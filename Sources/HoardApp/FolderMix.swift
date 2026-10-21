import Foundation
import ScanCore

/// The category holding the most counted bytes in a folder's subtree, and its share of them.
struct FolderMix: Equatable, Sendable {
    var category: FileCategory
    var share: Double

    /// Below this share a folder is drawn neutral: a mixed folder must not pretend to be one thing (§3.2).
    static let threshold = 0.4

    /// The category the folder tile is filled with, nil when it stays neutral.
    var tint: FileCategory? { share >= Self.threshold ? category : nil }
}

/// Dominant categories of the folder tiles in one scope: its folders and their sub-folders, the two
/// levels the space map draws. Folders with no counted bytes have no entry.
struct FolderMixes: Sendable {
    var generation: Int
    var scope: NodeID
    var revision: Int
    var byFolder: [NodeID: FolderMix]

    static let none = FolderMixes(generation: -1, scope: -1, revision: -1, byFolder: [:])

    /// One pass over the subtree of `scope`. Each file's counted bytes (`ownAlloc`: hardlinks and
    /// clones counted once) go into the ten category buckets of the first-level folder that contains
    /// it and of the second-level folder inside that one.
    static func compute(nodes: [Node], scope: NodeID) -> [NodeID: FolderMix] {
        let width = FileCategory.allCases.count
        var folders: [NodeID] = []
        var buckets: [Int64] = []
        func slot(_ id: NodeID) -> Int {
            folders.append(id)
            buckets.append(contentsOf: repeatElement(0, count: width))
            return folders.count - 1
        }
        // (folder to list, slot of its first-level folder, slot of its second-level folder or -1)
        var stack: [(NodeID, Int, Int)] = []
        // Per-extension category, so a file costs an integer-keyed lookup instead of a String.
        var categoryOf: [ExtensionKey: Int] = [:]
        var child = nodes[Int(scope)].firstChild
        while child >= 0 {
            let node = nodes[Int(child)]
            if node.isDirectory && !node.isRemoved { stack.append((child, slot(child), -1)) }
            child = node.nextSibling
        }
        while let (dir, top, second) = stack.popLast() {
            var child = nodes[Int(dir)].firstChild
            while child >= 0 {
                let node = nodes[Int(child)]
                if !node.isRemoved {
                    if node.isDirectory {
                        stack.append((child, top, second >= 0 ? second : slot(child)))
                    } else if node.ownAlloc > 0 {
                        let ext = ExtensionKey(fileName: node.name)
                        let k: Int
                        if let known = categoryOf[ext] {
                            k = known
                        } else {
                            k = FileCategory.of(extension: ext.string).rawValue
                            categoryOf[ext] = k
                        }
                        buckets[top * width + k] += node.ownAlloc
                        if second >= 0 { buckets[second * width + k] += node.ownAlloc }
                    }
                }
                child = node.nextSibling
            }
        }
        var result: [NodeID: FolderMix] = [:]
        result.reserveCapacity(folders.count)
        for (index, id) in folders.enumerated() {
            let row = buckets[index * width ..< (index + 1) * width]
            let total = row.reduce(0, +)
            guard total > 0, let best = row.indices.max(by: { row[$0] < row[$1] }),
                  let category = FileCategory(rawValue: best - index * width) else { continue }
            result[id] = FolderMix(category: category, share: Double(row[best]) / Double(total))
        }
        return result
    }
}
