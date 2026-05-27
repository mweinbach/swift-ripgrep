import Foundation

public struct PatternMatcher {
    private let options: RipgrepOptions
    private let patternSources: [String]
    private let patterns: [CompiledPattern]
    private let requiredLiteralPrefilters: [String]?
    private let byteLiteralFastPathCache: ByteLiteralFastPath?
    private let byteRequiredLiteralPrefilterCache: ByteLiteralFastPath?
    private let wordWhitespaceSequenceFastPathCache: WordWhitespaceSequenceFastPath?
    public let usesByteSemantics: Bool

    public init(options: RipgrepOptions) throws {
        let patternSources = options.effectivePatterns
        let usesByteSemantics = options.fixedStrings
            ? options.noUnicode
            : patternSources.contains { Self.regexUsesByteSemantics(pattern: $0, options: options) }
        let requiredLiteralPrefilters = Self.requiredLiteralPrefilters(
            for: patternSources,
            options: options,
            usesByteSemantics: usesByteSemantics
        )
        let wordWhitespaceSequenceFastPath = Self.makeWordWhitespaceSequenceFastPath(
            patterns: patternSources,
            options: options,
            usesByteSemantics: usesByteSemantics
        )

        let patterns = try patternSources.flatMap { pattern -> [CompiledPattern] in
            if options.wordRegexp && pattern.isEmpty {
                return [.emptyWordBoundary]
            }
            if options.fixedStrings {
                if !options.multiline,
                   !(options.nullData && !options.crlf),
                   pattern.contains("\n") {
                    throw RipgrepError.message(Self.lineTerminatorPatternError(terminator: "\\n"))
                }
                let literal = options.effectiveIgnoreCase ? Self.foldedCase(pattern, options: options) : pattern
                return [.literal(usesByteSemantics ? Self.bytePattern(literal) : literal)]
            } else {
                if !options.disablesBinaryDetection, Self.canMatchNUL(pattern) {
                    throw RipgrepError.message("""
                    pattern contains "\\0" but it is impossible to match

                    Consider enabling text mode with the --text flag (or -a for short). Otherwise,
                    binary detection is enabled and matching a NUL byte is impossible.
                    """)
                }
                if options.nullData && !options.multiline && Self.canMatchLineTerminator(pattern, terminator: "\0") {
                    throw RipgrepError.message(Self.lineTerminatorPatternError(terminator: "\\0"))
                }
                if !options.multiline,
                   !(options.nullData && !options.crlf),
                   Self.canMatchLineTerminator(pattern, terminator: "\n") {
                    throw RipgrepError.message(Self.lineTerminatorPatternError(terminator: "\\n"))
                }
                if options.engineMode == .pcre2 {
                    if let literals = Self.defaultLiteralPatterns(
                        for: pattern,
                        options: options,
                        allowPCREQuotedLiterals: true
                    ),
                       literals.count == 1 {
                        return literals.map { literal in
                            .literal(usesByteSemantics ? Self.bytePattern(literal) : literal)
                        }
                    }
                    return [.pcre2(try PCRE2CompiledPattern(pattern: pattern, options: options))]
                }
                if let unsupported = Self.defaultEngineUnsupportedFeature(in: pattern) {
                    if options.engineMode == .default {
                        throw RipgrepError.message(Self.defaultRegexParseError(pattern: pattern, feature: unsupported))
                    }
                    if let literals = Self.defaultLiteralPatterns(
                        for: pattern,
                        options: options,
                        allowPCREQuotedLiterals: true
                    ) {
                        return literals.map { literal in
                            .literal(usesByteSemantics ? Self.bytePattern(literal) : literal)
                        }
                    }
                    do {
                        return [.pcre2(try PCRE2CompiledPattern(pattern: pattern, options: options))]
                    } catch {
                        throw RipgrepError.message(Self.automaticEngineUnavailableMessage(
                            pattern: pattern,
                            feature: unsupported,
                            pcre2Error: String(describing: error)
                        ))
                    }
                }
                if let unicodeDiagnostic = Self.unicodeClassInNoUnicodeDiagnostic(
                    pattern,
                    unicodeEnabled: !options.noUnicode
                ) {
                    let message = options.engineMode == .automatic
                        ? Self.automaticEngineUnavailableMessage(
                            pattern: pattern,
                            feature: unicodeDiagnostic,
                            pcre2Error: "Unicode not allowed here"
                        )
                        : Self.defaultRegexParseError(pattern: pattern, feature: unicodeDiagnostic)
                    throw RipgrepError.message(message)
                }
                if let parseError = Self.defaultRegexParseErrorIfRecognized(pattern) {
                    throw RipgrepError.message(parseError)
                }
                if let literals = Self.defaultLiteralPatterns(for: pattern, options: options) {
                    return literals.map { literal in
                        .literal(usesByteSemantics ? Self.bytePattern(literal) : literal)
                    }
                }
                do {
                    return try Self.defaultCompiledPatterns(for: pattern, options: options)
                } catch let error as RipgrepError {
                    if options.engineMode == .automatic {
                        do {
                            return [.pcre2(try PCRE2CompiledPattern(pattern: pattern, options: options))]
                        } catch {
                            throw RipgrepError.message(Self.automaticEngineUnavailableMessage(
                                pattern: pattern,
                                defaultError: String(describing: error),
                                pcre2Error: String(describing: error)
                            ))
                        }
                    }
                    throw error
                } catch {
                    if options.engineMode == .automatic {
                        do {
                            return [.pcre2(try PCRE2CompiledPattern(pattern: pattern, options: options))]
                        } catch {
                            throw RipgrepError.message(Self.automaticEngineUnavailableMessage(
                                pattern: pattern,
                                defaultError: error.localizedDescription,
                                pcre2Error: String(describing: error)
                            ))
                        }
                    }
                    throw RipgrepError.invalidRegex(error.localizedDescription)
                }
            }
        }

        self.options = options
        self.patternSources = patternSources
        self.usesByteSemantics = usesByteSemantics
        self.requiredLiteralPrefilters = requiredLiteralPrefilters
        self.patterns = patterns
        self.byteLiteralFastPathCache = Self.makeByteLiteralFastPath(
            patterns: patterns,
            options: options,
            usesByteSemantics: usesByteSemantics
        )
        self.byteRequiredLiteralPrefilterCache = Self.makeByteRequiredLiteralPrefilter(
            requiredLiteralPrefilters: requiredLiteralPrefilters,
            options: options,
            usesByteSemantics: usesByteSemantics
        )
        self.wordWhitespaceSequenceFastPathCache = wordWhitespaceSequenceFastPath
    }

    private static func lineTerminatorPatternError(terminator: String) -> String {
        """
        the literal "\(terminator)" is not allowed in a regex

        Consider enabling multiline mode with the --multiline flag (or -U for short).
        When multiline mode is enabled, new line characters can be matched.
        """
    }

