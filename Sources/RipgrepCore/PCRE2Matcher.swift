import CPCRE2
import Foundation

struct PCRE2Backend {
    static var versionDescription: String {
        let rawVersion = configString(rg_pcre2_config_version_key()) ?? "unknown"
        let version = rawVersion.split(separator: " ").first.map(String.init) ?? rawVersion
        let jitAvailable = configUInt32(rg_pcre2_config_jit_key()).map { $0 != 0 } ?? false
        return "PCRE2 \(version) is available (JIT is \(jitAvailable ? "available" : "unavailable"))"
    }

    private static func configString(_ key: UInt32) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            rg_pcre2_config(key, pointer.baseAddress)
        }
        guard status >= 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func configUInt32(_ key: UInt32) -> UInt32? {
        var value: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            rg_pcre2_config(key, pointer)
        }
        return status >= 0 ? value : nil
    }
}

final class PCRE2CompiledPattern {
    let source: String
    private let code: OpaquePointer
    private let utfEnabled: Bool

    init(pattern: String, options: RipgrepOptions) throws {
        self.source = pattern
        self.utfEnabled = !options.noUnicode
        var compileOptions: UInt32 = rg_pcre2_option_multiline()
        if options.effectiveIgnoreCase {
            compileOptions |= rg_pcre2_option_caseless()
        }
        if options.multiline && options.multilineDotall {
            compileOptions |= rg_pcre2_option_dotall()
        }
        if options.crlf {
            compileOptions |= rg_pcre2_option_newline_crlf()
        }
        if !options.noUnicode {
            compileOptions |= rg_pcre2_option_utf()
            compileOptions |= rg_pcre2_option_ucp()
        }

        var errorCode: Int32 = 0
        var errorOffset = 0
        let compiled = pattern.withCString { cString in
            rg_pcre2_compile(cString, pattern.utf8.count, compileOptions, &errorCode, &errorOffset)
        }
        guard let compiled else {
            throw RipgrepError.message(Self.compileErrorMessage(
                pattern: pattern,
                errorCode: Int(errorCode),
                errorOffset: errorOffset
            ))
        }
        self.code = compiled
        _ = rg_pcre2_jit_compile(compiled)
    }

    deinit {
        rg_pcre2_code_free(code)
    }

    func matches(in text: String) -> [PCRE2Match] {
        let bytes = Array(text.utf8)
        let length = bytes.count
        var output: [PCRE2Match] = []
        var startOffset = 0

        while startOffset <= length {
            guard let matchData = rg_pcre2_match_data_create_from_pattern(code) else {
                return output
            }
            defer {
                rg_pcre2_match_data_free(matchData)
            }

            let status: Int32
            if bytes.isEmpty {
                status = rg_pcre2_match(code, "", 0, startOffset, matchOptions, matchData)
            } else {
                status = bytes.withUnsafeBufferPointer { pointer in
                    rg_pcre2_match(
                        code,
                        UnsafeRawPointer(pointer.baseAddress!).assumingMemoryBound(to: CChar.self),
                        length,
                        startOffset,
                        matchOptions,
                        matchData
                    )
                }
            }

            if status == rg_pcre2_error_nomatch() {
                break
            }
            guard status >= 0,
                  let match = Self.match(from: matchData, captureCount: Int(status), in: text) else {
                break
            }
            output.append(match)

            if match.byteRange.lowerBound == match.byteRange.upperBound {
                guard startOffset < length else {
                    break
                }
                startOffset = Self.nextUTF8Boundary(after: startOffset, in: bytes, utfEnabled: utfEnabled)
            } else {
                startOffset = match.byteRange.upperBound
            }
        }
        return output
    }

    private var matchOptions: UInt32 { 0 }

    private static func match(
        from matchData: OpaquePointer,
        captureCount: Int,
        in text: String
    ) -> PCRE2Match? {
        guard let ovector = rg_pcre2_get_ovector_pointer(matchData) else {
            return nil
        }
        let availableCount = Int(rg_pcre2_get_ovector_count(matchData))
        let count = max(1, min(captureCount, availableCount))
        var captures: [Range<String.Index>?] = []
        captures.reserveCapacity(count)
        var byteCaptures: [Range<Int>?] = []
        byteCaptures.reserveCapacity(count)

        for index in 0..<count {
            let start = Int(ovector[index * 2])
            let end = Int(ovector[index * 2 + 1])
            if start < 0 || end < start {
                captures.append(nil)
                byteCaptures.append(nil)
                continue
            }
            guard let lower = stringIndex(in: text, atUTF8Offset: start),
                  let upper = stringIndex(in: text, atUTF8Offset: end) else {
                return nil
            }
            captures.append(lower..<upper)
            byteCaptures.append(start..<end)
        }

        guard let range = captures.first ?? nil,
              let byteRange = byteCaptures.first ?? nil else {
            return nil
        }
        return PCRE2Match(range: range, byteRange: byteRange, captures: captures)
    }

    private static func stringIndex(in text: String, atUTF8Offset offset: Int) -> String.Index? {
        guard offset >= 0 else {
            return nil
        }
        if offset == 0 {
            return text.startIndex
        }
        var bytes = 0
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            bytes += text[index].utf8.count
            if bytes == offset {
                return next
            }
            if bytes > offset {
                return nil
            }
            index = next
        }
        return bytes == offset ? text.endIndex : nil
    }

    private static func nextUTF8Boundary(after offset: Int, in bytes: [UInt8], utfEnabled: Bool) -> Int {
        guard utfEnabled else {
            return offset + 1
        }
        var next = offset + 1
        while next < bytes.count, bytes[next] & 0xC0 == 0x80 {
            next += 1
        }
        return next
    }

    private static func compileErrorMessage(pattern: String, errorCode: Int, errorOffset: Int) -> String {
        let message = pcre2ErrorMessage(errorCode) ?? "error code \(errorCode)"
        return """
        PCRE2: error compiling pattern at offset \(errorOffset): \(message)
        \(pattern)
        \(String(repeating: " ", count: max(0, errorOffset)))^
        """
    }

    private static func pcre2ErrorMessage(_ code: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            rg_pcre2_get_error_message(Int32(code), pointer.baseAddress, pointer.count)
        }
        guard status >= 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}

struct PCRE2Match {
    let range: Range<String.Index>
    let byteRange: Range<Int>
    let captures: [Range<String.Index>?]
}
