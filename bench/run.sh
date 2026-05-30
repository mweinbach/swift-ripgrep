#!/bin/bash
set -e
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SUITE_DIR="${SUITE_DIR:-/tmp/swift-rg-bench}"
RG="${RG:-/opt/zerobrew/prefix/bin/rg}"
SWIFT_RG="${SWIFT_RG:-$REPO_ROOT/.build/release/ripgrep}"
OUT="${OUT:-$SUITE_DIR/results}"

mkdir -p "$OUT"

echo "=== Focused bench run ($(date)) ==="
echo "rg: $($RG --version | head -1)"
echo "swift-rg: $($SWIFT_RG --version | head -1)"
echo ""

# Comma-separated curated set
"$SCRIPT_DIR/bench_swift_vs_rust.py" \
    --suite-dir "$SUITE_DIR" \
    --rg "$RG" \
    --swift-rg "$SWIFT_RG" \
    --out "$OUT" \
    --filter linux_literal_default,linux_literal_casei,linux_no_literal,subtitles_en_literal,subtitles_en_literal_casei,subtitles_en_alternate,subtitles_en_no_literal \
    --warmup 1 --runs 1

echo ""
echo "=== Done ($(date)) ==="
