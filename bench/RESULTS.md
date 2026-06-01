# Performance benchmark — Swift port vs Rust ripgrep

Direct head-to-head using the patterns, flags, and corpora from the upstream
`ripgrep/benchsuite` script. Run on **Apple M3 Ultra (32 cores), macOS 26.5**
with `hyperfine 1.20.0`, 1 warm-up iteration + 2 timed iterations per case.

- `rg`: `ripgrep 15.1.0` (release build, system install)
- `swift-rg`: `ripgrep 15.1.0 (rev 4519153e5e)` (release build,
  `.build/release/ripgrep` produced by `swift build -c release`)

## Retuned ignore-aware file-list worker cap — 2026-06-01

The bounded Swift worker queue for the Darwin ignore-aware `--files` data
writer now caps root-child directory workers at 6 instead of 8. A cap scan over
4, 6, 8, 12, and 16 workers found 6 was the best median across default,
hidden, no-vcs, and NUL file-listing on the Linux tree. This keeps the previous
ordered chunk store and Swift-only implementation intact while reducing root
fan-out a little further.

Validation:

- Current Swift stdout/stderr/status matched checkpoint `35f56b4` byte-for-byte
  for default, hidden, no-vcs, no-ignore, NUL, and debug file-listing.
- Sorted current Swift paths matched Rust for default, hidden, and no-vcs
  file-listing on `/tmp/swift-rg-bench/linux`.
- The `--no-ignore` row was included as a guardrail; it uses the separate
  no-ignore writer and was effectively unchanged.

A 120-run interleaved process A/B against checkpoint `35f56b4` measured:

| Command | Current Swift | Previous Swift | Rust |
| --- | ---: | ---: | ---: |
| `--files linux` | 78.50 ms mean / 77.22 ms median | 80.05 ms / 78.81 ms | 75.44 ms / 74.99 ms |
| `--hidden --files linux` | 80.72 ms / 80.11 ms | 82.30 ms / 81.35 ms | 74.92 ms / 74.84 ms |
| `--no-ignore-vcs --files linux` | 60.66 ms / 59.72 ms | 62.78 ms / 62.41 ms | 67.93 ms / 67.25 ms |
| `--no-ignore --files linux` | 65.74 ms / 64.86 ms | 65.17 ms / 64.49 ms | 68.93 ms / 68.31 ms |
| `--null --files linux` | 77.87 ms / 76.52 ms | 79.60 ms / 78.93 ms | 76.12 ms / 75.12 ms |

## Rejected in-place logical path byte recursion — 2026-06-01

A Swift-only probe changed the ignore-aware Darwin `--files` data recursion to
mutate `logicalPathBytes` in place while descending, mirroring the no-ignore
byte walker's shape and avoiding one copy of the logical path byte array per
child directory. The probe preserved Swift stdout/stderr/status byte-for-byte
against checkpoint `6b002e1` for default, hidden, no-vcs, no-ignore, NUL, and
debug file-listing, and kept sorted Rust path parity for default, hidden, and
no-vcs controls. It was backed out because the median movement was flat to
tiny, while mean/p95 worsened in some rows.

An 80-run interleaved process A/B against checkpoint `6b002e1` measured:

| Command | Probe Swift | Baseline Swift | Rust |
| --- | ---: | ---: | ---: |
| `--files linux` | 79.19 ms mean / 77.50 ms median | 77.94 ms / 77.50 ms | 76.67 ms / 75.35 ms |
| `--hidden --files linux` | 80.89 ms / 79.90 ms | 81.54 ms / 80.18 ms | 75.76 ms / 75.14 ms |
| `--no-ignore-vcs --files linux` | 61.36 ms / 60.04 ms | 60.80 ms / 60.25 ms | 70.03 ms / 67.49 ms |
| `--null --files linux` | 78.38 ms / 77.77 ms | 78.86 ms / 77.82 ms | 76.34 ms / 75.18 ms |

## Bounded ignore-aware file-list workers — 2026-06-01

The ignore-aware Darwin `--files` data writer now runs top-level directory
subtrees through a bounded Swift worker queue instead of scheduling one GCD work
item per root child directory. Output is still stored by the original child
index and drained in order, so natural ordering is unchanged; the cap reduces
root fan-out and simultaneous filesystem pressure on the Linux tree without
adding C shims or low-level code.

Validation:

- Current Swift stdout/stderr/status matched checkpoint `90daab1` byte-for-byte
  for default, hidden, no-vcs, no-ignore, NUL, and debug file-listing.
- Sorted current Swift paths matched Rust for default, hidden, and no-vcs
  file-listing on `/tmp/swift-rg-bench/linux`.
- A probe scan over 4, 8, 12, 16, and 26 workers found the 4-8 worker band best;
  the retained cap is 8 to preserve the hidden-row win while still reducing
  default/no-vcs fan-out.

A 120-run interleaved process A/B against checkpoint `90daab1` measured:

| Command | Current Swift | Previous Swift | Rust |
| --- | ---: | ---: | ---: |
| `--files linux` | 83.47 ms mean / 80.36 ms median | 86.49 ms / 83.23 ms | 77.36 ms / 75.58 ms |
| `--hidden --files linux` | 85.98 ms / 82.72 ms | 88.67 ms / 85.39 ms | 78.40 ms / 75.33 ms |
| `--no-ignore-vcs --files linux` | 66.48 ms / 63.72 ms | 70.06 ms / 66.98 ms | 69.85 ms / 68.19 ms |
| `--no-ignore --files linux` | 68.58 ms / 65.67 ms | 69.17 ms / 66.44 ms | 71.21 ms / 69.37 ms |
| `--null --files linux` | 84.14 ms / 81.04 ms | 86.24 ms / 82.97 ms | 77.60 ms / 75.77 ms |

## Rejected file-list helper forced inlining — 2026-06-01

A Swift-only probe forced `@inline(__always)` on the tiny private helpers used
inside the Darwin file-list hot loops: path-line appends, UTF-8/path-component
appends, and the shared ignore-aware `shouldEmitFastFilePath` decision helper.
The probe preserved Swift stdout/stderr byte-for-byte for default, hidden,
no-vcs, no-ignore, and NUL file-listing, and kept sorted Rust path parity for
default, hidden, and no-vcs controls. It was backed out because the current
release optimizer's private-function inlining was already competitive and the
forced attributes were neutral-to-slower on the broader control set.

An 80-run interleaved process A/B against checkpoint `f439976` measured:

| Command | Probe Swift | Baseline Swift | Rust |
| --- | ---: | ---: | ---: |
| `--files linux` | 82.68 ms mean / 82.15 ms median | 82.79 ms / 82.26 ms | 75.66 ms / 75.11 ms |
| `--hidden --files linux` | 85.33 ms / 84.64 ms | 84.90 ms / 84.20 ms | 75.36 ms / 75.08 ms |
| `--no-ignore-vcs --files linux` | 67.17 ms / 66.47 ms | 67.04 ms / 66.44 ms | 69.08 ms / 67.88 ms |
| `--no-ignore --files linux` | 66.06 ms / 65.19 ms | 65.31 ms / 64.67 ms | 69.31 ms / 68.46 ms |
| `--null --files linux` | 82.70 ms / 82.49 ms | 82.64 ms / 81.94 ms | 75.30 ms / 75.15 ms |

## Rejected reversed-index file-list child walks — 2026-06-01

A Swift-only probe replaced the hot ignore-aware Darwin `--files` data writer's
`children.reversed()` loops with explicit descending index loops. The probe kept
the same root-child and recursive traversal order, preserved Swift stdout/stderr
byte-for-byte for default, hidden, no-vcs, no-ignore, and NUL file-listing, and
kept sorted Rust path parity for default, hidden, and no-vcs controls. It was
backed out because the optimizer already handles the reversed collection shape
well and the manual index form was flat-to-slower.

An 80-run interleaved process A/B against checkpoint `d32f4f8` measured:

| Command | Probe Swift | Baseline Swift | Rust |
| --- | ---: | ---: | ---: |
| `--files linux` | 84.62 ms mean / 82.68 ms median | 83.56 ms / 82.45 ms | 77.77 ms / 75.15 ms |
| `--hidden --files linux` | 86.21 ms / 85.52 ms | 86.09 ms / 84.73 ms | 76.78 ms / 75.16 ms |
| `--no-ignore-vcs --files linux` | 67.96 ms / 67.11 ms | 67.42 ms / 66.43 ms | 67.69 ms / 67.16 ms |
| `--no-ignore --files linux` | 67.04 ms / 65.01 ms | 65.77 ms / 64.78 ms | 70.85 ms / 67.96 ms |

## Rejected fixed-PCRE first-match split — 2026-05-31

A Swift-only probe split fixed-lookaround PCRE quiet/path-only searches out of
the general line-tracking loop, so `-P -q` and `-P --files-with-matches` could
return after the first verified byte match without initializing newline state.
The probe preserved stdout/stderr/status for positive lookbehind path-only,
quiet, no-match path-only, and a space-containing lookbehind prefix, but the
extra loop shape was slower on the hot positive path and was backed out.

A 120-run shell-free A/B against checkpoint `e7af0c5` measured:

| Command | Probe Swift | Baseline Swift | Rust |
| --- | ---: | ---: | ---: |
| `-P --files-with-matches '(?<=prefix)needle'` | 3.050 ms mean / 2.989 ms median | 2.720 ms / 2.714 ms | 2.506 ms / 2.504 ms |
| `-P -q '(?<=prefix)needle'` | 2.740 ms / 2.735 ms | 2.726 ms / 2.702 ms | 2.949 ms / 2.807 ms |
| `-P --files-without-match '(?<=prefix)needle'` | 2.701 ms / 2.684 ms | 2.803 ms / 2.715 ms | 8.146 ms / 8.116 ms |

## Rejected ordered file-list chunk drain — 2026-05-31

A Swift-only probe let the ignore-aware Darwin `--files` data writer consume
top-level chunks in output order as soon as each next chunk finished, rather
than waiting for every parallel subtree before writing. This preserved output
order by blocking on each ordered chunk, but the `NSCondition` coordination and
earlier writes did not beat the existing `DispatchGroup` wait plus snapshot.
The source change was backed out.

An 80-run interleaved A/B against checkpoint `e7af0c5` was mixed, so an
order-flipped 120-run confirmation was used for the decision:

| Command | Probe Swift | Baseline Swift | Result |
| --- | ---: | ---: | --- |
| `--files linux` | 82.67 ms mean / 82.29 ms median | 82.06 ms / 81.80 ms | slower |
| `--hidden --files linux` | 84.17 ms / 84.08 ms | 84.51 ms / 84.02 ms | flat |
| `--no-ignore-vcs --files linux` | 70.20 ms / 67.19 ms | 66.14 ms / 66.08 ms | slower |

## Rejected parallel search work-item removal — 2026-05-31

A Swift-only probe removed the transient `SearchWorkItem` array from the
parallel haystack search path and let the actor hand out indexed `Haystack`
values directly. This avoided one allocation/copy pass before recursive
parallel search, but the direct A/B against checkpoint `17640ee` was flat in
the quiet rows and slightly worse in file-listing controls, so the source
change was backed out.

The 20-run interleaved comparison used the release binary from checkpoint
`17640ee`, the probed current binary, and Rust `rg` on `/tmp/swift-rg-bench/linux`:

| Command | Probe Swift | Baseline Swift | Rust |
| --- | ---: | ---: | ---: |
| `-q PM_RESUME linux` | 371.86 ms mean / 379.76 ms median | 373.87 ms / 380.52 ms | 314.82 ms / 295.55 ms |
| `-q __swift_rg_missing_needle__ linux` | 930.54 ms / 924.74 ms | 935.36 ms / 927.67 ms | 2.755 s / 2.718 s |
| `--files linux` | 96.23 ms / 91.39 ms | 96.48 ms / 89.09 ms | 96.83 ms / 86.47 ms |
| `--hidden --files linux` | 102.85 ms / 105.74 ms | 102.27 ms / 102.66 ms | 86.16 ms / 76.85 ms |
| `PM_RESUME linux` | 1.613 s / 1.603 s | 1.611 s / 1.613 s | 2.711 s / 2.704 s |

## Rejected quiet worker-count retune — 2026-05-31

A worker-count scan tested whether quiet fallback search should raise or lower
the default Darwin parallelism. The current default cap of 4 workers remained
best for both a late hit and a miss on `/tmp/swift-rg-bench/linux`; explicit
`--threads 1`, `--threads 2`, `--threads 8`, `--threads 12`, and `--threads 16`
were all slower. No source change was retained.

Measured medians:

| Command | Default | `--threads 1` | `--threads 2` | `--threads 8` | `--threads 12` | `--threads 16` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `-q PM_RESUME linux` | 355.8 ms | 516.2 ms | 413.0 ms | 429.0 ms | 506.2 ms | 773.3 ms |
| `-q __swift_rg_missing_needle__ linux` | 924.2 ms | 2.003 s | 1.282 s | 1.486 s | n/a | n/a |

## Rejected required-literal quiet jump — 2026-05-31

A Swift-only probe for quiet regexes with one required ASCII literal jumped
directly to the literal with the existing fallback `memmem`, decoded only
candidate lines, and verified the real regex before returning a quiet match.
It preserved stdout/stderr/status for `[A-Z]+_RESUME`, a false-positive
`[Z]{3}_RESUME` miss, `.+_RESUME`, and literal-regex `PM_RESUME` against the
previous Swift checkpoint and Rust, but did not improve the target workload.

A 30-run A/B against checkpoint `0296d02` measured
`-q '[A-Z]+_RESUME' linux` at 250.0 ms for the probe versus 244.2 ms baseline
and Rust at 6.5 ms. The false-positive miss `-q '[Z]{3}_RESUME' linux`
remained flat at 960.7 ms versus 958.8 ms baseline, with Rust at 2.788 s. The
source change was backed out.

## Suppressed literal exact-path allocation cleanup — 2026-05-31

The suppressed literal-output path now builds the prepared ASCII
case-insensitive shift table only for case-insensitive literals. Plain exact
literal quiet/path/summary searches continue to reuse the original literal
buffer, avoiding one small per-file allocation in late-hit and miss walks.

Validation:

- Current Swift stdout/stderr/status matched checkpoint `0684746` and Rust for
  quiet exact hit/miss, quiet ignore-case hit, `--stats -q` exact and
  ignore-case hits, and `--json -q` exact and ignore-case hits after
  normalizing only elapsed timing fields.
- Current Swift path-only `-l EXPORT_SYMBOL` output matched checkpoint
  `0684746` byte-for-byte.
- `xcrun swift build -c release` passed before benchmarking.

A/B checks against checkpoint `0684746` measured:

| Command | Current Swift | Previous Swift |
| --- | ---: | ---: |
| `-q PM_RESUME linux` | 353.36 ms mean / 353.38 ms median | 360.15 ms / 356.65 ms |
| `-q ABSENT_NEEDLE_DOES_NOT_EXIST linux` | 919.08 ms / 912.09 ms | 913.17 ms / 912.10 ms |
| `-q -i pm_resume linux` | 7.46 ms / 7.45 ms | 8.80 ms / 8.51 ms |
| `-q EXPORT_SYMBOL linux` | 6.00 ms / 6.00 ms | 5.95 ms / 5.93 ms |

## ASCII ignore-case quiet probe budget — 2026-05-31

The bounded quiet byte-literal first-match probe now admits safe ASCII
ignore-case literals. It folds the single literal once per probed file and uses
the existing Swift fallback prepared ASCII scanner, while non-ASCII folded
literals still fall back to the normal matcher. The probe budget is now 32
searched files / 64 MiB, enough to catch the Linux-tree `pm_resume` hit at file
26 without making late hits and misses pay for a long pre-scan before the fast
quiet fallback walker takes over.

Validation:

- Current Swift stdout/stderr/status matched the saved pre-fast-fallback Swift
  binary and Rust for recursive quiet ignore-case hit/miss, late exact
  hit/miss, early exact hit, explicit-file ignore-case hit/miss, and an
  explicit README miss.
- Current Swift matched the saved Swift binary and Rust for `--stats -q -i`
  and `--json -q -i` hit/miss controls after normalizing only elapsed timing
  fields.
- `xcrun swift build -c release` passed before the final timing pass.

A/B checks against checkpoint `b2c4af8` measured:

| Command | Current Swift | Previous Swift |
| --- | ---: | ---: |
| `-q -i pm_resume linux` | 7.34 ms mean / 7.14 ms median | 241.21 ms / 235.95 ms |
| `-q ABSENT_NEEDLE_DOES_NOT_EXIST linux` | 928.16 ms / 918.47 ms | 937.20 ms / 921.77 ms |
| `-q PM_RESUME linux` | 354.88 ms / 353.62 ms | 356.56 ms / 352.49 ms |
| `-q EXPORT_SYMBOL linux` | 5.62 ms / 5.63 ms | 6.93 ms / 6.88 ms |

A direct 50-run Rust comparison for the target early ignore-case quiet hit
measured Rust `rg -q -i pm_resume linux` at 5.86 ms mean / 5.89 ms median and
current Swift at 7.41 ms / 6.86 ms. A broader probe that routed fixed-class
regex suffixes through the fast walker was not retained: it did not improve the
regex-suffix quiet case and regressed quiet miss / late exact / early exact
controls.

## Known-regular quiet read and suppressed literal output — 2026-05-31

Fast-walk haystacks now carry the existing known-regular-file signal through
the automatic Darwin read path. When size metadata is unavailable, the reader
tries the existing mmap reader directly instead of first asking
`selectedPath(for:)` to stat the path and then opening/fstatting again for the
mmap. The streaming eligibility check skips the same redundant selected-path
probe for those known-regular automatic reads. Suppressed literal output also
now handles plain quiet and safe ASCII ignore-case quiet/path/summary modes
without constructing line matches that will not be printed.

Validation:

- Current Swift stdout/stderr/status matched the saved pre-fast-fallback Swift
  binary byte-for-byte for recursive quiet hit/miss, early quiet hit,
  ignore-case quiet, regex-suffix quiet, and normalized `--stats -q -i` /
  `--json -q -i` controls.
- Current Swift matched Rust for the same quiet controls after normalizing only
  elapsed stats/JSON timing fields.
- Sampling `-q -i absent_needledoesnotexist /tmp/swift-rg-bench/linux` no
  longer showed the prior `HaystackReader.selectedPath` stack under the worker
  search path; remaining samples were dominated by existing mmap/open/fstat and
  the ASCII case-insensitive scanner.
- `xcrun swift build -c release` passed before benchmarking.

Tighter A/B checks against checkpoint `d185828` measured:

| Command | Current Swift | Previous Swift |
| --- | ---: | ---: |
| `-q PM_RESUME linux` | 353.9 ms mean / 353.5 ms median | 377.4 ms / 377.1 ms |
| `-q ABSENT_NEEDLE_DOES_NOT_EXIST linux` | 924.0 ms / 920.2 ms | 1035.5 ms / 1030.7 ms |
| `-q -i pm_resume linux` | 236.5 ms / 236.3 ms | 238.9 ms / 236.0 ms |
| `-q '[A-Z]+_RESUME' linux` | 240.9 ms / 238.2 ms | 239.5 ms / 238.3 ms |
| `-q EXPORT_SYMBOL linux` | 5.6 ms / 5.6 ms | 6.9 ms / 6.9 ms |

## Fast quiet file-URL directory hint — 2026-05-31

The fast quiet fallback walker now constructs known-file haystack URLs with
`URL(fileURLWithPath:isDirectory: false)`. The walker already filtered the
entry as a regular file, so giving Foundation the directory hint avoids the
extra file-type probe visible in samples of the fast quiet fallback walk.

Validation:

- Current Swift output matched the saved pre-fast-fallback Swift binary
  byte-for-byte for recursive quiet hit/miss, early quiet hit, ignore-case
  quiet, and regex-suffix quiet controls; Rust statuses matched.
- Sampling `-q PM_RESUME /tmp/swift-rg-bench/linux` after the change no longer
  showed the prior prominent per-file `lstat` stack under file URL creation.
- `xcrun swift build -c release` passed before benchmarking.

An alternating process-level A/B against checkpoint `696835d` measured:

| Command | Current Swift | Previous Swift |
| --- | ---: | ---: |
| `-q PM_RESUME linux` | 380.72 ms mean / 377.90 ms median | 613.78 ms / 593.06 ms |
| `-q ABSENT_NEEDLE_DOES_NOT_EXIST linux` | 1046.94 ms / 1045.24 ms | 1248.27 ms / 1251.67 ms |
| `-q -i pm_resume linux` | 240.70 ms / 237.06 ms | 467.78 ms / 452.23 ms |
| `-q '[A-Z]+_RESUME' linux` | 242.38 ms / 241.91 ms | 461.83 ms / 459.52 ms |
| `-q EXPORT_SYMBOL linux` | 5.96 ms / 5.95 ms | 6.09 ms / 6.02 ms |

## Fast quiet fallback haystack walk — 2026-05-31

Recursive quiet search now reuses the existing Darwin fast search-file walker
when the bounded first-match probe cannot finish the search. This keeps normal
line/path output traversal unchanged, but avoids restarting late quiet hits and
quiet misses through the generic `URL`/metadata-heavy haystack walker. The
raw-literal first-match probe now stops after 16 searched files instead of 64;
the original 16 MiB byte cap remains, preserving the cheap early-hit behavior
for large files while reducing redundant probe work before the fast fallback.

Validation:

- Current Swift output matched the saved previous Swift binary byte-for-byte for
  recursive quiet hit/miss, early quiet hit, explicit-file quiet hit/miss,
  ignore-case quiet, word quiet, regex-suffix quiet, binary fallback,
  `--quiet --files`, and `--stats -q` controls.
- The same controls matched Rust exit statuses; output remained empty or
  unchanged where applicable.
- `xcrun swift build -c release` passed before benchmarking.
- `xcrun swift test` passed after the implementation.

Final process-level checks on `/tmp/swift-rg-bench/linux` measured:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-q PM_RESUME linux` | 606.44 ms mean / 595.55 ms median | 1021.61 ms / 1016.90 ms | 258.88 ms / 221.99 ms |
| `-q ABSENT_NEEDLE_DOES_NOT_EXIST linux` | 1276.36 ms / 1281.79 ms | 1632.54 ms / 1627.78 ms | 2943.48 ms / 2973.98 ms |
| `-q EXPORT_SYMBOL linux` | 6.24 ms / 6.12 ms | 6.31 ms / 6.09 ms | 5.66 ms / 5.26 ms |
| `-q -i pm_resume linux` | 475.80 ms / 454.62 ms | 926.90 ms / 904.25 ms | 6.03 ms / 6.01 ms |
| `-q '[A-Z]+_RESUME' linux` | 463.86 ms / 455.46 ms | 902.34 ms / 890.87 ms | 7.17 ms / 7.08 ms |
| `--quiet --files linux` | 5.29 ms / 5.25 ms | 5.40 ms / 5.31 ms | 5.50 ms / 5.24 ms |

A smaller four-file probe cap was parity-clean but slower on the target late
and no-match quiet controls, so the retained cap is 16 files.

## Utility-mode preflight bypass — 2026-05-31

The Swift executable now bypasses the Darwin literal preflight parser for
first-argument utility/file-listing modes (`-h`, `--help`, version flags,
`--generate`, and `--files`). Those modes cannot use the single-file literal
preflight, and stdin readability cannot affect their output, so the entry point
also skips the `fstat(stdin)` readability probe for the same commands.

Validation:

- Current Swift output matched the saved previous Swift binary byte-for-byte for
  default, hidden, `--no-ignore-vcs`, `--no-ignore`, and NUL-terminated
  file-listing controls on `/tmp/swift-rg-bench/linux`.
- Current Swift output matched the saved previous Swift binary byte-for-byte for
  `--help`, `-h`, `--version`, `--pcre2-version`, `--generate man`, recursive
  `PM_RESUME`, `-i pm_resume`, and dash-looking `-e --files` / `-e --help`
  pattern controls.
- Sorted current Swift output matched Rust for default, hidden, and no-vcs
  file-listing controls on the same tree.

An isolated alternating 240-pair process-level harness against the prior
checkpoint measured the first-argument `--files` addition as neutral for file
listing:

| Command | Current Swift | Previous Swift | Delta |
| --- | ---: | ---: | ---: |
| `--files linux` | 81.83 ms mean / 81.38 ms median | 82.00 ms / 81.40 ms | -0.17 ms / -0.02 ms |
| `--hidden --files linux` | 89.98 ms / 87.14 ms | 89.51 ms / 86.66 ms | +0.47 ms / +0.48 ms |
| `--no-ignore-vcs --files linux` | 73.64 ms / 74.27 ms | 73.18 ms / 73.88 ms | +0.46 ms / +0.39 ms |
| `--no-ignore --files linux` | 66.56 ms / 64.58 ms | 66.34 ms / 64.66 ms | +0.22 ms / -0.08 ms |

The same probe stabilized the utility classifier fast path. An alternating
300-pair process-level harness measured:

| Command | Current Swift | Previous Swift | Delta |
| --- | ---: | ---: | ---: |
| `--help` | 6.36 ms mean / 6.13 ms median | 9.77 ms / 9.35 ms | -3.41 ms / -3.22 ms |
| `-h` | 6.06 ms / 6.06 ms | 9.29 ms / 9.27 ms | -3.23 ms / -3.22 ms |
| `--version` | 3.70 ms / 3.66 ms | 3.67 ms / 3.63 ms | +0.03 ms / +0.03 ms |
| `--pcre2-version` | 3.65 ms / 3.63 ms | 3.62 ms / 3.60 ms | +0.03 ms / +0.03 ms |
| `--generate man` | 6.13 ms / 6.13 ms | 9.38 ms / 9.34 ms | -3.25 ms / -3.21 ms |
| `--generate=man` | 6.17 ms / 6.16 ms | 9.46 ms / 9.40 ms | -3.28 ms / -3.24 ms |

A broader pre-scan that rejected `--files` anywhere in the argument vector was
backed out: it preserved output parity but added measurable overhead to the
default file-list path. The retained check only looks at the first argument and
only skips modes whose output is independent of stdin readability.

## Common-prefix sorted file-list keys — 2026-05-31

Sorted file-list output for a single explicit directory now builds sort keys
from the suffix after the shared ASCII root path prefix. The emitted paths are
unchanged; only the per-line key used for `--sort path` / `--sortr path`
skips bytes that are identical for every candidate in the fast Darwin
file-list route. The key builder also now fills a reserved byte array directly
from `String.withUTF8`, avoiding the intermediate dropped UTF-8 view used by
the prior implementation.

Validation:

- Current Swift output matched the saved previous Swift binary byte-for-byte for
  sorted, reverse-sorted, hidden no-ignore, no-vcs, default ignore-aware, and
  NUL sorted file-list controls on `/tmp/swift-rg-bench/linux`.
- Current Swift output matched Rust ordered output byte-for-byte for sorted and
  reverse-sorted no-ignore/default controls on the same tree.
- A non-ASCII explicit root smoke matched the saved previous Swift binary and
  kept prefix trimming disabled for non-ASCII root prefixes.

An alternating 80-pair process-level harness measured:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--sort path --no-ignore --files linux` | 164.73 ms mean / 166.73 ms median | 197.59 ms / 199.31 ms | 145.60 ms / 146.39 ms |
| `--sortr path --no-ignore --files linux` | 157.43 ms / 150.42 ms | 187.26 ms / 179.44 ms | 175.27 ms / 167.97 ms |
| `--sort path --hidden --no-ignore --files linux` | 144.53 ms / 143.89 ms | 175.30 ms / 173.40 ms | 134.49 ms / 132.93 ms |
| `--sort path --no-ignore-vcs --files linux` | 111.73 ms / 110.14 ms | 143.36 ms / 141.42 ms | 166.41 ms / 163.96 ms |
| `--sort path --files linux` | 125.52 ms / 124.26 ms | 155.56 ms / 154.82 ms | 234.67 ms / 232.43 ms |
| `--sortr path --files linux` | 125.32 ms / 123.78 ms | 156.02 ms / 153.73 ms | 272.37 ms / 269.64 ms |

