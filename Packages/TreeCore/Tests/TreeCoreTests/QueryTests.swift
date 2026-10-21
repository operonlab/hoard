import XCTest
@testable import TreeCore

final class QueryTests: XCTestCase {
    private func file(_ name: String, _ size: Int64, modTime: Int64 = 0, accessTime: Int64 = 0,
                      fileID: UInt64 = 0, links: UInt32 = 1) -> ScanEntry {
        ScanEntry(name: name, isDirectory: false, allocSize: size, logicalSize: size, fileID: fileID,
                  linkCount: links, modTime: modTime, accessTime: accessTime, device: 1)
    }

    private func dir(_ name: String) -> ScanEntry {
        ScanEntry(name: name, isDirectory: true, device: 1)
    }

    private func names(_ ids: [NodeID], in tree: FileTree) -> [String] {
        ids.map { tree[$0].name }
    }

    func testLargestFilesOrdersAndLimitsCountedLiveFiles() {
        let tree = FileTree(rootPath: "/r", device: 1)
        let folder = tree.addChild(of: FileTree.root, entry: dir("folder"))
        tree.addChild(of: FileTree.root, entry: file("middle", 30))
        tree.addChild(of: folder, entry: file("small", 10))
        tree.addChild(of: folder, entry: file("largest", 90))
        tree.addChild(of: folder, entry: file("primary", 100, fileID: 7, links: 2))
        let duplicate = tree.addChild(of: FileTree.root, entry: file("zz-duplicate", 100, fileID: 7, links: 2))
        let removed = tree.addChild(of: FileTree.root, entry: file("removed", 1_000))
        tree.recomputeAggregates()
        tree.removeSubtree(removed)

        XCTAssertEqual(tree[duplicate].ownAlloc, 0)
        XCTAssertEqual(names(TreeQuery.largestFiles(in: tree.nodes, limit: 3), in: tree),
                       ["primary", "largest", "middle"])
        XCTAssertEqual(names(TreeQuery.largestFiles(in: tree.nodes, limit: 2), in: tree),
                       ["primary", "largest"])
    }

    func testLargestDirectoriesRespectDepthAndOrdering() {
        let tree = FileTree(rootPath: "/r", device: 1)
        let alpha = tree.addChild(of: FileTree.root, entry: dir("alpha"))
        let beta = tree.addChild(of: FileTree.root, entry: dir("beta"))
        tree.addChild(of: FileTree.root, entry: dir("empty"))
        let removed = tree.addChild(of: FileTree.root, entry: dir("removed"))
        let nested = tree.addChild(of: alpha, entry: dir("nested"))
        tree.addChild(of: alpha, entry: file("a", 20))
        tree.addChild(of: beta, entry: file("b", 80))
        tree.addChild(of: nested, entry: file("n", 50))
        tree.addChild(of: removed, entry: file("gone", 100))
        tree.recomputeAggregates()
        tree.removeSubtree(removed)

        XCTAssertEqual(names(TreeQuery.largestDirs(in: tree.nodes, depth: 1, limit: 5), in: tree),
                       ["beta", "alpha", "empty"])
        XCTAssertEqual(names(TreeQuery.largestDirs(in: tree.nodes, depth: 2, limit: 2), in: tree),
                       ["beta", "alpha"])
        XCTAssertEqual(names(TreeQuery.largestDirs(in: tree.nodes, depth: nil, limit: 5), in: tree),
                       ["beta", "alpha", "nested", "empty"])
        XCTAssertEqual(TreeQuery.largestDirs(in: tree.nodes, depth: 0, limit: 5), [])
    }

    func testStaleFilesUsesNewestTimeAndInclusiveMinimumSize() {
        let tree = FileTree(rootPath: "/r", device: 1)
        let folder = tree.addChild(of: FileTree.root, entry: dir("folder"))
        tree.addChild(of: folder, entry: file("old-large", 80, modTime: 90, accessTime: 20))
        tree.addChild(of: folder, entry: file("old-threshold", 50, modTime: 99, accessTime: 30))
        tree.addChild(of: folder, entry: file("equal-cutoff", 90, modTime: 100, accessTime: 10))
        tree.addChild(of: folder, entry: file("recent-access", 90, modTime: 1, accessTime: 101))
        tree.addChild(of: folder, entry: file("too-small", 49, modTime: 1, accessTime: 1))
        tree.recomputeAggregates()

        XCTAssertEqual(names(TreeQuery.staleFiles(in: tree.nodes, unusedSince: 100, minSize: 50, limit: 5), in: tree),
                       ["old-large", "old-threshold"])
        XCTAssertEqual(names(TreeQuery.staleFiles(in: tree.nodes, unusedSince: 100, minSize: 50, limit: 1), in: tree),
                       ["old-large"])
    }

    /// A whole-tree query of 50k+ nodes reads the array in parallel chunks; it must give the same K as
    /// sorting everything, ties (equal sizes, equal names) and removed subtrees included.
    func testWholeTreeQueriesMatchAFullSort() {
        let tree = FileTree(rootPath: "/r", device: 1)
        var dirs: [NodeID] = []
        for d in 0..<400 {
            let folder = tree.addChild(of: d % 7 == 0 || dirs.isEmpty ? FileTree.root : dirs[d / 3], entry: dir("d\(d % 50)"))
            dirs.append(folder)
            for f in 0..<130 {
                // Few distinct sizes and names, so ties decide much of the order.
                tree.addChild(of: folder, entry: file("f\(f % 9)", Int64((d * 31 + f * 17) % 23) * 4096,
                                                      modTime: Int64(f % 5) * 100))
            }
        }
        tree.recomputeAggregates()
        tree.removeSubtree(dirs[5])
        XCTAssertGreaterThanOrEqual(tree.nodeCount, FileTree.parallelThreshold)
        let nodes = tree.nodes
        func sorted(_ ids: [Int], by bytes: (Node) -> Int64, limit: Int) -> [NodeID] {
            Array(ids.sorted { a, b in
                let (x, y) = (nodes[a], nodes[b])
                if bytes(x) != bytes(y) { return bytes(x) > bytes(y) }
                if x.name != y.name { return x.name < y.name }
                return a < b
            }.prefix(limit)).map { NodeID($0) }
        }
        let live = nodes.indices.dropFirst().filter { !nodes[$0].isRemoved }
        let files = live.filter { !nodes[$0].isDirectory && nodes[$0].ownAlloc > 0 }
        XCTAssertEqual(TreeQuery.largestFiles(in: nodes, limit: 1000), sorted(files, by: \.ownAlloc, limit: 1000))
        // A limit above the count: every chunk boundary's node must be there.
        XCTAssertEqual(TreeQuery.largestFiles(in: nodes, limit: files.count + 5), sorted(files, by: \.ownAlloc, limit: files.count))
        XCTAssertEqual(TreeQuery.largestDirs(in: nodes, limit: 150), sorted(live.filter { nodes[$0].isDirectory }, by: \.totalAlloc, limit: 150))
        let stale = files.filter { nodes[$0].ownAlloc >= 8192 && max(nodes[$0].accessTime, nodes[$0].modTime) < 300 }
        XCTAssertEqual(TreeQuery.staleFiles(in: nodes, unusedSince: 300, minSize: 8192, limit: 700), sorted(stale, by: \.ownAlloc, limit: 700))
    }
}
