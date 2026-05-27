import Foundation
import Testing

/// Verifies that the bundled help/man/completion assets under
/// `Sources/RipgrepCore/Resources/Generated/` stay in sync with what the
/// `ripgrep` binary actually generates via `--help`, `-h`, and `--generate`.
///
/// When this suite fails, run `scripts/refresh-generated-assets.sh` from the
/// repository root to refresh the stored copies.
@Suite("Generated assets drift")
struct GeneratedAssetDriftTests {
    @Test("short help matches binary output")
    func shortHelpMatchesBinary() throws {
        try expectStoredAssetMatchesBinary(
            storedRelative: "Sources/RipgrepCore/Resources/Generated/rg.help.short",
            arguments: ["-h"]
        )
    }

    @Test("long help matches binary output")
    func longHelpMatchesBinary() throws {
        try expectStoredAssetMatchesBinary(
            storedRelative: "Sources/RipgrepCore/Resources/Generated/rg.help.long",
            arguments: ["--help"]
        )
    }

    @Test("man page matches binary generate output")
    func manPageMatchesBinary() throws {
        try expectStoredAssetMatchesBinary(
            storedRelative: "Sources/RipgrepCore/Resources/Generated/rg.1",
            arguments: ["--generate", "man"]
        )
    }

    @Test("bash completion matches binary generate output")
    func bashCompletionMatchesBinary() throws {
        try expectStoredAssetMatchesBinary(
            storedRelative: "Sources/RipgrepCore/Resources/Generated/rg.bash",
            arguments: ["--generate", "complete-bash"]
        )
    }

    @Test("zsh completion matches binary generate output")
    func zshCompletionMatchesBinary() throws {
        try expectStoredAssetMatchesBinary(
            storedRelative: "Sources/RipgrepCore/Resources/Generated/_rg",
            arguments: ["--generate", "complete-zsh"]
        )
    }

    @Test("fish completion matches binary generate output")
    func fishCompletionMatchesBinary() throws {
        try expectStoredAssetMatchesBinary(
            storedRelative: "Sources/RipgrepCore/Resources/Generated/rg.fish",
            arguments: ["--generate", "complete-fish"]
        )
    }

    @Test("powershell completion matches binary generate output")
    func powershellCompletionMatchesBinary() throws {
        try expectStoredAssetMatchesBinary(
            storedRelative: "Sources/RipgrepCore/Resources/Generated/_rg.ps1",
            arguments: ["--generate", "complete-powershell"]
        )
    }
}

private func expectStoredAssetMatchesBinary(
    storedRelative: String,
    arguments: [String]
) throws {
    let packageRoot = packageRootURL()
    let stored = packageRoot.appendingPathComponent(storedRelative)
    let binary = try ensureBuiltBinary(packageRoot: packageRoot)

    let storedData = try Data(contentsOf: stored)
    let generatedData = try runBinary(executable: binary, arguments: arguments)

    if storedData != generatedData {
        let storedText = String(data: storedData, encoding: .utf8) ?? "<binary>"
        let generatedText = String(data: generatedData, encoding: .utf8) ?? "<binary>"
        let diffSnippet = firstDifference(storedText, generatedText)
        Issue.record("""
        Drift between stored asset and binary --generate/--help output.

        Asset:     \(storedRelative)
        Arguments: \(arguments.joined(separator: " "))
        Stored:    \(storedData.count) bytes
        Generated: \(generatedData.count) bytes

        First difference:
        \(diffSnippet)

        Run scripts/refresh-generated-assets.sh from the repo root to refresh.
        """)
    }
}

private func packageRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func ensureBuiltBinary(packageRoot: URL) throws -> URL {
    let binary = packageRoot.appendingPathComponent(".build/debug/ripgrep")
    if FileManager.default.isExecutableFile(atPath: binary.path) {
        return binary
    }
    _ = try runBinary(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["swift", "build"],
        currentDirectory: packageRoot
    )
    return binary
}

private func runBinary(executable: URL, arguments: [String], currentDirectory: URL? = nil) throws -> Data {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    _ = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return output
}

private func firstDifference(_ lhs: String, _ rhs: String) -> String {
    let lhsLines = lhs.split(separator: "\n", omittingEmptySubsequences: false)
    let rhsLines = rhs.split(separator: "\n", omittingEmptySubsequences: false)
    let count = min(lhsLines.count, rhsLines.count)
    for i in 0..<count where lhsLines[i] != rhsLines[i] {
        return """
        line \(i + 1):
          stored:    \(lhsLines[i].debugDescription)
          generated: \(rhsLines[i].debugDescription)
        """
    }
    if lhsLines.count != rhsLines.count {
        return "line count differs: stored=\(lhsLines.count), generated=\(rhsLines.count)"
    }
    return "(content identical but byte representations differ — trailing newline?)"
}
