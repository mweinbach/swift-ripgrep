import Foundation

public struct JSONPrinter {
    private let options: RipgrepOptions
    private let pathFormatter: OutputPathFormatter

    public init(
        options: RipgrepOptions,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.options = options
        self.pathFormatter = OutputPathFormatter(options: options, currentDirectory: currentDirectory)
    }

    public func lines(for results: SearchResults) -> [String] {
        var output: [String] = []
        var totalBytesPrinted = 0
        if !options.quiet {
            for result in results.files where shouldPrintFile(result) {
                let path = displayPath(for: result.fileURL)
                var fileOutput: [String] = []
                fileOutput.append(jsonLine(.object([
                    ("type", .string("begin")),
                    ("data", .object([
                        ("path", dataObject(path)),
                    ])),
                ])))

                for message in messages(for: result, path: path) {
                    fileOutput.append(jsonLine(message))
                }

                let fileBytesPrinted = bytesPrinted(fileOutput)
                totalBytesPrinted += fileBytesPrinted
                output += fileOutput
                output.append(jsonLine(.object([
                    ("type", .string("end")),
                    ("data", .object([
                        ("path", dataObject(path)),
                        ("binary_offset", result.binaryByteOffset.map(JSONValue.int) ?? .null),
                        ("stats", fileStatsObject(for: result, bytesPrinted: fileBytesPrinted)),
                    ])),
                ])))
            }
        }

        output.append(jsonLine(.object([
            ("data", .object([
                ("elapsed_total", elapsedObject()),
                ("stats", summaryStatsObject(for: results, bytesPrinted: totalBytesPrinted)),
            ])),
            ("type", .string("summary")),
        ])))
        return output
    }

    private func shouldPrintFile(_ result: SearchFileResult) -> Bool {
        result.hasMatch || (options.passthru && !result.lines.isEmpty)
    }

    private func messages(for result: SearchFileResult, path: String) -> [JSONValue] {
        if shouldSuppressContextForMultilineLineAnchors {
            return result.matches.map { matchMessage($0, path: path) }
        }
        if options.passthru || options.beforeContext > 0 || options.afterContext > 0 {
            return contextAwareMessages(for: result, path: path)
        }
        return result.matches.map { matchMessage($0, path: path) }
    }

