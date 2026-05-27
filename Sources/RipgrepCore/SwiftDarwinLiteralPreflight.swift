import Foundation

#if !canImport(CRipgrepPlatform) && canImport(Darwin)
import Darwin

public enum SwiftDarwinLiteralPreflight {
    public static func exitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool
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
                asciiCaseInsensitive: asciiCaseInsensitive
            )
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    static func multiLiteralResult(
        path: String,
        literals: [[UInt8]],
        maxCount: Int?
    ) -> rg_darwin_literal_file_result? {
        guard literals.count > 1,
              literals.count <= 8,
              literals.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        var firstBytes: [UInt8] = []
        firstBytes.reserveCapacity(literals.count)
        var literalIndicesByByte = [Int](repeating: -1, count: 256)
        for (literalIndex, literal) in literals.enumerated() {
            let firstByte = literal[0]
            guard literalIndicesByByte[Int(firstByte)] == -1 else {
                return nil
            }
            literalIndicesByByte[Int(firstByte)] = literalIndex
            firstBytes.append(firstByte)
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
            firstBytes: firstBytes,
            literalIndicesByByte: literalIndicesByByte,
            maxCount: maxCount ?? Int.max
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
    asciiCaseInsensitive: Bool
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
    var searchOffset = 0
    var lastEmittedLineStart = -1
    var writeFailed = false

    func emitMatchedLine(found: UnsafePointer<UInt8>) -> Bool {
        let matchStart = base.distance(to: found)
        var lineStart = matchStart
        while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
        }

        if lineStart != lastEmittedLineStart {
            let newline = memchr(found, Int32(UInt8(ascii: "\n")), haystackLength - matchStart)
            let outputEnd = newline.map {
                base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) + 1
            } ?? haystackLength
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
                    guard let found = rg_memcasemem_ascii_prepared(
                        base.advanced(by: searchOffset),
                        haystackLength - searchOffset,
                        foldedNeedle.baseAddress,
                        foldedNeedle.count,
                        shifts.baseAddress
                    ) else {
                        break
                    }
                    guard emitMatchedLine(found: found) else {
                        break
                    }
                }
            }
        }
    } else {
        while searchOffset < haystackLength {
            guard let found = rg_memmem_simple(
                base.advanced(by: searchOffset),
                haystackLength - searchOffset,
                literalBase,
                literal.count
            ) else {
                break
            }
            guard emitMatchedLine(found: found) else {
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

private func rgSwiftDarwinWriteMultiLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]],
    firstBytes: [UInt8],
    literalIndicesByByte: [Int],
    maxCount: Int
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
    var searchOffset = 0
    var writeFailed = false

    firstBytes.withUnsafeBufferPointer { firstByteBuffer in
        while searchOffset < haystackLength, matchedLineCount < maxCount {
            let foundPointer = rg_memchr_any_bytes(
                base.advanced(by: searchOffset),
                haystackLength - searchOffset,
                firstByteBuffer.baseAddress,
                firstByteBuffer.count
            )
            guard let foundPointer else {
                break
            }

            let matchStart = base.distance(to: foundPointer)
            let literalIndex = literalIndicesByByte[Int(base[matchStart])]
            guard literalIndex >= 0 else {
                searchOffset = matchStart + 1
                continue
            }

            let literal = literals[literalIndex]
            guard literal.count <= haystackLength - matchStart else {
                searchOffset = matchStart + 1
                continue
            }
            let matches = literal.withUnsafeBufferPointer { literalBuffer -> Bool in
                guard let literalBase = literalBuffer.baseAddress else {
                    return false
                }
                return memcmp(base.advanced(by: matchStart), literalBase, literal.count) == 0
            }
            guard matches else {
                searchOffset = matchStart + 1
                continue
            }

            var lineStart = matchStart
            while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
                lineStart -= 1
            }
            let newline = memchr(
                foundPointer,
                Int32(UInt8(ascii: "\n")),
                haystackLength - matchStart
            )
            let outputEnd = newline.map {
                base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) + 1
            } ?? haystackLength
            guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
                writeFailed = true
                break
            }
            if newline == nil, !output.writeByte(UInt8(ascii: "\n")) {
                writeFailed = true
                break
            }
            matchedLineCount += 1
            bytesSearched = outputEnd
            searchOffset = outputEnd
        }
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
#endif
