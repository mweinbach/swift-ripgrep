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
private func rgASCIIIsAlpha(_ byte: UInt8) -> Bool {
    (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
        || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
}

@inline(__always)
private func rgSIMDFoldASCIIForCompare(_ bytes: SIMD16<UInt8>, isAlpha: Bool) -> SIMD16<UInt8> {
    isAlpha ? bytes | SIMD16<UInt8>(repeating: 0x20) : bytes
}

@inline(__always)
private func rgConstBytePointer(_ pointer: UnsafeMutableRawPointer?) -> UnsafePointer<UInt8>? {
    guard let pointer else {
        return nil
    }
    return UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
}

private func rgMemmemSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    needleLength: Int
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let tail = needle[needleLength - 1]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= needleLength + 15
        ? haystackLength - needleLength - 15 + 1
        : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + needleLength - 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = ((firstBytes .== firstVector) .& (tailBytes .== tailVector))._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                let candidate = haystack.advanced(by: cursor + lane)
                if needleLength <= 2
                    || memcmp(candidate.advanced(by: 1), needle.advanced(by: 1), needleLength - 2) == 0 {
                    return candidate
                }
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - needleLength + 1
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + needleLength - 1] == tail,
           needleLength <= 2
            || memcmp(
                haystack.advanced(by: cursor + 1),
                needle.advanced(by: 1),
                needleLength - 2
            ) == 0 {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

func rg_memmem_count_byte_before(
    _ haystack: UnsafePointer<UInt8>?,
    _ haystackLength: Int,
    _ needle: UnsafePointer<UInt8>?,
    _ needleLength: Int,
    _ byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    guard let haystack,
          let needle,
          haystackLength > 0,
          needleLength > 0,
          needleLength <= haystackLength else {
        return (nil, 0)
    }

    let first = needle[0]
    let tail = needle[needleLength - 1]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= needleLength + 15
        ? haystackLength - needleLength - 15 + 1
        : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + needleLength - 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = ((firstBytes .== firstVector) .& (tailBytes .== tailVector))._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                let candidate = haystack.advanced(by: cursor + lane)
                if needleLength <= 2
                    || memcmp(candidate.advanced(by: 1), needle.advanced(by: 1), needleLength - 2) == 0 {
                    for offset in 0..<lane where haystack[cursor + offset] == byte {
                        count += 1
                    }
                    return (candidate, count)
                }
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - needleLength + 1
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + needleLength - 1] == tail,
           needleLength <= 2
            || memcmp(
                haystack.advanced(by: cursor + 1),
                needle.advanced(by: 1),
                needleLength - 2
            ) == 0 {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

@inline(__always)
private func rgCaseInsensitiveMiddleMatches(
    candidate: UnsafePointer<UInt8>,
    foldedNeedle: UnsafePointer<UInt8>,
    needleLength: Int
) -> Bool {
    guard needleLength > 2 else {
        return true
    }
    var offset = 1
    while offset + 1 < needleLength {
        guard rgASCIILower(candidate[offset]) == foldedNeedle[offset] else {
            return false
        }
        offset += 1
    }
    return true
}

private func rgMemcaseMemASCII_SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    foldedNeedle: UnsafePointer<UInt8>,
    needleLength: Int
) -> UnsafePointer<UInt8>? {
    let first = foldedNeedle[0]
    let tail = foldedNeedle[needleLength - 1]
    let firstIsAlpha = rgASCIIIsAlpha(first)
    let tailIsAlpha = rgASCIIIsAlpha(tail)
    let firstVector = SIMD16<UInt8>(repeating: first)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= needleLength + 15
        ? haystackLength - needleLength - 15 + 1
        : 0
    while cursor < vectorLimit {
        let firstBytes = rgSIMDFoldASCIIForCompare(
            UnsafeRawPointer(haystack.advanced(by: cursor)).loadUnaligned(as: SIMD16<UInt8>.self),
            isAlpha: firstIsAlpha
        )
        let tailBytes = rgSIMDFoldASCIIForCompare(
            UnsafeRawPointer(haystack.advanced(by: cursor + needleLength - 1)).loadUnaligned(as: SIMD16<UInt8>.self),
            isAlpha: tailIsAlpha
        )
        let candidateStorage = ((firstBytes .== firstVector) .& (tailBytes .== tailVector))._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                let candidate = haystack.advanced(by: cursor + lane)
                if rgCaseInsensitiveMiddleMatches(
                    candidate: candidate,
                    foldedNeedle: foldedNeedle,
                    needleLength: needleLength
                ) {
                    return candidate
                }
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - needleLength + 1
    while cursor < maxStart {
        if rgASCIILower(haystack[cursor]) == first,
           rgASCIILower(haystack[cursor + needleLength - 1]) == tail,
           rgCaseInsensitiveMiddleMatches(
            candidate: haystack.advanced(by: cursor),
            foldedNeedle: foldedNeedle,
            needleLength: needleLength
           ) {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
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
    return rgMemmemSIMD16(
        haystack: haystack,
        haystackLength: haystackLength,
        needle: needle,
        needleLength: needleLength
    )
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
    _: UnsafePointer<Int>?
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
    if needleLength > 1 {
        return rgMemcaseMemASCII_SIMD16(
            haystack: haystack,
            haystackLength: haystackLength,
            foldedNeedle: foldedNeedle,
            needleLength: needleLength
        )
    }
    if needleLength == 1 {
        let folded = foldedNeedle[0]
        for index in 0..<haystackLength where rgASCIILower(haystack[index]) == folded {
            return haystack.advanced(by: index)
        }
        return nil
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

    if needleCount == 2, haystackLength >= 16 {
        let firstNeedle = SIMD16<UInt8>(repeating: needles[0])
        let secondNeedle = SIMD16<UInt8>(repeating: needles[1])
        var cursor = 0
        let vectorLimit = haystackLength - 15
        while cursor < vectorLimit {
            let bytes = UnsafeRawPointer(haystack.advanced(by: cursor))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let candidateStorage = ((bytes .== firstNeedle) .| (bytes .== secondNeedle))._storage
            if candidateStorage.min() < 0 {
                for lane in 0..<16 where candidateStorage[lane] != 0 {
                    return haystack.advanced(by: cursor + lane)
                }
            }
            cursor += 16
        }
        for index in cursor..<haystackLength {
            let byte = haystack[index]
            if byte == needles[0] || byte == needles[1] {
                return haystack.advanced(by: index)
            }
        }
        return nil
    }

    if needleCount <= 8, haystackLength >= 16 {
        var cursor = 0
        let vectorLimit = haystackLength - 15
        while cursor < vectorLimit {
            let bytes = UnsafeRawPointer(haystack.advanced(by: cursor))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            var matches = bytes .== SIMD16<UInt8>(repeating: needles[0])
            for index in 1..<needleCount {
                matches = matches .| (bytes .== SIMD16<UInt8>(repeating: needles[index]))
            }
            let candidateStorage = matches._storage
            if candidateStorage.min() < 0 {
                for lane in 0..<16 where candidateStorage[lane] != 0 {
                    return haystack.advanced(by: cursor + lane)
                }
            }
            cursor += 16
        }
        for index in cursor..<haystackLength {
            for needleIndex in 0..<needleCount where haystack[index] == needles[needleIndex] {
                return haystack.advanced(by: index)
            }
        }
        return nil
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

    if haystackLength >= 16 {
        let target = SIMD16<UInt8>(repeating: byte)
        let vectorLimit = haystackLength - 15
        while cursor < vectorLimit {
            let bytes = UnsafeRawPointer(haystack.advanced(by: cursor))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            count -= Int((bytes .== target)._storage.wrappedSum())
            cursor += 16
        }
    }

    while cursor < haystackLength {
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
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
