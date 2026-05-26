import Foundation

#if !canImport(CRipgrepPlatform)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct rg_darwin_literal_file_result {
    var status: Int32
    var matched_line_count: Int
    var total_match_count: Int
    var bytes_searched: Int
}

@inline(__always)
private func rgASCIILower(_ byte: UInt8) -> UInt8 {
    byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
        ? byte + (UInt8(ascii: "a") - UInt8(ascii: "A"))
        : byte
}

@inline(__always)
private func rgConstBytePointer(_ pointer: UnsafeMutableRawPointer?) -> UnsafePointer<UInt8>? {
    guard let pointer else {
        return nil
    }
    return UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
}

func rg_memmem_simple(
    _ haystack: UnsafePointer<UInt8>?,
    _ haystackLength: Int,
    _ needle: UnsafePointer<UInt8>?,
    _ needleLength: Int
) -> UnsafePointer<UInt8>? {
    guard let haystack, let needle else {
        return nil
    }
    if needleLength == 0 {
        return haystack
    }
    guard haystackLength >= needleLength else {
        return nil
    }
    if needleLength == 1 {
        return rgConstBytePointer(memchr(haystack, Int32(needle[0]), haystackLength))
    }

    var cursor = 0
    let lastStart = haystackLength - needleLength
    while cursor <= lastStart {
        let remaining = lastStart - cursor + 1
        guard let candidate = rgConstBytePointer(memchr(
            haystack.advanced(by: cursor),
            Int32(needle[0]),
            remaining
        )) else {
            return nil
        }
        if memcmp(candidate.advanced(by: 1), needle.advanced(by: 1), needleLength - 1) == 0 {
            return candidate
        }
        cursor = haystack.distance(to: candidate) + 1
    }
    return nil
}

func rg_memcasemem_ascii(
    _ haystack: UnsafePointer<UInt8>?,
    _ haystackLength: Int,
    _ needle: UnsafePointer<UInt8>?,
    _ needleLength: Int
) -> UnsafePointer<UInt8>? {
    guard let needle else {
        return nil
    }
    let foldedNeedle = (0..<max(needleLength, 0)).map { rgASCIILower(needle[$0]) }
    var shifts = [Int](repeating: needleLength, count: 256)
    if needleLength > 1 {
        for index in 0..<(needleLength - 1) {
            shifts[Int(foldedNeedle[index])] = needleLength - 1 - index
        }
    }
    return foldedNeedle.withUnsafeBufferPointer { folded in
        shifts.withUnsafeBufferPointer { shiftBuffer in
            rg_memcasemem_ascii_prepared(
                haystack,
                haystackLength,
                folded.baseAddress,
                needleLength,
                shiftBuffer.baseAddress
            )
        }
    }
}

func rg_memcasemem_ascii_prepared(
    _ haystack: UnsafePointer<UInt8>?,
    _ haystackLength: Int,
    _ foldedNeedle: UnsafePointer<UInt8>?,
    _ needleLength: Int,
    _ shifts: UnsafePointer<Int>?
) -> UnsafePointer<UInt8>? {
    guard let haystack, let foldedNeedle else {
        return nil
    }
    if needleLength == 0 {
        return haystack
    }
    guard haystackLength >= needleLength else {
        return nil
    }
    if needleLength == 1 {
        let folded = foldedNeedle[0]
        for index in 0..<haystackLength where rgASCIILower(haystack[index]) == folded {
            return haystack.advanced(by: index)
        }
        return nil
    }

    var cursor = 0
    while cursor + needleLength <= haystackLength {
        let tail = rgASCIILower(haystack[cursor + needleLength - 1])
        if tail == foldedNeedle[needleLength - 1] {
            var offset = 0
            while offset < needleLength,
                  rgASCIILower(haystack[cursor + offset]) == foldedNeedle[offset] {
                offset += 1
            }
            if offset == needleLength {
                return haystack.advanced(by: cursor)
            }
        }
        let shift = shifts?[Int(tail)] ?? needleLength
        cursor += shift == 0 ? 1 : shift
    }
    return nil
}

func rg_memchr_any_bytes(
    _ haystack: UnsafePointer<UInt8>?,
    _ haystackLength: Int,
    _ needles: UnsafePointer<UInt8>?,
    _ needleCount: Int
) -> UnsafePointer<UInt8>? {
    guard let haystack, let needles, needleCount > 0 else {
        return nil
    }
    if needleCount == 1 {
        return rgConstBytePointer(memchr(haystack, Int32(needles[0]), haystackLength))
    }

    var mask = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
    for index in 0..<needleCount {
        let byte = Int(needles[index])
        switch byte >> 6 {
        case 0:
            mask.0 |= UInt64(1) << UInt64(byte & 63)
        case 1:
            mask.1 |= UInt64(1) << UInt64(byte & 63)
        case 2:
            mask.2 |= UInt64(1) << UInt64(byte & 63)
        default:
            mask.3 |= UInt64(1) << UInt64(byte & 63)
        }
    }

    for index in 0..<haystackLength {
        let byte = Int(haystack[index])
        let bit = UInt64(1) << UInt64(byte & 63)
        let contains: Bool
        switch byte >> 6 {
        case 0:
            contains = mask.0 & bit != 0
        case 1:
            contains = mask.1 & bit != 0
        case 2:
            contains = mask.2 & bit != 0
        default:
            contains = mask.3 & bit != 0
        }
        if contains {
            return haystack.advanced(by: index)
        }
    }
    return nil
}

