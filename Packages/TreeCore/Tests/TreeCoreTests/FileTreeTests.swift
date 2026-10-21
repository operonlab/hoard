import XCTest
@testable import TreeCore

final class FileTreeTests: XCTestCase {
    private func file(_ name: String, _ size: Int64, fileID: UInt64 = 0, links: UInt32 = 1,
                      clone: UInt64 = 0, shared: Bool = false) -> ScanEntry {
        ScanEntry(name: name, isDirectory: false, allocSize: size, logicalSize: size, fileID: fileID,
                  linkCount: links, cloneID: clone, sharesAllBlocks: shared, device: 1)
    }
    private func dir(_ name: String) -> ScanEntry { ScanEntry(name: name, isDirectory: true, device: 1) }

    func testAggregatesAndSortedChildren() {
        let t = FileTree(rootPath: "/r", device: 1)
        let a = t.addChild(of: FileTree.root, entry: dir("a"))
        t.addChild(of: a, entry: file("x.mov", 300))
        t.addChild(of: FileTree.root, entry: file("y.txt", 50))
        t.recomputeAggregates()
        XCTAssertEqual(t[FileTree.root].totalAlloc, 350)
        XCTAssertEqual(t[FileTree.root].fileCount, 2)
        XCTAssertEqual(t[FileTree.root].dirCount, 2)
        XCTAssertEqual(t.sortedChildren(of: FileTree.root).map { t[$0].name }, ["a", "y.txt"])
        XCTAssertEqual(t.path(of: t.child(named: "x.mov", of: a)!), "/r/a/x.mov")
        XCTAssertEqual(t.lookup(path: "/r/a/x.mov"), t.child(named: "x.mov", of: a))
        XCTAssertNil(t.lookup(path: "/other/a"))
    }

    /// Every file on APFS has a clone ID, so the ID alone says nothing; sharing is a hardlink or a full clone.
    func testSharesStorageIgnoresAPlainCloneID() {
        let t = FileTree(rootPath: "/r", device: 1)
        let plain = t.addChild(of: FileTree.root, entry: file("plain", 10, fileID: 1, clone: 41))
        let linked = t.addChild(of: FileTree.root, entry: file("linked", 10, fileID: 2, links: 2, clone: 42))
        let cloned = t.addChild(of: FileTree.root, entry: file("cloned", 10, fileID: 3, clone: 43, shared: true))
        XCTAssertFalse(t[plain].sharesStorage)
        XCTAssertTrue(t[linked].sharesStorage)
        XCTAssertTrue(t[cloned].sharesStorage)
    }

    func testHardlinksAndClonesCountOnceAndPromoteOnRemoval() {
        let t = FileTree(rootPath: "/r", device: 1)
        let a = t.addChild(of: FileTree.root, entry: dir("a"))
        let b = t.addChild(of: FileTree.root, entry: dir("b"))
        let h1 = t.addChild(of: a, entry: file("h1", 100, fileID: 7, links: 2))
        t.addChild(of: b, entry: file("h2", 100, fileID: 7, links: 2))
        let c1 = t.addChild(of: a, entry: file("c1", 40, fileID: 8, clone: 99, shared: true))
        t.addChild(of: b, entry: file("c2", 40, fileID: 9, clone: 99, shared: true))
        t.addChild(of: b, entry: file("plain", 5, fileID: 10, clone: 99, shared: false))
        t.recomputeAggregates()
        XCTAssertEqual(t[FileTree.root].totalAlloc, 145)
        XCTAssertEqual(t[a].totalAlloc, 140)
        XCTAssertEqual(t[b].totalAlloc, 5)

        // Removing the primaries hands the bytes to the surviving holders in b.
        t.removeSubtree(h1)
        t.removeSubtree(c1)
        XCTAssertEqual(t[a].totalAlloc, 0)
        XCTAssertEqual(t[b].totalAlloc, 145)
        XCTAssertEqual(t[FileTree.root].totalAlloc, 145)
    }

