import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct Haystack: Equatable, Sendable {
    public let url: URL
    public let isExplicit: Bool
    public let overridePath: String
    public let fileSize: UInt64?
    public let isRegularFile: Bool?

    public init(
        url: URL,
        isExplicit: Bool,
        overridePath: String? = nil,
        fileSize: UInt64? = nil,
        isRegularFile: Bool? = nil
    ) {
        self.url = url
        self.isExplicit = isExplicit
        self.overridePath = overridePath ?? url.path
        self.fileSize = fileSize
        self.isRegularFile = isRegularFile
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

public struct FilePathStreamResults: Equatable {
    public let count: Int
    public let messages: [String]
    public let warnings: [String]
    public let diagnostics: [String]
    public let filtered: Bool
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

private struct DirectoryChild {
    let url: URL
    let name: String
    let metadata: WalkMetadata?
}

private struct DirectoryContents {
    let children: [DirectoryChild]
    let hasGitMarker: Bool
    let hasGitignore: Bool
    let hasIgnore: Bool
    let hasRgignore: Bool
}

private struct WalkMetadata {
    let isDirectory: Bool
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let fileSize: UInt64?
}

#if canImport(Darwin)
private let darwinFilePathDataWorkerLimit = 8

private struct FastDirectoryChild {
    let name: String
    let isASCII: Bool
    let isHidden: Bool
    let kind: FastDirectoryEntryKind
}

private struct FastDirectoryByteChild: Sendable {
    let nameBytes: [UInt8]
    let isASCII: Bool
    let isHidden: Bool
    let kind: FastDirectoryEntryKind
}

private struct FastDirectoryContents {
    let children: [FastDirectoryChild]
    let hasGitMarker: Bool
    let hasGitignore: Bool
    let hasIgnore: Bool
    let hasRgignore: Bool
}

private enum FastDirectoryEntryKind: Equatable, Sendable {
    case directory
    case file
    case symbolicLink
    case other

    var isDirectory: Bool {
        if case .directory = self {
            return true
        }
        return false
    }

    var isFile: Bool {
        if case .file = self {
            return true
        }
        return false
    }
}

private struct DarwinNoIgnoreFilePathChunk: @unchecked Sendable {
    let data: Data
    let count: Int
}

private struct DarwinNoIgnoreFilePathWorkItem: @unchecked Sendable {
    let index: Int
    let directoryPathBytes: [UInt8]
    let logicalPathBytes: [UInt8]
    let logicalPathIsASCII: Bool
}

private final class DarwinNoIgnoreFilePathWorkQueue: @unchecked Sendable {
    private let items: [DarwinNoIgnoreFilePathWorkItem]
    private let lock = NSLock()
    private var nextIndex = 0

    init(items: [DarwinNoIgnoreFilePathWorkItem]) {
        self.items = items
    }

    func next() -> DarwinNoIgnoreFilePathWorkItem? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard nextIndex < items.count else {
            return nil
        }
        let item = items[nextIndex]
        nextIndex += 1
        return item
    }
}

private struct DarwinFilePathStringChunk: @unchecked Sendable {
    let lines: [String]
    let messages: [String]
    let warnings: [String]
    let diagnostics: [String]
    let filtered: Bool
}

private struct DarwinFilePathDataChunk: @unchecked Sendable {
    let data: Data
    let count: Int
    let messages: [String]
    let warnings: [String]
    let diagnostics: [String]
    let filtered: Bool
}

private struct DarwinFilePathDataWorkItem: @unchecked Sendable {
    let index: Int
    let childName: String
    let childIsASCII: Bool
    let childLogicalPathBytes: [UInt8]
}

private final class DarwinFilePathDataWorkQueue: @unchecked Sendable {
    private let items: [DarwinFilePathDataWorkItem]
    private let lock = NSLock()
    private var nextIndex = 0

    init(items: [DarwinFilePathDataWorkItem]) {
        self.items = items
    }

    func next() -> DarwinFilePathDataWorkItem? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard nextIndex < items.count else {
            return nil
        }
        let item = items[nextIndex]
        nextIndex += 1
        return item
    }
}

private struct DarwinFilePathRootPlan {
    let rootURL: URL
    let rootBase: URL
    let rootArgumentIsAbsolute: Bool
    let logicalPath: String
    let logicalPathBytes: [UInt8]
    let logicalPathIsASCII: Bool
}

private final class DarwinNoIgnoreFilePathChunkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Result<DarwinNoIgnoreFilePathChunk, Error>?]

    init(count: Int) {
        self.chunks = Array(repeating: nil, count: count)
    }

    func store(_ result: Result<DarwinNoIgnoreFilePathChunk, Error>, at index: Int) {
        lock.lock()
        chunks[index] = result
        lock.unlock()
    }

    func orderedChunks() throws -> [DarwinNoIgnoreFilePathChunk] {
        lock.lock()
        let snapshot = chunks
        lock.unlock()
        return try snapshot.map { result in
            try result!.get()
        }
    }
}

private final class DarwinFilePathStringChunkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Result<DarwinFilePathStringChunk, Error>?]

    init(count: Int) {
        self.chunks = Array(repeating: nil, count: count)
    }

    func store(_ result: Result<DarwinFilePathStringChunk, Error>, at index: Int) {
        lock.lock()
        chunks[index] = result
        lock.unlock()
    }

    func orderedChunks() throws -> [DarwinFilePathStringChunk] {
        lock.lock()
        let snapshot = chunks
        lock.unlock()
        return try snapshot.map { result in
            try result!.get()
        }
    }
}

private final class DarwinFilePathDataChunkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Result<DarwinFilePathDataChunk, Error>?]

    init(count: Int) {
        self.chunks = Array(repeating: nil, count: count)
    }

    func store(_ result: Result<DarwinFilePathDataChunk, Error>, at index: Int) {
        lock.lock()
        chunks[index] = result
        lock.unlock()
    }

    func orderedChunks() throws -> [DarwinFilePathDataChunk] {
        lock.lock()
        let snapshot = chunks
        lock.unlock()
        return try snapshot.map { result in
            try result!.get()
        }
    }
}
#endif

public struct FileWalker: @unchecked Sendable {
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

    public func streamFilePathsWithMessages(
        for options: RipgrepOptions,
        stopAfterFirst: Bool = false,
        emit: (String) -> Void
    ) throws -> FilePathStreamResults? {
        #if canImport(Darwin)
        guard canFastWalkFilePaths(options: options, allowPathSort: true),
              options.effectiveRoots.count == 1 else {
            return nil
        }
        let pathSortMode = options.sortMode?.kind == .path ? options.sortMode : nil
        var sortedFilePathLines: [String] = []
        var sortedFilePathCommonPrefixByteCount = 0
        if pathSortMode != nil {
            sortedFilePathLines.reserveCapacity(1024)
        }
        func emitOrCollect(_ line: String) {
            if pathSortMode != nil {
                sortedFilePathLines.append(line)
            } else {
                emit(line)
            }
        }
        var messages: [String] = []
        var warnings: [String] = []
        var diagnostics: [String] = []
        var filtered = false
        var emittedCount = 0
        let root = options.effectiveRoots[0]
        guard let rootPlan = fastFilePathRootPlan(root: root, options: options) else {
            if !fileManager.fileExists(atPath: root.path) {
                let displayPath = rootDisplayPath(at: 0, root: root, options: options)
                messages.append(missingRootMessage(displayPath, options: options, hasExistingRoot: false))
                return FilePathStreamResults(count: 0, messages: messages, warnings: warnings, diagnostics: diagnostics, filtered: false)
            }
            return nil
        }
        if pathSortMode != nil,
           rootPlan.logicalPathIsASCII,
           !rootPlan.logicalPathBytes.isEmpty {
            sortedFilePathCommonPrefixByteCount = rootPlan.logicalPathBytes.count + 1
        }

        if stopAfterFirst, options.quiet, options.noIgnore, options.loggingMode == nil {
            let hasFile = try fastDirectoryTreeContainsFile(atPath: rootPlan.rootURL.path, includeHidden: options.hidden)
            return FilePathStreamResults(
                count: hasFile ? 1 : 0,
                messages: messages,
                warnings: warnings,
                diagnostics: diagnostics,
                filtered: false
            )
        }

        let rootVCSContext = options.noRequireGit || isInGitRepository(rootPlan.rootBase)
        var rootIgnoreStack = IgnoreStack()
        appendExplicitIgnoreFiles(
            to: &rootIgnoreStack,
            rootBase: rootPlan.rootBase,
            rootVCSContext: rootVCSContext,
            warnings: &warnings,
            diagnostics: &diagnostics,
            options: options
        )
        appendGlobalIgnoreFile(to: &rootIgnoreStack, rootBase: rootPlan.rootBase, warnings: &warnings, diagnostics: &diagnostics, options: options)
        appendParentIgnoreFiles(to: &rootIgnoreStack, rootBase: rootPlan.rootBase, warnings: &warnings, diagnostics: &diagnostics, options: options)
        if stopAfterFirst, options.quiet, options.loggingMode == nil {
            let hasFile = try fastDirectoryTreeContainsAllowedFile(
                directoryPath: rootPlan.rootURL.path,
                logicalDirectoryPath: rootPlan.logicalPath,
                relativePath: "",
                rootBase: rootPlan.rootBase,
                rootDebugDisplayPath: rootDisplayPath(at: 0, root: root, options: options),
                rootArgumentIsAbsolute: rootPlan.rootArgumentIsAbsolute,
                vcsContext: rootVCSContext,
                warnings: &warnings,
                diagnostics: &diagnostics,
                filtered: &filtered,
                ignoreStack: rootIgnoreStack,
                options: options
            )
            return FilePathStreamResults(
                count: hasFile ? 1 : 0,
                messages: messages,
                warnings: warnings,
                diagnostics: diagnostics,
                filtered: filtered
            )
        }
        if let parallelResults = try streamFilePathsInOutputOrderParallel(
            rootURL: rootPlan.rootURL,
            logicalRootPath: rootPlan.logicalPath,
            logicalRootPathIsASCII: rootPlan.logicalPathIsASCII,
            rootBase: rootPlan.rootBase,
            rootDebugDisplayPath: rootDisplayPath(at: 0, root: root, options: options),
            rootVCSContext: rootVCSContext,
            rootIgnoreStack: rootIgnoreStack,
            options: options,
            stopAfterFirst: stopAfterFirst,
            emit: emitOrCollect
        ) {
            messages.append(contentsOf: parallelResults.messages)
            warnings.append(contentsOf: parallelResults.warnings)
            diagnostics.append(contentsOf: parallelResults.diagnostics)
            filtered = filtered || parallelResults.filtered
            if let pathSortMode {
                emitSortedFilePathLines(
                    sortedFilePathLines,
                    reverse: pathSortMode.reverse,
                    commonPrefixByteCount: sortedFilePathCommonPrefixByteCount,
                    sortInPlace: options.noIgnore && !options.hidden,
                    emit: emit
                )
            }
            return FilePathStreamResults(
                count: parallelResults.count,
                messages: messages,
                warnings: warnings,
                diagnostics: diagnostics,
                filtered: filtered
            )
        }
        var didStop = false
        try walkFilePathsInOutputOrder(
            directoryPath: rootPlan.rootURL.path,
            logicalDirectoryPath: rootPlan.logicalPath,
            logicalDirectoryPathIsASCII: rootPlan.logicalPathIsASCII,
            relativePath: "",
            rootBase: rootPlan.rootBase,
            rootDebugDisplayPath: rootDisplayPath(at: 0, root: root, options: options),
            rootArgumentIsAbsolute: rootPlan.rootArgumentIsAbsolute,
            vcsContext: rootVCSContext,
            messages: &messages,
            warnings: &warnings,
            diagnostics: &diagnostics,
            filtered: &filtered,
            ignoreStack: rootIgnoreStack,
            options: options,
            stopAfterFirst: stopAfterFirst,
            didStop: &didStop
        ) { path in
            emittedCount += 1
            emitOrCollect(path)
        }
        if let pathSortMode {
            emitSortedFilePathLines(
                sortedFilePathLines,
                reverse: pathSortMode.reverse,
                commonPrefixByteCount: sortedFilePathCommonPrefixByteCount,
                sortInPlace: options.noIgnore && !options.hidden,
                emit: emit
            )
        }
        return FilePathStreamResults(
            count: emittedCount,
            messages: messages,
            warnings: warnings,
            diagnostics: diagnostics,
            filtered: filtered
        )
        #else
        return nil
        #endif
    }

    func writeDarwinFilePathsWithMessages(
        for options: RipgrepOptions,
        stopAfterFirst: Bool = false,
        writeBytes: (UnsafeRawBufferPointer) -> Void
    ) throws -> FilePathStreamResults? {
        #if canImport(Darwin)
        guard canFastWalkFilePaths(options: options, allowNullPathTerminator: true),
              options.effectiveRoots.count == 1,
              !stopAfterFirst else {
            return nil
        }
        if !canUseNoIgnoreDarwinFilePathWalker(options: options) {
            return try writeDarwinIgnoreFilePathsWithMessages(for: options, writeBytes: writeBytes)
        }
        var messages: [String] = []
        var outputBuffer = Data()
        outputBuffer.reserveCapacity(64 * 1024)

        let root = options.effectiveRoots[0]
        guard let rootPlan = fastFilePathRootPlan(root: root, options: options) else {
            if !fileManager.fileExists(atPath: root.path) {
                let displayPath = rootDisplayPath(at: 0, root: root, options: options)
                messages.append(missingRootMessage(displayPath, options: options, hasExistingRoot: false))
                return FilePathStreamResults(count: 0, messages: messages, warnings: [], diagnostics: [], filtered: false)
            }
            return nil
        }

        let terminator = options.nullPathTerminator ? UInt8(0) : UInt8(ascii: "\n")
        var emittedCount = 0
        var directoryPathBytes = Array(rootPlan.rootURL.path.utf8)
        var logicalPathBytes = rootPlan.logicalPathBytes
        if let parallelEmittedCount = try writeDarwinNoIgnoreFilePathsInOutputOrderParallel(
            directoryPathBytes: directoryPathBytes,
            logicalPathBytes: logicalPathBytes,
            logicalPathIsASCII: rootPlan.logicalPathIsASCII,
            includeHidden: options.hidden,
            terminator: terminator,
            writeBytes: writeBytes
        ) {
            return FilePathStreamResults(
                count: parallelEmittedCount,
                messages: messages,
                warnings: [],
                diagnostics: [],
                filtered: false
            )
        }
        try writeDarwinNoIgnoreFilePathsInOutputOrder(
            directoryPathBytes: &directoryPathBytes,
            logicalPathBytes: &logicalPathBytes,
            logicalPathIsASCII: rootPlan.logicalPathIsASCII,
            includeHidden: options.hidden,
            terminator: terminator,
            emittedCount: &emittedCount,
            outputBuffer: &outputBuffer,
            writeBytes: writeBytes
        )
        flushDarwinFilePathOutputBuffer(&outputBuffer, writeBytes: writeBytes)

        return FilePathStreamResults(
            count: emittedCount,
            messages: messages,
            warnings: [],
            diagnostics: [],
            filtered: false
        )
        #else
        return nil
        #endif
    }

