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
    public var mode: SearchMode = .search
    public var printMode: PrintMode = .matchingLines
    public var pattern: String?
    public var patterns: [String] = []
    public var roots: [URL] = []
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
}

public enum CLIParseResult: Equatable {
    case run(RipgrepOptions)
    case help
    case version
    case pcre2Version
    case error(String)
}

public enum RipgrepArgumentParser {
    public static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CLIParseResult {
        let finalArguments: [String]
        if shouldLoadConfig(for: arguments) {
            finalArguments = configArguments(environment: environment) + arguments
        } else {
            finalArguments = arguments
        }
        return parseFinal(finalArguments)
    }

    private static func parseFinal(_ arguments: [String]) -> CLIParseResult {
        var options = RipgrepOptions()
        var positionals: [String] = []
        var explicitPatterns: [String] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            switch argument {
            case "-h", "--help":
                return .help
            case "-V", "--version":
                return .version
            case "--pcre2-version":
                return .pcre2Version
            case "--no-config":
                break
            case "--debug":
                options.loggingMode = .debug
            case "--trace":
                options.loggingMode = .trace
            case "--files":
                options.mode = .files
            case "--type-list":
                options.mode = .types
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
                    return .error("error: The argument '--engine <ENGINE>' requires a value")
                }
                guard let mode = parseEngineMode(arguments[index]) else {
                    return .error("error: unrecognized regex engine '\(arguments[index])'")
                }
                options.engineMode = mode
                index += 1
            case let value where value.hasPrefix("--engine="):
                let raw = String(value.dropFirst("--engine=".count))
                guard let mode = parseEngineMode(raw) else {
                    return .error("error: unrecognized regex engine '\(raw)'")
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
                    return .error("error: The argument '--dfa-size-limit <NUM>' requires a value")
                }
                guard let limit = parseHumanReadableSize(arguments[index]) else {
                    return .error("error: invalid DFA size limit '\(arguments[index])'")
                }
                options.dfaSizeLimit = limit
                index += 1
            case let value where value.hasPrefix("--dfa-size-limit="):
                let raw = String(value.dropFirst("--dfa-size-limit=".count))
                guard let limit = parseHumanReadableSize(raw) else {
                    return .error("error: invalid DFA size limit '\(raw)'")
                }
                options.dfaSizeLimit = limit
            case "--regex-size-limit":
                guard index < arguments.count else {
                    return .error("error: The argument '--regex-size-limit <NUM>' requires a value")
                }
                guard let limit = parseHumanReadableSize(arguments[index]) else {
                    return .error("error: invalid regex size limit '\(arguments[index])'")
                }
                options.regexSizeLimit = limit
                index += 1
            case let value where value.hasPrefix("--regex-size-limit="):
                let raw = String(value.dropFirst("--regex-size-limit=".count))
                guard let limit = parseHumanReadableSize(raw) else {
                    return .error("error: invalid regex size limit '\(raw)'")
                }
                options.regexSizeLimit = limit
            case "-j", "--threads":
                guard index < arguments.count else {
                    return .error("error: The argument '--threads <NUM>' requires a value")
                }
                guard let threads = parseNonNegativeInt(arguments[index]) else {
                    return .error("error: invalid thread count '\(arguments[index])'")
                }
                options.threadCount = threads == 0 ? nil : threads
                index += 1
            case let value where value.hasPrefix("--threads="):
                let raw = String(value.dropFirst("--threads=".count))
                guard let threads = parseNonNegativeInt(raw) else {
                    return .error("error: invalid thread count '\(raw)'")
                }
                options.threadCount = threads == 0 ? nil : threads
            case let value where value.hasPrefix("-j") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let threads = parseNonNegativeInt(raw) else {
                    return .error("error: invalid thread count '\(raw)'")
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
                    return .error("error: The argument '--encoding <ENCODING>' requires a value")
                }
                guard let mode = parseEncoding(arguments[index]) else {
                    return .error("error: unknown encoding '\(arguments[index])'")
                }
                options.encodingMode = mode
                index += 1
            case let value where value.hasPrefix("--encoding="):
                let raw = String(value.dropFirst("--encoding=".count))
                guard let mode = parseEncoding(raw) else {
                    return .error("error: unknown encoding '\(raw)'")
                }
                options.encodingMode = mode
            case let value where value.hasPrefix("-E") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let mode = parseEncoding(raw) else {
                    return .error("error: unknown encoding '\(raw)'")
                }
                options.encodingMode = mode
            case "--no-encoding":
                options.encodingMode = .automatic
            case "-e", "--regexp":
                guard index < arguments.count else {
                    return .error("error: The argument '--regexp <PATTERN>' requires a value")
                }
                explicitPatterns.append(arguments[index])
                index += 1
            case let value where value.hasPrefix("--regexp="):
                explicitPatterns.append(String(value.dropFirst("--regexp=".count)))
            case "-f", "--file":
                guard index < arguments.count else {
                    return .error("error: The argument '--file <PATTERNFILE>' requires a value")
                }
                switch readPatterns(from: arguments[index]) {
                case .patterns(let patterns):
                    explicitPatterns.append(contentsOf: patterns)
                case .error(let message):
                    return .error(message)
                }
                index += 1
            case let value where value.hasPrefix("--file="):
                switch readPatterns(from: String(value.dropFirst("--file=".count))) {
                case .patterns(let patterns):
                    explicitPatterns.append(contentsOf: patterns)
                case .error(let message):
                    return .error(message)
                }
            case "-w", "--word-regexp":
                options.wordRegexp = true
            case "-x", "--line-regexp":
                options.lineRegexp = true
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
                    return .error("error: The argument '--replace <TEXT>' requires a value")
                }
                options.replacement = arguments[index]
                index += 1
            case let value where value.hasPrefix("--replace="):
                options.replacement = String(value.dropFirst("--replace=".count))
            case "-n", "--line-number":
                options.lineNumber = true
                options.noLineNumber = false
            case "-b", "--byte-offset":
                options.byteOffset = true
            case "--no-byte-offset":
                options.byteOffset = false
            case "--json":
                options.json = true
                options.colorMode = .never
            case "--no-json":
                options.json = false
            case "-p", "--pretty":
                options.colorMode = .always
                options.heading = true
                options.lineNumber = true
                options.noLineNumber = false
            case "--color":
                guard index < arguments.count else {
                    return .error("error: The argument '--color <WHEN>' requires a value")
                }
                guard let mode = parseColorMode(arguments[index]) else {
                    return .error("error: choice '\(arguments[index])' is unrecognized")
                }
                options.colorMode = mode
                index += 1
            case let value where value.hasPrefix("--color="):
                let raw = String(value.dropFirst("--color=".count))
                guard let mode = parseColorMode(raw) else {
                    return .error("error: choice '\(raw)' is unrecognized")
                }
                options.colorMode = mode
            case "--no-color":
                options.colorMode = .never
            case "--colors":
                guard index < arguments.count else {
                    return .error("error: The argument '--colors <COLOR_SPEC>' requires a value")
                }
                guard let change = parseColorChange(arguments[index]) else {
                    return .error("error: invalid color spec '\(arguments[index])'")
                }
                options.colorChanges.append(change)
                index += 1
            case let value where value.hasPrefix("--colors="):
                let raw = String(value.dropFirst("--colors=".count))
                guard let change = parseColorChange(raw) else {
                    return .error("error: invalid color spec '\(raw)'")
                }
                options.colorChanges.append(change)
            case "--hyperlink-format":
                guard index < arguments.count else {
                    return .error("error: The argument '--hyperlink-format <FORMAT>' requires a value")
                }
                do {
                    options.hyperlinkFormat = try parseHyperlinkFormat(arguments[index])
                } catch {
                    return .error("error: invalid hyperlink format: \(error.localizedDescription)")
                }
                index += 1
            case let value where value.hasPrefix("--hyperlink-format="):
                let raw = String(value.dropFirst("--hyperlink-format=".count))
                do {
                    options.hyperlinkFormat = try parseHyperlinkFormat(raw)
                } catch {
                    return .error("error: invalid hyperlink format: \(error.localizedDescription)")
                }
            case "--hostname-bin":
                guard index < arguments.count else {
                    return .error("error: The argument '--hostname-bin <COMMAND>' requires a value")
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
                    return .error("error: The argument '--max-columns <NUM>' requires a value")
                }
                guard let columns = parseNonNegativeInt(arguments[index]) else {
                    return .error("error: invalid max columns '\(arguments[index])'")
                }
                options.maxColumns = columns == 0 ? nil : columns
                index += 1
            case let value where value.hasPrefix("--max-columns="):
                let raw = String(value.dropFirst("--max-columns=".count))
                guard let columns = parseNonNegativeInt(raw) else {
                    return .error("error: invalid max columns '\(raw)'")
                }
                options.maxColumns = columns == 0 ? nil : columns
            case let value where value.hasPrefix("-M") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let columns = parseNonNegativeInt(raw) else {
                    return .error("error: invalid max columns '\(raw)'")
                }
                options.maxColumns = columns == 0 ? nil : columns
            case "--max-columns-preview":
                options.maxColumnsPreview = true
            case "--no-max-columns-preview":
                options.maxColumnsPreview = false
            case "--max-filesize":
                guard index < arguments.count else {
                    return .error("error: The argument '--max-filesize <NUM>' requires a value")
                }
                guard let size = parseHumanReadableSize(arguments[index]) else {
                    return .error("error: invalid max filesize '\(arguments[index])'")
                }
                options.maxFileSize = size
                index += 1
            case let value where value.hasPrefix("--max-filesize="):
                let raw = String(value.dropFirst("--max-filesize=".count))
                guard let size = parseHumanReadableSize(raw) else {
                    return .error("error: invalid max filesize '\(raw)'")
                }
                options.maxFileSize = size
            case "-N", "--no-line-number":
                options.lineNumber = false
                options.noLineNumber = true
            case "--column":
                options.column = true
            case "--no-column":
                options.column = false
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
                options.colorMode = .never
            case "-0", "--null":
                options.nullPathTerminator = true
            case "--path-separator":
                guard index < arguments.count else {
                    return .error("error: The argument '--path-separator <SEPARATOR>' requires a value")
                }
                guard let separator = parsePathSeparator(arguments[index]) else {
                    return .error("error: path separator must be a single character")
                }
                options.pathSeparator = separator
                index += 1
            case let value where value.hasPrefix("--path-separator="):
                let raw = String(value.dropFirst("--path-separator=".count))
                guard let separator = parsePathSeparator(raw) else {
                    return .error("error: path separator must be a single character")
                }
                options.pathSeparator = separator
            case "--sort":
                guard index < arguments.count else {
                    return .error("error: The argument '--sort <SORTBY>' requires a value")
                }
                if arguments[index] == "none" {
                    options.sortMode = nil
                } else {
                    guard let sort = parseSort(arguments[index], reverse: false) else {
                        return .error("error: choice '\(arguments[index])' is unrecognized")
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
                        return .error("error: choice '\(raw)' is unrecognized")
                    }
                    options.sortMode = sort
                }
            case "--sortr":
                guard index < arguments.count else {
                    return .error("error: The argument '--sortr <SORTBY>' requires a value")
                }
                if arguments[index] == "none" {
                    options.sortMode = nil
                } else {
                    guard let sort = parseSort(arguments[index], reverse: true) else {
                        return .error("error: choice '\(arguments[index])' is unrecognized")
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
                        return .error("error: choice '\(raw)' is unrecognized")
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
                    return .error("error: The argument '--ignore-file <PATH>' requires a value")
                }
                options.ignoreFiles.append(URL(fileURLWithPath: arguments[index]))
                index += 1
            case let value where value.hasPrefix("--ignore-file="):
                options.ignoreFiles.append(URL(fileURLWithPath: String(value.dropFirst("--ignore-file=".count))))
            case "--pre":
                guard index < arguments.count else {
                    return .error("error: The argument '--pre <COMMAND>' requires a value")
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
                    return .error("error: The argument '--pre-glob <GLOB>' requires a value")
                }
                options.preGlobPatterns.append(arguments[index])
                index += 1
            case let value where value.hasPrefix("--pre-glob="):
                options.preGlobPatterns.append(String(value.dropFirst("--pre-glob=".count)))
            case "-g", "--glob":
                guard index < arguments.count else {
                    return .error("error: The argument '--glob <GLOB>' requires a value")
                }
                options.globPatterns.append(arguments[index])
                index += 1
            case let value where value.hasPrefix("--glob="):
                options.globPatterns.append(String(value.dropFirst("--glob=".count)))
            case "--iglob":
                guard index < arguments.count else {
                    return .error("error: The argument '--iglob <GLOB>' requires a value")
                }
                options.caseInsensitiveGlobPatterns.append(arguments[index])
                index += 1
            case let value where value.hasPrefix("--iglob="):
                options.caseInsensitiveGlobPatterns.append(String(value.dropFirst("--iglob=".count)))
            case "-t", "--type":
                guard index < arguments.count else {
                    return .error("error: The argument '--type <TYPE>' requires a value")
                }
                options.typeChanges.append(.select(arguments[index]))
                index += 1
            case let value where value.hasPrefix("--type="):
                options.typeChanges.append(.select(String(value.dropFirst("--type=".count))))
            case let value where value.hasPrefix("-t") && value.count > 2:
                options.typeChanges.append(.select(String(value.dropFirst(2))))
            case "-T", "--type-not":
                guard index < arguments.count else {
                    return .error("error: The argument '--type-not <TYPE>' requires a value")
                }
                options.typeChanges.append(.negate(arguments[index]))
                index += 1
            case let value where value.hasPrefix("--type-not="):
                options.typeChanges.append(.negate(String(value.dropFirst("--type-not=".count))))
            case let value where value.hasPrefix("-T") && value.count > 2:
                options.typeChanges.append(.negate(String(value.dropFirst(2))))
            case "--type-add":
                guard index < arguments.count else {
                    return .error("error: The argument '--type-add <TYPESPEC>' requires a value")
                }
                options.typeChanges.append(.add(arguments[index]))
                index += 1
            case let value where value.hasPrefix("--type-add="):
                options.typeChanges.append(.add(String(value.dropFirst("--type-add=".count))))
            case "--type-clear":
                guard index < arguments.count else {
                    return .error("error: The argument '--type-clear <TYPE>' requires a value")
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
                options.binaryMode = .asText
            case "-u", "--unrestricted":
                applyUnrestricted(to: &options)
            case "-uu":
                applyUnrestricted(to: &options)
                applyUnrestricted(to: &options)
            case "-uuu":
                applyUnrestricted(to: &options)
                applyUnrestricted(to: &options)
                applyUnrestricted(to: &options)
            case "--passthru", "--passthrough":
                options.passthru = true
                options.beforeContext = 0
                options.afterContext = 0
            case "-m", "--max-count":
                guard index < arguments.count else {
                    return .error("error: The argument '--max-count <NUM>' requires a value")
                }
                guard let count = parseNonNegativeInt(arguments[index]) else {
                    return .error("error: invalid max count '\(arguments[index])'")
                }
                options.maxCount = count
                index += 1
            case let value where value.hasPrefix("--max-count="):
                let raw = String(value.dropFirst("--max-count=".count))
                guard let count = parseNonNegativeInt(raw) else {
                    return .error("error: invalid max count '\(raw)'")
                }
                options.maxCount = count
            case let value where value.hasPrefix("-m") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let count = parseNonNegativeInt(raw) else {
                    return .error("error: invalid max count '\(raw)'")
                }
                options.maxCount = count
            case "-d", "--max-depth":
                guard index < arguments.count else {
                    return .error("error: The argument '--max-depth <NUM>' requires a value")
                }
                guard let depth = parseNonNegativeInt(arguments[index]) else {
                    return .error("error: invalid max depth '\(arguments[index])'")
                }
                options.maxDepth = depth
                index += 1
            case let value where value.hasPrefix("--max-depth="):
                let raw = String(value.dropFirst("--max-depth=".count))
                guard let depth = parseNonNegativeInt(raw) else {
                    return .error("error: invalid max depth '\(raw)'")
                }
                options.maxDepth = depth
            case let value where value.hasPrefix("-d") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let depth = parseNonNegativeInt(raw) else {
                    return .error("error: invalid max depth '\(raw)'")
                }
                options.maxDepth = depth
            case "-A", "--after-context":
                guard index < arguments.count else {
                    return .error("error: The argument '--after-context <NUM>' requires a value")
                }
                guard let count = parseContextCount(arguments[index], flag: argument) else {
                    return .error("error: invalid context length '\(arguments[index])'")
                }
                options.afterContext = count
                options.passthru = false
                index += 1
            case let value where value.hasPrefix("--after-context="):
                let raw = String(value.dropFirst("--after-context=".count))
                guard let count = parseContextCount(raw, flag: "--after-context") else {
                    return .error("error: invalid context length '\(raw)'")
                }
                options.afterContext = count
                options.passthru = false
            case let value where value.hasPrefix("-A") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let count = parseContextCount(raw, flag: "-A") else {
                    return .error("error: invalid context length '\(raw)'")
                }
                options.afterContext = count
                options.passthru = false
            case "-B", "--before-context":
                guard index < arguments.count else {
                    return .error("error: The argument '--before-context <NUM>' requires a value")
                }
                guard let count = parseContextCount(arguments[index], flag: argument) else {
                    return .error("error: invalid context length '\(arguments[index])'")
                }
                options.beforeContext = count
                options.passthru = false
                index += 1
            case let value where value.hasPrefix("--before-context="):
                let raw = String(value.dropFirst("--before-context=".count))
                guard let count = parseContextCount(raw, flag: "--before-context") else {
                    return .error("error: invalid context length '\(raw)'")
                }
                options.beforeContext = count
                options.passthru = false
            case let value where value.hasPrefix("-B") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let count = parseContextCount(raw, flag: "-B") else {
                    return .error("error: invalid context length '\(raw)'")
                }
                options.beforeContext = count
                options.passthru = false
            case "-C", "--context":
                guard index < arguments.count else {
                    return .error("error: The argument '--context <NUM>' requires a value")
                }
                guard let count = parseContextCount(arguments[index], flag: argument) else {
                    return .error("error: invalid context length '\(arguments[index])'")
                }
                options.beforeContext = count
                options.afterContext = count
                options.passthru = false
                index += 1
            case let value where value.hasPrefix("--context="):
                let raw = String(value.dropFirst("--context=".count))
                guard let count = parseContextCount(raw, flag: "--context") else {
                    return .error("error: invalid context length '\(raw)'")
                }
                options.beforeContext = count
                options.afterContext = count
                options.passthru = false
            case let value where value.hasPrefix("-C") && value.count > 2:
                let raw = String(value.dropFirst(2))
                guard let count = parseContextCount(raw, flag: "-C") else {
                    return .error("error: invalid context length '\(raw)'")
                }
                options.beforeContext = count
                options.afterContext = count
                options.passthru = false
            case "--context-separator":
                guard index < arguments.count else {
                    return .error("error: The argument '--context-separator <SEPARATOR>' requires a value")
                }
                options.contextSeparator = arguments[index]
                index += 1
            case let value where value.hasPrefix("--context-separator="):
                options.contextSeparator = String(value.dropFirst("--context-separator=".count))
            case "--no-context-separator":
                options.contextSeparator = nil
            case "--field-match-separator":
                guard index < arguments.count else {
                    return .error("error: The argument '--field-match-separator <SEPARATOR>' requires a value")
                }
                options.fieldMatchSeparator = parseEscapedSeparator(arguments[index])
                index += 1
            case let value where value.hasPrefix("--field-match-separator="):
                options.fieldMatchSeparator = parseEscapedSeparator(String(value.dropFirst("--field-match-separator=".count)))
            case "--field-context-separator":
                guard index < arguments.count else {
                    return .error("error: The argument '--field-context-separator <SEPARATOR>' requires a value")
                }
                options.fieldContextSeparator = parseEscapedSeparator(arguments[index])
                index += 1
            case let value where value.hasPrefix("--field-context-separator="):
                options.fieldContextSeparator = parseEscapedSeparator(String(value.dropFirst("--field-context-separator=".count)))
            case "-c", "--count":
                options.printMode = .count
                options.json = false
            case "--count-matches":
                options.printMode = .countMatches
                options.json = false
            case "-l", "--files-with-matches":
                options.printMode = .filesWithMatches
                options.json = false
            case "--files-without-match":
                options.printMode = .filesWithoutMatch
                options.json = false
            case "--":
                positionals.append(contentsOf: arguments[index...])
                index = arguments.count
            case "-":
                options.useStdin = true
            default:
                if argument.hasPrefix("-") {
                    return .error("error: unrecognized option '\(argument)'")
                }
                positionals.append(argument)
            }
        }

