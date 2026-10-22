import Foundation
import XCTest
@testable import TreeCore

/// The parallel writer must produce exactly the bytes of the sequential writer it replaced.
final class SnapshotParallelWriteTests: XCTestCase {
    private let meta = SnapshotMeta(rootPath: "/big", device: 1, createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                    scanSeconds: 2, lastEventId: 9, eventsUUID: "w")

    /// The sequential writer `Snapshot.write` replaced, as it was; returns the file bytes.
    private func oracle(_ tree: FileTree, meta: SnapshotMeta) throws -> [UInt8] {
        var legacyMeta = meta
        legacyMeta.formatVersion = 2
        let metadata = try JSONEncoder().encode(legacyMeta)
        let old = tree.nodes
        var ids = [Int32](repeating: -1, count: old.count)
        var live: [Int] = []
        for i in old.indices where !old[i].isRemoved {
            ids[i] = Int32(live.count)
            live.append(i)
        }
        var names: [UInt8] = []
        var nameRanges: [(UInt32, UInt32)] = []
        for i in live {
            let bytes = old[i].name.utf8
            nameRanges.append((UInt32(names.count), UInt32(bytes.count)))
            names.append(contentsOf: bytes)
        }
        var out: [UInt8] = [0x44, 0x53, 0x43, 0x4e]
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        put(UInt32(2))
        put(UInt32(metadata.count)); out.append(contentsOf: metadata)
        put(UInt32(live.count))
        put(UInt32(names.count)); out.append(contentsOf: names)
        for (index, oldID) in live.enumerated() {
            let n = old[oldID]
            let range = nameRanges[index]
            func mapped(_ id: NodeID) -> Int32 { id < 0 ? -1 : ids[Int(id)] }
            var child = n.firstChild
            while child >= 0 && old[Int(child)].isRemoved { child = old[Int(child)].nextSibling }
            var sibling = n.nextSibling
            while sibling >= 0 && old[Int(sibling)].isRemoved { sibling = old[Int(sibling)].nextSibling }
            put(range.0); put(range.1)
            put(mapped(n.parent)); put(mapped(child)); put(mapped(sibling))
            put(n.flags.rawValue); put(n.status.rawValue)
            put(n.rawAlloc); put(n.ownAlloc); put(n.logicalSize); put(n.modTime); put(n.accessTime)
            put(n.fileID); put(n.cloneID); put(n.linkCount); put(n.device)
            put(n.totalAlloc); put(n.totalLogical); put(n.fileCount); put(n.dirCount)
        }
        return out
    }

    /// Equal files, except that the meta JSON is compared decoded: JSONEncoder does not keep a key
    /// order from one call to the next.
    private func assertSameSnapshot(_ written: [UInt8], _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
        func u32(_ b: [UInt8], _ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(b[at + $1]) << (8 * $1) } }
        XCTAssertEqual(Array(written.prefix(8)), Array(expected.prefix(8)), file: file, line: line)
        let length = u32(written, 8)
        XCTAssertEqual(length, u32(expected, 8), "meta length", file: file, line: line)
        guard length == u32(expected, 8) else { return }
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(SnapshotMeta.self, from: Data(written[12..<(12 + length)])),
                       try decoder.decode(SnapshotMeta.self, from: Data(expected[12..<(12 + length)])), file: file, line: line)
        XCTAssertEqual(written.count, expected.count, "file size", file: file, line: line)
        if let first = (12 + length ..< min(written.count, expected.count)).first(where: { written[$0] != expected[$0] }) {
            XCTFail("first differing byte at \(first)", file: file, line: line)
        }
    }

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// 100k+ nodes with removed subtrees and removed files scattered over every chunk, so ids shift
    /// and live children/siblings are found past removed ones across chunk boundaries.
    private func bigTree() -> FileTree {
        let t = FileTree(rootPath: "/big", device: 1)
        var dirs: [NodeID] = [FileTree.root]
        for d in 0..<2_000 {
            dirs.append(t.addChild(of: dirs[(d * 31) % dirs.count], entry: ScanEntry(name: "d\(d)", isDirectory: true, device: 1)))
        }
        var files: [NodeID] = []
        for i in 0..<110_000 {
            let n = String(decoding: Array((i % 3 == 0 ? "a-long-shared-file-name-\(i % 40).dat" : "f\(i).é").utf8), as: UTF8.self)
            files.append(t.addChild(of: dirs[(i * 7919) % dirs.count], entry: ScanEntry(
                name: n, isDirectory: false, allocSize: Int64(i % 4096), logicalSize: Int64(i), fileID: UInt64(i + 1),
                linkCount: i % 97 == 0 ? 2 : 1, device: 1)))
        }
        t.recomputeAggregates()
        for d in stride(from: 5, to: dirs.count, by: 37) where !t[dirs[d]].isRemoved { t.removeSubtree(dirs[d]) }
        for f in stride(from: 3, to: files.count, by: 101) where !t[files[f]].isRemoved { t.removeSubtree(files[f]) }
        return t
    }

    func testParallelWriteMatchesSequentialBytes() throws {
        let tree = bigTree()
        XCTAssertGreaterThan(tree.nodeCount, 65_536)
        XCTAssertGreaterThan(tree.nodes.filter(\.isRemoved).count, 1_000)
        let url = try directory().appendingPathComponent("big.dscan")
        try Snapshot.writeUncompressed(tree, meta: meta, to: url)
        try assertSameSnapshot([UInt8](try Data(contentsOf: url)), try oracle(tree, meta: meta))
        // And it reads back to the same live tree.
        let restored = try Snapshot.read(from: url).tree
        XCTAssertEqual(restored[FileTree.root].totalAlloc, tree[FileTree.root].totalAlloc)
        XCTAssertEqual(restored[FileTree.root].fileCount, tree[FileTree.root].fileCount)
    }

    func testManyBlocksPerChunkMatchSequentialBytes() throws {
        let tree = bigTree()
        let url = try directory().appendingPathComponent("blocks.dscan")
        try Snapshot.writeUncompressed(tree, meta: meta, to: url, block: 997)
        try assertSameSnapshot([UInt8](try Data(contentsOf: url)), try oracle(tree, meta: meta))
    }

    func testSmallTreeMatchesSequentialBytes() throws {
        let t = FileTree(rootPath: "/big", device: 1)
        let a = t.addChild(of: FileTree.root, entry: ScanEntry(name: "a", isDirectory: true, device: 1))
        let x = t.addChild(of: a, entry: ScanEntry(name: "x", isDirectory: false, allocSize: 5, device: 1))
        t.addChild(of: a, entry: ScanEntry(name: "y", isDirectory: false, allocSize: 7, device: 1))
        t.recomputeAggregates()
        t.removeSubtree(x)
        let url = try directory().appendingPathComponent("small.dscan")
        try Snapshot.writeUncompressed(t, meta: meta, to: url)
        try assertSameSnapshot([UInt8](try Data(contentsOf: url)), try oracle(t, meta: meta))
    }

    func testFailedWriteLeavesNoTempFileAndKeepsTheOldSnapshot() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("keep.dscan")
        try Snapshot.write(bigTree(), meta: meta, to: url)
        let before = try Data(contentsOf: url)
        // A read-only folder: the temp file cannot be created.
        XCTAssertEqual(chmod(dir.path, 0o555), 0)
        defer { chmod(dir.path, 0o755) }
        XCTAssertThrowsError(try Snapshot.write(bigTree(), meta: meta, to: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["keep.dscan"])
    }
}
