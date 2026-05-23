import Foundation

public enum SearchMode: Equatable {
    case search
    case files
    case types
}

public enum PrintMode: Equatable {
    case matchingLines
    case count
    case filesWithMatches
    case filesWithoutMatch
}

public enum BinaryMode: Equatable {
    case automatic
    case searchAndSuppress
    case asText
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
    public var wordRegexp = false
    public var lineRegexp = false
    public var invertMatch = false
    public var onlyMatching = false
    public var replacement: String?
    public var json = false
    public var stats = false
    public var maxCount: Int?
    public var maxDepth: Int?
    public var sortMode: SortMode?
    public var lineNumber = false
    public var noLineNumber = false
    public var column = false
    public var byteOffset = false
    public var withFilename: Bool?
    public var hidden = false
    public var noIgnore = false
    public var ignoreFiles: [URL] = []
    public var globPatterns: [String] = []
    public var typeChanges: [TypeChange] = []
    public var followSymlinks = false
    public var binaryMode: BinaryMode = .automatic
    public var quiet = false
    public var useStdin = false
    public var beforeContext = 0
    public var afterContext = 0
    public var passthru = false

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
    case error(String)
}

public enum RipgrepArgumentParser {
    public static func parse(_ arguments: [String]) -> CLIParseResult {
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
            case "--version":
                return .version
            case "--files":
                options.mode = .files
            case "--type-list":
                options.mode = .types
            case "-i", "--ignore-case":
                options.ignoreCase = true
            case "-S", "--smart-case":
                options.smartCase = true
            case "-F", "--fixed-strings":
                options.fixedStrings = true
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
            case "-v", "--invert-match":
                options.invertMatch = true
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
            case "-b", "--byte-offset":
                options.byteOffset = true
            case "--no-byte-offset":
                options.byteOffset = false
            case "--json":
                options.json = true
            case "--no-json":
                options.json = false
            case "--stats":
                options.stats = true
            case "--no-stats":
                options.stats = false
            case "-N", "--no-line-number":
                options.noLineNumber = true
            case "--column":
                options.column = true
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
            case "--hidden":
                options.hidden = true
            case "--no-ignore":
                options.noIgnore = true
            case "--ignore-file":
                guard index < arguments.count else {
                    return .error("error: The argument '--ignore-file <PATH>' requires a value")
                }
                options.ignoreFiles.append(URL(fileURLWithPath: arguments[index]))
                index += 1
            case let value where value.hasPrefix("--ignore-file="):
                options.ignoreFiles.append(URL(fileURLWithPath: String(value.dropFirst("--ignore-file=".count))))
            case "-g", "--glob":
                guard index < arguments.count else {
                    return .error("error: The argument '--glob <GLOB>' requires a value")
                }
                options.globPatterns.append(arguments[index])
                index += 1
            case let value where value.hasPrefix("--glob="):
                options.globPatterns.append(String(value.dropFirst("--glob=".count)))
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
            case "--passthru":
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
            case "-c", "--count":
                options.printMode = .count
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
          -F, --fixed-strings        Treat the pattern as a literal string
          -e, --regexp PATTERN       Add a pattern to search for
          -f, --file PATTERNFILE     Read patterns from a file
          -w, --word-regexp          Only show matches surrounded by word boundaries
          -x, --line-regexp          Only show matches spanning an entire line
          -v, --invert-match         Show non-matching lines
          -o, --only-matching        Print only the matched text
          -r, --replace TEXT         Replace matches with the given text
              --json                 Show search results in JSON Lines format
              --stats                Print statistics about the search
          -m, --max-count NUM        Limit matching lines per file
          -d, --max-depth NUM        Descend at most NUM directory levels
          -n, --line-number          Show line numbers
          -N, --no-line-number       Suppress line numbers
              --column               Show the first match column
          -b, --byte-offset          Show the 0-based byte offset
              --sort SORTBY          Sort results by path, modified, accessed or created
              --sortr SORTBY         Sort results in reverse order
          -H, --with-filename        Show file names
          -I, --no-filename          Suppress file names
          -c, --count                Show match counts per file
              -l, --files-with-matches   Show only paths with matches
              --files-without-match  Show only paths without matches
              --files                Print files that would be searched
              --hidden               Search hidden files and directories
              --no-ignore            Do not respect ignore files
              --ignore-file PATH     Add a custom ignore file
          -g, --glob GLOB            Include or exclude paths with an override glob
          -t, --type TYPE            Only search files matching TYPE
          -T, --type-not TYPE        Do not search files matching TYPE
              --type-add TYPESPEC    Add a new glob for a file type
              --type-clear TYPE      Clear globs for a file type
              --type-list            Show all supported file types
          -A, --after-context NUM    Show NUM lines after each match
          -B, --before-context NUM   Show NUM lines before each match
          -C, --context NUM          Show NUM lines before and after each match
              --passthru             Print both matching and non-matching lines
          -L, --follow               Follow symbolic links
              --binary               Search binary files but suppress binary output
          -a, --text                 Search binary files as text
          -q, --quiet                Do not print matches
          -h, --help                 Print help
              --version              Print version
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

    private static func parseContextCount(_ raw: String, flag: String) -> Int? {
        parseNonNegativeInt(raw)
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
}

private enum PatternFileResult {
    case patterns([String])
    case error(String)
}