        if options.mode == .search {
            if explicitPatterns.isEmpty {
                guard let pattern = positionals.first, !pattern.isEmpty else {
                    return .error(usage())
                }
                options.pattern = pattern
                options.patterns = [pattern]
                options.roots = positionals.dropFirst().map { URL(fileURLWithPath: $0) }
            } else {
                options.pattern = explicitPatterns.first
                options.patterns = explicitPatterns
                options.roots = positionals.map { URL(fileURLWithPath: $0) }
            }
            if options.roots.isEmpty && !options.useStdin {
                options.roots = [URL(fileURLWithPath: ".")]
            }
        } else if options.mode == .files {
            options.roots = positionals.map { URL(fileURLWithPath: $0) }
            if options.roots.isEmpty {
                options.roots = [URL(fileURLWithPath: ".")]
            }
        } else {
            options.roots = []
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
              --dfa-size-limit NUM   Set the regex DFA size limit
              --regex-size-limit NUM Set the compiled regex size limit
          -j, --threads NUM          Set the approximate thread count
              --mmap                 Search with memory maps when possible
          -E, --encoding ENCODING    Specify text encoding: auto, none, utf-8, utf-16/le/be
          -e, --regexp PATTERN       Add a pattern to search for
          -f, --file PATTERNFILE     Read patterns from a file
          -w, --word-regexp          Only show matches surrounded by word boundaries
          -x, --line-regexp          Only show matches spanning an entire line
              --no-unicode           Disable Unicode mode
              --pcre2-unicode        Enable Unicode mode for PCRE2 compatibility
          -U, --multiline            Enable matching across line terminators
              --multiline-dotall     Make '.' match line terminators in multiline mode
              --crlf                 Treat CRLF as a line terminator for anchors
          -v, --invert-match         Show non-matching lines
              --stop-on-nonmatch     Stop after a non-match following a match
          -o, --only-matching        Print only the matched text
          -r, --replace TEXT         Replace matches with the given text
              --json                 Show search results in JSON Lines format
              --stats                Print statistics about the search
              --include-zero         Print count output for files with zero matches
          -m, --max-count NUM        Limit matching lines per file
          -M, --max-columns NUM      Omit matching lines at least NUM bytes long
              --max-columns-preview  Show a preview for omitted long lines
              --max-filesize NUM     Ignore non-explicit files larger than NUM
          -d, --max-depth NUM        Descend at most NUM directory levels
          -n, --line-number          Show line numbers
          -N, --no-line-number       Suppress line numbers
              --column               Show the first match column
              --no-column            Suppress column numbers
          -b, --byte-offset          Show the 0-based byte offset
          -p, --pretty               Alias for colors, headings and line numbers
              --color WHEN           Use color: never, auto, always or ansi
              --colors COLOR_SPEC    Configure output color settings
              --hyperlink-format FMT Format file path hyperlinks
              --hostname-bin COMMAND Run a program to get the hostname for hyperlinks
              --heading              Group matches by file
              --trim                 Trim leading ASCII whitespace from printed lines
              --vimgrep              Print vim-compatible file:line:column matches
          -0, --null                 Print NUL after file paths
              --path-separator SEP   Set the path separator for printed paths
              --sort SORTBY          Sort results by path, modified, accessed or created
              --sortr SORTBY         Sort results in reverse order
          -H, --with-filename        Show file names
          -I, --no-filename          Suppress file names
          -c, --count                Show match counts per file
              --count-matches        Show individual match counts per file
              -l, --files-with-matches   Show only paths with matches
              --files-without-match  Show only paths without matches
              --files                Print files that would be searched
              --hidden               Search hidden files and directories
          -u, --unrestricted         Reduce filtering; repeat to include hidden/binary files
              --no-ignore            Do not respect ignore files
              --no-ignore-dot        Do not respect .ignore or .rgignore files
              --no-ignore-exclude    Do not respect .git/info/exclude
              --no-ignore-files      Do not respect --ignore-file arguments
              --no-ignore-global     Do not respect global git ignore files
              --no-ignore-messages   Suppress ignore file parse messages
              --no-ignore-parent     Do not respect ignore files in parent directories
              --no-ignore-vcs        Do not respect VCS ignore files
              --no-require-git       Use VCS ignore files outside repositories
              --glob-case-insensitive Process -g/--glob patterns case insensitively
              --ignore-file-case-insensitive Process ignore files case insensitively
              --ignore-file PATH     Add a custom ignore file
              --pre COMMAND          Search stdout of COMMAND for each path
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
              --field-match-separator S   Set field separator for matching lines
              --field-context-separator S Set field separator for context lines
              --passthru             Print both matching and non-matching lines
          -L, --follow               Follow symbolic links
              --one-file-system      Skip directories on other file systems
          -z, --search-zip           Search compressed files
              --binary               Search binary files but suppress binary output
          -a, --text                 Search binary files as text
              --null-data            Use NUL as a line terminator
          -q, --quiet                Do not print matches
              --debug                Show debug messages
              --trace                Show trace messages
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
        do {
            let contents = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            return .patterns(contents.components(separatedBy: "\n").map {
                $0.hasSuffix("\r") ? String($0.dropLast()) : $0
            }.filter { !$0.isEmpty })
        } catch {
            return .error("error: failed to read pattern file '\(path)': \(error)")
        }
    }

