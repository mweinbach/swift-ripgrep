import RipgrepCore
#if canImport(CRipgrepPlatform)
import CRipgrepPlatform
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(CRT)
import CRT
#endif

@main
struct RipgrepCommand {
    static func main() {
        #if canImport(Darwin) && canImport(CRipgrepPlatform)
        if let exitCode = runDarwinLiteralPreflight(arguments: Array(CommandLine.arguments.dropFirst())) {
            exit(exitCode)
        }
        #endif
        #if canImport(Darwin) && !canImport(CRipgrepPlatform)
        if let exitCode = runSwiftDarwinLiteralPreflight(arguments: Array(CommandLine.arguments.dropFirst())) {
            exit(exitCode)
        }
        #endif

        let exitCode = RipgrepCLI.run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            standardInputIsReadable: standardInputIsReadable()
        )
        exit(exitCode)
    }

    private static func standardInputIsReadable() -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var statBuffer = stat()
        guard fstat(STDIN_FILENO, &statBuffer) == 0 else {
            return false
        }
        let mode = statBuffer.st_mode & S_IFMT
        return mode == S_IFIFO || mode == S_IFREG
        #else
        return false
        #endif
    }

    #if canImport(Darwin)
    #if canImport(CRipgrepPlatform)
    private static func runDarwinLiteralPreflight(arguments: [String]) -> Int32? {
        guard getenv("RIPGREP_CONFIG_PATH") == nil else {
            return nil
        }

        enum DarwinLiteralPreflightMode {
            case mmap
            case noMmap
            case asciiCaseInsensitive
            case surroundingWords
            case surroundingWordsWithLineNumbers
            case wordWithLineNumbers
        }

        let preflightArguments = darwinLiteralPreflightArguments(
            afterStrippingLeadingEngineSelectorFrom: arguments
        )
        let arguments = preflightArguments.arguments
        let allowPCREQuotedLiterals = preflightArguments.allowPCREQuotedLiterals
        let mode: DarwinLiteralPreflightMode
        let pattern: String
        let path: String
        if arguments.count == 2 {
            mode = .mmap
            pattern = arguments[0]
            path = arguments[1]
        } else if arguments.count == 3,
                  isSingleArgumentEngineSelector(arguments[0]) {
            mode = .mmap
            pattern = arguments[1]
            path = arguments[2]
        } else if arguments.count == 4,
                  arguments[0] == "--engine",
                  isEngineSelectorValue(arguments[1]) {
            mode = .mmap
            pattern = arguments[2]
            path = arguments[3]
        } else if arguments.count == 3, arguments[0] == "--no-mmap" {
            mode = .noMmap
            pattern = arguments[1]
            path = arguments[2]
        } else if arguments.count == 3, arguments[0] == "-i" || arguments[0] == "--ignore-case" {
            mode = .asciiCaseInsensitive
            pattern = arguments[1]
            path = arguments[2]
        } else if arguments.count == 3,
                  arguments[0] == "-n" || arguments[0] == "--line-number",
                  surroundingWordsLiteral(
                    arguments[1],
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                  ) != nil {
            mode = .surroundingWordsWithLineNumbers
            pattern = arguments[1]
            path = arguments[2]
        } else if arguments.count == 3, arguments[0] == "-nw" || arguments[0] == "-wn" {
            mode = .wordWithLineNumbers
            pattern = arguments[1]
            path = arguments[2]
        } else if arguments.count == 4,
                  (arguments[0] == "-n" || arguments[0] == "--line-number"),
                  (arguments[1] == "-w" || arguments[1] == "--word-regexp") {
            mode = .wordWithLineNumbers
            pattern = arguments[2]
            path = arguments[3]
        } else if arguments.count == 4,
                  (arguments[0] == "-w" || arguments[0] == "--word-regexp"),
                  (arguments[1] == "-n" || arguments[1] == "--line-number") {
            mode = .wordWithLineNumbers
            pattern = arguments[2]
            path = arguments[3]
        } else {
            return nil
        }

        if mode == .mmap,
           let literal = surroundingWordsLiteral(
            pattern,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
           ),
           path != "-" {
            let literalBytes = Array(literal.utf8)
            guard !literalBytes.isEmpty,
                  literalBytes.allSatisfy({ $0 < 0x80 }) else {
                return nil
            }
            let result = path.withCString { pathPointer in
                literalBytes.withUnsafeBufferPointer { needle in
                    rg_darwin_write_surrounding_words_file_lines(
                        pathPointer,
                        needle.baseAddress,
                        needle.count
                    )
                }
            }
            guard result.status >= 0 else {
                return nil
            }
            return result.status > 0 ? 0 : 1
        }

        if mode == .surroundingWordsWithLineNumbers,
           let literal = surroundingWordsLiteral(
            pattern,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
           ),
           path != "-" {
            let literalBytes = Array(literal.utf8)
            guard !literalBytes.isEmpty,
                  literalBytes.allSatisfy({ $0 < 0x80 }) else {
                return nil
            }
            let result = path.withCString { pathPointer in
                literalBytes.withUnsafeBufferPointer { needle in
                    rg_darwin_write_surrounding_words_file_lines_with_line_numbers(
                        pathPointer,
                        needle.baseAddress,
                        needle.count
                    )
                }
            }
            guard result.status >= 0 else {
                return nil
            }
            return result.status > 0 ? 0 : 1
        }

        if mode == .mmap,
           let byteSet = singleByteAlternation(
            pattern,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
           ),
           path != "-" {
            let result = path.withCString { pathPointer in
                byteSet.withUnsafeBufferPointer { needles in
                    rg_darwin_write_byte_set_file_lines(
                        pathPointer,
                        needles.baseAddress,
                        needles.count
                    )
                }
            }
            guard result.status >= 0 else {
                return nil
            }
            return result.status > 0 ? 0 : 1
        }

        guard !pattern.hasPrefix("-"),
              path != "-",
              let literalPattern = RegexLiteralParser.literal(
                fromPlainRegexPattern: pattern,
                allowPCREQuotedLiterals: allowPCREQuotedLiterals
              ) else {
            return nil
        }

        let literal = Array(literalPattern.utf8)
        guard !literal.isEmpty,
              mode != .asciiCaseInsensitive || literal.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }

        let result = path.withCString { pathPointer in
            literal.withUnsafeBufferPointer { needle in
                switch mode {
                case .mmap:
                    return rg_darwin_write_literal_file_lines(
                        pathPointer,
                        needle.baseAddress,
                        needle.count
                    )
                case .noMmap:
                    return rg_darwin_write_literal_file_lines_no_mmap(
                        pathPointer,
                        needle.baseAddress,
                        needle.count
                    )
                case .asciiCaseInsensitive:
                    return rg_darwin_write_literal_file_lines_ascii_case_insensitive(
                        pathPointer,
                        needle.baseAddress,
                        needle.count
                    )
                case .surroundingWords:
                    return rg_darwin_write_surrounding_words_file_lines(
                        pathPointer,
                        needle.baseAddress,
                        needle.count
                    )
                case .surroundingWordsWithLineNumbers:
                    return rg_darwin_write_surrounding_words_file_lines_with_line_numbers(
                        pathPointer,
                        needle.baseAddress,
                        needle.count
                    )
                case .wordWithLineNumbers:
                    return rg_darwin_write_word_literal_file_lines(
                        pathPointer,
                        needle.baseAddress,
                        needle.count
                    )
                }
            }
        }
        guard result.status >= 0 else {
            return nil
        }
        return result.status > 0 ? 0 : 1
    }
    #endif

    #if !canImport(CRipgrepPlatform)
    private static func runSwiftDarwinLiteralPreflight(arguments: [String]) -> Int32? {
        guard getenv("RIPGREP_CONFIG_PATH") == nil else {
            return nil
        }

        let preflightArguments = darwinLiteralPreflightArguments(
            afterStrippingLeadingEngineSelectorFrom: arguments
        )
        let arguments = preflightArguments.arguments
        let asciiCaseInsensitive: Bool
        let lineNumber: Bool
        let noMmap: Bool
        let pattern: String
        let path: String
        let wordRegexp: Bool
        let fixedStrings: Bool
        enum CaseMode {
            case sensitive
            case insensitive
            case smart
        }
        func isIgnoreCaseFlag(_ argument: String) -> Bool {
            argument == "-i" || argument == "--ignore-case"
        }
        func isCaseSensitiveFlag(_ argument: String) -> Bool {
            argument == "-s" || argument == "--case-sensitive"
        }
        func isSmartCaseFlag(_ argument: String) -> Bool {
            argument == "-S" || argument == "--smart-case"
        }
        func isLineNumberFlag(_ argument: String) -> Bool {
            argument == "-n" || argument == "--line-number"
        }
        func isNoLineNumberFlag(_ argument: String) -> Bool {
            argument == "-N" || argument == "--no-line-number"
        }
        func isFixedStringsFlag(_ argument: String) -> Bool {
            argument == "-F" || argument == "--fixed-strings"
        }
        func isNoFixedStringsFlag(_ argument: String) -> Bool {
            argument == "--no-fixed-strings"
        }
        func isMmapFlag(_ argument: String) -> Bool {
            argument == "--mmap"
        }
        func isByteOffsetFlag(_ argument: String) -> Bool {
            argument == "-b" || argument == "--byte-offset"
        }
        func isNoByteOffsetFlag(_ argument: String) -> Bool {
            argument == "--no-byte-offset"
        }
        func isColumnFlag(_ argument: String) -> Bool {
            argument == "--column"
        }
        func isNoColumnFlag(_ argument: String) -> Bool {
            argument == "--no-column"
        }
        func isHeadingFlag(_ argument: String) -> Bool {
            argument == "--heading"
        }
        func isNoHeadingFlag(_ argument: String) -> Bool {
            argument == "--no-heading"
        }
        func isWithFilenameFlag(_ argument: String) -> Bool {
            argument == "-H" || argument == "--with-filename"
        }
        func isNoFilenameFlag(_ argument: String) -> Bool {
            argument == "-I" || argument == "--no-filename"
        }
        func isTrimFlag(_ argument: String) -> Bool {
            argument == "--trim"
        }
        func isNoTrimFlag(_ argument: String) -> Bool {
            argument == "--no-trim"
        }
        func isBufferingFlag(_ argument: String) -> Bool {
            argument == "--block-buffered" || argument == "--no-line-buffered"
        }
        func isMessageFlag(_ argument: String) -> Bool {
            argument == "--no-messages" || argument == "--messages"
        }
        func colorModeMayEmitForPreflight(_ value: String) -> Bool? {
            switch value {
            case "never":
                return false
            case "always", "ansi", "auto":
                return true
            default:
                return nil
            }
        }
        func inlineRegexpPattern(_ argument: String) -> String? {
            if argument.hasPrefix("--regexp=") {
                return String(argument.dropFirst("--regexp=".count))
            }
            if argument.hasPrefix("-e"), argument.count > 2 {
                return String(argument.dropFirst(2))
            }
            return nil
        }
        func isOutputNeutralSingleFileFlag(_ argument: String) -> Bool {
            switch argument {
            case "-.",
                 "--hidden",
                 "--ignore",
                 "--ignore-dot",
                 "--ignore-exclude",
                 "--ignore-file-case-insensitive",
                 "--ignore-files",
                 "--ignore-global",
                 "--ignore-messages",
                 "--ignore-parent",
                 "--ignore-vcs",
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
                 "--no-config",
                 "--no-one-file-system",
                 "--no-require-git",
                 "--one-file-system",
                 "--require-git":
                return true
            default:
                return isBufferingFlag(argument) || isMessageFlag(argument)
            }
        }
        func shortFlagCluster(
            _ argument: String
        ) -> (caseMode: CaseMode?, lineNumber: Bool?, wordRegexp: Bool, fixedStrings: Bool)? {
            let bytes = Array(argument.utf8)
            guard bytes.count > 2,
                  bytes.first == UInt8(ascii: "-"),
                  bytes.dropFirst().first != UInt8(ascii: "-") else {
                return nil
            }

            var caseMode: CaseMode?
            var lineNumber: Bool?
            var wordRegexp = false
            var fixedStrings = false
            for byte in bytes.dropFirst() {
                switch byte {
                case UInt8(ascii: "i"):
                    caseMode = .insensitive
                case UInt8(ascii: "s"):
                    caseMode = .sensitive
                case UInt8(ascii: "S"):
                    caseMode = .smart
                case UInt8(ascii: "n"):
                    lineNumber = true
                case UInt8(ascii: "N"):
                    lineNumber = false
                case UInt8(ascii: "w"):
                    wordRegexp = true
                case UInt8(ascii: "F"):
                    fixedStrings = true
                default:
                    return nil
                }
            }
            return (caseMode, lineNumber, wordRegexp, fixedStrings)
        }
        var parsedCaseMode = CaseMode.sensitive
        var parsedByteOffset = false
        var parsedColumn = false
        var parsedColorMayEmit = false
        var parsedFixedStrings = false
        var parsedHeading = false
        var parsedLineNumber = false
        var parsedNoMmap = false
        var parsedTrim = false
        var parsedWithFilename = false
        var parsedWordRegexp = false
        var parsedRegexpPattern: String?
        var patternCanStartWithDash = false
        var valueArguments: [String] = []
        var argumentIndex = 0
        while argumentIndex < arguments.count {
            let argument = arguments[argumentIndex]
            argumentIndex += 1
            if isIgnoreCaseFlag(argument) {
                parsedCaseMode = .insensitive
            } else if isCaseSensitiveFlag(argument) {
                parsedCaseMode = .sensitive
            } else if isSmartCaseFlag(argument) {
                parsedCaseMode = .smart
            } else if isLineNumberFlag(argument) {
                parsedLineNumber = true
            } else if isNoLineNumberFlag(argument) {
                parsedLineNumber = false
            } else if isFixedStringsFlag(argument) {
                parsedFixedStrings = true
            } else if isNoFixedStringsFlag(argument) {
                parsedFixedStrings = false
            } else if isByteOffsetFlag(argument) {
                parsedByteOffset = true
            } else if isNoByteOffsetFlag(argument) {
                parsedByteOffset = false
            } else if isColumnFlag(argument) {
                parsedColumn = true
            } else if isNoColumnFlag(argument) {
                parsedColumn = false
            } else if isHeadingFlag(argument) {
                parsedHeading = true
            } else if isNoHeadingFlag(argument) {
                parsedHeading = false
            } else if isWithFilenameFlag(argument) {
                parsedWithFilename = true
            } else if isNoFilenameFlag(argument) {
                parsedWithFilename = false
            } else if isTrimFlag(argument) {
                parsedTrim = true
            } else if isNoTrimFlag(argument) {
                parsedTrim = false
            } else if argument == "-nw" || argument == "-wn" {
                parsedLineNumber = true
                parsedWordRegexp = true
            } else if argument == "-w" || argument == "--word-regexp" {
                parsedWordRegexp = true
            } else if argument == "--no-mmap" {
                parsedNoMmap = true
            } else if isMmapFlag(argument) {
                parsedNoMmap = false
            } else if argument == "-e" || argument == "--regexp" {
                guard argumentIndex < arguments.count,
                      parsedRegexpPattern == nil else {
                    return nil
                }
                parsedRegexpPattern = arguments[argumentIndex]
                patternCanStartWithDash = true
                argumentIndex += 1
            } else if let inlineRegexp = inlineRegexpPattern(argument) {
                guard parsedRegexpPattern == nil else {
                    return nil
                }
                parsedRegexpPattern = inlineRegexp
                patternCanStartWithDash = true
            } else if argument == "--color" {
                guard argumentIndex < arguments.count,
                      let mayEmit = colorModeMayEmitForPreflight(arguments[argumentIndex]) else {
                    return nil
                }
                parsedColorMayEmit = mayEmit
                argumentIndex += 1
            } else if argument.hasPrefix("--color=") {
                let raw = String(argument.dropFirst("--color=".count))
                guard let mayEmit = colorModeMayEmitForPreflight(raw) else {
                    return nil
                }
                parsedColorMayEmit = mayEmit
            } else if isOutputNeutralSingleFileFlag(argument) {
                continue
            } else if let cluster = shortFlagCluster(argument) {
                if let caseMode = cluster.caseMode {
                    parsedCaseMode = caseMode
                }
                if let lineNumber = cluster.lineNumber {
                    parsedLineNumber = lineNumber
                }
                parsedWordRegexp = parsedWordRegexp || cluster.wordRegexp
                parsedFixedStrings = parsedFixedStrings || cluster.fixedStrings
            } else if argument == "--" {
                valueArguments.append(contentsOf: arguments[argumentIndex...])
                patternCanStartWithDash = true
                argumentIndex = arguments.count
            } else {
                valueArguments.append(argument)
            }
        }
        if let regexpPattern = parsedRegexpPattern {
            guard valueArguments.count == 1 else {
                return nil
            }
            pattern = regexpPattern
            path = valueArguments[0]
        } else {
            guard valueArguments.count == 2 else {
                return nil
            }
            pattern = valueArguments[0]
            path = valueArguments[1]
        }
        switch parsedCaseMode {
        case .sensitive:
            asciiCaseInsensitive = false
        case .insensitive:
            asciiCaseInsensitive = true
        case .smart:
            asciiCaseInsensitive = pattern.rangeOfCharacter(from: .uppercaseLetters) == nil
        }
        lineNumber = parsedLineNumber
        noMmap = parsedNoMmap
        wordRegexp = parsedWordRegexp
        fixedStrings = parsedFixedStrings
        guard !parsedByteOffset,
              !parsedColumn,
              !parsedColorMayEmit,
              !parsedHeading,
              !parsedTrim,
              !parsedWithFilename else {
            return nil
        }

        if !fixedStrings,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-",
           !asciiCaseInsensitive,
           !wordRegexp,
           !noMmap,
           let surroundingLiteral = surroundingWordsLiteral(
            pattern,
            allowPCREQuotedLiterals: preflightArguments.allowPCREQuotedLiterals
           ) {
            return SwiftDarwinLiteralPreflight.surroundingWordsExitCode(
                path: path,
                literal: Array(surroundingLiteral.utf8),
                lineNumber: lineNumber,
                asciiOnly: pattern.hasPrefix("(?-u)")
            )
        }

        let asciiBoundaryLiteralPattern = (fixedStrings || asciiCaseInsensitive) ? nil : asciiBoundaryLiteral(
            pattern,
            allowPCREQuotedLiterals: preflightArguments.allowPCREQuotedLiterals
        )
        let asciiBoundary = asciiBoundaryLiteralPattern != nil
        let parsedLiteralPattern = fixedStrings
            ? pattern
            : asciiBoundaryLiteralPattern ?? RegexLiteralParser.literal(
                fromPlainRegexPattern: pattern,
                allowPCREQuotedLiterals: preflightArguments.allowPCREQuotedLiterals
            )

        if !fixedStrings,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-",
           !asciiCaseInsensitive,
           !wordRegexp,
           !asciiBoundary,
           let literals = multiLiteralAlternation(
            pattern,
            allowPCREQuotedLiterals: preflightArguments.allowPCREQuotedLiterals
           ),
           let exitCode = SwiftDarwinLiteralPreflight.multiLiteralExitCode(
            path: path,
            literals: literals,
            lineNumber: lineNumber
           ) {
            return exitCode
        }

        guard (patternCanStartWithDash || !pattern.hasPrefix("-")),
              path != "-",
              let literalPattern = parsedLiteralPattern else {
            return nil
        }

        let literal = Array(literalPattern.utf8)
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              !asciiCaseInsensitive || literal.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        if wordRegexp {
            guard lineNumber,
                  !asciiCaseInsensitive,
                  !noMmap,
                  !asciiBoundary else {
                return nil
            }
            return SwiftDarwinLiteralPreflight.wordLineNumberExitCode(
                path: path,
                literal: literal
            )
        }
        if noMmap {
            // This executable preflight is output-only; prefer the faster mapped
            // Swift scanner when it is available and keep streaming as fallback.
            if let mappedExitCode = SwiftDarwinLiteralPreflight.exitCode(
                path: path,
                literal: literal,
                asciiCaseInsensitive: asciiCaseInsensitive,
                lineNumber: lineNumber,
                asciiBoundary: asciiBoundary
            ) {
                return mappedExitCode
            }
            guard !asciiBoundary else {
                return nil
            }
            return SwiftDarwinLiteralPreflight.streamingExitCode(
                path: path,
                literal: literal,
                asciiCaseInsensitive: asciiCaseInsensitive,
                lineNumber: lineNumber
            )
        }
        return SwiftDarwinLiteralPreflight.exitCode(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            lineNumber: lineNumber,
            asciiBoundary: asciiBoundary
        )
    }
    #endif

    private static func darwinLiteralPreflightArguments(
        afterStrippingLeadingEngineSelectorFrom arguments: [String]
    ) -> (arguments: [String], allowPCREQuotedLiterals: Bool) {
        guard let first = arguments.first else {
            return (arguments, false)
        }
        if isSingleArgumentEngineSelector(first) {
            return (
                Array(arguments.dropFirst()),
                singleArgumentEngineSelectorAllowsPCREQuotedLiterals(first)
            )
        }
        if arguments.count >= 2,
           first == "--engine",
           isEngineSelectorValue(arguments[1]) {
            return (
                Array(arguments.dropFirst(2)),
                engineSelectorValueAllowsPCREQuotedLiterals(arguments[1])
            )
        }
        return (arguments, false)
    }

    private static func isSingleArgumentEngineSelector(_ argument: String) -> Bool {
        switch argument {
        case "-P",
             "--pcre2",
             "--no-pcre2",
             "--auto-hybrid-regex",
             "--no-auto-hybrid-regex",
             "--engine=default",
             "--engine=pcre2",
             "--engine=auto":
            return true
        default:
            return false
        }
    }

    private static func isEngineSelectorValue(_ value: String) -> Bool {
        switch value {
        case "default", "pcre2", "auto":
            return true
        default:
            return false
        }
    }

    private static func singleArgumentEngineSelectorAllowsPCREQuotedLiterals(_ argument: String) -> Bool {
        switch argument {
        case "-P",
             "--pcre2",
             "--auto-hybrid-regex",
             "--engine=pcre2",
             "--engine=auto":
            return true
        default:
            return false
        }
    }

    private static func engineSelectorValueAllowsPCREQuotedLiterals(_ value: String) -> Bool {
        value == "pcre2" || value == "auto"
    }

    private static func surroundingWordsLiteral(
        _ pattern: String,
        allowPCREQuotedLiterals: Bool
    ) -> String? {
        var pattern = pattern
        if pattern.hasPrefix("(?-u)") {
            pattern.removeFirst("(?-u)".count)
        }
        let prefix = #"\w+\s+"#
        let suffix = #"\s+\w+"#
        guard pattern.hasPrefix(prefix), pattern.hasSuffix(suffix) else {
            return nil
        }
        let literalStart = pattern.index(pattern.startIndex, offsetBy: prefix.count)
        let literalEnd = pattern.index(pattern.endIndex, offsetBy: -suffix.count)
        return RegexLiteralParser.literal(
            fromPlainRegexPattern: String(pattern[literalStart..<literalEnd]),
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
        )
    }

    private static func asciiBoundaryLiteral(
        _ pattern: String,
        allowPCREQuotedLiterals: Bool
    ) -> String? {
        let boundary = #"(?-u:\b)"#
        guard pattern.hasPrefix(boundary), pattern.hasSuffix(boundary) else {
            return nil
        }
        let literalStart = pattern.index(pattern.startIndex, offsetBy: boundary.count)
        let literalEnd = pattern.index(pattern.endIndex, offsetBy: -boundary.count)
        return RegexLiteralParser.literal(
            fromPlainRegexPattern: String(pattern[literalStart..<literalEnd]),
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
        )
    }

    private static func singleByteAlternation(
        _ pattern: String,
        allowPCREQuotedLiterals: Bool
    ) -> [UInt8]? {
        let parts = pattern.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count > 1 else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(parts.count)
        for part in parts {
            guard let literal = RegexLiteralParser.literal(
                fromPlainRegexPattern: String(part),
                allowPCREQuotedLiterals: allowPCREQuotedLiterals
            ),
                  literal.utf8.count == 1,
                  let byte = literal.utf8.first,
                  byte < 0x80 else {
                return nil
            }
            bytes.append(byte)
        }
        return bytes
    }

    private static func multiLiteralAlternation(
        _ pattern: String,
        allowPCREQuotedLiterals: Bool
    ) -> [[UInt8]]? {
        let alternatives = RegexLiteralParser.topLevelAlternatives(in: pattern)
        guard alternatives.count > 1,
              alternatives.count <= 64 else {
            return nil
        }
        let literals = alternatives.compactMap {
            RegexLiteralParser.literal(
                fromPlainRegexPattern: $0,
                allowPCREQuotedLiterals: allowPCREQuotedLiterals
            )
        }
        guard literals.count == alternatives.count else {
            return nil
        }
        let literalBytes = literals.map { Array($0.utf8) }
        return literalBytes.allSatisfy { !$0.isEmpty } ? literalBytes : nil
    }
    #endif
}
