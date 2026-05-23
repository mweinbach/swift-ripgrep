import Foundation

public struct Haystack: Equatable {
    public let url: URL
    public let isExplicit: Bool

    public init(url: URL, isExplicit: Bool) {
        self.url = url
        self.isExplicit = isExplicit
    }
}

public struct FileWalkResults: Equatable {
    public let haystacks: [Haystack]
    public let messages: [String]
    public let diagnostics: [String]
    public let filtered: Bool

    public init(haystacks: [Haystack], messages: [String], diagnostics: [String] = [], filtered: Bool = false) {
        self.haystacks = haystacks
        self.messages = messages
        self.diagnostics = diagnostics
        self.filtered = filtered
    }
}

private struct LoadedIgnoreMatcher {
    let matcher: GlobMatcher
    let messages: [String]
}

public struct FileWalker {
    private let fileManager: FileManager
    private let environment: [String: String]

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    public func withEnvironment(_ environment: [String: String]) -> FileWalker {
        FileWalker(fileManager: fileManager, environment: environment)
    }

    public func haystacks(for options: RipgrepOptions) throws -> [Haystack] {
        let results = try haystacksWithMessages(for: options)
        if let message = results.messages.first {
            throw RipgrepError.message(message)
        }
        return results.haystacks
    }

    public func haystacksWithMessages(for options: RipgrepOptions) throws -> FileWalkResults {
        var haystacks: [Haystack] = []
        var messages: [String] = []
        var diagnostics: [String] = []
        var filtered = false
        var baseIgnoreStack = IgnoreStack()
        if !options.noIgnoreFiles {
            for ignoreFile in options.ignoreFiles {
                appendLoadedMatcher(
                    from: ignoreFile,
                    to: &baseIgnoreStack,
                    messages: &messages,
                    rootBase: nil,
                    options: options
                )
            }
        }
        let overrideEntries = options.globPatterns.map { pattern in
            (pattern: pattern, caseInsensitive: options.globCaseInsensitive)
        } + options.caseInsensitiveGlobPatterns.map { pattern in
            (pattern: pattern, caseInsensitive: true)
        }
        let overrides = GlobMatcher(
            patternEntries: overrideEntries,
            overrideSemantics: true,
        )
        var typeRegistry = FileTypeRegistry()
        let typeErrors = typeRegistry.apply(options.typeChanges)
        if let error = typeErrors.first {
            throw RipgrepError.message(error)
        }

        for (offset, root) in options.effectiveRoots.enumerated() {
            guard fileManager.fileExists(atPath: root.path) else {
                let displayPath = rootDisplayPath(at: offset, root: root, options: options)
                messages.append(missingRootMessage(displayPath, options: options))
                continue
            }
            let rootBase = rootBase(for: root.standardizedFileURL)
            var rootIgnoreStack = baseIgnoreStack
            appendGlobalIgnoreFile(to: &rootIgnoreStack, rootBase: rootBase, messages: &messages, options: options)
            appendParentIgnoreFiles(to: &rootIgnoreStack, rootBase: rootBase, messages: &messages, options: options)
            let rootVolume = options.oneFileSystem ? volumeIdentifier(for: root.standardizedFileURL) : nil
            haystacks.append(contentsOf: try walk(
                root.standardizedFileURL,
                isExplicit: true,
                depth: 0,
                rootBase: rootBase,
                rootVolume: rootVolume,
                messages: &messages,
                diagnostics: &diagnostics,
                filtered: &filtered,
                ignoreStack: rootIgnoreStack,
                overrides: overrides,
                typeRegistry: typeRegistry,
                options: options
            ))
        }

        return FileWalkResults(
            haystacks: sorted(haystacks, options: options),
            messages: messages,
            diagnostics: diagnostics,
            filtered: filtered
        )
    }

    private func missingRootMessage(_ displayPath: String, options: RipgrepOptions) -> String {
        guard options.sortMode != nil else {
            return "\(displayPath): No such file or directory (os error 2)"
        }
        return "\(displayPath): IO error for operation on \(displayPath): No such file or directory (os error 2)"
    }

