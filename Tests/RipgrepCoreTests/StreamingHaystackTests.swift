import Foundation
import Testing
@testable import RipgrepCore

@Suite("Streaming haystack", .serialized)
struct StreamingHaystackTests {
    @Test("plain single-file matching lines can stream directly to output")
    func plainSingleFileMatchingLinesCanStreamDirectlyToOutput() throws {
        let root = try TemporaryDirectory()
        let fileURL = URL(fileURLWithPath: root.path("large-direct-output.txt"))
        let blockCount = 32 * 1024
        try writeAlternatingBlocks(to: fileURL, blockCount: blockCount, blockSize: 1024)

        var options = RipgrepOptions()
        options.pattern = "A|B|C|D|E"
        options.roots = [fileURL]
        options.rootPathArguments = [fileURL.path]

        var output: [String] = []
        let results = try #require(RipgrepSearcher().streamPlainMatchingLines(options: options) { line in
            output.append(line)
        })

        #expect(output.count == blockCount)
        #expect(output.allSatisfy { $0.hasPrefix("A ") || $0.hasPrefix("z ") })
        #expect(results.summary.filesSearched == 1)
        #expect(results.summary.filesWithMatches == 1)
        #expect(results.summary.matchedLines == blockCount)
        #expect(results.files.first?.matches.isEmpty == true)
        #expect(results.files.first?.supplementalMatchedLines == blockCount)
    }

    @Test("plain direct output declines formatted searches")
    func plainDirectOutputDeclinesFormattedSearches() throws {
        let root = try TemporaryDirectory()
        try root.write("A one\nB two\n", to: "formatted.txt")
        let fileURL = URL(fileURLWithPath: root.path("formatted.txt"))

        var options = RipgrepOptions()
        options.pattern = "A|B"
        options.roots = [fileURL]
        options.rootPathArguments = [fileURL.path]
        options.lineNumber = true

        let results = try RipgrepSearcher().streamPlainMatchingLines(options: options) { _ in
            Issue.record("formatted searches should use the normal printer path")
        }
        #expect(results == nil)
    }

    @Test("large --no-mmap search streams within the perf smoke budget")
    func largeNoMmapSearchStreamsWithinPerfSmokeBudget() throws {
        let root = try TemporaryDirectory()
        let fileURL = URL(fileURLWithPath: root.path("large-streaming.txt"))
        let blockCount = 64 * 1024
        try writeSyntheticBlocks(
            to: fileURL,
            blockCount: blockCount,
            marker: "needle\n",
            blockSize: 1024
        )

        let started = Date()
        let output = try run(["--no-mmap", "--count", "needle", fileURL.path])
        let elapsed = Date().timeIntervalSince(started)

        #expect(output == ["\(blockCount)"])
        #expect(elapsed < 10.0)
    }

    @Test("streaming --no-mmap output matches mmap output for repeated Sherlock haystack")
    func streamingOutputMatchesMmapOutputForRepeatedSherlockHaystack() throws {
        let root = try TemporaryDirectory()
        let repetitions = 4096
        try root.write(String(repeating: SHERLOCK, count: repetitions), to: "sherlock-large.txt")
        let path = root.path("sherlock-large.txt")

        let mmapOutput = try run(["--line-number", "Sherlock", path])
        let streamingOutput = try run(["--no-mmap", "--line-number", "Sherlock", path])

        #expect(streamingOutput == mmapOutput)
    }

    @Test("buffered accumulation enforces max buffer limit")
    func bufferedAccumulationEnforcesMaxBufferLimit() throws {
        let root = try TemporaryDirectory()
        try root.write("abcdef", to: "too-large.txt")
        var options = RipgrepOptions()
        options.mmapMode = .never

        do {
            _ = try HaystackReader.read(
                Haystack(url: URL(fileURLWithPath: root.path("too-large.txt")), isExplicit: true),
                options: options,
                maxBufferBytes: 4
            )
            Issue.record("expected HaystackReader.read to enforce the max buffer limit")
        } catch {
            #expect(String(describing: error) == "haystack size 6 exceeds buffered limit 4; use --mmap or shrink --max-filesize")
        }
    }

    private func writeSyntheticBlocks(
        to fileURL: URL,
        blockCount: Int,
        marker: String,
        blockSize: Int
    ) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        let markerData = Data(marker.utf8)
        let padding = Data(repeating: UInt8(ascii: "x"), count: blockSize - markerData.count)
        var block = Data()
        block.reserveCapacity(blockSize)
        block.append(markerData)
        block.append(padding)

        for _ in 0..<blockCount {
            try handle.write(contentsOf: block)
        }
    }

    private func writeAlternatingBlocks(
        to fileURL: URL,
        blockCount: Int,
        blockSize: Int
    ) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        for index in 0..<blockCount {
            let marker = index.isMultiple(of: 2) ? "A " : "z E "
            let markerData = Data(marker.utf8)
            let padding = Data(repeating: UInt8(ascii: "x"), count: blockSize - markerData.count - 1)
            var block = Data()
            block.reserveCapacity(blockSize)
            block.append(markerData)
            block.append(padding)
            block.append(UInt8(ascii: "\n"))
            try handle.write(contentsOf: block)
        }
    }
}
