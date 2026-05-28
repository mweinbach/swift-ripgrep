# Performance benchmark — Swift port vs Rust ripgrep

Direct head-to-head using the patterns, flags, and corpora from the upstream
`ripgrep/benchsuite` script. Run on **Apple M3 Ultra (32 cores), macOS 26.5**
with `hyperfine 1.20.0`, 1 warm-up iteration + 2 timed iterations per case.

- `rg`: `ripgrep 15.1.0` (release build, system install)
- `swift-rg`: `ripgrep 15.1.0 (rev 4519153e5e)` (release build,
  `.build/release/ripgrep` produced by `swift build -c release`)

## Swift-only word/case checkpoint — 2026-05-28

Single-literal `-w -i` now has an ASCII-only Darwin preflight that reuses the
Swift literal writer with word-boundary checks. It rejects non-ASCII haystacks
so Unicode word-boundary cases fall back to the existing matcher. Direct
release comparisons against Rust `rg` were byte-identical for output, line
numbers, counts, quiet mode, path-only mode, files-without-match, and a
Unicode-adjacent fallback fixture. Follow-ups extend the same ASCII-only guard
to single-literal `--count-matches -w -i` and multi-literal word/count modes,
also falling back for non-ASCII haystacks.

Benchmarks used `/tmp/swift-rg-bench/stop-on-nonmatch-small.txt`, a 4.8 MiB
dense ASCII fixture, with 2 warmups and 5 timed runs:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-w -i NEEDLE` | 2.122 s | 11.3 ms | 14.5 ms |
| `-n -w -i NEEDLE` | 209.3 ms | 11.9 ms | 19.2 ms |
| `-c -w -i NEEDLE` | 136.4 ms | 7.4 ms | 12.2 ms |
| `--count-matches -w -i NEEDLE` | 154.8 ms | 25.0 ms | 40.1 ms |
| `-c -w -i "NEEDLE\|QUIET"` | 184.8 ms | 24.0 ms | 12.3 ms |
| `--count-matches -w -i "NEEDLE\|QUIET"` | 173.8 ms | 24.9 ms | 57.1 ms |
| `-q -w -i NEEDLE` | 99.3 ms | 5.2 ms | 2.7 ms |
| `-l -w -i NEEDLE` | 125.7 ms | 5.7 ms | 2.7 ms |

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

The ordered parallel file-listing merge now counts each completed chunk in bulk
while preserving per-line emission order. A 100-run A/B on the same Linux tree
preserved exact Swift output and measured default `--files` at 134.0 ms mean /
128.3 ms median versus the previous checkpoint at 137.1 ms mean / 133.7 ms
median; `--hidden --files` measured 134.3 ms mean / 130.6 ms median versus
135.7 ms mean / 133.3 ms median.

Hidden-entry include checks now skip the ignore-stack walk when the active stack
has no include rules. A 100-run confirmation on the same Linux tree preserved
exact Swift output and sorted Rust parity, measuring default `--files` at
120.4 ms mean / 119.6 ms median versus 124.5 ms mean / 123.6 ms median before;
`--hidden --files` measured 121.0 ms mean / 120.2 ms median versus 124.0 ms mean
/ 122.6 ms median.

Ignore-file parsing now returns the raw line split directly instead of trimming
and checking every line before appending the same raw text anyway. `GlobMatcher`
continues to filter empty and comment lines at rule construction. A 100-run
confirmation on the Linux tree preserved exact Swift output and sorted Rust
parity, measuring default `--files` at 137.2 ms mean / 136.5 ms median versus
139.0 ms mean / 139.7 ms median before; `--hidden --files` measured 130.3 ms
mean / 129.3 ms median versus 133.5 ms mean / 134.0 ms median.

Ignore matcher construction now collapses adjacent duplicate rules after blank
and comment lines are skipped, preserving last-match behavior because the
duplicates have the same pattern, decision, and case-sensitivity. This removes
repeated global-ignore rules from the hot stack. Exact Swift output and sorted
Rust parity were preserved. A 150-run order-flipped default check measured
`--files` at 112.0 ms mean / 109.0 ms median versus 118.1 ms mean / 114.8 ms
median before; a 100-run hidden check measured `--hidden --files` at
114.0 ms mean / 109.8 ms median versus 118.9 ms mean / 115.9 ms median before.

The matcher constructor now records include-rule and basename-only-rule flags
while appending rules, instead of rescanning the completed rule array and then
rescanning again when an `IgnoreStack` appends the matcher. Exact Swift output
and sorted Rust parity were preserved. A 100-run confirmation measured default
`--files` at 113.3 ms mean / 109.5 ms median versus 115.7 ms mean / 112.2 ms
median before; `--hidden --files` measured 113.2 ms mean / 108.4 ms median
versus 114.5 ms mean / 110.3 ms median before.

Slash-containing exact ignore patterns are now included in the Darwin fast rule
index. Anchored/root-relative rules still use exact-path lookup, while
match-anywhere slash rules also get a path-component suffix bucket, avoiding
fallback matcher checks for common rules such as `foo/bar`. Exact Swift output
and sorted Rust parity were preserved. A clean 100-run order-flipped check
measured default `--files` at 119.1 ms mean / 117.7 ms median versus 124.1 ms /
122.6 ms before; `--hidden --files` was neutral at 124.2 ms mean / 120.5 ms
median versus 123.0 ms / 120.8 ms before. A follow-up guard now skips the
suffix-path lookup entirely when the index has no suffix path buckets,
preserving exact output and measuring default `--files` at 117.9 ms mean /
117.4 ms median versus 120.2 ms / 118.7 ms before; `--hidden --files` measured
119.1 ms mean / 118.7 ms median versus 120.3 ms / 119.0 ms before.

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
66.1 ms for Rust.

Unbounded plain and line-numbered multi-literal single-file output now routes
through the same Swift-only mmap/stdout helper when the C shim is unavailable.
It preserves exact output while avoiding the previous full collect/sort writer.
On a 252 MiB synthetic dense `Sherlock|Watson` corpus, a 30-run A/B measured
the new path at 263.9 ms mean versus 1.364 s before and 200.6 ms for Rust; a
post-stats-patch 10-run confirmation measured 260.9 ms versus 1.358 s before.
On a 23 MiB generated Linux register header, a 50-run A/B for `REG|MASK`
measured 46.2 ms mean versus 56.4 ms before and 14.4 ms for Rust. The direct
result now reports full-file bytes searched when the unbounded scan exhausts
the file, matching Rust stats on the synthetic check.

The executable Swift-only preflight now recognizes the same simple
multi-literal alternations before full CLI/searcher setup, while still
respecting escaped pipes, grouped/classed regexes, word mode, and
case-insensitive fallbacks. Output for plain dense `Sherlock|Watson`,
line-numbered `REG|MASK`, and escaped `a\|b` checks matched both the previous
Swift binary and Rust. A 30-run synthetic dense check measured 227.0 ms mean
versus 255.3 ms before and 201.1 ms for Rust; the 23 MiB line-numbered Linux
header measured 20.6 ms mean versus 45.6 ms before and 18.8 ms for Rust.

The Swift executable preflight parser now recognizes clustered short flags made
only from `-i`, `-n`, and `-w`, so common forms such as `-ni` reach the same
Swift-only mapped literal writer as `-n -i`. Output for `-ni Sherlock` and
`--no-mmap -ni Sherlock` on the 252 MiB dense fixture matched both the previous
Swift binary and Rust. Ten-run checks measured `-ni Sherlock` at 212.3 ms
versus 363.2 ms before and 503.0 ms for Rust; the `--no-mmap -ni` form
measured 224.7 ms versus 401.6 ms before and 529.6 ms for Rust.

The same parser now treats `-N`/`--no-line-number` as ordered line-number
toggles, including clustered forms such as `-nN` and `-Nn`, so explicit
no-line-number single-file searches can still use the Swift mapped preflight.
Output for `-N Sherlock`, `-n -N Sherlock`, and clustered ordering checks on
the 252 MiB dense fixture matched the previous Swift binary and Rust. Ten-run
checks measured `-N Sherlock` at 177.0 ms versus 298.4 ms before and 267.7 ms
for Rust; the long `--no-line-number` spelling measured 169.1 ms versus
300.0 ms before and 265.0 ms for Rust.

Output-neutral single-file flags now also stay eligible for the Swift
executable preflight. The parser ignores `--no-heading`, `--no-filename`, and
`--no-messages` only for the preflight eligibility check, leaving positive
formatting flags on the full CLI path. Output for all three flags on the
252 MiB dense fixture matched both the previous Swift binary and Rust. A noisy
ten-run check measured `--no-heading Sherlock` at 190.3 ms versus 337.8 ms
before and 280.5 ms for Rust, `--no-filename` at 197.8 ms versus 304.2 ms
before, and `--no-messages` at 200.3 ms versus 324.5 ms before.

Ordered case-sensitivity toggles now also flow through the executable
preflight. The parser treats `-s`/`--case-sensitive` as the inverse of
`-i`/`--ignore-case`, including clustered forms where the last case toggle wins
(`-is` stays case-sensitive and `-si` returns to ignore-case). Output for
`-i -s Sherlock`, `-is Sherlock`, and `-si sherlock` on the 252 MiB dense
fixture matched both the previous Swift binary and Rust. A clean ten-run split
rerun measured `-i -s Sherlock` at 193.5 ms versus 306.5 ms before and
283.2 ms for Rust; clustered checks measured `-is Sherlock` at 196.5 ms versus
303.5 ms before, and `-si sherlock` at 195.8 ms versus 321.1 ms before.

Smart-case toggles now use the same ordered case-mode parser. The executable
preflight accepts `-S`/`--smart-case`, keeps the last `-i`/`-s`/`-S` toggle
semantics for separate and clustered flags, and decides smart-case from the raw
pattern before dispatching to the mapped literal writer. Output for
`-S Sherlock`, `-S sherlock`, `--smart-case sherlock`, `-i -S Sherlock`,
`-S -i Sherlock`, `-iS Sherlock`, and `-Si Sherlock` on the 252 MiB dense
fixture matched both the previous Swift binary and Rust. A ten-run check
measured `-S Sherlock` at 203.8 ms versus 327.9 ms before and 284.8 ms for
Rust; the lowercase smart-case form measured 212.1 ms versus 318.0 ms before
and 366.8 ms for Rust.

Explicit `--mmap` now stays eligible for the executable preflight as an ordered
inverse of `--no-mmap`, so regular-file single-literal searches avoid falling
back to full CLI setup just because mapped mode was requested explicitly.
Output for `--mmap Sherlock`, `--mmap -n -i Sherlock`,
`--no-mmap --mmap Sherlock`, and `--mmap --no-mmap Sherlock` on the 252 MiB
dense fixture matched both the previous Swift binary and Rust. A ten-run check
measured `--mmap Sherlock` at 206.9 ms versus 321.4 ms before and 298.6 ms for
Rust; `--mmap -n -i Sherlock` measured 285.3 ms versus 443.0 ms before and
563.4 ms for Rust.

Fixed-string and single explicit-regexp forms now feed the executable preflight
too. The parser accepts `-F`/`--fixed-strings`, ordered
`--no-fixed-strings`, clustered `-Fi`, single `-e`/`--regexp` pattern sources,
inline regexp values, `--no-config`, and `--` leading-dash patterns. Dense-fixture
byte checks for `-F Sherlock`, `-Fi sherlock`, fixed no-match pipes,
`-e Sherlock`, `--regexp=Sherlock`, `-n -i -e Sherlock`, and unsupported repeated
`-e` fallback matched both the previous Swift binary and Rust, with matching exit
status. Focused fixtures also cover fixed metacharacter literals,
`--no-fixed-strings` regex fallback, and leading-dash patterns. Ten-run checks
measured `-F Sherlock` at 218.4 ms versus 392.7 ms before and 312.0 ms for
Rust; `-Fi sherlock` at 226.9 ms versus 340.9 ms before and 412.5 ms for Rust;
`-e Sherlock` at 207.9 ms versus 336.0 ms before and 289.5 ms for Rust; and
`-n -i -e Sherlock` at 281.4 ms versus 458.5 ms before and 572.1 ms for Rust.

Repeated explicit-regexp forms whose patterns reduce to bounded non-empty
literal bytes now reuse the existing multi-literal executable preflight instead
of falling back to full CLI setup. This covers plain and line-numbered matching
lines, filename and heading prefixes, path-only modes, quiet checks, fixed-string
patterns, and explicit patterns that themselves contain safe literal
alternations; case-insensitive line output and semantic modes like word-regexp,
line-regexp, and counts still fall back. Dense-fixture byte checks for
`-e needle -e quiet`, `-n -e needle -e quiet`,
`--with-filename -e needle -e quiet`,
`--heading --with-filename -e needle -e quiet`,
`--files-without-match -e absent -e missing`, `-q -e needle -e quiet`,
`-i -q -e needle -e quiet`, `-F -e 'needle needle' -e 'quiet line'`, and
`-e 'needle|tail' -e quiet` matched Rust. On the 50 KiB dense fixture,
`-e needle -e quiet` measured 4.3 ms versus 31.6 ms before and 2.8 ms for Rust,
while `-n -e needle -e quiet` measured 3.2 ms versus 26.9 ms before and 2.8 ms
for Rust.

Literal-only pattern files now feed the same executable preflight. The parser
accepts separated `-f`/`--file`, inline `--file=...`, short `-fPATH`, and mixed
explicit `-e` plus `-f` sources when the loaded patterns reduce to bounded
non-empty literal bytes; unreadable files, stdin pattern files, empty pattern
sets, and semantic modes outside the existing multi-literal preflight still
fall back. Dense-fixture byte checks matched Rust for plain, line-numbered,
filename/heading, path-only, files-without-match, quiet, ASCII ignore-case quiet,
fixed-string pattern files, literal alternation pattern lines, one-pattern
files, and mixed `-e`/`-f` forms. On the 50 KiB dense fixture, `-f patterns.txt`
measured 6.0 ms versus 35.3 ms before and 2.7 ms for Rust, while
`-n -f patterns.txt` measured 5.2 ms versus 35.3 ms before and 2.8 ms for Rust.

Positive `-m`/`--max-count` now stays on the executable multi-literal preflight
for safe alternations, repeated explicit regexps, and literal-only pattern
files. The public Swift preflight wrapper now passes the existing bounded
`maxCount` through to the mapped multi-literal writer; `-m0` and unsupported
semantic modes still fall back. Dense-fixture byte checks matched Rust for
plain, line-numbered, filename-prefixed, heading-prefixed, pattern-file, and
single-pattern alternation forms. On the 50 KiB dense fixture,
`-m2 -e needle -e quiet` measured 4.1 ms versus 32.0 ms before and 2.6 ms for
Rust, while `-n -m2 -f patterns.txt` measured 4.8 ms versus 36.7 ms before and
2.5 ms for Rust.

Multi-literal count output now reuses that same mapped writer without emitting
matched lines, then prints only the matched-line count summary. This covers
unbounded `-c` and bounded `-c -mN`/`--count --max-count N` for safe
alternations, repeated explicit regexps, and literal-only pattern files, while
`-m0`, quiet precedence, ASCII ignore-case fallback, and unsupported semantic
modes stay on prior behavior. Dense-fixture byte checks matched Rust for
repeated-regexp, pattern-file, single-pattern alternation, include-zero
no-match, CRLF summary, quiet-count, filename-prefixed, heading-prefixed,
NUL-prefixed, path-separated, ASCII ignore-case fallback, and zero-count forms.
On the 50 KiB dense fixture, unbounded `-c -e needle -e quiet` measured 4.4 ms
versus 56.2 ms before and 2.8 ms for Rust, while unbounded `-c -f patterns.txt`
measured 4.8 ms versus 45.6 ms before and 2.7 ms for Rust. The bounded
`-c -m2 -e needle -e quiet` measured 4.4 ms versus 22.7 ms before and 2.5 ms
for Rust, while `-c -m2 -f patterns.txt` measured 4.6 ms versus 38.9 ms before
and 2.8 ms for Rust; the neighboring `-H -c -m2 -e needle -e quiet` measured
4.3 ms versus 2.5 ms for Rust while preserving the required path prefix.

Traversal-only flags that do not affect an explicit regular file now stay
eligible for the executable preflight. The parser treats hidden, ignore-family,
require-git, and one-file-system toggles as neutral only in this single-path
preflight shape. Dense-fixture output for `--hidden --no-ignore Sherlock`,
`--no-hidden --ignore Sherlock`, `-. -F Sherlock`, ignore-family toggles, and
one-file-system toggles matched both the previous Swift binary and Rust, with
matching exit status; focused fixtures also cover explicit hidden and ignored
files. Ten-run checks measured `--hidden --no-ignore Sherlock` at 211.7 ms
versus 336.9 ms before and 288.9 ms for Rust; the
`--ignore-dot --ignore-vcs --require-git Sherlock` form measured 235.2 ms
versus 383.6 ms before and 307.0 ms for Rust.

Explicit-file ignore-file controls now also stay eligible when they cannot
change the searched operand. The parser accepts existing readable regular
`--ignore-file` paths, `--ignore-file-case-insensitive`, `--ignore-files`, and
final `--no-ignore-files` states that suppress missing ignore-file diagnostics;
missing enabled ignore-file paths still fall back. On the 45 MiB fixture,
`--ignore-file <existing> needle` improved from 86.8 ms to 36.0 ms, versus
42.5 ms for Rust, while `--ignore-file-case-insensitive needle` measured
35.4 ms, versus 46.7 ms for Rust.

Output-neutral formatting disables and explicit block-buffering are parsed
conservatively in the same preflight. The parser tracks ordered formatting
toggles and only dispatches when the final state does not request filenames,
headings, byte offsets, columns, trimming, or color; explicit streaming
`--line-buffered` now stays eligible for explicit-file byte-equivalent line
output. Dense-fixture output and exit status for `--messages`,
`--block-buffered`, `--no-line-buffered`, `--no-byte-offset`, `--no-column`,
`--no-trim`, `--color=never`, `--with-filename --no-filename`,
`--heading --no-heading`, `--column --no-column`,
`--byte-offset --no-byte-offset`, `--trim --no-trim`, and
`--color=always --color=never` matched both the previous Swift binary and
Rust. Later reset checks also covered `--pretty`/`-p` when color, heading, and
line numbering are all reset before the pattern. Ten-run checks on the 252 MiB
dense fixture measured the combined neutral-format form at 258.3 ms versus
359.7 ms before and 329.1 ms for Rust; `--block-buffered --messages Sherlock`
measured 265.3 ms versus 355.6 ms before and 308.7 ms for Rust;
`--no-line-buffered Sherlock` measured 235.1 ms versus 349.6 ms before and
335.7 ms for Rust. On the 45 MiB fixture,
`--pretty --color=never --no-heading -N needle` improved from 83.1 ms to
36.8 ms, versus 43.6 ms for Rust, and
`-p --color=never --no-heading -N needle` improved from 79.1 ms to 33.8 ms,
versus 42.4 ms for Rust.
Valid `--colors` specs now stay on the same path when final color output is
disabled, while invalid specs continue through the full parser for diagnostics.
On the 45 MiB fixture, `--colors match:fg:red --color=never needle` improved
from 78.1 ms to 34.8 ms, versus 43.9 ms for Rust, and
`--colors match:none --color=never needle` improved from 89.4 ms to 34.6 ms,
versus 46.8 ms for Rust.
Quiet, path-only, and count output are now allowed to reuse the executable
preflight with `--line-buffered`, since no streaming matching-line flushes are
observable in those modes. On the 45 MiB fixture, `--line-buffered -q needle`
improved from 27.9 ms to 5.3 ms, versus 3.0 ms for Rust;
`--line-buffered -l needle` improved from 43.7 ms to 4.1 ms, versus 3.3 ms for
Rust; and `--line-buffered -c -m1 needle` improved from a forced fallback at
33.9 ms to 4.0-5.7 ms, versus 3.2 ms for Rust.
Matching-line output now also accepts `--line-buffered` for single explicit
file searches. Focused coverage checks literal, numbered literal, bounded
literal, multi-literal, and surrounding-word preflight output under the flag,
and direct release byte checks matched Rust for literal, numbered, bounded,
multi-literal, reset, and CRLF combinations. On the 50 KiB dense fixture,
`--line-buffered needle` improved from 29.3 ms before this slice to 3.3 ms,
versus 3.5 ms for Rust; `--line-buffered -n needle` measured 3.0 ms.
Ordered print-mode overrides now update the executable preflight eligibility
with last-flag-wins semantics when the final mode is path-only. Final
short clusters that mix count and path modes and unbounded final count output
still fall back. On the 45 MiB fixture,
`--count --files-with-matches needle` improved from 28.5 ms to 6.4 ms, versus
3.6 ms for Rust, and `--count-matches --files-with-matches needle` improved
from 32.2 ms to 4.2 ms, versus 3.3 ms for Rust.

Executable preflight now handles final `--count-matches` for single
case-sensitive literal searches with a mapped Swift counter, including final
print-mode overrides, explicit single `-e`, filename-prefixed summaries,
include-zero no-match summaries, and binary/text files. Case-insensitive,
bounded, line-regexp, and multi-literal count-matches forms stayed on the prior
fallback at this checkpoint. On the 50 KiB dense fixture,
`--count-matches needle` measured 8.8 ms versus 41.1 ms before and 3.7 ms for
Rust; final `--files-with-matches --count-matches needle` measured 8.0 ms
versus 53.2 ms before; and `-H --count-matches needle` measured 7.9 ms versus
57.7 ms before.

The same mapped counter now covers safe multi-literal count-matches inputs from
repeated explicit regexps, simple alternations, and literal-only pattern files.
The preflight first deduplicates identical literals and proves that distinct
literals cannot overlap or contain one another, so ambiguous ordered-overlap
cases stay on the prior fallback. Dense-fixture byte checks matched Rust for
repeated-regexp, alternation, pattern-file, filename-prefixed, and include-zero
no-match forms; overlapping `aa`/`a` controls stayed on the prior fallback. On
the 50 KiB dense fixture, `--count-matches -e needle -e quiet` measured 9.6 ms
versus 54.0 ms before and 3.6 ms for Rust,
`--count-matches 'needle|quiet'` measured 10.1 ms versus 3.7 ms for Rust,
while `--count-matches -f patterns.txt` measured 10.1 ms and
`-H --count-matches -f patterns.txt` measured 10.2 ms.

That counter now uses the existing Swift fallback literal scanner instead of a
per-match `Data.range(of:)` loop, which removes the dense-match regression on
larger files while keeping the default no-C-shim build. The same scanner also
covers conservative ASCII word-boundary `--count-matches` by proving candidate
boundaries before writing output; ambiguous non-ASCII boundaries and
boundary-heavy false positives still fall back. Byte/status checks matched Rust
for plain, word-boundary, prefixed, include-zero, embedded-word, and binary
forms. On the 48 MiB dense fixture, `--count-matches needle` measured 35.4 ms
versus 1.089 s before and 109.3 ms for Rust; `--count-matches -w needle`
measured 43.1 ms versus 1.142 s before and 250.4 ms for Rust; and safe
multi-literal `--count-matches -e needle -e quiet` measured 44.5 ms, with
`--count-matches 'needle|quiet'` at 43.7 ms, versus 195.6 ms for Rust.

Word-boundary count-line output now uses the same conservative scanner without
emitting matching lines. It counts each matching line once, skips the rest of a
line after a proven bounded match, honors `-m`, and falls back before printing
for ambiguous boundaries. Byte/status checks matched Rust for plain, prefixed,
bounded, include-zero, embedded-word, and binary forms. On the 48 MiB dense
fixture, `-c -w needle` improved from 1.142 s to 17.2 ms, versus 53.8 ms for
Rust; bounded `-c -m2 -w needle` measured 4.0 ms, versus 2.8 ms for Rust.

Multi-literal word-boundary count summaries now use the same no-output scanner
for simple alternations, repeated explicit regexps, and literal pattern files.
Count-line mode counts each line once after the first bounded literal, while
count-matches mode keeps the existing non-overlap proof before summing bounded
literal totals. Byte/status checks matched Rust for alternation, pattern-file,
bounded count-line, include-zero, embedded-word, and overlapping count-matches
fallback controls. On the 48 MiB dense fixture, `-c -w 'needle|quiet'`
improved from 1.373 s to 45.1 ms, versus 67.6 ms for Rust;
`--count-matches -w 'needle|quiet'` improved from 1.367 s to 50.0 ms, versus
373.2 ms for Rust. The pattern-file forms measured 46.6 ms and 52.0 ms.

`--include-zero` now stays on the executable literal preflight for normal
matching-line output, where it only affects count summaries. Focused tests
cover plain output, `-n`, and `--include-zero --no-include-zero`; byte checks
also covered NUL-containing binary fallback and `-c`/`--count-matches`
zero-match forms against Rust. On a 45 MiB dense fixture,
`--include-zero needle` improved from 87.8 ms to 34.9 ms, versus 43.1 ms for
Rust, while plain `needle` on the same current binary measured 38.2 ms.

Exact unrestricted forms now also use the executable literal preflight for
explicit file searches. The parser counts `-u`, `-uu`, `-uuu`, and
`--unrestricted` repeats so a fourth unrestricted flag still falls through to
the normal parser error. Focused tests cover each accepted form, long repeated
forms with `-n`, and NUL-containing binary fallback; release byte checks also
compared the fourth-`-u` error path with Rust. On the 45 MiB dense fixture,
`-u needle` improved from 84.5 ms to 34.9 ms, and `-uuu needle` improved from
1.438 s to 34.9 ms, versus 43.5 ms for Rust `-uuu`.

Short unrestricted clusters now share the same counted preflight path.
Focused coverage includes `-un`, `-nuu`, combined exact-plus-cluster repeats,
`-uuuF`, NUL-containing binary fallback, and over-repeated cluster errors. On
the same fixture, `-un needle` improved from 121.7 ms to 54.7 ms, versus
84.7 ms for Rust, and `-uuuF needle` improved from 1.438 s to 35.4 ms.

Explicit-file sort flags are now validated as traversal-order no-ops for the
executable preflight. This covers `--sort`/`--sortr` values `none`, `path`,
`modified`, `accessed`, and `created`, plus `--sort-files`, while invalid sort
values still fall through to the normal parser error. On the same fixture,
`--sort path needle` improved from 1.459 s to 35.0 ms, and `--sort-files needle`
improved from 1.438 s to 37.1 ms, versus 45.0 ms for Rust
`--sort path`.

Engine selector flags now update the Swift executable preflight wherever they
appear instead of only when they lead the command. This covers `-P`/`--pcre2`,
`--no-pcre2`, `--auto-hybrid-regex`/`--no-auto-hybrid-regex`,
`--engine`/`--engine=`, and `P` inside short clusters, while invalid engine
values still fall through to the normal parser diagnostic. Focused coverage
includes non-leading selectors, ordering with `--no-pcre2`, short-cluster
`-Pn`, and PCRE quoted literals. On the 45 MiB dense fixture, `-n -P needle`
improved from 115.8 ms to 51.2 ms, and `-Pn needle` improved from 110.9 ms to
50.6 ms, versus 94.5 ms for Rust `-n -P`.

Explicit-file follow toggles now stay on the Swift executable preflight as
well. This covers `--follow`, `--no-follow`, `-L`, and `L` inside short
clusters, with symlink operand parity checked against Rust. On the same
fixture, `--follow needle` improved from 6.177 s to 38.6 ms,
`--no-follow needle` improved from 87.9 ms to 36.9 ms, and `-Ln needle`
improved from 1.762 s to 54.1 ms, versus 48.3 ms for Rust `--follow`.

Output-neutral metadata flags now stay preflight-eligible when their values
cannot affect the matching-line stream. This covers known
`--hyperlink-format` aliases or empty values while filenames are suppressed,
plus empty `--pre`/`--pre=` and `--no-pre`; custom hyperlink formats,
invalid aliases, and non-empty preprocessors still fall through to the normal
parser. On the same fixture, `--hyperlink-format=grep+ needle` improved from
1.515 s to 38.2 ms, and `--pre= needle` improved from 88.3 ms to 37.9 ms,
versus 48.7 ms for Rust `--hyperlink-format=grep+`.

Preprocessor globs now stay preflight-eligible when no active preprocessor can
consume them. The parser validates `--pre-glob` with the same unclosed-class
check as the full option parser, and still falls back for invalid globs or any
non-empty `--pre` command. On the same fixture, `--pre-glob '*.pdf' needle`
improved from 6.211 s to 35.0 ms, versus 48.3 ms for Rust.

Explicit-file override globs now use the same preflight treatment. Valid
`-g`/`--glob`/`--iglob` values do not filter an explicit file operand, while
invalid glob syntax still falls through to the normal parser diagnostic. On the
same fixture, `-g '*.nomatch' needle` improved from 6.343 s to 38.0 ms,
versus 46.8 ms for Rust.

Quiet explicit-file literal searches now use a contains-only Swift mmap
preflight that writes nothing and stops at the first match. Unsupported
word-boundary/statistics forms still fall through to the normal searcher. On
the same fixture, `-q needle` improved from 28.3 ms to 3.9 ms, versus 3.1 ms
for Rust. A no-match quiet scan improved from 40.5 ms to 21.0 ms, versus
8.1 ms for Rust.

Path-only explicit-file searches now share the same high-level mapped contains
check. `-l`/`--files-with-matches` prints the operand path on the first match,
and `--files-without-match` prints it only when no match is found, including
the `--null` path terminator. Unsupported word-boundary, ignore-case, custom
path-separator, and statistics forms still fall through. On the same fixture,
`-l needle` improved from 32.8 ms to 5.0 ms, versus 3.5 ms for Rust, while
`--files-without-match absent_literal` improved from 45.5 ms to 21.5 ms,
versus 9.3 ms for Rust.

ASCII word-boundary quiet and path-only searches now use a conservative
Swift-first mapped existence check. It accepts only literals whose first and
last bytes are ASCII regex word bytes, falls back on non-ASCII candidate
boundaries or early binary detection, and bails back to the full searcher after
128 rejected boundary candidates so embedded-substring no-match cases do not
regress. On the same fixture, `-q -w needle` improved from 762.8 ms to 3.3 ms,
versus 2.8 ms for Rust, and `-l -w needle` improved from 1.968 s to 3.7 ms,
versus 2.8 ms for Rust. Absent word no-match checks measured 26.2-26.4 ms,
versus 6.6 ms for Rust. The boundary-heavy `-w eed` substring no-match falls
back and stayed effectively tied with the full Swift path at 134.6 ms for
quiet and 165.6 ms for path-only.

Small multi-literal quiet and path-only alternations now avoid the line-output
multi-literal writer and use a bounded high-level mapped contains check for up
to eight alternatives. This fixes the previous default-path parity leak where
`-q 'needle|tail'` and `-l 'needle|tail'` printed matching lines, while the
core direct stdout path now also declines quiet mode when config disables the
executable preflight. On the same fixture, `-q 'needle|tail'` now emits no
stdout and measures 2.9 ms, versus 2.4 ms for Rust; `-l 'needle|tail'` emits
only the file path and measures 3.4 ms, versus 2.5 ms for Rust. The two-literal
no-match form measured 59.3-62.2 ms, versus 8.8 ms for Rust.

Case-insensitive quiet and path-only searches now have a conservative
Swift-first match-only preflight. It probes exact, lowercase, and uppercase
ASCII literal variants through mapped `Data` and falls back whenever those
checks cannot prove a match, so no-match and mixed-case-only haystacks stay on
the full searcher. The executable parser also recognizes clustered lowercase
`l`, so common forms such as `-li NEEDLE` reach the same path-only route. On
the same fixture, `-qi NEEDLE` improved from 113.8 ms to 11.0 ms, versus
3.1 ms for Rust; `-li NEEDLE` measured 10.8 ms, versus 2.7 ms for Rust; and
`-li 'NEEDLE|TAIL'` improved from 2.434 s to 10.7 ms, versus 3.0 ms for Rust.
Alphabetic no-match forms still fall back and measured 60.2-83.7 ms.
No-letter ASCII ignore-case literals now prove no-match because their
case-folded variants collapse to the original bytes. On the 45 MiB fixture,
`-q -i 1234567890` improved from 43.9 ms to 9.9 ms, versus 6.2 ms for Rust;
`-l -i 1234567890` improved from 39.5 ms to 9.3 ms, versus 7.0 ms for Rust;
and `--files-without-match -i 1234567890` improved from 40.8 ms to 9.2 ms,
versus 7.1 ms for Rust.

Positive `-m`/`--max-count` explicit-file literal searches now have a bounded
Swift line-output preflight. It uses high-level mapped `Data` searches, emits
each matching line at most once, preserves optional line numbers, and falls
through for zero counts, word-boundary/case-folded forms, and early binary
detection. On the same fixture, `-m1 needle` improved from 81.6 ms to 2.9 ms,
matching Rust at 2.9 ms. A no-match `-m1 absent_literal` scan improved from
84.1 ms to 18.0 ms, versus 6.0 ms for Rust.

Bounded count output now reuses the same Swift-first max-count idea for
`-c -mN`/`--count --max-count N` literal searches. The earlier high-level
unbounded count attempt stayed off because repeated line counting regressed that
case. On the same fixture, `-c -m1 needle` improved from 26.4 ms to 3.3 ms,
versus 3.0 ms for Rust.

Unbounded case-sensitive single-literal count output now uses the mapped
literal writer that proved fast for multi-literal counts, with a one-literal
input list and line emission disabled. This covers plain `-c`, line-buffered
count, CRLF summaries, include-zero no-match summaries, and filename-prefixed
count output, while case-folded, word-boundary, and exact-line prefixed counts
stay on prior behavior. On the 50 KiB dense fixture, `-c needle` measured
5.0 ms versus 29.8 ms before and 3.1 ms for Rust, `--line-buffered -c needle`
measured 4.2 ms versus 34.3 ms before, and `-H -c needle` measured 3.7 ms
versus 34.4 ms before; the bounded prefixed `-H -c -m2 needle` measured 3.4 ms.

Case-insensitive `-c -m1` literal and exact-line searches now share a
match-only Swift preflight. When a mapped ASCII exact/lower/upper probe proves a
match, the count is known to be `1`; otherwise no-match and mixed-case-only
cases fall back to the full searcher. On a 45 MiB fixture, `-c -m1 -i NEEDLE`
measured 11.0 ms, versus 2.5 ms for Rust, and `-c -m1 -i -x 'NEEDLE NEEDLE
NEEDLE QUIET TAIL NEEDLE'` measured 7.3 ms, versus 2.8 ms for Rust. On a
3.7 MiB exact-line fixture, the exact-line count form improved from a forced
fallback at 1.490 s to 4.1 ms.

