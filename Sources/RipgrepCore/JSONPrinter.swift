import Foundation

public struct JSONPrinter {
    private let options: RipgrepOptions

    public init(options: RipgrepOptions) {
        self.options = options
    }

    public func lines(for results: SearchResults) -> [String] {
        var output: [String] = []
        if !options.quiet {
            for result in results.files where result.hasMatch {
                output.append(jsonLine([
                    "type": "begin",
                    "data": [
                        "path": dataObject(result.fileURL.path),
                    ],
                ]))

                for message in messages(for: result) {
                    output.append(jsonLine(message))
                }

                output.append(jsonLine([
                    "type": "end",
                    "data": [
                        "path": dataObject(result.fileURL.path),
                        "binary_offset": result.binaryByteOffset.map { $0 as Any } ?? NSNull(),
                        "stats": statsObject(for: result),
                    ],
                ]))
            }
        }

        output.append(jsonLine([
            "type": "summary",
            "data": [
                "stats": summaryStatsObject(for: results),
                "elapsed_total": elapsedObject(),
            ],
        ]))
        return output
    }

    private func messages(for result: SearchFileResult) -> [[String: Any]] {
        if options.passthru || options.beforeContext > 0 || options.afterContext > 0 {
            return contextAwareMessages(for: result)
        }
        return result.matches.map { matchMessage($0, path: result.fileURL.path) }
    }

    private func contextAwareMessages(for result: SearchFileResult) -> [[String: Any]] {
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
                return matchMessage(match, path: result.fileURL.path)
            }
            guard let line = result.lines.first(where: { $0.lineNumber == lineNumber }) else {
                return nil
            }
            return contextMessage(line, path: result.fileURL.path)
        }
    }

    private func matchMessage(_ match: SearchMatch, path: String) -> [String: Any] {
        [
            "type": "match",
            "data": lineData(
                path: path,
                text: match.lineWithTerminator,
                lineNumber: match.lineNumber,
                absoluteOffset: match.absoluteOffset,
                submatches: match.spans
            ),
        ]
    }

    private func contextMessage(_ line: SearchLine, path: String) -> [String: Any] {
        [
            "type": "context",
            "data": lineData(
                path: path,
                text: line.lineWithTerminator,
                lineNumber: line.lineNumber,
                absoluteOffset: line.absoluteOffset,
                submatches: []
            ),
        ]
    }

    private func lineData(
        path: String,
        text: String,
        lineNumber: Int,
        absoluteOffset: Int,
        submatches: [MatchSpan]
    ) -> [String: Any] {
        [
            "path": dataObject(path),
            "lines": dataObject(text),
            "line_number": lineNumber,
            "absolute_offset": absoluteOffset,
            "submatches": submatches.map(submatchObject),
        ]
    }

    private func submatchObject(_ span: MatchSpan) -> [String: Any] {
        var object: [String: Any] = [
            "match": dataObject(span.text),
            "start": span.startByte,
            "end": span.endByte,
        ]
        if let replacement = span.replacement {
            object["replacement"] = dataObject(replacement)
        }
        return object
    }

    private func statsObject(for result: SearchFileResult) -> [String: Any] {
        [
            "elapsed": elapsedObject(),
            "searches": result.searched ? 1 : 0,
            "searches_with_match": result.hasMatch ? 1 : 0,
            "bytes_searched": result.bytesSearched,
            "bytes_printed": 0,
            "matched_lines": result.matches.reduce(0) { $0 + matchedLineCount($1) },
            "matches": result.matches.reduce(0) { $0 + $1.matchCount } + (result.hasBinaryMatch ? 1 : 0),
        ]
    }

    private func summaryStatsObject(for results: SearchResults) -> [String: Any] {
        [
            "elapsed": elapsedObject(),
            "searches": results.summary.filesSearched,
            "searches_with_match": results.summary.filesWithMatches,
            "bytes_searched": results.files.reduce(0) { $0 + $1.bytesSearched },
            "bytes_printed": 0,
            "matched_lines": results.summary.matchedLines,
            "matches": results.summary.totalMatches,
        ]
    }

    private func elapsedObject() -> [String: Any] {
        [
            "secs": 0,
            "nanos": 0,
            "human": "0.000000s",
        ]
    }

    private func dataObject(_ text: String) -> [String: String] {
        ["text": text]
    }

    private func matchedLineCount(_ match: SearchMatch) -> Int {
        let terminator: Character = match.lineWithTerminator.contains("\0") ? "\0" : "\n"
        return max(1, match.lineWithTerminator.filter { $0 == terminator }.count)
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
