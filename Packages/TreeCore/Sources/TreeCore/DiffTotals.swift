import Foundation

extension TreeDiff {
    /// Totals of a list of changes in which a folder and the items inside it can both appear. A
    /// folder's change already contains its listed children's, so each row contributes only what is
    /// left after its nearest listed descendants are taken out: summing every row counts the same
    /// bytes once per listed ancestor, and summing only the deepest rows loses changes too small to
    /// list. That remainder counts in its own direction, so Larger and Smaller add up to the net
    /// change of the outermost rows. Uncertain rows, and their part of the folders above them, are
    /// left out.
    public static func listedTotals(_ changes: [(path: String, delta: Int64)], uncertain: Set<String> = []) -> (grown: Int64, shrunk: Int64) {
        var seen = Set<String>()
        let changes = changes.filter { seen.insert($0.path).inserted }
        var remainder = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0.delta) })
        for change in changes where change.path != "/" {
            var path = change.path
            while let cut = path.lastIndex(of: "/") {
                path = cut == path.startIndex ? "/" : String(path[..<cut])
                if remainder[path] != nil { remainder[path]! -= change.delta; break }
                if path == "/" { break }
            }
        }
        var grown: Int64 = 0, shrunk: Int64 = 0
        for (path, delta) in remainder where !uncertain.contains(path) {
            if delta > 0 { grown += delta } else { shrunk += delta }
        }
        return (grown, shrunk)
    }
}
