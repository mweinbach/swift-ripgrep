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
        let exitCode = RipgrepCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(exitCode)
    }
}