A follow-up alternating 100-pair harness against the common-prefix checkpoint
measured the manual key builder:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--sort path --no-ignore --files linux` | 157.66 ms mean / 149.62 ms median | 159.30 ms / 150.43 ms | 141.62 ms / 135.60 ms |
| `--sortr path --no-ignore --files linux` | 155.30 ms / 146.75 ms | 158.14 ms / 149.17 ms | 176.53 ms / 168.03 ms |
| `--sort path --hidden --no-ignore --files linux` | 141.78 ms / 140.20 ms | 144.17 ms / 142.89 ms | 134.89 ms / 132.76 ms |
| `--sort path --no-ignore-vcs --files linux` | 108.29 ms / 106.85 ms | 110.59 ms / 109.35 ms | 163.55 ms / 162.39 ms |
| `--sort path --files linux` | 122.22 ms / 121.29 ms | 124.71 ms / 123.84 ms | 233.30 ms / 232.67 ms |
| `--sortr path --files linux` | 125.02 ms / 122.44 ms | 129.52 ms / 125.26 ms | 274.85 ms / 270.45 ms |

The sorted emitter now also chooses the forward or reverse comparator before
calling `sorted`, avoiding a reverse-mode branch inside every key comparison.
Output still matched the previous Swift binary byte-for-byte and matched Rust
ordered output for the sorted Linux file-list controls. A 140-pair confirmation
against checkpoint `8b9f74c` measured small median wins:

| Command | Current Swift | Previous Swift |
| --- | ---: | ---: |
| `--sort path --no-ignore-vcs --files linux` | 107.46 ms mean / 106.43 ms median | 107.20 ms / 106.62 ms |
| `--sort path --files linux` | 121.92 ms / 120.17 ms | 121.22 ms / 120.70 ms |
| `--sortr path --files linux` | 120.48 ms / 119.75 ms | 121.49 ms / 120.14 ms |
| `--sort path --no-ignore --files linux` | 147.41 ms / 146.14 ms | 147.28 ms / 146.22 ms |

## Hoisted executable argument snapshot — 2026-05-31

The Swift executable entry point now materializes
`Array(CommandLine.arguments.dropFirst())` once and reuses it for Darwin
preflight checks and the normal `RipgrepCLI.run` path. This removes duplicate
argument-array allocation on non-preflight commands without changing parsing,
preflight eligibility, or exit behavior.

Validation:

- Current Swift output matched the saved previous Swift binary byte-for-byte for
  default, hidden, `--no-ignore-vcs`, `--no-ignore`, and NUL-terminated
  file-listing controls on `/tmp/swift-rg-bench/linux`.
- Sorted current Swift output matched Rust for default, hidden, and no-vcs
  file-listing controls on the same tree.
- Current Swift output matched the saved previous Swift binary for recursive
  `PM_RESUME`, `-i pm_resume`, and `--help` controls.

An alternating 90-pair process-level harness measured:

| Command | Current Swift | Previous Swift | Delta |
| --- | ---: | ---: | ---: |
| `--files linux` | 82.87 ms mean / 82.46 ms median | 83.60 ms / 81.97 ms | -0.72 ms / +0.49 ms |
| `--hidden --files linux` | 84.25 ms / 83.41 ms | 85.14 ms / 84.08 ms | -0.89 ms / -0.67 ms |
| `--no-ignore-vcs --files linux` | 66.29 ms / 65.61 ms | 66.80 ms / 65.57 ms | -0.51 ms / +0.04 ms |
| `--help` | 6.17 ms / 6.16 ms | 9.44 ms / 9.40 ms | -3.28 ms / -3.24 ms |

## Buffered path-only preflight output — 2026-05-31

Single-file Darwin path-only preflights now emit the display path and its
newline/CRLF/NUL terminator through the existing Swift stdout buffer in one
flush. This avoids a separate terminator write while preserving the same path
bytes and terminator semantics for `-l` and `--files-without-match` forms.

Validation:

- Current Swift output matched the saved previous Swift binary byte-for-byte for
  `--files-without-match` match/no-match, NUL, CRLF, `--files-with-matches`,
  `--stats --files-without-match`, and `--json --files-without-match` controls
  on the 46 MiB ASCII fixture.
- Current Swift output matched Rust byte-for-byte for path-only
  `--files-without-match`, NUL, CRLF, and `--files-with-matches` controls on the
  same explicit file.

On `/tmp/swift-rg-bench/match-ascii-46m.txt`, timed with 10-20 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--files-without-match absentliteral` | 6.9 ms | 7.0 ms | 6.4 ms |
| `--stats --files-without-match absentliteral` | 7.7 ms | 8.0 ms | 6.9 ms |
| `--json --files-without-match absentliteral` | 7.7 ms | 7.9 ms | 6.9 ms |

## Direct JSON summary writer — 2026-05-31

JSON no-match summaries now share the same direct Swift stdout buffer path as
text stats summaries: the writer emits the fixed JSON prefix, decimal
`bytes_searched`, and fixed suffix without allocating an interpolated
`String`/`Data` payload.

Validation:

- Current Swift output matched the saved previous Swift binary byte-for-byte for
  `--json`, `--json -q`, `--json -i`, and `--json --files-without-match`
  no-match/match controls on the 46 MiB ASCII fixture.
- Current Swift output matched Rust for `--json`, `--json -q`, and `--json -i`
  no-match summaries after normalizing only JSON elapsed-time fields.

On `/tmp/swift-rg-bench/match-ascii-46m.txt`, 200 timed runs with 10 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--json absentliteral` | 7.7 ms | 8.9 ms | 7.8 ms |
| `--json -q absentliteral` | 7.5 ms | 8.6 ms | 6.9 ms |

## Direct stats summary writer — 2026-05-31

Single-file Darwin preflight stats summaries now use the existing Swift stdout
buffer and decimal writer instead of constructing one interpolated Swift
`String` and wrapping it in `Data`. This keeps the summary format identical
while trimming the summary-only path.

Validation:

- Current Swift output matched the saved previous Swift binary byte-for-byte for
  `--stats --files-without-match` match/no-match, `--stats -l`,
  `--stats --count`, and `--stats --count-matches` on the 46 MiB ASCII fixture.
- Current Swift output matched Rust for the same modes after normalizing only
  elapsed-time stats lines.

On `/tmp/swift-rg-bench/match-ascii-46m.txt`, timed with 10 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--stats --files-without-match absentliteral` | 7.7 ms | 8.3 ms | 6.9 ms |
| `--stats -l missingliteral` | 37.8 ms | 38.9 ms | 38.5 ms |

## NUL-terminated file-list direct writer — 2026-05-31

The Darwin file-list direct writer now supports `-0`/`--null` by threading the
path terminator byte through the existing ignore-aware and no-ignore data
writers. This keeps NUL-terminated `--files` output on the same Swift-first
parallel writer as newline-terminated file lists instead of falling back to the
generic URL/string path.

Validation:

- `--null --files /tmp/swift-rg-bench/linux` output matched the saved previous
  Swift binary byte-for-byte.
- Splitting NUL-delimited probe output and sorting paths matched Rust on the
  same tree.
- Regular `--files` output still matched the previous Swift binary
  byte-for-byte, and sorted output matched Rust.

On `/tmp/swift-rg-bench/linux`, 80 timed runs with 5 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--null --files linux` | 82.4 ms | 945.8 ms | 73.5 ms |

Regular `--files` stayed in the same band in a guard run: current Swift
80.4 ms, previous Swift 83.0 ms, Rust 74.9 ms.

## Hidden-path ignore short-circuit — 2026-05-31

The ignore-aware Darwin file-listing writer now skips the recursive ignore
stack lookup for hidden children when the active stack has no include rules.
That keeps default hidden filtering on the cheap path while preserving the
single decision lookup needed when ignore rules can explicitly re-include a
hidden path.

Validation:

- Current Swift `--files` output matched the saved probe byte-for-byte.
- Sorted current Swift output matched Rust on `/tmp/swift-rg-bench/linux`.
- `--no-ignore --files` remained in the same noisy band as Rust and does not use
  this ignore-aware branch.

On `/tmp/swift-rg-bench/linux`, 60 timed runs with 5 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--files linux` | 81.8 ms | 83.6 ms | 73.8 ms |

## Empty ignore-stack file-list branch — 2026-05-31

The ignore-aware Darwin file-listing data writer now skips per-child inherited
ignore decisions whenever the current directory's ignore stack is empty. It
still recurses normally, so child directories continue to load their own
`.ignore`/`.gitignore` files before filtering descendants.

Validation:

- Probe output matched the saved current Swift binary byte-for-byte for
  `--files /tmp/swift-rg-bench/linux`.
- Sorted probe output matched Rust on the same tree.

On `/tmp/swift-rg-bench/linux`, 80 timed runs with 5 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--files linux` | 82.6 ms | 85.1 ms | 75.8 ms |

### Rejected continuation probes — 2026-05-31

The following Swift-first/no-C-shim probes preserved exact Swift output and
Rust-compatible sorted file-list output where applicable, but were backed out
because they did not improve the current checkpoint:

- Threading physical directory paths as UTF-8 byte buffers through the
  ignore-aware data walker was mixed and noisy. The flipped confirmation
  measured default `--files` at 81.1 ms for the probe versus 84.8 ms baseline,
  hidden at 83.9 ms versus 83.8 ms, and `--no-ignore-vcs` at 69.7 ms versus
  66.4 ms, so the string physical-path walker stayed.
- Raising the ignore-aware data walker queue QoS from `.userInitiated` to
  `.userInteractive` was flat-to-slower: default `--files` measured 81.8 ms
  versus 81.5 ms baseline, hidden 85.2 ms versus 83.9 ms, and `--no-ignore-vcs`
  68.4 ms versus 65.9 ms.
- Combining path/count output and no-match stats summary writes into one helper
  preserved stdout/stderr/status for stats and JSON controls, but regressed the
  explicit-file stats rows: `--stats --files-without-match absentliteral`
  measured 8.5 ms versus 8.2 ms baseline and Rust at 7.5 ms.
- Classifying `.git`/`.gitignore`/`.ignore`/`.rgignore` markers from directory
  entry bytes instead of switching on the decoded `String` was also rejected.
  Exact file-list output matched the saved Swift checkpoint and sorted Rust, but
  the 80-run A/B measured default `--files` at 82.1 ms versus 82.3 ms baseline,
  hidden at 90.2 ms versus 84.4 ms, and `--no-ignore-vcs` at 66.2 ms versus
  65.6 ms.
- Removing intermediate `fflush(stdout)` calls between preflight output and
  stats summaries preserved exact stdout/stderr/status, but the order-flipped
  160-run confirmation did not hold: `--stats --files-without-match` measured
  7.9 ms versus 7.5 ms baseline, `--stats --include-zero -c` was flat at
  7.6 ms, `--stats -c literal` regressed to 19.1 ms versus 18.8 ms, and visible
  `--stats literal` was flat at 67.4 ms.
- Lazily constructing recursive `directory/` and `relative/` prefixes only when
  the empty-ignore-stack file-list branch saw a child directory preserved exact
  Swift output and sorted Rust parity, but did not improve the full file-list
  control set. A 100-run A/B measured default `--files` at 82.3 ms versus
  83.4 ms baseline, hidden flat at 85.4 ms versus 85.1 ms, and
  `--no-ignore-vcs` slower at 67.8 ms versus 66.3 ms.
- Unifying the top-level non-empty ignore-stack file-list filter through
  `shouldEmitFastFilePath` preserved exact Swift output and sorted Rust parity,
  but slowed the primary controls. A 100-run A/B measured default `--files` at
  82.3 ms versus 81.6 ms baseline and `--no-ignore-vcs` at 67.0 ms versus
  66.0 ms. Hidden mode was noisy at 84.9 ms versus 85.9 ms, so the manual root
  branch stayed.
- Passing `RipgrepSearcher`'s stored environment directly into `FileWalker`
  avoided a redundant `ProcessInfo.processInfo.environment` default-argument
  read and preserved exact Swift output plus sorted Rust parity, but process
  timings did not improve. A 120-run A/B measured default `--files` at
  83.7 ms versus 82.5 ms baseline, hidden at 85.1 ms versus 86.4 ms, and
  `--no-ignore-vcs` at 68.8 ms versus 67.3 ms.
- Shrinking the parallel ignore-aware file-list worker's initial `Data`
  reserve from 64 KiB was also rejected. A 16 KiB probe preserved exact Swift
  output and sorted Rust parity but measured default `--files` at 82.7 ms
  versus 83.0 ms baseline, hidden slower at 86.8 ms versus 85.9 ms, and
  `--no-ignore-vcs` faster at 66.1 ms versus 68.0 ms. A 32 KiB follow-up was
  flat on default/hidden and slower on `--no-ignore-vcs` at 66.9 ms versus
  66.1 ms, so the 64 KiB reserve stayed.
- Adding a single-matcher shortcut to `IgnoreStack.decision` preserved exact
  Swift output and sorted Rust parity but slowed default file listing in a
  140-run A/B: default `--files` measured 86.8 ms versus 84.2 ms baseline,
  hidden was flat at 99.7 ms, and `--no-ignore-vcs` only moved within noise at
  66.4 ms versus 67.0 ms.
- Raising the string-based Darwin directory child-array reserve from 64 to 128
  entries also failed confirmation. It preserved exact Swift output and sorted
  Rust parity; a first hyperfine run looked mildly positive for default and
  no-vcs file listing, but an 80-pair alternating harness measured default
  `--files` flat at 82.64 ms versus 82.49 ms baseline, hidden at 84.07 ms
  versus 84.37 ms, `--no-ignore-vcs` at 66.87 ms versus 67.16 ms, and
  `--no-ignore` at 65.28 ms versus 65.15 ms. The original 64-entry reserve
  stayed.
- Routing raw-literal buffer eligibility through walker-provided `Haystack`
  metadata, then skipping the streaming preflight when that buffered raw path
  would be chosen anyway, also stayed rejected. Both forms preserved exact Swift
  output for quiet literal match/no-match, explicit literal output, path-only
  output, and binary-NUL controls, with matching Rust quiet statuses. The
  metadata-only probe measured `PM_RESUME -q` flat at 1.016 s median versus
  1.016 s baseline, no-match quiet slightly slower at 1.581 s versus 1.574 s,
  and `spin_lock -n` flat at 1.739 s. The combined skip-stream probe likewise
  stayed flat-to-slower: `PM_RESUME -q` 1.018 s versus 1.014 s, no-match quiet
  1.587 s versus 1.582 s, `spin_lock -n` 1.740 s versus 1.735 s, and
  `spin_lock -l` 1.654 s versus 1.652 s. The existing streamed-search gate and
  file-attribute helper stayed.
- Returning immediately from `GlobMatcher.fastDecision` when the Darwin fast
  index had no unindexed fallback rules preserved exact Swift output for default,
  hidden, no-vcs, debug, and sorted file-list controls, with sorted Rust parity.
  It was not retained because the 80-pair A/B was mixed: default `--files`
  improved to 81.06 ms median versus 82.13 ms baseline, but hidden regressed to
  83.52 ms versus 83.15 ms, no-vcs to 66.37 ms versus 65.94 ms, and sorted
  default stayed flat at 121.16 ms versus 121.04 ms.
- Decoding raw Greek-script candidate lines from an
  `UnsafeBufferPointer<UInt8>` instead of copying them into temporary `Data`
  preserved exact Swift output and sorted Rust parity, but did not improve the
  Linux Unicode category bench. A 12-pair process A/B measured `-n \p{Greek}`
  at 1948.7 ms versus 1946.9 ms baseline and `-n -i \p{Greek}` at 1949.6 ms
  versus 1938.6 ms baseline, so the existing `Data` decode path stayed.
- Suppressing the internal 64 KiB flushes while the parallel no-ignore
  file-list writer is already collecting each ordered subtree chunk preserved
  exact Swift output and sorted Rust parity, but the main no-ignore controls
  were flat. A 160-pair A/B measured `--no-ignore --files` at 64.75 ms versus
  65.19 ms baseline by mean but 64.07 ms versus 63.98 ms by median, hidden
  no-ignore at 70.47 ms versus 70.49 ms by mean but 71.34 ms versus 71.17 ms
  by median, NUL no-ignore mildly faster at 75.91 ms versus 76.09 ms median,
  and the all-ignore-disabled spelling flat at 64.38 ms versus 64.29 ms median.
  The existing flush-and-collect structure stayed.
- Broadening the entry-point utility classifier shape was also rejected. A
  targeted second-argument `--files` bypass preserved exact Swift output and
  sorted Rust parity, but regressed the no-ignore/no-vcs controls by
  0.22-0.30 ms median while only helping NUL by 0.14 ms median. A narrower
  non-optional first-argument helper kept the utility-mode startup win
  (`--help` and `--generate man` about 3.3 ms faster) but regressed primary
  file-list medians by 0.20-0.60 ms, so the original optional first-argument
  classifier stayed.
- Removing the direct Darwin file-list writer's duplicate
  `FileManager.fileExists` root probe was also rejected. `fastFilePathRootPlan`
  already performs an `lstat`, and the fallback path preserved exact Swift
  output for existing/missing roots plus sorted Rust parity, but the 180-pair
  A/B regressed default `--files` by 0.22 ms median, hidden by 0.71 ms, no-vcs
  by 0.06 ms, no-ignore by 0.20 ms, and NUL by 0.23 ms. Quiet stayed flat at
  4.95 ms versus 4.93 ms, so the explicit root-existence branch stayed.
- Routing sorted no-ignore file lists through the byte-oriented no-ignore
  writer preserved exact Swift output and Rust ordered output, but did not
  improve median timings. The key-array sorter measured `--sort path
  --no-ignore --files` flat at 180.72 ms versus 180.74 ms baseline and regressed
  all-ignore-disabled sorting to 163.29 ms versus 161.26 ms. A follow-up
  in-place byte-slice comparator avoided per-path key allocation but stayed
  flat on the primary case at 179.88 ms versus 179.83 ms and regressed reverse
  sort to 181.39 ms versus 179.15 ms, so the existing string sorted path stayed.
- Raising the sorted file-list collector's initial reserve from 1,024 to 16,384
  entries preserved exact Swift output and Rust ordered output, but was flat to
  slower in an 80-pair A/B against checkpoint `59c9294`: `--sort path
  --no-ignore --files` measured 149.92 ms median versus 150.07 ms baseline,
  reverse no-ignore 166.13 ms versus 166.04 ms, hidden no-ignore 142.49 ms
  versus 142.31 ms, no-vcs 108.17 ms versus 108.04 ms, default 122.17 ms
  versus 121.69 ms, and reverse default 122.64 ms versus 121.66 ms. The 1,024
  reserve stayed.
- Sorting reverse file-list output with the forward comparator and then
  iterating the sorted array in reverse also stayed rejected. It preserved exact
  Swift output and Rust ordered output, but an alternating 120-pair A/B against
  checkpoint `2e0dcad` regressed every reverse control: no-ignore reverse
  sorting measured 145.86 ms median versus 144.77 ms baseline, hidden no-ignore
  reverse sorting 140.07 ms versus 139.23 ms, and default reverse sorting
  123.20 ms versus 121.87 ms. The dedicated reverse comparator stayed.
- Copying the sorted path-key UTF-8 suffix into an array and then rewriting
  slash bytes in place also stayed rejected. It preserved exact Swift output
  and Rust ordered output, but an alternating 100-pair A/B against checkpoint
  `9163edf` regressed no-ignore sorting to 146.00 ms median versus 145.62 ms,
  reverse no-ignore to 146.24 ms versus 145.92 ms, hidden no-ignore to
  147.33 ms versus 145.26 ms, and no-vcs to 109.16 ms versus 108.34 ms. The
  default sorted medians were slightly faster, but not enough to offset the
  broader sorted-control regressions, so the reserved append builder stayed.

## Visible line stats preflight — 2026-05-31

Single explicit-file `--stats` searches that emit normal matching lines now use
the Swift Darwin literal preflight when the pattern is a safe literal or ASCII
word literal and no formatting mode changes the visible line shape. The route
computes the stats summary before writing output, then emits matching lines
while tracking Rust-compatible `bytes printed`, including the no-final-newline
case where the displayed synthetic newline is not counted in stats.

Validation:

- Current Swift stdout/stderr/status matched Rust for plain `--stats`,
  line-numbered `--stats -n`, prefixed `--stats -H`, `--stats --heading -H`,
  and the no-match summary after normalizing only elapsed-time stats lines.
- `xcrun swift test --filter MiscTests/darwinExecutableLiteralPreflightDenseLines`
  passed with exact visible-stats summary coverage.

On `/tmp/swift-rg-candidates/countm-big.txt`, 30 timed runs with 3 warmups:

| Command | Current Swift | Preflight bypassed | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--stats needle countm-big.txt` | 20.7 ms | 2.197 s | 25.5 ms |

## Larger stdout block buffer for bulk file lists — 2026-05-31

Non-tty stdout now uses a 256 KiB stdio block buffer instead of 64 KiB. This is
a runtime-level Swift/Darwin tuning change: it does not alter traversal,
filtering, path formatting, or search semantics, but reduces flush churn for
large `--files` style outputs.

Validation:

- `xcrun swift build -c release` passed before benchmarking.
- Current Swift `--files` output stayed path-set equivalent to Rust on the
  Linux benchmark tree; this repo already tracks sorted parity for file lists
  because raw traversal order differs.

On the Linux tree under `/tmp/swift-rg-bench`, 40 timed runs with 5 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--files linux` | 81.3 ms | 91.7 ms | 73.1 ms |
| `--no-ignore --files linux` | 63.5 ms | 80.8 ms | 67.5 ms |

## Overlapping repeated-literal count/stat parity — 2026-05-31

Overlapping repeated `-e` count paths now reuse the existing Swift multi-literal
only-matching scanner with output disabled. This makes `--count-matches` and
`--stats -q` count the same leftmost visible matches as Rust ripgrep, without a
C shim or a new low-level scanner. Matching `--stats -q` summaries use that
count plus the existing matched-line helper; all-absent overlap summaries stay
on the fast Swift preflight path.

Validation:

- Current Swift output matched Rust byte-for-byte for overlapping
  `--count-matches`, bounded `-m2 --count-matches`, and `--stats -q` after
  normalizing only elapsed-time stats lines.
- The prior Swift fallback double-counted overlapping repeated literals in
  `--count-matches`/stats; this checkpoint intentionally changes that output to
  match Rust and the already-correct Swift `-o` output.
- `xcrun swift test --filter MiscTests/darwinExecutableLiteralPreflightDenseLines`
  passed with focused overlapping count/stat coverage.

On one or two 46 MiB explicit files under `/tmp/swift-rg-bench`, 20 timed runs
with 2 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--stats -q -e missingliteral -e literal no-match-ascii-46m.txt match-ascii-46m.txt` | 80.5 ms | 12.968 s | 51.5 ms |
| `--count-matches -e missingliteral -e literal match-ascii-46m.txt` | 30.3 ms | count-divergent | 47.7 ms |
| `--stats -q -e absentliteral -e otherabsent no-match-ascii-46m.txt match-ascii-46m.txt` | 14.7 ms | 15.5 ms | 12.4 ms |

## Existing-scanner overlap no-match proof — 2026-05-31

The overlapping repeated-`-e` `--stats -q` all-absent proof now first asks the
existing Swift multi-literal file helper to prove each explicit file has zero
matching lines. This reuses the already-tested multi-literal scanner and avoids
the previous file/literal Cartesian set of Foundation `Data.range(of:)` probes.
If any overlapping literal may match, the path still declines to the generic
fallback so current overlapping-match count semantics are preserved.

Validation:

- Current Swift output matched the saved pre-change Swift binary byte-for-byte
  for the overlapping all-absent stats target.
- Current Swift output matched Rust after normalizing only elapsed-time stats
  lines.
- The overlapping match fallback matched the saved Swift binary byte-for-byte
  and stayed neutral: current Swift 12.968 s versus previous Swift 13.024 s.
  Rust remains faster for that known Swift/Rust count-divergent fallback case.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`, 20 timed runs with
1 warmup:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--stats -q -e absentliteral -e otherabsent no-match-ascii-46m.txt match-ascii-46m.txt` | 15.5 ms | 35.1 ms | 12.9 ms |

## Parallel repeated-literal stats file aggregation — 2026-05-31

The non-overlapping repeated-`-e` `--stats -q` preflight now computes each
explicit file summary in parallel and aggregates the deterministic totals after
all file probes complete. This overlaps no-match containment checks with the
matched-file line/count work added in the prior checkpoint, while keeping the
same mapped `Data` guards, existing Swift scanner helpers, and fallback
behavior.

Validation:

- Current Swift output matched the saved pre-change Swift binary byte-for-byte
  for the mixed match/no-match repeated-`-e` stats target.
- Current Swift output matched Rust after normalizing only elapsed-time stats
  lines.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`, 20 timed runs with
1 warmup:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--stats -q -e missingliteral -e absentliteral no-match-ascii-46m.txt match-ascii-46m.txt` | 44.7 ms | 77.7 ms | 52.2 ms |

## Parallel matched-file quiet-stats counts — 2026-05-31

Matched files in the non-overlapping repeated-`-e` `--stats -q` preflight now
run the existing matched-line helper and the existing non-overlapping match
count helper concurrently. The match-count helper also counts independent
literals in parallel for large mapped files. This keeps the same Swift scanner
helpers and fallback rules; it only changes how already-independent work is
scheduled.

Validation:

- Current Swift output matched the saved pre-change Swift binary byte-for-byte
  for the mixed match/no-match repeated-`-e` stats target.
- Current Swift output matched Rust after normalizing only elapsed-time stats
  lines.
- A `--count-matches` repeated-`-e` guardrail matched both the saved Swift
  binary and Rust byte-for-byte.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--stats -q -e missingliteral -e absentliteral no-match-ascii-46m.txt match-ascii-46m.txt` | 72.6 ms | 86.2 ms | 51.4 ms |
| `--count-matches -e missingliteral -e absentliteral no-match-ascii-46m.txt match-ascii-46m.txt` | 21.3 ms | 28.0 ms | 53.4 ms |

## Flattened quiet-stats overlap no-match proof — 2026-05-31

The repeated-`-e` `--stats -q` all-absent proof now flattens small explicit
file/literal probe sets across `DispatchQueue.concurrentPerform`. It still uses
Foundation `Data.range(of:)` over mapped file data, keeps larger probe sets on
the file-parallel path, and still returns to the generic implementation whenever
any overlapping literal may match.

Validation:

- Current Swift output matched the saved pre-change Swift binary byte-for-byte
  for the overlapping all-absent stats target.
- Current Swift output matched Rust after normalizing only elapsed-time stats
  lines.
- The overlapping match fallback stayed neutral: current Swift 12.888 s versus
  previous Swift 12.934 s, with Rust at 55.0 ms for that generic fallback case.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`, 20 timed runs with
1 warmup:

| Command | Current Swift | Prior Swift checkpoint | Pre-parallel Swift baseline | Rust `rg` |
| --- | ---: | ---: | ---: | ---: |
| `--stats -q -e absentliteral -e otherabsent no-match-ascii-46m.txt match-ascii-46m.txt` | 32.8 ms | 46.0 ms | 82.9 ms | 12.7 ms |

## Parallel quiet-stats overlap no-match proof — 2026-05-31

The repeated-`-e` `--stats -q` preflight now proves all-absent overlapping
literals across explicit files in parallel. This keeps the earlier
Foundation-backed no-match proof, avoids custom scanner code, and still declines
to the generic path when any overlapping literal may match so existing count
semantics are preserved.

Validation:

- Current Swift output matched the saved pre-change Swift binary byte-for-byte
  for the overlapping all-absent stats target.
- Current Swift output matched Rust after normalizing only the elapsed-time
  stats lines.
- The overlapping match fallback was benchmarked as a guardrail and stayed
  neutral: current Swift 12.911 s versus previous Swift 13.043 s.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`, 20 timed runs with
1 warmup:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--stats -q -e absentliteral -e otherabsent no-match-ascii-46m.txt match-ascii-46m.txt` | 46.0 ms | 81.0 ms | 12.4 ms |

## Multi-file quiet stats repeated-regexp checkpoint — 2026-05-31

Explicit regular-file `--stats -q` searches with more than one `-e` pattern now
use a Swift Darwin aggregate summary preflight. The fast path writes the same
deterministic stats summary as the existing single-file preflights, uses a
Foundation `Data.range(of:)` containment proof for files with no candidate
literal, and only uses the existing non-overlapping multi-literal scanners when
a file actually contains one of the repeated literals. Overlapping repeated
literals still fall back when a match is possible, preserving current and Rust
count semantics.

