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
        if options.passthru || options.beforeContext > 0 || options.afterContext > 0 {
            return contextAwareMessages(for: result, path: path)
        }
        return result.matches.map { matchMessage($0, path: path) }
    }

    private func contextAwareMessages(for result: SearchFileResult, path: String) -> [JSONValue] {
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

        return selectedLineNumbers.compactMap { lineNumber in
            if let match = matchesByLine[lineNumber] {
                return matchMessage(match, path: path)
            }
            guard let line = result.lines.first(where: { $0.lineNumber == lineNumber }) else {
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

    private func matchMessage(_ match: SearchMatch, path: String) -> JSONValue {
        .object([
            ("type", .string("match")),
            ("data", lineData(
                path: path,
                text: match.lineWithTerminator,
                rawText: match.rawLine.map { $0 + match.lineTerminator },
                lineNumber: match.lineNumber,
                absoluteOffset: match.absoluteOffset,
                submatches: options.invertMatch ? [] : match.spans
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
        submatches: [MatchSpan]
    ) -> JSONValue {
        .object([
            ("path", dataObject(path)),
            ("lines", dataObject(rawText ?? text, rawWhenEncodingDisabled: rawText != nil || options.encodingMode == .disabled)),
            ("line_number", options.noLineNumber ? .null : .int(lineNumber)),
            ("absolute_offset", .int(absoluteOffset)),
            ("submatches", .array(submatches.map(submatchObject))),
        ])
    }

    private func submatchObject(_ span: MatchSpan) -> JSONValue {
        let rawByteLength = span.endByte - span.startByte
        var fields: [(String, JSONValue)] = [
            ("match", dataObject(
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
        return .object([
            ("elapsed", fileElapsedObject()),
            ("searches", .int(result.searched ? 1 : 0)),
            ("searches_with_match", .int(result.hasMatch ? 1 : 0)),
            ("bytes_searched", .int(result.bytesSearched)),
            ("bytes_printed", .int(bytesPrinted)),
            ("matched_lines", .int(result.matches.reduce(0) { $0 + MatchedLineCounter.count($1, options: options) } + result.supplementalMatchedLines)),
            ("matches", .int(matchCount == 0 && result.hasBinaryMatch ? 1 : matchCount)),
        ])
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
            let data = text.rawByteData()
            if let decoded = String(data: data, encoding: .utf8) {
                return .object([("text", .string(decoded))])
            }
            return .object([("bytes", .string(data.base64EncodedString()))])
        }
        return .object([("text", .string(text))])
    }

    private func displayPath(for url: URL) -> String {
        pathFormatter.displayPath(for: url)
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
