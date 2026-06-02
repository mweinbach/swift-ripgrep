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

private func rgMemmem2SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let tail = needle[1]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= 17 ? haystackLength - 16 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = ((firstBytes .== firstVector) .& (tailBytes .== tailVector))._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                return haystack.advanced(by: cursor + lane)
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - 1
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == tail {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

private func rgMemmem3SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let middle = needle[1]
    let tail = needle[2]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= 18 ? haystackLength - 17 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                return haystack.advanced(by: cursor + lane)
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - 2
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == middle,
           haystack[cursor + 2] == tail {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

private func rgMemmem4SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let tail = needle[3]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= 19 ? haystackLength - 18 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = (
            (firstBytes .== firstVector)
                .& (secondBytes .== secondVector)
                .& (thirdBytes .== thirdVector)
                .& (tailBytes .== tailVector)
        )._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                return haystack.advanced(by: cursor + lane)
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - 3
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == tail {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

private func rgMemmem5SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let second = needle[1]
    let middle = needle[2]
    let fourth = needle[3]
    let tail = needle[4]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= 20 ? haystackLength - 19 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = (
            (firstBytes .== firstVector)
                .& (secondBytes .== secondVector)
                .& (middleBytes .== middleVector)
                .& (fourthBytes .== fourthVector)
                .& (tailBytes .== tailVector)
        )._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                return haystack.advanced(by: cursor + lane)
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - 4
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == middle,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == tail {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

private func rgMemmem6SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let middle = needle[3]
    let fifth = needle[4]
    let tail = needle[5]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let fifthVector = SIMD16<UInt8>(repeating: fifth)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= 21 ? haystackLength - 20 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let fifthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = (
            (firstBytes .== firstVector)
                .& (secondBytes .== secondVector)
                .& (thirdBytes .== thirdVector)
                .& (middleBytes .== middleVector)
                .& (fifthBytes .== fifthVector)
                .& (tailBytes .== tailVector)
        )._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                return haystack.advanced(by: cursor + lane)
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - 5
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == middle,
           haystack[cursor + 4] == fifth,
           haystack[cursor + 5] == tail {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

private func rgMemmem7SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let middle = needle[3]
    let fifth = needle[4]
    let sixth = needle[5]
    let tail = needle[6]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let fifthVector = SIMD16<UInt8>(repeating: fifth)
    let sixthVector = SIMD16<UInt8>(repeating: sixth)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= 22 ? haystackLength - 21 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let fifthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let sixthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = (
            (firstBytes .== firstVector)
                .& (secondBytes .== secondVector)
                .& (thirdBytes .== thirdVector)
                .& (middleBytes .== middleVector)
                .& (fifthBytes .== fifthVector)
                .& (sixthBytes .== sixthVector)
                .& (tailBytes .== tailVector)
        )._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                return haystack.advanced(by: cursor + lane)
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - 6
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == middle,
           haystack[cursor + 4] == fifth,
           haystack[cursor + 5] == sixth,
           haystack[cursor + 6] == tail {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

private func rgMemmem8SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let fourth = needle[3]
    let middle = needle[4]
    let sixth = needle[5]
    let seventh = needle[6]
    let tail = needle[7]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let sixthVector = SIMD16<UInt8>(repeating: sixth)
    let seventhVector = SIMD16<UInt8>(repeating: seventh)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= 23 ? haystackLength - 22 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 7))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let sixthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let seventhBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let exactStorage = (
                candidateMask
                    .& (secondBytes .== secondVector)
                    .& (thirdBytes .== thirdVector)
                    .& (fourthBytes .== fourthVector)
                    .& (sixthBytes .== sixthVector)
                    .& (seventhBytes .== seventhVector)
            )._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    return haystack.advanced(by: cursor + lane)
                }
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - 7
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == middle,
           haystack[cursor + 5] == sixth,
           haystack[cursor + 6] == seventh,
           haystack[cursor + 7] == tail {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

private func rgMemmem9SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let fourth = needle[3]
    let middle = needle[4]
    let sixth = needle[5]
    let seventh = needle[6]
    let eighth = needle[7]
    let tail = needle[8]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let sixthVector = SIMD16<UInt8>(repeating: sixth)
    let seventhVector = SIMD16<UInt8>(repeating: seventh)
    let eighthVector = SIMD16<UInt8>(repeating: eighth)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= 24 ? haystackLength - 23 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 8))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let sixthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let seventhBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let eighthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 7))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let exactStorage = (
                candidateMask
                    .& (secondBytes .== secondVector)
                    .& (thirdBytes .== thirdVector)
                    .& (fourthBytes .== fourthVector)
                    .& (sixthBytes .== sixthVector)
                    .& (seventhBytes .== seventhVector)
                    .& (eighthBytes .== eighthVector)
            )._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    return haystack.advanced(by: cursor + lane)
                }
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - 8
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == middle,
           haystack[cursor + 5] == sixth,
           haystack[cursor + 6] == seventh,
           haystack[cursor + 7] == eighth,
           haystack[cursor + 8] == tail {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

private func rgMemmem10SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let fourth = needle[3]
    let fifth = needle[4]
    let middle = needle[5]
    let seventh = needle[6]
    let eighth = needle[7]
    let ninth = needle[8]
    let tail = needle[9]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let fifthVector = SIMD16<UInt8>(repeating: fifth)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let seventhVector = SIMD16<UInt8>(repeating: seventh)
    let eighthVector = SIMD16<UInt8>(repeating: eighth)
    let ninthVector = SIMD16<UInt8>(repeating: ninth)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= 25 ? haystackLength - 24 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 9))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fifthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let seventhBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let eighthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 7))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let ninthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 8))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let exactStorage = (
                candidateMask
                    .& (secondBytes .== secondVector)
                    .& (thirdBytes .== thirdVector)
                    .& (fourthBytes .== fourthVector)
                    .& (fifthBytes .== fifthVector)
                    .& (seventhBytes .== seventhVector)
                    .& (eighthBytes .== eighthVector)
                    .& (ninthBytes .== ninthVector)
            )._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    return haystack.advanced(by: cursor + lane)
                }
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - 9
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == fifth,
           haystack[cursor + 5] == middle,
           haystack[cursor + 6] == seventh,
           haystack[cursor + 7] == eighth,
           haystack[cursor + 8] == ninth,
           haystack[cursor + 9] == tail {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

private func rgMemmem11SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let fourth = needle[3]
    let fifth = needle[4]
    let middle = needle[5]
    let seventh = needle[6]
    let eighth = needle[7]
    let ninth = needle[8]
    let tenth = needle[9]
    let tail = needle[10]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let fifthVector = SIMD16<UInt8>(repeating: fifth)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let seventhVector = SIMD16<UInt8>(repeating: seventh)
    let eighthVector = SIMD16<UInt8>(repeating: eighth)
    let ninthVector = SIMD16<UInt8>(repeating: ninth)
    let tenthVector = SIMD16<UInt8>(repeating: tenth)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= 26 ? haystackLength - 25 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 10))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fifthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let seventhBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let eighthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 7))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let ninthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 8))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let tenthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 9))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let exactStorage = (
                candidateMask
                    .& (secondBytes .== secondVector)
                    .& (thirdBytes .== thirdVector)
                    .& (fourthBytes .== fourthVector)
                    .& (fifthBytes .== fifthVector)
                    .& (seventhBytes .== seventhVector)
                    .& (eighthBytes .== eighthVector)
                    .& (ninthBytes .== ninthVector)
                    .& (tenthBytes .== tenthVector)
            )._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    return haystack.advanced(by: cursor + lane)
                }
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - 10
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == fifth,
           haystack[cursor + 5] == middle,
           haystack[cursor + 6] == seventh,
           haystack[cursor + 7] == eighth,
           haystack[cursor + 8] == ninth,
           haystack[cursor + 9] == tenth,
           haystack[cursor + 10] == tail {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

private func rgMemmem12SIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let fourth = needle[3]
    let fifth = needle[4]
    let sixth = needle[5]
    let middle = needle[6]
    let eighth = needle[7]
    let ninth = needle[8]
    let tenth = needle[9]
    let eleventh = needle[10]
    let tail = needle[11]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let fifthVector = SIMD16<UInt8>(repeating: fifth)
    let sixthVector = SIMD16<UInt8>(repeating: sixth)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let eighthVector = SIMD16<UInt8>(repeating: eighth)
    let ninthVector = SIMD16<UInt8>(repeating: ninth)
    let tenthVector = SIMD16<UInt8>(repeating: tenth)
    let eleventhVector = SIMD16<UInt8>(repeating: eleventh)
    let tailVector = SIMD16<UInt8>(repeating: tail)

    var cursor = 0
    let vectorLimit = haystackLength >= 27 ? haystackLength - 26 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 11))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fifthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let sixthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let eighthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 7))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let ninthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 8))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let tenthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 9))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let eleventhBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 10))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let exactStorage = (
                candidateMask
                    .& (secondBytes .== secondVector)
                    .& (thirdBytes .== thirdVector)
                    .& (fourthBytes .== fourthVector)
                    .& (fifthBytes .== fifthVector)
                    .& (sixthBytes .== sixthVector)
                    .& (eighthBytes .== eighthVector)
                    .& (ninthBytes .== ninthVector)
                    .& (tenthBytes .== tenthVector)
                    .& (eleventhBytes .== eleventhVector)
            )._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    return haystack.advanced(by: cursor + lane)
                }
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - 11
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == fifth,
           haystack[cursor + 5] == sixth,
           haystack[cursor + 6] == middle,
           haystack[cursor + 7] == eighth,
           haystack[cursor + 8] == ninth,
           haystack[cursor + 9] == tenth,
           haystack[cursor + 10] == eleventh,
           haystack[cursor + 11] == tail {
            return haystack.advanced(by: cursor)
        }
        cursor += 1
    }
    return nil
}

