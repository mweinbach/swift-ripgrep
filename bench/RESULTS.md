# Performance benchmark — Swift port vs Rust ripgrep

Direct head-to-head using the patterns, flags, and corpora from the upstream
`ripgrep/benchsuite` script. Run on **Apple M3 Ultra (32 cores), macOS 26.5**
with `hyperfine 1.20.0`, 1 warm-up iteration + 2 timed iterations per case.

- `rg`: `ripgrep 15.1.0` (release build, system install)
- `swift-rg`: `ripgrep 15.1.0 (rev 4519153e5e)` (release build,
  `.build/release/ripgrep` produced by `swift build -c release`)

## Swift-only default checkpoint — 2026-05-26

The package now omits `CRipgrepPlatform` by default. The Swift-only build keeps
the byte-search fast paths active through Swift SIMD fallbacks for the old
shim's byte-scanning entrypoints, and returns `-2` from unavailable
whole-output Darwin C entrypoints so the existing Swift path can take over.
Set `SWIFT_RIPGREP_USE_C_SHIM=1` to build the old C helper path for A/B
comparison. Both default Swift-only and C-shim comparison test suites pass 163
tests, with the Rust parity harness skipped unless `SWIFT_RIPGREP_PARITY=1` is
set.

Same-machine release checks used separate build directories:
`.build/c-shim/release/ripgrep` and `.build/no-c-shim/release/ripgrep`.
Sorted `--files` output and the checked subtitles outputs were byte-identical
between the C-shim and Swift-only binaries.

| Bench | Flags / corpus | rg | C-shim Swift | Swift-only | Swift-only / C-shim |
|---|---|---:|---:|---:|---:|
| file listing | `--files /tmp/swift-rg-bench/linux` | 91.0 ms | 149.4 ms | 154.5 ms | **1.03x** |
| no-match literal | `PM_RESUME` on 1.5 GiB subtitles | 171.0 ms | 159.8 ms | 182.0 ms | **1.14x** |
| case-insensitive literal | `-i sherlock` on 1.5 GiB subtitles | 300.1 ms | 174.7 ms | 202.4 ms | **1.16x** |
| multi-literal regex | `Sherlock|Watson` on 1.5 GiB subtitles | 298.5 ms | 343.0 ms | 380.3 ms | **1.11x** |

Bottom line: traversal/file-listing performance can effectively match the
current build without the C shim, and the matcher path is now close enough to
be plausible. The Swift-only build uses Swift SIMD16 first/tail candidate
scanners for case-sensitive and ASCII case-insensitive literals, plus a
Swift-only Darwin mmap preflight for simple `literal file` and `-i literal
file` invocations. That cuts the original no-shim `-i sherlock` result from
1.338 s to 202.4 ms. The remaining gap is scanner CPU: system time is
effectively tied with the C-shim
preflight, while user time remains about 27 ms higher on this corpus.

### Swift-only follow-up — 2026-05-26

The Swift-only Darwin literal preflight now skips directly to the end of a line
after emitting it. This preserves ripgrep's one-line-per-matching-line output
while avoiding repeated same-line rescans on dense literal lines. On a 33 MiB
synthetic corpus with ten `needle` hits per line, output was byte-identical to
both the previous Swift binary and the sibling Rust oracle; 10-run hyperfine
checks measured the case-sensitive form at 39.8 ms versus 228.3 ms for the
previous Swift-only checkpoint and 49.2 ms for Rust, while `-i NEEDLE` dropped
from 128.4 ms to about 10 ms in manual `/usr/bin/time` checks. The normal 1.5
GiB subtitles literal/no-match/case-insensitive/multi-literal smoke cases
remained neutral.

The same Swift-only literal preflight now keeps prepared case-insensitive
literal and shift-table buffers borrowed across the search loop instead of
rebinding them for each next-match probe. Output for 1.5 GiB `-i sherlock`,
193 MiB `Sherlock Holmes`, and no-match `PM_RESUME` checks matched both the
previous Swift checkpoint and the sibling Rust oracle, including no-match exit
status. Seven-run large-corpus checks measured `-i sherlock` at 217.4 ms versus
233.5 ms before and 301.1 ms for Rust; the neighboring `PM_RESUME` no-match
case stayed neutral at 198.2 ms versus 198.1 ms before. A 20-run 193 MiB smoke
measured `-i sherlock` at 32.6 ms versus 34.7 ms before and 42.9 ms for Rust.
The preflight writer now also unwraps its stdout buffer once after allocation
instead of paying optional access on each emitted line. Against the previous
Swift checkpoint on the same 1.5 GiB corpus, 7-run checks measured
`-i sherlock` at 202.4 ms versus 216.6 ms before and 285.3 ms for Rust; the
neighboring `PM_RESUME` no-match case stayed neutral at 184.3 ms versus
183.2 ms before. Output for `-i sherlock` and no-match output/exit status
matched both the previous Swift checkpoint and the sibling Rust oracle.

Quiet file-listing probes also got a small traversal cleanup. The no-ignore
existence walker now keeps recursive paths in byte buffers, and the
ignore-aware existence probe reuses the fast directory contents scan instead
of doing a marker-only scan before reading entries again. A 50-run recheck on
`/tmp/swift-rg-bench/linux` measured default `--quiet --files` at 11.1 ms
versus 11.7 ms for the previous Swift-only checkpoint; `--no-ignore --hidden
--quiet --files` stayed effectively tied at 9.1 ms.

The default ignore-aware `--files` path now avoids a few small repeated
allocations while walking the Linux tree: scoped ignore matchers cache their
`stripBasePath + "/"` prefix, the root ASCII-path check is computed once per
parallel walk, marker-name checks only run for hidden directory entries, and
`.`/`..` entries are skipped before Swift string decoding. A 60-run A/B on
`/tmp/swift-rg-bench/linux` preserved exact Swift output and measured Swift at
145.6 ms mean / 144.2 ms median versus the previous checkpoint at 146.3 ms mean
/ 143.6 ms median; the same run measured the sibling Rust release at 93.3 ms
mean / 90.0 ms median.

The Swift multi-literal full-line writer now skips to a matched line's output
end after recording it, caching line ends so later literals do not rescan
duplicate lines for newline boundaries. It also special-cases `-m 1` by finding
the earliest first literal match and emitting only that line, avoiding the
previous all-file collect/sort/prefix path. Output for `Sherlock|Watson` was
byte-identical to both the previous Swift checkpoint and the sibling Rust
oracle on the dense synthetic corpus and the 1.5 GiB subtitles corpus. A 20-run
A/B measured the dense duplicated-line corpus at 148.0 ms versus 161.7 ms for
the previous Swift checkpoint and 26.1 ms for Rust; the full subtitles corpus
stayed effectively neutral at 316.4 ms versus 320.5 ms before and 290.3 ms for
Rust. For `-m 1 'Sherlock|Watson'` on the subtitles corpus, a 30-run A/B
measured Swift at 49.7 ms versus 319.4 ms before and 6.0 ms for Rust; the
line-numbered `-n -m 1` form measured the same 49.7 ms versus 320.6 ms before.
The same earliest-line strategy now covers finite multi-literal max counts up
to 1280 lines, stopping after the requested output prefix instead of scanning
and sorting every matching line. Output for `-m 2`, `-n -m 2`, `-c -m 2`,
`-m 128`, `-m 129`, `-m 512`, `-m 1024`, `-m 1025`, `-m 1280`, and the
fallback boundary `-m 1281` was byte-identical to the previous Swift
checkpoint and the sibling Rust oracle. On the 1.5 GiB subtitles corpus,
30-run checks measured
`-m 2 'Sherlock|Watson'` at 43.5 ms versus 327.8 ms before and 6.1 ms for
Rust; `-m 10` measured 56.2 ms versus 329.3 ms before. A 20-run threshold
check measured `-m 128` at 150.6 ms versus 323.7 ms before and 23.0 ms for
Rust. Extending the threshold from 128 to 1024 lines kept output identical and
measured `-m 129` at 145.4 ms versus 322.7 ms before and 23.4 ms for Rust,
`-m 512` at 211.1 ms versus 322.2 ms before and 48.6 ms for Rust, and
`-m 1024` at 259.7 ms versus 325.3 ms before. Extending the cutoff again from
1024 to 1280 lines measured `-m 1025` at 265.7 ms versus 319.2 ms before and
63.8 ms for Rust; `-m 1280` measured 289.6 ms versus 317.0 ms before and
66.1 ms for Rust. Unlimited output continues through the previous scanner.