    private static func canMatchNUL(_ pattern: String) -> Bool {
        if pattern.contains("\0") {
            return true
        }

        var escaped = false
        var inClass = false
        var classNegated = false
        var classContentStarted = false
        var escapeStart: String.Index?
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                let escapeEnd = escapeStart.flatMap { regexEscapeEnd(in: pattern, backslashAt: $0) }
                let matchesNUL: Bool
                if character == "0" {
                    matchesNUL = true
                } else if character == "x" {
                    let next = pattern.index(after: index)
                    let remainder = pattern[next...].lowercased()
                    matchesNUL = remainder.hasPrefix("00") || bracedHexEscapeValue(in: remainder) == 0
                } else if character == "u" {
                    let next = pattern.index(after: index)
                    let remainder = pattern[next...].lowercased()
                    matchesNUL = remainder.hasPrefix("0000") || bracedHexEscapeValue(in: remainder) == 0
                } else {
                    matchesNUL = false
                }
                if matchesNUL && (!inClass || !classNegated) {
                    return true
                }
                if inClass {
                    classContentStarted = true
                }
                escaped = false
                escapeStart = nil
                index = escapeEnd ?? pattern.index(after: index)
                continue
            }
            if inClass {
                if character == "^", classNegated, !classContentStarted {
                    index = pattern.index(after: index)
                    continue
                }
                if character == "]", classContentStarted {
                    inClass = false
                    classNegated = false
                    classContentStarted = false
                    index = pattern.index(after: index)
                    continue
                }
                if character == "\\" {
                    escaped = true
                    escapeStart = index
                    index = pattern.index(after: index)
                    continue
                }
                classContentStarted = true
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                escapeStart = index
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                let next = pattern.index(after: index)
                inClass = true
                classNegated = next < pattern.endIndex && pattern[next] == "^"
                classContentStarted = false
            }
            index = pattern.index(after: index)
        }
        return false
    }

    private static func canMatchLineTerminator(_ pattern: String, terminator: Character) -> Bool {
        let terminatorValue: UInt32 = terminator == "\0" ? 0x00 : 0x0A
        var escaped = false
        var inClass = false
        var classNegated = false
        var classContentStarted = false
        var classHasLineTerminator = false
        var classHasOther = false
        var escapeStart: String.Index?
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                let escapeEnd = escapeStart.flatMap { regexEscapeEnd(in: pattern, backslashAt: $0) }
                let matchesLineTerminator: Bool
                if terminator == "\n", character == "n" {
                    matchesLineTerminator = true
                } else if terminator == "\0", character == "0" {
                    matchesLineTerminator = true
                } else if character == "x" {
                    let next = pattern.index(after: index)
                    let remainder = pattern[next...].lowercased()
                    matchesLineTerminator = remainder.hasPrefix(String(format: "%02x", terminatorValue))
                        || bracedHexEscapeValue(in: remainder) == terminatorValue
                } else if character == "u" {
                    let next = pattern.index(after: index)
                    let remainder = pattern[next...].lowercased()
                    matchesLineTerminator = remainder.hasPrefix(String(format: "%04x", terminatorValue))
                        || bracedHexEscapeValue(in: remainder) == terminatorValue
                } else {
                    matchesLineTerminator = false
                }
                if inClass {
                    classContentStarted = true
                    if matchesLineTerminator {
                        classHasLineTerminator = true
                    } else {
                        classHasOther = true
                    }
                } else if matchesLineTerminator {
                    return true
                }
                escaped = false
                escapeStart = nil
                index = escapeEnd ?? pattern.index(after: index)
                continue
            }
            if character == terminator && !inClass {
                return true
            }
            if character == "\\" {
                escaped = true
                escapeStart = index
                index = pattern.index(after: index)
                continue
            }
            if inClass {
                if character == "^", classNegated, !classContentStarted {
                    index = pattern.index(after: index)
                    continue
                }
                if character == "]", classContentStarted {
                    if !classNegated && classHasLineTerminator && !classHasOther {
                        return true
                    }
                    inClass = false
                    classNegated = false
                    classContentStarted = false
                    classHasLineTerminator = false
                    classHasOther = false
                    index = pattern.index(after: index)
                    continue
                }
                classContentStarted = true
                if character == terminator {
                    classHasLineTerminator = true
                } else {
                    classHasOther = true
                }
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                let next = pattern.index(after: index)
                inClass = true
                classNegated = next < pattern.endIndex && pattern[next] == "^"
                classContentStarted = false
                classHasLineTerminator = false
                classHasOther = false
            }
            index = pattern.index(after: index)
        }
        if inClass, !classNegated, classHasLineTerminator, !classHasOther {
            return true
        }
        return false
    }

    static func replacementSuppressionPatternCanMatchLineTerminator(
        _ pattern: String,
        options: RipgrepOptions
    ) -> Bool {
        let terminatorValue: UInt32 = options.nullData ? 0x00 : 0x0A
        if options.fixedStrings {
            return pattern.unicodeScalars.contains { $0.value == terminatorValue }
        }

        var source = foundationAnyClassPattern(for: pattern)
        source = scalarDotAllWildcardPattern(for: source, options: options)
        source = binaryWildcardPattern(for: source, options: options)
        source = foundationScalarEscapePattern(for: source)
        source = negatedASCIIPosixClasses(for: source)
        source = asciiPOSIXClasses(for: source)
        return regexSourceCanMatchLineTerminator(source, terminatorValue: terminatorValue)
    }

    private static func regexSourceCanMatchLineTerminator(
        _ pattern: String,
        terminatorValue: UInt32
    ) -> Bool {
        var escaped = false
        var inClass = false
        var classNegated = false
        var classContentStarted = false
        var classHasTerminator = false
        var escapeStart: String.Index?
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                let escapeEnd = escapeStart.flatMap { regexEscapeEnd(in: pattern, backslashAt: $0) }
                let matchesTerminator = regexEscapeCanMatchLineTerminator(
                    character,
                    in: pattern,
                    at: index,
                    terminatorValue: terminatorValue
                )
                if inClass {
                    classContentStarted = true
                    classHasTerminator = classHasTerminator || matchesTerminator
                } else if matchesTerminator {
                    return true
                }
                escaped = false
                escapeStart = nil
                index = escapeEnd ?? pattern.index(after: index)
                continue
            }

            if character == "\\" {
                escaped = true
                escapeStart = index
                index = pattern.index(after: index)
                continue
            }

            if inClass {
                if character == "^", classNegated, !classContentStarted {
                    index = pattern.index(after: index)
                    continue
                }
                if character == "]", classContentStarted {
                    if classNegated ? !classHasTerminator : classHasTerminator {
                        return true
                    }
                    inClass = false
                    classNegated = false
                    classContentStarted = false
                    classHasTerminator = false
                    index = pattern.index(after: index)
                    continue
                }
                classContentStarted = true
                classHasTerminator = classHasTerminator || character.unicodeScalars.contains {
                    $0.value == terminatorValue
                }
                index = pattern.index(after: index)
                continue
            }

            if character == "[" {
                let next = pattern.index(after: index)
                inClass = true
                classNegated = next < pattern.endIndex && pattern[next] == "^"
                classContentStarted = false
                classHasTerminator = false
                index = next
                continue
            }

            if character.unicodeScalars.contains(where: { $0.value == terminatorValue }) {
                return true
            }
            index = pattern.index(after: index)
        }

        return inClass && (classNegated ? !classHasTerminator : classHasTerminator)
    }

    private static func regexEscapeCanMatchLineTerminator(
        _ character: Character,
        in pattern: String,
        at index: String.Index,
        terminatorValue: UInt32
    ) -> Bool {
        if character == "n" {
            return terminatorValue == 0x0A
        }
        if character == "0" {
            return terminatorValue == 0x00
        }
        if character == "s" {
            return terminatorValue == 0x0A
        }
        if character == "p" {
            let propertyStart = pattern.index(after: index)
            return pattern[propertyStart...].hasPrefix("{Any}")
        }
        if character == "x" || character == "u" {
            let next = pattern.index(after: index)
            let remainder = pattern[next...].lowercased()
            let width = character == "x" ? 2 : 4
            if remainder.hasPrefix(String(format: "%0\(width)x", terminatorValue)) {
                return true
            }
            return bracedHexEscapeValue(in: remainder) == terminatorValue
        }
        return false
    }

    private static func bracedHexEscapeValue(in remainder: String) -> UInt32? {
        guard remainder.first == "{",
              let close = remainder.firstIndex(of: "}") else {
            return nil
        }
        let hexStart = remainder.index(after: remainder.startIndex)
        guard hexStart < close else {
            return nil
        }
        return UInt32(remainder[hexStart..<close], radix: 16)
    }

    public func matches(in line: String) -> [Range<String.Index>] {
        spans(in: line).compactMap { span in
            indexRange(for: span, in: line)
        }
    }

    public func hasPositiveMatch(in line: String) -> Bool {
        !filteredCandidates(in: line).isEmpty
    }

    public func canFastReject(_ line: String) -> Bool {
        let literals = patterns.compactMap { pattern -> String? in
            guard case .literal(let literal) = pattern, !literal.isEmpty else {
                return nil
            }
            return literal
        }
        guard literals.count == patterns.count else {
            if let requiredLiteralPrefilters {
                return !requiredLiteralPrefilters.contains { literalContains($0, in: line) }
            }
            return false
        }
        return !literals.contains { literalContains($0, in: line) }
    }

    func byteLiteralFastPath() -> ByteLiteralFastPath? {
        return byteLiteralFastPathCache
    }

    func byteRequiredLiteralPrefilter() -> ByteLiteralFastPath? {
        return byteRequiredLiteralPrefilterCache
    }

    func wordWhitespaceSequenceFastPath() -> WordWhitespaceSequenceFastPath? {
        return wordWhitespaceSequenceFastPathCache
    }

    func fixedPositiveLookbehindFastPath() -> (prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)? {
        guard patterns.count == 1,
              case .pcre2(let regex) = patterns[0] else {
            return nil
        }
        return regex.fixedPositiveLookbehindFastPath
    }

    func fixedPositiveLookaheadFastPath() -> (literal: [UInt8], suffix: [UInt8], caseInsensitiveASCII: Bool)? {
        guard patterns.count == 1,
              case .pcre2(let regex) = patterns[0] else {
            return nil
        }
        return regex.fixedPositiveLookaheadFastPath
    }

    func fixedNegativeLookbehindFastPath() -> (prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)? {
        guard patterns.count == 1,
              case .pcre2(let regex) = patterns[0] else {
            return nil
        }
        return regex.fixedNegativeLookbehindFastPath
    }

    func fixedNegativeLookaheadFastPath() -> (literal: [UInt8], suffix: [UInt8], caseInsensitiveASCII: Bool)? {
        guard patterns.count == 1,
              case .pcre2(let regex) = patterns[0] else {
            return nil
        }
        return regex.fixedNegativeLookaheadFastPath
    }

    func fixedResetStartFastPath() -> (prefix: [UInt8], literal: [UInt8], caseInsensitiveASCII: Bool)? {
        guard patterns.count == 1,
              case .pcre2(let regex) = patterns[0] else {
            return nil
        }
        return regex.fixedResetStartFastPath
    }

    func bareResetStartFastPath() -> Bool {
        guard patterns.count == 1,
              case .pcre2(let regex) = patterns[0] else {
            return false
        }
        return regex.bareResetStartFastPath
    }

    func fixedLiteralBackreferenceFastPath() -> (literal: [UInt8], caseInsensitiveASCII: Bool)? {
        guard patterns.count == 1,
              case .pcre2(let regex) = patterns[0] else {
            return nil
        }
        return regex.fixedLiteralBackreferenceFastPath
    }

    func fixedAssertionConditionalFastPath() -> (
        condition: PCRE2CompiledPattern.FixedAssertionCondition,
        trueLiteral: [UInt8],
        falseLiteral: [UInt8],
        caseInsensitiveASCII: Bool
    )? {
        guard patterns.count == 1,
              case .pcre2(let regex) = patterns[0] else {
            return nil
        }
        return regex.fixedAssertionConditionalFastPath
    }

    func byteUnitFastPath() -> (
        pattern: PCRE2CompiledPattern.ByteUnitPattern,
        unicodeStartOnly: Bool
    )? {
        guard patterns.count == 1,
              case .pcre2(let regex) = patterns[0] else {
            return nil
        }
        return regex.byteUnitFastPath
    }

    private static func makeByteLiteralFastPath(
        patterns: [CompiledPattern],
        options: RipgrepOptions,
        usesByteSemantics: Bool
    ) -> ByteLiteralFastPath? {
        guard !options.lineRegexp,
              !options.invertMatch,
              !options.multiline,
              !options.nullData,
              !usesByteSemantics else {
            return nil
        }
        let literals = patterns.compactMap { pattern -> String? in
            guard case .literal(let literal) = pattern, !literal.isEmpty else {
                return nil
            }
            return literal
        }
        guard literals.count == patterns.count else {
            return nil
        }
        guard (!options.effectiveIgnoreCase && !options.wordRegexp)
                || literals.allSatisfy({ $0.utf8.allSatisfy(\.isASCII) }) else {
            return nil
        }
        return ByteLiteralFastPath(
            literals: literals.map { Array($0.utf8) },
            caseInsensitiveASCII: options.effectiveIgnoreCase,
            wordASCII: options.wordRegexp
        )
    }

    private static func makeWordWhitespaceSequenceFastPath(
        patterns: [String],
        options: RipgrepOptions,
        usesByteSemantics: Bool
    ) -> WordWhitespaceSequenceFastPath? {
        guard patterns.count == 1,
              !options.fixedStrings,
              !options.multiline,
              !options.nullData,
              !options.crlf,
              !options.wordRegexp,
              !options.lineRegexp else {
            return nil
        }

        let pattern = patterns[0]
        let unscopedPattern = pattern.hasPrefix("(?-u)")
            ? String(pattern.dropFirst("(?-u)".count))
            : pattern
        guard let groupCount = wordWhitespaceSequenceGroupCount(in: unscopedPattern) else {
            return nil
        }
        return WordWhitespaceSequenceFastPath(asciiOnly: usesByteSemantics, groupCount: groupCount)
    }

    private static func wordWhitespaceSequenceGroupCount(in pattern: String) -> Int? {
        let wordGroup = #"\w{5}"#
        let separator = #"\s+"#
        var remainder = pattern[...]
        var groupCount = 0
        while true {
            guard remainder.hasPrefix(wordGroup) else {
                return nil
            }
            groupCount += 1
            remainder.removeFirst(wordGroup.count)
            if remainder.isEmpty {
                return groupCount >= 2 ? groupCount : nil
            }
            guard remainder.hasPrefix(separator) else {
                return nil
            }
            remainder.removeFirst(separator.count)
        }
    }

    private static func makeByteRequiredLiteralPrefilter(
        requiredLiteralPrefilters: [String]?,
        options: RipgrepOptions,
        usesByteSemantics: Bool
    ) -> ByteLiteralFastPath? {
        guard !options.effectiveIgnoreCase,
              !options.fixedStrings,
              !options.lineRegexp,
              !options.invertMatch,
              !options.multiline,
              !options.nullData,
              !usesByteSemantics,
              let requiredLiteralPrefilters,
              !requiredLiteralPrefilters.isEmpty,
              requiredLiteralPrefilters.allSatisfy({ $0.utf8.allSatisfy(\.isASCII) }) else {
            return nil
        }
        return ByteLiteralFastPath(
            literals: requiredLiteralPrefilters.map { Array($0.utf8) },
            caseInsensitiveASCII: false,
            wordASCII: false
        )
    }

    public func positiveSpans(in line: String) -> [MatchSpan] {
        matchSpans(from: filteredCandidates(in: line), in: line)
    }

    public func syntheticEmptyReplacement(atEndOf line: String) -> String? {
        replacement(for: line.endIndex..<line.endIndex, in: line)
    }

    public func spans(in line: String) -> [MatchSpan] {
        let filtered = filteredCandidates(in: line)

        if options.invertMatch {
            return filtered.isEmpty ? [
                MatchSpan(startColumn: 1, endColumn: 1, startByte: 0, endByte: 0, text: "", replacement: nil),
            ] : []
        }

        return matchSpans(from: filtered, in: line)
    }

    private func matchSpans(
        from candidates: [(range: Range<String.Index>, replacement: String?)],
        in line: String
    ) -> [MatchSpan] {
        let spans = internalUTF8EmptyMatches(
            in: Self.dropAdjacentEmptyMatches(afterNonEmpty: candidates),
            line: line
        )
            .sorted { lhs, rhs in
                let lhsStart = lhs.byteOffset ?? line[..<lhs.range.lowerBound].utf8.count
                let rhsStart = rhs.byteOffset ?? line[..<rhs.range.lowerBound].utf8.count
                if lhsStart == rhsStart {
                    let lhsEnd = lhs.byteOffset ?? line[..<lhs.range.upperBound].utf8.count
                    let rhsEnd = rhs.byteOffset ?? line[..<rhs.range.upperBound].utf8.count
                    return lhsEnd < rhsEnd
                }
                return lhsStart < rhsStart
            }
            .map { candidate in
                let startByte = candidate.byteOffset ?? byteOffset(for: candidate.range.lowerBound, in: line)
                let endByte = candidate.byteOffset ?? byteOffset(for: candidate.range.upperBound, in: line)
                let startColumn = candidate.column ?? column(for: candidate.range.lowerBound, in: line)
                let endColumn = candidate.column ?? column(for: candidate.range.upperBound, in: line)
                return MatchSpan(
                    startColumn: startColumn,
                    endColumn: endColumn,
                    startByte: startByte,
                    endByte: endByte,
                    text: String(line[candidate.range]),
                    replacement: candidate.replacement
                )
            }
        return deduplicated(spans)
    }

    private func deduplicated(_ spans: [MatchSpan]) -> [MatchSpan] {
        var seen: Set<MatchSpanIdentity> = []
        var output: [MatchSpan] = []
        for span in spans {
            let identity = MatchSpanIdentity(span)
            if seen.insert(identity).inserted {
                output.append(span)
            }
        }
        return output
    }

    private func internalUTF8EmptyMatches(
        in candidates: [(range: Range<String.Index>, replacement: String?)],
        line: String
    ) -> [(range: Range<String.Index>, replacement: String?, byteOffset: Int?, column: Int?)] {
        var output: [(range: Range<String.Index>, replacement: String?, byteOffset: Int?, column: Int?)] = candidates.map {
            ($0.range, $0.replacement, nil, nil)
        }
        guard !usesByteSemantics,
              !options.effectivePatterns.allSatisfy(Self.suppressesInternalUTF8EmptyMatches) else {
            return output
        }
        for candidate in candidates where candidate.range.isEmpty && candidate.range.lowerBound < line.endIndex {
            let character = line[candidate.range.lowerBound]
            guard character.unicodeScalars.count == 1 else {
                continue
            }
            let width = character.utf8.count
            guard width > 1 else {
                continue
            }
            let startByte = line[..<candidate.range.lowerBound].utf8.count
            let startColumn = line.distance(from: line.startIndex, to: candidate.range.lowerBound) + 1
            for offset in 1..<width {
                output.append((
                    candidate.range,
                    candidate.replacement,
                    startByte + offset,
                    startColumn + offset
                ))
            }
        }
        return output
    }

    private func filteredCandidates(in line: String) -> [(range: Range<String.Index>, replacement: String?)] {
        var candidates: [(range: Range<String.Index>, replacement: String?)] = []
        for pattern in patterns {
            switch pattern {
            case .emptyWordBoundary:
                candidates.append(contentsOf: emptyWordBoundaryRanges(in: line).map { range in
                    (range, replacement(for: range, in: line))
                })
            case .regex(let regex):
                let matches = regex.matches(
                    in: line,
                    range: NSRange(line.startIndex..., in: line)
                )
                candidates.append(contentsOf: matches.compactMap { match in
                    guard let range = Range(match.range, in: line) else {
                        return nil
                    }
                    let replacement = replacement(for: match, in: line)
                    return (range, replacement)
                })
            case .pcre2(let regex):
                candidates.append(contentsOf: regex.matches(in: line).map { match in
                    (match.range, replacement(for: match, in: line))
                })
            case .literal(let literal):
                candidates.append(contentsOf: literalRanges(literal, in: line).map { range in
                    (range, replacement(for: range, in: line))
                })
            }
        }
        if shouldAddBareCRLineEndNotWordBoundary(in: line) {
            let range = line.endIndex..<line.endIndex
            candidates.append((range, replacement(for: range, in: line)))
        }
        if shouldSuppressBareWordBoundaryPattern {
            return []
        }

        return candidates.filter { candidate in
            !shouldDropBareCRLineEndWordBoundary(candidate.range, in: line)
                && (!options.wordRegexp || isWordBounded(candidate.range, in: line))
                && (!options.lineRegexp || isLineRegexpBounded(candidate.range, in: line))
                && !shouldDropTrailingMultilineEmptySpan(candidate.range, in: line)
        }
    }

    private var shouldSuppressBareWordBoundaryPattern: Bool {
        options.wordRegexp
            && !patternSources.isEmpty
            && patternSources.allSatisfy { $0 == "\\b" }
    }

    private func shouldDropBareCRLineEndWordBoundary(_ range: Range<String.Index>, in line: String) -> Bool {
        options.wordRegexp
            && !options.crlf
            && !options.multiline
            && !options.nullData
            && line.hasSuffix("\r")
            && range.isEmpty
            && range.lowerBound == line.endIndex
            && patternSources.allSatisfy { $0 == "\\b" }
    }

    private func shouldAddBareCRLineEndNotWordBoundary(in line: String) -> Bool {
        options.wordRegexp
            && !options.crlf
            && !options.multiline
            && !options.nullData
            && line.hasSuffix("\r")
            && patternSources.allSatisfy { $0 == "\\B" }
    }

    private static func dropAdjacentEmptyMatches(
        afterNonEmpty candidates: [(range: Range<String.Index>, replacement: String?)]
    ) -> [(range: Range<String.Index>, replacement: String?)] {
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.range.lowerBound == rhs.range.lowerBound {
                return lhs.range.upperBound < rhs.range.upperBound
            }
            return lhs.range.lowerBound < rhs.range.lowerBound
        }
        var output: [(range: Range<String.Index>, replacement: String?)] = []
        for candidate in sorted {
            if candidate.range.isEmpty,
               let previous = output.last,
               previous.range.isEmpty,
               previous.range.lowerBound == candidate.range.lowerBound {
                continue
            }
            if candidate.range.isEmpty,
               let previous = output.last,
               !previous.range.isEmpty,
               previous.range.upperBound == candidate.range.lowerBound {
                continue
            }
            output.append(candidate)
        }
        return output
    }

    private func shouldDropTrailingMultilineEmptySpan(_ range: Range<String.Index>, in line: String) -> Bool {
        guard options.multiline,
              !line.isEmpty,
              range.isEmpty,
              range.lowerBound == line.endIndex else {
            return false
        }
        if options.effectivePatterns.allSatisfy(Self.isEndAssertionPattern),
           !line.contains("\n"),
           !line.contains("\0") {
            return false
        }
        return true
    }

    private static func isEndAssertionPattern(_ pattern: String) -> Bool {
        switch pattern {
        case "$", "\\z":
            return true
        default:
            return unwrappedSingleGroupPattern(pattern).map(isEndAssertionPattern) ?? false
        }
    }

    private static func suppressesInternalUTF8EmptyMatches(_ pattern: String) -> Bool {
        if pattern.contains("|") {
            return pattern.split(separator: "|", omittingEmptySubsequences: false).allSatisfy {
                suppressesInternalUTF8EmptyMatches(String($0))
            }
        }
        switch pattern {
        case "^", "$", "\\A", "\\z", "\\b", "\\B":
            return true
        default:
            return unwrappedSingleGroupPattern(pattern).map(suppressesInternalUTF8EmptyMatches) ?? false
        }
    }

    private static func isAbsoluteStartAssertionPattern(_ pattern: String) -> Bool {
        switch pattern {
        case "\\A":
            return true
        default:
            return unwrappedSingleGroupPattern(pattern).map(isAbsoluteStartAssertionPattern) ?? false
        }
    }

    private static func unwrappedSingleGroupPattern(_ pattern: String) -> String? {
        for prefix in ["(?:", "(?m:", "(?-m:"] where pattern.hasPrefix(prefix) && pattern.hasSuffix(")") {
            let start = pattern.index(pattern.startIndex, offsetBy: prefix.count)
            return String(pattern[start..<pattern.index(before: pattern.endIndex)])
        }
        return nil
    }

    private static func defaultCompiledPatterns(for pattern: String, options: RipgrepOptions) throws -> [CompiledPattern] {
        let sources = Self.regexPatterns(for: pattern, options: options)
        return try sources.map { source in
            try enforceRegexSizeLimit(source: source, options: options)
            try enforceDFASizeLimit(source: source, options: options)
            var regexOptions: NSRegularExpression.Options = []
            if (options.multiline && !options.crlf) || (options.nullData && !options.crlf) {
                regexOptions.insert(.anchorsMatchLines)
            }
            if options.multiline && options.multilineDotall {
                regexOptions.insert(.dotMatchesLineSeparators)
            }
            return .regex(try NSRegularExpression(
                pattern: source,
                options: regexOptions
            ))
        }
    }

    private static func defaultLiteralPatterns(
        for pattern: String,
        options: RipgrepOptions,
        allowPCREQuotedLiterals: Bool = false
    ) -> [String]? {
        guard !pattern.isEmpty,
              !options.multiline,
              !options.nullData,
              !options.crlf,
              options.regexSizeLimit == nil,
              options.dfaSizeLimit == nil else {
            return nil
        }
        if let literal = RegexLiteralParser.literal(
            fromPlainRegexPattern: pattern,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
        ) {
            return [options.effectiveIgnoreCase ? foldedCase(literal, options: options) : literal]
        }
        let alternatives = topLevelAlternatives(in: pattern)
        let literals = alternatives.compactMap {
            RegexLiteralParser.literal(
                fromPlainRegexPattern: $0,
                allowPCREQuotedLiterals: allowPCREQuotedLiterals
            )
        }
        guard literals.count == alternatives.count else {
            return nil
        }
        return literals.map {
            options.effectiveIgnoreCase ? foldedCase($0, options: options) : $0
        }
    }

    private static func requiredLiteralPrefilters(
        for patterns: [String],
        options: RipgrepOptions,
        usesByteSemantics: Bool
    ) -> [String]? {
        guard !options.fixedStrings,
              !options.multiline,
              !options.nullData,
              !options.crlf,
              !usesByteSemantics else {
            return nil
        }
        let literals = patterns.compactMap {
            requiredLiteralPrefilter(for: $0, options: options, usesByteSemantics: usesByteSemantics)
        }
        return literals.count == patterns.count ? literals : nil
    }

    private static func requiredLiteralPrefilter(
        for pattern: String,
        options: RipgrepOptions,
        usesByteSemantics: Bool
    ) -> String? {
        if options.engineMode != .default,
           let literal = PCRE2CompiledPattern.fixedPositiveLookaroundLiteral(pattern) {
            let folded = options.effectiveIgnoreCase ? foldedCase(literal, options: options) : literal
            return usesByteSemantics ? bytePattern(folded) : folded
        }
        guard !pattern.isEmpty,
              topLevelAlternatives(in: pattern).count == 1,
              !pattern.contains("("),
              !pattern.contains(")"),
              !pattern.contains(#"\x"#),
              !pattern.contains(#"\u"#) else {
            return nil
        }

        var runs: [String] = []
        var current = ""
        var escaped = false
        var inClass = false
        var index = pattern.startIndex

        func flushRun(next: Character? = nil) {
            var run = current
            if let next, "?*{+".contains(next), !run.isEmpty {
                run.removeLast()
            }
            if run.count >= 3 {
                runs.append(run)
            }
            current.removeAll(keepingCapacity: true)
        }

        while index < pattern.endIndex {
            let character = pattern[index]
            let nextIndex = pattern.index(after: index)
            let next = nextIndex < pattern.endIndex ? pattern[nextIndex] : nil

            if escaped {
                flushRun(next: character)
                escaped = false
                index = nextIndex
                continue
            }

            if inClass {
                if character == "]" {
                    inClass = false
                }
                index = nextIndex
                continue
            }

            if character == "\\" {
                flushRun(next: next)
                escaped = true
            } else if character == "[" {
                flushRun(next: next)
                inClass = true
            } else if ".^$|()".contains(character) {
                flushRun(next: next)
            } else if "?*{+".contains(character) {
                flushRun(next: character)
            } else {
                current.append(character)
            }
            index = nextIndex
        }
        flushRun()

        guard let literal = runs.max(by: { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count < rhs.count
        }) else {
            return nil
        }
        let folded = options.effectiveIgnoreCase ? foldedCase(literal, options: options) : literal
        return usesByteSemantics ? bytePattern(folded) : folded
    }

    private static func enforceRegexSizeLimit(source: String, options: RipgrepOptions) throws {
        guard let limit = options.regexSizeLimit else {
            return
        }
        let estimate = UInt64(source.utf8.count + regexSizeWeight(for: source))
        if estimate > limit {
            throw RipgrepError.message("compiled regex exceeds size limit of \(limit)")
        }
    }

    private static func enforceDFASizeLimit(source: String, options: RipgrepOptions) throws {
        guard let limit = options.dfaSizeLimit, limit > 0 else {
            return
        }
        let estimate = UInt64(source.utf8.count + source.filter { "|[]{}()+*?".contains($0) }.count * 8)
        if estimate > limit * 64 {
            throw RipgrepError.message("dfa size limit exceeded")
        }
    }

    private static func regexSizeWeight(for source: String) -> Int {
        var weight = 1
        var escaped = false
        for character in source {
            if escaped {
                switch character {
                case "p", "P":
                    weight += 16
                case "d", "D", "s", "S", "w", "W":
                    weight += 16_384
                default:
                    weight += 2
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if "[]{}()+*?|".contains(character) {
                weight += 8
            }
        }
        return weight
    }

    private static func regexPatterns(for pattern: String, options: RipgrepOptions) -> [String] {
        let alternatives = topLevelAlternatives(in: pattern)
        if alternatives.count > 1,
           alternatives.contains(where: isAbsoluteStartAssertionPattern) {
            return alternatives.map { regexPattern(for: $0, options: options) }
        }
        return [regexPattern(for: pattern, options: options)]
    }

    private static func regexPattern(for pattern: String, options: RipgrepOptions) -> String {
        let usesByteSemantics = regexUsesByteSemantics(pattern: pattern, options: options)
        var source = foundationNamedCapturePattern(for: pattern)
        source = foundationAnyClassPattern(for: source)
        source = scalarDotAllWildcardPattern(for: source, options: options)
        source = binaryWildcardPattern(for: source, options: options)
        source = foundationUnicodePropertyShorthandPattern(for: source)
        source = foundationScalarEscapePattern(for: source)
        source = negatedASCIIPosixClasses(for: source)
        source = asciiPOSIXClasses(for: source)
        if source == ")(" {
            source = ""
        }
        let inlineCRLF = inlineCRLFPattern(for: source)
        source = inlineCRLF.pattern
        if source.isEmpty {
            source = "(?:)"
        }
        if !usesByteSemantics {
            source = scopedByteRegexPattern(
                for: source,
                defaultUnicodeEnabled: !options.noUnicode,
                caseInsensitive: options.effectiveIgnoreCase
            )
        }
        if usesByteSemantics {
            source = asciiRegexPattern(for: source)
        }
        if usesByteSemantics && options.effectiveIgnoreCase {
            source = asciiCaseInsensitivePattern(for: source)
        }
        if usesByteSemantics {
            source = byteRegexLiteralPattern(for: source)
        }
        if options.wordRegexp {
            source = wordRegexpPattern(for: source, usesByteSemantics: options.noUnicode)
        }
        if options.lineRegexp && !options.multiline {
            source = "^(?:\(source))$"
        }
        if options.crlf && options.multiline {
            source = multilineCRLFAnchorPattern(for: source)
        } else if options.crlf {
            source = crlfAnchorPattern(for: source)
        } else if inlineCRLF.enablesGlobalCRLF {
            source = inlineCRLFAnchorPattern(for: source)
        } else if options.multiline {
            source = multilineLineEndPattern(for: source)
        } else if options.nullData && !options.multiline {
            source = nullDataAnchorPattern(for: source)
        } else if !options.multiline && !options.nullData {
            source = strictLineEndPattern(for: source)
        }
        return source
    }

    private static func regexUsesByteSemantics(pattern: String, options: RipgrepOptions) -> Bool {
        if hasPCREByteUnitEscape(pattern) {
            return true
        }
        if options.noUnicode {
            return !wholePatternUnicodeEnabled(pattern) && !hasInlineUnicodeEnableOption(pattern)
        }
        return hasInlineNoUnicodeOption(pattern) && !hasInlineUnicodeEnableOption(pattern)
    }

    private static func hasPCREByteUnitEscape(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        for character in pattern {
            if escaped {
                if !inClass, character == "C" {
                    return true
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
            } else if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            }
        }
        return false
    }

    private static func wholePatternUnicodeEnabled(_ pattern: String) -> Bool {
        guard pattern.hasPrefix("(?u") else {
            return false
        }
        guard let flags = inlineUnicodeFlags(in: pattern, openingAt: pattern.startIndex),
              flags.unicodeEnabled == true else {
            return false
        }
        if flags.scoped {
            return flags.end == pattern.endIndex
        }
        return flags.end < pattern.endIndex
    }

    private static func wordRegexpPattern(for source: String, usesByteSemantics: Bool) -> String {
        let wordClass = usesByteSemantics
            ? "0-9A-Za-z_"
            : "\\p{L}\\p{M}\\p{N}_"
        return "(?<![\(wordClass)])(?:\(source))(?![\(wordClass)])"
    }

    private static func topLevelAlternatives(in pattern: String) -> [String] {
        var alternatives: [String] = []
        var start = pattern.startIndex
        var index = pattern.startIndex
        var escaped = false
        var inClass = false
        var depth = 0

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if inClass {
                if character == "]" {
                    inClass = false
                }
                index = pattern.index(after: index)
                continue
            }
            switch character {
            case "[":
                inClass = true
            case "(":
                depth += 1
            case ")":
                depth = max(0, depth - 1)
            case "|" where depth == 0:
                alternatives.append(String(pattern[start..<index]))
                start = pattern.index(after: index)
            default:
                break
            }
            index = pattern.index(after: index)
        }

        guard !alternatives.isEmpty else {
            return [pattern]
        }
        alternatives.append(String(pattern[start..<pattern.endIndex]))
        return alternatives
    }

    private static func inlineCRLFPattern(for pattern: String) -> (pattern: String, enablesGlobalCRLF: Bool) {
        var output = ""
        var enablesGlobalCRLF = false
        var escaped = false
        var inClass = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                output.append("\\")
                output.append(character)
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                output.append(character)
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                output.append(character)
                index = pattern.index(after: index)
                continue
            }
            if !inClass,
               character == "(",
               let group = inlineCRLFGroup(in: pattern, openingAt: index) {
                if group.scoped {
                    let bodyResult = inlineCRLFPattern(for: group.body)
                    var body = bodyResult.pattern
                    if group.crlfEnabled && !group.disablesMultiline {
                        body = inlineCRLFAnchorPattern(for: body)
                    }
                    output += inlineFlagGroup(flags: group.cleanedFlags, body: body)
                    enablesGlobalCRLF = enablesGlobalCRLF || bodyResult.enablesGlobalCRLF
                } else {
                    enablesGlobalCRLF = enablesGlobalCRLF || group.crlfEnabled
                    output += inlineFlagGroup(flags: group.cleanedFlags)
                }
                index = group.end
                continue
            }
            output.append(character)
            index = pattern.index(after: index)
        }

        if escaped {
            output.append("\\")
        }
        return (output, enablesGlobalCRLF)
    }

    private static func inlineCRLFGroup(
        in pattern: String,
        openingAt opening: String.Index
    ) -> (scoped: Bool, crlfEnabled: Bool, disablesMultiline: Bool, cleanedFlags: String, body: String, end: String.Index)? {
        let question = pattern.index(after: opening)
        guard question < pattern.endIndex, pattern[question] == "?" else {
            return nil
        }

        var cursor = pattern.index(after: question)
        var flags = ""
        while cursor < pattern.endIndex {
            let character = pattern[cursor]
            if character == ":" || character == ")" {
                break
            }
            guard character == "-" || character.isASCII && character.isLetter else {
                return nil
            }
            flags.append(character)
            cursor = pattern.index(after: cursor)
        }
        guard flags.contains("R"), cursor < pattern.endIndex else {
            return nil
        }

        let crlfEnabled = inlineCRLFEnabled(by: flags)
        let disablesMultiline = inlineFlagsDisableMultiline(flags)
        let cleanedFlags = inlineFlagsRemovingCRLF(flags)
        if pattern[cursor] == ")" {
            return (false, crlfEnabled, disablesMultiline, cleanedFlags, "", pattern.index(after: cursor))
        }
        guard pattern[cursor] == ":",
              let close = closingGroupIndex(in: pattern, openingAt: opening) else {
            return nil
        }
        let bodyStart = pattern.index(after: cursor)
        let body = String(pattern[bodyStart..<close])
        return (true, crlfEnabled, disablesMultiline, cleanedFlags, body, pattern.index(after: close))
    }

    private static func inlineCRLFEnabled(by flags: String) -> Bool {
        var disabling = false
        var enabled = false
        for character in flags {
            if character == "-" {
                disabling = true
            } else if character == "R" {
                enabled = !disabling
            }
        }
        return enabled
    }

    private static func inlineFlagsDisableMultiline(_ flags: String) -> Bool {
        var disabling = false
        var disabled = false
        for character in flags {
            if character == "-" {
                disabling = true
            } else if character == "m" {
                disabled = disabling
            }
        }
        return disabled
    }

    private static func inlineFlagsRemovingCRLF(_ flags: String) -> String {
        var cleaned = ""
        var pendingDash = false
        for character in flags {
            if character == "-" {
                pendingDash = true
                continue
            }
            guard character != "R" else {
                continue
            }
            if pendingDash {
                cleaned.append("-")
                pendingDash = false
            }
            cleaned.append(character)
        }
        return cleaned
    }

    private static func inlineFlagGroup(flags: String, body: String? = nil) -> String {
        if let body {
            return flags.isEmpty ? "(?:\(body))" : "(?\(flags):\(body))"
        }
        return flags.isEmpty ? "" : "(?\(flags))"
    }

    private static func closingGroupIndex(in pattern: String, openingAt opening: String.Index) -> String.Index? {
        var escaped = false
        var inClass = false
        var depth = 0
        var index = opening
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
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
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func byteRegexLiteralPattern(for pattern: String) -> String {
        var output = ""
        var escaped = false

        for character in pattern {
            if escaped {
                output.append("\\")
                output.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character.isASCII {
                output.append(character)
                continue
            }
            output += character.utf8.map { byte in
                "\\x{\(String(byte, radix: 16, uppercase: true))}"
            }.joined()
        }
        if escaped {
            output.append("\\")
        }
        return output
    }

    private static func hasInlineNoUnicodeOption(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                index = pattern.index(after: index)
                continue
            }
            if !inClass,
               pattern[index...].hasPrefix("(?-u)") || pattern[index...].hasPrefix("(?-u:") {
                return true
            }
            index = pattern.index(after: index)
        }
        return false
    }

    private static func hasInlineUnicodeEnableOption(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                index = pattern.index(after: index)
                continue
            }
            if !inClass,
               character == "(",
               let flags = inlineUnicodeFlags(in: pattern, openingAt: index) {
                if flags.unicodeEnabled == true {
                    return true
                }
                index = flags.end
                continue
            }
            index = pattern.index(after: index)
        }
        return false
    }

    private static func bytePattern(_ pattern: String) -> String {
        String(String.UnicodeScalarView(pattern.utf8.map { UnicodeScalar($0) }))
    }

    private static func foundationNamedCapturePattern(for pattern: String) -> String {
        var output = ""
        var escaped = false
        var inClass = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                output.append(character)
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                output.append(character)
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                output.append(character)
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                output.append(character)
                index = pattern.index(after: index)
                continue
            }
            if !inClass, pattern[index...].hasPrefix("(?P<") {
                output += "(?<"
                index = pattern.index(index, offsetBy: 4)
                continue
            }
            output.append(character)
            index = pattern.index(after: index)
        }

        return output
    }

    private static func foundationAnyClassPattern(for pattern: String) -> String {
        var output = ""
        var escaped = false
        var inClass = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if !inClass, character == "p", pattern[index...].hasPrefix("p{Any}") {
                    output += "[\\s\\S]"
                    index = pattern.index(index, offsetBy: "p{Any}".count)
                } else if !inClass, character == "P", pattern[index...].hasPrefix("P{Any}") {
                    output += "(?!)"
                    index = pattern.index(index, offsetBy: "P{Any}".count)
                } else {
                    output.append("\\")
                    output.append(character)
                    index = pattern.index(after: index)
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            }
            output.append(character)
            index = pattern.index(after: index)
        }
        if escaped {
            output.append("\\")
        }
        return output
    }

    private static func binaryWildcardPattern(for pattern: String, options: RipgrepOptions) -> String {
        guard !options.multilineDotall,
              !hasInlineDotAllOption(pattern) else {
            return pattern
        }
        let replacement: String
        if options.nullData {
            replacement = "[^\\n\\x{0}]"
        } else if options.disablesBinaryDetection {
            replacement = "[^\\n]"
        } else {
            replacement = "[^\\n\\x{0}]"
        }
        var output = ""
        var escaped = false
        var inClass = false

        for character in pattern {
            if escaped {
                output.append("\\")
                output.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "[" {
                inClass = true
                output.append(character)
                continue
            }
            if character == "]" {
                inClass = false
                output.append(character)
                continue
            }
            if !inClass, character == "." {
                output += replacement
                continue
            }
            output.append(character)
        }
        if escaped {
            output.append("\\")
        }
        return output
    }

    private static func scalarDotAllWildcardPattern(for pattern: String, options: RipgrepOptions) -> String {
        guard options.multilineDotall || hasInlineDotAllOption(pattern) else {
            return pattern
        }
        return transformWildcards(in: pattern, replacement: "[\\s\\S]")
    }

    private static func transformWildcards(in pattern: String, replacement: String) -> String {
        var output = ""
        var escaped = false
        var inClass = false

        for character in pattern {
            if escaped {
                output.append("\\")
                output.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "[" {
                inClass = true
                output.append(character)
                continue
            }
            if character == "]" {
                inClass = false
                output.append(character)
                continue
            }
            if !inClass, character == "." {
                output += replacement
                continue
            }
            output.append(character)
        }
        if escaped {
            output.append("\\")
        }
        return output
    }

    private static func hasInlineDotAllOption(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                index = pattern.index(after: index)
                continue
            }
            if !inClass, pattern[index...].hasPrefix("(?") {
                var optionIndex = pattern.index(index, offsetBy: 2)
                var enablesDotAll = false
                var disabling = false
                while optionIndex < pattern.endIndex {
                    let option = pattern[optionIndex]
                    if option == ")" || option == ":" {
                        return enablesDotAll
                    }
                    if option == "-" {
                        disabling = true
                    } else if option == "s" {
                        enablesDotAll = !disabling
                    }
                    optionIndex = pattern.index(after: optionIndex)
                }
                return false
            }
            index = pattern.index(after: index)
        }
        return false
    }

    private static func foundationUnicodePropertyShorthandPattern(for pattern: String) -> String {
        var output = ""
        var escaped = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character == "p" || character == "P" {
                    let propertyStart = pattern.index(after: index)
                    if propertyStart < pattern.endIndex,
                       pattern[propertyStart].isASCII,
                       pattern[propertyStart].isLetter {
                        output.append("\\")
                        output.append(character)
                        output.append("{")
                        output.append(pattern[propertyStart])
                        output.append("}")
                        index = pattern.index(after: propertyStart)
                    } else {
                        output.append("\\")
                        output.append(character)
                        index = propertyStart
                    }
                } else {
                    output.append("\\")
                    output.append(character)
                    index = pattern.index(after: index)
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            output.append(character)
            index = pattern.index(after: index)
        }
        if escaped {
            output.append("\\")
        }
        return output
    }

    private static func foundationScalarEscapePattern(for pattern: String) -> String {
        var output = ""
        var escaped = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character == "x" || character == "u",
                   let escape = scalarEscapeSource(after: index, kind: character, in: pattern) {
                    output += escape.source
                    index = pattern.index(after: escape.end)
                } else {
                    output.append("\\")
                    output.append(character)
                    index = pattern.index(after: index)
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            output.append(character)
            index = pattern.index(after: index)
        }
        if escaped {
            output.append("\\")
        }
        return output
    }

    private static func scalarEscapeSource(
        after index: String.Index,
        kind: Character,
        in pattern: String
    ) -> (source: String, end: String.Index)? {
        if let escape = bracedScalarEscape(after: index, in: pattern) {
            return ("\\x{\(String(escape.value, radix: 16, uppercase: true))}", escape.end)
        }
        let digitCount = kind == "x" ? 2 : 4
        var end = index
        var digits = ""
        for _ in 0..<digitCount {
            let next = pattern.index(after: end)
            guard next < pattern.endIndex, pattern[next].isHexDigit else {
                return nil
            }
            digits.append(pattern[next])
            end = next
        }
        guard let value = UInt32(digits, radix: 16),
              UnicodeScalar(value) != nil else {
            return nil
        }
        return ("\\x{\(String(value, radix: 16, uppercase: true))}", end)
    }

    private static func bracedScalarEscape(
        after index: String.Index,
        in pattern: String
    ) -> (value: UInt32, end: String.Index)? {
        let brace = pattern.index(after: index)
        guard brace < pattern.endIndex, pattern[brace] == "{",
              let close = pattern[brace...].firstIndex(of: "}") else {
            return nil
        }
        let digitsStart = pattern.index(after: brace)
        guard digitsStart < close,
              let value = UInt32(pattern[digitsStart..<close], radix: 16),
              UnicodeScalar(value) != nil else {
            return nil
        }
        return (value, close)
    }

    private struct UnsupportedRegexFeature {
        let byteOffset: Int
        let caretLength: Int
        let message: String
    }

    private static func defaultEngineUnsupportedFeature(in pattern: String) -> UnsupportedRegexFeature? {
        var escaped = false
        var inClass = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character.isNumber {
                    return UnsupportedRegexFeature(
                        byteOffset: pattern[..<pattern.index(before: index)].utf8.count,
                        caretLength: 2,
                        message: "backreferences are not supported"
                    )
                }
                if character == "g"
                    || character == "k"
                    || character == "K"
                    || character == "C"
                    || character == "N"
                    || character == "Q"
                    || character == "E" {
                    return UnsupportedRegexFeature(
                        byteOffset: pattern[..<pattern.index(before: index)].utf8.count,
                        caretLength: 2,
                        message: "unrecognized escape sequence"
                    )
                }
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                index = pattern.index(after: index)
                continue
            }
            if !inClass,
               character == "(",
               let conditionalFlag = unsupportedPCREConditionalFlag(at: index, in: pattern) {
                return conditionalFlag
            }
            if !inClass,
               character == "(",
               let pcreFlag = unsupportedPCREGroupFlag(at: index, in: pattern) {
                return pcreFlag
            }
            if !inClass,
               character == "(",
               let lookAroundLength = lookAroundPrefixLength(at: index, in: pattern) {
                return UnsupportedRegexFeature(
                    byteOffset: pattern[..<index].utf8.count,
                    caretLength: lookAroundLength,
                    message: "look-around, including look-ahead and look-behind, is not supported"
                )
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func defaultRegexParseError(pattern: String, feature: UnsupportedRegexFeature) -> String {
        let wrappedPattern = "(?:\(pattern))"
        let caretIndent = String(repeating: " ", count: 4 + 3 + feature.byteOffset)
        let carets = String(repeating: "^", count: feature.caretLength)
        return """
        regex parse error:
            \(wrappedPattern)
        \(caretIndent)\(carets)
        error: \(feature.message)
        """
    }

    private static func defaultRegexParseErrorIfRecognized(_ pattern: String) -> String? {
        if let diagnostic = unrecognizedEscapeDiagnostic(pattern) {
            return defaultRegexParseError(pattern: pattern, feature: diagnostic)
        }
        if let diagnostic = unclosedOrInvalidClassDiagnostic(pattern) {
            return defaultRegexParseError(pattern: pattern, feature: diagnostic)
        }
        if let diagnostic = invalidRepetitionDiagnostic(pattern) {
            return defaultRegexParseError(pattern: pattern, feature: diagnostic)
        }
        if let diagnostic = unopenedGroupDiagnostic(pattern) {
            return defaultRegexParseError(pattern: pattern, feature: diagnostic)
        }
        return nil
    }

    private static func unicodeClassInNoUnicodeDiagnostic(
        _ pattern: String,
        unicodeEnabled: Bool
    ) -> UnsupportedRegexFeature? {
        scanUnicodeClass(in: pattern, from: pattern.startIndex, to: pattern.endIndex, unicodeEnabled: unicodeEnabled)
    }

    private static func scanUnicodeClass(
        in pattern: String,
        from start: String.Index,
        to end: String.Index,
        unicodeEnabled: Bool
    ) -> UnsupportedRegexFeature? {
        var escaped = false
        var inClass = false
        var currentUnicodeEnabled = unicodeEnabled
        var index = start

        while index < end {
            let character = pattern[index]
            if escaped {
                if (character == "p" || character == "P"),
                   let propertyEnd = unicodePropertyEnd(after: index, in: pattern) {
                    if !currentUnicodeEnabled {
                        let backslash = pattern.index(before: index)
                        return UnsupportedRegexFeature(
                            byteOffset: pattern[..<backslash].utf8.count,
                            caretLength: pattern[backslash..<propertyEnd].utf8.count,
                            message: "Unicode not allowed here"
                        )
                    }
                    escaped = false
                    index = propertyEnd
                    continue
                }
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                index = pattern.index(after: index)
                continue
            }
            if !inClass,
               character == "(",
               let flags = inlineUnicodeFlags(in: pattern, openingAt: index) {
                if flags.scoped,
                   let close = flags.close,
                   let diagnostic = scanUnicodeClass(
                    in: pattern,
                    from: flags.bodyStart,
                    to: close,
                    unicodeEnabled: flags.unicodeEnabled ?? currentUnicodeEnabled
                   ) {
                    return diagnostic
                }
                if flags.scoped {
                    index = flags.end
                    continue
                }
                if let unicodeEnabled = flags.unicodeEnabled {
                    currentUnicodeEnabled = unicodeEnabled
                }
                index = flags.end
                continue
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func unicodePropertyEnd(after index: String.Index, in pattern: String) -> String.Index? {
        let propertyStart = pattern.index(after: index)
        guard propertyStart < pattern.endIndex else {
            return nil
        }
        if pattern[propertyStart] == "{" {
            guard let close = pattern[propertyStart...].firstIndex(of: "}") else {
                return nil
            }
            return pattern.index(after: close)
        }
        guard pattern[propertyStart].isASCII, pattern[propertyStart].isLetter else {
            return nil
        }
        return pattern.index(after: propertyStart)
    }

    private static func inlineUnicodeFlags(
        in pattern: String,
        openingAt opening: String.Index
    ) -> (scoped: Bool, unicodeEnabled: Bool?, bodyStart: String.Index, close: String.Index?, end: String.Index)? {
        let question = pattern.index(after: opening)
        guard question < pattern.endIndex, pattern[question] == "?" else {
            return nil
        }

        var cursor = pattern.index(after: question)
        var disabling = false
        var unicodeEnabled: Bool?
        while cursor < pattern.endIndex {
            let character = pattern[cursor]
            if character == ":" {
                guard let close = closingGroupIndex(in: pattern, openingAt: opening) else {
                    return nil
                }
                return (
                    scoped: true,
                    unicodeEnabled: unicodeEnabled,
                    bodyStart: pattern.index(after: cursor),
                    close: close,
                    end: pattern.index(after: close)
                )
            }
            if character == ")" {
                return (
                    scoped: false,
                    unicodeEnabled: unicodeEnabled,
                    bodyStart: cursor,
                    close: nil,
                    end: pattern.index(after: cursor)
                )
            }
            guard character == "-" || character.isASCII && character.isLetter else {
                return nil
            }
            if character == "-" {
                disabling = true
            } else if character == "u" {
                unicodeEnabled = !disabling
            }
            cursor = pattern.index(after: cursor)
        }
        return nil
    }

    private static func unrecognizedEscapeDiagnostic(_ pattern: String) -> UnsupportedRegexFeature? {
        var escaped = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character == "q" || character == "C" {
                    return UnsupportedRegexFeature(
                        byteOffset: pattern[..<pattern.index(before: index)].utf8.count,
                        caretLength: 2,
                        message: "unrecognized escape sequence"
                    )
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func unclosedOrInvalidClassDiagnostic(_ pattern: String) -> UnsupportedRegexFeature? {
        var escaped = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if (character == "p" || character == "P" || character == "x" || character == "u"),
                   let close = bracedEscapeEnd(after: index, in: pattern) {
                    escaped = false
                    index = pattern.index(after: close)
                    continue
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "[" {
                if pattern[index...].hasSuffix("-") {
                    let start = pattern.index(after: index)
                    return UnsupportedRegexFeature(
                        byteOffset: pattern[..<start].utf8.count,
                        caretLength: pattern[start...].utf8.count + 1,
                        message: "invalid character class range, the start must be <= the end"
                    )
                }
                if !hasClosingBracket(after: index, in: pattern) {
                    return UnsupportedRegexFeature(
                        byteOffset: pattern[..<index].utf8.count,
                        caretLength: 1,
                        message: "unclosed character class"
                    )
                }
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func invalidRepetitionDiagnostic(_ pattern: String) -> UnsupportedRegexFeature? {
        var escaped = false
        var inClass = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if (character == "p" || character == "P" || character == "x" || character == "u"),
                   let close = bracedEscapeEnd(after: index, in: pattern) {
                    escaped = false
                    index = pattern.index(after: close)
                    continue
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            } else if !inClass, character == "{" {
                let digitStart = pattern.index(after: index)
                let digitEnd = pattern[digitStart...].firstIndex { !$0.isNumber } ?? pattern.endIndex
                let digitCount = pattern[digitStart..<digitEnd].count
                if digitCount == 0 {
                    return UnsupportedRegexFeature(
                        byteOffset: pattern[..<index].utf8.count + 1,
                        caretLength: 1,
                        message: "repetition quantifier expects a valid decimal"
                    )
                }
                if digitCount > 19 {
                    return UnsupportedRegexFeature(
                        byteOffset: pattern[..<digitStart].utf8.count,
                        caretLength: pattern[digitStart..<digitEnd].utf8.count,
                        message: "decimal literal invalid"
                    )
                }
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func bracedEscapeEnd(after index: String.Index, in pattern: String) -> String.Index? {
        let brace = pattern.index(after: index)
        guard brace < pattern.endIndex, pattern[brace] == "{" else {
            return nil
        }
        return pattern[brace...].firstIndex(of: "}")
    }

    private static func bracedUnicodeClassEnd(after index: String.Index, in pattern: String) -> String.Index? {
        bracedEscapeEnd(after: index, in: pattern)
    }

    private static func unopenedGroupDiagnostic(_ pattern: String) -> UnsupportedRegexFeature? {
        var escaped = false
        var inClass = false
        var depth = 0
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
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
                    guard !pattern[pattern.index(after: index)...].contains("(") else {
                        index = pattern.index(after: index)
                        continue
                    }
                    return UnsupportedRegexFeature(
                        byteOffset: pattern[..<index].utf8.count + 1,
                        caretLength: 1,
                        message: "unopened group"
                    )
                }
                depth -= 1
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func automaticEngineUnavailableMessage(
        pattern: String,
        feature: UnsupportedRegexFeature,
        pcre2Error: String
    ) -> String {
        automaticEngineUnavailableMessage(
            pattern: pattern,
            defaultError: defaultRegexParseError(pattern: pattern, feature: feature),
            pcre2Error: pcre2Error
        )
    }

    private static func automaticEngineUnavailableMessage(
        pattern _: String,
        defaultError: String,
        pcre2Error: String
    ) -> String {
        """
        regex could not be compiled with either the default regex engine or with PCRE2.

        default regex engine error:
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        \(defaultError)
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

        PCRE2 regex engine error:
        \(pcre2Error)
        """
    }

    private static func lookAroundPrefixLength(at index: String.Index, in text: String) -> Int? {
        if text[index...].hasPrefix("(?=") || text[index...].hasPrefix("(?!") {
            return 3
        }
        if text[index...].hasPrefix("(?<=") || text[index...].hasPrefix("(?<!") {
            return 4
        }
        return nil
    }

    private static func unsupportedPCREConditionalFlag(
        at index: String.Index,
        in text: String
    ) -> UnsupportedRegexFeature? {
        guard text[index...].hasPrefix("(?(") else {
            return nil
        }
        let conditionOpen = text.index(index, offsetBy: 2)
        return UnsupportedRegexFeature(
            byteOffset: text[..<conditionOpen].utf8.count,
            caretLength: 1,
            message: "unrecognized flag"
        )
    }

    private static func unsupportedPCREGroupFlag(at index: String.Index, in text: String) -> UnsupportedRegexFeature? {
        let question = text.index(after: index)
        guard question < text.endIndex, text[question] == "?" else {
            return nil
        }
        let flag = text.index(after: question)
        guard flag < text.endIndex, text[flag] == "P" else {
            return nil
        }
        let next = text.index(after: flag)
        guard next < text.endIndex, text[next] != "<" else {
            return nil
        }
        return UnsupportedRegexFeature(
            byteOffset: text[..<flag].utf8.count,
            caretLength: 1,
            message: "unrecognized flag"
        )
    }

    private static func hasClosingBracket(after open: String.Index, in pattern: String) -> Bool {
        var escaped = false
        var index = pattern.index(after: open)
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "]" {
                return true
            }
            index = pattern.index(after: index)
        }
        return false
    }

    private static func asciiRegexPattern(for pattern: String) -> String {
        var output = ""
        var escaped = false
        var inClass = false

        for character in pattern {
            if escaped {
                switch character {
                case "w":
                    output += inClass ? "0-9A-Za-z_" : "[0-9A-Za-z_]"
                case "W":
                    output += inClass ? "\\W" : "[^0-9A-Za-z_]"
                case "d":
                    output += inClass ? "0-9" : "[0-9]"
                case "D":
                    output += inClass ? "\\D" : "[^0-9]"
                case "s":
                    output += inClass ? " \\t\\r\\n\\f" : "[ \\t\\r\\n\\f]"
                case "S":
                    output += inClass ? "\\S" : "[^ \\t\\r\\n\\f]"
                case "b":
                    output += inClass ? "\\b" : asciiWordBoundaryPattern
                case "B":
                    output += inClass ? "\\B" : asciiNotWordBoundaryPattern
                default:
                    output.append("\\")
                    output.append(character)
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            }
            output.append(character)
        }
        if escaped {
            output.append("\\")
        }
        return output
    }

    private static func scopedByteRegexPattern(
        for pattern: String,
        defaultUnicodeEnabled: Bool,
        caseInsensitive: Bool
    ) -> String {
        var output = ""
        var chunk = ""
        var currentUnicodeEnabled = defaultUnicodeEnabled
        var escaped = false
        var inClass = false
        var index = pattern.startIndex

        func flushChunk() {
            guard !chunk.isEmpty else {
                return
            }
            if currentUnicodeEnabled {
                output += caseInsensitive
                    ? unicodeSimpleCaseInsensitivePattern(for: chunk)
                    : chunk
            } else {
                var transformed = asciiRegexPattern(for: chunk)
                if caseInsensitive {
                    transformed = asciiCaseInsensitivePattern(for: transformed)
                }
                output += byteRegexLiteralPattern(for: transformed)
            }
            chunk = ""
        }

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                chunk.append(character)
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                chunk.append(character)
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                chunk.append(character)
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                chunk.append(character)
                index = pattern.index(after: index)
                continue
            }
            if !inClass,
               character == "(",
               let flags = inlineUnicodeFlags(in: pattern, openingAt: index) {
                flushChunk()
                if flags.scoped, let close = flags.close {
                    let prefix = pattern[index..<flags.bodyStart]
                    let body = pattern[flags.bodyStart..<close]
                    let unicodeEnabled = flags.unicodeEnabled ?? currentUnicodeEnabled
                    output += prefix
                    output += scopedByteRegexPattern(
                        for: String(body),
                        defaultUnicodeEnabled: unicodeEnabled,
                        caseInsensitive: caseInsensitive
                    )
                    output.append(")")
                    index = flags.end
                    continue
                }
                output += pattern[index..<flags.end]
                if let unicodeEnabled = flags.unicodeEnabled {
                    currentUnicodeEnabled = unicodeEnabled
                }
                index = flags.end
                continue
            }
            chunk.append(character)
            index = pattern.index(after: index)
        }
        flushChunk()
        return output
    }

    private static let asciiWordBoundaryPattern =
        "(?:(?<![0-9A-Za-z_])(?=[0-9A-Za-z_])|(?<=[0-9A-Za-z_])(?![0-9A-Za-z_]))"

    private static let asciiNotWordBoundaryPattern =
        "(?:(?<=[0-9A-Za-z_])(?=[0-9A-Za-z_])|(?<![0-9A-Za-z_])(?![0-9A-Za-z_]))"

    private static let asciiPOSIXClassRanges = [
        "alnum": "0-9A-Za-z",
        "alpha": "A-Za-z",
        "blank": " \\t",
        "digit": "0-9",
        "lower": "a-z",
        "space": " \\t\\r\\n\\u000B\\f",
        "upper": "A-Z",
        "word": "0-9A-Za-z_",
        "xdigit": "0-9A-Fa-f",
    ]

    private static func negatedASCIIPosixClasses(for pattern: String) -> String {
        var output = ""
        var escaped = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                output.append(character)
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                output.append(character)
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            guard character == "[",
                  let close = characterClassClose(in: pattern, openingAt: index) else {
                output.append(character)
                index = pattern.index(after: index)
                continue
            }

            let contentStart = pattern.index(after: index)
            let content = String(pattern[contentStart..<close])
            if let replacement = negatedASCIIPosixClassReplacement(forClassContent: content) {
                output += replacement
            } else {
                output.append(contentsOf: pattern[index...close])
            }
            index = pattern.index(after: close)
        }

        if escaped {
            output.append("\\")
        }
        return output
    }

    private static func characterClassClose(in pattern: String, openingAt opening: String.Index) -> String.Index? {
        var escaped = false
        var index = pattern.index(after: opening)
        var contentStarted = false
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                contentStarted = true
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                contentStarted = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[", pattern[index...].hasPrefix("[:"),
               let posixClose = posixClassClose(in: pattern, openingAt: index) {
                contentStarted = true
                index = pattern.index(after: posixClose)
                continue
            }
            if character == "]", contentStarted {
                return index
            }
            contentStarted = true
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func posixClassClose(in pattern: String, openingAt opening: String.Index) -> String.Index? {
        var index = pattern.index(after: opening)
        while index < pattern.endIndex {
            if pattern[index] == "]",
               index > pattern.startIndex,
               pattern[pattern.index(before: index)] == ":" {
                return index
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func negatedASCIIPosixClassReplacement(forClassContent content: String) -> String? {
        guard !content.hasPrefix("^") else {
            return nil
        }

        var positiveContent = ""
        var negatedRanges: [String] = []
        var index = content.startIndex
        while index < content.endIndex {
            if content[index...].hasPrefix("[:^"),
               let close = content[index...].firstIndex(of: "]") {
                let nameStart = content.index(index, offsetBy: 3)
                let nameEnd = content.index(before: close)
                let name = String(content[nameStart..<nameEnd])
                if let range = asciiPOSIXClassRanges[name] {
                    negatedRanges.append(range)
                    index = content.index(after: close)
                    continue
                }
            }
            positiveContent.append(content[index])
            index = content.index(after: index)
        }

        guard !negatedRanges.isEmpty else {
            return nil
        }

        var alternatives = negatedRanges.map { "[^\($0)]" }
        if !positiveContent.isEmpty {
            alternatives.insert("[\(positiveContent)]", at: 0)
        }
        return "(?:\(alternatives.joined(separator: "|")))"
    }

    private static func asciiPOSIXClasses(for pattern: String) -> String {
        var output = ""
        var escaped = false
        var inClass = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                output.append(character)
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                output.append(character)
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                if inClass, let replacement = asciiPOSIXClassReplacement(at: index, in: pattern) {
                    output += replacement.value
                    index = replacement.end
                    continue
                }
                inClass = true
                output.append(character)
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
            }
            output.append(character)
            index = pattern.index(after: index)
        }

        return output
    }

    private static func asciiPOSIXClassReplacement(
        at index: String.Index,
        in pattern: String
    ) -> (value: String, end: String.Index)? {
        let replacements = asciiPOSIXClassRanges.reduce(into: [String: String]()) { result, entry in
            result["[:\(entry.key):]"] = entry.value
        }
        for (token, value) in replacements where pattern[index...].hasPrefix(token) {
            return (value, pattern.index(index, offsetBy: token.count))
        }
        return nil
    }

    private static func asciiCaseInsensitivePattern(for pattern: String) -> String {
        var output = ""
        var escaped = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                output.append("\\")
                output.append(character)
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                if let escapeEnd = regexEscapeEnd(in: pattern, backslashAt: index) {
                    output += pattern[index..<escapeEnd]
                    index = escapeEnd
                    continue
                }
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "(",
               let prefixEnd = regexSyntaxGroupPrefixEnd(in: pattern, openingAt: index) {
                output += pattern[index..<prefixEnd]
                index = prefixEnd
                continue
            }
            if character == "[" {
                guard let classEnd = characterClassEnd(in: pattern, openingAt: index) else {
                    output.append(character)
                    index = pattern.index(after: index)
                    continue
                }
                let classStart = pattern.index(after: index)
                let content = String(pattern[classStart..<classEnd])
                output += "[\(asciiCaseInsensitiveClass(content))]"
                index = pattern.index(after: classEnd)
                continue
            }
            if let alternate = asciiCaseAlternate(for: character) {
                output += "[\(character)\(alternate)]"
                index = pattern.index(after: index)
                continue
            }
            output.append(character)
            index = pattern.index(after: index)
        }
        if escaped {
            output.append("\\")
        }
        return output
    }

    private static func unicodeSimpleCaseInsensitivePattern(for pattern: String) -> String {
        var output = ""
        var escaped = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                output.append("\\")
                output.append(character)
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                if let escapeEnd = regexEscapeEnd(in: pattern, backslashAt: index) {
                    output += pattern[index..<escapeEnd]
                    index = escapeEnd
                    continue
                }
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "(",
               let prefixEnd = regexSyntaxGroupPrefixEnd(in: pattern, openingAt: index) {
                output += pattern[index..<prefixEnd]
                index = prefixEnd
                continue
            }
            if character == "[" {
                guard let classEnd = characterClassEnd(in: pattern, openingAt: index) else {
                    output.append(character)
                    index = pattern.index(after: index)
                    continue
                }
                let classStart = pattern.index(after: index)
                let content = String(pattern[classStart..<classEnd])
                output += "[\(unicodeSimpleCaseInsensitiveClass(content))]"
                index = pattern.index(after: classEnd)
                continue
            }

            let alternates = unicodeSimpleCaseAlternates(for: character)
            if alternates.count > 1 {
                output += "(?:\(alternates.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")))"
            } else {
                output.append(character)
            }
            index = pattern.index(after: index)
        }
        if escaped {
            output.append("\\")
        }
        return output
    }

    private static func regexEscapeEnd(in pattern: String, backslashAt backslash: String.Index) -> String.Index? {
        let marker = pattern.index(after: backslash)
        guard marker < pattern.endIndex else {
            return nil
        }
        switch pattern[marker] {
        case "x":
            let first = pattern.index(after: marker)
            guard first < pattern.endIndex else {
                return nil
            }
            if pattern[first] == "{" {
                guard let close = pattern[first...].firstIndex(of: "}") else {
                    return nil
                }
                return pattern.index(after: close)
            }
            let second = pattern.index(after: first)
            guard second < pattern.endIndex else {
                return nil
            }
            return pattern.index(after: second)
        case "u":
            let first = pattern.index(after: marker)
            guard first < pattern.endIndex else {
                return nil
            }
            if pattern[first] == "{" {
                guard let close = pattern[first...].firstIndex(of: "}") else {
                    return nil
                }
                return pattern.index(after: close)
            }
            var cursor = first
            for _ in 0..<4 {
                guard cursor < pattern.endIndex else {
                    return nil
                }
                cursor = pattern.index(after: cursor)
            }
            return cursor
        default:
            return nil
        }
    }

    private static func regexSyntaxGroupPrefixEnd(in pattern: String, openingAt opening: String.Index) -> String.Index? {
        let question = pattern.index(after: opening)
        guard question < pattern.endIndex, pattern[question] == "?" else {
            return nil
        }
        let marker = pattern.index(after: question)
        guard marker < pattern.endIndex else {
            return nil
        }

        if pattern[marker] == "<" {
            let nameStart = pattern.index(after: marker)
            guard nameStart < pattern.endIndex,
                  pattern[nameStart] != "=",
                  pattern[nameStart] != "!" else {
                return nil
            }
            var nameEnd = nameStart
            while nameEnd < pattern.endIndex, pattern[nameEnd] != ">" {
                nameEnd = pattern.index(after: nameEnd)
            }
            return nameEnd < pattern.endIndex ? pattern.index(after: nameEnd) : nil
        }

        var cursor = marker
        var sawFlag = false
        while cursor < pattern.endIndex {
            let character = pattern[cursor]
            if character == ":" || character == ")" {
                return sawFlag ? cursor : nil
            }
            guard character == "-" || character.isASCII && character.isLetter else {
                return nil
            }
            sawFlag = true
            cursor = pattern.index(after: cursor)
        }
        return nil
    }

    private static func characterClassEnd(in pattern: String, openingAt opening: String.Index) -> String.Index? {
        var escaped = false
        var index = pattern.index(after: opening)

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "]", index != pattern.index(after: opening) {
                return index
            }
            if character == "[",
               let next = pattern.index(index, offsetBy: 1, limitedBy: pattern.endIndex),
               next < pattern.endIndex,
               pattern[next] == ":" || pattern[next] == "." || pattern[next] == "=",
               let posixEnd = posixClassEnd(in: pattern, from: next) {
                index = pattern.index(after: posixEnd)
                continue
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func posixClassEnd(in pattern: String, from marker: String.Index) -> String.Index? {
        let markerCharacter = pattern[marker]
        var index = pattern.index(after: marker)

        while index < pattern.endIndex {
            if pattern[index] == markerCharacter {
                let close = pattern.index(after: index)
                if close < pattern.endIndex, pattern[close] == "]" {
                    return close
                }
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func asciiCaseInsensitiveClass(_ content: String) -> String {
        let characters = Array(content)
        var additions = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if index + 2 < characters.count,
               characters[index + 1] == "-",
               let startAlternate = asciiCaseAlternate(for: character),
               let endAlternate = asciiCaseAlternate(for: characters[index + 2]) {
                additions.append(startAlternate)
                additions.append("-")
                additions.append(endAlternate)
                index += 3
                continue
            }
            if let alternate = asciiCaseAlternate(for: character) {
                additions.append(alternate)
            }
            index += 1
        }

        return content + additions
    }

    private static func unicodeSimpleCaseInsensitiveClass(_ content: String) -> String {
        let characters = Array(content)
        var additions = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if index + 2 < characters.count,
               characters[index + 1] == "-" {
                let startAlternates = Array(unicodeSimpleCaseAlternates(for: character).dropFirst())
                let endAlternates = Array(unicodeSimpleCaseAlternates(for: characters[index + 2]).dropFirst())
                for (start, end) in zip(startAlternates, endAlternates) {
                    additions += "\(escapedCharacterClassLiteral(start))-\(escapedCharacterClassLiteral(end))"
                }
                index += 3
                continue
            }
            for alternate in unicodeSimpleCaseAlternates(for: character).dropFirst() {
                additions += escapedCharacterClassLiteral(alternate)
            }
            index += 1
        }

        return content + additions
    }

    private static func asciiCaseAlternate(for character: Character) -> Character? {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return nil
        }
        if value >= 65, value <= 90, let scalar = UnicodeScalar(value + 32) {
            return Character(scalar)
        }
        if value >= 97, value <= 122, let scalar = UnicodeScalar(value - 32) {
            return Character(scalar)
        }
        return nil
    }

    private static func unicodeSimpleCaseAlternates(for character: Character) -> [String] {
        let original = String(character)
        var alternates: [String] = []
        func append(_ candidate: String) {
            guard !candidate.isEmpty,
                  candidate.count == 1,
                  !alternates.contains(candidate) else {
                return
            }
            alternates.append(candidate)
        }

        append(original)
        append(original.lowercased())
        append(original.uppercased())
        append(original.capitalized)
        if original == "Σ" || original == "σ" || original == "ς" {
            append("Σ")
            append("σ")
            append("ς")
        }
        return alternates
    }

    private static func simpleCaseEqual(_ lhs: Character, _ rhs: Character) -> Bool {
        unicodeSimpleCaseAlternates(for: lhs).contains(String(rhs))
    }

    private static func escapedCharacterClassLiteral(_ text: String) -> String {
        switch text {
        case "\\", "]", "-", "^":
            return "\\\(text)"
        default:
            return text
        }
    }

    private static func crlfAnchorPattern(for pattern: String) -> String {
        transformAnchors(in: pattern) { anchor in
            switch anchor {
            case "^":
                return "(?:^|(?<=\\r))"
            case "$":
                return "(?=\\r|(?<!\\r)$)"
            default:
                return String(anchor)
            }
        }
    }

    private static func multilineCRLFAnchorPattern(for pattern: String) -> String {
        transformMultilineAnchors(in: pattern) { anchor, multilineEnabled in
            if !multilineEnabled {
                return anchor == "$" ? "(?=\\z)" : String(anchor)
            }
            switch anchor {
            case "^":
                return "(?:^|(?<=\\n))"
            case "$":
                return "(?=\\r\\n|(?<!\\r)\\n|(?<![\\r\\n])\\z)"
            default:
                return String(anchor)
            }
        }
    }

    private static func inlineCRLFAnchorPattern(for pattern: String) -> String {
        transformMultilineAnchors(in: pattern) { anchor, multilineEnabled in
            if !multilineEnabled {
                return anchor == "$" ? "(?=\\z)" : String(anchor)
            }
            switch anchor {
            case "^":
                return "(?:^|(?<=[\\r\\n]))"
            case "$":
                return "(?=\\r|\\n|(?<![\\r\\n])\\z)"
            default:
                return String(anchor)
            }
        }
    }

    private static func strictLineEndPattern(for pattern: String) -> String {
        transformAnchors(in: pattern) { anchor in
            anchor == "$" ? "(?=\\z)" : String(anchor)
        }
    }

    private static func multilineLineEndPattern(for pattern: String) -> String {
        transformMultilineAnchors(in: pattern) { anchor, multilineEnabled in
            if anchor == "$" {
                return multilineEnabled ? "(?=\\n|(?<!\\n)\\z)" : "(?=\\z)"
            }
            return String(anchor)
        }
    }

    private static func nullDataAnchorPattern(for pattern: String) -> String {
        transformMultilineAnchors(in: pattern) { anchor, multilineEnabled in
            switch anchor {
            case "^":
                return "(?:^|(?<=\\n))"
            case "$":
                return multilineEnabled ? "(?=\\n|\\z)" : "(?=\\z)"
            default:
                return String(anchor)
            }
        }
    }

    private static func transformAnchors(
        in pattern: String,
        replacement: (Character) -> String
    ) -> String {
        var output = ""
        var escaped = false
        var inClass = false

        for character in pattern {
            if escaped {
                output.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                output.append(character)
                escaped = true
                continue
            }
            if character == "[" {
                inClass = true
                output.append(character)
                continue
            }
            if character == "]" {
                inClass = false
                output.append(character)
                continue
            }
            if !inClass && (character == "^" || character == "$") {
                output += replacement(character)
                continue
            }
            output.append(character)
        }

        return output
    }

    private static func transformMultilineAnchors(
        in pattern: String,
        replacement: (Character, Bool) -> String
    ) -> String {
        transformMultilineAnchors(in: pattern, defaultMultilineEnabled: true, replacement: replacement)
    }

    private static func transformMultilineAnchors(
        in pattern: String,
        defaultMultilineEnabled: Bool,
        replacement: (Character, Bool) -> String
    ) -> String {
        var output = ""
        var escaped = false
        var inClass = false
        var multilineEnabled = defaultMultilineEnabled
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                output.append(character)
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                output.append(character)
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                output.append(character)
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                output.append(character)
                index = pattern.index(after: index)
                continue
            }
            if !inClass,
               character == "(",
               let flags = inlineMultilineFlags(in: pattern, openingAt: index) {
                if flags.scoped, let close = flags.close {
                    output += pattern[index..<flags.bodyStart]
                    output += transformMultilineAnchors(
                        in: String(pattern[flags.bodyStart..<close]),
                        defaultMultilineEnabled: flags.multilineEnabled ?? multilineEnabled,
                        replacement: replacement
                    )
                    output.append(")")
                    index = flags.end
                    continue
                }
                output += pattern[index..<flags.end]
                if let flagMultilineEnabled = flags.multilineEnabled {
                    multilineEnabled = flagMultilineEnabled
                }
                index = flags.end
                continue
            }
            if !inClass && (character == "^" || character == "$") {
                output += replacement(character, multilineEnabled)
                index = pattern.index(after: index)
                continue
            }
            output.append(character)
            index = pattern.index(after: index)
        }

        return output
    }

    private static func inlineMultilineFlags(
        in pattern: String,
        openingAt opening: String.Index
    ) -> (scoped: Bool, multilineEnabled: Bool?, bodyStart: String.Index, close: String.Index?, end: String.Index)? {
        let question = pattern.index(after: opening)
        guard question < pattern.endIndex, pattern[question] == "?" else {
            return nil
        }

        var cursor = pattern.index(after: question)
        var disabling = false
        var multilineEnabled: Bool?
        while cursor < pattern.endIndex {
            let character = pattern[cursor]
            if character == ":" {
                guard let close = closingGroupIndex(in: pattern, openingAt: opening) else {
                    return nil
                }
                return (
                    scoped: true,
                    multilineEnabled: multilineEnabled,
                    bodyStart: pattern.index(after: cursor),
                    close: close,
                    end: pattern.index(after: close)
                )
            }
            if character == ")" {
                return (
                    scoped: false,
                    multilineEnabled: multilineEnabled,
                    bodyStart: cursor,
                    close: nil,
                    end: pattern.index(after: cursor)
                )
            }
            guard character == "-" || character.isASCII && character.isLetter else {
                return nil
            }
            if character == "-" {
                disabling = true
            } else if character == "m" {
                multilineEnabled = !disabling
            }
            cursor = pattern.index(after: cursor)
        }
        return nil
    }

    private func literalRanges(_ literal: String, in line: String) -> [Range<String.Index>] {
        if literal.isEmpty {
            var ranges: [Range<String.Index>] = []
            var index = line.startIndex
            while true {
                ranges.append(index..<index)
                guard index < line.endIndex else {
                    break
                }
                index = line.index(after: index)
            }
            return ranges
        }
        if options.effectiveIgnoreCase {
            return caseInsensitiveLiteralRanges(literal, in: line)
        }
        let haystack = line
        var cursor = haystack.startIndex
        var ranges: [Range<String.Index>] = []

        while cursor <= haystack.endIndex,
              let found = haystack.range(of: literal, range: cursor..<haystack.endIndex) {
            let lowerOffset = haystack.distance(from: haystack.startIndex, to: found.lowerBound)
            let upperOffset = haystack.distance(from: haystack.startIndex, to: found.upperBound)
            let lower = line.index(line.startIndex, offsetBy: lowerOffset)
            let upper = line.index(line.startIndex, offsetBy: upperOffset)
            ranges.append(lower..<upper)
            cursor = found.upperBound == cursor ? haystack.index(after: cursor) : found.upperBound
        }

        return ranges
    }

    private func literalContains(_ literal: String, in line: String) -> Bool {
        guard !literal.isEmpty else {
            return true
        }
        if options.effectiveIgnoreCase {
            return line.range(of: literal, options: [.caseInsensitive]) != nil
        }
        return line.range(of: literal) != nil
    }

    private func caseInsensitiveLiteralRanges(_ literal: String, in line: String) -> [Range<String.Index>] {
        let literalCharacters = Array(literal)
        var ranges: [Range<String.Index>] = []
        var cursor = line.startIndex

        while cursor < line.endIndex {
            let lower = cursor
            var upper = cursor
            var matched = true

            for literalCharacter in literalCharacters {
                guard upper < line.endIndex,
                      literalCharactersCaseEqual(literalCharacter, line[upper]) else {
                    matched = false
                    break
                }
                upper = line.index(after: upper)
            }

            if matched {
                ranges.append(lower..<upper)
                cursor = upper == cursor ? line.index(after: cursor) : upper
            } else {
                cursor = line.index(after: cursor)
            }
        }

        return ranges
    }

    private func literalCharactersCaseEqual(_ lhs: Character, _ rhs: Character) -> Bool {
        if options.noUnicode {
            return String(lhs).asciiLowercased() == String(rhs).asciiLowercased()
        }
        return Self.simpleCaseEqual(lhs, rhs)
    }

    private func emptyWordBoundaryRanges(in line: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = line.startIndex
        while true {
            let before = index == line.startIndex ? nil : line[line.index(before: index)]
            let after = index == line.endIndex ? nil : line[index]
            if !isWordCharacter(before) && !isWordCharacter(after) {
                ranges.append(index..<index)
            }
            guard index < line.endIndex else {
                break
            }
            index = line.index(after: index)
        }
        return ranges
    }

    private static func foldedCase(_ text: String, options: RipgrepOptions) -> String {
        options.noUnicode ? text.asciiLowercased() : text.lowercased()
    }

    private func replacement(for range: Range<String.Index>, in line: String) -> String? {
        guard let replacement = options.replacement else {
            return nil
        }
        return renderReplacement(replacement, line: line, ranges: [NSRange(range, in: line)])
    }

    private func replacement(for match: NSTextCheckingResult, in line: String) -> String? {
        guard let replacement = options.replacement else {
            return nil
        }
        let ranges = (0..<match.numberOfRanges).map { match.range(at: $0) }
        return renderReplacement(replacement, line: line, ranges: ranges) { name in
            match.range(withName: name)
        }
    }

    private func replacement(for match: PCRE2Match, in line: String) -> String? {
        guard let replacement = options.replacement else {
            return nil
        }
        let ranges = match.captures.map { capture -> NSRange in
            guard let capture else {
                return NSRange(location: NSNotFound, length: 0)
            }
            return NSRange(capture, in: line)
        }
        return renderReplacement(replacement, line: line, ranges: ranges) { name in
            guard let range = match.namedCaptures[name] else {
                return NSRange(location: NSNotFound, length: 0)
            }
            return NSRange(range, in: line)
        }
    }

    private func renderReplacement(
        _ template: String,
        line: String,
        ranges: [NSRange],
        namedRange: (String) -> NSRange = { _ in NSRange(location: NSNotFound, length: 0) }
    ) -> String {
        var output = ""
        var index = template.startIndex

        while index < template.endIndex {
            let character = template[index]
            guard character == "$" else {
                output.append(character)
                index = template.index(after: index)
                continue
            }

            let nextIndex = template.index(after: index)
            guard nextIndex < template.endIndex else {
                output.append(character)
                index = nextIndex
                continue
            }

            let next = template[nextIndex]
            if next == "$" {
                output.append("$")
                index = template.index(after: nextIndex)
                continue
            }
            if next == "{" {
                let nameStart = template.index(after: nextIndex)
                var nameEnd = nameStart
                while nameEnd < template.endIndex, isCaptureNameCharacter(template[nameEnd]) {
                    nameEnd = template.index(after: nameEnd)
                }
                guard nameEnd > nameStart,
                      nameEnd < template.endIndex,
                      template[nameEnd] == "}" else {
                    output.append("$")
                    index = nextIndex
                    continue
                }
                output += captureText(
                    String(template[nameStart..<nameEnd]),
                    line: line,
                    ranges: ranges,
                    namedRange: namedRange
                )
                index = template.index(after: nameEnd)
                continue
            }

            let nameStart = nextIndex
            var nameEnd = nameStart
            while nameEnd < template.endIndex, isCaptureNameCharacter(template[nameEnd]) {
                nameEnd = template.index(after: nameEnd)
            }
            guard nameEnd > nameStart else {
                output.append("$")
                index = nextIndex
                continue
            }
            output += captureText(
                String(template[nameStart..<nameEnd]),
                line: line,
                ranges: ranges,
                namedRange: namedRange
            )
            index = nameEnd
        }

        return output
    }

    private func captureText(
        _ name: String,
        line: String,
        ranges: [NSRange],
        namedRange: (String) -> NSRange
    ) -> String {
        let range: NSRange
        if let index = Int(name), index < ranges.count {
            range = ranges[index]
        } else {
            range = namedRange(name)
        }
        guard range.location != NSNotFound,
              let stringRange = Range(range, in: line) else {
            return ""
        }
        return String(line[stringRange])
    }

    private func isCaptureNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }

    private func lineStartIndex(in line: String) -> String.Index {
        line.startIndex
    }

    private func lineEndIndex(in line: String) -> String.Index {
        guard options.crlf, line.hasSuffix("\r") else {
            return line.endIndex
        }
        return line.index(before: line.endIndex)
    }

    private func isLineRegexpBounded(_ range: Range<String.Index>, in line: String) -> Bool {
        guard options.multiline else {
            return range.lowerBound == lineStartIndex(in: line) && range.upperBound == lineEndIndex(in: line)
        }
        let startsLine = range.lowerBound == line.startIndex
            || isMultilineLineTerminator(line[line.index(before: range.lowerBound)])
        let endsLine: Bool
        if range.upperBound == line.endIndex {
            endsLine = true
        } else if isMultilineLineTerminator(line[range.upperBound]) {
            endsLine = true
        } else {
            endsLine = false
        }
        return startsLine && endsLine
    }

    private func isMultilineLineTerminator(_ character: Character) -> Bool {
        character == "\n" || (options.crlf && (character == "\r" || character == "\r\n"))
    }

    private func indexRange(for span: MatchSpan, in line: String) -> Range<String.Index>? {
        guard span.startByte >= 0, span.endByte >= span.startByte else {
            return nil
        }
        guard let lower = stringIndex(in: line, atByteOffset: span.startByte),
              let upper = stringIndex(in: line, atByteOffset: span.endByte) else {
            return nil
        }
        return lower..<upper
    }

    private func column(for index: String.Index, in line: String) -> Int {
        byteOffset(for: index, in: line) + 1
    }

    private func byteOffset(for index: String.Index, in line: String) -> Int {
        let prefix = line[line.startIndex..<index]
        if usesByteSemantics {
            return prefix.unicodeScalars.count
        }
        return prefix.utf8.count
    }

    private func stringIndex(in line: String, atByteOffset byteOffset: Int) -> String.Index? {
        guard byteOffset >= 0 else {
            return nil
        }
        if byteOffset == 0 {
            return line.startIndex
        }
        var bytes = 0
        for index in line.indices {
            if bytes == byteOffset {
                return index
            }
            bytes += usesByteSemantics
                ? String(line[index]).unicodeScalars.count
                : String(line[index]).utf8.count
        }
        return bytes == byteOffset ? line.endIndex : nil
    }

    private func isWordBounded(_ range: Range<String.Index>, in line: String) -> Bool {
        let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
        let after = range.upperBound == line.endIndex ? nil : line[range.upperBound]
        if range.isEmpty {
            return !isWordCharacter(before) && !isWordCharacter(after)
        }

        let matched = line[range]
        guard matched.contains(where: { isWordCharacter($0) }) else {
            return !isWordCharacter(before) && !isWordCharacter(after)
        }
        if let first = matched.first,
           isWordCharacter(first),
           isWordCharacter(before) {
            return false
        }
        if let last = matched.last,
           isWordCharacter(last),
           isWordCharacter(after) {
            return false
        }
        return true
    }

    private func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else {
            return false
        }
        if options.noUnicode {
            return character.isASCIIWordCharacter
        }
        return character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || CharacterSet.nonBaseCharacters.contains($0)
                || $0 == "_"
        }
    }
}

private extension String {
    func asciiLowercased() -> String {
        String(unicodeScalars.map { scalar in
            guard scalar.value >= 65, scalar.value <= 90,
                  let lowered = UnicodeScalar(scalar.value + 32) else {
                return Character(scalar)
            }
            return Character(lowered)
        })
    }
}

private extension Character {
    var isASCIIWordCharacter: Bool {
        guard unicodeScalars.count == 1, let value = unicodeScalars.first?.value else {
            return false
        }
        return (value >= 48 && value <= 57)
            || (value >= 65 && value <= 90)
            || (value >= 97 && value <= 122)
            || value == 95
    }
}

private enum CompiledPattern {
    case emptyWordBoundary
    case regex(NSRegularExpression)
    case pcre2(PCRE2CompiledPattern)
    case literal(String)
}

struct ByteLiteralFastPath {
    let literals: [[UInt8]]
    let caseInsensitiveASCII: Bool
    let wordASCII: Bool
}

struct WordWhitespaceSequenceFastPath {
    let asciiOnly: Bool
    let groupCount: Int
}

private extension UInt8 {
    var isASCII: Bool {
        self < 0x80
    }
}

private struct MatchSpanIdentity: Hashable {
    let startByte: Int
    let endByte: Int
    let text: String
    let replacement: String?

    init(_ span: MatchSpan) {
        self.startByte = span.startByte
        self.endByte = span.endByte
        self.text = span.text
        self.replacement = span.replacement
    }
}
