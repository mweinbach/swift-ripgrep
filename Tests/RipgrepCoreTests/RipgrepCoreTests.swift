import Foundation
import Testing
@testable import RipgrepCore

@Suite("Ripgrep searcher")
struct RipgrepSearcherTests {
    @Test("finds matching lines recursively")
    func findsMatchingLinesRecursively() throws {
        let root = try TemporaryDirectory()
        try root.write("alpha\nneedle here\nomega\n", to: "one.txt")
        try root.createDirectory("nested")
        try root.write("another needle\n", to: "nested/two.txt")

        let matches = try RipgrepSearcher().search(
            pattern: "needle",
            roots: [root.url]
        )

        #expect(matches.map(\.line) == ["another needle", "needle here"])
        #expect(matches.map(\.lineNumber) == [1, 2])
    }

    @Test("supports regex fixed string word and line matching")
    func supportsMatcherModes() throws {
        let root = try TemporaryDirectory()
        try root.write("abc123\nabc.123\nabc\nabc def\nxabc\n", to: "patterns.txt")

        #expect(try run(["abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["-F", "abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["-w", "abc", root.path("patterns.txt")]) == ["abc.123", "abc", "abc def"])
        #expect(try run(["-x", "abc", root.path("patterns.txt")]) == ["abc"])
    }

    @Test("supports smart case and inverted matches")
    func supportsSmartCaseAndInvertedMatches() throws {
        let root = try TemporaryDirectory()
        try root.write("Needle\nneedle\nhay\n", to: "case.txt")

        #expect(try run(["-S", "needle", root.path("case.txt")]) == ["Needle", "needle"])
        #expect(try run(["-S", "Needle", root.path("case.txt")]) == ["Needle"])
        #expect(try run(["-v", "needle", root.path("case.txt")]) == ["Needle", "hay"])
    }

    @Test("supports multiple regexp and pattern file inputs")
    func supportsMultiplePatterns() throws {
        let root = try TemporaryDirectory()
        try root.write("alpha\nbeta\ngamma\n", to: "words.txt")
        try root.write("alpha\ngamma\n", to: "patterns")

        #expect(try run(["-e", "alpha", "-e", "gamma", root.path("words.txt")]) == ["alpha", "gamma"])
        #expect(try run(["-f", root.path("patterns"), root.path("words.txt")]) == ["alpha", "gamma"])
    }

