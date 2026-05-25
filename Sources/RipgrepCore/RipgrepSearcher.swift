import Foundation
#if canImport(CRipgrepPlatform)
import CRipgrepPlatform
#endif
#if canImport(Darwin)
import Darwin
#endif

private struct FileSearchOutcome: Sendable {
    let result: SearchFileResult
    let message: String?

    init(result: SearchFileResult, message: String? = nil) {
        self.result = result
        self.message = message
    }
}

private struct DecompressionCommand {
    let executable: URL
    let arguments: [String]
}

private struct SearchedHaystack: Sendable {
    let url: URL
    let result: SearchFileResult
    let message: String?
}

private struct SearchWorkItem: Sendable {
    let index: Int
    let url: URL
    let isExplicit: Bool
    let overridePath: String
    let fileSize: UInt64?
    let isRegularFile: Bool?
}

private actor ParallelSearchState {
    private let items: [SearchWorkItem]
    private var nextIndex = 0
    private var results: [SearchedHaystack?]

    init(items: [SearchWorkItem]) {
        self.items = items
        self.results = Array(repeating: nil, count: items.count)
    }

    func next() -> SearchWorkItem? {
        guard nextIndex < items.count else {
            return nil
        }
        let item = items[nextIndex]
        nextIndex += 1
        return item
    }

    func store(_ item: SearchWorkItem, outcome: FileSearchOutcome) {
        results[item.index] = SearchedHaystack(
            url: item.url,
            result: outcome.result,
            message: outcome.message
        )
    }

    func orderedResults() -> [SearchedHaystack] {
        results.compactMap { $0 }
    }
}