Filename-prefixed count summaries now reuse that same count-prefix formatting in
the exact-line and bounded ASCII case-insensitive count helpers. This covers
`-H -c -x`, NUL-prefixed count summaries, include-zero prefixed exact-line
summaries, and bounded `-H -c -m1 -i`/`-ix` forms, while unbounded
case-insensitive counts stay on the prior fallback. On the 50 KiB exact-line
fixture, `-H -c -x needle` measured 7.6 ms versus 84.4 ms before and 3.4 ms for
Rust, `-H -c -m1 -x needle` measured 3.9 ms versus 58.2 ms before, and
`-H -c -m1 -ix NEEDLE` measured 4.0 ms versus the previous prefixed fallback.

Clustered short count flags now reach the same executable preflight parser, so
common spellings like `-ci -m1 NEEDLE` and `-cix -m1 ...` no longer fall back
just because `c` was packed into the short-flag cluster. On the same 45 MiB
fixture, `-ci -m1 NEEDLE` now measures 11.0 ms, versus the pre-change clustered
route at 26.6 ms and Rust at 2.6 ms. On the 3.7 MiB exact-line fixture,
`-cix -m1 'NEEDLE NEEDLE NEEDLE QUIET TAIL NEEDLE'` measures 3.7 ms, versus the
earlier forced fallback at 1.490 s and Rust at 2.8 ms.

