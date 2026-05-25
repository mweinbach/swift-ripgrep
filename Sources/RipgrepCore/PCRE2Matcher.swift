import Foundation
#if canImport(CRipgrepPlatform)
import CRipgrepPlatform
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct PCRE2Backend {
    static let versionDescription = "PCRE2-compatible Swift regex engine is available (libpcre2 is not linked; JIT is unavailable)"
}

final class PCRE2CompiledPattern {
    private enum Matcher {
        case regex(NSRegularExpression)
        case fixedPositiveLookbehind(prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)
        case fixedNegativeLookbehind(prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)
        case fixedPositiveLookahead(literal: [UInt8], suffix: [UInt8], caseInsensitiveASCII: Bool)
        case fixedNegativeLookahead(literal: [UInt8], suffix: [UInt8], caseInsensitiveASCII: Bool)
        case fixedLiteralBackreference(literal: [UInt8], captureRanges: [Range<Int>], caseInsensitiveASCII: Bool)
    }

    let source: String
    private let matcher: Matcher

    var fixedPositiveLookbehindFastPath: (prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)? {
        guard case .fixedPositiveLookbehind(let prefix, let literal, let caseInsensitiveASCII) = matcher else {
            return nil
        }
        return (prefix, literal, caseInsensitiveASCII)
    }

    var fixedPositiveLookaheadFastPath: (literal: [UInt8], suffix: [UInt8], caseInsensitiveASCII: Bool)? {
        guard case .fixedPositiveLookahead(let literal, let suffix, let caseInsensitiveASCII) = matcher else {
            return nil
        }
        return (literal, suffix, caseInsensitiveASCII)
    }

    var fixedNegativeLookbehindFastPath: (prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)? {
        guard case .fixedNegativeLookbehind(let prefix, let literal, let caseInsensitiveASCII) = matcher else {
            return nil
        }
        return (prefix, literal, caseInsensitiveASCII)
    }

    var fixedNegativeLookaheadFastPath: (literal: [UInt8], suffix: [UInt8], caseInsensitiveASCII: Bool)? {
        guard case .fixedNegativeLookahead(let literal, let suffix, let caseInsensitiveASCII) = matcher else {
            return nil
        }
        return (literal, suffix, caseInsensitiveASCII)
    }

    var fixedLiteralBackreferenceFastPath: (literal: [UInt8], caseInsensitiveASCII: Bool)? {
        guard case .fixedLiteralBackreference(let literal, _, let caseInsensitiveASCII) = matcher else {
            return nil
        }
        return (literal, caseInsensitiveASCII)
    }

    init(pattern: String, options: RipgrepOptions) throws {
        self.source = pattern
        #if canImport(CRipgrepPlatform)
        let canUseFixedByteMatcher = !options.effectiveIgnoreCase || options.noUnicode
        let caseInsensitiveASCII = options.effectiveIgnoreCase && options.noUnicode
        if canUseFixedByteMatcher,
           let lookbehind = Self.fixedPositiveLookbehind(pattern) {
            self.matcher = .fixedPositiveLookbehind(
                prefix: Array(lookbehind.prefix.utf8),
                literal: Array(lookbehind.literal.utf8),
                caseInsensitiveASCII: caseInsensitiveASCII
            )
            return
        }
        if canUseFixedByteMatcher,
           let lookahead = Self.fixedPositiveLookahead(pattern) {
            self.matcher = .fixedPositiveLookahead(
                literal: Array(lookahead.literal.utf8),
                suffix: Array(lookahead.suffix.utf8),
                caseInsensitiveASCII: caseInsensitiveASCII
            )
            return
        }
        if canUseFixedByteMatcher,
           let lookbehind = Self.fixedNegativeLookbehind(pattern) {
            self.matcher = .fixedNegativeLookbehind(
                prefix: Array(lookbehind.prefix.utf8),
                literal: Array(lookbehind.literal.utf8),
                caseInsensitiveASCII: caseInsensitiveASCII
            )
            return
        }
        if canUseFixedByteMatcher,
           let lookahead = Self.fixedNegativeLookahead(pattern) {
            self.matcher = .fixedNegativeLookahead(
                literal: Array(lookahead.literal.utf8),
                suffix: Array(lookahead.suffix.utf8),
                caseInsensitiveASCII: caseInsensitiveASCII
            )
            return
        }
        if canUseFixedByteMatcher,
           let backreference = Self.fixedLiteralBackreference(pattern) {
            self.matcher = .fixedLiteralBackreference(
                literal: Array(backreference.literal.utf8),
                captureRanges: backreference.captureRanges,
                caseInsensitiveASCII: caseInsensitiveASCII
            )
            return
        }
        #endif

        var regexOptions: NSRegularExpression.Options = []
        if options.effectiveIgnoreCase {
            regexOptions.insert(.caseInsensitive)
        }
        if !options.crlf {
            regexOptions.insert(.anchorsMatchLines)
        }
        if options.multiline && options.multilineDotall {
            regexOptions.insert(.dotMatchesLineSeparators)
        }

        do {
            self.matcher = .regex(try NSRegularExpression(pattern: pattern, options: regexOptions))
        } catch {
            throw RipgrepError.message(Self.compileErrorMessage(pattern: pattern, error: error))
        }
    }