Validation:

- Current Swift output matched the saved pre-change Swift binary byte-for-byte
  for mixed match/no-match and all-absent repeated-`-e` stats targets.
- Current Swift output matched Rust after normalizing only the elapsed-time
  stats lines.
- Coverage was added for multi-file repeated-`-e` quiet stats match and
  no-match summaries.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`, 8 timed runs with
1 warmup for current Swift/Rust and 3 timed runs for the saved previous Swift:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--stats -q -e missingliteral -e absentliteral no-match-ascii-46m.txt match-ascii-46m.txt` | 87.6 ms | 11.308 s | 57.2 ms |
| `--stats -q -e absentliteral -e otherabsent no-match-ascii-46m.txt match-ascii-46m.txt` | 79.0 ms | 4.060 s | 12.0 ms |

## Multi-file word repeated-regexp path preflight checkpoint — 2026-05-31

Explicit regular-file repeated-`-e` searches with `-w` now keep multi-file
quiet and path-only modes on Swift Darwin word-boundary multi-literal helpers.
The helpers use the existing ASCII word-boundary scanner with `maxCount: 1`, so
they can stop after the first matching line for `-q`/`-l` and still fall back for
binary or ambiguous Unicode-boundary cases. Count output stays on the generic
route for this slice because full match-heavy count-line scans were measured as
a regression.

Validation:

- Current Swift output matched the saved pre-change Swift binary and Rust
  byte-for-byte for `-q -w`, `-l -w`, `--files-without-match -w`, the
  corresponding `-i -w` forms, and the rejected `-w -c` count control.
- Coverage was added for repeated-`-e` word and ignore-case word multi-file
  quiet, files-with-matches, and files-without-match forms.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`, 40 timed runs with
5 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-q -w -e missingliteral -e absentliteral no-match-ascii-46m.txt match-ascii-46m.txt` | 16.0 ms | 626.6 ms | 9.9 ms |
| `-l -w -e missingliteral -e absentliteral no-match-ascii-46m.txt match-ascii-46m.txt` | 16.7 ms | 352.6 ms | 12.4 ms |
| `--files-without-match -i -w -e MISSINGLITERAL -e ABSENTLITERAL no-match-ascii-46m.txt match-ascii-46m.txt` | 23.1 ms | 369.9 ms | 78.2 ms |

## Multi-file ignore-case repeated-regexp path preflight checkpoint — 2026-05-31

Explicit regular-file repeated-`-e` searches with `-i` now keep multi-file
quiet and path-only modes on the existing Swift Darwin ASCII case-insensitive
multi-literal helpers. Count output remains on the generic route for this slice:
the existing count-line helpers are fast on no-match files but regress badly on
match-heavy files.

Validation:

- Current Swift output matched the saved pre-change Swift binary and Rust
  byte-for-byte for `-q -i`, `-l -i`, `--files-without-match -i`, and the
  rejected `-i -c` count control.
- Coverage was added for repeated-`-e` ignore-case multi-file quiet,
  files-with-matches, and files-without-match forms.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`, 40 timed runs with
5 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-q -i -e MISSINGLITERAL -e ABSENTLITERAL no-match-ascii-46m.txt match-ascii-46m.txt` | 16.8 ms | 614.0 ms | 10.2 ms |
| `-l -i -e MISSINGLITERAL -e ABSENTLITERAL no-match-ascii-46m.txt match-ascii-46m.txt` | 17.2 ms | 366.7 ms | 12.6 ms |
| `--files-without-match -i -e MISSINGLITERAL -e ABSENTLITERAL no-match-ascii-46m.txt match-ascii-46m.txt` | 16.3 ms | 367.4 ms | 48.2 ms |

## Multi-file exact repeated-regexp preflight checkpoint — 2026-05-31

Explicit regular-file exact-line searches with more than one `-e` pattern now
use the existing Swift Darwin exact-line multi-literal helpers for count,
path-only, and quiet modes. The branch stays within Swift preflight code and
continues to reject word-regexp, null-data, and CRLF combinations.

Validation:

- Current Swift output matched the saved pre-change Swift binary and Rust
  byte-for-byte for the large mixed-file exact-line count target.
- Coverage was added for exact repeated-`-e` multi-file count, ignore-case
  count, include-zero count, count-matches, path-only, files-without-match, and
  quiet forms.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-x -c -e "alpha beta theta zeta eta kappa rho tau missingliteral" -e absentliteral no-match-ascii-46m.txt match-ascii-46m.txt` | 23.49 ms | 14.238 s | 91.46 ms |
| Current/Rust order-flipped confirmation | 20.70 ms | not rerun | 85.61 ms |

## Multi-file include-zero count checkpoint — 2026-05-31

Explicit regular-file `--include-zero` count output now stays on the existing
Swift Darwin literal preflight. The multi-path gate no longer rejects count
modes solely because zero rows are requested, and known no-match files emit
their zero count directly after the status probe instead of rescanning the file.
This keeps the path Swift-first and uses the existing preflight output buffer;
no C shims or custom low-level code were added.

Validation:

- Current Swift output matched the saved pre-change Swift binary byte-for-byte
  for multi-file `--include-zero -c`, `--include-zero --count-matches`,
  `--no-filename --include-zero -c`, and `--crlf --include-zero -c` controls.
- Current Swift output matched Rust for the zero-plus-match target command
  `--include-zero -c missingliteral no-match-ascii-46m.txt match-ascii-46m.txt`.
- `xcrun swift test --filter MiscTests` passed after adding multi-file
  include-zero count coverage.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`, 40 timed runs with
5 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--include-zero -c missingliteral no-match-ascii-46m.txt match-ascii-46m.txt` | 23.84 ms | 307.42 ms | 24.96 ms |
| Same command, order-flipped confirmation | 22.03 ms | 307.63 ms | 24.75 ms |

## Multi-file heading-neutral preflight checkpoint — 2026-05-31

Explicit regular-file `--heading` now remains eligible for the existing Swift
Darwin literal preflight when the active output mode is count, path-only, or
quiet. Heading formatting is silent in those modes, so the old multi-path gate
was forcing a generic scan without changing observable output.

Validation:

- Current Swift output matched the saved pre-change Swift binary and Rust
  byte-for-byte for multi-file `--heading -c`, `--heading --include-zero -c`,
  `--heading -l`, `--heading --files-without-match`, and `--heading -q`
  controls.
- Coverage was added for heading-neutral multi-file count, include-zero count,
  path-only, files-without-match, and quiet forms.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`, 40 timed runs with
5 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--heading -c missingliteral no-match-ascii-46m.txt match-ascii-46m.txt` | 25.21 ms | 312.44 ms | 25.14 ms |
| Same command, order-flipped confirmation | 21.78 ms | 310.91 ms | 24.83 ms |

## Multi-file repeated-regexp preflight checkpoint — 2026-05-31

Explicit regular-file searches with more than one `-e` pattern now have a
narrow multi-file Swift preflight for plain literal count, path-only, and quiet
modes. The branch reuses the existing multi-literal Darwin helpers and stays
deliberately conservative: case-insensitive, word-regexp, and exact-line forms
still use the previous route until they are measured and proven separately.

Validation:

- Current Swift output matched the saved pre-change Swift binary and Rust
  byte-for-byte for repeated-`-e` multi-file count, include-zero count,
  count-matches, files-with-matches, files-without-match, and quiet controls.
- Coverage was added for repeated-`-e` multi-file count, include-zero count,
  count-matches, path-only, files-without-match, and quiet forms.

On two 46 MiB explicit files under `/tmp/swift-rg-bench`, 40 timed runs with
5 warmups:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-c -e missingliteral -e absentliteral no-match-ascii-46m.txt match-ascii-46m.txt` | 45.32 ms | 342.55 ms | 32.42 ms |
| Same command, order-flipped confirmation | 45.60 ms | 346.74 ms | 33.13 ms |

## Files-mode root setup checkpoint — 2026-05-31

The Darwin file-list root planner now proves the fast root is a directory before
deriving the traversal base, then reuses that already-standardized directory as
`rootBase` instead of asking Foundation to classify the URL again. This keeps
the Swift-first fast path and avoids a startup-side `URL.resourceValues` lookup
without adding C shims or custom low-level code.

Validation:

- Current Swift output matched the saved pre-change Swift binary byte-for-byte
  for default, hidden, no-vcs, trailing-slash root, and symlink-root fallback
  file listing.
- Sorted current Swift output matched Rust for default, hidden, no-vcs, and
  trailing-slash Linux corpus file listing.
- A known-directory Git-context variant was rejected: it reduced some user CPU
  in one order, but default `--files` wall time regressed in the current-first
  confirmation.

120 timed runs with 5 warmups on `/tmp/swift-rg-bench/linux`:

| Command | Current Swift | Previous Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--files` | 80.4 ms ± 5.1 ms | 80.9 ms ± 5.1 ms | 75.3 ms ± 10.8 ms |
| `--hidden --files` | 81.5 ms ± 3.1 ms | 82.2 ms ± 5.7 ms | not rerun |
| `--no-ignore-vcs --files` | 64.3 ms ± 2.9 ms | 65.5 ms ± 5.6 ms | not rerun |

### Continuation probes — 2026-05-31

A fresh 15-row Linux recursive-search scan after the root setup checkpoint kept
the default Swift-first/no-C-shim build ahead of Rust on every measured search
row, including literal, word, Greek, no-literal, and alternation workloads. The
active remaining gap is still ignore-aware file listing. An 80-run refresh
measured Rust `--files` at 74.5 ms and Swift at 79.8 ms, Rust
`--hidden --files` at 73.4 ms and Swift at 82.0 ms, while
`--no-ignore-vcs --files` stayed a Swift win at 65.4 ms versus Rust at 66.5 ms.

Additional Swift-only file-list probes from this checkpoint were parity-clean
but not retained:

- Raising `fastDirectoryContents` child reserve capacity from 64 to 128 was
  mixed-to-slower: default `--files` measured 82.4 ms versus 81.7 ms before,
  hidden was 83.4 ms versus 84.1 ms, and `--no-ignore-vcs` regressed to 67.3 ms
  versus 65.4 ms.
- Moving root existence checks behind the fast root planner improved sorted
  file-listing in one order, but did not hold on default/hidden controls. The
  flipped 120-run pass measured default at 80.0 ms versus 79.7 ms before and
  hidden at 83.9 ms versus 82.5 ms before.
- Bypassing root-argument standardization for simple or exact absolute paths was
  also rejected. The simple-path probe measured default `--files` at 81.5 ms
  versus 79.6 ms before; the exact-path variant measured 80.6 ms versus 79.9 ms
  and `--no-ignore-vcs` at 64.6 ms versus 64.1 ms.
- Loading marker-known local ignore files by string path instead of child `URL`
  construction preserved output but stayed neutral-to-worse. The flipped pass
  measured default at 80.4 ms versus 79.7 ms before, hidden at 81.6 ms versus
  81.4 ms, and no-vcs at 64.7 ms versus 64.5 ms.
- Replacing the bridged `NSString.isAbsolutePath` root flag with a direct
  leading-slash check preserved absolute, trailing-slash, and relative-root
  output, but the order-flipped timing reversed the apparent win: default moved
  to 80.6 ms versus 79.8 ms before and hidden to 82.4 ms versus 81.7 ms before.

## Swift-first files-mode checkpoint — 2026-05-29

`--files` startup/traversal now avoids building the default file-type registry
when no type changes were requested, reads ignore/config inputs through
path-based `String` initializers, and skips scoped-path allocation for
unanchored basename-only ignore matchers. Anchored basename-looking patterns
still use scoped paths. These are Swift/Foundation-only changes; no C shims or
custom low-level code were added.

Validation:

- Current Swift `--files /tmp/swift-rg-bench/linux` output matched the saved
  pre-change Swift output byte-for-byte:
  `d6298ab34199c0f992b7280b2b16c4763a1981169477cb82765df33b502dc9f9`.
- Sorted current Swift `--files` output matched Rust `rg --files` on the same
  Linux corpus.
- `SWIFT_RIPGREP_PARITY=1 xcrun swift test --filter ParityHarnessTests`
  passed after each committed slice.

20 timed runs with 5 warmups on `/tmp/swift-rg-bench/linux`:

| Command | Current Swift | Rust `rg` |
| --- | ---: | ---: |
| `--files` | 102.9 ms ± 8.1 ms | 75.8 ms ± 2.8 ms |
| `--no-ignore --files` | 65.3 ms ± 1.8 ms | 64.7 ms ± 2.8 ms |

### Continuation probes — 2026-05-30

Fresh release checks on the same Linux corpus kept the default no-C-shim Swift
build ahead of Rust on most recursive search rows. A one-run curated scan
measured Swift faster on literal, word, Greek, and case-sensitive alternation
rows; the only tied/slower row was the ASCII no-literal word/space regex at
2.137 s versus Rust at 2.100 s. Full-output file listing remains the clearer
remaining gap: a direct 30-run check measured Swift `--files` at 92.7 ms versus
Rust at 73.6 ms, while `--no-ignore-vcs --files` was much closer at 66.6 ms
versus Rust at 64.0 ms.

The Darwin file-list fast writer now also handles implicit and relative
single-directory roots by separating the physical traversal root from the
logical output prefix. This keeps ignore matching on absolute filesystem paths
while allowing `rg --files` from the current directory to emit `path/to/file`
instead of falling back to the generic `Haystack` walker. Exact output matched
the previous Swift binary for `--files`, `--files .`, `--no-ignore --hidden
--files`, and `--no-ignore-vcs --files` from the Linux corpus root; sorted
output matched Rust for those controls plus absolute `/tmp/.../linux`,
`/tmp/.../linux/`, and `/tmp/.../linux/.` roots. A 40-run same-machine A/B from
inside `/tmp/swift-rg-bench/linux` improved Swift implicit-root `--files` from
924.7 ms before to 86.9 ms after, versus Rust at 67.8 ms. The same retained
build measured `--files .` at 86.9 ms and `--no-ignore --hidden --files` at
70.9 ms. An absolute-root control measured Swift at 88.9 ms versus Rust at
73.2 ms, keeping the already-optimized explicit-root path in the same band.

Unscoped ignore matchers now bypass the scoped-path helper and use the incoming
relative path directly. This trims the root `.gitignore`/global-ignore decision
path without changing scoped directory-local matchers. Exact output matched the
previous Swift binary for `--files`, `--files .`, `--hidden --files`,
`--no-ignore-vcs --files`, and `--no-ignore --hidden --files` from the Linux
corpus root; sorted output matched Rust for the same controls. An 80-run A/B
measured default `--files` at 86.2 ms for the probe versus 87.4 ms for the
previous checkpoint, hidden at 86.7 ms versus 87.1 ms, and `--no-ignore-vcs` at
63.7 ms versus 64.4 ms. A 100-run order-flipped confirmation was smaller but
still directionally positive: default 87.1 ms versus 87.4 ms, hidden 86.6 ms
versus 86.9 ms, and `--no-ignore-vcs` 64.1 ms versus 64.7 ms. Rust default
measured 67.1 ms in both confirmation slices.

The global-ignore setup now skips appending global matchers that can only
exclude hidden paths during default non-hidden file listing when no earlier
ignore file supplied an include rule. Hidden paths are already filtered before
ignore matching in that mode, while `--hidden` continues to load and apply the
global matcher. Exact output matched the previous Swift binary for default,
hidden, no-global, no-vcs, and no-ignore-hidden file listing; sorted output
matched Rust for the same controls. An 80-run A/B measured default `--files` at
84.5 ms versus 86.8 ms for the previous checkpoint, hidden stayed neutral at
86.9 ms versus 86.5 ms, and the no-global control stayed neutral. A 100-run
order-flipped confirmation measured default at 84.8 ms versus 86.2 ms, hidden
at 87.5 ms for both binaries, and Rust default at 67.2 ms.

Sorted `--files` now stays on the Swift-first file-list walker for path sorts
instead of falling back to the generic `Haystack`/`URL` result path, and path
sorts cache component keys instead of rebuilding them per comparator call. On
the full Linux corpus, exact sorted output matched both the previous Swift
binary and Rust for default, no-vcs, and no-ignore-hidden controls. An 8-run A/B
measured default `--sort path --files` at 279.4 ms versus 3463.8 ms for the
previous checkpoint, with Rust at 228.2 ms. The no-ignore-hidden sorted control
measured 297.2 ms versus 3446.6 ms.

Sorted file-listing path keys now encode component boundaries once per emitted
path instead of storing split `Substring` component arrays. Exact output matched
Rust for forward and reverse sorted file listing plus the sorted recursive
`spin_lock` control. Against the previous checkpoint, a 10-run A/B measured
`--sort path --files` at 197.8 ms versus 282.5 ms before. The generic sorted
search path stayed on component arrays after a string-key probe regressed the
`spin_lock` row; the final check kept sorted search neutral at 1802.5 ms versus
1799.9 ms before.

Sorted file-listing keys now store the same component-boundary transform as
safe Swift UTF-8 byte arrays, avoiding per-key replacement strings while keeping
the optimized path Swift-only. Exact output matched Rust for forward and
reverse sorted file listing plus the sorted recursive `spin_lock` control. A
20-run A/B against checkpoint `d10a347` measured `--sort path --files` at
158.8 ms median versus 201.8 ms for the prior string-key build, with Rust at
225.4 ms on the same run.

The no-C-shim Swift-first file-listing pass on 2026-05-30 removed the
non-ASCII regex fallback from simple ignore globs, boxed the private Darwin
fast rule index to avoid copying dictionary-heavy matcher state, lowered the
boxed index activation threshold from eight rules to four, and reused a single
ignore decision in the fast file-path traversal. The simple-glob change also
matches Rust's UTF-8 byte behavior for `?` against non-ASCII filenames. Sorted
Swift output matched Rust for default `--files`, `--hidden --files`, and
`--no-ignore-vcs --files` on `/tmp/swift-rg-bench/linux`; the Rust parity
harness and the full Swift test suite passed after the retained slices. A
20-run no-shell hyperfine check with five warmups measured:

| Command | Swift | Rust `rg` |
| --- | ---: | ---: |
| `--files` | 80.0 ms ± 4.2 ms | 72.8 ms ± 1.0 ms |
| `--hidden --files` | 81.1 ms ± 2.3 ms | not rerun in this slice |
| `--no-ignore-vcs --files` | 71.1 ms ± 12.9 ms | not rerun in this slice |

### Continuation probes — 2026-05-31

Fresh Swift-first/no-C-shim measurements on the Linux corpus still point at
VCS-ignore-aware file listing as the main remaining file-walk gap. A 50-run
no-shell refresh measured default `--files` at 87.0 ms median for Swift versus
77.1 ms for Rust, `--hidden --files` at 93.4 ms versus 82.0 ms, and
`--no-ignore-vcs --files` effectively tied at 71.49 ms versus 71.47 ms. Quiet
file listing is already close: an 80-run check measured Swift
`--quiet --files` at 5.23 ms versus Rust at 4.89 ms, and
`--no-ignore --hidden --quiet --files` at 4.52 ms versus Rust at 4.13 ms.

Two fresh Swift-only probes were parity-clean but not retained:

- Guarding the fast ignore decision before the unindexed-rule loop preserved
  exact Swift output and sorted Rust parity for default, hidden, and no-vcs file
  listing, but an 80-run A/B regressed the hot default/hidden cases: default
  moved from 86.9 ms to 88.8 ms and hidden from 86.7 ms to 89.7 ms.
- Reading quiet literal probe files through Foundation mapped `Data(contentsOf:)`
  instead of the existing `HaystackReader` path preserved stdout, stderr, and
  status for quiet hit/miss, `--no-mmap`, JSON quiet, and stats quiet controls,
  but regressed default recursive `-q EXPORT_SYMBOL` from 30.7 ms to 35.6 ms in
  an 80-run A/B. The existing reader route stayed.
- Splitting the recursive quiet literal search across top-level root children
  preserved quiet hit/miss output versus the previous Swift binary and Rust, but
  regressed `-q EXPORT_SYMBOL` from 33.4 ms to 37.0 ms and no-match quiet from
  1.574 s to 3.017 s in an 80-run A/B. The extra GCD scheduling and duplicated
  directory work doubled miss time, so the ordered quiet walker stayed.

The executable literal preflight now accepts multiple explicit regular-file
operands for quiet mode while leaving the single-file branch on its previous
straight-through path. Direct status/stdout/stderr checks matched the previous
Swift binary and Rust for match-first, match-second, no-match, `-w`, and `-i`
multi-file quiet cases. A 100-run A/B on the Linux corpus block files measured
`-q EXPORT_SYMBOL bsg.c bfq-iosched.c` at 4.41 ms versus 30.7 ms before and
4.58 ms for Rust; the reversed match measured 4.41 ms versus 32.6 ms before and
2.75 ms for Rust. A final 80-run check measured the reversed match at 4.43 ms
versus 29.6 ms before and 4.23 ms for Rust, no-match at 4.50 ms versus
37.8 ms before, and single-file quiet flat at 2.63 ms versus 2.64 ms before.

The same executable literal preflight now handles multiple explicit
regular-file operands for path-only and count-style output when the mode has
stable byte-for-byte parity with both the previous Swift binary and Rust rg.
This covers `-l`, `--files-without-match`, `--files-with-matches --null`, `-c`,
`--no-filename -c`, and `--count-matches`; alternation, repeated `-e`, heading,
and `--include-zero` count cases still fall back. Direct stdout/stderr/status
checks matched the previous Swift binary and Rust for the accepted modes. An
80-run A/B on the Linux corpus block files measured:

| Command | Previous Swift | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-l EXPORT_SYMBOL bfq-iosched.c bsg.c` | 35.34 ms | 4.99 ms | 6.27 ms |
| `--files-without-match EXPORT_SYMBOL bfq-iosched.c bsg.c` | 31.30 ms | 4.56 ms | 6.47 ms |
| `-c EXPORT_SYMBOL bfq-iosched.c bsg.c` | 31.10 ms | 4.94 ms | 6.47 ms |
| `--count-matches EXPORT_SYMBOL bfq-iosched.c bsg.c` | 33.43 ms | 4.46 ms | 6.49 ms |

Plain quiet search output now skips constructing `StandardPrinter` entirely
when neither JSON nor stats output can be emitted. This removes search-mode
formatting setup from `-q` runs while keeping JSON quiet summaries and quiet
stats on their existing formatters. An 80-run A/B on the Linux corpus measured
recursive `-q EXPORT_SYMBOL /tmp/swift-rg-bench/linux` at 5.48 ms versus
28.64 ms for the previous Swift binary and 4.24 ms for Rust. A 100-run
directory/empty-root check measured `-q EXPORT_SYMBOL linux/block` at 5.52 ms
versus 31.54 ms before and an empty-directory quiet miss at 4.30 ms versus
34.26 ms before.

`GlobMatcher.excludesOnlyHiddenPaths` is now computed only when the global-ignore
setup asks for it, instead of classifying every rule in every directory-local
ignore matcher during construction. Exact Swift output matched the previous
binary for default, hidden, and `--no-ignore-vcs` file listing, and sorted output
matched Rust on the Linux corpus. A 60-run same-machine A/B measured default
`--files` at 79.1 ms for the probe versus 80.7 ms for the previous checkpoint,
and hidden `--files` at 80.7 ms versus 81.8 ms. The `--no-ignore-vcs` control
was noise-dominated at 70.2 ms versus 68.3 ms and does not exercise the moved
global-ignore property.

The ignore-aware Darwin file-list writer now skips ignore-stack decisions in
`--no-ignore-vcs` directories that have not loaded any `.ignore` or `.rgignore`
rules. That leaves VCS-ignore traversal unchanged while avoiding relative-path
construction and empty `IgnoreStack` probes for no-vcs file listing. Exact Swift
output matched the previous binary for default, hidden, and `--no-ignore-vcs`;
sorted output matched Rust on the same controls. A 70-run A/B measured
`--no-ignore-vcs --files` at 64.2 ms versus 67.8 ms for the previous
checkpoint, with user CPU 27.4 ms versus 34.3 ms, and Rust no-vcs at 65.5 ms.
Default stayed neutral at 78.5 ms versus 79.3 ms; hidden was noisy at 82.5 ms
versus 80.7 ms, so keep monitoring that control. A later 60-run confirmation
measured `--no-ignore-vcs --files` at 65.5 ms versus 67.8 ms before and Rust at
65.9 ms; default was 79.0 ms versus a noisy 83.5 ms before, and hidden was
84.0 ms versus 81.4 ms before. An order-flipped 100-run control then measured
hidden neutral at 81.4 ms versus 81.5 ms before; default in that same control
was noise-dominated at 81.4 ms versus 80.0 ms before.

The CLI files-mode path now defers allocating the generic 64 KiB line-output
buffer until after the Darwin byte-output fast path declines the request. The
fast path writes bytes directly, so successful default, hidden, and no-vcs
file-listing runs no longer pay for an unused fallback buffer. Exact Swift
output matched the previous binary for default, hidden, and `--no-ignore-vcs`;
sorted default output matched Rust. A 100-run A/B measured default `--files` at
80.6 ms versus 80.5 ms before, hidden at 80.8 ms versus 81.5 ms, and no-vcs at
63.5 ms versus 64.5 ms. An order-flipped 120-run confirmation measured default
at 78.5 ms versus 79.0 ms before, hidden at 80.9 ms versus 81.6 ms, and no-vcs
neutral at 63.7 ms versus 63.6 ms.

The path-component suffix matcher now checks the candidate's final byte before
falling into `memcmp`. This keeps tiny exact slash-pattern ignores cheap on the
non-match path while preserving the existing Swift-only UTF-8 buffer helper.
Exact Swift output matched the previous binary for default, hidden,
`--no-ignore-vcs`, and hidden/no-global file listing; sorted output matched Rust
for the same controls. The first 80-run A/B was noisy but had better medians for
default and hidden. The order-flipped 100-run pass kept default median slightly
positive at 78.5 ms versus 78.6 ms before and hidden mean positive at 80.6 ms
versus 82.4 ms before, while no-vcs was noise-level. A focused 150-run pass
measured default at 77.4 ms versus 78.2 ms before, with hidden neutral at
80.0 ms versus 79.7 ms and no-vcs noise-dominated at 64.9 ms versus 65.5 ms.

The default file-list global-ignore skip now classifies hidden-only global
ignore files before constructing a `GlobMatcher`. This preserves the existing
guard that only applies when `--files` is non-hidden, logging is off, and no
earlier ignore source can include hidden paths, but avoids compiling a matcher
just to throw it away. Exact Swift output matched the previous binary for
default, hidden, no-vcs, and no-global file listing; sorted output matched Rust
for the same controls. An 80-run A/B measured default at 77.7 ms versus
78.1 ms before, hidden at 80.9 ms versus 79.9 ms before, and no-vcs at
63.1 ms versus 63.7 ms before. The order-flipped 100-run confirmation was
wall-time neutral at default 78.0 ms versus 77.9 ms before, hidden 79.9 ms
versus 80.2 ms before, and no-vcs 63.1 ms versus 62.9 ms before; default user
CPU moved from 94.2 ms before to 92.7 ms after.

Parent VCS ignore setup now treats a `.git` marker at the traversal root as the
nearest Git boundary before checking ancestor directories. Parent VCS ignores
above that boundary cannot apply, so this skips redundant ancestor
`isInGitRepository` probes while leaving parent `.ignore` handling unchanged.
Exact Swift output matched the previous binary for default, hidden, no-parent,
and no-vcs file listing; sorted output matched Rust for the same controls. A
100-run A/B measured default at 77.4 ms versus 79.2 ms before, hidden at
80.9 ms versus 79.4 ms before, and no-parent neutral at 77.4 ms versus
76.9 ms before. The order-flipped 100-run confirmation was wall-time neutral:
default 78.2 ms for both, hidden 80.0 ms versus 79.8 ms before, and no-parent
77.5 ms versus 77.6 ms before.

Several plausible Swift-only probes were rejected after exact Swift-output and
sorted Rust-output checks:

- Indexing exact path rules behind a character-count guard preserved exact
  Swift output and sorted Rust parity, but measured flat-to-worse: default
  `--files` was about 81.0 ms and hidden was about 81.2 ms.
