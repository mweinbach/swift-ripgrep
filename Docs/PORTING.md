# swift-ripgrep porting notes

Baseline checked: `/Users/mweinbach/Projects/swift-harness/ripgrep` at
`4519153e5e` (`ripgrep 15.1.0`). The Swift binary reports the same upstream
revision and keeps the `-P`/`--engine=pcre2` surface available through the
in-tree Swift compatibility engine; it does not link libpcre2.

## Status — 2026-05-26

**Functional 1:1 with Rust ripgrep 15.1.0 across the covered harness,
including the streaming I/O architecture.** Verified via:

- **163 Swift Testing cases** across 12 suites covering search, output formats,
  ignore rules, file types, stdin, encodings, binary handling, parser
  diagnostics, mmap/worker pool, PCRE2, streaming haystack reads, and
  generated-asset drift.
- **193 parity-harness cases** drawn from Rust's own `tests/binary.rs`,
  `tests/multiline.rs`, `tests/json.rs`, `tests/misc.rs`, `tests/feature.rs`
  and `tests/regression.rs`, plus compressed-input probes for `.gz` /
  `.bz2` / `.xz` / `.lzma` / `.br` / `.zst` / `.lz4`. **192 pass
  byte-for-byte** (including JSON
  output after stripping `elapsed`/`elapsed_total` timing values, which are
  inherently non-deterministic in Rust). The remaining 1 is skipped because
  APFS refuses to create the invalid-UTF-8 filename the upstream Rust fixture
  builds — a filesystem limitation, not a Swift gap.
- **Ad-hoc parity sweep:** 36/36 probes byte-identical to `rg` across PCRE2,
  encoding labels, mmap selection, threaded search, every output mode,
  glob/ignore handling, and JSON output.
- **PCRE long-tail stress sweep:** 36/36 probes byte-identical to the sibling
  Rust PCRE2 oracle after the 2026-05-26 named-replacement, branch-reset
  suffix, leading-`(?U)`, `(*PRUNE)`, group-state conditional and `\A`
  line-mode span fixes, fixed-literal subroutine lowering, and a scoped
  balanced-parentheses recursion matcher.
- **Asset drift suite:** stored help/man/completion files are pinned to the
  current binary's `--generate`/`--help` output via 7 dedicated tests.
  `scripts/refresh-generated-assets.sh` regenerates them when needed.
- **Dependency guard:** `scripts/check-no-external-deps.sh` builds the release
  binary and verifies the manifest, package graph, source hooks, vendored
  binary libraries, Darwin arm64 architecture, dynamic libraries and binary
  symbols so the normal build stays free of external PCRE2/package-manager
  dependencies.

Every public CLI flag accepted by Rust ripgrep is parsed; every flag that
controls runtime behaviour is wired to the corresponding subsystem.

## Current shape

The Swift port is a SwiftPM package with one library target, one executable
target, one optional Darwin arm performance shim (`CRipgrepPlatform`) and one
test target. It maps most of ripgrep's public CLI flags into
`RipgrepOptions`, carries generated help/man/completion resources, and uses a
test suite that mirrors the Rust upstream split (`BinaryTests`, `FeatureTests`,
`JSONTests`, `MiscTests`, `MultilineTests`, `RegressionTests`, plus
`HaystackReaderTests`, `ParityHarnessTests` and `RipgrepTestSupport`).

The default build omits `CRipgrepPlatform`. It keeps the in-tree Swift PCRE2
compatibility engine available, uses Swift SIMD fallbacks for the hottest byte
scanners, and includes a Swift-only Darwin mmap preflight for simple literal
and case-insensitive literal searches. Set `SWIFT_RIPGREP_USE_C_SHIM=1` to
include the old Darwin C helper target for A/B performance comparison; if both
that flag and `SWIFT_RIPGREP_NO_C_SHIM=1` are present, the Swift-only build
wins.