Exact line-regexp literals now get a Swift-first executable preflight for
`-x`/`--line-regexp` when CRLF mode and formatted output modes are inactive.
The scanner uses mapped `Data`, searches for `literal + "\\n"` in the common
no-line-number path, preserves `-n` and positive `-m`, and falls through for
`--crlf`, quiet/path-only forms, unsupported count variants, and early binary
detection. On the same fixture, `-x 'needle needle needle quiet tail needle'`
improved from 13.783 s to 397.9 ms, versus 115.5 ms for Rust. A no-match
exact-line scan improved from 2.241 s to 22.5 ms, versus 8.1 ms for Rust.

Exact line count output now uses the same full-line scanner without emitting
matched lines. On the same fixture,
`-c -x 'needle needle needle quiet tail needle'` improved from 13.070 s to
370.6 ms, versus 99.2 ms for Rust.

The exact-line count scanner now uses the existing Swift literal scanner for
`literal + "\\n"` instead of repeated `Data.range(of:)`, and final
`--count-matches -x` routes to the same count because each exact-line match
contributes one match. Byte/status checks matched Rust for plain, bounded,
prefixed, include-zero, and final-line-without-newline forms. On the 48 MiB
dense fixture, `-c -x 'needle needle needle quiet tail needle'` measured
13.1 ms, versus 104.9 ms for Rust; `--count-matches -x ...` measured 12.0 ms
after a pre-route forced-fallback probe was still running after 60 seconds,
versus 238.8 ms for Rust; and bounded `--count-matches -m2 -x ...` measured
3.6 ms.

Exact-line count summaries now also cover simple literal alternations,
multiple explicit regexps, and literal pattern files. The helper deduplicates
identical exact-line alternatives and sums per-literal full-line counts, which
is order-independent for count summaries while still honoring `-m` as a total
cap. Byte/status checks matched Rust for alternation, repeated `-e`, pattern
file, bounded, prefixed include-zero no-match, duplicate-alternative, and
neighboring matching-line fallback controls. On the 4.8 MiB dense fixture,
`-c -x 'needle needle…|missing'` improved from 1.968 s to 4.6 ms, versus
11.7 ms for Rust; `--count-matches -x ...` improved from 1.958 s to 4.6 ms,
versus 24.0 ms for Rust. On the 48 MiB dense fixture, current `-c -x ...`
measured 15.3 ms versus 91.9 ms for Rust, and current
`--count-matches -x ...` measured 13.4 ms versus 211.2 ms for Rust.

Exact-line quiet and path-only explicit-file searches now use the same
Swift-first full-line existence check. The preflight writes no output for
`-q -x`, prints only the file path for `-l -x`, preserves
`--files-without-match` and `--null`, and still falls through for `--crlf`,
custom path separators, and early binary detection. On the same fixture,
`-q -x 'needle needle needle quiet tail needle'` improved from 13.112 s to
3.2 ms, versus 3.0 ms for Rust; `-l -x` improved from 13.043 s to 3.4 ms,
versus 3.0 ms for Rust. No-match exact-line quiet/path-only scans measured
12.4 ms, versus 7.0 ms and 6.9 ms for Rust.

Exact-line quiet and path-only searches now also cover simple literal
alternations, repeated explicit regexps, and literal pattern files. The
preflight shares the exact-line multi-literal existence check with count
summaries, preserves `--files-without-match` and `--null` path output, and
keeps CRLF exact-line forms on the existing fallback. Byte/status checks
matched Rust for quiet, path-only, files-without-match, repeated `-e`, pattern
file, NUL path output, and CRLF fallback controls. On the 4.8 MiB dense
fixture, `-q -x 'needle needle…|missing'` improved from 1.967 s to 4.2 ms,
versus 4.1 ms for Rust, while `-l -x ...` improved from 1.952 s to 4.9 ms,
versus 3.0 ms for Rust. On the 48 MiB dense fixture, current `-q -x ...`
measured 4.6 ms versus 4.0 ms for Rust, current `-l -x ...` measured 4.3 ms
versus 3.3 ms for Rust, and no-match `--files-without-match -x ...` measured
11.2 ms versus 10.7 ms for Rust.

Exact-line matching output now covers the same literal alternation, repeated
`-e`, and pattern-file shapes with a Swift line scanner that preserves file
order, one output row per matched line, line numbers, max-count, filename
prefixes, headings, and binary fallback behavior. Direct byte/status checks
matched Rust for plain, numbered, bounded, prefixed, heading, repeated `-e`,
pattern-file, CRLF fallback, and binary fallback forms. On the 4.8 MiB dense
fixture, `-x 'needle needle...|missing'` improved from 2.033 s to 38.6 ms,
versus 14.1 ms for Rust; `-n -x ...` improved from 2.048 s to 54.6 ms,
versus 16.9 ms for Rust. On the 48 MiB dense fixture, current plain output
measured 351.4 ms versus 114.9 ms for Rust, and numbered output measured
499.2 ms versus 144.9 ms for Rust.

Exact-line only-matching output now shares that same literal alternation,
repeated `-e`, and pattern-file route. The executable preflight parses
`-o`/`--only-matching` and short clusters such as `-nox`, but keeps `-o` on the
fast path only when `-x` makes the match span the whole emitted line. It still
falls through for non-exact only-matching, counts, quiet/path-only modes, CRLF,
and binary fallback controls. Direct byte/status checks matched Rust for plain,
numbered, clustered, bounded, prefixed, heading, repeated `-e`, pattern-file,
CRLF fallback, binary fallback, non-exact fallback, and count-only fallback
forms. On the 4.8 MiB dense fixture, `-o -x 'needle needle...|missing'`
improved from 2.128 s to 38.9 ms, versus 26.5 ms for Rust, and `-n -o -x ...`
improved from 2.149 s to 54.8 ms, versus 31.7 ms for Rust.

Case-insensitive exact-line quiet and path-only searches now have a conservative
match-only Swift preflight. It probes exact, lowercase, and uppercase ASCII
whole-line variants and falls back whenever it cannot prove a match, preserving
mixed-case and no-match behavior through the full searcher. On a 45 MiB repeated
exact-line fixture, `-q -i -x 'NEEDLE NEEDLE NEEDLE QUIET TAIL NEEDLE'`
measured 7.8 ms, versus 2.8 ms for Rust, and `-l -i -x` measured 8.3 ms,
versus 3.5 ms for Rust. On a 3.7 MiB fixture, forcing the full fallback with an
empty `RIPGREP_CONFIG_PATH` measured 2.852-2.902 s for the same quiet/path-only
forms, while the default Swift preflight measured 3.7-5.1 ms.
No-letter ASCII no-match exact-line forms can now also prove false instead of
falling back. On the 45 MiB fixture, `-q -i -x 1234567890` measured 8.8 ms,
versus 4.879 s for the forced fallback and 7.4 ms for Rust; the matching
`--files-without-match -i -x 1234567890` form measured 9.1 ms, versus
5.044 s for the forced fallback and 8.5 ms for Rust.

Case-insensitive exact-line matching output now has a conservative Swift
line scanner for ASCII-only data and patterns. It emits the original line
bytes while comparing folded bytes, covers literal alternations, repeated
`-e`, pattern files, line numbers, headings, `-o`, and max-count, and falls
back for CRLF, binary, non-ASCII, quiet/path-only, and count forms. Direct
byte/status checks matched Rust for plain, numbered, only-matching, bounded,
prefixed, heading, repeated `-e`, pattern-file, CRLF fallback, binary fallback,
and Unicode fallback forms. On the 4.8 MiB dense fixture,
`-i -x 'NEEDLE NEEDLE NEEDLE QUIET TAIL NEEDLE'` improved from 3.900 s to
62.3 ms, versus 16.4 ms for Rust, while `-n -i -x ...` improved from 3.909 s
to 80.2 ms, versus 20.0 ms for Rust. The neighboring alternation
`-i -x 'NEEDLE NEEDLE...|MISSING'` measured 57.3 ms, and numbered alternation
measured 72.3 ms.

The same ASCII exact-line scanner now counts case-insensitive `-c -i -x` and
`--count-matches -i -x` matches without emitting lines. Byte/status checks
matched Rust for line counts, count-matches, bounded counts, include-zero,
repeated `-e`, pattern-file, prefixed, CRLF fallback, binary fallback, and
Unicode fallback forms. On the 4.8 MiB dense fixture,
`-c -i -x 'NEEDLE NEEDLE NEEDLE QUIET TAIL NEEDLE'` improved from 3.797 s to
48.2 ms, versus 12.7 ms for Rust, and `--count-matches -i -x ...` improved
from 3.825 s to 48.0 ms, versus 25.9 ms for Rust.