The Swift byte-set scanner now uses SIMD for alternations with up to eight
single-byte literals, while keeping the previous scalar bitset fallback for
larger sets. Output for `--count-matches 'A|B|C|D|E'`, `-o 'A|B|C|D|E'` and
bounded full-line output matched the previous Swift checkpoint and the sibling
Rust oracle. On the 193 MiB subtitles corpus, 15-run checks measured
`--count-matches 'A|B|C|D|E'` at 158.9 ms versus 237.3 ms before and
168.9 ms for Rust; `-o 'A|B|C|D|E'` at 269.7 ms versus 345.4 ms before and
205.6 ms for Rust; and `-m 20 'A|B|C|D|E'` at 46.9 ms versus 53.5 ms before.

The one-byte only-matching writer now emits the matched byte and trailing
newline through a single raw output call, and the line-number-only form emits
`line:byte\n` as one raw output chunk. Output for `-o`, `-n -o`, field-prefixed
variants, and the unchanged multi-byte literal form matched the previous Swift
checkpoint and the sibling Rust oracle. On the same 193 MiB subtitles corpus,
20-run checks measured `-o 'A'` at 98.5 ms versus 113.8 ms before and
75.5 ms for Rust. A 15-run cumulative recheck measured `-n -o 'A'` at
210.6 ms versus 229.9 ms before and 110.6 ms for Rust. A 15-run byte-set
recheck measured `-o 'A|B|C|D|E'` at 225.7 ms versus 264.2 ms before and
212.8 ms for Rust; the final line-numbered byte-set path measured
`-n -o 'A|B|C|D|E'` at 349.4 ms versus 447.9 ms before.

The executable direct-output byte-set count-matches path now skips matched-line
boundary accounting, while the non-direct testable path keeps exact summary
counts. Output for `--count-matches`, `-c`, `-o`, `-n -o`, and bounded
full-line byte-set searches matched the previous Swift checkpoint and the
sibling Rust oracle. On the 193 MiB subtitles corpus, 25-run checks measured
`--count-matches 'A|B|C|D|E'` at 122.4 ms versus 155.3 ms before and
171.6 ms for Rust. The neighboring `-c 'A|B|C|D|E'` mode remains on the exact
matched-line counter and measured effectively neutral on the same run.

The same direct-output total-only shortcut now covers one-byte literal
`--count-matches` searches. At that checkpoint, word-boundary searches and
multi-byte literals still used the exact matched-line path. Output for
one-byte, multi-byte, ignore-case, whole-line count, only-matching, and
word-boundary count forms matched the previous Swift checkpoint and the sibling
Rust oracle. On the 193 MiB subtitles corpus, 25-run checks measured
`--count-matches 'A'` at 67.4 ms versus 75.1 ms before and 65.1 ms for Rust.
A 20-run ignore-case check measured `--count-matches -i 'a'` at 214.9 ms
versus 466.1 ms before and 509.1 ms for Rust. Multi-byte `--count-matches
'Sherlock Holmes'` stayed effectively neutral at 62.8 ms versus 63.9 ms
before.

Direct executable `--count-matches` now extends that total-only shortcut to
single multi-byte literals as well, while the non-direct summary path still
keeps exact matched-line counts. Output and exit status for multi-byte,
ignore-case multi-byte, empty-file, one-byte, neighboring `-c`, and `-o`
fixtures matched the previous Swift checkpoint and sibling Rust oracle. On a
67 MiB dense `needle` fixture, 20-run checks measured `--count-matches
'needle'` at 115.9 ms versus 294.0 ms before and 178.0 ms for Rust. A
40-run sparse subtitles check for `--count-matches 'Sherlock Holmes'` remained
system-noise-bound: current measured 74.8 ms versus 68.9 ms before with the
same 23.3 ms user time in both runs.

The direct total-only path now also covers multi-literal `--count-matches`
when byte-level analysis proves the literals cannot overlap or contain one
another, so independent literal totals are equivalent to regex non-overlapping
counts. Safe alternation fixtures, neighboring `-c` and `-o` forms, and the
unsafe overlapping `a|ab` fallback matched the previous Swift checkpoint; safe
fixtures also matched the sibling Rust oracle. On the 193 MiB subtitles
corpus, 20-run checks measured `--count-matches 'Sherlock|Watson'` at 74.6 ms
versus 678.6 ms before and 39.4 ms for Rust. On the 67 MiB dense fixture,
15-run checks measured `--count-matches 'needle|haystack'` at 104.2 ms versus
1.933 s before and 249.0 ms for Rust.

The same non-overlap proof now enables direct plain `-o` output for safe
multi-literal alternations without line, byte-offset, or column prefixes.
Output for a `bravo|delta` fixture, the subtitles `Sherlock|Watson` corpus,
and neighboring prefixed `-n -o` mode matched the previous Swift checkpoint and
the sibling Rust oracle; unsafe overlapping `a|ab` only-match output stayed on
the existing fallback. On the 193 MiB subtitles corpus, three-run checks
measured `-o 'Sherlock|Watson'` at 198.3 ms versus 16.230 s before and 39.4 ms
for Rust.

Line-number, byte-offset, and column prefixes now use that same direct safe
multi-literal only-match writer. Output for `-n -o`, `-b -o`, combined
`-n -b -o`, column-only `--column -o`, combined `-n --column -b -o`, plain
`-o`, and unsafe overlapping fallback matched the previous Swift checkpoint;
safe prefixed forms also matched the sibling Rust oracle. On the 193 MiB
subtitles corpus, three-run checks measured `-n -o 'Sherlock|Watson'` at
278.6 ms versus 15.935 s before and 43.3 ms for Rust. The byte-offset form
measured 192.8 ms versus 15.827 s before and 40.2 ms for Rust. The column form
measured 267.0 ms versus 16.001 s before and 43.6 ms for Rust.

Plain executable `--vimgrep` output now has a direct byte-literal writer for
single literals and safe multi-literal alternations. It emits one row per match
with path, line, column and optional byte-offset fields while leaving
replacement, context, max-column, only-matching and unsafe overlapping
alternations on the existing formatted path. Output for literal, safe
multi-literal, byte-offset and no-filename vimgrep forms matched the previous
Swift checkpoint and the sibling Rust oracle on the 193 MiB subtitles corpus.
Five-run checks measured `--vimgrep 'Sherlock Holmes'` at 139.3 ms versus
10.840 s before and 31.8 ms for Rust. The safe multi-literal
`--vimgrep 'Sherlock|Watson'` form measured 269.9 ms versus 16.119 s before
and 44.3 ms for Rust.

Only-matching `--vimgrep -o` output now reuses that direct vimgrep writer,
emitting matched bytes instead of the containing line while preserving path,
line, column, byte-offset and no-filename field combinations. Output for
literal, safe multi-literal, byte-offset and no-filename `--vimgrep -o` forms
matched the previous Swift checkpoint and the sibling Rust oracle on the same
corpus. Five-run checks measured `--vimgrep -o 'Sherlock Holmes'` at
133.1 ms versus 10.746 s before and 31.2 ms for Rust. The safe multi-literal
`--vimgrep -o 'Sherlock|Watson'` form measured 261.9 ms versus 16.342 s before
and 43.8 ms for Rust.

Plain single-literal replacement output now has a direct byte writer when the
replacement text is literal-only and no formatted fields are requested. It
replaces every non-overlapping match on each matching line and leaves `$`
expansions, field-prefixed output, vimgrep, max-count and context forms on the
existing replacement path. Output for literal and empty replacements matched
the previous Swift checkpoint, and the representative literal replacement also
matched the sibling Rust oracle on the 193 MiB subtitles corpus. Five-run
checks measured `-r Holmes 'Sherlock Holmes'` at 64.1 ms versus 10.828 s
before and 24.9 ms for Rust.

That same direct replacement writer now handles line-numbered single-literal
output, including ASCII case-insensitive literals. Output for `-n -r Holmes
'Sherlock Holmes'` and `-n -i -r Holmes sherlock` on the 193 MiB subtitles
corpus matched both the previous Swift checkpoint and the sibling Rust oracle.
A three-run A/B measured the case-sensitive form at 79.0 ms versus 10.754 s
before and 28.7 ms for Rust; the case-insensitive form measured 69.5 ms versus
24.293 s before and 43.8 ms for Rust. A 15-run plain replacement control stayed
neutral at 64.6 ms versus 63.7 ms before.

The same direct path now also covers column and byte-offset prefixes for
single-literal replacement output. Output for column-only, byte-offset-only,
combined column+byte-offset, and matching ignore-case field forms on the
193 MiB subtitles corpus matched both the previous Swift checkpoint and the
sibling Rust oracle. Five-run A/B checks measured `--column -r Holmes
'Sherlock Holmes'` at 73.1 ms versus 10.838 s before and 28.6 ms for Rust;
`--byte-offset -r Holmes 'Sherlock Holmes'` at 110.6 ms versus 10.749 s before
and 24.4 ms for Rust; `--column --byte-offset -r Holmes 'Sherlock Holmes'` at
79.3 ms versus 10.897 s before and 30.0 ms for Rust; and `--byte-offset -i -r
Holmes sherlock` at 60.3 ms versus 24.281 s before and 41.3 ms for Rust.

