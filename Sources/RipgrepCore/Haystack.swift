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
        for ignoreFile in options.ignoreFiles {
            baseIgnoreStack.append(loadMatcher(from: ignoreFile))
        }
        let overrides = GlobMatcher(patterns: options.globPatterns, overrideSemantics: true)

        for root in options.effectiveRoots {
            guard fileManager.fileExists(atPath: root.path) else {
                throw RipgrepError.missingPath(root.path)
            }
            let rootBase = rootBase(for: root.standardizedFileURL)
            haystacks.append(contentsOf: try walk(
                root.standardizedFileURL,
                isExplicit: true,
                rootBase: rootBase,
                ignoreStack: baseIgnoreStack,
                overrides: overrides,
                options: options
            ))
        }

        return haystacks.sorted { $0.url.path < $1.url.path }
    }

    private func walk(
        _ url: URL,
        isExplicit: Bool,
        rootBase: URL,
        ignoreStack: IgnoreStack,
        overrides: GlobMatcher,
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

        var directoryIgnoreStack = ignoreStack
        if !options.noIgnore {
            directoryIgnoreStack.append(loadMatcher(from: resolvedURL.appendingPathComponent(".ignore")))
            directoryIgnoreStack.append(loadMatcher(from: resolvedURL.appendingPathComponent(".gitignore")))
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
                rootBase: rootBase,
                ignoreStack: directoryIgnoreStack,
                overrides: overrides,
                options: options
            ))
        }
        return haystacks
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