private func rgMemmemProofScore(_ byte: UInt8) -> Int {
    switch byte {
    case 113, 122, 120, 106: // q z x j
        return 0
    case 107, 118, 98, 112: // k v b p
        return 1
    case 121, 103, 119, 102: // y g w f
        return 2
    case 109, 99, 117, 108: // m c u l
        return 3
    case 100, 114, 104, 115, 110: // d r h s n
        return 4
    case 105, 111, 97: // i o a
        return 5
    case 101, 116: // e t
        return 6
    case 32:
        return 7
    default:
        return 2
    }
}

private func rgMemmemStagedExactSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    needleLength: Int
) -> UnsafePointer<UInt8>? {
    let first = needle[0]
    let tail = needle[needleLength - 1]
    let middleIndex = needleLength / 2
    let middle = needle[middleIndex]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let firstWord = UnsafeRawPointer(needle)
        .loadUnaligned(as: UInt64.self)
    let tailWordOffset = needleLength - 8
    let tailWord = UnsafeRawPointer(needle.advanced(by: tailWordOffset))
        .loadUnaligned(as: UInt64.self)
    let proofOffset = 1
    let proofVector = SIMD16<UInt8>(repeating: needle[proofOffset])

    var cursor = 0
    let vectorLimit = haystackLength >= needleLength + 15
        ? haystackLength - needleLength - 15 + 1
        : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + middleIndex))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + needleLength - 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let proofBytes = UnsafeRawPointer(haystack.advanced(by: cursor + proofOffset))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            var exactMask = candidateMask .& (proofBytes .== proofVector)
            var offset = 1
            while exactMask._storage.min() < 0, offset < needleLength - 1 {
                if offset != middleIndex, offset != proofOffset {
                    let bytes = UnsafeRawPointer(haystack.advanced(by: cursor + offset))
                        .loadUnaligned(as: SIMD16<UInt8>.self)
                    exactMask = exactMask .& (bytes .== SIMD16<UInt8>(repeating: needle[offset]))
                }
                offset += 1
            }
            let exactStorage = exactMask._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    return haystack.advanced(by: cursor + lane)
                }
            }
        }
        cursor += 16
    }

    let maxStart = haystackLength - needleLength + 1
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + middleIndex] == middle,
           haystack[cursor + needleLength - 1] == tail {
            let candidate = haystack.advanced(by: cursor)
            if UnsafeRawPointer(candidate).loadUnaligned(as: UInt64.self) == firstWord,
               UnsafeRawPointer(candidate.advanced(by: tailWordOffset)).loadUnaligned(as: UInt64.self) == tailWord {
                return candidate
            }
        }
        cursor += 1
    }
    return nil
}

