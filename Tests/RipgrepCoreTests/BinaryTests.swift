import Foundation
import Testing
@testable import RipgrepCore

@Suite("Ripgrep binary parity area", .serialized)
struct BinaryTests {
    @Test("handles binary detection modes")
    func handlesBinaryDetectionModes() throws {
        let root = try TemporaryDirectory()
        try root.write(Data("needle\0tail\n".utf8), to: "bin.dat")
        try root.write(Data("needle\n\0tail\n".utf8), to: "before-nul.dat")
        try root.write(Data("foo\0needle\0bar\0".utf8), to: "nul-anchors.dat")

        #expect(try runAllowingNoMatch(["-n", "needle", root.url.path]) == [])
        #expect(try runAllowingNoMatch(["tail", root.url.path]) == [])
        #expect(try run(["needle", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run([#"[^\x00]"#, root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-U", "tail", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-U", "$", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        let multilineBinaryEndOutput = try runExecutableData([
            "-U",
            "-a",
            "$",
            root.path("bin.dat"),
        ], fixture: {})
        #expect(multilineBinaryEndOutput == Data("needle\0tail\n".utf8))
        #expect(try run(["-U", "-a", "--count-matches", "$", root.path("bin.dat")]) == [
            "1",
        ])
        #expect(try runAllowingNoMatch(["-U", "needle.tail", root.path("bin.dat")]) == [])
        #expect(try run(["-U", "--multiline-dotall", "needle.tail", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-U", #"(?s)needle.*tail"#, root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["--encoding", "utf-8", "needle", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["--encoding", "latin1", "needle", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try runAllowingNoMatch(["-U", #"needle\ntail"#, root.path("bin.dat")]) == [])
        #expect(try run(["-n", "needle", root.path("before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["-n", "tail", root.path("before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["-A1", "needle", root.path("bin.dat")]) == [
            #"binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-A1", "needle", root.path("before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["-0", "-A1", "needle", root.path("before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])
        #expect(try run(["^needle", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try run(["foo$", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try run(["-A1", "^needle", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try runAllowingNoMatch(["-B1", "^needle", root.path("nul-anchors.dat")]) == [])
        #expect(try runAllowingNoMatch(["-C1", "^needle", root.path("nul-anchors.dat")]) == [])
        #expect(try run(["-B1", "foo$", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try runAllowingNoMatch(["--passthru", "^needle", root.path("nul-anchors.dat")]) == [])
        #expect(try run(["--passthru", "foo$", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try runAllowingNoMatch(["-v", "[a-z]+", root.path("nul-anchors.dat")]) == [])
        #expect(try runAllowingNoMatch(["--text", "^needle", root.path("nul-anchors.dat")]) == [])
        #expect(try run(["-U", "-B1", "[a-z]+", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try run(["-U", "--passthru", "[a-z]+", root.path("nul-anchors.dat")]) == [
            #"binary file matches (found "\0" byte around offset 3)"#,
        ])
        #expect(try run(["-U", "--count", "[a-z]+", root.path("nul-anchors.dat")]) == ["3"])

        var lateBinary = Data(repeating: UInt8(ascii: "a"), count: 70_000)
        lateBinary.append(0)
        lateBinary.append(contentsOf: Data("tail\n".utf8))
        try root.write(lateBinary, to: "late-nul.dat")
        #expect(try run(["--passthru", "aaaa", root.path("late-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 70000)"#,
        ])
        #expect(try runAllowingNoMatch(["--passthru", "tail", root.path("late-nul.dat")]) == [])

        var lateBlockBinary = Data("medical student before\n".utf8)
        lateBlockBinary.append(
            Data(repeating: UInt8(ascii: "x"), count: 70_000 - lateBlockBinary.count)
        )
        lateBlockBinary.append(0)
        lateBlockBinary.append(contentsOf: Data("medical student after\n".utf8))
        try root.write(lateBlockBinary, to: "late-block-nul.dat")
        let lateBlockOutput = try runExecutableData([
            "--mmap",
            "-n",
            "medical student",
            root.path("late-block-nul.dat"),
        ], fixture: {})
        #expect(lateBlockOutput == Data((
            "1:medical student before\n" +
            #"binary file matches (found "\0" byte around offset 70000)"# + "\n"
        ).utf8))

        try root.write(
            Data("Project Gutenberg EBook first\n\0binary tail\n".utf8),
            to: "explicit-text.dat"
        )
        let explicitTextOutput = try runExecutableData([
            "--no-mmap",
            "-n",
            "--text",
            "Project Gutenberg EBook",
            root.path("explicit-text.dat"),
        ], fixture: {})
        #expect(explicitTextOutput == Data("1:Project Gutenberg EBook first\n".utf8))

        let multilineBinaryReplacementStats = try run([
            "--stats",
            "-U",
            "--replace",
            "X",
            "[a-z]+",
            root.path("nul-anchors.dat"),
        ])
        #expect(multilineBinaryReplacementStats.contains("1 matches"))
        #expect(multilineBinaryReplacementStats.contains("1 matched lines"))
        #expect(multilineBinaryReplacementStats.contains("4 bytes searched"))
        #expect(try run(["-c", "needle", root.path("before-nul.dat")]) == ["1"])
        #expect(pathBasenames(try run(["--sort=path", "--binary", "needle", root.url.path])) == [
            "before-nul.dat",
            "bin.dat",
            "nul-anchors.dat",
        ])

        try root.write(Data("a\0needle\nb\0\n".utf8), to: "text-multiline-nul.dat")
        let multilineTextNULOutput = try runExecutableData([
            "-U",
            "-a",
            "needle",
            root.path("text-multiline-nul.dat"),
        ], fixture: {})
        #expect(multilineTextNULOutput == Data("a\0needle\n".utf8))

        let countRoot = try TemporaryDirectory()
        try countRoot.write(Data("cat cat\npadding\n\0tail cat\n".utf8), to: "file1.txt")
        try countRoot.write("cat here\n", to: "file2.txt")
        #expect(pathBasenames(try run(["--sort=path", "-l", "cat", countRoot.url.path])) == ["file2.txt"])
        #expect(countBasenames(try run(["--sort=path", "-c", "cat", countRoot.url.path])) == ["file2.txt:1"])
        #expect(countBasenames(try run(["--sort=path", "-c", "cat", countRoot.url.path, "--binary"])) == [
            "file1.txt:2",
            "file2.txt:1",
        ])
        #expect(countBasenames(try run(["--sort=path", "-c", "-o", "cat", countRoot.url.path, "--binary"])) == [
            "file1.txt:3",
            "file2.txt:1",
        ])
        #expect(countBasenames(try run(["--sort=path", "--count-matches", "cat", countRoot.url.path, "--binary"])) == [
            "file1.txt:3",
            "file2.txt:1",
        ])
        #expect(countBasenames(try run(["--sort=path", "-c", "cat", countRoot.url.path, "--text"])) == [
            "file1.txt:2",
            "file2.txt:1",
        ])
        let binaryStats = try run(["--stats", "cat", countRoot.path("file1.txt")])
        #expect(binaryStats.contains("2 matches"))
        #expect(binaryStats.contains("1 matched lines"))
        #expect(binaryStats.contains("55 bytes printed"))
        #expect(binaryStats.contains("8 bytes searched"))

        try countRoot.write(Data("pre\nneedle\0after\nneedle later\n".utf8), to: "multi-match-before-nul.dat")
        let multiLineBeforeNULStats = try run(["--stats", #"[a-z]+"#, countRoot.path("multi-match-before-nul.dat")])
        #expect(multiLineBeforeNULStats.contains("1 matches"))
        #expect(multiLineBeforeNULStats.contains("1 matched lines"))
        #expect(multiLineBeforeNULStats.contains("4 bytes searched"))
        let quietMultiLineBeforeNULStats = try run([
            "-q",
            "--stats",
            #"[a-z]+"#,
            countRoot.path("multi-match-before-nul.dat"),
        ])
        #expect(quietMultiLineBeforeNULStats.contains("5 matches"))
        #expect(quietMultiLineBeforeNULStats.contains("4 matched lines"))
        #expect(try run(["--passthru", #"[a-z]+"#, countRoot.path("multi-match-before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 10)"#,
        ])
        #expect(runWithExitCode(
            ["--passthru", "needle$", countRoot.path("multi-match-before-nul.dat")],
            expectedExitCode: 1
        ).isEmpty)
        #expect(runWithExitCode(
            ["--passthru", "needle", countRoot.path("multi-match-before-nul.dat")],
            expectedExitCode: 1
        ).isEmpty)
        #expect(runWithExitCode(
            ["-B1", "needle", countRoot.path("multi-match-before-nul.dat")],
            expectedExitCode: 1
        ).isEmpty)
        #expect(runWithExitCode(
            ["-C1", "needle", countRoot.path("multi-match-before-nul.dat")],
            expectedExitCode: 1
        ).isEmpty)
        #expect(try run(["-A1", "needle", countRoot.path("multi-match-before-nul.dat")]) == [
            #"binary file matches (found "\0" byte around offset 10)"#,
        ])

        let postNulStats = try run(["--stats", "tail", countRoot.path("file1.txt")])
        #expect(postNulStats.contains("1 matches"))
        #expect(postNulStats.contains("1 matched lines"))
        #expect(postNulStats.contains("26 bytes searched"))

        try countRoot.write(Data("abc\0needle\nneedle2\0tail\n".utf8), to: "post-nul.txt")
        let explicitPostNulStats = try run(["--stats", "needle", countRoot.path("post-nul.txt")])
        #expect(explicitPostNulStats.contains("1 matches"))
        #expect(explicitPostNulStats.contains("11 bytes searched"))
        let passthruPostNulStats = runWithExitCode(
            ["--stats", "--passthru", "needle", countRoot.path("post-nul.txt")],
            expectedExitCode: 1
        )
        #expect(passthruPostNulStats.contains("0 matches"))
        #expect(passthruPostNulStats.contains("4 bytes searched"))
        let passthruNoMatchBinaryStats = runWithExitCode(
            ["--stats", "--passthru", "zzz", countRoot.path("post-nul.txt")],
            expectedExitCode: 1
        )
        #expect(passthruNoMatchBinaryStats.contains("0 matches"))
        #expect(passthruNoMatchBinaryStats.contains("4 bytes searched"))
        let passthruPostNulJSON = try run(["--json", "--passthru", "needle", countRoot.path("post-nul.txt")])
        let passthruPostNulMessages = try passthruPostNulJSON.map(jsonObject)
        let passthruPostNulEnd = passthruPostNulMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let passthruPostNulJSONStats = passthruPostNulEnd?["stats"] as? [String: Any]
        #expect(passthruPostNulJSONStats?["bytes_searched"] as? Int == 24)
        let jsonNoMatchBinary = runWithExitCode(
            ["-U", "--json", "^bar", countRoot.path("post-nul.txt")],
            expectedExitCode: 1
        )
        let jsonNoMatchMessages = try jsonNoMatchBinary.map(jsonObject)
        let jsonNoMatchSummary = jsonNoMatchMessages.first { $0["type"] as? String == "summary" }?["data"] as? [String: Any]
        let jsonNoMatchStats = jsonNoMatchSummary?["stats"] as? [String: Any]
        #expect(jsonNoMatchStats?["bytes_searched"] as? Int == 3)
        let beforeContextPostNulStats = runWithExitCode(
            ["--stats", "-B1", "needle", countRoot.path("post-nul.txt")],
            expectedExitCode: 1
        )
        #expect(beforeContextPostNulStats.contains("0 matches"))
        #expect(beforeContextPostNulStats.contains("0 bytes searched"))

        var quietBinaryStatsOutput: [String] = []
        let quietBinaryStatsExitCode = RipgrepCLI.run(
            arguments: ["-q", "--stats", "cat", countRoot.path("file1.txt")],
            stdout: { quietBinaryStatsOutput.append($0) }
        )
        #expect(quietBinaryStatsExitCode == 0)
        #expect(quietBinaryStatsOutput.contains("3 matches"))
        #expect(quietBinaryStatsOutput.contains("2 matched lines"))
        #expect(quietBinaryStatsOutput.contains("26 bytes searched"))

        let withoutRoot = try TemporaryDirectory()
        try withoutRoot.write(Data("hay\0cat\n".utf8), to: "binary.txt")
        try withoutRoot.write("hay\n", to: "text.txt")
        #expect(pathBasenames(try run([
            "--sort=path",
            "--files-without-match",
            "cat",
            withoutRoot.url.path,
        ])) == ["text.txt"])
        #expect(pathBasenames(try run([
            "--sort=path",
            "--files-without-match",
            "absent",
            withoutRoot.url.path,
        ])) == ["text.txt"])
        let explicitBinaryWithoutMatch = try runExecutableData([
            "--files-without-match",
            "absent",
            withoutRoot.path("binary.txt"),
        ], fixture: {})
        #expect(explicitBinaryWithoutMatch == Data("\(withoutRoot.path("binary.txt"))\n".utf8))
        var stdinOutput: [String] = []
        var stdinExitCode = RipgrepCLI.run(
            arguments: ["-n", "needle", "-"],
            stdout: { stdinOutput.append($0) },
            stdin: "needle\n\0tail\n"
        )
        #expect(stdinExitCode == 0)
        #expect(stdinOutput == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])

        stdinOutput = []
        stdinExitCode = RipgrepCLI.run(
            arguments: ["-n", "tail", "-"],
            stdout: { stdinOutput.append($0) },
            stdin: "needle\n\0tail\n"
        )
        #expect(stdinExitCode == 0)
        #expect(stdinOutput == [
            #"binary file matches (found "\0" byte around offset 7)"#,
        ])

        stdinOutput = []
        stdinExitCode = RipgrepCLI.run(
            arguments: ["--passthru", "tail", "-"],
            stdout: { stdinOutput.append($0) },
            stdin: "needle\n\0tail\n"
        )
        #expect(stdinExitCode == 1)
        #expect(stdinOutput == [])

        stdinOutput = []
        stdinExitCode = RipgrepCLI.run(
            arguments: ["-B1", "tail", "-"],
            stdout: { stdinOutput.append($0) },
            stdin: "needle\n\0tail\n"
        )
        #expect(stdinExitCode == 1)
        #expect(stdinOutput == [])

        let stdinContextFile = try TemporaryDirectory()
        try stdinContextFile.write("file needle\nfile tail\n", to: "file.txt")
        stdinOutput = []
        stdinExitCode = RipgrepCLI.run(
            arguments: ["-A1", "tail", stdinContextFile.path("file.txt"), "-"],
            stdout: { stdinOutput.append($0) },
            stdin: "needle\0tail\n"
        )
        #expect(stdinExitCode == 0)
        #expect(stdinOutput == [
            "\(stdinContextFile.path("file.txt")):file tail",
            #"<stdin>: binary file matches (found "\0" byte around offset 6)"#,
        ])
        #expect(try run(["-a", "needle", root.path("bin.dat")]) == [
            "needle\0tail",
        ])
        #expect(try run(["-c", "needle", root.path("bin.dat")]) == ["1"])
        #expect(pathBasenames(try run(["-l", "needle", root.path("bin.dat")])) == ["bin.dat"])

        try root.write(Data("pre\nneedle before\n\0binary needle after\n".utf8), to: "binary-counts.dat")
        #expect(try run(["-c", "needle", root.path("binary-counts.dat")]) == ["2"])
        #expect(try run(["--count-matches", "needle", root.path("binary-counts.dat")]) == ["2"])
        let jsonBinaryOutput = try run(["--json", "needle", root.path("binary-counts.dat")])
        let jsonBinaryMessages = try jsonBinaryOutput.map(jsonObject)
        #expect(jsonBinaryMessages.filter { $0["type"] as? String == "match" }.count == 2)
        let jsonBinaryMatches = jsonBinaryMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        let jsonBinarySecondLines = jsonBinaryMatches[1]["lines"] as? [String: String]
        let jsonBinarySecondSubmatches = jsonBinaryMatches[1]["submatches"] as? [[String: Any]]
        #expect(jsonBinarySecondLines?["text"] == "binary needle after\n")
        #expect(jsonBinarySecondSubmatches?.first?["start"] as? Int == 7)
        let jsonBinaryEnd = jsonBinaryMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let jsonBinaryStats = jsonBinaryEnd?["stats"] as? [String: Any]
        #expect(jsonBinaryStats?["matches"] as? Int == 2)

        try root.write(Data("bin\0needle\npost\0tail needle\n".utf8), to: "binary-multiline-json.dat")
        let multilineBinaryJSONOutput = try run(["-U", "--json", "needle", root.path("binary-multiline-json.dat")])
        let multilineBinaryJSONMessages = try multilineBinaryJSONOutput.map(jsonObject)
        let multilineBinaryJSONMatches = multilineBinaryJSONMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        #expect(multilineBinaryJSONMatches.map { $0["line_number"] as? Int } == [2, 4])
        #expect(multilineBinaryJSONMatches.compactMap { ($0["lines"] as? [String: String])?["text"] } == [
            "needle\n",
            "tail needle\n",
        ])
        let multilineBinaryJSONSecondSubmatches = multilineBinaryJSONMatches[1]["submatches"] as? [[String: Any]]
        #expect(multilineBinaryJSONSecondSubmatches?.first?["start"] as? Int == 5)
        #expect(multilineBinaryJSONSecondSubmatches?.first?["end"] as? Int == 11)
        let multilineBinaryDotAllJSONOutput = try run([
            "-U",
            "--multiline-dotall",
            "--json",
            "needle.post",
            root.path("binary-multiline-json.dat"),
        ])
        let multilineBinaryDotAllJSONMessages = try multilineBinaryDotAllJSONOutput.map(jsonObject)
        let multilineBinaryDotAllJSONMatch = multilineBinaryDotAllJSONMessages.first {
            $0["type"] as? String == "match"
        }?["data"] as? [String: Any]
        let multilineBinaryDotAllJSONLines = multilineBinaryDotAllJSONMatch?["lines"] as? [String: String]
        let multilineBinaryDotAllJSONEnd = multilineBinaryDotAllJSONMessages.first {
            $0["type"] as? String == "end"
        }?["data"] as? [String: Any]
        let multilineBinaryDotAllJSONStats = multilineBinaryDotAllJSONEnd?["stats"] as? [String: Any]
        #expect(multilineBinaryDotAllJSONMatch?["line_number"] as? Int == 1)
        #expect(multilineBinaryDotAllJSONMatch?["absolute_offset"] as? Int == 0)
        #expect(multilineBinaryDotAllJSONLines?["text"] == "bin\0needle\npost\0tail needle\n")
        #expect(multilineBinaryDotAllJSONStats?["bytes_searched"] as? Int == 3)

        try root.write(Data("needle\0tail\0needle tail\0".utf8), to: "binary-multiline-records.dat")
        let multilineBinaryRecordsJSONOutput = try run(["-U", "--json", "needle", root.path("binary-multiline-records.dat")])
        let multilineBinaryRecordsJSONMessages = try multilineBinaryRecordsJSONOutput.map(jsonObject)
        let multilineBinaryRecordsJSONMatches = multilineBinaryRecordsJSONMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        #expect(multilineBinaryRecordsJSONMatches.map { $0["line_number"] as? Int } == [1, 3])
        #expect(multilineBinaryRecordsJSONMatches.compactMap { ($0["lines"] as? [String: String])?["text"] } == [
            "needle\n",
            "needle tail\n",
        ])
        let multilineBinaryRecordsContextOutput = try run(["-U", "--json", "-A1", "needle", root.path("binary-multiline-records.dat")])
        let multilineBinaryRecordsContextMessages = try multilineBinaryRecordsContextOutput.map(jsonObject)
        #expect(multilineBinaryRecordsContextMessages.compactMap { $0["type"] as? String } == [
            "begin",
            "match",
            "context",
            "match",
            "end",
            "summary",
        ])
        let multilineBinaryClassJSONOutput = try run(["-U", "--json", #"[^\n]+"#, root.path("binary-multiline-records.dat")])
        let multilineBinaryClassJSONMessages = try multilineBinaryClassJSONOutput.map(jsonObject)
        let multilineBinaryClassJSONMatches = multilineBinaryClassJSONMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        #expect(multilineBinaryClassJSONMatches.compactMap { ($0["lines"] as? [String: String])?["text"] } == [
            "needle\n",
            "tail\n",
            "needle tail\n",
        ])
        let multilineBinaryBoundaryJSONOutput = try run(["-U", "--json", #"\b"#, root.path("binary-multiline-records.dat")])
        let multilineBinaryBoundaryJSONMessages = try multilineBinaryBoundaryJSONOutput.map(jsonObject)
        let multilineBinaryBoundaryJSONMatches = multilineBinaryBoundaryJSONMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        let multilineBinaryBoundarySubmatches = multilineBinaryBoundaryJSONMatches.compactMap { $0["submatches"] as? [[String: Any]] }
        #expect(multilineBinaryBoundarySubmatches.map(\.count) == [2, 2, 4])

        let multilineBinaryAnchorJSONOutput = try run(["-U", "--json", "^", root.path("binary-multiline-json.dat")])
        let multilineBinaryAnchorJSONMessages = try multilineBinaryAnchorJSONOutput.map(jsonObject)
        let multilineBinaryAnchorEnd = multilineBinaryAnchorJSONMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let multilineBinaryAnchorStats = multilineBinaryAnchorEnd?["stats"] as? [String: Any]
        #expect(multilineBinaryAnchorStats?["bytes_searched"] as? Int == 3)

        let multilineBinaryEndJSONOutput = try run(["-U", "--json", "$", root.path("binary-multiline-records.dat")])
        let multilineBinaryEndJSONMessages = try multilineBinaryEndJSONOutput.map(jsonObject)
        let multilineBinaryEndJSONMatch = multilineBinaryEndJSONMessages.first { $0["type"] as? String == "match" }?["data"] as? [String: Any]
        let multilineBinaryEndJSONSubmatches = multilineBinaryEndJSONMatch?["submatches"] as? [[String: Any]]
        let multilineBinaryEndJSONEnd = multilineBinaryEndJSONMessages.first { $0["type"] as? String == "end" }?["data"] as? [String: Any]
        let multilineBinaryEndJSONStats = multilineBinaryEndJSONEnd?["stats"] as? [String: Any]
        #expect(multilineBinaryEndJSONSubmatches?.isEmpty == true)
        #expect(multilineBinaryEndJSONStats?["matches"] as? Int == 0)

        try root.write(Data("needle\0tail needle\n".utf8), to: "binary-same-line.dat")
        let sameLineJSONOutput = try run(["--json", "needle", root.path("binary-same-line.dat")])
        let sameLineJSONMessages = try sameLineJSONOutput.map(jsonObject)
        let sameLineJSONMatches = sameLineJSONMessages.compactMap { message -> [String: Any]? in
            guard message["type"] as? String == "match" else { return nil }
            return message["data"] as? [String: Any]
        }
        let sameLineFirstLines = sameLineJSONMatches[0]["lines"] as? [String: String]
        let sameLineSecondLines = sameLineJSONMatches[1]["lines"] as? [String: String]
        let sameLineSecondSubmatches = sameLineJSONMatches[1]["submatches"] as? [[String: Any]]
        #expect(sameLineFirstLines?["text"] == "needle\n")
        #expect(sameLineJSONMatches[0]["line_number"] as? Int == 1)
        #expect(sameLineSecondLines?["text"] == "tail needle\n")
        #expect(sameLineJSONMatches[1]["line_number"] as? Int == 2)
        #expect(sameLineSecondSubmatches?.first?["start"] as? Int == 5)

        let sameLineContextOutput = try run(["--json", "-A1", "needle", root.path("binary-same-line.dat")])
        let sameLineContextMessages = try sameLineContextOutput.map(jsonObject)
        #expect(sameLineContextMessages.map { $0["type"] as? String } == ["begin", "match", "match", "end", "summary"])

        try root.write(Data("\0needle\n".utf8), to: "binary-leading-nul.dat")
        let leadingContextOutput = try run(["--json", "-B1", "needle", root.path("binary-leading-nul.dat")])
        let leadingContextMessages = try leadingContextOutput.map(jsonObject)
        #expect(leadingContextMessages.map { $0["type"] as? String } == ["begin", "context", "match", "end", "summary"])

        try root.write(Data("a\0b\nneedle\n".utf8), to: "binary-later-line.dat")
        let laterLineOutput = try run(["--json", "-B1", "needle", root.path("binary-later-line.dat")])
        let laterLineMessages = try laterLineOutput.map(jsonObject)
        let laterLineContext = laterLineMessages[1]["data"] as? [String: Any]
        let laterLineContextLines = laterLineContext?["lines"] as? [String: String]
        let laterLineMatch = laterLineMessages[2]["data"] as? [String: Any]
        #expect(laterLineContextLines?["text"] == "b\n")
        #expect(laterLineContext?["line_number"] as? Int == 2)
        #expect(laterLineMatch?["line_number"] as? Int == 3)

        try root.write(Data("needle\0tail\nneedle\n".utf8), to: "binary-split-and-later.dat")
        let splitAndLaterOutput = try run(["--json", "-A1", "needle", root.path("binary-split-and-later.dat")])
        let splitAndLaterMessages = try splitAndLaterOutput.map(jsonObject)
        let splitAndLaterTypes = splitAndLaterMessages.map { $0["type"] as? String }
        let splitContext = splitAndLaterMessages[2]["data"] as? [String: Any]
        let splitContextLines = splitContext?["lines"] as? [String: String]
        let splitLaterMatch = splitAndLaterMessages[3]["data"] as? [String: Any]
        #expect(splitAndLaterTypes == ["begin", "match", "context", "match", "end", "summary"])
        #expect(splitContextLines?["text"] == "tail\n")
        #expect(splitContext?["line_number"] as? Int == 2)
        #expect(splitLaterMatch?["line_number"] as? Int == 3)

        try root.write(Data("needle\n\0tail needle\n".utf8), to: "binary-max-context.dat")
        let binaryMaxContextOutput = try run(["--json", "-m1", "-A2", "needle", root.path("binary-max-context.dat")])
        let binaryMaxContextMessages = try binaryMaxContextOutput.map(jsonObject)
        #expect(binaryMaxContextMessages.map { $0["type"] as? String } == [
            "begin",
            "match",
            "context",
            "match",
            "end",
            "summary",
        ])
        let binaryMaxContextEnd = binaryMaxContextMessages[4]["data"] as? [String: Any]
        let binaryMaxContextStats = binaryMaxContextEnd?["stats"] as? [String: Any]
        #expect(binaryMaxContextStats?["matched_lines"] as? Int == 2)
        #expect(binaryMaxContextStats?["matches"] as? Int == 2)

        let implicitBinary = try TemporaryDirectory()
        try implicitBinary.write(Data("needle\0tail\n".utf8), to: "bin.dat")
        var binaryStatsOutput: [String] = []
        var binaryStatsExitCode = RipgrepCLI.run(
            arguments: ["--stats", "needle", implicitBinary.url.path],
            stdout: { binaryStatsOutput.append($0) }
        )
        #expect(binaryStatsExitCode == 1)
        #expect(binaryStatsOutput.contains("1 files searched"))
        #expect(binaryStatsOutput.contains("0 bytes searched"))

        binaryStatsOutput = []
        binaryStatsExitCode = RipgrepCLI.run(
            arguments: ["--files-without-match", "needle", implicitBinary.url.path],
            stdout: { binaryStatsOutput.append($0) }
        )
        #expect(binaryStatsExitCode == 0)
        #expect(binaryStatsOutput.isEmpty)

        try assertExplicitIgnoreFileDoesNotExcludeExplicitSearchRoot()
    }

}

