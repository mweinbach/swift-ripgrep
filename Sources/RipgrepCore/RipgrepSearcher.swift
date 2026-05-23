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
                    searchFile(haystack.url, matcher: matcher, options: options)
                }

        if options.useStdin {
            let input = stdin ?? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            files.append(searchContents(input, fileURL: URL(fileURLWithPath: "-"), matcher: matcher, options: options))
        }

        files.sort { lhs, rhs in
            lhs.fileURL.path < rhs.fileURL.path
        }

        let matchedFiles = files.filter { !$0.matches.isEmpty }
        let summary = SearchSummary(
            filesSearched: files.filter(\.searched).count,
            filesWithMatches: matchedFiles.count,
            matchedLines: matchedFiles.reduce(0) { $0 + $1.matches.count },
            totalMatches: matchedFiles.reduce(0) { total, file in
                total + file.matches.reduce(0) { $0 + $1.matchCount }
            }
        )

        return SearchResults(files: files, summary: summary)
    }

    private func searchFile(
        _ fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> SearchFileResult {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return SearchFileResult(fileURL: fileURL, matches: [], searched: false)
        }

        return searchContents(contents, fileURL: fileURL, matcher: matcher, options: options)
    }

    private func searchContents(
        _ contents: String,
        fileURL: URL,
        matcher: PatternMatcher,
        options: RipgrepOptions
    ) -> SearchFileResult {
        var matches: [SearchMatch] = []
        var lines = contents.components(separatedBy: "\n")
        if contents.hasSuffix("\n") {
            lines.removeLast()
        }
        var searchLines: [SearchLine] = []

        for (offset, lineFragment) in lines.enumerated() {
            var line = lineFragment
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            let lineNumber = offset + 1
            searchLines.append(SearchLine(lineNumber: lineNumber, line: line))

            let spans = matcher.spans(in: line)
            guard !spans.isEmpty else {
                continue
            }

            matches.append(SearchMatch(
                fileURL: fileURL,
                lineNumber: lineNumber,
                column: options.column ? spans[0].startColumn : nil,
                line: line,
                matchCount: spans.count,
                spans: spans
            ))
        }

        return SearchFileResult(fileURL: fileURL, matches: matches, lines: searchLines)
    }
}
