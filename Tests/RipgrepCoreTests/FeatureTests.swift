import Foundation
import Testing
@testable import RipgrepCore

@Suite("Ripgrep feature parity area", .serialized)
struct FeatureTests {
    @Test("quiet literal recursive search returns only exit status")
    func quietLiteralRecursiveSearchReturnsOnlyExitStatus() throws {
        let root = try TemporaryDirectory()
        try root.write("plain\n", to: "a.txt")
        try root.write("needle\n", to: "nested/b.txt")

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["-q", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-q", "absent", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)
    }

    @Test("quiet required-literal regex recursive search returns only exit status")
    func quietRequiredLiteralRegexRecursiveSearchReturnsOnlyExitStatus() throws {
        let root = try TemporaryDirectory()
        for index in 0..<170 {
            try root.write("plain \(index)\n", to: String(format: "prefix/file-%03d.txt", index))
        }
        try root.write("task TWA_RESUME\n", to: "prefix/file-120.txt")

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["-q", "[A-Z]+_RESUME", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-q", "[A-Z]+_MISSING", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)
    }

    @Test("quiet literal recursive summaries count exact matches")
    func quietLiteralRecursiveSummariesCountExactMatches() throws {
        let root = try TemporaryDirectory()
        try root.write("needle needle\nplain\nneedle\n", to: "a.txt")
        try root.write("plain\nneedle\n", to: "nested/b.txt")

        let statsQuiet = try run(["--stats", "-q", "needle", root.url.path])
        #expect(statsQuiet.contains("4 matches"))
        #expect(statsQuiet.contains("3 matched lines"))
        #expect(statsQuiet.contains("2 files contained matches"))
        #expect(statsQuiet.contains("2 files searched"))
        #expect(statsQuiet.contains("0 bytes printed"))

        let jsonQuiet = try run(["--json", "-q", "needle", root.url.path])
        let jsonQuietObject = try jsonObject(jsonQuiet[0])
        let jsonQuietData = jsonQuietObject["data"] as? [String: Any]
        let jsonQuietStats = jsonQuietData?["stats"] as? [String: Any]
        #expect(jsonQuietStats?["matches"] as? Int == 4)
        #expect(jsonQuietStats?["matched_lines"] as? Int == 3)
        #expect(jsonQuietStats?["searches_with_match"] as? Int == 2)
        #expect(jsonQuietStats?["searches"] as? Int == 2)
        #expect(jsonQuietStats?["bytes_printed"] as? Int == 0)

        #expect(pathBasenames(try run(["-A1", "-l", "needle", root.url.path])).sorted() == [
            "a.txt",
            "b.txt",
        ])
    }

