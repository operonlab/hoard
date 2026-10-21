import Foundation
import XCTest
@testable import TreeCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class FileTreeLookupTests: XCTestCase {
    private func file(_ name: String) -> ScanEntry { ScanEntry(name: name, isDirectory: false, device: 1) }
    private func dir(_ name: String) -> ScanEntry { ScanEntry(name: name, isDirectory: true, device: 1) }

    /// The lookup before the UTF-8 rewrite: Character split, String == (canonical equivalence),
    /// first matching sibling in list order.
    private func oracle(_ tree: FileTree, _ path: String) -> NodeID? {
        let base = tree.rootPath.hasSuffix("/") ? String(tree.rootPath.dropLast()) : tree.rootPath
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if p == base || p == tree.rootPath { return FileTree.root }
        guard p.hasPrefix(base + "/") else { return nil }
        var cur = FileTree.root
        for comp in p.dropFirst(base.count + 1).split(separator: "/") {
            var c = tree[cur].firstChild
            var found: NodeID?
            while c >= 0 {
                if !tree[c].isRemoved && tree[c].name == String(comp) { found = c; break }
                c = tree[c].nextSibling
            }
            guard let next = found else { return nil }
            cur = next
        }
        return cur
    }

    private let nfc = "caf\u{E9}", nfd = "cafe\u{301}", kelvin = "\u{212A}"

    private func assertMatchesOracle(_ tree: FileTree, _ paths: [String], file: StaticString = #filePath, line: UInt = #line) {
        for path in paths {
            XCTAssertEqual(tree.lookup(path: path), oracle(tree, path), path, file: file, line: line)
            XCTAssertEqual(tree.lookup(path: (path as NSString) as String), oracle(tree, path), "bridged " + path,
                           file: file, line: line)
        }
    }

    private func queries(root: String, dirs: [String]) -> [String] {
        var out = [root, root + "/", root + "///", root + "x", "/elsewhere" + root, ""]
        for d in dirs {
            for name in ["plain", nfc, nfd, "K", kelvin, "missing", "plain/missing"] {
                out += [root + "/" + d + "/" + name, root + "/" + d + "//" + name, root + "/" + d + "/" + name + "/"]
            }
        }
        return out
    }

    private func build(childrenPerDir filler: Int) -> FileTree {
        let tree = FileTree(rootPath: "/r", device: 1)
        let both = tree.addChild(of: 0, entry: dir("both"))
        let onlyNFD = tree.addChild(of: 0, entry: dir("onlynfd"))
        let ascii = tree.addChild(of: 0, entry: dir("ascii"))
        for parent in [both, onlyNFD, ascii] {
            for i in 0..<filler { tree.addChild(of: parent, entry: file("item\(i)")) }
            tree.addChild(of: parent, entry: file("plain"))
        }
        tree.addChild(of: both, entry: file(nfc))
        tree.addChild(of: both, entry: file(nfd))
        tree.addChild(of: onlyNFD, entry: file(nfd))
        tree.addChild(of: onlyNFD, entry: file(kelvin))
        tree.addChild(of: ascii, entry: file("K"))
        tree.recomputeAggregates()
        return tree
    }

    func testNarrowDirectoriesMatchTheOldLookup() {
        let tree = build(childrenPerDir: 3)
        assertMatchesOracle(tree, queries(root: "/r", dirs: ["both", "onlynfd", "ascii"]))
        XCTAssertTrue(tree.childNameIndexes.isEmpty)
        // Canonical equivalence is kept: an NFC query finds the NFD-only name.
        XCTAssertNotNil(tree.lookup(path: "/r/onlynfd/" + nfc))
    }

    func testWideDirectoriesMatchTheOldLookup() {
        let tree = build(childrenPerDir: 200)
        assertMatchesOracle(tree, queries(root: "/r", dirs: ["both", "onlynfd", "ascii"]))
        XCTAssertEqual(tree.childNameIndexes.count, 3)
        XCTAssertNotNil(tree.lookup(path: "/r/onlynfd/" + nfc))
    }

    func testRootGivenInTheOtherUnicodeForm() {
        for (rootForm, pathForm) in [(nfc, nfd), (nfd, nfc)] {
            let tree = FileTree(rootPath: "/u/" + rootForm, device: 1)
            let sub = tree.addChild(of: 0, entry: dir("sub"))
            let f = tree.addChild(of: sub, entry: file("f"))
            tree.recomputeAggregates()
            let base = "/u/" + pathForm
            assertMatchesOracle(tree, [base, base + "/", base + "/sub", base + "/sub/f", base + "//sub/f/",
                                       base + "/sub/missing", base + "x/sub", "/u", "/u/other/sub"])
            XCTAssertEqual(tree.lookup(path: base + "/sub/f"), f)
            XCTAssertEqual(tree.deepestNode(onPath: base + "/sub/missing/deeper"), sub)
            XCTAssertEqual(tree.deepestNode(onPath: base), FileTree.root)
        }
    }

    func testRootSlash() {
        let tree = FileTree(rootPath: "/", device: 1)
        tree.addChild(of: 0, entry: file("x"))
        assertMatchesOracle(tree, ["/", "////", "/x", "/x/", "/xy", "x"])
        // The old lookup turned "/" into an empty base and answered the root for "".
        XCTAssertNil(tree.lookup(path: ""))
    }

    func testIndexFollowsRemoveInsertAndDuplicates() {
        let tree = FileTree(rootPath: "/r", device: 1)
        let folder = tree.addChild(of: 0, entry: dir("wide"))
        for i in 0..<200 { tree.addChild(of: folder, entry: file("item\(i)")) }
        tree.recomputeAggregates()
        let first = try! XCTUnwrap(tree.lookup(path: "/r/wide/item42"))
        XCTAssertEqual(tree.childNameIndexes[folder]?.ids.count, 200)

        tree.removeSubtree(first)
        XCTAssertNil(tree.lookup(path: "/r/wide/item42"))
        let second = tree.insert(file("item42"), under: folder)
        XCTAssertEqual(tree.lookup(path: "/r/wide/item42"), second)
        tree.removeSubtree(second)
        let renamed = tree.insert(file("renamed"), under: folder)
        XCTAssertNil(tree.lookup(path: "/r/wide/item42"))
        XCTAssertEqual(tree.lookup(path: "/r/wide/renamed"), renamed)

        // Two siblings with one name: the newest answers, and removing it hands over to the older.
        let older = try! XCTUnwrap(tree.lookup(path: "/r/wide/item7"))
        let newer = tree.insert(file("item7"), under: folder)
        XCTAssertEqual(tree.lookup(path: "/r/wide/item7"), newer)
        tree.removeSubtree(newer)
        XCTAssertEqual(tree.lookup(path: "/r/wide/item7"), older)
        // Canonically equal siblings behave the same way.
        let composed = tree.insert(file(nfc), under: folder)
        let decomposed = tree.insert(file(nfd), under: folder)
        XCTAssertEqual(tree.lookup(path: "/r/wide/" + nfc), decomposed)
        tree.removeSubtree(decomposed)
        XCTAssertEqual(tree.lookup(path: "/r/wide/" + nfd), composed)
        assertMatchesOracle(tree, ["/r/wide/item7", "/r/wide/" + nfc, "/r/wide/" + nfd, "/r/wide/item42", "/r/wide/renamed"])
    }

    func testGraftUpdatesParentIndex() {
        let tree = FileTree(rootPath: "/r", device: 1)
        for i in 0..<200 { tree.addChild(of: 0, entry: file("item\(i)")) }
        let old = tree.addChild(of: 0, entry: dir("target"))
        tree.recomputeAggregates()
        XCTAssertEqual(tree.lookup(path: "/r/target"), old)
        let sub = FileTree(rootPath: "/other", device: 1)
        sub.addChild(of: 0, entry: file("inside"))
        sub.recomputeAggregates()
        let replaced = tree.graft(sub, as: "target", under: 0)
        XCTAssertNotEqual(old, replaced)
        XCTAssertEqual(tree.lookup(path: "/r/target"), replaced)
        XCTAssertEqual(tree.lookup(path: "/r/target/inside"), tree.child(named: "inside", of: replaced))
        assertMatchesOracle(tree, ["/r/target", "/r/target/inside", "/r/item5"])
    }

    func testRemovedDirectoryDropsItsIndex() {
        let tree = FileTree(rootPath: "/r", device: 1)
        let folder = tree.addChild(of: 0, entry: dir("wide"))
        for i in 0..<200 { tree.addChild(of: folder, entry: file("item\(i)")) }
        tree.recomputeAggregates()
        XCTAssertNotNil(tree.lookup(path: "/r/wide/item1"))
        XCTAssertNotNil(tree.childNameIndexes[folder])
        tree.removeSubtree(folder)
        XCTAssertNil(tree.childNameIndexes[folder])
        XCTAssertNil(tree.lookup(path: "/r/wide/item1"))
    }

    func testLazyIndexMemoryEffect() {
        let tree = FileTree(rootPath: "/r", device: 1)
        let folder = tree.addChild(of: 0, entry: dir("wide"))
        for i in 0..<20_000 { tree.addChild(of: folder, entry: file("item\(i)")) }
        tree.recomputeAggregates()
        XCTAssertTrue(tree.childNameIndexes.isEmpty)
        #if canImport(Darwin)
        var allocatedBefore = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &allocatedBefore)
        #endif
        XCTAssertNotNil(tree.lookup(path: "/r/wide/item19999"))
        let index = try! XCTUnwrap(tree.childNameIndexes[folder])
        XCTAssertEqual(index.ids.count, 20_000)
        #if canImport(Darwin)
        var allocatedAfter = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &allocatedAfter)
        print("INDEX_MEMORY entries=\(index.ids.count) heap_in_use_delta=\(allocatedAfter.size_in_use - allocatedBefore.size_in_use) bytes")
        #endif
    }
}