The normal build has no package-manager or system-library dependency. Plain
literals selected through PCRE-compatible flags (`-P`, `--pcre2`, `--engine`,
`--auto-hybrid-regex` and their disabling/default forms) reuse the default
literal matcher and, for single-file executable searches, the Darwin literal
preflight before the compatibility engine is needed. That literal parser also
understands safely escaped regex metacharacters such as `\.` and `\[` plus
PCRE quote escapes (`\Q...\E`) when the selected engine permits them.
PCRE2 syntax compatibility is implemented in Swift/Foundation for the covered
non-literal `-P` surface, including translation of partial PCRE quoted regexes,
bare non-newline escapes (`\N`), ASCII shorthand class semantics under
`--no-pcre2-unicode`, and assertion-conditionals such as
`(?(?=foo)foo|bar)` before Foundation compilation, with Swift-parsed fixed
positive/negative lookaround literal, reset-start (`\K`) literal and
literal-backreference specializations, including bare `\K`, empty-prefix or
empty-literal reset-start forms such as `\Kfoo` and `foo\K`, and fixed literal
prefix plus regex suffix forms such as `foo\K\w+`, `foo\K[0-9]+` and
`foo\K(?:bar|baz)`, plus regex-prefix reset-start forms such as
`(foo|abc)\K[0-9]+`, `\w+\K[0-9]+`, `foo.*\Kbar`, `foo(?=bar)\K` and
`(?<=foo)\Kbar`. The fixed byte cases use the checked-in Darwin byte scanner
for `-P -o`, line-numbered, byte-offset and byte-column only-match output, plus
count/path/quiet modes. Broader reset-start forms are rewritten through the
Swift/Foundation compatibility matcher and preserve post-reset replacements,
including reset-start backreference shapes such as `(foo)\K\1`, `(foo)\K\g1`,
`(foo)\K\g{1}`, `(?P<w>foo)\K(?P=w)` and `(foo|abc)\K\1`.
Backreference spellings such as `\g` and Python-style named backreferences are
translated in-tree, including relative `\g{-1}`, `\g<-1>`, `\g'-1'` and bare
`\g-1` forms plus their PCRE2 compile diagnostics for invalid relative or zero
targets. Fixed PCRE byte-unit escapes (`\C`, `\C+` and `\C{n}`) are
matched in-tree as raw bytes, preserving Rust's UTF-mode behavior of starting
matches only at UTF-8 scalar boundaries unless
`--no-pcre2-unicode` is selected. Literal assertion-conditionals and plain
byte-unit only-match output also get narrow Darwin stdout writers for the
plain executable `-P -o` shape. Fixed literal PCRE lookaround/backreference
only-match output now has the same narrow Darwin writer for the plain
executable shape, while Swift byte-loop fast paths cover
line-numbered/byte-offset/column only-match output plus count/path/quiet modes.
The old Darwin arm C hot paths remain checked in behind
`SWIFT_RIPGREP_USE_C_SHIM=1` for benchmarking, but the Swift SIMD scanners and
Swift-only mmap preflight are now the normal build path.

File input flows through `HaystackReader` (mmap for regular files ≥ 16 KiB or
when `--mmap` is forced, chunked 64 KiB buffered reads otherwise, stdin always
buffered). Per-haystack searches run inside a bounded Swift Concurrency
`TaskGroup` driven by `--threads`; on Darwin the automatic worker cap is four
because that benchmarks faster on the Linux tree, while non-Darwin keeps the
Rust-shaped `min(activeProcessorCount, 12)` cap and explicit `--threads N`
always overrides the default. Stdout buffering honours `--line-buffered` /
`--block-buffered` via `setvbuf`, with the same TTY-based default that Rust
ripgrep uses.

Compared with Rust ripgrep, the port still collapses the upstream workspace
into a much smaller implementation:

- Rust: `grep`, `regex`, `searcher`, `ignore`, `globset`, `printer`, `cli`,
  `matcher`, `pcre2` and the `rg` core binary.
- Swift default: `RipgrepCore` and the `ripgrep` executable.
- Swift C-shim comparison build: `RipgrepCore`, the Darwin arm
  `CRipgrepPlatform` shim and the `ripgrep` executable.

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
- `--search-zip` works for checked `.gz`, `.bz2`, `.xz`, `.lzma`, `.br`,
  `.zst` and `.lz4` probes when the matching decompressor is available.