func rg_memcount_byte(
    _ haystack: UnsafePointer<UInt8>?,
    _ haystackLength: Int,
    _ byte: UInt8
) -> Int {
    guard let haystack, haystackLength > 0 else {
        return 0
    }
    var count = 0
    var cursor = 0
    while cursor < haystackLength {
        guard let found = rgConstBytePointer(memchr(
            haystack.advanced(by: cursor),
            Int32(byte),
            haystackLength - cursor
        )) else {
            break
        }
        count += 1
        cursor = haystack.distance(to: found) + 1
    }
    return count
}

@inline(__always)
private func unavailableDarwinFastPath() -> rg_darwin_literal_file_result {
    rg_darwin_literal_file_result(
        status: -2,
        matched_line_count: 0,
        total_match_count: 0,
        bytes_searched: 0
    )
}

func rg_darwin_write_literal_file_lines(
    _ path: UnsafePointer<CChar>?,
    _ needle: UnsafePointer<UInt8>?,
    _ needleLength: Int
) -> rg_darwin_literal_file_result {
    unavailableDarwinFastPath()
}

func rg_darwin_write_literal_file_lines_no_mmap(
    _ path: UnsafePointer<CChar>?,
    _ needle: UnsafePointer<UInt8>?,
    _ needleLength: Int
) -> rg_darwin_literal_file_result {
    unavailableDarwinFastPath()
}

func rg_darwin_write_literal_file_lines_ascii_case_insensitive(
    _ path: UnsafePointer<CChar>?,
    _ needle: UnsafePointer<UInt8>?,
    _ needleLength: Int
) -> rg_darwin_literal_file_result {
    unavailableDarwinFastPath()
}

func rg_darwin_write_surrounding_words_file_lines(
    _ path: UnsafePointer<CChar>?,
    _ literal: UnsafePointer<UInt8>?,
    _ literalLength: Int
) -> rg_darwin_literal_file_result {
    unavailableDarwinFastPath()
}

func rg_darwin_write_surrounding_words_file_lines_with_line_numbers(
    _ path: UnsafePointer<CChar>?,
    _ literal: UnsafePointer<UInt8>?,
    _ literalLength: Int
) -> rg_darwin_literal_file_result {
    unavailableDarwinFastPath()
}

func rg_darwin_write_word_literal_file_lines(
    _ path: UnsafePointer<CChar>?,
    _ literal: UnsafePointer<UInt8>?,
    _ literalLength: Int
) -> rg_darwin_literal_file_result {
    unavailableDarwinFastPath()
}

func rg_darwin_write_byte_set_file_lines(
    _ path: UnsafePointer<CChar>?,
    _ needles: UnsafePointer<UInt8>?,
    _ needleCount: Int
) -> rg_darwin_literal_file_result {
    unavailableDarwinFastPath()
}

func rg_darwin_write_multi_literal_file_lines(
    _ path: UnsafePointer<CChar>?,
    _ literals: UnsafePointer<UInt8>?,
    _ literalOffsets: UnsafePointer<Int>?,
    _ literalLengths: UnsafePointer<Int>?,
    _ literalCount: Int
) -> rg_darwin_literal_file_result {
    unavailableDarwinFastPath()
}

func rg_darwin_write_fixed_conditional_pcre_o(
    _ base: UnsafePointer<UInt8>?,
    _ haystackLength: Int,
    _ conditionKind: Int32,
    _ condition: UnsafePointer<UInt8>?,
    _ conditionLength: Int,
    _ trueLiteral: UnsafePointer<UInt8>?,
    _ trueLiteralLength: Int,
    _ falseLiteral: UnsafePointer<UInt8>?,
    _ falseLiteralLength: Int
) -> rg_darwin_literal_file_result {
    unavailableDarwinFastPath()
}

func rg_darwin_write_fixed_literal_pcre_o(
    _ base: UnsafePointer<UInt8>?,
    _ haystackLength: Int,
    _ literal: UnsafePointer<UInt8>?,
    _ literalLength: Int,
    _ prefix: UnsafePointer<UInt8>?,
    _ prefixLength: Int,
    _ hasPrefix: Int32,
    _ prefixShouldMatch: Int32,
    _ suffix: UnsafePointer<UInt8>?,
    _ suffixLength: Int,
    _ hasSuffix: Int32,
    _ suffixShouldMatch: Int32,
    _ asciiCaseInsensitive: Int32
) -> rg_darwin_literal_file_result {
    unavailableDarwinFastPath()
}

func rg_darwin_write_byte_unit_pcre_o(
    _ base: UnsafePointer<UInt8>?,
    _ haystackLength: Int,
    _ mode: Int32,
    _ fixedCount: Int,
    _ unicodeStartOnly: Int32
) -> rg_darwin_literal_file_result {
    unavailableDarwinFastPath()
}
#endif
