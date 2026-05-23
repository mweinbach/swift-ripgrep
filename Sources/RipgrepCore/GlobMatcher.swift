import Foundation

public struct GlobMatcher: Equatable {
    public enum Decision: Equatable {
        case include
        case exclude
    }

    public struct Rule: Equatable {
        let pattern: String
        let decision: Decision
        let directoryOnly: Bool
        let anchored: Bool
        let basenameOnly: Bool

        init(pattern: String, decision: Decision) {
            var source = pattern
            let directoryOnly = source.hasSuffix("/")
            if directoryOnly {
                source.removeLast()
            }
            let anchored = source.hasPrefix("/")
            if anchored {
                source.removeFirst()
            }

            self.pattern = source
            self.decision = decision
            self.directoryOnly = directoryOnly
            self.anchored = anchored
            self.basenameOnly = !source.contains("/")
        }
    }

    private let rules: [Rule]
    private let requirePositiveMatch: Bool
    private let caseInsensitive: Bool

    public init(
        patterns: [String],
        overrideSemantics: Bool = false,
        caseInsensitive: Bool = false
    ) {
        var rules: [Rule] = []
        for raw in patterns {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            let isNegated = trimmed.hasPrefix("!")
            let pattern = isNegated ? String(trimmed.dropFirst()) : trimmed
            let decision: Decision
            if overrideSemantics {
                decision = isNegated ? .exclude : .include
            } else {
                decision = isNegated ? .include : .exclude
            }
            rules.append(Rule(pattern: pattern, decision: decision))
        }

        self.rules = rules
        self.requirePositiveMatch = overrideSemantics && rules.contains { $0.decision == .include }
        self.caseInsensitive = caseInsensitive
    }

    public var isEmpty: Bool {
        rules.isEmpty
    }

    public func allows(relativePath: String, isDirectory: Bool) -> Bool {
        if let decision = decision(relativePath: relativePath, isDirectory: isDirectory) {
            return decision == .include
        }
        return !requirePositiveMatch || isDirectory
    }

    public func decision(relativePath: String, isDirectory: Bool) -> Decision? {
        var decision: Decision?
        for rule in rules where matches(rule, relativePath: relativePath, isDirectory: isDirectory) {
            decision = rule.decision
        }
        return decision
    }

    private func matches(_ rule: Rule, relativePath: String, isDirectory: Bool) -> Bool {
        if rule.directoryOnly && !isDirectory {
            return false
        }
        if rule.pattern.isEmpty {
            return false
        }
        if rule.basenameOnly {
            return pathComponents(relativePath).contains { component in
                matchesGlob(rule.pattern, component)
            }
        }
        if rule.anchored {
            return matchesGlob(rule.pattern, relativePath)
        }
        return matchesGlob("**/\(rule.pattern)", relativePath) || matchesGlob(rule.pattern, relativePath)
    }

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private func matchesGlob(_ pattern: String, _ value: String) -> Bool {
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
                    source += ".*"
                    index = pattern.index(after: next)
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
}
