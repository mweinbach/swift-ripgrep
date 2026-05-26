package enum RegexLiteralParser {
    package static func literal(fromPlainRegexPattern pattern: String) -> String? {
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
