import Foundation

public enum WhatsNewPolicy {
    /// Dotted numeric versions, compared part by part; missing parts are zero.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").compactMap { Int($0) }
        let right = b.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    public static func versionsToShow(current: String, lastSeen: String?, hasPriorUse: Bool,
                                      available: [String]) -> [String] {
        guard let lastSeen else { return hasPriorUse && available.contains(current) ? [current] : [] }
        guard compare(lastSeen, current) == .orderedAscending else { return [] }
        return available.filter {
            compare(lastSeen, $0) == .orderedAscending && compare($0, current) != .orderedDescending
        }.sorted { compare($0, $1) == .orderedDescending }
    }
}
