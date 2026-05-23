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

    @Test("supports case insensitive search")
    func supportsCaseInsensitiveSearch() throws {
        let root = try TemporaryDirectory()
        try root.write("Needle\n", to: "case.txt")

        let matches = try RipgrepSearcher().search(
            pattern: "needle",
            roots: [root.url],
            ignoreCase: true
        )

        #expect(matches.count == 1)
        #expect(matches.first?.line == "Needle")
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
}
