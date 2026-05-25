import Foundation

public struct GlobMatcher: Equatable {
    public enum Decision: Equatable {
        case include
        case exclude
    }

    fileprivate enum FastMatcher: Equatable {
        case any
        case exact(String)
        case prefix(String)
        case prefixSuffix(prefix: String, suffix: String)
        case suffix(String)
        case contains(String)
    }

    public struct Rule: Equatable {
        let originalPattern: String
        let pattern: String
        let actualPattern: String
        let decision: Decision
        let caseInsensitive: Bool
        let directoryOnly: Bool
        let anchored: Bool
        let basenameOnly: Bool
        let sourcePath: String?
        fileprivate let fastMatcher: FastMatcher?
        let regex: NSRegularExpression?
        let anywhereRegex: NSRegularExpression?

        init(pattern: String, decision: Decision, caseInsensitive: Bool, sourcePath: String?) {
            var source = pattern.replacingOccurrences(of: #"\/"#, with: "/")
            let directoryOnly = source.hasSuffix("/")
            if directoryOnly {
                source.removeLast()
            }
            let anchored = source.hasPrefix("/")
            if anchored {
                source.removeFirst()
            }

            let basenameOnly = !source.contains("/")
            var actual = source
            if !anchored && basenameOnly && !actual.hasPrefix("**/") {
                actual = "**/\(actual)"
            }
            if actual.hasSuffix("/**") {
                actual = "\(actual)/*"
            }

            self.originalPattern = pattern
            self.pattern = source
            self.actualPattern = actual
            self.decision = decision
            self.caseInsensitive = caseInsensitive
            self.directoryOnly = directoryOnly
            self.anchored = anchored
            self.basenameOnly = basenameOnly
            self.sourcePath = sourcePath
            self.fastMatcher = GlobMatcher.compileFastMatcher(source, basenameOnly: basenameOnly, caseInsensitive: caseInsensitive)
            self.regex = GlobMatcher.compileGlobRegex(source, caseInsensitive: caseInsensitive)
            self.anywhereRegex = GlobMatcher.compileGlobRegex("**/\(source)", caseInsensitive: caseInsensitive)
        }

        static public func == (lhs: Rule, rhs: Rule) -> Bool {
            lhs.originalPattern == rhs.originalPattern
                && lhs.pattern == rhs.pattern
                && lhs.actualPattern == rhs.actualPattern
                && lhs.decision == rhs.decision
                && lhs.caseInsensitive == rhs.caseInsensitive
                && lhs.directoryOnly == rhs.directoryOnly
                && lhs.anchored == rhs.anchored
                && lhs.basenameOnly == rhs.basenameOnly
                && lhs.sourcePath == rhs.sourcePath
                && lhs.fastMatcher == rhs.fastMatcher
        }
    }

    private let rules: [Rule]
    private let requirePositiveMatch: Bool
    private let slashPatternsMatchAnywhere: Bool
    private let stripBasePath: String?
    private let pathPrefix: String
    private let overrideSemantics: Bool

    public init(
        patterns: [String],
        overrideSemantics: Bool = false,
        caseInsensitive: Bool = false,
        stripBasePath: String? = nil,
        pathPrefix: String = "",
        slashPatternsMatchAnywhere: Bool? = nil,
        sourcePath: String? = nil
    ) {
        self.init(
            patternEntries: patterns.map { ($0, caseInsensitive) },
            overrideSemantics: overrideSemantics,
            stripBasePath: stripBasePath,
            pathPrefix: pathPrefix,
            slashPatternsMatchAnywhere: slashPatternsMatchAnywhere,
            sourcePath: sourcePath
        )
    }

    public init(
        patternEntries: [(pattern: String, caseInsensitive: Bool)],
        overrideSemantics: Bool = false,
        stripBasePath: String? = nil,
        pathPrefix: String = "",
        slashPatternsMatchAnywhere: Bool? = nil,
        sourcePath: String? = nil
    ) {
        var rules: [Rule] = []
        for entry in patternEntries {
            let raw = entry.pattern
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            let normalized = Self.unescapeLeadingCommentOrNegation(trimmed)
            let isNegated = !normalized.wasEscaped && normalized.pattern.hasPrefix("!")
            let pattern = isNegated ? String(normalized.pattern.dropFirst()) : normalized.pattern
            let decision: Decision
            if overrideSemantics {
                decision = isNegated ? .exclude : .include
            } else {
                decision = isNegated ? .include : .exclude
            }
            rules.append(Rule(
                pattern: pattern,
                decision: decision,
                caseInsensitive: entry.caseInsensitive,
                sourcePath: sourcePath
            ))
        }

        self.rules = rules
        self.requirePositiveMatch = overrideSemantics && rules.contains { $0.decision == .include }
        self.overrideSemantics = overrideSemantics
        self.slashPatternsMatchAnywhere = slashPatternsMatchAnywhere ?? !overrideSemantics
        self.stripBasePath = stripBasePath?.isEmpty == true ? nil : stripBasePath
        self.pathPrefix = pathPrefix
    }

