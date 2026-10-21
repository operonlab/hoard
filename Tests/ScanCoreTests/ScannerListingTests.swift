import XCTest
@testable import ScanCore

final class ScannerListingTests: XCTestCase {
    func testIncompleteListingThrowsInsteadOfReturningAPartialList() {
        let partial = ([ScanEntry(name: "kept", isDirectory: false)], false)
        XCTAssertThrowsError(try Scanner.complete(partial, path: "/x")) { error in
            XCTAssertEqual(error as? ScanError, .incompleteListing(path: "/x"))
        }
        let full = ([ScanEntry(name: "kept", isDirectory: false)], true)
        XCTAssertEqual(try Scanner.complete(full, path: "/x").map(\.name), ["kept"])
    }

    func testFolderThatTurnsUnreadableStopsCountingItsOldContents() throws {
        // Codex review (phase 2, finding 2): keeping the old bytes of a folder we can no longer read
        // would make "≥ size" overstate. It turns unavailable and its contents stop counting.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ds-listing-\(UUID().uuidString)")
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: locked.appendingPathComponent("f").path, contents: Data(count: 4096))
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
        let root = try XCTUnwrap(realpath(dir.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        let tree = try Scanner().scan(root: root)
        let lockedID = try XCTUnwrap(tree.child(named: "locked", of: FileTree.root))
        let before = tree[FileTree.root].totalAlloc
        XCTAssertGreaterThan(before, 0)

        chmod(locked.path, 0o000)
        let done = expectation(description: "batch applied")
        var summary: UpdateSummary?
        let updater = LiveUpdater(tree: tree, scanner: Scanner(), sinceEventId: nil) { s in summary = s; done.fulfill() }
        updater.applyDirectoryEvents([(root + "/locked", false)], eventId: 1)
        wait(for: [done], timeout: 10)

        XCTAssertEqual(tree[lockedID].status, .unavailable)
        XCTAssertEqual(tree[FileTree.root].status, .partial)
        XCTAssertEqual(tree[FileTree.root].totalAlloc, 0,
                       "its old contents are no longer known, so they stop counting: ≥ must stay a lower bound")
        XCTAssertGreaterThan(before, 0)
        XCTAssertEqual(summary?.requiresFullRescan, false, "a full rescan cannot read it either; asking for one would loop")
    }

    func testRetryUnavailableRecoversAFolderThatBecameReadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ds-retry-\(UUID().uuidString)")
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: locked.appendingPathComponent("f").path, contents: Data(count: 8192))
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
        let root = try XCTUnwrap(realpath(dir.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        chmod(locked.path, 0o000)
        let tree = try Scanner().scan(root: root)
        let lockedID = try XCTUnwrap(tree.child(named: "locked", of: FileTree.root))
        XCTAssertEqual(tree[lockedID].status, .unavailable)
        XCTAssertEqual(tree[FileTree.root].status, .partial)

        chmod(locked.path, 0o755)   // the permission arrives
        let done = expectation(description: "retry applied")
        let updater = LiveUpdater(tree: tree, scanner: Scanner(), sinceEventId: nil) { _ in done.fulfill() }
        XCTAssertEqual(updater.retryUnavailable(), 1)
        wait(for: [done], timeout: 10)

        let fresh = try Scanner().scan(root: root)
        XCTAssertEqual(tree[FileTree.root].status, .complete)
        XCTAssertEqual(tree[FileTree.root].totalAlloc, fresh[FileTree.root].totalAlloc)
        XCTAssertEqual(tree[FileTree.root].fileCount, 1)
    }

    func testFullDiskAccessProbeIsThreeState() {
        XCTAssertEqual(FullDiskAccess.state(openingResult: 3, errno: 0), .granted)
        XCTAssertEqual(FullDiskAccess.state(openingResult: -1, errno: EPERM), .denied)
        XCTAssertEqual(FullDiskAccess.state(openingResult: -1, errno: ENOENT), .unknown(errno: ENOENT))
    }
}
