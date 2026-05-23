import Foundation

public struct PatternMatcher {
    private let options: RipgrepOptions
    private let regex: NSRegularExpression?
    private let literal: String

    public init(options: RipgrepOptions) throws {
        guard let pattern = options.pattern, !pattern.isEmpty else {
            throw RipgrepError.emptyPattern
        }

        self.options = options
        self.literal = options.effectiveIgnoreCase ? pattern.lowercased() : pattern

        if options.fixedStrings {
            self.regex = nil
        } else {
            let source = Self.regexPattern(for: pattern, options: options)
            do {
                self.regex = try NSRegularExpression(
                    pattern: source,
                    options: options.effectiveIgnoreCase ? [.caseInsensitive] : []
                )
            } catch {
                throw RipgrepError.invalidRegex(error.localizedDescription)
            }
        }
    }

    public func matches(in line: String) -> [Range<String.Index>] {
        let ranges: [Range<String.Index>]
        if let regex {
            ranges = regex.matches(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ).compactMap { Range($0.range, in: line) }
        } else {
            ranges = literalRanges(in: line)
        }

        let filtered = ranges.filter { range in
            (!options.wordRegexp || isWordBounded(range, in: line))
                && (!options.lineRegexp || (range.lowerBound == line.startIndex && range.upperBound == line.endIndex))
        }
        return options.invertMatch ? (filtered.isEmpty ? [line.startIndex..<line.startIndex] : []) : filtered
    }

    private static func regexPattern(for pattern: String, options: RipgrepOptions) -> String {
        var source = pattern
        if options.wordRegexp {
            source = "\\b(?:\(source))\\b"
        }
        if options.lineRegexp {
            source = "^(?:\(source))$"
        }
        return source
    }

    private func literalRanges(in line: String) -> [Range<String.Index>] {
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
