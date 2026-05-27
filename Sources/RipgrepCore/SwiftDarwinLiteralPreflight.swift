import Foundation

#if !canImport(CRipgrepPlatform) && canImport(Darwin)
import Darwin

public enum SwiftDarwinLiteralPreflight {
    public static func exitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        lineNumber: Bool = false,
        asciiBoundary: Bool = false
    ) -> Int32? {
        guard !literal.isEmpty else {
            return nil
        }
        if asciiCaseInsensitive, literal.contains(where: { $0 >= 0x80 }) {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWriteLiteralBytes(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                asciiCaseInsensitive: asciiCaseInsensitive,
                lineNumber: lineNumber,
                asciiBoundary: asciiBoundary
            )
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func streamingExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        lineNumber: Bool = false
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")) else {
            return nil
        }
        if asciiCaseInsensitive, literal.contains(where: { $0 >= 0x80 }) {
            return nil
        }
        return streamingLiteralExitCode(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            lineNumber: lineNumber
        )
    }

    public static func wordLineNumberExitCode(
        path: String,
        literal: [UInt8]
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              let first = literal.first,
              let last = literal.last,
              rgSwiftIsASCIIRegexWordByte(first),
              rgSwiftIsASCIIRegexWordByte(last) else {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWriteWordLiteralLineNumberBytes(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer
            )
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func surroundingWordsExitCode(
        path: String,
        literal: [UInt8],
        lineNumber: Bool,
        asciiOnly: Bool
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              literal.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWriteSurroundingWordsBytes(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                lineNumber: lineNumber,
                asciiOnly: asciiOnly
            )
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func multiLiteralExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool = false
    ) -> Int32? {
        guard let result = multiLiteralResult(
            path: path,
            literals: literals,
            maxCount: nil,
            lineNumber: lineNumber
        ) else {
            return nil
        }
        guard result.status >= 0 else {
            return nil
        }
        return result.matched_line_count > 0 ? 0 : 1
    }

    private static func streamingLiteralExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        lineNumber: Bool
    ) -> Int32? {
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            return nil
        }
        defer {
            try? handle.close()
        }

        var matchedLineCount = 0
        var carry = Data()
        var bytesCheckedForNUL = 0
        var isFirstChunk = true
        var rejected = false
        var writeFailed = false
        var currentLineNumber = 1
        let newlineByte = UInt8(ascii: "\n")
        let foldedLiteral = asciiCaseInsensitive ? literal.map(rgSwiftASCIILower) : []
        var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
        if asciiCaseInsensitive, foldedLiteral.count > 1 {
            for index in 0..<(foldedLiteral.count - 1) {
                caseInsensitiveShifts[Int(foldedLiteral[index])] = literal.count - 1 - index
            }
        }

        func appendCarry(_ bytes: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else {
                return
            }
            guard carry.count + count <= HaystackReader.defaultMaxBufferBytes else {
                rejected = true
                return
            }
            carry.append(contentsOf: UnsafeBufferPointer(start: bytes, count: count))
        }

        func lastNewlineOffset(before endOffset: Int, in base: UnsafePointer<UInt8>) -> Int? {
            guard endOffset > 0 else {
                return nil
            }
            var offset = endOffset - 1
            while offset >= 0 {
                if base[offset] == newlineByte {
                    return offset
                }
                if offset == 0 {
                    break
                }
                offset -= 1
            }
            return nil
        }

        func validateChunk(_ base: UnsafePointer<UInt8>, count: Int) -> Bool {
            if isFirstChunk {
                isFirstChunk = false
                if count >= 3,
                   base[0] == 0xEF,
                   base[1] == 0xBB,
                   base[2] == 0xBF {
                    rejected = true
                    return false
                }
                if count >= 2,
                   (base[0] == 0xFF && base[1] == 0xFE
                    || base[0] == 0xFE && base[1] == 0xFF) {
                    rejected = true
                    return false
                }
            }
            if bytesCheckedForNUL < 64 * 1024 {
                let checkCount = min(count, 64 * 1024 - bytesCheckedForNUL)
                if memchr(base, 0, checkCount) != nil {
                    rejected = true
                    return false
                }
                bytesCheckedForNUL += checkCount
            }
            return true
        }

        func findLiteral(
            in base: UnsafePointer<UInt8>,
            from searchOffset: Int,
            count: Int
        ) -> UnsafePointer<UInt8>? {
            let remainingCount = count - searchOffset
            guard remainingCount >= literal.count else {
                return nil
            }
            if asciiCaseInsensitive {
                return foldedLiteral.withUnsafeBufferPointer { foldedNeedle in
                    caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                        rg_memcasemem_ascii_prepared(
                            base.advanced(by: searchOffset),
                            remainingCount,
                            foldedNeedle.baseAddress,
                            foldedNeedle.count,
                            shifts.baseAddress
                        )
                    }
                }
            }
            return literal.withUnsafeBufferPointer { needle in
                rg_memmem_simple(
                    base.advanced(by: searchOffset),
                    remainingCount,
                    needle.baseAddress,
                    needle.count
                )
            }
        }

        func emitMatches(
            in base: UnsafePointer<UInt8>,
            count: Int,
            allowUnterminatedFinalLine: Bool
        ) -> (lineNumber: Int, countedOffset: Int) {
            guard !writeFailed else {
                return (currentLineNumber, 0)
            }
            var lineNumberCursor = currentLineNumber
            var lineCountOffset = 0
            var searchOffset = 0
            var lastEmittedLineStart = -1
            while searchOffset < count {
                guard let found = findLiteral(in: base, from: searchOffset, count: count) else {
                    return (lineNumberCursor, lineCountOffset)
                }
                let matchStart = base.distance(to: found)
                var lineStart = matchStart
                while lineStart > 0, base[lineStart - 1] != newlineByte {
                    lineStart -= 1
                }
                if lineStart == lastEmittedLineStart {
                    searchOffset = matchStart + literal.count
                    continue
                }

                let newline = memchr(found, Int32(newlineByte), count - matchStart)
                let outputEnd: Int
                let hasNewline: Bool
                if let newline {
                    outputEnd = base.distance(to: newline.assumingMemoryBound(to: UInt8.self)) + 1
                    hasNewline = true
                } else if allowUnterminatedFinalLine {
                    outputEnd = count
                    hasNewline = false
                } else {
                    return (lineNumberCursor, lineCountOffset)
                }

                if lineNumber {
                    lineNumberCursor += Int(rg_memcount_byte(
                        base.advanced(by: lineCountOffset),
                        lineStart - lineCountOffset,
                        newlineByte
                    ))
                    lineCountOffset = lineStart
                    guard output.writeLineNumberPrefix(lineNumberCursor) else {
                        writeFailed = true
                        return (lineNumberCursor, lineCountOffset)
                    }
                }
                guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
                    writeFailed = true
                    return (lineNumberCursor, lineCountOffset)
                }
                if !hasNewline, !output.writeByte(newlineByte) {
                    writeFailed = true
                    return (lineNumberCursor, lineCountOffset)
                }
                matchedLineCount += 1
                lastEmittedLineStart = lineStart
                searchOffset = outputEnd
            }
            return (lineNumberCursor, lineCountOffset)
        }

        func processBuffer(_ base: UnsafePointer<UInt8>, count: Int) -> Data? {
            guard let lastNewline = lastNewlineOffset(before: count, in: base) else {
                guard count <= HaystackReader.defaultMaxBufferBytes else {
                    rejected = true
                    return nil
                }
                return Data(bytes: base, count: count)
            }

            let completeCount = lastNewline + 1
            let emittedLineState = emitMatches(in: base, count: completeCount, allowUnterminatedFinalLine: false)
            if lineNumber {
                currentLineNumber = emittedLineState.lineNumber + Int(rg_memcount_byte(
                    base.advanced(by: emittedLineState.countedOffset),
                    completeCount - emittedLineState.countedOffset,
                    newlineByte
                ))
            }
            let tailCount = count - completeCount
            return tailCount > 0
                ? Data(bytes: base.advanced(by: completeCount), count: tailCount)
                : Data()
        }

        while !rejected, !writeFailed {
            let chunk = handle.readData(ofLength: 2 * 1024 * 1024)
            guard !chunk.isEmpty else {
                break
            }

            chunk.withUnsafeBytes { rawChunk in
                guard let rawBase = rawChunk.baseAddress else {
                    return
                }
                let base = rawBase.assumingMemoryBound(to: UInt8.self)
                guard validateChunk(base, count: rawChunk.count) else {
                    return
                }

                if carry.isEmpty {
                    carry = processBuffer(base, count: rawChunk.count) ?? Data()
                } else {
                    appendCarry(base, count: rawChunk.count)
                    guard !rejected else {
                        return
                    }
                    let nextCarry = carry.withUnsafeBytes { rawCarry -> Data in
                        guard let rawCarryBase = rawCarry.baseAddress else {
                            return Data()
                        }
                        let carryBase = rawCarryBase.assumingMemoryBound(to: UInt8.self)
                        return processBuffer(carryBase, count: rawCarry.count) ?? Data()
                    }
                    carry = nextCarry
                }
            }
        }

        guard !rejected else {
            return nil
        }
        if !carry.isEmpty {
            carry.withUnsafeBytes { rawCarry in
                guard let rawBase = rawCarry.baseAddress else {
                    return
                }
                _ = emitMatches(
                    in: rawBase.assumingMemoryBound(to: UInt8.self),
                    count: rawCarry.count,
                    allowUnterminatedFinalLine: true
                )
            }
        }
        guard !writeFailed, output.flush() else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    static func multiLiteralResult(
        path: String,
        literals: [[UInt8]],
        maxCount: Int?,
        lineNumber: Bool = false
    ) -> rg_darwin_literal_file_result? {
        guard literals.count > 1,
              literals.count <= 64,
              literals.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return rg_darwin_literal_file_result(
                status: 0,
                matched_line_count: 0,
                total_match_count: 0,
                bytes_searched: 0
            )
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        let base = UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self)
        return rgSwiftDarwinWriteMultiLiteralLines(
            base,
            haystackLength: haystackLength,
            literals: literals,
            maxCount: maxCount ?? Int.max,
            lineNumber: lineNumber
        )
    }
}