- Switching the ignore-aware file-list loops to a local directory-entry-kind
  enum preserved exact Swift output and sorted Rust parity, but was flat or
  slower: default `--files` was about 81.6 ms, hidden about 81.0 ms, and
  `--no-ignore-vcs` about 67.0 ms.
- Replacing the array-backed `IgnoreStack` with a linked stack preserved exact
  Swift output and sorted Rust parity, but raised default/hidden user CPU and
  measured neutral-to-worse: a 30-run check put default `--files` at 83.7 ms and
  hidden at 84.1 ms, with `--no-ignore-vcs` flat at 66.0 ms. The array-backed
  stack stayed.
- Hidden-entry include checks that reused the ignore decision for hidden files
  were parity-clean but flat-to-slower: an 80-run order-flipped check measured
  default `--files` at 90.1 ms versus 89.2 ms before.
- Parsing ignore files into already-trimmed active lines preserved output but
  regressed the Linux tree: a 40-run A/B measured default `--files` at 91.2 ms
  versus 90.0 ms and `--hidden --files` at 89.5 ms versus 88.1 ms.
- Single-matcher and empty-bucket shortcuts in `IgnoreStack`/`GlobMatcher`
  were neutral or worse under order-flipped checks, so the existing generic
  matcher loop remains faster for this workload.
- Replacing the root-child async group with `DispatchQueue.concurrentPerform`
  preserved file-list order but did not improve scheduling cost: an 80-run
  A/B measured default `--files` at 89.3 ms versus 89.8 ms and hidden output at
  90.9 ms versus 89.0 ms.
- Storing path-suffix rule bytes and indexing small simple-glob basename rules
  both preserved output but regressed the optimizer-sensitive file-list path,
  raising default `--files` to about 102 ms in 80-run checks.
- Indexing scoped slash simple-globs by literal path prefix also preserved exact
  output and sorted Rust parity, but regressed default and hidden file listing
  from about 87 ms to 101 ms while leaving `--no-ignore-vcs` flat.
- Building with `-cross-module-optimization` preserved exact output and sorted
  Rust parity, but was neutral overall: default moved from 87.7 ms to 87.0 ms,
  hidden from 86.5 ms to 87.4 ms, and `--no-ignore-vcs` from 64.4 ms to
  63.8 ms in a noisy 60-run pass.
- Enabling the existing short-line prefilter for all no-literal Linux files,
  instead of only large mapped files, preserved the Unicode and ASCII
  no-literal output but was neutral-to-slower: the ASCII row measured 2.182 s
  versus 2.162 s before in a seven-run A/B.
- Forcing `@inline(__always)` on the ASCII word/whitespace byte classifiers
  used by the no-literal scanner preserved exact Swift output and sorted Rust
  parity for the Linux five-group Unicode (721 lines) and `(?-u)` ASCII
  (720 lines) patterns, but did not hold an order-flipped timing win. The first
  seven-run A/B looked slightly positive at Unicode 2.199 s versus 2.226 s
  before and ASCII 2.126 s versus 2.150 s before; the current-first 10-run
  confirmation reversed that to Unicode 2.277 s versus 2.196 s before and ASCII
  2.284 s versus 2.131 s before, so the plain helpers stay.
- A narrow ASCII-only matching-line specialization for the Linux five-group
  no-literal scanner also stayed rejected. It preserved exact Swift output and
  byte-sorted Rust parity for both `(?-u)` ASCII (720 lines) and default
  Unicode (721 lines), but the targeted seven-run A/B slowed ASCII to 2.158 s
  versus 2.117 s before. The generic word/whitespace scanner remains faster
  despite carrying the Unicode fallback bookkeeping.
- A Swift UTF-8 prescan for the Greek-script fast path also stayed rejected.
  It preserved exact Swift output and sorted Rust parity for recursive
  matching-lines, count, count-matches, and files-with-matches modes, but the
  added validation pass did not beat the retained high-bit guard plus decode.
  A seven-run line-output A/B measured plain `\p{Greek}` at 1.868 s versus
  1.853 s before and ignore-case at 1.884 s versus 1.883 s before. Count and
  count-matches checks were flat at about 1.86 s, so the simpler matcher-backed
  scan stayed.
- Follow-up VCS-ignore file-list probes on 2026-05-30 also preserved exact
  Swift output and sorted Rust parity but did not retain a measurable win:
  URL `isDirectory` hints for known ignore/config file appends were mixed
  (default about 78.9 ms versus 80.2 ms before, but hidden/no-vcs slightly
  worse), a scoped-traversal flag for directory-local basename matchers was
  flat-to-worse (default about 79.4 ms versus 78.8 ms), boxing the
  `IgnoreStack` matcher array was neutral after order-flipped confirmations
  (default about 79.0 ms versus 80.4 ms, hidden worse/noisy), first-byte guards
  around exact fast-index dictionaries were flat (default 78.5 ms versus
  78.4 ms), caching basename and relative-path edge bytes once per stack
  decision regressed user CPU (default 81.5 ms versus 80.1 ms, hidden
  81.4 ms versus 80.2 ms), and a visible-path fast index that skipped rules
  which can only match hidden paths also regressed default user CPU
  (82.2 ms versus 80.4 ms).
- Two later bookkeeping probes also stayed rejected after exact Swift output and
  sorted Rust parity. Removing the fast file-list chunk message/warning/
  diagnostic side channels was mixed: an 80-run pass measured default at
  77.6 ms versus 79.0 ms before and no-vcs at 66.6 ms versus a noisy
  79.3 ms before, but hidden regressed to 86.6 ms versus 81.8 ms; the
  order-flipped 100-run pass put default slower at 79.2 ms versus 78.0 ms and
  no-vcs neutral at 63.7 ms versus 63.8 ms. Reserving cloned logical path byte
  arrays before appending directory names was likewise noise: an 80-run pass
  showed default at 77.9 ms versus 78.6 ms before and no-vcs at 64.0 ms versus
  64.4 ms, but the order-flipped 100-run pass regressed default to 80.5 ms
  versus 77.6 ms and left no-vcs flat at 63.1 ms versus 63.2 ms.
- Lowering the Darwin fast-rule-index activation threshold from four indexed
  ignore rules to three preserved exact Swift output and sorted Rust parity, but
  hidden file listing regressed immediately: an 80-run pass measured hidden at
  81.8 ms versus 79.4 ms before, with user CPU up to 115.1 ms from 105.0 ms.
  Default was only noise-level better at 77.8 ms versus 78.5 ms, so the
  four-rule threshold stayed.
- A narrower variant that indexed only tiny slash-path exact matchers also
  regressed hidden mode. It preserved exact Swift output and sorted Rust parity,
  but an 80-run pass measured hidden at 82.1 ms versus 80.5 ms before, with
  user CPU up to 112.6 ms from 104.6 ms; the hidden no-global control was also
  slower at 78.6 ms versus 77.4 ms. The reverse matcher loop stayed faster for
  these tiny global-ignore shapes.
- Adding a first-byte check alongside the retained final-byte guard in
  `hasPathComponentSuffix` also preserved exact Swift output and sorted Rust
  parity, but it slowed the file-listing controls in a 100-run A/B: default
  measured 80.8 ms versus 77.9 ms before, hidden 81.0 ms versus 79.9 ms,
  no-vcs 64.7 ms versus 62.9 ms, and hidden/no-global 78.5 ms versus 77.2 ms.
  The single final-byte guard stayed.
- Reordering the retained suffix guard to check the candidate final byte before
  the slash boundary also stayed rejected. It preserved exact Swift output and
  sorted Rust parity, and a 100-run pass initially improved default to 77.1 ms
  versus 79.3 ms before, but the order-flipped 120-run pass put default slower
  at 78.7 ms versus 77.8 ms and no-vcs slower at 63.9 ms versus 63.0 ms.
  The original slash-then-final-byte ordering stayed.
- Replacing the indexed basename prefix/suffix checks with direct Swift UTF-8
  buffer comparisons also stayed rejected. It preserved exact Swift output and
  sorted Rust parity for default, hidden, no-vcs, and no-global file listing,
  but both 80-run A/B orders raised ignore-heavy user CPU: default moved from
  95.4 ms before to 97.5 ms after in the first pass and from 94.3 ms before to
  96.8 ms after in the flipped pass; hidden moved from 102.0/101.5 ms before to
  103.6/103.8 ms after. The standard `String.hasPrefix`/`hasSuffix` path stayed.
- One-level nested parallel file-list splitting under large root-child
  directories was also rejected. It preserved exact Swift output and sorted Rust
  parity for default, hidden, no-vcs, and no-global file listing, but the extra
  GCD work and ordered chunk buffering overwhelmed any straggler benefit:
  default regressed to 150.0 ms versus 79.8 ms before, hidden to 150.0 ms versus
  80.6 ms before, and system CPU jumped to about 2.9 s per run. The existing
  root-child parallel boundary stayed.
- Skipping matcher construction for ignore files with no active patterns also
  stayed rejected. It preserved exact stdout and stderr versus the previous
  Swift binary for default, hidden, no-vcs, and `--debug --files`, and sorted
  output matched Rust for the same file-list controls. But both 100-run A/B
  orders raised ignore-heavy user CPU and hidden wall time: default user CPU
  moved from 92.2/93.6 ms before to 97.1/96.4 ms after, while hidden moved from
  80.7/80.6 ms before to 82.0/81.8 ms after. The existing empty matcher path
  stayed.
- Reusing the traversal root Git-repository context for global-ignore setup
  also stayed rejected. It preserved exact stdout and stderr versus the previous
  Swift binary for default, hidden, no-vcs, and `--debug --files`, and sorted
  output matched Rust for the same file-list controls. But both 100-run A/B
  orders were neutral-to-slower: default measured 78.0 ms versus 77.9 ms before
  in the first pass and 78.3 ms versus 77.5 ms before in the flipped pass, with
  no-vcs likewise neutral/slower. The simpler existing setup order stayed.
- Short-circuiting hidden file-list entries before asking the ignore stack when
  no ignore file can include hidden paths also stayed rejected. It preserved
  exact stdout and stderr versus the previous Swift binary for default, hidden,
  no-vcs, no-global, and `--debug --files`, and sorted output matched Rust for
  the same file-list controls. The first 80-run A/B looked positive for default
  at 79.0 ms versus 81.3 ms before, but the order-flipped 100-run confirmation
  flattened default to 78.6 ms versus 78.5 ms before and made no-vcs slightly
  worse at 63.6 ms versus 63.2 ms, so the shared helper stayed unchanged.
- Guarding the fast-rule exact-path dictionary lookup when the dictionary was
  empty also stayed rejected. It preserved exact Swift stdout and stderr for
  default, hidden, no-vcs, no-global, and `--debug --files`, and sorted output
  matched Rust for the same file-list controls. The first 100-run A/B was
  neutral for default at 78.6 ms for both binaries and no-vcs slightly worse at
  63.5 ms versus 63.2 ms before; the order-flipped 120-run confirmation
  regressed default to 78.9 ms versus 78.1 ms before and no-vcs to 63.8 ms
  versus 63.1 ms before, so the unconditional lookup stayed.
- Quiet literal search probes outside the file-list path also stayed rejected.
  Raising the recursive raw-literal probe window to 1024 files / 128 MiB
  preserved quiet stdout/stderr/status but slowed `EXPORT_SYMBOL -q` on the
  Linux tree to 33.6 ms versus 25.9 ms before and slowed the no-match quiet
  control to 1.647 s versus 1.581 s before. Disabling that probe entirely made
  recursive `EXPORT_SYMBOL -q` fall back to the generic full search and regress
  to 923.1 ms. Avoiding quiet haystack override-path formatting was only
  noise-positive in the first order and then regressed no-match quiet and
  `--quiet --files` in the flipped order. A narrow multiple-explicit-file quiet
  shortcut preserved output/status but did not improve the two-file match or
  no-match controls. The existing quiet first-match route stayed.
- Follow-up quiet literal probes on 2026-05-31 also stayed rejected. The
  `PM_RESUME -q` hotspot first matched at file 14,840 in Swift file-list order,
  after about 164 MiB, while the existing 16 MiB probe budget covered roughly
  the first 937 files. Reusing the same raw byte-literal first-match scan inside
  the normal parallel fallback preserved quiet stdout/stderr/status versus the
  previous Swift binary and Rust for recursive match/no-match, explicit-file,
  `--quiet --files`, and binary-NUL controls, but regressed `PM_RESUME -q` to
  1.242 s median versus 1.024 s before and no-match quiet to 2.951 s versus
  1.772 s before. Skipping files that the bounded probe had already proven
  no-match was also parity-clean, but measured `PM_RESUME -q` at 1.030 s versus
  1.007 s before and no-match quiet at 1.596 s versus 1.583 s before, so the
  fallback still restarts through the normal parallel search path.
- Replacing the recursive quiet raw-literal size guard's `FileManager`
  attribute lookup with a Darwin `fstatat` call also stayed rejected. It
  preserved quiet stdout/stderr/status versus the previous Swift binary and
  Rust for recursive match, recursive no-match, explicit-file match/no-match,
  and two-file controls, but the 80-run A/B was flat-to-slower: recursive
  `EXPORT_SYMBOL -q` measured 32.9 ms versus 30.4 ms before, recursive
  no-match measured 1.580 s versus 1.579 s before, and count/json-count
  controls were neutral. The existing Foundation attribute guard stayed.
- Removing that recursive quiet raw-literal size guard entirely was also
  rejected. It preserved quiet stdout/stderr/status versus the previous Swift
  binary and Rust for the same controls, but an 80-run A/B slowed the near-match
  `EXPORT_SYMBOL -q` control to 39.7 ms versus 34.1 ms before while leaving the
  recursive no-match median flat at 1.579 s. The guard remains in place so the
  quiet fast path does not trade the common early-match case for noise.
- Continuing with generic per-file search after the quiet raw-literal probe
  reaches its file/byte budget was rejected too. It preserved quiet
  stdout/stderr/status versus the previous Swift binary and Rust, including a
  synthetic match after the probe budget, but it gave up the existing parallel
  fallback and regressed recursive Linux no-match to 2.500 s versus 1.579 s
  before. The restart into the normal search path remains faster for exhaustive
  quiet misses.
- Folding the fast directory-entry current/parent/ASCII/hidden checks into one
  byte pass before string decoding also stayed rejected. It preserved exact
  Swift output for default, hidden, no-vcs, sorted file listing, and quiet
  controls, with sorted Rust output parity for file listing and exact Rust
  parity for sorted/quiet controls. The 80-run A/B was flat for default
  `--files` at 79.3 ms versus 79.6 ms before, regressed hidden to 82.3 ms
  versus 81.6 ms, and regressed recursive `EXPORT_SYMBOL -q` to 52.5 ms versus
  38.1 ms. The existing helper plus `allSatisfy` stayed.
- Combining the recursive quiet raw-literal BOM checks, binary NUL check, and
  literal scan into one `Data.withUnsafeBytes` pass was rejected after the
  order-flipped confirmation. It preserved quiet stdout/stderr/status versus the
  previous Swift binary and Rust for recursive match/no-match, explicit-file
  match/no-match, two-file match, UTF-8 BOM, UTF-16LE BOM, and binary-NUL
  controls. The first 100-run pass was mixed at 58.2 ms versus 60.7 ms before
  for near-match quiet and 1.573 s versus 1.572 s before for no-match quiet; the
  flipped pass regressed both, with near-match at 50.5 ms versus 47.5 ms and
  no-match at 1.582 s versus 1.578 s. The separate existing BOM/binary checks
  stayed.
- Raising the block-buffered stdout size from 64 KiB to 256 KiB also stayed
  rejected. Exact output matched the previous Swift binary for default, hidden,
  no-vcs, sorted file listing, normal line output, and explicit
  `--block-buffered`/`--line-buffered` controls; sorted output matched Rust for
  the same file-list and line-output controls. The 80-run A/B was flat on
  default `--files` at 79.6 ms versus 80.1 ms before and no-vcs at 64.6 ms for
  both, but sorted `--files` regressed to 152.6 ms versus 151.8 ms and recursive
  `EXPORT_SYMBOL` line output regressed to 1.687 s versus 1.679 s. The 64 KiB
  stdout buffer stayed.
- A small multi-explicit-file quiet literal route that directly scanned two to
  eight existing file operands also stayed rejected. It preserved exact
  stdout/stderr/status versus the previous Swift binary and Rust for two-file
  match, reversed match, no-match, three-file match, missing-file fallback,
  directory fallback, binary-NUL fallback, UTF-8 BOM fallback, explicit
  `--ignore-file` fallback, and recursive quiet controls. But the 120-run A/B
  was wall-time flat-to-slower: two-file match moved to 34.5 ms versus 32.3 ms
  before, reversed stayed neutral at 35.0 ms versus 34.8 ms, no-match stayed
  neutral at 34.3 ms versus 33.7 ms, and the three-file synthetic match
  regressed to 36.4 ms versus 31.4 ms. The existing parallel generic explicit
  search path stayed despite its higher user CPU. A retried version inside the
  quiet walker, including a variant that skipped the helper's extra
  `FileManager.attributesOfItem` precheck for explicit operands, also failed to
  move wall time toward Rust: the 100-run retry left two-file match in the
  42 ms band, reversed match around 32 ms, and no-match worse at 53 ms, so no
  source change was retained.
- Routing single-file `--stats -l` and `--stats --files-without-match` through
  the direct Swift literal writer was also rejected. It preserved stdout,
  stderr, and status versus the previous Swift binary and Rust after normalizing
  Rust's elapsed timing lines for match, no-match, binary-NUL, UTF-8 BOM,
  explicit `--ignore-file`, ignore-case, and word-regexp controls. But the
  80-run A/B was flat-to-slower: matching `--stats -l` measured 31.2 ms versus
  30.0 ms before and Rust at 20.0 ms, no-match measured 4.34 ms versus
  4.26 ms before, and matching `--stats --files-without-match` stayed neutral
  at 9.18 ms versus 9.12 ms. The generic stats path stayed.
- Adding a second-last-byte guard before basename suffix-rule `hasSuffix`
  checks was rejected. Exact output matched the previous Swift binary for
  default, hidden, no-vcs, and no-global file listing, and sorted output matched
  Rust. The first 100-run A/B was mixed: default `--files` regressed to
  79.9 ms versus 78.6 ms before, hidden improved to 80.6 ms versus a noisy
  83.0 ms before, and no-vcs was neutral. The order-flipped 120-run
  confirmation still had default slower at 78.9 ms versus 78.4 ms before and
  no-vcs flat, so the single last-byte suffix bucket stayed.
- Skipping path-dependent ignore rules for deep relative paths outside literal
  first-component prefixes was rejected. Exact Swift output matched the
  previous binary for default, hidden, no-vcs, and no-global file listing, and
  sorted output matched Rust on those controls. The 80-run A/B showed the extra
  branch/prefix bookkeeping overwhelmed the avoided path-rule checks: default
  regressed to 86.0 ms versus 78.7 ms before, hidden to 88.0 ms versus
  80.8 ms before, and no-vcs stayed slightly worse at 64.8 ms versus 63.7 ms.
- Calling `opendir` through a local `String.withCString` helper instead of the
  direct Swift string bridge was also rejected. It preserved exact Swift output
  and sorted Rust parity for default, hidden, no-vcs, and no-ignore file
  listing, but the timings were order-sensitive and not a clear win: a
  current-first 100-run pass put default at 81.0 ms versus 78.9 ms before,
  while an order-flipped 120-run pass put default nearly flat at 79.3 ms versus
  79.5 ms before and hidden slightly worse at 81.0 ms versus 80.8 ms before.
  The existing direct `opendir(path)` calls stayed.
- Dropping scoped-path checks for ignore matchers whose rules are all
  unanchored basename-only was rejected. The probe kept the public `GlobMatcher`
  semantics unchanged by making the scope drop opt-in from ignore loading, and
  exact Swift output matched the previous binary for default, hidden, no-vcs,
  no-global, and `--debug --files`; sorted output matched Rust for the
  non-debug file-list controls. The code shape still regressed default
  `--files` to 79.6 ms versus 78.6 ms before and no-vcs to 64.3 ms versus
  63.6 ms before in a 100-run A/B, while hidden was neutral at 80.8 ms versus
  80.9 ms. The existing scoped matcher path stayed.

A fresh three-run Linux benchsuite scan kept recursive search ahead of Rust on
all captured rows, so the active gap remains ignore-aware file listing rather
than search throughput. The slowest Swift/Rust ratios were still Swift wins:
`linux_alternates_casei` at 2.308 s versus Rust 2.635 s, `linux_no_literal` at
2.214 s versus Rust 2.602 s, `linux_no_literal (ASCII)` at 2.159 s versus Rust
2.691 s, and `linux_unicode_greek_casei` at 2.123 s versus Rust 2.618 s.

### Continuation probes — 2026-05-29

A fresh curated Linux search scan showed the current Swift search path is
already faster than Rust on the measured cases, so the remaining active gap is
ignore-aware `--files`, not literal search:

- `linux_literal_default`: Swift 1.633 s vs Rust 2.797 s.
- `linux_literal_casei`: Swift 1.718 s vs Rust 2.740 s.
- `linux_no_literal`: Swift 2.343 s vs Rust 2.867 s.

Case-sensitive recursive alternations now use a Swift/Foundation no-match
preflight for larger multi-literal file buffers before falling back to the
existing byte-line scanner. The preflight preserves match semantics because it
only returns early when none of the literal byte strings are present in the
file. Sorted output for the Linux kernel
`ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT` workload matched Rust exactly
(140 lines). A direct seven-run A/B measured the retained 4 KiB-gated preflight
at 2.287 s median versus the previous 2.690 s median on the same binary pair,
about a 1.19x speedup. A focused harness recheck measured Swift at 2.276 s for
`linux_alternates`; neighboring `linux_alternates_casei` and `linux_literal`
remained in the Swift-win band.

The same recursive no-match preflight now probes mapped file buffers with the
existing Swift byte scanner instead of allocating `Data` for each literal search.
Direct byte/status checks matched the previous Swift binary and sorted Rust
output for the Linux alternation, literal, no-literal, and case-insensitive
controls. A seven-run A/B on the Linux
`ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT` workload improved from 2.309 s
to 1.938 s, versus 2.775 s for Rust. The neighboring single-literal
`spin_lock` control stayed in the same band at 1.790 s versus 1.738 s before
and 2.716 s for Rust.

Unicode Greek script property searches now avoid treating the property name as a
required literal prefilter and keep `\p{Greek}` intact through ignore-case
pattern rewriting. A narrow Swift-native matcher covers the exact `\p{Greek}`
and `\p{Greek}+` forms, including Rust-compatible `Ω` script handling and the
`µ` ignore-case fold, with a high-bit guard for ASCII lines. Sorted Linux corpus
output for `-n '\p{Greek}'` and `-n -i '\p{Greek}'` matched Rust exactly
(105 and 245 lines respectively). The corrected Foundation-regex path measured
about 30.9 s for plain `\p{Greek}` before the native matcher; the retained
Swift matcher measured 21.5 s plain and 21.6 s ignore-case by `/usr/bin/time`,
versus Rust at about 2.76 s in a five-run hyperfine sample.

The recursive matching-lines path now keeps that exact Greek-script matcher on
raw UTF-8 bytes until a line must be emitted, avoiding per-line `String` matcher
calls for non-matching high-bit lines. It still falls back for encodings, spans,
context, JSON/stats, replacements, word/line boundaries, inverted searches, and
other formatted modes. Sorted Linux corpus output for both `-n '\p{Greek}'` and
`-n -i '\p{Greek}'` continued to match Rust exactly (105 and 245 lines). A
five-run hyperfine sample measured Swift at 1.973 s plain and 2.016 s
ignore-case, versus Rust plain at 2.804 s on the same corpus. A current
warm-cache `/usr/bin/time -p` recheck measured Swift at 1.99/2.01 s plain and
1.96/1.98 s ignore-case, with Rust at 2.68/2.74 s plain and 2.86/2.91 s
ignore-case.

The direct Darwin `--files` byte writer now also handles option combinations
where the individual ignore toggles disable every ignore source. This preserves
explicit `--ignore-file` handling unless `--no-ignore-files` is also set. Sorted
Linux corpus output for
`--no-ignore-dot --no-ignore-global --no-ignore-parent --no-ignore-vcs --no-ignore-files --files`
matched both Swift `--no-ignore --files` and Rust with the same flags exactly
(79,046 lines). A 12-run hyperfine sample measured Swift at 72.6 ms ± 7.8 ms
for the expanded toggles, Swift `--no-ignore --files` at 66.8 ms ± 1.8 ms, and
Rust at 61.7 ms ± 1.1 ms.

The executable ASCII case-insensitive containment proof now uses the existing
folded byte scanner instead of building exact/lower/upper `Data` variants. It
initially only proved no-match for literals without ASCII letters; lettered
no-matches fell back. Direct status/stdout/stderr checks matched the previous
Swift binary and Rust for explicit-file quiet, path-only, without-match, and
digit no-match controls. A 30-run A/B on the 23 MiB Linux register header
measured `-q -i ReG_MaSk` at 3.2 ms versus 23.6 ms before and 3.3 ms for Rust;
`-l -i ReG_MaSk` measured 3.1 ms versus 23.6 ms before and 3.3 ms for Rust. A
digit no-match control improved from 9.8 ms to 5.6 ms. A follow-up no-letter
literal branch reuses the plain byte scanner, keeping mixed-case controls in the
same band while improving the digit no-match control again to 4.9 ms in an
order-flipped 60-run check, versus 5.4 ms for the folded scanner and 4.8 ms for
Rust.

Lettered ASCII case-insensitive quiet/path-only no-matches now use the same
folded byte scanner, then only return no-match when the mapped haystack has no
non-ASCII bytes. Non-ASCII haystacks still fall back for Unicode case folding.
Targeted status/stdout/stderr checks matched the previous Swift binary and Rust
for ASCII match/no-match, `-q`, `-l`, `-L`, Unicode fallback, binary, and empty
file controls. On a 46 MiB ASCII file, a 40-run A/B measured
`-i -q missingliteral` at 9.5 ms for the probe versus 33.3 ms baseline and
9.6 ms for Rust; `-i -l missingliteral` measured 9.4 ms versus 33.4 ms
baseline. The order-flipped 60-run confirmation measured `-i -q` at 9.5 ms
probe versus 34.4 ms baseline and `-i -l` at 9.4 ms probe versus 33.5 ms
baseline, with Rust `-i -q` at 9.7 ms.

Single-byte ASCII case-insensitive containment now reuses the existing Swift
byte-set search helper instead of the generic folded literal scanner. This keeps
Unicode haystacks on the conservative fallback when no ASCII byte proves a
match, while avoiding the scalar one-byte fold loop for large ASCII misses.
Targeted stdout/stderr/status checks matched the previous Swift binary and Rust
for `-q`, `-l`, and `--files-without-match` match/no-match cases plus a Unicode
fallback fixture. On a 48 MiB ASCII exact-line fixture, a 40-run A/B measured
`-q -i Z` at 9.4 ms versus 26.6 ms before and 5.5 ms for Rust; `-l -i Z`
measured 7.1 ms versus 25.3 ms before and 5.6 ms for Rust. The order-flipped
confirmation measured `-q -i Z` at 7.2 ms versus 28.1 ms before and `-l -i Z`
at 6.9 ms versus 24.9 ms before.

Single-byte ASCII case-insensitive count paths now share that one-byte
specialization. `-c` first proves the byte is absent with the byte-set search
before falling into matched-line accounting, while `--count-matches` sums the
existing Swift byte counters for folded lower/upper variants instead of walking
the generic folded scanner. Targeted output/status checks matched the previous
Swift binary and Rust for count, count-matches, include-zero, prefixed count,
positive match, no-match, and Unicode fallback controls. On the same 48 MiB
fixture, a 40-run A/B measured `--count-matches -i Z` at 11.7 ms versus
27.4 ms before and 5.6 ms for Rust; `-c -i Z` measured 7.4 ms versus 25.5 ms
before and 5.5 ms for Rust. The order-flipped confirmation measured
`--count-matches -i Z` at 9.3 ms versus 28.8 ms before and `-c -i Z` at
7.3 ms versus 25.2 ms before. A dense positive `--count-matches -i N` check
measured Swift at 11.8 ms versus Rust at 107.9 ms.

