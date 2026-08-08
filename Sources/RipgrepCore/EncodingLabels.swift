import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if os(Windows)
import WinSDK
#endif

public struct TextEncoding: Equatable, Sendable {
    fileprivate enum Decoder: Equatable, Sendable {
        case foundation(String.Encoding)
        case windowsCodePage(UInt32)
        case windows1252
        case replacement
        case xUserDefined
    }

    public let name: String
    fileprivate let decoder: Decoder

    private init(name: String, decoder: Decoder) {
        self.name = name
        self.decoder = decoder
    }

    public static let utf8 = TextEncoding(name: "UTF-8", decoder: .foundation(.utf8))
    public static let utf16LittleEndian = TextEncoding(name: "UTF-16LE", decoder: .foundation(.utf16LittleEndian))
    public static let utf16BigEndian = TextEncoding(name: "UTF-16BE", decoder: .foundation(.utf16BigEndian))
    public static let windows1252 = TextEncoding(name: "windows-1252", decoder: .windows1252)
    public static let replacement = TextEncoding(name: "replacement", decoder: .replacement)
    public static let xUserDefined = TextEncoding(name: "x-user-defined", decoder: .xUserDefined)

    public static func foundation(_ name: String, _ encoding: String.Encoding) -> TextEncoding {
        TextEncoding(name: name, decoder: .foundation(encoding))
    }

    #if !os(Windows)
    public static func coreFoundation(_ name: String, _ encoding: CFStringEncodings) -> TextEncoding {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        return .foundation(name, String.Encoding(rawValue: raw))
    }
    #endif

    public static func windowsCodePage(_ name: String, _ codePage: UInt32) -> TextEncoding {
        TextEncoding(name: name, decoder: .windowsCodePage(codePage))
    }

    var isUTF16: Bool {
        switch decoder {
        case .foundation(let encoding):
            return encoding == .utf16 || encoding == .utf16LittleEndian || encoding == .utf16BigEndian
        case .windowsCodePage, .windows1252, .replacement, .xUserDefined:
            return false
        }
    }

    func decode(_ data: Data) -> String {
        switch decoder {
        case .foundation(let encoding):
            return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
        case .windowsCodePage(let codePage):
            return decodeWindowsCodePage(data, codePage: codePage)
        case .windows1252:
            return decodeWindows1252(data)
        case .replacement:
            return String(repeating: "\u{FFFD}", count: data.count)
        case .xUserDefined:
            return decodeXUserDefined(data)
        }
    }

    static func encoding(forLabel raw: String) -> TextEncoding? {
        labelTable[normalizedLabel(raw)]
    }

    public static func isKnownLabel(_ raw: String) -> Bool {
        encoding(forLabel: raw) != nil
    }

