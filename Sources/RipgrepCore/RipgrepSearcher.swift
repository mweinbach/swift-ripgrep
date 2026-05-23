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
    let displayCommand: String
}

public struct RipgrepSearcher {
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

    public func search(options: RipgrepOptions) throws -> SearchResults {
        try search(options: options, stdin: nil)
    }

    public func search(options: RipgrepOptions, stdin: String?) throws -> SearchResults {
        guard !options.effectivePatterns.isEmpty else {
            throw RipgrepError.emptyPattern
        }

        let matcher = try PatternMatcher(options: options)
        let walkResults = options.useStdin && options.roots.isEmpty
            ? FileWalkResults(haystacks: [], messages: [])
            : try FileWalker(fileManager: fileManager)
                .withEnvironment(environment)
                .haystacksWithMessages(for: options)
        var messages = walkResults.messages
        var files = walkResults.haystacks.map { haystack in
            let outcome = searchFile(haystack, matcher: matcher, options: options)
            if let message = outcome.message {
                messages.append(message)
            }
            return outcome.result
        }

        if options.useStdin {
            let input = stdin ?? decode(FileHandle.standardInput.readDataToEndOfFile(), options: options)
            files.append(searchContents(input, fileURL: URL(fileURLWithPath: "-"), matcher: matcher, options: options))
        }

        files = sorted(files, options: options)

        let matchedFiles = files.filter(\.hasMatch)
        let summary = SearchSummary(
            filesSearched: files.filter(\.searched).count,
            filesWithMatches: matchedFiles.count,
            matchedLines: matchedFiles.reduce(0) { total, file in
                total + file.matches.reduce(0) { $0 + matchedLineCount($1) }
            },
            totalMatches: matchedFiles.reduce(0) { total, file in
                total + file.matches.reduce(0) { $0 + $1.matchCount } + (file.hasBinaryMatch ? 1 : 0)
            }
        )

        return SearchResults(files: files, summary: summary, messages: messages)
    }

    private func matchedLineCount(_ match: SearchMatch) -> Int {
        let terminator: Character = match.lineWithTerminator.contains("\0") ? "\0" : "\n"
        let count = match.lineWithTerminator.filter { $0 == terminator }.count
        return max(1, count)
    }

    private func sorted(_ files: [SearchFileResult], options: RipgrepOptions) -> [SearchFileResult] {
        guard let sortMode = options.sortMode else {
            return files.sorted { $0.fileURL.path < $1.fileURL.path }
        }
        return files.sorted { lhs, rhs in
            let order = compare(lhs.fileURL, rhs.fileURL, by: sortMode.kind)
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
                originalData: data,
                command: decompressionCommand,
                matcher: matcher,
                options: options
            )
        }

        let binaryByteOffset = shouldCheckBinary(data, options: options) ? data.firstIndex(of: 0) : nil
        if let binaryByteOffset, options.binaryMode != .asText {
            if options.binaryMode == .automatic && !haystack.isExplicit {
                return FileSearchOutcome(result: SearchFileResult(fileURL: fileURL, matches: [], searched: false))
            }

            let contents = decode(data, options: options)
            let result = searchContents(contents, fileURL: fileURL, matcher: matcher, options: options)
            return FileSearchOutcome(result: SearchFileResult(
                fileURL: fileURL,
                matches: [],
                lines: result.lines,
                binaryByteOffset: binaryByteOffset,
                hasBinaryMatch: result.hasMatch,
                bytesSearched: data.count
            ))
        }