- In-tree PCRE2-compatible regex support powers `-P`, `--engine=pcre2`,
  `--engine=auto` (auto-hybrid fallback), and the
  `--pcre2-unicode`/`--no-pcre2-unicode` compatibility toggles without linking
  libpcre2. Plain literals selected through those engine flags bypass the
  compatibility matcher and stay on the default literal/Darwin byte path,
  including safely escaped fixed literals and PCRE quoted literals. Default and
  `--no-pcre2` modes still reject PCRE-only quote escapes and byte-unit escapes
  with Rust-compatible diagnostics.
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

1. **(Updated 2026-05-26)** PCRE2-style and auto-hybrid regex support without
   libpcre2 — see `Sources/RipgrepCore/PCRE2Matcher.swift` and the
   compatibility integration in `Sources/RipgrepCore/PatternMatcher.swift`.
   Plain literals selected through PCRE/auto/default engine flags bypass the
   compatibility matcher entirely and use the same literal fast paths as the
   default engine, including safely escaped fixed literals such as `foo\.bar`
   and PCRE quoted literals such as `\Qfoo.bar\E` when PCRE or auto mode is
   selected. Partial quoted regexes are translated in-tree before Foundation
   compilation, while default/no-PCRE modes retain Rust-compatible rejection
   diagnostics for `\Q`, `\E`, `\K`, `\N`, `\g`, `\k`, and Python-style PCRE
   backreference flags. Fixed positive/negative lookaround literals, bare
   reset-start `\K`, fixed reset-start literals such as `foo\Kbar`, `\Kfoo`
   and `foo\K`, and literal-group backreferences including `(foo)\g1`,
   `(foo)\g{1}`, and
   `(?P<w>foo)(?P=w)` now avoid the Foundation regex path for single-file
   `-P -o` output, line-numbered/byte-offset/byte-column only-match output and
   count/path/quiet modes, including ASCII ignore-case forms when
   `--no-pcre2-unicode` selects byte semantics. Literal-prefix reset-start
   regex suffixes such as `foo\K\w+`, `foo\K[0-9]+` and `foo\K(?:bar|baz)`
   are rewritten through the Swift/Foundation compatibility matcher so they no
   longer need PCRE2. Regex-prefix reset-start forms such as
   `(foo|abc)\K[0-9]+`, `\w+\K[0-9]+`, `foo.*\Kbar`, `foo(?=bar)\K` and
   `(?<=foo)\Kbar` now use the same in-tree reset-range adjustment and preserve
   capture numbering for replacements. Numeric and PCRE/Python named
   backreferences after `\K` are shifted around the synthetic boundary capture,
   covering forms like `(foo)\K\1`, `(foo)\K\g1`, `(foo)\K\g{1}`,
   `(?P<w>foo)\K(?P=w)` and `(foo|abc)\K\1`. Bare `\N` now matches any
   non-newline character in PCRE/auto
   mode, while `\N{name}` stays a Rust-compatible PCRE2 error. Under
   `--no-pcre2-unicode`, shorthand classes such as `\w` and `\d` are translated
   to ASCII ranges before Foundation compilation. Assertion conditionals using
   lookahead/lookbehind conditions are translated in-tree for PCRE/auto modes
   while default/no-PCRE modes retain Rust-compatible `unrecognized flag`
   diagnostics. Literal condition/branch forms use a Swift matcher plus a
   Darwin stdout writer for plain executable `-P -o`; they remain
   byte-identical to Rust `rg` and benchmark faster than Rust PCRE2 on the
   dense conditional corpus in `bench/RESULTS.md`. Fixed byte-unit forms
   `\C`, `\C+` and `\C{n}` now use a Swift raw-byte matcher, a direct Darwin
   writer for the plain executable `-P -o` case, and a formatted Swift byte
   loop for line-numbered/byte-offset/column only-match output plus
   count/path/quiet modes; auto mode falls through to that compatibility path,
   while default/no-PCRE modes reject `\C` with the same diagnostic shape as
   Rust. Embedded byte-unit forms such as `a\Cb`, `a\C+`, `foo\C{3}bar`,
   `.\C` and `\C\d` are translated to raw-byte Swift regexes for the general
   compatibility path. Common PCRE skip/fail alternations such as
   `alpha(*SKIP)(*F)|beta` and `\[[^\]]+\](*SKIP)(*FAIL)|\w+` are handled
   in-tree by pairing skip and match regexes while preserving replacement
   capture numbering for skipped-branch groups, and `(*PRUNE)` verbs in
   leftmost alternation patterns are erased before Foundation compilation so
   forms like `foo(*PRUNE)|foobar` keep Rust's observed only-match output.
   Top-level PCRE branch-reset alternations such as `(?|a(b)|c(d))` are split
   into Swift regex branches and preserve the reset capture numbering for
   replacements; no-new-capture suffixes such as `(?|(foo)|(bar))\1` are split
   the same way so branch-reset backreferences after the group remain
   Rust-compatible. PCRE named captures
   now flow through both Swift-regex compatibility matches and fixed named
   backreference fast paths so `$name` and `${name}` replacements match Rust
   for `(?<name>...)`, `(?'name'...)` and `(?P<name>...)` spellings. Numeric
   `\k` names now keep PCRE2's compile-time diagnostic instead of being treated
   as numeric backreferences, and relative `\g` backreferences are resolved
   in-tree for brace, angle, quoted and bare signed spellings without libpcre2.
   Leading `(?U)` ungreedy mode is translated by flipping quantifier defaults
   before Foundation compilation, including the PCRE behavior where an explicit
   lazy suffix becomes greedy under ungreedy mode. Simple group-state
   conditionals over a leading optional fixed capture, such as `(a)?(?(1)b|c)`,
   `(?<x>a)?(?(<x>)b|c)` and `(?P<x>a)?(?(<x>)b|c)`, lower to equivalent
   Swift-compatible alternations for PCRE/auto modes without libpcre2.
   Simple absolute-start literal patterns such as `\Afoo` now preserve later
   matched lines while dropping later-line submatches, matching Rust's
   line-mode only-match, replacement and count behavior. Fixed-literal
   subroutine calls such as `(ab)(?1)`, `(?<pair>ab)(?&pair)` and
   `(?<pair>ab)(?P>pair)` lower in-tree while preserving the original capture
   for replacements. The common balanced-parentheses recursive PCRE shape
   `(?<par>\((?:[^()]++|(?&par))*\))` is handled by a scoped Swift matcher
   that preserves numeric and named replacement captures.
   Plain fixed literal PCRE lookaround/backreference `-P -o` output uses a
   narrow Darwin stdout writer; the 2026-05-26 release smoke measured relative
   `\g{-1}` at 57.6 ms versus Rust PCRE2 release at 73.0 ms on a 900k-line
   synthetic `foofoo` corpus.

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
   the default engine cannot handle now degrade gracefully to the compatibility
   engine. The 2026-05-26 PCRE stress sweep is now 36/36 byte-identical to the
   Rust PCRE2 oracle, but this remains an ongoing quality area because broader
   upstream regex fixture suites can still expose syntax and pathological
   matching gaps outside the covered corpus.
   This is best driven by running upstream regex fixture suites against the
   Swift binary and folding the diffs back into `PatternMatcher.swift` — an
   ongoing quality effort rather than a finite porting slice.

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

