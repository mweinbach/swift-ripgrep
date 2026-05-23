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
        #expect(try run(["-F", "--no-fixed-strings", "abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["--no-fixed-strings", "-F", "abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["-w", "abc", root.path("patterns.txt")]) == ["abc.123", "abc", "abc def"])
        #expect(try run(["-x", "abc", root.path("patterns.txt")]) == ["abc"])
        #expect(try run(["-w", "-x", "abc", root.path("patterns.txt")]) == ["abc"])
        #expect(try run(["-x", "-w", "abc", root.path("patterns.txt")]) == ["abc.123", "abc", "abc def"])
    }

    @Test("honors regex engine flag ordering")
    func honorsRegexEngineFlagOrdering() throws {
        let root = try TemporaryDirectory()
        try root.write("ab\nac\n", to: "engine.txt")

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["-o", #"(?<=a)b"#, root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors.first?.contains("look-around") == true)

        #expect(try run(["-o", "--engine=auto", #"(?<=a)b"#, root.path("engine.txt")]) == ["b"])
        #expect(try run(["-o", "-P", #"(?<=a)b"#, root.path("engine.txt")]) == ["b"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-o", "-P", "--no-pcre2", #"(?<=a)b"#, root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors.first?.contains("look-around") == true)

        #expect(try run(["-o", "--engine=default", "--auto-hybrid-regex", #"(?<=a)b"#, root.path("engine.txt")]) == ["b"])
    }

    @Test("accepts runtime resource flags")
    func acceptsRuntimeResourceFlags() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "runtime.txt")

        #expect(try run([
            "--dfa-size-limit=0",
            "--regex-size-limit",
            "1K",
            "-j0",
            "--mmap",
            "--no-mmap",
            "--line-buffered",
            "--block-buffered",
            "needle",
            root.path("runtime.txt"),
        ]) == ["needle"])

        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--threads", "many", "needle", root.path("runtime.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["error: invalid thread count 'many'"])
    }

    @Test("enforces regex size limit")
    func enforcesRegexSizeLimit() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "limit.txt")

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--regex-size-limit=0", "needle", root.path("limit.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors.first?.contains("compiled regex exceeds size limit of 0") == true)

        #expect(try run(["--regex-size-limit=1K", "needle", root.path("limit.txt")]) == ["needle"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--regex-size-limit=4", "-e", "abc", "-e", "def", root.path("limit.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors.first?.contains("compiled regex exceeds size limit of 4") == true)
    }

    @Test("honors no unicode regex and literal semantics")
    func honorsNoUnicodeSemantics() throws {
        let root = try TemporaryDirectory()
        try root.write("café\nπ\n_\n", to: "classes.txt")
        try root.write("éx\nxé\nx\n", to: "words.txt")
        try root.write("Σ\nσ\n", to: "casefold.txt")

        #expect(try run(["-o", #"\w+"#, root.path("classes.txt")]) == ["café", "π", "_"])
        #expect(try run(["--no-unicode", "-o", #"\w+"#, root.path("classes.txt")]) == ["caf", "_"])
        #expect(try run(["-w", "x", root.path("words.txt")]) == ["x"])
        #expect(try run(["-won", "x", root.path("words.txt")]) == ["3:x"])
        #expect(try run(["--no-unicode", "-w", "x", root.path("words.txt")]) == ["éx", "xé", "x"])
        #expect(try run(["-F", "-i", "σ", root.path("casefold.txt")]) == ["Σ", "σ"])
        #expect(try run(["--no-unicode", "-F", "-i", "σ", root.path("casefold.txt")]) == ["σ"])
        #expect(try run(["--no-unicode", "--unicode", "-o", #"\w+"#, root.path("classes.txt")]) == ["café", "π", "_"])
        #expect(try run(["--no-pcre2-unicode", "--pcre2-unicode", "-o", #"\w+"#, root.path("classes.txt")]) == ["café", "π", "_"])
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

        #expect(try run(["-e", "alpha", "-e", "gamma", root.path("words.txt")]) == ["alpha", "gamma"])
        #expect(try run(["-f", root.path("patterns"), root.path("words.txt")]) == ["alpha", "gamma"])
        #expect(try run(["-f\(root.path("patterns"))", root.path("words.txt")]) == ["alpha", "gamma"])
        #expect(try run(["-vf", root.path("patterns"), root.path("words.txt")]) == ["beta"])

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
            "\(root.path("one.txt"))",
            "2:needle here",
            "3:needle there",
        ])
        #expect(try run(["-H", "-c", "needle", root.path("one.txt")]) == [
            "\(root.path("one.txt")):2",
        ])
        #expect(try run(["-l", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["one.txt"])
        #expect(try run(["--files-without-match", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["two.txt"])

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

        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--path-separator", "ø", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors.first?.contains("exactly one byte") == true)
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

        #expect(countBasenames(try run(["-c", "--include-zero", "needle", root.url.path])) == [
            "many.txt:2",
            "none.txt:0",
        ])
        #expect(countBasenames(try run(["--count-matches", "--include-zero", "needle", root.url.path])) == [
            "many.txt:3",
            "none.txt:0",
        ])

        var output: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["-c", "--include-zero", "absent", root.path("none.txt")],
            stdout: { output.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output == ["0"])
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
            "[Omitted long matching line]",
            "[Omitted long matching line]",
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
            "1:7:short needle [... 0 more matches]",
            "2:10:verylong nee [... 0 more matches]",
        ])
        #expect(try run(["-M", "12", "--replace", "PIN", "needle", root.path("columns.txt")]) == [
            "[Omitted long line with 1 match]",
            "[Omitted long line with 1 match]",
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
            "PIN middle PIN [... 1 more match]",
        ])

        try root.write("needle\nthis context line is very long\n", to: "context-columns.txt")
        #expect(try run(["-M", "20", "-A1", "needle", root.path("context-columns.txt")]) == [
            "needle",
            "[Omitted long context line]",
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

    @Test("searches multiline regex matches")
    func searchesMultilineRegexMatches() throws {
        let root = try TemporaryDirectory()
        try root.write("foo\nbar\nbaz\n", to: "multi.txt")
        try root.write("a\nb\nc\na\nb\nc", to: "passthru.txt")
        try root.write("""
        #!/usr/bin/env bash

        zero=one

        a=one

        if true; then
        \ta=(
        \t\ta
        \t\tb
        \t\tc
        \t)
        \ttrue
        fi

        a=two

        b=one
        });
        """, to: "named-replace.txt")
        try root.write("     0123456789abcdefghijklmnopqrstuvwxyz", to: "trim-columns.txt")
        try root.write("xxx\nabc\ndefxxxabc\ndefxxx\nxxx", to: "overlap1.txt")
        try root.write("xxx\nabc\ndefabc\ndefxxx\nxxx", to: "overlap2.txt")
        try root.write("a\nbaz\nabc\n", to: "anchors.txt")
        try root.write("foobar\nfoobar\nfoo quux", to: "vimgrep.txt")

        #expect(try run(["-n", "-U", #"foo\nbar"#, root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
        ])
        #expect(try run(["-U", "-o", #"foo\nbar"#, root.path("multi.txt")]) == [
            "foo",
            "bar",
        ])
        #expect(try run(["-n", "-U", "-o", #"foo[\s\S]+?bar"#, root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
        ])
        #expect(try run([
            "--no-line-number",
            "--no-filename",
            "-U",
            "--max-count=1",
            "--passthru",
            "--replace=B",
            "b",
            root.path("passthru.txt"),
        ]) == [
            "a",
            "B",
            "c",
            "a",
            "b",
            "c",
        ])
        #expect(try runAllowingNoMatch(["-n", "-U", "foo.bar", root.path("multi.txt")]) == [])
        #expect(try run(["-n", "-U", "--multiline-dotall", "foo.bar", root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
        ])
        #expect(try run(["-n", "-U", #"abc\ndef"#, root.path("overlap1.txt")]) == [
            "2:abc",
            "3:defxxxabc",
            "4:defxxx",
        ])
        #expect(try run(["-n", "-U", #"abc\ndef"#, root.path("overlap2.txt")]) == [
            "2:abc",
            "3:defabc",
            "4:defxxx",
        ])
        #expect(try run(["-n", "-U", "-C1", #"abc\ndef"#, root.path("overlap2.txt")]) == [
            "1-xxx",
            "2:abc",
            "3:defabc",
            "4:defxxx",
            "5-xxx",
        ])
        #expect(try run(["-U", "^baz", root.path("anchors.txt")]) == ["baz"])
        #expect(try runAllowingNoMatch(["-U", #"(?-m)^baz"#, root.path("anchors.txt")]) == [])
        #expect(try runAllowingNoMatch(["-U", #"\Abaz"#, root.path("anchors.txt")]) == [])
        #expect(try run(["-U", "--vimgrep", #"foobar\nfoobar\nfoo|quux"#, root.path("vimgrep.txt")]) == [
            "\(root.path("vimgrep.txt")):1:1:foobar",
            "\(root.path("vimgrep.txt")):3:5:foo quux",
        ])
        #expect(try run([
            "-n",
            "-U",
            "-o",
            "--replace",
            "${value}",
            #"^(?P<indent>\s*)a=(?P<value>(?ms:[(].*?[)])|.*?)$"#,
            root.path("named-replace.txt"),
        ]) == [
            "4:one",
            "8:(",
            "9:\t\ta",
            "10:\t\tb",
            "11:\t\tc",
            "12:\t)",
            "15:two",
        ])
        #expect(try run([
            "-U",
            "--trim",
            "--max-columns-preview",
            "-M8",
            "-o",
            "--no-filename",
            #".*a\n?bc.*"#,
            root.path("trim-columns.txt"),
        ]) == [
            "01234567 [... 0 more matches]",
        ])
        #expect(try run([
            "-U",
            "--trim",
            "--max-columns-preview",
            "-M8",
            "--vimgrep",
            "--no-filename",
            #".*a\n?bc.*"#,
            root.path("trim-columns.txt"),
        ]) == [
            "1:1:01234567 [... 0 more matches]",
        ])

        let output = try run(["--json", "-U", #"foo\nbar"#, root.path("multi.txt")])
        let messages = try output.map(jsonObject)
        let match = messages.first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let lines = match?["lines"] as? [String: String]
        let submatch = (match?["submatches"] as? [[String: Any]])?.first
        #expect(lines?["text"] == "foo\nbar\n")
        #expect(match?["line_number"] as? Int == 1)
        #expect(submatch?["start"] as? Int == 0)
        #expect(submatch?["end"] as? Int == 7)
    }

    @Test("honors CRLF anchor mode")
    func honorsCRLFAnchorMode() throws {
        let root = try TemporaryDirectory()
        try root.write("foo\r\nbar\rquux\nbaz\r\n", to: "crlf.txt")

        #expect(try runAllowingNoMatch(["-n", "foo$", root.path("crlf.txt")]) == [])
        #expect(try run(["--crlf", "-n", "foo$", root.path("crlf.txt")]) == [
            "1:foo\r",
        ])
        #expect(try run(["--crlf", "-n", "bar$", root.path("crlf.txt")]) == [
            "2:bar\rquux",
        ])
        #expect(try run(["--crlf", "-n", "^quux", root.path("crlf.txt")]) == [
            "2:bar\rquux",
        ])
        #expect(try run(["--crlf", "-x", "foo", root.path("crlf.txt")]) == [
            "foo\r",
        ])
        #expect(try runAllowingNoMatch(["--crlf", "--null-data", "-n", "foo$", root.path("crlf.txt")]) == [])
        #expect(try run(["--null-data", "--crlf", "-n", "foo$", root.path("crlf.txt")]) == [
            "1:foo\r",
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

        try root.write("--replace\n\"X Y\"\n", to: "ripgreprc")
        #expect(try run(["Needle", root.path("a.txt")], environment: environment) == [
            "\"X Y\"",
        ])
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
        #expect(Set(pathBasenames(try run([
            "--pre",
            script,
            "--pre-glob",
            "*.md",
            "needle",
            root.url.path,
        ]))) == Set(["doc.md", "plain.txt", "pre.sh"]))
        #expect(try run(["--pre", script, "--pre", "", "needle", root.path("plain.txt")]) == [
            "needle",
        ])
        #expect(try run(["--pre", script, "--no-pre", "needle", root.path("plain.txt")]) == [
            "needle",
        ])

        try root.write("""
        #!/bin/sh
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
        #expect(errors.first?.contains("preprocessor command failed") == true)
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
        #expect(try run(["--replace", "${0}_${1}_${2}${3}_$$", #"([a-z]+)(\d+)"#, root.path("replace.txt")]) == [
            "abc123_abc_123_$ def456_def_456_$",
        ])
        #expect(try run(["--replace", "$word:${digits}$missing", #"(?P<word>[a-z]+)(?P<digits>\d+)"#, root.path("replace.txt")]) == [
            "abc:123 def:456",
        ])
        #expect(try run(["--replace", "${}_${bad-name}_${1}", #"([a-z]+)\d+"#, root.path("replace.txt")]) == [
            "${}_${bad-name}_abc ${}_${bad-name}_def",
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
        #expect(try run(["--heading", "-n", "needle", root.url.path]) == [
            "\(root.path("a.txt"))",
            "1:  needle one needle",
            "",
            "\(root.path("b.txt"))",
            "1:xx needle",
        ])
    }

    @Test("prints pretty and ANSI color modes")
    func printsPrettyAndANSIColorModes() throws {
        let root = try TemporaryDirectory()
        try root.write("alpha needle beta\nno\n", to: "a.txt")
        try root.write("needle again\n", to: "b.txt")

        let reset = "\u{1B}[0m"
        let green = "\u{1B}[32m"
        let magenta = "\u{1B}[35m"
        let redBold = "\u{1B}[1m\u{1B}[31m"

        #expect(try run(["--color=always", "-n", "needle", root.path("a.txt")]) == [
            "\(reset)\(green)1\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
        ])
        #expect(try run(["--pretty", "--color=never", "needle", root.url.path]) == [
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
        #expect(try run(["--pretty", "needle", root.url.path]) == [
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
        #expect(errors == ["error: choice 'Always' is unrecognized"])
    }

    @Test("prints OSC8 hyperlinks for paths")
    func printsOSC8HyperlinksForPaths() throws {
        let root = try TemporaryDirectory()
        try root.createDirectory("links")
        try root.write("hay\nneedle\n", to: "links/a file.txt")
        let path = root.path("links/a file.txt")
        let encodedPath = path.replacingOccurrences(of: " ", with: "%20")
        let linkedPath = "\u{1B}]8;;grep+://\(encodedPath):2\u{1B}\\\(path)\u{1B}]8;;\u{1B}\\"

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
            "\(linkedPath):2:1:needle",
        ])

        try root.write("#!/bin/sh\nprintf test-host\n", to: "hostname")
        try root.makeExecutable("hostname")
        let hostLinkedPath = "\u{1B}]8;;file://test-host\(encodedPath)\u{1B}\\\(path)\u{1B}]8;;\u{1B}\\"
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

    @Test("prints JSON lines for matches context and summary")
    func printsJSONLines() throws {
        let root = try TemporaryDirectory()
        try root.write("hay\nneedle here\nthere\n", to: "json.txt")
        try root.write(Data("needle\n\0tail\n".utf8), to: "binary.txt")

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
        #expect(stats?["bytes_printed"] as? Int == output.prefix(4).reduce(0) { $0 + $1.utf8.count + 1 })
        #expect(stats?["matched_lines"] as? Int == 1)
        #expect(stats?["matches"] as? Int == 1)

        let summary = messages[5]["data"] as? [String: Any]
        let summaryStats = summary?["stats"] as? [String: Any]
        #expect(summaryStats?["bytes_printed"] as? Int == stats?["bytes_printed"] as? Int)

        let binaryOutput = try run(["--json", "-n", "needle", root.path("binary.txt")])
        let binaryMessages = try binaryOutput.map(jsonObject)
        #expect(binaryMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let binaryEnd = binaryMessages[2]["data"] as? [String: Any]
        #expect(binaryEnd?["binary_offset"] as? Int == 7)

        let binaryOnlyOutput = try run(["--json", "-n", "tail", root.path("binary.txt")])
        let binaryOnlyMessages = try binaryOnlyOutput.map(jsonObject)
        #expect(binaryOnlyMessages.map { $0["type"] as? String } == ["begin", "end", "summary"])
        let binaryOnlyEnd = binaryOnlyMessages[1]["data"] as? [String: Any]
        #expect(binaryOnlyEnd?["binary_offset"] as? Int == 7)
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
        #expect(try run(["--json", "--files", "--no-json", root.url.path]) == [root.path("ordering.txt")])
        #expect(try run(["--json", "-l", "--no-json", "needle", root.path("ordering.txt")]) == [root.path("ordering.txt")])
        #expect(try run(["--color=always", "--json", "--no-json", "needle", root.path("ordering.txt")]) == [
            "\(reset)\(redBold)needle\(reset)",
        ])
    }

    @Test("lists files and honors hidden flag")
    func listsFilesAndHonorsHiddenFlag() throws {
        let root = try TemporaryDirectory()
        try root.write("visible\n", to: "visible.txt")
        try root.write("secret\n", to: ".hidden.txt")

        #expect(try run(["--files", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["visible.txt"])
        #expect(try run(["--files", "--hidden", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == [".hidden.txt", "visible.txt"])

        let whitelisted = try TemporaryDirectory()
        try whitelisted.createDirectory("subdir")
        try whitelisted.write("text\n", to: "subdir/.foo.txt")
        try whitelisted.write("!.foo.txt\n", to: ".ignore")
        #expect(try run(["--files", whitelisted.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == [".foo.txt"])

        var output: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--quiet", "--files", "--glob", "*.txt", root.url.path],
            stdout: { output.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output.isEmpty)

        output = []
        exitCode = RipgrepCLI.run(
            arguments: ["--quiet", "--files", "--glob", "*.md", root.url.path],
            stdout: { output.append($0) }
        )
        #expect(exitCode == 1)
        #expect(output.isEmpty)
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
        #expect(errors.contains { $0.contains("DEBUG|swift-ripgrep::walk|") && $0.contains(".hidden.txt: hidden") })
        #expect(errors.contains { $0.contains("DEBUG|swift-ripgrep::walk|") && $0.contains("skip.log: ignore file") })

        output = []
        errors = []
        let traceExitCode = RipgrepCLI.run(
            arguments: ["--debug", "--trace", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(traceExitCode == 0)
        #expect(errors.contains { $0.contains("DEBUG|swift-ripgrep::walk|") })
    }

    @Test("honors symlink and one file system traversal toggles")
    func honorsSymlinkAndOneFileSystemTraversalToggles() throws {
        let root = try TemporaryDirectory()
        try root.createDirectory("real")
        try root.write("needle\n", to: "real/file.txt")
        try FileManager.default.createSymbolicLink(
            at: root.url.appendingPathComponent("link"),
            withDestinationURL: root.url.appendingPathComponent("real")
        )

        #expect(pathBasenames(try run(["needle", root.url.path])) == ["file.txt"])
        #expect(pathBasenames(try run(["--follow", "needle", root.url.path])) == ["file.txt", "file.txt"])
        #expect(pathBasenames(try run(["--follow", "--no-follow", "needle", root.url.path])) == ["file.txt"])
        #expect(pathBasenames(try run(["--one-file-system", "needle", root.url.path])) == ["file.txt"])
        #expect(pathBasenames(try run(["--one-file-system", "--no-one-file-system", "needle", root.url.path])) == ["file.txt"])
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

    @Test("honors git info exclude and its toggle")
    func honorsGitInfoExcludeAndToggle() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("needle\n", to: "skip.txt")
        try root.write("skip.txt\n", to: ".git/info/exclude")

        #expect(pathBasenames(try run(["needle", root.url.path])) == ["keep.txt"])
        #expect(pathBasenames(try run(["--no-ignore-exclude", "needle", root.url.path])) == ["keep.txt", "skip.txt"])
        #expect(pathBasenames(try run([
            "--no-ignore-exclude",
            "--ignore-exclude",
            "needle",
            root.url.path,
        ])) == ["keep.txt"])
        #expect(pathBasenames(try run(["--no-ignore", "needle", root.url.path])) == ["keep.txt", "skip.txt"])
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
        #expect(pathBasenames(try run([
            "--no-ignore-global",
            "needle",
            root.url.path,
        ], environment: environment)) == ["keep.txt", "skip.txt"])
        #expect(pathBasenames(try run([
            "--no-ignore-global",
            "--ignore-global",
            "needle",
            root.url.path,
        ], environment: environment)) == ["keep.txt"])
        #expect(pathBasenames(try run([
            "--no-ignore",
            "needle",
            root.url.path,
        ], environment: environment)) == ["keep.txt", "skip.txt"])

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

    @Test("honors ignore parse message switches")
    func honorsIgnoreParseMessageSwitches() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("[broken\n", to: ".ignore")

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output == [root.path("keep.txt") + ":needle"])
        #expect(errors.count == 1)
        #expect(errors.first?.contains(".ignore: line 1") == true)
        #expect(errors.first?.contains("unclosed character class") == true)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--no-ignore-messages", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(output == [root.path("keep.txt") + ":needle"])
        #expect(errors.isEmpty)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--no-ignore-messages", "--ignore-messages", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output == [root.path("keep.txt") + ":needle"])
        #expect(errors.count == 1)
    }

    @Test("honors escaped slash in ignore patterns")
    func honorsEscapedSlashInIgnorePatterns() throws {
        let root = try TemporaryDirectory()
        try root.write(#"foo\/"#, to: ".ignore")
        try root.createDirectory("foo")
        try root.write("test\n", to: "foo/bar")

        #expect(try runAllowingNoMatch(["--files", root.url.path]) == [])
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
        #expect(errors == [
            "rg: No files were searched, which means ripgrep probably applied a filter you didn't expect.",
            "Running with --debug will show why files are being skipped.",
        ])

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
        #expect(errors.contains { $0.contains("DEBUG|swift-ripgrep::walk|") && $0.contains("ignored-dir") && $0.contains("ignore file") })
        #expect(errors.suffix(2) == [
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
        #expect(pathBasenames(try run(["--no-ignore-parent", "needle", parent.path("sub")])) == [
            "keep.txt",
            "skip.txt",
        ])

        let nested = try TemporaryDirectory()
        try nested.createDirectory(".git")
        try nested.write("skip.txt\n", to: ".gitignore")
        try nested.write("rgskip.txt\n", to: ".rgignore")
        try nested.createDirectory("repo/.git")
        try nested.write("needle\n", to: "repo/bar/keep.txt")
        try nested.write("needle\n", to: "repo/bar/skip.txt")
        try nested.write("needle\n", to: "repo/bar/rgskip.txt")

        #expect(pathBasenames(try run(["needle", nested.path("repo/bar")])) == [
            "keep.txt",
            "skip.txt",
        ])

        let nestedFileMarker = try TemporaryDirectory()
        try nestedFileMarker.createDirectory(".git")
        try nestedFileMarker.write("skip.txt\n", to: ".gitignore")
        try nestedFileMarker.write("", to: "repo/.git")
        try nestedFileMarker.write("needle\n", to: "repo/bar/keep.txt")
        try nestedFileMarker.write("needle\n", to: "repo/bar/skip.txt")
        #expect(pathBasenames(try run(["needle", nestedFileMarker.path("repo/bar")])) == [
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

    @Test("honors filesize and case insensitive glob filters")
    func honorsFilesizeAndCaseInsensitiveGlobFilters() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\n", to: "keep.txt")
        try root.write("needle \(String(repeating: "x", count: 100))\n", to: "big.txt")
        try root.write("needle\n", to: "UPPER.TXT")
        try root.write("upper.txt\n", to: ".ignore")

        #expect(pathBasenames(try run(["--max-filesize", "10", "needle", root.url.path])) == [
            "UPPER.TXT",
            "keep.txt",
        ])
        #expect(pathBasenames(try run(["--max-filesize", "1K", "needle", root.url.path])) == [
            "UPPER.TXT",
            "big.txt",
            "keep.txt",
        ])
        #expect(try run(["--max-filesize", "10", "needle", root.path("big.txt")]) == [
            "needle \(String(repeating: "x", count: 100))",
        ])

        #expect(pathBasenames(try run([
            "--no-ignore",
            "-g",
            "*.txt",
            "needle",
            root.url.path,
        ])) == ["big.txt", "keep.txt"])
        #expect(pathBasenames(try run([
            "--no-ignore",
            "--glob-case-insensitive",
            "-g",
            "*.txt",
            "needle",
            root.url.path,
        ])) == ["UPPER.TXT", "big.txt", "keep.txt"])
        #expect(pathBasenames(try run([
            "--no-ignore",
            "--iglob",
            "*.txt",
            "needle",
            root.url.path,
        ])) == ["UPPER.TXT", "big.txt", "keep.txt"])
        #expect(pathBasenames(try run([
            "--ignore-file-case-insensitive",
            "needle",
            root.url.path,
        ])) == ["big.txt", "keep.txt"])
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
        #expect(pathBasenames(try run([
            "--iglob",
            "!*.TXT",
            "needle",
            root.url.path,
        ])) == ["keep.swift"])
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
        try root.write(Data("needle\n\0tail\n".utf8), to: "before-nul.dat")

        #expect(try run(["-n", "needle", root.url.path]) == [
            "\(root.path("before-nul.dat")):1:needle",
            #"\#(root.path("before-nul.dat")): WARNING: stopped searching binary file after match (found "\0" byte around offset 7)"#,
        ])
        #expect(try runAllowingNoMatch(["tail", root.url.path]) == [])
        #expect(try run(["needle", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-n", "needle", root.path("before-nul.dat")]) == [
            "1:needle",
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["-n", "tail", root.path("before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["-c", "needle", root.path("before-nul.dat")]) == ["1"])
        #expect(pathBasenames(try run(["--binary", "needle", root.url.path])) == ["before-nul.dat", "before-nul.dat", "bin.dat"])
        var stdinOutput: [String] = []
        var stdinExitCode = RipgrepCLI.run(
            arguments: ["-n", "needle", "-"],
            stdout: { stdinOutput.append($0) },
            stdin: "needle\n\0tail\n"
        )
        #expect(stdinExitCode == 0)
        #expect(stdinOutput == [
            "1:needle",
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])

        stdinOutput = []
        stdinExitCode = RipgrepCLI.run(
            arguments: ["-n", "tail", "-"],
            stdout: { stdinOutput.append($0) },
            stdin: "needle\n\0tail\n"
        )
        #expect(stdinExitCode == 0)
        #expect(stdinOutput == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
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

    @Test("prints version from short and long flags")
    func printsVersionFromShortAndLongFlags() {
        for flag in ["-V", "--version"] {
            var output: [String] = []
            var errors: [String] = []
            let exitCode = RipgrepCLI.run(
                arguments: [flag],
                stdout: { output.append($0) },
                stderr: { errors.append($0) }
            )

            #expect(exitCode == 0)
            #expect(errors.isEmpty)
            #expect(output == ["ripgrep \(RipgrepCLI.version)"])
        }
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
        #expect(output.first?.contains(".TH RG 1") == true)
        #expect(output.first?.contains("--ignore-case") == true)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--generate=complete-bash"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(errors.isEmpty)
        #expect(output.first?.contains("complete -F _rg rg") == true)
        #expect(output.first?.contains("--generate") == true)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--generate", "complete-bash", "--generate=man"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(errors.isEmpty)
        #expect(output.first?.contains(".TH RG 1") == true)

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
        #expect(errors == ["error: choice 'bogus' is unrecognized"])
    }

    @Test("prints detected PCRE2 version")
    func printsDetectedPCRE2Version() throws {
        let root = try TemporaryDirectory()
        try root.write("#!/bin/sh\nprintf '10.99\\n'\n", to: "pcre2-config")
        try root.makeExecutable("pcre2-config")

        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--pcre2-version"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            environment: ["PATH": root.url.path]
        )

        #expect(exitCode == 0)
        #expect(errors.isEmpty)
        #expect(output == ["PCRE2 10.99 is available (JIT availability unknown)"])
    }

    private func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String] {
        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: arguments,
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            environment: environment
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

    private func countBasenames(_ lines: [String]) -> [String] {
        lines.map { line in
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else {
                return line
            }
            return "\(URL(fileURLWithPath: String(pieces[0])).lastPathComponent):\(pieces[1])"
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

    func makeExecutable(_ relativePath: String) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path(relativePath)
        )
    }

    func writeGzip(_ contents: String, to relativePath: String) throws {
        let fileURL = url.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gzip", "-c"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output

        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(contents.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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
