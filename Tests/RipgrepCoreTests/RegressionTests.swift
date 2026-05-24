import Foundation
import Testing
@testable import RipgrepCore

@Suite("Ripgrep regression parity area", .serialized)
struct RegressionTests {
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
        #expect(errors == ["""
        rg: regex parse error:
            (?:(?<=a)b)
               ^^^^
        error: look-around, including look-ahead and look-behind, is not supported
        """])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: [#"(a)\1"#, root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["""
        rg: regex parse error:
            (?:(a)\\1)
                  ^^
        error: backreferences are not supported
        """])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["[", root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["""
        rg: regex parse error:
            (?:[)
               ^
        error: unclosed character class
        """])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: [#"\q"#, root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["""
        rg: regex parse error:
            (?:\\q)
               ^^
        error: unrecognized escape sequence
        """])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["a{", root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["""
        rg: regex parse error:
            (?:a{)
                 ^
        error: repetition quantifier expects a valid decimal
        """])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["abc)", root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["""
        rg: regex parse error:
            (?:abc))
                   ^
        error: unopened group
        """])

        #expect(try run(["-o", "--engine=auto", "a.", root.path("engine.txt")]) == ["ab", "ac"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-o", "--engine=auto", #"(?<=a)b"#, root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        expectPCRE2LookaroundOutcome(exitCode: exitCode, output: output, errors: errors)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-o", "-P", #"(?<=a)b"#, root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        expectPCRE2LookaroundOutcome(exitCode: exitCode, output: output, errors: errors)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-o", "-P", "--no-pcre2", #"(?<=a)b"#, root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["""
        rg: regex parse error:
            (?:(?<=a)b)
               ^^^^
        error: look-around, including look-ahead and look-behind, is not supported
        """])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-o", "--engine=default", "--auto-hybrid-regex", #"(?<=a)b"#, root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        expectPCRE2LookaroundOutcome(exitCode: exitCode, output: output, errors: errors)

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--engine=bogus", "ab", root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: error parsing flag --engine: unrecognized regex engine 'bogus'"])
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
        #expect(errors == ["rg: error parsing flag --threads: value is not a valid number: invalid digit found in string"])
    }

    @Test("accepts regex size limit")
    func acceptsRegexSizeLimit() throws {
        let root = try TemporaryDirectory()
        try root.write("needle\nabc\ndef\n", to: "limit.txt")

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: ["--regex-size-limit=0", "needle", root.path("limit.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: compiled regex exceeds size limit of 0"])

        #expect(try run(["--regex-size-limit=1K", "needle", root.path("limit.txt")]) == ["needle"])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--regex-size-limit=1", "abc", root.path("limit.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: compiled regex exceeds size limit of 1"])

        #expect(try run(["--regex-size-limit=4", "-e", "abc", "-e", "def", root.path("limit.txt")]) == [
            "abc",
            "def",
        ])
    }

    @Test("reports unrecognized flags like ripgrep")
    func reportsUnrecognizedFlagsLikeRipgrep() {
        for (arguments, expected) in [
            (["--unknown"], "rg: unrecognized flag --unknown"),
            (["--foo=bar"], "rg: unrecognized flag --foo"),
            (["-Z"], "rg: unrecognized flag -Z"),
            (
                ["--replace X"],
                "rg: unrecognized flag --replace X\n\nsimilar flags that are available: --replace"
            ),
            (
                ["--replace \"A B\""],
                "rg: unrecognized flag --replace \"A B\"\n\nsimilar flags that are available: --replace"
            ),
            (
                ["--colo r"],
                "rg: unrecognized flag --colo r\n\nsimilar flags that are available: --color"
            ),
            (
                ["--colorr"],
                "rg: unrecognized flag --colorr\n\nsimilar flags that are available: --color, --colors"
            ),
            (
                ["--sort bad"],
                "rg: unrecognized flag --sort bad"
            ),
            (
                ["--line-number --ignore-case"],
                "rg: unrecognized flag --line-number --ignore-case"
            ),
            (
                ["--ignore-cas"],
                "rg: unrecognized flag --ignore-cas\n\nsimilar flags that are available: --ignore-case, --ignore-file, --ignore, --ignore-dot, --ignore-vcs"
            ),
            (
                ["--files-with-match"],
                "rg: unrecognized flag --files-with-match\n\nsimilar flags that are available: --files-with-matches, --files-without-match"
            ),
            (
                ["--no-color"],
                "rg: unrecognized flag --no-color\n\nsimilar flags that are available: --color, --colors, --no-column"
            ),
            (
                ["--no-colum"],
                "rg: unrecognized flag --no-colum\n\nsimilar flags that are available: --column, --no-column"
            ),
            (
                ["--no-filenam"],
                "rg: unrecognized flag --no-filenam\n\nsimilar flags that are available: --with-filename, --no-filename"
            ),
            (
                ["--unicod"],
                "rg: unrecognized flag --unicod\n\nsimilar flags that are available: --no-unicode, --unicode"
            ),
            (
                ["--messag"],
                "rg: unrecognized flag --messag\n\nsimilar flags that are available: --no-messages, --messages"
            ),
            (
                ["--no-max-filesize"],
                "rg: unrecognized flag --no-max-filesize\n\nsimilar flags that are available: --max-filesize"
            ),
            (
                ["--no-max-columns"],
                "rg: unrecognized flag --no-max-columns\n\nsimilar flags that are available: --no-column, --max-columns, --max-columns-preview, --no-max-columns-preview"
            ),
            (
                ["--no-maxdepth"],
                "rg: unrecognized flag --no-maxdepth\n\nsimilar flags that are available: --maxdepth"
            ),
            (
                ["--maxde"],
                "rg: unrecognized flag --maxde\n\nsimilar flags that are available: --maxdepth"
            ),
            (
                ["--max-depthh"],
                "rg: unrecognized flag --max-depthh\n\nsimilar flags that are available: --max-depth, --maxdepth"
            ),
            (
                ["-uuuu"],
                "rg: error parsing flag -u: flag can only be repeated up to 3 times"
            ),
            (["-inZ"], "rg: unrecognized flag -Z"),
            (["-hZ"], "rg: unrecognized flag -Z"),
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
            #expect(errors == [expected])
        }
    }

    @Test("reports parser diagnostics like ripgrep")
    func reportsParserDiagnosticsLikeRipgrep() {
        for (arguments, expected) in [
            ([], "rg: ripgrep requires at least one pattern to execute a search"),
            (["--regexp"], "rg: missing value for flag --regexp: missing argument for option '--regexp'"),
            (["-e"], "rg: missing value for flag -e: missing argument for option '-e'"),
            (["--file"], "rg: missing value for flag --file: missing argument for option '--file'"),
            (["--color"], "rg: missing value for flag --color: missing argument for option '--color'"),
            (["--sort"], "rg: missing value for flag --sort: missing argument for option '--sort'"),
            (["--threads"], "rg: missing value for flag --threads: missing argument for option '--threads'"),
            (["-C"], "rg: missing value for flag -C: missing argument for option '-C'"),
            (["-C", "nope", "needle"], "rg: error parsing flag -C: value is not a valid number: invalid digit found in string"),
            (["--context", "", "needle"], "rg: error parsing flag --context: value is not a valid number: cannot parse integer from empty string"),
            (["--threads", "999999999999999999999999999999", "needle"], "rg: error parsing flag --threads: value is not a valid number: number too large to fit in target type"),
            (["--max-columns", "nope", "needle"], "rg: error parsing flag --max-columns: value is not a valid number: invalid digit found in string"),
            (["--max-columns", "-0", "needle"], "rg: error parsing flag --max-columns: value is not a valid number: invalid digit found in string"),
            (["--max-count", "", "needle"], "rg: error parsing flag --max-count: value is not a valid number: cannot parse integer from empty string"),
            (["-M", "nope", "needle"], "rg: error parsing flag -M: value is not a valid number: invalid digit found in string"),
            (["--max-filesize", "+1", "needle"], "rg: error parsing flag --max-filesize: invalid size: invalid format for size '+1', which should be a non-empty sequence of digits followed by an optional 'K', 'M' or 'G' suffix"),
            (["--regex-size-limit", "-0", "needle"], "rg: error parsing flag --regex-size-limit: invalid size: invalid format for size '-0', which should be a non-empty sequence of digits followed by an optional 'K', 'M' or 'G' suffix"),
            (["--path-separator"], "rg: missing value for flag --path-separator: missing argument for option '--path-separator'"),
            (["--no-json=true", "needle"], "rg: invalid CLI arguments: unexpected argument for option '--no-json': \"true\""),
            (["--count=1", "needle"], "rg: invalid CLI arguments: unexpected argument for option '--count': \"1\""),
            (["--help=foo"], "rg: invalid CLI arguments: unexpected argument for option '--help': \"foo\""),
            (["--no-context-separator=", "needle"], "rg: invalid CLI arguments: unexpected argument for option '--no-context-separator': \"\""),
            (["--no-byte-offset=x", "needle"], "rg: invalid CLI arguments: unexpected argument for option '--no-byte-offset': \"x\""),
            (["--no-filename=x", "needle"], "rg: invalid CLI arguments: unexpected argument for option '--no-filename': \"x\""),
            (["--hyperlink-format", "{bogus}", "needle"], "rg: error parsing flag --hyperlink-format: invalid hyperlink format: invalid hyperlink format variable: 'bogus', choose from: path, line, column, host, wslprefix"),
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
            #expect(errors == [expected])
        }
    }

    @Test("reports PCRE2 unavailable")
    func reportsPCRE2Unavailable() throws {
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

        #expect(errors.isEmpty)
        if exitCode == 0 {
            #expect(output.count == 1)
            #expect(output.first?.contains("PCRE2") == true)
            #expect(output.first?.contains("is available") == true)
        } else {
            #expect(exitCode == 1)
            #expect(output == ["PCRE2 is not available in this build of ripgrep."])
        }
    }

}

private func expectPCRE2LookaroundOutcome(exitCode: Int32, output: [String], errors: [String]) {
    if exitCode == 0 {
        #expect(output == ["b"])
        #expect(errors.isEmpty)
    } else if exitCode == 1 {
        #expect(output.isEmpty)
        #expect(errors.isEmpty)
    } else {
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        let diagnostic = errors.joined(separator: "\n")
        #expect(
            diagnostic.contains("PCRE2 is not available") ||
                diagnostic.contains("regex could not be compiled")
        )
    }
}
