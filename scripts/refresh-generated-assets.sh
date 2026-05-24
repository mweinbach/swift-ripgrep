#!/usr/bin/env bash
#
# Regenerate the help/man/completion assets in
# Sources/RipgrepCore/Resources/Generated/ from the locally built
# ripgrep binary. The binary's `--generate` and `--help`/`-h` output
# is the canonical source of truth — these stored copies exist so
# release builds don't have to re-derive them at runtime.
#
# Usage:
#     scripts/refresh-generated-assets.sh
#
# Run after any change that affects CLI help output, flag definitions,
# or shell completion templates. The companion test
# `GeneratedAssetDriftTests.swift` enforces that the stored assets
# match the binary; running this script clears any drift.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

echo "[refresh] building ripgrep..."
swift build >/dev/null

binary="$repo_root/.build/debug/ripgrep"
out_dir="$repo_root/Sources/RipgrepCore/Resources/Generated"

if [ ! -x "$binary" ]; then
    echo "[refresh] ERROR: built binary not found at $binary" >&2
    exit 1
fi

if [ ! -d "$out_dir" ]; then
    echo "[refresh] ERROR: output directory not found at $out_dir" >&2
    exit 1
fi

regenerate() {
    local kind="$1"
    local dest="$2"
    echo "[refresh] $kind → $dest"
    "$binary" --generate "$kind" > "$dest"
}

regenerate_help() {
    local flag="$1"
    local dest="$2"
    echo "[refresh] $flag → $dest"
    "$binary" "$flag" > "$dest"
}

regenerate man                  "$out_dir/rg.1"
regenerate complete-bash        "$out_dir/rg.bash"
regenerate complete-zsh         "$out_dir/_rg"
regenerate complete-fish        "$out_dir/rg.fish"
regenerate complete-powershell  "$out_dir/_rg.ps1"
regenerate_help -h              "$out_dir/rg.help.short"
regenerate_help --help          "$out_dir/rg.help.long"

echo "[refresh] done."
