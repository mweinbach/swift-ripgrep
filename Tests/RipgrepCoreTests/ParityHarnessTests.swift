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

        for parityCase in parityCases() {
            if let reason = parityCase.intentionallySkippedBecause {
                print("Skipping parity case \(parityCase.name): \(reason)")
                continue
            }

            let tempdir = try IsolatedParityDirectory(name: parityCase.name)
            try parityCase.fixture(tempdir.url)

            let arguments = ["--path-separator", "/"] + parityCase.arguments
            let swiftResult = try runProcess(
                executable: swiftRipgrep,
                arguments: arguments,
                currentDirectory: tempdir.url,
                stdin: parityCase.stdin
            )
            let rustResult = try runProcess(
                executable: rustRipgrep,
                arguments: arguments,
                currentDirectory: tempdir.url,
                stdin: parityCase.stdin
            )

            XCTAssertEqual(
                swiftResult.exitCode,
                rustResult.exitCode,
                "exit status mismatch for \(parityCase.name)\n\(renderComparison(swift: swiftResult, rust: rustResult))"
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
    var fixture: (URL) throws -> Void
    var arguments: [String]
    var stdin: Data?
    var intentionallySkippedBecause: String?

    init(
        name: String,
        fixture: @escaping (URL) throws -> Void,
        arguments: [String],
        stdin: Data? = nil,
        intentionallySkippedBecause: String? = nil
    ) {
        self.name = name
        self.fixture = fixture
        self.arguments = arguments
        self.stdin = stdin
        self.intentionallySkippedBecause = intentionallySkippedBecause
    }
}

private func parityCases() -> [ParityCase] {
    [
        ParityCase(
            name: "recursive sorted text search honors ignore files",
            fixture: existingParityFixture,
            arguments: ["--sort", "path", "needle", "."]
        ),
        ParityCase(
            name: "ignored file produces no match",
            fixture: existingParityFixture,
            arguments: ["ignored-only", "."]
        ),
        ParityCase(
            name: "line numbers in multiline fixture",
            fixture: existingParityFixture,
            arguments: ["-n", "line", "multiline.txt"]
        ),
        ParityCase(
            name: "binary searched as text",
            fixture: existingParityFixture,
            arguments: ["-a", "binary", "binary.bin"]
        ),
        ParityCase(
            name: "explicit UTF-16LE decoding",
            fixture: existingParityFixture,
            arguments: ["--encoding", "utf-16le", "hello", "utf16le.txt"]
        ),
        ParityCase(
            name: "multiline search across line terminators",
            fixture: existingParityFixture,
            arguments: ["-U", "--multiline", "two\\nline", "multiline.txt"]
        ),
        ParityCase(
            name: "threaded sorted text search",
            fixture: existingParityFixture,
            arguments: ["--threads", "4", "--sort", "path", "needle", "."]
        ),
        ParityCase(
            name: "single-thread sorted text search",
            fixture: existingParityFixture,
            arguments: ["--threads", "1", "--sort", "path", "needle", "."]
        ),
    ]
}

private func existingParityFixture(in dir: URL) throws {
    try write("needle in one\n", to: "text/one.txt", in: dir)
    try write("needle in two\n", to: "nested/two.txt", in: dir)
    try write("ignored-only\n", to: "ignored.txt", in: dir)
    try write("ignored.txt\n", to: ".ignore", in: dir)
    try write("one line\ntwo line\n", to: "multiline.txt", in: dir)
    try write(Data([0x62, 0x69, 0x6E, 0x61, 0x72, 0x79, 0x00, 0x74, 0x65, 0x78, 0x74, 0x0A]), to: "binary.bin", in: dir)
    try write(Data("hello\n".utf16LittleEndianBytes), to: "utf16le.txt", in: dir)
}

private struct ProcessResult {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
}

private final class IsolatedParityDirectory {
    let url: URL

    init(name: String) throws {
        let safeName = String(name.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-ripgrep-parity-\(safeName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func write(_ contents: String, to relativePath: String, in dir: URL) throws {
    try write(Data(contents.utf8), to: relativePath, in: dir)
}

private func write(_ data: Data, to relativePath: String, in dir: URL) throws {
    let fileURL = dir.appendingPathComponent(relativePath, isDirectory: false)
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
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
    currentDirectory: URL,
    stdin: Data? = nil
) throws -> ProcessResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "RIPGREP_CONFIG_PATH")
    process.environment = environment

    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    if stdin != nil {
        process.standardInput = input
    }
    process.standardOutput = output
    process.standardError = error

    try process.run()
    if let stdin {
        try input.fileHandleForWriting.write(contentsOf: stdin)
        try input.fileHandleForWriting.close()
    }
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

private func renderComparison(swift: ProcessResult, rust: ProcessResult) -> String {
    """
    --- swift-ripgrep
    \(render(swift))
    --- installed rg
    \(render(rust))
    """
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

