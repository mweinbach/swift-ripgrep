import Foundation

public enum RipgrepCLI {
    public static let version = "0.1.0"

    public struct OutputOptions: Equatable {
        public let showFilename: Bool
        public let showLineNumber: Bool

        public init(showFilename: Bool, showLineNumber: Bool) {
            self.showFilename = showFilename
            self.showLineNumber = showLineNumber
        }
    }

    public static func run(
        arguments: [String],
        stdout: (String) -> Void = { line in
            let output = line.hasSuffix("\0") ? line : "\(line)\n"
            if let data = output.data(using: .utf8) {
                FileHandle.standardOutput.write(data)
            }
        },
        stderr: (String) -> Void = { message in
            if let data = "\(message)\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        },
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdin: String? = nil
    ) -> Int32 {
        switch RipgrepArgumentParser.parse(arguments, environment: environment) {
        case .help:
            stdout(usage())
            return 0
        case .version:
            stdout("ripgrep \(version)")
            return 0
        case .pcre2Version:
            if let version = pcre2Version(environment: environment) {
                stdout("PCRE2 \(version) is available (JIT availability unknown)")
                return 0
            }
            stderr("PCRE2 is not available in this Swift build")
            return 2
        case .generate(let mode):
            stdout(generate(mode))
            return 0
        case .error(let message):
            stderr(message)
            return 2
        case .run(let options):
            do {
                let searcher = RipgrepSearcher(fileManager: fileManager, environment: environment)
                let printer = StandardPrinter(options: options)

                if options.mode == .files {
                    for line in try printer.paths(searcher.files(options: options)) {
                        stdout(line)
                    }
                    return 0
                }
                if options.mode == .types {
                    var registry = FileTypeRegistry()
                    registry.apply(options.typeChanges)
                    for line in registry.typeListLines() {
                        stdout(line)
                    }
                    return registry.definitions.isEmpty ? 1 : 0
                }

                let results = try searcher.search(options: options, stdin: stdin)
                let outputLines = options.json
                    ? JSONPrinter(options: options).lines(for: results)
                    : printer.lines(for: results)
                for line in outputLines {
                    stdout(line)
                }
                for diagnostic in results.diagnostics {
                    stderr("rg: \(diagnostic)")
                }
                if !options.noMessages {
                    for message in results.messages {
                        stderr("rg: \(message)")
                    }
                }

                if !results.messages.isEmpty && !(options.quiet && results.hasMatch) {
                    return 2
                }
                return results.hasMatch ? 0 : 1
            } catch {
                stderr("rg: \(error)")
                return 2
            }
        }
    }

    public static func usage() -> String {
        RipgrepArgumentParser.usage(version: version)
    }

    private static func pcre2Version(environment: [String: String]) -> String? {
        guard let executable = resolveExecutable("pcre2-config", environment: environment) else {
            return nil
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
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
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    private static func generate(_ mode: GenerateMode) -> String {
        switch mode {
        case .man:
            return """
            .TH RG 1
            .SH NAME
            rg \\- recursively search the current directory for lines matching a pattern
            .SH SYNOPSIS
            .B rg
            [OPTIONS] <pattern> [path ...]
            .SH DESCRIPTION
            swift-ripgrep is a Swift port of ripgrep. This generated page is derived from the Swift CLI usage surface.
            .SH OPTIONS
            \(usage().replacingOccurrences(of: "\n", with: "\n.br\n"))
            """
        case .completeBash:
            return """
            _rg() {
                local cur="${COMP_WORDS[COMP_CWORD]}"
                COMPREPLY=( $(compgen -W "\(completionWords)" -- "$cur") )
            }
            complete -F _rg rg
            """
        case .completeZsh:
            return """
            #compdef rg
            _arguments '*::arg:->args' \\
              '(- *)'{\(completionWords.split(separator: " ").joined(separator: ","))}'[swift-ripgrep option]'
            """
        case .completeFish:
            return completionWords
                .split(separator: " ")
                .map { "complete -c rg -l \(String($0).dropFirst(2))" }
                .joined(separator: "\n")
        case .completePowerShell:
            return """
            Register-ArgumentCompleter -Native -CommandName rg -ScriptBlock {
                param($wordToComplete)
                '\(completionWords)' -split ' ' | Where-Object { $_ -like "$wordToComplete*" }
            }
            """
        }
    }

    private static let completionWords = [
        "--after-context",
        "--auto-hybrid-regex",
        "--before-context",
        "--binary",
        "--block-buffered",
        "--byte-offset",
        "--case-sensitive",
        "--color",
        "--colors",
        "--column",
        "--context",
        "--count",
        "--count-matches",
        "--crlf",
        "--debug",
        "--dfa-size-limit",
        "--encoding",
        "--engine",
        "--field-context-separator",
        "--field-match-separator",
        "--file",
        "--files",
        "--files-with-matches",
        "--files-without-match",
        "--fixed-strings",
        "--follow",
        "--generate",
        "--glob",
        "--glob-case-insensitive",
        "--heading",
        "--help",
        "--hidden",
        "--hostname-bin",
        "--hyperlink-format",
        "--iglob",
        "--ignore-case",
        "--ignore-file",
        "--ignore-file-case-insensitive",
        "--include-zero",
        "--invert-match",
        "--json",
        "--line-buffered",
        "--line-number",
        "--max-columns",
        "--max-columns-preview",
        "--max-count",
        "--max-depth",
        "--max-filesize",
        "--mmap",
        "--multiline",
        "--multiline-dotall",
        "--no-config",
        "--no-filename",
        "--no-ignore",
        "--no-ignore-dot",
        "--no-ignore-exclude",
        "--no-ignore-files",
        "--no-ignore-global",
        "--no-ignore-messages",
        "--no-ignore-parent",
        "--no-ignore-vcs",
        "--no-messages",
        "--no-require-git",
        "--no-unicode",
        "--null",
        "--null-data",
        "--one-file-system",
        "--only-matching",
        "--path-separator",
        "--passthru",
        "--pcre2",
        "--pcre2-version",
        "--pre",
        "--pre-glob",
        "--pretty",
        "--quiet",
        "--regex-size-limit",
        "--regexp",
        "--replace",
        "--search-zip",
        "--smart-case",
        "--sort",
        "--sort-files",
        "--sortr",
        "--stats",
        "--stop-on-nonmatch",
        "--text",
        "--threads",
        "--trace",
        "--trim",
        "--type",
        "--type-add",
        "--type-clear",
        "--type-list",
        "--type-not",
        "--unrestricted",
        "--version",
        "--vimgrep",
        "--with-filename",
        "--word-regexp",
    ].joined(separator: " ")

    private static func resolveExecutable(_ name: String, environment: [String: String]) -> URL? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in paths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public static func format(
        _ match: SearchMatch,
        options: OutputOptions = OutputOptions(showFilename: true, showLineNumber: true)
    ) -> String {
        var ripgrepOptions = RipgrepOptions()
        ripgrepOptions.withFilename = options.showFilename
        ripgrepOptions.lineNumber = options.showLineNumber
        return StandardPrinter(options: ripgrepOptions).lines(for: SearchResults(
            files: [SearchFileResult(fileURL: match.fileURL, matches: [match])],
            summary: SearchSummary(
                filesSearched: 1,
                filesWithMatches: 1,
                matchedLines: 1,
                totalMatches: match.matchCount
            )
        )).first ?? match.line
    }
}