    private var shouldSuppressContextForMultilineLineAnchors: Bool {
        options.multiline
            && options.maxCount == nil
            && options.effectivePatterns.allSatisfy(isBareMultilineLineAnchorPattern)
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

    private func contextAwareMessages(for result: SearchFileResult, path: String) -> [JSONValue] {
        let matchesByLine = Dictionary(uniqueKeysWithValues: result.matches.map { ($0.lineNumber, $0) })
        let matchedLineNumbers = Set(result.matches.flatMap(multilineLineNumbers))
        let selectedLineNumbers: [Int]
        if options.passthru {
            selectedLineNumbers = result.lines.map(\.lineNumber)
        } else {
            let lineCount = jsonContextLineCount(for: result)
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

        return selectedLineNumbers.compactMap { lineNumber in
            if let match = matchesByLine[lineNumber] {
                return matchMessage(match, path: path)
            }
            if matchedLineNumbers.contains(lineNumber) {
                return nil
            }
            guard let line = result.lines.first(where: { $0.lineNumber == lineNumber })
                    ?? synthesizedTrailingContextLine(lineNumber: lineNumber, in: result) else {
                return nil
            }
            if !options.passthru, !options.invertMatch, !line.positiveSpans.isEmpty {
                return matchMessage(SearchMatch(
                    fileURL: result.fileURL,
                    lineNumber: line.lineNumber,
                    column: options.column ? line.positiveSpans.first?.startColumn : nil,
                    line: line.line,
                    rawLine: line.rawLine,
                    lineTerminator: line.lineTerminator,
                    absoluteOffset: line.absoluteOffset,
                    matchCount: line.positiveSpans.count,
                    spans: line.positiveSpans
                ), path: path)
            }
            return contextMessage(line, path: path)
        }
    }

    private func jsonContextLineCount(for result: SearchFileResult) -> Int {
        let maxLineNumber = result.lines.map(\.lineNumber).max() ?? 0
        guard options.multiline,
              options.json,
              options.afterContext > 0,
              let last = result.lines.last,
              last.lineTerminator == "\n",
              lineEndOffset(last) < result.bytesSearched else {
            return maxLineNumber
        }
        return maxLineNumber + 1
    }

    private func synthesizedTrailingContextLine(lineNumber: Int, in result: SearchFileResult) -> SearchLine? {
        guard options.multiline,
              options.json,
              options.afterContext > 0,
              let previous = result.lines.last,
              lineNumber == previous.lineNumber + 1,
              previous.lineTerminator == "\n",
              lineEndOffset(previous) < result.bytesSearched else {
            return nil
        }
        return SearchLine(
            lineNumber: lineNumber,
            line: "",
            lineTerminator: "\n",
            absoluteOffset: lineEndOffset(previous)
        )
    }

    private func lineEndOffset(_ line: SearchLine) -> Int {
        line.absoluteOffset + line.line.utf8.count + line.lineTerminator.utf8.count
    }

    private func multilineLineNumbers(for match: SearchMatch) -> [Int] {
        guard options.multiline else {
            return [match.lineNumber]
        }
        let lineCount = splitRenderedLines(match.lineWithTerminator).count
        return Array(match.lineNumber..<(match.lineNumber + max(1, lineCount)))
    }

    private func splitRenderedLines(_ text: String) -> [String] {
        let terminator: UnicodeScalar = text.contains("\0") ? "\0" : "\n"
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == terminator {
                lines.append(String(current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty || text.unicodeScalars.last != terminator {
            lines.append(String(current))
        }
        return lines
    }

    private func matchMessage(_ match: SearchMatch, path: String) -> JSONValue {
        let rawText = match.rawLine.map { $0 + match.lineTerminator }
        return .object([
            ("type", .string("match")),
            ("data", lineData(
                path: path,
                text: match.lineWithTerminator,
                rawText: rawText,
                lineNumber: match.lineNumber,
                absoluteOffset: match.absoluteOffset,
                submatches: options.invertMatch ? [] : match.spans,
                rawSubmatchText: rawText
            )),
        ])
    }

    private func contextMessage(_ line: SearchLine, path: String) -> JSONValue {
        .object([
            ("type", .string("context")),
            ("data", lineData(
                path: path,
                text: line.lineWithTerminator,
                rawText: line.rawLine.map { $0 + line.lineTerminator },
                lineNumber: line.lineNumber,
                absoluteOffset: line.absoluteOffset,
                submatches: []
            )),
        ])
    }

    private func lineData(
        path: String,
        text: String,
        rawText: String? = nil,
        lineNumber: Int,
        absoluteOffset: Int,
        submatches: [MatchSpan],
        rawSubmatchText: String? = nil
    ) -> JSONValue {
        .object([
            ("path", dataObject(path)),
            ("lines", dataObject(rawText ?? text, rawWhenEncodingDisabled: rawText != nil || options.encodingMode == .disabled)),
            ("line_number", options.noLineNumber ? .null : .int(lineNumber)),
            ("absolute_offset", .int(absoluteOffset)),
            ("submatches", .array(submatches.map { submatchObject($0, rawText: rawSubmatchText) })),
        ])
    }

    private func submatchObject(_ span: MatchSpan, rawText: String?) -> JSONValue {
        let rawByteLength = span.endByte - span.startByte
        let matchData = rawText.flatMap {
            rawByteSlice(in: $0, start: span.startByte, end: span.endByte)
        }
        var fields: [(String, JSONValue)] = [
            ("match", matchData.map(dataObject) ?? dataObject(
                span.text,
                rawWhenEncodingDisabled: options.encodingMode == .disabled || rawByteLength != span.text.utf8.count
            )),
        ]
        if let replacement = span.replacement {
            fields.append(("replacement", dataObject(replacement)))
        }
        fields.append(("start", .int(span.startByte)))
        fields.append(("end", .int(span.endByte)))
        return .object(fields)
    }

    private func fileStatsObject(for result: SearchFileResult, bytesPrinted: Int) -> JSONValue {
        let matchCount = options.invertMatch ? 0 : result.matches.reduce(0) { $0 + $1.matchCount } + result.supplementalMatches
        let promotedBinaryMatch = matchCount == 0
            && result.hasBinaryMatch
            && !shouldPreserveZeroMultilineBinaryMatchCount
        return .object([
            ("elapsed", fileElapsedObject()),
            ("searches", .int(result.searched ? 1 : 0)),
            ("searches_with_match", .int(result.hasMatch ? 1 : 0)),
            ("bytes_searched", .int(result.bytesSearched)),
            ("bytes_printed", .int(bytesPrinted)),
            ("matched_lines", .int(result.matches.reduce(0) { $0 + MatchedLineCounter.count($1, options: options) } + result.supplementalMatchedLines)),
            ("matches", .int(promotedBinaryMatch ? 1 : matchCount)),
        ])
    }

    private var shouldPreserveZeroMultilineBinaryMatchCount: Bool {
        options.multiline && options.effectivePatterns.allSatisfy(isBareMultilineLineEndPattern)
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

    private func summaryStatsObject(for results: SearchResults, bytesPrinted: Int) -> JSONValue {
        .object([
            ("bytes_printed", .int(bytesPrinted)),
            ("bytes_searched", .int(results.files.reduce(0) { $0 + $1.bytesSearched })),
            ("elapsed", elapsedObject()),
            ("matched_lines", .int(results.summary.matchedLines)),
            ("matches", .int(results.summary.totalMatches)),
            ("searches", .int(results.summary.filesSearched)),
            ("searches_with_match", .int(results.summary.filesWithMatches)),
        ])
    }

    private func elapsedObject() -> JSONValue {
        .object([
            ("human", .string("0.000000s")),
            ("nanos", .int(0)),
            ("secs", .int(0)),
        ])
    }

    private func fileElapsedObject() -> JSONValue {
        .object([
            ("secs", .int(0)),
            ("nanos", .int(0)),
            ("human", .string("0.000000s")),
        ])
    }

    private func dataObject(_ text: String, rawWhenEncodingDisabled: Bool = false) -> JSONValue {
        if rawWhenEncodingDisabled {
            return dataObject(text.rawByteData())
        }
        return .object([("text", .string(text))])
    }

    private func dataObject(_ data: Data) -> JSONValue {
        if isValidUTF8(data) {
            return .object([("text", .string(String(decoding: data, as: UTF8.self)))])
        }
        return .object([("bytes", .string(data.base64EncodedString()))])
    }

    private func rawByteSlice(in text: String, start: Int, end: Int) -> Data? {
        let data = text.rawByteData()
        guard start >= 0, end >= start, end <= data.count else {
            return nil
        }
        return data.subdata(in: start..<end)
    }

    private func isValidUTF8(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8) != nil
    }

    private func displayPath(for url: URL) -> String {
        pathFormatter.displayPath(for: url, applyingPathSeparator: false)
    }

    private func jsonLine(_ object: JSONValue) -> String {
        object.rendered()
    }

    private func bytesPrinted(_ lines: [String]) -> Int {
        lines.reduce(0) { total, line in
            total + line.utf8.count + 1
        }
    }
}

private enum JSONValue {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case null

    func rendered() -> String {
        switch self {
        case .object(let fields):
            let body = fields
                .map { field in "\(Self.escaped(field.0)):\(field.1.rendered())" }
                .joined(separator: ",")
            return "{\(body)}"
        case .array(let values):
            return "[\(values.map { $0.rendered() }.joined(separator: ","))]"
        case .string(let text):
            return Self.escaped(text)
        case .int(let value):
            return String(value)
        case .null:
            return "null"
        }
    }

    private static func escaped(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x08:
                output += "\\b"
            case 0x09:
                output += "\\t"
            case 0x0A:
                output += "\\n"
            case 0x0C:
                output += "\\f"
            case 0x0D:
                output += "\\r"
            case 0x22:
                output += "\\\""
            case 0x5C:
                output += "\\\\"
            case 0x00...0x1F:
                output += String(format: "\\u%04X", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
        return output
    }
}

private extension String {
    func rawByteData() -> Data {
        var data = Data()
        for scalar in unicodeScalars {
            if scalar.value <= UInt8.max {
                data.append(UInt8(scalar.value))
            } else {
                data.append(contentsOf: String(scalar).utf8)
            }
        }
        return data
    }
}
