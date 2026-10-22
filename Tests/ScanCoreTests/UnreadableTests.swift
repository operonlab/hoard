import Darwin
import Foundation
import XCTest
@testable import ScanCore

final class UnreadableTests: XCTestCase {
    func testClassificationOrder() {
        let cases: [(Int32?, UInt32, Bool, Int32?, FullDiskAccess.State, UnreadableDiagnosis.Reason)] = [
            (ENOENT, UInt32(SF_DATALESS), true, nil, .denied, .gone),
            (EIO, 0, false, nil, .denied, .error),
            (nil, UInt32(SF_DATALESS | SF_RESTRICTED), true, EPERM, .denied, .notDownloaded),
            (nil, UInt32(SF_RESTRICTED), true, nil, .denied, .systemProtected),
            (nil, 0, true, EACCES, .denied, .readableNow),
            (nil, 0, false, EACCES, .denied, .filePermissions),
            (nil, 0, false, EPERM, .denied, .needsFullDiskAccess),
            (nil, 0, false, EPERM, .granted, .systemProtected),
            (nil, 0, false, EPERM, .unknown(errno: EIO), .permission),
            (nil, 0, false, ENOTDIR, .denied, .gone),
            (nil, 0, false, EIO, .denied, .error),
            (nil, 0, false, nil, .denied, .unknown)
        ]
        for (statError, flags, opened, openError, access, expected) in cases {
            let actual = Unreadable.classify(lstatErrno: statError, flags: flags, opened: opened,
                                             openErrno: openError, fullDiskAccess: access, owner: "tester")
            XCTAssertEqual(actual.reason, expected)
            XCTAssertEqual(actual.errno, statError ?? (opened || flags != 0 ? nil : openError))
            XCTAssertEqual(actual.owner, expected == .filePermissions ? "tester" : nil)
        }
    }

    func testDiagnoseTemporaryFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(Unreadable.diagnose(root.appendingPathComponent("missing").path,
                                           fullDiskAccess: .denied).reason, .gone)
        XCTAssertEqual(Unreadable.diagnose(root.path, fullDiskAccess: .denied).reason, .readableNow)
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let diagnosis = Unreadable.diagnose(locked.path, fullDiskAccess: .denied)
        XCTAssertEqual(diagnosis.reason, .filePermissions)
        XCTAssertEqual(diagnosis.owner, String(cString: getpwuid(getuid())!.pointee.pw_name))
    }

    func testFoldersLimitTotalAndRemoved() {
        let tree = FileTree(rootPath: "/temporary-fixture", device: 1)
        let a = tree.addChild(of: FileTree.root, entry: ScanEntry(name: "a", isDirectory: true))
        let b = tree.addChild(of: FileTree.root, entry: ScanEntry(name: "b", isDirectory: true))
        let c = tree.addChild(of: FileTree.root, entry: ScanEntry(name: "c", isDirectory: true))
        tree.setStatus(a, .unavailable)
        tree.markListingIncomplete(b)
        tree.setStatus(c, .unavailable)
        tree.removeSubtree(c)
        let result = Unreadable.folders(in: tree, under: FileTree.root, limit: 1)
        XCTAssertEqual(result.paths, ["/temporary-fixture/a"])
        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(Unreadable.folders(in: tree, under: b, limit: 3).paths, ["/temporary-fixture/b"])
    }
}
