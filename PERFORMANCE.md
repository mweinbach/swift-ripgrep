# Performance

Swift ripgrep is faster than Rust ripgrep in every case in the current
Windows AMD64 CI benchmark matrix on the development machine. Across all 12
cases, its geometric-mean elapsed-time ratio is **0.813x**: **18.7% less
elapsed time**, equivalent to about **1.23x the throughput** for this workload.

These results were recorded on August 9, 2026, from commit
[`fc0efd7`](https://github.com/mweinbach/swift-ripgrep/commit/fc0efd714f37bb1e191ab1de292300ce37a4668f).

## Results

Lower elapsed time and a lower Swift/Rust ratio are better. A ratio below
`1.000x` means Swift completed the case faster than Rust.

| Benchmark | Rust median | Swift median | Swift/Rust | Elapsed-time reduction |
|---|---:|---:|---:|---:|
| Literal search | 63.41 ms | 56.95 ms | **0.898x** | 10.2% |
| Literal search, no mmap | 32.73 ms | 27.82 ms | **0.850x** | 15.0% |
| Literal count | 62.33 ms | 56.39 ms | **0.905x** | 9.5% |
| ASCII case-insensitive literal count | 69.69 ms | 64.48 ms | **0.925x** | 7.5% |
| Word count | 131.41 ms | 73.51 ms | **0.559x** | 44.1% |
| Literal-alternation count | 70.99 ms | 67.98 ms | **0.958x** | 4.2% |
| Required-literal regex count | 61.02 ms | 57.74 ms | **0.946x** | 5.4% |
| No-match literal search | 61.14 ms | 58.99 ms | **0.965x** | 3.5% |
| Recursive literal count | 19.72 ms | 13.55 ms | **0.687x** | 31.3% |
| Recursive files with matches | 16.93 ms | 13.20 ms | **0.780x** | 22.0% |
| Recursive no-match search | 19.26 ms | 13.37 ms | **0.694x** | 30.6% |
| Recursive file listing | 10.41 ms | 7.44 ms | **0.715x** | 28.5% |
| **Geometric mean** | | | **0.813x** | **18.7%** |

## Test system

| Component | Specification |
|---|---|
| System | AMD `RAH-001` |
| CPU | AMD Ryzen AI Max+ 395 with Radeon 8060S, 16 cores / 32 logical processors |
| Memory | 63.79 GiB usable (64 GB class) |
| Storage | 2.05 TB Micron 4600 (`Micron_4600_MTFDLBA2T0THJ`) |
| Operating system | Microsoft Windows 11 Pro, version 10.0.26200, build 26200 |
| Architecture | Windows AMD64 / x86-64 |
| Swift toolchain | Swift 6.3.3 release toolchain with assertions enabled |
| Benchmark driver | Python 3.13.5 |
| Rust baseline | ripgrep 15.2.0, revision `e89fff89ac` |
| Swift implementation version | ripgrep-compatible 15.2.0, revision `e89fff89ac` |

The Swift contestant was the self-contained release build produced by
`scripts/build-windows-static.ps1`: a 168,448-byte native launcher and a
69,199,872-byte static Swift backend. The dependency check confirmed that
neither executable imports Swift runtime DLLs.

## Methodology

The portable benchmark harness generated a 128 MiB single-file corpus and a
32 MiB recursive tree on the local system drive. Each contestant received two
warmup runs followed by seven measured runs. Contestants were interleaved to
reduce ordering bias, and the table reports the median of each set.

Before timing, the harness checked stdout, stderr, and exit status byte for
byte for every case. The accompanying Windows test selection also passed all
25 tests, covering encoding labels, readers, worker-pool determinism,
generated assets, native executable fast paths, recursive output, and count
semantics.

To reproduce the comparison after building the self-contained Windows
artifact:

```powershell
python bench/install_rust_rg.py --version 15.2.0 --destination .ci-tools
./scripts/build-windows-static.ps1 `
  -Configuration release `
  -ScratchPath .build/local-windows-static
$env:SWIFT_RIPGREP_WINDOWS_NATIVE_ONLY = "1"
python bench/ci_benchmark.py `
  --rg .ci-tools/rg.exe `
  --swift-rg .build/local-windows-static/x86_64-unknown-windows-msvc/release/ripgrep.exe `
  --out benchmark-results `
  --warmup 2 `
  --runs 7 `
  --corpus-mib 128 `
  --tree-mib 32
```

## Scope and interpretation

This is a reproducible snapshot, not a universal speed claim. It measures the
12 generated-corpus shapes in the Windows native fast-path CI matrix on one
machine. Filesystems, CPU power state, background activity, corpus shape,
match density, command options, and fallback into the full Swift engine can
change the result. Small differences on shared or interactive machines should
be treated as noise until repeated.

GitHub Actions runs the same correctness-first benchmark matrix on Windows,
Linux, and macOS and uploads the raw JSON and Markdown results for every run.
See [`bench/README.md`](bench/README.md) for the portable CI suite and the
larger upstream ripgrep corpus workflow.