    @Test("only matching literal output preserves every span")
    func onlyMatchingLiteralOutputPreservesEverySpan() throws {
        let root = try TemporaryDirectory()
        try root.write("needle needle\nplain needle\n", to: "matches.txt")

        #expect(try run(["-o", "needle", root.path("matches.txt")]) == [
            "needle",
            "needle",
            "needle",
        ])
        #expect(try run(["-on", "needle", root.path("matches.txt")]) == [
            "1:needle",
            "1:needle",
            "2:needle",
        ])
    }

    @Test("honors no unicode regex and literal semantics")
    func honorsNoUnicodeSemantics() throws {
        let root = try TemporaryDirectory()
        try root.write("café\nπ\n_\n", to: "classes.txt")
        try root.write("éx\nxé\nx\n", to: "words.txt")
        try root.write("Σ\nσ\nς\nStraße\nSTRASSE\nstrasse\n", to: "casefold.txt")
        try root.write("ABC\nabc\nδ\n", to: "ascii-case.txt")
        try root.write("abc ABC 123 _ é π\nword-word\nfoo bar\n", to: "posix-alpha.txt")
        try root.write("abc ABC\nbar\nfoo bar\néx xé\n123_\n", to: "inline-word-boundary.txt")
        try root.write("π δ Δ µ Ω\n", to: "greek-script.txt")
        try root.write("ascii\nπ line\ncafe\nµ line\nΩ line\n", to: "greek-lines.txt")
        try root.write("abc ABC café π δ Δ xyz_123 éx xé\n", to: "scoped-modes.txt")
        try root.write("\n##\n", to: "empty-word.txt")

        #expect(try run(["-o", #"\w+"#, root.path("classes.txt")]) == ["café", "π", "_"])
        #expect(try run(["--no-unicode", "-o", #"\w+"#, root.path("classes.txt")]) == ["caf", "_"])
        #expect(try run(["-o", #"(?-u)\w+"#, root.path("classes.txt")]) == ["caf", "_"])
        #expect(try run(["-w", "x", root.path("words.txt")]) == ["x"])
        #expect(try run(["-won", "x", root.path("words.txt")]) == ["3:x"])
        #expect(try run(["-w", #"(?-u:\w+)|é"#, root.path("inline-word-boundary.txt")]) == [
            "abc ABC",
            "bar",
            "foo bar",
            "123_",
        ])
        #expect(try run(["-wo", #"(?-u:\w+)|é"#, root.path("inline-word-boundary.txt")]) == [
            "abc",
            "ABC",
            "bar",
            "foo",
            "bar",
            "123_",
        ])
        #expect(try run(["-won", "", root.path("empty-word.txt")]) == ["1:", "2:", "2:", "2:"])
        let noUnicodeWordOutput = try runExecutableData(["--no-unicode", "-w", "x", root.path("words.txt")], fixture: {})
        #expect(noUnicodeWordOutput == Data("éx\nxé\nx\n".utf8))
        #expect(try run(["--no-unicode", "-bo", #"\b"#, root.path("words.txt")]) == [
            "2:",
            "3:",
            "4:",
            "5:",
            "8:",
            "9:",
        ])
        #expect(try run(["--no-unicode", "-bo", #"\B"#, root.path("words.txt")]) == [
            "0:",
            "1:",
            "6:",
            "7:",
        ])
        #expect(try run(["-F", "-i", "σ", root.path("casefold.txt")]) == ["Σ", "σ", "ς"])
        #expect(try run(["-i", "σ", root.path("casefold.txt")]) == ["Σ", "σ", "ς"])
        #expect(try run(["-i", "strasse", root.path("casefold.txt")]) == ["STRASSE", "strasse"])
        #expect(try run(["-iw", "strasse", root.path("casefold.txt")]) == ["STRASSE", "strasse"])
        #expect(try run(["-i", "straße", root.path("casefold.txt")]) == ["Straße"])
        #expect(try run(["-i", "[a-z]+", root.path("ascii-case.txt")]) == ["ABC", "abc"])
        let noUnicodeFixedOutput = try runExecutableData([
            "--no-unicode",
            "-F",
            "-i",
            "σ",
            root.path("casefold.txt"),
        ], fixture: {})
        #expect(noUnicodeFixedOutput == Data("σ\n".utf8))
        let noUnicodeRegexLiteralOutput = try runExecutableData([
            "--no-unicode",
            "σ",
            root.path("casefold.txt"),
        ], fixture: {})
        #expect(noUnicodeRegexLiteralOutput == Data("σ\n".utf8))
        let inlineNoUnicodeRegexLiteralOutput = try runExecutableData([
            "(?-u)σ",
            root.path("casefold.txt"),
        ], fixture: {})
        #expect(inlineNoUnicodeRegexLiteralOutput == Data("σ\n".utf8))
        #expect(try run(["--no-unicode", "-i", "abc", root.path("ascii-case.txt")]) == ["ABC", "abc"])
        #expect(try run(["--no-unicode", "-i", "[a-z]+", root.path("ascii-case.txt")]) == ["ABC", "abc"])
        #expect(try run(["-o", "[[:alpha:]]+", root.path("posix-alpha.txt")]) == ["abc", "ABC", "word", "word", "foo", "bar"])
        #expect(try run(["-o", #"\pL+"#, root.path("posix-alpha.txt")]) == ["abc", "ABC", "é", "π", "word", "word", "foo", "bar"])
        #expect(try run(["-o", #"\p{Greek}+"#, root.path("greek-script.txt")]) == ["π", "δ", "Δ", "Ω"])
        #expect(try run(["-io", #"\p{Greek}+"#, root.path("greek-script.txt")]) == ["π", "δ", "Δ", "µ", "Ω"])
        #expect(try run(["-n", #"\p{Greek}"#, root.path("greek-lines.txt")]) == ["2:π line", "5:Ω line"])
        #expect(try run(["-in", #"\p{Greek}"#, root.path("greek-lines.txt")]) == ["2:π line", "4:µ line", "5:Ω line"])
        #expect(try run(["-o", #"\PL+"#, root.path("posix-alpha.txt")]) == [" ", " 123 _ ", " ", "-", " "])
        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--no-unicode", #"\pL+"#, root.path("posix-alpha.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["""
        rg: regex parse error:
            (?:\\pL+)
               ^^^
        error: Unicode not allowed here
        """])
        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: [#"(?-u:[\p{Greek}]+)"#, root.path("posix-alpha.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["""
        rg: regex parse error:
            (?:(?-u:[\\p{Greek}]+))
                     ^^^^^^^^^
        error: Unicode not allowed here
        """])
        #expect(try run(["--no-unicode", "-o", #"(?u:\pL+)"#, root.path("posix-alpha.txt")]) == ["abc", "ABC", "é", "π", "word", "word", "foo", "bar"])
        #expect(try run(["--no-unicode", "-o", #"(?u)\w+"#, root.path("classes.txt")]) == ["café", "π", "_"])
        #expect(try run(["-o", #"(?u:\pL+)\s+(?-u:\w+)"#, root.path("scoped-modes.txt")]) == [
            "abc ABC",
            "Δ xyz_123",
            "éx x",
        ])
        #expect(try run(["--no-unicode", "-o", #"(?u:\pL+)\s+(?-u:\w+)"#, root.path("scoped-modes.txt")]) == [
            "abc ABC",
            "Δ xyz_123",
            "éx x",
        ])
        #expect(try run(["--no-unicode", "-i", "[[:alpha:]]+", root.path("ascii-case.txt")]) == ["ABC", "abc"])
        #expect(try runAllowingNoMatch(["--no-unicode", "-i", "Δ", root.path("ascii-case.txt")]) == [])
        #expect(try run(["--no-unicode", "--unicode", "-o", #"\w+"#, root.path("classes.txt")]) == ["café", "π", "_"])
        #expect(try run(["--no-pcre2-unicode", "--pcre2-unicode", "-o", #"\w+"#, root.path("classes.txt")]) == ["café", "π", "_"])
    }

    @Test("matches Greek script property recursively")
    func matchesGreekScriptPropertyRecursively() throws {
        let root = try TemporaryDirectory()
        try root.write("latin\nπ alpha\n", to: "a.txt")
        try root.write("micro µ\nomega Ω\n", to: "nested/b.txt")
        try root.write("plain\ncafé\nsnow ☃\n", to: "nested/c.txt")

        #expect(try run(["--sort", "path", "-n", #"\p{Greek}"#, root.url.path]) == [
            "\(root.path("a.txt")):2:π alpha",
            "\(root.path("nested/b.txt")):2:omega Ω",
        ])
        #expect(try run(["--sort", "path", "-n", "-i", #"\p{Greek}"#, root.url.path]) == [
            "\(root.path("a.txt")):2:π alpha",
            "\(root.path("nested/b.txt")):1:micro µ",
            "\(root.path("nested/b.txt")):2:omega Ω",
        ])
        #expect(try run(["--sort", "path", "-c", #"\p{Greek}"#, root.url.path]) == [
            "\(root.path("a.txt")):1",
            "\(root.path("nested/b.txt")):1",
        ])
        #expect(try run(["--sort", "path", "-i", "-c", #"\p{Greek}"#, root.url.path]) == [
            "\(root.path("a.txt")):1",
            "\(root.path("nested/b.txt")):2",
        ])
        #expect(try run(["--sort", "path", "--count-matches", #"\p{Greek}+"#, root.url.path]) == [
            "\(root.path("a.txt")):1",
            "\(root.path("nested/b.txt")):1",
        ])
        #expect(try run(["--sort", "path", "-l", #"\p{Greek}"#, root.url.path]) == [
            root.path("a.txt"),
            root.path("nested/b.txt"),
        ])
        let statsFilesWithMatches = try run([
            "--sort",
            "path",
            "--stats",
            "-l",
            #"\p{Greek}"#,
            root.url.path,
        ])
        #expect(statsFilesWithMatches.contains("2 matches"))
        #expect(statsFilesWithMatches.contains("2 matched lines"))
        #expect(statsFilesWithMatches.contains("2 files contained matches"))
        #expect(statsFilesWithMatches.contains("3 files searched"))
        let statsQuiet = try run([
            "--sort",
            "path",
            "--stats",
            "-q",
            #"\p{Greek}"#,
            root.url.path,
        ])
        #expect(statsQuiet.contains("2 matches"))
        #expect(statsQuiet.contains("2 matched lines"))
        #expect(statsQuiet.contains("2 files contained matches"))
        #expect(statsQuiet.contains("3 files searched"))
        #expect(statsQuiet.contains("0 bytes printed"))
        let jsonQuiet = try run([
            "--json",
            "-q",
            #"\p{Greek}"#,
            root.url.path,
        ])
        let jsonQuietObject = try jsonObject(jsonQuiet[0])
        let jsonQuietData = jsonQuietObject["data"] as? [String: Any]
        let jsonQuietStats = jsonQuietData?["stats"] as? [String: Any]
        #expect(jsonQuietStats?["matches"] as? Int == 2)
        #expect(jsonQuietStats?["matched_lines"] as? Int == 2)
        #expect(jsonQuietStats?["searches_with_match"] as? Int == 2)
        #expect(jsonQuietStats?["searches"] as? Int == 3)
        #expect(jsonQuietStats?["bytes_printed"] as? Int == 0)
        let jsonStatsQuiet = try run([
            "--json",
            "--stats",
            "-q",
            #"\p{Greek}"#,
            root.url.path,
        ])
        let jsonStatsQuietObject = try jsonObject(jsonStatsQuiet[0])
        let jsonStatsQuietData = jsonStatsQuietObject["data"] as? [String: Any]
        let jsonStatsQuietStats = jsonStatsQuietData?["stats"] as? [String: Any]
        #expect(jsonStatsQuietStats?["matches"] as? Int == 2)
        #expect(jsonStatsQuietStats?["matched_lines"] as? Int == 2)
        #expect(jsonStatsQuietStats?["searches_with_match"] as? Int == 2)
        #expect(jsonStatsQuietStats?["searches"] as? Int == 3)
        #expect(jsonStatsQuietStats?["bytes_printed"] as? Int == 0)
    }

    @Test("supports smart case and inverted matches")
    func supportsSmartCaseAndInvertedMatches() throws {
        let root = try TemporaryDirectory()
        try root.write("Needle\nneedle\nhay\n", to: "case.txt")

        #expect(try run(["-S", "needle", root.path("case.txt")]) == ["Needle", "needle"])
        #expect(try run(["-S", "Needle", root.path("case.txt")]) == ["Needle"])
        #expect(try run(["-i", "-S", "Needle", root.path("case.txt")]) == ["Needle"])
        #expect(try run(["-S", "-i", "Needle", root.path("case.txt")]) == ["Needle", "needle"])
        #expect(try run(["-i", "--case-sensitive", "needle", root.path("case.txt")]) == ["needle"])
        #expect(try run(["-s", "-i", "needle", root.path("case.txt")]) == ["Needle", "needle"])
        #expect(try run(["-v", "needle", root.path("case.txt")]) == ["Needle", "hay"])
        #expect(try run(["-v", "--no-invert-match", "needle", root.path("case.txt")]) == ["needle"])
    }

    @Test("supports multiple regexp and pattern file inputs")
    func supportsMultiplePatterns() throws {
        let root = try TemporaryDirectory()
        try root.write("alpha\nbeta\ngamma\n", to: "words.txt")
        try root.write("alpha\ngamma\n", to: "patterns")
        try root.write("alpha\r\ngamma\r\n", to: "crlf-patterns")
        try root.write("", to: "zero-patterns")
        try root.write("\n", to: "empty-pattern")

        #expect(try run(["-e", "alpha", "-e", "gamma", root.path("words.txt")]) == ["alpha", "gamma"])
        #expect(try run(["-f", root.path("patterns"), root.path("words.txt")]) == ["alpha", "gamma"])
        #expect(try run(["-f", root.path("crlf-patterns"), root.path("words.txt")]) == ["alpha", "gamma"])
        #expect(try run(["-f\(root.path("patterns"))", root.path("words.txt")]) == ["alpha", "gamma"])
        #expect(try run(["-vf", root.path("patterns"), root.path("words.txt")]) == ["beta"])
        #expect(try runAllowingNoMatch(["-f", root.path("zero-patterns"), root.path("words.txt")]) == [])
        #expect(try run(["-f", root.path("empty-pattern"), root.path("words.txt")]) == [
            "alpha",
            "beta",
            "gamma",
        ])
        #expect(try run(["-vf", root.path("zero-patterns"), root.path("words.txt")]) == [
            "alpha",
            "beta",
            "gamma",
        ])
        #expect(try runAllowingNoMatch(["-vf", root.path("empty-pattern"), root.path("words.txt")]) == [])
        #expect(try runAllowingNoMatch(["-f", "/dev/null", root.path("words.txt")]) == [])

        try root.write("alpha.*\n", to: "literal-patterns")
        try root.write("alpha.*\nalphaX\n", to: "literal.txt")
        #expect(try run(["-Ff", root.path("literal-patterns"), root.path("literal.txt")]) == ["alpha.*"])

        var output: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["-f-", root.path("words.txt")],
            stdout: { output.append($0) },
            stdin: "alpha\ngamma\n"
        )
        #expect(exitCode == 0)
        #expect(output == ["alpha", "gamma"])

        output = []
        var errors: [String] = []
        let missingExitCode = RipgrepCLI.run(
            arguments: ["-f", "missing", root.path("words.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(missingExitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: missing: No such file or directory (os error 2)"])

        output = []
        errors = []
        let directoryExitCode = RipgrepCLI.run(
            arguments: ["-f", root.url.path, root.path("words.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(directoryExitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: \(root.url.path):Is a directory (os error 21)"])
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
        #expect(try run(["-n", "--column", "--no-column", "needle", root.path("one.txt")]) == [
            "2:needle here",
            "3:needle there",
        ])
        #expect(try run(["-n", "-N", "needle", root.path("one.txt")]) == [
            "needle here",
            "needle there",
        ])
        #expect(try run(["-N", "-n", "needle", root.path("one.txt")]) == [
            "2:needle here",
            "3:needle there",
        ])
        #expect(try run(["-N", "--pretty", "--color=never", "needle", root.path("one.txt")]) == [
            "2:needle here",
            "3:needle there",
        ])
        let numberedRoot = try TemporaryDirectory()
        let numberedLiteralLines = (1...40).map { line in
            line == 37 ? "prefix anchor suffix anchor" : "filler \(line)"
        }.joined(separator: "\n") + "\nanchor again\n"
        try numberedRoot.write(numberedLiteralLines, to: "numbered-literal.txt")
        #expect(try run(["-n", "anchor", numberedRoot.path("numbered-literal.txt")]) == [
            "37:prefix anchor suffix anchor",
            "41:anchor again",
        ])
        #expect(try run(["-H", "-n", "-m1", "anchor", numberedRoot.path("numbered-literal.txt")]) == [
            "\(numberedRoot.path("numbered-literal.txt")):37:prefix anchor suffix anchor",
        ])
        #expect(try run(["-n", "-i", "ANCHOR", numberedRoot.path("numbered-literal.txt")]) == [
            "37:prefix anchor suffix anchor",
            "41:anchor again",
        ])
        #expect(try run(["-H", "-c", "needle", root.path("one.txt")]) == [
            "\(root.path("one.txt")):2",
        ])
        #expect(try run(["-l", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["one.txt"])
        #expect(try run(["--files", "-l", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["one.txt"])
        #expect(try run(["--files", "--files-without-match", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["two.txt"])
        #expect(try run(["--files-without-match", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["two.txt"])
        let crlfFilesWithMatches = try runExecutableData(["--crlf", "-l", "needle", root.url.path]) {}
        #expect(crlfFilesWithMatches == Data("\(root.path("one.txt"))\r\n".utf8))
        let crlfFilesWithoutMatch = try runExecutableData(["--crlf", "--files-without-match", "needle", root.url.path]) {}
        #expect(crlfFilesWithoutMatch == Data("\(root.path("two.txt"))\r\n".utf8))
        try root.write("pin one\n", to: "heading-a.txt")
        try root.write("pin two\n", to: "heading-b.txt")
        let crlfHeadingOutput = try runExecutableData([
            "--sort",
            "path",
            "--crlf",
            "--heading",
            "pin",
            root.url.path,
        ]) {}
        #expect(crlfHeadingOutput == Data((
            "\(root.path("heading-a.txt"))\r\n" +
            "pin one\n" +
            "\r\n" +
            "\(root.path("heading-b.txt"))\r\n" +
            "pin two\n"
        ).utf8))

        var output: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--files-without-match", "-q", "needle", root.path("two.txt")],
            stdout: { output.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.isEmpty)

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files-without-match", "-q", "needle", root.path("one.txt")],
            stdout: { output.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)

        try root.write("pin\nmiddle\nhay\n", to: "ctx.txt")
        #expect(try run([
            "-n",
            "-C1",
            "--field-match-separator",
            "::",
            "--field-context-separator",
            "~~",
            "pin",
            root.path("ctx.txt"),
        ]) == [
            "1::pin",
            "2~~middle",
        ])
        #expect(try run([
            "--vimgrep",
            "--field-match-separator",
            "::",
            "needle",
            root.path("one.txt"),
        ]) == [
            "\(root.path("one.txt"))::2::1::needle here",
            "\(root.path("one.txt"))::3::1::needle there",
        ])
    }

    @Test("prints NUL terminated paths and custom path separators")
    func printsNullTerminatedPathsAndCustomPathSeparators() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "dir/one.txt")
        try root.write("hay\n", to: "dir/two.txt")

        #expect(try run(["-l", "--null", "needle", root.url.path]) == [
            "\(root.path("dir/one.txt"))\0",
        ])
        let executableOutput = try runExecutableData(["-l", "--null", "needle", root.url.path]) {}
        #expect(executableOutput == Data("\(root.path("dir/one.txt"))\0".utf8))
        let nullDataFilesWithMatches = try runExecutableData(["-l", "--null-data", "needle", root.url.path]) {}
        #expect(nullDataFilesWithMatches == Data("\(root.path("dir/one.txt"))\0".utf8))
        #expect(Set(try run(["--files", "--null", root.url.path])) == Set([
            "\(root.path("dir/one.txt"))\0",
            "\(root.path("dir/two.txt"))\0",
        ]))
        #expect(try run(["--null", "needle", root.url.path]) == [
            "\(root.path("dir/one.txt"))\0needle",
        ])
        #expect(try run(["-l", "--path-separator", #"\"#, "needle", root.url.path]) == [
            root.path("dir/one.txt").replacingOccurrences(of: "/", with: #"\"#),
        ])
        #expect(try run(["-l", "--path-separator", #"\x5A"#, "needle", root.url.path]) == [
            root.path("dir/one.txt").replacingOccurrences(of: "/", with: "Z"),
        ])
        #expect(try run([
            "-l",
            "--path-separator",
            "Z",
            "--path-separator=",
            "needle",
            root.url.path,
        ]) == [
            root.path("dir/one.txt"),
        ])

        try root.write("needle\n", to: "unicode-é.txt")
        #expect(try run(["--files", "--sort", "path", root.url.path]) == [
            root.path("dir/one.txt"),
            root.path("dir/two.txt"),
            root.path("unicode-é.txt").precomposedStringWithCanonicalMapping,
        ])
        #expect(try run(["-l", "--sort", "path", "needle", root.url.path]) == [
            root.path("dir/one.txt"),
            root.path("unicode-é.txt").precomposedStringWithCanonicalMapping,
        ])

        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--path-separator", "ø", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == [
            """
            rg: error parsing flag --path-separator: A path separator must be exactly one byte, but the given separator is 2 bytes: ø
            In some shells on Windows '/' is automatically expanded. Use '//' instead.
            """,
        ])

        output = []
        errors = []
        let overEscapedExitCode = RipgrepCLI.run(
            arguments: ["--path-separator", #"\\x00"#, "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(overEscapedExitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == [
            #"""
            rg: error parsing flag --path-separator: A path separator must be exactly one byte, but the given separator is 4 bytes: \\x00
            In some shells on Windows '/' is automatically expanded. Use '//' instead.
            """#,
        ])
    }

    @Test("limits matching lines per file")
    func limitsMatchingLinesPerFile() throws {
        let root = try TemporaryDirectory()
        try root.write("needle one\nneedle two\nneedle three\n", to: "many.txt")

        #expect(try run(["-m1", "needle", root.path("many.txt")]) == ["needle one"])
        #expect(try run(["--max-count", "2", "needle", root.path("many.txt")]) == ["needle one", "needle two"])
        #expect(try run(["-m1", "-c", "needle", root.path("many.txt")]) == ["1"])

        try root.write("first alpha\nsecond beta\nthird alpha beta\n", to: "alternation.txt")
        #expect(try run(["-m1", "beta|alpha", root.path("alternation.txt")]) == ["first alpha"])
        #expect(try run(["-m2", "beta|alpha", root.path("alternation.txt")]) == ["first alpha", "second beta"])
        #expect(try run(["-m129", "beta|alpha", root.path("alternation.txt")]) == [
            "first alpha",
            "second beta",
            "third alpha beta",
        ])
        #expect(try run(["-m1280", "beta|alpha", root.path("alternation.txt")]) == [
            "first alpha",
            "second beta",
            "third alpha beta",
        ])
        #expect(try run(["-n", "-m1", "beta|alpha", root.path("alternation.txt")]) == ["1:first alpha"])
        #expect(try run(["-n", "-m2", "beta|alpha", root.path("alternation.txt")]) == [
            "1:first alpha",
            "2:second beta",
        ])
        #expect(try run(["-c", "-m1", "beta|alpha", root.path("alternation.txt")]) == ["1"])
        #expect(try run(["-c", "-m2", "beta|alpha", root.path("alternation.txt")]) == ["2"])
        let executableAlternationM2 = try runExecutableData(["-m2", "beta|alpha", root.path("alternation.txt")]) {}
        #expect(String(decoding: executableAlternationM2, as: UTF8.self) == "first alpha\nsecond beta\n")

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["-m0", "needle", root.path("many.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        for arguments in [
            ["-m0", "-q", "needle", root.path("many.txt")],
            ["-m0", "-l", "needle", root.path("many.txt")],
            ["-m0", "-c", "--include-zero", "needle", root.path("many.txt")],
            ["-m0", "needle", root.path("missing.txt")],
        ] {
            output = []
            errors = []
            exitCode = RipgrepCLI.run(
                arguments: arguments,
                stdout: { output.append($0) },
                stderr: { errors.append($0) }
            )
            #expect(exitCode == 1)
            #expect(output.isEmpty)
            #expect(errors.isEmpty)
        }

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--max-count=0", "needle", root.path("many.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-m", "nope", "needle", root.path("many.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: error parsing flag -m: value is not a valid number: invalid digit found in string"])
    }

    @Test("counts matching lines and individual matches")
    func countsMatchingLinesAndIndividualMatches() throws {
        let root = try TemporaryDirectory()
        try root.write("needle needle\nno\nneedle\n", to: "many.txt")
        try root.write("hay\n", to: "none.txt")

        #expect(try run(["-c", "needle", root.path("many.txt")]) == ["2"])
        #expect(try run(["--count-matches", "needle", root.path("many.txt")]) == ["3"])
        #expect(try run(["-H", "-c", "needle|no", root.path("many.txt")]) == [
            "\(root.path("many.txt")):3",
        ])
        #expect(try run(["-H", "--count-matches", "needle|no", root.path("many.txt")]) == [
            "\(root.path("many.txt")):4",
        ])
        #expect(pathBasenames(try run(["--count-matches", "needle", root.url.path])) == ["many.txt"])
        #expect(try runAllowingNoMatch(["-c", "needle", root.path("none.txt")]) == [])

        #expect(countBasenames(try run(["-c", "--include-zero", "needle", root.url.path])) == [
            "none.txt:0",
            "many.txt:2",
        ])
        #expect(countBasenames(try run(["--count-matches", "--include-zero", "needle", root.url.path])) == [
            "none.txt:0",
            "many.txt:3",
        ])
        #expect(countBasenames(try run(["--sort", "path", "-c", "--include-zero", "needle", root.url.path])) == [
            "many.txt:2",
            "none.txt:0",
        ])

        let traversalRoot = try TemporaryDirectory()
        try traversalRoot.write("needle\nneedle\n", to: "a.txt")
        try traversalRoot.write("hay\n", to: "b.txt")
        try traversalRoot.write("needle\n", to: "sub/c.txt")
        #expect(countBasenames(try run(["-c", "--include-zero", "needle", traversalRoot.url.path])) == [
            "a.txt:2",
            "c.txt:1",
            "b.txt:0",
        ])

        var output: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["-c", "--include-zero", "absent", root.path("none.txt")],
            stdout: { output.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output == ["0"])

        output = []
        let filenameZeroExitCode = RipgrepCLI.run(
            arguments: ["-H", "--count-matches", "--include-zero", "absent", root.path("none.txt")],
            stdout: { output.append($0) }
        )
        #expect(filenameZeroExitCode == 1)
        #expect(output == ["\(root.path("none.txt")):0"])
    }

    @Test("omits long matching lines after max columns")
    func omitsLongMatchingLinesAfterMaxColumns() throws {
        let root = try TemporaryDirectory()
        try root.write("short needle\nverylong needle tail\n", to: "columns.txt")

        #expect(try run(["--max-columns", "12", "needle", root.path("columns.txt")]) == [
            "[Omitted long matching line]",
            "[Omitted long matching line]",
        ])
        #expect(try run(["--color=always", "--max-columns", "12", "needle", root.path("columns.txt")]) == [
            "[Omitted long line with 1 matches]",
            "[Omitted long line with 1 matches]",
        ])
        try root.write("needle needle\n", to: "columns-stats.txt")
        let longStatsOutput = try run(["--max-columns", "10", "--stats", "needle", root.path("columns-stats.txt")])
        #expect(longStatsOutput.first == "[Omitted long line with 2 matches]")
        #expect(longStatsOutput.contains("35 bytes printed"))
        let longPreviewStatsOutput = try run([
            "--max-columns", "10",
            "--max-columns-preview",
            "--stats",
            "needle",
            root.path("columns-stats.txt"),
        ])
        #expect(longPreviewStatsOutput.first == "needle nee [... 0 more matches]")
        #expect(longPreviewStatsOutput.contains("32 bytes printed"))
        let reset = "\u{1B}[0m"
        let redBold = "\u{1B}[1m\u{1B}[31m"
        #expect(try run(["--color=always", "--max-columns", "20", "needle", root.path("columns.txt")]) == [
            "short \(reset)\(redBold)needle\(reset)",
            "[Omitted long line with 1 matches]",
        ])
        #expect(try run(["--max-columns", "12", "--max-columns-preview", "needle", root.path("columns.txt")]) == [
            "short needle [... omitted end of long line]",
            "verylong nee [... omitted end of long line]",
        ])
        let crlfOmitted = try runExecutableData([
            "--crlf",
            "--max-columns",
            "12",
            "needle",
            root.path("columns.txt"),
        ]) {}
        #expect(crlfOmitted == Data(
            "[Omitted long matching line]\r\n[Omitted long matching line]\r\n".utf8
        ))
        try root.write(Data("one\r\nneedle\r\ntwo\r\n".utf8), to: "source-crlf-columns.txt")
        let sourceCRLFOmitted = try runExecutableData([
            "--crlf",
            "--max-columns",
            "5",
            #"[a-z]+\d*"#,
            root.path("source-crlf-columns.txt"),
        ]) {}
        #expect(sourceCRLFOmitted == Data(
            "one\r\n[Omitted long matching line]\r\ntwo\r\n".utf8
        ))
        let crlfPreview = try runExecutableData([
            "--crlf",
            "--max-columns",
            "12",
            "--max-columns-preview",
            "needle",
            root.path("columns.txt"),
        ]) {}
        #expect(crlfPreview == Data(
            "short needle [... omitted end of long line]\r\nverylong nee [... omitted end of long line]\r\n".utf8
        ))
        #expect(try run(["-M0", "needle", root.path("columns.txt")]) == [
            "short needle",
            "verylong needle tail",
        ])
        #expect(try run(["-o", "--max-columns", "12", "needle", root.path("columns.txt")]) == [
            "needle",
            "needle",
        ])
        #expect(try run([
            "-o",
            "--column",
            "--max-columns",
            "12",
            "--max-columns-preview",
            "needle",
            root.path("columns.txt"),
        ]) == [
            "1:7:needle",
            "2:10:needle",
        ])
        #expect(try run([
            "-o",
            "--column",
            "--max-columns",
            "6",
            "needle",
            root.path("columns.txt"),
        ]) == [
            "1:7:needle",
            "2:10:needle",
        ])
        #expect(try run(["--column", "--max-columns", "12", "needle", root.path("columns.txt")]) == [
            "1:7:[Omitted long line with 1 matches]",
            "2:10:[Omitted long line with 1 matches]",
        ])
        #expect(try run([
            "-o",
            "--column",
            "--max-columns",
            "5",
            "--max-columns-preview",
            "needle",
            root.path("columns.txt"),
        ]) == [
            "1:7:needl [... 0 more matches]",
            "2:10:needl [... 0 more matches]",
        ])
        try root.write("long needle line here\n", to: "only-preview-cutoff.txt")
        #expect(try run([
            "-o",
            "-M5",
            "--max-columns-preview",
            "needle",
            root.path("only-preview-cutoff.txt"),
        ]) == [
            "needl [... 1 more match]",
        ])
        #expect(try run(["-M", "12", "--replace", "PIN", "needle", root.path("columns.txt")]) == [
            "short PIN",
            "[Omitted long line with 1 matches]",
        ])
        try root.write("needle tail\nhay\nneedle tail again\n", to: "replacement-context-columns.txt")
        #expect(try run([
            "-M5",
            "-B1",
            "--replace",
            "X",
            #"needle\s+tail"#,
            root.path("replacement-context-columns.txt"),
        ]) == [
            "X",
            "hay",
            "[Omitted long line with 1 matches]",
        ])
        try root.write("needle middle needle tail\n", to: "replacement-preview.txt")
        #expect(try run([
            "-M",
            "14",
            "--max-columns-preview",
            "--replace",
            "PIN",
            "needle",
            root.path("replacement-preview.txt"),
        ]) == [
            "PIN middle PIN [... 0 more matches]",
        ])

        try root.write("     0123456789abcdefghijklmnopqrstuvwxyz\n", to: "trim-columns.txt")
        #expect(try run([
            "--trim",
            "--max-columns-preview",
            "-M8",
            "--color=always",
            "--colors=path:none",
            "--no-filename",
            "abc",
            root.path("trim-columns.txt"),
        ]) == [
            "01234567 [... 1 more match]",
        ])

        try root.write("""
        but Doctor Watson has to have it taken out for him and dusted,
        and exhibited clearly, with a label attached.
        """, to: "replacement-multiline-preview.txt")
        #expect(try run([
            "-M43",
            "--max-columns-preview",
            "-rxxx",
            "exhibited|dusted|has to have it",
            root.path("replacement-multiline-preview.txt"),
        ]) == [
            "but Doctor Watson xxx taken out for him and [... 1 more match]",
            "and xxx clearly, with a label attached.",
        ])

        try root.write("needle\nthis context line is very long\n", to: "context-columns.txt")
        #expect(try run(["-M", "20", "-A1", "needle", root.path("context-columns.txt")]) == [
            "needle",
            "[Omitted long context line]",
        ])
        let crlfContextOmitted = try runExecutableData([
            "--crlf",
            "-M",
            "20",
            "-A1",
            "needle",
            root.path("context-columns.txt"),
        ]) {}
        #expect(crlfContextOmitted == Data("needle\n[Omitted long context line]\r\n".utf8))
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
        try root.write("Needle\nneedle\nfoo needle foo\n", to: "invert-offsets.txt")
        #expect(try run(["--column", "-v", "needle", root.path("invert-offsets.txt")]) == [
            "1:Needle",
        ])
        #expect(try run(["--column", "--byte-offset", "-v", "needle", root.path("invert-offsets.txt")]) == [
            "1:0:Needle",
        ])
        #expect(try run(["-n", "--byte-offset", "-A1", "needle", root.path("offsets.txt")]) == [
            "1:0:xx needle yy",
            "2:13:needle",
        ])

        try root.write("pre\nneedle one\nctx\nneedle two\npost\n", to: "max-context-offsets.txt")
        #expect(try run(["-n", "--byte-offset", "-m1", "-A2", "needle", root.path("max-context-offsets.txt")]) == [
            "2:4:needle one",
            "3-15-ctx",
            "4:19:needle two",
        ])
        #expect(try run(["-n", "--byte-offset", "-m1", "-o", "-A2", "needle", root.path("max-context-offsets.txt")]) == [
            "2:4:needle",
            "3-15-ctx",
            "4:19:needle",
        ])
        #expect(try run(["-m1", "-A2", "--count", "needle", root.path("max-context-offsets.txt")]) == [
            "2",
        ])
        #expect(try run(["-m1", "-A2", "--count-matches", "needle", root.path("max-context-offsets.txt")]) == [
            "2",
        ])

        try root.write("éabc\n", to: "unicode-offsets.txt")
        #expect(try run(["-o", "--column", "abc", root.path("unicode-offsets.txt")]) == [
            "1:3:abc",
        ])
        #expect(try run(["-o", "--byte-offset", "--column", "abc", root.path("unicode-offsets.txt")]) == [
            "1:3:2:abc",
        ])
        try root.write("solo", to: "unterminated.txt")
        #expect(try run(["--column", "-n", "-o", "$", root.path("unterminated.txt")]) == [
            "1:solo",
        ])
        #expect(try run(["--column", "-n", "-o", #"\z"#, root.path("unterminated.txt")]) == [
            "1:solo",
        ])
        try root.write("á\na_1\n--\n", to: "unicode-empty-offsets.txt")
        #expect(try run(["--count-matches", "x?", root.path("unicode-empty-offsets.txt")]) == [
            "10",
        ])
        #expect(try run(["--count-matches", "a?", root.path("unicode-empty-offsets.txt")]) == [
            "9",
        ])
        #expect(try run(["-bo", "x?", root.path("unicode-empty-offsets.txt")]) == [
            "0:",
            "1:",
            "2:",
            "3:",
            "4:",
            "5:",
            "6:",
            "7:",
            "8:",
            "9:",
        ])
        #expect(try run(["-bo", "^", root.path("unicode-empty-offsets.txt")]) == [
            "0:",
            "3:",
            "7:",
        ])
        #expect(try run(["-bo", #"\b"#, root.path("unicode-empty-offsets.txt")]) == [
            "0:",
            "2:",
            "3:",
            "6:",
        ])
        #expect(try run(["--count-matches", #"\b"#, root.path("unicode-empty-offsets.txt")]) == [
            "4",
        ])
        #expect(try run(["-n", "--column", "-o", "x?", root.path("unicode-empty-offsets.txt")]) == [
            "1:1:",
            "1:2:",
            "1:3:",
            "2:1:",
            "2:2:",
            "2:3:",
            "2:4:",
            "3:1:",
            "3:2:",
            "3:3:",
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
        #expect(try run(["--null-data", "-c", "needle", root.path("nul.txt")]) == [
            "1\0",
        ])
        #expect(try run(["--null-data", "--count-matches", "needle", root.path("nul.txt")]) == [
            "1\0",
        ])
        var nullTerminatorOutput: [String] = []
        var nullTerminatorErrors: [String] = []
        let nullTerminatorExitCode = RipgrepCLI.run(
            arguments: ["--null-data", #"\x00"#, root.path("nul.txt")],
            stdout: { nullTerminatorOutput.append($0) },
            stderr: { nullTerminatorErrors.append($0) }
        )
        #expect(nullTerminatorExitCode == 2)
        #expect(nullTerminatorOutput.isEmpty)
        #expect(nullTerminatorErrors == ["""
        rg: the literal "\\0" is not allowed in a regex

        Consider enabling multiline mode with the --multiline flag (or -U for short).
        When multiline mode is enabled, new line characters can be matched.
        """])
        #expect(try run(["--null-data", #"[^\x00]"#, root.path("nul.txt")]) == [
            "alpha\0",
            "needle\0",
            "omega\0",
        ])
        try root.write(Data("abc\0needle\nneedle2\0tail\n".utf8), to: "nul-anchors.txt")
        #expect(try run(["--null-data", "-n", "--column", "--byte-offset", "^needle", root.path("nul-anchors.txt")]) == [
            "2:8:4:needle\nneedle2\0",
        ])
        #expect(try run(["--null-data", "-o", "--column", "needle$", root.path("nul-anchors.txt")]) == [
            "2:1:needle\0",
        ])
        try root.write(Data("foo\0bar\0foo bar\0end\0".utf8), to: "nul-inline-m.txt")
        try root.write(Data("foo\0bar".utf8), to: "nul-inline-m-no-final.txt")
        try root.write(Data("foo\0bar\0foo bar\0end\0bar".utf8), to: "nul-inline-m-final-bar.txt")
        #expect(try runAllowingNoMatch(["--null-data", #"(?-m)bar$"#, root.path("nul-inline-m.txt")]) == [])
        #expect(try run(["--null-data", #"(?-m)^bar"#, root.path("nul-inline-m.txt")]) == ["bar\0"])
        #expect(try run(["--null-data", #"(?-m)bar$"#, root.path("nul-inline-m-no-final.txt")]) == ["bar\0"])
        let nullDataInlineAlternationOutput = try runExecutableData([
            "--null-data",
            "-o",
            #"(?-m:bar$)|foo"#,
            root.path("nul-inline-m-final-bar.txt"),
        ], fixture: {})
        #expect(nullDataInlineAlternationOutput == Data("foo\0foo\0bar\0bar\0".utf8))
        let nullDataInlineOnlyFinalOutput = try runExecutableData([
            "--null-data",
            "-o",
            #"(?-m:bar$)|xxx"#,
            root.path("nul-inline-m-final-bar.txt"),
        ], fixture: {})
        #expect(nullDataInlineOnlyFinalOutput == Data("bar\0".utf8))
        let nullDataUnanchoredAlternativeOutput = try runExecutableData([
            "--null-data",
            "-o",
            #"bar|(?-m:bar$)"#,
            root.path("nul-inline-m-final-bar.txt"),
        ], fixture: {})
        #expect(nullDataUnanchoredAlternativeOutput == Data("bar\0bar\0bar\0".utf8))
        let anchorOutput = try run(["--json", "--null-data", "^needle", root.path("nul-anchors.txt")])
        let anchorMessages = try anchorOutput.map(jsonObject)
        let anchorMatch = anchorMessages.first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let anchorSubmatches = anchorMatch?["submatches"] as? [[String: Any]]
        #expect(anchorSubmatches?.first?["start"] as? Int == 7)
        #expect(anchorSubmatches?.first?["end"] as? Int == 13)
        try root.write("needle\nunterminated\n", to: "lf.txt")
        #expect(try run(["--null-data", "needle", root.path("lf.txt")]) == [
            "needle\nunterminated\n\0",
        ])
        #expect(try run(["--null-data", #"needle\nunterminated"#, root.path("lf.txt")]) == [
            "needle\nunterminated\n\0",
        ])
        #expect(try run(["--null-data", #"^$"#, root.path("lf.txt")]) == [
            "needle\nunterminated\n\0",
        ])
        try root.write(Data([0x61, 0x00, 0x62, 0x0A, 0x00, 0x0A]), to: "nul-empty-anchors.txt")
        let nullDataDotOutput = try runExecutableData([
            "--null-data",
            "-o",
            ".",
            root.path("nul-empty-anchors.txt"),
        ], fixture: {})
        #expect(nullDataDotOutput == Data([0x61, 0x00, 0x62, 0x00]))
        let nullDataLineEndOutput = try runExecutableData([
            "--null-data",
            "-bo",
            "$",
            root.path("nul-empty-anchors.txt"),
        ], fixture: {})
        #expect(nullDataLineEndOutput == Data([
            0x31, 0x3A, 0x00,
            0x33, 0x3A, 0x00,
            0x34, 0x3A, 0x00,
            0x35, 0x3A, 0x00,
        ]))
        let nullDataLineStartOutput = try runExecutableData([
            "--null-data",
            "-bo",
            "^",
            root.path("nul-empty-anchors.txt"),
        ], fixture: {})
        #expect(nullDataLineStartOutput == Data([
            0x30, 0x3A, 0x00,
            0x32, 0x3A, 0x00,
            0x34, 0x3A, 0x00,
            0x35, 0x3A, 0x00,
        ]))
        #expect(try run(["--null-data", "--count-matches", "$", root.path("nul-empty-anchors.txt")]) == [
            "4\0",
        ])

        try root.write(Data("needle\0tail\0needle tail\0".utf8), to: "nul-record-start.txt")
        let nullDataRecordStartColumnOutput = try runExecutableData([
            "--null-data",
            "--column",
            "^needle",
            root.path("nul-record-start.txt"),
        ], fixture: {})
        #expect(nullDataRecordStartColumnOutput == Data("1:1:needle\03:needle tail\0".utf8))
        let nullDataRecordStartOnlyOutput = try runExecutableData([
            "--null-data",
            "-o",
            "^needle",
            root.path("nul-record-start.txt"),
        ], fixture: {})
        #expect(nullDataRecordStartOnlyOutput == Data("needle\0needle tail\0".utf8))
        try root.write(Data("abc\0def\0needle\0".utf8), to: "nul-record-anchors.txt")
        let nullDataOnlyLineStartOutput = try runExecutableData([
            "--null-data",
            "-o",
            "^",
            root.path("nul-record-anchors.txt"),
        ], fixture: {})
        #expect(nullDataOnlyLineStartOutput == Data("\0def\0needle\0".utf8))
        let nullDataOnlyLineStartEndOutput = try runExecutableData([
            "--null-data",
            "-o",
            "^|$",
            root.path("nul-record-anchors.txt"),
        ], fixture: {})
        #expect(nullDataOnlyLineStartEndOutput == Data([0x00, 0x00, 0x00, 0x00]))
        #expect(try run(["--null-data", "--count-matches", "^|$", root.path("nul-record-anchors.txt")]) == [
            "6\0",
        ])
        try root.write(Data("foo\0bar\nzzz\0foo\n".utf8), to: "nul-record-starts.txt")
        let nullDataOnlyRecordStartOutput = try runExecutableData([
            "--null-data",
            "-n",
            "-o",
            "^",
            root.path("nul-record-starts.txt"),
        ], fixture: {})
        #expect(nullDataOnlyRecordStartOutput == Data("1:\02:\03:\0".utf8))
        #expect(try run(["--null-data", "--count-matches", "^", root.path("nul-record-starts.txt")]) == [
            "3\0",
        ])
        #expect(try run(["--null-data", "--count-matches", "^|$", root.path("nul-record-starts.txt")]) == [
            "7\0",
        ])
        let nullDataRecordStartEndJSONOutput = try run([
            "--json",
            "--null-data",
            "^|$",
            root.path("nul-record-starts.txt"),
        ])
        let nullDataRecordStartEndMessages = try nullDataRecordStartEndJSONOutput.map(jsonObject)
        let nullDataRecordStartEndMatches = nullDataRecordStartEndMessages.compactMap { object -> [String: Any]? in
            guard object["type"] as? String == "match" else { return nil }
            return object["data"] as? [String: Any]
        }
        let nullDataRecordStartEndSubmatches = nullDataRecordStartEndMatches.compactMap { $0["submatches"] as? [[String: Any]] }
        #expect(nullDataRecordStartEndSubmatches.map(\.count) == [2, 3, 2])
        let nullDataRecordStartJSONOutput = try run([
            "--json",
            "--null-data",
            "^needle",
            root.path("nul-record-start.txt"),
        ])
        let nullDataRecordStartMessages = try nullDataRecordStartJSONOutput.map(jsonObject)
        let nullDataRecordStartMatches = nullDataRecordStartMessages.compactMap { object -> [String: Any]? in
            guard object["type"] as? String == "match" else { return nil }
            return object["data"] as? [String: Any]
        }
        let nullDataRecordStartSubmatches = nullDataRecordStartMatches.compactMap { $0["submatches"] as? [[String: Any]] }
        #expect(nullDataRecordStartSubmatches.map(\.count) == [1, 0])

        try root.write(Data("needle\r\ntail needle\r\nlast\r\n".utf8), to: "null-data-crlf-record.txt")
        let nullDataEmptyLineColumnOutput = try runExecutableData([
            "--null-data",
            "--column",
            "^$",
            root.path("null-data-crlf-record.txt"),
        ], fixture: {})
        #expect(nullDataEmptyLineColumnOutput == Data("1:needle\r\ntail needle\r\nlast\r\n\0".utf8))
        let nullDataEmptyLineOnlyOutput = try runExecutableData([
            "--null-data",
            "-o",
            "^$",
            root.path("null-data-crlf-record.txt"),
        ], fixture: {})
        #expect(nullDataEmptyLineOnlyOutput == Data("needle\r\ntail needle\r\nlast\r\n\0".utf8))
        #expect(try run(["--null-data", "--count-matches", "^$", root.path("null-data-crlf-record.txt")]) == [
            "1\0",
        ])
        #expect(try run(["--null-data", "--count-matches", "$", root.path("null-data-crlf-record.txt")]) == [
            "3\0",
        ])
        try root.write(Data("a\0needle\nb\0\n".utf8), to: "null-data-empty-record-line.txt")
        let nullDataEmptyOnlyOutput = try runExecutableData([
            "--null-data",
            "-o",
            "^$",
            root.path("null-data-empty-record-line.txt"),
        ], fixture: {})
        #expect(nullDataEmptyOnlyOutput == Data([0x00]))
        #expect(try run(["--null-data", "--count-matches", "^$", root.path("null-data-empty-record-line.txt")]) == [
            "1\0",
        ])

        let output = try run(["--json", "--null-data", "needle", root.path("nul.txt")])
        let messages = try output.map(jsonObject)
        let match = messages.first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let lines = match?["lines"] as? [String: String]
        #expect(lines?["text"] == "needle\0")
        #expect(match?["line_number"] as? Int == 2)
        #expect(match?["absolute_offset"] as? Int == 6)

        try root.write("needle\nhay\nneedle\n", to: "lf-record.txt")
        let lfRecordOutput = try run(["--json", "--null-data", "needle", root.path("lf-record.txt")])
        let lfRecordMessages = try lfRecordOutput.map(jsonObject)
        let lfRecordEnd = lfRecordMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let lfRecordStats = lfRecordEnd?["stats"] as? [String: Any]
        let lfRecordSummary = lfRecordMessages.first { $0["type"] as? String == "summary" }?["data"] as? [String: Any]
        let lfRecordSummaryStats = lfRecordSummary?["stats"] as? [String: Any]
        #expect(lfRecordStats?["matched_lines"] as? Int == 1)
        #expect(lfRecordSummaryStats?["matched_lines"] as? Int == 1)

        try root.write(Data([0x61, 0x00, 0x62, 0x00, 0x63]), to: "binary-nul.txt")
        #expect(try run(["--count-matches", "$", root.path("binary-nul.txt")]) == [
            "3",
        ])
        #expect(try run(["--count-matches", #"\b"#, root.path("binary-nul.txt")]) == [
            "5",
        ])
        try root.write(Data("a\0b\0ab\0\0".utf8), to: "binary-multiline-nul.txt")
        #expect(try run(["-U", "--count-matches", #"[^\n]+"#, root.path("binary-multiline-nul.txt")]) == [
            "3",
        ])
        #expect(try run(["-U", "--count-matches", #"[^\x0A]+"#, root.path("binary-multiline-nul.txt")]) == [
            "3",
        ])
        #expect(try run(["-U", "--count-matches", #"[^\x00]"#, root.path("binary-multiline-nul.txt")]) == [
            "4",
        ])
        #expect(try run(["-U", "-a", "--count-matches", #"[^\n]+"#, root.path("binary-multiline-nul.txt")]) == [
            "1",
        ])
        let binaryAnchorOutput = try run(["--json", "$", root.path("binary-nul.txt")])
        let binaryAnchorMessages = try binaryAnchorOutput.map(jsonObject)
        let binaryAnchorMatches = binaryAnchorMessages.compactMap { object -> [String: Any]? in
            guard object["type"] as? String == "match" else { return nil }
            return object["data"] as? [String: Any]
        }
        #expect(binaryAnchorMatches.count == 3)
        let binaryAnchorSubmatches = binaryAnchorMatches.compactMap { $0["submatches"] as? [[String: Any]] }
        #expect(binaryAnchorSubmatches.map(\.count) == [1, 1, 0])
        let binaryAnchorEnd = binaryAnchorMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let binaryAnchorStats = binaryAnchorEnd?["stats"] as? [String: Any]
        #expect(binaryAnchorStats?["matched_lines"] as? Int == 3)
        #expect(binaryAnchorStats?["matches"] as? Int == 2)

        let binaryBoundaryOutput = try run(["--json", #"\b"#, root.path("binary-nul.txt")])
        let binaryBoundaryMessages = try binaryBoundaryOutput.map(jsonObject)
        let binaryBoundaryMatches = binaryBoundaryMessages.compactMap { object -> [String: Any]? in
            guard object["type"] as? String == "match" else { return nil }
            return object["data"] as? [String: Any]
        }
        let binaryBoundarySubmatches = binaryBoundaryMatches.compactMap { $0["submatches"] as? [[String: Any]] }
        #expect(binaryBoundarySubmatches.map(\.count) == [2, 2, 1])
        let binaryBoundaryEnd = binaryBoundaryMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let binaryBoundaryStats = binaryBoundaryEnd?["stats"] as? [String: Any]
        #expect(binaryBoundaryStats?["matched_lines"] as? Int == 3)
        #expect(binaryBoundaryStats?["matches"] as? Int == 5)
    }

    @Test("decodes BOM and explicit encodings")
    func decodesBOMAndExplicitEncodings() throws {
        let root = try TemporaryDirectory()
        try root.write(Data([0xFF, 0xFE]) + Data("hay\nneedle\n".utf16LittleEndianBytes), to: "bom16le.txt")
        try root.write(Data([0xFE, 0xFF]) + Data("needle\n".utf16BigEndianBytes), to: "bom16be.txt")
        try root.write(Data("hay\nneedle\n".utf16LittleEndianBytes), to: "utf16le.txt")
        try root.write(Data("needle\n".utf16BigEndianBytes), to: "utf16be.txt")
        try root.write(Data([0xEF, 0xBB, 0xBF]) + Data("needle\n".utf8), to: "bom8.txt")
        try root.write(Data([0xFF, 0xFE, 0x00, 0x62, 0x0A]), to: "bom16le-invalid.txt")
        try root.write(Data([
            0x84, 0x59, 0x84, 0x75, 0x84, 0x82, 0x84, 0x7C, 0x84, 0x80, 0x84, 0x7B,
            0x20,
            0x84, 0x56, 0x84, 0x80, 0x84, 0x7C, 0x84, 0x7D, 0x84, 0x83,
        ]), to: "sjis.txt")
        try root.write(Data([
            0xA7, 0xBA, 0xA7, 0xD6, 0xA7, 0xE2, 0xA7, 0xDD, 0xA7, 0xE0, 0xA7, 0xDC,
            0x20,
            0xA7, 0xB7, 0xA7, 0xE0, 0xA7, 0xDD, 0xA7, 0xDE, 0xA7, 0xE3,
        ]), to: "eucjp.txt")

        #expect(try run(["-n", "needle", root.path("bom16le.txt")]) == ["2:needle"])
        #expect(try run(["-n", "-E", "utf-16le", "needle", root.path("bom16le.txt")]) == ["2:needle"])
        #expect(try run(["-n", "-E", "utf-16", "needle", root.path("utf16le.txt")]) == ["2:needle"])
        #expect(try run(["-n", "-E", "utf-16be", "needle", root.path("bom16be.txt")]) == ["1:needle"])
        #expect(try run(["-n", "-E", "utf-16", "needle", root.path("bom16be.txt")]) == ["1:needle"])
        #expect(try run(["-n", "-E", "utf-16", "needle", root.path("bom16le.txt")]) == ["2:needle"])
        #expect(try runAllowingNoMatch(["-n", "-E", "utf-16", "needle", root.path("utf16be.txt")]) == [])
        #expect(try run(["-n", "-E", "utf-16le", "needle", root.path("bom16be.txt")]) == ["1:needle"])
        #expect(try run(["-n", "-E", "utf-16be", "needle", root.path("bom16le.txt")]) == ["2:needle"])
        #expect(try runAllowingNoMatch(["-n", "-E", "none", "needle", root.path("bom16le.txt")]) == [])
        #expect(try run(["-n", "-E", "utf-16le", "needle", root.path("utf16le.txt")]) == ["2:needle"])
        #expect(try run(["-n", "needle", root.path("bom8.txt")]) == ["1:needle"])
        #expect(try run(["-a", "-n", "needle", root.path("bom16le.txt")]) == ["2:needle"])
        #expect(try run(["--text", "-n", "needle", root.path("bom16le.txt")]) == ["2:needle"])
        try root.write(Data("needle utf16\n".utf16LittleEndianBytes), to: "utf16le-raw.txt")
        let rawUTF16Stats = try run([
            "-a",
            "--stats",
            #"\x00"#,
            root.path("utf16le-raw.txt"),
        ])
        #expect(rawUTF16Stats.contains("13 matches"))
        #expect(rawUTF16Stats.contains("2 matched lines"))
        let rawUTF16JSONOutput = try run([
            "--json",
            "-a",
            #"\x00"#,
            root.path("utf16le-raw.txt"),
        ])
        let rawUTF16JSONMessages = try rawUTF16JSONOutput.map(jsonObject)
        let rawUTF16JSONEnd = rawUTF16JSONMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let rawUTF16JSONStats = rawUTF16JSONEnd?["stats"] as? [String: Any]
        #expect(rawUTF16JSONStats?["matched_lines"] as? Int == 2)
        #expect(rawUTF16JSONStats?["matches"] as? Int == 13)
        let bom16JSONOutput = try run(["--json", "needle", root.path("bom16le.txt")])
        let bom16JSONMessages = try bom16JSONOutput.map(jsonObject)
        let bom16JSONMatch = bom16JSONMessages.first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let bom16JSONLines = bom16JSONMatch?["lines"] as? [String: String]
        #expect(bom16JSONLines?["text"] == "needle\n")
        #expect(try run([".", root.path("bom16le-invalid.txt")]) == ["戀\u{FFFD}"])
        #expect(try run(["-o", ".", root.path("bom16le-invalid.txt")]) == [
            "戀",
            "\u{FFFD}",
        ])
        #expect(try run(["-E", "utf-16le", "-o", ".", root.path("bom8.txt")]) == [
            "敮",
            "摥",
            "敬",
            "\u{FFFD}",
        ])
        let bomRawOutput = try runExecutableData([
            "-n",
            "-E",
            "none",
            "\u{FEFF}needle",
            root.path("bom8.txt"),
        ], fixture: {})
        #expect(bomRawOutput == Data([
            0x31, 0x3A,
            0xEF, 0xBB, 0xBF,
            0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65,
            0x0A,
        ]))
        let rawOutput = try runExecutableData([
            "--encoding",
            "none",
            "-a",
            #"\x00"#,
            root.path("raw-bytes.txt"),
        ], fixture: {
            try root.write(Data([0xFF, 0xFE, 0x00, 0x62]), to: "raw-bytes.txt")
        })
        #expect(rawOutput == Data([0xFF, 0xFE, 0x00, 0x62, 0x0A]))
        #expect(try run(["--encoding", "none", "-a", "-o", "--byte-offset", #"\x00"#, root.path("raw-bytes.txt")]) == [
            "2:\0",
        ])
        let textOutput = try runExecutableData([
            "-a",
            "-n",
            "foo",
            root.path("invalid-utf8.txt"),
        ], fixture: {
            try root.write(
                Data([0xC3, 0xA9, 0x0A, 0xFF, 0x66, 0x6F, 0x6F, 0x0A]),
                to: "invalid-utf8.txt"
            )
        })
        #expect(textOutput == Data([0x32, 0x3A, 0xFF, 0x66, 0x6F, 0x6F, 0x0A]))
        try root.write("cafe\nCAFÉ\ncafé\n", to: "valid-utf8.txt")
        let validUTF8TextOutput = try runExecutableData([
            "-a",
            "[a-z]+",
            root.path("valid-utf8.txt"),
        ], fixture: {})
        #expect(validUTF8TextOutput == Data("cafe\ncafé\n".utf8))
        let validUTF8NullDataOutput = try runExecutableData([
            "--null-data",
            "[a-z]+",
            root.path("valid-utf8.txt"),
        ], fixture: {})
        #expect(validUTF8NullDataOutput == Data("cafe\nCAFÉ\ncafé\n\0".utf8))
        let validUTF8MaxColumnsOutput = try runExecutableData([
            "--max-columns",
            "4",
            "--max-columns-preview",
            "[[:word:]]+",
            root.path("valid-utf8.txt"),
        ], fixture: {})
        #expect(validUTF8MaxColumnsOutput == Data(
            "cafe [... omitted end of long line]\nCAFÉ [... omitted end of long line]\ncafé [... omitted end of long line]\n".utf8
        ))
        try root.write(Data([
            0x63, 0x61, 0x66, 0xE9, 0x0A,
            0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x20, 0x63, 0x61, 0x66, 0xE9, 0x0A,
        ]), to: "latin1.txt")
        try root.write(Data([
            0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x8B, 0x91,
            0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x99, 0x9F, 0x0A,
        ]), to: "latin1-c1.txt")
        #expect(try runAllowingNoMatch(["caf.", root.path("latin1.txt")]) == [])
        #expect(try runAllowingNoMatch(["--no-encoding", "caf.", root.path("latin1.txt")]) == [])
        let invalidAutomaticLineOutput = try runExecutableData(["needle", root.path("latin1.txt")], fixture: {})
        #expect(invalidAutomaticLineOutput == Data([
            0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x20, 0x63, 0x61, 0x66, 0xE9, 0x0A,
        ]))
        try root.write("naïve needle\n", to: "utf8-mixed.txt")
        let mixedAutomaticOutput = try runExecutableData(["needle", root.url.path], fixture: {})
        #expect(mixedAutomaticOutput.contains(Data("utf8-mixed.txt:naïve needle\n".utf8)))
        #expect(mixedAutomaticOutput.contains(Data([
            0x6C, 0x61, 0x74, 0x69, 0x6E, 0x31, 0x2E, 0x74, 0x78, 0x74, 0x3A,
            0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x20, 0x63, 0x61, 0x66, 0xE9, 0x0A,
        ])))
        #expect(try run(["--encoding", "latin1", "caf.", root.path("latin1.txt")]) == [
            "café",
            "needle café",
        ])
        #expect(try run(["--encoding", "latin1", ".", root.path("latin1-c1.txt")]) == [
            "€\u{81}‚ƒ„…‹‘’“”•–—™Ÿ",
        ])
        #expect(try run(["--encoding", "iso-8859-1", "-o", ".", root.path("latin1-c1.txt")]) == [
            "€",
            "\u{81}",
            "‚",
            "ƒ",
            "„",
            "…",
            "‹",
            "‘",
            "’",
            "“",
            "”",
            "•",
            "–",
            "—",
            "™",
            "Ÿ",
        ])
        let latin1JsonOutput = try run(["--json", "--encoding", "latin1", "caf.", root.path("latin1.txt")])
        let latin1JsonMatches = try latin1JsonOutput.map(jsonObject).compactMap { object -> [String: Any]? in
            guard object["type"] as? String == "match" else { return nil }
            return object["data"] as? [String: Any]
        }
        let firstLatin1Submatch = (latin1JsonMatches.first?["submatches"] as? [[String: Any]])?.first
        #expect((firstLatin1Submatch?["match"] as? [String: String])?["text"] == "café")
        let onlyMatchingTextOutput = try runExecutableData([
            "-a",
            "-o",
            ".",
            root.path("invalid-utf8.txt"),
        ], fixture: {})
        #expect(onlyMatchingTextOutput == Data([
            0xC3, 0xA9, 0x0A,
            0x66, 0x0A,
            0x6F, 0x0A,
            0x6F, 0x0A,
        ]))
        #expect(try run(["-a", "-bo", "foo", root.path("invalid-utf8.txt")]) == [
            "4:foo",
        ])
        #expect(try run(["-a", "--column", "foo", root.path("invalid-utf8.txt")]) == [
            "2:2:\u{FF}foo",
        ])
        let multilineInvalidOutput = try runExecutableData([
            "-U",
            ".",
            root.path("invalid-utf8.txt"),
        ], fixture: {})
        #expect(multilineInvalidOutput == Data([
            0xC3, 0xA9, 0x0A,
            0xFF, 0x66, 0x6F, 0x6F, 0x0A,
        ]))
        let multilineInvalidOnlyMatchingOutput = try runExecutableData([
            "-U",
            "-o",
            ".",
            root.path("invalid-utf8.txt"),
        ], fixture: {})
        #expect(multilineInvalidOnlyMatchingOutput == Data([
            0xC3, 0xA9, 0x0A,
            0x66, 0x0A,
            0x6F, 0x0A,
            0x6F, 0x0A,
        ]))
        try root.write(Data([0x66, 0x6F, 0x6F, 0xFF, 0x62, 0x61, 0x72, 0x0A]), to: "byte-regex.txt")
        let byteRegexOutput = try runExecutableData([#"(?-u)\xFF"#, root.path("byte-regex.txt")], fixture: {})
        #expect(byteRegexOutput == Data([0x66, 0x6F, 0x6F, 0xFF, 0x62, 0x61, 0x72, 0x0A]))
        let noUnicodeByteRegexOutput = try runExecutableData([
            "--no-unicode",
            #"\xFF"#,
            root.path("byte-regex.txt"),
        ], fixture: {})
        #expect(noUnicodeByteRegexOutput == Data([0x66, 0x6F, 0x6F, 0xFF, 0x62, 0x61, 0x72, 0x0A]))
        let onlyMatchingByteRegexOutput = try runExecutableData(["-o", #"(?-u)."#, root.path("byte-regex.txt")], fixture: {})
        #expect(onlyMatchingByteRegexOutput == Data([
            0x66, 0x0A,
            0x6F, 0x0A,
            0x6F, 0x0A,
            0xFF, 0x0A,
            0x62, 0x0A,
            0x61, 0x0A,
            0x72, 0x0A,
        ]))
        try root.write("é\n", to: "utf8-byte-regex.txt")
        let noUnicodeDotOutput = try runExecutableData([
            "--no-unicode",
            "-o",
            ".",
            root.path("utf8-byte-regex.txt"),
        ], fixture: {})
        #expect(noUnicodeDotOutput == Data([0xC3, 0x0A, 0xA9, 0x0A]))
        let noUnicodeByteOffsetDotOutput = try runExecutableData([
            "--no-unicode",
            "-bo",
            ".",
            root.path("utf8-byte-regex.txt"),
        ], fixture: {})
        #expect(noUnicodeByteOffsetDotOutput == Data([
            0x30, 0x3A, 0xC3, 0x0A,
            0x31, 0x3A, 0xA9, 0x0A,
        ]))
        let byteRegexJsonOutput = try run(["--json", #"(?-u)\xFF"#, root.path("byte-regex.txt")])
        let byteRegexJsonMatch = try byteRegexJsonOutput.map(jsonObject)
            .first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let byteRegexJsonLines = byteRegexJsonMatch?["lines"] as? [String: String]
        let byteRegexJsonSubmatches = byteRegexJsonMatch?["submatches"] as? [[String: Any]]
        #expect(byteRegexJsonLines?["bytes"] == "Zm9v/2Jhcgo=")
        #expect((byteRegexJsonSubmatches?.first?["match"] as? [String: String])?["bytes"] == "/w==")
        #expect(byteRegexJsonSubmatches?.first?["start"] as? Int == 3)
        #expect(byteRegexJsonSubmatches?.first?["end"] as? Int == 4)
        let jsonOutput = try run(["--json", "--encoding", "none", "-a", #"\x00"#, root.path("raw-bytes.txt")])
        let jsonMatch = try jsonOutput.map(jsonObject).first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let jsonLines = jsonMatch?["lines"] as? [String: String]
        let jsonSubmatches = jsonMatch?["submatches"] as? [[String: Any]]
        #expect(jsonLines?["bytes"] == "//4AYg==")
        #expect(jsonSubmatches?.first?["start"] as? Int == 2)
        #expect(jsonSubmatches?.first?["end"] as? Int == 3)
        let encodingNoneUTF8BOMJSONOutput = try run(["--json", "--encoding", "none", "needle", root.path("bom8.txt")])
        let encodingNoneUTF8BOMJSONMatch = try encodingNoneUTF8BOMJSONOutput.map(jsonObject)
            .first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let encodingNoneUTF8BOMJSONSubmatches = encodingNoneUTF8BOMJSONMatch?["submatches"] as? [[String: Any]]
        let utf8BOM = String(UnicodeScalar(0xFEFF)!)
        let encodingNoneUTF8BOMJSONLineText = #""lines":{"text":""# + utf8BOM + #"needle\n"}"#
        #expect(encodingNoneUTF8BOMJSONOutput.contains { $0.contains(encodingNoneUTF8BOMJSONLineText) })
        #expect((encodingNoneUTF8BOMJSONSubmatches?.first?["match"] as? [String: String])?["text"] == "needle")
        #expect(encodingNoneUTF8BOMJSONSubmatches?.first?["start"] as? Int == 3)
        #expect(encodingNoneUTF8BOMJSONSubmatches?.first?["end"] as? Int == 9)
        let encodingNoneInvalidDotJSONOutput = try run(["--json", "--encoding", "none", ".", root.path("invalid-utf8.txt")])
        let encodingNoneInvalidDotJSONMatches = try encodingNoneInvalidDotJSONOutput.map(jsonObject)
            .compactMap { object -> [String: Any]? in
                guard object["type"] as? String == "match" else { return nil }
                return object["data"] as? [String: Any]
            }
        let encodingNoneInvalidDotFirstSubmatches = encodingNoneInvalidDotJSONMatches.first?["submatches"] as? [[String: Any]]
        #expect((encodingNoneInvalidDotFirstSubmatches?.first?["match"] as? [String: String])?["text"] == "é")
        let automaticJsonOutput = try run(["--json", "-a", "foo", root.path("invalid-utf8.txt")])
        let automaticJsonMatch = try automaticJsonOutput.map(jsonObject)
            .first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let automaticJsonLines = automaticJsonMatch?["lines"] as? [String: String]
        let automaticJsonSubmatches = automaticJsonMatch?["submatches"] as? [[String: Any]]
        #expect(automaticJsonLines?["bytes"] == "/2Zvbwo=")
        #expect(automaticJsonSubmatches?.first?["start"] as? Int == 1)
        #expect(automaticJsonSubmatches?.first?["end"] as? Int == 4)
        let automaticBinaryJsonOutput = try run(["--json", "foo", root.path("invalid-utf8.txt")])
        let automaticBinaryJsonMatch = try automaticBinaryJsonOutput.map(jsonObject)
            .first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let automaticBinaryJsonLines = automaticBinaryJsonMatch?["lines"] as? [String: String]
        let automaticBinaryJsonSubmatches = automaticBinaryJsonMatch?["submatches"] as? [[String: Any]]
        #expect(automaticBinaryJsonLines?["bytes"] == "/2Zvbwo=")
        #expect(automaticBinaryJsonSubmatches?.first?["start"] as? Int == 1)
        #expect(automaticBinaryJsonSubmatches?.first?["end"] as? Int == 4)
        #expect(try run(["-n", "-Esjis", "Шерлок Холмс", root.path("sjis.txt")]) == ["1:Шерлок Холмс"])
        #expect(try run(["-n", "-Eeuc-jp", "Шерлок Холмс", root.path("eucjp.txt")]) == ["1:Шерлок Холмс"])

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--encoding", "nope", "needle", root.path("bom8.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: error parsing flag --encoding: grep config error: unknown encoding: nope"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-Enope", "needle", root.path("bom8.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: error parsing flag -E: grep config error: unknown encoding: nope"])
    }

    @Test("limits traversal depth")
    func limitsTraversalDepth() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "root.txt")
        try root.write("needle\n", to: "sub/one.txt")
        try root.write("needle\n", to: "sub/deeper/two.txt")

        #expect(try runAllowingNoMatch(["--max-depth", "0", "needle", root.url.path]) == [])
        #expect(pathBasenames(try run(["--max-depth", "1", "needle", root.url.path])) == ["root.txt"])
        #expect(Set(pathBasenames(try run(["-d2", "needle", root.url.path]))) == Set(["root.txt", "one.txt"]))
        #expect(Set(pathBasenames(try run(["--maxdepth", "2", "needle", root.url.path]))) == Set(["root.txt", "one.txt"]))
        #expect(Set(pathBasenames(try run(["--maxdepth=2", "needle", root.url.path]))) == Set(["root.txt", "one.txt"]))

        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--maxdepth", "nope", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: error parsing flag --maxdepth: value is not a valid number: invalid digit found in string"])
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

        #expect(pathBasenames(try run(["--threads", "1", "needle", root.path("a.txt"), root.path("b.txt")])) == ["a.txt", "b.txt"])
        #expect(pathBasenames(try run(["--files", root.path("a.txt"), root.path("b.txt")])) == ["b.txt", "a.txt"])
        #expect(pathBasenames(try run(["--sortr", "path", "--files", root.path("a.txt"), root.path("b.txt")])) == ["b.txt", "a.txt"])
        #expect(pathBasenames(try run(["--sort", "path", "needle", root.url.path])) == ["a.txt", "b.txt"])
        #expect(pathBasenames(try run(["--sortr", "path", "needle", root.url.path])) == ["b.txt", "a.txt"])
        #expect(pathBasenames(try run(["--sort", "modified", "needle", root.url.path])) == ["b.txt", "a.txt"])
        #expect(pathBasenames(try run(["--sort", "path", "needle", root.path("b.txt"), root.path("a.txt")])) == ["b.txt", "a.txt"])
        #expect(pathBasenames(try run(["--sortr", "path", "needle", root.path("a.txt"), root.path("b.txt")])) == ["b.txt", "a.txt"])
        #expect(pathBasenames(try run(["--sort", "modified", "needle", root.path("a.txt"), root.path("b.txt")])) == ["b.txt", "a.txt"])
        #expect(pathBasenames(try run(["--sort-files", "--files", root.url.path])) == ["a.txt", "b.txt"])

        let componentRoot = try TemporaryDirectory()
        try componentRoot.createDirectory("a")
        try componentRoot.write("needle\n", to: "a/c")
        try componentRoot.write("needle\n", to: "a-b")
        #expect(try run(["--sort", "path", "needle", componentRoot.url.path]) == [
            "\(componentRoot.path("a/c")):needle",
            "\(componentRoot.path("a-b")):needle",
        ])
        #expect(try run(["--sort-files", "--files", componentRoot.url.path]) == [
            componentRoot.path("a/c"),
            componentRoot.path("a-b"),
        ])
        #expect(try run(["--sortr", "path", "--files", componentRoot.url.path]) == [
            componentRoot.path("a-b"),
            componentRoot.path("a/c"),
        ])

        let traversalRoot = try TemporaryDirectory()
        try traversalRoot.createDirectory("a")
        try traversalRoot.createDirectory("b")
        try traversalRoot.write("needle\n", to: "b/two.txt")
        try traversalRoot.write("needle\n", to: "a/one.txt")
        try traversalRoot.write("needle\n", to: "A.txt")
        #expect(pathBasenames(try run(["needle", traversalRoot.url.path])) == ["two.txt", "A.txt", "one.txt"])
        #expect(pathBasenames(try run(["--threads", "0", "needle", traversalRoot.url.path])) == ["two.txt", "A.txt", "one.txt"])
        #expect(pathBasenames(try run(["--threads", "1", "needle", traversalRoot.url.path])) == ["one.txt", "A.txt", "two.txt"])
        #expect(pathBasenames(try run(["--threads", "1", "--sort", "none", "needle", traversalRoot.url.path])) == ["one.txt", "A.txt", "two.txt"])
        #expect(pathBasenames(try run(["--sort", "path", "needle", traversalRoot.url.path])) == ["A.txt", "one.txt", "two.txt"])
        #expect(pathBasenames(try run([
            "--threads",
            "1",
            "--sort",
            "path",
            "needle",
            traversalRoot.path("b/two.txt"),
            traversalRoot.path("a/one.txt"),
        ])) == ["two.txt", "one.txt"])

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--sort", "bogus", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: error parsing flag --sort: choice 'bogus' is unrecognized"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--sortr", "bogus", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: error parsing flag --sortr: choice 'bogus' is unrecognized"])
    }

    @Test("prints aggregate stats")
    func printsAggregateStats() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\nneedle two\nnope\n", to: "stats.txt")
        try root.write("no match\n", to: "other.txt")

        let output = try run(["--stats", "needle", root.path("stats.txt")])
        #expect(output.contains("2 matches"))
        #expect(output.contains("2 matched lines"))
        #expect(output.contains("1 files contained matches"))
        #expect(output.contains("1 files searched"))
        #expect(output.contains("23 bytes searched"))
        #expect(output.contains("18 bytes printed"))

        try root.write("foo1\nfoo2\nfoo3\nfoo4\nfoo5\n", to: "max-count-stats.txt")
        let limitedOutput = try run(["--stats", "-m2", "foo", root.path("max-count-stats.txt")])
        #expect(limitedOutput.contains("2 matches"))
        #expect(limitedOutput.contains("10 bytes searched"))

        let contextRoot = try TemporaryDirectory()
        try contextRoot.write("pre\nneedle one\nctx\nneedle two\npost\n", to: "max-context-stats.txt")
        let limitedContextOutput = try run(["--stats", "-m1", "-A2", "needle", contextRoot.path("max-context-stats.txt")])
        #expect(limitedContextOutput.contains("2 matches"))
        #expect(limitedContextOutput.contains("2 matched lines"))
        #expect(limitedContextOutput.contains("30 bytes searched"))

        let passthruOutput = try run(["--stats", "-m1", "--passthru", "needle", contextRoot.path("max-context-stats.txt")])
        #expect(passthruOutput.contains("1 matches"))
        #expect(passthruOutput.contains("1 matched lines"))
        #expect(passthruOutput.contains("35 bytes searched"))

        let countOutput = try run(["--sort", "path", "--stats", "--count", "needle", root.url.path])
        #expect(countOutput.contains("\(root.path("stats.txt")):2"))
        #expect(countOutput.contains("2 matches"))
        #expect(countOutput.contains("2 matched lines"))
        #expect(countOutput.contains("1 files contained matches"))
        #expect(countOutput.contains("3 files searched"))
        #expect(countOutput.contains("0 bytes printed"))

        let countMatchesOutput = try run(["--sort", "path", "--stats", "--count-matches", "needle", root.url.path])
        #expect(countMatchesOutput.contains("\(root.path("stats.txt")):2"))
        #expect(countMatchesOutput.contains("2 matches"))
        #expect(countMatchesOutput.contains("0 bytes printed"))

        let filesWithMatchesOutput = try run(["--sort", "path", "--stats", "--files-with-matches", "needle", root.url.path])
        #expect(filesWithMatchesOutput.contains(root.path("stats.txt")))
        #expect(filesWithMatchesOutput.contains("2 matches"))
        #expect(filesWithMatchesOutput.contains("0 bytes printed"))

        let filesWithoutMatchOutput = try run(["--sort", "path", "--stats", "--files-without-match", "needle", root.url.path])
        #expect(filesWithoutMatchOutput.contains(root.path("max-count-stats.txt")))
        #expect(filesWithoutMatchOutput.contains(root.path("other.txt")))
        #expect(filesWithoutMatchOutput.contains("2 matches"))
        #expect(filesWithoutMatchOutput.contains("0 bytes printed"))

        let invertedOutput = try run(["--stats", "-v", "needle", root.path("stats.txt")])
        #expect(invertedOutput.contains("0 matches"))
        #expect(invertedOutput.contains("1 matched lines"))
    }

    @Test("loads arguments from RIPGREP_CONFIG_PATH")
    func loadsArgumentsFromRipgrepConfigPath() throws {
        let root = try TemporaryDirectory()
        try root.write("Needle\n", to: "a.txt")
        try root.write("Needle\n", to: "a.log")
        try root.write("# comment\n--ignore-case\n--line-number\n--glob\n*.txt\n", to: "ripgreprc")
        let environment = ["RIPGREP_CONFIG_PATH": root.path("ripgreprc")]

        #expect(try run(["needle", root.url.path], environment: environment) == [
            "\(root.path("a.txt")):1:Needle",
        ])
        #expect(try run(["--no-config", "needle", root.url.path], environment: environment) == [])
        #expect(try run(["--case-sensitive", "needle", root.url.path], environment: environment) == [])

        var output: [String] = []
        var errors: [String] = []
        let debugConfigExitCode = RipgrepCLI.run(
            arguments: ["--debug", "needle", root.path("a.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            environment: environment
        )
        #expect(debugConfigExitCode == 0)
        #expect(output == ["1:Needle"])
        #expect(errors.contains(
            "rg: DEBUG|rg::flags::config|crates/core/flags/config.rs:47: \(root.path("ripgreprc")): arguments loaded from config file: [\"--ignore-case\", \"--line-number\", \"--glob\", \"*.txt\"]"
        ))

        try root.write("--replace\n\"X Y\"\n", to: "ripgreprc")
        #expect(try run(["Needle", root.path("a.txt")], environment: environment) == [
            "\"X Y\"",
        ])

        try root.write("--ignore-case --line-number\n", to: "ripgreprc")
        output = []
        errors = []
        let sameLineConfigExitCode = RipgrepCLI.run(
            arguments: ["needle", root.path("a.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            environment: environment
        )
        #expect(sameLineConfigExitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == [
            "rg: unrecognized flag --ignore-case --line-number\n\nsimilar flags that are available: --no-line-number",
        ])

        output = []
        errors = []
        let missingConfig = root.path("missing-ripgreprc")
        let missingExitCode = RipgrepCLI.run(
            arguments: ["Needle", root.path("a.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            environment: ["RIPGREP_CONFIG_PATH": missingConfig]
        )
        #expect(missingExitCode == 0)
        #expect(output == ["Needle"])
        #expect(errors == [
            "rg: failed to read the file specified in RIPGREP_CONFIG_PATH: \(missingConfig): No such file or directory (os error 2)",
        ])

        output = []
        errors = []
        let missingEnvironmentExitCode = RipgrepCLI.run(
            arguments: ["--debug", "Needle", root.path("a.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            environment: [:]
        )
        #expect(missingEnvironmentExitCode == 0)
        #expect(output == ["Needle"])
        #expect(errors.contains(
            "rg: DEBUG|rg::flags::config|crates/core/flags/config.rs:19: RIPGREP_CONFIG_PATH environment variable is not set, therefore not reading any config file"
        ))
        #expect(errors.contains(
            "rg: DEBUG|rg::flags::parse|crates/core/flags/parse.rs:97: no extra arguments found from configuration file"
        ))

        output = []
        errors = []
        let noConfigExitCode = RipgrepCLI.run(
            arguments: ["--debug", "--no-config", "Needle", root.path("a.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            environment: ["RIPGREP_CONFIG_PATH": missingConfig]
        )
        #expect(noConfigExitCode == 0)
        #expect(output == ["Needle"])
        #expect(errors.contains(
            "rg: DEBUG|rg::flags::parse|crates/core/flags/parse.rs:89: not reading config files because --no-config is present"
        ))
    }

    @Test("quiet mode still prints stats")
    func quietModeStillPrintsStats() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "quiet-stats.txt")

        var output: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["-q", "--stats", "needle", root.path("quiet-stats.txt")],
            stdout: { output.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.contains("1 matches"))
        #expect(output.contains("1 files searched"))
        #expect(output.contains("0 bytes printed"))

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["-q", "--stats", "absent", root.path("quiet-stats.txt")],
            stdout: { output.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.contains("0 matches"))
        #expect(output.contains("1 files searched"))
        #expect(output.contains("0 bytes printed"))
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
        try root.write("1\n2\n3\n4\n5\n6\n7\n8\n9\n", to: "context-override.txt")
        #expect(try run(["-C1", "-A2", "5", root.path("context-override.txt")]) == [
            "4",
            "5",
            "6",
            "7",
        ])
        #expect(try run(["-A2", "-C1", "5", root.path("context-override.txt")]) == [
            "4",
            "5",
            "6",
            "7",
        ])
        #expect(try run(["-n", "-A1", "-e", "match", "-e", "other", root.path("context.txt")]) == [
            "3:match",
            "4-four",
            "--",
            "6:other",
            "7-seven",
        ])

        let multiRoot = try TemporaryDirectory()
        try multiRoot.write("needle\nafter\n", to: "a.txt")
        try multiRoot.write("needle\nafter\n", to: "b.txt")
        try multiRoot.write("", to: "empty.txt")
        #expect(try run(["--sort", "path", "-n", "-A1", "needle", multiRoot.url.path]) == [
            "\(multiRoot.path("a.txt")):1:needle",
            "\(multiRoot.path("a.txt"))-2-after",
            "--",
            "\(multiRoot.path("b.txt")):1:needle",
            "\(multiRoot.path("b.txt"))-2-after",
        ])
        #expect(try run([
            "--sort",
            "path",
            "-n",
            "-A1",
            "--no-context-separator",
            "needle",
            multiRoot.url.path,
        ]) == [
            "\(multiRoot.path("a.txt")):1:needle",
            "\(multiRoot.path("a.txt"))-2-after",
            "\(multiRoot.path("b.txt")):1:needle",
            "\(multiRoot.path("b.txt"))-2-after",
        ])
        #expect(try run(["--sort", "path", "--passthru", "needle", multiRoot.url.path]) == [
            "\(multiRoot.path("a.txt")):needle",
            "\(multiRoot.path("a.txt"))-after",
            "\(multiRoot.path("b.txt")):needle",
            "\(multiRoot.path("b.txt"))-after",
        ])
        let crlfContextOutput = try runExecutableData([
            "--sort",
            "path",
            "--crlf",
            "-A1",
            "needle",
            multiRoot.url.path,
        ]) {}
        #expect(crlfContextOutput == Data((
            "\(multiRoot.path("a.txt")):needle\n" +
            "\(multiRoot.path("a.txt"))-after\n" +
            "--\r\n" +
            "\(multiRoot.path("b.txt")):needle\n" +
            "\(multiRoot.path("b.txt"))-after\n"
        ).utf8))
        let nullContextRoot = try TemporaryDirectory()
        try nullContextRoot.write(Data("needle\0after\0".utf8), to: "a.txt")
        try nullContextRoot.write(Data("needle\0after\0".utf8), to: "b.txt")
        let nullDataContextOutput = try runExecutableData([
            "--sort",
            "path",
            "--null-data",
            "-A1",
            "needle",
            nullContextRoot.url.path,
        ]) {}
        #expect(nullDataContextOutput == Data((
            "\(nullContextRoot.path("a.txt")):needle\0" +
            "\(nullContextRoot.path("a.txt"))-after\0" +
            "--\0" +
            "\(nullContextRoot.path("b.txt")):needle\0" +
            "\(nullContextRoot.path("b.txt"))-after\0"
        ).utf8))
        #expect(try runAllowingNoMatch(["^", multiRoot.path("empty.txt")]) == [])
        let emptyPassthruJSON = runWithExitCode(
            ["--json", "--passthru", "needle", multiRoot.path("empty.txt")],
            expectedExitCode: 1
        )
        let emptyPassthruMessages = try emptyPassthruJSON.map(jsonObject)
        #expect(emptyPassthruMessages.map { $0["type"] as? String } == ["summary"])
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
            "--context-separator",
            #"CTX\x7F"#,
            "-e",
            "match",
            "-e",
            "other",
            root.path("context.txt"),
        ]) == [
            "3:match",
            "4-four",
            "CTX\u{7F}",
            "6:other",
            "7-seven",
        ])
        #expect(try run([
            "-n",
            "-A1",
            "--context-separator=",
            "-e",
            "match",
            "-e",
            "other",
            root.path("context.txt"),
        ]) == [
            "3:match",
            "4-four",
            "",
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
        #expect(try run([
            "-n",
            "-A1",
            "--no-context-separator",
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
            "--context-separator",
            "SEP",
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
        try root.write("pre\nneedle one\nctx\nneedle two\npost\n", to: "max-context.txt")
        #expect(try run(["-n", "-m1", "-A2", "-B1", "needle", root.path("max-context.txt")]) == [
            "1-pre",
            "2:needle one",
            "3-ctx",
            "4:needle two",
        ])
        #expect(try run(["-n", "-m1", "-o", "-A2", "needle", root.path("max-context.txt")]) == [
            "2:needle",
            "3-ctx",
            "4:needle",
        ])
        try root.write("foo\nbar\nxxx\nfoo bar\n", to: "vimgrep-multiline-passthru.txt")
        #expect(try run([
            "--vimgrep",
            "-U",
            "-m1",
            "--passthru",
            "foo\nbar",
            root.path("vimgrep-multiline-passthru.txt"),
        ]) == [
            "\(root.path("vimgrep-multiline-passthru.txt")):1:1:foo",
            "\(root.path("vimgrep-multiline-passthru.txt"))-3-xxx",
            "\(root.path("vimgrep-multiline-passthru.txt"))-4-foo bar",
        ])
        #expect(try run([
            "-U",
            "--replace",
            "X",
            "--passthru",
            "foo\nbar",
            root.path("vimgrep-multiline-passthru.txt"),
        ]) == [
            "X",
            "xxx",
            "foo bar",
        ])
        try root.write("pre\nfoo\nbar\npost\n", to: "replacement-multiline-context.txt")
        #expect(try run([
            "-H",
            "-U",
            "--replace",
            "<$0>",
            "-A1",
            "foo\nbar",
            root.path("replacement-multiline-context.txt"),
        ]) == [
            "\(root.path("replacement-multiline-context.txt")):<foo",
            "\(root.path("replacement-multiline-context.txt")):bar>",
            "\(root.path("replacement-multiline-context.txt"))-post",
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
        #expect(try run(["-n", "--passthrough", "match", root.path("context.txt")]) == [
            "1-one",
            "2-two",
            "3:match",
            "4-four",
            "5-five",
            "6-other",
            "7-seven",
        ])

        #expect(try run(["-n", "-o", "-C1", "match", root.path("context.txt")]) == [
            "2-two",
            "3:match",
            "4-four",
        ])
        #expect(try run(["-n", "--passthru", "-o", "match", root.path("context.txt")]) == [
            "1-one",
            "2-two",
            "3:match",
            "4-four",
            "5-five",
            "6-other",
            "7-seven",
        ])

        try root.write("alpha\nfoo\nbar\nfoo bar\nFOO\n", to: "invert-context.txt")
        #expect(try run(["-v", "-o", "-n", "-A1", "foo", root.path("invert-context.txt")]) == [
            "1:alpha",
            "2-foo",
            "3:bar",
            "4-foo",
            "5:FOO",
        ])
        #expect(try run(["-v", "-o", "-n", "--column", "-A1", "foo", root.path("invert-context.txt")]) == [
            "1:alpha",
            "2-1-foo",
            "3:bar",
            "4-1-foo",
            "5:FOO",
        ])

        try root.write("before\ncat cat\nafter\n", to: "only-context.txt")
        #expect(try run(["-n", "-o", "-C1", "cat", root.path("only-context.txt")]) == [
            "1-before",
            "2:cat",
            "2:cat",
            "3-after",
        ])
    }

    @Test("stops after first nonmatch following matches")
    func stopsAfterFirstNonmatchFollowingMatches() throws {
        let root = try TemporaryDirectory()
        try root.write("hay\nmatch1\nmatch2\nhay\nmatch3\n", to: "stop.txt")

        #expect(try run(["-n", "--stop-on-nonmatch", "match", root.path("stop.txt")]) == [
            "2:match1",
            "3:match2",
        ])
        #expect(try run(["-n", "--stop-on-nonmatch", "-A1", "match", root.path("stop.txt")]) == [
            "2:match1",
            "3:match2",
            "4-hay",
        ])
        #expect(try run(["-n", "--stop-on-nonmatch", "--passthru", "match", root.path("stop.txt")]) == [
            "1-hay",
            "2:match1",
            "3:match2",
            "4-hay",
        ])
        #expect(try run(["-n", "--stop-on-nonmatch", "-U", "match", root.path("stop.txt")]) == [
            "2:match1",
            "3:match2",
            "5:match3",
        ])
        #expect(try run(["-n", "-U", "--stop-on-nonmatch", "match", root.path("stop.txt")]) == [
            "2:match1",
            "3:match2",
        ])

        try root.write("alpha\nneedle\nbeta\nneedle\ngamma\n", to: "stop-invert.txt")
        #expect(try run(["--stop-on-nonmatch", "-v", "needle", root.path("stop-invert.txt")]) == [
            "alpha",
            "beta",
        ])
        try root.write("line1\nline2\nline3\nline4\nline5\n", to: "stop-invert-positive-run.txt")
        #expect(try run(["--stop-on-nonmatch", "-v", "[235]", root.path("stop-invert-positive-run.txt")]) == [
            "line1",
        ])
        try root.write("line2\nalpha\nbeta\nline3\n", to: "stop-invert-leading-positive.txt")
        #expect(try run(["--stop-on-nonmatch", "-v", "[235]", root.path("stop-invert-leading-positive.txt")]) == [
            "alpha",
            "beta",
        ])
    }

    @Test("searches preprocessor output")
    func searchesPreprocessorOutput() throws {
        let root = try TemporaryDirectory()
        try root.write("raw\n", to: "doc.md")
        try root.write("needle\n", to: "plain.txt")
        let script = root.path("pre.sh")
        try root.write("""
        #!/bin/sh
        printf 'converted needle from %s\\n' "$(basename "$1")"
        """, to: "pre.sh")
        try root.makeExecutable("pre.sh")

        #expect(try run(["--pre", script, "needle", root.path("doc.md")]) == [
            "converted needle from doc.md",
        ])
        let originalDirectory = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalDirectory) }
        #expect(FileManager.default.changeCurrentDirectoryPath(root.url.path))
        #expect(try run(["--pre", script, "needle", "doc.md"]) == [
            "converted needle from doc.md",
        ])
        let jsonOutput = try run(["--json", "--pre", script, "needle", "doc.md"])
        let jsonMessages = try jsonOutput.map(jsonObject)
        let endMessage = jsonMessages.first { $0["type"] as? String == "end" }
        let endData = endMessage?["data"] as? [String: Any]
        let stats = endData?["stats"] as? [String: Any]
        #expect(stats?["bytes_searched"] as? Int == "converted needle from doc.md\n".utf8.count)

        #expect(Set(pathBasenames(try run([
            "--pre",
            script,
            "--pre-glob",
            "*.md",
            "needle",
            root.url.path,
        ]))) == Set(["doc.md", "plain.txt", "pre.sh"]))
        try root.createDirectory("sub")
        try root.write("plain needle\n", to: "sub/doc.md")
        #expect(try run([
            "--sort",
            "path",
            "--pre",
            script,
            "--pre-glob",
            "sub/**",
            "needle",
            ".",
        ]) == [
            "./plain.txt:needle",
            #"./pre.sh:printf 'converted needle from %s\n' "$(basename "$1")""#,
            "./sub/doc.md:converted needle from doc.md",
        ])
        #expect(try run([
            "--sort",
            "path",
            "--pre",
            script,
            "--pre-glob",
            "sub/**",
            "needle",
            "sub",
        ]) == [
            "sub/doc.md:converted needle from doc.md",
        ])
        #expect(try run([
            "--sort",
            "path",
            "--pre",
            script,
            "--pre-glob",
            "sub/**",
            "needle",
            root.url.path,
        ]) == [
            "\(root.path("plain.txt")):needle",
            #"\#(root.path("pre.sh")):printf 'converted needle from %s\n' "$(basename "$1")""#,
            "\(root.path("sub/doc.md")):plain needle",
        ])
        try root.write("""
        #!/bin/sh
        printf 'needle\\n\\0tail needle\\n'
        """, to: "pre-binary.sh")
        try root.makeExecutable("pre-binary.sh")
        #expect(try run(["--pre", root.path("pre-binary.sh"), "needle", root.path("doc.md")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        try root.write("""
        #!/bin/sh
        printf 'preprocessed match before binary data padding line\\n'
        cat "$1"
        """, to: "pre-binary-preface.sh")
        try root.makeExecutable("pre-binary-preface.sh")
        try root.write(Data("needle utf16\n".utf16LittleEndianBytes), to: "utf16le.bin")
        #expect(try run(["--pre", root.path("pre-binary-preface.sh"), ".", root.path("utf16le.bin")]) == [
            "preprocessed match before binary data padding line",
            #"binary file matches (found "\0" byte around offset 52)"#,
        ])
        #expect(try run(["--pre", root.path("pre-binary-preface.sh"), "--count", ".", root.path("utf16le.bin")]) == [
            "13",
        ])
        let preBinaryJSONOutput = try run(["--json", "--pre", root.path("pre-binary-preface.sh"), ".", root.path("utf16le.bin")])
        let preBinaryJSONMessages = try preBinaryJSONOutput.map(jsonObject)
        let preBinaryJSONMatches = preBinaryJSONMessages.filter { $0["type"] as? String == "match" }
        #expect(preBinaryJSONMatches.count == 13)
        #expect(try run(["--pre", script, "--pre", "", "needle", root.path("plain.txt")]) == [
            "needle",
        ])
        #expect(try run(["--pre", script, "--no-pre", "needle", root.path("plain.txt")]) == [
            "needle",
        ])

        try root.write("""
        #!/bin/sh
        echo boom >&2
        exit 7
        """, to: "fail.sh")
        try root.makeExecutable("fail.sh")
        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--pre", root.path("fail.sh"), "needle", root.path("doc.md")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        let expectedPreprocessorError = "rg: \(root.path("doc.md")): preprocessor command failed: " +
            "'\"\(root.path("fail.sh"))\" \"\(root.path("doc.md"))\"': " +
            """

            -------------------------------------------------------------------------------
            boom
            -------------------------------------------------------------------------------
            """
        #expect(errors == [
            expectedPreprocessorError
        ])

        output = []
        errors = []
        let missingExitCode = RipgrepCLI.run(
            arguments: ["--pre", root.path("missing-preprocessor"), "needle", root.path("doc.md")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(missingExitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == [
            "rg: \(root.path("doc.md")): preprocessor command could not start: " +
                "'\"\(root.path("missing-preprocessor"))\" \"\(root.path("doc.md"))\"': " +
                "No such file or directory (os error 2)"
        ])
    }

    @Test("searches gzip compressed files")
    func searchesGzipCompressedFiles() throws {
        let root = try TemporaryDirectory()
        try root.writeGzip("needle in gzip\n", to: "compressed.txt.gz")
        try root.write("needle in plain\n", to: "plain.txt")
        let script = root.path("pre.sh")
        try root.write("""
        #!/bin/sh
        printf 'preprocessed needle\\n'
        """, to: "pre.sh")
        try root.makeExecutable("pre.sh")

        #expect(try runAllowingNoMatch(["needle", root.path("compressed.txt.gz")]) == [])
        #expect(try run(["-z", "needle", root.path("compressed.txt.gz")]) == [
            "needle in gzip",
        ])
        #expect(Set(pathBasenames(try run([
            "--search-zip",
            "needle",
            root.url.path,
        ]))) == Set(["compressed.txt.gz", "plain.txt", "pre.sh"]))
        #expect(try runAllowingNoMatch([
            "-z",
            "--no-search-zip",
            "needle",
            root.path("compressed.txt.gz"),
        ]) == [])
        #expect(try run([
            "--pre",
            script,
            "--search-zip",
            "needle",
            root.path("compressed.txt.gz"),
        ]) == ["needle in gzip"])
        #expect(try run([
            "--search-zip",
            "--pre",
            script,
            "needle",
            root.path("compressed.txt.gz"),
        ]) == ["preprocessed needle"])

        let jsonOutput = try run([
            "--json",
            "--search-zip",
            "needle",
            root.path("compressed.txt.gz"),
        ])
        let jsonMessages = try jsonOutput.map(jsonObject)
        let endMessage = jsonMessages.first { $0["type"] as? String == "end" }
        let endData = endMessage?["data"] as? [String: Any]
        let stats = endData?["stats"] as? [String: Any]
        #expect(stats?["bytes_searched"] as? Int == "needle in gzip\n".utf8.count)
        let compressedBinary = Data("prefix match\n".utf8) + Data("needle utf16\n".utf16LittleEndianBytes)
        try root.writeGzip(compressedBinary, to: "binary.txt.gz")
        #expect(try run(["--search-zip", ".", root.path("binary.txt.gz")]) == [
            #"binary file matches (found "\0" byte around offset 14)"#,
        ])
        #expect(try run(["--search-zip", "--count", ".", root.path("binary.txt.gz")]) == [
            "13",
        ])
        #expect(try run(["--search-zip", "--count-matches", ".", root.path("binary.txt.gz")]) == [
            "24",
        ])
        try root.writeGzip(compressedBinary, to: "binary-dir/binary.txt.gz")
        #expect(try runAllowingNoMatch(["--search-zip", "--count", ".", root.path("binary-dir")]) == [])
        let compressedBinaryJSONOutput = try run([
            "--json",
            "--search-zip",
            ".",
            root.path("binary.txt.gz"),
        ])
        let compressedBinaryJSONMessages = try compressedBinaryJSONOutput.map(jsonObject)
        let compressedBinaryJSONMatches = compressedBinaryJSONMessages.filter { $0["type"] as? String == "match" }
        let compressedBinaryJSONEnd = compressedBinaryJSONMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let compressedBinaryJSONStats = compressedBinaryJSONEnd?["stats"] as? [String: Any]
        #expect(compressedBinaryJSONMatches.count == 13)
        #expect(compressedBinaryJSONStats?["matched_lines"] as? Int == 13)
        #expect(compressedBinaryJSONStats?["matches"] as? Int == 24)

        try root.write("not gzip\nneedle\n", to: "bad.gz")
        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--search-zip", "needle", root.path("bad.gz")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: \(root.path("bad.gz")): " + """

        -------------------------------------------------------------------------------
        gzip: \(root.path("bad.gz")): not in gzip format
        -------------------------------------------------------------------------------
        """])
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
        try root.write("foo bar foo\nqux\nfoo\n", to: "line-replace.txt")
        #expect(try run(["-n", "--replace", "X", "foo", root.path("line-replace.txt")]) == [
            "1:X bar X",
            "3:X",
        ])
        try root.write("Foo bar fOo\nqux\nfoo\n", to: "line-replace-ignore-case.txt")
        #expect(try run(["-n", "-i", "--replace", "X", "foo", root.path("line-replace-ignore-case.txt")]) == [
            "1:X bar X",
            "3:X",
        ])
        #expect(try run(["--column", "--replace", "X", "foo", root.path("line-replace.txt")]) == [
            "1:1:X bar X",
            "3:1:X",
        ])
        #expect(try run(["--byte-offset", "--replace", "X", "foo", root.path("line-replace.txt")]) == [
            "0:X bar X",
            "16:X",
        ])
        #expect(try run(["--column", "--byte-offset", "--replace", "X", "foo", root.path("line-replace.txt")]) == [
            "1:1:0:X bar X",
            "3:1:16:X",
        ])
        #expect(try run(["-o", "--replace", "X", "foo", root.path("line-replace.txt")]) == [
            "X",
            "X",
            "X",
        ])
        #expect(try run(["-n", "-o", "--column", "--byte-offset", "--replace", "X", "foo", root.path("line-replace.txt")]) == [
            "1:1:0:X",
            "1:7:6:X",
            "3:1:16:X",
        ])
        #expect(try run(["-o", "-i", "--replace", "X", "foo", root.path("line-replace-ignore-case.txt")]) == [
            "X",
            "X",
            "X",
        ])
        #expect(try run(["-m1", "--replace", "X", "foo", root.path("line-replace.txt")]) == [
            "X bar X",
        ])
        #expect(try run(["-m1", "-o", "--replace", "X", "foo", root.path("line-replace.txt")]) == [
            "X",
            "X",
        ])
        #expect(try run(["-m1", "-n", "-o", "--column", "--byte-offset", "--replace", "X", "foo", root.path("line-replace.txt")]) == [
            "1:1:0:X",
            "1:7:6:X",
        ])
        try root.write("foo bar foo\nfoo\nbar foo\n", to: "bounded-only.txt")
        let boundedOnlyMatchingOutput = try runExecutableData([
            "-o",
            "-m1",
            "foo",
            root.path("bounded-only.txt"),
        ]) {}
        #expect(boundedOnlyMatchingOutput == Data("foo\nfoo\n".utf8))
        let boundedLineNumberOnlyMatchingOutput = try runExecutableData([
            "-n",
            "-o",
            "-m2",
            "foo",
            root.path("bounded-only.txt"),
        ]) {}
        #expect(boundedLineNumberOnlyMatchingOutput == Data("1:foo\n1:foo\n2:foo\n".utf8))
        let boundedIgnoreCaseOnlyMatchingOutput = try runExecutableData([
            "-i",
            "-o",
            "-m1",
            "FOO",
            root.path("bounded-only.txt"),
        ]) {}
        #expect(boundedIgnoreCaseOnlyMatchingOutput == Data("foo\nfoo\n".utf8))
        try root.write("foo food FOO\nbar foo\n", to: "bounded-word-only.txt")
        let wordOnlyMatchingOutput = try runExecutableData([
            "-w",
            "-o",
            "foo",
            root.path("bounded-word-only.txt"),
        ]) {}
        #expect(wordOnlyMatchingOutput == Data("foo\nfoo\n".utf8))
        let boundedWordOnlyMatchingOutput = try runExecutableData([
            "-w",
            "-n",
            "-o",
            "-m1",
            "foo",
            root.path("bounded-word-only.txt"),
        ]) {}
        #expect(boundedWordOnlyMatchingOutput == Data("1:foo\n".utf8))
        let boundedIgnoreCaseWordOnlyMatchingOutput = try runExecutableData([
            "-w",
            "-i",
            "-o",
            "-m1",
            "FOO",
            root.path("bounded-word-only.txt"),
        ]) {}
        #expect(boundedIgnoreCaseWordOnlyMatchingOutput == Data("foo\nFOO\n".utf8))
        try root.write("éfoo\nfooé\nfoo\n", to: "unicode-word-only.txt")
        let unicodeAdjacentWordOnlyMatchingOutput = try runExecutableData([
            "-w",
            "-o",
            "foo",
            root.path("unicode-word-only.txt"),
        ]) {}
        #expect(unicodeAdjacentWordOnlyMatchingOutput == Data("foo\n".utf8))
        try root.write("foo_food foo bar food\nquiet foo bar\n", to: "multi-word-only.txt")
        let fieldedMultiOnlyMatchingOutput = try runExecutableData([
            "-n",
            "--column",
            "-b",
            "-o",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(fieldedMultiOnlyMatchingOutput == Data(
            "1:1:0:foo\n1:5:4:foo\n1:10:9:foo\n1:14:13:bar\n1:18:17:foo\n".utf8
        ))
        let vimgrepMultiOnlyMatchingOutput = try runExecutableData([
            "--vimgrep",
            "-o",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(vimgrepMultiOnlyMatchingOutput == Data((
            "\(root.path("multi-word-only.txt")):1:1:foo\n"
                + "\(root.path("multi-word-only.txt")):1:5:foo\n"
                + "\(root.path("multi-word-only.txt")):1:10:foo\n"
                + "\(root.path("multi-word-only.txt")):1:14:bar\n"
                + "\(root.path("multi-word-only.txt")):1:18:foo\n"
        ).utf8))
        let headingVimgrepMultiOnlyMatchingOutput = try runExecutableData([
            "--heading",
            "--vimgrep",
            "-o",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(headingVimgrepMultiOnlyMatchingOutput == vimgrepMultiOnlyMatchingOutput)
        let vimgrepMultiLineOutput = try runExecutableData([
            "--vimgrep",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(vimgrepMultiLineOutput == Data((
            "\(root.path("multi-word-only.txt")):1:1:foo_food foo bar food\n"
                + "\(root.path("multi-word-only.txt")):1:5:foo_food foo bar food\n"
                + "\(root.path("multi-word-only.txt")):1:10:foo_food foo bar food\n"
                + "\(root.path("multi-word-only.txt")):1:14:foo_food foo bar food\n"
                + "\(root.path("multi-word-only.txt")):1:18:foo_food foo bar food\n"
        ).utf8))
        let headingVimgrepMultiLineOutput = try runExecutableData([
            "--heading",
            "--vimgrep",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(headingVimgrepMultiLineOutput == vimgrepMultiLineOutput)
        let vimgrepMultiLineByteOutput = try runExecutableData([
            "--vimgrep",
            "-b",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(vimgrepMultiLineByteOutput == Data((
            "\(root.path("multi-word-only.txt")):1:1:0:foo_food foo bar food\n"
                + "\(root.path("multi-word-only.txt")):1:5:4:foo_food foo bar food\n"
                + "\(root.path("multi-word-only.txt")):1:10:9:foo_food foo bar food\n"
                + "\(root.path("multi-word-only.txt")):1:14:13:foo_food foo bar food\n"
                + "\(root.path("multi-word-only.txt")):1:18:17:foo_food foo bar food\n"
        ).utf8))
        let vimgrepMultiLineNoFilenameOutput = try runExecutableData([
            "--vimgrep",
            "--no-filename",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(vimgrepMultiLineNoFilenameOutput == Data((
            "1:1:foo_food foo bar food\n"
                + "1:5:foo_food foo bar food\n"
                + "1:10:foo_food foo bar food\n"
                + "1:14:foo_food foo bar food\n"
                + "1:18:foo_food foo bar food\n"
        ).utf8))
        let boundedMultiWordOnlyMatchingOutput = try runExecutableData([
            "-w",
            "-n",
            "-o",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(boundedMultiWordOnlyMatchingOutput == Data("1:foo\n1:bar\n".utf8))
        let fieldedMultiWordOnlyMatchingOutput = try runExecutableData([
            "-w",
            "-n",
            "--column",
            "-b",
            "-o",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(fieldedMultiWordOnlyMatchingOutput == Data("1:10:9:foo\n1:14:13:bar\n".utf8))
        let vimgrepMultiWordOnlyMatchingOutput = try runExecutableData([
            "--vimgrep",
            "-w",
            "-o",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(vimgrepMultiWordOnlyMatchingOutput == Data(
            "\(root.path("multi-word-only.txt")):1:10:foo\n\(root.path("multi-word-only.txt")):1:14:bar\n".utf8
        ))
        let vimgrepMultiWordLineOutput = try runExecutableData([
            "--vimgrep",
            "-w",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(vimgrepMultiWordLineOutput == Data((
            "\(root.path("multi-word-only.txt")):1:10:foo_food foo bar food\n"
                + "\(root.path("multi-word-only.txt")):1:14:foo_food foo bar food\n"
        ).utf8))
        let headingVimgrepMultiWordLineOutput = try runExecutableData([
            "--heading",
            "--vimgrep",
            "-w",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(headingVimgrepMultiWordLineOutput == vimgrepMultiWordLineOutput)
        let vimgrepMultiWordLineByteOutput = try runExecutableData([
            "--vimgrep",
            "-w",
            "-b",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(vimgrepMultiWordLineByteOutput == Data((
            "\(root.path("multi-word-only.txt")):1:10:9:foo_food foo bar food\n"
                + "\(root.path("multi-word-only.txt")):1:14:13:foo_food foo bar food\n"
        ).utf8))
        let prefixedMultiWordOnlyMatchingOutput = try runExecutableData([
            "--with-filename",
            "-w",
            "-o",
            "-m1",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(prefixedMultiWordOnlyMatchingOutput == Data(
            "\(root.path("multi-word-only.txt")):foo\n\(root.path("multi-word-only.txt")):bar\n".utf8
        ))
        try root.write("FOO_food Foo bar BAR\nquiet FOO\n", to: "multi-word-ignore-only.txt")
        let boundedIgnoreCaseMultiWordOnlyMatchingOutput = try runExecutableData([
            "-w",
            "-i",
            "-o",
            "-m1",
            "-e",
            "FOO",
            "-e",
            "BAR",
            root.path("multi-word-ignore-only.txt"),
        ]) {}
        #expect(boundedIgnoreCaseMultiWordOnlyMatchingOutput == Data("Foo\nbar\nBAR\n".utf8))
        let vimgrepIgnoreCaseMultiLineOutput = try runExecutableData([
            "--vimgrep",
            "-i",
            "-m1",
            "-e",
            "FOO",
            "-e",
            "BAR",
            root.path("multi-word-ignore-only.txt"),
        ]) {}
        #expect(vimgrepIgnoreCaseMultiLineOutput == Data((
            "\(root.path("multi-word-ignore-only.txt")):1:1:FOO_food Foo bar BAR\n"
                + "\(root.path("multi-word-ignore-only.txt")):1:5:FOO_food Foo bar BAR\n"
                + "\(root.path("multi-word-ignore-only.txt")):1:10:FOO_food Foo bar BAR\n"
                + "\(root.path("multi-word-ignore-only.txt")):1:14:FOO_food Foo bar BAR\n"
                + "\(root.path("multi-word-ignore-only.txt")):1:18:FOO_food Foo bar BAR\n"
        ).utf8))
        let vimgrepIgnoreCaseMultiWordLineOutput = try runExecutableData([
            "--vimgrep",
            "-w",
            "-i",
            "-m1",
            "-e",
            "FOO",
            "-e",
            "BAR",
            root.path("multi-word-ignore-only.txt"),
        ]) {}
        #expect(vimgrepIgnoreCaseMultiWordLineOutput == Data((
            "\(root.path("multi-word-ignore-only.txt")):1:10:FOO_food Foo bar BAR\n"
                + "\(root.path("multi-word-ignore-only.txt")):1:14:FOO_food Foo bar BAR\n"
                + "\(root.path("multi-word-ignore-only.txt")):1:18:FOO_food Foo bar BAR\n"
        ).utf8))
        try root.write("delta bravo delta\nbravo\n", to: "bounded-alternation-only.txt")
        let boundedAlternationOnlyMatchingOutput = try runExecutableData([
            "-n",
            "-o",
            "-m1",
            "bravo|delta",
            root.path("bounded-alternation-only.txt"),
        ]) {}
        #expect(boundedAlternationOnlyMatchingOutput == Data("1:delta\n1:bravo\n1:delta\n".utf8))
        let boundedAlternationVimgrepLineOutput = try runExecutableData([
            "--vimgrep",
            "-m1",
            "bravo|delta",
            root.path("bounded-alternation-only.txt"),
        ]) {}
        #expect(boundedAlternationVimgrepLineOutput == Data((
            "\(root.path("bounded-alternation-only.txt")):1:1:delta bravo delta\n"
                + "\(root.path("bounded-alternation-only.txt")):1:7:delta bravo delta\n"
                + "\(root.path("bounded-alternation-only.txt")):1:13:delta bravo delta\n"
        ).utf8))
        let boundedWordAlternationOnlyMatchingOutput = try runExecutableData([
            "-w",
            "-n",
            "-o",
            "-m1",
            "foo|bar",
            root.path("multi-word-only.txt"),
        ]) {}
        #expect(boundedWordAlternationOnlyMatchingOutput == Data("1:foo\n1:bar\n".utf8))
        try root.write("éfoo\nbaré\nfoo bar\n", to: "multi-unicode-word-only.txt")
        let unicodeAdjacentMultiWordOnlyMatchingOutput = try runExecutableData([
            "-w",
            "-o",
            "-e",
            "foo",
            "-e",
            "bar",
            root.path("multi-unicode-word-only.txt"),
        ]) {}
        #expect(unicodeAdjacentMultiWordOnlyMatchingOutput == Data("foo\nbar\n".utf8))
        try root.write("Watson Sherlock\nSherlock Watson\n", to: "multi-literal-replace.txt")
        #expect(try run(["--replace", "X", "Sherlock|Watson", root.path("multi-literal-replace.txt")]) == [
            "X X",
            "X X",
        ])
        #expect(try run(["-n", "--column", "--byte-offset", "--replace", "XX", "Sherlock|Watson", root.path("multi-literal-replace.txt")]) == [
            "1:1:0:XX XX",
            "2:1:16:XX XX",
        ])
        #expect(try run(["-n", "-o", "--column", "--byte-offset", "--replace", "", "Sherlock|Watson", root.path("multi-literal-replace.txt")]) == [
            "1:1:0:",
            "1:2:1:",
            "2:1:16:",
            "2:2:17:",
        ])
        #expect(try run(["--with-filename", "Sherlock", root.path("multi-literal-replace.txt")]) == [
            "\(root.path("multi-literal-replace.txt")):Watson Sherlock",
            "\(root.path("multi-literal-replace.txt")):Sherlock Watson",
        ])
        #expect(try run(["--with-filename", "-o", "Sherlock", root.path("multi-literal-replace.txt")]) == [
            "\(root.path("multi-literal-replace.txt")):Sherlock",
            "\(root.path("multi-literal-replace.txt")):Sherlock",
        ])
        #expect(try run(["--with-filename", "-o", "Sherlock|Watson", root.path("multi-literal-replace.txt")]) == [
            "\(root.path("multi-literal-replace.txt")):Watson",
            "\(root.path("multi-literal-replace.txt")):Sherlock",
            "\(root.path("multi-literal-replace.txt")):Sherlock",
            "\(root.path("multi-literal-replace.txt")):Watson",
        ])
        #expect(try run(["--with-filename", "-n", "--column", "--byte-offset", "Sherlock|Watson", root.path("multi-literal-replace.txt")]) == [
            "\(root.path("multi-literal-replace.txt")):1:1:0:Watson Sherlock",
            "\(root.path("multi-literal-replace.txt")):2:1:16:Sherlock Watson",
        ])
        #expect(try run(["--with-filename", "--replace", "X", "Sherlock|Watson", root.path("multi-literal-replace.txt")]) == [
            "\(root.path("multi-literal-replace.txt")):X X",
            "\(root.path("multi-literal-replace.txt")):X X",
        ])
        #expect(try run(["--with-filename", "-n", "--column", "--byte-offset", "--replace", "XX", "Sherlock|Watson", root.path("multi-literal-replace.txt")]) == [
            "\(root.path("multi-literal-replace.txt")):1:1:0:XX XX",
            "\(root.path("multi-literal-replace.txt")):2:1:16:XX XX",
        ])
        #expect(try run(["--with-filename", "-n", "-o", "--column", "--byte-offset", "--replace", "", "Sherlock|Watson", root.path("multi-literal-replace.txt")]) == [
            "\(root.path("multi-literal-replace.txt")):1:1:0:",
            "\(root.path("multi-literal-replace.txt")):1:2:1:",
            "\(root.path("multi-literal-replace.txt")):2:1:16:",
            "\(root.path("multi-literal-replace.txt")):2:2:17:",
        ])
        #expect(try run(["-o", "--replace", "[$1]", #"([a-z]+)\d+"#, root.path("replace.txt")]) == [
            "[abc]",
            "[def]",
        ])
        #expect(try run(["-or", "$1", #"([a-z]+)\d+"#, root.path("replace.txt")]) == [
            "abc",
            "def",
        ])
        #expect(try run(["-orX", #"([a-z]+)\d+"#, root.path("replace.txt")]) == [
            "X",
            "X",
        ])
        #expect(try run(["-o", "--column", "--replace", "X", #"[a-z]+\d+"#, root.path("replace.txt")]) == [
            "1:1:X",
            "1:3:X",
        ])
        #expect(try run(["-o", "--byte-offset", "--replace", "X", #"[a-z]+\d+"#, root.path("replace.txt")]) == [
            "0:X",
            "2:X",
        ])
        let onlyMatchingTrailingLFReplacement = try runExecutableData([
            "-o",
            "--replace",
            "X\n",
            #"([a-z]+)\d+"#,
            root.path("replace.txt"),
        ]) {}
        #expect(onlyMatchingTrailingLFReplacement == Data("X\nX\n".utf8))
        let onlyMatchingTrailingCRLFReplacement = try runExecutableData([
            "-o",
            "--replace",
            "X\r\n",
            #"([a-z]+)\d+"#,
            root.path("replace.txt"),
        ]) {}
        #expect(onlyMatchingTrailingCRLFReplacement == Data("X\r\nX\r\n".utf8))
        #expect(try run(["--replace", "${0}_${1}_${2}${3}_$$", #"([a-z]+)(\d+)"#, root.path("replace.txt")]) == [
            "abc123_abc_123_$ def456_def_456_$",
        ])
        #expect(try run(["--replace", "$word:${digits}$missing", #"(?P<word>[a-z]+)(?P<digits>\d+)"#, root.path("replace.txt")]) == [
            "abc:123 def:456",
        ])
        try root.write("a\n\n", to: "empty-match.txt")
        #expect(try run(["-o", #".*"#, root.path("empty-match.txt")]) == [
            "a",
            "",
        ])
        try root.write("one\ntwo\nthree\n", to: "absolute-start.txt")
        #expect(try run(["-n", "-o", #"\A"#, root.path("absolute-start.txt")]) == [
            "1:",
            "2:two",
            "3:three",
        ])
        #expect(try run(["--column", "-n", "-o", #"\A"#, root.path("absolute-start.txt")]) == [
            "1:1:",
            "2:two",
            "3:three",
        ])
        #expect(try run(["--count-matches", #"\A"#, root.path("absolute-start.txt")]) == [
            "3",
        ])
        #expect(try run(["-v", "-n", #"\A"#, root.path("absolute-start.txt")]) == [])
        try root.write("foo\nfoo\nbarfoo\nquux\n", to: "absolute-start-alternation.txt")
        #expect(try run(["-n", "-o", #"\A|bar"#, root.path("absolute-start-alternation.txt")]) == [
            "1:",
            "2:foo",
            "3:bar",
            "4:quux",
        ])
        #expect(try run(["-n", "-o", #"bar|\A"#, root.path("absolute-start-alternation.txt")]) == [
            "1:",
            "2:foo",
            "3:bar",
            "4:quux",
        ])
        #expect(try run(["-n", "-o", #"\A|foo"#, root.path("absolute-start-alternation.txt")]) == [
            "1:",
            "2:foo",
            "3:foo",
            "4:quux",
        ])
        #expect(try run(["-n", "-o", #"foo|\A"#, root.path("absolute-start-alternation.txt")]) == [
            "1:foo",
            "2:foo",
            "3:foo",
            "4:quux",
        ])
        #expect(try run(["--count-matches", #"\A|bar"#, root.path("absolute-start-alternation.txt")]) == [
            "4",
        ])
        #expect(try run(["-n", "-o", "--replace", "X", #"\A|bar"#, root.path("absolute-start-alternation.txt")]) == [
            "1:X",
            "2:foo",
            "3:X",
            "4:quux",
        ])
        #expect(try run(["--replace", "X", #"\A|foo"#, root.path("absolute-start-alternation.txt")]) == [
            "Xfoo",
            "X",
            "barX",
            "quux",
        ])
        #expect(try run(["--replace", "${0}f", #".*"#, root.path("empty-match.txt")]) == [
            "af",
            "f",
        ])
        try root.write("á\n", to: "utf8-empty-replace.txt")
        let internalUTF8EmptyReplacement = try runExecutableData([
            "--replace",
            "X",
            "x?",
            root.path("utf8-empty-replace.txt"),
        ]) {}
        #expect(internalUTF8EmptyReplacement == Data([0x58, 0xC3, 0x58, 0xA1, 0x58, 0x0A]))
        let internalUTF8OptionalLiteralReplacement = try runExecutableData([
            "--replace",
            "X",
            "a?",
            root.path("utf8-empty-replace.txt"),
        ]) {}
        #expect(internalUTF8OptionalLiteralReplacement == Data([0x58, 0xC3, 0x58, 0xA1, 0x58, 0x0A]))
        let prefixedInternalUTF8Replacement = try runExecutableData([
            "-H",
            "--replace",
            "<$0>",
            "x?",
            root.path("utf8-empty-replace.txt"),
        ]) {}
        #expect(prefixedInternalUTF8Replacement == Data(
            "\(root.path("utf8-empty-replace.txt")):<>".utf8
        ) + Data([0xC3]) + Data("<>".utf8) + Data([0xA1]) + Data("<>\n".utf8)
        )
        let internalUTF8OnlyMatchingReplacement = try runExecutableData([
            "-o",
            "--replace",
            "X",
            "x?",
            root.path("utf8-empty-replace.txt"),
        ]) {}
        #expect(internalUTF8OnlyMatchingReplacement == Data("X\nX\nX\n".utf8))
        let internalUTF8ByteOffsets = try runExecutableData([
            "-bo",
            "x?",
            root.path("utf8-empty-replace.txt"),
        ]) {}
        #expect(internalUTF8ByteOffsets == Data("0:\n1:\n2:\n".utf8))
        #expect(try run(["--replace", "${}_${bad-name}_${1}", #"([a-z]+)\d+"#, root.path("replace.txt")]) == [
            "${}_${bad-name}_abc ${}_${bad-name}_def",
        ])
        try root.write("κόσμε needle\n", to: "unicode-replace-column.txt")
        #expect(try run([
            "-o",
            "--column",
            "--replace",
            "$1",
            #"\bneedle\b"#,
            root.path("unicode-replace-column.txt"),
        ]) == [
            "1:13:",
        ])

        try root.write("abc123\nfoo\nπ\n", to: "invert-only.txt")
        #expect(try run(["-v", "-o", "foo", root.path("invert-only.txt")]) == [
            "abc123",
            "π",
        ])
        #expect(try run(["-v", "-o", "-n", "--column", "foo", root.path("invert-only.txt")]) == [
            "1:abc123",
            "3:π",
        ])
        #expect(try run(["-v", "-o", "-b", "foo", root.path("invert-only.txt")]) == [
            "0:abc123",
            "11:π",
        ])

        try root.write("foo bar -baz\n", to: "hyphen.txt")
        #expect(try run(["-e-baz", "-e", "-baz", root.path("hyphen.txt")]) == [
            "foo bar -baz",
        ])
        #expect(try run(["-rni", "bar", root.path("hyphen.txt")]) == [
            "foo ni -baz",
        ])
        #expect(try run(["-r", "-n", "-i", "bar", root.path("hyphen.txt")]) == [
            "foo -n -baz",
        ])
        #expect(try run(["-n", "-No", "bar", root.path("hyphen.txt")]) == [
            "bar",
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
        #expect(try run(["--vimgrep", "-c", "needle", root.path("a.txt")]) == [
            "\(root.path("a.txt")):1",
        ])
        #expect(try run(["--vimgrep", "--count-matches", "needle", root.path("a.txt")]) == [
            "\(root.path("a.txt")):2",
        ])
        #expect(try run(["--vimgrep", "--no-filename", "-c", "needle", root.path("a.txt")]) == [
            "1",
        ])
        #expect(try run(["--vimgrep", "--no-filename", "--count-matches", "needle", root.path("a.txt")]) == [
            "2",
        ])
        #expect(try run(["--vimgrep", "-m1", "needle", root.path("a.txt")]) == [
            "\(root.path("a.txt")):1:3:  needle one needle",
            "\(root.path("a.txt")):1:14:  needle one needle",
        ])
        #expect(try run(["--vimgrep", "-m1", "-o", "--byte-offset", "needle", root.path("a.txt")]) == [
            "\(root.path("a.txt")):1:3:2:needle",
            "\(root.path("a.txt")):1:14:13:needle",
        ])
        try root.write("abc\nABC\nxxxabcxxx\nzzz\nabc\n", to: "vimgrep-columns.txt")
        #expect(try run(["--vimgrep", "--max-columns", "3", "abc", root.path("vimgrep-columns.txt")]) == [
            "\(root.path("vimgrep-columns.txt")):1:1:[Omitted long line with 1 matches]",
            "\(root.path("vimgrep-columns.txt")):3:4:[Omitted long line with 1 matches]",
            "\(root.path("vimgrep-columns.txt")):5:1:[Omitted long line with 1 matches]",
        ])
        #expect(try run([
            "--vimgrep",
            "--max-columns",
            "3",
            "--max-columns-preview",
            "abc",
            root.path("vimgrep-columns.txt"),
        ]) == [
            "\(root.path("vimgrep-columns.txt")):1:1:abc [... 0 more matches]",
            "\(root.path("vimgrep-columns.txt")):3:4:xxx [... 1 more match]",
            "\(root.path("vimgrep-columns.txt")):5:1:abc [... 0 more matches]",
        ])
        try root.write("abc\nABC\nxxxabcxxx\nzzz\nabc\n", to: "vimgrep-null-data.txt")
        let vimgrepNullDataOutput = try runExecutableData([
            "--vimgrep",
            "--null-data",
            "abc",
            root.path("vimgrep-null-data.txt"),
        ]) {}
        let vimgrepNullDataLine = "\(root.path("vimgrep-null-data.txt")):1:1:abc\nABC\nxxxabcxxx\nzzz\nabc\n\0"
        #expect(vimgrepNullDataOutput == Data(
            "\(vimgrepNullDataLine)\(root.path("vimgrep-null-data.txt")):1:12:abc\nABC\nxxxabcxxx\nzzz\nabc\n\0\(root.path("vimgrep-null-data.txt")):1:23:abc\nABC\nxxxabcxxx\nzzz\nabc\n\0".utf8
        ))
        try root.write("abc123 def456\n", to: "vimgrep-replace.txt")
        #expect(try run(["--vimgrep", "--replace", "X", #"[a-z]+\d+"#, root.path("vimgrep-replace.txt")]) == [
            "\(root.path("vimgrep-replace.txt")):1:1:X X",
            "\(root.path("vimgrep-replace.txt")):1:3:X X",
        ])
        try root.write("foo foo\nFoo foo\n", to: "vimgrep-literal-replace.txt")
        #expect(try run(["--vimgrep", "--replace", "XX", "foo", root.path("vimgrep-literal-replace.txt")]) == [
            "\(root.path("vimgrep-literal-replace.txt")):1:1:XX XX",
            "\(root.path("vimgrep-literal-replace.txt")):1:4:XX XX",
            "\(root.path("vimgrep-literal-replace.txt")):2:5:Foo XX",
        ])
        #expect(try run([
            "--vimgrep",
            "-o",
            "--byte-offset",
            "--replace",
            "",
            "foo",
            root.path("vimgrep-literal-replace.txt"),
        ]) == [
            "\(root.path("vimgrep-literal-replace.txt")):1:1:0:",
            "\(root.path("vimgrep-literal-replace.txt")):1:2:1:",
            "\(root.path("vimgrep-literal-replace.txt")):2:5:12:",
        ])
        #expect(try run([
            "--vimgrep",
            "-m1",
            "-o",
            "--replace",
            "X",
            "foo",
            root.path("vimgrep-literal-replace.txt"),
        ]) == [
            "\(root.path("vimgrep-literal-replace.txt")):1:1:X",
            "\(root.path("vimgrep-literal-replace.txt")):1:3:X",
        ])
        try root.write("Watson Sherlock\nSherlock Watson\n", to: "vimgrep-multi-literal-replace.txt")
        #expect(try run([
            "--vimgrep",
            "--replace",
            "X",
            "Sherlock|Watson",
            root.path("vimgrep-multi-literal-replace.txt"),
        ]) == [
            "\(root.path("vimgrep-multi-literal-replace.txt")):1:1:X X",
            "\(root.path("vimgrep-multi-literal-replace.txt")):1:3:X X",
            "\(root.path("vimgrep-multi-literal-replace.txt")):2:1:X X",
            "\(root.path("vimgrep-multi-literal-replace.txt")):2:3:X X",
        ])
        #expect(try run([
            "--vimgrep",
            "-o",
            "--byte-offset",
            "--replace",
            "",
            "Sherlock|Watson",
            root.path("vimgrep-multi-literal-replace.txt"),
        ]) == [
            "\(root.path("vimgrep-multi-literal-replace.txt")):1:1:0:",
            "\(root.path("vimgrep-multi-literal-replace.txt")):1:2:1:",
            "\(root.path("vimgrep-multi-literal-replace.txt")):2:1:16:",
            "\(root.path("vimgrep-multi-literal-replace.txt")):2:2:17:",
        ])
        #expect(try run([
            "--vimgrep",
            "--byte-offset",
            "--replace",
            "<$1>",
            #"([a-z]+)\d+"#,
            root.path("vimgrep-replace.txt"),
        ]) == [
            "\(root.path("vimgrep-replace.txt")):1:1:0:<abc> <def>",
            "\(root.path("vimgrep-replace.txt")):1:7:6:<abc> <def>",
        ])
        try root.write("á\n", to: "vimgrep-utf8-replace.txt")
        let vimgrepUTF8Replacement = try runExecutableData([
            "--vimgrep",
            "--replace",
            "<$0>",
            "x?",
            root.path("vimgrep-utf8-replace.txt"),
        ]) {}
        let vimgrepUTF8ReplacementLine1 = Data(
            "\(root.path("vimgrep-utf8-replace.txt")):1:1:<>".utf8
        ) + Data([0xC3]) + Data("<>".utf8) + Data([0xA1]) + Data("<>\n".utf8)
        let vimgrepUTF8ReplacementLine2 = Data(
            "\(root.path("vimgrep-utf8-replace.txt")):1:4:<>".utf8
        ) + Data([0xC3]) + Data("<>".utf8) + Data([0xA1]) + Data("<>\n".utf8)
        let vimgrepUTF8ReplacementLine3 = Data(
            "\(root.path("vimgrep-utf8-replace.txt")):1:7:<>".utf8
        ) + Data([0xC3]) + Data("<>".utf8) + Data([0xA1]) + Data("<>\n".utf8)
        #expect(vimgrepUTF8Replacement == vimgrepUTF8ReplacementLine1
            + vimgrepUTF8ReplacementLine2
            + vimgrepUTF8ReplacementLine3)
        try root.write("Watson Sherlock\nnone\nSherlock Holmes\nDoctor Watson\n", to: "vimgrep.txt")
        #expect(try run(["--vimgrep", "-N", "Sherlock|Watson", root.path("vimgrep.txt")]) == [
            "\(root.path("vimgrep.txt")):1:Watson Sherlock",
            "\(root.path("vimgrep.txt")):8:Watson Sherlock",
            "\(root.path("vimgrep.txt")):1:Sherlock Holmes",
            "\(root.path("vimgrep.txt")):8:Doctor Watson",
        ])
        #expect(try run(["--vimgrep", "-N", "--no-column", "Sherlock|Watson", root.path("vimgrep.txt")]) == [
            "\(root.path("vimgrep.txt")):Watson Sherlock",
            "\(root.path("vimgrep.txt")):Watson Sherlock",
            "\(root.path("vimgrep.txt")):Sherlock Holmes",
            "\(root.path("vimgrep.txt")):Doctor Watson",
        ])
        #expect(try run(["--vimgrep", "-N", "--no-column", "--column", "Sherlock", root.path("vimgrep.txt")]) == [
            "\(root.path("vimgrep.txt")):8:Watson Sherlock",
            "\(root.path("vimgrep.txt")):1:Sherlock Holmes",
        ])
        #expect(try run(["--vimgrep", "-m1", "Sherlock|Watson", root.path("vimgrep.txt")]) == [
            "\(root.path("vimgrep.txt")):1:1:Watson Sherlock",
            "\(root.path("vimgrep.txt")):1:8:Watson Sherlock",
        ])
        #expect(try run(["--vimgrep", "-m1", "-o", "--byte-offset", "Sherlock|Watson", root.path("vimgrep.txt")]) == [
            "\(root.path("vimgrep.txt")):1:1:0:Watson",
            "\(root.path("vimgrep.txt")):1:8:7:Sherlock",
        ])
        let vimgrepInvertRoot = try TemporaryDirectory()
        try vimgrepInvertRoot.write("before\nneedle\nafter\n", to: "vimgrep-invert.txt")
        #expect(try run(["--vimgrep", "-v", "NEEDLE", vimgrepInvertRoot.path("vimgrep-invert.txt")]) == [
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt")):1:before",
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt")):2:needle",
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt")):3:after",
        ])
        #expect(try run(["--vimgrep", "--passthru", "-v", "NEEDLE", vimgrepInvertRoot.path("vimgrep-invert.txt")]) == [
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt")):1:before",
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt")):2:needle",
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt")):3:after",
        ])
        #expect(try run(["--vimgrep", "--passthru", "-v", "needle", vimgrepInvertRoot.path("vimgrep-invert.txt")]) == [
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt")):1:before",
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt"))-2-1-needle",
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt")):3:after",
        ])
        #expect(try run(["--vimgrep", "--passthru", "-b", "-v", "needle", vimgrepInvertRoot.path("vimgrep-invert.txt")]) == [
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt")):1:0:before",
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt"))-2-1-7-needle",
            "\(vimgrepInvertRoot.path("vimgrep-invert.txt")):3:14:after",
        ])
        try root.write("κόσμε target\n", to: "vimgrep-unicode-replace-column.txt")
        #expect(try run([
            "--vimgrep",
            "--replace",
            "$1",
            #"\btarget\b"#,
            root.path("vimgrep-unicode-replace-column.txt"),
        ]) == [
            "\(root.path("vimgrep-unicode-replace-column.txt")):1:13:κόσμε ",
        ])
        #expect(try run(["--heading", "-n", "--sort=path", "needle", root.url.path]) == [
            "\(root.path("a.txt"))",
            "1:  needle one needle",
            "",
            "\(root.path("b.txt"))",
            "1:xx needle",
        ])
        let nullHeadingOutput = try runExecutableData([
            "--heading",
            "--null",
            "--sort=path",
            "needle",
            root.url.path,
        ]) {}
        #expect(nullHeadingOutput == Data(
            "\(root.path("a.txt"))\0  needle one needle\n\n\(root.path("b.txt"))\0xx needle\n".utf8
        ))
        let nullDataHeadingOutput = try runExecutableData([
            "--heading",
            "--null-data",
            "--sort=path",
            "needle",
            root.url.path,
        ]) {}
        #expect(nullDataHeadingOutput == Data(
            "\(root.path("a.txt"))\0  needle one needle\n  no\n\0\0\(root.path("b.txt"))\0xx needle\n\0".utf8
        ))
        #expect(try run(["--heading", "--no-filename", "--sort=path", "needle", root.url.path]) == [
            "  needle one needle",
            "",
            "xx needle",
        ])
        try root.write("alpha\nneedle\ncontext\nneedle2\nomega\n", to: "vimgrep-context.txt")
        #expect(try run(["--vimgrep", "-C1", "needle", root.path("vimgrep-context.txt")]) == [
            "\(root.path("vimgrep-context.txt"))-1-alpha",
            "\(root.path("vimgrep-context.txt")):2:1:needle",
            "\(root.path("vimgrep-context.txt"))-3-context",
            "\(root.path("vimgrep-context.txt")):4:1:needle2",
            "\(root.path("vimgrep-context.txt"))-5-omega",
        ])
        #expect(try run(["--vimgrep", "-C1", "-b", "needle", root.path("vimgrep-context.txt")]) == [
            "\(root.path("vimgrep-context.txt"))-1-0-alpha",
            "\(root.path("vimgrep-context.txt")):2:1:6:needle",
            "\(root.path("vimgrep-context.txt"))-3-13-context",
            "\(root.path("vimgrep-context.txt")):4:1:21:needle2",
            "\(root.path("vimgrep-context.txt"))-5-29-omega",
        ])
        #expect(try run(["--vimgrep", "--no-filename", "-A1", "needle", root.path("vimgrep-context.txt")]) == [
            "2:1:needle",
            "3-context",
            "4:1:needle2",
            "5-omega",
        ])
        let vimgrepContextRoot = try TemporaryDirectory()
        try vimgrepContextRoot.write("needle tail\nNeedle\nhay\nneedle tail again\n", to: "a.txt")
        try vimgrepContextRoot.write("needle tail\n", to: "b.foo")
        #expect(try run([
            "--sort",
            "path",
            "--multiline-dotall",
            "--vimgrep",
            "-C1",
            #"needle\s+tail"#,
            vimgrepContextRoot.url.path,
        ]) == [
            "\(vimgrepContextRoot.path("a.txt")):1:1:needle tail",
            "\(vimgrepContextRoot.path("a.txt"))-2-Needle",
            "\(vimgrepContextRoot.path("a.txt"))-3-hay",
            "\(vimgrepContextRoot.path("a.txt")):4:1:needle tail again",
            "--",
            "\(vimgrepContextRoot.path("b.foo")):1:1:needle tail",
        ])
    }

    @Test("prints pretty and ANSI color modes")
    func printsPrettyAndANSIColorModes() throws {
        let root = try TemporaryDirectory()
        try root.write("alpha needle beta\nno\n", to: "a.txt")
        try root.write("needle again\n", to: "b.txt")
        try root.write("\n\ntest\n", to: "empty.txt")
        let multilineRoot = try TemporaryDirectory()
        try multilineRoot.write("alpha needle beta\nquiet\nneedle again\n", to: "multi-color.txt")

        let reset = "\u{1B}[0m"
        let blue = "\u{1B}[34m"
        let green = "\u{1B}[32m"
        let magenta = "\u{1B}[35m"
        let redBold = "\u{1B}[1m\u{1B}[31m"

        #expect(try run(["--color=always", "-n", "needle", root.path("a.txt")]) == [
            "\(reset)\(green)1\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
        ])
        #expect(try run(["--color=always", "-b", "needle", root.path("a.txt")]) == [
            "\(reset)0\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
        ])
        #expect(try run([
            "--color=always",
            "--colors=column:fg:blue",
            "-n",
            "-b",
            "needle",
            root.path("a.txt"),
        ]) == [
            "\(reset)\(green)1\(reset):\(reset)\(blue)0\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
        ])
        #expect(try run(["--trim", "--color=always", "needle", root.path("a.txt")]) == [
            "alpha \(reset)\(redBold)needle\(reset) beta",
        ])
        try root.write("barfoo\n", to: "adjacent.txt")
        #expect(try run(["--color=always", "--no-filename", "foo|bar", root.path("adjacent.txt")]) == [
            "\(reset)\(redBold)barfoo\(reset)",
        ])
        #expect(try run(["--vimgrep", "--color=always", "needle", root.path("a.txt")]) == [
            "\(reset)\(magenta)\(root.path("a.txt"))\(reset):\(reset)\(green)1\(reset):\(reset)7\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
        ])
        #expect(try run(["--color=always", "--vimgrep", "needle", root.path("a.txt")]) == [
            "\(reset)\(magenta)\(root.path("a.txt"))\(reset):\(reset)\(green)1\(reset):\(reset)7\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
        ])
        #expect(try run(["--pretty", "--vimgrep", "needle", root.path("a.txt")]) == [
            "\(reset)\(magenta)\(root.path("a.txt"))\(reset):\(reset)\(green)1\(reset):\(reset)7\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
        ])
        #expect(try run(["--color=always", "-U", "needle", multilineRoot.path("multi-color.txt")]) == [
            "alpha \(reset)\(redBold)needle\(reset) beta",
            "\(reset)\(redBold)needle\(reset) again",
        ])
        #expect(try run(["-Up", "needle", multilineRoot.path("multi-color.txt")]) == [
            "\(reset)\(green)1\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
            "\(reset)\(green)3\(reset):\(reset)\(redBold)needle\(reset) again",
        ])
        #expect(try run(["-pU", "needle", multilineRoot.path("multi-color.txt")]) == [
            "\(reset)\(green)1\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
            "\(reset)\(green)3\(reset):\(reset)\(redBold)needle\(reset) again",
        ])
        #expect(try run(["-Np", "needle", root.path("a.txt")]) == [
            "\(reset)\(green)1\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
        ])
        #expect(try run(["-pN", "needle", root.path("a.txt")]) == [
            "alpha \(reset)\(redBold)needle\(reset) beta",
        ])
        #expect(try run(["--vimgrep", "--color=always", "-o", "needle", root.path("a.txt")]) == [
            "\(reset)\(magenta)\(root.path("a.txt"))\(reset):\(reset)\(green)1\(reset):\(reset)7\(reset):\(reset)\(redBold)needle\(reset)",
        ])
        #expect(try run(["--pretty", "--color=never", "--sort=path", "needle", root.url.path]) == [
            "\(root.path("a.txt"))",
            "1:alpha needle beta",
            "",
            "\(root.path("b.txt"))",
            "1:needle again",
        ])
        #expect(try run([
            "--color=always",
            "--colors=match:none",
            "--colors=path:none",
            "--colors=line:none",
            "needle",
            root.path("a.txt"),
        ]) == [
            "alpha needle beta",
        ])
        #expect(try run([
            "--color=always",
            "--colors=match:fg:magenta",
            "needle",
            root.path("a.txt"),
        ]) == [
            "alpha \(reset)\u{1B}[1m\(magenta)needle\(reset) beta",
        ])
        #expect(try run([
            "--color=ansi",
            "--colors=path:none",
            "--colors=line:none",
            "--colors=match:fg:red",
            "--colors=match:style:nobold",
            "--line-number",
            "^$",
            root.path("empty.txt"),
        ]) == [
            "\(reset)1\(reset):",
            "\(reset)2\(reset):",
        ])
        #expect(try run(["--pretty", "--sort=path", "needle", root.url.path]) == [
            "\(reset)\(magenta)\(root.path("a.txt"))\(reset)",
            "\(reset)\(green)1\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
            "",
            "\(reset)\(magenta)\(root.path("b.txt"))\(reset)",
            "\(reset)\(green)1\(reset):\(reset)\(redBold)needle\(reset) again",
        ])

        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--color=Always", "needle", root.path("a.txt")],
            stdout: { _ in },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(errors == ["rg: error parsing flag --color: choice 'Always' is unrecognized"])

        var output: [String] = []
        output = []
        errors = []
        let invalidColorsExitCode = RipgrepCLI.run(
            arguments: ["--colors", "bad", "needle", root.path("a.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(invalidColorsExitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == [
            "rg: error parsing flag --colors: invalid color spec format: 'bad'. Valid format is '(path|line|column|match|highlight):(fg|bg|style):(value)'.",
        ])

        let invalidColorCases = [
            ("bad:fg:red", "rg: error parsing flag --colors: unrecognized output type 'bad'. Choose from: path, line, column, match, highlight."),
            ("match:bad:red", "rg: error parsing flag --colors: unrecognized spec type 'bad'. Choose from: fg, bg, style, none."),
            ("match:fg:notacolor", "rg: error parsing flag --colors: unrecognized color name 'notacolor'. Choose from: black, blue, green, red, cyan, magenta, yellow, white"),
            ("match:fg:bad", "rg: error parsing flag --colors: unrecognized ansi256 color number, should be '[0-255]' (or a hex number), but is 'bad'"),
            ("match:fg:f", "rg: error parsing flag --colors: unrecognized ansi256 color number, should be '[0-255]' (or a hex number), but is 'f'"),
            ("match:fg:300", "rg: error parsing flag --colors: unrecognized ansi256 color number, should be '[0-255]' (or a hex number), but is '300'"),
            ("match:fg:0x100", "rg: error parsing flag --colors: unrecognized color name '0x100'. Choose from: black, blue, green, red, cyan, magenta, yellow, white"),
            ("match:fg:0xFF00AA", "rg: error parsing flag --colors: unrecognized color name '0xFF00AA'. Choose from: black, blue, green, red, cyan, magenta, yellow, white"),
            ("match:fg:1,2,300", "rg: error parsing flag --colors: unrecognized RGB color triple, should be '[0-255],[0-255],[0-255]' (or a hex triple), but is '1,2,300'"),
            ("match:style:notastyle", "rg: error parsing flag --colors: unrecognized style attribute 'notastyle'. Choose from: nobold, bold, nointense, intense, nounderline, underline, noitalic, italic."),
        ]
        for (spec, expectedError) in invalidColorCases {
            output = []
            errors = []
            let exitCode = RipgrepCLI.run(
                arguments: ["--colors", spec, "needle", root.path("a.txt")],
                stdout: { output.append($0) },
                stderr: { errors.append($0) }
            )
            #expect(exitCode == 2)
            #expect(output.isEmpty)
            #expect(errors == [expectedError])
        }

        output = try run(["--color=always", "--colors=match:none:red", "needle", root.path("a.txt")])
        #expect(output == ["alpha needle beta"])
    }

    @Test("prints OSC8 hyperlinks for paths")
    func printsOSC8HyperlinksForPaths() throws {
        let root = try TemporaryDirectory()
        try root.createDirectory("links")
        try root.write("hay\nneedle\n", to: "links/a file.txt")
        let path = root.path("links/a file.txt")
        let hyperlinkPath = path.hasPrefix("/var/") ? "/private\(path)" : path
        let encodedPath = hyperlinkPath.replacingOccurrences(of: " ", with: "%20")
        let reset = "\u{1B}[0m"
        let linkedPath = "\u{1B}]8;;grep+://\(encodedPath):2\u{1B}\\\(reset)\(path)\(reset)\u{1B}]8;;\u{1B}\\"

        #expect(try run([
            "-H",
            "-n",
            "--column",
            "--color=always",
            "--colors=path:none",
            "--colors=line:none",
            "--colors=column:none",
            "--colors=match:none",
            "--hyperlink-format=grep+",
            "needle",
            path,
        ]) == [
            "\(linkedPath):\(reset)2\(reset):\(reset)1\(reset):needle",
        ])

        try root.write("#!/bin/sh\nprintf test-host\n", to: "hostname")
        try root.makeExecutable("hostname")
        let hostLinkedPath = "\u{1B}]8;;file://test-host\(encodedPath)\u{1B}\\\(reset)\(path)\(reset)\u{1B}]8;;\u{1B}\\"
        #expect(try run([
            "-H",
            "--color=always",
            "--colors=path:none",
            "--colors=match:none",
            "--hostname-bin",
            root.path("hostname"),
            "--hyperlink-format=file://{host}{path}",
            "needle",
            path,
        ]) == [
            "\(hostLinkedPath):needle",
        ])

        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--hyperlink-format", "file://example.invalid", "needle", path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors.first?.contains("invalid hyperlink format") == true)
    }

    @Test("lists files and honors hidden flag")
    func listsFilesAndHonorsHiddenFlag() throws {
        let root = try TemporaryDirectory()
        try root.write("visible\n", to: "visible.txt")
        try root.write("secret\n", to: ".hidden.txt")

        #expect(try run(["--files", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["visible.txt"])
        #expect(Set(try run(["--files", "--hidden", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent }) == Set([".hidden.txt", "visible.txt"]))
        #expect(Set(pathBasenames(try run(["--hidden", "e", root.url.path]))) == Set([".hidden.txt", "visible.txt"]))

        let executableRoot = try TemporaryDirectory()
        try executableRoot.write("visible\n", to: "visible.txt")
        try executableRoot.write("secret\n", to: ".hidden.txt")
        try executableRoot.write("nested\n", to: ".hidden-dir/nested.txt")
        try executableRoot.write("unicode\n", to: "café.txt")
        try FileManager.default.createSymbolicLink(
            at: executableRoot.url.appendingPathComponent("link.txt"),
            withDestinationURL: executableRoot.url.appendingPathComponent("visible.txt")
        )
        let executableFileList = try runExecutableData([
            "--no-ignore",
            "--hidden",
            "--files",
            executableRoot.url.path,
        ]) {}
        let executableRootPrefix = executableRoot.url.path + "/"
        let executableRelativePaths = String(decoding: executableFileList, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .map { path in
                path.hasPrefix(executableRootPrefix)
                    ? String(path.dropFirst(executableRootPrefix.count))
                    : path
            }
            .sorted()
        #expect(executableRelativePaths == [".hidden-dir/nested.txt", ".hidden.txt", "café.txt", "visible.txt"])

        let executableVisibleFileList = try runExecutableData([
            "--no-ignore",
            "--files",
            executableRoot.url.path,
        ]) {}
        let executableVisibleRelativePaths = String(decoding: executableVisibleFileList, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .map { path in
                path.hasPrefix(executableRootPrefix)
                    ? String(path.dropFirst(executableRootPrefix.count))
                    : path
            }
            .sorted()
        #expect(executableVisibleRelativePaths == ["café.txt", "visible.txt"])

        #if canImport(Darwin)
        let parallelRoot = try TemporaryDirectory()
        try parallelRoot.write("root\n", to: "root.txt")
        try parallelRoot.write("a\n", to: "a/one.txt")
        try parallelRoot.write("b\n", to: "b/two.txt")
        guard case .run(let noIgnoreOptions) = RipgrepArgumentParser.parse([
            "--no-ignore",
            "--hidden",
            "--files",
            parallelRoot.url.path,
        ]) else {
            Issue.record("expected file-list arguments to parse")
            return
        }
        var directBytes = Data()
        let directResults = try FileWalker().writeDarwinFilePathsWithMessages(
            for: noIgnoreOptions,
            writeBytes: { bytes in
                directBytes.append(bytes.bindMemory(to: UInt8.self))
            }
        )
        var streamedLines: [String] = []
        let streamedResults = try FileWalker().streamFilePathsWithMessages(
            for: noIgnoreOptions,
            emit: { streamedLines.append($0) }
        )
        let directLines = String(decoding: directBytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(directResults?.count == streamedResults?.count)
        #expect(directLines == streamedLines)

        guard case .run(let nullOptions) = RipgrepArgumentParser.parse([
            "--hidden",
            "--null",
            "--files",
            parallelRoot.url.path,
        ]) else {
            Issue.record("expected null file-list arguments to parse")
            return
        }
        var directNullBytes = Data()
        let directNullResults = try FileWalker().writeDarwinFilePathsWithMessages(
            for: nullOptions,
            writeBytes: { bytes in
                directNullBytes.append(bytes.bindMemory(to: UInt8.self))
            }
        )
        let directNullLines = String(decoding: directNullBytes, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
        #expect(directNullResults?.count == 3)
        #expect(directNullBytes.last == 0)
        #expect(directNullLines == streamedLines.sorted())

        let implicitRoot = try TemporaryDirectory()
        try implicitRoot.write("root\n", to: "keep.txt")
        try implicitRoot.write("nested\n", to: "nested/ok.txt")
        try implicitRoot.write("skip\n", to: "skip.txt")
        try implicitRoot.write("hidden\n", to: ".hidden.txt")
        try implicitRoot.write("skip.txt\n", to: ".ignore")
        let originalDirectory = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalDirectory) }
        #expect(FileManager.default.changeCurrentDirectoryPath(implicitRoot.url.path))

        let implicitFileList = try runExecutableData(["--files"]) {}
        #expect(String(decoding: implicitFileList, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .sorted() == ["keep.txt", "nested/ok.txt"])

        let explicitDotFileList = try runExecutableData(["--files", "."]) {}
        #expect(String(decoding: explicitDotFileList, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .sorted() == ["./keep.txt", "./nested/ok.txt"])

        let equivalentNoIgnoreRoot = try TemporaryDirectory()
        try equivalentNoIgnoreRoot.createDirectory(".git")
        try equivalentNoIgnoreRoot.write("root\n", to: "visible.txt")
        try equivalentNoIgnoreRoot.write("dot\n", to: "skip-dot.txt")
        try equivalentNoIgnoreRoot.write("vcs\n", to: "skip-vcs.txt")
        try equivalentNoIgnoreRoot.write("explicit\n", to: "skip-explicit.txt")
        try equivalentNoIgnoreRoot.write("skip-dot.txt\n", to: ".ignore")
        try equivalentNoIgnoreRoot.write("skip-vcs.txt\n", to: ".gitignore")
        try equivalentNoIgnoreRoot.write("skip-explicit.txt\n", to: "custom.ignore")
        guard case .run(let equivalentNoIgnoreOptions) = RipgrepArgumentParser.parse([
            "--no-ignore-dot",
            "--no-ignore-global",
            "--no-ignore-parent",
            "--no-ignore-vcs",
            "--no-ignore-files",
            "--files",
            equivalentNoIgnoreRoot.url.path,
        ]) else {
            Issue.record("expected equivalent no-ignore file-list arguments to parse")
            return
        }
        var equivalentNoIgnoreBytes = Data()
        let equivalentNoIgnoreResults = try FileWalker().writeDarwinFilePathsWithMessages(
            for: equivalentNoIgnoreOptions,
            writeBytes: { bytes in
                equivalentNoIgnoreBytes.append(bytes.bindMemory(to: UInt8.self))
            }
        )
        let equivalentNoIgnoreBasenames = Set(
            String(decoding: equivalentNoIgnoreBytes, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0)).lastPathComponent }
        )
        #expect(equivalentNoIgnoreResults?.count == 5)
        #expect(equivalentNoIgnoreBasenames == Set([
            "custom.ignore",
            "skip-dot.txt",
            "skip-explicit.txt",
            "skip-vcs.txt",
            "visible.txt",
        ]))

        #expect(Set(pathBasenames(try run([
            "--no-ignore-dot",
            "--no-ignore-global",
            "--no-ignore-parent",
            "--no-ignore-vcs",
            "--ignore-file",
            equivalentNoIgnoreRoot.path("custom.ignore"),
            "--files",
            equivalentNoIgnoreRoot.url.path,
        ]))) == Set([
            "custom.ignore",
            "skip-dot.txt",
            "skip-vcs.txt",
            "visible.txt",
        ]))

        let ignoreParallelRoot = try TemporaryDirectory()
        try ignoreParallelRoot.write("a\n", to: "a/keep.txt")
        try ignoreParallelRoot.write("skip\n", to: "a/skip.txt")
        try ignoreParallelRoot.write("skip.txt\n", to: "a/.ignore")
        try ignoreParallelRoot.write("b\n", to: "b/keep.txt")
        guard case .run(let parallelOptions) = RipgrepArgumentParser.parse([
            "--files",
            ignoreParallelRoot.url.path,
        ]),
              case .run(let sequentialOptions) = RipgrepArgumentParser.parse([
                "--debug",
                "--files",
                ignoreParallelRoot.url.path,
              ]) else {
            Issue.record("expected ignore-aware file-list arguments to parse")
            return
        }
        var parallelLines: [String] = []
        let parallelResults = try FileWalker().streamFilePathsWithMessages(
            for: parallelOptions,
            emit: { parallelLines.append($0) }
        )
        var sequentialLines: [String] = []
        let sequentialResults = try FileWalker().streamFilePathsWithMessages(
            for: sequentialOptions,
            emit: { sequentialLines.append($0) }
        )
        #expect(parallelResults?.count == sequentialResults?.count)
        #expect(parallelLines == sequentialLines)
        var parallelDirectBytes = Data()
        let parallelDirectResults = try FileWalker().writeDarwinFilePathsWithMessages(
            for: parallelOptions,
            writeBytes: { bytes in
                parallelDirectBytes.append(bytes.bindMemory(to: UInt8.self))
            }
        )
        let parallelDirectLines = String(decoding: parallelDirectBytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(parallelDirectResults?.count == parallelResults?.count)
        #expect(parallelDirectLines == parallelLines)

        let noVCSIgnoreRoot = try TemporaryDirectory()
        try noVCSIgnoreRoot.createDirectory(".git")
        try noVCSIgnoreRoot.write("keep\n", to: "a/keep-dot.txt")
        try noVCSIgnoreRoot.write("skip\n", to: "a/skip-dot.txt")
        try noVCSIgnoreRoot.write("skip-dot.txt\n", to: "a/.ignore")
        try noVCSIgnoreRoot.write("keep\n", to: "b/keep-vcs.txt")
        try noVCSIgnoreRoot.write("vcs\n", to: "b/skip-vcs.txt")
        try noVCSIgnoreRoot.write("skip-vcs.txt\n", to: ".gitignore")
        guard case .run(let noVCSIgnoreOptions) = RipgrepArgumentParser.parse([
            "--no-ignore-vcs",
            "--no-ignore-global",
            "--no-ignore-parent",
            "--files",
            noVCSIgnoreRoot.url.path,
        ]) else {
            Issue.record("expected no-vcs file-list arguments to parse")
            return
        }
        var noVCSIgnoreBytes = Data()
        let noVCSIgnoreResults = try FileWalker().writeDarwinFilePathsWithMessages(
            for: noVCSIgnoreOptions,
            writeBytes: { bytes in
                noVCSIgnoreBytes.append(bytes.bindMemory(to: UInt8.self))
            }
        )
        let noVCSIgnoreRootPrefix = noVCSIgnoreRoot.url.path + "/"
        let noVCSIgnoreRelativePaths = String(decoding: noVCSIgnoreBytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .map { path in
                path.hasPrefix(noVCSIgnoreRootPrefix)
                    ? String(path.dropFirst(noVCSIgnoreRootPrefix.count))
                    : path
            }
            .sorted()
        #expect(noVCSIgnoreResults?.count == 3)
        #expect(noVCSIgnoreRelativePaths == [
            "a/keep-dot.txt",
            "b/keep-vcs.txt",
            "b/skip-vcs.txt",
        ])
        #endif

        let whitelisted = try TemporaryDirectory()
        try whitelisted.createDirectory("subdir")
        try whitelisted.write("text\n", to: "subdir/.foo.txt")
        try whitelisted.write("!.foo.txt\n", to: ".ignore")
        #expect(try run(["--files", whitelisted.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == [".foo.txt"])

        let overrideRoot = try TemporaryDirectory()
        try overrideRoot.createDirectory("sub")
        try overrideRoot.write("alpha\n", to: "a.txt")
        try overrideRoot.write("beta\n", to: "b.txt")
        try overrideRoot.write("secret\n", to: ".hidden.txt")
        try overrideRoot.write("gamma\n", to: "sub/c.txt")
        try overrideRoot.write("b.txt\n", to: ".ignore")
        #expect(pathBasenames(try run([
            "--files",
            "--glob",
            "*.txt",
            "--sort",
            "path",
            overrideRoot.url.path,
        ])) == [".hidden.txt", "a.txt", "b.txt", "c.txt"])
        #expect(pathBasenames(try run([
            "--files",
            "--glob",
            "*.txt",
            "--glob",
            "!a.txt",
            "--sort",
            "path",
            overrideRoot.url.path,
        ])) == [".hidden.txt", "b.txt", "c.txt"])

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--quiet", "--files", "--glob", "*.txt", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--quiet", "--files", "--glob", "*.md", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--quiet", "--files", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        let quietIgnored = try TemporaryDirectory()
        try quietIgnored.write("ignored\n", to: "ignored.txt")
        try quietIgnored.write("ignored.txt\n", to: ".ignore")

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--quiet", "--files", quietIgnored.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        let quietReincludedHidden = try TemporaryDirectory()
        try quietReincludedHidden.write("secret\n", to: ".allowed.txt")
        try quietReincludedHidden.write("!.allowed.txt\n", to: ".ignore")

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--quiet", "--files", quietReincludedHidden.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        let hiddenOnly = try TemporaryDirectory()
        try hiddenOnly.write("secret\n", to: ".only-hidden.txt")

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--no-ignore", "--quiet", "--files", hiddenOnly.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--no-ignore", "--hidden", "--quiet", "--files", hiddenOnly.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        let hiddenDirectoryOnly = try TemporaryDirectory()
        try hiddenDirectoryOnly.write("secret\n", to: ".hidden-dir/nested.txt")

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--no-ignore", "--quiet", "--files", hiddenDirectoryOnly.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--no-ignore", "--hidden", "--quiet", "--files", hiddenDirectoryOnly.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--quiet", "--files", root.path("missing")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: \(root.path("missing")): IO error for operation on \(root.path("missing")): No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--glob", "*.txt", "--glob", "!visible.txt", "visible", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files", "missing", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.map { URL(fileURLWithPath: $0).lastPathComponent } == ["visible.txt"])
        #expect(errors == ["rg: missing: No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--json", "--files", "missing", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.map { URL(fileURLWithPath: $0).lastPathComponent } == ["visible.txt"])
        #expect(errors == ["rg: missing: No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files", "--no-messages", "missing", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.map { URL(fileURLWithPath: $0).lastPathComponent } == ["visible.txt"])
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files", "--quiet", "missing", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.isEmpty)
        #expect(errors == ["rg: missing: No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files", "--quiet", root.url.path, "missing"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.isEmpty)
        #expect(errors == ["rg: missing: No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files", "--quiet", "missing"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: missing: IO error for operation on missing: No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files", "--sort", "path", "-", root.path("visible.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output == [
            "<stdin>",
            root.path("visible.txt"),
        ])
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files", "--sortr", "path", "-", root.path("visible.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output == [
            root.path("visible.txt"),
            "<stdin>",
        ])
        #expect(errors.isEmpty)
    }

    @Test("preserves explicit current directory path prefixes")
    func preservesExplicitCurrentDirectoryPathPrefixes() throws {
        let root = try TemporaryDirectory()
        try root.createDirectory("a")
        try root.write("", to: "a/.ignore")
        let fileURL = root.url.appendingPathComponent("a/.ignore")

        var options = RipgrepOptions()
        options.mode = .files
        options.roots = [root.url]
        #expect(StandardPrinter(options: options, currentDirectory: root.url.path).paths([fileURL]) == ["a/.ignore"])

        options.rootPathArguments = ["./"]
        #expect(StandardPrinter(options: options, currentDirectory: root.url.path).paths([fileURL]) == ["./a/.ignore"])

        options.roots = [root.url.appendingPathComponent("a", isDirectory: true)]
        options.rootPathArguments = ["a"]
        #expect(StandardPrinter(options: options, currentDirectory: root.url.path).paths([fileURL]) == ["a/.ignore"])

        options.rootPathArguments = ["./a"]
        #expect(StandardPrinter(options: options, currentDirectory: root.url.path).paths([fileURL]) == ["./a/.ignore"])

        options.rootPathArguments = ["a/."]
        #expect(StandardPrinter(options: options, currentDirectory: root.url.path).paths([fileURL]) == ["a/./.ignore"])

        options.rootPathArguments = [root.path("a")]
        #expect(StandardPrinter(options: options, currentDirectory: root.url.path).paths([fileURL]) == ["\(root.path("a"))/.ignore"])

        options.rootPathArguments = [root.path("a/.")]
        #expect(StandardPrinter(options: options, currentDirectory: root.url.path).paths([fileURL]) == ["\(root.path("a/."))/.ignore"])
    }

    @Test("prints debug diagnostics for skipped files")
    func printsDebugDiagnosticsForSkippedFiles() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("needle\n", to: ".hidden.txt")
        try root.write("needle\n", to: "skip.log")
        try root.write("*.log\n", to: ".ignore")

        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--debug", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output == ["\(root.path("keep.txt")):needle"])
        #expect(errors.contains { $0.contains("DEBUG|rg::flags::hiargs|") && $0.contains("number of paths given to search: 1") })
        let defaultThreadCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        #expect(errors.contains { $0.contains("DEBUG|rg::flags::hiargs|") && $0.contains("using \(defaultThreadCount) thread(s)") })
        #expect(errors.contains { $0.contains("DEBUG|grep_regex::config|") && $0.contains("assembling HIR from 1 fixed string literals") })
        #expect(errors.contains { $0.contains("DEBUG|ignore::gitignore|") && $0.contains("opened gitignore file:") && $0.contains(".ignore") })
        #expect(errors.contains { $0.contains("DEBUG|globset|") && $0.contains("built glob set; 0 literals, 0 basenames, 1 extensions") })
        #expect(errors.contains { $0.contains("DEBUG|ignore::walk|") && $0.contains(".hidden.txt: Ignore(IgnoreMatch(Hidden))") })
        #expect(errors.contains { $0.contains("DEBUG|ignore::walk|") && $0.contains("skip.log: Ignore(IgnoreMatch(Gitignore(Glob") && $0.contains(#"original: "*.log""#) && $0.contains(#"actual: "**/*.log""#) })

        output = []
        errors = []
        let filesExitCode = RipgrepCLI.run(
            arguments: ["--debug", "--files", "--sort", "path", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(filesExitCode == 0)
        #expect(output == [root.path("keep.txt")])
        #expect(errors.contains { $0.contains("DEBUG|ignore::walk|") && $0.contains(".hidden.txt: Ignore(IgnoreMatch(Hidden))") })
        #expect(errors.contains { $0.contains("DEBUG|ignore::walk|") && $0.contains("skip.log: Ignore(IgnoreMatch(Gitignore(Glob") && $0.contains(#"original: "*.log""#) })

        output = []
        errors = []
        let traceExitCode = RipgrepCLI.run(
            arguments: ["--debug", "--trace", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(traceExitCode == 0)
        #expect(errors.contains { $0.contains("DEBUG|ignore::walk|") && $0.contains("Ignore(IgnoreMatch(") })
    }

    @Test("honors symlink and one file system traversal toggles")
    func honorsSymlinkAndOneFileSystemTraversalToggles() throws {
        let root = try TemporaryDirectory()
        try root.createDirectory("real")
        try root.createDirectory("real/nested")
        try root.write("needle\n", to: "real/file.txt")
        try root.write("needle\n", to: "real/nested/deep.txt")
        try FileManager.default.createSymbolicLink(
            at: root.url.appendingPathComponent("link"),
            withDestinationURL: root.url.appendingPathComponent("real")
        )
        try FileManager.default.createSymbolicLink(
            at: root.url.appendingPathComponent("file-link"),
            withDestinationURL: root.url.appendingPathComponent("real/file.txt")
        )
        var output: [String] = []
        var errors: [String] = []
        let debugExitCode = RipgrepCLI.run(
            arguments: ["--debug", "--sort", "path", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(debugExitCode == 0)
        #expect(pathBasenames(output) == ["file.txt", "deep.txt"])
        #expect(!errors.contains { $0.contains("symbolic link") })

        #expect(pathBasenames(try run(["--sort", "path", "needle", root.url.path])) == ["file.txt", "deep.txt"])
        #expect(try run(["needle", root.path("file-link")]) == ["needle"])
        #expect(try run(["needle", root.path("real/file.txt"), root.path("file-link")]) == [
            "\(root.path("real/file.txt")):needle",
            "\(root.path("file-link")):needle",
        ])
        #expect(try run(["--follow", "--sort", "path", "needle", root.url.path]) == [
            "\(root.path("file-link")):needle",
            "\(root.path("link/file.txt")):needle",
            "\(root.path("link/nested/deep.txt")):needle",
            "\(root.path("real/file.txt")):needle",
            "\(root.path("real/nested/deep.txt")):needle",
        ])
        #expect(Set(try run(["needle", root.path("link")])) == Set([
            "\(root.path("link/file.txt")):needle",
            "\(root.path("link/nested/deep.txt")):needle",
        ]))
        #expect(pathBasenames(try run(["--follow", "--no-follow", "--sort", "path", "needle", root.url.path])) == ["file.txt", "deep.txt"])
        #expect(pathBasenames(try run(["--one-file-system", "--sort", "path", "needle", root.url.path])) == ["file.txt", "deep.txt"])
        #expect(pathBasenames(try run(["--one-file-system", "--no-one-file-system", "--sort", "path", "needle", root.url.path])) == ["file.txt", "deep.txt"])

        let ignoredSymlinkRoot = try TemporaryDirectory()
        try ignoredSymlinkRoot.createDirectory("real/nested")
        try ignoredSymlinkRoot.write("needle\n", to: "real/main.swift")
        try ignoredSymlinkRoot.write("needle\n", to: "real/nested/deep.swift")
        try ignoredSymlinkRoot.write("nested/\n", to: "real/.ignore")
        try FileManager.default.createSymbolicLink(
            at: ignoredSymlinkRoot.url.appendingPathComponent("link"),
            withDestinationURL: ignoredSymlinkRoot.url.appendingPathComponent("real")
        )
        #expect(try run(["needle", ignoredSymlinkRoot.path("link")]) == [
            "\(ignoredSymlinkRoot.path("link/main.swift")):needle",
        ])
        #expect(try run(["--no-ignore", "needle", ignoredSymlinkRoot.path("link")]) == [
            "\(ignoredSymlinkRoot.path("link/main.swift")):needle",
            "\(ignoredSymlinkRoot.path("link/nested/deep.swift")):needle",
        ])
        #expect(try run(["--follow", "--sort", "path", "needle", ignoredSymlinkRoot.url.path]) == [
            "\(ignoredSymlinkRoot.path("link/main.swift")):needle",
            "\(ignoredSymlinkRoot.path("real/main.swift")):needle",
        ])
        #expect(try run(["--no-ignore", "--follow", "--sort", "path", "needle", ignoredSymlinkRoot.url.path]) == [
            "\(ignoredSymlinkRoot.path("link/main.swift")):needle",
            "\(ignoredSymlinkRoot.path("link/nested/deep.swift")):needle",
            "\(ignoredSymlinkRoot.path("real/main.swift")):needle",
            "\(ignoredSymlinkRoot.path("real/nested/deep.swift")):needle",
        ])

        try root.write("*.log\n", to: ".ignore")
        try root.createDirectory("logreal")
        try root.write("needle\n", to: "logreal/skip.log")
        try FileManager.default.createSymbolicLink(
            at: root.url.appendingPathComponent("loglink"),
            withDestinationURL: root.url.appendingPathComponent("logreal")
        )
        #expect(try runAllowingNoMatch(["--no-messages", "--follow", "needle", root.path("loglink")]) == [])
        #expect(try run(["--no-ignore", "--follow", "needle", root.path("loglink")]) == [
            "\(root.path("loglink/skip.log")):needle",
        ])

        let loopRoot = try TemporaryDirectory()
        try loopRoot.createDirectory("dir")
        try loopRoot.write("needle\n", to: "dir/file.txt")
        try FileManager.default.createSymbolicLink(
            at: loopRoot.url.appendingPathComponent("link-file"),
            withDestinationURL: loopRoot.url.appendingPathComponent("dir/file.txt")
        )
        try FileManager.default.createSymbolicLink(
            at: loopRoot.url.appendingPathComponent("link-dir"),
            withDestinationURL: loopRoot.url.appendingPathComponent("dir")
        )
        try FileManager.default.createSymbolicLink(
            at: loopRoot.url.appendingPathComponent("broken"),
            withDestinationURL: loopRoot.url.appendingPathComponent("missing")
        )
        try FileManager.default.createSymbolicLink(
            at: loopRoot.url.appendingPathComponent("self"),
            withDestinationURL: loopRoot.url
        )

        output = []
        errors = []
        let loopExitCode = RipgrepCLI.run(
            arguments: ["--sort", "path", "--follow", "needle", loopRoot.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(loopExitCode == 2)
        #expect(output == [
            "\(loopRoot.path("dir/file.txt")):needle",
            "\(loopRoot.path("link-dir/file.txt")):needle",
            "\(loopRoot.path("link-file")):needle",
        ])
        #expect(errors == [
            "rg: \(loopRoot.path("broken")): IO error for operation on \(loopRoot.path("broken")): No such file or directory (os error 2)",
            "rg: File system loop found: \(loopRoot.path("self")) points to an ancestor \(loopRoot.url.path)",
        ])

        output = []
        errors = []
        let filesLoopExitCode = RipgrepCLI.run(
            arguments: ["--sort", "path", "--files", "--follow", loopRoot.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(filesLoopExitCode == 2)
        #expect(output == [
            loopRoot.path("dir/file.txt"),
            loopRoot.path("link-dir/file.txt"),
            loopRoot.path("link-file"),
        ])
        #expect(errors == [
            "rg: \(loopRoot.path("broken")): IO error for operation on \(loopRoot.path("broken")): No such file or directory (os error 2)",
            "rg: File system loop found: \(loopRoot.path("self")) points to an ancestor \(loopRoot.url.path)",
        ])
    }

    @Test("honors ignore files and no ignore")
    func honorsIgnoreFilesAndNoIgnore() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("needle\n", to: "skip.log")
        try root.write("*.log\n", to: ".gitignore")
        try root.createDirectory(".git")

        #expect(pathBasenames(try run(["needle", root.url.path])) == ["keep.txt"])
        #expect(Set(pathBasenames(try run(["--no-ignore", "needle", root.url.path]))) == Set(["keep.txt", "skip.log"]))

        let anchored = try TemporaryDirectory()
        try anchored.createDirectory(".git")
        try anchored.write("/llvm/\n", to: ".gitignore")
        try anchored.createDirectory("src/llvm")
        try anchored.write("needle\n", to: "src/llvm/foo")
        #expect(try run(["needle", anchored.url.path]) == [anchored.path("src/llvm/foo") + ":needle"])
        #expect(try run(["needle", anchored.path("src")]) == [anchored.path("src/llvm/foo") + ":needle"])

        let slashScoped = try TemporaryDirectory()
        try slashScoped.createDirectory(".git")
        try slashScoped.createDirectory("vendor")
        try slashScoped.createDirectory("src/vendor")
        try slashScoped.write("vendor/**\n", to: ".ignore")
        try slashScoped.write("needle\n", to: "vendor/skip.rs")
        try slashScoped.write("needle\n", to: "src/vendor/keep.rs")
        try slashScoped.write("needle\n", to: "src/main.rs")
        #expect(try run(["--sort", "path", "needle", slashScoped.url.path]) == [
            slashScoped.path("src/main.rs") + ":needle",
            slashScoped.path("src/vendor/keep.rs") + ":needle",
        ])
        #expect(try run(["--sort", "path", "--files", slashScoped.url.path]) == [
            slashScoped.path("src/main.rs"),
            slashScoped.path("src/vendor/keep.rs"),
        ])

        let anchoredSlashGlob = try TemporaryDirectory()
        try anchoredSlashGlob.createDirectory(".git")
        try anchoredSlashGlob.createDirectory("arch/arm64/include/generated")
        try anchoredSlashGlob.createDirectory("arch/arm64/include/manual")
        try anchoredSlashGlob.createDirectory("src/arch/arm64/include/generated")
        try anchoredSlashGlob.write("/arch/*/include/generated/\n", to: ".gitignore")
        try anchoredSlashGlob.write("needle\n", to: "arch/arm64/include/generated/skip.h")
        try anchoredSlashGlob.write("needle\n", to: "arch/arm64/include/manual/keep.h")
        try anchoredSlashGlob.write("needle\n", to: "src/arch/arm64/include/generated/keep.h")
        #expect(try run(["--sort", "path", "--files", anchoredSlashGlob.url.path]) == [
            anchoredSlashGlob.path("arch/arm64/include/manual/keep.h"),
            anchoredSlashGlob.path("src/arch/arm64/include/generated/keep.h"),
        ])

        let reinclude = try TemporaryDirectory()
        try reinclude.createDirectory(".git")
        try reinclude.createDirectory("tools/perf/include/perf")
        try reinclude.write("perf\n!include/perf/\n", to: "tools/perf/.gitignore")
        try reinclude.write("needle\n", to: "tools/perf/include/perf/perf_dlfilter.h")
        #expect(Set(try run(["--files", reinclude.url.path])) == Set([
            reinclude.path("tools/perf/include/perf/perf_dlfilter.h"),
        ]))
        #expect(try run(["--sort", "path", "--files", reinclude.path("tools/perf")]) == [
            reinclude.path("tools/perf/include/perf/perf_dlfilter.h"),
        ])

        let classReinclude = try TemporaryDirectory()
        try classReinclude.createDirectory(".git")
        try classReinclude.write(
            "fake_sigreturn_*\n!*.[ch]\n",
            to: ".gitignore"
        )
        try classReinclude.write("needle\n", to: "fake_sigreturn_bad_magic.c")
        try classReinclude.write("needle\n", to: "fake_sigreturn_bad_magic.o")
        try classReinclude.write("needle\n", to: "TODO")
        #expect(try run(["--sort", "path", "--files", classReinclude.url.path]) == [
            classReinclude.path("TODO"),
            classReinclude.path("fake_sigreturn_bad_magic.c"),
        ])

        let indexedRules = try TemporaryDirectory()
        try indexedRules.createDirectory(".git")
        try indexedRules.createDirectory("cache-build")
        try indexedRules.createDirectory("generated/a")
        try indexedRules.createDirectory("generated/c")
        try indexedRules.write(
            """
            *.tmp
            *.bin
            *.log
            *.o
            *.d
            cache*/
            build
            dist
            node_modules
            !keep.bin
            !generated/[ab]/keep.log
            """,
            to: ".gitignore"
        )
        try indexedRules.write("needle\n", to: "cache-build/skip.txt")
        try indexedRules.write("needle\n", to: "drop.bin")
        try indexedRules.write("needle\n", to: "generated/a/keep.log")
        try indexedRules.write("needle\n", to: "generated/c/skip.log")
        try indexedRules.write("needle\n", to: "keep.bin")
        try indexedRules.write("needle\n", to: "main.swift")
        #expect(try run(["--sort", "path", "--files", indexedRules.url.path]) == [
            indexedRules.path("generated/a/keep.log"),
            indexedRules.path("keep.bin"),
            indexedRules.path("main.swift"),
        ])

        let indexedSlashRules = try TemporaryDirectory()
        try indexedSlashRules.createDirectory(".git")
        try indexedSlashRules.createDirectory("foo")
        try indexedSlashRules.createDirectory("build/out")
        try indexedSlashRules.createDirectory("nested/foo")
        try indexedSlashRules.createDirectory("nested/build/out")
        try indexedSlashRules.createDirectory("keep/foo")
        try indexedSlashRules.write(
            """
            *.tmp
            *.bin
            *.log
            *.o
            *.d
            cache
            dist
            foo/bar
            build/out/
            !keep/foo/bar
            """,
            to: ".gitignore"
        )
        try indexedSlashRules.write("needle\n", to: "foo/bar")
        try indexedSlashRules.write("needle\n", to: "build/out/generated.txt")
        try indexedSlashRules.write("needle\n", to: "nested/foo/bar")
        try indexedSlashRules.write("needle\n", to: "nested/build/out/generated.txt")
        try indexedSlashRules.write("needle\n", to: "keep/foo/bar")
        try indexedSlashRules.write("needle\n", to: "main.swift")
        #expect(try run(["--sort", "path", "--files", indexedSlashRules.url.path]) == [
            indexedSlashRules.path("keep/foo/bar"),
            indexedSlashRules.path("main.swift"),
            indexedSlashRules.path("nested/build/out/generated.txt"),
            indexedSlashRules.path("nested/foo/bar"),
        ])

        let utf8ByteGlob = try TemporaryDirectory()
        try utf8ByteGlob.createDirectory(".git")
        try utf8ByteGlob.write("?.txt\n", to: ".gitignore")
        try utf8ByteGlob.write("needle\n", to: "a.txt")
        try utf8ByteGlob.write("needle\n", to: "é.txt")
        try utf8ByteGlob.write("needle\n", to: "éa.txt")
        #expect(Set(pathBasenames(try run(["--sort", "path", "--files", utf8ByteGlob.url.path]))) == Set([
            "é.txt",
            "éa.txt",
        ]))

        let utf8TwoByteGlob = try TemporaryDirectory()
        try utf8TwoByteGlob.createDirectory(".git")
        try utf8TwoByteGlob.write("??.txt\n", to: ".gitignore")
        try utf8TwoByteGlob.write("needle\n", to: "a.txt")
        try utf8TwoByteGlob.write("needle\n", to: "é.txt")
        try utf8TwoByteGlob.write("needle\n", to: "éa.txt")
        #expect(Set(pathBasenames(try run(["--sort", "path", "--files", utf8TwoByteGlob.url.path]))) == Set([
            "a.txt",
            "é.txt",
            "éa.txt",
        ]))

        let anywhereSlashMatcher = GlobMatcher(patterns: [
            "*.tmp", "*.bin", "*.log", "*.o", "*.d", "cache", "dist", "foo/bar",
        ])
        #expect(anywhereSlashMatcher.decision(relativePath: "foo/bar", isDirectory: false) == .exclude)
        #expect(anywhereSlashMatcher.decision(relativePath: "nested/foo/bar", isDirectory: false) == .exclude)
        #expect(anywhereSlashMatcher.decision(relativePath: "nested/foo/baz", isDirectory: false) == nil)

        let anywhereRegexMatcher = GlobMatcher(patterns: ["foo/{bar,baz}"])
        #expect(anywhereRegexMatcher.decision(relativePath: "nested/foo/bar", isDirectory: false) == .exclude)
        #expect(anywhereRegexMatcher.decision(relativePath: "nested/foo/quux", isDirectory: false) == nil)

        let scopedRegexMatcher = GlobMatcher(patterns: ["foo/{bar,baz}"], slashPatternsMatchAnywhere: false)
        #expect(scopedRegexMatcher.decision(relativePath: "foo/bar", isDirectory: false) == .exclude)
        #expect(scopedRegexMatcher.decision(relativePath: "nested/foo/bar", isDirectory: false) == nil)
    }

    @Test("honors git info exclude and its toggle")
    func honorsGitInfoExcludeAndToggle() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("needle\n", to: "skip.txt")
        try root.write("skip.txt\n", to: ".git/info/exclude")

        #expect(pathBasenames(try run(["needle", root.url.path])) == ["keep.txt"])
        #expect(Set(pathBasenames(try run(["--no-ignore-exclude", "needle", root.url.path]))) == Set(["keep.txt", "skip.txt"]))
        #expect(pathBasenames(try run([
            "--no-ignore-exclude",
            "--ignore-exclude",
            "needle",
            root.url.path,
        ])) == ["keep.txt"])
        #expect(Set(pathBasenames(try run(["--no-ignore", "needle", root.url.path]))) == Set(["keep.txt", "skip.txt"]))

        let worktree = try TemporaryDirectory()
        try worktree.createDirectory("repo/.git/info")
        try worktree.write("ignored\n", to: "repo/.git/info/exclude")
        try worktree.createDirectory("repo/.git/worktrees/repotree")
        try worktree.write("../..\n", to: "repo/.git/worktrees/repotree/commondir")
        try worktree.createDirectory("repotree")
        try worktree.write("gitdir: repo/.git/worktrees/repotree\n", to: "repotree/.git")
        try worktree.write("", to: "repotree/ignored")
        try worktree.write("", to: "repotree/not-ignored")

        let originalDirectory = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalDirectory) }
        #expect(FileManager.default.changeCurrentDirectoryPath(worktree.url.path))

        #expect(try run(["--sort", "path", "--files", "repotree"]) == ["repotree/not-ignored"])
        #expect(Set(try run(["--no-ignore-exclude", "--sort", "path", "--files", "repotree"])) == Set([
            "repotree/ignored",
            "repotree/not-ignored",
        ]))
    }

    @Test("honors global git ignore and its toggle")
    func honorsGlobalGitIgnoreAndToggle() throws {
        let home = try TemporaryDirectory()
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("needle\n", to: "skip.txt")
        try root.createDirectory(".git")
        try home.write("skip.txt\n", to: ".config/git/ignore")
        let environment = [
            "HOME": home.url.path,
            "XDG_CONFIG_HOME": home.path(".config"),
        ]

        #expect(pathBasenames(try run(["needle", root.url.path], environment: environment)) == ["keep.txt"])
        #expect(Set(pathBasenames(try run([
            "--no-ignore-global",
            "needle",
            root.url.path,
        ], environment: environment))) == Set(["keep.txt", "skip.txt"]))
        #expect(pathBasenames(try run([
            "--no-ignore-global",
            "--ignore-global",
            "needle",
            root.url.path,
        ], environment: environment)) == ["keep.txt"])
        #expect(Set(pathBasenames(try run([
            "--no-ignore",
            "needle",
            root.url.path,
        ], environment: environment))) == Set(["keep.txt", "skip.txt"]))

        let configuredHome = try TemporaryDirectory()
        let configuredRoot = try TemporaryDirectory()
        try configuredRoot.write("needle\n", to: "keep.txt")
        try configuredRoot.write("needle\n", to: "configured.txt")
        try configuredRoot.createDirectory(".git")
        try configuredHome.write("[core]\nexcludesFile = ~/custom-ignore\n", to: ".gitconfig")
        try configuredHome.write("configured.txt\n", to: "custom-ignore")
        #expect(pathBasenames(try run([
            "needle",
            configuredRoot.url.path,
        ], environment: ["HOME": configuredHome.url.path])) == ["keep.txt"])

        let hiddenHome = try TemporaryDirectory()
        let hiddenRoot = try TemporaryDirectory()
        try hiddenRoot.createDirectory(".git")
        try hiddenRoot.createDirectory(".cache")
        try hiddenRoot.write("", to: "visible.txt")
        try hiddenRoot.write("", to: ".cache/keep.txt")
        try hiddenRoot.write("", to: ".cache/skip.txt")
        try hiddenHome.write("**/.cache/skip.txt\n", to: ".config/git/ignore")
        let hiddenEnvironment = [
            "HOME": hiddenHome.url.path,
            "XDG_CONFIG_HOME": hiddenHome.path(".config"),
        ]
        #expect(Set(try run([
            "--sort",
            "path",
            "--files",
            hiddenRoot.url.path,
        ], environment: hiddenEnvironment)) == Set([
            hiddenRoot.path("visible.txt"),
        ]))
        #expect(Set(try run([
            "--sort",
            "path",
            "--hidden",
            "--files",
            hiddenRoot.url.path,
        ], environment: hiddenEnvironment)) == Set([
            hiddenRoot.path(".cache/keep.txt"),
            hiddenRoot.path("visible.txt"),
        ]))
        #expect(Set(try run([
            "--sort",
            "path",
            "--hidden",
            "--no-ignore-global",
            "--files",
            hiddenRoot.url.path,
        ], environment: hiddenEnvironment)) == Set([
            hiddenRoot.path(".cache/keep.txt"),
            hiddenRoot.path(".cache/skip.txt"),
            hiddenRoot.path("visible.txt"),
        ]))
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
        #expect(Set(pathBasenames(try run([
            "--no-ignore-dot",
            "--ignore-file",
            root.path("ignore.txt"),
            "needle",
            root.url.path,
        ]))) == Set(["keep.txt", "skip-dot.txt"]))
        #expect(Set(pathBasenames(try run([
            "--no-ignore-vcs",
            "--ignore-file",
            root.path("ignore.txt"),
            "needle",
            root.url.path,
        ]))) == Set(["keep.txt", "skip-vcs.txt"]))
        #expect(Set(pathBasenames(try run([
            "--no-ignore-files",
            "--ignore-file",
            root.path("ignore.txt"),
            "needle",
            root.url.path,
        ]))) == Set(["keep.txt", "skip-explicit.txt"]))

        let outsideGit = try TemporaryDirectory()
        try outsideGit.write("needle\n", to: "keep.txt")
        try outsideGit.write("needle\n", to: "skip-vcs.txt")
        try outsideGit.write("skip-vcs.txt\n", to: ".gitignore")
        #expect(Set(pathBasenames(try run(["needle", outsideGit.url.path]))) == Set(["keep.txt", "skip-vcs.txt"]))
        #expect(pathBasenames(try run(["--no-require-git", "needle", outsideGit.url.path])) == ["keep.txt"])
    }

    @Test("treats ignore unclosed character classes as literal")
    func treatsIgnoreUnclosedCharacterClassesAsLiteral() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("needle\n", to: "[broken")
        try root.write("[broken\n", to: ".ignore")

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output == [root.path("keep.txt") + ":needle"])
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files", "--sort", "path", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output == [root.path("keep.txt")])
        #expect(errors.isEmpty)
    }

    @Test("rejects unclosed character classes in CLI globs")
    func rejectsUnclosedCharacterClassesInCLIGlobs() throws {
        let root = try TemporaryDirectory()
        try root.write("", to: "[broken")
        try root.write("", to: "test")

        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--files", "-g", "[broken", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: error parsing glob '[broken': unclosed character class; missing ']'"])
    }

    @Test("honors escaped slash in ignore patterns")
    func honorsEscapedSlashInIgnorePatterns() throws {
        let root = try TemporaryDirectory()
        try root.write(#"foo\/"#, to: ".ignore")
        try root.createDirectory("foo")
        try root.write("test\n", to: "foo/bar")

        #expect(try runAllowingNoMatch(["--files", root.url.path]) == [])
    }

    @Test("honors escaped leading comment and negation markers in globs")
    func honorsEscapedLeadingCommentAndNegationMarkersInGlobs() throws {
        let root = try TemporaryDirectory()
        try root.write("\\#secret\n\\!bang\n", to: ".ignore")
        try root.write("needle\n", to: "#secret")
        try root.write("needle\n", to: "!bang")
        try root.write("needle\n", to: "keep")

        #expect(try run(["--sort", "path", "needle", root.url.path]) == [
            "\(root.path("keep")):needle",
        ])
        #expect(pathBasenames(try run(["--sort", "path", "--files", "-g", "\\#secret", root.url.path])) == ["#secret"])
        #expect(pathBasenames(try run(["--sort", "path", "--files", "-g", "\\!bang", root.url.path])) == ["!bang"])
    }

    @Test("warns when filters leave nothing searched")
    func warnsWhenFiltersLeaveNothingSearched() throws {
        let root = try TemporaryDirectory()
        try root.write("ignored-dir/**\n", to: ".ignore")
        try root.createDirectory("ignored-dir")
        try root.write("needle\n", to: "ignored-dir/foo.txt")

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--no-messages", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--debug", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.contains { $0.contains("DEBUG|ignore::walk|") && $0.contains("ignored-dir") && $0.contains("Ignore(IgnoreMatch(Gitignore(Glob") })

        let implicit = try TemporaryDirectory()
        try implicit.write("*\n", to: ".ignore")
        try implicit.write("needle\n", to: "file.txt")
        let originalDirectory = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalDirectory) }
        #expect(FileManager.default.changeCurrentDirectoryPath(implicit.url.path))

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["needle"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == [
            "rg: No files were searched, which means ripgrep probably applied a filter you didn't expect.",
            "Running with --debug will show why files are being skipped.",
        ])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-q", "needle"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == [
            "rg: No files were searched, which means ripgrep probably applied a filter you didn't expect.",
            "Running with --debug will show why files are being skipped.",
        ])
    }

    @Test("honors parent ignore files and unrestricted levels")
    func honorsParentIgnoreFilesAndUnrestrictedLevels() throws {
        let parent = try TemporaryDirectory()
        try parent.write("skip.txt\n", to: ".rgignore")
        try parent.write("needle\n", to: "sub/keep.txt")
        try parent.write("needle\n", to: "sub/skip.txt")

        #expect(pathBasenames(try run(["needle", parent.path("sub")])) == ["keep.txt"])
        #expect(Set(pathBasenames(try run(["--no-ignore-parent", "needle", parent.path("sub")]))) == Set([
            "keep.txt",
            "skip.txt",
        ]))

        let explicitRoot = try TemporaryDirectory()
        try explicitRoot.createDirectory("a/b")
        try explicitRoot.write("b\n", to: "a/.ignore")
        try explicitRoot.write("needle\n", to: "a/b/kept")
        let originalDirectory = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalDirectory) }
        #expect(FileManager.default.changeCurrentDirectoryPath(explicitRoot.url.path))
        #expect(try run(["--files", "a/b"]) == ["a/b/kept"])
        #expect(try run(["needle", "a/b"]) == ["a/b/kept:needle"])
        #expect(try runAllowingNoMatch(["--files", "a"]) == [])

        let nested = try TemporaryDirectory()
        try nested.createDirectory(".git")
        try nested.write("skip.txt\n", to: ".gitignore")
        try nested.write("rgskip.txt\n", to: ".rgignore")
        try nested.createDirectory("repo/.git")
        try nested.write("needle\n", to: "repo/bar/keep.txt")
        try nested.write("needle\n", to: "repo/bar/skip.txt")
        try nested.write("needle\n", to: "repo/bar/rgskip.txt")

        #expect(Set(pathBasenames(try run(["needle", nested.path("repo/bar")]))) == Set([
            "keep.txt",
            "skip.txt",
        ]))

        let nestedFileMarker = try TemporaryDirectory()
        try nestedFileMarker.createDirectory(".git")
        try nestedFileMarker.write("skip.txt\n", to: ".gitignore")
        try nestedFileMarker.write("", to: "repo/.git")
        try nestedFileMarker.write("needle\n", to: "repo/bar/keep.txt")
        try nestedFileMarker.write("needle\n", to: "repo/bar/skip.txt")
        #expect(Set(pathBasenames(try run(["needle", nestedFileMarker.path("repo/bar")]))) == Set([
            "keep.txt",
            "skip.txt",
        ]))

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

    @Test("honors filesize and case insensitive glob filters")
    func honorsFilesizeAndCaseInsensitiveGlobFilters() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("needle \(String(repeating: "x", count: 100))\n", to: "big.txt")
        try root.write("needle\n", to: "UPPER.TXT")
        try root.write("upper.txt\n", to: ".ignore")

        #expect(Set(pathBasenames(try run(["--max-filesize", "10", "needle", root.url.path]))) == Set([
            "keep.txt",
            "UPPER.TXT",
        ]))
        #expect(Set(pathBasenames(try run(["--max-filesize", "1K", "needle", root.url.path]))) == Set([
            "UPPER.TXT",
            "big.txt",
            "keep.txt",
        ]))
        #expect(try run(["--max-filesize", "10", "needle", root.path("big.txt")]) == [
            "needle \(String(repeating: "x", count: 100))",
        ])

        let oversized = try TemporaryDirectory()
        try oversized.write("needle \(String(repeating: "x", count: 100))\n", to: "large.txt")
        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--max-filesize", "10", "needle", oversized.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--max-filesize", "45k", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: error parsing flag --max-filesize: invalid size: invalid format for size '45k', which should be a non-empty sequence of digits followed by an optional 'K', 'M' or 'G' suffix"])

        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--max-filesize=34359738368G", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(errors == ["rg: error parsing flag --max-filesize: invalid size: size too big in '34359738368G'"])

        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--max-filesize=999999999999999999999999999999999G", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(errors == ["rg: error parsing flag --max-filesize: invalid size: invalid integer found in size '999999999999999999999999999999999G': number too large to fit in target type"])

        #expect(Set(pathBasenames(try run([
            "--no-ignore",
            "-g",
            "*.txt",
            "needle",
            root.url.path,
        ]))) == Set(["big.txt", "keep.txt"]))
        #expect(Set(pathBasenames(try run([
            "--no-ignore",
            "--glob-case-insensitive",
            "-g",
            "*.txt",
            "needle",
            root.url.path,
        ]))) == Set(["UPPER.TXT", "big.txt", "keep.txt"]))
        #expect(Set(pathBasenames(try run([
            "--no-ignore",
            "--iglob",
            "*.txt",
            "needle",
            root.url.path,
        ]))) == Set(["UPPER.TXT", "big.txt", "keep.txt"]))
        #expect(Set(pathBasenames(try run([
            "--ignore-file-case-insensitive",
            "needle",
            root.url.path,
        ]))) == Set(["big.txt", "keep.txt"]))

        let braceRoot = try TemporaryDirectory()
        try braceRoot.createDirectory(".git")
        try braceRoot.write("", to: "lock")
        try braceRoot.write("", to: "bar.py")
        try braceRoot.write("", to: ".git/packed-refs")
        try braceRoot.write("", to: ".git/description")
        #expect(try run([
            "--no-ignore",
            "--hidden",
            "--follow",
            "--files",
            "--glob",
            "!{.git,node_modules,plugged}/**",
            "--glob",
            "*.{js,json,php,md,styl,scss,sass,pug,html,config,py,cpp,c,go,hs}",
            braceRoot.url.path,
        ]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["bar.py"])
    }

    @Test("honors custom ignore file and override globs")
    func honorsCustomIgnoreFileAndOverrideGlobs() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.swift")
        try root.write("needle\n", to: "skip.txt")
        try root.write("skip.txt\n", to: "ignore.txt")

        #expect(pathBasenames(try run(["--ignore-file", root.path("ignore.txt"), "needle", root.url.path])) == ["keep.swift"])
        let explicitCaseRoot = try TemporaryDirectory()
        try explicitCaseRoot.write("needle\n", to: "keep.txt")
        try explicitCaseRoot.write("needle\n", to: "UPPER.TXT")
        try explicitCaseRoot.write("*.TXT\n", to: "case.ignore")
        #expect(Set(pathBasenames(try run([
            "--ignore-file",
            explicitCaseRoot.path("case.ignore"),
            "--ignore-file-case-insensitive",
            "needle",
            explicitCaseRoot.url.path,
        ]))) == Set(["keep.txt"]))
        #expect(pathBasenames(try run(["-g", "*.swift", "needle", root.url.path])) == ["keep.swift"])
        #expect(pathBasenames(try run(["-g*.swift", "needle", root.url.path])) == ["keep.swift"])
        #expect(pathBasenames(try run(["-g", "!skip.txt", "needle", root.url.path])) == ["keep.swift"])
        #expect(pathBasenames(try run(["-g!skip.txt", "needle", root.url.path])) == ["keep.swift"])
        #expect(pathBasenames(try run([
            "--iglob",
            "!*.TXT",
            "needle",
            root.url.path,
        ])) == ["keep.swift"])
        try root.createDirectory("sub")
        try root.write("needle\n", to: "sub/nested.txt")
        let originalDirectory = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalDirectory) }
        #expect(FileManager.default.changeCurrentDirectoryPath(root.url.path))
        #expect(try run([
            "--sort",
            "path",
            "-g",
            "sub/**",
            "needle",
            "sub",
        ]) == ["sub/nested.txt:needle"])
        #expect(try runAllowingNoMatch([
            "--sort",
            "path",
            "-g",
            "sub/**",
            "needle",
            root.url.path,
        ]) == [])
        #expect(try run([
            "--sort",
            "path",
            "-g",
            "**/sub/**",
            "needle",
            root.url.path,
        ]) == ["\(root.path("sub/nested.txt")):needle"])
        #expect(pathBasenames(try run([
            "--sort",
            "path",
            "-g",
            "*.txt",
            "-g",
            "!sub/*",
            "needle",
            root.url.path,
        ])) == ["skip.txt", "nested.txt"])

        let overrideDirectoryRoot = try TemporaryDirectory()
        try overrideDirectoryRoot.createDirectory(".hidden")
        try overrideDirectoryRoot.write("needle\n", to: ".hidden/child.txt")
        try overrideDirectoryRoot.write("needle\n", to: ".hidden.txt")
        #expect(try runAllowingNoMatch(["-g", ".hidden", "needle", overrideDirectoryRoot.url.path]) == [])
        #expect(try runAllowingNoMatch(["--files", "-g", ".hidden", overrideDirectoryRoot.url.path]) == [])
        #expect(pathBasenames(try run([
            "-g",
            ".hidden.txt",
            "needle",
            overrideDirectoryRoot.url.path,
        ])) == [".hidden.txt"])

        let explicitScope = try TemporaryDirectory()
        try explicitScope.createDirectory("vendor/src")
        try explicitScope.createDirectory("keep")
        try explicitScope.write("needle\n", to: "root.txt")
        try explicitScope.write("needle\n", to: "vendor/src/lib.rs")
        try explicitScope.write("needle\n", to: "keep/file.log")
        try explicitScope.write("needle\n", to: "temp.tmp")
        try explicitScope.write("needle\n", to: "important.tmp")
        try explicitScope.write("*.tmp\n!important.tmp\n/vendor/\nkeep/*.log\n", to: "ignore.txt")
        #expect(pathBasenames(try run([
            "--sort",
            "path",
            "--ignore-file",
            explicitScope.path("ignore.txt"),
            "needle",
            explicitScope.url.path,
        ])) == [
            "important.tmp",
            "file.log",
            "root.txt",
            "lib.rs",
        ])

        try root.createDirectory("ignore-dir")
        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--ignore-file", root.path("ignore-dir"), "needle", root.path("keep.swift")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output == ["needle"])
        #expect(errors == ["rg: \(root.path("ignore-dir")): line 1: Is a directory (os error 21)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--ignore-file", root.path("missing-ignore"), "needle", root.path("keep.swift")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output == ["needle"])
        #expect(errors == ["rg: \(root.path("missing-ignore")): No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--ignore-file", "missing-ignore", "needle", root.path("keep.swift")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output == ["needle"])
        #expect(errors == ["rg: missing-ignore: No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--ignore-file", "missing-ignore", "."],
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            stdin: "",
            standardInputIsReadable: true
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors == ["rg: missing-ignore: No such file or directory (os error 2)"])

        let globstarRoot = try TemporaryDirectory()
        try globstarRoot.createDirectory(".git")
        try globstarRoot.write("**/**/*", to: ".gitignore")
        try globstarRoot.createDirectory("a")
        try globstarRoot.write("needle\n", to: "a/foo")
        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["needle", globstarRoot.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)
        #expect(pathBasenames(try run(["--no-ignore", "needle", globstarRoot.url.path])) == ["foo"])
    }

    @Test("filters by built in file types")
    func filtersByBuiltInFileTypes() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "Sources/main.swift")
        try root.write("needle\n", to: "Sources/main.rs")
        try root.write("needle\n", to: "README.md")
        try root.write("needle\n", to: ".hidden.swift")
        try root.createDirectory(".hidden-directory")
        try root.write("needle\n", to: ".hidden-directory/inside.swift")

        #expect(pathBasenames(try run(["--sort", "path", "-tswift", "needle", root.url.path])) == [
            ".hidden.swift",
            "main.swift",
        ])
        #expect(pathBasenames(try run(["-trust", "needle", root.url.path])) == ["main.rs"])
        #expect(Set(pathBasenames(try run(["-T", "rust", "needle", root.url.path]))) == Set(["README.md", "main.swift"]))
        #expect(pathBasenames(try run(["--sort", "path", "-T", "rust", "-t", "rust", "needle", root.url.path])) == ["main.rs"])
        #expect(pathBasenames(try run(["--sort", "path", "-T", "all", "-t", "rust", "needle", root.url.path])) == ["main.rs"])
        #expect(pathBasenames(try run(["--sort", "path", "-tall", "-Tmd", "needle", root.url.path])) == [
            ".hidden.swift",
            "main.rs",
            "main.swift",
        ])
        #expect(pathBasenames(try run(["--sort", "path", "-T", "rust", "-t", "all", "needle", root.url.path])) == [
            ".hidden.swift",
            "README.md",
            "main.rs",
            "main.swift",
        ])
        #expect(pathBasenames(try run(["--sort", "path", "-tmd", "-g", "*.swift", "needle", root.url.path])) == [
            ".hidden.swift",
            "main.swift",
        ])

        try root.write("needle\n", to: "OnlyMarkdown/README.md")
        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["-Tmd", "needle", root.path("OnlyMarkdown")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)
    }

    @Test("supports type add clear include and list")
    func supportsTypeAddClearIncludeAndList() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "one.foo")
        try root.write("needle\n", to: "one.txt")
        try root.write("needle\n", to: "two.swift")
        try root.write("needle\n", to: "three.rs")

        #expect(pathBasenames(try run(["--sort", "path", "--type-add", "foo:*.foo", "-tfoo", "needle", root.url.path])) == ["one.foo"])
        #expect(pathBasenames(try run(["--sort", "path", "-tfoo", "--type-add", "foo:*.foo", "needle", root.url.path])) == ["one.foo"])
        #expect(pathBasenames(try run(["--sort", "path", "-Tfoo", "--type-add", "foo:*.foo", "needle", root.url.path])) == [
            "one.txt",
            "three.rs",
            "two.swift",
        ])
        #expect(Set(pathBasenames(try run([
            "--type-add", "src:include:swift,rust",
            "-tsrc",
            "needle",
            root.url.path,
        ]))) == Set(["three.rs", "two.swift"]))
        #expect(pathBasenames(try run([
            "--type-clear", "swift",
            "--type-add", "swift:*.foo",
            "-tswift",
            "needle",
            root.url.path,
        ])) == ["one.foo"])

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--type-clear", "md", "-tmd", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: unrecognized file type: md"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--type-clear", "rust", "-t", "rust", "needle"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            standardInputIsReadable: true
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: unrecognized file type: rust"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--type-add", "bad-definition", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: invalid definition (format is type:glob, e.g., html:*.html)"])

        for invalidTypeDefinition in ["foo:", ":*.foo", "foo:include:", "foo:include:nope", "foo:include:rust,"] {
            output = []
            errors = []
            exitCode = RipgrepCLI.run(
                arguments: ["--type-add", invalidTypeDefinition, "needle", root.url.path],
                stdout: { output.append($0) },
                stderr: { errors.append($0) }
            )
            #expect(exitCode == 2)
            #expect(output.isEmpty)
            #expect(errors == ["rg: invalid definition (format is type:glob, e.g., html:*.html)"])
        }

        let typeList = try run(["--type-add", "foo:*.foo", "--type-list"])
        #expect(typeList.contains("foo: *.foo"))
        #expect(typeList.contains("rust: *.rs"))
        #expect(typeList.contains("swift: *.swift"))
    }

    @Test("searches provided stdin")
    func searchesProvidedStdin() throws {
        var output: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["-n", "needle", "-"],
            stdout: { output.append($0) },
            stdin: "hay\nneedle\n"
        )

        #expect(exitCode == 0)
        #expect(output == ["2:needle"])

        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "file.txt")
        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["-H", "-n", "needle", "-", root.path("file.txt")],
            stdout: { output.append($0) },
            stdin: "needle\n"
        )

        #expect(exitCode == 0)
        #expect(output == [
            "<stdin>:1:needle",
            "\(root.path("file.txt")):1:needle",
        ])

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["-H", "-n", "needle", root.path("file.txt"), "-"],
            stdout: { output.append($0) },
            stdin: "needle\n"
        )
        #expect(exitCode == 0)
        #expect(output == [
            "\(root.path("file.txt")):1:needle",
            "<stdin>:1:needle",
        ])

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["-H", "needle", root.path("file.txt"), "-", root.path("file.txt")],
            stdout: { output.append($0) },
            stdin: "needle\n"
        )
        #expect(exitCode == 0)
        #expect(output == [
            "\(root.path("file.txt")):needle",
            "<stdin>:needle",
            "\(root.path("file.txt")):needle",
        ])

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files-without-match", "nomatch", "-", root.path("file.txt"), "-"],
            stdout: { output.append($0) },
            stdin: "needle\n"
        )
        #expect(exitCode == 0)
        #expect(output == [
            "<stdin>",
            "\(root.path("file.txt"))",
            "<stdin>",
        ])

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files-without-match", "needle", "-", root.path("file.txt"), "-"],
            stdout: { output.append($0) },
            stdin: "needle\n"
        )
        #expect(exitCode == 0)
        #expect(output == ["<stdin>"])

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["--sort", "path", "-H", "needle", "-", root.path("file.txt")],
            stdout: { output.append($0) },
            stdin: "needle stdin\n"
        )
        #expect(exitCode == 0)
        #expect(output == [
            "<stdin>:needle stdin",
            "\(root.path("file.txt")):needle",
        ])

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["--sortr", "path", "-H", "needle", "-", root.path("file.txt")],
            stdout: { output.append($0) },
            stdin: "needle stdin\n"
        )
        #expect(exitCode == 0)
        #expect(output == [
            "<stdin>:needle stdin",
            "\(root.path("file.txt")):needle",
        ])

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["--json", "needle"],
            stdout: { output.append($0) },
            stdin: "needle\n"
        )
        #expect(exitCode == 0)
        let jsonMessages = try output.map(jsonObject)
        let beginData = jsonMessages[0]["data"] as? [String: Any]
        let beginPath = beginData?["path"] as? [String: String]
        #expect(beginPath?["text"] == "<stdin>")

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["-c", "needle", "-"],
            stdout: { output.append($0) },
            stdin: "pre\nneedle before\n\0binary needle after\n"
        )
        #expect(exitCode == 0)
        #expect(output == ["2"])

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["--json", "needle", "-"],
            stdout: { output.append($0) },
            stdin: "pre\nneedle before\n\0binary needle after\n"
        )
        #expect(exitCode == 0)
        let stdinJsonMessages = try output.map(jsonObject)
        let stdinJsonMatches = stdinJsonMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        #expect(stdinJsonMatches.count == 2)
        let stdinJsonSecondLines = stdinJsonMatches[1]["lines"] as? [String: String]
        let stdinJsonSecondSubmatches = stdinJsonMatches[1]["submatches"] as? [[String: Any]]
        #expect(stdinJsonSecondLines?["text"] == "binary needle after\n")
        #expect(stdinJsonSecondSubmatches?.first?["start"] as? Int == 7)
    }

    @Test("searches piped stdin for implicit default path")
    func searchesPipedStdinForImplicitDefaultPath() throws {
        let root = try TemporaryDirectory()
        try root.createDirectory("-")
        try root.write("{}", to: "a.json")
        try root.write("some text", to: "a.txt")

        let originalDirectory = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalDirectory) }
        #expect(FileManager.default.changeCurrentDirectoryPath(root.url.path))

        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["a"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            stdin: "a.json\na.txt\n"
        )

        #expect(exitCode == 0)
        #expect(output == ["a.json", "a.txt"])
        #expect(errors.isEmpty)
    }

    @Test("searches default directory when stdin is not readable")
    func searchesDefaultDirectoryWhenStdinIsNotReadable() throws {
        let root = try TemporaryDirectory()
        try root.write("\n", to: "test")

        let originalDirectory = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalDirectory) }
        #expect(FileManager.default.changeCurrentDirectoryPath(root.url.path))

        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["x?", "--crlf", "--color", "always"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output == ["\u{1B}[0m\u{1B}[35mtest\u{1B}[0m:\r"])
        #expect(errors.isEmpty)
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

    @Test("suppresses non fatal file messages")
    func suppressesNonFatalFileMessages() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "ok.txt")
        let missingPath = root.path("missing.txt")

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["needle", root.path("ok.txt"), missingPath],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 2)
        #expect(output == ["\(root.path("ok.txt")):needle"])
        #expect(errors == ["rg: \(missingPath): No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["needle", missingPath],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: \(missingPath): IO error for operation on \(missingPath): No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files", missingPath],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: \(missingPath): IO error for operation on \(missingPath): No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--files", missingPath, root.path("ok.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 2)
        #expect(output == [root.path("ok.txt")])
        #expect(errors == ["rg: \(missingPath): No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--sort", "path", "needle", root.path("ok.txt"), missingPath],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 2)
        #expect(output == ["\(root.path("ok.txt")):needle"])
        #expect(errors == ["rg: \(missingPath): IO error for operation on \(missingPath): No such file or directory (os error 2)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--no-messages", "needle", root.path("ok.txt"), missingPath],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 2)
        #expect(output == ["\(root.path("ok.txt")):needle"])
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-q", "needle", root.path("ok.txt"), missingPath],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output.isEmpty)
        #expect(errors == ["rg: \(missingPath): No such file or directory (os error 2)"])

        let relativeRoot = try TemporaryDirectory()
        try relativeRoot.write("needle\n", to: "ok.txt")
        let originalDirectory = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalDirectory) }
        #expect(FileManager.default.changeCurrentDirectoryPath(relativeRoot.url.path))

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-l", "needle", "ok.txt", "missing.txt"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 2)
        #expect(output == ["ok.txt"])
        #expect(errors == ["rg: missing.txt: No such file or directory (os error 2)"])
    }

    @Test("prints help")
    func printsHelp() {
        var output: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["-h"],
            stdout: { output.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output.count == 1)
        #expect(output[0].contains("ripgrep 15.1.0 (rev 4519153e5e)"))
        #expect(output[0].contains("Use -h for short descriptions and --help for more details."))
        #expect(output[0].contains("-i, --ignore-case"))
        #expect(!output[0].contains("This flag searches case insensitively."))

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["-nh"],
            stdout: { output.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.count == 1)
        #expect(output[0].contains("Use -h for short descriptions and --help for more details."))

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["--help"],
            stdout: { output.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output.count == 1)
        #expect(output[0].contains("ripgrep 15.1.0 (rev 4519153e5e)"))
        #expect(output[0].contains("--files"))
        #expect(output[0].contains("--maxdepth"))
        #expect(output[0].contains("--no-json"))
        #expect(output[0].contains("--no-ignore-vcs"))
        #expect(output[0].contains("--passthrough"))
        #expect(output[0].contains("--no-search-zip"))
        #expect(output[0].contains("When this flag is provided, all patterns will be searched case"))
    }

    @Test("prints version from short and long flags")
    func printsVersionFromShortAndLongFlags() {
        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["-V"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(errors.isEmpty)
        #expect(output == ["ripgrep 15.1.0 (rev 4519153e5e)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-nV"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(errors.isEmpty)
        #expect(output == ["ripgrep 15.1.0 (rev 4519153e5e)"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--version"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(errors.isEmpty)
        #expect(output.count == 1)
        let versionDetails = output.joined(separator: "\n")
        #expect(versionDetails.contains("ripgrep 15.1.0 (rev 4519153e5e)"))
        #expect(versionDetails.contains("simd(compile):+NEON"))
        #expect(versionDetails.contains("simd(runtime):+NEON"))
        #expect(
            versionDetails.contains("features:-pcre2") ||
                versionDetails.contains("features:+pcre2")
        )
        #expect(
            versionDetails.contains("PCRE2 is not available in this build of ripgrep.") ||
                versionDetails.contains("PCRE2") && versionDetails.contains("is available")
        )
    }

    @Test("generates man pages and completions")
    func generatesManPagesAndCompletions() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "generate.txt")

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--generate", "man"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(errors.isEmpty)
        let manOutput = output.joined(separator: "\n")
        #expect(manOutput.contains(".TH RG 1"))
        #expect(manOutput.contains("\\fB\\-i\\fP, \\fB\\-\\-ignore\\-case\\fP"))

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--generate=complete-bash"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(errors.isEmpty)
        let bashOutput = output.joined(separator: "\n")
        #expect(bashOutput.contains("complete -F _rg -o bashdefault -o default rg"))
        #expect(bashOutput.contains("--generate"))
        #expect(bashOutput.contains("--line-regexp"))
        #expect(bashOutput.contains("--context-separator"))
        #expect(bashOutput.contains("--no-json"))
        #expect(bashOutput.contains("--max-depth"))

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--generate", "complete-bash", "--generate=man"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(errors.isEmpty)
        #expect(output.joined(separator: "\n").contains(".TH RG 1"))

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--generate", "man", "-l", "needle", root.path("generate.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(errors.isEmpty)
        #expect(output == [root.path("generate.txt")])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--generate", "bogus"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: error parsing flag --generate: choice 'bogus' is unrecognized"])
    }

}
