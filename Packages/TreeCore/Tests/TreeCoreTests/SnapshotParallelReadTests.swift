import Foundation
import XCTest
@testable import TreeCore

/// Snapshots big enough for `Snapshot.read` to decode in parallel chunks (65,536 records or more).
/// Names come from byte arrays, never literals, so storage sharing is the reader's doing.
final class SnapshotParallelReadTests: XCTestCase {
    private static let fileCount = 90_000
    private func name(_ text: String) -> String { String(decoding: Array(text.utf8), as: UTF8.self) }

    private func address(_ s: String) -> UInt {
        var copy = s
        return copy.withUTF8 { UInt(bitPattern: $0.baseAddress) }
    }

    /// Hardlinks and clones whose holders sit far apart (so in different chunks), long names repeated
    /// near and far, NFC and NFD spellings of one long name, short names.
    private func bigTree() -> FileTree {
        let t = FileTree(rootPath: "/big", device: 1)
        var dirs: [NodeID] = []
        for d in 0..<300 { dirs.append(t.addChild(of: FileTree.root, entry: ScanEntry(name: "dir\(d)", isDirectory: true, device: 1))) }
        let nfc = "caf\u{E9}-a-long-name-in-composed-form.txt", nfd = "cafe\u{301}-a-long-name-in-composed-form.txt"
        for i in 0..<Self.fileCount {
            let n: String
            switch i % 7 {
            case 0: n = name("__init__.cpython-312.pyc")
            case 1: n = name(i % 2 == 0 ? nfc : nfd)
            case 2: n = name("unique-long-name-number-\(i).bin")
            case 3: n = name("s\(i % 50).c")
            default: n = name("f\(i).txt")
            }
            var entry = ScanEntry(name: n, isDirectory: false, allocSize: Int64(i % 997 + 1), logicalSize: Int64(i), device: 1)
            if i % 101 == 0 {  // one inode under two names, 446 × 101 records apart
                entry.fileID = UInt64(i / 101 % 446 + 1_000_000); entry.linkCount = 2
            } else if i % 103 == 0 {  // one clone group of three, spread over the whole file
                entry.fileID = UInt64(i); entry.cloneID = UInt64(i % 3 + 7); entry.sharesAllBlocks = true
            }
            t.addChild(of: dirs[(i * 7919) % dirs.count], entry: entry)
        }
        t.recomputeAggregates()
        return t
    }

    private func write(_ tree: FileTree, uncompressed: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.dscan")
        let meta = SnapshotMeta(rootPath: tree.rootPath, device: tree.device, createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                scanSeconds: 0, lastEventId: 0, eventsUUID: nil)
        if uncompressed { try Snapshot.writeUncompressed(tree, meta: meta, to: url) }
        else { try Snapshot.write(tree, meta: meta, to: url) }
        return url
    }

    /// Offset of record `index` in the file bytes.
    private func record(_ index: Int, in bytes: [UInt8]) -> Int {
        func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
        let json = u32(8)
        let names = u32(16 + json)
        return 20 + json + names + index * 118
    }

    func testParallelReadRestoresEveryNodeAndDedupHolder() throws {
        let original = bigTree()
        XCTAssertGreaterThan(original.nodeCount, 65_536)
        let restored = try Snapshot.read(from: try write(original)).tree
        XCTAssertEqual(restored.nodeCount, original.nodeCount)
        for i in 0..<original.nodeCount {
            let a = original.nodes[i], b = restored.nodes[i]
            guard Array(a.name.utf8) == Array(b.name.utf8), a.parent == b.parent, a.firstChild == b.firstChild,
                  a.nextSibling == b.nextSibling, a.flags == b.flags, a.status == b.status, a.rawAlloc == b.rawAlloc,
                  a.ownAlloc == b.ownAlloc, a.logicalSize == b.logicalSize, a.fileID == b.fileID, a.cloneID == b.cloneID,
                  a.linkCount == b.linkCount, a.totalAlloc == b.totalAlloc, a.fileCount == b.fileCount else {
                return XCTFail("node \(i) differs: \(a) vs \(b)")
            }
        }
        // Holders gathered while decoding match a sequential rebuild, order included.
        let sequential = FileTree(restoring: restored.nodes, rootPath: restored.rootPath, device: restored.device)
        XCTAssertFalse(restored.holders.isEmpty)
        XCTAssertEqual(restored.holders, sequential.holders)
        XCTAssertEqual(restored.holders, original.holders)
        // And they work: removing a primary hands its bytes to the other name.
        let primary = original.holders.values.first { $0.count == 2 }![0]
        original.removeSubtree(primary)
        restored.removeSubtree(primary)
        XCTAssertEqual(restored[FileTree.root].totalAlloc, original[FileTree.root].totalAlloc)
    }

