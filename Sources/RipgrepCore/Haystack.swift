import Foundation

public struct Haystack: Equatable {
    public let url: URL
    public let isExplicit: Bool
    public let overridePath: String

    public init(url: URL, isExplicit: Bool, overridePath: String? = nil) {
        self.url = url
        self.isExplicit = isExplicit
        self.overridePath = overridePath ?? url.path
    }
}

public struct FileWalkResults: Equatable {
    public let haystacks: [Haystack]
    public let messages: [String]
    public let warnings: [String]
    public let diagnostics: [String]
    public let filtered: Bool

    public init(
        haystacks: [Haystack],
        messages: [String],
        warnings: [String] = [],
        diagnostics: [String] = [],
        filtered: Bool = false
    ) {
        self.haystacks = haystacks
        self.messages = messages
        self.warnings = warnings
        self.diagnostics = diagnostics
        self.filtered = filtered
    }
}

private struct LoadedIgnoreMatcher {
    let matcher: GlobMatcher
    let messages: [String]
    let diagnostics: [String]
}

private struct DirectoryVisit {
    let logicalURL: URL
    let physicalPath: String
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
        var warnings: [String] = []
        var diagnostics: [String] = []
        var filtered = false
        let baseIgnoreStack = IgnoreStack()
        var reportedExplicitIgnoreFileWarnings = false
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

        let rootExistence = options.effectiveRoots.map { fileManager.fileExists(atPath: $0.path) }
        let hasExistingRoot = rootExistence.contains(true)
        for (offset, root) in options.effectiveRoots.enumerated() {
            if options.useStdin,
               offset < options.rootPathArguments.count,
               options.rootPathArguments[offset] == "-" {
                continue
            }
            guard offset < rootExistence.count, rootExistence[offset] else {
                let displayPath = rootDisplayPath(at: offset, root: root, options: options)
                messages.append(missingRootMessage(displayPath, options: options, hasExistingRoot: hasExistingRoot))
                continue
            }
            let rootBase = rootBase(for: root.standardizedFileURL)
            let rootArgument = offset < options.rootPathArguments.count ? options.rootPathArguments[offset] : ""
            let rootArgumentIsAbsolute = (rootArgument as NSString).isAbsolutePath
            let rootDebugDisplayPath = rootDisplayPath(at: offset, root: root, options: options)
            var rootIgnoreStack = baseIgnoreStack
            if reportedExplicitIgnoreFileWarnings {
                var ignoredWarnings: [String] = []
                appendExplicitIgnoreFiles(
                    to: &rootIgnoreStack,
                    rootBase: rootBase,
                    warnings: &ignoredWarnings,
                    diagnostics: &diagnostics,
                    options: options
                )
            } else {
                appendExplicitIgnoreFiles(
                    to: &rootIgnoreStack,
                    rootBase: rootBase,
                    warnings: &warnings,
                    diagnostics: &diagnostics,
                    options: options
                )
            }
            reportedExplicitIgnoreFileWarnings = true
            appendGlobalIgnoreFile(to: &rootIgnoreStack, rootBase: rootBase, warnings: &warnings, diagnostics: &diagnostics, options: options)
            appendParentIgnoreFiles(to: &rootIgnoreStack, rootBase: rootBase, warnings: &warnings, diagnostics: &diagnostics, options: options)
            appendLogicalParentIgnoreFiles(
                for: root.standardizedFileURL,
                rootBase: rootBase,
                to: &rootIgnoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                options: options
            )
            let rootVolume = options.oneFileSystem ? volumeIdentifier(for: root.standardizedFileURL) : nil
            let walked = try walk(
                root.standardizedFileURL,
                physicalURL: nil,
                isExplicit: true,
                depth: 0,
                ancestors: [],
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                rootVolume: rootVolume,
                messages: &messages,
                warnings: &warnings,
                diagnostics: &diagnostics,
                filtered: &filtered,
                ignoreStack: rootIgnoreStack,
                overrides: overrides,
                typeRegistry: typeRegistry,
                options: options
            )
            haystacks.append(contentsOf: sorted(walked, options: options))
        }