    func testDedupOwnerDoesNotDependOnInsertionOrder() {
        // The same hardlink pair and clone pair, inserted in opposite orders, must charge the same folder.
        func build(reversed: Bool) -> FileTree {
            let t = FileTree(rootPath: "/r", device: 1)
            let names = reversed ? ["b", "a"] : ["a", "b"]
            for name in names {
                let d = t.addChild(of: FileTree.root, entry: dir(name))
                t.addChild(of: d, entry: file("h", 100, fileID: 7, links: 2))
                t.addChild(of: d, entry: file("c", 40, fileID: name == "a" ? 8 : 9, clone: 99, shared: true))
            }
            t.recomputeAggregates()
            return t
        }
        for t in [build(reversed: false), build(reversed: true)] {
            let a = t.child(named: "a", of: FileTree.root)!
            let b = t.child(named: "b", of: FileTree.root)!
            XCTAssertEqual(t[a].totalAlloc, 140, "the lexicographically first path owns the bytes")
            XCTAssertEqual(t[b].totalAlloc, 0)
            XCTAssertEqual(t[FileTree.root].totalAlloc, 140)
        }
    }

    // Codex review finding 3: growing a hardlinked inode through one name must grow the total.
    func testHardlinkGrowthThroughOneNameUpdatesTotals() {
        let t = FileTree(rootPath: "/r", device: 1)
        let a = t.addChild(of: FileTree.root, entry: dir("a"))
        let b = t.addChild(of: FileTree.root, entry: dir("b"))
        let ha = t.addChild(of: a, entry: file("h", 100, fileID: 7, links: 2))
        let hb = t.addChild(of: b, entry: file("h", 100, fileID: 7, links: 2))
        t.recomputeAggregates()
        XCTAssertEqual(t[FileTree.root].totalAlloc, 100)
        for (grown, other) in [(ha, hb), (hb, ha)] {
            t.updateFile(grown, with: file("h", 200 + Int64(grown), fileID: 7, links: 2))
            let size = 200 + Int64(grown)
            XCTAssertEqual(t[FileTree.root].totalAlloc, size, "one inode, counted once, at its new size")
            XCTAssertEqual(t[FileTree.root].totalLogical, 2 * size, "logical counts every name")
            XCTAssertEqual(t[other].rawAlloc, size, "the other name sees the same inode")
        }
    }

    // Codex review finding 5: live inserts must pick the same owner a full scan would.
    func testLiveInsertKeepsCanonicalOwner() {
        let t = FileTree(rootPath: "/r", device: 1)
        let a = t.addChild(of: FileTree.root, entry: dir("a"))
        let b = t.addChild(of: FileTree.root, entry: dir("b"))
        t.addChild(of: b, entry: file("c", 40, fileID: 9, clone: 99, shared: true))
        t.recomputeAggregates()
        XCTAssertEqual(t[b].totalAlloc, 40)
        let ca = t.insert(file("c", 40, fileID: 8, clone: 99, shared: true), under: a)
        XCTAssertEqual(t[a].totalAlloc, 40, "/r/a/c sorts first, so it owns the bytes")
        XCTAssertEqual(t[b].totalAlloc, 0)
        XCTAssertEqual(t[FileTree.root].totalAlloc, 40)
        t.removeSubtree(ca)
        XCTAssertEqual(t[b].totalAlloc, 40, "ownership returns to the remaining member")
        XCTAssertEqual(t[FileTree.root].totalAlloc, 40)
    }

    // Codex review finding 6: a folder that becomes readable again must stop reporting partial.
    func testStatusRecoversAfterUnreadableSubtreeIsReplaced() {
        let t = FileTree(rootPath: "/r", device: 1)
        let a = t.addChild(of: FileTree.root, entry: dir("a"))
        let locked = t.addChild(of: a, entry: dir("locked"))
        t.setStatus(locked, .unavailable)
        t.recomputeAggregates()
        XCTAssertEqual(t[FileTree.root].status, .partial)

        let sub = FileTree(rootPath: "/r/a/locked", device: 1)
        sub.addChild(of: FileTree.root, entry: file("f", 10))
        sub.recomputeAggregates()
        t.graft(sub, as: "locked", under: a)
        XCTAssertEqual(t[a].status, .complete)
        XCTAssertEqual(t[FileTree.root].status, .complete)

        // A folder whose own listing failed stays partial even when its children are fine.
        let c = t.addChild(of: FileTree.root, entry: dir("c"))
        t.markListingIncomplete(c)
        t.recomputeAggregates()
        let sub2 = FileTree(rootPath: "/r/c/x", device: 1)
        sub2.recomputeAggregates()
        t.graft(sub2, as: "x", under: c)
        XCTAssertEqual(t[c].status, .partial)
        XCTAssertEqual(t[FileTree.root].status, .partial)
    }

