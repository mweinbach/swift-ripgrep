# ripgrep

[![CI](https://github.com/mweinbach/swift-ripgrep/actions/workflows/ci.yml/badge.svg)](https://github.com/mweinbach/swift-ripgrep/actions/workflows/ci.yml)

A Swift executable package for a ripgrep-style command-line search tool.

The Linux x86-64, macOS arm64, and Windows x86-64 builds have no
package-manager dependencies. PCRE2-style `-P` searches are handled by the
in-tree Swift compatibility layer. macOS uses a Swift-only Darwin mmap
preflight; its optional comparison C shim is restricted to macOS arm64. Linux
uses a small in-tree C SIMD helper with AVX2 runtime dispatch and an SSE2
fallback. Windows excludes both Darwin preflight sources at the package-target
level and uses
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
the benchmark machine, but is approximately 69 MB instead of 8 MB, so the
normal `swift build` command remains dynamic. CI builds, executable-tests, and
benchmarks the self-contained static Windows artifact.

On Linux, the equivalent self-contained Swift-runtime build is:

```sh
swift build --scratch-path .build/linux-static -c release -Xswiftc -static-stdlib
```

CI tests and benchmarks this exact Linux artifact rather than a dynamically
linked development build, and verifies that the selected Linux and Windows
executables do not retain Swift runtime library dependencies.

Windows x86-64 builds also use an executable-level fast path for a plain
literal searched in one explicit regular file. It maps the file with Win32,
uses Swift `SIMD16<UInt8>` scans, and batches output through `WriteFile` for
plain output, `-n`, `-c`, `--count-matches`, `-q`, `-l`, and
`--files-without-match`. Unsupported argument, encoding, binary, console, or
file shapes fall back to the full search engine. Set
`SWIFT_RIPGREP_NO_WINDOWS_X86_PREFLIGHT=1` to disable it for A/B measurements.
Plain redirected `--no-mmap` output uses a bounded one-pass Win32 reader that
keeps incomplete lines across chunks and buffers matches until binary and BOM
validation succeeds.

Linux x86-64 builds use a similarly conservative executable preflight for a
plain literal searched in one explicit regular file and for count-only plain,
literal-alternation, and required-literal regex searches. It uses POSIX `mmap`
for normal reads, a 1 MiB streaming reader for `--no-mmap`, vector-filtered
literal and ASCII case-insensitive scans, and buffered direct output. Sorted
plain-literal directory searches for `--files`, matching lines, `-c`, and `-l`
use direct POSIX enumeration, one path-component sort, and read-only file
mappings. Binary, encoded, configured, console, non-ASCII-path, ignore-aware,
symlinked, non-regular, or unsupported argument shapes fall back to the full
engine. Set `SWIFT_RIPGREP_NO_LINUX_X86_PREFLIGHT=1` to disable it for A/B
measurements.

Sorted plain-literal Windows directory searches have a conservative executable
preflight for `--files`, matching lines, `-c`, and `-l`. It batches Win32
directory enumeration and file reads, sorts once by path components, and falls
back before output when ignore metadata or an unsupported filesystem/file shape
is present. Other recursive Windows searches use a low-allocation Win32 walker
that carries `WIN32_FIND_DATAW` file sizes directly into the parallel search pipeline,
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
Windows x86-64. Linux and Windows use their self-contained release artifacts;
macOS uses the normal release build. The full parity harness runs on Linux and
macOS; Windows runs its stable platform suites and byte-checks every timed
benchmark case.
Each run publishes the benchmark JSON and Markdown tables as workflow artifacts;
see [bench/README.md](bench/README.md) for local and full-corpus commands.

## Optional C-Shim Comparison Build

The default build omits the `CRipgrepPlatform` target. Set
`SWIFT_RIPGREP_USE_C_SHIM=1` when building or testing to include the old
Darwin arm C helper target for A/B performance comparison. If both
`SWIFT_RIPGREP_USE_C_SHIM=1` and `SWIFT_RIPGREP_NO_C_SHIM=1` are present, the
Swift-only build wins.
