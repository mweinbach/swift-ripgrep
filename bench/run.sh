#!/bin/bash
set -e
SUITE_DIR=/tmp/swift-rg-bench
RG=/opt/zerobrew/prefix/bin/rg
SWIFT_RG=/Users/mweinbach/Projects/swift-harness/swift-ripgrep/.build/release/ripgrep
OUT=/tmp/swift-rg-bench/results
mkdir -p $OUT

echo "=== Focused bench run ($(date)) ==="
echo "rg: $($RG --version | head -1)"
echo "swift-rg: $($SWIFT_RG --version | head -1)"
echo ""

# Comma-separated curated set
$SUITE_DIR/bench_swift_vs_rust.py \
    --suite-dir $SUITE_DIR \
    --rg $RG \
    --swift-rg $SWIFT_RG \
    --out $OUT \
    --filter linux_literal_default,linux_literal_casei,linux_no_literal,subtitles_en_literal,subtitles_en_literal_casei,subtitles_en_alternate,subtitles_en_no_literal \
    --warmup 1 --runs 1

echo ""
echo "=== Done ($(date)) ==="