        return FileWalkResults(
            haystacks: ordered(haystacks, options: options),
            messages: messages,
            warnings: warnings,
            diagnostics: diagnostics,
            filtered: filtered
        )
    }

    private func missingRootMessage(_ displayPath: String, options: RipgrepOptions, hasExistingRoot: Bool) -> String {
        guard options.sortMode != nil || !hasExistingRoot else {
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
        physicalURL: URL?,
        isExplicit: Bool,
        depth: Int,
        ancestors: [DirectoryVisit],
        rootBase: URL,
        rootDebugDisplayPath: String,
        rootArgumentIsAbsolute: Bool,
        rootVolume: String?,
        messages: inout [String],
        warnings: inout [String],
        diagnostics: inout [String],
        filtered: inout Bool,
        ignoreStack: IgnoreStack,
        overrides: GlobMatcher,
        typeRegistry: FileTypeRegistry,
        options: RipgrepOptions
    ) throws -> [Haystack] {
        let metadataURL = physicalURL ?? url
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
        let overridePath = overridePath(for: url, rootArgumentIsAbsolute: rootArgumentIsAbsolute)

        if !isExplicit {
            let overrideDecision = overrides.decision(relativePath: overridePath, isDirectory: isDirectory)
            let isIncludedByOverride = overrideDecision == .include
            if overrideDecision == .exclude
                || (overrideDecision == nil && !overrides.allows(relativePath: overridePath, isDirectory: isDirectory)) {
                debug("ignoring \(url.path): override glob", options: options, diagnostics: &diagnostics)
                return []
            }
            if !isIncludedByOverride,
               !options.hidden,
               isHidden(url),
               (isDirectory || !typeRegistry.selectedTypeAllows(path: relativePath)),
               !isIncludedByIgnore(relativePath: relativePath, isDirectory: isDirectory, ignoreStack: ignoreStack) {
                debugHiddenMatch(
                    displayPath: debugDisplayPath(
                        for: url,
                        relativePath: relativePath,
                        rootDisplayPath: rootDebugDisplayPath,
                        rootArgumentIsAbsolute: rootArgumentIsAbsolute
                    ),
                    options: options,
                    diagnostics: &diagnostics
                )
                return []
            }
            if !isIncludedByOverride && !ignoreStack.allows(relativePath: relativePath, isDirectory: isDirectory) {
                debugIgnoreMatch(
                    path: url.path,
                    displayPath: debugDisplayPath(
                        for: url,
                        relativePath: relativePath,
                        rootDisplayPath: rootDebugDisplayPath,
                        rootArgumentIsAbsolute: rootArgumentIsAbsolute
                    ),
                    relativePath: relativePath,
                    isDirectory: isDirectory,
                    ignoreStack: ignoreStack,
                    options: options,
                    diagnostics: &diagnostics
                )
                filtered = true
                return []
            }
            if !isDirectory && !isIncludedByOverride && !typeRegistry.allows(path: relativePath) {
                debug("ignoring \(url.path): file type filter", options: options, diagnostics: &diagnostics)
                return []
            }
        }

        if values.isSymbolicLink == true && !options.followSymlinks && !isExplicit {
            return []
        }

        let resolvedURL = values.isSymbolicLink == true && (options.followSymlinks || isExplicit)
            ? url.resolvingSymlinksInPath()
            : metadataURL
        if values.isSymbolicLink == true,
           (options.followSymlinks || isExplicit),
           !fileManager.fileExists(atPath: resolvedURL.path) {
            messages.append(fileSystemMessage(for: url, errno: ENOENT))
            return []
        }
        let resolvedValues: URLResourceValues
        do {
            resolvedValues = try resolvedURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .nameKey,
            ])
        } catch {
            messages.append(fileSystemMessage(for: url, error: error))
            return []
        }

        if resolvedValues.isRegularFile == true {
            if !isExplicit,
               let maxFileSize = options.maxFileSize,
               let fileSize = values.fileSize,
               UInt64(fileSize) > maxFileSize {
                debug("ignoring \(url.path): \(fileSize) bytes exceeds max filesize \(maxFileSize)", options: options, diagnostics: &diagnostics)
                return []
            }
            return [Haystack(url: url, isExplicit: isExplicit, overridePath: overridePath)]
        }

        guard resolvedValues.isDirectory == true else {
            return []
        }
        let resolvedDirectoryPath = resolvedURL.standardizedFileURL.path
        if let ancestor = ancestors.last(where: { $0.physicalPath == resolvedDirectoryPath }) {
            messages.append("File system loop found: \(url.path) points to an ancestor \(ancestor.logicalURL.path)")
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
                logicalDirectory: url,
                to: &directoryIgnoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                options: options
            )
        }

        let childAncestors = ancestors + [DirectoryVisit(
            logicalURL: url,
            physicalPath: resolvedDirectoryPath
        )]
        let children = try fileManager.contentsOfDirectory(
            at: resolvedURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .nameKey,
            ],
            options: []
        )

        var haystacks: [Haystack] = []
        for child in children {
            let childURL = url.appendingPathComponent(child.lastPathComponent)
            haystacks.append(contentsOf: try walk(
                childURL,
                physicalURL: child,
                isExplicit: false,
                depth: depth + 1,
                ancestors: childAncestors,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                rootVolume: rootVolume,
                messages: &messages,
                warnings: &warnings,
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

    private func fileSystemMessage(for url: URL, error: Error) -> String {
        if let cocoaError = error as? CocoaError,
           let underlying = cocoaError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == ENOENT {
            return fileSystemMessage(for: url, errno: ENOENT)
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == ENOENT {
            return fileSystemMessage(for: url, errno: ENOENT)
        }
        return "\(url.path): \(error)"
    }

    private func fileSystemMessage(for url: URL, errno: Int32) -> String {
        switch errno {
        case ENOENT:
            return "\(url.path): IO error for operation on \(url.path): No such file or directory (os error 2)"
        default:
            return "\(url.path): IO error for operation on \(url.path): \(String(cString: strerror(errno))) (os error \(errno))"
        }
    }

    private func debug(_ message: String, options: RipgrepOptions, diagnostics: inout [String]) {
        guard options.loggingMode != nil else {
            return
        }
        diagnostics.append("DEBUG|swift-ripgrep::walk| \(message)")
    }

    private func debugIgnoreMatch(
        path: String,
        displayPath: String,
        relativePath: String,
        isDirectory: Bool,
        ignoreStack: IgnoreStack,
        options: RipgrepOptions,
        diagnostics: inout [String]
    ) {
        guard options.loggingMode != nil else {
            return
        }
        guard let rule = ignoreStack.matchingRule(relativePath: relativePath, isDirectory: isDirectory) else {
            diagnostics.append("DEBUG|swift-ripgrep::walk| ignoring \(displayPath): ignore file")
            return
        }
        let from = rule.sourcePath.map { #"Some("\#($0)")"# } ?? "None"
        let match = "Ignore(IgnoreMatch(Gitignore(Glob { from: \(from), original: \"\(rule.originalPattern)\", actual: \"\(rule.actualPattern)\", is_whitelist: \(rule.decision == .include ? "true" : "false"), is_only_dir: \(rule.directoryOnly ? "true" : "false") })))"
        diagnostics.append("DEBUG|ignore::walk|crates/ignore/src/walk.rs:1942: ignoring \(displayPath): \(match)")
    }

    private func debugHiddenMatch(
        displayPath: String,
        options: RipgrepOptions,
        diagnostics: inout [String]
    ) {
        guard options.loggingMode != nil else {
            return
        }
        diagnostics.append("DEBUG|ignore::walk|crates/ignore/src/walk.rs:1942: ignoring \(displayPath): Ignore(IgnoreMatch(Hidden))")
    }

    private func debugDisplayPath(
        for url: URL,
        relativePath: String,
        rootDisplayPath: String,
        rootArgumentIsAbsolute: Bool
    ) -> String {
        guard !rootArgumentIsAbsolute else {
            return url.path
        }
        guard !relativePath.isEmpty else {
            return rootDisplayPath
        }
        let root = rootDisplayPath.isEmpty ? "." : rootDisplayPath
        if root == "." {
            return "./\(relativePath)"
        }
        let separator = root.hasSuffix("/") ? "" : "/"
        return "\(root)\(separator)\(relativePath)"
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

    private func ordered(_ haystacks: [Haystack], options: RipgrepOptions) -> [Haystack] {
        if options.mode == .files,
           options.sortMode?.reverse == true {
            return sorted(haystacks, options: options)
        }
        guard options.sortMode == nil, options.threadCount == nil else {
            return haystacks
        }
        if options.mode == .files,
           haystacks.count > 1,
           haystacks.allSatisfy(\.isExplicit) {
            return haystacks.reversed()
        }
        guard haystacks.contains(where: { !$0.isExplicit }) else {
            return haystacks
        }
        return haystacks.reversed()
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
        PathSort.compare(lhs, rhs)
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
        if (try? root.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return root
        }
        return root.deletingLastPathComponent()
    }

    private func appendLogicalParentIgnoreFiles(
        for root: URL,
        rootBase: URL,
        to ignoreStack: inout IgnoreStack,
        warnings: inout [String],
        diagnostics: inout [String],
        rootDebugDisplayPath: String,
        rootArgumentIsAbsolute: Bool,
        options: RipgrepOptions
    ) {
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
              (try? root.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return
        }
        appendIgnoreFiles(
            in: rootBase,
            to: &ignoreStack,
            warnings: &warnings,
            diagnostics: &diagnostics,
            rootBase: rootBase,
            rootDebugDisplayPath: rootDebugDisplayPath,
            rootArgumentIsAbsolute: rootArgumentIsAbsolute,
            options: options
        )
    }

    private func appendParentIgnoreFiles(
        to ignoreStack: inout IgnoreStack,
        rootBase: URL,
        warnings: inout [String],
        diagnostics: inout [String],
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
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                options: options
            )
            appendParentVCSIgnoreFiles(
                in: parentURL,
                gitBoundary: gitBoundary,
                to: &ignoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                options: options
            )
        }
    }

    private func appendParentDotIgnoreFiles(
        in parentURL: URL,
        to ignoreStack: inout IgnoreStack,
        warnings: inout [String],
        diagnostics: inout [String],
        rootBase: URL,
        options: RipgrepOptions
    ) {
        guard !options.noIgnoreDot else {
            return
        }
        appendLoadedMatcher(
            from: parentURL.appendingPathComponent(".ignore"),
            to: &ignoreStack,
            warnings: &warnings,
            diagnostics: &diagnostics,
            rootBase: rootBase,
            ignoreExplicitRootMatch: true,
            options: options
        )
        appendLoadedMatcher(
            from: parentURL.appendingPathComponent(".rgignore"),
            to: &ignoreStack,
            warnings: &warnings,
            diagnostics: &diagnostics,
            rootBase: rootBase,
            ignoreExplicitRootMatch: true,
            options: options
        )
    }

    private func appendParentVCSIgnoreFiles(
        in parentURL: URL,
        gitBoundary: URL?,
        to ignoreStack: inout IgnoreStack,
        warnings: inout [String],
        diagnostics: inout [String],
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
            warnings: &warnings,
            diagnostics: &diagnostics,
            rootBase: rootBase,
            ignoreExplicitRootMatch: true,
            options: options
        )
        if !options.noIgnoreExclude,
           let excludeURL = gitInfoExcludeURL(for: parentURL) {
            appendLoadedMatcher(
                from: excludeURL,
                to: &ignoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                scopeDirectory: parentURL,
                ignoreExplicitRootMatch: true,
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
        warnings: inout [String],
        diagnostics: inout [String],
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
            warnings: &warnings,
            diagnostics: &diagnostics,
            rootBase: nil,
            emitDiagnostics: false,
            options: options
        )
    }

    private func appendExplicitIgnoreFiles(
        to ignoreStack: inout IgnoreStack,
        rootBase: URL,
        warnings: inout [String],
        diagnostics: inout [String],
        options: RipgrepOptions
    ) {
        guard !options.noIgnoreFiles else {
            return
        }
        let pathPrefix = cwdRelativePathPrefix(for: rootBase)
        for (offset, ignoreFile) in options.ignoreFiles.enumerated() {
            appendLoadedMatcher(
                from: ignoreFile,
                to: &ignoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                pathPrefix: pathPrefix,
                slashPatternsMatchAnywhere: false,
                reportLoadErrors: true,
                displayPath: offset < options.ignoreFileDisplayPaths.count ? options.ignoreFileDisplayPaths[offset] : nil,
                caseInsensitive: false,
                options: options
            )
        }
    }

    private func cwdRelativePathPrefix(for rootBase: URL) -> String {
        let rootPath = rootBase.standardizedFileURL.path
        let cwdPath = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
            .path
        if rootPath == cwdPath {
            return ""
        }
        let prefix = cwdPath.hasSuffix("/") ? cwdPath : "\(cwdPath)/"
        if rootPath.hasPrefix(prefix) {
            return String(rootPath.dropFirst(prefix.count))
        }
        return rootPath.hasPrefix("/") ? String(rootPath.dropFirst()) : rootPath
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

    private func overridePath(for url: URL, rootArgumentIsAbsolute: Bool) -> String {
        let path = url.standardizedFileURL.path
        guard !rootArgumentIsAbsolute else {
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
            .path
        let prefix = cwd.hasSuffix("/") ? cwd : "\(cwd)/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
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
        warnings: inout [String],
        diagnostics: inout [String],
        rootBase: URL?,
        scopeDirectory: URL? = nil,
        pathPrefix: String? = nil,
        slashPatternsMatchAnywhere: Bool? = nil,
        reportLoadErrors: Bool = false,
        displayPath: String? = nil,
        caseInsensitive: Bool? = nil,
        ignoreExplicitRootMatch: Bool = false,
        emitDiagnostics: Bool = true,
        options: RipgrepOptions
    ) {
        let loaded = loadMatcher(
            from: fileURL,
            rootBase: rootBase,
            scopeDirectory: scopeDirectory,
            pathPrefix: pathPrefix,
            slashPatternsMatchAnywhere: slashPatternsMatchAnywhere,
            reportLoadErrors: reportLoadErrors,
            displayPath: displayPath,
            caseInsensitive: caseInsensitive ?? options.ignoreFileCaseInsensitive,
            ignoreExplicitRootMatch: ignoreExplicitRootMatch
        )
        ignoreStack.append(loaded.matcher)
        if emitDiagnostics, options.loggingMode != .none {
            diagnostics.append(contentsOf: loaded.diagnostics)
        }
        if !options.noIgnoreMessages {
            warnings.append(contentsOf: loaded.messages)
        }
    }

    private func loadMatcher(
        from fileURL: URL,
        rootBase: URL?,
        scopeDirectory: URL? = nil,
        pathPrefix: String? = nil,
        slashPatternsMatchAnywhere: Bool? = nil,
        reportLoadErrors: Bool = false,
        displayPath: String? = nil,
        caseInsensitive: Bool = false,
        ignoreExplicitRootMatch: Bool = false
    ) -> LoadedIgnoreMatcher {
        let contents: String
        do {
            contents = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            let messages = reportLoadErrors ? [ignoreFileLoadMessage(for: fileURL, displayPath: displayPath)] : []
            return LoadedIgnoreMatcher(matcher: GlobMatcher(patterns: []), messages: messages, diagnostics: [])
        }
        let parsed = parseIgnorePatterns(contents, fileURL: fileURL)
        let scope = pathPrefix.map { (stripBasePath: String?.none, pathPrefix: $0) }
            ?? ignoreScope(for: scopeDirectory ?? fileURL.deletingLastPathComponent(), rootBase: rootBase)
        let matchSlashPatternsAnywhere = slashPatternsMatchAnywhere ?? false
        let patterns = ignoreExplicitRootMatch
            ? patternsIgnoringExplicitRootMatch(
                parsed.patterns,
                scope: scope,
                slashPatternsMatchAnywhere: matchSlashPatternsAnywhere,
                caseInsensitive: caseInsensitive
            )
            : parsed.patterns
        let diagnostics = ignoreLoadDiagnostics(
            fileURL: fileURL,
            displayPath: displayPath,
            patterns: patterns
        )
        return LoadedIgnoreMatcher(matcher: GlobMatcher(
            patterns: patterns,
            caseInsensitive: caseInsensitive,
            stripBasePath: scope.stripBasePath,
            pathPrefix: scope.pathPrefix,
            slashPatternsMatchAnywhere: matchSlashPatternsAnywhere,
            sourcePath: ignoreDiagnosticPath(fileURL, displayPath: displayPath)
        ), messages: parsed.messages, diagnostics: diagnostics)
    }

    private func ignoreLoadDiagnostics(fileURL: URL, displayPath: String?, patterns: [String]) -> [String] {
        let opened = "DEBUG|ignore::gitignore|crates/ignore/src/gitignore.rs:398: opened gitignore file: \(ignoreDiagnosticPath(fileURL, displayPath: displayPath))"
        return [
            opened,
            "DEBUG|globset|crates/globset/src/lib.rs:515: built glob set; \(globsetSummary(for: patterns))",
        ]
    }

    private func ignoreDiagnosticPath(_ fileURL: URL, displayPath: String?) -> String {
        if let displayPath {
            return displayPath
        }
        let path = fileURL.standardizedFileURL.path
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
            .path
        let prefix = cwd.hasSuffix("/") ? cwd : "\(cwd)/"
        if path.hasPrefix(prefix) {
            return "./\(String(path.dropFirst(prefix.count)))"
        }
        return path
    }

    private func globsetSummary(for patterns: [String]) -> String {
        let parsed = patterns.compactMap(globsetPatternSummary)
        let literals = parsed.filter { $0 == .literal }.count
        let basenames = parsed.filter { $0 == .basename }.count
        let extensions = parsed.filter { $0 == .extension }.count
        let prefixes = parsed.filter { $0 == .prefix }.count
        let suffixes = parsed.filter { $0 == .suffix }.count
        let regexes = parsed.filter { $0 == .regex }.count
        return "\(literals) literals, \(basenames) basenames, \(extensions) extensions, \(prefixes) prefixes, \(suffixes) suffixes, 0 required extensions, \(regexes) regexes"
    }

    private enum GlobsetPatternKind {
        case literal
        case basename
        case `extension`
        case prefix
        case suffix
        case regex
    }

    private func globsetPatternSummary(_ rawPattern: String) -> GlobsetPatternKind? {
        var pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else {
            return nil
        }
        if pattern.hasPrefix("!") {
            pattern.removeFirst()
        }
        if pattern.hasSuffix("/") {
            pattern.removeLast()
        }
        if pattern.hasPrefix("/") {
            pattern.removeFirst()
        }
        if pattern.hasPrefix("*."),
           pattern.dropFirst(2).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            return .extension
        }
        if !pattern.contains("*"), !pattern.contains("?"), !pattern.contains("["), !pattern.contains("{") {
            return pattern.contains("/") ? .literal : .basename
        }
        if pattern.hasSuffix("*"), pattern.dropLast().allSatisfy({ $0 != "*" && $0 != "?" && $0 != "[" && $0 != "{" }) {
            return .prefix
        }
        if pattern.hasPrefix("*"), pattern.dropFirst().allSatisfy({ $0 != "*" && $0 != "?" && $0 != "[" && $0 != "{" }) {
            return .suffix
        }
        return .regex
    }

    private func patternsIgnoringExplicitRootMatch(
        _ patterns: [String],
        scope: (stripBasePath: String?, pathPrefix: String),
        slashPatternsMatchAnywhere: Bool?,
        caseInsensitive: Bool
    ) -> [String] {
        guard !scope.pathPrefix.isEmpty else {
            return patterns
        }
        return patterns.filter { pattern in
            let matcher = GlobMatcher(
                patterns: [pattern],
                caseInsensitive: caseInsensitive,
                stripBasePath: scope.stripBasePath,
                pathPrefix: scope.pathPrefix,
                slashPatternsMatchAnywhere: slashPatternsMatchAnywhere
            )
            return matcher.decision(relativePath: "", isDirectory: true) != .exclude
        }
    }

    private func ignoreFileLoadMessage(for fileURL: URL, displayPath: String?) -> String {
        let renderedPath = displayPath ?? fileURL.path
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "\(renderedPath): line 1: Is a directory (os error 21)"
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            return "\(renderedPath): No such file or directory (os error 2)"
        }
        return "\(renderedPath): error reading ignore file"
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
        logicalDirectory: URL? = nil,
        to ignoreStack: inout IgnoreStack,
        warnings: inout [String],
        diagnostics: inout [String],
        rootBase: URL,
        rootDebugDisplayPath: String,
        rootArgumentIsAbsolute: Bool,
        options: RipgrepOptions
    ) {
        let scopeDirectory = logicalDirectory ?? directoryURL
        if !options.noIgnoreDot {
            let ignoreURL = directoryURL.appendingPathComponent(".ignore")
            appendLoadedMatcher(
                from: ignoreURL,
                to: &ignoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                scopeDirectory: scopeDirectory,
                displayPath: ignoreFileDebugDisplayPath(
                    for: scopeDirectory.appendingPathComponent(".ignore"),
                    rootBase: rootBase,
                    rootDisplayPath: rootDebugDisplayPath,
                    rootArgumentIsAbsolute: rootArgumentIsAbsolute
                ),
                options: options
            )
            let rgignoreURL = directoryURL.appendingPathComponent(".rgignore")
            appendLoadedMatcher(
                from: rgignoreURL,
                to: &ignoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                scopeDirectory: scopeDirectory,
                displayPath: ignoreFileDebugDisplayPath(
                    for: scopeDirectory.appendingPathComponent(".rgignore"),
                    rootBase: rootBase,
                    rootDisplayPath: rootDebugDisplayPath,
                    rootArgumentIsAbsolute: rootArgumentIsAbsolute
                ),
                options: options
            )
        }
        if !options.noIgnoreVCS && (options.noRequireGit || isInGitRepository(directoryURL)) {
            let gitignoreURL = directoryURL.appendingPathComponent(".gitignore")
            appendLoadedMatcher(
                from: gitignoreURL,
                to: &ignoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                scopeDirectory: scopeDirectory,
                displayPath: ignoreFileDebugDisplayPath(
                    for: scopeDirectory.appendingPathComponent(".gitignore"),
                    rootBase: rootBase,
                    rootDisplayPath: rootDebugDisplayPath,
                    rootArgumentIsAbsolute: rootArgumentIsAbsolute
                ),
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
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                scopeDirectory: scopeDirectory,
                displayPath: ignoreFileDebugDisplayPath(
                    for: scopeDirectory.appendingPathComponent(".git/info/exclude"),
                    rootBase: rootBase,
                    rootDisplayPath: rootDebugDisplayPath,
                    rootArgumentIsAbsolute: rootArgumentIsAbsolute
                ),
                options: options
            )
        }
    }

    private func ignoreFileDebugDisplayPath(
        for logicalURL: URL,
        rootBase: URL,
        rootDisplayPath: String,
        rootArgumentIsAbsolute: Bool
    ) -> String {
        debugDisplayPath(
            for: logicalURL,
            relativePath: relativePath(for: logicalURL, rootBase: rootBase),
            rootDisplayPath: rootDisplayPath,
            rootArgumentIsAbsolute: rootArgumentIsAbsolute
        )
    }
}
