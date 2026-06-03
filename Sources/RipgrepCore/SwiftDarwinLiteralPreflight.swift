import Foundation

#if !canImport(CRipgrepPlatform) && canImport(Darwin)
import Darwin

public enum SwiftDarwinLiteralPreflight {
    private final class QuietStatsProbeAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var bytesSearched = 0
        private var hasMatch = false
        private var failed = false

        func record(bytes: Int, matched: Bool) {
            lock.lock()
            bytesSearched += bytes
            hasMatch = hasMatch || matched
            lock.unlock()
        }

        func recordMatch() {
            lock.lock()
            hasMatch = true
            lock.unlock()
        }

        func recordFailure() {
            lock.lock()
            failed = true
            lock.unlock()
        }

        func snapshot() -> (bytesSearched: Int, hasMatch: Bool, failed: Bool) {
            lock.lock()
            let result = (bytesSearched, hasMatch, failed)
            lock.unlock()
            return result
        }
    }

    private final class QuietStatsCountAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func add(_ value: Int) {
            lock.lock()
            count += value
            lock.unlock()
        }

        func snapshot() -> Int {
            lock.lock()
            let result = count
            lock.unlock()
            return result
        }
    }

    private final class QuietStatsMatchedFileAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var result: rg_darwin_literal_file_result?
        private var matchCount: Int?
        private var failed = false

        func recordResult(_ value: rg_darwin_literal_file_result?) {
            lock.lock()
            if let value, value.status >= 0 {
                result = value
            } else {
                failed = true
            }
            lock.unlock()
        }

        func recordMatchCount(_ value: Int) {
            lock.lock()
            matchCount = value
            lock.unlock()
        }

        func snapshot() -> (result: rg_darwin_literal_file_result?, matchCount: Int?, failed: Bool) {
            lock.lock()
            let snapshot = (result, matchCount, failed)
            lock.unlock()
            return snapshot
        }
    }

    private final class QuietStatsSummaryAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var totalMatches = 0
        private var matchedLines = 0
        private var filesWithMatches = 0
        private var bytesSearched = 0
        private var failed = false

        func record(totalMatches: Int, matchedLines: Int, bytesSearched: Int) {
            lock.lock()
            self.totalMatches += totalMatches
            self.matchedLines += matchedLines
            self.bytesSearched += bytesSearched
            if matchedLines > 0 {
                filesWithMatches += 1
            }
            lock.unlock()
        }

        func recordFailure() {
            lock.lock()
            failed = true
            lock.unlock()
        }

        func snapshot() -> (
            totalMatches: Int,
            matchedLines: Int,
            filesWithMatches: Int,
            bytesSearched: Int,
            failed: Bool
        ) {
            lock.lock()
            let snapshot = (totalMatches, matchedLines, filesWithMatches, bytesSearched, failed)
            lock.unlock()
            return snapshot
        }
    }

    private static func writePathTerminator(
        nullTerminated: Bool,
        crlfTerminated: Bool
    ) -> Bool {
        if nullTerminated {
            return fputc(0, Darwin.stdout) != EOF
        } else if crlfTerminated {
            return fputc(Int32(UInt8(ascii: "\r")), Darwin.stdout) != EOF
                && fputc(Int32(UInt8(ascii: "\n")), Darwin.stdout) != EOF
        } else {
            return fputc(Int32(UInt8(ascii: "\n")), Darwin.stdout) != EOF
        }
    }

    private static func writeCountOutput(
        _ count: Int,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool
    ) -> Bool {
        guard var output = rgSwiftStdoutBuffer(capacity: max(64, countPrefix.count + 32)) else {
            return false
        }
        defer {
            output.deallocate()
        }
        guard output.writeBytes(countPrefix),
              output.writeLineNumberPrefix(count, fieldSeparator: []) else {
            return false
        }
        if crlfTerminated,
           !output.writeByte(UInt8(ascii: "\r")) {
            return false
        }
        guard output.writeByte(UInt8(ascii: "\n")) else {
            return false
        }
        return output.flush()
    }

    private static let statsMatchesSuffix = Array(" matches\n".utf8)
    private static let statsMatchedLinesSuffix = Array(" matched lines\n".utf8)
    private static let statsFilesWithMatchesSuffix = Array(" files contained matches\n".utf8)
    private static let statsFilesSearchedSuffix = Array(" files searched\n".utf8)
    private static let statsBytesPrintedSuffix = Array(" bytes printed\n".utf8)
    private static let statsBytesSearchedSuffix = Array(" bytes searched\n".utf8)
    private static let statsElapsedSuffix = Array(
        "0.000000 seconds spent searching\n0.000000 seconds total\n".utf8
    )
    private static let omittedLongMatchingLine = Array("[Omitted long matching line]\n".utf8)
    private static let omittedLongLineWithPrefix = Array("[Omitted long line with ".utf8)
    private static let omittedLongLineWithSuffix = Array(" matches]\n".utf8)
    private static let previewOmittedEndSuffix = Array(" [... omitted end of long line]\n".utf8)
    private static let previewMoreMatchesPrefix = Array(" [... ".utf8)
    private static let previewMoreMatchSuffix = Array(" more match]\n".utf8)
    private static let previewMoreMatchesSuffix = Array(" more matches]\n".utf8)
    private static let jsonNoMatchSummaryPrefix = Array(
        #"{"data":{"elapsed_total":{"human":"0.000000s","nanos":0,"secs":0},"stats":{"bytes_printed":0,"bytes_searched":"#.utf8
    )
    private static let jsonNoMatchSummarySuffix = Array(
        #","elapsed":{"human":"0.000000s","nanos":0,"secs":0},"matched_lines":0,"matches":0,"searches":1,"searches_with_match":0}},"type":"summary"}"#.utf8
    )

    public static func zeroCountOutputExitCode(
        countPrefix: [UInt8],
        crlfTerminated: Bool
    ) -> Int32? {
        guard writeCountOutput(0, countPrefix: countPrefix, crlfTerminated: crlfTerminated) else {
            return nil
        }
        return 1
    }

    private static func appendLineNumberPrefix(
        _ lineNumber: Int,
        to output: inout Data,
        fieldSeparator: [UInt8]
    ) {
        output.append(Data("\(lineNumber)".utf8))
        output.append(contentsOf: fieldSeparator)
    }

    private static func appendLinePrefix(_ linePrefix: [UInt8], to output: inout Data) {
        guard !linePrefix.isEmpty else {
            return
        }
        output.append(contentsOf: linePrefix)
    }

    private static func appendHeadingPrefix(
        _ headingPrefix: [UInt8],
        emittedHeading: inout Bool,
        to output: inout Data
    ) {
        guard !emittedHeading else {
            return
        }
        emittedHeading = true
        output.append(contentsOf: headingPrefix)
    }

    private static func writePathOnlyOutput(
        path: String,
        outputPath: [UInt8]?,
        nullTerminated: Bool,
        crlfTerminated: Bool
    ) -> Bool {
        let terminatorCount = crlfTerminated ? 2 : 1
        let pathByteCount = outputPath?.count ?? path.utf8.count
        guard var output = rgSwiftStdoutBuffer(capacity: max(64, pathByteCount + terminatorCount)) else {
            return false
        }
        defer {
            output.deallocate()
        }
        let wrotePath: Bool
        if let outputPath {
            wrotePath = output.writeBytes(outputPath)
        } else {
            var path = path
            wrotePath = path.withUTF8 { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return true
                }
                return output.write(baseAddress, count: bytes.count)
            }
        }
        guard wrotePath else {
            return false
        }
        if nullTerminated {
            guard output.writeByte(0) else {
                return false
            }
        } else if crlfTerminated {
            guard output.writeByte(UInt8(ascii: "\r")),
                  output.writeByte(UInt8(ascii: "\n")) else {
                return false
            }
        } else {
            guard output.writeByte(UInt8(ascii: "\n")) else {
                return false
            }
        }
        guard output.flush() else {
            return false
        }
        return true
    }

    public static func quietExitCode(
        path: String,
        literal: [UInt8]
    ) -> Int32? {
        guard let matchedLineCount = literalLineMatchCount(
            path: path,
            literal: literal,
            asciiCaseInsensitive: false,
            emitLines: false,
            maxCount: 1,
            knownTextHaystack: true
        ) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func noMatchExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        wordRegexp: Bool
    ) -> Int32? {
        guard noMatchByteCount(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            wordRegexp: wordRegexp
        ) != nil else {
            return nil
        }
        return 1
    }

    public static func noMatchCountOutputExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        wordRegexp: Bool,
        countPrefix: [UInt8],
        crlfTerminated: Bool,
        stats: Bool
    ) -> Int32? {
        guard let bytesSearched = noMatchByteCount(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            wordRegexp: wordRegexp
        ) else {
            return nil
        }
        guard writeCountOutput(0, countPrefix: countPrefix, crlfTerminated: crlfTerminated) else {
            return nil
        }
        if stats {
            guard fflush(Darwin.stdout) == 0 else {
                return nil
            }
            return writeNoMatchSummary(bytesSearched: bytesSearched, json: false)
        }
        return 1
    }

    public static func noMatchPathOutputExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        wordRegexp: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool,
        outputPath: [UInt8]?,
        stats: Bool
    ) -> Int32? {
        guard let bytesSearched = noMatchByteCount(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            wordRegexp: wordRegexp
        ) else {
            return nil
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        if stats {
            guard fflush(Darwin.stdout) == 0 else {
                return nil
            }
            return writeNoMatchSummary(bytesSearched: bytesSearched, json: false, exitCode: 0)
        }
        return 0
    }

    public static func matchedPathSuppressedExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        wordRegexp: Bool
    ) -> Int32? {
        let matched: Bool?
        if asciiCaseInsensitive && wordRegexp {
            matched = asciiCaseInsensitiveWordMatched(path: path, literal: literal)
        } else if asciiCaseInsensitive {
            matched = containsASCIICaseInsensitiveLiteral(path: path, literal: literal)
        } else if wordRegexp {
            matched = containsWordLiteral(path: path, literal: literal)
        } else {
            matched = containsLiteral(path: path, literal: literal)
        }
        guard matched == true else {
            return nil
        }
        return 1
    }

    public static func matchedFilesWithoutMatchStatsExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        wordRegexp: Bool
    ) -> Int32? {
        guard let stats = matchedSummaryStats(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            wordRegexp: wordRegexp
        ), stats.matchedLines > 0 else {
            return nil
        }
        return writeStatsSummary(
            totalMatches: stats.totalMatches,
            matchedLines: stats.matchedLines,
            filesWithMatches: 1,
            filesSearched: 1,
            bytesSearched: stats.bytesSearched,
            exitCode: 1
        )
    }

    public static func matchedPathStatsExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        wordRegexp: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool,
        outputPath: [UInt8]?
    ) -> Int32? {
        guard let stats = matchedSummaryStats(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            wordRegexp: wordRegexp
        ), stats.matchedLines > 0 else {
            return nil
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ), fflush(Darwin.stdout) == 0 else {
            return nil
        }
        return writeStatsSummary(
            totalMatches: stats.totalMatches,
            matchedLines: stats.matchedLines,
            filesWithMatches: 1,
            filesSearched: 1,
            bytesSearched: stats.bytesSearched,
            exitCode: 0
        )
    }

    public static func matchedCountStatsExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        wordRegexp: Bool,
        countMatches: Bool,
        includeZero: Bool,
        countPrefix: [UInt8],
        crlfTerminated: Bool
    ) -> Int32? {
        guard let stats = matchedSummaryStats(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            wordRegexp: wordRegexp
        ), stats.matchedLines > 0 else {
            return nil
        }
        let count = countMatches ? stats.totalMatches : stats.matchedLines
        guard count > 0 || includeZero else {
            return nil
        }
        guard writeCountOutput(
            count,
            countPrefix: countPrefix,
            crlfTerminated: crlfTerminated
        ), fflush(Darwin.stdout) == 0 else {
            return nil
        }
        return writeStatsSummary(
            totalMatches: stats.totalMatches,
            matchedLines: stats.matchedLines,
            filesWithMatches: 1,
            filesSearched: 1,
            bytesSearched: stats.bytesSearched,
            exitCode: 0
        )
    }

    public static func multiLiteralQuietStatsExitCode(
        paths: [String],
        literals rawLiterals: [[UInt8]]
    ) -> Int32? {
        guard !paths.isEmpty,
              !rawLiterals.isEmpty,
              rawLiterals.count <= 64,
              rawLiterals.allSatisfy({
                !$0.isEmpty && !$0.contains(UInt8(ascii: "\n"))
              }) else {
            return nil
        }
        if let literals = nonOverlappingDistinctLiterals(rawLiterals),
           !literals.isEmpty {
            return nonOverlappingMultiLiteralQuietStatsExitCode(paths: paths, literals: literals)
        }

        return overlappingMultiLiteralQuietStatsExitCode(paths: paths, literals: rawLiterals)
    }

    private static func overlappingMultiLiteralQuietStatsExitCode(
        paths: [String],
        literals rawLiterals: [[UInt8]]
    ) -> Int32? {
        let accumulator = QuietStatsSummaryAccumulator()
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            guard let summary = overlappingMultiLiteralFileStats(
                path: paths[index],
                literals: rawLiterals
            ) else {
                accumulator.recordFailure()
                return
            }
            accumulator.record(
                totalMatches: summary.totalMatches,
                matchedLines: summary.matchedLines,
                bytesSearched: summary.bytesSearched
            )
        }

        let summary = accumulator.snapshot()
        guard !summary.failed else {
            return nil
        }
        return writeStatsSummary(
            totalMatches: summary.totalMatches,
            matchedLines: summary.matchedLines,
            filesWithMatches: summary.filesWithMatches,
            filesSearched: paths.count,
            bytesSearched: summary.bytesSearched,
            exitCode: summary.totalMatches > 0 ? 0 : 1
        )
    }

    private static func overlappingMultiLiteralFileStats(
        path: String,
        literals rawLiterals: [[UInt8]]
    ) -> (totalMatches: Int, matchedLines: Int, bytesSearched: Int)? {
        guard let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data),
              let counts = countMultiLiteralOnlyMatchCounts(in: data, literals: rawLiterals) else {
            return nil
        }
        guard counts.totalMatches > 0 else {
            return (totalMatches: 0, matchedLines: 0, bytesSearched: data.count)
        }
        guard !hasTextEncodingBOM(data) else {
            return nil
        }
        return (
            totalMatches: counts.totalMatches,
            matchedLines: counts.matchedLines,
            bytesSearched: data.count
        )
    }

    private static func nonOverlappingMultiLiteralQuietStatsExitCode(
        paths: [String],
        literals: [[UInt8]]
    ) -> Int32? {
        let literalData = literals.map { Data($0) }
        let accumulator = QuietStatsSummaryAccumulator()

        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            guard let summary = nonOverlappingMultiLiteralFileStats(
                path: paths[index],
                literalData: literalData,
                literals: literals
            ) else {
                accumulator.recordFailure()
                return
            }
            accumulator.record(
                totalMatches: summary.totalMatches,
                matchedLines: summary.matchedLines,
                bytesSearched: summary.bytesSearched
            )
        }

        let summary = accumulator.snapshot()
        guard !summary.failed else {
            return nil
        }

        return writeStatsSummary(
            totalMatches: summary.totalMatches,
            matchedLines: summary.matchedLines,
            filesWithMatches: summary.filesWithMatches,
            filesSearched: paths.count,
            bytesSearched: summary.bytesSearched,
            exitCode: summary.totalMatches > 0 ? 0 : 1
        )
    }

    private static func nonOverlappingMultiLiteralFileStats(
        path: String,
        literalData: [Data],
        literals: [[UInt8]]
    ) -> (totalMatches: Int, matchedLines: Int, bytesSearched: Int)? {
        guard let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data) else {
            return nil
        }
        guard dataContainsAnyLiteralUsingFoundation(data, literals: literalData) else {
            return (totalMatches: 0, matchedLines: 0, bytesSearched: data.count)
        }
        return nonOverlappingMultiLiteralMatchedStats(
            path: path,
            data: data,
            literals: literals
        )
    }

    private static func nonOverlappingMultiLiteralMatchedStats(
        path: String,
        data: Data,
        literals: [[UInt8]]
    ) -> (totalMatches: Int, matchedLines: Int, bytesSearched: Int)? {
        guard literals.count > 1,
              data.count >= 1024 * 1024 else {
            guard let result = multiLiteralResult(
                    path: path,
                    literals: literals,
                    maxCount: nil,
                    emitLines: false
                  ),
                  result.status >= 0 else {
                return nil
            }
            return (
                totalMatches: countNonOverlappingMultiLiteralMatches(in: data, literals: literals),
                matchedLines: result.matched_line_count,
                bytesSearched: result.bytes_searched
            )
        }

        let accumulator = QuietStatsMatchedFileAccumulator()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        group.enter()
        queue.async {
            accumulator.recordResult(multiLiteralResult(
                path: path,
                literals: literals,
                maxCount: nil,
                emitLines: false
            ))
            group.leave()
        }

        group.enter()
        queue.async {
            accumulator.recordMatchCount(countNonOverlappingMultiLiteralMatches(
                in: data,
                literals: literals
            ))
            group.leave()
        }

        group.wait()
        let summary = accumulator.snapshot()
        guard !summary.failed,
              let result = summary.result,
              let matchCount = summary.matchCount else {
            return nil
        }
        return (
            totalMatches: matchCount,
            matchedLines: result.matched_line_count,
            bytesSearched: result.bytes_searched
        )
    }

    private static func dataContainsAnyLiteralUsingFoundation(
        _ data: Data,
        literals: [Data]
    ) -> Bool {
        for literal in literals where data.range(of: literal) != nil {
            return true
        }
        return false
    }

    public static func matchedPathOutputExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        wordRegexp: Bool,
        lineRegexp: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool,
        outputPath: [UInt8]?
    ) -> Int32? {
        guard !(lineRegexp && wordRegexp) else {
            return nil
        }
        if asciiCaseInsensitive {
            if wordRegexp {
                return asciiCaseInsensitiveWordPathOnlyExitCode(
                    path: path,
                    literal: literal,
                    printWhenMatched: true,
                    nullTerminated: nullTerminated,
                    crlfTerminated: crlfTerminated,
                    outputPath: outputPath
                )
            }
            if lineRegexp {
                return asciiCaseInsensitiveExactLinePathOnlyExitCode(
                    path: path,
                    literal: literal,
                    printWhenMatched: true,
                    nullTerminated: nullTerminated,
                    crlfTerminated: crlfTerminated,
                    outputPath: outputPath
                )
            }
            return asciiCaseInsensitivePathOnlyExitCode(
                path: path,
                literal: literal,
                printWhenMatched: true,
                nullTerminated: nullTerminated,
                crlfTerminated: crlfTerminated,
                outputPath: outputPath
            )
        }
        if wordRegexp {
            return wordPathOnlyExitCode(
                path: path,
                literal: literal,
                printWhenMatched: true,
                nullTerminated: nullTerminated,
                crlfTerminated: crlfTerminated,
                outputPath: outputPath
            )
        }
        if lineRegexp {
            return exactLinePathOnlyExitCode(
                path: path,
                literal: literal,
                printWhenMatched: true,
                nullTerminated: nullTerminated,
                crlfTerminated: crlfTerminated,
                outputPath: outputPath
            )
        }
        return pathOnlyExitCode(
            path: path,
            literal: literal,
            printWhenMatched: true,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated,
            outputPath: outputPath
        )
    }

    public static func literalNoMatchSummaryExitCode(
        path: String,
        literal: [UInt8],
        json: Bool,
        stats: Bool
    ) -> Int32? {
        guard json || stats,
              let bytesSearched = literalNoMatchByteCount(path: path, literal: literal) else {
            return nil
        }
        return writeNoMatchSummary(bytesSearched: bytesSearched, json: json)
    }

    public static func asciiCaseInsensitiveNoMatchSummaryExitCode(
        path: String,
        literal: [UInt8],
        json: Bool,
        stats: Bool
    ) -> Int32? {
        guard json || stats,
              let bytesSearched = asciiCaseInsensitiveNoMatchByteCount(path: path, literal: literal) else {
            return nil
        }
        return writeNoMatchSummary(bytesSearched: bytesSearched, json: json)
    }

    public static func wordNoMatchSummaryExitCode(
        path: String,
        literal: [UInt8],
        json: Bool,
        stats: Bool
    ) -> Int32? {
        guard json || stats,
              let bytesSearched = wordNoMatchByteCount(path: path, literal: literal) else {
            return nil
        }
        return writeNoMatchSummary(bytesSearched: bytesSearched, json: json)
    }

    public static func asciiCaseInsensitiveWordNoMatchSummaryExitCode(
        path: String,
        literal: [UInt8],
        json: Bool,
        stats: Bool
    ) -> Int32? {
        guard json || stats,
              let bytesSearched = asciiCaseInsensitiveWordNoMatchByteCount(path: path, literal: literal) else {
            return nil
        }
        return writeNoMatchSummary(bytesSearched: bytesSearched, json: json)
    }

    private struct MatchedSummaryStats {
        let totalMatches: Int
        let matchedLines: Int
        let bytesSearched: Int
    }

    private struct MatchedOutputStats {
        let totalMatches: Int
        let matchedLines: Int
        let bytesPrinted: Int
        let bytesSearched: Int
    }

    private static func matchedSummaryStats(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        wordRegexp: Bool
    ) -> MatchedSummaryStats? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")) else {
            return nil
        }
        if wordRegexp, !isSafeASCIIWordLiteral(literal) {
            return nil
        }
        if asciiCaseInsensitive,
           !literal.allSatisfy({ $0 < 0x80 }) {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !hasBinaryDetectionPrefix(data),
              !containsNULByte(data) else {
            return nil
        }
        if (asciiCaseInsensitive || wordRegexp),
           containsNonASCIIByte(data) {
            return nil
        }

        let matchedLineCount: Int?
        let totalMatchCount: Int?
        if wordRegexp {
            matchedLineCount = countASCIIWordMatchedLines(
                in: data,
                literals: [literal],
                maxCount: nil,
                asciiCaseInsensitive: asciiCaseInsensitive
            )
            totalMatchCount = countASCIIWordMatches(
                in: data,
                literal: literal,
                asciiCaseInsensitive: asciiCaseInsensitive
            )
        } else if asciiCaseInsensitive {
            guard let literals = distinctASCIICaseInsensitiveLiterals([literal]),
                  let foldedLiteral = literals.first else {
                return nil
            }
            matchedLineCount = countASCIICaseInsensitiveMatchedLines(
                data: data,
                foldedLiterals: [foldedLiteral],
                maxCount: nil
            )
            totalMatchCount = countASCIICaseInsensitiveMatches(
                in: data,
                foldedLiteral: foldedLiteral
            )
        } else {
            let counts = literalMatchedLineAndMatchCounts(in: data, literal: literal)
            matchedLineCount = counts.matchedLines
            totalMatchCount = counts.totalMatches
        }
        guard let matchedLineCount,
              matchedLineCount > 0,
              let totalMatchCount,
              totalMatchCount > 0 else {
            return nil
        }
        return MatchedSummaryStats(
            totalMatches: totalMatchCount,
            matchedLines: matchedLineCount,
            bytesSearched: data.count
        )
    }

    private static func writeNoMatchSummary(bytesSearched: Int, json: Bool, exitCode: Int32 = 1) -> Int32 {
        if json {
            writeNoMatchJSONSummary(bytesSearched: bytesSearched)
        } else {
            return writeStatsSummary(
                totalMatches: 0,
                matchedLines: 0,
                filesWithMatches: 0,
                filesSearched: 1,
                bytesSearched: bytesSearched,
                exitCode: exitCode
            )
        }
        return exitCode
    }

    @discardableResult
    private static func writeNoMatchJSONSummary(bytesSearched: Int) -> Bool {
        guard var output = rgSwiftStdoutBuffer(capacity: 384) else {
            return false
        }
        defer {
            output.deallocate()
        }
        guard output.writeBytes(jsonNoMatchSummaryPrefix),
              output.writeLineNumberPrefix(
                bytesSearched,
                fieldSeparator: jsonNoMatchSummarySuffix
              ),
              output.writeByte(UInt8(ascii: "\n")),
              output.flush() else {
            return false
        }
        return true
    }

    private static func writeStatsSummary(
        totalMatches: Int,
        matchedLines: Int,
        filesWithMatches: Int,
        filesSearched: Int,
        bytesPrinted: Int = 0,
        bytesSearched: Int,
        exitCode: Int32
    ) -> Int32 {
        guard var output = rgSwiftStdoutBuffer(capacity: 256) else {
            return exitCode
        }
        defer {
            output.deallocate()
        }
        guard output.writeByte(UInt8(ascii: "\n")),
              output.writeLineNumberPrefix(totalMatches, fieldSeparator: statsMatchesSuffix),
              output.writeLineNumberPrefix(matchedLines, fieldSeparator: statsMatchedLinesSuffix),
              output.writeLineNumberPrefix(
                filesWithMatches,
                fieldSeparator: statsFilesWithMatchesSuffix
              ),
              output.writeLineNumberPrefix(filesSearched, fieldSeparator: statsFilesSearchedSuffix),
              output.writeLineNumberPrefix(bytesPrinted, fieldSeparator: statsBytesPrintedSuffix),
              output.writeLineNumberPrefix(bytesSearched, fieldSeparator: statsBytesSearchedSuffix),
              output.writeBytes(statsElapsedSuffix),
              output.flush() else {
            return exitCode
        }
        return exitCode
    }

    public static func pathOnlyExitCode(
        path: String,
        literal: [UInt8],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        let matched = if printWhenMatched {
            containsLiteral(path: path, literal: literal)
        } else {
            containsLiteralUsingSIMD(path: path, literal: literal)
        }
        guard let matched else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func asciiFixedClassPathOnlyExitCode(
        path: String,
        pattern: String,
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let classes = asciiFixedClassSequenceClasses(pattern: pattern) else {
            return nil
        }
        let matched = containsASCIIFixedClassSequence(path: path, classes: classes)
        guard let matched else { return nil }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func asciiFixedClassNoMatchPathOutputExitCode(
        path: String,
        pattern: String,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil,
        stats: Bool
    ) -> Int32? {
        guard let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let bytesSearched = asciiFixedClassNoMatchByteCount(path: path, classes: classes) else {
            return nil
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        if stats {
            guard fflush(Darwin.stdout) == 0 else {
                return nil
            }
            return writeNoMatchSummary(bytesSearched: bytesSearched, json: false, exitCode: 0)
        }
        return 0
    }

    public static func asciiFixedClassMatchedPathStatsExitCode(
        path: String,
        pattern: String,
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let stats = asciiFixedClassMatchedSummaryStats(path: path, classes: classes) else {
            return nil
        }
        if printWhenMatched {
            guard writePathOnlyOutput(
                path: path,
                outputPath: outputPath,
                nullTerminated: nullTerminated,
                crlfTerminated: crlfTerminated
            ), fflush(Darwin.stdout) == 0 else {
                return nil
            }
        }
        return writeStatsSummary(
            totalMatches: stats.totalMatches,
            matchedLines: stats.matchedLines,
            filesWithMatches: 1,
            filesSearched: 1,
            bytesSearched: stats.bytesSearched,
            exitCode: printWhenMatched ? 0 : 1
        )
    }

    public static func asciiFixedClassMatchedCountStatsExitCode(
        path: String,
        pattern: String,
        countMatches: Bool,
        includeZero: Bool,
        maxCount: Int?,
        countPrefix: [UInt8],
        crlfTerminated: Bool
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let stats = asciiFixedClassMatchedSummaryStats(
                path: path,
                classes: classes,
                maxCount: maxCount
              ) else {
            return nil
        }
        let count = countMatches ? stats.totalMatches : stats.matchedLines
        guard count > 0 || includeZero else {
            return nil
        }
        guard writeCountOutput(
            count,
            countPrefix: countPrefix,
            crlfTerminated: crlfTerminated
        ), fflush(Darwin.stdout) == 0 else {
            return nil
        }
        let exitCode: Int32 = stats.matchedLines > 0 ? 0 : 1
        return writeStatsSummary(
            totalMatches: stats.totalMatches,
            matchedLines: stats.matchedLines,
            filesWithMatches: stats.matchedLines > 0 ? 1 : 0,
            filesSearched: 1,
            bytesSearched: stats.bytesSearched,
            exitCode: exitCode
        )
    }

    public static func asciiFixedClassMatchedCountOutputExitCode(
        path: String,
        pattern: String,
        countMatches: Bool,
        includeZero: Bool,
        maxCount: Int?,
        countPrefix: [UInt8],
        crlfTerminated: Bool
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let stats = asciiFixedClassMatchedSummaryStats(
                path: path,
                classes: classes,
                maxCount: maxCount
              ) else {
            return nil
        }
        let count = countMatches ? stats.totalMatches : stats.matchedLines
        guard count > 0 || includeZero else {
            return nil
        }
        guard writeCountOutput(
            count,
            countPrefix: countPrefix,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return stats.matchedLines > 0 ? 0 : 1
    }

    public static func asciiFixedClassMatchedLineOutputExitCode(
        path: String,
        pattern: String,
        lineNumber: Bool,
        maxCount: Int?,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let matchedLineCount = asciiFixedClassMatchedLineOutputCount(
                path: path,
                classes: classes,
                lineNumber: lineNumber,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
              ) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func asciiFixedClassMatchedLineStatsExitCode(
        path: String,
        pattern: String,
        lineNumber: Bool,
        maxCount: Int?,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let stats = asciiFixedClassMatchedLineOutput(
                path: path,
                classes: classes,
                lineNumber: lineNumber,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix,
                collectTotalMatches: true
              ) else {
            return nil
        }
        guard fflush(Darwin.stdout) == 0 else {
            return nil
        }
        let exitCode: Int32 = stats.matchedLines > 0 ? 0 : 1
        return writeStatsSummary(
            totalMatches: stats.totalMatches,
            matchedLines: stats.matchedLines,
            filesWithMatches: stats.matchedLines > 0 ? 1 : 0,
            filesSearched: 1,
            bytesPrinted: stats.bytesPrinted,
            bytesSearched: stats.bytesSearched,
            exitCode: exitCode
        )
    }

    public static func asciiFixedClassMaxColumnsLineOutputExitCode(
        path: String,
        pattern: String,
        lineNumber: Bool,
        maxCount: Int?,
        maxColumns: Int,
        maxColumnsPreview: Bool,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern) else {
            return nil
        }
        if maxColumnsPreview,
           !lineNumber,
           linePrefix.isEmpty,
           headingPrefix.isEmpty,
           let matchedLineCount = asciiFixedClassPlainMaxColumnsPreviewOutputCount(
            path: path,
            classes: classes,
            maxCount: maxCount ?? Int.max,
            maxColumns: maxColumns
           ) {
            return matchedLineCount > 0 ? 0 : 1
        }
        guard let stats = asciiFixedClassMaxColumnsLineOutput(
                path: path,
                classes: classes,
                lineNumber: lineNumber,
                maxCount: maxCount ?? Int.max,
                maxColumns: maxColumns,
                maxColumnsPreview: maxColumnsPreview,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix,
                collectTotalMatches: false
              ) else {
            return nil
        }
        return stats.matchedLines > 0 ? 0 : 1
    }

    public static func asciiFixedClassOmittedLongLineOutputExitCode(
        path: String,
        pattern: String,
        maxCount: Int?,
        maxColumns: Int
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let matchedLineCount = asciiFixedClassOmittedLongLineOutput(
                path: path,
                classes: classes,
                maxCount: maxCount ?? Int.max,
                maxColumns: maxColumns
              ) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func asciiFixedClassMaxColumnsLineStatsExitCode(
        path: String,
        pattern: String,
        lineNumber: Bool,
        maxCount: Int?,
        maxColumns: Int,
        maxColumnsPreview: Bool,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let stats = asciiFixedClassMaxColumnsLineOutput(
                path: path,
                classes: classes,
                lineNumber: lineNumber,
                maxCount: maxCount ?? Int.max,
                maxColumns: maxColumns,
                maxColumnsPreview: maxColumnsPreview,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix,
                collectTotalMatches: true
              ) else {
            return nil
        }
        let exitCode: Int32 = stats.matchedLines > 0 ? 0 : 1
        return writeStatsSummary(
            totalMatches: stats.totalMatches,
            matchedLines: stats.matchedLines,
            filesWithMatches: stats.matchedLines > 0 ? 1 : 0,
            filesSearched: 1,
            bytesPrinted: stats.bytesPrinted,
            bytesSearched: stats.bytesSearched,
            exitCode: exitCode
        )
    }

    public static func asciiFixedClassOnlyMatchingOutputExitCode(
        path: String,
        pattern: String,
        lineNumber: Bool,
        byteOffset: Bool,
        column: Bool,
        maxCount: Int?,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let matchCount = asciiFixedClassOnlyMatchingOutput(
                path: path,
                classes: classes,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                column: column,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
              ) else {
            return nil
        }
        return matchCount.totalMatches > 0 ? 0 : 1
    }

    public static func asciiFixedClassOnlyMatchingStatsExitCode(
        path: String,
        pattern: String,
        lineNumber: Bool,
        byteOffset: Bool,
        column: Bool,
        maxCount: Int?,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let stats = asciiFixedClassOnlyMatchingOutput(
                path: path,
                classes: classes,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                column: column,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
              ) else {
            return nil
        }
        guard fflush(Darwin.stdout) == 0 else {
            return nil
        }
        let exitCode: Int32 = stats.totalMatches > 0 ? 0 : 1
        return writeStatsSummary(
            totalMatches: stats.totalMatches,
            matchedLines: stats.matchedLines,
            filesWithMatches: stats.matchedLines > 0 ? 1 : 0,
            filesSearched: 1,
            bytesPrinted: stats.bytesPrinted,
            bytesSearched: stats.bytesSearched,
            exitCode: exitCode
        )
    }

    public static func asciiFixedClassJSONOutputExitCode(
        path: String,
        displayPath: [UInt8],
        pattern: String,
        noLineNumber: Bool,
        maxCount: Int?
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern) else {
            return nil
        }
        return asciiFixedClassJSONOutput(
            path: path,
            displayPath: displayPath,
            classes: classes,
            noLineNumber: noLineNumber,
            maxCount: maxCount ?? Int.max
        )
    }

    public static func asciiFixedClassVimgrepLineOutputExitCode(
        path: String,
        pattern: String,
        lineNumber: Bool,
        byteOffset: Bool,
        column: Bool,
        maxCount: Int?,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8]
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let stats = asciiFixedClassVimgrepLineOutput(
                path: path,
                classes: classes,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                column: column,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix
              ) else {
            return nil
        }
        return stats.totalMatches > 0 ? 0 : 1
    }

    public static func asciiFixedClassVimgrepLineStatsExitCode(
        path: String,
        pattern: String,
        lineNumber: Bool,
        byteOffset: Bool,
        column: Bool,
        maxCount: Int?,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8]
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let stats = asciiFixedClassVimgrepLineOutput(
                path: path,
                classes: classes,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                column: column,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix
              ) else {
            return nil
        }
        guard fflush(Darwin.stdout) == 0 else {
            return nil
        }
        let exitCode: Int32 = stats.totalMatches > 0 ? 0 : 1
        return writeStatsSummary(
            totalMatches: stats.totalMatches,
            matchedLines: stats.matchedLines,
            filesWithMatches: stats.matchedLines > 0 ? 1 : 0,
            filesSearched: 1,
            bytesPrinted: stats.bytesPrinted,
            bytesSearched: stats.bytesSearched,
            exitCode: exitCode
        )
    }

    public static func asciiFixedClassMatchedQuietStatsExitCode(
        path: String,
        pattern: String
    ) -> Int32? {
        guard let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let stats = asciiFixedClassMatchedSummaryStats(path: path, classes: classes) else {
            return nil
        }
        return writeStatsSummary(
            totalMatches: stats.totalMatches,
            matchedLines: stats.matchedLines,
            filesWithMatches: 1,
            filesSearched: 1,
            bytesSearched: stats.bytesSearched,
            exitCode: 0
        )
    }

    public static func asciiFixedClassNoMatchExitCode(
        path: String,
        pattern: String
    ) -> Int32? {
        guard let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let matched = containsASCIIFixedClassSequence(path: path, classes: classes),
              !matched else {
            return nil
        }
        return 1
    }

    public static func greekScriptNoMatchExitCode(
        path: String,
        pattern: String,
        caseInsensitive: Bool
    ) -> Int32? {
        guard isDefaultGreekScriptPattern(pattern: pattern),
              let data = mappedPreflightData(path: path),
              !startsWithUTFBOM(data),
              !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        if !containsNonASCIIByte(data) {
            return 1
        }
        guard !GreekScriptByteProof.containsMatch(in: data, caseInsensitive: caseInsensitive) else {
            return nil
        }
        return 1
    }

    public static func asciiFixedClassNoMatchCountOutputExitCode(
        path: String,
        pattern: String,
        includeZero: Bool,
        countPrefix: [UInt8],
        crlfTerminated: Bool,
        stats: Bool = false
    ) -> Int32? {
        guard let classes = asciiFixedClassSequenceClasses(pattern: pattern) else {
            return nil
        }
        let bytesSearched: Int?
        if stats {
            guard let provenBytesSearched = asciiFixedClassNoMatchByteCount(
                path: path,
                classes: classes
            ) else {
                return nil
            }
            bytesSearched = provenBytesSearched
        } else {
            guard let matched = containsASCIIFixedClassSequence(path: path, classes: classes),
                  !matched else {
                return nil
            }
            bytesSearched = nil
        }
        if includeZero {
            guard writeCountOutput(
                0,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        if let bytesSearched {
            guard fflush(Darwin.stdout) == 0 else {
                return nil
            }
            return writeNoMatchSummary(bytesSearched: bytesSearched, json: false)
        }
        return 1
    }

    public static func asciiFixedClassNoMatchSummaryExitCode(
        path: String,
        pattern: String,
        json: Bool,
        stats: Bool
    ) -> Int32? {
        guard json || stats,
              let classes = asciiFixedClassSequenceClasses(pattern: pattern),
              let bytesSearched = asciiFixedClassNoMatchByteCount(path: path, classes: classes) else {
            return nil
        }
        return writeNoMatchSummary(bytesSearched: bytesSearched, json: json)
    }

    private static func asciiFixedClassSequenceClasses(
        pattern: String
    ) -> [ASCIIFixedClassSequenceFastPath.ByteClass]? {
        var patternBytes = Array(pattern.utf8)
        let noUnicodePrefix = Array("(?-u)".utf8)
        if patternBytes.starts(with: noUnicodePrefix) {
            patternBytes.removeFirst(noUnicodePrefix.count)
        }
        return PatternMatcher.asciiFixedClassSequence(in: patternBytes)?.classes
    }

    private static func isDefaultGreekScriptPattern(pattern: String) -> Bool {
        switch pattern {
        case #"\p{Greek}"#, #"\p{Greek}+"#:
            return true
        default:
            return false
        }
    }

    public static func fixedLookbehindQuietExitCode(
        path: String,
        prefix: [UInt8],
        literal: [UInt8],
        prefixShouldMatch: Bool
    ) -> Int32? {
        guard let matched = containsFixedLookbehindLiteral(
            path: path,
            prefix: prefix,
            literal: literal,
            prefixShouldMatch: prefixShouldMatch
        ) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func fixedLookbehindPathOnlyExitCode(
        path: String,
        prefix: [UInt8],
        literal: [UInt8],
        prefixShouldMatch: Bool,
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let matched = containsFixedLookbehindLiteral(
            path: path,
            prefix: prefix,
            literal: literal,
            prefixShouldMatch: prefixShouldMatch
        ) else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func fixedLookbehindLineExitCode(
        path: String,
        prefix: [UInt8],
        literal: [UInt8],
        prefixShouldMatch: Bool,
        maxCount: Int?,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard fixedLookaroundInputsAreSafe(literal, prefix),
              maxCount != 0,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }
        guard let matchedLineCount = data.withUnsafeBytes({ rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return prefix.withUnsafeBufferPointer { prefixBytes in
                literal.withUnsafeBufferPointer { literalBytes in
                    guard let prefixBase = prefixBytes.baseAddress,
                          let literalBase = literalBytes.baseAddress else {
                        return nil
                    }
                    return rgSwiftDarwinWriteFixedLookbehindLines(
                        rawBase.assumingMemoryBound(to: UInt8.self),
                        haystackLength: data.count,
                        prefix: UnsafeBufferPointer(start: prefixBase, count: prefix.count),
                        literal: UnsafeBufferPointer(start: literalBase, count: literal.count),
                        prefixShouldMatch: prefixShouldMatch,
                        maxCount: maxCount ?? Int.max,
                        lineNumber: lineNumber,
                        lineNumberFieldSeparator: lineNumberFieldSeparator,
                        linePrefix: linePrefix,
                        headingPrefix: headingPrefix
                    )
                }
            }
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func fixedLookbehindCountLineExitCode(
        path: String,
        prefix: [UInt8],
        literal: [UInt8],
        prefixShouldMatch: Bool,
        includeZero: Bool,
        maxCount: Int?,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard fixedLookaroundInputsAreSafe(literal, prefix),
              maxCount != 0,
              let matchedLineCount = countFixedLookbehindMatchedLines(
                path: path,
                prefix: prefix,
                literal: literal,
                prefixShouldMatch: prefixShouldMatch,
                maxCount: maxCount
              ) else {
            return nil
        }
        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func fixedLookbehindCountMatchesExitCode(
        path: String,
        prefix: [UInt8],
        literal: [UInt8],
        prefixShouldMatch: Bool,
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard fixedLookaroundInputsAreSafe(literal, prefix),
              maxCount.map({ $0 > 0 }) ?? true,
              let matchCount = countFixedLookbehindMatches(
                path: path,
                prefix: prefix,
                literal: literal,
                prefixShouldMatch: prefixShouldMatch,
                maxCount: maxCount
              ) else {
            return nil
        }
        if matchCount > 0 || includeZero {
            guard writeCountOutput(
                matchCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func fixedLookaheadQuietExitCode(
        path: String,
        literal: [UInt8],
        suffix: [UInt8],
        suffixShouldMatch: Bool
    ) -> Int32? {
        guard let matched = containsFixedLookaheadLiteral(
            path: path,
            literal: literal,
            suffix: suffix,
            suffixShouldMatch: suffixShouldMatch
        ) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func fixedLookaheadPathOnlyExitCode(
        path: String,
        literal: [UInt8],
        suffix: [UInt8],
        suffixShouldMatch: Bool,
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let matched = containsFixedLookaheadLiteral(
            path: path,
            literal: literal,
            suffix: suffix,
            suffixShouldMatch: suffixShouldMatch
        ) else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func fixedLookaheadLineExitCode(
        path: String,
        literal: [UInt8],
        suffix: [UInt8],
        suffixShouldMatch: Bool,
        maxCount: Int?,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard fixedLookaroundInputsAreSafe(literal, suffix),
              maxCount != 0,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }
        guard let matchedLineCount = data.withUnsafeBytes({ rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return literal.withUnsafeBufferPointer { literalBytes in
                suffix.withUnsafeBufferPointer { suffixBytes in
                    guard let literalBase = literalBytes.baseAddress,
                          let suffixBase = suffixBytes.baseAddress else {
                        return nil
                    }
                    return rgSwiftDarwinWriteFixedLookaheadLines(
                        rawBase.assumingMemoryBound(to: UInt8.self),
                        haystackLength: data.count,
                        literal: UnsafeBufferPointer(start: literalBase, count: literal.count),
                        suffix: UnsafeBufferPointer(start: suffixBase, count: suffix.count),
                        suffixShouldMatch: suffixShouldMatch,
                        maxCount: maxCount ?? Int.max,
                        lineNumber: lineNumber,
                        lineNumberFieldSeparator: lineNumberFieldSeparator,
                        linePrefix: linePrefix,
                        headingPrefix: headingPrefix
                    )
                }
            }
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func fixedLookaheadCountLineExitCode(
        path: String,
        literal: [UInt8],
        suffix: [UInt8],
        suffixShouldMatch: Bool,
        includeZero: Bool,
        maxCount: Int?,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard fixedLookaroundInputsAreSafe(literal, suffix),
              maxCount != 0,
              let matchedLineCount = countFixedLookaheadMatchedLines(
                path: path,
                literal: literal,
                suffix: suffix,
                suffixShouldMatch: suffixShouldMatch,
                maxCount: maxCount
              ) else {
            return nil
        }
        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func fixedLookaheadCountMatchesExitCode(
        path: String,
        literal: [UInt8],
        suffix: [UInt8],
        suffixShouldMatch: Bool,
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard fixedLookaroundInputsAreSafe(literal, suffix),
              maxCount.map({ $0 > 0 }) ?? true,
              let matchCount = countFixedLookaheadMatches(
                path: path,
                literal: literal,
                suffix: suffix,
                suffixShouldMatch: suffixShouldMatch,
                maxCount: maxCount
              ) else {
            return nil
        }
        if matchCount > 0 || includeZero {
            guard writeCountOutput(
                matchCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveQuietExitCode(
        path: String,
        literal: [UInt8]
    ) -> Int32? {
        guard let matched = containsASCIICaseInsensitiveLiteral(path: path, literal: literal) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func asciiCaseInsensitivePathOnlyExitCode(
        path: String,
        literal: [UInt8],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let matched = containsASCIICaseInsensitiveLiteral(path: path, literal: literal) else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func exactLineQuietExitCode(
        path: String,
        literal: [UInt8]
    ) -> Int32? {
        guard let matched = containsExactLine(path: path, literal: literal) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func exactLinePathOnlyExitCode(
        path: String,
        literal: [UInt8],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let matched = containsExactLine(path: path, literal: literal) else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func multiLiteralExactLineQuietExitCode(
        path: String,
        literals: [[UInt8]]
    ) -> Int32? {
        guard let matched = containsAnyExactLine(path: path, literals: literals) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func multiLiteralExactLinePathOnlyExitCode(
        path: String,
        literals: [[UInt8]],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let matched = containsAnyExactLine(path: path, literals: literals) else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func asciiCaseInsensitiveExactLineQuietExitCode(
        path: String,
        literal: [UInt8]
    ) -> Int32? {
        asciiCaseInsensitiveExactLineQuietExitCode(path: path, literals: [literal])
    }

    public static func asciiCaseInsensitiveExactLineQuietExitCode(
        path: String,
        literals: [[UInt8]]
    ) -> Int32? {
        guard let matched = asciiCaseInsensitiveExactLineMatched(path: path, literals: literals) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func asciiCaseInsensitiveExactLinePathOnlyExitCode(
        path: String,
        literal: [UInt8],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        asciiCaseInsensitiveExactLinePathOnlyExitCode(
            path: path,
            literals: [literal],
            printWhenMatched: printWhenMatched,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated,
            outputPath: outputPath
        )
    }

    public static func asciiCaseInsensitiveExactLinePathOnlyExitCode(
        path: String,
        literals: [[UInt8]],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let matched = asciiCaseInsensitiveExactLineMatched(path: path, literals: literals) else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func asciiCaseInsensitiveLimitedCountLineExitCode(
        path: String,
        literal: [UInt8],
        includeZero: Bool,
        maxCount: Int,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard maxCount == 1,
              let matched = containsASCIICaseInsensitiveLiteral(path: path, literal: literal) else {
            return nil
        }
        if matched {
            guard writeCountOutput(1, countPrefix: countPrefix, crlfTerminated: crlfTerminated) else {
                return nil
            }
        } else if includeZero {
            guard writeCountOutput(0, countPrefix: countPrefix, crlfTerminated: crlfTerminated) else {
                return nil
            }
        }
        return matched ? 0 : 1
    }

    public static func asciiCaseInsensitiveExactLineCountExitCode(
        path: String,
        literal: [UInt8],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        asciiCaseInsensitiveExactLineCountExitCode(
            path: path,
            literals: [literal],
            includeZero: includeZero,
            maxCount: maxCount,
            countPrefix: countPrefix,
            crlfTerminated: crlfTerminated
        )
    }

    public static func asciiCaseInsensitiveExactLineCountExitCode(
        path: String,
        literals: [[UInt8]],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctASCIICaseInsensitiveExactLineLiterals(literals),
              !literals.isEmpty else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }
        if literals.count > 1,
           !dataContainsAnyASCIICaseInsensitiveLiteral(data, foldedLiterals: literals) {
            if includeZero {
                guard writeCountOutput(
                    0,
                    countPrefix: countPrefix,
                    crlfTerminated: crlfTerminated
                ) else {
                    return nil
                }
            }
            return 1
        }

        let matchedLineCount = asciiCaseInsensitiveExactLineCount(
            data: data,
            foldedLiterals: literals,
            maxCount: maxCount
        )

        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func wordQuietExitCode(
        path: String,
        literal: [UInt8]
    ) -> Int32? {
        guard let matched = containsWordLiteral(path: path, literal: literal) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func wordPathOnlyExitCode(
        path: String,
        literal: [UInt8],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let matched = containsWordLiteral(path: path, literal: literal) else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func wordCountLineExitCode(
        path: String,
        literal: [UInt8],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              maxCount.map({ $0 > 0 }) ?? true,
              let first = literal.first,
              let last = literal.last,
              rgSwiftIsASCIIRegexWordByte(first),
              rgSwiftIsASCIIRegexWordByte(last) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path),
              let matchedLineCount = countASCIIWordMatchedLines(
                in: data,
                literal: literal,
                maxCount: maxCount
              ) else {
            return nil
        }

        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func multiLiteralWordCountLineExitCode(
        path: String,
        literals: [[UInt8]],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctASCIIWordLiterals(literals),
              !literals.isEmpty else {
            return nil
        }
        guard let data = mappedPreflightData(path: path),
              let matchedLineCount = countASCIIWordMatchedLines(
                in: data,
                literals: literals,
                maxCount: maxCount
              ) else {
            return nil
        }

        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func multiLiteralWordQuietExitCode(
        path: String,
        literals: [[UInt8]]
    ) -> Int32? {
        guard let matched = containsAnyWordLiteral(path: path, literals: literals) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func multiLiteralWordPathOnlyExitCode(
        path: String,
        literals: [[UInt8]],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let matched = containsAnyWordLiteral(path: path, literals: literals) else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func asciiCaseInsensitiveMultiLiteralWordCountLineExitCode(
        path: String,
        literals: [[UInt8]],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctASCIICaseInsensitiveWordLiterals(literals),
              !literals.isEmpty,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data),
              let matchedLineCount = countASCIIWordMatchedLines(
                in: data,
                literals: literals,
                maxCount: maxCount,
                asciiCaseInsensitive: true
              ) else {
            return nil
        }

        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveMultiLiteralWordQuietExitCode(
        path: String,
        literals: [[UInt8]]
    ) -> Int32? {
        guard let matched = containsAnyASCIICaseInsensitiveWordLiteral(path: path, literals: literals) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func asciiCaseInsensitiveMultiLiteralWordPathOnlyExitCode(
        path: String,
        literals: [[UInt8]],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let matched = containsAnyASCIICaseInsensitiveWordLiteral(path: path, literals: literals) else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func multiLiteralWordLineExitCode(
        path: String,
        literals: [[UInt8]],
        maxCount: Int? = nil,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctASCIIWordLiterals(literals),
              !literals.isEmpty,
              let data = mappedPreflightData(path: path),
              !data.isEmpty,
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data) else {
            return nil
        }
        if let maxCount,
           !lineNumber,
           linePrefix.isEmpty,
           headingPrefix.isEmpty,
           let matchedLineCount = writeBoundedASCIIWordMatchedLines(
            in: data,
            literals: literals,
            maxCount: maxCount
           ) {
            return matchedLineCount > 0 ? 0 : 1
        }
        guard !containsNonASCIIByte(data),
              let matchedLineCount = writeASCIIWordMatchedLines(
                in: data,
                literals: literals,
                maxCount: maxCount,
                lineNumber: lineNumber,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
              ) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveMultiLiteralWordLineExitCode(
        path: String,
        literals: [[UInt8]],
        maxCount: Int? = nil,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctASCIICaseInsensitiveWordLiterals(literals),
              !literals.isEmpty,
              let data = mappedPreflightData(path: path),
              !data.isEmpty,
              !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data),
              !containsNULByte(data),
              let matchedLineCount = writeASCIIWordMatchedLines(
                in: data,
                literals: literals,
                maxCount: maxCount,
                asciiCaseInsensitive: true,
                lineNumber: lineNumber,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
              ) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func multiLiteralQuietExitCode(
        path: String,
        literals: [[UInt8]]
    ) -> Int32? {
        guard let matched = containsAnyLiteral(path: path, literals: literals) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func multiLiteralPathOnlyExitCode(
        path: String,
        literals: [[UInt8]],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        let matched = if printWhenMatched {
            containsAnyLiteral(path: path, literals: literals)
        } else {
            containsAnyLiteralUsingSIMD(path: path, literals: literals)
        }
        guard let matched else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func asciiCaseInsensitiveMultiLiteralQuietExitCode(
        path: String,
        literals: [[UInt8]]
    ) -> Int32? {
        guard let matched = containsAnyASCIICaseInsensitiveLiteral(path: path, literals: literals) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func asciiCaseInsensitiveMultiLiteralPathOnlyExitCode(
        path: String,
        literals: [[UInt8]],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard let matched = containsAnyASCIICaseInsensitiveLiteral(path: path, literals: literals) else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func asciiCaseInsensitiveMultiLiteralCountLineExitCode(
        path: String,
        literals: [[UInt8]],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctASCIICaseInsensitiveLiterals(literals),
              !literals.isEmpty else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }

        let matchedLineCount = countASCIICaseInsensitiveMatchedLines(
            data: data,
            foldedLiterals: literals,
            maxCount: maxCount
        )

        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveCountMatchesExitCode(
        path: String,
        literal: [UInt8],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctASCIICaseInsensitiveLiterals([literal]),
              let foldedLiteral = literals.first else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }

        let matchCount = if let maxCount {
            countASCIICaseInsensitiveMatchesWithinFirstMatchingLines(
                data: data,
                foldedLiteral: foldedLiteral,
                maxCount: maxCount
            )
        } else {
            countASCIICaseInsensitiveMatches(in: data, foldedLiteral: foldedLiteral)
        }

        if matchCount > 0 || includeZero {
            guard writeCountOutput(
                matchCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveMultiLiteralOnlyMatchingExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool,
        byteOffset: Bool = false,
        column: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard let literals = distinctASCIICaseInsensitiveLiterals(literals),
              !literals.isEmpty,
              maxCount.map({ $0 > 0 }) ?? true,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        guard let matchCount = data.withUnsafeBytes({ rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return rgSwiftDarwinWriteASCIICaseInsensitiveMultiLiteralOnlyMatches(
                rawBase.assumingMemoryBound(to: UInt8.self),
                haystackLength: data.count,
                foldedLiterals: literals,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                column: column,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }) else {
            return nil
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveMultiLiteralWordOnlyMatchingExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool,
        byteOffset: Bool = false,
        column: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard let literals = distinctASCIICaseInsensitiveWordLiterals(literals),
              !literals.isEmpty,
              maxCount.map({ $0 > 0 }) ?? true,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        guard let matchCount = data.withUnsafeBytes({ rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return rgSwiftDarwinWriteMultiLiteralWordOnlyMatches(
                rawBase.assumingMemoryBound(to: UInt8.self),
                haystackLength: data.count,
                literals: literals,
                asciiCaseInsensitive: true,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                column: column,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }) else {
            return nil
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func multiLiteralOnlyMatchingExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool,
        byteOffset: Bool = false,
        column: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        multiLiteralOnlyMatchingExitCode(
            path: path,
            literals: literals,
            lineNumber: lineNumber,
            byteOffset: byteOffset,
            column: column,
            maxCount: maxCount,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix,
            requireASCIIHaystack: false
        )
    }

    public static func asciiMultiLiteralOnlyMatchingExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool,
        byteOffset: Bool = false,
        column: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        multiLiteralOnlyMatchingExitCode(
            path: path,
            literals: literals,
            lineNumber: lineNumber,
            byteOffset: byteOffset,
            column: column,
            maxCount: maxCount,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix,
            requireASCIIHaystack: true
        )
    }

    private static func multiLiteralOnlyMatchingExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool,
        byteOffset: Bool,
        column: Bool,
        maxCount: Int?,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8],
        requireASCIIHaystack: Bool
    ) -> Int32? {
        guard let literals = distinctExactLineLiterals(literals),
              !literals.isEmpty,
              maxCount.map({ $0 > 0 }) ?? true,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        if requireASCIIHaystack,
           containsNonASCIIByte(data) {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        guard let matchCount = data.withUnsafeBytes({ rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return rgSwiftDarwinWriteMultiLiteralOnlyMatches(
                rawBase.assumingMemoryBound(to: UInt8.self),
                haystackLength: data.count,
                literals: literals,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                column: column,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }) else {
            return nil
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func multiLiteralWordOnlyMatchingExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool,
        byteOffset: Bool = false,
        column: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard let literals = distinctASCIIWordLiterals(literals),
              !literals.isEmpty,
              literals.allSatisfy({ literal in literal.allSatisfy { byte in byte < 0x80 } }),
              maxCount.map({ $0 > 0 }) ?? true,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        guard let matchCount = data.withUnsafeBytes({ rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return rgSwiftDarwinWriteMultiLiteralWordOnlyMatches(
                rawBase.assumingMemoryBound(to: UInt8.self),
                haystackLength: data.count,
                literals: literals,
                asciiCaseInsensitive: false,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                column: column,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }) else {
            return nil
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveMultiLiteralWordVimgrepLineExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool = true,
        column: Bool = true,
        byteOffset: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = []
    ) -> Int32? {
        guard let literals = distinctASCIICaseInsensitiveWordLiterals(literals),
              !literals.isEmpty,
              maxCount.map({ $0 > 0 }) ?? true,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        guard let matchCount = data.withUnsafeBytes({ rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return rgSwiftDarwinWriteMultiLiteralVimgrepLines(
                rawBase.assumingMemoryBound(to: UInt8.self),
                haystackLength: data.count,
                literals: literals,
                asciiCaseInsensitive: true,
                wordBoundary: true,
                lineNumber: lineNumber,
                column: column,
                byteOffset: byteOffset,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix
            )
        }) else {
            return nil
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func multiLiteralWordVimgrepLineExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool = true,
        column: Bool = true,
        byteOffset: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = []
    ) -> Int32? {
        guard let literals = distinctASCIIWordLiterals(literals),
              !literals.isEmpty,
              literals.allSatisfy({ literal in literal.allSatisfy { byte in byte < 0x80 } }),
              maxCount.map({ $0 > 0 }) ?? true,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        guard let matchCount = data.withUnsafeBytes({ rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return rgSwiftDarwinWriteMultiLiteralVimgrepLines(
                rawBase.assumingMemoryBound(to: UInt8.self),
                haystackLength: data.count,
                literals: literals,
                asciiCaseInsensitive: false,
                wordBoundary: true,
                lineNumber: lineNumber,
                column: column,
                byteOffset: byteOffset,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix
            )
        }) else {
            return nil
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveMultiLiteralVimgrepLineExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool = true,
        column: Bool = true,
        byteOffset: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = []
    ) -> Int32? {
        guard let literals = distinctASCIICaseInsensitiveLiterals(literals),
              !literals.isEmpty,
              maxCount.map({ $0 > 0 }) ?? true,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        guard let matchCount = data.withUnsafeBytes({ rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return rgSwiftDarwinWriteMultiLiteralVimgrepLines(
                rawBase.assumingMemoryBound(to: UInt8.self),
                haystackLength: data.count,
                literals: literals,
                asciiCaseInsensitive: true,
                lineNumber: lineNumber,
                column: column,
                byteOffset: byteOffset,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix
            )
        }) else {
            return nil
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func multiLiteralVimgrepLineExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool = true,
        column: Bool = true,
        byteOffset: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = []
    ) -> Int32? {
        guard let literals = distinctExactLineLiterals(literals),
              !literals.isEmpty,
              maxCount.map({ $0 > 0 }) ?? true,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        guard let matchCount = data.withUnsafeBytes({ rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return rgSwiftDarwinWriteMultiLiteralVimgrepLines(
                rawBase.assumingMemoryBound(to: UInt8.self),
                haystackLength: data.count,
                literals: literals,
                asciiCaseInsensitive: false,
                lineNumber: lineNumber,
                column: column,
                byteOffset: byteOffset,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix
            )
        }) else {
            return nil
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func multiLiteralExactLineVimgrepLineExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool = true,
        column: Bool = true,
        byteOffset: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = []
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctExactLineLiterals(literals),
              !literals.isEmpty,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        if literals.count == 1 {
            return asciiCaseInsensitiveExactLineFieldOutput(
                data: data,
                foldedLiteral: literals[0],
                maxCount: maxCount,
                lineNumber: lineNumber,
                column: column,
                byteOffset: byteOffset,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: []
            )
        }
        guard dataContainsAnyLiteral(data, literals: literals) else {
            return 1
        }

        let limit = maxCount ?? Int.max
        let newline = UInt8(ascii: "\n")
        var matchedLineCount = 0
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let wroteOutput = data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return true
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            var lineStart = 0
            var lineNumberValue = 1

            while lineStart < data.count, matchedLineCount < limit {
                let remaining = data.count - lineStart
                let lineEnd: Int
                let nextLineStart: Int
                if let newlinePointer = memchr(
                    base.advanced(by: lineStart),
                    Int32(newline),
                    remaining
                ) {
                    lineEnd = base.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
                    nextLineStart = lineEnd + 1
                } else {
                    lineEnd = data.count
                    nextLineStart = data.count
                }

                if exactLineRangeMatches(
                    base: base,
                    lineStart: lineStart,
                    lineEnd: lineEnd,
                    literals: literals
                ) {
                    guard output.writeBytes(linePrefix) else {
                        return false
                    }
                    if lineNumber {
                        guard output.writeLineNumberPrefix(
                            lineNumberValue,
                            fieldSeparator: lineNumberFieldSeparator
                        ) else {
                            return false
                        }
                    }
                    if column {
                        guard output.writeLineNumberPrefix(
                            1,
                            fieldSeparator: lineNumberFieldSeparator
                        ) else {
                            return false
                        }
                    }
                    if byteOffset {
                        guard output.writeLineNumberPrefix(
                            lineStart,
                            fieldSeparator: lineNumberFieldSeparator
                        ) else {
                            return false
                        }
                    }
                    guard output.write(base.advanced(by: lineStart), count: lineEnd - lineStart),
                          output.writeByte(newline) else {
                        return false
                    }
                    matchedLineCount += 1
                }

                lineStart = nextLineStart
                if lineStart < data.count {
                    lineNumberValue += 1
                }
            }
            return true
        }
        guard wroteOutput,
              output.flush() else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveExactLineVimgrepLineExitCode(
        path: String,
        literals: [[UInt8]],
        lineNumber: Bool = true,
        column: Bool = true,
        byteOffset: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = []
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctASCIICaseInsensitiveExactLineLiterals(literals),
              !literals.isEmpty,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        if literals.count == 1 {
            return asciiCaseInsensitiveExactLineFieldOutput(
                data: data,
                foldedLiteral: literals[0],
                maxCount: maxCount,
                lineNumber: lineNumber,
                column: column,
                byteOffset: byteOffset,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: []
            )
        }
        guard dataContainsAnyASCIICaseInsensitiveLiteral(data, foldedLiterals: literals) else {
            return 1
        }

        let limit = maxCount ?? Int.max
        let newline = UInt8(ascii: "\n")
        var matchedLineCount = 0
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let wroteOutput = data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return true
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            var lineStart = 0
            var lineNumberValue = 1

            while lineStart < data.count, matchedLineCount < limit {
                let remaining = data.count - lineStart
                let lineEnd: Int
                let nextLineStart: Int
                if let newlinePointer = memchr(
                    base.advanced(by: lineStart),
                    Int32(newline),
                    remaining
                ) {
                    lineEnd = base.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
                    nextLineStart = lineEnd + 1
                } else {
                    lineEnd = data.count
                    nextLineStart = data.count
                }

                if asciiCaseInsensitiveExactLineRangeMatches(
                    base: base,
                    lineStart: lineStart,
                    lineEnd: lineEnd,
                    foldedLiterals: literals
                ) {
                    guard output.writeBytes(linePrefix) else {
                        return false
                    }
                    if lineNumber {
                        guard output.writeLineNumberPrefix(
                            lineNumberValue,
                            fieldSeparator: lineNumberFieldSeparator
                        ) else {
                            return false
                        }
                    }
                    if column {
                        guard output.writeLineNumberPrefix(
                            1,
                            fieldSeparator: lineNumberFieldSeparator
                        ) else {
                            return false
                        }
                    }
                    if byteOffset {
                        guard output.writeLineNumberPrefix(
                            lineStart,
                            fieldSeparator: lineNumberFieldSeparator
                        ) else {
                            return false
                        }
                    }
                    guard output.write(base.advanced(by: lineStart), count: lineEnd - lineStart),
                          output.writeByte(newline) else {
                        return false
                    }
                    matchedLineCount += 1
                }

                lineStart = nextLineStart
                if lineStart < data.count {
                    lineNumberValue += 1
                }
            }
            return true
        }
        guard wroteOutput,
              output.flush() else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func limitedLineExitCode(
        path: String,
        literal: [UInt8],
        maxCount: Int,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literal.isEmpty,
              maxCount > 0,
              !literal.contains(UInt8(ascii: "\n")) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        let needle = Data(literal)
        let newline = UInt8(ascii: "\n")
        var searchStart = data.startIndex
        var lineScanStart = data.startIndex
        var nextLineNumber = 1
        var matchedLineCount = 0
        var checkedBinaryPrefix = false
        var emittedHeading = false
        var output = Data()
        output.reserveCapacity(64 * 1024)

        while matchedLineCount < maxCount,
              searchStart < data.endIndex,
              let matchRange = data.range(of: needle, in: searchStart..<data.endIndex) {
            guard !matchRange.isEmpty else {
                return nil
            }
            if !checkedBinaryPrefix {
                checkedBinaryPrefix = true
                guard !hasBinaryDetectionPrefix(data) else {
                    return nil
                }
            }

            let lineStart = data[..<matchRange.lowerBound]
                .lastIndex(of: newline)
                .map { data.index(after: $0) } ?? data.startIndex
            let lineEnd = data[matchRange.upperBound...]
                .firstIndex(of: newline) ?? data.endIndex

            if lineNumber {
                appendHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading, to: &output)
                appendLinePrefix(linePrefix, to: &output)
                let skippedNewlines = data[lineScanStart..<lineStart]
                    .reduce(0) { count, byte in count + (byte == newline ? 1 : 0) }
                let matchedLineNumber = nextLineNumber + skippedNewlines
                appendLineNumberPrefix(
                    matchedLineNumber,
                    to: &output,
                    fieldSeparator: lineNumberFieldSeparator
                )
                nextLineNumber = matchedLineNumber + 1
            } else {
                appendHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading, to: &output)
                appendLinePrefix(linePrefix, to: &output)
            }
            output.append(contentsOf: data[lineStart..<lineEnd])
            output.append(newline)
            matchedLineCount += 1

            if lineEnd < data.endIndex {
                searchStart = data.index(after: lineEnd)
                lineScanStart = searchStart
            } else {
                searchStart = data.endIndex
                lineScanStart = data.endIndex
            }
            if output.count >= 64 * 1024 {
                FileHandle.standardOutput.write(output)
                output.removeAll(keepingCapacity: true)
            }
        }
        if !output.isEmpty {
            FileHandle.standardOutput.write(output)
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func stopOnNonmatchLineExitCode(
        path: String,
        literal: [UInt8],
        maxCount: Int? = nil,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literal.isEmpty,
              maxCount != 0 else {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWriteStopOnNonmatchLiteralLines(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                maxCount: maxCount ?? Int.max,
                lineNumber: lineNumber,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func stopOnNonmatchCountLineExitCode(
        path: String,
        literal: [UInt8],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard !literal.isEmpty,
              maxCount != 0 else {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            if includeZero {
                guard writeCountOutput(0, countPrefix: countPrefix, crlfTerminated: crlfTerminated) else {
                    return nil
                }
            }
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinCountStopOnNonmatchLiteralLines(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                maxCount: maxCount ?? Int.max
            )
        }) else {
            return nil
        }
        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func countLineExitCode(
        path: String,
        literal: [UInt8],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              maxCount.map({ $0 > 0 }) ?? true else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }

        let matchedLineCount = countLiteralMatchedLines(
            in: data,
            literal: literal,
            maxCount: maxCount
        )

        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func exactLineExitCode(
        path: String,
        literal: [UInt8],
        maxCount: Int? = nil,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              maxCount.map({ $0 > 0 }) ?? true else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }

        if !lineNumber {
            return exactLineWithoutLineNumbers(
                data: data,
                literal: literal,
                maxCount: maxCount,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }

        let needle = Data(literal)
        let newline = UInt8(ascii: "\n")
        let limit = maxCount ?? Int.max
        var searchStart = data.startIndex
        var lineScanStart = data.startIndex
        var nextLineNumber = 1
        var matchedLineCount = 0
        var emittedHeading = false
        var output = Data()
        output.reserveCapacity(64 * 1024)

        while matchedLineCount < limit,
              searchStart < data.endIndex,
              let matchRange = data.range(of: needle, in: searchStart..<data.endIndex) {
            guard !matchRange.isEmpty else {
                return nil
            }

            let lineStart = data[..<matchRange.lowerBound]
                .lastIndex(of: newline)
                .map { data.index(after: $0) } ?? data.startIndex
            let lineEnd = data[matchRange.upperBound...]
                .firstIndex(of: newline) ?? data.endIndex

            if lineNumber {
                let skippedNewlines = data[lineScanStart..<lineStart]
                    .reduce(0) { count, byte in count + (byte == newline ? 1 : 0) }
                nextLineNumber += skippedNewlines
            }
            if lineStart == matchRange.lowerBound,
               lineEnd == matchRange.upperBound {
                appendHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading, to: &output)
                appendLinePrefix(linePrefix, to: &output)
                if lineNumber {
                    appendLineNumberPrefix(
                        nextLineNumber,
                        to: &output,
                        fieldSeparator: lineNumberFieldSeparator
                    )
                }
                output.append(contentsOf: data[lineStart..<lineEnd])
                output.append(newline)
                matchedLineCount += 1
                if output.count >= 64 * 1024 {
                    FileHandle.standardOutput.write(output)
                    output.removeAll(keepingCapacity: true)
                }
            }

            if lineEnd < data.endIndex {
                searchStart = data.index(after: lineEnd)
                if lineNumber {
                    nextLineNumber += 1
                    lineScanStart = searchStart
                }
            } else {
                searchStart = data.endIndex
                lineScanStart = data.endIndex
            }
        }

        if !output.isEmpty {
            FileHandle.standardOutput.write(output)
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func exactLineFieldExitCode(
        path: String,
        literal: [UInt8],
        maxCount: Int? = nil,
        lineNumber: Bool = false,
        column: Bool = false,
        byteOffset: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              maxCount.map({ $0 > 0 }) ?? true else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }

        if !lineNumber, !column, !byteOffset {
            return exactLineWithoutLineNumbers(
                data: data,
                literal: literal,
                maxCount: maxCount,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }

        let newline = UInt8(ascii: "\n")
        let limit = maxCount ?? Int.max
        var lineNeedle = literal
        lineNeedle.append(newline)
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let matchedLineCount = data.withUnsafeBytes { rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return literal.withUnsafeBufferPointer { literalBuffer -> Int? in
                guard let literalBase = literalBuffer.baseAddress else {
                    return 0
                }
                return lineNeedle.withUnsafeBufferPointer { lineNeedleBuffer -> Int? in
                    guard let lineNeedleBase = lineNeedleBuffer.baseAddress else {
                        return 0
                    }

                    var searchOffset = 0
                    var lineCountOffset = 0
                    var currentLineNumber = 1
                    var matchedLineCount = 0
                    var emittedHeading = false

                    while matchedLineCount < limit,
                          searchOffset < data.count,
                          let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            lineNeedleBase,
                            lineNeedle.count
                          ) {
                        let matchStart = base.distance(to: found)
                        if matchStart == 0 || base[matchStart - 1] == newline {
                            if lineNumber {
                                currentLineNumber += rg_memcount_byte(
                                    base.advanced(by: lineCountOffset),
                                    matchStart - lineCountOffset,
                                    newline
                                )
                                lineCountOffset = matchStart
                            }
                            guard output.writeHeadingPrefix(
                                headingPrefix,
                                emittedHeading: &emittedHeading
                            ),
                                output.writeBytes(linePrefix) else {
                                return nil
                            }
                            if lineNumber,
                               !output.writeLineNumberPrefix(
                                currentLineNumber,
                                fieldSeparator: lineNumberFieldSeparator
                               ) {
                                return nil
                            }
                            if column,
                               !output.writeLineNumberPrefix(
                                1,
                                fieldSeparator: lineNumberFieldSeparator
                               ) {
                                return nil
                            }
                            if byteOffset,
                               !output.writeLineNumberPrefix(
                                matchStart,
                                fieldSeparator: lineNumberFieldSeparator
                               ) {
                                return nil
                            }
                            guard output.write(lineNeedleBase, count: lineNeedle.count) else {
                                return nil
                            }
                            matchedLineCount += 1
                        }
                        searchOffset = matchStart + lineNeedle.count
                    }

                    if matchedLineCount < limit,
                       data.count >= literal.count,
                       data.count > 0,
                       base[data.count - 1] != newline {
                        let suffixStart = data.count - literal.count
                        if suffixStart >= 0,
                           (suffixStart == 0 || base[suffixStart - 1] == newline),
                           memcmp(base.advanced(by: suffixStart), literalBase, literal.count) == 0 {
                            if lineNumber {
                                currentLineNumber += rg_memcount_byte(
                                    base.advanced(by: lineCountOffset),
                                    suffixStart - lineCountOffset,
                                    newline
                                )
                            }
                            guard output.writeHeadingPrefix(
                                headingPrefix,
                                emittedHeading: &emittedHeading
                            ),
                                output.writeBytes(linePrefix) else {
                                return nil
                            }
                            if lineNumber,
                               !output.writeLineNumberPrefix(
                                currentLineNumber,
                                fieldSeparator: lineNumberFieldSeparator
                               ) {
                                return nil
                            }
                            if column,
                               !output.writeLineNumberPrefix(
                                1,
                                fieldSeparator: lineNumberFieldSeparator
                               ) {
                                return nil
                            }
                            if byteOffset,
                               !output.writeLineNumberPrefix(
                                suffixStart,
                                fieldSeparator: lineNumberFieldSeparator
                               ) {
                                return nil
                            }
                            guard output.write(literalBase, count: literal.count),
                                  output.writeByte(newline) else {
                                return nil
                            }
                            matchedLineCount += 1
                        }
                    }
                    return matchedLineCount
                }
            }
        }

        guard let matchedLineCount,
              output.flush() else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func exactLineCountExitCode(
        path: String,
        literal: [UInt8],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              maxCount.map({ $0 > 0 }) ?? true else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }

        let matchedLineCount = exactLineCount(
            data: data,
            literal: literal,
            maxCount: maxCount
        )
        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func multiLiteralExactLineExitCode(
        path: String,
        literals: [[UInt8]],
        maxCount: Int? = nil,
        lineNumber: Bool = false,
        column: Bool = false,
        byteOffset: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctExactLineLiterals(literals),
              !literals.isEmpty else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        if literals.count > 1,
           !dataContainsAnyLiteral(data, literals: literals) {
            return 1
        }

        let limit = maxCount ?? Int.max
        let newline = UInt8(ascii: "\n")
        var matchedLineCount = 0
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let wroteOutput = data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return true
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            var lineStart = 0
            var lineNumberValue = 1
            var emittedHeading = false

            while lineStart < data.count, matchedLineCount < limit {
                let remaining = data.count - lineStart
                let lineEnd: Int
                let nextLineStart: Int
                if let newlinePointer = memchr(
                    base.advanced(by: lineStart),
                    Int32(newline),
                    remaining
                ) {
                    lineEnd = base.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
                    nextLineStart = lineEnd + 1
                } else {
                    lineEnd = data.count
                    nextLineStart = data.count
                }

                if exactLineRangeMatches(
                    base: base,
                    lineStart: lineStart,
                    lineEnd: lineEnd,
                    literals: literals
                ) {
                    guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading),
                          output.writeBytes(linePrefix) else {
                        return false
                    }
                    if lineNumber {
                        guard output.writeLineNumberPrefix(
                            lineNumberValue,
                            fieldSeparator: lineNumberFieldSeparator
                        ) else {
                            return false
                        }
                    }
                    if column {
                        guard output.writeLineNumberPrefix(
                            1,
                            fieldSeparator: lineNumberFieldSeparator
                        ) else {
                            return false
                        }
                    }
                    if byteOffset {
                        guard output.writeLineNumberPrefix(
                            lineStart,
                            fieldSeparator: lineNumberFieldSeparator
                        ) else {
                            return false
                        }
                    }
                    guard output.write(base.advanced(by: lineStart), count: lineEnd - lineStart),
                          output.writeByte(newline) else {
                        return false
                    }
                    matchedLineCount += 1
                }

                lineStart = nextLineStart
                if lineStart < data.count {
                    lineNumberValue += 1
                }
            }
            return true
        }
        guard wroteOutput,
              output.flush() else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveExactLineExitCode(
        path: String,
        literals: [[UInt8]],
        maxCount: Int? = nil,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctASCIICaseInsensitiveExactLineLiterals(literals),
              !literals.isEmpty else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }
        guard !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }

        if literals.count == 1 {
            return asciiCaseInsensitiveExactLineFieldOutput(
                data: data,
                foldedLiteral: literals[0],
                maxCount: maxCount,
                lineNumber: lineNumber,
                column: false,
                byteOffset: false,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }
        guard dataContainsAnyASCIICaseInsensitiveLiteral(data, foldedLiterals: literals) else {
            return 1
        }

        let limit = maxCount ?? Int.max
        let newline = UInt8(ascii: "\n")
        var matchedLineCount = 0
        guard var output = rgSwiftStdoutBuffer(capacity: 64 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let wroteOutput = data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return true
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            var lineStart = 0
            var lineNumberValue = 1
            var emittedHeading = false

            while lineStart < data.count, matchedLineCount < limit {
                let remaining = data.count - lineStart
                let lineEnd: Int
                let nextLineStart: Int
                if let newlinePointer = memchr(
                    base.advanced(by: lineStart),
                    Int32(newline),
                    remaining
                ) {
                    lineEnd = base.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
                    nextLineStart = lineEnd + 1
                } else {
                    lineEnd = data.count
                    nextLineStart = data.count
                }

                if asciiCaseInsensitiveExactLineRangeMatches(
                    base: base,
                    lineStart: lineStart,
                    lineEnd: lineEnd,
                    foldedLiterals: literals
                ) {
                    guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading),
                          output.writeBytes(linePrefix) else {
                        return false
                    }
                    if lineNumber {
                        guard output.writeLineNumberPrefix(
                            lineNumberValue,
                            fieldSeparator: lineNumberFieldSeparator
                        ) else {
                            return false
                        }
                    }
                    guard output.write(
                        base.advanced(by: lineStart),
                        count: lineEnd - lineStart
                    ),
                        output.writeByte(newline) else {
                        return false
                    }
                    matchedLineCount += 1
                }

                lineStart = nextLineStart
                if lineStart < data.count {
                    lineNumberValue += 1
                }
            }
            return true
        }

        guard wroteOutput,
              output.flush() else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    private static func asciiCaseInsensitiveExactLineFieldOutput(
        data: Data,
        foldedLiteral: [UInt8],
        maxCount: Int?,
        lineNumber: Bool,
        column: Bool,
        byteOffset: Bool,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int32? {
        guard !foldedLiteral.isEmpty else {
            return nil
        }
        guard !data.isEmpty else {
            return 1
        }

        let newline = UInt8(ascii: "\n")
        let limit = maxCount ?? Int.max
        var lineNeedle = foldedLiteral
        lineNeedle.append(newline)
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let matchedLineCount = data.withUnsafeBytes { rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return lineNeedle.withUnsafeBufferPointer { lineNeedleBuffer -> Int? in
                guard let lineNeedleBase = lineNeedleBuffer.baseAddress else {
                    return 0
                }

                var searchOffset = 0
                var lineCountOffset = 0
                var currentLineNumber = 1
                var matchedLineCount = 0
                var emittedHeading = false

                while matchedLineCount < limit,
                      searchOffset < data.count,
                      let found = rg_memcasemem_ascii_prepared(
                        base.advanced(by: searchOffset),
                        data.count - searchOffset,
                        lineNeedleBase,
                        lineNeedle.count,
                        nil
                      ) {
                    let matchStart = base.distance(to: found)
                    if matchStart == 0 || base[matchStart - 1] == newline {
                        if lineNumber {
                            currentLineNumber += rg_memcount_byte(
                                base.advanced(by: lineCountOffset),
                                matchStart - lineCountOffset,
                                newline
                            )
                            lineCountOffset = matchStart
                        }
                        guard output.writeHeadingPrefix(
                            headingPrefix,
                            emittedHeading: &emittedHeading
                        ),
                            output.writeBytes(linePrefix) else {
                            return nil
                        }
                        if lineNumber,
                           !output.writeLineNumberPrefix(
                            currentLineNumber,
                            fieldSeparator: lineNumberFieldSeparator
                           ) {
                            return nil
                        }
                        if column,
                           !output.writeLineNumberPrefix(
                            1,
                            fieldSeparator: lineNumberFieldSeparator
                           ) {
                            return nil
                        }
                        if byteOffset,
                           !output.writeLineNumberPrefix(
                            matchStart,
                            fieldSeparator: lineNumberFieldSeparator
                           ) {
                            return nil
                        }
                        guard output.write(base.advanced(by: matchStart), count: lineNeedle.count) else {
                            return nil
                        }
                        matchedLineCount += 1
                    }
                    searchOffset = matchStart + lineNeedle.count
                }

                if matchedLineCount < limit,
                   data.count >= foldedLiteral.count,
                   base[data.count - 1] != newline {
                    let suffixStart = data.count - foldedLiteral.count
                    if suffixStart >= 0,
                       (suffixStart == 0 || base[suffixStart - 1] == newline) {
                        var matched = true
                        for index in 0..<foldedLiteral.count
                        where rgSwiftASCIILower(base[suffixStart + index]) != foldedLiteral[index] {
                            matched = false
                            break
                        }
                        if matched {
                            if lineNumber {
                                currentLineNumber += rg_memcount_byte(
                                    base.advanced(by: lineCountOffset),
                                    suffixStart - lineCountOffset,
                                    newline
                                )
                            }
                            guard output.writeHeadingPrefix(
                                headingPrefix,
                                emittedHeading: &emittedHeading
                            ),
                                output.writeBytes(linePrefix) else {
                                return nil
                            }
                            if lineNumber,
                               !output.writeLineNumberPrefix(
                                currentLineNumber,
                                fieldSeparator: lineNumberFieldSeparator
                               ) {
                                return nil
                            }
                            if column,
                               !output.writeLineNumberPrefix(
                                1,
                                fieldSeparator: lineNumberFieldSeparator
                               ) {
                                return nil
                            }
                            if byteOffset,
                               !output.writeLineNumberPrefix(
                                suffixStart,
                                fieldSeparator: lineNumberFieldSeparator
                               ) {
                                return nil
                            }
                            guard output.write(
                                base.advanced(by: suffixStart),
                                count: foldedLiteral.count
                            ),
                                output.writeByte(newline) else {
                                return nil
                            }
                            matchedLineCount += 1
                        }
                    }
                }

                return matchedLineCount
            }
        }

        guard let matchedLineCount,
              output.flush() else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func multiLiteralExactLineCountExitCode(
        path: String,
        literals: [[UInt8]],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let literals = distinctExactLineLiterals(literals),
              !literals.isEmpty else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }

        let matchedLineCount = multiLiteralExactLineCount(
            data: data,
            literals: literals,
            maxCount: maxCount
        )

        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    private static func exactLineWithoutLineNumbers(
        data: Data,
        literal: [UInt8],
        maxCount: Int?,
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int32? {
        let newline = UInt8(ascii: "\n")
        let limit = maxCount ?? Int.max
        var lineNeedle = literal
        lineNeedle.append(newline)
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let matchedLineCount = data.withUnsafeBytes { rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return literal.withUnsafeBufferPointer { literalBuffer -> Int? in
                guard let literalBase = literalBuffer.baseAddress else {
                    return 0
                }
                return lineNeedle.withUnsafeBufferPointer { lineNeedleBuffer -> Int? in
                    guard let lineNeedleBase = lineNeedleBuffer.baseAddress else {
                        return 0
                    }

                    var searchOffset = 0
                    var matchedLineCount = 0
                    var emittedHeading = false

                    while matchedLineCount < limit,
                          searchOffset < data.count,
                          let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            lineNeedleBase,
                            lineNeedle.count
                          ) {
                        let matchStart = base.distance(to: found)
                        if matchStart == 0 || base[matchStart - 1] == newline {
                            guard output.writeHeadingPrefix(
                                headingPrefix,
                                emittedHeading: &emittedHeading
                            ),
                                output.writeBytes(linePrefix),
                                output.write(lineNeedleBase, count: lineNeedle.count) else {
                                return nil
                            }
                            matchedLineCount += 1
                        }
                        searchOffset = matchStart + lineNeedle.count
                    }

                    if matchedLineCount < limit,
                       data.count >= literal.count,
                       data.count > 0,
                       base[data.count - 1] != newline {
                        let suffixStart = data.count - literal.count
                        if suffixStart >= 0,
                           (suffixStart == 0 || base[suffixStart - 1] == newline),
                           memcmp(base.advanced(by: suffixStart), literalBase, literal.count) == 0 {
                            guard output.writeHeadingPrefix(
                                headingPrefix,
                                emittedHeading: &emittedHeading
                            ),
                                output.writeBytes(linePrefix),
                                output.write(literalBase, count: literal.count),
                                output.writeByte(newline) else {
                                return nil
                            }
                            matchedLineCount += 1
                        }
                    }
                    return matchedLineCount
                }
            }
        }

        guard let matchedLineCount,
              output.flush() else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    private static func exactLineCount(
        data: Data,
        literal: [UInt8],
        maxCount: Int?
    ) -> Int {
        guard !literal.isEmpty,
              data.count >= literal.count else {
            return 0
        }
        let limit = maxCount ?? Int.max
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return literal.withUnsafeBufferPointer { literalBuffer in
                guard let literalBase = literalBuffer.baseAddress else {
                    return 0
                }

                let newline = UInt8(ascii: "\n")
                var lineNeedle = literal
                lineNeedle.append(newline)
                var searchOffset = 0
                var matchedLineCount = 0
                lineNeedle.withUnsafeBufferPointer { lineNeedleBuffer in
                    guard let lineNeedleBase = lineNeedleBuffer.baseAddress else {
                        return
                    }
                    while matchedLineCount < limit,
                          searchOffset < data.count,
                          let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            lineNeedleBase,
                            lineNeedle.count
                          ) {
                        let matchStart = base.distance(to: found)
                        if matchStart == 0 || base[matchStart - 1] == newline {
                            matchedLineCount += 1
                        }
                        searchOffset = matchStart + lineNeedle.count
                    }
                }

                if matchedLineCount < limit,
                   base[data.count - 1] != newline {
                    let suffixStart = data.count - literal.count
                    if (suffixStart == 0 || base[suffixStart - 1] == newline),
                       memcmp(base.advanced(by: suffixStart), literalBase, literal.count) == 0 {
                        matchedLineCount += 1
                    }
                }

                return matchedLineCount
            }
        }
    }

    private static func multiLiteralExactLineCount(
        data: Data,
        literals: [[UInt8]],
        maxCount: Int?
    ) -> Int {
        let limit = maxCount ?? Int.max
        var matchedLineCount = 0
        for literal in literals where matchedLineCount < limit {
            matchedLineCount += exactLineCount(
                data: data,
                literal: literal,
                maxCount: limit - matchedLineCount
            )
        }
        return matchedLineCount
    }

    private static func exactLineRangeMatches(
        data: Data,
        lineStart: Data.Index,
        lineEnd: Data.Index,
        literals: [[UInt8]]
    ) -> Bool {
        let lineLength = data.distance(from: lineStart, to: lineEnd)
        guard lineLength > 0 else {
            return false
        }
        for literal in literals where literal.count == lineLength {
            guard data[lineStart] == literal[0] else {
                continue
            }
            if literal.count > 1,
               data[data.index(before: lineEnd)] != literal[literal.count - 1] {
                continue
            }
            var cursor = lineStart
            var matched = true
            for byte in literal {
                if data[cursor] != byte {
                    matched = false
                    break
                }
                cursor = data.index(after: cursor)
            }
            if matched {
                return true
            }
        }
        return false
    }

    private static func exactLineRangeMatches(
        base: UnsafePointer<UInt8>,
        lineStart: Int,
        lineEnd: Int,
        literals: [[UInt8]]
    ) -> Bool {
        let lineLength = lineEnd - lineStart
        guard lineLength > 0 else {
            return false
        }
        for literal in literals where literal.count == lineLength {
            guard base[lineStart] == literal[0] else {
                continue
            }
            if literal.count > 1,
               base[lineEnd - 1] != literal[literal.count - 1] {
                continue
            }
            let matched = literal.withUnsafeBufferPointer { literalBuffer in
                guard let literalBase = literalBuffer.baseAddress else {
                    return true
                }
                return memcmp(base.advanced(by: lineStart), literalBase, literal.count) == 0
            }
            if matched {
                return true
            }
        }
        return false
    }

    private static func asciiCaseInsensitiveExactLineRangeMatches(
        data: Data,
        lineStart: Data.Index,
        lineEnd: Data.Index,
        foldedLiterals: [[UInt8]]
    ) -> Bool {
        let lineLength = data.distance(from: lineStart, to: lineEnd)
        guard lineLength > 0 else {
            return false
        }
        for literal in foldedLiterals where literal.count == lineLength {
            guard rgSwiftASCIILower(data[lineStart]) == literal[0] else {
                continue
            }
            if literal.count > 1,
               rgSwiftASCIILower(data[data.index(before: lineEnd)]) != literal[literal.count - 1] {
                continue
            }
            var cursor = lineStart
            var matched = true
            for byte in literal {
                if rgSwiftASCIILower(data[cursor]) != byte {
                    matched = false
                    break
                }
                cursor = data.index(after: cursor)
            }
            if matched {
                return true
            }
        }
        return false
    }

    private static func asciiCaseInsensitiveExactLineRangeMatches(
        base: UnsafePointer<UInt8>,
        lineStart: Int,
        lineEnd: Int,
        foldedLiterals: [[UInt8]]
    ) -> Bool {
        let lineLength = lineEnd - lineStart
        guard lineLength > 0 else {
            return false
        }
        for literal in foldedLiterals where literal.count == lineLength {
            guard rgSwiftASCIILower(base[lineStart]) == literal[0] else {
                continue
            }
            if literal.count > 1,
               rgSwiftASCIILower(base[lineEnd - 1]) != literal[literal.count - 1] {
                continue
            }
            var matched = true
            for offset in 0..<literal.count {
                if rgSwiftASCIILower(base[lineStart + offset]) != literal[offset] {
                    matched = false
                    break
                }
            }
            if matched {
                return true
            }
        }
        return false
    }

    private static func asciiCaseInsensitiveExactLineCount(
        data: Data,
        foldedLiterals: [[UInt8]],
        maxCount: Int?
    ) -> Int {
        let limit = maxCount ?? Int.max
        var matchedLineCount = 0
        for literal in foldedLiterals where matchedLineCount < limit {
            matchedLineCount += asciiCaseInsensitiveExactLineCount(
                data: data,
                foldedLiteral: literal,
                maxCount: limit - matchedLineCount
            )
        }
        return matchedLineCount
    }

    private static func asciiCaseInsensitiveExactLineCount(
        data: Data,
        foldedLiteral: [UInt8],
        maxCount: Int?
    ) -> Int {
        guard !foldedLiteral.isEmpty,
              data.count >= foldedLiteral.count else {
            return 0
        }
        let limit = maxCount ?? Int.max
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            let newline = UInt8(ascii: "\n")
            var lineNeedle = foldedLiteral
            lineNeedle.append(newline)
            var searchOffset = 0
            var matchedLineCount = 0

            lineNeedle.withUnsafeBufferPointer { lineNeedleBuffer in
                guard let lineNeedleBase = lineNeedleBuffer.baseAddress else {
                    return
                }
                while matchedLineCount < limit,
                      searchOffset < data.count,
                      let found = rg_memcasemem_ascii_prepared(
                        base.advanced(by: searchOffset),
                        data.count - searchOffset,
                        lineNeedleBase,
                        lineNeedle.count,
                        nil
                      ) {
                    let matchStart = base.distance(to: found)
                    if matchStart == 0 || base[matchStart - 1] == newline {
                        matchedLineCount += 1
                    }
                    searchOffset = matchStart + lineNeedle.count
                }
            }

            if matchedLineCount < limit,
               base[data.count - 1] != newline {
                let suffixStart = data.count - foldedLiteral.count
                if suffixStart >= 0,
                   (suffixStart == 0 || base[suffixStart - 1] == newline) {
                    var matched = true
                    for index in 0..<foldedLiteral.count
                    where rgSwiftASCIILower(base[suffixStart + index]) != foldedLiteral[index] {
                        matched = false
                        break
                    }
                    if matched {
                        matchedLineCount += 1
                    }
                }
            }

            return matchedLineCount
        }
    }

    private static func hasBinaryDetectionPrefix(_ data: Data) -> Bool {
        containsNULByte(data, limit: 64 * 1024)
    }

    private static func containsASCIIFixedClassSequence(
        path: String,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass]
    ) -> Bool? {
        guard !classes.isEmpty,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !startsWithUTFBOM(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return false
        }
        return data.withUnsafeBytes { rawData -> Bool? in
            guard let rawBase = rawData.baseAddress else {
                return false
            }
            return asciiFixedClassSequenceMatch(
                baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                searchCount: rawData.count,
                classes: classes
            )
        }
    }

    private static func asciiFixedClassNoMatchByteCount(
        path: String,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass]
    ) -> Int? {
        guard !classes.isEmpty,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !startsWithUTFBOM(data),
              !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return data.count
        }
        let matched = data.withUnsafeBytes { rawData -> Bool in
            guard let rawBase = rawData.baseAddress else {
                return false
            }
            return asciiFixedClassSequenceMatch(
                baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                searchCount: rawData.count,
                classes: classes
            )
        }
        guard !matched else {
            return nil
        }
        return data.count
    }

    private static func asciiFixedClassMatchedSummaryStats(
        path: String,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        maxCount: Int? = nil
    ) -> MatchedSummaryStats? {
        guard !classes.isEmpty,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !startsWithUTFBOM(data),
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data) else {
            return nil
        }
        guard !data.isEmpty else {
            return nil
        }
        if let maxCount {
            guard maxCount > 0 else {
                return nil
            }
            return data.withUnsafeBytes { rawData -> MatchedSummaryStats? in
                guard let rawBase = rawData.baseAddress else {
                    return MatchedSummaryStats(
                        totalMatches: 0,
                        matchedLines: 0,
                        bytesSearched: data.count
                    )
                }
                return asciiFixedClassBoundedMatchedSummaryStats(
                    baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                    dataCount: rawData.count,
                    classes: classes,
                    maxCount: maxCount
                )
            }
        }
        let counts = data.withUnsafeBytes { rawData -> (matches: Int, matchedLines: Int) in
            guard let rawBase = rawData.baseAddress else {
                return (0, 0)
            }
            return asciiFixedClassMatchedCounts(
                baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                searchCount: rawData.count,
                classes: classes
            )
        }
        guard counts.matches > 0,
              counts.matchedLines > 0 else {
            return nil
        }
        return MatchedSummaryStats(
            totalMatches: counts.matches,
            matchedLines: counts.matchedLines,
            bytesSearched: data.count
        )
    }

    private static func asciiFixedClassBoundedMatchedSummaryStats(
        baseAddress: UnsafePointer<UInt8>,
        dataCount: Int,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        maxCount: Int
    ) -> MatchedSummaryStats? {
        let width = classes.count
        guard width > 0, maxCount > 0, dataCount >= width else {
            return MatchedSummaryStats(
                totalMatches: 0,
                matchedLines: 0,
                bytesSearched: dataCount
            )
        }

        let newline = UInt8(ascii: "\n")
        var searchOffset = 0
        var selectedLineEnd = -1
        var matchedLineCount = 0
        var matchCount = 0
        var bytesSearched = dataCount

        while let matchStart = asciiFixedClassNextSequenceMatch(
            baseAddress: baseAddress,
            endExclusive: matchedLineCount >= maxCount ? selectedLineEnd : dataCount,
            classes: classes,
            from: searchOffset
        ) {
            if matchStart >= selectedLineEnd {
                guard matchedLineCount < maxCount else {
                    break
                }
                matchedLineCount += 1
                if let newlinePointer = memchr(
                    baseAddress.advanced(by: matchStart),
                    Int32(newline),
                    dataCount - matchStart
                ) {
                    selectedLineEnd = baseAddress.distance(
                        to: newlinePointer.assumingMemoryBound(to: UInt8.self)
                    ) + 1
                } else {
                    selectedLineEnd = dataCount
                }
            }

            matchCount += 1
            searchOffset = matchStart + width
        }
        if matchedLineCount >= maxCount, selectedLineEnd >= 0 {
            bytesSearched = selectedLineEnd
        }

        return MatchedSummaryStats(
            totalMatches: matchCount,
            matchedLines: matchedLineCount,
            bytesSearched: bytesSearched
        )
    }

    private static func asciiFixedClassMatchedLineOutput(
        path: String,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        lineNumber: Bool,
        maxCount: Int,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8],
        collectTotalMatches: Bool
    ) -> MatchedOutputStats? {
        guard !classes.isEmpty,
              maxCount > 0,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !startsWithUTFBOM(data),
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data) else {
            return nil
        }
        return data.withUnsafeBytes { rawData -> MatchedOutputStats? in
            guard let rawBase = rawData.baseAddress else {
                return MatchedOutputStats(
                    totalMatches: 0,
                    matchedLines: 0,
                    bytesPrinted: 0,
                    bytesSearched: data.count
                )
            }
            return asciiFixedClassMatchedLineOutput(
                baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                dataCount: rawData.count,
                classes: classes,
                lineNumber: lineNumber,
                maxCount: maxCount,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix,
                collectTotalMatches: collectTotalMatches
            )
        }
    }

    private static func asciiFixedClassMatchedLineOutput(
        baseAddress: UnsafePointer<UInt8>,
        dataCount: Int,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        lineNumber: Bool,
        maxCount: Int,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8],
        collectTotalMatches: Bool
    ) -> MatchedOutputStats? {
        let width = classes.count
        guard width > 0, dataCount >= width else {
            return MatchedOutputStats(
                totalMatches: 0,
                matchedLines: 0,
                bytesPrinted: 0,
                bytesSearched: dataCount
            )
        }
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let newline = UInt8(ascii: "\n")
        var searchOffset = 0
        var lineStart = 0
        var lineNumberAtLineStart = 1
        var matchedLineCount = 0
        var totalMatches = 0
        var bytesSearched = dataCount
        var synthesizedLineTerminators = 0
        var emittedHeading = false

        func recentLineStart(before matchOffset: Int) -> Int? {
            let scanLimit = max(0, matchOffset - 4096)
            var cursor = matchOffset
            while cursor > scanLimit {
                cursor -= 1
                if baseAddress[cursor] == newline {
                    return cursor + 1
                }
            }
            return cursor == 0 ? 0 : nil
        }

        func advanceLineStart(to matchOffset: Int) {
            while lineStart < matchOffset {
                let distance = matchOffset - lineStart
                guard let newlinePointer = memchr(
                    baseAddress.advanced(by: lineStart),
                    Int32(newline),
                    distance
                ) else {
                    return
                }
                let newlineOffset = baseAddress.distance(
                    to: newlinePointer.assumingMemoryBound(to: UInt8.self)
                )
                lineNumberAtLineStart += 1
                lineStart = newlineOffset + 1
            }
        }

        while let matchOffset = asciiFixedClassNextSequenceMatch(
            baseAddress: baseAddress,
            endExclusive: dataCount,
            classes: classes,
            from: searchOffset
        ) {
            guard matchedLineCount < maxCount else {
                break
            }
            if let boundedLineStart = recentLineStart(before: matchOffset) {
                if lineNumber, boundedLineStart > lineStart {
                    lineNumberAtLineStart += rg_memcount_byte(
                        baseAddress.advanced(by: lineStart),
                        boundedLineStart - lineStart,
                        newline
                    )
                }
                lineStart = boundedLineStart
            } else {
                advanceLineStart(to: matchOffset)
            }

            let newlinePointer = memchr(
                baseAddress.advanced(by: matchOffset),
                Int32(newline),
                dataCount - matchOffset
            )
            let lineEnd = newlinePointer.map {
                baseAddress.distance(to: $0.assumingMemoryBound(to: UInt8.self))
            } ?? dataCount
            let outputEnd = newlinePointer == nil ? dataCount : lineEnd + 1

            if collectTotalMatches {
                var spanSearchOffset = matchOffset
                while let spanStart = asciiFixedClassNextSequenceMatch(
                    baseAddress: baseAddress,
                    endExclusive: lineEnd,
                    classes: classes,
                    from: spanSearchOffset
                ) {
                    totalMatches += 1
                    spanSearchOffset = spanStart + width
                }
            }

            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading),
                  output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber,
               !output.writeLineNumberPrefix(
                lineNumberAtLineStart,
                fieldSeparator: lineNumberFieldSeparator
               ) {
                return nil
            }
            guard output.write(baseAddress.advanced(by: lineStart), count: outputEnd - lineStart) else {
                return nil
            }
            if newlinePointer == nil,
               !output.writeByte(newline) {
                return nil
            }
            if newlinePointer == nil {
                synthesizedLineTerminators += 1
            }

            matchedLineCount += 1
            if matchedLineCount >= maxCount {
                bytesSearched = outputEnd
                break
            }
            searchOffset = outputEnd
            lineStart = outputEnd
            if newlinePointer != nil {
                lineNumberAtLineStart += 1
            } else {
                break
            }
        }

        guard output.flush() else {
            return nil
        }
        return MatchedOutputStats(
            totalMatches: collectTotalMatches ? totalMatches : matchedLineCount,
            matchedLines: matchedLineCount,
            bytesPrinted: output.statsBytesWritten + synthesizedLineTerminators,
            bytesSearched: bytesSearched
        )
    }

    private static func asciiFixedClassMatchedLineOutputCount(
        path: String,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        lineNumber: Bool,
        maxCount: Int,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int? {
        guard !classes.isEmpty,
              maxCount > 0,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !startsWithUTFBOM(data),
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data) else {
            return nil
        }
        return data.withUnsafeBytes { rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return asciiFixedClassMatchedLineOutputCount(
                baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                dataCount: rawData.count,
                classes: classes,
                lineNumber: lineNumber,
                maxCount: maxCount,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }
    }

    private static func asciiFixedClassMatchedLineOutputCount(
        baseAddress: UnsafePointer<UInt8>,
        dataCount: Int,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        lineNumber: Bool,
        maxCount: Int,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int? {
        let width = classes.count
        guard width > 0, dataCount >= width else {
            return 0
        }
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let newline = UInt8(ascii: "\n")
        var searchOffset = 0
        var lineStart = 0
        var lineNumberAtLineStart = 1
        var matchedLineCount = 0
        var emittedHeading = false

        func recentLineStart(before matchOffset: Int) -> Int? {
            let scanLimit = max(0, matchOffset - 4096)
            var cursor = matchOffset
            while cursor > scanLimit {
                cursor -= 1
                if baseAddress[cursor] == newline {
                    return cursor + 1
                }
            }
            return cursor == 0 ? 0 : nil
        }

        func advanceLineStart(to matchOffset: Int) {
            while lineStart < matchOffset {
                let distance = matchOffset - lineStart
                guard let newlinePointer = memchr(
                    baseAddress.advanced(by: lineStart),
                    Int32(newline),
                    distance
                ) else {
                    return
                }
                let newlineOffset = baseAddress.distance(
                    to: newlinePointer.assumingMemoryBound(to: UInt8.self)
                )
                lineNumberAtLineStart += 1
                lineStart = newlineOffset + 1
            }
        }

        while let matchOffset = asciiFixedClassNextSequenceMatch(
            baseAddress: baseAddress,
            endExclusive: dataCount,
            classes: classes,
            from: searchOffset
        ) {
            if let boundedLineStart = recentLineStart(before: matchOffset) {
                if lineNumber, boundedLineStart > lineStart {
                    lineNumberAtLineStart += rg_memcount_byte(
                        baseAddress.advanced(by: lineStart),
                        boundedLineStart - lineStart,
                        newline
                    )
                }
                lineStart = boundedLineStart
            } else {
                advanceLineStart(to: matchOffset)
            }

            let newlinePointer = memchr(
                baseAddress.advanced(by: matchOffset),
                Int32(newline),
                dataCount - matchOffset
            )
            let lineEnd = newlinePointer.map {
                baseAddress.distance(to: $0.assumingMemoryBound(to: UInt8.self))
            } ?? dataCount
            let outputEnd = newlinePointer == nil ? dataCount : lineEnd + 1

            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading),
                  output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber,
               !output.writeLineNumberPrefix(
                lineNumberAtLineStart,
                fieldSeparator: lineNumberFieldSeparator
               ) {
                return nil
            }
            guard output.write(baseAddress.advanced(by: lineStart), count: outputEnd - lineStart) else {
                return nil
            }
            if newlinePointer == nil,
               !output.writeByte(newline) {
                return nil
            }

            matchedLineCount += 1
            if matchedLineCount >= maxCount {
                break
            }
            searchOffset = outputEnd
            lineStart = outputEnd
            if newlinePointer != nil {
                lineNumberAtLineStart += 1
            } else {
                break
            }
        }

        guard output.flush() else {
            return nil
        }
        return matchedLineCount
    }

    private static func asciiFixedClassMaxColumnsLineOutput(
        path: String,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        lineNumber: Bool,
        maxCount: Int,
        maxColumns: Int,
        maxColumnsPreview: Bool,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8],
        collectTotalMatches: Bool
    ) -> MatchedOutputStats? {
        guard !classes.isEmpty,
              maxCount > 0,
              maxColumns > 0,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !startsWithUTFBOM(data),
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data) else {
            return nil
        }
        return data.withUnsafeBytes { rawData -> MatchedOutputStats? in
            guard let rawBase = rawData.baseAddress else {
                return MatchedOutputStats(
                    totalMatches: 0,
                    matchedLines: 0,
                    bytesPrinted: 0,
                    bytesSearched: data.count
                )
            }
            return asciiFixedClassMaxColumnsLineOutput(
                baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                dataCount: rawData.count,
                classes: classes,
                lineNumber: lineNumber,
                maxCount: maxCount,
                maxColumns: maxColumns,
                maxColumnsPreview: maxColumnsPreview,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix,
                collectTotalMatches: collectTotalMatches
            )
        }
    }

    private static func asciiFixedClassPlainMaxColumnsPreviewOutputCount(
        path: String,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        maxCount: Int,
        maxColumns: Int
    ) -> Int? {
        guard !classes.isEmpty,
              maxCount > 0,
              maxColumns > 0,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !startsWithUTFBOM(data),
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data) else {
            return nil
        }
        return data.withUnsafeBytes { rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return asciiFixedClassPlainMaxColumnsPreviewOutputCount(
                baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                dataCount: rawData.count,
                classes: classes,
                maxCount: maxCount,
                maxColumns: maxColumns
            )
        }
    }

    private static func asciiFixedClassPlainMaxColumnsPreviewOutputCount(
        baseAddress: UnsafePointer<UInt8>,
        dataCount: Int,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        maxCount: Int,
        maxColumns: Int
    ) -> Int? {
        let width = classes.count
        guard width > 0, maxColumns > 0, dataCount >= width else {
            return 0
        }
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let newline = UInt8(ascii: "\n")
        var searchOffset = 0
        var lineStart = 0
        var matchedLineCount = 0

        func recentLineStart(before matchOffset: Int) -> Int? {
            let scanLimit = max(0, matchOffset - 4096)
            var cursor = matchOffset
            while cursor > scanLimit {
                cursor -= 1
                if baseAddress[cursor] == newline {
                    return cursor + 1
                }
            }
            return cursor == 0 ? 0 : nil
        }

        func advanceLineStart(to matchOffset: Int) {
            while lineStart < matchOffset {
                let distance = matchOffset - lineStart
                guard let newlinePointer = memchr(
                    baseAddress.advanced(by: lineStart),
                    Int32(newline),
                    distance
                ) else {
                    return
                }
                let newlineOffset = baseAddress.distance(
                    to: newlinePointer.assumingMemoryBound(to: UInt8.self)
                )
                lineStart = newlineOffset + 1
            }
        }

        while let matchOffset = asciiFixedClassNextSequenceMatch(
            baseAddress: baseAddress,
            endExclusive: dataCount,
            classes: classes,
            from: searchOffset
        ) {
            guard matchedLineCount < maxCount else {
                break
            }
            if let boundedLineStart = recentLineStart(before: matchOffset) {
                lineStart = boundedLineStart
            } else {
                advanceLineStart(to: matchOffset)
            }

            let newlinePointer = memchr(
                baseAddress.advanced(by: matchOffset),
                Int32(newline),
                dataCount - matchOffset
            )
            let lineEnd = newlinePointer.map {
                baseAddress.distance(to: $0.assumingMemoryBound(to: UInt8.self))
            } ?? dataCount
            let outputEnd = newlinePointer == nil ? dataCount : lineEnd + 1
            let lineByteCount = lineEnd - lineStart

            if lineByteCount >= maxColumns {
                guard !rgSwiftContainsNonASCIIByte(
                    baseAddress.advanced(by: lineStart),
                    count: maxColumns
                ) else {
                    return nil
                }
                guard output.write(baseAddress.advanced(by: lineStart), count: maxColumns),
                      output.writeBytes(previewOmittedEndSuffix) else {
                    return nil
                }
            } else {
                guard output.write(baseAddress.advanced(by: lineStart), count: outputEnd - lineStart) else {
                    return nil
                }
                if newlinePointer == nil,
                   !output.writeByte(newline) {
                    return nil
                }
            }

            matchedLineCount += 1
            if matchedLineCount >= maxCount {
                break
            }
            searchOffset = outputEnd
            lineStart = outputEnd
            if newlinePointer == nil {
                break
            }
        }

        guard output.flush() else {
            return nil
        }
        return matchedLineCount
    }

    private static func asciiFixedClassMaxColumnsLineOutput(
        baseAddress: UnsafePointer<UInt8>,
        dataCount: Int,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        lineNumber: Bool,
        maxCount: Int,
        maxColumns: Int,
        maxColumnsPreview: Bool,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8],
        collectTotalMatches: Bool
    ) -> MatchedOutputStats? {
        let width = classes.count
        guard width > 0, maxColumns > 0, dataCount >= width else {
            return MatchedOutputStats(
                totalMatches: 0,
                matchedLines: 0,
                bytesPrinted: 0,
                bytesSearched: dataCount
            )
        }
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let newline = UInt8(ascii: "\n")
        var searchOffset = 0
        var lineStart = 0
        var lineNumberAtLineStart = 1
        var matchedLineCount = 0
        var totalMatches = 0
        var bytesSearched = dataCount
        var synthesizedLineTerminators = 0
        var emittedHeading = false

        func advanceLineStart(to matchOffset: Int) {
            while lineStart < matchOffset {
                let distance = matchOffset - lineStart
                guard let newlinePointer = memchr(
                    baseAddress.advanced(by: lineStart),
                    Int32(newline),
                    distance
                ) else {
                    return
                }
                let newlineOffset = baseAddress.distance(
                    to: newlinePointer.assumingMemoryBound(to: UInt8.self)
                )
                lineNumberAtLineStart += 1
                lineStart = newlineOffset + 1
            }
        }

        func writePreviewSuffix(remainingMatches: Int?) -> Bool {
            guard let remainingMatches else {
                return output.writeBytes(previewOmittedEndSuffix)
            }
            return output.writeBytes(previewMoreMatchesPrefix)
                && output.writeLineNumberPrefix(
                    remainingMatches,
                    fieldSeparator: remainingMatches == 1 ? previewMoreMatchSuffix : previewMoreMatchesSuffix
                )
        }

        while let matchOffset = asciiFixedClassNextSequenceMatch(
            baseAddress: baseAddress,
            endExclusive: dataCount,
            classes: classes,
            from: searchOffset
        ) {
            guard matchedLineCount < maxCount else {
                break
            }
            advanceLineStart(to: matchOffset)

            let newlinePointer = memchr(
                baseAddress.advanced(by: matchOffset),
                Int32(newline),
                dataCount - matchOffset
            )
            let lineEnd = newlinePointer.map {
                baseAddress.distance(to: $0.assumingMemoryBound(to: UInt8.self))
            } ?? dataCount
            let outputEnd = newlinePointer == nil ? dataCount : lineEnd + 1
            let lineByteCount = lineEnd - lineStart
            var lineMatchCount = 1
            var remainingLineMatches = matchOffset - lineStart >= maxColumns ? 1 : 0

            if collectTotalMatches {
                lineMatchCount = 0
                remainingLineMatches = 0
                var spanSearchOffset = matchOffset
                while let spanStart = asciiFixedClassNextSequenceMatch(
                    baseAddress: baseAddress,
                    endExclusive: lineEnd,
                    classes: classes,
                    from: spanSearchOffset
                ) {
                    lineMatchCount += 1
                    if spanStart - lineStart >= maxColumns {
                        remainingLineMatches += 1
                    }
                    spanSearchOffset = spanStart + width
                }
                totalMatches += lineMatchCount
            }

            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading),
                  output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber,
               !output.writeLineNumberPrefix(
                lineNumberAtLineStart,
                fieldSeparator: lineNumberFieldSeparator
               ) {
                return nil
            }

            if lineByteCount >= maxColumns {
                if maxColumnsPreview {
                    guard !rgSwiftContainsNonASCIIByte(
                        baseAddress.advanced(by: lineStart),
                        count: maxColumns
                    ) else {
                        return nil
                    }
                    guard output.write(baseAddress.advanced(by: lineStart), count: maxColumns),
                          writePreviewSuffix(
                            remainingMatches: collectTotalMatches ? remainingLineMatches : nil
                          ) else {
                        return nil
                    }
                } else if collectTotalMatches {
                    guard output.writeBytes(omittedLongLineWithPrefix),
                          output.writeLineNumberPrefix(lineMatchCount, fieldSeparator: omittedLongLineWithSuffix) else {
                        return nil
                    }
                } else if !output.writeBytes(omittedLongMatchingLine) {
                    return nil
                }
            } else {
                guard output.write(baseAddress.advanced(by: lineStart), count: outputEnd - lineStart) else {
                    return nil
                }
                if newlinePointer == nil,
                   !output.writeByte(newline) {
                    return nil
                }
                if newlinePointer == nil {
                    synthesizedLineTerminators += 1
                }
            }

            matchedLineCount += 1
            if matchedLineCount >= maxCount {
                bytesSearched = outputEnd
                break
            }
            searchOffset = outputEnd
            lineStart = outputEnd
            if newlinePointer != nil {
                lineNumberAtLineStart += 1
            } else {
                break
            }
        }

        guard output.flush() else {
            return nil
        }
        return MatchedOutputStats(
            totalMatches: collectTotalMatches ? totalMatches : matchedLineCount,
            matchedLines: matchedLineCount,
            bytesPrinted: output.statsBytesWritten + synthesizedLineTerminators,
            bytesSearched: bytesSearched
        )
    }

    private static func asciiFixedClassOmittedLongLineOutput(
        path: String,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        maxCount: Int,
        maxColumns: Int
    ) -> Int? {
        guard !classes.isEmpty,
              maxCount > 0,
              maxColumns > 0,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !startsWithUTFBOM(data),
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data) else {
            return nil
        }
        return data.withUnsafeBytes { rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            return asciiFixedClassOmittedLongLineOutput(
                baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                dataCount: rawData.count,
                classes: classes,
                maxCount: maxCount,
                maxColumns: maxColumns
            )
        }
    }

    private static func asciiFixedClassOmittedLongLineOutput(
        baseAddress: UnsafePointer<UInt8>,
        dataCount: Int,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        maxCount: Int,
        maxColumns: Int
    ) -> Int? {
        let width = classes.count
        guard width > 0, maxColumns > 0, dataCount >= width else {
            return 0
        }
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let newline = UInt8(ascii: "\n")
        var searchOffset = 0
        var matchedLineCount = 0

        while let matchOffset = asciiFixedClassNextSequenceMatch(
            baseAddress: baseAddress,
            endExclusive: dataCount,
            classes: classes,
            from: searchOffset
        ) {
            let newlinePointer = memchr(
                baseAddress.advanced(by: matchOffset),
                Int32(newline),
                dataCount - matchOffset
            )
            let lineEnd = newlinePointer.map {
                baseAddress.distance(to: $0.assumingMemoryBound(to: UInt8.self))
            } ?? dataCount
            let outputEnd = newlinePointer == nil ? dataCount : lineEnd + 1

            let backLimit = max(0, matchOffset - maxColumns)
            var cursor = matchOffset
            var previousNewline: Int?
            while cursor > backLimit {
                cursor -= 1
                if baseAddress[cursor] == newline {
                    previousNewline = cursor
                    break
                }
            }

            let lineIsLong: Bool
            let lineStart: Int
            if let previousNewline {
                lineStart = previousNewline + 1
                lineIsLong = lineEnd - lineStart >= maxColumns
            } else if matchOffset >= maxColumns {
                lineStart = 0
                lineIsLong = true
            } else {
                lineStart = 0
                lineIsLong = lineEnd >= maxColumns
            }

            if lineIsLong {
                guard output.writeBytes(omittedLongMatchingLine) else {
                    return nil
                }
            } else {
                guard output.write(baseAddress.advanced(by: lineStart), count: outputEnd - lineStart) else {
                    return nil
                }
                if newlinePointer == nil,
                   !output.writeByte(newline) {
                    return nil
                }
            }

            matchedLineCount += 1
            if matchedLineCount >= maxCount {
                break
            }
            searchOffset = outputEnd
            if newlinePointer == nil {
                break
            }
        }

        guard output.flush() else {
            return nil
        }
        return matchedLineCount
    }

    private static func asciiFixedClassOnlyMatchingOutput(
        path: String,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        lineNumber: Bool,
        byteOffset: Bool,
        column: Bool,
        maxCount: Int,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> MatchedOutputStats? {
        guard !classes.isEmpty,
              maxCount > 0,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !startsWithUTFBOM(data),
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data) else {
            return nil
        }
        return data.withUnsafeBytes { rawData -> MatchedOutputStats? in
            guard let rawBase = rawData.baseAddress else {
                return MatchedOutputStats(
                    totalMatches: 0,
                    matchedLines: 0,
                    bytesPrinted: 0,
                    bytesSearched: data.count
                )
            }
            return asciiFixedClassOnlyMatchingOutput(
                baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                dataCount: rawData.count,
                classes: classes,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                column: column,
                maxCount: maxCount,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }
    }

    private static func asciiFixedClassOnlyMatchingOutput(
        baseAddress: UnsafePointer<UInt8>,
        dataCount: Int,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        lineNumber: Bool,
        byteOffset: Bool,
        column: Bool,
        maxCount: Int,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> MatchedOutputStats? {
        let width = classes.count
        guard width > 0, dataCount >= width else {
            return MatchedOutputStats(
                totalMatches: 0,
                matchedLines: 0,
                bytesPrinted: 0,
                bytesSearched: dataCount
            )
        }
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let newline = UInt8(ascii: "\n")
        var searchOffset = 0
        var selectedLineEnd = -1
        var matchedLineCount = 0
        var matchCount = 0
        var currentLineNumber = 1
        var currentLineStart = 0
        var lineCountOffset = 0
        var emittedHeading = false
        var bytesSearched = dataCount

        func advanceLineState(to matchStart: Int) {
            while lineCountOffset < matchStart {
                let distance = matchStart - lineCountOffset
                guard let newlinePointer = memchr(
                    baseAddress.advanced(by: lineCountOffset),
                    Int32(newline),
                    distance
                ) else {
                    return
                }
                let newlineOffset = baseAddress.distance(
                    to: newlinePointer.assumingMemoryBound(to: UInt8.self)
                )
                currentLineNumber += 1
                currentLineStart = newlineOffset + 1
                lineCountOffset = currentLineStart
            }
        }

        while let matchStart = asciiFixedClassNextSequenceMatch(
            baseAddress: baseAddress,
            endExclusive: matchedLineCount >= maxCount ? selectedLineEnd : dataCount,
            classes: classes,
            from: searchOffset
        ) {
            if matchStart >= selectedLineEnd {
                guard matchedLineCount < maxCount else {
                    break
                }
                matchedLineCount += 1
                if let newlinePointer = memchr(
                    baseAddress.advanced(by: matchStart),
                    Int32(newline),
                    dataCount - matchStart
                ) {
                    selectedLineEnd = baseAddress.distance(
                        to: newlinePointer.assumingMemoryBound(to: UInt8.self)
                    ) + 1
                } else {
                    selectedLineEnd = dataCount
                }
            }

            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading),
                  output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber || column {
                advanceLineState(to: matchStart)
            }
            if lineNumber,
               !output.writeLineNumberPrefix(currentLineNumber, fieldSeparator: lineNumberFieldSeparator) {
                return nil
            }
            if column,
               !output.writeLineNumberPrefix(
                matchStart - currentLineStart + 1,
                fieldSeparator: lineNumberFieldSeparator
               ) {
                return nil
            }
            if byteOffset,
               !output.writeLineNumberPrefix(matchStart, fieldSeparator: lineNumberFieldSeparator) {
                return nil
            }
            guard output.write(baseAddress.advanced(by: matchStart), count: width),
                  output.writeByte(newline) else {
                return nil
            }

            matchCount += 1
            searchOffset = matchStart + width
        }
        if matchedLineCount >= maxCount, selectedLineEnd >= 0 {
            bytesSearched = selectedLineEnd
        }

        guard output.flush() else {
            return nil
        }
        return MatchedOutputStats(
            totalMatches: matchCount,
            matchedLines: matchedLineCount,
            bytesPrinted: output.statsBytesWritten + matchCount,
            bytesSearched: bytesSearched
        )
    }

    private static func asciiFixedClassJSONOutput(
        path: String,
        displayPath: [UInt8],
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        noLineNumber: Bool,
        maxCount: Int
    ) -> Int32? {
        guard !classes.isEmpty,
              maxCount > 0,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !startsWithUTFBOM(data),
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data),
              !containsNonASCIIByte(data) else {
            return nil
        }
        return data.withUnsafeBytes { rawData -> Int32? in
            guard let rawBase = rawData.baseAddress else {
                return writeNoMatchSummary(bytesSearched: data.count, json: true)
            }
            return asciiFixedClassJSONOutput(
                baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                dataCount: rawData.count,
                displayPath: displayPath,
                classes: classes,
                noLineNumber: noLineNumber,
                maxCount: maxCount
            )
        }
    }

    private static func asciiFixedClassJSONOutput(
        baseAddress: UnsafePointer<UInt8>,
        dataCount: Int,
        displayPath: [UInt8],
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        noLineNumber: Bool,
        maxCount: Int
    ) -> Int32? {
        let width = classes.count
        guard width > 0, dataCount >= width else {
            return writeNoMatchSummary(bytesSearched: dataCount, json: true)
        }
        guard let firstMatch = asciiFixedClassNextSequenceMatch(
            baseAddress: baseAddress,
            endExclusive: dataCount,
            classes: classes,
            from: 0
        ) else {
            return writeNoMatchSummary(bytesSearched: dataCount, json: true)
        }
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let newline = UInt8(ascii: "\n")
        var fileBytesPrinted = 0
        var totalMatches = 0
        var matchedLineCount = 0
        var currentLineNumber = 1
        var currentLineStart = 0
        var lineCountOffset = 0
        var bytesSearched = dataCount

        func advanceLineState(to matchStart: Int) {
            while lineCountOffset < matchStart {
                let distance = matchStart - lineCountOffset
                guard let newlinePointer = memchr(
                    baseAddress.advanced(by: lineCountOffset),
                    Int32(newline),
                    distance
                ) else {
                    return
                }
                let newlineOffset = baseAddress.distance(
                    to: newlinePointer.assumingMemoryBound(to: UInt8.self)
                )
                currentLineNumber += 1
                currentLineStart = newlineOffset + 1
                lineCountOffset = currentLineStart
            }
        }

        guard let beginBytes = writeJSONBeginRecord(
            displayPath: displayPath,
            to: &output
        ) else {
            return nil
        }
        fileBytesPrinted += beginBytes

        var searchOffset = firstMatch
        while let matchStart = asciiFixedClassNextSequenceMatch(
            baseAddress: baseAddress,
            endExclusive: dataCount,
            classes: classes,
            from: searchOffset
        ) {
            guard matchedLineCount < maxCount else {
                break
            }
            advanceLineState(to: matchStart)
            let lineStart = currentLineStart
            let lineNumber = currentLineNumber
            let lineEnd: Int
            let outputEnd: Int
            if let newlinePointer = memchr(
                baseAddress.advanced(by: matchStart),
                Int32(newline),
                dataCount - matchStart
            ) {
                lineEnd = baseAddress.distance(
                    to: newlinePointer.assumingMemoryBound(to: UInt8.self)
                )
                outputEnd = lineEnd + 1
            } else {
                lineEnd = dataCount
                outputEnd = dataCount
            }

            var spans: [(start: Int, end: Int)] = []
            var spanSearchOffset = matchStart
            while let spanStart = asciiFixedClassNextSequenceMatch(
                baseAddress: baseAddress,
                endExclusive: lineEnd,
                classes: classes,
                from: spanSearchOffset
            ) {
                spans.append((spanStart - lineStart, spanStart - lineStart + width))
                totalMatches += 1
                spanSearchOffset = spanStart + width
            }
            guard !spans.isEmpty,
                  let matchBytes = writeJSONMatchRecord(
                    displayPath: displayPath,
                    lineBaseAddress: baseAddress.advanced(by: lineStart),
                    lineByteCount: outputEnd - lineStart,
                    lineNumber: lineNumber,
                    noLineNumber: noLineNumber,
                    absoluteOffset: lineStart,
                    spans: spans,
                    to: &output
                  ) else {
                return nil
            }
            matchedLineCount += 1
            fileBytesPrinted += matchBytes
            if matchedLineCount >= maxCount {
                bytesSearched = outputEnd
                break
            }
            searchOffset = outputEnd
        }

        guard writeJSONEndRecord(
            displayPath: displayPath,
            bytesSearched: bytesSearched,
            bytesPrinted: fileBytesPrinted,
            matchedLines: matchedLineCount,
            matches: totalMatches,
            to: &output
        ),
              writeJSONSummaryRecord(
                bytesPrinted: fileBytesPrinted,
                bytesSearched: bytesSearched,
                matchedLines: matchedLineCount,
                matches: totalMatches,
                filesSearched: 1,
                filesWithMatches: matchedLineCount > 0 ? 1 : 0,
                to: &output
              ),
              output.flush() else {
            return nil
        }
        return totalMatches > 0 ? 0 : 1
    }

    private static func writeJSONBeginRecord(
        displayPath: [UInt8],
        to output: inout rgSwiftStdoutBuffer
    ) -> Int? {
        var bytesWritten = 0
        guard writeCountedJSONBytes(
            Array(#"{"type":"begin","data":{"path":{"text":"#.utf8),
            to: &output,
            bytesWritten: &bytesWritten
        ),
              writeJSONEscapedBytes(displayPath, to: &output, bytesWritten: &bytesWritten),
              writeCountedJSONBytes(Array(#"}}}"#.utf8), to: &output, bytesWritten: &bytesWritten),
              writeCountedJSONByte(UInt8(ascii: "\n"), to: &output, bytesWritten: &bytesWritten) else {
            return nil
        }
        return bytesWritten
    }

    private static func writeJSONMatchRecord(
        displayPath: [UInt8],
        lineBaseAddress: UnsafePointer<UInt8>,
        lineByteCount: Int,
        lineNumber: Int,
        noLineNumber: Bool,
        absoluteOffset: Int,
        spans: [(start: Int, end: Int)],
        to output: inout rgSwiftStdoutBuffer
    ) -> Int? {
        var bytesWritten = 0
        guard writeCountedJSONBytes(
            Array(#"{"type":"match","data":{"path":{"text":"#.utf8),
            to: &output,
            bytesWritten: &bytesWritten
        ),
              writeJSONEscapedBytes(displayPath, to: &output, bytesWritten: &bytesWritten),
              writeCountedJSONBytes(Array(#"},"lines":{"text":"#.utf8), to: &output, bytesWritten: &bytesWritten),
              writeJSONEscapedBytes(
                lineBaseAddress,
                count: lineByteCount,
                to: &output,
                bytesWritten: &bytesWritten
              ),
              writeCountedJSONBytes(
                Array(#"},"line_number":"#.utf8),
                to: &output,
                bytesWritten: &bytesWritten
              ) else {
            return nil
        }
        if noLineNumber {
            guard writeCountedJSONBytes(Array("null".utf8), to: &output, bytesWritten: &bytesWritten) else {
                return nil
            }
        } else {
            guard writeCountedJSONInt(lineNumber, to: &output, bytesWritten: &bytesWritten) else {
                return nil
            }
        }
        guard writeCountedJSONBytes(
            Array(#","absolute_offset":"#.utf8),
            to: &output,
            bytesWritten: &bytesWritten
        ),
              writeCountedJSONInt(absoluteOffset, to: &output, bytesWritten: &bytesWritten),
              writeCountedJSONBytes(
                Array(#","submatches":["#.utf8),
                to: &output,
                bytesWritten: &bytesWritten
              ) else {
            return nil
        }

        for (index, span) in spans.enumerated() {
            if index > 0,
               !writeCountedJSONByte(UInt8(ascii: ","), to: &output, bytesWritten: &bytesWritten) {
                return nil
            }
            guard writeCountedJSONBytes(
                Array(#"{"match":{"text":"#.utf8),
                to: &output,
                bytesWritten: &bytesWritten
            ),
                  writeJSONEscapedBytes(
                    lineBaseAddress.advanced(by: span.start),
                    count: span.end - span.start,
                    to: &output,
                    bytesWritten: &bytesWritten
                  ),
                  writeCountedJSONBytes(
                    Array(#"},"start":"#.utf8),
                    to: &output,
                    bytesWritten: &bytesWritten
                  ),
                  writeCountedJSONInt(span.start, to: &output, bytesWritten: &bytesWritten),
                  writeCountedJSONBytes(Array(#","end":"#.utf8), to: &output, bytesWritten: &bytesWritten),
                  writeCountedJSONInt(span.end, to: &output, bytesWritten: &bytesWritten),
                  writeCountedJSONByte(UInt8(ascii: "}"), to: &output, bytesWritten: &bytesWritten) else {
                return nil
            }
        }
        guard writeCountedJSONBytes(Array(#"]}}"#.utf8), to: &output, bytesWritten: &bytesWritten),
              writeCountedJSONByte(UInt8(ascii: "\n"), to: &output, bytesWritten: &bytesWritten) else {
            return nil
        }
        return bytesWritten
    }

    private static func writeJSONEndRecord(
        displayPath: [UInt8],
        bytesSearched: Int,
        bytesPrinted: Int,
        matchedLines: Int,
        matches: Int,
        to output: inout rgSwiftStdoutBuffer
    ) -> Bool {
        guard output.writeBytes(Array(#"{"type":"end","data":{"path":{"text":"#.utf8)),
              writeJSONEscapedBytes(displayPath, to: &output),
              output.writeBytes(Array(#"},"binary_offset":null,"stats":{"elapsed":{"secs":0,"nanos":0,"human":"0.000000s"},"searches":1,"searches_with_match":1,"bytes_searched":"#.utf8)),
              writeJSONInt(bytesSearched, to: &output),
              output.writeBytes(Array(#","bytes_printed":"#.utf8)),
              writeJSONInt(bytesPrinted, to: &output),
              output.writeBytes(Array(#","matched_lines":"#.utf8)),
              writeJSONInt(matchedLines, to: &output),
              output.writeBytes(Array(#","matches":"#.utf8)),
              writeJSONInt(matches, to: &output),
              output.writeBytes(Array(#"}}}"#.utf8)),
              output.writeByte(UInt8(ascii: "\n")) else {
            return false
        }
        return true
    }

    private static func writeJSONSummaryRecord(
        bytesPrinted: Int,
        bytesSearched: Int,
        matchedLines: Int,
        matches: Int,
        filesSearched: Int,
        filesWithMatches: Int,
        to output: inout rgSwiftStdoutBuffer
    ) -> Bool {
        guard output.writeBytes(Array(#"{"data":{"elapsed_total":{"human":"0.000000s","nanos":0,"secs":0},"stats":{"bytes_printed":"#.utf8)),
              writeJSONInt(bytesPrinted, to: &output),
              output.writeBytes(Array(#","bytes_searched":"#.utf8)),
              writeJSONInt(bytesSearched, to: &output),
              output.writeBytes(Array(#","elapsed":{"human":"0.000000s","nanos":0,"secs":0},"matched_lines":"#.utf8)),
              writeJSONInt(matchedLines, to: &output),
              output.writeBytes(Array(#","matches":"#.utf8)),
              writeJSONInt(matches, to: &output),
              output.writeBytes(Array(#","searches":"#.utf8)),
              writeJSONInt(filesSearched, to: &output),
              output.writeBytes(Array(#","searches_with_match":"#.utf8)),
              writeJSONInt(filesWithMatches, to: &output),
              output.writeBytes(Array(#"}},"type":"summary"}"#.utf8)),
              output.writeByte(UInt8(ascii: "\n")) else {
            return false
        }
        return true
    }

    private static func writeJSONEscapedBytes(
        _ bytes: [UInt8],
        to output: inout rgSwiftStdoutBuffer
    ) -> Bool {
        var ignoredBytesWritten = 0
        return writeJSONEscapedBytes(bytes, to: &output, bytesWritten: &ignoredBytesWritten)
    }

    private static func writeJSONEscapedBytes(
        _ bytes: [UInt8],
        to output: inout rgSwiftStdoutBuffer,
        bytesWritten: inout Int
    ) -> Bool {
        guard !bytes.isEmpty else {
            return writeCountedJSONBytes(Array(#""""#.utf8), to: &output, bytesWritten: &bytesWritten)
        }
        return bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return writeCountedJSONBytes(Array(#""""#.utf8), to: &output, bytesWritten: &bytesWritten)
            }
            return writeJSONEscapedBytes(
                baseAddress,
                count: buffer.count,
                to: &output,
                bytesWritten: &bytesWritten
            )
        }
    }

    private static func writeJSONEscapedBytes(
        _ baseAddress: UnsafePointer<UInt8>,
        count: Int,
        to output: inout rgSwiftStdoutBuffer
    ) -> Bool {
        var ignoredBytesWritten = 0
        return writeJSONEscapedBytes(
            baseAddress,
            count: count,
            to: &output,
            bytesWritten: &ignoredBytesWritten
        )
    }

    private static func writeJSONEscapedBytes(
        _ baseAddress: UnsafePointer<UInt8>,
        count: Int,
        to output: inout rgSwiftStdoutBuffer,
        bytesWritten: inout Int
    ) -> Bool {
        guard writeCountedJSONByte(UInt8(ascii: "\""), to: &output, bytesWritten: &bytesWritten) else {
            return false
        }
        let hex = Array("0123456789ABCDEF".utf8)
        for index in 0..<count {
            let byte = baseAddress[index]
            switch byte {
            case UInt8(ascii: "\""):
                guard writeCountedJSONBytes(Array(#"\""#.utf8), to: &output, bytesWritten: &bytesWritten) else {
                    return false
                }
            case UInt8(ascii: "\\"):
                guard writeCountedJSONBytes(Array(#"\\"#.utf8), to: &output, bytesWritten: &bytesWritten) else {
                    return false
                }
            case UInt8(ascii: "\u{08}"):
                guard writeCountedJSONBytes(Array(#"\b"#.utf8), to: &output, bytesWritten: &bytesWritten) else {
                    return false
                }
            case UInt8(ascii: "\t"):
                guard writeCountedJSONBytes(Array(#"\t"#.utf8), to: &output, bytesWritten: &bytesWritten) else {
                    return false
                }
            case UInt8(ascii: "\n"):
                guard writeCountedJSONBytes(Array(#"\n"#.utf8), to: &output, bytesWritten: &bytesWritten) else {
                    return false
                }
            case UInt8(ascii: "\u{0C}"):
                guard writeCountedJSONBytes(Array(#"\f"#.utf8), to: &output, bytesWritten: &bytesWritten) else {
                    return false
                }
            case UInt8(ascii: "\r"):
                guard writeCountedJSONBytes(Array(#"\r"#.utf8), to: &output, bytesWritten: &bytesWritten) else {
                    return false
                }
            case 0x00...0x1F:
                guard writeCountedJSONBytes(
                    [
                        UInt8(ascii: "\\"),
                        UInt8(ascii: "u"),
                        UInt8(ascii: "0"),
                        UInt8(ascii: "0"),
                        hex[Int(byte >> 4)],
                        hex[Int(byte & 0x0F)],
                    ],
                    to: &output,
                    bytesWritten: &bytesWritten
                ) else {
                    return false
                }
            default:
                guard writeCountedJSONByte(byte, to: &output, bytesWritten: &bytesWritten) else {
                    return false
                }
            }
        }
        return writeCountedJSONByte(UInt8(ascii: "\""), to: &output, bytesWritten: &bytesWritten)
    }

    private static func writeJSONInt(_ value: Int, to output: inout rgSwiftStdoutBuffer) -> Bool {
        var ignoredBytesWritten = 0
        return writeCountedJSONInt(value, to: &output, bytesWritten: &ignoredBytesWritten)
    }

    private static func writeCountedJSONInt(
        _ value: Int,
        to output: inout rgSwiftStdoutBuffer,
        bytesWritten: inout Int
    ) -> Bool {
        let bytes = Array(String(value).utf8)
        return writeCountedJSONBytes(bytes, to: &output, bytesWritten: &bytesWritten)
    }

    private static func writeCountedJSONBytes(
        _ bytes: [UInt8],
        to output: inout rgSwiftStdoutBuffer,
        bytesWritten: inout Int
    ) -> Bool {
        guard output.writeBytes(bytes) else {
            return false
        }
        bytesWritten += bytes.count
        return true
    }

    private static func writeCountedJSONByte(
        _ byte: UInt8,
        to output: inout rgSwiftStdoutBuffer,
        bytesWritten: inout Int
    ) -> Bool {
        guard output.writeByte(byte) else {
            return false
        }
        bytesWritten += 1
        return true
    }

    private static func asciiFixedClassVimgrepLineOutput(
        path: String,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        lineNumber: Bool,
        byteOffset: Bool,
        column: Bool,
        maxCount: Int,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8]
    ) -> MatchedOutputStats? {
        guard !classes.isEmpty,
              maxCount > 0,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !startsWithUTFBOM(data),
              !hasBinaryDetectionPrefix(data),
              !containsNULByte(data) else {
            return nil
        }
        return data.withUnsafeBytes { rawData -> MatchedOutputStats? in
            guard let rawBase = rawData.baseAddress else {
                return MatchedOutputStats(
                    totalMatches: 0,
                    matchedLines: 0,
                    bytesPrinted: 0,
                    bytesSearched: data.count
                )
            }
            return asciiFixedClassVimgrepLineOutput(
                baseAddress: rawBase.assumingMemoryBound(to: UInt8.self),
                dataCount: rawData.count,
                classes: classes,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                column: column,
                maxCount: maxCount,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix
            )
        }
    }

    private static func asciiFixedClassVimgrepLineOutput(
        baseAddress: UnsafePointer<UInt8>,
        dataCount: Int,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        lineNumber: Bool,
        byteOffset: Bool,
        column: Bool,
        maxCount: Int,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8]
    ) -> MatchedOutputStats? {
        let width = classes.count
        guard width > 0, dataCount >= width else {
            return MatchedOutputStats(
                totalMatches: 0,
                matchedLines: 0,
                bytesPrinted: 0,
                bytesSearched: dataCount
            )
        }
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let newline = UInt8(ascii: "\n")
        var searchOffset = 0
        var selectedLineEnd = -1
        var matchedLineCount = 0
        var matchCount = 0
        var currentLineNumber = 1
        var currentLineStart = 0
        var lineCountOffset = 0
        var bytesSearched = dataCount

        func advanceLineState(to matchStart: Int) {
            while lineCountOffset < matchStart {
                let distance = matchStart - lineCountOffset
                guard let newlinePointer = memchr(
                    baseAddress.advanced(by: lineCountOffset),
                    Int32(newline),
                    distance
                ) else {
                    return
                }
                let newlineOffset = baseAddress.distance(
                    to: newlinePointer.assumingMemoryBound(to: UInt8.self)
                )
                currentLineNumber += 1
                currentLineStart = newlineOffset + 1
                lineCountOffset = currentLineStart
            }
        }

        while let matchStart = asciiFixedClassNextSequenceMatch(
            baseAddress: baseAddress,
            endExclusive: matchedLineCount >= maxCount ? selectedLineEnd : dataCount,
            classes: classes,
            from: searchOffset
        ) {
            if matchStart >= selectedLineEnd {
                guard matchedLineCount < maxCount else {
                    break
                }
                matchedLineCount += 1
                if let newlinePointer = memchr(
                    baseAddress.advanced(by: matchStart),
                    Int32(newline),
                    dataCount - matchStart
                ) {
                    selectedLineEnd = baseAddress.distance(
                        to: newlinePointer.assumingMemoryBound(to: UInt8.self)
                    ) + 1
                } else {
                    selectedLineEnd = dataCount
                }
            }

            advanceLineState(to: matchStart)
            let lineOutputEnd = if selectedLineEnd > currentLineStart,
                                   selectedLineEnd <= dataCount,
                                   baseAddress[selectedLineEnd - 1] == newline {
                selectedLineEnd - 1
            } else {
                selectedLineEnd
            }

            guard output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber,
               !output.writeLineNumberPrefix(currentLineNumber, fieldSeparator: lineNumberFieldSeparator) {
                return nil
            }
            if column,
               !output.writeLineNumberPrefix(
                matchStart - currentLineStart + 1,
                fieldSeparator: lineNumberFieldSeparator
               ) {
                return nil
            }
            if byteOffset,
               !output.writeLineNumberPrefix(matchStart, fieldSeparator: lineNumberFieldSeparator) {
                return nil
            }
            guard output.write(baseAddress.advanced(by: currentLineStart), count: lineOutputEnd - currentLineStart),
                  output.writeByte(newline) else {
                return nil
            }

            matchCount += 1
            searchOffset = matchStart + width
        }
        if matchedLineCount >= maxCount, selectedLineEnd >= 0 {
            bytesSearched = selectedLineEnd
        }

        guard output.flush() else {
            return nil
        }
        return MatchedOutputStats(
            totalMatches: matchCount,
            matchedLines: matchedLineCount,
            bytesPrinted: output.statsBytesWritten + matchCount,
            bytesSearched: bytesSearched
        )
    }

    private static func asciiFixedClassMatchedCounts(
        baseAddress: UnsafePointer<UInt8>,
        searchCount: Int,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass]
    ) -> (matches: Int, matchedLines: Int) {
        let width = classes.count
        guard width > 0, searchCount >= width else {
            return (0, 0)
        }

        let newline = UInt8(ascii: "\n")
        let lastStart = searchCount - width
        var matches = 0
        var matchedLines = 0
        var lineHasMatch = false
        var offset = 0
        guard asciiFixedClassShouldUseCandidateJumps(
            baseAddress: baseAddress,
            searchCount: searchCount,
            byteClass: classes[0]
        ) else {
            while offset <= lastStart {
                if baseAddress[offset] == newline {
                    lineHasMatch = false
                    offset += 1
                    continue
                }
                guard asciiFixedClassByte(baseAddress[offset], matches: classes[0]) else {
                    offset += 1
                    continue
                }

                var classIndex = 1
                while classIndex < width,
                      asciiFixedClassByte(baseAddress[offset + classIndex], matches: classes[classIndex]) {
                    classIndex += 1
                }
                if classIndex == width {
                    matches += 1
                    if !lineHasMatch {
                        matchedLines += 1
                        lineHasMatch = true
                    }
                    offset += width
                    continue
                }
                offset += 1
            }
            return (matches, matchedLines)
        }

        while let candidateOffset = asciiFixedClassNextCandidate(
            baseAddress: baseAddress,
            endExclusive: lastStart + 1,
            byteClass: classes[0],
            from: offset
        ) {
            if candidateOffset > offset,
               memchr(baseAddress.advanced(by: offset), Int32(newline), candidateOffset - offset) != nil {
                lineHasMatch = false
            }

            var classIndex = 1
            while classIndex < width,
                  asciiFixedClassByte(baseAddress[candidateOffset + classIndex], matches: classes[classIndex]) {
                classIndex += 1
            }
            if classIndex == width {
                matches += 1
                if !lineHasMatch {
                    matchedLines += 1
                    lineHasMatch = true
                }
                offset = candidateOffset + width
                continue
            }
            offset = candidateOffset + 1
        }
        return (matches, matchedLines)
    }

    private static func asciiFixedClassShouldUseCandidateJumps(
        baseAddress: UnsafePointer<UInt8>,
        searchCount: Int,
        byteClass: ASCIIFixedClassSequenceFastPath.ByteClass
    ) -> Bool {
        let sampleCount = min(searchCount, 4096)
        guard sampleCount > 0 else {
            return false
        }
        var matches = 0
        var offset = 0
        while offset < sampleCount {
            if asciiFixedClassByte(baseAddress[offset], matches: byteClass) {
                matches += 1
                if matches * 8 > sampleCount {
                    return false
                }
            }
            offset += 1
        }
        return true
    }

    private static func asciiFixedClassSequenceMatch(
        baseAddress: UnsafePointer<UInt8>,
        searchCount: Int,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass]
    ) -> Bool {
        let width = classes.count
        guard width > 0, searchCount >= width else {
            return false
        }

        let lastStartExclusive = searchCount - width + 1
        var offset = 0
        while let candidateOffset = asciiFixedClassNextCandidate(
            baseAddress: baseAddress,
            endExclusive: lastStartExclusive,
            byteClass: classes[0],
            from: offset
        ) {
            var classIndex = 1
            while classIndex < width,
                  asciiFixedClassByte(baseAddress[candidateOffset + classIndex], matches: classes[classIndex]) {
                classIndex += 1
            }
            if classIndex == width {
                return true
            }
            offset = candidateOffset + 1
        }
        return false
    }

    private static func asciiFixedClassNextSequenceMatch(
        baseAddress: UnsafePointer<UInt8>,
        endExclusive: Int,
        classes: [ASCIIFixedClassSequenceFastPath.ByteClass],
        from startOffset: Int
    ) -> Int? {
        let width = classes.count
        guard width > 0 else {
            return nil
        }
        let lastStartExclusive = endExclusive - width + 1
        guard lastStartExclusive > startOffset else {
            return nil
        }

        var offset = startOffset
        while let candidateOffset = asciiFixedClassNextCandidate(
            baseAddress: baseAddress,
            endExclusive: lastStartExclusive,
            byteClass: classes[0],
            from: offset
        ) {
            var classIndex = 1
            while classIndex < width,
                  asciiFixedClassByte(baseAddress[candidateOffset + classIndex], matches: classes[classIndex]) {
                classIndex += 1
            }
            if classIndex == width {
                return candidateOffset
            }
            offset = candidateOffset + 1
        }
        return nil
    }

    private static func asciiFixedClassNextCandidate(
        baseAddress: UnsafePointer<UInt8>,
        endExclusive: Int,
        byteClass: ASCIIFixedClassSequenceFastPath.ByteClass,
        from startOffset: Int
    ) -> Int? {
        let endExclusive = max(0, endExclusive)
        var cursor = max(0, startOffset)
        guard cursor < endExclusive else {
            return nil
        }

        let lower: UInt8
        let upper: UInt8
        switch byteClass {
        case .uppercase:
            lower = UInt8(ascii: "A")
            upper = UInt8(ascii: "Z")
        case .lowercase:
            lower = UInt8(ascii: "a")
            upper = UInt8(ascii: "z")
        case .digit:
            lower = UInt8(ascii: "0")
            upper = UInt8(ascii: "9")
        }

        if endExclusive - cursor >= 16 {
            let lowerVector = SIMD16<UInt8>(repeating: lower)
            let upperVector = SIMD16<UInt8>(repeating: upper)
            let vectorLimit = endExclusive - 15
            while cursor < vectorLimit {
                let bytes = UnsafeRawPointer(baseAddress.advanced(by: cursor))
                    .loadUnaligned(as: SIMD16<UInt8>.self)
                let matches = (bytes .>= lowerVector) .& (bytes .<= upperVector)
                if matches._storage.min() < 0 {
                    for lane in 0..<16 where matches[lane] {
                        return cursor + lane
                    }
                }
                cursor += 16
            }
        }

        while cursor < endExclusive {
            if asciiFixedClassByte(baseAddress[cursor], matches: byteClass) {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private static func asciiFixedClassByte(
        _ byte: UInt8,
        matches byteClass: ASCIIFixedClassSequenceFastPath.ByteClass
    ) -> Bool {
        switch byteClass {
        case .uppercase:
            byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
        case .lowercase:
            byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
        case .digit:
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }
    }

    private static func startsWithUTFBOM(_ data: Data) -> Bool {
        data.starts(with: [0xEF, 0xBB, 0xBF])
            || data.starts(with: [0xFF, 0xFE])
            || data.starts(with: [0xFE, 0xFF])
    }

    private static func containsNULByte(_ data: Data, limit: Int? = nil) -> Bool {
        data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return false
            }
            let byteCount = min(rawData.count, max(0, limit ?? rawData.count))
            guard byteCount > 0 else {
                return false
            }
            return memchr(rawBase, 0, byteCount) != nil
        }
    }

    private static func hasTextEncodingBOM(_ data: Data) -> Bool {
        if data.count >= 3,
           data[data.startIndex] == 0xEF,
           data[data.index(data.startIndex, offsetBy: 1)] == 0xBB,
           data[data.index(data.startIndex, offsetBy: 2)] == 0xBF {
            return true
        }
        if data.count >= 2 {
            let second = data[data.index(data.startIndex, offsetBy: 1)]
            if data[data.startIndex] == 0xFF && second == 0xFE
                || data[data.startIndex] == 0xFE && second == 0xFF {
                return true
            }
        }
        return false
    }

    private static func containsNonASCIIByte(_ data: Data) -> Bool {
        return data.withUnsafeBytes { (rawData: UnsafeRawBufferPointer) -> Bool in
            guard let rawBase = rawData.baseAddress else {
                return false
            }
            return rgSwiftContainsNonASCIIByte(
                rawBase.assumingMemoryBound(to: UInt8.self),
                count: rawData.count
            )
        }
    }

    private static func containsLiteral(path: String, literal: [UInt8]) -> Bool? {
        guard !literal.isEmpty else {
            return nil
        }

        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return false
        }
        return dataContainsLiteralUsingSIMD(data, literal: literal)
    }

    private static func containsLiteralUsingSIMD(path: String, literal: [UInt8]) -> Bool? {
        guard !literal.isEmpty else {
            return nil
        }

        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return false
        }
        return dataContainsLiteralUsingSIMD(data, literal: literal)
    }

    private static func literalNoMatchByteCount(path: String, literal: [UInt8]) -> Int? {
        guard !literal.isEmpty else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        guard !dataContainsLiteralUsingSIMD(data, literal: literal) else {
            return nil
        }
        return data.count
    }

    private static func noMatchByteCount(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        wordRegexp: Bool
    ) -> Int? {
        if asciiCaseInsensitive && wordRegexp {
            return asciiCaseInsensitiveWordNoMatchByteCount(path: path, literal: literal)
        }
        if asciiCaseInsensitive {
            return asciiCaseInsensitiveNoMatchByteCount(path: path, literal: literal)
        }
        if wordRegexp {
            return wordNoMatchByteCount(path: path, literal: literal)
        }
        return literalNoMatchByteCount(path: path, literal: literal)
    }

    private static func asciiCaseInsensitiveNoMatchByteCount(path: String, literal: [UInt8]) -> Int? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              literal.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !hasBinaryDetectionPrefix(data),
              let matched = containsASCIICaseInsensitiveLiteral(data: data, literal: literal),
              !matched else {
            return nil
        }
        return data.count
    }

    private static func wordNoMatchByteCount(path: String, literal: [UInt8]) -> Int? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              let first = literal.first,
              let last = literal.last,
              rgSwiftIsASCIIRegexWordByte(first),
              rgSwiftIsASCIIRegexWordByte(last) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        guard dataContainsLiteralUsingSIMD(data, literal: literal) else {
            return data.count
        }
        guard let matchedLineCount = countASCIIWordMatchedLines(
                in: data,
                literal: literal,
                maxCount: 1
              ),
              matchedLineCount == 0 else {
            return nil
        }
        return data.count
    }

    private static func asciiCaseInsensitiveWordNoMatchByteCount(path: String, literal: [UInt8]) -> Int? {
        guard isSafeASCIIWordLiteral(literal) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard let matchedLineCount = countASCIIWordMatchedLines(
            in: data,
            literals: [literal],
            maxCount: 1,
            asciiCaseInsensitive: true
        ),
              matchedLineCount == 0,
              !containsNULByte(data),
              !containsNonASCIIByte(data) else {
            return nil
        }
        return data.count
    }

    private static func dataContainsLiteralUsingSIMD(_ data: Data, literal: [UInt8]) -> Bool {
        guard !literal.isEmpty,
              data.count >= literal.count else {
            return false
        }
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return false
            }
            return literal.withUnsafeBufferPointer { literalBytes in
                guard let literalBase = literalBytes.baseAddress else {
                    return false
                }
                return rg_memmem_simple(
                    rawBase.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    literalBase,
                    literal.count
                ) != nil
            }
        }
    }

    private static func dataContainsAnyLiteral(_ data: Data, literals: [[UInt8]]) -> Bool {
        for literal in literals where dataContainsLiteralUsingSIMD(data, literal: literal) {
            return true
        }
        return false
    }

    private static func dataContainsASCIICaseInsensitiveLiteral(
        _ data: Data,
        foldedLiteral: [UInt8]
    ) -> Bool {
        guard !foldedLiteral.isEmpty,
              data.count >= foldedLiteral.count else {
            return false
        }
        if foldedLiteral.count == 1 {
            return dataContainsASCIICaseInsensitiveByte(data, foldedByte: foldedLiteral[0])
        }
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return false
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return foldedLiteral.withUnsafeBufferPointer { literalBuffer in
                guard let literalBase = literalBuffer.baseAddress else {
                    return false
                }
                return rg_memcasemem_ascii_prepared(
                    base,
                    data.count,
                    literalBase,
                    literalBuffer.count,
                    nil
                ) != nil
            }
        }
    }

    private static func dataContainsASCIICaseInsensitiveByte(
        _ data: Data,
        foldedByte: UInt8
    ) -> Bool {
        let needles: [UInt8]
        if foldedByte >= UInt8(ascii: "a"),
           foldedByte <= UInt8(ascii: "z") {
            needles = [foldedByte, foldedByte - (UInt8(ascii: "a") - UInt8(ascii: "A"))]
        } else {
            needles = [foldedByte]
        }
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return false
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return needles.withUnsafeBufferPointer { needleBuffer in
                rg_memchr_any_bytes(
                    base,
                    data.count,
                    needleBuffer.baseAddress,
                    needleBuffer.count
                ) != nil
            }
        }
    }

    private static func dataContainsAnyASCIICaseInsensitiveLiteral(
        _ data: Data,
        foldedLiterals: [[UInt8]]
    ) -> Bool {
        for literal in foldedLiterals
        where dataContainsASCIICaseInsensitiveLiteral(data, foldedLiteral: literal) {
            return true
        }
        return false
    }

    private static func containsFixedLookbehindLiteral(
        path: String,
        prefix: [UInt8],
        literal: [UInt8],
        prefixShouldMatch: Bool
    ) -> Bool? {
        guard !prefix.isEmpty,
              !literal.isEmpty,
              !prefix.contains(UInt8(ascii: "\n")),
              !literal.contains(UInt8(ascii: "\n")),
              !prefix.contains(UInt8(ascii: "\r")),
              !literal.contains(UInt8(ascii: "\r")) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard data.count >= literal.count else {
            return false
        }

        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return false
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return prefix.withUnsafeBufferPointer { prefixBytes in
                literal.withUnsafeBufferPointer { literalBytes in
                    guard let prefixBase = prefixBytes.baseAddress,
                          let literalBase = literalBytes.baseAddress else {
                        return false
                    }
                    var searchOffset = 0
                    while searchOffset <= data.count - literal.count {
                        guard let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            literalBase,
                            literal.count
                        ) else {
                            return false
                        }
                        let matchStart = base.distance(to: found)
                        let hasPrefix = matchStart >= prefix.count
                            && memcmp(
                                base.advanced(by: matchStart - prefix.count),
                                prefixBase,
                                prefix.count
                            ) == 0
                        if hasPrefix == prefixShouldMatch {
                            return true
                        }
                        searchOffset = matchStart + 1
                    }
                    return false
                }
            }
        }
    }

    private static func containsFixedLookaheadLiteral(
        path: String,
        literal: [UInt8],
        suffix: [UInt8],
        suffixShouldMatch: Bool
    ) -> Bool? {
        guard !literal.isEmpty,
              !suffix.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              !suffix.contains(UInt8(ascii: "\n")),
              !literal.contains(UInt8(ascii: "\r")),
              !suffix.contains(UInt8(ascii: "\r")) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard data.count >= literal.count else {
            return false
        }

        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return false
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return literal.withUnsafeBufferPointer { literalBytes in
                suffix.withUnsafeBufferPointer { suffixBytes in
                    guard let literalBase = literalBytes.baseAddress,
                          let suffixBase = suffixBytes.baseAddress else {
                        return false
                    }
                    var searchOffset = 0
                    while searchOffset <= data.count - literal.count {
                        guard let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            literalBase,
                            literal.count
                        ) else {
                            return false
                        }
                        let matchStart = base.distance(to: found)
                        let suffixStart = matchStart + literal.count
                        let hasSuffix = suffixStart + suffix.count <= data.count
                            && memcmp(
                                base.advanced(by: suffixStart),
                                suffixBase,
                                suffix.count
                            ) == 0
                        if hasSuffix == suffixShouldMatch {
                            return true
                        }
                        searchOffset = matchStart + 1
                    }
                    return false
                }
            }
        }
    }

    private static func fixedLookaroundInputsAreSafe(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        !first.isEmpty
            && !second.isEmpty
            && !first.contains(UInt8(ascii: "\n"))
            && !second.contains(UInt8(ascii: "\n"))
            && !first.contains(UInt8(ascii: "\r"))
            && !second.contains(UInt8(ascii: "\r"))
    }

    private static func nextLineStart(
        after offset: Int,
        in base: UnsafePointer<UInt8>,
        count: Int
    ) -> Int {
        guard offset < count,
              let newline = memchr(
                base.advanced(by: offset),
                Int32(UInt8(ascii: "\n")),
                count - offset
              ) else {
            return count
        }
        return base.distance(to: newline.assumingMemoryBound(to: UInt8.self)) + 1
    }

    private static func countFixedLookbehindMatchedLines(
        path: String,
        prefix: [UInt8],
        literal: [UInt8],
        prefixShouldMatch: Bool,
        maxCount: Int?
    ) -> Int? {
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard data.count >= literal.count else {
            return 0
        }
        let limit = maxCount ?? Int.max

        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return prefix.withUnsafeBufferPointer { prefixBytes in
                literal.withUnsafeBufferPointer { literalBytes in
                    guard let prefixBase = prefixBytes.baseAddress,
                          let literalBase = literalBytes.baseAddress else {
                        return 0
                    }
                    var searchOffset = 0
                    var matchedLineCount = 0
                    while matchedLineCount < limit,
                          searchOffset <= data.count - literal.count {
                        guard let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            literalBase,
                            literal.count
                        ) else {
                            return matchedLineCount
                        }
                        let matchStart = base.distance(to: found)
                        let hasPrefix = matchStart >= prefix.count
                            && memcmp(
                                base.advanced(by: matchStart - prefix.count),
                                prefixBase,
                                prefix.count
                            ) == 0
                        if hasPrefix == prefixShouldMatch {
                            matchedLineCount += 1
                            searchOffset = nextLineStart(
                                after: matchStart + literal.count,
                                in: base,
                                count: data.count
                            )
                        } else {
                            searchOffset = matchStart + 1
                        }
                    }
                    return matchedLineCount
                }
            }
        }
    }

    private static func countFixedLookbehindMatches(
        path: String,
        prefix: [UInt8],
        literal: [UInt8],
        prefixShouldMatch: Bool,
        maxCount: Int? = nil
    ) -> Int? {
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard data.count >= literal.count else {
            return 0
        }
        if let maxCount {
            guard let selectedPrefixEnd = fixedLookbehindSelectedPrefixEnd(
                data: data,
                prefix: prefix,
                literal: literal,
                prefixShouldMatch: prefixShouldMatch,
                maxCount: maxCount
            ) else {
                return nil
            }
            guard selectedPrefixEnd > 0 else {
                return 0
            }
            return countFixedLookbehindMatches(
                in: Data(data[..<selectedPrefixEnd]),
                prefix: prefix,
                literal: literal,
                prefixShouldMatch: prefixShouldMatch
            )
        }
        return countFixedLookbehindMatches(
            in: data,
            prefix: prefix,
            literal: literal,
            prefixShouldMatch: prefixShouldMatch
        )
    }

    private static func countFixedLookbehindMatches(
        in data: Data,
        prefix: [UInt8],
        literal: [UInt8],
        prefixShouldMatch: Bool
    ) -> Int? {
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return prefix.withUnsafeBufferPointer { prefixBytes in
                literal.withUnsafeBufferPointer { literalBytes in
                    guard let prefixBase = prefixBytes.baseAddress,
                          let literalBase = literalBytes.baseAddress else {
                        return 0
                    }
                    var searchOffset = 0
                    var matchCount = 0
                    while searchOffset <= data.count - literal.count {
                        guard let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            literalBase,
                            literal.count
                        ) else {
                            return matchCount
                        }
                        let matchStart = base.distance(to: found)
                        let hasPrefix = matchStart >= prefix.count
                            && memcmp(
                                base.advanced(by: matchStart - prefix.count),
                                prefixBase,
                                prefix.count
                            ) == 0
                        if hasPrefix == prefixShouldMatch {
                            matchCount += 1
                            searchOffset = matchStart + literal.count
                        } else {
                            searchOffset = matchStart + 1
                        }
                    }
                    return matchCount
                }
            }
        }
    }

    private static func fixedLookbehindSelectedPrefixEnd(
        data: Data,
        prefix: [UInt8],
        literal: [UInt8],
        prefixShouldMatch: Bool,
        maxCount: Int
    ) -> Int? {
        guard data.count >= literal.count else {
            return 0
        }
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return prefix.withUnsafeBufferPointer { prefixBytes in
                literal.withUnsafeBufferPointer { literalBytes in
                    guard let prefixBase = prefixBytes.baseAddress,
                          let literalBase = literalBytes.baseAddress else {
                        return 0
                    }
                    var searchOffset = 0
                    var matchedLineCount = 0
                    var selectedPrefixEnd = 0
                    while matchedLineCount < maxCount,
                          searchOffset <= data.count - literal.count {
                        guard let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            literalBase,
                            literal.count
                        ) else {
                            return selectedPrefixEnd
                        }
                        let matchStart = base.distance(to: found)
                        let hasPrefix = matchStart >= prefix.count
                            && memcmp(
                                base.advanced(by: matchStart - prefix.count),
                                prefixBase,
                                prefix.count
                            ) == 0
                        if hasPrefix == prefixShouldMatch {
                            matchedLineCount += 1
                            selectedPrefixEnd = nextLineStart(
                                after: matchStart + literal.count,
                                in: base,
                                count: data.count
                            )
                            searchOffset = selectedPrefixEnd
                        } else {
                            searchOffset = matchStart + 1
                        }
                    }
                    return selectedPrefixEnd
                }
            }
        }
    }

    private static func countFixedLookaheadMatchedLines(
        path: String,
        literal: [UInt8],
        suffix: [UInt8],
        suffixShouldMatch: Bool,
        maxCount: Int?
    ) -> Int? {
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard data.count >= literal.count else {
            return 0
        }
        let limit = maxCount ?? Int.max

        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return literal.withUnsafeBufferPointer { literalBytes in
                suffix.withUnsafeBufferPointer { suffixBytes in
                    guard let literalBase = literalBytes.baseAddress,
                          let suffixBase = suffixBytes.baseAddress else {
                        return 0
                    }
                    var searchOffset = 0
                    var matchedLineCount = 0
                    while matchedLineCount < limit,
                          searchOffset <= data.count - literal.count {
                        guard let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            literalBase,
                            literal.count
                        ) else {
                            return matchedLineCount
                        }
                        let matchStart = base.distance(to: found)
                        let suffixStart = matchStart + literal.count
                        let hasSuffix = suffixStart + suffix.count <= data.count
                            && memcmp(
                                base.advanced(by: suffixStart),
                                suffixBase,
                                suffix.count
                            ) == 0
                        if hasSuffix == suffixShouldMatch {
                            matchedLineCount += 1
                            searchOffset = nextLineStart(
                                after: suffixStart,
                                in: base,
                                count: data.count
                            )
                        } else {
                            searchOffset = matchStart + 1
                        }
                    }
                    return matchedLineCount
                }
            }
        }
    }

    private static func countFixedLookaheadMatches(
        path: String,
        literal: [UInt8],
        suffix: [UInt8],
        suffixShouldMatch: Bool,
        maxCount: Int? = nil
    ) -> Int? {
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard data.count >= literal.count else {
            return 0
        }
        if let maxCount {
            guard let selectedPrefixEnd = fixedLookaheadSelectedPrefixEnd(
                data: data,
                literal: literal,
                suffix: suffix,
                suffixShouldMatch: suffixShouldMatch,
                maxCount: maxCount
            ) else {
                return nil
            }
            guard selectedPrefixEnd > 0 else {
                return 0
            }
            return countFixedLookaheadMatches(
                in: Data(data[..<selectedPrefixEnd]),
                literal: literal,
                suffix: suffix,
                suffixShouldMatch: suffixShouldMatch
            )
        }
        return countFixedLookaheadMatches(
            in: data,
            literal: literal,
            suffix: suffix,
            suffixShouldMatch: suffixShouldMatch
        )
    }

    private static func countFixedLookaheadMatches(
        in data: Data,
        literal: [UInt8],
        suffix: [UInt8],
        suffixShouldMatch: Bool
    ) -> Int? {
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return literal.withUnsafeBufferPointer { literalBytes in
                suffix.withUnsafeBufferPointer { suffixBytes in
                    guard let literalBase = literalBytes.baseAddress,
                          let suffixBase = suffixBytes.baseAddress else {
                        return 0
                    }
                    var searchOffset = 0
                    var matchCount = 0
                    while searchOffset <= data.count - literal.count {
                        guard let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            literalBase,
                            literal.count
                        ) else {
                            return matchCount
                        }
                        let matchStart = base.distance(to: found)
                        let suffixStart = matchStart + literal.count
                        let hasSuffix = suffixStart + suffix.count <= data.count
                            && memcmp(
                                base.advanced(by: suffixStart),
                                suffixBase,
                                suffix.count
                            ) == 0
                        if hasSuffix == suffixShouldMatch {
                            matchCount += 1
                            searchOffset = matchStart + literal.count
                        } else {
                            searchOffset = matchStart + 1
                        }
                    }
                    return matchCount
                }
            }
        }
    }

    private static func fixedLookaheadSelectedPrefixEnd(
        data: Data,
        literal: [UInt8],
        suffix: [UInt8],
        suffixShouldMatch: Bool,
        maxCount: Int
    ) -> Int? {
        guard data.count >= literal.count else {
            return 0
        }
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return literal.withUnsafeBufferPointer { literalBytes in
                suffix.withUnsafeBufferPointer { suffixBytes in
                    guard let literalBase = literalBytes.baseAddress,
                          let suffixBase = suffixBytes.baseAddress else {
                        return 0
                    }
                    var searchOffset = 0
                    var matchedLineCount = 0
                    var selectedPrefixEnd = 0
                    while matchedLineCount < maxCount,
                          searchOffset <= data.count - literal.count {
                        guard let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            literalBase,
                            literal.count
                        ) else {
                            return selectedPrefixEnd
                        }
                        let matchStart = base.distance(to: found)
                        let suffixStart = matchStart + literal.count
                        let hasSuffix = suffixStart + suffix.count <= data.count
                            && memcmp(
                                base.advanced(by: suffixStart),
                                suffixBase,
                                suffix.count
                            ) == 0
                        if hasSuffix == suffixShouldMatch {
                            matchedLineCount += 1
                            selectedPrefixEnd = nextLineStart(
                                after: suffixStart,
                                in: base,
                                count: data.count
                            )
                            searchOffset = selectedPrefixEnd
                        } else {
                            searchOffset = matchStart + 1
                        }
                    }
                    return selectedPrefixEnd
                }
            }
        }
    }

    private static func containsASCIICaseInsensitiveLiteral(path: String, literal: [UInt8]) -> Bool? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              literal.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return containsASCIIFoldableByte(literal) ? nil : false
        }
        return containsASCIICaseInsensitiveLiteral(data: data, literal: literal)
    }

    private static func containsAnyASCIICaseInsensitiveLiteral(
        path: String,
        literals: [[UInt8]]
    ) -> Bool? {
        guard (2...8).contains(literals.count),
              let literals = distinctASCIICaseInsensitiveLiterals(literals),
              !literals.isEmpty else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return nil
        }
        var canProveNoMatch = true
        for literal in literals {
            guard let matched = containsASCIICaseInsensitiveLiteral(data: data, literal: literal) else {
                canProveNoMatch = false
                continue
            }
            if matched {
                return true
            }
        }
        return canProveNoMatch ? false : nil
    }

    private static func asciiCaseInsensitiveLineCount(
        data: Data,
        foldedLiterals: [[UInt8]],
        maxCount: Int?
    ) -> Int {
        let limit = maxCount ?? Int.max
        let newline = UInt8(ascii: "\n")
        var lineStart = data.startIndex
        var matchedLineCount = 0
        while lineStart < data.endIndex, matchedLineCount < limit {
            let lineEnd = data[lineStart..<data.endIndex].firstIndex(of: newline) ?? data.endIndex
            if asciiCaseInsensitiveLineRangeContains(
                data: data,
                lineStart: lineStart,
                lineEnd: lineEnd,
                foldedLiterals: foldedLiterals
            ) {
                matchedLineCount += 1
            }
            if lineEnd < data.endIndex {
                lineStart = data.index(after: lineEnd)
            } else {
                lineStart = data.endIndex
            }
        }
        return matchedLineCount
    }

    private static func countASCIICaseInsensitiveMatchedLines(
        data: Data,
        foldedLiterals: [[UInt8]],
        maxCount: Int?
    ) -> Int {
        guard let minimumLiteralLength = foldedLiterals.map(\.count).min(),
              data.count >= minimumLiteralLength else {
            return 0
        }
        if foldedLiterals.count == 1,
           foldedLiterals[0].count == 1,
           !dataContainsASCIICaseInsensitiveByte(data, foldedByte: foldedLiterals[0][0]) {
            return 0
        }
        let limit = maxCount ?? Int.max
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let shifts = foldedLiterals.map { literal -> [Int] in
                var table = [Int](repeating: literal.count, count: 256)
                if literal.count > 1 {
                    for index in 0..<(literal.count - 1) {
                        table[Int(literal[index])] = literal.count - 1 - index
                    }
                }
                return table
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            var searchOffset = 0
            var matchedLineCount = 0

            while searchOffset < data.count,
                  matchedLineCount < limit {
                var bestStart = Int.max
                for literalIndex in foldedLiterals.indices {
                    let literal = foldedLiterals[literalIndex]
                    guard literal.count <= data.count - searchOffset else {
                        continue
                    }
                    let found = literal.withUnsafeBufferPointer { literalBuffer in
                        shifts[literalIndex].withUnsafeBufferPointer { shiftBuffer in
                            rg_memcasemem_ascii_prepared(
                                base.advanced(by: searchOffset),
                                data.count - searchOffset,
                                literalBuffer.baseAddress,
                                literalBuffer.count,
                                shiftBuffer.baseAddress
                            )
                        }
                    }
                    guard let found else {
                        continue
                    }
                    let matchStart = base.distance(to: found)
                    if matchStart < bestStart {
                        bestStart = matchStart
                    }
                }
                guard bestStart < data.count else {
                    break
                }
                matchedLineCount += 1
                let newline = memchr(
                    base.advanced(by: bestStart),
                    Int32(UInt8(ascii: "\n")),
                    data.count - bestStart
                )
                if let newline {
                    searchOffset = base.distance(to: newline.assumingMemoryBound(to: UInt8.self)) + 1
                } else {
                    break
                }
            }
            return matchedLineCount
        }
    }

    private static func countASCIICaseInsensitiveMatches(
        in data: Data,
        foldedLiteral: [UInt8]
    ) -> Int {
        guard !foldedLiteral.isEmpty,
              data.count >= foldedLiteral.count else {
            return 0
        }
        if foldedLiteral.count == 1 {
            return countASCIICaseInsensitiveByteMatches(in: data, foldedByte: foldedLiteral[0])
        }
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            var shifts = [Int](repeating: foldedLiteral.count, count: 256)
            if foldedLiteral.count > 1 {
                for index in 0..<(foldedLiteral.count - 1) {
                    shifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
                }
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            var searchOffset = 0
            var matchCount = 0
            while searchOffset < data.count {
                let found = foldedLiteral.withUnsafeBufferPointer { literalBuffer in
                    shifts.withUnsafeBufferPointer { shiftBuffer in
                        rg_memcasemem_ascii_prepared(
                            base.advanced(by: searchOffset),
                            data.count - searchOffset,
                            literalBuffer.baseAddress,
                            literalBuffer.count,
                            shiftBuffer.baseAddress
                        )
                    }
                }
                guard let found else {
                    break
                }
                let matchStart = base.distance(to: found)
                matchCount += 1
                searchOffset = matchStart + foldedLiteral.count
            }
            return matchCount
        }
    }

    private static func countASCIICaseInsensitiveByteMatches(
        in data: Data,
        foldedByte: UInt8
    ) -> Int {
        return data.withUnsafeBytes { rawData in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            if foldedByte >= UInt8(ascii: "a"),
               foldedByte <= UInt8(ascii: "z") {
                let upperByte = foldedByte - (UInt8(ascii: "a") - UInt8(ascii: "A"))
                return Int(rg_memcount_byte(base, data.count, foldedByte))
                    + Int(rg_memcount_byte(base, data.count, upperByte))
            }
            return Int(rg_memcount_byte(base, data.count, foldedByte))
        }
    }

    private static func countASCIICaseInsensitiveMatchesWithinFirstMatchingLines(
        data: Data,
        foldedLiteral: [UInt8],
        maxCount: Int
    ) -> Int {
        let newline = UInt8(ascii: "\n")
        var lineStart = data.startIndex
        var matchedLineCount = 0
        var selectedPrefixEnd = data.startIndex

        while matchedLineCount < maxCount,
              lineStart < data.endIndex {
            let lineEnd = data[lineStart..<data.endIndex].firstIndex(of: newline) ?? data.endIndex
            if asciiCaseInsensitiveLineRangeContains(
                data: data,
                lineStart: lineStart,
                lineEnd: lineEnd,
                foldedLiteral: foldedLiteral
            ) {
                matchedLineCount += 1
                selectedPrefixEnd = lineEnd
            }
            if lineEnd < data.endIndex {
                lineStart = data.index(after: lineEnd)
            } else {
                lineStart = data.endIndex
            }
        }

        guard matchedLineCount > 0 else {
            return 0
        }
        return countASCIICaseInsensitiveMatches(
            in: Data(data[..<selectedPrefixEnd]),
            foldedLiteral: foldedLiteral
        )
    }

    private static func asciiCaseInsensitiveLineRangeContains(
        data: Data,
        lineStart: Data.Index,
        lineEnd: Data.Index,
        foldedLiterals: [[UInt8]]
    ) -> Bool {
        let lineLength = data.distance(from: lineStart, to: lineEnd)
        guard lineLength > 0 else {
            return false
        }
        for literal in foldedLiterals where literal.count <= lineLength {
            if asciiCaseInsensitiveLineRangeContains(
                data: data,
                lineStart: lineStart,
                lineEnd: lineEnd,
                foldedLiteral: literal
            ) {
                return true
            }
        }
        return false
    }

    private static func asciiCaseInsensitiveLineRangeContains(
        data: Data,
        lineStart: Data.Index,
        lineEnd: Data.Index,
        foldedLiteral: [UInt8]
    ) -> Bool {
        var candidateStart = lineStart
        while data.distance(from: candidateStart, to: lineEnd) >= foldedLiteral.count {
            var cursor = candidateStart
            var matched = true
            for byte in foldedLiteral {
                if rgSwiftASCIILower(data[cursor]) != byte {
                    matched = false
                    break
                }
                cursor = data.index(after: cursor)
            }
            if matched {
                return true
            }
            candidateStart = data.index(after: candidateStart)
        }
        return false
    }

    private static func containsASCIICaseInsensitiveLiteral(data: Data, literal: [UInt8]) -> Bool? {
        guard containsASCIIFoldableByte(literal) else {
            return dataContainsLiteralUsingSIMD(data, literal: literal)
        }
        let foldedLiteral = literal.map(rgSwiftASCIILower)
        if dataContainsASCIICaseInsensitiveLiteral(data, foldedLiteral: foldedLiteral) {
            return true
        }
        return containsNonASCIIByte(data) ? nil : false
    }

    private static func containsASCIICaseInsensitiveExactLine(path: String, literal: [UInt8]) -> Bool? {
        asciiCaseInsensitiveExactLineMatched(path: path, literals: [literal])
    }

    private static func asciiCaseInsensitiveExactLineMatched(path: String, literals: [[UInt8]]) -> Bool? {
        guard let literals = distinctASCIICaseInsensitiveExactLineLiterals(literals),
              !literals.isEmpty else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return false
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        if literals.count > 1,
           !dataContainsAnyASCIICaseInsensitiveLiteral(data, foldedLiterals: literals) {
            return containsNonASCIIByte(data) ? nil : false
        }
        if asciiCaseInsensitiveExactLineCount(data: data, foldedLiterals: literals, maxCount: 1) > 0 {
            return true
        }
        return containsNonASCIIByte(data) ? nil : false
    }

    private static func containsASCIIFoldableByte(_ literal: [UInt8]) -> Bool {
        literal.contains {
            ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z"))
                || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
        }
    }

    private static func containsAnyLiteral(path: String, literals: [[UInt8]]) -> Bool? {
        guard (2...8).contains(literals.count),
              literals.allSatisfy({
                !$0.isEmpty && !$0.contains(UInt8(ascii: "\n"))
              }) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return false
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        return dataContainsAnyLiteral(data, literals: literals)
    }

    private static func containsAnyLiteralUsingSIMD(path: String, literals: [[UInt8]]) -> Bool? {
        guard (2...8).contains(literals.count),
              literals.allSatisfy({
                !$0.isEmpty && !$0.contains(UInt8(ascii: "\n"))
              }) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return false
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        return dataContainsAnyLiteral(data, literals: literals)
    }

    private static func containsExactLine(path: String, literal: [UInt8]) -> Bool? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return false
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        return exactLineCount(data: data, literal: literal, maxCount: 1) > 0
    }

    private static func containsAnyExactLine(path: String, literals: [[UInt8]]) -> Bool? {
        guard let literals = distinctExactLineLiterals(literals),
              !literals.isEmpty else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return false
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        return multiLiteralExactLineCount(data: data, literals: literals, maxCount: 1) > 0
    }

    private static func containsWordLiteral(path: String, literal: [UInt8]) -> Bool? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              let first = literal.first,
              let last = literal.last,
              rgSwiftIsASCIIRegexWordByte(first),
              rgSwiftIsASCIIRegexWordByte(last) else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return false
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        guard dataContainsLiteralUsingSIMD(data, literal: literal) else {
            return false
        }

        return countASCIIWordMatchedLines(in: data, literal: literal, maxCount: 1).map { $0 > 0 }
    }

    private static func containsAnyWordLiteral(path: String, literals: [[UInt8]]) -> Bool? {
        guard let literals = distinctASCIIWordLiterals(literals),
              !literals.isEmpty,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return false
        }
        guard !hasBinaryDetectionPrefix(data) else {
            return nil
        }
        guard dataContainsAnyLiteral(data, literals: literals) else {
            return false
        }

        return countASCIIWordMatchedLines(in: data, literals: literals, maxCount: 1).map { $0 > 0 }
    }

    private static func containsAnyASCIICaseInsensitiveWordLiteral(
        path: String,
        literals: [[UInt8]]
    ) -> Bool? {
        guard let literals = distinctASCIICaseInsensitiveWordLiterals(literals),
              !literals.isEmpty,
              let data = mappedPreflightData(path: path) else {
            return nil
        }
        guard !data.isEmpty else {
            return false
        }
        guard !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }

        return countASCIIWordMatchedLines(
            in: data,
            literals: literals,
            maxCount: 1,
            asciiCaseInsensitive: true
        ).map { $0 > 0 }
    }

    private static func isASCIIWordBoundaryMatch(
        data: Data,
        matchRange: Range<Data.Index>
    ) -> Bool? {
        if matchRange.lowerBound > data.startIndex {
            let before = data[data.index(before: matchRange.lowerBound)]
            if before >= 0x80 {
                return nil
            }
            if rgSwiftIsASCIIRegexWordByte(before) {
                return false
            }
        }
        if matchRange.upperBound < data.endIndex {
            let after = data[matchRange.upperBound]
            if after >= 0x80 {
                return nil
            }
            if rgSwiftIsASCIIRegexWordByte(after) {
                return false
            }
        }
        return true
    }

    private static func isASCIIWordBoundaryMatch(
        base: UnsafePointer<UInt8>,
        dataCount: Int,
        matchStart: Int,
        matchEnd: Int
    ) -> Bool? {
        if matchStart > 0 {
            let before = base[matchStart - 1]
            if before >= 0x80 {
                return nil
            }
            if rgSwiftIsASCIIRegexWordByte(before) {
                return false
            }
        }
        if matchEnd < dataCount {
            let after = base[matchEnd]
            if after >= 0x80 {
                return nil
            }
            if rgSwiftIsASCIIRegexWordByte(after) {
                return false
            }
        }
        return true
    }

    private static func mappedPreflightData(path: String) -> Data? {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        } catch {
            return nil
        }
        if data.count >= 3,
           data[data.startIndex] == 0xEF,
           data[data.index(after: data.startIndex)] == 0xBB,
           data[data.index(data.startIndex, offsetBy: 2)] == 0xBF {
            return nil
        }
        if data.count >= 2 {
            let second = data[data.index(after: data.startIndex)]
            if data[data.startIndex] == 0xFF && second == 0xFE
                || data[data.startIndex] == 0xFE && second == 0xFF {
                return nil
            }
        }
        return data
    }

    public static func fileCanUseUTF8LinePreflight(path: String) -> Bool {
        guard let data = mappedPreflightData(path: path) else {
            return false
        }
        return String(data: data, encoding: .utf8) != nil
    }

    public static func fileCanUseASCIILinePreflight(path: String) -> Bool {
        guard let data = mappedPreflightData(path: path) else {
            return false
        }
        return !containsNonASCIIByte(data)
    }

    private static func literalLineMatchCount(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        lineNumber: Bool = false,
        asciiBoundary: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = [],
        emitLines: Bool,
        maxCount: Int = Int.max,
        requireASCIIHaystack: Bool = false,
        knownTextHaystack: Bool = false
    ) -> Int? {
        guard !literal.isEmpty,
              maxCount > 0 else {
            return nil
        }
        if asciiCaseInsensitive, literal.contains(where: { $0 >= 0x80 }) {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 0
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }
        let base = UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self)
        if asciiCaseInsensitive,
           asciiBoundary,
           !emitLines,
           literal.count == 1,
           rgSwiftDarwinFindASCIICaseInsensitiveByte(
            base,
            haystackLength: haystackLength,
            foldedByte: rgSwiftASCIILower(literal[0])
           ) == nil {
            return 0
        }

        let stats = literal.withUnsafeBufferPointer { literalBuffer in
            rgSwiftDarwinWriteLiteralBytes(
                base,
                haystackLength: haystackLength,
                literal: literalBuffer,
                asciiCaseInsensitive: asciiCaseInsensitive,
                lineNumber: lineNumber,
                asciiBoundary: asciiBoundary,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix,
                emitLines: emitLines,
                maxCount: maxCount,
                requireASCIIHaystack: requireASCIIHaystack,
                knownTextHaystack: knownTextHaystack
            )
        }
        return stats?.matchedLines
    }

    private static func literalLineWriteStats(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        lineNumber: Bool = false,
        asciiBoundary: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> LiteralLineWriteStats? {
        guard !literal.isEmpty else {
            return nil
        }
        if asciiCaseInsensitive, literal.contains(where: { $0 >= 0x80 }) {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return LiteralLineWriteStats(matchedLines: 0, bytesPrinted: 0, bytesSearched: 0)
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        return literal.withUnsafeBufferPointer { literalBuffer in
            rgSwiftDarwinWriteLiteralBytes(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                asciiCaseInsensitive: asciiCaseInsensitive,
                lineNumber: lineNumber,
                asciiBoundary: asciiBoundary,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }
    }

    public static func exitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        lineNumber: Bool = false,
        asciiBoundary: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard let stats = literalLineWriteStats(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            lineNumber: lineNumber,
            asciiBoundary: asciiBoundary,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix
        ) else {
            return nil
        }
        return stats.matchedLines > 0 ? 0 : 1
    }

    public static func literalLineStatsExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        wordRegexp: Bool,
        lineNumber: Bool = false,
        asciiBoundary: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !asciiBoundary,
              let stats = matchedSummaryStats(
                path: path,
                literal: literal,
                asciiCaseInsensitive: asciiCaseInsensitive,
                wordRegexp: wordRegexp
              ), stats.matchedLines > 0 else {
            return nil
        }
        guard let lineStats = literalLineWriteStats(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            lineNumber: lineNumber,
            asciiBoundary: false,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix
        ), lineStats.matchedLines == stats.matchedLines else {
            return nil
        }
        guard fflush(Darwin.stdout) == 0 else {
            return nil
        }
        return writeStatsSummary(
            totalMatches: stats.totalMatches,
            matchedLines: stats.matchedLines,
            filesWithMatches: 1,
            filesSearched: 1,
            bytesPrinted: lineStats.bytesPrinted,
            bytesSearched: stats.bytesSearched,
            exitCode: 0
        )
    }

    public static func asciiCaseInsensitiveUTF8LineExitCode(
        path: String,
        literal: [UInt8],
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literal.isEmpty,
              literal.allSatisfy({ $0 < 0x80 }),
              let matchedLineCount = literalLineMatchCount(
                path: path,
                literal: literal,
                asciiCaseInsensitive: true,
                lineNumber: lineNumber,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix,
                emitLines: true,
                requireASCIIHaystack: true
              ) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func streamingExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")) else {
            return nil
        }
        if asciiCaseInsensitive, literal.contains(where: { $0 >= 0x80 }) {
            return nil
        }
        return streamingLiteralExitCode(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            lineNumber: lineNumber,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix
        )
    }

    private static func isSafeASCIIWordLiteral(_ literal: [UInt8]) -> Bool {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              literal.allSatisfy({ $0 < 0x80 }),
              let first = literal.first,
              let last = literal.last else {
            return false
        }
        return rgSwiftIsASCIIRegexWordByte(first) && rgSwiftIsASCIIRegexWordByte(last)
    }

    public static func asciiCaseInsensitiveWordQuietExitCode(
        path: String,
        literal: [UInt8]
    ) -> Int32? {
        guard isSafeASCIIWordLiteral(literal),
              let matched = asciiCaseInsensitiveWordMatched(
                path: path,
                literal: literal
              ) else {
            return nil
        }
        return matched ? 0 : 1
    }

    public static func asciiCaseInsensitiveWordPathOnlyExitCode(
        path: String,
        literal: [UInt8],
        printWhenMatched: Bool,
        nullTerminated: Bool,
        crlfTerminated: Bool = false,
        outputPath: [UInt8]? = nil
    ) -> Int32? {
        guard isSafeASCIIWordLiteral(literal),
              let matched = asciiCaseInsensitiveWordMatched(
                path: path,
                literal: literal
              ) else {
            return nil
        }
        guard matched == printWhenMatched else {
            return 1
        }
        guard writePathOnlyOutput(
            path: path,
            outputPath: outputPath,
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        ) else {
            return nil
        }
        return 0
    }

    public static func asciiCaseInsensitiveWordCountLineExitCode(
        path: String,
        literal: [UInt8],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard isSafeASCIIWordLiteral(literal),
              maxCount.map({ $0 > 0 }) ?? true,
              let matchedLineCount = literalLineMatchCount(
                path: path,
                literal: literal,
                asciiCaseInsensitive: true,
                asciiBoundary: true,
                emitLines: false,
                maxCount: maxCount ?? Int.max,
                requireASCIIHaystack: true
              ) else {
            return nil
        }

        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveWordCountMatchesExitCode(
        path: String,
        literal: [UInt8],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard isSafeASCIIWordLiteral(literal),
              maxCount.map({ $0 > 0 }) ?? true,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }
        let matchCount: Int
        if let maxCount {
            guard let boundedMatchCount = countASCIICaseInsensitiveWordMatchesWithinFirstMatchingLines(
                data: data,
                literal: literal,
                maxCount: maxCount
            ) else {
                return nil
            }
            matchCount = boundedMatchCount
        } else {
            guard let totalMatchCount = countASCIIWordMatches(
                in: data,
                literal: literal,
                asciiCaseInsensitive: true
            ) else {
                return nil
            }
            matchCount = totalMatchCount
        }

        if matchCount > 0 || includeZero {
            guard writeCountOutput(
                matchCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchCount > 0 ? 0 : 1
    }

    private static func countASCIICaseInsensitiveWordMatchesWithinFirstMatchingLines(
        data: Data,
        literal: [UInt8],
        maxCount: Int
    ) -> Int? {
        countASCIIWordMatchesWithinFirstMatchingLines(
            data: data,
            literal: literal,
            maxCount: maxCount,
            asciiCaseInsensitive: true
        )
    }

    public static func asciiCaseInsensitiveWordLineExitCode(
        path: String,
        literal: [UInt8],
        lineNumber: Bool,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard isSafeASCIIWordLiteral(literal),
              let matchedLineCount = literalLineMatchCount(
                path: path,
                literal: literal,
                asciiCaseInsensitive: true,
                lineNumber: lineNumber,
                asciiBoundary: true,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix,
                emitLines: true,
                requireASCIIHaystack: true
              ) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveWordOnlyMatchingExitCode(
        path: String,
        literal: [UInt8],
        lineNumber: Bool,
        byteOffset: Bool = false,
        column: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        asciiWordOnlyMatchingExitCode(
            path: path,
            literal: literal,
            lineNumber: lineNumber,
            byteOffset: byteOffset,
            column: column,
            maxCount: maxCount,
            asciiCaseInsensitive: true,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix
        )
    }

    public static func wordOnlyMatchingExitCode(
        path: String,
        literal: [UInt8],
        lineNumber: Bool,
        byteOffset: Bool = false,
        column: Bool = false,
        maxCount: Int? = nil,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        asciiWordOnlyMatchingExitCode(
            path: path,
            literal: literal,
            lineNumber: lineNumber,
            byteOffset: byteOffset,
            column: column,
            maxCount: maxCount,
            asciiCaseInsensitive: false,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix
        )
    }

    private static func asciiWordOnlyMatchingExitCode(
        path: String,
        literal: [UInt8],
        lineNumber: Bool,
        byteOffset: Bool,
        column: Bool,
        maxCount: Int?,
        asciiCaseInsensitive: Bool,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int32? {
        guard isSafeASCIIWordLiteral(literal),
              maxCount.map({ $0 > 0 }) ?? true else {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWriteASCIICaseInsensitiveWordOnlyMatches(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                asciiCaseInsensitive: asciiCaseInsensitive,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                column: column,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }) else {
            return nil
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func wordLineNumberExitCode(
        path: String,
        literal: [UInt8]
    ) -> Int32? {
        wordLineExitCode(path: path, literal: literal, lineNumber: true)
    }

    public static func wordLineExitCode(
        path: String,
        literal: [UInt8],
        lineNumber: Bool,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              let first = literal.first,
              let last = literal.last,
              rgSwiftIsASCIIRegexWordByte(first),
              rgSwiftIsASCIIRegexWordByte(last) else {
            return nil
        }
        if let matchedLineCount = literalLineMatchCount(
            path: path,
            literal: literal,
            asciiCaseInsensitive: false,
            lineNumber: lineNumber,
            asciiBoundary: true,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix,
            emitLines: true,
            requireASCIIHaystack: true
        ) {
            return matchedLineCount > 0 ? 0 : 1
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWriteWordLiteralLineBytes(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                lineNumber: lineNumber,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func surroundingWordsExitCode(
        path: String,
        literal: [UInt8],
        lineNumber: Bool,
        asciiOnly: Bool,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              literal.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWriteSurroundingWordsBytes(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                lineNumber: lineNumber,
                asciiOnly: asciiOnly,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func multiLiteralExitCode(
        path: String,
        literals: [[UInt8]],
        maxCount: Int? = nil,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard let result = multiLiteralResult(
            path: path,
            literals: literals,
            maxCount: maxCount,
            lineNumber: lineNumber,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix
        ) else {
            return nil
        }
        guard result.status >= 0 else {
            return nil
        }
        return result.matched_line_count > 0 ? 0 : 1
    }

    public static func multiLiteralCountLineExitCode(
        path: String,
        literals: [[UInt8]],
        includeZero: Bool,
        maxCount: Int?,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard maxCount != 0,
              let result = multiLiteralResult(
                path: path,
                literals: literals,
                maxCount: maxCount,
                emitLines: false
              ) else {
            return nil
        }
        guard result.status >= 0 else {
            return nil
        }
        let matchedLineCount = Int(result.matched_line_count)
        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(
                matchedLineCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    private static func streamingLiteralExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool,
        lineNumber: Bool,
        lineNumberFieldSeparator: [UInt8],
        linePrefix: [UInt8],
        headingPrefix: [UInt8]
    ) -> Int32? {
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            return nil
        }
        defer {
            try? handle.close()
        }
        while true {
            let chunk = handle.readData(ofLength: 2 * 1024 * 1024)
            guard !chunk.isEmpty else {
                break
            }
            let containsNUL = chunk.withUnsafeBytes { rawChunk -> Bool in
                guard let rawBase = rawChunk.baseAddress else {
                    return false
                }
                return memchr(rawBase, 0, rawChunk.count) != nil
            }
            guard !containsNUL else {
                return nil
            }
        }
        guard Darwin.lseek(handle.fileDescriptor, 0, SEEK_SET) >= 0 else {
            return nil
        }

        var matchedLineCount = 0
        var carry = Data()
        var isFirstChunk = true
        var rejected = false
        var writeFailed = false
        var emittedHeading = false
        var currentLineNumber = 1
        let newlineByte = UInt8(ascii: "\n")
        let foldedLiteral = asciiCaseInsensitive ? literal.map(rgSwiftASCIILower) : []
        var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
        if asciiCaseInsensitive, foldedLiteral.count > 1 {
            for index in 0..<(foldedLiteral.count - 1) {
                caseInsensitiveShifts[Int(foldedLiteral[index])] = literal.count - 1 - index
            }
        }

        func appendCarry(_ bytes: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else {
                return
            }
            guard carry.count + count <= HaystackReader.defaultMaxBufferBytes else {
                rejected = true
                return
            }
            carry.append(contentsOf: UnsafeBufferPointer(start: bytes, count: count))
        }

        func lastNewlineOffset(before endOffset: Int, in base: UnsafePointer<UInt8>) -> Int? {
            guard endOffset > 0 else {
                return nil
            }
            var offset = endOffset - 1
            while offset >= 0 {
                if base[offset] == newlineByte {
                    return offset
                }
                if offset == 0 {
                    break
                }
                offset -= 1
            }
            return nil
        }

        func validateChunk(_ base: UnsafePointer<UInt8>, count: Int) -> Bool {
            if isFirstChunk {
                isFirstChunk = false
                if count >= 3,
                   base[0] == 0xEF,
                   base[1] == 0xBB,
                   base[2] == 0xBF {
                    rejected = true
                    return false
                }
                if count >= 2,
                   (base[0] == 0xFF && base[1] == 0xFE
                    || base[0] == 0xFE && base[1] == 0xFF) {
                    rejected = true
                    return false
                }
            }
            return true
        }

        func findLiteral(
            in base: UnsafePointer<UInt8>,
            from searchOffset: Int,
            count: Int
        ) -> UnsafePointer<UInt8>? {
            let remainingCount = count - searchOffset
            guard remainingCount >= literal.count else {
                return nil
            }
            if asciiCaseInsensitive {
                return foldedLiteral.withUnsafeBufferPointer { foldedNeedle in
                    caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                        rg_memcasemem_ascii_prepared(
                            base.advanced(by: searchOffset),
                            remainingCount,
                            foldedNeedle.baseAddress,
                            foldedNeedle.count,
                            shifts.baseAddress
                        )
                    }
                }
            }
            return literal.withUnsafeBufferPointer { needle in
                rg_memmem_simple(
                    base.advanced(by: searchOffset),
                    remainingCount,
                    needle.baseAddress,
                    needle.count
                )
            }
        }

        func emitMatches(
            in base: UnsafePointer<UInt8>,
            count: Int,
            allowUnterminatedFinalLine: Bool
        ) -> (lineNumber: Int, countedOffset: Int) {
            guard !writeFailed else {
                return (currentLineNumber, 0)
            }
            var lineNumberCursor = currentLineNumber
            var lineCountOffset = 0
            var searchOffset = 0
            var lastEmittedLineStart = -1
            while searchOffset < count {
                guard let found = findLiteral(in: base, from: searchOffset, count: count) else {
                    return (lineNumberCursor, lineCountOffset)
                }
                let matchStart = base.distance(to: found)
                var lineStart = matchStart
                while lineStart > 0, base[lineStart - 1] != newlineByte {
                    lineStart -= 1
                }
                if lineStart == lastEmittedLineStart {
                    searchOffset = matchStart + literal.count
                    continue
                }

                let newline = memchr(found, Int32(newlineByte), count - matchStart)
                let outputEnd: Int
                let hasNewline: Bool
                if let newline {
                    outputEnd = base.distance(to: newline.assumingMemoryBound(to: UInt8.self)) + 1
                    hasNewline = true
                } else if allowUnterminatedFinalLine {
                    outputEnd = count
                    hasNewline = false
                } else {
                    return (lineNumberCursor, lineCountOffset)
                }

                if lineNumber {
                    lineNumberCursor += Int(rg_memcount_byte(
                        base.advanced(by: lineCountOffset),
                        lineStart - lineCountOffset,
                        newlineByte
                    ))
                    lineCountOffset = lineStart
                    guard output.writeHeadingPrefix(
                        headingPrefix,
                        emittedHeading: &emittedHeading
                    ) else {
                        writeFailed = true
                        return (lineNumberCursor, lineCountOffset)
                    }
                    guard output.writeBytes(linePrefix) else {
                        writeFailed = true
                        return (lineNumberCursor, lineCountOffset)
                    }
                    guard output.writeLineNumberPrefix(
                        lineNumberCursor,
                        fieldSeparator: lineNumberFieldSeparator
                    ) else {
                        writeFailed = true
                        return (lineNumberCursor, lineCountOffset)
                    }
                } else {
                    guard output.writeHeadingPrefix(
                        headingPrefix,
                        emittedHeading: &emittedHeading
                    ) else {
                        writeFailed = true
                        return (lineNumberCursor, lineCountOffset)
                    }
                    guard output.writeBytes(linePrefix) else {
                        writeFailed = true
                        return (lineNumberCursor, lineCountOffset)
                    }
                }
                guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
                    writeFailed = true
                    return (lineNumberCursor, lineCountOffset)
                }
                if !hasNewline, !output.writeByte(newlineByte) {
                    writeFailed = true
                    return (lineNumberCursor, lineCountOffset)
                }
                matchedLineCount += 1
                lastEmittedLineStart = lineStart
                searchOffset = outputEnd
            }
            return (lineNumberCursor, lineCountOffset)
        }

        func processBuffer(_ base: UnsafePointer<UInt8>, count: Int) -> Data? {
            guard let lastNewline = lastNewlineOffset(before: count, in: base) else {
                guard count <= HaystackReader.defaultMaxBufferBytes else {
                    rejected = true
                    return nil
                }
                return Data(bytes: base, count: count)
            }

            let completeCount = lastNewline + 1
            let emittedLineState = emitMatches(in: base, count: completeCount, allowUnterminatedFinalLine: false)
            if lineNumber {
                currentLineNumber = emittedLineState.lineNumber + Int(rg_memcount_byte(
                    base.advanced(by: emittedLineState.countedOffset),
                    completeCount - emittedLineState.countedOffset,
                    newlineByte
                ))
            }
            let tailCount = count - completeCount
            return tailCount > 0
                ? Data(bytes: base.advanced(by: completeCount), count: tailCount)
                : Data()
        }

        while !rejected, !writeFailed {
            let chunk = handle.readData(ofLength: 2 * 1024 * 1024)
            guard !chunk.isEmpty else {
                break
            }

            chunk.withUnsafeBytes { rawChunk in
                guard let rawBase = rawChunk.baseAddress else {
                    return
                }
                let base = rawBase.assumingMemoryBound(to: UInt8.self)
                guard validateChunk(base, count: rawChunk.count) else {
                    return
                }

                if carry.isEmpty {
                    carry = processBuffer(base, count: rawChunk.count) ?? Data()
                } else {
                    appendCarry(base, count: rawChunk.count)
                    guard !rejected else {
                        return
                    }
                    let nextCarry = carry.withUnsafeBytes { rawCarry -> Data in
                        guard let rawCarryBase = rawCarry.baseAddress else {
                            return Data()
                        }
                        let carryBase = rawCarryBase.assumingMemoryBound(to: UInt8.self)
                        return processBuffer(carryBase, count: rawCarry.count) ?? Data()
                    }
                    carry = nextCarry
                }
            }
        }

        guard !rejected else {
            return nil
        }
        if !carry.isEmpty {
            carry.withUnsafeBytes { rawCarry in
                guard let rawBase = rawCarry.baseAddress else {
                    return
                }
                _ = emitMatches(
                    in: rawBase.assumingMemoryBound(to: UInt8.self),
                    count: rawCarry.count,
                    allowUnterminatedFinalLine: true
                )
            }
        }
        guard !writeFailed, output.flush() else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func countMatchesExitCode(
        path: String,
        literal: [UInt8],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              maxCount.map({ $0 > 0 }) ?? true else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }

        let matchCount = if let maxCount {
            countNonOverlappingMatchesWithinFirstMatchingLines(
                inFirstMatchingLinesOf: data,
                literal: literal,
                maxCount: maxCount
            )
        } else {
            countNonOverlappingMatches(in: data, literal: literal)
        }

        if matchCount > 0 || includeZero {
            guard writeCountOutput(
                matchCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchCount > 0 ? 0 : 1
    }

    private static func countNonOverlappingMatchesWithinFirstMatchingLines(
        inFirstMatchingLinesOf data: Data,
        literal: [UInt8],
        maxCount: Int
    ) -> Int {
        guard maxCount > 0,
              !literal.isEmpty,
              data.count >= literal.count else {
            return 0
        }
        return data.withUnsafeBytes { rawData -> Int in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return literal.withUnsafeBufferPointer { literalBuffer -> Int in
                guard let literalBase = literalBuffer.baseAddress else {
                    return 0
                }

                var searchOffset = 0
                var matchedLineCount = 0
                var matchCount = 0
                var selectedLineEnd = -1

                while searchOffset <= data.count - literal.count,
                      let found = rg_memmem_simple(
                        base.advanced(by: searchOffset),
                        data.count - searchOffset,
                        literalBase,
                        literal.count
                      ) {
                    let matchStart = base.distance(to: found)
                    if matchStart >= selectedLineEnd {
                        guard matchedLineCount < maxCount else {
                            break
                        }
                        matchedLineCount += 1
                        selectedLineEnd = rgSwiftDarwinNextLineStart(
                            base: base,
                            haystackLength: data.count,
                            from: matchStart + literal.count
                        )
                    }
                    matchCount += 1
                    searchOffset = matchStart + literal.count
                }

                return matchCount
            }
        }
    }

    private static func countASCIIWordMatchesWithinFirstMatchingLines(
        data: Data,
        literal: [UInt8],
        maxCount: Int,
        asciiCaseInsensitive: Bool = false
    ) -> Int? {
        guard maxCount > 0,
              !literal.isEmpty,
              data.count >= literal.count else {
            return 0
        }
        let searchLiteral = asciiCaseInsensitive ? literal.map(rgSwiftASCIILower) : literal
        var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
        if asciiCaseInsensitive, searchLiteral.count > 1 {
            for index in 0..<(searchLiteral.count - 1) {
                caseInsensitiveShifts[Int(searchLiteral[index])] = searchLiteral.count - 1 - index
            }
        }

        return data.withUnsafeBytes { rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            return searchLiteral.withUnsafeBufferPointer { needle -> Int? in
                guard let needleBase = needle.baseAddress else {
                    return 0
                }

                func countWithPreparedSearch(_ shifts: UnsafePointer<Int>?) -> Int? {
                    var searchOffset = 0
                    var matchedLineCount = 0
                    var matchCount = 0
                    var selectedLineEnd = -1

                    while searchOffset <= data.count - literal.count {
                        let found = if asciiCaseInsensitive {
                            rg_memcasemem_ascii_prepared(
                                base.advanced(by: searchOffset),
                                data.count - searchOffset,
                                needleBase,
                                needle.count,
                                shifts
                            )
                        } else {
                            rg_memmem_simple(
                                base.advanced(by: searchOffset),
                                data.count - searchOffset,
                                needleBase,
                                needle.count
                            )
                        }
                        guard let found else {
                            break
                        }

                        let matchStart = base.distance(to: found)
                        let matchEnd = matchStart + literal.count
                        guard let bounded = isASCIIWordBoundaryMatch(
                            base: base,
                            dataCount: data.count,
                            matchStart: matchStart,
                            matchEnd: matchEnd
                        ) else {
                            return nil
                        }
                        if bounded {
                            if matchStart >= selectedLineEnd {
                                guard matchedLineCount < maxCount else {
                                    break
                                }
                                matchedLineCount += 1
                                selectedLineEnd = rgSwiftDarwinNextLineStart(
                                    base: base,
                                    haystackLength: data.count,
                                    from: matchEnd
                                )
                            }
                            matchCount += 1
                            searchOffset = matchEnd
                        } else {
                            searchOffset = rgSwiftNextASCIIWordSearchOffset(
                                base: base,
                                dataCount: data.count,
                                matchEnd: matchEnd
                            )
                        }
                    }

                    return matchCount
                }

                if asciiCaseInsensitive {
                    return caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                        countWithPreparedSearch(shifts.baseAddress)
                    }
                }
                return countWithPreparedSearch(nil)
            }
        }
    }

    public static func wordCountMatchesExitCode(
        path: String,
        literal: [UInt8],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              let first = literal.first,
              let last = literal.last,
              rgSwiftIsASCIIRegexWordByte(first),
              rgSwiftIsASCIIRegexWordByte(last),
              maxCount.map({ $0 > 0 }) ?? true else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }
        let matchCount: Int
        if let maxCount {
            guard let boundedMatchCount = countASCIIWordMatchesWithinFirstMatchingLines(
                data: data,
                literal: literal,
                maxCount: maxCount
            ) else {
                return nil
            }
            matchCount = boundedMatchCount
        } else {
            guard let totalMatchCount = countASCIIWordMatches(in: data, literal: literal) else {
                return nil
            }
            matchCount = totalMatchCount
        }

        if matchCount > 0 || includeZero {
            guard writeCountOutput(
                matchCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func multiLiteralWordCountMatchesExitCode(
        path: String,
        literals: [[UInt8]],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard let literals = nonOverlappingDistinctLiterals(literals),
              distinctASCIIWordLiterals(literals) != nil,
              !literals.isEmpty,
              maxCount.map({ $0 > 0 }) ?? true else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }

        let matchCount: Int
        if let maxCount {
            guard let boundedMatchCount = countMultiLiteralWordMatchesWithinFirstMatchingLines(
                data: data,
                literals: literals,
                maxCount: maxCount
            ) else {
                return nil
            }
            matchCount = boundedMatchCount
        } else {
            guard let totalMatchCount = countNonOverlappingMultiLiteralWordMatches(
                in: data,
                literals: literals
            ) else {
                return nil
            }
            matchCount = totalMatchCount
        }

        if matchCount > 0 || includeZero {
            guard writeCountOutput(
                matchCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func asciiCaseInsensitiveMultiLiteralWordCountMatchesExitCode(
        path: String,
        literals: [[UInt8]],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard let literals = nonOverlappingDistinctASCIICaseInsensitiveWordLiterals(literals),
              !literals.isEmpty,
              maxCount.map({ $0 > 0 }) ?? true,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              !containsNonASCIIByte(data) else {
            return nil
        }

        let matchCount: Int
        if let maxCount {
            guard let boundedMatchCount = countMultiLiteralWordMatchesWithinFirstMatchingLines(
                data: data,
                literals: literals,
                maxCount: maxCount,
                asciiCaseInsensitive: true
            ) else {
                return nil
            }
            matchCount = boundedMatchCount
        } else {
            guard let totalMatchCount = countNonOverlappingMultiLiteralWordMatches(
                in: data,
                literals: literals,
                asciiCaseInsensitive: true
            ) else {
                return nil
            }
            matchCount = totalMatchCount
        }

        if matchCount > 0 || includeZero {
            guard writeCountOutput(
                matchCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchCount > 0 ? 0 : 1
    }

    private static func countMultiLiteralWordMatchesWithinFirstMatchingLines(
        data: Data,
        literals: [[UInt8]],
        maxCount: Int,
        asciiCaseInsensitive: Bool = false
    ) -> Int? {
        guard maxCount > 0,
              !literals.isEmpty,
              !data.isEmpty else {
            return 0
        }
        let searchLiterals = asciiCaseInsensitive
            ? literals.map { $0.map(rgSwiftASCIILower) }
            : literals
        let caseInsensitiveShifts = searchLiterals.map { literal in
            var table = [Int](repeating: literal.count, count: 256)
            if asciiCaseInsensitive, literal.count > 1 {
                for index in 0..<(literal.count - 1) {
                    table[Int(literal[index])] = literal.count - 1 - index
                }
            }
            return table
        }

        return data.withUnsafeBytes { rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)

            func nextCandidate(literalIndex: Int, from offset: Int) -> (start: Int, literalIndex: Int) {
                let literal = searchLiterals[literalIndex]
                let safeOffset = min(offset, data.count)
                guard !literal.isEmpty,
                      literal.count <= data.count - safeOffset else {
                    return (Int.max, literalIndex)
                }
                let found = literal.withUnsafeBufferPointer { literalBuffer in
                    if asciiCaseInsensitive {
                        return caseInsensitiveShifts[literalIndex].withUnsafeBufferPointer { shifts in
                            rg_memcasemem_ascii_prepared(
                                base.advanced(by: safeOffset),
                                data.count - safeOffset,
                                literalBuffer.baseAddress,
                                literal.count,
                                shifts.baseAddress
                            )
                        }
                    }
                    return rg_memmem_simple(
                        base.advanced(by: safeOffset),
                        data.count - safeOffset,
                        literalBuffer.baseAddress,
                        literal.count
                    )
                }
                guard let found else {
                    return (Int.max, literalIndex)
                }
                return (base.distance(to: found), literalIndex)
            }

            func earliestCandidateIndex(in candidates: [(start: Int, literalIndex: Int)]) -> Int? {
                var selectedIndex: Int?
                var selectedStart = Int.max
                for index in candidates.indices where candidates[index].start < selectedStart {
                    selectedStart = candidates[index].start
                    selectedIndex = index
                }
                return selectedStart == Int.max ? nil : selectedIndex
            }

            var candidates = literals.indices.map {
                nextCandidate(literalIndex: $0, from: 0)
            }
            var matchedLineCount = 0
            var matchCount = 0
            var selectedLineEnd = -1
            var rejectedBoundaryCandidates = 0
            let maxRejectedBoundaryCandidates = max(128, literals.count * 128)

            while let candidateIndex = earliestCandidateIndex(in: candidates) {
                let matchStart = candidates[candidateIndex].start
                let literalIndex = candidates[candidateIndex].literalIndex
                let literalCount = literals[literalIndex].count
                guard matchStart < data.count else {
                    break
                }
                let matchEnd = matchStart + literalCount
                guard let bounded = isASCIIWordBoundaryMatch(
                    base: base,
                    dataCount: data.count,
                    matchStart: matchStart,
                    matchEnd: matchEnd
                ) else {
                    return nil
                }
                if bounded {
                    if matchStart >= selectedLineEnd {
                        guard matchedLineCount < maxCount else {
                            break
                        }
                        matchedLineCount += 1
                        selectedLineEnd = rgSwiftDarwinNextLineStart(
                            base: base,
                            haystackLength: data.count,
                            from: matchEnd
                        )
                    }
                    matchCount += 1
                    candidates[candidateIndex] = nextCandidate(
                        literalIndex: literalIndex,
                        from: matchEnd
                    )
                } else {
                    rejectedBoundaryCandidates += 1
                    guard rejectedBoundaryCandidates <= maxRejectedBoundaryCandidates else {
                        return nil
                    }
                    candidates[candidateIndex] = nextCandidate(
                        literalIndex: literalIndex,
                        from: matchStart + 1
                    )
                }
            }

            return matchCount
        }
    }

    private static func countNonOverlappingMultiLiteralWordMatches(
        in data: Data,
        literals: [[UInt8]],
        asciiCaseInsensitive: Bool = false
    ) -> Int? {
        var matchCount = 0
        for literal in literals {
            guard let literalCount = countASCIIWordMatches(
                in: data,
                literal: literal,
                asciiCaseInsensitive: asciiCaseInsensitive
            ) else {
                return nil
            }
            matchCount += literalCount
        }
        return matchCount
    }

    public static func multiLiteralCountMatchesExitCode(
        path: String,
        literals: [[UInt8]],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard let literals = nonOverlappingDistinctLiterals(literals),
              !literals.isEmpty,
              maxCount.map({ $0 > 0 }) ?? true else {
            return nil
        }
        guard let data = mappedPreflightData(path: path) else {
            return nil
        }

        let matchCount: Int
        if let maxCount {
            matchCount = countMultiLiteralMatchesWithinFirstMatchingLines(
                data: data,
                literals: literals,
                maxCount: maxCount
            )
        } else {
            matchCount = countNonOverlappingMultiLiteralMatches(in: data, literals: literals)
        }

        if matchCount > 0 || includeZero {
            guard writeCountOutput(
                matchCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchCount > 0 ? 0 : 1
    }

    public static func multiLiteralOverlappingCountMatchesExitCode(
        path: String,
        literals: [[UInt8]],
        includeZero: Bool,
        maxCount: Int? = nil,
        countPrefix: [UInt8] = [],
        crlfTerminated: Bool = false
    ) -> Int32? {
        guard maxCount.map({ $0 > 0 }) ?? true,
              let data = mappedPreflightData(path: path),
              !hasBinaryDetectionPrefix(data),
              let matchCount = countMultiLiteralOnlyMatches(
                in: data,
                literals: literals,
                maxCount: maxCount
              ) else {
            return nil
        }

        if matchCount > 0 || includeZero {
            guard writeCountOutput(
                matchCount,
                countPrefix: countPrefix,
                crlfTerminated: crlfTerminated
            ) else {
                return nil
            }
        }
        return matchCount > 0 ? 0 : 1
    }

    private static func countMultiLiteralOnlyMatches(
        in data: Data,
        literals rawLiterals: [[UInt8]],
        maxCount: Int? = nil
    ) -> Int? {
        guard let literals = distinctExactLineLiterals(rawLiterals),
              !literals.isEmpty,
              maxCount.map({ $0 > 0 }) ?? true else {
            return nil
        }
        guard !data.isEmpty else {
            return 0
        }
        return data.withUnsafeBytes { rawData -> Int? in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            if maxCount == nil {
                return rgSwiftDarwinCountMultiLiteralOnlyMatches(
                    rawBase.assumingMemoryBound(to: UInt8.self),
                    haystackLength: data.count,
                    literals: literals
                )
            }
            return rgSwiftDarwinWriteMultiLiteralOnlyMatches(
                rawBase.assumingMemoryBound(to: UInt8.self),
                haystackLength: data.count,
                literals: literals,
                lineNumber: false,
                byteOffset: false,
                column: false,
                maxCount: maxCount ?? Int.max,
                lineNumberFieldSeparator: [58],
                linePrefix: [],
                headingPrefix: [],
                emitMatches: false
            )
        }
    }

    private static func countMultiLiteralOnlyMatchCounts(
        in data: Data,
        literals rawLiterals: [[UInt8]],
        maxCount: Int? = nil
    ) -> LiteralMatchedLineAndMatchCounts? {
        guard let literals = distinctExactLineLiterals(rawLiterals),
              !literals.isEmpty,
              maxCount.map({ $0 > 0 }) ?? true else {
            return nil
        }
        guard !data.isEmpty else {
            return LiteralMatchedLineAndMatchCounts(matchedLines: 0, totalMatches: 0)
        }
        return data.withUnsafeBytes { rawData -> LiteralMatchedLineAndMatchCounts? in
            guard let rawBase = rawData.baseAddress else {
                return LiteralMatchedLineAndMatchCounts(matchedLines: 0, totalMatches: 0)
            }
            return rgSwiftDarwinCountMultiLiteralOnlyMatchesAndLines(
                rawBase.assumingMemoryBound(to: UInt8.self),
                haystackLength: data.count,
                literals: literals,
                maxCount: maxCount ?? Int.max
            )
        }
    }

    private static func countMultiLiteralMatchesWithinFirstMatchingLines(
        data: Data,
        literals: [[UInt8]],
        maxCount: Int
    ) -> Int {
        guard maxCount > 0,
              !literals.isEmpty,
              !data.isEmpty else {
            return 0
        }
        return data.withUnsafeBytes { rawData -> Int in
            guard let rawBase = rawData.baseAddress else {
                return 0
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)

            func nextCandidate(literalIndex: Int, from offset: Int) -> (start: Int, literalIndex: Int) {
                let literal = literals[literalIndex]
                let safeOffset = min(offset, data.count)
                guard !literal.isEmpty,
                      literal.count <= data.count - safeOffset else {
                    return (Int.max, literalIndex)
                }
                let found = literal.withUnsafeBufferPointer { literalBuffer in
                    rg_memmem_simple(
                        base.advanced(by: safeOffset),
                        data.count - safeOffset,
                        literalBuffer.baseAddress,
                        literal.count
                    )
                }
                guard let found else {
                    return (Int.max, literalIndex)
                }
                return (base.distance(to: found), literalIndex)
            }

            func earliestCandidateIndex(in candidates: [(start: Int, literalIndex: Int)]) -> Int? {
                var selectedIndex: Int?
                var selectedStart = Int.max
                for index in candidates.indices where candidates[index].start < selectedStart {
                    selectedStart = candidates[index].start
                    selectedIndex = index
                }
                return selectedStart == Int.max ? nil : selectedIndex
            }

            func countMatches(inPrefixLength prefixLength: Int, literal: [UInt8]) -> Int {
                guard !literal.isEmpty,
                      prefixLength >= literal.count else {
                    return 0
                }
                return literal.withUnsafeBufferPointer { literalBuffer -> Int in
                    guard let literalBase = literalBuffer.baseAddress else {
                        return 0
                    }
                    var searchOffset = 0
                    var matchCount = 0
                    while searchOffset <= prefixLength - literal.count,
                          let found = rg_memmem_simple(
                            base.advanced(by: searchOffset),
                            prefixLength - searchOffset,
                            literalBase,
                            literal.count
                          ) {
                        let matchStart = base.distance(to: found)
                        matchCount += 1
                        searchOffset = matchStart + literal.count
                    }
                    return matchCount
                }
            }

            var candidates = literals.indices.map {
                nextCandidate(literalIndex: $0, from: 0)
            }
            var matchedLineCount = 0
            var selectedLineEnd = -1
            var selectedPrefixEnd = 0

            while let candidateIndex = earliestCandidateIndex(in: candidates) {
                let matchStart = candidates[candidateIndex].start
                guard matchStart < data.count else {
                    break
                }
                if matchStart >= selectedLineEnd {
                    guard matchedLineCount < maxCount else {
                        break
                    }
                    matchedLineCount += 1
                    selectedLineEnd = rgSwiftDarwinNextLineStart(
                        base: base,
                        haystackLength: data.count,
                        from: matchStart
                    )
                    selectedPrefixEnd = if selectedLineEnd > 0,
                                           base[selectedLineEnd - 1] == UInt8(ascii: "\n") {
                        selectedLineEnd - 1
                    } else {
                        selectedLineEnd
                    }
                }

                for index in candidates.indices where candidates[index].start < selectedLineEnd {
                    candidates[index] = nextCandidate(
                        literalIndex: candidates[index].literalIndex,
                        from: selectedLineEnd
                    )
                }
            }

            guard matchedLineCount > 0 else {
                return 0
            }
            var matchCount = 0
            for literal in literals {
                matchCount += countMatches(inPrefixLength: selectedPrefixEnd, literal: literal)
            }
            return matchCount
        }
    }

    private static func countNonOverlappingMultiLiteralMatches(
        in data: Data,
        literals: [[UInt8]]
    ) -> Int {
        guard literals.count > 1,
              data.count >= 1024 * 1024 else {
            var matchCount = 0
            for literal in literals {
                matchCount += countNonOverlappingMatches(in: data, literal: literal)
            }
            return matchCount
        }
        let accumulator = QuietStatsCountAccumulator()
        DispatchQueue.concurrentPerform(iterations: literals.count) { index in
            accumulator.add(countNonOverlappingMatches(in: data, literal: literals[index]))
        }
        return accumulator.snapshot()
    }

    static func multiLiteralResult(
        path: String,
        literals: [[UInt8]],
        maxCount: Int?,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = [],
        emitLines: Bool = true,
        trimLeadingWhitespace: Bool = false
    ) -> rg_darwin_literal_file_result? {
        guard !literals.isEmpty,
              literals.count <= 64,
              literals.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return rg_darwin_literal_file_result(
                status: 0,
                matched_line_count: 0,
                total_match_count: 0,
                bytes_searched: 0
            )
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        let base = UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self)
        return rgSwiftDarwinWriteMultiLiteralLines(
            base,
            haystackLength: haystackLength,
            literals: literals,
            maxCount: maxCount ?? Int.max,
            lineNumber: lineNumber,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix,
            emitLines: emitLines,
            trimLeadingWhitespace: trimLeadingWhitespace
        )
    }

    public static func trimmedLiteralLineExitCode(
        path: String,
        literal: [UInt8],
        maxCount: Int,
        asciiCaseInsensitive: Bool = false,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literal.isEmpty,
              maxCount > 0 else {
            return nil
        }

        if asciiCaseInsensitive {
            guard literal.allSatisfy({ $0 < 0x80 }) else {
                return nil
            }
            let fd = path.withCString { Darwin.open($0, O_RDONLY) }
            guard fd >= 0 else {
                return nil
            }
            defer {
                Darwin.close(fd)
            }

            var fileStat = stat()
            guard Darwin.fstat(fd, &fileStat) == 0 else {
                return nil
            }
            guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
                return nil
            }
            guard fileStat.st_size > 0 else {
                return 1
            }
            guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
                return nil
            }

            let haystackLength = Int(fileStat.st_size)
            guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
                  mapped != MAP_FAILED else {
                return nil
            }
            defer {
                Darwin.munmap(mapped, haystackLength)
            }

            guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
                rgSwiftDarwinWriteTrimmedLiteralLines(
                    UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                    haystackLength: haystackLength,
                    literal: literalBuffer,
                    maxCount: maxCount,
                    asciiCaseInsensitive: true,
                    lineNumber: lineNumber,
                    lineNumberFieldSeparator: lineNumberFieldSeparator,
                    linePrefix: linePrefix,
                    headingPrefix: headingPrefix
                )
            }) else {
                return nil
            }
            return matchedLineCount > 0 ? 0 : 1
        }

        guard let result = multiLiteralResult(
            path: path,
            literals: [literal],
            maxCount: maxCount,
            lineNumber: lineNumber,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix,
            trimLeadingWhitespace: true
        ),
        result.status == 0 else {
            return nil
        }
        return result.matched_line_count > 0 ? 0 : 1
    }

    public static func trimmedMultiLiteralLineExitCode(
        path: String,
        literals: [[UInt8]],
        maxCount: Int,
        asciiCaseInsensitive: Bool = false,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literals.isEmpty,
              literals.count <= 64,
              literals.allSatisfy({ !$0.isEmpty }),
              maxCount > 0 else {
            return nil
        }

        if asciiCaseInsensitive {
            guard literals.allSatisfy({ $0.allSatisfy { $0 < 0x80 } }) else {
                return nil
            }
            let fd = path.withCString { Darwin.open($0, O_RDONLY) }
            guard fd >= 0 else {
                return nil
            }
            defer {
                Darwin.close(fd)
            }

            var fileStat = stat()
            guard Darwin.fstat(fd, &fileStat) == 0 else {
                return nil
            }
            guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
                return nil
            }
            guard fileStat.st_size > 0 else {
                return 1
            }
            guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
                return nil
            }

            let haystackLength = Int(fileStat.st_size)
            guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
                  mapped != MAP_FAILED else {
                return nil
            }
            defer {
                Darwin.munmap(mapped, haystackLength)
            }

            guard let matchedLineCount = rgSwiftDarwinWriteTrimmedMultiLiteralLines(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literals: literals,
                maxCount: maxCount,
                asciiCaseInsensitive: true,
                lineNumber: lineNumber,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            ) else {
                return nil
            }
            return matchedLineCount > 0 ? 0 : 1
        }

        guard let result = multiLiteralResult(
            path: path,
            literals: literals,
            maxCount: maxCount,
            lineNumber: lineNumber,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix,
            trimLeadingWhitespace: true
        ),
        result.status == 0 else {
            return nil
        }
        return result.matched_line_count > 0 ? 0 : 1
    }

    public static func invertedLiteralLineExitCode(
        path: String,
        literal: [UInt8],
        maxCount: Int,
        asciiCaseInsensitive: Bool = false,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literal.isEmpty,
              maxCount > 0 else {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let selectedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWriteInvertedLiteralLines(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                maxCount: maxCount,
                asciiCaseInsensitive: asciiCaseInsensitive,
                lineNumber: lineNumber,
                lineNumberFieldSeparator: lineNumberFieldSeparator,
                linePrefix: linePrefix,
                headingPrefix: headingPrefix
            )
        }) else {
            return nil
        }
        return selectedLineCount > 0 ? 0 : 1
    }

    public static func invertedMultiLiteralLineExitCode(
        path: String,
        literals: [[UInt8]],
        maxCount: Int,
        asciiCaseInsensitive: Bool = false,
        lineNumber: Bool = false,
        lineNumberFieldSeparator: [UInt8] = [58],
        linePrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literals.isEmpty,
              literals.count <= 64,
              literals.allSatisfy({ !$0.isEmpty }),
              maxCount > 0 else {
            return nil
        }
        if asciiCaseInsensitive,
           !literals.allSatisfy({ $0.allSatisfy { $0 < 0x80 } }) {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let selectedLineCount = rgSwiftDarwinWriteInvertedMultiLiteralLines(
            UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
            haystackLength: haystackLength,
            literals: literals,
            maxCount: maxCount,
            asciiCaseInsensitive: asciiCaseInsensitive,
            lineNumber: lineNumber,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix
        ) else {
            return nil
        }
        return selectedLineCount > 0 ? 0 : 1
    }

    public static func afterContextLiteralLineExitCode(
        path: String,
        literal: [UInt8],
        afterContext: Int,
        maxCount: Int,
        asciiCaseInsensitive: Bool = false,
        lineNumber: Bool = false,
        lineNumberFieldMatchSeparator: [UInt8] = [58],
        lineNumberFieldContextSeparator: [UInt8] = [45],
        lineMatchPrefix: [UInt8] = [],
        lineContextPrefix: [UInt8] = [],
        headingPrefix: [UInt8] = [],
        contextSeparator: [UInt8]? = [45, 45]
    ) -> Int32? {
        guard !literal.isEmpty,
              afterContext > 0,
              maxCount > 0 else {
            return nil
        }
        if asciiCaseInsensitive, literal.contains(where: { $0 >= 0x80 }) {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWriteAfterContextLiteralLines(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                afterContext: afterContext,
                maxCount: maxCount,
                asciiCaseInsensitive: asciiCaseInsensitive,
                lineNumber: lineNumber,
                lineNumberFieldMatchSeparator: lineNumberFieldMatchSeparator,
                lineNumberFieldContextSeparator: lineNumberFieldContextSeparator,
                lineMatchPrefix: lineMatchPrefix,
                lineContextPrefix: lineContextPrefix,
                headingPrefix: headingPrefix,
                contextSeparator: contextSeparator
            )
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func beforeContextLiteralLineExitCode(
        path: String,
        literal: [UInt8],
        beforeContext: Int,
        maxCount: Int,
        asciiCaseInsensitive: Bool = false,
        lineNumber: Bool = false,
        lineNumberFieldMatchSeparator: [UInt8] = [58],
        lineNumberFieldContextSeparator: [UInt8] = [45],
        lineMatchPrefix: [UInt8] = [],
        lineContextPrefix: [UInt8] = [],
        headingPrefix: [UInt8] = [],
        contextSeparator: [UInt8]? = [45, 45]
    ) -> Int32? {
        guard !literal.isEmpty,
              beforeContext > 0,
              maxCount > 0 else {
            return nil
        }
        if asciiCaseInsensitive, literal.contains(where: { $0 >= 0x80 }) {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWriteBeforeContextLiteralLines(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                beforeContext: beforeContext,
                maxCount: maxCount,
                asciiCaseInsensitive: asciiCaseInsensitive,
                lineNumber: lineNumber,
                lineNumberFieldMatchSeparator: lineNumberFieldMatchSeparator,
                lineNumberFieldContextSeparator: lineNumberFieldContextSeparator,
                lineMatchPrefix: lineMatchPrefix,
                lineContextPrefix: lineContextPrefix,
                headingPrefix: headingPrefix,
                contextSeparator: contextSeparator
            )
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func contextLiteralLineExitCode(
        path: String,
        literal: [UInt8],
        beforeContext: Int,
        afterContext: Int,
        maxCount: Int,
        asciiCaseInsensitive: Bool = false,
        lineNumber: Bool = false,
        lineNumberFieldMatchSeparator: [UInt8] = [58],
        lineNumberFieldContextSeparator: [UInt8] = [45],
        lineMatchPrefix: [UInt8] = [],
        lineContextPrefix: [UInt8] = [],
        headingPrefix: [UInt8] = [],
        contextSeparator: [UInt8]? = [45, 45]
    ) -> Int32? {
        guard !literal.isEmpty,
              beforeContext > 0,
              afterContext > 0,
              maxCount > 0 else {
            return nil
        }
        if asciiCaseInsensitive, literal.contains(where: { $0 >= 0x80 }) {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWriteContextLiteralLines(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                beforeContext: beforeContext,
                afterContext: afterContext,
                maxCount: maxCount,
                asciiCaseInsensitive: asciiCaseInsensitive,
                lineNumber: lineNumber,
                lineNumberFieldMatchSeparator: lineNumberFieldMatchSeparator,
                lineNumberFieldContextSeparator: lineNumberFieldContextSeparator,
                lineMatchPrefix: lineMatchPrefix,
                lineContextPrefix: lineContextPrefix,
                headingPrefix: headingPrefix,
                contextSeparator: contextSeparator
            )
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func multiLiteralContextLineExitCode(
        path: String,
        literals: [[UInt8]],
        beforeContext: Int,
        afterContext: Int,
        maxCount: Int,
        asciiCaseInsensitive: Bool = false,
        lineNumber: Bool = false,
        lineNumberFieldMatchSeparator: [UInt8] = [58],
        lineNumberFieldContextSeparator: [UInt8] = [45],
        lineMatchPrefix: [UInt8] = [],
        lineContextPrefix: [UInt8] = [],
        headingPrefix: [UInt8] = [],
        contextSeparator: [UInt8]? = [45, 45]
    ) -> Int32? {
        guard !literals.isEmpty,
              literals.allSatisfy({ !$0.isEmpty }),
              beforeContext > 0 || afterContext > 0,
              maxCount > 0 else {
            return nil
        }
        if asciiCaseInsensitive,
           !literals.allSatisfy({ $0.allSatisfy { $0 < 0x80 } }) {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = rgSwiftDarwinWriteMultiLiteralContextLines(
            UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
            haystackLength: haystackLength,
            literals: literals,
            beforeContext: beforeContext,
            afterContext: afterContext,
            maxCount: maxCount,
            asciiCaseInsensitive: asciiCaseInsensitive,
            lineNumber: lineNumber,
            lineNumberFieldMatchSeparator: lineNumberFieldMatchSeparator,
            lineNumberFieldContextSeparator: lineNumberFieldContextSeparator,
            lineMatchPrefix: lineMatchPrefix,
            lineContextPrefix: lineContextPrefix,
            headingPrefix: headingPrefix,
            contextSeparator: contextSeparator
        ) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }

    public static func passthruLiteralLineExitCode(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool = false,
        lineNumber: Bool = false,
        lineNumberFieldMatchSeparator: [UInt8] = [58],
        lineNumberFieldContextSeparator: [UInt8] = [45],
        lineMatchPrefix: [UInt8] = [],
        lineContextPrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard let result = passthruLiteralLineResult(
            path: path,
            literal: literal,
            asciiCaseInsensitive: asciiCaseInsensitive,
            lineNumber: lineNumber,
            lineNumberFieldMatchSeparator: lineNumberFieldMatchSeparator,
            lineNumberFieldContextSeparator: lineNumberFieldContextSeparator,
            lineMatchPrefix: lineMatchPrefix,
            lineContextPrefix: lineContextPrefix,
            headingPrefix: headingPrefix
        ) else {
            return nil
        }
        return result.matched_line_count > 0 ? 0 : 1
    }

    static func passthruLiteralLineResult(
        path: String,
        literal: [UInt8],
        asciiCaseInsensitive: Bool = false,
        lineNumber: Bool = false,
        lineNumberFieldMatchSeparator: [UInt8] = [58],
        lineNumberFieldContextSeparator: [UInt8] = [45],
        lineMatchPrefix: [UInt8] = [],
        lineContextPrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> rg_darwin_literal_file_result? {
        guard !literal.isEmpty else {
            return nil
        }
        if asciiCaseInsensitive, literal.contains(where: { $0 >= 0x80 }) {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return rg_darwin_literal_file_result(
                status: 0,
                matched_line_count: 0,
                total_match_count: 0,
                bytes_searched: 0
            )
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = literal.withUnsafeBufferPointer({ literalBuffer in
            rgSwiftDarwinWritePassthruLiteralLines(
                UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
                haystackLength: haystackLength,
                literal: literalBuffer,
                asciiCaseInsensitive: asciiCaseInsensitive,
                lineNumber: lineNumber,
                lineNumberFieldMatchSeparator: lineNumberFieldMatchSeparator,
                lineNumberFieldContextSeparator: lineNumberFieldContextSeparator,
                lineMatchPrefix: lineMatchPrefix,
                lineContextPrefix: lineContextPrefix,
                headingPrefix: headingPrefix
            )
        }) else {
            return nil
        }
        return rg_darwin_literal_file_result(
            status: 0,
            matched_line_count: matchedLineCount,
            total_match_count: matchedLineCount,
            bytes_searched: haystackLength
        )
    }

    public static func multiLiteralPassthruLineExitCode(
        path: String,
        literals: [[UInt8]],
        asciiCaseInsensitive: Bool = false,
        lineNumber: Bool = false,
        lineNumberFieldMatchSeparator: [UInt8] = [58],
        lineNumberFieldContextSeparator: [UInt8] = [45],
        lineMatchPrefix: [UInt8] = [],
        lineContextPrefix: [UInt8] = [],
        headingPrefix: [UInt8] = []
    ) -> Int32? {
        guard !literals.isEmpty,
              literals.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        if asciiCaseInsensitive,
           !literals.allSatisfy({ $0.allSatisfy { $0 < 0x80 } }) {
            return nil
        }

        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else {
            return nil
        }
        defer {
            Darwin.close(fd)
        }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            return nil
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard fileStat.st_size > 0 else {
            return 1
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            return nil
        }

        let haystackLength = Int(fileStat.st_size)
        guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        defer {
            Darwin.munmap(mapped, haystackLength)
        }

        guard let matchedLineCount = rgSwiftDarwinWritePassthruMultiLiteralLines(
            UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
            haystackLength: haystackLength,
            literals: literals,
            asciiCaseInsensitive: asciiCaseInsensitive,
            lineNumber: lineNumber,
            lineNumberFieldMatchSeparator: lineNumberFieldMatchSeparator,
            lineNumberFieldContextSeparator: lineNumberFieldContextSeparator,
            lineMatchPrefix: lineMatchPrefix,
            lineContextPrefix: lineContextPrefix,
            headingPrefix: headingPrefix
        ) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
    }
}

private func countNonOverlappingMatches(in data: Data, literal: [UInt8]) -> Int {
    guard !literal.isEmpty,
          data.count >= literal.count else {
        return 0
    }
    return data.withUnsafeBytes { rawData in
        guard let rawBase = rawData.baseAddress else {
            return 0
        }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        return literal.withUnsafeBufferPointer { needle in
            guard let needleBase = needle.baseAddress else {
                return 0
            }
            if literal.count == 1 {
                return rg_memcount_byte(base, data.count, needleBase[0])
            }

            var searchOffset = 0
            var matchCount = 0
            while searchOffset < data.count {
                guard let found = rg_memmem_simple(
                    base.advanced(by: searchOffset),
                    data.count - searchOffset,
                    needleBase,
                    literal.count
                ) else {
                    break
                }
                matchCount += 1
                searchOffset = base.distance(to: found) + literal.count
            }
            return matchCount
        }
    }
}

private func countLiteralMatchedLines(
    in data: Data,
    literal: [UInt8],
    maxCount: Int?
) -> Int {
    guard !literal.isEmpty,
          data.count >= literal.count else {
        return 0
    }
    let limit = maxCount ?? Int.max
    return data.withUnsafeBytes { rawData in
        guard let rawBase = rawData.baseAddress else {
            return 0
        }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        return literal.withUnsafeBufferPointer { needle in
            guard let needleBase = needle.baseAddress else {
                return 0
            }

            var searchOffset = 0
            var matchedLineCount = 0
            while matchedLineCount < limit,
                  searchOffset <= data.count - literal.count {
                guard let found = rg_memmem_simple(
                    base.advanced(by: searchOffset),
                    data.count - searchOffset,
                    needleBase,
                    literal.count
                ) else {
                    break
                }
                let matchStart = base.distance(to: found)
                matchedLineCount += 1
                searchOffset = rgSwiftDarwinNextLineStart(
                    base: base,
                    haystackLength: data.count,
                    from: matchStart + literal.count
                )
            }
            return matchedLineCount
        }
    }
}

private struct LiteralLineWriteStats {
    let matchedLines: Int
    let bytesPrinted: Int
    let bytesSearched: Int
}

private struct LiteralMatchedLineAndMatchCounts {
    let matchedLines: Int
    let totalMatches: Int
}

private func literalMatchedLineAndMatchCounts(
    in data: Data,
    literal: [UInt8]
) -> LiteralMatchedLineAndMatchCounts {
    guard !literal.isEmpty,
          data.count >= literal.count else {
        return LiteralMatchedLineAndMatchCounts(matchedLines: 0, totalMatches: 0)
    }
    var result = LiteralMatchedLineAndMatchCounts(matchedLines: 0, totalMatches: 0)
    data.withUnsafeBytes { (rawData: UnsafeRawBufferPointer) -> Void in
        guard let rawBase = rawData.baseAddress else {
            return
        }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        literal.withUnsafeBufferPointer { needle in
            guard let needleBase = needle.baseAddress else {
                return
            }

            var searchOffset = 0
            var matchedLineCount = 0
            var totalMatchCount = 0
            var currentLineEnd = -1
            if literal.count == 1 {
                while searchOffset < data.count {
                    guard let rawFound = memchr(
                        base.advanced(by: searchOffset),
                        Int32(needleBase[0]),
                        data.count - searchOffset
                    ) else {
                        break
                    }
                    let found = rawFound.assumingMemoryBound(to: UInt8.self)
                    let matchStart = base.distance(to: found)
                    totalMatchCount += 1
                    if matchStart >= currentLineEnd {
                        matchedLineCount += 1
                        let newline = memchr(
                            found,
                            Int32(UInt8(ascii: "\n")),
                            data.count - matchStart
                        )
                        currentLineEnd = newline.map {
                            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
                        } ?? data.count
                    }
                    searchOffset = matchStart + 1
                }
            } else {
                while searchOffset <= data.count - literal.count {
                    guard let found = rg_memmem_simple(
                        base.advanced(by: searchOffset),
                        data.count - searchOffset,
                        needleBase,
                        literal.count
                    ) else {
                        break
                    }
                    let matchStart = base.distance(to: found)
                    totalMatchCount += 1
                    if matchStart >= currentLineEnd {
                        matchedLineCount += 1
                        let newline = memchr(
                            found,
                            Int32(UInt8(ascii: "\n")),
                            data.count - matchStart
                        )
                        currentLineEnd = newline.map {
                            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
                        } ?? data.count
                    }
                    searchOffset = matchStart + literal.count
                }
            }
            result = LiteralMatchedLineAndMatchCounts(
                matchedLines: matchedLineCount,
                totalMatches: totalMatchCount
            )
        }
    }
    return result
}

private func nonOverlappingDistinctLiterals(_ literals: [[UInt8]]) -> [[UInt8]]? {
    var distinct: [[UInt8]] = []
    distinct.reserveCapacity(literals.count)
    for literal in literals {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")) else {
            return nil
        }
        if !distinct.contains(literal) {
            distinct.append(literal)
        }
    }

    for leftIndex in distinct.indices {
        for rightIndex in distinct.indices where leftIndex != rightIndex {
            if literalsCanOverlap(distinct[leftIndex], distinct[rightIndex]) {
                return nil
            }
        }
    }
    return distinct
}

private func distinctASCIIWordLiterals(_ literals: [[UInt8]]) -> [[UInt8]]? {
    var distinct: [[UInt8]] = []
    distinct.reserveCapacity(literals.count)
    for literal in literals {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              let first = literal.first,
              let last = literal.last,
              rgSwiftIsASCIIRegexWordByte(first),
              rgSwiftIsASCIIRegexWordByte(last) else {
            return nil
        }
        if !distinct.contains(literal) {
            distinct.append(literal)
        }
    }
    return distinct
}

private func distinctASCIICaseInsensitiveLiterals(_ literals: [[UInt8]]) -> [[UInt8]]? {
    var distinct: [[UInt8]] = []
    distinct.reserveCapacity(literals.count)
    for literal in literals {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              literal.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        let folded = literal.map(rgSwiftASCIILower)
        if !distinct.contains(folded) {
            distinct.append(folded)
        }
    }
    return distinct
}

private func distinctASCIICaseInsensitiveWordLiterals(_ literals: [[UInt8]]) -> [[UInt8]]? {
    var distinct: [[UInt8]] = []
    distinct.reserveCapacity(literals.count)
    for literal in literals {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              literal.allSatisfy({ $0 < 0x80 }),
              let first = literal.first,
              let last = literal.last,
              rgSwiftIsASCIIRegexWordByte(first),
              rgSwiftIsASCIIRegexWordByte(last) else {
            return nil
        }
        let folded = literal.map(rgSwiftASCIILower)
        if !distinct.contains(folded) {
            distinct.append(folded)
        }
    }
    return distinct
}

private func nonOverlappingDistinctASCIICaseInsensitiveWordLiterals(_ literals: [[UInt8]]) -> [[UInt8]]? {
    guard let distinct = distinctASCIICaseInsensitiveWordLiterals(literals) else {
        return nil
    }
    for leftIndex in distinct.indices {
        for rightIndex in distinct.indices where leftIndex != rightIndex {
            if literalsCanOverlap(distinct[leftIndex], distinct[rightIndex]) {
                return nil
            }
        }
    }
    return distinct
}

private func distinctExactLineLiterals(_ literals: [[UInt8]]) -> [[UInt8]]? {
    var distinct: [[UInt8]] = []
    distinct.reserveCapacity(literals.count)
    for literal in literals {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")) else {
            return nil
        }
        if !distinct.contains(literal) {
            distinct.append(literal)
        }
    }
    return distinct
}

private func distinctASCIICaseInsensitiveExactLineLiterals(_ literals: [[UInt8]]) -> [[UInt8]]? {
    var distinct: [[UInt8]] = []
    distinct.reserveCapacity(literals.count)
    for literal in literals {
        guard !literal.isEmpty,
              !literal.contains(UInt8(ascii: "\n")),
              literal.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        let folded = literal.map(rgSwiftASCIILower)
        if !distinct.contains(folded) {
            distinct.append(folded)
        }
    }
    return distinct
}

private func literalsCanOverlap(_ left: [UInt8], _ right: [UInt8]) -> Bool {
    if containsLiteral(left, in: right) || containsLiteral(right, in: left) {
        return true
    }

    let maxOverlap = min(left.count, right.count)
    guard maxOverlap > 0 else {
        return false
    }
    for length in 1...maxOverlap {
        if suffix(left, length).elementsEqual(prefix(right, length))
            || suffix(right, length).elementsEqual(prefix(left, length)) {
            return true
        }
    }
    return false
}

private func containsLiteral(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
    guard !needle.isEmpty,
          needle.count <= haystack.count else {
        return false
    }
    if needle.count == haystack.count {
        return needle == haystack
    }
    for offset in 0...(haystack.count - needle.count) {
        var matches = true
        for index in needle.indices where haystack[offset + index] != needle[index] {
            matches = false
            break
        }
        if matches {
            return true
        }
    }
    return false
}

private func prefix(_ bytes: [UInt8], _ count: Int) -> ArraySlice<UInt8> {
    bytes[..<bytes.index(bytes.startIndex, offsetBy: count)]
}

private func suffix(_ bytes: [UInt8], _ count: Int) -> ArraySlice<UInt8> {
    bytes[bytes.index(bytes.endIndex, offsetBy: -count)..<bytes.endIndex]
}

private func countASCIIWordMatches(
    in data: Data,
    literal: [UInt8],
    asciiCaseInsensitive: Bool = false
) -> Int? {
    guard !literal.isEmpty,
          data.count >= literal.count else {
        return 0
    }
    return data.withUnsafeBytes { rawData in
        guard let rawBase = rawData.baseAddress else {
            return 0
        }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        return literal.withUnsafeBufferPointer { needle -> Int? in
            guard let needleBase = needle.baseAddress else {
                return 0
            }
            let foldedLiteral = asciiCaseInsensitive ? literal.map(rgSwiftASCIILower) : []
            if asciiCaseInsensitive,
               literal.count == 1,
               rgSwiftDarwinFindASCIICaseInsensitiveByte(
                base,
                haystackLength: data.count,
                foldedByte: foldedLiteral[0]
               ) == nil {
                return 0
            }
            var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
            if asciiCaseInsensitive, foldedLiteral.count > 1 {
                for index in 0..<(foldedLiteral.count - 1) {
                    caseInsensitiveShifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
                }
            }

            var searchOffset = 0
            var matchCount = 0
            while searchOffset < data.count {
                let found: UnsafePointer<UInt8>?
                if asciiCaseInsensitive {
                    found = foldedLiteral.withUnsafeBufferPointer { foldedNeedle in
                        caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                            rg_memcasemem_ascii_prepared(
                                base.advanced(by: searchOffset),
                                data.count - searchOffset,
                                foldedNeedle.baseAddress,
                                foldedNeedle.count,
                                shifts.baseAddress
                            )
                        }
                    }
                } else {
                    found = rg_memmem_simple(
                        base.advanced(by: searchOffset),
                        data.count - searchOffset,
                        needleBase,
                        literal.count
                    )
                }
                guard let found else {
                    break
                }

                let matchStart = base.distance(to: found)
                let matchEnd = matchStart + literal.count
                guard let bounded = isASCIIWordBoundaryMatch(
                    base: base,
                    dataCount: data.count,
                    matchStart: matchStart,
                    matchEnd: matchEnd
                ) else {
                    return nil
                }
                if bounded {
                    matchCount += 1
                    searchOffset = matchEnd
                } else {
                    searchOffset = rgSwiftNextASCIIWordSearchOffset(
                        base: base,
                        dataCount: data.count,
                        matchEnd: matchEnd
                    )
                }
            }
            return matchCount
        }
    }
}

private func countASCIIWordMatchedLines(
    in data: Data,
    literal: [UInt8],
    maxCount: Int?
) -> Int? {
    guard !literal.isEmpty,
          data.count >= literal.count else {
        return 0
    }
    let limit = maxCount ?? Int.max
    return data.withUnsafeBytes { rawData in
        guard let rawBase = rawData.baseAddress else {
            return 0
        }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        return literal.withUnsafeBufferPointer { needle -> Int? in
            guard let needleBase = needle.baseAddress else {
                return 0
            }

            var searchOffset = 0
            var matchedLineCount = 0
            while searchOffset < data.count,
                  matchedLineCount < limit {
                guard let found = rg_memmem_simple(
                    base.advanced(by: searchOffset),
                    data.count - searchOffset,
                    needleBase,
                    literal.count
                ) else {
                    break
                }

                let matchStart = base.distance(to: found)
                let matchEnd = matchStart + literal.count
                guard let bounded = isASCIIWordBoundaryMatch(
                    base: base,
                    dataCount: data.count,
                    matchStart: matchStart,
                    matchEnd: matchEnd
                ) else {
                    return nil
                }
                if bounded {
                    matchedLineCount += 1
                    guard let newline = memchr(
                        base.advanced(by: matchEnd),
                        Int32(UInt8(ascii: "\n")),
                        data.count - matchEnd
                    ) else {
                        break
                    }
                    searchOffset = base.distance(to: newline.assumingMemoryBound(to: UInt8.self)) + 1
                } else {
                    searchOffset = rgSwiftNextASCIIWordSearchOffset(
                        base: base,
                        dataCount: data.count,
                        matchEnd: matchEnd
                    )
                }
            }
            return matchedLineCount
        }
    }
}

private func countASCIIWordMatchedLines(
    in data: Data,
    literals: [[UInt8]],
    maxCount: Int?,
    asciiCaseInsensitive: Bool = false
) -> Int? {
    guard !literals.isEmpty else {
        return 0
    }
    let limit = maxCount ?? Int.max
    let searchLiterals = asciiCaseInsensitive
        ? literals.map { $0.map(rgSwiftASCIILower) }
        : literals
    let caseInsensitiveShifts: [[Int]] = if asciiCaseInsensitive {
        searchLiterals.map { literal -> [Int] in
            var shifts = [Int](repeating: literal.count, count: 256)
            if literal.count > 1 {
                for index in 0..<(literal.count - 1) {
                    shifts[Int(literal[index])] = literal.count - 1 - index
                }
            }
            return shifts
        }
    } else {
        []
    }
    return data.withUnsafeBytes { rawData in
        guard let rawBase = rawData.baseAddress else {
            return 0
        }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        if asciiCaseInsensitive,
           searchLiterals.count == 1,
           searchLiterals[0].count == 1,
           rgSwiftDarwinFindASCIICaseInsensitiveByte(
            base,
            haystackLength: data.count,
            foldedByte: searchLiterals[0][0]
           ) == nil {
            return 0
        }
        var searchOffset = 0
        var matchedLineCount = 0

        while searchOffset < data.count,
              matchedLineCount < limit {
            var bestStart = Int.max
            var bestEnd = Int.max
            var needsFallback = false

            for literalIndex in searchLiterals.indices {
                let literal = searchLiterals[literalIndex]
                literal.withUnsafeBufferPointer { needle in
                    guard !needsFallback,
                          let needleBase = needle.baseAddress else {
                        return
                    }
                    var literalSearchOffset = searchOffset
                    while literalSearchOffset < data.count {
                        let found: UnsafePointer<UInt8>?
                        if asciiCaseInsensitive {
                            found = caseInsensitiveShifts[literalIndex].withUnsafeBufferPointer { shifts in
                                rg_memcasemem_ascii_prepared(
                                    base.advanced(by: literalSearchOffset),
                                    data.count - literalSearchOffset,
                                    needleBase,
                                    literal.count,
                                    shifts.baseAddress
                                )
                            }
                        } else {
                            found = rg_memmem_simple(
                                base.advanced(by: literalSearchOffset),
                                data.count - literalSearchOffset,
                                needleBase,
                                literal.count
                            )
                        }
                        guard let found else {
                            break
                        }

                        let matchStart = base.distance(to: found)
                        let matchEnd = matchStart + literal.count
                        guard let bounded = isASCIIWordBoundaryMatch(
                            base: base,
                            dataCount: data.count,
                            matchStart: matchStart,
                            matchEnd: matchEnd
                        ) else {
                            needsFallback = true
                            return
                        }
                        if bounded {
                            if matchStart < bestStart {
                                bestStart = matchStart
                                bestEnd = matchEnd
                            }
                            break
                        }

                        literalSearchOffset = rgSwiftNextASCIIWordSearchOffset(
                            base: base,
                            dataCount: data.count,
                            matchEnd: matchEnd
                        )
                    }
                }
                if needsFallback {
                    return nil
                }
            }

            guard bestStart != Int.max else {
                break
            }
            matchedLineCount += 1
            guard let newline = memchr(
                base.advanced(by: bestEnd),
                Int32(UInt8(ascii: "\n")),
                data.count - bestEnd
            ) else {
                break
            }
            searchOffset = base.distance(to: newline.assumingMemoryBound(to: UInt8.self)) + 1
        }
        return matchedLineCount
    }

}

private func writeBoundedASCIIWordMatchedLines(
    in data: Data,
    literals: [[UInt8]],
    maxCount: Int
) -> Int? {
    guard maxCount > 0,
          !literals.isEmpty else {
        return 0
    }
    struct PendingLine {
        let start: Int
        let outputEnd: Int
        let needsFinalNewline: Bool
    }

    return data.withUnsafeBytes { rawData in
        guard let rawBase = rawData.baseAddress else {
            return 0
        }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        var searchOffset = 0
        let newline = UInt8(ascii: "\n")
        var pendingLines: [PendingLine] = []
        pendingLines.reserveCapacity(min(maxCount, 1024))

        func literalMatchesAtSearchOffset(_ literal: [UInt8]) -> Bool? {
            guard literal.count <= data.count - searchOffset else {
                return false
            }
            for index in literal.indices where base[searchOffset + index] != literal[index] {
                return false
            }
            return isASCIIWordBoundaryMatch(
                base: base,
                dataCount: data.count,
                matchStart: searchOffset,
                matchEnd: searchOffset + literal.count
            )
        }

        while searchOffset < data.count,
              pendingLines.count < maxCount {
            var bestStart = Int.max
            var bestEnd = Int.max
            var needsFallback = false

            for literal in literals {
                guard let bounded = literalMatchesAtSearchOffset(literal) else {
                    return nil
                }
                if bounded {
                    bestStart = searchOffset
                    bestEnd = searchOffset + literal.count
                    break
                }
            }

            if bestStart == Int.max {
                for literal in literals {
                    literal.withUnsafeBufferPointer { needle in
                        guard !needsFallback,
                              let needleBase = needle.baseAddress else {
                            return
                        }
                        var literalSearchOffset = searchOffset
                        while literalSearchOffset < data.count {
                            guard let found = rg_memmem_simple(
                                base.advanced(by: literalSearchOffset),
                                data.count - literalSearchOffset,
                                needleBase,
                                literal.count
                            ) else {
                                break
                            }

                            let matchStart = base.distance(to: found)
                            let matchEnd = matchStart + literal.count
                            guard let bounded = isASCIIWordBoundaryMatch(
                                base: base,
                                dataCount: data.count,
                                matchStart: matchStart,
                                matchEnd: matchEnd
                            ) else {
                                needsFallback = true
                                return
                            }
                            if bounded {
                                if matchStart < bestStart {
                                    bestStart = matchStart
                                    bestEnd = matchEnd
                                }
                                break
                            }

                            literalSearchOffset = rgSwiftNextASCIIWordSearchOffset(
                                base: base,
                                dataCount: data.count,
                                matchEnd: matchEnd
                            )
                        }
                    }
                    if needsFallback {
                        return nil
                    }
                }
            }

            guard bestStart != Int.max else {
                break
            }

            var lineStart = bestStart
            while lineStart > 0, base[lineStart - 1] != newline {
                lineStart -= 1
            }
            let lineEndPointer = memchr(
                base.advanced(by: bestEnd),
                Int32(newline),
                data.count - bestEnd
            )
            let outputEnd: Int
            let needsFinalNewline: Bool
            if let lineEndPointer {
                outputEnd = base.distance(to: lineEndPointer.assumingMemoryBound(to: UInt8.self)) + 1
                needsFinalNewline = false
            } else {
                outputEnd = data.count
                needsFinalNewline = true
            }

            pendingLines.append(PendingLine(
                start: lineStart,
                outputEnd: outputEnd,
                needsFinalNewline: needsFinalNewline
            ))
            searchOffset = outputEnd
        }

        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }
        for line in pendingLines {
            guard output.write(base.advanced(by: line.start), count: line.outputEnd - line.start) else {
                return nil
            }
            if line.needsFinalNewline,
               !output.writeByte(newline) {
                return nil
            }
        }
        guard output.flush() else {
            return nil
        }
        return pendingLines.count
    }
}

private func writeASCIIWordMatchedLines(
    in data: Data,
    literals: [[UInt8]],
    maxCount: Int?,
    asciiCaseInsensitive: Bool = false,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard !literals.isEmpty else {
        return 0
    }
    let limit = maxCount ?? Int.max
    let searchLiterals = asciiCaseInsensitive
        ? literals.map { $0.map(rgSwiftASCIILower) }
        : literals
    let caseInsensitiveShifts: [[Int]] = if asciiCaseInsensitive {
        searchLiterals.map { literal -> [Int] in
            var shifts = [Int](repeating: literal.count, count: 256)
            if literal.count > 1 {
                for index in 0..<(literal.count - 1) {
                    shifts[Int(literal[index])] = literal.count - 1 - index
                }
            }
            return shifts
        }
    } else {
        []
    }
    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    return data.withUnsafeBytes { rawData in
        guard let rawBase = rawData.baseAddress else {
            return 0
        }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        var searchOffset = 0
        var matchedLineCount = 0
        var rejectedBoundaryCandidates = 0
        var currentLineNumber = 1
        var lineCountOffset = 0
        var emittedHeading = false
        let simpleOutput = !lineNumber && linePrefix.isEmpty && headingPrefix.isEmpty
        var pendingOutputStart: Int?
        var pendingOutputEnd = 0
        var pendingNeedsFinalNewline = false
        let maxRejectedBoundaryCandidates = maxCount == nil ? 128 : nil

        func flushPendingSimpleOutput() -> Bool {
            guard let start = pendingOutputStart else {
                return true
            }
            guard output.write(base.advanced(by: start), count: pendingOutputEnd - start) else {
                return false
            }
            if pendingNeedsFinalNewline,
               !output.writeByte(UInt8(ascii: "\n")) {
                return false
            }
            pendingOutputStart = nil
            pendingOutputEnd = 0
            pendingNeedsFinalNewline = false
            return true
        }

        func matchAtSearchOffset(_ literal: [UInt8]) -> Bool? {
            guard literal.count <= data.count - searchOffset else {
                return false
            }
            if asciiCaseInsensitive {
                for index in literal.indices
                    where rgSwiftASCIILower(base[searchOffset + index]) != literal[index] {
                    return false
                }
            } else {
                for index in literal.indices where base[searchOffset + index] != literal[index] {
                    return false
                }
            }
            return isASCIIWordBoundaryMatch(
                base: base,
                dataCount: data.count,
                matchStart: searchOffset,
                matchEnd: searchOffset + literal.count
            )
        }

        while searchOffset < data.count,
              matchedLineCount < limit {
            var bestStart = Int.max
            var bestEnd = Int.max
            var needsFallback = false

            for literal in searchLiterals {
                guard let bounded = matchAtSearchOffset(literal) else {
                    needsFallback = true
                    break
                }
                if bounded {
                    bestStart = searchOffset
                    bestEnd = searchOffset + literal.count
                    break
                }
            }

            if bestStart == Int.max, !needsFallback {
                for literalIndex in searchLiterals.indices {
                    let literal = searchLiterals[literalIndex]
                    literal.withUnsafeBufferPointer { needle in
                        guard !needsFallback,
                              let needleBase = needle.baseAddress else {
                            return
                        }
                        var literalSearchOffset = searchOffset
                        while literalSearchOffset < data.count {
                            let found: UnsafePointer<UInt8>?
                            if asciiCaseInsensitive {
                                found = caseInsensitiveShifts[literalIndex].withUnsafeBufferPointer { shifts in
                                    rg_memcasemem_ascii_prepared(
                                        base.advanced(by: literalSearchOffset),
                                        data.count - literalSearchOffset,
                                        needleBase,
                                        literal.count,
                                        shifts.baseAddress
                                    )
                                }
                            } else {
                                found = rg_memmem_simple(
                                    base.advanced(by: literalSearchOffset),
                                    data.count - literalSearchOffset,
                                    needleBase,
                                    literal.count
                                )
                            }
                            guard let found else {
                                break
                            }

                            let matchStart = base.distance(to: found)
                            let matchEnd = matchStart + literal.count
                            guard let bounded = isASCIIWordBoundaryMatch(
                                base: base,
                                dataCount: data.count,
                                matchStart: matchStart,
                                matchEnd: matchEnd
                            ) else {
                                needsFallback = true
                                return
                            }
                            if bounded {
                                if matchStart < bestStart {
                                    bestStart = matchStart
                                    bestEnd = matchEnd
                                }
                                break
                            }

                            rejectedBoundaryCandidates += 1
                            if let maxRejectedBoundaryCandidates,
                               rejectedBoundaryCandidates > maxRejectedBoundaryCandidates {
                                needsFallback = true
                                return
                            }
                            literalSearchOffset = rgSwiftNextASCIIWordSearchOffset(
                                base: base,
                                dataCount: data.count,
                                matchEnd: matchEnd
                            )
                        }
                    }
                    if needsFallback {
                        return nil
                    }
                }
            }
            if needsFallback {
                return nil
            }

            guard bestStart != Int.max else {
                break
            }

            var lineStart = bestStart == searchOffset ? searchOffset : bestStart
            if lineStart != searchOffset {
                while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
                    lineStart -= 1
                }
            }
            let newline = memchr(
                base.advanced(by: bestEnd),
                Int32(UInt8(ascii: "\n")),
                data.count - bestEnd
            )
            let lineEnd = newline.map {
                base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
            } ?? data.count
            let outputEnd = newline == nil ? data.count : lineEnd + 1

            if simpleOutput {
                if pendingOutputStart != nil,
                   pendingOutputEnd != lineStart || pendingNeedsFinalNewline {
                    guard flushPendingSimpleOutput() else {
                        return nil
                    }
                    pendingOutputStart = lineStart
                } else if pendingOutputStart == nil {
                    pendingOutputStart = lineStart
                }
                pendingOutputEnd = outputEnd
                pendingNeedsFinalNewline = newline == nil
                matchedLineCount += 1
                searchOffset = outputEnd
                continue
            }

            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
                return nil
            }
            guard output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber {
                currentLineNumber += rg_memcount_byte(
                    base.advanced(by: lineCountOffset),
                    lineStart - lineCountOffset,
                    UInt8(ascii: "\n")
                )
                lineCountOffset = lineStart
                guard output.writeLineNumberPrefix(
                    currentLineNumber,
                    fieldSeparator: lineNumberFieldSeparator
                ) else {
                    return nil
                }
            }
            guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
                return nil
            }
            if newline == nil,
               !output.writeByte(UInt8(ascii: "\n")) {
                return nil
            }

            matchedLineCount += 1
            searchOffset = outputEnd
        }

        guard flushPendingSimpleOutput() else {
            return nil
        }
        guard output.flush() else {
            return nil
        }
        return matchedLineCount
    }
}

private func asciiCaseInsensitiveWordMatched(
    path: String,
    literal: [UInt8]
) -> Bool? {
    guard !literal.isEmpty else {
        return nil
    }

    let fd = path.withCString { Darwin.open($0, O_RDONLY) }
    guard fd >= 0 else {
        return nil
    }
    defer {
        Darwin.close(fd)
    }

    var fileStat = stat()
    guard Darwin.fstat(fd, &fileStat) == 0 else {
        return nil
    }
    guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
        return nil
    }
    guard fileStat.st_size > 0 else {
        return false
    }
    guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
        return nil
    }

    let haystackLength = Int(fileStat.st_size)
    guard let mapped = Darwin.mmap(nil, haystackLength, PROT_READ, MAP_PRIVATE, fd, 0),
          mapped != MAP_FAILED else {
        return nil
    }
    defer {
        Darwin.munmap(mapped, haystackLength)
    }

    return literal.withUnsafeBufferPointer { literalBuffer in
        rgSwiftDarwinContainsASCIICaseInsensitiveWord(
            UnsafeRawPointer(mapped).assumingMemoryBound(to: UInt8.self),
            haystackLength: haystackLength,
            literal: literalBuffer
        )
    }
}

private func isASCIIWordBoundaryMatch(
    base: UnsafePointer<UInt8>,
    dataCount: Int,
    matchStart: Int,
    matchEnd: Int
) -> Bool? {
    if matchStart > 0 {
        let before = base[matchStart - 1]
        if before >= 0x80 {
            return nil
        }
        if rgSwiftIsASCIIRegexWordByte(before) {
            return false
        }
    }
    if matchEnd < dataCount {
        let after = base[matchEnd]
        if after >= 0x80 {
            return nil
        }
        if rgSwiftIsASCIIRegexWordByte(after) {
            return false
        }
    }
    return true
}

@inline(__always)
private func rgSwiftNextASCIIWordSearchOffset(
    base: UnsafePointer<UInt8>,
    dataCount: Int,
    matchEnd: Int
) -> Int {
    var offset = matchEnd
    while offset < dataCount,
          rgSwiftIsASCIIRegexWordByte(base[offset]) {
        offset += 1
    }
    return offset
}

private func rgSwiftContainsNonASCIIByte(_ base: UnsafePointer<UInt8>, count: Int) -> Bool {
    let highBit = SIMD16<UInt8>(repeating: 0x80)
    var offset = 0
    let vectorLimit = count >= 16 ? count - 15 : 0
    while offset < vectorLimit {
        let bytes = UnsafeRawPointer(base.advanced(by: offset))
            .loadUnaligned(as: SIMD16<UInt8>.self)
        let highMask = bytes .>= highBit
        if highMask._storage.min() < 0 {
            return true
        }
        offset += 16
    }
    while offset < count {
        if base[offset] >= 0x80 {
            return true
        }
        offset += 1
    }
    return false
}

private func rgSwiftDarwinFindASCIICaseInsensitiveByte(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    foldedByte: UInt8
) -> UnsafePointer<UInt8>? {
    let needles: [UInt8]
    if foldedByte >= UInt8(ascii: "a"),
       foldedByte <= UInt8(ascii: "z") {
        needles = [foldedByte, foldedByte - (UInt8(ascii: "a") - UInt8(ascii: "A"))]
    } else {
        needles = [foldedByte]
    }
    return needles.withUnsafeBufferPointer { needleBuffer in
        rg_memchr_any_bytes(
            base,
            haystackLength,
            needleBuffer.baseAddress,
            needleBuffer.count
        )
    }
}

private func rgSwiftDarwinContainsASCIICaseInsensitiveWord(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>
) -> Bool? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    let foldedLiteral = (0..<literal.count).map { rgSwiftASCIILower(literalBase[$0]) }
    if foldedLiteral.count == 1 {
        var searchOffset = 0
        var rejectedBoundaryCandidates = 0
        let maxRejectedBoundaryCandidates = 128
        while searchOffset < haystackLength {
            guard let found = rgSwiftDarwinFindASCIICaseInsensitiveByte(
                base.advanced(by: searchOffset),
                haystackLength: haystackLength - searchOffset,
                foldedByte: foldedLiteral[0]
            ) else {
                if memchr(base, 0, haystackLength) != nil
                    || rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
                    return nil
                }
                return false
            }
            let matchStart = base.distance(to: found)
            guard let bounded = isASCIIWordBoundaryMatch(
                base: base,
                dataCount: haystackLength,
                matchStart: matchStart,
                matchEnd: matchStart + 1
            ) else {
                return nil
            }
            if bounded {
                return true
            }
            rejectedBoundaryCandidates += 1
            guard rejectedBoundaryCandidates <= maxRejectedBoundaryCandidates else {
                return nil
            }
            searchOffset = matchStart + 1
        }
        if memchr(base, 0, haystackLength) != nil
            || rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
            return nil
        }
        return false
    }
    var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
    if foldedLiteral.count > 1 {
        for index in 0..<(foldedLiteral.count - 1) {
            caseInsensitiveShifts[Int(foldedLiteral[index])] = literal.count - 1 - index
        }
    }

    var searchOffset = 0
    var rejectedBoundaryCandidates = 0
    let maxRejectedBoundaryCandidates = 128
    while searchOffset < haystackLength {
        let found = foldedLiteral.withUnsafeBufferPointer { foldedNeedle in
            caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                rg_memcasemem_ascii_prepared(
                    base.advanced(by: searchOffset),
                    haystackLength - searchOffset,
                    foldedNeedle.baseAddress,
                    foldedNeedle.count,
                    shifts.baseAddress
                )
            }
        }
        guard let found else {
            if memchr(base, 0, haystackLength) != nil
                || rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
                return nil
            }
            return false
        }

        let matchStart = base.distance(to: found)
        let matchEnd = matchStart + literal.count
        guard let bounded = isASCIIWordBoundaryMatch(
            base: base,
            dataCount: haystackLength,
            matchStart: matchStart,
            matchEnd: matchEnd
        ) else {
            return nil
        }
        if bounded {
            return true
        }

        rejectedBoundaryCandidates += 1
        guard rejectedBoundaryCandidates <= maxRejectedBoundaryCandidates else {
            return nil
        }
        searchOffset = matchStart + 1
    }
    if memchr(base, 0, haystackLength) != nil
        || rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
        return nil
    }
    return false
}

@inline(__always)
private func rgSwiftASCIILower(_ byte: UInt8) -> UInt8 {
    byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
        ? byte + (UInt8(ascii: "a") - UInt8(ascii: "A"))
        : byte
}

private struct rgSwiftStdoutBuffer {
    private let storage: UnsafeMutablePointer<UInt8>
    private var length = 0
    private let capacity: Int
    private(set) var statsBytesWritten = 0

    init?(capacity: Int) {
        guard capacity > 0 else {
            return nil
        }
        self.capacity = capacity
        self.storage = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    mutating func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard count > 0 else {
            return true
        }
        if count > capacity {
            guard flush() else {
                return false
            }
            guard fwrite(bytes, 1, count, Darwin.stdout) == count else {
                return false
            }
            statsBytesWritten += count
            return true
        }
        if length + count > capacity, !flush() {
            return false
        }
        storage.advanced(by: length).update(from: bytes, count: count)
        length += count
        statsBytesWritten += count
        return true
    }

    mutating func writeByte(_ byte: UInt8) -> Bool {
        if length == capacity, !flush() {
            return false
        }
        storage[length] = byte
        length += 1
        // Rust stats do not count the synthesized line terminator added for
        // matching files that do not end in a newline.
        return true
    }

    mutating func writeBytes(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else {
            return true
        }
        return bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return true
            }
            return write(baseAddress, count: buffer.count)
        }
    }

    mutating func writeHeadingPrefix(
        _ headingPrefix: [UInt8],
        emittedHeading: inout Bool
    ) -> Bool {
        guard !emittedHeading else {
            return true
        }
        emittedHeading = true
        return writeBytes(headingPrefix)
    }

    mutating func writeLineNumberPrefix(_ value: Int, fieldSeparator: [UInt8]) -> Bool {
        let wroteNumber = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
            var cursor = buffer.count
            var number = value
            repeat {
                cursor -= 1
                buffer[cursor] = UInt8(number % 10) + UInt8(ascii: "0")
                number /= 10
            } while number > 0
            return write(
                buffer.baseAddress!.advanced(by: cursor),
                count: buffer.count - cursor
            )
        }
        guard wroteNumber else {
            return false
        }
        return fieldSeparator.withUnsafeBufferPointer { separator in
            guard let baseAddress = separator.baseAddress,
                  separator.count > 0 else {
                return true
            }
            return write(baseAddress, count: separator.count)
        }
    }

    mutating func flush() -> Bool {
        guard length > 0 else {
            return true
        }
        let written = fwrite(storage, 1, length, Darwin.stdout)
        guard written == length else {
            return false
        }
        length = 0
        return true
    }

    func deallocate() {
        storage.deallocate()
    }
}

private final class rgSwiftLazyStdoutBuffer {
    private var buffer: rgSwiftStdoutBuffer?
    private let capacity: Int

    init?(capacity: Int, allocateImmediately: Bool) {
        self.capacity = capacity
        if allocateImmediately {
            guard let buffer = rgSwiftStdoutBuffer(capacity: capacity) else {
                return nil
            }
            self.buffer = buffer
        }
    }

    private func ensureBuffer() -> Bool {
        guard buffer == nil else {
            return true
        }
        guard let buffer = rgSwiftStdoutBuffer(capacity: capacity) else {
            return false
        }
        self.buffer = buffer
        return true
    }

    func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard ensureBuffer(),
              var buffer else {
            return false
        }
        let wrote = buffer.write(bytes, count: count)
        self.buffer = buffer
        return wrote
    }

    func writeByte(_ byte: UInt8) -> Bool {
        guard ensureBuffer(),
              var buffer else {
            return false
        }
        let wrote = buffer.writeByte(byte)
        self.buffer = buffer
        return wrote
    }

    func writeBytes(_ bytes: [UInt8]) -> Bool {
        guard ensureBuffer(),
              var buffer else {
            return false
        }
        let wrote = buffer.writeBytes(bytes)
        self.buffer = buffer
        return wrote
    }

    func writeHeadingPrefix(_ headingPrefix: [UInt8], emittedHeading: inout Bool) -> Bool {
        guard ensureBuffer(),
              var buffer else {
            return false
        }
        let wrote = buffer.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading)
        self.buffer = buffer
        return wrote
    }

    func writeLineNumberPrefix(_ value: Int, fieldSeparator: [UInt8]) -> Bool {
        guard ensureBuffer(),
              var buffer else {
            return false
        }
        let wrote = buffer.writeLineNumberPrefix(value, fieldSeparator: fieldSeparator)
        self.buffer = buffer
        return wrote
    }

    func flush() -> Bool {
        guard var buffer else {
            return true
        }
        let flushed = buffer.flush()
        self.buffer = buffer
        return flushed
    }

    var statsBytesWritten: Int {
        buffer?.statsBytesWritten ?? 0
    }

    func deallocate() {
        buffer?.deallocate()
        buffer = nil
    }
}

private func rgSwiftDarwinWriteLiteralBytes(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    asciiBoundary: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8],
    emitLines: Bool = true,
    maxCount: Int = Int.max,
    requireASCIIHaystack: Bool = false,
    knownTextHaystack: Bool = false
) -> LiteralLineWriteStats? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0,
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if !asciiCaseInsensitive,
       rg_memmem_simple(base, haystackLength, literalBase, literal.count) == nil {
        return LiteralLineWriteStats(
            matchedLines: 0,
            bytesPrinted: 0,
            bytesSearched: haystackLength
        )
    }
    let simpleLineOutput = emitLines && !lineNumber && linePrefix.isEmpty && headingPrefix.isEmpty
    let output: rgSwiftLazyStdoutBuffer?
    if emitLines {
        guard let lazyOutput = rgSwiftLazyStdoutBuffer(
            capacity: 1024 * 1024,
            allocateImmediately: !simpleLineOutput
        ) else {
            return nil
        }
        output = lazyOutput
    } else {
        output = nil
    }
    defer {
        output?.deallocate()
    }

    var foldedLiteral: [UInt8] = []
    var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
    if asciiCaseInsensitive {
        foldedLiteral = (0..<literal.count).map { rgSwiftASCIILower(literalBase[$0]) }
        if foldedLiteral.count > 1 {
            for index in 0..<(foldedLiteral.count - 1) {
                caseInsensitiveShifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
            }
        }
    }

    var matchedLineCount = 0
    var lineNumberAtSearchOffset = 1
    var searchOffset = 0
    var lastEmittedLineStart = -1
    var emittedHeading = false
    var writeFailed = false
    var declinedFastPath = false
    var confirmedTextHaystack = knownTextHaystack
    var confirmedASCIIHaystack = !requireASCIIHaystack
    var bytesSearched = haystackLength
    var pendingSimpleOutputStart: Int?
    var pendingSimpleOutputEnd = 0
    var pendingSimpleOutputNeedsFinalNewline = false

    func ensureTextHaystack() -> Bool {
        if confirmedTextHaystack {
            return true
        }
        guard memchr(base, 0, haystackLength) == nil else {
            return false
        }
        confirmedTextHaystack = true
        return true
    }

    func ensureASCIIHaystack() -> Bool {
        if confirmedASCIIHaystack {
            return true
        }
        guard !rgSwiftContainsNonASCIIByte(base, count: haystackLength) else {
            return false
        }
        confirmedASCIIHaystack = true
        return true
    }

    func flushPendingSimpleOutput() -> Bool {
        guard let start = pendingSimpleOutputStart else {
            return true
        }
        guard output?.write(base.advanced(by: start), count: pendingSimpleOutputEnd - start) == true else {
            writeFailed = true
            return false
        }
        if pendingSimpleOutputNeedsFinalNewline,
           output?.writeByte(UInt8(ascii: "\n")) != true {
            writeFailed = true
            return false
        }
        pendingSimpleOutputStart = nil
        pendingSimpleOutputEnd = 0
        pendingSimpleOutputNeedsFinalNewline = false
        return true
    }

    @inline(__always)
    func isASCIIBoundaryMatch(matchStart: Int, lineStart: Int, lineEnd: Int) -> Bool {
        if matchStart > lineStart, rgSwiftIsASCIIRegexWordByte(base[matchStart - 1]) {
            return false
        }
        let matchEnd = matchStart + literal.count
        if matchEnd < lineEnd, rgSwiftIsASCIIRegexWordByte(base[matchEnd]) {
            return false
        }
        return true
    }

    func emitMatchedLine(found: UnsafePointer<UInt8>, newlinesBeforeMatch: Int) -> Bool {
        let matchStart = base.distance(to: found)
        var lineStart = matchStart
        if lineNumber, !asciiBoundary, newlinesBeforeMatch == 0 {
            // The counted search keeps searchOffset at this line's start.
            lineStart = searchOffset
        } else {
            while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
                lineStart -= 1
            }
        }

        let newline = memchr(found, Int32(UInt8(ascii: "\n")), haystackLength - matchStart)
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        if asciiBoundary,
           !isASCIIBoundaryMatch(matchStart: matchStart, lineStart: lineStart, lineEnd: lineEnd) {
            if lineNumber {
                lineNumberAtSearchOffset += newlinesBeforeMatch
            }
            searchOffset = max(matchStart + 1, searchOffset + 1)
            return true
        }

        guard ensureASCIIHaystack() else {
            declinedFastPath = true
            return false
        }
        guard ensureTextHaystack() else {
            declinedFastPath = true
            return false
        }

        if lineStart != lastEmittedLineStart {
            let outputEnd = newline.map {
                base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) + 1
            } ?? haystackLength
            if simpleLineOutput {
                if pendingSimpleOutputStart != nil,
                   pendingSimpleOutputEnd != lineStart || pendingSimpleOutputNeedsFinalNewline {
                    guard flushPendingSimpleOutput() else {
                        return false
                    }
                    pendingSimpleOutputStart = lineStart
                } else if pendingSimpleOutputStart == nil {
                    pendingSimpleOutputStart = lineStart
                }
                pendingSimpleOutputEnd = outputEnd
                pendingSimpleOutputNeedsFinalNewline = newline == nil
            } else if emitLines {
                guard output?.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) == true else {
                    writeFailed = true
                    return false
                }
                guard output?.writeBytes(linePrefix) == true else {
                    writeFailed = true
                    return false
                }
                if lineNumber {
                    let matchedLineNumber = lineNumberAtSearchOffset + newlinesBeforeMatch
                    guard output?.writeLineNumberPrefix(
                        matchedLineNumber,
                        fieldSeparator: lineNumberFieldSeparator
                    ) == true else {
                        writeFailed = true
                        return false
                    }
                    lineNumberAtSearchOffset = newline == nil
                        ? matchedLineNumber
                        : matchedLineNumber + 1
                }
                guard output?.write(base.advanced(by: lineStart), count: outputEnd - lineStart) == true else {
                    writeFailed = true
                    return false
                }
                if newline == nil,
                   output?.writeByte(UInt8(ascii: "\n")) != true {
                    writeFailed = true
                    return false
                }
            }
            matchedLineCount += 1
            lastEmittedLineStart = lineStart
            bytesSearched = outputEnd
            searchOffset = outputEnd
            return true
        }

        searchOffset = matchStart + literal.count
        return true
    }

    if asciiCaseInsensitive {
        foldedLiteral.withUnsafeBufferPointer { foldedNeedle in
            caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                while searchOffset < haystackLength && matchedLineCount < maxCount {
                    let found: UnsafePointer<UInt8>?
                    let newlinesBeforeMatch: Int
                    if lineNumber {
                        let result = rg_memcasemem_ascii_count_byte_before(
                            base.advanced(by: searchOffset),
                            haystackLength - searchOffset,
                            foldedNeedle.baseAddress,
                            foldedNeedle.count,
                            UInt8(ascii: "\n")
                        )
                        found = result.match
                        newlinesBeforeMatch = result.count
                    } else {
                        found = rg_memcasemem_ascii_prepared(
                            base.advanced(by: searchOffset),
                            haystackLength - searchOffset,
                            foldedNeedle.baseAddress,
                            foldedNeedle.count,
                            shifts.baseAddress
                        )
                        newlinesBeforeMatch = 0
                    }
                    guard let found else {
                        break
                    }
                    guard emitMatchedLine(found: found, newlinesBeforeMatch: newlinesBeforeMatch) else {
                        break
                    }
                }
            }
        }
    } else {
        while searchOffset < haystackLength && matchedLineCount < maxCount {
            let found: UnsafePointer<UInt8>?
            let newlinesBeforeMatch: Int
            if lineNumber {
                let result = rg_memmem_count_byte_before(
                    base.advanced(by: searchOffset),
                    haystackLength - searchOffset,
                    literalBase,
                    literal.count,
                    UInt8(ascii: "\n")
                )
                found = result.match
                newlinesBeforeMatch = result.count
            } else {
                found = rg_memmem_simple(
                    base.advanced(by: searchOffset),
                    haystackLength - searchOffset,
                    literalBase,
                    literal.count
                )
                newlinesBeforeMatch = 0
            }
            guard let found else {
                break
            }
            guard emitMatchedLine(found: found, newlinesBeforeMatch: newlinesBeforeMatch) else {
                break
            }
        }
    }

    guard !writeFailed, !declinedFastPath else {
        return nil
    }
    if matchedLineCount < maxCount {
        bytesSearched = haystackLength
    }
    if simpleLineOutput {
        guard flushPendingSimpleOutput() else {
            return nil
        }
    }
    if emitLines {
        guard output?.flush() ?? true else {
            return nil
        }
    }
    return LiteralLineWriteStats(
        matchedLines: matchedLineCount,
        bytesPrinted: output?.statsBytesWritten ?? 0,
        bytesSearched: bytesSearched
    )
}

private func rgSwiftDarwinWriteStopOnNonmatchLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    maxCount: Int,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0,
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }

    guard let firstMatch = rg_memmem_simple(
        base,
        haystackLength,
        literalBase,
        literal.count
    ) else {
        return 0
    }
    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    let newline = UInt8(ascii: "\n")
    var firstLineStart = base.distance(to: firstMatch)
    while firstLineStart > 0, base[firstLineStart - 1] != newline {
        firstLineStart -= 1
    }
    var nextLineNumber = lineNumber
        ? Int(rg_memcount_byte(base, firstLineStart, newline)) + 1
        : 1
    var lineStart = firstLineStart
    var matchedLineCount = 0
    var emittedHeading = false

    func emitLine(lineStart: Int, outputEnd: Int, hasNewline: Bool) -> Bool {
        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading),
              output.writeBytes(linePrefix) else {
            return false
        }
        if lineNumber {
            guard output.writeLineNumberPrefix(
                nextLineNumber,
                fieldSeparator: lineNumberFieldSeparator
            ) else {
                return false
            }
        }
        guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
            return false
        }
        if !hasNewline,
           !output.writeByte(newline) {
            return false
        }
        return true
    }

    while matchedLineCount < maxCount,
          lineStart < haystackLength {
        let newlinePointer = memchr(base.advanced(by: lineStart), Int32(newline), haystackLength - lineStart)
        let lineEnd: Int
        let outputEnd: Int
        let hasNewline: Bool
        if let newlinePointer {
            lineEnd = base.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
            outputEnd = lineEnd + 1
            hasNewline = true
        } else {
            lineEnd = haystackLength
            outputEnd = haystackLength
            hasNewline = false
        }

        let lineLength = lineEnd - lineStart
        guard rg_memmem_simple(
            base.advanced(by: lineStart),
            lineLength,
            literalBase,
            literal.count
        ) != nil else {
            break
        }
        guard emitLine(lineStart: lineStart, outputEnd: outputEnd, hasNewline: hasNewline) else {
            return nil
        }

        matchedLineCount += 1
        nextLineNumber += 1
        lineStart = outputEnd
    }

    guard output.flush() else {
        return nil
    }
    return matchedLineCount
}

private func rgSwiftDarwinCountStopOnNonmatchLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    maxCount: Int
) -> Int? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0,
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }

    guard let firstMatch = rg_memmem_simple(
        base,
        haystackLength,
        literalBase,
        literal.count
    ) else {
        return 0
    }

    let newline = UInt8(ascii: "\n")
    var lineStart = base.distance(to: firstMatch)
    while lineStart > 0, base[lineStart - 1] != newline {
        lineStart -= 1
    }
    var matchedLineCount = 0

    while matchedLineCount < maxCount,
          lineStart < haystackLength {
        let newlinePointer = memchr(base.advanced(by: lineStart), Int32(newline), haystackLength - lineStart)
        let lineEnd: Int
        let nextLineStart: Int
        if let newlinePointer {
            lineEnd = base.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
            nextLineStart = lineEnd + 1
        } else {
            lineEnd = haystackLength
            nextLineStart = haystackLength
        }

        let lineLength = lineEnd - lineStart
        guard rg_memmem_simple(
            base.advanced(by: lineStart),
            lineLength,
            literalBase,
            literal.count
        ) != nil else {
            break
        }

        matchedLineCount += 1
        lineStart = nextLineStart
    }
    return matchedLineCount
}

private func rgSwiftDarwinWriteFixedLookbehindLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    prefix: UnsafeBufferPointer<UInt8>,
    literal: UnsafeBufferPointer<UInt8>,
    prefixShouldMatch: Bool,
    maxCount: Int,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard let prefixBase = prefix.baseAddress,
          literal.baseAddress != nil,
          prefix.count > 0,
          literal.count > 0,
          maxCount > 0 else {
        return nil
    }
    return rgSwiftDarwinWriteFixedLookaroundLines(
        base,
        haystackLength: haystackLength,
        literal: literal,
        maxCount: maxCount,
        lineNumber: lineNumber,
        lineNumberFieldSeparator: lineNumberFieldSeparator,
        linePrefix: linePrefix,
        headingPrefix: headingPrefix
    ) { matchStart in
        let hasPrefix = matchStart >= prefix.count
            && memcmp(
                base.advanced(by: matchStart - prefix.count),
                prefixBase,
                prefix.count
            ) == 0
        return hasPrefix == prefixShouldMatch
    }
}

private func rgSwiftDarwinWriteFixedLookaheadLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    suffix: UnsafeBufferPointer<UInt8>,
    suffixShouldMatch: Bool,
    maxCount: Int,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard let suffixBase = suffix.baseAddress,
          literal.baseAddress != nil,
          literal.count > 0,
          suffix.count > 0,
          maxCount > 0 else {
        return nil
    }
    return rgSwiftDarwinWriteFixedLookaroundLines(
        base,
        haystackLength: haystackLength,
        literal: literal,
        maxCount: maxCount,
        lineNumber: lineNumber,
        lineNumberFieldSeparator: lineNumberFieldSeparator,
        linePrefix: linePrefix,
        headingPrefix: headingPrefix
    ) { matchStart in
        let suffixStart = matchStart + literal.count
        let hasSuffix = suffixStart + suffix.count <= haystackLength
            && memcmp(
                base.advanced(by: suffixStart),
                suffixBase,
                suffix.count
            ) == 0
        return hasSuffix == suffixShouldMatch
    }
}

private func rgSwiftDarwinWriteFixedLookaroundLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    maxCount: Int,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8],
    assertionMatches: (Int) -> Bool
) -> Int? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0,
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    let newline = UInt8(ascii: "\n")
    var searchOffset = 0
    var matchedLineCount = 0
    var nextLineNumber = 1
    var lineScanOffset = 0
    var emittedHeading = false

    while matchedLineCount < maxCount,
          searchOffset <= haystackLength - literal.count {
        guard let found = rg_memmem_simple(
            base.advanced(by: searchOffset),
            haystackLength - searchOffset,
            literalBase,
            literal.count
        ) else {
            break
        }
        let matchStart = base.distance(to: found)
        guard assertionMatches(matchStart) else {
            searchOffset = matchStart + 1
            continue
        }

        var lineStart = matchStart
        while lineStart > 0, base[lineStart - 1] != newline {
            lineStart -= 1
        }
        let newlinePointer = memchr(found, Int32(newline), haystackLength - matchStart)
        let outputEnd: Int
        let nextSearchOffset: Int
        let hasNewline: Bool
        if let newlinePointer {
            outputEnd = base.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self)) + 1
            nextSearchOffset = outputEnd
            hasNewline = true
        } else {
            outputEnd = haystackLength
            nextSearchOffset = haystackLength
            hasNewline = false
        }

        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading),
              output.writeBytes(linePrefix) else {
            return nil
        }
        if lineNumber {
            let skippedNewlines = Int(rg_memcount_byte(
                base.advanced(by: lineScanOffset),
                lineStart - lineScanOffset,
                newline
            ))
            let matchedLineNumber = nextLineNumber + skippedNewlines
            guard output.writeLineNumberPrefix(
                matchedLineNumber,
                fieldSeparator: lineNumberFieldSeparator
            ) else {
                return nil
            }
            nextLineNumber = matchedLineNumber + 1
            lineScanOffset = nextSearchOffset
        }
        guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
            return nil
        }
        if !hasNewline,
           !output.writeByte(newline) {
            return nil
        }

        matchedLineCount += 1
        searchOffset = nextSearchOffset
    }

    guard output.flush() else {
        return nil
    }
    return matchedLineCount
}

@inline(__always)
private func rgSwiftDarwinNextLineStart(
    base: UnsafePointer<UInt8>,
    haystackLength: Int,
    from offset: Int
) -> Int {
    guard offset < haystackLength,
          let newline = memchr(
            base.advanced(by: offset),
            Int32(UInt8(ascii: "\n")),
            haystackLength - offset
          ) else {
        return haystackLength
    }
    return base.distance(to: newline.assumingMemoryBound(to: UInt8.self)) + 1
}

private func rgSwiftDarwinWriteASCIICaseInsensitiveWordOnlyMatches(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    byteOffset: Bool,
    column: Bool,
    maxCount: Int,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0,
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }
    for offset in 0..<haystackLength where base[offset] >= 0x80 {
        return nil
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    let foldedLiteral = (0..<literal.count).map { rgSwiftASCIILower(literalBase[$0]) }
    var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
    if foldedLiteral.count > 1 {
        for index in 0..<(foldedLiteral.count - 1) {
            caseInsensitiveShifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
        }
    }

    var searchOffset = 0
    var currentLineNumber = 1
    var matchCount = 0
    var matchedLineCount = 0
    var selectedLineEnd = -1
    var emittedHeading = false
    var rejectedBoundaryCandidates = 0
    let maxRejectedBoundaryCandidates = 128
    let newline = UInt8(ascii: "\n")

    while searchOffset < haystackLength {
        var found: UnsafePointer<UInt8>?
        var newlinesBeforeMatch = 0
        if asciiCaseInsensitive {
            foldedLiteral.withUnsafeBufferPointer { foldedNeedle in
                caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                    if lineNumber {
                        let result = rg_memcasemem_ascii_count_byte_before(
                            base.advanced(by: searchOffset),
                            haystackLength - searchOffset,
                            foldedNeedle.baseAddress,
                            foldedNeedle.count,
                            UInt8(ascii: "\n")
                        )
                        found = result.match
                        newlinesBeforeMatch = result.count
                    } else {
                        found = rg_memcasemem_ascii_prepared(
                            base.advanced(by: searchOffset),
                            haystackLength - searchOffset,
                            foldedNeedle.baseAddress,
                            foldedNeedle.count,
                            shifts.baseAddress
                        )
                        newlinesBeforeMatch = 0
                    }
                }
            }
        } else {
            if lineNumber {
                let result = rg_memmem_count_byte_before(
                    base.advanced(by: searchOffset),
                    haystackLength - searchOffset,
                    literalBase,
                    literal.count,
                    UInt8(ascii: "\n")
                )
                found = result.match
                newlinesBeforeMatch = result.count
            } else {
                found = rg_memmem_simple(
                    base.advanced(by: searchOffset),
                    haystackLength - searchOffset,
                    literalBase,
                    literal.count
                )
                newlinesBeforeMatch = 0
            }
        }
        guard let found else {
            break
        }

        let matchStart = base.distance(to: found)
        let matchEnd = matchStart + literal.count
        guard let bounded = isASCIIWordBoundaryMatch(
            base: base,
            dataCount: haystackLength,
            matchStart: matchStart,
            matchEnd: matchEnd
        ) else {
            return nil
        }
        let matchedLineNumber = currentLineNumber + newlinesBeforeMatch
        var matchedLineStart = 0
        if column {
            matchedLineStart = matchStart
            while matchedLineStart > 0, base[matchedLineStart - 1] != newline {
                matchedLineStart -= 1
            }
        }
        if bounded {
            if matchStart >= selectedLineEnd {
                guard matchedLineCount < maxCount else {
                    break
                }
                matchedLineCount += 1
                selectedLineEnd = rgSwiftDarwinNextLineStart(
                    base: base,
                    haystackLength: haystackLength,
                    from: matchStart
                )
            }
            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
                return nil
            }
            guard output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber,
               !output.writeLineNumberPrefix(
                matchedLineNumber,
                fieldSeparator: lineNumberFieldSeparator
               ) {
                return nil
            }
            if column,
               !output.writeLineNumberPrefix(
                matchStart - matchedLineStart + 1,
                fieldSeparator: lineNumberFieldSeparator
               ) {
                return nil
            }
            if byteOffset,
               !output.writeLineNumberPrefix(
                matchStart,
                fieldSeparator: lineNumberFieldSeparator
               ) {
                return nil
            }
            guard output.write(base.advanced(by: matchStart), count: literal.count),
                  output.writeByte(UInt8(ascii: "\n")) else {
                return nil
            }
            matchCount += 1
            currentLineNumber = matchedLineNumber
            searchOffset = matchEnd
        } else {
            rejectedBoundaryCandidates += 1
            guard rejectedBoundaryCandidates <= maxRejectedBoundaryCandidates else {
                return nil
            }
            currentLineNumber = matchedLineNumber
            searchOffset = matchStart + 1
        }
    }

    guard output.flush() else {
        return nil
    }
    return matchCount
}

private func rgSwiftDarwinWriteASCIICaseInsensitiveMultiLiteralOnlyMatches(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    foldedLiterals: [[UInt8]],
    lineNumber: Bool,
    byteOffset: Bool,
    column: Bool,
    maxCount: Int,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard maxCount > 0 else {
        return nil
    }
    guard !foldedLiterals.isEmpty else {
        return 0
    }
    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    let shifts = foldedLiterals.map { literal -> [Int] in
        var table = [Int](repeating: literal.count, count: 256)
        if literal.count > 1 {
            for index in 0..<(literal.count - 1) {
                table[Int(literal[index])] = literal.count - 1 - index
            }
        }
        return table
    }

    var searchOffset = 0
    var currentLineNumber = 1
    var lineCountOffset = 0
    var matchCount = 0
    var matchedLineCount = 0
    var selectedLineEnd = -1
    var emittedHeading = false
    var currentLineStart = 0
    let newline = UInt8(ascii: "\n")

    func advanceLineState(to matchStart: Int) {
        while lineCountOffset < matchStart {
            if base[lineCountOffset] == newline {
                currentLineNumber += 1
                currentLineStart = lineCountOffset + 1
            }
            lineCountOffset += 1
        }
    }

    while searchOffset < haystackLength {
        var bestStart = Int.max
        var bestLiteralIndex = -1

        for literalIndex in foldedLiterals.indices {
            let literal = foldedLiterals[literalIndex]
            guard literal.count <= haystackLength - searchOffset else {
                continue
            }
            let found = literal.withUnsafeBufferPointer { literalBuffer in
                shifts[literalIndex].withUnsafeBufferPointer { shiftBuffer in
                    rg_memcasemem_ascii_prepared(
                        base.advanced(by: searchOffset),
                        haystackLength - searchOffset,
                        literalBuffer.baseAddress,
                        literalBuffer.count,
                        shiftBuffer.baseAddress
                    )
                }
            }
            guard let found else {
                continue
            }
            let matchStart = base.distance(to: found)
            if matchStart < bestStart {
                bestStart = matchStart
                bestLiteralIndex = literalIndex
            }
        }

        guard bestLiteralIndex >= 0 else {
            break
        }

        let literalLength = foldedLiterals[bestLiteralIndex].count
        if bestStart >= selectedLineEnd {
            guard matchedLineCount < maxCount else {
                break
            }
            matchedLineCount += 1
            selectedLineEnd = rgSwiftDarwinNextLineStart(
                base: base,
                haystackLength: haystackLength,
                from: bestStart
            )
        }
        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
            return nil
        }
        guard output.writeBytes(linePrefix) else {
            return nil
        }
        if column {
            advanceLineState(to: bestStart)
        }
        if lineNumber {
            if column {
                guard output.writeLineNumberPrefix(
                    currentLineNumber,
                    fieldSeparator: lineNumberFieldSeparator
                ) else {
                    return nil
                }
            } else {
                currentLineNumber += rg_memcount_byte(
                    base.advanced(by: lineCountOffset),
                    bestStart - lineCountOffset,
                    newline
                )
                lineCountOffset = bestStart
                guard output.writeLineNumberPrefix(
                    currentLineNumber,
                    fieldSeparator: lineNumberFieldSeparator
                ) else {
                    return nil
                }
            }
        }
        if column,
           !output.writeLineNumberPrefix(
            bestStart - currentLineStart + 1,
            fieldSeparator: lineNumberFieldSeparator
           ) {
            return nil
        }
        if byteOffset,
           !output.writeLineNumberPrefix(
            bestStart,
            fieldSeparator: lineNumberFieldSeparator
           ) {
            return nil
        }
        guard output.write(base.advanced(by: bestStart), count: literalLength),
              output.writeByte(UInt8(ascii: "\n")) else {
            return nil
        }
        matchCount += 1
        searchOffset = bestStart + literalLength
    }

    guard output.flush() else {
        return nil
    }
    return matchCount
}

private func rgSwiftDarwinWriteMultiLiteralOnlyMatches(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]],
    lineNumber: Bool,
    byteOffset: Bool,
    column: Bool,
    maxCount: Int,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8],
    emitMatches: Bool = true
) -> Int? {
    guard maxCount > 0 else {
        return nil
    }
    guard !literals.isEmpty else {
        return 0
    }
    var output = emitMatches ? rgSwiftStdoutBuffer(capacity: 1024 * 1024) : nil
    if emitMatches, output == nil {
        return nil
    }
    defer {
        output?.deallocate()
    }

    func nextCandidate(literalIndex: Int, from offset: Int) -> (start: Int, literalIndex: Int) {
        let safeOffset = min(offset, haystackLength)
        let literal = literals[literalIndex]
        guard literal.count <= haystackLength - safeOffset else {
            return (Int.max, literalIndex)
        }
        let found = literal.withUnsafeBufferPointer { literalBuffer in
            rg_memmem_simple(
                base.advanced(by: safeOffset),
                haystackLength - safeOffset,
                literalBuffer.baseAddress,
                literalBuffer.count
            )
        }
        guard let found else {
            return (Int.max, literalIndex)
        }
        return (base.distance(to: found), literalIndex)
    }

    func earliestCandidateIndex(in candidates: [(start: Int, literalIndex: Int)]) -> Int? {
        var selectedIndex: Int?
        var selectedStart = Int.max
        for index in candidates.indices where candidates[index].start < selectedStart {
            selectedStart = candidates[index].start
            selectedIndex = index
        }
        return selectedStart == Int.max ? nil : selectedIndex
    }

    var candidates = literals.indices.map {
        nextCandidate(literalIndex: $0, from: 0)
    }
    var currentLineNumber = 1
    var lineCountOffset = 0
    var matchCount = 0
    var matchedLineCount = 0
    var selectedLineEnd = -1
    var emittedHeading = false
    var currentLineStart = 0
    let newline = UInt8(ascii: "\n")

    func advanceLineState(to matchStart: Int) {
        while lineCountOffset < matchStart {
            if base[lineCountOffset] == newline {
                currentLineNumber += 1
                currentLineStart = lineCountOffset + 1
            }
            lineCountOffset += 1
        }
    }

    while let candidateIndex = earliestCandidateIndex(in: candidates) {
        let matchStart = candidates[candidateIndex].start
        guard matchStart < haystackLength else {
            break
        }
        let literalLength = literals[candidates[candidateIndex].literalIndex].count
        let nextSearchOffset = matchStart + literalLength
        if matchStart >= selectedLineEnd {
            guard matchedLineCount < maxCount else {
                break
            }
            matchedLineCount += 1
            selectedLineEnd = rgSwiftDarwinNextLineStart(
                base: base,
                haystackLength: haystackLength,
                from: matchStart
            )
        }

        if emitMatches {
            guard output?.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) == true else {
                return nil
            }
            guard output?.writeBytes(linePrefix) == true else {
                return nil
            }
            if column {
                advanceLineState(to: matchStart)
            }
            if lineNumber {
                if column {
                    guard output?.writeLineNumberPrefix(
                        currentLineNumber,
                        fieldSeparator: lineNumberFieldSeparator
                    ) == true else {
                        return nil
                    }
                } else {
                    currentLineNumber += rg_memcount_byte(
                        base.advanced(by: lineCountOffset),
                        matchStart - lineCountOffset,
                        newline
                    )
                    lineCountOffset = matchStart
                    guard output?.writeLineNumberPrefix(
                        currentLineNumber,
                        fieldSeparator: lineNumberFieldSeparator
                    ) == true else {
                        return nil
                    }
                }
            }
            if column,
               output?.writeLineNumberPrefix(
                matchStart - currentLineStart + 1,
                fieldSeparator: lineNumberFieldSeparator
               ) != true {
                return nil
            }
            if byteOffset,
               output?.writeLineNumberPrefix(
                matchStart,
                fieldSeparator: lineNumberFieldSeparator
               ) != true {
                return nil
            }
            guard output?.write(base.advanced(by: matchStart), count: literalLength) == true,
                  output?.writeByte(UInt8(ascii: "\n")) == true else {
                return nil
            }
        }
        matchCount += 1

        for index in candidates.indices where candidates[index].start < nextSearchOffset {
            candidates[index] = nextCandidate(
                literalIndex: candidates[index].literalIndex,
                from: nextSearchOffset
            )
        }
    }

    if emitMatches {
        guard output?.flush() == true else {
            return nil
        }
    }
    return matchCount
}

private func rgSwiftDarwinCountMultiLiteralOnlyMatchesAndLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]],
    maxCount: Int
) -> LiteralMatchedLineAndMatchCounts? {
    guard maxCount > 0 else {
        return nil
    }
    guard !literals.isEmpty else {
        return LiteralMatchedLineAndMatchCounts(matchedLines: 0, totalMatches: 0)
    }

    func nextCandidate(literalIndex: Int, from offset: Int) -> (start: Int, literalIndex: Int) {
        let safeOffset = min(offset, haystackLength)
        let literal = literals[literalIndex]
        guard literal.count <= haystackLength - safeOffset else {
            return (Int.max, literalIndex)
        }
        let found = literal.withUnsafeBufferPointer { literalBuffer in
            rg_memmem_simple(
                base.advanced(by: safeOffset),
                haystackLength - safeOffset,
                literalBuffer.baseAddress,
                literalBuffer.count
            )
        }
        guard let found else {
            return (Int.max, literalIndex)
        }
        return (base.distance(to: found), literalIndex)
    }

    func earliestCandidateIndex(in candidates: [(start: Int, literalIndex: Int)]) -> Int? {
        var selectedIndex: Int?
        var selectedStart = Int.max
        for index in candidates.indices where candidates[index].start < selectedStart {
            selectedStart = candidates[index].start
            selectedIndex = index
        }
        return selectedStart == Int.max ? nil : selectedIndex
    }

    var candidates = literals.indices.map {
        nextCandidate(literalIndex: $0, from: 0)
    }
    var matchCount = 0
    var matchedLineCount = 0
    var selectedLineEnd = -1

    while let candidateIndex = earliestCandidateIndex(in: candidates) {
        let matchStart = candidates[candidateIndex].start
        guard matchStart < haystackLength else {
            break
        }
        let literalLength = literals[candidates[candidateIndex].literalIndex].count
        let nextSearchOffset = matchStart + literalLength
        if matchStart >= selectedLineEnd {
            guard matchedLineCount < maxCount else {
                break
            }
            matchedLineCount += 1
            selectedLineEnd = rgSwiftDarwinNextLineStart(
                base: base,
                haystackLength: haystackLength,
                from: matchStart
            )
        }
        matchCount += 1

        for index in candidates.indices where candidates[index].start < nextSearchOffset {
            candidates[index] = nextCandidate(
                literalIndex: candidates[index].literalIndex,
                from: nextSearchOffset
            )
        }
    }

    return LiteralMatchedLineAndMatchCounts(
        matchedLines: matchedLineCount,
        totalMatches: matchCount
    )
}

private func rgSwiftDarwinCountMultiLiteralOnlyMatches(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]]
) -> Int? {
    guard !literals.isEmpty else {
        return 0
    }

    func nextCandidate(literalIndex: Int, from offset: Int) -> (start: Int, literalIndex: Int) {
        let safeOffset = min(offset, haystackLength)
        let literal = literals[literalIndex]
        guard literal.count <= haystackLength - safeOffset else {
            return (Int.max, literalIndex)
        }
        let found = literal.withUnsafeBufferPointer { literalBuffer in
            rg_memmem_simple(
                base.advanced(by: safeOffset),
                haystackLength - safeOffset,
                literalBuffer.baseAddress,
                literalBuffer.count
            )
        }
        guard let found else {
            return (Int.max, literalIndex)
        }
        return (base.distance(to: found), literalIndex)
    }

    func earliestCandidateIndex(in candidates: [(start: Int, literalIndex: Int)]) -> Int? {
        var selectedIndex: Int?
        var selectedStart = Int.max
        for index in candidates.indices where candidates[index].start < selectedStart {
            selectedStart = candidates[index].start
            selectedIndex = index
        }
        return selectedStart == Int.max ? nil : selectedIndex
    }

    var candidates = literals.indices.map {
        nextCandidate(literalIndex: $0, from: 0)
    }
    var matchCount = 0

    while let candidateIndex = earliestCandidateIndex(in: candidates) {
        let matchStart = candidates[candidateIndex].start
        guard matchStart < haystackLength else {
            break
        }
        let literalLength = literals[candidates[candidateIndex].literalIndex].count
        let nextSearchOffset = matchStart + literalLength
        matchCount += 1

        for index in candidates.indices where candidates[index].start < nextSearchOffset {
            candidates[index] = nextCandidate(
                literalIndex: candidates[index].literalIndex,
                from: nextSearchOffset
            )
        }
    }

    return matchCount
}

private func rgSwiftDarwinWriteMultiLiteralVimgrepLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]],
    asciiCaseInsensitive: Bool,
    wordBoundary: Bool = false,
    lineNumber: Bool,
    column: Bool,
    byteOffset: Bool,
    maxCount: Int,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8]
) -> Int? {
    guard maxCount > 0 else {
        return nil
    }
    guard !literals.isEmpty else {
        return 0
    }
    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    let shifts = asciiCaseInsensitive
        ? literals.map { literal -> [Int] in
            var table = [Int](repeating: literal.count, count: 256)
            if literal.count > 1 {
                for index in 0..<(literal.count - 1) {
                    table[Int(literal[index])] = literal.count - 1 - index
                }
            }
            return table
        }
        : []

    func nextCandidate(literalIndex: Int, from offset: Int) -> (start: Int, literalIndex: Int) {
        let safeOffset = min(offset, haystackLength)
        let literal = literals[literalIndex]
        guard literal.count <= haystackLength - safeOffset else {
            return (Int.max, literalIndex)
        }
        let found = literal.withUnsafeBufferPointer { literalBuffer -> UnsafePointer<UInt8>? in
            if asciiCaseInsensitive {
                return shifts[literalIndex].withUnsafeBufferPointer { shiftBuffer in
                    rg_memcasemem_ascii_prepared(
                        base.advanced(by: safeOffset),
                        haystackLength - safeOffset,
                        literalBuffer.baseAddress,
                        literalBuffer.count,
                        shiftBuffer.baseAddress
                    )
                }
            }
            return rg_memmem_simple(
                base.advanced(by: safeOffset),
                haystackLength - safeOffset,
                literalBuffer.baseAddress,
                literalBuffer.count
            )
        }
        guard let found else {
            return (Int.max, literalIndex)
        }
        return (base.distance(to: found), literalIndex)
    }

    func earliestCandidateIndex(in candidates: [(start: Int, literalIndex: Int)]) -> Int? {
        var selectedIndex: Int?
        var selectedStart = Int.max
        for index in candidates.indices where candidates[index].start < selectedStart {
            selectedStart = candidates[index].start
            selectedIndex = index
        }
        return selectedStart == Int.max ? nil : selectedIndex
    }

    var candidates = literals.indices.map {
        nextCandidate(literalIndex: $0, from: 0)
    }
    var currentLineNumber = 1
    var currentLineStart = 0
    var lineCountOffset = 0
    var matchCount = 0
    var matchedLineCount = 0
    var selectedLineEnd = -1
    let newline = UInt8(ascii: "\n")

    func advanceLineState(to matchStart: Int) {
        while lineCountOffset < matchStart {
            if base[lineCountOffset] == newline {
                currentLineNumber += 1
                currentLineStart = lineCountOffset + 1
            }
            lineCountOffset += 1
        }
    }

    while let candidateIndex = earliestCandidateIndex(in: candidates) {
        let matchStart = candidates[candidateIndex].start
        guard matchStart < haystackLength else {
            break
        }
        let literalIndex = candidates[candidateIndex].literalIndex
        let literalLength = literals[literalIndex].count
        let matchEnd = matchStart + literalLength
        if wordBoundary {
            guard let bounded = isASCIIWordBoundaryMatch(
                base: base,
                dataCount: haystackLength,
                matchStart: matchStart,
                matchEnd: matchEnd
            ) else {
                return nil
            }
            guard bounded else {
                candidates[candidateIndex] = nextCandidate(
                    literalIndex: literalIndex,
                    from: matchStart + 1
                )
                continue
            }
        }

        if matchStart >= selectedLineEnd {
            guard matchedLineCount < maxCount else {
                break
            }
            matchedLineCount += 1
            selectedLineEnd = rgSwiftDarwinNextLineStart(
                base: base,
                haystackLength: haystackLength,
                from: matchStart
            )
        }

        advanceLineState(to: matchStart)
        let lineOutputEnd = if selectedLineEnd > currentLineStart,
                               selectedLineEnd <= haystackLength,
                               base[selectedLineEnd - 1] == newline {
            selectedLineEnd - 1
        } else {
            selectedLineEnd
        }

        guard output.writeBytes(linePrefix) else {
            return nil
        }
        if lineNumber,
           !output.writeLineNumberPrefix(
                currentLineNumber,
                fieldSeparator: lineNumberFieldSeparator
           ) {
            return nil
        }
        if column,
           !output.writeLineNumberPrefix(
                matchStart - currentLineStart + 1,
                fieldSeparator: lineNumberFieldSeparator
           ) {
            return nil
        }
        if byteOffset,
           !output.writeLineNumberPrefix(
            matchStart,
            fieldSeparator: lineNumberFieldSeparator
           ) {
            return nil
        }
        guard output.write(
            base.advanced(by: currentLineStart),
            count: lineOutputEnd - currentLineStart
        ),
              output.writeByte(newline) else {
            return nil
        }
        matchCount += 1

        for index in candidates.indices where candidates[index].start < matchEnd {
            candidates[index] = nextCandidate(
                literalIndex: candidates[index].literalIndex,
                from: matchEnd
            )
        }
    }

    guard output.flush() else {
        return nil
    }
    return matchCount
}

private func rgSwiftDarwinWriteMultiLiteralWordOnlyMatches(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]],
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    byteOffset: Bool,
    column: Bool,
    maxCount: Int,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard maxCount > 0 else {
        return nil
    }
    guard !literals.isEmpty else {
        return 0
    }
    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    let shifts = asciiCaseInsensitive
        ? literals.map { literal -> [Int] in
            var table = [Int](repeating: literal.count, count: 256)
            if literal.count > 1 {
                for index in 0..<(literal.count - 1) {
                    table[Int(literal[index])] = literal.count - 1 - index
                }
            }
            return table
        }
        : []

    func nextCandidate(literalIndex: Int, from offset: Int) -> (start: Int, literalIndex: Int) {
        let safeOffset = min(offset, haystackLength)
        let literal = literals[literalIndex]
        guard literal.count <= haystackLength - safeOffset else {
            return (Int.max, literalIndex)
        }
        let found = literal.withUnsafeBufferPointer { literalBuffer -> UnsafePointer<UInt8>? in
            if asciiCaseInsensitive {
                return shifts[literalIndex].withUnsafeBufferPointer { shiftBuffer in
                    rg_memcasemem_ascii_prepared(
                        base.advanced(by: safeOffset),
                        haystackLength - safeOffset,
                        literalBuffer.baseAddress,
                        literalBuffer.count,
                        shiftBuffer.baseAddress
                    )
                }
            }
            return rg_memmem_simple(
                base.advanced(by: safeOffset),
                haystackLength - safeOffset,
                literalBuffer.baseAddress,
                literalBuffer.count
            )
        }
        guard let found else {
            return (Int.max, literalIndex)
        }
        return (base.distance(to: found), literalIndex)
    }

    func earliestCandidateIndex(in candidates: [(start: Int, literalIndex: Int)]) -> Int? {
        var selectedIndex: Int?
        var selectedStart = Int.max
        for index in candidates.indices where candidates[index].start < selectedStart {
            selectedStart = candidates[index].start
            selectedIndex = index
        }
        return selectedStart == Int.max ? nil : selectedIndex
    }

    var candidates = literals.indices.map {
        nextCandidate(literalIndex: $0, from: 0)
    }
    var currentLineNumber = 1
    var lineCountOffset = 0
    var matchCount = 0
    var matchedLineCount = 0
    var selectedLineEnd = -1
    var emittedHeading = false
    var currentLineStart = 0
    let newline = UInt8(ascii: "\n")

    func advanceLineState(to matchStart: Int) {
        while lineCountOffset < matchStart {
            if base[lineCountOffset] == newline {
                currentLineNumber += 1
                currentLineStart = lineCountOffset + 1
            }
            lineCountOffset += 1
        }
    }

    while let candidateIndex = earliestCandidateIndex(in: candidates) {
        let matchStart = candidates[candidateIndex].start
        guard matchStart < haystackLength else {
            break
        }
        let literalIndex = candidates[candidateIndex].literalIndex
        let literalLength = literals[literalIndex].count
        let matchEnd = matchStart + literalLength
        guard let bounded = isASCIIWordBoundaryMatch(
            base: base,
            dataCount: haystackLength,
            matchStart: matchStart,
            matchEnd: matchEnd
        ) else {
            return nil
        }

        guard bounded else {
            candidates[candidateIndex] = nextCandidate(
                literalIndex: literalIndex,
                from: matchStart + 1
            )
            continue
        }

        if matchStart >= selectedLineEnd {
            guard matchedLineCount < maxCount else {
                break
            }
            matchedLineCount += 1
            selectedLineEnd = rgSwiftDarwinNextLineStart(
                base: base,
                haystackLength: haystackLength,
                from: matchStart
            )
        }

        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
            return nil
        }
        guard output.writeBytes(linePrefix) else {
            return nil
        }
        if column {
            advanceLineState(to: matchStart)
        }
        if lineNumber {
            if column {
                guard output.writeLineNumberPrefix(
                    currentLineNumber,
                    fieldSeparator: lineNumberFieldSeparator
                ) else {
                    return nil
                }
            } else {
                currentLineNumber += rg_memcount_byte(
                    base.advanced(by: lineCountOffset),
                    matchStart - lineCountOffset,
                    UInt8(ascii: "\n")
                )
                lineCountOffset = matchStart
                guard output.writeLineNumberPrefix(
                    currentLineNumber,
                    fieldSeparator: lineNumberFieldSeparator
                ) else {
                    return nil
                }
            }
        }
        if column,
           !output.writeLineNumberPrefix(
            matchStart - currentLineStart + 1,
            fieldSeparator: lineNumberFieldSeparator
           ) {
            return nil
        }
        if byteOffset,
           !output.writeLineNumberPrefix(
            matchStart,
            fieldSeparator: lineNumberFieldSeparator
           ) {
            return nil
        }
        guard output.write(base.advanced(by: matchStart), count: literalLength),
              output.writeByte(UInt8(ascii: "\n")) else {
            return nil
        }
        matchCount += 1

        for index in candidates.indices where candidates[index].start < matchEnd {
            candidates[index] = nextCandidate(
                literalIndex: candidates[index].literalIndex,
                from: matchEnd
            )
        }
    }

    guard output.flush() else {
        return nil
    }
    return matchCount
}

private func rgSwiftDarwinWriteWordLiteralLineBytes(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard let literalBase = literal.baseAddress, literal.count > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }

    enum WordBoundaryState {
        case bounded
        case notBounded
        case needsDecodedFallback
    }

    struct PendingLine {
        let number: Int
        let start: Int
        let outputEnd: Int
        let needsFinalNewline: Bool
    }

    @inline(__always)
    func wordBoundaryState(matchStart: Int, matchEnd: Int) -> WordBoundaryState {
        if matchStart > 0 {
            let before = base[matchStart - 1]
            if before >= 0x80 {
                return .needsDecodedFallback
            }
            if rgSwiftIsASCIIRegexWordByte(before) {
                return .notBounded
            }
        }
        if matchEnd < haystackLength {
            let after = base[matchEnd]
            if after >= 0x80 {
                return .needsDecodedFallback
            }
            if rgSwiftIsASCIIRegexWordByte(after) {
                return .notBounded
            }
        }
        return .bounded
    }

    var pendingLines: [PendingLine] = []
    pendingLines.reserveCapacity(1024)
    let maxBufferedLines = 16_384
    var lineNumberAtSearchOffset = 1
    var searchOffset = 0
    var lastEmittedLineStart = -1

    while searchOffset < haystackLength {
        let result = rg_memmem_count_byte_before(
            base.advanced(by: searchOffset),
            haystackLength - searchOffset,
            literalBase,
            literal.count,
            UInt8(ascii: "\n")
        )
        guard let found = result.match else {
            break
        }

        let matchStart = base.distance(to: found)
        let matchEnd = matchStart + literal.count
        let matchedLineNumber = lineNumberAtSearchOffset + Int(result.count)
        switch wordBoundaryState(matchStart: matchStart, matchEnd: matchEnd) {
        case .bounded:
            break
        case .notBounded:
            lineNumberAtSearchOffset = matchedLineNumber
            searchOffset = max(matchStart + 1, searchOffset + 1)
            continue
        case .needsDecodedFallback:
            return nil
        }

        var lineStart = matchStart
        while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
        }
        let newline = memchr(found, Int32(UInt8(ascii: "\n")), haystackLength - matchStart)
        let outputEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) + 1
        } ?? haystackLength

        if lineStart != lastEmittedLineStart {
            guard pendingLines.count < maxBufferedLines else {
                return nil
            }
            pendingLines.append(PendingLine(
                number: matchedLineNumber,
                start: lineStart,
                outputEnd: outputEnd,
                needsFinalNewline: newline == nil
            ))
            lastEmittedLineStart = lineStart
        }
        lineNumberAtSearchOffset = newline == nil ? matchedLineNumber : matchedLineNumber + 1
        searchOffset = outputEnd
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    var emittedHeading = false
    for line in pendingLines {
        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
            return nil
        }
        guard output.writeBytes(linePrefix) else {
            return nil
        }
        if lineNumber,
           !output.writeLineNumberPrefix(line.number, fieldSeparator: lineNumberFieldSeparator) {
            return nil
        }
        guard output.write(base.advanced(by: line.start), count: line.outputEnd - line.start) else {
            return nil
        }
        if line.needsFinalNewline,
           !output.writeByte(UInt8(ascii: "\n")) {
            return nil
        }
    }

    guard output.flush() else {
        return nil
    }
    return pendingLines.count
}

private func rgSwiftDarwinWriteSurroundingWordsBytes(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    lineNumber: Bool,
    asciiOnly: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard let literalBase = literal.baseAddress, literal.count > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }

    struct PendingLine {
        let number: Int
        let start: Int
        let outputEnd: Int
        let needsFinalNewline: Bool
    }
    let newlineByte = UInt8(ascii: "\n")

    @inline(__always)
    func hasSurroundingASCIIWords(lineStart: Int, lineEnd: Int, literalStart: Int, literalEnd: Int) -> Bool {
        guard literalStart > lineStart, literalEnd < lineEnd else {
            return false
        }

        var beforeWhitespaceStart = literalStart
        while beforeWhitespaceStart > lineStart,
              rgSwiftIsASCIIRegexWhitespaceByte(base[beforeWhitespaceStart - 1]) {
            beforeWhitespaceStart -= 1
        }
        guard beforeWhitespaceStart < literalStart else {
            return false
        }

        var beforeWordStart = beforeWhitespaceStart
        while beforeWordStart > lineStart,
              rgSwiftIsASCIIRegexWordByte(base[beforeWordStart - 1]) {
            beforeWordStart -= 1
        }
        guard beforeWordStart < beforeWhitespaceStart else {
            return false
        }

        var afterWhitespaceEnd = literalEnd
        while afterWhitespaceEnd < lineEnd,
              rgSwiftIsASCIIRegexWhitespaceByte(base[afterWhitespaceEnd]) {
            afterWhitespaceEnd += 1
        }
        guard afterWhitespaceEnd > literalEnd else {
            return false
        }

        var afterWordEnd = afterWhitespaceEnd
        while afterWordEnd < lineEnd,
              rgSwiftIsASCIIRegexWordByte(base[afterWordEnd]) {
            afterWordEnd += 1
        }
        return afterWordEnd > afterWhitespaceEnd
    }

    @inline(__always)
    func utf8SequenceLength(startingWith byte: UInt8) -> Int? {
        if byte < 0x80 {
            return 1
        }
        if byte >= 0xC2 && byte <= 0xDF {
            return 2
        }
        if byte >= 0xE0 && byte <= 0xEF {
            return 3
        }
        if byte >= 0xF0 && byte <= 0xF4 {
            return 4
        }
        return nil
    }

    @inline(__always)
    func isUTF8Continuation(_ byte: UInt8) -> Bool {
        byte >= 0x80 && byte <= 0xBF
    }

    @inline(__always)
    func knownUnicodeWhitespaceScalar(at offset: Int, lineEnd: Int) -> Bool? {
        // Keep the Unicode preflight conservative in \s+ slots: known
        // whitespace can fall back, known non-whitespace can keep scanning, and
        // malformed UTF-8 returns nil so the full matcher decides.
        guard offset < lineEnd else {
            return false
        }
        let first = base[offset]
        guard first >= 0x80 else {
            return rgSwiftIsASCIIRegexWhitespaceByte(first)
        }
        guard let length = utf8SequenceLength(startingWith: first),
              offset + length <= lineEnd else {
            return nil
        }
        for continuationOffset in (offset + 1)..<(offset + length) {
            guard isUTF8Continuation(base[continuationOffset]) else {
                return nil
            }
        }

        if length == 2 {
            return first == 0xC2 && (base[offset + 1] == 0x85 || base[offset + 1] == 0xA0)
        }
        if length == 3 {
            let second = base[offset + 1]
            let third = base[offset + 2]
            if first == 0xE1, second == 0x9A, third == 0x80 {
                return true
            }
            if first == 0xE2 {
                if second == 0x80, (0x80...0x8A).contains(third) || third == 0xA8 || third == 0xA9 {
                    return true
                }
                if second == 0x80, third == 0xAF {
                    return true
                }
                if second == 0x81, third == 0x9F {
                    return true
                }
            }
            if first == 0xE3, second == 0x80, third == 0x80 {
                return true
            }
        }
        return false
    }

    @inline(__always)
    func previousKnownUnicodeWhitespaceScalar(endingAt offset: Int, lineStart: Int) -> Bool? {
        guard offset > lineStart else {
            return false
        }
        var scalarStart = offset - 1
        while scalarStart > lineStart, isUTF8Continuation(base[scalarStart]) {
            scalarStart -= 1
        }
        guard let length = utf8SequenceLength(startingWith: base[scalarStart]),
              scalarStart + length == offset else {
            return nil
        }
        return knownUnicodeWhitespaceScalar(at: scalarStart, lineEnd: offset)
    }

    @inline(__always)
    func leftSideMayNeedUnicode(lineStart: Int, literalStart: Int) -> Bool {
        var offset = literalStart
        var sawWhitespace = false
        while offset > lineStart {
            let byte = base[offset - 1]
            if rgSwiftIsASCIIRegexWhitespaceByte(byte) {
                sawWhitespace = true
                offset -= 1
                continue
            }
            if byte >= 0x80 {
                if sawWhitespace {
                    return true
                }
                return previousKnownUnicodeWhitespaceScalar(endingAt: offset, lineStart: lineStart) ?? true
            }
            break
        }
        guard sawWhitespace else {
            return false
        }

        var sawWord = false
        while offset > lineStart {
            let byte = base[offset - 1]
            if rgSwiftIsASCIIRegexWordByte(byte) {
                sawWord = true
                offset -= 1
                continue
            }
            if byte >= 0x80 {
                return true
            }
            break
        }
        return sawWord
    }

    @inline(__always)
    func rightSideMayNeedUnicode(lineEnd: Int, literalEnd: Int) -> Bool {
        var offset = literalEnd
        var sawWhitespace = false
        while offset < lineEnd {
            let byte = base[offset]
            if rgSwiftIsASCIIRegexWhitespaceByte(byte) {
                sawWhitespace = true
                offset += 1
                continue
            }
            if byte >= 0x80 {
                if sawWhitespace {
                    return true
                }
                return knownUnicodeWhitespaceScalar(at: offset, lineEnd: lineEnd) ?? true
            }
            break
        }
        guard sawWhitespace else {
            return false
        }

        var sawWord = false
        while offset < lineEnd {
            let byte = base[offset]
            if rgSwiftIsASCIIRegexWordByte(byte) {
                sawWord = true
                offset += 1
                continue
            }
            if byte >= 0x80 {
                return true
            }
            break
        }
        return sawWord
    }

    @inline(__always)
    func surroundingUnicodeFallbackMayMatch(
        lineStart: Int,
        lineEnd: Int,
        literalStart: Int,
        literalEnd: Int
    ) -> Bool {
        leftSideMayNeedUnicode(lineStart: lineStart, literalStart: literalStart)
            && rightSideMayNeedUnicode(lineEnd: lineEnd, literalEnd: literalEnd)
    }

    @inline(__always)
    func definitelyCannotMatchNearLiteral(literalStart: Int, literalEnd: Int) -> Bool {
        guard literalStart > 0, literalEnd < haystackLength else {
            return true
        }

        let before = base[literalStart - 1]
        if before == newlineByte {
            return true
        }
        if before < 0x80 {
            guard rgSwiftIsASCIIRegexWhitespaceByte(before) else {
                return true
            }
        } else if asciiOnly {
            return true
        }

        let after = base[literalEnd]
        if after == newlineByte {
            return true
        }
        if after < 0x80 {
            guard rgSwiftIsASCIIRegexWhitespaceByte(after) else {
                return true
            }
        } else if asciiOnly {
            return true
        }

        return false
    }

    func haystackContainsNonASCII() -> Bool {
        for offset in 0..<haystackLength where base[offset] >= 0x80 {
            return true
        }
        return false
    }

    func writeStreamingASCIICompatibleMatches() -> Int? {
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }

        var lineNumberAtSearchOffset = 1
        var searchOffset = 0
        var matchedLineCount = 0
        var emittedHeading = false

        while searchOffset < haystackLength {
            let found: UnsafePointer<UInt8>?
            let skippedNewlines: Int
            if lineNumber {
                let result = rg_memmem_count_byte_before(
                    base.advanced(by: searchOffset),
                    haystackLength - searchOffset,
                    literalBase,
                    literal.count,
                    newlineByte
                )
                found = result.match
                skippedNewlines = Int(result.count)
            } else {
                found = rg_memmem_simple(
                    base.advanced(by: searchOffset),
                    haystackLength - searchOffset,
                    literalBase,
                    literal.count
                )
                skippedNewlines = 0
            }
            guard let found else {
                break
            }

            let literalStart = base.distance(to: found)
            let literalEnd = literalStart + literal.count
            let matchedLineNumber = lineNumberAtSearchOffset + skippedNewlines
            if definitelyCannotMatchNearLiteral(literalStart: literalStart, literalEnd: literalEnd) {
                if lineNumber {
                    lineNumberAtSearchOffset = matchedLineNumber
                }
                searchOffset = max(literalStart + 1, searchOffset + 1)
                continue
            }

            var lineStart = literalStart
            while lineStart > 0, base[lineStart - 1] != newlineByte {
                lineStart -= 1
            }
            let newline = memchr(found, Int32(newlineByte), haystackLength - literalStart)
            let lineEnd = newline.map {
                base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
            } ?? haystackLength
            let outputEnd = newline == nil ? haystackLength : lineEnd + 1

            guard hasSurroundingASCIIWords(
                lineStart: lineStart,
                lineEnd: lineEnd,
                literalStart: literalStart,
                literalEnd: literalEnd
            ) else {
                if lineNumber {
                    lineNumberAtSearchOffset = matchedLineNumber
                }
                searchOffset = max(literalStart + 1, searchOffset + 1)
                continue
            }

            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading),
                  output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber,
               !output.writeLineNumberPrefix(matchedLineNumber, fieldSeparator: lineNumberFieldSeparator) {
                return nil
            }
            guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
                return nil
            }
            if newline == nil,
               !output.writeByte(newlineByte) {
                return nil
            }

            matchedLineCount += 1
            if lineNumber {
                lineNumberAtSearchOffset = newline == nil ? matchedLineNumber : matchedLineNumber + 1
            }
            searchOffset = outputEnd
        }

        guard output.flush() else {
            return nil
        }
        return matchedLineCount
    }

    if asciiOnly {
        return writeStreamingASCIICompatibleMatches()
    }

    var pendingLines: [PendingLine] = []
    pendingLines.reserveCapacity(1024)
    let maxBufferedLines = 16_384
    var lineNumberAtSearchOffset = 1
    var searchOffset = 0
    var lastEmittedLineStart = -1

    while searchOffset < haystackLength {
        let result = rg_memmem_count_byte_before(
            base.advanced(by: searchOffset),
            haystackLength - searchOffset,
            literalBase,
            literal.count,
            newlineByte
        )
        guard let found = result.match else {
            break
        }

        let literalStart = base.distance(to: found)
        let literalEnd = literalStart + literal.count
        let matchedLineNumber = lineNumberAtSearchOffset + Int(result.count)
        if definitelyCannotMatchNearLiteral(literalStart: literalStart, literalEnd: literalEnd) {
            lineNumberAtSearchOffset = matchedLineNumber
            searchOffset = max(literalStart + 1, searchOffset + 1)
            continue
        }

        var lineStart = literalStart
        while lineStart > 0, base[lineStart - 1] != newlineByte {
            lineStart -= 1
        }
        let newline = memchr(found, Int32(newlineByte), haystackLength - literalStart)
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let outputEnd = newline == nil ? haystackLength : lineEnd + 1

        let asciiMatched = hasSurroundingASCIIWords(
            lineStart: lineStart,
            lineEnd: lineEnd,
            literalStart: literalStart,
            literalEnd: literalEnd
        )
        if asciiMatched {
            if lineStart != lastEmittedLineStart {
                guard pendingLines.count < maxBufferedLines else {
                    guard !haystackContainsNonASCII() else {
                        return nil
                    }
                    return writeStreamingASCIICompatibleMatches()
                }
                pendingLines.append(PendingLine(
                    number: matchedLineNumber,
                    start: lineStart,
                    outputEnd: outputEnd,
                    needsFinalNewline: newline == nil
                ))
                lastEmittedLineStart = lineStart
            }
            lineNumberAtSearchOffset = newline == nil ? matchedLineNumber : matchedLineNumber + 1
            searchOffset = outputEnd
            continue
        }
        if !asciiOnly,
           surroundingUnicodeFallbackMayMatch(
            lineStart: lineStart,
            lineEnd: lineEnd,
            literalStart: literalStart,
            literalEnd: literalEnd
           ) {
            return nil
        }

        lineNumberAtSearchOffset = matchedLineNumber
        searchOffset = max(literalStart + 1, searchOffset + 1)
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    var emittedHeading = false
    for line in pendingLines {
        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
            return nil
        }
        guard output.writeBytes(linePrefix) else {
            return nil
        }
        if lineNumber,
           !output.writeLineNumberPrefix(line.number, fieldSeparator: lineNumberFieldSeparator) {
            return nil
        }
        guard output.write(base.advanced(by: line.start), count: line.outputEnd - line.start) else {
            return nil
        }
        if line.needsFinalNewline,
           !output.writeByte(UInt8(ascii: "\n")) {
            return nil
        }
    }

    guard output.flush() else {
        return nil
    }
    return pendingLines.count
}

private func rgSwiftDarwinWriteSingleActiveMultiLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: [UInt8],
    maxCount: Int,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8],
    emitLines: Bool
) -> rg_darwin_literal_file_result? {
    literal.withUnsafeBufferPointer { literalBuffer in
        guard let stats = rgSwiftDarwinWriteLiteralBytes(
            base,
            haystackLength: haystackLength,
            literal: literalBuffer,
            asciiCaseInsensitive: false,
            lineNumber: lineNumber,
            asciiBoundary: false,
            lineNumberFieldSeparator: lineNumberFieldSeparator,
            linePrefix: linePrefix,
            headingPrefix: headingPrefix,
            emitLines: emitLines,
            maxCount: maxCount,
            knownTextHaystack: true
        ) else {
            return nil
        }
        return rg_darwin_literal_file_result(
            status: 0,
            matched_line_count: stats.matchedLines,
            total_match_count: 0,
            bytes_searched: stats.bytesSearched
        )
    }
}

private func rgSwiftDarwinWriteMultiLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]],
    maxCount: Int,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8],
    emitLines: Bool,
    trimLeadingWhitespace: Bool = false
) -> rg_darwin_literal_file_result? {
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    var matchedLineCount = 0
    var bytesSearched = haystackLength
    var currentLineNumber = 1
    var lineCountOffset = 0
    var emittedHeading = false
    var writeFailed = false

    func literal(_ literal: [UInt8], matchesAt offset: Int) -> Bool {
        guard literal.count <= haystackLength - offset else {
            return false
        }
        for index in literal.indices where base[offset + index] != literal[index] {
            return false
        }
        return true
    }

    func commonPrefixLength() -> Int {
        guard let firstLiteral = literals.first else {
            return 0
        }
        var prefixLength = firstLiteral.count
        for literal in literals.dropFirst() {
            prefixLength = min(prefixLength, literal.count)
            while prefixLength > 0 {
                var matches = true
                for index in 0..<prefixLength where firstLiteral[index] != literal[index] {
                    matches = false
                    break
                }
                if matches {
                    break
                }
                prefixLength -= 1
            }
            if prefixLength == 0 {
                break
            }
        }
        return prefixLength
    }

    func emitLine(containing matchStart: Int) -> Bool {
        var lineStart = matchStart
        while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
        }
        let newline = memchr(
            base.advanced(by: matchStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - matchStart
        )
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let outputEnd = newline == nil ? haystackLength : lineEnd + 1
        var renderedLineStart = lineStart
        if trimLeadingWhitespace {
            while renderedLineStart < lineEnd {
                let byte = base[renderedLineStart]
                guard byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A else {
                    break
                }
                renderedLineStart += 1
            }
        }
        if !emitLines {
            matchedLineCount += 1
            bytesSearched = outputEnd
            return true
        }
        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
            return false
        }
        guard output.writeBytes(linePrefix) else {
            return false
        }
        if lineNumber {
            currentLineNumber += rg_memcount_byte(
                base.advanced(by: lineCountOffset),
                lineStart - lineCountOffset,
                UInt8(ascii: "\n")
            )
            lineCountOffset = lineStart
            guard output.writeLineNumberPrefix(
                currentLineNumber,
                fieldSeparator: lineNumberFieldSeparator
            ) else {
                return false
            }
        }
        guard output.write(
            base.advanced(by: renderedLineStart),
            count: outputEnd - renderedLineStart
        ) else {
            return false
        }
        if newline == nil, !output.writeByte(UInt8(ascii: "\n")) {
            return false
        }
        matchedLineCount += 1
        bytesSearched = outputEnd
        return true
    }

    let prefixLineFirstBytes: [UInt8] = {
        var firstBytes: [UInt8] = []
        firstBytes.reserveCapacity(literals.count)
        for literal in literals where !firstBytes.contains(literal[0]) {
            firstBytes.append(literal[0])
        }
        return firstBytes
    }()

    func firstLiteralMatch(inLineStart lineStart: Int, lineEnd: Int) -> Int? {
        var searchOffset = lineStart
        while searchOffset < lineEnd {
            let foundPointer = prefixLineFirstBytes.withUnsafeBufferPointer { firstByteBuffer in
                rg_memchr_any_bytes(
                    base.advanced(by: searchOffset),
                    lineEnd - searchOffset,
                    firstByteBuffer.baseAddress,
                    firstByteBuffer.count
                )
            }
            if let foundPointer {
                let matchStart = base.distance(to: foundPointer)
                let firstByte = base[matchStart]
                for candidateLiteral in literals
                    where candidateLiteral[0] == firstByte && candidateLiteral.count <= lineEnd - matchStart {
                    if literal(candidateLiteral, matchesAt: matchStart) {
                        return matchStart
                    }
                }
                searchOffset = matchStart + 1
            } else {
                return nil
            }
        }
        return nil
    }

    func boundedPrefixLineMatches() -> [Int]? {
        guard emitLines,
              maxCount <= 1024,
              literals.count >= 4 else {
            return nil
        }
        let binaryPrefixLength = min(haystackLength, 64 * 1024)
        guard memchr(base, 0, binaryPrefixLength) == nil else {
            return nil
        }
        var matches: [Int] = []
        matches.reserveCapacity(maxCount)
        var lineStart = 0
        let scanLimit = min(haystackLength, 2 * 1024 * 1024)
        while lineStart < haystackLength,
              lineStart < scanLimit,
              matches.count < maxCount {
            let newline = memchr(
                base.advanced(by: lineStart),
                Int32(UInt8(ascii: "\n")),
                haystackLength - lineStart
            )
            let lineEnd: Int
            let outputEnd: Int
            if let newline {
                lineEnd = base.distance(to: newline.assumingMemoryBound(to: UInt8.self))
                outputEnd = lineEnd + 1
            } else {
                lineEnd = haystackLength
                outputEnd = haystackLength
            }
            guard memchr(base.advanced(by: lineStart), 0, outputEnd - lineStart) == nil else {
                return nil
            }
            if let matchStart = firstLiteralMatch(inLineStart: lineStart, lineEnd: lineEnd) {
                matches.append(matchStart)
            }
            lineStart = outputEnd
        }
        return matches.count == maxCount ? matches : nil
    }

    func nextCandidate(literalIndex: Int, from offset: Int) -> (start: Int, literalIndex: Int) {
        let safeOffset = min(offset, haystackLength)
        let literal = literals[literalIndex]
        guard literal.count <= haystackLength - safeOffset else {
            return (Int.max, literalIndex)
        }
        let foundPointer = literal.withUnsafeBufferPointer { literalBuffer in
            rg_memmem_simple(
                base.advanced(by: safeOffset),
                haystackLength - safeOffset,
                literalBuffer.baseAddress,
                literalBuffer.count
            )
        }
        guard let foundPointer else {
            return (Int.max, literalIndex)
        }
        return (base.distance(to: foundPointer), literalIndex)
    }

    func earliestCandidateIndex(in candidates: [(start: Int, literalIndex: Int)]) -> Int? {
        var selectedIndex: Int?
        var selectedStart = Int.max
        for index in candidates.indices where candidates[index].start < selectedStart {
            selectedStart = candidates[index].start
            selectedIndex = index
        }
        return selectedStart == Int.max ? nil : selectedIndex
    }

    let prefixLength = commonPrefixLength()
    if let prefixMatches = boundedPrefixLineMatches() {
        for matchStart in prefixMatches {
            guard emitLine(containing: matchStart) else {
                writeFailed = true
                break
            }
        }
    } else {
        if memchr(base, 0, haystackLength) != nil {
            return nil
        }
        if prefixLength >= 4 {
            var searchOffset = 0
            while matchedLineCount < maxCount, searchOffset < haystackLength {
                let foundPointer = literals[0].withUnsafeBufferPointer { literalBuffer in
                    rg_memmem_simple(
                        base.advanced(by: searchOffset),
                        haystackLength - searchOffset,
                        literalBuffer.baseAddress,
                        prefixLength
                    )
                }
                guard let foundPointer else {
                    break
                }
                let matchStart = base.distance(to: foundPointer)
                if literals.contains(where: { literal($0, matchesAt: matchStart) }) {
                    guard emitLine(containing: matchStart) else {
                        writeFailed = true
                        break
                    }
                    searchOffset = bytesSearched
                } else {
                    searchOffset = matchStart + 1
                }
            }
        } else {
            var candidates = literals.indices.map {
                nextCandidate(literalIndex: $0, from: 0)
            }
            if !trimLeadingWhitespace {
                var activeCandidate: (start: Int, literalIndex: Int)?
                var activeCandidateCount = 0
                for candidate in candidates where candidate.start < Int.max {
                    activeCandidate = candidate
                    activeCandidateCount += 1
                    if activeCandidateCount > 1 {
                        break
                    }
                }
                if activeCandidateCount == 1, let activeCandidate {
                    return rgSwiftDarwinWriteSingleActiveMultiLiteralLines(
                        base,
                        haystackLength: haystackLength,
                        literal: literals[activeCandidate.literalIndex],
                        maxCount: maxCount,
                        lineNumber: lineNumber,
                        lineNumberFieldSeparator: lineNumberFieldSeparator,
                        linePrefix: linePrefix,
                        headingPrefix: headingPrefix,
                        emitLines: emitLines
                    )
                }
            }

            while matchedLineCount < maxCount,
                  let candidateIndex = earliestCandidateIndex(in: candidates) {
                let matchStart = candidates[candidateIndex].start
                guard matchStart < haystackLength else {
                    break
                }

                guard emitLine(containing: matchStart) else {
                    writeFailed = true
                    break
                }
                for index in candidates.indices where candidates[index].start < bytesSearched {
                    candidates[index] = nextCandidate(
                        literalIndex: candidates[index].literalIndex,
                        from: bytesSearched
                    )
                }
            }
        }
    }

    if matchedLineCount < maxCount {
        bytesSearched = haystackLength
    }

    guard !writeFailed else {
        return rg_darwin_literal_file_result(
            status: -1,
            matched_line_count: matchedLineCount,
            total_match_count: 0,
            bytes_searched: bytesSearched
        )
    }
    guard output.flush() else {
        return rg_darwin_literal_file_result(
            status: -1,
            matched_line_count: matchedLineCount,
            total_match_count: 0,
            bytes_searched: bytesSearched
        )
    }
    return rg_darwin_literal_file_result(
        status: 0,
        matched_line_count: matchedLineCount,
        total_match_count: 0,
        bytes_searched: bytesSearched
    )
}

private func rgSwiftDarwinWriteTrimmedLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    maxCount: Int,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0,
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }
    if asciiCaseInsensitive {
        for byte in literal where byte >= 0x80 {
            return nil
        }
        if rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
            return nil
        }
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    let foldedLiteral = asciiCaseInsensitive
        ? (0..<literal.count).map { rgSwiftASCIILower(literalBase[$0]) }
        : []
    var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
    if asciiCaseInsensitive, foldedLiteral.count > 1 {
        for index in 0..<(foldedLiteral.count - 1) {
            caseInsensitiveShifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
        }
    }

    func lineContainsLiteral(lineStart: Int, lineEnd: Int) -> Bool {
        if asciiCaseInsensitive {
            return foldedLiteral.withUnsafeBufferPointer { foldedBuffer in
                caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                    rg_memcasemem_ascii_prepared(
                        base.advanced(by: lineStart),
                        lineEnd - lineStart,
                        foldedBuffer.baseAddress,
                        foldedBuffer.count,
                        shifts.baseAddress
                    ) != nil
                }
            }
        }
        return rg_memmem_simple(
            base.advanced(by: lineStart),
            lineEnd - lineStart,
            literalBase,
            literal.count
        ) != nil
    }

    var matchedLineCount = 0
    var currentLineNumber = 1
    var lineStart = 0
    var emittedHeading = false

    while lineStart < haystackLength && matchedLineCount < maxCount {
        let newline = memchr(
            base.advanced(by: lineStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - lineStart
        )
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let outputEnd = newline == nil ? haystackLength : lineEnd + 1

        if lineContainsLiteral(lineStart: lineStart, lineEnd: lineEnd) {
            var renderedLineStart = lineStart
            while renderedLineStart < lineEnd {
                let byte = base[renderedLineStart]
                guard byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A else {
                    break
                }
                renderedLineStart += 1
            }
            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
                return nil
            }
            guard output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber {
                guard output.writeLineNumberPrefix(
                    currentLineNumber,
                    fieldSeparator: lineNumberFieldSeparator
                ) else {
                    return nil
                }
            }
            guard output.write(base.advanced(by: renderedLineStart), count: outputEnd - renderedLineStart) else {
                return nil
            }
            if newline == nil, !output.writeByte(UInt8(ascii: "\n")) {
                return nil
            }
            matchedLineCount += 1
        }

        lineStart = outputEnd
        currentLineNumber += 1
    }

    guard output.flush() else {
        return nil
    }
    return matchedLineCount
}

private func rgSwiftDarwinWriteTrimmedMultiLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]],
    maxCount: Int,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard !literals.isEmpty,
          literals.count <= 64,
          literals.allSatisfy({ !$0.isEmpty }),
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }
    if asciiCaseInsensitive {
        guard literals.allSatisfy({ $0.allSatisfy { $0 < 0x80 } }) else {
            return nil
        }
        if rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
            return nil
        }
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    let firstBytes: [UInt8] = {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(literals.count)
        for literal in literals where !bytes.contains(literal[0]) {
            bytes.append(literal[0])
        }
        return bytes
    }()
    let foldedLiterals = asciiCaseInsensitive
        ? literals.map { $0.map(rgSwiftASCIILower) }
        : []
    let caseInsensitiveFirstBytes: [UInt8] = if asciiCaseInsensitive {
        {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(foldedLiterals.count * 2)
            for literal in foldedLiterals {
                let first = literal[0]
                if !bytes.contains(first) {
                    bytes.append(first)
                }
                if first >= UInt8(ascii: "a"), first <= UInt8(ascii: "z") {
                    let upper = first - 32
                    if !bytes.contains(upper) {
                        bytes.append(upper)
                    }
                }
            }
            return bytes
        }()
    } else {
        []
    }
    guard !firstBytes.isEmpty || !caseInsensitiveFirstBytes.isEmpty else {
        return nil
    }

    func literal(_ literal: [UInt8], matchesAt offset: Int, lineEnd: Int) -> Bool {
        guard literal.count <= lineEnd - offset else {
            return false
        }
        for index in literal.indices where base[offset + index] != literal[index] {
            return false
        }
        return true
    }

    func foldedLiteral(_ literal: [UInt8], matchesAt offset: Int, lineEnd: Int) -> Bool {
        guard literal.count <= lineEnd - offset else {
            return false
        }
        for index in literal.indices where rgSwiftASCIILower(base[offset + index]) != literal[index] {
            return false
        }
        return true
    }

    func lineContainsAnyLiteral(lineStart: Int, lineEnd: Int) -> Bool {
        var searchOffset = lineStart
        while searchOffset < lineEnd {
            let foundPointer: UnsafePointer<UInt8>?
            if asciiCaseInsensitive {
                foundPointer = caseInsensitiveFirstBytes.withUnsafeBufferPointer { firstByteBuffer in
                    rg_memchr_any_bytes(
                        base.advanced(by: searchOffset),
                        lineEnd - searchOffset,
                        firstByteBuffer.baseAddress,
                        firstByteBuffer.count
                    )
                }
            } else {
                foundPointer = firstBytes.withUnsafeBufferPointer { firstByteBuffer in
                    rg_memchr_any_bytes(
                        base.advanced(by: searchOffset),
                        lineEnd - searchOffset,
                        firstByteBuffer.baseAddress,
                        firstByteBuffer.count
                    )
                }
            }
            guard let foundPointer else {
                return false
            }

            let matchStart = base.distance(to: foundPointer)
            if asciiCaseInsensitive {
                let foldedFirstByte = rgSwiftASCIILower(base[matchStart])
                for candidateLiteral in foldedLiterals
                    where candidateLiteral[0] == foldedFirstByte
                        && foldedLiteral(candidateLiteral, matchesAt: matchStart, lineEnd: lineEnd) {
                    return true
                }
            } else {
                let firstByte = base[matchStart]
                for candidateLiteral in literals
                    where candidateLiteral[0] == firstByte
                        && literal(candidateLiteral, matchesAt: matchStart, lineEnd: lineEnd) {
                    return true
                }
            }
            searchOffset = matchStart + 1
        }
        return false
    }

    var matchedLineCount = 0
    var currentLineNumber = 1
    var lineStart = 0
    var emittedHeading = false

    while lineStart < haystackLength && matchedLineCount < maxCount {
        let newline = memchr(
            base.advanced(by: lineStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - lineStart
        )
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let outputEnd = newline == nil ? haystackLength : lineEnd + 1

        if lineContainsAnyLiteral(lineStart: lineStart, lineEnd: lineEnd) {
            var renderedLineStart = lineStart
            while renderedLineStart < lineEnd {
                let byte = base[renderedLineStart]
                guard byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A else {
                    break
                }
                renderedLineStart += 1
            }
            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
                return nil
            }
            guard output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber {
                guard output.writeLineNumberPrefix(
                    currentLineNumber,
                    fieldSeparator: lineNumberFieldSeparator
                ) else {
                    return nil
                }
            }
            guard output.write(base.advanced(by: renderedLineStart), count: outputEnd - renderedLineStart) else {
                return nil
            }
            if newline == nil, !output.writeByte(UInt8(ascii: "\n")) {
                return nil
            }
            matchedLineCount += 1
        }

        lineStart = outputEnd
        currentLineNumber += 1
    }

    guard output.flush() else {
        return nil
    }
    return matchedLineCount
}

private func rgSwiftDarwinWriteInvertedLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    maxCount: Int,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0,
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }
    if asciiCaseInsensitive {
        for byte in literal where byte >= 0x80 {
            return nil
        }
        if rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
            return nil
        }
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    var selectedLineCount = 0
    var currentLineNumber = 1
    var lineStart = 0
    var emittedHeading = false
    let foldedLiteral = asciiCaseInsensitive
        ? (0..<literal.count).map { rgSwiftASCIILower(literalBase[$0]) }
        : []
    var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
    if asciiCaseInsensitive, foldedLiteral.count > 1 {
        for index in 0..<(foldedLiteral.count - 1) {
            caseInsensitiveShifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
        }
    }

    func lineContainsLiteral(lineStart: Int, lineEnd: Int) -> Bool {
        if asciiCaseInsensitive {
            return foldedLiteral.withUnsafeBufferPointer { foldedBuffer in
                caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                    rg_memcasemem_ascii_prepared(
                        base.advanced(by: lineStart),
                        lineEnd - lineStart,
                        foldedBuffer.baseAddress,
                        foldedBuffer.count,
                        shifts.baseAddress
                    ) != nil
                }
            }
        }
        return rg_memmem_simple(
            base.advanced(by: lineStart),
            lineEnd - lineStart,
            literalBase,
            literal.count
        ) != nil
    }

    while lineStart < haystackLength && selectedLineCount < maxCount {
        let newline = memchr(
            base.advanced(by: lineStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - lineStart
        )
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let outputEnd = newline == nil ? haystackLength : lineEnd + 1
        let containsLiteral = lineContainsLiteral(lineStart: lineStart, lineEnd: lineEnd)

        if !containsLiteral {
            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
                return nil
            }
            guard output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber {
                guard output.writeLineNumberPrefix(
                    currentLineNumber,
                    fieldSeparator: lineNumberFieldSeparator
                ) else {
                    return nil
                }
            }
            guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
                return nil
            }
            if newline == nil, !output.writeByte(UInt8(ascii: "\n")) {
                return nil
            }
            selectedLineCount += 1
        }

        lineStart = outputEnd
        currentLineNumber += 1
    }

    guard output.flush() else {
        return nil
    }
    return selectedLineCount
}

private func rgSwiftDarwinWriteInvertedMultiLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]],
    maxCount: Int,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    lineNumberFieldSeparator: [UInt8],
    linePrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard !literals.isEmpty,
          literals.allSatisfy({ !$0.isEmpty }),
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }
    if asciiCaseInsensitive {
        guard literals.allSatisfy({ $0.allSatisfy { $0 < 0x80 } }) else {
            return nil
        }
        if rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
            return nil
        }
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    let firstBytes: [UInt8] = {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(literals.count)
        for literal in literals where !bytes.contains(literal[0]) {
            bytes.append(literal[0])
        }
        return bytes
    }()
    let foldedLiterals = asciiCaseInsensitive
        ? literals.map { $0.map(rgSwiftASCIILower) }
        : []
    let caseInsensitiveFirstBytes: [UInt8] = if asciiCaseInsensitive {
        {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(foldedLiterals.count * 2)
            for literal in foldedLiterals {
                let first = literal[0]
                if !bytes.contains(first) {
                    bytes.append(first)
                }
                if first >= UInt8(ascii: "a"), first <= UInt8(ascii: "z") {
                    let upper = first - 32
                    if !bytes.contains(upper) {
                        bytes.append(upper)
                    }
                }
            }
            return bytes
        }()
    } else {
        []
    }
    guard !firstBytes.isEmpty || !caseInsensitiveFirstBytes.isEmpty else {
        return nil
    }

    func literal(_ literal: [UInt8], matchesAt offset: Int, lineEnd: Int) -> Bool {
        guard literal.count <= lineEnd - offset else {
            return false
        }
        for index in literal.indices where base[offset + index] != literal[index] {
            return false
        }
        return true
    }

    func foldedLiteral(_ literal: [UInt8], matchesAt offset: Int, lineEnd: Int) -> Bool {
        guard literal.count <= lineEnd - offset else {
            return false
        }
        for index in literal.indices where rgSwiftASCIILower(base[offset + index]) != literal[index] {
            return false
        }
        return true
    }

    func lineContainsAnyLiteral(lineStart: Int, lineEnd: Int) -> Bool {
        var searchOffset = lineStart
        while searchOffset < lineEnd {
            let foundPointer: UnsafePointer<UInt8>?
            if asciiCaseInsensitive {
                foundPointer = caseInsensitiveFirstBytes.withUnsafeBufferPointer { firstByteBuffer in
                    rg_memchr_any_bytes(
                        base.advanced(by: searchOffset),
                        lineEnd - searchOffset,
                        firstByteBuffer.baseAddress,
                        firstByteBuffer.count
                    )
                }
            } else {
                foundPointer = firstBytes.withUnsafeBufferPointer { firstByteBuffer in
                    rg_memchr_any_bytes(
                        base.advanced(by: searchOffset),
                        lineEnd - searchOffset,
                        firstByteBuffer.baseAddress,
                        firstByteBuffer.count
                    )
                }
            }
            guard let foundPointer else {
                return false
            }

            let matchStart = base.distance(to: foundPointer)
            if asciiCaseInsensitive {
                let foldedFirstByte = rgSwiftASCIILower(base[matchStart])
                for candidateLiteral in foldedLiterals
                    where candidateLiteral[0] == foldedFirstByte
                        && foldedLiteral(candidateLiteral, matchesAt: matchStart, lineEnd: lineEnd) {
                    return true
                }
            } else {
                let firstByte = base[matchStart]
                for candidateLiteral in literals
                    where candidateLiteral[0] == firstByte
                        && literal(candidateLiteral, matchesAt: matchStart, lineEnd: lineEnd) {
                    return true
                }
            }
            searchOffset = matchStart + 1
        }
        return false
    }

    var selectedLineCount = 0
    var currentLineNumber = 1
    var lineStart = 0
    var emittedHeading = false

    while lineStart < haystackLength && selectedLineCount < maxCount {
        let newline = memchr(
            base.advanced(by: lineStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - lineStart
        )
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let outputEnd = newline == nil ? haystackLength : lineEnd + 1

        if !lineContainsAnyLiteral(lineStart: lineStart, lineEnd: lineEnd) {
            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
                return nil
            }
            guard output.writeBytes(linePrefix) else {
                return nil
            }
            if lineNumber {
                guard output.writeLineNumberPrefix(
                    currentLineNumber,
                    fieldSeparator: lineNumberFieldSeparator
                ) else {
                    return nil
                }
            }
            guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
                return nil
            }
            if newline == nil, !output.writeByte(UInt8(ascii: "\n")) {
                return nil
            }
            selectedLineCount += 1
        }

        lineStart = outputEnd
        currentLineNumber += 1
    }

    guard output.flush() else {
        return nil
    }
    return selectedLineCount
}

private func rgSwiftLiteralContextWindowStart(
    base: UnsafePointer<UInt8>,
    matchStart: Int,
    beforeContext: Int
) -> Int {
    var lineStart = matchStart
    while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
        lineStart -= 1
    }

    var remaining = beforeContext
    while remaining > 0, lineStart > 0 {
        lineStart -= 1
        while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
        }
        remaining -= 1
    }
    return lineStart
}

private struct RgSwiftMultiLiteralMatchInfo {
    let firstMatch: UnsafePointer<UInt8>?
    let presentLiterals: [[UInt8]]
}

private func rgSwiftMultiLiteralMatchInfo(
    base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]]
) -> RgSwiftMultiLiteralMatchInfo {
    var firstMatch: UnsafePointer<UInt8>?
    var firstMatchOffset = haystackLength
    var presentLiterals: [[UInt8]] = []
    presentLiterals.reserveCapacity(literals.count)

    for literal in literals {
        let match = literal.withUnsafeBufferPointer { literalBuffer in
            rg_memmem_simple(
                base,
                haystackLength,
                literalBuffer.baseAddress,
                literalBuffer.count
            )
        }
        if let match {
            presentLiterals.append(literal)
            let matchOffset = base.distance(to: match)
            if matchOffset < firstMatchOffset {
                firstMatch = match
                firstMatchOffset = matchOffset
            }
        }
    }
    return RgSwiftMultiLiteralMatchInfo(
        firstMatch: firstMatch,
        presentLiterals: presentLiterals
    )
}

private func rgSwiftDarwinWriteAfterContextLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    afterContext: Int,
    maxCount: Int,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    lineNumberFieldMatchSeparator: [UInt8],
    lineNumberFieldContextSeparator: [UInt8],
    lineMatchPrefix: [UInt8],
    lineContextPrefix: [UInt8],
    headingPrefix: [UInt8],
    contextSeparator: [UInt8]?
) -> Int? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0,
          afterContext > 0,
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    let firstLiteralMatch: UnsafePointer<UInt8>?
    if asciiCaseInsensitive {
        firstLiteralMatch = nil
    } else {
        firstLiteralMatch = rg_memmem_simple(
            base,
            haystackLength,
            literalBase,
            literal.count
        )
        guard firstLiteralMatch != nil else {
            return 0
        }
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }
    if asciiCaseInsensitive {
        for byte in literal where byte >= 0x80 {
            return nil
        }
        if rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
            return nil
        }
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    var matchedLineCount = 0
    var remainingContextLines = 0
    var currentLineNumber = 1
    var previousEmittedLineNumber = 0
    var lineStart = 0
    var emittedHeading = false
    let foldedLiteral = asciiCaseInsensitive
        ? (0..<literal.count).map { rgSwiftASCIILower(literalBase[$0]) }
        : []
    var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
    if asciiCaseInsensitive, foldedLiteral.count > 1 {
        for index in 0..<(foldedLiteral.count - 1) {
            caseInsensitiveShifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
        }
    }

    if let firstLiteralMatch {
        let firstMatchStart = base.distance(to: firstLiteralMatch)
        lineStart = rgSwiftLiteralContextWindowStart(
            base: base,
            matchStart: firstMatchStart,
            beforeContext: 0
        )
        currentLineNumber = lineNumber
            ? Int(rg_memcount_byte(base, lineStart, UInt8(ascii: "\n"))) + 1
            : 1
    }

    func emitGroupSeparatorIfNeeded() -> Bool {
        guard previousEmittedLineNumber > 0,
              currentLineNumber > previousEmittedLineNumber + 1,
              let contextSeparator else {
            return true
        }
        return output.writeBytes(contextSeparator)
            && output.writeByte(UInt8(ascii: "\n"))
    }

    func lineContainsLiteral(lineStart: Int, lineEnd: Int) -> Bool {
        if asciiCaseInsensitive {
            return foldedLiteral.withUnsafeBufferPointer { foldedBuffer in
                caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                    rg_memcasemem_ascii_prepared(
                        base.advanced(by: lineStart),
                        lineEnd - lineStart,
                        foldedBuffer.baseAddress,
                        foldedBuffer.count,
                        shifts.baseAddress
                    ) != nil
                }
            }
        }
        return rg_memmem_simple(
            base.advanced(by: lineStart),
            lineEnd - lineStart,
            literalBase,
            literal.count
        ) != nil
    }

    while lineStart < haystackLength {
        let newline = memchr(
            base.advanced(by: lineStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - lineStart
        )
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let outputEnd = newline == nil ? haystackLength : lineEnd + 1
        let containsLiteral = lineContainsLiteral(lineStart: lineStart, lineEnd: lineEnd)

        let shouldCountMatch = containsLiteral && matchedLineCount < maxCount
        let shouldEmit = shouldCountMatch || remainingContextLines > 0
        if shouldEmit {
            if shouldCountMatch {
                matchedLineCount += 1
                remainingContextLines = afterContext
            } else {
                remainingContextLines -= 1
            }

            guard emitGroupSeparatorIfNeeded() else {
                return nil
            }
            guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
                return nil
            }
            guard output.writeBytes(containsLiteral ? lineMatchPrefix : lineContextPrefix) else {
                return nil
            }
            if lineNumber {
                guard output.writeLineNumberPrefix(
                    currentLineNumber,
                    fieldSeparator: containsLiteral
                        ? lineNumberFieldMatchSeparator
                        : lineNumberFieldContextSeparator
                ) else {
                    return nil
                }
            }
            guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
                return nil
            }
            if newline == nil, !output.writeByte(UInt8(ascii: "\n")) {
                return nil
            }
            previousEmittedLineNumber = currentLineNumber
        }

        lineStart = outputEnd
        currentLineNumber += 1
    }

    guard output.flush() else {
        return nil
    }
    return matchedLineCount
}

private func rgSwiftDarwinWriteBeforeContextLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    beforeContext: Int,
    maxCount: Int,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    lineNumberFieldMatchSeparator: [UInt8],
    lineNumberFieldContextSeparator: [UInt8],
    lineMatchPrefix: [UInt8],
    lineContextPrefix: [UInt8],
    headingPrefix: [UInt8],
    contextSeparator: [UInt8]?
) -> Int? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0,
          beforeContext > 0,
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    let firstLiteralMatch: UnsafePointer<UInt8>?
    if asciiCaseInsensitive {
        firstLiteralMatch = nil
    } else {
        firstLiteralMatch = rg_memmem_simple(
            base,
            haystackLength,
            literalBase,
            literal.count
        )
        guard firstLiteralMatch != nil else {
            return 0
        }
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }
    if asciiCaseInsensitive {
        for byte in literal where byte >= 0x80 {
            return nil
        }
        if rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
            return nil
        }
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    struct PendingLine {
        let number: Int
        let start: Int
        let outputEnd: Int
        let hasNewline: Bool
        let containsLiteral: Bool
    }

    var pendingLines: [PendingLine] = []
    pendingLines.reserveCapacity(min(beforeContext, 128))
    var pendingStartIndex = 0
    var matchedLineCount = 0
    var currentLineNumber = 1
    var previousEmittedLineNumber = 0
    var lineStart = 0
    var emittedHeading = false
    let foldedLiteral = asciiCaseInsensitive
        ? (0..<literal.count).map { rgSwiftASCIILower(literalBase[$0]) }
        : []
    var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
    if asciiCaseInsensitive, foldedLiteral.count > 1 {
        for index in 0..<(foldedLiteral.count - 1) {
            caseInsensitiveShifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
        }
    }

    if let firstLiteralMatch {
        let firstMatchStart = base.distance(to: firstLiteralMatch)
        lineStart = rgSwiftLiteralContextWindowStart(
            base: base,
            matchStart: firstMatchStart,
            beforeContext: beforeContext
        )
        currentLineNumber = lineNumber
            ? Int(rg_memcount_byte(base, lineStart, UInt8(ascii: "\n"))) + 1
            : 1
    }

    func compactPendingLinesIfNeeded() {
        guard pendingStartIndex > 1024 else {
            return
        }
        pendingLines.removeFirst(pendingStartIndex)
        pendingStartIndex = 0
    }

    func appendPendingLine(_ line: PendingLine) {
        pendingLines.append(line)
        if pendingLines.count - pendingStartIndex > beforeContext {
            pendingStartIndex += 1
            compactPendingLinesIfNeeded()
        }
    }

    func emitGroupSeparatorIfNeeded(for lineNumber: Int) -> Bool {
        guard previousEmittedLineNumber > 0,
              lineNumber > previousEmittedLineNumber + 1,
              let contextSeparator else {
            return true
        }
        return output.writeBytes(contextSeparator)
            && output.writeByte(UInt8(ascii: "\n"))
    }

    func emitLine(_ line: PendingLine) -> Bool {
        guard line.number > previousEmittedLineNumber else {
            return true
        }
        guard emitGroupSeparatorIfNeeded(for: line.number) else {
            return false
        }
        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
            return false
        }
        guard output.writeBytes(line.containsLiteral ? lineMatchPrefix : lineContextPrefix) else {
            return false
        }
        if lineNumber {
            guard output.writeLineNumberPrefix(
                line.number,
                fieldSeparator: line.containsLiteral
                    ? lineNumberFieldMatchSeparator
                    : lineNumberFieldContextSeparator
            ) else {
                return false
            }
        }
        guard output.write(base.advanced(by: line.start), count: line.outputEnd - line.start) else {
            return false
        }
        if !line.hasNewline,
           !output.writeByte(UInt8(ascii: "\n")) {
            return false
        }
        previousEmittedLineNumber = line.number
        return true
    }

    func lineContainsLiteral(lineStart: Int, lineEnd: Int) -> Bool {
        if asciiCaseInsensitive {
            return foldedLiteral.withUnsafeBufferPointer { foldedBuffer in
                caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                    rg_memcasemem_ascii_prepared(
                        base.advanced(by: lineStart),
                        lineEnd - lineStart,
                        foldedBuffer.baseAddress,
                        foldedBuffer.count,
                        shifts.baseAddress
                    ) != nil
                }
            }
        }
        return rg_memmem_simple(
            base.advanced(by: lineStart),
            lineEnd - lineStart,
            literalBase,
            literal.count
        ) != nil
    }

    while lineStart < haystackLength {
        let newline = memchr(
            base.advanced(by: lineStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - lineStart
        )
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let hasNewline = newline != nil
        let outputEnd = hasNewline ? lineEnd + 1 : haystackLength
        let containsLiteral = lineContainsLiteral(lineStart: lineStart, lineEnd: lineEnd)
        let currentLine = PendingLine(
            number: currentLineNumber,
            start: lineStart,
            outputEnd: outputEnd,
            hasNewline: hasNewline,
            containsLiteral: containsLiteral
        )

        if containsLiteral && matchedLineCount < maxCount {
            matchedLineCount += 1
            for pendingLine in pendingLines[pendingStartIndex...] {
                guard emitLine(pendingLine) else {
                    return nil
                }
            }
            guard emitLine(currentLine) else {
                return nil
            }
        }

        appendPendingLine(currentLine)
        lineStart = outputEnd
        currentLineNumber += 1
    }

    guard output.flush() else {
        return nil
    }
    return matchedLineCount
}

private func rgSwiftDarwinWriteContextLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    beforeContext: Int,
    afterContext: Int,
    maxCount: Int,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    lineNumberFieldMatchSeparator: [UInt8],
    lineNumberFieldContextSeparator: [UInt8],
    lineMatchPrefix: [UInt8],
    lineContextPrefix: [UInt8],
    headingPrefix: [UInt8],
    contextSeparator: [UInt8]?
) -> Int? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0,
          beforeContext > 0,
          afterContext > 0,
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    let firstLiteralMatch: UnsafePointer<UInt8>?
    if asciiCaseInsensitive {
        firstLiteralMatch = nil
    } else {
        firstLiteralMatch = rg_memmem_simple(
            base,
            haystackLength,
            literalBase,
            literal.count
        )
        guard firstLiteralMatch != nil else {
            return 0
        }
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }
    if asciiCaseInsensitive {
        for byte in literal where byte >= 0x80 {
            return nil
        }
        if rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
            return nil
        }
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    struct PendingLine {
        let number: Int
        let start: Int
        let outputEnd: Int
        let hasNewline: Bool
        let containsLiteral: Bool
    }

    var pendingLines: [PendingLine] = []
    pendingLines.reserveCapacity(min(beforeContext, 128))
    var pendingStartIndex = 0
    var matchedLineCount = 0
    var remainingContextLines = 0
    var currentLineNumber = 1
    var previousEmittedLineNumber = 0
    var lineStart = 0
    var emittedHeading = false
    let foldedLiteral = asciiCaseInsensitive
        ? (0..<literal.count).map { rgSwiftASCIILower(literalBase[$0]) }
        : []
    var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
    if asciiCaseInsensitive, foldedLiteral.count > 1 {
        for index in 0..<(foldedLiteral.count - 1) {
            caseInsensitiveShifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
        }
    }

    if let firstLiteralMatch {
        let firstMatchStart = base.distance(to: firstLiteralMatch)
        lineStart = rgSwiftLiteralContextWindowStart(
            base: base,
            matchStart: firstMatchStart,
            beforeContext: beforeContext
        )
        currentLineNumber = lineNumber
            ? Int(rg_memcount_byte(base, lineStart, UInt8(ascii: "\n"))) + 1
            : 1
    }

    func compactPendingLinesIfNeeded() {
        guard pendingStartIndex > 1024 else {
            return
        }
        pendingLines.removeFirst(pendingStartIndex)
        pendingStartIndex = 0
    }

    func appendPendingLine(_ line: PendingLine) {
        pendingLines.append(line)
        if pendingLines.count - pendingStartIndex > beforeContext {
            pendingStartIndex += 1
            compactPendingLinesIfNeeded()
        }
    }

    func emitGroupSeparatorIfNeeded(for lineNumber: Int) -> Bool {
        guard previousEmittedLineNumber > 0,
              lineNumber > previousEmittedLineNumber + 1,
              let contextSeparator else {
            return true
        }
        return output.writeBytes(contextSeparator)
            && output.writeByte(UInt8(ascii: "\n"))
    }

    func emitLine(_ line: PendingLine) -> Bool {
        guard line.number > previousEmittedLineNumber else {
            return true
        }
        guard emitGroupSeparatorIfNeeded(for: line.number) else {
            return false
        }
        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
            return false
        }
        guard output.writeBytes(line.containsLiteral ? lineMatchPrefix : lineContextPrefix) else {
            return false
        }
        if lineNumber {
            guard output.writeLineNumberPrefix(
                line.number,
                fieldSeparator: line.containsLiteral
                    ? lineNumberFieldMatchSeparator
                    : lineNumberFieldContextSeparator
            ) else {
                return false
            }
        }
        guard output.write(base.advanced(by: line.start), count: line.outputEnd - line.start) else {
            return false
        }
        if !line.hasNewline,
           !output.writeByte(UInt8(ascii: "\n")) {
            return false
        }
        previousEmittedLineNumber = line.number
        return true
    }

    func lineContainsLiteral(lineStart: Int, lineEnd: Int) -> Bool {
        if asciiCaseInsensitive {
            return foldedLiteral.withUnsafeBufferPointer { foldedBuffer in
                caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                    rg_memcasemem_ascii_prepared(
                        base.advanced(by: lineStart),
                        lineEnd - lineStart,
                        foldedBuffer.baseAddress,
                        foldedBuffer.count,
                        shifts.baseAddress
                    ) != nil
                }
            }
        }
        return rg_memmem_simple(
            base.advanced(by: lineStart),
            lineEnd - lineStart,
            literalBase,
            literal.count
        ) != nil
    }

    while lineStart < haystackLength {
        let newline = memchr(
            base.advanced(by: lineStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - lineStart
        )
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let hasNewline = newline != nil
        let outputEnd = hasNewline ? lineEnd + 1 : haystackLength
        let containsLiteral = lineContainsLiteral(lineStart: lineStart, lineEnd: lineEnd)
        let currentLine = PendingLine(
            number: currentLineNumber,
            start: lineStart,
            outputEnd: outputEnd,
            hasNewline: hasNewline,
            containsLiteral: containsLiteral
        )

        if containsLiteral && matchedLineCount < maxCount {
            matchedLineCount += 1
            for pendingLine in pendingLines[pendingStartIndex...] {
                guard emitLine(pendingLine) else {
                    return nil
                }
            }
            guard emitLine(currentLine) else {
                return nil
            }
            remainingContextLines = afterContext
        } else if remainingContextLines > 0 {
            guard emitLine(currentLine) else {
                return nil
            }
            remainingContextLines -= 1
        }

        appendPendingLine(currentLine)
        lineStart = outputEnd
        currentLineNumber += 1
    }

    guard output.flush() else {
        return nil
    }
    return matchedLineCount
}

private func rgSwiftDarwinWriteMultiLiteralContextLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]],
    beforeContext: Int,
    afterContext: Int,
    maxCount: Int,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    lineNumberFieldMatchSeparator: [UInt8],
    lineNumberFieldContextSeparator: [UInt8],
    lineMatchPrefix: [UInt8],
    lineContextPrefix: [UInt8],
    headingPrefix: [UInt8],
    contextSeparator: [UInt8]?
) -> Int? {
    guard !literals.isEmpty,
          literals.allSatisfy({ !$0.isEmpty }),
          beforeContext > 0 || afterContext > 0,
          maxCount > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    let activeLiterals: [[UInt8]]
    let firstLiteralMatch: UnsafePointer<UInt8>?
    if asciiCaseInsensitive {
        activeLiterals = literals
        firstLiteralMatch = nil
    } else {
        let matchInfo = rgSwiftMultiLiteralMatchInfo(
            base: base,
            haystackLength: haystackLength,
            literals: literals
        )
        guard let firstMatch = matchInfo.firstMatch else {
            return 0
        }
        activeLiterals = matchInfo.presentLiterals
        firstLiteralMatch = firstMatch
    }
    if !asciiCaseInsensitive, activeLiterals.count == 1 {
        return activeLiterals[0].withUnsafeBufferPointer { literal in
            if beforeContext > 0, afterContext > 0 {
                return rgSwiftDarwinWriteContextLiteralLines(
                    base,
                    haystackLength: haystackLength,
                    literal: literal,
                    beforeContext: beforeContext,
                    afterContext: afterContext,
                    maxCount: maxCount,
                    asciiCaseInsensitive: false,
                    lineNumber: lineNumber,
                    lineNumberFieldMatchSeparator: lineNumberFieldMatchSeparator,
                    lineNumberFieldContextSeparator: lineNumberFieldContextSeparator,
                    lineMatchPrefix: lineMatchPrefix,
                    lineContextPrefix: lineContextPrefix,
                    headingPrefix: headingPrefix,
                    contextSeparator: contextSeparator
                )
            }
            if beforeContext > 0 {
                return rgSwiftDarwinWriteBeforeContextLiteralLines(
                    base,
                    haystackLength: haystackLength,
                    literal: literal,
                    beforeContext: beforeContext,
                    maxCount: maxCount,
                    asciiCaseInsensitive: false,
                    lineNumber: lineNumber,
                    lineNumberFieldMatchSeparator: lineNumberFieldMatchSeparator,
                    lineNumberFieldContextSeparator: lineNumberFieldContextSeparator,
                    lineMatchPrefix: lineMatchPrefix,
                    lineContextPrefix: lineContextPrefix,
                    headingPrefix: headingPrefix,
                    contextSeparator: contextSeparator
                )
            }
            return rgSwiftDarwinWriteAfterContextLiteralLines(
                base,
                haystackLength: haystackLength,
                literal: literal,
                afterContext: afterContext,
                maxCount: maxCount,
                asciiCaseInsensitive: false,
                lineNumber: lineNumber,
                lineNumberFieldMatchSeparator: lineNumberFieldMatchSeparator,
                lineNumberFieldContextSeparator: lineNumberFieldContextSeparator,
                lineMatchPrefix: lineMatchPrefix,
                lineContextPrefix: lineContextPrefix,
                headingPrefix: headingPrefix,
                contextSeparator: contextSeparator
            )
        }
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }
    if asciiCaseInsensitive {
        guard literals.allSatisfy({ $0.allSatisfy { $0 < 0x80 } }) else {
            return nil
        }
        if rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
            return nil
        }
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    let firstBytes: [UInt8] = {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(activeLiterals.count)
        for literal in activeLiterals where !bytes.contains(literal[0]) {
            bytes.append(literal[0])
        }
        return bytes
    }()
    let foldedLiterals = asciiCaseInsensitive
        ? activeLiterals.map { $0.map(rgSwiftASCIILower) }
        : []
    let caseInsensitiveFirstBytes: [UInt8] = if asciiCaseInsensitive {
        {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(foldedLiterals.count * 2)
            for literal in foldedLiterals {
                let first = literal[0]
                if !bytes.contains(first) {
                    bytes.append(first)
                }
                if first >= UInt8(ascii: "a"), first <= UInt8(ascii: "z") {
                    let upper = first - 32
                    if !bytes.contains(upper) {
                        bytes.append(upper)
                    }
                }
            }
            return bytes
        }()
    } else {
        []
    }
    guard !firstBytes.isEmpty || !caseInsensitiveFirstBytes.isEmpty else {
        return nil
    }

    struct PendingLine {
        let number: Int
        let start: Int
        let outputEnd: Int
        let hasNewline: Bool
        let containsLiteral: Bool
    }

    var pendingLines: [PendingLine] = []
    pendingLines.reserveCapacity(min(beforeContext, 128))
    var pendingStartIndex = 0
    var matchedLineCount = 0
    var remainingContextLines = 0
    var currentLineNumber = 1
    var previousEmittedLineNumber = 0
    var lineStart = 0
    var emittedHeading = false

    if let firstLiteralMatch {
        let firstMatchStart = base.distance(to: firstLiteralMatch)
        lineStart = rgSwiftLiteralContextWindowStart(
            base: base,
            matchStart: firstMatchStart,
            beforeContext: beforeContext
        )
        currentLineNumber = lineNumber
            ? Int(rg_memcount_byte(base, lineStart, UInt8(ascii: "\n"))) + 1
            : 1
    }

    func compactPendingLinesIfNeeded() {
        guard pendingStartIndex > 1024 else {
            return
        }
        pendingLines.removeFirst(pendingStartIndex)
        pendingStartIndex = 0
    }

    func appendPendingLine(_ line: PendingLine) {
        guard beforeContext > 0 else {
            return
        }
        pendingLines.append(line)
        if pendingLines.count - pendingStartIndex > beforeContext {
            pendingStartIndex += 1
            compactPendingLinesIfNeeded()
        }
    }

    func literal(_ literal: [UInt8], matchesAt offset: Int, lineEnd: Int) -> Bool {
        guard literal.count <= lineEnd - offset else {
            return false
        }
        for index in literal.indices where base[offset + index] != literal[index] {
            return false
        }
        return true
    }

    func foldedLiteral(_ literal: [UInt8], matchesAt offset: Int, lineEnd: Int) -> Bool {
        guard literal.count <= lineEnd - offset else {
            return false
        }
        for index in literal.indices where rgSwiftASCIILower(base[offset + index]) != literal[index] {
            return false
        }
        return true
    }

    func lineContainsAnyLiteral(lineStart: Int, lineEnd: Int) -> Bool {
        var searchOffset = lineStart
        while searchOffset < lineEnd {
            let foundPointer: UnsafePointer<UInt8>?
            if asciiCaseInsensitive {
                foundPointer = caseInsensitiveFirstBytes.withUnsafeBufferPointer { firstByteBuffer in
                    rg_memchr_any_bytes(
                        base.advanced(by: searchOffset),
                        lineEnd - searchOffset,
                        firstByteBuffer.baseAddress,
                        firstByteBuffer.count
                    )
                }
            } else {
                foundPointer = firstBytes.withUnsafeBufferPointer { firstByteBuffer in
                    rg_memchr_any_bytes(
                        base.advanced(by: searchOffset),
                        lineEnd - searchOffset,
                        firstByteBuffer.baseAddress,
                        firstByteBuffer.count
                    )
                }
            }
            guard let foundPointer else {
                return false
            }

            let matchStart = base.distance(to: foundPointer)
            if asciiCaseInsensitive {
                let foldedFirstByte = rgSwiftASCIILower(base[matchStart])
                for candidateLiteral in foldedLiterals
                    where candidateLiteral[0] == foldedFirstByte
                        && foldedLiteral(candidateLiteral, matchesAt: matchStart, lineEnd: lineEnd) {
                    return true
                }
            } else {
                let firstByte = base[matchStart]
                for candidateLiteral in activeLiterals
                    where candidateLiteral[0] == firstByte
                        && literal(candidateLiteral, matchesAt: matchStart, lineEnd: lineEnd) {
                    return true
                }
            }
            searchOffset = matchStart + 1
        }
        return false
    }

    func emitGroupSeparatorIfNeeded(for lineNumber: Int) -> Bool {
        guard previousEmittedLineNumber > 0,
              lineNumber > previousEmittedLineNumber + 1,
              let contextSeparator else {
            return true
        }
        return output.writeBytes(contextSeparator)
            && output.writeByte(UInt8(ascii: "\n"))
    }

    func emitLine(_ line: PendingLine) -> Bool {
        guard line.number > previousEmittedLineNumber else {
            return true
        }
        guard emitGroupSeparatorIfNeeded(for: line.number) else {
            return false
        }
        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
            return false
        }
        guard output.writeBytes(line.containsLiteral ? lineMatchPrefix : lineContextPrefix) else {
            return false
        }
        if lineNumber {
            guard output.writeLineNumberPrefix(
                line.number,
                fieldSeparator: line.containsLiteral
                    ? lineNumberFieldMatchSeparator
                    : lineNumberFieldContextSeparator
            ) else {
                return false
            }
        }
        guard output.write(base.advanced(by: line.start), count: line.outputEnd - line.start) else {
            return false
        }
        if !line.hasNewline,
           !output.writeByte(UInt8(ascii: "\n")) {
            return false
        }
        previousEmittedLineNumber = line.number
        return true
    }

    while lineStart < haystackLength {
        let newline = memchr(
            base.advanced(by: lineStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - lineStart
        )
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let hasNewline = newline != nil
        let outputEnd = hasNewline ? lineEnd + 1 : haystackLength
        let containsLiteral = lineContainsAnyLiteral(lineStart: lineStart, lineEnd: lineEnd)
        let currentLine = PendingLine(
            number: currentLineNumber,
            start: lineStart,
            outputEnd: outputEnd,
            hasNewline: hasNewline,
            containsLiteral: containsLiteral
        )

        if containsLiteral && matchedLineCount < maxCount {
            matchedLineCount += 1
            for pendingLine in pendingLines[pendingStartIndex...] {
                guard emitLine(pendingLine) else {
                    return nil
                }
            }
            guard emitLine(currentLine) else {
                return nil
            }
            remainingContextLines = afterContext
        } else if remainingContextLines > 0 {
            guard emitLine(currentLine) else {
                return nil
            }
            remainingContextLines -= 1
        }

        appendPendingLine(currentLine)
        lineStart = outputEnd
        currentLineNumber += 1
    }

    guard output.flush() else {
        return nil
    }
    return matchedLineCount
}

private func rgSwiftDarwinWritePassthruLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literal: UnsafeBufferPointer<UInt8>,
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    lineNumberFieldMatchSeparator: [UInt8],
    lineNumberFieldContextSeparator: [UInt8],
    lineMatchPrefix: [UInt8],
    lineContextPrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard let literalBase = literal.baseAddress,
          literal.count > 0 else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if let rawBinaryByte = memchr(base, 0, haystackLength) {
        let binaryByte = rawBinaryByte.assumingMemoryBound(to: UInt8.self)
        let binaryOffset = base.distance(to: binaryByte)
        if !asciiCaseInsensitive,
           !lineNumber,
           lineMatchPrefix.isEmpty,
           lineContextPrefix.isEmpty,
           headingPrefix.isEmpty,
           binaryOffset >= 64 * 1024 {
            let matchedBeforeBinary = rg_memmem_simple(
                base,
                binaryOffset,
                literalBase,
                literal.count
            ) != nil
            guard matchedBeforeBinary else {
                return 0
            }
            guard rgSwiftDarwinWriteBinaryFileMatchesMessage(binaryOffset: binaryOffset) else {
                return nil
            }
            return 1
        }
        return nil
    }
    if asciiCaseInsensitive {
        for byte in literal where byte >= 0x80 {
            return nil
        }
        if rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
            return nil
        }
    }

    if !asciiCaseInsensitive,
       !lineNumber,
       lineMatchPrefix.isEmpty,
       lineContextPrefix.isEmpty,
       headingPrefix.isEmpty,
       rg_memmem_simple(base, haystackLength, literalBase, literal.count) == nil {
        guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
            return nil
        }
        defer {
            output.deallocate()
        }
        guard output.write(base, count: haystackLength) else {
            return nil
        }
        if base[haystackLength - 1] != UInt8(ascii: "\n"),
           !output.writeByte(UInt8(ascii: "\n")) {
            return nil
        }
        guard output.flush() else {
            return nil
        }
        return 0
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    var matchedLineCount = 0
    var currentLineNumber = 1
    var lineStart = 0
    var emittedHeading = false
    let foldedLiteral = asciiCaseInsensitive
        ? (0..<literal.count).map { rgSwiftASCIILower(literalBase[$0]) }
        : []
    var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
    if asciiCaseInsensitive, foldedLiteral.count > 1 {
        for index in 0..<(foldedLiteral.count - 1) {
            caseInsensitiveShifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
        }
    }

    func lineContainsLiteral(lineStart: Int, lineEnd: Int) -> Bool {
        if asciiCaseInsensitive {
            return foldedLiteral.withUnsafeBufferPointer { foldedBuffer in
                caseInsensitiveShifts.withUnsafeBufferPointer { shifts in
                    rg_memcasemem_ascii_prepared(
                        base.advanced(by: lineStart),
                        lineEnd - lineStart,
                        foldedBuffer.baseAddress,
                        foldedBuffer.count,
                        shifts.baseAddress
                    ) != nil
                }
            }
        }
        return rg_memmem_simple(
            base.advanced(by: lineStart),
            lineEnd - lineStart,
            literalBase,
            literal.count
        ) != nil
    }

    while lineStart < haystackLength {
        let newline = memchr(
            base.advanced(by: lineStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - lineStart
        )
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let outputEnd = newline == nil ? haystackLength : lineEnd + 1
        let containsLiteral = lineContainsLiteral(lineStart: lineStart, lineEnd: lineEnd)

        if containsLiteral {
            matchedLineCount += 1
        }

        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
            return nil
        }
        guard output.writeBytes(containsLiteral ? lineMatchPrefix : lineContextPrefix) else {
            return nil
        }
        if lineNumber {
            guard output.writeLineNumberPrefix(
                currentLineNumber,
                fieldSeparator: containsLiteral
                    ? lineNumberFieldMatchSeparator
                    : lineNumberFieldContextSeparator
            ) else {
                return nil
            }
        }
        guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
            return nil
        }
        if newline == nil, !output.writeByte(UInt8(ascii: "\n")) {
            return nil
        }

        lineStart = outputEnd
        currentLineNumber += 1
    }

    guard output.flush() else {
        return nil
    }
    return matchedLineCount
}

private func rgSwiftDarwinWriteBinaryFileMatchesMessage(binaryOffset: Int) -> Bool {
    guard var output = rgSwiftStdoutBuffer(capacity: 128) else {
        return false
    }
    defer {
        output.deallocate()
    }
    return output.writeBytes(Array(#"binary file matches (found "\0" byte around offset "#.utf8))
        && output.writeLineNumberPrefix(binaryOffset, fieldSeparator: Array(")\n".utf8))
        && output.flush()
}

private func rgSwiftDarwinWritePassthruMultiLiteralLines(
    _ base: UnsafePointer<UInt8>,
    haystackLength: Int,
    literals: [[UInt8]],
    asciiCaseInsensitive: Bool,
    lineNumber: Bool,
    lineNumberFieldMatchSeparator: [UInt8],
    lineNumberFieldContextSeparator: [UInt8],
    lineMatchPrefix: [UInt8],
    lineContextPrefix: [UInt8],
    headingPrefix: [UInt8]
) -> Int? {
    guard !literals.isEmpty,
          literals.allSatisfy({ !$0.isEmpty }) else {
        return nil
    }
    if haystackLength >= 3,
       base[0] == 0xEF,
       base[1] == 0xBB,
       base[2] == 0xBF {
        return nil
    }
    if haystackLength >= 2,
       (base[0] == 0xFF && base[1] == 0xFE
        || base[0] == 0xFE && base[1] == 0xFF) {
        return nil
    }
    if memchr(base, 0, haystackLength) != nil {
        return nil
    }
    if asciiCaseInsensitive {
        guard literals.allSatisfy({ $0.allSatisfy { $0 < 0x80 } }) else {
            return nil
        }
        if rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
            return nil
        }
    }

    guard var output = rgSwiftStdoutBuffer(capacity: 1024 * 1024) else {
        return nil
    }
    defer {
        output.deallocate()
    }

    let firstBytes: [UInt8] = {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(literals.count)
        for literal in literals where !bytes.contains(literal[0]) {
            bytes.append(literal[0])
        }
        return bytes
    }()
    let foldedLiterals = asciiCaseInsensitive
        ? literals.map { $0.map(rgSwiftASCIILower) }
        : []
    let caseInsensitiveFirstBytes: [UInt8] = if asciiCaseInsensitive {
        {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(foldedLiterals.count * 2)
            for literal in foldedLiterals {
                let first = literal[0]
                if !bytes.contains(first) {
                    bytes.append(first)
                }
                if first >= UInt8(ascii: "a"), first <= UInt8(ascii: "z") {
                    let upper = first - 32
                    if !bytes.contains(upper) {
                        bytes.append(upper)
                    }
                }
            }
            return bytes
        }()
    } else {
        []
    }
    guard !firstBytes.isEmpty || !caseInsensitiveFirstBytes.isEmpty else {
        return nil
    }

    func literal(_ literal: [UInt8], matchesAt offset: Int, lineEnd: Int) -> Bool {
        guard literal.count <= lineEnd - offset else {
            return false
        }
        for index in literal.indices where base[offset + index] != literal[index] {
            return false
        }
        return true
    }

    func foldedLiteral(_ literal: [UInt8], matchesAt offset: Int, lineEnd: Int) -> Bool {
        guard literal.count <= lineEnd - offset else {
            return false
        }
        for index in literal.indices where rgSwiftASCIILower(base[offset + index]) != literal[index] {
            return false
        }
        return true
    }

    func lineContainsAnyLiteral(lineStart: Int, lineEnd: Int) -> Bool {
        var searchOffset = lineStart
        while searchOffset < lineEnd {
            let foundPointer: UnsafePointer<UInt8>?
            if asciiCaseInsensitive {
                foundPointer = caseInsensitiveFirstBytes.withUnsafeBufferPointer { firstByteBuffer in
                    rg_memchr_any_bytes(
                        base.advanced(by: searchOffset),
                        lineEnd - searchOffset,
                        firstByteBuffer.baseAddress,
                        firstByteBuffer.count
                    )
                }
            } else {
                foundPointer = firstBytes.withUnsafeBufferPointer { firstByteBuffer in
                    rg_memchr_any_bytes(
                        base.advanced(by: searchOffset),
                        lineEnd - searchOffset,
                        firstByteBuffer.baseAddress,
                        firstByteBuffer.count
                    )
                }
            }
            guard let foundPointer else {
                return false
            }

            let matchStart = base.distance(to: foundPointer)
            if asciiCaseInsensitive {
                let foldedFirstByte = rgSwiftASCIILower(base[matchStart])
                for candidateLiteral in foldedLiterals
                    where candidateLiteral[0] == foldedFirstByte
                        && foldedLiteral(candidateLiteral, matchesAt: matchStart, lineEnd: lineEnd) {
                    return true
                }
            } else {
                let firstByte = base[matchStart]
                for candidateLiteral in literals
                    where candidateLiteral[0] == firstByte
                        && literal(candidateLiteral, matchesAt: matchStart, lineEnd: lineEnd) {
                    return true
                }
            }
            searchOffset = matchStart + 1
        }
        return false
    }

    var matchedLineCount = 0
    var currentLineNumber = 1
    var lineStart = 0
    var emittedHeading = false

    while lineStart < haystackLength {
        let newline = memchr(
            base.advanced(by: lineStart),
            Int32(UInt8(ascii: "\n")),
            haystackLength - lineStart
        )
        let lineEnd = newline.map {
            base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
        } ?? haystackLength
        let outputEnd = newline == nil ? haystackLength : lineEnd + 1
        let containsLiteral = lineContainsAnyLiteral(lineStart: lineStart, lineEnd: lineEnd)

        if containsLiteral {
            matchedLineCount += 1
        }

        guard output.writeHeadingPrefix(headingPrefix, emittedHeading: &emittedHeading) else {
            return nil
        }
        guard output.writeBytes(containsLiteral ? lineMatchPrefix : lineContextPrefix) else {
            return nil
        }
        if lineNumber {
            guard output.writeLineNumberPrefix(
                currentLineNumber,
                fieldSeparator: containsLiteral
                    ? lineNumberFieldMatchSeparator
                    : lineNumberFieldContextSeparator
            ) else {
                return nil
            }
        }
        guard output.write(base.advanced(by: lineStart), count: outputEnd - lineStart) else {
            return nil
        }
        if newline == nil, !output.writeByte(UInt8(ascii: "\n")) {
            return nil
        }

        lineStart = outputEnd
        currentLineNumber += 1
    }

    guard output.flush() else {
        return nil
    }
    return matchedLineCount
}

@inline(__always)
private func rgSwiftIsASCIIRegexWordByte(_ byte: UInt8) -> Bool {
    (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
        || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
        || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
        || byte == UInt8(ascii: "_")
}

@inline(__always)
private func rgSwiftIsASCIIRegexWhitespaceByte(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || (byte >= 0x09 && byte <= 0x0D)
}
#endif