        let contents = decode(data, options: options)
        let result = searchContents(contents, fileURL: fileURL, matcher: matcher, options: options)
        return FileSearchOutcome(result: SearchFileResult(
            fileURL: result.fileURL,
            matches: result.matches,
            lines: result.lines,
            bytesSearched: data.count,
            searched: result.searched
        ))
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
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command, fileURL.path]

            let input = try FileHandle(forReadingFrom: fileURL)
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            try process.run()
            input.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return FileSearchOutcome(
                    result: SearchFileResult(fileURL: fileURL, matches: [], searched: false),
                    message: "\(fileURL.path): preprocessor command failed: '\"\(command)\" \"\(fileURL.path)\"': <stderr is empty>"
                )
            }

            let contents = decode(data, options: options)
            let result = searchContents(contents, fileURL: fileURL, matcher: matcher, options: options)
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
                message: "\(fileURL.path): preprocessor command could not start: '\(command)': \(error)"
            )
        }
    }

    private func searchDecompressedFile(
        _ fileURL: URL,
        originalData: Data,
        command: DecompressionCommand,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> FileSearchOutcome {
        do {
            let data = try runStreamingCommand(
                executable: command.executable,
                arguments: command.arguments,
                inputFile: fileURL
            )
            let contents = decode(data, options: options)
            let result = searchContents(contents, fileURL: fileURL, matcher: matcher, options: options)
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
                message: "\(fileURL.path): decompression command failed: '\(command.displayCommand)': \(error)"
            )
        }
    }

    private func runStreamingCommand(
        executable: URL,
        arguments: [String],
        inputFile: URL
    ) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let input = try FileHandle(forReadingFrom: inputFile)
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
            let stderrText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RipgrepError.message(stderrText?.isEmpty == false ? stderrText! : "<stderr is empty>")
        }
        return data
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
            arguments: spec.arguments,
            displayCommand: ([spec.program] + spec.arguments).joined(separator: " ")
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
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> SearchFileResult {
        if options.multiline && !options.invertMatch {
            return searchMultilineContents(contents, fileURL: fileURL, matcher: matcher, options: options)
        }

        var matches: [SearchMatch] = []
        let lines = splitLines(contents, options: options)
        var searchLines: [SearchLine] = []
        var absoluteOffset = 0
        let maxCount = options.maxCount ?? Int.max
        var hasMatched = false

        for (offset, splitLine) in lines.enumerated() {
            let line = splitLine.text
            let lineNumber = offset + 1
            searchLines.append(SearchLine(
                lineNumber: lineNumber,
                line: line,
                lineTerminator: splitLine.terminator,
                absoluteOffset: absoluteOffset
            ))

            guard matches.count < maxCount else {
                absoluteOffset += splitLine.text.utf8.count + splitLine.terminator.utf8.count
                continue
            }

            let spans = matcher.spans(in: line)
            guard !spans.isEmpty else {
                absoluteOffset += splitLine.text.utf8.count + splitLine.terminator.utf8.count
                if options.stopOnNonmatch && hasMatched {
                    break
                }
                continue
            }

            hasMatched = true
            matches.append(SearchMatch(
                fileURL: fileURL,
                lineNumber: lineNumber,
                column: options.column ? spans[0].startColumn : nil,
                line: line,
                lineTerminator: splitLine.terminator,
                absoluteOffset: absoluteOffset,
                matchCount: spans.count,
                spans: spans
            ))
            absoluteOffset += splitLine.text.utf8.count + splitLine.terminator.utf8.count
        }

        return SearchFileResult(fileURL: fileURL, matches: matches, lines: searchLines)
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
            absoluteOffset += splitLine.text.utf8.count + splitLine.terminator.utf8.count
        }

        let spans = matcher.spans(in: contents)
        let limitedSpans = Array(spans.prefix(options.maxCount ?? Int.max))
        let matches = limitedSpans.compactMap { span -> SearchMatch? in
            guard let startLineIndex = lineIndex(containingByteOffset: span.startByte, lineStartOffsets: lineStartOffsets),
                  let endLineIndex = lineIndex(containingByteOffset: max(span.endByte - 1, span.startByte), lineStartOffsets: lineStartOffsets) else {
                return nil
            }

            let blockLines = searchLines[startLineIndex...endLineIndex]
            let blockText = blockLines.map(\.lineWithTerminator).joined()
            let blockOffset = searchLines[startLineIndex].absoluteOffset
            let adjustedSpan = MatchSpan(
                startColumn: span.startColumn,
                endColumn: span.endColumn,
                startByte: span.startByte - blockOffset,
                endByte: span.endByte - blockOffset,
                text: span.text,
                replacement: span.replacement
            )

            return SearchMatch(
                fileURL: fileURL,
                lineNumber: startLineIndex + 1,
                column: options.column ? span.startColumn : nil,
                line: blockText,
                lineTerminator: "",
                absoluteOffset: blockOffset,
                matchCount: 1,
                spans: [adjustedSpan]
            )
        }

        return SearchFileResult(fileURL: fileURL, matches: matches, lines: searchLines)
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
            return decode(data, encoding: encoding)
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

    private func splitLines(_ contents: String, options: RipgrepOptions) -> [(text: String, terminator: String)] {
        if options.nullData {
            return splitNulDelimited(contents)
        }

        var lines: [(String, String)] = []
        var current = String.UnicodeScalarView()

        for scalar in contents.unicodeScalars {
            if scalar == "\n" {
                lines.append((String(current), "\n"))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(scalar)
            }
        }

        if !current.isEmpty || !lastScalar(in: contents, equals: "\n") {
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

    private func lastScalar(in contents: String, equals expected: UnicodeScalar) -> Bool {
        guard let last = contents.unicodeScalars.last else {
            return false
        }
        return last == expected
    }
}