**Status: done 2026-05-24.** The buffered non-mmap file path now has a
line-streaming search path for safe non-multiline UTF-8 searches. It reads
64 KiB chunks, carries partial trailing lines across chunk boundaries, and
hands each complete line to the matcher without first accumulating the full
haystack into one `Data`. Multiline, preprocessor, decompressor, stdin,
non-UTF-8/BOM, binary, and other parity-sensitive cases deliberately fall back
to the capped accumulating path.

- [x] Add a streaming line reader for buffered file I/O with chunk carry.
- [x] Route safe `--no-mmap`/buffered file searches through the streaming
      matcher path while preserving the mmap and multiline paths unchanged.
- [x] Enforce a 256 MiB default cap on accumulating buffered reads with the
      diagnostic `haystack size <bytes> exceeds buffered limit <cap>; use
      --mmap or shrink --max-filesize`.
- [x] Add streaming perf/fidelity tests covering a 64 MiB synthetic haystack,
      repeated Sherlock mmap-vs-streaming output, and the buffer-limit guard.

## Wave 4 — open backlog (no scheduled work)

- **(Done 2026-05-24)** True streaming line buffer for safe buffered file
  searches plus a heap cap on accumulating buffered reads (see Wave 3B).
- **(Done 2026-05-24)** Wider encoding probe coverage for GB18030 plane-2,
  Big5-HKSCS extension bytes and EUC-KR.
