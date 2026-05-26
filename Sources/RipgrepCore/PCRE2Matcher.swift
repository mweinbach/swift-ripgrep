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
        case regex(NSRegularExpression)
        case byteUnit(ByteUnitPattern, unicodeStartOnly: Bool)
        case fixedPositiveLookbehind(prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)
        case fixedNegativeLookbehind(prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)
        case fixedPositiveLookahead(literal: [UInt8], suffix: [UInt8], caseInsensitiveASCII: Bool)
        case fixedNegativeLookahead(literal: [UInt8], suffix: [UInt8], caseInsensitiveASCII: Bool)
        case fixedLiteralBackreference(literal: [UInt8], captureRanges: [Range<Int>], caseInsensitiveASCII: Bool)
        case fixedAssertionConditional(
            condition: FixedAssertionCondition,
            trueLiteral: [UInt8],
            falseLiteral: [UInt8],
            caseInsensitiveASCII: Bool
        )
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

    init(pattern: String, options: RipgrepOptions) throws {
        self.source = pattern
        if let byteUnit = Self.byteUnitPattern(pattern) {
            self.matcher = .byteUnit(byteUnit, unicodeStartOnly: !options.noUnicode)
            return
        }

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
           let resetStart = Self.fixedLiteralResetStart(pattern) {
            self.matcher = .fixedPositiveLookbehind(
                prefix: Array(resetStart.prefix.utf8),
                literal: Array(resetStart.literal.utf8),
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

        var regexPattern = try Self.regexPatternExpandingPCREQuotedLiterals(
            pattern,
            asciiShorthandEscapes: options.noUnicode
        )
        if regexPattern.isEmpty {
            regexPattern = "(?:)"
        }
        do {
            self.matcher = .regex(try NSRegularExpression(pattern: regexPattern, options: regexOptions))
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
        case .byteUnit(let pattern, let unicodeStartOnly):
            return Self.byteUnitMatches(pattern: pattern, unicodeStartOnly: unicodeStartOnly, in: text)
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
        case .fixedAssertionConditional(let condition, let trueLiteral, let falseLiteral, let caseInsensitiveASCII):
            return Self.fixedAssertionConditionalMatches(
                condition: condition,
                trueLiteral: trueLiteral,
                falseLiteral: falseLiteral,
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
        guard let resetRange = firstUnescapedResetStart(in: pattern) else {
            return nil
        }
        let rawPrefix = String(pattern[..<resetRange.lowerBound])
        let rawLiteral = String(pattern[resetRange.upperBound...])
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

    private static func fixedLiteralBackreference(_ pattern: String) -> (literal: String, captureRanges: [Range<Int>])? {
        var groups: [(name: String?, literal: String)] = []
        var namedGroups: [String: Int] = [:]
        var captureRanges: [Range<Int>] = []
        var literal = ""
        var byteOffset = 0
        var index = pattern.startIndex

        while index < pattern.endIndex,
              let group = fixedLiteralCaptureGroup(at: index, in: pattern) {
            let groupByteCount = group.literal.utf8.count
            let groupNumber = groups.count + 1
            if let name = group.name {
                namedGroups[name] = groupNumber
            }
            groups.append((group.name, group.literal))
            captureRanges.append(byteOffset..<byteOffset + groupByteCount)
            literal += group.literal
            byteOffset += groupByteCount
            index = pattern.index(after: group.close)
        }

        guard !groups.isEmpty,
              index < pattern.endIndex,
              let reference = fixedBackreferenceIndex(
                at: index,
                in: pattern,
                namedGroups: namedGroups
              ),
              reference.end == pattern.endIndex,
              reference.groupIndex > 0,
              reference.groupIndex <= groups.count else {
            return nil
        }
        literal += groups[reference.groupIndex - 1].literal
        return (literal, captureRanges)
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
        namedGroups: [String: Int]
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
                return fixedGBackreferenceIndex(after: marker, in: pattern, namedGroups: namedGroups)
            }
            if pattern[marker] == "k" {
                return fixedDelimitedBackreferenceIndex(
                    after: marker,
                    in: pattern,
                    namedGroups: namedGroups
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
        namedGroups: [String: Int]
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
        return fixedDelimitedBackreferenceIndex(after: marker, in: pattern, namedGroups: namedGroups)
    }

    private static func fixedDelimitedBackreferenceIndex(
        after marker: String.Index,
        in pattern: String,
        namedGroups: [String: Int]
    ) -> (groupIndex: Int, end: String.Index)? {
        let payloadStart = pattern.index(after: marker)
        guard let identifier = delimitedPCREBackreferenceIdentifier(at: payloadStart, in: pattern) else {
            return nil
        }
        if identifier.name.allSatisfy(\.isNumber),
           let groupIndex = Int(identifier.name) {
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

    private static func firstUnescapedResetStart(in pattern: String) -> Range<String.Index>? {
        var escaped = false
        var escapeStart: String.Index?
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
                if character == "K", let escapeStart {
                    return escapeStart..<pattern.index(after: index)
                }
                escaped = false
                escapeStart = nil
            } else if character == "\\" {
                escaped = true
                escapeStart = index
            }
            index = pattern.index(after: index)
        }
        return nil
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

    private static func fixedAssertionConditionalMatches(
        condition: FixedAssertionCondition,
        trueLiteral: [UInt8],
        falseLiteral: [UInt8],
        caseInsensitiveASCII: Bool,
        in text: String
    ) -> [PCRE2Match] {
        #if canImport(CRipgrepPlatform)
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
        #else
        return []
        #endif
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

    private static func regexPatternExpandingPCREQuotedLiterals(
        _ pattern: String,
        asciiShorthandEscapes: Bool = false
    ) throws -> String {
        var output = ""
        var inClass = false
        var index = pattern.startIndex
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
                       pattern[marker] == "g",
                       let backreference = pcreGBackreference(after: marker, in: pattern) {
                        output += backreference.pattern
                        index = backreference.end
                        continue
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
        in pattern: String
    ) -> (pattern: String, end: String.Index)? {
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
            guard let replacement = pcreBackreferenceReplacement(for: name) else {
                return nil
            }
            return (replacement, pattern.index(after: close))
        }

        guard opener.isNumber else {
            return nil
        }
        var digits = ""
        var index = payloadStart
        while index < pattern.endIndex, pattern[index].isNumber {
            digits.append(pattern[index])
            index = pattern.index(after: index)
        }
        return ("\\\(digits)", index)
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

    private static func pcreBackreferenceReplacement(for name: String) -> String? {
        guard !name.isEmpty else {
            return nil
        }
        if name.allSatisfy(\.isNumber) {
            return "\\\(name)"
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
}
