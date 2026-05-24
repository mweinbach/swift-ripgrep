# swift-ripgrep porting notes

Baseline checked: `/Users/mweinbach/Projects/swift-harness/ripgrep` at
`4519153e5e` (`ripgrep 15.1.0`). The Swift binary reports the same upstream
revision and, after the 2026-05-24 orchestration, advertises `features:+pcre2`
when the linked libpcre2-8 is available.

## Current shape

The Swift port is a SwiftPM package with one library target, one executable
target, one system-module target (`CPCRE2`, wrapping Homebrew libpcre2-8) and
one test target. It maps most of ripgrep's public CLI flags into
`RipgrepOptions`, carries generated help/man/completion resources, and uses a
test suite that mirrors the Rust upstream split (`BinaryTests`, `FeatureTests`,
`JSONTests`, `MiscTests`, `MultilineTests`, `RegressionTests`, plus
`HaystackReaderTests`, `ParityHarnessTests` and `RipgrepTestSupport`).

File input flows through `HaystackReader` (mmap for regular files ≥ 16 KiB or
when `--mmap` is forced, chunked 64 KiB buffered reads otherwise, stdin always
buffered). Per-haystack searches run inside a bounded Swift Concurrency
`TaskGroup` driven by `--threads` (default `min(activeProcessorCount, 12)`,
Rust's cap). Stdout buffering honours `--line-buffered` / `--block-buffered`
via `setvbuf`, with the same TTY-based default that Rust ripgrep uses.

Compared with Rust ripgrep, the port still collapses the upstream workspace
into a much smaller implementation:

- Rust: `grep`, `regex`, `searcher`, `ignore`, `globset`, `printer`, `cli`,
  `matcher`, `pcre2` and the `rg` core binary.
- Swift: `RipgrepCore` (plus `CPCRE2`) and the `ripgrep` executable.

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
- Real PCRE2 backend via `CPCRE2`/libpcre2-8 powers `-P`, `--engine=pcre2`,
  `--engine=auto` (auto-hybrid fallback), `--pcre2-version`, and the
  `--pcre2-unicode`/`--no-pcre2-unicode` UCP/UTF toggles.
- Default-engine size accounting honours `--regex-size-limit` and emits the
  Rust-compatible `compiled regex exceeds size limit of <N>` diagnostic when
  the budget is exceeded. `--dfa-size-limit` is plumbed in for the same
  failure path.
- Full WHATWG Encoding Standard label support via `EncodingLabels.swift` and
  the new `TextEncoding` wrapper. `--encoding gbk`, `big5`, `koi8-r`,
  `windows-1251`, `iso-8859-7`, and the rest of the Encoding Standard alias
  table decode correctly; unknown labels produce
  `error parsing flag --encoding: grep config error: unknown encoding: <label>`.
- `HaystackReader` provides the mmap + chunked-buffered file I/O paths. `--mmap`
  forces mmap (and surfaces the underlying mmap error if the kernel rejects),
  `--no-mmap` forces the chunked path, automatic mode picks based on file size
  and regular-file status. Stdin streams in 64 KiB chunks.
- A bounded `TaskGroup`-based worker pool fans out per-file search work.
  `--threads N` drives the worker count (`N == 1` falls back to the prior
  sequential `.map` path so single-threaded behaviour stays byte-identical).
  Output ordering is deterministic by walk position even at high thread counts.
- `--line-buffered` / `--block-buffered` wire to `setvbuf(stdout, ...)` and
  fall back to explicit flushes for non-stdio writers.

## High-priority missing parity

1. **(Done 2026-05-24)** Real PCRE2 and auto-hybrid regex support — see
   `Sources/CPCRE2/`, `Sources/RipgrepCore/PCRE2Matcher.swift`, and the PCRE2
   integration in `Sources/RipgrepCore/PatternMatcher.swift`.

2. **(Done 2026-05-24)** Enforced regex resource limits — see the size-budget
   guard in `Sources/RipgrepCore/PatternMatcher.swift`.

3. **(Done 2026-05-24)** Full Encoding Standard label support — see
   `Sources/RipgrepCore/EncodingLabels.swift` and the `TextEncoding` decoder
   plumbed through `Haystack.swift` and the stdin path.

4. **(Done 2026-05-24)** Streaming, mmap and parallel search architecture.
   `HaystackReader` provides mmap-vs-buffered selection, the per-haystack
   loop runs through a bounded `TaskGroup` worker pool wired to `--threads`,
   and stdout buffering honours `--line-buffered` / `--block-buffered`. The
   sequential path (`--threads 1`) is preserved bit-for-bit so existing tests
   remain green. The only piece of Rust's architecture that is *not* mirrored
   is a true streaming line buffer that hands matcher chunks rather than the
   full file — that's a Wave 3 optimisation, not a correctness gap, because
   mmap already avoids any actual heap copy of the file body.

5. Regex engine fidelity beyond covered cases. **(Open backlog)**

   The Swift matcher translates selected Rust regex behavior onto
   `NSRegularExpression` plus bespoke edge-case handling. The Rust implementation
   builds configured HIR and regex-automata matchers with literal extraction,
   Unicode/no-Unicode transforms, CRLF handling, line terminator bans and size
   accounting. The Swift tests cover many patched cases, but the architecture is
   still more likely to drift on regex syntax and pathological edge cases. The
   auto-hybrid fallback (item 1) reduces the impact in practice because patterns
   the default engine cannot handle now degrade gracefully to PCRE2. This is
   best driven by running upstream regex fixture suites against the Swift
   binary and folding the diffs back into `PatternMatcher.swift` — an ongoing
   quality effort rather than a finite porting slice.

## Wave 3 — true 1:1 parity push (active 2026-05-24)

### Wave 3A — Comprehensive parity harness vs Rust tests/* + drift fixes
Owner: pair-agent-F. Touches: `Tests/RipgrepCoreTests/ParityHarnessTests.swift`
(rewrite to data-driven), new `Tests/RipgrepCoreTests/ParityHay.swift` (port
of Rust `tests/hay.rs` constants), new `Tests/Fixtures/parity/` subtrees as
needed, and bug fixes anywhere in `Sources/RipgrepCore/` that the harness
flags. Do NOT delete or downgrade the existing 81 Swift Testing cases — they
stay green.

- [x] Port Rust's `tests/hay.rs` constants (`SHERLOCK`, `SHERLOCK_CRLF`, etc.)
      into a Swift constant module. They are the canonical haystacks used by
      most Rust integration tests.
- [x] Convert `ParityHarnessTests` into a data-driven runner: each case is a
      `(name, fixtureBuilder, args[, stdin])` tuple. The runner creates a
      tempdir, lets `fixtureBuilder` populate it, runs both binaries with
      `args`, and asserts byte-identical stdout/stderr/exit-code.
- [x] Port at least ~150 cases drawn from Rust's `tests/binary.rs`,
      `tests/multiline.rs`, `tests/json.rs`, `tests/misc.rs`,
      `tests/feature.rs`, `tests/regression.rs`. Concentrate on cases that
      exercise behaviour the existing Swift Testing suite *doesn't* already
      cover — passthru, OSC8 hyperlinks, `--null`/`-Z` JSON variants, weird
      regex regressions (look for `r123`-style names), `-Uw` multiline word
      boundaries, etc.
- [x] Run the harness. For every diff, fix the Swift implementation until
      the case matches Rust byte-for-byte. Most fixes land in
      `Sources/RipgrepCore/PatternMatcher.swift`, but the output formatters
      (`StandardPrinter`, `JSONPrinter`) and `RipgrepSearcher` are fair game
      too. Skip a case (with a clear `XCTSkip("known divergence: ...")`) only
      if the difference is intentional (e.g. Swift PCRE2 version string).
- [x] Document each intentional skip in the harness file *and* in
      `Docs/PORTING.md` under a new "Intentional divergences" section.

Wave 3A status: 193 parity cases are registered; 192 now pass byte-for-byte
against installed `rg`, and 1 case is intentionally skipped (APFS filesystem
limitation only).

### Wave 3C — Timing-aware JSON parity (done 2026-05-24)

Rust `rg` emits real elapsed timings in JSON output (`elapsed`,
`elapsed_total`); Swift keeps those fields at zero for deterministic test
output. The parity harness now normalizes timing objects out of both outputs
before byte-comparing, which re-enables the 10 previously-skipped JSON cases.
The Swift JSON schema and all non-timing values are byte-identical to Rust.

### Intentional divergences

- JSON `elapsed` / `elapsed_total` fields carry real timings in Rust and zero
  in Swift (deliberate, for deterministic output). The parity harness strips
  those object bodies before comparing, so the rest of the JSON output is
  verified byte-for-byte.
- `json::notutf8` is skipped on macOS/APFS only because the upstream Rust
  fixture depends on an invalid UTF-8 filename that APFS cannot create. There
  is no Swift-side gap; the Rust binary itself wouldn't reproduce the upstream
  output if its filesystem also forbade that filename.

### Wave 3B — True streaming line buffer + heap cap on chunked I/O

**Status: deferred (not a parity gap).** mmap auto-selection at 16 KiB
already avoids any heap copy for the file sizes where streaming matters; the
chunked buffered path is only used for small files and stdin where the
accumulated `Data` is bounded by content. This is a pure perf optimisation
and should reopen only if a benchmark shows realistic-workload RSS pressure.

## Wave 4 — open backlog (no scheduled work)

- True streaming line buffer that hands matcher chunks rather than the full
  haystack (perf optimisation; see Wave 3B notes above).
- Wider encoding probe coverage (more legacy codepages, GB18030 edge cases,
  big5-hkscs).
- Compressed-input probe coverage (`.gz`, `.bz2`, `.zst`, `.lz4`).
- Generated-asset refresh automation (`rg.help.*`, `rg.1`, shell
  completions) from the Rust checkout.

## Medium-priority improvements

- **(Done 2026-05-24)** Parity harness gated on `SWIFT_RIPGREP_PARITY=1`
  in `Tests/RipgrepCoreTests/ParityHarnessTests.swift` (fixtures under
  `Tests/Fixtures/parity/`). When the env var is unset the test skips so CI
  stays green; when set it diffs stdout/stderr/exit between
  `.build/debug/ripgrep` and the installed `rg`.
- **(Done 2026-05-24)** Test split mirroring the Rust upstream layout —
  `BinaryTests`, `FeatureTests`, `JSONTests`, `MiscTests`, `MultilineTests`,
  `RegressionTests`, plus `RipgrepTestSupport` for shared helpers.
- Automate generated asset refresh for `rg.help.*`, `rg.1` and shell
  completions from the Rust checkout, or at least add a drift check.
- Add performance smoke tests for large files, many files, binary detection and
  compressed input before changing the search architecture.
- Grow the parity harness fixture set — current coverage is text, binary,
  gitignored, multiline and UTF-16LE; extend with more encodings, more
  compressed inputs, and a few of the regex pathological cases.
- Keep the next slices narrow and checkpointable: streaming/mmap/parallel
  architecture (high-priority item 4), then asset-refresh automation and
  perf smoke tests.

## Active porting work plan (2026-05-24 orchestration)

Three parallel work items are in flight. Each is owned by one sub-agent. The
streaming/mmap/parallel rearch (item 4 above) is intentionally deferred — it is
a multi-session undertaking that should follow this batch.

### Wave 1A — PCRE2 backend + regex/DFA size limit enforcement
Owner: pair-agent-A. Touches: `Package.swift`, new
`Sources/CPCRE2/*` (system module) and `Sources/RipgrepCore/PCRE2*.swift`,
`Sources/RipgrepCore/PatternMatcher.swift`, `Sources/RipgrepCore/RipgrepCLI.swift`.

- [x] Add a `CPCRE2` system module target wrapping libpcre2-8 from Homebrew
      (`/opt/homebrew/opt/pcre2`, header `pcre2.h`, lib `pcre2-8`). Use
      `PCRE2_CODE_UNIT_WIDTH=8`. Make the link/include paths work when the
      Homebrew prefix is `/opt/homebrew` (Apple silicon) or `/usr/local`
      (Intel) via `unsafeFlags` driven by `pcre2-config` or a small fallback.
- [x] Replace the "PCRE2 is not available" error path in
      `PatternMatcher` with a real PCRE2-backed `CompiledPattern` case.
      Implement `--engine=pcre2`, `-P`, `--engine=auto` (auto must try the
      default engine first and fall back to PCRE2 when the default rejects the
      pattern with the auto-hybrid diagnostic).
- [x] Wire `--no-pcre2-unicode` / `--pcre2-unicode` into PCRE2 compile
      options (UCP/UTF flags) and `--pcre2-version` to return the real linked
      PCRE2 version string. Update `RipgrepCLI` `features:-pcre2` to
      `features:+pcre2` when PCRE2 is linked.
- [x] Enforce `--regex-size-limit` for the default (NSRegularExpression)
      engine using a heuristic that mirrors Rust's behaviour: refuse to
      compile when the estimated regex program size exceeds the limit, and
      surface Rust's exact error string `compiled regex exceeds size limit of
      <N>`. Map `--dfa-size-limit` to a guard that produces Rust's
      `dfa size limit exceeded` style error when triggered.
- [x] Tests in `Tests/RipgrepCoreTests/` covering all of the above
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

- [x] Split `Tests/RipgrepCoreTests/RipgrepCoreTests.swift` (≈7,110 lines)
      into per-area files that mirror the Rust integration test layout under
      `~/Projects/swift-harness/ripgrep/tests/`: `BinaryTests.swift`,
      `FeatureTests.swift`, `JSONTests.swift`, `MiscTests.swift`,
      `MultilineTests.swift`, `RegressionTests.swift`. Move shared helpers
      into a new `RipgrepTestSupport.swift` (or similar). Every existing test
      method must land in exactly one new file with the same name and
      behaviour; do not silently drop tests.
- [x] Add a `ParityHarnessTests.swift` (gated behind an env var such as
      `SWIFT_RIPGREP_PARITY=1`) that, when enabled, runs both
      `.build/debug/ripgrep` and the installed `rg` over a small fixture set
      (a tiny `Tests/Fixtures/parity/` tree with text, binary, gitignored,
      multiline and encoding samples) and diffs stdout/stderr/exit. When the
      env var is unset the test should skip cleanly so CI stays green.
- [x] Run `swift test` after the split to confirm the suite still passes,
      and `SWIFT_RIPGREP_PARITY=1 swift test --filter ParityHarnessTests`
      locally to sanity-check the harness against installed `rg`.

### Wave 2 — Streaming + mmap + workers + buffering (active 2026-05-24)

The remaining high-priority architectural slice. Two sequential agents so
they don't fight over `RipgrepSearcher.swift`.

#### Wave 2A — Streaming + mmap reader
Owner: pair-agent-D. Touches: new
`Sources/RipgrepCore/HaystackReader.swift`,
`Sources/RipgrepCore/RipgrepSearcher.swift` (`searchFile` body and the stdin
path — leave the per-file loop alone for 2B).

- [x] Add a `HaystackReader` (or equivalent) abstraction with two read paths:
      1. mmap via Darwin `mmap`/`munmap` for regular files — choose mmap when
         the file is at least ~16 KiB *and* `options.mmapMode != .never` *and*
         the file is a regular file (`stat.st_mode & S_IFREG`).
      2. Chunked buffered read via `FileHandle.read(upToCount:)` (8–64 KiB
         chunks) otherwise. Honour `options.mmapMode == .always` by forcing
         mmap and surfacing a useful error if mmap fails.
- [x] Replace the `Data(contentsOf: fileURL)` whole-file read at
      `RipgrepSearcher.swift` line ~282 with `HaystackReader.read(haystack,
      options:)`. Behaviour for downstream code (binary detection, decode,
      `searchContents(...)`) must be identical for already-passing tests.
- [x] Stream stdin the same way — replace
      `FileHandle.standardInput.readDataToEndOfFile()` at line ~92 with a
      chunked reader. Stdin always uses the buffered path.
- [x] Honour `--max-filesize` before the mmap/buffered branch (skip oversized
      files cleanly the same way the current code does).
- [x] Tests: add a small `HaystackReaderTests.swift` covering large vs small
      files, `--mmap`/`--no-mmap` forced paths, mmap-fallback when the OS
      rejects mmap (use `/dev/null` or an anonymous pipe), and chunk-boundary
      determinism for multiline patterns. Existing tests must remain green.

#### Wave 2B — Worker pool + line/block buffering
Owner: pair-agent-E (dispatched only after 2A lands). Touches:
`Sources/RipgrepCore/RipgrepSearcher.swift` (the per-haystack loop near the
top of `search(options:stdin:)`), `Sources/RipgrepCore/RipgrepCLI.swift`
(stdout flush wiring).

- [x] Drive the per-haystack loop with a bounded `TaskGroup`. Default the
      worker count to `min(ProcessInfo.processInfo.activeProcessorCount, 12)`
      (matching the Rust ripgrep cap) and let `--threads N` override it
      (clamped to ≥1). When `N == 1`, fall back to the existing sequential
      path so behaviour is unchanged.
- [x] Preserve deterministic per-walk-order output: collect results into an
      array indexed by walk position and emit in that order. The existing
      tests assume stable ordering.
- [x] Wire `--line-buffered` / `--block-buffered` to the stdout flush policy
      in `RipgrepCLI`. Default to line buffering when stdout is a TTY
      (`isatty(STDOUT_FILENO)`), block otherwise. Use `setvbuf` (line `_IOLBF`
      or block `_IOFBF`) — fall back to manual `fflush` after each match line
      if `setvbuf` is impractical.
- [x] Tests: extend `ParityHarnessTests` with a `--threads 4` and a
      `--threads 1` invocation to prove output is byte-identical. Add a
      determinism test that runs the same search 8x with `--threads 8` and
      asserts identical stdout each time.

#### Wave 2 — wrap-up
- [ ] Refresh PORTING.md (mark items 4 and the streaming sub-list done; flag
      item 5 / regex-engine-fidelity as the remaining backlog).
- [ ] Final parity probes from "Verification commands" against installed
      `rg`, plus the new probes for `--threads`, `--mmap`, and `--no-mmap`.

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
