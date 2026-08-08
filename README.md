# ripgrep

[![CI](https://github.com/mweinbach/swift-ripgrep/actions/workflows/ci.yml/badge.svg)](https://github.com/mweinbach/swift-ripgrep/actions/workflows/ci.yml)

A Swift executable package for a ripgrep-style command-line search tool.

The normal macOS arm64 and Windows x86-64 builds have no package-manager
dependencies. PCRE2-style `-P` searches are handled by the in-tree Swift
compatibility layer, and the default byte-search hot paths are implemented in
Swift with SIMD fallbacks. macOS additionally uses a Swift-only Darwin mmap
preflight; its optional C shim is restricted to macOS arm64. Windows excludes
both Darwin preflight sources at the package-target level and uses
Foundation-backed mapped reads, Win32 directory enumeration, native Windows
encoding conversion, and portable raw-byte literal/regex count paths.

## Run

```sh
swift run ripgrep needle Sources Tests
```

On Windows, run the same commands from a Swift-enabled Developer PowerShell.
SwiftPM produces `.build\x86_64-unknown-windows-msvc\debug\ripgrep.exe` when
the `.build\debug` convenience link is unavailable.

For a release executable that does not load the Swift or Foundation DLLs at
startup, use the opt-in static Windows build:

```powershell
.\scripts\build-windows-static.ps1
```

This requires a Swift toolchain containing `WindowsExperimental.sdk` and
produces
`.build\windows-static\x86_64-unknown-windows-msvc\release\ripgrep.exe`.
The static executable starts and runs short searches about 10–15% faster on
the benchmark machine, but is approximately 68 MB instead of 7.2 MB, so the
normal dynamic build remains the default.

Windows x86-64 builds also use an executable-level fast path for a plain
literal searched in one explicit regular file. It maps the file with Win32,
uses Swift `SIMD16<UInt8>` scans, and batches output through `WriteFile` for
plain output, `-n`, `-c`, `--count-matches`, `-q`, `-l`, and
`--files-without-match`. Unsupported argument, encoding, binary, console, or
file shapes fall back to the full search engine. Set
`SWIFT_RIPGREP_NO_WINDOWS_X86_PREFLIGHT=1` to disable it for A/B measurements.

Recursive Windows searches use a low-allocation Win32 walker that carries
`WIN32_FIND_DATAW` file sizes directly into the parallel search pipeline,
avoiding per-entry Foundation metadata and path-normalization calls. Plain and
ASCII case-insensitive literals then use the same match-driven Swift SIMD
scanners as the optimized Darwin path. `--files` uses the walker with batched
pathname output. The generic Windows build deliberately remains on the
x86-64/SSE2 baseline: forcing Swift's `core-avx2` target did not improve the
measured searches.

## Test

```sh
swift test
./scripts/check-no-external-deps.sh
```

GitHub Actions runs builds, platform tests, Rust parity checks, and
generated-corpus Swift-vs-Rust benchmarks on Linux x86-64, macOS arm64, and
Windows x86-64. The full parity harness runs on Linux and macOS; Windows runs
its stable platform suites and byte-checks every timed benchmark case.
Each run publishes the benchmark JSON and Markdown tables as workflow artifacts;
see [bench/README.md](bench/README.md) for local and full-corpus commands.

## Optional C-Shim Comparison Build

The default build omits the `CRipgrepPlatform` target. Set
`SWIFT_RIPGREP_USE_C_SHIM=1` when building or testing to include the old
Darwin arm C helper target for A/B performance comparison. If both
`SWIFT_RIPGREP_USE_C_SHIM=1` and `SWIFT_RIPGREP_NO_C_SHIM=1` are present, the
Swift-only build wins.
