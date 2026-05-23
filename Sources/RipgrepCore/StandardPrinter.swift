import Foundation

public struct StandardPrinter {
    private let options: RipgrepOptions
    private let currentDirectory: String

    public init(
        options: RipgrepOptions,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.options = options
        self.currentDirectory = URL(fileURLWithPath: currentDirectory)
            .standardizedFileURL
            .path
    }

    public func lines(for results: SearchResults) -> [String] {
        guard !options.quiet else {
            return []
        }

        let body = bodyLines(for: results)
        if options.stats, options.printMode == .matchingLines {
            return body + statsLines(for: results, bytesPrinted: bytesPrinted(body))
        }
        return body
    }

    private func bodyLines(for results: SearchResults) -> [String] {
        switch options.printMode {
        case .matchingLines:
            if options.vimgrep {
                return results.files.flatMap { result in
                    formatVimgrep(result)
                }
            }
            if options.heading == true {
                return headingLines(for: results)
            }
            if options.onlyMatching {
                return results.files.flatMap { result in
                    if let binaryLine = formatBinaryMatch(result, showPath: showPath(for: results)) {
                        return [binaryLine]
                    }
                    return result.matches.flatMap { formatOnlyMatching($0, showPath: showPath(for: results)) }
                }
            }
            if options.passthru || options.beforeContext > 0 || options.afterContext > 0 {
                return results.files.flatMap { contextLines(for: $0, showPath: showPath(for: results)) }
            }
            return results.files.flatMap { result in
                if let binaryLine = formatBinaryMatch(result, showPath: showPath(for: results)) {
                    return [binaryLine]
                }
                return result.matches.flatMap { formatSearchMatch($0, showPath: showPath(for: results)) }
            }
        case .count:
            return results.files.filter { options.includeZero ? $0.searched : $0.hasMatch }.map { result in
                let count = options.onlyMatching
                    ? result.matches.reduce(0) { $0 + $1.matchCount }
                    : result.matches.count + (result.hasBinaryMatch ? 1 : 0)
                if showPath(for: results) {
                    return "\(displayPath(for: result.fileURL))\(pathFieldSeparator())\(count)"
                }
                return "\(count)"
            }
        case .countMatches:
            return results.files.filter { options.includeZero ? $0.searched : $0.hasMatch }.map { result in
                let count = result.matches.reduce(0) { $0 + $1.matchCount } + (result.hasBinaryMatch ? 1 : 0)
                if showPath(for: results) {
                    return "\(displayPath(for: result.fileURL))\(pathFieldSeparator())\(count)"
                }
                return "\(count)"
            }
        case .filesWithMatches:
            return results.files
                .filter(\.hasMatch)
                .map { "\(displayPath(for: $0.fileURL))\(pathTerminator())" }
        case .filesWithoutMatch:
            return results.files
                .filter { !$0.hasMatch }
                .map { "\(displayPath(for: $0.fileURL))\(pathTerminator())" }
        }
    }

    public func paths(_ urls: [URL]) -> [String] {
        urls.map { "\(displayPath(for: $0))\(pathTerminator())" }
    }

    private func format(_ match: SearchMatch, showPath: Bool) -> String {
        var fields: [String] = []
        let path = showPath ? displayPath(for: match.fileURL) : nil
        if options.wantsLineNumber {
            fields.append("\(match.lineNumber)")
        }
        if options.column, let column = match.column {
            fields.append("\(column)")
        }
        if options.byteOffset {
            fields.append("\(match.absoluteOffset)")
        }

        return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(renderedLine(for: match))"
    }

    private func formatSearchMatch(_ match: SearchMatch, showPath: Bool) -> [String] {
        guard options.multiline, match.line.contains("\n") || match.line.contains("\0") else {
            return [format(match, showPath: showPath)]
        }

        return splitRenderedLines(match.lineWithTerminator).enumerated().map { offset, line in
            var fields: [String] = []
            let path = showPath ? displayPath(for: match.fileURL) : nil
            if options.wantsLineNumber {
                fields.append("\(match.lineNumber + offset)")
            }
            let rendered = renderedLine(line)
            return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(rendered)"
        }
    }

    private func formatVimgrep(_ result: SearchFileResult) -> [String] {
        result.matches.flatMap { match in
            match.spans.map { span in
                let text = options.onlyMatching
                    ? (span.replacement ?? span.text)
                    : renderedLine(match.line)
                return "\(displayPath(for: match.fileURL))\(matchPathFieldSeparator())\(match.lineNumber)\(options.fieldMatchSeparator)\(span.startColumn)\(options.fieldMatchSeparator)\(text)\(outputTerminator(match.lineTerminator))"
            }
        }
    }