    @Test("formats line numbers columns counts and filename modes")
    func formatsOutputModes() throws {
        let root = try TemporaryDirectory()
        try root.write("alpha\nneedle here\nneedle there\n", to: "one.txt")
        try root.write("none\n", to: "two.txt")

        #expect(try run(["-n", "--column", "needle", root.path("one.txt")]) == [
            "2:1:needle here",
            "3:1:needle there",
        ])
        #expect(try run(["-H", "-c", "needle", root.path("one.txt")]) == [
            "\(root.path("one.txt")):2",
        ])
        #expect(try run(["-l", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["one.txt"])
        #expect(try run(["--files-without-match", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["two.txt"])
    }

    @Test("prints before after context and passthru")
    func printsContextAndPassthru() throws {
        let root = try TemporaryDirectory()
        try root.write("one\ntwo\nmatch\nfour\nfive\nother\nseven\n", to: "context.txt")

        #expect(try run(["-n", "-C1", "match", root.path("context.txt")]) == [
            "2-two",
            "3:match",
            "4-four",
        ])
        #expect(try run(["-n", "-A1", "-e", "match", "-e", "other", root.path("context.txt")]) == [
            "3:match",
            "4-four",
            "--",
            "6:other",
            "7-seven",
        ])
        #expect(try run(["-n", "--passthru", "match", root.path("context.txt")]) == [
            "1-one",
            "2-two",
            "3:match",
            "4-four",
            "5-five",
            "6-other",
            "7-seven",
        ])
    }

    @Test("prints only matching text and replacements")
    func printsOnlyMatchingAndReplacements() throws {
        let root = try TemporaryDirectory()
        try root.write("abc123 def456\n", to: "replace.txt")

        #expect(try run(["-o", "--column", #"\d+"#, root.path("replace.txt")]) == [
            "1:4:123",
            "1:11:456",
        ])
        #expect(try run(["--replace", "NUM", #"\d+"#, root.path("replace.txt")]) == [
            "abcNUM defNUM",
        ])
        #expect(try run(["-o", "--replace", "[$1]", #"([a-z]+)\d+"#, root.path("replace.txt")]) == [
            "[abc]",
            "[def]",
        ])
    }

    @Test("prints JSON lines for matches context and summary")
    func printsJSONLines() throws {
        let root = try TemporaryDirectory()
        try root.write("hay\nneedle here\nthere\n", to: "json.txt")

        let output = try run(["--json", "-n", "-C1", "needle", root.path("json.txt")])
        let messages = try output.map(jsonObject)

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
        #expect(stats?["matched_lines"] as? Int == 1)
        #expect(stats?["matches"] as? Int == 1)
    }

    @Test("prints JSON replacement fields")
    func printsJSONReplacementFields() throws {
        let root = try TemporaryDirectory()
        try root.write("abc123\n", to: "json-replace.txt")

        let output = try run(["--json", "--replace", "[$1]", #"([a-z]+)\d+"#, root.path("json-replace.txt")])
        let messages = try output.map(jsonObject)
        let match = messages.first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let submatch = (match?["submatches"] as? [[String: Any]])?.first
        let replacement = submatch?["replacement"] as? [String: String]

        #expect(replacement?["text"] == "[abc]")
    }

    @Test("JSON mode follows output mode flag ordering")
    func jsonModeFollowsOutputModeOrdering() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "ordering.txt")

        #expect(try run(["--json", "-l", "needle", root.path("ordering.txt")]) == [root.path("ordering.txt")])
        let output = try run(["-l", "--json", "needle", root.path("ordering.txt")])
        let messages = try output.map(jsonObject)
        #expect(messages.first?["type"] as? String == "begin")
    }

    @Test("lists files and honors hidden flag")
    func listsFilesAndHonorsHiddenFlag() throws {
        let root = try TemporaryDirectory()
        try root.write("visible\n", to: "visible.txt")
        try root.write("secret\n", to: ".hidden.txt")

        #expect(try run(["--files", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["visible.txt"])
        #expect(try run(["--files", "--hidden", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == [".hidden.txt", "visible.txt"])
    }

    @Test("honors ignore files and no ignore")
    func honorsIgnoreFilesAndNoIgnore() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("needle\n", to: "skip.log")
        try root.write("*.log\n", to: ".gitignore")

        #expect(pathBasenames(try run(["needle", root.url.path])) == ["keep.txt"])
        #expect(pathBasenames(try run(["--no-ignore", "needle", root.url.path])) == ["keep.txt", "skip.log"])
    }

    @Test("honors custom ignore file and override globs")
    func honorsCustomIgnoreFileAndOverrideGlobs() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.swift")
        try root.write("needle\n", to: "skip.txt")
        try root.write("skip.txt\n", to: "ignore.txt")

        #expect(pathBasenames(try run(["--ignore-file", root.path("ignore.txt"), "needle", root.url.path])) == ["keep.swift"])
        #expect(pathBasenames(try run(["-g", "*.swift", "needle", root.url.path])) == ["keep.swift"])
        #expect(pathBasenames(try run(["-g", "!skip.txt", "needle", root.url.path])) == ["keep.swift"])
    }

    @Test("filters by built in file types")
    func filtersByBuiltInFileTypes() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "Sources/main.swift")
        try root.write("needle\n", to: "Sources/main.rs")
        try root.write("needle\n", to: "README.md")

        #expect(pathBasenames(try run(["-tswift", "needle", root.url.path])) == ["main.swift"])
        #expect(pathBasenames(try run(["-trust", "needle", root.url.path])) == ["main.rs"])
        #expect(pathBasenames(try run(["-tall", "-Tmd", "needle", root.url.path])) == ["main.rs", "main.swift"])
    }

    @Test("supports type add clear include and list")
    func supportsTypeAddClearIncludeAndList() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "one.foo")
        try root.write("needle\n", to: "two.swift")
        try root.write("needle\n", to: "three.rs")

        #expect(pathBasenames(try run(["--type-add", "foo:*.foo", "-tfoo", "needle", root.url.path])) == ["one.foo"])
        #expect(pathBasenames(try run([
            "--type-add", "src:include:swift,rust",
            "-tsrc",
            "needle",
            root.url.path,
        ])) == ["three.rs", "two.swift"])
        #expect(pathBasenames(try run([
            "--type-clear", "swift",
            "--type-add", "swift:*.foo",
            "-tswift",
            "needle",
            root.url.path,
        ])) == ["one.foo"])

        let typeList = try run(["--type-add", "foo:*.foo", "--type-list"])
        #expect(typeList.contains("foo: *.foo"))
        #expect(typeList.contains("rust: *.rs"))
        #expect(typeList.contains("swift: *.swift"))
    }

    @Test("handles binary detection modes")
    func handlesBinaryDetectionModes() throws {
        let root = try TemporaryDirectory()
        try root.write(Data("needle\0tail\n".utf8), to: "bin.dat")

        #expect(try runAllowingNoMatch(["needle", root.url.path]) == [])
        #expect(try run(["needle", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(pathBasenames(try run(["--binary", "needle", root.url.path])) == ["bin.dat"])
        #expect(try run(["-a", "needle", root.path("bin.dat")]) == [
            "needle\0tail",
        ])
        #expect(try run(["-c", "needle", root.path("bin.dat")]) == ["1"])
        #expect(pathBasenames(try run(["-l", "needle", root.path("bin.dat")])) == ["bin.dat"])
    }

    @Test("searches provided stdin")
    func searchesProvidedStdin() throws {
        var output: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["-n", "needle", "-"],
            stdout: { output.append($0) },
            stdin: "hay\nneedle\n"
        )

        #expect(exitCode == 0)
        #expect(output == ["2:needle"])
    }

    @Test("returns exit code one when no matches are found")
    func returnsExitCodeOneWhenNoMatchesAreFound() throws {
        let root = try TemporaryDirectory()
        try root.write("alpha\nbeta\n", to: "file.txt")

        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)
    }

    @Test("prints help")
    func printsHelp() {
        var output: [String] = []

        let exitCode = RipgrepCLI.run(
            arguments: ["--help"],
            stdout: { output.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output.first?.contains("USAGE:") == true)
        #expect(output.first?.contains("--files") == true)
    }

    private func run(_ arguments: [String]) throws -> [String] {
        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: arguments,
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(errors.isEmpty)
        #expect(exitCode == (output.isEmpty ? 1 : 0))
        return output
    }

    private func runAllowingNoMatch(_ arguments: [String]) throws -> [String] {
        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: arguments,
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(errors.isEmpty)
        #expect(exitCode == (output.isEmpty ? 1 : 0))
        return output
    }

    private func pathBasenames(_ lines: [String]) -> [String] {
        lines.map { line in
            let path = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private func jsonObject(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripgrep-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func createDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func write(_ contents: String, to relativePath: String) throws {
        try write(Data(contents.utf8), to: relativePath)
    }

    func write(_ data: Data, to relativePath: String) throws {
        let fileURL = url.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
    }

    func path(_ relativePath: String) -> String {
        url.appendingPathComponent(relativePath, isDirectory: false).path
    }
}
