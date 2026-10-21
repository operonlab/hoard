import Darwin
import XCTest
@testable import ScanCore

/// Fixture (under a fresh temp dir, realpath'd so `/var` reads as `/private/var`):
///
///     root/
///       top0…top7/b0…b4/d1/d2/d3/d4/   208 dirs, 10 files each (2,080 files), depth 6
///       pairs/x/deep/h1  pairs/y/h2     hardlink pair  (both under one first-level dir, see below)
///       pairs/x/c1  pairs/y/deep/c2     APFS clone pair
///       links/big.lnk -> ../../outside/big.bin (4 MiB, outside the scanned root)
///       links/dir.lnk -> ../top0
///       locked/secret.txt               chmod 000 during the test
///       empty/  loose.txt
///
/// Dedup gives a pair's bytes to whichever member is inserted first, and the parallel walk's
/// order is not the recursive walk's order. Root totals are order-independent; per-directory
/// totals are only order-independent when both members sit under the same directory, which is
/// why each pair lives under `pairs/`.
final class ScannerTests: XCTestCase {
    private var base = ""
    private var root = ""
    private var lockedDir = ""
    private var cloneSkipReason: String?
    private let bigSize = 4 << 20
    private let pairSize = 256 << 10

    override func setUpWithError() throws {
        var template = Array((FileManager.default.temporaryDirectory.path + "/ScannerTests.XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(.init(rawValue: errno)!) }
        guard let resolved = realpath(String(cString: template), nil) else { throw POSIXError(.init(rawValue: errno)!) }
        base = String(cString: resolved)
        free(resolved)
        root = base + "/root"
        try buildFixture()
    }

    override func tearDownWithError() throws {
        if !lockedDir.isEmpty { chmod(lockedDir, 0o755) }
        if !base.isEmpty { try FileManager.default.removeItem(atPath: base) }
    }

    // MARK: Fixture

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func write(_ path: String, _ size: Int) throws {
        guard FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x61, count: size)) else {
            throw POSIXError(.EIO)
        }
    }

    private func buildFixture() throws {
        var dirs: [String] = []
        for t in 0..<8 {
            let top = "\(root)/top\(t)"
            dirs.append(top)
            for b in 0..<5 {
                var cur = "\(top)/b\(b)"
                dirs.append(cur)
                for d in 1...4 { cur += "/d\(d)"; dirs.append(cur) }
            }
        }
        for (i, dir) in dirs.enumerated() {
            try mkdir(dir)
            for j in 0..<10 { try write("\(dir)/f\(j).dat", (i * 7919 + j * 104_729) % 20_000) }
        }

        try mkdir("\(root)/pairs/x/deep")
        try mkdir("\(root)/pairs/y/deep")
        try write("\(root)/pairs/x/deep/h1", pairSize)
        guard link("\(root)/pairs/x/deep/h1", "\(root)/pairs/y/h2") == 0 else { throw POSIXError(.init(rawValue: errno)!) }

        try write("\(root)/pairs/x/c1", pairSize)
        if !isAPFS(base) {
            cloneSkipReason = "temp volume is not APFS"
        } else if clonefile("\(root)/pairs/x/c1", "\(root)/pairs/y/deep/c2", 0) != 0 {
            cloneSkipReason = "clonefile failed: errno \(errno)"
        }

        try mkdir("\(base)/outside")
        try write("\(base)/outside/big.bin", bigSize)
        try mkdir("\(root)/links")
        try FileManager.default.createSymbolicLink(atPath: "\(root)/links/big.lnk", withDestinationPath: "../../outside/big.bin")
        try FileManager.default.createSymbolicLink(atPath: "\(root)/links/dir.lnk", withDestinationPath: "../top0")

        lockedDir = "\(root)/locked"
        try mkdir(lockedDir)
        try write("\(lockedDir)/secret.txt", 50_000)
        chmod(lockedDir, 0)

        try mkdir("\(root)/empty")
        try write("\(root)/loose.txt", 1234)
    }

    private func isAPFS(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let name = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return name == "apfs"
    }

    // MARK: Helpers

    private struct Totals: Equatable {
        var alloc: Int64, logical: Int64, files: Int64, dirs: Int64, status: ScanStatus
    }

