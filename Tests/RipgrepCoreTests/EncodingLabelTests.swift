import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
import Testing
#if os(Windows)
import WinSDK
#endif
@testable import RipgrepCore

@Suite("Encoding Standard label support", .serialized)
struct EncodingLabelTests {
    @Test("supports representative WHATWG labels")
    func supportsRepresentativeLabels() throws {
        #if os(Windows)
        try assertMatch(label: "gbk", text: "中文", codePage: 936)
        try assertMatch(label: "gb2312", text: "中文", codePage: 936)
        try assertMatch(label: "big5", text: "中文", codePage: 950)
        try assertMatch(label: "gb18030", text: "𠀋", codePage: 54_936)
        try assertMatch(label: "shift-jis", text: "こんにちは", codePage: 932)
        try assertMatch(label: "euc-kr", text: "한국", codePage: 51_949)
        try assertMatch(label: "koi8-r", text: "Привет", codePage: 20_866)
        try assertMatch(label: "windows-1251", text: "Привет", codePage: 1_251)
        try assertMatch(label: "iso-8859-7", text: "αβγ", codePage: 28_597)
        #elseif os(macOS)
        try assertMatch(label: "gbk", text: "中文", encoding: .GBK_95)
        try assertMatch(label: "gb2312", text: "中文", encoding: .GBK_95)
        try assertMatch(label: "big5", text: "中文", encoding: .big5)
        try assertMatch(label: "gb18030", text: "𠀋", encoding: .GB_18030_2000)
        try assertMatch(label: "shift-jis", text: "こんにちは", encoding: .shiftJIS)
        try assertMatch(label: "euc-kr", text: "한국", encoding: .EUC_KR)
        try assertMatch(label: "koi8-r", text: "Привет", encoding: .KOI8_R)
        try assertMatch(label: "windows-1251", text: "Привет", encoding: .windowsCyrillic)
        try assertMatch(label: "iso-8859-7", text: "αβγ", encoding: .isoLatinGreek)
        #else
        try assertMatch(label: "gbk", text: "中文", encodedText: [0xD6, 0xD0, 0xCE, 0xC4])
        try assertMatch(label: "gb2312", text: "中文", encodedText: [0xD6, 0xD0, 0xCE, 0xC4])
        try assertMatch(label: "big5", text: "中文", encodedText: [0xA4, 0xA4, 0xA4, 0xE5])
        try assertMatch(label: "gb18030", text: "𠀋", encodedText: [0x95, 0x32, 0x83, 0x37])
        try assertMatch(
            label: "shift-jis",
            text: "こんにちは",
            encodedText: [0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF, 0x82, 0xCD]
        )
        try assertMatch(label: "euc-kr", text: "한국", encodedText: [0xC7, 0xD1, 0xB1, 0xB9])
        try assertMatch(label: "koi8-r", text: "Привет", encodedText: [0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4])
        try assertMatch(label: "windows-1251", text: "Привет", encodedText: [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2])
        try assertMatch(label: "iso-8859-7", text: "αβγ", encodedText: [0xE1, 0xE2, 0xE3])
        #endif
    }

    @Test("decodes Big5-HKSCS extensions for Big5 labels")
    func decodesBig5HKSCS() throws {
        try assertBytesMatch(label: "big5", text: "Á", bytes: Data([0x88, 0x57, 0x0A]))
        try assertBytesMatch(label: "big5-hkscs", text: "Á", bytes: Data([0x88, 0x57, 0x0A]))
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

    #if os(Windows)
    private func assertMatch(
        label: String,
        text: String,
        codePage: UInt32,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let root = try TemporaryDirectory()
        try root.write(try encoded("prefix \(text) suffix\n", codePage: codePage), to: "encoded.txt")

        let lines = try run(["--encoding", label, text, root.path("encoded.txt")])
        #expect(lines == ["prefix \(text) suffix"], sourceLocation: sourceLocation)
    }
    #elseif os(macOS)
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
    #else
    private func assertMatch(
        label: String,
        text: String,
        encodedText: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let bytes = Data(Array("prefix ".utf8) + encodedText + Array(" suffix\n".utf8))
        try assertBytesMatch(
            label: label,
            text: "prefix \(text) suffix",
            bytes: bytes,
            sourceLocation: sourceLocation
        )
    }
    #endif

    private func assertBytesMatch(
        label: String,
        text: String,
        bytes: Data,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let root = try TemporaryDirectory()
        try root.write(bytes, to: "encoded.txt")

        let lines = try run(["--encoding", label, text, root.path("encoded.txt")])
        #expect(lines == [text], sourceLocation: sourceLocation)
    }

    #if os(macOS)
    private func encoded(_ text: String, as encoding: CFStringEncodings) throws -> Data {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        let stringEncoding = String.Encoding(rawValue: raw)
        return try #require(text.data(using: stringEncoding))
    }
    #endif

    #if os(Windows)
    private func encoded(_ text: String, codePage: UInt32) throws -> Data {
        let utf16 = Array(text.utf16)
        let requiredCount = utf16.withUnsafeBufferPointer { source in
            WideCharToMultiByte(
                codePage,
                0,
                source.baseAddress,
                Int32(source.count),
                nil,
                0,
                nil,
                nil
            )
        }
        let count = try #require(requiredCount > 0 ? Int(requiredCount) : nil)
        var bytes = [CChar](repeating: 0, count: count)
        let writtenCount = utf16.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { destination in
                WideCharToMultiByte(
                    codePage,
                    0,
                    source.baseAddress,
                    Int32(source.count),
                    destination.baseAddress,
                    Int32(destination.count),
                    nil,
                    nil
                )
            }
        }
        try #require(writtenCount == requiredCount)
        return bytes.withUnsafeBytes { Data($0) }
    }
    #endif
}
