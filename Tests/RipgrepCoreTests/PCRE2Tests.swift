import Foundation
import Testing
@testable import RipgrepCore

@Suite("PCRE2 backend")
struct PCRE2Tests {
    @Test func pcre2LookbehindOnlyMatching() throws {
        let temp = try TemporaryDirectory()
        try temp.write("ab\nac\n", to: "pcre.txt")

        let output = try run(["-P", "-o", "(?<=a)b", temp.path("pcre.txt")])

        #expect(output == ["b"])
    }

    @Test func pcre2PlainLiteralUsesDefaultLiteralFastPath() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock Holmes\nMycroft Holmes\n", to: "pcre.txt")
        guard case .run(let options) = RipgrepArgumentParser.parse([
            "-P",
            "-o",
            "Sherlock",
            temp.path("pcre.txt"),
        ], environment: [:]) else {
            Issue.record("expected -P literal arguments to parse")
            return
        }

        let matcher = try PatternMatcher(options: options)
        let output = try run(["-P", "-o", "Sherlock", temp.path("pcre.txt")])

        #expect(matcher.byteLiteralFastPath() != nil)
        #expect(output == ["Sherlock"])
    }

    @Test func pcre2PlainLiteralExecutablePreflightOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock Holmes\nMycroft Holmes\n", to: "pcre.txt")

        let shortFlagOutput = try runExecutableData(["-P", "Sherlock", temp.path("pcre.txt")]) {}
        let engineFlagOutput = try runExecutableData(["--engine=pcre2", "Sherlock", temp.path("pcre.txt")]) {}
        let splitEngineFlagOutput = try runExecutableData(["--engine", "pcre2", "Sherlock", temp.path("pcre.txt")]) {}
        let autoEngineOutput = try runExecutableData(["--engine=auto", "Sherlock", temp.path("pcre.txt")]) {}
        let splitAutoEngineOutput = try runExecutableData(["--engine", "auto", "Sherlock", temp.path("pcre.txt")]) {}
        let autoHybridOutput = try runExecutableData(["--auto-hybrid-regex", "Sherlock", temp.path("pcre.txt")]) {}
        let noPcreOutput = try runExecutableData(["--no-pcre2", "Sherlock", temp.path("pcre.txt")]) {}
        let ignoreCaseOutput = try runExecutableData(["-P", "-i", "sherlock", temp.path("pcre.txt")]) {}
        let noMmapOutput = try runExecutableData(["-P", "--no-mmap", "Sherlock", temp.path("pcre.txt")]) {}

        #expect(shortFlagOutput == Data("Sherlock Holmes\n".utf8))
        #expect(engineFlagOutput == Data("Sherlock Holmes\n".utf8))
        #expect(splitEngineFlagOutput == Data("Sherlock Holmes\n".utf8))
        #expect(autoEngineOutput == Data("Sherlock Holmes\n".utf8))
        #expect(splitAutoEngineOutput == Data("Sherlock Holmes\n".utf8))
        #expect(autoHybridOutput == Data("Sherlock Holmes\n".utf8))
        #expect(noPcreOutput == Data("Sherlock Holmes\n".utf8))
        #expect(ignoreCaseOutput == Data("Sherlock Holmes\n".utf8))
        #expect(noMmapOutput == Data("Sherlock Holmes\n".utf8))
    }

    @Test func pcre2EscapedLiteralUsesDefaultLiteralFastPath() throws {
        let temp = try TemporaryDirectory()
        try temp.write("[Sherlock].Holmes\nSherlockxHolmes\n", to: "pcre.txt")
        guard case .run(let options) = RipgrepArgumentParser.parse([
            "-P",
            "-o",
            #"\[Sherlock\]\.Holmes"#,
            temp.path("pcre.txt"),
        ], environment: [:]) else {
            Issue.record("expected -P escaped literal arguments to parse")
            return
        }

        let matcher = try PatternMatcher(options: options)
        let output = try run(["-P", "-o", #"\[Sherlock\]\.Holmes"#, temp.path("pcre.txt")])

        #expect(matcher.byteLiteralFastPath() != nil)
        #expect(output == ["[Sherlock].Holmes"])
    }

    @Test func pcre2EscapedLiteralExecutablePreflightOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("[Sherlock].Holmes\nSherlockxHolmes\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", #"\[Sherlock\]\.Holmes"#, temp.path("pcre.txt")]) {}

        #expect(output == Data("[Sherlock].Holmes\n".utf8))
    }

    @Test func pcre2QuotedLiteralUsesDefaultLiteralFastPath() throws {
        let temp = try TemporaryDirectory()
        try temp.write("[Sherlock].Holmes\nSherlockxHolmes\n", to: "pcre.txt")
        guard case .run(let options) = RipgrepArgumentParser.parse([
            "-P",
            "-o",
            #"\Q[Sherlock].Holmes\E"#,
            temp.path("pcre.txt"),
        ], environment: [:]) else {
            Issue.record("expected -P quoted literal arguments to parse")
            return
        }

        let matcher = try PatternMatcher(options: options)
        let output = try run(["-P", "-o", #"\Q[Sherlock].Holmes\E"#, temp.path("pcre.txt")])

        #expect(matcher.byteLiteralFastPath() != nil)
        #expect(output == ["[Sherlock].Holmes"])
    }

    @Test func pcre2QuotedLiteralExecutablePreflightOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("[Sherlock].Holmes\nSherlockxHolmes\n", to: "pcre.txt")

        let pcreOutput = try runExecutableData(["-P", #"\Q[Sherlock].Holmes\E"#, temp.path("pcre.txt")]) {}
        let autoOutput = try runExecutableData([
            "--engine=auto",
            #"\Q[Sherlock].Holmes\E"#,
            temp.path("pcre.txt"),
        ]) {}
        let autoHybridOutput = try runExecutableData([
            "--auto-hybrid-regex",
            #"\Q[Sherlock].Holmes\E"#,
            temp.path("pcre.txt"),
        ]) {}

        #expect(pcreOutput == Data("[Sherlock].Holmes\n".utf8))
        #expect(autoOutput == Data("[Sherlock].Holmes\n".utf8))
        #expect(autoHybridOutput == Data("[Sherlock].Holmes\n".utf8))
    }

    @Test func pcre2QuotedLiteralsRespectDefaultEngineSelection() throws {
        let temp = try TemporaryDirectory()
        try temp.write("[Sherlock].Holmes\n", to: "pcre.txt")
        let expectedQuotedStartError = """
        rg: regex parse error:
            (?:\\Q[Sherlock].Holmes\\E)
               ^^
        error: unrecognized escape sequence
        """
        let expectedQuotedEndError = """
        rg: regex parse error:
            (?:\\E)
               ^^
        error: unrecognized escape sequence
        """

        for arguments in [
            [#"\Q[Sherlock].Holmes\E"#, temp.path("pcre.txt")],
            ["--engine=default", #"\Q[Sherlock].Holmes\E"#, temp.path("pcre.txt")],
            ["--no-pcre2", #"\Q[Sherlock].Holmes\E"#, temp.path("pcre.txt")],
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
            #expect(errors == [expectedQuotedStartError])
        }

        for arguments in [
            [#"\E"#, temp.path("pcre.txt")],
            ["--engine=default", #"\E"#, temp.path("pcre.txt")],
            ["--no-pcre2", #"\E"#, temp.path("pcre.txt")],
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
            #expect(errors == [expectedQuotedEndError])
        }
    }

    @Test func pcre2StandaloneQuoteEndMatchesEveryLine() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock\nMycroft\n", to: "pcre.txt")

        let pcreOutput = try run(["-P", #"\E"#, temp.path("pcre.txt")])
        let autoOutput = try run(["--engine=auto", #"\E"#, temp.path("pcre.txt")])

        #expect(pcreOutput == ["Sherlock", "Mycroft"])
        #expect(autoOutput == ["Sherlock", "Mycroft"])
    }

    @Test func pcre2QuotedLookbehindExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock.Holmes\nSherlockxHolmes\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-o", #"(?<=\QSherlock.\E)Holmes"#, temp.path("pcre.txt")]) {}

        #expect(output == Data("Holmes\n".utf8))
    }

    @Test func pcre2QuotedPartialRegexFallsBackThroughSwiftRegex() throws {
        let temp = try TemporaryDirectory()
        try temp.write("[Sherlock].Holmes\n[Sherlock].123\nSherlockxHolmes\n", to: "pcre.txt")

        let output = try run(["-P", "-o", #"\Q[Sherlock].\E\w+"#, temp.path("pcre.txt")])

        #expect(output == ["[Sherlock].Holmes", "[Sherlock].123"])
    }

    @Test func pcre2NonNewlineEscapeOnlyMatching() throws {
        let temp = try TemporaryDirectory()
        try temp.write("ab\nc d\n\n", to: "pcre.txt")

        let pcreOutput = try run(["-P", "-o", #"\N"#, temp.path("pcre.txt")])
        let autoOutput = try run(["--engine=auto", "-o", #"\N"#, temp.path("pcre.txt")])
        let composedOutput = try run(["-P", "-o", #"\Nfoo"#, temp.path("pcre.txt")])

        #expect(pcreOutput == ["a", "b", "c", " ", "d"])
        #expect(autoOutput == ["a", "b", "c", " ", "d"])
        #expect(composedOutput.isEmpty)
    }

    @Test func pcre2NonNewlineEscapeRespectsDefaultEngineSelection() throws {
        let temp = try TemporaryDirectory()
        try temp.write("ab\n", to: "pcre.txt")
        let expected = """
        rg: regex parse error:
            (?:\\N)
               ^^
        error: unrecognized escape sequence
        """

        for arguments in [
            [#"\N"#, temp.path("pcre.txt")],
            ["--engine=default", #"\N"#, temp.path("pcre.txt")],
            ["--no-pcre2", #"\N"#, temp.path("pcre.txt")],
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

        var pcreOutput: [String] = []
        var pcreErrors: [String] = []
        let pcreExitCode = RipgrepCLI.run(
            arguments: ["-P", #"\N{LATIN CAPITAL LETTER A}"#, temp.path("pcre.txt")],
            stdout: { pcreOutput.append($0) },
            stderr: { pcreErrors.append($0) }
        )

        #expect(pcreExitCode == 2)
        #expect(pcreOutput.isEmpty)
        #expect(!pcreErrors.isEmpty)
    }

    @Test func pcre2ByteUnitEscapeOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write(Data([0x63, 0x61, 0x66, 0xC3, 0xA9, 0x0A, 0x61, 0x62, 0x63, 0x0A]), to: "pcre.txt")
        try temp.write(Data([0xA9, 0x61, 0x62, 0x63, 0x0A]), to: "invalid-prefix.txt")

        let unicodeSingle = try runExecutableData(["-P", "-o", #"\C"#, temp.path("pcre.txt")]) {}
        let byteSingle = try runExecutableData([
            "-P",
            "--no-pcre2-unicode",
            "-o",
            #"\C"#,
            temp.path("pcre.txt"),
        ]) {}
        let oneOrMore = try runExecutableData(["-P", "-o", #"\C+"#, temp.path("pcre.txt")]) {}
        let fixedTwo = try runExecutableData(["-P", "-o", #"\C{2}"#, temp.path("pcre.txt")]) {}
        let autoSingle = try runExecutableData(["--engine=auto", "-o", #"\C"#, temp.path("pcre.txt")]) {}
        let invalidPrefixOneOrMore = try runExecutableData(["-P", "-o", #"\C+"#, temp.path("invalid-prefix.txt")]) {}
        let invalidPrefixByteOneOrMore = try runExecutableData([
            "-P",
            "--no-pcre2-unicode",
            "-o",
            #"\C+"#,
            temp.path("invalid-prefix.txt"),
        ]) {}
        let lazyOneOrMore = try runExecutableData(["-P", "-o", #"\C+?"#, temp.path("invalid-prefix.txt")]) {}

        #expect(unicodeSingle == Data([0x63, 0x0A, 0x61, 0x0A, 0x66, 0x0A, 0xC3, 0x0A, 0x61, 0x0A, 0x62, 0x0A, 0x63, 0x0A]))
        #expect(byteSingle == Data([0x63, 0x0A, 0x61, 0x0A, 0x66, 0x0A, 0xC3, 0x0A, 0xA9, 0x0A, 0x61, 0x0A, 0x62, 0x0A, 0x63, 0x0A]))
        #expect(oneOrMore == Data([0x63, 0x61, 0x66, 0xC3, 0xA9, 0x0A, 0x61, 0x62, 0x63, 0x0A]))
        #expect(fixedTwo == Data([0x63, 0x61, 0x0A, 0x66, 0xC3, 0x0A, 0x61, 0x62, 0x0A]))
        #expect(autoSingle == unicodeSingle)
        #expect(invalidPrefixOneOrMore == Data([0x61, 0x62, 0x63, 0x0A]))
        #expect(invalidPrefixByteOneOrMore == Data([0xA9, 0x61, 0x62, 0x63, 0x0A]))
        #expect(lazyOneOrMore == Data([0x61, 0x0A, 0x62, 0x0A, 0x63, 0x0A]))
    }

    @Test func pcre2ByteUnitEscapeRespectsDefaultEngineSelection() throws {
        let temp = try TemporaryDirectory()
        try temp.write("ab\n", to: "pcre.txt")
        let expected = """
        rg: regex parse error:
            (?:\\C)
               ^^
        error: unrecognized escape sequence
        """

        for arguments in [
            [#"\C"#, temp.path("pcre.txt")],
            ["--engine=default", #"\C"#, temp.path("pcre.txt")],
            ["--no-pcre2", #"\C"#, temp.path("pcre.txt")],
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

    @Test func pcre2ByteUnitEscapeFastPathFieldsCountsAndPathModes() throws {
        let temp = try TemporaryDirectory()
        try temp.write(Data([0x63, 0x61, 0x66, 0xC3, 0xA9, 0x0A, 0x61, 0x62, 0x63, 0x0A]), to: "pcre.txt")
        try temp.write(Data([0xA9, 0x0A]), to: "continuation.txt")

        let fieldOutput = try runExecutableData([
            "-P",
            "-n",
            "--column",
            "--byte-offset",
            "-o",
            #"\C{2}"#,
            temp.path("pcre.txt"),
        ]) {}
        let countOutput = try runExecutableData(["-P", "-c", #"\C"#, temp.path("pcre.txt")]) {}
        let countMatchesOutput = try runExecutableData([
            "-P",
            "--count-matches",
            #"\C"#,
            temp.path("pcre.txt"),
        ]) {}
        let matchingPathOutput = try runExecutableData([
            "-P",
            "--files-with-matches",
            #"\C"#,
            temp.path("pcre.txt"),
        ]) {}
        let nonmatchingPathOutput = try runExecutableData([
            "-P",
            "--files-without-match",
            #"\C"#,
            temp.path("continuation.txt"),
        ]) {}

        var expectedFieldOutput = Data("1:1:0:ca\n1:3:2:f".utf8)
        expectedFieldOutput.append(0xC3)
        expectedFieldOutput.append(contentsOf: Data("\n2:1:6:ab\n".utf8))
        #expect(fieldOutput == expectedFieldOutput)
        #expect(countOutput == Data("2\n".utf8))
        #expect(countMatchesOutput == Data("7\n".utf8))
        #expect(matchingPathOutput == Data("\(temp.path("pcre.txt"))\n".utf8))
        #expect(nonmatchingPathOutput == Data("\(temp.path("continuation.txt"))\n".utf8))

        var quietOutput: [String] = []
        var quietErrors: [String] = []
        let quietMatchExit = RipgrepCLI.run(
            arguments: ["-P", "-q", #"\C"#, temp.path("pcre.txt")],
            stdout: { quietOutput.append($0) },
            stderr: { quietErrors.append($0) }
        )
        #expect(quietMatchExit == 0)
        #expect(quietOutput.isEmpty)
        #expect(quietErrors.isEmpty)

        let quietNoMatchExit = RipgrepCLI.run(
            arguments: ["-P", "-q", #"\C"#, temp.path("continuation.txt")],
            stdout: { quietOutput.append($0) },
            stderr: { quietErrors.append($0) }
        )
        #expect(quietNoMatchExit == 1)
        #expect(quietOutput.isEmpty)
        #expect(quietErrors.isEmpty)
    }

    @Test func pcre2EmbeddedByteUnitEscapesUseRawByteRegex() throws {
        let temp = try TemporaryDirectory()
        try temp.write(Data([
            0x61, 0x62, 0x63, 0x0A,
            0x63, 0x61, 0x66, 0xC3, 0xA9, 0x0A,
            0x61, 0x31, 0x62, 0x0A,
            0x66, 0x6F, 0x6F, 0x31, 0x32, 0x33, 0x62, 0x61, 0x72, 0x0A,
        ]), to: "pcre.txt")

        let surrounded = try runExecutableData(["-P", "-n", "-o", #"a\Cb"#, temp.path("pcre.txt")]) {}
        let greedy = try runExecutableData(["-P", "-n", "-o", #"a\C+"#, temp.path("pcre.txt")]) {}
        let fixedCount = try runExecutableData(["-P", "-n", "-o", #"foo\C{3}bar"#, temp.path("pcre.txt")]) {}
        let dotByte = try runExecutableData(["-P", "-n", "-o", #".\C"#, temp.path("pcre.txt")]) {}
        let byteDigit = try runExecutableData(["-P", "-n", "-o", #"\C\d"#, temp.path("pcre.txt")]) {}
        let replacement = try run(["-P", #"a(\C)b"#, "-r", "[$1]", temp.path("pcre.txt")])

        #expect(surrounded == Data("3:a1b\n".utf8))
        #expect(greedy == Data([
            0x31, 0x3A, 0x61, 0x62, 0x63, 0x0A,
            0x32, 0x3A, 0x61, 0x66, 0xC3, 0xA9, 0x0A,
            0x33, 0x3A, 0x61, 0x31, 0x62, 0x0A,
            0x34, 0x3A, 0x61, 0x72, 0x0A,
        ]))
        #expect(fixedCount == Data("4:foo123bar\n".utf8))
        #expect(dotByte == Data([
            0x31, 0x3A, 0x61, 0x62, 0x0A,
            0x32, 0x3A, 0x63, 0x61, 0x0A,
            0x32, 0x3A, 0x66, 0xC3, 0x0A,
            0x33, 0x3A, 0x61, 0x31, 0x0A,
            0x34, 0x3A, 0x66, 0x6F, 0x0A,
            0x34, 0x3A, 0x6F, 0x31, 0x0A,
            0x34, 0x3A, 0x32, 0x33, 0x0A,
            0x34, 0x3A, 0x62, 0x61, 0x0A,
        ]))
        #expect(byteDigit == Data("3:a1\n4:o1\n4:23\n".utf8))
        #expect(replacement == ["[1]"])
    }

    @Test func pcre2AssertionConditionalsOnlyMatching() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foofoo\nbar\nfoobar\n", to: "pcre.txt")

        let positiveLookahead = try run(["-P", "-o", #"(?(?=foo)foo|bar)"#, temp.path("pcre.txt")])
        let falseLookahead = try run(["-P", "-o", #"(?(?=z)foo|bar)"#, temp.path("pcre.txt")])
        let negativeLookahead = try run(["-P", "-o", #"(?(?!foo)bar|foo)"#, temp.path("pcre.txt")])
        let positiveLookbehind = try run(["-P", "-o", #"(?(?<=foo)foo|bar)"#, temp.path("pcre.txt")])
        let negativeLookbehind = try run(["-P", "-o", #"(?(?<!foo)bar|foo)"#, temp.path("pcre.txt")])
        let autoOutput = try run(["--engine=auto", "-o", #"(?(?=foo)foo|bar)"#, temp.path("pcre.txt")])

        #expect(positiveLookahead == ["foo", "foo", "bar", "foo", "bar"])
        #expect(falseLookahead == ["bar", "bar"])
        #expect(negativeLookahead == positiveLookahead)
        #expect(positiveLookbehind == ["foo", "bar"])
        #expect(negativeLookbehind == ["foo", "bar"])
        #expect(autoOutput == positiveLookahead)
    }

    @Test func pcre2AssertionConditionalExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foofoo\nbar\nfoobar\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-o", #"(?(?=foo)foo|bar)"#, temp.path("pcre.txt")]) {}

        #expect(output == Data("foo\nfoo\nbar\nfoo\nbar\n".utf8))
    }

    @Test func pcre2AssertionConditionalsRespectDefaultEngineSelection() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foo\n", to: "pcre.txt")
        let expected = """
        rg: regex parse error:
            (?:(?(?=foo)foo|bar))
                 ^
        error: unrecognized flag
        """

        for arguments in [
            [#"(?(?=foo)foo|bar)"#, temp.path("pcre.txt")],
            ["--engine=default", #"(?(?=foo)foo|bar)"#, temp.path("pcre.txt")],
            ["--no-pcre2", #"(?(?=foo)foo|bar)"#, temp.path("pcre.txt")],
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

    @Test func pcre2ResetStartLiteralOnlyMatching() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foobar\nfooqux\nbar\n", to: "pcre.txt")

        let lineOutput = try run(["-P", #"foo\Kbar"#, temp.path("pcre.txt")])
        let onlyMatchingOutput = try run(["-P", "-o", #"foo\Kbar"#, temp.path("pcre.txt")])
        let autoOnlyMatchingOutput = try run(["--engine=auto", "-o", #"foo\Kbar"#, temp.path("pcre.txt")])

        #expect(lineOutput == ["foobar"])
        #expect(onlyMatchingOutput == ["bar"])
        #expect(autoOnlyMatchingOutput == ["bar"])
    }

    @Test func pcre2ResetStartReplacementUsesResetMatchRange() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foobar\nfooqux\nbar\n", to: "pcre.txt")

        let output = try run(["-P", #"foo\Kbar"#, "-r", "X", temp.path("pcre.txt")])

        #expect(output == ["fooX"])
    }

    @Test func pcre2ResetStartExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foobar\nfooqux\nbar\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-o", #"foo\Kbar"#, temp.path("pcre.txt")]) {}

        #expect(output == Data("bar\n".utf8))
    }

    @Test func pcre2ResetStartAllowsEmptyPrefixOrLiteral() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foo\nbarfoo\nfoofoo\n", to: "pcre.txt")

        let emptyPrefixOutput = try runExecutableData(["-P", "-o", #"\Kfoo"#, temp.path("pcre.txt")]) {}
        let emptyLiteralOutput = try runExecutableData(["-P", "-o", #"foo\K"#, temp.path("pcre.txt")]) {}
        let fieldOutput = try runExecutableData([
            "-P",
            "-n",
            "--column",
            "--byte-offset",
            "-o",
            #"foo\K"#,
            temp.path("pcre.txt"),
        ]) {}
        let countOutput = try runExecutableData(["-P", "-c", #"\Kfoo"#, temp.path("pcre.txt")]) {}
        let countMatchesOutput = try runExecutableData([
            "-P",
            "--count-matches",
            #"foo\K"#,
            temp.path("pcre.txt"),
        ]) {}

        #expect(emptyPrefixOutput == Data("foo\nfoo\nfoo\nfoo\n".utf8))
        #expect(emptyLiteralOutput == Data("\n\n\n".utf8))
        #expect(fieldOutput == Data("1:4:3:\n2:7:10:\n3:4:14:\n".utf8))
        #expect(countOutput == Data("3\n".utf8))
        #expect(countMatchesOutput == Data("3\n".utf8))
    }

    @Test func pcre2BareResetStartMatchesEveryLineBytePosition() throws {
        let temp = try TemporaryDirectory()
        try temp.write(Data("foo\n".utf8), to: "with-final-newline.txt")
        try temp.write(Data("foo".utf8), to: "without-final-newline.txt")
        try temp.write(Data("\n".utf8), to: "empty-line.txt")
        try temp.write(Data("café\n".utf8), to: "utf8.txt")
        try temp.write(Data([0xA9, UInt8(ascii: "a"), UInt8(ascii: "\n")]), to: "invalid-prefix.txt")

        let finalNewlineFields = try runExecutableData([
            "-P",
            "-n",
            "--column",
            "--byte-offset",
            "-o",
            #"\K"#,
            temp.path("with-final-newline.txt"),
        ]) {}
        let noFinalNewlineFields = try runExecutableData([
            "-P",
            "-n",
            "--column",
            "--byte-offset",
            "-o",
            #"\K"#,
            temp.path("without-final-newline.txt"),
        ]) {}
        let emptyLineFields = try runExecutableData([
            "-P",
            "-n",
            "--column",
            "--byte-offset",
            "-o",
            #"\K"#,
            temp.path("empty-line.txt"),
        ]) {}
        let plainOnlyMatching = try runExecutableData([
            "-P",
            "-o",
            #"\K"#,
            temp.path("without-final-newline.txt"),
        ]) {}
        let wholeLineFinalNewline = try runExecutableData([
            "-P",
            #"\K"#,
            temp.path("with-final-newline.txt"),
        ]) {}
        let wholeLineNoFinalNewline = try runExecutableData([
            "-P",
            #"\K"#,
            temp.path("without-final-newline.txt"),
        ]) {}
        let utf8CountMatches = try runExecutableData([
            "-P",
            "--count-matches",
            #"\K"#,
            temp.path("utf8.txt"),
        ]) {}
        let invalidNoUnicodeCountMatches = try runExecutableData([
            "-P",
            "--no-pcre2-unicode",
            "--count-matches",
            #"\K"#,
            temp.path("invalid-prefix.txt"),
        ]) {}
        let decodedFallbackOutput = try run(["-P", "-o", #"\K"#, temp.path("with-final-newline.txt")])

        #expect(finalNewlineFields == Data("1:1:0:\n1:2:1:\n1:3:2:\n1:4:3:\n".utf8))
        #expect(noFinalNewlineFields == Data("1:1:0:\n1:2:1:\n1:3:2:\n".utf8))
        #expect(emptyLineFields == Data("1:1:0:\n".utf8))
        #expect(plainOnlyMatching == Data(repeating: UInt8(ascii: "\n"), count: 3))
        #expect(wholeLineFinalNewline == Data("foo\n".utf8))
        #expect(wholeLineNoFinalNewline == Data("foo\n".utf8))
        #expect(utf8CountMatches == Data("6\n".utf8))
        #expect(invalidNoUnicodeCountMatches == Data("3\n".utf8))
        #expect(decodedFallbackOutput == ["", "", "", ""])
    }

    @Test func pcre2ResetStartSupportsLiteralPrefixRegexSuffix() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foobar foo123 foobaz\nfoocafé\n", to: "pcre.txt")

        let wordOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"foo\K\w+"#,
            temp.path("pcre.txt"),
        ]) {}
        let noUnicodeWordOutput = try runExecutableData([
            "-P",
            "--no-pcre2-unicode",
            "-n",
            "-o",
            #"foo\K\w+"#,
            temp.path("pcre.txt"),
        ]) {}
        let digitOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"foo\K[0-9]+"#,
            temp.path("pcre.txt"),
        ]) {}
        let alternationOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"foo\K(?:bar|baz)"#,
            temp.path("pcre.txt"),
        ]) {}
        let emptyLookaheadOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"foo\K(?=bar)"#,
            temp.path("pcre.txt"),
        ]) {}

        #expect(wordOutput == Data("1:bar\n1:123\n1:baz\n2:café\n".utf8))
        #expect(noUnicodeWordOutput == Data("1:bar\n1:123\n1:baz\n2:caf\n".utf8))
        #expect(digitOutput == Data("1:123\n".utf8))
        #expect(alternationOutput == Data("1:bar\n1:baz\n".utf8))
        #expect(emptyLookaheadOutput == Data("1:\n".utf8))
    }

    @Test func pcre2ResetStartSupportsRegexPrefix() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foobar foo123 barfoo foobaz\nabc123 abc abc456\nfoo123\n", to: "pcre.txt")

        let alternationDigitOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"(foo|abc)\K[0-9]+"#,
            temp.path("pcre.txt"),
        ]) {}
        let alternationWordOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"(foo|abc)\K\w+"#,
            temp.path("pcre.txt"),
        ]) {}
        let greedyPrefixOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"\w+\K[0-9]+"#,
            temp.path("pcre.txt"),
        ]) {}
        let dotStarOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"foo.*\Kbar"#,
            temp.path("pcre.txt"),
        ]) {}
        let emptyLookaheadOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"foo(?=bar)\K"#,
            temp.path("pcre.txt"),
        ]) {}
        let lookbehindOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"(?<=foo)\Kbar"#,
            temp.path("pcre.txt"),
        ]) {}
        let replacementOutput = try run([
            "-P",
            #"(foo|abc)\K([0-9]+)"#,
            "-r",
            "[$1:$2]",
            temp.path("pcre.txt"),
        ])

        #expect(alternationDigitOutput == Data("1:123\n2:123\n2:456\n3:123\n".utf8))
        #expect(alternationWordOutput == Data("1:bar\n1:123\n1:baz\n2:123\n2:456\n3:123\n".utf8))
        #expect(greedyPrefixOutput == Data("1:3\n2:3\n2:6\n3:3\n".utf8))
        #expect(dotStarOutput == Data("1:bar\n".utf8))
        #expect(emptyLookaheadOutput == Data("1:\n".utf8))
        #expect(lookbehindOutput == Data("1:bar\n".utf8))
        #expect(replacementOutput == [
            "foobar foo[foo:123] barfoo foobaz",
            "abc[abc:123] abc abc[abc:456]",
            "foo[foo:123]",
        ])
    }

    @Test func pcre2ResetStartSupportsBackreferences() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foofoo foofoobar barfoo abcabc abc123\n", to: "pcre.txt")

        let numericOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"(foo)\K\1"#,
            temp.path("pcre.txt"),
        ]) {}
        let gOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"(foo)\K\g1"#,
            temp.path("pcre.txt"),
        ]) {}
        let bracedGOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"(foo)\K\g{1}"#,
            temp.path("pcre.txt"),
        ]) {}
        let namedOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"(?P<w>foo)\K(?P=w)"#,
            temp.path("pcre.txt"),
        ]) {}
        let alternationOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"(foo|abc)\K\1"#,
            temp.path("pcre.txt"),
        ]) {}
        let replacementOutput = try run([
            "-P",
            #"(foo)\K\1"#,
            "-r",
            "[$1]",
            temp.path("pcre.txt"),
        ])

        #expect(numericOutput == Data("1:foo\n1:foo\n".utf8))
        #expect(gOutput == numericOutput)
        #expect(bracedGOutput == numericOutput)
        #expect(namedOutput == numericOutput)
        #expect(alternationOutput == Data("1:foo\n1:foo\n1:abc\n".utf8))
        #expect(replacementOutput == ["foo[foo] foo[foo]bar barfoo abcabc abc123"])
    }

    @Test func pcre2SkipFailAlternationSkipsIgnoredRegions() throws {
        let temp = try TemporaryDirectory()
        try temp.write("""
        alpha beta gamma
        one [two] three 123
        foo bar baz
        qux foo bar
        """, to: "pcre.txt")

        let literalSkipOutput = try runExecutableData([
            "-P",
            "-n",
            "-o",
            #"alpha(*SKIP)(*F)|beta"#,
            temp.path("pcre.txt"),
        ]) {}
        let regexSkipOutput = try run([
            "--engine=auto",
            "-n",
            "-o",
            #"\[[^\]]+\](*SKIP)(*FAIL)|\w+"#,
            temp.path("pcre.txt"),
        ])
        let replacementOutput = try run([
            "-P",
            #"(foo)(*SKIP)(*F)|(bar)"#,
            "-r",
            #"[$1]/[$2]"#,
            temp.path("pcre.txt"),
        ])

        #expect(literalSkipOutput == Data("1:beta\n".utf8))
        #expect(regexSkipOutput == [
            "1:alpha",
            "1:beta",
            "1:gamma",
            "2:one",
            "2:three",
            "2:123",
            "3:foo",
            "3:bar",
            "3:baz",
            "4:qux",
            "4:foo",
            "4:bar",
        ])
        #expect(replacementOutput == [
            "foo []/[bar] baz",
            "qux foo []/[bar]",
        ])
    }

    @Test func pcre2ResetStartRespectsDefaultEngineSelection() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foobar\n", to: "pcre.txt")
        let expected = """
        rg: regex parse error:
            (?:foo\\Kbar)
                  ^^
        error: unrecognized escape sequence
        """

        for arguments in [
            [#"foo\Kbar"#, temp.path("pcre.txt")],
            ["--engine=default", #"foo\Kbar"#, temp.path("pcre.txt")],
            ["--no-pcre2", #"foo\Kbar"#, temp.path("pcre.txt")],
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

    @Test func pcre2EscapedLookbehindExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock.Holmes\nSherlockxHolmes\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-o", #"(?<=Sherlock\.)Holmes"#, temp.path("pcre.txt")]) {}

        #expect(output == Data("Holmes\n".utf8))
    }

    @Test func pcre2FixedLookbehindLiteralOnlyMatchesAfterPrefix() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock Holmes\nMycroft Holmes\nSherlock Holmes\n", to: "pcre.txt")

        let output = try run(["-P", "-o", "(?<=Sherlock )Holmes", temp.path("pcre.txt")])

        #expect(output == ["Holmes", "Holmes"])
    }

    @Test func pcre2FixedLookbehindExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Mycroft Holmes\nSherlock Holmes and Sherlock Holmes\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-o", "(?<=Sherlock )Holmes", temp.path("pcre.txt")]) {}

        #expect(output == Data("Holmes\nHolmes\n".utf8))
    }

    @Test func pcre2NoUnicodeIgnoreCaseFixedLookbehindExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("sherlock holmes\nSHERLOCK HOLMES\nSherlock Holmes\nMycroft Holmes\n", to: "pcre.txt")

        let output = try runExecutableData([
            "-P",
            "--no-pcre2-unicode",
            "-i",
            "-n",
            "-o",
            "(?<=sherlock )holmes",
            temp.path("pcre.txt"),
        ]) {}

        #expect(output == Data("1:holmes\n2:HOLMES\n3:Holmes\n".utf8))
    }

    @Test func pcre2NoUnicodeShorthandClassesUseASCII() throws {
        let temp = try TemporaryDirectory()
        try temp.write("café\nabc_123\n٣ 3\n", to: "pcre.txt")

        let asciiWords = try run(["-P", "--no-pcre2-unicode", "-o", #"\w+"#, temp.path("pcre.txt")])
        let unicodeWords = try run(["-P", "--pcre2-unicode", "-o", #"\w+"#, temp.path("pcre.txt")])
        let asciiDigits = try run(["-P", "--no-pcre2-unicode", "-o", #"\d+"#, temp.path("pcre.txt")])
        let unicodeDigits = try run(["-P", "--pcre2-unicode", "-o", #"\d+"#, temp.path("pcre.txt")])

        #expect(asciiWords == ["caf", "abc_123", "3"])
        #expect(unicodeWords == ["café", "abc_123", "٣", "3"])
        #expect(asciiDigits == ["123", "3"])
        #expect(unicodeDigits == ["123", "٣", "3"])
    }

    @Test func pcre2FixedLookbehindExecutableFastPathLineNumberOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Mycroft Holmes\nSherlock Holmes and Sherlock Holmes\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-n", "-o", "(?<=Sherlock )Holmes", temp.path("pcre.txt")]) {}

        #expect(output == Data("2:Holmes\n2:Holmes\n".utf8))
    }

    @Test func pcre2FixedLookbehindExecutableFastPathOnlyMatchingFields() throws {
        let temp = try TemporaryDirectory()
        try temp.write("abc Sherlock Holmes xyz\n", to: "pcre.txt")

        let byteOffsetOutput = try runExecutableData([
            "-P",
            "-b",
            "-o",
            "(?<=Sherlock )Holmes",
            temp.path("pcre.txt"),
        ]) {}
        let columnOutput = try runExecutableData([
            "-P",
            "--column",
            "-o",
            "(?<=Sherlock )Holmes",
            temp.path("pcre.txt"),
        ]) {}
        let combinedOutput = try runExecutableData([
            "-P",
            "-n",
            "-b",
            "--column",
            "-o",
            "(?<=Sherlock )Holmes",
            temp.path("pcre.txt"),
        ]) {}
        let columnWithoutLineOutput = try runExecutableData([
            "-P",
            "--no-line-number",
            "--column",
            "-o",
            "(?<=Sherlock )Holmes",
            temp.path("pcre.txt"),
        ]) {}

        #expect(byteOffsetOutput == Data("13:Holmes\n".utf8))
        #expect(columnOutput == Data("1:14:Holmes\n".utf8))
        #expect(combinedOutput == Data("1:14:13:Holmes\n".utf8))
        #expect(columnWithoutLineOutput == Data("14:Holmes\n".utf8))
    }

    @Test func pcre2FixedLookbehindExecutableFastPathCountOutputs() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Mycroft Holmes\nSherlock Holmes and Sherlock Holmes\n", to: "pcre.txt")

        let countOutput = try runExecutableData(["-P", "-c", "(?<=Sherlock )Holmes", temp.path("pcre.txt")]) {}
        let countMatchesOutput = try runExecutableData([
            "-P",
            "--count-matches",
            "(?<=Sherlock )Holmes",
            temp.path("pcre.txt"),
        ]) {}

        #expect(countOutput == Data("1\n".utf8))
        #expect(countMatchesOutput == Data("2\n".utf8))
    }

    @Test func pcre2FixedLookbehindExecutableFastPathPathOutputs() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Mycroft Holmes\nSherlock Holmes\n", to: "pcre.txt")

        let matchingOutput = try runExecutableData([
            "-P",
            "--files-with-matches",
            "(?<=Sherlock )Holmes",
            temp.path("pcre.txt"),
        ]) {}
        let nonmatchingOutput = try runExecutableData([
            "-P",
            "--files-without-match",
            "(?<=Nobody )Holmes",
            temp.path("pcre.txt"),
        ]) {}

        #expect(matchingOutput == Data("\(temp.path("pcre.txt"))\n".utf8))
        #expect(nonmatchingOutput == Data("\(temp.path("pcre.txt"))\n".utf8))
    }

    @Test func pcre2FixedNegativeLookbehindLiteralOnlyMatchesWithoutPrefix() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock Holmes\nMycroft Holmes\nHolmes\n", to: "pcre.txt")

        let output = try run(["-P", "-o", "(?<!Sherlock )Holmes", temp.path("pcre.txt")])

        #expect(output == ["Holmes", "Holmes"])
    }

    @Test func pcre2FixedNegativeLookbehindExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock Holmes\nMycroft Holmes\nHolmes\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-o", "(?<!Sherlock )Holmes", temp.path("pcre.txt")]) {}

        #expect(output == Data("Holmes\nHolmes\n".utf8))
    }

    @Test func pcre2FixedLookaheadLiteralOnlyMatchesBeforeSuffix() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock Holmes\nSherlock Watson\nSherlock Holmes\n", to: "pcre.txt")

        let output = try run(["-P", "-o", "Sherlock(?= Holmes)", temp.path("pcre.txt")])

        #expect(output == ["Sherlock", "Sherlock"])
    }

    @Test func pcre2FixedLookaheadExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock Watson\nSherlock Holmes and Sherlock Holmes\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-o", "Sherlock(?= Holmes)", temp.path("pcre.txt")]) {}

        #expect(output == Data("Sherlock\nSherlock\n".utf8))
    }

    @Test func pcre2FixedNegativeLookaheadLiteralOnlyMatchesWithoutSuffix() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock Holmes\nSherlock Watson\nSherlock\n", to: "pcre.txt")

        let output = try run(["-P", "-o", "Sherlock(?! Holmes)", temp.path("pcre.txt")])

        #expect(output == ["Sherlock", "Sherlock"])
    }

    @Test func pcre2FixedNegativeLookaheadExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock Holmes\nSherlock Watson\nSherlock\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-o", "Sherlock(?! Holmes)", temp.path("pcre.txt")]) {}

        #expect(output == Data("Sherlock\nSherlock\n".utf8))
    }

    @Test func pcre2FixedNegativeLookaheadExecutableFastPathLineNumberOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Sherlock Holmes\nSherlock Watson\nSherlock\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-n", "-o", "Sherlock(?! Holmes)", temp.path("pcre.txt")]) {}

        #expect(output == Data("2:Sherlock\n3:Sherlock\n".utf8))
    }

    @Test func pcre2BackreferenceOnlyMatching() throws {
        let temp = try TemporaryDirectory()
        try temp.write("abba\nabca\n", to: "pcre.txt")

        let output = try run(["-P", "-o", #"(a)(b)\2"#, temp.path("pcre.txt")])

        #expect(output == ["abb"])
    }

    @Test func pcre2GBackreferenceSyntaxOnlyMatching() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foofoo\nfoobar\nfoo\n", to: "pcre.txt")

        let numericOutput = try run(["-P", "-o", #"(foo)\g1"#, temp.path("pcre.txt")])
        let bracedNumericOutput = try run(["-P", "-o", #"(foo)\g{1}"#, temp.path("pcre.txt")])
        let autoOutput = try run(["--engine=auto", "-o", #"(foo)\g1"#, temp.path("pcre.txt")])

        #expect(numericOutput == ["foofoo"])
        #expect(bracedNumericOutput == ["foofoo"])
        #expect(autoOutput == ["foofoo"])
    }

    @Test func pcre2PythonNamedBackreferenceSyntaxOnlyMatching() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foofoo\nfoobar\nfoo\n", to: "pcre.txt")

        let pythonOutput = try run(["-P", "-o", #"(?P<w>foo)(?P=w)"#, temp.path("pcre.txt")])
        let pythonCaptureOutput = try run(["-P", "-o", #"(?P<w>foo)\k<w>"#, temp.path("pcre.txt")])
        let bracedNamedOutput = try run(["-P", "-o", #"(?<w>foo)\g{w}"#, temp.path("pcre.txt")])
        let angledNamedOutput = try run(["-P", "-o", #"(?<w>foo)\g<w>"#, temp.path("pcre.txt")])
        let autoOutput = try run(["--engine=auto", "-o", #"(?P<w>foo)(?P=w)"#, temp.path("pcre.txt")])

        #expect(pythonOutput == ["foofoo"])
        #expect(pythonCaptureOutput == ["foofoo"])
        #expect(bracedNamedOutput == ["foofoo"])
        #expect(angledNamedOutput == ["foofoo"])
        #expect(autoOutput == ["foofoo"])
    }

    @Test func pcre2TranslatedBackreferenceExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foofoo\nfoobar\nfoofoo\n", to: "pcre.txt")

        let numericOutput = try runExecutableData(["-P", "-o", #"(foo)\g1"#, temp.path("pcre.txt")]) {}
        let namedOutput = try runExecutableData(["-P", "-o", #"(?P<w>foo)(?P=w)"#, temp.path("pcre.txt")]) {}

        #expect(numericOutput == Data("foofoo\nfoofoo\n".utf8))
        #expect(namedOutput == Data("foofoo\nfoofoo\n".utf8))
    }

    @Test func pcre2TranslatedBackreferenceSyntaxPreservesCapturesForReplacement() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foofoo\nfoobar\n", to: "pcre.txt")

        let numericOutput = try run(["-P", #"(foo)\g1"#, "-r", "$1", temp.path("pcre.txt")])
        let namedOutput = try run(["-P", #"(?P<w>foo)(?P=w)"#, "-r", "$1", temp.path("pcre.txt")])

        #expect(numericOutput == ["foo"])
        #expect(namedOutput == ["foo"])
    }

    @Test func pcre2BranchResetAlternationPreservesCaptureNumbering() throws {
        let temp = try TemporaryDirectory()
        try temp.write("ab\ncd\nac\n", to: "pcre.txt")

        let onlyMatching = try run(["-P", "-n", "-o", #"(?|a(b)|c(d))"#, temp.path("pcre.txt")])
        let autoOnlyMatching = try run(["--engine=auto", "-n", "-o", #"(?|a(b)|c(d))"#, temp.path("pcre.txt")])
        let replacement = try run(["-P", #"(?|a(b)|c(d))"#, "-r", "[$1]", temp.path("pcre.txt")])

        #expect(onlyMatching == ["1:ab", "2:cd"])
        #expect(autoOnlyMatching == onlyMatching)
        #expect(replacement == ["[b]", "[d]"])
    }

    @Test func pcre2NumericKBackreferencesUsePCREDiagnostic() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foofoo\n", to: "pcre.txt")
        let expected = "rg: PCRE2: error compiling pattern at offset 16: subpattern name must start with a non-digit"

        for pattern in [#"(?<w>foo)\k'1'"#, #"(?<w>foo)\k<1>"#, #"(?<w>foo)\k{1}"#] {
            var output: [String] = []
            var errors: [String] = []
            let exitCode = RipgrepCLI.run(
                arguments: ["-P", pattern, temp.path("pcre.txt")],
                stdout: { output.append($0) },
                stderr: { errors.append($0) }
            )

            #expect(exitCode == 2)
            #expect(output.isEmpty)
            #expect(errors == [expected])
        }
    }

    @Test func pcre2BackreferenceSyntaxRespectsDefaultEngineSelection() throws {
        let temp = try TemporaryDirectory()
        try temp.write("foofoo\n", to: "pcre.txt")
        let expectedGError = """
        rg: regex parse error:
            (?:(foo)\\g1)
                    ^^
        error: unrecognized escape sequence
        """
        let expectedKError = """
        rg: regex parse error:
            (?:(?<w>foo)\\k<w>)
                        ^^
        error: unrecognized escape sequence
        """
        let expectedPythonBackreferenceError = """
        rg: regex parse error:
            (?:(?P<w>foo)(?P=w))
                           ^
        error: unrecognized flag
        """

        let cases = [
            (#"(foo)\g1"#, expectedGError),
            (#"(?<w>foo)\k<w>"#, expectedKError),
            (#"(?P<w>foo)(?P=w)"#, expectedPythonBackreferenceError),
        ]
        for (pattern, expected) in cases {
            for arguments in [
                [pattern, temp.path("pcre.txt")],
                ["--engine=default", pattern, temp.path("pcre.txt")],
                ["--no-pcre2", pattern, temp.path("pcre.txt")],
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
    }

    @Test func pcre2LiteralBackreferenceExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("abba\nabca\nabba\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-o", #"(a)(b)\2"#, temp.path("pcre.txt")]) {}

        #expect(output == Data("abb\nabb\n".utf8))
    }

    @Test func pcre2NoUnicodeIgnoreCaseLiteralBackreferenceExecutableFastPathOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("abba\naBBa\nabca\n", to: "pcre.txt")

        let output = try runExecutableData([
            "-P",
            "--no-pcre2-unicode",
            "-i",
            "-o",
            #"(a)(b)\2"#,
            temp.path("pcre.txt"),
        ]) {}

        #expect(output == Data("abb\naBB\n".utf8))
    }

    @Test func pcre2LiteralBackreferenceExecutableFastPathLineNumberOnlyMatchingOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("abba\nabca\nabba\n", to: "pcre.txt")

        let output = try runExecutableData(["-P", "-n", "-o", #"(a)(b)\2"#, temp.path("pcre.txt")]) {}

        #expect(output == Data("1:abb\n3:abb\n".utf8))
    }

    @Test func pcre2QuietSuppressesFixedFastPathOutput() throws {
        let temp = try TemporaryDirectory()
        try temp.write("Mycroft Holmes\nSherlock Holmes\n", to: "pcre.txt")
        var output: [String] = []
        var errors: [String] = []

        let exitCode = RipgrepCLI.run(
            arguments: ["-q", "-P", "-c", "(?<=Sherlock )Holmes", temp.path("pcre.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(output.isEmpty)
        #expect(errors.isEmpty)
    }

    @Test func pcre2LiteralBackreferenceCapturesReplacement() throws {
        let temp = try TemporaryDirectory()
        try temp.write("abba\nabca\n", to: "pcre.txt")

        let output = try run(["-P", "-r", "$2/$1", #"(a)(b)\2"#, temp.path("pcre.txt")])

        #expect(output == ["b/aa"])
    }

    @Test func automaticEngineFallsBackToPCRE2() throws {
        let temp = try TemporaryDirectory()
        try temp.write("ab\nac\n", to: "pcre.txt")

        let output = try run(["--engine=auto", "-o", "(?<=a)b", temp.path("pcre.txt")])

        #expect(output == ["b"])
    }

    @Test func regexSizeLimitUsesRustDiagnostic() throws {
        let temp = try TemporaryDirectory()
        try temp.write("abc\n", to: "r.txt")
        var output: [String] = []
        var errors: [String] = []

        let exitCode = RipgrepCLI.run(
            arguments: ["--regex-size-limit=0", "[a-z]", temp.path("r.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(output.isEmpty)
        #expect(exitCode == 2)
        #expect(errors == ["rg: compiled regex exceeds size limit of 0"])
    }

    @Test func pcre2VersionReportsSwiftCompatibilityEngine() {
        var output: [String] = []
        var errors: [String] = []

        let exitCode = RipgrepCLI.run(
            arguments: ["--pcre2-version"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(errors.isEmpty)
        #expect(exitCode == 0)
        #expect(output == ["PCRE2-compatible Swift regex engine is available (libpcre2 is not linked; JIT is unavailable)"])
    }
}