    #if canImport(Darwin)
    private func fastFilePathRootPlan(root: URL, options: RipgrepOptions) -> DarwinFilePathRootPlan? {
        let rootURL = root.standardizedFileURL
        guard isDirectoryPath(rootURL.path) else {
            return nil
        }
        let rootBase = rootURL

        let rootArgument = options.rootPathArguments.first ?? ""
        let logicalPath: String
        let rootArgumentIsAbsolute: Bool
        if rootArgument.isEmpty {
            let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .standardizedFileURL
                .path
            guard rootURL.path == currentDirectory else {
                return nil
            }
            logicalPath = ""
            rootArgumentIsAbsolute = false
        } else {
            guard URL(fileURLWithPath: rootArgument).standardizedFileURL.path == rootURL.path else {
                return nil
            }
            logicalPath = trimmingTrailingSlashes(rootArgument)
            rootArgumentIsAbsolute = (rootArgument as NSString).isAbsolutePath
        }

        let logicalPathBytes = Array(logicalPath.utf8)
        return DarwinFilePathRootPlan(
            rootURL: rootURL,
            rootBase: rootBase,
            rootArgumentIsAbsolute: rootArgumentIsAbsolute,
            logicalPath: logicalPath,
            logicalPathBytes: logicalPathBytes,
            logicalPathIsASCII: logicalPathBytes.allSatisfy { $0 < 0x80 }
        )
    }

    private func canUseNoIgnoreDarwinFilePathWalker(options: RipgrepOptions) -> Bool {
        if options.noIgnore {
            return true
        }
        guard options.noIgnoreDot,
              options.noIgnoreGlobal,
              options.noIgnoreParent,
              options.noIgnoreVCS else {
            return false
        }
        return options.noIgnoreFiles || options.ignoreFiles.isEmpty
    }

    private func writeDarwinIgnoreFilePathsWithMessages(
        for options: RipgrepOptions,
        writeBytes: (UnsafeRawBufferPointer) -> Void
    ) throws -> FilePathStreamResults? {
        var messages: [String] = []
        var warnings: [String] = []
        var diagnostics: [String] = []
        var filtered = false
        let root = options.effectiveRoots[0]
        guard let rootPlan = fastFilePathRootPlan(root: root, options: options) else {
            if !fileManager.fileExists(atPath: root.path) {
                let displayPath = rootDisplayPath(at: 0, root: root, options: options)
                messages.append(missingRootMessage(displayPath, options: options, hasExistingRoot: false))
                return FilePathStreamResults(
                    count: 0,
                    messages: messages,
                    warnings: warnings,
                    diagnostics: diagnostics,
                    filtered: false
                )
            }
            return nil
        }

        let rootVCSContext = options.noRequireGit || isInGitRepository(rootPlan.rootBase)
        var rootIgnoreStack = IgnoreStack()
        appendExplicitIgnoreFiles(
            to: &rootIgnoreStack,
            rootBase: rootPlan.rootBase,
            rootVCSContext: rootVCSContext,
            warnings: &warnings,
            diagnostics: &diagnostics,
            options: options
        )
        appendGlobalIgnoreFile(to: &rootIgnoreStack, rootBase: rootPlan.rootBase, warnings: &warnings, diagnostics: &diagnostics, options: options)
        appendParentIgnoreFiles(to: &rootIgnoreStack, rootBase: rootPlan.rootBase, warnings: &warnings, diagnostics: &diagnostics, options: options)

        guard let parallelResults = try writeFilePathsInOutputOrderParallel(
            rootURL: rootPlan.rootURL,
            rootLogicalPathBytes: rootPlan.logicalPathBytes,
            rootLogicalPathIsASCII: rootPlan.logicalPathIsASCII,
            rootBase: rootPlan.rootBase,
            rootDebugDisplayPath: rootDisplayPath(at: 0, root: root, options: options),
            rootVCSContext: rootVCSContext,
            rootIgnoreStack: rootIgnoreStack,
            options: options,
            writeBytes: writeBytes
        ) else {
            return nil
        }

        messages.append(contentsOf: parallelResults.messages)
        warnings.append(contentsOf: parallelResults.warnings)
        diagnostics.append(contentsOf: parallelResults.diagnostics)
        filtered = filtered || parallelResults.filtered
        return FilePathStreamResults(
            count: parallelResults.count,
            messages: messages,
            warnings: warnings,
            diagnostics: diagnostics,
            filtered: filtered
        )
    }
    #endif

    public func haystacksWithMessages(for options: RipgrepOptions) throws -> FileWalkResults {
        try haystacksWithMessages(for: options, visitHaystack: nil)
    }

    func firstVisitedHaystackWithMessages(
        for options: RipgrepOptions,
        visitHaystack: @escaping (Haystack) -> Bool
    ) throws -> FileWalkResults {
        try haystacksWithMessages(for: options, visitHaystack: visitHaystack)
    }

    func fastSearchHaystacksWithMessages(
        for options: RipgrepOptions
    ) throws -> FileWalkResults? {
        try fastSearchFileWalkResults(for: options) { haystack, haystacks in
            haystacks.append(haystack)
            return false
        }
    }

    func firstVisitedFastSearchFileWithMessages(
        for options: RipgrepOptions,
        visitHaystack: @escaping (Haystack) -> Bool
    ) throws -> FileWalkResults? {
        try fastSearchFileWalkResults(for: options, lexicalOrder: true) { haystack, haystacks in
            if visitHaystack(haystack) {
                haystacks.append(haystack)
                return true
            }
            return false
        }
    }

    func firstVisitedFastSearchFilePrefixWithMessages(
        for options: RipgrepOptions,
        prefixLimit: Int,
        visitHaystack: @escaping (Haystack) -> Bool
    ) throws -> (results: FileWalkResults, exhausted: Bool)? {
        var visited = 0
        var exhausted = false
        guard let results = try fastSearchFileWalkResults(
            for: options,
            lexicalOrder: false,
            visitHaystack: { haystack, haystacks in
                guard visited < prefixLimit else {
                    exhausted = true
                    return true
                }
                visited += 1
                if visitHaystack(haystack) {
                    haystacks.append(haystack)
                    return true
                }
                return false
            }
        ) else {
            return nil
        }
        return (results, exhausted)
    }

    func fastSearchHaystacksWithPrefixVisitMessages(
        for options: RipgrepOptions,
        prefixLimit: Int,
        visitHaystack: @escaping (Haystack) -> Bool
    ) throws -> FileWalkResults? {
        var visitedPrefixCount = 0
        return try fastSearchFileWalkResults(for: options) { haystack, haystacks in
            if visitedPrefixCount < prefixLimit {
                visitedPrefixCount += 1
                if visitHaystack(haystack) {
                    haystacks.append(haystack)
                    return true
                }
            }
            haystacks.append(haystack)
            return false
        }
    }

    private func fastSearchFileWalkResults(
        for options: RipgrepOptions,
        lexicalOrder: Bool = false,
        visitHaystack: (Haystack, inout [Haystack]) -> Bool
    ) throws -> FileWalkResults? {
        #if canImport(Darwin)
        guard canFastVisitSearchFiles(options: options),
              options.effectiveRoots.count == 1 else {
            return nil
        }

        var messages: [String] = []
        var warnings: [String] = []
        var diagnostics: [String] = []
        var filtered = false

        let root = options.effectiveRoots[0]
        guard fileManager.fileExists(atPath: root.path) else {
            let displayPath = rootDisplayPath(at: 0, root: root, options: options)
            messages.append(missingRootMessage(displayPath, options: options, hasExistingRoot: false))
            return FileWalkResults(
                haystacks: [],
                messages: messages,
                warnings: warnings,
                diagnostics: diagnostics,
                filtered: false
            )
        }

        guard let rootPlan = fastFilePathRootPlan(root: root, options: options) else {
            return nil
        }

        var rootIgnoreStack = IgnoreStack()
        appendExplicitIgnoreFiles(
            to: &rootIgnoreStack,
            rootBase: rootPlan.rootBase,
            warnings: &warnings,
            diagnostics: &diagnostics,
            options: options
        )
        appendGlobalIgnoreFile(to: &rootIgnoreStack, rootBase: rootPlan.rootBase, warnings: &warnings, diagnostics: &diagnostics, options: options)
        appendParentIgnoreFiles(to: &rootIgnoreStack, rootBase: rootPlan.rootBase, warnings: &warnings, diagnostics: &diagnostics, options: options)

        let rootVCSContext = options.noRequireGit || isInGitRepository(rootPlan.rootBase)
        var didStop = false
        var matchedHaystacks: [Haystack] = []
        try walkFastSearchFilesInOutputOrder(
            directoryPath: rootPlan.rootURL.path,
            logicalDirectoryPath: rootPlan.logicalPath,
            logicalDirectoryPathIsASCII: rootPlan.logicalPathIsASCII,
            relativePath: "",
            rootBase: rootPlan.rootBase,
            rootDebugDisplayPath: rootDisplayPath(at: 0, root: root, options: options),
            rootArgumentIsAbsolute: rootPlan.rootArgumentIsAbsolute,
            vcsContext: rootVCSContext,
            messages: &messages,
            warnings: &warnings,
            diagnostics: &diagnostics,
            filtered: &filtered,
            ignoreStack: rootIgnoreStack,
            options: options,
            lexicalOrder: lexicalOrder,
            didStop: &didStop
        ) { haystack in
            visitHaystack(haystack, &matchedHaystacks)
        }

        return FileWalkResults(
            haystacks: matchedHaystacks,
            messages: messages,
            warnings: warnings,
            diagnostics: diagnostics,
            filtered: filtered
        )
        #else
        return nil
        #endif
    }

