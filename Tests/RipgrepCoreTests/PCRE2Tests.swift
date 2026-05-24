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

    @Test func pcre2BackreferenceOnlyMatching() throws {
        let temp = try TemporaryDirectory()
        try temp.write("abba\nabca\n", to: "pcre.txt")

        let output = try run(["-P", "-o", #"(a)(b)\2"#, temp.path("pcre.txt")])

        #expect(output == ["abb"])
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

    @Test func pcre2VersionReportsLinkedLibrary() {
        var output: [String] = []
        var errors: [String] = []

        let exitCode = RipgrepCLI.run(
            arguments: ["--pcre2-version"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(errors.isEmpty)
        #expect(exitCode == 0)
        #expect(output.count == 1)
        #expect(output.first?.hasPrefix("PCRE2 10.") == true)
        #expect(output.first?.contains("JIT is") == true)
    }
}
