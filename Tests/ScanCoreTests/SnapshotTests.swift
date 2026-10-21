import Darwin
import Foundation
import XCTest
@testable import ScanCore

final class SnapshotTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("tree.dscan")
    }

    func testRoundTripCompactsAndPreservesDedupPromotion() throws {
        let url = try temporaryURL()
        let fixture = url.deletingLastPathComponent().appendingPathComponent("fixture")
        for dir in ["a/nested", "b", "gone"] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let h1URL = fixture.appendingPathComponent("a/nested/h1")
        let c1URL = fixture.appendingPathComponent("a/nested/c1")
        try Data(repeating: 1, count: 100).write(to: h1URL)
        try Data(repeating: 2, count: 40).write(to: c1URL)
        try FileManager.default.linkItem(at: h1URL, to: fixture.appendingPathComponent("b/h2"))
        let c2URL = fixture.appendingPathComponent("b/c2")
        if clonefile(c1URL.path, c2URL.path, 0) != 0 {
            try FileManager.default.copyItem(at: c1URL, to: c2URL)
        }
        try Data(repeating: 3, count: 5).write(to: fixture.appendingPathComponent("gone/dead"))
        let pointer = try XCTUnwrap(realpath(fixture.path, nil))
        defer { free(pointer) }
        let root = String(cString: pointer)
        let tree = FileTree(rootPath: root, device: 7)
        let a = tree.addChild(of: 0, entry: ScanEntry(name: "a", isDirectory: true, device: 7))
        let nested = tree.addChild(of: a, entry: ScanEntry(name: "nested", isDirectory: true, device: 7))
        let gone = tree.addChild(of: 0, entry: ScanEntry(name: "gone", isDirectory: true, device: 7))
        tree.addChild(of: gone, entry: ScanEntry(name: "dead", isDirectory: false, allocSize: 5, device: 7))
        let b = tree.addChild(of: 0, entry: ScanEntry(name: "b", isDirectory: true, device: 7))
        let h1 = tree.addChild(of: nested, entry: ScanEntry(name: "h1", isDirectory: false, allocSize: 100, logicalSize: 90, fileID: 17, linkCount: 2, device: 7))
        tree.addChild(of: b, entry: ScanEntry(name: "h2", isDirectory: false, allocSize: 100, logicalSize: 90, fileID: 17, linkCount: 2, device: 7))
        let c1 = tree.addChild(of: nested, entry: ScanEntry(name: "c1", isDirectory: false, allocSize: 40, logicalSize: 35, fileID: 18, cloneID: 42, sharesAllBlocks: true, device: 7))
        tree.addChild(of: b, entry: ScanEntry(name: "c2", isDirectory: false, allocSize: 40, logicalSize: 35, fileID: 19, cloneID: 42, sharesAllBlocks: true, device: 7))
        tree.recomputeAggregates()
        tree.removeSubtree(gone)
        try FileManager.default.removeItem(at: fixture.appendingPathComponent("gone"))
        let meta = SnapshotMeta(rootPath: tree.rootPath, device: tree.device, createdAt: Date(), scanSeconds: 0.1, lastEventId: 23, eventsUUID: "test")
        try Snapshot.write(tree, meta: meta, to: url)
        let (restored, decoded) = try Snapshot.read(from: url)
        XCTAssertEqual(decoded, meta)
        XCTAssertEqual(restored.nodeCount, tree.nodeCount - 2)
        for i in tree.nodes.indices where !tree.nodes[i].isRemoved {
            let path = tree.path(of: NodeID(i))
            let id = try XCTUnwrap(restored.lookup(path: path))
            var expected = tree[NodeID(i)]
            expected.parent = restored[id].parent
            expected.firstChild = restored[id].firstChild
            expected.nextSibling = restored[id].nextSibling
            XCTAssertEqual(restored[id], expected, "\(path)")
        }
        restored.removeSubtree(try XCTUnwrap(restored.lookup(path: tree.path(of: h1))))
        restored.removeSubtree(try XCTUnwrap(restored.lookup(path: tree.path(of: c1))))
        XCTAssertEqual(restored[0].totalAlloc, tree[0].totalAlloc)
        XCTAssertEqual(restored[try XCTUnwrap(restored.lookup(path: root + "/b"))].totalAlloc, 140)
    }

    func testCorruptInputThrows() throws {
        let url = try temporaryURL()
        try Data("XXXX".utf8).write(to: url)
        XCTAssertThrowsError(try Snapshot.read(from: url)) { XCTAssertEqual($0 as? SnapshotError, .badMagic) }
        try Data("DSCN".utf8).write(to: url)
        XCTAssertThrowsError(try Snapshot.read(from: url)) { XCTAssertEqual($0 as? SnapshotError, .truncated) }
    }

    func testMalformedVersionAndNodeLinksThrow() throws {
        let url = try temporaryURL()
        let tree = FileTree(rootPath: "/fixture", device: 1)
        let meta = SnapshotMeta(rootPath: tree.rootPath, device: 1, createdAt: Date(), scanSeconds: 0,
                                lastEventId: 0, eventsUUID: nil)
        try Snapshot.write(tree, meta: meta, to: url)
        let valid = try Data(contentsOf: url)
        var wrongVersion = valid
        let future = SnapshotMeta.currentFormat + 1
        wrongVersion.replaceSubrange(4..<8, with: [UInt8(future), 0, 0, 0])
        try wrongVersion.write(to: url)
        XCTAssertThrowsError(try Snapshot.read(from: url)) { XCTAssertEqual($0 as? SnapshotError, .unsupportedVersion(future)) }
        var badLink = valid
        let jsonLength = (0..<4).reduce(0) { $0 | Int(valid[8 + $1]) << (8 * $1) }
        let nameLengthOffset = 12 + jsonLength + 4
        let nameLength = (0..<4).reduce(0) { $0 | Int(valid[nameLengthOffset + $1]) << (8 * $1) }
        let recordOffset = nameLengthOffset + 4 + nameLength
        badLink.replaceSubrange((recordOffset + 8)..<(recordOffset + 12), with: [0, 0, 0, 0])
        try badLink.write(to: url)
        XCTAssertThrowsError(try Snapshot.read(from: url)) { XCTAssertEqual($0 as? SnapshotError, .truncated) }
    }

    func testMillionNodePerformanceWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["HOARD_PERF"] == "1" else { return }
        let tree = FileTree(rootPath: "/fixture", device: 1)
        for i in 0..<999_999 {
            tree.addChild(of: 0, entry: ScanEntry(name: "f\(i)", isDirectory: false, allocSize: 1, logicalSize: 1, device: 1))
        }
        tree.recomputeAggregates()
        let meta = SnapshotMeta(rootPath: tree.rootPath, device: 1, createdAt: Date(), scanSeconds: 1, lastEventId: 1, eventsUUID: nil)
        let url = try temporaryURL()
        let start = CFAbsoluteTimeGetCurrent()
        try Snapshot.write(tree, meta: meta, to: url)
        let write = CFAbsoluteTimeGetCurrent() - start
        let readStart = CFAbsoluteTimeGetCurrent()
        let restored = try Snapshot.read(from: url).tree
        let read = CFAbsoluteTimeGetCurrent() - readStart
        print("SNAPSHOT_PERF write=\(write) read=\(read) total=\(write + read) seconds")
        XCTAssertEqual(restored.nodeCount, 1_000_000)
        XCTAssertLessThan(write + read, 1.5)
    }
}

