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

    private static let regexSyntaxCharacters = Set("\\.[]{}()+*?^$|")
    private static let escapableLiteralCharacters = Set("\\.[]{}()+*?^$|")
}