Case-insensitive exact-line quiet and path-only modes now also accept safe
literal alternations, repeated `-e`, and pattern-file inputs. The path uses the
same ASCII folded exact-line probe, prints only path output for `-l`/
`--files-without-match`, and keeps CRLF, binary, and non-ASCII cases on the
existing fallback. Direct byte/status checks matched Rust for quiet match and
no-match, repeated `-e`, pattern-file, path-only, custom path separators, NUL
path output, files-without-match, CRLF fallback, binary fallback, and Unicode
fallback forms. On the 4.8 MiB dense fixture,
`-q -i -x 'NEEDLE NEEDLE...|MISSING'` improved from 7.246 s to 19.2 ms, versus
2.9 ms for Rust; `-l -i -x ...` improved from 7.248 s to 19.9 ms, versus
2.9 ms for Rust; and no-match `--files-without-match -i -x 'ABSENT|MISSING'`
improved from 954.8 ms to 35.0 ms, versus 3.6 ms for Rust.

Case-insensitive multi-literal line counts now use a Swift folded line scanner
for safe ASCII alternations, repeated `-e`, and pattern files outside
line-regexp mode. It counts each matching line once, preserves `-m`,
`--include-zero`, and filename prefixes, and falls back for binary or non-ASCII
inputs. Direct byte/status checks matched Rust for plain, bounded, prefixed,
repeated `-e`, pattern-file, include-zero no-match, binary fallback, and
Unicode fallback forms. On the 4.8 MiB dense fixture,
`-c -i 'NEEDLE|QUIET'` improved from 177.6 ms to 36.9 ms, versus 7.4 ms for
Rust, and bounded `-c -m2 -i ...` measured 20.4 ms, versus 2.8 ms for Rust.

Type-definition flags that do not activate a type filter now also stay
eligible for the executable preflight. The preflight replays
`--type-add`/`--type-clear` through `FileTypeRegistry.apply`, so invalid
definitions and follow-on `-t`/`-T` filters still use the normal parser and
diagnostics. On the same fixture, `--type-clear rust needle` improved from
6.141 s to 35.6 ms, and `--type-add foo:*.foo needle` improved from 6.165 s
to 36.0 ms, versus 44.6 ms and 47.0 ms for the same Rust commands.
Explicit-file type filters now share that same validation path because Rust
still searches explicit operands regardless of `-t`/`-T` filters. The parser
accepts separated and inline short/long forms, plus filters that reference a
type added earlier in the same command; invalid types still fall back to the
normal diagnostic. On the 45 MiB fixture, `-t rust needle` improved from
5.744 s to 34.2 ms, versus 41.5 ms for Rust; `-T rust needle` improved from
5.774 s to 33.4 ms, versus 49.0 ms for Rust; and
`--type-add foo:*.txt -t foo needle` improved from 5.795 s to 33.9 ms, versus
42.0 ms for Rust.

Regex-mode toggles that do not affect plain literal line output now also stay
eligible for the executable preflight. `--unicode`/`--no-unicode`,
`--pcre2-unicode`/`--no-pcre2-unicode`, and `--crlf`/`--no-crlf` are still
rejected naturally when the pattern is not reducible to a literal. Small
previous/current/Rust checks covered Unicode and CRLF output bytes, including a
CRLF-terminated file. On the 252 MiB dense fixture, current output for
`--no-unicode Sherlock`, ordered Unicode toggles, PCRE2 Unicode toggles,
`--crlf Sherlock`, and ordered CRLF toggles matched Rust exactly; the previous
Swift binary timed out after 10 seconds with no output for both
`--no-unicode Sherlock` and `--crlf Sherlock`. Ten-run checks measured current
`--no-unicode Sherlock` at 258.5 ms versus 392.2 ms for Rust, and current
`--crlf Sherlock` at 327.9 ms versus 406.1 ms for Rust.

Default-reset and no-op selection flags now also stay eligible for the
executable literal preflight when the command is still a single explicit file
search. This covers buffering/search/output resets such as
`--no-block-buffered`, `--no-json`, `--no-stats`, `--no-search-zip`, glob-case
toggles without globs, ordered output/search/invert toggles that finish disabled,
`--sort none`/`--sortr none`, and validated `--threads N` forms. Small
previous/current/Rust checks covered each accepted form, large current/Rust
checks covered `--no-block-buffered`, `--sort=none`, and `--threads=1`, and
invalid `--threads=bogus` still fell through to the normal parser error.
Ten-run checks on the 252 MiB dense fixture measured current
`--no-block-buffered Sherlock` at 313.7 ms versus 443.0 ms before,
`--sort=none Sherlock` at 319.8 ms versus 449.3 ms before and 418.7 ms for
Rust, and a noisy `--threads=1 Sherlock` rerun at 380.1 ms versus 480.0 ms
before and 401.8 ms for Rust. Ordered reset checks on the 45 MiB fixture
measured `--json --no-json needle` improving from 84.3 ms to 35.9 ms, versus
42.3 ms for Rust; `--stats --no-stats needle` from 83.4 ms to 34.5 ms, versus
43.0 ms for Rust; `--search-zip --no-search-zip needle` from 85.2 ms to
35.5 ms, versus 42.3 ms for Rust; and `-z --no-search-zip needle` at 34.0 ms,
versus 42.3 ms for Rust. A follow-up ordered invert reset check measured
`--invert-match --no-invert-match needle` improving from 86.6 ms to 37.9 ms,
versus 46.9 ms for Rust, and `-v --no-invert-match needle` from 67.0 ms to
37.7 ms, versus 46.6 ms for Rust.

Valid regex/DFA resource limit flags now also remain eligible for the
executable literal preflight. The preflight parser accepts separated and inline
`--dfa-size-limit` and `--regex-size-limit` values using the same digit plus
optional `K`/`M`/`G` syntax as the full parser, and invalid values still fall
through to the normal parser diagnostic. Small previous/current/Rust checks
covered inline and separated forms; large current/Rust checks covered
`--dfa-size-limit=10M` and `--regex-size-limit 10M`. Ten-run checks on the
252 MiB dense fixture measured current `--dfa-size-limit=10M Sherlock` at
380.2 ms versus 13.501 s before, and current `--regex-size-limit 10M Sherlock`
at 358.1 ms versus 13.659 s before and 476.9 ms for Rust.

Zero-valued numeric controls now stay on the executable literal preflight when
they are output-equivalent for a single explicit file search. This covers
inline, separated, and short forms for `--max-columns 0`, `--max-depth 0`,
`--maxdepth 0`, `--after-context 0`, `--before-context 0`, and `--context 0`;
ordered numeric controls that finish at zero, and `--passthru`/`--passthrough`
forms reset by later zero-context flags; nonzero final values and invalid
values still fall through to the normal parser/searcher.
`--no-encoding` and standalone `--max-columns-preview` are also treated as
neutral in this preflight shape. Small previous/current/Rust checks covered
every accepted form, large current/Rust checks covered representative
max-columns, context, max-depth, and no-encoding forms, invalid
`--max-columns=bogus` still reported the normal parser error, and nonzero
`--context=1` matched Rust through fallback. Ten-run checks on the 252 MiB
dense fixture measured current `--max-columns=0 Sherlock` at 444.5 ms versus
532.2 ms before, current `--context=0 Sherlock` at 425.7 ms versus 556.2 ms
before and 540.6 ms for Rust, and current `--max-depth=0 Sherlock` at
449.9 ms versus 557.5 ms before. Ordered reset checks on the 45 MiB fixture
measured `--passthru --context=0 needle` improving from 91.7 ms to 38.4 ms,
versus 47.4 ms for Rust; `--context=1 --context=0 needle` from 91.0 ms to
38.1 ms, versus 47.4 ms for Rust; and
`--max-columns=100 --max-columns=0 needle` from 82.4 ms to 38.1 ms, versus
47.0 ms for Rust.

Nonzero `--max-depth` values now share that explicit-file preflight treatment,
since depth pruning is traversal-only once the operand is an actual file.
Release byte checks matched Rust for inline, separated, short, ordered,
numbered, filename-prefixed, heading-prefixed, and path-only forms. On the 50
KiB dense fixture, five-run checks measured `--max-depth=1 needle` at 3.9 ms
versus 26.4 ms before and 2.8 ms for Rust; `--maxdepth=2 -n needle` measured
3.0 ms versus 25.9 ms before and 2.7 ms for Rust.

Separator and metadata value flags that cannot affect plain matching-line
bytes now also remain eligible for the executable literal preflight. The parser
consumes inline and separated `--field-match-separator`,
`--field-context-separator`, `--context-separator`, `--path-separator`, and
`--hostname-bin` only while filename, field, and context output are otherwise
absent.
Small previous/current/Rust checks covered every accepted form, large
current/Rust checks covered field, path, and hostname representatives, invalid
`--path-separator=//` still reported the normal parser error, and
`--field-match-separator='|' -n` matched Rust through fallback. Five-run
before checks on the 252 MiB dense fixture measured the old
`--field-match-separator='|' Sherlock` and `--path-separator=/ Sherlock` paths
at 21.720 s and 21.696 s, with `--hostname-bin=hostname Sherlock` at 692.4 ms.
Ten-run current checks measured those same forms at 468.2 ms, 507.1 ms, and
488.9 ms respectively, versus 610.6 ms for Rust field-separator output. After
tightening mapped preflight binary detection to reject NUL bytes anywhere
before writing, those current checks measured 492.4 ms, 509.7 ms, and
451.3 ms respectively, versus 536.3 ms for Rust field-separator output; the
Rust parity harness binary fixtures also stayed on the binary-aware fallback.
Line-numbered `--field-match-separator` output now uses the same executable
preflight by carrying the parsed separator bytes into the Swift line-number
prefix writers. Focused coverage checks inline, separated, tab-escaped,
hex-escaped, and empty separators; direct release byte checks matched Rust for
literal, line-buffered, max-count, multi-literal, and word-regexp forms. On the
50 KiB dense fixture, `--field-match-separator='|' -n needle` improved from
48.2 ms before this slice to 3.4 ms, versus 2.9 ms for Rust and 3.0 ms for
plain Swift `-n needle`.

Binary-mode toggles now stay eligible for the same executable literal preflight
on ordinary text files. The parser accepts `--text`, `-a`, `--binary`, and
clustered text-mode forms such as `-an`/`-na`; NUL-containing files still
return to the full searcher before emitting output. Focused executable tests
covered matching-line and line-number forms plus a `--text` binary fallback,
and direct release byte checks matched Rust for small, large, clustered, and
binary-fallback representatives. On a generated 24,000,000-byte text fixture,
five-run checks before this parser eligibility change measured `--text
Sherlock` at 865.0 ms, `-a Sherlock` at 874.4 ms, and `--binary Sherlock` at
868.8 ms, with plain Swift preflight at 26.6 ms and Rust `--text Sherlock` at
31.3 ms. After the change, the same current forms measured 26.7 ms, 26.4 ms,
and 26.6 ms respectively, versus 31.7 ms for Rust `--text Sherlock`.

Multiline enable flags are now also accepted by the executable literal
preflight when the parsed literal has no line terminator. This covers `-U`,
`--multiline`, `--multiline-dotall`, and clustered forms such as `-Un`/`-nU`,
while newline-sensitive patterns still fall back through the existing literal
guard. Focused executable coverage checked matching-line and line-number forms,
direct release byte checks matched Rust on small, large, clustered, dotall, and
binary-fallback representatives, and the Rust parity harness remained green. On
a 24 KB generated text fixture, three-run before checks measured `-U Sherlock`
at 25.0 ms, `--multiline Sherlock` at 52.0 ms, and
`--multiline-dotall Sherlock` at 42.6 ms versus 5.3 ms for plain Swift and
3.9 ms for Rust `-U`; larger pre-change probes were slow enough to stop before
completion. After the change, five-run checks on the same 24 KB fixture measured
3.8 ms, 4.0 ms, and 3.7 ms respectively, with Rust `-U` at 3.6 ms. On the same
24,000,000-byte fixture used for binary-mode toggles, current `-U`,
`--multiline`, and `--multiline-dotall` measured 26.4 ms, 26.2 ms, and 26.4 ms
respectively, versus 30.6 ms for Rust `-U`.
Active `--stop-on-nonmatch` remains on the full path for matching-line and
count output, but quiet and path-only forms are now accepted because the flag is
output-neutral once only the existence of a match matters. The executable
preflight also accepts ordered reset forms where a later `-U` or `--multiline`
makes line output equivalent to normal literal matching. Focused coverage keeps
`-U --stop-on-nonmatch` on the fallback by checking its truncated output, while
direct release byte checks matched Rust for reset line-output, active quiet,
active path-only, active count fallback, and active matching-line fallback
controls. On a 50 KiB dense fixture, `--stop-on-nonmatch -U needle` improved
from 62.8 ms to 4.7 ms, versus 4.4 ms for Rust. Active
`--stop-on-nonmatch -q needle` improved from 49.6 ms to 3.4 ms, versus 3.1 ms
for Rust, and `--stop-on-nonmatch -l needle` improved from 44.2 ms to 4.3 ms,
versus 3.0 ms for Rust. A current 48 MiB quiet reset check measured
`--stop-on-nonmatch -qU needle` at 3.7 ms, versus 3.2 ms for Rust.

Null path terminator flags now stay on the executable literal preflight when
the command shape cannot print a path. This covers standalone `--null` and
`-0`; clustered `-0n` remains on the current parser path because Rust accepts
it but the current Swift CLI does not. Focused executable coverage checked
matching-line, line-number, and binary-fallback forms, and direct release byte
checks matched Rust on small, large, and binary representatives while confirming
clustered `-0n` still falls through to the existing parser error. On a generated
4.8 MiB text fixture, single-run before probes measured `--null Sherlock` at
about 0.82 s and `-0 Sherlock` at about 0.85 s. Seven-run current checks on the
same fixture shape measured 8.3 ms and 8.4 ms respectively, in line with the
plain Swift preflight at 8.6 ms and Rust `--null Sherlock` at 9.0 ms.

CRLF path-only and counted executable preflight output now uses Rust-compatible
`\r\n` terminators, while `--null` path terminators still take precedence. The
parser also tracks ordered `--null-data`/`--crlf` state so Rust-equivalent
reset forms such as `--null-data --crlf` and `--null-data --crlf --no-crlf`
can use the executable preflight, while active final `--null-data` remains on
the full path. Focused coverage and direct release byte checks matched Rust for
CRLF path summaries, CRLF counts, null path summaries, active null-data line
records, quiet reset forms, and null-data reset path/count summaries. On a 50
KiB dense fixture, a pre-slice shell probe for `--null-data --crlf needle`
measured 45.0 ms before the reset fast path; final no-shell hyperfine checks
measured 3.4 ms, versus 3.1 ms for Rust. Current no-shell CRLF summary checks
measured `--crlf -l needle` at 3.9 ms versus 3.1 ms for Rust, and
`--crlf -c -m1 needle` at 3.4 ms versus 2.8 ms for Rust.

