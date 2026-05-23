import Foundation

public struct StandardPrinter {
    private let options: RipgrepOptions
    private let pathFormatter: OutputPathFormatter
    private let colors: ANSIColorPalette
    private let hyperlinks: HyperlinkFormatter

    public init(
        options: RipgrepOptions,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.options = options
        self.pathFormatter = OutputPathFormatter(options: options, currentDirectory: currentDirectory)
        let colorPalette = ANSIColorPalette(options: options)
        self.colors = colorPalette
        self.hyperlinks = HyperlinkFormatter(options: options, colorsEnabled: colorPalette.isEnabled)
    }

    public func lines(for results: SearchResults) -> [String] {
        if options.quiet && options.stats {
            return statsLines(for: results, bytesPrinted: 0)
        }
        if options.quiet {
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
                    if let binaryLine = formatBinaryMatch(result, showPath: options.withFilename != false) {
                        return [binaryLine]
                    }
                    return formatVimgrep(result, showPath: options.withFilename != false)
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
            if options.multiline, options.replacement == nil {
                return results.files.flatMap { multilineMatchLines(for: $0, showPath: showPath(for: results)) }
            }
            return results.files.flatMap { result in
                let matchLines = result.matches.flatMap { formatSearchMatch($0, showPath: showPath(for: results)) }
                if let binaryLine = formatBinaryMatch(result, showPath: showPath(for: results)) {
                    return matchLines + [binaryLine]
                }
                return matchLines
            }
        case .count:
            return countResults(for: results).map { result in
                let count = options.onlyMatching
                    ? result.matches.reduce(0) { $0 + $1.matchCount }
                    : result.matches.isEmpty && result.hasBinaryMatch ? 1 : result.matches.count
                if showPath(for: results) {
                    return "\(renderPath(for: result.fileURL))\(pathFieldSeparator())\(count)"
                }
                return "\(count)"
            }
        case .countMatches:
            return countResults(for: results).map { result in
                let count = result.matches.isEmpty && result.hasBinaryMatch ? 1 : result.matches.reduce(0) { $0 + $1.matchCount }
                if showPath(for: results) {
                    return "\(renderPath(for: result.fileURL))\(pathFieldSeparator())\(count)"
                }
                return "\(count)"
            }
        case .filesWithMatches:
            return results.files
                .filter(\.hasMatch)
                .map { "\(renderPath(for: $0.fileURL))\(pathTerminator())" }
        case .filesWithoutMatch:
            return results.files
                .filter { $0.searched && !$0.hasMatch }
                .map { "\(renderPath(for: $0.fileURL))\(pathTerminator())" }
        }
    }

    private func countable(_ result: SearchFileResult) -> Bool {
        if result.stoppedBinaryAfterMatch {
            return false
        }
        return options.includeZero ? result.searched : result.hasMatch
    }

    private func countResults(for results: SearchResults) -> [SearchFileResult] {
        let files = results.files.filter { countable($0) }
        guard options.includeZero, options.sortMode == nil else {
            return files
        }
        return files.sorted { lhs, rhs in
            if lhs.hasMatch != rhs.hasMatch {
                return !lhs.hasMatch
            }
            return false
        }
    }

    public func paths(_ urls: [URL]) -> [String] {
        urls.map { "\(renderPath(for: $0))\(pathTerminator())" }
    }

    private func format(_ match: SearchMatch, showPath: Bool) -> String {
        var fields: [OutputField] = []
        let path = showPath ? renderPath(for: match.fileURL, line: match.lineNumber, column: match.column) : nil
        if options.wantsLineNumber {
            fields.append(OutputField("\(match.lineNumber)", colorTarget: .line))
        }
        if options.column, let column = match.column {
            fields.append(OutputField("\(column)", colorTarget: .column))
        }
        if options.byteOffset {
            fields.append(OutputField("\(match.absoluteOffset)", colorTarget: nil))
        }

        return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(renderedLine(for: match))"
    }

