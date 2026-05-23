import Foundation

public struct SearchMatch: Equatable {
    public let fileURL: URL
    public let lineNumber: Int
    public let line: String

    public init(fileURL: URL, lineNumber: Int, line: String) {
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.line = line
    }
}

public enum RipgrepError: Error, CustomStringConvertible, Equatable {
    case emptyPattern
    case missingPath(String)

    public var description: String {
        switch self {
        case .emptyPattern:
            return "pattern must not be empty"
        case .missingPath(let path):
            return "path does not exist: \(path)"
        }
    }
}

public struct RipgrepSearcher {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func search(
        pattern: String,
        roots: [URL],
        ignoreCase: Bool = false
    ) throws -> [SearchMatch] {
        guard !pattern.isEmpty else {
            throw RipgrepError.emptyPattern
        }

        let needle = ignoreCase ? pattern.lowercased() : pattern
        var matches: [SearchMatch] = []

        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else {
                throw RipgrepError.missingPath(root.path)
            }

            for fileURL in try files(in: root) {
                matches.append(contentsOf: searchFile(
                    fileURL,
                    needle: needle,
                    ignoreCase: ignoreCase
                ))
            }
        }

        return matches.sorted {
            if $0.fileURL.path != $1.fileURL.path {
                return $0.fileURL.path < $1.fileURL.path
            }
            return $0.lineNumber < $1.lineNumber
        }
    }

    private func files(in url: URL) throws -> [URL] {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .nameKey,
        ])

        guard values.isSymbolicLink != true else {
            return []
        }

        if values.isRegularFile == true {
            return [url]
        }

        guard values.isDirectory == true else {
            return []
        }

        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .nameKey,
            ],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.path < $1.path }

        var files: [URL] = []
        for child in children {
            files.append(contentsOf: try self.files(in: child))
        }
        return files
    }

    private func searchFile(
        _ fileURL: URL,
        needle: String,
        ignoreCase: Bool
    ) -> [SearchMatch] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }

        var matches: [SearchMatch] = []
        let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        for (offset, lineSubstring) in lines.enumerated() {
            var line = String(lineSubstring)
            if line.hasSuffix("\r") {
                line.removeLast()
            }

            let haystack = ignoreCase ? line.lowercased() : line
            if haystack.contains(needle) {
                matches.append(SearchMatch(
                    fileURL: fileURL,
                    lineNumber: offset + 1,
                    line: line
                ))
            }
        }

        return matches
    }
}