Word-regexp quiet/path-only existence checks now reuse the existing Swift byte
scanner and ASCII boundary helper instead of `Data.range(of:)`. This preserves
the binary guard, Unicode-boundary fallback, and rejected-boundary cap while
making literal-absent word searches match the plain literal scanner path.
Targeted status/stdout/stderr checks matched the previous Swift binary and Rust
for word `-q`, `-l`, `-L`, fixed-string word controls, Unicode boundary
fallback, binary, and rejected-boundary fixtures. On the same 46 MiB ASCII file,
a 40-run A/B measured `-w -q missingliteral` at 7.2 ms for the probe versus
18.7 ms baseline and 6.9 ms for Rust; `-w -l missingliteral` measured 7.4 ms
versus 19.0 ms baseline. The order-flipped 60-run confirmation measured
`-w -q` at 7.1 ms probe versus 19.4 ms baseline and `-w -l` at 7.3 ms probe
versus 19.0 ms baseline, with Rust `-w -q` at 6.3 ms. The early-match
`-w -q needle` control stayed flat at 2.8 ms for both binaries.

Single-byte ASCII ignore-case word searches now take the same byte-set absence
shortcut before the heavier word-boundary scanner. Quiet/path-only mode still
checks every found byte for ASCII word boundaries, and no-match paths still
fall back on NUL or non-ASCII haystacks before proving absence. Count-line and
count-matches modes use the shortcut only to prove zero matches; positive cases
stay on the existing boundary counters. Targeted stdout/stderr/status checks
matched the previous Swift binary and Rust for quiet, path-only,
files-without-match, count, count-matches, include-zero, bounded word hits, and
Unicode fallback controls. On the 48 MiB exact-line fixture, a 40-run A/B
measured `-q -w -i Z` at 10.5 ms versus 27.6 ms before and 5.7 ms for Rust;
`-c -w -i Z` at 8.1 ms versus 26.3 ms before and 5.6 ms for Rust; and
`--count-matches -w -i Z` at 7.2 ms versus 25.3 ms before and 6.3 ms for Rust.
The order-flipped confirmation measured 7.7 ms versus 28.9 ms, 7.9 ms versus
26.0 ms, and 7.1 ms versus 25.1 ms for those same three forms.

JSON/stats summary-only no-matches now get a narrow executable preflight for
simple single-file literal searches. When the literal is absent and the mapped
file has no binary prefix, Swift emits the same zero-match JSON or stats summary
without constructing full search results. Exact Swift output matched the
previous binary for JSON/stats no-match, small match, and binary fallback
controls; JSON no-match also matched Rust through the parity harness after
normalizing elapsed fields. On the 46 MiB ASCII file, a 20-run A/B measured
`--json missingliteral` at 7.7 ms for the probe versus 2.201 s baseline and
7.3 ms for Rust; `--stats -q missingliteral` measured 7.6 ms versus 2.186 s
baseline; `--stats missingliteral` measured 7.5 ms versus 2.196 s baseline. An
order-flipped 10-run confirmation measured JSON at 7.5 ms probe versus 2.155 s
baseline and quiet stats at 8.0 ms probe versus 2.202 s baseline.

The JSON/stats summary preflight now also covers conservative ASCII
case-insensitive and word-regexp no-match proofs. `-i` summaries use the
existing folded byte scanner and only prove no-match when non-ASCII haystack
bytes cannot affect Unicode case folding; `-w` summaries use the existing ASCII
word-boundary byte scanner and fall back on non-ASCII boundaries or too many
rejected boundary candidates. Combined `-i -w` summaries still fall back. Direct
status/stdout/stderr checks matched the previous Swift binary and Rust for
`--json -i`, `--json -w`, `--stats -i`, and `--stats -w` on the 46 MiB ASCII
file after normalizing elapsed timing fields. `MiscTests` covered exact
zero-match JSON/stats output for the new modes, and the Rust parity harness
covered JSON summary parity. A five-run A/B measured `--json -i missingliteral`
at 10.8 ms for the probe versus 4.929 s baseline and 11.2 ms for Rust;
`--json -w` at 8.6 ms versus 2.182 s baseline and 7.7 ms for Rust;
`--stats -i` at 10.9 ms versus 4.961 s baseline and 9.8 ms for Rust; and
`--stats -w` at 9.0 ms versus 2.187 s baseline and 6.7 ms for Rust.

The same summary preflight now covers the combined ASCII `-i -w` no-match case.
The proof reuses the existing folded word-boundary scanner, then only emits the
summary directly when the mapped haystack has no NUL or non-ASCII bytes; those
cases preserve the existing fallback path. Direct status/stdout/stderr checks
matched the previous Swift binary and Rust for `--json -i -w` and
`--stats -i -w` after normalizing elapsed timing fields. A five-run A/B on the
46 MiB ASCII file measured `--json -i -w missingliteral` at 11.7 ms for the
probe versus 4.967 s baseline and 11.3 ms for Rust; `--stats -i -w` measured
11.0 ms versus 4.989 s baseline and 9.1 ms for Rust.

The summary preflight gate now admits formatting-only no-match modes that cannot
change a proven zero-match summary: context flags, `--max-columns`,
replacement text, and nonzero `--max-count`. `--max-count 0`, passthrough,
trim/CRLF, stop-on-nonmatch, null-data, and other semantic modes still fall
back. Direct status/stdout/stderr checks matched the previous Swift binary and
Rust for the measured cases after normalizing elapsed timing fields. On the
46 MiB ASCII file, five-run A/Bs measured `--json --max-columns 1` at 8.5 ms
for the probe versus 2.188 s baseline and 7.2 ms for Rust; `--json -C 2` at
8.6 ms versus 2.182 s and 7.7 ms for Rust; `--json -r x` at 8.9 ms versus
2.218 s and 7.4 ms for Rust; `--stats -m 1` at 8.5 ms versus 2.188 s and
6.4 ms for Rust; and `--stats -C 2` at 8.6 ms versus 2.195 s and 6.6 ms for
Rust.

The summary preflight gate now also admits match-shaping modes that cannot
change a proven zero-match summary: line-regexp, only-matching, and vimgrep.
The preflight still has to prove the literal is absent, so matching cases and
literal-present line-boundary cases remain on the regular path. Direct
status/stdout/stderr checks matched the previous Swift binary and Rust for JSON
and stats line-regexp, only-matching, and vimgrep controls after normalizing
elapsed timing fields. On the 46 MiB ASCII file, five-run A/Bs measured
`--json -x` at 8.4 ms for the probe versus 2.197 s baseline and 7.3 ms for
Rust; `--json -x -i` at 12.9 ms versus 5.086 s and 11.2 ms for Rust;
`--json -o` at 9.0 ms versus 2.189 s and 7.5 ms for Rust; `--json --vimgrep`
at 8.7 ms versus 2.220 s and 7.3 ms for Rust; `--stats -x` at 8.7 ms versus
2.204 s and 6.9 ms for Rust; `--stats -o` at 8.5 ms versus 2.194 s and
6.4 ms for Rust; and `--stats --vimgrep` at 8.8 ms versus 2.201 s and 7.6 ms
for Rust.

Stats-only files-with-matches and count no-match outputs now use the same
summary preflight when `--include-zero` is not active. `--include-zero` count
modes still need the leading `0` before the stats block. Direct
status/stdout/stderr checks matched the previous Swift binary and Rust for
`--stats -l`, `--stats -c`, `--stats --count-matches`, the `--include-zero`
fallback, and JSON count/path fallback controls. On the 46 MiB ASCII file,
five-run A/Bs measured
`--stats -l` at 9.0 ms for the probe versus 2.209 s baseline and 6.7 ms for
Rust; `--stats -c` at 9.4 ms versus 2.173 s and 7.2 ms for Rust; and
`--stats --count-matches` at 9.0 ms versus 2.210 s and 6.5 ms for Rust.

Matching stats count output now writes the count line and deterministic stats
block from the same matched-summary helper instead of falling through to the
full search path. The fast route is scoped to unbounded single-literal
`--stats -c` and `--stats --count-matches` forms with safe ASCII word and
ignore-case support. Normalized stdout/status checks matched Rust for plain and
prefixed counts, count-matches, `-i`, `-w`, `-i -w`, include-zero-on-match, and
a bounded fallback control. On the 46 MiB matching ASCII file, 30-run checks
measured `--stats -c` at 44.2 ms versus 8.074 s before and 38.1 ms for Rust,
`--stats -H -c` at 44.0 ms versus 8.088 s before and 38.1 ms for Rust, and
`--stats --count-matches` at 43.5 ms versus 38.3 ms for Rust.
A follow-up fused the case-sensitive single-literal matched-line and total-match
counts into one mapped-data pass for that stats route. Normalized output/status
checks matched Rust for multiple matches on one line, count-matches totals,
filename prefixes, final-line-without-newline input, one-byte literals, binary
fallback, and the 46 MiB fixture. Forty-run release checks measured
`--stats -c` at 17.7 ms versus 38.6 ms for Rust, `--stats -H -c` at 17.2 ms
versus 38.2 ms for Rust, and `--stats --count-matches` at 17.0 ms versus
38.1 ms for Rust.

JSON files-with-matches and count/count-matches no-match modes now use a
separate no-output preflight instead of the summary writer, preserving Rust's
empty JSON output for those modes while keeping `--include-zero` on the fallback
path. Direct status/stdout/stderr checks matched the previous Swift binary and
Rust for plain, `-i`, `-w`, combined `-i -w`, and `--include-zero` controls. On
the 46 MiB ASCII file, ten-run A/Bs measured `--json -l` at 7.1 ms for the
probe versus 28.1 ms baseline and 6.6 ms for Rust; `--json -c` at 7.4 ms versus
28.2 ms and 6.5 ms for Rust; `--json --count-matches` at 7.4 ms versus 24.9 ms
and 6.6 ms for Rust; `--json -i -c` at 9.6 ms versus 29.2 ms and 9.9 ms for
Rust; `--json -w -c` at 7.4 ms versus 108.9 ms and 6.6 ms for Rust; and
`--json -i -w -c` at 10.6 ms versus 117.5 ms and 9.9 ms for Rust.

Count and count-matches `--include-zero` no-match outputs now use a dedicated
count-line preflight. The preflight writes the required `0` line, honors CRLF
count termination, and appends the existing deterministic stats summary when
`--stats` is active; stats timing fields were normalized for Rust comparisons.
Direct status/stdout/stderr checks matched the previous Swift binary exactly
and matched Rust for JSON, stats, CRLF, and combined `-i -w` controls after
normalizing stats timing text. On the 46 MiB ASCII file, eight-run A/Bs measured
`--json -c --include-zero` at 7.3 ms for the probe versus 25.6 ms baseline and
6.2 ms for Rust; `--stats -c --include-zero` at 8.1 ms versus 2.193 s and
6.3 ms for Rust. Six-run A/Bs measured `--stats --count-matches --include-zero`
at 8.5 ms versus 2.180 s and 6.5 ms for Rust; `--stats -i -w -c --include-zero`
at 11.7 ms versus 4.959 s and 10.0 ms for Rust.

No-match `--files-without-match` JSON/stats path output now uses the same
literal absence proof and writes the path through the existing path-only
formatter, including CRLF and NUL path terminators. Stats timing fields were
normalized for comparisons. Direct status/stdout/stderr checks matched the
previous Swift binary and Rust for JSON, stats, CRLF, NUL, combined `-i -w`,
and combined JSON+stats controls. On a regenerated 46 MiB ASCII no-match file,
eight-run A/Bs measured `--json --files-without-match` at 9.7 ms for the probe
versus 43.3 ms baseline and 8.1 ms for Rust; `--stats --files-without-match`
at 11.7 ms versus 2.318 s and 8.6 ms for Rust. A six-run A/B measured
`--stats -i -w --files-without-match` at 15.2 ms versus 5.298 s and 13.3 ms
for Rust.

Matching `--json --files-without-match` outputs now avoid the full JSON/search
fallback too: once the existing literal, word, or ASCII ignore-case proof finds
a match, Swift emits no output and returns the required status 1 directly.
Direct release comparisons matched the previous Swift binary and Rust for
matching, no-match, binary, and combined `-i -w` controls. On the 46 MiB
matching ASCII file, eight-run A/Bs measured `--json --files-without-match` at
4.9 ms for the probe versus 29.4 ms baseline and 27.3 ms for Rust;
`--json -i -w --files-without-match` at 3.2 ms versus 429.7 ms and 81.7 ms for
Rust.

Matching `--json -l` / files-with-matches path output now uses the same
Swift-only path preflight as non-JSON path-only modes. Direct stdout/stderr/status
checks matched Rust for match, no-match, exact-line match, exact-line mismatch,
and combined `-i -w` controls. On the 46 MiB matching ASCII file, eight-run
Swift/Rust measurements put `--json -l` at 4.9 ms versus Rust at 3.6 ms,
down from the earlier 32.9 ms Swift probe.

Matching `--stats --files-without-match` summaries now use Swift summary
counters after a path-output match proof instead of falling through to the full
stats path. The gate is limited to single-file literal searches without
max-count, line-regexp, only-matching, vimgrep, context, replacement, trim, or
stop-on-nonmatch effects; binary, NUL, non-ASCII case-folding, and unsupported
word-boundary cases still fall back. Direct comparisons matched Rust for plain,
`-i`, `-w`, `-i -w`, and the 46 MiB matching file after normalizing elapsed
timing fields. A six-run Swift/Rust measurement put the 46 MiB
`--stats --files-without-match` matching case at 38.2 ms for Swift versus
39.4 ms for Rust, down from the earlier 8.103 s Swift probe.

Matching JSON count modes now reuse the existing Swift literal count preflights
instead of the full JSON path. Direct comparisons matched Rust for plain
`--json -c`, `--json --count-matches`, combined `-i -w`, and the 46 MiB
matching file. Eight-run Swift/Rust measurements on the 46 MiB file put
`--json -c` at 33.4 ms versus Rust at 22.1 ms, down from the earlier 68.1 ms
Swift probe; `--json --count-matches` measured 12.3 ms versus Rust at 39.6 ms.

Single-literal count output now bypasses the generic multi-literal line walker
and uses the Swift literal matched-line counter directly, including
filename-prefixed count output. Direct stdout/status comparisons matched Rust
for `--json -c`, bounded `--json -m2 -c`, `--json -c --include-zero`,
prefixed `--json -H -c`, bounded prefixed count output, and prefixed
include-zero output. On the same 46 MiB matching ASCII file, a 30-run check
measured `--json -c` at 15.2 ms versus the prior same-run route at 34.0 ms and
Rust at 22.2 ms; `--json --count-matches` remained 12.2 ms. A follow-up
30-run prefixed check measured `--json -H -c` at 15.3 ms versus the previous
route at 33.7 ms and Rust at 22.0 ms, with unprefixed `--json -c` at 14.8 ms.
The plain non-JSON single-literal count route now uses that same direct helper
instead of detouring through the one-literal multi-literal walker. Direct
stdout/stderr/status comparisons matched Rust for plain `-c`, prefixed `-H -c`,
bounded `-m2 -c`, prefixed bounded counts, `--include-zero`, CRLF summaries, and
a binary-file prefixed count case. A 30-run release check on the 46 MiB matching
ASCII file measured plain `-c` at 15.1 ms versus Rust at 22.5 ms, `-H -c` at
14.9 ms versus Rust at 22.2 ms, and `--json -c` still at 15.1 ms.

Line-shaping flags that do not affect a proven zero-match summary now share the
summary preflight as well: `--crlf`, `--trim`, and `--stop-on-nonmatch`. Direct
status/stdout/stderr checks matched the previous Swift binary and Rust for JSON
and stats controls after normalizing elapsed timing fields. On the 46 MiB ASCII
file, five-run A/Bs measured `--json --crlf` at 8.6 ms for the probe versus
3.590 s baseline and 7.4 ms for Rust; `--stats --crlf` at 8.1 ms versus
3.593 s and 7.3 ms for Rust; `--json --trim` at 8.6 ms versus 2.183 s and
7.4 ms for Rust; `--stats --trim` at 8.5 ms versus 2.189 s and 6.5 ms for
Rust; `--json --stop-on-nonmatch` at 8.5 ms versus 2.173 s and 7.4 ms for
Rust; and `--stats --stop-on-nonmatch` at 9.2 ms versus 2.169 s and 6.7 ms for
Rust.

Files-mode controls on `/tmp/swift-rg-bench/linux` isolated the cost to VCS
ignore handling. A 30-run slice measured Swift `--files` at 101.3 ms ± 2.9 ms,
Swift `--hidden --files` at 101.6 ms ± 2.7 ms, Swift
`--no-ignore --files` at 65.5 ms ± 1.5 ms, and Rust `--files` at
75.1 ms ± 1.1 ms. `--no-ignore-vcs --files` measured 74.5 ms ± 2.2 ms,
while `--no-ignore-dot`, `--no-ignore-parent`, and `--no-ignore-global` were
near the default path. The fresh Time Profiler export
`/tmp/swift-rg-current-timesample.xml` now points at directory traversal,
`fastDirectoryContents`, relative-path construction, and `IgnoreStack` /
`GlobMatcher` decisions; the old `/tmp/swift-rg-timesample.xml` still showed
default file-type registry initialization and is stale for current files-mode
work.

The Darwin fast walker now passes the known root-relative directory scope
directly into local ignore matcher loading, avoiding repeated `URL.path`
containment checks for directory-local `.gitignore`/`.ignore` files when debug
logging is off. Sorted default and hidden `--files` output matched Rust exactly.
A 30-run same-machine A/B measured default `--files` at 100.7 ms for the probe
versus 101.9 ms baseline; an order-flipped 80-run confirmation measured
101.4 ms probe versus 101.8 ms baseline. Hidden `--files` measured 101.4 ms
versus 101.7 ms in the 30-run A/B and 101.1 ms versus 102.7 ms in the
order-flipped confirmation.

`GlobMatcher.Rule` now only compiles the fallback `**/pattern` regex when the
matcher was created with slash-patterns-match-anywhere semantics. Directory-local
ignore matchers pass that mode as false, so they keep their direct regex fallback
without paying for an unused second ICU regex. Exact Swift output matched the
saved pre-change binary for default and hidden file listing, and sorted output
matched Rust. A 40-run A/B measured default `--files` at 103.8 ms for the probe
versus 105.1 ms baseline and hidden at 105.9 ms versus 104.8 ms; the
order-flipped confirmation measured default at 104.8 ms probe versus 107.4 ms
baseline and hidden at 104.1 ms probe versus 108.7 ms baseline.

`GlobMatcher.compileFastMatcher` now derives unsupported-meta, simple-glob-meta,
and star-count facts with one Swift UTF-8 scan instead of constructing
`CharacterSet` values and doing multiple Foundation string searches for every
ignore rule. Exact Swift output matched the saved pre-change binary for default
and hidden file listing, and sorted output matched Rust. Initial same-machine
40-run A/Bs were noisy but pointed at lower system time for the probe; isolated
80-run confirmations measured default `--files` at 101.2 ms for the probe versus
102.7 ms baseline and hidden `--files` at 101.3 ms versus 105.7 ms.

Ignore-aware `--files` now writes each top-level parallel chunk as UTF-8 `Data`
instead of merging arrays of path strings and converting them later in the CLI.
Exact Swift output matched the pre-change binary for default, hidden,
`--no-ignore-vcs`, and `--no-ignore`; sorted output matched Rust. A same-machine
40-run A/B measured default `--files` at 98.3 ms for the probe versus 104.8 ms
baseline, hidden at 97.6 ms versus 103.1 ms, and `--no-ignore-vcs --files` at
70.1 ms versus 74.1 ms. The order-flipped 80-run confirmation measured default
at 97.6 ms probe versus 102.2 ms baseline, hidden at 97.6 ms versus 104.4 ms,
and `--no-ignore-vcs` at 71.5 ms versus 74.5 ms with one first-run probe
outlier; Rust default measured 75.5 ms in that same run.

The ignore-aware data chunk writer now also emits recursive file paths into the
chunk buffer from existing Swift `String.UTF8View` storage instead of building a
fresh output `String` for every path. Ignore matching still uses the established
String path flow, and directory entries do not store extra byte-array copies.
Exact Swift output matched the pre-change binary for default, hidden,
`--no-ignore-vcs`, and `--no-ignore`; sorted output matched Rust. The first
40-run A/B measured default `--files` at 96.2 ms for the probe versus 100.6 ms
baseline, hidden at 100.4 ms versus 97.9 ms with a noisy probe tail, and
`--no-ignore-vcs --files` at 68.8 ms versus 69.2 ms. The order-flipped 80-run
confirmation measured default at 98.8 ms probe versus 99.8 ms baseline, hidden
at 96.3 ms versus 99.8 ms, and `--no-ignore-vcs` at 68.5 ms versus 78.6 ms
with a noisy baseline tail. A fresh 40-run Swift/Rust snapshot measured current
Swift default `--files` at 96.9 ms versus Rust at 74.8 ms, hidden at 95.0 ms
versus 74.8 ms, and `--no-ignore-vcs` at 71.8 ms versus 70.9 ms.

Rejected Swift-only probes from this continuation preserved exact Swift output
and sorted Rust parity unless noted, but did not improve the checkpoint:

- Storing each ignore-aware directory entry name as a separate `[UInt8]` so
  recursive chunks could append cached bytes preserved exact Swift output and
  sorted Rust parity, but the extra allocation did not survive confirmation. The
  first 40-run A/B improved default and hidden but regressed
  `--no-ignore-vcs`; the order-flipped 80-run confirmation measured default
  `--files` at 99.0 ms probe versus 98.3 ms baseline, hidden at 98.8 ms versus
  99.3 ms, and `--no-ignore-vcs` at 72.6 ms versus 70.3 ms. The lighter
  `String.UTF8View` writer landed instead.
- Raising the CLI file-path output buffer from 64 KiB to 256 KiB preserved exact
  Swift output and sorted Rust parity for default, hidden, and no-ignore file
  listing, but was flat to slightly worse. A 40-run A/B measured default
  `--files` at 106.3 ms baseline versus 106.2 ms probe, hidden at 104.2 ms
  baseline versus 105.0 ms probe, and `--no-ignore --files` at 67.9 ms baseline
  versus 70.3 ms probe.
- Reusing one root Git-context check for global-ignore setup measured
  103.5 ms ± 6.4 ms, essentially flat.
- Threading known ASCII path state into ignore decisions regressed to
  114.5 ms ± 3.2 ms and raised user CPU.
- Expanding simple character-class globs into indexed exact/prefix/suffix sets
  regressed to 116.8 ms ± 6.1 ms.
- Scoped basename-only matcher dispatch was neutral at 102.3 ms ± 5.3 ms.
- Raising `fastDirectoryContents` child reserve from 64 to 128 was neutral for
  default and slightly worse for no-ignore.
- Recursive and top-wide nested parallel walkers preserved output but
  over-scheduled heavily, regressing default files mode to 311.8 ms ± 16.2 ms
  and 266.3 ms ± 12.3 ms respectively.
- Forcing inline on `FastDirectoryEntryKind` predicates was noisy/worse at
  104.5 ms ± 4.9 ms.
- Filtering empty/comment ignore lines before `GlobMatcher` construction in
  normal non-debug mode preserved the exact Swift `--files` output hash and
  sorted Rust parity, but measured 103.6 ms ± 3.0 ms versus the 103.0 ms
  baseline, so the parser shape stayed unchanged.
- A single-matcher fast path in `IgnoreStack` preserved the exact Swift
  `--files` output hash and sorted Rust parity, but the same-machine A/B was
  flat at 101.3 ms versus 101.5 ms, so the simpler stack iteration stayed.
- Collapsing fast-path root existence, directory, and root-base checks into one
  Darwin status probe preserved sorted Rust parity for default and no-ignore
  file listing, but a same-machine 30-run A/B was flat: default `--files`
  measured 101.7 ms baseline versus 101.2 ms for the probe, and
  `--no-ignore --files` measured 65.1 ms baseline versus 64.4 ms for the probe.
  The existing setup path stayed to avoid a neutral churn-only change.
- Caching `GlobMatcher`'s scoped strip-prefix character count avoided
  recomputing it during directory-local ignore decisions and preserved sorted
  Rust parity for default and hidden file listing, but a same-machine 30-run A/B
  was flat: default `--files` measured 101.8 ms baseline versus 101.4 ms for
  the probe, while `--hidden --files` measured 103.0 ms baseline versus
  102.7 ms for the probe. The extra stored field stayed out.
- Walking `SimpleGlob` tokens through `withUnsafeBufferPointer` instead of
  binding `glob.tokens` to a local array preserved sorted Rust parity for
  default and hidden file listing, but regressed the hot path: a 20-run probe
  measured default `--files` at 118.2 ms ± 4.0 ms and `--hidden --files` at
  119.7 ms ± 4.5 ms, with user CPU rising above 300 ms. The simpler token loop
  stayed.
- Removing the 4 KiB size gate from the retained multi-literal no-match
  preflight was noisier against the Linux alternation corpus; the ungated probe
  measured 2.298 s ± 0.058 s mean versus the gated probe at 2.286 s ± 0.010 s,
  so tiny files continue to use the existing line scanner.
- Loading scanned local `.gitignore`/`.ignore`/`.rgignore` files through a
  string-path helper instead of `URL.appendingPathComponent` preserved exact
  Swift output and sorted Rust parity for default and hidden file listing, but
  the same-machine 40-run A/B was slightly worse: default `--files` measured
  103.0 ms baseline versus 104.2 ms for the probe, while `--hidden --files`
  measured 101.7 ms baseline versus 102.6 ms for the probe. The URL loader
  stayed.
- Reading ignore files through `Data(contentsOf:)` plus explicit UTF-8 decoding
  instead of `String(contentsOfFile:encoding:)` preserved sorted Rust parity, but
  did not survive order-flipped confirmation. The first 40-run A/B was noisy
  (default `--files` 118.3 ms baseline versus 111.7 ms probe, hidden
  103.5 ms baseline versus 108.0 ms probe); the flipped run measured default
  102.5 ms baseline versus 102.7 ms probe and hidden 104.7 ms baseline versus
  102.8 ms probe. The direct String loader stayed.
- Splitting ordinary ASCII ignore files with a Swift UTF-8 byte loop instead of
  `components(separatedBy: .newlines)` preserved exact Swift output and sorted
  Rust parity for default and hidden file listing, but the 40-run A/B was flat:
  default `--files` measured 103.8 ms baseline versus 102.4 ms probe, while
  `--hidden --files` measured 101.9 ms baseline versus 102.1 ms probe. The
  Foundation splitter stayed.
- Guarding `GlobMatcher.Rule` escaped-slash normalization and checking rule slash
  markers through UTF-8 bytes preserved exact Swift output and sorted Rust parity,
  but also measured neutral-to-worse: a 40-run A/B measured default `--files` at
  105.2 ms baseline versus 105.1 ms probe, and hidden at 102.4 ms baseline
  versus 103.8 ms probe. The simpler String operations stayed.
- Adding empty-bucket guards around `GlobMatcher.fastDecision` dictionary lookups
  preserved exact Swift output and sorted Rust parity, but regressed both file
  listing modes and raised user CPU. A 40-run A/B measured default `--files` at
  104.9 ms baseline versus 120.1 ms probe, and hidden at 102.1 ms baseline
  versus 118.8 ms probe. The unconditional lookup shape stayed.
- Fusing `IgnoreStack.allows` with its own reversed matcher walk preserved exact
  Swift output for default, hidden, and `--no-ignore-vcs` file listing plus
  sorted Rust parity, but did not improve the hot controls. A 40-run A/B measured
  default `--files` at 101.8 ms baseline versus 104.1 ms probe, hidden at
  101.5 ms baseline versus 102.3 ms probe, and `--no-ignore-vcs --files` at
  73.9 ms baseline versus 74.6 ms probe. The shared `decision` call stayed.
- Reusing the full-pattern glob meta scan to classify `**/literal` fast matchers
  preserved exact Swift output and sorted Rust parity, but the order-flipped
  confirmation was mixed. The first 40-run A/B measured default `--files` at
  104.8 ms baseline versus 102.0 ms probe and hidden at 102.0 ms baseline versus
  101.6 ms probe; the 80-run flipped run measured default at 102.7 ms probe
  versus 103.6 ms baseline, but hidden regressed to 105.2 ms probe versus
  102.7 ms baseline. The explicit suffix meta scan stayed.
