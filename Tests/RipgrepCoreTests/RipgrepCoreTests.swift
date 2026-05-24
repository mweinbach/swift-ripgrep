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
        try root.write("é\nπ\n.\n", to: "scalars.txt")

        #expect(try run(["abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["-F", "abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["-F", "--no-fixed-strings", "abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["--no-fixed-strings", "-F", "abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["-w", "abc", root.path("patterns.txt")]) == ["abc.123", "abc", "abc def"])
        #expect(try run(["-x", "abc", root.path("patterns.txt")]) == ["abc"])
        #expect(try run(["-w", "-x", "abc", root.path("patterns.txt")]) == ["abc"])
        #expect(try run(["-x", "-w", "abc", root.path("patterns.txt")]) == ["abc.123", "abc", "abc def"])
        try root.write("abc abc123 123 abc_def x-y foo.bar foo/bar\nempty:\n", to: "word-edges.txt")
        #expect(try run(["-wo", #"\D+"#, root.path("word-edges.txt")]) == [
            "abc",
            "abc_def x-y foo.bar foo/bar",
            "empty:",
        ])
        #expect(try runAllowingNoMatch(["-wo", #"\W+"#, root.path("word-edges.txt")]) == [])
        try root.write("é e\u{301} É π Δ δ привет Привет １２3\n", to: "unicode-word-edges.txt")
        #expect(try run(["-wo", #"[[:^alpha:]]+"#, root.path("unicode-word-edges.txt")]) == [
            "é",
            "É π Δ δ привет Привет １２3",
        ])
        #expect(try run(["-e", ")(", root.path("patterns.txt")]) == ["abc123", "abc.123", "abc", "abc def", "xabc"])
        try root.write("abc\n\n", to: "empty-literal.txt")
        #expect(try run(["-F", "", root.path("empty-literal.txt")]) == ["abc", ""])
        #expect(try run(["-Fo", "", root.path("empty-literal.txt")]) == ["", "", "", "", ""])
        #expect(try run(["-Fc", "", root.path("empty-literal.txt")]) == ["2"])
        #expect(try run(["-Fw", "", root.path("empty-literal.txt")]) == [""])
        #expect(try run(["-Fx", "", root.path("empty-literal.txt")]) == [""])
        #expect(try runAllowingNoMatch(["-Fv", "", root.path("empty-literal.txt")]) == [])
        try root.write("a\nb\nab\nba\n\n", to: "empty-word-regex.txt")
        #expect(try run(["-w", "a*", root.path("empty-word-regex.txt")]) == ["a", ""])
        #expect(try run(["-wo", "a*", root.path("empty-word-regex.txt")]) == ["a", ""])
        #expect(try run(["-w", "--count-matches", "a*", root.path("empty-word-regex.txt")]) == ["2"])
        #expect(try run(["-w", "-bo", "a*", root.path("empty-word-regex.txt")]) == [
            "0:a",
            "10:",
        ])
        #expect(try run(["-w", "-n", "--column", "-o", "a*", root.path("empty-word-regex.txt")]) == [
            "1:1:a",
            "5:1:",
        ])

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
        #expect(try run(["-o", #"\x{E9}"#, root.path("scalars.txt")]) == ["é"])
        #expect(try run(["-o", #"\u{03C0}"#, root.path("scalars.txt")]) == ["π"])
        #expect(try run(["-o", #"\x{2E}"#, root.path("scalars.txt")]) == ["."])
        try root.write("a é z-9_\na\u{0B}b\n", to: "posix.txt")
        #expect(try run(["-o", #"[[:word:]]+"#, root.path("posix.txt")]) == ["a", "z", "9_", "a", "b"])
        #expect(try run(["-o", #"[[:^word:]]+"#, root.path("posix.txt")]) == [" é ", "-", "\u{0B}"])
        #expect(try run(["-o", #"[a[:^word:]]+"#, root.path("posix.txt")]) == ["a é ", "-", "a\u{0B}"])
        let noUnicodeNegatedWord = try runExecutableData([
            "--no-unicode",
            "-o",
            #"[[:^word:]]+"#,
            root.path("posix.txt"),
        ]) {}
        #expect(noUnicodeNegatedWord == Data(" é \n-\n\u{0B}\n".utf8))
        #expect(try run(["-o", #"[[:space:]]+"#, root.path("posix.txt")]) == [" ", " ", "\u{0B}"])
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
        try root.write("abc ABC 123 _ é π\nword-word\nfoo bar\n", to: "posix-alpha.txt")
        try root.write("abc ABC café π δ Δ xyz_123 éx xé\n", to: "scoped-modes.txt")
        try root.write("\n##\n", to: "empty-word.txt")

        #expect(try run(["-o", #"\w+"#, root.path("classes.txt")]) == ["café", "π", "_"])
        #expect(try run(["--no-unicode", "-o", #"\w+"#, root.path("classes.txt")]) == ["caf", "_"])
        #expect(try run(["-o", #"(?-u)\w+"#, root.path("classes.txt")]) == ["caf", "_"])
        #expect(try run(["-w", "x", root.path("words.txt")]) == ["x"])
        #expect(try run(["-won", "x", root.path("words.txt")]) == ["3:x"])
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
        #expect(try run(["-F", "-i", "σ", root.path("casefold.txt")]) == ["Σ", "σ"])
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
        #expect(try runAllowingNoMatch(["--null-data", #"(?-m)bar$"#, root.path("nul-inline-m.txt")]) == [])
        #expect(try run(["--null-data", #"(?-m)^bar"#, root.path("nul-inline-m.txt")]) == ["bar\0"])
        #expect(try run(["--null-data", #"(?-m)bar$"#, root.path("nul-inline-m-no-final.txt")]) == ["bar\0"])
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
        #expect(try run(["-n", "-E", "utf-16be", "needle", root.path("bom16be.txt")]) == ["1:needle"])
        #expect(try run(["-n", "-E", "utf-16le", "needle", root.path("bom16be.txt")]) == ["1:needle"])
        #expect(try run(["-n", "-E", "utf-16be", "needle", root.path("bom16le.txt")]) == ["2:needle"])
        #expect(try runAllowingNoMatch(["-n", "-E", "none", "needle", root.path("bom16le.txt")]) == [])
        #expect(try run(["-n", "-E", "utf-16le", "needle", root.path("utf16le.txt")]) == ["2:needle"])
        #expect(try run(["-n", "needle", root.path("bom8.txt")]) == ["1:needle"])
        #expect(try run(["-a", "-n", "needle", root.path("bom16le.txt")]) == ["2:needle"])
        #expect(try run(["--text", "-n", "needle", root.path("bom16le.txt")]) == ["2:needle"])
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
        #expect(try runAllowingNoMatch(["caf.", root.path("latin1.txt")]) == [])
        #expect(try runAllowingNoMatch(["--no-encoding", "caf.", root.path("latin1.txt")]) == [])
        let invalidAutomaticLineOutput = try runExecutableData(["needle", root.path("latin1.txt")], fixture: {})
        #expect(invalidAutomaticLineOutput == Data([
            0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x20, 0x63, 0x61, 0x66, 0xE9, 0x0A,
        ]))
        #expect(try run(["--encoding", "latin1", "caf.", root.path("latin1.txt")]) == [
            "café",
            "needle café",
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
        #expect(try run(["-U", "--count-matches", "$", root.path("zero-width.txt")]) == ["3"])
        #expect(try run(["-U", "--count-matches", "(?:)", root.path("zero-width.txt")]) == ["7"])
        #expect(try run(["-U", "--count-matches", "x?", root.path("zero-width.txt")]) == ["7"])
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
        try root.write("a\r\nb\r\n", to: "plain-crlf.txt")
        try root.write("\n", to: "lf-empty.txt")
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
        #expect(try run(["-U", "--crlf", "--count-matches", "$", root.path("crlf-no-final-newline.txt")]) == [
            "1\r",
        ])
        #expect(try run(["-U", "--crlf", "-n", "$", root.path("crlf-no-final-newline.txt")]) == [
            "1:foo\r",
            "2:bar\r",
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
        #expect(try runAllowingNoMatch(["-n", #"(?-R:foo$)"#, root.path("crlf.txt")]) == [])
        #expect(try runAllowingNoMatch(["-n", #"(?R-m:foo$)"#, root.path("crlf.txt")]) == [])
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
        try root.write("""
        #!/bin/sh
        printf 'needle\\n\\0tail needle\\n'
        """, to: "pre-binary.sh")
        try root.makeExecutable("pre-binary.sh")
        #expect(try run(["--pre", root.path("pre-binary.sh"), "needle", root.path("doc.md")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
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
        #expect(try run(["--trim", "--color=always", "needle", root.path("a.txt")]) == [
            "alpha \(reset)\(redBold)needle\(reset) beta",
        ])
        #expect(try run(["--vimgrep", "--color=always", "needle", root.path("a.txt")]) == [
            "\(reset)\(magenta)\(root.path("a.txt"))\(reset):\(reset)\(green)1\(reset):\(reset)7\(reset):alpha \(reset)\(redBold)needle\(reset) beta",
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

    @Test("handles binary detection modes")
    func handlesBinaryDetectionModes() throws {
        let root = try TemporaryDirectory()
        try root.write(Data("needle\0tail\n".utf8), to: "bin.dat")
        try root.write(Data("needle\n\0tail\n".utf8), to: "before-nul.dat")
        try root.write(Data("foo\0needle\0bar\0".utf8), to: "nul-anchors.dat")

        #expect(try runAllowingNoMatch(["-n", "needle", root.url.path]) == [])
        #expect(try runAllowingNoMatch(["tail", root.url.path]) == [])
        #expect(try run(["needle", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run([#"[^\x00]"#, root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-U", "tail", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-U", "$", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        let multilineBinaryEndOutput = try runExecutableData([
            "-U",
            "-a",
            "$",
            root.path("bin.dat"),
        ], fixture: {})
        #expect(multilineBinaryEndOutput == Data("needle\0tail\n".utf8))
        #expect(try run(["-U", "-a", "--count-matches", "$", root.path("bin.dat")]) == [
            "1",
        ])
        #expect(try runAllowingNoMatch(["-U", "needle.tail", root.path("bin.dat")]) == [])
        #expect(try run(["-U", "--multiline-dotall", "needle.tail", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-U", #"(?s)needle.*tail"#, root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["--encoding", "utf-8", "needle", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["--encoding", "latin1", "needle", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try runAllowingNoMatch(["-U", #"needle\ntail"#, root.path("bin.dat")]) == [])
        #expect(try run(["-n", "needle", root.path("before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["-n", "tail", root.path("before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["-A1", "needle", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-A1", "needle", root.path("before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["-0", "-A1", "needle", root.path("before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["^needle", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try run(["foo$", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try run(["-A1", "^needle", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try runAllowingNoMatch(["-B1", "^needle", root.path("nul-anchors.dat")]) == [])
        #expect(try runAllowingNoMatch(["-C1", "^needle", root.path("nul-anchors.dat")]) == [])
        #expect(try run(["-B1", "foo$", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try runAllowingNoMatch(["--passthru", "^needle", root.path("nul-anchors.dat")]) == [])
        #expect(try run(["--passthru", "foo$", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try runAllowingNoMatch(["-v", "[a-z]+", root.path("nul-anchors.dat")]) == [])
        #expect(try runAllowingNoMatch(["--text", "^needle", root.path("nul-anchors.dat")]) == [])
        #expect(try run(["-c", "needle", root.path("before-nul.dat")]) == ["1"])
        #expect(pathBasenames(try run(["--sort=path", "--binary", "needle", root.url.path])) == [
            "before-nul.dat",
            "bin.dat",
            "nul-anchors.dat",
        ])

        try root.write(Data("a\0needle\nb\0\n".utf8), to: "text-multiline-nul.dat")
        let multilineTextNULOutput = try runExecutableData([
            "-U",
            "-a",
            "needle",
            root.path("text-multiline-nul.dat"),
        ], fixture: {})
        #expect(multilineTextNULOutput == Data("a\0needle\n".utf8))

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

        try countRoot.write(Data("abc\0needle\nneedle2\0tail\n".utf8), to: "post-nul.txt")
        let explicitPostNulStats = try run(["--stats", "needle", countRoot.path("post-nul.txt")])
        #expect(explicitPostNulStats.contains("1 matches"))
        #expect(explicitPostNulStats.contains("11 bytes searched"))
        let passthruPostNulStats = runWithExitCode(
            ["--stats", "--passthru", "needle", countRoot.path("post-nul.txt")],
            expectedExitCode: 1
        )
        #expect(passthruPostNulStats.contains("0 matches"))
        #expect(passthruPostNulStats.contains("4 bytes searched"))
        let passthruNoMatchBinaryStats = runWithExitCode(
            ["--stats", "--passthru", "zzz", countRoot.path("post-nul.txt")],
            expectedExitCode: 1
        )
        #expect(passthruNoMatchBinaryStats.contains("0 matches"))
        #expect(passthruNoMatchBinaryStats.contains("4 bytes searched"))
        let passthruPostNulJSON = try run(["--json", "--passthru", "needle", countRoot.path("post-nul.txt")])
        let passthruPostNulMessages = try passthruPostNulJSON.map(jsonObject)
        let passthruPostNulEnd = passthruPostNulMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let passthruPostNulJSONStats = passthruPostNulEnd?["stats"] as? [String: Any]
        #expect(passthruPostNulJSONStats?["bytes_searched"] as? Int == 24)
        let jsonNoMatchBinary = runWithExitCode(
            ["-U", "--json", "^bar", countRoot.path("post-nul.txt")],
            expectedExitCode: 1
        )
        let jsonNoMatchMessages = try jsonNoMatchBinary.map(jsonObject)
        let jsonNoMatchSummary = jsonNoMatchMessages.first { $0["type"] as? String == "summary" }?["data"] as? [String: Any]
        let jsonNoMatchStats = jsonNoMatchSummary?["stats"] as? [String: Any]
        #expect(jsonNoMatchStats?["bytes_searched"] as? Int == 3)
        let beforeContextPostNulStats = runWithExitCode(
            ["--stats", "-B1", "needle", countRoot.path("post-nul.txt")],
            expectedExitCode: 1
        )
        #expect(beforeContextPostNulStats.contains("0 matches"))
        #expect(beforeContextPostNulStats.contains("0 bytes searched"))

        var quietBinaryStatsOutput: [String] = []
        let quietBinaryStatsExitCode = RipgrepCLI.run(
            arguments: ["-q", "--stats", "cat", countRoot.path("file1.txt")],
            stdout: { quietBinaryStatsOutput.append($0) }
        )
        #expect(quietBinaryStatsExitCode == 0)
        #expect(quietBinaryStatsOutput.contains("3 matches"))
        #expect(quietBinaryStatsOutput.contains("2 matched lines"))
        #expect(quietBinaryStatsOutput.contains("26 bytes searched"))

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

        stdinOutput = []
        stdinExitCode = RipgrepCLI.run(
            arguments: ["--passthru", "tail", "-"],
            stdout: { stdinOutput.append($0) },
            stdin: "needle\n\0tail\n"
        )
        #expect(stdinExitCode == 1)
        #expect(stdinOutput == [])

        stdinOutput = []
        stdinExitCode = RipgrepCLI.run(
            arguments: ["-B1", "tail", "-"],
            stdout: { stdinOutput.append($0) },
            stdin: "needle\n\0tail\n"
        )
        #expect(stdinExitCode == 1)
        #expect(stdinOutput == [])

        let stdinContextFile = try TemporaryDirectory()
        try stdinContextFile.write("file needle\nfile tail\n", to: "file.txt")
        stdinOutput = []
        stdinExitCode = RipgrepCLI.run(
            arguments: ["-A1", "tail", stdinContextFile.path("file.txt"), "-"],
            stdout: { stdinOutput.append($0) },
            stdin: "needle\0tail\n"
        )
        #expect(stdinExitCode == 0)
        #expect(stdinOutput == [
            "\(stdinContextFile.path("file.txt")):file tail",
            #"<stdin>: binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-a", "needle", root.path("bin.dat")]) == [
            "needle\0tail",
        ])
        #expect(try run(["-c", "needle", root.path("bin.dat")]) == ["1"])
        #expect(pathBasenames(try run(["-l", "needle", root.path("bin.dat")])) == ["bin.dat"])

        try root.write(Data("pre\nneedle before\n\0binary needle after\n".utf8), to: "binary-counts.dat")
        #expect(try run(["-c", "needle", root.path("binary-counts.dat")]) == ["2"])
        #expect(try run(["--count-matches", "needle", root.path("binary-counts.dat")]) == ["2"])
        let jsonBinaryOutput = try run(["--json", "needle", root.path("binary-counts.dat")])
        let jsonBinaryMessages = try jsonBinaryOutput.map(jsonObject)
        #expect(jsonBinaryMessages.filter { $0["type"] as? String == "match" }.count == 2)
        let jsonBinaryMatches = jsonBinaryMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        let jsonBinarySecondLines = jsonBinaryMatches[1]["lines"] as? [String: String]
        let jsonBinarySecondSubmatches = jsonBinaryMatches[1]["submatches"] as? [[String: Any]]
        #expect(jsonBinarySecondLines?["text"] == "binary needle after\n")
        #expect(jsonBinarySecondSubmatches?.first?["start"] as? Int == 7)
        let jsonBinaryEnd = jsonBinaryMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let jsonBinaryStats = jsonBinaryEnd?["stats"] as? [String: Any]
        #expect(jsonBinaryStats?["matches"] as? Int == 2)

        try root.write(Data("bin\0needle\npost\0tail needle\n".utf8), to: "binary-multiline-json.dat")
        let multilineBinaryJSONOutput = try run(["-U", "--json", "needle", root.path("binary-multiline-json.dat")])
        let multilineBinaryJSONMessages = try multilineBinaryJSONOutput.map(jsonObject)
        let multilineBinaryJSONMatches = multilineBinaryJSONMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        #expect(multilineBinaryJSONMatches.map { $0["line_number"] as? Int } == [2, 4])
        #expect(multilineBinaryJSONMatches.compactMap { ($0["lines"] as? [String: String])?["text"] } == [
            "needle\n",
            "tail needle\n",
        ])
        let multilineBinaryJSONSecondSubmatches = multilineBinaryJSONMatches[1]["submatches"] as? [[String: Any]]
        #expect(multilineBinaryJSONSecondSubmatches?.first?["start"] as? Int == 5)
        #expect(multilineBinaryJSONSecondSubmatches?.first?["end"] as? Int == 11)
        let multilineBinaryDotAllJSONOutput = try run([
            "-U",
            "--multiline-dotall",
            "--json",
            "needle.post",
            root.path("binary-multiline-json.dat"),
        ])
        let multilineBinaryDotAllJSONMessages = try multilineBinaryDotAllJSONOutput.map(jsonObject)
        let multilineBinaryDotAllJSONMatch = multilineBinaryDotAllJSONMessages.first {
            $0["type"] as? String == "match"
        }?["data"] as? [String: Any]
        let multilineBinaryDotAllJSONLines = multilineBinaryDotAllJSONMatch?["lines"] as? [String: String]
        let multilineBinaryDotAllJSONEnd = multilineBinaryDotAllJSONMessages.first {
            $0["type"] as? String == "end"
        }?["data"] as? [String: Any]
        let multilineBinaryDotAllJSONStats = multilineBinaryDotAllJSONEnd?["stats"] as? [String: Any]
        #expect(multilineBinaryDotAllJSONMatch?["line_number"] as? Int == 1)
        #expect(multilineBinaryDotAllJSONMatch?["absolute_offset"] as? Int == 0)
        #expect(multilineBinaryDotAllJSONLines?["text"] == "bin\0needle\npost\0tail needle\n")
        #expect(multilineBinaryDotAllJSONStats?["bytes_searched"] as? Int == 3)

        try root.write(Data("needle\0tail\0needle tail\0".utf8), to: "binary-multiline-records.dat")
        let multilineBinaryRecordsJSONOutput = try run(["-U", "--json", "needle", root.path("binary-multiline-records.dat")])
        let multilineBinaryRecordsJSONMessages = try multilineBinaryRecordsJSONOutput.map(jsonObject)
        let multilineBinaryRecordsJSONMatches = multilineBinaryRecordsJSONMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        #expect(multilineBinaryRecordsJSONMatches.map { $0["line_number"] as? Int } == [1, 3])
        #expect(multilineBinaryRecordsJSONMatches.compactMap { ($0["lines"] as? [String: String])?["text"] } == [
            "needle\n",
            "needle tail\n",
        ])
        let multilineBinaryRecordsContextOutput = try run(["-U", "--json", "-A1", "needle", root.path("binary-multiline-records.dat")])
        let multilineBinaryRecordsContextMessages = try multilineBinaryRecordsContextOutput.map(jsonObject)
        #expect(multilineBinaryRecordsContextMessages.compactMap { $0["type"] as? String } == [
            "begin",
            "match",
            "context",
            "match",
            "end",
            "summary",
        ])
        let multilineBinaryClassJSONOutput = try run(["-U", "--json", #"[^\n]+"#, root.path("binary-multiline-records.dat")])
        let multilineBinaryClassJSONMessages = try multilineBinaryClassJSONOutput.map(jsonObject)
        let multilineBinaryClassJSONMatches = multilineBinaryClassJSONMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        #expect(multilineBinaryClassJSONMatches.compactMap { ($0["lines"] as? [String: String])?["text"] } == [
            "needle\n",
            "tail\n",
            "needle tail\n",
        ])
        let multilineBinaryBoundaryJSONOutput = try run(["-U", "--json", #"\b"#, root.path("binary-multiline-records.dat")])
        let multilineBinaryBoundaryJSONMessages = try multilineBinaryBoundaryJSONOutput.map(jsonObject)
        let multilineBinaryBoundaryJSONMatches = multilineBinaryBoundaryJSONMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        let multilineBinaryBoundarySubmatches = multilineBinaryBoundaryJSONMatches.compactMap { $0["submatches"] as? [[String: Any]] }
        #expect(multilineBinaryBoundarySubmatches.map(\.count) == [2, 2, 4])

        let multilineBinaryAnchorJSONOutput = try run(["-U", "--json", "^", root.path("binary-multiline-json.dat")])
        let multilineBinaryAnchorJSONMessages = try multilineBinaryAnchorJSONOutput.map(jsonObject)
        let multilineBinaryAnchorEnd = multilineBinaryAnchorJSONMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let multilineBinaryAnchorStats = multilineBinaryAnchorEnd?["stats"] as? [String: Any]
        #expect(multilineBinaryAnchorStats?["bytes_searched"] as? Int == 3)

        let multilineBinaryEndJSONOutput = try run(["-U", "--json", "$", root.path("binary-multiline-records.dat")])
        let multilineBinaryEndJSONMessages = try multilineBinaryEndJSONOutput.map(jsonObject)
        let multilineBinaryEndJSONMatch = multilineBinaryEndJSONMessages.first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let multilineBinaryEndJSONSubmatches = multilineBinaryEndJSONMatch?["submatches"] as? [[String: Any]]
        let multilineBinaryEndJSONEnd = multilineBinaryEndJSONMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let multilineBinaryEndJSONStats = multilineBinaryEndJSONEnd?["stats"] as? [String: Any]
        #expect(multilineBinaryEndJSONSubmatches?.isEmpty == true)
        #expect(multilineBinaryEndJSONStats?["matches"] as? Int == 0)

        try root.write(Data("needle\0tail needle\n".utf8), to: "binary-same-line.dat")
        let sameLineJSONOutput = try run(["--json", "needle", root.path("binary-same-line.dat")])
        let sameLineJSONMessages = try sameLineJSONOutput.map(jsonObject)
        let sameLineJSONMatches = sameLineJSONMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        let sameLineFirstLines = sameLineJSONMatches[0]["lines"] as? [String: String]
        let sameLineSecondLines = sameLineJSONMatches[1]["lines"] as? [String: String]
        let sameLineSecondSubmatches = sameLineJSONMatches[1]["submatches"] as? [[String: Any]]
        #expect(sameLineFirstLines?["text"] == "needle\n")
        #expect(sameLineJSONMatches[0]["line_number"] as? Int == 1)
        #expect(sameLineSecondLines?["text"] == "tail needle\n")
        #expect(sameLineJSONMatches[1]["line_number"] as? Int == 2)
        #expect(sameLineSecondSubmatches?.first?["start"] as? Int == 5)

        let sameLineContextOutput = try run(["--json", "-A1", "needle", root.path("binary-same-line.dat")])
        let sameLineContextMessages = try sameLineContextOutput.map(jsonObject)
        #expect(sameLineContextMessages.map { $0["type"] as? String } == ["begin", "match", "match", "end", "summary"])

        try root.write(Data("\0needle\n".utf8), to: "binary-leading-nul.dat")
        let leadingContextOutput = try run(["--json", "-B1", "needle", root.path("binary-leading-nul.dat")])
        let leadingContextMessages = try leadingContextOutput.map(jsonObject)
        #expect(leadingContextMessages.map { $0["type"] as? String } == ["begin", "context", "match", "end", "summary"])

        try root.write(Data("a\0b\nneedle\n".utf8), to: "binary-later-line.dat")
        let laterLineOutput = try run(["--json", "-B1", "needle", root.path("binary-later-line.dat")])
        let laterLineMessages = try laterLineOutput.map(jsonObject)
        let laterLineContext = laterLineMessages[1]["data"] as? [String: Any]
        let laterLineContextLines = laterLineContext?["lines"] as? [String: String]
        let laterLineMatch = laterLineMessages[2]["data"] as? [String: Any]
        #expect(laterLineContextLines?["text"] == "b\n")
        #expect(laterLineContext?["line_number"] as? Int == 2)
        #expect(laterLineMatch?["line_number"] as? Int == 3)

        try root.write(Data("needle\0tail\nneedle\n".utf8), to: "binary-split-and-later.dat")
        let splitAndLaterOutput = try run(["--json", "-A1", "needle", root.path("binary-split-and-later.dat")])
        let splitAndLaterMessages = try splitAndLaterOutput.map(jsonObject)
        let splitAndLaterTypes = splitAndLaterMessages.map { $0["type"] as? String }
        let splitContext = splitAndLaterMessages[2]["data"] as? [String: Any]
        let splitContextLines = splitContext?["lines"] as? [String: String]
        let splitLaterMatch = splitAndLaterMessages[3]["data"] as? [String: Any]
        #expect(splitAndLaterTypes == ["begin", "match", "context", "match", "end", "summary"])
        #expect(splitContextLines?["text"] == "tail\n")
        #expect(splitContext?["line_number"] as? Int == 2)
        #expect(splitLaterMatch?["line_number"] as? Int == 3)

        try root.write(Data("needle\n\0tail needle\n".utf8), to: "binary-max-context.dat")
        let binaryMaxContextOutput = try run(["--json", "-m1", "-A2", "needle", root.path("binary-max-context.dat")])
        let binaryMaxContextMessages = try binaryMaxContextOutput.map(jsonObject)
        #expect(binaryMaxContextMessages.map { $0["type"] as? String } == [
            "begin",
            "match",
            "context",
            "match",
            "end",
            "summary",
        ])
        let binaryMaxContextEnd = binaryMaxContextMessages[4]["data"] as? [String: Any]
        let binaryMaxContextStats = binaryMaxContextEnd?["stats"] as? [String: Any]
        #expect(binaryMaxContextStats?["matched_lines"] as? Int == 2)
        #expect(binaryMaxContextStats?["matches"] as? Int == 2)

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

    private func runWithExitCode(_ arguments: [String], expectedExitCode: Int) -> [String] {
        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: arguments,
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(errors.isEmpty)
        #expect(exitCode == expectedExitCode)
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

    var utf16BigEndianBytes: [UInt8] {
        utf16.flatMap { codeUnit in
            [
                UInt8((codeUnit & 0xFF00) >> 8),
                UInt8(codeUnit & 0x00FF),
            ]
        }
    }
}
