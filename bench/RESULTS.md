# Performance benchmark — Swift port vs Rust ripgrep

Direct head-to-head using the patterns, flags, and corpora from the upstream
`ripgrep/benchsuite` script. Run on **Apple M3 Ultra (32 cores), macOS 26.5**
with `hyperfine 1.20.0`, 1 warm-up iteration + 2 timed iterations per case.

- `rg`: `ripgrep 15.1.0` (release build, system install)
- `swift-rg`: `ripgrep 15.1.0 (rev 4519153e5e)` (release build,
  `.build/release/ripgrep` produced by `swift build -c release`)

## Status — 2026-05-25 fast-path checkpoint

After the Darwin C fast-path work, the hot single-file ASCII cases are now
near Rust ripgrep, and several are faster in this environment. Single-file
benchmarks below use `/tmp/swift-rg-bench/subtitles/en.small.txt` (193 MiB).

| Bench | Flags | rg | swift-rg | swift / rg |
|---|---|---:|---:|---:|
| literal | `'Sherlock Holmes'` | 25.8 ms | 26.4 ms | **1.03x** |
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
this environment for the default literal search. A fresh confirmation run used
2 warm-ups and 7 timed iterations for the default Swift worker count and Rust
`rg`:

| Bench | Flags | rg | swift-rg | swift / rg |
|---|---|---:|---:|---:|
| Linux tree files | `--files` | 83.0 ms | 306.0 ms | **3.69x** |
| Linux tree files, no ignore | `--no-ignore --files` | 73.3 ms | 167.4 ms | **2.28x** |
| Linux tree files, no ignore/hidden | `--no-ignore --hidden --files` | 71.6 ms | 168.4 ms | **2.35x** |
| Linux tree files, quiet | `--quiet --files` | 6.5 ms | 44.3 ms | **6.82x** |
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
- PCRE2 fixed negative-lookaround literal shapes now use the same in-tree
  parser and Darwin byte scanner for `-P -o`, preserving Rust output while
  reducing representative negative lookbehind/lookahead cases by about two
  orders of magnitude versus the previous Swift path;
- PCRE2 literal-group backreferences such as `(a)(b)\2` now use the same
  in-tree parser and Darwin byte-output path for single-file `-P -o`, while
  still preserving capture replacement semantics through the non-executable
  matcher path;
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
