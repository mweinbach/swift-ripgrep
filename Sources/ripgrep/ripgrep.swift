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

        let useMmap: Bool
        let pattern: String
        let path: String
        if arguments.count == 2 {
            useMmap = true
            pattern = arguments[0]
            path = arguments[1]
        } else if arguments.count == 3, arguments[0] == "--no-mmap" {
            useMmap = false
            pattern = arguments[1]
            path = arguments[2]
        } else {
            return nil
        }

        guard !pattern.hasPrefix("-"),
              path != "-",
              isPlainDarwinLiteral(pattern) else {
            return nil
        }

        let literal = Array(pattern.utf8)
        guard !literal.isEmpty else {
            return nil
        }

        let result = path.withCString { pathPointer in
            literal.withUnsafeBufferPointer { needle in
                if useMmap {
                    return rg_darwin_write_literal_file_lines(
                        pathPointer,
                        needle.baseAddress,
                        needle.count
                    )
                }
                return rg_darwin_write_literal_file_lines_no_mmap(
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

    private static func isPlainDarwinLiteral(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, !pattern.utf8.contains(UInt8(ascii: "\n")) else {
            return false
        }
        let regexSyntax = "\\.^$*+?()[]{}|"
        return !pattern.contains { regexSyntax.contains($0) }
    }
    #endif
}
