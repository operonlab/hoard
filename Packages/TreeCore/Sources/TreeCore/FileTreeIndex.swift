import Foundation

/// Name → child for one wide directory, built on the first lookup during live updates and kept in
/// step by `addChild` / `unlink` instead of being rebuilt. String keys hash the way `==` compares
/// (canonical equivalence), and each key holds the first sibling in list order: the same answer
/// the linear scan gives.
struct ChildNameIndex {
    var ids: [String: NodeID]
    /// Two siblings share a key, so unlinking the holder needs a rescan to find the next one.
    var hasDuplicates: Bool
}

extension FileTree {
    static let childIndexThreshold = 64

    /// Drops the name indexes built for lookups so far; the next lookup into a wide folder rebuilds
    /// its own. LiveUpdater calls it after each batch, so a long-lived tree does not keep one per
    /// wide folder it ever touched.
    public func releaseNameIndexes() {
        childNameIndexes.removeAll(keepingCapacity: false)
    }

    /// How many folders currently hold a name index (memory diagnostics and tests).
    public var indexedFolderCount: Int { childNameIndexes.count }

    /// The deepest node of the tree on `path`: the node itself when the whole path is known, else
    /// its nearest known ancestor. nil when `path` is not inside the tree.
    public func deepestNode(onPath path: String) -> NodeID? {
        walk(path: path)?.deepest
    }

    /// One pass from the root over the path's UTF-8 bytes. Each component becomes a native String,
    /// which compares with == like the stored names do (canonical equivalence) without the
    /// per-Character walk a bridged FSEvents path costs.
    func walk(path: String) -> (deepest: NodeID, complete: Bool)? {
        var p = path
        p.makeContiguousUTF8()
        let walked = p.utf8.withContiguousStorageIfAvailable { walk(bytes: $0) }
            ?? Array(p.utf8).withUnsafeBufferPointer { walk(bytes: $0) }
        if let walked { return walked }
        // The root as given and the path as the file system spells it can differ in Unicode form
        // (an NFC root typed for an NFD folder): match the root as String == does, then walk the rest.
        guard let rest = canonicalRemainder(of: p) else { return nil }
        guard !rest.isEmpty else { return (Self.root, true) }
        var r = rest
        r.makeContiguousUTF8()
        return Array(r.utf8).withUnsafeBufferPointer { walkComponents($0, from: 0, to: $0.count) }
    }

    /// The part of `path` below the root when the root matches only by canonical equivalence: "" for
    /// the root itself, nil when `path` is not inside the tree.
    private func canonicalRemainder(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if p == base || p == rootPath { return "" }
        guard p.hasPrefix(base + "/") else { return nil }
        return String(p.dropFirst(base.count + 1))
    }

    private func walk(bytes: UnsafeBufferPointer<UInt8>) -> (deepest: NodeID, complete: Bool)? {
        let root = rootUTF8
        var end = bytes.count
        while end > 1 && bytes[end - 1] == 0x2F { end -= 1 }
        var rootEnd = root.count
        while rootEnd > 1 && root[rootEnd - 1] == 0x2F { rootEnd -= 1 }
        guard end >= rootEnd else { return nil }
        for i in 0..<rootEnd where bytes[i] != root[i] { return nil }
        if end == rootEnd { return (Self.root, true) }
        var start = rootEnd
        if !(rootEnd == 1 && root[0] == 0x2F) {
            guard bytes[rootEnd] == 0x2F else { return nil }
            start += 1
        }
        return walkComponents(bytes, from: start, to: end)
    }

    private func walkComponents(_ bytes: UnsafeBufferPointer<UInt8>, from offset: Int, to end: Int) -> (deepest: NodeID, complete: Bool) {
        var start = offset
        var cur = Self.root
        while start < end {
            if bytes[start] == 0x2F { start += 1; continue }
            var slash = start
            while slash < end && bytes[slash] != 0x2F { slash += 1 }
            let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<slash]), as: UTF8.self)
            guard let next = childLookup(name, of: cur) else { return (cur, false) }
            cur = next
            start = slash + 1
        }
        return (cur, true)
    }

    /// Builds the index on a read, so lookups write: like every other use of a tree, call them from
    /// the one thread that owns it (main, or a detached `restoring:` copy), never concurrently.
    func childLookup(_ name: String, of parent: NodeID) -> NodeID? {
        if let index = childNameIndexes[parent] { return index.ids[name] }
        var count = 0
        var match: NodeID?
        var c = nodes[Int(parent)].firstChild
        while c >= 0 && count < Self.childIndexThreshold {
            if match == nil && !nodes[Int(c)].isRemoved && nodes[Int(c)].name == name { match = c }
            count += 1
            c = nodes[Int(c)].nextSibling
        }
        if c < 0 { return match }
        var ids: [String: NodeID] = [:]
        var hasDuplicates = false
        c = nodes[Int(parent)].firstChild
        while c >= 0 {
            if !nodes[Int(c)].isRemoved {
                if ids[nodes[Int(c)].name] == nil { ids[nodes[Int(c)].name] = c } else { hasDuplicates = true }
            }
            c = nodes[Int(c)].nextSibling
        }
        childNameIndexes[parent] = ChildNameIndex(ids: ids, hasDuplicates: hasDuplicates)
        return ids[name]
    }

    /// `id` was just put first in `parent`'s child list, so it is now the first match for its name.
    func indexChildAdded(_ id: NodeID, to parent: NodeID) {
        guard !childNameIndexes.isEmpty, childNameIndexes[parent] != nil else { return }
        if childNameIndexes[parent]!.ids.updateValue(id, forKey: nodes[Int(id)].name) != nil {
            childNameIndexes[parent]!.hasDuplicates = true
        }
    }

    func indexChildUnlinked(_ id: NodeID, from parent: NodeID) {
        guard !childNameIndexes.isEmpty else { return }
        let name = nodes[Int(id)].name
        guard childNameIndexes[parent]?.ids[name] == id else { return }
        if childNameIndexes[parent]!.hasDuplicates { childNameIndexes[parent] = nil } else { childNameIndexes[parent]!.ids[name] = nil }
    }
}
