import Foundation

public struct MatchSpan: Equatable, Sendable {
    public let startColumn: Int
    public let endColumn: Int
    public let text: String
    public let replacement: String?

    public init(startColumn: Int, endColumn: Int, text: String, replacement: String? = nil) {
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.text = text
        self.replacement = replacement
    }
}

public struct SearchMatch: Equatable, Sendable {
    public let fileURL: URL
    public let lineNumber: Int
    public let column: Int?
    public let line: String
    public let matchCount: Int
    public let spans: [MatchSpan]

    public init(
        fileURL: URL,
        lineNumber: Int,
        column: Int?,
        line: String,
        matchCount: Int,
        spans: [MatchSpan] = []
    ) {
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.column = column
        self.line = line
        self.matchCount = matchCount
        self.spans = spans
    }
}

public struct SearchLine: Equatable, Sendable {
    public let lineNumber: Int
    public let line: String

    public init(lineNumber: Int, line: String) {
        self.lineNumber = lineNumber
        self.line = line
    }
}

public struct SearchFileResult: Equatable, Sendable {
    public let fileURL: URL
    public let matches: [SearchMatch]
    public let lines: [SearchLine]
    public let binaryByteOffset: Int?
    public let hasBinaryMatch: Bool
    public let searched: Bool

    public init(
        fileURL: URL,
        matches: [SearchMatch],
        lines: [SearchLine] = [],
        binaryByteOffset: Int? = nil,
        hasBinaryMatch: Bool = false,
        searched: Bool = true
    ) {
        self.fileURL = fileURL
        self.matches = matches
        self.lines = lines
        self.binaryByteOffset = binaryByteOffset
        self.hasBinaryMatch = hasBinaryMatch
        self.searched = searched
    }

    public var hasMatch: Bool {
        hasBinaryMatch || !matches.isEmpty
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