    private func formatSearchMatch(_ match: SearchMatch, showPath: Bool) -> [String] {
        guard options.multiline, match.line.contains("\n") || match.line.contains("\0") else {
            return [format(match, showPath: showPath)]
        }

        let text = options.replacement == nil ? match.lineWithTerminator : renderedText(for: match)
        return splitRenderedLines(text).enumerated().map { offset, line in
            var fields: [OutputField] = []
            let path = showPath ? renderPath(for: match.fileURL, line: match.lineNumber + offset) : nil
            if options.wantsLineNumber {
                fields.append(OutputField("\(match.lineNumber + offset)", colorTarget: .line))
            }
            let rendered = renderedLine(line)
            return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(rendered)"
        }
    }

    private func formatVimgrep(_ result: SearchFileResult, showPath: Bool) -> [String] {
        result.matches.flatMap { match in
            match.spans.map { span in
                let text = options.onlyMatching
                    ? (span.replacement ?? span.text)
                    : vimgrepLineText(for: match)
                let fields = vimgrepFields(
                    lineNumber: match.lineNumber,
                    column: span.startColumn,
                    text: text
                )
                guard showPath else {
                    return "\(fields.joined(separator: options.fieldMatchSeparator))\(outputTerminator(match.lineTerminator))"
                }
                let path = renderPath(for: match.fileURL, line: match.lineNumber, column: span.startColumn)
                return "\(path)\(matchPathFieldSeparator())\(fields.joined(separator: options.fieldMatchSeparator))\(outputTerminator(match.lineTerminator))"
            }
        }
    }

    private func vimgrepFields(lineNumber: Int, column: Int, text: String) -> [String] {
        var fields: [String] = []
        if !options.noLineNumber {
            fields.append("\(lineNumber)")
        }
        if !options.noColumn {
            fields.append("\(column)")
        }
        fields.append(text)
        return fields
    }

    private func vimgrepLineText(for match: SearchMatch) -> String {
        let line = firstRenderedLine(match.line)
        if let maxColumns = options.maxColumns,
           options.maxColumnsPreview,
           line.utf8.count >= maxColumns {
            let rendered = options.trim ? line.trimmingASCIIWhitespacePrefix() : line
            return previewLineSuffix(rendered, maxColumns: maxColumns, remainingMatches: 0)
        }
        return renderedLine(line)
    }

    private func formatBinaryMatch(_ result: SearchFileResult, showPath: Bool) -> String? {
        guard result.hasBinaryMatch, let offset = result.binaryByteOffset else {
            return nil
        }
        let message = result.stoppedBinaryAfterMatch
            ? #"WARNING: stopped searching binary file after match (found "\0" byte around offset \#(offset))"#
            : #"binary file matches (found "\0" byte around offset \#(offset))"#
        if showPath {
            return "\(renderPath(for: result.fileURL))\(matchPathFieldSeparator()) \(message)"
        }
        return message
    }

    private func formatOnlyMatching(_ match: SearchMatch, showPath: Bool) -> [String] {
        match.spans.flatMap { span in
            if options.multiline, span.text.contains("\n") || span.text.contains("\0") {
                return formatOnlyMatchingMultiline(span, in: match, showPath: showPath)
            }
            var fields: [OutputField] = []
            let path = showPath ? renderPath(for: match.fileURL, line: match.lineNumber, column: span.startColumn) : nil
            if options.wantsLineNumber {
                fields.append(OutputField("\(match.lineNumber)", colorTarget: .line))
            }
            if options.column {
                fields.append(OutputField("\(span.startColumn)", colorTarget: .column))
            }
            if options.byteOffset {
                fields.append(OutputField("\(match.absoluteOffset + span.startByte)", colorTarget: nil))
            }
            let text = "\(onlyMatchingText(span, in: match))\(outputTerminator(match.lineTerminator, line: match.line))"
            return ["\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(text)"]
        }
    }