Only-matching replacement output now uses the same direct literal replacement
scanner, including line/column/byte-offset prefixes and ASCII ignore-case
literals. Output for plain `-o -r`, column, byte-offset, combined
line+column+byte-offset, and ignore-case forms on the 193 MiB subtitles corpus
matched both the previous Swift checkpoint and the sibling Rust oracle. Five-run
A/B checks measured `-o -r Holmes 'Sherlock Holmes'` at 56.7 ms versus
10.860 s before and 26.8 ms for Rust; `-o --column -r Holmes
'Sherlock Holmes'` at 86.4 ms versus 10.863 s before and 30.8 ms for Rust;
`-o --byte-offset -r Holmes 'Sherlock Holmes'` at 70.9 ms versus 10.794 s
before and 26.5 ms for Rust; `-n -o --column --byte-offset -r Holmes
'Sherlock Holmes'` at 81.3 ms versus 10.781 s before and 30.2 ms for Rust;
and `-o -i -r Holmes sherlock` at 61.4 ms versus 24.388 s before.

Bounded literal replacement output now also stays on the direct Swift writer
for whole-line and only-matching forms. It preserves ripgrep's one-line
max-count semantics by stopping after the requested number of matching lines
while still replacing every match on emitted lines. Output for bounded plain,
only-matching, prefixed only-matching, and ignore-case replacement forms on the
193 MiB subtitles corpus matched both the previous Swift checkpoint and the
sibling Rust oracle. Five-run A/B checks measured `-m1 -r Holmes
'Sherlock Holmes'` at 46.2 ms versus 10.738 s before and 11.6 ms for Rust;
`-m128 -r Holmes 'Sherlock Holmes'` at 68.6 ms versus 10.760 s before;
`-m1 -o -r Holmes 'Sherlock Holmes'` at 53.8 ms versus 10.694 s before and
11.2 ms for Rust; and `-m1 -n -o --column --byte-offset -r Holmes
'Sherlock Holmes'` at 65.0 ms versus 10.937 s before and 13.3 ms for Rust.

Literal-only `--vimgrep --replace` output now uses a direct Swift writer for
single-literal whole-line and only-matching replacement forms, including
filename, line, column, byte-offset, ignore-case, no-column, no-filename, empty
replacement and finite max-count field combinations. Replacement coordinates
follow ripgrep's replaced-line positions while max-count still counts matching
lines. Output on the 193 MiB subtitles corpus matched both the previous Swift
checkpoint and the sibling Rust oracle. Five-run A/B checks measured
`--vimgrep -r Holmes 'Sherlock Holmes'` at 73.8 ms versus 10.970 s before and
28.4 ms for Rust; `--vimgrep -o -r Holmes 'Sherlock Holmes'` at 72.7 ms versus
10.768 s before and 28.8 ms for Rust; `--vimgrep --byte-offset -r Holmes
'Sherlock Holmes'` at 72.0 ms versus 10.813 s before; `--vimgrep -m1 -r
Holmes 'Sherlock Holmes'` at 58.3 ms versus 10.799 s before and 13.4 ms for
Rust; and `--vimgrep -m1 -o -r Holmes 'Sherlock Holmes'` at 57.2 ms versus
10.822 s before and 12.5 ms for Rust.

Plain single-literal `--vimgrep` now keeps finite max-count output on the
direct Swift writer. The bounded path scans at line granularity so `-m` counts
matching lines while still emitting every match on each admitted line for both
whole-line and only-matching output. Output for `-m1`, `-m2`, `-o`, byte-offset,
no-column, no-filename, and ignore-case vimgrep forms on the 193 MiB subtitles
corpus matched both the previous Swift checkpoint and the sibling Rust oracle.
Five-run A/B checks measured `--vimgrep -m1 'Sherlock Holmes'` at 50.8 ms
versus 10.828 s before and 13.5 ms for Rust; `--vimgrep -m1 -o
'Sherlock Holmes'` at 53.8 ms versus 10.826 s before and 12.7 ms for Rust; and
`--vimgrep -m2 -o 'Sherlock Holmes'` at 51.4 ms versus 10.815 s before.

Safe multi-literal only-match and vimgrep output now merge each literal's next
match stream instead of re-scanning every literal from the current global
offset. Interleaved same-line fixtures and representative subtitles cases
matched both the previous Swift checkpoint and the sibling Rust oracle. Five-run
A/B checks on the 193 MiB subtitles corpus measured `-o 'Sherlock|Watson'` at
67.4 ms versus 184.4 ms before and 39.6 ms for Rust, `-n -o
'Sherlock|Watson'` at 156.3 ms versus 266.5 ms before and 44.0 ms for Rust,
and `--vimgrep 'Sherlock|Watson'` at 158.8 ms versus 263.1 ms before and
43.6 ms for Rust.

The Swift fallback byte counter now uses a SIMD mask sum instead of a repeated
`memchr` loop, which cuts the line-number accounting cost in formatted direct
writers and speeds dense byte counts without reintroducing any C shim. Output
for vimgrep, prefixed only-match, one-byte count, byte-set count, ignore-case
one-byte count and multi-byte count cases matched both the previous Swift
checkpoint and the sibling Rust oracle. Five-run checks measured `--vimgrep
'Sherlock Holmes'` at 75.8 ms versus 125.5 ms before and 29.1 ms for Rust,
`--vimgrep 'Sherlock|Watson'` at 72.9 ms versus 158.8 ms before and 43.5 ms
for Rust, `-n -o 'Sherlock|Watson'` at 82.5 ms versus 156.3 ms before and
43.5 ms for Rust, and `--count-matches -i 'a'` at 66.3 ms versus 198.7 ms
before and 509.0 ms for Rust.

Byte-set `--count-matches` now counts sets of three or more bytes in one Swift
SIMD pass instead of scanning the haystack once per byte. Two-byte sets stay on
the previous counter after sparse checks came back neutral. Output for two-byte,
five-byte, alphabet and ignore-case control cases matched both the previous
Swift checkpoint and the sibling Rust oracle. Seven-run checks measured
`--count-matches 'A|B|C|D|E'` at 78.5 ms versus 99.4 ms before and 174.5 ms
for Rust, and the alphabet set at 159.8 ms versus 280.1 ms before and 892.1 ms
for Rust.

The Swift fallback two-byte `memchr-any` scanner now keeps both SIMD comparison
vectors outside the scan loop instead of rebuilding them for each chunk. Output
for sparse, dense, and prefixed two-byte only-match cases matched both the
previous Swift checkpoint and the sibling Rust oracle. Twenty-run checks on the
193 MiB subtitles corpus measured `-o 'Q|Z'` at 55.9 ms versus 65.7 ms before
and 27.0 ms for Rust, and `-o 'A|B'` at 120.3 ms versus 131.3 ms before and
103.4 ms for Rust. The neighboring `-n -o 'A|B'` form stayed neutral at
167.1 ms versus 167.8 ms before.

Direct executable byte-unit PCRE2 `--count-matches` now counts totals without
matched-line bookkeeping while preserving the exact summary path for non-direct
callers. Output for default Unicode `\C`, byte-mode `\C`, `\C+`, `\C{2}`, and
a continuation-byte no-match case matched the previous Swift checkpoint and the
sibling Rust oracle. On the 193 MiB subtitles corpus, 20-run checks measured
`-P --count-matches '\C'` at 276.8 ms versus 576.3 ms before and 10.669 s for
Rust PCRE2. Ten-run Swift A/B checks measured `-P --no-pcre2-unicode
--count-matches '\C'` at 149.0 ms versus 579.7 ms before, `-P --count-matches
'\C+'` at 134.4 ms versus 145.8 ms before, and `-P --count-matches '\C{2}'`
at 218.4 ms versus 428.5 ms before.

The direct one-byte and byte-set `--count-matches` paths now use the existing
Swift byte counter instead of issuing a find-next call per match. Output for
five-byte, alphabet, sparse, and ignore-case counts matched the previous Swift
checkpoint and the sibling Rust oracle. On the 193 MiB subtitles corpus, 25-run
checks measured `--count-matches -i 'a'` at 198.7 ms versus 211.8 ms before,
`--count-matches 'A|B|C|D|E'` at 103.4 ms versus 116.4 ms before, and the
single-byte `--count-matches 'A'` form effectively neutral at 64.2 ms versus
64.3 ms before. Ten-run size checks measured `--count-matches
'A|B|C|D|E|F|G|H|I|J|K|L|M|N|O|P|Q|R|S|T|U|V|W|X|Y|Z'` at 310.4 ms versus
529.5 ms before, while sparse `--count-matches 'Q|Z'` stayed neutral at
61.5 ms versus 63.2 ms before.

