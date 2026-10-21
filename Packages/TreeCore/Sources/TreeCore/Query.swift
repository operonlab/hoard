import Foundation

/// Read-only queries over a value snapshot of a file tree.
///
/// Pass `FileTree.nodes` to these methods after copying it on the tree's owning queue. The copied
/// array has copy-on-write value semantics and can be queried safely from a background thread.
public enum TreeQuery {
    /// Returns the counted byte owners of the largest files in the subtree, largest first.
    ///
    /// The walk keeps at most `limit` candidates in a min-heap, using O(n log K) time and O(K)
    /// additional space. Removed nodes and deduplicated files (`ownAlloc == 0`) are omitted.
    public static func largestFiles(in nodes: [Node], under root: NodeID = FileTree.root,
                                    limit: Int) -> [NodeID] {
        top(in: nodes, under: root, limit: limit, metric: .file) { node in
            !node.isDirectory && node.ownAlloc > 0
        }
    }

    /// Returns the largest directories below `root`, ordered by counted subtree bytes.
    ///
    /// `depth` counts directory levels below `root`: `1` considers direct children, `2` adds
    /// grandchildren, and `nil` has no depth limit. The root itself is not included.
    public static func largestDirs(in nodes: [Node], under root: NodeID = FileTree.root,
                                   depth: Int? = nil, limit: Int) -> [NodeID] {
        guard limit > 0, valid(root, in: nodes), !nodes[Int(root)].isRemoved else { return [] }
        guard depth.map({ $0 >= 1 }) ?? true else { return [] }
        if depth == nil, root == FileTree.root, nodes.count >= FileTree.parallelThreshold {
            return parallelTop(in: nodes, limit: limit, metric: .directory) { $0.isDirectory }
        }

        var heap = NodeMinHeap(nodes: nodes, metric: .directory)
        var stack: [(NodeID, Int)] = children(of: root, in: nodes).map { ($0, 1) }

        while let (id, level) = stack.popLast() {
            let node = nodes[Int(id)]
            if node.isRemoved { continue }
            if node.isDirectory {
                heap.insert(id, keeping: limit)
            }
            guard node.isDirectory, depth.map({ level < $0 }) ?? true else { continue }
            stack.append(contentsOf: children(of: id, in: nodes).map { ($0, level + 1) })
        }
        return heap.descending()
    }

    /// Returns large files whose newest recorded filesystem timestamp is older than `cutoff`.
    ///
    /// APFS access time is a lower bound: it updates on read only when it is not newer than the
    /// modification time. Consequently, "unused since" is conservative and callers may confirm
    /// the shortlist with Spotlight before presenting a cleanup candidate.
    public static func staleFiles(in nodes: [Node], under root: NodeID = FileTree.root,
                                  unusedSince cutoff: Int64, minSize: Int64,
                                  limit: Int) -> [NodeID] {
        top(in: nodes, under: root, limit: limit, metric: .file) { node in
            !node.isDirectory && node.ownAlloc > 0 && node.ownAlloc >= minSize
                && max(node.accessTime, node.modTime) < cutoff
        }
    }

    private enum Metric { case file, directory }

    private static func top(in nodes: [Node], under root: NodeID, limit: Int, metric: Metric,
                            include: (Node) -> Bool) -> [NodeID] {
        guard limit > 0, valid(root, in: nodes) else { return [] }
        if root == FileTree.root, nodes.count >= FileTree.parallelThreshold, !nodes[0].isRemoved {
            return parallelTop(in: nodes, limit: limit, metric: metric, include: include)
        }
        var heap = NodeMinHeap(nodes: nodes, metric: metric)
        var stack = [root]

        while let id = stack.popLast() {
            let node = nodes[Int(id)]
            if node.isRemoved { continue }
            if node.isDirectory {
                stack.append(contentsOf: children(of: id, in: nodes))
            } else if include(node) {
                heap.insert(id, keeping: limit)
            }
        }
        return heap.descending()
    }

    /// `top` for the whole tree: every live node is reachable from the root (removing a subtree marks
    /// all of it), so the array is read straight through in parallel chunks, each keeping its own K.
    /// The heap order is total (bytes, name, id), so the merged K are exactly the single-walk K.
    private static func parallelTop(in nodes: [Node], limit: Int, metric: Metric,
                                    include: (Node) -> Bool) -> [NodeID] {
        let chunks = min(ProcessInfo.processInfo.activeProcessorCount, 16)
        var partial = [[NodeID]](repeating: [], count: chunks)
        partial.withUnsafeMutableBufferPointer { out in
            nodes.withUnsafeBufferPointer { all in
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    var heap = NodeMinHeap(nodes: nodes, metric: metric)
                    // The root is not a result of its own query.
                    for i in max(1, all.count * chunk / chunks)..<(all.count * (chunk + 1) / chunks)
                        where !all[i].isRemoved && include(all[i]) {
                        heap.insert(NodeID(i), keeping: limit)
                    }
                    out[chunk] = heap.ids
                }
            }
        }
        var heap = NodeMinHeap(nodes: nodes, metric: metric)
        for id in partial.joined() { heap.insert(id, keeping: limit) }
        return heap.descending()
    }

    private static func valid(_ id: NodeID, in nodes: [Node]) -> Bool {
        id >= 0 && Int(id) < nodes.count
    }

    /// Returns live child ids defensively. Normal FileTree snapshots always have valid acyclic
    /// sibling chains; the guard also keeps an untrusted decoded array from indexing out of range.
    private static func children(of parent: NodeID, in nodes: [Node]) -> [NodeID] {
        var result: [NodeID] = []
        var child = nodes[Int(parent)].firstChild
        var remaining = nodes.count
        while valid(child, in: nodes), remaining > 0 {
            result.append(child)
            child = nodes[Int(child)].nextSibling
            remaining -= 1
        }
        return result
    }

    /// A min-heap whose root is the least useful retained result.
    private struct NodeMinHeap {
        let nodes: [Node]
        let metric: Metric
        var ids: [NodeID] = []

        mutating func insert(_ id: NodeID, keeping limit: Int) {
            if ids.count < limit {
                ids.append(id)
                siftUp(from: ids.count - 1)
            } else if let first = ids.first, isWorse(first, than: id) {
                ids[0] = id
                siftDown(from: 0)
            }
        }

        func descending() -> [NodeID] {
            ids.sorted { isWorse($1, than: $0) }
        }

        private func bytes(of id: NodeID) -> Int64 {
            let node = nodes[Int(id)]
            return metric == .file ? node.ownAlloc : node.totalAlloc
        }

        /// Defines the min-heap order. Equal-sized entries have a deterministic name/id order.
        private func isWorse(_ lhs: NodeID, than rhs: NodeID) -> Bool {
            let leftBytes = bytes(of: lhs)
            let rightBytes = bytes(of: rhs)
            if leftBytes != rightBytes { return leftBytes < rightBytes }
            let leftName = nodes[Int(lhs)].name
            let rightName = nodes[Int(rhs)].name
            if leftName != rightName { return leftName > rightName }
            return lhs > rhs
        }

        private mutating func siftUp(from index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard isWorse(ids[child], than: ids[parent]) else { break }
                ids.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(from index: Int) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                guard left < ids.count else { return }
                let right = left + 1
                let child = right < ids.count && isWorse(ids[right], than: ids[left]) ? right : left
                guard isWorse(ids[child], than: ids[parent]) else { return }
                ids.swapAt(parent, child)
                parent = child
            }
        }
    }
}