private func rgMemmemSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    needleLength: Int
) -> UnsafePointer<UInt8>? {
    if needleLength == 2 {
        return rgMemmem2SIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle)
    }
    if needleLength == 3 {
        return rgMemmem3SIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle)
    }
    if needleLength == 4 {
        return rgMemmem4SIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle)
    }
    if needleLength == 5 {
        return rgMemmem5SIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle)
    }
    if needleLength == 6 {
        return rgMemmem6SIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle)
    }
    if needleLength == 7 {
        return rgMemmem7SIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle)
    }
    if needleLength == 8 {
        return rgMemmem8SIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle)
    }
    if needleLength == 9 {
        return rgMemmem9SIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle)
    }
    if needleLength == 10 {
        return rgMemmem10SIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle)
    }
    if needleLength == 11 {
        return rgMemmem11SIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle)
    }
    if needleLength == 12 {
        return rgMemmem12SIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle)
    }
    if needleLength >= 13, needleLength <= 16 {
        if rgMemmemProofScore(needle[1]) <= 1 {
            return rgMemmemStagedExactSIMD16(
                haystack: haystack,
                haystackLength: haystackLength,
                needle: needle,
                needleLength: needleLength
            )
        }
    }

    let first = needle[0]
    let tail = needle[needleLength - 1]
    let useMiddle = needleLength > 2
    let middleIndex = needleLength / 2
    let middle = useMiddle ? needle[middleIndex] : 0
    let firstVector = SIMD16<UInt8>(repeating: first)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let middleVector = SIMD16<UInt8>(repeating: middle)

    var cursor = 0
    let vectorLimit = haystackLength >= needleLength + 15
        ? haystackLength - needleLength - 15 + 1
        : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + needleLength - 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        var candidateMask = (firstBytes .== firstVector) .& (tailBytes .== tailVector)
        if useMiddle {
            let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + middleIndex))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            candidateMask = candidateMask .& (middleBytes .== middleVector)
        }
        let candidateStorage = candidateMask._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                let candidate = haystack.advanced(by: cursor + lane)
                if needleLength <= 3
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
           (!useMiddle || haystack[cursor + middleIndex] == middle),
           needleLength <= 3
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