- **(Done 2026-05-24)** Compressed-input parity probes for `.gz`, `.bz2`,
  `.xz`, `.lzma`, `.br`, `.zst` and `.lz4`.
- Generated-asset refresh automation (`rg.help.*`, `rg.1`, shell
  completions) from the Rust checkout.

## Medium-priority improvements

- **(Done 2026-05-24)** Parity harness gated on `SWIFT_RIPGREP_PARITY=1`
  in `Tests/RipgrepCoreTests/ParityHarnessTests.swift` (fixtures under
  `Tests/Fixtures/parity/`). When the env var is unset the test skips so CI
  stays green; when set it diffs stdout/stderr/exit between
  `.build/debug/ripgrep` and Rust `rg`. Set `SWIFT_RIPGREP_RUST_BINARY` to a
  source-built oracle such as
  `/Users/mweinbach/Projects/swift-harness/ripgrep/target/debug/rg`; build
  that oracle with `cargo build --bin rg --features pcre2` so PCRE2 parity
  cases compare like-for-like.
- **(Done 2026-05-24)** Test split mirroring the Rust upstream layout —
  `BinaryTests`, `FeatureTests`, `JSONTests`, `MiscTests`, `MultilineTests`,
  `RegressionTests`, plus `RipgrepTestSupport` for shared helpers.
- Automate generated asset refresh for `rg.help.*`, `rg.1` and shell
  completions from the Rust checkout, or at least add a drift check.
- Add performance smoke tests for large files, many files, binary detection and
  compressed input before changing the search architecture.
- Grow the parity harness fixture set — current coverage is text, binary,
  gitignored, multiline, UTF-16LE, seven compressed formats and wider legacy
  encodings; extend with a few of the regex pathological cases.
- Keep the next slices narrow and checkpointable: streaming/mmap/parallel
  architecture (high-priority item 4), then asset-refresh automation and
  perf smoke tests.

## Active porting work plan (2026-05-24 orchestration)

Three parallel work items are in flight. Each is owned by one sub-agent. The
streaming/mmap/parallel rearch (item 4 above) is intentionally deferred — it is
a multi-session undertaking that should follow this batch.

### Wave 1A — PCRE2-style compatibility + regex/DFA size limit enforcement
Owner: pair-agent-A. Touches: `Package.swift`,
`Sources/RipgrepCore/PCRE2Matcher.swift`,
`Sources/RipgrepCore/PatternMatcher.swift`, `Sources/RipgrepCore/RipgrepCLI.swift`.

- [x] Remove the libpcre2 dependency from the normal build. The current macOS
      arm64 package links no `CPCRE2` system module, vendored archive,
      Homebrew install, `pkg-config` output or `pcre2-config` output. Keep this
      true with `scripts/check-no-external-deps.sh`.
- [x] Replace the "PCRE2 is not available" error path in
      `PatternMatcher` with a Swift/Foundation-backed compatibility pattern.
      Implement `--engine=pcre2`, `-P`, `--engine=auto` (auto must try the
      default engine first and fall back to the compatibility engine when the
      default rejects the pattern with the auto-hybrid diagnostic).
- [x] Wire `--no-pcre2-unicode` / `--pcre2-unicode` into PCRE2 compile
      compatibility options and `--pcre2-version` to report the built-in
      compatibility engine rather than a linked libpcre2 version.
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
      `.build/debug/ripgrep` and Rust `rg` over a small fixture set
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

- [x] Drive the per-haystack loop with a bounded `TaskGroup`. Explicit
      `--threads N` overrides the automatic default (clamped to ≥1). When
      `N == 1`, fall back to the existing sequential path so behaviour is
      unchanged. The Darwin automatic cap is four workers after Linux tree
      benchmarking; non-Darwin keeps the Rust-style
      `min(ProcessInfo.processInfo.activeProcessorCount, 12)` cap.
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
- [x] Refresh PORTING.md (mark items 4 and the streaming sub-list done; flag
      item 5 / regex-engine-fidelity as the remaining backlog).
- [x] Final parity probes from "Verification commands" against the sibling
      Rust PCRE2 oracle, plus explicit-file probes for `--threads 1` /
      `--threads 4` and file probes for `--mmap` / `--no-mmap`.

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
