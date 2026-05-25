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
        case fixedPositiveLookbehind(prefix: [UInt8], literal: [UInt8])
    }

    let source: String
    private let matcher: Matcher

    var fixedPositiveLookbehindFastPath: (prefix: [UInt8], literal: [UInt8])? {
        guard case .fixedPositiveLookbehind(let prefix, let literal) = matcher else {
            return nil
        }
        return (prefix, literal)
    }

    init(pattern: String, options: RipgrepOptions) throws {
        self.source = pattern
        #if canImport(CRipgrepPlatform)
        if !options.effectiveIgnoreCase,
           let lookbehind = Self.fixedPositiveLookbehind(pattern) {
            self.matcher = .fixedPositiveLookbehind(
                prefix: Array(lookbehind.prefix.utf8),
                literal: Array(lookbehind.literal.utf8)
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
        case .fixedPositiveLookbehind(let prefix, let literal):
            return Self.fixedPositiveLookbehindMatches(prefix: prefix, literal: literal, in: text)
        }
    }

    static func fixedPositiveLookbehindLiteral(_ pattern: String) -> String? {
        fixedPositiveLookbehind(pattern)?.literal
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

    private static func isPlainPCRELiteral(_ text: String) -> Bool {
        !text.contains { character in
            #"\\.[]{}()+*?^$|"#.contains(character)
        }
    }

    private static func fixedPositiveLookbehindMatches(
        prefix: [UInt8],
        literal: [UInt8],
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
                          let found = rg_memmem_simple(
                            baseAddress.advanced(by: searchOffset),
                            bytes.count - searchOffset,
                            literalBase,
                            literalBytes.count
                          ) {
                        let matchOffset = baseAddress.distance(to: found)
                        if matchOffset >= prefixBytes.count,
                           memcmp(
                            baseAddress.advanced(by: matchOffset - prefixBytes.count),
                            prefixBase,
                            prefixBytes.count
                           ) == 0,
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
