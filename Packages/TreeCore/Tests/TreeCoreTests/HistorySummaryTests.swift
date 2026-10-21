import XCTest
import TreeCore

final class HistorySummaryTests: XCTestCase {
    static let mb: Int64 = 1_048_576

    private func file(_ name: String, _ size: Int64, fileID: UInt64 = 0, links: UInt32 = 1,
                      mod: Int64 = 0, access: Int64 = 0) -> ScanEntry {
        ScanEntry(name: name, isDirectory: false, allocSize: size, logicalSize: size, fileID: fileID,
                  linkCount: links, modTime: mod, accessTime: access, device: 1)
    }
    private func dir(_ name: String) -> ScanEntry { ScanEntry(name: name, isDirectory: true, device: 1) }

    func testSummaryOfHandBuiltTree() {
        let mb = Self.mb
        let t = FileTree(rootPath: "/r", device: 1)
        let a = t.addChild(of: FileTree.root, entry: dir("a"))
        let b = t.addChild(of: a, entry: dir("b"))
        let gone = t.addChild(of: FileTree.root, entry: dir("gone"))
        t.addChild(of: gone, entry: file("huge.bin", 50 * mb))
        t.addChild(of: b, entry: file("exact.mov", 10 * mb, mod: 11, access: 12))     // exactly the threshold
        t.addChild(of: b, entry: file("under.mov", 10 * mb - 1))
        t.addChild(of: a, entry: file("h1", 20 * mb, fileID: 7, links: 2))            // dedup duplicate
        t.addChild(of: b, entry: file("h2", 20 * mb, fileID: 7, links: 2))            // owner: "/r/a/b/h2" < "/r/a/h1"
        let unreadable = t.addChild(of: a, entry: dir("locked"))
        t.recomputeAggregates()
        t.markUnavailable(unreadable)
        t.removeSubtree(gone)

        let s = TreeSummary(tree: t, createdAt: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(s.rootPath, "/r")
        XCTAssertEqual(s.bigFileThreshold, 10 * mb)
        XCTAssertEqual(s.dirs.count, 4)
        XCTAssertEqual(s.dirs[0].parent, -1)
        for (i, d) in s.dirs.enumerated() where i > 0 { XCTAssertLessThan(d.parent, Int32(i)) }
        let paths = Set(s.dirs.indices.map { s.path(ofDir: Int32($0)) })
        XCTAssertEqual(paths, ["/r", "/r/a", "/r/a/b", "/r/a/locked"])
        XCTAssertFalse(paths.contains("/r/gone"))

        func dirNamed(_ p: String) -> TreeSummary.Dir {
            s.dirs[s.dirs.indices.first { s.path(ofDir: Int32($0)) == p }!]
        }
        XCTAssertEqual(dirNamed("/r").totalAlloc, t[FileTree.root].totalAlloc)
        XCTAssertEqual(dirNamed("/r").totalAlloc, 40 * mb - 1)
        XCTAssertEqual(dirNamed("/r").fileCount, 4)
        XCTAssertEqual(dirNamed("/r").status, .partial)
        XCTAssertEqual(dirNamed("/r/a/locked").status, .unavailable)
        XCTAssertEqual(dirNamed("/r/a/b").totalAlloc, 40 * mb - 1)

        let big = s.bigFiles.map { s.path(ofDir: $0.dir) + "/" + $0.name }.sorted()
        XCTAssertEqual(big, ["/r/a/b/exact.mov", "/r/a/b/h2"])
        let exact = s.bigFiles.first { $0.name == "exact.mov" }!
        XCTAssertEqual(exact.alloc, 10 * mb)
        XCTAssertEqual(exact.modTime, 11)
        XCTAssertEqual(exact.accessTime, 12)
    }

    func testSlashRootHasNoDoubleSlash() {
        let t = FileTree(rootPath: "/", device: 1)
        let u = t.addChild(of: FileTree.root, entry: dir("Users"))
        t.addChild(of: u, entry: dir("me"))
        t.recomputeAggregates()
        let s = TreeSummary(tree: t, createdAt: Date())
        XCTAssertEqual(s.dirs.indices.map { s.path(ofDir: Int32($0)) }.sorted(), ["/", "/Users", "/Users/me"])
    }

    func testCustomThreshold() {
        let t = FileTree(rootPath: "/r", device: 1)
        t.addChild(of: FileTree.root, entry: file("a", 100))
        t.addChild(of: FileTree.root, entry: file("b", 99))
        t.recomputeAggregates()
        let s = TreeSummary(tree: t, createdAt: Date(), bigFileThreshold: 100)
        XCTAssertEqual(s.bigFiles.map(\.name), ["a"])
        XCTAssertEqual(s.bigFiles[0].dir, 0)
    }
}