    func matches(in text: String) -> [PCRE2Match] {
        switch matcher {
        case .regex(let regex):
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Self.match(from: match, in: text)
            }
        case .fixedPositiveLookbehind(let prefix, let literal, let caseInsensitiveASCII):
            return Self.fixedPositiveLookbehindMatches(
                prefix: prefix,
                literal: literal,
                caseInsensitiveASCII: caseInsensitiveASCII,
                in: text
            )
        case .fixedPositiveLookahead(let literal, let suffix, let caseInsensitiveASCII):
            return Self.fixedPositiveLookaheadMatches(
                literal: literal,
                suffix: suffix,
                caseInsensitiveASCII: caseInsensitiveASCII,
                in: text
            )
        case .fixedNegativeLookbehind(let prefix, let literal, let caseInsensitiveASCII):
            return Self.fixedNegativeLookbehindMatches(
                prefix: prefix,
                literal: literal,
                caseInsensitiveASCII: caseInsensitiveASCII,
                in: text
            )
        case .fixedNegativeLookahead(let literal, let suffix, let caseInsensitiveASCII):
            return Self.fixedNegativeLookaheadMatches(
                literal: literal,
                suffix: suffix,
                caseInsensitiveASCII: caseInsensitiveASCII,
                in: text
            )
        case .fixedLiteralBackreference(let literal, let captureRanges, let caseInsensitiveASCII):
            return Self.fixedLiteralBackreferenceMatches(
                literal: literal,
                captureRanges: captureRanges,
                caseInsensitiveASCII: caseInsensitiveASCII,
                in: text
            )
        }
    }

    static func fixedPositiveLookaroundLiteral(_ pattern: String) -> String? {
        if let lookbehind = fixedPositiveLookbehind(pattern) {
            return lookbehind.literal
        }
        if let lookahead = fixedPositiveLookahead(pattern) {
            return lookahead.literal
        }
        if let lookbehind = fixedNegativeLookbehind(pattern) {
            return lookbehind.literal
        }
        if let lookahead = fixedNegativeLookahead(pattern) {
            return lookahead.literal
        }
        return nil
    }

    private static func fixedPositiveLookbehind(_ pattern: String) -> (prefix: String, literal: String)? {
        let marker = "(?<="
        guard pattern.hasPrefix(marker),
              let close = pattern.dropFirst(marker.count).firstIndex(of: ")") else {
            return nil
        }
        let prefixStart = pattern.index(pattern.startIndex, offsetBy: marker.count)
        let prefix = String(pattern[prefixStart..<close])
        let literalStart = pattern.index(after: close)
        let literal = String(pattern[literalStart...])
        guard !prefix.isEmpty,
              !literal.isEmpty,
              !prefix.contains("\n"),
              !prefix.contains("\r"),
              !literal.contains("\n"),
              !literal.contains("\r"),
              prefix.utf8.allSatisfy({ $0 < 0x80 }),
              literal.utf8.allSatisfy({ $0 < 0x80 }),
              isPlainPCRELiteral(prefix),
              isPlainPCRELiteral(literal) else {
            return nil
        }
        return (prefix, literal)
    }

    private static func fixedPositiveLookahead(_ pattern: String) -> (literal: String, suffix: String)? {
        let marker = "(?="
        guard pattern.hasSuffix(")"),
              let markerRange = pattern.range(of: marker) else {
            return nil
        }
        let literal = String(pattern[..<markerRange.lowerBound])
        let suffixEnd = pattern.index(before: pattern.endIndex)
        let suffix = String(pattern[markerRange.upperBound..<suffixEnd])
        guard !literal.isEmpty,
              !suffix.isEmpty,
              !literal.contains("\n"),
              !literal.contains("\r"),
              !suffix.contains("\n"),
              !suffix.contains("\r"),
              literal.utf8.allSatisfy({ $0 < 0x80 }),
              suffix.utf8.allSatisfy({ $0 < 0x80 }),
              isPlainPCRELiteral(literal),
              isPlainPCRELiteral(suffix) else {
            return nil
        }
        return (literal, suffix)
    }

    private static func fixedNegativeLookbehind(_ pattern: String) -> (prefix: String, literal: String)? {
        let marker = "(?<!"
        guard pattern.hasPrefix(marker),
              let close = pattern.dropFirst(marker.count).firstIndex(of: ")") else {
            return nil
        }
        let prefixStart = pattern.index(pattern.startIndex, offsetBy: marker.count)
        let prefix = String(pattern[prefixStart..<close])
        let literalStart = pattern.index(after: close)
        let literal = String(pattern[literalStart...])
        guard !prefix.isEmpty,
              !literal.isEmpty,
              !prefix.contains("\n"),
              !prefix.contains("\r"),
              !literal.contains("\n"),
              !literal.contains("\r"),
              prefix.utf8.allSatisfy({ $0 < 0x80 }),
              literal.utf8.allSatisfy({ $0 < 0x80 }),
              isPlainPCRELiteral(prefix),
              isPlainPCRELiteral(literal) else {
            return nil
        }
        return (prefix, literal)
    }

    private static func fixedNegativeLookahead(_ pattern: String) -> (literal: String, suffix: String)? {
        let marker = "(?!"
        guard pattern.hasSuffix(")"),
              let markerRange = pattern.range(of: marker) else {
            return nil
        }
        let literal = String(pattern[..<markerRange.lowerBound])
        let suffixEnd = pattern.index(before: pattern.endIndex)
        let suffix = String(pattern[markerRange.upperBound..<suffixEnd])
        guard !literal.isEmpty,
              !suffix.isEmpty,
              !literal.contains("\n"),
              !literal.contains("\r"),
              !suffix.contains("\n"),
              !suffix.contains("\r"),
              literal.utf8.allSatisfy({ $0 < 0x80 }),
              suffix.utf8.allSatisfy({ $0 < 0x80 }),
              isPlainPCRELiteral(literal),
              isPlainPCRELiteral(suffix) else {
            return nil
        }
        return (literal, suffix)
    }

    private static func isPlainPCRELiteral(_ text: String) -> Bool {
        !text.contains { character in
            #"\\.[]{}()+*?^$|"#.contains(character)
        }
    }

    private static func fixedLiteralBackreference(_ pattern: String) -> (literal: String, captureRanges: [Range<Int>])? {
        var groups: [String] = []
        var captureRanges: [Range<Int>] = []
        var literal = ""
        var byteOffset = 0
        var index = pattern.startIndex

        while index < pattern.endIndex, pattern[index] == "(" {
            let groupStart = pattern.index(after: index)
            guard let close = pattern[groupStart...].firstIndex(of: ")") else {
                return nil
            }
            let group = String(pattern[groupStart..<close])
            guard !group.isEmpty,
                  !group.contains("\n"),
                  !group.contains("\r"),
                  group.utf8.allSatisfy({ $0 < 0x80 }),
                  isPlainPCRELiteral(group) else {
                return nil
            }
            let groupByteCount = group.utf8.count
            groups.append(group)
            captureRanges.append(byteOffset..<byteOffset + groupByteCount)
            literal += group
            byteOffset += groupByteCount
            index = pattern.index(after: close)
        }

        guard !groups.isEmpty,
              index < pattern.endIndex,
              pattern[index] == "\\" else {
            return nil
        }
        let referenceIndex = pattern.index(after: index)
        guard referenceIndex < pattern.endIndex,
              let reference = pattern[referenceIndex].wholeNumberValue,
              reference > 0,
              reference <= groups.count,
              pattern.index(after: referenceIndex) == pattern.endIndex else {
            return nil
        }
        literal += groups[reference - 1]
        return (literal, captureRanges)
    }

    private static func fixedPositiveLookbehindMatches(
        prefix: [UInt8],
        literal: [UInt8],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
        #if canImport(CRipgrepPlatform)
        var matches: [PCRE2Match] = []
        let originalText = text
        var utf8Text = text
        utf8Text.withUTF8 { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            prefix.withUnsafeBufferPointer { prefixBytes in
                literal.withUnsafeBufferPointer { literalBytes in
                    guard let prefixBase = prefixBytes.baseAddress,
                          let literalBase = literalBytes.baseAddress else {
                        return
                    }
                    var searchOffset = 0
                    while searchOffset <= bytes.count - literalBytes.count,
                          let found = findLiteral(
                            baseAddress.advanced(by: searchOffset),
                            bytes.count - searchOffset,
                            literalBase,
                            literalBytes.count,
                            caseInsensitiveASCII: caseInsensitiveASCII
                          ) {
                        let matchOffset = baseAddress.distance(to: found)
                        if matchOffset >= prefixBytes.count,
                           bytesEqual(
                            baseAddress.advanced(by: matchOffset - prefixBytes.count),
                            prefixBase,
                            prefixBytes.count,
                            caseInsensitiveASCII: caseInsensitiveASCII
                           ),
                           let range = stringRange(
                            startByte: matchOffset,
                            endByte: matchOffset + literalBytes.count,
                            in: originalText
                           ) {
                            matches.append(PCRE2Match(
                                range: range,
                                byteRange: matchOffset..<matchOffset + literalBytes.count,
                                captures: [range]
                            ))
                        }
                        searchOffset = matchOffset + max(literalBytes.count, 1)
                    }
                }
            }
        }
        return matches
        #else
        return []
        #endif
    }

    private static func fixedNegativeLookbehindMatches(
        prefix: [UInt8],
        literal: [UInt8],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
        #if canImport(CRipgrepPlatform)
        var matches: [PCRE2Match] = []
        let originalText = text
        var utf8Text = text
        utf8Text.withUTF8 { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            prefix.withUnsafeBufferPointer { prefixBytes in
                literal.withUnsafeBufferPointer { literalBytes in
                    guard let prefixBase = prefixBytes.baseAddress,
                          let literalBase = literalBytes.baseAddress else {
                        return
                    }
                    var searchOffset = 0
                    while searchOffset <= bytes.count - literalBytes.count,
                          let found = findLiteral(
                            baseAddress.advanced(by: searchOffset),
                            bytes.count - searchOffset,
                            literalBase,
                            literalBytes.count,
                            caseInsensitiveASCII: caseInsensitiveASCII
                          ) {
                        let matchOffset = baseAddress.distance(to: found)
                        let hasPrefix = matchOffset >= prefixBytes.count
                            && bytesEqual(
                                baseAddress.advanced(by: matchOffset - prefixBytes.count),
                                prefixBase,
                                prefixBytes.count,
                                caseInsensitiveASCII: caseInsensitiveASCII
                            )
                        if !hasPrefix,
                           let range = stringRange(
                            startByte: matchOffset,
                            endByte: matchOffset + literalBytes.count,
                            in: originalText
                           ) {
                            matches.append(PCRE2Match(
                                range: range,
                                byteRange: matchOffset..<matchOffset + literalBytes.count,
                                captures: [range]
                            ))
                        }
                        searchOffset = matchOffset + max(literalBytes.count, 1)
                    }
                }
            }
        }
        return matches
        #else
        return []
        #endif
    }

    private static func fixedPositiveLookaheadMatches(
        literal: [UInt8],
        suffix: [UInt8],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
        #if canImport(CRipgrepPlatform)
        var matches: [PCRE2Match] = []
        let originalText = text
        var utf8Text = text
        utf8Text.withUTF8 { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            literal.withUnsafeBufferPointer { literalBytes in
                suffix.withUnsafeBufferPointer { suffixBytes in
                    guard let literalBase = literalBytes.baseAddress,
                          let suffixBase = suffixBytes.baseAddress else {
                        return
                    }
                    var searchOffset = 0
                    while searchOffset <= bytes.count - literalBytes.count,
                          let found = findLiteral(
                            baseAddress.advanced(by: searchOffset),
                            bytes.count - searchOffset,
                            literalBase,
                            literalBytes.count,
                            caseInsensitiveASCII: caseInsensitiveASCII
                          ) {
                        let matchOffset = baseAddress.distance(to: found)
                        let suffixOffset = matchOffset + literalBytes.count
                        if suffixOffset + suffixBytes.count <= bytes.count,
                           bytesEqual(
                            baseAddress.advanced(by: suffixOffset),
                            suffixBase,
                            suffixBytes.count,
                            caseInsensitiveASCII: caseInsensitiveASCII
                           ),
                           let range = stringRange(
                            startByte: matchOffset,
                            endByte: suffixOffset,
                            in: originalText
                           ) {
                            matches.append(PCRE2Match(
                                range: range,
                                byteRange: matchOffset..<suffixOffset,
                                captures: [range]
                            ))
                        }
                        searchOffset = matchOffset + max(literalBytes.count, 1)
                    }
                }
            }
        }
        return matches
        #else
        return []
        #endif
    }

    private static func fixedNegativeLookaheadMatches(
        literal: [UInt8],
        suffix: [UInt8],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
        #if canImport(CRipgrepPlatform)
        var matches: [PCRE2Match] = []
        let originalText = text
        var utf8Text = text
        utf8Text.withUTF8 { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            literal.withUnsafeBufferPointer { literalBytes in
                suffix.withUnsafeBufferPointer { suffixBytes in
                    guard let literalBase = literalBytes.baseAddress,
                          let suffixBase = suffixBytes.baseAddress else {
                        return
                    }
                    var searchOffset = 0
                    while searchOffset <= bytes.count - literalBytes.count,
                          let found = findLiteral(
                            baseAddress.advanced(by: searchOffset),
                            bytes.count - searchOffset,
                            literalBase,
                            literalBytes.count,
                            caseInsensitiveASCII: caseInsensitiveASCII
                          ) {
                        let matchOffset = baseAddress.distance(to: found)
                        let suffixOffset = matchOffset + literalBytes.count
                        let hasSuffix = suffixOffset + suffixBytes.count <= bytes.count
                            && bytesEqual(
                                baseAddress.advanced(by: suffixOffset),
                                suffixBase,
                                suffixBytes.count,
                                caseInsensitiveASCII: caseInsensitiveASCII
                            )
                        if !hasSuffix,
                           let range = stringRange(
                            startByte: matchOffset,
                            endByte: suffixOffset,
                            in: originalText
                           ) {
                            matches.append(PCRE2Match(
                                range: range,
                                byteRange: matchOffset..<suffixOffset,
                                captures: [range]
                            ))
                        }
                        searchOffset = matchOffset + max(literalBytes.count, 1)
                    }
                }
            }
        }
        return matches
        #else
        return []
        #endif
    }

    private static func fixedLiteralBackreferenceMatches(
        literal: [UInt8],
        captureRanges: [Range<Int>],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
        #if canImport(CRipgrepPlatform)
        var matches: [PCRE2Match] = []
        let originalText = text
        var utf8Text = text
        utf8Text.withUTF8 { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            literal.withUnsafeBufferPointer { literalBytes in
                guard let literalBase = literalBytes.baseAddress, !literalBytes.isEmpty else {
                    return
                }
                var searchOffset = 0
                while searchOffset <= bytes.count - literalBytes.count,
                      let found = findLiteral(
                        baseAddress.advanced(by: searchOffset),
                        bytes.count - searchOffset,
                        literalBase,
                        literalBytes.count,
                        caseInsensitiveASCII: caseInsensitiveASCII
                      ) {
                    let matchOffset = baseAddress.distance(to: found)
                    let matchEnd = matchOffset + literalBytes.count
                    if let range = stringRange(startByte: matchOffset, endByte: matchEnd, in: originalText) {
                        var captures: [Range<String.Index>?] = [range]
                        captures.reserveCapacity(captureRanges.count + 1)
                        for captureRange in captureRanges {
                            captures.append(stringRange(
                                startByte: matchOffset + captureRange.lowerBound,
                                endByte: matchOffset + captureRange.upperBound,
                                in: originalText
                            ))
                        }
                        matches.append(PCRE2Match(
                            range: range,
                            byteRange: matchOffset..<matchEnd,
                            captures: captures
                        ))
                    }
                    searchOffset = matchOffset + literalBytes.count
                }
            }
        }
        return matches
        #else
        return []
        #endif
    }

    #if canImport(CRipgrepPlatform)
    private static func findLiteral(
        _ haystack: UnsafePointer<UInt8>,
        _ haystackLength: Int,
        _ literal: UnsafePointer<UInt8>,
        _ literalLength: Int,
        caseInsensitiveASCII: Bool
    ) -> UnsafePointer<UInt8>? {
        if caseInsensitiveASCII {
            return rg_memcasemem_ascii(haystack, haystackLength, literal, literalLength)
        }
        return rg_memmem_simple(haystack, haystackLength, literal, literalLength)
    }

    private static func bytesEqual(
        _ lhs: UnsafePointer<UInt8>,
        _ rhs: UnsafePointer<UInt8>,
        _ count: Int,
        caseInsensitiveASCII: Bool
    ) -> Bool {
        guard caseInsensitiveASCII else {
            return memcmp(lhs, rhs, count) == 0
        }
        for offset in 0..<count {
            guard asciiLowercase(lhs[offset]) == asciiLowercase(rhs[offset]) else {
                return false
            }
        }
        return true
    }

    private static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }
    #endif

    private static func stringRange(startByte: Int, endByte: Int, in text: String) -> Range<String.Index>? {
        let lowerUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: startByte)
        let upperUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: endByte)
        guard let lower = lowerUTF8.samePosition(in: text),
              let upper = upperUTF8.samePosition(in: text) else {
            return nil
        }
        return lower..<upper
    }

    private static func match(from match: NSTextCheckingResult, in text: String) -> PCRE2Match? {
        var captures: [Range<String.Index>?] = []
        captures.reserveCapacity(match.numberOfRanges)

        for index in 0..<match.numberOfRanges {
            let nsRange = match.range(at: index)
            guard nsRange.location != NSNotFound else {
                captures.append(nil)
                continue
            }
            guard let range = Range(nsRange, in: text) else {
                return nil
            }
            captures.append(range)
        }

        guard let range = captures.first ?? nil else {
            return nil
        }
        return PCRE2Match(
            range: range,
            byteRange: byteRange(for: range, in: text),
            captures: captures
        )
    }

    private static func byteRange(for range: Range<String.Index>, in text: String) -> Range<Int> {
        text[..<range.lowerBound].utf8.count..<text[..<range.upperBound].utf8.count
    }

    private static func compileErrorMessage(pattern: String, error: Error) -> String {
        """
        PCRE2-compatible regex error: \(error.localizedDescription)
        \(pattern)
        """
    }
}

struct PCRE2Match {
    let range: Range<String.Index>
    let byteRange: Range<Int>
    let captures: [Range<String.Index>?]
}