private final class ParallelSearchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[SearchedHaystack], Error>?

    func set(_ result: Result<[SearchedHaystack], Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws -> [SearchedHaystack] {
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}

private struct MultilineSpanCandidate {
    let span: MatchSpan
    let startLineIndex: Int
    let endLineIndex: Int
}

private struct RawLineMap {
    let decodedToRawByteOffsets: [Int]
    let invalidDecodedRanges: [Range<Int>]
}

public struct RipgrepSearcher: @unchecked Sendable {
    private static let binaryDetectionBufferSize = 64 * 1024

    private let fileManager: FileManager
    private let environment: [String: String]

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    public func search(
        pattern: String,
        roots: [URL],
        ignoreCase: Bool = false
    ) throws -> [SearchMatch] {
        var options = RipgrepOptions()
        options.pattern = pattern
        options.roots = roots
        options.ignoreCase = ignoreCase
        return try search(options: options).files.flatMap(\.matches)
    }

    public func files(options: RipgrepOptions) throws -> [URL] {
        try FileWalker(fileManager: fileManager)
            .withEnvironment(environment)
            .haystacks(for: options)
            .map(\.url)
    }

    public func walkFilesWithMessages(options: RipgrepOptions) throws -> FileWalkResults {
        try FileWalker(fileManager: fileManager)
            .withEnvironment(environment)
            .haystacksWithMessages(for: options)
    }

    public func search(options: RipgrepOptions) throws -> SearchResults {
        try search(options: options, stdin: nil)
    }

    public func streamPlainMatchingLines(
        options: RipgrepOptions,
        emit: (String) -> Void
    ) throws -> SearchResults? {
        #if !canImport(Darwin)
        return nil
        #else
        guard canStreamPlainMatchingLines(options: options) else {
            return nil
        }
        guard let root = options.roots.first,
              !isDirectory(root.standardizedFileURL) else {
            return nil
        }

        let matcher = try PatternMatcher(options: options)
        guard !matcher.usesByteSemantics,
              matcher.byteLiteralFastPath() != nil else {
            return nil
        }
        let walkResults = try FileWalker(fileManager: fileManager)
            .withEnvironment(environment)
            .haystacksWithMessages(for: options)
        guard walkResults.haystacks.count == 1,
              let haystack = walkResults.haystacks.first,
              haystack.isExplicit,
              !isDirectory(haystack.url),
              !shouldPreprocess(haystack, options: options),
              decompressionCommand(for: haystack.url, options: options) == nil,
              try canPreflightPlainStreamingText(haystack, options: options) else {
            return nil
        }

        var streamOptions = options
        streamOptions.mmapMode = .never
        var matchedLines = 0
        var totalBytes = 0
        try HaystackReader.streamLines(haystack, options: streamOptions) { streamedLine, _ in
            totalBytes = streamedLine.absoluteOffset + streamedLine.data.count + streamedLine.terminator.count
            guard let line = String(data: streamedLine.data, encoding: .utf8),
                  !matcher.canFastReject(line),
                  matcher.hasPositiveMatch(in: line) else {
                return
            }
            matchedLines += 1
            emit(line)
        }

        let result = SearchFileResult(
            fileURL: haystack.url,
            matches: [],
            bytesSearched: totalBytes,
            searched: true,
            supplementalMatchedLines: matchedLines,
            supplementalMatches: matchedLines
        )
        return SearchResults(
            files: [result],
            summary: SearchSummary(
                filesSearched: 1,
                filesWithMatches: matchedLines > 0 ? 1 : 0,
                matchedLines: matchedLines,
                totalMatches: matchedLines
            ),
            messages: walkResults.messages,
            warnings: walkResults.warnings,
            diagnostics: walkResults.diagnostics,
            filtered: walkResults.filtered
        )
        #endif
    }

    public func search(options: RipgrepOptions, stdin: String?) throws -> SearchResults {
        let matcher = try PatternMatcher(options: options)
        let walkResults = options.useStdin && options.roots.isEmpty
            ? FileWalkResults(haystacks: [], messages: [], warnings: explicitIgnoreFileLoadWarnings(options: options))
            : try FileWalker(fileManager: fileManager)
                .withEnvironment(environment)
                .haystacksWithMessages(for: options)
        var messages = walkResults.messages
        let warnings = walkResults.warnings
        let diagnostics = walkResults.diagnostics
        let searchedHaystacks = try searchHaystacks(
            walkResults.haystacks,
            matcher: matcher,
            options: options
        )
        for haystack in searchedHaystacks {
            if let message = haystack.message {
                messages.append(message)
            }
        }
        var files = searchedHaystacks.map(\.result)

        if options.useStdin {
            let stdinData = stdin.map { Data($0.utf8) } ?? ((try? HaystackReader.readStandardInput()) ?? Data())
            let stdinResults = stdinSearchResults(
                stdinData,
                matcher: matcher,
                options: options
            )
            if preservesExplicitStdinPosition(options: options) {
                var ordered: [SearchFileResult] = []
                var insertedStdin = false
                var stdinIndex = 0
                var consumedHaystackIndices = Set<Int>()
                for rootPath in options.rootPathArguments {
                    if rootPath == "-" || rootPath == "<stdin>" {
                        if stdinIndex < stdinResults.count {
                            ordered.append(stdinResults[stdinIndex])
                            stdinIndex += 1
                            insertedStdin = true
                        }
                        continue
                    }
                    let root = URL(fileURLWithPath: rootPath).standardizedFileURL
                    let matchingIndices = searchedHaystacks.indices.filter { index in
                        !consumedHaystackIndices.contains(index)
                            && isRootMatch(searchedHaystacks[index].url, root: root)
                    }
                    let indicesToAppend = isDirectory(root)
                        ? matchingIndices
                        : Array(matchingIndices.prefix(1))
                    for index in indicesToAppend {
                        ordered.append(searchedHaystacks[index].result)
                        consumedHaystackIndices.insert(index)
                    }
                }
                if !insertedStdin {
                    ordered.append(stdinResults[0])
                }
                files = ordered
            } else if shouldSearchStdinFirst(options: options) {
                files = [stdinResults[0]] + files + stdinResults.dropFirst()
            } else {
                files.append(contentsOf: stdinResults)
            }
        }
        files = sorted(files, options: options)

        let matchedFiles = files.filter(\.hasMatch)
        let summary = SearchSummary(
            filesSearched: files.filter(\.searched).count,
            filesWithMatches: matchedFiles.count,
            matchedLines: matchedFiles.reduce(0) { total, file in
                let matchedLines = file.matches.reduce(0) { $0 + MatchedLineCounter.count($1, options: options) }
                return total + (matchedLines == 0 && file.hasBinaryMatch ? 1 : matchedLines) + file.supplementalMatchedLines
            },
            totalMatches: matchedFiles.reduce(0) { total, file in
                if options.invertMatch {
                    return total
                }
                let matchCount = file.matches.reduce(0) { $0 + $1.matchCount }
                let promotedBinaryMatch = matchCount == 0
                    && file.hasBinaryMatch
                    && !shouldPreserveZeroMultilineBinaryMatchCount(options: options)
                return total + (promotedBinaryMatch ? 1 : matchCount) + file.supplementalMatches
            }
        )

        return SearchResults(
            files: files,
            summary: summary,
            messages: messages,
            warnings: warnings,
            diagnostics: diagnostics,
            filtered: walkResults.filtered
        )
    }

    private func canStreamPlainMatchingLines(options: RipgrepOptions) -> Bool {
        guard options.mode == .search,
              options.printMode == .matchingLines,
              options.rootPathArguments.count == 1,
              !options.useStdin,
              !options.patternFileStdin,
              options.sortMode == nil,
              !options.quiet,
              !options.json,
              !options.stats,
              !options.multiline,
              !options.nullData,
              !options.invertMatch,
              !options.stopOnNonmatch,
              !options.onlyMatching,
              options.replacement == nil,
              options.maxCount == nil,
              options.maxColumns == nil,
              options.beforeContext == 0,
              options.afterContext == 0,
              !options.passthru,
              !options.lineRegexp,
              !options.noUnicode,
              !options.wantsLineNumber,
              !options.column,
              !options.byteOffset,
              options.heading != true,
              !options.trim,
              !options.vimgrep,
              !options.crlf,
              options.withFilename != true,
              options.colorChanges.isEmpty,
              !options.hyperlinkFormat.isEnabled,
              options.binaryMode == .automatic else {
            return false
        }
        guard case .automatic = options.encodingMode else {
            return false
        }
        guard options.colorMode == .never
                || (options.colorMode == .automatic && isatty(STDOUT_FILENO) == 0) else {
            return false
        }
        return !options.effectivePatterns.contains { pattern in
            pattern.contains("$")
                || pattern.contains(#"\A"#)
                || pattern.contains(#"\z"#)
                || pattern.contains(#"\Z"#)
        }
    }

    private func canPreflightPlainStreamingText(
        _ haystack: Haystack,
        options: RipgrepOptions
    ) throws -> Bool {
        var streamOptions = options
        streamOptions.mmapMode = .never
        var isFirstLine = true
        var canStream = true
        try HaystackReader.streamLines(haystack, options: streamOptions) { streamedLine, terminate in
            var lineData = streamedLine.data
            lineData.append(streamedLine.terminator)
            if isFirstLine {
                isFirstLine = false
                if lineData.starts(with: [0xEF, 0xBB, 0xBF])
                    || lineData.starts(with: [0xFF, 0xFE])
                    || lineData.starts(with: [0xFE, 0xFF]) {
                    canStream = false
                    terminate = true
                    return
                }
            }
            if lineData.contains(0) || String(data: streamedLine.data, encoding: .utf8) == nil {
                canStream = false
                terminate = true
            }
        }
        return canStream
    }

    private func shouldPreserveZeroMultilineBinaryMatchCount(options: RipgrepOptions) -> Bool {
        options.multiline && options.effectivePatterns.allSatisfy(isBareMultilineLineEndPattern)
    }

    private func explicitIgnoreFileLoadWarnings(options: RipgrepOptions) -> [String] {
        guard !options.noIgnoreFiles, !options.noIgnoreMessages else {
            return []
        }
        return zip(options.ignoreFiles, options.ignoreFileDisplayPaths).compactMap { fileURL, displayPath in
            explicitIgnoreFileLoadWarning(fileURL: fileURL, displayPath: displayPath)
        }
    }

    private func explicitIgnoreFileLoadWarning(fileURL: URL, displayPath: String) -> String? {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "\(displayPath): line 1: Is a directory (os error 21)"
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            return "\(displayPath): No such file or directory (os error 2)"
        }
        return nil
    }

    private func preservesExplicitStdinPosition(options: RipgrepOptions) -> Bool {
        guard let sortMode = options.sortMode else {
            return true
        }
        return sortMode.kind == .path && !sortMode.reverse
    }

    private func shouldSearchStdinFirst(options: RipgrepOptions) -> Bool {
        guard let sortMode = options.sortMode else {
            return true
        }
        return sortMode.kind == .path && sortMode.reverse
    }

    private func sorted(_ files: [SearchFileResult], options: RipgrepOptions) -> [SearchFileResult] {
        guard let sortMode = options.sortMode else {
            return files
        }
        if sortMode.kind == .path && !sortMode.reverse {
            return files
        }
        if sortMode.kind == .path && sortMode.reverse && files.contains(where: { $0.fileURL.lastPathComponent == "<stdin>" }) {
            return files
        }
        return files.sorted { lhs, rhs in
            let order = compare(lhs.fileURL, rhs.fileURL, by: sortMode.kind)
            if sortMode.reverse {
                return order == .orderedDescending
            }
            return order == .orderedAscending
        }
    }

    func writeDarwinSimpleByteLiteralLines(
        options: RipgrepOptions,
        writeBytes: (UnsafeRawBufferPointer) -> Void
    ) throws -> SearchResults? {
        #if !canImport(Darwin)
        return nil
        #else
        guard canWriteDarwinSimpleByteLiteralLines(options: options) else {
            return nil
        }

        let matcher = try PatternMatcher(options: options)
        guard let fastPath = matcher.byteLiteralFastPath(),
              !fastPath.literals.isEmpty,
              fastPath.literals.allSatisfy({ !$0.isEmpty }),
              canWriteDarwinSimpleByteLiteralFastPath(fastPath),
              let fileURL = options.roots.first?.standardizedFileURL else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        let data = try HaystackReader.read(Haystack(url: fileURL, isExplicit: true), options: options)
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]),
              !data.starts(with: [0xFF, 0xFE]),
              !data.starts(with: [0xFE, 0xFF]) else {
            return nil
        }
        if !options.disablesBinaryDetection,
           shouldCheckBinary(data, options: options),
           firstNulByteOffset(in: data, limit: Self.binaryDetectionBufferSize) != nil {
            return nil
        }

        let literals = fastPath.literals
        let maxCount = options.maxCount ?? Int.max
        var matchedLineCount = 0
        var bytesSearched = data.count
        var needsDecodedFallback = false
        let wantsLineNumber = options.wantsLineNumber
        let countOnly = options.printMode == .count
        let filesWithMatches = options.printMode == .filesWithMatches
        let filesWithoutMatch = options.printMode == .filesWithoutMatch
        let pathOnly = filesWithMatches || filesWithoutMatch
        let countMatchesOnly = options.printMode == .countMatches
        let onlyMatching = options.onlyMatching
        var totalMatchCount = 0

        data.withUnsafeBytes { rawBytes in
            guard let rawBaseAddress = rawBytes.baseAddress else {
                return
            }
            let baseAddress = rawBaseAddress.assumingMemoryBound(to: UInt8.self)
            let byteBuffer = UnsafeBufferPointer(start: baseAddress, count: data.count)
            var lineNumber = 1
            var lineCountOffset = 0

            if options.quiet || pathOnly {
                if literals.count == 1,
                   let literal = literals.first {
                    var searchOffset = 0
                    var foldedLiteral: [UInt8] = []
                    var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
                    if fastPath.caseInsensitiveASCII {
                        foldedLiteral = literal.map(asciiLowercase)
                        if literal.count > 1 {
                            for index in 0..<(foldedLiteral.count - 1) {
                                caseInsensitiveShifts[Int(foldedLiteral[index])] = literal.count - 1 - index
                            }
                        }
                    }
                    while searchOffset < data.count {
                        let foundPointer: UnsafePointer<UInt8>?
                        if fastPath.caseInsensitiveASCII {
                            foundPointer = foldedLiteral.withUnsafeBufferPointer { foldedNeedle in
                                caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                                    rg_memcasemem_ascii_prepared(
                                        baseAddress.advanced(by: searchOffset),
                                        data.count - searchOffset,
                                        foldedNeedle.baseAddress,
                                        foldedNeedle.count,
                                        shifts.baseAddress
                                    )
                                }
                            }
                        } else {
                            foundPointer = literal.withUnsafeBufferPointer { needle in
                                rg_memmem_simple(
                                    baseAddress.advanced(by: searchOffset),
                                    data.count - searchOffset,
                                    needle.baseAddress,
                                    needle.count
                                )
                            }
                        }
                        guard let rawFoundPointer = foundPointer else {
                            return
                        }
                        let matchStart = baseAddress.distance(to: rawFoundPointer)
                        if fastPath.wordASCII {
                            var lineStart = matchStart
                            while lineStart > 0, baseAddress[lineStart - 1] != UInt8(ascii: "\n") {
                                lineStart -= 1
                            }
                            let remaining = data.count - matchStart
                            let newlinePointer = memchr(rawFoundPointer, Int32(UInt8(ascii: "\n")), remaining)
                            let lineEnd = newlinePointer.map {
                                baseAddress.distance(to: $0.assumingMemoryBound(to: UInt8.self))
                            } ?? data.count
                            switch asciiWordBoundaryState(
                                bytes: byteBuffer,
                                lineStart: lineStart,
                                lineEnd: lineEnd,
                                matchStart: matchStart,
                                matchEnd: matchStart + literal.count
                            ) {
                            case .bounded:
                                matchedLineCount = 1
                                bytesSearched = matchStart + literal.count
                                return
                            case .notBounded:
                                searchOffset = max(matchStart + 1, searchOffset + 1)
                                continue
                            case .needsDecodedFallback:
                                needsDecodedFallback = true
                                return
                            }
                        }
                        matchedLineCount = 1
                        bytesSearched = matchStart + literal.count
                        return
                    }
                    return
                }

                if let byteSet = singleByteLiteralSet(literals) {
                    var table = [UInt8](repeating: 0, count: 256)
                    byteSet.withUnsafeBufferPointer { needles in
                        rg_byte_set_init(&table, needles.baseAddress, needles.count)
                    }
                    if let foundPointer = rg_memchr_any_table(baseAddress, data.count, table) {
                        matchedLineCount = 1
                        bytesSearched = baseAddress.distance(to: foundPointer) + 1
                    }
                }
                return
            }

            func advanceLineNumber(to targetOffset: Int) {
                guard wantsLineNumber, lineCountOffset < targetOffset else {
                    return
                }
                lineNumber += Int(rg_memcount_byte(
                    baseAddress.advanced(by: lineCountOffset),
                    targetOffset - lineCountOffset,
                    UInt8(ascii: "\n")
                ))
                lineCountOffset = targetOffset
            }

            func writeLineNumberPrefix(for lineStart: Int) {
                guard wantsLineNumber else {
                    return
                }
                advanceLineNumber(to: lineStart)
                withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
                    var cursor = buffer.count - 1
                    buffer[cursor] = UInt8(ascii: ":")
                    var number = lineNumber
                    repeat {
                        cursor -= 1
                        buffer[cursor] = UInt8(number % 10) + UInt8(ascii: "0")
                        number /= 10
                    } while number > 0
                    writeBytes(UnsafeRawBufferPointer(
                        start: buffer.baseAddress?.advanced(by: cursor),
                        count: buffer.count - cursor
                    ))
                }
            }

            if literals.count == 1,
               let literal = literals.first {
                var searchOffset = 0
                var lastEmittedLineStart: Int?
                var lastMatchedLineStart: Int?
                var foldedLiteral: [UInt8] = []
                var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
                if fastPath.caseInsensitiveASCII {
                    foldedLiteral = literal.map(asciiLowercase)
                    if literal.count > 1 {
                        for index in 0..<(foldedLiteral.count - 1) {
                            caseInsensitiveShifts[Int(foldedLiteral[index])] = literal.count - 1 - index
                        }
                    }
                }
                while searchOffset < data.count, matchedLineCount < maxCount {
                    let foundPointer: UnsafePointer<UInt8>?
                    if fastPath.caseInsensitiveASCII {
                        foundPointer = foldedLiteral.withUnsafeBufferPointer { foldedNeedle in
                            caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                                rg_memcasemem_ascii_prepared(
                                    baseAddress.advanced(by: searchOffset),
                                    data.count - searchOffset,
                                    foldedNeedle.baseAddress,
                                    foldedNeedle.count,
                                    shifts.baseAddress
                                )
                            }
                        }
                    } else {
                        foundPointer = literal.withUnsafeBufferPointer { needle in
                            rg_memmem_simple(
                                baseAddress.advanced(by: searchOffset),
                                data.count - searchOffset,
                                needle.baseAddress,
                                needle.count
                            )
                        }
                    }
                    guard let rawFoundPointer = foundPointer else {
                        break
                    }
                    let matchStart = baseAddress.distance(to: rawFoundPointer)
                    var lineStart = matchStart
                    while lineStart > 0, baseAddress[lineStart - 1] != UInt8(ascii: "\n") {
                        lineStart -= 1
                    }
                    if lastEmittedLineStart != lineStart {
                        let remaining = data.count - matchStart
                        let newlinePointer = memchr(rawFoundPointer, Int32(UInt8(ascii: "\n")), remaining)
                        let lineEnd: Int
                        let outputEnd: Int
                        if let newlinePointer {
                            lineEnd = baseAddress.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
                            outputEnd = lineEnd + 1
                        } else {
                            lineEnd = data.count
                            outputEnd = data.count
                        }
                        if fastPath.wordASCII {
                            switch asciiWordBoundaryState(
                                bytes: byteBuffer,
                                lineStart: lineStart,
                                lineEnd: lineEnd,
                                matchStart: matchStart,
                                matchEnd: matchStart + literal.count
                            ) {
                            case .bounded:
                                break
                            case .notBounded:
                                searchOffset = max(matchStart + 1, searchOffset + 1)
                                continue
                            case .needsDecodedFallback:
                                needsDecodedFallback = true
                                return
                            }
                        }
                        if countMatchesOnly || onlyMatching {
                            totalMatchCount += 1
                            if lastMatchedLineStart != lineStart {
                                matchedLineCount += 1
                                lastMatchedLineStart = lineStart
                            }
                            if onlyMatching {
                                writeBytes(UnsafeRawBufferPointer(
                                    start: rawBaseAddress.advanced(by: matchStart),
                                    count: literal.count
                                ))
                                var newline = UInt8(ascii: "\n")
                                withUnsafeBytes(of: &newline) { buffer in
                                    writeBytes(buffer)
                                }
                            }
                            searchOffset = matchStart + literal.count
                            continue
                        }
                        matchedLineCount += 1
                        lastEmittedLineStart = lineStart
                        if !countOnly {
                            writeLineNumberPrefix(for: lineStart)
                            writeBytes(UnsafeRawBufferPointer(
                                start: rawBaseAddress.advanced(by: lineStart),
                                count: outputEnd - lineStart
                            ))
                            if newlinePointer == nil {
                                var newline = UInt8(ascii: "\n")
                                withUnsafeBytes(of: &newline) { buffer in
                                    writeBytes(buffer)
                                }
                            }
                        }
                        if matchedLineCount == maxCount {
                            bytesSearched = outputEnd
                            break
                        }
                        searchOffset = outputEnd
                        continue
                    }
                    searchOffset = max(matchStart + 1, searchOffset + 1)
                }
                return
            }

            if let byteSet = singleByteLiteralSet(literals) {
                var table = [UInt8](repeating: 0, count: 256)
                byteSet.withUnsafeBufferPointer { needles in
                    rg_byte_set_init(&table, needles.baseAddress, needles.count)
                }

                var searchOffset = 0
                while searchOffset < data.count, matchedLineCount < maxCount {
                    let foundPointer = rg_memchr_any_table(
                        baseAddress.advanced(by: searchOffset),
                        data.count - searchOffset,
                        table
                    )
                    guard let rawFoundPointer = foundPointer else {
                        break
                    }
                    let matchStart = baseAddress.distance(to: rawFoundPointer)
                    var lineStart = matchStart
                    while lineStart > 0, baseAddress[lineStart - 1] != UInt8(ascii: "\n") {
                        lineStart -= 1
                    }
                    let remaining = data.count - matchStart
                    let newlinePointer = memchr(rawFoundPointer, Int32(UInt8(ascii: "\n")), remaining)
                    let outputEnd: Int
                    if let newlinePointer {
                        outputEnd = baseAddress.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self)) + 1
                    } else {
                        outputEnd = data.count
                    }
                    matchedLineCount += 1
                    if !countOnly {
                        writeLineNumberPrefix(for: lineStart)
                        writeBytes(UnsafeRawBufferPointer(
                            start: rawBaseAddress.advanced(by: lineStart),
                            count: outputEnd - lineStart
                        ))
                        if newlinePointer == nil {
                            var newline = UInt8(ascii: "\n")
                            withUnsafeBytes(of: &newline) { buffer in
                                writeBytes(buffer)
                            }
                        }
                    }
                    if matchedLineCount == maxCount {
                        bytesSearched = outputEnd
                        break
                    }
                    searchOffset = outputEnd
                }
                return
            }

            var lineStart = 0
            while lineStart < data.count, matchedLineCount < maxCount {
                let remaining = data.count - lineStart
                let newlinePointer = memchr(baseAddress.advanced(by: lineStart), Int32(UInt8(ascii: "\n")), remaining)
                let lineEnd: Int
                let outputEnd: Int
                if let newlinePointer {
                    lineEnd = baseAddress.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
                    outputEnd = lineEnd + 1
                } else {
                    lineEnd = data.count
                    outputEnd = data.count
                }

                if lineContainsAnyLiteral(
                    baseAddress.advanced(by: lineStart),
                    count: lineEnd - lineStart,
                    literals: literals
                ) {
                    matchedLineCount += 1
                    if !countOnly {
                        writeLineNumberPrefix(for: lineStart)
                        writeBytes(UnsafeRawBufferPointer(
                            start: rawBaseAddress.advanced(by: lineStart),
                            count: outputEnd - lineStart
                        ))
                        if newlinePointer == nil {
                            var newline = UInt8(ascii: "\n")
                            withUnsafeBytes(of: &newline) { buffer in
                                writeBytes(buffer)
                            }
                        }
                    }
                    if matchedLineCount == maxCount {
                        bytesSearched = outputEnd
                        break
                    }
                }

                lineStart = outputEnd
            }
        }
        if needsDecodedFallback {
            return nil
        }
        if countMatchesOnly && totalMatchCount > 0 {
            writeDarwinDecimalLine(totalMatchCount, writeBytes: writeBytes)
        } else if countOnly && matchedLineCount > 0 {
            writeDarwinDecimalLine(matchedLineCount, writeBytes: writeBytes)
        } else if (filesWithMatches && matchedLineCount > 0) || (filesWithoutMatch && matchedLineCount == 0) {
            writeDarwinPathLine(fileURL.path, writeBytes: writeBytes)
        }

        let reportedMatches = totalMatchCount > 0 ? totalMatchCount : matchedLineCount
        let fileResult = SearchFileResult(
            fileURL: fileURL,
            matches: [],
            bytesSearched: bytesSearched,
            searched: true,
            supplementalMatchedLines: matchedLineCount,
            supplementalMatches: reportedMatches
        )
        return SearchResults(
            files: [fileResult],
            summary: SearchSummary(
                filesSearched: 1,
                filesWithMatches: matchedLineCount > 0 ? 1 : 0,
                matchedLines: matchedLineCount,
                totalMatches: reportedMatches
            )
        )
        #endif
    }

    private func singleByteLiteralSet(_ literals: [[UInt8]]) -> [UInt8]? {
        var seen = Set<UInt8>()
        var bytes: [UInt8] = []
        for literal in literals {
            guard literal.count == 1, let byte = literal.first else {
                return nil
            }
            if seen.insert(byte).inserted {
                bytes.append(byte)
            }
        }
        return bytes.isEmpty ? nil : bytes
    }

    private func writeDarwinDecimalLine(_ value: Int, writeBytes: (UnsafeRawBufferPointer) -> Void) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
            var cursor = buffer.count - 1
            buffer[cursor] = UInt8(ascii: "\n")
            var number = value
            repeat {
                cursor -= 1
                buffer[cursor] = UInt8(number % 10) + UInt8(ascii: "0")
                number /= 10
            } while number > 0
            writeBytes(UnsafeRawBufferPointer(
                start: buffer.baseAddress?.advanced(by: cursor),
                count: buffer.count - cursor
            ))
        }
    }

    private func writeDarwinPathLine(_ path: String, writeBytes: (UnsafeRawBufferPointer) -> Void) {
        let bytes = Array(path.utf8) + [UInt8(ascii: "\n")]
        bytes.withUnsafeBytes { buffer in
            writeBytes(buffer)
        }
    }

    private func canWriteDarwinSimpleByteLiteralLines(options: RipgrepOptions) -> Bool {
        guard (options.printMode == .matchingLines
            || options.printMode == .count
            || options.printMode == .countMatches
            || options.printMode == .filesWithMatches
            || options.printMode == .filesWithoutMatch),
              options.rootPathArguments.count == 1,
              options.roots.count == 1,
              !options.useStdin,
              !options.patternFileStdin,
              options.encodingMode == .automatic,
              options.binaryMode == .automatic,
              options.engineMode == .default,
              options.dfaSizeLimit == nil,
              options.regexSizeLimit == nil,
              !options.lineRegexp,
              !options.noUnicode,
              !options.multiline,
              !options.crlf,
              !options.invertMatch,
              !options.stopOnNonmatch,
              (!options.onlyMatching || (options.printMode == .matchingLines && !options.wantsLineNumber && options.maxCount == nil)),
              (options.printMode != .countMatches || options.maxCount == nil),
              options.replacement == nil,
              !options.json,
              !options.stats,
              options.maxColumns == nil,
              !options.maxColumnsPreview,
              options.sortMode == nil,
              !options.byteOffset,
              !options.column,
              options.heading != true,
              !options.trim,
              !options.vimgrep,
              options.colorMode != .always,
              options.colorMode != .ansi,
              options.hyperlinkFormat.isEnabled == false,
              !options.nullPathTerminator,
              options.pathSeparator == nil,
              options.withFilename != true,
              options.globPatterns.isEmpty,
              options.caseInsensitiveGlobPatterns.isEmpty,
              options.preprocessor == nil,
              options.preGlobPatterns.isEmpty,
              !options.searchZip,
              options.typeChanges.isEmpty,
              !options.followSymlinks,
              !options.oneFileSystem,
              options.beforeContext == 0,
              options.afterContext == 0,
              !options.passthru,
              !options.nullData else {
            return false
        }
        return options.effectivePatterns.allSatisfy { !$0.isEmpty }
    }

    private func canWriteDarwinSimpleByteLiteralFastPath(_ fastPath: ByteLiteralFastPath) -> Bool {
        if fastPath.caseInsensitiveASCII {
            return !fastPath.wordASCII && fastPath.literals.count == 1 && fastPath.literals.allSatisfy { literal in
                literal.allSatisfy { $0 < 0x80 }
            }
        }
        if fastPath.wordASCII {
            return fastPath.literals.count == 1 && fastPath.literals.allSatisfy { literal in
                literal.allSatisfy { $0 < 0x80 }
            }
        }
        return fastPath.literals.allSatisfy { $0.count == 1 } || fastPath.literals.count == 1
    }

    private func searchDarwinPlainLiteralNoMatch(
        _ data: Data,
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> SearchFileResult? {
        #if !canImport(Darwin)
        return nil
        #else
        guard case .automatic = options.encodingMode,
              options.binaryMode == .automatic,
              !options.disablesBinaryDetection,
              !data.starts(with: [0xEF, 0xBB, 0xBF]),
              !data.starts(with: [0xFF, 0xFE]),
              !data.starts(with: [0xFE, 0xFF]),
              options.printMode == .matchingLines,
              canOmitMatchSpans(options: options),
              !options.json,
              !options.stats,
              options.beforeContext == 0,
              options.afterContext == 0,
              !options.passthru,
              options.replacement == nil,
              !options.stopOnNonmatch,
              options.maxCount == nil,
              !options.onlyMatching,
              !options.column,
              !options.byteOffset,
              !options.vimgrep,
              !options.crlf,
              options.maxColumns == nil,
              let fastPath = matcher.byteLiteralFastPath(),
              !fastPath.caseInsensitiveASCII,
              !fastPath.wordASCII,
              fastPath.literals.count == 1,
              let literal = fastPath.literals.first,
              !literal.isEmpty else {
            return nil
        }

        return data.withUnsafeBytes { rawBytes -> SearchFileResult? in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return SearchFileResult(fileURL: fileURL, matches: [], bytesSearched: data.count)
            }
            let found = literal.withUnsafeBufferPointer { needle in
                rg_memmem_simple(baseAddress, data.count, needle.baseAddress, needle.count)
            }
            guard found == nil else {
                return nil
            }
            return SearchFileResult(
                fileURL: fileURL,
                matches: [],
                bytesSearched: data.count,
                searched: true
            )
        }
        #endif
    }

    private func lineContainsAnyLiteral(_ line: UnsafePointer<UInt8>, count: Int, literals: [[UInt8]]) -> Bool {
        guard count > 0 else {
            return false
        }
        for literal in literals where literal.count <= count {
            if literal.count == 1 {
                if memchr(line, Int32(literal[0]), count) != nil {
                    return true
                }
            } else {
                let found = literal.withUnsafeBufferPointer { needle in
                    rg_memmem_simple(line, count, needle.baseAddress, needle.count)
                }
                if found != nil {
                    return true
                }
            }
        }
        return false
    }

    private func stdinSearchResults(
        _ data: Data,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> [SearchFileResult] {
        let count = max(1, options.rootPathArguments.filter { $0 == "-" }.count)
        return (0..<count).map { index in
            searchStdin(index == 0 ? data : Data(), matcher: matcher, options: options)
        }
    }

    private func searchHaystacks(
        _ haystacks: [Haystack],
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) throws -> [SearchedHaystack] {
        let workerCount = effectiveWorkerCount(options: options)
        guard workerCount > 1, haystacks.count > 1 else {
            return haystacks.map { haystack in
                let outcome = searchFile(haystack, matcher: matcher, options: options)
                return SearchedHaystack(
                    url: haystack.url,
                    result: outcome.result,
                    message: outcome.message
                )
            }
        }

        let items = haystacks.enumerated().map { index, haystack in
            SearchWorkItem(
                index: index,
                url: haystack.url,
                isExplicit: haystack.isExplicit,
                overridePath: haystack.overridePath,
                fileSize: haystack.fileSize,
                isRegularFile: haystack.isRegularFile
            )
        }
        return try runParallelSearch(items: items, options: options, workerCount: min(workerCount, items.count))
    }

    private func effectiveWorkerCount(options: RipgrepOptions) -> Int {
        if let requested = options.threadCount {
            return requested <= 1 ? 1 : requested
        }
        return max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
    }

    private func runParallelSearch(
        items: [SearchWorkItem],
        options: RipgrepOptions,
        workerCount: Int
    ) throws -> [SearchedHaystack] {
        let semaphore = DispatchSemaphore(value: 0)
        let completion = ParallelSearchCompletion()
        Task {
            do {
                let results = try await searchHaystacksConcurrently(
                    items: items,
                    options: options,
                    workerCount: workerCount
                )
                completion.set(.success(results))
            } catch {
                completion.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try completion.get()
    }

    private func searchHaystacksConcurrently(
        items: [SearchWorkItem],
        options: RipgrepOptions,
        workerCount: Int
    ) async throws -> [SearchedHaystack] {
        let state = ParallelSearchState(items: items)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask { [options] in
                    let matcher = try PatternMatcher(options: options)
                    while let item = await state.next() {
                        let haystack = Haystack(
                            url: item.url,
                            isExplicit: item.isExplicit,
                            overridePath: item.overridePath,
                            fileSize: item.fileSize,
                            isRegularFile: item.isRegularFile
                        )
                        let outcome = searchFile(haystack, matcher: matcher, options: options)
                        await state.store(item, outcome: outcome)
                    }
                }
            }
            try await group.waitForAll()
        }
        return await state.orderedResults()
    }

    private func isRootMatch(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if path == rootPath {
            return true
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        return path.hasPrefix(prefix)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func compare(_ lhs: URL, _ rhs: URL, by kind: SortKind) -> ComparisonResult {
        switch kind {
        case .path:
            return comparePaths(lhs, rhs)
        case .modified:
            return compareDates(lhs, rhs, key: .contentModificationDateKey)
        case .accessed:
            return compareDates(lhs, rhs, key: .contentAccessDateKey)
        case .created:
            return compareDates(lhs, rhs, key: .creationDateKey)
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

    private func searchFile(
        _ haystack: Haystack,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> FileSearchOutcome {
        let fileURL = haystack.url

        func isBufferedLimitError(_ error: Error) -> Bool {
            guard case HaystackReader.ReaderError.bufferLimitExceeded = error else {
                return false
            }
            return true
        }

        func shouldSurfaceReadError(_ error: Error) -> Bool {
            options.mmapMode == .always || isBufferedLimitError(error)
        }

        func canStreamLineByLine() -> Bool {
            guard !shouldPreprocess(haystack, options: options),
                  decompressionCommand(for: fileURL, options: options) == nil,
                  (try? HaystackReader.selectedPath(forFileAt: fileURL, options: options)) == .buffered,
                  !options.multiline,
                  !options.nullData,
                  !options.json,
                  options.beforeContext == 0,
                  options.afterContext == 0,
                  !options.passthru,
                  !options.invertMatch,
                  !options.stopOnNonmatch,
                  options.replacement == nil,
                  !matcher.usesByteSemantics else {
                return false
            }
            guard case .automatic = options.encodingMode else {
                return false
            }
            return !options.effectivePatterns.contains { pattern in
                pattern.contains("$")
                    || pattern.contains(#"\A"#)
                    || pattern.contains(#"\z"#)
                    || pattern.contains(#"\Z"#)
            }
        }

        func streamedSearchOutcome() throws -> FileSearchOutcome? {
            guard canStreamLineByLine() else {
                return nil
            }

            var matches: [SearchMatch] = []
            var totalBytes = 0
            var lineNumber = 0
            var supplementalMatchedLines = 0
            var supplementalMatches = 0
            var fellBackToBufferedSearch = false
            let maxCount = options.maxCount ?? Int.max
            let countOnly = options.printMode == .count
                && !options.stats
                && options.maxCount == nil
                && !options.onlyMatching
                && !options.wordRegexp
                && !options.lineRegexp
                && !options.column
                && !options.byteOffset
            let streamByteFastPath = streamingByteLiteralFastPath(matcher: matcher, options: options)
            if streamByteFastPath != nil,
               canUseBufferedRawLiteralSearch(fileURL: fileURL) {
                return nil
            }
            if matcher.byteRequiredLiteralPrefilter() != nil,
               canUseBufferedRawLiteralSearch(fileURL: fileURL) {
                return nil
            }

            try HaystackReader.streamLines(haystack, options: options) { streamedLine, terminate in
                lineNumber += 1
                var lineData = streamedLine.data
                lineData.append(streamedLine.terminator)
                totalBytes = streamedLine.absoluteOffset + lineData.count

                if streamedLine.absoluteOffset == 0,
                   lineData.starts(with: [0xEF, 0xBB, 0xBF])
                    || lineData.starts(with: [0xFF, 0xFE])
                    || lineData.starts(with: [0xFE, 0xFF]) {
                    fellBackToBufferedSearch = true
                    terminate = true
                    return
                }
                if !options.disablesBinaryDetection,
                   shouldCheckBinary(lineData, options: options),
                   lineData.contains(0) {
                    fellBackToBufferedSearch = true
                    terminate = true
                    return
                }
                if let streamByteFastPath {
                    let lineBytes = [UInt8](streamedLine.data)
                    if options.printMode == .matchingLines,
                       canOmitMatchSpans(options: options) {
                        let scan = byteLiteralLineMatch(
                            fastPath: streamByteFastPath,
                            bytes: lineBytes,
                            lineStart: 0,
                            lineEnd: lineBytes.count
                        )
                        if scan.needsDecodedFallback {
                            guard let lineText = String(data: streamedLine.data, encoding: .utf8) else {
                                fellBackToBufferedSearch = true
                                terminate = true
                                return
                            }
                            let spans = decodedLiteralFallbackSpans(
                                matcher: matcher,
                                options: options,
                                line: lineText
                            )
                            guard !spans.isEmpty else {
                                return
                            }
                            appendStreamingMatch(
                                lineText: lineText,
                                lineBytes: lineBytes,
                                terminator: streamedLine.terminator,
                                absoluteOffset: streamedLine.absoluteOffset,
                                lineNumber: lineNumber,
                                spans: spans,
                                fileURL: fileURL,
                                matches: &matches
                            )
                        } else {
                            guard scan.hasMatch else {
                                return
                            }
                            guard let lineText = String(data: streamedLine.data, encoding: .utf8) else {
                                fellBackToBufferedSearch = true
                                terminate = true
                                return
                            }
                            let lineTerminator = String(data: streamedLine.terminator, encoding: .utf8) ?? ""
                            matches.append(SearchMatch(
                                fileURL: fileURL,
                                lineNumber: lineNumber,
                                column: nil,
                                line: lineText,
                                lineTerminator: lineTerminator,
                                absoluteOffset: streamedLine.absoluteOffset,
                                matchCount: 1,
                                spans: []
                            ))
                        }
                        if matches.count >= maxCount {
                            terminate = true
                        }
                        return
                    }
                    let scan = byteLiteralSpans(
                        fastPath: streamByteFastPath,
                        bytes: lineBytes,
                        lineStart: 0,
                        lineEnd: lineBytes.count
                    )
                    let spans: [MatchSpan]
                    var decodedLine: String?
                    if scan.needsDecodedFallback {
                        guard let lineText = String(data: streamedLine.data, encoding: .utf8) else {
                            fellBackToBufferedSearch = true
                            terminate = true
                            return
                        }
                        decodedLine = lineText
                        spans = decodedLiteralFallbackSpans(
                            matcher: matcher,
                            options: options,
                            line: lineText
                        )
                    } else {
                        spans = scan.spans
                    }
                    guard !spans.isEmpty else {
                        return
                    }
                    switch options.printMode {
                    case .count:
                        supplementalMatchedLines += 1
                        return
                    case .countMatches:
                        supplementalMatches += spans.count
                        return
                    case .filesWithMatches, .filesWithoutMatch:
                        matches.append(SearchMatch(
                            fileURL: fileURL,
                            lineNumber: lineNumber,
                            column: nil,
                            line: "",
                            lineTerminator: "",
                            absoluteOffset: streamedLine.absoluteOffset,
                            matchCount: spans.count,
                            spans: []
                        ))
                        terminate = true
                        return
                    case .matchingLines:
                        let lineText: String
                        if let decodedLine {
                            lineText = decodedLine
                        } else {
                            guard let decoded = String(data: streamedLine.data, encoding: .utf8) else {
                                fellBackToBufferedSearch = true
                                terminate = true
                                return
                            }
                            lineText = decoded
                        }
                        let lineTerminator = String(data: streamedLine.terminator, encoding: .utf8) ?? ""
                        matches.append(SearchMatch(
                            fileURL: fileURL,
                            lineNumber: lineNumber,
                            column: nil,
                            line: lineText,
                            lineTerminator: lineTerminator,
                            absoluteOffset: streamedLine.absoluteOffset,
                            matchCount: spans.count,
                            spans: spans.map { span in
                                let textBytes = lineBytes[span.startByte..<span.endByte]
                                return MatchSpan(
                                    startColumn: span.startByte + 1,
                                    endColumn: span.endByte + 1,
                                    startByte: span.startByte,
                                    endByte: span.endByte,
                                    text: String(decoding: textBytes, as: UTF8.self)
                                )
                            }
                        ))
                        if matches.count >= maxCount {
                            terminate = true
                        }
                        return
                    }
                }
                guard let lineText = String(data: lineData, encoding: .utf8) else {
                    fellBackToBufferedSearch = true
                    terminate = true
                    return
                }

                if countOnly {
                    if !matcher.canFastReject(lineText),
                       matcher.hasPositiveMatch(in: lineText) {
                        supplementalMatchedLines += 1
                    }
                    return
                }

                var lineOptions = options
                if options.maxCount != nil {
                    lineOptions.maxCount = max(0, maxCount - matches.count)
                }
                let lineResult = searchContents(
                    lineText,
                    fileURL: fileURL,
                    matcher: matcher,
                    options: lineOptions,
                    splitBinaryNUL: false
                )
                matches.append(contentsOf: lineResult.matches.map { match in
                    SearchMatch(
                        fileURL: match.fileURL,
                        lineNumber: lineNumber + match.lineNumber - 1,
                        column: match.column,
                        line: match.line,
                        rawLine: match.rawLine,
                        lineTerminator: match.lineTerminator,
                        absoluteOffset: streamedLine.absoluteOffset + match.absoluteOffset,
                        matchCount: match.matchCount,
                        spans: match.spans
                    )
                })
                supplementalMatchedLines += lineResult.supplementalMatchedLines
                supplementalMatches += lineResult.supplementalMatches
                if matches.count >= maxCount {
                    terminate = true
                }
            }

            guard !fellBackToBufferedSearch else {
                return nil
            }
            return FileSearchOutcome(result: SearchFileResult(
                fileURL: fileURL,
                matches: matches,
                bytesSearched: totalBytes,
                searched: true,
                supplementalMatchedLines: supplementalMatchedLines,
                supplementalMatches: supplementalMatches
            ))
        }

        do {
            if let streamed = try streamedSearchOutcome() {
                return streamed
            }
        } catch {
            if shouldSurfaceReadError(error) {
                return FileSearchOutcome(
                    result: SearchFileResult(fileURL: fileURL, matches: [], searched: false),
                    message: String(describing: error)
                )
            }
        }

        let data: Data
        do {
            data = try HaystackReader.read(haystack, options: options)
        } catch {
            let message = shouldSurfaceReadError(error) ? String(describing: error) : nil
            return FileSearchOutcome(
                result: SearchFileResult(fileURL: fileURL, matches: [], searched: false),
                message: message
            )
        }

        if shouldPreprocess(haystack, options: options) {
            return searchPreprocessedFile(
                haystack,
                originalData: data,
                matcher: matcher,
                options: options
            )
        }
        if let decompressionCommand = decompressionCommand(for: fileURL, options: options) {
            return searchDecompressedFile(
                fileURL,
                command: decompressionCommand,
                matcher: matcher,
                options: options,
                isExplicit: haystack.isExplicit
            )
        }

        if let noMatchResult = searchDarwinPlainLiteralNoMatch(
            data,
            fileURL: fileURL,
            matcher: matcher,
            options: options
        ) {
            return FileSearchOutcome(result: noMatchResult)
        }

        let binaryByteOffset = shouldCheckBinary(data, options: options) ? firstNulByteOffset(in: data) : nil
        if let binaryByteOffset, !options.disablesBinaryDetection {
            let contents = decode(data, options: options)
            let result = searchContents(
                contents,
                rawData: rawDataForOutput(data, options: options, matcher: matcher),
                rawDataForMatching: rawDataForMatching(data, options: options, matcher: matcher),
                fileURL: fileURL,
                matcher: matcher,
                options: options,
                splitBinaryNUL: true
            )
            let binaryDetectedBeforeSearch = binaryByteOffset < Self.binaryDetectionBufferSize
            let visibleMatches = binaryDetectedBeforeSearch && !haystack.isExplicit
                ? []
                : binaryVisibleMatches(
                    result.matches,
                    binaryByteOffset: binaryByteOffset,
                    options: options,
                    isExplicit: haystack.isExplicit
                )
            let emittedMatches = shouldEmitSuppressedBinaryMatches(options, isExplicit: haystack.isExplicit)
                ? result.matches
                : visibleMatches
            let statsMatches = matchesBeforeBinaryByte(
                result.matches,
                binaryByteOffset: binaryByteOffset,
                options: options
            )
            let lineNumberShifts = jsonBinaryLineNumberShifts(for: result.lines, options: options)
            var displayMatches = options.json
                ? jsonBinaryDisplayMatches(emittedMatches, lineNumberShifts: lineNumberShifts, options: options)
                : emittedMatches
            let hasBinaryMatch = hasBinaryMatchResult(
                result: result,
                visibleMatches: visibleMatches,
                binaryByteOffset: binaryByteOffset,
                options: options
            )
            if shouldDropSuppressedBinaryContextMatches(hasBinaryMatch: hasBinaryMatch, options: options) {
                displayMatches = []
            }
            let suppressBinaryMatchDetails = options.binaryMode == .automatic
                && options.printMode == .matchingLines
                && !options.json
                && !(options.quiet && options.stats)
                && options.replacement != nil
                && hasBinaryMatch
                && binaryDetectedBeforeSearch
            if suppressBinaryMatchDetails {
                displayMatches = []
            }
            let displayLines: [SearchLine]
            if options.json {
                displayLines = jsonBinaryDisplayLines(result.lines, lineNumberShifts: lineNumberShifts, options: options)
            } else {
                displayLines = hasBinaryMatch ? result.lines : []
            }
            if options.binaryMode == .automatic && !haystack.isExplicit && binaryDetectedBeforeSearch {
                return FileSearchOutcome(result: SearchFileResult(
                    fileURL: fileURL,
                    matches: [],
                    binaryByteOffset: binaryByteOffset,
                    stoppedBinaryAfterMatch: true,
                    searched: true
                ))
            }
            if options.binaryMode == .automatic && !haystack.isExplicit && visibleMatches.isEmpty {
                return FileSearchOutcome(result: SearchFileResult(fileURL: fileURL, matches: [], searched: false))
            }
            return FileSearchOutcome(result: SearchFileResult(
                fileURL: fileURL,
                matches: displayMatches,
                lines: displayLines,
                binaryByteOffset: binaryByteOffset,
                hasBinaryMatch: hasBinaryMatch,
                stoppedBinaryAfterMatch: options.binaryMode == .automatic && !haystack.isExplicit,
                bytesSearched: suppressedBinaryBytesSearched(
                    dataCount: data.count,
                    binaryByteOffset: binaryByteOffset,
                    searchedMatches: result.matches,
                    visibleMatches: visibleMatches,
                    options: options
                ),
                supplementalMatchedLines: suppressBinaryMatchDetails
                    ? 0
                    : result.supplementalMatchedLines + binarySupplementalMatchedLines(
                        statsMatches: statsMatches,
                        displayMatches: displayMatches,
                        hasBinaryMatch: hasBinaryMatch,
                        options: options
                    ),
                supplementalMatches: suppressBinaryMatchDetails
                    ? 0
                    : result.supplementalMatches + binarySupplementalMatches(
                        statsMatches: statsMatches,
                        displayMatches: displayMatches,
                        hasBinaryMatch: hasBinaryMatch
                    )
            ))
        }

        if let fastResult = searchRawLiteralContents(
            data,
            fileURL: fileURL,
            matcher: matcher,
            options: options
        ) {
            return FileSearchOutcome(result: fastResult)
        }
        if let fastResult = searchRawRegexPrefilterContents(
            data,
            fileURL: fileURL,
            matcher: matcher,
            options: options
        ) {
            return FileSearchOutcome(result: fastResult)
        }

        let contents = decode(data, options: options)
        let result = searchContents(
            contents,
            rawData: rawDataForOutput(data, options: options, matcher: matcher),
            rawDataForMatching: rawDataForMatching(data, options: options, matcher: matcher),
            fileURL: fileURL,
            matcher: matcher,
            options: options,
            splitBinaryNUL: true
        )
        return FileSearchOutcome(result: SearchFileResult(
            fileURL: result.fileURL,
            matches: result.matches,
            lines: result.lines,
            bytesSearched: result.bytesSearched,
            searched: result.searched,
            supplementalMatchedLines: result.supplementalMatchedLines,
            supplementalMatches: result.supplementalMatches
        ))
    }

    private func searchRawLiteralContents(
        _ data: Data,
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> SearchFileResult? {
        #if !canImport(Darwin)
        return nil
        #else
        guard case .automatic = options.encodingMode,
              !data.starts(with: [0xEF, 0xBB, 0xBF]),
              !data.starts(with: [0xFF, 0xFE]),
              !data.starts(with: [0xFE, 0xFF]),
              !options.json,
              !options.stats,
              options.beforeContext == 0,
              options.afterContext == 0,
              !options.passthru,
              options.replacement == nil,
              !options.stopOnNonmatch,
              options.maxCount == nil,
              !options.onlyMatching,
              !options.column,
              !options.byteOffset,
              !options.vimgrep,
              !options.crlf,
              options.maxColumns == nil,
              let fastPath = matcher.byteLiteralFastPath() else {
            return nil
        }

        var matches: [SearchMatch] = []
        var supplementalMatchedLines = 0
        var supplementalMatches = 0
        var lineStart = 0
        var lineNumber = 1
        var bytesSearchedThroughMaxCount: Int?
        var failedDecode = false
        let maxCount = options.maxCount ?? Int.max
        let dataCount = data.count
        let result = data.withUnsafeBytes { rawBytes -> SearchFileResult? in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return SearchFileResult(fileURL: fileURL, matches: [], bytesSearched: data.count)
            }
            if options.printMode == .matchingLines,
               canOmitMatchSpans(options: options),
               fastPath.caseInsensitiveASCII,
               !fastPath.wordASCII,
               fastPath.literals.count == 1,
               let literal = fastPath.literals.first,
               !literal.isEmpty,
               !literal.contains(where: isNonASCII) {
                if let literalResult = searchDarwinCaseInsensitiveLiteralLines(
                    data: data,
                    fileURL: fileURL,
                    bytes: bytes,
                    baseAddress: baseAddress,
                    literal: literal,
                    maxCount: maxCount
                ) {
                    return literalResult
                }
            }
            if options.printMode == .matchingLines,
               canOmitMatchSpans(options: options),
               !fastPath.caseInsensitiveASCII,
               fastPath.literals.count == 1,
               let literal = fastPath.literals.first,
               !literal.isEmpty {
                if let literalResult = searchDarwinPlainLiteralLines(
                    data: data,
                    fileURL: fileURL,
                    bytes: bytes,
                    baseAddress: baseAddress,
                    literal: literal,
                    maxCount: maxCount,
                    requiresWordBoundary: fastPath.wordASCII
                ) {
                    return literalResult
                }
            }
            if options.printMode == .matchingLines,
               canOmitMatchSpans(options: options),
               !fastPath.caseInsensitiveASCII {
                let wholeFileMatch = byteLiteralWholeFileMatch(
                    fastPath: fastPath,
                    bytes: bytes,
                    lineEnd: dataCount
                )
                if !wholeFileMatch.needsDecodedFallback, !wholeFileMatch.hasMatch {
                    return SearchFileResult(
                        fileURL: fileURL,
                        matches: [],
                        bytesSearched: data.count,
                        searched: true
                    )
                }
            }

            func scanLine(end lineEnd: Int, terminator: String) -> Bool {
                if options.printMode == .matchingLines,
                   canOmitMatchSpans(options: options) {
                    let scan = byteLiteralLineMatch(
                        fastPath: fastPath,
                        bytes: bytes,
                        lineStart: lineStart,
                        lineEnd: lineEnd
                    )
                    if scan.needsDecodedFallback {
                        guard let decodedLine = String(
                            data: Data(bytes: baseAddress.advanced(by: lineStart), count: lineEnd - lineStart),
                            encoding: .utf8
                        ) else {
                            failedDecode = true
                            return true
                        }
                        let fallbackSpans = decodedLiteralFallbackSpans(
                            matcher: matcher,
                            options: options,
                            line: decodedLine
                        )
                        return emitLine(spans: fallbackSpans, line: decodedLine, lineEnd: lineEnd, terminator: terminator)
                    }
                    guard scan.hasMatch else {
                        return false
                    }
                    return emitPlainLineMatch(line: nil, lineEnd: lineEnd, terminator: terminator)
                }
                let scan = byteLiteralSpans(
                    fastPath: fastPath,
                    bytes: bytes,
                    lineStart: lineStart,
                    lineEnd: lineEnd
                )
                if scan.needsDecodedFallback {
                    guard let decodedLine = String(
                        data: Data(bytes: baseAddress.advanced(by: lineStart), count: lineEnd - lineStart),
                        encoding: .utf8
                    ) else {
                        failedDecode = true
                        return true
                    }
                    let fallbackSpans = decodedLiteralFallbackSpans(
                        matcher: matcher,
                        options: options,
                        line: decodedLine
                    )
                    return emitLine(spans: fallbackSpans, line: decodedLine, lineEnd: lineEnd, terminator: terminator)
                }
                let spans = scan.spans
                return emitLine(spans: spans, line: nil, lineEnd: lineEnd, terminator: terminator)
            }

            func emitPlainLineMatch(line decodedLine: String?, lineEnd: Int, terminator: String) -> Bool {
                guard matches.count < maxCount else {
                    return true
                }
                let line: String
                if let decodedLine {
                    line = decodedLine
                } else {
                    let lineData = Data(
                        bytes: baseAddress.advanced(by: lineStart),
                        count: lineEnd - lineStart
                    )
                    guard let decoded = String(data: lineData, encoding: .utf8) else {
                        failedDecode = true
                        return true
                    }
                    line = decoded
                }
                matches.append(SearchMatch(
                    fileURL: fileURL,
                    lineNumber: lineNumber,
                    column: nil,
                    line: line,
                    lineTerminator: terminator,
                    absoluteOffset: lineStart,
                    matchCount: 1,
                    spans: []
                ))
                if matches.count == maxCount {
                    bytesSearchedThroughMaxCount = lineEnd + terminator.utf8.count
                    return true
                }
                return false
            }

            func emitLine(spans: [MatchSpan], line decodedLine: String?, lineEnd: Int, terminator: String) -> Bool {
                guard !spans.isEmpty else {
                    return false
                }

                switch options.printMode {
                case .count:
                    supplementalMatchedLines += 1
                    return false
                case .countMatches:
                    supplementalMatches += spans.count
                    return false
                case .filesWithMatches:
                    matches.append(SearchMatch(
                        fileURL: fileURL,
                        lineNumber: lineNumber,
                        column: nil,
                        line: "",
                        lineTerminator: "",
                        absoluteOffset: lineStart,
                        matchCount: spans.count,
                        spans: []
                    ))
                    return true
                case .filesWithoutMatch:
                    matches.append(SearchMatch(
                        fileURL: fileURL,
                        lineNumber: lineNumber,
                        column: nil,
                        line: "",
                        lineTerminator: "",
                        absoluteOffset: lineStart,
                        matchCount: spans.count,
                        spans: []
                    ))
                    return true
                case .matchingLines:
                    guard matches.count < maxCount else {
                        return true
                    }
                    let line: String
                    if let decodedLine {
                        line = decodedLine
                    } else {
                        let lineData = Data(
                            bytes: baseAddress.advanced(by: lineStart),
                            count: lineEnd - lineStart
                        )
                        guard let decoded = String(data: lineData, encoding: .utf8) else {
                            failedDecode = true
                            return true
                        }
                        line = decoded
                    }
                    matches.append(SearchMatch(
                        fileURL: fileURL,
                        lineNumber: lineNumber,
                        column: nil,
                        line: line,
                        lineTerminator: terminator,
                        absoluteOffset: lineStart,
                        matchCount: spans.count,
                        spans: spans.map { span in
                            let start = lineStart + span.startByte
                            let count = span.endByte - span.startByte
                            let textBytes = UnsafeBufferPointer(
                                start: baseAddress.advanced(by: start),
                                count: count
                            )
                            return MatchSpan(
                                startColumn: span.startByte + 1,
                                endColumn: span.endByte + 1,
                                startByte: span.startByte,
                                endByte: span.endByte,
                                text: String(decoding: textBytes, as: UTF8.self)
                            )
                        }
                    ))
                    if matches.count == maxCount {
                        bytesSearchedThroughMaxCount = lineEnd + terminator.utf8.count
                        return true
                    }
                    return false
                }
            }

            var index = 0
            while index < dataCount {
                if bytes[index] == UInt8(ascii: "\n") {
                    if scanLine(end: index, terminator: "\n") {
                        break
                    }
                    index += 1
                    lineStart = index
                    lineNumber += 1
                    continue
                }
                index += 1
            }
            if lineStart < dataCount || data.last != UInt8(ascii: "\n") {
                _ = scanLine(end: dataCount, terminator: "")
            }
            if failedDecode {
                return nil
            }

            return SearchFileResult(
                fileURL: fileURL,
                matches: matches,
                bytesSearched: bytesSearchedThroughMaxCount ?? data.count,
                searched: true,
                supplementalMatchedLines: supplementalMatchedLines,
                supplementalMatches: supplementalMatches
            )
        }
        return result
        #endif
    }

    private func searchRawRegexPrefilterContents(
        _ data: Data,
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> SearchFileResult? {
        #if !canImport(Darwin)
        return nil
        #else
        guard case .automatic = options.encodingMode,
              !data.starts(with: [0xEF, 0xBB, 0xBF]),
              !data.starts(with: [0xFF, 0xFE]),
              !data.starts(with: [0xFE, 0xFF]),
              !options.json,
              !options.stats,
              options.beforeContext == 0,
              options.afterContext == 0,
              !options.passthru,
              options.replacement == nil,
              !options.stopOnNonmatch,
              options.maxCount == nil,
              !options.onlyMatching,
              !options.column,
              !options.byteOffset,
              !options.vimgrep,
              !options.crlf,
              options.maxColumns == nil else {
            return nil
        }
        if let fastResult = searchDarwinSurroundingWordsContents(
            data,
            fileURL: fileURL,
            matcher: matcher,
            options: options
        ) {
            return fastResult
        }
        guard let prefilter = matcher.byteRequiredLiteralPrefilter() else {
            return nil
        }
        if let fastResult = searchDarwinRegexRequiredLiteralContents(
            data,
            fileURL: fileURL,
            matcher: matcher,
            options: options,
            prefilter: prefilter
        ) {
            return fastResult
        }

        var matches: [SearchMatch] = []
        var supplementalMatchedLines = 0
        var supplementalMatches = 0
        var lineStart = 0
        var lineNumber = 1
        var failedDecode = false
        let dataCount = data.count

        let result = data.withUnsafeBytes { rawBytes -> SearchFileResult? in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return SearchFileResult(fileURL: fileURL, matches: [], bytesSearched: data.count)
            }

            func scanLine(end lineEnd: Int, terminator: String) -> Bool {
                let scan = byteLiteralLineMatch(
                    fastPath: prefilter,
                    bytes: bytes,
                    lineStart: lineStart,
                    lineEnd: lineEnd
                )
                guard scan.hasMatch else {
                    return false
                }
                let lineData = Data(bytes: baseAddress.advanced(by: lineStart), count: lineEnd - lineStart)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    failedDecode = true
                    return true
                }
                let spans = decodedLiteralFallbackSpans(matcher: matcher, options: options, line: line)
                guard !spans.isEmpty else {
                    return false
                }

                switch options.printMode {
                case .count:
                    supplementalMatchedLines += 1
                case .countMatches:
                    supplementalMatches += spans.count
                case .filesWithMatches, .filesWithoutMatch:
                    matches.append(SearchMatch(
                        fileURL: fileURL,
                        lineNumber: lineNumber,
                        column: nil,
                        line: "",
                        lineTerminator: "",
                        absoluteOffset: lineStart,
                        matchCount: spans.count,
                        spans: []
                    ))
                    return true
                case .matchingLines:
                    matches.append(SearchMatch(
                        fileURL: fileURL,
                        lineNumber: lineNumber,
                        column: nil,
                        line: line,
                        lineTerminator: terminator,
                        absoluteOffset: lineStart,
                        matchCount: spans.count,
                        spans: spans.map { span in
                            let start = lineStart + span.startByte
                            let count = span.endByte - span.startByte
                            let textBytes = UnsafeBufferPointer(
                                start: baseAddress.advanced(by: start),
                                count: count
                            )
                            return MatchSpan(
                                startColumn: span.startByte + 1,
                                endColumn: span.endByte + 1,
                                startByte: span.startByte,
                                endByte: span.endByte,
                                text: String(decoding: textBytes, as: UTF8.self)
                            )
                        }
                    ))
                }
                return false
            }

            var index = 0
            while index < dataCount {
                if bytes[index] == UInt8(ascii: "\n") {
                    if scanLine(end: index, terminator: "\n") {
                        break
                    }
                    index += 1
                    lineStart = index
                    lineNumber += 1
                    continue
                }
                index += 1
            }
            if lineStart < dataCount || data.last != UInt8(ascii: "\n") {
                _ = scanLine(end: dataCount, terminator: "")
            }
            if failedDecode {
                return nil
            }

            return SearchFileResult(
                fileURL: fileURL,
                matches: matches,
                bytesSearched: data.count,
                searched: true,
                supplementalMatchedLines: supplementalMatchedLines,
                supplementalMatches: supplementalMatches
            )
        }
        return result
        #endif
    }

    private func searchDarwinSurroundingWordsContents(
        _ data: Data,
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> SearchFileResult? {
        #if !canImport(Darwin)
        return nil
        #else
        guard options.printMode == .matchingLines,
              options.heading != true,
              canOmitMatchSpans(options: options),
              let literal = surroundingWordsLiteralPattern(options: options) else {
            return nil
        }

        var matches: [SearchMatch] = []
        let dataCount = data.count
        var failedDecode = false

        let result = data.withUnsafeBytes { rawBytes -> SearchFileResult? in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return SearchFileResult(fileURL: fileURL, matches: [], bytesSearched: data.count)
            }

            var searchOffset = 0
            var lastMatchedLineStart: Int?
            var lineNumber = 1
            var lineCountOffset = 0

            func advanceLineNumber(to targetOffset: Int) {
                guard lineCountOffset < targetOffset else {
                    return
                }
                lineNumber += Int(rg_memcount_byte(
                    baseAddress.advanced(by: lineCountOffset),
                    targetOffset - lineCountOffset,
                    UInt8(ascii: "\n")
                ))
                lineCountOffset = targetOffset
            }

            while searchOffset < dataCount {
                let foundPointer = literal.withUnsafeBufferPointer { needle in
                    rg_memmem_simple(
                        baseAddress.advanced(by: searchOffset),
                        dataCount - searchOffset,
                        needle.baseAddress,
                        needle.count
                    )
                }
                guard let rawFoundPointer = foundPointer else {
                    break
                }

                let matchStart = baseAddress.distance(to: rawFoundPointer)
                var lineStart = matchStart
                while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") {
                    lineStart -= 1
                }
                if lastMatchedLineStart == lineStart {
                    searchOffset = max(matchStart + 1, searchOffset + 1)
                    continue
                }

                let newlinePointer = memchr(
                    rawFoundPointer,
                    Int32(UInt8(ascii: "\n")),
                    dataCount - matchStart
                )
                let lineEnd: Int
                let terminator: String
                if let newlinePointer {
                    lineEnd = baseAddress.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
                    terminator = "\n"
                } else {
                    lineEnd = dataCount
                    terminator = ""
                }

                var matched = asciiSurroundingWordsMatch(
                    bytes: bytes,
                    lineStart: lineStart,
                    lineEnd: lineEnd,
                    literalStart: matchStart,
                    literalEnd: matchStart + literal.count
                )
                if !matched && lineContainsNonASCII(bytes: bytes, lineStart: lineStart, lineEnd: lineEnd) {
                    guard let line = utf8LineString(
                        baseAddress: baseAddress,
                        lineStart: lineStart,
                        lineEnd: lineEnd
                    ) else {
                        failedDecode = true
                        break
                    }
                    matched = !decodedLiteralFallbackSpans(matcher: matcher, options: options, line: line).isEmpty
                }

                if matched {
                    lastMatchedLineStart = lineStart
                    guard let line = utf8LineString(
                        baseAddress: baseAddress,
                        lineStart: lineStart,
                        lineEnd: lineEnd
                    ) else {
                        failedDecode = true
                        break
                    }
                    advanceLineNumber(to: lineStart)
                    matches.append(SearchMatch(
                        fileURL: fileURL,
                        lineNumber: lineNumber,
                        column: nil,
                        line: line,
                        lineTerminator: terminator,
                        absoluteOffset: lineStart,
                        matchCount: 1,
                        spans: []
                    ))
                    searchOffset = newlinePointer == nil ? dataCount : lineEnd + 1
                    continue
                }
                searchOffset = max(matchStart + 1, searchOffset + 1)
            }

            guard !failedDecode else {
                return nil
            }
            return SearchFileResult(
                fileURL: fileURL,
                matches: matches,
                bytesSearched: data.count,
                searched: true
            )
        }
        return result
        #endif
    }

    private func searchDarwinRegexRequiredLiteralContents(
        _ data: Data,
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions,
        prefilter: ByteLiteralFastPath
    ) -> SearchFileResult? {
        #if !canImport(Darwin)
        return nil
        #else
        guard options.printMode == .matchingLines,
              options.heading != true,
              !prefilter.caseInsensitiveASCII,
              !prefilter.wordASCII,
              prefilter.literals.count == 1,
              let literal = prefilter.literals.first,
              !literal.isEmpty else {
            return nil
        }

        var matches: [SearchMatch] = []
        let dataCount = data.count
        var failedDecode = false

        let result = data.withUnsafeBytes { rawBytes -> SearchFileResult? in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return SearchFileResult(fileURL: fileURL, matches: [], bytesSearched: data.count)
            }

            var searchOffset = 0
            var lastCandidateLineStart: Int?
            var lineNumber = 1
            var lineCountOffset = 0

            func advanceLineNumber(to targetOffset: Int) {
                guard options.wantsLineNumber, lineCountOffset < targetOffset else {
                    return
                }
                lineNumber += Int(rg_memcount_byte(
                    baseAddress.advanced(by: lineCountOffset),
                    targetOffset - lineCountOffset,
                    UInt8(ascii: "\n")
                ))
                lineCountOffset = targetOffset
            }

            while searchOffset < dataCount {
                let foundPointer = literal.withUnsafeBufferPointer { needle in
                    rg_memmem_simple(
                        baseAddress.advanced(by: searchOffset),
                        dataCount - searchOffset,
                        needle.baseAddress,
                        needle.count
                    )
                }
                guard let rawFoundPointer = foundPointer else {
                    break
                }
                let matchStart = baseAddress.distance(to: rawFoundPointer)
                var lineStart = matchStart
                while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") {
                    lineStart -= 1
                }
                if lastCandidateLineStart == lineStart {
                    searchOffset = max(matchStart + 1, searchOffset + 1)
                    continue
                }
                lastCandidateLineStart = lineStart

                let newlinePointer = memchr(
                    rawFoundPointer,
                    Int32(UInt8(ascii: "\n")),
                    dataCount - matchStart
                )
                let lineEnd: Int
                let terminator: String
                if let newlinePointer {
                    lineEnd = baseAddress.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
                    terminator = "\n"
                } else {
                    lineEnd = dataCount
                    terminator = ""
                }
                guard let line = utf8LineString(
                    baseAddress: baseAddress,
                    lineStart: lineStart,
                    lineEnd: lineEnd
                ) else {
                    failedDecode = true
                    break
                }
                let spans = decodedLiteralFallbackSpans(matcher: matcher, options: options, line: line)
                if !spans.isEmpty {
                    advanceLineNumber(to: lineStart)
                    matches.append(SearchMatch(
                        fileURL: fileURL,
                        lineNumber: lineNumber,
                        column: nil,
                        line: line,
                        lineTerminator: terminator,
                        absoluteOffset: lineStart,
                        matchCount: spans.count,
                        spans: spans.map { span in
                            let start = lineStart + span.startByte
                            let count = span.endByte - span.startByte
                            let textBytes = UnsafeBufferPointer(
                                start: baseAddress.advanced(by: start),
                                count: count
                            )
                            return MatchSpan(
                                startColumn: span.startColumn,
                                endColumn: span.endColumn,
                                startByte: span.startByte,
                                endByte: span.endByte,
                                text: String(decoding: textBytes, as: UTF8.self)
                            )
                        }
                    ))
                }
                searchOffset = newlinePointer == nil ? dataCount : lineEnd + 1
            }

            guard !failedDecode else {
                return nil
            }
            return SearchFileResult(
                fileURL: fileURL,
                matches: matches,
                bytesSearched: data.count,
                searched: true
            )
        }
        return result
        #endif
    }

    private func surroundingWordsLiteralPattern(options: RipgrepOptions) -> [UInt8]? {
        guard !options.effectiveIgnoreCase,
              !options.fixedStrings,
              !options.lineRegexp,
              !options.invertMatch,
              !options.multiline,
              !options.nullData,
              options.effectivePatterns.count == 1,
              var pattern = options.effectivePatterns.first else {
            return nil
        }
        if pattern.hasPrefix("(?-u)") {
            pattern.removeFirst("(?-u)".count)
        }
        let prefix = #"\w+\s+"#
        let suffix = #"\s+\w+"#
        guard pattern.hasPrefix(prefix), pattern.hasSuffix(suffix) else {
            return nil
        }
        let literalStart = pattern.index(pattern.startIndex, offsetBy: prefix.count)
        let literalEnd = pattern.index(pattern.endIndex, offsetBy: -suffix.count)
        let literal = String(pattern[literalStart..<literalEnd])
        guard !literal.isEmpty,
              literal.utf8.allSatisfy({ $0 < 0x80 }),
              !literal.contains(where: { #"\.[]{}()+*?^$|"#.contains($0) }) else {
            return nil
        }
        return Array(literal.utf8)
    }

    private func asciiSurroundingWordsMatch(
        bytes: UnsafeBufferPointer<UInt8>,
        lineStart: Int,
        lineEnd: Int,
        literalStart: Int,
        literalEnd: Int
    ) -> Bool {
        guard literalStart >= lineStart, literalEnd <= lineEnd else {
            return false
        }

        var beforeWhitespaceStart = literalStart
        while beforeWhitespaceStart > lineStart,
              isASCIIWhitespace(bytes[beforeWhitespaceStart - 1]) {
            beforeWhitespaceStart -= 1
        }
        guard beforeWhitespaceStart < literalStart else {
            return false
        }

        var wordStart = beforeWhitespaceStart
        while wordStart > lineStart,
              isASCIIWord(bytes[wordStart - 1]) {
            wordStart -= 1
        }
        guard wordStart < beforeWhitespaceStart else {
            return false
        }

        var afterWhitespaceEnd = literalEnd
        while afterWhitespaceEnd < lineEnd,
              isASCIIWhitespace(bytes[afterWhitespaceEnd]) {
            afterWhitespaceEnd += 1
        }
        guard afterWhitespaceEnd > literalEnd else {
            return false
        }

        var wordEnd = afterWhitespaceEnd
        while wordEnd < lineEnd,
              isASCIIWord(bytes[wordEnd]) {
            wordEnd += 1
        }
        return wordEnd > afterWhitespaceEnd
    }

    private func lineContainsNonASCII(
        bytes: UnsafeBufferPointer<UInt8>,
        lineStart: Int,
        lineEnd: Int
    ) -> Bool {
        guard lineStart < lineEnd else {
            return false
        }
        for index in lineStart..<lineEnd where bytes[index] >= 0x80 {
            return true
        }
        return false
    }

    private func utf8LineString(
        baseAddress: UnsafePointer<UInt8>,
        lineStart: Int,
        lineEnd: Int
    ) -> String? {
        var index = lineStart
        while index < lineEnd {
            if baseAddress[index] >= 0x80 {
                let lineData = Data(bytes: baseAddress.advanced(by: lineStart), count: lineEnd - lineStart)
                return String(data: lineData, encoding: .utf8)
            }
            index += 1
        }
        return String(
            decoding: UnsafeBufferPointer(
                start: baseAddress.advanced(by: lineStart),
                count: lineEnd - lineStart
            ),
            as: UTF8.self
        )
    }

    private func isASCIIWord(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "_")
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
    }

    private func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ")
            || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\r")
            || byte == 0x0B
            || byte == 0x0C
    }

    private func streamingByteLiteralFastPath(
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> ByteLiteralFastPath? {
        #if !canImport(Darwin)
        return nil
        #else
        guard case .automatic = options.encodingMode,
              !options.json,
              !options.stats,
              options.beforeContext == 0,
              options.afterContext == 0,
              !options.passthru,
              options.replacement == nil,
              !options.stopOnNonmatch,
              options.maxCount == nil,
              !options.onlyMatching,
              !options.column,
              !options.byteOffset,
              !options.vimgrep,
              !options.crlf,
              options.maxColumns == nil,
              options.printMode != .filesWithMatches,
              options.printMode != .filesWithoutMatch else {
            return nil
        }
        return matcher.byteLiteralFastPath()
        #endif
    }

    private func canUseBufferedRawLiteralSearch(fileURL: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue <= HaystackReader.defaultMaxBufferBytes
    }

    private func canOmitMatchSpans(options: RipgrepOptions) -> Bool {
        options.colorMode != .always && options.colorMode != .ansi
    }

    private struct ByteLiteralScan {
        var spans: [MatchSpan]
        var needsDecodedFallback: Bool
    }

    private struct ByteLineScan {
        var hasMatch: Bool
        var needsDecodedFallback: Bool
    }

    private enum ByteWordBoundaryState {
        case bounded
        case notBounded
        case needsDecodedFallback
    }

    private func decodedLiteralFallbackSpans(
        matcher: PatternMatcher,
        options: RipgrepOptions,
        line: String
    ) -> [MatchSpan] {
        unicodeWordBoundedSpans(
            matcher.spans(in: line),
            decodedLine: line,
            matcher: matcher,
            rawLine: nil,
            options: options
        )
    }

    private func appendStreamingMatch(
        lineText: String,
        lineBytes: [UInt8],
        terminator: Data,
        absoluteOffset: Int,
        lineNumber: Int,
        spans: [MatchSpan],
        fileURL: URL,
        matches: inout [SearchMatch]
    ) {
        let lineTerminator = String(data: terminator, encoding: .utf8) ?? ""
        matches.append(SearchMatch(
            fileURL: fileURL,
            lineNumber: lineNumber,
            column: nil,
            line: lineText,
            lineTerminator: lineTerminator,
            absoluteOffset: absoluteOffset,
            matchCount: spans.count,
            spans: spans.map { span in
                let textBytes = lineBytes[span.startByte..<span.endByte]
                return MatchSpan(
                    startColumn: span.startByte + 1,
                    endColumn: span.endByte + 1,
                    startByte: span.startByte,
                    endByte: span.endByte,
                    text: String(decoding: textBytes, as: UTF8.self)
                )
            }
        ))
    }

    private func byteLiteralWholeFileMatch(
        fastPath: ByteLiteralFastPath,
        bytes: UnsafeBufferPointer<UInt8>,
        lineEnd: Int
    ) -> ByteLineScan {
        #if canImport(Darwin)
        if !fastPath.caseInsensitiveASCII,
           !fastPath.wordASCII,
           fastPath.literals.count == 1,
           let literal = fastPath.literals.first {
            guard !literal.isEmpty else {
                return ByteLineScan(hasMatch: false, needsDecodedFallback: false)
            }
            let found = literal.withUnsafeBufferPointer { needle in
                rg_memmem_simple(bytes.baseAddress, lineEnd, needle.baseAddress, needle.count) != nil
            }
            return ByteLineScan(hasMatch: found, needsDecodedFallback: false)
        }
        #endif
        return byteLiteralLineMatch(fastPath: fastPath, bytes: bytes, lineStart: 0, lineEnd: lineEnd)
    }

    private func searchDarwinPlainLiteralLines(
        data: Data,
        fileURL: URL,
        bytes: UnsafeBufferPointer<UInt8>,
        baseAddress: UnsafePointer<UInt8>,
        literal: [UInt8],
        maxCount: Int,
        requiresWordBoundary: Bool
    ) -> SearchFileResult? {
        #if canImport(Darwin)
        let dataCount = data.count
        var matches: [SearchMatch] = []
        var searchOffset = 0
        var lineNumber = 1
        var lineCountOffset = 0
        var lastEmittedLineStart = -1
        var bytesSearchedThroughMaxCount: Int?

        func advanceLineNumber(to targetOffset: Int) {
            guard lineCountOffset < targetOffset else {
                return
            }
            lineNumber += Int(rg_memcount_byte(
                baseAddress.advanced(by: lineCountOffset),
                targetOffset - lineCountOffset,
                UInt8(ascii: "\n")
            ))
            lineCountOffset = targetOffset
        }

        while searchOffset < dataCount, matches.count < maxCount {
            let foundPointer = literal.withUnsafeBufferPointer { needle in
                rg_memmem_simple(
                    baseAddress.advanced(by: searchOffset),
                    dataCount - searchOffset,
                    needle.baseAddress,
                    needle.count
                )
            }
            guard let rawFoundPointer = foundPointer else {
                break
            }
            let matchStart = baseAddress.distance(to: rawFoundPointer)
            var lineStart = matchStart
            while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") {
                lineStart -= 1
            }
            let newlinePointer = memchr(
                baseAddress.advanced(by: matchStart),
                Int32(UInt8(ascii: "\n")),
                dataCount - matchStart
            )
            let lineEnd: Int
            let terminator: String
            if let newlinePointer {
                lineEnd = baseAddress.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
                terminator = "\n"
            } else {
                lineEnd = dataCount
                terminator = ""
            }
            if requiresWordBoundary {
                switch asciiWordBoundaryState(
                    bytes: bytes,
                    lineStart: lineStart,
                    lineEnd: lineEnd,
                    matchStart: matchStart,
                    matchEnd: matchStart + literal.count
                ) {
                case .bounded:
                    break
                case .notBounded:
                    searchOffset = max(matchStart + 1, searchOffset + 1)
                    continue
                case .needsDecodedFallback:
                    return nil
                }
            }
            if lineStart != lastEmittedLineStart {
                advanceLineNumber(to: lineStart)
                let lineData = Data(bytes: baseAddress.advanced(by: lineStart), count: lineEnd - lineStart)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    return nil
                }
                matches.append(SearchMatch(
                    fileURL: fileURL,
                    lineNumber: lineNumber,
                    column: nil,
                    line: line,
                    lineTerminator: terminator,
                    absoluteOffset: lineStart,
                    matchCount: 1,
                    spans: []
                ))
                lastEmittedLineStart = lineStart
                if matches.count == maxCount {
                    bytesSearchedThroughMaxCount = lineEnd + terminator.utf8.count
                    break
                }
            }
            searchOffset = max(matchStart + 1, searchOffset + 1)
        }

        return SearchFileResult(
            fileURL: fileURL,
            matches: matches,
            bytesSearched: bytesSearchedThroughMaxCount ?? data.count,
            searched: true
        )
        #else
        return nil
        #endif
    }

    private func searchDarwinCaseInsensitiveLiteralLines(
        data: Data,
        fileURL: URL,
        bytes: UnsafeBufferPointer<UInt8>,
        baseAddress: UnsafePointer<UInt8>,
        literal: [UInt8],
        maxCount: Int
    ) -> SearchFileResult? {
        #if canImport(Darwin)
        let dataCount = data.count
        var lineStarts = Set<Int>()
        var matchStarts: [Int] = []

        func lineBounds(containing offset: Int) -> (start: Int, end: Int, terminator: String) {
            var lineStart = offset
            while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") {
                lineStart -= 1
            }
            let newlinePointer = memchr(
                baseAddress.advanced(by: offset),
                Int32(UInt8(ascii: "\n")),
                dataCount - offset
            )
            if let newlinePointer {
                return (
                    lineStart,
                    baseAddress.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self)),
                    "\n"
                )
            }
            return (lineStart, dataCount, "")
        }

        var searchOffset = 0
        while searchOffset < dataCount {
            let foundPointer = literal.withUnsafeBufferPointer { needle in
                rg_memcasemem_ascii(
                    baseAddress.advanced(by: searchOffset),
                    dataCount - searchOffset,
                    needle.baseAddress,
                    needle.count
                )
            }
            guard let rawFoundPointer = foundPointer else {
                break
            }
            let matchStart = baseAddress.distance(to: rawFoundPointer)
            let bounds = lineBounds(containing: matchStart)
            if lineStarts.insert(bounds.start).inserted {
                matchStarts.append(bounds.start)
            }
            searchOffset = max(matchStart + 1, searchOffset + 1)
        }

        matchStarts.sort()
        var matches: [SearchMatch] = []
        var lineNumber = 1
        var lineCountOffset = 0
        var bytesSearchedThroughMaxCount: Int?

        func advanceLineNumber(to targetOffset: Int) {
            guard lineCountOffset < targetOffset else {
                return
            }
            lineNumber += Int(rg_memcount_byte(
                baseAddress.advanced(by: lineCountOffset),
                targetOffset - lineCountOffset,
                UInt8(ascii: "\n")
            ))
            lineCountOffset = targetOffset
        }

        for lineStart in matchStarts {
            guard matches.count < maxCount else {
                break
            }
            let bounds = lineBounds(containing: lineStart)
            advanceLineNumber(to: lineStart)
            let lineData = Data(bytes: baseAddress.advanced(by: bounds.start), count: bounds.end - bounds.start)
            guard let line = String(data: lineData, encoding: .utf8) else {
                return nil
            }
            matches.append(SearchMatch(
                fileURL: fileURL,
                lineNumber: lineNumber,
                column: nil,
                line: line,
                lineTerminator: bounds.terminator,
                absoluteOffset: bounds.start,
                matchCount: 1,
                spans: []
            ))
            if matches.count == maxCount {
                bytesSearchedThroughMaxCount = bounds.end + bounds.terminator.utf8.count
                break
            }
        }

        return SearchFileResult(
            fileURL: fileURL,
            matches: matches,
            bytesSearched: bytesSearchedThroughMaxCount ?? data.count,
            searched: true
        )
        #else
        return nil
        #endif
    }

    private func byteLiteralLineMatch(
        fastPath: ByteLiteralFastPath,
        bytes: [UInt8],
        lineStart: Int,
        lineEnd: Int
    ) -> ByteLineScan {
        bytes.withUnsafeBufferPointer { buffer in
            byteLiteralLineMatch(fastPath: fastPath, bytes: buffer, lineStart: lineStart, lineEnd: lineEnd)
        }
    }

    private func byteLiteralLineMatch(
        fastPath: ByteLiteralFastPath,
        bytes: UnsafeBufferPointer<UInt8>,
        lineStart: Int,
        lineEnd: Int
    ) -> ByteLineScan {
        if fastPath.caseInsensitiveASCII,
           (lineStart..<lineEnd).contains(where: { isNonASCII(bytes[$0]) }) {
            return ByteLineScan(hasMatch: false, needsDecodedFallback: true)
        }
        for literal in fastPath.literals where literal.count <= lineEnd - lineStart {
            var index = lineStart
            while index + literal.count <= lineEnd {
                guard let first = literal.first else {
                    break
                }
                while index + literal.count <= lineEnd,
                      !byteEquals(bytes[index], first, caseInsensitiveASCII: fastPath.caseInsensitiveASCII) {
                    index += 1
                }
                guard index + literal.count <= lineEnd else {
                    break
                }
                var matched = true
                for offset in 1..<literal.count
                    where !byteEquals(
                        bytes[index + offset],
                        literal[offset],
                        caseInsensitiveASCII: fastPath.caseInsensitiveASCII
                    ) {
                    matched = false
                    break
                }
                if matched && fastPath.wordASCII {
                    switch asciiWordBoundaryState(
                        bytes: bytes,
                        lineStart: lineStart,
                        lineEnd: lineEnd,
                        matchStart: index,
                        matchEnd: index + literal.count
                    ) {
                    case .bounded:
                        return ByteLineScan(hasMatch: true, needsDecodedFallback: false)
                    case .notBounded:
                        index += 1
                        continue
                    case .needsDecodedFallback:
                        return ByteLineScan(hasMatch: false, needsDecodedFallback: true)
                    }
                }
                if matched {
                    return ByteLineScan(hasMatch: true, needsDecodedFallback: false)
                }
                index += 1
            }
        }
        return ByteLineScan(hasMatch: false, needsDecodedFallback: false)
    }

    private func byteLiteralSpans(
        fastPath: ByteLiteralFastPath,
        bytes: [UInt8],
        lineStart: Int,
        lineEnd: Int
    ) -> ByteLiteralScan {
        bytes.withUnsafeBufferPointer { buffer in
            byteLiteralSpans(fastPath: fastPath, bytes: buffer, lineStart: lineStart, lineEnd: lineEnd)
        }
    }

    private func byteLiteralSpans(
        fastPath: ByteLiteralFastPath,
        bytes: UnsafeBufferPointer<UInt8>,
        lineStart: Int,
        lineEnd: Int
    ) -> ByteLiteralScan {
        if fastPath.caseInsensitiveASCII,
           (lineStart..<lineEnd).contains(where: { isNonASCII(bytes[$0]) }) {
            return ByteLiteralScan(spans: [], needsDecodedFallback: true)
        }
        var spans: [MatchSpan] = []
        for literal in fastPath.literals where literal.count <= lineEnd - lineStart {
            var index = lineStart
            while index + literal.count <= lineEnd {
                guard let first = literal.first else {
                    break
                }
                while index + literal.count <= lineEnd,
                      !byteEquals(bytes[index], first, caseInsensitiveASCII: fastPath.caseInsensitiveASCII) {
                    index += 1
                }
                guard index + literal.count <= lineEnd else {
                    break
                }
                var matched = true
                for offset in 1..<literal.count
                    where !byteEquals(
                        bytes[index + offset],
                        literal[offset],
                        caseInsensitiveASCII: fastPath.caseInsensitiveASCII
                    ) {
                    matched = false
                    break
                }
                if matched && fastPath.wordASCII {
                    switch asciiWordBoundaryState(
                        bytes: bytes,
                        lineStart: lineStart,
                        lineEnd: lineEnd,
                        matchStart: index,
                        matchEnd: index + literal.count
                    ) {
                    case .bounded:
                        break
                    case .notBounded:
                        index += 1
                        continue
                    case .needsDecodedFallback:
                        return ByteLiteralScan(spans: spans, needsDecodedFallback: true)
                    }
                }
                if matched {
                    spans.append(MatchSpan(
                        startColumn: index - lineStart + 1,
                        endColumn: index - lineStart + literal.count + 1,
                        startByte: index - lineStart,
                        endByte: index - lineStart + literal.count,
                        text: ""
                    ))
                    index += literal.count
                } else {
                    index += 1
                }
            }
        }
        let sorted = spans.sorted {
            if $0.startByte == $1.startByte {
                return $0.endByte < $1.endByte
            }
            return $0.startByte < $1.startByte
        }
        return ByteLiteralScan(spans: deduplicatedByteSpans(sorted), needsDecodedFallback: false)
    }

    private func byteEquals(_ lhs: UInt8, _ rhs: UInt8, caseInsensitiveASCII: Bool) -> Bool {
        guard caseInsensitiveASCII else {
            return lhs == rhs
        }
        return asciiLowercase(lhs) == asciiLowercase(rhs)
    }

    private func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    private func asciiWordBoundaryState(
        bytes: UnsafeBufferPointer<UInt8>,
        lineStart: Int,
        lineEnd: Int,
        matchStart: Int,
        matchEnd: Int
    ) -> ByteWordBoundaryState {
        let before = matchStart == lineStart ? nil : bytes[matchStart - 1]
        let after = matchEnd == lineEnd ? nil : bytes[matchEnd]
        if isNonASCII(before) || isNonASCII(after) {
            return .needsDecodedFallback
        }
        let hasWordByte = (matchStart..<matchEnd).contains { isASCIIWordByte(bytes[$0]) }
        guard hasWordByte else {
            return !isASCIIWordByte(before) && !isASCIIWordByte(after) ? .bounded : .notBounded
        }
        if isASCIIWordByte(bytes[matchStart]), isASCIIWordByte(before) {
            return .notBounded
        }
        if isASCIIWordByte(bytes[matchEnd - 1]), isASCIIWordByte(after) {
            return .notBounded
        }
        return .bounded
    }

    private func isNonASCII(_ byte: UInt8?) -> Bool {
        guard let byte else {
            return false
        }
        return byte >= 0x80
    }

    private func isASCIIWordByte(_ byte: UInt8?) -> Bool {
        guard let byte else {
            return false
        }
        return (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || byte == UInt8(ascii: "_")
    }

    private func deduplicatedByteSpans(_ spans: [MatchSpan]) -> [MatchSpan] {
        var output: [MatchSpan] = []
        var seen: Set<String> = []
        for span in spans {
            let key = "\(span.startByte):\(span.endByte)"
            if seen.insert(key).inserted {
                output.append(span)
            }
        }
        return output
    }

    private func jsonBinaryDisplayMatches(
        _ matches: [SearchMatch],
        lineNumberShifts: [Int: Int],
        options: RipgrepOptions
    ) -> [SearchMatch] {
        guard shouldSplitJSONBinaryDisplayLines(options: options) else {
            return matches
        }
        return matches.flatMap { match -> [SearchMatch] in
            let lineNumber = match.lineNumber + (lineNumberShifts[match.lineNumber] ?? 0)
            guard match.line.contains("\0") else {
                guard lineNumber != match.lineNumber else {
                    return [match]
                }
                return [SearchMatch(
                    fileURL: match.fileURL,
                    lineNumber: lineNumber,
                    column: match.column,
                    line: match.line,
                    rawLine: match.rawLine,
                    lineTerminator: match.lineTerminator,
                    absoluteOffset: match.absoluteOffset,
                    matchCount: match.matchCount,
                    spans: match.spans
                )]
            }
            return jsonBinaryDisplayPieces(for: match, startingLineNumber: lineNumber, options: options)
        }
    }

    private func jsonBinaryDisplayLines(
        _ lines: [SearchLine],
        lineNumberShifts: [Int: Int],
        options: RipgrepOptions
    ) -> [SearchLine] {
        guard shouldSplitJSONBinaryDisplayLines(options: options) else {
            return lines
        }
        return lines.flatMap { line -> [SearchLine] in
            let lineNumber = line.lineNumber + (lineNumberShifts[line.lineNumber] ?? 0)
            guard line.line.contains("\0") else {
                guard lineNumber != line.lineNumber else {
                    return [line]
                }
                return [SearchLine(
                    lineNumber: lineNumber,
                    line: line.line,
                    rawLine: line.rawLine,
                    lineTerminator: line.lineTerminator,
                    absoluteOffset: line.absoluteOffset,
                    positiveSpans: line.positiveSpans
                )]
            }
            return jsonBinaryDisplayPieces(for: line, startingLineNumber: lineNumber, options: options)
        }
    }

    private func jsonBinaryLineNumberShifts(for lines: [SearchLine], options: RipgrepOptions) -> [Int: Int] {
        guard shouldSplitJSONBinaryDisplayLines(options: options) else {
            return [:]
        }
        var shifts: [Int: Int] = [:]
        var shift = 0
        for line in lines.sorted(by: { $0.lineNumber < $1.lineNumber }) {
            shifts[line.lineNumber] = shift
            shift += line.line.unicodeScalars.filter { $0 == "\0" }.count
        }
        return shifts
    }

    private func shouldSplitJSONBinaryDisplayLines(options: RipgrepOptions) -> Bool {
        options.json
            && !options.effectivePatterns.contains(where: containsNULPattern)
            && !options.effectivePatterns.contains { usesMultilineDotAllWildcard($0, options: options) }
            && (!options.multiline || !options.effectivePatterns.contains(where: isMultilineBinaryBoundaryPattern))
    }

    private func usesMultilineDotAllWildcard(_ pattern: String, options: RipgrepOptions) -> Bool {
        (options.multilineDotall || containsInlineDotAllOption(pattern))
            && containsDotWildcardOutsideCharacterClass(pattern)
    }

    private func containsDotWildcardOutsideCharacterClass(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        for character in pattern {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "[" {
                inClass = true
                continue
            }
            if character == "]" {
                inClass = false
                continue
            }
            if !inClass, character == "." {
                return true
            }
        }
        return false
    }

    private func containsInlineDotAllOption(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                index = pattern.index(after: index)
                continue
            }
            if !inClass, pattern[index...].hasPrefix("(?") {
                var optionIndex = pattern.index(index, offsetBy: 2)
                var enablesDotAll = false
                var disabling = false
                while optionIndex < pattern.endIndex {
                    let option = pattern[optionIndex]
                    if option == ")" || option == ":" {
                        return enablesDotAll
                    }
                    if option == "-" {
                        disabling = true
                    } else if option == "s" {
                        enablesDotAll = !disabling
                    }
                    optionIndex = pattern.index(after: optionIndex)
                }
                return false
            }
            index = pattern.index(after: index)
        }
        return false
    }

    private func containsNULPattern(_ pattern: String) -> Bool {
        pattern.contains("\0")
            || pattern.contains(#"\0"#)
            || pattern.lowercased().contains(#"\x00"#)
            || pattern.lowercased().contains(#"\x{0}"#)
            || pattern.lowercased().contains(#"\u0000"#)
            || pattern.lowercased().contains(#"\u{0}"#)
    }

    private func jsonBinaryDisplayPieces(
        for match: SearchMatch,
        startingLineNumber: Int,
        options: RipgrepOptions
    ) -> [SearchMatch] {
        jsonBinaryDisplaySegments(
            text: match.line,
            rawText: match.rawLine,
            lineTerminator: match.lineTerminator,
            absoluteOffset: match.absoluteOffset,
            startingLineNumber: startingLineNumber,
            spans: match.spans,
            options: options
        ).compactMap { segment in
            guard !segment.spans.isEmpty else {
                return nil
            }
            return SearchMatch(
                fileURL: match.fileURL,
                lineNumber: segment.lineNumber,
                column: options.column ? segment.spans.first?.startColumn : nil,
                line: segment.text,
                rawLine: segment.rawText,
                lineTerminator: segment.terminator,
                absoluteOffset: segment.absoluteOffset,
                matchCount: segment.spans.count,
                spans: segment.spans
            )
        }
    }

    private func jsonBinaryDisplayPieces(
        for line: SearchLine,
        startingLineNumber: Int,
        options: RipgrepOptions
    ) -> [SearchLine] {
        jsonBinaryDisplaySegments(
            text: line.line,
            rawText: line.rawLine,
            lineTerminator: line.lineTerminator,
            absoluteOffset: line.absoluteOffset,
            startingLineNumber: startingLineNumber,
            spans: line.positiveSpans,
            options: options
        ).map { segment in
            SearchLine(
                lineNumber: segment.lineNumber,
                line: segment.text,
                rawLine: segment.rawText,
                lineTerminator: segment.terminator,
                absoluteOffset: segment.absoluteOffset,
                positiveSpans: segment.spans
            )
        }
    }

    private struct JSONBinaryDisplaySegment {
        let lineNumber: Int
        let text: String
        let rawText: String?
        let terminator: String
        let absoluteOffset: Int
        let spans: [MatchSpan]
    }

    private func jsonBinaryDisplaySegments(
        text: String,
        rawText: String?,
        lineTerminator: String,
        absoluteOffset: Int,
        startingLineNumber: Int,
        spans: [MatchSpan],
        options: RipgrepOptions
    ) -> [JSONBinaryDisplaySegment] {
        let rawSegments = rawText.map(splitJSONBinaryRawSegments)
        var output: [JSONBinaryDisplaySegment] = []
        var segmentStart = text.startIndex
        var segmentStartByte = 0
        var lineNumber = startingLineNumber
        var rawSegmentIndex = 0

        func appendSegment(end: String.Index, terminator: String) {
            let segmentText = String(text[segmentStart..<end])
            let segmentEndByte = segmentStartByte + byteCount(segmentText, options: options)
            let segmentSpans = spans.compactMap { span -> MatchSpan? in
                let clippedStartByte = max(span.startByte, segmentStartByte)
                let clippedEndByte = min(span.endByte, segmentEndByte)
                if span.startByte == span.endByte {
                    guard span.startByte >= segmentStartByte,
                          span.startByte <= segmentEndByte else {
                        return nil
                    }
                } else {
                    guard clippedStartByte < clippedEndByte,
                          span.startByte < segmentEndByte,
                          span.endByte > segmentStartByte else {
                        return nil
                    }
                }
                let startByte = clippedStartByte - segmentStartByte
                let endByte = clippedEndByte - segmentStartByte
                return MatchSpan(
                    startColumn: column(in: segmentText, byteOffset: startByte, options: options),
                    endColumn: column(in: segmentText, byteOffset: endByte, options: options),
                    startByte: startByte,
                    endByte: endByte,
                    text: byteSlice(in: segmentText, start: startByte, end: endByte, options: options),
                    replacement: span.replacement
                )
            }
            output.append(JSONBinaryDisplaySegment(
                lineNumber: lineNumber,
                text: segmentText,
                rawText: rawSegments?[safe: rawSegmentIndex],
                terminator: terminator,
                absoluteOffset: absoluteOffset + segmentStartByte,
                spans: segmentSpans
            ))
            rawSegmentIndex += 1
        }

        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\0" {
                appendSegment(end: index, terminator: "\n")
                let segmentText = String(text[segmentStart..<index])
                segmentStartByte += byteCount(segmentText, options: options) + byteCount("\0", options: options)
                segmentStart = text.index(after: index)
                lineNumber += jsonBinaryDisplayLineCount(segmentText)
            }
            index = text.index(after: index)
        }
        if segmentStart < text.endIndex || !lastScalar(in: text, equals: "\0") {
            appendSegment(end: text.endIndex, terminator: lineTerminator)
        }
        return output
    }

    private func jsonBinaryDisplayLineCount(_ text: String) -> Int {
        max(1, text.unicodeScalars.filter { $0 == "\n" }.count + 1)
    }

    private func splitJSONBinaryRawSegments(_ rawText: String) -> [String] {
        var segments: [String] = []
        var start = rawText.startIndex
        var index = rawText.startIndex
        while index < rawText.endIndex {
            if rawText[index] == "\0" {
                segments.append(String(rawText[start..<index]))
                start = rawText.index(after: index)
            }
            index = rawText.index(after: index)
        }
        segments.append(String(rawText[start..<rawText.endIndex]))
        return segments
    }

    private func byteSlice(in text: String, start: Int, end: Int, options: RipgrepOptions) -> String {
        guard start < end else {
            return ""
        }
        guard start > 0 || end < byteCount(text, options: options) else {
            return text
        }
        var lower = text.startIndex
        var upper = text.endIndex
        var bytes = 0
        var index = text.startIndex
        while index < text.endIndex {
            if bytes == start {
                lower = index
            }
            let next = text.index(after: index)
            bytes += byteCount(String(text[index]), options: options)
            if bytes == end {
                upper = next
                break
            }
            index = next
        }
        return String(text[lower..<upper])
    }

    private func searchStdin(
        _ data: Data,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> SearchFileResult {
        let fileURL = URL(fileURLWithPath: "<stdin>")
        let contents = decode(data, options: options)
        let result = searchContents(
            contents,
            rawData: rawDataForOutput(data, options: options, matcher: matcher),
            rawDataForMatching: rawDataForMatching(data, options: options, matcher: matcher),
            fileURL: fileURL,
            matcher: matcher,
            options: options,
            splitBinaryNUL: shouldSplitStdinBinaryNUL(options: options)
        )
        guard !options.disablesBinaryDetection,
              shouldCheckBinary(data, options: options),
              let binaryByteOffset = data.firstIndex(of: 0) else {
            return result
        }
        let visibleMatches = binaryVisibleMatches(
            result.matches,
            binaryByteOffset: binaryByteOffset,
            options: options,
            isExplicit: true
        )
        let emittedMatches = shouldEmitSuppressedBinaryMatches(options, isExplicit: true)
            ? result.matches
            : visibleMatches
        let hasBinaryMatch = hasBinaryMatchResult(
            result: result,
            visibleMatches: visibleMatches,
            binaryByteOffset: binaryByteOffset,
            options: options
        )
        let lineNumberShifts = jsonBinaryLineNumberShifts(for: result.lines, options: options)
        var displayMatches = options.json
            ? jsonBinaryDisplayMatches(emittedMatches, lineNumberShifts: lineNumberShifts, options: options)
            : emittedMatches
        if shouldDropSuppressedBinaryContextMatches(hasBinaryMatch: hasBinaryMatch, options: options) {
            displayMatches = []
        }
        let displayLines = options.json
            ? jsonBinaryDisplayLines(result.lines, lineNumberShifts: lineNumberShifts, options: options)
            : hasBinaryMatch ? result.lines : []
        return SearchFileResult(
            fileURL: fileURL,
            matches: displayMatches,
            lines: displayLines,
            binaryByteOffset: binaryByteOffset,
            hasBinaryMatch: hasBinaryMatch,
            bytesSearched: suppressedBinaryBytesSearched(
                dataCount: data.count,
                binaryByteOffset: binaryByteOffset,
                searchedMatches: result.matches,
                visibleMatches: visibleMatches,
                options: options
            ),
            supplementalMatchedLines: result.supplementalMatchedLines + binarySupplementalMatchedLines(
                statsMatches: matchesBeforeBinaryByte(result.matches, binaryByteOffset: binaryByteOffset, options: options),
                displayMatches: displayMatches,
                hasBinaryMatch: hasBinaryMatch,
                options: options
            ),
            supplementalMatches: result.supplementalMatches + binarySupplementalMatches(
                statsMatches: matchesBeforeBinaryByte(result.matches, binaryByteOffset: binaryByteOffset, options: options),
                displayMatches: displayMatches,
                hasBinaryMatch: hasBinaryMatch
            )
        )
    }

    private func matchesBeforeBinary(
        _ matches: [SearchMatch],
        binaryByteOffset: Int,
        options: RipgrepOptions
    ) -> [SearchMatch] {
        let cutoff = binarySuppressionCutoff(for: binaryByteOffset)
        return matchesBeforeBinary(matches, cutoff: cutoff, options: options)
    }

    private func matchesBeforeBinaryByte(
        _ matches: [SearchMatch],
        binaryByteOffset: Int,
        options: RipgrepOptions
    ) -> [SearchMatch] {
        matchesBeforeBinary(matches, cutoff: binaryByteOffset, options: options)
    }

    private func matchesBeforeBinary(
        _ matches: [SearchMatch],
        cutoff: Int,
        options: RipgrepOptions
    ) -> [SearchMatch] {
        if options.printMode == .matchingLines && !options.json {
            return matches.filter { match in
                match.absoluteOffset + byteCount(match.lineWithTerminator, options: options) <= cutoff
            }
        }
        return matchesBeforeBinarySpans(matches, cutoff: cutoff, options: options)
    }

    private func matchesBeforeBinarySpans(
        _ matches: [SearchMatch],
        cutoff: Int,
        options: RipgrepOptions
    ) -> [SearchMatch] {
        matches.filter { match in
            guard !match.spans.isEmpty else {
                return match.absoluteOffset + byteCount(match.line, options: options) <= cutoff
            }
            return match.spans.contains { span in
                match.absoluteOffset + span.endByte <= cutoff
            }
        }
    }

    private func binarySuppressionCutoff(for binaryByteOffset: Int) -> Int {
        (binaryByteOffset / Self.binaryDetectionBufferSize) * Self.binaryDetectionBufferSize
    }

    private func binaryVisibleMatches(
        _ matches: [SearchMatch],
        binaryByteOffset: Int,
        options: RipgrepOptions,
        isExplicit: Bool,
        usesBufferCutoff: Bool = true
    ) -> [SearchMatch] {
        let matches = usesBufferCutoff
            ? matchesBeforeBinary(matches, binaryByteOffset: binaryByteOffset, options: options)
            : matchesBeforeBinaryByte(matches, binaryByteOffset: binaryByteOffset, options: options)
        guard options.printMode == .matchingLines,
              !options.json,
              !(options.quiet && options.stats),
              !isExplicit else {
            return matches
        }
        return Array(matches.prefix(1))
    }

    private func binarySupplementalMatches(
        statsMatches: [SearchMatch],
        displayMatches: [SearchMatch],
        hasBinaryMatch: Bool
    ) -> Int {
        let statsCount = statsMatches.reduce(0) { $0 + $1.matchCount }
        let displayCount = displayMatches.reduce(0) { $0 + $1.matchCount }
        let promotedBinaryMatch = displayCount == 0 && hasBinaryMatch ? 1 : 0
        return max(0, statsCount - displayCount - promotedBinaryMatch)
    }

    private func binarySupplementalMatchedLines(
        statsMatches: [SearchMatch],
        displayMatches: [SearchMatch],
        hasBinaryMatch: Bool,
        options: RipgrepOptions
    ) -> Int {
        let statsLines = statsMatches.reduce(0) { $0 + MatchedLineCounter.count($1, options: options) }
        let displayLines = displayMatches.reduce(0) { $0 + MatchedLineCounter.count($1, options: options) }
        let promotedBinaryLine = displayLines == 0 && hasBinaryMatch ? 1 : 0
        return max(0, statsLines - displayLines - promotedBinaryLine)
    }

    private func shouldSplitStdinBinaryNUL(options: RipgrepOptions) -> Bool {
        switch options.printMode {
        case .count, .countMatches:
            return true
        case .matchingLines, .filesWithMatches, .filesWithoutMatch:
            return false
        }
    }

    private func hasBinaryMatchResult(
        result: SearchFileResult,
        visibleMatches: [SearchMatch],
        binaryByteOffset: Int,
        options: RipgrepOptions
    ) -> Bool {
        guard result.hasMatch else {
            return false
        }
        guard options.printMode == .matchingLines,
              !options.json,
              (options.beforeContext > 0 || options.passthru) else {
            return true
        }
        if options.effectivePatterns.contains(where: containsLineEndAnchor) {
            return matchesBeforeBinarySpans(
                result.matches,
                cutoff: binaryByteOffset,
                options: options
            ).contains { $0.absoluteOffset == 0 }
        }
        if options.multiline {
            return !matchesBeforeBinarySpans(
                result.matches,
                cutoff: binaryByteOffset,
                options: options
            ).isEmpty
        }
        let matchesBeforeNUL = matchesBeforeBinaryByte(
            result.matches,
            binaryByteOffset: binaryByteOffset,
            options: options
        )
        return !matchesBeforeNUL.isEmpty
    }

    private func shouldDropSuppressedBinaryContextMatches(
        hasBinaryMatch: Bool,
        options: RipgrepOptions
    ) -> Bool {
        options.printMode == .matchingLines
            && !options.json
            && !hasBinaryMatch
            && (options.beforeContext > 0 || options.passthru)
    }

    private func shouldEmitSuppressedBinaryMatches(_ options: RipgrepOptions, isExplicit: Bool) -> Bool {
        guard options.binaryMode == .searchAndSuppress || isExplicit else {
            return false
        }
        if options.quiet && options.stats {
            return true
        }
        if options.json {
            return true
        }
        switch options.printMode {
        case .count, .countMatches:
            return true
        case .matchingLines, .filesWithMatches, .filesWithoutMatch:
            return false
        }
    }

    private func suppressedBinaryBytesSearched(
        dataCount: Int,
        binaryByteOffset: Int,
        searchedMatches: [SearchMatch],
        visibleMatches: [SearchMatch],
        options: RipgrepOptions
    ) -> Int {
        if options.quiet && options.stats {
            return dataCount
        }
        if options.json,
           options.multiline,
           (options.effectivePatterns.contains(where: isMultilineBinaryBoundaryPattern)
            || options.effectivePatterns.contains(where: containsNULPattern)
            || options.effectivePatterns.contains { usesMultilineDotAllWildcard($0, options: options) }) {
            return binaryByteOffset
        }
        guard options.printMode == .matchingLines,
              !options.json else {
            return dataCount
        }
        if visibleMatches.isEmpty {
            if options.passthru {
                return binaryByteOffset + 1
            }
        }
        guard let firstMatch = (visibleMatches.first ?? searchedMatches.first) else {
            return dataCount
        }
        if visibleMatches.isEmpty, options.beforeContext > 0 {
            return 0
        }
        if options.multiline,
           options.binaryMode == .automatic,
           let span = firstMatch.spans.first {
            let spanStart = firstMatch.absoluteOffset + span.startByte
            let spanEnd = firstMatch.absoluteOffset + span.endByte
            if spanStart < binaryByteOffset, spanEnd > binaryByteOffset {
                return binaryByteOffset
            }
            return min(dataCount, spanEnd + 1)
        }
        return firstMatch.absoluteOffset + firstMatch.lineWithTerminator.utf8.count
    }

    private func shouldPreprocess(_ haystack: Haystack, options: RipgrepOptions) -> Bool {
        guard options.preprocessor != nil, !haystack.url.path.isEmpty else {
            return false
        }
        guard !options.preGlobPatterns.isEmpty else {
            return true
        }
        let matcher = GlobMatcher(patterns: options.preGlobPatterns, overrideSemantics: true)
        return matcher.allows(relativePath: haystack.overridePath, isDirectory: false)
    }

    private func searchPreprocessedFile(
        _ haystack: Haystack,
        originalData: Data,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> FileSearchOutcome {
        guard let command = options.preprocessor else {
            let fileURL = haystack.url
            return FileSearchOutcome(result: SearchFileResult(fileURL: fileURL, matches: [], searched: false))
        }
        let fileURL = haystack.url
        let displayPath = OutputPathFormatter(options: options).displayPath(for: fileURL)
        let commandDisplay = preprocessorCommandDisplay(command: command, filePath: displayPath)
        guard let executable = resolveExecutable(command) else {
            return FileSearchOutcome(
                result: SearchFileResult(fileURL: fileURL, matches: [], searched: false),
                message: "\(displayPath): preprocessor command could not start: '\(commandDisplay)': No such file or directory (os error 2)"
            )
        }
        do {
            let process = Process()
            process.executableURL = executable
            process.arguments = [displayPath]

            let input = try FileHandle(forReadingFrom: fileURL)
            let output = Pipe()
            let stderr = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = stderr

            try process.run()
            input.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return FileSearchOutcome(
                    result: SearchFileResult(fileURL: fileURL, matches: [], searched: false),
                    message: "\(displayPath): preprocessor command failed: '\(commandDisplay)': \(preprocessorErrorText(errorData))"
                )
            }

            let contents = decode(data, options: options)
            let result = searchContents(
                contents,
                rawData: rawDataForOutput(data, options: options, matcher: matcher),
                rawDataForMatching: rawDataForMatching(data, options: options, matcher: matcher),
                fileURL: fileURL,
                matcher: matcher,
                options: options,
                splitBinaryNUL: true
            )
            let searchedResult = SearchFileResult(
                fileURL: result.fileURL,
                matches: result.matches,
                lines: result.lines,
                bytesSearched: data.count,
                searched: result.searched
            )
            return FileSearchOutcome(result: binaryAdjustedPreprocessedResult(
                searchedResult,
                data: data,
                originalBinaryByteOffset: originalData.firstIndex(of: 0),
                options: options,
                isExplicit: haystack.isExplicit
            ))
        } catch {
            return FileSearchOutcome(
                result: SearchFileResult(fileURL: fileURL, matches: [], searched: false),
                message: "\(displayPath): preprocessor command could not start: '\(commandDisplay)': \(error)"
            )
        }
    }

    private func binaryAdjustedPreprocessedResult(
        _ result: SearchFileResult,
        data: Data,
        originalBinaryByteOffset: Int?,
        options: RipgrepOptions,
        isExplicit: Bool
    ) -> SearchFileResult {
        guard !options.disablesBinaryDetection,
              shouldCheckBinary(data, options: options),
              let binaryByteOffset = data.firstIndex(of: 0) else {
            return result
        }
        let binaryDetectedBeforeSearch = binaryByteOffset < Self.binaryDetectionBufferSize
        let visibleMatches = binaryVisibleMatches(
            result.matches,
            binaryByteOffset: binaryByteOffset,
            options: options,
            isExplicit: isExplicit,
            usesBufferCutoff: false
        )
        let emittedMatches = shouldEmitSuppressedBinaryMatches(options, isExplicit: isExplicit)
            ? result.matches
            : visibleMatches
        let hasBinaryMatch = hasBinaryMatchResult(
            result: result,
            visibleMatches: visibleMatches,
            binaryByteOffset: binaryByteOffset,
            options: options
        )
        let displayMatches = shouldDropSuppressedBinaryContextMatches(hasBinaryMatch: hasBinaryMatch, options: options)
            ? []
            : emittedMatches
        let displayLines = hasBinaryMatch ? result.lines : []
        if options.binaryMode == .automatic && !isExplicit && binaryDetectedBeforeSearch && visibleMatches.isEmpty {
            return SearchFileResult(
                fileURL: result.fileURL,
                matches: [],
                binaryByteOffset: binaryByteOffset,
                stoppedBinaryAfterMatch: true,
                searched: true
            )
        }
        if options.binaryMode == .automatic && !isExplicit && visibleMatches.isEmpty {
            return SearchFileResult(fileURL: result.fileURL, matches: [], searched: false)
        }
        return SearchFileResult(
            fileURL: result.fileURL,
            matches: displayMatches,
            lines: displayLines,
            binaryByteOffset: binaryByteOffset,
            hasBinaryMatch: hasBinaryMatch,
            stoppedBinaryAfterMatch: options.binaryMode == .automatic && !isExplicit,
            shouldPrintMatchesBeforeBinary: originalBinaryByteOffset != nil && !displayMatches.isEmpty,
            bytesSearched: suppressedBinaryBytesSearched(
                dataCount: data.count,
                binaryByteOffset: binaryByteOffset,
                searchedMatches: result.matches,
                visibleMatches: visibleMatches,
                options: options
            ),
            supplementalMatchedLines: result.supplementalMatchedLines,
            supplementalMatches: result.supplementalMatches
        )
    }

    private func preprocessorCommandDisplay(command: String, filePath: String) -> String {
        "\"\(command)\" \"\(filePath)\""
    }

    private func preprocessorErrorText(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return "<stderr is empty>"
        }
        return """

        -------------------------------------------------------------------------------
        \(text)
        -------------------------------------------------------------------------------
        """
    }

    private func searchDecompressedFile(
        _ fileURL: URL,
        command: DecompressionCommand,
        matcher: PatternMatcher,
        options: RipgrepOptions,
        isExplicit: Bool
    ) -> FileSearchOutcome {
        do {
            let displayPath = OutputPathFormatter(options: options).displayPath(for: fileURL)
            let data = try runStreamingCommand(
                executable: command.executable,
                arguments: command.arguments,
                inputPath: commandInputPath(displayPath: displayPath, fileURL: fileURL, options: options)
            )
            let contents = decode(data, options: options)
            let result = searchContents(
                contents,
                rawData: rawDataForOutput(data, options: options, matcher: matcher),
                rawDataForMatching: rawDataForMatching(data, options: options, matcher: matcher),
                fileURL: fileURL,
                matcher: matcher,
                options: options,
                splitBinaryNUL: true
            )
            let searchedResult = SearchFileResult(
                fileURL: result.fileURL,
                matches: result.matches,
                lines: result.lines,
                bytesSearched: data.count,
                searched: result.searched
            )
            return FileSearchOutcome(result: binaryAdjustedDecompressedResult(
                searchedResult,
                data: data,
                options: options,
                isExplicit: isExplicit
            ))
        } catch {
            let displayPath = OutputPathFormatter(options: options).displayPath(for: fileURL)
            return FileSearchOutcome(
                result: SearchFileResult(fileURL: fileURL, matches: [], searched: false),
                message: "\(displayPath): \(error)"
            )
        }
    }

    private func binaryAdjustedDecompressedResult(
        _ result: SearchFileResult,
        data: Data,
        options: RipgrepOptions,
        isExplicit: Bool
    ) -> SearchFileResult {
        guard !options.disablesBinaryDetection,
              shouldCheckBinary(data, options: options),
              let binaryByteOffset = data.firstIndex(of: 0) else {
            return result
        }
        let binaryDetectedBeforeSearch = binaryByteOffset < Self.binaryDetectionBufferSize
        let visibleMatches = binaryDetectedBeforeSearch && !isExplicit
            ? []
            : binaryVisibleMatches(
                result.matches,
                binaryByteOffset: binaryByteOffset,
                options: options,
                isExplicit: isExplicit
            )
        let emittedMatches = shouldEmitSuppressedBinaryMatches(options, isExplicit: isExplicit)
            ? result.matches
            : visibleMatches
        let lineNumberShifts = jsonBinaryLineNumberShifts(for: result.lines, options: options)
        let displayMatches = options.json
            ? jsonBinaryDisplayMatches(emittedMatches, lineNumberShifts: lineNumberShifts, options: options)
            : emittedMatches
        let hasBinaryMatch = hasBinaryMatchResult(
            result: result,
            visibleMatches: visibleMatches,
            binaryByteOffset: binaryByteOffset,
            options: options
        )
        let displayLines = options.json
            ? jsonBinaryDisplayLines(result.lines, lineNumberShifts: lineNumberShifts, options: options)
            : hasBinaryMatch ? result.lines : []
        if options.binaryMode == .automatic && !isExplicit && binaryDetectedBeforeSearch {
            return SearchFileResult(
                fileURL: result.fileURL,
                matches: [],
                binaryByteOffset: binaryByteOffset,
                stoppedBinaryAfterMatch: true,
                searched: true
            )
        }
        if options.binaryMode == .automatic && !isExplicit && visibleMatches.isEmpty {
            return SearchFileResult(fileURL: result.fileURL, matches: [], searched: false)
        }
        return SearchFileResult(
            fileURL: result.fileURL,
            matches: displayMatches,
            lines: displayLines,
            binaryByteOffset: binaryByteOffset,
            hasBinaryMatch: hasBinaryMatch,
            bytesSearched: suppressedBinaryBytesSearched(
                dataCount: data.count,
                binaryByteOffset: binaryByteOffset,
                searchedMatches: result.matches,
                visibleMatches: visibleMatches,
                options: options
            ),
            supplementalMatchedLines: result.supplementalMatchedLines,
            supplementalMatches: result.supplementalMatches
        )
    }

    private func runStreamingCommand(
        executable: URL,
        arguments: [String],
        inputPath: String
    ) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let output = Pipe()
        let stderr = Pipe()
        process.arguments = arguments + [inputPath]
        process.standardOutput = output
        process.standardError = stderr

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RipgrepError.message(preprocessorErrorText(errorData))
        }
        return data
    }

    private func commandInputPath(displayPath: String, fileURL: URL, options: RipgrepOptions) -> String {
        guard options.pathSeparator == nil else {
            return fileURL.path
        }
        return displayPath
    }

    private func decompressionCommand(
        for fileURL: URL,
        options: RipgrepOptions
    ) -> DecompressionCommand? {
        guard options.searchZip else {
            return nil
        }
        let path = fileURL.path
        let specs: [(suffix: String, program: String, arguments: [String])] = [
            (".gz", "gzip", ["-d", "-c"]),
            (".tgz", "gzip", ["-d", "-c"]),
            (".bz2", "bzip2", ["-d", "-c"]),
            (".tbz2", "bzip2", ["-d", "-c"]),
            (".xz", "xz", ["-d", "-c"]),
            (".txz", "xz", ["-d", "-c"]),
            (".lz4", "lz4", ["-d", "-c"]),
            (".lzma", "xz", ["--format=lzma", "-d", "-c"]),
            (".br", "brotli", ["-d", "-c"]),
            (".zst", "zstd", ["-q", "-d", "-c"]),
            (".zstd", "zstd", ["-q", "-d", "-c"]),
            (".Z", "uncompress", ["-c"]),
        ]
        guard let spec = specs.last(where: { path.hasSuffix($0.suffix) }),
              let executable = resolveExecutable(spec.program) else {
            return nil
        }
        return DecompressionCommand(
            executable: executable,
            arguments: spec.arguments
        )
    }

    private func resolveExecutable(_ program: String) -> URL? {
        if program.contains("/") {
            let url = URL(fileURLWithPath: program)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let paths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
            .split(separator: ":")
            .map(String.init)
        for path in paths {
            let candidate = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(program)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func searchContents(
        _ contents: String,
        rawData: Data? = nil,
        rawDataForMatching: Data? = nil,
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions,
        splitBinaryNUL: Bool = false
    ) -> SearchFileResult {
        let shouldSplitBinaryNUL = splitBinaryNUL && !options.disablesBinaryDetection
        if options.multiline {
            let shouldSplitMultilineBinaryNUL = shouldSplitBinaryNUL
                && (options.printMode == .count || options.printMode == .countMatches)
                && !options.effectivePatterns.contains(where: containsLineAnchor)
                && !options.effectivePatterns.contains(where: containsNULPattern)
                && !options.effectivePatterns.contains(where: containsLineTerminatorOutsideCharacterClass)
            return searchMultilineContents(
                contents,
                rawData: rawData,
                rawDataForMatching: rawDataForMatching,
                fileURL: fileURL,
                matcher: matcher,
                options: options,
                splitBinaryNUL: shouldSplitMultilineBinaryNUL
            )
        }

        var matches: [SearchMatch] = []
        let lines = splitLines(contents, options: options, splitBinaryNUL: shouldSplitBinaryNUL)
        let rawLines = rawData.map { splitRawLines($0, options: options, splitBinaryNUL: shouldSplitBinaryNUL) }
        let matchingRawLines = rawDataForMatching.map {
            splitRawLines($0, options: options, splitBinaryNUL: shouldSplitBinaryNUL)
        } ?? rawLines
        var searchLines: [SearchLine] = []
        var absoluteOffset = 0
        let maxCount = options.maxCount ?? Int.max
        var hasMatched = false
        var positiveRunAfterInvertedMatch = 0
        var bytesSearchedThroughMaxCount: Int?

        for (offset, splitLine) in lines.enumerated() {
            let line = splitLine.text
            let rawLine = rawLines?[safe: offset]?.text
            let matchingRawLine = matchingRawLines?[safe: offset]?.text
            let lineForMatching = matcher.usesByteSemantics ? (matchingRawLine ?? line) : line
            let rawLineForSpanAdjustment = matcher.usesByteSemantics ? nil : matchingRawLine
            let lineNumber = offset + 1
            let lineByteCount = matchingRawLines?[safe: offset].map {
                $0.text.unicodeScalars.count + $0.terminator.unicodeScalars.count
            } ?? byteCount(splitLine.text, options: options) + byteCount(splitLine.terminator, options: options)
            if !options.invertMatch, matcher.canFastReject(lineForMatching) {
                searchLines.append(SearchLine(
                    lineNumber: lineNumber,
                    line: line,
                    rawLine: rawLine,
                    lineTerminator: splitLine.terminator,
                    absoluteOffset: absoluteOffset,
                    positiveSpans: []
                ))
                absoluteOffset += lineByteCount
                if options.stopOnNonmatch && !options.invertMatch && hasMatched {
                    break
                }
                continue
            }
            let positiveSpans = syntheticBinarySplitSpans(
                syntheticInlineCRLFBoundarySpans(
                    crlfTrimmedSpans(
                        unicodeWordBoundedSpans(
                            adjustedSpans(
                                matcher.positiveSpans(in: lineForMatching),
                                rawLine: rawLineForSpanAdjustment,
                                options: options
                            ),
                            decodedLine: line,
                            matcher: matcher,
                            rawLine: rawLineForSpanAdjustment,
                            options: options
                        ),
                        line: line,
                        options: options
                    ),
                    line: line,
                    terminator: splitLine.terminator,
                    matcher: matcher,
                    options: options
                ),
                line: matchingRawLine ?? lineForMatching,
                terminator: splitLine.terminator,
                splitBinaryNUL: shouldSplitBinaryNUL,
                options: options
            ).spans
            guard matches.count < maxCount else {
                searchLines.append(SearchLine(
                    lineNumber: lineNumber,
                    line: line,
                    rawLine: rawLine,
                    lineTerminator: splitLine.terminator,
                    absoluteOffset: absoluteOffset,
                    positiveSpans: positiveSpans
                ))
                absoluteOffset += lineByteCount
                continue
            }

            let rawSpans = syntheticInlineCRLFBoundarySpans(
                crlfTrimmedSpans(
                    unicodeWordBoundedSpans(
                        adjustedSpans(
                            matcher.spans(in: lineForMatching),
                            rawLine: rawLineForSpanAdjustment,
                            options: options
                        ),
                        decodedLine: line,
                        matcher: matcher,
                        rawLine: rawLineForSpanAdjustment,
                        options: options
                    ),
                    line: line,
                    options: options
                ),
                line: line,
                terminator: splitLine.terminator,
                matcher: matcher,
                options: options
            )
            let nullDataRecordAdjusted = nullDataRecordAnchorSpans(
                rawSpans,
                matchingLine: matchingRawLine ?? lineForMatching,
                absoluteOffset: absoluteOffset,
                terminator: splitLine.terminator,
                options: options
            )
            let syntheticAdjusted = syntheticBinarySplitSpans(
                nullDataRecordAdjusted.spans,
                line: matchingRawLine ?? lineForMatching,
                terminator: splitLine.terminator,
                splitBinaryNUL: shouldSplitBinaryNUL,
                options: options
            )
            let firstLineAdjusted = absoluteStartFirstLineSpans(
                syntheticAdjusted.spans,
                lineNumber: lineNumber,
                options: options
            )
            let absoluteStartAdjusted = absoluteStartTrimmedSpans(
                firstLineAdjusted,
                lineNumber: lineNumber,
                options: options
            )
            let spans = absoluteStartAdjusted.spans
            searchLines.append(SearchLine(
                lineNumber: lineNumber,
                line: line,
                rawLine: rawLine,
                lineTerminator: splitLine.terminator,
                absoluteOffset: absoluteOffset,
                positiveSpans: positiveSpans
            ))
            let preserveMatchedLine = nullDataRecordAdjusted.preserveMatchedLine
                || syntheticAdjusted.preserveMatchedLine
                || absoluteStartAdjusted.preserveMatchedLine
            let positiveMatched = options.invertMatch && options.stopOnNonmatch
                ? !positiveSpans.isEmpty
                : (!spans.isEmpty || preserveMatchedLine)
            guard !spans.isEmpty || preserveMatchedLine else {
                absoluteOffset += lineByteCount
                if options.stopOnNonmatch && !options.invertMatch && hasMatched {
                    break
                }
                if positiveMatched {
                    if hasMatched {
                        positiveRunAfterInvertedMatch += 1
                    }
                } else {
                    positiveRunAfterInvertedMatch = 0
                }
                continue
            }

            if options.stopOnNonmatch,
               options.invertMatch,
               positiveRunAfterInvertedMatch > 1 {
                break
            }

            hasMatched = true
            matches.append(SearchMatch(
                fileURL: fileURL,
                lineNumber: lineNumber,
                column: options.column && !options.invertMatch ? spans.first?.startColumn : nil,
                line: line,
                rawLine: rawLine,
                lineTerminator: splitLine.terminator,
                absoluteOffset: absoluteOffset,
                matchCount: spans.count,
                spans: spans
            ))
            absoluteOffset += lineByteCount
            if matches.count == maxCount {
                bytesSearchedThroughMaxCount = absoluteOffset
            }
            if options.stopOnNonmatch && options.invertMatch && positiveRunAfterInvertedMatch > 0 {
                break
            }
            positiveRunAfterInvertedMatch = 0
        }

        return SearchFileResult(
            fileURL: fileURL,
            matches: matches,
            lines: searchLines,
            bytesSearched: bytesSearched(
                lines: searchLines,
                matches: matches,
                bytesSearchedThroughMaxCount: bytesSearchedThroughMaxCount,
                totalBytes: absoluteOffset,
                options: options
            ),
            supplementalMatchedLines: supplementalMatchedLineCount(
                lines: searchLines,
                matches: matches,
                options: options
            ),
            supplementalMatches: supplementalMatchCount(
                lines: searchLines,
                matches: matches,
                options: options
            )
        )
    }

    private func bytesSearched(
        lines: [SearchLine],
        matches: [SearchMatch],
        bytesSearchedThroughMaxCount: Int?,
        totalBytes: Int,
        options: RipgrepOptions
    ) -> Int {
        if options.passthru {
            return totalBytes
        }
        guard let bytesSearchedThroughMaxCount else {
            return totalBytes
        }
        guard options.beforeContext > 0 || options.afterContext > 0 else {
            return bytesSearchedThroughMaxCount
        }
        let selected = selectedContextLineNumbers(lineCount: lines.count, matches: matches, options: options)
        guard let lastLineNumber = selected.max(),
              let line = lines.first(where: { $0.lineNumber == lastLineNumber }) else {
            return bytesSearchedThroughMaxCount
        }
        return line.absoluteOffset + byteCount(line.line, options: options) + byteCount(line.lineTerminator, options: options)
    }

    private func nullDataRecordAnchorSpans(
        _ spans: [MatchSpan],
        matchingLine: String,
        absoluteOffset: Int,
        terminator: String,
        options: RipgrepOptions
    ) -> (spans: [MatchSpan], preserveMatchedLine: Bool) {
        guard options.nullData, !options.multiline, !spans.isEmpty else {
            return (spans, false)
        }
        if options.effectivePatterns.contains(where: containsLineStartAnchor),
           !options.effectivePatterns.contains(where: containsLineEndAnchor) {
            let bytes = Array(matchingLine.utf8)
            let filtered = spans.filter { span in
                guard span.text.isEmpty,
                      span.startByte == span.endByte,
                      span.startByte > 0,
                      span.startByte < bytes.count else {
                    return true
                }
                return bytes[span.startByte - 1] != UInt8(ascii: "\n")
            }
            if filtered.isEmpty || filtered.count != spans.count {
                return (filtered, filtered.isEmpty)
            }
        }
        if !terminator.isEmpty,
           options.effectivePatterns.contains(where: containsRecordEndConstrainedAnchor) {
            let recordEnd = byteCount(matchingLine, options: options)
            let filtered = spans.filter {
                $0.endByte < recordEnd
                    || canMatchNonFinalNullDataRecordEnd(matchingLine, options: options)
            }
            return (filtered, false)
        }
        if terminator.isEmpty,
           lastScalar(in: matchingLine, equals: "\n"),
           !options.effectivePatterns.contains(where: containsLineStartAndEndAnchor) {
            let trailingRecordEnd = byteCount(matchingLine, options: options)
            let filtered = spans.filter {
                !($0.text.isEmpty
                    && $0.startByte == $0.endByte
                    && $0.startByte >= trailingRecordEnd)
            }
            return (filtered, filtered.isEmpty && filtered.count != spans.count)
        }
        if options.effectivePatterns.contains(where: containsLineStartAndEndAnchor) {
            if options.effectivePatterns.contains(where: containsLineStartEndAlternation),
               options.onlyMatching || options.printMode == .countMatches || options.json {
                return (
                    nullDataLineStartEndAlternationSpans(
                        spans,
                        matchingLine: matchingLine,
                        absoluteOffset: absoluteOffset,
                        terminator: terminator,
                        options: options
                    ),
                    false
                )
            }
            if matchingLine == "\n",
               spans.contains(where: { $0.startByte == 0 && $0.endByte == 0 && $0.text.isEmpty }) {
                return (spans.filter { $0.startByte == 0 && $0.endByte == 0 && $0.text.isEmpty }, false)
            }
            return ([], true)
        }
        guard absoluteOffset > 0,
              options.effectivePatterns.contains(where: containsLineStartAnchor) else {
            return (spans, false)
        }
        let filtered = spans.filter {
            !($0.startByte == 0
                && $0.endByte > 0
                && (!matchingLine.contains("\n") || spans.count > 1))
        }
        return (filtered, filtered.isEmpty && filtered.count != spans.count)
    }

    private func nullDataLineStartEndAlternationSpans(
        _ spans: [MatchSpan],
        matchingLine: String,
        absoluteOffset: Int,
        terminator: String,
        options: RipgrepOptions
    ) -> [MatchSpan] {
        let recordEnd = byteCount(matchingLine, options: options)
        return spans.filter { span in
            guard span.text.isEmpty,
                  span.startByte == span.endByte else {
                return true
            }
            if absoluteOffset > 0,
               !terminator.isEmpty,
               matchingLine.contains("\n"),
               span.startByte == 0 {
                return false
            }
            if terminator.isEmpty,
               lastScalar(in: matchingLine, equals: "\n"),
               span.startByte >= recordEnd {
                return false
            }
            return true
        }
    }

    private func containsLineStartEndAlternation(_ pattern: String) -> Bool {
        let alternatives = topLevelAlternatives(in: pattern)
        guard alternatives.count > 1 else {
            return false
        }
        return alternatives.contains(where: containsLineStartAnchor)
            && alternatives.contains(where: containsLineEndAnchor)
    }

    private func crlfTrimmedSpans(
        _ spans: [MatchSpan],
        line: String,
        options: RipgrepOptions
    ) -> [MatchSpan] {
        guard options.crlf,
              !options.multiline,
              !options.nullData,
              line.hasSuffix("\r") else {
            return spans
        }
        let lineEnd = byteCount(line, options: options)
        let crlfLineEndSpans = spans.filter {
            !($0.text.isEmpty
                && $0.startByte == lineEnd
                && $0.endByte == lineEnd)
        }
        return crlfLineEndSpans.compactMap { span in
            guard span.endByte == lineEnd,
                  span.startByte < span.endByte,
                  span.text.hasSuffix("\r") else {
                return span
            }
            let endByte = lineEnd - 1
            guard endByte > span.startByte else {
                return nil
            }
            return MatchSpan(
                startColumn: span.startColumn,
                endColumn: max(span.startColumn, span.endColumn - 1),
                startByte: span.startByte,
                endByte: endByte,
                text: String(span.text.dropLast()),
                replacement: span.replacement
            )
        }
    }

    private func unicodeWordBoundedSpans(
        _ spans: [MatchSpan],
        decodedLine: String,
        matcher: PatternMatcher,
        rawLine: String?,
        options: RipgrepOptions
    ) -> [MatchSpan] {
        guard options.wordRegexp,
              !options.noUnicode,
              matcher.usesByteSemantics,
              rawLine == nil else {
            return spans
        }
        return spans.filter { isUnicodeWordBounded($0, in: decodedLine) }
    }

    private func isUnicodeWordBounded(_ span: MatchSpan, in line: String) -> Bool {
        guard let lower = utf8Index(in: line, atByteOffset: span.startByte),
              let upper = utf8Index(in: line, atByteOffset: span.endByte) else {
            return false
        }
        let before = lower == line.startIndex ? nil : line[line.index(before: lower)]
        let after = upper == line.endIndex ? nil : line[upper]
        if lower == upper {
            return !isUnicodeWordCharacter(before) && !isUnicodeWordCharacter(after)
        }

        let matched = line[lower..<upper]
        guard matched.contains(where: { isUnicodeWordCharacter($0) }) else {
            return false
        }
        if let first = matched.first,
           isUnicodeWordCharacter(first),
           isUnicodeWordCharacter(before) {
            return false
        }
        if let last = matched.last,
           isUnicodeWordCharacter(last),
           isUnicodeWordCharacter(after) {
            return false
        }
        return true
    }

    private func isUnicodeWordCharacter(_ character: Character?) -> Bool {
        guard let character else {
            return false
        }
        return character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || CharacterSet.nonBaseCharacters.contains($0)
                || $0 == "_"
        }
    }

    private func utf8Index(in line: String, atByteOffset byteOffset: Int) -> String.Index? {
        guard byteOffset >= 0 else {
            return nil
        }
        var bytes = 0
        for index in line.indices {
            if bytes == byteOffset {
                return index
            }
            bytes += line[index].utf8.count
        }
        return bytes == byteOffset ? line.endIndex : nil
    }

    private func syntheticInlineCRLFBoundarySpans(
        _ spans: [MatchSpan],
        line: String,
        terminator: String,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> [MatchSpan] {
        guard !options.multiline,
              !options.wordRegexp,
              !options.lineRegexp,
              line.hasSuffix("\r"),
              terminator == "\n",
              options.effectivePatterns.contains(where: isBareInlineCRLFLineAnchorPattern) else {
            return spans
        }
        let lineEnd = byteCount(line, options: options)
        guard !spans.contains(where: { $0.startByte == lineEnd && $0.endByte == lineEnd }) else {
            return spans
        }
        return spans + [
            MatchSpan(
                startColumn: lineEnd + 1,
                endColumn: lineEnd + 1,
                startByte: lineEnd,
                endByte: lineEnd,
                text: "",
                replacement: matcher.syntheticEmptyReplacement(atEndOf: line)
            ),
        ]
    }

    private func syntheticBinarySplitSpans(
        _ spans: [MatchSpan],
        line: String,
        terminator: String,
        splitBinaryNUL: Bool,
        options: RipgrepOptions
    ) -> (spans: [MatchSpan], preserveMatchedLine: Bool) {
        guard splitBinaryNUL,
              terminator.isEmpty,
              !line.isEmpty,
              !spans.isEmpty else {
            return (spans, false)
        }
        if options.printMode == .countMatches,
           !options.json,
           options.effectivePatterns.contains(where: containsLineEndAnchor) {
            return (spans, false)
        }
        let lineEnd = byteCount(line, options: options)
        let filtered = spans.filter {
            !($0.startByte == lineEnd && $0.endByte == lineEnd && $0.text.isEmpty)
        }
        return (filtered, filtered.isEmpty && !spans.isEmpty)
    }

    private func absoluteStartTrimmedSpans(
        _ spans: [MatchSpan],
        lineNumber: Int,
        options: RipgrepOptions
    ) -> (spans: [MatchSpan], preserveMatchedLine: Bool) {
        guard lineNumber > 1,
              !options.multiline,
              options.effectivePatterns.contains(where: containsAbsoluteStartAnchor),
              !spans.isEmpty else {
            return (spans, false)
        }
        let filtered = spans.filter {
            !($0.startByte == 0 && $0.endByte == 0 && $0.text.isEmpty)
        }
        return (filtered, filtered.isEmpty && !spans.isEmpty)
    }

    private func absoluteStartFirstLineSpans(
        _ spans: [MatchSpan],
        lineNumber: Int,
        options: RipgrepOptions
    ) -> [MatchSpan] {
        guard lineNumber == 1,
              spans.contains(where: { $0.startByte == 0 && $0.endByte == 0 && $0.text.isEmpty }),
              spans.contains(where: { $0.startByte == 0 && !$0.text.isEmpty }),
              options.effectivePatterns.contains(where: containsAbsoluteStartAnchor) else {
            return spans
        }
        if options.effectivePatterns.contains(where: startsWithAbsoluteStartAlternative) {
            return spans.filter {
                !($0.startByte == 0 && !$0.text.isEmpty)
            }
        }
        return spans.filter {
            !($0.startByte == 0 && $0.endByte == 0 && $0.text.isEmpty)
        }
    }

    private func containsAbsoluteStartAnchor(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        for character in pattern {
            if escaped {
                if !inClass && character == "A" {
                    return true
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "[" {
                inClass = true
                continue
            }
            if character == "]" {
                inClass = false
            }
        }
        return false
    }

    private func containsLineStartAnchor(_ pattern: String) -> Bool {
        containsAnchor("^", in: pattern)
    }

    private func containsLineEndAnchor(_ pattern: String) -> Bool {
        containsAnchor("$", in: pattern)
    }

    private func containsLineStartAndEndAnchor(_ pattern: String) -> Bool {
        containsLineStartAnchor(pattern) && containsLineEndAnchor(pattern)
    }

    private func containsLineAnchor(_ pattern: String) -> Bool {
        containsAnchor("^", in: pattern) || containsAnchor("$", in: pattern)
    }

    private func containsDisabledMultilineLineEndAnchor(_ pattern: String) -> Bool {
        containsDisabledMultilineLineEndAnchor(in: pattern, multilineEnabled: true)
    }

    private func containsRecordEndConstrainedAnchor(_ pattern: String) -> Bool {
        containsDisabledMultilineLineEndAnchor(pattern) || containsAbsoluteEndAnchor(pattern)
    }

    private func canMatchNonFinalNullDataRecordEnd(_ matchingLine: String, options: RipgrepOptions) -> Bool {
        options.effectivePatterns.contains { pattern in
            topLevelAlternatives(in: pattern).contains { alternative in
                guard !containsRecordEndConstrainedAnchor(alternative),
                      !containsLineEndAnchor(alternative) else {
                    return false
                }
                return alternativeMatches(alternative, in: matchingLine, options: options)
            }
        }
    }

    private func alternativeMatches(_ alternative: String, in text: String, options: RipgrepOptions) -> Bool {
        var alternativeOptions = options
        alternativeOptions.pattern = alternative
        alternativeOptions.patterns = []
        alternativeOptions.invertMatch = false
        alternativeOptions.replacement = nil
        guard let matcher = try? PatternMatcher(options: alternativeOptions) else {
            return false
        }
        return !matcher.spans(in: text).isEmpty
    }

    private func containsAbsoluteEndAnchor(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        for character in pattern {
            if escaped {
                if !inClass && character == "z" {
                    return true
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "[" {
                inClass = true
                continue
            }
            if character == "]" {
                inClass = false
            }
        }
        return false
    }

    private func containsDisabledMultilineLineEndAnchor(in pattern: String, multilineEnabled: Bool) -> Bool {
        var escaped = false
        var inClass = false
        var currentMultilineEnabled = multilineEnabled
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                index = pattern.index(after: index)
                continue
            }
            if !inClass,
               character == "(",
               let flags = inlineMultilineFlags(in: pattern, openingAt: index) {
                if flags.scoped, let close = flags.close {
                    let scopedMultilineEnabled = flags.multilineEnabled ?? currentMultilineEnabled
                    if containsDisabledMultilineLineEndAnchor(
                        in: String(pattern[flags.bodyStart..<close]),
                        multilineEnabled: scopedMultilineEnabled
                    ) {
                        return true
                    }
                    index = flags.end
                    continue
                }
                if let flagMultilineEnabled = flags.multilineEnabled {
                    currentMultilineEnabled = flagMultilineEnabled
                }
                index = flags.end
                continue
            }
            if !inClass, character == "$", !currentMultilineEnabled {
                return true
            }
            index = pattern.index(after: index)
        }
        return false
    }

    private func isBareInlineCRLFLineAnchorPattern(_ pattern: String) -> Bool {
        if pattern.hasPrefix("(?"),
           let close = pattern.firstIndex(of: ")") {
            let flagStart = pattern.index(pattern.startIndex, offsetBy: 2)
            let flags = pattern[flagStart..<close]
            let rest = pattern[pattern.index(after: close)...]
            if flags.contains("R"), rest == "$" {
                return true
            }
        }
        guard pattern.hasPrefix("(?"),
              pattern.hasSuffix(")"),
              let colon = pattern.firstIndex(of: ":") else {
            return false
        }
        let flagStart = pattern.index(pattern.startIndex, offsetBy: 2)
        let flags = pattern[flagStart..<colon]
        let bodyStart = pattern.index(after: colon)
        let body = pattern[bodyStart..<pattern.index(before: pattern.endIndex)]
        return flags.contains("R") && body == "$"
    }

    private func isMultilineBinaryBoundaryPattern(_ pattern: String) -> Bool {
        containsLineAnchor(pattern) || containsLineTerminatorOutsideCharacterClass(pattern)
    }

    private func containsLineTerminatorOutsideCharacterClass(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        for character in pattern {
            if escaped {
                if !inClass && character == "n" {
                    return true
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "[" {
                inClass = true
                continue
            }
            if character == "]" {
                inClass = false
                continue
            }
            if !inClass && character == "\n" {
                return true
            }
        }
        return false
    }

    private func containsAnchor(_ anchor: Character, in pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        for character in pattern {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "[" {
                inClass = true
                continue
            }
            if character == "]" {
                inClass = false
                continue
            }
            if !inClass && character == anchor {
                return true
            }
        }
        return false
    }

    private func inlineMultilineFlags(
        in pattern: String,
        openingAt opening: String.Index
    ) -> (scoped: Bool, multilineEnabled: Bool?, bodyStart: String.Index, close: String.Index?, end: String.Index)? {
        let question = pattern.index(after: opening)
        guard question < pattern.endIndex, pattern[question] == "?" else {
            return nil
        }

        var cursor = pattern.index(after: question)
        var disabling = false
        var multilineEnabled: Bool?
        while cursor < pattern.endIndex {
            let character = pattern[cursor]
            if character == ":" {
                guard let close = closingGroupIndex(in: pattern, openingAt: opening) else {
                    return nil
                }
                return (
                    scoped: true,
                    multilineEnabled: multilineEnabled,
                    bodyStart: pattern.index(after: cursor),
                    close: close,
                    end: pattern.index(after: close)
                )
            }
            if character == ")" {
                return (
                    scoped: false,
                    multilineEnabled: multilineEnabled,
                    bodyStart: cursor,
                    close: nil,
                    end: pattern.index(after: cursor)
                )
            }
            guard character == "-" || character.isASCII && character.isLetter else {
                return nil
            }
            if character == "-" {
                disabling = true
            } else if character == "m" {
                multilineEnabled = !disabling
            }
            cursor = pattern.index(after: cursor)
        }
        return nil
    }

    private func closingGroupIndex(in pattern: String, openingAt opening: String.Index) -> String.Index? {
        var escaped = false
        var inClass = false
        var depth = 0
        var index = opening

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if character == "[" {
                inClass = true
                index = pattern.index(after: index)
                continue
            }
            if character == "]" {
                inClass = false
                index = pattern.index(after: index)
                continue
            }
            if !inClass, character == "(" {
                depth += 1
            } else if !inClass, character == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = pattern.index(after: index)
        }
        return nil
    }

    private func unwrappedSingleGroupPattern(_ pattern: String) -> String? {
        for prefix in ["(?:", "(?m:", "(?-m:"] where pattern.hasPrefix(prefix) && pattern.hasSuffix(")") {
            let start = pattern.index(pattern.startIndex, offsetBy: prefix.count)
            return String(pattern[start..<pattern.index(before: pattern.endIndex)])
        }
        return nil
    }

    private func startsWithAbsoluteStartAlternative(_ pattern: String) -> Bool {
        topLevelAlternatives(in: pattern).first.map(isAbsoluteStartAlternative) ?? false
    }

    private func isAbsoluteStartAlternative(_ pattern: String) -> Bool {
        switch pattern {
        case "\\A":
            return true
        default:
            return unwrappedSingleGroupPattern(pattern).map(isAbsoluteStartAlternative) ?? false
        }
    }

    private func topLevelAlternatives(in pattern: String) -> [String] {
        var alternatives: [String] = []
        var start = pattern.startIndex
        var index = pattern.startIndex
        var escaped = false
        var inClass = false
        var depth = 0

        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
                index = pattern.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = pattern.index(after: index)
                continue
            }
            if inClass {
                if character == "]" {
                    inClass = false
                }
                index = pattern.index(after: index)
                continue
            }
            switch character {
            case "[":
                inClass = true
            case "(":
                depth += 1
            case ")":
                depth = max(0, depth - 1)
            case "|" where depth == 0:
                alternatives.append(String(pattern[start..<index]))
                start = pattern.index(after: index)
            default:
                break
            }
            index = pattern.index(after: index)
        }

        guard !alternatives.isEmpty else {
            return [pattern]
        }
        alternatives.append(String(pattern[start..<pattern.endIndex]))
        return alternatives
    }

    private func supplementalMatchedLineCount(
        lines: [SearchLine],
        matches: [SearchMatch],
        options: RipgrepOptions
    ) -> Int {
        supplementalMatchingContextLines(lines: lines, matches: matches, options: options).count
    }

    private func supplementalMatchCount(
        lines: [SearchLine],
        matches: [SearchMatch],
        options: RipgrepOptions
    ) -> Int {
        supplementalMatchingContextLines(lines: lines, matches: matches, options: options)
            .reduce(0) { $0 + $1.positiveSpans.count }
    }

    private func supplementalMatchingContextLines(
        lines: [SearchLine],
        matches: [SearchMatch],
        options: RipgrepOptions
    ) -> [SearchLine] {
        guard !options.passthru,
              !options.invertMatch,
              options.beforeContext > 0 || options.afterContext > 0 else {
            return []
        }
        if options.multiline,
           options.maxCount == nil,
           options.effectivePatterns.contains(where: containsLineAnchor) {
            return []
        }
        if options.multiline,
           matches.count == 1,
           let match = matches.first,
           match.absoluteOffset == 0,
           let matchEnd = match.spans.map(\.endByte).max(),
           matchEnd >= byteCount(match.lineWithTerminator, options: options) {
            return []
        }
        let matchedLineNumbers = Set(matches.flatMap { multilineMatchedLineNumbers(for: $0, options: options) })
        let selected = selectedContextLineNumbers(lineCount: lines.count, matches: matches, options: options)
        return lines.filter {
            selected.contains($0.lineNumber)
                && !matchedLineNumbers.contains($0.lineNumber)
                && !$0.positiveSpans.isEmpty
        }
    }

    private func multilineMatchedLineNumbers(for match: SearchMatch, options: RipgrepOptions) -> [Int] {
        guard options.multiline else {
            return [match.lineNumber]
        }
        let separator: Character = options.nullData ? "\0" : "\n"
        let text = match.lineWithTerminator
        let separatorCount = text.filter { $0 == separator }.count
        let lineCount = separatorCount + (text.last == separator ? 0 : 1)
        return Array(match.lineNumber..<(match.lineNumber + max(1, lineCount)))
    }

    private func selectedContextLineNumbers(
        lineCount: Int,
        matches: [SearchMatch],
        options: RipgrepOptions
    ) -> Set<Int> {
        matches.reduce(into: Set<Int>()) { lineNumbers, match in
            let lower = max(1, match.lineNumber - options.beforeContext)
            let upper = min(lineCount, match.lineNumber + options.afterContext)
            for lineNumber in lower...upper {
                lineNumbers.insert(lineNumber)
            }
        }
    }

    private func searchMultilineContents(
        _ contents: String,
        rawData: Data? = nil,
        rawDataForMatching: Data? = nil,
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions,
        splitBinaryNUL: Bool = false
    ) -> SearchFileResult {
        let split = splitLines(contents, options: options, splitBinaryNUL: splitBinaryNUL)
        let outputRawSplit = rawData.map { splitRawLines($0, options: options, splitBinaryNUL: splitBinaryNUL) }
        let matchingRawSplit = rawDataForMatching.map { splitRawLines($0, options: options, splitBinaryNUL: splitBinaryNUL) }
        let splitMatchingContents = split.map { $0.text + $0.terminator }.joined()
        let matchingContents = matcher.usesByteSemantics
            ? matchingRawSplit?.map { $0.text + $0.terminator }.joined() ?? contents
            : splitBinaryNUL ? splitMatchingContents : contents
        let rawContentsForSpanAdjustment = matcher.usesByteSemantics
            ? nil
            : matchingRawSplit?.map { $0.text + $0.terminator }.joined()
        var searchLines: [SearchLine] = []
        var lineStartOffsets: [Int] = []
        var absoluteOffset = 0

        for (offset, splitLine) in split.enumerated() {
            let outputRawLine = outputRawSplit?[safe: offset]
            let matchingRawLine = matchingRawSplit?[safe: offset]
            lineStartOffsets.append(absoluteOffset)
            searchLines.append(SearchLine(
                lineNumber: offset + 1,
                line: splitLine.text,
                rawLine: outputRawLine?.text,
                lineTerminator: splitLine.terminator,
                absoluteOffset: absoluteOffset
            ))
            absoluteOffset += matchingRawLine.map {
                $0.text.unicodeScalars.count + $0.terminator.unicodeScalars.count
            } ?? byteCount(splitLine.text, options: options) + byteCount(splitLine.terminator, options: options)
        }

        let spans = multilineCRLFLineStartTrimmedSpans(
            adjustedSpans(
                options.invertMatch
                    ? matcher.positiveSpans(in: matchingContents)
                    : matcher.spans(in: matchingContents),
                rawLine: rawContentsForSpanAdjustment,
                options: options
            ),
            in: matchingContents,
            options: options
        )
        if !options.invertMatch,
           spans.isEmpty,
           let preserved = multilineBinaryEndAnchorMatch(
               contents: matchingContents,
               fileURL: fileURL,
               lines: searchLines,
               options: options
           ) {
            return SearchFileResult(
                fileURL: fileURL,
                matches: [preserved],
                lines: searchLines,
                bytesSearched: absoluteOffset
            )
        }
        let standardLineEndColumn = multilineStandardLineEndColumn(
            spans: spans,
            lines: searchLines,
            lineStartOffsets: lineStartOffsets,
            options: options
        )
        let positiveSpansByLine = multilinePositiveSpansByLine(
            spans: spans,
            lines: searchLines,
            lineStartOffsets: lineStartOffsets,
            options: options
        )
        let searchLinesWithPositiveSpans = searchLines.map { line in
            SearchLine(
                lineNumber: line.lineNumber,
                line: line.line,
                rawLine: line.rawLine,
                lineTerminator: line.lineTerminator,
                absoluteOffset: line.absoluteOffset,
                positiveSpans: positiveSpansByLine[line.lineNumber] ?? []
            )
        }
        if options.invertMatch {
            return invertedMultilineSearchResult(
                fileURL: fileURL,
                lines: searchLinesWithPositiveSpans,
                positiveSpans: spans,
                lineStartOffsets: lineStartOffsets,
                totalBytes: absoluteOffset,
                options: options
            )
        }
        let limitedSpans = Array(spans.prefix(options.maxCount ?? Int.max))
        let candidateSpans = options.onlyMatching
            ? multilineOnlyMatchingCandidateSpans(
                spans: spans,
                limitedSpans: limitedSpans,
                lineStartOffsets: lineStartOffsets,
                maxCount: options.maxCount
            )
            : limitedSpans
        if options.replacement != nil, !options.onlyMatching {
            let replacementSpans = multilineReplacementCandidateSpans(
                spans: spans,
                lineStartOffsets: lineStartOffsets,
                maxCount: options.maxCount
            )
            let candidates = replacementSpans.compactMap { span -> MultilineSpanCandidate? in
                guard let startLineIndex = lineIndex(containingByteOffset: span.startByte, lineStartOffsets: lineStartOffsets),
                      let endLineIndex = endLineIndex(for: span, lineStartOffsets: lineStartOffsets) else {
                    return nil
                }
                return MultilineSpanCandidate(span: span, startLineIndex: startLineIndex, endLineIndex: endLineIndex)
            }
            let grouped = groupedOverlappingLineSpans(
                candidates,
                splitSeparatedTrailingLineMatches: false,
                mergeAdjacentLineSpans: false
            )
            let matches = grouped.compactMap { group -> SearchMatch? in
                guard let first = group.first else {
                    return nil
                }
                let startLineIndex = first.startLineIndex
                let endLineIndex = group.reduce(first.endLineIndex) { max($0, $1.endLineIndex) }
                let blockText = multilineReplacementBlockText(
                    lines: searchLines,
                    startLineIndex: startLineIndex,
                    endLineIndex: endLineIndex,
                    group: group,
                    options: options
                )
                let rawBlockText = multilineReplacementRawBlockText(
                    lines: searchLines,
                    startLineIndex: startLineIndex,
                    endLineIndex: endLineIndex,
                    group: group,
                    options: options
                )
                let blockOffset = searchLines[startLineIndex].absoluteOffset
                let adjustedSpans = group.map { candidate in
                    let startByte = candidate.span.startByte - blockOffset
                    let endByte = candidate.span.endByte - blockOffset
                    return MatchSpan(
                        startColumn: column(in: blockText, byteOffset: startByte, options: options),
                        endColumn: column(in: blockText, byteOffset: endByte, options: options),
                        startByte: startByte,
                        endByte: endByte,
                        text: candidate.span.text,
                        replacement: candidate.span.replacement
                    )
                }

                return SearchMatch(
                    fileURL: fileURL,
                    lineNumber: startLineIndex + 1,
                    column: options.column ? standardLineEndColumn ?? adjustedSpans.first?.startColumn : nil,
                    line: blockText,
                    rawLine: rawBlockText,
                    lineTerminator: searchLines[endLineIndex].lineTerminator,
                    absoluteOffset: blockOffset,
                    matchCount: multilineMatchCount(
                        for: group,
                        contentEndOffset: absoluteOffset,
                        lineCount: searchLines.count,
                        options: options
                    ),
                    spans: adjustedSpans
                )
            }
            return SearchFileResult(
                fileURL: fileURL,
                matches: matches,
                lines: searchLinesWithPositiveSpans,
                bytesSearched: multilineBytesSearched(
                    lines: searchLinesWithPositiveSpans,
                    matches: matches,
                    limitedSpans: replacementSpans,
                    totalBytes: absoluteOffset,
                    options: options
                ),
                supplementalMatchedLines: supplementalMatchedLineCount(
                    lines: searchLinesWithPositiveSpans,
                    matches: matches,
                    options: options
                ),
                supplementalMatches: supplementalMatchCount(
                    lines: searchLinesWithPositiveSpans,
                    matches: matches,
                    options: options
                )
            )
        }

        let candidates = candidateSpans.compactMap { span -> MultilineSpanCandidate? in
            guard let startLineIndex = lineIndex(containingByteOffset: span.startByte, lineStartOffsets: lineStartOffsets),
                  let endLineIndex = endLineIndex(for: span, lineStartOffsets: lineStartOffsets) else {
                return nil
            }
            if options.onlyMatching,
               isLineTerminatorOnlySpan(span, in: searchLines, lineIndex: startLineIndex, options: options) {
                return nil
            }
            return MultilineSpanCandidate(span: span, startLineIndex: startLineIndex, endLineIndex: endLineIndex)
        }
        let shouldGroupLineAnchors = shouldGroupMultilineJSONLineAnchorSpans(candidates, options: options)
        let shouldGroupNULPattern = shouldGroupMultilineJSONNULPatternSpans(candidates, options: options)
        let shouldGroupAdjacentOnlyMatchingLineAnchors = options.onlyMatching
            && options.effectivePatterns.contains(where: containsLineAnchor)
        let groups = shouldGroupLineAnchors || shouldGroupNULPattern
            ? [candidates]
            : groupedOverlappingLineSpans(
                candidates,
                splitSeparatedTrailingLineMatches: true,
                mergeAdjacentLineSpans: shouldGroupAdjacentOnlyMatchingLineAnchors
            )
        let matches = groups.compactMap { group -> SearchMatch? in
            guard let first = group.first else {
                return nil
            }
            let startLineIndex = first.startLineIndex
            let endLineIndex = shouldGroupLineAnchors || shouldGroupNULPattern
                ? searchLines.count - 1
                : group.reduce(first.endLineIndex) { max($0, $1.endLineIndex) }
            let blockText = multilineReplacementBlockText(
                lines: searchLines,
                startLineIndex: startLineIndex,
                endLineIndex: endLineIndex,
                group: group,
                options: options
            )
            let rawBlockText = multilineReplacementRawBlockText(
                lines: searchLines,
                startLineIndex: startLineIndex,
                endLineIndex: endLineIndex,
                group: group,
                options: options
            )
            let blockOffset = searchLines[startLineIndex].absoluteOffset
            let adjustedSpans = group.map { candidate in
                let startByte = candidate.span.startByte - blockOffset
                let endByte = candidate.span.endByte - blockOffset
                return MatchSpan(
                    startColumn: column(in: blockText, byteOffset: startByte, options: options),
                    endColumn: column(in: blockText, byteOffset: endByte, options: options),
                    startByte: startByte,
                    endByte: endByte,
                    text: candidate.span.text,
                    replacement: candidate.span.replacement
                )
            }
            let endLine = searchLines[endLineIndex]
            let endLineTextEnd = lineTextEndOffset(endLine, options: options)
            let includesEndTerminator = group.contains { $0.span.endByte > endLineTextEnd }
            let reachesEndLineText = group.contains { $0.span.endByte > endLine.absoluteOffset }
            let shouldUseEndLineTerminator = shouldGroupLineAnchors
                || (!includesEndTerminator && (startLineIndex == endLineIndex || reachesEndLineText))
            let lineTerminator = shouldUseEndLineTerminator ? endLine.lineTerminator : ""

            return SearchMatch(
                fileURL: fileURL,
                lineNumber: startLineIndex + 1,
                column: options.column ? standardLineEndColumn ?? adjustedSpans.first?.startColumn : nil,
                line: blockText,
                rawLine: rawBlockText,
                lineTerminator: lineTerminator,
                absoluteOffset: blockOffset,
                matchCount: multilineMatchCount(
                    for: group,
                    contentEndOffset: absoluteOffset,
                    lineCount: searchLines.count,
                    options: options
                ),
                spans: adjustedSpans
            )
        }

        return SearchFileResult(
            fileURL: fileURL,
            matches: matches,
            lines: searchLinesWithPositiveSpans,
            bytesSearched: multilineBytesSearched(
                lines: searchLinesWithPositiveSpans,
                matches: matches,
                limitedSpans: limitedSpans,
                totalBytes: absoluteOffset,
                options: options
            ),
            supplementalMatchedLines: supplementalMatchedLineCount(
                lines: searchLinesWithPositiveSpans,
                matches: matches,
                options: options
            ),
            supplementalMatches: supplementalMatchCount(
                lines: searchLinesWithPositiveSpans,
                matches: matches,
                options: options
            )
        )
    }

    private func invertedMultilineSearchResult(
        fileURL: URL,
        lines: [SearchLine],
        positiveSpans: [MatchSpan],
        lineStartOffsets: [Int],
        totalBytes: Int,
        options: RipgrepOptions
    ) -> SearchFileResult {
        let positiveLineNumbers = Set(positiveSpans.flatMap { span -> [Int] in
            guard let startLineIndex = lineIndex(containingByteOffset: span.startByte, lineStartOffsets: lineStartOffsets),
                  let endLineIndex = invertedMultilineEndLineIndex(for: span, lineStartOffsets: lineStartOffsets) else {
                return []
            }
            return Array((startLineIndex + 1)...(endLineIndex + 1))
        })
        let maxCount = options.maxCount ?? Int.max
        let matches = lines.compactMap { line -> SearchMatch? in
            guard !positiveLineNumbers.contains(line.lineNumber) else {
                return nil
            }
            return SearchMatch(
                fileURL: fileURL,
                lineNumber: line.lineNumber,
                column: nil,
                line: line.line,
                rawLine: line.rawLine,
                lineTerminator: line.lineTerminator,
                absoluteOffset: line.absoluteOffset,
                matchCount: 1,
                spans: [
                    MatchSpan(
                        startColumn: 1,
                        endColumn: 1,
                        startByte: 0,
                        endByte: 0,
                        text: "",
                        replacement: nil
                    ),
                ]
            )
        }.prefix(maxCount)

        return SearchFileResult(
            fileURL: fileURL,
            matches: Array(matches),
            lines: lines,
            bytesSearched: totalBytes
        )
    }

    private func invertedMultilineEndLineIndex(for span: MatchSpan, lineStartOffsets: [Int]) -> Int? {
        if span.endByte > span.startByte,
           lineStartOffsets.contains(span.endByte) {
            return lineIndex(
                containingByteOffset: max(span.endByte - 1, span.startByte),
                lineStartOffsets: lineStartOffsets
            )
        }
        return endLineIndex(for: span, lineStartOffsets: lineStartOffsets)
    }

    private func multilineStandardLineEndColumn(
        spans: [MatchSpan],
        lines: [SearchLine],
        lineStartOffsets: [Int],
        options: RipgrepOptions
    ) -> Int? {
        guard options.multiline,
              options.column,
              !options.vimgrep,
              !options.onlyMatching,
              options.effectivePatterns.contains(where: containsLineEndAnchor),
              let firstSpan = spans.first,
              let lineIndex = lineIndex(containingByteOffset: firstSpan.startByte, lineStartOffsets: lineStartOffsets),
              lineIndex < lines.count else {
            return nil
        }
        let line = lines[lineIndex]
        return column(
            in: line.lineWithTerminator,
            byteOffset: firstSpan.startByte - line.absoluteOffset,
            options: options
        )
    }

    private func multilineBinaryEndAnchorMatch(
        contents: String,
        fileURL: URL,
        lines: [SearchLine],
        options: RipgrepOptions
    ) -> SearchMatch? {
        guard options.multiline,
              !contents.isEmpty,
              contents.contains("\0"),
              !contents.contains("\n"),
              options.effectivePatterns.allSatisfy(isBareMultilineLineEndPattern),
              let line = lines.first else {
            return nil
        }
        return SearchMatch(
            fileURL: fileURL,
            lineNumber: line.lineNumber,
            column: nil,
            line: line.line,
            rawLine: line.rawLine,
            lineTerminator: line.lineTerminator,
            absoluteOffset: line.absoluteOffset,
            matchCount: 0,
            spans: []
        )
    }

    private func multilineBytesSearched(
        lines: [SearchLine],
        matches: [SearchMatch],
        limitedSpans: [MatchSpan],
        totalBytes: Int,
        options: RipgrepOptions
    ) -> Int {
        guard options.maxCount != nil,
              !limitedSpans.isEmpty,
              let lastSpan = limitedSpans.last,
              let line = lines.first(where: { line in
                  lastSpan.startByte >= line.absoluteOffset
                      && lastSpan.endByte <= line.absoluteOffset
                          + byteCount(line.line, options: options)
                          + byteCount(line.lineTerminator, options: options)
              }),
              !options.effectivePatterns.contains(where: hasMultilineLineAnchor) else {
            return totalBytes
        }
        let searchedThrough = line.absoluteOffset + byteCount(line.line, options: options) + byteCount(line.lineTerminator, options: options)
        return bytesSearched(
            lines: lines,
            matches: matches,
            bytesSearchedThroughMaxCount: searchedThrough,
            totalBytes: totalBytes,
            options: options
        )
    }

    private func hasMultilineLineAnchor(_ pattern: String) -> Bool {
        pattern.contains("^") || pattern.contains("$")
    }

    private func multilinePositiveSpansByLine(
        spans: [MatchSpan],
        lines: [SearchLine],
        lineStartOffsets: [Int],
        options: RipgrepOptions
    ) -> [Int: [MatchSpan]] {
        spans.reduce(into: [Int: [MatchSpan]]()) { spansByLine, span in
            guard let startLineIndex = lineIndex(containingByteOffset: span.startByte, lineStartOffsets: lineStartOffsets),
                  let endLineIndex = endLineIndex(for: span, lineStartOffsets: lineStartOffsets),
                  startLineIndex == endLineIndex,
                  startLineIndex < lines.count else {
                return
            }
            let line = lines[startLineIndex]
            let startByte = span.startByte - line.absoluteOffset
            let endByte = span.endByte - line.absoluteOffset
            spansByLine[line.lineNumber, default: []].append(MatchSpan(
                startColumn: column(in: line.lineWithTerminator, byteOffset: startByte, options: options),
                endColumn: column(in: line.lineWithTerminator, byteOffset: endByte, options: options),
                startByte: startByte,
                endByte: endByte,
                text: span.text,
                replacement: span.replacement
            ))
        }
    }

    private func shouldGroupMultilineJSONLineAnchorSpans(
        _ candidates: [MultilineSpanCandidate],
        options: RipgrepOptions
    ) -> Bool {
        options.json
            && options.multiline
            && options.maxCount == nil
            && !candidates.isEmpty
            && options.effectivePatterns.contains(where: containsLineAnchor)
            && candidates.contains { $0.span.startByte == $0.span.endByte && $0.span.text.isEmpty }
    }

    private func shouldGroupMultilineJSONNULPatternSpans(
        _ candidates: [MultilineSpanCandidate],
        options: RipgrepOptions
    ) -> Bool {
        options.json
            && options.multiline
            && options.maxCount == nil
            && !candidates.isEmpty
            && options.effectivePatterns.contains(where: containsNULPattern)
    }

    private func multilineMatchCount(
        for group: [MultilineSpanCandidate],
        contentEndOffset: Int,
        lineCount: Int,
        options: RipgrepOptions
    ) -> Int {
        guard lineCount > 1,
              options.effectivePatterns.contains(where: isBareMultilineLineEndPattern) else {
            return group.count
        }
        return group.filter { candidate in
            !(candidate.span.startByte == contentEndOffset
                && candidate.span.endByte == contentEndOffset
                && candidate.span.text.isEmpty)
        }.count
    }

    private func isBareMultilineLineEndPattern(_ pattern: String) -> Bool {
        if pattern == "$" {
            return true
        }
        guard pattern.hasPrefix("(?"),
              pattern.hasSuffix(")"),
              let colon = pattern.firstIndex(of: ":") else {
            return false
        }
        let flagStart = pattern.index(pattern.startIndex, offsetBy: 2)
        let flags = pattern[flagStart..<colon]
        let bodyStart = pattern.index(after: colon)
        let body = pattern[bodyStart..<pattern.index(before: pattern.endIndex)]
        return flags.contains("m") && body == "$"
    }

    private func multilineCRLFLineStartTrimmedSpans(
        _ spans: [MatchSpan],
        in contents: String,
        options: RipgrepOptions
    ) -> [MatchSpan] {
        guard options.multiline,
              options.effectivePatterns.contains(where: containsLineStartAnchor),
              !options.effectivePatterns.contains(where: containsLineEndAnchor),
              contents.contains("\r\n") else {
            return spans
        }
        let bytes = Array(contents.utf8)
        return spans.filter { span in
            guard span.text.isEmpty,
                  span.startByte == span.endByte,
                  span.startByte > 0,
                  span.startByte < bytes.count else {
                return true
            }
            return !(bytes[span.startByte - 1] == UInt8(ascii: "\r")
                && bytes[span.startByte] == UInt8(ascii: "\n"))
        }
    }

    private func isBareMultilineLineAnchorPattern(_ pattern: String) -> Bool {
        if pattern == "^" || pattern == "$" {
            return true
        }
        if pattern.hasPrefix("(?:"), pattern.hasSuffix(")") {
            let start = pattern.index(pattern.startIndex, offsetBy: 3)
            return isBareMultilineLineAnchorPattern(String(pattern[start..<pattern.index(before: pattern.endIndex)]))
        }
        guard pattern.hasPrefix("(?"),
              pattern.hasSuffix(")"),
              let colon = pattern.firstIndex(of: ":") else {
            return false
        }
        let flagStart = pattern.index(pattern.startIndex, offsetBy: 2)
        let flags = pattern[flagStart..<colon]
        let bodyStart = pattern.index(after: colon)
        let body = pattern[bodyStart..<pattern.index(before: pattern.endIndex)]
        return flags.contains("m") && (body == "^" || body == "$")
    }

    private func rawDataForOutput(_ data: Data, options: RipgrepOptions, matcher: PatternMatcher) -> Data? {
        if options.encodingMode == .disabled || matcher.usesByteSemantics {
            return data
        }
        return usesLossyAutomaticUTF8Decode(data, options: options) ? data : nil
    }

    private func rawDataForMatching(_ data: Data, options: RipgrepOptions, matcher: PatternMatcher) -> Data? {
        if matcher.usesByteSemantics {
            return data
        }
        switch options.encodingMode {
        case .automatic:
            return usesLossyAutomaticUTF8Decode(data, options: options) ? data : nil
        case .disabled:
            return data
        case .explicit:
            return nil
        }
    }

    private func usesLossyAutomaticUTF8Decode(_ data: Data, options: RipgrepOptions) -> Bool {
        guard options.encodingMode == .automatic,
              !data.starts(with: [0xEF, 0xBB, 0xBF]),
              !data.starts(with: [0xFF, 0xFE]),
              !data.starts(with: [0xFE, 0xFF]) else {
            return false
        }
        return String(data: data, encoding: .utf8) == nil
    }

    private func adjustedSpans(
        _ spans: [MatchSpan],
        rawLine: String?,
        options: RipgrepOptions
    ) -> [MatchSpan] {
        guard let rawLine,
              let rawMap = rawLineMap(for: rawLine) else {
            return spans
        }

        return spans.compactMap { span in
            let decodedRange = span.startByte..<span.endByte
            guard !rawMap.invalidDecodedRanges.contains(where: { rangesOverlap($0, decodedRange) }),
                  span.startByte < rawMap.decodedToRawByteOffsets.count,
                  span.endByte < rawMap.decodedToRawByteOffsets.count else {
                return nil
            }
            let rawStart = rawMap.decodedToRawByteOffsets[span.startByte]
            let rawEnd = rawMap.decodedToRawByteOffsets[span.endByte]
            return MatchSpan(
                startColumn: rawStart + 1,
                endColumn: rawEnd + 1,
                startByte: rawStart,
                endByte: rawEnd,
                text: span.text,
                replacement: span.replacement
            )
        }
    }

    private func rangesOverlap(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private func rawLineMap(for rawLine: String) -> RawLineMap? {
        let bytes = rawLine.unicodeScalars.compactMap { scalar -> UInt8? in
            guard scalar.value <= UInt8.max else {
                return nil
            }
            return UInt8(scalar.value)
        }
        guard bytes.count == rawLine.unicodeScalars.count else {
            return nil
        }

        var decodedToRaw = [0]
        var invalidRanges: [Range<Int>] = []
        var rawOffset = 0
        var decodedOffset = 0

        while rawOffset < bytes.count {
            if let length = validUTF8SequenceLength(in: bytes, at: rawOffset) {
                for offset in 1...length {
                    decodedToRaw.append(rawOffset + offset)
                }
                rawOffset += length
                decodedOffset += length
            } else {
                invalidRanges.append(decodedOffset..<(decodedOffset + 3))
                decodedToRaw.append(rawOffset)
                decodedToRaw.append(rawOffset)
                decodedToRaw.append(rawOffset + 1)
                rawOffset += 1
                decodedOffset += 3
            }
        }

        return RawLineMap(
            decodedToRawByteOffsets: decodedToRaw,
            invalidDecodedRanges: invalidRanges
        )
    }

    private func validUTF8SequenceLength(in bytes: [UInt8], at offset: Int) -> Int? {
        let byte = bytes[offset]
        if byte <= 0x7F {
            return 1
        }

        let length: Int
        let minimumScalar: UInt32
        var scalar: UInt32
        switch byte {
        case 0xC2...0xDF:
            length = 2
            minimumScalar = 0x80
            scalar = UInt32(byte & 0x1F)
        case 0xE0...0xEF:
            length = 3
            minimumScalar = 0x800
            scalar = UInt32(byte & 0x0F)
        case 0xF0...0xF4:
            length = 4
            minimumScalar = 0x10000
            scalar = UInt32(byte & 0x07)
        default:
            return nil
        }

        guard offset + length <= bytes.count else {
            return nil
        }
        for index in (offset + 1)..<(offset + length) {
            let continuation = bytes[index]
            guard (0x80...0xBF).contains(continuation) else {
                return nil
            }
            scalar = (scalar << 6) | UInt32(continuation & 0x3F)
        }
        guard scalar >= minimumScalar,
              scalar <= 0x10FFFF,
              !(0xD800...0xDFFF).contains(scalar) else {
            return nil
        }
        return length
    }

    private func multilineReplacementBlockText(
        lines: [SearchLine],
        startLineIndex: Int,
        endLineIndex: Int,
        group: [MultilineSpanCandidate],
        options: RipgrepOptions
    ) -> String {
        let endLine = lines[endLineIndex]
        let endLineTextEnd = endLine.absoluteOffset + byteCount(endLine.line, options: options)
        let includeEndTerminator = group.contains { $0.span.endByte > endLineTextEnd }

        var text = ""
        for index in startLineIndex...endLineIndex {
            if index < endLineIndex || includeEndTerminator {
                text += lines[index].lineWithTerminator
            } else {
                text += lines[index].line
            }
        }
        return text
    }

    private func multilineOnlyMatchingCandidateSpans(
        spans: [MatchSpan],
        limitedSpans: [MatchSpan],
        lineStartOffsets: [Int],
        maxCount: Int?
    ) -> [MatchSpan] {
        guard maxCount != nil else {
            return spans
        }
        let selectedLines = Set(limitedSpans.compactMap {
            lineIndex(containingByteOffset: $0.startByte, lineStartOffsets: lineStartOffsets)
        })
        return spans.filter { span in
            guard let startLineIndex = lineIndex(containingByteOffset: span.startByte, lineStartOffsets: lineStartOffsets) else {
                return false
            }
            return selectedLines.contains(startLineIndex)
        }
    }

    private func multilineReplacementCandidateSpans(
        spans: [MatchSpan],
        lineStartOffsets: [Int],
        maxCount: Int?
    ) -> [MatchSpan] {
        guard let maxCount else {
            return spans
        }
        var selectedLines = Set<Int>()
        for span in spans {
            guard let startLineIndex = lineIndex(containingByteOffset: span.startByte, lineStartOffsets: lineStartOffsets) else {
                continue
            }
            selectedLines.insert(startLineIndex)
            if selectedLines.count == maxCount {
                break
            }
        }
        return spans.filter { span in
            guard let startLineIndex = lineIndex(containingByteOffset: span.startByte, lineStartOffsets: lineStartOffsets) else {
                return false
            }
            return selectedLines.contains(startLineIndex)
        }
    }

    private func multilineReplacementRawBlockText(
        lines: [SearchLine],
        startLineIndex: Int,
        endLineIndex: Int,
        group: [MultilineSpanCandidate],
        options: RipgrepOptions
    ) -> String? {
        guard lines[startLineIndex...endLineIndex].allSatisfy({ $0.rawLine != nil }) else {
            return nil
        }
        let endLine = lines[endLineIndex]
        let endLineTextEnd = lineTextEndOffset(endLine, options: options)
        let includeEndTerminator = group.contains { $0.span.endByte > endLineTextEnd }

        var text = ""
        for index in startLineIndex...endLineIndex {
            guard let rawLine = lines[index].rawLine else {
                return nil
            }
            if index < endLineIndex || includeEndTerminator {
                text += rawLine + lines[index].lineTerminator
            } else {
                text += rawLine
            }
        }
        return text
    }

    private func isLineTerminatorOnlySpan(
        _ span: MatchSpan,
        in lines: [SearchLine],
        lineIndex: Int,
        options: RipgrepOptions
    ) -> Bool {
        guard span.endByte > span.startByte,
              lineIndex < lines.count else {
            return false
        }
        let line = lines[lineIndex]
        let textEnd = lineTextEndOffset(line, options: options)
        let lineEnd = textEnd + byteCount(line.lineTerminator, options: options)
        return span.startByte >= textEnd && span.endByte <= lineEnd
    }

    private func lineTextEndOffset(_ line: SearchLine, options: RipgrepOptions) -> Int {
        line.absoluteOffset + (line.rawLine?.unicodeScalars.count ?? byteCount(line.line, options: options))
    }

    private func groupedOverlappingLineSpans(
        _ candidates: [MultilineSpanCandidate],
        splitSeparatedTrailingLineMatches: Bool,
        mergeAdjacentLineSpans: Bool
    ) -> [[MultilineSpanCandidate]] {
        var groups: [[MultilineSpanCandidate]] = []
        var current: [MultilineSpanCandidate] = []
        var currentStartLineIndex: Int?
        var currentEndLineIndex: Int?
        var currentEndByte: Int?

        for candidate in candidates {
            let shouldStartNewGroup: Bool
            if let startLineIndex = currentStartLineIndex,
               let endLineIndex = currentEndLineIndex,
               let endByte = currentEndByte {
                let startsAfterCurrentGroup = candidate.startLineIndex > endLineIndex
                let startsAdjacentLine = candidate.startLineIndex == endLineIndex + 1
                shouldStartNewGroup = startsAfterCurrentGroup
                    && !(mergeAdjacentLineSpans && startsAdjacentLine)
                    || (splitSeparatedTrailingLineMatches
                        && startLineIndex < endLineIndex
                        && candidate.startLineIndex == endLineIndex
                        && candidate.span.startByte > endByte)
            } else {
                shouldStartNewGroup = false
            }

            if shouldStartNewGroup {
                groups.append(current)
                current = []
                currentStartLineIndex = nil
                currentEndLineIndex = nil
                currentEndByte = nil
            }
            current.append(candidate)
            currentStartLineIndex = currentStartLineIndex ?? candidate.startLineIndex
            currentEndLineIndex = max(currentEndLineIndex ?? candidate.endLineIndex, candidate.endLineIndex)
            currentEndByte = max(currentEndByte ?? candidate.span.endByte, candidate.span.endByte)
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private func endLineIndex(for span: MatchSpan, lineStartOffsets: [Int]) -> Int? {
        if span.endByte > span.startByte,
           lineStartOffsets.contains(span.endByte) {
            return lineIndex(containingByteOffset: span.endByte, lineStartOffsets: lineStartOffsets)
        }
        return lineIndex(
            containingByteOffset: max(span.endByte - 1, span.startByte),
            lineStartOffsets: lineStartOffsets
        )
    }

    private func column(in text: String, byteOffset: Int, options: RipgrepOptions) -> Int {
        var bytes = 0
        var column = 1
        for character in text {
            guard bytes < byteOffset else {
                break
            }
            bytes += byteCount(String(character), options: options)
            if character == "\n" || character == "\0" {
                column = 1
            } else {
                column = bytes + 1
            }
        }
        return column
    }

    private func byteCount(_ text: String, options: RipgrepOptions) -> Int {
        options.encodingMode == .disabled ? text.unicodeScalars.count : text.utf8.count
    }

    private func lineIndex(containingByteOffset byteOffset: Int, lineStartOffsets: [Int]) -> Int? {
        guard !lineStartOffsets.isEmpty else {
            return nil
        }
        var result = 0
        for (index, lineOffset) in lineStartOffsets.enumerated() {
            if lineOffset > byteOffset {
                break
            }
            result = index
        }
        return result
    }

    private func decode(_ data: Data, options: RipgrepOptions) -> String {
        switch options.encodingMode {
        case .automatic:
            if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                return decodeSlice(data.dropFirst(3), encoding: .utf8)
            }
            if data.starts(with: [0xFF, 0xFE]) {
                return decodeUTF16(data.dropFirst(2), littleEndian: true)
            }
            if data.starts(with: [0xFE, 0xFF]) {
                return decodeUTF16(data.dropFirst(2), littleEndian: false)
            }
            return decode(data, encoding: .utf8)
        case .disabled:
            return String(decoding: data, as: UTF8.self)
        case .explicit(let encoding):
            return decodeExplicit(data, encoding: encoding)
        }
    }

    private func shouldCheckBinary(_ data: Data, options: RipgrepOptions) -> Bool {
        if options.nullData {
            return false
        }
        switch options.encodingMode {
        case .explicit(let encoding):
            return !encoding.isUTF16
        case .disabled:
            return true
        case .automatic:
            return !(data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]))
        }
    }

    private func firstNulByteOffset(in data: Data) -> Int? {
        firstNulByteOffset(in: data, limit: data.count)
    }

    private func firstNulByteOffset(in data: Data, limit: Int) -> Int? {
        data.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            let count = min(data.count, max(0, limit))
            guard let pointer = memchr(baseAddress, 0, count) else {
                return nil
            }
            return baseAddress.distance(to: pointer.assumingMemoryBound(to: UInt8.self))
        }
    }

    private func decodeSlice(_ data: Data.SubSequence, encoding: String.Encoding) -> String {
        decode(Data(data), encoding: encoding)
    }

    private func decodeUTF16(_ data: Data.SubSequence, littleEndian: Bool) -> String {
        let bytes = Array(data)
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity((bytes.count + 1) / 2)
        var index = 0
        while index + 1 < bytes.count {
            let codeUnit = littleEndian
                ? UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                : (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
            codeUnits.append(codeUnit)
            index += 2
        }
        if index < bytes.count {
            codeUnits.append(0xFFFD)
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    private func decode(_ data: Data, encoding: String.Encoding) -> String {
        String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    private func decodeExplicit(_ data: Data, encoding: TextEncoding) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = data.dropFirst(3)
            if encoding == .utf16LittleEndian {
                return decodeUTF16(body, littleEndian: true)
            }
            if encoding == .utf16BigEndian {
                return decodeUTF16(body, littleEndian: false)
            }
            return encoding.decode(Data(body))
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return decodeUTF16(data.dropFirst(2), littleEndian: true)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return decodeUTF16(data.dropFirst(2), littleEndian: false)
        }
        if encoding == .utf16LittleEndian {
            return decodeUTF16(data, littleEndian: true)
        }
        if encoding == .utf16BigEndian {
            return decodeUTF16(data, littleEndian: false)
        }
        return encoding.decode(data)
    }

    private func splitLines(
        _ contents: String,
        options: RipgrepOptions,
        splitBinaryNUL: Bool = false
    ) -> [(text: String, terminator: String)] {
        guard !contents.isEmpty else {
            return []
        }
        if options.nullData {
            return splitNulDelimited(contents)
        }

        var lines: [(String, String)] = []
        var current = String.UnicodeScalarView()

        for scalar in contents.unicodeScalars {
            if scalar == "\n" || (splitBinaryNUL && scalar == "\0") {
                lines.append((String(current), "\n"))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(scalar)
            }
        }

        if !current.isEmpty || !lastScalarIsTerminator(in: contents, splitBinaryNUL: splitBinaryNUL) {
            lines.append((String(current), ""))
        }
        return lines
    }

    private func splitNulDelimited(_ contents: String) -> [(text: String, terminator: String)] {
        guard !contents.isEmpty else {
            return []
        }
        var lines: [(String, String)] = []
        var current = String.UnicodeScalarView()
        for scalar in contents.unicodeScalars {
            if scalar == "\0" {
                lines.append((String(current), "\0"))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty || !lastScalar(in: contents, equals: "\0") {
            lines.append((String(current), ""))
        }
        return lines
    }

    private func splitRawLines(
        _ data: Data,
        options: RipgrepOptions,
        splitBinaryNUL: Bool = false
    ) -> [(text: String, terminator: String)] {
        guard !data.isEmpty else {
            return []
        }
        let separator: UInt8 = options.nullData ? 0 : UInt8(ascii: "\n")
        var lines: [(String, String)] = []
        var current = String.UnicodeScalarView()

        for byte in data {
            if byte == separator || (splitBinaryNUL && byte == 0) {
                lines.append((String(current), options.nullData ? String(UnicodeScalar(separator)) : "\n"))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(UnicodeScalar(byte))
            }
        }

        let lastByteIsTerminator = data.last == separator || (splitBinaryNUL && data.last == 0)
        if !current.isEmpty || !lastByteIsTerminator {
            lines.append((String(current), ""))
        }
        return lines
    }

    private func lastScalarIsTerminator(in contents: String, splitBinaryNUL: Bool) -> Bool {
        lastScalar(in: contents, equals: "\n") || (splitBinaryNUL && lastScalar(in: contents, equals: "\0"))
    }

    private func lastScalar(in contents: String, equals expected: UnicodeScalar) -> Bool {
        guard let last = contents.unicodeScalars.last else {
            return false
        }
        return last == expected
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