    func testEqualLongNamesShareStorageAndCanonicalTwinsStayDistinct() throws {
        let restored = try Snapshot.read(from: try write(bigTree())).tree
        let pyc = restored.nodes.indices.filter { restored.nodes[$0].name == "__init__.cpython-312.pyc" }
        XCTAssertGreaterThan(pyc.count, 10_000)
        // Within one chunk (neighbouring records) every repeat is the same storage.
        let near = pyc.prefix(50).map { address(restored.nodes[$0].name) }
        XCTAssertEqual(Set(near).count, 1)
        // NFC and NFD compare equal as Strings but are different bytes: both spellings survive.
        let cafe = Set(restored.nodes.filter { $0.name.hasPrefix("caf") }.map { Array($0.name.utf8) })
        XCTAssertEqual(cafe.count, 2)
    }

    func testNamesWithTheSameHashTagStayDistinct() throws {
        // Two long names whose hashes agree in the 32 bits the name table keeps.
        var seen: [UInt64: String] = [:]
        var pair: (String, String)?
        for i in 0..<400_000 where pair == nil {
            let n = "tag-collision-probe-\(i).dat"
            let tag = n.utf8.withContiguousStorageIfAvailable { NameInterner.hash(UnsafeRawBufferPointer($0)) }! & 0xFFFF_FFFF
            if let other = seen[tag] { pair = (other, n) } else { seen[tag] = n }
        }
        let (a, b) = try XCTUnwrap(pair)
        let t = bigTree()
        let d = t.addChild(of: FileTree.root, entry: ScanEntry(name: "collide", isDirectory: true, device: 1))
        for n in [a, b, a, b] { t.addChild(of: d, entry: ScanEntry(name: name(n), isDirectory: false, allocSize: 1, device: 1)) }
        t.recomputeAggregates()
        let restored = try Snapshot.read(from: try write(t)).tree
        XCTAssertEqual(restored.sortedChildren(of: restored.child(named: "collide", of: FileTree.root)!).map { restored[$0].name }.sorted(),
                       [a, a, b, b].sorted())
    }

    func testCorruptRecordInAnyChunkThrows() throws {
        let url = try write(bigTree(), uncompressed: true)
        let good = [UInt8](try Data(contentsOf: url))
        let count = SnapshotParallelReadTests.fileCount + 301
        for index in [1, count / 2, count - 1] {
            var bytes = good
            let parent = record(index, in: bytes) + 8
            for k in 0..<4 { bytes[parent + k] = 0x7F }  // parent far beyond the record's own index
            try Data(bytes).write(to: url)
            XCTAssertThrowsError(try Snapshot.read(from: url), "record \(index)") { XCTAssertEqual($0 as? SnapshotError, .truncated) }
        }
    }

    func testInvalidUTF8InLateChunkThrows() throws {
        let url = try write(bigTree(), uncompressed: true)
        let good = [UInt8](try Data(contentsOf: url))
        let count = SnapshotParallelReadTests.fileCount + 301
        func nameRange(_ index: Int, _ bytes: [UInt8]) -> Range<Int> {
            let r = record(index, in: bytes)
            func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
            let json = u32(8)
            let blob = 20 + json
            return (blob + u32(r))..<(blob + u32(r) + u32(r + 4))
        }
        // The last record holding a short name, then the last holding a unique long name.
        for wantLong in [false, true] {
            let index = (0..<count).reversed().first {
                let n = nameRange($0, good).count
                return wantLong ? n > NameInterner.inlineLimit && good[nameRange($0, good)].starts(with: Array("unique".utf8))
                                : n <= NameInterner.inlineLimit
            }!
            var bytes = good
            bytes[nameRange(index, bytes).last!] = 0xFF
            try Data(bytes).write(to: url)
            XCTAssertThrowsError(try Snapshot.read(from: url), "long \(wantLong)") { XCTAssertEqual($0 as? SnapshotError, .truncated) }
        }
    }
}