    private static func shouldLoadConfig(for arguments: [String]) -> Bool {
        !arguments.contains { argument in
            argument == "-h" || argument == "--help" || argument == "--version" || argument == "--no-config"
        }
    }

    private static func configArguments(environment: [String: String]) -> [String] {
        guard let path = environment["RIPGREP_CONFIG_PATH"], !path.isEmpty else {
            return []
        }
        guard let contents = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            return []
        }
        return contents.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                return nil
            }
            return trimmed
        }
    }

    private static func parseContextCount(_ raw: String, flag: String) -> Int? {
        parseNonNegativeInt(raw)
    }

    private static func applyUnrestricted(to options: inout RipgrepOptions) {
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
        default:
            return nil
        }
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

    private static func parseColorChange(_ raw: String) -> ColorChange? {
        let pieces = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= 2, pieces.count <= 3 else {
            return nil
        }
        guard let target = parseColorTarget(pieces[0]) else {
            return nil
        }

        switch pieces[1].lowercased() {
        case "none":
            guard pieces.count == 2 else { return nil }
            return ColorChange(target: target, attribute: .none)
        case "fg":
            guard pieces.count == 3, isValidColor(pieces[2]) else { return nil }
            return ColorChange(target: target, attribute: .foreground(pieces[2].lowercased()))
        case "bg":
            guard pieces.count == 3, isValidColor(pieces[2]) else { return nil }
            return ColorChange(target: target, attribute: .background(pieces[2].lowercased()))
        case "style":
            guard pieces.count == 3, isValidStyle(pieces[2]) else { return nil }
            return ColorChange(target: target, attribute: .style(pieces[2].lowercased()))
        default:
            return nil
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

    private static func parsePathSeparator(_ raw: String) -> Character? {
        let value: String
        switch raw {
        case #"\"#, #"\\"#:
            value = #"\"#
        case #"\0"#, #"\x00"#, #"\\0"#, #"\\x00"#:
            value = "\0"
        default:
            value = raw
        }
        guard value.count == 1 else {
            return nil
        }
        return value.first
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
        guard let count = Int(raw), count >= 0 else { return nil }
        return count
    }

    private static func parseHumanReadableSize(_ raw: String) -> UInt64? {
        guard !raw.isEmpty else {
            return nil
        }
        let suffix = raw.last!
        let multiplier: UInt64
        let digits: Substring
        switch suffix {
        case "K", "k":
            multiplier = 1024
            digits = raw.dropLast()
        case "M", "m":
            multiplier = 1024 * 1024
            digits = raw.dropLast()
        case "G", "g":
            multiplier = 1024 * 1024 * 1024
            digits = raw.dropLast()
        default:
            multiplier = 1
            digits = Substring(raw)
        }
        guard let value = UInt64(digits) else {
            return nil
        }
        let product = value.multipliedReportingOverflow(by: multiplier)
        return product.overflow ? nil : product.partialValue
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
