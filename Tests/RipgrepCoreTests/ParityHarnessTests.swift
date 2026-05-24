import Foundation
import XCTest

final class ParityHarnessTests: XCTestCase {
    func testMatchesInstalledRipgrepOnSelectedFixtures() throws {
        guard ProcessInfo.processInfo.environment["SWIFT_RIPGREP_PARITY"] == "1" else {
            throw XCTSkip("Set SWIFT_RIPGREP_PARITY=1 to run the installed rg parity harness.")
        }

        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let rustRipgrep = try findInstalledRipgrep(packageRoot: packageRoot)
        let swiftRipgrep = try ensureSwiftRipgrepBinary(packageRoot: packageRoot)
        let fixtureRoot = "Tests/Fixtures/parity"

        let cases: [ParityCase] = [
            ParityCase(
                name: "recursive sorted text search honors ignore files",
                arguments: ["--sort", "path", "needle", fixtureRoot]
            ),
            ParityCase(
                name: "ignored file produces no match",
                arguments: ["ignored-only", fixtureRoot]
            ),
            ParityCase(
                name: "line numbers in multiline fixture",
                arguments: ["-n", "line", "\(fixtureRoot)/multiline.txt"]
            ),
            ParityCase(
                name: "binary searched as text",
                arguments: ["-a", "binary", "\(fixtureRoot)/binary.bin"]
            ),
            ParityCase(
                name: "explicit UTF-16LE decoding",
                arguments: ["--encoding", "utf-16le", "hello", "\(fixtureRoot)/utf16le.txt"]
            ),
            ParityCase(
                name: "multiline search across line terminators",
                arguments: ["-U", "--multiline", "two\\nline", "\(fixtureRoot)/multiline.txt"]
            ),
            ParityCase(
                name: "threaded sorted text search",
                arguments: ["--threads", "4", "--sort", "path", "needle", fixtureRoot]
            ),
            ParityCase(
                name: "single-thread sorted text search",
                arguments: ["--threads", "1", "--sort", "path", "needle", fixtureRoot]
            ),
        ]

        for parityCase in cases {
            let swiftResult = try runProcess(
                executable: swiftRipgrep,
                arguments: parityCase.arguments,
                currentDirectory: packageRoot
            )
            let rustResult = try runProcess(
                executable: rustRipgrep,
                arguments: parityCase.arguments,
                currentDirectory: packageRoot
            )

            XCTAssertEqual(
                swiftResult.exitCode,
                rustResult.exitCode,
                "exit status mismatch for \(parityCase.name)"
            )
            expectEqualData(
                swiftResult.stdout,
                rustResult.stdout,
                stream: "stdout",
                caseName: parityCase.name
            )
            expectEqualData(
                swiftResult.stderr,
                rustResult.stderr,
                stream: "stderr",
                caseName: parityCase.name
            )
        }
    }
}

private struct ParityCase {
    var name: String
    var arguments: [String]
}

private struct ProcessResult {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
}

private func findInstalledRipgrep(packageRoot: URL) throws -> URL {
    let whichResult = try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["which", "rg"],
        currentDirectory: packageRoot
    )
    guard whichResult.exitCode == 0,
          let path = String(data: whichResult.stdout, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .first
    else {
        throw XCTSkip("Could not find installed rg with `which rg`.")
    }
    return URL(fileURLWithPath: String(path))
}

private func ensureSwiftRipgrepBinary(packageRoot: URL) throws -> URL {
    let binary = packageRoot.appendingPathComponent(".build/debug/ripgrep")
    if FileManager.default.isExecutableFile(atPath: binary.path) {
        return binary
    }

    let buildResult = try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["swift", "build"],
        currentDirectory: packageRoot
    )
    guard buildResult.exitCode == 0 else {
        XCTFail("swift build failed while preparing parity harness:\n\(render(buildResult))")
        throw ParityHarnessError.buildFailed
    }
    return binary
}

private func runProcess(
    executable: URL,
    arguments: [String],
    currentDirectory: URL
) throws -> ProcessResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory

    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error

    try process.run()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return ProcessResult(
        exitCode: process.terminationStatus,
        stdout: stdout,
        stderr: stderr
    )
}

private func expectEqualData(_ actual: Data, _ expected: Data, stream: String, caseName: String) {
    guard actual != expected else { return }
    XCTFail("""
    \(stream) mismatch for \(caseName)
    --- swift-ripgrep
    \(render(actual))
    --- installed rg
    \(render(expected))
    """)
}

private func render(_ result: ProcessResult) -> String {
    """
    exit: \(result.exitCode)
    stdout:
    \(render(result.stdout))
    stderr:
    \(render(result.stderr))
    """
}

private func render(_ data: Data) -> String {
    if let text = String(data: data, encoding: .utf8) {
        return text.debugDescription
    }
    return data.base64EncodedString()
}

private enum ParityHarnessError: Error {
    case buildFailed
}
