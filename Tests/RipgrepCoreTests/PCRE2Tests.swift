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
