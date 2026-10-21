import CoreServices
import Foundation

/// Finder's last-opened date, when Spotlight has indexed it. Nil means unknown.
public enum Spotlight {
    public static func lastUsedDate(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return value as? Date
    }
}
