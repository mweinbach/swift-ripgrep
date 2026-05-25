import Foundation
import Testing
@testable import RipgrepCore

@Suite("Haystack reader", .serialized)
struct HaystackReaderTests {
    @Test("small files use the platform automatic reader")
    func smallFilesUsePlatformAutomaticReader() throws {
        let root = try TemporaryDirectory()
        try root.write("hello\n", to: "small.txt")
        let options = RipgrepOptions()

        #if canImport(Darwin)
        let expectedPath = HaystackReader.ReadPath.mmap
        #else
        let expectedPath = HaystackReader.ReadPath.buffered
        #endif

        #expect(try HaystackReader.selectedPath(forFileAt: URL(fileURLWithPath: root.path("small.txt")), options: options) == expectedPath)
        #expect(try HaystackReader.read(Haystack(url: URL(fileURLWithPath: root.path("small.txt")), isExplicit: true), options: options) == Data("hello\n".utf8))
    }

    @Test("large files use mmap automatically")
    func largeFilesUseMmapAutomatically() throws {
        let root = try TemporaryDirectory()
        let contents = String(repeating: "a", count: Int(HaystackReader.automaticMmapThreshold) + 1)
        try root.write(contents, to: "large.txt")
        let options = RipgrepOptions()

        #expect(try HaystackReader.selectedPath(forFileAt: URL(fileURLWithPath: root.path("large.txt")), options: options) == .mmap)
        #expect(try HaystackReader.read(Haystack(url: URL(fileURLWithPath: root.path("large.txt")), isExplicit: true), options: options) == Data(contents.utf8))
    }

    @Test("--mmap forces mmap")
    func mmapFlagForcesMmap() throws {
        let root = try TemporaryDirectory()
        try root.write("forced mmap\n", to: "forced.txt")
        var options = RipgrepOptions()
        options.mmapMode = .always

        #expect(try HaystackReader.selectedPath(forFileAt: URL(fileURLWithPath: root.path("forced.txt")), options: options) == .mmap)
        #expect(try HaystackReader.read(Haystack(url: URL(fileURLWithPath: root.path("forced.txt")), isExplicit: true), options: options) == Data("forced mmap\n".utf8))
    }

    @Test("--no-mmap forces buffered reads")
    func noMmapFlagForcesBufferedReads() throws {
        let root = try TemporaryDirectory()
        let contents = String(repeating: "b", count: Int(HaystackReader.automaticMmapThreshold) + 1)
        try root.write(contents, to: "buffered.txt")
        var options = RipgrepOptions()
        options.mmapMode = .never

        #expect(try HaystackReader.selectedPath(forFileAt: URL(fileURLWithPath: root.path("buffered.txt")), options: options) == .buffered)
        #expect(try HaystackReader.read(Haystack(url: URL(fileURLWithPath: root.path("buffered.txt")), isExplicit: true), options: options) == Data(contents.utf8))
    }

    @Test("automatic mode falls back to buffered for non-regular inputs")
    func automaticModeFallsBackToBufferedForNonRegularInputs() throws {
        let options = RipgrepOptions()
        #expect(HaystackReader.selectedPath(fileSize: HaystackReader.automaticMmapThreshold + 1, isRegularFile: false, options: options) == .buffered)

        #if os(macOS)
        let devNull = URL(fileURLWithPath: "/dev/null")
        #expect(try HaystackReader.selectedPath(forFileAt: devNull, options: options) == .buffered)
        #expect(try HaystackReader.read(Haystack(url: devNull, isExplicit: true), options: options).isEmpty)
        #endif
    }

    @Test("--mmap reports a useful error for non-regular inputs")
    func mmapReportsUsefulErrorForNonRegularInputs() throws {
        #if os(macOS)
        var options = RipgrepOptions()
        options.mmapMode = .always
        let devNull = URL(fileURLWithPath: "/dev/null")

        #expect(throws: HaystackReader.ReaderError.self) {
            try HaystackReader.read(Haystack(url: devNull, isExplicit: true), options: options)
        }
        #else
        return
        #endif
    }

    @Test("chunk boundaries preserve multiline matches")
    func chunkBoundariesPreserveMultilineMatches() throws {
        let root = try TemporaryDirectory()
        let prefix = String(repeating: "x", count: HaystackReader.bufferedChunkSize - 2)
        let suffix = String(repeating: "z", count: 200 * 1024 - prefix.utf8.count - "foo\nbar\n".utf8.count)
        try root.write(prefix + "foo\nbar\n" + suffix, to: "boundary.txt")

        #expect(try run(["-U", "-o", #"foo\nbar"#, root.path("boundary.txt")]) == [
            "foo",
            "bar",
        ])
    }
}
