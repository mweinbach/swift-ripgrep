import Foundation

private struct FileSearchOutcome {
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

private struct MultilineSpanCandidate {
    let span: MatchSpan
    let startLineIndex: Int
    let endLineIndex: Int
}

private struct RawLineMap {
    let decodedToRawByteOffsets: [Int]
    let invalidDecodedRanges: [Range<Int>]
}

public struct RipgrepSearcher {
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

    public func search(options: RipgrepOptions, stdin: String?) throws -> SearchResults {
        let matcher = try PatternMatcher(options: options)
        let walkResults = options.useStdin && options.roots.isEmpty
            ? FileWalkResults(haystacks: [], messages: [])
            : try FileWalker(fileManager: fileManager)
                .withEnvironment(environment)
                .haystacksWithMessages(for: options)
        var messages = walkResults.messages
        let warnings = walkResults.warnings
        let diagnostics = walkResults.diagnostics
        let searchedHaystacks = walkResults.haystacks.map { haystack in
            let outcome = searchFile(haystack, matcher: matcher, options: options)
            if let message = outcome.message {
                messages.append(message)
            }
            return (url: haystack.url, result: outcome.result)
        }
        var files = searchedHaystacks.map(\.result)

        if options.useStdin {
            let stdinData = stdin.map { Data($0.utf8) } ?? FileHandle.standardInput.readDataToEndOfFile()
            let stdinResult = searchStdin(stdinData, matcher: matcher, options: options)
            if let dashIndex = firstStdinRootIndex(in: options),
               preservesExplicitStdinPosition(options: options) {
                var ordered: [SearchFileResult] = []
                var insertedStdin = false
                var emittedHaystackIDs = Set<String>()
                for (offset, root) in options.roots.enumerated() {
                    if offset == dashIndex {
                        ordered.append(stdinResult)
                        insertedStdin = true
                        continue
                    }
                    let rootPath = root.standardizedFileURL.path
                    for searched in searchedHaystacks where isRootMatch(searched.url, root: root) {
                        let identifier = searched.url.standardizedFileURL.path
                        guard !emittedHaystackIDs.contains(identifier) else {
                            continue
                        }
                        ordered.append(searched.result)
                        emittedHaystackIDs.insert(identifier)
                    }
                    if rootPath == "-" || rootPath == "<stdin>" {
                        continue
                    }
                }
                if !insertedStdin {
                    ordered.append(stdinResult)
                }
                files = ordered
            } else {
                files.append(stdinResult)
            }
        }

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
                return total + (matchCount == 0 && file.hasBinaryMatch ? 1 : matchCount) + file.supplementalMatches
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

    private func preservesExplicitStdinPosition(options: RipgrepOptions) -> Bool {
        guard let sortMode = options.sortMode else {
            return true
        }
        return sortMode.kind == .path && !sortMode.reverse
    }

    private func sorted(_ files: [SearchFileResult], options: RipgrepOptions) -> [SearchFileResult] {
        guard let sortMode = options.sortMode else {
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

    private func firstStdinRootIndex(in options: RipgrepOptions) -> Int? {
        options.rootPathArguments.firstIndex(of: "-")
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
        let lhsPath = lhs.path
        let rhsPath = rhs.path
        if lhsPath == rhsPath {
            return .orderedSame
        }
        return lhsPath < rhsPath ? .orderedAscending : .orderedDescending
    }

    private func searchFile(
        _ haystack: Haystack,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> FileSearchOutcome {
        let fileURL = haystack.url
        guard let data = try? Data(contentsOf: fileURL) else {
            return FileSearchOutcome(result: SearchFileResult(fileURL: fileURL, matches: [], searched: false))
        }

        if shouldPreprocess(haystack, options: options) {
            return searchPreprocessedFile(
                fileURL,
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
                options: options
            )
        }

        let binaryByteOffset = shouldCheckBinary(data, options: options) ? data.firstIndex(of: 0) : nil
        if let binaryByteOffset, options.binaryMode != .asText {
            let contents = decode(data, options: options)
            let result = searchContents(
                contents,
                rawData: rawDataForOutput(data, options: options),
                fileURL: fileURL,
                matcher: matcher,
                options: options,
                splitBinaryNUL: true
            )
            let binaryDetectedBeforeSearch = binaryByteOffset < Self.binaryDetectionBufferSize
            let visibleMatches = binaryDetectedBeforeSearch && !haystack.isExplicit
                ? []
                : matchesBeforeBinary(result.matches, binaryByteOffset: binaryByteOffset, options: options)
            let emittedMatches = shouldEmitSuppressedBinaryMatches(options, isExplicit: haystack.isExplicit)
                ? result.matches
                : visibleMatches
            let lineNumberShifts = jsonBinaryLineNumberShifts(for: result.lines, options: options)
            let displayMatches = options.json
                ? jsonBinaryDisplayMatches(emittedMatches, lineNumberShifts: lineNumberShifts, options: options)
                : emittedMatches
            let hasBinaryMatch = hasBinaryMatchResult(
                result: result,
                visibleMatches: visibleMatches,
                options: options
            )
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
                    visibleMatches: visibleMatches,
                    options: options
                ),
                supplementalMatchedLines: result.supplementalMatchedLines,
                supplementalMatches: result.supplementalMatches
            ))
        }

        let contents = decode(data, options: options)
        let result = searchContents(
            contents,
            rawData: rawDataForOutput(data, options: options),
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

    private func jsonBinaryDisplayMatches(
        _ matches: [SearchMatch],
        lineNumberShifts: [Int: Int],
        options: RipgrepOptions
    ) -> [SearchMatch] {
        matches.flatMap { match -> [SearchMatch] in
            let lineNumber = match.lineNumber + (lineNumberShifts[match.lineNumber] ?? 0)
            guard let nulIndex = match.line.firstIndex(of: "\0") else {
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
            let prefixLine = String(match.line[..<nulIndex])
            let contentStart = match.line.index(after: nulIndex)
            let suffixLine = String(match.line[contentStart...])
            let prefixBytes = byteCount(prefixLine, options: options)
            let prefixWithNULBytes = prefixBytes + byteCount("\0", options: options)
            let rawPieces = jsonBinaryRawLinePieces(match.rawLine)

            let prefixSpans = match.spans.filter { $0.endByte <= prefixBytes }
            let suffixSpans = match.spans.compactMap { span -> MatchSpan? in
                guard span.startByte >= prefixWithNULBytes else {
                    return nil
                }
                let startByte = span.startByte - prefixWithNULBytes
                let endByte = span.endByte - prefixWithNULBytes
                return MatchSpan(
                    startColumn: column(in: suffixLine, byteOffset: startByte, options: options),
                    endColumn: column(in: suffixLine, byteOffset: endByte, options: options),
                    startByte: startByte,
                    endByte: endByte,
                    text: span.text,
                    replacement: span.replacement
                )
            }

            var displayMatches: [SearchMatch] = []
            if !prefixSpans.isEmpty {
                displayMatches.append(SearchMatch(
                    fileURL: match.fileURL,
                    lineNumber: lineNumber,
                    column: options.column ? prefixSpans.first?.startColumn : nil,
                    line: prefixLine,
                    rawLine: rawPieces?.prefix,
                    lineTerminator: "\n",
                    absoluteOffset: match.absoluteOffset,
                    matchCount: prefixSpans.count,
                    spans: prefixSpans
                ))
            }
            if !suffixSpans.isEmpty {
                displayMatches.append(SearchMatch(
                    fileURL: match.fileURL,
                    lineNumber: lineNumber + 1,
                    column: options.column ? suffixSpans.first?.startColumn : nil,
                    line: suffixLine,
                    rawLine: rawPieces?.suffix,
                    lineTerminator: match.lineTerminator,
                    absoluteOffset: match.absoluteOffset + prefixWithNULBytes,
                    matchCount: suffixSpans.count,
                    spans: suffixSpans
                ))
            }
            return displayMatches
        }
    }

    private func jsonBinaryDisplayLines(
        _ lines: [SearchLine],
        lineNumberShifts: [Int: Int],
        options: RipgrepOptions
    ) -> [SearchLine] {
        lines.flatMap { line -> [SearchLine] in
            let lineNumber = line.lineNumber + (lineNumberShifts[line.lineNumber] ?? 0)
            guard let nulIndex = line.line.firstIndex(of: "\0") else {
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
            let prefixLine = String(line.line[..<nulIndex])
            let contentStart = line.line.index(after: nulIndex)
            let suffixLine = String(line.line[contentStart...])
            let prefixBytes = byteCount(prefixLine, options: options)
            let prefixWithNULBytes = byteCount(prefixLine, options: options) + byteCount("\0", options: options)
            let rawPieces = jsonBinaryRawLinePieces(line.rawLine)
            let prefixPositiveSpans = line.positiveSpans.filter { $0.endByte <= prefixBytes }
            let suffixPositiveSpans = line.positiveSpans.compactMap { span -> MatchSpan? in
                guard span.startByte >= prefixWithNULBytes else {
                    return nil
                }
                let startByte = span.startByte - prefixWithNULBytes
                let endByte = span.endByte - prefixWithNULBytes
                return MatchSpan(
                    startColumn: column(in: suffixLine, byteOffset: startByte, options: options),
                    endColumn: column(in: suffixLine, byteOffset: endByte, options: options),
                    startByte: startByte,
                    endByte: endByte,
                    text: span.text,
                    replacement: span.replacement
                )
            }
            return [
                SearchLine(
                    lineNumber: lineNumber,
                    line: prefixLine,
                    rawLine: rawPieces?.prefix,
                    lineTerminator: "\n",
                    absoluteOffset: line.absoluteOffset,
                    positiveSpans: prefixPositiveSpans
                ),
                SearchLine(
                    lineNumber: lineNumber + 1,
                    line: suffixLine,
                    rawLine: rawPieces?.suffix,
                    lineTerminator: line.lineTerminator,
                    absoluteOffset: line.absoluteOffset + prefixWithNULBytes,
                    positiveSpans: suffixPositiveSpans
                )
            ]
        }
    }

    private func jsonBinaryLineNumberShifts(for lines: [SearchLine], options: RipgrepOptions) -> [Int: Int] {
        guard options.json else {
            return [:]
        }
        var shifts: [Int: Int] = [:]
        var shift = 0
        for line in lines.sorted(by: { $0.lineNumber < $1.lineNumber }) {
            shifts[line.lineNumber] = shift
            if line.line.contains("\0") {
                shift += 1
            }
        }
        return shifts
    }

    private func jsonBinaryRawLinePieces(_ rawLine: String?) -> (prefix: String, suffix: String)? {
        guard let rawLine,
              let rawNulIndex = rawLine.firstIndex(of: "\0") else {
            return nil
        }
        let prefix = String(rawLine[..<rawNulIndex])
        let suffix = String(rawLine[rawLine.index(after: rawNulIndex)...])
        return (prefix, suffix)
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
            rawData: rawDataForOutput(data, options: options),
            fileURL: fileURL,
            matcher: matcher,
            options: options
        )
        guard options.binaryMode != .asText,
              shouldCheckBinary(data, options: options),
              let binaryByteOffset = data.firstIndex(of: 0) else {
            return result
        }
        let binaryDetectedBeforeSearch = binaryByteOffset < Self.binaryDetectionBufferSize
        let visibleMatches = binaryDetectedBeforeSearch
            ? []
            : matchesBeforeBinary(result.matches, binaryByteOffset: binaryByteOffset, options: options)
        let emittedMatches = shouldEmitSuppressedBinaryMatches(options, isExplicit: true)
            ? result.matches
            : visibleMatches
        let lineNumberShifts = jsonBinaryLineNumberShifts(for: result.lines, options: options)
        let displayMatches = options.json
            ? jsonBinaryDisplayMatches(emittedMatches, lineNumberShifts: lineNumberShifts, options: options)
            : emittedMatches
        let displayLines = options.json
            ? jsonBinaryDisplayLines(result.lines, lineNumberShifts: lineNumberShifts, options: options)
            : result.lines
        return SearchFileResult(
            fileURL: fileURL,
            matches: displayMatches,
            lines: displayLines,
            binaryByteOffset: binaryByteOffset,
            hasBinaryMatch: result.hasMatch,
            bytesSearched: data.count,
            supplementalMatchedLines: result.supplementalMatchedLines,
            supplementalMatches: result.supplementalMatches
        )
    }

    private func matchesBeforeBinary(
        _ matches: [SearchMatch],
        binaryByteOffset: Int,
        options: RipgrepOptions
    ) -> [SearchMatch] {
        matches.filter { match in
            let matchEnd = match.spans.map(\.endByte).max() ?? byteCount(match.line, options: options)
            return match.absoluteOffset + matchEnd <= binaryByteOffset
        }
    }

    private func hasBinaryMatchResult(
        result: SearchFileResult,
        visibleMatches: [SearchMatch],
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
        return !visibleMatches.isEmpty
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
        visibleMatches: [SearchMatch],
        options: RipgrepOptions
    ) -> Int {
        if options.quiet && options.stats {
            return dataCount
        }
        guard options.printMode == .matchingLines,
              !options.json,
              let firstMatch = visibleMatches.first else {
            return dataCount
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
        return matcher.allows(relativePath: haystack.url.path, isDirectory: false)
    }

    private func searchPreprocessedFile(
        _ fileURL: URL,
        originalData: Data,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> FileSearchOutcome {
        guard let command = options.preprocessor else {
            return FileSearchOutcome(result: SearchFileResult(fileURL: fileURL, matches: [], searched: false))
        }
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
            process.arguments = [fileURL.path]

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
                rawData: rawDataForOutput(data, options: options),
                fileURL: fileURL,
                matcher: matcher,
                options: options
            )
            return FileSearchOutcome(result: SearchFileResult(
                fileURL: result.fileURL,
                matches: result.matches,
                lines: result.lines,
                bytesSearched: originalData.count,
                searched: result.searched
            ))
        } catch {
            return FileSearchOutcome(
                result: SearchFileResult(fileURL: fileURL, matches: [], searched: false),
                message: "\(displayPath): preprocessor command could not start: '\(commandDisplay)': \(error)"
            )
        }
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
        options: RipgrepOptions
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
                rawData: rawDataForOutput(data, options: options),
                fileURL: fileURL,
                matcher: matcher,
                options: options
            )
            return FileSearchOutcome(result: SearchFileResult(
                fileURL: result.fileURL,
                matches: result.matches,
                lines: result.lines,
                bytesSearched: data.count,
                searched: result.searched
            ))
        } catch {
            let displayPath = OutputPathFormatter(options: options).displayPath(for: fileURL)
            return FileSearchOutcome(
                result: SearchFileResult(fileURL: fileURL, matches: [], searched: false),
                message: "\(displayPath): \(error)"
            )
        }
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
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions,
        splitBinaryNUL: Bool = false
    ) -> SearchFileResult {
        if options.multiline && !options.invertMatch {
            return searchMultilineContents(contents, fileURL: fileURL, matcher: matcher, options: options)
        }

        var matches: [SearchMatch] = []
        let shouldSplitBinaryNUL = splitBinaryNUL && options.binaryMode != .asText && !options.nullData
        let lines = splitLines(contents, options: options, splitBinaryNUL: shouldSplitBinaryNUL)
        let rawLines = rawData.map { splitRawLines($0, options: options, splitBinaryNUL: shouldSplitBinaryNUL) }
        var searchLines: [SearchLine] = []
        var absoluteOffset = 0
        let maxCount = options.maxCount ?? Int.max
        var hasMatched = false
        var hasPositiveMatched = false
        var bytesSearchedThroughMaxCount: Int?

        for (offset, splitLine) in lines.enumerated() {
            let line = splitLine.text
            let rawLine = rawLines?[safe: offset]?.text
            let lineNumber = offset + 1
            let lineByteCount = rawLines?[safe: offset].map {
                $0.text.unicodeScalars.count + $0.terminator.unicodeScalars.count
            } ?? byteCount(splitLine.text, options: options) + byteCount(splitLine.terminator, options: options)
            let positiveSpans = adjustedSpans(
                matcher.positiveSpans(in: line),
                rawLine: rawLine,
                options: options
            )
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

            let spans = adjustedSpans(
                matcher.spans(in: line),
                rawLine: rawLine,
                options: options
            )
            searchLines.append(SearchLine(
                lineNumber: lineNumber,
                line: line,
                rawLine: rawLine,
                lineTerminator: splitLine.terminator,
                absoluteOffset: absoluteOffset,
                positiveSpans: positiveSpans
            ))
            let positiveMatched = options.invertMatch && options.stopOnNonmatch
                ? !positiveSpans.isEmpty
                : !spans.isEmpty
            guard !spans.isEmpty else {
                absoluteOffset += lineByteCount
                if options.stopOnNonmatch && !options.invertMatch && hasMatched {
                    break
                }
                if positiveMatched {
                    hasPositiveMatched = true
                }
                continue
            }

            hasMatched = true
            matches.append(SearchMatch(
                fileURL: fileURL,
                lineNumber: lineNumber,
                column: options.column ? spans[0].startColumn : nil,
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
            if options.stopOnNonmatch && options.invertMatch && hasPositiveMatched && !positiveMatched {
                break
            }
            if positiveMatched {
                hasPositiveMatched = true
            }
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
        guard options.beforeContext > 0 || options.afterContext > 0 else {
            return bytesSearchedThroughMaxCount ?? totalBytes
        }
        let selected = selectedContextLineNumbers(lineCount: lines.count, matches: matches, options: options)
        guard let lastLineNumber = selected.max(),
              let line = lines.first(where: { $0.lineNumber == lastLineNumber }) else {
            return bytesSearchedThroughMaxCount ?? totalBytes
        }
        return line.absoluteOffset + byteCount(line.line, options: options) + byteCount(line.lineTerminator, options: options)
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
        let matchedLineNumbers = Set(matches.map(\.lineNumber))
        let selected = selectedContextLineNumbers(lineCount: lines.count, matches: matches, options: options)
        return lines.filter {
            selected.contains($0.lineNumber)
                && !matchedLineNumbers.contains($0.lineNumber)
                && !$0.positiveSpans.isEmpty
        }
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
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> SearchFileResult {
        let split = splitLines(contents, options: options)
        var searchLines: [SearchLine] = []
        var lineStartOffsets: [Int] = []
        var absoluteOffset = 0

        for (offset, splitLine) in split.enumerated() {
            lineStartOffsets.append(absoluteOffset)
            searchLines.append(SearchLine(
                lineNumber: offset + 1,
                line: splitLine.text,
                lineTerminator: splitLine.terminator,
                absoluteOffset: absoluteOffset
            ))
            absoluteOffset += byteCount(splitLine.text, options: options) + byteCount(splitLine.terminator, options: options)
        }

        let spans = matcher.spans(in: contents)
        let limitedSpans = Array(spans.prefix(options.maxCount ?? Int.max))
        if options.replacement != nil, !options.onlyMatching {
            let candidates = limitedSpans.compactMap { span -> MultilineSpanCandidate? in
                guard let startLineIndex = lineIndex(containingByteOffset: span.startByte, lineStartOffsets: lineStartOffsets),
                      let endLineIndex = endLineIndex(for: span, lineStartOffsets: lineStartOffsets) else {
                    return nil
                }
                return MultilineSpanCandidate(span: span, startLineIndex: startLineIndex, endLineIndex: endLineIndex)
            }
            let grouped = groupedOverlappingLineSpans(candidates, splitSeparatedTrailingLineMatches: false)
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
                    column: options.column ? adjustedSpans.first?.startColumn : nil,
                    line: blockText,
                    lineTerminator: "",
                    absoluteOffset: blockOffset,
                    matchCount: adjustedSpans.count,
                    spans: adjustedSpans
                )
            }
            return SearchFileResult(
                fileURL: fileURL,
                matches: matches,
                lines: searchLines,
                bytesSearched: absoluteOffset
            )
        }

        let candidates = limitedSpans.compactMap { span -> MultilineSpanCandidate? in
            guard let startLineIndex = lineIndex(containingByteOffset: span.startByte, lineStartOffsets: lineStartOffsets),
                  let endLineIndex = endLineIndex(for: span, lineStartOffsets: lineStartOffsets) else {
                return nil
            }
            return MultilineSpanCandidate(span: span, startLineIndex: startLineIndex, endLineIndex: endLineIndex)
        }
        let matches = groupedOverlappingLineSpans(candidates, splitSeparatedTrailingLineMatches: true).compactMap { group -> SearchMatch? in
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
            let endLineTextEnd = endLine.absoluteOffset + byteCount(endLine.line, options: options)
            let includesEndTerminator = group.contains { $0.span.endByte > endLineTextEnd }
            let reachesEndLineText = group.contains { $0.span.endByte > endLine.absoluteOffset }
            let lineTerminator = !includesEndTerminator && (startLineIndex == endLineIndex || reachesEndLineText)
                ? endLine.lineTerminator
                : ""

            return SearchMatch(
                fileURL: fileURL,
                lineNumber: startLineIndex + 1,
                column: options.column ? adjustedSpans.first?.startColumn : nil,
                line: blockText,
                lineTerminator: lineTerminator,
                absoluteOffset: blockOffset,
                matchCount: adjustedSpans.count,
                spans: adjustedSpans
            )
        }

        return SearchFileResult(
            fileURL: fileURL,
            matches: matches,
            lines: searchLines,
            bytesSearched: absoluteOffset
        )
    }

    private func rawDataForOutput(_ data: Data, options: RipgrepOptions) -> Data? {
        options.emitsRawBytes ? data : nil
    }

    private func adjustedSpans(
        _ spans: [MatchSpan],
        rawLine: String?,
        options: RipgrepOptions
    ) -> [MatchSpan] {
        guard options.emitsRawBytes,
              let rawLine,
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

    private func groupedOverlappingLineSpans(
        _ candidates: [MultilineSpanCandidate],
        splitSeparatedTrailingLineMatches: Bool
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
                shouldStartNewGroup = candidate.startLineIndex > endLineIndex
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
                return decodeSlice(data.dropFirst(2), encoding: .utf16LittleEndian)
            }
            if data.starts(with: [0xFE, 0xFF]) {
                return decodeSlice(data.dropFirst(2), encoding: .utf16BigEndian)
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
        case .explicit:
            return false
        case .disabled:
            return true
        case .automatic:
            return !(data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]))
        }
    }

    private func decodeSlice(_ data: Data.SubSequence, encoding: String.Encoding) -> String {
        decode(Data(data), encoding: encoding)
    }

    private func decode(_ data: Data, encoding: String.Encoding) -> String {
        String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    private func decodeExplicit(_ data: Data, encoding: String.Encoding) -> String {
        if encoding == .utf16LittleEndian, data.starts(with: [0xFF, 0xFE]) {
            return decodeSlice(data.dropFirst(2), encoding: encoding)
        }
        if encoding == .utf16BigEndian, data.starts(with: [0xFE, 0xFF]) {
            return decodeSlice(data.dropFirst(2), encoding: encoding)
        }
        return decode(data, encoding: encoding)
    }

    private func splitLines(
        _ contents: String,
        options: RipgrepOptions,
        splitBinaryNUL: Bool = false
    ) -> [(text: String, terminator: String)] {
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