@inline(__always)
private func rgSwiftASCIILower(_ byte: UInt8) -> UInt8 {
    byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
        ? byte + (UInt8(ascii: "a") - UInt8(ascii: "A"))
        : byte
}

private struct rgSwiftStdoutBuffer {
    private let storage: UnsafeMutablePointer<UInt8>
    private var length = 0
    private let capacity: Int

    init?(capacity: Int) {
        guard capacity > 0 else {
            return nil
        }
        self.capacity = capacity
        self.storage = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    mutating func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard count > 0 else {
            return true
        }
        if count > capacity {
            guard flush() else {
                return false
            }
            return fwrite(bytes, 1, count, Darwin.stdout) == count
        }
        if length + count > capacity, !flush() {
            return false
        }
        storage.advanced(by: length).update(from: bytes, count: count)
        length += count
        return true
    }

    mutating func writeByte(_ byte: UInt8) -> Bool {
        if length == capacity, !flush() {
            return false
        }
        storage[length] = byte
        length += 1
        return true
    }

    mutating func writeLineNumberPrefix(_ value: Int) -> Bool {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
            var cursor = buffer.count - 1
            buffer[cursor] = UInt8(ascii: ":")
            var number = value
            repeat {
                cursor -= 1
                buffer[cursor] = UInt8(number % 10) + UInt8(ascii: "0")
                number /= 10
            } while number > 0
            return write(
                buffer.baseAddress!.advanced(by: cursor),
                count: buffer.count - cursor
            )
        }
    }

    mutating func flush() -> Bool {
        guard length > 0 else {
            return true
        }
        let written = fwrite(storage, 1, length, Darwin.stdout)
        guard written == length else {
            return false
        }
        length = 0
        return true
    }

    func deallocate() {
        storage.deallocate()
    }
}

