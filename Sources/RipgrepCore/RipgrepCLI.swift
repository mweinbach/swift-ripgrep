import Foundation

public enum RipgrepCLI {
    public static let version = "0.1.0"

    public static func run(
        arguments: [String],
        stdout: (String) -> Void = { print($0) },
        stderr: (String) -> Void = { message in
            if let data = "\(message)\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        },
        fileManager: FileManager = .default
    ) -> Int32 {
        var ignoreCase = false
        var positionals: [String] = []

        for argument in arguments {
            switch argument {
            case "-h", "--help":
                stdout(usage())
                return 0
            case "--version":
                stdout("ripgrep \(version)")
                return 0
            case "-i", "--ignore-case":
                ignoreCase = true
            default:
                if argument.hasPrefix("-") {
                    stderr("error: unrecognized option '\(argument)'")
                    return 2
                }
                positionals.append(argument)
            }
        }

        guard let pattern = positionals.first, !pattern.isEmpty else {
            stderr(usage())
            return 2
        }

        let pathArguments = positionals.dropFirst()
        let roots = (pathArguments.isEmpty ? ["."] : Array(pathArguments))
            .map { URL(fileURLWithPath: $0) }

        do {
            let matches = try RipgrepSearcher(fileManager: fileManager).search(
                pattern: pattern,
                roots: roots,
                ignoreCase: ignoreCase
            )

            for match in matches {
                stdout(format(match))
            }

            return matches.isEmpty ? 1 : 0
        } catch {
            stderr("error: \(error)")
            return 2
        }
    }

    public static func usage() -> String {
        """
        ripgrep \(version)

        USAGE:
          ripgrep [OPTIONS] <pattern> [path ...]

        OPTIONS:
          -i, --ignore-case    Search case insensitively
          -h, --help           Print help
              --version        Print version
        """
    }

    public static func format(_ match: SearchMatch) -> String {
        "\(displayPath(for: match.fileURL)):\(match.lineNumber):\(match.line)"
    }

    private static func displayPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
            .path
        let prefix = currentDirectory.hasSuffix("/") ? currentDirectory : "\(currentDirectory)/"

        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }

        return path
    }
}
