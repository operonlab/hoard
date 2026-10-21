import XCTest
import TreeCore

final class HistoryStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func tree(extra: Int64 = 0) -> FileTree {
        let mb: Int64 = 1_048_576
        let t = FileTree(rootPath: "/r", device: 1)
        let a = t.addChild(of: FileTree.root, entry: ScanEntry(name: "a", isDirectory: true, device: 1))
        let b = t.addChild(of: a, entry: ScanEntry(name: "bé 漢字", isDirectory: true, device: 1))
        t.addChild(of: b, entry: ScanEntry(name: "big.mov", isDirectory: false, allocSize: 30 * mb + extra,
                                           modTime: 1_700_000_000, accessTime: 1_700_000_100, device: 1))
        t.addChild(of: a, entry: ScanEntry(name: "small", isDirectory: false, allocSize: 4096, device: 1))
        let locked = t.addChild(of: FileTree.root, entry: ScanEntry(name: "locked", isDirectory: true, device: 1))
        t.recomputeAggregates()
        t.markUnavailable(locked)
        return t
    }

    private func history(_ retention: HistoryRetention = HistoryRetention()) -> SnapshotHistory {
        SnapshotHistory(rootPath: "/r", directory: tempDir, retention: retention)
    }

    private let t0 = Date(timeIntervalSince1970: 1_792_468_800.25)   // fractional seconds survive the round trip

    func testRoundTrip() throws {
        let h = history()
        let t = tree()
        let saved = try h.record(t, at: t0)
        XCTAssertEqual(saved.rootPath, "/r")
        XCTAssertEqual(saved.totalAlloc, t[FileTree.root].totalAlloc)
        XCTAssertEqual(saved.fileCount, 2)
        XCTAssertEqual(saved.dirCount, 4)
        XCTAssertEqual(saved.status, .partial)

        let size = try FileManager.default.attributesOfItem(atPath: tempDir
            .appendingPathComponent(saved.id + ".dshist").path)[.size] as! NSNumber
        XCTAssertEqual(saved.storedBytes, size.int64Value)

        XCTAssertEqual(try h.versions(), [saved])
        let loaded = try h.load(saved.id)
        XCTAssertEqual(loaded, TreeSummary(tree: t, createdAt: t0))
        XCTAssertEqual(loaded.bigFiles.count, 1)
        XCTAssertEqual(loaded.path(ofDir: loaded.bigFiles[0].dir), "/r/a/bé 漢字")
    }

    func testIdFormatAndSameSecondUnique() throws {
        let h = history()
        let a = try h.record(tree(), at: t0)
        let b = try h.record(tree(extra: 1), at: t0)
        let c = try h.record(tree(extra: 2), at: t0.addingTimeInterval(0.5))   // same UTC second
        XCTAssertEqual(a.id, "20261020T040000Z")
        XCTAssertEqual(b.id, "20261020T040000Z-2")
        XCTAssertEqual(c.id, "20261020T040000Z-3")
        XCTAssertEqual(try h.versions().map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(try h.load(b.id).bigFiles[0].alloc, 30 * 1_048_576 + 1)
    }

    func testConcurrentWritersOfTheSameSecondKeepEveryVersion() throws {
        // One SnapshotHistory per writer, as two processes would have; all write the same UTC second.
        let writers = 8
        let mutex = NSLock()
        var ids: [String] = [], failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: writers) { i in
            let result = Result { try history().record(tree(extra: Int64(i)), at: t0) }
            mutex.lock(); defer { mutex.unlock() }
            switch result {
            case .success(let v): ids.append(v.id)
            case .failure(let e): failures.append("\(e)")
            }
        }
        XCTAssertEqual(failures, [])
        XCTAssertEqual(Set(ids).count, writers, "\(ids)")
        let listed = try history().versions()
        XCTAssertEqual(Set(listed.map(\.id)), Set(ids))
        let sizes = try listed.map { try history().load($0.id).bigFiles[0].alloc }
        XCTAssertEqual(Set(sizes), Set((0..<writers).map { 30 * 1_048_576 + Int64($0) }), "no writer overwrote another")
    }

    func testMissingVersionAndEmptyDirectory() throws {
        let h = history()
        XCTAssertEqual(try h.versions(), [])
        XCTAssertThrowsError(try h.load("20990101T000000Z")) { XCTAssertEqual($0 as? HistoryError, .notFound(id: "20990101T000000Z")) }
        XCTAssertThrowsError(try h.load("../x")) { XCTAssertEqual($0 as? HistoryError, .notFound(id: "../x")) }
    }

    func testCorruptAndTruncatedFilesThrowCorrupt() throws {
        let h = history()
        let saved = try h.record(tree(), at: t0)
        let url = tempDir.appendingPathComponent(saved.id + ".dshist")
        let good = try Data(contentsOf: url)

        func expectCorrupt(_ data: Data, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
            try data.write(to: url)
            XCTAssertThrowsError(try h.load(saved.id), label, file: file, line: line) {
                XCTAssertEqual($0 as? HistoryError, .corrupt(id: saved.id), label, file: file, line: line)
            }
        }
        // Every truncation point.
        for cut in 0..<good.count { try expectCorrupt(good.prefix(cut), "cut \(cut)") }
        try expectCorrupt(good + Data([0]), "trailing byte")
        var bad = good; bad[0] = 0x58
        try expectCorrupt(bad, "magic")
        bad = good; bad[4] = 9
        try expectCorrupt(bad, "format version")
        bad = good; bad[8] = 0xff; bad[9] = 0xff; bad[10] = 0xff; bad[11] = 0x7f
        try expectCorrupt(bad, "json length")
        // Flip every payload byte one at a time: must throw or decode, never crash.
        let jsonLength = Int(good[8]) | Int(good[9]) << 8 | Int(good[10]) << 16 | Int(good[11]) << 24
        for i in (12 + jsonLength)..<good.count {
            bad = good; bad[i] ^= 0xff
            try bad.write(to: url)
            do { _ = try h.load(saved.id) } catch { XCTAssertEqual(error as? HistoryError, .corrupt(id: saved.id)) }
        }
        // A file whose header cannot be read is left out of the listing, not fatal.
        try Data("junk".utf8).write(to: url)
        XCTAssertEqual(try h.versions(), [])
    }

    func testRetentionByCount() throws {
        let h = history(HistoryRetention(maxVersions: 3, maxAge: 1e9))
        var ids: [String] = []
        for day in 0..<5 { ids.append(try h.record(tree(), at: t0.addingTimeInterval(Double(day) * 86_400)).id) }
        XCTAssertEqual(try h.versions().map(\.id), Array(ids.suffix(3).reversed()))
    }

    func testRetentionByAgeKeepsNewest() throws {
        let h = history(HistoryRetention(maxVersions: 100, maxAge: 10 * 86_400))
        try h.record(tree(), at: t0)
        let mid = try h.record(tree(), at: t0.addingTimeInterval(5 * 86_400))
        let new = try h.record(tree(), at: t0.addingTimeInterval(12 * 86_400))
        XCTAssertEqual(try h.versions().map(\.id), [new.id, mid.id])            // old pruned at record time
        // Far in the future: everything is too old, but the newest stays.
        XCTAssertEqual(try h.prune(now: t0.addingTimeInterval(1000 * 86_400)), [mid.id])
        XCTAssertEqual(try h.versions().map(\.id), [new.id])
        XCTAssertEqual(try history(HistoryRetention(maxVersions: 0, maxAge: 0)).prune(now: .distantFuture), [])
        XCTAssertEqual(try h.versions().map(\.id), [new.id])
    }

    func testDefaultDirectoryIsPerRoot() {
        let a = SnapshotHistory(rootPath: "/Users/me")
        let b = SnapshotHistory(rootPath: "/Volumes/Data")
        XCTAssertNotEqual(a.directory, b.directory)
        XCTAssertEqual(a.directory.lastPathComponent.count, 16)
        XCTAssertEqual(a.directory.deletingLastPathComponent().lastPathComponent, "History")
        XCTAssertEqual(a.directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Hoard")
    }
}
