import Foundation
import XCTest
@testable import TreeCore

final class SnapshotCompressedTests: XCTestCase {
    private func fixture() throws -> (FileTree, SnapshotMeta, URL) {
        let tree = FileTree(rootPath: "/compressed", device: 7)
        for _ in 0..<300 {
            tree.addChild(of: FileTree.root, entry: ScanEntry(name: "repeated-name.txt", isDirectory: false,
                                                               allocSize: 128, device: 7))
        }
        tree.recomputeAggregates()
        let meta = SnapshotMeta(rootPath: tree.rootPath, device: tree.device,
                                createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                scanSeconds: 1, lastEventId: 2, eventsUUID: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (tree, meta, dir.appendingPathComponent("cache.dscan"))
    }

    private func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
    }

    func testChecksumVectors() {
        for (bytes, expected): ([UInt8], UInt64) in [
            ([], 0xcbf29ce484222325),
            (Array("a".utf8), 0x7b8990c03d9195ec),
            (Array("12345678".utf8), 0x4ac9c5a0009f893e),
            (Array("123456789abcd".utf8), 0x73ae3d8c0b29b7aa),
        ] {
            XCTAssertEqual(bytes.withUnsafeBytes { Snapshot.checksum($0) }, expected)
        }
    }

    #if canImport(Compression)
    func testChunkedRoundTripHeaderAndSize() throws {
        let (tree, meta, url) = try fixture()
        try Snapshot.write(tree, meta: meta, to: url, block: 31, chunkBytes: 4096)
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(bytes.prefix(4)), Array("DSCN".utf8))
        XCTAssertEqual(u32(bytes, 4), 3)
        let jsonLength = u32(bytes, 8)
        let storedMeta = try JSONDecoder().decode(SnapshotMeta.self, from: Data(bytes[12..<(12 + jsonLength)]))
        XCTAssertEqual(storedMeta.rootPath, tree.rootPath)
        XCTAssertEqual(storedMeta.formatVersion, 3)
        XCTAssertGreaterThan(u32(bytes, 20 + jsonLength), 2)
        let restored = try Snapshot.read(from: url).tree
        XCTAssertEqual(restored.nodes, tree.nodes)
        let legacy = url.deletingLastPathComponent().appendingPathComponent("legacy.dscan")
        try Snapshot.writeUncompressed(tree, meta: meta, to: legacy)
        XCTAssertLessThan(bytes.count, try Data(contentsOf: legacy).count)
        XCTAssertEqual(try Snapshot.read(from: legacy).tree.nodes, tree.nodes)
    }

    func testCorruptChunkAndWrongFileLengthThrow() throws {
        let (tree, meta, url) = try fixture()
        try Snapshot.write(tree, meta: meta, to: url, block: 31, chunkBytes: 4096)
        let good = [UInt8](try Data(contentsOf: url))
        let table = 24 + u32(good, 8)
        let chunks = u32(good, table - 4)
        let compressedStart = table + chunks * 16
        var badChecksum = good
        badChecksum[table + 8] ^= 1
        try Data(badChecksum).write(to: url)
        XCTAssertThrowsError(try Snapshot.read(from: url)) { XCTAssertEqual($0 as? SnapshotError, .truncated) }
        var flipped = good
        flipped[compressedStart + u32(good, table + 4) / 2] ^= 1
        try Data(flipped).write(to: url)
        XCTAssertThrowsError(try Snapshot.read(from: url)) { XCTAssertEqual($0 as? SnapshotError, .truncated) }
        for damaged in [Array(good.dropLast()), good + [0]] {
            try Data(damaged).write(to: url)
            XCTAssertThrowsError(try Snapshot.read(from: url)) { XCTAssertEqual($0 as? SnapshotError, .truncated) }
        }
    }

    /// A file that claims to expand far beyond what real caches do is refused before any memory is
    /// allocated for it.
    func testImplausibleExpansionIsRefused() {
        XCTAssertTrue(Snapshot.rawLengthPlausible(560_622_506, fileSize: 115_300_000))
        XCTAssertTrue(Snapshot.rawLengthPlausible(64 << 20, fileSize: 1_024))
        XCTAssertFalse(Snapshot.rawLengthPlausible((64 << 20) + 1, fileSize: 1_024))
        XCTAssertFalse(Snapshot.rawLengthPlausible(8 << 30, fileSize: 300_000))
        XCTAssertTrue(Snapshot.rawLengthPlausible(Int.max, fileSize: Int.max / 2))
    }
    #endif
}
