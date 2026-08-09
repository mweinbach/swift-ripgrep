import Foundation
import RipgrepCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(CRT)
import CRT
#endif

#if os(Windows)
import WinSDK
#endif

/// The non-macOS entry point. macOS uses `ripgrep.swift`, which owns the
/// Darwin preflight machinery and is excluded from portable builds.
@main
struct PortableRipgrepCommand {
    static func main() {
        #if os(Windows)
        _setmode(_fileno(stdin), _O_BINARY)
        _setmode(_fileno(stdout), _O_BINARY)
        _setmode(_fileno(stderr), _O_BINARY)
        #endif

        let arguments = Array(CommandLine.arguments.dropFirst())
        #if os(Windows) && arch(x86_64)
        if let exitCode = WindowsX86LiteralPreflight.run(arguments: arguments) {
            exit(exitCode)
        }
        #endif
        #if os(Linux) && arch(x86_64)
        if let exitCode = LinuxX86LiteralPreflight.run(arguments: arguments) {
            exit(exitCode)
        }
        #endif
        if arguments.first.map(mayUseUtilityFastPath) == true,
           let exitCode = RipgrepCLI.runUtilityFastPath(arguments: arguments) {
            exit(exitCode)
        }

        exit(RipgrepCLI.run(
            arguments: arguments,
            standardInputIsReadable: standardInputIsReadable()
        ))
    }

    private static func mayUseUtilityFastPath(_ argument: String) -> Bool {
        switch argument {
        case "-h", "--help", "-V", "--version", "--pcre2-version", "--generate":
            return true
        default:
            return argument.hasPrefix("--generate=")
        }
    }

    private static func standardInputIsReadable() -> Bool {
        #if os(Windows)
        if _isatty(_fileno(stdin)) == 0 {
            return true
        }
        guard let handle = GetStdHandle(STD_INPUT_HANDLE),
              handle != INVALID_HANDLE_VALUE else {
            return false
        }
        var consoleMode: DWORD = 0
        return !GetConsoleMode(handle, &consoleMode)
        #elseif canImport(Glibc) || canImport(Musl)
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
}
