import Darwin
import Foundation
import XCTest
@testable import ScanCore

final class LiveUpdaterTests: XCTestCase {
    private func fixture() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HoardLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let path = try XCTUnwrap(realpath(url.path, nil))
        defer { free(path) }
        let resolved = String(cString: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: resolved) }
        return resolved
    }

    private func write(_ path: String, _ count: Int) throws {
        try Data(repeating: 65, count: count).write(to: URL(fileURLWithPath: path))
    }

    private func matches(_ tree: FileTree, _ fresh: FileTree) -> Bool {
        let a = tree[0], b = fresh[0]
        guard a.totalAlloc == b.totalAlloc, a.fileCount == b.fileCount, a.dirCount == b.dirCount else { return false }
        let old = Dictionary(uniqueKeysWithValues: tree.children(of: 0).map { (tree[$0].name, tree[$0]) })
        let now = Dictionary(uniqueKeysWithValues: fresh.children(of: 0).map { (fresh[$0].name, fresh[$0]) })
        guard old.keys == now.keys else { return false }
        return old.allSatisfy { name, node in
            guard let other = now[name] else { return false }
            return node.totalAlloc == other.totalAlloc && node.totalLogical == other.totalLogical &&
                node.fileCount == other.fileCount && node.dirCount == other.dirCount && node.flags == other.flags
        }
    }

    func testLiveChangesConvergeToFreshScan() throws {
        let root = try fixture()
        try write(root + "/grow", 10)
        try write(root + "/delete", 20)
        try FileManager.default.createDirectory(atPath: root + "/old", withIntermediateDirectories: false)
        try write(root + "/old/file", 30)
        let scanner = ScanCore.Scanner()
        let tree = try scanner.scan(root: root)
        var waiting: XCTestExpectation?
        let updater = LiveUpdater(tree: tree, scanner: scanner, sinceEventId: nil) { summary in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(summary.requiresFullRescan)
            if let fresh = try? scanner.scan(root: root), self.matches(tree, fresh) {
                waiting?.fulfill(); waiting = nil
            }
        }
        do { try updater.start() }
        catch LiveUpdaterError.cannotStartStream { throw XCTSkip("FSEvents unavailable in this sandbox") }
        defer { updater.stop() }
        func change(_ label: String, _ action: () throws -> Void) throws {
            let expected = expectation(description: label)
            waiting = expected
            try action()
            wait(for: [expected], timeout: 10)
            XCTAssertTrue(matches(tree, try scanner.scan(root: root)), label)
        }
        try change("create file") { try write(root + "/new", 40) }
        try change("grow file") { try write(root + "/grow", 8192) }
        try change("delete file") { try FileManager.default.removeItem(atPath: root + "/delete") }
        try change("create directory with files") {
            try FileManager.default.createDirectory(atPath: root + "/newdir", withIntermediateDirectories: false)
            try write(root + "/newdir/nested", 50)
        }
        try change("delete directory") { try FileManager.default.removeItem(atPath: root + "/old") }
        try change("rename directory") { try FileManager.default.moveItem(atPath: root + "/newdir", toPath: root + "/renamed") }
    }

    func testRealPathMapsToRootSpelling() throws {
        let spelling = FileManager.default.temporaryDirectory.path
        let pointer = try XCTUnwrap(realpath(spelling, nil))
        defer { free(pointer) }
        let real = String(cString: pointer)
        XCTAssertEqual(LiveUpdater.mapEventPath(real + "/child", rootPath: spelling, realRoot: real),
                       spelling + "/child")
        XCTAssertNil(LiveUpdater.mapEventPath("/elsewhere/child", rootPath: spelling, realRoot: real))
    }

    func testDirectoryDiffConvergesWithoutFSEvents() throws {
        let root = try fixture()
        try write(root + "/grow", 10)
        try write(root + "/delete", 20)
        try FileManager.default.createDirectory(atPath: root + "/old", withIntermediateDirectories: false)
        try write(root + "/old/file", 30)
        let scanner = ScanCore.Scanner()
        let tree = try scanner.scan(root: root)
        var waiting: XCTestExpectation?
        var summaries: [UpdateSummary] = []
        let updater = LiveUpdater(tree: tree, scanner: scanner, sinceEventId: 10) { summary in
            summaries.append(summary)
            waiting?.fulfill()
            waiting = nil
        }
        func change(_ label: String, path: String? = nil, full: Bool = false, _ action: () throws -> Void) throws {
            try action()
            let expected = expectation(description: label)
            waiting = expected
            updater.applyDirectoryEvents([(path ?? root, full)], eventId: UInt64(11 + summaries.count))
            wait(for: [expected], timeout: 10)
            XCTAssertFalse(try XCTUnwrap(summaries.last).requiresFullRescan, label)
            XCTAssertTrue(matches(tree, try scanner.scan(root: root)), label)
        }
        try change("create file") { try write(root + "/new", 40) }
        let stable = try XCTUnwrap(tree.lookup(path: root + "/grow"))
        try change("unchanged listing") {}
        XCTAssertEqual(tree.lookup(path: root + "/grow"), stable)
        XCTAssertEqual(summaries.last?.nodesAdded, 0)
        XCTAssertEqual(summaries.last?.nodesRemoved, 0)
        try change("grow file") { try write(root + "/grow", 8192) }
        try change("delete file") { try FileManager.default.removeItem(atPath: root + "/delete") }
        try change("create directory with files") {
            try FileManager.default.createDirectory(atPath: root + "/newdir", withIntermediateDirectories: false)
            try write(root + "/newdir/nested", 50)
        }
        try change("nested file", path: root + "/newdir") { try write(root + "/newdir/nested", 9000) }
        try change("delete directory", path: root + "/old") { try FileManager.default.removeItem(atPath: root + "/old") }
        try change("rename directory") { try FileManager.default.moveItem(atPath: root + "/newdir", toPath: root + "/renamed") }
        try change("full root rescan", full: true) { try write(root + "/last", 30) }
        try write(root + "/renamed/another", 70)
        let coalesced = expectation(description: "full ancestor coalesces descendant")
        waiting = coalesced
        updater.applyDirectoryEvents([(root, true), (root + "/renamed", false)], eventId: 100)
        wait(for: [coalesced], timeout: 10)
        XCTAssertEqual(summaries.last?.dirsRescanned, 1)
        XCTAssertTrue(matches(tree, try scanner.scan(root: root)))
        XCTAssertEqual(updater.lastEventId, 100)
        let invalid = expectation(description: "root changed signals full rescan")
        waiting = invalid
        updater.applyDirectoryEvents([(root, false)], eventId: 101, invalid: true)
        wait(for: [invalid], timeout: 10)
        XCTAssertTrue(try XCTUnwrap(summaries.last).requiresFullRescan)
        XCTAssertEqual(updater.lastEventId, 100)
    }

    /// Batches that queue while one is applied are applied as one, so a folder they all name is listed
    /// once. A full rescan of `a` covers `a/b/c` but not its prefix sibling `ab`.
    func testQueuedBatchesMergeAndFullRescanCoversOnlyDescendants() throws {
        let root = try fixture()
        for dir in ["a/b/c", "ab", "x"] {
            try FileManager.default.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
        }
        try write(root + "/x/f", 10)
        let scanner = ScanCore.Scanner()
        let tree = try scanner.scan(root: root)
        var summaries: [UpdateSummary] = []
        var done: XCTestExpectation? = expectation(description: "covered")
        let updater = LiveUpdater(tree: tree, scanner: scanner, sinceEventId: 10) { summary in
            summaries.append(summary)
            done?.fulfill()
            done = nil
        }
        try write(root + "/ab/new", 20)
        updater.applyDirectoryEvents([(root + "/a", true), (root + "/a/b/c", false), (root + "/ab", false)], eventId: 11)
        wait(for: [try XCTUnwrap(done)], timeout: 10)
        XCTAssertEqual(summaries.last?.dirsRescanned, 2)

        let merged = expectation(description: "merged")
        merged.expectedFulfillmentCount = 2
        done = nil
        let count = summaries.count
        let watcher = LiveUpdater(tree: tree, scanner: scanner, sinceEventId: 20) { summary in
            summaries.append(summary)
            merged.fulfill()
        }
        try write(root + "/x/g", 30)
        // The first batch starts at once; the next three queue behind it and go as one listing of x.
        for id in 21...24 { watcher.applyDirectoryEvents([(root + "/x", false)], eventId: UInt64(id)) }
        wait(for: [merged], timeout: 10)
        XCTAssertEqual(summaries.count - count, 2)
        XCTAssertEqual(summaries.dropFirst(count).map(\.dirsRescanned), [1, 1])
        XCTAssertEqual(watcher.lastEventId, 24)
        XCTAssertTrue(matches(tree, try scanner.scan(root: root)))
    }

    func testInvalidBatchDropsQueuedValidBatch() throws {
        let root = try fixture()
        try write(root + "/file", 10)
        let scanner = ScanCore.Scanner()
        let tree = try scanner.scan(root: root)
        var summaries: [UpdateSummary] = []
        let done = expectation(description: "invalid batch")
        let updater = LiveUpdater(tree: tree, scanner: scanner, sinceEventId: 10) { summary in
            summaries.append(summary)
            if summary.requiresFullRescan { done.fulfill() }
        }
        updater.applyDirectoryEvents([(root, true)], eventId: 11)
        updater.applyDirectoryEvents([(root, false)], eventId: 12)
        updater.applyDirectoryEvents([(root, false)], eventId: 13, invalid: true)
        wait(for: [done], timeout: 10)
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.map(\.requiresFullRescan), [false, true])
        XCTAssertEqual(updater.lastEventId, 11)
    }

    func testOfflineReplayConverges() throws {
        let root = try fixture()
        try write(root + "/old", 10)
        let since = LiveUpdater.currentEventId()
        let scanner = ScanCore.Scanner()
        let tree = try scanner.scan(root: root)
        try write(root + "/new", 30)
        try FileManager.default.removeItem(atPath: root + "/old")
        var expected: XCTestExpectation?
        let updater = LiveUpdater(tree: tree, scanner: scanner, sinceEventId: since) { summary in
            XCTAssertFalse(summary.requiresFullRescan)
            if let fresh = try? scanner.scan(root: root), self.matches(tree, fresh) { expected?.fulfill(); expected = nil }
        }
        do { try updater.start() }
        catch LiveUpdaterError.cannotStartStream { throw XCTSkip("FSEvents unavailable in this sandbox") }
        defer { updater.stop() }
        let replay = expectation(description: "offline replay")
        expected = replay
        wait(for: [replay], timeout: 10)
        XCTAssertTrue(matches(tree, try scanner.scan(root: root)))
    }
}