    public var isEmpty: Bool {
        rules.isEmpty
    }

    private static func unescapeLeadingCommentOrNegation(_ pattern: String) -> (pattern: String, wasEscaped: Bool) {
        guard pattern.hasPrefix("\\#") || pattern.hasPrefix("\\!") else {
            return (pattern, false)
        }
        return (String(pattern.dropFirst()), true)
    }

    public func allows(relativePath: String, isDirectory: Bool) -> Bool {
        if let decision = decision(relativePath: relativePath, isDirectory: isDirectory) {
            return decision == .include
        }
        return !requirePositiveMatch || isDirectory
    }

    public func decision(relativePath: String, isDirectory: Bool) -> Decision? {
        guard let scopedPath = scopedPath(for: relativePath) else {
            return nil
        }
        let pathBasename = basename(scopedPath)
        var matchedDecision: Decision?
        for rule in rules where matches(rule, relativePath: scopedPath, basename: pathBasename, isDirectory: isDirectory) {
            matchedDecision = rule.decision
        }
        return matchedDecision
    }

    public func matchingRule(relativePath: String, isDirectory: Bool) -> Rule? {
        guard let scopedPath = scopedPath(for: relativePath) else {
            return nil
        }
        let pathBasename = basename(scopedPath)
        var matchedRule: Rule?
        for rule in rules where matches(rule, relativePath: scopedPath, basename: pathBasename, isDirectory: isDirectory) {
            matchedRule = rule
        }
        return matchedRule
    }

    private func scopedPath(for relativePath: String) -> String? {
        var path = relativePath
        if let stripBasePath {
            if path == stripBasePath {
                path = ""
            } else {
                let prefix = "\(stripBasePath)/"
                guard path.hasPrefix(prefix) else {
                    return nil
                }
                path = String(path.dropFirst(prefix.count))
            }
        }
        if !pathPrefix.isEmpty {
            path = path.isEmpty ? pathPrefix : "\(pathPrefix)/\(path)"
        }
        return path
    }

    private func matches(_ rule: Rule, relativePath: String, basename pathBasename: String?, isDirectory: Bool) -> Bool {
        if rule.directoryOnly && !isDirectory {
            return false
        }
        if rule.pattern.isEmpty {
            return false
        }
        if rule.anchored {
            return matchesGlob(rule, relativePath)
        }
        if rule.basenameOnly {
            guard let pathBasename else {
                return false
            }
            return matchesGlob(rule, pathBasename)
        }
        if slashPatternsMatchAnywhere && !rule.anchored {
            return matchesGlobAnywhere(rule, relativePath) || matchesGlob(rule, relativePath)
        }
        return matchesGlob(rule, relativePath)
    }

    private func basename(_ path: String) -> String? {
        guard !path.isEmpty else {
            return nil
        }
        guard let slash = path.lastIndex(of: "/") else {
            return path
        }
        let next = path.index(after: slash)
        guard next < path.endIndex else {
            return nil
        }
        return String(path[next...])
    }

    private func matchesGlob(_ rule: Rule, _ value: String) -> Bool {
        if let fastMatcher = rule.fastMatcher {
            return matchesFast(fastMatcher, value)
        }
        guard let regex = rule.regex else {
            return false
        }
        return matches(regex, value)
    }

    private func matchesGlobAnywhere(_ rule: Rule, _ value: String) -> Bool {
        if let fastMatcher = rule.fastMatcher, matchesFastAnywhere(fastMatcher, value) {
            return true
        }
        guard let regex = rule.anywhereRegex else {
            return false
        }
        return matches(regex, value)
    }

    private func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    private func matchesFast(_ matcher: FastMatcher, _ value: String) -> Bool {
        switch matcher {
        case .any:
            return true
        case .exact(let expected):
            return value == expected
        case .prefix(let prefix):
            return value.hasPrefix(prefix)
        case .prefixSuffix(let prefix, let suffix):
            return value.hasPrefix(prefix) && value.hasSuffix(suffix)
        case .suffix(let suffix):
            return value.hasSuffix(suffix)
        case .contains(let needle):
            return value.contains(needle)
        }
    }

