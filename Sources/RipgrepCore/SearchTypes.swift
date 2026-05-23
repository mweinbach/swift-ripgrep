import Foundation

public struct MatchSpan: Equatable, Sendable {
    public let startColumn: Int
    public let endColumn: Int
    public let startByte: Int
    public let endByte: Int
    public let text: String
    public let replacement: String?

    public init(
        startColumn: Int,
        endColumn: Int,
        startByte: Int,
        endByte: Int,
        text: String,
        replacement: String? = nil
    ) {
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.startByte = startByte
        self.endByte = endByte
        self.text = text
        self.replacement = replacement
    }
}

public struct SearchMatch: Equatable, Sendable {
    public let fileURL: URL
    public let lineNumber: Int
    public let column: Int?
    public let line: String
    public let lineTerminator: String
    public let absoluteOffset: Int
    public let matchCount: Int
    public let spans: [MatchSpan]

    public init(
        fileURL: URL,
        lineNumber: Int,
        column: Int?,
        line: String,
        lineTerminator: String = "",
        absoluteOffset: Int = 0,
        matchCount: Int,
        spans: [MatchSpan] = []
    ) {
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.column = column
        self.line = line
        self.lineTerminator = lineTerminator
        self.absoluteOffset = absoluteOffset
        self.matchCount = matchCount
        self.spans = spans
    }

    public var lineWithTerminator: String {
        line + lineTerminator
    }
}

public struct SearchLine: Equatable, Sendable {
    public let lineNumber: Int
    public let line: String
    public let lineTerminator: String
    public let absoluteOffset: Int

    public init(lineNumber: Int, line: String, lineTerminator: String = "", absoluteOffset: Int = 0) {
        self.lineNumber = lineNumber
        self.line = line
        self.lineTerminator = lineTerminator
        self.absoluteOffset = absoluteOffset
    }

    public var lineWithTerminator: String {
        line + lineTerminator
    }
}

public struct SearchFileResult: Equatable, Sendable {
    public let fileURL: URL
    public let matches: [SearchMatch]
    public let lines: [SearchLine]
    public let binaryByteOffset: Int?
    public let hasBinaryMatch: Bool
    public let stoppedBinaryAfterMatch: Bool
    public let bytesSearched: Int
    public let searched: Bool

    public init(
        fileURL: URL,
        matches: [SearchMatch],
        lines: [SearchLine] = [],
        binaryByteOffset: Int? = nil,
        hasBinaryMatch: Bool = false,
        stoppedBinaryAfterMatch: Bool = false,
        bytesSearched: Int = 0,
        searched: Bool = true
    ) {
        self.fileURL = fileURL
        self.matches = matches
        self.lines = lines
        self.binaryByteOffset = binaryByteOffset
        self.hasBinaryMatch = hasBinaryMatch
        self.stoppedBinaryAfterMatch = stoppedBinaryAfterMatch
        self.bytesSearched = bytesSearched
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
    public let messages: [String]
    public let diagnostics: [String]
    public let filtered: Bool

    public init(
        files: [SearchFileResult],
        summary: SearchSummary,
        messages: [String] = [],
        diagnostics: [String] = [],
        filtered: Bool = false
    ) {
        self.files = files
        self.summary = summary
        self.messages = messages
        self.diagnostics = diagnostics
        self.filtered = filtered
    }

    public var hasMatch: Bool {
        summary.filesWithMatches > 0
    }
}

public enum RipgrepError: Error, CustomStringConvertible, Equatable, Sendable {
    case emptyPattern
    case missingPath(String)
    case invalidRegex(String)
    case message(String)

    public var description: String {
        switch self {
        case .emptyPattern:
            return "pattern must not be empty"
        case .missingPath(let path):
            return "path does not exist: \(path)"
        case .invalidRegex(let message):
            return "regex parse error: \(message)"
        case .message(let message):
            return message
        }
    }
}

enum MatchedLineCounter {
    static func count(_ match: SearchMatch, options: RipgrepOptions) -> Int {
        if options.multiline {
            return multilineCount(match, options: options)
        }
        let terminator: Character = match.lineWithTerminator.contains("\0") ? "\0" : "\n"
        return max(1, match.lineWithTerminator.filter { $0 == terminator }.count)
    }

    private static func multilineCount(_ match: SearchMatch, options: RipgrepOptions) -> Int {
        var lineStarts = [0]
        let separator = options.nullData ? UInt8(0) : UInt8(ascii: "\n")
        for (offset, byte) in match.lineWithTerminator.utf8.enumerated() where byte == separator {
            lineStarts.append(offset + 1)
        }

        var covered = Set<Int>()
        for span in match.spans {
            let firstLine = lineIndex(containingRelativeByteOffset: span.startByte, lineStarts: lineStarts)
            let lastByte = max(span.startByte, span.endByte - 1)
            let lastLine = lineIndex(containingRelativeByteOffset: lastByte, lineStarts: lineStarts)
            for line in firstLine...lastLine {
                covered.insert(line)
            }
        }
        return max(1, covered.count)
    }

    private static func lineIndex(containingRelativeByteOffset byteOffset: Int, lineStarts: [Int]) -> Int {
        var lineIndex = 0
        for (index, start) in lineStarts.enumerated() where start <= byteOffset {
            lineIndex = index
        }
        return lineIndex
    }
}
