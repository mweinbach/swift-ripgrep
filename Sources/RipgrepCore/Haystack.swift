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
        var baseIgnoreStack = IgnoreStack()
        if !options.noIgnoreFiles {
            for ignoreFile in options.ignoreFiles {
                baseIgnoreStack.append(loadMatcher(
                    from: ignoreFile,
                    caseInsensitive: options.ignoreFileCaseInsensitive
                ))
            }
        }
        let overrides = GlobMatcher(
            patterns: options.globPatterns,
            overrideSemantics: true,
            caseInsensitive: options.globCaseInsensitive
        )
        var typeRegistry = FileTypeRegistry()
        typeRegistry.apply(options.typeChanges)

        for root in options.effectiveRoots {
            guard fileManager.fileExists(atPath: root.path) else {
                messages.append("\(root.path): No such file or directory (os error 2)")
                continue
            }
            let rootBase = rootBase(for: root.standardizedFileURL)
            var rootIgnoreStack = baseIgnoreStack
            appendGlobalIgnoreFile(to: &rootIgnoreStack, rootBase: rootBase, options: options)
            appendParentIgnoreFiles(to: &rootIgnoreStack, rootBase: rootBase, options: options)
            haystacks.append(contentsOf: try walk(
                root.standardizedFileURL,
                isExplicit: true,
                depth: 0,
                rootBase: rootBase,
                ignoreStack: rootIgnoreStack,
                overrides: overrides,
                typeRegistry: typeRegistry,
                options: options
            ))
        }

        return FileWalkResults(
            haystacks: sorted(haystacks, options: options),
            messages: messages
        )
    }

    private func walk(
        _ url: URL,
        isExplicit: Bool,
        depth: Int,
        rootBase: URL,
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
        ])
        let isDirectory = values.isDirectory == true
        let relativePath = relativePath(for: url, rootBase: rootBase)

        if !isExplicit {
            if !options.hidden && isHidden(url) {
                return []
            }
            if !overrides.allows(relativePath: relativePath, isDirectory: isDirectory) {
                return []
            }
            if !ignoreStack.allows(relativePath: relativePath, isDirectory: isDirectory) {
                return []
            }
            if !isDirectory && !typeRegistry.allows(path: relativePath) {
                return []
            }
        }

        if values.isSymbolicLink == true && !options.followSymlinks && !isExplicit {
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
                return []
            }
            return [Haystack(url: url, isExplicit: isExplicit)]
        }

        guard resolvedValues.isDirectory == true else {
            return []
        }
        if let maxDepth = options.maxDepth, depth >= maxDepth {
            return []
        }

        var directoryIgnoreStack = ignoreStack
        if !options.noIgnore {
            appendIgnoreFiles(in: resolvedURL, to: &directoryIgnoreStack, options: options)
        }

        let optionsMask: FileManager.DirectoryEnumerationOptions = options.hidden ? [] : [.skipsHiddenFiles]
        let children = try fileManager.contentsOfDirectory(
            at: resolvedURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .nameKey,
            ],
            options: optionsMask
        )
        .sorted { $0.path < $1.path }

        var haystacks: [Haystack] = []
        for child in children {
            haystacks.append(contentsOf: try walk(
                child,
                isExplicit: false,
                depth: depth + 1,
                rootBase: rootBase,
                ignoreStack: directoryIgnoreStack,
                overrides: overrides,
                typeRegistry: typeRegistry,
                options: options
            ))
        }
        return haystacks
    }

    private func sorted(_ haystacks: [Haystack], options: RipgrepOptions) -> [Haystack] {
        guard let sortMode = options.sortMode else {
            return haystacks.sorted { $0.url.path < $1.url.path }
        }
        return haystacks.sorted { lhs, rhs in
            let order = compare(lhs.url, rhs.url, by: sortMode.kind)
            if sortMode.reverse {
                return order == .orderedDescending
            }
            return order == .orderedAscending
        }
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

    private func rootBase(for root: URL) -> URL {
        if (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return root
        }
        return root.deletingLastPathComponent()
    }

    private func appendParentIgnoreFiles(
        to ignoreStack: inout IgnoreStack,
        rootBase: URL,
        options: RipgrepOptions
    ) {
        guard !options.noIgnore, !options.noIgnoreParent else {
            return
        }

        let rootPath = rootBase.standardizedFileURL.path
        let parentPaths = ancestorPaths(of: rootPath)
        for parentPath in parentPaths {
            let parentURL = URL(fileURLWithPath: parentPath, isDirectory: true)
            appendIgnoreFiles(in: parentURL, to: &ignoreStack, options: options)
        }
    }

    private func appendGlobalIgnoreFile(
        to ignoreStack: inout IgnoreStack,
        rootBase: URL,
        options: RipgrepOptions
    ) {
        guard !options.noIgnore,
              !options.noIgnoreVCS,
              !options.noIgnoreGlobal,
              options.noRequireGit || isInGitRepository(rootBase),
              let globalIgnoreFile = globalGitIgnoreFile() else {
            return
        }
        ignoreStack.append(loadMatcher(
            from: globalIgnoreFile,
            caseInsensitive: options.ignoreFileCaseInsensitive
        ))
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

    private func loadMatcher(from fileURL: URL, caseInsensitive: Bool = false) -> GlobMatcher {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return GlobMatcher(patterns: [])
        }
        return GlobMatcher(
            patterns: contents.components(separatedBy: .newlines),
            caseInsensitive: caseInsensitive
        )
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
        options: RipgrepOptions
    ) {
        if !options.noIgnoreVCS && (options.noRequireGit || isInGitRepository(directoryURL)) {
            ignoreStack.append(loadMatcher(
                from: directoryURL.appendingPathComponent(".gitignore"),
                caseInsensitive: options.ignoreFileCaseInsensitive
            ))
        }
        if !options.noIgnoreExclude,
           !options.noIgnoreVCS,
           (options.noRequireGit || isInGitRepository(directoryURL)),
           fileManager.fileExists(atPath: directoryURL.appendingPathComponent(".git").path) {
            ignoreStack.append(loadMatcher(
                from: directoryURL.appendingPathComponent(".git/info/exclude"),
                caseInsensitive: options.ignoreFileCaseInsensitive
            ))
        }
        if !options.noIgnoreDot {
            ignoreStack.append(loadMatcher(
                from: directoryURL.appendingPathComponent(".ignore"),
                caseInsensitive: options.ignoreFileCaseInsensitive
            ))
            ignoreStack.append(loadMatcher(
                from: directoryURL.appendingPathComponent(".rgignore"),
                caseInsensitive: options.ignoreFileCaseInsensitive
            ))
        }
    }
}
