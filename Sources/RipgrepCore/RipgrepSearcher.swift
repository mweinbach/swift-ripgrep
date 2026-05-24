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
        PathSort.compare(lhs, rhs)
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
                    binaryByteOffset: binaryByteOffset,
                    searchedMatches: result.matches,
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
            rawData: rawDataForOutput(data, options: options, matcher: matcher),
            rawDataForMatching: rawDataForMatching(data, options: options, matcher: matcher),
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
           searchedMatches.isEmpty,
           options.effectivePatterns.contains(where: isMultilineBinaryBoundaryPattern) {
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
                rawData: rawDataForOutput(data, options: options, matcher: matcher),
                rawDataForMatching: rawDataForMatching(data, options: options, matcher: matcher),
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
        rawDataForMatching: Data? = nil,
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions,
        splitBinaryNUL: Bool = false
    ) -> SearchFileResult {
        let shouldSplitBinaryNUL = splitBinaryNUL && options.binaryMode != .asText && !options.nullData
        if options.multiline && !options.invertMatch {
            return searchMultilineContents(
                contents,
                rawData: rawData,
                rawDataForMatching: rawDataForMatching,
                fileURL: fileURL,
                matcher: matcher,
                options: options,
                splitBinaryNUL: shouldSplitBinaryNUL
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
        var hasPositiveMatched = false
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
            let positiveSpans = syntheticBinarySplitSpans(
                syntheticInlineCRLFBoundarySpans(
                    nullDataLineAnchorSpans(
                        crlfTrimmedSpans(
                            adjustedSpans(
                                matcher.positiveSpans(in: lineForMatching),
                                rawLine: rawLineForSpanAdjustment,
                                options: options
                            ),
                            line: line,
                            options: options
                        ),
                        line: line,
                        absoluteOffset: absoluteOffset,
                        terminator: splitLine.terminator,
                        options: options
                    ),
                    line: line,
                    terminator: splitLine.terminator,
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
                nullDataLineAnchorSpans(
                    crlfTrimmedSpans(
                        adjustedSpans(
                            matcher.spans(in: lineForMatching),
                            rawLine: rawLineForSpanAdjustment,
                            options: options
                        ),
                        line: line,
                        options: options
                    ),
                    line: line,
                    absoluteOffset: absoluteOffset,
                    terminator: splitLine.terminator,
                    options: options
                ),
                line: line,
                terminator: splitLine.terminator,
                options: options
            )
            let syntheticAdjusted = syntheticBinarySplitSpans(
                rawSpans,
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
            let preserveMatchedLine = syntheticAdjusted.preserveMatchedLine || absoluteStartAdjusted.preserveMatchedLine
            let positiveMatched = options.invertMatch && options.stopOnNonmatch
                ? !positiveSpans.isEmpty
                : (!spans.isEmpty || preserveMatchedLine)
            guard !spans.isEmpty || preserveMatchedLine else {
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

    private func nullDataLineAnchorSpans(
        _ spans: [MatchSpan],
        line: String,
        absoluteOffset: Int,
        terminator: String,
        options: RipgrepOptions
    ) -> [MatchSpan] {
        guard options.nullData, !options.multiline else {
            return spans
        }
        var output = spans
        if !terminator.isEmpty,
           absoluteOffset > 3,
           line.contains("\n"),
           options.effectivePatterns.contains(where: containsLineStartAnchor) {
            output = output.filter { $0.startByte != 0 }
        }
        if terminator.isEmpty,
           line.hasSuffix("\n"),
           !options.effectivePatterns.contains(where: containsLineStartAndEndAnchor) {
            let lineEnd = byteCount(line, options: options)
            output = output.filter {
                !($0.startByte == lineEnd && $0.endByte == lineEnd && $0.text.isEmpty)
            }
        }
        return output
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
        return spans.compactMap { span in
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

    private func syntheticInlineCRLFBoundarySpans(
        _ spans: [MatchSpan],
        line: String,
        terminator: String,
        options: RipgrepOptions
    ) -> [MatchSpan] {
        guard !options.multiline,
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
                text: ""
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

    private func isBareInlineCRLFLineAnchorPattern(_ pattern: String) -> Bool {
        if pattern.hasPrefix("(?"),
           let close = pattern.firstIndex(of: ")") {
            let flagStart = pattern.index(pattern.startIndex, offsetBy: 2)
            let flags = pattern[flagStart..<close]
            let rest = pattern[pattern.index(after: close)...]
            if flags.contains("R"), rest == "^" || rest == "$" {
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
        return flags.contains("R") && (body == "^" || body == "$")
    }

    private func isMultilineBinaryBoundaryPattern(_ pattern: String) -> Bool {
        containsLineAnchor(pattern) || containsLineTerminatorPattern(pattern)
    }

    private func containsLineTerminatorPattern(_ pattern: String) -> Bool {
        pattern.contains("\n") || pattern.contains(#"\n"#)
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
                matcher.spans(in: matchingContents),
                rawLine: rawContentsForSpanAdjustment,
                options: options
            ),
            in: matchingContents,
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
                    column: options.column ? adjustedSpans.first?.startColumn : nil,
                    line: blockText,
                    rawLine: rawBlockText,
                    lineTerminator: "",
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
        let groups = shouldGroupLineAnchors
            ? [candidates]
            : groupedOverlappingLineSpans(candidates, splitSeparatedTrailingLineMatches: true)
        let matches = groups.compactMap { group -> SearchMatch? in
            guard let first = group.first else {
                return nil
            }
            let startLineIndex = first.startLineIndex
            let endLineIndex = shouldGroupLineAnchors
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
                column: options.column ? adjustedSpans.first?.startColumn : nil,
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
        if options.emitsRawBytes || matcher.usesByteSemantics || (options.json && options.encodingMode == .automatic) {
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