    private func formatOnlyMatchingMultiline(_ span: MatchSpan, in match: SearchMatch, showPath: Bool) -> [String] {
        let text = span.replacement ?? span.text
        let chunks = splitRenderedLines(text)
        let startLineOffset = lineOffset(in: match.lineWithTerminator, beforeByteOffset: span.startByte)
        var runningByteOffset = match.absoluteOffset + span.startByte

        return chunks.enumerated().map { offset, chunk in
            let lineNumber = match.lineNumber + startLineOffset + offset
            var fields: [OutputField] = []
            let column = offset == 0 ? span.startColumn : 1
            let path = showPath ? renderPath(for: match.fileURL, line: lineNumber, column: column) : nil
            if options.wantsLineNumber {
                fields.append(OutputField("\(lineNumber)", colorTarget: .line))
            }
            if options.column {
                fields.append(OutputField("\(column)", colorTarget: .column))
            }
            if options.byteOffset {
                fields.append(OutputField("\(runningByteOffset)", colorTarget: nil))
            }
            runningByteOffset += chunk.utf8.count + 1
            return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(colors.apply(.match, to: chunk))\(outputTerminator(match.lineTerminator, line: chunk))"
        }
    }

    private func headingLines(for results: SearchResults) -> [String] {
        var output: [String] = []
        let showPath = showPath(for: results)
        for result in results.files {
            if result.matches.isEmpty,
               let binaryLine = formatBinaryMatch(result, showPath: showPath) {
                output.append(binaryLine)
                continue
            }
            let lines: [String]
            if let binaryLine = formatBinaryMatch(result, showPath: false) {
                lines = [binaryLine]
            } else if options.onlyMatching {
                lines = result.matches.flatMap { formatOnlyMatching($0, showPath: false) }
            } else if options.passthru || options.beforeContext > 0 || options.afterContext > 0 {
                lines = contextLines(for: result, showPath: false)
            } else if options.multiline, options.replacement == nil {
                lines = multilineMatchLines(for: result, showPath: false)
            } else {
                lines = result.matches.flatMap { formatSearchMatch($0, showPath: false) }
            }
            guard !lines.isEmpty else {
                continue
            }
            if !output.isEmpty {
                output.append("")
            }
            if showPath {
                output.append(renderPath(for: result.fileURL))
            }
            output.append(contentsOf: lines)
        }
        return output
    }

