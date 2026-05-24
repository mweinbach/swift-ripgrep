import Foundation
import Testing
@testable import RipgrepCore

@Suite("Ripgrep JSON parity area", .serialized)
struct JSONTests {
    @Test("prints JSON lines for matches context and summary")
    func printsJSONLines() throws {
        let root = try TemporaryDirectory()
        try root.write("hay\nneedle here\nthere\n", to: "json.txt")
        try root.write(Data("needle\n\0tail\n".utf8), to: "binary.txt")

        let output = try run(["--json", "-n", "-C1", "needle", root.path("json.txt")])
        let messages = try output.map(jsonObject)

        #expect(output[0] == #"{"type":"begin","data":{"path":{"text":"\#(root.path("json.txt"))"}}}"#)
        #expect(!output[0].contains("\\/"))
        #expect(output[5].hasPrefix(#"{"data":{"elapsed_total":{"human":"0.000000s","nanos":0,"secs":0},"stats":{"bytes_printed":"#))
        #expect(messages.map { $0["type"] as? String } == ["begin", "context", "match", "context", "end", "summary"])

        let match = messages[2]["data"] as? [String: Any]
        let lines = match?["lines"] as? [String: String]
        let submatches = match?["submatches"] as? [[String: Any]]
        let firstSubmatch = submatches?.first
        let submatchText = firstSubmatch?["match"] as? [String: String]

        #expect(lines?["text"] == "needle here\n")
        #expect(match?["line_number"] as? Int == 2)
        #expect(match?["absolute_offset"] as? Int == 4)
        #expect(submatchText?["text"] == "needle")
        #expect(firstSubmatch?["start"] as? Int == 0)
        #expect(firstSubmatch?["end"] as? Int == 6)

        let end = messages[4]["data"] as? [String: Any]
        let stats = end?["stats"] as? [String: Any]
        #expect(stats?["searches"] as? Int == 1)
        #expect(stats?["searches_with_match"] as? Int == 1)
        #expect(stats?["bytes_printed"] as? Int == output.prefix(4).reduce(0) { $0 + $1.utf8.count + 1 })
        #expect(stats?["matched_lines"] as? Int == 1)
        #expect(stats?["matches"] as? Int == 1)

        let summary = messages[5]["data"] as? [String: Any]
        let summaryStats = summary?["stats"] as? [String: Any]
        #expect(summaryStats?["bytes_printed"] as? Int == stats?["bytes_printed"] as? Int)

        try root.write("one\ntwo\nthree\n", to: "absolute-start-json.txt")
        let absoluteStartOutput = try run(["--json", #"\A"#, root.path("absolute-start-json.txt")])
        let absoluteStartMessages = try absoluteStartOutput.map(jsonObject)
        let absoluteStartMatches = absoluteStartMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        #expect(absoluteStartMatches.count == 3)
        #expect((absoluteStartMatches[0]["submatches"] as? [[String: Any]])?.count == 1)
        #expect((absoluteStartMatches[1]["submatches"] as? [[String: Any]])?.isEmpty == true)
        #expect((absoluteStartMatches[2]["submatches"] as? [[String: Any]])?.isEmpty == true)
        let absoluteStartEnd = absoluteStartMessages.first { $0["type"] as? String == "end" }
        let absoluteStartEndData = absoluteStartEnd?["data"] as? [String: Any]
        let absoluteStartStats = absoluteStartEndData?["stats"] as? [String: Any]
        #expect(absoluteStartStats?["matched_lines"] as? Int == 3)
        #expect(absoluteStartStats?["matches"] as? Int == 1)

        try root.write("foo\nfoo\nbarfoo\nquux\n", to: "absolute-start-alternation-json.txt")
        let absoluteStartAlternationOutput = try run(["--json", #"\A|bar"#, root.path("absolute-start-alternation-json.txt")])
        let absoluteStartAlternationMessages = try absoluteStartAlternationOutput.map(jsonObject)
        let absoluteStartAlternationMatches = absoluteStartAlternationMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        #expect(absoluteStartAlternationMatches.count == 4)
        #expect((absoluteStartAlternationMatches[0]["submatches"] as? [[String: Any]])?.count == 1)
        #expect((absoluteStartAlternationMatches[1]["submatches"] as? [[String: Any]])?.isEmpty == true)
        let absoluteStartAlternationLine3 = absoluteStartAlternationMatches[2]["submatches"] as? [[String: Any]]
        let absoluteStartAlternationLine3Text = absoluteStartAlternationLine3?.first?["match"] as? [String: String]
        #expect(absoluteStartAlternationLine3Text?["text"] == "bar")
        #expect((absoluteStartAlternationMatches[3]["submatches"] as? [[String: Any]])?.isEmpty == true)
        let absoluteStartAlternationEnd = absoluteStartAlternationMessages.first { $0["type"] as? String == "end" }
        let absoluteStartAlternationEndData = absoluteStartAlternationEnd?["data"] as? [String: Any]
        let absoluteStartAlternationStats = absoluteStartAlternationEndData?["stats"] as? [String: Any]
        #expect(absoluteStartAlternationStats?["matched_lines"] as? Int == 4)
        #expect(absoluteStartAlternationStats?["matches"] as? Int == 2)

        try root.write("alpha needle\nneedle beta\nzzz\n", to: "context-bytes-json.txt")
        let contextBytesOutput = try run(["--json", "-B1", "needle", root.path("context-bytes-json.txt")])
        let contextBytesMessages = try contextBytesOutput.map(jsonObject)
        let contextBytesEnd = contextBytesMessages[4]["data"] as? [String: Any]
        let contextBytesStats = contextBytesEnd?["stats"] as? [String: Any]
        #expect(contextBytesStats?["bytes_searched"] as? Int == "alpha needle\nneedle beta\nzzz\n".utf8.count)

        try root.write("pre\nneedle one\nctx\nneedle two\npost\n", to: "max-context-json.txt")
        let maxContextOutput = try run(["--json", "-m1", "-A2", "needle", root.path("max-context-json.txt")])
        let maxContextMessages = try maxContextOutput.map(jsonObject)
        #expect(maxContextMessages.map { $0["type"] as? String } == [
            "begin",
            "match",
            "context",
            "match",
            "end",
            "summary",
        ])
        let maxContextEnd = maxContextMessages[4]["data"] as? [String: Any]
        let maxContextStats = maxContextEnd?["stats"] as? [String: Any]
        #expect(maxContextStats?["bytes_searched"] as? Int == 30)
        #expect(maxContextStats?["matched_lines"] as? Int == 2)
        #expect(maxContextStats?["matches"] as? Int == 2)

        let passthruJSONOutput = try run(["--json", "-m1", "--passthru", "needle", root.path("max-context-json.txt")])
        let passthruJSONMessages = try passthruJSONOutput.map(jsonObject)
        #expect(passthruJSONMessages.map { $0["type"] as? String } == [
            "begin",
            "context",
            "match",
            "context",
            "context",
            "context",
            "end",
            "summary",
        ])
        let passthruJSONEnd = passthruJSONMessages[6]["data"] as? [String: Any]
        let passthruJSONStats = passthruJSONEnd?["stats"] as? [String: Any]
        #expect(passthruJSONStats?["bytes_searched"] as? Int == 35)
        #expect(passthruJSONStats?["matched_lines"] as? Int == 1)
        #expect(passthruJSONStats?["matches"] as? Int == 1)

        try root.write("nomatch\n", to: "passthru-no-match.txt")
        let passthruNoMatchOutput = try run([
            "--json",
            "--passthru",
            "needle",
            root.path("passthru-no-match.txt"),
            root.path("json.txt"),
        ])
        let passthruNoMatchMessages = try passthruNoMatchOutput.map(jsonObject)
        #expect(passthruNoMatchMessages.map { $0["type"] as? String } == [
            "begin",
            "context",
            "end",
            "begin",
            "context",
            "match",
            "context",
            "end",
            "summary",
        ])
        let passthruNoMatchContext = passthruNoMatchMessages[1]["data"] as? [String: Any]
        let passthruNoMatchLines = passthruNoMatchContext?["lines"] as? [String: String]
        #expect(passthruNoMatchLines?["text"] == "nomatch\n")
        let passthruNoMatchEnd = passthruNoMatchMessages[2]["data"] as? [String: Any]
        let passthruNoMatchStats = passthruNoMatchEnd?["stats"] as? [String: Any]
        #expect(passthruNoMatchStats?["searches"] as? Int == 1)
        #expect(passthruNoMatchStats?["searches_with_match"] as? Int == 0)
        #expect(passthruNoMatchStats?["matched_lines"] as? Int == 0)
        #expect(passthruNoMatchStats?["matches"] as? Int == 0)

        let invertedOutput = try run(["--json", "-v", "needle", root.path("json.txt")])
        let invertedMessages = try invertedOutput.map(jsonObject)
        let invertedMatch = invertedMessages.first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let invertedSubmatches = invertedMatch?["submatches"] as? [[String: Any]]
        let invertedEnd = invertedMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let invertedStats = invertedEnd?["stats"] as? [String: Any]
        let invertedSummary = invertedMessages.first { $0["type"] as? String == "summary" }?["data"] as? [String: Any]
        let invertedSummaryStats = invertedSummary?["stats"] as? [String: Any]
        #expect(invertedSubmatches?.isEmpty == true)
        #expect(invertedStats?["matched_lines"] as? Int == 2)
        #expect(invertedStats?["matches"] as? Int == 0)
        #expect(invertedSummaryStats?["matches"] as? Int == 0)

        let noLineNumberOutput = try run(["--json", "-N", "-C1", "needle", root.path("json.txt")])
        let noLineNumberMessages = try noLineNumberOutput.map(jsonObject)
        let noLineNumberContext = noLineNumberMessages[1]["data"] as? [String: Any]
        let noLineNumberMatch = noLineNumberMessages[2]["data"] as? [String: Any]
        #expect(noLineNumberContext?["line_number"] is NSNull)
        #expect(noLineNumberMatch?["line_number"] is NSNull)

        let binaryOutput = try run(["--json", "-n", "needle", root.path("binary.txt")])
        let binaryMessages = try binaryOutput.map(jsonObject)
        #expect(binaryMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let binaryMatch = binaryMessages[1]["data"] as? [String: Any]
        let binaryLines = binaryMatch?["lines"] as? [String: String]
        #expect(binaryLines?["text"] == "needle\n")
        let binaryEnd = binaryMessages[2]["data"] as? [String: Any]
        #expect(binaryEnd?["binary_offset"] as? Int == 7)

        let binaryOnlyOutput = try run(["--json", "-n", "tail", root.path("binary.txt")])
        let binaryOnlyMessages = try binaryOnlyOutput.map(jsonObject)
        #expect(binaryOnlyMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let binaryOnlyMatch = binaryOnlyMessages[1]["data"] as? [String: Any]
        let binaryOnlyLines = binaryOnlyMatch?["lines"] as? [String: String]
        #expect(binaryOnlyLines?["text"] == "tail\n")
        let binaryOnlyEnd = binaryOnlyMessages[2]["data"] as? [String: Any]
        #expect(binaryOnlyEnd?["binary_offset"] as? Int == 7)

        try root.write("test\r\n\n", to: "crlf-json.txt")
        let multilineOutput = try run(["-U", "--json", "\\n", root.path("crlf-json.txt")])
        let multilineMessages = try multilineOutput.map(jsonObject)
        #expect(multilineMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let multilineEnd = multilineMessages[2]["data"] as? [String: Any]
        let multilineStats = multilineEnd?["stats"] as? [String: Any]
        #expect(multilineStats?["bytes_searched"] as? Int == 7)
        #expect(multilineStats?["matched_lines"] as? Int == 2)
        #expect(multilineStats?["matches"] as? Int == 2)
        let multilineSummary = multilineMessages[3]["data"] as? [String: Any]
        let multilineSummaryStats = multilineSummary?["stats"] as? [String: Any]
        #expect(multilineSummaryStats?["bytes_searched"] as? Int == 7)
        #expect(multilineSummaryStats?["matched_lines"] as? Int == 2)
        #expect(multilineSummaryStats?["matches"] as? Int == 2)

        var relativeOptions = RipgrepOptions()
        relativeOptions.json = true
        relativeOptions.pattern = "needle"
        relativeOptions.patterns = ["needle"]
        relativeOptions.rootPathArguments = ["json.txt"]
        relativeOptions.roots = [root.url.appendingPathComponent("json.txt")]
        let relativeMatch = SearchMatch(
            fileURL: root.url.appendingPathComponent("json.txt"),
            lineNumber: 2,
            column: nil,
            line: "needle here",
            lineTerminator: "\n",
            absoluteOffset: 4,
            matchCount: 1,
            spans: [MatchSpan(startColumn: 1, endColumn: 7, startByte: 0, endByte: 6, text: "needle")]
        )
        let relativeResult = SearchResults(
            files: [SearchFileResult(fileURL: relativeMatch.fileURL, matches: [relativeMatch], bytesSearched: 23)],
            summary: SearchSummary(filesSearched: 1, filesWithMatches: 1, matchedLines: 1, totalMatches: 1)
        )
        let relativeMessages = try JSONPrinter(options: relativeOptions, currentDirectory: root.url.path)
            .lines(for: relativeResult)
            .map(jsonObject)
        let relativeBegin = relativeMessages[0]["data"] as? [String: Any]
        let relativePath = relativeBegin?["path"] as? [String: String]
        #expect(relativePath?["text"] == "json.txt")

        var separatorOptions = relativeOptions
        separatorOptions.pathSeparator = "|"
        separatorOptions.rootPathArguments = ["."]
        separatorOptions.roots = [root.url]
        let nestedJSONURL = root.url.appendingPathComponent("nested/json.txt")
        let separatorMatch = SearchMatch(
            fileURL: nestedJSONURL,
            lineNumber: 1,
            column: nil,
            line: "needle",
            lineTerminator: "\n",
            absoluteOffset: 0,
            matchCount: 1,
            spans: [MatchSpan(startColumn: 1, endColumn: 7, startByte: 0, endByte: 6, text: "needle")]
        )
        let separatorResult = SearchResults(
            files: [SearchFileResult(fileURL: separatorMatch.fileURL, matches: [separatorMatch], bytesSearched: 7)],
            summary: SearchSummary(filesSearched: 1, filesWithMatches: 1, matchedLines: 1, totalMatches: 1)
        )
        let separatorMessages = try JSONPrinter(options: separatorOptions, currentDirectory: root.url.path)
            .lines(for: separatorResult)
            .map(jsonObject)
        let separatorBegin = separatorMessages[0]["data"] as? [String: Any]
        let separatorPath = separatorBegin?["path"] as? [String: String]
        #expect(separatorPath?["text"] == "./nested/json.txt")
    }

    @Test("prints JSON replacement fields")
    func printsJSONReplacementFields() throws {
        let root = try TemporaryDirectory()
        try root.write("abc123\n", to: "json-replace.txt")

        let output = try run([
            "--json",
            "--replace",
            "$word/$digits/$missing",
            #"(?P<word>[a-z]+)(?P<digits>\d+)"#,
            root.path("json-replace.txt"),
        ])
        let messages = try output.map(jsonObject)
        let match = messages.first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let submatch = (match?["submatches"] as? [[String: Any]])?.first
        let replacement = submatch?["replacement"] as? [String: String]

        #expect(replacement?["text"] == "abc/123/")
    }

    @Test("JSON quiet stats emits summary only")
    func jsonQuietStatsEmitsSummaryOnly() throws {
        let root = try TemporaryDirectory()
        try root.write("hay\nneedle\n", to: "json-quiet.txt")

        let output = try run(["--json", "--quiet", "--stats", "needle", root.path("json-quiet.txt")])
        let messages = try output.map(jsonObject)
        #expect(messages.map { $0["type"] as? String } == ["summary"])
        let summary = messages[0]["data"] as? [String: Any]
        let stats = summary?["stats"] as? [String: Any]
        #expect(stats?["searches_with_match"] as? Int == 1)
        #expect(stats?["bytes_searched"] as? Int == 11)
        #expect(stats?["bytes_printed"] as? Int == 0)
    }

    @Test("JSON mode follows output mode flag ordering")
    func jsonModeFollowsOutputModeOrdering() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "ordering.txt")

        let reset = "\u{1B}[0m"
        let redBold = "\u{1B}[1m\u{1B}[31m"

        #expect(try run(["--json", "-l", "needle", root.path("ordering.txt")]) == [root.path("ordering.txt")])
        let output = try run(["-l", "--json", "needle", root.path("ordering.txt")])
        let messages = try output.map(jsonObject)
        #expect(messages.first?["type"] as? String == "begin")
        let filesThenJSON = try run(["--files", "--json", "needle", root.path("ordering.txt")])
        let filesThenJSONMessages = try filesThenJSON.map(jsonObject)
        #expect(filesThenJSONMessages.first?["type"] as? String == "begin")
        #expect(try run(["--files", "--json", "--no-json", "needle", root.path("ordering.txt")]) == ["needle"])
        #expect(try run(["--json", "--files", "--no-json", root.url.path]) == [root.path("ordering.txt")])
        #expect(try run(["--json", "-l", "--no-json", "needle", root.path("ordering.txt")]) == [root.path("ordering.txt")])
        #expect(try run(["--color=always", "--json", "--no-json", "needle", root.path("ordering.txt")]) == [
            "\(reset)\(redBold)needle\(reset)",
        ])
    }

}