    private func totals(_ t: FileTree, _ id: NodeID) -> Totals {
        let n = t[id]
        return Totals(alloc: n.totalAlloc, logical: n.totalLogical, files: n.fileCount, dirs: n.dirCount, status: n.status)
    }

    private func firstLevel(_ t: FileTree) -> [String: Totals] {
        Dictionary(uniqueKeysWithValues: t.children(of: FileTree.root).map { (t[$0].name, totals(t, $0)) })
    }

    private func node(_ t: FileTree, _ rel: String) throws -> Node {
        let id = try XCTUnwrap(t.lookup(path: "\(root)/\(rel)"), "missing \(rel)")
        return t[id]
    }

    // MARK: Tests

    func testFixtureShape() throws {
        let t = try Scanner().scanSequential(root: root)
        XCTAssertGreaterThanOrEqual(t[FileTree.root].fileCount, 2_000)
        XCTAssertGreaterThanOrEqual(t[FileTree.root].dirCount, 200)
        XCTAssertNotNil(t.lookup(path: "\(root)/top3/b2/d1/d2/d3/d4/f9.dat"))
    }

    func testParallelMatchesSequentialAtRootAndFirstLevel() throws {
        let oracle = try Scanner().scanSequential(root: root)
        for threads in [1, 4, 16] {
            let t = try Scanner(options: ScanOptions(threads: threads)).scan(root: root)
            XCTAssertEqual(totals(t, FileTree.root), totals(oracle, FileTree.root), "root, threads=\(threads)")
            XCTAssertEqual(t.nodeCount, oracle.nodeCount, "node count, threads=\(threads)")
            let got = firstLevel(t), want = firstLevel(oracle)
            XCTAssertEqual(Set(got.keys), Set(want.keys), "first-level names, threads=\(threads)")
            for (name, w) in want { XCTAssertEqual(got[name], w, "\(name), threads=\(threads)") }
        }
    }

    func testHardlinkPairCountsOnce() throws {
        let t = try Scanner(options: ScanOptions(threads: 4)).scan(root: root)
        let pair = [try node(t, "pairs/x/deep/h1"), try node(t, "pairs/y/h2")]
        XCTAssertEqual(pair.filter { $0.flags.contains(.duplicate) }.count, 1)
        for n in pair {
            XCTAssertGreaterThanOrEqual(n.rawAlloc, Int64(pairSize))
            XCTAssertEqual(n.ownAlloc, n.flags.contains(.duplicate) ? 0 : n.rawAlloc)
        }
        try assertRootIsDeduped(t)
    }

    func testClonePairCountsOnce() throws {
        if let cloneSkipReason { throw XCTSkip(cloneSkipReason) }
        let t = try Scanner(options: ScanOptions(threads: 4)).scan(root: root)
        let pair = [try node(t, "pairs/x/c1"), try node(t, "pairs/y/deep/c2")]
        for n in pair {
            XCTAssertTrue(n.flags.contains(.cloneShared), "\(n.name) not reported as sharing all blocks")
            XCTAssertNotEqual(n.cloneID, 0, "\(n.name) has no clone id")
        }
        XCTAssertEqual(pair[0].cloneID, pair[1].cloneID)
        XCTAssertEqual(pair.filter { $0.flags.contains(.duplicate) }.count, 1)
        try assertRootIsDeduped(t)
    }