    func testRemovingWholeSubtreeDoesNotPromoteInsideIt() {
        let t = FileTree(rootPath: "/r", device: 1)
        let a = t.addChild(of: FileTree.root, entry: dir("a"))
        t.addChild(of: a, entry: file("h1", 100, fileID: 7, links: 2))
        t.addChild(of: a, entry: file("h2", 100, fileID: 7, links: 2))
        t.addChild(of: FileTree.root, entry: file("k", 1))
        t.recomputeAggregates()
        XCTAssertEqual(t[FileTree.root].totalAlloc, 101)
        t.removeSubtree(a)
        XCTAssertEqual(t[FileTree.root].totalAlloc, 1)
        XCTAssertEqual(t[FileTree.root].fileCount, 1)
        XCTAssertEqual(t.children(of: FileTree.root).count, 1)
    }

    func testGraftReplacesSubtreeAndKeepsTotals() {
        let t = FileTree(rootPath: "/r", device: 1)
        let a = t.addChild(of: FileTree.root, entry: dir("a"))
        t.addChild(of: a, entry: file("old", 70))
        t.recomputeAggregates()

        let sub = FileTree(rootPath: "/r/a", device: 1)
        let s = sub.addChild(of: FileTree.root, entry: dir("s"))
        sub.addChild(of: s, entry: file("new1", 10))
        sub.addChild(of: FileTree.root, entry: file("new2", 20))
        sub.recomputeAggregates()

        let g = t.graft(sub, as: "a", under: FileTree.root)
        XCTAssertEqual(t[g].totalAlloc, 30)
        XCTAssertEqual(t[FileTree.root].totalAlloc, 30)
        XCTAssertEqual(t[FileTree.root].fileCount, 2)
        XCTAssertNil(t.lookup(path: "/r/a/old"))
        XCTAssertNotNil(t.lookup(path: "/r/a/s/new1"))
    }

    func testUpdateFilePropagatesDelta() {
        let t = FileTree(rootPath: "/r", device: 1)
        let a = t.addChild(of: FileTree.root, entry: dir("a"))
        let f = t.addChild(of: a, entry: file("f", 10))
        t.recomputeAggregates()
        t.updateFile(f, with: file("f", 25))
        XCTAssertEqual(t[a].totalAlloc, 25)
        XCTAssertEqual(t[FileTree.root].totalAlloc, 25)
    }

    func testRestoringRebuildsDedupHolders() {
        let t = FileTree(rootPath: "/r", device: 1)
        let h1 = t.addChild(of: FileTree.root, entry: file("h1", 100, fileID: 7, links: 2))
        t.addChild(of: FileTree.root, entry: file("h2", 100, fileID: 7, links: 2))
        t.recomputeAggregates()
        let r = FileTree(restoring: t.nodes, rootPath: "/r", device: 1)
        XCTAssertEqual(r[FileTree.root].totalAlloc, 100)
        r.removeSubtree(h1)
        XCTAssertEqual(r[FileTree.root].totalAlloc, 100, "the surviving hardlink takes over the bytes")
    }

    func testExtensionStats() {
        let t = FileTree(rootPath: "/r", device: 1)
        t.addChild(of: FileTree.root, entry: file("a.MOV", 300))
        t.addChild(of: FileTree.root, entry: file("b.mov", 100))
        t.addChild(of: FileTree.root, entry: file("Makefile", 5))
        t.addChild(of: FileTree.root, entry: file(".zshrc", 1))
        t.recomputeAggregates()
        let s = t.extensionStats()
        XCTAssertEqual(s.first, ExtensionStat(ext: "mov", bytes: 400, count: 2))
        XCTAssertEqual(s.first { $0.ext == "" }?.count, 2)
    }
}
