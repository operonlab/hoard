import Foundation
import XCTest
@testable import ScanCore

final class DuplicateCopyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HoardDupCopy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `a` and `b` with the same bytes, scans, and returns each as the comparison would record it.
    private func copies() throws -> (DuplicateCopy, DuplicateCopy) {
        let bytes = Data(repeating: 7, count: 4096)
        try bytes.write(to: root.appendingPathComponent("a"))
        try bytes.write(to: root.appendingPathComponent("b"))
        let tree = try Scanner().scan(root: root.path)
        let a = try XCTUnwrap(tree.child(named: "a", of: FileTree.root))
        let b = try XCTUnwrap(tree.child(named: "b", of: FileTree.root))
        return (DuplicateCopy(tree[a], path: tree.path(of: a)), DuplicateCopy(tree[b], path: tree.path(of: b)))
    }

    func testUntouchedCopiesStayEligible() throws {
        let (a, b) = try copies()
        XCTAssertTrue(a.unchanged())
        XCTAssertTrue(b.unchanged())
    }

    func testGrownFileIsNoLongerTheCopy() throws {
        let (a, _) = try copies()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: a.path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        XCTAssertFalse(a.unchanged())
    }

    func testSameSizeEditWithNewTimeIsNoLongerTheCopy() throws {
        let (a, _) = try copies()
        let later = Date(timeIntervalSince1970: TimeInterval(a.modTime + 60))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: a.path))
        try handle.write(contentsOf: Data(repeating: 9, count: 4096))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: a.path)
        XCTAssertFalse(a.unchanged())
    }

    func testReplacedOrDeletedFileIsNoLongerTheCopy() throws {
        let (a, b) = try copies()
        // Keep the old inode alive under another name, so the new file cannot reuse its number.
        try FileManager.default.moveItem(atPath: a.path, toPath: root.appendingPathComponent("a.old").path)
        try Data(repeating: 7, count: 4096).write(to: URL(fileURLWithPath: a.path))
        XCTAssertFalse(a.unchanged())
        try FileManager.default.removeItem(atPath: b.path)
        XCTAssertFalse(b.unchanged())
    }
}
