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

    private func shouldPreserveZeroMultilineBinaryMatchCount(options: RipgrepOptions) -> Bool {
        options.multiline && options.effectivePatterns.allSatisfy(isBareMultilineLineEndPattern)
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
        guard let data = try? Data(contentsOf: fileURL) else {
            return FileSearchOutcome(result: SearchFileResult(fileURL: fileURL, matches: [], searched: false))
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
                options: options
            )
        }

        let binaryByteOffset = shouldCheckBinary(data, options: options) ? data.firstIndex(of: 0) : nil
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
        let visibleMatches = matchesBeforeBinary(result.matches, binaryByteOffset: binaryByteOffset, options: options)
        let emittedMatches = shouldEmitSuppressedBinaryMatches(options, isExplicit: true)
            ? result.matches
            : visibleMatches
        let hasBinaryMatch = hasBinaryMatchResult(
            result: result,
            visibleMatches: visibleMatches,
            options: options
        )
        let lineNumberShifts = jsonBinaryLineNumberShifts(for: result.lines, options: options)
        let displayMatches = options.json
            ? jsonBinaryDisplayMatches(emittedMatches, lineNumberShifts: lineNumberShifts, options: options)
            : emittedMatches
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
            guard !match.spans.isEmpty else {
                return match.absoluteOffset + byteCount(match.line, options: options) <= binaryByteOffset
            }
            return match.spans.contains { span in
                match.absoluteOffset + span.endByte <= binaryByteOffset
            }
        }
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
                options: options
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
        options: RipgrepOptions,
        isExplicit: Bool
    ) -> SearchFileResult {
        guard !options.disablesBinaryDetection,
              shouldCheckBinary(data, options: options),
              let binaryByteOffset = data.firstIndex(of: 0) else {
            return result
        }
        let binaryDetectedBeforeSearch = binaryByteOffset < Self.binaryDetectionBufferSize
        let visibleMatches = matchesBeforeBinary(result.matches, binaryByteOffset: binaryByteOffset, options: options)
        let emittedMatches = shouldEmitSuppressedBinaryMatches(options, isExplicit: isExplicit)
            ? result.matches
            : visibleMatches
        let hasBinaryMatch = hasBinaryMatchResult(
            result: result,
            visibleMatches: visibleMatches,
            options: options
        )
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
            matches: emittedMatches,
            lines: displayLines,
            binaryByteOffset: binaryByteOffset,
            hasBinaryMatch: hasBinaryMatch,
            stoppedBinaryAfterMatch: options.binaryMode == .automatic && !isExplicit,
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
        let shouldSplitBinaryNUL = splitBinaryNUL && !options.disablesBinaryDetection
        if options.multiline && !options.invertMatch {
            let shouldSplitMultilineBinaryNUL = shouldSplitBinaryNUL
                && options.printMode == .countMatches
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
                terminator: splitLine.terminator,
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
        if !terminator.isEmpty,
           options.effectivePatterns.allSatisfy(isPlainDisabledMultilineLineEndAnchorPattern) {
            let recordEnd = byteCount(matchingLine, options: options)
            let filtered = spans.filter { $0.endByte < recordEnd }
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

    private func containsDisabledMultilineLineEndAnchor(_ pattern: String) -> Bool {
        containsDisabledMultilineLineEndAnchor(in: pattern, multilineEnabled: true)
    }

    private func isPlainDisabledMultilineLineEndAnchorPattern(_ pattern: String) -> Bool {
        containsDisabledMultilineLineEndAnchor(pattern) && !containsTopLevelAlternation(pattern)
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

    private func containsTopLevelAlternation(_ pattern: String) -> Bool {
        var escaped = false
        var inClass = false
        var depth = 0

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
            if inClass {
                continue
            }
            if character == "(" {
                depth += 1
                continue
            }
            if character == ")" {
                depth = max(0, depth - 1)
                continue
            }
            if character == "|", depth == 0 {
                return true
            }
        }
        return false
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
                matcher.spans(in: matchingContents),
                rawLine: rawContentsForSpanAdjustment,
                options: options
            ),
            in: matchingContents,
            options: options
        )
        if spans.isEmpty,
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
            return encoding != .utf16LittleEndian && encoding != .utf16BigEndian
        case .disabled:
            return true
        case .automatic:
            return !(data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]))
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

    private func decodeExplicit(_ data: Data, encoding: String.Encoding) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = data.dropFirst(3)
            if encoding == .utf16LittleEndian {
                return decodeUTF16(body, littleEndian: true)
            }
            if encoding == .utf16BigEndian {
                return decodeUTF16(body, littleEndian: false)
            }
            return decodeSlice(body, encoding: encoding)
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
