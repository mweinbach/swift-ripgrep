import Foundation
import Testing
@testable import RipgrepCore

@Suite("Encoding Standard label support", .serialized)
struct EncodingLabelTests {
    @Test("supports representative WHATWG labels")
    func supportsRepresentativeLabels() throws {
        try assertMatch(label: "gbk", text: "中文", encoding: .GBK_95)
        try assertMatch(label: "gb2312", text: "中文", encoding: .GBK_95)
        try assertMatch(label: "big5", text: "中文", encoding: .big5)
        try assertMatch(label: "koi8-r", text: "Привет", encoding: .KOI8_R)
        try assertMatch(label: "windows-1251", text: "Привет", encoding: .windowsCyrillic)
        try assertMatch(label: "iso-8859-7", text: "αβγ", encoding: .isoLatinGreek)
    }

    @Test("reports Rust-compatible unknown encoding errors")
    func reportsUnknownEncodingError() {
        var output: [String] = []
        var errors: [String] = []
        let exitCode = RipgrepCLI.run(
            arguments: ["--encoding", "nope", "needle", "/etc/hosts"],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(output.isEmpty)
        #expect(exitCode == 2)
        #expect(errors == ["rg: error parsing flag --encoding: grep config error: unknown encoding: nope"])
    }

    private func assertMatch(
        label: String,
        text: String,
        encoding: CFStringEncodings,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let root = try TemporaryDirectory()
        try root.write(try encoded("prefix \(text) suffix\n", as: encoding), to: "encoded.txt")

        let lines = try run(["--encoding", label, text, root.path("encoded.txt")])
        #expect(lines == ["prefix \(text) suffix"], sourceLocation: sourceLocation)
    }

    private func encoded(_ text: String, as encoding: CFStringEncodings) throws -> Data {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        let stringEncoding = String.Encoding(rawValue: raw)
        return try #require(text.data(using: stringEncoding))
    }
}
