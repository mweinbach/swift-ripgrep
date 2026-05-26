# ripgrep

A Swift executable package for a ripgrep-style command-line search tool.

The normal macOS arm64 build has no package-manager or system-library
dependencies. PCRE2-style `-P` searches are handled by the in-tree Swift
compatibility layer, and the small `CRipgrepPlatform` C target contains only
Darwin arm performance helpers for mmap/NEON hot paths.

## Run

```sh
swift run ripgrep needle Sources Tests
```

## Test

```sh
swift test
./scripts/check-no-external-deps.sh
```

## Optional No-C-Shim Build

Set `SWIFT_RIPGREP_NO_C_SHIM=1` when building or testing to omit the
`CRipgrepPlatform` target. This keeps the Swift PCRE2 compatibility engine
available and replaces the shim's hottest byte scanners with Swift SIMD
fallbacks, including a Swift-only Darwin mmap preflight for simple
literal and case-insensitive literal searches. The C-shim build remains the
default macOS configuration until the remaining scanner CPU gap is closed.
