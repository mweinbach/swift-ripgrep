import Foundation

public struct StandardPrinter {
    private let options: RipgrepOptions
    private let currentDirectory: String

    public init(
        options: RipgrepOptions,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.options = options
        self.currentDirectory = URL(fileURLWithPath: currentDirectory)
            .standardizedFileURL
            .path
    }

    public func lines(for results: SearchResults) -> [String] {
        guard !options.quiet else {
            return []
        }

        switch options.printMode {
        case .matchingLines:
            return results.files.flatMap { result in
                result.matches.map { format($0, showPath: showPath(for: results)) }
            }
        case .count:
            return results.files.map { result in
                let count = result.matches.count
                if showPath(for: results) {
                    return "\(displayPath(for: result.fileURL)):\(count)"
                }
                return "\(count)"
            }
        case .filesWithMatches:
            return results.files
                .filter { !$0.matches.isEmpty }
                .map { displayPath(for: $0.fileURL) }
        case .filesWithoutMatch:
            return results.files
                .filter { $0.matches.isEmpty }
                .map { displayPath(for: $0.fileURL) }
        }
    }

    public func paths(_ urls: [URL]) -> [String] {
        urls.map { displayPath(for: $0) }
    }

    private func format(_ match: SearchMatch, showPath: Bool) -> String {
        var fields: [String] = []
        if showPath {
            fields.append(displayPath(for: match.fileURL))
        }
        if options.wantsLineNumber {
            fields.append("\(match.lineNumber)")
        }
        if options.column, let column = match.column {
            fields.append("\(column)")
        }

        if fields.isEmpty {
            return match.line
        }
        return "\(fields.joined(separator: ":")):\(match.line)"
    }

    private func showPath(for results: SearchResults) -> Bool {
        if let withFilename = options.withFilename {
            return withFilename
        }
        if options.useStdin {
            return !options.roots.isEmpty
        }
        return results.files.count > 1 || options.effectiveRoots.contains { isDirectory($0) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func displayPath(for url: URL) -> String {
        if url.path == "-" {
            return "<stdin>"
        }

        let path = url.standardizedFileURL.path
        let prefix = currentDirectory.hasSuffix("/") ? currentDirectory : "\(currentDirectory)/"

        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }

        return path
    }
}
