import Foundation
import Testing
@testable import RipgrepCore

@Suite("Ripgrep searcher", .serialized)
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

        #expect(Set(matches.map(\.line)) == Set(["another needle", "needle here"]))
        #expect(Dictionary(uniqueKeysWithValues: matches.map { ($0.line, $0.lineNumber) }) == [
            "another needle": 1,
            "needle here": 2,
        ])
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
        #expect(try run(["-e", ")(", root.path("patterns.txt")]) == ["abc123", "abc.123", "abc", "abc def", "xabc"])
        try root.write("abc\n\n", to: "empty-literal.txt")
        #expect(try run(["-F", "", root.path("empty-literal.txt")]) == ["abc", ""])
        #expect(try run(["-Fo", "", root.path("empty-literal.txt")]) == ["", "", "", "", ""])
        #expect(try run(["-Fc", "", root.path("empty-literal.txt")]) == ["2"])
        #expect(try run(["-Fw", "", root.path("empty-literal.txt")]) == [""])
        #expect(try run(["-Fx", "", root.path("empty-literal.txt")]) == [""])
        #expect(try runAllowingNoMatch(["-Fv", "", root.path("empty-literal.txt")]) == [])

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: [#"foo\x00?"#, root.path("patterns.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["""
        rg: pattern contains "\\0" but it is impossible to match

        Consider enabling text mode with the --text flag (or -a for short). Otherwise,
        binary detection is enabled and matching a NUL byte is impossible.
        """])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--binary", #"foo\x00?"#, root.path("patterns.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors.first?.contains("pattern contains") == true)

        #expect(try run(["-a", #"abc\x00?"#, root.path("patterns.txt")]) == ["abc123", "abc.123", "abc", "abc def", "xabc"])
        #expect(try runAllowingNoMatch(["-F", #"foo\x00?"#, root.path("patterns.txt")]) == [])
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
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["""
        rg: regex could not be compiled with either the default regex engine or with PCRE2.

        default regex engine error:
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        regex parse error:
            (?:(?<=a)b)
               ^^^^
        error: look-around, including look-ahead and look-behind, is not supported
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

        PCRE2 regex engine error:
        PCRE2 is not available in this build of ripgrep
        """])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["-o", "-P", #"(?<=a)b"#, root.path("engine.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: PCRE2 is not available in this build of ripgrep"])

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
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors.joined(separator: "\n").contains("PCRE2 is not available"))

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

        #expect(try run(["--regex-size-limit=0", "needle", root.path("limit.txt")]) == ["needle"])

        #expect(try run(["--regex-size-limit=1K", "needle", root.path("limit.txt")]) == ["needle"])

        #expect(try run(["--regex-size-limit=1", "abc", root.path("limit.txt")]) == ["abc"])

        #expect(try run(["--regex-size-limit=4", "-e", "abc", "-e", "def", root.path("limit.txt")]) == [
            "abc",
            "def",
        ])
    }

    @Test("honors no unicode regex and literal semantics")
    func honorsNoUnicodeSemantics() throws {
        let root = try TemporaryDirectory()
        try root.write("café\nπ\n_\n", to: "classes.txt")
        try root.write("éx\nxé\nx\n", to: "words.txt")
        try root.write("Σ\nσ\n", to: "casefold.txt")
        try root.write("ABC\nabc\nδ\n", to: "ascii-case.txt")
        try root.write("\n##\n", to: "empty-word.txt")

        #expect(try run(["-o", #"\w+"#, root.path("classes.txt")]) == ["café", "π", "_"])
        #expect(try run(["--no-unicode", "-o", #"\w+"#, root.path("classes.txt")]) == ["caf", "_"])
        #expect(try run(["-w", "x", root.path("words.txt")]) == ["x"])
        #expect(try run(["-won", "x", root.path("words.txt")]) == ["3:x"])
        #expect(try run(["-won", "", root.path("empty-word.txt")]) == ["1:", "2:", "2:", "2:"])
        #expect(try run(["--no-unicode", "-w", "x", root.path("words.txt")]) == ["éx", "xé", "x"])
        #expect(try run(["-F", "-i", "σ", root.path("casefold.txt")]) == ["Σ", "σ"])
        #expect(try run(["--no-unicode", "-F", "-i", "σ", root.path("casefold.txt")]) == ["σ"])
        #expect(try run(["--no-unicode", "-i", "abc", root.path("ascii-case.txt")]) == ["ABC", "abc"])
        #expect(try run(["--no-unicode", "-i", "[a-z]+", root.path("ascii-case.txt")]) == ["ABC", "abc"])
        #expect(try run(["--no-unicode", "-i", "[[:alpha:]]+", root.path("ascii-case.txt")]) == ["ABC", "abc"])
        #expect(try runAllowingNoMatch(["--no-unicode", "-i", "Δ", root.path("ascii-case.txt")]) == [])
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
        try root.write("", to: "zero-patterns")
        try root.write("\n", to: "empty-pattern")

        #expect(try run(["-e", "alpha", "-e", "gamma", root.path("words.txt")]) == ["alpha", "gamma"])
        #expect(try run(["-f", root.path("patterns"), root.path("words.txt")]) == ["alpha", "gamma"])
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
        #expect(try run(["-H", "-c", "needle", root.path("one.txt")]) == [
            "\(root.path("one.txt")):2",
        ])
        #expect(try run(["-l", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["one.txt"])
        #expect(try run(["--files", "-l", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["one.txt"])
        #expect(try run(["--files", "--files-without-match", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["two.txt"])
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
        let executableOutput = try runExecutableData(["-l", "--null", "needle", root.url.path]) {}
        #expect(executableOutput == Data("\(root.path("dir/one.txt"))\0".utf8))
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
        #expect(errors == [
            """
            rg: error parsing flag --path-separator: A path separator must be exactly one byte, but the given separator is 2 bytes: ø
            In some shells on Windows '/' is automatically expanded. Use '//' instead.
            """,
        ])
    }

    @Test("limits matching lines per file")
    func limitsMatchingLinesPerFile() throws {
        let root = try TemporaryDirectory()
        try root.write("needle one\nneedle two\nneedle three\n", to: "many.txt")

        #expect(try run(["-m1", "needle", root.path("many.txt")]) == ["needle one"])
        #expect(try run(["--max-count", "2", "needle", root.path("many.txt")]) == ["needle one", "needle two"])
        #expect(try run(["-m1", "-c", "needle", root.path("many.txt")]) == ["1"])

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

        try root.write("éabc\n", to: "unicode-offsets.txt")
        #expect(try run(["-o", "--column", "abc", root.path("unicode-offsets.txt")]) == [
            "1:3:abc",
        ])
        #expect(try run(["-o", "--byte-offset", "--column", "abc", root.path("unicode-offsets.txt")]) == [
            "1:3:2:abc",
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
        try root.write("needle\nunterminated\n", to: "lf.txt")
        #expect(try run(["--null-data", "needle", root.path("lf.txt")]) == [
            "needle\nunterminated\n\0",
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
        #expect(try runAllowingNoMatch(["-n", "-E", "none", "needle", root.path("bom16le.txt")]) == [])
        #expect(try run(["-n", "-E", "utf-16le", "needle", root.path("utf16le.txt")]) == ["2:needle"])
        #expect(try run(["-n", "needle", root.path("bom8.txt")]) == ["1:needle"])
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
        let jsonOutput = try run(["--json", "--encoding", "none", "-a", #"\x00"#, root.path("raw-bytes.txt")])
        let jsonMatch = try jsonOutput.map(jsonObject).first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let jsonLines = jsonMatch?["lines"] as? [String: String]
        let jsonSubmatches = jsonMatch?["submatches"] as? [[String: Any]]
        #expect(jsonLines?["bytes"] == "//4AYg==")
        #expect(jsonSubmatches?.first?["start"] as? Int == 2)
        #expect(jsonSubmatches?.first?["end"] as? Int == 3)
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

        #expect(try run(["-n", "-U", #"foo\nbar"#, root.path("multi.txt")]) == [
            "1:foo",
            "2:bar",
        ])
        #expect(try run(["-U", "-o", #"foo\nbar"#, root.path("multi.txt")]) == [
            "foo",
            "bar",
        ])
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
        #expect(try run(["-U", "--count-matches", "$", root.path("zero-width.txt")]) == ["3"])
        #expect(try run(["-U", "--count-matches", "(?:)", root.path("zero-width.txt")]) == ["7"])
        #expect(try run(["-U", "--count-matches", "x?", root.path("zero-width.txt")]) == ["7"])
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
        try root.write("\n", to: "lf-empty.txt")

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
        #expect(try run(["--crlf", "-o", "foo$", root.path("crlf.txt")]) == [
            "foo\r",
        ])
        #expect(try run(["--crlf", "-o", "baz$", root.path("crlf.txt")]) == [
            "baz\r",
        ])
        #expect(try run(["--crlf", "-o", "quux$", root.path("crlf.txt")]) == [
            "quux\r",
        ])
        try root.write("foo\r\nbar\r\n\r\n", to: "crlf-empty.txt")
        let onlyMatchingEndAnchors = try runExecutableData(["--crlf", "-o", "$", root.path("crlf-empty.txt")]) {}
        #expect(onlyMatchingEndAnchors == Data([13, 10, 13, 10, 13, 10]))
        #expect(try run(["--crlf", "--count-matches", "$", root.path("crlf-empty.txt")]) == [
            "3\r",
        ])
        #expect(try runAllowingNoMatch(["--crlf", "--null-data", "-n", "foo$", root.path("crlf.txt")]) == [])
        #expect(try run(["--null-data", "--crlf", "-n", "foo$", root.path("crlf.txt")]) == [
            "1:foo\r",
        ])
        #expect(try run(["x?", "--crlf", "--color=always", root.path("lf-empty.txt")]) == [
            "\r",
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

        #expect(pathBasenames(try run(["--sort", "path", "needle", root.url.path])) == ["a.txt", "b.txt"])
        #expect(pathBasenames(try run(["--sortr", "path", "needle", root.url.path])) == ["b.txt", "a.txt"])
        #expect(pathBasenames(try run(["--sort", "modified", "needle", root.url.path])) == ["b.txt", "a.txt"])
        #expect(pathBasenames(try run(["--sort-files", "--files", root.url.path])) == ["a.txt", "b.txt"])

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

        let multiRoot = try TemporaryDirectory()
        try multiRoot.write("needle\nafter\n", to: "a.txt")
        try multiRoot.write("needle\nafter\n", to: "b.txt")
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
        #expect(try run(["-o", "--column", "--replace", "X", #"[a-z]+\d+"#, root.path("replace.txt")]) == [
            "1:1:X",
            "1:3:X",
        ])
        #expect(try run(["-o", "--byte-offset", "--replace", "X", #"[a-z]+\d+"#, root.path("replace.txt")]) == [
            "0:X",
            "2:X",
        ])
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
        #expect(try run(["--replace", "${0}f", #".*"#, root.path("empty-match.txt")]) == [
            "af",
            "f",
        ])
        #expect(try run(["--replace", "${}_${bad-name}_${1}", #"([a-z]+)\d+"#, root.path("replace.txt")]) == [
            "${}_${bad-name}_abc ${}_${bad-name}_def",
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
        try root.write("abc123 def456\n", to: "vimgrep-replace.txt")
        #expect(try run(["--vimgrep", "--replace", "X", #"[a-z]+\d+"#, root.path("vimgrep-replace.txt")]) == [
            "\(root.path("vimgrep-replace.txt")):1:1:X X",
            "\(root.path("vimgrep-replace.txt")):1:3:X X",
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
        #expect(try run(["--heading", "-n", "--sort=path", "needle", root.url.path]) == [
            "\(root.path("a.txt"))",
            "1:  needle one needle",
            "",
            "\(root.path("b.txt"))",
            "1:xx needle",
        ])
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
    }

    @Test("prints pretty and ANSI color modes")
    func printsPrettyAndANSIColorModes() throws {
        let root = try TemporaryDirectory()
        try root.write("alpha needle beta\nno\n", to: "a.txt")
        try root.write("needle again\n", to: "b.txt")
        try root.write("\n\ntest\n", to: "empty.txt")

        let reset = "\u{1B}[0m"
        let green = "\u{1B}[32m"
        let magenta = "\u{1B}[35m"
        let redBold = "\u{1B}[1m\u{1B}[31m"

        #expect(try run(["--color=always", "-n", "needle", root.path("a.txt")]) == [
            "\(reset)\(green)1\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
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
            ("match:fg:300", "rg: error parsing flag --colors: unrecognized ansi256 color number, should be '[0-255]' (or a hex number), but is '300'"),
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
        let encodedPath = path.replacingOccurrences(of: " ", with: "%20")
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
        #expect(binaryOnlyMessages.map { $0["type"] as? String } == ["begin", "end", "summary"])
        let binaryOnlyEnd = binaryOnlyMessages[1]["data"] as? [String: Any]
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
        #expect(Set(try run(["--files", "--hidden", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent }) == Set([".hidden.txt", "visible.txt"]))
        #expect(Set(pathBasenames(try run(["--hidden", "e", root.url.path]))) == Set([".hidden.txt", "visible.txt"]))

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
        #expect(errors.contains { $0.contains("DEBUG|swift-ripgrep::walk|") && $0.contains(".hidden.txt: hidden") })
        #expect(errors.contains { $0.contains("DEBUG|swift-ripgrep::walk|") && $0.contains("skip.log: ignore file") })

        output = []
        errors = []
        let filesExitCode = RipgrepCLI.run(
            arguments: ["--debug", "--files", "--sort", "path", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(filesExitCode == 0)
        #expect(output == [root.path("keep.txt")])
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
        #expect(errors.contains { $0.contains("DEBUG|swift-ripgrep::walk|") && $0.contains("ignored-dir") && $0.contains("ignore file") })

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
        #expect(pathBasenames(try run(["--sort", "path", "-tall", "-Tmd", "needle", root.url.path])) == [
            ".hidden.swift",
            "main.rs",
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
        try root.write("needle\n", to: "two.swift")
        try root.write("needle\n", to: "three.rs")

        #expect(pathBasenames(try run(["--type-add", "foo:*.foo", "-tfoo", "needle", root.url.path])) == ["one.foo"])
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
            arguments: ["--type-add", "bad-definition", "needle", root.url.path],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["rg: invalid definition (format is type:glob, e.g., html:*.html)"])

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

        #expect(try runAllowingNoMatch(["-n", "needle", root.url.path]) == [])
        #expect(try runAllowingNoMatch(["tail", root.url.path]) == [])
        #expect(try run(["needle", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-n", "needle", root.path("before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["-n", "tail", root.path("before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["-c", "needle", root.path("before-nul.dat")]) == ["1"])
        #expect(pathBasenames(try run(["--sort=path", "--binary", "needle", root.url.path])) == ["before-nul.dat", "bin.dat"])

        let countRoot = try TemporaryDirectory()
        try countRoot.write(Data("cat cat\npadding\n\0tail cat\n".utf8), to: "file1.txt")
        try countRoot.write("cat here\n", to: "file2.txt")
        #expect(pathBasenames(try run(["--sort=path", "-l", "cat", countRoot.url.path])) == ["file2.txt"])
        #expect(countBasenames(try run(["--sort=path", "-c", "cat", countRoot.url.path])) == ["file2.txt:1"])
        #expect(countBasenames(try run(["--sort=path", "-c", "cat", countRoot.url.path, "--binary"])) == [
            "file1.txt:2",
            "file2.txt:1",
        ])
        #expect(countBasenames(try run(["--sort=path", "-c", "-o", "cat", countRoot.url.path, "--binary"])) == [
            "file1.txt:3",
            "file2.txt:1",
        ])
        #expect(countBasenames(try run(["--sort=path", "--count-matches", "cat", countRoot.url.path, "--binary"])) == [
            "file1.txt:3",
            "file2.txt:1",
        ])
        #expect(countBasenames(try run(["--sort=path", "-c", "cat", countRoot.url.path, "--text"])) == [
            "file1.txt:2",
            "file2.txt:1",
        ])
        let binaryStats = try run(["--stats", "cat", countRoot.path("file1.txt")])
        #expect(binaryStats.contains("2 matches"))
        #expect(binaryStats.contains("1 matched lines"))
        #expect(binaryStats.contains("55 bytes printed"))
        #expect(binaryStats.contains("8 bytes searched"))

        let postNulStats = try run(["--stats", "tail", countRoot.path("file1.txt")])
        #expect(postNulStats.contains("1 matches"))
        #expect(postNulStats.contains("1 matched lines"))
        #expect(postNulStats.contains("26 bytes searched"))

        let withoutRoot = try TemporaryDirectory()
        try withoutRoot.write(Data("hay\0cat\n".utf8), to: "binary.txt")
        try withoutRoot.write("hay\n", to: "text.txt")
        #expect(pathBasenames(try run([
            "--sort=path",
            "--files-without-match",
            "cat",
            withoutRoot.url.path,
        ])) == ["text.txt"])
        var stdinOutput: [String] = []
        var stdinExitCode = RipgrepCLI.run(
            arguments: ["-n", "needle", "-"],
            stdout: { stdinOutput.append($0) },
            stdin: "needle\n\0tail\n"
        )
        #expect(stdinExitCode == 0)
        #expect(stdinOutput == [
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

        let implicitBinary = try TemporaryDirectory()
        try implicitBinary.write(Data("needle\0tail\n".utf8), to: "bin.dat")
        var binaryStatsOutput: [String] = []
        var binaryStatsExitCode = RipgrepCLI.run(
            arguments: ["--stats", "needle", implicitBinary.url.path],
            stdout: { binaryStatsOutput.append($0) }
        )
        #expect(binaryStatsExitCode == 1)
        #expect(binaryStatsOutput.contains("1 files searched"))
        #expect(binaryStatsOutput.contains("0 bytes searched"))

        binaryStatsOutput = []
        binaryStatsExitCode = RipgrepCLI.run(
            arguments: ["--files-without-match", "needle", implicitBinary.url.path],
            stdout: { binaryStatsOutput.append($0) }
        )
        #expect(binaryStatsExitCode == 0)
        #expect(binaryStatsOutput.isEmpty)
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

    @Test("reports unrecognized flags like ripgrep")
    func reportsUnrecognizedFlagsLikeRipgrep() {
        for (arguments, expected) in [
            (["--unknown"], "rg: unrecognized flag --unknown"),
            (["--foo=bar"], "rg: unrecognized flag --foo"),
            (["-Z"], "rg: unrecognized flag -Z"),
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
            (["--max-columns", "nope", "needle"], "rg: error parsing flag --max-columns: value is not a valid number: invalid digit found in string"),
            (["-M", "nope", "needle"], "rg: error parsing flag -M: value is not a valid number: invalid digit found in string"),
            (["--path-separator"], "rg: missing value for flag --path-separator: missing argument for option '--path-separator'"),
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
            arguments: ["--version"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 0)
        #expect(errors.isEmpty)
        #expect(output == ["""
        ripgrep 15.1.0 (rev 4519153e5e)

        features:-pcre2
        simd(compile):+NEON
        simd(runtime):+NEON

        PCRE2 is not available in this build of ripgrep.

        """])
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

        #expect(exitCode == 1)
        #expect(errors.isEmpty)
        #expect(output == ["PCRE2 is not available in this build of ripgrep."])
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

    private func runExecutableData(_ arguments: [String], fixture: () throws -> Void) throws -> Data {
        try fixture()
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/ripgrep")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(errorData.isEmpty)
        #expect(process.terminationStatus == (data.isEmpty ? 1 : 0))
        return data
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
