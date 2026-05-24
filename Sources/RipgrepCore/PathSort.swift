import Foundation

enum PathSort {
    static func compare(_ lhs: URL, _ rhs: URL) -> ComparisonResult {
        let lhsComponents = lhs.pathComponents
        let rhsComponents = rhs.pathComponents
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