    private func formatBinaryMatch(_ result: SearchFileResult, showPath: Bool) -> String? {
        guard result.hasBinaryMatch, let offset = result.binaryByteOffset else {
            return nil
        }
        let message = #"binary file matches (found "\0" byte around offset \#(offset))"#
        if showPath {
            return "\(displayPath(for: result.fileURL))\(matchPathFieldSeparator()) \(message)"
        }
        return message
    }

    private func formatOnlyMatching(_ match: SearchMatch, showPath: Bool) -> [String] {
        match.spans.map { span in
            var fields: [String] = []
            let path = showPath ? displayPath(for: match.fileURL) : nil
            if options.wantsLineNumber {
                fields.append("\(match.lineNumber)")
            }
            if options.column {
                fields.append("\(span.startColumn)")
            }
            if options.byteOffset {
                fields.append("\(match.absoluteOffset + span.startByte)")
            }
            let text = "\(span.replacement ?? span.text)\(outputTerminator(match.lineTerminator))"
            return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(text)"
        }
    }

    private func headingLines(for results: SearchResults) -> [String] {
        var output: [String] = []
        for result in results.files {
            let lines: [String]
            if let binaryLine = formatBinaryMatch(result, showPath: false) {
                lines = [binaryLine]
            } else if options.onlyMatching {
                lines = result.matches.flatMap { formatOnlyMatching($0, showPath: false) }
            } else if options.passthru || options.beforeContext > 0 || options.afterContext > 0 {
                lines = contextLines(for: result, showPath: false)
            } else {
                lines = result.matches.flatMap { formatSearchMatch($0, showPath: false) }
            }
            guard !lines.isEmpty else {
                continue
            }
            if !output.isEmpty {
                output.append("")
            }
            output.append(displayPath(for: result.fileURL))
            output.append(contentsOf: lines)
        }
        return output
    }

    private func contextLines(for result: SearchFileResult, showPath: Bool) -> [String] {
        let matchesByLine = Dictionary(uniqueKeysWithValues: result.matches.map { ($0.lineNumber, $0) })
        let selectedLineNumbers: [Int]
        if options.passthru {
            selectedLineNumbers = result.lines.map(\.lineNumber)
        } else {
            let lineCount = result.lines.count
            let selected = result.matches.reduce(into: Set<Int>()) { lineNumbers, match in
                let lower = max(1, match.lineNumber - options.beforeContext)
                let upper = min(lineCount, match.lineNumber + options.afterContext)
                for lineNumber in lower...upper {
                    lineNumbers.insert(lineNumber)
                }
            }
            selectedLineNumbers = selected.sorted()
        }

        var output: [String] = []
        var previous: Int?
        for lineNumber in selectedLineNumbers {
            if let previous, lineNumber > previous + 1, !options.passthru {
                if let contextSeparator = options.contextSeparator {
                    output.append(contextSeparator)
                }
            }
            guard let line = result.lines.first(where: { $0.lineNumber == lineNumber }) else {
                continue
            }
            if let match = matchesByLine[lineNumber] {
                output.append(format(match, showPath: showPath))
            } else {
                output.append(formatContextLine(line, fileURL: result.fileURL, showPath: showPath))
            }
            previous = lineNumber
        }
        return output
    }

