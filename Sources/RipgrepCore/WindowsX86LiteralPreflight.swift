import Foundation

#if os(Windows) && arch(x86_64)
import CRT
import WinSDK

/// A narrow executable-level fast path for one plain literal and one explicit
/// regular file. Unsupported shapes return `nil` and use the full engine.
public enum WindowsX86LiteralPreflight {
    private enum Mode {
        case matchingLines
        case lineNumbered
        case countLines
        case countMatches
        case quiet
        case filesWithMatches
        case filesWithoutMatch
    }

    public static func run(arguments: [String]) -> Int32? {
        guard !environmentVariableExists("SWIFT_RIPGREP_NO_WINDOWS_X86_PREFLIGHT"),
              !environmentVariableExists("RIPGREP_CONFIG_PATH"),
              _isatty(_fileno(stdout)) == 0,
              let parsed = parse(arguments),
              let literal = plainLiteralBytes(parsed.pattern) else {
            return nil
        }

        return parsed.path.withCString(encodedAs: UTF16.self) { path in
            guard let file = CreateFileW(
                path,
                DWORD(GENERIC_READ),
                DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN),
                nil
            ), file != INVALID_HANDLE_VALUE else {
                return nil
            }
            defer { CloseHandle(file) }

            var sizeHigh: DWORD = 0
            SetLastError(DWORD(NO_ERROR))
            let sizeLow = GetFileSize(file, &sizeHigh)
            guard sizeLow != DWORD(INVALID_FILE_SIZE) || GetLastError() == DWORD(NO_ERROR) else {
                return nil
            }
            let size64 = (UInt64(sizeHigh) << 32) | UInt64(sizeLow)
            guard size64 <= UInt64(Int.max) else {
                return nil
            }
            let size = Int(size64)
            if size == 0 {
                return finish(
                    mode: parsed.mode,
                    path: parsed.path,
                    matchedLines: 0,
                    totalMatches: 0
                )
            }

            guard let mapping = CreateFileMappingW(file, nil, DWORD(PAGE_READONLY), 0, 0, nil) else {
                return nil
            }
            defer { CloseHandle(mapping) }
            guard let view = MapViewOfFile(mapping, DWORD(FILE_MAP_READ), 0, 0, 0) else {
                return nil
            }
            defer { UnmapViewOfFile(view) }

            let bytes = view.assumingMemoryBound(to: UInt8.self)
            guard canUseMappedBytes(bytes, count: size) else {
                return nil
            }
            return scan(
                bytes: bytes,
                count: size,
                literal: literal,
                path: parsed.path,
                mode: parsed.mode
            )
        }
    }

    private static func environmentVariableExists(_ name: String) -> Bool {
        SetLastError(DWORD(NO_ERROR))
        let length = name.withCString(encodedAs: UTF16.self) {
            GetEnvironmentVariableW($0, nil, 0)
        }
        return length > 0 || GetLastError() != DWORD(ERROR_ENVVAR_NOT_FOUND)
    }

    private static func parse(_ arguments: [String]) -> (mode: Mode, pattern: String, path: String)? {
        var argumentIndex = 0
        leadingFlags: while argumentIndex < arguments.count {
            switch arguments[argumentIndex] {
            case "--no-config", "--color=never":
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
        let arguments = Array(arguments.dropFirst(argumentIndex))
        let mode: Mode
        let pattern: String
        let path: String
        if arguments.count == 2 {
            mode = .matchingLines
            pattern = arguments[0]
            path = arguments[1]
        } else if arguments.count == 3 {
            switch arguments[0] {
            case "-n", "--line-number": mode = .lineNumbered
            case "-c", "--count": mode = .countLines
            case "--count-matches": mode = .countMatches
            case "-q", "--quiet": mode = .quiet
            case "-l", "--files-with-matches": mode = .filesWithMatches
            case "--files-without-match": mode = .filesWithoutMatch
            default: return nil
            }
            pattern = arguments[1]
            path = arguments[2]
        } else {
            return nil
        }
        guard !pattern.hasPrefix("-"), path != "-", !path.isEmpty else {
            return nil
        }
        return (mode, pattern, path)
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

    private static func canUseMappedBytes(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        if count >= 3,
           bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return false
        }
        if count >= 2,
           ((bytes[0] == 0xFF && bytes[1] == 0xFE)
            || (bytes[0] == 0xFE && bytes[1] == 0xFF)) {
            return false
        }
        return findByte(bytes, count: count, byte: 0) == nil
    }

    private static func scan(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        literal: [UInt8],
        path: String,
        mode: Mode
    ) -> Int32? {
        if mode != .lineNumbered {
            return scanGlobalLiteral(
                bytes: bytes,
                count: count,
                literal: literal,
                path: path,
                mode: mode
            )
        }
        var writer: Win32OutputBuffer?
        if mode == .matchingLines || mode == .lineNumbered {
            writer = Win32OutputBuffer(capacity: 256 * 1024)
            guard writer != nil else { return nil }
        }
        defer { writer?.deallocate() }

        var matchedLines = 0
        var totalMatches = 0
        var lineNumber = 1
        var lineStart = 0
        while lineStart < count {
            let newline = findByte(
                bytes.advanced(by: lineStart),
                count: count - lineStart,
                byte: UInt8(ascii: "\n")
            ).map { lineStart + $0 }
            let lineEnd = newline ?? count
            let outputEnd = newline.map { $0 + 1 } ?? count

            var lineMatches = 0
            var searchStart = lineStart
            while searchStart <= lineEnd - literal.count,
                  let match = findLiteral(bytes: bytes, range: searchStart..<lineEnd, literal: literal) {
                lineMatches += 1
                if mode != .countMatches { break }
                searchStart = match + literal.count
            }

            if lineMatches > 0 {
                matchedLines += 1
                totalMatches += lineMatches
                switch mode {
                case .quiet:
                    return 0
                case .filesWithMatches:
                    guard writePath(path) else { return 2 }
                    return 0
                case .matchingLines, .lineNumbered:
                    if mode == .lineNumbered,
                       !(writer?.writeDecimal(lineNumber, terminator: UInt8(ascii: ":")) ?? false) {
                        return 2
                    }
                    guard writer?.write(bytes.advanced(by: lineStart), count: outputEnd - lineStart) == true else {
                        return 2
                    }
                    if newline == nil,
                       !(writer?.writeByte(UInt8(ascii: "\n")) ?? false) {
                        return 2
                    }
                case .countLines, .countMatches, .filesWithoutMatch:
                    break
                }
            }
            lineStart = outputEnd
            lineNumber += 1
        }

        guard writer?.flush() ?? true else { return 2 }
        return finish(
            mode: mode,
            path: path,
            matchedLines: matchedLines,
            totalMatches: totalMatches
        )
    }

    private static func finish(
        mode: Mode,
        path: String,
        matchedLines: Int,
        totalMatches: Int
    ) -> Int32? {
        let hasMatch = matchedLines > 0
        switch mode {
        case .countLines where hasMatch:
            return writeDecimalLine(matchedLines) ? 0 : nil
        case .countMatches where hasMatch:
            return writeDecimalLine(totalMatches) ? 0 : nil
        case .filesWithoutMatch where !hasMatch:
            return writePath(path) ? 0 : nil
        case .matchingLines, .lineNumbered:
            return hasMatch ? 0 : 1
        case .filesWithoutMatch:
            return 1
        case .quiet, .filesWithMatches, .countLines, .countMatches:
            return hasMatch ? 0 : 1
        }
    }

    private static func scanGlobalLiteral(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        literal: [UInt8],
        path: String,
        mode: Mode
    ) -> Int32? {
        var writer: Win32OutputBuffer?
        if mode == .matchingLines {
            writer = Win32OutputBuffer(capacity: 256 * 1024)
            guard writer != nil else { return nil }
        }
        defer { writer?.deallocate() }

        var matchedLines = 0
        var totalMatches = 0
        var searchOffset = 0
        var lastMatchedLineStart = -1
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

            if lineStart != lastMatchedLineStart {
                matchedLines += 1
                lastMatchedLineStart = lineStart
                switch mode {
                case .quiet:
                    return 0
                case .filesWithMatches:
                    guard writePath(path) else { return 2 }
                    return 0
                case .matchingLines:
                    guard writer?.write(bytes.advanced(by: lineStart), count: outputEnd - lineStart) == true else {
                        return 2
                    }
                    if newline == nil,
                       !(writer?.writeByte(UInt8(ascii: "\n")) ?? false) {
                        return 2
                    }
                case .countLines, .countMatches, .filesWithoutMatch:
                    break
                case .lineNumbered:
                    return nil
                }
            }

            totalMatches += 1
            searchOffset = mode == .countMatches
                ? matchStart + literal.count
                : outputEnd
        }

        if mode == .matchingLines,
           !(writer?.flush() ?? false) {
            return 2
        }
        let hasMatch = matchedLines > 0
        switch mode {
        case .matchingLines:
            return hasMatch ? 0 : 1
        case .countLines:
            guard writeDecimalLine(matchedLines) else { return 2 }
            return hasMatch ? 0 : 1
        case .countMatches:
            guard writeDecimalLine(totalMatches) else { return 2 }
            return hasMatch ? 0 : 1
        case .filesWithoutMatch:
            if !hasMatch {
                guard writePath(path) else { return 2 }
                return 0
            }
            return 1
        case .quiet, .filesWithMatches:
            return 1
        case .lineNumbered:
            return nil
        }
    }

    private static func writeDecimalLine(_ value: Int) -> Bool {
        guard var output = Win32OutputBuffer(capacity: 64) else { return false }
        defer { output.deallocate() }
        return output.writeDecimal(value, terminator: UInt8(ascii: "\n")) && output.flush()
    }

    private static func writePath(_ path: String) -> Bool {
        guard var output = Win32OutputBuffer(capacity: max(256, path.utf8.count + 1)) else {
            return false
        }
        defer { output.deallocate() }
        var path = path
        let wrote = path.withUTF8 { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            return output.write(base, count: bytes.count)
        }
        return wrote && output.writeByte(UInt8(ascii: "\n")) && output.flush()
    }

    @inline(__always)
    private static func findByte(
        _ bytes: UnsafePointer<UInt8>,
        count: Int,
        byte: UInt8
    ) -> Int? {
        guard count > 0 else { return nil }
        let needle = SIMD16<UInt8>(repeating: byte)
        var offset = 0
        while offset + 16 <= count {
            let block = UnsafeRawPointer(bytes.advanced(by: offset))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let matches = block .== needle
            if matches._storage.min() < 0 {
                for lane in 0..<16 where bytes[offset + lane] == byte {
                    return offset + lane
                }
            }
            offset += 16
        }
        while offset < count {
            if bytes[offset] == byte { return offset }
            offset += 1
        }
        return nil
    }

    @inline(__always)
    private static func findLiteral(
        bytes: UnsafePointer<UInt8>,
        range: Range<Int>,
        literal: [UInt8]
    ) -> Int? {
        guard range.count >= literal.count, let first = literal.first else { return nil }
        let lastStart = range.upperBound - literal.count
        let needle = SIMD16<UInt8>(repeating: first)
        var offset = range.lowerBound
        while offset + 15 <= lastStart {
            let block = UnsafeRawPointer(bytes.advanced(by: offset))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let matches = block .== needle
            if matches._storage.min() < 0 {
                for lane in 0..<16 {
                    let candidate = offset + lane
                    if bytes[candidate] == first,
                       literalMatches(bytes: bytes, at: candidate, literal: literal) {
                        return candidate
                    }
                }
            }
            offset += 16
        }
        while offset <= lastStart {
            if bytes[offset] == first,
               literalMatches(bytes: bytes, at: offset, literal: literal) {
                return offset
            }
            offset += 1
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

    private struct Win32OutputBuffer {
        private let storage: UnsafeMutablePointer<UInt8>
        private let capacity: Int
        private var length = 0
        private let output: HANDLE

        init?(capacity: Int) {
            guard capacity > 0,
                  let output = GetStdHandle(STD_OUTPUT_HANDLE),
                  output != INVALID_HANDLE_VALUE else {
                return nil
            }
            self.capacity = capacity
            self.storage = .allocate(capacity: capacity)
            self.output = output
        }

        mutating func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
            guard count > 0 else { return true }
            if count > capacity {
                return flush() && writeDirect(bytes, count: count)
            }
            if length + count > capacity, !flush() { return false }
            storage.advanced(by: length).update(from: bytes, count: count)
            length += count
            return true
        }

        mutating func writeByte(_ byte: UInt8) -> Bool {
            if length == capacity, !flush() { return false }
            storage[length] = byte
            length += 1
            return true
        }

        mutating func writeDecimal(_ value: Int, terminator: UInt8) -> Bool {
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
                var cursor = buffer.count
                var value = value
                repeat {
                    cursor -= 1
                    buffer[cursor] = UInt8(value % 10) + UInt8(ascii: "0")
                    value /= 10
                } while value > 0
                guard write(buffer.baseAddress!.advanced(by: cursor), count: buffer.count - cursor) else {
                    return false
                }
                return writeByte(terminator)
            }
        }

        mutating func flush() -> Bool {
            guard length > 0 else { return true }
            guard writeDirect(storage, count: length) else { return false }
            length = 0
            return true
        }

        private func writeDirect(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
            var offset = 0
            while offset < count {
                let chunk = min(count - offset, Int(DWORD.max))
                var written: DWORD = 0
                guard WriteFile(output, bytes.advanced(by: offset), DWORD(chunk), &written, nil),
                      written > 0 else {
                    return false
                }
                offset += Int(written)
            }
            return true
        }

        func deallocate() {
            storage.deallocate()
        }
    }
}

#else

public enum WindowsX86LiteralPreflight {
    public static func run(arguments: [String]) -> Int32? { nil }
}

#endif
