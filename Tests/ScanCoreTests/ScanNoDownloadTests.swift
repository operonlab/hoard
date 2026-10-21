import Darwin
import Foundation
import XCTest
@testable import ScanCore

/// A scan never fetches an evicted folder's listing from iCloud: every thread that reads folders runs
/// with downloads off, and reads nothing when they cannot be turned off.
final class ScanNoDownloadTests: XCTestCase {
    private func fixture() throws -> String {
        let path = FileManager.default.temporaryDirectory.path + "/ScanNoDownloadTests-\(UUID().uuidString)"
        for n in 0..<8 {
            try FileManager.default.createDirectory(atPath: path + "/d\(n)/e", withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private static func threadPolicy() -> Int32 {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    }

    /// The tests that read with the real switch need a system that lets this thread turn downloads off.
    private func requireDownloadSwitch() throws {
        guard let restore = Materialization.offForThread("test") else {
            throw XCTSkip("this system does not let a thread turn iCloud downloads off")
        }
        restore()
    }

    private func countFDs() -> Int {
        (0..<min(Int(getdtablesize()), 65_536)).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) }
    }

    /// Records each call of the real switch: whether it came from the calling (main) thread.
    private final class SwitchLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var onMain = 0, elsewhere = 0
        func record() { lock.lock(); if Thread.isMainThread { onMain += 1 } else { elsewhere += 1 }; lock.unlock() }
    }

    private func walk(_ root: String, threads: Int = 4, afterOpenAttempt: ((ParallelWalk, Bool) -> Void)? = nil,
                      downloadsOff: @escaping (String) -> (() -> Void)? = Materialization.offForThread) -> FileTree? {
        var st = stat()
        XCTAssertEqual(lstat(root, &st), 0)
        let tree = FileTree(rootPath: root, device: st.st_dev, rootModTime: Int64(st.st_mtimespec.tv_sec))
        let fd = Darwin.open(root, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let walk = ParallelWalk(tree: tree, rootFD: fd, crossDevices: false, progress: nil, isCancelled: nil,
                                afterOpenAttempt: afterOpenAttempt, downloadsOff: downloadsOff)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertTrue(walk.run(threads: threads))
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else { XCTFail("walk hang"); return nil }
        tree.recomputeAggregates()
        return tree
    }

    func testParallelWorkersOpenFoldersWithDownloadsOff() throws {
        try requireDownloadSwitch()
        let root = try fixture()
        let lock = NSLock()
        var opens = 0, off = 0
        let tree = try XCTUnwrap(walk(root) { _, _ in
            let isOff = Self.threadPolicy() == IOPOL_MATERIALIZE_DATALESS_FILES_OFF
            lock.lock()
            opens += 1
            if isOff { off += 1 }
            lock.unlock()
        })
        XCTAssertEqual(tree[FileTree.root].status, .complete)
        XCTAssertEqual(tree.nodeCount, 17)
        XCTAssertGreaterThanOrEqual(opens, 16, "d0…d7 and each e")
        XCTAssertEqual(off, opens)
    }

    func testWorkersThatCannotTurnDownloadsOffReadNothing() throws {
        let root = try fixture()
        let lock = NSLock()
        var asked = 0
        let before = countFDs()
        let tree = try XCTUnwrap(walk(root, downloadsOff: { _ in
            lock.lock()
            asked += 1
            lock.unlock()
            return nil
        }))
        XCTAssertEqual(asked, 4, "each worker asks once")
        XCTAssertEqual(tree.nodeCount, 1)
        XCTAssertEqual(tree[FileTree.root].status, .unavailable)
        XCTAssertEqual(countFDs(), before, "the root's descriptor is closed")
    }

    /// Workers that could and could not turn downloads off, together: the walk ends, closes every
    /// descriptor, and a folder is either read in full or unavailable.
    func testMixedWorkersEndAndCloseEveryDescriptor() throws {
        try requireDownloadSwitch()
        let root = try fixture()
        for n in 0..<8 { for m in 0..<20 { try FileManager.default.createDirectory(atPath: root + "/d\(n)/e/f\(m)", withIntermediateDirectories: true) } }
        let lock = NSLock()
        var calls = 0
        let before = countFDs()
        for _ in 0..<5 {
            let tree = try XCTUnwrap(walk(root, threads: 6, downloadsOff: { reader in
                lock.lock()
                calls += 1
                let refuse = calls % 2 == 0
                lock.unlock()
                return refuse ? nil : Materialization.offForThread(reader)
            }))
            for id in (0..<tree.nodeCount).map({ NodeID($0) }) where tree[id].isDirectory {
                let status = tree[id].status
                let readInFull = status == .complete || status == .partial  // partial only from an unavailable child
                XCTAssertTrue(readInFull || status == .unavailable, "\(tree.path(of: id)): \(status)")
                if status == .unavailable { XCTAssertTrue(tree.children(of: id).isEmpty, tree.path(of: id)) }
            }
        }
        XCTAssertEqual(countFDs(), before)
    }

    func testScanAsksOnTheCallingThreadAndInEveryWorker() throws {
        try requireDownloadSwitch()
        let root = try fixture()
        let log = SwitchLog()
        let tree = try Scanner(options: ScanOptions(threads: 3)).scan(root: root, progress: nil, isCancelled: nil) {
            log.record()
            return Materialization.offForThread($0)
        }
        XCTAssertEqual(tree[FileTree.root].status, .complete)
        XCTAssertEqual(log.onMain, 1, "the root is opened on the calling thread")
        XCTAssertEqual(log.elsewhere, 3)
    }

    func testScanThatCannotTurnDownloadsOffReadsNothing() throws {
        let root = try fixture()
        let before = countFDs()
        let tree = try Scanner(options: ScanOptions(threads: 3)).scan(root: root, progress: nil, isCancelled: nil) { _ in nil }
        XCTAssertEqual(tree.nodeCount, 1)
        XCTAssertEqual(tree[FileTree.root].status, .unavailable)
        XCTAssertEqual(countFDs(), before)
    }

    func testSequentialScanReadsWithDownloadsOffAndRestoresThePolicy() throws {
        try requireDownloadSwitch()
        let root = try fixture()
        let before = Self.threadPolicy()
        var polls = 0, off = 0
        // `isCancelled` is polled on the scanning thread once per folder.
        let tree = try Scanner().scanSequential(root: root, isCancelled: {
            polls += 1
            if Self.threadPolicy() == IOPOL_MATERIALIZE_DATALESS_FILES_OFF { off += 1 }
            return false
        })
        XCTAssertEqual(tree[FileTree.root].status, .complete)
        XCTAssertEqual(polls, 17)
        XCTAssertEqual(off, polls)
        XCTAssertEqual(Self.threadPolicy(), before)
    }

    func testListDirectoryReadsWithDownloadsOffOrNotAtAll() throws {
        try requireDownloadSwitch()
        let root = try fixture()
        let before = Self.threadPolicy()
        var asked = 0
        let entries = try Scanner().listDirectory(root) { asked += 1; return Materialization.offForThread($0) }
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(entries.count, 8)
        XCTAssertEqual(Self.threadPolicy(), before)
        XCTAssertEqual(try Scanner().listDirectory(root), entries, "the public form is the same read")
        XCTAssertThrowsError(try Scanner().listDirectory(root) { _ in nil }) { error in
            XCTAssertEqual(error as? ScanError, .incompleteListing(path: root))
        }
    }
}
