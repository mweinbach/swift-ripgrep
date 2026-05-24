import Foundation
import Testing
@testable import RipgrepCore

@Suite("Worker pool search", .serialized)
struct WorkerPoolTests {
    @Test("threaded search output is deterministic")
    func threadedSearchOutputIsDeterministic() throws {
        let root = try TemporaryDirectory()
        let fileNames = (1...24).map { String(format: "file-%02d.txt", $0) }
        for (offset, name) in fileNames.enumerated() {
            try root.write("preamble \(offset)\nmatch \(offset)\n", to: name)
        }

        let filePaths = fileNames.map(root.path)
        let arguments = ["--threads", "8", "match"] + filePaths
        let first = try run(arguments)
        #expect(first.count == fileNames.count)

        for _ in 0..<7 {
            #expect(try run(arguments) == first)
        }
    }

    @Test("threads one uses sequential fallback output")
    func threadsOneUsesSequentialFallbackOutput() throws {
        let root = try TemporaryDirectory()
        try root.write("alpha\nmatch first\n", to: "a.txt")
        try root.write("match second\nomega\n", to: "b.txt")

        let files = [root.path("a.txt"), root.path("b.txt")]
        let sequential = try run(["match"] + files)
        let forcedSequential = try run(["--threads", "1", "match"] + files)

        #expect(forcedSequential == sequential)
        #expect(forcedSequential.count == 2)
    }
}
