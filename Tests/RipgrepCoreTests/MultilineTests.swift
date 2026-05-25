import Foundation
import Testing
@testable import RipgrepCore

@Suite("Ripgrep multiline parity area", .serialized)
struct MultilineTests {
    @Test("searches multiline regex matches")
    func searchesMultilineRegexMatches() throws {
        let root = try TemporaryDirectory()
        try root.write("foo\nbar\nbaz\n", to: "multi.txt")
        try root.write("foo\nbar\n", to: "multi-final-newline.txt")
        try root.write("é\nβ\n", to: "multiline-utf8.txt")
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
        try root.write("""
        # Compile requirements.txt files from all found or specified requirements.in files (compile).
        # Use -h to include hashes, -u dep1,dep2... to upgrade specific dependencies, and -U to upgrade all.
        pipc () {  # [-h] [-U|-u <pkgspec>[,<pkgspec>...]] [<reqs-in>...] [-- <pip-compile-arg>...]
            emulate -L zsh
            unset REPLY
            if [[ $1 == --help ]] { zpy $0; return }
            [[ $ZPY_PROCS ]] || return

            local gen_hashes upgrade upgrade_csv
            while [[ $1 == -[hUu] ]] {
                if [[ $1 == -h ]] { gen_hashes=--generate-hashes; shift   }
                if [[ $1 == -U ]] { upgrade=1;                    shift   }
                if [[ $1 == -u ]] { upgrade=1; upgrade_csv=$2;    shift 2 }
            }
        }
        """, to: "usage-replace.txt")
        try root.write("     0123456789abcdefghijklmnopqrstuvwxyz", to: "trim-columns.txt")
        try root.write("xxx\nabc\ndefxxxabc\ndefxxx\nxxx", to: "overlap1.txt")
        try root.write("xxx\nabc\ndefabc\ndefxxx\nxxx", to: "overlap2.txt")
        try root.write("a\nbaz\nabc\n", to: "anchors.txt")
        try root.write("foobar\nfoobar\nfoo quux", to: "vimgrep.txt")
        try root.write("""
        For the Doctor Watsons of this world, as opposed to the Sherlock
        Holmeses, success in the province of detective work must always
        be, to a very large extent, the result of luck. Sherlock Holmes
        can extract a clew from a wisp of straw or a flake of cigar ash;
        but Doctor Watson has to have it taken out for him and dusted,
        """, to: "any-class.txt")

        #expect(try run(["-n", "-U", #"foo\nbar"#, root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
        ])
        #expect(try run(["-n", "--column", "-U", #"foo\nbar"#, root.path("multi.txt")]) == [
            "1:1:foo",
            "2:1:bar",
        ])
        #expect(try run(["--byte-offset", "-U", #"foo\nbar"#, root.path("multi.txt")]) == [
            "0:foo",
            "4:bar",
        ])
        #expect(try run(["-n", "-U", "-F", "foo\nbar", root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
        ])
        #expect(try run(["-U", "-x", "bar", root.path("multi.txt")]) == [
            "bar",
        ])
        #expect(try run(["-U", "-x", #"\bbar\b"#, root.path("multi.txt")]) == [
            "bar",
        ])
        #expect(try run(["-U", "--count", "-x", #"\bbar\b"#, root.path("multi.txt")]) == [
            "1",
        ])
        #expect(try run(["-U", "-o", #"foo\nbar"#, root.path("multi.txt")]) == [
            "foo",
            "bar",
        ])
        try root.write("a\nneedle\nmid\nneedle\nz\n", to: "multiline-invert.txt")
        #expect(try run(["-U", "-v", #"needle\nmid"#, root.path("multiline-invert.txt")]) == [
            "a",
            "needle",
            "z",
        ])
        #expect(try run(["-U", "-v", #"(?s)needle.*z"#, root.path("multiline-invert.txt")]) == [
            "a",
        ])
        #expect(try run(["-U", "-v", "--count-matches", "needle", root.path("multiline-invert.txt")]) == [
            "3",
        ])
        let multilineInvertJSONOutput = try run([
            "-U",
            "-v",
            "--json",
            "needle",
            root.path("multiline-invert.txt"),
        ])
        let multilineInvertJSONMessages = try multilineInvertJSONOutput.map(jsonObject)
        let multilineInvertJSONMatches = multilineInvertJSONMessages.filter { $0["type"] as? String == "match" }
        let multilineInvertJSONEnd = multilineInvertJSONMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let multilineInvertJSONStats = multilineInvertJSONEnd?["stats"] as? [String: Any]
        #expect(multilineInvertJSONMatches.count == 3)
        #expect(multilineInvertJSONStats?["matched_lines"] as? Int == 3)
        #expect(multilineInvertJSONStats?["matches"] as? Int == 0)
        let multilineDisabledError = """
        rg: the literal "\\n" is not allowed in a regex

        Consider enabling multiline mode with the --multiline flag (or -U for short).
        When multiline mode is enabled, new line characters can be matched.
        """
        for arguments in [
            [#"foo\nbar"#, root.path("multi.txt")],
            ["--no-multiline", #"foo\nbar"#, root.path("multi.txt")],
            ["-U", "--no-multiline", #"foo\nbar"#, root.path("multi.txt")],
            [#"foo\x0Abar"#, root.path("multi.txt")],
            [#"foo\x{0000A}bar"#, root.path("multi.txt")],
            [#"foo\u{A}bar"#, root.path("multi.txt")],
            [#"foo\u{0000A}bar"#, root.path("multi.txt")],
            [#"[\n]"#, root.path("multi.txt")],
            [#"[\x0A]"#, root.path("multi.txt")],
            [#"[\u{A}]"#, root.path("multi.txt")],
            ["-F", "foo\nbar", root.path("multi.txt")],
        ] {
            var output: [String] = []
            var errors: [String] = []
            let exitCode = RipgrepCLI.run(
                arguments: arguments,
                stdout: { output.append($0) },
                stderr: { errors.append($0) }
            )
            #expect(exitCode == 2)
            #expect(output.isEmpty)
            #expect(errors == [multilineDisabledError])
        }
        #expect(try run(["-n", #"[^a]+"#, root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
            "3:baz",
        ])
        #expect(try run(["-n", #"[^\n]+"#, root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
            "3:baz",
        ])
        #expect(try run(["-n", #"[^\x0A]+"#, root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
            "3:baz",
        ])
        #expect(try run(["-n", #"[^\u{A}]+"#, root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
            "3:baz",
        ])
        #expect(try runAllowingNoMatch(["-F", #"foo\nbar"#, root.path("multi.txt")]) == [])
        try root.write("ab\n\ncd\n", to: "zero-width.txt")
        for pattern in ["^", "$", "(?:^)", "(?m:$)"] {
            var output: [String] = []
            var errors: [String] = []
            let exitCode = RipgrepCLI.run(
                arguments: ["-U", "-o", pattern, root.path("zero-width.txt")],
                stdout: { output.append($0) },
                stderr: { errors.append($0) }
            )

            #expect(exitCode == 0)
            #expect(output.isEmpty)
            #expect(errors.isEmpty)
        }
        #expect(try run(["-U", "-n", "-o", #"\b"#, root.path("multi.txt")]) == [
            "1:",
            "1:",
            "2:",
            "2:",
            "3:",
            "3:",
        ])
        #expect(try run(["-U", "-n", "-o", #"(?s).."#, root.path("multi.txt")]) == [
            "1:fo",
            "1:o",
            "2:ba",
            "2:r",
            "3:ba",
            "3:z",
        ])
        #expect(try run(["-U", "-n", "-o", "--byte-offset", #"(?s).."#, root.path("multi.txt")]) == [
            "1:0:fo",
            "1:2:o",
            "2:4:ba",
            "2:6:r",
            "3:8:ba",
            "3:10:z",
        ])
        #expect(try run(["-U", "--column", "-n", "-o", "--byte-offset", #"(?s).."#, root.path("multi.txt")]) == [
            "1:1:0:fo",
            "1:3:2:o",
            "2:5:4:ba",
            "2:7:6:r",
            "3:9:8:ba",
            "3:11:10:z",
        ])
        #expect(try run(["-U", "--column", "-n", "-o", "--byte-offset", "^ba", root.path("multi.txt")]) == [
            "2:1:4:ba",
            "3:5:8:ba",
        ])
        #expect(try run(["-U", "-n", "-o", #"(?s).."#, root.path("zero-width.txt")]) == [
            "1:ab",
            "3:cd",
        ])
        #expect(try run(["-U", "-n", "-o", "--byte-offset", #"(?s).+"#, root.path("multi.txt")]) == [
            "1:0:foo",
            "2:0:bar",
            "3:0:baz",
        ])
        #expect(try run(["-U", "-n", "-o", #"foo|$"#, root.path("multi.txt")]) == [
            "1:foo",
        ])
        for arguments in [
            ["-U", "-o", "-r", "", "^|$", root.path("multi.txt")],
            ["-U", "-o", "-r", "${missing}", "^|$", root.path("multi.txt")],
            ["-U", "-o", "-r", "", "^ba", root.path("multi.txt")],
            ["-U", "-o", "-r", "", #"foo\nbar"#, root.path("multi.txt")],
            ["-U", "-o", "-r", "${missing}", #"(?s)foo.*baz"#, root.path("multi.txt")],
        ] {
            var output: [String] = []
            var errors: [String] = []
            let exitCode = RipgrepCLI.run(
                arguments: arguments,
                stdout: { output.append($0) },
                stderr: { errors.append($0) }
            )
            #expect(exitCode == 0)
            #expect(output.isEmpty)
            #expect(errors.isEmpty)
        }
        let multilineWordBoundaryEmptyReplacementOutput = try runExecutableData([
            "-U",
            "-o",
            "-r",
            "${missing}",
            #"\b"#,
            root.path("multi.txt"),
        ], fixture: {})
        #expect(multilineWordBoundaryEmptyReplacementOutput == Data("\n\n\n\n\n\n".utf8))
        #expect(try runAllowingNoMatch(["-U", #"(?-m)bar$"#, root.path("multi.txt")]) == [])
        #expect(try runAllowingNoMatch(["-U", "-o", #"(?-m)bar$"#, root.path("multi.txt")]) == [])
        #expect(try runAllowingNoMatch(["-U", #"(?-m)bar$"#, root.path("multi-final-newline.txt")]) == [])
        var vimgrepLineStartOutput: [String] = []
        var vimgrepLineStartErrors: [String] = []
        let vimgrepLineStartExitCode = RipgrepCLI.run(
            arguments: ["-U", "--vimgrep", "^", root.path("zero-width.txt")],
            stdout: { vimgrepLineStartOutput.append($0) },
            stderr: { vimgrepLineStartErrors.append($0) }
        )
        #expect(vimgrepLineStartExitCode == 0)
        #expect(vimgrepLineStartOutput.isEmpty)
        #expect(vimgrepLineStartErrors.isEmpty)
        #expect(try run(["-U", "--vimgrep", "$", root.path("zero-width.txt")]) == [
            "\(root.path("zero-width.txt")):1:3:ab",
            "\(root.path("zero-width.txt")):3:3:cd",
        ])
        #expect(try run(["-U", "--vimgrep", "^|$", root.path("zero-width.txt")]) == [
            "\(root.path("zero-width.txt")):1:3:ab",
            "\(root.path("zero-width.txt")):3:3:cd",
        ])
        try root.write("foo\nbar\nfoo bar\n", to: "line-anchor-counts.txt")
        #expect(try run(["-U", "--vimgrep", "^|$", root.path("line-anchor-counts.txt")]) == [
            "\(root.path("line-anchor-counts.txt")):1:4:foo",
            "\(root.path("line-anchor-counts.txt")):2:4:bar",
            "\(root.path("line-anchor-counts.txt")):3:8:foo bar",
        ])
        #expect(try run(["-U", "--vimgrep", "^|foo|$", root.path("line-anchor-counts.txt")]) == [
            "\(root.path("line-anchor-counts.txt")):1:4:foo",
            "\(root.path("line-anchor-counts.txt")):2:4:bar",
            "\(root.path("line-anchor-counts.txt")):3:8:foo bar",
        ])
        try root.write("abcde\nx\nfoo bar\n", to: "line-end-columns.txt")
        #expect(try run(["-U", "-n", "--column", "$", root.path("line-end-columns.txt")]) == [
            "1:6:abcde",
            "2:6:x",
            "3:6:foo bar",
        ])
        #expect(try run(["-U", "-n", "--column", "-r", "X", "$", root.path("line-end-columns.txt")]) == [
            "1:6:abcdeX",
            "2:6:xX",
            "3:6:foo barX",
        ])
        #expect(try run(["-U", "--vimgrep", "$", root.path("line-end-columns.txt")]) == [
            "\(root.path("line-end-columns.txt")):1:6:abcde",
            "\(root.path("line-end-columns.txt")):2:2:x",
            "\(root.path("line-end-columns.txt")):3:8:foo bar",
        ])
        #expect(try run(["-U", "--count-matches", "$", root.path("zero-width.txt")]) == ["3"])
        #expect(try run(["-U", "--count-matches", "(?:)", root.path("zero-width.txt")]) == ["7"])
        #expect(try run(["-U", "--count-matches", "x?", root.path("zero-width.txt")]) == ["7"])
        #expect(try run(["-U", "--count", "$", root.path("line-anchor-counts.txt")]) == ["3"])
        #expect(try run(["-U", "--count", "^", root.path("line-anchor-counts.txt")]) == ["3"])
        #expect(try run(["-U", "--count", "^|$", root.path("line-anchor-counts.txt")]) == ["6"])
        #expect(try run(["-U", "--count", "foo|$", root.path("line-anchor-counts.txt")]) == ["4"])
        #expect(try run(["-U", "--count", "^|foo", root.path("line-anchor-counts.txt")]) == ["3"])
        let jsonLineStartOutput = try run(["-U", "--json", "^", root.path("zero-width.txt")])
        let jsonLineStartMessages = try jsonLineStartOutput.map(jsonObject)
        #expect(jsonLineStartMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let jsonLineStartMatch = jsonLineStartMessages[1]["data"] as? [String: Any]
        let jsonLineStartLines = jsonLineStartMatch?["lines"] as? [String: String]
        let jsonLineStartSubmatches = jsonLineStartMatch?["submatches"] as? [[String: Any]]
        let jsonLineStartEnd = jsonLineStartMessages[2]["data"] as? [String: Any]
        let jsonLineStartStats = jsonLineStartEnd?["stats"] as? [String: Any]
        #expect(jsonLineStartLines?["text"] == "ab\n\ncd\n")
        #expect(jsonLineStartSubmatches?.map { $0["start"] as? Int } == [0, 3, 4])
        #expect(jsonLineStartSubmatches?.map { $0["end"] as? Int } == [0, 3, 4])
        #expect(jsonLineStartStats?["matched_lines"] as? Int == 3)
        #expect(jsonLineStartStats?["matches"] as? Int == 3)
        let jsonLineEndOutput = try run(["-U", "--json", "-C1", "$", root.path("zero-width.txt")])
        let jsonLineEndMessages = try jsonLineEndOutput.map(jsonObject)
        #expect(jsonLineEndMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let jsonLineEndMatch = jsonLineEndMessages[1]["data"] as? [String: Any]
        let jsonLineEndLines = jsonLineEndMatch?["lines"] as? [String: String]
        let jsonLineEndSubmatches = jsonLineEndMatch?["submatches"] as? [[String: Any]]
        let jsonLineEndEnd = jsonLineEndMessages[2]["data"] as? [String: Any]
        let jsonLineEndStats = jsonLineEndEnd?["stats"] as? [String: Any]
        #expect(jsonLineEndLines?["text"] == "ab\n\ncd\n")
        #expect(jsonLineEndSubmatches?.map { $0["start"] as? Int } == [2, 3, 6])
        #expect(jsonLineEndSubmatches?.map { $0["end"] as? Int } == [2, 3, 6])
        #expect(jsonLineEndStats?["matched_lines"] as? Int == 3)
        #expect(jsonLineEndStats?["matches"] as? Int == 3)
        let jsonMixedLineEndOutput = try run(["-U", "--json", #"foo|$"#, root.path("multi.txt")])
        let jsonMixedLineEndMessages = try jsonMixedLineEndOutput.map(jsonObject)
        #expect(jsonMixedLineEndMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let jsonMixedLineEndMatch = jsonMixedLineEndMessages[1]["data"] as? [String: Any]
        let jsonMixedLineEndLines = jsonMixedLineEndMatch?["lines"] as? [String: String]
        let jsonMixedLineEndSubmatches = jsonMixedLineEndMatch?["submatches"] as? [[String: Any]]
        let jsonMixedLineEndEnd = jsonMixedLineEndMessages[2]["data"] as? [String: Any]
        let jsonMixedLineEndStats = jsonMixedLineEndEnd?["stats"] as? [String: Any]
        #expect(jsonMixedLineEndLines?["text"] == "foo\nbar\nbaz\n")
        #expect(jsonMixedLineEndSubmatches?.compactMap { ($0["match"] as? [String: String])?["text"] } == ["foo", "", ""])
        #expect(jsonMixedLineEndSubmatches?.map { $0["start"] as? Int } == [0, 7, 11])
        #expect(jsonMixedLineEndSubmatches?.map { $0["end"] as? Int } == [3, 7, 11])
        #expect(jsonMixedLineEndStats?["matched_lines"] as? Int == 3)
        #expect(jsonMixedLineEndStats?["matches"] as? Int == 3)

        let jsonMixedLineEndContextOutput = try run(["-U", "--json", "-C1", #"foo|$"#, root.path("multi.txt")])
        let jsonMixedLineEndContextMessages = try jsonMixedLineEndContextOutput.map(jsonObject)
        #expect(jsonMixedLineEndContextMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let jsonMixedLineEndContextEnd = jsonMixedLineEndContextMessages[2]["data"] as? [String: Any]
        let jsonMixedLineEndContextStats = jsonMixedLineEndContextEnd?["stats"] as? [String: Any]
        #expect(jsonMixedLineEndContextStats?["matched_lines"] as? Int == 3)
        #expect(jsonMixedLineEndContextStats?["matches"] as? Int == 3)

        let jsonMixedLineStartOutput = try run(["-U", "--json", #"foo|^"#, root.path("multi.txt")])
        let jsonMixedLineStartMessages = try jsonMixedLineStartOutput.map(jsonObject)
        #expect(jsonMixedLineStartMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let jsonMixedLineStartMatch = jsonMixedLineStartMessages[1]["data"] as? [String: Any]
        let jsonMixedLineStartLines = jsonMixedLineStartMatch?["lines"] as? [String: String]
        let jsonMixedLineStartSubmatches = jsonMixedLineStartMatch?["submatches"] as? [[String: Any]]
        #expect(jsonMixedLineStartLines?["text"] == "foo\nbar\nbaz\n")
        #expect(jsonMixedLineStartSubmatches?.compactMap { ($0["match"] as? [String: String])?["text"] } == ["foo", "", ""])
        #expect(jsonMixedLineStartSubmatches?.map { $0["start"] as? Int } == [0, 4, 8])
        #expect(jsonMixedLineStartSubmatches?.map { $0["end"] as? Int } == [3, 4, 8])
        try root.write("foo\r\nbar\r\nfoo bar\r\n", to: "crlf-mixed-line-start.txt")
        let jsonCRLFMixedLineStartOutput = try run(["-U", "--json", #"foo|^"#, root.path("crlf-mixed-line-start.txt")])
        let jsonCRLFMixedLineStartMessages = try jsonCRLFMixedLineStartOutput.map(jsonObject)
        #expect(jsonCRLFMixedLineStartMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let jsonCRLFMixedLineStartMatch = jsonCRLFMixedLineStartMessages[1]["data"] as? [String: Any]
        let jsonCRLFMixedLineStartLines = jsonCRLFMixedLineStartMatch?["lines"] as? [String: String]
        let jsonCRLFMixedLineStartSubmatches = jsonCRLFMixedLineStartMatch?["submatches"] as? [[String: Any]]
        #expect(jsonCRLFMixedLineStartLines?["text"] == "foo\r\nbar\r\nfoo bar\r\n")
        #expect(jsonCRLFMixedLineStartSubmatches?.compactMap { ($0["match"] as? [String: String])?["text"] } == ["foo", "", "foo"])
        #expect(jsonCRLFMixedLineStartSubmatches?.map { $0["start"] as? Int } == [0, 5, 10])
        #expect(jsonCRLFMixedLineStartSubmatches?.map { $0["end"] as? Int } == [3, 5, 13])
        try root.write("alpha\nfoo\nbar\nbaz\nfoo bar\n", to: "json-anchored-lines.txt")
        let jsonAnchoredLineStartOutput = try run(["-U", "--json", "^foo", root.path("json-anchored-lines.txt")])
        let jsonAnchoredLineStartMessages = try jsonAnchoredLineStartOutput.map(jsonObject)
        let jsonAnchoredLineStartMatches = jsonAnchoredLineStartMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else {
                return nil
            }
            return message["data"] as? [String: Any]
        }
        #expect(jsonAnchoredLineStartMatches.map { $0["line_number"] as? Int } == [2, 5])
        #expect(jsonAnchoredLineStartMatches.compactMap { ($0["lines"] as? [String: String])?["text"] } == ["foo\n", "foo bar\n"])
        #expect(jsonAnchoredLineStartMatches.compactMap { ($0["submatches"] as? [[String: Any]])?.count } == [1, 1])

        let jsonAnchoredLineEndOutput = try run(["-U", "--json", "bar$", root.path("json-anchored-lines.txt")])
        let jsonAnchoredLineEndMessages = try jsonAnchoredLineEndOutput.map(jsonObject)
        let jsonAnchoredLineEndMatches = jsonAnchoredLineEndMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else {
                return nil
            }
            return message["data"] as? [String: Any]
        }
        #expect(jsonAnchoredLineEndMatches.map { $0["line_number"] as? Int } == [3, 5])
        #expect(jsonAnchoredLineEndMatches.compactMap { ($0["lines"] as? [String: String])?["text"] } == ["bar\n", "foo bar\n"])

        let jsonAnchoredContextOutput = try run(["-U", "--json", "-A1", "^foo", root.path("json-anchored-lines.txt")])
        let jsonAnchoredContextMessages = try jsonAnchoredContextOutput.map(jsonObject)
        #expect(jsonAnchoredContextMessages.map { $0["type"] as? String } == [
            "begin",
            "match",
            "context",
            "match",
            "end",
            "summary",
        ])
        let jsonAnchoredContextLine = jsonAnchoredContextMessages[2]["data"] as? [String: Any]
        #expect(jsonAnchoredContextLine?["line_number"] as? Int == 3)
        #expect((jsonAnchoredContextLine?["lines"] as? [String: String])?["text"] == "bar\n")
        let jsonDotallContextOutput = try run(["-U", "--json", "-C1", #"(?s).+?"#, root.path("multi.txt")])
        let jsonDotallContextMessages = try jsonDotallContextOutput.map(jsonObject)
        #expect(jsonDotallContextMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let jsonDotallContextEnd = jsonDotallContextMessages[2]["data"] as? [String: Any]
        let jsonDotallContextStats = jsonDotallContextEnd?["stats"] as? [String: Any]
        #expect(jsonDotallContextStats?["matched_lines"] as? Int == 3)
        #expect(jsonDotallContextStats?["matches"] as? Int == 12)
        #expect(try run(["-n", "-U", "-o", #"foo[\s\S]+?bar"#, root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
        ])
        #expect(try run(["-n", "-U", "-o", #"foo\p{Any}+?bar"#, root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
        ])
        #expect(try runAllowingNoMatch(["-U", #"\P{Any}"#, root.path("multi.txt")]) == [])
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
        let noUnicodeMultilineDotOutput = try runExecutableData([
            "-U",
            "--no-unicode",
            "-o",
            ".",
            root.path("multiline-utf8.txt"),
        ], fixture: {})
        #expect(noUnicodeMultilineDotOutput == Data([
            0xC3, 0x0A,
            0xA9, 0x0A,
            0xCE, 0x0A,
            0xB2, 0x0A,
        ]))
        let noUnicodeMultilineDotAllOutput = try runExecutableData([
            "-U",
            "--no-unicode",
            "-o",
            "(?s).",
            root.path("multiline-utf8.txt"),
        ], fixture: {})
        #expect(noUnicodeMultilineDotAllOutput == noUnicodeMultilineDotOutput)
        let noUnicodeMultilineMaxCountOutput = try runExecutableData([
            "-U",
            "--no-unicode",
            "-m1",
            "-o",
            "(?s).",
            root.path("multiline-utf8.txt"),
        ], fixture: {})
        #expect(noUnicodeMultilineMaxCountOutput == Data([
            0xC3, 0x0A,
            0xA9, 0x0A,
        ]))
        #expect(try run(["-U", "-r?", "-n", #"\n"#, root.path("multi.txt")]) == [
            "1:foo?bar?baz?",
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
        #expect(try run(["-U", "--vimgrep", #"(?s).."#, root.path("multi.txt")]) == [
            "\(root.path("multi.txt")):1:1:foo",
            "\(root.path("multi.txt")):1:3:foo",
            "\(root.path("multi.txt")):2:1:bar",
            "\(root.path("multi.txt")):2:3:bar",
            "\(root.path("multi.txt")):3:1:baz",
            "\(root.path("multi.txt")):3:3:baz",
        ])
        #expect(try run(["-U", "--vimgrep", #"(?s).+?"#, root.path("multi.txt")]) == [
            "\(root.path("multi.txt")):1:1:foo",
            "\(root.path("multi.txt")):1:2:foo",
            "\(root.path("multi.txt")):1:3:foo",
            "\(root.path("multi.txt")):1:4:foo",
            "\(root.path("multi.txt")):2:1:bar",
            "\(root.path("multi.txt")):2:2:bar",
            "\(root.path("multi.txt")):2:3:bar",
            "\(root.path("multi.txt")):2:4:bar",
            "\(root.path("multi.txt")):3:1:baz",
            "\(root.path("multi.txt")):3:2:baz",
            "\(root.path("multi.txt")):3:3:baz",
            "\(root.path("multi.txt")):3:4:baz",
        ])
        #expect(try run(["-U", "--vimgrep", "--byte-offset", #"(?s).."#, root.path("multi.txt")]) == [
            "\(root.path("multi.txt")):1:1:0:foo",
            "\(root.path("multi.txt")):1:3:0:foo",
            "\(root.path("multi.txt")):2:1:4:bar",
            "\(root.path("multi.txt")):2:3:4:bar",
            "\(root.path("multi.txt")):3:1:8:baz",
            "\(root.path("multi.txt")):3:3:8:baz",
        ])
        #expect(try run(["-U", "--vimgrep", "--byte-offset", "$", root.path("multi.txt")]) == [
            "\(root.path("multi.txt")):1:4:0:foo",
            "\(root.path("multi.txt")):2:4:4:bar",
            "\(root.path("multi.txt")):3:4:8:baz",
        ])
        #expect(try run(["-U", "--vimgrep", "--byte-offset", #"foo|$"#, root.path("multi.txt")]) == [
            "\(root.path("multi.txt")):1:1:0:foo",
            "\(root.path("multi.txt")):2:4:4:bar",
            "\(root.path("multi.txt")):3:4:8:baz",
        ])
        try root.write("pre\naaa\nbbb\nctx\naaa\nbbb\npost\naaa\nbbb\n", to: "multi-context.txt")
        #expect(try run(["-U", "-n", "-m1", "-o", "-A2", #"aaa\nbbb"#, root.path("multi-context.txt")]) == [
            "2:aaa",
            "3:bbb",
            "4-ctx",
            "5-aaa",
        ])
        #expect(try run(["-U", "--vimgrep", "-m1", "-A2", #"aaa\nbbb"#, root.path("multi-context.txt")]) == [
            "\(root.path("multi-context.txt")):2:1:aaa",
            "\(root.path("multi-context.txt"))-4-ctx",
            "\(root.path("multi-context.txt"))-5-aaa",
        ])
        #expect(try run(["-U", "--vimgrep", "-A2", #"aaa\nbbb"#, root.path("multi-context.txt")]) == [
            "\(root.path("multi-context.txt")):2:1:aaa",
            "\(root.path("multi-context.txt"))-4-ctx",
            "\(root.path("multi-context.txt")):5:1:aaa",
            "\(root.path("multi-context.txt"))-7-post",
            "\(root.path("multi-context.txt")):8:1:aaa",
        ])
        try root.write("needle\nnext\nneedle\ntail\n", to: "multi-max-context.txt")
        #expect(try run(["-U", "-n", "-m1", "-A2", "needle", root.path("multi-max-context.txt")]) == [
            "1:needle",
            "2-next",
            "3:needle",
        ])
        #expect(try run(["-U", "--vimgrep", "-m1", "-A2", "needle", root.path("multi-max-context.txt")]) == [
            "\(root.path("multi-max-context.txt")):1:1:needle",
            "\(root.path("multi-max-context.txt"))-2-next",
            "\(root.path("multi-max-context.txt")):3:1:needle",
        ])

        let jsonMultilineMaxOutput = try run([
            "-U",
            "--json",
            "-m1",
            "-A2",
            "needle",
            root.path("multi-max-context.txt"),
        ])
        let jsonMultilineMaxMessages = try jsonMultilineMaxOutput.map(jsonObject)
        #expect(jsonMultilineMaxMessages.map { $0["type"] as? String } == [
            "begin",
            "match",
            "context",
            "match",
            "end",
            "summary",
        ])
        let jsonMultilineMaxEnd = jsonMultilineMaxMessages[4]["data"] as? [String: Any]
        let jsonMultilineMaxStats = jsonMultilineMaxEnd?["stats"] as? [String: Any]
        #expect(jsonMultilineMaxStats?["bytes_searched"] as? Int == "needle\nnext\nneedle\n".utf8.count)
        #expect(jsonMultilineMaxStats?["matched_lines"] as? Int == 2)
        #expect(jsonMultilineMaxStats?["matches"] as? Int == 2)

        try root.write("needle tail\nneedle again\n", to: "multi-replace-max.txt")
        #expect(try run(["-U", "-m1", "--replace", "X", "[a-z]+", root.path("multi-replace-max.txt")]) == [
            "X X",
        ])
        try root.write("before\nneedle\nafter\n", to: "multi-replace-context-max.txt")
        #expect(try run([
            "-U",
            "-m1",
            "-A1",
            "--replace",
            "<$0>",
            "[a-z]+",
            root.path("multi-replace-context-max.txt"),
        ]) == [
            "<before>",
            "<needle>",
        ])
        let jsonMultilineReplaceMaxOutput = try run([
            "-U",
            "--json",
            "-m1",
            "--replace",
            "X",
            "[a-z]+",
            root.path("multi-replace-max.txt"),
        ])
        let jsonMultilineReplaceMaxMessages = try jsonMultilineReplaceMaxOutput.map(jsonObject)
        let jsonMultilineReplaceMaxMatch = jsonMultilineReplaceMaxMessages[1]["data"] as? [String: Any]
        let jsonMultilineReplaceMaxSubmatches = jsonMultilineReplaceMaxMatch?["submatches"] as? [[String: Any]]
        #expect(jsonMultilineReplaceMaxSubmatches?.compactMap { ($0["replacement"] as? [String: String])?["text"] } == ["X", "X"])
        let jsonMultilineReplaceContextOutput = try run([
            "-U",
            "--json",
            "-m1",
            "-A1",
            "--replace",
            "<$0>",
            "[a-z]+",
            root.path("multi-replace-context-max.txt"),
        ])
        let jsonMultilineReplaceContextMessages = try jsonMultilineReplaceContextOutput.map(jsonObject)
        let jsonMultilineReplaceContextEnd = jsonMultilineReplaceContextMessages[3]["data"] as? [String: Any]
        let jsonMultilineReplaceContextStats = jsonMultilineReplaceContextEnd?["stats"] as? [String: Any]
        #expect(jsonMultilineReplaceContextStats?["matched_lines"] as? Int == 2)
        #expect(jsonMultilineReplaceContextStats?["matches"] as? Int == 2)

        let jsonMultilineMaxNoContextOutput = try run([
            "-U",
            "--json",
            "-m1",
            "needle",
            root.path("multi-max-context.txt"),
        ])
        let jsonMultilineMaxNoContextMessages = try jsonMultilineMaxNoContextOutput.map(jsonObject)
        let jsonMultilineMaxNoContextEnd = jsonMultilineMaxNoContextMessages[2]["data"] as? [String: Any]
        let jsonMultilineMaxNoContextStats = jsonMultilineMaxNoContextEnd?["stats"] as? [String: Any]
        #expect(jsonMultilineMaxNoContextStats?["bytes_searched"] as? Int == "needle\n".utf8.count)
        #expect(jsonMultilineMaxNoContextStats?["matched_lines"] as? Int == 1)
        #expect(jsonMultilineMaxNoContextStats?["matches"] as? Int == 1)

        try root.write("foo\nbar\nfoo bar\n", to: "json-multiline-context.txt")
        let jsonMultilineAfterOutput = try run([
            "-U",
            "--json",
            "-C1",
            #"foo\nbar"#,
            root.path("json-multiline-context.txt"),
        ])
        let jsonMultilineAfterMessages = try jsonMultilineAfterOutput.map(jsonObject)
        #expect(jsonMultilineAfterMessages.map { $0["type"] as? String } == ["begin", "match", "context", "end", "summary"])
        let jsonMultilineAfterMatch = jsonMultilineAfterMessages[1]["data"] as? [String: Any]
        let jsonMultilineAfterContext = jsonMultilineAfterMessages[2]["data"] as? [String: Any]
        #expect(jsonMultilineAfterMatch?["line_number"] as? Int == 1)
        #expect((jsonMultilineAfterMatch?["lines"] as? [String: String])?["text"] == "foo\nbar\n")
        #expect(jsonMultilineAfterContext?["line_number"] as? Int == 3)
        #expect((jsonMultilineAfterContext?["lines"] as? [String: String])?["text"] == "foo bar\n")

        let jsonMultilineBeforeOutput = try run([
            "-U",
            "--json",
            "-C1",
            #"bar\nfoo"#,
            root.path("json-multiline-context.txt"),
        ])
        let jsonMultilineBeforeMessages = try jsonMultilineBeforeOutput.map(jsonObject)
        #expect(jsonMultilineBeforeMessages.map { $0["type"] as? String } == ["begin", "context", "match", "end", "summary"])
        let jsonMultilineBeforeContext = jsonMultilineBeforeMessages[1]["data"] as? [String: Any]
        let jsonMultilineBeforeMatch = jsonMultilineBeforeMessages[2]["data"] as? [String: Any]
        #expect(jsonMultilineBeforeContext?["line_number"] as? Int == 1)
        #expect((jsonMultilineBeforeContext?["lines"] as? [String: String])?["text"] == "foo\n")
        #expect(jsonMultilineBeforeMatch?["line_number"] as? Int == 2)
        #expect((jsonMultilineBeforeMatch?["lines"] as? [String: String])?["text"] == "bar\nfoo bar\n")
        #expect(try run(["-n", "-U", "--only-matching", #"Watson|Sherlock\p{Any}+?Holmes"#, root.path("any-class.txt")]) == [
            "1:Watson",
            "1:Sherlock",
            "2:Holmes",
            "3:Sherlock Holmes",
            "5:Watson",
        ])
        #expect(try run(["-n", "-U", "-C1", #"detective work\p{Any}+?result of luck"#, root.path("any-class.txt")]) == [
            "1-For the Doctor Watsons of this world, as opposed to the Sherlock",
            "2:Holmeses, success in the province of detective work must always",
            "3:be, to a very large extent, the result of luck. Sherlock Holmes",
            "4-can extract a clew from a wisp of straw or a flake of cigar ash;",
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
            "-N",
            "-U",
            "-r",
            "$usage",
            #"^(?P<predoc>\n?(# .*\n)*)(alias (?P<aname>pipc)="[^"]+"|(?P<fname>pipc) \(\) \{)(  #(?P<usage> .+))?"#,
            root.path("usage-replace.txt"),
        ]) == [
            " [-h] [-U|-u <pkgspec>[,<pkgspec>...]] [<reqs-in>...] [-- <pip-compile-arg>...]",
        ])
        #expect(try run([
            "-U",
            "--trim",
            "--max-columns-preview",
            "-M8",
            "--color=always",
            "--colors=path:none",
            "--no-filename",
            #"a\n?bc"#,
            root.path("trim-columns.txt"),
        ]) == [
            "01234567 [... 1 more match]",
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
        let redBold = "\u{1B}[1m\u{1B}[31m"
        let reset = "\u{1B}[0m"
        let coloredMultilineTrimPreview = try runExecutableData([
            "-U",
            "--trim",
            "--max-columns-preview",
            "-M8",
            "--color=always",
            "--colors=path:none",
            "--no-filename",
            #".*a\n?bc.*"#,
            root.path("trim-columns.txt"),
        ]) {}
        #expect(coloredMultilineTrimPreview == Data(
            "\(reset)\(redBold)01234567\(reset) [... 0 more matches]\n".utf8
        ))
        let coloredMultilineTrimVimgrepPreview = try runExecutableData([
            "-U",
            "--trim",
            "--max-columns-preview",
            "-M8",
            "--vimgrep",
            "--no-filename",
            "--color=always",
            "--colors=path:none",
            "--colors=line:none",
            "--colors=column:none",
            #".*a\n?bc.*"#,
            root.path("trim-columns.txt"),
        ]) {}
        #expect(coloredMultilineTrimVimgrepPreview == Data(
            "\(reset)1\(reset):\(reset)1\(reset):\(reset)\(redBold)01234567\(reset) [... 0 more matches]\n".utf8
        ))

        let output = try run(["--json", "-U", #"foo\nbar"#, root.path("multi.txt")])
        let messages = try output.map(jsonObject)
        let match = messages.first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let lines = match?["lines"] as? [String: String]
        let submatch = (match?["submatches"] as? [[String: Any]])?.first
        #expect(lines?["text"] == "foo\nbar\n")
        #expect(match?["line_number"] as? Int == 1)
        #expect(submatch?["start"] as? Int == 0)
        #expect(submatch?["end"] as? Int == 7)

        try root.write("test\r\n\n", to: "crlf-json.txt")
        let crlfOutput = try run(["--json", "-U", "--crlf", #"\n"#, root.path("crlf-json.txt")])
        let crlfMessages = try crlfOutput.map(jsonObject)
        #expect(crlfMessages.map { $0["type"] as? String } == ["begin", "match", "end", "summary"])
        let crlfMatch = crlfMessages[1]["data"] as? [String: Any]
        let crlfLines = crlfMatch?["lines"] as? [String: String]
        let crlfSubmatches = crlfMatch?["submatches"] as? [[String: Any]]
        #expect(crlfLines?["text"] == "test\r\n\n")
        #expect(crlfSubmatches?.count == 2)
        #expect(crlfSubmatches?.map { $0["start"] as? Int } == [5, 6])
        #expect(crlfSubmatches?.map { $0["end"] as? Int } == [6, 7])
    }

    @Test("honors CRLF anchor mode")
    func honorsCRLFAnchorMode() throws {
        let root = try TemporaryDirectory()
        try root.write("foo\r\nbar\rquux\nbaz\r\n", to: "crlf.txt")
        try root.write("a\r\nb\r\n", to: "plain-crlf.txt")
        try root.write("foo\r\nbar\r\nbaz\r\n", to: "crlf-line-regexp.txt")
        try root.write("foo\nbar\nbaz\n", to: "lf-line-regexp.txt")
        try root.write("\n", to: "lf-empty.txt")
        try root.write("emoji end\r\n\n", to: "inline-crlf-boundary.txt")
        try root.write("first\nlast", to: "lf-no-final-newline.txt")
        try root.write("foo\r\nbar", to: "crlf-no-final-newline.txt")

        #expect(try runAllowingNoMatch(["-n", "foo$", root.path("crlf.txt")]) == [])
        let plainDotOutput = try runExecutableData(["-o", ".", root.path("plain-crlf.txt")]) {}
        #expect(plainDotOutput == Data([
            0x61, 0x0A,
            0x0D, 0x0A,
            0x62, 0x0A,
            0x0D, 0x0A,
        ]))
        #expect(try run(["--count-matches", ".", root.path("plain-crlf.txt")]) == [
            "4",
        ])
        #expect(try run(["-U", "$", root.path("plain-crlf.txt")]) == [
            "a\r",
            "b\r",
        ])
        #expect(try run(["-U", #"(?m)$"#, root.path("plain-crlf.txt")]) == [
            "a\r",
            "b\r",
        ])
        #expect(try runAllowingNoMatch(["-U", "--crlf", #"(?-m)b$"#, root.path("plain-crlf.txt")]) == [])
        #expect(try runAllowingNoMatch(["-U", "--crlf", #"(?-m)^b"#, root.path("plain-crlf.txt")]) == [])
        #expect(try run(["-U", "--count-matches", "$", root.path("plain-crlf.txt")]) == [
            "2",
        ])
        #expect(try run(["-U", "--crlf", "--count-matches", "$", root.path("plain-crlf.txt")]) == [
            "2\r",
        ])
        #expect(try run(["-U", "--crlf", "--count-matches", "^", root.path("plain-crlf.txt")]) == [
            "2\r",
        ])
        #expect(try run(["-U", "--crlf", "--count-matches", "^|$", root.path("plain-crlf.txt")]) == [
            "4\r",
        ])
        let crlfOnlyLineStartEndOutput = try runExecutableData([
            "--crlf",
            "-bo",
            "^|$",
            root.path("plain-crlf.txt"),
        ], fixture: {})
        #expect(crlfOnlyLineStartEndOutput == Data("0:\r\n1:\r\n3:\r\n4:\r\n".utf8))
        #expect(try run(["--crlf", "--count-matches", "^|$", root.path("plain-crlf.txt")]) == [
            "4\r",
        ])
        let crlfOnlyNotWordBoundaryOutput = try runExecutableData([
            "--crlf",
            "-bo",
            #"\B"#,
            root.path("crlf-line-regexp.txt"),
        ], fixture: {})
        #expect(crlfOnlyNotWordBoundaryOutput == Data("1:\r\n2:\r\n6:\r\n7:\r\n11:\r\n12:\r\n".utf8))
        #expect(try run(["-U", "--crlf", "--count-matches", "$", root.path("crlf-no-final-newline.txt")]) == [
            "1\r",
        ])
        #expect(try run(["-U", "--crlf", "-n", "$", root.path("crlf-no-final-newline.txt")]) == [
            "1:foo\r",
            "2:bar\r",
        ])
        #expect(try run(["--vimgrep", "$", root.path("crlf-no-final-newline.txt")]) == [
            "\(root.path("crlf-no-final-newline.txt")):1:5:foo\r",
            "\(root.path("crlf-no-final-newline.txt")):2:bar",
        ])
        #expect(try run(["--crlf", "--vimgrep", "$", root.path("crlf-no-final-newline.txt")]) == [
            "\(root.path("crlf-no-final-newline.txt")):1:4:foo\r",
            "\(root.path("crlf-no-final-newline.txt")):2:bar\r",
        ])
        #expect(try run(["-U", "--count-matches", "$", root.path("crlf-no-final-newline.txt")]) == [
            "1",
        ])
        #expect(try run(["-U", "-n", "$", root.path("crlf-no-final-newline.txt")]) == [
            "1:foo\r",
            "2:bar",
        ])
        #expect(try run(["--crlf", "-n", "foo$", root.path("crlf.txt")]) == [
            "1:foo\r",
        ])
        #expect(try run(["--crlf", "-n", "bar$", root.path("crlf.txt")]) == [
            "2:bar\rquux",
        ])
        #expect(try runAllowingNoMatch(["-U", "bar$", root.path("crlf.txt")]) == [])
        #expect(try runAllowingNoMatch(["-U", "baz$", root.path("crlf.txt")]) == [])
        #expect(try runAllowingNoMatch(["-U", "--multiline-dotall", "foo.bar", root.path("crlf.txt")]) == [])
        #expect(try run(["-U", "--crlf", "baz$", root.path("crlf.txt")]) == [
            "baz\r",
        ])
        #expect(try run(["-U", #"(?s)foo.*bar"#, root.path("crlf.txt")]) == [
            "foo\r",
            "bar\rquux",
        ])
        #expect(try run(["-U", "-o", #"(?s)foo.*bar"#, root.path("crlf.txt")]) == [
            "foo\r",
            "bar",
        ])
        #expect(try run(["--crlf", "-n", "^quux", root.path("crlf.txt")]) == [
            "2:bar\rquux",
        ])
        #expect(try run(["-n", #"(?R:foo$)"#, root.path("crlf.txt")]) == [
            "1:foo\r",
        ])
        #expect(try run(["-n", #"(?R:^quux)"#, root.path("crlf.txt")]) == [
            "2:bar\rquux",
        ])
        #expect(try run(["-n", #"(?R)baz$"#, root.path("crlf.txt")]) == [
            "3:baz\r",
        ])
        #expect(try run(["-U", "-n", #"(?mR:$)"#, root.path("crlf.txt")]) == [
            "1:foo\r",
            "2:bar\rquux",
            "3:baz\r",
        ])
        #expect(try run(["--count-matches", #"(?R:$)"#, root.path("crlf.txt")]) == [
            "6",
        ])
        #expect(try run(["-bo", #"(?R:$)"#, root.path("crlf-no-final-newline.txt")]) == [
            "3:",
            "4:",
            "5:bar",
        ])
        let inlineCRLFWordBoundaryOutput = try runExecutableData([
            "-w",
            #"(?R:$)"#,
            root.path("inline-crlf-boundary.txt"),
        ], fixture: {})
        #expect(inlineCRLFWordBoundaryOutput == Data("\n".utf8))
        let inlineCRLFLineRegexpOutput = try runExecutableData([
            "-x",
            #"(?R:$)"#,
            root.path("inline-crlf-boundary.txt"),
        ], fixture: {})
        #expect(inlineCRLFLineRegexpOutput == Data("\n".utf8))
        let inlineCRLFReplacementOutput = try runExecutableData([
            "--replace",
            "X",
            #"(?R:$)"#,
            root.path("inline-crlf-boundary.txt"),
        ], fixture: {})
        #expect(inlineCRLFReplacementOutput == Data("emoji endX\rX\nX\n".utf8))
        let inlineCRLFOnlyMatchingReplacementOutput = try runExecutableData([
            "-o",
            "--replace",
            "X",
            #"(?R:$)"#,
            root.path("inline-crlf-boundary.txt"),
        ], fixture: {})
        #expect(inlineCRLFOnlyMatchingReplacementOutput == Data("X\nX\nX\n".utf8))
        #expect(try runAllowingNoMatch(["-n", #"(?-R:foo$)"#, root.path("crlf.txt")]) == [])
        #expect(try runAllowingNoMatch(["-n", #"(?R-m:foo$)"#, root.path("crlf.txt")]) == [])
        #expect(try run(["--crlf", "-x", "foo", root.path("crlf.txt")]) == [
            "foo\r",
        ])
        #expect(try run(["-U", "--crlf", "-x", "foo", root.path("crlf-line-regexp.txt")]) == [
            "foo\r",
        ])
        #expect(try run(["-U", "--crlf", "-x", #"\bbar\b"#, root.path("crlf-line-regexp.txt")]) == [
            "bar\r",
        ])
        #expect(try run(["-U", "--crlf", "--count", "-x", #"\bbar\b"#, root.path("crlf-line-regexp.txt")]) == [
            "1\r",
        ])
        #expect(try run(["-U", "--crlf", "--vimgrep", "-x", #"\bbar\b"#, root.path("crlf-line-regexp.txt")]) == [
            "\(root.path("crlf-line-regexp.txt")):2:1:bar\r",
        ])
        #expect(try run(["-U", "--crlf", "--vimgrep", "-x", #"\bbar\b"#, root.path("lf-line-regexp.txt")]) == [
            "\(root.path("lf-line-regexp.txt")):2:1:bar\r",
        ])
        #expect(try run(["--crlf", "-o", "foo$", root.path("crlf.txt")]) == [
            "foo\r",
        ])
        #expect(try run(["--crlf", "-o", "baz$", root.path("crlf.txt")]) == [
            "baz\r",
        ])
        #expect(try run(["--crlf", "-o", "quux$", root.path("crlf.txt")]) == [
            "quux\r",
        ])
        try root.write("a\r\nb\r\nab\r\nba\r\n", to: "crlf-classes.txt")
        #expect(try run(["--crlf", "--count-matches", "[^a]+", root.path("crlf-classes.txt")]) == [
            "3\r",
        ])
        #expect(try run(["--crlf", "-bo", "[^a]+", root.path("crlf-classes.txt")]) == [
            "3:b\r",
            "7:b\r",
            "10:b\r",
        ])
        #expect(try run(["--crlf", "-o", "[^a]+", root.path("crlf-classes.txt")]) == [
            "b\r",
            "b\r",
            "b\r",
        ])
        #expect(try run(["--crlf", "--count-matches", "[^b]+", root.path("crlf-classes.txt")]) == [
            "3\r",
        ])
        try root.write("foo\r\nbar\r\n\r\n", to: "crlf-empty.txt")
        let onlyMatchingStartAnchors = try runExecutableData(["--crlf", "-o", "^", root.path("crlf-empty.txt")]) {}
        #expect(onlyMatchingStartAnchors == Data([13, 10, 13, 10, 13, 10]))
        #expect(try run(["--crlf", "-n", "-o", "^", root.path("crlf-empty.txt")]) == [
            "1:\r",
            "2:\r",
            "3:\r",
        ])
        let onlyMatchingEndAnchors = try runExecutableData(["--crlf", "-o", "$", root.path("crlf-empty.txt")]) {}
        #expect(onlyMatchingEndAnchors == Data([13, 10, 13, 10, 13, 10]))
        #expect(try run(["--crlf", "--count-matches", "$", root.path("crlf-empty.txt")]) == [
            "3\r",
        ])
        #expect(try runAllowingNoMatch(["--crlf", "--null-data", "-n", "foo$", root.path("crlf.txt")]) == [])
        #expect(try run(["--null-data", "--crlf", "-n", "foo$", root.path("crlf.txt")]) == [
            "1:foo\r",
        ])
        try root.write(Data("pre\0needle\n".utf8), to: "crlf-binary.dat")
        try root.write("alpha\nneedle one\nneedle two\ntail\n", to: "crlf-text.txt")
        #expect(try run(["--sort=path", "--null-data", "--crlf", "needle", root.url.path]) == [
            "\(root.path("crlf-text.txt")):needle one",
            "\(root.path("crlf-text.txt")):needle two",
        ])
        let crlfThenNullData = try runExecutableData([
            "--sort=path",
            "--crlf",
            "--null-data",
            "needle",
            root.url.path,
        ]) {}
        #expect(crlfThenNullData == Data((
            "\(root.path("crlf-binary.dat")):needle\n\0" +
            "\(root.path("crlf-text.txt")):alpha\nneedle one\nneedle two\ntail\n\0"
        ).utf8))
        #expect(try run(["--sort=path", "--binary", "--null-data", "--crlf", "needle", root.url.path]) == [
            #"\#(root.path("crlf-binary.dat")): binary file matches (found "\0" byte around offset 3)"#,
            "\(root.path("crlf-text.txt")):needle one",
            "\(root.path("crlf-text.txt")):needle two",
        ])
        #expect(try run(["x?", "--crlf", "--color=always", root.path("lf-empty.txt")]) == [
            "\r",
        ])
        let lfOutput = try runExecutableData(["--crlf", "last$", root.path("lf-no-final-newline.txt")]) {}
        #expect(lfOutput == Data("last\r\n".utf8))
    }

}