private func rgMemmem2CountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let tail = needle[1]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= 17 ? haystackLength - 16 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = ((firstBytes .== firstVector) .& (tailBytes .== tailVector))._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                for offset in 0..<lane where haystack[cursor + offset] == byte {
                    count += 1
                }
                return (haystack.advanced(by: cursor + lane), count)
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - 1
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == tail {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

private func rgMemmem3CountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let middle = needle[1]
    let tail = needle[2]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= 18 ? haystackLength - 17 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                for offset in 0..<lane where haystack[cursor + offset] == byte {
                    count += 1
                }
                return (haystack.advanced(by: cursor + lane), count)
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - 2
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == middle,
           haystack[cursor + 2] == tail {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

private func rgMemmem4CountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let tail = needle[3]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= 19 ? haystackLength - 18 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = (
            (firstBytes .== firstVector)
                .& (secondBytes .== secondVector)
                .& (thirdBytes .== thirdVector)
                .& (tailBytes .== tailVector)
        )._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                for offset in 0..<lane where haystack[cursor + offset] == byte {
                    count += 1
                }
                return (haystack.advanced(by: cursor + lane), count)
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - 3
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == tail {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

private func rgMemmem5CountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let second = needle[1]
    let middle = needle[2]
    let fourth = needle[3]
    let tail = needle[4]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= 20 ? haystackLength - 19 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = (
            (firstBytes .== firstVector)
                .& (secondBytes .== secondVector)
                .& (middleBytes .== middleVector)
                .& (fourthBytes .== fourthVector)
                .& (tailBytes .== tailVector)
        )._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                for offset in 0..<lane where haystack[cursor + offset] == byte {
                    count += 1
                }
                return (haystack.advanced(by: cursor + lane), count)
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - 4
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == middle,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == tail {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

private func rgMemmem6CountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let middle = needle[3]
    let fifth = needle[4]
    let tail = needle[5]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let fifthVector = SIMD16<UInt8>(repeating: fifth)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= 21 ? haystackLength - 20 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let fifthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = (
            (firstBytes .== firstVector)
                .& (secondBytes .== secondVector)
                .& (thirdBytes .== thirdVector)
                .& (middleBytes .== middleVector)
                .& (fifthBytes .== fifthVector)
                .& (tailBytes .== tailVector)
        )._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                for offset in 0..<lane where haystack[cursor + offset] == byte {
                    count += 1
                }
                return (haystack.advanced(by: cursor + lane), count)
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - 5
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == middle,
           haystack[cursor + 4] == fifth,
           haystack[cursor + 5] == tail {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

private func rgMemmem7CountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let middle = needle[3]
    let fifth = needle[4]
    let sixth = needle[5]
    let tail = needle[6]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let fifthVector = SIMD16<UInt8>(repeating: fifth)
    let sixthVector = SIMD16<UInt8>(repeating: sixth)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= 22 ? haystackLength - 21 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let fifthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let sixthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateStorage = (
            (firstBytes .== firstVector)
                .& (secondBytes .== secondVector)
                .& (thirdBytes .== thirdVector)
                .& (middleBytes .== middleVector)
                .& (fifthBytes .== fifthVector)
                .& (sixthBytes .== sixthVector)
                .& (tailBytes .== tailVector)
        )._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                for offset in 0..<lane where haystack[cursor + offset] == byte {
                    count += 1
                }
                return (haystack.advanced(by: cursor + lane), count)
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - 6
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == middle,
           haystack[cursor + 4] == fifth,
           haystack[cursor + 5] == sixth,
           haystack[cursor + 6] == tail {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

private func rgMemmem8CountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let fourth = needle[3]
    let middle = needle[4]
    let sixth = needle[5]
    let seventh = needle[6]
    let tail = needle[7]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let sixthVector = SIMD16<UInt8>(repeating: sixth)
    let seventhVector = SIMD16<UInt8>(repeating: seventh)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= 23 ? haystackLength - 22 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 7))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let sixthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let seventhBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let exactStorage = (
                candidateMask
                    .& (secondBytes .== secondVector)
                    .& (thirdBytes .== thirdVector)
                    .& (fourthBytes .== fourthVector)
                    .& (sixthBytes .== sixthVector)
                    .& (seventhBytes .== seventhVector)
            )._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    for offset in 0..<lane where haystack[cursor + offset] == byte {
                        count += 1
                    }
                    return (haystack.advanced(by: cursor + lane), count)
                }
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - 7
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == middle,
           haystack[cursor + 5] == sixth,
           haystack[cursor + 6] == seventh,
           haystack[cursor + 7] == tail {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

private func rgMemmem9CountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let fourth = needle[3]
    let middle = needle[4]
    let sixth = needle[5]
    let seventh = needle[6]
    let eighth = needle[7]
    let tail = needle[8]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let sixthVector = SIMD16<UInt8>(repeating: sixth)
    let seventhVector = SIMD16<UInt8>(repeating: seventh)
    let eighthVector = SIMD16<UInt8>(repeating: eighth)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= 24 ? haystackLength - 23 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 8))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let sixthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let seventhBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let eighthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 7))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let exactStorage = (
                candidateMask
                    .& (secondBytes .== secondVector)
                    .& (thirdBytes .== thirdVector)
                    .& (fourthBytes .== fourthVector)
                    .& (sixthBytes .== sixthVector)
                    .& (seventhBytes .== seventhVector)
                    .& (eighthBytes .== eighthVector)
            )._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    for offset in 0..<lane where haystack[cursor + offset] == byte {
                        count += 1
                    }
                    return (haystack.advanced(by: cursor + lane), count)
                }
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - 8
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == middle,
           haystack[cursor + 5] == sixth,
           haystack[cursor + 6] == seventh,
           haystack[cursor + 7] == eighth,
           haystack[cursor + 8] == tail {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

private func rgMemmem10CountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let fourth = needle[3]
    let fifth = needle[4]
    let middle = needle[5]
    let seventh = needle[6]
    let eighth = needle[7]
    let ninth = needle[8]
    let tail = needle[9]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let fifthVector = SIMD16<UInt8>(repeating: fifth)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let seventhVector = SIMD16<UInt8>(repeating: seventh)
    let eighthVector = SIMD16<UInt8>(repeating: eighth)
    let ninthVector = SIMD16<UInt8>(repeating: ninth)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= 25 ? haystackLength - 24 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 9))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fifthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let seventhBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let eighthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 7))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let ninthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 8))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let exactStorage = (
                candidateMask
                    .& (secondBytes .== secondVector)
                    .& (thirdBytes .== thirdVector)
                    .& (fourthBytes .== fourthVector)
                    .& (fifthBytes .== fifthVector)
                    .& (seventhBytes .== seventhVector)
                    .& (eighthBytes .== eighthVector)
                    .& (ninthBytes .== ninthVector)
            )._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    for offset in 0..<lane where haystack[cursor + offset] == byte {
                        count += 1
                    }
                    return (haystack.advanced(by: cursor + lane), count)
                }
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - 9
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == fifth,
           haystack[cursor + 5] == middle,
           haystack[cursor + 6] == seventh,
           haystack[cursor + 7] == eighth,
           haystack[cursor + 8] == ninth,
           haystack[cursor + 9] == tail {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

private func rgMemmem11CountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let fourth = needle[3]
    let fifth = needle[4]
    let middle = needle[5]
    let seventh = needle[6]
    let eighth = needle[7]
    let ninth = needle[8]
    let tenth = needle[9]
    let tail = needle[10]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let fifthVector = SIMD16<UInt8>(repeating: fifth)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let seventhVector = SIMD16<UInt8>(repeating: seventh)
    let eighthVector = SIMD16<UInt8>(repeating: eighth)
    let ninthVector = SIMD16<UInt8>(repeating: ninth)
    let tenthVector = SIMD16<UInt8>(repeating: tenth)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= 26 ? haystackLength - 25 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 10))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fifthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let seventhBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let eighthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 7))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let ninthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 8))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let tenthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 9))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let exactStorage = (
                candidateMask
                    .& (secondBytes .== secondVector)
                    .& (thirdBytes .== thirdVector)
                    .& (fourthBytes .== fourthVector)
                    .& (fifthBytes .== fifthVector)
                    .& (seventhBytes .== seventhVector)
                    .& (eighthBytes .== eighthVector)
                    .& (ninthBytes .== ninthVector)
                    .& (tenthBytes .== tenthVector)
            )._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    for offset in 0..<lane where haystack[cursor + offset] == byte {
                        count += 1
                    }
                    return (haystack.advanced(by: cursor + lane), count)
                }
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - 10
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == fifth,
           haystack[cursor + 5] == middle,
           haystack[cursor + 6] == seventh,
           haystack[cursor + 7] == eighth,
           haystack[cursor + 8] == ninth,
           haystack[cursor + 9] == tenth,
           haystack[cursor + 10] == tail {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

private func rgMemmem12CountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let second = needle[1]
    let third = needle[2]
    let fourth = needle[3]
    let fifth = needle[4]
    let sixth = needle[5]
    let middle = needle[6]
    let eighth = needle[7]
    let ninth = needle[8]
    let tenth = needle[9]
    let eleventh = needle[10]
    let tail = needle[11]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let secondVector = SIMD16<UInt8>(repeating: second)
    let thirdVector = SIMD16<UInt8>(repeating: third)
    let fourthVector = SIMD16<UInt8>(repeating: fourth)
    let fifthVector = SIMD16<UInt8>(repeating: fifth)
    let sixthVector = SIMD16<UInt8>(repeating: sixth)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let eighthVector = SIMD16<UInt8>(repeating: eighth)
    let ninthVector = SIMD16<UInt8>(repeating: ninth)
    let tenthVector = SIMD16<UInt8>(repeating: tenth)
    let eleventhVector = SIMD16<UInt8>(repeating: eleventh)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= 27 ? haystackLength - 26 : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 6))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 11))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let secondBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 1))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let thirdBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 2))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fourthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 3))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let fifthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 4))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let sixthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 5))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let eighthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 7))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let ninthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 8))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let tenthBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 9))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let eleventhBytes = UnsafeRawPointer(haystack.advanced(by: cursor + 10))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            let exactStorage = (
                candidateMask
                    .& (secondBytes .== secondVector)
                    .& (thirdBytes .== thirdVector)
                    .& (fourthBytes .== fourthVector)
                    .& (fifthBytes .== fifthVector)
                    .& (sixthBytes .== sixthVector)
                    .& (eighthBytes .== eighthVector)
                    .& (ninthBytes .== ninthVector)
                    .& (tenthBytes .== tenthVector)
                    .& (eleventhBytes .== eleventhVector)
            )._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    for offset in 0..<lane where haystack[cursor + offset] == byte {
                        count += 1
                    }
                    return (haystack.advanced(by: cursor + lane), count)
                }
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - 11
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + 1] == second,
           haystack[cursor + 2] == third,
           haystack[cursor + 3] == fourth,
           haystack[cursor + 4] == fifth,
           haystack[cursor + 5] == sixth,
           haystack[cursor + 6] == middle,
           haystack[cursor + 7] == eighth,
           haystack[cursor + 8] == ninth,
           haystack[cursor + 9] == tenth,
           haystack[cursor + 10] == eleventh,
           haystack[cursor + 11] == tail {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
}