Explicit-file `--max-filesize` values now stay on the executable literal
preflight because the limit applies only to non-explicit files. The parser
accepts inline and separated K/M/G size values and leaves invalid values on the
normal parser path. Focused executable tests covered values smaller than the
file, direct release byte checks matched Rust on small and large explicit-file
representatives, and invalid `--max-filesize=45k` still matched Rust's parser
error. On the same generated 4.8 MiB text fixture, single-run before probes
measured both inline and separated `--max-filesize 1K Sherlock` at about
0.04 s; seven-run current checks measured both forms at 8.2 ms, in line with
plain Swift at 8.3 ms and Rust `--max-filesize=1K Sherlock` at 8.7 ms.

Explicit default encoding selections now stay on the executable literal
preflight. The parser accepts `--encoding auto`, `--encoding=auto`, `-E auto`,
and `-Eauto`; it also validates explicit encoding labels that are later reset
by `--no-encoding`, while final non-default labels and invalid labels still
fall back. Focused executable tests covered all four auto forms, valid reset
forms, and invalid reset diagnostics; direct release byte checks matched Rust
on small and large text fixtures, BOM input still returned to the normal
BOM-aware searcher, and invalid `--encoding=bogus` still matched Rust's parser
error. On the generated 4.8 MiB text fixture, single-run before probes measured
the explicit-auto forms at about 0.04 s; seven-run current checks measured
`--encoding=auto`, `--encoding auto`, and `-Eauto` at 8.3 ms, 8.8 ms, and
8.2 ms respectively, in line with plain Swift at 8.2 ms and Rust
`--encoding=auto Sherlock` at 8.9 ms. On the 45 MiB fixture,
`--encoding utf-8 --no-encoding needle` improved from 83.2 ms to 36.6 ms,
versus 45.2 ms for Rust; `-Eutf-8 --no-encoding needle` improved from
81.0 ms to 35.6 ms, versus 44.9 ms for Rust; and
`--encoding none --no-encoding needle` improved from 85.4 ms to 35.7 ms,
versus 44.1 ms for Rust.

The Swift-only Darwin mmap/stdout preflight now also covers line-numbered
medium bounded multi-literal output when no filename, byte-offset, column,
replacement, only-matching, or vimgrep formatting is requested. Output for
`-n -m 16`, `-n -m 128`, `-n -m 1024`, and neighboring plain `-m 128`
checks matched both the previous Swift checkpoint and Rust. On the small
subtitles corpus, 20-run A/B checks measured `-n -m 16 'Sherlock|Watson'` at
47.1 ms versus 55.1 ms before and 10.5 ms for Rust, while `-n -m 128` measured
69.9 ms versus 148.7 ms before and 23.7 ms for Rust. A 12-run `-n -m 1024`
check measured 103.0 ms versus 193.0 ms before and 43.9 ms for Rust.

The same bounded multi-literal preflight now keeps one exact next-match
candidate per literal instead of scanning for any literal first byte and then
rejecting false candidates. Output for `-m16`, `-m128`, `-n -m16`, `-n -m128`,
and the `-m1281` fallback boundary matched the sibling Rust oracle on the small
subtitles corpus. A 10-run check measured `-m128 'Sherlock|Watson'` at
58.9 ms versus the same-turn pre-change sweep at 72.7 ms and 22.9 ms for Rust;
`-n -m128` measured 62.0 ms versus 23.5 ms for Rust.

The direct Swift Darwin matching-line writer now covers transformed ASCII
multi-literal regexes, including ignore-case alternations and word-boundary
alternations, when no filename, byte-offset, column, replacement,
only-matching, or vimgrep formatting is requested. The writer keeps one
next-match candidate per literal and advances every candidate past an emitted
or rejected line, avoiding repeated all-file rescans while preserving one output
line per matched line. Output for `-i 'sherlock|watson'`,
`-n -i 'sherlock|watson'`, `-w 'Sherlock|Watson'`, `-n -w 'Sherlock|Watson'`,
and the neighboring `-n -m 16 'Sherlock|Watson'` check matched the sibling
Rust oracle on the small subtitles corpus. The focused executable regression
also covers mixed-case ignore-case output and a word-boundary false positive
like `Watsonian`. A 10-run check measured `-i 'sherlock|watson'` at 78.5 ms
versus the earlier 47,774.6 ms pathological Swift sweep and 40.7 ms for Rust;
`-w 'Sherlock|Watson'` measured 79.9 ms versus the earlier 21,342.5 ms Swift
sweep and 39.5 ms for Rust.

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

Safe multi-literal `--vimgrep` now uses the same line-granular finite
max-count strategy, merging independent literal streams and emitting every
match from each admitted line in byte order. Output for `-m1`, `-m2`, `-o`,
byte-offset, no-column, and no-filename forms on the 193 MiB subtitles corpus
matched both the previous Swift checkpoint and the sibling Rust oracle. Five-run
A/B checks measured `--vimgrep -m1 'Sherlock|Watson'` at 45.5 ms versus
15.927 s before and 5.7 ms for Rust; `--vimgrep -m1 -o 'Sherlock|Watson'` at
54.2 ms versus 15.976 s before and 5.7 ms for Rust; and `--vimgrep -m2 -o
'Sherlock|Watson'` at 41.7 ms versus 15.833 s before.

Literal-only safe multi-literal `--vimgrep --replace` now also has a direct
Swift writer. It merges independent literal streams, builds each replaced line
once, and emits replacement coordinates after prior replacements on that line,
which matches ripgrep's shifted-column and shifted-byte-offset semantics.
Output for full-line, only-matching, byte-offset, empty replacement, and
bounded forms on the 193 MiB subtitles corpus matched both the previous Swift
checkpoint and the sibling Rust oracle. Five-run A/B checks measured
`--vimgrep -r X 'Sherlock|Watson'` at 88.8 ms versus 15.931 s before and
45.9 ms for Rust; `--vimgrep -o -r X 'Sherlock|Watson'` at 70.0 ms versus
15.975 s before and 45.9 ms for Rust; and `--vimgrep -m1 -r X
'Sherlock|Watson'` at 43.8 ms versus 15.992 s before and 5.1 ms for Rust.

Non-vimgrep safe multi-literal replacement now uses the same direct Swift
writer strategy. It merges independent literal streams in byte order, builds
each replaced line once, and emits only-matching replacement coordinates after
prior replacements on that line. Output for full-line, only-matching,
byte-offset, combined line/column/byte-offset, empty replacement, and bounded
forms on the 193 MiB subtitles corpus matched both the previous Swift
checkpoint and the sibling Rust oracle. Five-run A/B checks measured `-r X
'Sherlock|Watson'` at 83.1 ms versus 15.995 s before and 40.9 ms for Rust;
`-o -r X 'Sherlock|Watson'` at 74.9 ms versus 16.287 s before and 41.3 ms for
Rust; and `-m1 -r X 'Sherlock|Watson'` at 47.9 ms versus 16.033 s before.

That replacement writer now also handles explicit `--with-filename` prefixes
for literal-only single-file searches. It writes the display path before the
same line/column/byte replacement fields while still leaving non-literal
replacement expansion on the formatted path. Output for single-literal,
multi-literal, only-matching, field-prefixed, empty replacement, and bounded
forms on the 193 MiB subtitles corpus matched both the previous Swift
checkpoint and the sibling Rust oracle. Five-run A/B checks measured
`--with-filename -r X 'Sherlock|Watson'` at 70.8 ms versus 15.947 s before and
40.4 ms for Rust; `--with-filename -o -r X 'Sherlock|Watson'` at 75.5 ms
versus 16.041 s before and 39.5 ms for Rust; and `--with-filename -n --column
--byte-offset -r X 'Sherlock|Watson'` at 106.2 ms versus 17.234 s before and
44.7 ms for Rust.

Plain literal `--with-filename` output now uses the direct Swift writer too,
covering single-literal, safe multi-literal, only-matching, and line/column/
byte-offset field forms while keeping PCRE-derived literal fast paths on their
existing fallback unless they already format paths themselves. Output on the
193 MiB subtitles corpus matched both the previous Swift checkpoint and the
sibling Rust oracle, including a large byte-set only-matching smoke. Five-run
A/B checks measured `--with-filename 'Sherlock|Watson'` at 74.9 ms versus
524.8 ms before and 39.7 ms for Rust; `--with-filename -o 'Sherlock|Watson'`
at 67.3 ms versus 15.865 s before and 39.2 ms for Rust; and
`--with-filename -n --column --byte-offset 'Sherlock|Watson'` at 80.2 ms
versus 15.853 s before and 43.5 ms for Rust.

Explicit single-file `--with-filename` matching-line searches now stay on the
Swift executable preflight for plain literal, numbered, NUL path prefix, custom
field separator, max-count, safe multi-literal, exact-line, word-regexp, and
line-buffered forms. Release byte checks matched Rust stdout, stderr, and exit
status for each form. On the 50 KiB dense fixture, five-run checks measured
`-H needle` at 3.4 ms versus a noisy fallback baseline around 54.4 ms and
3.0 ms for Rust; `-H -n needle` measured 3.1 ms versus 3.0 ms for Rust.

Single-file `--heading` searches without final filename output now remain on
the Swift executable preflight, since active heading is byte-neutral in that
shape. Release byte checks matched Rust for plain, numbered, path-separator,
NUL, custom field separator, max-count, safe multi-literal, exact-line,
word-regexp, and no-match forms. On the 50 KiB dense fixture, five-run checks
measured `--heading needle` at 3.2 ms versus 31.6 ms before and 2.9 ms for
Rust; `--heading -n needle` measured 3.0 ms versus 35.5 ms before and 2.9 ms
for Rust.

Single-file `--heading --with-filename` matching-line searches now use a
one-time Swift heading prefix instead of falling back for the path header.
Release byte checks matched Rust for plain, numbered, path-separator, NUL,
CRLF-heading, custom field separator, max-count, safe multi-literal,
exact-line, word-regexp, no-match, quiet, count, and path-only controls. On the
50 KiB dense fixture, five-run checks measured `--heading --with-filename
needle` at 3.2 ms versus 29.9 ms before and 2.8 ms for Rust; `--heading
--with-filename -n needle` measured 3.2 ms versus 28.9 ms before and 2.7 ms
for Rust.

Explicit single-file `--with-filename --path-separator` matching-line searches
now use the same Swift executable preflight by applying the escaped one-byte
path separator directly to the emitted path prefix. Release byte checks matched
Rust for separated and inline separators, escaped `\x5A`, automatic reset,
NUL path prefixes, max-count, safe multi-literal, exact-line, and word-regexp
forms. On the 50 KiB dense fixture, five-run checks measured
`-H --path-separator Z needle` at 3.5 ms versus 28.6 ms before and 3.0 ms for
Rust; `-H --path-separator Z -n needle` measured 3.1 ms versus 49.6 ms before
and 3.0 ms for Rust.

Path-only `--path-separator` output now also stays on the Swift executable
preflight by sharing the parsed display-path bytes with `-l` and
`--files-without-match` emitters. Release byte checks matched Rust for
matching and nonmatching path modes, NUL path terminators, ignore-case,
safe multi-literal, exact-line, word-regexp, escaped separators, and automatic
reset. On the 50 KiB dense fixture, five-run checks measured
`-l --path-separator Z needle` at 3.2 ms versus 27.5 ms before and 2.9 ms for
Rust; `--files-without-match --path-separator Z missing` measured 3.0 ms
versus 30.3 ms before and 2.9 ms for Rust.

Path-only `--heading --with-filename` forms now remain on that same Swift
preflight because heading layout is output-neutral for `-l` and
`--files-without-match`. Release byte checks matched Rust for matching,
nonmatching, NUL-terminated, path-separated, quiet, and ignore-case path-only
forms. On the 50 KiB dense fixture, five-run checks measured `--heading
--with-filename -l needle` at 4.7 ms versus 30.9 ms before and 3.4 ms for
Rust; `--heading --with-filename --files-without-match missing` measured
3.5 ms versus 33.6 ms before and 2.7 ms for Rust.

Filename-prefixed literal count output now also stays on the direct Swift
writer for `-c` and `--count-matches`, including `--include-zero path:0`
semantics. Output and exit status for matching, no-match, include-zero,
single-literal, safe multi-literal, and byte-set count forms matched both the
previous Swift checkpoint and the sibling Rust oracle. Five-run A/B checks on
the 193 MiB subtitles corpus measured `--with-filename -c 'Sherlock|Watson'`
at 72.0 ms versus 705.3 ms before and 40.6 ms for Rust; `--with-filename
--count-matches 'Sherlock|Watson'` at 94.9 ms versus 706.4 ms before and
39.6 ms for Rust; and `--with-filename --count-matches 'A|B|C|D|E'` at
75.6 ms versus 1.959 s before and 170.3 ms for Rust.

Finite safe multi-literal plain matching-line output now has a Swift-only
mmap/stdout preflight for medium bounded `-m` cases. The new path is limited to
plain non-prefixed, non-vimgrep, non-replacement output with distinct first
literal bytes, leaving unlimited and tiny bounded forms on the previous writer.
Output and exit status for unlimited, `-m1`, `-m10`, `-m128`, duplicate
first-byte, filename-prefixed, vimgrep, replacement, and no-match controls
matched both the previous Swift checkpoint and the sibling Rust oracle.
Fifteen-run A/B checks on the 193 MiB subtitles corpus measured `-m128
'Sherlock|Watson'` at 67.7 ms versus 140.0 ms before and 20.6 ms for Rust.
The unlimited control stayed neutral at 77.6 ms versus 74.1 ms before and
38.7 ms for Rust, and `-m1` stayed neutral at 39.9 ms versus 42.0 ms before.

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

Line-numbered safe multi-literal only-match output now emits the common
`line:match\n` form as one Swift raw output chunk when no path, column, or
byte-offset field is requested. Output for `-n -o 'Sherlock|Watson'` on the
193 MiB subtitles corpus matched the sibling Rust oracle; a 10-run recheck
measured 75.7 ms versus the same-turn pre-change 82.4 ms and 43.2 ms for Rust.

Vimgrep direct output now skips newline counting when both line and column
fields are suppressed, leaving default and line-only vimgrep accounting intact.
Output for `--vimgrep -N --no-column 'Sherlock|Watson'` and the neighboring
`--vimgrep --no-column` form matched the sibling Rust oracle on the 193 MiB
subtitles corpus. A 10-run no-fields check measured 79.1 ms versus the
same-turn pre-change 85.2 ms and 39.0 ms for Rust.

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

