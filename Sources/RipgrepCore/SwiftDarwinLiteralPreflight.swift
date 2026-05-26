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

    var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024)
    guard output != nil else {
        return nil
    }
    defer {
        output?.deallocate()
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

    func findNextMatch(from offset: Int) -> UnsafePointer<UInt8>? {
        if asciiCaseInsensitive {
            return foldedLiteral.withUnsafeBufferPointer { foldedNeedle in
                caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                    rg_memcasemem_ascii_prepared(
                        base.advanced(by: offset),
                        haystackLength - offset,
                        foldedNeedle.baseAddress,
                        foldedNeedle.count,
                        shifts.baseAddress
                    )
                }
            }
        }
        return rg_memmem_simple(
            base.advanced(by: offset),
            haystackLength - offset,
            literalBase,
            literal.count
        )
    }

    while searchOffset < haystackLength {
        guard let found = findNextMatch(from: searchOffset) else {
            break
        }

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
            guard output?.write(base.advanced(by: lineStart), count: outputEnd - lineStart) == true else {
                return nil
            }
            if newline == nil, output?.writeByte(UInt8(ascii: "\n")) != true {
                return nil
            }
            matchedLineCount += 1
            lastEmittedLineStart = lineStart
            searchOffset = outputEnd
            continue
        }

        searchOffset = matchStart + literal.count
    }

    guard output?.flush() == true else {
        return nil
    }
    return matchedLineCount
}
#endif
