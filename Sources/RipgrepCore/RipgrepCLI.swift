import Darwin
import Foundation

public enum RipgrepCLI {
    public static let version = "15.2.0"
    public static let revision = "e89fff89ac"

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
        case .shortHelp:
            emitStdoutVerbatim(helpOutput(named: "rg.help.short"), stdout: stdout)
            return 0
        case .longHelp:
            emitStdoutVerbatim(helpOutput(named: "rg.help.long"), stdout: stdout)
            return 0
        case .shortVersion:
            emitStdout("ripgrep \(version) (rev \(revision))", stdout: stdout)
            return 0
        case .longVersion:
            emitStdoutVerbatim(longVersionOutput, stdout: stdout)
            return 0
        case .pcre2Version:
            emitStdout(PCRE2Backend.versionDescription, stdout: stdout)
            return 0
        case .generate(let mode):
            emitStdoutVerbatim(generate(mode), stdout: stdout)
            return 0
        case .error(let message):
            stderr(message.hasPrefix("rg: ") ? message : "rg: \(message)")
            return 2
        case .run(var options):
            configureStdoutBuffering(options: options, stdoutOverride: stdout)
            do {
                if !options.noMessages {
                    for warning in options.startupWarnings {
                        stderr("rg: \(warning)")
                    }
                }
                for diagnostic in options.startupDiagnostics {
                    stderr("rg: \(diagnostic)")
                }
                for diagnostic in runtimeDebugDiagnostics(options: options, fileManager: fileManager) {
                    stderr("rg: \(diagnostic)")
                }
                if !options.typeChanges.isEmpty {
                    try validateTypeChanges(options.typeChanges)
                }
                if options.mode == .search, options.maxCount == 0 {
                    return 1
                }
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

                if options.mode == .files {
                    if stdout == nil,
                       let filePathResults = try searcher.writeDarwinFilePathsWithMessages(
                        options: options,
                        stopAfterFirst: options.quiet,
                        writeBytes: writeStdout
                       ) {
                        for diagnostic in filePathResults.diagnostics {
                            stderr("rg: \(diagnostic)")
                        }
                        if !options.noMessages {
                            for message in filePathResults.messages {
                                stderr("rg: \(message)")
                            }
                        }
                        if !filePathResults.messages.isEmpty {
                            if filePathResults.count == 0 {
                                return 2
                            }
                            if !options.quiet {
                                return 2
                            }
                        }
                        return filePathResults.count == 0 ? 1 : 0
                    }
                    var filePathOutputBuffer = Data()
                    filePathOutputBuffer.reserveCapacity(64 * 1024)
                    if let filePathResults = try searcher.streamFilePathsWithMessages(
                        options: options,
                        stopAfterFirst: options.quiet,
                        emit: { line in
                            guard !options.quiet else {
                                return
                            }
                            if stdout == nil {
                                appendUTF8(line, to: &filePathOutputBuffer)
                                filePathOutputBuffer.append(UInt8(ascii: "\n"))
                                if filePathOutputBuffer.count >= 64 * 1024 {
                                    writeStdout(filePathOutputBuffer)
                                    filePathOutputBuffer.removeAll(keepingCapacity: true)
                                }
                            } else {
                                emitStdout(line, stdout: stdout, suppressNewlineForTrailingNul: options.nullPathTerminator)
                            }
                        }
                    ) {
                        if !filePathOutputBuffer.isEmpty {
                            writeStdout(filePathOutputBuffer)
                        }
                        for diagnostic in filePathResults.diagnostics {
                            stderr("rg: \(diagnostic)")
                        }
                        if !options.noMessages {
                            for message in filePathResults.messages {
                                stderr("rg: \(message)")
                            }
                        }
                        if !filePathResults.messages.isEmpty {
                            if filePathResults.count == 0 {
                                return 2
                            }
                            if !options.quiet {
                                return 2
                            }
                        }
                        return filePathResults.count == 0 ? 1 : 0
                    }
                    let walkResults = try searcher.walkFilesWithMessages(options: options)
                    var stdinAdjustedFiles: [URL]?
                    if options.useStdin {
                        stdinAdjustedFiles = filesModePathsWithStdin(walkResults.haystacks.map(\.url), options: options)
                    }
                    let hasFiles = stdinAdjustedFiles?.isEmpty == false || (stdinAdjustedFiles == nil && !walkResults.haystacks.isEmpty)
                    if !options.quiet {
                        let printer = StandardPrinter(options: options)
                        if let stdinAdjustedFiles {
                            for url in stdinAdjustedFiles {
                                let line = printer.path(for: url)
                                emitStdout(line, stdout: stdout, suppressNewlineForTrailingNul: options.nullPathTerminator)
                            }
                        } else {
                            for haystack in walkResults.haystacks {
                                let line = printer.path(for: haystack.url)
                                emitStdout(line, stdout: stdout, suppressNewlineForTrailingNul: options.nullPathTerminator)
                            }
                        }
                    }
                    for diagnostic in walkResults.diagnostics {
                        stderr("rg: \(diagnostic)")
                    }
                    if !options.noMessages {
                        for message in walkResults.messages {
                            stderr("rg: \(message)")
                        }
                    }
                    if !walkResults.messages.isEmpty {
                        if !hasFiles {
                            return 2
                        }
                        if !options.quiet {
                            return 2
                        }
                    }
                    return hasFiles ? 0 : 1
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

                let results: SearchResults
                if stdout == nil,
                   let streamedResults = try searcher.writeDarwinSimpleByteLiteralLines(
                    options: options,
                    writeBytes: writeStdout,
                    allowDirectStdout: true
                   ) {
                    results = streamedResults
                } else if let streamedResults = try searcher.streamPlainMatchingLines(options: options, emit: { line in
                    emitStdout(line, stdout: stdout)
                }) {
                    results = streamedResults
                } else {
                    results = try searcher.search(options: options, stdin: searchStdin)
                    let outputEncodingMode = options.json ? nil : outputEncodingMode(for: options, results: results)
                    let outputLines: [String]
                    if options.quiet && !options.stats && !options.json {
                        outputLines = []
                    } else if options.json {
                        outputLines = JSONPrinter(options: options).lines(for: results)
                    } else {
                        outputLines = StandardPrinter(options: options).lines(for: results)
                    }
                    for line in outputLines {
                        emitStdout(
                            line,
                            stdout: stdout,
                            encodingMode: outputEncodingMode,
                            suppressNewlineForTrailingNul: options.nullData || options.nullPathTerminator
                        )
                    }
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

    public static func runUtilityFastPath(
        arguments: [String],
        stdout: ((String) -> Void)? = nil
    ) -> Int32? {
        if arguments.count == 2, arguments[0] == "--generate" {
            guard let mode = GenerateMode(rawValue: arguments[1]) else {
                return nil
            }
            emitGeneratedAsset(for: mode, stdout: stdout)
            return 0
        }
        guard arguments.count == 1 else {
            return nil
        }
        switch arguments[0] {
        case "-h":
            emitGeneratedAsset(named: "rg.help.short", stdout: stdout, fallback: usage())
            return 0
        case "--help":
            emitGeneratedAsset(named: "rg.help.long", stdout: stdout, fallback: usage())
            return 0
        case "-V":
            emitStdout("ripgrep \(version) (rev \(revision))", stdout: stdout)
            return 0
        case "--version":
            emitStdoutVerbatim(longVersionOutput, stdout: stdout)
            return 0
        case "--pcre2-version":
            emitStdout(PCRE2Backend.versionDescription, stdout: stdout)
            return 0
        case let value where value.hasPrefix("--generate="):
            let raw = String(value.dropFirst("--generate=".count))
            guard let mode = GenerateMode(rawValue: raw) else {
                return nil
            }
            emitGeneratedAsset(for: mode, stdout: stdout)
            return 0
        default:
            return nil
        }
    }

    private static func appendUTF8(_ string: String, to data: inout Data) {
        var string = string
        string.withUTF8 { bytes in
            guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else {
                return
            }
            data.append(baseAddress, count: bytes.count)
        }
    }

    private static func emitStdout(
        _ line: String,
        stdout: ((String) -> Void)?,
        encodingMode: EncodingMode? = nil,
        suppressNewlineForTrailingNul: Bool = false
    ) {
        if let stdout {
            stdout(line.rawBytePayload ?? line)
            return
        }
        let output = suppressNewlineForTrailingNul && line.hasSuffix("\0") ? line : "\(line)\n"
        let data = output.rawBytePayload.map { $0.rawByteData() } ?? (encodingMode == .disabled
            ? output.rawByteData()
            : Data(output.utf8))
        writeStdout(data)
    }

    private static func emitStdoutVerbatim(_ output: String, stdout: ((String) -> Void)?) {
        if let stdout {
            stdout(output)
            return
        }
        writeStdout(Data(output.utf8))
    }

    private static func emitGeneratedAsset(
        for mode: GenerateMode,
        stdout: ((String) -> Void)?
    ) {
        if stdout == nil, let data = generatedAssetData(for: mode) {
            writeStdout(data)
            return
        }
        emitStdoutVerbatim(generate(mode), stdout: stdout)
    }

    private static func emitGeneratedAsset(
        named resourceName: String,
        stdout: ((String) -> Void)?,
        fallback: @autoclosure () -> String
    ) {
        if stdout == nil, let data = generatedAssetData(named: resourceName) {
            writeStdout(data)
            return
        }
        emitStdoutVerbatim(generatedAsset(named: resourceName) ?? fallback(), stdout: stdout)
    }

    private static func configureStdoutBuffering(
        options: RipgrepOptions,
        stdoutOverride: ((String) -> Void)?
    ) {
        guard stdoutOverride == nil else {
            return
        }
        switch resolvedBufferMode(options.bufferMode) {
        case .line:
            setvbuf(Darwin.stdout, nil, _IOLBF, 0)
        case .block:
            setvbuf(Darwin.stdout, nil, _IOFBF, 262_144)
        case .automatic:
            break
        }
    }

    private static func resolvedBufferMode(_ mode: BufferMode) -> BufferMode {
        switch mode {
        case .automatic:
            return isatty(STDOUT_FILENO) != 0 ? .line : .block
        case .line, .block:
            return mode
        }
    }

    private static func writeStdout(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        data.withUnsafeBytes { buffer in
            writeStdout(buffer)
        }
    }

    private static func writeStdout(_ buffer: UnsafeRawBufferPointer) {
        guard !buffer.isEmpty else {
            return
        }
        guard let baseAddress = buffer.baseAddress else {
            return
        }
        fwrite(baseAddress, 1, buffer.count, Darwin.stdout)
    }

    private static func outputEncodingMode(for options: RipgrepOptions, results: SearchResults) -> EncodingMode? {
        return options.encodingMode
    }

    private static func runtimeDebugDiagnostics(
        options: RipgrepOptions,
        fileManager: FileManager
    ) -> [String] {
        guard options.loggingMode != .none else {
            return []
        }

        var diagnostics: [String] = []
        let cwd = realpath(fileManager.currentDirectoryPath) ?? fileManager.currentDirectoryPath
        diagnostics.append("DEBUG|rg::flags::hiargs|crates/core/flags/hiargs.rs:954: read CWD from environment: \(cwd)")
        diagnostics.append("DEBUG|rg::flags::hiargs|crates/core/flags/hiargs.rs:1092: number of paths given to search: \(options.rootPathArguments.count)")
        diagnostics.append("DEBUG|rg::flags::hiargs|crates/core/flags/hiargs.rs:1103: is_one_file? \(isOneFileSearch(options: options) ? "true" : "false")")
        if let hostname = debugHostname() {
            diagnostics.append("DEBUG|rg::flags::hiargs|crates/core/flags/hiargs.rs:1278: found hostname for hyperlink configuration: \(hostname)")
        }
        diagnostics.append(#"DEBUG|rg::flags::hiargs|crates/core/flags/hiargs.rs:1288: hyperlink format: """#)
        let threadCount = options.threadCount.map { max(1, $0) }
            ?? max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        diagnostics.append("DEBUG|rg::flags::hiargs|crates/core/flags/hiargs.rs:175: using \(threadCount) thread(s)")

        let globalGitIgnore = "\(NSHomeDirectory())/.config/git/ignore"
        if fileManager.fileExists(atPath: globalGitIgnore) {
            diagnostics.append("DEBUG|ignore::gitignore|crates/ignore/src/gitignore.rs:398: opened gitignore file: \(globalGitIgnore)")
            diagnostics.append("DEBUG|globset|crates/globset/src/lib.rs:515: built glob set; 3 literals, 0 basenames, 0 extensions, 0 prefixes, 22 suffixes, 0 required extensions, 0 regexes")
        }
        if options.mode == .search, !options.effectivePatterns.isEmpty {
            diagnostics.append("DEBUG|grep_regex::config|crates/regex/src/config.rs:175: assembling HIR from \(options.effectivePatterns.count) fixed string literals")
        }
        return diagnostics
    }

    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func debugHostname() -> String? {
        guard var hostname = Host.current().localizedName, !hostname.isEmpty else {
            return nil
        }
        if !hostname.contains(".") {
            hostname += ".local"
        }
        return hostname
    }

    private static func isOneFileSearch(options: RipgrepOptions) -> Bool {
        guard options.rootPathArguments.count == 1,
              let root = options.roots.first else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func carriesRawOutputLines(_ results: SearchResults) -> Bool {
        results.files.contains { file in
            file.matches.contains { $0.rawLine != nil }
                || file.lines.contains { $0.rawLine != nil }
        }
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
            && !options.patternFileStdin
            && options.rootPathArguments.isEmpty
            && options.roots.count == 1
            && options.roots[0].path == FileManager.default.currentDirectoryPath
            && (stdinProvided || standardInputIsReadable)
    }

    private static func validateTypeChanges(_ changes: [TypeChange]) throws {
        var registry = FileTypeRegistry()
        if let error = registry.apply(changes).first {
            throw RipgrepError.message(error)
        }
    }

    private static func shouldPrintNothingSearchedWarning(results: SearchResults, options: RipgrepOptions) -> Bool {
        guard options.rootPathArguments.isEmpty,
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
        if let sortMode = options.sortMode,
           sortMode.kind != .path || sortMode.reverse {
            return files + [stdinURL]
        }
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

    private static func helpOutput(named resourceName: String) -> String {
        generatedAsset(named: resourceName) ?? usage()
    }

    private static var longVersionOutput: String {
        """
        ripgrep \(version) (rev \(revision))

        features:+pcre2
        simd(compile):+NEON
        simd(runtime):+NEON

        \(PCRE2Backend.versionDescription)

        """
    }

    private static func generate(_ mode: GenerateMode) -> String {
        if let generated = generatedAsset(for: mode) {
            return generated
        }
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

    private static func generatedAsset(for mode: GenerateMode) -> String? {
        guard let data = generatedAssetData(for: mode) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func generatedAssetData(for mode: GenerateMode) -> Data? {
        let resourceName: String
        switch mode {
        case .man:
            resourceName = "rg.1"
        case .completeBash:
            resourceName = "rg.bash"
        case .completeZsh:
            resourceName = "_rg"
        case .completeFish:
            resourceName = "rg.fish"
        case .completePowerShell:
            resourceName = "_rg.ps1"
        }
        return generatedAssetData(named: resourceName)
    }

    private static func generatedAsset(named resourceName: String) -> String? {
        guard let data = generatedAssetData(named: resourceName) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func generatedAssetData(named resourceName: String) -> Data? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: nil) else {
            return nil
        }
        return try? Data(contentsOf: url)
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
    static let rawByteMarker = String(UnicodeScalar(0xFDD0)!)

    var rawBytePayload: String? {
        hasPrefix(Self.rawByteMarker) ? String(dropFirst()) : nil
    }

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