The upstream no-literal regex shapes made of repeated
`\w{5}` groups separated by `\s+` now have a Swift byte-line fast path for
matching-line output. The scanner handles ASCII lines directly and, for
Unicode mode, falls back to the existing regex engine only on lines containing
non-ASCII bytes so Unicode `\w`/`\s` semantics stay intact. Sorted output on
the Linux five-group corpus matched the sibling Rust oracle for both default
Unicode (721 lines) and `(?-u)` ASCII (720 lines), including the Unicode-only
Italian documentation line. A five-run check measured default Unicode at
3.518 s versus 87.562 s before and 3.381 s for Rust; the ASCII form measured
3.413 s versus 3.328 s for Rust.

The same scanner also covers the seven-group subtitles no-literal bench shape.
The latest version enforces regex-compatible run lengths: only the first and
last `\w{5}` groups can be satisfied by longer word runs, while middle groups
must be exactly five word bytes because they are immediately followed by `\s+`.
That fixes false positives such as `handful these girls become without their
mother`. Output on the 1.5 GiB subtitles corpus now matches the sibling Rust
oracle for both Unicode and `(?-u)` ASCII forms (22 lines each). The scanner now
walks the mapped bytes once and only looks for a line ending after a line has
matched. Three-run checks measured the Unicode form at 4.297 s versus 4.814 s
before and 2.519 s for Rust, and the ASCII form at 3.827 s versus 4.345 s
before and 2.410 s for Rust.

The no-literal scanner now rejects short non-ASCII lines before decoding them
for the Unicode regex fallback, and checks lowercase ASCII word bytes before
rarer uppercase/digit cases in the hot classifier. Output for the seven-group
Unicode and `(?-u)` ASCII subtitles patterns stayed byte-identical to the
previous Swift checkpoint and sibling Rust oracle (22 lines each). A seven-run
A/B measured Unicode at 3.958 s versus 4.194 s before and 2.530 s for Rust;
the ASCII form measured 3.691 s versus 3.736 s before and 2.407 s for Rust.

Large mapped no-literal word-sequence scans now prefilter lines that are too
short to satisfy the minimum `\w{5}\s+...` byte length, using `memchr` to skip
the line before entering the Swift byte-classification loop. The prefilter is
limited to large files so recursive Linux-tree scans keep the previous scalar
loop. Output for the seven-group Unicode and `(?-u)` ASCII subtitles patterns
remained byte-identical to the previous Swift checkpoint and sibling Rust
oracle (22 lines each). A five-run A/B measured Unicode at 2.809 s versus
3.968 s before, and ASCII at 2.542 s versus 3.689 s before. A three-run Linux
five-group guard stayed neutral/noisy-good: Unicode 2.628 s versus 2.641 s
before, and ASCII 2.537 s versus 2.586 s before.

The same large-file short-line prefilter now checks only the minimum required
line-width window before deciding a line is too short, avoiding a full
newline search on lines that the scanner will inspect anyway. Output for the
seven-group Unicode and `(?-u)` ASCII subtitles patterns matched both the
previous Swift checkpoint and sibling Rust oracle (22 lines each). A seven-run
A/B measured Unicode at 2.784 s versus 2.844 s before, and ASCII at 2.513 s
versus 2.585 s before. Linux five-group guards stayed neutral: Unicode
2.596 s versus 2.587 s before in a five-run recheck, and ASCII 2.526 s versus
2.547 s before in a three-run check.

Required-literal regexes of the form `\wAh` now have a byte verifier for the
single word-character prefix before the required literal. ASCII candidates are
checked without decoding; Unicode mode falls back to the existing regex engine
only when the byte before the literal is non-ASCII. Output for `\wAh` and
`(?-u)\wAh` on the Linux corpus matched the previous Swift checkpoint exactly
(247 and 233 lines respectively; the pre-existing Linux traversal order differs
from sibling Rust). A three-run benchmark measured Unicode at 2.144 s versus
62.189 s before and 3.354 s for Rust, and ASCII at 2.126 s versus 72.039 s
before and 3.499 s for Rust.

Line-numbered single-literal output now counts newline bytes inside the same
Swift SIMD first/tail literal scan used to find the next match, avoiding the
second skipped-region pass previously used only to print `-n` prefixes. Output
for `-n 'Sherlock Holmes'` on the 1.5 GiB subtitles corpus matched both the
previous Swift checkpoint and the sibling Rust oracle (830 lines). A seven-run
A/B measured Swift at 253.0 ms versus 281.1 ms before and 196.8 ms for Rust.
The focused regression also covers a long pre-match line gap, duplicate hits on
one output line, and the `-H -n -m1` prefixed form.

The same newline-counting literal scan now covers ASCII case-insensitive
single-literal line-number output. Output for `-n -i 'Sherlock Holmes'` on the
1.5 GiB subtitles corpus matched both the previous Swift checkpoint and the
sibling Rust oracle (871 lines). A seven-run A/B measured Swift at 333.1 ms
versus 346.0 ms before and 312.0 ms for Rust; the neighboring no-line-number
case stayed effectively unchanged at 252.6 ms versus 250.8 ms before.

The executable-level Swift Darwin literal preflight now also accepts
line-numbered literal file searches, including `-n` combined with ASCII
`-i`, and counts newlines during the SIMD literal scan instead of doing a
second skipped-region pass. Output for `-n 'Sherlock Holmes'` and
`-n -i 'Sherlock Holmes'` on the 1.5 GiB subtitles corpus matched both the
existing Swift fallback and sibling Rust oracle. Ten-run checks measured
`-n` at 215.9 ms versus 249.7 ms for the fallback and 195.5 ms for Rust;
`-n -i` measured 301.5 ms versus 334.1 ms for the fallback and 312.3 ms for
Rust.

The same executable preflight now handles explicit `--no-mmap` literal file
searches with a Swift chunked scanner instead of falling through to the
buffered reader limit. It keeps overlap bytes between chunks, searches for the
next literal before finding line bounds, and preserves line-number output.
Output for plain, `-n`, `-i`, and `-n -i` `--no-mmap 'Sherlock Holmes'` on the
1.5 GiB subtitles corpus matched sibling Rust `rg`. Five-run checks measured
plain `--no-mmap` at 294.3 ms versus a previous Swift error and 164.5 ms for
Rust; `--no-mmap -n` measured 378.7 ms versus the same previous error and
195.8 ms for Rust.

The no-mmap streaming preflight now keeps a logical start offset into its
`Data` buffer and compacts only after several consumed chunks, avoiding a
`removeSubrange` copy after every emitted or skipped slice. Output for plain,
`-n`, `-i`, and `-n -i` `--no-mmap 'Sherlock Holmes'` on the 1.5 GiB subtitles
corpus matched sibling Rust `rg`. Seven-run A/B checks measured plain output at
284.0 ms versus 294.9 ms before and 166.3 ms for Rust; `-n` at 352.4 ms
versus 363.0 ms before and 197.5 ms for Rust. Five-run case-insensitive guards
measured `-i` at 362.8 ms versus 372.5 ms before and 279.9 ms for Rust, and
`-n -i` at 425.1 ms versus 437.8 ms before and 310.7 ms for Rust.

The same no-mmap streaming path now reads 2 MiB chunks instead of 1 MiB chunks.
Plain output stayed neutral in a seven-run A/B (282.0 ms versus 281.3 ms
before, with the means essentially tied at 281.7 ms versus 282.1 ms), while
line-numbered and case-insensitive neighbors improved: `-n` measured 346.6 ms
versus 349.8 ms before, `-i` measured 358.1 ms versus 364.3 ms before, and
`-n -i` measured 424.5 ms versus 428.8 ms before. Output for plain, `-n`,
`-i`, and `-n -i` matched sibling Rust `rg` on the 1.5 GiB subtitles corpus.

The Swift-only mmap/stdout multi-literal preflight now accepts bounded
patterns whose literals share a first byte. The retained implementation keeps
one exact next-match candidate per literal, so the old unique-first-byte setup
guard was no longer needed and prevented the five-name subtitles alternation
from using the medium bounded path. Output for `-m128`, `-n -m128`, `-m1024`,
and `-n -m1024`
`Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor
Moriarty` matched sibling Rust `rg` on the 1.5 GiB subtitles corpus. Nine-run
checks measured `-m128` at 139.4 ms versus 1.134 s before and 50.2 ms for
Rust, while `-n -m128` measured 137.2 ms versus 1.145 s before and 54.9 ms for
Rust. A seven-run lower-boundary A/B measured `-m16` at 110.1 ms versus
627.9 ms before. The neighboring unique-first-byte `-m128 'Sherlock|Watson'`
case stayed in the fast preflight band at 57.5 ms on the same corpus.

The same bounded mmap/stdout preflight now accepts up to 16 literals instead
of eight. This keeps modest wider alternations on the exact-candidate scanner
instead of dropping back to the mapped `Data` path. Output for `-m128`,
`-n -m128`, `-m1024`, and `-n -m1024`
`Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor
Moriarty|Baker Street|Mycroft Holmes|Mrs Hudson|221B Baker|Moriarty` matched
sibling Rust `rg` on the 1.5 GiB subtitles corpus. Seven-run checks measured
the ten-literal `-m128` case at 197.7 ms versus 2.539 s before and 51.3 ms for
Rust; `-n -m128` measured 197.9 ms versus 2.537 s before and 51.0 ms for Rust.
The neighboring five-literal `-m128` case remained in the same band at
133.3 ms.

The bounded mmap/stdout preflight ceiling is now 32 literals. A 20-literal
bounded alternation that had fallen back to the mapped `Data` path now uses the
same exact-candidate scanner. Output for `-m128`, `-n -m128`, `-m1024`, and
`-n -m1024` for the 20-literal Sherlock/Watson subtitles pattern matched
sibling Rust `rg` on the 1.5 GiB subtitles corpus. Seven-run checks measured
`-m128` at 212.4 ms versus 18.579 s before and 6.3 ms for Rust; the
line-numbered form measured 215.5 ms versus 6.8 ms for Rust. The neighboring
16-literal `-m128` case stayed in the retained path at 208.2 ms in the same
run family.

The bounded mmap/stdout preflight ceiling is now 64 literals. A 40-literal
bounded alternation that had fallen back to the mapped `Data` path now uses the
same exact-candidate scanner. Output for `-m128`, `-n -m128`, `-m1024`, and
`-n -m1024` for the 40-literal Sherlock/Watson subtitles pattern matched
sibling Rust `rg` on the 1.5 GiB subtitles corpus. Five-run checks measured
`-m128` at 241.4 ms versus 22.909 s before and 6.1 ms for Rust; the
line-numbered form measured 244.3 ms versus 6.3 ms for Rust. The neighboring
32-literal `-m128` case stayed in the retained path at 246.4 ms in the same
run family.

Bounded multi-literal preflight now scans a shared literal prefix once when all
alternatives have a common prefix of at least four bytes, then verifies full
literals only at prefix candidates. This keeps wide common-prefix no-match
alternations from paying one whole-file scan per alternative. Empty output and
exit status for 40-literal `PM_NOPE_*` matched sibling Rust `rg`; five-run
checks measured 255.9 ms versus 3.310 s before and 194.8 ms for Rust. The
64-literal version measured 242.0 ms versus 5.272 s before and 196.9 ms for
Rust. A neighboring 40-literal matching pattern without a shared prefix stayed
in the retained scanner band at 273.0 ms.

Bounded multi-literal preflight now runs a small dry line-scan prefix for wide
finite `-m` searches, scanning first-byte candidates inside each line and
committing only when the first scanned prefix satisfies the full bound. This
avoids initializing one whole-file next-match candidate per literal when the
requested matches are dense near the start, while falling back unchanged for
sparse searches. Output for `-m128` and `-n -m128` on the 40-literal subtitles
name alternation matched sibling Rust `rg`; five-run checks measured plain
`-m128` at 40.5 ms versus the prior retained scanner's 273.0 ms band and
4.4 ms for Rust. The 40-literal common-prefix no-match guard improved to
214.0 ms versus 162.5 ms for Rust, with empty output and exit status still
matching.

Plain `--no-mmap` single-literal streaming now has a Swift-only complete-line
chunk path for the common case-sensitive, non-line-numbered form. It processes
complete lines directly from each `FileHandle` chunk and keeps only the
trailing partial line as carry, leaving line-numbered and ignore-case searches
on the existing general streaming path. Output for `--no-mmap 'Sherlock
Holmes'` on the 1.5 GiB subtitles corpus matched sibling Rust `rg`; a clean
seven-run check measured 282.2 ms versus a same-turn general-path check at
287.3 ms and 162.3 ms for Rust. A chunk-boundary regression covers a literal
split across the retained 2 MiB read edge, and the unterminated-final-line
case remains covered.

The same complete-line no-mmap path now covers case-sensitive line-numbered
output and uses `FileHandle.readData(ofLength:)` for chunk reads. It advances
line numbers across each completed chunk while counting each chunk at most
once, leaving ignore-case on the general streaming path. Output for plain and
`-n` `--no-mmap 'Sherlock Holmes'` on the 1.5 GiB subtitles corpus matched
sibling Rust `rg`; nine-run checks measured plain output at 279.5 ms versus
the earlier 282.2 ms retained path and 163.2 ms for Rust, while `-n` measured
346.3 ms versus the previous 346.6 ms band and 193.9 ms for Rust. A neighboring
`-i` no-mmap check stayed in its existing band at 362.2 ms versus 279.7 ms for
Rust.

ASCII ignore-case no-mmap single-literal output now reuses that complete-line
chunk path too, instead of the older rolling `Data` buffer. The path folds the
literal once, carries only the trailing partial line across 2 MiB reads, and
keeps the existing line-number accounting for `-n -i`. Output for
`--no-mmap -i 'Sherlock Holmes'` and
`--no-mmap -n -i 'Sherlock Holmes'` on the 1.5 GiB subtitles corpus matched
sibling Rust `rg`; a nine-run previous/current/Rust A/B measured `-i` at
359.9 ms versus 361.1 ms before and 281.6 ms for Rust, while `-n -i` measured
424.5 ms versus 426.8 ms before and 317.1 ms for Rust. Split-chunk ignore-case
boundary regressions cover both plain and line-numbered output.

Executable no-mmap single-literal preflight now treats `--no-mmap` as an
output-equivalent request: it tries the existing Swift mapped literal scanner
first and falls back to the streaming scanner if mapping is unavailable. Output
for plain, `-n`, `-i`, and `-n -i` `--no-mmap 'Sherlock Holmes'` on the 1.5 GiB
subtitles corpus matched sibling Rust `rg`; a seven-run previous/current/Rust
A/B measured plain output at 183.0 ms versus 281.3 ms before and 162.8 ms for
Rust, `-n` at 213.8 ms versus 345.3 ms before and 193.9 ms for Rust, `-i` at
249.9 ms versus 360.3 ms before and 280.1 ms for Rust, and `-n -i` at 300.4 ms
versus 428.0 ms before and 313.9 ms for Rust.