Fixed PCRE2 literal lookaround `--count-matches` also skips matched-line
bookkeeping for direct executable output. Positive/negative lookaround,
case-insensitive lookbehind, no-match backreference, and neighboring `-c`
outputs matched the previous Swift checkpoint and the sibling Rust oracle. On
the 193 MiB subtitles corpus, 20-run checks measured `-P --count-matches
'(?<=Sherlock )Holmes'` at 72.1 ms versus 139.1 ms before and 214.5 ms for
Rust PCRE2. The equivalent lookahead `-P --count-matches
'Sherlock(?= Holmes)'` measured 64.2 ms versus 138.5 ms before.

Fixed PCRE2 reset-start literal `--count-matches` now uses the same direct
total-only shape. Output for a subtitles `Sherlock\K Holmes` case, dense
`foo\K`, empty-prefix `\Kfoo`, neighboring `-c`, and only-matching reset-start
forms matched the previous Swift checkpoint and the sibling Rust oracle. On the
193 MiB subtitles corpus, 20-run checks measured `-P --count-matches
'Sherlock\K Holmes'` at 66.8 ms versus 140.5 ms before and 215.1 ms for Rust
PCRE2. On a 60 MiB reset-start fixture, `-P --count-matches 'foo\K'` measured
116.7 ms versus 152.5 ms before, and ten-run `-P --count-matches '\Kfoo'`
checks measured 127.5 ms versus 162.0 ms before.

Bare PCRE2 reset-start `--count-matches '\K'` now counts direct executable
output from the mapped byte size, while the formatted `-o` and whole-line
paths keep their exact line-position scanner. Output and exit status for final
newline, no-final-newline, empty-line, UTF-8, empty-file, and no-Unicode
invalid-byte fixtures matched the previous Swift checkpoint and the sibling
Rust oracle, as did neighboring `-o`, field-prefixed `-o`, and whole-line
forms. On the 193 MiB subtitles corpus, 20-run checks measured `-P
--count-matches '\K'` at 43.1 ms versus 158.4 ms before and 3.443 s for Rust
PCRE2. On the 60 MiB reset-start fixture, the same search measured 42.3 ms
versus 67.3 ms before and 1.079 s for Rust PCRE2.

Fixed PCRE2 assertion conditional `--count-matches` now skips matched-line
tracking for direct executable output while preserving the formatted `-o` and
whole-line count paths. Output and exit status for positive, false, negative,
lookbehind, ignore-case, and empty-file conditional count fixtures matched the
previous Swift checkpoint and sibling Rust oracle, as did neighboring `-c` and
`-o` forms. On the 193 MiB subtitles corpus, 20-run checks measured `-P
--count-matches '(?(?=Sherlock)Sherlock|Holmes)'` at 156.3 ms versus
247.3 ms before and 468.1 ms for Rust PCRE2.

Rejected Swift-only probes from the same checkpoint:

- Routing multi-literal full-line output through the existing line-by-line
  checker preserved output but regressed `Sherlock|Watson` on the 1.5 GiB
  subtitles corpus to 7.275 s versus 334.2 ms for the current per-literal
  scanner and 307.4 ms for Rust.
- A cross-literal interval skip helped the dense duplicated-line corpus
  (164.3 ms to 101.9 ms) but slowed the representative subtitles corpus
  (336.2 ms to 340.4 ms), and an adaptive probe still measured slower on that
  corpus (338.4 ms to 351.5 ms).
- A stdout byte-chunk writer for ignore-aware `--files` preserved current Swift
  ordering and sorted Rust content, but slowed default Linux-tree listing from
  149.7 ms to 168.3 ms.
- A count-only multi-literal path that skipped line-bound storage and sorting
  preserved output, but measured neutral to slightly slower on
  `-c 'Sherlock|Watson'` over the 1.5 GiB subtitles corpus: 327.0 ms versus
  323.0 ms for the current scanner.
- Extending the finite multi-literal cutoff all the way to 4096 preserved
  output, but the repeated earliest-match scans overtook the collect/sort path:
  `-m 2048 'Sherlock|Watson'` measured 414.9 ms versus 309.7 ms before, and
  `-m 4096` measured 1.157 s versus 321.5 ms before.
- Skipping the unavailable C-shim multi-literal stdout probe in the default
  Swift-only build avoided a small setup detour but did not improve the
  representative unlimited `Sherlock|Watson` benchmark.
- Replacing the general literal scanner with a first-byte `memchr` loop helped
  no-match literal scans in one trial, but regressed normal matching literals
  badly (`'Sherlock Holmes'` measured 275.1 ms versus 190.2 ms before). A
  narrower first-search-only version was neutral for no-match and slightly
  slower for matching output, so the SIMD first/tail scanner remains the
  default literal path.
- Replacing the Swift SIMD fallback with Foundation `Data.range(of:)` or libc
  `memmem` was much slower on the literal subtitles scan: `Data.range(of:)`
  measured 633.7 ms and libc `memmem` measured 1.046 s, versus about 213 ms
  for the current Swift scanner and about 192 ms for Rust.
- Streaming single-literal `-m 1` through the existing line-by-line path
  preserved output on spot checks, but was slow enough on the large subtitles
  corpus that the 60-run benchmark was terminated after the mmap baseline
  completed at 50.1 ms.
- Tracking the current line in the byte-set scanner preserved output, but
  regressed dense byte-set count and only-matching output: `--count-matches
  'A|B|C|D|E'` measured 254.3 ms versus 155.6 ms before, `-o` measured
  312.6 ms versus 220.5 ms before, and `-n -o` measured 435.3 ms versus
  348.3 ms before, so the local backward/newline scans remain on those paths.
- Widening the Swift first/tail literal candidate scanner from `SIMD16` to
  `SIMD32` preserved output but badly regressed representative literal scans:
  no-match `PM_RESUME` measured 120.8 ms versus 28.0 ms before, and
  `'Sherlock Holmes'` measured 117.2 ms versus 28.3 ms before.
- Extending the one-pass byte-set `--count-matches` counter down to two-byte
  sets preserved the focused byte-alternation test, but remained too noisy and
  regressed the sparse two-byte control. A 25-run check against checkpoint
  `8be9fe9` measured `--count-matches 'A|B'` at 65.3 ms versus 75.8 ms before,
  while sparse `--count-matches 'Q|Z'` measured 88.3 ms versus 74.6 ms before.
- Routing one-byte case-insensitive searches through the two-byte SIMD
  `memchr-any` scanner helped sparse output but regressed dense vowels. The best
  hybrid probe measured `-i -o 'q'` at 63.6 ms versus 173.1 ms before, while
  dense `-i -o 'e'` regressed to 1.350 s versus 1.220 s before.
- Caching vimgrep line bounds across same-line matches and forcing
  `rg_memchr_any_bytes` to inline both preserved focused tests, but slowed
  representative subtitles checks. The vimgrep cache measured
  `--vimgrep -o 'A'` at 240.4 ms versus 233.0 ms before and
  `--vimgrep 'Sherlock|Watson'` at 99.4 ms versus 85.4 ms before; forced
  `memchr-any` inlining measured sparse `-o 'Q|Z'` at 69.5 ms versus 61.7 ms
  before and five-byte `--count-matches` at 72.9 ms versus 68.2 ms before.

## Status — 2026-05-25 fast-path checkpoint

After the Darwin C fast-path work, the hot single-file ASCII cases are now
near Rust ripgrep, and several are faster in this environment. Single-file
benchmarks below use `/tmp/swift-rg-bench/subtitles/en.small.txt` (193 MiB).

| Bench | Flags | rg | swift-rg | swift / rg |
|---|---|---:|---:|---:|
| literal | `'Sherlock Holmes'` | 25.8 ms | 26.4 ms | **1.03x** |
| PCRE literal | `-P 'Sherlock Holmes'` | 220.0 ms | 26.7 ms | **0.12x** |
| PCRE literal, case-insensitive | `-P -i 'sherlock holmes'` | 371.8 ms | 35.3 ms | **0.09x** |
| literal, no-mmap | `--no-mmap 'Sherlock Holmes'` | 26.2 ms | 24.8 ms | **0.95x** |
| literal, case-insensitive | `-i 'Sherlock Holmes'` | 41.5 ms | 35.3 ms | **0.85x** |
| word boundary | `-nw 'Sherlock Holmes'` | 31.2 ms | 32.0 ms | **1.03x** |
| byte alternation, 5 literals | `'A\|B\|C\|D\|E'` | 128.2 ms | 97.6 ms | **0.76x** |
| required-literal regex with lines | `-n '\w+\s+Holmes\s+\w+'` | 33.7 ms | 32.3 ms | **0.96x** |

