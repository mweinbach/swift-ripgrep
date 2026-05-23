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
        #expect(try run(["-w", "abc", root.path("patterns.txt")]) == ["abc.123", "abc", "abc def"])
        #expect(try run(["-x", "abc", root.path("patterns.txt")]) == ["abc"])
    }

    @Test("supports smart case and inverted matches")
    func supportsSmartCaseAndInvertedMatches() throws {
        let root = try TemporaryDirectory()
        try root.write("Needle\nneedle\nhay\n", to: "case.txt")

        #expect(try run(["-S", "needle", root.path("case.txt")]) == ["Needle", "needle"])
        #expect(try run(["-S", "Needle", root.path("case.txt")]) == ["Needle"])
        #expect(try run(["-v", "needle", root.path("case.txt")]) == ["Needle", "hay"])
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
        #expect(try run(["-H", "-c", "needle", root.path("one.txt")]) == [
            "\(root.path("one.txt")):2",
        ])
        #expect(try run(["-l", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["one.txt"])
        #expect(try run(["--files-without-match", "needle", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["two.txt"])
    }

    @Test("lists files and honors hidden flag")
    func listsFilesAndHonorsHiddenFlag() throws {
        let root = try TemporaryDirectory()
        try root.write("visible\n", to: "visible.txt")
        try root.write("secret\n", to: ".hidden.txt")

        #expect(try run(["--files", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["visible.txt"])
        #expect(try run(["--files", "--hidden", root.url.path]).map { URL(fileURLWithPath: $0).lastPathComponent } == [".hidden.txt", "visible.txt"])
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

    private func run(_ arguments: [String]) throws -> [String] {
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
        let fileURL = url.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func path(_ relativePath: String) -> String {
        url.appendingPathComponent(relativePath, isDirectory: false).path
    }
}
