import Darwin
import Foundation
import XCTest
@testable import ScanCore

final class ScannerParityTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.path + "/ScannerParityTests-\(UUID().uuidString)-\(name)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func directory(_ path: String) throws {
        guard Darwin.mkdir(path, 0o755) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
    }

    private func file(_ path: String, bytes: Int = 0) throws {
        let fd = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        if bytes > 0 {
            let data = [UInt8](repeating: 65, count: bytes)
            _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes) }
        }
        close(fd)
    }

    private func paths(_ tree: FileTree) -> [String] {
        (0..<tree.nodeCount).map { tree.path(of: NodeID($0)) }.sorted()
    }

    private func assertSame(_ got: FileTree, _ want: FileTree, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.nodeCount, want.nodeCount, file: file, line: line)
        let gp = paths(got), wp = paths(want)
        XCTAssertEqual(gp, wp, file: file, line: line)
        for path in wp {
            guard let a = got.lookup(path: path), let b = want.lookup(path: path) else { continue }
            let x = got[a], y = want[b]
            XCTAssertEqual(x.flags, y.flags, path, file: file, line: line)
            XCTAssertEqual(x.status, y.status, path, file: file, line: line)
            XCTAssertEqual(x.rawAlloc, y.rawAlloc, path, file: file, line: line)
            XCTAssertEqual(x.ownAlloc, y.ownAlloc, path, file: file, line: line)
            XCTAssertEqual(x.totalAlloc, y.totalAlloc, path, file: file, line: line)
            XCTAssertEqual(x.totalLogical, y.totalLogical, path, file: file, line: line)
            XCTAssertEqual(x.fileCount, y.fileCount, path, file: file, line: line)
            XCTAssertEqual(x.dirCount, y.dirCount, path, file: file, line: line)
        }
    }

    func testWholeTreeMatchesSequential() throws {
        let root = try fixture("whole")
        var dirs: [String] = []
        for top in 0..<8 {
            let parent = root + "/top\(top)"
            dirs.append(parent)
            for mid in 0..<5 {
                var dir = parent + "/b\(mid)"
                dirs.append(dir)
                for depth in 1...4 {
                    dir += "/d\(depth)"
                    dirs.append(dir)
                }
            }
        }
        for (index, dir) in dirs.enumerated() {
            try directory(dir)
            for n in 0..<10 { try file(dir + "/f\(n).dat", bytes: (index * 7919 + n * 104_729) % 20_000) }
        }
        try directory(root + "/empty")
        try file(root + "/loose.txt", bytes: 1234)
        try directory(root + "/links")
        XCTAssertEqual(symlink("../top0", root + "/links/dir.lnk"), 0)
        try file(root + "/top0/hard", bytes: 4096)
        XCTAssertEqual(link(root + "/top0/hard", root + "/top1/hardlink"), 0)
        try file(root + "/top2/clone", bytes: 8192)
        if clonefile(root + "/top2/clone", root + "/top3/clonecopy", 0) != 0 {
            throw XCTSkip("clonefile unavailable: \(errno)")
        }
        let want = try Scanner().scanSequential(root: root)
        for threads in [1, 4, 16] {
            let got = try Scanner(options: ScanOptions(threads: threads)).scan(root: root)
            assertSame(got, want)
        }
    }

    func testNamesMatchFileManager() throws {
        let root = try fixture("names")
        let names = ["caf\u{00E9}", "cafe\u{0301}", "漢字", "🪐", String(repeating: "x", count: 255), "space name", "line\nname"]
        var parents: [(String, [String])] = []
        for (i, name) in names.enumerated() {
            let parent = root + "/p\(i)"
            try directory(parent)
            try file(parent + "/" + name)
            parents.append((parent, [name]))
        }
        let paging = root + "/paging"
        try directory(paging)
        let pageNames = (0..<10_000).map { String(format: "%05d", $0) + String(repeating: "z", count: 195) }
        for name in pageNames { try file(paging + "/" + name) }
        parents.append((paging, pageNames))
        func bytes(_ strings: [String]) -> [[UInt8]] { strings.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) } }
        for (parent, intended) in parents {
            XCTAssertEqual(bytes(try FileManager.default.contentsOfDirectory(atPath: parent)), bytes(intended), "fixture: \(parent)")
        }
        let tree = try Scanner(options: ScanOptions(threads: 4)).scan(root: root)
        for (parent, intended) in parents {
            let id = try XCTUnwrap(tree.lookup(path: parent))
            XCTAssertEqual(bytes(tree.children(of: id).map { tree[$0].name }), bytes(intended), parent)
        }
    }

    private func countFDs() -> Int {
        (0..<min(Int(getdtablesize()), 65_536)).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) }
    }

    private func scanWithWalk(root: String, threads: Int,
                              afterOpenAttempt: ((ParallelWalk, Bool) -> Void)? = nil) throws -> (FileTree, ParallelWalk) {
        var st = stat()
        guard lstat(root, &st) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        let tree = FileTree(rootPath: root, device: st.st_dev, rootModTime: Int64(st.st_mtimespec.tv_sec))
        let rootFD = Darwin.open(root, O_RDONLY | O_DIRECTORY)
        guard rootFD >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        let walk = ParallelWalk(tree: tree, rootFD: rootFD, crossDevices: false, progress: nil, isCancelled: nil,
                                afterOpenAttempt: afterOpenAttempt)
        XCTAssertTrue(walk.run(threads: threads))
        tree.recomputeAggregates()
        return (tree, walk)
    }

    /// An `afterOpenAttempt` hook for two workers and one free descriptor. The first folder opened stays
    /// open until the other worker's open has failed, so that failure is certain. The failed worker then
    /// waits until the walk has counted that folder's close, and runs `afterClose` before it relocks.
    private func contention(afterClose: @escaping () -> Void = {}) -> (ParallelWalk, Bool) -> Void {
        let lock = NSLock(), failed = DispatchSemaphore(value: 0)
        var opens = 0, failures = 0
        return { walk, opened in
            lock.lock()
            let first = opened ? opens == 0 : failures == 0
            if opened { opens += 1 } else { failures += 1 }
            lock.unlock()
            guard first else { return }
            if opened { _ = failed.wait(timeout: .now() + 5); return }
            let closed = walk.closedFDCount
            failed.signal()
            let deadline = Date().addingTimeInterval(5)
            while walk.closedFDCount == closed && Date() < deadline { usleep(1_000) }
            afterClose()
        }
    }

    /// Scans `root` with exactly one free descriptor: the root takes it, then one folder at a time.
    private func scanWithOneFreeFD(root: String,
                                   afterOpenAttempt: @escaping (ParallelWalk, Bool) -> Void) -> (FileTree, ParallelWalk)? {
        var lowestFree: Int32 = 0
        while fcntl(lowestFree, F_GETFD) >= 0 { lowestFree += 1 }
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &original), 0)
        defer { var saved = original; _ = setrlimit(RLIMIT_NOFILE, &saved) }
        var limited = original
        limited.rlim_cur = rlim_t(lowestFree + 1)
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &limited), 0)
        let done = DispatchSemaphore(value: 0)
        var result: (FileTree, ParallelWalk)?
        DispatchQueue.global().async {
            result = try? self.scanWithWalk(root: root, threads: 2, afterOpenAttempt: afterOpenAttempt)
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else { XCTFail("fd pressure hang"); return nil }
        if result == nil { XCTFail("scan did not return a tree") }
        return result
    }

    /// An open that fails with EMFILE is retried when another worker closes a folder before the failed
    /// worker relocks, instead of giving the folder up as unavailable.
    func testFdFreedBeforeAFailedOpenRelocksIsRetried() throws {
        let root = try fixture("race")
        for n in 0..<2 { try directory(root + "/d\(n)") }
        let oracle = try Scanner().scanSequential(root: root)
        guard let result = scanWithOneFreeFD(root: root, afterOpenAttempt: contention()) else { return }
        XCTAssertGreaterThan(result.1.fdPressureEvents, 0, "fixture must exercise EMFILE")
        XCTAssertEqual(result.0[FileTree.root].status, .complete)
        assertSame(result.0, oracle)
    }

    /// With the free descriptor held outside the walk, the folder is given up as unavailable after one
    /// retry; retrying on every failure would spin until the hang check fires.
    func testFdHeldOutsideTheWalkIsGivenUpWithoutSpinning() throws {
        let root = try fixture("foreign")
        for n in 0..<2 { try directory(root + "/d\(n)") }
        var foreign: Int32 = -1
        // Once the other worker has closed its folder, take that descriptor from outside the walk.
        let result = scanWithOneFreeFD(root: root, afterOpenAttempt: contention {
            let deadline = Date().addingTimeInterval(5)
            while foreign < 0 && Date() < deadline {
                foreign = Darwin.open(root, O_RDONLY)
                if foreign < 0 { usleep(1_000) }
            }
        })
        if foreign >= 0 { close(foreign) }
        guard let result else { return }
        XCTAssertEqual(result.1.fdPressureEvents, 2, "one retry after the close, then give up")
        let tree = result.0
        XCTAssertEqual(tree[FileTree.root].status, .partial)
        XCTAssertEqual(tree.children(of: FileTree.root).filter { tree[$0].status == .unavailable }.count, 1)
    }

    func testNoFdLeak() throws {
        let root = try fixture("leak")
        for n in 0..<100 { try directory(root + "/d\(n)") }
        let scanner = Scanner(options: ScanOptions(threads: 4))
        let before = countFDs()
        _ = try scanner.scan(root: root)
        XCTAssertEqual(countFDs(), before, "full scan")
        for cancelAt in [1, 5] {
            let lock = NSLock()
            var polls = 0
            XCTAssertThrowsError(try scanner.scan(root: root, isCancelled: {
                lock.lock(); defer { lock.unlock() }
                polls += 1
                return polls >= cancelAt
            })) { XCTAssertEqual($0 as? ScanError, .cancelled) }
            XCTAssertEqual(countFDs(), before, "cancel after \(cancelAt) polls")
        }
    }

    func testTerminatesWithMoreThreadsThanWork() throws {
        for hasFile in [false, true] {
            let root = try fixture(hasFile ? "one" : "empty")
            if hasFile { try file(root + "/only") }
            for iteration in 0..<20 {
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    _ = try? Scanner(options: ScanOptions(threads: 16)).scan(root: root)
                    done.signal()
                }
                if done.wait(timeout: .now() + 2) != .success {
                    XCTFail("scan hung: hasFile=\(hasFile), iteration=\(iteration)")
                    break
                }
            }
        }
    }

    func testTightFdLimitStaysComplete() throws {
        let root = try fixture("tight")
        for n in 0..<300 { try directory(root + "/d\(n)") }
        let oracle = try Scanner().scanSequential(root: root)
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &original), 0)
        defer { var saved = original; _ = setrlimit(RLIMIT_NOFILE, &saved) }
        var limited = original
        limited.rlim_cur = rlim_t(countFDs() + 4)
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &limited), 0)
        let done = DispatchSemaphore(value: 0)
        var result: (FileTree, ParallelWalk)?
        DispatchQueue.global().async {
            result = try? self.scanWithWalk(root: root, threads: 16)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "fd pressure hang")
        if let result {
            XCTAssertGreaterThan(result.1.fdPressureEvents, 0, "fixture must exercise EMFILE/ENFILE")
            XCTAssertEqual(result.0[FileTree.root].status, .complete, "fd pressure must not make root partial")
            assertSame(result.0, oracle)
        } else { XCTFail("scan did not return a tree") }
    }
}
