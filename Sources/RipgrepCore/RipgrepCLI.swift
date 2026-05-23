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
        stdout: ((String) -> Void)? = nil,
        stderr: (String) -> Void = { message in
            if let data = "\(message)\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        },
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdin: String? = nil,
        standardInputIsReadable: Bool = false
    ) -> Int32 {
        switch RipgrepArgumentParser.parse(arguments, environment: environment) {
        case .help:
            emitStdout(usage(), stdout: stdout)
            return 0
        case .version:
            emitStdout("ripgrep \(version)", stdout: stdout)
            return 0
        case .pcre2Version:
            if let version = pcre2Version(environment: environment) {
                emitStdout("PCRE2 \(version) is available (JIT availability unknown)", stdout: stdout)
                return 0
            }
            stderr("PCRE2 is not available in this Swift build")
            return 2
        case .generate(let mode):
            emitStdout(generate(mode), stdout: stdout)
            return 0
        case .error(let message):
            stderr(message.hasPrefix("rg: ") ? message : "rg: \(message)")
            return 2
        case .run(var options):
            do {
                if shouldSearchImplicitStdin(
                    options: options,
                    stdinProvided: stdin != nil,
                    standardInputIsReadable: standardInputIsReadable
                ) {
                    options.useStdin = true
                    options.roots = []
                }
                let searchStdin: String?
                if options.patternFileStdin {
                    let patternInput = stdin ?? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    options.appendPatternFileContents(patternInput)
                    searchStdin = nil
                } else {
                    searchStdin = stdin
                }
                let searcher = RipgrepSearcher(fileManager: fileManager, environment: environment)
                let printer = StandardPrinter(options: options)

                if options.mode == .files {
                    let walkResults = try searcher.walkFilesWithMessages(options: options)
                    var files = walkResults.haystacks.map(\.url)
                    if options.useStdin {
                        files = filesModePathsWithStdin(files, options: options)
                    }
                    if !options.quiet {
                        for line in printer.paths(files) {
                            emitStdout(line, stdout: stdout, suppressNewlineForTrailingNul: options.nullPathTerminator)
                        }
                    }
                    if !options.noMessages {
                        for message in walkResults.messages {
                            stderr("rg: \(message)")
                        }
                    }
                    if !walkResults.messages.isEmpty && !options.quiet {
                        return 2
                    }
                    return files.isEmpty ? 1 : 0
                }
                if options.mode == .types {
                    var registry = FileTypeRegistry()
                    let typeErrors = registry.apply(options.typeChanges)
                    if let error = typeErrors.first {
                        throw RipgrepError.message(error)
                    }
                    for line in registry.typeListLines() {
                        emitStdout(line, stdout: stdout)
                    }
                    return registry.definitions.isEmpty ? 1 : 0
                }

                let results = try searcher.search(options: options, stdin: searchStdin)
                let outputLines = options.json
                    ? JSONPrinter(options: options).lines(for: results)
                    : printer.lines(for: results)
                for line in outputLines {
                    emitStdout(
                        line,
                        stdout: stdout,
                        encodingMode: options.json ? nil : options.encodingMode,
                        suppressNewlineForTrailingNul: options.nullData || options.nullPathTerminator
                    )
                }
                for diagnostic in results.diagnostics {
                    stderr("rg: \(diagnostic)")
                }
                if !options.noMessages {
                    for message in results.messages {
                        stderr("rg: \(message)")
                    }
                    for warning in results.warnings {
                        stderr("rg: \(warning)")
                    }
                    if shouldPrintNothingSearchedWarning(results: results, options: options) {
                        stderr("rg: No files were searched, which means ripgrep probably applied a filter you didn't expect.")
                        stderr("Running with --debug will show why files are being skipped.")
                    }
                }

                let hasSuccessfulOutput = hasSuccessfulOutput(results: results, options: options)
                if !results.messages.isEmpty && !(options.quiet && hasSuccessfulOutput) {
                    return 2
                }
                if shouldExitForImplicitNothingSearched(results: results, options: options) {
                    return 2
                }
                return hasSuccessfulOutput ? 0 : 1
            } catch {
                stderr("rg: \(error)")
                return 2
            }
        }
    }

    private static func emitStdout(
        _ line: String,
        stdout: ((String) -> Void)?,
        encodingMode: EncodingMode? = nil,
        suppressNewlineForTrailingNul: Bool = false
    ) {
        if let stdout {
            stdout(line)
            return
        }
        let output = suppressNewlineForTrailingNul && line.hasSuffix("\0") ? line : "\(line)\n"
        let data = encodingMode == .disabled
            ? output.rawByteData()
            : Data(output.utf8)
        FileHandle.standardOutput.write(data)
    }

    private static func hasSuccessfulOutput(results: SearchResults, options: RipgrepOptions) -> Bool {
        switch options.printMode {
        case .matchingLines, .count, .countMatches, .filesWithMatches:
            return results.hasMatch
        case .filesWithoutMatch:
            return results.files.contains { $0.searched && !$0.hasMatch }
                || results.files.contains { $0.stoppedBinaryAfterMatch }
        }
    }

    private static func shouldSearchImplicitStdin(
        options: RipgrepOptions,
        stdinProvided: Bool,
        standardInputIsReadable: Bool
    ) -> Bool {
        options.mode == .search
            && !options.useStdin
            && options.rootPathArguments.isEmpty
            && options.roots.count == 1
            && options.roots[0].path == FileManager.default.currentDirectoryPath
            && (stdinProvided || standardInputIsReadable)
    }

    private static func shouldPrintNothingSearchedWarning(results: SearchResults, options: RipgrepOptions) -> Bool {
        guard options.printMode == .matchingLines,
              options.rootPathArguments.isEmpty,
              results.summary.filesSearched == 0,
              results.messages.isEmpty,
              results.filtered,
              options.maxFileSize == nil,
              options.typeChanges.isEmpty else {
            return false
        }
        return true
    }

    private static func shouldExitForImplicitNothingSearched(results: SearchResults, options: RipgrepOptions) -> Bool {
        options.rootPathArguments.isEmpty && shouldPrintNothingSearchedWarning(results: results, options: options)
    }

    private static func filesModePathsWithStdin(_ files: [URL], options: RipgrepOptions) -> [URL] {
        let stdinURL = URL(fileURLWithPath: "<stdin>")
        guard let dashIndex = options.rootPathArguments.firstIndex(of: "-") else {
            return files + [stdinURL]
        }
        var output: [URL] = []
        var emitted = Set<String>()
        var insertedStdin = false
        for (offset, root) in options.roots.enumerated() {
            if offset == dashIndex {
                output.append(stdinURL)
                insertedStdin = true
                continue
            }
            for file in files where isPath(file, under: root) {
                let identifier = file.standardizedFileURL.path
                guard !emitted.contains(identifier) else {
                    continue
                }
                output.append(file)
                emitted.insert(identifier)
            }
        }
        for file in files {
            let identifier = file.standardizedFileURL.path
            guard !emitted.contains(identifier) else {
                continue
            }
            output.append(file)
            emitted.insert(identifier)
        }
        if !insertedStdin {
            output.append(stdinURL)
        }
        return output
    }

    private static func isPath(_ file: URL, under root: URL) -> Bool {
        let path = file.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if path == rootPath {
            return true
        }
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        return path.hasPrefix(rootPrefix)
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
        "--context-separator",
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
        "--ignore",
        "--iglob",
        "--ignore-case",
        "--ignore-dot",
        "--ignore-exclude",
        "--ignore-file",
        "--ignore-file-case-insensitive",
        "--ignore-files",
        "--ignore-global",
        "--ignore-messages",
        "--ignore-parent",
        "--ignore-vcs",
        "--include-zero",
        "--invert-match",
        "--json",
        "--line-buffered",
        "--line-number",
        "--line-regexp",
        "--max-columns",
        "--max-columns-preview",
        "--max-count",
        "--max-depth",
        "--max-filesize",
        "--maxdepth",
        "--messages",
        "--mmap",
        "--multiline",
        "--multiline-dotall",
        "--no-auto-hybrid-regex",
        "--no-binary",
        "--no-block-buffered",
        "--no-byte-offset",
        "--no-color",
        "--no-column",
        "--no-config",
        "--no-context-separator",
        "--no-crlf",
        "--no-encoding",
        "--no-filename",
        "--no-fixed-strings",
        "--no-follow",
        "--no-glob-case-insensitive",
        "--no-heading",
        "--no-hidden",
        "--no-ignore",
        "--no-ignore-dot",
        "--no-ignore-exclude",
        "--no-ignore-file-case-insensitive",
        "--no-ignore-files",
        "--no-ignore-global",
        "--no-ignore-messages",
        "--no-ignore-parent",
        "--no-ignore-vcs",
        "--no-include-zero",
        "--no-invert-match",
        "--no-json",
        "--no-line-buffered",
        "--no-line-number",
        "--no-max-columns-preview",
        "--no-messages",
        "--no-mmap",
        "--no-multiline",
        "--no-multiline-dotall",
        "--no-one-file-system",
        "--no-pcre2",
        "--no-pcre2-unicode",
        "--no-pre",
        "--no-require-git",
        "--no-search-zip",
        "--no-sort-files",
        "--no-stats",
        "--no-text",
        "--no-trim",
        "--no-unicode",
        "--null",
        "--null-data",
        "--one-file-system",
        "--only-matching",
        "--path-separator",
        "--passthrough",
        "--passthru",
        "--pcre2",
        "--pcre2-unicode",
        "--pcre2-version",
        "--pre",
        "--pre-glob",
        "--pretty",
        "--quiet",
        "--regex-size-limit",
        "--regexp",
        "--replace",
        "--require-git",
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
        "--unicode",
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

private extension String {
    func rawByteData() -> Data {
        var data = Data()
        for scalar in unicodeScalars {
            if scalar.value <= UInt8.max {
                data.append(UInt8(scalar.value))
            } else {
                data.append(contentsOf: String(scalar).utf8)
            }
        }
        return data
    }
}
