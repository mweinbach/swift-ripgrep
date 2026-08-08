import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct HyperlinkFormatter {
    private static let escape = "\u{1B}"
    private let format: HyperlinkFormat
    private let isEnabled: Bool
    private let host: String
    private let wslPrefix: String

    init(options: RipgrepOptions, colorsEnabled: Bool) {
        self.format = options.hyperlinkFormat
        self.isEnabled = colorsEnabled && options.hyperlinkFormat.isEnabled
        self.host = Self.hostname(from: options.hostnameBin) ?? ProcessInfo.processInfo.hostName
        if let distro = ProcessInfo.processInfo.environment["WSL_DISTRO_NAME"], !distro.isEmpty {
            self.wslPrefix = "wsl$/\(distro)"
        } else {
            self.wslPrefix = ""
        }
    }

    private static func hostname(from command: String?) -> String? {
        guard let command, !command.isEmpty else {
            return nil
        }
        let process = Process()
        if command.contains("/") || command.contains("\\") {
            process.executableURL = URL(fileURLWithPath: command)
        } else {
            #if os(Windows)
            guard let executable = resolveExecutable(command) else {
                return nil
            }
            process.executableURL = executable
            #else
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command]
            #endif
        }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let hostname = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostname.isEmpty ? nil : hostname
    }

    #if os(Windows)
    private static func resolveExecutable(_ program: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let path = environment.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
        let extensions = (environment.first { $0.key.caseInsensitiveCompare("PATHEXT") == .orderedSame }?.value
            ?? ".COM;.EXE;.BAT;.CMD")
            .split(separator: ";")
            .map(String.init)
        let candidateNames = URL(fileURLWithPath: program).pathExtension.isEmpty
            ? [program] + extensions.map { program + $0.lowercased() }
            : [program]
        for directory in path.split(separator: ";").map(String.init) {
            for name in candidateNames {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
    #endif

    func label(_ text: String, for url: URL, line: Int? = nil, column: Int? = nil) -> String {
        guard isEnabled,
              let path = hyperlinkPath(for: url) else {
            return text
        }
        let target = interpolate(path: path, line: line, column: column)
        return "\(Self.escape)]8;;\(target)\(Self.escape)\\\(text)\(Self.escape)]8;;\(Self.escape)\\"
    }

    private func interpolate(path: String, line: Int?, column: Int?) -> String {
        var output = ""
        for part in format.parts {
            switch part {
            case .text(let text):
                output += text
            case .path:
                output += path
            case .line:
                output += "\(line ?? 1)"
            case .column:
                output += "\(column ?? 1)"
            case .host:
                output += host
            case .wslPrefix:
                output += wslPrefix
            }
        }
        return output
    }

    private func hyperlinkPath(for url: URL) -> String? {
        guard url.path != "-" else {
            return nil
        }
        let canonical = canonicalPath(for: url)
        #if os(Windows)
        let hyperlinkPath = canonical.replacingOccurrences(of: "\\", with: "/")
        let absolutePath = hyperlinkPath.hasPrefix("/") ? hyperlinkPath : "/\(hyperlinkPath)"
        #else
        let absolutePath = canonical
        #endif
        guard absolutePath.hasPrefix("/") else {
            return nil
        }
        return percentEncode(absolutePath)
    }

    private func canonicalPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        guard let resolved = realpath(path, nil) else {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
        #else
        return url.resolvingSymlinksInPath().standardizedFileURL.path
        #endif
    }

    private func percentEncode(_ path: String) -> String {
        var output = ""
        for scalar in path.unicodeScalars {
            if isUnreservedHyperlinkScalar(scalar) {
                output.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    output += "%"
                    output += String(format: "%02X", byte)
                }
            }
        }
        return output
    }

    private func isUnreservedHyperlinkScalar(_ scalar: UnicodeScalar) -> Bool {
        if scalar.value >= 128 {
            return true
        }
        switch scalar {
        case "0"..."9", "A"..."Z", "a"..."z", "/", ":", "-", ".", "_", "~":
            return true
        default:
            return false
        }
    }
}
