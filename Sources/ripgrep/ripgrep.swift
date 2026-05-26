import CRipgrepPlatform
import RipgrepCore

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
        #if canImport(Darwin)
        if let exitCode = runDarwinLiteralPreflight(arguments: Array(CommandLine.arguments.dropFirst())) {
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

        let arguments = darwinLiteralPreflightArguments(afterStrippingLeadingEngineSelectorFrom: arguments)
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
                  surroundingWordsLiteral(arguments[1]) != nil {
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
           let literal = surroundingWordsLiteral(pattern),
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
           let literal = surroundingWordsLiteral(pattern),
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
           let byteSet = singleByteAlternation(pattern),
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
              isPlainDarwinLiteral(pattern) else {
            return nil
        }

        let literal = Array(pattern.utf8)
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

    private static func darwinLiteralPreflightArguments(
        afterStrippingLeadingEngineSelectorFrom arguments: [String]
    ) -> [String] {
        guard let first = arguments.first else {
            return arguments
        }
        if isSingleArgumentEngineSelector(first) {
            return Array(arguments.dropFirst())
        }
        if arguments.count >= 2,
           first == "--engine",
           isEngineSelectorValue(arguments[1]) {
            return Array(arguments.dropFirst(2))
        }
        return arguments
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

    private static func isPlainDarwinLiteral(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, !pattern.utf8.contains(UInt8(ascii: "\n")) else {
            return false
        }
        let regexSyntax = "\\.^$*+?()[]{}|"
        return !pattern.contains { regexSyntax.contains($0) }
    }

    private static func surroundingWordsLiteral(_ pattern: String) -> String? {
        let prefix = #"\w+\s+"#
        let suffix = #"\s+\w+"#
        guard pattern.hasPrefix(prefix), pattern.hasSuffix(suffix) else {
            return nil
        }
        let literalStart = pattern.index(pattern.startIndex, offsetBy: prefix.count)
        let literalEnd = pattern.index(pattern.endIndex, offsetBy: -suffix.count)
        let literal = String(pattern[literalStart..<literalEnd])
        guard isPlainDarwinLiteral(literal) else {
            return nil
        }
        return literal
    }

    private static func singleByteAlternation(_ pattern: String) -> [UInt8]? {
        let parts = pattern.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count > 1 else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(parts.count)
        for part in parts {
            guard part.utf8.count == 1,
                  let byte = part.utf8.first,
                  byte < 0x80,
                  !isRegexSyntaxByte(byte) else {
                return nil
            }
            bytes.append(byte)
        }
        return bytes
    }

    private static func isRegexSyntaxByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "\\"),
             UInt8(ascii: "."),
             UInt8(ascii: "^"),
             UInt8(ascii: "$"),
             UInt8(ascii: "*"),
             UInt8(ascii: "+"),
             UInt8(ascii: "?"),
             UInt8(ascii: "("),
             UInt8(ascii: ")"),
             UInt8(ascii: "["),
             UInt8(ascii: "]"),
             UInt8(ascii: "{"),
             UInt8(ascii: "}"),
             UInt8(ascii: "|"):
            return true
        default:
            return false
        }
    }
    #endif
}
