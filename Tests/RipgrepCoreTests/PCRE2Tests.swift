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