private func rgMemmemStagedExactCountByteBeforeSIMD16(
    haystack: UnsafePointer<UInt8>,
    haystackLength: Int,
    needle: UnsafePointer<UInt8>,
    needleLength: Int,
    byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    let first = needle[0]
    let tail = needle[needleLength - 1]
    let middleIndex = needleLength / 2
    let middle = needle[middleIndex]
    let firstVector = SIMD16<UInt8>(repeating: first)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let countVector = SIMD16<UInt8>(repeating: byte)
    let firstWord = UnsafeRawPointer(needle)
        .loadUnaligned(as: UInt64.self)
    let tailWordOffset = needleLength - 8
    let tailWord = UnsafeRawPointer(needle.advanced(by: tailWordOffset))
        .loadUnaligned(as: UInt64.self)
    let proofOffset = 1
    let proofVector = SIMD16<UInt8>(repeating: needle[proofOffset])

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= needleLength + 15
        ? haystackLength - needleLength - 15 + 1
        : 0
    while cursor < vectorLimit {
        let firstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + middleIndex))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let tailBytes = UnsafeRawPointer(haystack.advanced(by: cursor + needleLength - 1))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let candidateMask = (
            (firstBytes .== firstVector)
                .& (middleBytes .== middleVector)
                .& (tailBytes .== tailVector)
        )
        if candidateMask._storage.min() < 0 {
            let proofBytes = UnsafeRawPointer(haystack.advanced(by: cursor + proofOffset))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            var exactMask = candidateMask .& (proofBytes .== proofVector)
            var offset = 1
            while exactMask._storage.min() < 0, offset < needleLength - 1 {
                if offset != middleIndex, offset != proofOffset {
                    let bytes = UnsafeRawPointer(haystack.advanced(by: cursor + offset))
                        .loadUnaligned(as: SIMD16<UInt8>.self)
                    exactMask = exactMask .& (bytes .== SIMD16<UInt8>(repeating: needle[offset]))
                }
                offset += 1
            }
            let exactStorage = exactMask._storage
            if exactStorage.min() < 0 {
                for lane in 0..<16 where exactStorage[lane] != 0 {
                    for offset in 0..<lane where haystack[cursor + offset] == byte {
                        count += 1
                    }
                    return (haystack.advanced(by: cursor + lane), count)
                }
            }
        }
        count -= Int((firstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - needleLength + 1
    while cursor < maxStart {
        if haystack[cursor] == first,
           haystack[cursor + middleIndex] == middle,
           haystack[cursor + needleLength - 1] == tail {
            let candidate = haystack.advanced(by: cursor)
            if UnsafeRawPointer(candidate).loadUnaligned(as: UInt64.self) == firstWord,
               UnsafeRawPointer(candidate.advanced(by: tailWordOffset)).loadUnaligned(as: UInt64.self) == tailWord {
                return (candidate, count)
            }
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
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

    if needleLength == 2 {
        return rgMemmem2CountByteBeforeSIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle, byte: byte)
    }
    if needleLength == 3 {
        return rgMemmem3CountByteBeforeSIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle, byte: byte)
    }
    if needleLength == 4 {
        return rgMemmem4CountByteBeforeSIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle, byte: byte)
    }
    if needleLength == 5 {
        return rgMemmem5CountByteBeforeSIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle, byte: byte)
    }
    if needleLength == 6 {
        return rgMemmem6CountByteBeforeSIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle, byte: byte)
    }
    if needleLength == 7 {
        return rgMemmem7CountByteBeforeSIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle, byte: byte)
    }
    if needleLength == 8 {
        return rgMemmem8CountByteBeforeSIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle, byte: byte)
    }
    if needleLength == 9 {
        return rgMemmem9CountByteBeforeSIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle, byte: byte)
    }
    if needleLength == 10 {
        return rgMemmem10CountByteBeforeSIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle, byte: byte)
    }
    if needleLength == 11 {
        return rgMemmem11CountByteBeforeSIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle, byte: byte)
    }
    if needleLength == 12 {
        return rgMemmem12CountByteBeforeSIMD16(haystack: haystack, haystackLength: haystackLength, needle: needle, byte: byte)
    }
    if needleLength >= 13, needleLength <= 16 {
        if rgMemmemProofScore(needle[1]) <= 1 {
            return rgMemmemStagedExactCountByteBeforeSIMD16(
                haystack: haystack,
                haystackLength: haystackLength,
                needle: needle,
                needleLength: needleLength,
                byte: byte
            )
        }
    }

    let first = needle[0]
    let tail = needle[needleLength - 1]
    let useMiddle = needleLength > 2
    let middleIndex = needleLength / 2
    let middle = useMiddle ? needle[middleIndex] : 0
    let firstVector = SIMD16<UInt8>(repeating: first)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let middleVector = SIMD16<UInt8>(repeating: middle)
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
        var candidateMask = (firstBytes .== firstVector) .& (tailBytes .== tailVector)
        if useMiddle {
            let middleBytes = UnsafeRawPointer(haystack.advanced(by: cursor + middleIndex))
                .loadUnaligned(as: SIMD16<UInt8>.self)
            candidateMask = candidateMask .& (middleBytes .== middleVector)
        }
        let candidateStorage = candidateMask._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                let candidate = haystack.advanced(by: cursor + lane)
                if needleLength <= 3
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
           (!useMiddle || haystack[cursor + middleIndex] == middle),
           needleLength <= 3
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
    let middleIndex = needleLength / 2
    let useMiddle = needleLength >= 8
        && middleIndex > 0
        && middleIndex < needleLength - 1
    let middle = foldedNeedle[middleIndex]
    let firstIsAlpha = rgASCIIIsAlpha(first)
    let tailIsAlpha = rgASCIIIsAlpha(tail)
    let middleIsAlpha = rgASCIIIsAlpha(middle)
    let firstVector = SIMD16<UInt8>(repeating: first)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let middleVector = SIMD16<UInt8>(repeating: middle)

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
        var candidateMask = (firstBytes .== firstVector) .& (tailBytes .== tailVector)
        if useMiddle {
            let middleBytes = rgSIMDFoldASCIIForCompare(
                UnsafeRawPointer(haystack.advanced(by: cursor + middleIndex)).loadUnaligned(as: SIMD16<UInt8>.self),
                isAlpha: middleIsAlpha
            )
            candidateMask = candidateMask .& (middleBytes .== middleVector)
        }
        let candidateStorage = candidateMask._storage
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
           (!useMiddle || rgASCIILower(haystack[cursor + middleIndex]) == middle),
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

