import Foundation
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
        enum PathOnlyMode {
            case matching
            case nonMatching
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
        func isLineRegexpFlag(_ argument: String) -> Bool {
            argument == "-x" || argument == "--line-regexp"
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
        func isQuietFlag(_ argument: String) -> Bool {
            argument == "-q" || argument == "--quiet"
        }
        func isCountFlag(_ argument: String) -> Bool {
            argument == "-c" || argument == "--count"
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
        func inlineEngineSelectorValue(_ argument: String) -> String? {
            argument.hasPrefix("--engine=")
                ? String(argument.dropFirst("--engine=".count))
                : nil
        }
        func inlineHyperlinkFormatValue(_ argument: String) -> String? {
            argument.hasPrefix("--hyperlink-format=")
                ? String(argument.dropFirst("--hyperlink-format=".count))
                : nil
        }
        func isPreflightNeutralHyperlinkFormat(_ value: String) -> Bool {
            switch value {
            case "",
                 "default",
                 "none",
                 "cursor",
                 "file",
                 "grep+",
                 "kitty",
                 "macvim",
                 "textmate",
                 "vscode",
                 "vscode-insiders",
                 "vscodium":
                return true
            default:
                return false
            }
        }
        func inlinePreprocessorValue(_ argument: String) -> String? {
            argument.hasPrefix("--pre=")
                ? String(argument.dropFirst("--pre=".count))
                : nil
        }
        func inlinePreGlobValue(_ argument: String) -> String? {
            argument.hasPrefix("--pre-glob=")
                ? String(argument.dropFirst("--pre-glob=".count))
                : nil
        }
        func hasUnclosedCharacterClass(in pattern: String) -> Bool {
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
        func isValidStrictGlob(_ raw: String) -> Bool {
            !hasUnclosedCharacterClass(in: raw)
        }
        func inlineIgnoreFileValue(_ argument: String) -> String? {
            argument.hasPrefix("--ignore-file=")
                ? String(argument.dropFirst("--ignore-file=".count))
                : nil
        }
        func isReadableRegularFile(_ path: String) -> Bool {
            guard let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType,
                  type == .typeRegular else {
                return false
            }
            return FileManager.default.isReadableFile(atPath: path)
        }
        func inlineGlobValue(_ argument: String) -> String? {
            if argument.hasPrefix("--glob=") {
                return String(argument.dropFirst("--glob=".count))
            }
            if argument.hasPrefix("-g"), argument.count > 2 {
                return String(argument.dropFirst(2))
            }
            return nil
        }
        func inlineCaseInsensitiveGlobValue(_ argument: String) -> String? {
            argument.hasPrefix("--iglob=")
                ? String(argument.dropFirst("--iglob=".count))
                : nil
        }
        func inlineTypeAddValue(_ argument: String) -> String? {
            argument.hasPrefix("--type-add=")
                ? String(argument.dropFirst("--type-add=".count))
                : nil
        }
        func inlineTypeClearValue(_ argument: String) -> String? {
            argument.hasPrefix("--type-clear=")
                ? String(argument.dropFirst("--type-clear=".count))
                : nil
        }
        func inlineTypeSelectValue(_ argument: String) -> String? {
            if argument.hasPrefix("--type=") {
                return String(argument.dropFirst("--type=".count))
            }
            if argument.hasPrefix("-t"), argument.count > 2 {
                return String(argument.dropFirst(2))
            }
            return nil
        }
        func inlineTypeNegateValue(_ argument: String) -> String? {
            if argument.hasPrefix("--type-not=") {
                return String(argument.dropFirst("--type-not=".count))
            }
            if argument.hasPrefix("-T"), argument.count > 2 {
                return String(argument.dropFirst(2))
            }
            return nil
        }
        func typeDefinitionChangesAreValid(_ changes: [TypeChange]) -> Bool {
            guard !changes.isEmpty else {
                return true
            }
            var registry = FileTypeRegistry()
            return registry.apply(changes).isEmpty
        }
        func isOutputNeutralSingleFileFlag(_ argument: String) -> Bool {
            switch argument {
            case "-.",
                 "-0",
                 "-a",
                 "-U",
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
                 "--include-zero",
                 "--binary",
                 "--crlf",
                 "--follow",
                 "--glob-case-insensitive",
                 "--no-block-buffered",
                 "--no-binary",
                 "--no-context-separator",
                 "--no-crlf",
                 "--no-follow",
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
                 "--no-encoding",
                 "--no-glob-case-insensitive",
                 "--no-include-zero",
                 "--no-invert-match",
                 "--no-json",
                 "--no-max-columns-preview",
                 "--multiline",
                 "--multiline-dotall",
                 "--no-multiline",
                 "--no-multiline-dotall",
                 "--no-search-zip",
                 "--no-sort-files",
                 "--no-stats",
                 "--text",
                 "--no-text",
                 "--no-config",
                 "--null",
                 "--no-one-file-system",
                 "--no-pre",
                 "--no-require-git",
                 "--no-pcre2-unicode",
                 "--no-unicode",
                 "--max-columns-preview",
                 "--one-file-system",
                 "--pcre2-unicode",
                 "--sort-files",
                 "--unicode",
                 "--require-git":
                return true
            default:
                return isBufferingFlag(argument) || isMessageFlag(argument)
            }
        }
        func unrestrictedRepeatCount(_ argument: String) -> Int? {
            switch argument {
            case "-u", "--unrestricted":
                return 1
            case "-uu":
                return 2
            case "-uuu":
                return 3
            default:
                return nil
            }
        }
        func isValidNonNegativeInteger(_ value: String) -> Bool {
            guard !value.hasPrefix("-"),
                  Int(value) != nil else {
                return false
            }
            return true
        }
        func nonNegativeInteger(_ value: String) -> Int? {
            guard !value.hasPrefix("-"),
                  let number = Int(value) else {
                return nil
            }
            return number
        }
        func inlineMaxCountValue(_ argument: String) -> String? {
            if argument.hasPrefix("--max-count=") {
                return String(argument.dropFirst("--max-count=".count))
            }
            if argument.hasPrefix("-m"), argument.count > 2 {
                return String(argument.dropFirst(2))
            }
            return nil
        }
        func isSeparatedMaxCountFlag(_ argument: String) -> Bool {
            argument == "-m" || argument == "--max-count"
        }
        func inlineThreadCount(_ argument: String) -> String? {
            if argument.hasPrefix("--threads=") {
                return String(argument.dropFirst("--threads=".count))
            }
            if argument.hasPrefix("-j"), argument.count > 2 {
                return String(argument.dropFirst(2))
            }
            return nil
        }
        func isValidSortValue(_ value: String) -> Bool {
            switch value {
            case "none", "path", "modified", "accessed", "created":
                return true
            default:
                return false
            }
        }
        func inlineSortValue(_ argument: String) -> String? {
            if argument.hasPrefix("--sort=") {
                return String(argument.dropFirst("--sort=".count))
            }
            if argument.hasPrefix("--sortr=") {
                return String(argument.dropFirst("--sortr=".count))
            }
            return nil
        }
        func zeroValueOption(_ argument: String) -> String? {
            let inlinePrefixes = [
                "--after-context=",
                "--before-context=",
                "--context=",
                "--max-columns=",
                "--max-depth=",
                "--maxdepth=",
            ]
            for prefix in inlinePrefixes where argument.hasPrefix(prefix) {
                return String(argument.dropFirst(prefix.count))
            }
            let shortPrefixes = ["-A", "-B", "-C", "-M", "-d"]
            for prefix in shortPrefixes where argument.hasPrefix(prefix) && argument.count > prefix.count {
                return String(argument.dropFirst(prefix.count))
            }
            return nil
        }
        func isSeparatedZeroValueFlag(_ argument: String) -> Bool {
            switch argument {
            case "-A",
                 "-B",
                 "-C",
                 "-M",
                 "-d",
                 "--after-context",
                 "--before-context",
                 "--context",
                 "--max-columns",
                 "--max-depth",
                 "--maxdepth":
                return true
            default:
                return false
            }
        }
        func isZeroInteger(_ value: String) -> Bool {
            guard !value.hasPrefix("-"),
                  let number = Int(value) else {
                return false
            }
            return number == 0
        }
        func isSeparatedNeutralValueFlag(_ argument: String) -> Bool {
            switch argument {
            case "--context-separator",
                 "--field-context-separator",
                 "--hostname-bin":
                return true
            default:
                return false
            }
        }
        func isInlineNeutralValueFlag(_ argument: String) -> Bool {
            let prefixes = [
                "--context-separator=",
                "--field-context-separator=",
                "--hostname-bin=",
            ]
            return prefixes.contains { argument.hasPrefix($0) }
        }
        func isInlineFieldMatchSeparator(_ argument: String) -> Bool {
            argument.hasPrefix("--field-match-separator=")
        }
        func pathSeparatorValue(_ argument: String) -> String? {
            argument.hasPrefix("--path-separator=")
                ? String(argument.dropFirst("--path-separator=".count))
                : nil
        }
        func isValidSimplePathSeparator(_ value: String) -> Bool {
            value.isEmpty || value.utf8.count == 1
        }
        func resourceLimitValue(_ argument: String) -> String? {
            if argument.hasPrefix("--dfa-size-limit=") {
                return String(argument.dropFirst("--dfa-size-limit=".count))
            }
            if argument.hasPrefix("--regex-size-limit=") {
                return String(argument.dropFirst("--regex-size-limit=".count))
            }
            return nil
        }
        func isResourceLimitFlag(_ argument: String) -> Bool {
            argument == "--dfa-size-limit" || argument == "--regex-size-limit"
        }
        func maxFilesizeValue(_ argument: String) -> String? {
            argument.hasPrefix("--max-filesize=")
                ? String(argument.dropFirst("--max-filesize=".count))
                : nil
        }
        func encodingValue(_ argument: String) -> String? {
            if argument.hasPrefix("--encoding=") {
                return String(argument.dropFirst("--encoding=".count))
            }
            if argument.hasPrefix("-E"), argument.count > 2 {
                return String(argument.dropFirst(2))
            }
            return nil
        }
        func isValidHumanReadableSize(_ raw: String) -> Bool {
            guard !raw.isEmpty else {
                return false
            }
            let multiplier: UInt64
            let digits: Substring
            switch raw.last {
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
            guard !digits.isEmpty,
                  digits.allSatisfy(\.isNumber),
                  let value = UInt64(digits) else {
                return false
            }
            return !value.multipliedReportingOverflow(by: multiplier).overflow
        }
        func shortFlagCluster(
            _ argument: String
        ) -> (
            caseMode: CaseMode?,
            lineNumber: Bool?,
            lineRegexp: Bool?,
            wordRegexp: Bool,
            fixedStrings: Bool,
            allowPCREQuotedLiterals: Bool?,
            quiet: Bool,
            count: Bool,
            pathOnlyMode: PathOnlyMode?,
            unrestrictedCount: Int
        )? {
            let bytes = Array(argument.utf8)
            guard bytes.count > 2,
                  bytes.first == UInt8(ascii: "-"),
                  bytes.dropFirst().first != UInt8(ascii: "-") else {
                return nil
            }

            var caseMode: CaseMode?
            var lineNumber: Bool?
            var lineRegexp: Bool?
            var wordRegexp = false
            var fixedStrings = false
            var allowPCREQuotedLiterals: Bool?
            var quiet = false
            var count = false
            var pathOnlyMode: PathOnlyMode?
            var unrestrictedCount = 0
            for byte in bytes.dropFirst() {
                switch byte {
                case UInt8(ascii: "i"):
                    caseMode = .insensitive
                case UInt8(ascii: "s"):
                    caseMode = .sensitive
                case UInt8(ascii: "S"):
                    caseMode = .smart
                case UInt8(ascii: "U"):
                    continue
                case UInt8(ascii: "n"):
                    lineNumber = true
                case UInt8(ascii: "N"):
                    lineNumber = false
                case UInt8(ascii: "w"):
                    wordRegexp = true
                    lineRegexp = false
                case UInt8(ascii: "x"):
                    wordRegexp = false
                    lineRegexp = true
                case UInt8(ascii: "F"):
                    fixedStrings = true
                case UInt8(ascii: "L"):
                    continue
                case UInt8(ascii: "P"):
                    allowPCREQuotedLiterals = true
                case UInt8(ascii: "a"):
                    continue
                case UInt8(ascii: "q"):
                    quiet = true
                case UInt8(ascii: "c"):
                    count = true
                case UInt8(ascii: "l"):
                    pathOnlyMode = .matching
                case UInt8(ascii: "u"):
                    unrestrictedCount += 1
                    guard unrestrictedCount <= 3 else {
                        return nil
                    }
                default:
                    return nil
                }
            }
            return (
                caseMode,
                lineNumber,
                lineRegexp,
                wordRegexp,
                fixedStrings,
                allowPCREQuotedLiterals,
                quiet,
                count,
                pathOnlyMode,
                unrestrictedCount
            )
        }
        var allowPCREQuotedLiterals = preflightArguments.allowPCREQuotedLiterals
        var parsedCaseMode = CaseMode.sensitive
        var parsedByteOffset = false
        var parsedColumn = false
        var parsedColorMayEmit = false
        var parsedFixedStrings = false
        var parsedFieldMatchSeparator = false
        var parsedHeading = false
        var parsedIncludeZero = false
        var parsedJson = false
        var parsedLineNumber = false
        var parsedLineRegexp = false
        var parsedLineBuffered = false
        var parsedNullPathTerminator = false
        var parsedNoMmap = false
        var parsedPathOnlyMode: PathOnlyMode?
        var parsedPathSeparator = false
        var parsedQuiet = false
        var parsedSearchZip = false
        var parsedMaxCount: Int?
        var parsedCount = false
        var parsedStats = false
        var parsedTrim = false
        var parsedTypeDefinitionChanges: [TypeChange] = []
        var parsedUnrestrictedCount = 0
        var parsedWithFilename = false
        var parsedWordRegexp = false
        var parsedCrlf = false
        var parsedIgnoreFilesEnabled = true
        var parsedIgnoreFilePaths: [String] = []
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
            } else if isLineRegexpFlag(argument) {
                parsedLineRegexp = true
                parsedWordRegexp = false
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
            } else if argument == "-l" || argument == "--files-with-matches" {
                parsedPathOnlyMode = .matching
            } else if argument == "--files-without-match" {
                parsedPathOnlyMode = .nonMatching
            } else if isCountFlag(argument) {
                parsedCount = true
            } else if argument == "--include-zero" {
                parsedIncludeZero = true
            } else if argument == "--no-include-zero" {
                parsedIncludeZero = false
            } else if argument == "-0" || argument == "--null" {
                parsedNullPathTerminator = true
            } else if argument == "-nw" || argument == "-wn" {
                parsedLineNumber = true
                parsedWordRegexp = true
                parsedLineRegexp = false
            } else if argument == "-w" || argument == "--word-regexp" {
                parsedWordRegexp = true
                parsedLineRegexp = false
            } else if isQuietFlag(argument) {
                parsedQuiet = true
            } else if argument == "--json" {
                parsedJson = true
            } else if argument == "--no-json" {
                parsedJson = false
            } else if argument == "--stats" {
                parsedStats = true
            } else if argument == "--no-stats" {
                parsedStats = false
            } else if argument == "-z" || argument == "--search-zip" {
                parsedSearchZip = true
            } else if argument == "--no-search-zip" {
                parsedSearchZip = false
            } else if argument == "--line-buffered" {
                parsedLineBuffered = true
            } else if argument == "--block-buffered" || argument == "--no-line-buffered" {
                parsedLineBuffered = false
            } else if argument == "--no-mmap" {
                parsedNoMmap = true
            } else if isMmapFlag(argument) {
                parsedNoMmap = false
            } else if argument == "--crlf" {
                parsedCrlf = true
            } else if argument == "--no-crlf" {
                parsedCrlf = false
            } else if isSeparatedMaxCountFlag(argument) {
                guard argumentIndex < arguments.count,
                      let maxCount = nonNegativeInteger(arguments[argumentIndex]) else {
                    return nil
                }
                parsedMaxCount = maxCount
                argumentIndex += 1
            } else if let maxCount = inlineMaxCountValue(argument) {
                guard let maxCount = nonNegativeInteger(maxCount) else {
                    return nil
                }
                parsedMaxCount = maxCount
            } else if argument == "--engine" {
                guard argumentIndex < arguments.count,
                      isEngineSelectorValue(arguments[argumentIndex]) else {
                    return nil
                }
                allowPCREQuotedLiterals = engineSelectorValueAllowsPCREQuotedLiterals(arguments[argumentIndex])
                argumentIndex += 1
            } else if let engineValue = inlineEngineSelectorValue(argument) {
                guard isEngineSelectorValue(engineValue) else {
                    return nil
                }
                allowPCREQuotedLiterals = engineSelectorValueAllowsPCREQuotedLiterals(engineValue)
            } else if isSingleArgumentEngineSelector(argument) {
                allowPCREQuotedLiterals = singleArgumentEngineSelectorAllowsPCREQuotedLiterals(argument)
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
            } else if argument == "--hyperlink-format" {
                guard argumentIndex < arguments.count,
                      isPreflightNeutralHyperlinkFormat(arguments[argumentIndex]) else {
                    return nil
                }
                argumentIndex += 1
            } else if let hyperlinkFormat = inlineHyperlinkFormatValue(argument) {
                guard isPreflightNeutralHyperlinkFormat(hyperlinkFormat) else {
                    return nil
                }
            } else if argument == "--pre" {
                guard argumentIndex < arguments.count,
                      arguments[argumentIndex].isEmpty else {
                    return nil
                }
                argumentIndex += 1
            } else if let preprocessor = inlinePreprocessorValue(argument) {
                guard preprocessor.isEmpty else {
                    return nil
                }
            } else if argument == "--pre-glob" {
                guard argumentIndex < arguments.count,
                      isValidStrictGlob(arguments[argumentIndex]) else {
                    return nil
                }
                argumentIndex += 1
            } else if let preGlob = inlinePreGlobValue(argument) {
                guard isValidStrictGlob(preGlob) else {
                    return nil
                }
            } else if argument == "-g" || argument == "--glob" || argument == "--iglob" {
                guard argumentIndex < arguments.count,
                      isValidStrictGlob(arguments[argumentIndex]) else {
                    return nil
                }
                argumentIndex += 1
            } else if let glob = inlineGlobValue(argument) {
                guard isValidStrictGlob(glob) else {
                    return nil
                }
            } else if let caseInsensitiveGlob = inlineCaseInsensitiveGlobValue(argument) {
                guard isValidStrictGlob(caseInsensitiveGlob) else {
                    return nil
                }
            } else if argument == "--ignore-file" {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                parsedIgnoreFilePaths.append(arguments[argumentIndex])
                argumentIndex += 1
            } else if let ignoreFile = inlineIgnoreFileValue(argument) {
                parsedIgnoreFilePaths.append(ignoreFile)
            } else if argument == "--ignore-file-case-insensitive"
                        || argument == "--no-ignore-file-case-insensitive" {
                continue
            } else if argument == "--ignore-files" {
                parsedIgnoreFilesEnabled = true
            } else if argument == "--no-ignore-files" {
                parsedIgnoreFilesEnabled = false
            } else if argument == "--type-add" {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                parsedTypeDefinitionChanges.append(.add(arguments[argumentIndex]))
                argumentIndex += 1
            } else if let typeAdd = inlineTypeAddValue(argument) {
                parsedTypeDefinitionChanges.append(.add(typeAdd))
            } else if argument == "--type-clear" {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                parsedTypeDefinitionChanges.append(.clear(arguments[argumentIndex]))
                argumentIndex += 1
            } else if let typeClear = inlineTypeClearValue(argument) {
                parsedTypeDefinitionChanges.append(.clear(typeClear))
            } else if argument == "-t" || argument == "--type" {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                parsedTypeDefinitionChanges.append(.select(arguments[argumentIndex]))
                argumentIndex += 1
            } else if let typeSelect = inlineTypeSelectValue(argument) {
                parsedTypeDefinitionChanges.append(.select(typeSelect))
            } else if argument == "-T" || argument == "--type-not" {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                parsedTypeDefinitionChanges.append(.negate(arguments[argumentIndex]))
                argumentIndex += 1
            } else if let typeNegate = inlineTypeNegateValue(argument) {
                parsedTypeDefinitionChanges.append(.negate(typeNegate))
            } else if argument == "--sort" || argument == "--sortr" {
                guard argumentIndex < arguments.count,
                      isValidSortValue(arguments[argumentIndex]) else {
                    return nil
                }
                argumentIndex += 1
            } else if let sortValue = inlineSortValue(argument) {
                guard isValidSortValue(sortValue) else {
                    return nil
                }
            } else if argument == "-j" || argument == "--threads" {
                guard argumentIndex < arguments.count,
                      isValidNonNegativeInteger(arguments[argumentIndex]) else {
                    return nil
                }
                argumentIndex += 1
            } else if let threadCount = inlineThreadCount(argument) {
                guard isValidNonNegativeInteger(threadCount) else {
                    return nil
                }
            } else if isSeparatedZeroValueFlag(argument) {
                guard argumentIndex < arguments.count,
                      isZeroInteger(arguments[argumentIndex]) else {
                    return nil
                }
                argumentIndex += 1
            } else if let zeroValue = zeroValueOption(argument) {
                guard isZeroInteger(zeroValue) else {
                    return nil
                }
            } else if argument == "--field-match-separator" {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                parsedFieldMatchSeparator = true
                argumentIndex += 1
            } else if isInlineFieldMatchSeparator(argument) {
                parsedFieldMatchSeparator = true
            } else if isSeparatedNeutralValueFlag(argument) {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                argumentIndex += 1
            } else if isInlineNeutralValueFlag(argument) {
                continue
            } else if argument == "--path-separator" {
                guard argumentIndex < arguments.count,
                      isValidSimplePathSeparator(arguments[argumentIndex]) else {
                    return nil
                }
                parsedPathSeparator = true
                argumentIndex += 1
            } else if let separator = pathSeparatorValue(argument) {
                guard isValidSimplePathSeparator(separator) else {
                    return nil
                }
                parsedPathSeparator = true
            } else if isResourceLimitFlag(argument) {
                guard argumentIndex < arguments.count,
                      isValidHumanReadableSize(arguments[argumentIndex]) else {
                    return nil
                }
                argumentIndex += 1
            } else if let resourceLimit = resourceLimitValue(argument) {
                guard isValidHumanReadableSize(resourceLimit) else {
                    return nil
                }
            } else if argument == "--max-filesize" {
                guard argumentIndex < arguments.count,
                      isValidHumanReadableSize(arguments[argumentIndex]) else {
                    return nil
                }
                argumentIndex += 1
            } else if let maxFilesize = maxFilesizeValue(argument) {
                guard isValidHumanReadableSize(maxFilesize) else {
                    return nil
                }
            } else if argument == "-E" || argument == "--encoding" {
                guard argumentIndex < arguments.count,
                      arguments[argumentIndex] == "auto" else {
                    return nil
                }
                argumentIndex += 1
            } else if let encoding = encodingValue(argument) {
                guard encoding == "auto" else {
                    return nil
                }
            } else if let unrestrictedCount = unrestrictedRepeatCount(argument) {
                parsedUnrestrictedCount += unrestrictedCount
                guard parsedUnrestrictedCount <= 3 else {
                    return nil
                }
            } else if isOutputNeutralSingleFileFlag(argument) {
                continue
            } else if let cluster = shortFlagCluster(argument) {
                if let caseMode = cluster.caseMode {
                    parsedCaseMode = caseMode
                }
                if let lineNumber = cluster.lineNumber {
                    parsedLineNumber = lineNumber
                }
                if let lineRegexp = cluster.lineRegexp {
                    parsedLineRegexp = lineRegexp
                }
                if cluster.wordRegexp {
                    parsedWordRegexp = true
                    parsedLineRegexp = false
                }
                parsedFixedStrings = parsedFixedStrings || cluster.fixedStrings
                if let clusterPCREQuotedLiterals = cluster.allowPCREQuotedLiterals {
                    allowPCREQuotedLiterals = clusterPCREQuotedLiterals
                }
                parsedQuiet = parsedQuiet || cluster.quiet
                parsedCount = parsedCount || cluster.count
                if let clusterPathOnlyMode = cluster.pathOnlyMode {
                    parsedPathOnlyMode = clusterPathOnlyMode
                }
                parsedUnrestrictedCount += cluster.unrestrictedCount
                guard parsedUnrestrictedCount <= 3 else {
                    return nil
                }
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
        if parsedIgnoreFilesEnabled {
            guard parsedIgnoreFilePaths.allSatisfy(isReadableRegularFile) else {
                return nil
            }
        }
        guard typeDefinitionChangesAreValid(parsedTypeDefinitionChanges) else {
            return nil
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
        guard !(parsedLineRegexp && wordRegexp) else {
            return nil
        }
        guard !parsedByteOffset,
              !parsedColumn,
              !parsedColorMayEmit,
              !(parsedFieldMatchSeparator && lineNumber),
              !parsedHeading,
              !parsedJson,
              !parsedSearchZip,
              !parsedStats,
              !parsedTrim,
              !parsedWithFilename else {
            return nil
        }

        if !fixedStrings,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-",
           !asciiCaseInsensitive,
           !wordRegexp,
           !parsedLineRegexp,
           !parsedLineBuffered,
           !noMmap,
           !parsedCount,
           parsedMaxCount == nil,
           let surroundingLiteral = surroundingWordsLiteral(
            pattern,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
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
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
        )
        let asciiBoundary = asciiBoundaryLiteralPattern != nil
        let parsedLiteralPattern = fixedStrings
            ? pattern
            : asciiBoundaryLiteralPattern ?? RegexLiteralParser.literal(
                fromPlainRegexPattern: pattern,
                allowPCREQuotedLiterals: allowPCREQuotedLiterals
            )

        if !fixedStrings,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-",
           !wordRegexp,
           !parsedLineRegexp,
           !asciiBoundary,
           !parsedCount,
           parsedMaxCount == nil,
           let literals = multiLiteralAlternation(
            pattern,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
           ) {
            if asciiCaseInsensitive {
                if parsedQuiet {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralQuietExitCode(
                        path: path,
                        literals: literals
                    )
                }
                if let parsedPathOnlyMode {
                    guard !parsedPathSeparator else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralPathOnlyExitCode(
                        path: path,
                        literals: literals,
                        printWhenMatched: parsedPathOnlyMode == .matching,
                        nullTerminated: parsedNullPathTerminator
                    )
                }
            } else {
                if parsedQuiet {
                    return SwiftDarwinLiteralPreflight.multiLiteralQuietExitCode(
                        path: path,
                        literals: literals
                    )
                }
                if let parsedPathOnlyMode {
                    guard !parsedPathSeparator else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.multiLiteralPathOnlyExitCode(
                        path: path,
                        literals: literals,
                        printWhenMatched: parsedPathOnlyMode == .matching,
                        nullTerminated: parsedNullPathTerminator
                    )
                }
                guard !parsedLineBuffered else {
                    return nil
                }
                if let exitCode = SwiftDarwinLiteralPreflight.multiLiteralExitCode(
                    path: path,
                    literals: literals,
                    lineNumber: lineNumber
                ) {
                    return exitCode
                }
            }
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
        if parsedMaxCount == 0 {
            return nil
        }
        if parsedQuiet {
            guard !asciiBoundary else {
                return nil
            }
            if asciiCaseInsensitive {
                guard !wordRegexp else {
                    return nil
                }
                if parsedLineRegexp {
                    guard !parsedCrlf else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLineQuietExitCode(
                        path: path,
                        literal: literal
                    )
                }
                return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveQuietExitCode(
                    path: path,
                    literal: literal
                )
            }
            if wordRegexp {
                return SwiftDarwinLiteralPreflight.wordQuietExitCode(
                    path: path,
                    literal: literal
                )
            }
            if parsedLineRegexp {
                guard !parsedCrlf else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.exactLineQuietExitCode(
                    path: path,
                    literal: literal
                )
            }
            return SwiftDarwinLiteralPreflight.quietExitCode(
                path: path,
                literal: literal
            )
        }
        if parsedCount {
            guard parsedPathOnlyMode == nil,
                  !wordRegexp,
                  !asciiBoundary else {
                return nil
            }
            if asciiCaseInsensitive {
                guard let parsedMaxCount else {
                    return nil
                }
                if parsedLineRegexp {
                    guard !parsedCrlf else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLineCountExitCode(
                        path: path,
                        literal: literal,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount
                    )
                }
                return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveLimitedCountLineExitCode(
                    path: path,
                    literal: literal,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount
                )
            }
            if parsedLineRegexp {
                guard !parsedCrlf else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.exactLineCountExitCode(
                    path: path,
                    literal: literal,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount
                )
            }
            guard let parsedMaxCount else {
                return nil
            }
            return SwiftDarwinLiteralPreflight.countLineExitCode(
                path: path,
                literal: literal,
                includeZero: parsedIncludeZero,
                maxCount: parsedMaxCount
            )
        }
        if let parsedPathOnlyMode {
            guard !asciiBoundary,
                  !parsedPathSeparator else {
                return nil
            }
            if asciiCaseInsensitive {
                guard !wordRegexp else {
                    return nil
                }
                if parsedLineRegexp {
                    guard !parsedCrlf else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLinePathOnlyExitCode(
                        path: path,
                        literal: literal,
                        printWhenMatched: parsedPathOnlyMode == .matching,
                        nullTerminated: parsedNullPathTerminator
                    )
                }
                return SwiftDarwinLiteralPreflight.asciiCaseInsensitivePathOnlyExitCode(
                    path: path,
                    literal: literal,
                    printWhenMatched: parsedPathOnlyMode == .matching,
                    nullTerminated: parsedNullPathTerminator
                )
            }
            if wordRegexp {
                return SwiftDarwinLiteralPreflight.wordPathOnlyExitCode(
                    path: path,
                    literal: literal,
                    printWhenMatched: parsedPathOnlyMode == .matching,
                    nullTerminated: parsedNullPathTerminator
                )
            }
            if parsedLineRegexp {
                guard !parsedCrlf else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.exactLinePathOnlyExitCode(
                    path: path,
                    literal: literal,
                    printWhenMatched: parsedPathOnlyMode == .matching,
                    nullTerminated: parsedNullPathTerminator
                )
            }
            return SwiftDarwinLiteralPreflight.pathOnlyExitCode(
                path: path,
                literal: literal,
                printWhenMatched: parsedPathOnlyMode == .matching,
                nullTerminated: parsedNullPathTerminator
            )
        }
        guard !parsedLineBuffered else {
            return nil
        }
        if parsedLineRegexp {
            guard !asciiCaseInsensitive,
                  !asciiBoundary,
                  !parsedCrlf,
                  !parsedCount,
                  parsedPathOnlyMode == nil,
                  !parsedQuiet else {
                return nil
            }
            return SwiftDarwinLiteralPreflight.exactLineExitCode(
                path: path,
                literal: literal,
                maxCount: parsedMaxCount,
                lineNumber: lineNumber
            )
        }
        if let parsedMaxCount {
            guard !wordRegexp,
                  !asciiCaseInsensitive,
                  !asciiBoundary else {
                return nil
            }
            return SwiftDarwinLiteralPreflight.limitedLineExitCode(
                path: path,
                literal: literal,
                maxCount: parsedMaxCount,
                lineNumber: lineNumber
            )
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
