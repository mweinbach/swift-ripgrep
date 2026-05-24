# swift-ripgrep porting notes

Baseline checked: `/Users/mweinbach/Projects/swift-harness/ripgrep` at
`4519153e5e` (`ripgrep 15.1.0`). The Swift binary reports the same upstream
revision and currently advertises `features:-pcre2`.

## Current shape

The Swift port is a compact SwiftPM package: one library target, one executable
target and one test target. It maps most of ripgrep's public CLI flags into
`RipgrepOptions`, carries generated help/man/completion resources, and has a
large single-file test suite covering search, output formats, ignore rules,
file types, stdin, encodings, binary handling and parser diagnostics.

Compared with Rust ripgrep, the port has intentionally collapsed the upstream
workspace into a much smaller implementation:

- Rust: `grep`, `regex`, `searcher`, `ignore`, `globset`, `printer`, `cli`,
  `matcher`, `pcre2` and the `rg` core binary.
- Swift: `RipgrepCore` plus `ripgrep`.

## Verified working areas

- CLI flag parsing covers the main Rust flag list, including deprecated aliases
  such as `--sort-files`, `--auto-hybrid-regex` and `--no-pcre2-unicode`.
- Basic recursive search, fixed strings, word/line regex modes, smart case,
  inverted matches and multiple pattern sources are covered.
- Output modes include counts, count matches, files with/without matches,
  line/column/byte offsets, NUL path/data modes, trim, vimgrep, headings,
  pretty/color output, OSC8 hyperlinks, JSON and stats.
- Search behavior covers context, passthru, max-count, max-columns,
  multiline, CRLF, null-data, replacements, binary detection and stdin.
- Traversal covers hidden files, symlink following, one-file-system,
  max-depth, max-filesize, custom ignore files, `.ignore`, `.rgignore`,
  `.gitignore`, `.git/info/exclude`, global git ignore files, override globs
  and default file types.
- `--search-zip` works for the checked `.xz` probe when `xz` is available.

## High-priority missing parity

1. Real PCRE2 and auto-hybrid regex support.

   Rust ripgrep can use PCRE2 when built with the `pcre2` feature. The installed
   Rust `rg` accepts `-P -o '(?<=a)b'` and `--engine=auto -o '(?<=a)b'`; the
   Swift port returns `PCRE2 is not available in this build of ripgrep`.

2. Enforced regex resource limits.

   Swift parses `--regex-size-limit` and `--dfa-size-limit`, but the current
   matcher uses `NSRegularExpression` and does not enforce Rust's automata
   limits. A direct probe with `--regex-size-limit=0 '[a-z]'` errors in Rust
   with `compiled regex exceeds size limit of 0`; Swift still matches.

3. Full Encoding Standard label support.

   Rust's searcher delegates labels to `encoding_rs`; Swift currently recognizes
   a small hard-coded set: UTF-8, UTF-16 variants, Latin-1/Windows-1252,
   Shift-JIS and EUC-JP. A direct probe with `--encoding gbk` works in Rust
   and fails at parse time in Swift.

4. Streaming, mmap and parallel search architecture.

   Swift reads each file into memory before searching and then walks/searches
   with ordinary array maps. Rust ripgrep has a streaming line buffer, mmap
   selection, heap limits and parallel traversal/search machinery. In Swift,
   `--threads`, `--mmap`, `--line-buffered`, `--block-buffered`,
   `--dfa-size-limit` and `--regex-size-limit` are mostly accepted as CLI
   compatibility flags rather than implemented runtime controls.

5. Regex engine fidelity beyond covered cases.

   The Swift matcher translates selected Rust regex behavior onto
   `NSRegularExpression` plus bespoke edge-case handling. The Rust implementation
   builds configured HIR and regex-automata matchers with literal extraction,
   Unicode/no-Unicode transforms, CRLF handling, line terminator bans and size
   accounting. The Swift tests cover many patched cases, but the architecture is
   still more likely to drift on regex syntax and pathological edge cases.

## Medium-priority improvements

- Add a parity harness that can run selected upstream integration fixtures
  against `.build/debug/ripgrep` and installed Rust `rg`, then compare stdout,
  stderr and exit status.
- Split `Tests/RipgrepCoreTests/RipgrepCoreTests.swift` by upstream area
  (`binary`, `feature`, `json`, `misc`, `multiline`, `regression`) so future
  porting slices can map back to Rust test files.
- Automate generated asset refresh for `rg.help.*`, `rg.1` and shell
  completions from the Rust checkout, or at least add a drift check.
- Add performance smoke tests for large files, many files, binary detection and
  compressed input before changing the search architecture.
- Keep the next slices narrow and checkpointable: PCRE2/auto-hybrid behavior,
  regex limit enforcement, Encoding Standard labels, and then streaming search.

## Verification commands

Run these before checkpointing a porting slice:

```sh
swift test
git diff --check
```

Useful parity probes:

```sh
tmp=$(mktemp -d)
printf 'ab\nac\n' > "$tmp/pcre.txt"
rg -P -o '(?<=a)b' "$tmp/pcre.txt"
.build/debug/ripgrep -P -o '(?<=a)b' "$tmp/pcre.txt"
rg --engine=auto -o '(?<=a)b' "$tmp/pcre.txt"
.build/debug/ripgrep --engine=auto -o '(?<=a)b' "$tmp/pcre.txt"
rm -rf "$tmp"

tmp=$(mktemp -d)
printf 'abc\n' > "$tmp/r.txt"
rg --regex-size-limit=0 '[a-z]' "$tmp/r.txt"
.build/debug/ripgrep --regex-size-limit=0 '[a-z]' "$tmp/r.txt"
rm -rf "$tmp"

tmp=$(mktemp -d)
printf 'needle\n' > "$tmp/e.txt"
rg --encoding gbk needle "$tmp/e.txt"
.build/debug/ripgrep --encoding gbk needle "$tmp/e.txt"
rm -rf "$tmp"
```
