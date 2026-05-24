import Foundation
import Darwin

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
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command]
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
        guard canonical.hasPrefix("/") else {
            return nil
        }
        return percentEncode(canonical)
    }

    private func canonicalPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
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
