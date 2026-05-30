import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        case simpleGlob(SimpleGlob)
    }

    fileprivate struct SimpleGlob: Equatable {
        enum Token: Equatable {
            case literal(UInt8)
            case any
            case star
            case charClass([ClosedRange<UInt8>], negated: Bool)
        }

        let tokens: [Token]
    }

    private struct FastMatcherPatternMeta {
        let hasUnsupportedMeta: Bool
        let hasQuestionOrClassMeta: Bool
        let starCount: Int

        var hasAnyGlobMeta: Bool {
            hasQuestionOrClassMeta || starCount > 0
        }
    }

    #if canImport(Darwin)
    private struct IndexedRule: Equatable {
        let ruleIndex: Int
        let decision: Decision
        let directoryOnly: Bool
    }

    private struct IndexedTextRule: Equatable {
        let rule: IndexedRule
        let text: String
    }

    private struct IndexedPrefixSuffixRule: Equatable {
        let rule: IndexedRule
        let prefix: String
        let suffix: String
    }

    private final class FastRuleIndex: Equatable {
        let indexedRuleCount: Int
        let exactPathRules: [String: [IndexedRule]]
        let suffixPathRulesByLastByte: [UInt8: [IndexedTextRule]]
        let exactBasenameRules: [String: [IndexedRule]]
        let suffixBasenameRulesByLastByte: [UInt8: [IndexedTextRule]]
        let prefixBasenameRulesByFirstByte: [UInt8: [IndexedTextRule]]
        let prefixSuffixBasenameRulesByFirstByte: [UInt8: [IndexedPrefixSuffixRule]]
        let containsBasenameRules: [IndexedTextRule]
        let anyBasenameRules: [IndexedRule]
        let unindexedRuleIndicesDescending: [Int]

        init(
            indexedRuleCount: Int,
            exactPathRules: [String: [IndexedRule]],
            suffixPathRulesByLastByte: [UInt8: [IndexedTextRule]],
            exactBasenameRules: [String: [IndexedRule]],
            suffixBasenameRulesByLastByte: [UInt8: [IndexedTextRule]],
            prefixBasenameRulesByFirstByte: [UInt8: [IndexedTextRule]],
            prefixSuffixBasenameRulesByFirstByte: [UInt8: [IndexedPrefixSuffixRule]],
            containsBasenameRules: [IndexedTextRule],
            anyBasenameRules: [IndexedRule],
            unindexedRuleIndicesDescending: [Int]
        ) {
            self.indexedRuleCount = indexedRuleCount
            self.exactPathRules = exactPathRules
            self.suffixPathRulesByLastByte = suffixPathRulesByLastByte
            self.exactBasenameRules = exactBasenameRules
            self.suffixBasenameRulesByLastByte = suffixBasenameRulesByLastByte
            self.prefixBasenameRulesByFirstByte = prefixBasenameRulesByFirstByte
            self.prefixSuffixBasenameRulesByFirstByte = prefixSuffixBasenameRulesByFirstByte
            self.containsBasenameRules = containsBasenameRules
            self.anyBasenameRules = anyBasenameRules
            self.unindexedRuleIndicesDescending = unindexedRuleIndicesDescending
        }

        static func == (lhs: FastRuleIndex, rhs: FastRuleIndex) -> Bool {
            lhs === rhs || (
                lhs.indexedRuleCount == rhs.indexedRuleCount
                    && lhs.exactPathRules == rhs.exactPathRules
                    && lhs.suffixPathRulesByLastByte == rhs.suffixPathRulesByLastByte
                    && lhs.exactBasenameRules == rhs.exactBasenameRules
                    && lhs.suffixBasenameRulesByLastByte == rhs.suffixBasenameRulesByLastByte
                    && lhs.prefixBasenameRulesByFirstByte == rhs.prefixBasenameRulesByFirstByte
                    && lhs.prefixSuffixBasenameRulesByFirstByte == rhs.prefixSuffixBasenameRulesByFirstByte
                    && lhs.containsBasenameRules == rhs.containsBasenameRules
                    && lhs.anyBasenameRules == rhs.anyBasenameRules
                    && lhs.unindexedRuleIndicesDescending == rhs.unindexedRuleIndicesDescending
            )
        }
    }
    #endif

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

        init(
            pattern: String,
            decision: Decision,
            caseInsensitive: Bool,
            sourcePath: String?,
            compileAnywhereRegex: Bool
        ) {
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
            let fastMatcher = GlobMatcher.compileFastMatcher(source, basenameOnly: basenameOnly, caseInsensitive: caseInsensitive)
            let needsRegexFallback: Bool
            if fastMatcher != nil {
                needsRegexFallback = false
            } else {
                needsRegexFallback = true
            }
            self.fastMatcher = fastMatcher
            self.regex = needsRegexFallback ? GlobMatcher.compileGlobRegex(source, caseInsensitive: caseInsensitive) : nil
            self.anywhereRegex = needsRegexFallback && compileAnywhereRegex
                ? GlobMatcher.compileGlobRegex("**/\(source)", caseInsensitive: caseInsensitive)
                : nil
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
    private let hasBasenameOnlyRules: Bool
    private let allRulesUnanchoredBasenameOnly: Bool
    private let hasIncludeRules: Bool
    private let slashPatternsMatchAnywhere: Bool
    private let stripBasePath: String?
    private let stripBasePathPrefix: String?
    private let pathPrefix: String
    private let isUnscoped: Bool
    private let overrideSemantics: Bool
    #if canImport(Darwin)
    private let fastRuleIndex: FastRuleIndex?
    #endif

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
        let resolvedSlashPatternsMatchAnywhere = slashPatternsMatchAnywhere ?? !overrideSemantics
        var rules: [Rule] = []
        var lastPattern: String?
        var lastDecision: Decision?
        var lastCaseInsensitive: Bool?
        var hasIncludeRules = false
        var hasBasenameOnlyRules = false
        var allRulesUnanchoredBasenameOnly = true
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
            if pattern == lastPattern,
               decision == lastDecision,
               entry.caseInsensitive == lastCaseInsensitive {
                continue
            }
            let rule = Rule(
                pattern: pattern,
                decision: decision,
                caseInsensitive: entry.caseInsensitive,
                sourcePath: sourcePath,
                compileAnywhereRegex: resolvedSlashPatternsMatchAnywhere
            )
            rules.append(rule)
            hasIncludeRules = hasIncludeRules || decision == .include
            hasBasenameOnlyRules = hasBasenameOnlyRules || rule.basenameOnly
            allRulesUnanchoredBasenameOnly = allRulesUnanchoredBasenameOnly && rule.basenameOnly && !rule.anchored
            lastPattern = pattern
            lastDecision = decision
            lastCaseInsensitive = entry.caseInsensitive
        }

        self.rules = rules
        self.requirePositiveMatch = overrideSemantics && hasIncludeRules
        self.hasBasenameOnlyRules = hasBasenameOnlyRules
        self.allRulesUnanchoredBasenameOnly = !rules.isEmpty && allRulesUnanchoredBasenameOnly
        self.hasIncludeRules = hasIncludeRules
        self.overrideSemantics = overrideSemantics
        self.slashPatternsMatchAnywhere = resolvedSlashPatternsMatchAnywhere
        self.stripBasePath = stripBasePath?.isEmpty == true ? nil : stripBasePath
        self.stripBasePathPrefix = self.stripBasePath.map { "\($0)/" }
        self.pathPrefix = pathPrefix
        self.isUnscoped = self.stripBasePath == nil && pathPrefix.isEmpty
        #if canImport(Darwin)
        if rules.count >= 4 {
            let fastRuleIndex = Self.makeFastRuleIndex(
                for: rules,
                slashPatternsMatchAnywhere: resolvedSlashPatternsMatchAnywhere
            )
            self.fastRuleIndex = fastRuleIndex.indexedRuleCount >= 4
                && fastRuleIndex.indexedRuleCount >= fastRuleIndex.unindexedRuleIndicesDescending.count
                ? fastRuleIndex
                : nil
        } else {
            self.fastRuleIndex = nil
        }
        #endif
    }

    public var isEmpty: Bool {
        rules.isEmpty
    }

    public var canInclude: Bool {
        hasIncludeRules
    }

    public var excludesOnlyHiddenPaths: Bool {
        guard !rules.isEmpty else {
            return false
        }
        return rules.allSatisfy { rule in
            rule.decision == .exclude && Self.patternMatchesOnlyHiddenPaths(rule.originalPattern)
        }
    }

    private static func unescapeLeadingCommentOrNegation(_ pattern: String) -> (pattern: String, wasEscaped: Bool) {
        guard pattern.hasPrefix("\\#") || pattern.hasPrefix("\\!") else {
            return (pattern, false)
        }
        return (String(pattern.dropFirst()), true)
    }

    private static func patternMatchesOnlyHiddenPaths(_ pattern: String) -> Bool {
        var source = pattern.replacingOccurrences(of: #"\/"#, with: "/")
        if source.hasSuffix("/") {
            source.removeLast()
        }
        if source.hasPrefix("/") {
            source.removeFirst()
        }
        return source.split(separator: "/", omittingEmptySubsequences: false).contains { component in
            component.first == "."
        }
    }

    public func allows(relativePath: String, isDirectory: Bool) -> Bool {
        if let decision = decision(relativePath: relativePath, isDirectory: isDirectory) {
            return decision == .include
        }
        return !requirePositiveMatch || isDirectory
    }

    public func decision(relativePath: String, isDirectory: Bool) -> Decision? {
        decision(relativePath: relativePath, basename: nil, isDirectory: isDirectory)
    }

    public func decision(relativePath: String, basename pathBasename: String?, isDirectory: Bool) -> Decision? {
        let scopedRelativePath: String
        if isUnscoped || canUseUnscopedBasename(relativePath: relativePath) {
            scopedRelativePath = relativePath
        } else {
            guard let path = scopedPath(for: relativePath) else {
                return nil
            }
            scopedRelativePath = path
        }
        #if canImport(Darwin)
        let pathBasename = hasBasenameOnlyRules ? (pathBasename ?? basename(scopedRelativePath)) : nil
        if let fastRuleIndex {
            return fastDecision(
                relativePath: scopedRelativePath,
                basename: pathBasename,
                isDirectory: isDirectory,
                fastRuleIndex: fastRuleIndex
            )
        }
        #else
        let pathBasename = pathBasename ?? basename(scopedRelativePath)
        #endif
        return reverseDecision(relativePath: scopedRelativePath, basename: pathBasename, isDirectory: isDirectory)
    }

    private func reverseDecision(relativePath: String, basename pathBasename: String?, isDirectory: Bool) -> Decision? {
        var matchedDecision: Decision?
        rules.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var offset = buffer.count
            while offset > 0 {
                offset -= 1
                let rule = baseAddress.advanced(by: offset)
                if matches(rule, relativePath: relativePath, basename: pathBasename, isDirectory: isDirectory) {
                    matchedDecision = rule.pointee.decision
                    return
                }
            }
        }
        return matchedDecision
    }

    #if canImport(Darwin)
    private static func makeFastRuleIndex(
        for rules: [Rule],
        slashPatternsMatchAnywhere: Bool
    ) -> FastRuleIndex {
        var exactPathRules: [String: [IndexedRule]] = [:]
        var suffixPathRulesByLastByte: [UInt8: [IndexedTextRule]] = [:]
        var exactBasenameRules: [String: [IndexedRule]] = [:]
        var suffixBasenameRulesByLastByte: [UInt8: [IndexedTextRule]] = [:]
        var prefixBasenameRulesByFirstByte: [UInt8: [IndexedTextRule]] = [:]
        var prefixSuffixBasenameRulesByFirstByte: [UInt8: [IndexedPrefixSuffixRule]] = [:]
        var containsBasenameRules: [IndexedTextRule] = []
        var anyBasenameRules: [IndexedRule] = []
        var unindexedRuleIndices: [Int] = []
        var indexedRuleCount = 0

        for (ruleIndex, rule) in rules.enumerated() {
            let indexedRule = IndexedRule(
                ruleIndex: ruleIndex,
                decision: rule.decision,
                directoryOnly: rule.directoryOnly
            )
            guard let fastMatcher = rule.fastMatcher else {
                unindexedRuleIndices.append(ruleIndex)
                continue
            }
            if rule.anchored {
                if case .exact = fastMatcher {
                    exactPathRules[rule.pattern, default: []].append(indexedRule)
                    indexedRuleCount += 1
                } else {
                    unindexedRuleIndices.append(ruleIndex)
                }
                continue
            }
            if !rule.basenameOnly {
                if case .exact(let expected) = fastMatcher {
                    exactPathRules[expected, default: []].append(indexedRule)
                    if slashPatternsMatchAnywhere,
                       let lastByte = expected.utf8.last {
                        suffixPathRulesByLastByte[lastByte, default: []].append(IndexedTextRule(
                            rule: indexedRule,
                            text: expected
                        ))
                    }
                    indexedRuleCount += 1
                } else {
                    unindexedRuleIndices.append(ruleIndex)
                }
                continue
            }

            switch fastMatcher {
            case .any:
                anyBasenameRules.append(indexedRule)
                indexedRuleCount += 1
            case .exact(let expected):
                exactBasenameRules[expected, default: []].append(indexedRule)
                indexedRuleCount += 1
            case .suffix(let suffix):
                guard let lastByte = suffix.utf8.last else {
                    anyBasenameRules.append(indexedRule)
                    indexedRuleCount += 1
                    continue
                }
                suffixBasenameRulesByLastByte[lastByte, default: []].append(IndexedTextRule(
                    rule: indexedRule,
                    text: suffix
                ))
                indexedRuleCount += 1
            case .prefix(let prefix):
                guard let firstByte = prefix.utf8.first else {
                    anyBasenameRules.append(indexedRule)
                    indexedRuleCount += 1
                    continue
                }
                prefixBasenameRulesByFirstByte[firstByte, default: []].append(IndexedTextRule(
                    rule: indexedRule,
                    text: prefix
                ))
                indexedRuleCount += 1
            case .prefixSuffix(let prefix, let suffix):
                guard let firstByte = prefix.utf8.first else {
                    unindexedRuleIndices.append(ruleIndex)
                    continue
                }
                prefixSuffixBasenameRulesByFirstByte[firstByte, default: []].append(IndexedPrefixSuffixRule(
                    rule: indexedRule,
                    prefix: prefix,
                    suffix: suffix
                ))
                indexedRuleCount += 1
            case .contains(let needle):
                containsBasenameRules.append(IndexedTextRule(rule: indexedRule, text: needle))
                indexedRuleCount += 1
            case .simpleGlob:
                unindexedRuleIndices.append(ruleIndex)
            }
        }

        return FastRuleIndex(
            indexedRuleCount: indexedRuleCount,
            exactPathRules: exactPathRules,
            suffixPathRulesByLastByte: suffixPathRulesByLastByte,
            exactBasenameRules: exactBasenameRules,
            suffixBasenameRulesByLastByte: suffixBasenameRulesByLastByte,
            prefixBasenameRulesByFirstByte: prefixBasenameRulesByFirstByte,
            prefixSuffixBasenameRulesByFirstByte: prefixSuffixBasenameRulesByFirstByte,
            containsBasenameRules: containsBasenameRules,
            anyBasenameRules: anyBasenameRules,
            unindexedRuleIndicesDescending: Array(unindexedRuleIndices.reversed())
        )
    }

    private func fastDecision(
        relativePath: String,
        basename pathBasename: String?,
        isDirectory: Bool,
        fastRuleIndex: FastRuleIndex
    ) -> Decision? {
        var bestRuleIndex = -1
        var bestDecision: Decision?
        considerIndexedRules(
            fastRuleIndex.exactPathRules[relativePath],
            isDirectory: isDirectory,
            bestRuleIndex: &bestRuleIndex,
            bestDecision: &bestDecision
        )
        if !fastRuleIndex.suffixPathRulesByLastByte.isEmpty,
           let lastByte = relativePath.utf8.last,
           let suffixPathRules = fastRuleIndex.suffixPathRulesByLastByte[lastByte] {
            for candidate in suffixPathRules where hasPathComponentSuffix(candidate.text, in: relativePath) {
                considerIndexedRule(
                    candidate.rule,
                    isDirectory: isDirectory,
                    bestRuleIndex: &bestRuleIndex,
                    bestDecision: &bestDecision
                )
            }
        }

        if let pathBasename {
            considerIndexedRules(
                fastRuleIndex.exactBasenameRules[pathBasename],
                isDirectory: isDirectory,
                bestRuleIndex: &bestRuleIndex,
                bestDecision: &bestDecision
            )

            if let lastByte = pathBasename.utf8.last,
               let suffixRules = fastRuleIndex.suffixBasenameRulesByLastByte[lastByte] {
                for candidate in suffixRules where pathBasename.hasSuffix(candidate.text) {
                    considerIndexedRule(
                        candidate.rule,
                        isDirectory: isDirectory,
                        bestRuleIndex: &bestRuleIndex,
                        bestDecision: &bestDecision
                    )
                }
            }

            if let firstByte = pathBasename.utf8.first {
                if let prefixRules = fastRuleIndex.prefixBasenameRulesByFirstByte[firstByte] {
                    for candidate in prefixRules where pathBasename.hasPrefix(candidate.text) {
                        considerIndexedRule(
                            candidate.rule,
                            isDirectory: isDirectory,
                            bestRuleIndex: &bestRuleIndex,
                            bestDecision: &bestDecision
                        )
                    }
                }
                if let prefixSuffixRules = fastRuleIndex.prefixSuffixBasenameRulesByFirstByte[firstByte] {
                    for candidate in prefixSuffixRules
                    where pathBasename.hasPrefix(candidate.prefix) && pathBasename.hasSuffix(candidate.suffix) {
                        considerIndexedRule(
                            candidate.rule,
                            isDirectory: isDirectory,
                            bestRuleIndex: &bestRuleIndex,
                            bestDecision: &bestDecision
                        )
                    }
                }
            }

            for candidate in fastRuleIndex.containsBasenameRules where containsFast(candidate.text, in: pathBasename) {
                considerIndexedRule(
                    candidate.rule,
                    isDirectory: isDirectory,
                    bestRuleIndex: &bestRuleIndex,
                    bestDecision: &bestDecision
                )
            }
            considerIndexedRules(
                fastRuleIndex.anyBasenameRules,
                isDirectory: isDirectory,
                bestRuleIndex: &bestRuleIndex,
                bestDecision: &bestDecision
            )
        }

        var resolvedDecision = bestDecision
        rules.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            for ruleIndex in fastRuleIndex.unindexedRuleIndicesDescending {
                if ruleIndex <= bestRuleIndex {
                    break
                }
                let rule = baseAddress.advanced(by: ruleIndex)
                if matches(rule, relativePath: relativePath, basename: pathBasename, isDirectory: isDirectory) {
                    resolvedDecision = rule.pointee.decision
                    return
                }
            }
        }
        return resolvedDecision
    }

    private func considerIndexedRules(
        _ candidates: [IndexedRule]?,
        isDirectory: Bool,
        bestRuleIndex: inout Int,
        bestDecision: inout Decision?
    ) {
        guard let candidates else {
            return
        }
        for candidate in candidates {
            considerIndexedRule(
                candidate,
                isDirectory: isDirectory,
                bestRuleIndex: &bestRuleIndex,
                bestDecision: &bestDecision
            )
        }
    }

    private func considerIndexedRule(
        _ candidate: IndexedRule,
        isDirectory: Bool,
        bestRuleIndex: inout Int,
        bestDecision: inout Decision?
    ) {
        guard candidate.ruleIndex > bestRuleIndex else {
            return
        }
        guard isDirectory || !candidate.directoryOnly else {
            return
        }
        bestRuleIndex = candidate.ruleIndex
        bestDecision = candidate.decision
    }
    #endif

    public func matchingRule(relativePath: String, isDirectory: Bool) -> Rule? {
        matchingRule(relativePath: relativePath, basename: nil, isDirectory: isDirectory)
    }

    public func matchingRule(relativePath: String, basename pathBasename: String?, isDirectory: Bool) -> Rule? {
        let scopedRelativePath: String
        if isUnscoped || canUseUnscopedBasename(relativePath: relativePath) {
            scopedRelativePath = relativePath
        } else {
            guard let path = scopedPath(for: relativePath) else {
                return nil
            }
            scopedRelativePath = path
        }
        #if canImport(Darwin)
        let pathBasename = hasBasenameOnlyRules ? (pathBasename ?? basename(scopedRelativePath)) : nil
        #else
        let pathBasename = pathBasename ?? basename(scopedRelativePath)
        #endif
        var matchedRule: Rule?
        rules.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var offset = buffer.count
            while offset > 0 {
                offset -= 1
                let rule = baseAddress.advanced(by: offset)
                if matches(rule, relativePath: scopedRelativePath, basename: pathBasename, isDirectory: isDirectory) {
                    matchedRule = rule.pointee
                    return
                }
            }
        }
        return matchedRule
    }

    private func canUseUnscopedBasename(relativePath: String) -> Bool {
        guard allRulesUnanchoredBasenameOnly else {
            return false
        }
        if !pathPrefix.isEmpty && relativePath.isEmpty {
            return false
        }
        guard let stripBasePath else {
            return true
        }
        if relativePath == stripBasePath {
            return true
        }
        guard let stripBasePathPrefix else {
            return false
        }
        return relativePath.hasPrefix(stripBasePathPrefix)
    }

    private func scopedPath(for relativePath: String) -> String? {
        var path = relativePath
        if let stripBasePath {
            if path == stripBasePath {
                path = ""
            } else {
                guard let stripBasePathPrefix,
                      path.hasPrefix(stripBasePathPrefix) else {
                    return nil
                }
                path = String(path.dropFirst(stripBasePathPrefix.count))
            }
        }
        if !pathPrefix.isEmpty {
            path = path.isEmpty ? pathPrefix : "\(pathPrefix)/\(path)"
        }
        return path
    }

    private func matches(_ rule: UnsafePointer<Rule>, relativePath: String, basename pathBasename: String?, isDirectory: Bool) -> Bool {
        if rule.pointee.directoryOnly && !isDirectory {
            return false
        }
        if rule.pointee.pattern.isEmpty {
            return false
        }
        if rule.pointee.anchored {
            return matchesGlob(rule, relativePath)
        }
        if rule.pointee.basenameOnly {
            guard let pathBasename else {
                return false
            }
            return matchesGlob(rule, pathBasename)
        }
        if slashPatternsMatchAnywhere && !rule.pointee.anchored {
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

    private func matchesGlob(_ rule: UnsafePointer<Rule>, _ value: String) -> Bool {
        if let fastMatcher = rule.pointee.fastMatcher {
            return matchesFast(fastMatcher, value)
        }
        guard let regex = rule.pointee.regex else {
            return false
        }
        return matches(regex, value)
    }

    private func matchesGlobAnywhere(_ rule: UnsafePointer<Rule>, _ value: String) -> Bool {
        if let fastMatcher = rule.pointee.fastMatcher {
            if matchesFastAnywhere(fastMatcher, value) {
                return true
            }
            return false
        }
        guard let regex = rule.pointee.anywhereRegex else {
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
            return containsFast(needle, in: value)
        case .simpleGlob(let glob):
            return matchesSimpleGlob(glob, value)
        }
    }

    private func matchesFastAnywhere(_ matcher: FastMatcher, _ value: String) -> Bool {
        if matchesFast(matcher, value) {
            return true
        }
        switch matcher {
        case .exact(let expected):
            return hasPathComponentSuffix(expected, in: value)
        case .any:
            return true
        case .prefix, .prefixSuffix, .suffix, .contains, .simpleGlob:
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

    private func hasPathComponentSuffix(_ suffix: String, in value: String) -> Bool {
        withUTF8Buffer(value) { valueBytes in
            withUTF8Buffer(suffix) { suffixBytes in
                guard !suffixBytes.isEmpty,
                      suffixBytes.count < valueBytes.count,
                      let valueBase = valueBytes.baseAddress,
                      let suffixBase = suffixBytes.baseAddress else {
                    return false
                }
                let offset = valueBytes.count - suffixBytes.count
                guard valueBytes[offset - 1] == UInt8(ascii: "/") else {
                    return false
                }
                return memcmp(valueBase.advanced(by: offset), suffixBase, suffixBytes.count) == 0
            }
        }
    }

    private func containsFast(_ needle: String, in value: String) -> Bool {
        withUTF8Buffer(needle) { needleBytes in
            guard needleBytes.allSatisfy({ $0 < 0x80 }) else {
                return value.contains(needle)
            }
            guard !needleBytes.isEmpty else {
                return true
            }
            return withUTF8Buffer(value) { valueBytes in
                guard needleBytes.count <= valueBytes.count,
                      let valueBase = valueBytes.baseAddress,
                      let needleBase = needleBytes.baseAddress else {
                    return false
                }
                let first = needleBytes[0]
                let lastStart = valueBytes.count - needleBytes.count
                var offset = 0
                while offset <= lastStart {
                    if valueBytes[offset] == first,
                       memcmp(valueBase.advanced(by: offset), needleBase, needleBytes.count) == 0 {
                        return true
                    }
                    offset += 1
                }
                return false
            }
        }
    }

    private func withUTF8Buffer<T>(_ value: String, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        var value = value
        return value.withUTF8(body)
    }

    private static func compileFastMatcher(
        _ pattern: String,
        basenameOnly: Bool,
        caseInsensitive: Bool
    ) -> FastMatcher? {
        guard !caseInsensitive else {
            return nil
        }
        let meta = fastMatcherPatternMeta(pattern)
        guard !meta.hasUnsupportedMeta else {
            return nil
        }
        #if canImport(Darwin)
        if pattern.hasPrefix("**/") {
            let suffix = String(pattern.dropFirst(3))
            if !suffix.isEmpty,
               !fastMatcherPatternMeta(suffix).hasAnyGlobMeta {
                return .exact(suffix)
            }
        }
        #endif
        if meta.hasQuestionOrClassMeta {
            #if canImport(Darwin)
            if let simpleGlob = compileSimpleGlob(pattern, basenameOnly: basenameOnly) {
                return .simpleGlob(simpleGlob)
            }
            #endif
            return nil
        }
        if meta.starCount == 0 {
            return .exact(pattern)
        }
        #if canImport(Darwin)
        if !basenameOnly, let simpleGlob = compileSimpleGlob(pattern, basenameOnly: basenameOnly) {
            return .simpleGlob(simpleGlob)
        }
        #endif
        guard basenameOnly else {
            return nil
        }
        if pattern == "*" {
            return .any
        }
        if meta.starCount == 1, pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return suffix.isEmpty ? .any : .suffix(suffix)
        }
        if meta.starCount == 1, pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return prefix.isEmpty ? .any : .prefix(prefix)
        }
        if meta.starCount == 1, let star = pattern.firstIndex(of: "*") {
            let prefix = String(pattern[..<star])
            let suffix = String(pattern[pattern.index(after: star)...])
            if !prefix.isEmpty, !suffix.isEmpty {
                return .prefixSuffix(prefix: prefix, suffix: suffix)
            }
        }
        if meta.starCount == 2, pattern.hasPrefix("*"), pattern.hasSuffix("*") {
            let needle = pattern.dropFirst().dropLast()
            return needle.isEmpty ? .any : .contains(String(needle))
        }
        #if canImport(Darwin)
        if let simpleGlob = compileSimpleGlob(pattern, basenameOnly: basenameOnly) {
            return .simpleGlob(simpleGlob)
        }
        #endif
        return nil
    }

    private static func fastMatcherPatternMeta(_ pattern: String) -> FastMatcherPatternMeta {
        var hasUnsupportedMeta = false
        var hasQuestionOrClassMeta = false
        var starCount = 0
        for byte in pattern.utf8 {
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "\\"):
                hasUnsupportedMeta = true
            case UInt8(ascii: "*"):
                starCount += 1
            case UInt8(ascii: "?"), UInt8(ascii: "["), UInt8(ascii: "]"):
                hasQuestionOrClassMeta = true
            default:
                break
            }
        }
        return FastMatcherPatternMeta(
            hasUnsupportedMeta: hasUnsupportedMeta,
            hasQuestionOrClassMeta: hasQuestionOrClassMeta,
            starCount: starCount
        )
    }

    private func matchesSimpleGlob(_ glob: SimpleGlob, _ value: String) -> Bool {
        if let matched = value.utf8.withContiguousStorageIfAvailable({ bytes in
            matchesSimpleGlob(glob, bytes: bytes)
        }) {
            return matched
        }
        let bytes = Array(value.utf8)
        return bytes.withUnsafeBufferPointer { bytes in
            matchesSimpleGlob(glob, bytes: bytes)
        }
    }

    private func matchesSimpleGlob(_ glob: SimpleGlob, bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let tokens = glob.tokens
        var tokenIndex = 0
        var byteIndex = 0
        var starTokenIndex: Int?
        var starByteIndex = 0

        while byteIndex < bytes.count {
            if tokenIndex < tokens.count,
               token(tokens[tokenIndex], matches: bytes[byteIndex]) {
                tokenIndex += 1
                byteIndex += 1
            } else if tokenIndex < tokens.count, tokens[tokenIndex] == .star {
                starTokenIndex = tokenIndex
                tokenIndex += 1
                starByteIndex = byteIndex
            } else if let previousStarTokenIndex = starTokenIndex {
                guard starByteIndex < bytes.count,
                      bytes[starByteIndex] != UInt8(ascii: "/") else {
                    return false
                }
                starByteIndex += 1
                tokenIndex = previousStarTokenIndex + 1
                byteIndex = starByteIndex
            } else {
                return false
            }
        }

        while tokenIndex < tokens.count, tokens[tokenIndex] == .star {
            tokenIndex += 1
        }
        return tokenIndex == tokens.count
    }

    private func token(_ token: SimpleGlob.Token, matches byte: UInt8) -> Bool {
        switch token {
        case .literal(let expected):
            return byte == expected
        case .any:
            return byte != UInt8(ascii: "/")
        case .star:
            return false
        case .charClass(let ranges, let negated):
            guard byte != UInt8(ascii: "/") else {
                return false
            }
            let contains = ranges.contains { $0.contains(byte) }
            return negated ? !contains : contains
        }
    }

    private static func compileSimpleGlob(_ pattern: String, basenameOnly: Bool) -> SimpleGlob? {
        guard pattern.utf8.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        if !basenameOnly, pattern.contains("**") {
            return nil
        }

        var tokens: [SimpleGlob.Token] = []
        let bytes = Array(pattern.utf8)
        var index = 0
        var sawSimpleGlobSyntax = false
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "*"):
                sawSimpleGlobSyntax = true
                if tokens.last != .star {
                    tokens.append(.star)
                }
                index += 1
            case UInt8(ascii: "?"):
                sawSimpleGlobSyntax = true
                tokens.append(.any)
                index += 1
            case UInt8(ascii: "["):
                guard let parsed = parseSimpleGlobClass(bytes, start: index) else {
                    return nil
                }
                sawSimpleGlobSyntax = true
                tokens.append(.charClass(parsed.ranges, negated: parsed.negated))
                index = parsed.nextIndex
            case UInt8(ascii: "]"):
                return nil
            default:
                tokens.append(.literal(bytes[index]))
                index += 1
            }
        }
        return sawSimpleGlobSyntax ? SimpleGlob(tokens: tokens) : nil
    }

    private static func parseSimpleGlobClass(
        _ bytes: [UInt8],
        start: Int
    ) -> (ranges: [ClosedRange<UInt8>], negated: Bool, nextIndex: Int)? {
        var index = start + 1
        guard index < bytes.count else {
            return nil
        }
        var negated = false
        if bytes[index] == UInt8(ascii: "!") || bytes[index] == UInt8(ascii: "^") {
            negated = true
            index += 1
        }
        guard index < bytes.count, bytes[index] != UInt8(ascii: "]") else {
            return nil
        }

        var ranges: [ClosedRange<UInt8>] = []
        while index < bytes.count, bytes[index] != UInt8(ascii: "]") {
            let lower = bytes[index]
            if index + 2 < bytes.count,
               bytes[index + 1] == UInt8(ascii: "-"),
               bytes[index + 2] != UInt8(ascii: "]") {
                let upper = bytes[index + 2]
                ranges.append(min(lower, upper)...max(lower, upper))
                index += 3
            } else {
                ranges.append(lower...lower)
                index += 1
            }
        }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "]") else {
            return nil
        }
        return (ranges, negated, index + 1)
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