private func rgSwiftDarwinWriteLiteralBytes(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    asciiBoundary: Bool
) -> Int? {
    guard let literalBase = literal.baseAddress, literal.count > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, min(haystackLength, 64 * 1024)) != nil {
        return nil
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    var foldedLiteral: [UInt8] = []
    var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
    if asciiCaseInsensitive {
        foldedLiteral = (0..<literal.count).map { rgSwiftASCIILower(literalBase[$0]) }
        if foldedLiteral.count > 1 {
            for index in 0..<(foldedLiteral.count - 1) {
                caseInsensitiveShifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
            }
        }
    }

    var matchedLineCount = 0
    var lineNumberAtSearchOffset = 1
    var searchOffset = 0
    var lastEmittedLineStart = -1
    var writeFailed = false

    @inline(__always)
    func isASCIIBoundaryMatch(matchStart: Int, lineStart: Int, lineEnd: Int) -> Bool {
        if matchStart > lineStart, rgSwiftIsASCIIRegexWordByte(base[matchStart - 1]) {
            return false
        }
        let matchEnd = matchStart + literal.count
        if matchEnd < lineEnd, rgSwiftIsASCIIRegexWordByte(base[matchEnd]) {
            return false
        }
        return true
    }

    func emitMatchedLine(found: UnsafePointer<UInt8>, newlinesBeforeMatch: Int) -> Bool {
        let matchStart = base.distance(to: found)
        var lineStart = matchStart
        while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
        }

        let newline = memchr(found, Int32(UInt8(ascii: "\n")), haystackLength - matchStart)
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        if asciiBoundary,
           !isASCIIBoundaryMatch(matchStart: matchStart, lineStart: lineStart, lineEnd: lineEnd) {
            if lineNumber {
                lineNumberAtSearchOffset += newlinesBeforeMatch
            }
            searchOffset = max(matchStart + 1, searchOffset + 1)
            return true
        }

        if lineStart != lastEmittedLineStart {
            let outputEnd = newline.map {
                base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) + 1
            } ?? haystackLength
            if lineNumber {
                let matchedLineNumber = lineNumberAtSearchOffset + newlinesBeforeMatch
                guard output.writeLineNumberPrefix(matchedLineNumber) else {
                    writeFailed = true
                    return false
                }
                lineNumberAtSearchOffset = newline == nil
                    ? matchedLineNumber
                    : matchedLineNumber + 1
            }
            guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
                writeFailed = true
                return false
            }
            if newline == nil, !output.writeByte(UInt8(ascii: "\n")) {
                writeFailed = true
                return false
            }
            matchedLineCount += 1
            lastEmittedLineStart = lineStart
            searchOffset = outputEnd
            return true
        }

        searchOffset = matchStart + literal.count
        return true
    }

    if asciiCaseInsensitive {
        foldedLiteral.withUnsafeBufferPointer { foldedNeedle in
            caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                while searchOffset < haystackLength {
                    let found: UnsafePointer<UInt8>?
                    let newlinesBeforeMatch: Int
                    if lineNumber {
                        let result = rg_memcasemem_ascii_count_byte_before(
                            base.advanced(by: searchOffset),
                            haystackLength - searchOffset,
                            foldedNeedle.baseAddress,
                            foldedNeedle.count,
                            UInt8(ascii: "\n")
                        )
                        found = result.match
                        newlinesBeforeMatch = result.count
                    } else {
                        found = rg_memcasemem_ascii_prepared(
                            base.advanced(by: searchOffset),
                            haystackLength - searchOffset,
                            foldedNeedle.baseAddress,
                            foldedNeedle.count,
                            shifts.baseAddress
                        )
                        newlinesBeforeMatch = 0
                    }
                    guard let found else {
                        break
                    }
                    guard emitMatchedLine(found: found, newlinesBeforeMatch: newlinesBeforeMatch) else {
                        break
                    }
                }
            }
        }
    } else {
        while searchOffset < haystackLength {
            let found: UnsafePointer<UInt8>?
            let newlinesBeforeMatch: Int
            if lineNumber {
                let result = rg_memmem_count_byte_before(
                    base.advanced(by: searchOffset),
                    haystackLength - searchOffset,
                    literalBase,
                    literal.count,
                    UInt8(ascii: "\n")
                )
                found = result.match
                newlinesBeforeMatch = result.count
            } else {
                found = rg_memmem_simple(
                    base.advanced(by: searchOffset),
                    haystackLength - searchOffset,
                    literalBase,
                    literal.count
                )
                newlinesBeforeMatch = 0
            }
            guard let found else {
                break
            }
            guard emitMatchedLine(found: found, newlinesBeforeMatch: newlinesBeforeMatch) else {
                break
            }
        }
    }

    guard !writeFailed else {
        return nil
    }
    guard output.flush() else {
        return nil
    }
    return matchedLineCount
}

