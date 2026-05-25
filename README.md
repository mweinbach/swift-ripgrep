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
```