Plain single-literal only-match field output now stays on the Darwin byte
writer. On the 193 MiB subtitles corpus, `-b -o 'Sherlock Holmes'` produced
byte-identical output to the sibling Rust oracle and measured Swift release at
86.0 ms versus 1.089 s for Rust in 5-run checks. `--column -o 'Sherlock
Holmes'` measured Swift at 64.6 ms versus 1.423 s for Rust, and
`-n -b --column -o 'Sherlock Holmes'` measured Swift at 73.2 ms versus
1.428 s for Rust. These literal field cases previously fell through the
formatted Swift path at about 10.8 s on the same corpus.

Whole-line single-literal field output now uses the same direct writer. On the
193 MiB subtitles corpus, `-b 'Sherlock Holmes'` produced byte-identical output
to Rust and measured Swift release at 87.7 ms versus 1.090 s for Rust in
5-run checks. `--column 'Sherlock Holmes'` measured Swift at 78.5 ms versus
1.425 s for Rust, and `-n -b --column 'Sherlock Holmes'` measured Swift at
72.8 ms versus 1.420 s for Rust. These whole-line field cases previously fell
through the formatted Swift path at about 11.0 s on the same corpus.

Single-byte alternation only-match and count-match output now stays correct on
the byte-set scanner instead of printing whole lines. On the 193 MiB subtitles
corpus, `-o 'A|B|C|D|E'` produced byte-identical output to Rust and measured
Swift release at 270.7 ms versus 3.896 s for Rust in 3-run checks.
`--count-matches 'A|B|C|D|E'` measured Swift at 164.7 ms versus 3.660 s for
Rust, also with byte-identical output.

Multi-byte literal regex alternations now avoid the Foundation regex path for
plain full-line output. On the 193 MiB subtitles corpus, `Sherlock|Watson`
produced byte-identical output to the sibling Rust oracle and measured Swift
release at 80.3 ms after the direct Darwin scanner, down from 21.7 s on the
previous Swift path. System Rust release measured 42.6 ms on the same 20-run
check, so this slice removes the pathological fallback while leaving a smaller
multi-literal scanner gap to close.

A 3-run PCRE compatibility check for `-P -o '(?<=Sherlock )Holmes'` on the
same 193 MiB file produced byte-identical output to Rust and measured Swift at
141.4 ms versus Rust PCRE2 at 214.9 ms (**0.66x**). The same query took about
25.3 s through the Foundation-regex path before the in-tree fixed-lookbehind
specialization.

The same fixed PCRE byte path now covers explicit ASCII case-folding under
`--no-pcre2-unicode`. On the current 1.5 GiB / 55 M-line subtitles corpus,
`-P --no-pcre2-unicode -i -o '(?<=sherlock )holmes'` produced byte-identical
output to Rust and measured Swift release at 1.099 s versus Rust PCRE2 at
1.841 s in 10-run checks. The case-sensitive control on the same larger file,
`-P -o '(?<=Sherlock )Holmes'`, measured Swift release at 1.014 s.

The matching fixed-lookahead shape is on the same byte path:
`-P -o 'Sherlock(?= Holmes)'` produced byte-identical output and measured
Swift at 145.5 ms versus Rust PCRE2 at 216.0 ms (**0.67x**) in a 3-run check.

Plain PCRE literal searches now route through the default literal matcher and,
for executable spellings with leading engine selectors (`-P`, `--pcre2`,
`--engine`, `--auto-hybrid-regex`, `--no-pcre2`), the Darwin literal preflight.
On the 193 MiB subtitles corpus, `-P 'Sherlock Holmes'` produced
byte-identical output and measured Swift release at 26.7 ms versus system Rust
`rg` PCRE2 at 220.0 ms in 7-run checks. The newly covered `-P -i 'sherlock
holmes'` literal form measured Swift release at 35.3 ms versus Rust PCRE2 at
371.8 ms in a separate 7-run check.

Escaped fixed PCRE literals now share the same Swift literal parser and Darwin
preflight. On a 119 MiB repeated `[Sherlock].Holmes` corpus,
`-P '\[Sherlock\]\.Holmes'` produced byte-identical output and measured Swift
release at 58.6 ms versus system Rust `rg` PCRE2 at 219.0 ms in 7-run checks.
The first escaped-literal version exposed the old per-line writer cost at
1.463 s on the same corpus, so the plain Darwin literal writer now batches
stdout through the shared 1 MiB output buffer.

PCRE quoted literals now use the same in-tree parser and Darwin preflight
without linking libpcre2. On the same 119 MiB escaped-literal corpus,
`-P '\Q[Sherlock].Holmes\E'` produced byte-identical output and measured Swift
release at 60.5 ms versus system Rust `rg` PCRE2 at 218.7 ms in 10-run checks
(3.62x faster in this environment). The default and `--no-pcre2` modes still
reject `\Q`/`\E` with Rust-identical diagnostics, while `--engine=auto` follows
Rust by using the PCRE-compatible path.

The remaining literal-style Darwin writers now use the same buffered output
path for dense line output. On the escaped-literal corpus,
`--no-mmap -P '\[Sherlock\]\.Holmes'` measured Swift release at 180.7 ms
versus system Rust at 218.8 ms in 7-run checks. On a 105 MiB dense word-boundary
corpus, `-nw 'Sherlock'` measured Swift release at 129.9 ms versus system Rust
at 524.9 ms, with byte-identical output in release spot checks.

Fixed negative lookaround literals also avoid the Foundation regex path for
single-file `-P -o`. On a 54 MiB repeated
`Sherlock Holmes` / `Mycroft Holmes` / `Sherlock Watson` corpus,
`-P -o '(?<!Sherlock )Holmes'` produced byte-identical output to Rust and
measured Swift release at 167.2 ms versus 15.520 s for the previous Swift path
and 1.661 s for the sibling Rust PCRE2 oracle in 10-run checks. The matching
negative-lookahead shape, `-P -o 'Sherlock(?! Holmes)'`, measured 145.8 ms
versus 15.441 s for the previous Swift path on the same corpus.

Simple literal-group backreferences now take the same in-tree byte-output path
for single-file `-P -o`. On a 74 MiB repeated `abba abca Sherlock Holmes`
corpus, `-P -o '(a)(b)\2'` produced byte-identical output to Rust and measured
Swift release at 229.3 ms versus 19.239 s for the previous Swift Foundation
regex path and 2.912 s for the sibling Rust PCRE2 oracle in 10-run checks.
Equivalent PCRE/Python spellings now use that same parser and byte path: on a
60 MiB repeated `foofoo` / `foobar` / `foo` corpus, `-P -o '(foo)\g1'`
measured Swift release at 354.4 ms versus system Rust PCRE2 at 503.9 ms, and
`-P -o '(?P<w>foo)(?P=w)'` measured Swift release at 350.9 ms versus Rust PCRE2
at 506.9 ms in 10-run checks. Both outputs were byte-identical to Rust.

Fixed PCRE reset-start literals now reuse the same in-tree fixed-lookbehind
byte path. On a 60 MiB repeated `foobar` / `fooqux` / `bar` corpus,
`-P -o 'foo\Kbar'` produced byte-identical output to system Rust `rg` PCRE2
and measured Swift release at 396.1 ms versus Rust PCRE2 at 502.3 ms in
10-run checks. Default and `--no-pcre2` modes still reject `\K` with
Rust-identical diagnostics.

Reset-start forms with an empty prefix or empty returned literal now use their
own in-tree byte scanner too. On a 32 MiB repeated `foo barfoo foofoo` corpus,
`-P --count-matches 'foo\K'` produced byte-identical output to system Rust
`rg` PCRE2 and measured Swift release at 99.9 ms versus Rust at 226.0 ms in
5-run checks. The non-empty returned slice `-P -o 'bar\Kfoo'` also produced
byte-identical output and measured Swift at 155.7 ms versus Rust PCRE2 at
179.1 ms. A dense field-output spot check for
`-P -n --column --byte-offset -o 'foo\K'` produced 110,391,211 bytes identical
to Rust on the same corpus.

Bare reset-start `\K` now has a pure Swift matcher and a Darwin raw-byte fast
path for line, only-match, count, path and quiet modes. On a 33.6 MiB repeated
`foo bar baz` corpus, `-P --count-matches '\K'` produced byte-identical output
to system Rust `rg` PCRE2 and measured Swift release at 71.9 ms versus Rust at
660.0 ms in 5-run checks (**0.11x**). The same oracle sweep covered final
newline, unterminated final line, empty line, UTF-8 byte positions,
`--no-pcre2-unicode` invalid-byte input, path modes and quiet statuses.

PCRE assertion-conditionals with fixed literal lookaround conditions now avoid
the Foundation regex path too. On a 14 MiB repeated `foofoo` / `bar` /
`foobar` corpus, `-P -o '(?(?=foo)foo|bar)'` produced 14,000,000 bytes of
output byte-identical to system Rust `rg` PCRE2 and measured Swift release at
130.6 ms versus Rust PCRE2 at 215.1 ms in 7-run checks (**0.61x**). The plain
executable `-P -o` form uses a narrow checked-in Darwin stdout writer, while
default and `--no-pcre2` modes still reject assertion-conditionals with
Rust-compatible `unrecognized flag` diagnostics.

