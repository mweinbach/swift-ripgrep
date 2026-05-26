# Performance benchmarks vs Rust ripgrep

This folder runs the upstream Rust `ripgrep` benchsuite scenarios with two
contestants: the installed Rust `rg` and the Swift port at
`.build/release/ripgrep`. The result is a direct, 1:1 comparison using
exactly the same patterns, flags, and corpora that BurntSushi uses to
benchmark `rg` against `ag` / `grep` / `git grep` / `ugrep`.

## How it works

We don't fork the upstream benchsuite. `bench_swift_vs_rust.py` exec()'s
the upstream source so its `bench_*` functions and `Command`/`Benchmark`
types are loaded into a private namespace. We then override `Command` to
intercept every `rg` invocation, build a paired `swift-ripgrep` command
with the same args, and run `hyperfine` on the pair.

## Prerequisites

```sh
brew install hyperfine          # benchmark driver
brew install ripgrep             # installs the Rust `rg` baseline
swift build -c release           # builds the Swift port at .build/release/ripgrep
```

To benchmark the Swift fallback path without the in-tree C shim, build with:

```sh
SWIFT_RIPGREP_NO_C_SHIM=1 swift build -c release --build-path .build/no-c-shim
```

You also need the upstream `ripgrep` checkout (for its `benchsuite/benchsuite`
script) and the upstream corpora:

```sh
# Clone Rust ripgrep (needed for benchsuite source).
git clone https://github.com/BurntSushi/ripgrep ~/upstream-ripgrep

# Set up a benchmark workspace.
SUITE_DIR=/tmp/swift-rg-bench
mkdir -p "$SUITE_DIR" "$SUITE_DIR/subtitles"

# Linux kernel corpus (many small files).
git clone --depth 1 https://github.com/BurntSushi/linux "$SUITE_DIR/linux"
# We skip building the kernel; just touch vmlinux so the upstream guard passes.
touch "$SUITE_DIR/linux/vmlinux"

# English subtitles corpus (single huge file).
curl -L -o "$SUITE_DIR/subtitles/en.txt.gz" \
    https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2016/mono/en.txt.gz
gunzip "$SUITE_DIR/subtitles/en.txt.gz"
# Upstream takes a 55M-line slice as the bench input. The full en.txt is
# ~10 GiB; the sample is ~1.6 GiB.
head -n 55000000 "$SUITE_DIR/subtitles/en.txt" > "$SUITE_DIR/subtitles/en.sample.txt"
rm "$SUITE_DIR/subtitles/en.txt"   # only en.sample.txt is used after this

# Copy the upstream benchsuite script next to ours.
cp ~/upstream-ripgrep/benchsuite/benchsuite "$SUITE_DIR/benchsuite.py"
```

## Running the suite

```sh
# Full curated subset (warmup=1, runs=2 — ~90 minutes on an M3 Ultra):
./bench_swift_vs_rust.py \
    --suite-dir   /tmp/swift-rg-bench \
    --rg          $(which rg) \
    --swift-rg    /Users/<you>/path/to/.build/release/ripgrep \
    --benchsuite  /tmp/swift-rg-bench/benchsuite.py \
    --out         /tmp/swift-rg-bench/results \
    --warmup 1 --runs 2

# A single benchmark, for a smoke run:
./bench_swift_vs_rust.py ... --filter subtitles_en_literal --runs 1 --warmup 0
```

The script writes:

- `results/summary.md` — a Markdown table with median runtimes for each
  benchmark/label and the swift/rg ratio.
- `results/summary.json` — same data in machine-readable form.
- `results/hyperfine/*.json` — raw per-bench hyperfine exports for
  detailed inspection.

## What's compared

Every `bench_*` function in the upstream `benchsuite` script that
exercises the `rg` binary produces one or more "labels" — typically the
default invocation, plus variants like `rg (no mmap)`, `rg (lines)`, or
`rg (ASCII)`. The harness mirrors each label against the Swift port and
discards the non-ripgrep tools (ag, grep, ugrep, git grep, …). The
patterns, args, fixtures, and working directories are exactly what the
upstream suite uses, so a ratio of `1.00x` means "matches Rust", not
"matches some other tool".

## Notes on the Russian subtitles corpus

`subtitles_ru_*` benches need `ru.txt` (~10 GiB) from the same OPUS host.
The recipe is identical to the English subtitles setup but uses
`ru.txt.gz`. We skip those by default to save disk and time; the
English subtitles already exercise the matcher's literal/regex/casei
paths.