    /// Independent check of the root total: sum st_blocks over everything readable via lstat,
    /// once per inode, then take one clone copy back out.
    private func assertRootIsDeduped(_ t: FileTree) throws {
        var seen = Set<UInt64>()
        var expected: Int64 = 0
        var stack = [root]
        while let dir = stack.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names {
                let p = dir + "/" + name
                var st = stat()
                guard lstat(p, &st) == 0 else { continue }
                if (st.st_mode & S_IFMT) == S_IFDIR { stack.append(p); continue }
                if seen.insert(st.st_ino).inserted { expected += Int64(st.st_blocks) * 512 }
            }
        }
        if cloneSkipReason == nil { expected -= try node(t, "pairs/x/c1").rawAlloc }
        XCTAssertEqual(t[FileTree.root].totalAlloc, expected)
    }

    func testSymlinksCountAsLinksNotTargets() throws {
        let t = try Scanner(options: ScanOptions(threads: 4)).scan(root: root)
        let big = try node(t, "links/big.lnk")
        XCTAssertTrue(big.flags.contains(.symlink))
        XCTAssertFalse(big.isDirectory)
        XCTAssertLessThan(big.rawAlloc, Int64(bigSize))
        let dirLink = try node(t, "links/dir.lnk")
        XCTAssertTrue(dirLink.flags.contains(.symlink))
        XCTAssertFalse(dirLink.isDirectory)
        XCTAssertEqual(dirLink.firstChild, -1)
        XCTAssertLessThan(try node(t, "links").totalAlloc, Int64(bigSize))
    }

    func testUnreadableDirIsUnavailableAndRootPartial() throws {
        if geteuid() == 0 { throw XCTSkip("root ignores chmod 000") }
        let t = try Scanner(options: ScanOptions(threads: 4)).scan(root: root)
        let locked = try node(t, "locked")
        XCTAssertEqual(locked.status, .unavailable)
        XCTAssertEqual(locked.firstChild, -1)
        XCTAssertEqual(t[FileTree.root].status, .partial)
        XCTAssertEqual(try node(t, "top0").status, .complete)
    }

    func testProgressAndCancellation() throws {
        let lock = NSLock()
        var last: ScanProgress?
        let t = try Scanner(options: ScanOptions(threads: 4)).scan(root: root, progress: { p in
            lock.lock(); last = p; lock.unlock()
        })
        let final = try XCTUnwrap(last)
        XCTAssertEqual(Int64(final.files), t[FileTree.root].fileCount)
        XCTAssertEqual(Int64(final.dirs) + 1, t[FileTree.root].dirCount)

        var polls = 0
        XCTAssertThrowsError(try Scanner(options: ScanOptions(threads: 4)).scan(root: root, isCancelled: {
            lock.lock(); defer { lock.unlock() }
            polls += 1
            return polls > 20
        })) { XCTAssertEqual($0 as? ScanError, .cancelled) }
    }

    /// The parallel walk opens directories by path; below PATH_MAX it must fall back to openat.
    func testPathsLongerThanPathMax() throws {
        let top = base + "/long"
        try mkdir(top)
        let name = String(repeating: "n", count: 200)
        var fds: [Int32] = [open(top, O_RDONLY | O_DIRECTORY)]
        defer {
            unlinkat(fds[fds.count - 1], "deep.dat", 0)
            for i in stride(from: fds.count - 1, through: 1, by: -1) {
                close(fds[i])
                unlinkat(fds[i - 1], name, AT_REMOVEDIR)
            }
            close(fds[0])
        }
        for _ in 0..<6 {
            guard mkdirat(fds[fds.count - 1], name, 0o755) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
            let fd = openat(fds[fds.count - 1], name, O_RDONLY | O_DIRECTORY)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
            fds.append(fd)
        }
        let f = openat(fds[fds.count - 1], "deep.dat", O_WRONLY | O_CREAT, 0o644)
        guard f >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        let data = [UInt8](repeating: 0x61, count: 10_000)
        XCTAssertEqual(Darwin.write(f, data, data.count), data.count)
        close(f)
        XCTAssertGreaterThan(top.utf8.count + 6 * (name.count + 1), Int(PATH_MAX))

        let oracle = try Scanner().scanSequential(root: top)
        let t = try Scanner(options: ScanOptions(threads: 4)).scan(root: top)
        XCTAssertEqual(totals(t, FileTree.root), totals(oracle, FileTree.root))
        XCTAssertEqual(t[FileTree.root].status, .complete)
        XCTAssertEqual(t[FileTree.root].fileCount, 1)
        XCTAssertEqual(t[FileTree.root].dirCount, 7)
        XCTAssertGreaterThan(t[FileTree.root].totalAlloc, 0)
    }

    func testBadRootsThrow() {
        XCTAssertThrowsError(try Scanner().scan(root: "\(base)/nope")) {
            guard case .cannotOpen = $0 as? ScanError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try Scanner().scan(root: "\(root)/loose.txt")) {
            XCTAssertEqual($0 as? ScanError, .notADirectory(path: "\(root)/loose.txt"))
        }
    }
}
