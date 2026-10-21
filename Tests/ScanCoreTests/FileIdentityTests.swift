import XCTest
@testable import ScanCore

final class FileIdentityTests: XCTestCase {
    func testReplacedFileAtSamePathDoesNotMatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ds-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("victim.bin").path

        // Keep the original alive under another name so the replacement cannot reuse its inode.
        FileManager.default.createFile(atPath: path, contents: Data("old".utf8))
        let scanned = try XCTUnwrap(FileIdentity.current(atPath: path))
        XCTAssertTrue(scanned.stillAt(path))

        try FileManager.default.moveItem(atPath: path, toPath: dir.appendingPathComponent("moved.bin").path)
        FileManager.default.createFile(atPath: path, contents: Data("new".utf8))
        XCTAssertFalse(scanned.stillAt(path), "a different file now lives at the path")

        try FileManager.default.removeItem(atPath: path)
        XCTAssertFalse(scanned.stillAt(path), "nothing at the path")
    }

    func testScannedNodeIdentityMatchesDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ds-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.txt").path, contents: Data("x".utf8))
        let tree = try Scanner().scan(root: dir.path)
        let id = try XCTUnwrap(tree.child(named: "a.txt", of: FileTree.root))
        XCTAssertTrue(FileIdentity(tree[id]).stillAt(tree.path(of: id)))
    }

    func testScannerReadsAccessAndModTimesLikeStat() throws {
        // Known answer: set atime/mtime to fixed, distinct values and expect the scanner to agree with lstat.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ds-atime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("old.bin").path
        FileManager.default.createFile(atPath: path, contents: Data(count: 10))
        var times = [timeval(tv_sec: 1_600_000_000, tv_usec: 0), timeval(tv_sec: 1_700_000_000, tv_usec: 0)]
        XCTAssertEqual(utimes(path, &times), 0)
        let tree = try Scanner().scan(root: dir.path)
        let n = tree[try XCTUnwrap(tree.child(named: "old.bin", of: FileTree.root))]
        XCTAssertEqual(n.accessTime, 1_600_000_000)
        XCTAssertEqual(n.modTime, 1_700_000_000)
        // And the snapshot keeps it.
        let url = dir.appendingPathComponent("t.dscan")
        try Snapshot.write(tree, meta: SnapshotMeta(rootPath: tree.rootPath, device: tree.device, createdAt: Date(),
                                                     scanSeconds: 0, lastEventId: 1, eventsUUID: nil), to: url)
        let back = try Snapshot.read(from: url).tree
        XCTAssertEqual(back[try XCTUnwrap(back.child(named: "old.bin", of: FileTree.root))].accessTime, 1_600_000_000)
    }

    func testUnknownIdentityNeverMatches() {
        XCTAssertFalse(FileIdentity(device: 1, fileID: 0).stillAt("/"))
    }
}