    private func formatContextLine(_ line: SearchLine, fileURL: URL, showPath: Bool) -> String {
        var fields: [String] = []
        let path = showPath ? displayPath(for: fileURL) : nil
        if options.wantsLineNumber {
            fields.append("\(line.lineNumber)")
        }

        return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldContextSeparator))\(renderedLine(line.line))\(outputTerminator(line.lineTerminator))"
    }

    private func renderedLine(for match: SearchMatch) -> String {
        guard options.replacement != nil, !match.spans.isEmpty else {
            return "\(renderedLine(match.line))\(outputTerminator(match.lineTerminator))"
        }
        var line = match.line
        for span in match.spans.sorted(by: { $0.startColumn > $1.startColumn }) {
            guard let replacement = span.replacement,
                  let range = indexRange(startColumn: span.startColumn, endColumn: span.endColumn, in: line) else {
                continue
            }
            line.replaceSubrange(range, with: replacement)
        }
        return "\(renderedLine(line))\(outputTerminator(match.lineTerminator))"
    }

    private func renderedLine(_ line: String) -> String {
        let trimmed = options.trim ? line.trimmingASCIIWhitespacePrefix() : line
        return limitedLine(trimmed)
    }

    private func outputTerminator(_ terminator: String) -> String {
        options.nullData ? terminator : ""
    }

    private func pathTerminator() -> String {
        options.nullPathTerminator ? "\0" : ""
    }

    private func pathFieldSeparator() -> String {
        options.nullPathTerminator ? "\0" : ":"
    }

    private func matchPathFieldSeparator() -> String {
        options.nullPathTerminator ? "\0" : options.fieldMatchSeparator
    }

    private func prefix(path: String?, fields: [String], fieldSeparator: String) -> String {
        var prefix = ""
        if let path {
            prefix += path
            prefix += options.nullPathTerminator ? "\0" : fieldSeparator
        }
        if !fields.isEmpty {
            prefix += fields.joined(separator: fieldSeparator)
            prefix += fieldSeparator
        }
        return prefix
    }

    private func limitedLine(_ line: String) -> String {
        guard let maxColumns = options.maxColumns, line.utf8.count >= maxColumns else {
            return line
        }
        guard options.maxColumnsPreview else {
            return "[Omitted long matching line]"
        }
        return "\(line.prefixBytes(maxColumns)) [... omitted end of long line]"
    }

    private func splitRenderedLines(_ text: String) -> [String] {
        let terminator: Character = text.contains("\0") ? "\0" : "\n"
        var lines: [String] = []
        var current = ""
        for character in text {
            if character == terminator {
                lines.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty || text.last != terminator {
            lines.append(current)
        }
        return lines
    }

    private func indexRange(startColumn: Int, endColumn: Int, in line: String) -> Range<String.Index>? {
        let lowerOffset = startColumn - 1
        let upperOffset = endColumn - 1
        guard lowerOffset >= 0, upperOffset >= lowerOffset, upperOffset <= line.count else {
            return nil
        }
        return line.index(line.startIndex, offsetBy: lowerOffset)..<line.index(line.startIndex, offsetBy: upperOffset)
    }

    private func showPath(for results: SearchResults) -> Bool {
        if let withFilename = options.withFilename {
            return withFilename
        }
        if options.useStdin {
            return !options.roots.isEmpty
        }
        return results.files.count > 1 || options.effectiveRoots.contains { isDirectory($0) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func displayPath(for url: URL) -> String {
        if url.path == "-" {
            return "<stdin>"
        }

        let path = url.standardizedFileURL.path
        let prefix = currentDirectory.hasSuffix("/") ? currentDirectory : "\(currentDirectory)/"

        if path.hasPrefix(prefix) {
            return applyPathSeparator(String(path.dropFirst(prefix.count)))
        }

        return applyPathSeparator(path)
    }

    private func applyPathSeparator(_ path: String) -> String {
        guard let pathSeparator = options.pathSeparator else {
            return path
        }
        return String(path.map { $0 == "/" ? pathSeparator : $0 })
    }

    private func statsLines(for results: SearchResults, bytesPrinted: Int) -> [String] {
        [
            "",
            "\(results.summary.totalMatches) matches",
            "\(results.summary.matchedLines) matched lines",
            "\(results.summary.filesWithMatches) files contained matches",
            "\(results.summary.filesSearched) files searched",
            "\(bytesPrinted) bytes printed",
            "\(results.files.reduce(0) { $0 + $1.bytesSearched }) bytes searched",
            "0.000000 seconds spent searching",
            "0.000000 seconds total",
        ]
    }

    private func bytesPrinted(_ lines: [String]) -> Int {
        lines.reduce(0) { total, line in
            total + line.utf8.count + 1
        }
    }
}

private extension String {
    func trimmingASCIIWhitespacePrefix() -> String {
        let firstNonWhitespace = firstIndex { character in
            character != " " && character != "\t" && character != "\r" && character != "\n"
        }
        guard let firstNonWhitespace else {
            return ""
        }
        return String(self[firstNonWhitespace...])
    }

    func prefixBytes(_ byteCount: Int) -> String {
        guard byteCount > 0 else {
            return ""
        }
        var output = ""
        var bytes = 0
        for character in self {
            let width = String(character).utf8.count
            guard bytes + width <= byteCount else {
                break
            }
            output.append(character)
            bytes += width
        }
        return output
    }
}