func rg_memcasemem_ascii_count_byte_before(
    _ haystack: UnsafePointer<UInt8>?,
    _ haystackLength: Int,
    _ foldedNeedle: UnsafePointer<UInt8>?,
    _ needleLength: Int,
    _ byte: UInt8
) -> (match: UnsafePointer<UInt8>?, count: Int) {
    guard let haystack, let foldedNeedle else {
        return (nil, 0)
    }
    guard haystackLength > 0, needleLength > 0, haystackLength >= needleLength else {
        return (nil, 0)
    }

    let first = foldedNeedle[0]
    let tail = foldedNeedle[needleLength - 1]
    let middleIndex = needleLength / 2
    let useMiddle = needleLength >= 8
        && middleIndex > 0
        && middleIndex < needleLength - 1
    let middle = foldedNeedle[middleIndex]
    let firstIsAlpha = rgASCIIIsAlpha(first)
    let tailIsAlpha = rgASCIIIsAlpha(tail)
    let middleIsAlpha = rgASCIIIsAlpha(middle)
    let firstVector = SIMD16<UInt8>(repeating: first)
    let tailVector = SIMD16<UInt8>(repeating: tail)
    let middleVector = SIMD16<UInt8>(repeating: middle)
    let countVector = SIMD16<UInt8>(repeating: byte)

    var count = 0
    var cursor = 0
    let vectorLimit = haystackLength >= needleLength + 15
        ? haystackLength - needleLength - 15 + 1
        : 0
    while cursor < vectorLimit {
        let rawFirstBytes = UnsafeRawPointer(haystack.advanced(by: cursor))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let firstBytes = rgSIMDFoldASCIIForCompare(rawFirstBytes, isAlpha: firstIsAlpha)
        let tailBytes = rgSIMDFoldASCIIForCompare(
            UnsafeRawPointer(haystack.advanced(by: cursor + needleLength - 1))
                .loadUnaligned(as: SIMD16<UInt8>.self),
            isAlpha: tailIsAlpha
        )
        var candidateMask = (firstBytes .== firstVector) .& (tailBytes .== tailVector)
        if useMiddle {
            let middleBytes = rgSIMDFoldASCIIForCompare(
                UnsafeRawPointer(haystack.advanced(by: cursor + middleIndex))
                    .loadUnaligned(as: SIMD16<UInt8>.self),
                isAlpha: middleIsAlpha
            )
            candidateMask = candidateMask .& (middleBytes .== middleVector)
        }
        let candidateStorage = candidateMask._storage
        if candidateStorage.min() < 0 {
            for lane in 0..<16 where candidateStorage[lane] != 0 {
                let candidate = haystack.advanced(by: cursor + lane)
                if rgCaseInsensitiveMiddleMatches(
                    candidate: candidate,
                    foldedNeedle: foldedNeedle,
                    needleLength: needleLength
                ) {
                    for offset in 0..<lane where haystack[cursor + offset] == byte {
                        count += 1
                    }
                    return (candidate, count)
                }
            }
        }
        count -= Int((rawFirstBytes .== countVector)._storage.wrappedSum())
        cursor += 16
    }

    let maxStart = haystackLength - needleLength + 1
    while cursor < maxStart {
        if rgASCIILower(haystack[cursor]) == first,
           rgASCIILower(haystack[cursor + needleLength - 1]) == tail,
           (!useMiddle || rgASCIILower(haystack[cursor + middleIndex]) == middle),
           rgCaseInsensitiveMiddleMatches(
            candidate: haystack.advanced(by: cursor),
            foldedNeedle: foldedNeedle,
            needleLength: needleLength
           ) {
            return (haystack.advanced(by: cursor), count)
        }
        if haystack[cursor] == byte {
            count += 1
        }
        cursor += 1
    }
    return (nil, count)
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