    private func haystacksWithMessages(
        for options: RipgrepOptions,
        visitHaystack: ((Haystack) -> Bool)?
    ) throws -> FileWalkResults {
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
        #if canImport(Darwin)
        var typeRegistry = FileTypeRegistry(loadDefaults: !options.typeChanges.isEmpty)
        #else
        var typeRegistry = FileTypeRegistry()
        #endif
        let typeErrors = typeRegistry.apply(options.typeChanges)
        if let error = typeErrors.first {
            throw RipgrepError.message(error)
        }

        let shouldStopAfterFirstHaystack = (options.mode == .files
            && options.quiet
            && options.sortMode == nil
            && options.loggingMode == nil)
            || visitHaystack != nil
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
            if shouldStopAfterFirstHaystack && !haystacks.isEmpty {
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
            let rootBasePath = rootBase.standardizedFileURL.path
            let rootBasePrefix = rootBasePath.hasSuffix("/") ? rootBasePath : "\(rootBasePath)/"
            let rootPath = root.standardizedFileURL.path
            let rootRelativePathOverride = rootPath == rootBasePath ? "" : nil
            let rootVCSContext = options.noRequireGit || isInGitRepository(rootBase)
            let cwdPath = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .standardizedFileURL
                .path
            let cwdPrefix = cwdPath.hasSuffix("/") ? cwdPath : "\(cwdPath)/"
            var walked: [Haystack] = []
            try walk(
                root.standardizedFileURL,
                physicalURL: nil,
                isExplicit: true,
                depth: 0,
                ancestors: [],
                rootBase: rootBase,
                rootBasePrefix: rootBasePrefix,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                cwdPrefix: cwdPrefix,
                rootVolume: rootVolume,
                vcsContext: rootVCSContext,
                messages: &messages,
                warnings: &warnings,
                diagnostics: &diagnostics,
                filtered: &filtered,
                ignoreStack: rootIgnoreStack,
                overrides: overrides,
                typeRegistry: typeRegistry,
                options: options,
                haystacks: &walked,
                metadataOverride: nil,
                relativePathOverride: rootRelativePathOverride,
                fileName: nil,
                shouldStopAfterFirstHaystack: shouldStopAfterFirstHaystack,
                visitHaystack: visitHaystack
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

    #if canImport(Darwin)
    private func canFastWalkFilePaths(
        options: RipgrepOptions,
        allowPathSort: Bool = false,
        allowNullPathTerminator: Bool = false
    ) -> Bool {
        let canSort = options.sortMode == nil || (allowPathSort && options.sortMode?.kind == .path)
        return options.mode == .files
            && !options.useStdin
            && (allowNullPathTerminator || !options.nullPathTerminator)
            && canSort
            && usesDefaultDarwinPathSeparator(options)
            && options.colorMode != .always
            && options.colorMode != .ansi
            && options.colorChanges.isEmpty
            && !options.hyperlinkFormat.isEnabled
            && options.globPatterns.isEmpty
            && options.caseInsensitiveGlobPatterns.isEmpty
            && options.typeChanges.isEmpty
            && options.maxFileSize == nil
            && options.maxDepth == nil
            && !options.followSymlinks
            && !options.oneFileSystem
    }

    private func canFastVisitSearchFiles(options: RipgrepOptions) -> Bool {
        options.mode == .search
            && !options.useStdin
            && !options.nullPathTerminator
            && options.sortMode == nil
            && options.loggingMode == nil
            && usesDefaultDarwinPathSeparator(options)
            && options.colorMode != .always
            && options.colorMode != .ansi
            && options.colorChanges.isEmpty
            && !options.hyperlinkFormat.isEnabled
            && options.globPatterns.isEmpty
            && options.caseInsensitiveGlobPatterns.isEmpty
            && options.typeChanges.isEmpty
            && options.maxFileSize == nil
            && options.maxDepth == nil
            && !options.followSymlinks
            && !options.oneFileSystem
    }

    private func usesDefaultDarwinPathSeparator(_ options: RipgrepOptions) -> Bool {
        options.pathSeparator == nil || options.pathSeparator == "/"
    }

    private func emitSortedFilePathLines(
        _ lines: [String],
        reverse: Bool,
        commonPrefixByteCount: Int = 0,
        sortInPlace: Bool = false,
        emit: (String) -> Void
    ) {
        if sortInPlace {
            var keyed = lines.map { line in
                (line: line, key: PathSort.byteKey(forPath: line, droppingFirstBytes: commonPrefixByteCount))
            }
            if reverse {
                keyed.sort(by: { lhs, rhs in rhs.key.lexicographicallyPrecedes(lhs.key) })
            } else {
                keyed.sort(by: { lhs, rhs in lhs.key.lexicographicallyPrecedes(rhs.key) })
            }
            for entry in keyed {
                emit(entry.line)
            }
            return
        }

        let keyed = lines.map { line in
            (line: line, key: PathSort.byteKey(forPath: line, droppingFirstBytes: commonPrefixByteCount))
        }
        let sorted = reverse
            ? keyed.sorted(by: { lhs, rhs in rhs.key.lexicographicallyPrecedes(lhs.key) })
            : keyed.sorted(by: { lhs, rhs in lhs.key.lexicographicallyPrecedes(rhs.key) })
        for entry in sorted {
            emit(entry.line)
        }
    }

    private func hasLoadableIgnoreFiles(
        hasGitMarker: Bool,
        hasGitignore: Bool,
        hasIgnore: Bool,
        hasRgignore: Bool,
        vcsContext: Bool,
        options: RipgrepOptions
    ) -> Bool {
        if !options.noIgnoreDot && (hasIgnore || hasRgignore) {
            return true
        }
        let shouldLoadVCSIgnore = !options.noIgnoreVCS && (options.noRequireGit || vcsContext)
        return shouldLoadVCSIgnore && (hasGitignore || (!options.noIgnoreExclude && hasGitMarker))
    }

    private func streamFilePathsInOutputOrderParallel(
        rootURL: URL,
        logicalRootPath: String,
        logicalRootPathIsASCII: Bool,
        rootBase: URL,
        rootDebugDisplayPath: String,
        rootVCSContext: Bool,
        rootIgnoreStack: IgnoreStack,
        options: RipgrepOptions,
        stopAfterFirst: Bool,
        emit: (String) -> Void
    ) throws -> FilePathStreamResults? {
        guard !options.noIgnore,
              !stopAfterFirst,
              options.loggingMode == nil else {
            return nil
        }

        let contents = try fastDirectoryContents(atPath: rootURL.path)
        let directoryVCSContext = rootVCSContext || (!options.noIgnoreVCS && contents.hasGitMarker)
        var directoryIgnoreStack = rootIgnoreStack
        var rootWarnings: [String] = []
        var rootDiagnostics: [String] = []
        if hasLoadableIgnoreFiles(
            hasGitMarker: contents.hasGitMarker,
            hasGitignore: contents.hasGitignore,
            hasIgnore: contents.hasIgnore,
            hasRgignore: contents.hasRgignore,
            vcsContext: directoryVCSContext,
            options: options
        ) {
            appendIgnoreFiles(
                in: rootURL,
                to: &directoryIgnoreStack,
                warnings: &rootWarnings,
                diagnostics: &rootDiagnostics,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: (logicalRootPath as NSString).isAbsolutePath,
                vcsContext: directoryVCSContext,
                scope: directoryIgnoreScope(relativePath: ""),
                directoryContents: DirectoryContents(
                    children: [],
                    hasGitMarker: contents.hasGitMarker,
                    hasGitignore: contents.hasGitignore,
                    hasIgnore: contents.hasIgnore,
                    hasRgignore: contents.hasRgignore
                ),
                options: options
            )
        }

        let directoryPathPrefix = rootURL.path + "/"
        let logicalDirectoryPathPrefix = pathPrefix(logicalRootPath)
        var orderedChildren: [FastDirectoryChild] = []
        orderedChildren.reserveCapacity(contents.children.count)
        var directoryCount = 0
        var rootFiltered = false
        if directoryIgnoreStack.isEmpty {
            for child in contents.children.reversed() {
                if child.kind == .symbolicLink || (!options.hidden && child.isHidden) {
                    continue
                }
                if child.kind.isDirectory {
                    directoryCount += 1
                    orderedChildren.append(child)
                } else if child.kind.isFile {
                    orderedChildren.append(child)
                }
            }
        } else {
            for child in contents.children.reversed() {
                if child.kind == .symbolicLink {
                    continue
                }
                let childRelativePath = child.name
                let isDirectory = child.kind.isDirectory
                guard shouldEmitFastFilePath(
                    child: child,
                    childRelativePath: childRelativePath,
                    isDirectory: isDirectory,
                    ignoreStack: directoryIgnoreStack,
                    options: options,
                    filtered: &rootFiltered
                ) else {
                    continue
                }
                if child.kind.isDirectory {
                    directoryCount += 1
                    orderedChildren.append(child)
                } else if child.kind.isFile {
                    orderedChildren.append(child)
                }
            }
        }
        guard directoryCount >= 2 else {
            return nil
        }

        let store = DarwinFilePathStringChunkStore(count: orderedChildren.count)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let parallelIgnoreStack = directoryIgnoreStack

        for (index, child) in orderedChildren.enumerated() {
            if child.kind.isFile {
                let line = outputPath(
                    logicalDirectoryPathPrefix: logicalDirectoryPathPrefix,
                    logicalDirectoryPathIsASCII: logicalRootPathIsASCII,
                    child: child
                )
                store.store(
                    .success(DarwinFilePathStringChunk(
                        lines: [line],
                        messages: [],
                        warnings: [],
                        diagnostics: [],
                        filtered: false
                    )),
                    at: index
                )
                continue
            }

            let childName = child.name
            let childIsASCII = child.isASCII
            group.enter()
            queue.async {
                defer {
                    group.leave()
                }
                var lines: [String] = []
                var messages: [String] = []
                var warnings: [String] = []
                var diagnostics: [String] = []
                var filtered = false
                var didStop = false
                do {
                    try walkFilePathsInOutputOrder(
                        directoryPath: directoryPathPrefix + childName,
                        logicalDirectoryPath: joinedPath(logicalRootPath, childName),
                        logicalDirectoryPathIsASCII: logicalRootPathIsASCII && childIsASCII,
                        relativePath: childName,
                        rootBase: rootBase,
                        rootDebugDisplayPath: rootDebugDisplayPath,
                        rootArgumentIsAbsolute: (logicalRootPath as NSString).isAbsolutePath,
                        vcsContext: directoryVCSContext,
                        messages: &messages,
                        warnings: &warnings,
                        diagnostics: &diagnostics,
                        filtered: &filtered,
                        ignoreStack: parallelIgnoreStack,
                        options: options,
                        stopAfterFirst: false,
                        didStop: &didStop,
                        emit: { lines.append($0) }
                    )
                    store.store(
                        .success(DarwinFilePathStringChunk(
                            lines: lines,
                            messages: messages,
                            warnings: warnings,
                            diagnostics: diagnostics,
                            filtered: filtered
                        )),
                        at: index
                    )
                } catch {
                    store.store(.failure(error), at: index)
                }
            }
        }

        group.wait()
        let chunks = try store.orderedChunks()
        var emittedCount = 0
        var messages: [String] = []
        var warnings = rootWarnings
        var diagnostics = rootDiagnostics
        var filtered = rootFiltered
        for chunk in chunks {
            emittedCount += chunk.lines.count
            for line in chunk.lines {
                emit(line)
            }
            messages.append(contentsOf: chunk.messages)
            warnings.append(contentsOf: chunk.warnings)
            diagnostics.append(contentsOf: chunk.diagnostics)
            filtered = filtered || chunk.filtered
        }
        return FilePathStreamResults(
            count: emittedCount,
            messages: messages,
            warnings: warnings,
            diagnostics: diagnostics,
            filtered: filtered
        )
    }

    private func writeFilePathsInOutputOrderParallel(
        rootURL: URL,
        rootLogicalPathBytes: [UInt8],
        rootLogicalPathIsASCII: Bool,
        rootBase: URL,
        rootDebugDisplayPath: String,
        rootVCSContext: Bool,
        rootIgnoreStack: IgnoreStack,
        options: RipgrepOptions,
        writeBytes: (UnsafeRawBufferPointer) -> Void
    ) throws -> FilePathStreamResults? {
        guard !options.noIgnore,
              options.loggingMode == nil else {
            return nil
        }

        let contents = try fastDirectoryContents(atPath: rootURL.path)
        let directoryVCSContext = rootVCSContext || (!options.noIgnoreVCS && contents.hasGitMarker)
        var directoryIgnoreStack = rootIgnoreStack
        var rootWarnings: [String] = []
        var rootDiagnostics: [String] = []
        if hasLoadableIgnoreFiles(
            hasGitMarker: contents.hasGitMarker,
            hasGitignore: contents.hasGitignore,
            hasIgnore: contents.hasIgnore,
            hasRgignore: contents.hasRgignore,
            vcsContext: directoryVCSContext,
            options: options
        ) {
            appendIgnoreFiles(
                in: rootURL,
                to: &directoryIgnoreStack,
                warnings: &rootWarnings,
                diagnostics: &rootDiagnostics,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootLogicalPathBytes.first == UInt8(ascii: "/"),
                vcsContext: directoryVCSContext,
                scope: directoryIgnoreScope(relativePath: ""),
                directoryContents: DirectoryContents(
                    children: [],
                    hasGitMarker: contents.hasGitMarker,
                    hasGitignore: contents.hasGitignore,
                    hasIgnore: contents.hasIgnore,
                    hasRgignore: contents.hasRgignore
                ),
                options: options
            )
        }

        let directoryPathPrefix = rootURL.path + "/"
        var orderedChildren: [FastDirectoryChild] = []
        orderedChildren.reserveCapacity(contents.children.count)
        var directoryCount = 0
        var rootFiltered = false
        if directoryIgnoreStack.isEmpty {
            for child in contents.children.reversed() {
                if child.kind == .symbolicLink || (!options.hidden && child.isHidden) {
                    continue
                }
                if child.kind.isDirectory {
                    directoryCount += 1
                    orderedChildren.append(child)
                } else if child.kind.isFile {
                    orderedChildren.append(child)
                }
            }
        } else {
            for child in contents.children.reversed() {
                if child.kind == .symbolicLink {
                    continue
                }
                let childRelativePath = child.name
                let isDirectory = child.kind.isDirectory
                if !options.hidden,
                   child.isHidden,
                   !isIncludedByIgnore(
                       relativePath: childRelativePath,
                       basename: child.name,
                       isDirectory: isDirectory,
                       ignoreStack: directoryIgnoreStack
                   ) {
                    continue
                }
                guard directoryIgnoreStack.allows(
                    relativePath: childRelativePath,
                    basename: child.name,
                    isDirectory: isDirectory
                ) else {
                    rootFiltered = true
                    continue
                }
                if child.kind.isDirectory {
                    directoryCount += 1
                    orderedChildren.append(child)
                } else if child.kind.isFile {
                    orderedChildren.append(child)
                }
            }
        }
        guard directoryCount >= 2 else {
            return nil
        }

        let store = DarwinFilePathDataChunkStore(count: orderedChildren.count)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let parallelIgnoreStack = directoryIgnoreStack
        var directoryWorkItems: [DarwinFilePathDataWorkItem] = []
        directoryWorkItems.reserveCapacity(directoryCount)

        for (index, child) in orderedChildren.enumerated() {
            if child.kind.isFile {
                var output = Data()
                output.reserveCapacity(rootLogicalPathBytes.count + child.name.utf8.count + 2)
                appendDarwinFilePathLine(
                    logicalPathBytes: rootLogicalPathBytes,
                    logicalPathIsASCII: rootLogicalPathIsASCII,
                    childName: child.name,
                    childNameIsASCII: child.isASCII,
                    outputBuffer: &output,
                    terminator: options.nullPathTerminator ? UInt8(0) : UInt8(ascii: "\n")
                )
                store.store(
                    .success(DarwinFilePathDataChunk(
                        data: output,
                        count: 1,
                        messages: [],
                        warnings: [],
                        diagnostics: [],
                        filtered: false
                    )),
                    at: index
                )
                continue
            }

            let childName = child.name
            let childIsASCII = child.isASCII
            let childLogicalPathBytes: [UInt8] = {
                var bytes = rootLogicalPathBytes
                appendPathComponent(child.name, to: &bytes)
                return bytes
            }()
            directoryWorkItems.append(DarwinFilePathDataWorkItem(
                index: index,
                childName: childName,
                childIsASCII: childIsASCII,
                childLogicalPathBytes: childLogicalPathBytes
            ))
        }

        let outputReserveCapacity = options.nullPathTerminator ? 64 * 1024 : 128 * 1024
        let workQueue = DarwinFilePathDataWorkQueue(items: directoryWorkItems)
        let workerCount = min(directoryWorkItems.count, darwinFilePathDataWorkerLimit)

        for _ in 0..<workerCount {
            group.enter()
            queue.async {
                defer {
                    group.leave()
                }
                while true {
                    guard let workItem = workQueue.next() else {
                        return
                    }

                    var output = Data()
                    output.reserveCapacity(outputReserveCapacity)
                    var emittedCount = 0
                    var messages: [String] = []
                    var warnings: [String] = []
                    var diagnostics: [String] = []
                    var filtered = false
                    do {
                        try walkFilePathsInOutputOrderData(
                            directoryPath: directoryPathPrefix + workItem.childName,
                            logicalPathBytes: workItem.childLogicalPathBytes,
                            logicalDirectoryPathIsASCII: rootLogicalPathIsASCII && workItem.childIsASCII,
                            relativePath: workItem.childName,
                            rootBase: rootBase,
                            rootDebugDisplayPath: rootDebugDisplayPath,
                            rootArgumentIsAbsolute: rootLogicalPathBytes.first == UInt8(ascii: "/"),
                            vcsContext: directoryVCSContext,
                            messages: &messages,
                            warnings: &warnings,
                            diagnostics: &diagnostics,
                            filtered: &filtered,
                            ignoreStack: parallelIgnoreStack,
                            options: options,
                            emittedCount: &emittedCount,
                            outputBuffer: &output
                        )
                        store.store(
                            .success(DarwinFilePathDataChunk(
                                data: output,
                                count: emittedCount,
                                messages: messages,
                                warnings: warnings,
                                diagnostics: diagnostics,
                                filtered: filtered
                            )),
                            at: workItem.index
                        )
                    } catch {
                        store.store(.failure(error), at: workItem.index)
                    }
                }
            }
        }

        group.wait()
        let chunks = try store.orderedChunks()
        var emittedCount = 0
        var messages: [String] = []
        var warnings = rootWarnings
        var diagnostics = rootDiagnostics
        var filtered = rootFiltered
        for chunk in chunks {
            emittedCount += chunk.count
            chunk.data.withUnsafeBytes { bytes in
                guard !bytes.isEmpty else {
                    return
                }
                writeBytes(bytes)
            }
            messages.append(contentsOf: chunk.messages)
            warnings.append(contentsOf: chunk.warnings)
            diagnostics.append(contentsOf: chunk.diagnostics)
            filtered = filtered || chunk.filtered
        }
        return FilePathStreamResults(
            count: emittedCount,
            messages: messages,
            warnings: warnings,
            diagnostics: diagnostics,
            filtered: filtered
        )
    }

    private func walkFilePathsInOutputOrderData(
        directoryPath: String,
        logicalPathBytes: [UInt8],
        logicalDirectoryPathIsASCII: Bool,
        relativePath: String,
        rootBase: URL,
        rootDebugDisplayPath: String,
        rootArgumentIsAbsolute: Bool,
        vcsContext: Bool,
        messages: inout [String],
        warnings: inout [String],
        diagnostics: inout [String],
        filtered: inout Bool,
        ignoreStack: IgnoreStack,
        options: RipgrepOptions,
        emittedCount: inout Int,
        outputBuffer: inout Data
    ) throws {
        let contents = try fastDirectoryContents(atPath: directoryPath)
        let directoryVCSContext = vcsContext || (!options.noIgnoreVCS && contents.hasGitMarker)
        var directoryIgnoreStack = ignoreStack
        if hasLoadableIgnoreFiles(
            hasGitMarker: contents.hasGitMarker,
            hasGitignore: contents.hasGitignore,
            hasIgnore: contents.hasIgnore,
            hasRgignore: contents.hasRgignore,
            vcsContext: directoryVCSContext,
            options: options
        ) {
            let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
            appendIgnoreFiles(
                in: directoryURL,
                logicalDirectory: nil,
                to: &directoryIgnoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                vcsContext: directoryVCSContext,
                scope: directoryIgnoreScope(relativePath: relativePath),
                directoryContents: DirectoryContents(
                    children: [],
                    hasGitMarker: contents.hasGitMarker,
                    hasGitignore: contents.hasGitignore,
                    hasIgnore: contents.hasIgnore,
                    hasRgignore: contents.hasRgignore
                ),
                options: options
            )
        }

        let directoryPathPrefix = directoryPath + "/"
        let relativePathPrefix = relativePath.isEmpty ? "" : relativePath + "/"
        let canUseBasenameOnlyIgnoreDecisions = directoryIgnoreStack.canUseBasenameOnlyChildDecisions
        if directoryIgnoreStack.isEmpty {
            for child in contents.children.reversed() {
                if child.kind == .symbolicLink || (!options.hidden && child.isHidden) {
                    continue
                }
                if child.kind.isDirectory {
                    let childRelativePath = relativePathPrefix + child.name
                    var childLogicalPathBytes = logicalPathBytes
                    childLogicalPathBytes.append(UInt8(ascii: "/"))
                    appendUTF8(child.name, to: &childLogicalPathBytes)
                    try walkFilePathsInOutputOrderData(
                        directoryPath: directoryPathPrefix + child.name,
                        logicalPathBytes: childLogicalPathBytes,
                        logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII && child.isASCII,
                        relativePath: childRelativePath,
                        rootBase: rootBase,
                        rootDebugDisplayPath: rootDebugDisplayPath,
                        rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                        vcsContext: directoryVCSContext,
                        messages: &messages,
                        warnings: &warnings,
                        diagnostics: &diagnostics,
                        filtered: &filtered,
                        ignoreStack: directoryIgnoreStack,
                        options: options,
                        emittedCount: &emittedCount,
                        outputBuffer: &outputBuffer
                    )
                } else if child.kind.isFile {
                    emittedCount += 1
                    appendDarwinFilePathLine(
                        logicalPathBytes: logicalPathBytes,
                        logicalPathIsASCII: logicalDirectoryPathIsASCII,
                        childName: child.name,
                        childNameIsASCII: child.isASCII,
                        outputBuffer: &outputBuffer,
                        terminator: options.nullPathTerminator ? UInt8(0) : UInt8(ascii: "\n")
                    )
                }
            }
            return
        }
        if canUseBasenameOnlyIgnoreDecisions {
            for child in contents.children.reversed() {
                if child.kind == .symbolicLink {
                    continue
                }
                let isDirectory = child.kind.isDirectory
                guard shouldEmitFastBasenameOnlyFilePath(
                    child: child,
                    isDirectory: isDirectory,
                    ignoreStack: directoryIgnoreStack,
                    options: options,
                    filtered: &filtered
                ) else {
                    continue
                }
                if child.kind.isDirectory {
                    let childRelativePath = relativePathPrefix + child.name
                    var childLogicalPathBytes = logicalPathBytes
                    childLogicalPathBytes.append(UInt8(ascii: "/"))
                    appendUTF8(child.name, to: &childLogicalPathBytes)
                    try walkFilePathsInOutputOrderData(
                        directoryPath: directoryPathPrefix + child.name,
                        logicalPathBytes: childLogicalPathBytes,
                        logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII && child.isASCII,
                        relativePath: childRelativePath,
                        rootBase: rootBase,
                        rootDebugDisplayPath: rootDebugDisplayPath,
                        rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                        vcsContext: directoryVCSContext,
                        messages: &messages,
                        warnings: &warnings,
                        diagnostics: &diagnostics,
                        filtered: &filtered,
                        ignoreStack: directoryIgnoreStack,
                        options: options,
                        emittedCount: &emittedCount,
                        outputBuffer: &outputBuffer
                    )
                } else if child.kind.isFile {
                    emittedCount += 1
                    appendDarwinFilePathLine(
                        logicalPathBytes: logicalPathBytes,
                        logicalPathIsASCII: logicalDirectoryPathIsASCII,
                        childName: child.name,
                        childNameIsASCII: child.isASCII,
                        outputBuffer: &outputBuffer,
                        terminator: options.nullPathTerminator ? UInt8(0) : UInt8(ascii: "\n")
                    )
                }
            }
            return
        }
        for child in contents.children.reversed() {
            if child.kind == .symbolicLink {
                continue
            }
            let childRelativePath = relativePathPrefix + child.name
            let isDirectory = child.kind.isDirectory
            guard shouldEmitFastFilePath(
                child: child,
                childRelativePath: childRelativePath,
                isDirectory: isDirectory,
                ignoreStack: directoryIgnoreStack,
                options: options,
                filtered: &filtered
            ) else {
                continue
            }
            if child.kind.isDirectory {
                var childLogicalPathBytes = logicalPathBytes
                childLogicalPathBytes.append(UInt8(ascii: "/"))
                appendUTF8(child.name, to: &childLogicalPathBytes)
                try walkFilePathsInOutputOrderData(
                    directoryPath: directoryPathPrefix + child.name,
                    logicalPathBytes: childLogicalPathBytes,
                    logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII && child.isASCII,
                    relativePath: childRelativePath,
                    rootBase: rootBase,
                    rootDebugDisplayPath: rootDebugDisplayPath,
                    rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                    vcsContext: directoryVCSContext,
                    messages: &messages,
                    warnings: &warnings,
                    diagnostics: &diagnostics,
                    filtered: &filtered,
                    ignoreStack: directoryIgnoreStack,
                    options: options,
                    emittedCount: &emittedCount,
                    outputBuffer: &outputBuffer
                )
            } else if child.kind.isFile {
                emittedCount += 1
                appendDarwinFilePathLine(
                    logicalPathBytes: logicalPathBytes,
                    logicalPathIsASCII: logicalDirectoryPathIsASCII,
                    childName: child.name,
                    childNameIsASCII: child.isASCII,
                    outputBuffer: &outputBuffer,
                    terminator: options.nullPathTerminator ? UInt8(0) : UInt8(ascii: "\n")
                )
            }
        }
    }

    private func walkFilePathsInOutputOrder(
        directoryPath: String,
        logicalDirectoryPath: String,
        logicalDirectoryPathIsASCII: Bool,
        relativePath: String,
        rootBase: URL,
        rootDebugDisplayPath: String,
        rootArgumentIsAbsolute: Bool,
        vcsContext: Bool,
        messages: inout [String],
        warnings: inout [String],
        diagnostics: inout [String],
        filtered: inout Bool,
        ignoreStack: IgnoreStack,
        options: RipgrepOptions,
        stopAfterFirst: Bool,
        didStop: inout Bool,
        emit: (String) -> Void
    ) throws {
        guard !didStop else {
            return
        }
        let contents = try fastDirectoryContents(
            atPath: directoryPath,
            collectIgnoreMarkers: !(options.noIgnore && options.hidden)
        )
        let directoryVCSContext = vcsContext || (!options.noIgnoreVCS && contents.hasGitMarker)
        var directoryIgnoreStack = ignoreStack
        if !options.noIgnore && hasLoadableIgnoreFiles(
            hasGitMarker: contents.hasGitMarker,
            hasGitignore: contents.hasGitignore,
            hasIgnore: contents.hasIgnore,
            hasRgignore: contents.hasRgignore,
            vcsContext: directoryVCSContext,
            options: options
        ) {
            let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
            let logicalDirectoryURL = options.loggingMode == nil
                ? nil
                : URL(fileURLWithPath: logicalDirectoryPath, isDirectory: true)
            appendIgnoreFiles(
                in: directoryURL,
                logicalDirectory: logicalDirectoryURL,
                to: &directoryIgnoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                vcsContext: directoryVCSContext,
                scope: directoryIgnoreScope(relativePath: relativePath),
                directoryContents: DirectoryContents(
                    children: [],
                    hasGitMarker: contents.hasGitMarker,
                    hasGitignore: contents.hasGitignore,
                    hasIgnore: contents.hasIgnore,
                    hasRgignore: contents.hasRgignore
                ),
                options: options
            )
        }

        if stopAfterFirst, options.quiet, options.loggingMode == nil {
            try walkFilePathsUntilFirstMatch(
                contents: contents,
                directoryPath: directoryPath,
                logicalDirectoryPath: logicalDirectoryPath,
                logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII,
                relativePath: relativePath,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                vcsContext: directoryVCSContext,
                messages: &messages,
                warnings: &warnings,
                diagnostics: &diagnostics,
                filtered: &filtered,
                ignoreStack: directoryIgnoreStack,
                options: options,
                didStop: &didStop,
                emit: emit
            )
            return
        }

        if options.noIgnore && !options.hidden {
            let directoryPathPrefix = directoryPath + "/"
            let logicalDirectoryPathPrefix = pathPrefix(logicalDirectoryPath)
            for child in contents.children.reversed() {
                if child.kind == .symbolicLink || child.isHidden {
                    continue
                }
                if child.kind.isDirectory {
                    try walkFilePathsInOutputOrder(
                        directoryPath: directoryPathPrefix + child.name,
                        logicalDirectoryPath: joinedPath(logicalDirectoryPath, child.name),
                        logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII && child.isASCII,
                        relativePath: "",
                        rootBase: rootBase,
                        rootDebugDisplayPath: rootDebugDisplayPath,
                        rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                        vcsContext: directoryVCSContext,
                        messages: &messages,
                        warnings: &warnings,
                        diagnostics: &diagnostics,
                        filtered: &filtered,
                        ignoreStack: directoryIgnoreStack,
                        options: options,
                        stopAfterFirst: stopAfterFirst,
                        didStop: &didStop,
                        emit: emit
                    )
                    if didStop {
                        return
                    }
                } else if child.kind.isFile {
                    emit(outputPath(
                        logicalDirectoryPathPrefix: logicalDirectoryPathPrefix,
                        logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII,
                        child: child
                    ))
                    if stopAfterFirst {
                        didStop = true
                        return
                    }
                }
            }
            return
        }

        if options.noIgnore && options.hidden {
            let directoryPathPrefix = directoryPath + "/"
            let logicalDirectoryPathPrefix = pathPrefix(logicalDirectoryPath)
            for child in contents.children.reversed() {
                if child.kind == .symbolicLink {
                    continue
                }
                if child.kind.isDirectory {
                    try walkFilePathsInOutputOrder(
                        directoryPath: directoryPathPrefix + child.name,
                        logicalDirectoryPath: joinedPath(logicalDirectoryPath, child.name),
                        logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII && child.isASCII,
                        relativePath: "",
                        rootBase: rootBase,
                        rootDebugDisplayPath: rootDebugDisplayPath,
                        rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                        vcsContext: directoryVCSContext,
                        messages: &messages,
                        warnings: &warnings,
                        diagnostics: &diagnostics,
                        filtered: &filtered,
                        ignoreStack: directoryIgnoreStack,
                        options: options,
                        stopAfterFirst: stopAfterFirst,
                        didStop: &didStop,
                        emit: emit
                    )
                    if didStop {
                        return
                    }
                } else if child.kind.isFile {
                    emit(outputPath(
                        logicalDirectoryPathPrefix: logicalDirectoryPathPrefix,
                        logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII,
                        child: child
                    ))
                    if stopAfterFirst {
                        didStop = true
                        return
                    }
                }
            }
            return
        }

        let directoryPathPrefix = directoryPath + "/"
        let logicalDirectoryPathPrefix = pathPrefix(logicalDirectoryPath)
        let relativePathPrefix = relativePath.isEmpty ? "" : relativePath + "/"
        let canUseBasenameOnlyIgnoreDecisions = options.loggingMode == nil
            && directoryIgnoreStack.canUseBasenameOnlyChildDecisions
        if canUseBasenameOnlyIgnoreDecisions {
            for child in contents.children.reversed() {
                if child.kind == .symbolicLink {
                    continue
                }
                let isDirectory = child.kind.isDirectory
                guard shouldEmitFastBasenameOnlyFilePath(
                    child: child,
                    isDirectory: isDirectory,
                    ignoreStack: directoryIgnoreStack,
                    options: options,
                    filtered: &filtered
                ) else {
                    continue
                }
                if child.kind.isDirectory {
                    let childRelativePath = relativePathPrefix + child.name
                    try walkFilePathsInOutputOrder(
                        directoryPath: directoryPathPrefix + child.name,
                        logicalDirectoryPath: joinedPath(logicalDirectoryPath, child.name),
                        logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII && child.isASCII,
                        relativePath: childRelativePath,
                        rootBase: rootBase,
                        rootDebugDisplayPath: rootDebugDisplayPath,
                        rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                        vcsContext: directoryVCSContext,
                        messages: &messages,
                        warnings: &warnings,
                        diagnostics: &diagnostics,
                        filtered: &filtered,
                        ignoreStack: directoryIgnoreStack,
                        options: options,
                        stopAfterFirst: stopAfterFirst,
                        didStop: &didStop,
                        emit: emit
                    )
                    if didStop {
                        return
                    }
                } else if child.kind.isFile {
                    emit(outputPath(
                        logicalDirectoryPathPrefix: logicalDirectoryPathPrefix,
                        logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII,
                        child: child
                    ))
                    if stopAfterFirst {
                        didStop = true
                        return
                    }
                }
            }
            return
        }
        for child in contents.children.reversed() {
            if child.kind == .symbolicLink {
                continue
            }
            let childRelativePath = relativePathPrefix + child.name
            let isDirectory = child.kind.isDirectory
            if !options.hidden,
               child.isHidden,
               !isIncludedByIgnore(
                   relativePath: childRelativePath,
                   basename: child.name,
                   isDirectory: isDirectory,
                   ignoreStack: directoryIgnoreStack
               ) {
                if options.loggingMode != nil {
                    debugHiddenMatch(
                        displayPath: debugDisplayPath(
                            path: logicalDirectoryPath,
                            childName: child.name,
                            relativePath: childRelativePath,
                            rootDisplayPath: rootDebugDisplayPath,
                            rootArgumentIsAbsolute: rootArgumentIsAbsolute
                        ),
                        options: options,
                        diagnostics: &diagnostics
                    )
                }
                continue
            }
            if !directoryIgnoreStack.allows(relativePath: childRelativePath, basename: child.name, isDirectory: isDirectory) {
                if options.loggingMode != nil {
                    let childPath = joinedPath(logicalDirectoryPath, child.name)
                    debugIgnoreMatch(
                        path: childPath,
                        displayPath: debugDisplayPath(
                            path: logicalDirectoryPath,
                            childName: child.name,
                            relativePath: childRelativePath,
                            rootDisplayPath: rootDebugDisplayPath,
                            rootArgumentIsAbsolute: rootArgumentIsAbsolute
                        ),
                        relativePath: childRelativePath,
                        isDirectory: isDirectory,
                        ignoreStack: directoryIgnoreStack,
                        options: options,
                        diagnostics: &diagnostics
                    )
                }
                filtered = true
                continue
            }
            if child.kind.isDirectory {
                try walkFilePathsInOutputOrder(
                    directoryPath: directoryPathPrefix + child.name,
                    logicalDirectoryPath: joinedPath(logicalDirectoryPath, child.name),
                    logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII && child.isASCII,
                    relativePath: childRelativePath,
                    rootBase: rootBase,
                    rootDebugDisplayPath: rootDebugDisplayPath,
                    rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                    vcsContext: directoryVCSContext,
                    messages: &messages,
                    warnings: &warnings,
                    diagnostics: &diagnostics,
                    filtered: &filtered,
                    ignoreStack: directoryIgnoreStack,
                    options: options,
                    stopAfterFirst: stopAfterFirst,
                    didStop: &didStop,
                    emit: emit
                )
                if didStop {
                    return
                }
            } else if child.kind.isFile {
                emit(outputPath(
                    logicalDirectoryPathPrefix: logicalDirectoryPathPrefix,
                    logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII,
                    child: child
                ))
                if stopAfterFirst {
                    didStop = true
                    return
                }
            }
        }
    }

    private func walkFilePathsUntilFirstMatch(
        contents: FastDirectoryContents,
        directoryPath: String,
        logicalDirectoryPath: String,
        logicalDirectoryPathIsASCII: Bool,
        relativePath: String,
        rootBase: URL,
        rootDebugDisplayPath: String,
        rootArgumentIsAbsolute: Bool,
        vcsContext: Bool,
        messages: inout [String],
        warnings: inout [String],
        diagnostics: inout [String],
        filtered: inout Bool,
        ignoreStack: IgnoreStack,
        options: RipgrepOptions,
        didStop: inout Bool,
        emit: (String) -> Void
    ) throws {
        guard !didStop else {
            return
        }
        let directoryPathPrefix = directoryPath + "/"
        let relativePathPrefix = relativePath.isEmpty ? "" : relativePath + "/"
        if options.noIgnore && options.hidden {
            for child in contents.children.reversed() where child.kind.isFile {
                emit("")
                didStop = true
                return
            }
            for child in contents.children.reversed() where child.kind.isDirectory {
                try walkFilePathsInOutputOrder(
                    directoryPath: directoryPathPrefix + child.name,
                    logicalDirectoryPath: joinedPath(logicalDirectoryPath, child.name),
                    logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII && child.isASCII,
                    relativePath: "",
                    rootBase: rootBase,
                    rootDebugDisplayPath: rootDebugDisplayPath,
                    rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                    vcsContext: vcsContext,
                    messages: &messages,
                    warnings: &warnings,
                    diagnostics: &diagnostics,
                    filtered: &filtered,
                    ignoreStack: ignoreStack,
                    options: options,
                    stopAfterFirst: true,
                    didStop: &didStop,
                    emit: emit
                )
                if didStop {
                    return
                }
            }
            return
        }

        for child in contents.children.reversed() where child.kind.isFile {
            let childRelativePath = relativePathPrefix + child.name
            guard shouldEmitFastFilePath(
                child: child,
                childRelativePath: childRelativePath,
                isDirectory: false,
                ignoreStack: ignoreStack,
                options: options,
                filtered: &filtered
            ) else {
                continue
            }
            emit("")
            didStop = true
            return
        }

        for child in contents.children.reversed() where child.kind.isDirectory {
            let childRelativePath = relativePathPrefix + child.name
            guard shouldEmitFastFilePath(
                child: child,
                childRelativePath: childRelativePath,
                isDirectory: true,
                ignoreStack: ignoreStack,
                options: options,
                filtered: &filtered
            ) else {
                continue
            }
            try walkFilePathsInOutputOrder(
                directoryPath: directoryPathPrefix + child.name,
                logicalDirectoryPath: joinedPath(logicalDirectoryPath, child.name),
                logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII && child.isASCII,
                relativePath: childRelativePath,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                vcsContext: vcsContext,
                messages: &messages,
                warnings: &warnings,
                diagnostics: &diagnostics,
                filtered: &filtered,
                ignoreStack: ignoreStack,
                options: options,
                stopAfterFirst: true,
                didStop: &didStop,
                emit: emit
            )
            if didStop {
                return
            }
        }
    }

    private func walkFastSearchFilesInOutputOrder(
        directoryPath: String,
        logicalDirectoryPath: String,
        logicalDirectoryPathIsASCII: Bool,
        relativePath: String,
        rootBase: URL,
        rootDebugDisplayPath: String,
        rootArgumentIsAbsolute: Bool,
        vcsContext: Bool,
        messages: inout [String],
        warnings: inout [String],
        diagnostics: inout [String],
        filtered: inout Bool,
        ignoreStack: IgnoreStack,
        options: RipgrepOptions,
        lexicalOrder: Bool = false,
        didStop: inout Bool,
        visit: (Haystack) -> Bool
    ) throws {
        guard !didStop else {
            return
        }
        let contents = try fastDirectoryContents(
            atPath: directoryPath,
            collectIgnoreMarkers: !(options.noIgnore && options.hidden)
        )
        let directoryVCSContext = vcsContext || (!options.noIgnoreVCS && contents.hasGitMarker)
        var directoryIgnoreStack = ignoreStack
        if !options.noIgnore && hasLoadableIgnoreFiles(
            hasGitMarker: contents.hasGitMarker,
            hasGitignore: contents.hasGitignore,
            hasIgnore: contents.hasIgnore,
            hasRgignore: contents.hasRgignore,
            vcsContext: directoryVCSContext,
            options: options
        ) {
            let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
            appendIgnoreFiles(
                in: directoryURL,
                to: &directoryIgnoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                vcsContext: directoryVCSContext,
                scope: directoryIgnoreScope(relativePath: relativePath),
                directoryContents: DirectoryContents(
                    children: [],
                    hasGitMarker: contents.hasGitMarker,
                    hasGitignore: contents.hasGitignore,
                    hasIgnore: contents.hasIgnore,
                    hasRgignore: contents.hasRgignore
                ),
                options: options
            )
        }

        let directoryPathPrefix = directoryPath + "/"
        let logicalDirectoryPathPrefix = pathPrefix(logicalDirectoryPath)
        let relativePathPrefix = relativePath.isEmpty ? "" : relativePath + "/"
        let canUseBasenameOnlyIgnoreDecisions = directoryIgnoreStack.canUseUnscopedBasenameDecisions
        func visitChildUsingBasenameDecisionPath(_ child: FastDirectoryChild) throws {
            if child.kind == .symbolicLink {
                return
            }
            let childRelativePath = relativePathPrefix + child.name
            let isDirectory = child.kind.isDirectory
            if !options.hidden,
               child.isHidden,
               !isIncludedByIgnore(
                   relativePath: childRelativePath,
                   basename: child.name,
                   isDirectory: isDirectory,
                   ignoreStack: directoryIgnoreStack
               ) {
                return
            }
            if !directoryIgnoreStack.allows(
                relativePath: childRelativePath,
                basename: child.name,
                isDirectory: isDirectory
            ) {
                filtered = true
                return
            }
            if child.kind.isDirectory {
                try walkFastSearchFilesInOutputOrder(
                    directoryPath: directoryPathPrefix + child.name,
                    logicalDirectoryPath: joinedPath(logicalDirectoryPath, child.name),
                    logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII && child.isASCII,
                    relativePath: childRelativePath,
                    rootBase: rootBase,
                    rootDebugDisplayPath: rootDebugDisplayPath,
                    rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                    vcsContext: directoryVCSContext,
                    messages: &messages,
                    warnings: &warnings,
                    diagnostics: &diagnostics,
                    filtered: &filtered,
                    ignoreStack: directoryIgnoreStack,
                    options: options,
                    lexicalOrder: lexicalOrder,
                    didStop: &didStop,
                    visit: visit
                )
                if didStop {
                    return
                }
            } else if child.kind.isFile {
                let haystack = Haystack(
                    url: URL(fileURLWithPath: directoryPathPrefix + child.name, isDirectory: false),
                    isExplicit: false,
                    overridePath: outputPath(
                        logicalDirectoryPathPrefix: logicalDirectoryPathPrefix,
                        logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII,
                        child: child
                    ),
                    isRegularFile: true
                )
                if visit(haystack) {
                    didStop = true
                    return
                }
            }
        }
        func visitChild(_ child: FastDirectoryChild) throws {
            if child.kind == .symbolicLink {
                return
            }
            let childRelativePath = relativePathPrefix + child.name
            let isDirectory = child.kind.isDirectory
            if !options.hidden,
               child.isHidden,
               !isIncludedByIgnore(
                   relativePath: childRelativePath,
                   basename: child.name,
                   isDirectory: isDirectory,
                   ignoreStack: directoryIgnoreStack
               ) {
                return
            }
            if !directoryIgnoreStack.allows(relativePath: childRelativePath, basename: child.name, isDirectory: isDirectory) {
                filtered = true
                return
            }
            if child.kind.isDirectory {
                try walkFastSearchFilesInOutputOrder(
                    directoryPath: directoryPathPrefix + child.name,
                    logicalDirectoryPath: joinedPath(logicalDirectoryPath, child.name),
                    logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII && child.isASCII,
                    relativePath: childRelativePath,
                    rootBase: rootBase,
                    rootDebugDisplayPath: rootDebugDisplayPath,
                    rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                    vcsContext: directoryVCSContext,
                    messages: &messages,
                    warnings: &warnings,
                    diagnostics: &diagnostics,
                    filtered: &filtered,
                    ignoreStack: directoryIgnoreStack,
                    options: options,
                    lexicalOrder: lexicalOrder,
                    didStop: &didStop,
                    visit: visit
                )
                if didStop {
                    return
                }
            } else if child.kind.isFile {
                let haystack = Haystack(
                    url: URL(fileURLWithPath: directoryPathPrefix + child.name, isDirectory: false),
                    isExplicit: false,
                    overridePath: outputPath(
                        logicalDirectoryPathPrefix: logicalDirectoryPathPrefix,
                        logicalDirectoryPathIsASCII: logicalDirectoryPathIsASCII,
                        child: child
                    ),
                    isRegularFile: true
                )
                if visit(haystack) {
                    didStop = true
                    return
                }
            }
        }
        if lexicalOrder {
            let children = contents.children.sorted { $0.name < $1.name }
            if canUseBasenameOnlyIgnoreDecisions {
                for child in children {
                    try visitChildUsingBasenameDecisionPath(child)
                    if didStop {
                        return
                    }
                }
            } else {
                for child in children {
                    try visitChild(child)
                    if didStop {
                        return
                    }
                }
            }
        } else {
            if canUseBasenameOnlyIgnoreDecisions {
                for child in contents.children.reversed() {
                    try visitChildUsingBasenameDecisionPath(child)
                    if didStop {
                        return
                    }
                }
            } else {
                for child in contents.children.reversed() {
                    try visitChild(child)
                    if didStop {
                        return
                    }
                }
            }
        }
    }

    private func writeDarwinNoIgnoreFilePathsInOutputOrderParallel(
        directoryPathBytes: [UInt8],
        logicalPathBytes: [UInt8],
        logicalPathIsASCII: Bool,
        includeHidden: Bool,
        terminator: UInt8,
        writeBytes: (UnsafeRawBufferPointer) -> Void
    ) throws -> Int? {
        var rootDirectoryPathBytes = directoryPathBytes
        let children = try fastDirectoryByteChildren(atPathBytes: &rootDirectoryPathBytes)
        var orderedChildren: [FastDirectoryByteChild] = []
        orderedChildren.reserveCapacity(children.count)
        var directoryCount = 0
        for child in children.reversed() {
            if child.kind == .symbolicLink {
                continue
            }
            if !includeHidden, child.isHidden {
                continue
            }
            if child.kind.isDirectory {
                directoryCount += 1
                orderedChildren.append(child)
            } else if child.kind.isFile {
                orderedChildren.append(child)
            }
        }
        guard directoryCount >= 2 else {
            return nil
        }

        let store = DarwinNoIgnoreFilePathChunkStore(count: orderedChildren.count)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        var directoryWorkItems: [DarwinNoIgnoreFilePathWorkItem] = []
        directoryWorkItems.reserveCapacity(directoryCount)

        for (index, child) in orderedChildren.enumerated() {
            if child.kind.isFile {
                var output = Data()
                output.reserveCapacity(logicalPathBytes.count + child.nameBytes.count + 2)
                appendDarwinFilePathLine(
                    logicalPathBytes: logicalPathBytes,
                    logicalPathIsASCII: logicalPathIsASCII,
                    childNameBytes: child.nameBytes,
                    childNameIsASCII: child.isASCII,
                    outputBuffer: &output,
                    terminator: terminator
                )
                store.store(.success(DarwinNoIgnoreFilePathChunk(data: output, count: 1)), at: index)
                continue
            }

            var taskDirectoryPathBytes = directoryPathBytes
            var taskLogicalPathBytes = logicalPathBytes
            taskDirectoryPathBytes.append(UInt8(ascii: "/"))
            taskDirectoryPathBytes.append(contentsOf: child.nameBytes)
            appendPathComponent(child.nameBytes, to: &taskLogicalPathBytes)
            let childLogicalPathIsASCII = logicalPathIsASCII && child.isASCII
            let childDirectoryPathBytes = taskDirectoryPathBytes
            let childLogicalPathBytes = taskLogicalPathBytes

            directoryWorkItems.append(DarwinNoIgnoreFilePathWorkItem(
                index: index,
                directoryPathBytes: childDirectoryPathBytes,
                logicalPathBytes: childLogicalPathBytes,
                logicalPathIsASCII: childLogicalPathIsASCII
            ))
        }

        let workQueue = DarwinNoIgnoreFilePathWorkQueue(items: directoryWorkItems)
        let workerCount = includeHidden
            ? directoryWorkItems.count
            : min(directoryWorkItems.count, darwinFilePathDataWorkerLimit)
        for _ in 0..<workerCount {
            group.enter()
            queue.async {
                defer {
                    group.leave()
                }
                while true {
                    guard let workItem = workQueue.next() else {
                        return
                    }

                    var directoryPathBytes = workItem.directoryPathBytes
                    var logicalPathBytes = workItem.logicalPathBytes
                    var flushedOutput = Data()
                    var output = Data()
                    output.reserveCapacity(64 * 1024)
                    var emittedCount = 0
                    do {
                        try writeDarwinNoIgnoreFilePathsInOutputOrder(
                            directoryPathBytes: &directoryPathBytes,
                            logicalPathBytes: &logicalPathBytes,
                            logicalPathIsASCII: workItem.logicalPathIsASCII,
                            includeHidden: includeHidden,
                            terminator: terminator,
                            emittedCount: &emittedCount,
                            outputBuffer: &output,
                            writeBytes: { bytes in
                                flushedOutput.append(bytes.bindMemory(to: UInt8.self))
                            }
                        )
                        flushedOutput.append(output)
                        store.store(
                            .success(DarwinNoIgnoreFilePathChunk(data: flushedOutput, count: emittedCount)),
                            at: workItem.index
                        )
                    } catch {
                        store.store(.failure(error), at: workItem.index)
                    }
                }
            }
        }

        group.wait()
        let chunks = try store.orderedChunks()
        var emittedCount = 0
        for chunk in chunks {
            emittedCount += chunk.count
            chunk.data.withUnsafeBytes { bytes in
                guard !bytes.isEmpty else {
                    return
                }
                writeBytes(bytes)
            }
        }
        return emittedCount
    }

    private func writeDarwinNoIgnoreFilePathsInOutputOrder(
        directoryPathBytes: inout [UInt8],
        logicalPathBytes: inout [UInt8],
        logicalPathIsASCII: Bool,
        includeHidden: Bool,
        terminator: UInt8,
        emittedCount: inout Int,
        outputBuffer: inout Data,
        writeBytes: (UnsafeRawBufferPointer) -> Void
    ) throws {
        let children = try fastDirectoryByteChildren(atPathBytes: &directoryPathBytes)

        for child in children.reversed() {
            if child.kind == .symbolicLink {
                continue
            }
            if !includeHidden, child.isHidden {
                continue
            }
            if child.kind.isDirectory {
                let previousDirectoryPathCount = directoryPathBytes.count
                let previousLogicalPathCount = logicalPathBytes.count
                directoryPathBytes.append(UInt8(ascii: "/"))
                directoryPathBytes.append(contentsOf: child.nameBytes)
                appendPathComponent(child.nameBytes, to: &logicalPathBytes)
                try writeDarwinNoIgnoreFilePathsInOutputOrder(
                    directoryPathBytes: &directoryPathBytes,
                    logicalPathBytes: &logicalPathBytes,
                    logicalPathIsASCII: logicalPathIsASCII && child.isASCII,
                    includeHidden: includeHidden,
                    terminator: terminator,
                    emittedCount: &emittedCount,
                    outputBuffer: &outputBuffer,
                    writeBytes: writeBytes
                )
                directoryPathBytes.removeSubrange(previousDirectoryPathCount...)
                logicalPathBytes.removeSubrange(previousLogicalPathCount...)
            } else if child.kind.isFile {
                emittedCount += 1
                appendDarwinFilePathLine(
                    logicalPathBytes: logicalPathBytes,
                    logicalPathIsASCII: logicalPathIsASCII,
                    childNameBytes: child.nameBytes,
                    childNameIsASCII: child.isASCII,
                    outputBuffer: &outputBuffer,
                    terminator: terminator
                )
                if outputBuffer.count >= 64 * 1024 {
                    flushDarwinFilePathOutputBuffer(&outputBuffer, writeBytes: writeBytes)
                }
            }
        }
    }

    private func appendDarwinFilePathLine(
        logicalPathBytes: [UInt8],
        logicalPathIsASCII: Bool,
        childName: String,
        childNameIsASCII: Bool,
        outputBuffer: inout Data,
        terminator: UInt8
    ) {
        if logicalPathIsASCII && childNameIsASCII {
            appendBytes(logicalPathBytes, to: &outputBuffer)
            if !logicalPathBytes.isEmpty {
                outputBuffer.append(UInt8(ascii: "/"))
            }
            appendUTF8(childName, to: &outputBuffer)
            outputBuffer.append(terminator)
            return
        }

        var pathBytes = logicalPathBytes
        appendPathComponent(childName, to: &pathBytes)
        let path = String(decoding: pathBytes, as: UTF8.self).precomposedStringWithCanonicalMapping
        appendUTF8(path, to: &outputBuffer)
        outputBuffer.append(terminator)
    }

    private func appendDarwinFilePathLine(
        logicalPathBytes: [UInt8],
        logicalPathIsASCII: Bool,
        childNameBytes: [UInt8],
        childNameIsASCII: Bool,
        outputBuffer: inout Data,
        terminator: UInt8
    ) {
        if logicalPathIsASCII && childNameIsASCII {
            appendBytes(logicalPathBytes, to: &outputBuffer)
            if !logicalPathBytes.isEmpty {
                outputBuffer.append(UInt8(ascii: "/"))
            }
            appendBytes(childNameBytes, to: &outputBuffer)
            outputBuffer.append(terminator)
            return
        }

        var pathBytes = logicalPathBytes
        appendPathComponent(childNameBytes, to: &pathBytes)
        let path = String(decoding: pathBytes, as: UTF8.self).precomposedStringWithCanonicalMapping
        appendUTF8(path, to: &outputBuffer)
        outputBuffer.append(terminator)
    }

    private func appendBytes(_ bytes: [UInt8], to data: inout Data) {
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress, !buffer.isEmpty else {
                return
            }
            data.append(baseAddress, count: buffer.count)
        }
    }

    private func flushDarwinFilePathOutputBuffer(
        _ outputBuffer: inout Data,
        writeBytes: (UnsafeRawBufferPointer) -> Void
    ) {
        guard !outputBuffer.isEmpty else {
            return
        }
        outputBuffer.withUnsafeBytes { bytes in
            writeBytes(bytes)
        }
        outputBuffer.removeAll(keepingCapacity: true)
    }

    private func appendUTF8(_ string: String, to bytes: inout [UInt8]) {
        var string = string
        string.withUTF8 { buffer in
            bytes.append(contentsOf: buffer)
        }
    }

    private func appendUTF8(_ string: String, to data: inout Data) {
        var string = string
        string.withUTF8 { buffer in
            guard let baseAddress = buffer.baseAddress, !buffer.isEmpty else {
                return
            }
            data.append(baseAddress, count: buffer.count)
        }
    }

    private func appendPathComponent(_ component: String, to bytes: inout [UInt8]) {
        if !bytes.isEmpty {
            bytes.append(UInt8(ascii: "/"))
        }
        appendUTF8(component, to: &bytes)
    }

    private func appendPathComponent(_ component: [UInt8], to bytes: inout [UInt8]) {
        if !bytes.isEmpty {
            bytes.append(UInt8(ascii: "/"))
        }
        bytes.append(contentsOf: component)
    }

    private func pathPrefix(_ path: String) -> String {
        path.isEmpty ? "" : "\(path)/"
    }

    private func joinedPath(_ path: String, _ component: String) -> String {
        path.isEmpty ? component : "\(path)/\(component)"
    }

    private func trimmingTrailingSlashes(_ path: String) -> String {
        var output = path
        while output.count > 1, output.last == "/" {
            output.removeLast()
        }
        return output
    }

    private func shouldEmitFastFilePath(
        child: FastDirectoryChild,
        childRelativePath: String,
        isDirectory: Bool,
        ignoreStack: IgnoreStack,
        options: RipgrepOptions,
        filtered: inout Bool
    ) -> Bool {
        if !options.hidden, child.isHidden {
            guard ignoreStack.canIncludePaths else {
                return false
            }
            return ignoreStack.decision(
                relativePath: childRelativePath,
                basename: child.name,
                isDirectory: isDirectory
            ) == .include
        }
        let ignoreDecision = ignoreStack.decision(
            relativePath: childRelativePath,
            basename: child.name,
            isDirectory: isDirectory
        )
        if ignoreDecision == .exclude {
            filtered = true
            return false
        }
        return true
    }

    private func shouldEmitFastBasenameOnlyFilePath(
        child: FastDirectoryChild,
        isDirectory: Bool,
        ignoreStack: IgnoreStack,
        options: RipgrepOptions,
        filtered: inout Bool
    ) -> Bool {
        if !options.hidden, child.isHidden {
            guard ignoreStack.canIncludePaths else {
                return false
            }
            return ignoreStack.decision(
                relativePath: child.name,
                basename: child.name,
                isDirectory: isDirectory
            ) == .include
        }
        let ignoreDecision = ignoreStack.decision(
            relativePath: child.name,
            basename: child.name,
            isDirectory: isDirectory
        )
        if ignoreDecision == .exclude {
            filtered = true
            return false
        }
        return true
    }

    private func fastDirectoryByteChildren(atPathBytes pathBytes: inout [UInt8]) throws -> [FastDirectoryByteChild] {
        guard let directory = withTemporaryCString(pathBytes: &pathBytes, opendir) else {
            let path = String(decoding: pathBytes, as: UTF8.self)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path]
            )
        }
        defer {
            closedir(directory)
        }

        var children: [FastDirectoryByteChild] = []
        children.reserveCapacity(64)
        while let entryPointer = readdir(directory) {
            let entry = entryPointer.pointee
            let nameLength = Int(entry.d_namlen)
            let nameBytes = withUnsafePointer(to: entry.d_name) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: nameLength + 1) { bytes in
                    Array(UnsafeBufferPointer(start: bytes, count: nameLength))
                }
            }
            if isCurrentOrParentDirectoryName(nameBytes) {
                continue
            }
            let kind = try fastDirectoryEntryKind(
                entry.d_type,
                directoryPathBytes: &pathBytes,
                nameBytes: nameBytes
            )
            children.append(FastDirectoryByteChild(
                nameBytes: nameBytes,
                isASCII: nameBytes.allSatisfy { $0 < 0x80 },
                isHidden: nameBytes.first == UInt8(ascii: "."),
                kind: kind
            ))
        }
        return children
    }

    private func withTemporaryCString<Result>(
        pathBytes: inout [UInt8],
        _ body: (UnsafePointer<CChar>) throws -> Result
    ) rethrows -> Result {
        pathBytes.append(0)
        defer {
            pathBytes.removeLast()
        }
        return try pathBytes.withUnsafeBufferPointer { buffer in
            try buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count, body)
        }
    }

    private func fastDirectoryContents(atPath path: String, collectIgnoreMarkers: Bool = true) throws -> FastDirectoryContents {
        guard let directory = opendir(path) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path]
            )
        }
        defer {
            closedir(directory)
        }

        var children: [FastDirectoryChild] = []
        children.reserveCapacity(64)
        var hasGitMarker = false
        var hasGitignore = false
        var hasIgnore = false
        var hasRgignore = false
        while let entryPointer = readdir(directory) {
            let entry = entryPointer.pointee
            guard let entryName = fastDirectoryEntryNameAndFlags(entry) else {
                continue
            }
            let name = entryName.name
            if collectIgnoreMarkers, entryName.isHidden {
                switch name {
                case ".git":
                    hasGitMarker = true
                case ".gitignore":
                    hasGitignore = true
                case ".ignore":
                    hasIgnore = true
                case ".rgignore":
                    hasRgignore = true
                default:
                    break
                }
            }
            let kind = try fastDirectoryEntryKind(entry.d_type, path: path, name: name)
            children.append(FastDirectoryChild(
                name: name,
                isASCII: entryName.isASCII,
                isHidden: entryName.isHidden,
                kind: kind
            ))
        }
        return FastDirectoryContents(
            children: children,
            hasGitMarker: hasGitMarker,
            hasGitignore: hasGitignore,
            hasIgnore: hasIgnore,
            hasRgignore: hasRgignore
        )
    }

    private func fastDirectoryTreeContainsFile(atPath path: String, includeHidden: Bool) throws -> Bool {
        var pathBytes = Array(path.utf8)
        return try fastDirectoryTreeContainsFile(atPathBytes: &pathBytes, includeHidden: includeHidden)
    }

    private func fastDirectoryTreeContainsFile(atPathBytes pathBytes: inout [UInt8], includeHidden: Bool) throws -> Bool {
        guard let directory = withTemporaryCString(pathBytes: &pathBytes, opendir) else {
            let path = String(decoding: pathBytes, as: UTF8.self)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path]
            )
        }
        defer {
            closedir(directory)
        }

        while let entryPointer = readdir(directory) {
            let entry = entryPointer.pointee
            let nameLength = Int(entry.d_namlen)
            let nameBytes = withUnsafePointer(to: entry.d_name) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: nameLength + 1) { bytes in
                    Array(UnsafeBufferPointer(start: bytes, count: nameLength))
                }
            }
            if isCurrentOrParentDirectoryName(nameBytes) {
                continue
            }
            if !includeHidden, nameBytes.first == UInt8(ascii: ".") {
                continue
            }
            switch try fastDirectoryEntryKind(entry.d_type, directoryPathBytes: &pathBytes, nameBytes: nameBytes) {
            case .file:
                return true
            case .directory:
                let childHasFile: Bool = try {
                    let previousCount = pathBytes.count
                    pathBytes.append(UInt8(ascii: "/"))
                    pathBytes.append(contentsOf: nameBytes)
                    defer {
                        pathBytes.removeSubrange(previousCount...)
                    }
                    return try fastDirectoryTreeContainsFile(atPathBytes: &pathBytes, includeHidden: includeHidden)
                }()
                if childHasFile {
                    return true
                }
            case .symbolicLink, .other:
                continue
            }
        }
        return false
    }

    private func fastDirectoryTreeContainsAllowedFile(
        directoryPath: String,
        logicalDirectoryPath: String,
        relativePath: String,
        rootBase: URL,
        rootDebugDisplayPath: String,
        rootArgumentIsAbsolute: Bool,
        vcsContext: Bool,
        warnings: inout [String],
        diagnostics: inout [String],
        filtered: inout Bool,
        ignoreStack: IgnoreStack,
        options: RipgrepOptions
    ) throws -> Bool {
        let contents = try fastDirectoryContents(atPath: directoryPath)
        let directoryVCSContext = vcsContext || (!options.noIgnoreVCS && contents.hasGitMarker)
        var directoryIgnoreStack = ignoreStack
        if !options.noIgnore && hasLoadableIgnoreFiles(
            hasGitMarker: contents.hasGitMarker,
            hasGitignore: contents.hasGitignore,
            hasIgnore: contents.hasIgnore,
            hasRgignore: contents.hasRgignore,
            vcsContext: directoryVCSContext,
            options: options
        ) {
            let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
            let logicalDirectoryURL = options.loggingMode == nil
                ? nil
                : URL(fileURLWithPath: logicalDirectoryPath, isDirectory: true)
            appendIgnoreFiles(
                in: directoryURL,
                logicalDirectory: logicalDirectoryURL,
                to: &directoryIgnoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                vcsContext: directoryVCSContext,
                scope: directoryIgnoreScope(relativePath: relativePath),
                directoryContents: DirectoryContents(
                    children: [],
                    hasGitMarker: contents.hasGitMarker,
                    hasGitignore: contents.hasGitignore,
                    hasIgnore: contents.hasIgnore,
                    hasRgignore: contents.hasRgignore
                ),
                options: options
            )
        }

        let directoryPathPrefix = directoryPath + "/"
        let relativePathPrefix = relativePath.isEmpty ? "" : relativePath + "/"
        for child in contents.children {
            let name = child.name
            let kind = child.kind
            if kind == .symbolicLink {
                continue
            }

            let childRelativePath = relativePathPrefix + name
            let isDirectory = kind.isDirectory
            if !options.hidden,
               child.isHidden,
               !isIncludedByIgnore(
                   relativePath: childRelativePath,
                   basename: name,
                   isDirectory: isDirectory,
                   ignoreStack: directoryIgnoreStack
               ) {
                continue
            }
            if !directoryIgnoreStack.allows(relativePath: childRelativePath, basename: name, isDirectory: isDirectory) {
                filtered = true
                continue
            }
            if kind.isFile {
                return true
            }
            if kind.isDirectory,
               try fastDirectoryTreeContainsAllowedFile(
                directoryPath: directoryPathPrefix + name,
                logicalDirectoryPath: joinedPath(logicalDirectoryPath, name),
                relativePath: childRelativePath,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                vcsContext: directoryVCSContext,
                warnings: &warnings,
                diagnostics: &diagnostics,
                filtered: &filtered,
                ignoreStack: directoryIgnoreStack,
                options: options
               ) {
                return true
            }
        }
        return false
    }

    private func outputPath(
        logicalDirectoryPathPrefix: String,
        logicalDirectoryPathIsASCII: Bool,
        child: FastDirectoryChild
    ) -> String {
        let path = logicalDirectoryPathPrefix + child.name
        return logicalDirectoryPathIsASCII && child.isASCII ? path : normalizedOutputPath(path)
    }

    private func fastDirectoryEntryNameAndFlags(
        _ entry: dirent
    ) -> (name: String, isASCII: Bool, isHidden: Bool)? {
        return withUnsafePointer(to: entry.d_name) { pointer in
            let nameLength = Int(entry.d_namlen)
            return pointer.withMemoryRebound(to: UInt8.self, capacity: nameLength + 1) { bytes in
                let buffer = UnsafeBufferPointer(start: bytes, count: nameLength)
                guard !isCurrentOrParentDirectoryName(buffer) else {
                    return nil
                }
                return (
                    String(decoding: buffer, as: UTF8.self),
                    buffer.allSatisfy { $0 < 0x80 },
                    buffer.first == UInt8(ascii: ".")
                )
            }
        }
    }

    private func fastDirectoryEntryKind(_ type: UInt8, path: String, name: String) throws -> FastDirectoryEntryKind {
        switch Int32(type) {
        case DT_DIR:
            return .directory
        case DT_REG:
            return .file
        case DT_LNK:
            return .symbolicLink
        case DT_UNKNOWN:
            var statBuffer = stat()
            let childPath = "\(path)/\(name)"
            guard lstat(childPath, &statBuffer) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: childPath]
                )
            }
            switch statBuffer.st_mode & S_IFMT {
            case S_IFDIR:
                return .directory
            case S_IFREG:
                return .file
            case S_IFLNK:
                return .symbolicLink
            default:
                return .other
            }
        default:
            return .other
        }
    }

    private func fastDirectoryEntryKind(_ type: UInt8, directoryPathBytes: inout [UInt8], nameBytes: [UInt8]) throws -> FastDirectoryEntryKind {
        switch Int32(type) {
        case DT_DIR:
            return .directory
        case DT_REG:
            return .file
        case DT_LNK:
            return .symbolicLink
        case DT_UNKNOWN:
            let previousCount = directoryPathBytes.count
            directoryPathBytes.append(UInt8(ascii: "/"))
            directoryPathBytes.append(contentsOf: nameBytes)
            defer {
                directoryPathBytes.removeSubrange(previousCount...)
            }
            var statBuffer = stat()
            let status = withTemporaryCString(pathBytes: &directoryPathBytes) { childPath in
                Darwin.lstat(childPath, &statBuffer)
            }
            guard status == 0 else {
                let childPath = String(decoding: directoryPathBytes, as: UTF8.self)
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: childPath]
                )
            }
            switch statBuffer.st_mode & S_IFMT {
            case S_IFDIR:
                return .directory
            case S_IFREG:
                return .file
            case S_IFLNK:
                return .symbolicLink
            default:
                return .other
            }
        default:
            return .other
        }
    }

    private func isDirectoryPath(_ path: String) -> Bool {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else {
            return false
        }
        return (statBuffer.st_mode & S_IFMT) == S_IFDIR
    }

    private func normalizedOutputPath(_ path: String) -> String {
        path.utf8.allSatisfy { $0 < 0x80 } ? path : path.precomposedStringWithCanonicalMapping
    }

    private func debugDisplayPath(
        path: String,
        childName: String,
        relativePath: String,
        rootDisplayPath: String,
        rootArgumentIsAbsolute: Bool
    ) -> String {
        if rootArgumentIsAbsolute {
            return "\(path)/\(childName)"
        }
        guard !relativePath.isEmpty else {
            return rootDisplayPath
        }
        return "\(rootDisplayPath)/\(relativePath)"
    }
    #endif

    private func walk(
        _ url: URL,
        physicalURL: URL?,
        isExplicit: Bool,
        depth: Int,
        ancestors: [DirectoryVisit],
        rootBase: URL,
        rootBasePrefix: String,
        rootDebugDisplayPath: String,
        rootArgumentIsAbsolute: Bool,
        cwdPrefix: String,
        rootVolume: String?,
        vcsContext: Bool,
        messages: inout [String],
        warnings: inout [String],
        diagnostics: inout [String],
        filtered: inout Bool,
        ignoreStack: IgnoreStack,
        overrides: GlobMatcher,
        typeRegistry: FileTypeRegistry,
        options: RipgrepOptions,
        haystacks: inout [Haystack],
        metadataOverride: WalkMetadata? = nil,
        relativePathOverride: String? = nil,
        fileName: String? = nil,
        shouldStopAfterFirstHaystack: Bool = false,
        visitHaystack: ((Haystack) -> Bool)? = nil
    ) throws {
        let metadataURL = physicalURL ?? url
        let values = try metadataOverride ?? metadata(for: metadataURL, followingSymlinks: false)
        let isDirectory = values.isDirectory
        let relativePath = relativePathOverride ?? relativePath(for: url, rootBase: rootBase, rootBasePrefix: rootBasePrefix)
        #if canImport(Darwin)
        let needsOverridePath = !overrides.isEmpty || (options.preprocessor != nil && !options.preGlobPatterns.isEmpty)
        let overridePath = needsOverridePath
            ? overridePath(for: url, rootArgumentIsAbsolute: rootArgumentIsAbsolute, cwdPrefix: cwdPrefix)
            : relativePath
        #else
        let overridePath = overridePath(for: url, rootArgumentIsAbsolute: rootArgumentIsAbsolute, cwdPrefix: cwdPrefix)
        #endif

        if !isExplicit {
            #if canImport(Darwin)
            let overrideDecision: GlobMatcher.Decision? = overrides.isEmpty
                ? nil
                : overrides.decision(relativePath: overridePath, isDirectory: isDirectory)
            #else
            let overrideDecision = overrides.decision(relativePath: overridePath, isDirectory: isDirectory)
            #endif
            let isIncludedByOverride = overrideDecision == .include
            #if canImport(Darwin)
            let isExcludedByOverride = overrideDecision == .exclude
                || (overrideDecision == nil
                    && !overrides.isEmpty
                    && !overrides.allows(relativePath: overridePath, isDirectory: isDirectory))
            #else
            let isExcludedByOverride = overrideDecision == .exclude
                || (overrideDecision == nil && !overrides.allows(relativePath: overridePath, isDirectory: isDirectory))
            #endif
            if isExcludedByOverride {
                debug("ignoring \(url.path): override glob", options: options, diagnostics: &diagnostics)
                return
            }
            if !isIncludedByOverride,
               !options.hidden,
               isHiddenName(fileName ?? url.lastPathComponent),
               (isDirectory || !typeRegistry.selectedTypeAllows(path: relativePath)),
               !isIncludedByIgnore(
                   relativePath: relativePath,
                   basename: fileName,
                   isDirectory: isDirectory,
                   ignoreStack: ignoreStack
               ) {
                if options.loggingMode != nil {
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
                }
                return
            }
            if !isIncludedByOverride && !ignoreStack.allows(relativePath: relativePath, basename: fileName, isDirectory: isDirectory) {
                if options.loggingMode != nil {
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
                }
                filtered = true
                return
            }
            if !isDirectory && !isIncludedByOverride && !typeRegistry.allows(path: relativePath) {
                debug("ignoring \(url.path): file type filter", options: options, diagnostics: &diagnostics)
                return
            }
        }

        if values.isSymbolicLink && !options.followSymlinks && !isExplicit {
            return
        }

        let resolvedURL = values.isSymbolicLink && (options.followSymlinks || isExplicit)
            ? url.resolvingSymlinksInPath()
            : metadataURL
        if values.isSymbolicLink,
           (options.followSymlinks || isExplicit),
           !fileManager.fileExists(atPath: resolvedURL.path) {
            messages.append(fileSystemMessage(for: url, errno: ENOENT))
            return
        }
        let resolvedValues: WalkMetadata
        if values.isSymbolicLink && (options.followSymlinks || isExplicit) {
            do {
                resolvedValues = try metadata(for: resolvedURL, followingSymlinks: true)
            } catch {
                messages.append(fileSystemMessage(for: url, error: error))
                return
            }
        } else {
            resolvedValues = values
        }

        if resolvedValues.isRegularFile {
            if !isExplicit,
               let maxFileSize = options.maxFileSize,
               let fileSize = values.fileSize,
               fileSize > maxFileSize {
                debug("ignoring \(url.path): \(fileSize) bytes exceeds max filesize \(maxFileSize)", options: options, diagnostics: &diagnostics)
                return
            }
            let haystack = Haystack(
                url: url,
                isExplicit: isExplicit,
                overridePath: overridePath,
                fileSize: resolvedValues.fileSize,
                isRegularFile: true
            )
            if let visitHaystack {
                if visitHaystack(haystack) {
                    haystacks.append(haystack)
                }
            } else {
                haystacks.append(haystack)
            }
            return
        }

        guard resolvedValues.isDirectory else {
            return
        }
        let resolvedDirectoryPath = resolvedURL.standardizedFileURL.path
        if let ancestor = ancestors.last(where: { $0.physicalPath == resolvedDirectoryPath }) {
            messages.append("File system loop found: \(url.path) points to an ancestor \(ancestor.logicalURL.path)")
            return
        }
        if !isExplicit,
           options.oneFileSystem,
           let rootVolume,
           let currentVolume = volumeIdentifier(for: resolvedURL),
           currentVolume != rootVolume {
            debug("ignoring \(url.path): different file system", options: options, diagnostics: &diagnostics)
            return
        }
        if let maxDepth = options.maxDepth, depth >= maxDepth {
            debug("ignoring \(url.path): max depth \(maxDepth)", options: options, diagnostics: &diagnostics)
            return
        }

        let directoryContents = try directoryContents(
            at: resolvedURL,
            preferDirectoryEntryMetadata: prefersDirectoryEntryMetadata(options: options)
        )
        let directoryVCSContext = vcsContext || (!options.noIgnoreVCS && directoryContents.hasGitMarker)
        var directoryIgnoreStack = ignoreStack
        if !options.noIgnore && hasLoadableIgnoreFiles(
            hasGitMarker: directoryContents.hasGitMarker,
            hasGitignore: directoryContents.hasGitignore,
            hasIgnore: directoryContents.hasIgnore,
            hasRgignore: directoryContents.hasRgignore,
            vcsContext: directoryVCSContext,
            options: options
        ) {
            appendIgnoreFiles(
                in: resolvedURL,
                logicalDirectory: url,
                to: &directoryIgnoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                vcsContext: directoryVCSContext,
                directoryContents: directoryContents,
                options: options
            )
        }

        let childAncestors = ancestors + [DirectoryVisit(
            logicalURL: url,
            physicalPath: resolvedDirectoryPath
        )]
        for child in directoryContents.children {
            let childURL = url.appendingPathComponent(child.name)
            let childRelativePath = relativePath.isEmpty ? child.name : "\(relativePath)/\(child.name)"
            try walk(
                childURL,
                physicalURL: child.url,
                isExplicit: false,
                depth: depth + 1,
                ancestors: childAncestors,
                rootBase: rootBase,
                rootBasePrefix: rootBasePrefix,
                rootDebugDisplayPath: rootDebugDisplayPath,
                rootArgumentIsAbsolute: rootArgumentIsAbsolute,
                cwdPrefix: cwdPrefix,
                rootVolume: rootVolume,
                vcsContext: directoryVCSContext,
                messages: &messages,
                warnings: &warnings,
                diagnostics: &diagnostics,
                filtered: &filtered,
                ignoreStack: directoryIgnoreStack,
                overrides: overrides,
                typeRegistry: typeRegistry,
                options: options,
                haystacks: &haystacks,
                metadataOverride: child.metadata,
                relativePathOverride: childRelativePath,
                fileName: child.name,
                shouldStopAfterFirstHaystack: shouldStopAfterFirstHaystack,
                visitHaystack: visitHaystack
            )
            if shouldStopAfterFirstHaystack && !haystacks.isEmpty {
                break
            }
        }
    }

    private func directoryContents(at url: URL, preferDirectoryEntryMetadata: Bool) throws -> DirectoryContents {
        #if canImport(Darwin)
        guard let directory = opendir(url.path) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        defer {
            closedir(directory)
        }

        var children: [DirectoryChild] = []
        var hasGitMarker = false
        var hasGitignore = false
        var hasIgnore = false
        var hasRgignore = false
        let directoryFileDescriptor = dirfd(directory)
        while let entryPointer = readdir(directory) {
            let entry = entryPointer.pointee
            let name = withUnsafePointer(to: entry.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." {
                continue
            }
            switch name {
            case ".git":
                hasGitMarker = true
            case ".gitignore":
                hasGitignore = true
            case ".ignore":
                hasIgnore = true
            case ".rgignore":
                hasRgignore = true
            default:
                break
            }
            let childMetadata = try directoryEntryMetadata(entry.d_type, preferDirectoryEntryMetadata: preferDirectoryEntryMetadata)
                ?? metadata(
                    named: name,
                    directoryFileDescriptor: directoryFileDescriptor,
                    followingSymlinks: false
                )
            children.append(DirectoryChild(
                url: url.appendingPathComponent(name),
                name: name,
                metadata: childMetadata
            ))
        }
        return DirectoryContents(
            children: children,
            hasGitMarker: hasGitMarker,
            hasGitignore: hasGitignore,
            hasIgnore: hasIgnore,
            hasRgignore: hasRgignore
        )
        #else
        let urls = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .nameKey,
            ],
            options: []
        )
        var children: [DirectoryChild] = []
        children.reserveCapacity(urls.count)
        var hasGitMarker = false
        var hasGitignore = false
        var hasIgnore = false
        var hasRgignore = false
        for child in urls {
            let name = child.lastPathComponent
            switch name {
            case ".git":
                hasGitMarker = true
            case ".gitignore":
                hasGitignore = true
            case ".ignore":
                hasIgnore = true
            case ".rgignore":
                hasRgignore = true
            default:
                break
            }
            children.append(DirectoryChild(url: child, name: name, metadata: nil))
        }
        return DirectoryContents(
            children: children,
            hasGitMarker: hasGitMarker,
            hasGitignore: hasGitignore,
            hasIgnore: hasIgnore,
            hasRgignore: hasRgignore
        )
        #endif
    }

    private func prefersDirectoryEntryMetadata(options: RipgrepOptions) -> Bool {
        #if canImport(Darwin)
        options.mode == .files
            && options.maxFileSize == nil
            && !options.followSymlinks
        #else
        false
        #endif
    }

    private func metadata(for url: URL, followingSymlinks: Bool) throws -> WalkMetadata {
        #if canImport(Darwin)
        var statBuffer = stat()
        let status = url.path.withCString { path in
            Darwin.fstatat(AT_FDCWD, path, &statBuffer, followingSymlinks ? 0 : AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        return metadata(from: statBuffer, followingSymlinks: followingSymlinks)
        #else
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .volumeIdentifierKey,
        ])
        return WalkMetadata(
            isDirectory: values.isDirectory == true,
            isRegularFile: values.isRegularFile == true,
            isSymbolicLink: !followingSymlinks && values.isSymbolicLink == true,
            fileSize: values.fileSize.map { UInt64(max(0, $0)) }
        )
        #endif
    }

    #if canImport(Darwin)
    private func metadata(
        named name: String,
        directoryFileDescriptor: Int32,
        followingSymlinks: Bool
    ) throws -> WalkMetadata {
        var statBuffer = stat()
        let status = name.withCString { childName in
            Darwin.fstatat(
                directoryFileDescriptor,
                childName,
                &statBuffer,
                followingSymlinks ? 0 : AT_SYMLINK_NOFOLLOW
            )
        }
        guard status == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: name]
            )
        }
        return metadata(from: statBuffer, followingSymlinks: followingSymlinks)
    }

    private func directoryEntryMetadata(
        _ type: UInt8,
        preferDirectoryEntryMetadata: Bool
    ) -> WalkMetadata? {
        guard preferDirectoryEntryMetadata else {
            return nil
        }
        switch Int32(type) {
        case DT_DIR:
            return WalkMetadata(isDirectory: true, isRegularFile: false, isSymbolicLink: false, fileSize: nil)
        case DT_REG:
            return WalkMetadata(isDirectory: false, isRegularFile: true, isSymbolicLink: false, fileSize: nil)
        case DT_LNK:
            return WalkMetadata(isDirectory: false, isRegularFile: false, isSymbolicLink: true, fileSize: nil)
        default:
            return nil
        }
    }

    private func metadata(from statBuffer: stat, followingSymlinks: Bool) -> WalkMetadata {
        WalkMetadata(
            isDirectory: (statBuffer.st_mode & S_IFMT) == S_IFDIR,
            isRegularFile: (statBuffer.st_mode & S_IFMT) == S_IFREG,
            isSymbolicLink: !followingSymlinks && (statBuffer.st_mode & S_IFMT) == S_IFLNK,
            fileSize: statBuffer.st_size >= 0 ? UInt64(statBuffer.st_size) : 0
        )
    }
    #endif

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
        if sortMode.kind == .path {
            let keyed = haystacks.map { haystack in
                (haystack: haystack, components: PathSort.components(for: haystack.url))
            }
            return keyed.sorted { lhs, rhs in
                let order = PathSort.compare(lhs.components, rhs.components)
                if sortMode.reverse {
                    return order == .orderedDescending
                }
                return order == .orderedAscending
            }.map(\.haystack)
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
        isHiddenName(url.lastPathComponent)
    }

    private func isHiddenName(_ name: String) -> Bool {
        name.utf8.first == UInt8(ascii: ".")
    }

    private func isHiddenName(_ nameBytes: [UInt8]) -> Bool {
        nameBytes.first == UInt8(ascii: ".")
    }

    private func isCurrentOrParentDirectoryName(_ nameBytes: [UInt8]) -> Bool {
        nameBytes.withUnsafeBufferPointer(isCurrentOrParentDirectoryName)
    }

    private func isCurrentOrParentDirectoryName(_ nameBytes: UnsafeBufferPointer<UInt8>) -> Bool {
        nameBytes.count == 1 && nameBytes[0] == UInt8(ascii: ".")
            || nameBytes.count == 2 && nameBytes[0] == UInt8(ascii: ".") && nameBytes[1] == UInt8(ascii: ".")
    }

    private func isIncludedByIgnore(relativePath: String, basename: String? = nil, isDirectory: Bool, ignoreStack: IgnoreStack) -> Bool {
        guard ignoreStack.canIncludePaths else {
            return false
        }
        return ignoreStack.decision(relativePath: relativePath, basename: basename, isDirectory: isDirectory) == .include
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
            vcsContext: options.noRequireGit || isInGitRepository(rootBase),
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
        let gitBoundary = hasGitMarker(in: rootBase) ? rootBase : parentURLs.last { hasGitMarker(in: $0) }
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
        guard let contents = try? String(contentsOfFile: gitFileURL.path, encoding: .utf8) else {
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
        guard let contents = try? String(contentsOfFile: commondirURL.path, encoding: .utf8) else {
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
        if options.mode == .files,
           !options.hidden,
           options.loggingMode == nil,
           !ignoreStack.canIncludePaths,
           globalIgnoreFileExcludesOnlyHiddenPaths(globalIgnoreFile) {
            return
        }
        let loaded = loadMatcher(
            from: globalIgnoreFile,
            rootBase: nil,
            reportLoadErrors: false,
            caseInsensitive: options.ignoreFileCaseInsensitive
        )
        if options.mode == .files,
           !options.hidden,
           options.loggingMode == nil,
           loaded.messages.isEmpty,
           !ignoreStack.canIncludePaths,
           loaded.matcher.excludesOnlyHiddenPaths {
            return
        }
        ignoreStack.append(loaded.matcher)
        if !options.noIgnoreMessages {
            warnings.append(contentsOf: loaded.messages)
        }
    }

    private func globalIgnoreFileExcludesOnlyHiddenPaths(_ fileURL: URL) -> Bool {
        guard let contents = try? String(contentsOfFile: fileURL.path, encoding: .utf8) else {
            return false
        }
        let parsed = parseIgnorePatterns(contents, fileURL: fileURL)
        guard parsed.messages.isEmpty else {
            return false
        }
        return GlobMatcher.parsedPatternsExcludeOnlyHiddenPaths(parsed.patterns)
    }

    private func appendExplicitIgnoreFiles(
        to ignoreStack: inout IgnoreStack,
        rootBase: URL,
        rootVCSContext: Bool = false,
        warnings: inout [String],
        diagnostics: inout [String],
        options: RipgrepOptions
    ) {
        guard !options.noIgnoreFiles else {
            return
        }
        let pathPrefix = cwdRelativePathPrefix(for: rootBase)
        let rootVCSGitignorePath = rootVCSCoveredGitignorePath(rootBase: rootBase, rootVCSContext: rootVCSContext, options: options)
        for (offset, ignoreFile) in options.ignoreFiles.enumerated() {
            let dropRootVCSCoveredBasenameRules = rootVCSGitignorePath == ignoreFile.standardizedFileURL.path
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
                ignoreExplicitRootMatch: true,
                dropRootVCSCoveredBasenameRules: dropRootVCSCoveredBasenameRules,
                options: options
            )
        }
    }

    private func rootVCSCoveredGitignorePath(rootBase: URL, rootVCSContext: Bool, options: RipgrepOptions) -> String? {
        guard options.mode == .files,
              options.loggingMode == nil,
              !options.noIgnore,
              !options.noIgnoreVCS,
              rootVCSContext else {
            return nil
        }
        let gitignoreURL = rootBase.appendingPathComponent(".gitignore")
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: gitignoreURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return gitignoreURL.standardizedFileURL.path
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

    private func relativePath(for url: URL, rootBase: URL, rootBasePrefix: String? = nil) -> String {
#if canImport(Darwin)
        if let rootBasePrefix {
            let path = url.path
            if path.hasPrefix(rootBasePrefix) {
                return String(path.dropFirst(rootBasePrefix.count))
            }
            return url.lastPathComponent
        }
#endif
        let path = url.standardizedFileURL.path
        let basePath = rootBase.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : "\(basePath)/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }

    private func overridePath(for url: URL, rootArgumentIsAbsolute: Bool, cwdPrefix: String? = nil) -> String {
#if canImport(Darwin)
        if let cwdPrefix {
            let path = url.path
            guard !rootArgumentIsAbsolute else {
                return path.hasPrefix("/") ? String(path.dropFirst()) : path
            }
            if path.hasPrefix(cwdPrefix) {
                return String(path.dropFirst(cwdPrefix.count))
            }
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
#endif
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
        scope: (stripBasePath: String?, pathPrefix: String)? = nil,
        pathPrefix: String? = nil,
        slashPatternsMatchAnywhere: Bool? = nil,
        reportLoadErrors: Bool = false,
        displayPath: String? = nil,
        caseInsensitive: Bool? = nil,
        ignoreExplicitRootMatch: Bool = false,
        dropRootVCSCoveredBasenameRules: Bool = false,
        emitDiagnostics: Bool = true,
        skipMissingFileCheck: Bool = false,
        options: RipgrepOptions
    ) {
        let loaded = loadMatcher(
            from: fileURL,
            rootBase: rootBase,
            scopeDirectory: scopeDirectory,
            scope: scope,
            pathPrefix: pathPrefix,
            slashPatternsMatchAnywhere: slashPatternsMatchAnywhere,
            reportLoadErrors: reportLoadErrors,
            displayPath: displayPath,
            caseInsensitive: caseInsensitive ?? options.ignoreFileCaseInsensitive,
            ignoreExplicitRootMatch: ignoreExplicitRootMatch,
            dropRootVCSCoveredBasenameRules: dropRootVCSCoveredBasenameRules,
            skipMissingFileCheck: skipMissingFileCheck,
            collectDiagnostics: emitDiagnostics && options.loggingMode != .none
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
        scope precomputedScope: (stripBasePath: String?, pathPrefix: String)? = nil,
        pathPrefix: String? = nil,
        slashPatternsMatchAnywhere: Bool? = nil,
        reportLoadErrors: Bool = false,
        displayPath: String? = nil,
        caseInsensitive: Bool = false,
        ignoreExplicitRootMatch: Bool = false,
        dropRootVCSCoveredBasenameRules: Bool = false,
        skipMissingFileCheck: Bool = false,
        collectDiagnostics: Bool = false
    ) -> LoadedIgnoreMatcher {
        if !reportLoadErrors && !skipMissingFileCheck {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return LoadedIgnoreMatcher(matcher: GlobMatcher(patterns: []), messages: [], diagnostics: [])
            }
        }

        let contents: String
        do {
            contents = try String(contentsOfFile: fileURL.path, encoding: .utf8)
        } catch {
            let messages = reportLoadErrors ? [ignoreFileLoadMessage(for: fileURL, displayPath: displayPath)] : []
            return LoadedIgnoreMatcher(matcher: GlobMatcher(patterns: []), messages: messages, diagnostics: [])
        }
        let parsed = parseIgnorePatterns(contents, fileURL: fileURL)
        let parsedPatterns = dropRootVCSCoveredBasenameRules
            ? parsed.patterns.filter { !isUnanchoredBasenameIgnorePattern($0) }
            : parsed.patterns
        let scope = pathPrefix.map { (stripBasePath: String?.none, pathPrefix: $0) }
            ?? precomputedScope
            ?? ignoreScope(for: scopeDirectory ?? fileURL.deletingLastPathComponent(), rootBase: rootBase)
        let matchSlashPatternsAnywhere = slashPatternsMatchAnywhere ?? false
        let scopedPatterns = ignoreExplicitRootMatch
            ? patternsIgnoringExplicitRootMatch(
                parsedPatterns,
                scope: scope,
                slashPatternsMatchAnywhere: matchSlashPatternsAnywhere,
                caseInsensitive: caseInsensitive
            )
            : parsedPatterns
        let patterns = pathPrefix.map {
            patternsIgnoringUnmatchableExplicitAnchors(
                scopedPatterns,
                pathPrefix: $0,
                caseInsensitive: caseInsensitive
            )
        } ?? scopedPatterns
        let diagnostics = collectDiagnostics
            ? ignoreLoadDiagnostics(
                fileURL: fileURL,
                displayPath: displayPath,
                patterns: patterns
            )
            : []
        return LoadedIgnoreMatcher(matcher: GlobMatcher(
            patterns: patterns,
            caseInsensitive: caseInsensitive,
            stripBasePath: scope.stripBasePath,
            pathPrefix: scope.pathPrefix,
            slashPatternsMatchAnywhere: matchSlashPatternsAnywhere,
            sourcePath: collectDiagnostics ? ignoreDiagnosticPath(fileURL, displayPath: displayPath) : nil
        ), messages: parsed.messages, diagnostics: diagnostics)
    }

    private func isUnanchoredBasenameIgnorePattern(_ rawPattern: String) -> Bool {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
            return false
        }
        let normalized: String
        if trimmed.hasPrefix("\\#") || trimmed.hasPrefix("\\!") {
            normalized = String(trimmed.dropFirst())
        } else if trimmed.hasPrefix("!") {
            normalized = String(trimmed.dropFirst())
        } else {
            normalized = trimmed
        }
        var pattern = normalized.replacingOccurrences(of: #"\/"#, with: "/")
        if pattern.hasPrefix("/") {
            return false
        }
        if pattern.hasSuffix("/") {
            pattern.removeLast()
        }
        return !pattern.isEmpty && !pattern.contains("/")
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

    private func patternsIgnoringUnmatchableExplicitAnchors(
        _ patterns: [String],
        pathPrefix: String,
        caseInsensitive: Bool
    ) -> [String] {
        guard !pathPrefix.isEmpty,
              let prefixComponent = pathPrefix.split(separator: "/", maxSplits: 1).first,
              !prefixComponent.isEmpty else {
            return patterns
        }
        let prefix = String(prefixComponent)
        let foldedPrefix = caseInsensitive ? prefix.lowercased() : prefix

        return patterns.filter { pattern in
            guard let anchorComponent = explicitAnchorFirstComponent(pattern) else {
                return true
            }
            if anchorComponent.hasGlobMeta {
                let matcher = GlobMatcher(
                    patterns: [anchorComponent.pattern],
                    caseInsensitive: caseInsensitive,
                    slashPatternsMatchAnywhere: false
                )
                return matcher.decision(
                    relativePath: prefix,
                    basename: prefix,
                    isDirectory: true
                ) != nil
            }
            if caseInsensitive {
                return anchorComponent.pattern.lowercased() == foldedPrefix
            }
            return anchorComponent.pattern == prefix
        }
    }

    private struct ExplicitAnchorFirstComponent {
        let pattern: String
        let hasGlobMeta: Bool
    }

    private func explicitAnchorFirstComponent(_ rawPattern: String) -> ExplicitAnchorFirstComponent? {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
            return nil
        }
        var pattern = trimmed
        if pattern.hasPrefix("\\#") || pattern.hasPrefix("\\!") {
            pattern.removeFirst()
        } else if pattern.hasPrefix("!") {
            pattern.removeFirst()
        }
        guard pattern.hasPrefix("/") else {
            return nil
        }
        pattern.removeFirst()
        while pattern.hasSuffix("/") {
            pattern.removeLast()
        }
        guard let firstComponent = pattern.split(separator: "/", maxSplits: 1).first,
              !firstComponent.isEmpty,
              !firstComponent.contains("\\") else {
            return nil
        }
        return ExplicitAnchorFirstComponent(
            pattern: String(firstComponent),
            hasGlobMeta: firstComponent.contains("*")
                || firstComponent.contains("?")
                || firstComponent.contains("[")
                || firstComponent.contains("{")
        )
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
        (contents.components(separatedBy: .newlines), [])
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
        return try? String(contentsOfFile: url.path, encoding: .utf8)
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
        vcsContext: Bool,
        scope: (stripBasePath: String?, pathPrefix: String)? = nil,
        directoryContents: DirectoryContents? = nil,
        options: RipgrepOptions
    ) {
        let scopeDirectory = logicalDirectory ?? directoryURL
        let shouldRenderIgnoreDiagnostics = options.loggingMode != nil
        let localIgnoreEntriesWereScanned = directoryContents != nil
        if !options.noIgnoreDot {
            if directoryContents?.hasIgnore != false {
                let ignoreURL = directoryURL.appendingPathComponent(".ignore")
                appendLoadedMatcher(
                    from: ignoreURL,
                    to: &ignoreStack,
                    warnings: &warnings,
                    diagnostics: &diagnostics,
                    rootBase: rootBase,
                    scopeDirectory: scopeDirectory,
                    scope: scope,
                    displayPath: shouldRenderIgnoreDiagnostics
                        ? ignoreFileDebugDisplayPath(
                            for: scopeDirectory.appendingPathComponent(".ignore"),
                            rootBase: rootBase,
                            rootDisplayPath: rootDebugDisplayPath,
                            rootArgumentIsAbsolute: rootArgumentIsAbsolute
                        )
                        : nil,
                    skipMissingFileCheck: localIgnoreEntriesWereScanned,
                    options: options
                )
            }
            if directoryContents?.hasRgignore != false {
                let rgignoreURL = directoryURL.appendingPathComponent(".rgignore")
                appendLoadedMatcher(
                    from: rgignoreURL,
                    to: &ignoreStack,
                    warnings: &warnings,
                    diagnostics: &diagnostics,
                    rootBase: rootBase,
                    scopeDirectory: scopeDirectory,
                    scope: scope,
                    displayPath: shouldRenderIgnoreDiagnostics
                        ? ignoreFileDebugDisplayPath(
                            for: scopeDirectory.appendingPathComponent(".rgignore"),
                            rootBase: rootBase,
                            rootDisplayPath: rootDebugDisplayPath,
                            rootArgumentIsAbsolute: rootArgumentIsAbsolute
                        )
                        : nil,
                    skipMissingFileCheck: localIgnoreEntriesWereScanned,
                    options: options
                )
            }
        }
        let shouldLoadVCSIgnore = !options.noIgnoreVCS && (options.noRequireGit || vcsContext)
        if shouldLoadVCSIgnore, directoryContents?.hasGitignore != false {
            let gitignoreURL = directoryURL.appendingPathComponent(".gitignore")
            appendLoadedMatcher(
                from: gitignoreURL,
                to: &ignoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                scopeDirectory: scopeDirectory,
                scope: scope,
                displayPath: shouldRenderIgnoreDiagnostics
                    ? ignoreFileDebugDisplayPath(
                        for: scopeDirectory.appendingPathComponent(".gitignore"),
                        rootBase: rootBase,
                        rootDisplayPath: rootDebugDisplayPath,
                        rootArgumentIsAbsolute: rootArgumentIsAbsolute
                    )
                    : nil,
                skipMissingFileCheck: localIgnoreEntriesWereScanned,
                options: options
            )
        }
        if !options.noIgnoreExclude,
           shouldLoadVCSIgnore,
           directoryContents?.hasGitMarker != false,
           let excludeURL = gitInfoExcludeURL(for: directoryURL) {
            appendLoadedMatcher(
                from: excludeURL,
                to: &ignoreStack,
                warnings: &warnings,
                diagnostics: &diagnostics,
                rootBase: rootBase,
                scopeDirectory: scopeDirectory,
                scope: scope,
                displayPath: shouldRenderIgnoreDiagnostics
                    ? ignoreFileDebugDisplayPath(
                        for: scopeDirectory.appendingPathComponent(".git/info/exclude"),
                        rootBase: rootBase,
                        rootDisplayPath: rootDebugDisplayPath,
                        rootArgumentIsAbsolute: rootArgumentIsAbsolute
                    )
                    : nil,
                options: options
            )
        }
    }

    private func directoryIgnoreScope(relativePath: String) -> (stripBasePath: String?, pathPrefix: String) {
        (relativePath, "")
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
