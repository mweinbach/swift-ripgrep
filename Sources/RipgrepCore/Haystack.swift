import Foundation

public struct Haystack: Equatable {
    public let url: URL
    public let isExplicit: Bool

    public init(url: URL, isExplicit: Bool) {
        self.url = url
        self.isExplicit = isExplicit
    }
}

public struct FileWalker {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func haystacks(for options: RipgrepOptions) throws -> [Haystack] {
        var haystacks: [Haystack] = []
        var baseIgnoreStack = IgnoreStack()
        if !options.noIgnoreFiles {
            for ignoreFile in options.ignoreFiles {
                baseIgnoreStack.append(loadMatcher(from: ignoreFile))
            }
        }
        let overrides = GlobMatcher(patterns: options.globPatterns, overrideSemantics: true)
        var typeRegistry = FileTypeRegistry()
        typeRegistry.apply(options.typeChanges)

        for root in options.effectiveRoots {
            guard fileManager.fileExists(atPath: root.path) else {
                throw RipgrepError.missingPath(root.path)
            }
            let rootBase = rootBase(for: root.standardizedFileURL)
            haystacks.append(contentsOf: try walk(
                root.standardizedFileURL,
                isExplicit: true,
                depth: 0,
                rootBase: rootBase,
                ignoreStack: baseIgnoreStack,
                overrides: overrides,
                typeRegistry: typeRegistry,
                options: options
            ))
        }

        return sorted(haystacks, options: options)
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
            return [Haystack(url: url, isExplicit: isExplicit)]
        }

        guard resolvedValues.isDirectory == true else {
            return []
        }
        if let maxDepth = options.maxDepth, depth >= maxDepth {
            return []
        }

        var directoryIgnoreStack = ignoreStack
        if !options.noIgnore && !options.noIgnoreVCS && (options.noRequireGit || isInGitRepository(resolvedURL)) {
            directoryIgnoreStack.append(loadMatcher(from: resolvedURL.appendingPathComponent(".gitignore")))
        }
        if !options.noIgnore && !options.noIgnoreDot {
            directoryIgnoreStack.append(loadMatcher(from: resolvedURL.appendingPathComponent(".ignore")))
            directoryIgnoreStack.append(loadMatcher(from: resolvedURL.appendingPathComponent(".rgignore")))
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

    private func loadMatcher(from fileURL: URL) -> GlobMatcher {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return GlobMatcher(patterns: [])
        }
        return GlobMatcher(patterns: contents.components(separatedBy: .newlines))
    }
}
