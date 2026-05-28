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

        try root.write("Sherlock Holmes", to: "word-literal-no-final-newline.txt")
        let noFinalNewlineOutput = try runExecutableData([
            "-nw",
            "Sherlock Holmes",
            root.path("word-literal-no-final-newline.txt"),
        ], fixture: {})
        #expect(noFinalNewlineOutput == Data("1:Sherlock Holmes\n".utf8))

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
        try root.write("needle\n", to: ".hidden.txt")
        try root.write("*.txt\n", to: ".ignore")
        try root.write("needle\n", to: "ignored.txt")
        try root.write(Data("pre\0needle\n".utf8), to: "binary-mode.dat")
        try root.write("quiet\n", to: "quiet-no-match.txt")

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

        for (quietArguments, expectedStatus) in [
            (["-q", "needle", root.path("dense.txt")], Int32(0)),
            (["--quiet", "missing", root.path("quiet-no-match.txt")], Int32(1)),
            (["-qn", "needle", root.path("dense.txt")], Int32(0)),
            (["-qi", "needle", root.path("dense.txt")], Int32(0)),
            (["-qi", "NEEDLE", root.path("dense.txt")], Int32(0)),
            (["-qi", "absentliteral", root.path("dense.txt")], Int32(1)),
            (["-qi", "12345", root.path("dense.txt")], Int32(1)),
            (["-q", "-w", "needle", root.path("dense.txt")], Int32(0)),
            (["-qw", "needle", root.path("dense.txt")], Int32(0)),
            (["-q", "-w", "eed", root.path("dense.txt")], Int32(1)),
            (["-q", "needle|tail", root.path("dense.txt")], Int32(0)),
            (["-qi", "NEEDLE|TAIL", root.path("dense.txt")], Int32(0)),
            (["-qi", "123|456", root.path("dense.txt")], Int32(1)),
            (["-q", "missing|absent", root.path("dense.txt")], Int32(1)),
            (["-q", "-x", "needle", root.path("exact.txt")], Int32(0)),
            (["-q", "-i", "-x", "NEEDLE", root.path("exact.txt")], Int32(0)),
            (["-q", "-x", "missing", root.path("exact.txt")], Int32(1)),
            (["-q", "-i", "-x", "missing", root.path("exact.txt")], Int32(1)),
            (["-q", "-i", "-x", "12345", root.path("exact.txt")], Int32(1)),
            (["--crlf", "-q", "-x", "needle", root.path("crlf.txt")], Int32(0)),
            (["-q", "needle", root.path("binary-mode.dat")], Int32(0)),
        ] {
            let quietResult = try runExecutableResult(quietArguments)
            #expect(quietResult.stdout.isEmpty)
            #expect(quietResult.stderr.isEmpty)
            #expect(quietResult.status == expectedStatus)
        }

        for (pathOnlyArguments, expectedOutput, expectedStatus) in [
            (["-l", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--files-with-matches", "--null", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\0".utf8), Int32(0)),
            (["-l", "missing", root.path("dense.txt")], Data(), Int32(1)),
            (["--files-without-match", "missing", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "needle", root.path("dense.txt")], Data(), Int32(1)),
            (["-li", "NEEDLE", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "-i", "NEEDLE", root.path("dense.txt")], Data(), Int32(1)),
            (["-li", "12345", root.path("dense.txt")], Data(), Int32(1)),
            (["--files-without-match", "-i", "12345", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["-q", "-l", "needle", root.path("dense.txt")], Data(), Int32(0)),
            (["-l", "-w", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["-l", "-w", "eed", root.path("dense.txt")], Data(), Int32(1)),
            (["--files-with-matches", "--null", "-w", "needle", root.path("dense.txt")], Data("\(root.path("dense.txt"))\0".utf8), Int32(0)),
            (["--files-without-match", "-w", "eed", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
            (["--files-without-match", "-w", "needle", root.path("dense.txt")], Data(), Int32(1)),
            (["-l", "needle|tail", root.path("dense.txt")], Data("\(root.path("dense.txt"))\n".utf8), Int32(0)),
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
        ] {
            let pathOnlyResult = try runExecutableResult(pathOnlyArguments)
            #expect(pathOnlyResult.stdout == expectedOutput)
            #expect(pathOnlyResult.stderr.isEmpty)
            #expect(pathOnlyResult.status == expectedStatus)
        }

        for (maxCountArguments, expectedOutput) in [
            (["-m1", "needle", root.path("dense.txt")], Data("needle needle needle\n".utf8)),
            (["-n", "-m1", "needle", root.path("dense.txt")], Data("1:needle needle needle\n".utf8)),
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

        for (countArguments, expectedOutput, expectedStatus) in [
            (["-c", "needle", root.path("dense.txt")], Data("3\n".utf8), Int32(0)),
            (["--count", "missing", root.path("quiet-no-match.txt")], Data(), Int32(1)),
            (["--count", "--include-zero", "missing", root.path("quiet-no-match.txt")], Data("0\n".utf8), Int32(1)),
            (["-c", "-m1", "needle", root.path("dense.txt")], Data("1\n".utf8), Int32(0)),
            (["-c", "-m1", "-i", "NEEDLE", root.path("dense.txt")], Data("1\n".utf8), Int32(0)),
            (["-ci", "-m1", "NEEDLE", root.path("dense.txt")], Data("1\n".utf8), Int32(0)),
            (["-c", "-m1", "-i", "missing", root.path("dense.txt")], Data(), Int32(1)),
            (["-c", "-m1", "-i", "12345", root.path("dense.txt")], Data(), Int32(1)),
            (["-c", "-m1", "-i", "--include-zero", "12345", root.path("dense.txt")], Data("0\n".utf8), Int32(1)),
            (["-c", "-x", "needle", root.path("exact.txt")], Data("2\n".utf8), Int32(0)),
            (["-c", "-m1", "-x", "needle", root.path("exact.txt")], Data("1\n".utf8), Int32(0)),
            (["-c", "-m1", "-i", "-x", "NEEDLE", root.path("exact.txt")], Data("1\n".utf8), Int32(0)),
            (["-cix", "-m1", "NEEDLE", root.path("exact.txt")], Data("1\n".utf8), Int32(0)),
            (["-c", "-m1", "-i", "-x", "--include-zero", "12345", root.path("exact.txt")], Data("0\n".utf8), Int32(1)),
            (["-c", "-x", "--include-zero", "missing", root.path("exact.txt")], Data("0\n".utf8), Int32(1)),
        ] {
            let countResult = try runExecutableResult(countArguments)
            #expect(countResult.stdout == expectedOutput)
            #expect(countResult.stderr.isEmpty)
            #expect(countResult.status == expectedStatus)
        }

        for (exactLineArguments, expectedOutput) in [
            (["-x", "needle", root.path("exact.txt")], Data("needle\nneedle\n".utf8)),
            (["-n", "-x", "needle", root.path("exact.txt")], Data("1:needle\n3:needle\n".utf8)),
            (["-nx", "needle", root.path("exact.txt")], Data("1:needle\n3:needle\n".utf8)),
            (["-m1", "-x", "needle", root.path("exact.txt")], Data("needle\n".utf8)),
            (["-x", "last", root.path("exact.txt")], Data("last\n".utf8)),
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

        let nullPathBinaryFallbackOutput = try runExecutableData([
            "--null",
            "needle",
            root.path("binary-mode.dat"),
        ], fixture: {})
        #expect(nullPathBinaryFallbackOutput == Data("""
        binary file matches (found "\\0" byte around offset 3)

        """.utf8))

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

        let blockBufferedOutput = try runExecutableData([
            "--block-buffered",
            "needle",
            root.path("dense.txt"),
        ], fixture: {})
        #expect(blockBufferedOutput == output)

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
