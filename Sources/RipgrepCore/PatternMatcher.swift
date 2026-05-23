import Foundation

public struct PatternMatcher {
    private let options: RipgrepOptions
    private let patterns: [CompiledPattern]

    public init(options: RipgrepOptions) throws {
        let patternSources = options.effectivePatterns
        guard !patternSources.isEmpty, patternSources.allSatisfy({ !$0.isEmpty }) else {
            throw RipgrepError.emptyPattern
        }

        self.options = options
        self.patterns = try patternSources.map { pattern in
            if options.fixedStrings {
                return .literal(options.effectiveIgnoreCase ? pattern.lowercased() : pattern)
            } else {
                let source = Self.regexPattern(for: pattern, options: options)
                do {
                    var regexOptions: NSRegularExpression.Options = options.effectiveIgnoreCase ? [.caseInsensitive] : []
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

    public func matches(in line: String) -> [Range<String.Index>] {
        spans(in: line).compactMap { span in
            indexRange(for: span, in: line)
        }
    }

    public func spans(in line: String) -> [MatchSpan] {
        var candidates: [(range: Range<String.Index>, replacement: String?)] = []
        for pattern in patterns {
            switch pattern {
            case .regex(let regex):
                let matches = regex.matches(
                    in: line,
                    range: NSRange(line.startIndex..., in: line)
                )
                candidates.append(contentsOf: matches.compactMap { match in
                    guard let range = Range(match.range, in: line) else {
                        return nil
                    }
                    let replacement = options.replacement.map {
                        regex.replacementString(for: match, in: line, offset: 0, template: $0)
                    }
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

        return filtered
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

    private static func regexPattern(for pattern: String, options: RipgrepOptions) -> String {
        var source = pattern
        if options.wordRegexp {
            source = "\\b(?:\(source))\\b"
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
        let haystack = options.effectiveIgnoreCase ? line.lowercased() : line
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

    private func replacement(for range: Range<String.Index>, in line: String) -> String? {
        guard let replacement = options.replacement else {
            return nil
        }
        return replacement.replacingOccurrences(of: "$0", with: String(line[range]))
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
        guard span.startColumn >= 1, span.endColumn >= span.startColumn else {
            return nil
        }
        let lowerOffset = span.startColumn - 1
        let upperOffset = span.endColumn - 1
        guard lowerOffset <= line.count, upperOffset <= line.count else {
            return nil
        }
        let lower = line.index(line.startIndex, offsetBy: lowerOffset)
        let upper = line.index(line.startIndex, offsetBy: upperOffset)
        return lower..<upper
    }

    private func column(for index: String.Index, in line: String) -> Int {
        line.distance(from: line.startIndex, to: index) + 1
    }

    private func byteOffset(for index: String.Index, in line: String) -> Int {
        line[line.startIndex..<index].utf8.count
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
        return character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }
}

private enum CompiledPattern {
    case regex(NSRegularExpression)
    case literal(String)
}
