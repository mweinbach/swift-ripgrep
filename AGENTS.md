# swift-ripgrep

A Swift implementation of ripgrep 15.2.0, tracking the Rust upstream at revision `e89fff8`. Built with SwiftPM; produces a single executable that is byte-for-byte output-compatible with `rg` across Linux x86-64, macOS arm64, and Windows x86-64.

## Tech stack & structure

Swift 6.2 package with four targets declared in `Package.swift`:

- **RipgrepCore** (`Sources/RipgrepCore/`) — library: CLI options (`RipgrepOptions`), pattern matching (`PatternMatcher`, PCRE2 compatibility engine), file I/O (`HaystackReader` mmap + chunked streaming, stdin), output formatters (`StandardPrinter`, `JSONPrinter`), traversal, worker pool.
- **ripgrep** (`Sources/ripgrep/`) — executable entry point (`PortableMain.swift`).
- **CRipgrepPlatform** (optional) — C shim for macOS arm64 literal scanning; included when `SWIFT_RIPGREP_USE_C_SHIM=1`. Excluded on non-macOS-arm64.
- **CLinuxPreflight** (conditional) — in-tree C SIMD helper with AVX2 runtime dispatch + SSE2 fallback for Linux x86-64 sorted directory searches (`Sources/CLinuxPreflight/`).
- **RipgrepCoreTests** (`Tests/RipgrepCoreTests/`) — Swift Testing suites mirroring Rust's integration-test split: `BinaryTests`, `FeatureTests`, `JSONTests`, `MiscTests`, `MultilineTests`, `RegressionTests`, plus `HaystackReaderTests`, `WorkerPoolTests`, `EncodingLabelTests`, `GeneratedAssetDriftTests`, and the data-driven `ParityHarnessTests`.

Platform-specific sources are excluded at the target level in `Package.swift` (e.g., `SwiftDarwinLiteralPreflight.swift` on non-macOS, `ripgrep.swift` vs `PortableMain.swift`). The normal build links no external PCRE2/system library; PCRE2 `-P`/`--engine=pcre2` is handled by an in-tree Swift compatibility engine.

## Build & test

```sh
swift run ripgrep needle Sources Tests   # build + run
swift test                              # all suites (excludes parity)
./scripts/check-no-external-deps.sh    # verify no PCRE2/system-library deps
```

Platform-specific release builds:
- Linux self-contained: `swift build --scratch-path .build/linux-static -c release -Xswiftc -static-stdlib`
- Windows static launcher+backend: `.\scripts\build-windows-static.ps1` (requires Swift toolchain with `WindowsExperimental.sdk`)

CI (`.github/workflows/ci.yml`): builds, runs platform tests + Rust parity matrix (`SWIFT_RIPGREP_PARITY=1`), benchmarks via `bench/ci_benchmark.py`, and verifies self-contained binaries have no Swift-runtime DLL dependencies. See [README.md](README.md) for full run/build/test instructions and [PERFORMANCE.md](PERFORMANCE.md) for benchmark methodology/reproduction.

## Verification checklist before pushing

- `swift test` — all suites pass.
- `./scripts/check-no-external-deps.sh --skip-build --binary <path>` — no external deps (CI runs this on Linux/macOS; Windows uses `.\scripts\check-windows-static-deps.ps1`).
- If changing CLI output/help/completions: confirm generated assets are still pinned via `GeneratedAssetDriftTests`, or refresh them with `scripts/refresh-generated-assets.sh`.

## Key files / conventions

- **Options parsing**: `Sources/RipgrepCore/RipgrepCLI.swift` — wires all flags into `RipgrepOptions`; every public CLI flag accepted by Rust ripgrep is parsed.
- **PCRE2 compatibility engine**: `Sources/RipgrepCore/PCRE2Matcher.swift`, integrated in `PatternMatcher.swift`. Plain literals selected through PCRE/auto/default engines bypass the matcher and use default literal fast paths including safely escaped fixed literals (`\Q...\E`) and `\.`/`\[` escapes.
- **File I/O**: `HaystackReader.swift` — mmap for regular files ≥16 KiB (or forced with `--mmap`), 64 KiB chunked streaming otherwise; stdin always buffered. Honors `--max-filesize`.
- **Worker pool**: bounded Swift Concurrency `TaskGroup`, `--threads N` overrides default (Darwin cap=4, else `min(activeProcessorCount, 12)`); deterministic per-walk-order output.
- **Tests use `@testable import RipgrepCore`** with helpers in `RipgrepTestSupport.swift`: `run()`, `runAllowingNoMatch()`, `TemporaryDirectory`, and executable-level runners via `SWIFT_RIPGREP_SWIFT_BINARY` env var.
- **Parity harness** (`ParityHarnessTests`): gated on `SWIFT_RIPGREP_PARITY=1`; diffs stdout/stderr/exit against Rust `rg`. Set `SWIFT_RIPGREP_RUST_BINARY` to a PCRE2-enabled oracle built with `cargo build --bin rg --features pcre2`.

## Docs & deeper reading

- [README.md](README.md) — full run/build/test, platform notes.
- [PERFORMANCE.md](PERFORMANCE.md) — benchmark results and reproduction commands.
- [bench/README.md](bench/README.md) — portable CI suite and upstream corpus workflow.
- [Docs/PORTING.md](Docs/PORTING.md) — porting status, architecture mapping (Rust `grep`/`regex`/`searcher`/... → Swift `RipgrepCore`), PCRE2/encoding/streaming details, intentional divergences from Rust ripgrep 15.2.0.

## Intentional divergences from upstream

- JSON `elapsed`/`elapsed_total`: real timings in Rust, zero in Swift (deterministic output); parity harness strips these before comparing.
- No true streaming line buffer that hands matcher chunks instead of the full file — a Wave 3 optimization, not a correctness gap (mmap avoids heap copy). See [Docs/PORTING.md](Docs/PORTING.md#wave-4--open-backlog-no-scheduled-work).

## Environment variables

| Variable | Purpose |
|---|---|
| `SWIFT_RIPGREP_USE_C_SHIM=1` | Include macOS arm64 C shim target for A/B comparison (Swift-only wins if `NO_C_SHIM=1` also set) |
| `SWIFT_RIPGREP_NO_WINDOWS_X86_PREFLIGHT=1` | Disable Windows x86-64 native launcher preflight |
| `SWIFT_RIPGREP_NO_LINUX_X86_PREFLIGHT=1` | Disable Linux x86-64 executable preflight |
| `SWIFT_RIPGREP_NO_DARWIN_SORTED_PREFLIGHT=1` | Disable macOS sorted literal directory search preflight |
| `SWIFT_RIPGREP_PARITY=1` | Enable parity harness tests (`ParityHarnessTests`) |
| `SWIFT_RIPGREP_SWIFT_BINARY` / `SWIFT_RIPGREP_RUST_BINARY` | Override binary paths for test/parity harness |

## Style note

Follow existing Swift conventions in the file you touch — no separate style guide is needed. The project uses Swift 6 strict concurrency; prefer `@testable import RipgrepCore` and `#expect(...)` from Swift Testing.