extension SnapshotTests {
    func testIncrementalSessionUsesValidSnapshotAndLogsFallback() throws {
        let cache = try temporaryURL()
        let rootURL = cache.deletingLastPathComponent().appendingPathComponent("root")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 42).write(to: rootURL.appendingPathComponent("first"))
        let pointer = try XCTUnwrap(realpath(rootURL.path, nil))
        defer { free(pointer) }
        let root = String(cString: pointer)
        let scanner = ScanCore.Scanner()
        let originalLog = IncrementalSession.log
        var messages: [String] = []
        IncrementalSession.log = { messages.append($0) }
        defer { IncrementalSession.log = originalLog }
        let first = try IncrementalSession.open(root: root, scanner: scanner, snapshotURL: cache,
                                                currentEventId: { 99 }, eventsUUID: { _ in "fixture-uuid" })
        guard case .fullScan = first.source else { return XCTFail("initial open must scan") }
        XCTAssertTrue(messages.contains { $0.contains("no snapshot") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        let second = try IncrementalSession.open(root: root, scanner: scanner, snapshotURL: cache,
                                                 eventsUUID: { _ in "fixture-uuid" })
        guard case .snapshot(_, let eventID) = second.source else { return XCTFail("valid snapshot must load") }
        XCTAssertEqual(eventID, 99)
        XCTAssertEqual(second.tree[0].totalAlloc, first.tree[0].totalAlloc)
        messages.removeAll()
        let changedUUID = try IncrementalSession.open(root: root, scanner: scanner, snapshotURL: cache,
                                                      currentEventId: { 100 }, eventsUUID: { _ in "new-uuid" })
        guard case .fullScan = changedUUID.source else { return XCTFail("changed UUID must rescan") }
        XCTAssertTrue(messages.contains { $0.contains("UUID unavailable or changed") })
        try Data("broken".utf8).write(to: cache)
        messages.removeAll()
        let recovered = try IncrementalSession.open(root: root, scanner: scanner, snapshotURL: cache,
                                                    currentEventId: { 101 }, eventsUUID: { _ in "new-uuid" })
        guard case .fullScan = recovered.source else { return XCTFail("corrupt snapshot must rescan") }
        XCTAssertTrue(messages.contains { $0.contains("snapshot rejected") })
        let session = IncrementalSession(root: root)
        try session.save(tree: recovered.tree, lastEventId: 123, to: cache)
        XCTAssertEqual(try Snapshot.read(from: cache).meta.lastEventId, 123)
    }
}
