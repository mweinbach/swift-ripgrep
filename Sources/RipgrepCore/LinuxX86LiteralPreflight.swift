#if os(Linux) && arch(x86_64)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A conservative executable-level fast path for count-only searches of one
/// explicit regular file. Unsupported shapes fall back to the full engine.
public enum LinuxX86LiteralPreflight {
    private static let maximumBufferedBytes = 512 * 1024 * 1024

    private enum Mode {
        case matchingLines
        case countLines
    }

    private enum PreflightPattern {
        case literal([UInt8])
        case literalAlternation([[UInt8]])
        case capitalizedWordWhitespaceSuffix([UInt8])
    }

    public static func run(arguments: [String]) -> Int32? {
        guard !environmentVariableExists("SWIFT_RIPGREP_NO_LINUX_X86_PREFLIGHT"),
              !environmentVariableExists("RIPGREP_CONFIG_PATH"),
              isatty(STDOUT_FILENO) == 0,
              let parsed = parse(arguments),
              let pattern = preflightPattern(parsed.pattern, mode: parsed.mode) else {
            return nil
        }

        let descriptor = parsed.path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(Int.max) else {
            return nil
        }
        let size = Int(metadata.st_size)
        guard size > 0 else { return 1 }

        if parsed.buffered {
            guard size <= maximumBufferedBytes else { return nil }
            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: size,
                alignment: MemoryLayout<UInt8>.alignment
            )
            defer { storage.deallocate() }
            var bytesRead = 0
            while bytesRead < size {
                let result = read(
                    descriptor,
                    storage.advanced(by: bytesRead),
                    size - bytesRead
                )
                guard result >= 0 else { return nil }
                guard result > 0 else { break }
                bytesRead += result
            }
            guard bytesRead > 0 else { return 1 }
            let bytes = UnsafePointer(storage.assumingMemoryBound(to: UInt8.self))
            return runScan(
                bytes: bytes,
                count: bytesRead,
                mode: parsed.mode,
                pattern: pattern
            )
        }

