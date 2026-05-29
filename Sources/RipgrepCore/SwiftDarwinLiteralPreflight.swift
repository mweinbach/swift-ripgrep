import Foundation

#if !canImport(CRipgrepPlatform) && canImport(Darwin)
import Darwin

public enum SwiftDarwinLiteralPreflight {
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
        let wrotePath = if let outputPath {
            outputPath.withUnsafeBufferPointer { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return true
                }
                return fwrite(baseAddress, 1, bytes.count, Darwin.stdout) == bytes.count
            }
        } else {
            path.withCString { cString in
                let byteCount = strlen(cString)
                return fwrite(cString, 1, byteCount, Darwin.stdout) == byteCount
            }
        }
        guard wrotePath else {
            return false
        }
        return writePathTerminator(
            nullTerminated: nullTerminated,
            crlfTerminated: crlfTerminated
        )
    }

    public static func quietExitCode(
        path: String,
        literal: [UInt8]
    ) -> Int32? {
        guard let matched = containsLiteral(path: path, literal: literal) else {
            return nil
        }
        return matched ? 0 : 1
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

        let needle = Data(literal)
        let newline = UInt8(ascii: "\n")
        let limit = maxCount ?? Int.max
        var searchStart = data.startIndex
        var matchedLineCount = 0

        while matchedLineCount < limit,
              searchStart < data.endIndex,
              let matchRange = data.range(of: needle, in: searchStart..<data.endIndex) {
            guard !matchRange.isEmpty else {
                return nil
            }
            matchedLineCount += 1
            let lineEnd = data[matchRange.upperBound...]
                .firstIndex(of: newline) ?? data.endIndex
            searchStart = lineEnd < data.endIndex
                ? data.index(after: lineEnd)
                : data.endIndex
        }

        if matchedLineCount > 0 || includeZero {
            guard writeCountOutput(matchedLineCount, crlfTerminated: crlfTerminated) else {
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
            return asciiCaseVariants(for: literal).count == 1 ? false : nil
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
        let variants = asciiCaseVariants(for: literal)
        for variant in variants where data.range(of: Data(variant)) != nil {
            return true
        }
        return variants.count == 1 ? false : nil
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

    private static func asciiCaseVariants(for literal: [UInt8]) -> [[UInt8]] {
        var variants = [literal]
        let lowercase = literal.map(rgSwiftASCIILower)
        if lowercase != literal {
            variants.append(lowercase)
        }
        let uppercase = literal.map(rgSwiftASCIIUpper)
        if uppercase != literal && uppercase != lowercase {
            variants.append(uppercase)
        }
        return variants
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

        let needle = Data(literal)
        var searchStart = data.startIndex
        var rejectedBoundaryCandidates = 0
        let maxRejectedBoundaryCandidates = 128
        while searchStart < data.endIndex,
              let matchRange = data.range(of: needle, in: searchStart..<data.endIndex) {
            guard !matchRange.isEmpty else {
                return nil
            }
            guard let bounded = isASCIIWordBoundaryMatch(data: data, matchRange: matchRange) else {
                return nil
            }
            if bounded {
                return true
            }
            rejectedBoundaryCandidates += 1
            guard rejectedBoundaryCandidates <= maxRejectedBoundaryCandidates else {
                return nil
            }
            searchStart = data.index(after: matchRange.lowerBound)
        }
        return false
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
        requireASCIIHaystack: Bool = false
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
                headingPrefix: headingPrefix,
                emitLines: emitLines,
                maxCount: maxCount,
                requireASCIIHaystack: requireASCIIHaystack
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
        }) else {
            return nil
        }
        return matchedLineCount > 0 ? 0 : 1
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
                    var rejectedBoundaryCandidates = 0
                    let maxRejectedBoundaryCandidates = 128

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
                            rejectedBoundaryCandidates += 1
                            guard rejectedBoundaryCandidates <= maxRejectedBoundaryCandidates else {
                                return nil
                            }
                            searchOffset = matchStart + 1
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
        var matchCount = 0
        for literal in literals {
            matchCount += countNonOverlappingMatches(in: data, literal: literal)
        }
        return matchCount
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
        return matchedLineCount > 0 ? 0 : 1
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
            var caseInsensitiveShifts = [Int](repeating: literal.count, count: 256)
            if asciiCaseInsensitive, foldedLiteral.count > 1 {
                for index in 0..<(foldedLiteral.count - 1) {
                    caseInsensitiveShifts[Int(foldedLiteral[index])] = foldedLiteral.count - 1 - index
                }
            }

            var searchOffset = 0
            var matchCount = 0
            var rejectedBoundaryCandidates = 0
            let maxRejectedBoundaryCandidates = 128
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
                    rejectedBoundaryCandidates += 1
                    guard rejectedBoundaryCandidates <= maxRejectedBoundaryCandidates else {
                        return nil
                    }
                    searchOffset = matchStart + 1
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
            var rejectedBoundaryCandidates = 0
            let maxRejectedBoundaryCandidates = 128
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
                    rejectedBoundaryCandidates += 1
                    guard rejectedBoundaryCandidates <= maxRejectedBoundaryCandidates else {
                        return nil
                    }
                    searchOffset = matchStart + 1
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
        var searchOffset = 0
        var matchedLineCount = 0
        var rejectedBoundaryCandidates = 0
        let maxRejectedBoundaryCandidates = 128

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

                        rejectedBoundaryCandidates += 1
                        guard rejectedBoundaryCandidates <= maxRejectedBoundaryCandidates else {
                            needsFallback = true
                            return
                        }
                        literalSearchOffset = matchStart + 1
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
        var rejectedBoundaryCandidates = 0
        let maxRejectedBoundaryCandidates = 128
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

                            rejectedBoundaryCandidates += 1
                            guard rejectedBoundaryCandidates <= maxRejectedBoundaryCandidates else {
                                needsFallback = true
                                return
                            }
                            literalSearchOffset = matchStart + 1
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
        let maxRejectedBoundaryCandidates = 128
        var currentLineNumber = 1
        var lineCountOffset = 0
        var emittedHeading = false
        let simpleOutput = !lineNumber && linePrefix.isEmpty && headingPrefix.isEmpty
        var pendingOutputStart: Int?
        var pendingOutputEnd = 0
        var pendingNeedsFinalNewline = false

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
                            guard rejectedBoundaryCandidates <= maxRejectedBoundaryCandidates else {
                                needsFallback = true
                                return
                            }
                            literalSearchOffset = matchStart + 1
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

@inline(__always)
private func rgSwiftASCIIUpper(_ byte: UInt8) -> UInt8 {
    byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
        ? byte - (UInt8(ascii: "a") - UInt8(ascii: "A"))
        : byte
}

private struct rgSwiftStdoutBuffer {
    private let storage: UnsafeMutablePointer<UInt8>
    private var length = 0
    private let capacity: Int

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
            return fwrite(bytes, 1, count, Darwin.stdout) == count
        }
        if length + count > capacity, !flush() {
            return false
        }
        storage.advanced(by: length).update(from: bytes, count: count)
        length += count
        return true
    }

    mutating func writeByte(_ byte: UInt8) -> Bool {
        if length == capacity, !flush() {
            return false
        }
        storage[length] = byte
        length += 1
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
    requireASCIIHaystack: Bool = false
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
    if requireASCIIHaystack,
       rgSwiftContainsNonASCIIByte(base, count: haystackLength) {
        return nil
    }

    var output = emitLines ? rgSwiftStdoutBuffer(capacity: 1024 * 1024) : nil
    if emitLines, output == nil {
        return nil
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
        while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
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

        if lineStart != lastEmittedLineStart {
            let outputEnd = newline.map {
                base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) + 1
            } ?? haystackLength
            if emitLines {
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

    guard !writeFailed else {
        return nil
    }
    if emitLines {
        guard output?.flush() == true else {
            return nil
        }
    }
    return matchedLineCount
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
                    newline
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

        for index in candidates.indices where candidates[index].start < nextSearchOffset {
            candidates[index] = nextCandidate(
                literalIndex: candidates[index].literalIndex,
                from: nextSearchOffset
            )
        }
    }

    guard output.flush() else {
        return nil
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

        let literalStart = base.distance(to: found)
        let literalEnd = literalStart + literal.count
        let matchedLineNumber = lineNumberAtSearchOffset + Int(result.count)
        var lineStart = literalStart
        while lineStart > 0, base[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
        }
        let newline = memchr(found, Int32(UInt8(ascii: "\n")), haystackLength - literalStart)
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
