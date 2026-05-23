import Foundation

public struct RipgrepSearcher {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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
        var files = options.useStdin && options.roots.isEmpty
            ? []
            : try FileWalker(fileManager: fileManager)
                .haystacks(for: options)
                .map { haystack in
                    searchFile(haystack, matcher: matcher, options: options)
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
            matchedLines: matchedFiles.reduce(0) { $0 + $1.matches.count },
            totalMatches: matchedFiles.reduce(0) { total, file in
                total + file.matches.reduce(0) { $0 + $1.matchCount } + (file.hasBinaryMatch ? 1 : 0)
            }
        )

        return SearchResults(files: files, summary: summary)
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
    ) -> SearchFileResult {
        let fileURL = haystack.url
        guard let data = try? Data(contentsOf: fileURL) else {
            return SearchFileResult(fileURL: fileURL, matches: [], searched: false)
        }

        let binaryByteOffset = shouldCheckBinary(data, options: options) ? data.firstIndex(of: 0) : nil
        if let binaryByteOffset, options.binaryMode != .asText {
            if options.binaryMode == .automatic && !haystack.isExplicit {
                return SearchFileResult(fileURL: fileURL, matches: [], searched: false)
            }

            let contents = decode(data, options: options)
            let result = searchContents(contents, fileURL: fileURL, matcher: matcher, options: options)
            return SearchFileResult(
                fileURL: fileURL,
                matches: [],
                lines: result.lines,
                binaryByteOffset: binaryByteOffset,
                hasBinaryMatch: result.hasMatch,
                bytesSearched: data.count
            )
        }

        let contents = decode(data, options: options)
        let result = searchContents(contents, fileURL: fileURL, matcher: matcher, options: options)
        return SearchFileResult(
            fileURL: result.fileURL,
            matches: result.matches,
            lines: result.lines,
            bytesSearched: data.count,
            searched: result.searched
        )
    }

    private func searchContents(
        _ contents: String,
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> SearchFileResult {
        var matches: [SearchMatch] = []
        let lines = splitLines(contents, options: options)
        var searchLines: [SearchLine] = []
        var absoluteOffset = 0
        let maxCount = options.maxCount ?? Int.max

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
                continue
            }

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
        var current = ""
        var index = contents.startIndex

        while index < contents.endIndex {
            let character = contents[index]
            if character == "\n" {
                if current.hasSuffix("\r") {
                    current.removeLast()
                    lines.append((current, "\r\n"))
                } else {
                    lines.append((current, "\n"))
                }
                current = ""
            } else {
                current.append(character)
            }
            index = contents.index(after: index)
        }

        if !current.isEmpty || !contents.hasSuffix("\n") {
            lines.append((current, ""))
        }
        return lines
    }

    private func splitNulDelimited(_ contents: String) -> [(text: String, terminator: String)] {
        var lines: [(String, String)] = []
        var current = ""
        for character in contents {
            if character == "\0" {
                lines.append((current, "\0"))
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty || !contents.hasSuffix("\0") {
            lines.append((current, ""))
        }
        return lines
    }
}