public struct IgnoreStack: @unchecked Sendable {
    private var matchers: [GlobMatcher] = []
    private var canInclude = false

    public init() {}

    public var isEmpty: Bool {
        matchers.isEmpty
    }

    public var canIncludePaths: Bool {
        canInclude
    }

    public mutating func append(_ matcher: GlobMatcher) {
        if !matcher.isEmpty {
            matchers.append(matcher)
            canInclude = canInclude || matcher.canInclude
        }
    }

    public func allows(relativePath: String, isDirectory: Bool) -> Bool {
        allows(relativePath: relativePath, basename: nil, isDirectory: isDirectory)
    }

    public func allows(relativePath: String, basename: String?, isDirectory: Bool) -> Bool {
        decision(relativePath: relativePath, basename: basename, isDirectory: isDirectory) != .exclude
    }

    public func decision(relativePath: String, isDirectory: Bool) -> GlobMatcher.Decision? {
        matchingRule(relativePath: relativePath, isDirectory: isDirectory)?.decision
    }

    public func decision(relativePath: String, basename: String?, isDirectory: Bool) -> GlobMatcher.Decision? {
        guard !matchers.isEmpty else {
            return nil
        }
        return matchers.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return nil
            }
            var offset = buffer.count
            while offset > 0 {
                offset -= 1
                let matcher = baseAddress.advanced(by: offset)
                if let decision = matcher.pointee.decision(relativePath: relativePath, basename: basename, isDirectory: isDirectory) {
                    return decision
                }
            }
            return nil
        }
    }

    public func matchingRule(relativePath: String, isDirectory: Bool) -> GlobMatcher.Rule? {
        matchingRule(relativePath: relativePath, basename: nil, isDirectory: isDirectory)
    }

    public func matchingRule(relativePath: String, basename: String?, isDirectory: Bool) -> GlobMatcher.Rule? {
        guard !matchers.isEmpty else {
            return nil
        }
        return matchers.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return nil
            }
            var offset = buffer.count
            while offset > 0 {
                offset -= 1
                let matcher = baseAddress.advanced(by: offset)
                if let rule = matcher.pointee.matchingRule(relativePath: relativePath, basename: basename, isDirectory: isDirectory) {
                    return rule
                }
            }
            return nil
        }
    }
}
