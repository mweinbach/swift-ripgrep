import Foundation

enum PathSort {
    static func compare(_ lhs: URL, _ rhs: URL) -> ComparisonResult {
        compare(lhs.pathComponents, rhs.pathComponents)
    }

    static func components(for url: URL) -> [String] {
        url.pathComponents
    }

    static func compare(_ lhsComponents: [String], _ rhsComponents: [String]) -> ComparisonResult {
        for (lhsComponent, rhsComponent) in zip(lhsComponents, rhsComponents) {
            if lhsComponent == rhsComponent {
                continue
            }
            return lhsComponent < rhsComponent ? .orderedAscending : .orderedDescending
        }
        if lhsComponents.count == rhsComponents.count {
            return .orderedSame
        }
        return lhsComponents.count < rhsComponents.count ? .orderedAscending : .orderedDescending
    }

    static func components(forPath path: String) -> [Substring] {
        #if os(Windows)
        return path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        #else
        path.split(separator: "/", omittingEmptySubsequences: false)
        #endif
    }

    static func byteKey(forPath path: String, droppingFirstBytes droppedByteCount: Int = 0) -> [UInt8] {
        var key: [UInt8] = []
        var path = path
        path.withUTF8 { bytes in
            let start = min(droppedByteCount, bytes.count)
            key.reserveCapacity(bytes.count - start)
            var index = start
            while index < bytes.count {
                let byte = bytes[index]
                #if os(Windows)
                key.append(byte == UInt8(ascii: "/") || byte == UInt8(ascii: "\\") ? 0 : byte)
                #else
                key.append(byte == UInt8(ascii: "/") ? 0 : byte)
                #endif
                index += 1
            }
        }
        return key
    }

    static func compare(_ lhsComponents: [Substring], _ rhsComponents: [Substring]) -> ComparisonResult {
        for (lhsComponent, rhsComponent) in zip(lhsComponents, rhsComponents) {
            if lhsComponent == rhsComponent {
                continue
            }
            return lhsComponent < rhsComponent ? .orderedAscending : .orderedDescending
        }
        if lhsComponents.count == rhsComponents.count {
            return .orderedSame
        }
        return lhsComponents.count < rhsComponents.count ? .orderedAscending : .orderedDescending
    }
}
