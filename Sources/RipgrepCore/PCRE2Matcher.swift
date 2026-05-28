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
    struct BranchResetAlternative {
        let regex: NSRegularExpression
        let captureCount: Int
        let namedCaptureNames: [String]
    }

    enum FixedAssertionCondition {
        case positiveLookahead([UInt8])
        case negativeLookahead([UInt8])
        case positiveLookbehind([UInt8])
        case negativeLookbehind([UInt8])
    }

    enum ByteUnitPattern {
        case single
        case oneOrMore
        case fixed(Int)
    }

    private enum Matcher {
        case regex(NSRegularExpression, namedCaptureNames: [String])
        case byteUnit(ByteUnitPattern, unicodeStartOnly: Bool)
        case bareResetStart
        case fixedPositiveLookbehind(prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)
        case fixedNegativeLookbehind(prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)
        case fixedPositiveLookahead(literal: [UInt8], suffix: [UInt8], caseInsensitiveASCII: Bool)
        case fixedNegativeLookahead(literal: [UInt8], suffix: [UInt8], caseInsensitiveASCII: Bool)
        case fixedResetStart(prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)
        case literalPrefixResetStartRegex(
            prefixUTF16Length: Int,
            regex: NSRegularExpression,
            namedCaptureNames: [String]
        )
        case capturedPrefixResetStartRegex(NSRegularExpression, namedCaptureNames: [String])
        case byteUnitRegex(NSRegularExpression, unicodeStartOnly: Bool, namedCaptureNames: [String])
        case branchResetAlternation(
            alternatives: [BranchResetAlternative],
            maxCaptureCount: Int
        )
        case skipFailAlternation(
            skipRegex: NSRegularExpression,
            matchRegex: NSRegularExpression,
            skipCaptureCount: Int,
            matchNamedCaptureNames: [String]
        )
        case fixedLiteralBackreference(literal: [UInt8], captureRanges: [Range<Int>], caseInsensitiveASCII: Bool)
        case fixedNamedLiteralBackreference(
            literal: [UInt8],
            captureRanges: [Range<Int>],
            namedCaptureRanges: [String: Range<Int>],
            caseInsensitiveASCII: Bool
        )
        case fixedAssertionConditional(
            condition: FixedAssertionCondition,
            trueLiteral: [UInt8],
            falseLiteral: [UInt8],
            caseInsensitiveASCII: Bool
        )
        case balancedParenthesesRecursion(name: String)
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

    var fixedResetStartFastPath: (prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)? {
        guard case .fixedResetStart(let prefix, let literal, let caseInsensitiveASCII) = matcher else {
            return nil
        }
        return (prefix, literal, caseInsensitiveASCII)
    }

    var fixedLiteralBackreferenceFastPath: (literal: [UInt8], caseInsensitiveASCII: Bool)? {
        switch matcher {
        case .fixedLiteralBackreference(let literal, _, let caseInsensitiveASCII),
             .fixedNamedLiteralBackreference(let literal, _, _, let caseInsensitiveASCII):
            return (literal, caseInsensitiveASCII)
        default:
            return nil
        }
    }

    var fixedAssertionConditionalFastPath:
        (condition: FixedAssertionCondition, trueLiteral: [UInt8], falseLiteral: [UInt8], caseInsensitiveASCII: Bool)? {
        guard case .fixedAssertionConditional(
            let condition,
            let trueLiteral,
            let falseLiteral,
            let caseInsensitiveASCII
        ) = matcher else {
            return nil
        }
        return (condition, trueLiteral, falseLiteral, caseInsensitiveASCII)
    }

    var byteUnitFastPath: (pattern: ByteUnitPattern, unicodeStartOnly: Bool)? {
        guard case .byteUnit(let pattern, let unicodeStartOnly) = matcher else {
            return nil
        }
        return (pattern, unicodeStartOnly)
    }

    var bareResetStartFastPath: Bool {
        guard case .bareResetStart = matcher else {
            return false
        }
        return true
    }

    init(pattern: String, options: RipgrepOptions) throws {
        self.source = pattern
        if let byteUnit = Self.byteUnitPattern(pattern) {
            self.matcher = .byteUnit(byteUnit, unicodeStartOnly: !options.noUnicode)
            return
        }
        if pattern == #"\K"# {
            self.matcher = .bareResetStart
            return
        }
        if let recursionName = Self.balancedParenthesesRecursion(pattern) {
            self.matcher = .balancedParenthesesRecursion(name: recursionName)
            return
        }

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
           let resetStart = Self.fixedLiteralResetStart(pattern) {
            self.matcher = .fixedResetStart(
                prefix: Array(resetStart.prefix.utf8),
                literal: Array(resetStart.literal.utf8),
                caseInsensitiveASCII: caseInsensitiveASCII
            )
            return
        }
        if canUseFixedByteMatcher,
           let backreference = Self.fixedLiteralBackreference(pattern) {
            if backreference.namedCaptureRanges.isEmpty {
                self.matcher = .fixedLiteralBackreference(
                    literal: Array(backreference.literal.utf8),
                    captureRanges: backreference.captureRanges,
                    caseInsensitiveASCII: caseInsensitiveASCII
                )
            } else {
                self.matcher = .fixedNamedLiteralBackreference(
                    literal: Array(backreference.literal.utf8),
                    captureRanges: backreference.captureRanges,
                    namedCaptureRanges: backreference.namedCaptureRanges,
                    caseInsensitiveASCII: caseInsensitiveASCII
                )
            }
            return
        }
        if canUseFixedByteMatcher,
           let conditional = Self.fixedAssertionConditional(pattern) {
            self.matcher = .fixedAssertionConditional(
                condition: conditional.condition,
                trueLiteral: Array(conditional.trueLiteral.utf8),
                falseLiteral: Array(conditional.falseLiteral.utf8),
                caseInsensitiveASCII: caseInsensitiveASCII
            )
            return
        }

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

        if let resetStartRegex = try Self.literalPrefixResetStartRegex(
            pattern,
            options: options,
            regexOptions: regexOptions
        ) {
            self.matcher = .literalPrefixResetStartRegex(
                prefixUTF16Length: resetStartRegex.prefixUTF16Length,
                regex: resetStartRegex.regex,
                namedCaptureNames: Self.namedCaptureNames(in: pattern)
            )
            return
        }
        if let resetStartRegex = try Self.capturedPrefixResetStartRegex(
            pattern,
            options: options,
            regexOptions: regexOptions
        ) {
            self.matcher = .capturedPrefixResetStartRegex(
                resetStartRegex,
                namedCaptureNames: Self.namedCaptureNames(in: pattern)
            )
            return
        }
        if let skipFailAlternation = try Self.skipFailAlternation(
            pattern,
            options: options,
            regexOptions: regexOptions
        ) {
            self.matcher = .skipFailAlternation(
                skipRegex: skipFailAlternation.skipRegex,
                matchRegex: skipFailAlternation.matchRegex,
                skipCaptureCount: skipFailAlternation.skipCaptureCount,
                matchNamedCaptureNames: skipFailAlternation.matchNamedCaptureNames
            )
            return
        }
        if let branchResetAlternation = try Self.branchResetAlternation(
            pattern,
            options: options,
            regexOptions: regexOptions
        ) {
            self.matcher = .branchResetAlternation(
                alternatives: branchResetAlternation.alternatives,
                maxCaptureCount: branchResetAlternation.maxCaptureCount
            )
            return
        }

        var regexPattern = try Self.regexPatternExpandingPCREQuotedLiterals(
            pattern,
            asciiShorthandEscapes: options.noUnicode
        )
        if regexPattern.isEmpty {
            regexPattern = "(?:)"
        }
        do {
            let regex = try NSRegularExpression(pattern: regexPattern, options: regexOptions)
            let namedCaptureNames = Self.namedCaptureNames(in: pattern)
            if Self.containsByteUnitEscape(pattern) {
                self.matcher = .byteUnitRegex(
                    regex,
                    unicodeStartOnly: !options.noUnicode,
                    namedCaptureNames: namedCaptureNames
                )
            } else {
                self.matcher = .regex(regex, namedCaptureNames: namedCaptureNames)
            }
        } catch {
            throw RipgrepError.message(Self.compileErrorMessage(pattern: pattern, error: error))
        }
    }

    func matches(in text: String) -> [PCRE2Match] {
        switch matcher {
        case .regex(let regex, let namedCaptureNames):
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Self.match(from: match, namedCaptureNames: namedCaptureNames, in: text)
            }
        case .byteUnit(let pattern, let unicodeStartOnly):
            return Self.byteUnitMatches(pattern: pattern, unicodeStartOnly: unicodeStartOnly, in: text)
        case .bareResetStart:
            return Self.bareResetStartMatches(in: text)
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
        case .fixedResetStart(let prefix, let literal, let caseInsensitiveASCII):
            return Self.fixedResetStartMatches(
                prefix: prefix,
                literal: literal,
                caseInsensitiveASCII: caseInsensitiveASCII,
                in: text
            )
        case .literalPrefixResetStartRegex(let prefixUTF16Length, let regex, let namedCaptureNames):
            return Self.literalPrefixResetStartRegexMatches(
                prefixUTF16Length: prefixUTF16Length,
                regex: regex,
                namedCaptureNames: namedCaptureNames,
                in: text
            )
        case .capturedPrefixResetStartRegex(let regex, let namedCaptureNames):
            return Self.capturedPrefixResetStartRegexMatches(
                regex: regex,
                namedCaptureNames: namedCaptureNames,
                in: text
            )
        case .byteUnitRegex(let regex, let unicodeStartOnly, let namedCaptureNames):
            return Self.byteUnitRegexMatches(
                regex: regex,
                unicodeStartOnly: unicodeStartOnly,
                namedCaptureNames: namedCaptureNames,
                in: text
            )
        case .branchResetAlternation(let alternatives, let maxCaptureCount):
            return Self.branchResetAlternationMatches(
                alternatives: alternatives,
                maxCaptureCount: maxCaptureCount,
                in: text
            )
        case .skipFailAlternation(let skipRegex, let matchRegex, let skipCaptureCount, let matchNamedCaptureNames):
            return Self.skipFailAlternationMatches(
                skipRegex: skipRegex,
                matchRegex: matchRegex,
                skipCaptureCount: skipCaptureCount,
                matchNamedCaptureNames: matchNamedCaptureNames,
                in: text
            )
        case .fixedLiteralBackreference(let literal, let captureRanges, let caseInsensitiveASCII):
            return Self.fixedLiteralBackreferenceMatches(
                literal: literal,
                captureRanges: captureRanges,
                namedCaptureRanges: [:],
                caseInsensitiveASCII: caseInsensitiveASCII,
                in: text
            )
        case .fixedNamedLiteralBackreference(
            let literal,
            let captureRanges,
            let namedCaptureRanges,
            let caseInsensitiveASCII
        ):
            return Self.fixedLiteralBackreferenceMatches(
                literal: literal,
                captureRanges: captureRanges,
                namedCaptureRanges: namedCaptureRanges,
                caseInsensitiveASCII: caseInsensitiveASCII,
                in: text
            )
        case .fixedAssertionConditional(let condition, let trueLiteral, let falseLiteral, let caseInsensitiveASCII):
            return Self.fixedAssertionConditionalMatches(
                condition: condition,
                trueLiteral: trueLiteral,
                falseLiteral: falseLiteral,
                caseInsensitiveASCII: caseInsensitiveASCII,
                in: text
            )
        case .balancedParenthesesRecursion(let name):
            return Self.balancedParenthesesRecursionMatches(name: name, in: text)
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
              let close = firstUnescapedClosingParen(in: pattern.dropFirst(marker.count)) else {
            return nil
        }
        let prefixStart = pattern.index(pattern.startIndex, offsetBy: marker.count)
        let rawPrefix = String(pattern[prefixStart..<close])
        let literalStart = pattern.index(after: close)
        let rawLiteral = String(pattern[literalStart...])
        guard let prefix = RegexLiteralParser.literal(
            fromPlainRegexPattern: rawPrefix,
            allowPCREQuotedLiterals: true
        ),
              let literal = RegexLiteralParser.literal(
                fromPlainRegexPattern: rawLiteral,
                allowPCREQuotedLiterals: true
              ) else {
            return nil
        }
        guard !prefix.isEmpty,
              !literal.isEmpty,
              !prefix.contains("\n"),
              !prefix.contains("\r"),
              !literal.contains("\n"),
              !literal.contains("\r"),
              prefix.utf8.allSatisfy({ $0 < 0x80 }),
              literal.utf8.allSatisfy({ $0 < 0x80 }) else {
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
        let rawLiteral = String(pattern[..<markerRange.lowerBound])
        let suffixEnd = pattern.index(before: pattern.endIndex)
        let rawSuffix = String(pattern[markerRange.upperBound..<suffixEnd])
        guard let literal = RegexLiteralParser.literal(
            fromPlainRegexPattern: rawLiteral,
            allowPCREQuotedLiterals: true
        ),
              let suffix = RegexLiteralParser.literal(
                fromPlainRegexPattern: rawSuffix,
                allowPCREQuotedLiterals: true
              ) else {
            return nil
        }
        guard !literal.isEmpty,
              !suffix.isEmpty,
              !literal.contains("\n"),
              !literal.contains("\r"),
              !suffix.contains("\n"),
              !suffix.contains("\r"),
              literal.utf8.allSatisfy({ $0 < 0x80 }),
              suffix.utf8.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        return (literal, suffix)
    }

    private static func fixedNegativeLookbehind(_ pattern: String) -> (prefix: String, literal: String)? {
        let marker = "(?<!"
        guard pattern.hasPrefix(marker),
              let close = firstUnescapedClosingParen(in: pattern.dropFirst(marker.count)) else {
            return nil
        }
        let prefixStart = pattern.index(pattern.startIndex, offsetBy: marker.count)
        let rawPrefix = String(pattern[prefixStart..<close])
        let literalStart = pattern.index(after: close)
        let rawLiteral = String(pattern[literalStart...])
        guard let prefix = RegexLiteralParser.literal(
            fromPlainRegexPattern: rawPrefix,
            allowPCREQuotedLiterals: true
        ),
              let literal = RegexLiteralParser.literal(
                fromPlainRegexPattern: rawLiteral,
                allowPCREQuotedLiterals: true
              ) else {
            return nil
        }
        guard !prefix.isEmpty,
              !literal.isEmpty,
              !prefix.contains("\n"),
              !prefix.contains("\r"),
              !literal.contains("\n"),
              !literal.contains("\r"),
              prefix.utf8.allSatisfy({ $0 < 0x80 }),
              literal.utf8.allSatisfy({ $0 < 0x80 }) else {
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
        let rawLiteral = String(pattern[..<markerRange.lowerBound])
        let suffixEnd = pattern.index(before: pattern.endIndex)
        let rawSuffix = String(pattern[markerRange.upperBound..<suffixEnd])
        guard let literal = RegexLiteralParser.literal(
            fromPlainRegexPattern: rawLiteral,
            allowPCREQuotedLiterals: true
        ),
              let suffix = RegexLiteralParser.literal(
                fromPlainRegexPattern: rawSuffix,
                allowPCREQuotedLiterals: true
              ) else {
            return nil
        }
        guard !literal.isEmpty,
              !suffix.isEmpty,
              !literal.contains("\n"),
              !literal.contains("\r"),
              !suffix.contains("\n"),
              !suffix.contains("\r"),
              literal.utf8.allSatisfy({ $0 < 0x80 }),
              suffix.utf8.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        return (literal, suffix)
    }

    private static func fixedLiteralResetStart(_ pattern: String) -> (prefix: String, literal: String)? {
        guard let resetRange = RegexLiteralParser.firstUnescapedResetStart(in: pattern) else {
            return nil
        }
        let rawPrefix = String(pattern[..<resetRange.lowerBound])
        let rawLiteral = String(pattern[resetRange.upperBound...])
        guard let prefix = plainLiteralOrEmpty(rawPrefix),
              let literal = plainLiteralOrEmpty(rawLiteral) else {
            return nil
        }
        guard (!prefix.isEmpty || !literal.isEmpty),
              !prefix.contains("\n"),
              !prefix.contains("\r"),
              !literal.contains("\n"),
              !literal.contains("\r"),
              prefix.utf8.allSatisfy({ $0 < 0x80 }),
              literal.utf8.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        return (prefix, literal)
    }

    private static func plainLiteralOrEmpty(_ pattern: String) -> String? {
        pattern.isEmpty
            ? ""
            : RegexLiteralParser.literal(fromPlainRegexPattern: pattern, allowPCREQuotedLiterals: true)
    }

    private static func literalPrefixResetStartRegex(
        _ pattern: String,
        options: RipgrepOptions,
        regexOptions: NSRegularExpression.Options
    ) throws -> (prefixUTF16Length: Int, regex: NSRegularExpression)? {
        guard let resetRange = RegexLiteralParser.firstUnescapedResetStart(in: pattern) else {
            return nil
        }
        let rawPrefix = String(pattern[..<resetRange.lowerBound])
        let rawSuffix = String(pattern[resetRange.upperBound...])
        guard !rawPrefix.isEmpty,
              !rawSuffix.isEmpty,
              RegexLiteralParser.firstUnescapedResetStart(in: rawSuffix) == nil,
              let prefix = RegexLiteralParser.literal(
                fromPlainRegexPattern: rawPrefix,
                allowPCREQuotedLiterals: true
              ) else {
            return nil
        }

        let suffixPattern = try regexPatternExpandingPCREQuotedLiterals(
            rawSuffix,
            asciiShorthandEscapes: options.noUnicode
        )
        let expandedPattern = NSRegularExpression.escapedPattern(for: prefix) + suffixPattern
        do {
            return (
                prefix.utf16.count,
                try NSRegularExpression(pattern: expandedPattern, options: regexOptions)
            )
        } catch {
            throw RipgrepError.message(Self.compileErrorMessage(pattern: pattern, error: error))
        }
    }

    private static func capturedPrefixResetStartRegex(
        _ pattern: String,
        options: RipgrepOptions,
        regexOptions: NSRegularExpression.Options
    ) throws -> NSRegularExpression? {
        guard let resetRange = RegexLiteralParser.firstUnescapedResetStart(in: pattern) else {
            return nil
        }
        let rawPrefix = String(pattern[..<resetRange.lowerBound])
        let rawSuffix = String(pattern[resetRange.upperBound...])
        guard !rawPrefix.isEmpty || !rawSuffix.isEmpty,
              RegexLiteralParser.firstUnescapedResetStart(in: rawSuffix) == nil else {
            return nil
        }

        let rawPrefixCaptureCount = captureGroupCount(in: rawPrefix)
        let rawTotalCaptureCount = rawPrefixCaptureCount + captureGroupCount(in: rawSuffix)
        let prefixPattern = rawPrefix.isEmpty
            ? ""
            : try regexPatternExpandingPCREQuotedLiterals(
                rawPrefix,
                asciiShorthandEscapes: options.noUnicode,
                numericCaptureOffset: 1,
                totalCaptureCountOverride: rawTotalCaptureCount
            )
        let suffixPattern = rawSuffix.isEmpty
            ? ""
            : try regexPatternExpandingPCREQuotedLiterals(
                rawSuffix,
                asciiShorthandEscapes: options.noUnicode,
                numericCaptureOffset: 1,
                captureCountBase: rawPrefixCaptureCount,
                totalCaptureCountOverride: rawTotalCaptureCount
            )
        do {
            return try NSRegularExpression(
                pattern: "(\(prefixPattern))\(suffixPattern)",
                options: regexOptions
            )
        } catch {
            throw RipgrepError.message(Self.compileErrorMessage(pattern: pattern, error: error))
        }
    }

    private static func skipFailAlternation(
        _ pattern: String,
        options: RipgrepOptions,
        regexOptions: NSRegularExpression.Options
    ) throws -> (
        skipRegex: NSRegularExpression,
        matchRegex: NSRegularExpression,
        skipCaptureCount: Int,
        matchNamedCaptureNames: [String]
    )? {
        guard let split = skipFailAlternationSplit(in: pattern) else {
            return nil
        }
        let rawSkip = String(pattern[..<split.marker.lowerBound])
        let rawMatch = String(pattern[split.matchStart...])
        guard !rawSkip.isEmpty, !rawMatch.isEmpty else {
            return nil
        }

        let skipPattern = try regexPatternExpandingPCREQuotedLiterals(
            rawSkip,
            asciiShorthandEscapes: options.noUnicode
        )
        let matchPattern = try regexPatternExpandingPCREQuotedLiterals(
            rawMatch,
            asciiShorthandEscapes: options.noUnicode
        )
        do {
            return (
                try NSRegularExpression(pattern: skipPattern, options: regexOptions),
                try NSRegularExpression(pattern: matchPattern, options: regexOptions),
                captureGroupCount(in: rawSkip),
                namedCaptureNames(in: rawMatch)
            )
        } catch {
            throw RipgrepError.message(Self.compileErrorMessage(pattern: pattern, error: error))
        }
    }

    private static func skipFailAlternationSplit(
        in pattern: String
    ) -> (marker: Range<String.Index>, matchStart: String.Index)? {
        let shortMarker = "(*SKIP)(*F)|"
        let longMarker = "(*SKIP)(*FAIL)|"
        var escaped = false
        var inClass = false
        var depth = 0
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character == "Q" {
                    var quotedIndex = pattern.index(after: index)
                    var closedQuote = false
                    while quotedIndex < pattern.endIndex {
                        if pattern[quotedIndex] == "\\" {
                            let quoteEscapeIndex = pattern.index(after: quotedIndex)
                            if quoteEscapeIndex < pattern.endIndex,
                               pattern[quoteEscapeIndex] == "E" {
                                index = pattern.index(after: quoteEscapeIndex)
                                closedQuote = true
                                break
                            }
                        }
                        quotedIndex = pattern.index(after: quotedIndex)
                    }
                    guard closedQuote else {
                        return nil
                    }
                    escaped = false
                    continue
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            } else if !inClass, depth == 0, pattern[index...].hasPrefix(shortMarker) {
                return (
                    index..<pattern.index(index, offsetBy: shortMarker.count),
                    pattern.index(index, offsetBy: shortMarker.count)
                )
            } else if !inClass, depth == 0, pattern[index...].hasPrefix(longMarker) {
                return (
                    index..<pattern.index(index, offsetBy: longMarker.count),
                    pattern.index(index, offsetBy: longMarker.count)
                )
            } else if !inClass, character == "(" {
                depth += 1
            } else if !inClass, character == ")", depth > 0 {
                depth -= 1
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func captureGroupCount(in pattern: String) -> Int {
        var count = 0
        var escaped = false
        var inClass = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character == "Q" {
                    var quotedIndex = pattern.index(after: index)
                    var closedQuote = false
                    while quotedIndex < pattern.endIndex {
                        if pattern[quotedIndex] == "\\" {
                            let quoteEscapeIndex = pattern.index(after: quotedIndex)
                            if quoteEscapeIndex < pattern.endIndex,
                               pattern[quoteEscapeIndex] == "E" {
                                index = pattern.index(after: quoteEscapeIndex)
                                closedQuote = true
                                break
                            }
                        }
                        quotedIndex = pattern.index(after: quotedIndex)
                    }
                    guard closedQuote else {
                        return count
                    }
                    escaped = false
                    continue
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            } else if !inClass, character == "(" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "?" {
                    let marker = pattern.index(after: next)
                    if marker < pattern.endIndex, pattern[marker] == "P" {
                        let payload = pattern.index(after: marker)
                        if payload < pattern.endIndex, pattern[payload] == "<" {
                            count += 1
                        }
                    } else if marker < pattern.endIndex, pattern[marker] == "<" {
                        let payload = pattern.index(after: marker)
                        if payload < pattern.endIndex,
                           pattern[payload] != "=",
                           pattern[payload] != "!" {
                            count += 1
                        }
                    }
                } else {
                    count += 1
                }
            }
            index = pattern.index(after: index)
        }
        return count
    }

    private static func namedCaptureNames(in pattern: String) -> [String] {
        var names: [String] = []
        var escaped = false
        var inClass = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character == "Q" {
                    var quotedIndex = pattern.index(after: index)
                    var closedQuote = false
                    while quotedIndex < pattern.endIndex {
                        if pattern[quotedIndex] == "\\" {
                            let quoteEscapeIndex = pattern.index(after: quotedIndex)
                            if quoteEscapeIndex < pattern.endIndex,
                               pattern[quoteEscapeIndex] == "E" {
                                index = pattern.index(after: quoteEscapeIndex)
                                closedQuote = true
                                break
                            }
                        }
                        quotedIndex = pattern.index(after: quotedIndex)
                    }
                    guard closedQuote else {
                        return names
                    }
                    escaped = false
                    continue
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            } else if !inClass, character == "(" {
                if pattern[index...].hasPrefix("(?P<") {
                    let nameStart = pattern.index(index, offsetBy: 4)
                    if let close = pattern[nameStart...].firstIndex(of: ">") {
                        let name = String(pattern[nameStart..<close])
                        if isPCREGroupName(name), !names.contains(name) {
                            names.append(name)
                        }
                    }
                } else if pattern[index...].hasPrefix("(?<") {
                    let nameStart = pattern.index(index, offsetBy: 3)
                    if let close = pattern[nameStart...].firstIndex(of: ">") {
                        let name = String(pattern[nameStart..<close])
                        if isPCREGroupName(name), !names.contains(name) {
                            names.append(name)
                        }
                    }
                } else if pattern[index...].hasPrefix("(?'") {
                    let nameStart = pattern.index(index, offsetBy: 3)
                    if let close = pattern[nameStart...].firstIndex(of: "'") {
                        let name = String(pattern[nameStart..<close])
                        if isPCREGroupName(name), !names.contains(name) {
                            names.append(name)
                        }
                    }
                }
            }
            index = pattern.index(after: index)
        }
        return names
    }

    private static func balancedParenthesesRecursion(_ pattern: String) -> String? {
        let contentStart: String.Index
        let name: String
        if pattern.hasPrefix("(?P<") {
            let nameStart = pattern.index(pattern.startIndex, offsetBy: 4)
            guard let nameEnd = pattern[nameStart...].firstIndex(of: ">") else {
                return nil
            }
            name = String(pattern[nameStart..<nameEnd])
            contentStart = pattern.index(after: nameEnd)
        } else if pattern.hasPrefix("(?<") {
            let nameStart = pattern.index(pattern.startIndex, offsetBy: 3)
            guard nameStart < pattern.endIndex,
                  pattern[nameStart] != "=",
                  pattern[nameStart] != "!",
                  let nameEnd = pattern[nameStart...].firstIndex(of: ">") else {
                return nil
            }
            name = String(pattern[nameStart..<nameEnd])
            contentStart = pattern.index(after: nameEnd)
        } else {
            return nil
        }
        guard isPCREGroupName(name),
              let close = matchingClosingParen(forOpeningParenAt: pattern.startIndex, in: pattern),
              pattern.index(after: close) == pattern.endIndex else {
            return nil
        }
        let content = String(pattern[contentStart..<close])
        let possessivePattern = #"\((?:[^()]++|(?&\#(name)))*\)"#
        let greedyPattern = #"\((?:[^()]+|(?&\#(name)))*\)"#
        guard content == possessivePattern || content == greedyPattern else {
            return nil
        }
        return name
    }

    private static func branchResetAlternation(
        _ pattern: String,
        options: RipgrepOptions,
        regexOptions: NSRegularExpression.Options
    ) throws -> (alternatives: [BranchResetAlternative], maxCaptureCount: Int)? {
        guard pattern.hasPrefix("(?|"),
              let close = matchingClosingParen(forOpeningParenAt: pattern.startIndex, in: pattern) else {
            return nil
        }
        let bodyStart = pattern.index(pattern.startIndex, offsetBy: 3)
        let body = String(pattern[bodyStart..<close])
        let suffixStart = pattern.index(after: close)
        let suffix = String(pattern[suffixStart...])
        guard let branches = topLevelAlternatives(in: body),
              branches.count > 1,
              branches.allSatisfy({ !$0.isEmpty }),
              captureGroupCount(in: suffix) == 0 else {
            return nil
        }

        var alternatives: [BranchResetAlternative] = []
        alternatives.reserveCapacity(branches.count)
        var maxCaptureCount = 0
        do {
            for branch in branches {
                let branchPattern = branch + suffix
                let pattern = try regexPatternExpandingPCREQuotedLiterals(
                    branchPattern,
                    asciiShorthandEscapes: options.noUnicode
                )
                let captureCount = captureGroupCount(in: branch)
                maxCaptureCount = max(maxCaptureCount, captureCount)
                alternatives.append(BranchResetAlternative(
                    regex: try NSRegularExpression(pattern: pattern, options: regexOptions),
                    captureCount: captureCount,
                    namedCaptureNames: namedCaptureNames(in: branchPattern)
                ))
            }
            return (alternatives, maxCaptureCount)
        } catch {
            throw RipgrepError.message(Self.compileErrorMessage(pattern: pattern, error: error))
        }
    }

    private static func topLevelAlternatives(in pattern: String) -> [String]? {
        var alternatives: [String] = []
        var escaped = false
        var inClass = false
        var depth = 0
        var start = pattern.startIndex
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character == "Q" {
                    var quotedIndex = pattern.index(after: index)
                    var closedQuote = false
                    while quotedIndex < pattern.endIndex {
                        if pattern[quotedIndex] == "\\" {
                            let quoteEscapeIndex = pattern.index(after: quotedIndex)
                            if quoteEscapeIndex < pattern.endIndex,
                               pattern[quoteEscapeIndex] == "E" {
                                index = pattern.index(after: quoteEscapeIndex)
                                closedQuote = true
                                break
                            }
                        }
                        quotedIndex = pattern.index(after: quotedIndex)
                    }
                    guard closedQuote else {
                        return nil
                    }
                    escaped = false
                    continue
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            } else if !inClass, character == "(" {
                depth += 1
            } else if !inClass, character == ")" {
                guard depth > 0 else {
                    return nil
                }
                depth -= 1
            } else if !inClass, character == "|", depth == 0 {
                alternatives.append(String(pattern[start..<index]))
                start = pattern.index(after: index)
            }
            index = pattern.index(after: index)
        }
        guard depth == 0, !escaped else {
            return nil
        }
        alternatives.append(String(pattern[start...]))
        return alternatives
    }

    private static func fixedLiteralBackreference(
        _ pattern: String
    ) -> (literal: String, captureRanges: [Range<Int>], namedCaptureRanges: [String: Range<Int>])? {
        var groups: [(name: String?, literal: String)] = []
        var namedGroups: [String: Int] = [:]
        var captureRanges: [Range<Int>] = []
        var namedCaptureRanges: [String: Range<Int>] = [:]
        var literal = ""
        var byteOffset = 0
        var index = pattern.startIndex

        while index < pattern.endIndex,
              let group = fixedLiteralCaptureGroup(at: index, in: pattern) {
            let groupByteCount = group.literal.utf8.count
            let groupNumber = groups.count + 1
            let captureRange = byteOffset..<byteOffset + groupByteCount
            if let name = group.name {
                namedGroups[name] = groupNumber
                namedCaptureRanges[name] = captureRange
            }
            groups.append((group.name, group.literal))
            captureRanges.append(captureRange)
            literal += group.literal
            byteOffset += groupByteCount
            index = pattern.index(after: group.close)
        }

        guard !groups.isEmpty,
              index < pattern.endIndex,
              let reference = fixedBackreferenceIndex(
                at: index,
                in: pattern,
                namedGroups: namedGroups,
                precedingCaptureCount: groups.count
              ),
              reference.end == pattern.endIndex,
              reference.groupIndex > 0,
              reference.groupIndex <= groups.count else {
            return nil
        }
        literal += groups[reference.groupIndex - 1].literal
        return (literal, captureRanges, namedCaptureRanges)
    }

    private static func fixedAssertionConditional(
        _ pattern: String
    ) -> (condition: FixedAssertionCondition, trueLiteral: String, falseLiteral: String)? {
        guard pattern.hasPrefix("(?(") else {
            return nil
        }
        let assertionStart = pattern.index(pattern.startIndex, offsetBy: 2)
        guard let assertion = pcreAssertionCondition(at: assertionStart, in: pattern),
              let branches = pcreConditionalBranches(from: assertion.end, in: pattern),
              pattern.index(after: branches.close) == pattern.endIndex else {
            return nil
        }
        let rawTrueBranch = String(pattern[assertion.end..<branches.separator])
        let rawFalseBranch = branches.falseBranchStart.map { String(pattern[$0..<branches.close]) } ?? ""
        guard let conditionLiteral = RegexLiteralParser.literal(
            fromPlainRegexPattern: assertion.body,
            allowPCREQuotedLiterals: true
        ),
              let trueLiteral = RegexLiteralParser.literal(
                fromPlainRegexPattern: rawTrueBranch,
                allowPCREQuotedLiterals: true
              ),
              let falseLiteral = RegexLiteralParser.literal(
                fromPlainRegexPattern: rawFalseBranch,
                allowPCREQuotedLiterals: true
              ) else {
            return nil
        }
        guard !conditionLiteral.isEmpty,
              !trueLiteral.isEmpty,
              !falseLiteral.isEmpty,
              conditionLiteral.utf8.allSatisfy({ $0 < 0x80 }),
              trueLiteral.utf8.allSatisfy({ $0 < 0x80 }),
              falseLiteral.utf8.allSatisfy({ $0 < 0x80 }),
              !conditionLiteral.contains("\n"),
              !conditionLiteral.contains("\r"),
              !trueLiteral.contains("\n"),
              !trueLiteral.contains("\r"),
              !falseLiteral.contains("\n"),
              !falseLiteral.contains("\r") else {
            return nil
        }
        let conditionBytes = Array(conditionLiteral.utf8)
        let condition: FixedAssertionCondition
        switch assertion.truePrefix {
        case "(?=":
            condition = .positiveLookahead(conditionBytes)
        case "(?!":
            condition = .negativeLookahead(conditionBytes)
        case "(?<=":
            condition = .positiveLookbehind(conditionBytes)
        case "(?<!":
            condition = .negativeLookbehind(conditionBytes)
        default:
            return nil
        }
        return (condition, trueLiteral, falseLiteral)
    }

    private static func byteUnitPattern(_ pattern: String) -> ByteUnitPattern? {
        guard pattern.hasPrefix(#"\C"#) else {
            return nil
        }
        let quantifierStart = pattern.index(pattern.startIndex, offsetBy: 2)
        guard quantifierStart < pattern.endIndex else {
            return .single
        }
        let quantifier = pattern[quantifierStart...]
        if quantifier == "+" {
            return .oneOrMore
        }
        if quantifier == "+?" {
            return .single
        }
        guard quantifier.first == "{",
              quantifier.last == "}" else {
            return nil
        }
        let countText = quantifier.dropFirst().dropLast()
        guard !countText.isEmpty,
              countText.allSatisfy({ $0.isNumber }),
              let count = Int(countText),
              count > 0 else {
            return nil
        }
        return .fixed(count)
    }

    private static func containsByteUnitEscape(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if !inClass, character == "C" {
                    return true
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            }
            index = pattern.index(after: index)
        }
        return false
    }

    private static func fixedLiteralCaptureGroup(
        at index: String.Index,
        in pattern: String
    ) -> (name: String?, literal: String, close: String.Index)? {
        guard pattern[index] == "(" else {
            return nil
        }
        var name: String?
        var contentStart = pattern.index(after: index)
        if pattern[index...].hasPrefix("(?P<") {
            let nameStart = pattern.index(index, offsetBy: 4)
            guard let nameEnd = pattern[nameStart...].firstIndex(of: ">") else {
                return nil
            }
            let parsedName = String(pattern[nameStart..<nameEnd])
            guard isPCREGroupName(parsedName) else {
                return nil
            }
            name = parsedName
            contentStart = pattern.index(after: nameEnd)
        } else if pattern[index...].hasPrefix("(?<") {
            let nameStart = pattern.index(index, offsetBy: 3)
            guard nameStart < pattern.endIndex,
                  pattern[nameStart] != "=",
                  pattern[nameStart] != "!",
                  let nameEnd = pattern[nameStart...].firstIndex(of: ">") else {
                return nil
            }
            let parsedName = String(pattern[nameStart..<nameEnd])
            guard isPCREGroupName(parsedName) else {
                return nil
            }
            name = parsedName
            contentStart = pattern.index(after: nameEnd)
        }
        guard let close = firstUnescapedClosingParen(in: pattern[contentStart...]) else {
            return nil
        }
        let rawGroup = String(pattern[contentStart..<close])
        guard let literal = RegexLiteralParser.literal(
            fromPlainRegexPattern: rawGroup,
            allowPCREQuotedLiterals: true
        ) else {
            return nil
        }
        guard !literal.isEmpty,
              !literal.contains("\n"),
              !literal.contains("\r"),
              literal.utf8.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        return (name, literal, close)
    }

    private static func fixedBackreferenceIndex(
        at index: String.Index,
        in pattern: String,
        namedGroups: [String: Int],
        precedingCaptureCount: Int
    ) -> (groupIndex: Int, end: String.Index)? {
        if pattern[index] == "\\" {
            let marker = pattern.index(after: index)
            guard marker < pattern.endIndex else {
                return nil
            }
            if let reference = pattern[marker].wholeNumberValue {
                return (reference, pattern.index(after: marker))
            }
            if pattern[marker] == "g" {
                return fixedGBackreferenceIndex(
                    after: marker,
                    in: pattern,
                    namedGroups: namedGroups,
                    precedingCaptureCount: precedingCaptureCount
                )
            }
            if pattern[marker] == "k" {
                return fixedDelimitedBackreferenceIndex(
                    after: marker,
                    in: pattern,
                    namedGroups: namedGroups,
                    allowsNumeric: false
                )
            }
            return nil
        }

        guard pattern[index...].hasPrefix("(?P=") else {
            return nil
        }
        let nameStart = pattern.index(index, offsetBy: 4)
        guard let close = pattern[nameStart...].firstIndex(of: ")") else {
            return nil
        }
        let name = String(pattern[nameStart..<close])
        guard let groupIndex = namedGroups[name] else {
            return nil
        }
        return (groupIndex, pattern.index(after: close))
    }

    private static func fixedGBackreferenceIndex(
        after marker: String.Index,
        in pattern: String,
        namedGroups: [String: Int],
        precedingCaptureCount: Int
    ) -> (groupIndex: Int, end: String.Index)? {
        let payloadStart = pattern.index(after: marker)
        guard payloadStart < pattern.endIndex else {
            return nil
        }
        if pattern[payloadStart].isNumber {
            var digits = ""
            var index = payloadStart
            while index < pattern.endIndex, pattern[index].isNumber {
                digits.append(pattern[index])
                index = pattern.index(after: index)
            }
            guard let groupIndex = Int(digits) else {
                return nil
            }
            return (groupIndex, index)
        }
        if pattern[payloadStart] == "+" || pattern[payloadStart] == "-" {
            var index = pattern.index(after: payloadStart)
            while index < pattern.endIndex, pattern[index].isNumber {
                index = pattern.index(after: index)
            }
            guard index > pattern.index(after: payloadStart),
                  let signed = signedIntegerPayload(String(pattern[payloadStart..<index])),
                  signed.hasExplicitSign,
                  let groupIndex = relativeBackreferenceGroupIndex(
                    relative: signed.value,
                    precedingCaptureCount: precedingCaptureCount,
                    totalCaptureCount: precedingCaptureCount
                  ) else {
                return nil
            }
            return (groupIndex, index)
        }
        return fixedDelimitedBackreferenceIndex(
            after: marker,
            in: pattern,
            namedGroups: namedGroups,
            precedingCaptureCount: precedingCaptureCount
        )
    }

    private static func fixedDelimitedBackreferenceIndex(
        after marker: String.Index,
        in pattern: String,
        namedGroups: [String: Int],
        allowsNumeric: Bool = true,
        precedingCaptureCount: Int? = nil
    ) -> (groupIndex: Int, end: String.Index)? {
        let payloadStart = pattern.index(after: marker)
        guard let identifier = delimitedPCREBackreferenceIdentifier(at: payloadStart, in: pattern) else {
            return nil
        }
        if let precedingCaptureCount,
           let signed = signedIntegerPayload(identifier.name),
           signed.hasExplicitSign {
            guard let groupIndex = relativeBackreferenceGroupIndex(
                relative: signed.value,
                precedingCaptureCount: precedingCaptureCount,
                totalCaptureCount: precedingCaptureCount
            ) else {
                return nil
            }
            return (groupIndex, identifier.end)
        }
        if identifier.name.allSatisfy(\.isNumber),
           let groupIndex = Int(identifier.name) {
            guard allowsNumeric else {
                return nil
            }
            return (groupIndex, identifier.end)
        }
        guard let groupIndex = namedGroups[identifier.name] else {
            return nil
        }
        return (groupIndex, identifier.end)
    }

    private static func delimitedPCREBackreferenceIdentifier(
        at payloadStart: String.Index,
        in pattern: String
    ) -> (name: String, end: String.Index)? {
        guard payloadStart < pattern.endIndex else {
            return nil
        }
        let opener = pattern[payloadStart]
        let closer: Character
        switch opener {
        case "{":
            closer = "}"
        case "<":
            closer = ">"
        case "'":
            closer = "'"
        default:
            return nil
        }
        let nameStart = pattern.index(after: payloadStart)
        guard nameStart < pattern.endIndex,
              let close = pattern[nameStart...].firstIndex(of: closer) else {
            return nil
        }
        let name = String(pattern[nameStart..<close])
        guard !name.isEmpty else {
            return nil
        }
        return (name, pattern.index(after: close))
    }

    private static func firstUnescapedClosingParen(in text: Substring) -> String.Index? {
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                if character == "Q" {
                    var quotedIndex = text.index(after: index)
                    var closedQuote = false
                    while quotedIndex < text.endIndex {
                        if text[quotedIndex] == "\\" {
                            let quoteEscapeIndex = text.index(after: quotedIndex)
                            if quoteEscapeIndex < text.endIndex,
                               text[quoteEscapeIndex] == "E" {
                                index = text.index(after: quoteEscapeIndex)
                                closedQuote = true
                                break
                            }
                        }
                        quotedIndex = text.index(after: quotedIndex)
                    }
                    guard closedQuote else {
                        return nil
                    }
                    escaped = false
                    continue
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == ")" {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func matchingClosingParen(
        forOpeningParenAt open: String.Index,
        in pattern: String
    ) -> String.Index? {
        guard pattern[open] == "(" else {
            return nil
        }
        var escaped = false
        var inClass = false
        var depth = 0
        var index = pattern.index(after: open)
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character == "Q" {
                    var quotedIndex = pattern.index(after: index)
                    var closedQuote = false
                    while quotedIndex < pattern.endIndex {
                        if pattern[quotedIndex] == "\\" {
                            let quoteEscapeIndex = pattern.index(after: quotedIndex)
                            if quoteEscapeIndex < pattern.endIndex,
                               pattern[quoteEscapeIndex] == "E" {
                                index = pattern.index(after: quoteEscapeIndex)
                                closedQuote = true
                                break
                            }
                        }
                        quotedIndex = pattern.index(after: quotedIndex)
                    }
                    guard closedQuote else {
                        return nil
                    }
                    escaped = false
                    continue
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            } else if !inClass, character == "(" {
                depth += 1
            } else if !inClass, character == ")" {
                if depth == 0 {
                    return index
                }
                depth -= 1
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func fixedPositiveLookbehindMatches(
        prefix: [UInt8],
        literal: [UInt8],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
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
    }

    private static func fixedNegativeLookbehindMatches(
        prefix: [UInt8],
        literal: [UInt8],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
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
    }

    private static func fixedPositiveLookaheadMatches(
        literal: [UInt8],
        suffix: [UInt8],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
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
    }

    private static func fixedNegativeLookaheadMatches(
        literal: [UInt8],
        suffix: [UInt8],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
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
    }

    private static func fixedResetStartMatches(
        prefix: [UInt8],
        literal: [UInt8],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
        let needle = prefix + literal
        guard !needle.isEmpty else {
            return []
        }

        var matches: [PCRE2Match] = []
        let originalText = text
        var utf8Text = text
        utf8Text.withUTF8 { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            needle.withUnsafeBufferPointer { needleBytes in
                guard let needleBase = needleBytes.baseAddress,
                      needleBytes.count <= bytes.count else {
                    return
                }
                var searchOffset = 0
                while searchOffset <= bytes.count - needleBytes.count,
                      let found = findLiteral(
                        baseAddress.advanced(by: searchOffset),
                        bytes.count - searchOffset,
                        needleBase,
                        needleBytes.count,
                        caseInsensitiveASCII: caseInsensitiveASCII
                      ) {
                    let overallStart = baseAddress.distance(to: found)
                    let matchStart = overallStart + prefix.count
                    let matchEnd = matchStart + literal.count
                    if let range = stringRange(startByte: matchStart, endByte: matchEnd, in: originalText) {
                        matches.append(PCRE2Match(
                            range: range,
                            byteRange: matchStart..<matchEnd,
                            captures: [range]
                        ))
                    }
                    let overallEnd = overallStart + needleBytes.count
                    searchOffset = literal.isEmpty ? overallEnd + 1 : overallEnd
                }
            }
        }
        return matches
    }

    private static func literalPrefixResetStartRegexMatches(
        prefixUTF16Length: Int,
        regex: NSRegularExpression,
        namedCaptureNames: [String],
        in text: String
    ) -> [PCRE2Match] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let fullRange = match.range(at: 0)
            guard fullRange.location != NSNotFound else {
                return nil
            }
            let resetLocation = fullRange.location + prefixUTF16Length
            let fullEnd = fullRange.location + fullRange.length
            guard resetLocation <= fullEnd,
                  let range = Range(
                    NSRange(location: resetLocation, length: fullEnd - resetLocation),
                    in: text
                  ) else {
                return nil
            }

            var captures: [Range<String.Index>?] = [range]
            captures.reserveCapacity(match.numberOfRanges)
            if match.numberOfRanges > 1 {
                for index in 1..<match.numberOfRanges {
                    let captureRange = match.range(at: index)
                    guard captureRange.location != NSNotFound else {
                        captures.append(nil)
                        continue
                    }
                    guard let capture = Range(captureRange, in: text) else {
                        return nil
                    }
                    captures.append(capture)
                }
            }

            return PCRE2Match(
                range: range,
                byteRange: byteRange(for: range, in: text),
                captures: captures,
                namedCaptures: namedCaptures(
                    from: match,
                    names: namedCaptureNames,
                    in: text
                )
            )
        }
    }

    private static func capturedPrefixResetStartRegexMatches(
        regex: NSRegularExpression,
        namedCaptureNames: [String],
        in text: String
    ) -> [PCRE2Match] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let fullRange = match.range(at: 0)
            let boundaryRange = match.range(at: 1)
            guard fullRange.location != NSNotFound,
                  boundaryRange.location != NSNotFound else {
                return nil
            }

            let resetLocation = boundaryRange.location + boundaryRange.length
            let fullEnd = fullRange.location + fullRange.length
            guard resetLocation <= fullEnd,
                  let range = Range(
                    NSRange(location: resetLocation, length: fullEnd - resetLocation),
                    in: text
                  ) else {
                return nil
            }

            var captures: [Range<String.Index>?] = [range]
            captures.reserveCapacity(max(match.numberOfRanges - 1, 1))
            if match.numberOfRanges > 2 {
                for index in 2..<match.numberOfRanges {
                    let captureRange = match.range(at: index)
                    guard captureRange.location != NSNotFound else {
                        captures.append(nil)
                        continue
                    }
                    guard let capture = Range(captureRange, in: text) else {
                        return nil
                    }
                    captures.append(capture)
                }
            }

            return PCRE2Match(
                range: range,
                byteRange: byteRange(for: range, in: text),
                captures: captures,
                namedCaptures: namedCaptures(
                    from: match,
                    names: namedCaptureNames,
                    in: text
                )
            )
        }
    }

    private static func byteUnitRegexMatches(
        regex: NSRegularExpression,
        unicodeStartOnly: Bool,
        namedCaptureNames: [String],
        in text: String
    ) -> [PCRE2Match] {
        let bytes = text.unicodeScalars.compactMap { scalar -> UInt8? in
            guard scalar.value <= UInt8.max else {
                return nil
            }
            return UInt8(scalar.value)
        }
        guard bytes.count == text.unicodeScalars.count else {
            return []
        }

        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let fullRange = match.range(at: 0)
            guard fullRange.location != NSNotFound,
                  let range = Range(fullRange, in: text) else {
                return nil
            }
            let startOffset = scalarOffset(for: range.lowerBound, in: text)
            if unicodeStartOnly,
               startOffset < bytes.count,
               isUTF8ContinuationByte(bytes[startOffset]) {
                return nil
            }

            var captures: [Range<String.Index>?] = []
            captures.reserveCapacity(match.numberOfRanges)
            for index in 0..<match.numberOfRanges {
                let captureRange = match.range(at: index)
                guard captureRange.location != NSNotFound else {
                    captures.append(nil)
                    continue
                }
                guard let capture = Range(captureRange, in: text) else {
                    return nil
                }
                captures.append(capture)
            }

            return PCRE2Match(
                range: range,
                byteRange: scalarOffset(for: range.lowerBound, in: text)..<scalarOffset(for: range.upperBound, in: text),
                captures: captures,
                namedCaptures: namedCaptures(
                    from: match,
                    names: namedCaptureNames,
                    in: text
                )
            )
        }
    }

    private static func branchResetAlternationMatches(
        alternatives: [BranchResetAlternative],
        maxCaptureCount: Int,
        in text: String
    ) -> [PCRE2Match] {
        struct Candidate {
            let branchIndex: Int
            let alternative: BranchResetAlternative
            let match: NSTextCheckingResult
            let range: NSRange
        }

        let fullSearchRange = NSRange(text.startIndex..., in: text)
        var candidates: [Candidate] = []
        for (branchIndex, alternative) in alternatives.enumerated() {
            let matches = alternative.regex.matches(in: text, range: fullSearchRange)
            candidates.append(contentsOf: matches.compactMap { match in
                let range = match.range(at: 0)
                guard range.location != NSNotFound else {
                    return nil
                }
                return Candidate(
                    branchIndex: branchIndex,
                    alternative: alternative,
                    match: match,
                    range: range
                )
            })
        }
        candidates.sort {
            if $0.range.location == $1.range.location {
                return $0.branchIndex < $1.branchIndex
            }
            return $0.range.location < $1.range.location
        }

        var matches: [PCRE2Match] = []
        var nextSearchLocation = fullSearchRange.location
        for candidate in candidates {
            guard candidate.range.location >= nextSearchLocation,
                  let range = Range(candidate.range, in: text) else {
                continue
            }

            var captures: [Range<String.Index>?] = [range]
            captures.reserveCapacity(maxCaptureCount + 1)
            if candidate.match.numberOfRanges > 1 {
                for index in 1..<candidate.match.numberOfRanges {
                    let captureRange = candidate.match.range(at: index)
                    guard captureRange.location != NSNotFound else {
                        captures.append(nil)
                        continue
                    }
                    guard let capture = Range(captureRange, in: text) else {
                        return matches
                    }
                    captures.append(capture)
                }
            }
            if captures.count < maxCaptureCount + 1 {
                captures.append(contentsOf: repeatElement(nil, count: maxCaptureCount + 1 - captures.count))
            }

            matches.append(PCRE2Match(
                range: range,
                byteRange: byteRange(for: range, in: text),
                captures: captures,
                namedCaptures: namedCaptures(
                    from: candidate.match,
                    names: candidate.alternative.namedCaptureNames,
                    in: text
                )
            ))
            nextSearchLocation = candidate.range.location + max(candidate.range.length, 1)
        }
        return matches
    }

    private static func skipFailAlternationMatches(
        skipRegex: NSRegularExpression,
        matchRegex: NSRegularExpression,
        skipCaptureCount: Int,
        matchNamedCaptureNames: [String],
        in text: String
    ) -> [PCRE2Match] {
        let fullSearchRange = NSRange(text.startIndex..., in: text)
        let skipRanges = skipRegex.matches(in: text, range: fullSearchRange)
            .map(\.range)
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted {
                if $0.location == $1.location {
                    return $0.length > $1.length
                }
                return $0.location < $1.location
            }
        let matchResults = matchRegex.matches(in: text, range: fullSearchRange)
        var matches: [PCRE2Match] = []
        var skipIndex = 0
        for match in matchResults {
            let fullRange = match.range(at: 0)
            guard fullRange.location != NSNotFound else {
                continue
            }
            while skipIndex < skipRanges.count,
                  skipRanges[skipIndex].location + skipRanges[skipIndex].length <= fullRange.location {
                skipIndex += 1
            }
            if skipIndex < skipRanges.count,
               skipRanges[skipIndex].location <= fullRange.location,
               fullRange.location < skipRanges[skipIndex].location + skipRanges[skipIndex].length {
                continue
            }
            guard let range = Range(fullRange, in: text) else {
                continue
            }

            var captures: [Range<String.Index>?] = [range]
            captures.reserveCapacity(match.numberOfRanges + skipCaptureCount)
            captures.append(contentsOf: repeatElement(nil, count: skipCaptureCount))
            if match.numberOfRanges > 1 {
                for index in 1..<match.numberOfRanges {
                    let captureRange = match.range(at: index)
                    guard captureRange.location != NSNotFound else {
                        captures.append(nil)
                        continue
                    }
                    guard let capture = Range(captureRange, in: text) else {
                        return matches
                    }
                    captures.append(capture)
                }
            }

            matches.append(PCRE2Match(
                range: range,
                byteRange: byteRange(for: range, in: text),
                captures: captures,
                namedCaptures: namedCaptures(
                    from: match,
                    names: matchNamedCaptureNames,
                    in: text
                )
            ))
        }
        return matches
    }

    private static func fixedLiteralBackreferenceMatches(
        literal: [UInt8],
        captureRanges: [Range<Int>],
        namedCaptureRanges: [String: Range<Int>],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
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
                            captures: captures,
                            namedCaptures: namedCaptureRanges.compactMapValues { captureRange in
                                stringRange(
                                    startByte: matchOffset + captureRange.lowerBound,
                                    endByte: matchOffset + captureRange.upperBound,
                                    in: originalText
                                )
                            }
                        ))
                    }
                    searchOffset = matchOffset + literalBytes.count
                }
            }
        }
        return matches
    }

    private static func fixedAssertionConditionalMatches(
        condition: FixedAssertionCondition,
        trueLiteral: [UInt8],
        falseLiteral: [UInt8],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
        enum ConditionKind {
            case positiveLookahead
            case negativeLookahead
            case positiveLookbehind
            case negativeLookbehind
        }

        let conditionBytes: [UInt8]
        let conditionKind: ConditionKind
        switch condition {
        case .positiveLookahead(let bytes):
            conditionBytes = bytes
            conditionKind = .positiveLookahead
        case .negativeLookahead(let bytes):
            conditionBytes = bytes
            conditionKind = .negativeLookahead
        case .positiveLookbehind(let bytes):
            conditionBytes = bytes
            conditionKind = .positiveLookbehind
        case .negativeLookbehind(let bytes):
            conditionBytes = bytes
            conditionKind = .negativeLookbehind
        }

        var matches: [PCRE2Match] = []
        let originalText = text
        var utf8Text = text
        utf8Text.withUTF8 { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            conditionBytes.withUnsafeBufferPointer { conditionBuffer in
                trueLiteral.withUnsafeBufferPointer { trueBuffer in
                    falseLiteral.withUnsafeBufferPointer { falseBuffer in
                        guard let conditionBase = conditionBuffer.baseAddress,
                              let trueBase = trueBuffer.baseAddress,
                              let falseBase = falseBuffer.baseAddress,
                              !conditionBuffer.isEmpty,
                              !trueBuffer.isEmpty,
                              !falseBuffer.isEmpty else {
                            return
                        }

                        var offset = 0
                        while offset < bytes.count {
                            let conditionMatched: Bool
                            switch conditionKind {
                            case .positiveLookahead:
                                conditionMatched = offset + conditionBuffer.count <= bytes.count
                                    && bytesEqual(
                                        baseAddress.advanced(by: offset),
                                        conditionBase,
                                        conditionBuffer.count,
                                        caseInsensitiveASCII: caseInsensitiveASCII
                                    )
                            case .negativeLookahead:
                                conditionMatched = !(offset + conditionBuffer.count <= bytes.count
                                    && bytesEqual(
                                        baseAddress.advanced(by: offset),
                                        conditionBase,
                                        conditionBuffer.count,
                                        caseInsensitiveASCII: caseInsensitiveASCII
                                    ))
                            case .positiveLookbehind:
                                conditionMatched = offset >= conditionBuffer.count
                                    && bytesEqual(
                                        baseAddress.advanced(by: offset - conditionBuffer.count),
                                        conditionBase,
                                        conditionBuffer.count,
                                        caseInsensitiveASCII: caseInsensitiveASCII
                                    )
                            case .negativeLookbehind:
                                conditionMatched = !(offset >= conditionBuffer.count
                                    && bytesEqual(
                                        baseAddress.advanced(by: offset - conditionBuffer.count),
                                        conditionBase,
                                        conditionBuffer.count,
                                        caseInsensitiveASCII: caseInsensitiveASCII
                                    ))
                            }

                            let literalBase = conditionMatched ? trueBase : falseBase
                            let literalCount = conditionMatched ? trueBuffer.count : falseBuffer.count
                            if offset + literalCount <= bytes.count,
                               bytesEqual(
                                baseAddress.advanced(by: offset),
                                literalBase,
                                literalCount,
                                caseInsensitiveASCII: caseInsensitiveASCII
                               ),
                               let range = stringRange(
                                startByte: offset,
                                endByte: offset + literalCount,
                                in: originalText
                               ) {
                                matches.append(PCRE2Match(
                                    range: range,
                                    byteRange: offset..<offset + literalCount,
                                    captures: [range]
                                ))
                                offset += literalCount
                            } else {
                                offset += 1
                            }
                        }
                    }
                }
            }
        }
        return matches
    }

    private static func byteUnitMatches(
        pattern: ByteUnitPattern,
        unicodeStartOnly: Bool,
        in text: String
    ) -> [PCRE2Match] {
        let scalars = Array(text.unicodeScalars)
        let bytes = scalars.compactMap { scalar -> UInt8? in
            guard scalar.value <= UInt8.max else {
                return nil
            }
            return UInt8(scalar.value)
        }
        guard bytes.count == scalars.count, !bytes.isEmpty else {
            return []
        }

        func isAllowedStart(_ offset: Int) -> Bool {
            !unicodeStartOnly || !isUTF8ContinuationByte(bytes[offset])
        }

        var matches: [PCRE2Match] = []
        switch pattern {
        case .single:
            var offset = 0
            while offset < bytes.count {
                guard isAllowedStart(offset) else {
                    offset += 1
                    continue
                }
                appendByteUnitMatch(start: offset, end: offset + 1, in: text, to: &matches)
                offset += 1
            }
        case .oneOrMore:
            var offset = 0
            while offset < bytes.count, !isAllowedStart(offset) {
                offset += 1
            }
            if offset < bytes.count {
                appendByteUnitMatch(start: offset, end: bytes.count, in: text, to: &matches)
            }
        case .fixed(let count):
            var offset = 0
            while offset + count <= bytes.count {
                guard isAllowedStart(offset) else {
                    offset += 1
                    continue
                }
                appendByteUnitMatch(start: offset, end: offset + count, in: text, to: &matches)
                offset += count
            }
        }
        return matches
    }

    private static func bareResetStartMatches(in text: String) -> [PCRE2Match] {
        var matches: [PCRE2Match] = []
        var index = text.startIndex
        while index < text.endIndex {
            let range = index..<index
            matches.append(PCRE2Match(
                range: range,
                byteRange: byteRange(for: range, in: text),
                captures: [range]
            ))
            index = text.index(after: index)
        }
        return matches
    }

    private static func balancedParenthesesRecursionMatches(name: String, in text: String) -> [PCRE2Match] {
        var matches: [PCRE2Match] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "(" else {
                index = text.index(after: index)
                continue
            }
            guard let end = balancedParenthesesEnd(startingAt: index, in: text) else {
                index = text.index(after: index)
                continue
            }
            let range = index..<end
            matches.append(PCRE2Match(
                range: range,
                byteRange: byteRange(for: range, in: text),
                captures: [range, range],
                namedCaptures: [name: range]
            ))
            index = end
        }
        return matches
    }

    private static func balancedParenthesesEnd(startingAt start: String.Index, in text: String) -> String.Index? {
        var depth = 0
        var index = start
        while index < text.endIndex {
            if text[index] == "(" {
                depth += 1
            } else if text[index] == ")" {
                depth -= 1
                if depth == 0 {
                    return text.index(after: index)
                }
                if depth < 0 {
                    return nil
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func appendByteUnitMatch(
        start: Int,
        end: Int,
        in text: String,
        to matches: inout [PCRE2Match]
    ) {
        guard let range = scalarRange(startOffset: start, endOffset: end, in: text) else {
            return
        }
        matches.append(PCRE2Match(
            range: range,
            byteRange: start..<end,
            captures: [range]
        ))
    }

    private static func scalarRange(startOffset: Int, endOffset: Int, in text: String) -> Range<String.Index>? {
        guard startOffset >= 0,
              endOffset >= startOffset,
              let lower = text.unicodeScalars.index(
                text.unicodeScalars.startIndex,
                offsetBy: startOffset,
                limitedBy: text.unicodeScalars.endIndex
              ),
              let upper = text.unicodeScalars.index(
                text.unicodeScalars.startIndex,
                offsetBy: endOffset,
                limitedBy: text.unicodeScalars.endIndex
              ),
              let lowerIndex = lower.samePosition(in: text),
              let upperIndex = upper.samePosition(in: text) else {
            return nil
        }
        return lowerIndex..<upperIndex
    }

    private static func isUTF8ContinuationByte(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }

    private static func findLiteral(
        _ haystack: UnsafePointer<UInt8>,
        _ haystackLength: Int,
        _ literal: UnsafePointer<UInt8>,
        _ literalLength: Int,
        caseInsensitiveASCII: Bool
    ) -> UnsafePointer<UInt8>? {
        #if canImport(CRipgrepPlatform)
        if caseInsensitiveASCII {
            return rg_memcasemem_ascii(haystack, haystackLength, literal, literalLength)
        }
        return rg_memmem_simple(haystack, haystackLength, literal, literalLength)
        #else
        guard literalLength > 0, haystackLength >= literalLength else {
            return nil
        }
        var offset = 0
        while offset <= haystackLength - literalLength {
            if bytesEqual(
                haystack.advanced(by: offset),
                literal,
                literalLength,
                caseInsensitiveASCII: caseInsensitiveASCII
            ) {
                return haystack.advanced(by: offset)
            }
            offset += 1
        }
        return nil
        #endif
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

    private static func stringRange(startByte: Int, endByte: Int, in text: String) -> Range<String.Index>? {
        let lowerUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: startByte)
        let upperUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: endByte)
        guard let lower = lowerUTF8.samePosition(in: text),
              let upper = upperUTF8.samePosition(in: text) else {
            return nil
        }
        return lower..<upper
    }

    private static func match(
        from match: NSTextCheckingResult,
        namedCaptureNames: [String],
        in text: String
    ) -> PCRE2Match? {
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
            captures: captures,
            namedCaptures: namedCaptures(from: match, names: namedCaptureNames, in: text)
        )
    }

    private static func namedCaptures(
        from match: NSTextCheckingResult,
        names: [String],
        in text: String
    ) -> [String: Range<String.Index>] {
        var captures: [String: Range<String.Index>] = [:]
        captures.reserveCapacity(names.count)
        for name in names {
            let range = match.range(withName: name)
            guard range.location != NSNotFound,
                  let stringRange = Range(range, in: text) else {
                continue
            }
            captures[name] = stringRange
        }
        return captures
    }

    private static func byteRange(for range: Range<String.Index>, in text: String) -> Range<Int> {
        text[..<range.lowerBound].utf8.count..<text[..<range.upperBound].utf8.count
    }

    private static func scalarOffset(for index: String.Index, in text: String) -> Int {
        text[..<index].unicodeScalars.count
    }

    private static func compileErrorMessage(pattern: String, error: Error) -> String {
        """
        PCRE2-compatible regex error: \(error.localizedDescription)
        \(pattern)
        """
    }

    private static func regexPatternExpandingPCREQuotedLiterals(
        _ pattern: String,
        asciiShorthandEscapes: Bool = false,
        numericCaptureOffset: Int = 0,
        captureCountBase: Int = 0,
        totalCaptureCountOverride: Int? = nil
    ) throws -> String {
        var pattern = patternExpandingSimpleSubroutineCall(pattern)
            ?? patternExpandingSimpleGroupStateConditional(pattern)
            ?? pattern
        pattern = patternExpandingLeadingUngreedyMode(pattern)
        var output = ""
        var inClass = false
        var index = pattern.startIndex
        var totalCaptureCountCache: Int?
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "\\" {
                let marker = pattern.index(after: index)
                if marker < pattern.endIndex {
                    if pattern[marker] == "Q" {
                        var literal = ""
                        var quotedIndex = pattern.index(after: marker)
                        var closedQuote = false
                        while quotedIndex < pattern.endIndex {
                            if pattern[quotedIndex] == "\\" {
                                let quoteEscapeIndex = pattern.index(after: quotedIndex)
                                if quoteEscapeIndex < pattern.endIndex,
                                   pattern[quoteEscapeIndex] == "E" {
                                    index = pattern.index(after: quoteEscapeIndex)
                                    closedQuote = true
                                    break
                                }
                            }
                            literal.append(pattern[quotedIndex])
                            quotedIndex = pattern.index(after: quotedIndex)
                        }
                        guard closedQuote else {
                            throw RipgrepError.message(
                                "PCRE2: error compiling pattern at offset \(pattern.utf8.count + 4): missing closing parenthesis"
                            )
                        }
                        output += NSRegularExpression.escapedPattern(for: literal)
                        continue
                    }
                    if pattern[marker] == "E" {
                        index = pattern.index(after: marker)
                        continue
                    }
                    if !inClass,
                       pattern[marker] == "C" {
                        output += "[\\x{00}-\\x{FF}]"
                        index = pattern.index(after: marker)
                        continue
                    }
                    if !inClass,
                       pattern[marker] == "N" {
                        let end = pattern.index(after: marker)
                        if end == pattern.endIndex || pattern[end] != "{" {
                            output += "[^\\n]"
                            index = end
                            continue
                        }
                        throw RipgrepError.message(
                            "PCRE2: error compiling pattern at offset \(pattern[..<end].utf8.count + 4): PCRE2 does not support \\F, \\L, \\l, \\N{name}, \\U, or \\u"
                        )
                    }
                    if !inClass,
                       let digit = pattern[marker].wholeNumberValue,
                       numericCaptureOffset != 0 {
                        var digits = String(digit)
                        var digitIndex = pattern.index(after: marker)
                        while digitIndex < pattern.endIndex,
                              pattern[digitIndex].isNumber {
                            digits.append(pattern[digitIndex])
                            digitIndex = pattern.index(after: digitIndex)
                        }
                        if let groupIndex = Int(digits) {
                            output += "\\\(groupIndex + numericCaptureOffset)"
                            index = digitIndex
                            continue
                        }
                    }
                    if !inClass,
                       pattern[marker] == "g" {
                        let precedingCaptureCount = captureCountBase + captureGroupCount(in: String(pattern[..<index]))
                        let totalCaptureCount: Int
                        if let cached = totalCaptureCountCache {
                            totalCaptureCount = cached
                        } else {
                            let computed = totalCaptureCountOverride
                                ?? captureCountBase + captureGroupCount(in: pattern)
                            totalCaptureCountCache = computed
                            totalCaptureCount = computed
                        }
                        if let backreference = try pcreGBackreference(
                            after: marker,
                            in: pattern,
                            numericCaptureOffset: numericCaptureOffset,
                            precedingCaptureCount: precedingCaptureCount,
                            totalCaptureCount: totalCaptureCount
                        ) {
                            output += backreference.pattern
                            index = backreference.end
                            continue
                        }
                    }
                    if !inClass,
                       pattern[marker] == "k",
                       let identifier = delimitedPCREBackreferenceIdentifier(
                        at: pattern.index(after: marker),
                        in: pattern
                       ),
                       identifier.name.allSatisfy(\.isNumber) {
                        let nameStart = pattern.index(pattern.index(after: marker), offsetBy: 1)
                        throw RipgrepError.message(
                            "PCRE2: error compiling pattern at offset \(pattern[..<nameStart].utf8.count + 4): subpattern name must start with a non-digit"
                        )
                    }
                    if !inClass,
                       pattern[marker] == "k",
                       numericCaptureOffset != 0 {
                        let payloadStart = pattern.index(after: marker)
                        if let identifier = delimitedPCREBackreferenceIdentifier(at: payloadStart, in: pattern),
                           identifier.name.allSatisfy(\.isNumber),
                           let groupIndex = Int(identifier.name) {
                            output += "\\\(groupIndex + numericCaptureOffset)"
                            index = identifier.end
                            continue
                        }
                    }
                    if asciiShorthandEscapes,
                       let shorthand = asciiShorthandEscapePattern(pattern[marker], inClass: inClass) {
                        output += shorthand
                        index = pattern.index(after: marker)
                        continue
                    }
                    output.append(character)
                    output.append(pattern[marker])
                    index = pattern.index(after: marker)
                    continue
                }
            }
            if !inClass, character == "(" {
                if pattern[index...].hasPrefix("(*PRUNE)") {
                    index = pattern.index(index, offsetBy: "(*PRUNE)".count)
                    continue
                }
                if let conditional = try pcreConditionalAssertionSyntax(
                    at: index,
                    in: pattern,
                    asciiShorthandEscapes: asciiShorthandEscapes
                ) {
                    output += conditional.pattern
                    index = conditional.end
                    continue
                }
                if let groupSyntax = pcrePythonGroupSyntax(at: index, in: pattern) {
                    output += groupSyntax.pattern
                    index = groupSyntax.end
                    continue
                }
            }
            output.append(character)
            if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            }
            index = pattern.index(after: index)
        }
        return output
    }

    private enum PCREGroupStateCondition {
        case numbered(Int)
        case named(String)
    }

    private enum PCRESubroutineCall {
        case numbered(Int)
        case named(String)
    }

    private static func patternExpandingSimpleSubroutineCall(_ pattern: String) -> String? {
        guard let group = fixedLiteralCaptureGroup(at: pattern.startIndex, in: pattern) else {
            return nil
        }
        let callStart = pattern.index(after: group.close)
        guard callStart < pattern.endIndex,
              let call = pcreSubroutineCall(at: callStart, in: pattern),
              call.end == pattern.endIndex else {
            return nil
        }
        switch call.group {
        case .numbered(let groupIndex):
            guard groupIndex == 1 else {
                return nil
            }
        case .named(let name):
            guard group.name == name else {
                return nil
            }
        }

        let rawGroup = String(pattern[pattern.startIndex...group.close])
        return "\(rawGroup)(?:\(NSRegularExpression.escapedPattern(for: group.literal)))"
    }

    private static func pcreSubroutineCall(
        at index: String.Index,
        in pattern: String
    ) -> (group: PCRESubroutineCall, end: String.Index)? {
        guard pattern[index...].hasPrefix("(?") else {
            return nil
        }
        let payloadStart = pattern.index(index, offsetBy: 2)
        guard payloadStart < pattern.endIndex else {
            return nil
        }
        if pattern[payloadStart].isNumber {
            var payloadEnd = payloadStart
            var digits = ""
            while payloadEnd < pattern.endIndex,
                  pattern[payloadEnd].isNumber {
                digits.append(pattern[payloadEnd])
                payloadEnd = pattern.index(after: payloadEnd)
            }
            guard payloadEnd < pattern.endIndex,
                  pattern[payloadEnd] == ")",
                  let groupIndex = Int(digits) else {
                return nil
            }
            return (.numbered(groupIndex), pattern.index(after: payloadEnd))
        }
        if pattern[payloadStart] == "&" {
            let nameStart = pattern.index(after: payloadStart)
            guard let nameEnd = pattern[nameStart...].firstIndex(of: ")") else {
                return nil
            }
            let name = String(pattern[nameStart..<nameEnd])
            guard isPCREGroupName(name) else {
                return nil
            }
            return (.named(name), pattern.index(after: nameEnd))
        }
        if pattern[payloadStart] == "P" {
            let nameStart = pattern.index(after: payloadStart)
            guard nameStart < pattern.endIndex,
                  pattern[nameStart] == ">",
                  pattern.index(after: nameStart) < pattern.endIndex else {
                return nil
            }
            let nameBodyStart = pattern.index(after: nameStart)
            guard let nameEnd = pattern[nameBodyStart...].firstIndex(of: ")") else {
                return nil
            }
            let name = String(pattern[nameBodyStart..<nameEnd])
            guard isPCREGroupName(name) else {
                return nil
            }
            return (.named(name), pattern.index(after: nameEnd))
        }
        return nil
    }

    private static func patternExpandingSimpleGroupStateConditional(_ pattern: String) -> String? {
        guard let group = fixedLiteralCaptureGroup(at: pattern.startIndex, in: pattern) else {
            return nil
        }
        let quantifier = pattern.index(after: group.close)
        guard quantifier < pattern.endIndex,
              pattern[quantifier] == "?" else {
            return nil
        }
        let conditionalStart = pattern.index(after: quantifier)
        guard conditionalStart < pattern.endIndex,
              let condition = pcreGroupStateCondition(at: conditionalStart, in: pattern),
              let branches = pcreConditionalBranches(from: condition.end, in: pattern),
              pattern.index(after: branches.close) == pattern.endIndex else {
            return nil
        }
        switch condition.group {
        case .numbered(let groupIndex):
            guard groupIndex == 1 else {
                return nil
            }
        case .named(let name):
            guard group.name == name else {
                return nil
            }
        }

        let rawGroup = String(pattern[pattern.startIndex...group.close])
        let trueBranch = String(pattern[condition.end..<branches.separator])
        let falseBranch = branches.falseBranchStart.map { String(pattern[$0..<branches.close]) } ?? ""
        return "(?:\(rawGroup)\(trueBranch)|\(falseBranch))"
    }

    private static func pcreGroupStateCondition(
        at index: String.Index,
        in pattern: String
    ) -> (group: PCREGroupStateCondition, end: String.Index)? {
        guard pattern[index...].hasPrefix("(?(") else {
            return nil
        }
        let payloadStart = pattern.index(index, offsetBy: 3)
        guard payloadStart < pattern.endIndex else {
            return nil
        }
        if pattern[payloadStart].isNumber {
            var payloadEnd = payloadStart
            var digits = ""
            while payloadEnd < pattern.endIndex,
                  pattern[payloadEnd].isNumber {
                digits.append(pattern[payloadEnd])
                payloadEnd = pattern.index(after: payloadEnd)
            }
            guard payloadEnd < pattern.endIndex,
                  pattern[payloadEnd] == ")",
                  let groupIndex = Int(digits) else {
                return nil
            }
            return (.numbered(groupIndex), pattern.index(after: payloadEnd))
        }
        if pattern[payloadStart] == "<" {
            let nameStart = pattern.index(after: payloadStart)
            guard nameStart < pattern.endIndex,
                  let nameEnd = pattern[nameStart...].firstIndex(of: ">") else {
                return nil
            }
            let close = pattern.index(after: nameEnd)
            guard close < pattern.endIndex,
                  pattern[close] == ")" else {
                return nil
            }
            let name = String(pattern[nameStart..<nameEnd])
            guard isPCREGroupName(name) else {
                return nil
            }
            return (.named(name), pattern.index(after: close))
        }

        var payloadEnd = payloadStart
        while payloadEnd < pattern.endIndex,
              pattern[payloadEnd] != ")" {
            payloadEnd = pattern.index(after: payloadEnd)
        }
        guard payloadEnd < pattern.endIndex else {
            return nil
        }
        let name = String(pattern[payloadStart..<payloadEnd])
        guard isPCREGroupName(name) else {
            return nil
        }
        return (.named(name), pattern.index(after: payloadEnd))
    }

    private static func patternExpandingLeadingUngreedyMode(_ pattern: String) -> String {
        guard pattern.hasPrefix("(?U)") else {
            return pattern
        }
        return transformUngreedyQuantifiers(in: String(pattern.dropFirst(4)))
    }

    private static func transformUngreedyQuantifiers(in pattern: String) -> String {
        var output = ""
        var escaped = false
        var inClass = false
        var quantifiableAtom = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                output.append("\\")
                output.append(character)
                escaped = false
                quantifiableAtom = true
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if inClass {
                output.append(character)
                if character == "]" {
                    inClass = false
                    quantifiableAtom = true
                }
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                output.append(character)
                inClass = true
                quantifiableAtom = false
                index = pattern.index(after: index)
                continue
            }
            if quantifiableAtom, character == "*" || character == "+" || character == "?" {
                output.append(character)
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "?" {
                    index = pattern.index(after: next)
                } else {
                    output.append("?")
                    index = next
                }
                quantifiableAtom = false
                continue
            }
            if quantifiableAtom,
               character == "{",
               let close = repetitionQuantifierClose(openingAt: index, in: pattern) {
                output += pattern[index...close]
                let next = pattern.index(after: close)
                if next < pattern.endIndex, pattern[next] == "?" {
                    index = pattern.index(after: next)
                } else {
                    output.append("?")
                    index = next
                }
                quantifiableAtom = false
                continue
            }

            output.append(character)
            switch character {
            case "(", "|", "^":
                quantifiableAtom = false
            case ")":
                quantifiableAtom = true
            default:
                quantifiableAtom = true
            }
            index = pattern.index(after: index)
        }
        if escaped {
            output.append("\\")
        }
        return output
    }

    private static func repetitionQuantifierClose(
        openingAt open: String.Index,
        in pattern: String
    ) -> String.Index? {
        var index = pattern.index(after: open)
        var sawDigit = false
        var sawComma = false
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "}" {
                return sawDigit ? index : nil
            }
            if character == "," {
                guard !sawComma else {
                    return nil
                }
                sawComma = true
            } else if character.isNumber {
                sawDigit = true
            } else {
                return nil
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func asciiShorthandEscapePattern(_ marker: Character, inClass: Bool) -> String? {
        switch marker {
        case "w":
            return inClass ? "A-Za-z0-9_" : "[A-Za-z0-9_]"
        case "W":
            return inClass ? nil : "[^A-Za-z0-9_]"
        case "d":
            return inClass ? "0-9" : "[0-9]"
        case "D":
            return inClass ? nil : "[^0-9]"
        case "s":
            return inClass ? " \\t\\n\\r\\f\\v" : "[ \\t\\n\\r\\f\\v]"
        case "S":
            return inClass ? nil : "[^ \\t\\n\\r\\f\\v]"
        default:
            return nil
        }
    }

    private static func pcreConditionalAssertionSyntax(
        at index: String.Index,
        in pattern: String,
        asciiShorthandEscapes: Bool = false
    ) throws -> (pattern: String, end: String.Index)? {
        guard pattern[index...].hasPrefix("(?(") else {
            return nil
        }
        let assertionStart = pattern.index(index, offsetBy: 2)
        guard let assertion = pcreAssertionCondition(at: assertionStart, in: pattern),
              let branches = pcreConditionalBranches(from: assertion.end, in: pattern) else {
            return nil
        }
        let rawTrueBranch = String(pattern[assertion.end..<branches.separator])
        let rawFalseBranch = branches.falseBranchStart.map { String(pattern[$0..<branches.close]) } ?? ""
        let condition = try regexPatternExpandingPCREQuotedLiterals(
            assertion.body,
            asciiShorthandEscapes: asciiShorthandEscapes
        )
        let trueBranch = try regexPatternExpandingPCREQuotedLiterals(
            rawTrueBranch,
            asciiShorthandEscapes: asciiShorthandEscapes
        )
        let falseBranch = try regexPatternExpandingPCREQuotedLiterals(
            rawFalseBranch,
            asciiShorthandEscapes: asciiShorthandEscapes
        )
        return (
            "(?:\(assertion.truePrefix)\(condition))\(trueBranch)|\(assertion.falsePrefix)\(condition))\(falseBranch))",
            pattern.index(after: branches.close)
        )
    }

    private static func pcreAssertionCondition(
        at index: String.Index,
        in pattern: String
    ) -> (truePrefix: String, falsePrefix: String, body: String, end: String.Index)? {
        let prefixes: [(marker: String, truePrefix: String, falsePrefix: String)] = [
            ("(?=", "(?=", "(?!"),
            ("(?!", "(?!", "(?="),
            ("(?<=", "(?<=", "(?<!"),
            ("(?<!", "(?<!", "(?<="),
        ]
        guard let prefix = prefixes.first(where: { pattern[index...].hasPrefix($0.marker) }) else {
            return nil
        }
        let bodyStart = pattern.index(index, offsetBy: prefix.marker.count)
        guard let close = firstUnescapedClosingParen(in: pattern[bodyStart...]) else {
            return nil
        }
        return (
            prefix.truePrefix,
            prefix.falsePrefix,
            String(pattern[bodyStart..<close]),
            pattern.index(after: close)
        )
    }

    private static func pcreConditionalBranches(
        from start: String.Index,
        in pattern: String
    ) -> (separator: String.Index, falseBranchStart: String.Index?, close: String.Index)? {
        var escaped = false
        var inClass = false
        var depth = 0
        var separator: String.Index?
        var index = start
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character == "Q" {
                    var quotedIndex = pattern.index(after: index)
                    var closedQuote = false
                    while quotedIndex < pattern.endIndex {
                        if pattern[quotedIndex] == "\\" {
                            let quoteEscapeIndex = pattern.index(after: quotedIndex)
                            if quoteEscapeIndex < pattern.endIndex,
                               pattern[quoteEscapeIndex] == "E" {
                                index = pattern.index(after: quoteEscapeIndex)
                                closedQuote = true
                                break
                            }
                        }
                        quotedIndex = pattern.index(after: quotedIndex)
                    }
                    guard closedQuote else {
                        return nil
                    }
                    escaped = false
                    continue
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            } else if !inClass, character == "(" {
                depth += 1
            } else if !inClass, character == ")" {
                if depth == 0 {
                    let split = separator ?? index
                    let falseStart = separator.map { pattern.index(after: $0) }
                    return (split, falseStart, index)
                }
                depth -= 1
            } else if !inClass, character == "|", depth == 0, separator == nil {
                separator = index
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func pcreGBackreference(
        after marker: String.Index,
        in pattern: String,
        numericCaptureOffset: Int = 0,
        precedingCaptureCount: Int,
        totalCaptureCount: Int
    ) throws -> (pattern: String, end: String.Index)? {
        let payloadStart = pattern.index(after: marker)
        guard payloadStart < pattern.endIndex else {
            return nil
        }
        let opener = pattern[payloadStart]
        if opener == "{" || opener == "<" || opener == "'" {
            let closer: Character = opener == "{" ? "}" : opener == "<" ? ">" : "'"
            let nameStart = pattern.index(after: payloadStart)
            guard nameStart < pattern.endIndex,
                  let close = pattern[nameStart...].firstIndex(of: closer) else {
                return nil
            }
            let name = String(pattern[nameStart..<close])
            if let signed = signedIntegerPayload(name), signed.hasExplicitSign {
                let end = pattern.index(after: close)
                let groupIndex = try pcreRelativeBackreferenceGroupIndex(
                    relative: signed.value,
                    precedingCaptureCount: precedingCaptureCount,
                    totalCaptureCount: totalCaptureCount,
                    nameStart: nameStart,
                    end: end,
                    isBare: false,
                    in: pattern
                )
                return ("\\\(groupIndex + numericCaptureOffset)", end)
            }
            if opener == "{",
               name.allSatisfy(\.isNumber),
               Int(name) == 0 {
                throw pcreNonexistentBackreferenceError(end: pattern.index(after: close), in: pattern)
            }
            guard let replacement = pcreBackreferenceReplacement(
                for: name,
                numericCaptureOffset: numericCaptureOffset
            ) else {
                return nil
            }
            return (replacement, pattern.index(after: close))
        }

        guard opener.isNumber else {
            if opener != "+", opener != "-" {
                return nil
            }
            var index = pattern.index(after: payloadStart)
            while index < pattern.endIndex, pattern[index].isNumber {
                index = pattern.index(after: index)
            }
            guard index > pattern.index(after: payloadStart),
                  let signed = signedIntegerPayload(String(pattern[payloadStart..<index])),
                  signed.hasExplicitSign else {
                return nil
            }
            let groupIndex = try pcreRelativeBackreferenceGroupIndex(
                relative: signed.value,
                precedingCaptureCount: precedingCaptureCount,
                totalCaptureCount: totalCaptureCount,
                nameStart: payloadStart,
                end: index,
                isBare: true,
                in: pattern
            )
            return ("\\\(groupIndex + numericCaptureOffset)", index)
        }
        var digits = ""
        var index = payloadStart
        while index < pattern.endIndex, pattern[index].isNumber {
            digits.append(pattern[index])
            index = pattern.index(after: index)
        }
        guard let groupIndex = Int(digits) else {
            return nil
        }
        guard groupIndex > 0 else {
            throw pcreNonexistentBackreferenceError(end: index, in: pattern)
        }
        return ("\\\(groupIndex + numericCaptureOffset)", index)
    }

    private static func signedIntegerPayload(_ text: String) -> (value: Int, hasExplicitSign: Bool)? {
        guard let first = text.first else {
            return nil
        }
        let hasExplicitSign = first == "+" || first == "-"
        let digitStart = hasExplicitSign ? text.index(after: text.startIndex) : text.startIndex
        guard digitStart < text.endIndex,
              text[digitStart...].allSatisfy(\.isNumber),
              let value = Int(text) else {
            return nil
        }
        return (value, hasExplicitSign)
    }

    private static func relativeBackreferenceGroupIndex(
        relative: Int,
        precedingCaptureCount: Int,
        totalCaptureCount: Int
    ) -> Int? {
        guard relative != 0 else {
            return nil
        }
        let groupIndex = relative < 0
            ? precedingCaptureCount + relative + 1
            : precedingCaptureCount + relative
        guard groupIndex > 0, groupIndex <= totalCaptureCount else {
            return nil
        }
        return groupIndex
    }

    private static func pcreRelativeBackreferenceGroupIndex(
        relative: Int,
        precedingCaptureCount: Int,
        totalCaptureCount: Int,
        nameStart: String.Index,
        end: String.Index,
        isBare: Bool,
        in pattern: String
    ) throws -> Int {
        guard relative != 0 else {
            let offset = isBare
                ? pattern[..<end].utf8.count + 3
                : pattern[..<nameStart].utf8.count + 2
            throw RipgrepError.message(
                "PCRE2: error compiling pattern at offset \(offset): a relative value of zero is not allowed"
            )
        }
        guard let groupIndex = relativeBackreferenceGroupIndex(
            relative: relative,
            precedingCaptureCount: precedingCaptureCount,
            totalCaptureCount: totalCaptureCount
        ) else {
            if isBare || relative > 0 {
                throw pcreNonexistentBackreferenceError(end: end, in: pattern)
            }
            throw RipgrepError.message(
                "PCRE2: error compiling pattern at offset \(pattern[..<nameStart].utf8.count + 2): reference to non-existent subpattern"
            )
        }
        return groupIndex
    }

    private static func pcreNonexistentBackreferenceError(
        end: String.Index,
        in pattern: String
    ) -> RipgrepError {
        RipgrepError.message(
            "PCRE2: error compiling pattern at offset \(pattern[..<end].utf8.count + 3): reference to non-existent subpattern"
        )
    }

    private static func pcrePythonGroupSyntax(
        at index: String.Index,
        in pattern: String
    ) -> (pattern: String, end: String.Index)? {
        let question = pattern.index(after: index)
        guard question < pattern.endIndex, pattern[question] == "?" else {
            return nil
        }
        let marker = pattern.index(after: question)
        guard marker < pattern.endIndex, pattern[marker] == "P" else {
            return nil
        }
        let payloadStart = pattern.index(after: marker)
        guard payloadStart < pattern.endIndex else {
            return nil
        }
        if pattern[payloadStart] == "<" {
            let nameStart = pattern.index(after: payloadStart)
            guard nameStart < pattern.endIndex,
                  let close = pattern[nameStart...].firstIndex(of: ">") else {
                return nil
            }
            let name = String(pattern[nameStart..<close])
            guard isPCREGroupName(name) else {
                return nil
            }
            return ("(?<\(name)>", pattern.index(after: close))
        }
        if pattern[payloadStart] == "=" {
            let nameStart = pattern.index(after: payloadStart)
            guard nameStart < pattern.endIndex,
                  let close = pattern[nameStart...].firstIndex(of: ")") else {
                return nil
            }
            let name = String(pattern[nameStart..<close])
            guard isPCREGroupName(name) else {
                return nil
            }
            return ("\\k<\(name)>", pattern.index(after: close))
        }
        return nil
    }

    private static func pcreBackreferenceReplacement(
        for name: String,
        numericCaptureOffset: Int = 0
    ) -> String? {
        guard !name.isEmpty else {
            return nil
        }
        if name.allSatisfy(\.isNumber) {
            guard let groupIndex = Int(name) else {
                return nil
            }
            return "\\\(groupIndex + numericCaptureOffset)"
        }
        guard isPCREGroupName(name) else {
            return nil
        }
        return "\\k<\(name)>"
    }

    private static func isPCREGroupName(_ name: String) -> Bool {
        guard let first = name.first,
              first == "_" || first.isASCII && first.isLetter else {
            return false
        }
        return name.dropFirst().allSatisfy { character in
            character == "_" || character.isASCII && (character.isLetter || character.isNumber)
        }
    }
}

struct PCRE2Match {
    let range: Range<String.Index>
    let byteRange: Range<Int>
    let captures: [Range<String.Index>?]
    let namedCaptures: [String: Range<String.Index>]

    init(
        range: Range<String.Index>,
        byteRange: Range<Int>,
        captures: [Range<String.Index>?],
        namedCaptures: [String: Range<String.Index>] = [:]
    ) {
        self.range = range
        self.byteRange = byteRange
        self.captures = captures
        self.namedCaptures = namedCaptures
    }
}