- Disabling the ignore-aware top-level parallel file-list walker preserved exact
  Swift output and sorted Rust parity for default and hidden file listing, but it
  regressed hard. A 30-run A/B measured default `--files` at 100.8 ms baseline
  versus 166.8 ms probe, hidden at 100.4 ms baseline versus 172.3 ms probe, and
  `--no-ignore-vcs --files` at 73.3 ms baseline versus 112.8 ms probe. The
  top-level parallel walker stayed.

## Swift-only word/case checkpoint — 2026-05-28

Single-literal `-w -i` now has an ASCII-only Darwin preflight that reuses the
Swift literal writer with word-boundary checks. It rejects non-ASCII haystacks
so Unicode word-boundary cases fall back to the existing matcher. Direct
release comparisons against Rust `rg` were byte-identical for output, line
numbers, counts, quiet mode, path-only mode, files-without-match, and a
Unicode-adjacent fallback fixture. Follow-ups extend the same ASCII-only guard
to single-literal `--count-matches -w -i`, multi-literal word/count modes,
single-literal only-matching word/case output, and plain single- or
multi-literal only-match output. Encoded multi-literal word line output now
uses the same ASCII-safe line writer before falling back, and bounded
multi-literal word output buffers proven line ranges before writing so tiny
`-mN` searches avoid full-line scans. The non-word
`-o`/`-o -i` path emits the
original matched bytes, preserves line-number and filename prefixes, handles
overlapping alternatives with Rust-compatible leftmost/alternation order, and
falls back for binary-prefix haystacks; ignore-case additionally falls back for
non-ASCII haystacks. Heading output now uses the same only-match writer and
emits the heading lazily before the first match. Heading is output-neutral for
count summaries, so heading count and count-matches forms also stay on the
existing count preflights.
Single-literal ASCII `--count-matches -i` now has a total-match counter that
falls back on non-ASCII or binary-prefix haystacks.
Case-insensitive line counts now use a byte-level matched-line scan that finds
the next folded literal match and skips directly to the following line.
Case-insensitive exact-line count summaries now search folded full-line needles
directly instead of walking every line with `Data` indices, and exact-line
existence probes defer the full non-ASCII scan until no ASCII whole-line match
has been proven.
Case-insensitive exact-line matching output now uses the same raw byte line
loop for line detection and prefix emission, while retaining the conservative
binary and non-ASCII fallback before writing.
Mapped ASCII haystack guards now use a Swift SIMD byte scan instead of
`Data.contains(where:)`, removing the guard as the dominant cost for dense
ASCII case-insensitive preflight modes.
Case-insensitive exact-line matching output now writes through the existing raw
stdout buffer, avoiding per-line `Data` growth and string-backed line-number
prefix formatting.
Case-insensitive word quiet and path-only probes now search for a bounded ASCII
match before doing full-haystack ASCII/NUL rejection, while still deferring to
the fallback searcher before proving no-match or Unicode-adjacent candidates.
Path-only preflights now write path bytes and terminators directly through
stdout instead of allocating a tiny `Data` buffer and handing it to
`FileHandle`.
Single-file `--files-without-match` probes now use the existing Swift SIMD
literal scanner for the full-file absence check while leaving positive
path-only existence probes on the Foundation search path.
Count preflights now use the same raw stdout buffer for prefix, decimal count,
and LF/CRLF output instead of allocating a tiny `Data` buffer for the count
line.
Generic binary-adjustment NUL probes now use the existing memchr-backed scanner
instead of `Data.firstIndex(of:)`; a direct 50-scan check on the 7.5 MiB dense
fixture measured 943.3 ms for `firstIndex` versus 8.2 ms for the scanner.
Direct searcher path-only output now goes through `OutputPathFormatter` before
writing, matching Rust's composed Unicode path bytes for explicit path-only
PCRE fast paths. The writer emits normal path-length lines through one Swift
stack buffer instead of allocating `Array(path.utf8) + newline`.
ASCII fixed-lookbehind PCRE quiet and path-only forms now enter a Swift
executable preflight too, avoiding the generic searcher setup when the result
only needs an exit status or a path.
ASCII fixed-lookahead PCRE quiet and path-only forms use the same mapped Swift
existence preflight, including overlap-safe rejected candidates for negative
lookahead.
ASCII fixed-lookaround PCRE count and count-matches forms now use mapped Swift
counting preflights too, preserving prefixed counts, CRLF summaries,
`--include-zero`, bounded line counts, and overlap-safe rejected assertions.
Positive fixed-lookbehind/lookahead matching-line output now searches the
contiguous `prefixliteral` / `literalsuffix` key through the literal line
writer too, since whole-line output does not expose the assertion span.
Negative fixed-lookbehind/lookahead matching-line output now uses a Swift
assertion-aware literal line writer that scans candidate literals, checks the
fixed prefix/suffix predicate, and emits each accepted line through the raw
stdout buffer.
ASCII PCRE reset-start `prefix\Kliteral` quiet, path-only, count, and
count-matches summaries now reuse the fixed-lookbehind mapped Swift preflights
for non-empty ASCII prefix/literal pairs. Normal matching-line output for the
same reset-start shape now uses the literal line writer with the contiguous
`prefixliteral` search key, since `\K` only changes the reported match span.
Active literal `--stop-on-nonmatch` matching-line and count output now have
mapped Swift writers that stop after the first non-matching line following the
first match.
Literal `--trim` matching-line output now routes through a Swift-only mapped
line writer that trims leading ASCII space, tab, and CR bytes from line content
before emitting the matched line, while preserving headings, line numbers, max-count,
fixed-string literals, no-final-newline output, and the conservative binary/BOM
fallbacks.
Output-neutral `--trim` combinations now stay eligible for the existing quiet,
path-only, count, count-matches, and only-matching preflights; full-line output
still requires a trim-aware writer.
Output-neutral `--null-data` combinations now stay eligible for quiet,
path-only, and count-matches literal preflights; NUL record-sensitive exact-line,
lookaround, count-line, and matching-line forms remain on fallback.
Output-neutral nonzero `--max-columns` combinations now stay eligible for quiet,
path-only, count, and count-matches literal preflights; matching-line and
only-matching forms still fall back so omitted-line output is preserved.
Output-neutral `--replace` combinations now stay eligible for quiet, path-only,
count, and count-matches literal preflights; matching-line and only-matching
replacement output remains on the existing replacement writer.
Output-neutral `--passthru` combinations now stay eligible for quiet,
path-only, count, and count-matches literal preflights; matching-line passthru
output remains on the existing mapped passthru writer.
Output-neutral `--vimgrep` combinations now stay eligible for quiet,
path-only, count, and count-matches literal preflights. Matching-line,
context, trim, inverted, stop-on-nonmatch, and passthru vimgrep output still
falls back to the existing vimgrep writers. Count and count-matches output now
also matches Rust's vimgrep default filename prefix while honoring
`--no-filename`.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--vimgrep -q needle` | 35.8 ms | 4.9 ms | 4.6 ms |
| `--vimgrep -l needle` | 1.488 s | 6.0 ms | 4.0 ms |
| `--vimgrep -c needle` | 1.497 s | 9.7 ms | 10.4 ms |
| `--vimgrep --count-matches needle` | 1.497 s | 6.9 ms | 19.5 ms |

Positive `--byte-offset` and `--column` formatting flags now stay eligible
when quiet, path-only, count, or count-matches modes make those fields
unobservable. Matching-line and only-matching output still falls back so byte
and column fields are preserved.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--byte-offset -q needle` | 37.7 ms | 4.2 ms | 4.0 ms |
| `--byte-offset -l needle` | 1.501 s | 5.7 ms | 4.1 ms |
| `--byte-offset -c needle` | 1.528 s | 12.8 ms | 12.6 ms |
| `--column --count-matches needle` | 1.519 s | 6.7 ms | 20.3 ms |

Color-enabled forms now stay eligible when quiet, count, or count-matches
output makes color unobservable. Path-only and matching-line color output still
falls back because Rust emits ANSI path/match styling there.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--color=always -q needle` | 256.0 ms | 4.3 ms | 3.9 ms |
| `--color=always -c needle` | 114.8 ms | 10.1 ms | 10.0 ms |
| `--color=always --count-matches needle` | 109.1 ms | 6.9 ms | 18.9 ms |

Only-matching now stays eligible when quiet or path-only modes suppress match
text, and unbounded `-o -c`/`-o --count-matches` reuse the count-matches
preflight because Rust counts individual matches in those forms. Matching
output, CRLF only-matching output, and bounded `-o -c -mN` stay on fallback.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-o -q needle` | 29.2 ms | 4.6 ms | 3.8 ms |
| `-o -l needle` | 1.435 s | 4.4 ms | 3.9 ms |
| `-o -c needle` | 1.456 s | 6.6 ms | 18.6 ms |
| `-o --count-matches needle` | 1.449 s | 7.1 ms | 19.0 ms |

Before/after context now only disables the generic executable preflight when
context lines can be printed. Quiet, path-only, count, and count-matches modes
stay on their existing literal preflights; matching-line output, including
`-o` with visible context lines, remains on the context-aware/fallback paths.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--after-context=1 -q needle` | 1.567 s | 1.6 ms | 899.0 us |
| `--before-context=1 -l needle` | 1.600 s | 2.1 ms | 2.2 ms |
| `--after-context=1 -c needle` | 1.536 s | 8.5 ms | 9.2 ms |
| `--before-context=1 --count-matches needle` | 1.582 s | 6.0 ms | 18.3 ms |

`--stop-on-nonmatch -c` already had a Swift literal preflight; context flags now
stay on that count preflight too because they do not change Rust's count output.
Visible stop-on-nonmatch context output stays on the context-aware/fallback path.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--stop-on-nonmatch --after-context=1 -c needle` | 1.533 s | 6.1 ms | 7.6 ms |
| `--stop-on-nonmatch --context=1 -c -m2 needle` | 823.4 ms | 4.0 ms | 2.9 ms |

Explicit UTF-8 and disabled encoding modes now stay eligible when quiet,
path-only, count, or count-matches modes avoid printing decoded line text. The
generic preflight still falls back for visible matching-line output, BOM input,
invalid UTF-8 output, and non-UTF-8 encodings such as Latin-1.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--encoding=utf-8 -q needle` | 1.458 s | 3.5 ms | 2.7 ms |
| `--encoding=utf-8 -l needle` | 1.454 s | 3.8 ms | 3.0 ms |
| `--encoding=utf-8 -c needle` | 1.472 s | 8.6 ms | 9.6 ms |
| `--encoding=utf-8 --count-matches needle` | 1.469 s | 5.8 ms | 18.0 ms |
| `--encoding=none -l needle` | 2.063 s | 3.5 ms | 2.8 ms |

Raw `--encoding=none` matching-line output now stays on the executable
preflight for plain line-output forms. Explicit UTF-8 and non-raw encodings
still fall back for visible line output, as do word, exact-line,
ignore-case, and only-matching forms. Direct byte/status checks covered normal
line output, line numbers, max-count, invalid raw bytes, UTF-8 BOM fallback,
an ignore-case fallback control, and an explicit UTF-8 invalid-byte control.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--encoding=none needle` | 3.240 s | 15.8 ms | 14.3 ms |
| `--encoding=none -n needle` | 3.507 s | 22.4 ms | 23.5 ms |
| `--encoding=none -m2 needle` | 1.396 s | 6.6 ms | 6.5 ms |

A follow-up keeps ASCII ignore-case raw encoding on the same preflight. The
non-ASCII literal guard still falls back naturally. Direct byte/status checks
covered dense output, invalid raw-byte output, no-match status, and non-ASCII
literal fallback.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--encoding=none -i NEEDLE` | 6.403 s | 16.2 ms | 20.4 ms |

Explicit UTF-8 visible line output now stays on the executable preflight when
the target file validates as UTF-8 and the command is still a plain literal
line-output form. Invalid UTF-8, BOM input, ignore-case, word, exact-line, and
only-matching forms still fall through to the full searcher. Direct byte/status
checks covered accepted line, line-number, and max-count forms plus those
fallback controls.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--encoding=utf-8 needle` | 1.765 s | 17.1 ms | 15.3 ms |
| `--encoding=utf-8 -n needle` | 1.813 s | 22.5 ms | 23.5 ms |
| `--encoding=utf-8 -m2 needle` | 908.6 ms | 7.4 ms | 5.0 ms |

ASCII-only explicit UTF-8 files now also keep selected semantic visible-output
forms on preflight. This covers ASCII ignore-case, only-matching, and
exact-line output while preserving Unicode case-folding/word-boundary fallback
for non-ASCII files. A same-turn probe left `--encoding=utf-8 -w needle` on the
fallback path after it measured neutral-to-slower with the existing word writer.
Direct byte/status checks covered `-i`, `-o`, and `-x` outputs plus `-w`,
Unicode case-fold, and non-ASCII word fallback controls. A later follow-up
made the ASCII eligibility probe use the existing SIMD high-bit scanner and
moved single-literal unnumbered exact-line output onto the stdout buffer.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups, except
`-x` which used `/tmp/swift-rg-candidates/exact-needle.txt`:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--encoding=utf-8 -i NEEDLE` | 4.863 s | 12.9 ms | 16.8 ms |
| `--encoding=utf-8 -o needle` | 1.726 s | 9.9 ms | 20.2 ms |
| `--encoding=utf-8 -x needle` | 2.445 s | 9.2 ms | 22.1 ms |

The same buffered exact-line writer measured plain `-x needle` at 9.0 ms and
raw `--encoding=none -x needle` at 8.6 ms on the exact-line fixture, versus
Rust at 21.9 ms and 21.6 ms.

Explicit UTF-8 ASCII ignore-case line output now validates the haystack inside
the mapped writer instead of doing a separate eligibility map/scan before
emitting. Direct checks matched Rust for ASCII, line-numbered, no-match,
Unicode casefold fallback, accent fallback, and vimgrep fallback forms. On the
same trim fixture, `--encoding=utf-8 -n -i NEEDLE` measured 17.4 ms versus
24.4 ms for Rust; a dense-line probe measured 12.5 ms versus 18.8 ms for Rust.

Explicit UTF-8 only-matching output now uses the same in-map ASCII validation
pattern before entering the existing only-match writer. Direct checks matched
Rust for ASCII, line-numbered, no-match, non-ASCII fallback, and vimgrep
only-match forms. On the same trim fixture, `--encoding=utf-8 -n -o needle`
measured 15.0 ms versus 26.2 ms for Rust.

Explicit UTF-8 compatible files now also keep literal vimgrep line output on
the Swift executable preflight, while non-ASCII ignore-case files continue to
fall back through the existing ASCII guard. Direct byte/status checks covered
plain vimgrep, ASCII ignore-case vimgrep, and deferred `--no-config` ordering.
On `/tmp/swift-rg-candidates/countm-big.txt`, `--encoding=utf-8 --vimgrep --heading -e needle -e quiet`
improved from 5.142 s to 47.9 ms, ASCII ignore-case UTF-8 vimgrep measured
76.0 ms, and Rust measured 90.4 ms.

`--search-zip` now stays on the executable preflight for explicit paths whose
suffix cannot trigger decompression. Compressed suffixes still fall through to
the normal searcher so real archives and decompressor errors keep matching
Rust. Direct byte/status checks covered no-suffix line output, quiet, path-only,
count, and count-matches modes, plus bad `.gz` and real gzip fallback controls.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--search-zip -q needle` | 171.4 ms | 4.8 ms | 3.7 ms |
| `--search-zip -l needle` | 80.9 ms | 4.2 ms | 4.2 ms |
| `--search-zip -c needle` | 111.0 ms | 10.1 ms | 12.7 ms |
| `--search-zip --count-matches needle` | 108.1 ms | 6.1 ms | 18.6 ms |

The same non-archive search-zip neutrality now applies to vimgrep line output,
including short `-z` and deferred `--no-config` ordering. On
`/tmp/swift-rg-candidates/countm-big.txt`, `--search-zip --vimgrep --heading -e needle -e quiet`
improved from 5.059 s to 47.3 ms, `-z --vimgrep --heading -e needle -e quiet`
measured 50.5 ms, and Rust measured 90.9 ms.

Leading `--no-config` now keeps the Swift executable preflight available even
when `RIPGREP_CONFIG_PATH` is set. The preflight still falls back for configured
invocations without a leading `--no-config`, and a `--no-config` pattern passed
after `--` or through `-e` is not treated as the flag by this outer guard.
Direct byte/status checks matched Rust for active config, leading `--no-config`,
line-numbered `--no-config`, leading engine selector plus `--no-config`, and a
neutral-flag-before-`--no-config` fallback control. A follow-up allows no-value
buffering/message flags before `--no-config` to keep the same preflight while
still falling back before any value-consuming flag or pattern source.

10 timed runs on `/tmp/swift-rg-candidates/trim.txt` with
`RIPGREP_CONFIG_PATH=/tmp/swift-rg-candidates/ripgreprc-no-config` and 3
warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--no-config needle` | 165.4 ms | 14.6 ms | 12.9 ms |
| `--line-buffered --no-config needle` | 165.4 ms | 14.8 ms | 128.6 ms |

The executable short-cluster parser now keeps additional already-supported
single-file flags on the Swift preflight: `H`/`I` filename toggles, `z`
search-zip enablement when the explicit path has no compressed suffix, and
`b` byte-offset enablement when the selected output mode makes offsets
unobservable. Direct byte/status checks matched Rust for clustered filename
ordering, search-zip line output, byte-offset quiet/count output, and a
visible byte-offset fallback control. A follow-up accepts clustered `p`
pretty mode when quiet or unprefixed count output makes color formatting
unobservable, while prefixed colored counts still fall back so ANSI path
coloring remains byte-identical to Rust.
The next slice writes Rust's default ANSI path coloring directly for forced
colored count prefixes. Non-path `--colors` overrides can use the same prefix
writer because count output does not expose line, column, match, or highlight
styles; `--color=auto` and custom path-color styles stay on the fallback path
where terminal/custom styling is observable.

7 timed runs on `/tmp/swift-rg-candidates/cluster-dense.txt`, a 600,000-line
literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-Hn needle` | 62.0 ms | 26.1 ms | 26.1 ms |
| `-nz needle` | 427.8 ms | 25.0 ms | 21.4 ms |
| `-bq needle` | 38.1 ms | 5.8 ms | 4.4 ms |
| `-Hc needle` | 43.5 ms | 13.2 ms | 10.8 ms |
| `-pq needle` | 456.0 ms | 5.4 ms | 5.0 ms |
| `-pc needle` | 277.5 ms | 12.7 ms | 11.8 ms |

7 timed runs on a generated 300,000-line literal fixture, with the before
column forcing the generic Swift path through `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--color=always -H -c needle` | 135.8 ms | 8.6 ms | 8.0 ms |
| `-pHc needle` | 129.8 ms | 8.7 ms | 8.2 ms |
| `--color=always --count-matches -H needle` | 136.6 ms | 7.5 ms | 13.4 ms |
| `--color=always --null -H -c needle` | 134.4 ms | 8.1 ms | 7.7 ms |
| `--colors match:fg:red --color=always -H -c needle` | 134.0 ms | 8.6 ms | 7.6 ms |
| `--colors line:fg:green --color=always --count-matches -H needle` | 134.2 ms | 7.2 ms | 13.2 ms |

Case-sensitive repeated `-e`/`-f` and top-level literal alternation `--trim`
forms now use the same mapped trim writer.
Literal `--invert-match` matching-line output now has its own mapped Swift line
writer for single-file literal searches, preserving line numbers, headings,
filename prefixes, max-count, fixed-string literals, no-final-newline output,
and binary/BOM fallback behavior.
Case-sensitive repeated `-e`/`-f` and top-level literal alternation
`--invert-match` forms now use a mapped multi-literal line classifier that emits
only lines containing none of the literals.
ASCII case-insensitive `--trim` and `--invert-match` now reuse Swift mapped
line writers when the literal and haystack are ASCII, preserving original
emitted bytes while leaving Unicode case-folding and binary input on the
fallback path.
ASCII case-insensitive multi-literal `--trim` and `--invert-match` forms now
share mapped classifiers for repeated `-e`/`-f` and top-level alternations when
all literals and the haystack are ASCII.
Literal `--passthru` matching-line output now uses a mapped Swift line writer
for single-file literal searches, emitting every line with Rust-compatible
match/context separators and returning status from whether any line matched.
It preserves line numbers, filename prefixes, headings, custom field match and
context separators, fixed-string literals, no-final-newline output, `-m0`
literal status, and binary/BOM fallback behavior.
Explicit multi-literal `--passthru` now uses the same Swift-first treatment for
literal `-e` and `-f` inputs, classifying each output line by whether any
literal source matched while keeping unsupported or ambiguous patterns on the
full matcher.
Top-level literal alternation `--passthru` forms now share that multi-literal
writer for positional and single-`-e` patterns.
ASCII case-insensitive `--passthru` now reuses the single- and multi-literal
mapped writers for plain literals, repeated `-e`/`-f` sources, and top-level
literal alternations when all literals and the haystack are ASCII. It folds
candidate checks in Swift while leaving Unicode case-folding and binary input
on the existing fallback.
Single-literal `-A`/`--after-context` matching-line output now has a mapped
Swift writer for explicit files when no before-context is active, preserving
match/context field separators, heading and filename layout, context separator
chunks, max-count, no-final-newline output, and binary/BOM fallback behavior.
Single-literal `-B`/`--before-context` now has the symmetric mapped Swift writer
for explicit files when no after-context is active, buffering prior line ranges
until a literal match selects them and preserving the same formatting and
fallback behavior.
Single-literal `-C`/`--context` now uses a combined mapped Swift writer when
both before- and after-context are active. It buffers prior line ranges and keeps
emitting trailing context after counted matches, preserving overlapping groups,
match/context markers, max-count, heading/prefix layout, no-final-newline output,
and conservative binary/BOM fallback behavior.
ASCII case-insensitive single-literal context output now reuses those same
mapped writers for `-A`, `-B`, and `-C` when the literal and haystack are ASCII,
falling back for Unicode case-folding candidates instead of widening the byte
scanner's semantics.
Case-sensitive multi-literal context output now uses a shared mapped Swift
writer for `-A`, `-B`, and `-C`, covering repeated `-e`/`-f` literal sources
and top-level literal alternations while preserving group separators,
match/context markers, max-count behavior, and binary/BOM fallback.
ASCII case-insensitive multi-literal context output reuses that writer when all
literals and the haystack are ASCII, folding candidate checks in Swift and
falling back when Unicode case-folding semantics may be needed.

A targeted 20-run A/B against the previous Swift checkpoint and Rust used the
same 4.8 MiB fixture:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--files-with-matches needle` | 4.2 ms | 3.1 ms | 2.8 ms |
| `--files-without-match absent` | 7.8 ms | 7.6 ms | 3.5 ms |

A follow-up 30-run shell-free check on the same fixture after narrowing the
SIMD scanner to absence probes measured:

| Flags | Swift | rg |
|---|---:|---:|
| `--files-with-matches needle` | 4.1 ms | 3.8 ms |
| `--files-without-match absent` | 4.5 ms | 4.1 ms |

The fixed-lookbehind check used
`/tmp/swift-rg-bench/pcre-lookbehind-small.txt`, a 5.7 MiB ASCII fixture, with
3 warmups and 20 timed runs. The before column is the same binary with the
executable preflight bypassed via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-P --files-with-matches '(?<=prefix)needle'` | 32.1 ms | 3.1 ms | 2.5 ms |
| `-P -q '(?<=prefix)needle'` | 36.0 ms | 3.2 ms | 2.6 ms |

The fixed-lookahead check used
`/tmp/swift-rg-bench/pcre-lookahead-small.txt`, a 6.4 MiB ASCII fixture, with
3 warmups and 20 timed runs. The before column is the same binary with the
executable preflight bypassed via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-P --files-with-matches 'needle(?=suffix)'` | 31.2 ms | 3.5 ms | 2.9 ms |
| `-P -q 'needle(?=suffix)'` | 32.0 ms | 3.4 ms | 2.9 ms |

The fixed-lookaround count check used the same two fixtures, with 3 warmups and
20 timed runs. The before column is the same binary with the executable
preflight bypassed via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-P -c '(?<=prefix)needle'` | 44.8 ms | 7.6 ms | 9.9 ms |
| `-P --count-matches '(?<=prefix)needle'` | 42.4 ms | 9.7 ms | 20.4 ms |
| `-P -c 'needle(?=suffix)'` | 44.9 ms | 6.9 ms | 9.8 ms |
| `-P --count-matches 'needle(?=suffix)'` | 42.0 ms | 7.2 ms | 20.5 ms |

The fixed positive lookaround matching-line check used
`/tmp/swift-rg-bench/pcre-lookbehind-line-small.txt` and
`/tmp/swift-rg-bench/pcre-lookahead-line-small.txt`, 4.64 MiB and 4.80 MiB
sparse ASCII fixtures, with 3 warmups and 10 timed runs. The before column is
the same binary with the executable preflight bypassed via
`RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-P '(?<=Sherlock )Holmes'` | 164.3 ms | 5.0 ms | 9.2 ms |
| `-P -n '(?<=Sherlock )Holmes'` | n/a | 5.1 ms | 9.1 ms |
| `-P 'Sherlock(?= Holmes)'` | 163.6 ms | 5.0 ms | 8.4 ms |
| `-P -n 'Sherlock(?= Holmes)'` | n/a | 4.7 ms | 8.2 ms |

The negative fixed lookaround matching-line check used
`/tmp/swift-rg-bench/pcre-neg-lookbehind-line-small.txt` and
`/tmp/swift-rg-bench/pcre-neg-lookahead-line-small.txt`, two 4.80 MiB sparse
ASCII fixtures, with 3 warmups and 10 timed runs. The before column is the
same binary with the executable preflight bypassed via
`RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-P '(?<!Sherlock )Holmes'` | 173.6 ms | 7.8 ms | 9.1 ms |
| `-P -n '(?<!Sherlock )Holmes'` | n/a | 7.0 ms | 8.9 ms |
| `-P 'Sherlock(?! Holmes)'` | 161.4 ms | 7.2 ms | 7.2 ms |
| `-P -n 'Sherlock(?! Holmes)'` | n/a | 6.5 ms | 7.2 ms |

The fixed reset-start check used
`/tmp/swift-rg-bench/pcre-reset-small.txt`, a 6.4 MiB ASCII fixture, with
3 warmups and 10 timed runs. The before column is the same binary with the
executable preflight bypassed via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-P --files-with-matches 'prefix\Kneedle'` | 36.4 ms | 4.5 ms | 3.6 ms |
| `-P -q 'prefix\Kneedle'` | 32.5 ms | 4.2 ms | 3.8 ms |
| `-P -c 'prefix\Kneedle'` | 39.8 ms | 8.6 ms | 8.6 ms |
| `-P --count-matches 'prefix\Kneedle'` | 40.4 ms | 9.1 ms | 19.4 ms |

The reset-start matching-line check used
`/tmp/swift-rg-bench/pcre-reset-line-small.txt`, a 4.16 MiB sparse ASCII
fixture, with 3 warmups and 10 timed runs. The before column is the same
binary with the executable preflight bypassed via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-P 'prefix\Kneedle'` | 35.5 ms | 4.8 ms | 7.2 ms |
| `-P -n 'prefix\Kneedle'` | 34.4 ms | 4.7 ms | 7.6 ms |

