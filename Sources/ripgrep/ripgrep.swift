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
        guard arguments.count == 2,
              getenv("RIPGREP_CONFIG_PATH") == nil else {
            return nil
        }

        let pattern = arguments[0]
        guard !pattern.hasPrefix("-"),
              arguments[1] != "-",
              isPlainDarwinLiteral(pattern) else {
            return nil
        }

        let literal = Array(pattern.utf8)
        guard !literal.isEmpty else {
            return nil
        }

        let result = arguments[1].withCString { pathPointer in
            literal.withUnsafeBufferPointer { needle in
                rg_darwin_write_literal_file_lines(
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