Fixed PCRE byte-unit escapes now avoid both libpcre2 and Foundation regex for
the covered whole-pattern forms. On a 16 MiB slice of the subtitles corpus,
`-P -o '\C'` produced byte-identical output to system Rust `rg` PCRE2 and
measured Swift release at 155.8 ms versus Rust at 1.102 s in 7-run checks.
The greedy whole-line form `-P -o '\C+'` also produced byte-identical output
and measured Swift at 64.3 ms versus Rust PCRE2 at 120.6 ms. A full-corpus
Swift-only spot check on the 193 MiB file produced 391,244,874 bytes for
`\C` and 202,721,401 bytes for `\C+`, confirming the direct byte writer is
being exercised on dense output.

The same byte-unit matcher now has a formatted Swift byte-loop fast path for
field/count/path/quiet modes, with Rust-oracle spot checks covering fielded
`\C{2}`, counts, path modes and quiet statuses. On the same 16 MiB corpus,
`-P -n --column --byte-offset -o '\C'` measured Swift release at 1.935 s versus
system Rust PCRE2 at 1.924 s in 5-run checks, effectively output-format bound.
The non-output-heavy `-P --count-matches '\C'` form measured Swift at 93.8 ms
versus Rust PCRE2 at 876.6 ms on the same corpus.

Line-numbered only-match output for the same fixed PCRE2 family now stays on
the executable Darwin byte writer too. On the 193 MiB subtitles corpus,
`-P -n -o '(?<=Sherlock )Holmes'` produced byte-identical output to the sibling
Rust PCRE2 oracle and measured Swift release at 140.5 ms versus 10.717 s for
the previous Swift formatted path and 2.709 s for Rust PCRE2 in 10-run checks.

Count-oriented fixed PCRE2 output now stays on that same byte path. On the
193 MiB subtitles corpus, `-P -c '(?<=Sherlock )Holmes'` measured Swift
release at 144.5 ms versus 299.4 ms before this slice and 2.365 s for Rust
PCRE2 in 10-run checks. `-P --count-matches '(?<=Sherlock )Holmes'` measured
Swift release at 146.8 ms versus 302.9 ms before this slice and 2.378 s for
Rust PCRE2. This slice also fixed quiet count output so `-q -c` remains silent
like Rust while preserving the match exit status.

Byte-offset and byte-column only-match output for fixed PCRE2 shapes now stays
on the same direct Darwin writer. On the 193 MiB subtitles corpus,
`-P -b -o '(?<=Sherlock )Holmes'` produced byte-identical output to the sibling
Rust PCRE2 oracle and measured Swift release at 139.6 ms versus 2.385 s for
Rust in 5-run checks. `-P --column -o '(?<=Sherlock )Holmes'` measured Swift
at 144.3 ms versus 2.712 s for Rust, and
`-P -n -b --column -o '(?<=Sherlock )Holmes'` measured Swift at 145.1 ms
versus 2.699 s for Rust. These cases previously fell through the formatted
Swift path at about 10.6 s on the same corpus.

The recursive Linux-kernel traversal/search path now matches or beats Rust in
this environment for the default literal search. The file-list rows below use
3 warm-ups and 15 timed iterations for the default Swift worker count and Rust
`rg`; the default literal row is the earlier 7-run confirmation:

| Bench | Flags | rg | swift-rg | swift / rg |
|---|---|---:|---:|---:|
| Linux tree files | `--files` | 93.0 ms | 134.0 ms | **1.44x** |
| Linux tree files, hidden | `--hidden --files` | 83.0 ms | 126.3 ms | **1.52x** |
| Linux tree files, no ignore | `--no-ignore --files` | 71.9 ms | 82.1 ms | **1.14x** |
| Linux tree files, no ignore/hidden | `--no-ignore --hidden --files` | 73.8 ms | 83.2 ms | **1.13x** |
| Linux tree files, quiet | `--quiet --files` | 6.7 ms | 9.2 ms | **1.36x** |
| Linux tree literal | `PM_RESUME` | 3.92 s | 2.37 s | **0.61x** |

The Linux-tree comparisons above have byte-identical sorted output, including
the 79,353-path `--files` set, and the Swift `--files` natural output remains
byte-identical to the previous Swift checkpoint. Natural output order still
differs from Rust for this corpus because the Swift walker preserves its own
deterministic traversal order under parallel search. The latest traversal
slices reduced the Swift `--files` mean from 1.43 s into the low-hundreds of
milliseconds, the `--no-ignore --hidden --files` mean to 168.4 ms, and the
Swift `PM_RESUME` median from 2.53 s to 2.37 s versus the previous 0ae4c30
checkpoint on the same corpus.

The key improvements since the 2026-05-24 baseline are:

- executable-level Darwin fast paths for plain literals, no-mmap literals,
  ASCII ignore-case literals, word literals, surrounding-word regexes, and
  byte alternations;
- plain single-literal only-match byte-offset and byte-column formatting now
  writes line/column/offset prefixes directly on the Darwin byte path, cutting
  representative field output from about 10.8 s to 64.6-86.0 ms while
  preserving Rust field ordering and byte-identical output;
- plain single-literal whole-line byte-offset and byte-column formatting uses
  the same direct line writer, cutting representative line field output from
  about 11.0 s to 72.8-87.7 ms while preserving Rust field ordering and
  byte-identical output;
- single-byte alternation `-o` and `--count-matches` output now stays on the
  byte-set scanner with correct per-match output, measuring 270.7 ms and
  164.7 ms respectively on the representative subtitles corpus while matching
  Rust byte-for-byte;
- plain multi-byte literal alternation line output now uses a vendored
  Darwin/arm scanner and a Swift sparse fallback for field/count variants,
  cutting `Sherlock|Watson` on the subtitles corpus from about 21.7 s to
  80.3 ms while preserving byte-identical Rust output;
- literal PCRE assertion-conditionals now translate into the in-tree matcher
  and use a narrow Darwin stdout writer for plain executable `-P -o`, measuring
  130.6 ms versus Rust PCRE2 at 215.1 ms on the dense conditional corpus while
  preserving byte-identical output;
- NEON-backed literal, byte-counting, and byte-set scanning in
  `CRipgrepPlatform`;
- suppressed optional ignore-file loads now check existence before attempting
  UTF-8 reads, avoiding exception-heavy traversal misses;
- recursive walking now appends into a single accumulator instead of returning
  and merging per-directory arrays, cutting same-load Swift `PM_RESUME` median
  from 3.58 s to 3.46 s;
- Darwin traversal now uses POSIX `fstatat` metadata instead of per-entry
  `URL.resourceValues`, avoids Foundation resource prefetch for directory
  listings, records ignore marker names while reading directory entries, and
  threads child metadata and relative paths through recursion;
- `--quiet --files` now stops after the first searchable haystack when sorting
  and debug logging are off, while preserving missing-root diagnostics;
- plain single-root Darwin `--files` now streams paths from a string/POSIX
  walker without materializing `URL` haystacks, and batches stdout writes
  through a reusable 64 KiB buffer;
- ignore matching skips regex fallbacks after ASCII simple-glob misses, avoids
  regex compilation for exact/prefix/suffix fast rules, passes child basenames
  through the ignore stack to avoid repeated path slicing, and has an even
  thinner no-ignore/hidden traversal branch;
- path rendering skips Unicode precomposition for ASCII paths and `--files`
  output no longer materializes a second full path-string array;
- byte-literal fast-path detection is cached per worker matcher, and the
  streaming fallback probe reuses walker metadata instead of restatting files;
- PCRE2 is no longer linked, and the common fixed positive-lookaround literal
  shapes now use an in-tree Swift parser plus Darwin byte scanning for
  `-P -o`, preserving Rust output while avoiding Foundation regex work on the
  hot path;
- plain literals behind leading PCRE/engine selectors (`-P`, `--pcre2`,
  `--engine`, `--auto-hybrid-regex`, `--no-pcre2`) now bypass the
  compatibility matcher entirely, reuse the default literal fast path, and hit
  the executable Darwin literal preflight for direct invocations while keeping
  the Rust-compatible PCRE2 CLI surface;
- safely escaped fixed PCRE literals such as `foo\.bar` now use the same
  parser and executable preflight, and the plain Darwin literal writer batches
  dense output through the shared 1 MiB buffer instead of writing per line;
- PCRE quote escapes (`\Q...\E`, plus standalone `\E`) are handled in-tree for
  `-P` and auto-hybrid modes; fully quoted literals take the Darwin literal
  preflight, partial quoted regexes are translated before Foundation regex
  compilation, and default/no-PCRE modes keep Rust-compatible rejection
  diagnostics;
