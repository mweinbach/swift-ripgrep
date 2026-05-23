import Foundation

public struct PatternMatcher {
    private let options: RipgrepOptions
    private let patterns: [CompiledPattern]

    public init(options: RipgrepOptions) throws {
        let patternSources = options.effectivePatterns.map {
            options.encodingMode == .disabled ? $0.utf8RawScalars() : $0
        }

        self.options = options
        var compiledRegexSourceBytes = 0
        self.patterns = try patternSources.map { pattern in
            if options.wordRegexp && pattern.isEmpty {
                return .emptyWordBoundary
            }
            if options.fixedStrings {
                return .literal(options.effectiveIgnoreCase ? Self.foldedCase(pattern, options: options) : pattern)
            } else {
                if options.engineMode == .pcre2 {
                    throw RipgrepError.message("PCRE2 is not available in this build of ripgrep")
                }
                if options.binaryMode != .asText, Self.canMatchNUL(pattern) {
                    throw RipgrepError.message("""
                    pattern contains "\\0" but it is impossible to match

                    Consider enabling text mode with the --text flag (or -a for short). Otherwise,
                    binary detection is enabled and matching a NUL byte is impossible.
                    """)
                }
                if options.engineMode == .default, let unsupported = Self.defaultEngineUnsupportedFeature(in: pattern) {
                    throw RipgrepError.invalidRegex("\(unsupported) is not supported by the default regex engine; use --pcre2 or --engine=auto")
                }
                if options.engineMode == .automatic, let unsupported = Self.defaultEngineUnsupportedFeature(in: pattern) {
                    throw RipgrepError.message(Self.automaticEngineUnavailableMessage(unsupported: unsupported))
                }
                let source = Self.regexPattern(for: pattern, options: options)
                compiledRegexSourceBytes += source.utf8.count
                if let regexSizeLimit = options.regexSizeLimit,
                   regexSizeLimit > 0,
                   UInt64(compiledRegexSourceBytes) > regexSizeLimit {
                    throw RipgrepError.invalidRegex("compiled regex exceeds size limit of \(regexSizeLimit)")
                }
                do {
                    var regexOptions: NSRegularExpression.Options = options.effectiveIgnoreCase && !options.noUnicode ? [.caseInsensitive] : []
                    if options.multiline {
                        regexOptions.insert(.anchorsMatchLines)
                    }
                    if options.multiline && options.multilineDotall {
                        regexOptions.insert(.dotMatchesLineSeparators)
                    }
                    return .regex(try NSRegularExpression(
                        pattern: source,
                        options: regexOptions
                    ))
                } catch {
                    throw RipgrepError.invalidRegex(error.localizedDescription)
                }
            }
        }
    }

