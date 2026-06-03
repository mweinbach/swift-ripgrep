import Foundation

#if canImport(Darwin)
enum GreekScriptByteProof {
    static func containsMatch(in data: Data, caseInsensitive: Bool) -> Bool {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            return containsMatch(in: bytes, caseInsensitive: caseInsensitive)
        }
    }

    static func containsMatch(
        in bytes: UnsafeBufferPointer<UInt8>,
        caseInsensitive: Bool
    ) -> Bool {
        guard let baseAddress = bytes.baseAddress else {
            return false
        }
        return candidateMatchOffset(
            bytes: bytes,
            baseAddress: baseAddress,
            start: 0,
            end: bytes.count,
            caseInsensitive: caseInsensitive
        ) != nil
    }

    private static func isGreekScriptUTF8Scalar(
        first: UInt8,
        second: UInt8,
        third: UInt8 = 0,
        fourth: UInt8 = 0,
        length: Int,
        caseInsensitive: Bool
    ) -> Bool {
        if length == 2 {
            if first == 0xC2 {
                return caseInsensitive && second == 0xB5
            }
            if first == 0xCD {
                return (0xB0...0xB3).contains(second)
                    || (0xB5...0xB7).contains(second)
                    || (0xBA...0xBD).contains(second)
                    || second == 0xBF
            }
            if first == 0xCE {
                return (0x84...0x8A).contains(second)
                    || second == 0x8C
                    || (0x8E...0xA1).contains(second)
                    || (0xA3...0xBF).contains(second)
            }
            if first == 0xCF {
                return (0x80...0xA1).contains(second)
                    || (0xB0...0xBF).contains(second)
            }
            return false
        }
        if length == 3 {
            return (first == 0xE1 && (0xBC...0xBF).contains(second))
                || (first == 0xE2 && second == 0x84 && third == 0xA6)
        }
        return (first == 0xF0
            && second == 0x90
            && ((third == 0x85 && (0x80...0xBF).contains(fourth))
                || (third == 0x86 && ((0x80...0x8F).contains(fourth) || fourth == 0xA0))))
            || (first == 0xF0
                && second == 0x9D
                && ((third == 0x88 && (0x80...0xBF).contains(fourth))
                    || (third == 0x89 && (0x80...0x8F).contains(fourth))))
    }

    @inline(__always)
    private static func isCandidateLeadByte(_ byte: UInt8, caseInsensitive: Bool) -> Bool {
        if byte >= 0xCD && byte <= 0xCF {
            return true
        }
        if byte == 0xE1 || byte == 0xE2 || byte == 0xF0 {
            return true
        }
        return caseInsensitive && byte == 0xC2
    }

    @inline(__always)
    private static func candidateLeadByteOffset(
        bytes: UnsafeBufferPointer<UInt8>,
        baseAddress: UnsafePointer<UInt8>,
        start: Int,
        end: Int,
        caseInsensitive: Bool
    ) -> Int? {
        var offset = start
        guard offset < end else {
            return nil
        }

        let greekLeadC2Vector = SIMD16<UInt8>(repeating: 0xC2)
        let greekLeadCDVector = SIMD16<UInt8>(repeating: 0xCD)
        let greekLeadCFVector = SIMD16<UInt8>(repeating: 0xCF)
        let greekLeadE1Vector = SIMD16<UInt8>(repeating: 0xE1)
        let greekLeadE2Vector = SIMD16<UInt8>(repeating: 0xE2)
        let greekLeadF0Vector = SIMD16<UInt8>(repeating: 0xF0)

        if end - offset >= 16 {
            let vectorLimit = end - 15
            while offset < vectorLimit {
                let byteVector = UnsafeRawPointer(baseAddress.advanced(by: offset))
                    .loadUnaligned(as: SIMD16<UInt8>.self)
                var matches = (byteVector .>= greekLeadCDVector) .& (byteVector .<= greekLeadCFVector)
                matches = matches
                    .| (byteVector .== greekLeadE1Vector)
                    .| (byteVector .== greekLeadE2Vector)
                    .| (byteVector .== greekLeadF0Vector)
                if caseInsensitive {
                    matches = matches .| (byteVector .== greekLeadC2Vector)
                }
                let candidateStorage = matches._storage
                if candidateStorage.min() < 0 {
                    for lane in 0..<16 where candidateStorage[lane] != 0 {
                        return offset + lane
                    }
                }
                offset += 16
            }
        }

        while offset < end {
            if isCandidateLeadByte(bytes[offset], caseInsensitive: caseInsensitive) {
                return offset
            }
            offset += 1
        }
        return nil
    }

    private static func candidateMatchOffset(
        bytes: UnsafeBufferPointer<UInt8>,
        baseAddress: UnsafePointer<UInt8>,
        start: Int,
        end: Int,
        caseInsensitive: Bool
    ) -> Int? {
        var offset = start
        while let candidate = candidateLeadByteOffset(
            bytes: bytes,
            baseAddress: baseAddress,
            start: offset,
            end: end,
            caseInsensitive: caseInsensitive
        ) {
            let first = bytes[candidate]
            if first == 0xC2 || first == 0xCD || first == 0xCE || first == 0xCF {
                if candidate + 2 <= end,
                   isGreekScriptUTF8Scalar(
                       first: first,
                       second: bytes[candidate + 1],
                       length: 2,
                       caseInsensitive: caseInsensitive
                   ) {
                    return candidate
                }
            } else if first == 0xE1 || first == 0xE2 {
                if candidate + 3 <= end,
                   (0x80...0xBF).contains(bytes[candidate + 2]),
                   isGreekScriptUTF8Scalar(
                       first: first,
                       second: bytes[candidate + 1],
                       third: bytes[candidate + 2],
                       length: 3,
                       caseInsensitive: caseInsensitive
                   ) {
                    return candidate
                }
            } else if first == 0xF0 {
                if candidate + 4 <= end,
                   isGreekScriptUTF8Scalar(
                       first: first,
                       second: bytes[candidate + 1],
                       third: bytes[candidate + 2],
                       fourth: bytes[candidate + 3],
                       length: 4,
                       caseInsensitive: caseInsensitive
                   ) {
                    return candidate
                }
            }
            offset = candidate + 1
        }
        return nil
    }
}
#endif