Benchmarks used `/tmp/swift-rg-bench/stop-on-nonmatch-small.txt`, a 4.8 MiB
dense ASCII fixture, with 2 warmups and 5 timed runs:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-w -i NEEDLE` | 2.122 s | 11.3 ms | 14.5 ms |
| `-n -w -i NEEDLE` | 209.3 ms | 11.9 ms | 19.2 ms |
| `-c -w -i NEEDLE` | 136.4 ms | 7.4 ms | 12.2 ms |
| `--count-matches -w -i NEEDLE` | 154.8 ms | 9.4 ms | 41.0 ms |
| `-c -w -i "NEEDLE\|QUIET"` | 184.8 ms | 7.8 ms | 12.7 ms |
| `--count-matches -w -i "NEEDLE\|QUIET"` | 173.8 ms | 9.6 ms | 52.9 ms |
| `-o -w -i NEEDLE` | 4.604 s | 13.5 ms | 50.1 ms |
| `-o needle` | 65.6 ms | 14.1 ms | 23.0 ms |
| `-n -o needle` | 81.6 ms | 22.2 ms | 30.1 ms |
| `-o "needle\|quiet"` | 59.6 ms | 17.8 ms | 32.1 ms |
| `-n -o "needle\|quiet"` | 66.8 ms | 28.3 ms | 42.6 ms |
| `--heading -H -o needle` | 1.661 s | 14.0 ms | 21.8 ms |
| `--heading -H -n -o needle` | 1.717 s | 21.8 ms | 30.9 ms |
| `--heading -H -o "needle\|quiet"` | 2.325 s | 17.8 ms | 32.6 ms |
| `--heading -H -c needle` | 144.8 ms | 5.7 ms | 5.3 ms |
| `--heading -H --count-matches needle` | 152.5 ms | 6.6 ms | 13.6 ms |
| `-o -i NEEDLE` | 68.6 ms | 11.2 ms | 43.5 ms |
| `-n -o -i NEEDLE` | 81.4 ms | 20.7 ms | 54.3 ms |
| `--count-matches -i NEEDLE` | 35.5 ms | 8.5 ms | 32.8 ms |
| `--heading -H --count-matches -i NEEDLE` | 142.5 ms | 8.2 ms | 33.3 ms |
| `-c -i NEEDLE` | 35.2 ms | 5.9 ms | 8.6 ms |
| `--heading -H -c -i NEEDLE` | 141.3 ms | 6.8 ms | 8.2 ms |
| `-c -i "NEEDLE\|QUIET"` | 36.6 ms | 7.2 ms | 8.6 ms |
| `-c -i -x "NEEDLE NEEDLE NEEDLE QUIET TAIL NEEDLE"` | 48.2 ms | 7.2 ms | 13.5 ms |
| `--count-matches -i -x "NEEDLE NEEDLE NEEDLE QUIET TAIL NEEDLE"` | 48.0 ms | 7.0 ms | 26.7 ms |
| `-i -x "NEEDLE NEEDLE NEEDLE QUIET TAIL NEEDLE"` | 62.3 ms | 10.4 ms | 15.3 ms |
| `-n -i -x "NEEDLE NEEDLE NEEDLE QUIET TAIL NEEDLE"` | 80.2 ms | 9.5 ms | 17.8 ms |
| `-i -x "NEEDLE NEEDLE NEEDLE QUIET TAIL NEEDLE\|MISSING"` | 57.3 ms | 9.1 ms | 15.6 ms |
| `-o -i "NEEDLE\|QUIET"` | 7.718 s | 19.8 ms | 54.5 ms |
| `-n -o -i "NEEDLE\|QUIET"` | 7.894 s | 29.8 ms | 66.6 ms |
| `-q -w -i NEEDLE` | 99.3 ms | 3.1 ms | 3.0 ms |
| `-l -w -i NEEDLE` | 125.7 ms | 3.2 ms | 2.6 ms |

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
`maxCount` through to the mapped multi-literal writer; unsupported semantic
modes still fall back. A follow-up handles `-m0`/`--max-count=0` before search
work begins, matching Rust's empty-output status-1 behavior for normal, quiet,
path-only, counted include-zero, missing-root, and invalid-regex forms while
still preserving parser/type diagnostics. Dense-fixture byte checks matched Rust for
plain, line-numbered, filename-prefixed, heading-prefixed, pattern-file, and
single-pattern alternation forms. On the 50 KiB dense fixture,
`-m2 -e needle -e quiet` measured 4.1 ms versus 32.0 ms before and 2.6 ms for
Rust, while `-n -m2 -f patterns.txt` measured 4.8 ms versus 36.7 ms before and
2.5 ms for Rust.

Nine-run checks on a generated 300,000-line fixture measured the `-m0`
early-exit path:

| Flags | Swift current | rg |
|---|---:|---:|
| `-m0 needle` | 3.93 ms | 2.60 ms |
| `-m0 -q needle` | 3.69 ms | 2.65 ms |
| `-m0 -l needle` | 3.68 ms | 2.70 ms |
| `-m0 -c --include-zero needle` | 3.71 ms | 2.71 ms |

Multi-literal count output now reuses that same mapped writer without emitting
matched lines, then prints only the matched-line count summary. This covers
unbounded `-c` and bounded `-c -mN`/`--count --max-count N` for safe
alternations, repeated explicit regexps, and literal-only pattern files, while
quiet precedence, ASCII ignore-case fallback, and unsupported semantic modes
stay on prior behavior. Dense-fixture byte checks matched Rust for
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
The follow-up keeps ordered print modes inside short clusters too, so Rust
forms such as `-cl`, `-lc`, `-Hcl`, and `-Hlc` reuse the existing path-only or
count preflights instead of falling back. Direct release byte/status checks
matched Rust for final path-only, final count, line-number-adjacent clusters,
prefixed output, no-match output, and quiet controls. On a generated
300,000-line fixture:

| Flags | Swift fallback | Swift preflight | rg |
|---|---:|---:|---:|
| `-cl needle` | 28.5 ms | 3.7 ms | 3.9 ms |
| `-lc needle` | 44.5 ms | 6.6 ms | 7.1 ms |
| `-Hcl needle` | 64.4 ms | 3.7 ms | 3.4 ms |
| `-Hlc needle` | 41.1 ms | 6.5 ms | 6.8 ms |

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
A later short-flag cleanup fixed the unclustered `-L` gap for the dense
vimgrep multi-literal preflight, including deferred `--no-config` ordering.
On `/tmp/swift-rg-candidates/countm-big.txt`, `-L --vimgrep --heading -e needle -e quiet`
improved from 5.112 s to 48.5 ms, versus 94.8 ms for Rust.

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

A later Swift-only cleanup moved single-literal quiet/path-only probes from
Foundation `Data.range` to the existing mapped byte scanner already used by the
negative path-only branch. Direct byte/status checks matched the previous Swift
binary and Rust for quiet, path-only, files-without-match, binary-prefix
fallback, and no-match forms. On `/tmp/swift-rg-candidates/trim.txt`, 80
no-shell runs measured `-q absent_literal` at 3.6 ms versus 5.1 ms before and
3.5 ms for Rust, while matching `-q needle` and `-l needle` stayed flat in the
2.7 ms band.

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

Those multi-literal quiet/path-only probes now share the same mapped byte
scanner too, removing the remaining per-literal `Data.range` no-match cost.
Direct byte/status checks matched the previous Swift binary and Rust for
top-level alternations, repeated `-e`, pattern files, fixed-string literals,
path separators, files-without-match, and binary-prefix fallback. On the 7 MiB
`trim.txt` fixture, 80 no-shell runs measured `-q 'absent|missing'` at 3.9 ms
versus 9.0 ms before and 4.4 ms for Rust; `-l 'absent|missing'` at 3.9 ms
versus 9.0 ms before and 3.9 ms for Rust; and matching `-q 'needle|tail'`
stayed flat at 2.8 ms.

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

The exact-line multi-literal matching writer now uses the same stdout buffer
and mapped-byte line scan shape as the adjacent exact-line field writers,
avoiding per-match `Data` output growth and `Data.Index` line walking while
preserving file-order output. Direct byte/status checks matched the previous
Swift binary and Rust for plain, numbered, byte-offset, bounded, repeated `-e`,
pattern-file, no-match, and final-line-without-newline forms. On a 4.6 MiB
dense fixture, plain `-x 'needle...|missing'` improved from 38.2 ms to
6.3 ms, versus 14.1 ms for Rust, and numbered output improved from 54.0 ms to
7.6 ms, versus 16.9 ms for Rust. On a 46 MiB dense fixture, plain output
improved from 341.2 ms to 29.4 ms, versus 111.1 ms for Rust; numbered output
improved from 483.8 ms to 44.2 ms, versus 138.0 ms for Rust; and no-match
alternation improved from 148.9 ms to 16.0 ms, versus 10.1 ms for Rust.

A follow-up no-match guard checks the mapped file for any exact-line literal
bytes before entering the line scanner. It returns status 1 immediately only
when none of the candidate bytes appear anywhere, so matching output stays on
the same writer. Direct byte/status checks matched the previous Swift binary
and Rust for plain, numbered, byte-offset, bounded, pattern-file, and no-match
forms. On the 46 MiB dense fixture, `-x -e absent -e missing` improved from
16.8 ms to 10.7 ms, versus 11.4 ms for Rust; matching output stayed flat at
29.0 ms.

Single-literal exact-line field output now uses the same stdout-buffer byte
scanner as plain exact-line output. It emits fields in Rust order (`line`,
`column`, `byte-offset`) when requested, treats `--column` as line-numbered
output, and preserves custom field separators, heading/prefixed output,
max-count, final no-newline matches, and no-match status. Direct release
byte/status checks matched Rust for those forms. On the matching
`/tmp/swift-rg-candidates/exact-needle.txt` fixture, current Swift measured
17.9 ms for `-n -x needle`, 15.4 ms for `-b -x needle`, and 22.0 ms for
`--vimgrep -x needle`, versus 34.5 ms, 33.8 ms, and 69.2 ms for Rust.

10 timed runs on `/tmp/swift-rg-candidates/countm-big.txt`:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-b -x needle` | 1.306 s | 3.5 ms | 9.3 ms |
| `--column -x needle` | 1.306 s | 3.5 ms | 9.4 ms |

Explicit `--encoding=none` and ASCII-safe UTF-8 exact-line field output share
that same single-literal field writer. Raw `none` field output uses byte offsets
directly, while UTF-8 validates an ASCII haystack first so the emitted
byte-offset and column fields remain Rust-compatible. Direct release
byte/status checks matched Rust for raw byte-offset, raw column, combined
fields, repeated `-e`, `-E utf8`, and a non-ASCII UTF-8 fallback control.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--encoding=none -b -x needle` | 1.935 s | 3.5 ms | 9.3 ms |
| `--encoding=utf-8 -b -x needle` | 1.338 s | 4.5 ms | 9.9 ms |

Single-literal numbered exact-line output now also uses the stdout-buffer field
writer instead of the candidate-substring line-number path. Direct release
byte/status checks matched Rust for numbered output, exact only-matching with
line numbers, headings, max-count, and encoded raw only-matching.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-n -x needle` | 1.305 s | 3.9 ms | 9.6 ms |

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

Raw `--encoding=none` exact-line only-matching now stays on the same exact-line
output preflight too. The raw unnumbered form can use the fast no-line-number
exact scanner, while numbered output shares the field writer above.
Direct release byte/status checks matched Rust for unnumbered, numbered,
repeated `-e`, max-count, UTF-8 ASCII, and non-ASCII UTF-8 fallback forms.

10 timed runs on `/tmp/swift-rg-candidates/countm-big.txt`:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--encoding=none -o -x needle` | 1.888 s | 7.7 ms | 9.4 ms |
| `--encoding=none -n -o -x needle` | 1.891 s | 3.5 ms | 9.4 ms |

Raw `--encoding=none` exact-line matching output now also keeps the normal
line-output forms on the exact-line preflight. The unnumbered and bounded forms
can use the fast no-line-number scanner, while numbered output shares the
field writer. Direct release byte/status checks matched Rust for plain,
numbered, max-count, repeated `-e`, ASCII UTF-8, and non-ASCII UTF-8 fallback
forms.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--encoding=none -x needle` | 1.897 s | 7.5 ms | 9.3 ms |
| `--encoding=none -n -x needle` | 1.920 s | 4.0 ms | 9.9 ms |
| `--encoding=none -m1 -x needle` | 1.903 s | 7.6 ms | 9.3 ms |

Raw `--encoding=none` and ASCII-safe UTF-8 case-insensitive exact-line
matching output now keep the same folded exact-line writer. This covers normal,
numbered, only-matching, repeated `-e`, and ASCII UTF-8 forms, while the
existing non-ASCII UTF-8 fallback guard still preserves Unicode case-folding.
Direct release byte/status checks matched Rust for those forms.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--encoding=none -i -x "NEEDLE NEEDLE QUIET TAIL"` | 5.972 s | 8.7 ms | 23.5 ms |
| `--encoding=none -n -i -x "NEEDLE NEEDLE QUIET TAIL"` | 6.234 s | 13.8 ms | 34.4 ms |

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
folded byte-search writer for single literals on ASCII-only data. It emits the
original line bytes while comparing folded bytes, covers line numbers, headings,
`-o`, max-count, explicit raw/UTF-8 encoding, and final no-newline matches, and
falls back for CRLF, binary, non-ASCII, multi-literal, quiet/path-only, and
count forms. Direct byte/status checks matched Rust for plain, numbered,
only-matching, bounded, prefixed, heading, repeated `-e`, pattern-file, CRLF
fallback, binary fallback, and Unicode fallback forms. On the 7.5 MiB dense
fixture, `-i -x 'NEEDLE NEEDLE QUIET TAIL'` measured 8.6 ms, versus 23.7 ms for
Rust, while `-n -i -x ...` measured 13.9 ms, versus 35.9 ms for Rust.
Multi-literal alternation remains on the folded line scanner.

Case-insensitive exact-line vimgrep output now has the same folded exact-line
scanner for ASCII haystacks. It preserves line, column, byte-offset, max-count,
and repeated `-e` field layouts while keeping Unicode fallback behavior on the
full searcher. Direct release byte/status checks matched Rust for those forms.
On `/tmp/swift-rg-candidates/countm-big.txt`, 10 timed runs of
`-i --vimgrep -x 'NEEDLE NEEDLE QUIET TAIL'` improved from 5.123 s to
142.2 ms, versus 64.7 ms for Rust.

Explicit `--encoding=none` and ASCII-safe UTF-8 case-insensitive exact-line
vimgrep now share that folded writer instead of falling back. The raw mode can
emit original bytes after the existing ASCII guard, while UTF-8 first proves the
haystack is ASCII so Unicode case-folding remains on the full searcher. Direct
byte/status checks matched Rust for raw, byte-offset raw, UTF-8, `-E utf8`,
Unicode fallback, and invalid raw-byte fallback forms. On the same fixture,
10 timed runs of `--encoding=none -i --vimgrep -x 'NEEDLE NEEDLE QUIET TAIL'`
improved from 6.225 s to 141.4 ms, versus 70.3 ms for Rust; the
`--encoding=utf-8` form improved from 5.171 s to 143.7 ms, versus 65.6 ms for
Rust.

Single-literal case-insensitive exact-line vimgrep now routes through the
existing folded stdout-buffer field writer instead of the older `Data` line
writer. Direct byte/status checks matched the previous Swift binary and Rust for
plain, raw, UTF-8, short encoding, byte-offset, bounded, no-match, repeated
`-e`, and final-line-without-newline forms. On
`/tmp/swift-rg-candidates/countm-big.txt`, 25-run checks measured
`-i --vimgrep -x 'NEEDLE NEEDLE QUIET TAIL'` at 17.0 ms versus 143.0 ms before
and 66.3 ms for Rust; `--encoding=none` at 17.0 ms versus 142.6 ms before and
65.6 ms for Rust; `--encoding=utf-8` at 17.9 ms versus 143.8 ms before and
67.2 ms for Rust; and the no-match form at 4.6 ms versus 28.5 ms before and
4.7 ms for Rust.

Multi-literal case-insensitive exact-line vimgrep now uses the same buffered
mapped-byte writer after the one-literal fast branch. Direct byte/status checks
matched the previous Swift binary and Rust for plain, raw, UTF-8, byte-offset,
no-column, no-line-number, custom field separators, no-filename output, bounded,
repeated `-e`, pattern-file, no-match, and final-line-without-newline forms. On
the same fixture, 25-run checks measured
`-i --vimgrep -x 'NEEDLE NEEDLE QUIET TAIL|MISSING LINE'` at 17.4 ms versus
141.9 ms before and 66.8 ms for Rust; `--encoding=none` at 17.3 ms versus
142.3 ms before and 66.0 ms for Rust; `--encoding=utf-8` at 18.3 ms versus
143.3 ms before and 66.8 ms for Rust; and the no-match alternation at 6.1 ms
versus 29.2 ms before and 4.9 ms for Rust.

Case-insensitive multi-literal exact-line no-match forms now first check the
mapped file for any folded candidate bytes. A false result returns status 1
only after the existing ASCII safety guard, so Unicode fallback behavior is
unchanged. Direct byte/status checks matched the previous Swift binary and Rust
for repeated `-e`, pattern-file, quiet/path-only, `--include-zero`, bounded
output, and vimgrep field variants. On the 46 MiB exact-line fixture,
`-i -x -e absent -e missing` improved from 15.0 ms to 12.1 ms, versus 9.9 ms
for Rust; matching output stayed flat at 45.6 ms versus 45.3 ms before and
115.7 ms for Rust. On `/tmp/swift-rg-candidates/countm-big.txt`,
`-i --vimgrep -x -e absent -e missing` improved from 5.3 ms to 4.3 ms, matching
Rust at 4.3 ms.

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
Active `--stop-on-nonmatch` matching-line, count, quiet, and path-only forms
now use executable preflights for literal searches. Matching-line and count
output find the first matching line, then scan only the consecutive matching
run until the first non-match, preserving line numbers, `-m`, prefixed counts,
`--include-zero`, and no-final-newline output. The executable preflight also
accepts ordered reset forms where a later `-U` or `--multiline` makes line
output equivalent to normal literal matching. Focused coverage keeps
`-U --stop-on-nonmatch` on the fallback by checking its truncated output, while
direct release byte checks matched Rust for reset line-output, active quiet,
active path-only, active count fallback, and active matching-line fallback
controls. On a 50 KiB dense fixture, `--stop-on-nonmatch -U needle` improved
from 62.8 ms to 4.7 ms, versus 4.4 ms for Rust. Active
`--stop-on-nonmatch -q needle` improved from 49.6 ms to 3.4 ms, versus 3.1 ms
for Rust, and `--stop-on-nonmatch -l needle` improved from 44.2 ms to 4.3 ms,
versus 3.0 ms for Rust. A current 48 MiB quiet reset check measured
`--stop-on-nonmatch -qU needle` at 3.7 ms, versus 3.2 ms for Rust.

The active matching-line stop-on-nonmatch check used
`/tmp/swift-rg-bench/stop-on-nonmatch-line-small.txt`, a 5.10 MiB fixture whose
first matching run ends near the start of the file, with 3 warmups and 10 timed
runs. The before column is the same binary with the executable preflight
bypassed via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--stop-on-nonmatch match` | 187.2 ms | 5.0 ms | 3.0 ms |
| `-n --stop-on-nonmatch match` | n/a | 4.2 ms | 2.7 ms |
| `-c --stop-on-nonmatch match` | 190.5 ms | 5.0 ms | 3.2 ms |
| `-H -c --stop-on-nonmatch match` | n/a | 4.3 ms | 3.1 ms |

The literal trim check used `/tmp/swift-rg-candidates/trim.txt`, a 250,000-line
fixture with leading spaces before every match. The before column is the
pre-route Swift fallback from a 7-run probe; after and Rust used 3 warmups and
10 timed runs with `RIPGREP_CONFIG_PATH` unset so the executable preflight was
eligible:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--trim needle` | 376.5 ms | 13.8 ms | 15.4 ms |
| `-n --trim needle` | 416.8 ms | 20.8 ms | 24.6 ms |

Output-neutral trim checks used the same fixture and 3 warmups plus 10 timed
runs. The before column is the same binary with executable preflight bypassed
via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--trim -q needle` | 176.9 ms | 4.3 ms | 3.4 ms |
| `--trim -l needle` | 91.0 ms | 4.8 ms | 3.8 ms |
| `--trim -c needle` | 118.1 ms | 10.1 ms | 10.4 ms |
| `--trim --count-matches needle` | 117.5 ms | 6.9 ms | 19.2 ms |

Output-neutral null-data checks used the same fixture and 3 warmups plus 10
timed runs:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--null-data -q needle` | 407.3 ms | 4.7 ms | 5.6 ms |
| `--null-data -l needle` | 410.0 ms | 4.7 ms | 5.8 ms |
| `--null-data --count-matches needle` | 407.2 ms | 7.4 ms | 9.0 ms |

Output-neutral nonzero max-columns checks used the same fixture and 3 warmups
plus 10 timed runs:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-M1 -q needle` | 1.544 s | 5.5 ms | 4.1 ms |
| `-M1 -l needle` | 1.562 s | 6.1 ms | 4.0 ms |
| `-M1 -c needle` | 1.557 s | 11.5 ms | 11.5 ms |
| `-M1 --count-matches needle` | 1.563 s | 8.3 ms | 20.0 ms |

Output-neutral replacement checks used the same fixture and 3 warmups plus 10
timed runs. The before column is the same binary with executable preflight
bypassed via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--replace X -q needle` | 30.1 ms | 5.6 ms | 4.7 ms |
| `--replace=X -l needle` | 1.569 s | 6.1 ms | 4.8 ms |
| `-rX -c needle` | 1.596 s | 11.6 ms | 12.0 ms |
| `--replace X --count-matches needle` | 1.603 s | 8.7 ms | 20.7 ms |

Output-neutral passthru checks used the same fixture and 3 warmups plus 10 timed
runs. The before column is the same binary with executable preflight bypassed
via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--passthru -q needle` | 1.542 s | 6.5 ms | 5.3 ms |
| `--passthru -l needle` | 1.554 s | 6.8 ms | 5.1 ms |
| `--passthru -c needle` | 1.558 s | 11.8 ms | 10.5 ms |
| `--passthru --count-matches needle` | 1.559 s | 8.6 ms | 19.4 ms |

The multi-literal trim check used the same fixture and 3 warmups plus 10 timed
runs. The before column is the same binary with executable preflight bypassed
via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--trim -e needle -e absent` | 401.8 ms | 13.5 ms | 15.9 ms |
| `--trim "needle|absent"` | 408.0 ms | 12.9 ms | 15.1 ms |

The literal invert check used `/tmp/swift-rg-candidates/invert.txt`, a
250,000-line / 6.19 MiB fixture with every tenth line containing the rejected
literal. The before column is the pre-route Swift fallback from a 7-run probe;
after and Rust used 3 warmups and 10 timed runs with `RIPGREP_CONFIG_PATH`
unset:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-v needle` | 927.2 ms | 10.3 ms | 11.1 ms |
| `-n -v needle` | 970.6 ms | 12.4 ms | 17.3 ms |

The multi-literal invert check used the same fixture and 3 warmups plus 10
timed runs. The before column is the same binary with executable preflight
bypassed via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-v -e needle -e absent` | 1.302 s | 13.3 ms | 10.6 ms |
| `-v "needle|absent"` | 1.447 s | 13.0 ms | 10.3 ms |

ASCII ignore-case trim/invert checks used the same fixtures with uppercase
`NEEDLE` as the query. The before column is the same binary with executable
preflight bypassed via `RIPGREP_CONFIG_PATH=`; current and Rust used 3 warmups
and 10 timed runs:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--trim -i NEEDLE` | 436.8 ms | 11.2 ms | 19.4 ms |
| `-v -i NEEDLE` | 3.609 s | 8.8 ms | 10.1 ms |

ASCII ignore-case multi-literal trim checks used the same trim fixture and 3
warmups plus 10 timed runs:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--trim -i -e NEEDLE -e ABSENT` | 396.6 ms | 10.7 ms | 21.3 ms |
| `--trim -i "NEEDLE|ABSENT"` | 397.9 ms | 10.8 ms | 20.7 ms |

ASCII ignore-case multi-literal invert checks used the same fixture and 3
warmups plus 10 timed runs:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-v -i -e NEEDLE -e ABSENT` | 6.648 s | 13.8 ms | 11.5 ms |
| `-v -i "NEEDLE|ABSENT"` | 6.815 s | 13.5 ms | 10.8 ms |

The literal passthru check used `/tmp/swift-rg-candidates/passthru-50k.txt`, a
50,000-line / 1.29 MiB fixture with every tenth line matching. The before
column is the same binary with the executable preflight bypassed via
`RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--passthru needle` | 1.523 s | 9.3 ms | 8.9 ms |

A larger current/Rust check on `/tmp/swift-rg-candidates/passthru.txt`, a
250,000-line / 6.66 MiB fixture, used 3 warmups and 10 timed runs:

| Flags | Swift | rg |
|---|---:|---:|
| `--passthru needle` | 12.6 ms | 16.2 ms |
| `-n --passthru needle` | 16.1 ms | 25.3 ms |

The explicit multi-literal passthru check used
`/tmp/swift-rg-candidates/passthru-multi-50k.txt`, a 50,000-line / 823 KiB
fixture with `needle` every tenth line and `alpha` every fifteenth line. The
before column is the same binary with executable preflight bypassed via
`RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--passthru -e needle -e alpha` | 1.500 s | 8.7 ms | 8.8 ms |

A larger current/Rust check on
`/tmp/swift-rg-candidates/passthru-multi-250k.txt`, a 250,000-line / 4.20 MiB
fixture, used 3 warmups and 10 timed runs:

| Flags | Swift | rg |
|---|---:|---:|
| `--passthru -e needle -e alpha` | 13.0 ms | 16.6 ms |
| `-n --passthru -e needle -e alpha` | 15.1 ms | 23.0 ms |

The equivalent top-level alternation check used the same fixtures and measured:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--passthru "needle|alpha"` | 1.490 s | 8.8 ms | 8.5 ms |

The larger current/Rust alternation check used 3 warmups and 10 timed runs:

| Flags | Swift | rg |
|---|---:|---:|
| `--passthru "needle|alpha"` | 12.8 ms | 16.7 ms |
| `-n --passthru "needle|alpha"` | 15.5 ms | 24.1 ms |

The ASCII ignore-case passthru check used
`/tmp/swift-rg-candidates/context-after-250k.txt`, the same 250,000-line /
4.21 MiB context fixture, with uppercase `NEEDLE` as the query. Pre-route
3-run probes measured the same Swift fallback at 36.490 s for the single
literal and 36.346 s for the repeated `-e` form; after and Rust used 3
warmups and 10 timed runs:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `--passthru -i NEEDLE` | 36.490 s | 9.6 ms | 15.5 ms |
| `--passthru -i -e NEEDLE -e ABSENT` | 36.346 s | 11.0 ms | 16.5 ms |
| `--passthru -i "NEEDLE|ABSENT"` | n/a | 12.6 ms | 17.0 ms |

The literal after-context check used
`/tmp/swift-rg-candidates/context-after-250k.txt`, a 250,000-line / 4.21 MiB
fixture with every tenth line matching. The before column is the same binary
with executable preflight bypassed via `RIPGREP_CONFIG_PATH=`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-A 1 needle` | 7.469 s | 10.9 ms | 8.5 ms |

Additional current/Rust checks used 3 warmups and 10 timed runs:

| Flags | Swift | rg |
|---|---:|---:|
| `-n -A 1 needle` | 11.1 ms | 9.8 ms |
| `--no-context-separator -A 1 needle` | 9.8 ms | 7.7 ms |

The before-context form used the same fixture:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-B 1 needle` | 7.094 s | 11.0 ms | 8.4 ms |

Additional current/Rust checks used 3 warmups and 10 timed runs:

| Flags | Swift | rg |
|---|---:|---:|
| `-n -B 1 needle` | 11.1 ms | 9.8 ms |
| `--no-context-separator -B 1 needle` | 9.6 ms | 6.8 ms |

The combined-context form used the same fixture:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-C 1 needle` | 10.691 s | 9.5 ms | 7.2 ms |

Additional current/Rust checks used 3 warmups and 10 timed runs:

| Flags | Swift | rg |
|---|---:|---:|
| `-n -C 1 needle` | 10.0 ms | 8.9 ms |
| `--no-context-separator -C 1 needle` | 8.8 ms | 6.4 ms |

The ASCII ignore-case context checks used the same fixture with uppercase
`NEEDLE` as the query:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-i -A 1 NEEDLE` | 7.920 s | 9.2 ms | 7.1 ms |
| `-i -B 1 NEEDLE` | 7.896 s | 9.4 ms | 7.0 ms |
| `-i -C 1 NEEDLE` | 11.281 s | 9.4 ms | 7.0 ms |

The multi-literal context checks used the same fixture with `needle` plus a
missing second literal:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-A 1 -e needle -e absent` | 7.348 s | 10.2 ms | 6.7 ms |
| `-B 1 -e needle -e absent` | 7.384 s | 10.7 ms | 7.1 ms |
| `-C 1 -e needle -e absent` | 11.025 s | 11.1 ms | 7.1 ms |
| `-C 1 'needle|absent'` | 11.025 s | 10.2 ms | 7.0 ms |