private func assertExplicitIgnoreFileDoesNotExcludeExplicitSearchRoot() throws {
    let root = try TemporaryDirectory()
    try root.createDirectory("target/sub")
    try root.write("needle\n", to: "target/sub/file.txt")
    try root.write("/target\n", to: "root.ignore")
    try root.write("/target/sub\n", to: "sub.ignore")
    try root.write("/target/sub/file.txt\n", to: "file.ignore")

    let originalDirectory = FileManager.default.currentDirectoryPath
    defer { FileManager.default.changeCurrentDirectoryPath(originalDirectory) }
    #expect(FileManager.default.changeCurrentDirectoryPath(root.url.path))

    #expect(try run([
        "--sort",
        "path",
        "--ignore-file",
        "root.ignore",
        "needle",
        "target",
    ]) == ["target/sub/file.txt:needle"])
    #expect(try run([
        "--sort",
        "path",
        "--ignore-file",
        "root.ignore",
        "--files",
        "target",
    ]) == ["target/sub/file.txt"])
    #expect(try runAllowingNoMatch([
        "--ignore-file",
        "sub.ignore",
        "needle",
        "target",
    ]) == [])
    #expect(try runAllowingNoMatch([
        "--ignore-file",
        "file.ignore",
        "needle",
        "target",
    ]) == [])
}
