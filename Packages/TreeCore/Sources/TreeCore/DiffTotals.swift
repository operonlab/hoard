import Foundation

extension TreeDiff {
    /// Totals of a list of changes in which a folder and the items inside it can both appear. A
    /// folder's change already contains its listed children's, so only the most specific entries —
    /// those with no other listed entry below them — are added up; summing every row counts the same
    /// bytes once per listed ancestor.
    public static func listedTotals(_ changes: [(path: String, delta: Int64)]) -> (grown: Int64, shrunk: Int64) {
        let listed = Set(changes.map(\.path))
        var hasListedChild = Set<String>()
        for change in changes where change.path != "/" {
            var path = change.path
            while let cut = path.lastIndex(of: "/") {
                path = cut == path.startIndex ? "/" : String(path[..<cut])
                if listed.contains(path) { hasListedChild.insert(path) }
                if path == "/" { break }
            }
        }
        var grown: Int64 = 0, shrunk: Int64 = 0
        for change in changes where !hasListedChild.contains(change.path) {
            if change.delta > 0 { grown += change.delta } else { shrunk += change.delta }
        }
        return (grown, shrunk)
    }
}
