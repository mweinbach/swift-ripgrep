import Foundation

public enum RipgrepCLI {
    public static let version = "0.1.0"

    public struct OutputOptions: Equatable {
        public let showFilename: Bool
        public let showLineNumber: Bool

        public init(showFilename: Bool, showLineNumber: Bool) {
            self.showFilename = showFilename
            self.showLineNumber = showLineNumber
        }
    }

    public static func run(
        arguments: [String],
        stdout: (String) -> Void = { print($0) },
        stderr: (String) -> Void = { message in
            if let data = "\(message)\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        },
        fileManager: FileManager = .default,
        stdin: String? = nil
    ) -> Int32 {
        switch RipgrepArgumentParser.parse(arguments) {
        case .help:
            stdout(usage())
            return 0
        case .version:
            stdout("ripgrep \(version)")
            return 0
        case .error(let message):
            stderr(message)
            return 2
        case .run(let options):
            do {
                let searcher = RipgrepSearcher(fileManager: fileManager)
                let printer = StandardPrinter(options: options)

                if options.mode == .files {
                    for line in try printer.paths(searcher.files(options: options)) {
                        stdout(line)
                    }
                    return 0
                }

                let results = try searcher.search(options: options, stdin: stdin)
                for line in printer.lines(for: results) {
                    stdout(line)
                }

                return results.hasMatch ? 0 : 1
            } catch {
                stderr("error: \(error)")
                return 2
            }
        }
    }

    public static func usage() -> String {
        RipgrepArgumentParser.usage(version: version)
    }

    public static func format(
        _ match: SearchMatch,
        options: OutputOptions = OutputOptions(showFilename: true, showLineNumber: true)
    ) -> String {
        var ripgrepOptions = RipgrepOptions()
        ripgrepOptions.withFilename = options.showFilename
        ripgrepOptions.lineNumber = options.showLineNumber
        return StandardPrinter(options: ripgrepOptions).lines(for: SearchResults(
            files: [SearchFileResult(fileURL: match.fileURL, matches: [match])],
            summary: SearchSummary(
                filesSearched: 1,
                filesWithMatches: 1,
                matchedLines: 1,
                totalMatches: match.matchCount
            )
        )).first ?? match.line
    }
}