Line-numbered five-name subtitles alternations now use a Swift-only unique
last-word suffix scan. The path scans suffixes such as `Holmes`, `Watson`, and
`Moriarty`, verifies the full literal at the computed start offset, and is
restricted to plain `-n` output so the neighboring plain alternation remains
on the existing full-literal scanner. Output for `-n 'Sherlock Holmes|John
Watson|Irene Adler|Inspector Lestrade|Professor Moriarty'` on the 1.5 GiB
subtitles corpus matched sibling Rust `rg`; a seven-run check measured
618.7 ms versus the current focused-suite full-literal line-numbered band at
662.1 ms and 309.9 ms for Rust. The plain form stayed in its existing band at
580.5 ms versus 278.6 ms for Rust.

Large unbounded 3-8 literal matching-line scans now collect line bounds in
parallel, then sort and deduplicate by line start before writing. This keeps
output order deterministic without adding C shims or replacing the literal
scanner, and leaves two-literal alternations on the previous serial scanner
after a neutral-to-slower probe. Output for plain and `-n` `Sherlock
Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor Moriarty` on the
1.5 GiB subtitles corpus matched sibling Rust `rg`; a seven-run
previous/current/Rust A/B measured the plain form at 337.9 ms versus
589.4 ms before and 280.3 ms for Rust. The line-numbered form stayed on the
unique-suffix path at 630.0 ms versus 623.9 ms before and 311.5 ms for Rust.
On the 193 MiB corpus, the same plain five-name check measured 83.9 ms versus
106.4 ms before and 39.7 ms for Rust, while `Sherlock|Watson` stayed neutral
at 66.7 ms versus 67.0 ms before.

The line-numbered five-name suffix path now uses the same parallel
collect/sort/deduplicate structure for large haystacks, scanning suffixes such
as `Holmes`, `Watson`, and `Moriarty` concurrently and verifying the full
literal before recording the line. Output for plain and `-n` `Sherlock
Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor Moriarty` on the
1.5 GiB subtitles corpus matched sibling Rust `rg`; a seven-run
previous/current/Rust A/B measured `-n` at 404.3 ms versus 620.4 ms before and
311.8 ms for Rust. The neighboring plain form stayed in its retained parallel
literal band at 329.7 ms versus 278.9 ms for Rust.

Large five-name alternations now split the mapped file into line-aligned chunks
and scan each chunk's literals concurrently, falling back to the per-literal
collector when the file cannot produce enough chunks. The same chunk fan-out is
used for the line-numbered unique-suffix path. Output for plain and `-n`
`Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor
Moriarty` matched sibling Rust `rg` on both subtitles corpora. On the 1.5 GiB
corpus, a seven-run previous/current/Rust A/B measured plain output at
120.8 ms versus 356.2 ms before and 282.4 ms for Rust, while `-n` measured
187.5 ms versus 418.9 ms before and 322.3 ms for Rust. On the 200 MiB corpus,
plain output measured 48.2 ms versus 69.8 ms before and 42.5 ms for Rust,
while `-n` measured 52.4 ms versus 75.7 ms before and 46.6 ms for Rust.
The focused benchmark harness reported the same 1.5 GiB checks at 102.70 ms
plain and 169.68 ms line-numbered, versus Rust at 278.04 ms and 315.51 ms.

Case-insensitive five-name alternations now use the same line-aligned chunk
collector for large mapped files. Each chunk scans the folded literals with the
prepared Swift ASCII case-insensitive scanner, then the result is sorted and
deduplicated before output so line order remains deterministic. Output for
plain and `-n -i` `Sherlock Holmes|John Watson|Irene Adler|Inspector
Lestrade|Professor Moriarty` on the 1.5 GiB subtitles corpus matched both the
previous Swift checkpoint and sibling Rust `rg`. A seven-run A/B measured
`-n -i` at 315.4 ms versus 985.9 ms before and 530.2 ms for Rust. The plain
neighbor measured 257.7 ms versus 907.2 ms before and 499.9 ms for Rust in a
five-run check, and the focused benchmark harness reported the line-numbered
case at 320.61 ms versus 534.65 ms for Rust.

ASCII no-literal `\w{5}\s+...` matching-line scans now split large mapped
haystacks on line boundaries and scan chunks in parallel, then reconstruct line
numbers from sorted match offsets. The path is restricted to `(?-u)` ASCII
semantics so Unicode fallback behavior remains on the existing serial scanner.
Output for `-n '(?-u)\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}'`
on the 1.5 GiB subtitles corpus matched sibling Rust `rg`; a seven-run
previous/current/Rust A/B measured 429.8 ms versus 2.512 s before and 2.406 s
for Rust. The neighboring Unicode form stayed on the existing path at 2.838 s
versus 2.514 s for Rust.

The same large-file chunk scanner now supports Unicode `\w{5}\s+...` patterns
by collecting non-ASCII candidate lines during the parallel ASCII pass and
replaying only those candidates through the existing Unicode matcher in file
order. Output for both Unicode and `(?-u)` ASCII seven-word subtitles patterns
matched sibling Rust `rg`; a seven-run previous/current/Rust A/B measured the
Unicode form at 698.3 ms versus 2.788 s before and 2.615 s for Rust. The ASCII
form stayed in the retained fast band at 435.0 ms versus 2.408 s for Rust.

ASCII boundary literal regexes of the form `(?-u:\b)LITERAL(?-u:\b)` now take
a Swift direct line writer instead of reaching the generic regex fallback. The
path parses the literal, scans mapped bytes directly, checks the two ASCII word
boundary bytes, and counts line numbers during the same next-literal scan used
to find the match. Output for `-n '(?-u:\b)Sherlock Holmes(?-u:\b)'` on the
1.5 GiB subtitles corpus matched sibling Rust `rg` exactly (830 lines), and
the focused byte-boundary fixture covers leading/trailing ASCII word bytes,
underscores, and a non-ASCII prefix byte. The neighboring `-nw` literal path
now also counts line numbers during the literal scan, updating the tracked line
number when a same-line boundary candidate is rejected. The upstream
`subtitles_en_literal_word` harness measured the ASCII regex case at
251.20 ms median versus Rust at 196.96 ms; the Unicode `-nw 'Sherlock Holmes'`
case measured 245.35 ms versus Rust at 197.04 ms.

The executable Swift preflight now recognizes the same ASCII boundary literal
shape before full CLI parsing and routes it through the direct mapped literal
writer. That keeps the byte-boundary checks in Swift but avoids constructing
the full searcher pipeline for the upstream ASCII word-literal command. Output
for `-n '(?-u:\b)Sherlock Holmes(?-u:\b)'` on the 1.5 GiB subtitles corpus
remained byte-identical to sibling Rust `rg`; a nine-run direct check measured
214.7 ms versus 201.2 ms for Rust, and the focused upstream
`subtitles_en_literal_word` harness measured 214.23 ms median versus
194.86 ms for Rust.

Line-numbered Unicode word literals now have the same Swift-only executable
preflight when the literal starts and ends with ASCII word bytes. The scanner
buffers line ranges until it knows no candidate needs Unicode decoding, so
non-ASCII-adjacent candidates fall back before any stdout is written. That also
keeps the full searcher direct-stdout path from partially writing word-boundary
literal output before Unicode fallback. Output for `-nw 'Sherlock Holmes'`,
`-n -w 'Sherlock Holmes'`, and the Unicode-adjacent fallback fixture matched
sibling Rust `rg`; on the 1.5 GiB subtitles corpus, `-nw 'Sherlock Holmes'`
matched Rust byte-for-byte (830 lines). Nine-run direct checks measured Swift
`-nw` at 215.7 ms versus Rust at 197.3 ms, with the explicit ASCII boundary
regex at 215.8 ms. The focused upstream `subtitles_en_literal_word` harness
now measures both Unicode and ASCII labels in the same band: Unicode
214.52 ms versus Rust 198.16 ms, and ASCII 215.91 ms versus Rust 197.59 ms.

Plain Unicode word literals now reuse that executable preflight when line
number prefixes are not requested. The scanner still falls back before writing
if a boundary needs Unicode decoding or the buffered matching-line set grows
too large. On a 57 MiB sparse word fixture, `-w needle` improved from a forced
fallback at 4.236 s to 12.5 ms, versus 10.7 ms for Rust; the no-match
`-w absentword` form improved from 4.118 s to 12.6 ms, versus 10.2 ms for
Rust.

The executable Swift preflight now also handles ASCII-scoped surrounding-word
regexes of the form `(?-u)\w+\s+LITERAL\s+\w+` for plain and line-numbered
single-file searches. It scans for the literal directly, verifies ASCII word
and whitespace runs on both sides, buffers matching line ranges until the scan
is complete, and then writes stdout, so no partial output is emitted before a
fallback decision. Output for `-n '(?-u)\w+\s+Holmes\s+\w+'` on the 1.5 GiB
subtitles corpus matched sibling Rust `rg` exactly (483 lines). The neighboring
default Unicode form remains on the existing matcher to preserve full Unicode
`\w` semantics; a small fixture with `Mø Holmes returns` and `Dr Holmes
étrange` also matched Rust output. The focused upstream
`subtitles_en_surrounding_words` harness measured the ASCII form at
217.94 ms versus Rust at 197.97 ms, down from the previous Swift-only
343.00 ms band. The Unicode form measured 318.88 ms versus Rust at 199.56 ms
on the retained path.

Default Unicode surrounding-word output now also gets a direct Swift stdout
writer inside `RipgrepSearcher`, before the generic `SearchMatch` and
`StandardPrinter` path. It still buffers line ranges before writing, uses the
existing decoded matcher for non-ASCII candidate lines, and falls back without
emitting partial stdout if decoding fails or the buffered output grows too
large. Output for both default Unicode and `(?-u)` ASCII surrounding-word
queries on the 1.5 GiB subtitles corpus matched sibling Rust `rg` exactly
(483 lines). A nine-run direct check measured the Unicode form at 249.8 ms
versus 199.0 ms for Rust, down from the retained 318.88 ms harness band; the
focused upstream harness measured the same route at 272.54 ms versus Rust at
200.76 ms. The ASCII form stayed in the executable-preflight band at 217.4 ms
versus Rust at 197.3 ms.

The executable Swift surrounding-word preflight now also covers default Unicode
patterns when nearby non-ASCII context cannot affect `\w+\s+LITERAL\s+\w+`.
The scan still buffers all output before writing and returns to the full matcher
if non-ASCII word characters or known Unicode whitespace could create a match.
The existing Unicode-adjacent fixture continues to fall back for `Mø Holmes
returns` and `Dr Holmes étrange`; on the subtitles corpus, default Unicode
`-n '\w+\s+Holmes\s+\w+'` matched sibling Rust `rg` byte-for-byte (483 lines)
and improved from the 277.62 ms recheck band to 217.58 ms, while the ASCII form
measured 219.37 ms.

ASCII case-insensitive literal scanning now adds a middle-byte SIMD filter for
literals of at least eight bytes, keeping the existing first/tail filter but
avoiding many false candidate verifications on longer folded literals. Single
file subtitle output for `-i 'Sherlock Holmes'` and
`-n -i 'Sherlock Holmes'` matched sibling Rust `rg` byte-for-byte (871 lines).
The focused harness measured `subtitles_en_literal_casei` at 215.93 ms versus
the current-map 253.72 ms band, and the line-numbered form at 269.82 ms versus
298.79 ms. The same scanner also improved `subtitles_en_alternate_casei` from
304.57 ms to 279.65 ms. On the recursive Linux case-insensitive alternation,
Swift's traversal order still differs from Rust's, but sorted output content
matched and the harness improved from 4.717 s to 4.146 s.

Recursive case-insensitive ASCII alternations now also use a raw multi-literal
line collector for buffered `SearchMatch` output. The path only runs on
all-ASCII files, scans each folded literal across the file, sorts and dedupes
matched line ranges, and decodes only lines that will be emitted; files with
non-ASCII bytes fall back to the existing decoded matcher path. Sorted output
for the Linux kernel `ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT` workload
matched sibling Rust `rg` exactly (241 lines). A seven-run focused harness
measured `linux_alternates_casei` at 3.085 s versus Rust at 3.817 s, improving
the prior Swift 4.146 s band to a Swift win. Neighboring subtitle alternation
checks stayed faster than Rust: `subtitles_en_alternate` measured 124.86 ms
plain and 177.90 ms line-numbered.

Rejected Swift-only probes from the same checkpoint:

- A separate ASCII-only surrounding-word stdout writer that emitted matching
  lines during the scan preserved both ASCII and Unicode-form output, but did
  not improve the retained buffered executable preflight. The focused harness
  measured `subtitles_en_surrounding_words` at 219.13 ms for Unicode and
  219.71 ms for ASCII, versus the retained 217-219 ms band, so the shared
  buffered writer stays.
- A lazy first-hit probe before allocating the single-literal stdout buffer
  preserved no-match, plain, and line-numbered output, but did not improve the
  no-match case it targeted. A direct 15-run A/B measured `PM_RESUME` no-match
  at 184.54 ms versus 183.39 ms before, plain `Sherlock Holmes` at 187.65 ms
  versus 186.42 ms before, and `-n` at 216.82 ms versus 219.04 ms before. The
  mixed result is too noisy to keep.
- Replacing the recursive case-insensitive multi-literal path's
  `bytes.contains(where:)` non-ASCII guard with a Swift SIMD high-bit scan
  preserved sorted Linux output and subtitle `-n -i` output, but slowed the
  exact target. A direct seven-run A/B on
  `ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT` measured 2.936 s versus
  2.758 s for the retained guard, so the standard collection scan stays.
- Skipping no-shim construction of the now-unused case-insensitive shift tables
  in the recursive multi-literal collector preserved sorted Linux output, but
  the extra branch shape lost on median: a nine-run direct A/B measured
  2.967 s versus 2.793 s for the retained code. The C-compatible shift-table
  setup remains.
- Splitting the plain case-sensitive executable literal writer out of the
  generic line-number/boundary/case-folding writer preserved `Sherlock Holmes`
  output and no-match exit status, but the longer same-binary A/B was slower:
  plain `Sherlock Holmes` measured 187.78 ms versus 187.35 ms before, and
  no-match `PM_RESUME` measured 184.56 ms versus 183.82 ms before. The generic
  writer stays.
- A broader default-Unicode executable surrounding-word preflight preserved
  byte output by buffering matches and falling back on whole non-ASCII
  candidate lines, but that fallback double-scanned the representative corpus.
  Direct checks measured 397.3 ms and the focused harness measured 413.30 ms,
  versus the retained Unicode path at about 319 ms. The retained default-Unicode
  executable preflight uses the narrower local Unicode-context gate described
  above.
- Narrowing the Unicode direct writer's decoded fallback trigger to only
  non-ASCII bytes adjacent to the candidate word/whitespace regions also
  preserved byte-identical output, but the nine-run check was within noise:
  247.0 ms versus the retained direct writer's 249.8 ms band. The broader
  whole-line non-ASCII guard stayed because it is simpler and already captures
  most of the measured win.
