import Foundation

public enum SearchMode: Equatable {
    case search
    case files
}

public enum PrintMode: Equatable {
    case matchingLines
    case count
    case filesWithMatches
    case filesWithoutMatch
}

public struct RipgrepOptions: Equatable {
    public var mode: SearchMode = .search
    public var printMode: PrintMode = .matchingLines
    public var pattern: String?
    public var roots: [URL] = []
    public var ignoreCase = false
    public var smartCase = false
    public var fixedStrings = false
    public var wordRegexp = false
    public var lineRegexp = false
    public var invertMatch = false
    public var lineNumber = false
    public var noLineNumber = false
    public var column = false
    public var withFilename: Bool?
    public var hidden = false
    public var followSymlinks = false
    public var quiet = false
    public var useStdin = false

    public init() {}

    public var effectiveRoots: [URL] {
        roots.isEmpty ? [URL(fileURLWithPath: ".")] : roots
    }

    public var effectiveIgnoreCase: Bool {
        ignoreCase || (smartCase && pattern?.rangeOfCharacter(from: .uppercaseLetters) == nil)
    }

    public var wantsLineNumber: Bool {
        lineNumber && !noLineNumber
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
            case "-i", "--ignore-case":
                options.ignoreCase = true
            case "-S", "--smart-case":
                options.smartCase = true
            case "-F", "--fixed-strings":
                options.fixedStrings = true
            case "-w", "--word-regexp":
                options.wordRegexp = true
            case "-x", "--line-regexp":
                options.lineRegexp = true
            case "-v", "--invert-match":
                options.invertMatch = true
            case "-n", "--line-number":
                options.lineNumber = true
            case "-N", "--no-line-number":
                options.noLineNumber = true
            case "--column":
                options.column = true
            case "-H", "--with-filename":
                options.withFilename = true
            case "-I", "--no-filename":
                options.withFilename = false
            case "--hidden":
                options.hidden = true
            case "-L", "--follow":
                options.followSymlinks = true
            case "-q", "--quiet":
                options.quiet = true
            case "-c", "--count":
                options.printMode = .count
            case "-l", "--files-with-matches":
                options.printMode = .filesWithMatches
            case "--files-without-match":
                options.printMode = .filesWithoutMatch
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
            guard let pattern = positionals.first, !pattern.isEmpty else {
                return .error(usage())
            }
            options.pattern = pattern
            options.roots = positionals.dropFirst().map { URL(fileURLWithPath: $0) }
            if options.roots.isEmpty && !options.useStdin {
                options.roots = [URL(fileURLWithPath: ".")]
            }
        } else {
            options.roots = positionals.map { URL(fileURLWithPath: $0) }
            if options.roots.isEmpty {
                options.roots = [URL(fileURLWithPath: ".")]
            }
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
          -w, --word-regexp          Only show matches surrounded by word boundaries
          -x, --line-regexp          Only show matches spanning an entire line
          -v, --invert-match         Show non-matching lines
          -n, --line-number          Show line numbers
          -N, --no-line-number       Suppress line numbers
              --column               Show the first match column
          -H, --with-filename        Show file names
          -I, --no-filename          Suppress file names
          -c, --count                Show match counts per file
          -l, --files-with-matches   Show only paths with matches
              --files-without-match  Show only paths without matches
              --files                Print files that would be searched
              --hidden               Search hidden files and directories
          -L, --follow               Follow symbolic links
          -q, --quiet                Do not print matches
          -h, --help                 Print help
              --version              Print version
        """
    }
}