    private func matchesFastAnywhere(_ matcher: FastMatcher, _ value: String) -> Bool {
        if matchesFast(matcher, value) {
            return true
        }
        switch matcher {
        case .exact(let expected):
            return value.hasSuffix("/\(expected)")
        case .any:
            return true
        case .prefix, .prefixSuffix, .suffix, .contains:
            var cursor = value.startIndex
            while let slash = value[cursor...].firstIndex(of: "/") {
                let next = value.index(after: slash)
                guard next < value.endIndex else {
                    return false
                }
                if matchesFast(matcher, String(value[next...])) {
                    return true
                }
                cursor = next
            }
            return false
        }
    }

    private static func compileFastMatcher(
        _ pattern: String,
        basenameOnly: Bool,
        caseInsensitive: Bool
    ) -> FastMatcher? {
        guard !caseInsensitive else {
            return nil
        }
        let metaCharacters = CharacterSet(charactersIn: "?[]{}\\")
        guard pattern.rangeOfCharacter(from: metaCharacters) == nil else {
            return nil
        }
        let starCount = pattern.reduce(0) { count, character in
            character == "*" ? count + 1 : count
        }
        if starCount == 0 {
            return .exact(pattern)
        }
        guard basenameOnly else {
            return nil
        }
        if pattern == "*" {
            return .any
        }
        if starCount == 1, pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return suffix.isEmpty ? .any : .suffix(suffix)
        }
        if starCount == 1, pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return prefix.isEmpty ? .any : .prefix(prefix)
        }
        if starCount == 1, let star = pattern.firstIndex(of: "*") {
            let prefix = String(pattern[..<star])
            let suffix = String(pattern[pattern.index(after: star)...])
            if !prefix.isEmpty, !suffix.isEmpty {
                return .prefixSuffix(prefix: prefix, suffix: suffix)
            }
        }
        if starCount == 2, pattern.hasPrefix("*"), pattern.hasSuffix("*") {
            let needle = pattern.dropFirst().dropLast()
            return needle.isEmpty ? .any : .contains(String(needle))
        }
        return nil
    }

    private static func compileGlobRegex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        return try? NSRegularExpression(pattern: "^\(regexSource(for: pattern))$", options: options)
    }

    private static func regexSource(for pattern: String) -> String {
        var source = ""
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterGlobstar = pattern.index(after: next)
                    if afterGlobstar < pattern.endIndex, pattern[afterGlobstar] == "/" {
                        source += "(?:.*/)?"
                        index = pattern.index(after: afterGlobstar)
                    } else {
                        source += ".*"
                        index = afterGlobstar
                    }
                } else {
                    source += "[^/]*"
                    index = next
                }
            } else if character == "?" {
                source += "[^/]"
                index = pattern.index(after: index)
            } else if character == "[", let close = pattern[index...].firstIndex(of: "]") {
                let afterOpen = pattern.index(after: index)
                if afterOpen < close {
                    source += String(pattern[index...close])
                    index = pattern.index(after: close)
                } else {
                    source += "\\["
                    index = afterOpen
                }
            } else if character == "{", let close = pattern[index...].firstIndex(of: "}") {
                let afterOpen = pattern.index(after: index)
                if afterOpen < close {
                    let body = String(pattern[afterOpen..<close])
                    let alternatives = body
                        .split(separator: ",", omittingEmptySubsequences: false)
                        .map { regexSource(for: String($0)) }
                        .joined(separator: "|")
                    source += "(?:\(alternatives))"
                    index = pattern.index(after: close)
                } else {
                    source += "\\{"
                    index = afterOpen
                }
            } else {
                source += NSRegularExpression.escapedPattern(for: String(character))
                index = pattern.index(after: index)
            }
        }

        return source
    }
}

public struct IgnoreStack {
    private var matchers: [GlobMatcher] = []

    public init() {}

    public var isEmpty: Bool {
        matchers.allSatisfy(\.isEmpty)
    }

    public mutating func append(_ matcher: GlobMatcher) {
        if !matcher.isEmpty {
            matchers.append(matcher)
        }
    }

    public func allows(relativePath: String, isDirectory: Bool) -> Bool {
        var allowed = true
        for matcher in matchers {
            if let decision = matcher.decision(relativePath: relativePath, isDirectory: isDirectory) {
                allowed = decision == .include
            }
        }
        return allowed
    }

    public func decision(relativePath: String, isDirectory: Bool) -> GlobMatcher.Decision? {
        matchingRule(relativePath: relativePath, isDirectory: isDirectory)?.decision
    }

    public func matchingRule(relativePath: String, isDirectory: Bool) -> GlobMatcher.Rule? {
        var matchedRule: GlobMatcher.Rule?
        for matcher in matchers {
            if let rule = matcher.matchingRule(relativePath: relativePath, isDirectory: isDirectory) {
                matchedRule = rule
            }
        }
        return matchedRule
    }
}