- A Swift-only Boyer-Moore-Horspool scanner for long case-sensitive
  single-literal executable preflight output preserved byte-identical
  `Sherlock Holmes` output but was much slower than the retained SIMD first/tail
  scanner: the focused harness measured 567.16 ms for plain output and
  567.36 ms for the `--no-mmap` output-equivalent path, versus the retained
  roughly 187 ms/184 ms bands.
- Adding a third middle-byte SIMD filter to the first/tail literal scanner also
  preserved output, but the extra load did not pay for the representative
  phrase literal. The focused subtitles harness measured 204.39 ms plain,
  206.58 ms for `--no-mmap`, and 244.61 ms for `-n`, worse than the retained
  current-map bands at 187.16 ms, 184.24 ms, and 215.27 ms.
- Raising the no-mmap stream read size to 4 MiB preserved output but regressed
  both representative checks: plain output measured 293.0 ms versus 288.3 ms
  before in that run, and `-n` measured 355.3 ms versus 352.9 ms before. The
  2 MiB chunk size is the retained middle point.
- Raising the complete-line plain no-mmap path to 4 MiB chunks also regressed
  the representative subtitles check, measuring 327.9 ms versus the retained
  2 MiB result's 282.2 ms and 162.1 ms for Rust.
- Routing unlimited `Sherlock|Watson` through the bounded mmap/stdout writer's
  first-byte candidate scan preserved focused output but regressed the 1.5 GiB
  subtitles check to 377.5 ms versus the fallback path's same-turn 308.4 ms
  and 276.3 ms for Rust, so unlimited output stays on the existing path.
- Routing the five-name unbounded subtitles alternation through the bounded
  mmap/stdout writer's exact-candidate path also preserved output but regressed
  plain output to 622.6 ms and `-n` to 670.5 ms, versus the current focused
  bands at 591.4 ms and 624.3 ms.
- Emitting unique last-word suffix candidates directly in line order avoided
  collecting and sorting line bounds, but produced no clear plain-output win
  and regressed the line-numbered control: plain output measured 586.8 ms and
  `-n` measured 654.5 ms, versus the retained collect/sort suffix
  line-numbered path's 618.7 ms band.
- Fusing complete-line no-mmap line-number counting into the literal search
  preserved output after the split-chunk edge was fixed, but regressed
  `--no-mmap -n -i 'Sherlock Holmes'` to 474.6 ms versus the retained 424 ms
  band, so the separate chunk-level newline accounting remains in place.
- Delaying no-mmap stream compaction until a full 8 MiB consumed prefix,
  without the half-buffer trigger, preserved the same output shape but regressed
  plain `--no-mmap 'Sherlock Holmes'` to 301.7 ms and raised peak memory versus
  the 284.0 ms half-buffer/8 MiB hybrid, so the hybrid compaction trigger
  stayed in place.
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
- Guarding ignore-pattern trimming with a first/last-scalar whitespace check
  preserved exact Swift output and sorted Rust parity, but regressed the hot
  default listing. An 80-run A/B measured default `--files` at 140.4 ms mean /
  136.7 ms median versus 131.5 ms / 128.6 ms before; `--hidden --files`
  improved to 137.0 ms mean / 131.6 ms median versus 141.5 ms / 139.2 ms
  before. The simpler unconditional Foundation trim stays.
- Lowering the Darwin fast ignore-rule index threshold from 8 rules to 4 rules
  preserved exact Swift output and sorted Rust parity, but did not produce a
  reliable win. An 80-run A/B measured default `--files` at 116.4 ms mean /
  116.3 ms median versus 116.8 ms / 115.1 ms before; `--hidden --files`
  measured 118.2 ms mean / 115.6 ms median versus 115.5 ms / 115.5 ms before.
  The 8-rule threshold stays.
- Guarding basename prefix/suffix first-byte and last-byte lookups when their
  fast-index buckets were empty preserved exact Swift output, but regressed the
  hot controls. A 100-run A/B measured default `--files` at 140.1 ms mean
  versus 128.8 ms before, and `--hidden --files` at 137.9 ms mean versus
  128.9 ms before. The unconditional byte reads stay.
- Raising the direct no-ignore file-list output buffer from 64 KiB to 256 KiB
  preserved exact Swift output and sorted Rust parity, but did not improve the
  already-direct byte writer. A 100-run A/B measured `--no-ignore --files` at
  80.7 ms mean versus 79.8 ms before, and `--no-ignore --hidden --files` at
  80.6 ms mean versus 78.7 ms before. The 64 KiB buffer stays.
- Replacing indexed ignore prefix/suffix `String.hasPrefix`/`hasSuffix` checks
  with ASCII-only UTF-8 byte comparisons, plus a rule-index prefilter for
  candidates that could not beat the current match, preserved sorted Rust
  output for default, hidden, and no-ignore file listings and preserved quiet
  exit/output. It regressed the hot default listing badly in a same-machine
  30-run A/B: probe `--files` measured 217.77 ms median versus 153.96 ms before,
  with Rust at 96.97 ms. The existing String prefix/suffix checks stay.
- Adding one extra ordered parallel split inside large top-level ignore-aware
  `--files` subtrees preserved exact current Swift output and sorted Rust
  content, but the nested chunk collection and dispatch overhead overwhelmed
  any load-balancing win. A 30-run A/B measured default listing at 185.19 ms
  median versus 127.74 ms before, and hidden listing at 180.23 ms versus
  120.95 ms before. The root-only parallel split stays.
- Checking allowed files before recursing into child directories in the
  ignore-aware `--quiet --files` existence walker preserved quiet exit/output,
  but it did not improve the target. A 50-run A/B measured quiet listing at
  8.97 ms median versus 8.75 ms before, with Rust at 6.51 ms. The existing
  readdir-order walker stays.
- Pre-reserving 1024 entries for each parallel ignore-aware `--files` string
  chunk also failed to produce a reliable win. A noisy 50-run A/B measured
  default listing at 213.71 ms median versus 143.73 ms before, while hidden
  listing was only slightly faster at 140.57 ms versus 144.52 ms. The dynamic
  array growth stays.
- Replacing `IgnoreStack.decision`'s reversed matcher loop with an explicit
  unsafe-buffer reverse walk preserved exact Swift output and sorted Rust parity,
  but the measured result was unstable and did not survive an order-flipped
  confirmation. A noisy 60-run pass measured probe default listing at 392.9 ms
  mean / 383.0 ms median versus 383.5 ms / 363.2 ms before, and probe hidden
  listing at 258.2 ms mean / 231.0 ms median versus 214.6 ms / 206.8 ms before.
  The simpler reversed matcher loop stays.
- Replacing the root ignore-aware `--files` `DispatchGroup` scheduling with
  `DispatchQueue.concurrentPerform` preserved exact Swift output and sorted Rust
  parity, but regressed the primary default listing while only improving the
  hidden control. An 80-run A/B measured default `--files` at 150.3 ms mean /
  143.6 ms median versus 146.9 ms / 141.2 ms before, while `--hidden --files`
  measured 132.2 ms mean / 132.1 ms median versus 135.6 ms / 135.6 ms before.
  The existing root async group scheduling stays.
- Making `GlobMatcher.Rule.actualPattern` lazy/computed avoided normal-mode
  debug-pattern string storage and preserved exact Swift output plus sorted Rust
  parity, but did not improve the primary listing. A 100-run A/B measured
  default `--files` at 135.3 ms mean / 133.2 ms median versus 134.0 ms /
  131.8 ms before; `--hidden --files` was neutral at 132.9 ms mean /
  131.2 ms median versus 136.2 ms / 131.4 ms before. The stored debug pattern
  stays.
- A count-only multi-literal path that skipped line-bound storage and sorting
  preserved output, but measured neutral to slightly slower on
  `-c 'Sherlock|Watson'` over the 1.5 GiB subtitles corpus: 327.0 ms versus
  323.0 ms for the current scanner.
- Extending the transformed multi-literal candidate writer to plain unlimited
  matching-line output preserved output, but did not beat the current scanner:
  `-n 'Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor
  Moriarty'` measured 644.6 ms, and the plain form measured 586.4 ms, versus
  Rust at 311.2 ms and 279.7 ms.
- Broadly routing both plain and line-numbered two-word multi-literal output
  through unique last-word suffix candidates preserved output, but the plain
  form drifted from 577.1 ms to 583.9 ms in the original probe. The retained
  version is therefore limited to line-numbered output, where the suffix scan
  has a measured win.
- Rechecking that same plain suffix route after the retained parallel
  collect/sort literal scanner also preserved output but stayed neutral to
  slower: on the 1.5 GiB subtitles corpus the plain five-name alternation
  measured 347.1 ms versus 338.1 ms before and 279.2 ms for Rust, while `-n`
  measured 405.8 ms versus 398.1 ms before and 313.2 ms for Rust.
- A one-pass first-byte line scanner for the same five-literal alternation also
  preserved output, but regressed the representative subtitles corpus to
  980.8 ms for `-n` and 917.6 ms for plain output, versus Rust at about
  311 ms and 279 ms.
- A pure Swift DFA/Aho-Corasick mmap stdout probe for plain unlimited
  multi-literal line output matched Rust byte-for-byte on the 1.5 GiB
  `Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor
  Moriarty` subtitles case (1094 lines for both plain and `-n`), but smoke
  timings were about 2.04-2.08 s versus the committed scanner's roughly
  0.58-0.64 s band, so the repeated SIMD literal scans remain faster than a
  Swift per-byte transition-table loop.
- A parallel single-literal whole-line collector for large mapped
  case-sensitive searches preserved output for plain and `-n 'Sherlock
  Holmes'` on the 1.5 GiB subtitles corpus, but measured effectively neutral:
  plain output was 184.5 ms versus 185.6 ms before and 167.6 ms for Rust, while
  `-n` was 215.6 ms versus 218.0 ms before and 195.8 ms for Rust. The existing
  serial literal scanner stays simpler and just as fast for this sparse case.
- Reusing the retained line-aligned chunk collector for that same single
  literal also preserved output, but the focused harness did not improve the
  representative plain/no-mmap checks: plain measured 184.04 ms and no-mmap
  measured 183.34 ms, versus the retained 182.8/182.6 ms band. The `-n` median
  moved only from 213.45 ms to 212.70 ms, so the broader single-literal route
  stayed out.
- Scanning only the last word of a multi-word literal in the executable
  preflight, then verifying the full literal before output, preserved
  byte-identical output for plain and `-n 'Sherlock Holmes'`, but lost the
  representative single-literal check: plain output measured 186.6 ms versus
  the retained 184 ms band, and `-n` measured 216.9 ms versus the retained
  215 ms band. The full-literal SIMD first/tail scan stays in place.
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
- A Swift-only bounded-prefix multi-literal reader for `-m 1` and `-m 2`
  preserved output against both the previous Swift checkpoint and Rust,
  including no-match fallback output, but slowed representative subtitle checks:
  small-corpus `-m 1 'Sherlock|Watson'` measured 50.1 ms versus 46.1 ms before,
  and 200 MiB `-m 2` measured 46.0 ms versus 42.1 ms before.
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
- Extending the Swift-only multi-literal mmap/stdout preflight to unlimited and
  tiny bounded forms preserved output but regressed the representative controls:
  unlimited `Sherlock|Watson` measured 95.4 ms versus 76.1 ms before, and `-m1`
  measured 46.3 ms versus 42.3 ms before. The landed path is therefore limited
  to medium finite `-m` cases where it outperformed the previous scanner.
- Coalescing no-line-number vimgrep output into one temporary Swift buffer
  preserved byte-identical output, but copying the full line outweighed the
  reduced write calls. `--vimgrep -N 'Sherlock|Watson'` regressed to 78.3 ms
  from the prior 68.0 ms band; the `-N --no-column` variant measured 76.3 ms
  versus 79.1 ms before, which was too small and noisy to keep.
- Relaxing unlimited vimgrep matched-line bookkeeping to only track whether any
  match occurred preserved CLI output and exit status, but did not produce a
  durable win. A 15-run check measured `--vimgrep -o 'Sherlock|Watson'` at
  78.1 ms and default `--vimgrep 'Sherlock|Watson'` at 80.9 ms, both within
  normal run noise for the current direct writer.
- Replacing the Swift SIMD literal scanner's candidate `min() < 0` mask check
  with `wrappedSum() != 0` preserved output but regressed scanner-heavy cases:
  `--vimgrep 'Sherlock|Watson'` measured 83.5 ms and
  `-i 'sherlock|watson'` measured 93.2 ms, versus the current roughly 80 ms
  and 78 ms bands.
- Replacing short case-sensitive literal candidate verification with two
  unaligned `UInt64` comparisons preserved `Sherlock Holmes` output but slowed
  the shared line-numbered scanners. A seven-run focused check measured
  `subtitles_en_literal (lines)` at 232.00 ms, `subtitles_en_literal_word` at
  231.18 ms, and `subtitles_en_surrounding_words` at 231.74 ms, all worse than
  the retained roughly 215-218 ms bands, so the existing `memcmp` verifier stays.
- Dropping the always-loaded tail SIMD vector from the case-sensitive literal
  scanner and checking the tail byte only on first-byte candidate lanes
  preserved `Sherlock Holmes` plain and line-numbered output, but badly
  regressed the intended controls. The focused harness measured
  `subtitles_en_literal` at 250.01 ms, `subtitles_en_literal (no mmap)` at
  250.58 ms, and `subtitles_en_literal (lines)` at 291.29 ms, versus the
  retained roughly 184/184/215 ms bands. The first/tail SIMD filter stays.
- Widening the byte counter from `SIMD16` to `SIMD64` preserved output but was
  catastrophically slower on Apple Silicon: `--vimgrep 'Sherlock|Watson'`
  measured 351.2 ms, `-n -o 'Sherlock|Watson'` measured 346.8 ms, and
  `--count-matches -i a` measured 722.4 ms.
- Forcing the private Swift SIMD scanner helpers to inline and building with
  `-cross-module-optimization` were both neutral-to-noisy. The inline
  case-insensitive scanner measured `-i 'sherlock|watson'` at 78.1 ms and
  default vimgrep at 86.2 ms; a separate CMO scratch build measured vimgrep at
  79.7 ms, ignore-case multi-literal at 86.3 ms, and no-match `PM_RESUME` tied
  with the normal release build. Neither is worth encoding in the package.
- A one-pass first-byte scanner for safe multi-literal `--count-matches`
  preserved output for plain, path-prefixed, and include-zero no-match cases,
  but regressed the representative `Sherlock|Watson` count path. A 15-run A/B
  measured plain count at 89.7 ms versus 70.7 ms before, and path-prefixed count
  at 96.3 ms versus 76.5 ms before, while Rust stayed around 39.6-39.9 ms.

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
