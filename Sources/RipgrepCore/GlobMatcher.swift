import Foundation

public struct GlobMatcher: Equatable {
    public enum Decision: Equatable {
        case include
        case exclude
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
        matchingRule(relativePath: relativePath, isDirectory: isDirectory)?.decision
    }

    public func matchingRule(relativePath: String, isDirectory: Bool) -> Rule? {
        guard let scopedPath = scopedPath(for: relativePath) else {
            return nil
        }
        var matchedRule: Rule?
        for rule in rules where matches(rule, relativePath: scopedPath, isDirectory: isDirectory) {
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

    private func matches(_ rule: Rule, relativePath: String, isDirectory: Bool) -> Bool {
        if rule.directoryOnly && !isDirectory {
            return false
        }
        if rule.pattern.isEmpty {
            return false
        }
        if rule.anchored {
            return matchesGlob(rule.pattern, relativePath, caseInsensitive: rule.caseInsensitive)
        }
        if rule.basenameOnly {
            if overrideSemantics, rule.decision == .include {
                guard let basename = pathComponents(relativePath).last else {
                    return false
                }
                return matchesGlob(rule.pattern, basename, caseInsensitive: rule.caseInsensitive)
            }
            return pathComponents(relativePath).contains { component in
                matchesGlob(rule.pattern, component, caseInsensitive: rule.caseInsensitive)
            }
        }
        if slashPatternsMatchAnywhere && !rule.anchored {
            return matchesGlob("**/\(rule.pattern)", relativePath, caseInsensitive: rule.caseInsensitive)
                || matchesGlob(rule.pattern, relativePath, caseInsensitive: rule.caseInsensitive)
        }
        return matchesGlob(rule.pattern, relativePath, caseInsensitive: rule.caseInsensitive)
    }

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private func matchesGlob(_ pattern: String, _ value: String, caseInsensitive: Bool) -> Bool {
        let regex = "^\(regexSource(for: pattern))$"
        let options: String.CompareOptions = caseInsensitive
            ? [.regularExpression, .caseInsensitive]
            : .regularExpression
        return value.range(of: regex, options: options) != nil
    }

    private func regexSource(for pattern: String) -> String {
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
