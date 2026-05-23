import Foundation

public struct SearchMatch: Equatable, Sendable {
    public let fileURL: URL
    public let lineNumber: Int
    public let column: Int?
    public let line: String
    public let matchCount: Int

    public init(
        fileURL: URL,
        lineNumber: Int,
        column: Int?,
        line: String,
        matchCount: Int
    ) {
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.column = column
        self.line = line
        self.matchCount = matchCount
    }
}

public struct SearchFileResult: Equatable, Sendable {
    public let fileURL: URL
    public let matches: [SearchMatch]
    public let searched: Bool

    public init(fileURL: URL, matches: [SearchMatch], searched: Bool = true) {
        self.fileURL = fileURL
        self.matches = matches
        self.searched = searched
    }
}

public struct SearchSummary: Equatable, Sendable {
    public let filesSearched: Int
    public let filesWithMatches: Int
    public let matchedLines: Int
    public let totalMatches: Int

    public static let empty = SearchSummary(
        filesSearched: 0,
        filesWithMatches: 0,
        matchedLines: 0,
        totalMatches: 0
    )
}

public struct SearchResults: Equatable, Sendable {
    public let files: [SearchFileResult]
    public let summary: SearchSummary

    public var hasMatch: Bool {
        summary.filesWithMatches > 0
    }
}

public enum RipgrepError: Error, CustomStringConvertible, Equatable, Sendable {
    case emptyPattern
    case missingPath(String)
    case invalidRegex(String)

    public var description: String {
        switch self {
        case .emptyPattern:
            return "pattern must not be empty"
        case .missingPath(let path):
            return "path does not exist: \(path)"
        case .invalidRegex(let message):
            return "regex parse error: \(message)"
        }
    }
}