    private func rootDisplayPath(at offset: Int, root: URL, options: RipgrepOptions) -> String {
        guard offset < options.rootPathArguments.count,
              !options.rootPathArguments[offset].isEmpty else {
            return root.path
        }
        return options.rootPathArguments[offset]
    }

    private func walk(
        _ url: URL,
        isExplicit: Bool,
        depth: Int,
        rootBase: URL,
        rootVolume: String?,
        messages: inout [String],
        diagnostics: inout [String],
        filtered: inout Bool,
        ignoreStack: IgnoreStack,
        overrides: GlobMatcher,
        typeRegistry: FileTypeRegistry,
        options: RipgrepOptions
    ) throws -> [Haystack] {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .nameKey,
            .fileSizeKey,
            .volumeIdentifierKey,
        ])
        let isDirectory = values.isDirectory == true
        let relativePath = relativePath(for: url, rootBase: rootBase)

        if !isExplicit {
            let overrideDecision = overrides.decision(relativePath: relativePath, isDirectory: isDirectory)
            let isIncludedByOverride = overrideDecision == .include
            if overrideDecision == .exclude
                || (overrideDecision == nil && !overrides.allows(relativePath: relativePath, isDirectory: isDirectory)) {
                debug("ignoring \(url.path): override glob", options: options, diagnostics: &diagnostics)
                return []
            }
            if !isIncludedByOverride,
               !options.hidden,
               isHidden(url),
               !isIncludedByIgnore(relativePath: relativePath, isDirectory: isDirectory, ignoreStack: ignoreStack) {
                debug("ignoring \(url.path): hidden", options: options, diagnostics: &diagnostics)
                return []
            }
            if !isIncludedByOverride && !ignoreStack.allows(relativePath: relativePath, isDirectory: isDirectory) {
                debug("ignoring \(url.path): ignore file", options: options, diagnostics: &diagnostics)
                filtered = true
                return []
            }
            if !isDirectory && !typeRegistry.allows(path: relativePath) {
                debug("ignoring \(url.path): file type filter", options: options, diagnostics: &diagnostics)
                return []
            }
        }

        if values.isSymbolicLink == true && !options.followSymlinks && !isExplicit {
            debug("ignoring \(url.path): symbolic link", options: options, diagnostics: &diagnostics)
            return []
        }

        let resolvedURL = values.isSymbolicLink == true && options.followSymlinks
            ? url.resolvingSymlinksInPath()
            : url
        let resolvedValues = try resolvedURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .nameKey,
        ])

        if resolvedValues.isRegularFile == true {
            if !isExplicit,
               let maxFileSize = options.maxFileSize,
               let fileSize = values.fileSize,
               UInt64(fileSize) > maxFileSize {
                debug("ignoring \(url.path): \(fileSize) bytes exceeds max filesize \(maxFileSize)", options: options, diagnostics: &diagnostics)
                return []
            }
            return [Haystack(url: url, isExplicit: isExplicit)]
        }

        guard resolvedValues.isDirectory == true else {
            return []
        }
        if !isExplicit,
           options.oneFileSystem,
           let rootVolume,
           let currentVolume = volumeIdentifier(for: resolvedURL),
           currentVolume != rootVolume {
            debug("ignoring \(url.path): different file system", options: options, diagnostics: &diagnostics)
            return []
        }
        if let maxDepth = options.maxDepth, depth >= maxDepth {
            debug("ignoring \(url.path): max depth \(maxDepth)", options: options, diagnostics: &diagnostics)
            return []
        }

        var directoryIgnoreStack = ignoreStack
        if !options.noIgnore {
            appendIgnoreFiles(
                in: resolvedURL,
                to: &directoryIgnoreStack,
                messages: &messages,
                rootBase: rootBase,
                options: options
            )
        }

        let children = try fileManager.contentsOfDirectory(
            at: resolvedURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .nameKey,
            ],
            options: []
        ).sorted(by: defaultWalkOrder)

        var haystacks: [Haystack] = []
        for child in children {
            let childURL = resolvedURL == url
                ? child
                : url.appendingPathComponent(child.lastPathComponent)
            haystacks.append(contentsOf: try walk(
                childURL,
                isExplicit: false,
                depth: depth + 1,
                rootBase: rootBase,
                rootVolume: rootVolume,
                messages: &messages,
                diagnostics: &diagnostics,
                filtered: &filtered,
                ignoreStack: directoryIgnoreStack,
                overrides: overrides,
                typeRegistry: typeRegistry,
                options: options
            ))
        }
        return haystacks
    }

    private func debug(_ message: String, options: RipgrepOptions, diagnostics: inout [String]) {
        guard options.loggingMode != nil else {
            return
        }
        diagnostics.append("DEBUG|swift-ripgrep::walk| \(message)")
    }

    private func volumeIdentifier(for url: URL) -> String? {
        guard let identifier = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return nil
        }
        return String(describing: identifier)
    }

    private func sorted(_ haystacks: [Haystack], options: RipgrepOptions) -> [Haystack] {
        guard let sortMode = options.sortMode else {
            return haystacks
        }
        return haystacks.sorted { lhs, rhs in
            let order = compare(lhs.url, rhs.url, by: sortMode.kind)
            if sortMode.reverse {
                return order == .orderedDescending
            }
            return order == .orderedAscending
        }
    }

    private func defaultWalkOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsName = lhs.lastPathComponent
        let rhsName = rhs.lastPathComponent
        return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
    }

    private func compare(_ lhs: URL, _ rhs: URL, by kind: SortKind) -> ComparisonResult {
        switch kind {
        case .path:
            return comparePaths(lhs, rhs)
        case .modified:
            return compareDates(
                lhs,
                rhs,
                key: .contentModificationDateKey
            )
        case .accessed:
            return compareDates(
                lhs,
                rhs,
                key: .contentAccessDateKey
            )
        case .created:
            return compareDates(
                lhs,
                rhs,
                key: .creationDateKey
            )
        }
    }

    private func compareDates(_ lhs: URL, _ rhs: URL, key: URLResourceKey) -> ComparisonResult {
        let lhsDate = (try? lhs.resourceValues(forKeys: [key]).allValues[key] as? Date) ?? .distantPast
        let rhsDate = (try? rhs.resourceValues(forKeys: [key]).allValues[key] as? Date) ?? .distantPast
        if lhsDate == rhsDate {
            return comparePaths(lhs, rhs)
        }
        return lhsDate < rhsDate ? .orderedAscending : .orderedDescending
    }

    private func comparePaths(_ lhs: URL, _ rhs: URL) -> ComparisonResult {
        let lhsPath = lhs.path
        let rhsPath = rhs.path
        if lhsPath == rhsPath {
            return .orderedSame
        }
        return lhsPath < rhsPath ? .orderedAscending : .orderedDescending
    }

    private func isHidden(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(".")
    }

    private func isIncludedByIgnore(relativePath: String, isDirectory: Bool, ignoreStack: IgnoreStack) -> Bool {
        ignoreStack.decision(relativePath: relativePath, isDirectory: isDirectory) == .include
    }

    private func rootBase(for root: URL) -> URL {
        if (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return root
        }
        return root.deletingLastPathComponent()
    }

    private func appendParentIgnoreFiles(
        to ignoreStack: inout IgnoreStack,
        rootBase: URL,
        messages: inout [String],
        options: RipgrepOptions
    ) {
        guard !options.noIgnore, !options.noIgnoreParent else {
            return
        }

        let rootPath = rootBase.standardizedFileURL.path
        let parentURLs = ancestorPaths(of: rootPath).map { path in
            URL(fileURLWithPath: path, isDirectory: true)
        }
        let gitBoundary = parentURLs.last { hasGitMarker(in: $0) }
        for parentURL in parentURLs {
            appendParentDotIgnoreFiles(
                in: parentURL,
                to: &ignoreStack,
                messages: &messages,
                rootBase: rootBase,
                options: options
            )
            appendParentVCSIgnoreFiles(
                in: parentURL,
                gitBoundary: gitBoundary,
                to: &ignoreStack,
                messages: &messages,
                rootBase: rootBase,
                options: options
            )
        }
    }

    private func appendParentDotIgnoreFiles(
        in parentURL: URL,
        to ignoreStack: inout IgnoreStack,
        messages: inout [String],
        rootBase: URL,
        options: RipgrepOptions
    ) {
        guard !options.noIgnoreDot else {
            return
        }
        appendLoadedMatcher(
            from: parentURL.appendingPathComponent(".ignore"),
            to: &ignoreStack,
            messages: &messages,
            rootBase: rootBase,
            options: options
        )
        appendLoadedMatcher(
            from: parentURL.appendingPathComponent(".rgignore"),
            to: &ignoreStack,
            messages: &messages,
            rootBase: rootBase,
            options: options
        )
    }

    private func appendParentVCSIgnoreFiles(
        in parentURL: URL,
        gitBoundary: URL?,
        to ignoreStack: inout IgnoreStack,
        messages: inout [String],
        rootBase: URL,
        options: RipgrepOptions
    ) {
        guard !options.noIgnoreVCS,
              shouldLoadParentVCSIgnore(in: parentURL, gitBoundary: gitBoundary, options: options) else {
            return
        }
        appendLoadedMatcher(
            from: parentURL.appendingPathComponent(".gitignore"),
            to: &ignoreStack,
            messages: &messages,
            rootBase: rootBase,
            options: options
        )
        if !options.noIgnoreExclude,
           let excludeURL = gitInfoExcludeURL(for: parentURL) {
            appendLoadedMatcher(
                from: excludeURL,
                to: &ignoreStack,
                messages: &messages,
                rootBase: rootBase,
                scopeDirectory: parentURL,
                options: options
            )
        }
    }

    private func shouldLoadParentVCSIgnore(
        in parentURL: URL,
        gitBoundary: URL?,
        options: RipgrepOptions
    ) -> Bool {
        if let gitBoundary {
            return isAtOrBelow(parentURL, gitBoundary)
        }
        return options.noRequireGit || isInGitRepository(parentURL)
    }

    private func hasGitMarker(in directoryURL: URL) -> Bool {
        fileManager.fileExists(atPath: directoryURL.appendingPathComponent(".git").path)
    }

    private func gitInfoExcludeURL(for directoryURL: URL) -> URL? {
        let markerURL = directoryURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: markerURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return markerURL
                .appendingPathComponent("info", isDirectory: true)
                .appendingPathComponent("exclude")
        }
        guard let gitDirectory = gitDirectory(fromGitFile: markerURL, worktreeDirectory: directoryURL) else {
            return nil
        }
        let commonDirectory = commonGitDirectory(from: gitDirectory)
        return commonDirectory
            .appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent("exclude")
    }

    private func gitDirectory(fromGitFile gitFileURL: URL, worktreeDirectory: URL) -> URL? {
        guard let contents = try? String(contentsOf: gitFileURL, encoding: .utf8) else {
            return nil
        }
        guard let rawLine = contents.components(separatedBy: .newlines).first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("gitdir:")
        }) else {
            return nil
        }
        let value = rawLine
            .dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        return resolvedGitPath(value, relativeTo: worktreeDirectory)
    }

    private func commonGitDirectory(from gitDirectory: URL) -> URL {
        let commondirURL = gitDirectory.appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: commondirURL, encoding: .utf8) else {
            return gitDirectory
        }
        let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return gitDirectory
        }
        return resolvedGitPath(value, relativeTo: gitDirectory) ?? gitDirectory
    }

    private func resolvedGitPath(_ rawPath: String, relativeTo baseURL: URL) -> URL? {
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath).standardizedFileURL
        }
        let relativeToBase = baseURL
            .appendingPathComponent(rawPath)
            .standardizedFileURL
        if fileManager.fileExists(atPath: relativeToBase.path) {
            return relativeToBase
        }
        let relativeToCWD = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(rawPath)
            .standardizedFileURL
        if fileManager.fileExists(atPath: relativeToCWD.path) {
            return relativeToCWD
        }
        return relativeToBase
    }

    private func isAtOrBelow(_ url: URL, _ ancestor: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let ancestorPath = ancestor.standardizedFileURL.path
        if path == ancestorPath {
            return true
        }
        let prefix = ancestorPath.hasSuffix("/") ? ancestorPath : "\(ancestorPath)/"
        return path.hasPrefix(prefix)
    }

    private func appendGlobalIgnoreFile(
        to ignoreStack: inout IgnoreStack,
        rootBase: URL,
        messages: inout [String],
        options: RipgrepOptions
    ) {
        guard !options.noIgnore,
              !options.noIgnoreVCS,
              !options.noIgnoreGlobal,
              options.noRequireGit || isInGitRepository(rootBase),
              let globalIgnoreFile = globalGitIgnoreFile() else {
            return
        }
        appendLoadedMatcher(
            from: globalIgnoreFile,
            to: &ignoreStack,
            messages: &messages,
            rootBase: nil,
            options: options
        )
    }

    private func ancestorPaths(of path: String) -> [String] {
        var paths: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty && current != "/" {
            paths.append(current)
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current {
                break
            }
            current = parent
        }
        return paths.reversed()
    }

    private func isInGitRepository(_ url: URL) -> Bool {
        let directory = ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            ? url
            : url.deletingLastPathComponent()
        var currentPath = directory.standardizedFileURL.path

        while true {
            if fileManager.fileExists(atPath: (currentPath as NSString).appendingPathComponent(".git")) {
                return true
            }
            let parentPath = (currentPath as NSString).deletingLastPathComponent
            if parentPath == currentPath || parentPath.isEmpty {
                return false
            }
            currentPath = parentPath
        }
    }

    private func relativePath(for url: URL, rootBase: URL) -> String {
        let path = url.standardizedFileURL.path
        let basePath = rootBase.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : "\(basePath)/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }

    private func relativePathIfContained(_ url: URL, in baseURL: URL) -> String? {
        let path = url.standardizedFileURL.path
        let basePath = baseURL.standardizedFileURL.path
        if path == basePath {
            return ""
        }
        let prefix = basePath.hasSuffix("/") ? basePath : "\(basePath)/"
        guard path.hasPrefix(prefix) else {
            return nil
        }
        return String(path.dropFirst(prefix.count))
    }

    private func appendLoadedMatcher(
        from fileURL: URL,
        to ignoreStack: inout IgnoreStack,
        messages: inout [String],
        rootBase: URL?,
        scopeDirectory: URL? = nil,
        options: RipgrepOptions
    ) {
        let loaded = loadMatcher(
            from: fileURL,
            rootBase: rootBase,
            scopeDirectory: scopeDirectory,
            caseInsensitive: options.ignoreFileCaseInsensitive
        )
        ignoreStack.append(loaded.matcher)
        if !options.noIgnoreMessages {
            messages.append(contentsOf: loaded.messages)
        }
    }

    private func loadMatcher(
        from fileURL: URL,
        rootBase: URL?,
        scopeDirectory: URL? = nil,
        caseInsensitive: Bool = false
    ) -> LoadedIgnoreMatcher {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return LoadedIgnoreMatcher(matcher: GlobMatcher(patterns: []), messages: [])
        }
        let parsed = parseIgnorePatterns(contents, fileURL: fileURL)
        let scope = ignoreScope(for: scopeDirectory ?? fileURL.deletingLastPathComponent(), rootBase: rootBase)
        return LoadedIgnoreMatcher(matcher: GlobMatcher(
            patterns: parsed.patterns,
            caseInsensitive: caseInsensitive,
            stripBasePath: scope.stripBasePath,
            pathPrefix: scope.pathPrefix
        ), messages: parsed.messages)
    }

    private func ignoreScope(for ignoreDirectory: URL, rootBase: URL?) -> (stripBasePath: String?, pathPrefix: String) {
        guard let rootBase else {
            return (nil, "")
        }
        if let stripBasePath = relativePathIfContained(ignoreDirectory, in: rootBase) {
            return (stripBasePath, "")
        }
        if let pathPrefix = relativePathIfContained(rootBase, in: ignoreDirectory) {
            return (nil, pathPrefix)
        }
        return (nil, "")
    }

    private func parseIgnorePatterns(_ contents: String, fileURL _: URL) -> (patterns: [String], messages: [String]) {
        var patterns: [String] = []
        for rawLine in contents.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                patterns.append(rawLine)
                continue
            }
            patterns.append(rawLine)
        }
        return (patterns, [])
    }

    private func globalGitIgnoreFile() -> URL? {
        if let homeConfig = readGitConfig(homeGitConfigURL()),
           let excludesFile = parseExcludesFile(from: homeConfig) {
            return excludesFile
        }
        if let xdgConfig = readGitConfig(xdgGitConfigURL()),
           let excludesFile = parseExcludesFile(from: xdgConfig) {
            return excludesFile
        }
        return defaultGlobalGitIgnoreURL()
    }

    private func readGitConfig(_ url: URL?) -> String? {
        guard let url else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func homeGitConfigURL() -> URL? {
        homeURL()?.appendingPathComponent(".gitconfig")
    }

    private func xdgGitConfigURL() -> URL? {
        let configDirectory = xdgConfigHomeURL() ?? homeURL()?.appendingPathComponent(".config", isDirectory: true)
        return configDirectory?
            .appendingPathComponent("git", isDirectory: true)
            .appendingPathComponent("config")
    }

    private func defaultGlobalGitIgnoreURL() -> URL? {
        let configDirectory = xdgConfigHomeURL() ?? homeURL()?.appendingPathComponent(".config", isDirectory: true)
        return configDirectory?
            .appendingPathComponent("git", isDirectory: true)
            .appendingPathComponent("ignore")
    }

    private func xdgConfigHomeURL() -> URL? {
        guard let raw = environment["XDG_CONFIG_HOME"], !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private func homeURL() -> URL? {
        guard let raw = environment["HOME"], !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private func parseExcludesFile(from config: String) -> URL? {
        for rawLine in config.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lowercased = line.lowercased()
            guard lowercased.hasPrefix("excludesfile") else {
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
                value = value.trimmingCharacters(in: .whitespaces)
            }
            guard !value.isEmpty, !value.contains(" ") else {
                continue
            }
            return URL(fileURLWithPath: expandTilde(value), isDirectory: false)
        }
        return nil
    }

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~"), let home = environment["HOME"], !home.isEmpty else {
            return path
        }
        return path.replacingOccurrences(of: "~", with: home)
    }

    private func appendIgnoreFiles(
        in directoryURL: URL,
        to ignoreStack: inout IgnoreStack,
        messages: inout [String],
        rootBase: URL,
        options: RipgrepOptions
    ) {
        if !options.noIgnoreVCS && (options.noRequireGit || isInGitRepository(directoryURL)) {
            appendLoadedMatcher(
                from: directoryURL.appendingPathComponent(".gitignore"),
                to: &ignoreStack,
                messages: &messages,
                rootBase: rootBase,
                options: options
            )
        }
        if !options.noIgnoreExclude,
           !options.noIgnoreVCS,
           (options.noRequireGit || isInGitRepository(directoryURL)),
           let excludeURL = gitInfoExcludeURL(for: directoryURL) {
            appendLoadedMatcher(
                from: excludeURL,
                to: &ignoreStack,
                messages: &messages,
                rootBase: rootBase,
                scopeDirectory: directoryURL,
                options: options
            )
        }
        if !options.noIgnoreDot {
            appendLoadedMatcher(
                from: directoryURL.appendingPathComponent(".ignore"),
                to: &ignoreStack,
                messages: &messages,
                rootBase: rootBase,
                options: options
            )
            appendLoadedMatcher(
                from: directoryURL.appendingPathComponent(".rgignore"),
                to: &ignoreStack,
                messages: &messages,
                rootBase: rootBase,
                options: options
            )
        }
    }
}
