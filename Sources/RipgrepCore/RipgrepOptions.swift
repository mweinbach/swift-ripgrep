import Foundation

public enum SearchMode: Equatable {
    case search
    case files
    case types
}

public enum PrintMode: Equatable {
    case matchingLines
    case count
    case countMatches
    case filesWithMatches
    case filesWithoutMatch
}

public enum BinaryMode: Equatable {
    case automatic
    case searchAndSuppress
    case asText
}

public enum EncodingMode: Equatable {
    case automatic
    case disabled
    case explicit(String.Encoding)
}

public enum ColorMode: Equatable {
    case never
    case automatic
    case always
    case ansi
}

public enum EngineMode: Equatable {
    case `default`
    case pcre2
    case automatic
}

public enum LoggingMode: Equatable {
    case debug
    case trace
}

public enum BufferMode: Equatable {
    case automatic
    case line
    case block
}

public enum MmapMode: Equatable {
    case automatic
    case always
    case never
}

public enum GenerateMode: String, Equatable {
    case man
    case completeBash = "complete-bash"
    case completeZsh = "complete-zsh"
    case completeFish = "complete-fish"
    case completePowerShell = "complete-powershell"
}

public enum ColorTarget: Equatable {
    case path
    case line
    case column
    case match
    case highlight
}

public enum ColorAttribute: Equatable {
    case none
    case foreground(String)
    case background(String)
    case style(String)
}

public struct ColorChange: Equatable {
    public let target: ColorTarget
    public let attribute: ColorAttribute

    public init(target: ColorTarget, attribute: ColorAttribute) {
        self.target = target
        self.attribute = attribute
    }
}

public struct HyperlinkFormat: Equatable {
    public enum Part: Equatable {
        case text(String)
        case path
        case line
        case column
        case host
        case wslPrefix
    }

    public var parts: [Part]

    public init(parts: [Part] = []) {
        self.parts = parts
    }

    public var isEnabled: Bool {
        !parts.isEmpty
    }
}

public enum SortKind: Equatable {
    case path
    case modified
    case accessed
    case created
}

public struct SortMode: Equatable {
    public let kind: SortKind
    public let reverse: Bool

    public init(kind: SortKind, reverse: Bool) {
        self.kind = kind
        self.reverse = reverse
    }
}

public struct RipgrepOptions: Equatable {
    public var startupWarnings: [String] = []
    public var startupDiagnostics: [String] = []
    public var mode: SearchMode = .search
    public var generateMode: GenerateMode?
    public var printMode: PrintMode = .matchingLines
    public var pattern: String?
    public var patterns: [String] = []
    public var patternFileStdin = false
    public var roots: [URL] = []
    public var rootPathArguments: [String] = []
    public var ignoreCase = false
    public var smartCase = false
    public var fixedStrings = false
    public var engineMode: EngineMode = .default
    public var dfaSizeLimit: UInt64?
    public var regexSizeLimit: UInt64?
    public var threadCount: Int?
    public var mmapMode: MmapMode = .automatic
    public var bufferMode: BufferMode = .automatic
    public var encodingMode: EncodingMode = .automatic
    public var wordRegexp = false
    public var lineRegexp = false
    public var noUnicode = false
    public var multiline = false
    public var multilineDotall = false
    public var crlf = false
    public var invertMatch = false
    public var stopOnNonmatch = false
    public var onlyMatching = false
    public var replacement: String?
    public var json = false
    public var stats = false
    public var includeZero = false
    public var maxCount: Int?
    public var maxColumns: Int?
    public var maxColumnsPreview = false
    public var maxDepth: Int?
    public var maxFileSize: UInt64?
    public var sortMode: SortMode?
    public var lineNumber = false
    public var noLineNumber = false
    public var column = false
    public var noColumn = false
    public var byteOffset = false
    public var heading: Bool?
    public var trim = false
    public var vimgrep = false
    public var colorMode: ColorMode = .automatic
    public var colorChanges: [ColorChange] = []
    public var hyperlinkFormat = HyperlinkFormat()
    public var hostnameBin: String?
    public var nullPathTerminator = false
    public var pathSeparator: Character?
    public var withFilename: Bool?
    public var hidden = false
    public var unrestrictedCount = 0
    public var noIgnore = false
    public var noIgnoreDot = false
    public var noIgnoreExclude = false
    public var noIgnoreFiles = false
    public var noIgnoreGlobal = false
    public var noIgnoreMessages = false
    public var noIgnoreParent = false
    public var noIgnoreVCS = false
    public var noRequireGit = false
    public var globCaseInsensitive = false
    public var ignoreFileCaseInsensitive = false
    public var ignoreFiles: [URL] = []
    public var ignoreFileDisplayPaths: [String] = []
    public var globPatterns: [String] = []
    public var caseInsensitiveGlobPatterns: [String] = []
    public var preprocessor: String?
    public var preGlobPatterns: [String] = []
    public var searchZip = false
    public var typeChanges: [TypeChange] = []
    public var followSymlinks = false
    public var oneFileSystem = false
    public var binaryMode: BinaryMode = .automatic
    public var quiet = false
    public var noMessages = false
    public var loggingMode: LoggingMode?
    public var useStdin = false
    public var beforeContext = 0
    public var afterContext = 0
    public var contextSeparator: String? = "--"
    public var fieldMatchSeparator = ":"
    public var fieldContextSeparator = "-"
    public var passthru = false
    public var nullData = false

    public init() {}

    public var effectiveRoots: [URL] {
        roots.isEmpty ? [URL(fileURLWithPath: ".")] : roots
    }

    public var effectiveIgnoreCase: Bool {
        ignoreCase || (smartCase && effectivePatterns.allSatisfy {
            $0.rangeOfCharacter(from: .uppercaseLetters) == nil
        })
    }

    public var wantsLineNumber: Bool {
        (lineNumber || column) && !noLineNumber
    }

    public var effectivePatterns: [String] {
        if !patterns.isEmpty {
            return patterns
        }
        return pattern.map { [$0] } ?? []
    }

    public var emitsRawBytes: Bool {
        encodingMode == .disabled || ((binaryMode == .asText || nullData) && encodingMode == .automatic)
    }

    public var disablesBinaryDetection: Bool {
        binaryMode == .asText || nullData
    }

    public mutating func appendPatternFileContents(_ contents: String) {
        let loadedPatterns = Self.patterns(fromPatternFileContents: contents)
        if patterns.isEmpty {
            pattern = loadedPatterns.first
        }
        patterns.append(contentsOf: loadedPatterns)
    }

    public static func patterns(fromPatternFileContents contents: String) -> [String] {
        guard !contents.isEmpty else {
            return []
        }
        var patterns = contents.components(separatedBy: "\n")
        if contents.utf8.last == UInt8(ascii: "\n") {
            patterns.removeLast()
        }
        return patterns.map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
    }
}

public enum CLIParseResult: Equatable {
    case run(RipgrepOptions)
    case shortHelp
    case longHelp
    case shortVersion
    case longVersion
    case pcre2Version
    case generate(GenerateMode)
    case error(String)
}

public enum RipgrepArgumentParser {
    public static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CLIParseResult {
        let finalArguments: [String]
        let startupWarnings: [String]
        let startupDiagnostics: [String]
        let shouldEmitConfigDebug = arguments.contains { $0 == "--debug" || $0 == "--trace" }
        if shouldLoadConfig(for: arguments) {
            let config = configArguments(environment: environment, emitDebug: shouldEmitConfigDebug)
            finalArguments = config.arguments + arguments
            startupWarnings = config.warnings
            startupDiagnostics = config.diagnostics
                + (shouldEmitConfigDebug && config.arguments.isEmpty ? [noConfigArgumentsDebugMessage] : [])
        } else {
            finalArguments = arguments
            startupWarnings = []
            startupDiagnostics = shouldEmitConfigDebug && arguments.contains("--no-config")
                ? [noConfigDebugMessage]
                : []
        }
        let parsed = parseFinal(finalArguments)
        if case .run(var options) = parsed {
            options.startupWarnings.append(contentsOf: startupWarnings)
            options.startupDiagnostics.append(contentsOf: startupDiagnostics)
            return .run(options)
        }
        return parsed
    }