private func rgSwiftDarwinWriteWordLiteralLineNumberBytes(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>
) -> Int? {
    guard let literalBase = literal.baseAddress, literal.count > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, min(haystackLength, 64 * 1024)) != nil {
        return nil
    }

    enum WordBoundaryState {
        case bounded
        case notBounded
        case needsDecodedFallback
    }

    struct PendingLine {
        let number: Int
        let start: Int
        let outputEnd: Int
        let needsFinalNewline: Bool
    }

    @inline(__always)
    func wordBoundaryState(matchStart: Int, matchEnd: Int) -> WordBoundaryState {
        if matchStart > 0 {
            let before = base[matchStart - 1]
            if before >= 0x80 {
                return .needsDecodedFallback
            }
            if rgSwiftIsASCIIRegexWordByte(before) {
                return .notBounded
            }
        }
        if matchEnd < haystackLength {
            let after = base[matchEnd]
            if after >= 0x80 {
                return .needsDecodedFallback
            }
            if rgSwiftIsASCIIRegexWordByte(after) {
                return .notBounded
            }
        }
        return .bounded
    }

    var pendingLines: [PendingLine] = []
    pendingLines.reserveCapacity(1024)
    let maxBufferedLines = 16_384
    var lineNumberAtSearchOffset = 1
    var searchOffset = 0
    var lastEmittedLineStart = -1

    while searchOffset < haystackLength {
        let result = rg_memmem_count_byte_before(
            base.advanced(by: searchOffset),
            haystackLength - searchOffset,
            literalBase,
            literal.count,
            UInt8(ascii: "\n")
        )
        guard let found = result.match else {
            break
        }

        let matchStart = base.distance(to: found)
        let matchEnd = matchStart + literal.count
        let matchedLineNumber = lineNumberAtSearchOffset + Int(result.count)
        switch wordBoundaryState(matchStart: matchStart, matchEnd: matchEnd) {
        case .bounded:
            break
        case .notBounded:
            lineNumberAtSearchOffset = matchedLineNumber
            searchOffset = max(matchStart + 1, searchOffset + 1)
            continue
        case .needsDecodedFallback:
            return nil
        }

        var lineStart = matchStart
        while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
        }
        let newline = memchr(found, Int32(UInt8(ascii: "\n")), haystackLength - matchStart)
        let outputEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) + 1
        } ?? haystackLength

        if lineStart != lastEmittedLineStart {
            guard pendingLines.count < maxBufferedLines else {
                return nil
            }
            pendingLines.append(PendingLine(
                number: matchedLineNumber,
                start: lineStart,
                outputEnd: outputEnd,
                needsFinalNewline: newline == nil
            ))
            lastEmittedLineStart = lineStart
        }
        lineNumberAtSearchOffset = newline == nil ? matchedLineNumber : matchedLineNumber + 1
        searchOffset = outputEnd
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    for line in pendingLines {
        guard output.writeLineNumberPrefix(line.number),
              output.write(base.advanced(by: line.start), count: line.outputEnd - line.start) else {
            return nil
        }
        if line.needsFinalNewline,
           !output.writeByte(UInt8(ascii: "\n")) {
            return nil
        }
    }

    guard output.flush() else {
        return nil
    }
    return pendingLines.count
}

