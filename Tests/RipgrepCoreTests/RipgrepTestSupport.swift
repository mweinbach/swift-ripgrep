import Foundation
import Testing
@testable import RipgrepCore

func run(
    _ arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> [String] {
    var output: [String] = []
    var errors: [String] = []
    let exitCode = RipgrepCLI.run(
        arguments: arguments,
        stdout: { output.append($0) },
        stderr: { errors.append($0) },
        environment: environment
    )
    #expect(errors.isEmpty)
    #expect(exitCode == (output.isEmpty ? 1 : 0))
    return output
}

func runAllowingNoMatch(_ arguments: [String]) throws -> [String] {
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

func runWithExitCode(_ arguments: [String], expectedExitCode: Int) -> [String] {
    var output: [String] = []
    var errors: [String] = []
    let exitCode = RipgrepCLI.run(
        arguments: arguments,
        stdout: { output.append($0) },
        stderr: { errors.append($0) }
    )
    #expect(errors.isEmpty)
    #expect(exitCode == expectedExitCode)
    return output
}

func pathBasenames(_ lines: [String]) -> [String] {
    lines.map { line in
        #if os(Windows)
        let delimiter = line.dropFirst(min(2, line.count)).firstIndex(of: ":")
        let path = delimiter.map { String(line[..<$0]) } ?? line
        #else
        let path = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
        #endif
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

func countBasenames(_ lines: [String]) -> [String] {
    lines.map { line in
        #if os(Windows)
        guard let delimiter = line.lastIndex(of: ":") else {
            return line
        }
        let path = String(line[..<delimiter])
        let count = String(line[line.index(after: delimiter)...])
        return "\(URL(fileURLWithPath: path).lastPathComponent):\(count)"
        #else
        let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else {
            return line
        }
        return "\(URL(fileURLWithPath: String(pieces[0])).lastPathComponent):\(pieces[1])"
        #endif
    }
}

func jsonObject(_ line: String) throws -> [String: Any] {
    let data = try #require(line.data(using: .utf8))
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

func runExecutableData(
    _ arguments: [String],
    environment: [String: String] = [:],
    fixture: () throws -> Void
) throws -> Data {
    let result = try runExecutableResult(arguments, environment: environment, fixture: fixture)
    #expect(result.error.isEmpty)
    #expect(result.exitCode == (result.output.isEmpty ? 1 : 0))
    return result.output
}

func runExecutableResult(
    _ arguments: [String],
    environment: [String: String] = [:],
    fixture: () throws -> Void
) throws -> (output: Data, error: Data, exitCode: Int32) {
    try fixture()
    let executable = ripgrepExecutableURL()
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if !environment.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    }
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (data, errorData, process.terminationStatus)
}

func ripgrepPackageRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func ripgrepExecutableURL() -> URL {
    let root = ripgrepPackageRootURL()
    #if os(Windows)
    let candidates = [
        ".build/debug/ripgrep.exe",
        ".build/x86_64-unknown-windows-msvc/debug/ripgrep.exe",
        ".build/aarch64-unknown-windows-msvc/debug/ripgrep.exe",
    ]
    #else
    let candidates = [".build/debug/ripgrep"]
    #endif
    for path in candidates {
        let candidate = root.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return root.appendingPathComponent(candidates[0])
}

final class TemporaryDirectory {
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
        try write(Data(contents.utf8), to: relativePath)
    }

    func write(_ data: Data, to relativePath: String) throws {
        let fileURL = url.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
    }

    func makeExecutable(_ relativePath: String) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path(relativePath)
        )
    }

    func writeGzip(_ contents: String, to relativePath: String) throws {
        try writeGzip(Data(contents.utf8), to: relativePath)
    }

    func writeGzip(_ contents: Data, to relativePath: String) throws {
        let fileURL = url.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gzip", "-c"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output

        try process.run()
        try input.fileHandleForWriting.write(contentsOf: contents)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try data.write(to: fileURL)
    }

    func path(_ relativePath: String) -> String {
        url.appendingPathComponent(relativePath, isDirectory: false).path
    }

    func setModificationDate(_ date: Date, for relativePath: String) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: path(relativePath)
        )
    }
}

extension String {
    var utf16LittleEndianBytes: [UInt8] {
        utf16.flatMap { codeUnit in
            [
                UInt8(codeUnit & 0x00FF),
                UInt8((codeUnit & 0xFF00) >> 8),
            ]
        }
    }

    var utf16BigEndianBytes: [UInt8] {
        utf16.flatMap { codeUnit in
            [
                UInt8((codeUnit & 0xFF00) >> 8),
                UInt8(codeUnit & 0x00FF),
            ]
        }
    }
}
