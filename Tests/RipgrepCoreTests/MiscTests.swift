import Foundation
import Testing
@testable import RipgrepCore

@Suite("Ripgrep misc parity area", .serialized)
struct MiscTests {
    @Test("finds matching lines recursively")
    func findsMatchingLinesRecursively() throws {
        let root = try TemporaryDirectory()
        try root.write("alpha\nneedle here\nomega\n", to: "one.txt")
        try root.createDirectory("nested")
        try root.write("another needle\n", to: "nested/two.txt")

        let matches = try RipgrepSearcher().search(
            pattern: "needle",
            roots: [root.url]
        )

        #expect(Set(matches.map(\.line)) == Set(["another needle", "needle here"]))
        #expect(Dictionary(uniqueKeysWithValues: matches.map { ($0.line, $0.lineNumber) }) == [
            "another needle": 1,
            "needle here": 2,
        ])
    }

    @Test("case-insensitive alternation preserves recursive line output")
    func caseInsensitiveAlternationPreservesRecursiveLineOutput() throws {
        let root = try TemporaryDirectory()
        try root.write("quiet\nerr_sys reached\nquiet\n", to: "drivers/one.c")
        try root.write("cfg_bme_evt and link_req_rst\nquiet\nPME_TURN_OFF\n", to: "drivers/two.c")
        try root.write("quiet\nERR_SYS café\n", to: "drivers/unicode.c")

        let output = try run([
            "-n",
            "-i",
            "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT",
            root.url.path,
        ])

        #expect(Set(output) == Set([
            "\(root.path("drivers/one.c")):2:err_sys reached",
            "\(root.path("drivers/two.c")):1:cfg_bme_evt and link_req_rst",
            "\(root.path("drivers/two.c")):3:PME_TURN_OFF",
            "\(root.path("drivers/unicode.c")):2:ERR_SYS café",
        ]))
    }

    @Test("no-literal word whitespace regex preserves Unicode and ASCII output")
    func noLiteralWordWhitespaceRegexPreservesUnicodeAndASCIIOutput() throws {
        let root = try TemporaryDirectory()
        try root.write("""
        alpha bravo charl delta echoo
        abcdef bravo charl delta echoo
        short words nope here
        perche il contesto delle righe verra cambiato.
        perché il contesto delle righe verrà cambiato.
        alpha bravo charl delta echoo foxtt golfx
        aaaaa bbbbb ccccc ddddd ééééé fffff ggggg
        alpha bravo charlie delta echoo
        Oh, what a handful these girls become without their mother!
        café
        """, to: "words.txt")
        let pattern = #"\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}"#
        let sevenGroupPattern = #"\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}"#

        let unicodeOutput = try runExecutableData([
            "-n",
            pattern,
            root.path("words.txt"),
        ], fixture: {})
        let streamingUnicodeOutput = try runExecutableData([
            "--no-mmap",
            "-n",
            pattern,
            root.path("words.txt"),
        ], fixture: {})
        let asciiOutput = try runExecutableData([
            "-n",
            "(?-u)\(pattern)",
            root.path("words.txt"),
        ], fixture: {})
        let sevenGroupUnicodeOutput = try runExecutableData([
            "-n",
            sevenGroupPattern,
            root.path("words.txt"),
        ], fixture: {})
        let sevenGroupASCIIOutput = try runExecutableData([
            "-n",
            "(?-u)\(sevenGroupPattern)",
            root.path("words.txt"),
        ], fixture: {})

        #expect(String(decoding: unicodeOutput, as: UTF8.self) == """
        1:alpha bravo charl delta echoo
        2:abcdef bravo charl delta echoo
        4:perche il contesto delle righe verra cambiato.
        5:perché il contesto delle righe verrà cambiato.
        6:alpha bravo charl delta echoo foxtt golfx
        7:aaaaa bbbbb ccccc ddddd ééééé fffff ggggg

        """)
        #expect(streamingUnicodeOutput == unicodeOutput)
        #expect(String(decoding: asciiOutput, as: UTF8.self) == """
        1:alpha bravo charl delta echoo
        2:abcdef bravo charl delta echoo
        4:perche il contesto delle righe verra cambiato.
        6:alpha bravo charl delta echoo foxtt golfx

        """)
        #expect(String(decoding: sevenGroupUnicodeOutput, as: UTF8.self) == """
        6:alpha bravo charl delta echoo foxtt golfx
        7:aaaaa bbbbb ccccc ddddd ééééé fffff ggggg

        """)
        #expect(String(decoding: sevenGroupASCIIOutput, as: UTF8.self) == """
        6:alpha bravo charl delta echoo foxtt golfx

        """)

        let largeFillerLineCount = 600_000
        let largeFiller = String(repeating: "tiny words here\n", count: largeFillerLineCount)
        try root.write(largeFiller + """
        alpha bravo charl delta echoo foxtt golfx
        short words nope here
        bravo charl delta echoo foxtt golfx hotel
        aaaaa bbbbb ccccc ddddd ééééé fffff ggggg
        """, to: "large-words.txt")
        let largeSevenGroupASCIIOutput = try runExecutableData([
            "-n",
            "(?-u)\(sevenGroupPattern)",
            root.path("large-words.txt"),
        ], fixture: {})
        #expect(String(decoding: largeSevenGroupASCIIOutput, as: UTF8.self) == """
        \(largeFillerLineCount + 1):alpha bravo charl delta echoo foxtt golfx
        \(largeFillerLineCount + 3):bravo charl delta echoo foxtt golfx hotel

        """)
        let largeSevenGroupUnicodeOutput = try runExecutableData([
            "-n",
            sevenGroupPattern,
            root.path("large-words.txt"),
        ], fixture: {})
        #expect(String(decoding: largeSevenGroupUnicodeOutput, as: UTF8.self) == """
        \(largeFillerLineCount + 1):alpha bravo charl delta echoo foxtt golfx
        \(largeFillerLineCount + 3):bravo charl delta echoo foxtt golfx hotel
        \(largeFillerLineCount + 4):aaaaa bbbbb ccccc ddddd ééééé fffff ggggg

        """)
    }

    @Test("word-prefix literal regex preserves Unicode and ASCII output")
    func wordPrefixLiteralRegexPreservesUnicodeAndASCIIOutput() throws {
        let root = try TemporaryDirectory()
        try root.write("""
        xAh
        _Ah
         Ah
        -Ah
        éAh
        zzz
        """, to: "word-prefix.txt")

        let unicodeOutput = try runExecutableData([
            "-n",
            #"\wAh"#,
            root.path("word-prefix.txt"),
        ], fixture: {})
        #expect(String(decoding: unicodeOutput, as: UTF8.self) == """
        1:xAh
        2:_Ah
        5:éAh

        """)

        let asciiOutput = try runExecutableData([
            "-n",
            #"(?-u)\wAh"#,
            root.path("word-prefix.txt"),
        ], fixture: {})
        #expect(String(decoding: asciiOutput, as: UTF8.self) == """
        1:xAh
        2:_Ah

        """)
    }

    @Test("word regexp line numbers survive rejected same-line candidate")
    func wordRegexpLineNumbersSurviveRejectedSameLineCandidate() throws {
        let root = try TemporaryDirectory()
        try root.write("""
        before
        xSherlock Holmes Sherlock Holmes
        after
        """, to: "word-boundary-line-number.txt")

        let output = try runExecutableData([
            "-n",
            "-w",
            "Sherlock Holmes",
            root.path("word-boundary-line-number.txt"),
        ], fixture: {})
        #expect(String(decoding: output, as: UTF8.self) == """
        2:xSherlock Holmes Sherlock Holmes

        """)
    }

    @Test("executable word literal preflight preserves Unicode fallback output")
    func executableWordLiteralPreflightPreservesUnicodeFallbackOutput() throws {
        let root = try TemporaryDirectory()
        try root.write("""
        Sherlock Holmes
        xSherlock Holmes
        Sherlock Holmesx
        Sherlock Holmes again
        """, to: "ascii-word-literal.txt")

        let compactFlagOutput = try runExecutableData([
            "-nw",
            "Sherlock Holmes",
            root.path("ascii-word-literal.txt"),
        ], fixture: {})
        #expect(String(decoding: compactFlagOutput, as: UTF8.self) == """
        1:Sherlock Holmes
        4:Sherlock Holmes again

        """)

        let splitFlagOutput = try runExecutableData([
            "-w",
            "-n",
            "Sherlock Holmes",
            root.path("ascii-word-literal.txt"),
        ], fixture: {})
        #expect(splitFlagOutput == compactFlagOutput)

        let plainWordOutput = try runExecutableData([
            "-w",
            "Sherlock Holmes",
            root.path("ascii-word-literal.txt"),
        ], fixture: {})
        #expect(String(decoding: plainWordOutput, as: UTF8.self) == """
        Sherlock Holmes
        Sherlock Holmes again

        """)

        try root.write("Sherlock Holmes", to: "word-literal-no-final-newline.txt")
        let noFinalNewlineOutput = try runExecutableData([
            "-nw",
            "Sherlock Holmes",
            root.path("word-literal-no-final-newline.txt"),
        ], fixture: {})
        #expect(noFinalNewlineOutput == Data("1:Sherlock Holmes\n".utf8))

        let plainNoFinalNewlineOutput = try runExecutableData([
            "-w",
            "Sherlock Holmes",
            root.path("word-literal-no-final-newline.txt"),
        ], fixture: {})
        #expect(plainNoFinalNewlineOutput == Data("Sherlock Holmes\n".utf8))

        try root.write("""
        Sherlock Holmes
        éSherlock Holmes
        Sherlock Holmesé
        Sherlock Holmes again
        """, to: "unicode-word-literal.txt")
        let unicodeBoundaryOutput = try runExecutableData([
            "-n",
            "-w",
            "Sherlock Holmes",
            root.path("unicode-word-literal.txt"),
        ], fixture: {})
        #expect(String(decoding: unicodeBoundaryOutput, as: UTF8.self) == """
        1:Sherlock Holmes
        4:Sherlock Holmes again

        """)

        let plainUnicodeBoundaryOutput = try runExecutableData([
            "-w",
            "Sherlock Holmes",
            root.path("unicode-word-literal.txt"),
        ], fixture: {})
        #expect(plainUnicodeBoundaryOutput == plainWordOutput)
    }

    @Test("ASCII boundary literal regex preserves byte boundary output")
    func asciiBoundaryLiteralRegexPreservesByteBoundaryOutput() throws {
        let root = try TemporaryDirectory()
        try root.write("""
        Sherlock Holmes
        xSherlock Holmes
        Sherlock HolmesX
        _Sherlock Holmes
        Sherlock Holmes_
        éSherlock Holmes!
        """, to: "ascii-boundary.txt")

        let output = try runExecutableData([
            "-n",
            #"(?-u:\b)Sherlock Holmes(?-u:\b)"#,
            root.path("ascii-boundary.txt"),
        ], fixture: {})
        #expect(String(decoding: output, as: UTF8.self) == """
        1:Sherlock Holmes
        6:éSherlock Holmes!

        """)

        let prefixedOutput = try runExecutableData([
            "-H",
            "-n",
            #"(?-u:\b)Sherlock Holmes(?-u:\b)"#,
            root.path("ascii-boundary.txt"),
        ], fixture: {})
        #expect(String(decoding: prefixedOutput, as: UTF8.self) == """
        \(root.path("ascii-boundary.txt")):1:Sherlock Holmes
        \(root.path("ascii-boundary.txt")):6:éSherlock Holmes!

        """)
    }

    @Test("streams simple Darwin byte literal lines")
    func streamsSimpleDarwinByteLiteralLines() throws {
        #if canImport(Darwin)
        let root = try TemporaryDirectory()
        let file = root.url.appendingPathComponent("letters.txt")
        try root.write("alpha\nbravo\ncharlie\ndelta", to: "letters.txt")

        var options = RipgrepOptions()
        options.pattern = "delta"
        options.roots = [file]
        options.rootPathArguments = [file.path]

        var output = Data()
        let results = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: options) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            output.append(baseAddress, count: bytes.count)
        }

        #expect(results?.summary.filesWithMatches == 1)
        #expect(results?.summary.matchedLines == 1)
        #expect(output == Data("delta\n".utf8))

        var lineFieldOptions = options
        lineFieldOptions.byteOffset = true
        lineFieldOptions.column = true
        var lineFieldOutput = Data()
        let lineFieldResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: lineFieldOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            lineFieldOutput.append(baseAddress, count: bytes.count)
        }
        #expect(lineFieldResults?.summary.matchedLines == 1)
        #expect(lineFieldOutput == Data("4:1:20:delta\n".utf8))

        var ignoreCaseOptions = options
        ignoreCaseOptions.pattern = "DELTA"
        ignoreCaseOptions.ignoreCase = true
        var ignoreCaseOutput = Data()
        let ignoreCaseResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: ignoreCaseOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            ignoreCaseOutput.append(baseAddress, count: bytes.count)
        }
        #expect(ignoreCaseResults?.summary.matchedLines == 1)
        #expect(ignoreCaseOutput == Data("delta\n".utf8))

        var mmapOptions = options
        mmapOptions.mmapMode = .always
        var mmapOutput = Data()
        let mmapResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: mmapOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            mmapOutput.append(baseAddress, count: bytes.count)
        }
        #expect(mmapResults?.summary.matchedLines == 1)
        #expect(mmapOutput == Data("delta\n".utf8))

        var fixedOptions = options
        fixedOptions.pattern = "charlie"
        fixedOptions.fixedStrings = true
        var fixedOutput = Data()
        let fixedResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: fixedOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            fixedOutput.append(baseAddress, count: bytes.count)
        }
        #expect(fixedResults?.summary.matchedLines == 1)
        #expect(fixedOutput == Data("charlie\n".utf8))

        var countOptions = options
        countOptions.pattern = "a"
        countOptions.printMode = .count
        var countOutput = Data()
        let countResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: countOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            countOutput.append(baseAddress, count: bytes.count)
        }
        #expect(countResults?.summary.matchedLines == 4)
        #expect(countOutput == Data("4\n".utf8))

        var countNoMatchOptions = countOptions
        countNoMatchOptions.pattern = "missing"
        var countNoMatchOutput = Data()
        let countNoMatchResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: countNoMatchOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            countNoMatchOutput.append(baseAddress, count: bytes.count)
        }
        #expect(countNoMatchResults?.summary.matchedLines == 0)
        #expect(countNoMatchOutput.isEmpty)

        var countMatchesOptions = options
        countMatchesOptions.pattern = "a"
        countMatchesOptions.printMode = .countMatches
        var countMatchesOutput = Data()
        let countMatchesResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: countMatchesOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            countMatchesOutput.append(baseAddress, count: bytes.count)
        }
        #expect(countMatchesResults?.summary.matchedLines == 4)
        #expect(countMatchesResults?.summary.totalMatches == 5)
        #expect(countMatchesOutput == Data("5\n".utf8))

        var onlyMatchingOptions = options
        onlyMatchingOptions.pattern = "delta"
        onlyMatchingOptions.onlyMatching = true
        var onlyMatchingOutput = Data()
        let onlyMatchingResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: onlyMatchingOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            onlyMatchingOutput.append(baseAddress, count: bytes.count)
        }
        #expect(onlyMatchingResults?.summary.matchedLines == 1)
        #expect(onlyMatchingResults?.summary.totalMatches == 1)
        #expect(onlyMatchingOutput == Data("delta\n".utf8))

        var onlyMatchingLineNumberOptions = onlyMatchingOptions
        onlyMatchingLineNumberOptions.lineNumber = true
        var onlyMatchingLineNumberOutput = Data()
        let onlyMatchingLineNumberResults = try RipgrepSearcher()
            .writeDarwinSimpleByteLiteralLines(options: onlyMatchingLineNumberOptions) { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                onlyMatchingLineNumberOutput.append(baseAddress, count: bytes.count)
            }
        #expect(onlyMatchingLineNumberResults?.summary.matchedLines == 1)
        #expect(onlyMatchingLineNumberResults?.summary.totalMatches == 1)
        #expect(onlyMatchingLineNumberOutput == Data("4:delta\n".utf8))

        var onlyMatchingFieldOptions = onlyMatchingOptions
        onlyMatchingFieldOptions.byteOffset = true
        onlyMatchingFieldOptions.column = true
        var onlyMatchingFieldOutput = Data()
        let onlyMatchingFieldResults = try RipgrepSearcher()
            .writeDarwinSimpleByteLiteralLines(options: onlyMatchingFieldOptions) { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                onlyMatchingFieldOutput.append(baseAddress, count: bytes.count)
            }
        #expect(onlyMatchingFieldResults?.summary.matchedLines == 1)
        #expect(onlyMatchingFieldResults?.summary.totalMatches == 1)
        #expect(onlyMatchingFieldOutput == Data("4:1:20:delta\n".utf8))

        var quietCountOutput = Data()
        var quietCountOptions = countOptions
        quietCountOptions.quiet = true
        let quietCountResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: quietCountOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            quietCountOutput.append(baseAddress, count: bytes.count)
        }
        #expect(quietCountResults?.summary.filesWithMatches == 1)
        #expect(quietCountOutput.isEmpty)

        var filesWithOptions = options
        filesWithOptions.printMode = .filesWithMatches
        var filesWithOutput = Data()
        let filesWithResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: filesWithOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            filesWithOutput.append(baseAddress, count: bytes.count)
        }
        #expect(filesWithResults?.summary.filesWithMatches == 1)
        #expect(filesWithOutput == Data("\(file.path)\n".utf8))

        var filesWithoutOptions = options
        filesWithoutOptions.pattern = "missing"
        filesWithoutOptions.printMode = .filesWithoutMatch
        var filesWithoutOutput = Data()
        let filesWithoutResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: filesWithoutOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            filesWithoutOutput.append(baseAddress, count: bytes.count)
        }
        #expect(filesWithoutResults?.summary.filesWithMatches == 0)
        #expect(filesWithoutOutput == Data("\(file.path)\n".utf8))

        var wordOptions = options
        wordOptions.pattern = "ha"
        wordOptions.wordRegexp = true
        var wordOutput = Data()
        let wordResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: wordOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            wordOutput.append(baseAddress, count: bytes.count)
        }
        #expect(wordResults?.summary.matchedLines == 0)
        #expect(wordOutput.isEmpty)

        var lineNumberOptions = options
        lineNumberOptions.pattern = "b|d"
        lineNumberOptions.lineNumber = true
        var lineNumberOutput = Data()
        let lineNumberResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: lineNumberOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            lineNumberOutput.append(baseAddress, count: bytes.count)
        }
        #expect(lineNumberResults?.summary.matchedLines == 2)
        #expect(lineNumberOutput == Data("2:bravo\n4:delta\n".utf8))

        var multiByteAlternationOptions = options
        multiByteAlternationOptions.pattern = "bravo|delta"
        multiByteAlternationOptions.lineNumber = true
        var multiByteAlternationOutput = Data()
        let multiByteAlternationResults = try RipgrepSearcher()
            .writeDarwinSimpleByteLiteralLines(options: multiByteAlternationOptions) { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                multiByteAlternationOutput.append(baseAddress, count: bytes.count)
            }
        #expect(multiByteAlternationResults?.summary.matchedLines == 2)
        #expect(multiByteAlternationOutput == Data("2:bravo\n4:delta\n".utf8))

        var multiByteCountOptions = multiByteAlternationOptions
        multiByteCountOptions.lineNumber = false
        multiByteCountOptions.printMode = .count
        var multiByteCountOutput = Data()
        let multiByteCountResults = try RipgrepSearcher()
            .writeDarwinSimpleByteLiteralLines(options: multiByteCountOptions) { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                multiByteCountOutput.append(baseAddress, count: bytes.count)
            }
        #expect(multiByteCountResults?.summary.matchedLines == 2)
        #expect(multiByteCountOutput == Data("2\n".utf8))

        var multiByteCountMatchesOptions = multiByteCountOptions
        multiByteCountMatchesOptions.printMode = .countMatches
        let multiByteCountMatchesResults = try RipgrepSearcher()
            .writeDarwinSimpleByteLiteralLines(options: multiByteCountMatchesOptions) { _ in
                Issue.record("multi-byte count-matches should stay on the ordered span path")
            }
        #expect(multiByteCountMatchesResults == nil)

        var quietOptions = options
        quietOptions.quiet = true
        var quietOutput = Data()
        let quietResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: quietOptions) { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            quietOutput.append(baseAddress, count: bytes.count)
        }
        #expect(quietResults?.summary.filesWithMatches == 1)
        #expect(quietResults?.summary.matchedLines == 1)
        #expect(quietOutput.isEmpty)

        var quietNoMatchOptions = quietOptions
        quietNoMatchOptions.pattern = "missing"
        let quietNoMatchResults = try RipgrepSearcher().writeDarwinSimpleByteLiteralLines(options: quietNoMatchOptions) { _ in
            Issue.record("quiet no-match search should not write output")
        }
        #expect(quietNoMatchResults?.summary.filesWithMatches == 0)
        #expect(quietNoMatchResults?.summary.matchedLines == 0)
        #endif
    }

    @Test("Darwin executable fast path preserves surrounding-word line numbers")
    func darwinExecutableFastPathSurroundingWordsLineNumbers() throws {
        #if canImport(Darwin)
        let root = try TemporaryDirectory()
        try root.write("""
        Holmes here
        Mr Holmes returns
        Holmes alone
        Doctor Holmes arrives
        """, to: "sherlock.txt")

        let output = try runExecutableData([
            "-n",
            #"\w+\s+Holmes\s+\w+"#,
            root.path("sherlock.txt"),
        ], fixture: {})

        #expect(String(decoding: output, as: UTF8.self) == "2:Mr Holmes returns\n4:Doctor Holmes arrives\n")

        let lineBufferedOutput = try runExecutableData([
            "--line-buffered",
            "-n",
            #"\w+\s+Holmes\s+\w+"#,
            root.path("sherlock.txt"),
        ], fixture: {})
        #expect(lineBufferedOutput == output)

        let filenameOutput = try runExecutableData([
            "--with-filename",
            "-n",
            #"\w+\s+Holmes\s+\w+"#,
            root.path("sherlock.txt"),
        ], fixture: {})
        #expect(String(decoding: filenameOutput, as: UTF8.self) == """
        \(root.path("sherlock.txt")):2:Mr Holmes returns
        \(root.path("sherlock.txt")):4:Doctor Holmes arrives

        """)

        try root.write("""
        Mr Holmes.Jr returns
        Mr HolmesxJr returns
        Doctor Holmes.Jr arrives
        """, to: "escaped-sherlock.txt")

        let escapedOutput = try runExecutableData([
            "-n",
            #"\w+\s+Holmes\.Jr\s+\w+"#,
            root.path("escaped-sherlock.txt"),
        ], fixture: {})

        #expect(String(decoding: escapedOutput, as: UTF8.self) == "1:Mr Holmes.Jr returns\n3:Doctor Holmes.Jr arrives\n")

        try root.write("""
        Mr Holmes returns
        Mø Holmes returns
        Dr Holmes étrange
        Holmes alone
        """, to: "unicode-sherlock.txt")
        let unicodeFallbackOutput = try runExecutableData([
            "-n",
            #"\w+\s+Holmes\s+\w+"#,
            root.path("unicode-sherlock.txt"),
        ], fixture: {})
        #expect(String(decoding: unicodeFallbackOutput, as: UTF8.self) == """
        1:Mr Holmes returns
        2:Mø Holmes returns
        3:Dr Holmes étrange

        """)

        let asciiScopedOutput = try runExecutableData([
            "-n",
            #"(?-u)\w+\s+Holmes\s+\w+"#,
            root.path("unicode-sherlock.txt"),
        ], fixture: {})
        #expect(String(decoding: asciiScopedOutput, as: UTF8.self) == """
        1:Mr Holmes returns

        """)

        try root.write("Mr Holmes returns", to: "sherlock-no-final-newline.txt")
        let noFinalNewlineOutput = try runExecutableData([
            "-n",
            #"(?-u)\w+\s+Holmes\s+\w+"#,
            root.path("sherlock-no-final-newline.txt"),
        ], fixture: {})
        #expect(noFinalNewlineOutput == Data("1:Mr Holmes returns\n".utf8))
        #endif
    }

    @Test("Darwin executable fast path preserves byte alternation output")
    func darwinExecutableFastPathByteAlternation() throws {
        #if canImport(Darwin)
        let root = try TemporaryDirectory()
        try root.write("alpha\nbravo\ncharlie\ndelta\n", to: "letters.txt")

        let output = try runExecutableData([
            "b|d",
            root.path("letters.txt"),
        ], fixture: {})

        #expect(String(decoding: output, as: UTF8.self) == "bravo\ndelta\n")

        let multiByteOutput = try runExecutableData([
            "-n",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})

        #expect(String(decoding: multiByteOutput, as: UTF8.self) == "2:bravo\n4:delta\n")

        let ignoreCaseMultiByteOutput = try runExecutableData([
            "-i",
            "BRAVO|DELTA",
            root.path("letters.txt"),
        ], fixture: {})
        #expect(String(decoding: ignoreCaseMultiByteOutput, as: UTF8.self) == "bravo\ndelta\n")

        try root.write("bravo\nBRAVO\ndelta\nDELTA\n", to: "case-letters.txt")
        let mixedCaseMultiByteOutput = try runExecutableData([
            "-i",
            "BRAVO|DELTA",
            root.path("case-letters.txt"),
        ], fixture: {})
        #expect(String(decoding: mixedCaseMultiByteOutput, as: UTF8.self) == "bravo\nBRAVO\ndelta\nDELTA\n")

        try root.write("sherlocked\nSherlock\nWatson!\nWatsonian\n", to: "words.txt")
        let wordMultiByteOutput = try runExecutableData([
            "-w",
            "Sherlock|Watson",
            root.path("words.txt"),
        ], fixture: {})
        #expect(String(decoding: wordMultiByteOutput, as: UTF8.self) == "Sherlock\nWatson!\n")

        let boundedMultiByteOutput = try runExecutableData([
            "-m1",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})

        #expect(String(decoding: boundedMultiByteOutput, as: UTF8.self) == "bravo\n")
        let boundedTwoMultiByteOutput = try runExecutableData([
            "-m2",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        #expect(String(decoding: boundedTwoMultiByteOutput, as: UTF8.self) == "bravo\ndelta\n")

        let explicitMmapBoundedMultiByteOutput = try runExecutableData([
            "--mmap",
            "-m1",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        #expect(String(decoding: explicitMmapBoundedMultiByteOutput, as: UTF8.self) == "bravo\n")

        try root.write("quiet\nlast delta", to: "unterminated-multi.txt")
        let boundedUnterminatedMultiByteOutput = try runExecutableData([
            "-m1",
            "bravo|delta",
            root.path("unterminated-multi.txt"),
        ], fixture: {})
        #expect(String(decoding: boundedUnterminatedMultiByteOutput, as: UTF8.self) == "last delta\n")

        let manyMultiLines = (1...20).map { index in
            "\(index.isMultiple(of: 2) ? "delta" : "bravo") \(index)"
        }.joined(separator: "\n") + "\n"
        try root.write(manyMultiLines, to: "many-multi.txt")
        let boundedFifteenMultiByteOutput = try runExecutableData([
            "-m15",
            "bravo|delta",
            root.path("many-multi.txt"),
        ], fixture: {})
        let expectedBoundedFifteenMultiLines = (1...15).map { index in
            "\(index.isMultiple(of: 2) ? "delta" : "bravo") \(index)"
        }.joined(separator: "\n") + "\n"
        #expect(String(decoding: boundedFifteenMultiByteOutput, as: UTF8.self) == expectedBoundedFifteenMultiLines)

        let boundedManyMultiByteOutput = try runExecutableData([
            "-m16",
            "bravo|delta",
            root.path("many-multi.txt"),
        ], fixture: {})
        let expectedBoundedManyMultiLines = (1...16).map { index in
            "\(index.isMultiple(of: 2) ? "delta" : "bravo") \(index)"
        }.joined(separator: "\n") + "\n"
        #expect(String(decoding: boundedManyMultiByteOutput, as: UTF8.self) == expectedBoundedManyMultiLines)

        let lineNumberedBoundedManyMultiByteOutput = try runExecutableData([
            "-n",
            "-m16",
            "bravo|delta",
            root.path("many-multi.txt"),
        ], fixture: {})
        let expectedLineNumberedBoundedManyMultiLines = (1...16).map { index in
            "\(index):\(index.isMultiple(of: 2) ? "delta" : "bravo") \(index)"
        }.joined(separator: "\n") + "\n"
        #expect(
            String(decoding: lineNumberedBoundedManyMultiByteOutput, as: UTF8.self)
                == expectedLineNumberedBoundedManyMultiLines
        )

        let duplicateFirstByteLines = (1...20).map { index in
            "\(index.isMultiple(of: 2) ? "Inspector" : "Irene") \(index)"
        }.joined(separator: "\n") + "\n"
        try root.write(duplicateFirstByteLines, to: "duplicate-first-byte-many-multi.txt")
        let duplicateFirstByteBoundedOutput = try runExecutableData([
            "-n",
            "-m16",
            "Irene|Inspector",
            root.path("duplicate-first-byte-many-multi.txt"),
        ], fixture: {})
        let expectedDuplicateFirstByteBoundedLines = (1...16).map { index in
            "\(index):\(index.isMultiple(of: 2) ? "Inspector" : "Irene") \(index)"
        }.joined(separator: "\n") + "\n"
        #expect(
            String(decoding: duplicateFirstByteBoundedOutput, as: UTF8.self)
                == expectedDuplicateFirstByteBoundedLines
        )

        try root.write("""
        quiet
        Sherlock Holmes
        Mycroft Holmes
        John Watson
        Irene Adler
        Inspector Lestrade
        Professor Moriarty
        """, to: "five-name-alternation.txt")
        let fiveNameLineNumberOutput = try runExecutableData([
            "-n",
            "Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor Moriarty",
            root.path("five-name-alternation.txt"),
        ], fixture: {})
        #expect(String(decoding: fiveNameLineNumberOutput, as: UTF8.self) == """
        2:Sherlock Holmes
        4:John Watson
        5:Irene Adler
        6:Inspector Lestrade
        7:Professor Moriarty

        """)

        let largeFillerLineCount = 600_000
        let largeFiller = String(
            repeating: "quiet filler line without names\n",
            count: largeFillerLineCount
        )
        try root.write(largeFiller + """
        Sherlock Holmes and John Watson
        quiet
        Professor Moriarty investigates
        Irene Adler replies
        Inspector Lestrade reports
        """, to: "large-five-name-alternation.txt")
        let fiveNamePattern = "Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade|Professor Moriarty"
        let largeFiveNameOutput = try runExecutableData([
            fiveNamePattern,
            root.path("large-five-name-alternation.txt"),
        ], fixture: {})
        #expect(String(decoding: largeFiveNameOutput, as: UTF8.self) == """
        Sherlock Holmes and John Watson
        Professor Moriarty investigates
        Irene Adler replies
        Inspector Lestrade reports

        """)

        let largeFiveNameLineNumberOutput = try runExecutableData([
            "-n",
            fiveNamePattern,
            root.path("large-five-name-alternation.txt"),
        ], fixture: {})
        #expect(String(decoding: largeFiveNameLineNumberOutput, as: UTF8.self) == """
        \(largeFillerLineCount + 1):Sherlock Holmes and John Watson
        \(largeFillerLineCount + 3):Professor Moriarty investigates
        \(largeFillerLineCount + 4):Irene Adler replies
        \(largeFillerLineCount + 5):Inspector Lestrade reports

        """)

        let lowercaseFiveNamePattern =
            "sherlock holmes|john watson|irene adler|inspector lestrade|professor moriarty"
        let largeFiveNameIgnoreCaseLineNumberOutput = try runExecutableData([
            "-n",
            "-i",
            lowercaseFiveNamePattern,
            root.path("large-five-name-alternation.txt"),
        ], fixture: {})
        #expect(String(decoding: largeFiveNameIgnoreCaseLineNumberOutput, as: UTF8.self) == """
        \(largeFillerLineCount + 1):Sherlock Holmes and John Watson
        \(largeFillerLineCount + 3):Professor Moriarty investigates
        \(largeFillerLineCount + 4):Irene Adler replies
        \(largeFillerLineCount + 5):Inspector Lestrade reports

        """)

        let largeTokenLineNumberOutput = try runExecutableData([
            "-n",
            "Sherlock|Watson|Moriarty",
            root.path("large-five-name-alternation.txt"),
        ], fixture: {})
        #expect(
            String(decoding: largeTokenLineNumberOutput, as: UTF8.self)
                == """
                \(largeFillerLineCount + 1):Sherlock Holmes and John Watson
                \(largeFillerLineCount + 3):Professor Moriarty investigates

                """
        )

        let tenLiteralNames = [
            "Ada", "Bert", "Cora", "Drew", "Eli",
            "Faye", "Gus", "Hale", "Iris", "Jules",
        ]
        let tenLiteralLines = (1...20).map { index in
            "\(tenLiteralNames[(index - 1) % tenLiteralNames.count]) \(index)"
        }.joined(separator: "\n") + "\n"
        try root.write(tenLiteralLines, to: "ten-literal-many-multi.txt")
        let tenLiteralBoundedOutput = try runExecutableData([
            "-n",
            "-m16",
            tenLiteralNames.joined(separator: "|"),
            root.path("ten-literal-many-multi.txt"),
        ], fixture: {})
        let expectedTenLiteralBoundedLines = (1...16).map { index in
            "\(index):\(tenLiteralNames[(index - 1) % tenLiteralNames.count]) \(index)"
        }.joined(separator: "\n") + "\n"
        #expect(
            String(decoding: tenLiteralBoundedOutput, as: UTF8.self)
                == expectedTenLiteralBoundedLines
        )

        let twentyLiteralNames = tenLiteralNames + [
            "Kara", "Liam", "Mina", "Nora", "Omar",
            "Pia", "Quin", "Rhea", "Seth", "Tess",
        ]
        let twentyLiteralLines = (1...40).map { index in
            "\(twentyLiteralNames[(index - 1) % twentyLiteralNames.count]) \(index)"
        }.joined(separator: "\n") + "\n"
        try root.write(twentyLiteralLines, to: "twenty-literal-many-multi.txt")
        let twentyLiteralBoundedOutput = try runExecutableData([
            "-n",
            "-m16",
            twentyLiteralNames.joined(separator: "|"),
            root.path("twenty-literal-many-multi.txt"),
        ], fixture: {})
        let expectedTwentyLiteralBoundedLines = (1...16).map { index in
            "\(index):\(twentyLiteralNames[(index - 1) % twentyLiteralNames.count]) \(index)"
        }.joined(separator: "\n") + "\n"
        #expect(
            String(decoding: twentyLiteralBoundedOutput, as: UTF8.self)
                == expectedTwentyLiteralBoundedLines
        )

        let fortyLiteralNames = twentyLiteralNames + [
            "Uma", "Vera", "Willa", "Xena", "Yara",
            "Zane", "Aria", "Bryn", "Cyra", "Dane",
            "Enid", "Finn", "Gail", "Hugh", "Ines",
            "Joss", "Kian", "Lena", "Milo", "Nell",
        ]
        let fortyLiteralLines = (1...80).map { index in
            "\(fortyLiteralNames[(index - 1) % fortyLiteralNames.count]) \(index)"
        }.joined(separator: "\n") + "\n"
        try root.write(fortyLiteralLines, to: "forty-literal-many-multi.txt")
        let fortyLiteralBoundedOutput = try runExecutableData([
            "-n",
            "-m16",
            fortyLiteralNames.joined(separator: "|"),
            root.path("forty-literal-many-multi.txt"),
        ], fixture: {})
        let expectedFortyLiteralBoundedLines = (1...16).map { index in
            "\(index):\(fortyLiteralNames[(index - 1) % fortyLiteralNames.count]) \(index)"
        }.joined(separator: "\n") + "\n"
        #expect(
            String(decoding: fortyLiteralBoundedOutput, as: UTF8.self)
                == expectedFortyLiteralBoundedLines
        )

        let commonPrefixNoMatchNames = (1...20).map { "PM_NOPE_\($0)" }
        let commonPrefixNoMatchOutput = try runExecutableData([
            "-m16",
            commonPrefixNoMatchNames.joined(separator: "|"),
            root.path("many-multi.txt"),
        ], fixture: {})
        #expect(commonPrefixNoMatchOutput.isEmpty)

        let onlyMatchingOutput = try runExecutableData([
            "-o",
            "b|d",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteOnlyMatchingOutput = try runExecutableData([
            "-o",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteLineNumberOnlyMatchingOutput = try runExecutableData([
            "-n",
            "-o",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteByteOffsetOnlyMatchingOutput = try runExecutableData([
            "-b",
            "-o",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteColumnOnlyMatchingOutput = try runExecutableData([
            "--column",
            "-o",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteLineColumnByteOnlyMatchingOutput = try runExecutableData([
            "-n",
            "--column",
            "-b",
            "-o",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        try root.write("delta bravo delta\nbravo\n", to: "interleaved.txt")
        let multiByteInterleavedOnlyMatchingOutput = try runExecutableData([
            "-n",
            "--column",
            "-o",
            "bravo|delta",
            root.path("interleaved.txt"),
        ], fixture: {})
        let multiByteVimgrepOutput = try runExecutableData([
            "--vimgrep",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteByteOffsetVimgrepOutput = try runExecutableData([
            "--vimgrep",
            "-b",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteNoFilenameVimgrepOutput = try runExecutableData([
            "--vimgrep",
            "--no-filename",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteNoFieldsVimgrepOutput = try runExecutableData([
            "--vimgrep",
            "-N",
            "--no-column",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteOnlyMatchingVimgrepOutput = try runExecutableData([
            "--vimgrep",
            "-o",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteInterleavedVimgrepOutput = try runExecutableData([
            "--vimgrep",
            "-o",
            "bravo|delta",
            root.path("interleaved.txt"),
        ], fixture: {})
        let multiByteByteOffsetOnlyMatchingVimgrepOutput = try runExecutableData([
            "--vimgrep",
            "-b",
            "-o",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteNoFilenameOnlyMatchingVimgrepOutput = try runExecutableData([
            "--vimgrep",
            "--no-filename",
            "-o",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        try root.write("aba\n", to: "repeat.txt")
        let singleByteRepeatedVimgrepOutput = try runExecutableData([
            "--vimgrep",
            "a",
            root.path("repeat.txt"),
        ], fixture: {})
        let singleByteRepeatedOnlyMatchingVimgrepOutput = try runExecutableData([
            "--vimgrep",
            "-o",
            "a",
            root.path("repeat.txt"),
        ], fixture: {})
        try root.write("bravo bravo\ncharlie\nbravo", to: "replace.txt")
        let literalReplacementOutput = try runExecutableData([
            "--replace",
            "delta",
            "bravo",
            root.path("replace.txt"),
        ], fixture: {})
        let emptyLiteralReplacementOutput = try runExecutableData([
            "--replace",
            "",
            "bravo",
            root.path("replace.txt"),
        ], fixture: {})
        let countMatchesOutput = try runExecutableData([
            "--count-matches",
            "b|d",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteSetCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "a|b|c|d|e",
            root.path("letters.txt"),
        ], fixture: {})
        let singleByteCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "a",
            root.path("letters.txt"),
        ], fixture: {})
        let singleByteIgnoreCaseCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-i",
            "A",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "bravo",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteAlternationCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "bravo|delta",
            root.path("letters.txt"),
        ], fixture: {})
        let multiByteIgnoreCaseCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-i",
            "BRAVO",
            root.path("letters.txt"),
        ], fixture: {})

        #expect(onlyMatchingOutput == Data("b\nd\n".utf8))
        #expect(multiByteOnlyMatchingOutput == Data("bravo\ndelta\n".utf8))
        #expect(multiByteLineNumberOnlyMatchingOutput == Data("2:bravo\n4:delta\n".utf8))
        #expect(multiByteByteOffsetOnlyMatchingOutput == Data("6:bravo\n20:delta\n".utf8))
        #expect(multiByteColumnOnlyMatchingOutput == Data("2:1:bravo\n4:1:delta\n".utf8))
        #expect(multiByteLineColumnByteOnlyMatchingOutput == Data("2:1:6:bravo\n4:1:20:delta\n".utf8))
        #expect(multiByteInterleavedOnlyMatchingOutput == Data(
            "1:1:delta\n1:7:bravo\n1:13:delta\n2:1:bravo\n".utf8
        ))
        #expect(multiByteVimgrepOutput == Data("\(root.path("letters.txt")):2:1:bravo\n\(root.path("letters.txt")):4:1:delta\n".utf8))
        #expect(multiByteByteOffsetVimgrepOutput == Data("\(root.path("letters.txt")):2:1:6:bravo\n\(root.path("letters.txt")):4:1:20:delta\n".utf8))
        #expect(multiByteNoFilenameVimgrepOutput == Data("2:1:bravo\n4:1:delta\n".utf8))
        #expect(multiByteNoFieldsVimgrepOutput == Data("\(root.path("letters.txt")):bravo\n\(root.path("letters.txt")):delta\n".utf8))
        #expect(multiByteOnlyMatchingVimgrepOutput == Data("\(root.path("letters.txt")):2:1:bravo\n\(root.path("letters.txt")):4:1:delta\n".utf8))
        #expect(multiByteInterleavedVimgrepOutput == Data(
            """
            \(root.path("interleaved.txt")):1:1:delta
            \(root.path("interleaved.txt")):1:7:bravo
            \(root.path("interleaved.txt")):1:13:delta
            \(root.path("interleaved.txt")):2:1:bravo

            """.utf8
        ))
        #expect(multiByteByteOffsetOnlyMatchingVimgrepOutput == Data("\(root.path("letters.txt")):2:1:6:bravo\n\(root.path("letters.txt")):4:1:20:delta\n".utf8))
        #expect(multiByteNoFilenameOnlyMatchingVimgrepOutput == Data("2:1:bravo\n4:1:delta\n".utf8))
        #expect(singleByteRepeatedVimgrepOutput == Data("\(root.path("repeat.txt")):1:1:aba\n\(root.path("repeat.txt")):1:3:aba\n".utf8))
        #expect(singleByteRepeatedOnlyMatchingVimgrepOutput == Data("\(root.path("repeat.txt")):1:1:a\n\(root.path("repeat.txt")):1:3:a\n".utf8))
        #expect(literalReplacementOutput == Data("delta delta\ndelta\n".utf8))
        #expect(emptyLiteralReplacementOutput == Data(" \n\n".utf8))
        #expect(countMatchesOutput == Data("2\n".utf8))
        #expect(multiByteSetCountMatchesOutput == Data("10\n".utf8))
        #expect(singleByteCountMatchesOutput == Data("5\n".utf8))
        #expect(singleByteIgnoreCaseCountMatchesOutput == Data("5\n".utf8))
        #expect(multiByteCountMatchesOutput == Data("1\n".utf8))
        #expect(multiByteAlternationCountMatchesOutput == Data("2\n".utf8))
        #expect(multiByteIgnoreCaseCountMatchesOutput == Data("1\n".utf8))
        #endif
    }

    @Test("Darwin executable literal preflight emits dense matching lines once")
    func darwinExecutableLiteralPreflightDenseLines() throws {
        #if canImport(Darwin)
        let root = try TemporaryDirectory()
        try root.write("""
        needle needle needle
        quiet line
        NEEDLE needle Needle
        tail needle
        """, to: "dense.txt")
        try FileManager.default.createSymbolicLink(
            atPath: root.path("dense-link.txt"),
            withDestinationPath: root.path("dense.txt")
        )
        try root.write("""
        a.b
        aXb
        Sherlock|Watson
        sherlock|watson
        """, to: "fixed.txt")
        try root.write("""
        -needle
        needle
        """, to: "dash-pattern.txt")
        try root.write("needle\npre needle\nneedle\nneedle tail\nlast", to: "exact.txt")
        try root.write(Data("needle\r\nquiet\r\n".utf8), to: "crlf.txt")
        try root.write("needle\nquiet\n", to: "patterns.txt")
        try root.write("--ignore-case\n--line-number\n", to: "ripgreprc")
        try root.write("needle\nlast\n", to: "exact-patterns.txt")
        try root.write("needle\n", to: "one-pattern.txt")
        try root.write("missing\nabsent\n", to: "missing-patterns.txt")
        try root.write("needle\nalpha\n", to: "passthru-patterns.txt")
        try root.write("needle needle\nquiet line\n", to: "fixed-patterns.txt")
        try root.write("needlex xneedle needle_ _needle needle\n", to: "word-count.txt")
        try root.write("éneedle\npre NEEDLE\nNEEDLE\n", to: "unicode-word-ci.txt")
        try root.write("needle needle\nNeedle quiet\n", to: "overlap.txt")
        try root.write("    needle padded\n\tneedle tabbed\nquiet\n    needle later\n", to: "trim.txt")
        try root.write("    Needle padded\n\tquiet\n  NEEDLE later\n", to: "trim-case.txt")
        try root.write("   \n  needle space\n", to: "trim-space.txt")
        try root.write("quiet one\nneedle skip\nquiet two\nneedle skip two\ntail quiet", to: "invert.txt")
        try root.write("quiet one\nNeedle skip\nafter one\nNEEDLE skip two\ntail quiet", to: "invert-case.txt")
        try root.write("needle\ntail\n", to: "invert-patterns.txt")
        try root.write("needle\nneedle two\n", to: "all-needle.txt")
        try root.write("alpha\nneedle one\nomega", to: "passthru.txt")
        try root.write("needle one\nafter one\nquiet\nquiet\nneedle two\nafter two\nquiet", to: "after-context.txt")
        try root.write("needle one\nneedle two\nafter\n", to: "after-max.txt")
        try root.write("quiet one\nneedle one\nquiet\nquiet\nbefore two\nneedle two\nquiet", to: "before-context.txt")
        try root.write("needle one\nneedle two\nafter\n", to: "before-max.txt")
        try root.write("quiet one\nNeedle one\nafter one\nquiet\nbefore two\nNEEDLE two\nafter two", to: "case-context.txt")
        try root.write("alpha\nneedle one\nbeta\nquiet\nzeta\nhay one\nomega", to: "multi-context.txt")
        try root.write("needle one\nhay two\nafter\n", to: "multi-context-max.txt")
        try root.write("alpha\nNeedle one\nbeta\nquiet\nzeta\nHAY one\nomega", to: "multi-case-context.txt")
        try root.write("needle\n", to: ".hidden.txt")
        try root.write("*.txt\n", to: ".ignore")
        try root.write("needle\n", to: "ignored.txt")
        try root.write(Data("pre\0needle\n".utf8), to: "binary-mode.dat")
        try root.write(Data("needle\0quiet\0needle\0".utf8), to: "nul-records.dat")
        try root.write(Data([0xFF]) + Data("needle raw\nquiet\n".utf8), to: "encoding-none-invalid.txt")
        try root.write(Data([0xEF, 0xBB, 0xBF]) + Data("needle\n".utf8), to: "encoding-none-bom.txt")
        try root.write(Data([0xE2, 0x84, 0xAA, 0x0A, 0x4B, 0x0A]), to: "utf8-casefold.txt")
        try root.write("quiet\n", to: "quiet-no-match.txt")
        try root.write("""
        hay
        needle one
        needle two
        needle three
        quiet
        needle four
        """, to: "stop-run.txt")

        func runExecutableResult(_ arguments: [String]) throws -> (stdout: Data, stderr: Data, status: Int32) {
            let executable = ripgrepPackageRootURL().appendingPathComponent(".build/debug/ripgrep")
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (data, errorData, process.terminationStatus)
        }

        let output = try runExecutableData([
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(output == Data("""
        needle needle needle
        NEEDLE needle Needle
        tail needle

        """.utf8))

        let lineBufferedOutput = try runExecutableData([
            "--line-buffered",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(lineBufferedOutput == output)

        let lineBufferedAlternationOutput = try runExecutableData([
            "--line-buffered",
            "needle|tail",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(lineBufferedAlternationOutput == output)

        let withFilenameOutput = try runExecutableData([
            "--with-filename",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(withFilenameOutput == Data("""
        \(root.path("dense.txt")):needle needle needle
        \(root.path("dense.txt")):NEEDLE needle Needle
        \(root.path("dense.txt")):tail needle

        """.utf8))

        let headingCountOutput = try runExecutableData([
            "--heading",
            "-H",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingCountOutput == Data("\(root.path("dense.txt")):3\n".utf8))

        let headingCountMatchesOutput = try runExecutableData([
            "--heading",
            "-H",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingCountMatchesOutput == Data("\(root.path("dense.txt")):5\n".utf8))

        let caseInsensitiveHeadingCountMatchesOutput = try runExecutableData([
            "--heading",
            "-H",
            "--count-matches",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveHeadingCountMatchesOutput == Data("\(root.path("dense.txt")):7\n".utf8))

        let caseInsensitiveCountOutput = try runExecutableData([
            "-c",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveCountOutput == Data("3\n".utf8))

        let clusteredCountThenPathOutput = try runExecutableData([
            "-cl",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredCountThenPathOutput == Data("\(root.path("dense.txt"))\n".utf8))

        let clusteredPathThenCountOutput = try runExecutableData([
            "-lc",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredPathThenCountOutput == Data("3\n".utf8))

        let clusteredPrefixedCountThenPathOutput = try runExecutableData([
            "-Hcl",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredPrefixedCountThenPathOutput == Data("\(root.path("dense.txt"))\n".utf8))

        let clusteredPrefixedPathThenCountOutput = try runExecutableData([
            "-Hlc",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredPrefixedPathThenCountOutput == Data("\(root.path("dense.txt")):3\n".utf8))

        let caseInsensitiveCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveCountMatchesOutput == Data("7\n".utf8))

        let unicodeCaseInsensitiveCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-i",
            "NEEDLE",
            root.path("unicode-word-ci.txt"),
        ], fixture: {})
        #expect(unicodeCaseInsensitiveCountMatchesOutput == Data("3\n".utf8))

        for nullDataResetArguments in [
            ["--null-data", "--crlf"],
            ["--null-data", "--crlf", "--no-crlf"],
        ] {
            let nullDataResetOutput = try runExecutableData(
                nullDataResetArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(nullDataResetOutput == output)
        }

        let ignoreCaseOutput = try runExecutableData([
            "-i",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(ignoreCaseOutput == Data("""
        needle needle needle
        NEEDLE needle Needle
        tail needle

        """.utf8))

        let caseInsensitiveWordOutput = try runExecutableData([
            "-w",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveWordOutput == output)

        let caseInsensitiveOnlyMatchingOutput = try runExecutableData([
            "-o",
            "-i",
            "NEEDLE",
            root.path("word-count.txt"),
        ], fixture: {})
        #expect(caseInsensitiveOnlyMatchingOutput == Data("""
        needle
        needle
        needle
        needle
        needle

        """.utf8))

        let plainOnlyMatchingOutput = try runExecutableData([
            "-o",
            "needle",
            root.path("word-count.txt"),
        ], fixture: {})
        #expect(plainOnlyMatchingOutput == caseInsensitiveOnlyMatchingOutput)

        let unicodeCaseInsensitiveOnlyMatchingOutput = try runExecutableData([
            "-o",
            "-i",
            "NEEDLE",
            root.path("unicode-word-ci.txt"),
        ], fixture: {})
        #expect(unicodeCaseInsensitiveOnlyMatchingOutput == Data("""
        needle
        NEEDLE
        NEEDLE

        """.utf8))

        let unicodeCaseInsensitiveWordOutput = try runExecutableData([
            "-w",
            "-i",
            "NEEDLE",
            root.path("unicode-word-ci.txt"),
        ], fixture: {})
        #expect(unicodeCaseInsensitiveWordOutput == Data("""
        pre NEEDLE
        NEEDLE

        """.utf8))

        let caseInsensitiveWordOnlyMatchingOutput = try runExecutableData([
            "-o",
            "-w",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveWordOnlyMatchingOutput == Data("""
        needle
        needle
        needle
        NEEDLE
        needle
        Needle
        needle

        """.utf8))

        let unicodeCaseInsensitiveWordOnlyMatchingOutput = try runExecutableData([
            "-o",
            "-w",
            "-i",
            "NEEDLE",
            root.path("unicode-word-ci.txt"),
        ], fixture: {})
        #expect(unicodeCaseInsensitiveWordOnlyMatchingOutput == Data("""
        NEEDLE
        NEEDLE

        """.utf8))

        let plainMultiLiteralOnlyMatchingOutput = try runExecutableData([
            "-o",
            "needle|quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(plainMultiLiteralOnlyMatchingOutput == Data("""
        needle
        needle
        needle
        quiet
        needle
        needle

        """.utf8))

        let headingOnlyMatchingOutput = try runExecutableData([
            "--heading",
            "-H",
            "-o",
            "needle|quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingOnlyMatchingOutput == Data("""
        \(root.path("dense.txt"))
        needle
        needle
        needle
        quiet
        needle
        needle

        """.utf8))

        let caseInsensitiveMultiLiteralOnlyMatchingOutput = try runExecutableData([
            "-o",
            "-i",
            "NEEDLE|QUIET",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveMultiLiteralOnlyMatchingOutput == Data("""
        needle
        needle
        needle
        quiet
        NEEDLE
        needle
        Needle
        needle

        """.utf8))

        let caseInsensitiveHeadingOnlyMatchingOutput = try runExecutableData([
            "--heading",
            "-H",
            "-o",
            "-i",
            "NEEDLE|QUIET",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveHeadingOnlyMatchingOutput == Data("""
        \(root.path("dense.txt"))
        needle
        needle
        needle
        quiet
        NEEDLE
        needle
        Needle
        needle

        """.utf8))

        let caseInsensitiveMultiLiteralPatternFileOnlyMatchingOutput = try runExecutableData([
            "-o",
            "-i",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveMultiLiteralPatternFileOnlyMatchingOutput == caseInsensitiveMultiLiteralOnlyMatchingOutput)

        let plainShortFirstOverlapOnlyMatchingOutput = try runExecutableData([
            "-o",
            "need|needle",
            root.path("overlap.txt"),
        ], fixture: {})
        #expect(plainShortFirstOverlapOnlyMatchingOutput == Data("""
        need
        need

        """.utf8))

        let plainLongFirstOverlapOnlyMatchingOutput = try runExecutableData([
            "-o",
            "needle|need",
            root.path("overlap.txt"),
        ], fixture: {})
        #expect(plainLongFirstOverlapOnlyMatchingOutput == Data("""
        needle
        needle

        """.utf8))

        let shortFirstOverlapOnlyMatchingOutput = try runExecutableData([
            "-o",
            "-i",
            "NEED|NEEDLE",
            root.path("overlap.txt"),
        ], fixture: {})
        #expect(shortFirstOverlapOnlyMatchingOutput == Data("""
        need
        need
        Need

        """.utf8))

        let longFirstOverlapOnlyMatchingOutput = try runExecutableData([
            "-o",
            "-i",
            "NEEDLE|NEED",
            root.path("overlap.txt"),
        ], fixture: {})
        #expect(longFirstOverlapOnlyMatchingOutput == Data("""
        needle
        needle
        Needle

        """.utf8))

        let unicodeCaseInsensitiveMultiLiteralOnlyMatchingOutput = try runExecutableData([
            "-o",
            "-i",
            "NEEDLE|QUIET",
            root.path("unicode-word-ci.txt"),
        ], fixture: {})
        #expect(unicodeCaseInsensitiveMultiLiteralOnlyMatchingOutput == Data("""
        needle
        NEEDLE
        NEEDLE

        """.utf8))

        let lineNumberOutput = try runExecutableData([
            "-n",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(lineNumberOutput == Data("""
        1:needle needle needle
        3:NEEDLE needle Needle
        4:tail needle

        """.utf8))

        let trimOutput = try runExecutableData([
            "--trim",
            "needle",
            root.path("trim.txt"),
        ], fixture: {})
        #expect(trimOutput == Data("""
        needle padded
        needle tabbed
        needle later

        """.utf8))

        let trimLineNumberOutput = try runExecutableData([
            "-n",
            "--trim",
            "needle",
            root.path("trim.txt"),
        ], fixture: {})
        #expect(trimLineNumberOutput == Data("""
        1:needle padded
        2:needle tabbed
        4:needle later

        """.utf8))

        let trimMaxCountOutput = try runExecutableData([
            "--trim",
            "-m2",
            "needle",
            root.path("trim.txt"),
        ], fixture: {})
        #expect(trimMaxCountOutput == Data("""
        needle padded
        needle tabbed

        """.utf8))

        let trimHeadingWithFilenameOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "--trim",
            "needle",
            root.path("trim.txt"),
        ], fixture: {})
        #expect(trimHeadingWithFilenameOutput == Data("""
        \(root.path("trim.txt"))
        needle padded
        needle tabbed
        needle later

        """.utf8))

        let trimDisabledOutput = try runExecutableData([
            "--trim",
            "--no-trim",
            "needle",
            root.path("trim.txt"),
        ], fixture: {})
        #expect(trimDisabledOutput == Data("    needle padded\n\tneedle tabbed\n    needle later\n".utf8))

        let trimWhitespaceOnlyOutput = try runExecutableData([
            "-F",
            "--trim",
            " ",
            root.path("trim-space.txt"),
        ], fixture: {})
        #expect(trimWhitespaceOnlyOutput == Data("\nneedle space\n".utf8))

        let trimMultiLiteralOutput = try runExecutableData([
            "-n",
            "--trim",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("trim.txt"),
        ], fixture: {})
        #expect(trimMultiLiteralOutput == Data("""
        1:needle padded
        2:needle tabbed
        3:quiet
        4:needle later

        """.utf8))

        let trimAlternationOutput = try runExecutableData([
            "-n",
            "--trim",
            "needle|quiet",
            root.path("trim.txt"),
        ], fixture: {})
        #expect(trimAlternationOutput == trimMultiLiteralOutput)

        let trimIgnoreCaseOutput = try runExecutableData([
            "-n",
            "--trim",
            "-i",
            "NEEDLE",
            root.path("trim-case.txt"),
        ], fixture: {})
        #expect(trimIgnoreCaseOutput == Data("""
        1:Needle padded
        3:NEEDLE later

        """.utf8))

        let trimMultiLiteralIgnoreCaseOutput = try runExecutableData([
            "-n",
            "--trim",
            "-i",
            "-e",
            "NEEDLE",
            "-e",
            "QUIET",
            root.path("trim-case.txt"),
        ], fixture: {})
        #expect(trimMultiLiteralIgnoreCaseOutput == Data("""
        1:Needle padded
        2:quiet
        3:NEEDLE later

        """.utf8))

        let trimAlternationIgnoreCaseOutput = try runExecutableData([
            "-n",
            "--trim",
            "-i",
            "NEEDLE|QUIET",
            root.path("trim-case.txt"),
        ], fixture: {})
        #expect(trimAlternationIgnoreCaseOutput == trimMultiLiteralIgnoreCaseOutput)

        let invertOutput = try runExecutableData([
            "-v",
            "needle",
            root.path("invert.txt"),
        ], fixture: {})
        #expect(invertOutput == Data("""
        quiet one
        quiet two
        tail quiet

        """.utf8))

        let invertLineNumberOutput = try runExecutableData([
            "-n",
            "-v",
            "needle",
            root.path("invert.txt"),
        ], fixture: {})
        #expect(invertLineNumberOutput == Data("""
        1:quiet one
        3:quiet two
        5:tail quiet

        """.utf8))

        let invertMaxCountOutput = try runExecutableData([
            "-v",
            "-m2",
            "needle",
            root.path("invert.txt"),
        ], fixture: {})
        #expect(invertMaxCountOutput == Data("""
        quiet one
        quiet two

        """.utf8))

        let invertHeadingWithFilenameOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "-v",
            "needle",
            root.path("invert.txt"),
        ], fixture: {})
        #expect(invertHeadingWithFilenameOutput == Data("""
        \(root.path("invert.txt"))
        quiet one
        quiet two
        tail quiet

        """.utf8))

        let invertIgnoreCaseOutput = try runExecutableData([
            "-n",
            "-v",
            "-i",
            "NEEDLE",
            root.path("invert-case.txt"),
        ], fixture: {})
        #expect(invertIgnoreCaseOutput == Data("""
        1:quiet one
        3:after one
        5:tail quiet

        """.utf8))

        let invertMultiLiteralOutput = try runExecutableData([
            "-n",
            "-v",
            "-e",
            "needle",
            "-e",
            "tail",
            root.path("invert.txt"),
        ], fixture: {})
        #expect(invertMultiLiteralOutput == Data("""
        1:quiet one
        3:quiet two

        """.utf8))

        let invertAlternationOutput = try runExecutableData([
            "-n",
            "-v",
            "needle|tail",
            root.path("invert.txt"),
        ], fixture: {})
        #expect(invertAlternationOutput == invertMultiLiteralOutput)

        let invertPatternFileOutput = try runExecutableData([
            "-n",
            "-v",
            "-f",
            root.path("invert-patterns.txt"),
            root.path("invert.txt"),
        ], fixture: {})
        #expect(invertPatternFileOutput == invertMultiLiteralOutput)

        let invertMultiLiteralMaxCountOutput = try runExecutableData([
            "-v",
            "-m1",
            "-e",
            "needle",
            "-e",
            "tail",
            root.path("invert.txt"),
        ], fixture: {})
        #expect(invertMultiLiteralMaxCountOutput == Data("quiet one\n".utf8))

        let invertMultiLiteralIgnoreCaseOutput = try runExecutableData([
            "-n",
            "-v",
            "-i",
            "-e",
            "NEEDLE",
            "-e",
            "TAIL",
            root.path("invert-case.txt"),
        ], fixture: {})
        #expect(invertMultiLiteralIgnoreCaseOutput == Data("""
        1:quiet one
        3:after one

        """.utf8))

        let invertAlternationIgnoreCaseOutput = try runExecutableData([
            "-n",
            "-v",
            "-i",
            "NEEDLE|TAIL",
            root.path("invert-case.txt"),
        ], fixture: {})
        #expect(invertAlternationIgnoreCaseOutput == invertMultiLiteralIgnoreCaseOutput)

        let invertAllFilteredResult = try runExecutableResult([
            "-v",
            "needle",
            root.path("all-needle.txt"),
        ])
        #expect(invertAllFilteredResult.stdout.isEmpty)
        #expect(invertAllFilteredResult.stderr.isEmpty)
        #expect(invertAllFilteredResult.status == 1)

        let passthruOutput = try runExecutableData([
            "--passthru",
            "needle",
            root.path("passthru.txt"),
        ], fixture: {})
        #expect(passthruOutput == Data("""
        alpha
        needle one
        omega

        """.utf8))

        let passthruLineNumberOutput = try runExecutableData([
            "-n",
            "--passthru",
            "needle",
            root.path("passthru.txt"),
        ], fixture: {})
        #expect(passthruLineNumberOutput == Data("""
        1-alpha
        2:needle one
        3-omega

        """.utf8))

        let passthruReplacementOutput = try runExecutableData([
            "-n",
            "--passthru",
            "--replace",
            "X",
            "needle",
            root.path("passthru.txt"),
        ], fixture: {})
        #expect(passthruReplacementOutput == Data("""
        1-alpha
        2:X one
        3-omega

        """.utf8))

        let passthruWithFilenameOutput = try runExecutableData([
            "--with-filename",
            "--passthru",
            "needle",
            root.path("passthru.txt"),
        ], fixture: {})
        #expect(passthruWithFilenameOutput == Data("""
        \(root.path("passthru.txt"))-alpha
        \(root.path("passthru.txt")):needle one
        \(root.path("passthru.txt"))-omega

        """.utf8))

        let passthruHeadingWithFilenameOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "--passthru",
            "needle",
            root.path("passthru.txt"),
        ], fixture: {})
        #expect(passthruHeadingWithFilenameOutput == Data("""
        \(root.path("passthru.txt"))
        alpha
        needle one
        omega

        """.utf8))

        let passthruCustomSeparatorOutput = try runExecutableData([
            "-n",
            "--field-match-separator=|",
            "--field-context-separator=_",
            "--passthru",
            "needle",
            root.path("passthru.txt"),
        ], fixture: {})
        #expect(passthruCustomSeparatorOutput == Data("""
        1_alpha
        2|needle one
        3_omega

        """.utf8))

        let passthruMissingResult = try runExecutableResult([
            "--passthru",
            "missing",
            root.path("passthru.txt"),
        ])
        #expect(passthruMissingResult.stdout == passthruOutput)
        #expect(passthruMissingResult.stderr.isEmpty)
        #expect(passthruMissingResult.status == 1)

        let passthruMaxCountZeroResult = try runExecutableResult([
            "--passthru",
            "-m0",
            "needle",
            root.path("passthru.txt"),
        ])
        #expect(passthruMaxCountZeroResult.stdout.isEmpty)
        #expect(passthruMaxCountZeroResult.stderr.isEmpty)
        #expect(passthruMaxCountZeroResult.status == 1)

        let passthruMaxCountZeroInvalidPatternResult = try runExecutableResult([
            "--passthru",
            "-m0",
            "[",
            root.path("passthru.txt"),
        ])
        #expect(passthruMaxCountZeroInvalidPatternResult.stdout.isEmpty)
        #expect(passthruMaxCountZeroInvalidPatternResult.stderr.isEmpty)
        #expect(passthruMaxCountZeroInvalidPatternResult.status == 1)

        let passthruMultiplePatternOutput = try runExecutableData([
            "-n",
            "--passthru",
            "-e",
            "needle",
            "-e",
            "alpha",
            root.path("passthru.txt"),
        ], fixture: {})
        #expect(passthruMultiplePatternOutput == Data("""
        1:alpha
        2:needle one
        3-omega

        """.utf8))

        let passthruAlternationOutput = try runExecutableData([
            "-n",
            "--passthru",
            "needle|alpha",
            root.path("passthru.txt"),
        ], fixture: {})
        #expect(passthruAlternationOutput == passthruMultiplePatternOutput)

        let passthruPatternFileOutput = try runExecutableData([
            "--with-filename",
            "-n",
            "--passthru",
            "-f",
            root.path("passthru-patterns.txt"),
            root.path("passthru.txt"),
        ], fixture: {})
        #expect(passthruPatternFileOutput == Data("""
        \(root.path("passthru.txt")):1:alpha
        \(root.path("passthru.txt")):2:needle one
        \(root.path("passthru.txt"))-3-omega

        """.utf8))

        let passthruIgnoreCaseOutput = try runExecutableData([
            "-n",
            "--passthru",
            "-i",
            "NEEDLE",
            root.path("case-context.txt"),
        ], fixture: {})
        #expect(passthruIgnoreCaseOutput == Data("""
        1-quiet one
        2:Needle one
        3-after one
        4-quiet
        5-before two
        6:NEEDLE two
        7-after two

        """.utf8))

        let passthruMultiIgnoreCaseOutput = try runExecutableData([
            "-n",
            "--passthru",
            "-i",
            "-e",
            "NEEDLE",
            "-e",
            "hay",
            root.path("multi-case-context.txt"),
        ], fixture: {})
        #expect(passthruMultiIgnoreCaseOutput == Data("""
        1-alpha
        2:Needle one
        3-beta
        4-quiet
        5-zeta
        6:HAY one
        7-omega

        """.utf8))

        let passthruAlternationIgnoreCaseOutput = try runExecutableData([
            "-n",
            "--passthru",
            "-i",
            "NEEDLE|hay",
            root.path("multi-case-context.txt"),
        ], fixture: {})
        #expect(passthruAlternationIgnoreCaseOutput == passthruMultiIgnoreCaseOutput)

        let afterContextOutput = try runExecutableData([
            "-A",
            "1",
            "needle",
            root.path("after-context.txt"),
        ], fixture: {})
        #expect(afterContextOutput == Data("""
        needle one
        after one
        --
        needle two
        after two

        """.utf8))

        let afterContextReplacementOutput = try runExecutableData([
            "--replace",
            "X",
            "-A",
            "1",
            "needle",
            root.path("after-context.txt"),
        ], fixture: {})
        #expect(afterContextReplacementOutput == Data("""
        X one
        after one
        --
        X two
        after two

        """.utf8))

        let afterContextLineNumberOutput = try runExecutableData([
            "-n",
            "-A",
            "1",
            "needle",
            root.path("after-context.txt"),
        ], fixture: {})
        #expect(afterContextLineNumberOutput == Data("""
        1:needle one
        2-after one
        --
        5:needle two
        6-after two

        """.utf8))

        let afterContextWithFilenameOutput = try runExecutableData([
            "--with-filename",
            "-A",
            "1",
            "needle",
            root.path("after-context.txt"),
        ], fixture: {})
        #expect(afterContextWithFilenameOutput == Data("""
        \(root.path("after-context.txt")):needle one
        \(root.path("after-context.txt"))-after one
        --
        \(root.path("after-context.txt")):needle two
        \(root.path("after-context.txt"))-after two

        """.utf8))

        let afterContextHeadingWithFilenameOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "-A",
            "1",
            "needle",
            root.path("after-context.txt"),
        ], fixture: {})
        #expect(afterContextHeadingWithFilenameOutput == Data("""
        \(root.path("after-context.txt"))
        needle one
        after one
        --
        needle two
        after two

        """.utf8))

        let afterContextCustomSeparatorOutput = try runExecutableData([
            "-n",
            "--field-match-separator=|",
            "--field-context-separator=_",
            "--context-separator=ZZ",
            "-A",
            "1",
            "needle",
            root.path("after-context.txt"),
        ], fixture: {})
        #expect(afterContextCustomSeparatorOutput == Data("""
        1|needle one
        2_after one
        ZZ
        5|needle two
        6_after two

        """.utf8))

        let afterContextNoSeparatorOutput = try runExecutableData([
            "--no-context-separator",
            "-A",
            "1",
            "needle",
            root.path("after-context.txt"),
        ], fixture: {})
        #expect(afterContextNoSeparatorOutput == Data("""
        needle one
        after one
        needle two
        after two

        """.utf8))

        let afterContextMaxCountOutput = try runExecutableData([
            "-n",
            "-A",
            "1",
            "-m",
            "1",
            "needle",
            root.path("after-max.txt"),
        ], fixture: {})
        #expect(afterContextMaxCountOutput == Data("""
        1:needle one
        2:needle two

        """.utf8))

        let afterContextMissingResult = try runExecutableResult([
            "-A",
            "1",
            "missing",
            root.path("after-context.txt"),
        ])
        #expect(afterContextMissingResult.stdout.isEmpty)
        #expect(afterContextMissingResult.stderr.isEmpty)
        #expect(afterContextMissingResult.status == 1)

        let afterContextMaxCountZeroResult = try runExecutableResult([
            "-A",
            "1",
            "-m0",
            "[",
            root.path("after-context.txt"),
        ])
        #expect(afterContextMaxCountZeroResult.stdout.isEmpty)
        #expect(afterContextMaxCountZeroResult.stderr.isEmpty)
        #expect(afterContextMaxCountZeroResult.status == 1)

        let afterContextIgnoreCaseOutput = try runExecutableData([
            "-i",
            "-A",
            "1",
            "NEEDLE",
            root.path("case-context.txt"),
        ], fixture: {})
        #expect(afterContextIgnoreCaseOutput == Data("""
        Needle one
        after one
        --
        NEEDLE two
        after two

        """.utf8))

        let beforeContextOutput = try runExecutableData([
            "-B",
            "1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(beforeContextOutput == Data("""
        quiet one
        needle one
        --
        before two
        needle two

        """.utf8))

        let beforeContextLineNumberOutput = try runExecutableData([
            "-n",
            "-B",
            "1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(beforeContextLineNumberOutput == Data("""
        1-quiet one
        2:needle one
        --
        5-before two
        6:needle two

        """.utf8))

        let beforeContextWithFilenameOutput = try runExecutableData([
            "--with-filename",
            "-B",
            "1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(beforeContextWithFilenameOutput == Data("""
        \(root.path("before-context.txt"))-quiet one
        \(root.path("before-context.txt")):needle one
        --
        \(root.path("before-context.txt"))-before two
        \(root.path("before-context.txt")):needle two

        """.utf8))

        let beforeContextHeadingWithFilenameOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "-B",
            "1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(beforeContextHeadingWithFilenameOutput == Data("""
        \(root.path("before-context.txt"))
        quiet one
        needle one
        --
        before two
        needle two

        """.utf8))

        let beforeContextCustomSeparatorOutput = try runExecutableData([
            "-n",
            "--field-match-separator=|",
            "--field-context-separator=_",
            "--context-separator=ZZ",
            "-B",
            "1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(beforeContextCustomSeparatorOutput == Data("""
        1_quiet one
        2|needle one
        ZZ
        5_before two
        6|needle two

        """.utf8))

        let beforeContextNoSeparatorOutput = try runExecutableData([
            "--no-context-separator",
            "-B",
            "1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(beforeContextNoSeparatorOutput == Data("""
        quiet one
        needle one
        before two
        needle two

        """.utf8))

        let beforeContextMaxCountOutput = try runExecutableData([
            "-n",
            "-B",
            "1",
            "-m",
            "1",
            "needle",
            root.path("before-max.txt"),
        ], fixture: {})
        #expect(beforeContextMaxCountOutput == Data("""
        1:needle one

        """.utf8))

        let beforeContextMissingResult = try runExecutableResult([
            "-B",
            "1",
            "missing",
            root.path("before-context.txt"),
        ])
        #expect(beforeContextMissingResult.stdout.isEmpty)
        #expect(beforeContextMissingResult.stderr.isEmpty)
        #expect(beforeContextMissingResult.status == 1)

        let beforeContextMaxCountZeroResult = try runExecutableResult([
            "-B",
            "1",
            "-m0",
            "[",
            root.path("before-context.txt"),
        ])
        #expect(beforeContextMaxCountZeroResult.stdout.isEmpty)
        #expect(beforeContextMaxCountZeroResult.stderr.isEmpty)
        #expect(beforeContextMaxCountZeroResult.status == 1)

        let beforeContextIgnoreCaseOutput = try runExecutableData([
            "-i",
            "-B",
            "1",
            "NEEDLE",
            root.path("case-context.txt"),
        ], fixture: {})
        #expect(beforeContextIgnoreCaseOutput == Data("""
        quiet one
        Needle one
        --
        before two
        NEEDLE two

        """.utf8))

        let contextOutput = try runExecutableData([
            "-C",
            "1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(contextOutput == Data("""
        quiet one
        needle one
        quiet
        --
        before two
        needle two
        quiet

        """.utf8))

        let contextLineNumberOutput = try runExecutableData([
            "-n",
            "--context=1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(contextLineNumberOutput == Data("""
        1-quiet one
        2:needle one
        3-quiet
        --
        5-before two
        6:needle two
        7-quiet

        """.utf8))

        let contextWithFilenameOutput = try runExecutableData([
            "--with-filename",
            "-C",
            "1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(contextWithFilenameOutput == Data("""
        \(root.path("before-context.txt"))-quiet one
        \(root.path("before-context.txt")):needle one
        \(root.path("before-context.txt"))-quiet
        --
        \(root.path("before-context.txt"))-before two
        \(root.path("before-context.txt")):needle two
        \(root.path("before-context.txt"))-quiet

        """.utf8))

        let contextHeadingWithFilenameOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "-C",
            "1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(contextHeadingWithFilenameOutput == Data("""
        \(root.path("before-context.txt"))
        quiet one
        needle one
        quiet
        --
        before two
        needle two
        quiet

        """.utf8))

        let contextCustomSeparatorOutput = try runExecutableData([
            "-n",
            "--field-match-separator=|",
            "--field-context-separator=_",
            "--context-separator=ZZ",
            "-C",
            "1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(contextCustomSeparatorOutput == Data("""
        1_quiet one
        2|needle one
        3_quiet
        ZZ
        5_before two
        6|needle two
        7_quiet

        """.utf8))

        let contextNoSeparatorOutput = try runExecutableData([
            "--no-context-separator",
            "-C",
            "1",
            "needle",
            root.path("before-context.txt"),
        ], fixture: {})
        #expect(contextNoSeparatorOutput == Data("""
        quiet one
        needle one
        quiet
        before two
        needle two
        quiet

        """.utf8))

        let contextMaxCountOutput = try runExecutableData([
            "-n",
            "-C",
            "1",
            "-m",
            "1",
            "needle",
            root.path("before-max.txt"),
        ], fixture: {})
        #expect(contextMaxCountOutput == Data("""
        1:needle one
        2:needle two

        """.utf8))

        let contextMissingResult = try runExecutableResult([
            "-C",
            "1",
            "missing",
            root.path("before-context.txt"),
        ])
        #expect(contextMissingResult.stdout.isEmpty)
        #expect(contextMissingResult.stderr.isEmpty)
        #expect(contextMissingResult.status == 1)

        let contextMaxCountZeroResult = try runExecutableResult([
            "-C",
            "1",
            "-m0",
            "[",
            root.path("before-context.txt"),
        ])
        #expect(contextMaxCountZeroResult.stdout.isEmpty)
        #expect(contextMaxCountZeroResult.stderr.isEmpty)
        #expect(contextMaxCountZeroResult.status == 1)

        let contextIgnoreCaseOutput = try runExecutableData([
            "-n",
            "-i",
            "-C",
            "1",
            "NEEDLE",
            root.path("case-context.txt"),
        ], fixture: {})
        #expect(contextIgnoreCaseOutput == Data("""
        1-quiet one
        2:Needle one
        3-after one
        --
        5-before two
        6:NEEDLE two
        7-after two

        """.utf8))

        let multiAfterContextOutput = try runExecutableData([
            "-A",
            "1",
            "-e",
            "needle",
            "-e",
            "hay",
            root.path("multi-context.txt"),
        ], fixture: {})
        #expect(multiAfterContextOutput == Data("""
        needle one
        beta
        --
        hay one
        omega

        """.utf8))

        let multiBeforeContextOutput = try runExecutableData([
            "-B",
            "1",
            "-e",
            "needle",
            "-e",
            "hay",
            root.path("multi-context.txt"),
        ], fixture: {})
        #expect(multiBeforeContextOutput == Data("""
        alpha
        needle one
        --
        zeta
        hay one

        """.utf8))

        let multiContextOutput = try runExecutableData([
            "-n",
            "--context=1",
            "--field-match-separator=|",
            "--field-context-separator=_",
            "--context-separator=ZZ",
            "-e",
            "needle",
            "-e",
            "hay",
            root.path("multi-context.txt"),
        ], fixture: {})
        #expect(multiContextOutput == Data("""
        1_alpha
        2|needle one
        3_beta
        ZZ
        5_zeta
        6|hay one
        7_omega

        """.utf8))

        let multiAlternationContextOutput = try runExecutableData([
            "-C",
            "1",
            "needle|hay",
            root.path("multi-context.txt"),
        ], fixture: {})
        #expect(multiAlternationContextOutput == Data("""
        alpha
        needle one
        beta
        --
        zeta
        hay one
        omega

        """.utf8))

        let multiContextMaxCountOutput = try runExecutableData([
            "-n",
            "-C",
            "1",
            "-m",
            "1",
            "-e",
            "needle",
            "-e",
            "hay",
            root.path("multi-context-max.txt"),
        ], fixture: {})
        #expect(multiContextMaxCountOutput == Data("""
        1:needle one
        2:hay two

        """.utf8))

        let multiContextMissingResult = try runExecutableResult([
            "-C",
            "1",
            "-e",
            "absent",
            "-e",
            "missing",
            root.path("multi-context.txt"),
        ])
        #expect(multiContextMissingResult.stdout.isEmpty)
        #expect(multiContextMissingResult.stderr.isEmpty)
        #expect(multiContextMissingResult.status == 1)

        let multiContextMaxCountZeroResult = try runExecutableResult([
            "-C",
            "1",
            "-m0",
            "-e",
            "[",
            "-e",
            "needle",
            root.path("multi-context.txt"),
        ])
        #expect(multiContextMaxCountZeroResult.stdout.isEmpty)
        #expect(multiContextMaxCountZeroResult.stderr.isEmpty)
        #expect(multiContextMaxCountZeroResult.status == 1)

        let multiIgnoreCaseContextOutput = try runExecutableData([
            "-n",
            "-i",
            "-C",
            "1",
            "-e",
            "NEEDLE",
            "-e",
            "hay",
            root.path("multi-case-context.txt"),
        ], fixture: {})
        #expect(multiIgnoreCaseContextOutput == Data("""
        1-alpha
        2:Needle one
        3-beta
        --
        5-zeta
        6:HAY one
        7-omega

        """.utf8))

        let multiIgnoreCaseAlternationOutput = try runExecutableData([
            "-i",
            "-C",
            "1",
            "NEEDLE|hay",
            root.path("multi-case-context.txt"),
        ], fixture: {})
        #expect(multiIgnoreCaseAlternationOutput == Data("""
        alpha
        Needle one
        beta
        --
        zeta
        HAY one
        omega

        """.utf8))

        let plainOnlyMatchingLineNumberOutput = try runExecutableData([
            "-n",
            "-o",
            "needle",
            root.path("word-count.txt"),
        ], fixture: {})
        #expect(plainOnlyMatchingLineNumberOutput == Data("""
        1:needle
        1:needle
        1:needle
        1:needle
        1:needle

        """.utf8))

        let headingOnlyMatchingLineNumberOutput = try runExecutableData([
            "--heading",
            "-H",
            "-n",
            "-o",
            "needle|quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingOnlyMatchingLineNumberOutput == Data("""
        \(root.path("dense.txt"))
        1:needle
        1:needle
        1:needle
        2:quiet
        3:needle
        4:needle

        """.utf8))

        let caseInsensitiveOnlyMatchingLineNumberOutput = try runExecutableData([
            "-n",
            "-o",
            "-i",
            "NEEDLE",
            root.path("word-count.txt"),
        ], fixture: {})
        #expect(caseInsensitiveOnlyMatchingLineNumberOutput == Data("""
        1:needle
        1:needle
        1:needle
        1:needle
        1:needle

        """.utf8))

        let caseInsensitiveMultiLiteralOnlyMatchingLineNumberOutput = try runExecutableData([
            "-n",
            "-o",
            "-i",
            "NEEDLE|QUIET",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveMultiLiteralOnlyMatchingLineNumberOutput == Data("""
        1:needle
        1:needle
        1:needle
        2:quiet
        3:NEEDLE
        3:needle
        3:Needle
        4:needle

        """.utf8))

        let caseInsensitiveWordLineNumberOutput = try runExecutableData([
            "-n",
            "-w",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveWordLineNumberOutput == lineNumberOutput)

        let caseInsensitiveWordOnlyMatchingLineNumberOutput = try runExecutableData([
            "-n",
            "-o",
            "-w",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveWordOnlyMatchingLineNumberOutput == Data("""
        1:needle
        1:needle
        1:needle
        3:NEEDLE
        3:needle
        3:Needle
        4:needle

        """.utf8))

        let lineBufferedLineNumberOutput = try runExecutableData([
            "--line-buffered",
            "-n",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(lineBufferedLineNumberOutput == lineNumberOutput)

        let withFilenameLineNumberOutput = try runExecutableData([
            "--with-filename",
            "-n",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(withFilenameLineNumberOutput == Data("""
        \(root.path("dense.txt")):1:needle needle needle
        \(root.path("dense.txt")):3:NEEDLE needle Needle
        \(root.path("dense.txt")):4:tail needle

        """.utf8))

        let clusteredWithFilenameLineNumberOutput = try runExecutableData([
            "-Hn",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredWithFilenameLineNumberOutput == withFilenameLineNumberOutput)

        let clusteredLineNumberWithFilenameOutput = try runExecutableData([
            "-nH",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredLineNumberWithFilenameOutput == withFilenameLineNumberOutput)

        let clusteredNoFilenameOutput = try runExecutableData([
            "-HI",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredNoFilenameOutput == output)

        let clusteredWithFilenameOutput = try runExecutableData([
            "-IH",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredWithFilenameOutput == withFilenameOutput)

        let clusteredSearchZipLineNumberOutput = try runExecutableData([
            "-zn",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredSearchZipLineNumberOutput == lineNumberOutput)

        let clusteredByteOffsetQuietResult = try runExecutableResult([
            "-bq",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(clusteredByteOffsetQuietResult.status == 0)
        #expect(clusteredByteOffsetQuietResult.stdout.isEmpty)
        #expect(clusteredByteOffsetQuietResult.stderr.isEmpty)

        let clusteredByteOffsetCountOutput = try runExecutableData([
            "-bc",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredByteOffsetCountOutput == Data("3\n".utf8))

        let clusteredPrettyQuietResult = try runExecutableResult([
            "-pq",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(clusteredPrettyQuietResult.status == 0)
        #expect(clusteredPrettyQuietResult.stdout.isEmpty)
        #expect(clusteredPrettyQuietResult.stderr.isEmpty)

        let clusteredPrettyCountOutput = try runExecutableData([
            "-pc",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredPrettyCountOutput == Data("3\n".utf8))

        let clusteredPrettyPrefixedCountOutput = try runExecutableData([
            "-pHc",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredPrettyPrefixedCountOutput == Data(
            "\u{1B}[0m\u{1B}[35m\(root.path("dense.txt"))\u{1B}[0m:3\n".utf8
        ))

        let ansiPrefixedCountOutput = try runExecutableData([
            "--color=ansi",
            "-H",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(ansiPrefixedCountOutput == clusteredPrettyPrefixedCountOutput)

        let coloredNullPrefixedCountOutput = try runExecutableData([
            "--color=always",
            "--null",
            "-H",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(coloredNullPrefixedCountOutput == Data(
            ("\u{1B}[0m\u{1B}[35m\(root.path("dense.txt"))\u{1B}[0m\0" + "3\n").utf8
        ))

        let coloredPrefixedCountMatchesOutput = try runExecutableData([
            "--color=always",
            "--count-matches",
            "-H",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(coloredPrefixedCountMatchesOutput == Data(
            "\u{1B}[0m\u{1B}[35m\(root.path("dense.txt"))\u{1B}[0m:5\n".utf8
        ))

        let customMatchColorPrefixedCountOutput = try runExecutableData([
            "--colors",
            "match:fg:red",
            "--color=always",
            "-H",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(customMatchColorPrefixedCountOutput == clusteredPrettyPrefixedCountOutput)

        let withFilenameNullOutput = try runExecutableData([
            "--with-filename",
            "--null",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(withFilenameNullOutput == Data((
            "\(root.path("dense.txt"))\0needle needle needle\n" +
            "\(root.path("dense.txt"))\0NEEDLE needle Needle\n" +
            "\(root.path("dense.txt"))\0tail needle\n"
        ).utf8))

        let pathSeparatedName = root.path("dense.txt").replacingOccurrences(of: "/", with: "Z")
        let withFilenamePathSeparatorOutput = try runExecutableData([
            "--with-filename",
            "--path-separator",
            "Z",
            "-n",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(withFilenamePathSeparatorOutput == Data("""
        \(pathSeparatedName):1:needle needle needle
        \(pathSeparatedName):3:NEEDLE needle Needle
        \(pathSeparatedName):4:tail needle

        """.utf8))

        let withFilenameEscapedPathSeparatorOutput = try runExecutableData([
            "--with-filename",
            #"--path-separator=\x5A"#,
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(withFilenameEscapedPathSeparatorOutput == Data("""
        \(pathSeparatedName):needle needle needle
        \(pathSeparatedName):NEEDLE needle Needle
        \(pathSeparatedName):tail needle

        """.utf8))

        let withFilenameAutomaticPathSeparatorOutput = try runExecutableData([
            "--with-filename",
            "--path-separator=Z",
            "--path-separator=",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(withFilenameAutomaticPathSeparatorOutput == withFilenameOutput)

        let explicitNoLineNumberOutput = try runExecutableData([
            "-N",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(explicitNoLineNumberOutput == output)

        let longNoLineNumberOutput = try runExecutableData([
            "--no-line-number",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(longNoLineNumberOutput == output)

        let noHeadingOutput = try runExecutableData([
            "--no-heading",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noHeadingOutput == output)

        let headingOutput = try runExecutableData([
            "--heading",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingOutput == output)

        let headingLineNumberOutput = try runExecutableData([
            "--heading",
            "-n",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingLineNumberOutput == lineNumberOutput)

        let headingPathSeparatorOutput = try runExecutableData([
            "--heading",
            "--path-separator=Z",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingPathSeparatorOutput == output)

        let headingWithFilenameOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingWithFilenameOutput == Data("""
        \(root.path("dense.txt"))
        needle needle needle
        NEEDLE needle Needle
        tail needle

        """.utf8))

        let headingWithFilenameLineNumberOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "-n",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingWithFilenameLineNumberOutput == Data("""
        \(root.path("dense.txt"))
        1:needle needle needle
        3:NEEDLE needle Needle
        4:tail needle

        """.utf8))

        let headingWithFilenameNullOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "--null",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingWithFilenameNullOutput == Data((
            "\(root.path("dense.txt"))\0" +
            "needle needle needle\n" +
            "NEEDLE needle Needle\n" +
            "tail needle\n"
        ).utf8))

        let headingWithFilenamePathSeparatorOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "--path-separator=Z",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingWithFilenamePathSeparatorOutput == Data("""
        \(pathSeparatedName)
        needle needle needle
        NEEDLE needle Needle
        tail needle

        """.utf8))

        let headingWithFilenameCrlfOutput = try runExecutableData([
            "--crlf",
            "--heading",
            "--with-filename",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingWithFilenameCrlfOutput == Data((
            "\(root.path("dense.txt"))\r\n" +
            "needle needle needle\n" +
            "NEEDLE needle Needle\n" +
            "tail needle\n"
        ).utf8))

        let headingWithFilenameNoMatch = try runExecutableResult([
            "--heading",
            "--with-filename",
            "missing",
            root.path("dense.txt"),
        ])
        #expect(headingWithFilenameNoMatch.stdout.isEmpty)
        #expect(headingWithFilenameNoMatch.stderr.isEmpty)
        #expect(headingWithFilenameNoMatch.status == 1)

        let noFilenameOutput = try runExecutableData([
            "--no-filename",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noFilenameOutput == output)

        let noMessagesOutput = try runExecutableData([
            "--no-messages",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noMessagesOutput == output)

        let replacementMatchingOutput = try runExecutableData([
            "--replace",
            "X",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(replacementMatchingOutput == Data("""
        X X X
        NEEDLE X Needle
        tail X

        """.utf8))

        for (quietArguments, expectedStatus) in [
            (["-q", "needle", root.path("dense.txt")], Int32(0)),
            (["--line-buffered", "-q", "needle", root.path("dense.txt")], Int32(0)),
            (["--quiet", "missing", root.path("quiet-no-match.txt")], Int32(1)),
            (["--replace", "X", "-q", "needle", root.path("dense.txt")], Int32(0)),
            (["--passthru", "-q", "needle", root.path("dense.txt")], Int32(0)),
            (["-qn", "needle", root.path("dense.txt")], Int32(0)),
            (["-qi", "needle", root.path("dense.txt")], Int32(0)),
            (["-qi", "NEEDLE", root.path("dense.txt")], Int32(0)),
            (["-qi", "absentliteral", root.path("dense.txt")], Int32(1)),
            (["-qi", "12345", root.path("dense.txt")], Int32(1)),
            (["--trim", "-q", "needle", root.path("trim.txt")], Int32(0)),
            (["--trim", "-q", "missing", root.path("trim.txt")], Int32(1)),
            (["--null-data", "-q", "needle", root.path("dense.txt")], Int32(0)),
            (["--null-data", "-q", "-x", "quiet", root.path("nul-records.dat")], Int32(0)),
            (["-M1", "-q", "needle", root.path("dense.txt")], Int32(0)),
            (["-q", "-w", "needle", root.path("dense.txt")], Int32(0)),
            (["-qw", "needle", root.path("dense.txt")], Int32(0)),
            (["-q", "-w", "eed", root.path("dense.txt")], Int32(1)),
            (["-q", "-w", "-i", "NEEDLE", root.path("dense.txt")], Int32(0)),
            (["-qwi", "NEEDLE", root.path("dense.txt")], Int32(0)),
            (["-q", "-w", "-i", "EED", root.path("dense.txt")], Int32(1)),
            (["--stop-on-nonmatch", "-q", "needle", root.path("dense.txt")], Int32(0)),
            (["--stop-on-nonmatch", "-q", "missing", root.path("dense.txt")], Int32(1)),
            (["-q", "needle|tail", root.path("dense.txt")], Int32(0)),
            (["-qi", "NEEDLE|TAIL", root.path("dense.txt")], Int32(0)),
            (["-qi", "123|456", root.path("dense.txt")], Int32(1)),
            (["-q", "missing|absent", root.path("dense.txt")], Int32(1)),
            (["-q", "-x", "needle", root.path("exact.txt")], Int32(0)),
            (["-q", "-i", "-x", "NEEDLE", root.path("exact.txt")], Int32(0)),
            (["-q", "-x", "missing", root.path("exact.txt")], Int32(1)),
            (["-q", "-i", "-x", "missing", root.path("exact.txt")], Int32(1)),
            (["-q", "-i", "-x", "12345", root.path("exact.txt")], Int32(1)),
            (["-q", "-x", "needle|last", root.path("exact.txt")], Int32(0)),
            (["-q", "-i", "-x", "NEEDLE|LAST", root.path("exact.txt")], Int32(0)),
            (["-q", "-x", "-e", "needle", "-e", "last", root.path("exact.txt")], Int32(0)),
            (["-q", "-i", "-x", "-e", "NEEDLE", "-e", "LAST", root.path("exact.txt")], Int32(0)),
            (["-q", "-x", "-f", root.path("exact-patterns.txt"), root.path("exact.txt")], Int32(0)),
            (["-q", "-i", "-x", "-f", root.path("exact-patterns.txt"), root.path("exact.txt")], Int32(0)),
            (["-q", "-x", "missing|absent", root.path("exact.txt")], Int32(1)),
            (["-q", "-i", "-x", "MISSING|ABSENT", root.path("exact.txt")], Int32(1)),
            (["--crlf", "-q", "-x", "needle", root.path("crlf.txt")], Int32(0)),
            (["--crlf", "-q", "-i", "-x", "NEEDLE|QUIET", root.path("crlf.txt")], Int32(0)),
            (["-q", "-w", "-i", "NEEDLE", root.path("unicode-word-ci.txt")], Int32(0)),
            (["-q", "needle", root.path("binary-mode.dat")], Int32(0)),
        ] {
            let quietResult = try runExecutableResult(quietArguments)
            #expect(quietResult.stdout.isEmpty)
            #expect(quietResult.stderr.isEmpty)
            #expect(quietResult.status == expectedStatus)
        }

        for (pathOnlyArguments, expectedOutput, expectedStatus) in [
            (["-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--line-buffered", "-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--crlf", "-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\r\n".utf8), Int32(0)),
            (["--crlf", "--null", "-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\0".utf8), Int32(0)),
            (["--null-data", "--crlf", "-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\r\n".utf8), Int32(0)),
            (["--files-with-matches", "--null", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\0".utf8), Int32(0)),
            (["--heading", "--with-filename", "-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--heading", "--with-filename", "--files-with-matches", "--null", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\0".utf8), Int32(0)),
            (["-l", "--path-separator", "Z", "needle", root.path("dense.txt")], Data("\(pathSeparatedName)\n".utf8), Int32(0)),
            (["--files-with-matches", "--path-separator=Z", "--null", "needle", root.path("dense.txt")], Data("\(pathSeparatedName)\0".utf8), Int32(0)),
            (["--heading", "--with-filename", "--path-separator=Z", "-l", "needle", root.path("dense.txt")], Data("\(pathSeparatedName)\n".utf8), Int32(0)),
            (["-l", "missing", root.path("dense.txt")], Data(), Int32(1)),
            (["--files-without-match", "missing", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--heading", "--with-filename", "--files-without-match", "missing", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "--path-separator=Z", "missing", root.path("dense.txt")], Data("\(pathSeparatedName)\n".utf8), Int32(0)),
            (["--crlf", "--files-without-match", "missing", root.path("dense.txt")], Data("\(root.path("dense.txt"))\r\n".utf8), Int32(0)),
            (["--trim", "-l", "needle", root.path("trim.txt")], Data("\(root.path("trim.txt"))\n".utf8), Int32(0)),
            (["--trim", "--files-without-match", "missing", root.path("trim.txt")], Data("\(root.path("trim.txt"))\n".utf8), Int32(0)),
            (["--null-data", "-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["-M1", "-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--replace=X", "-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--passthru", "-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "needle", root.path("dense.txt")], Data(), Int32(1)),
            (["--heading", "--with-filename", "--files-without-match", "needle", root.path("dense.txt")], Data(), Int32(1)),
            (["-li", "NEEDLE", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["-li", "--path-separator=Z", "NEEDLE", root.path("dense.txt")], Data("\(pathSeparatedName)\n".utf8), Int32(0)),
            (["--files-without-match", "-i", "NEEDLE", root.path("dense.txt")], Data(), Int32(1)),
            (["-li", "12345", root.path("dense.txt")], Data(), Int32(1)),
            (["--files-without-match", "-i", "12345", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["-q", "-l", "needle", root.path("dense.txt")], Data(), Int32(0)),
            (["-l", "-w", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["-l", "-w", "eed", root.path("dense.txt")], Data(), Int32(1)),
            (["--files-with-matches", "--null", "-w", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\0".utf8), Int32(0)),
            (["--files-without-match", "-w", "eed", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "-w", "needle", root.path("dense.txt")], Data(), Int32(1)),
            (["-l", "-w", "-i", "NEEDLE", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--files-with-matches", "--null", "-w", "-i", "NEEDLE", root.path("dense.txt")], Data("\(root.path("dense.txt"))\0".utf8), Int32(0)),
            (["--files-without-match", "-w", "-i", "EED", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "-w", "-i", "NEEDLE", root.path("dense.txt")], Data(), Int32(1)),
            (["--stop-on-nonmatch", "-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--stop-on-nonmatch", "-l", "missing", root.path("dense.txt")], Data(), Int32(1)),
            (["--stop-on-nonmatch", "--files-without-match", "needle", root.path("dense.txt")], Data(), Int32(1)),
            (["--stop-on-nonmatch", "--files-without-match", "missing", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["-l", "needle|tail", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["-l", "--path-separator=Z", "needle|tail", root.path("dense.txt")], Data("\(pathSeparatedName)\n".utf8), Int32(0)),
            (["-li", "NEEDLE|TAIL", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["-li", "123|456", root.path("dense.txt")], Data(), Int32(1)),
            (["--files-without-match", "-i", "123|456", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["-l", "missing|absent", root.path("dense.txt")], Data(), Int32(1)),
            (["--files-without-match", "missing|absent", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "needle|tail", root.path("dense.txt")], Data(), Int32(1)),
            (["-l", "-x", "needle", root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["-l", "-i", "-x", "NEEDLE", root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["-l", "-x", "missing", root.path("exact.txt")], Data(), Int32(1)),
            (["--files-with-matches", "--null", "-x", "needle", root.path("exact.txt")], Data("\(root.path("exact.txt"))\0".utf8), Int32(0)),
            (["--files-without-match", "-i", "-x", "NEEDLE", root.path("exact.txt")], Data(), Int32(1)),
            (["--files-without-match", "-i", "-x", "12345", root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "-x", "missing", root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "-x", "needle", root.path("exact.txt")], Data(), Int32(1)),
            (["-l", "-x", "needle|last", root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["-l", "-i", "-x", "NEEDLE|LAST", root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["-l", "-i", "-x", "--path-separator=Z", "NEEDLE|LAST", root.path("exact.txt")], Data("\(root.path("exact.txt").replacingOccurrences(of: "/", with: "Z"))\n".utf8), Int32(0)),
            (["-l", "-x", "-e", "needle", "-e", "last", root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["-l", "-i", "-x", "-e", "NEEDLE", "-e", "LAST", root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["-l", "-x", "-f", root.path("exact-patterns.txt"), root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["-l", "-i", "-x", "-f", root.path("exact-patterns.txt"), root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["--files-with-matches", "--null", "-x", "needle|last", root.path("exact.txt")], Data("\(root.path("exact.txt"))\0".utf8), Int32(0)),
            (["--files-with-matches", "--null", "-i", "-x", "NEEDLE|LAST", root.path("exact.txt")], Data("\(root.path("exact.txt"))\0".utf8), Int32(0)),
            (["--files-without-match", "-x", "missing|absent", root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "-i", "-x", "MISSING|ABSENT", root.path("exact.txt")], Data("\(root.path("exact.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "-x", "needle|last", root.path("exact.txt")], Data(), Int32(1)),
            (["--files-without-match", "-i", "-x", "NEEDLE|LAST", root.path("exact.txt")], Data(), Int32(1)),
            (["--crlf", "-l", "-i", "-x", "NEEDLE|QUIET", root.path("crlf.txt")], Data("\(root.path("crlf.txt"))\r\n".utf8), Int32(0)),
        ] {
            let pathOnlyResult = try runExecutableResult(pathOnlyArguments)
            #expect(pathOnlyResult.stdout == expectedOutput)
            #expect(pathOnlyResult.stderr.isEmpty)
            #expect(pathOnlyResult.status == expectedStatus)
        }

        for (printModeArguments, expectedOutput, expectedStatus) in [
            (
                ["--count", "--files-with-matches", "needle", root.path("dense.txt")],
                Data("\(root.path("dense.txt"))\n".utf8),
                Int32(0)
            ),
            (
                ["--count-matches", "--files-with-matches", "needle", root.path("dense.txt")],
                Data("\(root.path("dense.txt"))\n".utf8),
                Int32(0)
            ),
            (
                ["--files-with-matches", "--count", "needle", root.path("dense.txt")],
                Data("3\n".utf8),
                Int32(0)
            ),
            (
                ["--count-matches", "--count", "needle", root.path("dense.txt")],
                Data("3\n".utf8),
                Int32(0)
            ),
            (
                ["--files-with-matches", "--count-matches", "needle", root.path("dense.txt")],
                Data("5\n".utf8),
                Int32(0)
            ),
            (
                ["--count", "--count-matches", "needle", root.path("dense.txt")],
                Data("5\n".utf8),
                Int32(0)
            ),
            (
                ["--count", "--files-without-match", "needle", root.path("dense.txt")],
                Data(),
                Int32(1)
            ),
            (
                ["--count", "--files-without-match", "missing", root.path("dense.txt")],
                Data("\(root.path("dense.txt"))\n".utf8),
                Int32(0)
            ),
            (
                ["--files-without-match", "--count", "needle", root.path("dense.txt")],
                Data("3\n".utf8),
                Int32(0)
            ),
        ] {
            let printModeResult = try runExecutableResult(printModeArguments)
            #expect(printModeResult.stdout == expectedOutput)
            #expect(printModeResult.stderr.isEmpty)
            #expect(printModeResult.status == expectedStatus)
        }

        for (maxCountArguments, expectedOutput) in [
            (["-m1", "needle", root.path("dense.txt")], Data("needle needle needle\n".utf8)),
            (["--line-buffered", "-m1", "needle", root.path("dense.txt")], Data("needle needle needle\n".utf8)),
            (["-n", "-m1", "needle", root.path("dense.txt")], Data("1:needle needle needle\n".utf8)),
            (["--with-filename", "-m1", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt")):needle needle needle\n".utf8)),
            (["--heading", "--with-filename", "-m1", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\nneedle needle needle\n".utf8)),
            (["--max-count=2", "needle", root.path("dense.txt")], Data("""
            needle needle needle
            NEEDLE needle Needle

            """.utf8)),
            (["--max-count", "1", "needle", root.path("dense.txt")], Data("needle needle needle\n".utf8)),
            (["-m1", "needle|tail", root.path("dense.txt")], Data("needle needle needle\n".utf8)),
        ] {
            let maxCountOutput = try runExecutableData(maxCountArguments, fixture: {})
            #expect(maxCountOutput == expectedOutput)
        }
        let maxCountNoMatch = try runExecutableResult([
            "--max-count",
            "1",
            "missing",
            root.path("quiet-no-match.txt"),
        ])
        #expect(maxCountNoMatch.stdout.isEmpty)
        #expect(maxCountNoMatch.stderr.isEmpty)
        #expect(maxCountNoMatch.status == 1)

        for maxCountZeroArguments in [
            ["-m0", "-q", "needle", root.path("dense.txt")],
            ["-m0", "-l", "needle", root.path("dense.txt")],
            ["-m0", "-c", "--include-zero", "needle", root.path("dense.txt")],
            ["-m0", "needle", root.path("missing.txt")],
        ] {
            let maxCountZeroResult = try runExecutableResult(maxCountZeroArguments)
            #expect(maxCountZeroResult.stdout.isEmpty)
            #expect(maxCountZeroResult.stderr.isEmpty)
            #expect(maxCountZeroResult.status == 1)
        }

        let exactLineOnlyMatchingOutput = try runExecutableData([
            "-o",
            "-x",
            "needle|last",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLineOnlyMatchingOutput == Data("""
        needle
        needle
        last

        """.utf8))

        let exactLineOnlyMatchingLineNumberOutput = try runExecutableData([
            "-n",
            "-o",
            "-x",
            "needle|last",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLineOnlyMatchingLineNumberOutput == Data("""
        1:needle
        3:needle
        5:last

        """.utf8))

        let exactLineOnlyMatchingClusterOutput = try runExecutableData([
            "-nox",
            "needle|last",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLineOnlyMatchingClusterOutput == exactLineOnlyMatchingLineNumberOutput)

        let exactLineOnlyMatchingBoundedOutput = try runExecutableData([
            "-m2",
            "-o",
            "-x",
            "needle|last",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLineOnlyMatchingBoundedOutput == Data("""
        needle
        needle

        """.utf8))

        let exactLineOnlyMatchingRepeatedRegexpOutput = try runExecutableData([
            "-o",
            "-x",
            "-e",
            "needle",
            "-e",
            "last",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLineOnlyMatchingRepeatedRegexpOutput == exactLineOnlyMatchingOutput)

        let exactLineOnlyMatchingPatternFileOutput = try runExecutableData([
            "-o",
            "-x",
            "-f",
            root.path("exact-patterns.txt"),
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLineOnlyMatchingPatternFileOutput == exactLineOnlyMatchingOutput)

        let exactLineOnlyMatchingHeadingOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "-n",
            "-o",
            "-x",
            "needle|last",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLineOnlyMatchingHeadingOutput == Data("""
        \(root.path("exact.txt"))
        1:needle
        3:needle
        5:last

        """.utf8))

        let exactLineOnlyMatchingCrlfOutput = try runExecutableData([
            "--crlf",
            "-o",
            "-x",
            "needle",
            root.path("crlf.txt"),
        ], fixture: {})
        #expect(exactLineOnlyMatchingCrlfOutput == Data("needle\r\n".utf8))

        let caseInsensitiveExactLineOutput = try runExecutableData([
            "-i",
            "-x",
            "NEEDLE|LAST",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineOutput == exactLineOnlyMatchingOutput)

        let caseInsensitiveExactLineLineNumberOutput = try runExecutableData([
            "-n",
            "-i",
            "-x",
            "NEEDLE|LAST",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineLineNumberOutput == exactLineOnlyMatchingLineNumberOutput)

        let caseInsensitiveExactLineOnlyMatchingOutput = try runExecutableData([
            "-n",
            "-o",
            "-i",
            "-x",
            "NEEDLE|LAST",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineOnlyMatchingOutput == exactLineOnlyMatchingLineNumberOutput)

        let caseInsensitiveExactLineBoundedOutput = try runExecutableData([
            "-m2",
            "-i",
            "-x",
            "NEEDLE|LAST",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineBoundedOutput == exactLineOnlyMatchingBoundedOutput)

        let caseInsensitiveExactLineRepeatedRegexpOutput = try runExecutableData([
            "-i",
            "-x",
            "-e",
            "NEEDLE",
            "-e",
            "LAST",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineRepeatedRegexpOutput == exactLineOnlyMatchingOutput)

        let caseInsensitiveExactLinePatternFileOutput = try runExecutableData([
            "-i",
            "-x",
            "-f",
            root.path("exact-patterns.txt"),
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLinePatternFileOutput == exactLineOnlyMatchingOutput)

        let caseInsensitiveExactLineHeadingOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "-n",
            "-i",
            "-x",
            "NEEDLE|LAST",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineHeadingOutput == exactLineOnlyMatchingHeadingOutput)

        let caseInsensitiveExactLineCrlfOutput = try runExecutableData([
            "--crlf",
            "-i",
            "-x",
            "NEEDLE",
            root.path("crlf.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineCrlfOutput == Data("needle\r\n".utf8))

        let caseInsensitiveExactLineCountOutput = try runExecutableData([
            "-c",
            "-i",
            "-x",
            "NEEDLE|LAST",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineCountOutput == Data("3\n".utf8))

        let caseInsensitiveExactLineCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-i",
            "-x",
            "NEEDLE|LAST",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineCountMatchesOutput == caseInsensitiveExactLineCountOutput)

        let caseInsensitiveExactLineBoundedCountOutput = try runExecutableData([
            "-c",
            "-m2",
            "-i",
            "-x",
            "NEEDLE|LAST",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineBoundedCountOutput == Data("2\n".utf8))

        let caseInsensitiveExactLineRepeatedRegexpCountOutput = try runExecutableData([
            "-c",
            "-i",
            "-x",
            "-e",
            "NEEDLE",
            "-e",
            "LAST",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineRepeatedRegexpCountOutput == caseInsensitiveExactLineCountOutput)

        let caseInsensitiveExactLinePatternFileCountOutput = try runExecutableData([
            "--count-matches",
            "-i",
            "-x",
            "-f",
            root.path("exact-patterns.txt"),
            root.path("exact.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLinePatternFileCountOutput == caseInsensitiveExactLineCountOutput)

        let includeZeroCaseInsensitiveExactLineCountResult = try runExecutableResult([
            "--include-zero",
            "-c",
            "-i",
            "-x",
            "MISSING",
            root.path("exact.txt"),
        ])
        #expect(includeZeroCaseInsensitiveExactLineCountResult.status == 1)
        #expect(includeZeroCaseInsensitiveExactLineCountResult.stdout == Data("0\n".utf8))
        #expect(includeZeroCaseInsensitiveExactLineCountResult.stderr.isEmpty)

        let caseInsensitiveExactLineCrlfCountOutput = try runExecutableData([
            "--crlf",
            "-c",
            "-i",
            "-x",
            "NEEDLE",
            root.path("crlf.txt"),
        ], fixture: {})
        #expect(caseInsensitiveExactLineCrlfCountOutput == Data("1\r\n".utf8))

        for (countArguments, expectedOutput, expectedStatus) in [
            (["-c", "needle", root.path("dense.txt")], Data("3\n".utf8), Int32(0)),
            (["--count", "missing", root.path("quiet-no-match.txt")], Data(), Int32(1)),
            (["--count", "--include-zero", "missing", root.path("quiet-no-match.txt")], Data("0\n".utf8), Int32(1)),
            (["-c", "-m1", "needle", root.path("dense.txt")], Data("1\n".utf8), Int32(0)),
            (["--crlf", "-c", "-m1", "needle", root.path("dense.txt")], Data("1\r\n".utf8), Int32(0)),
            (["--null-data", "--crlf", "-c", "-m1", "needle", root.path("dense.txt")], Data("1\r\n".utf8), Int32(0)),
            (["--crlf", "-c", "-m1", "--include-zero", "missing", root.path("dense.txt")], Data("0\r\n".utf8), Int32(1)),
            (["--line-buffered", "-c", "-m1", "needle", root.path("dense.txt")], Data("1\n".utf8), Int32(0)),
            (["--trim", "-c", "needle", root.path("trim.txt")], Data("3\n".utf8), Int32(0)),
            (["--trim", "-c", "-i", "NEEDLE|QUIET", root.path("trim-case.txt")], Data("3\n".utf8), Int32(0)),
            (["-M1", "-c", "needle", root.path("dense.txt")], Data("3\n".utf8), Int32(0)),
            (["-rX", "-c", "needle", root.path("dense.txt")], Data("3\n".utf8), Int32(0)),
            (["--passthru", "-c", "needle", root.path("dense.txt")], Data("3\n".utf8), Int32(0)),
            (["-c", "-m1", "-i", "NEEDLE", root.path("dense.txt")], Data("1\n".utf8), Int32(0)),
            (["-ci", "-m1", "NEEDLE", root.path("dense.txt")], Data("1\n".utf8), Int32(0)),
            (["-c", "-m1", "-i", "missing", root.path("dense.txt")], Data(), Int32(1)),
            (["-c", "-m1", "-i", "12345", root.path("dense.txt")], Data(), Int32(1)),
            (["-c", "-m1", "-i", "--include-zero", "12345", root.path("dense.txt")], Data("0\n".utf8), Int32(1)),
            (["-c", "-w", "--include-zero", "missing", root.path("dense.txt")], Data("0\n".utf8), Int32(1)),
            (["-c", "-w", "-i", "NEEDLE", root.path("dense.txt")], Data("3\n".utf8), Int32(0)),
            (["-c", "-m2", "-w", "-i", "NEEDLE", root.path("dense.txt")], Data("2\n".utf8), Int32(0)),
            (["-c", "-w", "-i", "--include-zero", "EED", root.path("dense.txt")], Data("0\n".utf8), Int32(1)),
            (["-c", "-i", "NEEDLE|QUIET", root.path("dense.txt")], Data("4\n".utf8), Int32(0)),
            (["-c", "-m2", "-i", "NEEDLE|QUIET", root.path("dense.txt")], Data("2\n".utf8), Int32(0)),
            (["-H", "-c", "-i", "NEEDLE|QUIET", root.path("dense.txt")], Data("\(root.path("dense.txt")):4\n".utf8), Int32(0)),
            (["-c", "-i", "-e", "NEEDLE", "-e", "QUIET", root.path("dense.txt")], Data("4\n".utf8), Int32(0)),
            (["-c", "-i", "-f", root.path("patterns.txt"), root.path("dense.txt")], Data("4\n".utf8), Int32(0)),
            (["-c", "-i", "--include-zero", "MISSING|ABSENT", root.path("dense.txt")], Data("0\n".utf8), Int32(1)),
            (["-c", "-x", "needle", root.path("exact.txt")], Data("2\n".utf8), Int32(0)),
            (["-c", "-m1", "-x", "needle", root.path("exact.txt")], Data("1\n".utf8), Int32(0)),
            (["-c", "-m1", "-i", "-x", "NEEDLE", root.path("exact.txt")], Data("1\n".utf8), Int32(0)),
            (["-cix", "-m1", "NEEDLE", root.path("exact.txt")], Data("1\n".utf8), Int32(0)),
            (["-c", "-m1", "-i", "-x", "--include-zero", "12345", root.path("exact.txt")], Data("0\n".utf8), Int32(1)),
            (["-c", "-x", "--include-zero", "missing", root.path("exact.txt")], Data("0\n".utf8), Int32(1)),
            (["-c", "-x", "needle|last", root.path("exact.txt")], Data("3\n".utf8), Int32(0)),
            (["-c", "-m2", "-x", "needle|last", root.path("exact.txt")], Data("2\n".utf8), Int32(0)),
            (["-c", "-x", "-e", "needle", "-e", "last", root.path("exact.txt")], Data("3\n".utf8), Int32(0)),
        ] {
            let countResult = try runExecutableResult(countArguments)
            #expect(countResult.stdout == expectedOutput)
            #expect(countResult.stderr.isEmpty)
            #expect(countResult.status == expectedStatus)
        }

        let singleLiteralLineBufferedCountOutput = try runExecutableData([
            "--line-buffered",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(singleLiteralLineBufferedCountOutput == Data("3\n".utf8))

        let singleLiteralCrlfCountOutput = try runExecutableData([
            "--crlf",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(singleLiteralCrlfCountOutput == Data("3\r\n".utf8))

        let wordCountOutput = try runExecutableData([
            "-c",
            "-w",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(wordCountOutput == Data("3\n".utf8))

        let caseInsensitiveWordCountOutput = try runExecutableData([
            "-c",
            "-w",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveWordCountOutput == wordCountOutput)

        let unicodeCaseInsensitiveWordCountOutput = try runExecutableData([
            "-c",
            "-w",
            "-i",
            "NEEDLE",
            root.path("unicode-word-ci.txt"),
        ], fixture: {})
        #expect(unicodeCaseInsensitiveWordCountOutput == Data("2\n".utf8))

        let embeddedWordCountOutput = try runExecutableData([
            "-c",
            "-w",
            "needle",
            root.path("word-count.txt"),
        ], fixture: {})
        #expect(embeddedWordCountOutput == Data("1\n".utf8))

        let multiLiteralWordCountOutput = try runExecutableData([
            "-c",
            "-w",
            "needle|quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(multiLiteralWordCountOutput == Data("4\n".utf8))

        let caseInsensitiveMultiLiteralWordCountOutput = try runExecutableData([
            "-c",
            "-w",
            "-i",
            "NEEDLE|QUIET",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveMultiLiteralWordCountOutput == multiLiteralWordCountOutput)

        let multiLiteralWordMaxCountOutput = try runExecutableData([
            "-c",
            "-m2",
            "-w",
            "needle|quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(multiLiteralWordMaxCountOutput == Data("2\n".utf8))

        let caseInsensitiveMultiLiteralWordMaxCountOutput = try runExecutableData([
            "-c",
            "-m2",
            "-w",
            "-i",
            "NEEDLE|QUIET",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveMultiLiteralWordMaxCountOutput == multiLiteralWordMaxCountOutput)

        let patternFileWordCountOutput = try runExecutableData([
            "-c",
            "-w",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(patternFileWordCountOutput == multiLiteralWordCountOutput)

        let caseInsensitivePatternFileWordCountOutput = try runExecutableData([
            "-c",
            "-w",
            "-i",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitivePatternFileWordCountOutput == multiLiteralWordCountOutput)

        let singleLiteralPrefixedCountOutput = try runExecutableData([
            "-H",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(singleLiteralPrefixedCountOutput == Data("\(root.path("dense.txt")):3\n".utf8))

        let prefixedWordCountOutput = try runExecutableData([
            "-H",
            "-c",
            "-w",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(prefixedWordCountOutput == singleLiteralPrefixedCountOutput)

        let prefixedCaseInsensitiveWordCountOutput = try runExecutableData([
            "-H",
            "-c",
            "-w",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(prefixedCaseInsensitiveWordCountOutput == singleLiteralPrefixedCountOutput)

        let singleLiteralNullPrefixedCountOutput = try runExecutableData([
            "-H",
            "--null",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(singleLiteralNullPrefixedCountOutput == Data((
            "\(root.path("dense.txt"))\0" +
            "3\n"
        ).utf8))

        let singleLiteralPrefixedMaxCountOutput = try runExecutableData([
            "-H",
            "-c",
            "-m2",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(singleLiteralPrefixedMaxCountOutput == Data("\(root.path("dense.txt")):2\n".utf8))

        let wordMaxCountOutput = try runExecutableData([
            "-c",
            "-m2",
            "-w",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(wordMaxCountOutput == Data("2\n".utf8))

        let singleLiteralPrefixedCaseInsensitiveMaxCountOutput = try runExecutableData([
            "-H",
            "-c",
            "-m1",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(singleLiteralPrefixedCaseInsensitiveMaxCountOutput == Data("\(root.path("dense.txt")):1\n".utf8))

        let countMatchesOutput = try runExecutableData([
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(countMatchesOutput == Data("5\n".utf8))

        let utf8EncodingQuietResult = try runExecutableResult([
            "--encoding=utf-8",
            "-q",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(utf8EncodingQuietResult.status == 0)
        #expect(utf8EncodingQuietResult.stdout.isEmpty)
        #expect(utf8EncodingQuietResult.stderr.isEmpty)

        let utf8EncodingPathOnlyOutput = try runExecutableData([
            "--encoding",
            "utf8",
            "-l",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(utf8EncodingPathOnlyOutput == Data("\(root.path("dense.txt"))\n".utf8))

        let utf8EncodingCountOutput = try runExecutableData([
            "-E",
            "utf-8",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(utf8EncodingCountOutput == Data("3\n".utf8))

        let utf8EncodingCountMatchesOutput = try runExecutableData([
            "-Eutf8",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(utf8EncodingCountMatchesOutput == countMatchesOutput)

        let utf8EncodingLineOutput = try runExecutableData([
            "--encoding=utf-8",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(utf8EncodingLineOutput == output)

        let utf8EncodingLineNumberOutput = try runExecutableData([
            "--encoding",
            "utf8",
            "-n",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(utf8EncodingLineNumberOutput == lineNumberOutput)

        let utf8EncodingMaxCountOutput = try runExecutableData([
            "-Eutf8",
            "-m2",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(utf8EncodingMaxCountOutput == Data("""
        needle needle needle
        NEEDLE needle Needle

        """.utf8))

        let utf8EncodingInvalidLineOutput = try runExecutableData([
            "--encoding=utf-8",
            "needle",
            root.path("encoding-none-invalid.txt"),
        ], fixture: {})
        #expect(utf8EncodingInvalidLineOutput == Data("\u{FFFD}needle raw\n".utf8))

        let utf8EncodingBOMLineOutput = try runExecutableData([
            "--encoding=utf-8",
            "needle",
            root.path("encoding-none-bom.txt"),
        ], fixture: {})
        #expect(utf8EncodingBOMLineOutput == Data("needle\n".utf8))

        let utf8EncodingIgnoreCaseOutput = try runExecutableData([
            "--encoding=utf-8",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(utf8EncodingIgnoreCaseOutput == ignoreCaseOutput)

        let utf8EncodingWordOutput = try runExecutableData([
            "--encoding=utf-8",
            "-w",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(utf8EncodingWordOutput == output)

        let utf8EncodingExactLineOutput = try runExecutableData([
            "--encoding=utf-8",
            "-x",
            "needle",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(utf8EncodingExactLineOutput == Data("needle\nneedle\n".utf8))

        let utf8EncodingOnlyMatchingOutput = try runExecutableData([
            "--encoding=utf-8",
            "-o",
            "needle",
            root.path("word-count.txt"),
        ], fixture: {})
        #expect(utf8EncodingOnlyMatchingOutput == plainOnlyMatchingOutput)

        let utf8EncodingUnicodeCaseFoldOutput = try runExecutableData([
            "--encoding=utf-8",
            "-i",
            "k",
            root.path("utf8-casefold.txt"),
        ], fixture: {})
        #expect(utf8EncodingUnicodeCaseFoldOutput == Data([0xE2, 0x84, 0xAA, 0x0A, 0x4B, 0x0A]))

        let disabledEncodingPathOnlyOutput = try runExecutableData([
            "--encoding=none",
            "-l",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(disabledEncodingPathOnlyOutput == Data("\(root.path("dense.txt"))\n".utf8))

        let disabledEncodingLineOutput = try runExecutableData([
            "--encoding=none",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(disabledEncodingLineOutput == output)

        let disabledEncodingLineNumberOutput = try runExecutableData([
            "--encoding",
            "none",
            "-n",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(disabledEncodingLineNumberOutput == lineNumberOutput)

        let disabledEncodingIgnoreCaseOutput = try runExecutableData([
            "--encoding=none",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(disabledEncodingIgnoreCaseOutput == ignoreCaseOutput)

        let disabledEncodingInvalidLineOutput = try runExecutableData([
            "--encoding=none",
            "needle",
            root.path("encoding-none-invalid.txt"),
        ], fixture: {})
        #expect(disabledEncodingInvalidLineOutput == Data([0xFF]) + Data("needle raw\n".utf8))

        let disabledEncodingInvalidIgnoreCaseOutput = try runExecutableData([
            "--encoding=none",
            "-i",
            "NEEDLE",
            root.path("encoding-none-invalid.txt"),
        ], fixture: {})
        #expect(disabledEncodingInvalidIgnoreCaseOutput == disabledEncodingInvalidLineOutput)

        let disabledEncodingBOMLineOutput = try runExecutableData([
            "--encoding=none",
            "needle",
            root.path("encoding-none-bom.txt"),
        ], fixture: {})
        #expect(disabledEncodingBOMLineOutput == Data([0xEF, 0xBB, 0xBF]) + Data("needle\n".utf8))

        let searchZipLineOutput = try runExecutableData([
            "--search-zip",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(searchZipLineOutput == output)

        let searchZipQuietResult = try runExecutableResult([
            "--search-zip",
            "-q",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(searchZipQuietResult.status == 0)
        #expect(searchZipQuietResult.stdout.isEmpty)
        #expect(searchZipQuietResult.stderr.isEmpty)

        let searchZipPathOnlyOutput = try runExecutableData([
            "--search-zip",
            "-l",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(searchZipPathOnlyOutput == Data("\(root.path("dense.txt"))\n".utf8))

        let searchZipCountOutput = try runExecutableData([
            "--search-zip",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(searchZipCountOutput == Data("3\n".utf8))

        let searchZipCountMatchesOutput = try runExecutableData([
            "--search-zip",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(searchZipCountMatchesOutput == countMatchesOutput)

        let vimgrepQuietResult = try runExecutableResult([
            "--vimgrep",
            "-q",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(vimgrepQuietResult.status == 0)
        #expect(vimgrepQuietResult.stdout.isEmpty)
        #expect(vimgrepQuietResult.stderr.isEmpty)

        let vimgrepPathOnlyOutput = try runExecutableData([
            "--vimgrep",
            "-l",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(vimgrepPathOnlyOutput == Data("\(root.path("dense.txt"))\n".utf8))

        let vimgrepCountOutput = try runExecutableData([
            "--vimgrep",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(vimgrepCountOutput == Data("\(root.path("dense.txt")):3\n".utf8))

        let vimgrepCountMatchesOutput = try runExecutableData([
            "--vimgrep",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(vimgrepCountMatchesOutput == Data("\(root.path("dense.txt")):5\n".utf8))

        let vimgrepNoFilenameCountOutput = try runExecutableData([
            "--vimgrep",
            "--no-filename",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(vimgrepNoFilenameCountOutput == Data("3\n".utf8))

        let vimgrepNoFilenameCountMatchesOutput = try runExecutableData([
            "--vimgrep",
            "--no-filename",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(vimgrepNoFilenameCountMatchesOutput == countMatchesOutput)

        let byteOffsetQuietResult = try runExecutableResult([
            "--byte-offset",
            "-q",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(byteOffsetQuietResult.status == 0)
        #expect(byteOffsetQuietResult.stdout.isEmpty)
        #expect(byteOffsetQuietResult.stderr.isEmpty)

        let byteOffsetPathOnlyOutput = try runExecutableData([
            "--byte-offset",
            "-l",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(byteOffsetPathOnlyOutput == Data("\(root.path("dense.txt"))\n".utf8))

        let byteOffsetCountOutput = try runExecutableData([
            "--byte-offset",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(byteOffsetCountOutput == Data("3\n".utf8))

        let columnCountMatchesOutput = try runExecutableData([
            "--column",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(columnCountMatchesOutput == countMatchesOutput)

        let colorQuietResult = try runExecutableResult([
            "--color=always",
            "-q",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(colorQuietResult.status == 0)
        #expect(colorQuietResult.stdout.isEmpty)
        #expect(colorQuietResult.stderr.isEmpty)

        let colorCountOutput = try runExecutableData([
            "--color=always",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(colorCountOutput == Data("3\n".utf8))

        let colorPrefixedCountOutput = try runExecutableData([
            "--color=always",
            "-H",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(colorPrefixedCountOutput == Data(
            "\u{1B}[0m\u{1B}[35m\(root.path("dense.txt"))\u{1B}[0m:3\n".utf8
        ))

        let colorAutoPrefixedCountOutput = try runExecutableData([
            "--color=auto",
            "-H",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(colorAutoPrefixedCountOutput == Data("\(root.path("dense.txt")):3\n".utf8))

        let customPathColorPrefixedCountOutput = try runExecutableData([
            "--colors",
            "path:fg:red",
            "--color=always",
            "-H",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(customPathColorPrefixedCountOutput == Data(
            "\u{1B}[0m\u{1B}[31m\(root.path("dense.txt"))\u{1B}[0m:3\n".utf8
        ))

        let prettyCountMatchesOutput = try runExecutableData([
            "--pretty",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(prettyCountMatchesOutput == countMatchesOutput)

        let onlyMatchingQuietResult = try runExecutableResult([
            "-o",
            "-q",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(onlyMatchingQuietResult.status == 0)
        #expect(onlyMatchingQuietResult.stdout.isEmpty)
        #expect(onlyMatchingQuietResult.stderr.isEmpty)

        let onlyMatchingPathOnlyOutput = try runExecutableData([
            "-o",
            "-l",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(onlyMatchingPathOnlyOutput == Data("\(root.path("dense.txt"))\n".utf8))

        let onlyMatchingFilesWithoutMatchOutput = try runExecutableData([
            "-o",
            "--files-without-match",
            "missing",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(onlyMatchingFilesWithoutMatchOutput == Data("\(root.path("dense.txt"))\n".utf8))

        let onlyMatchingCountMatchesOutput = try runExecutableData([
            "-o",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(onlyMatchingCountMatchesOutput == countMatchesOutput)

        let onlyMatchingCountOutput = try runExecutableData([
            "-o",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(onlyMatchingCountOutput == countMatchesOutput)

        let afterContextQuietResult = try runExecutableResult([
            "--after-context=1",
            "-q",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(afterContextQuietResult.status == 0)
        #expect(afterContextQuietResult.stdout.isEmpty)
        #expect(afterContextQuietResult.stderr.isEmpty)

        let beforeContextPathOnlyOutput = try runExecutableData([
            "--before-context=1",
            "-l",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(beforeContextPathOnlyOutput == Data("\(root.path("dense.txt"))\n".utf8))

        let contextFilesWithoutMatchOutput = try runExecutableData([
            "--context=1",
            "--files-without-match",
            "missing",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(contextFilesWithoutMatchOutput == Data("\(root.path("dense.txt"))\n".utf8))

        let afterContextCountOutput = try runExecutableData([
            "--after-context=1",
            "-c",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(afterContextCountOutput == Data("3\n".utf8))

        let beforeContextCountMatchesOutput = try runExecutableData([
            "--before-context=1",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(beforeContextCountMatchesOutput == countMatchesOutput)

        let trimCountMatchesOutput = try runExecutableData([
            "--trim",
            "--count-matches",
            "needle",
            root.path("trim.txt"),
        ], fixture: {})
        #expect(trimCountMatchesOutput == Data("3\n".utf8))

        let nullDataCountMatchesOutput = try runExecutableData([
            "--null-data",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(nullDataCountMatchesOutput == countMatchesOutput)

        let maxColumnsCountMatchesOutput = try runExecutableData([
            "-M1",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(maxColumnsCountMatchesOutput == countMatchesOutput)

        let replacementCountMatchesOutput = try runExecutableData([
            "--replace",
            "X",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(replacementCountMatchesOutput == countMatchesOutput)

        let passthruCountMatchesOutput = try runExecutableData([
            "--passthru",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(passthruCountMatchesOutput == countMatchesOutput)

        let exactLineCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-x",
            "needle",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLineCountMatchesOutput == Data("2\n".utf8))

        let exactLineBoundedCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-m1",
            "-x",
            "needle",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLineBoundedCountMatchesOutput == Data("1\n".utf8))

        let exactLineAlternationCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-x",
            "needle|last",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLineAlternationCountMatchesOutput == Data("3\n".utf8))

        let exactLinePatternFileCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-x",
            "-f",
            root.path("exact-patterns.txt"),
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLinePatternFileCountMatchesOutput == exactLineAlternationCountMatchesOutput)

        let exactLinePrefixedCountMatchesOutput = try runExecutableData([
            "-H",
            "--count-matches",
            "-x",
            "needle",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLinePrefixedCountMatchesOutput == Data("\(root.path("exact.txt")):2\n".utf8))

        let explicitRegexpCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-e",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(explicitRegexpCountMatchesOutput == countMatchesOutput)

        let wordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(wordCountMatchesOutput == countMatchesOutput)

        let caseInsensitiveWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "-i",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveWordCountMatchesOutput == Data("7\n".utf8))

        let includeZeroCaseInsensitiveWordCountMatchesResult = try runExecutableResult([
            "--count-matches",
            "--include-zero",
            "-w",
            "-i",
            "EED",
            root.path("dense.txt"),
        ])
        #expect(includeZeroCaseInsensitiveWordCountMatchesResult.status == 1)
        #expect(includeZeroCaseInsensitiveWordCountMatchesResult.stdout == Data("0\n".utf8))
        #expect(includeZeroCaseInsensitiveWordCountMatchesResult.stderr.isEmpty)

        let unicodeCaseInsensitiveWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "-i",
            "NEEDLE",
            root.path("unicode-word-ci.txt"),
        ], fixture: {})
        #expect(unicodeCaseInsensitiveWordCountMatchesOutput == Data("2\n".utf8))

        let multiLiteralWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "needle|quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(multiLiteralWordCountMatchesOutput == Data("6\n".utf8))

        let boundedMultiLiteralWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "-m2",
            "needle|quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedMultiLiteralWordCountMatchesOutput == Data("4\n".utf8))

        let caseInsensitiveMultiLiteralWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "-i",
            "NEEDLE|QUIET",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitiveMultiLiteralWordCountMatchesOutput == Data("8\n".utf8))

        let boundedCaseInsensitiveMultiLiteralWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "-i",
            "-m2",
            "NEEDLE|QUIET",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedCaseInsensitiveMultiLiteralWordCountMatchesOutput == Data("4\n".utf8))

        let patternFileWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(patternFileWordCountMatchesOutput == multiLiteralWordCountMatchesOutput)

        let boundedPatternFileWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "-m2",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedPatternFileWordCountMatchesOutput == boundedMultiLiteralWordCountMatchesOutput)

        let caseInsensitivePatternFileWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "-i",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(caseInsensitivePatternFileWordCountMatchesOutput == caseInsensitiveMultiLiteralWordCountMatchesOutput)

        let boundedCaseInsensitivePatternFileWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "-i",
            "-m2",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(
            boundedCaseInsensitivePatternFileWordCountMatchesOutput
                == boundedCaseInsensitiveMultiLiteralWordCountMatchesOutput
        )

        let embeddedWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "needle",
            root.path("word-count.txt"),
        ], fixture: {})
        #expect(embeddedWordCountMatchesOutput == Data("1\n".utf8))

        let repeatedRegexpCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpCountMatchesOutput == Data("6\n".utf8))

        let boundedRepeatedRegexpCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedRepeatedRegexpCountMatchesOutput == Data("4\n".utf8))

        let patternFileCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(patternFileCountMatchesOutput == repeatedRegexpCountMatchesOutput)

        let boundedPatternFileCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-m2",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedPatternFileCountMatchesOutput == boundedRepeatedRegexpCountMatchesOutput)

        let alternationCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "needle|quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(alternationCountMatchesOutput == repeatedRegexpCountMatchesOutput)

        let prefixedCountMatchesOutput = try runExecutableData([
            "-H",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(prefixedCountMatchesOutput == Data("\(root.path("dense.txt")):5\n".utf8))

        let prefixedWordCountMatchesOutput = try runExecutableData([
            "-H",
            "--count-matches",
            "-w",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(prefixedWordCountMatchesOutput == prefixedCountMatchesOutput)

        let prefixedPatternFileCountMatchesOutput = try runExecutableData([
            "-H",
            "--count-matches",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(prefixedPatternFileCountMatchesOutput == Data("\(root.path("dense.txt")):6\n".utf8))

        let boundedCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-m1",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedCountMatchesOutput == Data("3\n".utf8))

        let boundedOnlyMatchingCountOutput = try runExecutableData([
            "-o",
            "-c",
            "-m2",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedOnlyMatchingCountOutput == Data("4\n".utf8))

        let prefixedBoundedCountMatchesOutput = try runExecutableData([
            "-H",
            "--count-matches",
            "-m1",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(prefixedBoundedCountMatchesOutput == Data("\(root.path("dense.txt")):3\n".utf8))

        let boundedCaseInsensitiveCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-i",
            "-m2",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedCaseInsensitiveCountMatchesOutput == Data("6\n".utf8))

        let boundedCaseInsensitiveOnlyMatchingCountOutput = try runExecutableData([
            "-o",
            "-c",
            "-i",
            "-m1",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedCaseInsensitiveOnlyMatchingCountOutput == Data("3\n".utf8))

        let boundedWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "-m2",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedWordCountMatchesOutput == Data("4\n".utf8))

        let prefixedBoundedWordCountMatchesOutput = try runExecutableData([
            "-H",
            "--count-matches",
            "-w",
            "-m1",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(prefixedBoundedWordCountMatchesOutput == Data("\(root.path("dense.txt")):3\n".utf8))

        let boundedCaseInsensitiveWordCountMatchesOutput = try runExecutableData([
            "--count-matches",
            "-w",
            "-i",
            "-m2",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedCaseInsensitiveWordCountMatchesOutput == Data("6\n".utf8))

        let boundedCaseInsensitiveWordOnlyMatchingCountOutput = try runExecutableData([
            "-o",
            "-c",
            "-w",
            "-i",
            "-m1",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(boundedCaseInsensitiveWordOnlyMatchingCountOutput == Data("3\n".utf8))

        let includeZeroCountMatchesResult = try runExecutableResult([
            "--include-zero",
            "--count-matches",
            "missing",
            root.path("dense.txt"),
        ])
        #expect(includeZeroCountMatchesResult.status == 1)
        #expect(includeZeroCountMatchesResult.stdout == Data("0\n".utf8))
        #expect(includeZeroCountMatchesResult.stderr.isEmpty)

        let includeZeroExactLineCountMatchesResult = try runExecutableResult([
            "--include-zero",
            "--count-matches",
            "-x",
            "missing",
            root.path("exact.txt"),
        ])
        #expect(includeZeroExactLineCountMatchesResult.status == 1)
        #expect(includeZeroExactLineCountMatchesResult.stdout == Data("0\n".utf8))
        #expect(includeZeroExactLineCountMatchesResult.stderr.isEmpty)

        let includeZeroWordCountMatchesResult = try runExecutableResult([
            "--include-zero",
            "--count-matches",
            "-w",
            "missing",
            root.path("dense.txt"),
        ])
        #expect(includeZeroWordCountMatchesResult.status == 1)
        #expect(includeZeroWordCountMatchesResult.stdout == Data("0\n".utf8))
        #expect(includeZeroWordCountMatchesResult.stderr.isEmpty)

        let includeZeroRepeatedRegexpCountMatchesResult = try runExecutableResult([
            "--include-zero",
            "--count-matches",
            "-e",
            "missing",
            "-e",
            "absent",
            root.path("dense.txt"),
        ])
        #expect(includeZeroRepeatedRegexpCountMatchesResult.status == 1)
        #expect(includeZeroRepeatedRegexpCountMatchesResult.stdout == Data("0\n".utf8))
        #expect(includeZeroRepeatedRegexpCountMatchesResult.stderr.isEmpty)

        let quietCountMatchesResult = try runExecutableResult([
            "-q",
            "--count-matches",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(quietCountMatchesResult.status == 0)
        #expect(quietCountMatchesResult.stdout.isEmpty)
        #expect(quietCountMatchesResult.stderr.isEmpty)

        for (exactLineArguments, expectedOutput) in [
            (["-x", "needle", root.path("exact.txt")], Data("needle\nneedle\n".utf8)),
            (["--with-filename", "-x", "needle", root.path("exact.txt")], Data("\(root.path("exact.txt")):needle\n\(root.path("exact.txt")):needle\n".utf8)),
            (["-n", "-x", "needle", root.path("exact.txt")], Data("1:needle\n3:needle\n".utf8)),
            (["--with-filename", "-n", "-x", "needle", root.path("exact.txt")], Data("\(root.path("exact.txt")):1:needle\n\(root.path("exact.txt")):3:needle\n".utf8)),
            (["-nx", "needle", root.path("exact.txt")], Data("1:needle\n3:needle\n".utf8)),
            (["-m1", "-x", "needle", root.path("exact.txt")], Data("needle\n".utf8)),
            (["--heading", "-x", "needle", root.path("exact.txt")], Data("needle\nneedle\n".utf8)),
            (["--heading", "--with-filename", "-x", "needle", root.path("exact.txt")], Data("\(root.path("exact.txt"))\nneedle\nneedle\n".utf8)),
            (["-x", "last", root.path("exact.txt")], Data("last\n".utf8)),
            (["-x", "needle|last", root.path("exact.txt")], Data("needle\nneedle\nlast\n".utf8)),
            (["-n", "-x", "needle|last", root.path("exact.txt")], Data("1:needle\n3:needle\n5:last\n".utf8)),
            (["-m2", "-x", "needle|last", root.path("exact.txt")], Data("needle\nneedle\n".utf8)),
            (["--with-filename", "-x", "-e", "needle", "-e", "last", root.path("exact.txt")], Data("\(root.path("exact.txt")):needle\n\(root.path("exact.txt")):needle\n\(root.path("exact.txt")):last\n".utf8)),
            (["--heading", "--with-filename", "-x", "-f", root.path("exact-patterns.txt"), root.path("exact.txt")], Data("\(root.path("exact.txt"))\nneedle\nneedle\nlast\n".utf8)),
            (["--crlf", "-x", "needle", root.path("crlf.txt")], Data("needle\r\n".utf8)),
        ] {
            let exactLineOutput = try runExecutableData(exactLineArguments, fixture: {})
            #expect(exactLineOutput == expectedOutput)
        }
        let exactLineNoMatch = try runExecutableResult([
            "-x",
            "missing",
            root.path("exact.txt"),
        ])
        #expect(exactLineNoMatch.stdout.isEmpty)
        #expect(exactLineNoMatch.stderr.isEmpty)
        #expect(exactLineNoMatch.status == 1)

        let exactLinePrefixedCountOutput = try runExecutableData([
            "-H",
            "-c",
            "-x",
            "needle",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLinePrefixedCountOutput == Data("\(root.path("exact.txt")):2\n".utf8))

        let exactLineNullPrefixedCountOutput = try runExecutableData([
            "-H",
            "--null",
            "-c",
            "-x",
            "needle",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLineNullPrefixedCountOutput == Data((
            "\(root.path("exact.txt"))\0" +
            "2\n"
        ).utf8))

        let exactLinePrefixedMaxCountOutput = try runExecutableData([
            "-H",
            "-c",
            "-m1",
            "-x",
            "needle",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLinePrefixedMaxCountOutput == Data("\(root.path("exact.txt")):1\n".utf8))

        let exactLinePrefixedCaseInsensitiveMaxCountOutput = try runExecutableData([
            "-H",
            "-c",
            "-m1",
            "-i",
            "-x",
            "NEEDLE",
            root.path("exact.txt"),
        ], fixture: {})
        #expect(exactLinePrefixedCaseInsensitiveMaxCountOutput == Data("\(root.path("exact.txt")):1\n".utf8))

        let exactLinePrefixedIncludeZeroResult = try runExecutableResult([
            "--include-zero",
            "-H",
            "-c",
            "-x",
            "missing",
            root.path("exact.txt"),
        ])
        #expect(exactLinePrefixedIncludeZeroResult.status == 1)
        #expect(exactLinePrefixedIncludeZeroResult.stdout == Data("\(root.path("exact.txt")):0\n".utf8))
        #expect(exactLinePrefixedIncludeZeroResult.stderr.isEmpty)

        for (includeZeroArguments, expectedOutput) in [
            (["--include-zero"], output),
            (["--include-zero", "-n"], lineNumberOutput),
            (["--include-zero", "--no-include-zero"], output),
        ] {
            let includeZeroOutput = try runExecutableData(
                includeZeroArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(includeZeroOutput == expectedOutput)
        }

        for (unrestrictedArguments, expectedOutput) in [
            (["-u"], output),
            (["-uu"], output),
            (["-uuu"], output),
            (["--unrestricted"], output),
            (["-u", "-n"], lineNumberOutput),
            (["-un"], lineNumberOutput),
            (["-nuu"], lineNumberOutput),
            (["-u", "-uun"], lineNumberOutput),
            (["-uuuF"], output),
            (["--unrestricted", "--unrestricted", "--unrestricted", "-n"], lineNumberOutput),
        ] {
            let unrestrictedOutput = try runExecutableData(
                unrestrictedArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(unrestrictedOutput == expectedOutput)
        }

        for (nullPathArguments, expectedOutput) in [
            (["--null"], output),
            (["-0"], output),
            (["--null", "-n"], lineNumberOutput),
            (["-0", "-n"], lineNumberOutput),
            (["-n", "-0"], lineNumberOutput),
            (["-0n"], lineNumberOutput),
            (["-n0"], lineNumberOutput),
        ] {
            let nullPathOutput = try runExecutableData(
                nullPathArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(nullPathOutput == expectedOutput)
        }

        let clusteredNullPathOnlyOutput = try runExecutableData([
            "-0l",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredNullPathOnlyOutput == Data("\(root.path("dense.txt"))\0".utf8))

        let clusteredNullPrefixedCountOutput = try runExecutableData([
            "-0Hc",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredNullPrefixedCountOutput == Data(("\(root.path("dense.txt"))\0" + "3\n").utf8))

        let clusteredNullQuietResult = try runExecutableResult([
            "-0q",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(clusteredNullQuietResult.status == 0)
        #expect(clusteredNullQuietResult.stdout.isEmpty)
        #expect(clusteredNullQuietResult.stderr.isEmpty)

        let nullPathBinaryFallbackOutput = try runExecutableData([
            "--null",
            "needle",
            root.path("binary-mode.dat"),
        ], fixture: {})
        #expect(nullPathBinaryFallbackOutput == Data("""
        binary file matches (found "\\0" byte around offset 3)

        """.utf8))

        let clusteredNullBinaryFallbackOutput = try runExecutableData([
            "-0n",
            "needle",
            root.path("binary-mode.dat"),
        ], fixture: {})
        #expect(clusteredNullBinaryFallbackOutput == nullPathBinaryFallbackOutput)

        let countBinaryFallbackOutput = try runExecutableData([
            "-c",
            "needle",
            root.path("binary-mode.dat"),
        ], fixture: {})
        #expect(countBinaryFallbackOutput == Data("1\n".utf8))

        let countMatchesBinaryOutput = try runExecutableData([
            "--count-matches",
            "needle",
            root.path("binary-mode.dat"),
        ], fixture: {})
        #expect(countMatchesBinaryOutput == Data("1\n".utf8))

        let unrestrictedBinaryFallbackOutput = try runExecutableData([
            "-uuu",
            "needle",
            root.path("binary-mode.dat"),
        ], fixture: {})
        #expect(unrestrictedBinaryFallbackOutput == nullPathBinaryFallbackOutput)

        for (binaryModeArguments, expectedOutput) in [
            (["--text"], output),
            (["-a"], output),
            (["--binary"], output),
            (["--text", "-n"], lineNumberOutput),
            (["--binary", "-n"], lineNumberOutput),
            (["-an"], lineNumberOutput),
            (["-na"], lineNumberOutput),
        ] {
            let binaryModeOutput = try runExecutableData(
                binaryModeArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(binaryModeOutput == expectedOutput)
        }

        let textBinaryFallbackOutput = try runExecutableData([
            "--text",
            "needle",
            root.path("binary-mode.dat"),
        ], fixture: {})
        #expect(textBinaryFallbackOutput == Data("pre\0needle\n".utf8))

        for (multilineArguments, expectedOutput) in [
            (["-U"], output),
            (["--multiline"], output),
            (["--multiline-dotall"], output),
            (["-Un"], lineNumberOutput),
            (["-nU"], lineNumberOutput),
            (["-U", "--multiline-dotall"], output),
            (["--multiline", "--multiline-dotall", "-n"], lineNumberOutput),
            (["--stop-on-nonmatch", "-U"], output),
            (["--stop-on-nonmatch", "--multiline"], output),
            (["--stop-on-nonmatch", "-U", "--no-multiline"], output),
        ] {
            let multilineOutput = try runExecutableData(
                multilineArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(multilineOutput == expectedOutput)
        }

        let activeStopOnNonmatchOutput = try runExecutableData([
            "-U",
            "--stop-on-nonmatch",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(activeStopOnNonmatchOutput == Data("needle needle needle\n".utf8))

        let stopOnNonmatchOutput = try runExecutableData([
            "--stop-on-nonmatch",
            "needle",
            root.path("stop-run.txt"),
        ], fixture: {})
        #expect(stopOnNonmatchOutput == Data("needle one\nneedle two\nneedle three\n".utf8))

        let stopOnNonmatchLineNumberMaxOutput = try runExecutableData([
            "-n",
            "--stop-on-nonmatch",
            "-m2",
            "needle",
            root.path("stop-run.txt"),
        ], fixture: {})
        #expect(stopOnNonmatchLineNumberMaxOutput == Data("2:needle one\n3:needle two\n".utf8))

        let stopOnNonmatchNoMatch = try runExecutableResult([
            "--stop-on-nonmatch",
            "missing",
            root.path("stop-run.txt"),
        ])
        #expect(stopOnNonmatchNoMatch.stdout.isEmpty)
        #expect(stopOnNonmatchNoMatch.stderr.isEmpty)
        #expect(stopOnNonmatchNoMatch.status == 1)

        let stopOnNonmatchCountOutput = try runExecutableData([
            "-c",
            "--stop-on-nonmatch",
            "needle",
            root.path("stop-run.txt"),
        ], fixture: {})
        #expect(stopOnNonmatchCountOutput == Data("3\n".utf8))

        let stopOnNonmatchAfterContextCountOutput = try runExecutableData([
            "-c",
            "--stop-on-nonmatch",
            "--after-context=1",
            "needle",
            root.path("stop-run.txt"),
        ], fixture: {})
        #expect(stopOnNonmatchAfterContextCountOutput == stopOnNonmatchCountOutput)

        let stopOnNonmatchMaxCountOutput = try runExecutableData([
            "-c",
            "--stop-on-nonmatch",
            "-m2",
            "needle",
            root.path("stop-run.txt"),
        ], fixture: {})
        #expect(stopOnNonmatchMaxCountOutput == Data("2\n".utf8))

        let stopOnNonmatchContextMaxCountOutput = try runExecutableData([
            "-c",
            "--stop-on-nonmatch",
            "--context=1",
            "-m2",
            "needle",
            root.path("stop-run.txt"),
        ], fixture: {})
        #expect(stopOnNonmatchContextMaxCountOutput == stopOnNonmatchMaxCountOutput)

        let stopOnNonmatchPrefixedCountOutput = try runExecutableData([
            "-H",
            "-c",
            "--stop-on-nonmatch",
            "needle",
            root.path("stop-run.txt"),
        ], fixture: {})
        #expect(stopOnNonmatchPrefixedCountOutput == Data("\(root.path("stop-run.txt")):3\n".utf8))

        let stopOnNonmatchIncludeZero = try runExecutableResult([
            "--include-zero",
            "-c",
            "--stop-on-nonmatch",
            "missing",
            root.path("stop-run.txt"),
        ])
        #expect(stopOnNonmatchIncludeZero.stdout == Data("0\n".utf8))
        #expect(stopOnNonmatchIncludeZero.stderr.isEmpty)
        #expect(stopOnNonmatchIncludeZero.status == 1)

        let messagesOutput = try runExecutableData([
            "--messages",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(messagesOutput == output)

        let noLineBufferedOutput = try runExecutableData([
            "--no-line-buffered",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noLineBufferedOutput == output)

        let orderedNoLineBufferedOutput = try runExecutableData([
            "--line-buffered",
            "--no-line-buffered",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedNoLineBufferedOutput == output)

        let blockBufferedOutput = try runExecutableData([
            "--block-buffered",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(blockBufferedOutput == output)

        let orderedBlockBufferedOutput = try runExecutableData([
            "--line-buffered",
            "--block-buffered",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedBlockBufferedOutput == output)

        let noColumnOutput = try runExecutableData([
            "--no-column",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noColumnOutput == output)

        let noByteOffsetOutput = try runExecutableData([
            "--no-byte-offset",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noByteOffsetOutput == output)

        let noTrimOutput = try runExecutableData([
            "--no-trim",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noTrimOutput == output)

        let colorNeverOutput = try runExecutableData([
            "--color=never",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(colorNeverOutput == output)

        let separateColorNeverOutput = try runExecutableData([
            "--color",
            "never",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(separateColorNeverOutput == output)

        let colorsResetOutput = try runExecutableData([
            "--colors",
            "match:fg:red",
            "--color=never",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(colorsResetOutput == output)

        let inlineColorsResetOutput = try runExecutableData([
            "--colors=match:none",
            "--color=never",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(inlineColorsResetOutput == output)

        let invalidColorsOutput = try runExecutableResult([
            "--colors",
            "bogus",
            "--color=never",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(invalidColorsOutput.stdout.isEmpty)
        let expectedInvalidColorsError = "rg: error parsing flag --colors: invalid color spec format: 'bogus'. "
            + "Valid format is '(path|line|column|match|highlight):(fg|bg|style):(value)'.\n"
        #expect(
            invalidColorsOutput.stderr
                == Data(expectedInvalidColorsError.utf8)
        )
        #expect(invalidColorsOutput.status == 2)

        let orderedNoColumnOutput = try runExecutableData([
            "--column",
            "--no-column",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedNoColumnOutput == output)

        let orderedNoByteOffsetOutput = try runExecutableData([
            "--byte-offset",
            "--no-byte-offset",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedNoByteOffsetOutput == output)

        let orderedNoTrimOutput = try runExecutableData([
            "--trim",
            "--no-trim",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedNoTrimOutput == output)

        let orderedNoFilenameOutput = try runExecutableData([
            "--with-filename",
            "--no-filename",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedNoFilenameOutput == output)

        let shortNoFilenameOutput = try runExecutableData([
            "-I",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(shortNoFilenameOutput == output)

        let orderedNoHeadingOutput = try runExecutableData([
            "--heading",
            "--no-heading",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedNoHeadingOutput == output)

        let orderedColorNeverOutput = try runExecutableData([
            "--color=always",
            "--color=never",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedColorNeverOutput == output)

        for prettyResetArguments in [
            ["--pretty", "--color=never", "--no-heading", "-N"],
            ["-p", "--color", "never", "--no-heading", "--no-line-number"],
            ["--pretty", "--colors", "match:fg:red", "--color=never", "--no-heading", "-N"],
        ] {
            let prettyResetOutput = try runExecutableData(
                prettyResetArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(prettyResetOutput == output)
        }

        for (engineArguments, expectedOutput) in [
            (["-n", "-P"], lineNumberOutput),
            (["-Pn"], lineNumberOutput),
            (["-n", "--pcre2"], lineNumberOutput),
            (["--no-pcre2", "-P"], output),
            (["-P", "--no-pcre2"], output),
            (["-n", "--engine", "pcre2"], lineNumberOutput),
            (["-n", "--engine=auto"], lineNumberOutput),
            (["-n", "--auto-hybrid-regex"], lineNumberOutput),
            (["-n", "--no-auto-hybrid-regex"], lineNumberOutput),
        ] {
            let engineOutput = try runExecutableData(
                engineArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(engineOutput == expectedOutput)
        }

        let pcreQuotedEngineOutput = try runExecutableData([
            "-n",
            "-P",
            #"\Qneedle\E"#,
            root.path("dense.txt"),
        ], fixture: {})
        #expect(pcreQuotedEngineOutput == lineNumberOutput)

        for (followArguments, expectedOutput) in [
            (["--follow"], output),
            (["--no-follow"], output),
            (["-L"], output),
            (["-Ln"], lineNumberOutput),
            (["-nL"], lineNumberOutput),
        ] {
            let followOutput = try runExecutableData(
                followArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(followOutput == expectedOutput)
        }

        let symlinkFollowOutput = try runExecutableData([
            "--no-follow",
            "needle",
            root.path("dense-link.txt"),
        ], fixture: {})
        #expect(symlinkFollowOutput == output)

        for (metadataArguments, expectedOutput) in [
            (["--hyperlink-format=grep+"], output),
            (["--hyperlink-format", "vscode"], output),
            (["--hyperlink-format="], output),
            (["--hyperlink-format=none", "-n"], lineNumberOutput),
            (["--pre="], output),
            (["--pre", ""], output),
            (["--no-pre"], output),
        ] {
            let metadataOutput = try runExecutableData(
                metadataArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(metadataOutput == expectedOutput)
        }

        for preGlobArguments in [
            ["--pre-glob", "*.pdf"],
            ["--pre-glob=*.txt"],
            ["--pre-glob", "*.pdf", "--pre", ""],
        ] {
            let preGlobOutput = try runExecutableData(
                preGlobArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(preGlobOutput == output)
        }

        for (globArguments, expectedOutput) in [
            (["-g", "*.nomatch"], output),
            (["--glob=*.txt", "-n"], lineNumberOutput),
            (["-g!*.txt"], output),
            (["--iglob", "*.NOMATCH"], output),
            (["--iglob=*.TXT", "-n"], lineNumberOutput),
        ] {
            let globOutput = try runExecutableData(
                globArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(globOutput == expectedOutput)
        }

        for (typeDefinitionArguments, expectedOutput) in [
            (["--type-add", "foo:*.foo"], output),
            (["--type-add=foo:*.foo", "-n"], lineNumberOutput),
            (["--type-clear", "rust"], output),
            (["--type-clear=rust"], output),
            (["--type-add", "wat:*.wat", "--type-add", "combo:include:wat,py"], output),
            (["-t", "rust"], output),
            (["--type=rust", "-n"], lineNumberOutput),
            (["-trust"], output),
            (["-T", "rust"], output),
            (["--type-not=rust"], output),
            (["-Trust", "-n"], lineNumberOutput),
            (["--type-add", "foo:*.foo", "-t", "foo"], output),
        ] {
            let typeDefinitionOutput = try runExecutableData(
                typeDefinitionArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(typeDefinitionOutput == expectedOutput)
        }

        let invalidTypeFilterOutput = try runExecutableResult([
            "-t",
            "missingtype",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(invalidTypeFilterOutput.stdout.isEmpty)
        #expect(invalidTypeFilterOutput.stderr == Data("rg: unrecognized file type: missingtype\n".utf8))
        #expect(invalidTypeFilterOutput.status == 2)

        let noUnicodeOutput = try runExecutableData([
            "--no-unicode",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noUnicodeOutput == output)

        let orderedUnicodeOutput = try runExecutableData([
            "--no-unicode",
            "--unicode",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedUnicodeOutput == output)

        let noPCRE2UnicodeOutput = try runExecutableData([
            "--no-pcre2-unicode",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noPCRE2UnicodeOutput == output)

        let crlfOutput = try runExecutableData([
            "--crlf",
            "needle",
            root.path("crlf.txt"),
        ], fixture: {})
        #expect(crlfOutput == Data("needle\r\n".utf8))

        let noCrlfOutput = try runExecutableData([
            "--crlf",
            "--no-crlf",
            "needle",
            root.path("crlf.txt"),
        ], fixture: {})
        #expect(noCrlfOutput == crlfOutput)

        for neutralResetFlag in [
            "--glob-case-insensitive",
            "--no-block-buffered",
            "--no-binary",
            "--no-context-separator",
            "--no-encoding",
            "--no-glob-case-insensitive",
            "--no-include-zero",
            "--no-invert-match",
            "--no-json",
            "--no-max-columns-preview",
            "--no-multiline",
            "--no-multiline-dotall",
            "--no-search-zip",
            "--no-sort-files",
            "--no-stats",
            "--no-text",
            "--max-columns-preview",
            "--sort-files",
        ] {
            let neutralResetOutput = try runExecutableData([
                neutralResetFlag,
                "needle",
                root.path("dense.txt"),
            ], fixture: {})
            #expect(neutralResetOutput == output)
        }

        for orderedResetArguments in [
            ["--invert-match", "--no-invert-match"],
            ["-v", "--no-invert-match"],
            ["--json", "--no-json"],
            ["--stats", "--no-stats"],
            ["--search-zip", "--no-search-zip"],
            ["-z", "--no-search-zip"],
        ] {
            let orderedResetOutput = try runExecutableData(
                orderedResetArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(orderedResetOutput == output)
        }

        let clusteredInvertResetOutput = try runExecutableData([
            "-vn",
            "--no-invert-match",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredInvertResetOutput == lineNumberOutput)

        let inlineSortNoneOutput = try runExecutableData([
            "--sort=none",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(inlineSortNoneOutput == output)

        let separateSortNoneOutput = try runExecutableData([
            "--sort",
            "none",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(separateSortNoneOutput == output)

        let reverseSortNoneOutput = try runExecutableData([
            "--sortr=none",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(reverseSortNoneOutput == output)

        for sortArguments in [
            ["--sort=path"],
            ["--sort", "modified"],
            ["--sortr=accessed"],
            ["--sortr", "created"],
        ] {
            let sortOutput = try runExecutableData(
                sortArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(sortOutput == output)
        }

        let threadCountOutput = try runExecutableData([
            "--threads=1",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(threadCountOutput == output)

        let shortThreadCountOutput = try runExecutableData([
            "-j1",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(shortThreadCountOutput == output)

        let dfaSizeLimitOutput = try runExecutableData([
            "--dfa-size-limit=10M",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(dfaSizeLimitOutput == output)

        let regexSizeLimitOutput = try runExecutableData([
            "--regex-size-limit",
            "10M",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(regexSizeLimitOutput == output)

        for encodingAutoArguments in [
            ["--encoding=auto"],
            ["--encoding", "auto"],
            ["-Eauto"],
            ["-E", "auto"],
        ] {
            let encodingAutoOutput = try runExecutableData(
                encodingAutoArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(encodingAutoOutput == output)
        }

        for orderedEncodingResetArguments in [
            ["--encoding=utf-8", "--no-encoding"],
            ["--encoding", "utf-8", "--no-encoding"],
            ["-Eutf-8", "--no-encoding"],
            ["-E", "utf-8", "--no-encoding"],
            ["--encoding=latin1", "--no-encoding"],
            ["--encoding", "none", "--no-encoding"],
        ] {
            let orderedEncodingResetOutput = try runExecutableData(
                orderedEncodingResetArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(orderedEncodingResetOutput == output)
        }

        let invalidEncodingResetOutput = try runExecutableResult([
            "--encoding",
            "bogus",
            "--no-encoding",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(invalidEncodingResetOutput.stdout.isEmpty)
        #expect(
            invalidEncodingResetOutput.stderr
                == Data("rg: error parsing flag --encoding: grep config error: unknown encoding: bogus\n".utf8)
        )
        #expect(invalidEncodingResetOutput.status == 2)

        for maxFilesizeArguments in [
            ["--max-filesize=1"],
            ["--max-filesize", "1"],
            ["--max-filesize=1K"],
            ["--max-filesize", "1K"],
        ] {
            let maxFilesizeOutput = try runExecutableData(
                maxFilesizeArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(maxFilesizeOutput == output)
        }

        for zeroValueArguments in [
            ["--max-columns=0"],
            ["--max-columns", "0"],
            ["-M0"],
            ["--max-depth=0"],
            ["--maxdepth=0"],
            ["--max-depth", "0"],
            ["-d0"],
            ["--after-context=0"],
            ["--before-context=0"],
            ["--context=0"],
            ["-A0"],
            ["-B0"],
            ["-C0"],
        ] {
            let zeroValueOutput = try runExecutableData(
                zeroValueArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(zeroValueOutput == output)
        }

        for orderedZeroValueArguments in [
            ["--max-columns=100", "--max-columns=0"],
            ["--max-columns", "100", "--max-columns", "0"],
            ["-M100", "-M0"],
            ["--max-depth=1", "--max-depth=0"],
            ["--maxdepth=1", "--maxdepth=0"],
            ["--max-depth", "1", "--max-depth", "0"],
            ["-d1", "-d0"],
            ["--passthru", "--context=0"],
            ["--passthrough", "--after-context=0"],
            ["--context=1", "--context=0"],
            ["--after-context=1", "--context=0", "--after-context=0"],
            ["--before-context=1", "--context=0", "--before-context=0"],
            ["-C1", "-C0"],
            ["-A1", "-C0", "-A0"],
            ["-B1", "-C0", "-B0"],
        ] {
            let orderedZeroValueOutput = try runExecutableData(
                orderedZeroValueArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(orderedZeroValueOutput == output)
        }

        for maxDepthArguments in [
            ["--max-depth=1"],
            ["--maxdepth=2"],
            ["--max-depth", "1"],
            ["-d1"],
            ["--max-depth=1", "--max-depth=2"],
        ] {
            let maxDepthOutput = try runExecutableData(
                maxDepthArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(maxDepthOutput == output)
        }

        let maxDepthLineNumberOutput = try runExecutableData([
            "--maxdepth=2",
            "-n",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(maxDepthLineNumberOutput == lineNumberOutput)

        let maxDepthPathOnlyOutput = try runExecutableData([
            "-d1",
            "-l",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(maxDepthPathOnlyOutput == Data("\(root.path("dense.txt"))\n".utf8))

        for neutralValueArguments in [
            ["--field-match-separator=|"],
            ["--field-match-separator", "|"],
            ["--field-context-separator=|"],
            ["--field-context-separator", "|"],
            ["--context-separator=SEP"],
            ["--context-separator", "SEP"],
            ["--path-separator=/"],
            ["--path-separator", "/"],
            ["--hostname-bin=hostname"],
            ["--hostname-bin", "hostname"],
        ] {
            let neutralValueOutput = try runExecutableData(
                neutralValueArguments + [
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(neutralValueOutput == output)
        }

        let fieldSeparatorLineNumberOutput = try runExecutableData([
            "--field-match-separator=|",
            "-n",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(fieldSeparatorLineNumberOutput == Data("""
        1|needle needle needle
        3|NEEDLE needle Needle
        4|tail needle

        """.utf8))

        for (fieldSeparatorArguments, expectedOutput) in [
            (
                ["--field-match-separator", "|"],
                Data("""
                1|needle needle needle
                3|NEEDLE needle Needle
                4|tail needle

                """.utf8)
            ),
            (
                ["--field-match-separator=\\t"],
                Data("""
                1\tneedle needle needle
                3\tNEEDLE needle Needle
                4\ttail needle

                """.utf8)
            ),
            (
                ["--field-match-separator="],
                Data("""
                1needle needle needle
                3NEEDLE needle Needle
                4tail needle

                """.utf8)
            ),
            (
                ["--field-match-separator=\\x7c"],
                Data("""
                1|needle needle needle
                3|NEEDLE needle Needle
                4|tail needle

                """.utf8)
            ),
            (
                ["--with-filename", "--field-match-separator=|"],
                Data("""
                \(root.path("dense.txt"))|1|needle needle needle
                \(root.path("dense.txt"))|3|NEEDLE needle Needle
                \(root.path("dense.txt"))|4|tail needle

                """.utf8)
            ),
        ] {
            let customFieldSeparatorOutput = try runExecutableData(
                fieldSeparatorArguments + [
                    "-n",
                    "needle",
                    root.path("dense.txt"),
                ],
                fixture: {}
            )
            #expect(customFieldSeparatorOutput == expectedOutput)
        }

        let hiddenFlagOutput = try runExecutableData([
            "--hidden",
            "--no-ignore",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(hiddenFlagOutput == output)

        let noHiddenExplicitFileOutput = try runExecutableData([
            "--no-hidden",
            "needle",
            root.path(".hidden.txt"),
        ], fixture: {})
        #expect(noHiddenExplicitFileOutput == Data("needle\n".utf8))

        let shortHiddenExplicitFileOutput = try runExecutableData([
            "-.",
            "needle",
            root.path(".hidden.txt"),
        ], fixture: {})
        #expect(shortHiddenExplicitFileOutput == noHiddenExplicitFileOutput)

        let clusteredHiddenLineNumberOutput = try runExecutableData([
            "-.n",
            "needle",
            root.path(".hidden.txt"),
        ], fixture: {})
        #expect(clusteredHiddenLineNumberOutput == Data("1:needle\n".utf8))

        let clusteredHiddenCountOutput = try runExecutableData([
            "-.c",
            "needle",
            root.path(".hidden.txt"),
        ], fixture: {})
        #expect(clusteredHiddenCountOutput == Data("1\n".utf8))

        let clusteredHiddenPathOnlyOutput = try runExecutableData([
            "-.l",
            "needle",
            root.path(".hidden.txt"),
        ], fixture: {})
        #expect(clusteredHiddenPathOnlyOutput == Data("\(root.path(".hidden.txt"))\n".utf8))

        let clusteredHiddenPrefixedCountOutput = try runExecutableData([
            "-.Hc",
            "needle",
            root.path(".hidden.txt"),
        ], fixture: {})
        #expect(clusteredHiddenPrefixedCountOutput == Data("\(root.path(".hidden.txt")):1\n".utf8))

        let clusteredHiddenQuietResult = try runExecutableResult([
            "-.q",
            "needle",
            root.path(".hidden.txt"),
        ])
        #expect(clusteredHiddenQuietResult.status == 0)
        #expect(clusteredHiddenQuietResult.stdout.isEmpty)
        #expect(clusteredHiddenQuietResult.stderr.isEmpty)

        let clusteredHiddenBinaryFallbackOutput = try runExecutableData([
            "-.n",
            "needle",
            root.path("binary-mode.dat"),
        ], fixture: {})
        #expect(clusteredHiddenBinaryFallbackOutput == Data("""
        binary file matches (found "\\0" byte around offset 3)

        """.utf8))

        let ignoreExplicitFileOutput = try runExecutableData([
            "--ignore",
            "needle",
            root.path("ignored.txt"),
        ], fixture: {})
        #expect(ignoreExplicitFileOutput == Data("needle\n".utf8))

        let noIgnoreExplicitFileOutput = try runExecutableData([
            "--no-ignore",
            "needle",
            root.path("ignored.txt"),
        ], fixture: {})
        #expect(noIgnoreExplicitFileOutput == ignoreExplicitFileOutput)

        let ignoreFileExplicitFileOutput = try runExecutableData([
            "--ignore-file",
            root.path(".ignore"),
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(ignoreFileExplicitFileOutput == output)

        let inlineIgnoreFileExplicitFileOutput = try runExecutableData([
            "--ignore-file=\(root.path(".ignore"))",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(inlineIgnoreFileExplicitFileOutput == output)

        let ignoreFileCaseInsensitiveOutput = try runExecutableData([
            "--ignore-file-case-insensitive",
            "--ignore-files",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(ignoreFileCaseInsensitiveOutput == output)

        let disabledMissingIgnoreFileOutput = try runExecutableResult([
            "--ignore-file",
            root.path("missing-ignore"),
            "--no-ignore-files",
            "needle",
            root.path("dense.txt"),
        ])
        #expect(disabledMissingIgnoreFileOutput.stdout == output)
        #expect(disabledMissingIgnoreFileOutput.stderr.isEmpty)
        #expect(disabledMissingIgnoreFileOutput.status == 0)

        let missingIgnoreFileOutput = try runExecutableResult([
            "--ignore-file",
            root.path("missing-ignore"),
            "needle",
            root.path("dense.txt"),
        ])
        #expect(missingIgnoreFileOutput.stdout == output)
        #expect(missingIgnoreFileOutput.status == 0)

        let neutralFormattingOutput = try runExecutableData([
            "--no-byte-offset",
            "--no-column",
            "--no-heading",
            "--no-filename",
            "--no-trim",
            "--color=never",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(neutralFormattingOutput == output)

        let neutralRuntimeOutput = try runExecutableData([
            "--block-buffered",
            "--messages",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(neutralRuntimeOutput == output)

        let orderedCaseSensitiveOutput = try runExecutableData([
            "-i",
            "-s",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedCaseSensitiveOutput == output)

        let clusteredCaseSensitiveOutput = try runExecutableData([
            "-is",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredCaseSensitiveOutput == output)

        let smartCaseSensitiveOutput = try runExecutableData([
            "-S",
            "Needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(smartCaseSensitiveOutput == Data("""
        NEEDLE needle Needle

        """.utf8))

        let longSmartCaseIgnoreCaseOutput = try runExecutableData([
            "--smart-case",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(longSmartCaseIgnoreCaseOutput == ignoreCaseOutput)

        let regexpOutput = try runExecutableData([
            "-e",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(regexpOutput == output)

        let longRegexpOutput = try runExecutableData([
            "--regexp",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(longRegexpOutput == output)

        let inlineLongRegexpOutput = try runExecutableData([
            "--regexp=needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(inlineLongRegexpOutput == output)

        let inlineShortRegexpOutput = try runExecutableData([
            "-eneedle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(inlineShortRegexpOutput == output)

        let noConfigRegexpOutput = try runExecutableData([
            "--no-config",
            "-e",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noConfigRegexpOutput == output)

        let noConfigEnvironmentRegexpOutput = try runExecutableData([
            "--no-config",
            "-e",
            "needle",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(noConfigEnvironmentRegexpOutput == output)

        let neutralLeadingNoConfigEnvironmentOutput = try runExecutableData([
            "--line-buffered",
            "--no-config",
            "-e",
            "needle",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(neutralLeadingNoConfigEnvironmentOutput == output)

        let deferredNoConfigVimgrepOutput = try runExecutableData([
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        let leadingNoConfigVimgrepOutput = try runExecutableData([
            "--no-config",
            "--heading",
            "--vimgrep",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredInlineNoConfigVimgrepOutput = try runExecutableData([
            "--sort=path",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlineNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredSeparatedNoConfigVimgrepOutput = try runExecutableData([
            "--sort",
            "path",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredSeparatedNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredPatternNoConfigVimgrepOutput = try runExecutableData([
            "-e",
            "needle",
            "--no-config",
            "--vimgrep",
            "--heading",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredPatternNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredInlinePatternNoConfigVimgrepOutput = try runExecutableData([
            "--regexp=needle",
            "--no-config",
            "--vimgrep",
            "--heading",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlinePatternNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredColorNoConfigVimgrepOutput = try runExecutableData([
            "--color",
            "never",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredColorNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredInlineColorNoConfigVimgrepOutput = try runExecutableData([
            "--color=never",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlineColorNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredColorsNoConfigVimgrepOutput = try runExecutableData([
            "--colors",
            "path:fg:red",
            "--color",
            "never",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredColorsNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredHyperlinkNoConfigVimgrepOutput = try runExecutableData([
            "--hyperlink-format",
            "grep+",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredHyperlinkNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredInlineHyperlinkNoConfigVimgrepOutput = try runExecutableData([
            "--hyperlink-format=grep+",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlineHyperlinkNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredPreNoConfigVimgrepOutput = try runExecutableData([
            "--pre",
            "",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredPreNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredInlinePreNoConfigVimgrepOutput = try runExecutableData([
            "--pre=",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlinePreNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredGlobNoConfigVimgrepOutput = try runExecutableData([
            "--glob",
            "*.pdf",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredGlobNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredInlineGlobNoConfigVimgrepOutput = try runExecutableData([
            "--glob=*.pdf",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlineGlobNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredMaxDepthNoConfigVimgrepOutput = try runExecutableData([
            "--max-depth",
            "1",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredMaxDepthNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredInlineMaxDepthNoConfigVimgrepOutput = try runExecutableData([
            "--max-depth=1",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlineMaxDepthNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let leadingFieldSeparatorNoConfigVimgrepOutput = try runExecutableData([
            "--no-config",
            "--field-match-separator",
            "|",
            "--vimgrep",
            "--heading",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        let deferredFieldSeparatorNoConfigVimgrepOutput = try runExecutableData([
            "--field-match-separator",
            "|",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredFieldSeparatorNoConfigVimgrepOutput == leadingFieldSeparatorNoConfigVimgrepOutput)

        let deferredInlineFieldSeparatorNoConfigVimgrepOutput = try runExecutableData([
            "--field-match-separator=|",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlineFieldSeparatorNoConfigVimgrepOutput == leadingFieldSeparatorNoConfigVimgrepOutput)

        let deferredHostnameNoConfigVimgrepOutput = try runExecutableData([
            "--hostname-bin",
            "hostname",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredHostnameNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredInlineHostnameNoConfigVimgrepOutput = try runExecutableData([
            "--hostname-bin=hostname",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlineHostnameNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredMaxFilesizeNoConfigVimgrepOutput = try runExecutableData([
            "--max-filesize",
            "1K",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredMaxFilesizeNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredInlineResourceLimitNoConfigVimgrepOutput = try runExecutableData([
            "--dfa-size-limit=10M",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlineResourceLimitNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredEncodingNoConfigVimgrepOutput = try runExecutableData([
            "--encoding",
            "auto",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredEncodingNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredInlineEncodingNoConfigVimgrepOutput = try runExecutableData([
            "-Eauto",
            "--vimgrep",
            "--heading",
            "--no-config",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlineEncodingNoConfigVimgrepOutput == leadingNoConfigVimgrepOutput)

        let deferredInlineMaxCountNoConfigOutput = try runExecutableData([
            "-m1",
            "--no-config",
            "needle",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        let leadingInlineMaxCountNoConfigOutput = try runExecutableData([
            "--no-config",
            "-m1",
            "needle",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredInlineMaxCountNoConfigOutput == leadingInlineMaxCountNoConfigOutput)

        let deferredSeparatedMaxCountNoConfigOutput = try runExecutableData([
            "-m",
            "1",
            "--no-config",
            "needle",
            root.path("dense.txt"),
        ], environment: [
            "RIPGREP_CONFIG_PATH": root.path("ripgreprc"),
        ], fixture: {})
        #expect(deferredSeparatedMaxCountNoConfigOutput == leadingInlineMaxCountNoConfigOutput)

        let regexpLineNumberOutput = try runExecutableData([
            "-e",
            "needle",
            "-n",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(regexpLineNumberOutput == lineNumberOutput)

        let regexpLeadingDashOutput = try runExecutableData([
            "-e",
            "-needle",
            root.path("dash-pattern.txt"),
        ], fixture: {})
        #expect(regexpLeadingDashOutput == Data("-needle\n".utf8))

        let endOfOptionsLeadingDashOutput = try runExecutableData([
            "--",
            "-needle",
            root.path("dash-pattern.txt"),
        ], fixture: {})
        #expect(endOfOptionsLeadingDashOutput == Data("-needle\n".utf8))

        let repeatedRegexpOutput = try runExecutableData([
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpOutput == Data("""
        needle needle needle
        quiet line
        NEEDLE needle Needle
        tail needle

        """.utf8))

        let repeatedRegexpLineNumberOutput = try runExecutableData([
            "-n",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpLineNumberOutput == Data("""
        1:needle needle needle
        2:quiet line
        3:NEEDLE needle Needle
        4:tail needle

        """.utf8))

        let repeatedRegexpFilenameOutput = try runExecutableData([
            "--with-filename",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpFilenameOutput == Data("""
        \(root.path("dense.txt")):needle needle needle
        \(root.path("dense.txt")):quiet line
        \(root.path("dense.txt")):NEEDLE needle Needle
        \(root.path("dense.txt")):tail needle

        """.utf8))

        let repeatedRegexpHeadingOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpHeadingOutput == Data("""
        \(root.path("dense.txt"))
        needle needle needle
        quiet line
        NEEDLE needle Needle
        tail needle

        """.utf8))

        let repeatedRegexpPathOnlyResult = try runExecutableResult([
            "-l",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ])
        #expect(repeatedRegexpPathOnlyResult.status == 0)
        #expect(repeatedRegexpPathOnlyResult.stdout == Data("\(root.path("dense.txt"))\n".utf8))
        #expect(repeatedRegexpPathOnlyResult.stderr.isEmpty)

        let repeatedRegexpWithoutMatchResult = try runExecutableResult([
            "--files-without-match",
            "-e",
            "missing",
            "-e",
            "absent",
            root.path("dense.txt"),
        ])
        #expect(repeatedRegexpWithoutMatchResult.status == 0)
        #expect(repeatedRegexpWithoutMatchResult.stdout == Data("\(root.path("dense.txt"))\n".utf8))
        #expect(repeatedRegexpWithoutMatchResult.stderr.isEmpty)

        let repeatedFixedRegexpOutput = try runExecutableData([
            "-F",
            "-e",
            "needle needle",
            "-e",
            "quiet line",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedFixedRegexpOutput == Data("""
        needle needle needle
        quiet line

        """.utf8))

        let repeatedAlternationRegexpOutput = try runExecutableData([
            "-e",
            "needle|tail",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedAlternationRegexpOutput == repeatedRegexpOutput)

        let repeatedIgnoreCaseRegexpOutput = try runExecutableData([
            "-i",
            "-e",
            "NEEDLE",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedIgnoreCaseRegexpOutput == repeatedRegexpOutput)

        let patternFileOutput = try runExecutableData([
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(patternFileOutput == repeatedRegexpOutput)

        let longPatternFileOutput = try runExecutableData([
            "--file",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(longPatternFileOutput == repeatedRegexpOutput)

        let inlineLongPatternFileOutput = try runExecutableData([
            "--file=\(root.path("patterns.txt"))",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(inlineLongPatternFileOutput == repeatedRegexpOutput)

        let inlineShortPatternFileOutput = try runExecutableData([
            "-f\(root.path("patterns.txt"))",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(inlineShortPatternFileOutput == repeatedRegexpOutput)

        let singlePatternFileOutput = try runExecutableData([
            "-f",
            root.path("one-pattern.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(singlePatternFileOutput == output)

        let patternFileLineNumberOutput = try runExecutableData([
            "-n",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(patternFileLineNumberOutput == repeatedRegexpLineNumberOutput)

        let patternFileHeadingOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(patternFileHeadingOutput == repeatedRegexpHeadingOutput)

        let patternFilePathOnlyResult = try runExecutableResult([
            "-l",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ])
        #expect(patternFilePathOnlyResult.status == 0)
        #expect(patternFilePathOnlyResult.stdout == Data("\(root.path("dense.txt"))\n".utf8))
        #expect(patternFilePathOnlyResult.stderr.isEmpty)

        let patternFileWithoutMatchResult = try runExecutableResult([
            "--files-without-match",
            "-f",
            root.path("missing-patterns.txt"),
            root.path("dense.txt"),
        ])
        #expect(patternFileWithoutMatchResult.status == 0)
        #expect(patternFileWithoutMatchResult.stdout == Data("\(root.path("dense.txt"))\n".utf8))
        #expect(patternFileWithoutMatchResult.stderr.isEmpty)

        let fixedPatternFileOutput = try runExecutableData([
            "-F",
            "-f",
            root.path("fixed-patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(fixedPatternFileOutput == repeatedFixedRegexpOutput)

        let mixedRegexpPatternFileOutput = try runExecutableData([
            "-e",
            "tail",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(mixedRegexpPatternFileOutput == repeatedRegexpOutput)

        let repeatedRegexpMaxCountOutput = try runExecutableData([
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpMaxCountOutput == Data("""
        needle needle needle
        quiet line

        """.utf8))

        let repeatedRegexpLineNumberMaxCountOutput = try runExecutableData([
            "-n",
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpLineNumberMaxCountOutput == Data("""
        1:needle needle needle
        2:quiet line

        """.utf8))

        let repeatedRegexpFilenameMaxCountOutput = try runExecutableData([
            "--with-filename",
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpFilenameMaxCountOutput == Data("""
        \(root.path("dense.txt")):needle needle needle
        \(root.path("dense.txt")):quiet line

        """.utf8))

        let repeatedRegexpHeadingMaxCountOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpHeadingMaxCountOutput == Data("""
        \(root.path("dense.txt"))
        needle needle needle
        quiet line

        """.utf8))

        let patternFileMaxCountOutput = try runExecutableData([
            "-m2",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(patternFileMaxCountOutput == repeatedRegexpMaxCountOutput)

        let patternFileLineNumberMaxCountOutput = try runExecutableData([
            "-n",
            "-m2",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(patternFileLineNumberMaxCountOutput == repeatedRegexpLineNumberMaxCountOutput)

        let alternationMaxCountOutput = try runExecutableData([
            "-m2",
            "needle|quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(alternationMaxCountOutput == repeatedRegexpMaxCountOutput)

        let repeatedRegexpZeroMaxCountOutput = try runExecutableData([
            "-m0",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpZeroMaxCountOutput.isEmpty)

        let repeatedRegexpCountOutput = try runExecutableData([
            "-c",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpCountOutput == Data("4\n".utf8))

        let patternFileCountOutput = try runExecutableData([
            "-c",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(patternFileCountOutput == repeatedRegexpCountOutput)

        let alternationCountOutput = try runExecutableData([
            "-c",
            "needle|quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(alternationCountOutput == repeatedRegexpCountOutput)

        let crlfCountOutput = try runExecutableData([
            "--crlf",
            "-c",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(crlfCountOutput == Data("4\r\n".utf8))

        let includeZeroCountResult = try runExecutableResult([
            "--include-zero",
            "-c",
            "-e",
            "missing",
            "-e",
            "absent",
            root.path("dense.txt"),
        ])
        #expect(includeZeroCountResult.status == 1)
        #expect(includeZeroCountResult.stdout == Data("0\n".utf8))
        #expect(includeZeroCountResult.stderr.isEmpty)

        let prefixedCountOutput = try runExecutableData([
            "-H",
            "-c",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(prefixedCountOutput == Data("\(root.path("dense.txt")):4\n".utf8))

        let quietCountResult = try runExecutableResult([
            "-q",
            "-c",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ])
        #expect(quietCountResult.status == 0)
        #expect(quietCountResult.stdout.isEmpty)
        #expect(quietCountResult.stderr.isEmpty)

        let repeatedRegexpMaxCountCountOutput = try runExecutableData([
            "-c",
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(repeatedRegexpMaxCountCountOutput == Data("2\n".utf8))

        let patternFileMaxCountCountOutput = try runExecutableData([
            "--count",
            "--max-count",
            "2",
            "-f",
            root.path("patterns.txt"),
            root.path("dense.txt"),
        ], fixture: {})
        #expect(patternFileMaxCountCountOutput == repeatedRegexpMaxCountCountOutput)

        let alternationMaxCountCountOutput = try runExecutableData([
            "-c",
            "-m2",
            "needle|quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(alternationMaxCountCountOutput == repeatedRegexpMaxCountCountOutput)

        let crlfMaxCountCountOutput = try runExecutableData([
            "--crlf",
            "-c",
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(crlfMaxCountCountOutput == Data("2\r\n".utf8))

        let includeZeroMaxCountCountResult = try runExecutableResult([
            "--include-zero",
            "-c",
            "-m2",
            "-e",
            "missing",
            "-e",
            "absent",
            root.path("dense.txt"),
        ])
        #expect(includeZeroMaxCountCountResult.status == 1)
        #expect(includeZeroMaxCountCountResult.stdout == Data("0\n".utf8))
        #expect(includeZeroMaxCountCountResult.stderr.isEmpty)

        let quietMaxCountCountResult = try runExecutableResult([
            "-q",
            "-c",
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ])
        #expect(quietMaxCountCountResult.status == 0)
        #expect(quietMaxCountCountResult.stdout.isEmpty)
        #expect(quietMaxCountCountResult.stderr.isEmpty)

        let prefixedMaxCountCountOutput = try runExecutableData([
            "-H",
            "-c",
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(prefixedMaxCountCountOutput == Data("\(root.path("dense.txt")):2\n".utf8))

        let headingPrefixedMaxCountCountOutput = try runExecutableData([
            "--heading",
            "--with-filename",
            "-c",
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(headingPrefixedMaxCountCountOutput == prefixedMaxCountCountOutput)

        let nullPrefixedMaxCountCountOutput = try runExecutableData([
            "-H",
            "-0",
            "-c",
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(nullPrefixedMaxCountCountOutput == Data("\(root.path("dense.txt"))\02\n".utf8))

        let pathSeparatedPrefixedMaxCountCountOutput = try runExecutableData([
            "-H",
            "--path-separator=Z",
            "-c",
            "-m2",
            "-e",
            "needle",
            "-e",
            "quiet",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(pathSeparatedPrefixedMaxCountCountOutput == Data("\(pathSeparatedName):2\n".utf8))

        let prefixedIncludeZeroMaxCountCountResult = try runExecutableResult([
            "-H",
            "--include-zero",
            "-c",
            "-m2",
            "-e",
            "missing",
            "-e",
            "absent",
            root.path("dense.txt"),
        ])
        #expect(prefixedIncludeZeroMaxCountCountResult.status == 1)
        #expect(prefixedIncludeZeroMaxCountCountResult.stdout == Data("\(root.path("dense.txt")):0\n".utf8))
        #expect(prefixedIncludeZeroMaxCountCountResult.stderr.isEmpty)

        let orderedNoLineNumberOutput = try runExecutableData([
            "-n",
            "-N",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedNoLineNumberOutput == output)

        let orderedLineNumberOutput = try runExecutableData([
            "-N",
            "-n",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedLineNumberOutput == lineNumberOutput)

        let clusteredNoLineNumberOutput = try runExecutableData([
            "-nN",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredNoLineNumberOutput == output)

        let clusteredLineNumberOutput = try runExecutableData([
            "-Nn",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredLineNumberOutput == lineNumberOutput)

        let lineNumberIgnoreCaseOutput = try runExecutableData([
            "-n",
            "-i",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(lineNumberIgnoreCaseOutput == Data("""
        1:needle needle needle
        3:NEEDLE needle Needle
        4:tail needle

        """.utf8))

        let clusteredLineNumberIgnoreCaseOutput = try runExecutableData([
            "-ni",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredLineNumberIgnoreCaseOutput == lineNumberIgnoreCaseOutput)

        let clusteredCaseInsensitiveOutput = try runExecutableData([
            "-si",
            "NEEDLE",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredCaseInsensitiveOutput == ignoreCaseOutput)

        let lowercaseSmartCaseOutput = try runExecutableData([
            "-S",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(lowercaseSmartCaseOutput == ignoreCaseOutput)

        let clusteredSmartCaseSensitiveOutput = try runExecutableData([
            "-iS",
            "Needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredSmartCaseSensitiveOutput == smartCaseSensitiveOutput)

        let clusteredIgnoreCaseOutput = try runExecutableData([
            "-Si",
            "Needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(clusteredIgnoreCaseOutput == ignoreCaseOutput)

        let orderedSmartCaseSensitiveOutput = try runExecutableData([
            "-i",
            "-S",
            "Needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedSmartCaseSensitiveOutput == smartCaseSensitiveOutput)

        let orderedIgnoreCaseOutput = try runExecutableData([
            "-S",
            "-i",
            "Needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(orderedIgnoreCaseOutput == ignoreCaseOutput)

        let fixedLiteralMetacharOutput = try runExecutableData([
            "-F",
            "a.b",
            root.path("fixed.txt"),
        ], fixture: {})
        #expect(fixedLiteralMetacharOutput == Data("a.b\n".utf8))

        let longFixedLiteralPipeOutput = try runExecutableData([
            "--fixed-strings",
            "Sherlock|Watson",
            root.path("fixed.txt"),
        ], fixture: {})
        #expect(longFixedLiteralPipeOutput == Data("Sherlock|Watson\n".utf8))

        let clusteredFixedIgnoreCaseOutput = try runExecutableData([
            "-Fi",
            "sherlock|watson",
            root.path("fixed.txt"),
        ], fixture: {})
        #expect(clusteredFixedIgnoreCaseOutput == Data("""
        Sherlock|Watson
        sherlock|watson

        """.utf8))

        let orderedNoFixedStringsOutput = try runExecutableData([
            "-F",
            "--no-fixed-strings",
            "a.b",
            root.path("fixed.txt"),
        ], fixture: {})
        #expect(orderedNoFixedStringsOutput == Data("""
        a.b
        aXb

        """.utf8))

        let mmapOutput = try runExecutableData([
            "--mmap",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(mmapOutput == output)

        let mmapLineNumberIgnoreCaseOutput = try runExecutableData([
            "--mmap",
            "-n",
            "-i",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(mmapLineNumberIgnoreCaseOutput == lineNumberIgnoreCaseOutput)

        let mmapOverridesNoMmapOutput = try runExecutableData([
            "--no-mmap",
            "--mmap",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(mmapOverridesNoMmapOutput == output)

        let noMmapOverridesMmapOutput = try runExecutableData([
            "--mmap",
            "--no-mmap",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noMmapOverridesMmapOutput == output)

        let noMmapOutput = try runExecutableData([
            "--no-mmap",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noMmapOutput == output)

        var noMmapBoundary = Data(
            repeating: UInt8(ascii: "q"),
            count: 2 * 1024 * 1024 - 4
        )
        noMmapBoundary.append(UInt8(ascii: "\n"))
        noMmapBoundary.append(contentsOf: "nee".utf8)
        noMmapBoundary.append(contentsOf: "dle across boundary\nquiet\n".utf8)
        try root.write(noMmapBoundary, to: "no-mmap-boundary.txt")
        let noMmapBoundaryOutput = try runExecutableData([
            "--no-mmap",
            "needle",
            root.path("no-mmap-boundary.txt"),
        ], fixture: {})
        #expect(noMmapBoundaryOutput == Data("needle across boundary\n".utf8))
        let noMmapBoundaryLineNumberOutput = try runExecutableData([
            "--no-mmap",
            "-n",
            "needle",
            root.path("no-mmap-boundary.txt"),
        ], fixture: {})
        #expect(noMmapBoundaryLineNumberOutput == Data("2:needle across boundary\n".utf8))
        let noMmapBoundaryIgnoreCaseOutput = try runExecutableData([
            "--no-mmap",
            "-i",
            "NEEDLE",
            root.path("no-mmap-boundary.txt"),
        ], fixture: {})
        #expect(noMmapBoundaryIgnoreCaseOutput == Data("needle across boundary\n".utf8))
        let noMmapBoundaryLineNumberIgnoreCaseOutput = try runExecutableData([
            "--no-mmap",
            "-n",
            "-i",
            "NEEDLE",
            root.path("no-mmap-boundary.txt"),
        ], fixture: {})
        #expect(noMmapBoundaryLineNumberIgnoreCaseOutput == Data("2:needle across boundary\n".utf8))

        let noMmapLineNumberIgnoreCaseOutput = try runExecutableData([
            "--no-mmap",
            "-n",
            "-i",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noMmapLineNumberIgnoreCaseOutput == lineNumberIgnoreCaseOutput)

        let noMmapClusteredLineNumberIgnoreCaseOutput = try runExecutableData([
            "--no-mmap",
            "-ni",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(noMmapClusteredLineNumberIgnoreCaseOutput == lineNumberIgnoreCaseOutput)

        try root.write("quiet\nneedle at end", to: "unterminated.txt")
        let noMmapUnterminatedLineOutput = try runExecutableData([
            "--no-mmap",
            "-n",
            "needle",
            root.path("unterminated.txt"),
        ], fixture: {})
        #expect(noMmapUnterminatedLineOutput == Data("2:needle at end\n".utf8))

        let noMmapUnterminatedOutput = try runExecutableData([
            "--no-mmap",
            "needle",
            root.path("unterminated.txt"),
        ], fixture: {})
        #expect(noMmapUnterminatedOutput == Data("needle at end\n".utf8))
        #endif
    }

    @Test("supports regex fixed string word and line matching")
    func supportsMatcherModes() throws {
        let root = try TemporaryDirectory()
        try root.write("abc123\nabc.123\nabc\nabc def\nxabc\n", to: "patterns.txt")
        try root.write("é\nπ\n.\n", to: "scalars.txt")

        #expect(try run(["abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["-F", "abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["-F", "--no-fixed-strings", "abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["--no-fixed-strings", "-F", "abc.123", root.path("patterns.txt")]) == ["abc.123"])
        #expect(try run(["-w", "abc", root.path("patterns.txt")]) == ["abc.123", "abc", "abc def"])
        #expect(try run(["-x", "abc", root.path("patterns.txt")]) == ["abc"])
        #expect(try run(["-w", "-x", "abc", root.path("patterns.txt")]) == ["abc"])
        #expect(try run(["-x", "-w", "abc", root.path("patterns.txt")]) == ["abc.123", "abc", "abc def"])
        try root.write("abc abc123 123 abc_def x-y foo.bar foo/bar\nempty:\n", to: "word-edges.txt")
        #expect(try run(["-wo", #"\D+"#, root.path("word-edges.txt")]) == [
            "abc",
            "abc_def x-y foo.bar foo/bar",
            "empty:",
        ])
        #expect(try runAllowingNoMatch(["-wo", #"\W+"#, root.path("word-edges.txt")]) == [])
        try root.write(Data("foo\r\nbar\r\nbaz\r\n".utf8), to: "crlf-word-boundary.txt")
        #expect(try runAllowingNoMatch(["-w", #"\b"#, root.path("crlf-word-boundary.txt")]) == [])
        let crlfNotWordBoundaryOutput = try runExecutableData([
            "-w",
            "-bo",
            #"\B"#,
            root.path("crlf-word-boundary.txt"),
        ], fixture: {})
        #expect(crlfNotWordBoundaryOutput == Data("4:\n9:\n14:\n".utf8))
        try root.write("  needle  \nneedle\n##\n", to: "word-boundary-only.txt")
        #expect(try runAllowingNoMatch(["-w", #"\b"#, root.path("word-boundary-only.txt")]) == [])
        #expect(try run(["-w", #"\B"#, root.path("word-boundary-only.txt")]) == [
            "  needle  ",
            "##",
        ])
        try root.write("é e\u{301} É π Δ δ привет Привет １２3\n", to: "unicode-word-edges.txt")
        #expect(try run(["-wo", #"[[:^alpha:]]+"#, root.path("unicode-word-edges.txt")]) == [
            "é",
            "É π Δ δ привет Привет １２3",
        ])
        #expect(try run(["-e", ")(", root.path("patterns.txt")]) == ["abc123", "abc.123", "abc", "abc def", "xabc"])
        try root.write("abc\n\n", to: "empty-literal.txt")
        #expect(try run(["-F", "", root.path("empty-literal.txt")]) == ["abc", ""])
        #expect(try run(["-Fo", "", root.path("empty-literal.txt")]) == ["", "", "", "", ""])
        #expect(try run(["-Fc", "", root.path("empty-literal.txt")]) == ["2"])
        #expect(try run(["-Fw", "", root.path("empty-literal.txt")]) == [""])
        #expect(try run(["-Fx", "", root.path("empty-literal.txt")]) == [""])
        #expect(try runAllowingNoMatch(["-Fv", "", root.path("empty-literal.txt")]) == [])
        try root.write("a\nb\nab\nba\n\n", to: "empty-word-regex.txt")
        #expect(try run(["-w", "a*", root.path("empty-word-regex.txt")]) == ["a", ""])
        #expect(try run(["-wo", "a*", root.path("empty-word-regex.txt")]) == ["a", ""])
        #expect(try run(["-w", "--count-matches", "a*", root.path("empty-word-regex.txt")]) == ["2"])
        #expect(try run(["-w", "-bo", "a*", root.path("empty-word-regex.txt")]) == [
            "0:a",
            "10:",
        ])
        #expect(try run(["-w", "-n", "--column", "-o", "a*", root.path("empty-word-regex.txt")]) == [
            "1:1:a",
            "5:1:",
        ])

        var output: [String] = []
        var errors: [String] = []
        var exitCode = RipgrepCLI.run(
            arguments: [#"foo\x00?"#, root.path("patterns.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors == ["""
        rg: pattern contains "\\0" but it is impossible to match

        Consider enabling text mode with the --text flag (or -a for short). Otherwise,
        binary detection is enabled and matching a NUL byte is impossible.
        """])

        output = []
        errors = []
        exitCode = RipgrepCLI.run(
            arguments: ["--binary", #"foo\x00?"#, root.path("patterns.txt")],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        #expect(exitCode == 2)
        #expect(output.isEmpty)
        #expect(errors.first?.contains("pattern contains") == true)

        #expect(try run(["-a", #"abc\x00?"#, root.path("patterns.txt")]) == ["abc123", "abc.123", "abc", "abc def", "xabc"])
        #expect(try runAllowingNoMatch(["-F", #"foo\x00?"#, root.path("patterns.txt")]) == [])
        #expect(try run(["-o", #"\x{E9}"#, root.path("scalars.txt")]) == ["é"])
        #expect(try run(["-o", #"\u{03C0}"#, root.path("scalars.txt")]) == ["π"])
        #expect(try run(["-o", #"\x{2E}"#, root.path("scalars.txt")]) == ["."])
        try root.write("a é z-9_\na\u{0B}b\n", to: "posix.txt")
        #expect(try run(["-o", #"[[:word:]]+"#, root.path("posix.txt")]) == ["a", "z", "9_", "a", "b"])
        #expect(try run(["-o", #"[[:^word:]]+"#, root.path("posix.txt")]) == [" é ", "-", "\u{0B}"])
        #expect(try run(["-o", #"[a[:^word:]]+"#, root.path("posix.txt")]) == ["a é ", "-", "a\u{0B}"])
        let noUnicodeNegatedWord = try runExecutableData([
            "--no-unicode",
            "-o",
            #"[[:^word:]]+"#,
            root.path("posix.txt"),
        ]) {}
        #expect(noUnicodeNegatedWord == Data(" é \n-\n\u{0B}\n".utf8))
        #expect(try run(["-o", #"[[:space:]]+"#, root.path("posix.txt")]) == [" ", " ", "\u{0B}"])
    }

}
