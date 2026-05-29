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
    private static func preflightEscapedSeparatorBytes(_ raw: String) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(raw.utf8.count)
        var index = raw.startIndex

        while index < raw.endIndex {
            let character = raw[index]
            guard character == "\\" else {
                output.append(contentsOf: String(character).utf8)
                index = raw.index(after: index)
                continue
            }

            let nextIndex = raw.index(after: index)
            guard nextIndex < raw.endIndex else {
                output.append(UInt8(ascii: "\\"))
                index = nextIndex
                continue
            }

            let next = raw[nextIndex]
            switch next {
            case "0":
                output.append(0)
                index = raw.index(after: nextIndex)
            case "n":
                output.append(UInt8(ascii: "\n"))
                index = raw.index(after: nextIndex)
            case "r":
                output.append(UInt8(ascii: "\r"))
                index = raw.index(after: nextIndex)
            case "t":
                output.append(UInt8(ascii: "\t"))
                index = raw.index(after: nextIndex)
            case "\\":
                output.append(UInt8(ascii: "\\"))
                index = raw.index(after: nextIndex)
            case "x":
                let firstHex = raw.index(after: nextIndex)
                guard firstHex < raw.endIndex else {
                    output.append(contentsOf: "\\x".utf8)
                    index = firstHex
                    continue
                }
                let secondHex = raw.index(after: firstHex)
                guard secondHex < raw.endIndex else {
                    output.append(contentsOf: "\\x".utf8)
                    output.append(contentsOf: String(raw[firstHex]).utf8)
                    index = secondHex
                    continue
                }
                let hex = String(raw[firstHex...secondHex])
                if let scalarValue = UInt32(hex, radix: 16),
                   let scalar = UnicodeScalar(scalarValue) {
                    output.append(contentsOf: String(Character(scalar)).utf8)
                } else {
                    output.append(contentsOf: "\\x\(hex)".utf8)
                }
                index = raw.index(after: secondHex)
            default:
                output.append(contentsOf: String(next).utf8)
                index = raw.index(after: nextIndex)
            }
        }

        return output
    }

    private enum PreflightPathSeparator {
        case automatic
        case separator(UInt8)
    }

    private static func preflightPathSeparator(_ raw: String) -> PreflightPathSeparator? {
        guard !raw.isEmpty else {
            return .automatic
        }
        let bytes = preflightEscapedSeparatorBytes(raw)
        guard bytes.count == 1,
              let byte = bytes.first else {
            return nil
        }
        return .separator(byte)
    }

    private static func preflightDisplayPathBytes(
        _ path: String,
        pathSeparator: UInt8?
    ) -> [UInt8] {
        let normalizedPath = path.utf8.allSatisfy { $0 < 0x80 }
            ? path
            : path.precomposedStringWithCanonicalMapping
        let bytes = Array(normalizedPath.utf8)
        guard let pathSeparator else {
            return bytes
        }
        return bytes.map { byte in
            byte == UInt8(ascii: "/") ? pathSeparator : byte
        }
    }

    private static func runSwiftDarwinLiteralPreflight(arguments: [String]) -> Int32? {
        let preflightArguments = darwinLiteralPreflightArguments(
            afterStrippingLeadingEngineSelectorFrom: arguments
        )
        let arguments = preflightArguments.arguments
        guard getenv("RIPGREP_CONFIG_PATH") == nil || leadingArgumentsDisableConfigForPreflight(arguments) else {
            return nil
        }

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
        enum PrintMode {
            case matchingLines
            case count
            case countMatches
            case filesWithMatches
            case filesWithoutMatch
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
        func isOnlyMatchingFlag(_ argument: String) -> Bool {
            argument == "-o" || argument == "--only-matching"
        }
        func colorModePreflightState(_ value: String) -> (mayEmit: Bool, forcesANSI: Bool)? {
            switch value {
            case "never":
                return (false, false)
            case "always", "ansi":
                return (true, true)
            case "auto":
                return (true, false)
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
        func inlinePatternFileValue(_ argument: String) -> String? {
            if argument.hasPrefix("--file=") {
                return String(argument.dropFirst("--file=".count))
            }
            if argument.hasPrefix("-f"), argument.count > 2 {
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
        func inlineColorsValue(_ argument: String) -> String? {
            argument.hasPrefix("--colors=")
                ? String(argument.dropFirst("--colors=".count))
                : nil
        }
        func colorChangeTargetsPath(_ raw: String) -> Bool {
            raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .lowercased() == "path"
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
        func inlineReplacementValue(_ argument: String) -> String? {
            if argument.hasPrefix("--replace=") {
                return String(argument.dropFirst("--replace=".count))
            }
            if argument.hasPrefix("-r"), argument.count > 2 {
                return String(argument.dropFirst(2))
            }
            return nil
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
        enum NumericPreflightOption {
            case afterContext
            case beforeContext
            case context
            case maxColumns
            case maxDepth
        }
        func inlineNumericPreflightOption(_ argument: String) -> (NumericPreflightOption, String)? {
            let inlinePrefixes: [(String, NumericPreflightOption)] = [
                ("--after-context=", .afterContext),
                ("--before-context=", .beforeContext),
                ("--context=", .context),
                ("--max-columns=", .maxColumns),
                ("--max-depth=", .maxDepth),
                ("--maxdepth=", .maxDepth),
            ]
            for (prefix, option) in inlinePrefixes where argument.hasPrefix(prefix) {
                return (option, String(argument.dropFirst(prefix.count)))
            }
            let shortPrefixes: [(String, NumericPreflightOption)] = [
                ("-A", .afterContext),
                ("-B", .beforeContext),
                ("-C", .context),
                ("-M", .maxColumns),
                ("-d", .maxDepth),
            ]
            for (prefix, option) in shortPrefixes where argument.hasPrefix(prefix) && argument.count > prefix.count {
                return (option, String(argument.dropFirst(prefix.count)))
            }
            return nil
        }
        func separatedNumericPreflightOption(_ argument: String) -> NumericPreflightOption? {
            switch argument {
            case "-A",
                 "--after-context":
                return .afterContext
            case "-B",
                 "--before-context":
                return .beforeContext
            case "-C",
                 "--context":
                return .context
            case "-M",
                 "--max-columns":
                return .maxColumns
            case "-d",
                 "--max-depth",
                 "--maxdepth":
                return .maxDepth
            default:
                return nil
            }
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
        func normalizedEncodingValue(_ raw: String) -> String {
            raw.trimmingCharacters(
                in: CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000C}\u{000D}\u{0020}")
            ).lowercased()
        }
        func isKnownPreflightEncodingValue(_ raw: String) -> Bool {
            switch normalizedEncodingValue(raw) {
            case "auto", "none":
                return true
            default:
                return TextEncoding.isKnownLabel(raw)
            }
        }
        func isAutomaticEncodingValue(_ raw: String) -> Bool {
            normalizedEncodingValue(raw) == "auto"
        }
        func pathMayUseSearchZip(_ path: String) -> Bool {
            [
                ".gz",
                ".tgz",
                ".bz2",
                ".tbz2",
                ".xz",
                ".txz",
                ".lz4",
                ".lzma",
                ".br",
                ".zst",
                ".zstd",
                ".Z",
            ].contains { path.hasSuffix($0) }
        }
        func isLinePreflightCompatibleEncodingValue(_ raw: String) -> Bool {
            switch normalizedEncodingValue(raw) {
            case "auto", "none":
                return true
            default:
                return false
            }
        }
        func isUTF8LinePreflightCompatibleEncodingValue(_ raw: String) -> Bool {
            switch normalizedEncodingValue(raw) {
            case "unicode-1-1-utf-8",
                 "unicode11utf8",
                 "unicode20utf8",
                 "utf-8",
                 "utf8",
                 "x-unicode20utf8":
                return true
            default:
                return false
            }
        }
        func isSummaryPreflightCompatibleEncodingValue(_ raw: String) -> Bool {
            switch normalizedEncodingValue(raw) {
            case "auto",
                 "none",
                 "unicode-1-1-utf-8",
                 "unicode11utf8",
                 "unicode20utf8",
                 "utf-8",
                 "utf8",
                 "x-unicode20utf8":
                return true
            default:
                return false
            }
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
            byteOffset: Bool,
            withFilename: Bool?,
            pretty: Bool,
            invertMatch: Bool,
            multiline: Bool,
            quiet: Bool,
            printMode: PrintMode?,
            onlyMatching: Bool,
            nullPathTerminator: Bool,
            searchZip: Bool,
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
            var byteOffset = false
            var withFilename: Bool?
            var pretty = false
            var invertMatch = false
            var multiline = false
            var quiet = false
            var printMode: PrintMode?
            var onlyMatching = false
            var nullPathTerminator = false
            var searchZip = false
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
                    multiline = true
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
                case UInt8(ascii: "."):
                    continue
                case UInt8(ascii: "P"):
                    allowPCREQuotedLiterals = true
                case UInt8(ascii: "a"):
                    continue
                case UInt8(ascii: "b"):
                    byteOffset = true
                case UInt8(ascii: "H"):
                    withFilename = true
                case UInt8(ascii: "I"):
                    withFilename = false
                case UInt8(ascii: "p"):
                    pretty = true
                    lineNumber = true
                case UInt8(ascii: "v"):
                    invertMatch = true
                case UInt8(ascii: "q"):
                    quiet = true
                case UInt8(ascii: "c"):
                    printMode = .count
                case UInt8(ascii: "o"):
                    onlyMatching = true
                case UInt8(ascii: "l"):
                    printMode = .filesWithMatches
                case UInt8(ascii: "0"):
                    nullPathTerminator = true
                case UInt8(ascii: "z"):
                    searchZip = true
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
                byteOffset,
                withFilename,
                pretty,
                invertMatch,
                multiline,
                quiet,
                printMode,
                onlyMatching,
                nullPathTerminator,
                searchZip,
                unrestrictedCount
            )
        }
        var allowPCREQuotedLiterals = preflightArguments.allowPCREQuotedLiterals
        var parsedCaseMode = CaseMode.sensitive
        var parsedByteOffset = false
        var parsedColumn = false
        var parsedColorMayEmit = false
        var parsedColorForcesANSI = false
        var parsedColorSpecMayChangePath = false
        var parsedContextSeparator: [UInt8]? = [UInt8(ascii: "-"), UInt8(ascii: "-")]
        var parsedFixedStrings = false
        var parsedFieldMatchSeparator = [UInt8(ascii: ":")]
        var parsedFieldContextSeparator = [UInt8(ascii: "-")]
        var parsedHeading = false
        var parsedEncodingIsAutomatic = true
        var parsedEncodingSupportsLinePreflight = true
        var parsedEncodingSupportsUTF8LinePreflight = false
        var parsedEncodingSupportsSummaryPreflight = true
        var parsedIncludeZero = false
        var parsedInvertMatch = false
        var parsedJson = false
        var parsedLineNumber = false
        var parsedLineRegexp = false
        var parsedAfterContext = 0
        var parsedAfterContextWasSet = false
        var parsedBeforeContext = 0
        var parsedBeforeContextWasSet = false
        var parsedMaxColumns = 0
        var parsedNullPathTerminator = false
        var parsedNoMmap = false
        var parsedOnlyMatching = false
        var parsedPrintMode = PrintMode.matchingLines
        var parsedPathSeparator: UInt8?
        var parsedPassthru = false
        var parsedQuiet = false
        var parsedReplacement = false
        var parsedSearchZip = false
        var parsedMaxCount: Int?
        var parsedCount = false
        var parsedStats = false
        var parsedStopOnNonmatch = false
        var parsedTrim = false
        var parsedNullData = false
        var parsedVimgrep = false
        var parsedTypeDefinitionChanges: [TypeChange] = []
        var parsedUnrestrictedCount = 0
        var parsedWithFilename = false
        var parsedNoFilename = false
        var parsedWordRegexp = false
        var parsedCrlf = false
        var parsedIgnoreFilesEnabled = true
        var parsedIgnoreFilePaths: [String] = []
        var parsedHasExplicitPatternSource = false
        var parsedRegexpPatterns: [String] = []
        var patternCanStartWithDash = false
        var valueArguments: [String] = []
        func appendPreflightPatternFile(_ path: String) -> Bool {
            guard path != "-",
                  isReadableRegularFile(path),
                  let data = FileManager.default.contents(atPath: path) else {
                return false
            }
            parsedHasExplicitPatternSource = true
            let contents = String(decoding: data, as: UTF8.self)
            parsedRegexpPatterns.append(
                contentsOf: RipgrepOptions.patterns(fromPatternFileContents: contents)
            )
            return true
        }
        func applyNumericPreflightOption(_ option: NumericPreflightOption, value: Int) {
            switch option {
            case .afterContext:
                parsedAfterContext = value
                parsedAfterContextWasSet = true
                parsedPassthru = false
            case .beforeContext:
                parsedBeforeContext = value
                parsedBeforeContextWasSet = true
                parsedPassthru = false
            case .context:
                if !parsedAfterContextWasSet {
                    parsedAfterContext = value
                }
                if !parsedBeforeContextWasSet {
                    parsedBeforeContext = value
                }
                parsedPassthru = false
            case .maxColumns:
                parsedMaxColumns = value
            case .maxDepth:
                break
            }
        }
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
                parsedNoFilename = false
            } else if isNoFilenameFlag(argument) {
                parsedWithFilename = false
                parsedNoFilename = true
            } else if isTrimFlag(argument) {
                parsedTrim = true
            } else if isNoTrimFlag(argument) {
                parsedTrim = false
            } else if argument == "-l" || argument == "--files-with-matches" {
                parsedPrintMode = .filesWithMatches
            } else if argument == "--files-without-match" {
                parsedPrintMode = .filesWithoutMatch
            } else if isCountFlag(argument) {
                parsedPrintMode = .count
            } else if argument == "--count-matches" {
                parsedPrintMode = .countMatches
            } else if isOnlyMatchingFlag(argument) {
                parsedOnlyMatching = true
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
            } else if argument == "-v" || argument == "--invert-match" {
                parsedInvertMatch = true
            } else if argument == "--no-invert-match" {
                parsedInvertMatch = false
            } else if argument == "--passthru" || argument == "--passthrough" {
                parsedPassthru = true
            } else if argument == "--vimgrep" {
                parsedVimgrep = true
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
                continue
            } else if argument == "--block-buffered" || argument == "--no-line-buffered" {
                continue
            } else if argument == "--no-mmap" {
                parsedNoMmap = true
            } else if isMmapFlag(argument) {
                parsedNoMmap = false
            } else if argument == "--crlf" {
                parsedCrlf = true
                parsedNullData = false
            } else if argument == "--no-crlf" {
                parsedCrlf = false
            } else if argument == "--null-data" {
                parsedNullData = true
                parsedCrlf = false
            } else if argument == "-U" || argument == "--multiline" {
                parsedStopOnNonmatch = false
            } else if argument == "--stop-on-nonmatch" {
                parsedStopOnNonmatch = true
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
                guard argumentIndex < arguments.count else {
                    return nil
                }
                parsedHasExplicitPatternSource = true
                parsedRegexpPatterns.append(arguments[argumentIndex])
                patternCanStartWithDash = true
                argumentIndex += 1
            } else if let inlineRegexp = inlineRegexpPattern(argument) {
                parsedHasExplicitPatternSource = true
                parsedRegexpPatterns.append(inlineRegexp)
                patternCanStartWithDash = true
            } else if argument == "-r" || argument == "--replace" {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                parsedReplacement = true
                argumentIndex += 1
            } else if inlineReplacementValue(argument) != nil {
                parsedReplacement = true
            } else if argument == "-f" || argument == "--file" {
                guard argumentIndex < arguments.count,
                      appendPreflightPatternFile(arguments[argumentIndex]) else {
                    return nil
                }
                argumentIndex += 1
            } else if let patternFile = inlinePatternFileValue(argument) {
                guard appendPreflightPatternFile(patternFile) else {
                    return nil
                }
            } else if argument == "-p" || argument == "--pretty" {
                parsedColorMayEmit = true
                parsedColorForcesANSI = true
                parsedHeading = true
                parsedLineNumber = true
            } else if argument == "--color" {
                guard argumentIndex < arguments.count,
                      let colorState = colorModePreflightState(arguments[argumentIndex]) else {
                    return nil
                }
                parsedColorMayEmit = colorState.mayEmit
                parsedColorForcesANSI = colorState.forcesANSI
                argumentIndex += 1
            } else if argument.hasPrefix("--color=") {
                let raw = String(argument.dropFirst("--color=".count))
                guard let colorState = colorModePreflightState(raw) else {
                    return nil
                }
                parsedColorMayEmit = colorState.mayEmit
                parsedColorForcesANSI = colorState.forcesANSI
            } else if argument == "--colors" {
                guard argumentIndex < arguments.count,
                      RipgrepArgumentParser.isValidColorChange(arguments[argumentIndex]) else {
                    return nil
                }
                parsedColorSpecMayChangePath = parsedColorSpecMayChangePath
                    || colorChangeTargetsPath(arguments[argumentIndex])
                argumentIndex += 1
            } else if let colorChange = inlineColorsValue(argument) {
                guard RipgrepArgumentParser.isValidColorChange(colorChange) else {
                    return nil
                }
                parsedColorSpecMayChangePath = parsedColorSpecMayChangePath
                    || colorChangeTargetsPath(colorChange)
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
            } else if let numericOption = separatedNumericPreflightOption(argument) {
                guard argumentIndex < arguments.count,
                      let numericValue = nonNegativeInteger(arguments[argumentIndex]) else {
                    return nil
                }
                applyNumericPreflightOption(numericOption, value: numericValue)
                argumentIndex += 1
            } else if let (numericOption, rawNumericValue) = inlineNumericPreflightOption(argument) {
                guard let numericValue = nonNegativeInteger(rawNumericValue) else {
                    return nil
                }
                applyNumericPreflightOption(numericOption, value: numericValue)
            } else if argument == "--field-match-separator" {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                parsedFieldMatchSeparator = preflightEscapedSeparatorBytes(arguments[argumentIndex])
                argumentIndex += 1
            } else if isInlineFieldMatchSeparator(argument) {
                let rawSeparator = String(argument.dropFirst("--field-match-separator=".count))
                parsedFieldMatchSeparator = preflightEscapedSeparatorBytes(rawSeparator)
            } else if argument == "--field-context-separator" {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                parsedFieldContextSeparator = preflightEscapedSeparatorBytes(arguments[argumentIndex])
                argumentIndex += 1
            } else if argument.hasPrefix("--field-context-separator=") {
                let rawSeparator = String(argument.dropFirst("--field-context-separator=".count))
                parsedFieldContextSeparator = preflightEscapedSeparatorBytes(rawSeparator)
            } else if argument == "--context-separator" {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                parsedContextSeparator = preflightEscapedSeparatorBytes(arguments[argumentIndex])
                argumentIndex += 1
            } else if argument.hasPrefix("--context-separator=") {
                let rawSeparator = String(argument.dropFirst("--context-separator=".count))
                parsedContextSeparator = preflightEscapedSeparatorBytes(rawSeparator)
            } else if argument == "--no-context-separator" {
                parsedContextSeparator = nil
            } else if isSeparatedNeutralValueFlag(argument) {
                guard argumentIndex < arguments.count else {
                    return nil
                }
                argumentIndex += 1
            } else if isInlineNeutralValueFlag(argument) {
                continue
            } else if argument == "--path-separator" {
                guard argumentIndex < arguments.count,
                      let pathSeparator = Self.preflightPathSeparator(arguments[argumentIndex]) else {
                    return nil
                }
                switch pathSeparator {
                case .automatic:
                    parsedPathSeparator = nil
                case .separator(let separator):
                    parsedPathSeparator = separator
                }
                argumentIndex += 1
            } else if let separator = pathSeparatorValue(argument) {
                guard let pathSeparator = Self.preflightPathSeparator(separator) else {
                    return nil
                }
                switch pathSeparator {
                case .automatic:
                    parsedPathSeparator = nil
                case .separator(let separator):
                    parsedPathSeparator = separator
                }
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
            } else if argument == "--no-encoding" {
                parsedEncodingIsAutomatic = true
                parsedEncodingSupportsLinePreflight = true
                parsedEncodingSupportsUTF8LinePreflight = false
                parsedEncodingSupportsSummaryPreflight = true
            } else if argument == "-E" || argument == "--encoding" {
                guard argumentIndex < arguments.count,
                      isKnownPreflightEncodingValue(arguments[argumentIndex]) else {
                    return nil
                }
                parsedEncodingIsAutomatic = isAutomaticEncodingValue(arguments[argumentIndex])
                parsedEncodingSupportsLinePreflight = isLinePreflightCompatibleEncodingValue(
                    arguments[argumentIndex]
                )
                parsedEncodingSupportsUTF8LinePreflight = isUTF8LinePreflightCompatibleEncodingValue(
                    arguments[argumentIndex]
                )
                parsedEncodingSupportsSummaryPreflight = isSummaryPreflightCompatibleEncodingValue(
                    arguments[argumentIndex]
                )
                argumentIndex += 1
            } else if let encoding = encodingValue(argument) {
                guard isKnownPreflightEncodingValue(encoding) else {
                    return nil
                }
                parsedEncodingIsAutomatic = isAutomaticEncodingValue(encoding)
                parsedEncodingSupportsLinePreflight = isLinePreflightCompatibleEncodingValue(encoding)
                parsedEncodingSupportsUTF8LinePreflight = isUTF8LinePreflightCompatibleEncodingValue(encoding)
                parsedEncodingSupportsSummaryPreflight = isSummaryPreflightCompatibleEncodingValue(encoding)
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
                parsedByteOffset = parsedByteOffset || cluster.byteOffset
                if let clusterWithFilename = cluster.withFilename {
                    parsedWithFilename = clusterWithFilename
                    parsedNoFilename = !clusterWithFilename
                }
                if cluster.pretty {
                    parsedColorMayEmit = true
                    parsedColorForcesANSI = true
                    parsedHeading = true
                }
                parsedInvertMatch = parsedInvertMatch || cluster.invertMatch
                if cluster.multiline {
                    parsedStopOnNonmatch = false
                }
                parsedQuiet = parsedQuiet || cluster.quiet
                if let clusterPrintMode = cluster.printMode {
                    parsedPrintMode = clusterPrintMode
                }
                parsedOnlyMatching = parsedOnlyMatching || cluster.onlyMatching
                parsedNullPathTerminator = parsedNullPathTerminator || cluster.nullPathTerminator
                parsedSearchZip = parsedSearchZip || cluster.searchZip
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
        let explicitRegexpPatterns = parsedRegexpPatterns
        if parsedHasExplicitPatternSource {
            guard !explicitRegexpPatterns.isEmpty,
                  valueArguments.count == 1 else {
                return nil
            }
            pattern = explicitRegexpPatterns[0]
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
            let smartCasePatterns = explicitRegexpPatterns.isEmpty ? [pattern] : explicitRegexpPatterns
            asciiCaseInsensitive = smartCasePatterns.allSatisfy {
                $0.rangeOfCharacter(from: .uppercaseLetters) == nil
            }
        }
        lineNumber = parsedLineNumber
        noMmap = parsedNoMmap
        wordRegexp = parsedWordRegexp
        fixedStrings = parsedFixedStrings
        if parsedOnlyMatching,
           parsedPrintMode == .count {
            parsedPrintMode = .countMatches
        }
        parsedCount = parsedPrintMode == .count
        let parsedPathOnlyMode: PathOnlyMode?
        switch parsedPrintMode {
        case .filesWithMatches:
            parsedPathOnlyMode = .matching
        case .filesWithoutMatch:
            parsedPathOnlyMode = .nonMatching
        default:
            parsedPathOnlyMode = nil
        }
        let parsedDisplayPath = Self.preflightDisplayPathBytes(
            path,
            pathSeparator: parsedPathSeparator
        )
        let parsedPathOnlyOutputPath = parsedPathSeparator == nil && path.utf8.allSatisfy { $0 < 0x80 }
            ? nil
            : parsedDisplayPath
        let parsedVimgrepForcesFilename = parsedVimgrep && !parsedNoFilename
        let parsedRawCountPrefix: [UInt8] = if parsedWithFilename || parsedVimgrepForcesFilename {
            parsedDisplayPath + (parsedNullPathTerminator ? [0] : [UInt8(ascii: ":")])
        } else {
            []
        }
        let parsedCountStyleOutput = parsedPrintMode == .count || parsedPrintMode == .countMatches
        let parsedCanEmitDefaultColoredCountPrefix = parsedColorMayEmit
            && parsedColorForcesANSI
            && !parsedColorSpecMayChangePath
            && parsedCountStyleOutput
            && !parsedRawCountPrefix.isEmpty
        let parsedCountPrefix: [UInt8] = if parsedCanEmitDefaultColoredCountPrefix {
            Array("\u{1B}[0m\u{1B}[35m".utf8)
                + parsedDisplayPath
                + Array("\u{1B}[0m".utf8)
                + (parsedNullPathTerminator ? [0] : [UInt8(ascii: ":")])
        } else {
            parsedRawCountPrefix
        }
        let parsedHeadingPrefix: [UInt8] = if parsedHeading && parsedWithFilename {
            if parsedNullPathTerminator {
                parsedDisplayPath + [0]
            } else if parsedCrlf {
                parsedDisplayPath + [UInt8(ascii: "\r"), UInt8(ascii: "\n")]
            } else {
                parsedDisplayPath + [UInt8(ascii: "\n")]
            }
        } else {
            []
        }
        let parsedLinePrefix: [UInt8] = if parsedWithFilename {
            if parsedHeading {
                []
            } else {
                parsedDisplayPath + (parsedNullPathTerminator ? [0] : parsedFieldMatchSeparator)
            }
        } else {
            []
        }
        let parsedContextLinePrefix: [UInt8] = if parsedWithFilename {
            if parsedHeading {
                []
            } else {
                parsedDisplayPath + (parsedNullPathTerminator ? [0] : parsedFieldContextSeparator)
            }
        } else {
            []
        }
        if (parsedAfterContext > 0 || parsedBeforeContext > 0),
           !parsedPassthru,
           !parsedReplacement,
           parsedPrintMode == .matchingLines,
           !parsedVimgrep,
           !parsedOnlyMatching,
           !parsedQuiet,
           !parsedByteOffset,
           !parsedColumn,
           !parsedColorMayEmit,
           parsedEncodingIsAutomatic,
           !parsedInvertMatch,
           !parsedJson,
           parsedMaxColumns == 0,
           !parsedNullData,
           !parsedSearchZip,
           !parsedStats,
           !parsedStopOnNonmatch,
           !parsedCrlf,
           !parsedTrim,
           !wordRegexp,
           !parsedLineRegexp,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-" {
            if parsedMaxCount == 0,
               explicitRegexpPatterns.count > 1 {
                return 1
            }
            let contextLiterals: [[UInt8]]?
            if explicitRegexpPatterns.count > 1 {
                contextLiterals = explicitRegexpPatternLiterals(
                    explicitRegexpPatterns,
                    fixedStrings: fixedStrings,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                )
            } else if !fixedStrings {
                contextLiterals = multiLiteralAlternation(
                    pattern,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                )
            } else {
                contextLiterals = nil
            }
            if let contextLiterals,
               contextLiterals.allSatisfy({
                   !$0.contains(UInt8(ascii: "\n"))
                       && (!asciiCaseInsensitive || $0.allSatisfy({ $0 < 0x80 }))
               }) {
                if parsedMaxCount == 0 {
                    return 1
                }
                return SwiftDarwinLiteralPreflight.multiLiteralContextLineExitCode(
                    path: path,
                    literals: contextLiterals,
                    beforeContext: parsedBeforeContext,
                    afterContext: parsedAfterContext,
                    maxCount: parsedMaxCount ?? Int.max,
                    asciiCaseInsensitive: asciiCaseInsensitive,
                    lineNumber: lineNumber,
                    lineNumberFieldMatchSeparator: parsedFieldMatchSeparator,
                    lineNumberFieldContextSeparator: parsedFieldContextSeparator,
                    lineMatchPrefix: parsedLinePrefix,
                    lineContextPrefix: parsedContextLinePrefix,
                    headingPrefix: parsedHeadingPrefix,
                    contextSeparator: parsedContextSeparator
                )
            }
        }
        if parsedAfterContext > 0,
           parsedBeforeContext > 0,
           !parsedPassthru,
           !parsedReplacement,
           parsedPrintMode == .matchingLines,
           !parsedVimgrep,
           !parsedOnlyMatching,
           !parsedQuiet,
           !parsedByteOffset,
           !parsedColumn,
           !parsedColorMayEmit,
           parsedEncodingIsAutomatic,
           !parsedInvertMatch,
           !parsedJson,
           parsedMaxColumns == 0,
           !parsedNullData,
           !parsedSearchZip,
           !parsedStats,
           !parsedStopOnNonmatch,
           !parsedCrlf,
           !parsedTrim,
           !wordRegexp,
           !parsedLineRegexp,
           explicitRegexpPatterns.count <= 1,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-" {
            if parsedMaxCount == 0 {
                return 1
            }
            let contextLiteralPattern = fixedStrings
                ? pattern
                : RegexLiteralParser.literal(
                    fromPlainRegexPattern: pattern,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                )
            if let contextLiteralPattern {
                let contextLiteral = Array(contextLiteralPattern.utf8)
                if !contextLiteral.isEmpty,
                   !contextLiteral.contains(UInt8(ascii: "\n")),
                   (!asciiCaseInsensitive || contextLiteral.allSatisfy({ $0 < 0x80 })) {
                    return SwiftDarwinLiteralPreflight.contextLiteralLineExitCode(
                        path: path,
                        literal: contextLiteral,
                        beforeContext: parsedBeforeContext,
                        afterContext: parsedAfterContext,
                        maxCount: parsedMaxCount ?? Int.max,
                        asciiCaseInsensitive: asciiCaseInsensitive,
                        lineNumber: lineNumber,
                        lineNumberFieldMatchSeparator: parsedFieldMatchSeparator,
                        lineNumberFieldContextSeparator: parsedFieldContextSeparator,
                        lineMatchPrefix: parsedLinePrefix,
                        lineContextPrefix: parsedContextLinePrefix,
                        headingPrefix: parsedHeadingPrefix,
                        contextSeparator: parsedContextSeparator
                    )
                }
            }
        }
        if parsedAfterContext > 0,
           parsedBeforeContext == 0,
           !parsedPassthru,
           !parsedReplacement,
           parsedPrintMode == .matchingLines,
           !parsedVimgrep,
           !parsedOnlyMatching,
           !parsedQuiet,
           !parsedByteOffset,
           !parsedColumn,
           !parsedColorMayEmit,
           parsedEncodingIsAutomatic,
           !parsedInvertMatch,
           !parsedJson,
           parsedMaxColumns == 0,
           !parsedNullData,
           !parsedSearchZip,
           !parsedStats,
           !parsedStopOnNonmatch,
           !parsedCrlf,
           !parsedTrim,
           !wordRegexp,
           !parsedLineRegexp,
           explicitRegexpPatterns.count <= 1,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-" {
            if parsedMaxCount == 0 {
                return 1
            }
            let afterContextLiteralPattern = fixedStrings
                ? pattern
                : RegexLiteralParser.literal(
                    fromPlainRegexPattern: pattern,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                )
            if let afterContextLiteralPattern {
                let afterContextLiteral = Array(afterContextLiteralPattern.utf8)
                if !afterContextLiteral.isEmpty,
                   !afterContextLiteral.contains(UInt8(ascii: "\n")),
                   (!asciiCaseInsensitive || afterContextLiteral.allSatisfy({ $0 < 0x80 })) {
                    return SwiftDarwinLiteralPreflight.afterContextLiteralLineExitCode(
                        path: path,
                        literal: afterContextLiteral,
                        afterContext: parsedAfterContext,
                        maxCount: parsedMaxCount ?? Int.max,
                        asciiCaseInsensitive: asciiCaseInsensitive,
                        lineNumber: lineNumber,
                        lineNumberFieldMatchSeparator: parsedFieldMatchSeparator,
                        lineNumberFieldContextSeparator: parsedFieldContextSeparator,
                        lineMatchPrefix: parsedLinePrefix,
                        lineContextPrefix: parsedContextLinePrefix,
                        headingPrefix: parsedHeadingPrefix,
                        contextSeparator: parsedContextSeparator
                    )
                }
            }
        }
        if parsedBeforeContext > 0,
           parsedAfterContext == 0,
           !parsedPassthru,
           !parsedReplacement,
           parsedPrintMode == .matchingLines,
           !parsedVimgrep,
           !parsedOnlyMatching,
           !parsedQuiet,
           !parsedByteOffset,
           !parsedColumn,
           !parsedColorMayEmit,
           parsedEncodingIsAutomatic,
           !parsedInvertMatch,
           !parsedJson,
           parsedMaxColumns == 0,
           !parsedNullData,
           !parsedSearchZip,
           !parsedStats,
           !parsedStopOnNonmatch,
           !parsedCrlf,
           !parsedTrim,
           !wordRegexp,
           !parsedLineRegexp,
           explicitRegexpPatterns.count <= 1,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-" {
            if parsedMaxCount == 0 {
                return 1
            }
            let beforeContextLiteralPattern = fixedStrings
                ? pattern
                : RegexLiteralParser.literal(
                    fromPlainRegexPattern: pattern,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                )
            if let beforeContextLiteralPattern {
                let beforeContextLiteral = Array(beforeContextLiteralPattern.utf8)
                if !beforeContextLiteral.isEmpty,
                   !beforeContextLiteral.contains(UInt8(ascii: "\n")),
                   (!asciiCaseInsensitive || beforeContextLiteral.allSatisfy({ $0 < 0x80 })) {
                    return SwiftDarwinLiteralPreflight.beforeContextLiteralLineExitCode(
                        path: path,
                        literal: beforeContextLiteral,
                        beforeContext: parsedBeforeContext,
                        maxCount: parsedMaxCount ?? Int.max,
                        asciiCaseInsensitive: asciiCaseInsensitive,
                        lineNumber: lineNumber,
                        lineNumberFieldMatchSeparator: parsedFieldMatchSeparator,
                        lineNumberFieldContextSeparator: parsedFieldContextSeparator,
                        lineMatchPrefix: parsedLinePrefix,
                        lineContextPrefix: parsedContextLinePrefix,
                        headingPrefix: parsedHeadingPrefix,
                        contextSeparator: parsedContextSeparator
                    )
                }
            }
        }
        if parsedStopOnNonmatch,
           parsedPrintMode == .matchingLines,
           !parsedVimgrep,
           !parsedOnlyMatching,
           !parsedQuiet,
           !parsedByteOffset,
           !parsedColumn,
           !parsedColorMayEmit,
           parsedEncodingIsAutomatic,
           parsedAfterContext == 0,
           parsedBeforeContext == 0,
           !parsedInvertMatch,
           !parsedJson,
           parsedMaxColumns == 0,
           !parsedNullData,
           !parsedPassthru,
           !parsedReplacement,
           !parsedSearchZip,
           !parsedStats,
           !parsedTrim,
           !wordRegexp,
           !parsedLineRegexp,
           !asciiCaseInsensitive,
           !parsedCrlf,
           parsedMaxCount != 0,
           path != "-" {
            let stopLiteralPattern = fixedStrings
                ? pattern
                : RegexLiteralParser.literal(
                    fromPlainRegexPattern: pattern,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                )
            if let stopLiteralPattern {
                let stopLiteral = Array(stopLiteralPattern.utf8)
                if !stopLiteral.isEmpty,
                   !stopLiteral.contains(UInt8(ascii: "\n")) {
                    return SwiftDarwinLiteralPreflight.stopOnNonmatchLineExitCode(
                        path: path,
                        literal: stopLiteral,
                        maxCount: parsedMaxCount,
                        lineNumber: lineNumber,
                        lineNumberFieldSeparator: parsedFieldMatchSeparator,
                        linePrefix: parsedLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }
            }
        }
        if parsedStopOnNonmatch,
           parsedPrintMode == .count,
           !parsedOnlyMatching,
           !parsedQuiet,
           !parsedByteOffset,
           !parsedColumn,
           !parsedColorMayEmit,
           parsedEncodingIsAutomatic,
           !parsedInvertMatch,
           !parsedJson,
           parsedMaxColumns == 0,
           !parsedNullData,
           !parsedPassthru,
           !parsedSearchZip,
           !parsedStats,
           !parsedTrim,
           !wordRegexp,
           !parsedLineRegexp,
           !asciiCaseInsensitive,
           parsedMaxCount != 0,
           path != "-" {
            let stopLiteralPattern = fixedStrings
                ? pattern
                : RegexLiteralParser.literal(
                    fromPlainRegexPattern: pattern,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                )
            if let stopLiteralPattern {
                let stopLiteral = Array(stopLiteralPattern.utf8)
                if !stopLiteral.isEmpty,
                   !stopLiteral.contains(UInt8(ascii: "\n")) {
                    return SwiftDarwinLiteralPreflight.stopOnNonmatchCountLineExitCode(
                        path: path,
                        literal: stopLiteral,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
            }
        }
        if parsedTrim,
           parsedPrintMode == .matchingLines,
           !parsedVimgrep,
           !parsedOnlyMatching,
           !parsedQuiet,
           !parsedByteOffset,
           !parsedColumn,
           !parsedColorMayEmit,
           parsedEncodingIsAutomatic,
           parsedAfterContext == 0,
           parsedBeforeContext == 0,
           !parsedInvertMatch,
           !parsedJson,
           parsedMaxColumns == 0,
           !parsedNullData,
           !parsedPassthru,
           !parsedReplacement,
           !parsedSearchZip,
           !parsedStats,
           !parsedStopOnNonmatch,
           !parsedCrlf,
           !wordRegexp,
           !parsedLineRegexp,
           parsedMaxCount != 0,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-" {
            if explicitRegexpPatterns.count > 1 {
                if let trimLiterals = explicitRegexpPatternLiterals(
                    explicitRegexpPatterns,
                    fixedStrings: fixedStrings,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                   ),
                   trimLiterals.allSatisfy({
                    !$0.contains(UInt8(ascii: "\n"))
                        && (!asciiCaseInsensitive || $0.allSatisfy({ $0 < 0x80 }))
                   }) {
                    return SwiftDarwinLiteralPreflight.trimmedMultiLiteralLineExitCode(
                        path: path,
                        literals: trimLiterals,
                        maxCount: parsedMaxCount ?? Int.max,
                        asciiCaseInsensitive: asciiCaseInsensitive,
                        lineNumber: lineNumber,
                        lineNumberFieldSeparator: parsedFieldMatchSeparator,
                        linePrefix: parsedLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }
            } else {
                if !fixedStrings,
                   let trimLiterals = multiLiteralAlternation(
                    pattern,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                   ),
                   trimLiterals.allSatisfy({
                    !$0.contains(UInt8(ascii: "\n"))
                        && (!asciiCaseInsensitive || $0.allSatisfy({ $0 < 0x80 }))
                   }) {
                    return SwiftDarwinLiteralPreflight.trimmedMultiLiteralLineExitCode(
                        path: path,
                        literals: trimLiterals,
                        maxCount: parsedMaxCount ?? Int.max,
                        asciiCaseInsensitive: asciiCaseInsensitive,
                        lineNumber: lineNumber,
                        lineNumberFieldSeparator: parsedFieldMatchSeparator,
                        linePrefix: parsedLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }

                let trimLiteralPattern = fixedStrings
                    ? pattern
                    : RegexLiteralParser.literal(
                        fromPlainRegexPattern: pattern,
                        allowPCREQuotedLiterals: allowPCREQuotedLiterals
                    )
                if let trimLiteralPattern {
                    let trimLiteral = Array(trimLiteralPattern.utf8)
                    if !trimLiteral.isEmpty,
                       !trimLiteral.contains(UInt8(ascii: "\n")),
                       (!asciiCaseInsensitive || trimLiteral.allSatisfy({ $0 < 0x80 })) {
                        return SwiftDarwinLiteralPreflight.trimmedLiteralLineExitCode(
                            path: path,
                            literal: trimLiteral,
                            maxCount: parsedMaxCount ?? Int.max,
                            asciiCaseInsensitive: asciiCaseInsensitive,
                            lineNumber: lineNumber,
                            lineNumberFieldSeparator: parsedFieldMatchSeparator,
                            linePrefix: parsedLinePrefix,
                            headingPrefix: parsedHeadingPrefix
                        )
                    }
                }
            }
        }
        if parsedInvertMatch,
           parsedPrintMode == .matchingLines,
           !parsedVimgrep,
           !parsedOnlyMatching,
           !parsedQuiet,
           !parsedByteOffset,
           !parsedColumn,
           !parsedColorMayEmit,
           parsedEncodingIsAutomatic,
           parsedAfterContext == 0,
           parsedBeforeContext == 0,
           !parsedJson,
           parsedMaxColumns == 0,
           !parsedNullData,
           !parsedPassthru,
           !parsedSearchZip,
           !parsedStats,
           !parsedStopOnNonmatch,
           !parsedCrlf,
           !parsedTrim,
           !wordRegexp,
           !parsedLineRegexp,
           parsedMaxCount != 0,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-" {
            if explicitRegexpPatterns.count > 1 {
                if let invertedLiterals = explicitRegexpPatternLiterals(
                    explicitRegexpPatterns,
                    fixedStrings: fixedStrings,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                   ),
                   invertedLiterals.allSatisfy({
                       !$0.contains(UInt8(ascii: "\n"))
                           && (!asciiCaseInsensitive || $0.allSatisfy({ $0 < 0x80 }))
                   }) {
                    return SwiftDarwinLiteralPreflight.invertedMultiLiteralLineExitCode(
                        path: path,
                        literals: invertedLiterals,
                        maxCount: parsedMaxCount ?? Int.max,
                        asciiCaseInsensitive: asciiCaseInsensitive,
                        lineNumber: lineNumber,
                        lineNumberFieldSeparator: parsedFieldMatchSeparator,
                        linePrefix: parsedLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }
            } else {
                if !fixedStrings,
                   let invertedLiterals = multiLiteralAlternation(
                    pattern,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                   ),
                   invertedLiterals.allSatisfy({
                       !$0.contains(UInt8(ascii: "\n"))
                           && (!asciiCaseInsensitive || $0.allSatisfy({ $0 < 0x80 }))
                   }) {
                    return SwiftDarwinLiteralPreflight.invertedMultiLiteralLineExitCode(
                        path: path,
                        literals: invertedLiterals,
                        maxCount: parsedMaxCount ?? Int.max,
                        asciiCaseInsensitive: asciiCaseInsensitive,
                        lineNumber: lineNumber,
                        lineNumberFieldSeparator: parsedFieldMatchSeparator,
                        linePrefix: parsedLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }

                let invertedLiteralPattern = fixedStrings
                    ? pattern
                    : RegexLiteralParser.literal(
                        fromPlainRegexPattern: pattern,
                        allowPCREQuotedLiterals: allowPCREQuotedLiterals
                    )
                if let invertedLiteralPattern {
                    let invertedLiteral = Array(invertedLiteralPattern.utf8)
                    if !invertedLiteral.isEmpty,
                       !invertedLiteral.contains(UInt8(ascii: "\n")),
                       (!asciiCaseInsensitive || invertedLiteral.allSatisfy({ $0 < 0x80 })) {
                        return SwiftDarwinLiteralPreflight.invertedLiteralLineExitCode(
                            path: path,
                            literal: invertedLiteral,
                            maxCount: parsedMaxCount ?? Int.max,
                            asciiCaseInsensitive: asciiCaseInsensitive,
                            lineNumber: lineNumber,
                            lineNumberFieldSeparator: parsedFieldMatchSeparator,
                            linePrefix: parsedLinePrefix,
                            headingPrefix: parsedHeadingPrefix
                        )
                    }
                }
            }
        }
        if parsedPassthru,
           parsedPrintMode == .matchingLines,
           !parsedVimgrep,
           !parsedOnlyMatching,
           !parsedQuiet,
           !parsedByteOffset,
           !parsedColumn,
           !parsedColorMayEmit,
           parsedEncodingIsAutomatic,
           parsedAfterContext == 0,
           parsedBeforeContext == 0,
           !parsedInvertMatch,
           !parsedJson,
           parsedMaxColumns == 0,
           !parsedNullData,
           !parsedReplacement,
           !parsedSearchZip,
           !parsedStats,
           !parsedStopOnNonmatch,
           !parsedCrlf,
           !parsedTrim,
           !wordRegexp,
           !parsedLineRegexp,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-" {
            if parsedMaxCount == 0 {
                return 1
            }

            if explicitRegexpPatterns.count > 1 {
                if let passthruLiterals = explicitRegexpPatternLiterals(
                    explicitRegexpPatterns,
                    fixedStrings: fixedStrings,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                ) {
                    guard passthruLiterals.allSatisfy({
                        !asciiCaseInsensitive || $0.allSatisfy({ $0 < 0x80 })
                    }) else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.multiLiteralPassthruLineExitCode(
                        path: path,
                        literals: passthruLiterals,
                        asciiCaseInsensitive: asciiCaseInsensitive,
                        lineNumber: lineNumber,
                        lineNumberFieldMatchSeparator: parsedFieldMatchSeparator,
                        lineNumberFieldContextSeparator: parsedFieldContextSeparator,
                        lineMatchPrefix: parsedLinePrefix,
                        lineContextPrefix: parsedContextLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }
            } else {
                if !fixedStrings,
                   let passthruLiterals = multiLiteralAlternation(
                    pattern,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                   ),
                   passthruLiterals.allSatisfy({
                       !$0.contains(UInt8(ascii: "\n"))
                           && (!asciiCaseInsensitive || $0.allSatisfy({ $0 < 0x80 }))
                   }) {
                    return SwiftDarwinLiteralPreflight.multiLiteralPassthruLineExitCode(
                        path: path,
                        literals: passthruLiterals,
                        asciiCaseInsensitive: asciiCaseInsensitive,
                        lineNumber: lineNumber,
                        lineNumberFieldMatchSeparator: parsedFieldMatchSeparator,
                        lineNumberFieldContextSeparator: parsedFieldContextSeparator,
                        lineMatchPrefix: parsedLinePrefix,
                        lineContextPrefix: parsedContextLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }

                let passthruLiteralPattern = fixedStrings
                    ? pattern
                    : RegexLiteralParser.literal(
                        fromPlainRegexPattern: pattern,
                        allowPCREQuotedLiterals: allowPCREQuotedLiterals
                    )
                if let passthruLiteralPattern {
                    let passthruLiteral = Array(passthruLiteralPattern.utf8)
                    guard !passthruLiteral.isEmpty,
                          !passthruLiteral.contains(UInt8(ascii: "\n")),
                          (!asciiCaseInsensitive || passthruLiteral.allSatisfy({ $0 < 0x80 })) else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.passthruLiteralLineExitCode(
                        path: path,
                        literal: passthruLiteral,
                        asciiCaseInsensitive: asciiCaseInsensitive,
                        lineNumber: lineNumber,
                        lineNumberFieldMatchSeparator: parsedFieldMatchSeparator,
                        lineNumberFieldContextSeparator: parsedFieldContextSeparator,
                        lineMatchPrefix: parsedLinePrefix,
                        lineContextPrefix: parsedContextLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }
            }
        }
        let parsedTrimAffectsPreflightOutput = parsedTrim
            && !parsedQuiet
            && parsedPathOnlyMode == nil
            && !parsedCount
            && parsedPrintMode != .countMatches
            && !parsedOnlyMatching
        let parsedNullDataAffectsPreflightOutput = parsedNullData
            && !parsedQuiet
            && parsedPathOnlyMode == nil
            && parsedPrintMode != .countMatches
        let parsedMaxColumnsAffectsPreflightOutput = parsedMaxColumns > 0
            && !parsedQuiet
            && parsedPathOnlyMode == nil
            && !parsedCount
            && parsedPrintMode != .countMatches
        let parsedPassthruAffectsPreflightOutput = parsedPassthru
            && !parsedQuiet
            && parsedPathOnlyMode == nil
            && !parsedCount
            && parsedPrintMode != .countMatches
        let parsedReplacementAffectsPreflightOutput = parsedReplacement
            && !parsedQuiet
            && parsedPathOnlyMode == nil
            && !parsedCount
            && parsedPrintMode != .countMatches
        let parsedByteOffsetAffectsPreflightOutput = parsedByteOffset
            && !parsedQuiet
            && parsedPathOnlyMode == nil
            && !parsedCount
            && parsedPrintMode != .countMatches
        let parsedColumnAffectsPreflightOutput = parsedColumn
            && !parsedQuiet
            && parsedPathOnlyMode == nil
            && !parsedCount
            && parsedPrintMode != .countMatches
        let parsedColorAffectsPreflightOutput = parsedColorMayEmit
            && !parsedQuiet
            && (!parsedCountStyleOutput
                || (!parsedRawCountPrefix.isEmpty && !parsedCanEmitDefaultColoredCountPrefix))
        let parsedVimgrepAffectsPreflightOutput = parsedVimgrep
            && !parsedQuiet
            && parsedPathOnlyMode == nil
            && !parsedCount
            && parsedPrintMode != .countMatches
        let parsedOnlyMatchingAffectsPreflightOutput = parsedOnlyMatching
            && !parsedQuiet
            && parsedPathOnlyMode == nil
            && parsedPrintMode != .countMatches
        let parsedContextAffectsPreflightOutput = (parsedAfterContext > 0 || parsedBeforeContext > 0)
            && !parsedQuiet
            && parsedPathOnlyMode == nil
            && !parsedCount
            && parsedPrintMode != .countMatches
        let parsedEncodingVisibleLineOutput = !parsedQuiet
            && parsedPathOnlyMode == nil
            && !parsedCount
            && parsedPrintMode != .countMatches
        let parsedEncodingVisibleLineShapeCanUsePreflight = !wordRegexp
            && !parsedLineRegexp
            && !parsedOnlyMatching
        let parsedUTF8EncodingVisibleLineOutputCanUsePreflight =
            parsedEncodingVisibleLineOutput
            && parsedEncodingSupportsUTF8LinePreflight
            && ((!asciiCaseInsensitive
                    && parsedEncodingVisibleLineShapeCanUsePreflight
                    && SwiftDarwinLiteralPreflight.fileCanUseUTF8LinePreflight(path: path))
                || (!wordRegexp && SwiftDarwinLiteralPreflight.fileCanUseASCIILinePreflight(path: path)))
        let parsedEncodingVisibleLineOutputCanUsePreflight =
            parsedEncodingVisibleLineOutput
            && ((parsedEncodingVisibleLineShapeCanUsePreflight && parsedEncodingSupportsLinePreflight)
                || parsedUTF8EncodingVisibleLineOutputCanUsePreflight)
        let parsedEncodingAffectsPreflightOutput = !parsedEncodingIsAutomatic
            && (!parsedEncodingSupportsSummaryPreflight
                || (parsedEncodingVisibleLineOutput
                    && !parsedEncodingVisibleLineOutputCanUsePreflight))
        let parsedSearchZipAffectsPreflight = parsedSearchZip && pathMayUseSearchZip(path)
        guard !(parsedLineRegexp && wordRegexp) else {
            return nil
        }
        guard !parsedByteOffsetAffectsPreflightOutput,
              !parsedColumnAffectsPreflightOutput,
              !parsedColorAffectsPreflightOutput,
              !parsedEncodingAffectsPreflightOutput,
              !parsedContextAffectsPreflightOutput,
              !parsedHeading || !parsedWithFilename || parsedPrintMode == .matchingLines
                  || parsedPrintMode == .count || parsedPrintMode == .countMatches
                  || parsedPathOnlyMode != nil,
              !parsedInvertMatch,
              !parsedJson,
              !parsedMaxColumnsAffectsPreflightOutput,
              !parsedNullDataAffectsPreflightOutput,
              !parsedPassthruAffectsPreflightOutput,
              !parsedReplacementAffectsPreflightOutput,
              !parsedSearchZipAffectsPreflight,
              !parsedStats,
              (!parsedStopOnNonmatch || parsedQuiet || parsedPathOnlyMode != nil),
              !parsedTrimAffectsPreflightOutput,
              !parsedVimgrepAffectsPreflightOutput else {
            return nil
        }
        if parsedOnlyMatchingAffectsPreflightOutput {
            guard parsedPrintMode == .matchingLines,
                  !parsedCrlf else {
                return nil
            }
            if parsedLineRegexp {
                guard !wordRegexp else {
                    return nil
                }
            }
        }

        if explicitRegexpPatterns.count > 1 {
            guard parsedMaxCount != 0,
                  path != "-",
                  let literals = explicitRegexpPatternLiterals(
                    explicitRegexpPatterns,
                    fixedStrings: fixedStrings,
                    allowPCREQuotedLiterals: allowPCREQuotedLiterals
                  ) else {
                return nil
            }
            if parsedLineRegexp {
                guard !wordRegexp,
                      !parsedNullData,
                      !parsedCrlf else {
                    return nil
                }
                if asciiCaseInsensitive {
                    if parsedQuiet {
                        return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLineQuietExitCode(
                            path: path,
                            literals: literals
                        )
                    }
                    if let parsedPathOnlyMode {
                        return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLinePathOnlyExitCode(
                            path: path,
                            literals: literals,
                            printWhenMatched: parsedPathOnlyMode == .matching,
                            nullTerminated: parsedNullPathTerminator,
                            crlfTerminated: parsedCrlf,
                            outputPath: parsedPathOnlyOutputPath
                        )
                    }
                    if parsedPrintMode == .countMatches || parsedCount {
                        return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLineCountExitCode(
                            path: path,
                            literals: literals,
                            includeZero: parsedIncludeZero,
                            maxCount: parsedMaxCount,
                            countPrefix: parsedCountPrefix,
                            crlfTerminated: parsedCrlf
                        )
                    }
                    guard parsedPrintMode == .matchingLines else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLineExitCode(
                        path: path,
                        literals: literals,
                        maxCount: parsedMaxCount,
                        lineNumber: lineNumber,
                        lineNumberFieldSeparator: parsedFieldMatchSeparator,
                        linePrefix: parsedLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }
                if parsedQuiet {
                    return SwiftDarwinLiteralPreflight.multiLiteralExactLineQuietExitCode(
                        path: path,
                        literals: literals
                    )
                }
                if let parsedPathOnlyMode {
                    return SwiftDarwinLiteralPreflight.multiLiteralExactLinePathOnlyExitCode(
                        path: path,
                        literals: literals,
                        printWhenMatched: parsedPathOnlyMode == .matching,
                        nullTerminated: parsedNullPathTerminator,
                        crlfTerminated: parsedCrlf,
                        outputPath: parsedPathOnlyOutputPath
                    )
                }
                if parsedPrintMode == .countMatches {
                    return SwiftDarwinLiteralPreflight.multiLiteralExactLineCountExitCode(
                        path: path,
                        literals: literals,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                if parsedCount {
                    return SwiftDarwinLiteralPreflight.multiLiteralExactLineCountExitCode(
                        path: path,
                        literals: literals,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                return SwiftDarwinLiteralPreflight.multiLiteralExactLineExitCode(
                    path: path,
                    literals: literals,
                    maxCount: parsedMaxCount,
                    lineNumber: lineNumber,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
            if wordRegexp {
                if asciiCaseInsensitive {
                    if parsedPrintMode == .countMatches {
                        guard parsedMaxCount != 0 else {
                            return nil
                        }
                        return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralWordCountMatchesExitCode(
                            path: path,
                            literals: literals,
                            includeZero: parsedIncludeZero,
                            maxCount: parsedMaxCount,
                            countPrefix: parsedCountPrefix,
                            crlfTerminated: parsedCrlf
                        )
                    }
                    if parsedCount {
                        return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralWordCountLineExitCode(
                            path: path,
                            literals: literals,
                            includeZero: parsedIncludeZero,
                            maxCount: parsedMaxCount,
                            countPrefix: parsedCountPrefix,
                            crlfTerminated: parsedCrlf
                        )
                    }
                    return nil
                }
                if parsedPrintMode == .countMatches {
                    guard parsedMaxCount != 0 else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.multiLiteralWordCountMatchesExitCode(
                        path: path,
                        literals: literals,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                if parsedCount {
                    return SwiftDarwinLiteralPreflight.multiLiteralWordCountLineExitCode(
                        path: path,
                        literals: literals,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                return nil
            }
            if parsedOnlyMatchingAffectsPreflightOutput {
                if asciiCaseInsensitive {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralOnlyMatchingExitCode(
                        path: path,
                        literals: literals,
                        lineNumber: lineNumber,
                        maxCount: parsedMaxCount,
                        lineNumberFieldSeparator: parsedFieldMatchSeparator,
                        linePrefix: parsedLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }
                return SwiftDarwinLiteralPreflight.multiLiteralOnlyMatchingExitCode(
                    path: path,
                    literals: literals,
                    lineNumber: lineNumber,
                    maxCount: parsedMaxCount,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
            if parsedPrintMode == .countMatches {
                guard !asciiCaseInsensitive,
                      parsedMaxCount != 0 else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.multiLiteralCountMatchesExitCode(
                    path: path,
                    literals: literals,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if asciiCaseInsensitive {
                if parsedQuiet {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralQuietExitCode(
                        path: path,
                        literals: literals
                    )
                }
                if let parsedPathOnlyMode {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralPathOnlyExitCode(
                        path: path,
                        literals: literals,
                        printWhenMatched: parsedPathOnlyMode == .matching,
                        nullTerminated: parsedNullPathTerminator,
                        crlfTerminated: parsedCrlf,
                        outputPath: parsedPathOnlyOutputPath
                    )
                }
                if parsedCount {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralCountLineExitCode(
                        path: path,
                        literals: literals,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                return nil
            }
            if parsedQuiet {
                return SwiftDarwinLiteralPreflight.multiLiteralQuietExitCode(
                    path: path,
                    literals: literals
                )
            }
            if parsedCount {
                return SwiftDarwinLiteralPreflight.multiLiteralCountLineExitCode(
                    path: path,
                    literals: literals,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if let parsedPathOnlyMode {
                return SwiftDarwinLiteralPreflight.multiLiteralPathOnlyExitCode(
                    path: path,
                    literals: literals,
                    printWhenMatched: parsedPathOnlyMode == .matching,
                    nullTerminated: parsedNullPathTerminator,
                    crlfTerminated: parsedCrlf,
                    outputPath: parsedPathOnlyOutputPath
                )
            }
            return SwiftDarwinLiteralPreflight.multiLiteralExitCode(
                path: path,
                literals: literals,
                maxCount: parsedMaxCount,
                lineNumber: lineNumber,
                lineNumberFieldSeparator: parsedFieldMatchSeparator,
                linePrefix: parsedLinePrefix,
                headingPrefix: parsedHeadingPrefix
            )
        }

        if !fixedStrings,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-",
           !asciiCaseInsensitive,
           !wordRegexp,
           !parsedLineRegexp,
           !parsedNullData,
           !noMmap,
           parsedPrintMode == .matchingLines,
           parsedMaxCount == nil,
           let surroundingLiteral = surroundingWordsLiteral(
            pattern,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
           ) {
            return SwiftDarwinLiteralPreflight.surroundingWordsExitCode(
                path: path,
                literal: Array(surroundingLiteral.utf8),
                lineNumber: lineNumber,
                asciiOnly: pattern.hasPrefix("(?-u)"),
                lineNumberFieldSeparator: parsedFieldMatchSeparator,
                linePrefix: parsedLinePrefix,
                headingPrefix: parsedHeadingPrefix
            )
        }

        if !fixedStrings,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-",
           !asciiCaseInsensitive,
           !wordRegexp,
           !parsedLineRegexp,
           !parsedNullData,
           parsedMaxCount != 0,
           let fixedLookbehind = fixedLookbehindLiteral(
            pattern,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
           ) {
            if parsedQuiet {
                return SwiftDarwinLiteralPreflight.fixedLookbehindQuietExitCode(
                    path: path,
                    prefix: fixedLookbehind.prefix,
                    literal: fixedLookbehind.literal,
                    prefixShouldMatch: fixedLookbehind.prefixShouldMatch
                )
            }
            if let parsedPathOnlyMode {
                return SwiftDarwinLiteralPreflight.fixedLookbehindPathOnlyExitCode(
                    path: path,
                    prefix: fixedLookbehind.prefix,
                    literal: fixedLookbehind.literal,
                    prefixShouldMatch: fixedLookbehind.prefixShouldMatch,
                    printWhenMatched: parsedPathOnlyMode == .matching,
                    nullTerminated: parsedNullPathTerminator,
                    crlfTerminated: parsedCrlf,
                    outputPath: parsedPathOnlyOutputPath
                )
            }
            if parsedPrintMode == .countMatches {
                guard parsedMaxCount != 0 else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.fixedLookbehindCountMatchesExitCode(
                    path: path,
                    prefix: fixedLookbehind.prefix,
                    literal: fixedLookbehind.literal,
                    prefixShouldMatch: fixedLookbehind.prefixShouldMatch,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if parsedCount {
                return SwiftDarwinLiteralPreflight.fixedLookbehindCountLineExitCode(
                    path: path,
                    prefix: fixedLookbehind.prefix,
                    literal: fixedLookbehind.literal,
                    prefixShouldMatch: fixedLookbehind.prefixShouldMatch,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if parsedPrintMode == .matchingLines,
               !parsedOnlyMatching,
               fixedLookbehind.prefixShouldMatch {
                return SwiftDarwinLiteralPreflight.multiLiteralExitCode(
                    path: path,
                    literals: [fixedLookbehind.prefix + fixedLookbehind.literal],
                    maxCount: parsedMaxCount,
                    lineNumber: lineNumber,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
            if parsedPrintMode == .matchingLines,
               !parsedOnlyMatching {
                return SwiftDarwinLiteralPreflight.fixedLookbehindLineExitCode(
                    path: path,
                    prefix: fixedLookbehind.prefix,
                    literal: fixedLookbehind.literal,
                    prefixShouldMatch: fixedLookbehind.prefixShouldMatch,
                    maxCount: parsedMaxCount,
                    lineNumber: lineNumber,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
        }

        if !fixedStrings,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-",
           !asciiCaseInsensitive,
           !wordRegexp,
           !parsedLineRegexp,
           !parsedNullData,
           parsedMaxCount != 0,
           let fixedLookahead = fixedLookaheadLiteral(
            pattern,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
           ) {
            if parsedQuiet {
                return SwiftDarwinLiteralPreflight.fixedLookaheadQuietExitCode(
                    path: path,
                    literal: fixedLookahead.literal,
                    suffix: fixedLookahead.suffix,
                    suffixShouldMatch: fixedLookahead.suffixShouldMatch
                )
            }
            if let parsedPathOnlyMode {
                return SwiftDarwinLiteralPreflight.fixedLookaheadPathOnlyExitCode(
                    path: path,
                    literal: fixedLookahead.literal,
                    suffix: fixedLookahead.suffix,
                    suffixShouldMatch: fixedLookahead.suffixShouldMatch,
                    printWhenMatched: parsedPathOnlyMode == .matching,
                    nullTerminated: parsedNullPathTerminator,
                    crlfTerminated: parsedCrlf,
                    outputPath: parsedPathOnlyOutputPath
                )
            }
            if parsedPrintMode == .countMatches {
                guard parsedMaxCount != 0 else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.fixedLookaheadCountMatchesExitCode(
                    path: path,
                    literal: fixedLookahead.literal,
                    suffix: fixedLookahead.suffix,
                    suffixShouldMatch: fixedLookahead.suffixShouldMatch,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if parsedCount {
                return SwiftDarwinLiteralPreflight.fixedLookaheadCountLineExitCode(
                    path: path,
                    literal: fixedLookahead.literal,
                    suffix: fixedLookahead.suffix,
                    suffixShouldMatch: fixedLookahead.suffixShouldMatch,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if parsedPrintMode == .matchingLines,
               !parsedOnlyMatching,
               fixedLookahead.suffixShouldMatch {
                return SwiftDarwinLiteralPreflight.multiLiteralExitCode(
                    path: path,
                    literals: [fixedLookahead.literal + fixedLookahead.suffix],
                    maxCount: parsedMaxCount,
                    lineNumber: lineNumber,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
            if parsedPrintMode == .matchingLines,
               !parsedOnlyMatching {
                return SwiftDarwinLiteralPreflight.fixedLookaheadLineExitCode(
                    path: path,
                    literal: fixedLookahead.literal,
                    suffix: fixedLookahead.suffix,
                    suffixShouldMatch: fixedLookahead.suffixShouldMatch,
                    maxCount: parsedMaxCount,
                    lineNumber: lineNumber,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
        }

        if !fixedStrings,
           (patternCanStartWithDash || !pattern.hasPrefix("-")),
           path != "-",
           !asciiCaseInsensitive,
           !wordRegexp,
           !parsedLineRegexp,
           !parsedNullData,
           parsedMaxCount != 0,
           let fixedResetStart = fixedResetStartLiteral(
            pattern,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
           ) {
            if parsedQuiet {
                return SwiftDarwinLiteralPreflight.fixedLookbehindQuietExitCode(
                    path: path,
                    prefix: fixedResetStart.prefix,
                    literal: fixedResetStart.literal,
                    prefixShouldMatch: true
                )
            }
            if let parsedPathOnlyMode {
                return SwiftDarwinLiteralPreflight.fixedLookbehindPathOnlyExitCode(
                    path: path,
                    prefix: fixedResetStart.prefix,
                    literal: fixedResetStart.literal,
                    prefixShouldMatch: true,
                    printWhenMatched: parsedPathOnlyMode == .matching,
                    nullTerminated: parsedNullPathTerminator,
                    crlfTerminated: parsedCrlf,
                    outputPath: parsedPathOnlyOutputPath
                )
            }
            if parsedPrintMode == .countMatches {
                guard parsedMaxCount != 0 else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.fixedLookbehindCountMatchesExitCode(
                    path: path,
                    prefix: fixedResetStart.prefix,
                    literal: fixedResetStart.literal,
                    prefixShouldMatch: true,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if parsedCount {
                return SwiftDarwinLiteralPreflight.fixedLookbehindCountLineExitCode(
                    path: path,
                    prefix: fixedResetStart.prefix,
                    literal: fixedResetStart.literal,
                    prefixShouldMatch: true,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if parsedPrintMode == .matchingLines,
               !parsedOnlyMatching {
                return SwiftDarwinLiteralPreflight.multiLiteralExitCode(
                    path: path,
                    literals: [fixedResetStart.prefix + fixedResetStart.literal],
                    maxCount: parsedMaxCount,
                    lineNumber: lineNumber,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
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
           !asciiBoundary,
           parsedMaxCount != 0,
           let literals = multiLiteralAlternation(
            pattern,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
            ) {
            if parsedLineRegexp {
                guard !wordRegexp,
                      !parsedNullData,
                      !parsedCrlf else {
                    return nil
                }
                if asciiCaseInsensitive {
                    if parsedQuiet {
                        return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLineQuietExitCode(
                            path: path,
                            literals: literals
                        )
                    }
                    if let parsedPathOnlyMode {
                        return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLinePathOnlyExitCode(
                            path: path,
                            literals: literals,
                            printWhenMatched: parsedPathOnlyMode == .matching,
                            nullTerminated: parsedNullPathTerminator,
                            crlfTerminated: parsedCrlf,
                            outputPath: parsedPathOnlyOutputPath
                        )
                    }
                    if parsedPrintMode == .countMatches || parsedCount {
                        return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLineCountExitCode(
                            path: path,
                            literals: literals,
                            includeZero: parsedIncludeZero,
                            maxCount: parsedMaxCount,
                            countPrefix: parsedCountPrefix,
                            crlfTerminated: parsedCrlf
                        )
                    }
                    guard parsedPrintMode == .matchingLines else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLineExitCode(
                        path: path,
                        literals: literals,
                        maxCount: parsedMaxCount,
                        lineNumber: lineNumber,
                        lineNumberFieldSeparator: parsedFieldMatchSeparator,
                        linePrefix: parsedLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }
                if parsedQuiet {
                    return SwiftDarwinLiteralPreflight.multiLiteralExactLineQuietExitCode(
                        path: path,
                        literals: literals
                    )
                }
                if let parsedPathOnlyMode {
                    return SwiftDarwinLiteralPreflight.multiLiteralExactLinePathOnlyExitCode(
                        path: path,
                        literals: literals,
                        printWhenMatched: parsedPathOnlyMode == .matching,
                        nullTerminated: parsedNullPathTerminator,
                        crlfTerminated: parsedCrlf,
                        outputPath: parsedPathOnlyOutputPath
                    )
                }
                if parsedPrintMode == .countMatches {
                    return SwiftDarwinLiteralPreflight.multiLiteralExactLineCountExitCode(
                        path: path,
                        literals: literals,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                if parsedCount {
                    return SwiftDarwinLiteralPreflight.multiLiteralExactLineCountExitCode(
                        path: path,
                        literals: literals,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                return SwiftDarwinLiteralPreflight.multiLiteralExactLineExitCode(
                    path: path,
                    literals: literals,
                    maxCount: parsedMaxCount,
                    lineNumber: lineNumber,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
            if wordRegexp {
                if asciiCaseInsensitive {
                    if parsedPrintMode == .countMatches {
                        guard parsedMaxCount != 0 else {
                            return nil
                        }
                        return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralWordCountMatchesExitCode(
                            path: path,
                            literals: literals,
                            includeZero: parsedIncludeZero,
                            maxCount: parsedMaxCount,
                            countPrefix: parsedCountPrefix,
                            crlfTerminated: parsedCrlf
                        )
                    }
                    if parsedCount {
                        return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralWordCountLineExitCode(
                            path: path,
                            literals: literals,
                            includeZero: parsedIncludeZero,
                            maxCount: parsedMaxCount,
                            countPrefix: parsedCountPrefix,
                            crlfTerminated: parsedCrlf
                        )
                    }
                    return nil
                }
                if parsedPrintMode == .countMatches {
                    guard parsedMaxCount != 0 else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.multiLiteralWordCountMatchesExitCode(
                        path: path,
                        literals: literals,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                if parsedCount {
                    return SwiftDarwinLiteralPreflight.multiLiteralWordCountLineExitCode(
                        path: path,
                        literals: literals,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                return nil
            }
            if parsedOnlyMatchingAffectsPreflightOutput {
                if asciiCaseInsensitive {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralOnlyMatchingExitCode(
                        path: path,
                        literals: literals,
                        lineNumber: lineNumber,
                        maxCount: parsedMaxCount,
                        lineNumberFieldSeparator: parsedFieldMatchSeparator,
                        linePrefix: parsedLinePrefix,
                        headingPrefix: parsedHeadingPrefix
                    )
                }
                return SwiftDarwinLiteralPreflight.multiLiteralOnlyMatchingExitCode(
                    path: path,
                    literals: literals,
                    lineNumber: lineNumber,
                    maxCount: parsedMaxCount,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
            if parsedPrintMode == .countMatches {
                guard !asciiCaseInsensitive,
                      parsedMaxCount != 0 else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.multiLiteralCountMatchesExitCode(
                    path: path,
                    literals: literals,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if asciiCaseInsensitive {
                if parsedQuiet {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralQuietExitCode(
                        path: path,
                        literals: literals
                    )
                }
                if let parsedPathOnlyMode {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralPathOnlyExitCode(
                        path: path,
                        literals: literals,
                        printWhenMatched: parsedPathOnlyMode == .matching,
                        nullTerminated: parsedNullPathTerminator,
                        crlfTerminated: parsedCrlf,
                        outputPath: parsedPathOnlyOutputPath
                    )
                }
                if parsedCount {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralCountLineExitCode(
                        path: path,
                        literals: literals,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
            } else {
                if parsedQuiet {
                    return SwiftDarwinLiteralPreflight.multiLiteralQuietExitCode(
                        path: path,
                        literals: literals
                    )
                }
                if parsedCount {
                    return SwiftDarwinLiteralPreflight.multiLiteralCountLineExitCode(
                        path: path,
                        literals: literals,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                if let parsedPathOnlyMode {
                    return SwiftDarwinLiteralPreflight.multiLiteralPathOnlyExitCode(
                        path: path,
                        literals: literals,
                        printWhenMatched: parsedPathOnlyMode == .matching,
                        nullTerminated: parsedNullPathTerminator,
                        crlfTerminated: parsedCrlf,
                        outputPath: parsedPathOnlyOutputPath
                    )
                }
                if let exitCode = SwiftDarwinLiteralPreflight.multiLiteralExitCode(
                    path: path,
                    literals: literals,
                    maxCount: parsedMaxCount,
                    lineNumber: lineNumber,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
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
        if parsedOnlyMatchingAffectsPreflightOutput, !parsedLineRegexp {
            guard parsedPrintMode == .matchingLines,
                  parsedPathOnlyMode == nil,
                  !parsedQuiet,
                  !parsedCrlf else {
                return nil
            }
            if !asciiCaseInsensitive {
                guard !wordRegexp,
                      !asciiBoundary else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.multiLiteralOnlyMatchingExitCode(
                    path: path,
                    literals: [literal],
                    lineNumber: lineNumber,
                    maxCount: parsedMaxCount,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
            guard wordRegexp else {
                guard !asciiBoundary else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralOnlyMatchingExitCode(
                    path: path,
                    literals: [literal],
                    lineNumber: lineNumber,
                    maxCount: parsedMaxCount,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
            return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveWordOnlyMatchingExitCode(
                path: path,
                literal: literal,
                lineNumber: lineNumber,
                maxCount: parsedMaxCount,
                lineNumberFieldSeparator: parsedFieldMatchSeparator,
                linePrefix: parsedLinePrefix,
                headingPrefix: parsedHeadingPrefix
            )
        }
        if parsedQuiet {
            guard !asciiBoundary else {
                return nil
            }
            if asciiCaseInsensitive {
                if wordRegexp {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveWordQuietExitCode(
                        path: path,
                        literal: literal
                    )
                }
                if parsedLineRegexp {
                    guard !parsedNullData,
                          !parsedCrlf else {
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
                guard !parsedNullData,
                      !parsedCrlf else {
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
        if parsedPrintMode == .countMatches {
            if parsedLineRegexp {
                guard parsedPathOnlyMode == nil,
                      !wordRegexp,
                      !asciiBoundary,
                      !parsedNullData,
                      !parsedCrlf else {
                    return nil
                }
                if asciiCaseInsensitive {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLineCountExitCode(
                        path: path,
                        literal: literal,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                return SwiftDarwinLiteralPreflight.exactLineCountExitCode(
                    path: path,
                    literal: literal,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            guard parsedPathOnlyMode == nil,
                  !parsedLineRegexp,
                  !asciiBoundary else {
                return nil
            }
            if wordRegexp {
                if asciiCaseInsensitive {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveWordCountMatchesExitCode(
                        path: path,
                        literal: literal,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                return SwiftDarwinLiteralPreflight.wordCountMatchesExitCode(
                    path: path,
                    literal: literal,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if asciiCaseInsensitive {
                return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveCountMatchesExitCode(
                    path: path,
                    literal: literal,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            return SwiftDarwinLiteralPreflight.countMatchesExitCode(
                path: path,
                literal: literal,
                includeZero: parsedIncludeZero,
                maxCount: parsedMaxCount,
                countPrefix: parsedCountPrefix,
                crlfTerminated: parsedCrlf
            )
        }
        if parsedCount {
            guard parsedPathOnlyMode == nil,
                  !asciiBoundary else {
                return nil
            }
            if wordRegexp {
                guard !parsedLineRegexp else {
                    return nil
                }
                if asciiCaseInsensitive {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveWordCountLineExitCode(
                        path: path,
                        literal: literal,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                return SwiftDarwinLiteralPreflight.wordCountLineExitCode(
                    path: path,
                    literal: literal,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if asciiCaseInsensitive {
                if parsedLineRegexp {
                    guard !parsedNullData,
                          !parsedCrlf else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLineCountExitCode(
                        path: path,
                        literal: literal,
                        includeZero: parsedIncludeZero,
                        maxCount: parsedMaxCount,
                        countPrefix: parsedCountPrefix,
                        crlfTerminated: parsedCrlf
                    )
                }
                return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveMultiLiteralCountLineExitCode(
                    path: path,
                    literals: [literal],
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if parsedLineRegexp {
                guard !parsedNullData,
                      !parsedCrlf else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.exactLineCountExitCode(
                    path: path,
                    literal: literal,
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            if parsedMaxCount == nil || parsedWithFilename {
                return SwiftDarwinLiteralPreflight.multiLiteralCountLineExitCode(
                    path: path,
                    literals: [literal],
                    includeZero: parsedIncludeZero,
                    maxCount: parsedMaxCount,
                    countPrefix: parsedCountPrefix,
                    crlfTerminated: parsedCrlf
                )
            }
            guard let parsedMaxCount else {
                return nil
            }
            return SwiftDarwinLiteralPreflight.countLineExitCode(
                path: path,
                literal: literal,
                includeZero: parsedIncludeZero,
                maxCount: parsedMaxCount,
                crlfTerminated: parsedCrlf
            )
        }
        if let parsedPathOnlyMode {
            guard !asciiBoundary else {
                return nil
            }
            if asciiCaseInsensitive {
                if wordRegexp {
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveWordPathOnlyExitCode(
                        path: path,
                        literal: literal,
                        printWhenMatched: parsedPathOnlyMode == .matching,
                        nullTerminated: parsedNullPathTerminator,
                        crlfTerminated: parsedCrlf,
                        outputPath: parsedPathOnlyOutputPath
                    )
                }
                if parsedLineRegexp {
                    guard !parsedNullData,
                          !parsedCrlf else {
                        return nil
                    }
                    return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLinePathOnlyExitCode(
                        path: path,
                        literal: literal,
                        printWhenMatched: parsedPathOnlyMode == .matching,
                        nullTerminated: parsedNullPathTerminator,
                        crlfTerminated: parsedCrlf,
                        outputPath: parsedPathOnlyOutputPath
                    )
                }
                return SwiftDarwinLiteralPreflight.asciiCaseInsensitivePathOnlyExitCode(
                    path: path,
                    literal: literal,
                    printWhenMatched: parsedPathOnlyMode == .matching,
                    nullTerminated: parsedNullPathTerminator,
                    crlfTerminated: parsedCrlf,
                    outputPath: parsedPathOnlyOutputPath
                )
            }
            if wordRegexp {
                return SwiftDarwinLiteralPreflight.wordPathOnlyExitCode(
                    path: path,
                    literal: literal,
                    printWhenMatched: parsedPathOnlyMode == .matching,
                    nullTerminated: parsedNullPathTerminator,
                    crlfTerminated: parsedCrlf,
                    outputPath: parsedPathOnlyOutputPath
                )
            }
            if parsedLineRegexp {
                guard !parsedNullData,
                      !parsedCrlf else {
                    return nil
                }
                return SwiftDarwinLiteralPreflight.exactLinePathOnlyExitCode(
                    path: path,
                    literal: literal,
                    printWhenMatched: parsedPathOnlyMode == .matching,
                    nullTerminated: parsedNullPathTerminator,
                    crlfTerminated: parsedCrlf,
                    outputPath: parsedPathOnlyOutputPath
                )
            }
            return SwiftDarwinLiteralPreflight.pathOnlyExitCode(
                path: path,
                literal: literal,
                printWhenMatched: parsedPathOnlyMode == .matching,
                nullTerminated: parsedNullPathTerminator,
                crlfTerminated: parsedCrlf,
                outputPath: parsedPathOnlyOutputPath
            )
        }
        if parsedLineRegexp {
            guard !asciiBoundary,
                  !parsedNullData,
                  !parsedCrlf,
                  !parsedCount,
                  parsedPathOnlyMode == nil,
                  !parsedQuiet else {
                return nil
            }
            if asciiCaseInsensitive {
                return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveExactLineExitCode(
                    path: path,
                    literals: [literal],
                    maxCount: parsedMaxCount,
                    lineNumber: lineNumber,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
            return SwiftDarwinLiteralPreflight.exactLineExitCode(
                path: path,
                literal: literal,
                maxCount: parsedMaxCount,
                lineNumber: lineNumber,
                lineNumberFieldSeparator: parsedFieldMatchSeparator,
                linePrefix: parsedLinePrefix,
                headingPrefix: parsedHeadingPrefix
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
                lineNumber: lineNumber,
                lineNumberFieldSeparator: parsedFieldMatchSeparator,
                linePrefix: parsedLinePrefix,
                headingPrefix: parsedHeadingPrefix
            )
        }
        if wordRegexp {
            guard !noMmap,
                  !asciiBoundary else {
                return nil
            }
            if asciiCaseInsensitive {
                return SwiftDarwinLiteralPreflight.asciiCaseInsensitiveWordLineExitCode(
                    path: path,
                    literal: literal,
                    lineNumber: lineNumber,
                    lineNumberFieldSeparator: parsedFieldMatchSeparator,
                    linePrefix: parsedLinePrefix,
                    headingPrefix: parsedHeadingPrefix
                )
            }
            return SwiftDarwinLiteralPreflight.wordLineExitCode(
                path: path,
                literal: literal,
                lineNumber: lineNumber,
                lineNumberFieldSeparator: parsedFieldMatchSeparator,
                linePrefix: parsedLinePrefix,
                headingPrefix: parsedHeadingPrefix
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
                asciiBoundary: asciiBoundary,
                lineNumberFieldSeparator: parsedFieldMatchSeparator,
                linePrefix: parsedLinePrefix,
                headingPrefix: parsedHeadingPrefix
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
                lineNumber: lineNumber,
                lineNumberFieldSeparator: parsedFieldMatchSeparator,
                linePrefix: parsedLinePrefix,
                headingPrefix: parsedHeadingPrefix
            )
        }
        return SwiftDarwinLiteralPreflight.exitCode(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            lineNumber: lineNumber,
            asciiBoundary: asciiBoundary,
            lineNumberFieldSeparator: parsedFieldMatchSeparator,
            linePrefix: parsedLinePrefix,
            headingPrefix: parsedHeadingPrefix
        )
    }

    private static func leadingArgumentsDisableConfigForPreflight(_ arguments: [String]) -> Bool {
        for argument in arguments {
            if argument == "--no-config" {
                return true
            }
            switch argument {
            case "--line-buffered",
                 "--block-buffered",
                 "--no-line-buffered",
                 "--messages",
                 "--no-messages":
                continue
            default:
                return false
            }
        }
        return false
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

    private static func fixedLookbehindLiteral(
        _ pattern: String,
        allowPCREQuotedLiterals: Bool
    ) -> (prefix: [UInt8], literal: [UInt8], prefixShouldMatch: Bool)? {
        let positiveMarker = "(?<="
        let negativeMarker = "(?<!"
        let marker: String
        let prefixShouldMatch: Bool
        if pattern.hasPrefix(positiveMarker) {
            marker = positiveMarker
            prefixShouldMatch = true
        } else if pattern.hasPrefix(negativeMarker) {
            marker = negativeMarker
            prefixShouldMatch = false
        } else {
            return nil
        }
        guard let close = firstUnescapedClosingParen(in: pattern.dropFirst(marker.count)) else {
            return nil
        }
        let prefixStart = pattern.index(pattern.startIndex, offsetBy: marker.count)
        let rawPrefix = String(pattern[prefixStart..<close])
        let literalStart = pattern.index(after: close)
        let rawLiteral = String(pattern[literalStart...])
        guard let prefix = RegexLiteralParser.literal(
            fromPlainRegexPattern: rawPrefix,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
        ),
              let literal = RegexLiteralParser.literal(
                fromPlainRegexPattern: rawLiteral,
                allowPCREQuotedLiterals: allowPCREQuotedLiterals
              ) else {
            return nil
        }
        let prefixBytes = Array(prefix.utf8)
        let literalBytes = Array(literal.utf8)
        guard !prefixBytes.isEmpty,
              !literalBytes.isEmpty,
              !prefixBytes.contains(UInt8(ascii: "\n")),
              !literalBytes.contains(UInt8(ascii: "\n")),
              !prefixBytes.contains(UInt8(ascii: "\r")),
              !literalBytes.contains(UInt8(ascii: "\r")),
              prefixBytes.allSatisfy({ $0 < 0x80 }),
              literalBytes.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        return (prefixBytes, literalBytes, prefixShouldMatch)
    }

    private static func fixedLookaheadLiteral(
        _ pattern: String,
        allowPCREQuotedLiterals: Bool
    ) -> (literal: [UInt8], suffix: [UInt8], suffixShouldMatch: Bool)? {
        let positiveMarker = "(?="
        let negativeMarker = "(?!"
        let markerRange: Range<String.Index>
        let suffixShouldMatch: Bool
        if pattern.hasSuffix(")"), let range = pattern.range(of: positiveMarker) {
            markerRange = range
            suffixShouldMatch = true
        } else if pattern.hasSuffix(")"), let range = pattern.range(of: negativeMarker) {
            markerRange = range
            suffixShouldMatch = false
        } else {
            return nil
        }
        let rawLiteral = String(pattern[..<markerRange.lowerBound])
        let suffixEnd = pattern.index(before: pattern.endIndex)
        let rawSuffix = String(pattern[markerRange.upperBound..<suffixEnd])
        guard let literal = RegexLiteralParser.literal(
            fromPlainRegexPattern: rawLiteral,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
        ),
              let suffix = RegexLiteralParser.literal(
                fromPlainRegexPattern: rawSuffix,
                allowPCREQuotedLiterals: allowPCREQuotedLiterals
              ) else {
            return nil
        }
        let literalBytes = Array(literal.utf8)
        let suffixBytes = Array(suffix.utf8)
        guard !literalBytes.isEmpty,
              !suffixBytes.isEmpty,
              !literalBytes.contains(UInt8(ascii: "\n")),
              !suffixBytes.contains(UInt8(ascii: "\n")),
              !literalBytes.contains(UInt8(ascii: "\r")),
              !suffixBytes.contains(UInt8(ascii: "\r")),
              literalBytes.allSatisfy({ $0 < 0x80 }),
              suffixBytes.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        return (literalBytes, suffixBytes, suffixShouldMatch)
    }

    private static func fixedResetStartLiteral(
        _ pattern: String,
        allowPCREQuotedLiterals: Bool
    ) -> (prefix: [UInt8], literal: [UInt8])? {
        guard allowPCREQuotedLiterals,
              let resetRange = RegexLiteralParser.firstUnescapedResetStart(in: pattern) else {
            return nil
        }
        let rawPrefix = String(pattern[..<resetRange.lowerBound])
        let rawLiteral = String(pattern[resetRange.upperBound...])
        guard let prefix = RegexLiteralParser.literal(
            fromPlainRegexPattern: rawPrefix,
            allowPCREQuotedLiterals: allowPCREQuotedLiterals
        ),
              let literal = RegexLiteralParser.literal(
                fromPlainRegexPattern: rawLiteral,
                allowPCREQuotedLiterals: allowPCREQuotedLiterals
              ) else {
            return nil
        }
        let prefixBytes = Array(prefix.utf8)
        let literalBytes = Array(literal.utf8)
        guard !prefixBytes.isEmpty,
              !literalBytes.isEmpty,
              !prefixBytes.contains(UInt8(ascii: "\n")),
              !literalBytes.contains(UInt8(ascii: "\n")),
              !prefixBytes.contains(UInt8(ascii: "\r")),
              !literalBytes.contains(UInt8(ascii: "\r")),
              prefixBytes.allSatisfy({ $0 < 0x80 }),
              literalBytes.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        return (prefixBytes, literalBytes)
    }

    private static func firstUnescapedClosingParen(in text: Substring) -> String.Index? {
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                if character == "Q" {
                    var quotedIndex = text.index(after: index)
                    var closedQuote = false
                    while quotedIndex < text.endIndex {
                        if text[quotedIndex] == "\\" {
                            let quoteEscapeIndex = text.index(after: quotedIndex)
                            if quoteEscapeIndex < text.endIndex,
                               text[quoteEscapeIndex] == "E" {
                                index = text.index(after: quoteEscapeIndex)
                                closedQuote = true
                                break
                            }
                        }
                        quotedIndex = text.index(after: quotedIndex)
                    }
                    guard closedQuote else {
                        return nil
                    }
                    escaped = false
                    continue
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == ")" {
                return index
            }
            index = text.index(after: index)
        }
        return nil
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

    private static func explicitRegexpPatternLiterals(
        _ patterns: [String],
        fixedStrings: Bool,
        allowPCREQuotedLiterals: Bool
    ) -> [[UInt8]]? {
        guard patterns.count > 1 else {
            return nil
        }

        var literalBytes: [[UInt8]] = []
        literalBytes.reserveCapacity(patterns.count)
        for pattern in patterns {
            if fixedStrings {
                literalBytes.append(Array(pattern.utf8))
                continue
            }
            if let alternationLiterals = multiLiteralAlternation(
                pattern,
                allowPCREQuotedLiterals: allowPCREQuotedLiterals
            ) {
                literalBytes.append(contentsOf: alternationLiterals)
                continue
            }
            guard let literal = RegexLiteralParser.literal(
                fromPlainRegexPattern: pattern,
                allowPCREQuotedLiterals: allowPCREQuotedLiterals
            ) else {
                return nil
            }
            literalBytes.append(Array(literal.utf8))
        }
        guard literalBytes.count > 1,
              literalBytes.count <= 64,
              literalBytes.allSatisfy({
                  !$0.isEmpty && !$0.contains(UInt8(ascii: "\n"))
              }) else {
            return nil
        }
        return literalBytes
    }
    #endif
}