    private static func parseFinal(_ arguments: [String]) -> CLIParseResult {
        var options = RipgrepOptions()
        var positionals: [String] = []
        var explicitPatterns: [String] = []
        var hasExplicitPatternSource = false
        var beforeContextWasSet = false
        var afterContextWasSet = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            switch argument {
            case "-h":
                return .shortHelp
            case "--help":
                return .longHelp
            case "-V":
                return .shortVersion
            case "--version":
                return .longVersion
            case "--pcre2-version":
                return .pcre2Version
            case "--no-config":
                break
            case "--debug":
                options.loggingMode = .debug
            case "--trace":
                options.loggingMode = .trace
            case "--generate":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--generate"))
                }
                guard let mode = GenerateMode(rawValue: arguments[index]) else {
                    return .error(unrecognizedChoice(flag: "--generate", value: arguments[index]))
                }
                options.generateMode = mode
                index += 1
            case let value where value.hasPrefix("--generate="):
                let raw = String(value.dropFirst("--generate=".count))
                guard let mode = GenerateMode(rawValue: raw) else {
                    return .error(unrecognizedChoice(flag: "--generate", value: raw))
                }
                options.generateMode = mode
            case "--files":
                options.mode = .files
                options.generateMode = nil
            case "--type-list":
                options.mode = .types
                options.generateMode = nil
            case "-i", "--ignore-case":
                options.ignoreCase = true
                options.smartCase = false
            case "-S", "--smart-case":
                options.ignoreCase = false
                options.smartCase = true
            case "-s", "--case-sensitive":
                options.ignoreCase = false
                options.smartCase = false
            case "-F", "--fixed-strings":
                options.fixedStrings = true
            case "--no-fixed-strings":
                options.fixedStrings = false
            case "--engine":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--engine"))
                }
                guard let mode = parseEngineMode(arguments[index]) else {
                    return .error(unrecognizedEngine(flag: "--engine", value: arguments[index]))
                }
                options.engineMode = mode
                index += 1
            case let value where value.hasPrefix("--engine="):
                let raw = String(value.dropFirst("--engine=".count))
                guard let mode = parseEngineMode(raw) else {
                    return .error(unrecognizedEngine(flag: "--engine", value: raw))
                }
                options.engineMode = mode
            case "-P", "--pcre2":
                options.engineMode = .pcre2
            case "--no-pcre2":
                options.engineMode = .default
            case "--auto-hybrid-regex":
                options.engineMode = .automatic
            case "--no-auto-hybrid-regex":
                options.engineMode = .default
            case "--dfa-size-limit":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--dfa-size-limit"))
                }
                guard let limit = parseHumanReadableSize(arguments[index]) else {
                    return .error(invalidSize(flag: "--dfa-size-limit", value: arguments[index]))
                }
                options.dfaSizeLimit = limit
                index += 1
            case let value where value.hasPrefix("--dfa-size-limit="):
                let raw = String(value.dropFirst("--dfa-size-limit=".count))
                guard let limit = parseHumanReadableSize(raw) else {
                    return .error(invalidSize(flag: "--dfa-size-limit", value: raw))
                }
                options.dfaSizeLimit = limit
            case "--regex-size-limit":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--regex-size-limit"))
                }
                guard let limit = parseHumanReadableSize(arguments[index]) else {
                    return .error(invalidSize(flag: "--regex-size-limit", value: arguments[index]))
                }
                options.regexSizeLimit = limit
                index += 1
            case let value where value.hasPrefix("--regex-size-limit="):
                let raw = String(value.dropFirst("--regex-size-limit=".count))
                guard let limit = parseHumanReadableSize(raw) else {
                    return .error(invalidSize(flag: "--regex-size-limit", value: raw))
                }
                options.regexSizeLimit = limit
            case "-j", "--threads":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                guard let threads = parseNonNegativeInt(arguments[index]) else {
                    return .error(invalidNumber(flag: argument, value: arguments[index]))
                }
                options.threadCount = threads == 0 ? nil : threads
                index += 1
            case let value where value.hasPrefix("--threads="):
                let raw = String(value.dropFirst("--threads=".count))
                guard let threads = parseNonNegativeInt(raw) else {
                    return .error(invalidNumber(flag: "--threads", value: raw))
                }
                options.threadCount = threads == 0 ? nil : threads
            case let value where value.hasPrefix("-j") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let threads = parseNonNegativeInt(raw) else {
                    return .error(invalidNumber(flag: "-j", value: raw))
                }
                options.threadCount = threads == 0 ? nil : threads
            case "--mmap":
                options.mmapMode = .always
            case "--no-mmap":
                options.mmapMode = .never
            case "--line-buffered":
                options.bufferMode = .line
            case "--no-line-buffered":
                options.bufferMode = .automatic
            case "--block-buffered":
                options.bufferMode = .block
            case "--no-block-buffered":
                options.bufferMode = .automatic
            case "-E", "--encoding":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                guard let mode = parseEncoding(arguments[index]) else {
                    return .error(unknownEncoding(arguments[index], flag: "--encoding"))
                }
                options.encodingMode = mode
                index += 1
            case let value where value.hasPrefix("--encoding="):
                let raw = String(value.dropFirst("--encoding=".count))
                guard let mode = parseEncoding(raw) else {
                    return .error(unknownEncoding(raw, flag: "--encoding"))
                }
                options.encodingMode = mode
            case let value where value.hasPrefix("-E") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let mode = parseEncoding(raw) else {
                    return .error(unknownEncoding(raw, flag: "-E"))
                }
                options.encodingMode = mode
            case "--no-encoding":
                options.encodingMode = .automatic
            case "-e", "--regexp":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                hasExplicitPatternSource = true
                explicitPatterns.append(arguments[index])
                index += 1
            case let value where value.hasPrefix("--regexp="):
                hasExplicitPatternSource = true
                explicitPatterns.append(String(value.dropFirst("--regexp=".count)))
            case let value where value.hasPrefix("-e") && value.count > 2:
                hasExplicitPatternSource = true
                explicitPatterns.append(String(value.dropFirst(2)))
            case "-f", "--file":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                hasExplicitPatternSource = true
                let path = arguments[index]
                if path == "-" {
                    options.patternFileStdin = true
                    index += 1
                    break
                }
                switch readPatterns(from: path) {
                case .patterns(let patterns):
                    explicitPatterns.append(contentsOf: patterns)
                case .error(let message):
                    return .error(message)
                }
                index += 1
            case let value where value.hasPrefix("--file="):
                hasExplicitPatternSource = true
                let path = String(value.dropFirst("--file=".count))
                if path == "-" {
                    options.patternFileStdin = true
                    break
                }
                switch readPatterns(from: path) {
                case .patterns(let patterns):
                    explicitPatterns.append(contentsOf: patterns)
                case .error(let message):
                    return .error(message)
                }
            case let value where value.hasPrefix("-f") && value.count > 2:
                hasExplicitPatternSource = true
                let path = String(value.dropFirst(2))
                if path == "-" {
                    options.patternFileStdin = true
                    break
                }
                switch readPatterns(from: path) {
                case .patterns(let patterns):
                    explicitPatterns.append(contentsOf: patterns)
                case .error(let message):
                    return .error(message)
                }
            case "-w", "--word-regexp":
                options.wordRegexp = true
                options.lineRegexp = false
            case "-x", "--line-regexp":
                options.lineRegexp = true
                options.wordRegexp = false
            case "--no-unicode", "--no-pcre2-unicode":
                options.noUnicode = true
            case "--unicode", "--pcre2-unicode":
                options.noUnicode = false
            case "-U", "--multiline":
                options.multiline = true
                options.stopOnNonmatch = false
            case "--no-multiline":
                options.multiline = false
            case "--multiline-dotall":
                options.multilineDotall = true
            case "--no-multiline-dotall":
                options.multilineDotall = false
            case "--crlf":
                options.crlf = true
                options.nullData = false
            case "--no-crlf":
                options.crlf = false
            case "-v", "--invert-match":
                options.invertMatch = true
            case "--no-invert-match":
                options.invertMatch = false
            case "--stop-on-nonmatch":
                options.stopOnNonmatch = true
                options.multiline = false
            case "-o", "--only-matching":
                options.onlyMatching = true
            case "-r", "--replace":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                options.replacement = arguments[index]
                index += 1
            case let value where value.hasPrefix("--replace="):
                options.replacement = String(value.dropFirst("--replace=".count))
            case let value where value.hasPrefix("-r") && value.count > 2:
                options.replacement = String(value.dropFirst(2))
            case let value where unrestrictedRepeatError(inCluster: value) != nil:
                return .error(unrestrictedRepeatError(inCluster: value)!)
            case let value where invalidShortFlag(inCluster: value) != nil:
                return .error(unrecognizedFlag("-\(invalidShortFlag(inCluster: value)!)"))
            case let value where isShortFlagCluster(value):
                if let result = shortClusterControlResult(value) {
                    return result
                }
                if let message = applyShortFlagCluster(
                    value,
                    options: &options,
                    explicitPatterns: &explicitPatterns,
                    hasExplicitPatternSource: &hasExplicitPatternSource,
                    arguments: arguments,
                    index: &index
                ) {
                    return .error(message)
                }
            case "-n", "--line-number":
                options.lineNumber = true
                options.noLineNumber = false
            case "-b", "--byte-offset":
                options.byteOffset = true
            case "--no-byte-offset":
                options.byteOffset = false
            case "--json":
                options.mode = .search
                options.json = true
                options.generateMode = nil
            case "--no-json":
                options.json = false
                options.generateMode = nil
            case "-p", "--pretty":
                options.colorMode = .always
                options.heading = true
                options.lineNumber = true
                options.noLineNumber = false
            case "--color":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--color"))
                }
                guard let mode = parseColorMode(arguments[index]) else {
                    return .error(unrecognizedChoice(flag: "--color", value: arguments[index]))
                }
                options.colorMode = mode
                index += 1
            case let value where value.hasPrefix("--color="):
                let raw = String(value.dropFirst("--color=".count))
                guard let mode = parseColorMode(raw) else {
                    return .error(unrecognizedChoice(flag: "--color", value: raw))
                }
                options.colorMode = mode
            case "--colors":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--colors"))
                }
                let parsedColorChange = parseColorChange(arguments[index])
                if let change = parsedColorChange.change {
                    options.colorChanges.append(change)
                } else if let error = parsedColorChange.error {
                    return .error(error)
                }
                index += 1
            case let value where value.hasPrefix("--colors="):
                let raw = String(value.dropFirst("--colors=".count))
                let parsedColorChange = parseColorChange(raw)
                if let change = parsedColorChange.change {
                    options.colorChanges.append(change)
                } else if let error = parsedColorChange.error {
                    return .error(error)
                }
            case "--hyperlink-format":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--hyperlink-format"))
                }
                do {
                    options.hyperlinkFormat = try parseHyperlinkFormat(arguments[index])
                } catch {
                    return .error("error parsing flag --hyperlink-format: invalid hyperlink format: \(error.localizedDescription)")
                }
                index += 1
            case let value where value.hasPrefix("--hyperlink-format="):
                let raw = String(value.dropFirst("--hyperlink-format=".count))
                do {
                    options.hyperlinkFormat = try parseHyperlinkFormat(raw)
                } catch {
                    return .error("error parsing flag --hyperlink-format: invalid hyperlink format: \(error.localizedDescription)")
                }
            case "--hostname-bin":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--hostname-bin"))
                }
                options.hostnameBin = arguments[index].isEmpty ? nil : arguments[index]
                index += 1
            case let value where value.hasPrefix("--hostname-bin="):
                let raw = String(value.dropFirst("--hostname-bin=".count))
                options.hostnameBin = raw.isEmpty ? nil : raw
            case "--stats":
                options.stats = true
            case "--no-stats":
                options.stats = false
            case "--include-zero":
                options.includeZero = true
            case "--no-include-zero":
                options.includeZero = false
            case "-M", "--max-columns":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                guard let columns = parseNonNegativeInt(arguments[index]) else {
                    return .error(invalidNumber(flag: argument, value: arguments[index]))
                }
                options.maxColumns = columns == 0 ? nil : columns
                index += 1
            case let value where value.hasPrefix("--max-columns="):
                let raw = String(value.dropFirst("--max-columns=".count))
                guard let columns = parseNonNegativeInt(raw) else {
                    return .error(invalidNumber(flag: "--max-columns", value: raw))
                }
                options.maxColumns = columns == 0 ? nil : columns
            case let value where value.hasPrefix("-M") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let columns = parseNonNegativeInt(raw) else {
                    return .error(invalidNumber(flag: "-M", value: raw))
                }
                options.maxColumns = columns == 0 ? nil : columns
            case "--max-columns-preview":
                options.maxColumnsPreview = true
            case "--no-max-columns-preview":
                options.maxColumnsPreview = false
            case "--max-filesize":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--max-filesize"))
                }
                guard let size = parseHumanReadableSize(arguments[index]) else {
                    return .error(invalidSize(flag: "--max-filesize", value: arguments[index]))
                }
                options.maxFileSize = size
                index += 1
            case let value where value.hasPrefix("--max-filesize="):
                let raw = String(value.dropFirst("--max-filesize=".count))
                guard let size = parseHumanReadableSize(raw) else {
                    return .error(invalidSize(flag: "--max-filesize", value: raw))
                }
                options.maxFileSize = size
            case "-N", "--no-line-number":
                options.lineNumber = false
                options.noLineNumber = true
            case "--column":
                options.column = true
                options.noColumn = false
            case "--no-column":
                options.column = false
                options.noColumn = true
            case "--heading":
                options.heading = true
            case "--no-heading":
                options.heading = false
            case "--trim":
                options.trim = true
            case "--no-trim":
                options.trim = false
            case "--vimgrep":
                options.vimgrep = true
                if options.colorMode == .automatic {
                    options.colorMode = .never
                }
            case "-0", "--null":
                options.nullPathTerminator = true
            case "--path-separator":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--path-separator"))
                }
                guard let parsed = parsePathSeparator(arguments[index]) else {
                    return .error(invalidPathSeparator(arguments[index]))
                }
                switch parsed {
                case .automatic:
                    options.pathSeparator = nil
                case .separator(let separator):
                    options.pathSeparator = separator
                }
                index += 1
            case let value where value.hasPrefix("--path-separator="):
                let raw = String(value.dropFirst("--path-separator=".count))
                guard let parsed = parsePathSeparator(raw) else {
                    return .error(invalidPathSeparator(raw))
                }
                switch parsed {
                case .automatic:
                    options.pathSeparator = nil
                case .separator(let separator):
                    options.pathSeparator = separator
                }
            case "--sort":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--sort"))
                }
                if arguments[index] == "none" {
                    options.sortMode = nil
                } else {
                    guard let sort = parseSort(arguments[index], reverse: false) else {
                        return .error(unrecognizedChoice(flag: "--sort", value: arguments[index]))
                    }
                    options.sortMode = sort
                }
                index += 1
            case let value where value.hasPrefix("--sort="):
                let raw = String(value.dropFirst("--sort=".count))
                if raw == "none" {
                    options.sortMode = nil
                } else {
                    guard let sort = parseSort(raw, reverse: false) else {
                        return .error(unrecognizedChoice(flag: "--sort", value: raw))
                    }
                    options.sortMode = sort
                }
            case "--sortr":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--sortr"))
                }
                if arguments[index] == "none" {
                    options.sortMode = nil
                } else {
                    guard let sort = parseSort(arguments[index], reverse: true) else {
                        return .error(unrecognizedChoice(flag: "--sortr", value: arguments[index]))
                    }
                    options.sortMode = sort
                }
                index += 1
            case let value where value.hasPrefix("--sortr="):
                let raw = String(value.dropFirst("--sortr=".count))
                if raw == "none" {
                    options.sortMode = nil
                } else {
                    guard let sort = parseSort(raw, reverse: true) else {
                        return .error(unrecognizedChoice(flag: "--sortr", value: raw))
                    }
                    options.sortMode = sort
                }
            case "--sort-files":
                options.sortMode = SortMode(kind: .path, reverse: false)
            case "--no-sort-files":
                options.sortMode = nil
            case "-H", "--with-filename":
                options.withFilename = true
            case "-I", "--no-filename":
                options.withFilename = false
            case "-.", "--hidden":
                options.hidden = true
            case "--no-hidden":
                options.hidden = false
            case "--no-ignore":
                options.noIgnore = true
                options.noIgnoreDot = true
                options.noIgnoreExclude = true
                options.noIgnoreParent = true
                options.noIgnoreGlobal = true
                options.noIgnoreVCS = true
            case "--ignore":
                options.noIgnore = false
                options.noIgnoreDot = false
                options.noIgnoreExclude = false
                options.noIgnoreParent = false
                options.noIgnoreGlobal = false
                options.noIgnoreVCS = false
            case "--no-ignore-dot":
                options.noIgnoreDot = true
            case "--ignore-dot":
                options.noIgnoreDot = false
            case "--no-ignore-exclude":
                options.noIgnoreExclude = true
            case "--ignore-exclude":
                options.noIgnoreExclude = false
            case "--no-ignore-global":
                options.noIgnoreGlobal = true
            case "--ignore-global":
                options.noIgnoreGlobal = false
            case "--no-ignore-messages":
                options.noIgnoreMessages = true
            case "--ignore-messages":
                options.noIgnoreMessages = false
            case "--no-ignore-parent":
                options.noIgnoreParent = true
            case "--ignore-parent":
                options.noIgnoreParent = false
            case "--no-ignore-files":
                options.noIgnoreFiles = true
            case "--ignore-files":
                options.noIgnoreFiles = false
            case "--no-ignore-vcs":
                options.noIgnoreVCS = true
            case "--ignore-vcs":
                options.noIgnoreVCS = false
            case "--no-require-git":
                options.noRequireGit = true
            case "--require-git":
                options.noRequireGit = false
            case "--glob-case-insensitive":
                options.globCaseInsensitive = true
            case "--no-glob-case-insensitive":
                options.globCaseInsensitive = false
            case "--ignore-file-case-insensitive":
                options.ignoreFileCaseInsensitive = true
            case "--no-ignore-file-case-insensitive":
                options.ignoreFileCaseInsensitive = false
            case "--ignore-file":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--ignore-file"))
                }
                options.ignoreFiles.append(URL(fileURLWithPath: arguments[index]))
                options.ignoreFileDisplayPaths.append(arguments[index])
                index += 1
            case let value where value.hasPrefix("--ignore-file="):
                let raw = String(value.dropFirst("--ignore-file=".count))
                options.ignoreFiles.append(URL(fileURLWithPath: raw))
                options.ignoreFileDisplayPaths.append(raw)
            case "--pre":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--pre"))
                }
                options.preprocessor = arguments[index].isEmpty ? nil : arguments[index]
                if options.preprocessor != nil {
                    options.searchZip = false
                }
                index += 1
            case let value where value.hasPrefix("--pre="):
                let command = String(value.dropFirst("--pre=".count))
                options.preprocessor = command.isEmpty ? nil : command
                if options.preprocessor != nil {
                    options.searchZip = false
                }
            case "--no-pre":
                options.preprocessor = nil
            case "--pre-glob":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--pre-glob"))
                }
                guard let glob = parseStrictGlob(arguments[index]) else {
                    return .error(globParseError(arguments[index]))
                }
                options.preGlobPatterns.append(glob)
                index += 1
            case let value where value.hasPrefix("--pre-glob="):
                let glob = String(value.dropFirst("--pre-glob=".count))
                guard let glob = parseStrictGlob(glob) else {
                    return .error(globParseError(glob))
                }
                options.preGlobPatterns.append(glob)
            case "-g", "--glob":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                guard let glob = parseStrictGlob(arguments[index]) else {
                    return .error(globParseError(arguments[index]))
                }
                options.globPatterns.append(glob)
                index += 1
            case let value where value.hasPrefix("--glob="):
                let glob = String(value.dropFirst("--glob=".count))
                guard let glob = parseStrictGlob(glob) else {
                    return .error(globParseError(glob))
                }
                options.globPatterns.append(glob)
            case let value where value.hasPrefix("-g") && value.count > 2:
                let glob = String(value.dropFirst(2))
                guard let glob = parseStrictGlob(glob) else {
                    return .error(globParseError(glob))
                }
                options.globPatterns.append(glob)
            case "--iglob":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--iglob"))
                }
                guard let glob = parseStrictGlob(arguments[index]) else {
                    return .error(globParseError(arguments[index]))
                }
                options.caseInsensitiveGlobPatterns.append(glob)
                index += 1
            case let value where value.hasPrefix("--iglob="):
                let glob = String(value.dropFirst("--iglob=".count))
                guard let glob = parseStrictGlob(glob) else {
                    return .error(globParseError(glob))
                }
                options.caseInsensitiveGlobPatterns.append(glob)
            case "-t", "--type":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                options.typeChanges.append(.select(arguments[index]))
                index += 1
            case let value where value.hasPrefix("--type="):
                options.typeChanges.append(.select(String(value.dropFirst("--type=".count))))
            case let value where value.hasPrefix("-t") && value.count > 2:
                options.typeChanges.append(.select(String(value.dropFirst(2))))
            case "-T", "--type-not":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                options.typeChanges.append(.negate(arguments[index]))
                index += 1
            case let value where value.hasPrefix("--type-not="):
                options.typeChanges.append(.negate(String(value.dropFirst("--type-not=".count))))
            case let value where value.hasPrefix("-T") && value.count > 2:
                options.typeChanges.append(.negate(String(value.dropFirst(2))))
            case "--type-add":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--type-add"))
                }
                options.typeChanges.append(.add(arguments[index]))
                index += 1
            case let value where value.hasPrefix("--type-add="):
                options.typeChanges.append(.add(String(value.dropFirst("--type-add=".count))))
            case "--type-clear":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--type-clear"))
                }
                options.typeChanges.append(.clear(arguments[index]))
                index += 1
            case let value where value.hasPrefix("--type-clear="):
                options.typeChanges.append(.clear(String(value.dropFirst("--type-clear=".count))))
            case "-L", "--follow":
                options.followSymlinks = true
            case "--no-follow":
                options.followSymlinks = false
            case "--one-file-system":
                options.oneFileSystem = true
            case "--no-one-file-system":
                options.oneFileSystem = false
            case "-z", "--search-zip":
                options.searchZip = true
                options.preprocessor = nil
            case "--no-search-zip":
                options.searchZip = false
            case "--binary":
                options.binaryMode = .searchAndSuppress
            case "--no-binary":
                options.binaryMode = .automatic
            case "-a", "--text":
                options.binaryMode = .asText
            case "--no-text":
                options.binaryMode = .automatic
            case "-q", "--quiet":
                options.quiet = true
            case "--no-messages":
                options.noMessages = true
            case "--messages":
                options.noMessages = false
            case "--null-data":
                options.nullData = true
                options.crlf = false
            case "-u", "--unrestricted":
                if let error = applyUnrestricted(to: &options) {
                    return .error(error)
                }
            case "-uu":
                if let error = applyUnrestricted(repeatCount: 2, to: &options) {
                    return .error(error)
                }
            case "-uuu":
                if let error = applyUnrestricted(repeatCount: 3, to: &options) {
                    return .error(error)
                }
            case "--passthru", "--passthrough":
                options.passthru = true
                options.beforeContext = 0
                options.afterContext = 0
            case "-m", "--max-count":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                guard let count = parseNonNegativeInt(arguments[index]) else {
                    return .error(invalidNumber(flag: argument, value: arguments[index]))
                }
                options.maxCount = count
                index += 1
            case let value where value.hasPrefix("--max-count="):
                let raw = String(value.dropFirst("--max-count=".count))
                guard let count = parseNonNegativeInt(raw) else {
                    return .error(invalidNumber(flag: "--max-count", value: raw))
                }
                options.maxCount = count
            case let value where value.hasPrefix("-m") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let count = parseNonNegativeInt(raw) else {
                    return .error(invalidNumber(flag: "-m", value: raw))
                }
                options.maxCount = count
            case "-d", "--max-depth", "--maxdepth":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                guard let depth = parseNonNegativeInt(arguments[index]) else {
                    return .error(invalidNumber(flag: argument, value: arguments[index]))
                }
                options.maxDepth = depth
                index += 1
            case let value where value.hasPrefix("--max-depth="):
                let raw = String(value.dropFirst("--max-depth=".count))
                guard let depth = parseNonNegativeInt(raw) else {
                    return .error(invalidNumber(flag: "--max-depth", value: raw))
                }
                options.maxDepth = depth
            case let value where value.hasPrefix("--maxdepth="):
                let raw = String(value.dropFirst("--maxdepth=".count))
                guard let depth = parseNonNegativeInt(raw) else {
                    return .error(invalidNumber(flag: "--maxdepth", value: raw))
                }
                options.maxDepth = depth
            case let value where value.hasPrefix("-d") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let depth = parseNonNegativeInt(raw) else {
                    return .error(invalidNumber(flag: "-d", value: raw))
                }
                options.maxDepth = depth
            case "-A", "--after-context":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                guard let count = parseContextCount(arguments[index], flag: argument) else {
                    return .error(invalidNumber(flag: argument, value: arguments[index]))
                }
                options.afterContext = count
                afterContextWasSet = true
                options.passthru = false
                index += 1
            case let value where value.hasPrefix("--after-context="):
                let raw = String(value.dropFirst("--after-context=".count))
                guard let count = parseContextCount(raw, flag: "--after-context") else {
                    return .error(invalidNumber(flag: "--after-context", value: raw))
                }
                options.afterContext = count
                afterContextWasSet = true
                options.passthru = false
            case let value where value.hasPrefix("-A") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let count = parseContextCount(raw, flag: "-A") else {
                    return .error(invalidNumber(flag: "-A", value: raw))
                }
                options.afterContext = count
                afterContextWasSet = true
                options.passthru = false
            case "-B", "--before-context":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                guard let count = parseContextCount(arguments[index], flag: argument) else {
                    return .error(invalidNumber(flag: argument, value: arguments[index]))
                }
                options.beforeContext = count
                beforeContextWasSet = true
                options.passthru = false
                index += 1
            case let value where value.hasPrefix("--before-context="):
                let raw = String(value.dropFirst("--before-context=".count))
                guard let count = parseContextCount(raw, flag: "--before-context") else {
                    return .error(invalidNumber(flag: "--before-context", value: raw))
                }
                options.beforeContext = count
                beforeContextWasSet = true
                options.passthru = false
            case let value where value.hasPrefix("-B") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let count = parseContextCount(raw, flag: "-B") else {
                    return .error(invalidNumber(flag: "-B", value: raw))
                }
                options.beforeContext = count
                beforeContextWasSet = true
                options.passthru = false
            case "-C", "--context":
                guard index < arguments.count else {
                    return .error(missingValue(flag: argument))
                }
                guard let count = parseContextCount(arguments[index], flag: argument) else {
                    return .error(invalidNumber(flag: argument, value: arguments[index]))
                }
                if !beforeContextWasSet {
                    options.beforeContext = count
                }
                if !afterContextWasSet {
                    options.afterContext = count
                }
                options.passthru = false
                index += 1
            case let value where value.hasPrefix("--context="):
                let raw = String(value.dropFirst("--context=".count))
                guard let count = parseContextCount(raw, flag: "--context") else {
                    return .error(invalidNumber(flag: "--context", value: raw))
                }
                if !beforeContextWasSet {
                    options.beforeContext = count
                }
                if !afterContextWasSet {
                    options.afterContext = count
                }
                options.passthru = false
            case let value where value.hasPrefix("-C") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let count = parseContextCount(raw, flag: "-C") else {
                    return .error(invalidNumber(flag: "-C", value: raw))
                }
                if !beforeContextWasSet {
                    options.beforeContext = count
                }
                if !afterContextWasSet {
                    options.afterContext = count
                }
                options.passthru = false
            case "--context-separator":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--context-separator"))
                }
                options.contextSeparator = parseEscapedSeparator(arguments[index])
                index += 1
            case let value where value.hasPrefix("--context-separator="):
                options.contextSeparator = parseEscapedSeparator(String(value.dropFirst("--context-separator=".count)))
            case "--no-context-separator":
                options.contextSeparator = nil
            case "--field-match-separator":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--field-match-separator"))
                }
                options.fieldMatchSeparator = parseEscapedSeparator(arguments[index])
                index += 1
            case let value where value.hasPrefix("--field-match-separator="):
                options.fieldMatchSeparator = parseEscapedSeparator(String(value.dropFirst("--field-match-separator=".count)))
            case "--field-context-separator":
                guard index < arguments.count else {
                    return .error(missingValue(flag: "--field-context-separator"))
                }
                options.fieldContextSeparator = parseEscapedSeparator(arguments[index])
                index += 1
            case let value where value.hasPrefix("--field-context-separator="):
                options.fieldContextSeparator = parseEscapedSeparator(String(value.dropFirst("--field-context-separator=".count)))
            case "-c", "--count":
                options.mode = .search
                options.printMode = .count
                options.json = false
                options.generateMode = nil
            case "--count-matches":
                options.mode = .search
                options.printMode = .countMatches
                options.json = false
                options.generateMode = nil
            case "-l", "--files-with-matches":
                options.mode = .search
                options.printMode = .filesWithMatches
                options.json = false
                options.generateMode = nil
            case "--files-without-match":
                options.mode = .search
                options.printMode = .filesWithoutMatch
                options.json = false
                options.generateMode = nil
            case "--":
                positionals.append(contentsOf: arguments[index...])
                index = arguments.count
            case "-":
                options.useStdin = true
                positionals.append(argument)
            default:
                if let unexpectedArgumentError = unexpectedArgumentForNoValueFlag(argument) {
                    return .error(unexpectedArgumentError)
                }
                if argument.hasPrefix("-") {
                    return .error(unrecognizedFlag(argument))
                }
                positionals.append(argument)
            }
        }

        if let generateMode = options.generateMode {
            return .generate(generateMode)
        }

        if options.mode == .search {
            if explicitPatterns.isEmpty && !options.patternFileStdin && !hasExplicitPatternSource {
                guard let pattern = positionals.first else {
                    return .error("ripgrep requires at least one pattern to execute a search")
                }
                options.pattern = pattern
                options.patterns = [pattern]
                let roots = Array(positionals.dropFirst())
                options.rootPathArguments = roots
                options.roots = roots.map { URL(fileURLWithPath: $0) }
            } else {
                options.pattern = explicitPatterns.first
                options.patterns = explicitPatterns
                options.rootPathArguments = positionals
                options.roots = positionals.map { URL(fileURLWithPath: $0) }
            }
            if options.roots.isEmpty && !options.useStdin {
                options.roots = [URL(fileURLWithPath: ".")]
                options.rootPathArguments = []
            }
        } else if options.mode == .files {
            options.rootPathArguments = positionals
            options.roots = positionals.map { URL(fileURLWithPath: $0) }
            if options.roots.isEmpty {
                options.roots = [URL(fileURLWithPath: ".")]
                options.rootPathArguments = []
            }
        } else {
            options.roots = []
            options.rootPathArguments = []
        }

        return .run(options)
    }

    public static func usage(version: String = RipgrepCLI.version) -> String {
        """
        ripgrep \(version)

        USAGE:
          ripgrep [OPTIONS] <pattern> [path ...]
          ripgrep [OPTIONS] --files [path ...]

        OPTIONS:
          -i, --ignore-case          Search case insensitively
          -S, --smart-case           Search case insensitively if the pattern is lowercase
          -s, --case-sensitive       Search case sensitively
          -F, --fixed-strings        Treat the pattern as a literal string
              --no-fixed-strings     Treat the pattern as a regular expression
              --engine ENGINE        Use regex engine: default, pcre2 or auto
          -P, --pcre2                Enable PCRE2-style regex matching
              --no-pcre2             Disable PCRE2-style regex matching
              --auto-hybrid-regex    Use PCRE2 automatically when needed
              --no-auto-hybrid-regex Disable automatic PCRE2 fallback
              --dfa-size-limit NUM   Set the regex DFA size limit
              --regex-size-limit NUM Set the compiled regex size limit
          -j, --threads NUM          Set the approximate thread count
              --mmap                 Search with memory maps when possible
              --no-mmap              Disable memory maps
              --line-buffered        Force line buffering
              --no-line-buffered     Disable forced line buffering
              --block-buffered       Force block buffering
              --no-block-buffered    Disable forced block buffering
          -E, --encoding ENCODING    Specify text encoding: auto, none, utf-8, utf-16/le/be
              --no-encoding          Reset to automatic encoding detection
          -e, --regexp PATTERN       Add a pattern to search for
          -f, --file PATTERNFILE     Read patterns from a file
          -w, --word-regexp          Only show matches surrounded by word boundaries
          -x, --line-regexp          Only show matches spanning an entire line
              --no-unicode           Disable Unicode mode
              --unicode              Enable Unicode mode
              --pcre2-unicode        Enable Unicode mode for PCRE2 compatibility
              --no-pcre2-unicode     Disable Unicode mode for PCRE2 compatibility
          -U, --multiline            Enable matching across line terminators
              --no-multiline         Disable matching across line terminators
              --multiline-dotall     Make '.' match line terminators in multiline mode
              --no-multiline-dotall  Make '.' stop before line terminators
              --crlf                 Treat CRLF as a line terminator for anchors
              --no-crlf              Disable CRLF anchor mode
          -v, --invert-match         Show non-matching lines
              --no-invert-match      Show matching lines
              --stop-on-nonmatch     Stop after a non-match following a match
          -o, --only-matching        Print only the matched text
          -r, --replace TEXT         Replace matches with the given text
              --json                 Show search results in JSON Lines format
              --no-json              Disable JSON Lines output
              --stats                Print statistics about the search
              --no-stats             Disable statistics output
              --include-zero         Print count output for files with zero matches
              --no-include-zero      Suppress count output for zero-match files
          -m, --max-count NUM        Limit matching lines per file
          -M, --max-columns NUM      Omit matching lines at least NUM bytes long
              --max-columns-preview  Show a preview for omitted long lines
              --no-max-columns-preview Disable previews for omitted long lines
              --max-filesize NUM     Ignore non-explicit files larger than NUM
          -d, --max-depth, --maxdepth NUM Descend at most NUM directory levels
          -n, --line-number          Show line numbers
          -N, --no-line-number       Suppress line numbers
              --column               Show the first match column
              --no-column            Suppress column numbers
          -b, --byte-offset          Show the 0-based byte offset
              --no-byte-offset       Suppress byte offsets
          -p, --pretty               Alias for colors, headings and line numbers
              --color WHEN           Use color: never, auto, always or ansi
              --colors COLOR_SPEC    Configure output color settings
              --hyperlink-format FMT Format file path hyperlinks
              --hostname-bin COMMAND Run a program to get the hostname for hyperlinks
              --heading              Group matches by file
              --no-heading           Print each match with its path
              --trim                 Trim leading ASCII whitespace from printed lines
              --no-trim              Preserve leading whitespace
              --vimgrep              Print vim-compatible file:line:column matches
          -0, --null                 Print NUL after file paths
              --path-separator SEP   Set the path separator for printed paths
              --sort SORTBY          Sort results by path, modified, accessed or created
              --sortr SORTBY         Sort results in reverse order
              --sort-files           Sort results by path
              --no-sort-files        Disable path sorting
          -H, --with-filename        Show file names
          -I, --no-filename          Suppress file names
          -c, --count                Show match counts per file
              --count-matches        Show individual match counts per file
              -l, --files-with-matches   Show only paths with matches
              --files-without-match  Show only paths without matches
              --files                Print files that would be searched
              --hidden               Search hidden files and directories
              --no-hidden            Do not search hidden files and directories
          -u, --unrestricted         Reduce filtering; repeat to include hidden/binary files
              --ignore               Respect ignore files
              --no-ignore            Do not respect ignore files
              --ignore-dot           Respect .ignore and .rgignore files
              --no-ignore-dot        Do not respect .ignore or .rgignore files
              --ignore-exclude       Respect .git/info/exclude
              --no-ignore-exclude    Do not respect .git/info/exclude
              --ignore-files         Respect --ignore-file arguments
              --no-ignore-files      Do not respect --ignore-file arguments
              --ignore-global        Respect global git ignore files
              --no-ignore-global     Do not respect global git ignore files
              --ignore-messages      Show ignore file parse messages
              --no-ignore-messages   Suppress ignore file parse messages
              --ignore-parent        Respect ignore files in parent directories
              --no-ignore-parent     Do not respect ignore files in parent directories
              --ignore-vcs           Respect VCS ignore files
              --no-ignore-vcs        Do not respect VCS ignore files
              --require-git          Require a git repository for VCS ignore files
              --no-require-git       Use VCS ignore files outside repositories
              --glob-case-insensitive Process -g/--glob patterns case insensitively
              --no-glob-case-insensitive Process -g/--glob patterns case sensitively
              --ignore-file-case-insensitive Process ignore files case insensitively
              --no-ignore-file-case-insensitive Process ignore files case sensitively
              --ignore-file PATH     Add a custom ignore file
              --pre COMMAND          Search stdout of COMMAND for each path
              --no-pre               Disable preprocessing
              --pre-glob GLOB        Include or exclude files from preprocessing
          -g, --glob GLOB            Include or exclude paths with an override glob
              --iglob GLOB           Include/exclude paths case insensitively
          -t, --type TYPE            Only search files matching TYPE
          -T, --type-not TYPE        Do not search files matching TYPE
              --type-add TYPESPEC    Add a new glob for a file type
              --type-clear TYPE      Clear globs for a file type
              --type-list            Show all supported file types
          -A, --after-context NUM    Show NUM lines after each match
          -B, --before-context NUM   Show NUM lines before each match
          -C, --context NUM          Show NUM lines before and after each match
              --context-separator S  Set the separator for context chunks
              --no-context-separator Do not print context separators
              --field-match-separator S   Set field separator for matching lines
              --field-context-separator S Set field separator for context lines
              --passthru             Print both matching and non-matching lines
              --passthrough          Alias for --passthru
          -L, --follow               Follow symbolic links
              --no-follow            Do not follow symbolic links
              --one-file-system      Skip directories on other file systems
              --no-one-file-system   Traverse directories on other file systems
          -z, --search-zip           Search compressed files
              --no-search-zip        Do not search compressed files
              --binary               Search binary files but suppress binary output
              --no-binary            Disable binary search mode
          -a, --text                 Search binary files as text
              --no-text              Disable text mode
              --null-data            Use NUL as a line terminator
          -q, --quiet                Do not print matches
              --debug                Show debug messages
              --trace                Show trace messages
              --generate KIND        Generate man pages and completion scripts
              --line-buffered        Force line buffering
              --block-buffered       Force block buffering
              --no-messages          Suppress file open/read error messages
              --no-config            Do not read RIPGREP_CONFIG_PATH
          -h, --help                 Print help
              --version              Print version
              --pcre2-version        Print the detected PCRE2 version
        """
    }

    private static func readPatterns(from path: String) -> PatternFileResult {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return .error("\(path):Is a directory (os error 21)")
        }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let data = handle.readDataToEndOfFile()
            let contents = String(decoding: data, as: UTF8.self)
            return .patterns(RipgrepOptions.patterns(fromPatternFileContents: contents))
        } catch let error as NSError where isNoSuchFile(error) {
            return .error("\(path): No such file or directory (os error 2)")
        } catch {
            return .error("error: failed to read pattern file '\(path)': \(error)")
        }
    }

    private static func isNoSuchFile(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoSuchFile.rawValue {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isNoSuchFile(underlying)
        }
        return false
    }

    private static func isShortFlagCluster(_ argument: String) -> Bool {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 2 else {
            return false
        }
        let flags = argument.dropFirst()
        let standaloneFlags = Set("iSsFPwxUvonbpNHILzaqclhVu")
        for (offset, flag) in flags.enumerated() {
            if flag == "f" {
                return offset == flags.count - 1
            }
            if flag == "r" {
                return true
            }
            if !standaloneFlags.contains(flag) {
                return false
            }
        }
        return true
    }

    private static func invalidShortFlag(inCluster argument: String) -> Character? {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 2 else {
            return nil
        }
        let flags = argument.dropFirst()
        guard let first = flags.first, !Set("efgEdABCmMjTt").contains(first) else {
            return nil
        }
        let standaloneFlags = Set("iSsFPwxUvonbpNHILzaqclhVu")
        for flag in flags {
            if flag == "f" || flag == "r" {
                return nil
            }
            if !standaloneFlags.contains(flag) {
                return flag
            }
        }
        return nil
    }

    private static func unrestrictedRepeatError(inCluster argument: String) -> String? {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 2 else {
            return nil
        }
        let unrestrictedCount = argument.dropFirst().filter { $0 == "u" }.count
        guard unrestrictedCount > 3 else {
            return nil
        }
        return "error parsing flag -u: flag can only be repeated up to 3 times"
    }

    private static func shortClusterControlResult(_ argument: String) -> CLIParseResult? {
        for flag in argument.dropFirst() {
            switch flag {
            case "h":
                return .shortHelp
            case "V":
                return .shortVersion
            default:
                continue
            }
        }
        return nil
    }

    private static func applyShortFlagCluster(
        _ argument: String,
        options: inout RipgrepOptions,
        explicitPatterns: inout [String],
        hasExplicitPatternSource: inout Bool,
        arguments: [String],
        index: inout Int
    ) -> String? {
        let flags = Array(argument.dropFirst())
        for (offset, flag) in flags.enumerated() {
            switch flag {
            case "i":
                options.ignoreCase = true
                options.smartCase = false
            case "S":
                options.ignoreCase = false
                options.smartCase = true
            case "s":
                options.ignoreCase = false
                options.smartCase = false
            case "F":
                options.fixedStrings = true
            case "P":
                options.engineMode = .pcre2
            case "w":
                options.wordRegexp = true
                options.lineRegexp = false
            case "x":
                options.lineRegexp = true
                options.wordRegexp = false
            case "U":
                options.multiline = true
                options.stopOnNonmatch = false
            case "v":
                options.invertMatch = true
            case "o":
                options.onlyMatching = true
            case "n":
                options.lineNumber = true
                options.noLineNumber = false
            case "b":
                options.byteOffset = true
            case "p":
                options.colorMode = .always
                options.heading = true
                options.lineNumber = true
            case "N":
                options.lineNumber = false
                options.noLineNumber = true
            case "H":
                options.withFilename = true
            case "I":
                options.withFilename = false
            case "L":
                options.followSymlinks = true
            case "z":
                options.searchZip = true
            case "a":
                options.binaryMode = .asText
            case "u":
                if let error = applyUnrestricted(to: &options) {
                    return error
                }
            case "q":
                options.quiet = true
            case "c":
                options.mode = .search
                options.printMode = .count
                options.generateMode = nil
            case "l":
                options.mode = .search
                options.printMode = .filesWithMatches
                options.generateMode = nil
            case "r":
                let nextOffset = offset + 1
                if nextOffset < flags.count {
                    options.replacement = String(flags[nextOffset...])
                    return nil
                }
                guard index < arguments.count else {
                    return missingValue(flag: "-r")
                }
                options.replacement = arguments[index]
                index += 1
                return nil
            case "f":
                guard index < arguments.count else {
                    return missingValue(flag: "-f")
                }
                hasExplicitPatternSource = true
                let path = arguments[index]
                if path == "-" {
                    options.patternFileStdin = true
                    index += 1
                    continue
                }
                switch readPatterns(from: path) {
                case .patterns(let patterns):
                    explicitPatterns.append(contentsOf: patterns)
                case .error(let message):
                    return message
                }
                index += 1
            default:
                return nil
            }
        }
        return nil
    }

    private static func shouldLoadConfig(for arguments: [String]) -> Bool {
        !arguments.contains { argument in
            argument == "-h" || argument == "--help" || argument == "--version" || argument == "--no-config"
        }
    }

    private static func configArguments(
        environment: [String: String],
        emitDebug: Bool
    ) -> (arguments: [String], warnings: [String], diagnostics: [String]) {
        guard let path = environment["RIPGREP_CONFIG_PATH"] else {
            return (
                [],
                [],
                emitDebug ? [missingConfigPathDebugMessage] : []
            )
        }
        guard !path.isEmpty else {
            return ([], [], [])
        }
        let contents: String
        do {
            contents = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        } catch {
            return ([], [
                "failed to read the file specified in RIPGREP_CONFIG_PATH: \(path): \(configReadErrorDescription(path: path, error: error))",
            ], [])
        }
        let arguments: [String] = contents.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                return nil
            }
            return trimmed
        }
        let diagnostics = emitDebug && !arguments.isEmpty
            ? [loadedConfigDebugMessage(path: path, arguments: arguments)]
            : []
        return (arguments, [], diagnostics)
    }

    private static let missingConfigPathDebugMessage =
        "DEBUG|rg::flags::config|crates/core/flags/config.rs:19: RIPGREP_CONFIG_PATH environment variable is not set, therefore not reading any config file"

    private static let noConfigArgumentsDebugMessage =
        "DEBUG|rg::flags::parse|crates/core/flags/parse.rs:97: no extra arguments found from configuration file"

    private static let noConfigDebugMessage =
        "DEBUG|rg::flags::parse|crates/core/flags/parse.rs:89: not reading config files because --no-config is present"

    private static func loadedConfigDebugMessage(path: String, arguments: [String]) -> String {
        let formattedArguments = arguments.map { "\"\($0)\"" }.joined(separator: ", ")
        return "DEBUG|rg::flags::config|crates/core/flags/config.rs:47: \(path): arguments loaded from config file: [\(formattedArguments)]"
    }

    private static func configReadErrorDescription(path: String, error: Error) -> String {
        if !FileManager.default.fileExists(atPath: path) {
            return "No such file or directory (os error 2)"
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return "\(nsError.localizedDescription) (os error \(nsError.code))"
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return "\(underlying.localizedDescription) (os error \(underlying.code))"
        }
        return nsError.localizedDescription
    }

    private static func parseStrictGlob(_ raw: String) -> String? {
        hasUnclosedCharacterClass(raw) ? nil : raw
    }

    private static func globParseError(_ raw: String) -> String {
        "rg: error parsing glob '\(raw)': unclosed character class; missing ']'"
    }

    private static func hasUnclosedCharacterClass(_ pattern: String) -> Bool {
        var escaped = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "[" {
                var cursor = pattern.index(after: index)
                var foundClose = false
                while cursor < pattern.endIndex {
                    if pattern[cursor] == "]" {
                        foundClose = true
                        break
                    }
                    cursor = pattern.index(after: cursor)
                }
                if !foundClose {
                    return true
                }
                index = cursor
            }
            index = pattern.index(after: index)
        }
        return false
    }

    private static func parseContextCount(_ raw: String, flag: String) -> Int? {
        parseNonNegativeInt(raw)
    }

    private static func applyUnrestricted(repeatCount: Int, to options: inout RipgrepOptions) -> String? {
        for _ in 0..<repeatCount {
            if let error = applyUnrestricted(to: &options) {
                return error
            }
        }
        return nil
    }

    private static func applyUnrestricted(to options: inout RipgrepOptions) -> String? {
        guard options.unrestrictedCount < 3 else {
            return "error parsing flag -u: flag can only be repeated up to 3 times"
        }
        options.unrestrictedCount += 1
        if !options.noIgnore {
            options.noIgnore = true
            options.noIgnoreDot = true
            options.noIgnoreParent = true
            options.noIgnoreVCS = true
        } else if !options.hidden {
            options.hidden = true
        } else {
            options.binaryMode = .searchAndSuppress
        }
        return nil
    }

    private static func parseEncoding(_ raw: String) -> EncodingMode? {
        switch raw.lowercased() {
        case "auto":
            return .automatic
        case "none":
            return .disabled
        case "utf-8", "utf8":
            return .explicit(.utf8)
        case "utf-16", "utf16":
            return .explicit(.utf16)
        case "utf-16le", "utf16le":
            return .explicit(.utf16LittleEndian)
        case "utf-16be", "utf16be":
            return .explicit(.utf16BigEndian)
        case "latin1", "latin-1", "iso-8859-1", "iso8859-1":
            return .explicit(.isoLatin1)
        case "shift_jis", "shift-jis", "sjis":
            return .explicit(Self.stringEncoding(.shiftJIS))
        case "euc-jp", "eucjp":
            return .explicit(Self.stringEncoding(.EUC_JP))
        default:
            return nil
        }
    }

    private static func stringEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        return String.Encoding(rawValue: raw)
    }

    private static func parseEngineMode(_ raw: String) -> EngineMode? {
        switch raw {
        case "default":
            return .default
        case "pcre2":
            return .pcre2
        case "auto":
            return .automatic
        default:
            return nil
        }
    }

    private static func parseColorMode(_ raw: String) -> ColorMode? {
        switch raw {
        case "never":
            return .never
        case "auto":
            return .automatic
        case "always":
            return .always
        case "ansi":
            return .ansi
        default:
            return nil
        }
    }

    private static func parseColorChange(_ raw: String) -> (change: ColorChange?, error: String?) {
        let pieces = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= 2, pieces.count <= 3 else {
            return (nil, invalidColorSpec(raw))
        }
        guard let target = parseColorTarget(pieces[0]) else {
            return (nil, unrecognizedColorTarget(pieces[0]))
        }

        switch pieces[1].lowercased() {
        case "none":
            return (ColorChange(target: target, attribute: .none), nil)
        case "fg":
            guard pieces.count == 3 else { return (nil, invalidColorSpec(raw)) }
            guard isValidColor(pieces[2]) else { return (nil, unrecognizedColorValue(pieces[2])) }
            return (ColorChange(target: target, attribute: .foreground(pieces[2].lowercased())), nil)
        case "bg":
            guard pieces.count == 3 else { return (nil, invalidColorSpec(raw)) }
            guard isValidColor(pieces[2]) else { return (nil, unrecognizedColorValue(pieces[2])) }
            return (ColorChange(target: target, attribute: .background(pieces[2].lowercased())), nil)
        case "style":
            guard pieces.count == 3 else { return (nil, invalidColorSpec(raw)) }
            guard isValidStyle(pieces[2]) else { return (nil, unrecognizedColorStyle(pieces[2])) }
            return (ColorChange(target: target, attribute: .style(pieces[2].lowercased())), nil)
        default:
            return (nil, unrecognizedColorSpecType(pieces[1]))
        }
    }

    private static func parseColorTarget(_ raw: String) -> ColorTarget? {
        switch raw.lowercased() {
        case "path":
            return .path
        case "line":
            return .line
        case "column":
            return .column
        case "match":
            return .match
        case "highlight":
            return .highlight
        default:
            return nil
        }
    }

    private static func isValidColor(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        if ["black", "blue", "green", "red", "cyan", "magenta", "yellow", "white"].contains(lower) {
            return true
        }
        if parseColorByte(lower) != nil {
            return true
        }
        let components = lower.split(separator: ",", omittingEmptySubsequences: false)
        return components.count == 3 && components.allSatisfy { parseColorByte(String($0)) != nil }
    }

    private static func isValidStyle(_ raw: String) -> Bool {
        ["bold", "nobold", "intense", "nointense", "underline", "nounderline", "italic", "noitalic"]
            .contains(raw.lowercased())
    }

    private static func parseColorByte(_ raw: String) -> UInt8? {
        let value: UInt64?
        if raw.hasPrefix("0x") {
            value = UInt64(raw.dropFirst(2), radix: 16)
        } else {
            value = UInt64(raw)
        }
        guard let value, value <= UInt8.max else {
            return nil
        }
        return UInt8(value)
    }

    private static func parseHyperlinkFormat(_ raw: String) throws -> HyperlinkFormat {
        let expanded = hyperlinkAliases[raw] ?? raw
        guard !expanded.isEmpty else {
            return HyperlinkFormat()
        }

        var parts: [HyperlinkFormat.Part] = []
        var text = ""
        var index = expanded.startIndex

        func flushText() {
            if !text.isEmpty {
                parts.append(.text(text))
                text = ""
            }
        }

        while index < expanded.endIndex {
            let character = expanded[index]
            if character == "{" {
                let next = expanded.index(after: index)
                if next < expanded.endIndex, expanded[next] == "{" {
                    text.append("{")
                    index = expanded.index(after: next)
                    continue
                }
                guard let close = expanded[next...].firstIndex(of: "}") else {
                    throw HyperlinkFormatParseError("unclosed variable: found '{' without a corresponding '}' following it")
                }
                let name = String(expanded[next..<close])
                flushText()
                switch name {
                case "path":
                    parts.append(.path)
                case "line":
                    parts.append(.line)
                case "column":
                    parts.append(.column)
                case "host":
                    parts.append(.host)
                case "wslprefix":
                    parts.append(.wslPrefix)
                default:
                    throw HyperlinkFormatParseError("invalid hyperlink format variable: '\(name)', choose from: path, line, column, host, wslprefix")
                }
                index = expanded.index(after: close)
            } else if character == "}" {
                let next = expanded.index(after: index)
                if next < expanded.endIndex, expanded[next] == "}" {
                    text.append("}")
                    index = expanded.index(after: next)
                } else {
                    throw HyperlinkFormatParseError("unopened variable: found '}' without a corresponding '{' preceding it")
                }
            } else {
                text.append(character)
                index = expanded.index(after: index)
            }
        }
        flushText()

        guard parts.contains(.path) else {
            if parts.allSatisfy({
                if case .text = $0 { return true }
                return false
            }) {
                throw HyperlinkFormatParseError("at least a {path} variable is required in a hyperlink format, or otherwise use a valid alias: default, none, cursor, file, grep+, kitty, macvim, textmate, vscode, vscode-insiders, vscodium")
            }
            throw HyperlinkFormatParseError("the {path} variable is required in a hyperlink format")
        }
        if parts.contains(.column), !parts.contains(.line) {
            throw HyperlinkFormatParseError("the hyperlink format contains a {column} variable, but no {line} variable is present")
        }
        try validateHyperlinkScheme(parts)
        return HyperlinkFormat(parts: parts)
    }

    private static let hyperlinkAliases = [
        "cursor": "cursor://file{path}:{line}:{column}",
        "default": "file://{host}{path}",
        "file": "file://{host}{path}",
        "grep+": "grep+://{path}:{line}",
        "kitty": "file://{host}{path}#{line}",
        "macvim": "mvim://open?url=file://{path}&line={line}&column={column}",
        "none": "",
        "textmate": "txmt://open?url=file://{path}&line={line}&column={column}",
        "vscode": "vscode://file{path}:{line}:{column}",
        "vscode-insiders": "vscode-insiders://file{path}:{line}:{column}",
        "vscodium": "vscodium://file{path}:{line}:{column}",
    ]

    private static func validateHyperlinkScheme(_ parts: [HyperlinkFormat.Part]) throws {
        guard case .text(let prefix) = parts.first,
              let colon = prefix.firstIndex(of: ":") else {
            throw HyperlinkFormatParseError("the hyperlink format must start with a valid URL scheme, i.e., [0-9A-Za-z+-.]+:")
        }
        let scheme = prefix[..<colon]
        guard !scheme.isEmpty,
              scheme.allSatisfy({ character in
                  character.isASCII && (character.isLetter || character.isNumber || character == "+" || character == "-" || character == ".")
              }) else {
            throw HyperlinkFormatParseError("the hyperlink format must start with a valid URL scheme, i.e., [0-9A-Za-z+-.]+:")
        }
    }

    private enum PathSeparatorParseResult {
        case automatic
        case separator(Character)
    }

    private static func parsePathSeparator(_ raw: String) -> PathSeparatorParseResult? {
        guard !raw.isEmpty else {
            return .automatic
        }
        let value = parseEscapedSeparator(raw)
        guard value.count == 1,
              let separator = value.first,
              String(separator).utf8.count == 1 else {
            return nil
        }
        return .separator(separator)
    }

    private static func invalidPathSeparator(_ raw: String) -> String {
        let value = parseEscapedSeparator(raw)
        let byteCount = value.utf8.count
        return """
        error parsing flag --path-separator: A path separator must be exactly one byte, but the given separator is \(byteCount) bytes: \(raw)
        In some shells on Windows '/' is automatically expanded. Use '//' instead.
        """
    }

    private static func parseEscapedSeparator(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            let character = raw[index]
            guard character == "\\" else {
                output.append(character)
                index = raw.index(after: index)
                continue
            }

            let nextIndex = raw.index(after: index)
            guard nextIndex < raw.endIndex else {
                output.append(character)
                index = nextIndex
                continue
            }

            let next = raw[nextIndex]
            switch next {
            case "0":
                output.append("\0")
                index = raw.index(after: nextIndex)
            case "n":
                output.append("\n")
                index = raw.index(after: nextIndex)
            case "r":
                output.append("\r")
                index = raw.index(after: nextIndex)
            case "t":
                output.append("\t")
                index = raw.index(after: nextIndex)
            case "\\":
                output.append("\\")
                index = raw.index(after: nextIndex)
            case "x":
                let firstHex = raw.index(after: nextIndex)
                guard firstHex < raw.endIndex else {
                    output.append("\\x")
                    index = firstHex
                    continue
                }
                let secondHex = raw.index(after: firstHex)
                guard secondHex < raw.endIndex else {
                    output.append("\\x")
                    output.append(raw[firstHex])
                    index = secondHex
                    continue
                }
                let hex = String(raw[firstHex...secondHex])
                if let scalarValue = UInt32(hex, radix: 16),
                   let scalar = UnicodeScalar(scalarValue) {
                    output.append(Character(scalar))
                } else {
                    output.append("\\x\(hex)")
                }
                index = raw.index(after: secondHex)
            default:
                output.append(next)
                index = raw.index(after: nextIndex)
            }
        }

        return output
    }

    private static func parseSort(_ raw: String, reverse: Bool) -> SortMode? {
        switch raw {
        case "path":
            return SortMode(kind: .path, reverse: reverse)
        case "modified":
            return SortMode(kind: .modified, reverse: reverse)
        case "accessed":
            return SortMode(kind: .accessed, reverse: reverse)
        case "created":
            return SortMode(kind: .created, reverse: reverse)
        default:
            return nil
        }
    }

    private static func parseNonNegativeInt(_ raw: String) -> Int? {
        guard !raw.hasPrefix("-") else { return nil }
        guard let count = Int(raw), count >= 0 else { return nil }
        return count
    }

    private static func parsePositiveInt(_ raw: String) -> Int? {
        guard let count = Int(raw), count > 0 else { return nil }
        return count
    }

    private static func invalidNumber(flag: String, value: String) -> String {
        "error parsing flag \(flag): value is not a valid number: \(invalidNumberDetail(value))"
    }

    private static func invalidNumberDetail(_ raw: String) -> String {
        if raw.isEmpty {
            return "cannot parse integer from empty string"
        }
        let digits = raw.hasPrefix("+") ? raw.dropFirst() : raw[...]
        if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
            return "number too large to fit in target type"
        }
        return "invalid digit found in string"
    }

    private static func unknownEncoding(_ raw: String, flag: String) -> String {
        "error parsing flag \(flag): grep config error: unknown encoding: \(raw)"
    }

    private static func invalidColorSpec(_ raw: String) -> String {
        """
        error parsing flag --colors: invalid color spec format: '\(raw)'. Valid format is '(path|line|column|match|highlight):(fg|bg|style):(value)'.
        """
    }

    private static func unrecognizedColorTarget(_ raw: String) -> String {
        "error parsing flag --colors: unrecognized output type '\(raw)'. Choose from: path, line, column, match, highlight."
    }

    private static func unrecognizedColorSpecType(_ raw: String) -> String {
        "error parsing flag --colors: unrecognized spec type '\(raw)'. Choose from: fg, bg, style, none."
    }

    private static func unrecognizedColorValue(_ raw: String) -> String {
        if raw.contains(",") {
            return "error parsing flag --colors: unrecognized RGB color triple, should be '[0-255],[0-255],[0-255]' (or a hex triple), but is '\(raw)'"
        }
        if isColorNumberLike(raw) {
            return "error parsing flag --colors: unrecognized ansi256 color number, should be '[0-255]' (or a hex number), but is '\(raw)'"
        }
        return "error parsing flag --colors: unrecognized color name '\(raw)'. Choose from: black, blue, green, red, cyan, magenta, yellow, white"
    }

    private static func unrecognizedColorStyle(_ raw: String) -> String {
        "error parsing flag --colors: unrecognized style attribute '\(raw)'. Choose from: nobold, bold, nointense, intense, nounderline, underline, noitalic, italic."
    }

    private static func isColorNumberLike(_ raw: String) -> Bool {
        UInt64(raw) != nil || raw.allSatisfy(\.isHexDigit)
    }

    private static func unrecognizedChoice(flag: String, value: String) -> String {
        "error parsing flag \(flag): choice '\(value)' is unrecognized"
    }

    private static func missingValue(flag: String) -> String {
        "missing value for flag \(flag): missing argument for option '\(flag)'"
    }

    private static func unrecognizedEngine(flag: String, value: String) -> String {
        "error parsing flag \(flag): unrecognized regex engine '\(value)'"
    }

    private static func invalidSize(flag: String, value: String) -> String {
        "error parsing flag \(flag): invalid size: \(invalidSizeDetail(value))"
    }

    private static func invalidSizeDetail(_ raw: String) -> String {
        let formatMessage = "invalid format for size '\(raw)', which should be a non-empty sequence of digits followed by an optional 'K', 'M' or 'G' suffix"
        guard !raw.isEmpty else {
            return formatMessage
        }
        let suffix = raw.last!
        let multiplier: UInt64
        let digits: Substring
        switch suffix {
        case "K":
            multiplier = 1024
            digits = raw.dropLast()
        case "M":
            multiplier = 1024 * 1024
            digits = raw.dropLast()
        case "G":
            multiplier = 1024 * 1024 * 1024
            digits = raw.dropLast()
        default:
            guard suffix.isNumber else {
                return formatMessage
            }
            multiplier = 1
            digits = Substring(raw)
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
            return formatMessage
        }
        guard let value = UInt64(digits) else {
            return "invalid integer found in size '\(raw)': number too large to fit in target type"
        }
        return value.multipliedReportingOverflow(by: multiplier).overflow
            ? "size too big in '\(raw)'"
            : formatMessage
    }

    private static func parseHumanReadableSize(_ raw: String) -> UInt64? {
        guard !raw.isEmpty else {
            return nil
        }
        let suffix = raw.last!
        let multiplier: UInt64
        let digits: Substring
        switch suffix {
        case "K":
            multiplier = 1024
            digits = raw.dropLast()
        case "M":
            multiplier = 1024 * 1024
            digits = raw.dropLast()
        case "G":
            multiplier = 1024 * 1024 * 1024
            digits = raw.dropLast()
        default:
            multiplier = 1
            digits = Substring(raw)
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
            return nil
        }
        guard let value = UInt64(digits) else {
            return nil
        }
        let product = value.multipliedReportingOverflow(by: multiplier)
        return product.overflow ? nil : product.partialValue
    }

    private static func unrecognizedFlag(_ argument: String) -> String {
        let flag = argument.hasPrefix("--")
            ? argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? argument
            : argument
        let suggestions = flagSuggestions(for: flag)
        guard !suggestions.isEmpty else {
            return "unrecognized flag \(flag)"
        }
        return "unrecognized flag \(flag)\n\nsimilar flags that are available: \(suggestions.joined(separator: ", "))"
    }

    private static func unexpectedArgumentForNoValueFlag(_ argument: String) -> String? {
        guard argument.hasPrefix("--"),
              let equals = argument.firstIndex(of: "=") else {
            return nil
        }
        let flag = String(argument[..<equals])
        guard noValueLongFlags.contains(flag) else {
            return nil
        }
        let valueStart = argument.index(after: equals)
        let value = String(argument[valueStart...])
        return "invalid CLI arguments: unexpected argument for option '\(flag)': \"\(escapedArgumentValue(value))\""
    }

    private static func escapedArgumentValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func flagSuggestions(for flag: String) -> [String] {
        guard flag.hasPrefix("--") else {
            return []
        }
        if flag.contains(" ") {
            if let suggestions = spacedFlagSuggestionExtras[flag] {
                return suggestions
            }
            let firstToken = flag.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? flag
            if knownLongFlags.contains(firstToken) {
                return knownLongFlags.filter { knownFlag in
                    guard knownFlag.count >= 8, flag.hasPrefix("\(knownFlag) ") else {
                        return false
                    }
                    let remainder = flag.dropFirst(knownFlag.count + 1)
                    return !remainder.hasPrefix("-")
                }
            }
            let prefixMatches = knownLongFlags.filter { knownFlag in
                firstToken.count >= 6
                    && knownFlag.count >= 7
                    && knownFlag.hasPrefix(firstToken)
            }
            guard let shortest = prefixMatches.map(\.count).min() else {
                return []
            }
            return prefixMatches.filter { $0.count == shortest }
        }
        if flag.hasPrefix("--no-") {
            if let suggestions = exactNegativeFlagSuggestionExtras[flag] {
                return suggestions
            }
            var suggestions: [String] = []
            let positiveFlag = "--" + flag.dropFirst("--no-".count)
            if knownLongFlags.contains(positiveFlag) {
                suggestions.append(String(positiveFlag))
            }
            suggestions.append(contentsOf: negativeFlagSuggestionExtras[flag] ?? [])
            suggestions.append(contentsOf: knownLongFlags.filter { knownFlag in
                flag == knownFlag
                    || knownFlag.hasPrefix(flag)
            })
            return suggestions.uniqued()
        }
        if flag.hasPrefix("--ignore-") {
            return primaryIgnoreFlagSuggestions.filter { knownFlag in
                knownFlag.hasPrefix(flag) || commonPrefixLength(flag, knownFlag) >= 8
            }
        }
        var suggestions = leadingFlagSuggestionExtras[flag] ?? []
        suggestions.append(contentsOf: knownLongFlags.filter { knownFlag in
            flag == knownFlag
                || (flag.count >= 7 && knownFlag.hasPrefix(flag))
                || commonPrefixLength(flag, knownFlag) >= 9
        })
        suggestions.append(contentsOf: flagSuggestionExtras[flag] ?? [])
        return suggestions.uniqued()
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (left, right) in zip(lhs, rhs) {
            guard left == right else {
                break
            }
            count += 1
        }
        return count
    }

    private static let knownLongFlags = [
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
        "--iglob",
        "--ignore",
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
        "--maxdepth",
        "--max-filesize",
        "--messages",
        "--mmap",
        "--multiline",
        "--multiline-dotall",
        "--no-auto-hybrid-regex",
        "--no-binary",
        "--no-block-buffered",
        "--no-byte-offset",
        "--no-column",
        "--no-config",
        "--no-context-separator",
        "--no-crlf",
        "--no-encoding",
        "--no-fixed-strings",
        "--no-follow",
        "--no-filename",
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
        "--no-line-number",
        "--no-line-buffered",
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
        "--passthrough",
        "--passthru",
        "--path-separator",
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
        "--type-not",
        "--type-list",
        "--unrestricted",
        "--unicode",
        "--version",
        "--vimgrep",
        "--with-filename",
        "--word-regexp",
    ]

    private static let noValueLongFlags: Set<String> = [
        "--auto-hybrid-regex",
        "--binary",
        "--block-buffered",
        "--byte-offset",
        "--case-sensitive",
        "--column",
        "--count",
        "--count-matches",
        "--crlf",
        "--debug",
        "--files",
        "--files-with-matches",
        "--files-without-match",
        "--fixed-strings",
        "--follow",
        "--glob-case-insensitive",
        "--heading",
        "--help",
        "--hidden",
        "--ignore",
        "--ignore-case",
        "--ignore-dot",
        "--ignore-exclude",
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
        "--max-columns-preview",
        "--messages",
        "--mmap",
        "--multiline",
        "--multiline-dotall",
        "--no-auto-hybrid-regex",
        "--no-binary",
        "--no-block-buffered",
        "--no-byte-offset",
        "--no-column",
        "--no-config",
        "--no-context-separator",
        "--no-crlf",
        "--no-encoding",
        "--no-fixed-strings",
        "--no-follow",
        "--no-filename",
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
        "--passthrough",
        "--passthru",
        "--pcre2",
        "--pcre2-unicode",
        "--pcre2-version",
        "--pretty",
        "--quiet",
        "--require-git",
        "--search-zip",
        "--smart-case",
        "--sort-files",
        "--stats",
        "--stop-on-nonmatch",
        "--text",
        "--trace",
        "--trim",
        "--type-list",
        "--unrestricted",
        "--unicode",
        "--version",
        "--vimgrep",
        "--with-filename",
        "--word-regexp",
    ]

    private static let primaryIgnoreFlagSuggestions = [
        "--ignore-case",
        "--ignore-file",
        "--ignore",
        "--ignore-dot",
        "--ignore-vcs",
    ]

    private static let negativeFlagSuggestionExtras = [
        "--no-color": ["--colors", "--no-column"],
        "--no-count": ["--max-count"],
        "--no-binar": ["--binary"],
        "--no-byte-offse": ["--byte-offset"],
        "--no-colum": ["--column"],
        "--no-files": ["--no-filename", "--sort-files", "--no-sort-files"],
        "--no-filenam": ["--with-filename"],
        "--no-follo": ["--follow"],
        "--no-hidde": ["--hidden"],
        "--no-regexp": ["--line-regexp", "--word-regexp"],
    ]

    private static let exactNegativeFlagSuggestionExtras = [
        "--no-max-columns": ["--no-column", "--max-columns", "--max-columns-preview", "--no-max-columns-preview"],
    ]

    private static let flagSuggestionExtras = [
        "--colorr": ["--color", "--colors"],
        "--max-depthh": ["--maxdepth"],
    ]

    private static let leadingFlagSuggestionExtras = [
        "--messag": ["--no-messages"],
        "--unicod": ["--no-unicode"],
    ]

    private static let spacedFlagSuggestionExtras = [
        "--ignore-case --line-number": ["--no-line-number"],
    ]
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

private enum PatternFileResult {
    case patterns([String])
    case error(String)
}

private struct HyperlinkFormatParseError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