    private static func normalizedLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: asciiWhitespace).lowercased()
    }

    private static let asciiWhitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000C}\u{000D}\u{0020}")

    #if os(Windows)
    private static let ibm866 = windowsCodePage("IBM866", 866)
    private static let iso8859_2 = windowsCodePage("ISO-8859-2", 28_592)
    private static let iso8859_3 = windowsCodePage("ISO-8859-3", 28_593)
    private static let iso8859_4 = windowsCodePage("ISO-8859-4", 28_594)
    private static let iso8859_5 = windowsCodePage("ISO-8859-5", 28_595)
    private static let iso8859_6 = windowsCodePage("ISO-8859-6", 28_596)
    private static let iso8859_7 = windowsCodePage("ISO-8859-7", 28_597)
    private static let iso8859_8 = windowsCodePage("ISO-8859-8", 28_598)
    private static let iso8859_10 = windowsCodePage("ISO-8859-10", 28_600)
    private static let iso8859_13 = windowsCodePage("ISO-8859-13", 28_603)
    private static let iso8859_14 = windowsCodePage("ISO-8859-14", 28_604)
    private static let iso8859_15 = windowsCodePage("ISO-8859-15", 28_605)
    private static let iso8859_16 = windowsCodePage("ISO-8859-16", 28_606)
    private static let koi8r = windowsCodePage("KOI8-R", 20_866)
    private static let koi8u = windowsCodePage("KOI8-U", 21_866)
    private static let macintosh = windowsCodePage("macintosh", 10_000)
    private static let windows874 = windowsCodePage("windows-874", 874)
    private static let windows1250 = windowsCodePage("windows-1250", 1_250)
    private static let windows1251 = windowsCodePage("windows-1251", 1_251)
    private static let windows1253 = windowsCodePage("windows-1253", 1_253)
    private static let windows1254 = windowsCodePage("windows-1254", 1_254)
    private static let windows1255 = windowsCodePage("windows-1255", 1_255)
    private static let windows1256 = windowsCodePage("windows-1256", 1_256)
    private static let windows1257 = windowsCodePage("windows-1257", 1_257)
    private static let windows1258 = windowsCodePage("windows-1258", 1_258)
    private static let xMacCyrillic = windowsCodePage("x-mac-cyrillic", 10_007)
    private static let gbk = windowsCodePage("GBK", 936)
    private static let gb18030 = windowsCodePage("gb18030", 54_936)
    private static let big5 = windowsCodePage("Big5", 950)
    private static let eucJP = windowsCodePage("EUC-JP", 51_932)
    private static let iso2022JP = windowsCodePage("ISO-2022-JP", 50_220)
    private static let shiftJIS = windowsCodePage("Shift_JIS", 932)
    private static let eucKR = windowsCodePage("EUC-KR", 51_949)
    #else
    private static let ibm866 = coreFoundation("IBM866", .dosRussian)
    private static let iso8859_2 = coreFoundation("ISO-8859-2", .isoLatin2)
    private static let iso8859_3 = coreFoundation("ISO-8859-3", .isoLatin3)
    private static let iso8859_4 = coreFoundation("ISO-8859-4", .isoLatin4)
    private static let iso8859_5 = coreFoundation("ISO-8859-5", .isoLatinCyrillic)
    private static let iso8859_6 = coreFoundation("ISO-8859-6", .isoLatinArabic)
    private static let iso8859_7 = coreFoundation("ISO-8859-7", .isoLatinGreek)
    private static let iso8859_8 = coreFoundation("ISO-8859-8", .isoLatinHebrew)
    private static let iso8859_10 = coreFoundation("ISO-8859-10", .isoLatin6)
    private static let iso8859_13 = coreFoundation("ISO-8859-13", .isoLatin7)
    private static let iso8859_14 = coreFoundation("ISO-8859-14", .isoLatin8)
    private static let iso8859_15 = coreFoundation("ISO-8859-15", .isoLatin9)
    private static let iso8859_16 = coreFoundation("ISO-8859-16", .isoLatin10)
    private static let koi8r = coreFoundation("KOI8-R", .KOI8_R)
    private static let koi8u = coreFoundation("KOI8-U", .KOI8_U)
    private static let macintosh = foundation("macintosh", .macOSRoman)
    private static let windows874 = coreFoundation("windows-874", .dosThai)
    private static let windows1250 = coreFoundation("windows-1250", .windowsLatin2)
    private static let windows1251 = coreFoundation("windows-1251", .windowsCyrillic)
    private static let windows1253 = coreFoundation("windows-1253", .windowsGreek)
    private static let windows1254 = coreFoundation("windows-1254", .windowsLatin5)
    private static let windows1255 = coreFoundation("windows-1255", .windowsHebrew)
    private static let windows1256 = coreFoundation("windows-1256", .windowsArabic)
    private static let windows1257 = coreFoundation("windows-1257", .windowsBalticRim)
    private static let windows1258 = coreFoundation("windows-1258", .windowsVietnamese)
    private static let xMacCyrillic = coreFoundation("x-mac-cyrillic", .macCyrillic)
    private static let gbk = coreFoundation("GBK", .GBK_95)
    private static let gb18030 = coreFoundation("gb18030", .GB_18030_2000)
    private static let big5 = coreFoundation("Big5", .big5_HKSCS_1999)
    private static let eucJP = coreFoundation("EUC-JP", .EUC_JP)
    private static let iso2022JP = coreFoundation("ISO-2022-JP", .ISO_2022_JP)
    private static let shiftJIS = coreFoundation("Shift_JIS", .shiftJIS)
    private static let eucKR = coreFoundation("EUC-KR", .EUC_KR)
    #endif

    private static let labelTable: [String: TextEncoding] = {
        var table: [String: TextEncoding] = [:]
        func add(_ encoding: TextEncoding, _ labels: String...) {
            for label in labels {
                table[label] = encoding
            }
        }

        add(.utf8, "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "utf-8", "utf8", "x-unicode20utf8")
        add(ibm866, "866", "cp866", "csibm866", "ibm866")
        add(iso8859_2, "csisolatin2", "iso-8859-2", "iso-ir-101", "iso8859-2", "iso88592", "iso_8859-2", "iso_8859-2:1987", "l2", "latin2")
        add(iso8859_3, "csisolatin3", "iso-8859-3", "iso-ir-109", "iso8859-3", "iso88593", "iso_8859-3", "iso_8859-3:1988", "l3", "latin3")
        add(iso8859_4, "csisolatin4", "iso-8859-4", "iso-ir-110", "iso8859-4", "iso88594", "iso_8859-4", "iso_8859-4:1988", "l4", "latin4")
        add(iso8859_5, "csisolatincyrillic", "cyrillic", "iso-8859-5", "iso-ir-144", "iso8859-5", "iso88595", "iso_8859-5", "iso_8859-5:1988")
        add(iso8859_6, "arabic", "asmo-708", "csiso88596e", "csiso88596i", "csisolatinarabic", "ecma-114", "iso-8859-6", "iso-8859-6-e", "iso-8859-6-i", "iso-ir-127", "iso8859-6", "iso88596", "iso_8859-6", "iso_8859-6:1987")
        add(iso8859_7, "csisolatingreek", "ecma-118", "elot_928", "greek", "greek8", "iso-8859-7", "iso-ir-126", "iso8859-7", "iso88597", "iso_8859-7", "iso_8859-7:1987", "sun_eu_greek")
        add(iso8859_8, "csiso88598e", "csisolatinhebrew", "hebrew", "iso-8859-8", "iso-8859-8-e", "iso-ir-138", "iso8859-8", "iso88598", "iso_8859-8", "iso_8859-8:1988", "visual", "csiso88598i", "iso-8859-8-i", "logical")
        add(iso8859_10, "csisolatin6", "iso-8859-10", "iso-ir-157", "iso8859-10", "iso885910", "l6", "latin6")
        add(iso8859_13, "iso-8859-13", "iso8859-13", "iso885913")
        add(iso8859_14, "iso-8859-14", "iso8859-14", "iso885914")
        add(iso8859_15, "csisolatin9", "iso-8859-15", "iso8859-15", "iso885915", "iso_8859-15", "l9")
        add(iso8859_16, "iso-8859-16")
        add(koi8r, "cskoi8r", "koi", "koi8", "koi8-r", "koi8_r")
        add(koi8u, "koi8-ru", "koi8-u")
        add(macintosh, "csmacintosh", "mac", "macintosh", "x-mac-roman")
        add(windows874, "dos-874", "iso-8859-11", "iso8859-11", "iso885911", "tis-620", "windows-874")
        add(windows1250, "cp1250", "windows-1250", "x-cp1250")
        add(windows1251, "cp1251", "windows-1251", "x-cp1251")
        add(.windows1252, "ansi_x3.4-1968", "ascii", "cp1252", "cp819", "csisolatin1", "ibm819", "iso-8859-1", "iso-ir-100", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987", "l1", "latin1", "us-ascii", "windows-1252", "x-cp1252")
        add(windows1253, "cp1253", "windows-1253", "x-cp1253")
        add(windows1254, "cp1254", "csisolatin5", "iso-8859-9", "iso-ir-148", "iso8859-9", "iso88599", "iso_8859-9", "iso_8859-9:1989", "l5", "latin5", "windows-1254", "x-cp1254")
        add(windows1255, "cp1255", "windows-1255", "x-cp1255")
        add(windows1256, "cp1256", "windows-1256", "x-cp1256")
        add(windows1257, "cp1257", "windows-1257", "x-cp1257")
        add(windows1258, "cp1258", "windows-1258", "x-cp1258")
        add(xMacCyrillic, "x-mac-cyrillic", "x-mac-ukrainian")
        add(gbk, "chinese", "csgb2312", "csiso58gb231280", "gb2312", "gb_2312", "gb_2312-80", "gbk", "iso-ir-58", "x-gbk")
        add(gb18030, "gb18030")
        add(big5, "big5", "big5-hkscs", "cn-big5", "csbig5", "x-x-big5")
        add(eucJP, "cseucpkdfmtjapanese", "euc-jp", "x-euc-jp")
        add(iso2022JP, "csiso2022jp", "iso-2022-jp")
        add(shiftJIS, "csshiftjis", "ms932", "ms_kanji", "shift-jis", "shift_jis", "sjis", "windows-31j", "x-sjis")
        add(eucKR, "cseuckr", "csksc56011987", "euc-kr", "iso-ir-149", "korean", "ks_c_5601-1987", "ks_c_5601-1989", "ksc5601", "ksc_5601", "windows-949")
        add(.replacement, "hz-gb-2312", "iso-2022-cn", "iso-2022-cn-ext", "iso-2022-kr", "replacement")
        add(.utf16BigEndian, "unicodefffe", "utf-16be", "utf16be")
        add(.utf16LittleEndian, "csunicode", "iso-10646-ucs-2", "ucs-2", "unicode", "unicodefeff", "utf-16", "utf-16le", "utf16", "utf16le")
        add(.xUserDefined, "x-user-defined")
        return table
    }()

    private func decodeWindows1252(_ data: Data) -> String {
        let scalars = data.map { byte -> UnicodeScalar in
            switch byte {
            case 0x80: return "\u{20AC}"
            case 0x82: return "\u{201A}"
            case 0x83: return "\u{0192}"
            case 0x84: return "\u{201E}"
            case 0x85: return "\u{2026}"
            case 0x86: return "\u{2020}"
            case 0x87: return "\u{2021}"
            case 0x88: return "\u{02C6}"
            case 0x89: return "\u{2030}"
            case 0x8A: return "\u{0160}"
            case 0x8B: return "\u{2039}"
            case 0x8C: return "\u{0152}"
            case 0x8E: return "\u{017D}"
            case 0x91: return "\u{2018}"
            case 0x92: return "\u{2019}"
            case 0x93: return "\u{201C}"
            case 0x94: return "\u{201D}"
            case 0x95: return "\u{2022}"
            case 0x96: return "\u{2013}"
            case 0x97: return "\u{2014}"
            case 0x98: return "\u{02DC}"
            case 0x99: return "\u{2122}"
            case 0x9A: return "\u{0161}"
            case 0x9B: return "\u{203A}"
            case 0x9C: return "\u{0153}"
            case 0x9E: return "\u{017E}"
            case 0x9F: return "\u{0178}"
            default: return UnicodeScalar(UInt32(byte))!
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func decodeWindowsCodePage(_ data: Data, codePage: UInt32) -> String {
        #if os(Windows)
        guard !data.isEmpty else {
            return ""
        }
        let icuConverterName: String? = switch codePage {
        case 950: "big5-hkscs"
        case 936: "gbk"
        case 54_936: "gb18030"
        case 51_932: "euc-jp"
        case 50_220: "iso-2022-jp"
        case 932: "shift_jis"
        case 51_949: "euc-kr"
        default: nil
        }
        if let icuConverterName,
           let decoded = decodeWithFoundationICU(data, converterName: icuConverterName) {
            return decoded
        }
        let requiredCount = data.withUnsafeBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return 0
            }
            return MultiByteToWideChar(codePage, 0, baseAddress, Int32(bytes.count), nil, 0)
        }
        guard requiredCount > 0 else {
            return String(decoding: data, as: UTF8.self)
        }
        var utf16 = [WCHAR](repeating: 0, count: Int(requiredCount))
        let writtenCount = data.withUnsafeBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return 0
            }
            return utf16.withUnsafeMutableBufferPointer { destination in
                MultiByteToWideChar(
                    codePage,
                    0,
                    baseAddress,
                    Int32(bytes.count),
                    destination.baseAddress,
                    requiredCount
                )
            }
        }
        guard writtenCount > 0 else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: utf16.prefix(Int(writtenCount)), as: UTF16.self)
        #else
        return String(decoding: data, as: UTF8.self)
        #endif
    }

    #if os(Windows)
    private func decodeWithFoundationICU(_ data: Data, converterName: String) -> String? {
        typealias OpenConverter = @convention(c) (
            UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?
        ) -> OpaquePointer?
        typealias CloseConverter = @convention(c) (OpaquePointer?) -> Void
        typealias ConvertToUTF16 = @convention(c) (
            OpaquePointer?, UnsafeMutablePointer<UInt16>?, Int32,
            UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<Int32>?
        ) -> Int32

        let libraryName = Array("_FoundationICU.dll".utf16) + [0]
        guard let module = libraryName.withUnsafeBufferPointer({ name in
            GetModuleHandleW(name.baseAddress) ?? LoadLibraryW(name.baseAddress)
        }) else {
            return nil
        }
        guard let openAddress = GetProcAddress(module, "swift_ucnv_open"),
              let closeAddress = GetProcAddress(module, "swift_ucnv_close"),
              let convertAddress = GetProcAddress(module, "swift_ucnv_toUChars") else {
            return nil
        }
        let open = unsafeBitCast(openAddress, to: OpenConverter.self)
        let close = unsafeBitCast(closeAddress, to: CloseConverter.self)
        let convert = unsafeBitCast(convertAddress, to: ConvertToUTF16.self)

        var status: Int32 = 0
        guard let converter = converterName.withCString({ open($0, &status) }), status <= 0 else {
            return nil
        }
        defer { close(converter) }

        let requiredCount = data.withUnsafeBytes { bytes -> Int32 in
            guard let source = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return 0
            }
            status = 0
            return convert(converter, nil, 0, source, Int32(bytes.count), &status)
        }
        guard requiredCount > 0 else {
            return nil
        }
        var utf16 = [UInt16](repeating: 0, count: Int(requiredCount))
        let writtenCount = data.withUnsafeBytes { bytes -> Int32 in
            guard let source = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return 0
            }
            status = 0
            return utf16.withUnsafeMutableBufferPointer { destination in
                convert(
                    converter,
                    destination.baseAddress,
                    Int32(destination.count),
                    source,
                    Int32(bytes.count),
                    &status
                )
            }
        }
        guard status <= 0, writtenCount > 0 else {
            return nil
        }
        return String(decoding: utf16.prefix(Int(writtenCount)), as: UTF16.self)
    }
    #endif

    private func decodeXUserDefined(_ data: Data) -> String {
        let scalars = data.map { byte -> UnicodeScalar in
            if byte < 0x80 {
                return UnicodeScalar(UInt32(byte))!
            }
            return UnicodeScalar(0xF780 + UInt32(byte) - 0x80)!
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
