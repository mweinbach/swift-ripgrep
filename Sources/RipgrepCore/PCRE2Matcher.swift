import Foundation

struct PCRE2Backend {
    static let versionDescription = "PCRE2-compatible Swift regex engine is available (libpcre2 is not linked; JIT is unavailable)"
}

final class PCRE2CompiledPattern {
    let source: String
    private let regex: NSRegularExpression

    init(pattern: String, options: RipgrepOptions) throws {
        self.source = pattern
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
            self.regex = try NSRegularExpression(pattern: pattern, options: regexOptions)
        } catch {
            throw RipgrepError.message(Self.compileErrorMessage(pattern: pattern, error: error))
        }
    }

    func matches(in text: String) -> [PCRE2Match] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Self.match(from: match, in: text)
        }
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