- streaming no-mmap literals, surrounding-word regex output, and line-numbered
  word literal output now use that same buffered writer so dense-match cases
  avoid per-line syscalls;
- PCRE2 fixed negative-lookaround literal shapes now use the same in-tree
  parser and Darwin byte scanner for `-P -o`, preserving Rust output while
  reducing representative negative lookbehind/lookahead cases by about two
  orders of magnitude versus the previous Swift path;
- PCRE2 literal-group backreferences such as `(a)(b)\2` now use the same
  in-tree parser and Darwin byte-output path for single-file `-P -o`, while
  still preserving capture replacement semantics through the non-executable
  matcher path;
- equivalent PCRE/Python backreference spellings such as `(foo)\g1`,
  `(foo)\g{1}`, `(?<w>foo)\g{w}`, `(?<w>foo)\g<w>`, and
  `(?P<w>foo)(?P=w)` now translate in-tree and use that same fixed
  backreference path when the capture bodies are literals;
- PCRE2 reset-start literals such as `foo\Kbar` now parse into the same
  in-tree fixed-lookbehind representation, preserving line output,
  only-matching output, replacement ranges, auto-hybrid fallback, and
  default/no-PCRE rejection diagnostics without linking PCRE2;
- line-numbered `-P -n -o` output for those fixed lookaround/backreference
  shapes writes the numeric prefix directly in the same Darwin byte-output
  path, cutting representative fixed-lookbehind formatted output from
  10.717 s to 140.5 ms while preserving byte-identical Rust output;
- fixed PCRE2 count/count-matches/path/quiet modes now use the same direct
  byte scanner, cutting representative fixed-lookbehind count output from
  299.4 ms to 144.5 ms and restoring Rust-compatible silent `-q -c` output;
- fixed PCRE2 byte-offset and byte-column only-match formatting now writes the
  line/column/offset fields directly on the Darwin byte path, cutting
  representative fixed-lookbehind offset/column output from about 10.6 s to
  roughly 0.14 s while preserving Rust field ordering and byte-identical
  output;
- Darwin default recursive search remains capped at four workers because this
  checkout benchmarked faster than the ripgrep-style 12-worker cap on the
  Linux tree, while `--threads N` still lets callers override it.
  A 2026-05-25 smoke recheck with the 12-worker cap measured Swift
  `PM_RESUME` at 4.998 s versus 4.680 s for Rust on the same Linux tree, so
  the four-worker default remains the faster Darwin choice. Keeping that cap
  measured Swift `PM_RESUME` at 2.596 s versus 3.972 s for Rust in a 3-run
  smoke check.
- default ignore-aware `--files` now avoids constructing ignore debug
  summaries/source paths unless debug logging needs them and scans ignore rules
  through a borrowed buffer while preserving last-match-wins semantics. The fast
  `--files` stdout path also appends string UTF-8 bytes directly into its block
  buffer. A 2026-05-25 recheck measured Swift release `--files` at
  306.0 ms versus Rust release at 83.0 ms on `/tmp/swift-rg-bench/linux`, down
  from the prior 462.0 ms Swift smoke with byte-identical sorted output. The
  same recheck includes direct UTF-8 matching for the remaining exact
  path-component and ASCII contains ignore-glob fast paths, reuses directory
  path prefixes in the Darwin walker, decodes Darwin `dirent` names from their
  known `d_namlen` byte spans instead of scanning for a nul terminator, and
  avoids ignore-marker checks in the no-ignore/hidden file-list branch.
- executable no-ignore file listing now has a direct Darwin byte-output walker
  for both visible-only and hidden-inclusive modes. It copies `dirent` names as
  UTF-8 bytes, filters hidden names byte-wise when needed, writes ASCII paths
  without per-line `String` emission, keeps a reusable logical path byte buffer
  through recursion, and preserves the existing Swift traversal order. A
  2026-05-25 recheck measured Swift release `--no-ignore --files` at 167.4 ms
  versus Rust release at 73.3 ms and Swift release
  `--no-ignore --hidden --files` at 168.4 ms versus Rust release at 71.6 ms on
  `/tmp/swift-rg-bench/linux`, with byte-identical sorted output.
- The same direct no-ignore walker now keeps the recursive Darwin physical path
  as a UTF-8 byte buffer and writes ASCII output paths with direct `Data`
  buffer appends. A later 2026-05-25 15-run recheck measured Swift release
  `--no-ignore --files` at 167.2 ms and
  `--no-ignore --hidden --files` at 162.2 ms on the same Linux tree, preserving
  byte-identical sorted output while avoiding linked PCRE2 or any external
  dependency.
- No-ignore Darwin file listing now parallelizes independent top-level
  directory subtrees and emits their byte buffers in the same order as the
  previous sequential Swift writer. A same-machine 10-run A/B against
  checkpoint `faa52c3` measured Swift release `--no-ignore --files` at
  135.6 ms versus 167.1 ms on `/tmp/swift-rg-bench/linux`, with Rust at
  81.4 ms. The hidden-inclusive form measured 126.1 ms versus 171.4 ms, with
  Rust at 81.0 ms. Exact Swift output order matched the pre-change writer, and
  sorted output remained byte-identical to Rust.
- Default ignore-aware Darwin file listing now parallelizes independent
  top-level directory subtrees after loading root-local ignore files, then
  emits each ordered chunk through the existing output path. A same-machine
  10-run A/B against checkpoint `be6552c` measured Swift release `--files` at
  210.0 ms versus 291.6 ms on `/tmp/swift-rg-bench/linux`, with Rust at
  169.0 ms. The hidden-inclusive form measured 194.2 ms versus 284.8 ms, with
  Rust at 162.1 ms. Exact Swift output order matched the pre-change writer,
  and sorted output remained byte-identical to Rust.
- `--quiet --files` has an early-exit walker for the plain single-root Darwin
  path that checks files before descending once ignore files for the current
  directory are loaded. A 2026-05-25 7-run recheck measured Swift release at
  44.3 ms versus Rust release at 6.5 ms on `/tmp/swift-rg-bench/linux`, down
  from the 66.6 ms Swift no-PCRE2 checkpoint. Ignore setup and matching remain
  the largest traversal hotspot.
- Directory-local ignore loading now skips debug display-path rendering when
  debug/trace logging is disabled, and trusts ignore-file names already seen by
  the Darwin directory scan instead of repeating a `FileManager.fileExists`
  preflight. A same-machine 30-run A/B against checkpoint `4f40289` measured
  default Swift release `--files` at 323.9 ms versus 327.2 ms and
  `--quiet --files` at 49.5 ms versus 53.9 ms on `/tmp/swift-rg-bench/linux`.
- Darwin ignore matching now builds an in-process index for larger exact and
  simple basename/path rules, while complex rules still run through the
  last-match-wins reverse scan and can override indexed candidates. Normal
  traversal also avoids constructing hidden/ignore debug display paths unless
  debug or trace logging is enabled. A same-machine 15-run A/B against
  checkpoint `f443789` measured default Swift release `--files` at 299.8 ms
  versus 331.6 ms, and `--quiet --files` at 55.6 ms versus 66.4 ms on
  `/tmp/swift-rg-bench/linux`, with byte-identical sorted file-list output
  against Rust.
- Quiet no-ignore file listing now has a narrower existence-only Darwin walker.
  The same Linux tree measured `--no-ignore --hidden --quiet --files` at
  31.0 ms for Swift versus 5.3 ms for Rust, down from the prior 53.4 ms Swift
  smoke. Default quiet listing remains around 52 ms because it still needs the
  ignore stack.
- Ignore-aware `--quiet --files` now has a marker-first Darwin existence
  walker that loads local ignore files before scanning entries, avoids
  materializing per-directory child arrays, and exits as soon as an allowed
  file is found. A 30-run A/B against checkpoint `a386edc` measured Swift
  release at 37.0 ms versus 48.6 ms on `/tmp/swift-rg-bench/linux`.
- `--files` mode now constructs `StandardPrinter` only for the fallback path
  that needs rendered paths. The Darwin stream/byte-output fast paths and
  quiet existence path no longer pay for search-result formatting setup. A
  same-machine 20-run A/B against checkpoint `6104d57` measured Swift release
  `--quiet --files` at 9.2 ms versus 50.3 ms, `--files` at 129.2 ms versus
  163.5 ms, and `--no-ignore --files` at 81.1 ms versus 120.7 ms on
  `/tmp/swift-rg-bench/linux`. Exact Swift natural output remained
  byte-identical for default and no-ignore file listing, and quiet output
  remained empty with the same exit status.

### Initial no-C-shim investigation — 2026-05-26

Superseded by the checkpoint above after adding the Swift SIMD literal
scanners and no-shim Darwin preflight.

