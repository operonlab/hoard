import Foundation
import XCTest
@testable import ScanCore

final class SnapshotCacheTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func cache(_ name: String, root: String, in directory: URL, modified: Date? = nil) throws -> URL {
        let file = directory.appendingPathComponent(name + ".dscan")
        let tree = FileTree(rootPath: root, device: 1)
        let meta = SnapshotMeta(rootPath: root, device: 1, createdAt: Date(), scanSeconds: 0,
                                lastEventId: 0, eventsUUID: nil)
        try Snapshot.write(tree, meta: meta, to: file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        return file
    }

    func testEvictsGoneOldAndUnreadableButKeepsRecentProtectedAndOtherFiles() throws {
        let dir = try directory()
        let existing = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let oldRoot = dir.appendingPathComponent("old-root")
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        let now = Date()
        let recent = try cache("recent", root: existing.path, in: dir)
        let gone = try cache("gone", root: dir.appendingPathComponent("missing").path, in: dir)
        let unplugged = try cache("unplugged", root: "/Volumes/NoSuchVolume-\(UUID().uuidString)/x", in: dir)
        let old = try cache("old", root: oldRoot.path, in: dir, modified: now.addingTimeInterval(-31 * 86_400))
        let protected = try cache("protected", root: existing.path, in: dir, modified: now.addingTimeInterval(-31 * 86_400))
        let bad = dir.appendingPathComponent("bad.dscan")
        try Data("garbage".utf8).write(to: bad)
        let history = dir.appendingPathComponent("history.dshist")
        let other = dir.appendingPathComponent("other.txt")
        try Data("history".utf8).write(to: history)
        try Data("other".utf8).write(to: other)

        let removed = SnapshotCache.evict(in: dir, keep: [existing.path], now: now)
        XCTAssertEqual(Set(removed.map { $0.file.lastPathComponent }), ["gone.dscan", "old.dscan", "bad.dscan"])
        XCTAssertEqual(removed.first(where: { $0.file.lastPathComponent == gone.lastPathComponent })?.reason, .rootGone)
        XCTAssertEqual(removed.first(where: { $0.file.lastPathComponent == old.lastPathComponent })?.reason, .unused)
        XCTAssertEqual(removed.first(where: { $0.file.lastPathComponent == bad.lastPathComponent })?.reason, .unreadable)
        for file in [recent, unplugged, protected, history, other] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
        }

        let later = SnapshotCache.evict(in: dir, keep: [], now: now)
        XCTAssertEqual(Set(later.map { $0.file.lastPathComponent }), ["protected.dscan"])
        XCTAssertTrue(later.allSatisfy { $0.reason == .unused && $0.bytesFreed > 0 })
    }

    /// A write that never finished (the app quit or crashed mid-save) leaves its temporary files behind.
    func testRemovesAbandonedWritesButNotOnesInProgress() throws {
        let dir = try directory()
        let now = Date()
        let old = now.addingTimeInterval(-2 * 86_400)
        let abandoned = dir.appendingPathComponent(".1e9796d61d60c7ac.dscan.\(UUID().uuidString).tmp")
        let abandonedRaw = dir.appendingPathComponent(".1e9796d61d60c7ac.dscan.\(UUID().uuidString).raw.tmp")
        let inProgress = dir.appendingPathComponent(".73266feaed1b31cf.dscan.\(UUID().uuidString).raw.tmp")
        let unrelated = dir.appendingPathComponent(".something.tmp")
        for file in [abandoned, abandonedRaw, inProgress, unrelated] { try Data("partial".utf8).write(to: file) }
        for file in [abandoned, abandonedRaw, unrelated] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        }

        let removed = SnapshotCache.evict(in: dir, keep: [], now: now)
        XCTAssertEqual(Set(removed.map { $0.file.lastPathComponent }), [abandoned.lastPathComponent, abandonedRaw.lastPathComponent])
        XCTAssertTrue(removed.allSatisfy { $0.reason == .abandonedWrite && $0.rootPath == nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: inProgress.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testKeepOverridesGoneRoot() throws {
        let dir = try directory()
        let root = dir.appendingPathComponent("missing").path
        let file = try cache("keep-gone", root: root, in: dir)
        XCTAssertTrue(SnapshotCache.evict(in: dir, keep: [root], now: Date()).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRootIsGone() throws {
        let dir = try directory()
        XCTAssertTrue(SnapshotCache.rootIsGone(dir.appendingPathComponent("missing").path))
        XCTAssertFalse(SnapshotCache.rootIsGone(dir.path))
        XCTAssertFalse(SnapshotCache.rootIsGone("/Volumes/NoSuchVolume-\(UUID().uuidString)/a"))
    }
}
