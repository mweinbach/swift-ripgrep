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
        path.split(separator: "/", omittingEmptySubsequences: false)
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