The ASCII ignore-case multi-literal context checks used the same fixture with
uppercase `NEEDLE`/`ABSENT`:

| Flags | Swift before | Swift after | rg |
|---|---:|---:|---:|
| `-i -A 1 -e NEEDLE -e ABSENT` | 8.576 s | 11.3 ms | 8.5 ms |
| `-i -B 1 -e NEEDLE -e ABSENT` | 8.566 s | 11.6 ms | 8.2 ms |
| `-i -C 1 -e NEEDLE -e ABSENT` | 12.278 s | 11.5 ms | 8.7 ms |
| `-i -C 1 'NEEDLE|ABSENT'` | 12.278 s | 11.3 ms | 8.9 ms |

Null path terminator flags now stay on the executable literal preflight when
the command shape cannot print a path. This covers standalone `--null` and
`-0`, and a follow-up accepts Rust-compatible `0` inside short clusters in both
the executable preflight and the main Swift option parser. Focused executable
coverage checked matching-line, line-number, path-only, count, quiet, and
binary-fallback forms, and direct release byte checks matched Rust on small,
large, and binary representatives. On a generated 4.8 MiB text fixture,
single-run before probes measured `--null Sherlock` at about 0.82 s and
`-0 Sherlock` at about 0.85 s. Seven-run current checks on the same fixture
shape measured 8.3 ms and 8.4 ms respectively, in line with the plain Swift
preflight at 8.6 ms and Rust `--null Sherlock` at 9.0 ms.

Clustered `-0` checks used a generated 300,000-line fixture after the parser
fix, with the fallback column forcing the generic Swift path through
`RIPGREP_CONFIG_PATH=`:

| Flags | Swift fallback | Swift preflight | rg |
|---|---:|---:|---:|
| `-0n needle` | 229.7 ms | 12.4 ms | 12.7 ms |
| `-0Hc needle` | 84.6 ms | 7.1 ms | 7.4 ms |
| `-0l needle` | 64.3 ms | 4.5 ms | 3.8 ms |
| `-0q needle` | 99.2 ms | 4.3 ms | 3.8 ms |

Clustered hidden flags now share that parser treatment. The executable
preflight accepts `.` inside short clusters for explicit-file forms where
hidden matching is output-neutral, while the main Swift parser applies the
same hidden toggle for fallback-only cases. Direct release byte/status checks
matched Rust for `-.n`, `-n.`, `-.q`, `-.c`, `-.l`, `-.Hc`, a visible file
control, and a binary fallback control. The same generated 300,000-line fixture
measured:

| Flags | Swift fallback | Swift preflight | rg |
|---|---:|---:|---:|
| `-.n needle` | 40.8 ms | 12.1 ms | 11.7 ms |
| `-.c needle` | 25.9 ms | 6.6 ms | 7.2 ms |
| `-.l needle` | 30.5 ms | 3.9 ms | 3.8 ms |
| `-.q needle` | 32.9 ms | 4.4 ms | 4.0 ms |

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

Plain literal `--vimgrep` full-line output now also stays on the executable
preflight for explicit repeated `-e`, single-literal, top-level alternation,
and ASCII ignore-case forms. The writer emits full source-line bytes once per
match with Rust-compatible path, line, column, optional byte-offset,
`--no-filename`, `-N`, and `--no-column` field layouts, while word-boundary,
replacement, context, trim, invert, max-column, and non-ASCII ignore-case
haystacks continue to fall back. Direct byte/status checks matched Rust for
repeated literals, byte offsets, no-filename, single literal, alternation,
bounded `-m`, `-N`, `--no-column`, no-field vimgrep, and Unicode fallback
fixtures.

10 timed runs on `/tmp/swift-rg-candidates/countm-big.txt` with 3 warmups:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--vimgrep -e needle -e quiet` | 198.0 ms | 47.8 ms | 90.9 ms |
| `--vimgrep -i -e NEEDLE -e QUIET` | 10.106 s | 50.0 ms | 124.3 ms |
| `--vimgrep -m100000 -e needle -e quiet` | 92.9 ms | 19.0 ms | 32.7 ms |

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

A follow-up keeps that dry line-scan path Swift-first but avoids the earlier
full-file NUL probe when the prefix scan itself proves the requested bounded
lines. The fast route still rejects NUL bytes in the first 64 KiB or in any
scanned output line before writing, leaving the slower retained routes
conservative. Direct byte/status checks matched sibling Rust `rg` for `-m128`,
`-n -m128`, `-m1024`, `-n -m1024`, an early-NUL fallback, and a late-NUL
after-bound case. On `/tmp/swift-rg-bench/multi-literal-synth.txt`, a 252 MiB
synthetic dense 40-literal fixture, 20-run checks measured Swift `-m128` at
4.2 ms versus 4.6 ms for Rust and Swift `-n -m128` at 3.7 ms versus 4.6 ms for
Rust. The same local reproduction measured the pre-follow-up Swift build at
23.3 ms for plain `-m128` and 25.2 ms for `-n -m128`.

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

Dense ASCII-compatible surrounding-word output now streams from the executable
preflight instead of falling through after the 16,384 buffered-line cutoff. The
ASCII-scoped form streams immediately, while default Unicode streams only after
that cutoff and a whole-file ASCII proof so Unicode fallback semantics stay
unchanged. A 4,000,000-line, 264 MiB synthetic `Holmes` corpus matched Rust
byte-for-byte for both Unicode-default and `(?-u)` forms. Ten-run A/B checks
measured default Unicode at 322.7 ms versus 5.904 s before and 496.0 ms for
Rust; the ASCII-scoped form measured 237.4 ms versus 5.897 s before. A sparse
252 MiB rejection-heavy fixture also matched Rust byte-for-byte and measured
default Unicode at 67.9 ms versus 148.0 ms before and 194.3 ms for Rust, with
the ASCII-scoped form at 67.0 ms versus 127.7 ms before.
Plain dense output now skips newline counting inside the same streaming route:
the ASCII-scoped form measured 160.9 ms versus 5.225 s before and 310.0 ms for
Rust, while default Unicode measured 252.9 ms.

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

Bounded single-literal count-matches now keeps the executable Swift preflight
when `--max-count` limits the number of matching lines. `-o -c -mN` uses the
same count-matches semantics, matching Rust's "matches within the first N
matching lines" output. A follow-up made the bounded counter single-pass,
counting matches while tracking selected matching lines instead of copying and
rescanning the selected prefix. Direct release comparisons were byte-identical
for unprefixed, `-H` prefixed, `--include-zero`, and only-matching count forms.

10 timed runs on `/tmp/swift-rg-candidates/countm-big.txt`, a 7.5 MiB dense
literal fixture with 300,000 lines:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--count-matches -m100000 needle` | 1.56 s | 5.4 ms | 8.1 ms |

The tiny bound control `--count-matches -m2 needle` measured 2.9 ms versus
2.3 ms for Rust, while the unbounded Swift count path stayed in its existing
fast band at 6.9 ms.

Bounded ASCII ignore-case count-matches now uses the same executable preflight
shape for `-i --count-matches -mN`, while keeping non-ASCII haystacks and
literals on the existing fallback. Direct release comparisons were
byte-identical for unprefixed, `-H` prefixed, `--include-zero`, only-matching
count, and Unicode fallback forms.

10 timed runs on the same 7.5 MiB dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--count-matches -i -m100000 NEEDLE` | 3.312 s | 18.4 ms | 21.1 ms |

Bounded ASCII word count-matches now stays on the executable preflight for
`-w --count-matches -mN` and counts matches while selecting the first N matching
lines, instead of copying and rescanning the selected prefix. Unicode-adjacent
word-boundary cases still fall back. Direct release comparisons were
byte-identical for unprefixed, `-H` prefixed, `--include-zero`, only-matching
count, and Unicode-boundary fallback forms.

10 timed runs on the same 7.5 MiB dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--count-matches -w -m100000 needle` | 1.958 s | 5.0 ms | 16.4 ms |

The tiny word-bound control `--count-matches -w -m2 needle` measured 2.7 ms
versus 3.7 ms for Rust.

Bounded ASCII ignore-case word count-matches now also shares the one-pass
selection/counting path for `-w -i --count-matches -mN`, while preserving
Unicode-boundary fallback behavior. Direct release comparisons were
byte-identical for unprefixed, `-H` prefixed, `--include-zero`, only-matching
count, and Unicode-boundary fallback forms.

10 timed runs on the same 7.5 MiB dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--count-matches -w -i -m100000 NEEDLE` | 4.951 s | 5.6 ms | 22.7 ms |

Bounded non-overlapping multi-literal count-matches now uses the executable
preflight for repeated `-e`, pattern-file, and top-level alternation forms with
`--count-matches -mN`. A follow-up made the bounded multi-literal counter
select matching lines with per-literal candidates and then count the selected
prefix without copying it. Direct release comparisons were byte-identical for
unprefixed, `-H` prefixed, `--include-zero`, only-matching count, pattern-file,
and alternation forms.

10 timed runs on the same 7.5 MiB dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--count-matches -m100000 -e needle -e quiet` | 2.233 s | 9.3 ms | 13.3 ms |

The tiny bound control `--count-matches -m2 -e needle -e quiet` measured
2.8 ms versus 2.4 ms for Rust.

Bounded multi-literal word count-matches now also counts while selecting the
first N matching lines for repeated `-e`, pattern-file, and top-level
alternation forms with `-w --count-matches -mN`, including the ASCII
ignore-case variant. It keeps per-literal candidates in file order and falls
back on Unicode-adjacent word-boundary ambiguity. Direct release comparisons
were byte-identical for unprefixed, `-H` prefixed, `--include-zero`,
only-matching count, pattern-file, alternation, ignore-case, and Unicode
fallback forms.

10 timed runs on the same 7.5 MiB dense literal fixture, except the
preflight-bypassed `-w -i` probe used 3 timed runs:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--count-matches -w -m100000 -e needle -e quiet` | 2.761 s | 8.7 ms | 22.7 ms |
| `--count-matches -w -i -m100000 -e NEEDLE -e QUIET` | 6.545 s | 8.9 ms | 28.2 ms |

Bounded only-matching output now stays on the executable preflight for
single-literal, ASCII ignore-case, ASCII ignore-case word, and multi-literal
forms. The writer stops after the first N matching lines while still emitting
all matches from the final selected line. Direct release comparisons were
byte-identical for line-numbered, filename-prefixed, heading, ignore-case,
word ignore-case, alternation, no-match, and `-m0` forms.

10 timed runs on `/tmp/swift-rg-candidates/countm-big.txt`:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-o -m100000 needle` | 1.656 s | 10.4 ms | 14.5 ms |

Case-sensitive word only-matching output now has the same executable Swift
preflight shape as ASCII ignore-case word output. It remains conservative and
falls back for non-ASCII haystacks so Unicode word-boundary semantics stay on
the existing matcher. Direct release comparisons were byte-identical for plain,
bounded line-numbered, filename-prefixed, no-match, and Unicode-adjacent
fallback forms.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-w -o needle` | 2.995 s | 18.1 ms | 58.6 ms |

Multi-literal word only-matching output now uses the same conservative
ASCII-boundary executable preflight for repeated `-e` and top-level
alternation forms, including ASCII ignore-case. It emits original haystack bytes
for matched text, preserves line numbers and filename prefixes, respects
`-mN` as matching-line bounded output, and falls back for non-ASCII haystacks.
Direct release comparisons against Rust were byte-identical for repeated `-e`,
line-numbered, filename-prefixed, ignore-case, alternation, no-match, and
Unicode-adjacent fallback forms.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-w -o -e needle -e quiet` | 4.093 s | 26.7 ms | 79.7 ms |
| `-w -i -o -e NEEDLE -e QUIET` | 9.236 s | 27.1 ms | 89.2 ms |

Visible field prefixes for word only-matching output now stay on that same
preflight. The writer emits fields in Rust order (`line`, `column`,
`byte-offset`) after any path prefix, treats `--column` as line-numbered
output, and keeps the ASCII haystack guard so column math is byte-column
compatible. Direct release comparisons were byte-identical for byte-offset,
column, combined fields, filename-prefixed fields, ignore-case fields,
alternation fields, a single-literal control, and Unicode-adjacent fallback
forms.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-w -b -o -e needle -e quiet` | 4.217 s | 36.9 ms | 96.1 ms |
| `-w --column -o -e needle -e quiet` | 4.286 s | 46.0 ms | 108.9 ms |

Word only-matching vimgrep output now also uses the field-prefix preflight for
the visible `--vimgrep -o` shape. Direct release comparisons were
byte-identical for repeated `-e`, byte-offset, `--no-filename`, ignore-case,
alternation, single-literal, and Unicode-adjacent fallback forms.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--vimgrep -w -o -e needle -e quiet` | 5.679 s | 49.9 ms | 126.6 ms |

Word full-line vimgrep output now shares that same ASCII-boundary executable
preflight for repeated `-e`, top-level alternation, single-literal, and ASCII
ignore-case forms. It emits the full source line once per accepted word match
with Rust-compatible path, line, column, optional byte-offset, `--no-filename`,
`-N`, and `--no-column` layouts, while non-ASCII haystacks and unsupported
vimgrep shapes continue to fall back. Direct release comparisons were
byte-identical for repeated literals, byte offsets, no-filename, single literal,
alternation, bounded `-m`, `-N`, `--no-column`, no-field vimgrep, ignore-case,
and Unicode fallback fixtures.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--vimgrep -w -e needle -e quiet` | 5.762 s | 50.7 ms | 127.3 ms |
| `--vimgrep -w -i -e NEEDLE -e QUIET` | 10.668 s | 50.8 ms | 136.9 ms |
| `--vimgrep -w -m100000 -e needle -e quiet` | 3.146 s | 20.7 ms | 44.7 ms |

Explicit `--encoding=none` and ASCII-safe UTF-8 word vimgrep now keep that
same full-line word writer instead of falling back. The writer still rejects
non-ASCII haystacks, so Unicode word-boundary behavior remains on the full
searcher. Direct byte/status checks matched Rust for raw, raw ignore-case,
UTF-8, UTF-8 ignore-case, and Unicode fallback forms. Three-run probes on
`/tmp/swift-rg-candidates/countm-big.txt` measured
`--encoding=none --vimgrep -w -e needle -e quiet` improving from 8.548 s to
55.1 ms, versus 141.6 ms for Rust;
`--encoding=none -i --vimgrep -w -e NEEDLE -e QUIET` from 13.470 s to
53.1 ms, versus 150.3 ms for Rust; and the matching `--encoding=utf-8 -i`
form from 11.448 s to 54.4 ms, versus 152.9 ms for Rust.

Encoded word only-matching vimgrep now also uses that existing conservative
word-only writer. This keeps raw and ASCII-safe UTF-8 `--vimgrep -w -o` on the
Swift executable preflight while preserving fallback for non-ASCII
word-boundary cases. Direct release byte/status checks matched Rust for raw,
UTF-8 ignore-case, and Unicode fallback forms. Five-run probes on
`/tmp/swift-rg-candidates/countm-big.txt` measured
`--encoding=none --vimgrep -w -o -e needle -e quiet` improving from 7.856 s to
51.2 ms, versus 127.3 ms for Rust; and
`--encoding=utf-8 -i --vimgrep -w -o -e NEEDLE -e QUIET` from 11.139 s to
49.7 ms, versus 138.3 ms for Rust.

The same encoded word only-matching eligibility now covers non-vimgrep `-w -o`
output. Direct release byte/status checks matched Rust for raw, UTF-8
ignore-case, and Unicode fallback forms. Five-run probes on
`/tmp/swift-rg-candidates/countm-big.txt` measured
`--encoding=none -w -o -e needle -e quiet` improving from 6.194 s to
27.9 ms, versus 78.2 ms for Rust; and
`--encoding=utf-8 -i -w -o -e NEEDLE -e QUIET` at 26.6 ms, versus 90.1 ms for
Rust.

ASCII word line output now tries the existing streaming literal-line writer with
ASCII word-boundary checks before falling back to the conservative Unicode-aware
word writer. This removes the dense-output buffering cliff for plain and encoded
single-literal word line output while keeping non-ASCII haystacks on fallback.
Direct release byte/status checks matched Rust for raw, UTF-8 ignore-case, and
invalid UTF-8 fallback forms. Five-run probes on
`/tmp/swift-rg-candidates/countm-big.txt` measured `-w needle` improving from
1.337 s to 16.9 ms, versus 18.6 ms for Rust;
`--encoding=none -w needle` improving from 4.150 s to 14.6 ms; and
`--encoding=utf-8 -w needle` improving from 2.691 s to 15.5 ms. The
case-insensitive encoded forms measured 14.1 ms for raw and 15.5 ms for UTF-8,
versus 29.3 ms for Rust.

Encoded multi-literal word line output now has a dedicated ASCII-only mapped
writer instead of falling through the full encoding path. It scans all
candidate literals, emits each matching line once in file order, preserves line
number/max-count/heading prefixes, and falls back for non-ASCII, binary, or
ambiguous boundary cases. Direct release byte/status checks matched Rust for
raw, UTF-8, UTF-8 ignore-case, line-number, max-count, and Unicode fallback
forms.

10 timed runs on `/tmp/swift-rg-candidates/countm-big.txt`:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--encoding=none -w -e needle -e quiet` | 5.286 s | 31.3 ms | 22.6 ms |
| `--encoding=utf-8 -w -e needle -e quiet` | 3.800 s | 32.0 ms | 23.6 ms |
| `--encoding=utf-8 -i -w -e NEEDLE -e QUIET` | n/a | 32.3 ms | 30.9 ms |

The simple unnumbered multi-literal word writer now coalesces contiguous
matching output lines into larger stdout-buffer writes instead of taking the
full prefix/write path once per line. Sparse output and no-final-newline
fixtures still matched Rust byte-for-byte. On the same dense fixture, 10-run
checks measured `--encoding=none -w -e needle -e quiet` at 7.3 ms versus
24.2 ms for Rust, and `--encoding=utf-8 -w -e needle -e quiet` at 8.3 ms
versus 24.6 ms for Rust.

Dense multi-literal word line output now checks for a word-literal match at the
current line start before probing every literal through the rest of the file.
That shortcut preserves file-order output and helps repeated dense lines where
the earliest selected match is at the line boundary. A follow-up adds a bounded
max-count writer for unprefixed case-sensitive output; it collects candidate
line ranges before writing, so Unicode/binary fallbacks still happen before any
stdout bytes are emitted. Direct checks matched Rust for raw, UTF-8, UTF-8
ignore-case, line-numbered, bounded max-count, alternation, no-final-newline,
no-match, and Unicode fallback forms. A 20-run bounded control on
`/tmp/swift-rg-candidates/countm-big.txt` measured
`--encoding=none -m2 -w -e needle -e quiet` at 4.3 ms versus 2.6 ms for Rust,
and the UTF-8 form at 4.2 ms versus 2.3 ms for Rust.

Exact line-regexp vimgrep output now uses the single-literal stdout-buffer field
writer for case-sensitive literal `-x`/`--line-regexp` searches. It preserves
vimgrep line, column, byte-offset, max-count, filename-prefix, and
repeated-pattern layouts while keeping ignore-case, CRLF, null-data, color,
trim, stats, and other observable modes on the fallback path. Direct release
byte/status checks matched Rust for matching, repeated `-e`, byte-offset,
no-match, and deferred `--no-config` forms.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--vimgrep -x needle` | 1.303 s | 3.5 ms | 11.9 ms |

Explicit `--encoding=none` and ASCII-safe UTF-8 exact-line vimgrep now share
that route. `none` can write raw bytes directly, while UTF-8 first proves the
haystack is ASCII so line bytes and vimgrep column `1` remain byte-compatible.
Direct release byte/status checks matched Rust for `--encoding=utf-8`,
`-E utf8`, `--encoding=none`, repeated `-e`, and a non-ASCII UTF-8 fallback
control.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--encoding=utf-8 --vimgrep -x needle` | 1.317 s | 4.5 ms | 13.4 ms |
| `--encoding=none --vimgrep -x needle` | 1.899 s | 4.3 ms | 10.0 ms |

Case-sensitive exact-line vimgrep for repeated `-e` and pattern-file literals
now uses the same stdout-buffer mapped-byte writer as matching-line output
instead of the older `Data` line writer. Direct byte/status checks matched the
previous Swift binary and Rust for repeated `-e`, raw, UTF-8, byte-offset,
no-column, no-line-number, custom field separators, no-filename output, bounded,
pattern-file, no-match, and final-line-without-newline forms. On
`/tmp/swift-rg-candidates/countm-big.txt`, 25-run checks measured
`--vimgrep -x -e 'needle needle quiet tail' -e 'missing line'` at 15.2 ms
versus 141.1 ms before and 62.8 ms for Rust; `--encoding=none` at 15.4 ms
versus 138.4 ms before and 62.8 ms for Rust; `--encoding=utf-8` at 16.5 ms
versus 139.8 ms before and 63.8 ms for Rust; and the no-match repeated-`-e`
form at 5.6 ms versus 28.5 ms before and 4.4 ms for Rust.

The same no-match guard now applies before the repeated/pattern-file exact-line
vimgrep writer. Direct byte/status checks matched the previous Swift binary and
Rust for repeated `-e`, pattern-file, no-column, no-line-number, and no-match
forms. On `/tmp/swift-rg-candidates/countm-big.txt`, `--vimgrep -x -e absent
-e missing` improved from 5.2 ms to 3.8 ms, versus 4.1 ms for Rust.

`--heading` is now output-neutral for executable vimgrep preflights. Rust does
not emit separate heading records for vimgrep output, so the parser keeps
full-line, only-matching, and word-boundary vimgrep shapes on their existing
Swift writers while preserving the usual field layouts and fallback guards.
Direct release comparisons were byte-identical for repeated literals,
only-matching, byte offsets, no-filename, ignore-case, word, word ignore-case,
alternation, single literal, `-N --no-column`, explicit `--with-filename`, and
Unicode fallback fixtures.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--heading --vimgrep -e needle -e quiet` | 5.016 s | 49.3 ms | 91.1 ms |
| `--heading --vimgrep -o -e needle -e quiet` | 4.994 s | 47.0 ms | 92.4 ms |
| `--heading --vimgrep -w -e needle -e quiet` | 5.741 s | 50.0 ms | 128.7 ms |

When `RIPGREP_CONFIG_PATH` is set, supported no-value plus validated inline and
separated value preflight flags may now precede `--no-config` without disabling
the Swift executable preflight. The outer config guard stays conservative around
pattern sources and unknown value-consuming flags, while the full parser still
owns final output eligibility. Direct release comparisons matched Rust stdout,
stderr, and status for deferred `--no-config` vimgrep, quiet, prefixed count,
word-vimgrep, only-matching vimgrep, inline and separated sort/reverse-sort,
inline and separated thread count, inline and separated max-count, and separated
engine selector forms under an active config environment. A follow-up extends
the same guard to explicit pattern-source and replacement flags before
`--no-config`; direct checks matched Rust for separated `-e`, inline
`--regexp=`, short inline `-ePATTERN`, separated `-r`, and inline `--replace=`
vimgrep forms. Color mode and color spec value flags are now included too:
`--color never`/`--color=never` and separated/inline `--colors` forms can reach
the fast path when color is unobservable, while visible color output still falls
through and matched Rust in direct checks. The guard also recognizes neutral
metadata and glob values before `--no-config`: separated/inline
`--hyperlink-format`, empty `--pre`, `--pre-glob`, `--glob`, short inline `-g`,
and `--iglob` forms matched Rust byte-for-byte in direct checks. Numeric,
separator, path-separator, size-limit, max-filesize, and encoding value flags
now share that treatment too, with direct checks covering separated, inline,
short, and visible separator/path representatives. A final metadata follow-up
adds separated and inline `--hostname-bin` values while preserving byte parity.
Existing readable `--ignore-file` paths are now admitted before `--no-config`
too, while missing enabled ignore-file paths stay on the normal parser path.
Type definition and filter values may also precede `--no-config`; invalid
types continue through the normal diagnostic path. Valid short-flag clusters
that the full executable preflight parser already understands are now scanned
before `--no-config`; invalid clusters still use the normal parser diagnostics.
Plain positional pattern/path arguments may also precede `--no-config`, while
dash-prefixed unknowns still fall through to normal parsing.

The before column is the same command measured before the relevant parser
change, where the outer config guard forced the generic Swift path.

| Command | Before | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `--vimgrep --heading --no-config -e needle -e quiet` | 5.067 s | 50.9 ms | 89.2 ms |
| `--sort=path --vimgrep --heading --no-config -e needle -e quiet` | 5.074 s | 47.6 ms | 93.1 ms |
| `--sort path --vimgrep --heading --no-config -e needle -e quiet` | 5.246 s | 48.9 ms | 96.2 ms |
| `-e needle --no-config --vimgrep --heading -e quiet` | 5.116 s | 47.9 ms | 93.5 ms |
| `--color never --vimgrep --heading --no-config -e needle -e quiet` | 5.170 s | 48.1 ms | 97.7 ms |
| `--hyperlink-format=grep+ --vimgrep --heading --no-config -e needle -e quiet` | 5.116 s | 48.2 ms | 96.9 ms |
| `--pre= --vimgrep --heading --no-config -e needle -e quiet` | 5.117 s | 48.0 ms | 96.6 ms |
| `--field-match-separator='|' --vimgrep --heading --no-config -e needle -e quiet` | 5.178 s | 48.4 ms | 96.4 ms |
| `--encoding=auto --vimgrep --heading --no-config -e needle -e quiet` | 5.225 s | 48.5 ms | 97.4 ms |
| `--hostname-bin=hostname --vimgrep --heading --no-config -e needle -e quiet` | 5.165 s | 47.8 ms | 95.7 ms |
| `--ignore-file <existing> --vimgrep --heading --no-config -e needle -e quiet` | 5.050 s | 49.5 ms | 93.3 ms |
| `-t rust --vimgrep --heading --no-config -e needle -e quiet` | 5.036 s | 47.6 ms | 93.3 ms |
| `-iw --vimgrep --heading --no-config -e NEEDLE -e QUIET` | 13.667 s | 49.1 ms | 136.3 ms |
| `needle --no-config --vimgrep --heading` | 3.478 s | 32.1 ms | 62.1 ms |

Plain multi-literal only-matching field output now uses the same field-prefix
preflight for `-b`, `--column`, and `--vimgrep -o` forms. The route covers
single-literal, repeated `-e`, alternation, ASCII ignore-case, filename
prefixes, and vimgrep no-filename output, while non-ASCII ignore-case haystacks
stay on fallback. Direct release comparisons were byte-identical for those
fielded, prefixed, vimgrep, single-literal, and Unicode fallback forms.

10 timed runs on the same dense literal fixture:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-b -o -e needle -e quiet` | 113.4 ms | 36.6 ms | 62.9 ms |
| `--column -o -e needle -e quiet` | 153.8 ms | 44.7 ms | 74.7 ms |
| `--vimgrep -o -e needle -e quiet` | 189.8 ms | 47.6 ms | 91.4 ms |

Bounded fixed-lookaround PCRE count-matches now also stays on the executable
preflight for ASCII fixed lookbehind, fixed lookahead, and reset-start
`prefix\Kliteral` forms. Direct release comparisons were byte-identical for
unprefixed, `-H` prefixed, `--include-zero`, lookahead, lookbehind, and
reset-start bounded count-matches forms, including the `-o --count-matches`
spelling.

10 timed runs on `/tmp/swift-rg-candidates/lookaround-countm-big.txt`, a
9.2 MiB dense lookaround fixture with 300,000 lines:

| Command | Preflight bypassed | Current Swift | Rust `rg` |
| --- | ---: | ---: | ---: |
| `-P --count-matches -m100000 '(?<=prefix)needle'` | 1.378 s | 11.1 ms | 13.8 ms |
| `-P --count-matches -m100000 'prefix(?=needle)'` | 1.343 s | 10.3 ms | 14.6 ms |

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