    private static func canMatchNUL(_ pattern: String) -> Bool {
        if pattern.contains("\0") {
            return true
        }

        var escaped = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character == "0" {
                    return true
                }
                if character == "x" {
                    let next = pattern.index(after: index)
                    if pattern[next...].hasPrefix("00") || pattern[next...].hasPrefix("{0}") {
                        return true
                    }
                }
                if character == "u" {
                    let next = pattern.index(after: index)
                    if pattern[next...].hasPrefix("0000") || pattern[next...].hasPrefix("{0}") {
                        return true
                    }
                }
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
            }
            index = pattern.index(after: index)
        }
        return false
    }

    public func matches(in line: String) -> [Range<String.Index>] {
        spans(in: line).compactMap { span in
            indexRange(for: span, in: line)
        }
    }

    public func spans(in line: String) -> [MatchSpan] {
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
            case .literal(let literal):
                candidates.append(contentsOf: literalRanges(literal, in: line).map { range in
                    (range, replacement(for: range, in: line))
                })
            }
        }

        let filtered = candidates.filter { candidate in
            (!options.wordRegexp || isWordBounded(candidate.range, in: line))
                && (!options.lineRegexp || (candidate.range.lowerBound == lineStartIndex(in: line) && candidate.range.upperBound == lineEndIndex(in: line)))
        }

        if options.invertMatch {
            return filtered.isEmpty ? [
                MatchSpan(startColumn: 1, endColumn: 1, startByte: 0, endByte: 0, text: "", replacement: nil),
            ] : []
        }

        return Self.dropAdjacentEmptyMatches(afterNonEmpty: filtered)
            .sorted { lhs, rhs in
                if lhs.range.lowerBound == rhs.range.lowerBound {
                    return lhs.range.upperBound < rhs.range.upperBound
                }
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            .map { candidate in
                MatchSpan(
                    startColumn: column(for: candidate.range.lowerBound, in: line),
                    endColumn: column(for: candidate.range.upperBound, in: line),
                    startByte: byteOffset(for: candidate.range.lowerBound, in: line),
                    endByte: byteOffset(for: candidate.range.upperBound, in: line),
                    text: String(line[candidate.range]),
                    replacement: candidate.replacement
                )
            }
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

    private static func regexPattern(for pattern: String, options: RipgrepOptions) -> String {
        var source = foundationNamedCapturePattern(for: pattern)
        if source == ")(" {
            source = ""
        }
        let isEmptyPattern = source.isEmpty
        if source.isEmpty {
            source = "(?:)"
        }
        if options.noUnicode {
            source = asciiPOSIXClasses(for: source)
            source = asciiRegexPattern(for: source)
        }
        if options.noUnicode && options.effectiveIgnoreCase {
            source = asciiCaseInsensitivePattern(for: source)
        }
        if options.wordRegexp && !isEmptyPattern {
            source = options.noUnicode
                ? "(?<![0-9A-Za-z_])(?:\(source))(?![0-9A-Za-z_])"
                : "\\b(?:\(source))\\b"
        }
        if options.lineRegexp {
            source = "^(?:\(source))$"
        }
        if options.crlf {
            source = crlfAnchorPattern(for: source)
        } else if !options.multiline {
            source = strictLineEndPattern(for: source)
        }
        return source
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

    private static func defaultEngineUnsupportedFeature(in pattern: String) -> String? {
        var escaped = false
        var inClass = false
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                if character.isNumber {
                    return "backreferences"
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
               hasAnyPrefix(["(?=", "(?!", "(?<=", "(?<!", "(?>"], at: index, in: pattern) {
                return "look-around"
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private static func automaticEngineUnavailableMessage(unsupported: String) -> String {
        """
        regex could not be compiled with either the default regex engine or with PCRE2.

        default regex engine error:
        \(unsupported) is not supported by the default regex engine

        PCRE2 regex engine error:
        PCRE2 is not available in this build of ripgrep
        """
    }

    private static func hasAnyPrefix(_ prefixes: [String], at index: String.Index, in text: String) -> Bool {
        prefixes.contains { prefix in
            text[index...].hasPrefix(prefix)
        }
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
        let replacements = [
            "[:alnum:]": "0-9A-Za-z",
            "[:alpha:]": "A-Za-z",
            "[:blank:]": " \\t",
            "[:digit:]": "0-9",
            "[:lower:]": "a-z",
            "[:space:]": " \\t\\r\\n\\f",
            "[:upper:]": "A-Z",
            "[:word:]": "0-9A-Za-z_",
            "[:xdigit:]": "0-9A-Fa-f",
        ]
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

    private static func crlfAnchorPattern(for pattern: String) -> String {
        transformAnchors(in: pattern) { anchor in
            switch anchor {
            case "^":
                return "(?:^|(?<=\\r))"
            case "$":
                return "(?=\\r?$|\\r)"
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

    private func literalRanges(_ literal: String, in line: String) -> [Range<String.Index>] {
        let haystack = options.effectiveIgnoreCase ? Self.foldedCase(line, options: options) : line
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
        return options.encodingMode == .disabled
            ? prefix.unicodeScalars.count
            : prefix.utf8.count
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
            bytes += options.encodingMode == .disabled ? 1 : String(line[index]).utf8.count
        }
        return bytes == byteOffset ? line.endIndex : nil
    }

    private func isWordBounded(_ range: Range<String.Index>, in line: String) -> Bool {
        let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
        let after = range.upperBound == line.endIndex ? nil : line[range.upperBound]
        return !isWordCharacter(before) && !isWordCharacter(after)
    }

    private func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else {
            return false
        }
        if options.noUnicode {
            return character.isASCIIWordCharacter
        }
        return character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }
}

private extension String {
    func utf8RawScalars() -> String {
        String(data: Data(utf8), encoding: .isoLatin1) ?? self
    }

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
    case literal(String)
}
