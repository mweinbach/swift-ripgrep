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

## Active porting work plan (2026-05-24 orchestration)

Three parallel work items are in flight. Each is owned by one sub-agent. The
streaming/mmap/parallel rearch (item 4 above) is intentionally deferred — it is
a multi-session undertaking that should follow this batch.

### Wave 1A — PCRE2 backend + regex/DFA size limit enforcement
Owner: pair-agent-A. Touches: `Package.swift`, new
`Sources/CPCRE2/*` (system module) and `Sources/RipgrepCore/PCRE2*.swift`,
`Sources/RipgrepCore/PatternMatcher.swift`, `Sources/RipgrepCore/RipgrepCLI.swift`.

- [ ] Add a `CPCRE2` system module target wrapping libpcre2-8 from Homebrew
      (`/opt/homebrew/opt/pcre2`, header `pcre2.h`, lib `pcre2-8`). Use
      `PCRE2_CODE_UNIT_WIDTH=8`. Make the link/include paths work when the
      Homebrew prefix is `/opt/homebrew` (Apple silicon) or `/usr/local`
      (Intel) via `unsafeFlags` driven by `pcre2-config` or a small fallback.
- [ ] Replace the "PCRE2 is not available" error path in
      `PatternMatcher` with a real PCRE2-backed `CompiledPattern` case.
      Implement `--engine=pcre2`, `-P`, `--engine=auto` (auto must try the
      default engine first and fall back to PCRE2 when the default rejects the
      pattern with the auto-hybrid diagnostic).
- [ ] Wire `--no-pcre2-unicode` / `--pcre2-unicode` into PCRE2 compile
      options (UCP/UTF flags) and `--pcre2-version` to return the real linked
      PCRE2 version string. Update `RipgrepCLI` `features:-pcre2` to
      `features:+pcre2` when PCRE2 is linked.
- [ ] Enforce `--regex-size-limit` for the default (NSRegularExpression)
      engine using a heuristic that mirrors Rust's behaviour: refuse to
      compile when the estimated regex program size exceeds the limit, and
      surface Rust's exact error string `compiled regex exceeds size limit of
      <N>`. Map `--dfa-size-limit` to a guard that produces Rust's
      `dfa size limit exceeded` style error when triggered.
- [ ] Tests in `Tests/RipgrepCoreTests/` covering all of the above
      (PCRE2 lookaround, PCRE2 backrefs, auto-hybrid fallback, size-limit
      rejection messages, `--pcre2-version` output). Run `swift test`.

### Wave 1B — Encoding Standard label support
Owner: pair-agent-B. Touches: new
`Sources/RipgrepCore/EncodingLabels.swift`,
`Sources/RipgrepCore/RipgrepOptions.swift` (`parseEncoding`),
`Sources/RipgrepCore/Haystack.swift` (decode path),
`Sources/RipgrepCore/RipgrepCLI.swift` (encoding flow if needed).

- [x] Build a WHATWG-Encoding-Standard label table mapping every label from
      <https://encoding.spec.whatwg.org/#concept-encoding-get> to a Foundation
      `String.Encoding` or `CFStringEncoding`. Cover at least the families
      ripgrep users hit: gbk / gb18030, big5, euc-kr, iso-8859-* (1..16
      except known gaps), windows-1250..1258, koi8-r/u, mac-cyrillic, ibm866,
      x-mac-cyrillic, utf-8/16/le/be, gb2312 (alias of gbk), shift_jis,
      euc-jp.
- [x] Extend `EncodingMode.explicit(...)` to carry whatever representation
      the table returns (introduce a `TextEncoding` wrapper if the existing
      `String.Encoding` is not expressive enough). Decode file/stdin bytes
      through that encoding in `Haystack` and the stdin path.
- [x] Reject unknown labels with Rust's exact error text:
      `error parsing flag --encoding: unknown encoding: <label>` (or whatever
      Rust's wording is — check by probing `rg --encoding nope x.txt`).
- [x] Update the `--encoding` short-help string in `RipgrepOptions` so it no
      longer claims only `auto/none/utf-8/utf-16/le/be`.
- [x] Tests covering several new labels (at minimum gbk, big5, koi8-r,
      windows-1251, iso-8859-7) plus the unknown-label error wording. Run
      `swift test`.

### Wave 1C — Test split + parity harness
Owner: pair-agent-C. Touches: `Tests/RipgrepCoreTests/*` only — do not modify
files under `Sources/`.

- [ ] Split `Tests/RipgrepCoreTests/RipgrepCoreTests.swift` (≈7,110 lines)
      into per-area files that mirror the Rust integration test layout under
      `~/Projects/swift-harness/ripgrep/tests/`: `BinaryTests.swift`,
      `FeatureTests.swift`, `JSONTests.swift`, `MiscTests.swift`,
      `MultilineTests.swift`, `RegressionTests.swift`. Move shared helpers
      into a new `RipgrepTestSupport.swift` (or similar). Every existing test
      method must land in exactly one new file with the same name and
      behaviour; do not silently drop tests.
- [ ] Add a `ParityHarnessTests.swift` (gated behind an env var such as
      `SWIFT_RIPGREP_PARITY=1`) that, when enabled, runs both
      `.build/debug/ripgrep` and the installed `rg` over a small fixture set
      (a tiny `Tests/Fixtures/parity/` tree with text, binary, gitignored,
      multiline and encoding samples) and diffs stdout/stderr/exit. When the
      env var is unset the test should skip cleanly so CI stays green.
- [ ] Run `swift test` after the split to confirm the suite still passes,
      and `SWIFT_RIPGREP_PARITY=1 swift test --filter ParityHarnessTests`
      locally to sanity-check the harness against installed `rg`.

### Wave 2 (deferred — explicitly out of scope this batch)
- Streaming line buffer, mmap selection, per-thread search workers and
  `--threads`/`--mmap`/`--line-buffered`/`--block-buffered` runtime wiring.
  This is the largest remaining slice from "High-priority missing parity"
  item 4 and should be its own multi-step plan.

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