        guard let mapping = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0),
              mapping != MAP_FAILED else {
            return nil
        }
        defer { _ = munmap(mapping, size) }

        let bytes = UnsafeRawPointer(mapping).assumingMemoryBound(to: UInt8.self)
        return runScan(bytes: bytes, count: size, mode: parsed.mode, pattern: pattern)
    }

    private static func runScan(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        mode: Mode,
        pattern: PreflightPattern
    ) -> Int32? {
        guard canUseBytes(bytes, count: count) else { return nil }
        switch mode {
        case .matchingLines:
            guard case .literal(let literal) = pattern else { return nil }
            return scanLiteralLines(bytes: bytes, count: count, literal: literal)
        case .countLines:
            guard let matchedLines = scanCount(
                bytes: bytes,
                count: count,
                pattern: pattern
            ) else {
                return nil
            }
            guard matchedLines > 0 else { return 1 }
            return writeDecimalLine(matchedLines) ? 0 : nil
        }
    }

    private static func environmentVariableExists(_ name: String) -> Bool {
        name.withCString { getenv($0) != nil }
    }

    private static func parse(
        _ arguments: [String]
    ) -> (mode: Mode, pattern: String, path: String, buffered: Bool)? {
        var argumentIndex = 0
        var buffered = false
        leadingFlags: while argumentIndex < arguments.count {
            switch arguments[argumentIndex] {
            case "--no-config", "--color=never":
                argumentIndex += 1
            case "--no-mmap":
                buffered = true
                argumentIndex += 1
            case "--color":
                guard argumentIndex + 1 < arguments.count,
                      arguments[argumentIndex + 1] == "never" else {
                    return nil
                }
                argumentIndex += 2
            default:
                break leadingFlags
            }
        }
        let remaining = arguments.dropFirst(argumentIndex)
        let mode: Mode
        let pattern: String
        let path: String
        if remaining.count == 2 {
            mode = .matchingLines
            pattern = remaining[remaining.startIndex]
            path = remaining[remaining.index(after: remaining.startIndex)]
        } else if remaining.count == 3,
                  remaining[remaining.startIndex] == "-c"
                    || remaining[remaining.startIndex] == "--count" {
            mode = .countLines
            let patternIndex = remaining.index(after: remaining.startIndex)
            let pathIndex = remaining.index(after: patternIndex)
            pattern = remaining[patternIndex]
            path = remaining[pathIndex]
        } else {
            return nil
        }
        guard !pattern.hasPrefix("-"), path != "-", !path.isEmpty else {
            return nil
        }
        return (mode, pattern, path, buffered)
    }

    private static func plainLiteralBytes(_ pattern: String) -> [UInt8]? {
        guard !pattern.isEmpty,
              !pattern.utf8.contains(0),
              !pattern.contains("\n"),
              !pattern.contains("\r") else {
            return nil
        }
        let regexMetacharacters = "\\.^$*+?()[]{}|"
        guard !pattern.contains(where: { regexMetacharacters.contains($0) }) else {
            return nil
        }
        let bytes = Array(pattern.utf8)
        return bytes.isEmpty ? nil : bytes
    }

    private static func preflightPattern(_ pattern: String, mode: Mode) -> PreflightPattern? {
        if let literal = plainLiteralBytes(pattern) {
            return .literal(literal)
        }
        guard mode == .countLines else { return nil }
        let branches = pattern.split(separator: "|", omittingEmptySubsequences: false)
        if branches.count >= 2, branches.count <= 8 {
            let literals = branches.compactMap { plainLiteralBytes(String($0)) }
            if literals.count == branches.count {
                return .literalAlternation(literals)
            }
        }

        let prefix = #"[A-Z][a-z]+\s+"#
        guard pattern.hasPrefix(prefix) else { return nil }
        let suffix = String(pattern.dropFirst(prefix.count))
        guard let literal = plainLiteralBytes(suffix),
              literal.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        return .capitalizedWordWhitespaceSuffix(literal)
    }

    private static func canUseBytes(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        if count >= 3,
           bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return false
        }
        if count >= 2,
           ((bytes[0] == 0xFF && bytes[1] == 0xFE)
            || (bytes[0] == 0xFE && bytes[1] == 0xFF)) {
            return false
        }
        return memchr(bytes, 0, count) == nil
    }

    private static func scanCount(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        pattern: PreflightPattern
    ) -> Int? {
        switch pattern {
        case .literal(let literal):
            return scanLiteral(bytes: bytes, count: count, literal: literal)
        case .literalAlternation(let literals):
            return scanLiteralAlternation(bytes: bytes, count: count, literals: literals)
        case .capitalizedWordWhitespaceSuffix(let suffix):
            return scanCapitalizedWordWhitespaceSuffix(
                bytes: bytes,
                count: count,
                suffix: suffix
            )
        }
    }

    private static func scanLiteralLines(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        literal: [UInt8]
    ) -> Int32? {
        var foundMatch = false
        var searchOffset = 0
        while searchOffset <= count - literal.count,
              let matchStart = findLiteral(
                bytes: bytes,
                range: searchOffset..<count,
                literal: literal
              ) {
            var lineStart = matchStart
            while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") {
                lineStart -= 1
            }
            let newline = findByte(
                bytes.advanced(by: matchStart),
                count: count - matchStart,
                byte: UInt8(ascii: "\n")
            ).map { matchStart + $0 }
            let lineEnd = newline ?? count
            let outputEnd = newline.map { $0 + 1 } ?? count
            guard matchStart + literal.count <= lineEnd else {
                searchOffset = matchStart + 1
                continue
            }
            guard writeAll(bytes.advanced(by: lineStart), count: outputEnd - lineStart) else {
                return nil
            }
            if newline == nil {
                var newlineByte = UInt8(ascii: "\n")
                guard withUnsafePointer(to: &newlineByte, {
                    writeAll($0, count: 1)
                }) else {
                    return nil
                }
            }
            foundMatch = true
            searchOffset = outputEnd
        }
        return foundMatch ? 0 : 1
    }

    private static func scanLiteral(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        literal: [UInt8]
    ) -> Int {
        var matchedLines = 0
        var searchOffset = 0
        while searchOffset <= count - literal.count,
              let matchStart = findLiteral(
                bytes: bytes,
                range: searchOffset..<count,
                literal: literal
              ) {
            let newline = findByte(
                bytes.advanced(by: matchStart),
                count: count - matchStart,
                byte: UInt8(ascii: "\n")
            ).map { matchStart + $0 }
            let lineEnd = newline ?? count
            guard matchStart + literal.count <= lineEnd else {
                searchOffset = matchStart + 1
                continue
            }
            matchedLines += 1
            searchOffset = newline.map { $0 + 1 } ?? count
        }
        return matchedLines
    }

    private static func scanLiteralAlternation(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        literals: [[UInt8]]
    ) -> Int {
        var matchedLines = 0
        var searchOffset = 0
        while searchOffset < count,
              let match = earliestLiteralMatch(
                bytes: bytes,
                range: searchOffset..<count,
                literals: literals
              ) {
            let newline = findByte(
                bytes.advanced(by: match.start),
                count: count - match.start,
                byte: UInt8(ascii: "\n")
            ).map { match.start + $0 }
            let lineEnd = newline ?? count
            guard match.start + match.length <= lineEnd else {
                searchOffset = match.start + 1
                continue
            }
            matchedLines += 1
            searchOffset = newline.map { $0 + 1 } ?? count
        }
        return matchedLines
    }

    private static func earliestLiteralMatch(
        bytes: UnsafePointer<UInt8>,
        range: Range<Int>,
        literals: [[UInt8]]
    ) -> (start: Int, length: Int)? {
        var earliest: (start: Int, length: Int)?
        for literal in literals {
            guard let start = findLiteral(bytes: bytes, range: range, literal: literal) else {
                continue
            }
            if earliest == nil || start < earliest!.start {
                earliest = (start, literal.count)
            }
        }
        return earliest
    }

    private static func scanCapitalizedWordWhitespaceSuffix(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        suffix: [UInt8]
    ) -> Int? {
        var matchedLines = 0
        var searchOffset = 0
        while searchOffset <= count - suffix.count,
              let suffixStart = findLiteral(
                bytes: bytes,
                range: searchOffset..<count,
                literal: suffix
              ) {
            var lineStart = suffixStart
            while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") {
                lineStart -= 1
            }
            let newline = findByte(
                bytes.advanced(by: suffixStart),
                count: count - suffixStart,
                byte: UInt8(ascii: "\n")
            ).map { suffixStart + $0 }
            let lineEnd = newline ?? count
            let outputEnd = newline.map { $0 + 1 } ?? count
            guard suffixStart + suffix.count <= lineEnd else {
                searchOffset = suffixStart + 1
                continue
            }
            guard let matches = matchesCapitalizedWordWhitespacePrefix(
                bytes: bytes,
                lineStart: lineStart,
                suffixStart: suffixStart
            ) else {
                return nil
            }
            if matches {
                matchedLines += 1
                searchOffset = outputEnd
            } else {
                searchOffset = suffixStart + 1
            }
        }
        return matchedLines
    }

    @inline(__always)
    private static func matchesCapitalizedWordWhitespacePrefix(
        bytes: UnsafePointer<UInt8>,
        lineStart: Int,
        suffixStart: Int
    ) -> Bool? {
        var cursor = suffixStart
        var foundWhitespace = false
        while cursor > lineStart {
            let byte = bytes[cursor - 1]
            if byte >= 0x80 { return nil }
            guard isASCIIWhitespace(byte) else { break }
            foundWhitespace = true
            cursor -= 1
        }
        guard foundWhitespace else { return false }

        let lowercaseEnd = cursor
        while cursor > lineStart {
            let byte = bytes[cursor - 1]
            guard byte >= UInt8(ascii: "a"), byte <= UInt8(ascii: "z") else {
                break
            }
            cursor -= 1
        }
        guard cursor < lowercaseEnd, cursor > lineStart else { return false }
        let uppercase = bytes[cursor - 1]
        return uppercase >= UInt8(ascii: "A") && uppercase <= UInt8(ascii: "Z")
    }

    @inline(__always)
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || (byte >= 0x09 && byte <= 0x0D)
    }

    @inline(__always)
    private static func findByte(
        _ bytes: UnsafePointer<UInt8>,
        count: Int,
        byte: UInt8
    ) -> Int? {
        guard count > 0,
              let rawFound = memchr(bytes, Int32(byte), count) else {
            return nil
        }
        let found = UnsafeRawPointer(rawFound).assumingMemoryBound(to: UInt8.self)
        return bytes.distance(to: found)
    }

    @inline(__always)
    private static func findLiteral(
        bytes: UnsafePointer<UInt8>,
        range: Range<Int>,
        literal: [UInt8]
    ) -> Int? {
        guard range.count >= literal.count, let first = literal.first else { return nil }
        let lastStart = range.upperBound - literal.count
        var searchOffset = range.lowerBound
        while searchOffset <= lastStart,
              let rawFound = memchr(
                bytes.advanced(by: searchOffset),
                Int32(first),
                lastStart - searchOffset + 1
              ) {
            let found = UnsafeRawPointer(rawFound).assumingMemoryBound(to: UInt8.self)
            let candidate = bytes.distance(to: found)
            if literalMatches(bytes: bytes, at: candidate, literal: literal) {
                return candidate
            }
            searchOffset = candidate + 1
        }
        return nil
    }

    @inline(__always)
    private static func literalMatches(
        bytes: UnsafePointer<UInt8>,
        at offset: Int,
        literal: [UInt8]
    ) -> Bool {
        for index in literal.indices where bytes[offset + index] != literal[index] {
            return false
        }
        return true
    }

    private static func writeDecimalLine(_ value: Int) -> Bool {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
            var cursor = buffer.count - 1
            buffer[cursor] = UInt8(ascii: "\n")
            var value = value
            repeat {
                cursor -= 1
                buffer[cursor] = UInt8(value % 10) + UInt8(ascii: "0")
                value /= 10
            } while value > 0
            return writeAll(
                buffer.baseAddress!.advanced(by: cursor),
                count: buffer.count - cursor
            )
        }
    }

    private static func writeAll(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let written = write(STDOUT_FILENO, bytes.advanced(by: offset), count - offset)
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}
#endif
