# ripgrep

A Swift executable package for a ripgrep-style command-line search tool.

The normal macOS arm64 build has no package-manager or system-library
dependencies. PCRE2-style `-P` searches are handled by the in-tree Swift
compatibility layer, and the default byte-search hot paths are implemented in
Swift with SIMD fallbacks and a Swift-only Darwin mmap preflight.

## Run

```sh
swift run ripgrep needle Sources Tests
```

## Test

```sh
swift test
./scripts/check-no-external-deps.sh
```

## Optional C-Shim Comparison Build

The default build omits the `CRipgrepPlatform` target. Set
`SWIFT_RIPGREP_USE_C_SHIM=1` when building or testing to include the old
Darwin arm C helper target for A/B performance comparison. If both
`SWIFT_RIPGREP_USE_C_SHIM=1` and `SWIFT_RIPGREP_NO_C_SHIM=1` are present, the
Swift-only build wins.
