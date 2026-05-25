import Foundation
import Testing
@testable import RipgrepCore

@Suite("Ripgrep misc parity area", .serialized)
struct MiscTests {
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

    @Test("streams simple Darwin byte literal lines")
    func streamsSimpleDarwinByteLiteralLines() throws {
        #if canImport(Darwin)
        let root = try TemporaryDirectory()
        let file = root.url.appendingPathComponent("letters.txt")
        try root.write("alpha\nbravo\ncharlie\ndelta", to: "letters.txt")

        var options = RipgrepOptions()
        options.pattern = "v|d"
        options.roots = [file]
        options.rootPathArguments = [file.path]

        var output = Data()
        let results = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: options) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            output.append(baseAddress, count: bytes.count)
        }

        #expect(results?.summary.filesWithMatches == 1)
        #expect(results?.summary.matchedLines == 2)
        #expect(output == Data("bravo\ndelta\n".utf8))
        #endif
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
        try root.write(Data("foo\r\nbar\r\nbaz\r\n".utf8), to: "crlf-word-boundary.txt")
        #expect(try runAllowingNoMatch(["-w", #"\b"#, root.path("crlf-word-boundary.txt")]) == [])
        let crlfNotWordBoundaryOutput = try runExecutableData([
            "-w",
            "-bo",
            #"\B"#,
            root.path("crlf-word-boundary.txt"),
        ], fixture: {})
        #expect(crlfNotWordBoundaryOutput == Data("4:\n9:\n14:\n".utf8))
        try root.write("  needle  \nneedle\n##\n", to: "word-boundary-only.txt")
        #expect(try runAllowingNoMatch(["-w", #"\b"#, root.path("word-boundary-only.txt")]) == [])
        #expect(try run(["-w", #"\B"#, root.path("word-boundary-only.txt")]) == [
            "  needle  ",
            "##",
        ])
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

}