private func rgSwiftDarwinWriteSurroundingWordsBytes(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    lineNumber: Bool,
    asciiOnly: Bool
) -> Int? {
    guard let literalBase = literal.baseAddress, literal.count > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, min(haystackLength, 64 * 1024)) != nil {
        return nil
    }

    struct PendingLine {
        let number: Int
        let start: Int
        let outputEnd: Int
        let needsFinalNewline: Bool
    }

    @inline(__always)
    func hasSurroundingASCIIWords(lineStart: Int, lineEnd: Int, literalStart: Int, literalEnd: Int) -> Bool {
        guard literalStart > lineStart, literalEnd < lineEnd else {
            return false
        }

        var beforeWhitespaceStart = literalStart
        while beforeWhitespaceStart > lineStart,
              rgSwiftIsASCIIRegexWhitespaceByte(base[beforeWhitespaceStart - 1]) {
            beforeWhitespaceStart -= 1
        }
        guard beforeWhitespaceStart < literalStart else {
            return false
        }

        var beforeWordStart = beforeWhitespaceStart
        while beforeWordStart > lineStart,
              rgSwiftIsASCIIRegexWordByte(base[beforeWordStart - 1]) {
            beforeWordStart -= 1
        }
        guard beforeWordStart < beforeWhitespaceStart else {
            return false
        }

        var afterWhitespaceEnd = literalEnd
        while afterWhitespaceEnd < lineEnd,
              rgSwiftIsASCIIRegexWhitespaceByte(base[afterWhitespaceEnd]) {
            afterWhitespaceEnd += 1
        }
        guard afterWhitespaceEnd > literalEnd else {
            return false
        }

        var afterWordEnd = afterWhitespaceEnd
        while afterWordEnd < lineEnd,
              rgSwiftIsASCIIRegexWordByte(base[afterWordEnd]) {
            afterWordEnd += 1
        }
        return afterWordEnd > afterWhitespaceEnd
    }

    @inline(__always)
    func utf8SequenceLength(startingWith byte: UInt8) -> Int? {
        if byte < 0x80 {
            return 1
        }
        if byte >= 0xC2 && byte <= 0xDF {
            return 2
        }
        if byte >= 0xE0 && byte <= 0xEF {
            return 3
        }
        if byte >= 0xF0 && byte <= 0xF4 {
            return 4
        }
        return nil
    }

    @inline(__always)
    func isUTF8Continuation(_ byte: UInt8) -> Bool {
        byte >= 0x80 && byte <= 0xBF
    }

    @inline(__always)
    func knownUnicodeWhitespaceScalar(at offset: Int, lineEnd: Int) -> Bool? {
        // Keep the Unicode preflight conservative in \s+ slots: known
        // whitespace can fall back, known non-whitespace can keep scanning, and
        // malformed UTF-8 returns nil so the full matcher decides.
        guard offset < lineEnd else {
            return false
        }
        let first = base[offset]
        guard first >= 0x80 else {
            return rgSwiftIsASCIIRegexWhitespaceByte(first)
        }
        guard let length = utf8SequenceLength(startingWith: first),
              offset + length <= lineEnd else {
            return nil
        }
        for continuationOffset in (offset + 1)..<(offset + length) {
            guard isUTF8Continuation(base[continuationOffset]) else {
                return nil
            }
        }

        if length == 2 {
            return first == 0xC2 && (base[offset + 1] == 0x85 || base[offset + 1] == 0xA0)
        }
        if length == 3 {
            let second = base[offset + 1]
            let third = base[offset + 2]
            if first == 0xE1, second == 0x9A, third == 0x80 {
                return true
            }
            if first == 0xE2 {
                if second == 0x80, (0x80...0x8A).contains(third) || third == 0xA8 || third == 0xA9 {
                    return true
                }
                if second == 0x80, third == 0xAF {
                    return true
                }
                if second == 0x81, third == 0x9F {
                    return true
                }
            }
            if first == 0xE3, second == 0x80, third == 0x80 {
                return true
            }
        }
        return false
    }

    @inline(__always)
    func previousKnownUnicodeWhitespaceScalar(endingAt offset: Int, lineStart: Int) -> Bool? {
        guard offset > lineStart else {
            return false
        }
        var scalarStart = offset - 1
        while scalarStart > lineStart, isUTF8Continuation(base[scalarStart]) {
            scalarStart -= 1
        }
        guard let length = utf8SequenceLength(startingWith: base[scalarStart]),
              scalarStart + length == offset else {
            return nil
        }
        return knownUnicodeWhitespaceScalar(at: scalarStart, lineEnd: offset)
    }

    @inline(__always)
    func leftSideMayNeedUnicode(lineStart: Int, literalStart: Int) -> Bool {
        var offset = literalStart
        var sawWhitespace = false
        while offset > lineStart {
            let byte = base[offset - 1]
            if rgSwiftIsASCIIRegexWhitespaceByte(byte) {
                sawWhitespace = true
                offset -= 1
                continue
            }
            if byte >= 0x80 {
                if sawWhitespace {
                    return true
                }
                return previousKnownUnicodeWhitespaceScalar(endingAt: offset, lineStart: lineStart) ?? true
            }
            break
        }
        guard sawWhitespace else {
            return false
        }

        var sawWord = false
        while offset > lineStart {
            let byte = base[offset - 1]
            if rgSwiftIsASCIIRegexWordByte(byte) {
                sawWord = true
                offset -= 1
                continue
            }
            if byte >= 0x80 {
                return true
            }
            break
        }
        return sawWord
    }

    @inline(__always)
    func rightSideMayNeedUnicode(lineEnd: Int, literalEnd: Int) -> Bool {
        var offset = literalEnd
        var sawWhitespace = false
        while offset < lineEnd {
            let byte = base[offset]
            if rgSwiftIsASCIIRegexWhitespaceByte(byte) {
                sawWhitespace = true
                offset += 1
                continue
            }
            if byte >= 0x80 {
                if sawWhitespace {
                    return true
                }
                return knownUnicodeWhitespaceScalar(at: offset, lineEnd: lineEnd) ?? true
            }
            break
        }
        guard sawWhitespace else {
            return false
        }

        var sawWord = false
        while offset < lineEnd {
            let byte = base[offset]
            if rgSwiftIsASCIIRegexWordByte(byte) {
                sawWord = true
                offset += 1
                continue
            }
            if byte >= 0x80 {
                return true
            }
            break
        }
        return sawWord
    }

    @inline(__always)
    func surroundingUnicodeFallbackMayMatch(
        lineStart: Int,
        lineEnd: Int,
        literalStart: Int,
        literalEnd: Int
    ) -> Bool {
        leftSideMayNeedUnicode(lineStart: lineStart, literalStart: literalStart)
            && rightSideMayNeedUnicode(lineEnd: lineEnd, literalEnd: literalEnd)
    }

    var pendingLines: [PendingLine] = []
    pendingLines.reserveCapacity(1024)
    let maxBufferedLines = 16_384
    var lineNumberAtSearchOffset = 1
    var searchOffset = 0
    var lastEmittedLineStart = -1

    while searchOffset < haystackLength {
        let result = rg_memmem_count_byte_before(
            base.advanced(by: searchOffset),
            haystackLength - searchOffset,
            literalBase,
            literal.count,
            UInt8(ascii: "\n")
        )
        guard let found = result.match else {
            break
        }

        let literalStart = base.distance(to: found)
        let literalEnd = literalStart + literal.count
        let matchedLineNumber = lineNumberAtSearchOffset + Int(result.count)
        var lineStart = literalStart
        while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
        }
        let newline = memchr(found, Int32(UInt8(ascii: "\n")), haystackLength - literalStart)
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let outputEnd = newline == nil ? haystackLength : lineEnd + 1

        let asciiMatched = hasSurroundingASCIIWords(
            lineStart: lineStart,
            lineEnd: lineEnd,
            literalStart: literalStart,
            literalEnd: literalEnd
        )
        if asciiMatched {
            if lineStart != lastEmittedLineStart {
                guard pendingLines.count < maxBufferedLines else {
                    return nil
                }
                pendingLines.append(PendingLine(
                    number: matchedLineNumber,
                    start: lineStart,
                    outputEnd: outputEnd,
                    needsFinalNewline: newline == nil
                ))
                lastEmittedLineStart = lineStart
            }
            lineNumberAtSearchOffset = newline == nil ? matchedLineNumber : matchedLineNumber + 1
            searchOffset = outputEnd
            continue
        }
        if !asciiOnly,
           surroundingUnicodeFallbackMayMatch(
            lineStart: lineStart,
            lineEnd: lineEnd,
            literalStart: literalStart,
            literalEnd: literalEnd
           ) {
            return nil
        }

        lineNumberAtSearchOffset = matchedLineNumber
        searchOffset = max(literalStart + 1, searchOffset + 1)
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    for line in pendingLines {
        if lineNumber,
           !output.writeLineNumberPrefix(line.number) {
            return nil
        }
        guard output.write(base.advanced(by: line.start), count: line.outputEnd - line.start) else {
            return nil
        }
        if line.needsFinalNewline,
           !output.writeByte(UInt8(ascii: "\n")) {
            return nil
        }
    }

    guard output.flush() else {
        return nil
    }
    return pendingLines.count
}

private func rgSwiftDarwinWriteMultiLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]],
    maxCount: Int,
    lineNumber: Bool
) -> rg_darwin_literal_file_result? {
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, min(haystackLength, 64 * 1024)) != nil {
        return nil
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    var matchedLineCount = 0
    var bytesSearched = haystackLength
    var currentLineNumber = 1
    var lineCountOffset = 0
    var writeFailed = false

    func literal(_ literal: [UInt8], matchesAt offset: Int) -> Bool {
        guard literal.count <= haystackLength - offset else {
            return false
        }
        for index in literal.indices where base[offset + index] != literal[index] {
            return false
        }
        return true
    }

    func commonPrefixLength() -> Int {
        guard let firstLiteral = literals.first else {
            return 0
        }
        var prefixLength = firstLiteral.count
        for literal in literals.dropFirst() {
            prefixLength = min(prefixLength, literal.count)
            while prefixLength > 0 {
                var matches = true
                for index in 0..<prefixLength where firstLiteral[index] != literal[index] {
                    matches = false
                    break
                }
                if matches {
                    break
                }
                prefixLength -= 1
            }
            if prefixLength == 0 {
                break
            }
        }
        return prefixLength
    }

    func emitLine(containing matchStart: Int) -> Bool {
        var lineStart = matchStart
        while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
        }
        let newline = memchr(
            base.advanced(by: matchStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - matchStart
        )
        let outputEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) + 1
        } ?? haystackLength
        if lineNumber {
            currentLineNumber += rg_memcount_byte(
                base.advanced(by: lineCountOffset),
                lineStart - lineCountOffset,
                UInt8(ascii: "\n")
            )
            lineCountOffset = lineStart
            guard output.writeLineNumberPrefix(currentLineNumber) else {
                return false
            }
        }
        guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
            return false
        }
        if newline == nil, !output.writeByte(UInt8(ascii: "\n")) {
            return false
        }
        matchedLineCount += 1
        bytesSearched = outputEnd
        return true
    }

    let prefixLineFirstBytes: [UInt8] = {
        var firstBytes: [UInt8] = []
        firstBytes.reserveCapacity(literals.count)
        for literal in literals where !firstBytes.contains(literal[0]) {
            firstBytes.append(literal[0])
        }
        return firstBytes
    }()

    func firstLiteralMatch(inLineStart lineStart: Int, lineEnd: Int) -> Int? {
        var searchOffset = lineStart
        while searchOffset < lineEnd {
            let foundPointer = prefixLineFirstBytes.withUnsafeBufferPointer { firstByteBuffer in
                rg_memchr_any_bytes(
                    base.advanced(by: searchOffset),
                    lineEnd - searchOffset,
                    firstByteBuffer.baseAddress,
                    firstByteBuffer.count
                )
            }
            if let foundPointer {
                let matchStart = base.distance(to: foundPointer)
                let firstByte = base[matchStart]
                for candidateLiteral in literals
                    where candidateLiteral[0] == firstByte && candidateLiteral.count <= lineEnd - matchStart {
                    if literal(candidateLiteral, matchesAt: matchStart) {
                        return matchStart
                    }
                }
                searchOffset = matchStart + 1
            } else {
                return nil
            }
        }
        return nil
    }

    func boundedPrefixLineMatches() -> [Int]? {
        guard maxCount <= 1024, literals.count >= 4 else {
            return nil
        }
        var matches: [Int] = []
        matches.reserveCapacity(maxCount)
        var lineStart = 0
        let scanLimit = min(haystackLength, 2 * 1024 * 1024)
        while lineStart < haystackLength,
              lineStart < scanLimit,
              matches.count < maxCount {
            let newline = memchr(
                base.advanced(by: lineStart),
                Int32(UInt8(ascii: "\n")),
                haystackLength - lineStart
            )
            let lineEnd: Int
            let outputEnd: Int
            if let newline {
                lineEnd = base.distance(to: newline.assumingMemoryBound(to: UInt8.self))
                outputEnd = lineEnd + 1
            } else {
                lineEnd = haystackLength
                outputEnd = haystackLength
            }
            if let matchStart = firstLiteralMatch(inLineStart: lineStart, lineEnd: lineEnd) {
                matches.append(matchStart)
            }
            lineStart = outputEnd
        }
        return matches.count == maxCount ? matches : nil
    }

    func nextCandidate(literalIndex: Int, from offset: Int) -> (start: Int, literalIndex: Int) {
        let safeOffset = min(offset, haystackLength)
        let literal = literals[literalIndex]
        guard literal.count <= haystackLength - safeOffset else {
            return (Int.max, literalIndex)
        }
        let foundPointer = literal.withUnsafeBufferPointer { literalBuffer in
            rg_memmem_simple(
                base.advanced(by: safeOffset),
                haystackLength - safeOffset,
                literalBuffer.baseAddress,
                literalBuffer.count
            )
        }
        guard let foundPointer else {
            return (Int.max, literalIndex)
        }
        return (base.distance(to: foundPointer), literalIndex)
    }

    func earliestCandidateIndex(in candidates: [(start: Int, literalIndex: Int)]) -> Int? {
        var selectedIndex: Int?
        var selectedStart = Int.max
        for index in candidates.indices where candidates[index].start < selectedStart {
            selectedStart = candidates[index].start
            selectedIndex = index
        }
        return selectedStart == Int.max ? nil : selectedIndex
    }

    let prefixLength = commonPrefixLength()
    if let prefixMatches = boundedPrefixLineMatches() {
        for matchStart in prefixMatches {
            guard emitLine(containing: matchStart) else {
                writeFailed = true
                break
            }
        }
    } else if prefixLength >= 4 {
        var searchOffset = 0
        while matchedLineCount < maxCount, searchOffset < haystackLength {
            let foundPointer = literals[0].withUnsafeBufferPointer { literalBuffer in
                rg_memmem_simple(
                    base.advanced(by: searchOffset),
                    haystackLength - searchOffset,
                    literalBuffer.baseAddress,
                    prefixLength
                )
            }
            guard let foundPointer else {
                break
            }
            let matchStart = base.distance(to: foundPointer)
            if literals.contains(where: { literal($0, matchesAt: matchStart) }) {
                guard emitLine(containing: matchStart) else {
                    writeFailed = true
                    break
                }
                searchOffset = bytesSearched
            } else {
                searchOffset = matchStart + 1
            }
        }
    } else {
        var candidates = literals.indices.map {
            nextCandidate(literalIndex: $0, from: 0)
        }

        while matchedLineCount < maxCount,
              let candidateIndex = earliestCandidateIndex(in: candidates) {
            let matchStart = candidates[candidateIndex].start
            guard matchStart < haystackLength else {
                break
            }

            guard emitLine(containing: matchStart) else {
                writeFailed = true
                break
            }
            for index in candidates.indices where candidates[index].start < bytesSearched {
                candidates[index] = nextCandidate(
                    literalIndex: candidates[index].literalIndex,
                    from: bytesSearched
                )
            }
        }
    }

    if matchedLineCount < maxCount {
        bytesSearched = haystackLength
    }

    guard !writeFailed else {
        return rg_darwin_literal_file_result(
            status: -1,
            matched_line_count: matchedLineCount,
            total_match_count: 0,
            bytes_searched: bytesSearched
        )
    }
    guard output.flush() else {
        return rg_darwin_literal_file_result(
            status: -1,
            matched_line_count: matchedLineCount,
            total_match_count: 0,
            bytes_searched: bytesSearched
        )
    }
    return rg_darwin_literal_file_result(
        status: 0,
        matched_line_count: matchedLineCount,
        total_match_count: 0,
        bytes_searched: bytesSearched
    )
}

@inline(__always)
private func rgSwiftIsASCIIRegexWordByte(_ byte: UInt8) -> Bool {
    (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
        || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
        || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
        || byte == UInt8(ascii: "_")
}

@inline(__always)
private func rgSwiftIsASCIIRegexWhitespaceByte(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || (byte >= 0x09 && byte <= 0x0D)
}
#endif
