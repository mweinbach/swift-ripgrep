package enum RegexLiteralParser {
    package static func literal(
        fromPlainRegexPattern pattern: String,
        allowPCREQuotedLiterals: Bool = false
    ) -> String? {
        guard !pattern.isEmpty else {
            return nil
        }

        var literal = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "\\" {
                let escapedIndex = pattern.index(after: index)
                guard escapedIndex < pattern.endIndex else {
                    return nil
                }
                let escaped = pattern[escapedIndex]
                if allowPCREQuotedLiterals, escaped == "Q" {
                    var quotedIndex = pattern.index(after: escapedIndex)
                    var closedQuote = false
                    while quotedIndex < pattern.endIndex {
                        let quotedCharacter = pattern[quotedIndex]
                        if quotedCharacter == "\\" {
                            let quoteEscapeIndex = pattern.index(after: quotedIndex)
                            if quoteEscapeIndex < pattern.endIndex,
                               pattern[quoteEscapeIndex] == "E" {
                                index = pattern.index(after: quoteEscapeIndex)
                                closedQuote = true
                                break
                            }
                        }
                        literal.append(quotedCharacter)
                        quotedIndex = pattern.index(after: quotedIndex)
                    }
                    guard closedQuote else {
                        return nil
                    }
                    continue
                }
                guard escapableLiteralCharacters.contains(escaped) else {
                    return nil
                }
                literal.append(escaped)
                index = pattern.index(after: escapedIndex)
                continue
            }
            guard !regexSyntaxCharacters.contains(character) else {
                return nil
            }
            literal.append(character)
            index = pattern.index(after: index)
        }

        return literal.isEmpty ? nil : literal
    }

    package static func firstUnescapedResetStart(in pattern: String) -> Range<String.Index>? {
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

    package static func topLevelAlternatives(in pattern: String) -> [String] {
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

    private static let regexSyntaxCharacters = Set("\\.[]{}()+*?^$|")
    private static let escapableLiteralCharacters = Set("\\.[]{}()+*?^$|")
}
