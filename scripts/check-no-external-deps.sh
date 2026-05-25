#!/usr/bin/env bash
#
# Verify that the normal release build does not depend on an external PCRE2
# package, system-library target, pkg-config entry, Homebrew library, or C API.
#
# Usage:
#     scripts/check-no-external-deps.sh
#     scripts/check-no-external-deps.sh --skip-build
#
# The command is intentionally conservative about hard dependency signals while
# allowing user-facing PCRE2 compatibility flag names and generated ripgrep
# help text to remain in the tree.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

skip_build=0

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
    echo "[deps] ERROR: $*" >&2
    exit 1
}

check_no_match() {
    local label="$1"
    local pattern="$2"
    shift 2

    if grep -En "$pattern" "$@"; then
        fail "$label matched a forbidden external dependency marker"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-build)
            skip_build=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
    shift
done

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/swift-rg-deps.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

echo "[deps] checking SwiftPM manifest..."
check_no_match \
    "Package.swift" \
    'CPCRE2|libpcre|pcre2-config|pkg-config|pkgConfig|systemLibrary|linkerSettings|unsafeFlags|linkedLibrary' \
    "$repo_root/Package.swift"

echo "[deps] checking SwiftPM package graph..."
dependency_graph="$(swift package show-dependencies --format text)"
if [ "$dependency_graph" != "No external dependencies found" ]; then
    echo "$dependency_graph" >&2
    fail "package graph contains external package dependencies"
fi
swift package describe --type json > "$tmp_dir/package.json"
check_no_match \
    "SwiftPM package graph" \
    'CPCRE2|libpcre|pcre2-config|pkg-config|pkgConfig|SystemLibrary|systemLibrary|linkerSettings|unsafeFlags|linkedLibrary' \
    "$tmp_dir/package.json"

echo "[deps] checking source for PCRE C API hooks..."
source_files=()
while IFS= read -r -d '' file; do
    source_files+=("$file")
done < <(
    find "$repo_root/Sources" \
        \( -path '*/Resources/Generated/*' \) -prune -o \
        \( -name '*.swift' -o -name '*.c' -o -name '*.h' \) -print0
)

if [ "${#source_files[@]}" -gt 0 ]; then
    check_no_match \
        "Source files" \
        '^[[:space:]]*#include[[:space:]]+[<"].*pcre|^[[:space:]]*import[[:space:]]+CPCRE2([^[:alnum:]_]|$)|pcre2_[A-Za-z0-9_]+|dlopen[[:space:]]*\([^)]*pcre|dlsym[[:space:]]*\([^)]*pcre' \
        "${source_files[@]}"
fi

echo "[deps] checking for vendored binary libraries..."
vendored_libraries="$(
    find "$repo_root" \
        \( -path "$repo_root/.git" -o -path "$repo_root/.build" \) -prune -o \
        \( -name '*.a' -o -name '*.dylib' -o -name '*.so' \) -print
)"
if [ -n "$vendored_libraries" ]; then
    echo "$vendored_libraries" >&2
    fail "repository contains vendored binary libraries"
fi

binary="$repo_root/.build/release/ripgrep"
if [ "$skip_build" -eq 0 ]; then
    echo "[deps] building release binary..."
    swift build -c release >/dev/null
fi

if [ ! -x "$binary" ]; then
    fail "release binary not found at $binary"
fi

if [ "$(uname -s)" = "Darwin" ]; then
    echo "[deps] checking Darwin release binary architecture..."
    if command -v lipo >/dev/null 2>&1; then
        archs="$(lipo -archs "$binary" 2>/dev/null || true)"
        case " $archs " in
            *" arm64 "*) ;;
            *) fail "release binary is not an arm64 Darwin build (archs: ${archs:-unknown})" ;;
        esac
    fi

    echo "[deps] checking Darwin dynamic libraries..."
    if command -v otool >/dev/null 2>&1; then
        if otool -L "$binary" | grep -Eiq 'libpcre|pcre2|CPCRE2'; then
            otool -L "$binary" >&2
            fail "release binary links an external PCRE library"
        fi
    else
        fail "otool is required on Darwin to verify dynamic library linkage"
    fi
elif command -v ldd >/dev/null 2>&1; then
    echo "[deps] checking dynamic libraries..."
    if ldd "$binary" | grep -Eiq 'libpcre|pcre2|CPCRE2'; then
        ldd "$binary" >&2
        fail "release binary links an external PCRE library"
    fi
fi

echo "[deps] checking binary symbols..."
if command -v nm >/dev/null 2>&1; then
    if nm -a "$binary" 2>/dev/null | grep -E '(^|[^[:alnum:]_])_?pcre2_[[:alnum:]_]+'; then
        fail "release binary contains PCRE2 C API symbols"
    fi
fi

echo "[deps] ok: no external PCRE2, package-manager, system-library, or vendored binary dependency detected."
