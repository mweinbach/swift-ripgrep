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

        for root in options.effectiveRoots {
            guard fileManager.fileExists(atPath: root.path) else {
                throw RipgrepError.missingPath(root.path)
            }
            haystacks.append(contentsOf: try walk(
                root.standardizedFileURL,
                isExplicit: true,
                options: options
            ))
        }

        return haystacks.sorted { $0.url.path < $1.url.path }
    }

    private func walk(
        _ url: URL,
        isExplicit: Bool,
        options: RipgrepOptions
    ) throws -> [Haystack] {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .nameKey,
        ])

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
            if !options.hidden && isHidden(child) {
                continue
            }
            haystacks.append(contentsOf: try walk(
                child,
                isExplicit: false,
                options: options
            ))
        }
        return haystacks
    }

    private func isHidden(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(".")
    }
}
