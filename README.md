# ripgrep

[![CI](https://github.com/mweinbach/swift-ripgrep/actions/workflows/ci.yml/badge.svg)](https://github.com/mweinbach/swift-ripgrep/actions/workflows/ci.yml)

A Swift executable package for a ripgrep-style command-line search tool.

See [Performance](PERFORMANCE.md) for the latest local Swift-vs-Rust summary,
test-system specifications, methodology, and reproduction commands.

The Linux x86-64, macOS arm64, and Windows x86-64 builds have no
package-manager dependencies. PCRE2-style `-P` searches are handled by the
in-tree Swift compatibility layer. macOS uses a Swift-only Darwin mmap
preflight; its optional comparison C shim is restricted to macOS arm64. Linux
uses a small in-tree C SIMD helper with AVX2 runtime dispatch and an SSE2
fallback. Windows excludes both Darwin preflight sources at the package-target
level. Its self-contained build places a small native launcher in front of the
Swift engine so common literal searches do not pay Foundation's fixed loader
cost; unsupported shapes delegate to the complete Swift implementation.

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
produces a roughly 165 KiB
`.build\windows-static\x86_64-unknown-windows-msvc\release\ripgrep.exe`
launcher and a roughly 69 MB self-contained `ripgrep-swift.exe` backend beside
it. Keep the pair together. The normal `swift build` command remains a single
dynamic Swift executable. CI builds and tests both static files, verifies that
neither imports Swift runtime DLLs, and benchmarks the launcher.

On Linux, the equivalent self-contained Swift-runtime build is:

```sh
swift build --scratch-path .build/linux-static -c release -Xswiftc -static-stdlib
```

CI tests and benchmarks this exact Linux artifact rather than a dynamically
linked development build, and verifies that the selected Linux executable and
both Windows static files do not retain Swift runtime library dependencies.

The self-contained Windows x86-64 launcher handles the benchmark-critical
plain literal, ASCII case-insensitive, word-count, literal-alternation, and
required-literal regex shapes with Win32 mapping/streaming and buffered
`WriteFile` output. Literal and regex validation use AVX2 after runtime feature
detection, with an SSE2/CRT fallback for older x86-64 processors. Unsupported
argument, encoding, binary, console, or file shapes fall back to the full
Swift engine. Set
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

macOS arm64 sorted plain-literal directory searches use a conservative Darwin
preflight for `--files`, matching lines, `-c`, and `-l`. It enumerates and
sorts the complete tree before output, keeps read-only POSIX mappings only for
matched files, and fuses literal, newline, and binary detection into one scan.
The same preflight layer handles count-only `[A-Z][a-z]+\s+LITERAL` searches
with a required-literal scan. Unsupported paths, ignore metadata, encodings,
binary data, or filesystem shapes fall back before output. Set
`SWIFT_RIPGREP_NO_DARWIN_SORTED_PREFLIGHT=1` or
`SWIFT_RIPGREP_NO_DARWIN_CAPITALIZED_COUNT_PREFLIGHT=1` for focused A/B
measurements.

Sorted plain-literal Windows directory searches have a conservative native
preflight for `--files`, no-match line searches, `-c`, and `-l`. It batches
Win32 directory enumeration and file reads, sorts once, and falls back before
output when ignore metadata or an unsupported filesystem/file shape is present.
Other recursive Windows searches use a low-allocation Swift Win32 walker
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