    private func contextLines(for result: SearchFileResult, showPath: Bool) -> [String] {
        let matchedLineNumbers = multilineMatchedLineNumbers(for: result)
        let startMatchesByLine = firstMatchesByLine(for: result)
        let selectedLineNumbers: [Int]
        if options.passthru {
            selectedLineNumbers = result.lines.map(\.lineNumber)
        } else {
            let lineCount = result.lines.count
            let selected = result.matches.reduce(into: Set<Int>()) { lineNumbers, match in
                let matchLineNumbers = multilineLineNumbers(for: match)
                let lower = max(1, (matchLineNumbers.first ?? match.lineNumber) - options.beforeContext)
                let upper = min(lineCount, (matchLineNumbers.last ?? match.lineNumber) + options.afterContext)
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
            if let match = startMatchesByLine[lineNumber], shouldUseWholeMatchFormatter(match) {
                output.append(format(match, showPath: showPath))
            } else if matchedLineNumbers.contains(lineNumber) {
                output.append(formatMatchedLine(
                    line,
                    fileURL: result.fileURL,
                    showPath: showPath,
                    match: startMatchesByLine[lineNumber]
                ))
            } else {
                output.append(formatContextLine(line, fileURL: result.fileURL, showPath: showPath))
            }
            previous = lineNumber
        }
        return output
    }

    private func shouldUseWholeMatchFormatter(_ match: SearchMatch) -> Bool {
        !options.multiline || (options.replacement != nil && multilineLineNumbers(for: match).count == 1)
    }

    private func multilineMatchLines(for result: SearchFileResult, showPath: Bool) -> [String] {
        let matchedLineNumbers = multilineMatchedLineNumbers(for: result)
        let startMatchesByLine = firstMatchesByLine(for: result)
        return result.lines.compactMap { line in
            guard matchedLineNumbers.contains(line.lineNumber) else {
                return nil
            }
            return formatMatchedLine(
                line,
                fileURL: result.fileURL,
                showPath: showPath,
                match: startMatchesByLine[line.lineNumber]
            )
        }
    }

    private func multilineMatchedLineNumbers(for result: SearchFileResult) -> Set<Int> {
        guard options.multiline else {
            return Set(result.matches.map(\.lineNumber))
        }
        return result.matches.reduce(into: Set<Int>()) { lineNumbers, match in
            for lineNumber in multilineLineNumbers(for: match) {
                lineNumbers.insert(lineNumber)
            }
        }
    }

    private func firstMatchesByLine(for result: SearchFileResult) -> [Int: SearchMatch] {
        result.matches.reduce(into: [:]) { matchesByLine, match in
            matchesByLine[match.lineNumber] = matchesByLine[match.lineNumber] ?? match
        }
    }

    private func multilineLineNumbers(for match: SearchMatch) -> [Int] {
        guard options.multiline else {
            return [match.lineNumber]
        }
        let lineCount = splitRenderedLines(match.lineWithTerminator).count
        return Array(match.lineNumber..<(match.lineNumber + max(1, lineCount)))
    }

    private func formatContextLine(_ line: SearchLine, fileURL: URL, showPath: Bool) -> String {
        var fields: [OutputField] = []
        let path = showPath ? renderPath(for: fileURL, line: line.lineNumber) : nil
        if options.wantsLineNumber {
            fields.append(OutputField("\(line.lineNumber)", colorTarget: .line))
        }

        return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldContextSeparator))\(renderedLine(line.line, omittedKind: .context))\(outputTerminator(line.lineTerminator, line: line.line))"
    }

    private func formatMatchedLine(_ line: SearchLine, fileURL: URL, showPath: Bool, match: SearchMatch?) -> String {
        var fields: [OutputField] = []
        let path = showPath ? renderPath(for: fileURL, line: line.lineNumber, column: match?.column) : nil
        if options.wantsLineNumber {
            fields.append(OutputField("\(line.lineNumber)", colorTarget: .line))
        }
        if options.column, let column = match?.column {
            fields.append(OutputField("\(column)", colorTarget: .column))
        }
        if options.byteOffset, let match {
            fields.append(OutputField("\(match.absoluteOffset)", colorTarget: nil))
        }

        return "\(prefix(path: path, fields: fields, fieldSeparator: options.fieldMatchSeparator))\(renderedLine(line.line))\(outputTerminator(line.lineTerminator, line: line.line))"
    }

    private func renderedLine(for match: SearchMatch) -> String {
        guard options.replacement != nil, !match.spans.isEmpty else {
            if let rendered = limitedMatchedLine(match.line, match: match) {
                return "\(rendered)\(outputTerminator(match.lineTerminator, line: match.line))"
            }
            return "\(renderedLine(match.line, spans: match.spans))\(outputTerminator(match.lineTerminator, line: match.line))"
        }
        let originalLine = match.line
        let line = renderedText(for: match)
        if let rendered = limitedReplacementLine(line, originalLine: originalLine, match: match) {
            return "\(rendered)\(outputTerminator(match.lineTerminator, line: match.line))"
        }
        return "\(renderedLine(line))\(outputTerminator(match.lineTerminator, line: line))"
    }

    private func limitedMatchedLine(_ line: String, match: SearchMatch) -> String? {
        guard colors.isEnabled,
              let maxColumns = options.maxColumns,
              line.utf8.count >= maxColumns,
              options.maxColumnsPreview else {
            return nil
        }
        let rendered = options.trim ? line.trimmingASCIIWhitespacePrefix() : line
        let trimOffset = line.utf8.count - rendered.utf8.count
        let remainingMatches = match.spans.filter { $0.startByte >= trimOffset + maxColumns }.count
        return previewLineSuffix(rendered, maxColumns: maxColumns, remainingMatches: remainingMatches)
    }

    private func renderedText(for match: SearchMatch) -> String {
        var line = match.line
        for span in match.spans.sorted(by: { $0.startByte > $1.startByte }) {
            guard let replacement = span.replacement,
                  let range = indexRange(startByte: span.startByte, endByte: span.endByte, in: line) else {
                continue
            }
            line.replaceSubrange(range, with: replacement)
        }
        return line
    }

    private func renderedLine(_ line: String, omittedKind: OmittedLineKind = .matching) -> String {
        let trimmed = options.trim ? line.trimmingASCIIWhitespacePrefix() : line
        return limitedLine(trimmed, omittedKind: omittedKind)
    }

    private func renderedLine(_ line: String, spans: [MatchSpan]) -> String {
        guard colors.isEnabled, !options.trim, options.maxColumns == nil, !spans.isEmpty else {
            return renderedLine(line)
        }
        return colors.colorMatches(in: line, spans: spans)
    }

    private func outputTerminator(_ terminator: String, line: String? = nil) -> String {
        if options.nullData {
            return terminator
        }
        if options.crlf, colors.isEnabled, terminator == "\n", line?.hasSuffix("\r") != true {
            return "\r"
        }
        return ""
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

    private func prefix(path: String?, fields: [OutputField], fieldSeparator: String) -> String {
        var prefix = ""
        if let path {
            prefix += path
            prefix += options.nullPathTerminator ? "\0" : fieldSeparator
        }
        if !fields.isEmpty {
            prefix += fields.map { field in
                guard let colorTarget = field.colorTarget else {
                    return field.text
                }
                return colors.apply(colorTarget, to: field.text)
            }.joined(separator: fieldSeparator)
            prefix += fieldSeparator
        }
        return prefix
    }

    private func renderPath(for url: URL, line: Int? = nil, column: Int? = nil) -> String {
        let text = colors.apply(.path, to: displayPath(for: url))
        return hyperlinks.label(text, for: url, line: line, column: column)
    }

    private func limitedLine(_ line: String, omittedKind: OmittedLineKind) -> String {
        guard let maxColumns = options.maxColumns, line.utf8.count >= maxColumns else {
            return line
        }
        guard options.maxColumnsPreview else {
            return omittedKind.message
        }
        return "\(line.prefixBytes(maxColumns)) [... omitted end of long line]"
    }

    private func limitedReplacementLine(_ line: String, originalLine: String, match: SearchMatch) -> String? {
        guard let maxColumns = options.maxColumns, originalLine.utf8.count >= maxColumns else {
            return nil
        }
        guard options.maxColumnsPreview else {
            return "[Omitted long line with \(match.matchCount) \(match.matchCount == 1 ? "match" : "matches")]"
        }
        guard line.utf8.count >= maxColumns else {
            return nil
        }
        let remainingMatches = replacementStartOffsets(for: match).filter { $0 >= maxColumns }.count
        return previewLineSuffix(line, maxColumns: maxColumns, remainingMatches: remainingMatches)
    }

    private func onlyMatchingText(_ span: MatchSpan, in match: SearchMatch) -> String {
        let rawText = span.replacement ?? span.text
        let text = options.trim ? rawText.trimmingASCIIWhitespacePrefix() : rawText
        guard let maxColumns = options.maxColumns,
              text.utf8.count > maxColumns else {
            return colors.apply(.match, to: text)
        }
        guard options.maxColumnsPreview else {
            return OmittedLineKind.matching.message
        }
        return previewLineSuffix(text, maxColumns: maxColumns, remainingMatches: 0)
    }

    private func previewLineSuffix(_ line: String, maxColumns: Int, remainingMatches: Int?) -> String {
        guard let remainingMatches else {
            return "\(line.prefixBytes(maxColumns)) [... omitted end of long line]"
        }
        return "\(line.prefixBytes(maxColumns)) [... \(remainingMatches) more \(remainingMatches == 1 ? "match" : "matches")]"
    }

    private func replacementStartOffsets(for match: SearchMatch) -> [Int] {
        var delta = 0
        var offsets: [Int] = []
        for span in match.spans.sorted(by: { $0.startByte < $1.startByte }) {
            let replacementLength = (span.replacement ?? span.text).utf8.count
            offsets.append(span.startByte + delta)
            delta += replacementLength - (span.endByte - span.startByte)
        }
        return offsets
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

    private func firstRenderedLine(_ text: String) -> String {
        splitRenderedLines(text).first ?? ""
    }

    private func lineOffset(in text: String, beforeByteOffset byteOffset: Int) -> Int {
        var bytes = 0
        var lines = 0
        let terminator: Character = text.contains("\0") ? "\0" : "\n"
        for character in text {
            guard bytes < byteOffset else {
                break
            }
            bytes += String(character).utf8.count
            if character == terminator {
                lines += 1
            }
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

    private func indexRange(startByte: Int, endByte: Int, in line: String) -> Range<String.Index>? {
        guard startByte >= 0, endByte >= startByte,
              let lower = stringIndex(in: line, atByteOffset: startByte),
              let upper = stringIndex(in: line, atByteOffset: endByte) else {
            return nil
        }
        return lower..<upper
    }

    private func stringIndex(in line: String, atByteOffset byteOffset: Int) -> String.Index? {
        guard byteOffset >= 0 else {
            return nil
        }
        if byteOffset == 0 {
            return line.startIndex
        }
        var bytes = 0
        for index in line.indices {
            if bytes == byteOffset {
                return index
            }
            bytes += String(line[index]).utf8.count
        }
        return bytes == byteOffset ? line.endIndex : nil
    }

    private func showPath(for results: SearchResults) -> Bool {
        if let withFilename = options.withFilename {
            return withFilename
        }
        if options.useStdin {
            return !options.roots.isEmpty
        }
        return results.files.count > 1 || options.effectiveRoots.count > 1 || options.effectiveRoots.contains { isDirectory($0) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func displayPath(for url: URL) -> String {
        pathFormatter.displayPath(for: url)
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

    func trimmingTrailingSlashes() -> String {
        var output = self
        while output.count > 1, output.last == "/" {
            output.removeLast()
        }
        return output
    }
}

private struct OutputField {
    let text: String
    let colorTarget: ColorTarget?

    init(_ text: String, colorTarget: ColorTarget?) {
        self.text = text
        self.colorTarget = colorTarget
    }
}

private enum OmittedLineKind {
    case matching
    case context

    var message: String {
        switch self {
        case .matching:
            return "[Omitted long matching line]"
        case .context:
            return "[Omitted long context line]"
        }
    }
}

private struct ANSIColorPalette {
    struct Style {
        var foreground: String?
        var background: String?
        var bold = false
        var underline = false
        var italic = false

        var isEmpty: Bool {
            foreground == nil && background == nil && !bold && !underline && !italic
        }

        var escape: String? {
            var escapes: [String] = []
            if bold {
                escapes.append("\u{1B}[1m")
            }
            if underline {
                escapes.append("\u{1B}[4m")
            }
            if italic {
                escapes.append("\u{1B}[3m")
            }
            if let foreground, let code = ANSIColorPalette.colorCode(foreground, foreground: true) {
                escapes.append("\u{1B}[\(code)m")
            }
            if let background, let code = ANSIColorPalette.colorCode(background, foreground: false) {
                escapes.append("\u{1B}[\(code)m")
            }
            guard !escapes.isEmpty else {
                return nil
            }
            return escapes.joined()
        }
    }

    static let reset = "\u{1B}[0m"
    private static let foregroundCodes = [
        "black": "30",
        "red": "31",
        "green": "32",
        "yellow": "33",
        "blue": "34",
        "magenta": "35",
        "cyan": "36",
        "white": "37",
    ]
    private static let backgroundCodes = [
        "black": "40",
        "red": "41",
        "green": "42",
        "yellow": "43",
        "blue": "44",
        "magenta": "45",
        "cyan": "46",
        "white": "47",
    ]

    let isEnabled: Bool
    private var styles: [ColorTarget: Style]

    init(options: RipgrepOptions) {
        self.isEnabled = options.colorMode == .always || options.colorMode == .ansi
        var styles: [ColorTarget: Style] = [
            .path: Style(foreground: "magenta"),
            .line: Style(foreground: "green"),
            .column: Style(),
            .match: Style(foreground: "red", bold: true),
            .highlight: Style(),
        ]
        for change in options.colorChanges {
            var style = styles[change.target] ?? Style()
            switch change.attribute {
            case .none:
                style = Style()
            case .foreground(let color):
                style.foreground = color
            case .background(let color):
                style.background = color
            case .style(let name):
                Self.applyStyle(name, to: &style)
            }
            styles[change.target] = style
        }
        self.styles = styles
    }

    func apply(_ target: ColorTarget, to text: String) -> String {
        guard isEnabled, !text.isEmpty, let style = styles[target] else {
            return text
        }
        guard let escape = style.escape else {
            return shouldResetPlainText(target) ? "\(Self.reset)\(text)\(Self.reset)" : text
        }
        return "\(Self.reset)\(escape)\(text)\(Self.reset)"
    }

    func colorMatches(in line: String, spans: [MatchSpan]) -> String {
        guard isEnabled else {
            return line
        }
        let orderedSpans = spans.sorted {
            if $0.startByte == $1.startByte {
                return $0.endByte < $1.endByte
            }
            return $0.startByte < $1.startByte
        }
        var output = ""
        var cursor = line.startIndex
        for span in orderedSpans {
            guard let range = indexRange(startByte: span.startByte, endByte: span.endByte, in: line),
                  range.lowerBound >= cursor else {
                continue
            }
            output.append(contentsOf: line[cursor..<range.lowerBound])
            output.append(apply(.match, to: String(line[range])))
            cursor = range.upperBound
        }
        output.append(contentsOf: line[cursor..<line.endIndex])
        return output
    }

    private func shouldResetPlainText(_ target: ColorTarget) -> Bool {
        switch target {
        case .path, .line, .column:
            return true
        case .match, .highlight:
            return false
        }
    }

    private func indexRange(startByte: Int, endByte: Int, in line: String) -> Range<String.Index>? {
        guard startByte >= 0, endByte >= startByte,
              let lower = stringIndex(in: line, atByteOffset: startByte),
              let upper = stringIndex(in: line, atByteOffset: endByte) else {
            return nil
        }
        return lower..<upper
    }

    private func stringIndex(in line: String, atByteOffset byteOffset: Int) -> String.Index? {
        guard byteOffset >= 0 else {
            return nil
        }
        if byteOffset == 0 {
            return line.startIndex
        }
        var bytes = 0
        for index in line.indices {
            if bytes == byteOffset {
                return index
            }
            bytes += String(line[index]).utf8.count
        }
        return bytes == byteOffset ? line.endIndex : nil
    }

    private static func applyStyle(_ name: String, to style: inout Style) {
        switch name {
        case "bold", "intense":
            style.bold = true
        case "nobold", "nointense":
            style.bold = false
        case "underline":
            style.underline = true
        case "nounderline":
            style.underline = false
        case "italic":
            style.italic = true
        case "noitalic":
            style.italic = false
        default:
            break
        }
    }

    private static func colorCode(_ color: String, foreground: Bool) -> String? {
        if foreground, let code = foregroundCodes[color] {
            return code
        }
        if !foreground, let code = backgroundCodes[color] {
            return code
        }
        if let byte = parseColorByte(color) {
            return "\(foreground ? 38 : 48);5;\(byte)"
        }
        let components = color.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3,
              let red = parseColorByte(components[0]),
              let green = parseColorByte(components[1]),
              let blue = parseColorByte(components[2]) else {
            return nil
        }
        return "\(foreground ? 38 : 48);2;\(red);\(green);\(blue)"
    }

    private static func parseColorByte(_ raw: String) -> UInt8? {
        let value: UInt64?
        if raw.hasPrefix("0x") {
            value = UInt64(raw.dropFirst(2), radix: 16)
        } else {
            value = UInt64(raw)
        }
        guard let value, value <= UInt8.max else {
            return nil
        }
        return UInt8(value)
    }
}
