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

    @Test("limits matching lines per file")
    func limitsMatchingLinesPerFile() throws {
        let root = try TemporaryDirectory()
        try root.write("needle one\nneedle two\nneedle three\n", to: "many.txt")

        #expect(try run(["-m1", "needle", root.path("many.txt")]) == ["needle one"])
        #expect(try run(["--max-count", "2", "needle", root.path("many.txt")]) == ["needle one", "needle two"])
        #expect(try runAllowingNoMatch(["-m0", "needle", root.path("many.txt")]) == [])
        #expect(try run(["-m1", "-c", "needle", root.path("many.txt")]) == ["1"])
    }

    @Test("counts matching lines and individual matches")
    func countsMatchingLinesAndIndividualMatches() throws {
        let root = try TemporaryDirectory()
        try root.write("needle needle\nno\nneedle\n", to: "many.txt")
        try root.write("hay\n", to: "none.txt")

        #expect(try run(["-c", "needle", root.path("many.txt")]) == ["2"])
        #expect(try run(["--count-matches", "needle", root.path("many.txt")]) == ["3"])
        #expect(pathBasenames(try run(["--count-matches", "needle", root.url.path])) == ["many.txt"])
        #expect(try runAllowingNoMatch(["-c", "needle", root.path("none.txt")]) == [])
    }

    @Test("omits long matching lines after max columns")
    func omitsLongMatchingLinesAfterMaxColumns() throws {
        let root = try TemporaryDirectory()
        try root.write("short needle\nverylong needle tail\n", to: "columns.txt")

        #expect(try run(["--max-columns", "12", "needle", root.path("columns.txt")]) == [
            "[Omitted long matching line]",
            "[Omitted long matching line]",
        ])
        #expect(try run(["--max-columns", "12", "--max-columns-preview", "needle", root.path("columns.txt")]) == [
            "short needle [... omitted end of long line]",
            "verylong nee [... omitted end of long line]",
        ])
        #expect(try run(["-M0", "needle", root.path("columns.txt")]) == [
            "short needle",
            "verylong needle tail",
        ])
        #expect(try run(["-o", "--max-columns", "12", "needle", root.path("columns.txt")]) == [
            "needle",
            "needle",
        ])
    }

    @Test("prints byte offsets for lines and only matches")
    func printsByteOffsets() throws {
        let root = try TemporaryDirectory()
        try root.write("xx needle yy\nneedle\n", to: "offsets.txt")

        #expect(try run(["-n", "--byte-offset", "needle", root.path("offsets.txt")]) == [
            "1:0:xx needle yy",
            "2:13:needle",
        ])
        #expect(try run(["-n", "-o", "--byte-offset", "needle", root.path("offsets.txt")]) == [
            "1:3:needle",
            "2:13:needle",
        ])
        #expect(try run(["--column", "--byte-offset", "needle", root.path("offsets.txt")]) == [
            "1:4:0:xx needle yy",
            "2:1:13:needle",
        ])
    }

    @Test("searches NUL delimited data")
    func searchesNullDelimitedData() throws {
        let root = try TemporaryDirectory()
        try root.write(Data("alpha\0needle\0omega\0".utf8), to: "nul.txt")

        #expect(try run(["--null-data", "-n", "needle", root.path("nul.txt")]) == [
            "2:needle\0",
        ])
        #expect(try run(["--null-data", "-o", "needle", root.path("nul.txt")]) == [
            "needle\0",
        ])

        let output = try run(["--json", "--null-data", "needle", root.path("nul.txt")])
        let messages = try output.map(jsonObject)
        let match = messages.first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let lines = match?["lines"] as? [String: String]
        #expect(lines?["text"] == "needle\0")
        #expect(match?["line_number"] as? Int == 2)
        #expect(match?["absolute_offset"] as? Int == 6)
    }

    @Test("decodes BOM and explicit encodings")
    func decodesBOMAndExplicitEncodings() throws {
        let root = try TemporaryDirectory()
        try root.write(Data([0xFF, 0xFE]) + Data("hay\nneedle\n".utf16LittleEndianBytes), to: "bom16le.txt")
        try root.write(Data("hay\nneedle\n".utf16LittleEndianBytes), to: "utf16le.txt")
        try root.write(Data([0xEF, 0xBB, 0xBF]) + Data("needle\n".utf8), to: "bom8.txt")

        #expect(try run(["-n", "needle", root.path("bom16le.txt")]) == ["2:needle"])
        #expect(try runAllowingNoMatch(["-n", "-E", "none", "needle", root.path("bom16le.txt")]) == [])
        #expect(try run(["-n", "-E", "utf-16le", "needle", root.path("utf16le.txt")]) == ["2:needle"])
        #expect(try run(["-n", "needle", root.path("bom8.txt")]) == ["1:needle"])
        #expect(try run(["-n", "-E", "none", "\u{FEFF}needle", root.path("bom8.txt")]) == [
            "1:\u{FEFF}needle",
        ])
    }

    @Test("limits traversal depth")
    func limitsTraversalDepth() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "root.txt")
        try root.write("needle\n", to: "sub/one.txt")
        try root.write("needle\n", to: "sub/deeper/two.txt")

        #expect(try runAllowingNoMatch(["--max-depth", "0", "needle", root.url.path]) == [])
        #expect(pathBasenames(try run(["--max-depth", "1", "needle", root.url.path])) == ["root.txt"])
        #expect(pathBasenames(try run(["-d2", "needle", root.url.path])) == ["root.txt", "one.txt"])
    }

    @Test("sorts files by requested criteria")
    func sortsFilesByRequestedCriteria() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "b.txt")
        try root.write("needle\n", to: "a.txt")

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        try root.setModificationDate(newer, for: "a.txt")
        try root.setModificationDate(older, for: "b.txt")

        #expect(pathBasenames(try run(["--sort", "path", "needle", root.url.path])) == ["a.txt", "b.txt"])
        #expect(pathBasenames(try run(["--sortr", "path", "needle", root.url.path])) == ["b.txt", "a.txt"])
        #expect(pathBasenames(try run(["--sort", "modified", "needle", root.url.path])) == ["b.txt", "a.txt"])
        #expect(pathBasenames(try run(["--sort-files", "--files", root.url.path])) == ["a.txt", "b.txt"])
    }

    @Test("prints aggregate stats")
    func printsAggregateStats() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\nneedle two\nnope\n", to: "stats.txt")

        let output = try run(["--stats", "needle", root.path("stats.txt")])
        #expect(output.contains("2 matches"))
        #expect(output.contains("2 matched lines"))
        #expect(output.contains("1 files contained matches"))
        #expect(output.contains("1 files searched"))
        #expect(output.contains("23 bytes searched"))
        #expect(output.contains("18 bytes printed"))
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
        #expect(try run([
            "-n",
            "-A1",
            "--context-separator",
            "SEP",
            "-e",
            "match",
            "-e",
            "other",
            root.path("context.txt"),
        ]) == [
            "3:match",
            "4-four",
            "SEP",
            "6:other",
            "7-seven",
        ])
        #expect(try run([
            "-n",
            "-A1",
            "--no-context-separator",
            "-e",
            "match",
            "-e",
            "other",
            root.path("context.txt"),
        ]) == [
            "3:match",
            "4-four",
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

    @Test("prints trim vimgrep and heading modes")
    func printsTrimVimgrepAndHeadingModes() throws {
        let root = try TemporaryDirectory()
        try root.write("  needle one needle\n  no\n", to: "a.txt")
        try root.write("xx needle\n", to: "b.txt")

        #expect(try run(["-n", "--trim", "needle", root.path("a.txt")]) == [
            "1:needle one needle",
        ])
        #expect(try run(["--vimgrep", "needle", root.path("a.txt")]) == [
            "\(root.path("a.txt")):1:3:  needle one needle",
            "\(root.path("a.txt")):1:14:  needle one needle",
        ])
        #expect(try run(["--vimgrep", "-o", "needle", root.path("a.txt")]) == [
            "\(root.path("a.txt")):1:3:needle",
            "\(root.path("a.txt")):1:14:needle",
        ])
        #expect(try run(["--heading", "-n", "needle", root.url.path]) == [
            "\(root.path("a.txt"))",
            "1:  needle one needle",
            "",
            "\(root.path("b.txt"))",
            "1:xx needle",
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
        try root.createDirectory(".git")

        #expect(pathBasenames(try run(["needle", root.url.path])) == ["keep.txt"])
        #expect(pathBasenames(try run(["--no-ignore", "needle", root.url.path])) == ["keep.txt", "skip.log"])
    }

    @Test("honors rgignore and ignore family switches")
    func honorsRgignoreAndIgnoreFamilySwitches() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("needle\n", to: "skip-dot.txt")
        try root.write("needle\n", to: "skip-vcs.txt")
        try root.write("needle\n", to: "skip-explicit.txt")
        try root.write("skip-dot.txt\n", to: ".rgignore")
        try root.write("skip-vcs.txt\n", to: ".gitignore")
        try root.write("skip-explicit.txt\n", to: "ignore.txt")
        try root.createDirectory(".git")

        #expect(pathBasenames(try run([
            "--ignore-file",
            root.path("ignore.txt"),
            "needle",
            root.url.path,
        ])) == ["keep.txt"])
        #expect(pathBasenames(try run([
            "--no-ignore-dot",
            "--ignore-file",
            root.path("ignore.txt"),
            "needle",
            root.url.path,
        ])) == ["keep.txt", "skip-dot.txt"])
        #expect(pathBasenames(try run([
            "--no-ignore-vcs",
            "--ignore-file",
            root.path("ignore.txt"),
            "needle",
            root.url.path,
        ])) == ["keep.txt", "skip-vcs.txt"])
        #expect(pathBasenames(try run([
            "--no-ignore-files",
            "--ignore-file",
            root.path("ignore.txt"),
            "needle",
            root.url.path,
        ])) == ["keep.txt", "skip-explicit.txt"])

        let outsideGit = try TemporaryDirectory()
        try outsideGit.write("needle\n", to: "keep.txt")
        try outsideGit.write("needle\n", to: "skip-vcs.txt")
        try outsideGit.write("skip-vcs.txt\n", to: ".gitignore")
        #expect(pathBasenames(try run(["needle", outsideGit.url.path])) == ["keep.txt", "skip-vcs.txt"])
        #expect(pathBasenames(try run(["--no-require-git", "needle", outsideGit.url.path])) == ["keep.txt"])
    }

    @Test("honors parent ignore files and unrestricted levels")
    func honorsParentIgnoreFilesAndUnrestrictedLevels() throws {
        let parent = try TemporaryDirectory()
        try parent.write("skip.txt\n", to: ".rgignore")
        try parent.write("needle\n", to: "sub/keep.txt")
        try parent.write("needle\n", to: "sub/skip.txt")

        #expect(pathBasenames(try run(["needle", parent.path("sub")])) == ["keep.txt"])
        #expect(pathBasenames(try run(["--no-ignore-parent", "needle", parent.path("sub")])) == [
            "keep.txt",
            "skip.txt",
        ])

        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("needle\n", to: "skip.txt")
        try root.write("needle\n", to: ".hidden.txt")
        try root.write("skip.txt\n", to: ".rgignore")
        try root.write(Data("needle\0tail\n".utf8), to: "bin.dat")

        #expect(Set(pathBasenames(try run(["-u", "needle", root.url.path]))) == Set([
            "keep.txt",
            "skip.txt",
        ]))
        #expect(Set(pathBasenames(try run(["-uu", "needle", root.url.path]))) == Set([
            ".hidden.txt",
            "keep.txt",
            "skip.txt",
        ]))
        #expect(Set(pathBasenames(try run(["-uuu", "needle", root.url.path]))) == Set([
            ".hidden.txt",
            "bin.dat",
            "keep.txt",
            "skip.txt",
        ]))
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

    func setModificationDate(_ date: Date, for relativePath: String) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: path(relativePath)
        )
    }
}

private extension String {
    var utf16LittleEndianBytes: [UInt8] {
        utf16.flatMap { codeUnit in
            [
                UInt8(codeUnit & 0x00FF),
                UInt8((codeUnit & 0xFF00) >> 8),
            ]
        }
    }
}
