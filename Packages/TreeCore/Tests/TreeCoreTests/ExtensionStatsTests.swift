import XCTest
@testable import TreeCore

final class ExtensionStatsTests: XCTestCase {
    /// The single-threaded String-keyed version `extensionStats` replaced; the oracle for every case here.
    private func oracle(_ nodes: [Node], under id: NodeID) -> [ExtensionStat] {
        var acc: [String: (Int64, Int64)] = [:]
        var stack = [id]
        while let cur = stack.popLast() {
            let n = nodes[Int(cur)]
            if n.isRemoved { continue }
            if n.isDirectory {
                var c = n.firstChild
                while c >= 0 { stack.append(c); c = nodes[Int(c)].nextSibling }
            } else {
                let ext = FileTree.fileExtension(n.name)
                let v = acc[ext, default: (0, 0)]
                acc[ext] = (v.0 + n.ownAlloc, v.1 + 1)
            }
        }
        return acc.map { ExtensionStat(ext: $0.key, bytes: $0.value.0, count: $0.value.1) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.ext < $1.ext }
    }

    static let edgeNames = [
        "a.jpg", "B.JPG", "c.JpEg", "Makefile", ".zshrc", "a.", "a..", "..", "a.b.c", "x.tar.gz",
        "long.extension9", "eight.abcdefgh", "nine.abcdefghi", "é.jpg", "a.JPÉG", "a.ÄBC", "a.\u{301}jpg",
        "a.jp\u{301}g", "a\u{600}.jpg", "a\u{600}.jpg.png", "數據.MOV", "a.mov\u{200D}", "a.\r\n", "a. b", "a.Ⅻ",
        "a.İ", "a.ß", "a.1", "a.9Z", ".", "a.b.", "UPPER.TXT", "a.Z", "a.@", "a.[", "a.`",
        "a.b\u{600}.", "x.\u{600}.", "a.;", "a.\u{37E}",
    ]

    func testKeyMatchesFileExtensionOnEdgeNames() {
        for name in Self.edgeNames {
            XCTAssertEqual(ExtensionKey(fileName: name).string, FileTree.fileExtension(name), name)
            XCTAssertEqual(ExtensionKey(fileName: name), ExtensionKey(extension: FileTree.fileExtension(name)), name)
        }
    }

    func testDifferentExtensionsGetDifferentKeys() {
        let exts = Set(Self.edgeNames.map(FileTree.fileExtension))
        XCTAssertEqual(Set(exts.map(ExtensionKey.init(extension:))).count, exts.count)
    }

    private func build(files: Int, seed: UInt64) -> (FileTree, [NodeID]) {
        var rng = seed
        func next() -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int(rng >> 33) }
        let t = FileTree(rootPath: "/r", device: 1)
        var dirs: [NodeID] = [FileTree.root]
        for i in 0..<(files / 20) {
            dirs.append(t.addChild(of: dirs[next() % dirs.count], entry: ScanEntry(name: "d\(i)", isDirectory: true, device: 1)))
        }
        let pool = Self.edgeNames + ["f.swift", "g.o", "h.PNG", "i.heic", "j.json", "k.MP4", "l", "m.dylib"]
        for i in 0..<files {
            let name = "\(i)" + pool[next() % pool.count]
            t.addChild(of: dirs[next() % dirs.count], entry: ScanEntry(name: name, isDirectory: false,
                       allocSize: Int64(next() % 100_000), logicalSize: 1, device: 1))
        }
        t.recomputeAggregates()
        return (t, dirs)
    }

    func testSmallTreeMatchesOracleForRootAndSubtrees() {
        let (t, dirs) = build(files: 2_000, seed: 1)
        XCTAssertEqual(t.extensionStats(), oracle(t.nodes, under: FileTree.root))
        for d in dirs.prefix(30) { XCTAssertEqual(t.extensionStats(under: d), oracle(t.nodes, under: d)) }
    }

    func testParallelPathMatchesOracleWithRemovedSubtrees() {
        let (t, dirs) = build(files: 120_000, seed: 7)
        XCTAssertGreaterThan(t.nodes.count, FileTree.parallelThreshold)
        for d in dirs.dropFirst().prefix(200) where !t[d].isRemoved { t.removeSubtree(d) }
        XCTAssertEqual(t.extensionStats(), oracle(t.nodes, under: FileTree.root))
        let big = dirs.max { t[$0].fileCount < t[$1].fileCount }!
        XCTAssertEqual(t.extensionStats(under: big), oracle(t.nodes, under: big))
    }

    /// A live update can land under a folder removed while its scan ran (FSEvents rescan racing a
    /// move to the Trash). What it adds must count as removed too: unreachable from the root, out of
    /// every statistic, and out of the snapshot, which would otherwise fail to read back.
    func testNodesAddedUnderARemovedFolderAreRemoved() throws {
        let (t, dirs) = build(files: 2_000, seed: 5)
        let gone = dirs[3]
        let before = t.extensionStats()
        t.removeSubtree(gone)
        let after = t.extensionStats()
        let file = t.insert(ScanEntry(name: "late.mov", isDirectory: false, allocSize: 999, logicalSize: 999, device: 1), under: gone)
        let sub = FileTree(rootPath: "/new", device: 1)
        sub.addChild(of: FileTree.root, entry: ScanEntry(name: "inner.mov", isDirectory: false, allocSize: 5, logicalSize: 5,
                                                          fileID: 77, linkCount: 2, device: 1))
        sub.recomputeAggregates()
        let grafted = t.graft(sub, as: "new", under: gone)
        XCTAssertTrue(t[file].isRemoved)
        XCTAssertTrue(t[grafted].isRemoved)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(t.extensionStats(), after)
        XCTAssertEqual(t.extensionStats(), oracle(t.nodes, under: FileTree.root))
        XCTAssertFalse(t.holders.values.contains { $0.contains { t[$0].isRemoved && t[$0].name == "inner.mov" } })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dscan")
        defer { try? FileManager.default.removeItem(at: url) }
        try Snapshot.write(t, meta: SnapshotMeta(rootPath: "/r", device: 1, createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                                 scanSeconds: 0, lastEventId: 0, eventsUUID: nil), to: url)
        XCTAssertEqual(try Snapshot.read(from: url).tree[FileTree.root].totalAlloc, t[FileTree.root].totalAlloc)
    }

    func testCanonicallyEquivalentExtensionsShareOneRow() {
        let t = FileTree(rootPath: "/r", device: 1)
        for name in ["a.;", "b.\u{37E}", "c.\u{1FEF}", "d.`"] {
            t.addChild(of: FileTree.root, entry: ScanEntry(name: name, isDirectory: false, allocSize: 1, logicalSize: 1, device: 1))
        }
        t.recomputeAggregates()
        XCTAssertEqual(t.extensionStats(), oracle(t.nodes, under: FileTree.root))
        XCTAssertEqual(t.extensionStats().count, 2)
    }

    func testRemovedOrUnknownScopeIsEmpty() {
        let (t, dirs) = build(files: 200, seed: 3)
        t.removeSubtree(dirs[1])
        XCTAssertEqual(t.extensionStats(under: dirs[1]), [])
        XCTAssertEqual(FileTree.extensionStats(in: t.nodes, under: NodeID(t.nodes.count)), [])
    }
}