`SWIFT_RIPGREP_NO_C_SHIM=1` now builds and tests without the
`CRipgrepPlatform` target, so the portability experiment is mechanically
viable. It is not performance-competitive for the matcher hot path. Fresh
release checks on the same M3 Ultra and `/tmp/swift-rg-bench` corpora measured:

| Bench | Flags | c-shim Swift | no-c-shim Swift | no-c / c-shim |
|---|---|---:|---:|---:|
| literal, 193 MiB subtitles | `'Sherlock Holmes'` | 26.9 ms | 10.888 s | **405x slower** |
| `--files`, Linux tree | `--files` | 147.0 ms | 212.9 ms | **1.45x slower** |

The literal result confirms that removing the C shim gives up the NEON literal
scanner and buffered mmap stdout writer that closed the original
hundreds-of-times matcher gap. The file-listing result is much closer because
that path is dominated by traversal, metadata and ignore processing rather than
literal scanning. The raw hyperfine exports live under
`/tmp/swift-rg-bench/no-c-shim-literal-warm-*.json` and
`/tmp/swift-rg-bench/no-c-shim-files-warm-*.json`.

### Rejected A/B checks — 2026-05-25

The following plausible Darwin optimizations were measured against checkpoint
`9049084` and backed out because they were neutral-to-slower on the Linux-tree
benchmarks:

- Replacing the Swift ASCII `GlobMatcher.containsFast` loop with the vendored
  `rg_memmem_simple` C shim regressed a 30-run A/B: default `--files` measured
  330.6 ms versus 324.5 ms at baseline, and `PM_RESUME` measured 2.339 s
  versus 2.325 s.
- Lazily compiling `NSRegularExpression` fallbacks for ASCII simple-glob ignore
  rules also regressed the hot path: default `--files` measured 327.4 ms versus
  324.0 ms, and `--quiet --files` measured 51.0 ms versus 40.7 ms.
- Avoiding `String` decoding for regular-file entries in the quiet no-ignore
  existence walker did not pay off: `--no-ignore --hidden --quiet --files`
  measured 53.1 ms versus 49.3 ms, and visible-only no-ignore quiet measured
  51.2 ms versus 47.4 ms.
- Increasing file-list stdout batching from 64 KiB to 256 KiB was slower:
  default `--files` measured 332.4 ms versus 323.7 ms, and
  `--no-ignore --files` measured 181.1 ms versus 177.8 ms.
- Skipping hidden `dirent` names before kind classification in the visible-only
  no-ignore byte walker preserved output but did not improve the Linux-tree
  walker. A 30-run A/B against checkpoint `16ea768` measured
  `--no-ignore --files` at 178.0 ms versus 177.1 ms baseline, and
  `--no-ignore --hidden --files` at 179.2 ms versus 176.3 ms baseline.
- Routing default ignore-aware `--files` through a direct stdout byte writer
  instead of the existing string-emitting fast walker preserved sorted output
  but did not improve the Linux-tree benchmark. A 2026-05-25 7-run check
  measured Swift release `--files` at 338.5 ms versus the preceding 323.0 ms
  smoke on `/tmp/swift-rg-bench/linux`, with Rust at 159.8 ms and the existing
  Swift no-ignore direct writer at 167.8 ms.
- Replacing the Swift no-ignore byte walker with a whole-output C walker
  preserved byte-identical sorted output but was slower on the Linux tree. A
  2026-05-25 10-run check measured Swift release `--no-ignore --files` at
  177.8 ms and `--no-ignore --hidden --files` at 184.1 ms, versus the current
  Swift byte walker's ledgered 167.2 ms / 162.2 ms.
- Combining `dirent` name byte copying and ASCII/hidden flag detection into a
  manual Swift loop also regressed the no-ignore walker. A 2026-05-25 10-run
  check measured `--no-ignore --files` at 184.6 ms and
  `--no-ignore --hidden --files` at 181.2 ms, so the existing
  `Array(buffer)` plus `allSatisfy` path remains faster.
- Adding a first-byte prefilter before the small multi-literal line-output
  scanner preserved byte-identical output but regressed the 1.5 GiB subtitles
  `Sherlock|Watson` benchmark. A 2026-05-25 check measured Swift release at
  426.8 ms versus 315.6 ms for the current first+tail window scanner, with
  Rust at 300.5 ms.

## Historical baseline — 2026-05-24

## Single-file haystack (subtitles, 200 MiB ASCII text)

Slice of OpenSubtitles English (`en.sample.txt`, first 7 M lines ≈ 200 MiB).
Mirrors the `subtitles_en_*` family in upstream `benchsuite`.

| Bench | Flags | rg | swift-rg | swift / rg |
|---|---|---:|---:|---:|
| literal | `'Sherlock Holmes'` | 25.7 ms ± 0.7 | 22.255 s ± 0.095 | **866x** |
| literal, no-mmap | `--no-mmap 'Sherlock Holmes'` | 25.2 ms ± 0.8 | 31.901 s ± 0.012 | **1267x** |
| literal, case-insensitive | `-i 'Sherlock Holmes'` | 39.5 ms ± 0.6 | 22.929 s ± 0.053 | **580x** |
| word boundary | `-nw 'Sherlock Holmes'` | 28.7 ms ± 0.6 | 22.463 s ± 0.160 | **782x** |
| alternation, 5 literals | `-n 'A\|B\|C\|D\|E'` | 43.5 ms ± 0.2 | 53.238 s ± 0.274 | **1223x** |
| no-literal regex | `-n '\w+\s+Holmes\s+\w+'` | 31.1 ms ± 0.4 | 51.111 s ± 0.238 | **1645x** |

## Many-file haystack (Linux kernel checkout, ≈ 1.6 GiB across ~75 K files)

Shallow clone of `BurntSushi/linux` matching the `linux_*` family in upstream
`benchsuite`. Default recursive search (gitignore-aware, parallel walker).

| Bench | Flags | rg | swift-rg | swift / rg |
|---|---|---:|---:|---:|
| literal default | `PM_RESUME` | 3.758 s ± 0.194 | 208.808 s ± 0.020 | **56x** |

## Headline

**Swift port is functionally identical to Rust ripgrep (192/193 parity cases
byte-for-byte) but dramatically slower** — typically **600–1700x slower on
single-file matching** and **~50x slower on recursive multi-file searches**.

## Where the gap comes from

The Swift port matches Rust's *behaviour* but uses Foundation's
`NSRegularExpression` plus an in-process literal pre-scan, whereas the Rust
crate stack (`regex` / `regex-automata` / `aho-corasick` / `memchr`) ships
hand-vectorised AVX/NEON literal scanners, a SIMD-friendly DFA, and
multi-pattern Aho-Corasick automata. The result is a roughly two-order-of-
magnitude gap *per byte* on the matcher hot path:

- **Literal scan throughput.** Rust at ~25 ms / 200 MiB is doing ~8 GiB/s on
  a single core — SIMD memchr cadence. Swift at ~22 s for the same workload
  is ~9 MiB/s, i.e. byte-by-byte traversal in `NSRegularExpression`'s NFA
  walk. This explains the 800–1700× single-file factor.
- **mmap vs streaming.** Forcing `--no-mmap` slows Swift further (32 s vs 22 s)
  but barely moves rg (25 ms either way). mmap on the Swift side is doing
  what it can; the matcher dwarfs whatever the I/O layer saves.
- **Multi-file amortisation.** On the Linux kernel checkout, much of the wall
  time is the walker / gitignore / per-file open/stat cost, which both
  binaries pay. With a 32-core M3 Ultra both saturate cores, but Rust's
  matcher finishes each file in <1 ms while Swift takes 60+ ms; the ratio
  drops to ~50× because the file-walking floor is shared.

## What this means for "1:1 parity"

Correctness parity (which `Docs/PORTING.md` covers — 192/193 byte-identical
outputs against `rg`) is independent of throughput. The Swift port produces
the same answers; it just gets there slower because the underlying matcher
is decades behind Rust's `regex` crate on SIMD-friendly workloads.

Closing the perf gap would require either (a) wrapping a SIMD-vectorised
literal scanner like `aho-corasick` / `memchr` via a C shim, or (b)
replacing `NSRegularExpression` with a hand-written DFA in Swift. Both are
deep rewrites of the matcher subsystem and far larger than the porting
work captured in the rest of this repo.

## How to reproduce

See `bench/README.md` for corpus setup. Then:

```sh
hyperfine --warmup 1 --runs 2 \
    -n 'rg' "rg 'Sherlock Holmes' en.sample.txt > /dev/null" \
    -n 'swift-rg' "$SWIFT 'Sherlock Holmes' en.sample.txt > /dev/null"
```

Raw hyperfine JSON for each bench is in `bench/results/` after a run; the
table above was generated from `2026-05-24` measurements.
