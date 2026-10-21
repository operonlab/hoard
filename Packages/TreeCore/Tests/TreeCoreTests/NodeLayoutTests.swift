import Foundation
import XCTest
import TreeCore

final class NodeLayoutTests: XCTestCase {
    func testStride() {
        XCTAssertLessThanOrEqual(MemoryLayout<Node>.stride, 128)
        XCTAssertEqual(MemoryLayout<Node>.stride, 120, "fileCount and dirCount are stored as Int32")
    }

    func testCorruptCountThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tree.dscan")
        let t = FileTree(rootPath: "/c", device: 1)
        t.addChild(of: FileTree.root, entry: ScanEntry(name: "f", isDirectory: false, allocSize: 1, device: 1))
        t.recomputeAggregates()
        try Snapshot.write(t, meta: SnapshotMeta(rootPath: "/c", device: 1, createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                                 scanSeconds: 0, lastEventId: 0, eventsUUID: nil), to: url)
        let valid = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(try Snapshot.read(from: url).tree[FileTree.root].fileCount, 1)
        let jsonLength = (0..<4).reduce(0) { $0 | Int(valid[8 + $1]) << (8 * $1) }
        let nameLength = (0..<4).reduce(0) { $0 | Int(valid[16 + jsonLength + $1]) << (8 * $1) }
        let fileCountOffset = 20 + jsonLength + nameLength + 102
        XCTAssertEqual(Array(valid[fileCountOffset..<(fileCountOffset + 8)]), [1, 0, 0, 0, 0, 0, 0, 0])
        // Out of range, and in range but not the sum of the children (Int32.max would let the next
        // live insert overflow the stored count).
        for bad in [Int64(Int32.max) + 1, -1, Int64(Int32.max), 2, 0] {
            var bytes = valid
            withUnsafeBytes(of: bad.littleEndian) { bytes.replaceSubrange(fileCountOffset..<(fileCountOffset + 8), with: $0) }
            try Data(bytes).write(to: url)
            XCTAssertThrowsError(try Snapshot.read(from: url), "fileCount \(bad)") {
                XCTAssertEqual($0 as? SnapshotError, .truncated)
            }
        }
    }

    private func build(_ t: FileTree) {
        let a = t.addChild(of: FileTree.root, entry: ScanEntry(name: "a", isDirectory: true, device: 1))
        for i in 0..<20 {
            t.addChild(of: i % 2 == 0 ? a : FileTree.root,
                       entry: ScanEntry(name: "f\(i)", isDirectory: false, allocSize: Int64(i + 1), logicalSize: 1, device: 1))
        }
        t.recomputeAggregates()
    }

    func testReserveCapacity() {
        let plain = FileTree(rootPath: "/r", device: 1)
        build(plain)
        let t = FileTree(rootPath: "/r", device: 1)
        t.reserveCapacity(nodes: 1000)
        XCTAssertGreaterThanOrEqual(t.nodes.capacity, 1000)
        build(t)
        XCTAssertEqual(t.nodes, plain.nodes)
        XCTAssertEqual(t[FileTree.root].totalAlloc, 210)
        let capacity = t.nodes.capacity
        t.reserveCapacity(nodes: 10)
        XCTAssertEqual(t.nodes.capacity, capacity)
        XCTAssertEqual(t.nodes, plain.nodes)
    }
}
