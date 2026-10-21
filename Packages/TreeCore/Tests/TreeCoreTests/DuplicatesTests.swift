import XCTest
@testable import TreeCore

final class DuplicatesTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicatesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // chmod 000 fixtures must be readable again before removal.
        if let e = FileManager.default.enumerator(atPath: tempDir.path) {
            for case let rel as String in e {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: tempDir.appendingPathComponent(rel).path)
            }
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Helpers

    private func path(_ name: String) -> String { tempDir.appendingPathComponent(name).path }

    @discardableResult
    private func write(_ name: String, _ data: Data) throws -> String {
        let p = path(name)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: p))
        return p
    }


    /// Deterministic content; `salt` changes every byte.
    private func bytes(_ n: Int, salt: UInt8 = 0) -> Data {
        Data((0..<n).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 8)) &+ salt })
    }

    private func with(_ data: Data, byteAt i: Int) -> Data {
        var d = data
        d[i] ^= 0xff
        return d
    }

    /// Builds a tree of the temp dir from the real files' size, inode and link count (lstat, so a
    /// symlink on disk becomes a symlink node). `adjust` can rewrite an entry by its name.
    private func scan(_ adjust: (String, inout ScanEntry) -> Void = { _, _ in }) throws -> FileTree {
        let fm = FileManager.default
        let t = FileTree(rootPath: tempDir.path, device: 1)
        func walk(_ dir: String, _ parent: NodeID) throws {
            for name in try fm.contentsOfDirectory(atPath: dir).sorted() {
                let p = (dir as NSString).appendingPathComponent(name)
                let a = try fm.attributesOfItem(atPath: p)
                let type = DuplicatesIO.fileType(a[.type])
                let size = DuplicatesIO.int64(a[.size]) ?? 0
                var e = ScanEntry(name: name, isDirectory: type == .typeDirectory,
                                  isSymlink: type == .typeSymbolicLink,
                                  allocSize: type == .typeDirectory ? 0 : size,
                                  logicalSize: type == .typeDirectory ? 0 : size,
                                  fileID: DuplicatesIO.uint64(a[.systemFileNumber]) ?? 0,
                                  linkCount: UInt32(DuplicatesIO.int64(a[.referenceCount]) ?? 1), device: 1)
                adjust(name, &e)
                let id = t.addChild(of: parent, entry: e)
                if e.isDirectory { try walk(p, id) }
            }
        }
        try walk(tempDir.path, FileTree.root)
        t.recomputeAggregates()
        return t
    }

    private func find(_ t: FileTree, under root: NodeID = FileTree.root, options: DuplicateOptions = DuplicateOptions(),
                      isCancelled: () -> Bool = { false }, progress: (DuplicateProgress) -> Void = { _ in },
                      open: (String) throws -> FileHandle = DuplicatesIO.openForReading) -> DuplicateReport {
        DuplicateFinder.find(in: t.nodes, rootPath: t.rootPath, under: root, options: options,
                             isCancelled: isCancelled, progress: progress, open: open)
    }

    private func paths(_ g: DuplicateGroup) -> [String] { g.members.map(\.path) }

    private let small = DuplicateOptions(minSize: 1000, edgeBytes: 256, chunkBytes: 1000)

    // MARK: 1-2: hashing and the Foundation IO surface

    func testFNV1a64Vectors() {
        func hex(_ s: String) -> String { String(DuplicatesIO.fnv1a64(Array(s.utf8)), radix: 16) }
        XCTAssertEqual(hex(""), "cbf29ce484222325")
        XCTAssertEqual(hex("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(hex("foobar"), "85944171f73967e8")
        // Continuing from a seed equals hashing the concatenation.
        let foo = DuplicatesIO.fnv1a64(Array("foo".utf8))
        XCTAssertEqual(String(DuplicatesIO.fnv1a64(Array("bar".utf8), seed: foo), radix: 16), "85944171f73967e8")
    }

    func testLinuxFoundationIOProbe() throws {
        let fm = FileManager.default
        let data = Data((0..<1000).map { UInt8($0 % 251) })
        let file = try write("probe/file.bin", data)

        // Every throwing FileHandle call.
        let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        try h.seek(toOffset: 990)
        XCTAssertEqual(try h.read(upToCount: 100), data.suffix(10))
        let eof = try h.read(upToCount: 100)
        XCTAssertTrue(eof == nil || eof!.isEmpty, "EOF reads as nil or empty")
        try h.seek(toOffset: 0)
        XCTAssertEqual(try h.read(upToCount: 4), data.prefix(4))
        try h.close()
        XCTAssertThrowsError(try FileHandle(forReadingFrom: URL(fileURLWithPath: path("probe/missing"))))

        // lstat attributes.
        let attrs = try fm.attributesOfItem(atPath: file)
        for key in [FileAttributeKey.type, .size, .systemFileNumber, .modificationDate, .referenceCount] {
            let v = try XCTUnwrap(attrs[key], "missing \(key.rawValue)")
            print("probe attr \(key.rawValue): \(type(of: v)) = \(v)")
        }
        XCTAssertEqual(DuplicatesIO.fileType(attrs[.type]), .typeRegular)
        XCTAssertEqual(DuplicatesIO.int64(attrs[.size]), 1000)
        let inode = try XCTUnwrap(DuplicatesIO.uint64(attrs[.systemFileNumber]))
        XCTAssertNotEqual(inode, 0)
        XCTAssertNotNil(attrs[.modificationDate] as? Date)
        XCTAssertEqual(DuplicatesIO.int64(attrs[.referenceCount]), 1)

        // A symlink is reported as a symlink, not followed.
        let link = path("probe/link")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: file)
        XCTAssertEqual(DuplicatesIO.fileType(try fm.attributesOfItem(atPath: link)[.type]), .typeSymbolicLink)
        XCTAssertThrowsError(try DuplicatesIO.checkedSample(link, size: 1000, fileID: 0)) { e in
            XCTAssertEqual((e as? DuplicatesIO.Failure)?.kind, .changed)
        }

        // A hardlink shares the inode and bumps the link count.
        let hard = path("probe/hard")
        try fm.linkItem(atPath: file, toPath: hard)
        let hattrs = try fm.attributesOfItem(atPath: hard)
        XCTAssertEqual(DuplicatesIO.uint64(hattrs[.systemFileNumber]), inode)
        XCTAssertEqual(DuplicatesIO.int64(hattrs[.referenceCount]), 2)

        // The error a lstat of a missing path throws.
        do {
            _ = try fm.attributesOfItem(atPath: path("probe/missing"))
            XCTFail("lstat of a missing path must throw")
        } catch {
            let ns = error as NSError
            let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? Error).map { $0 as NSError }
            print("probe missing-path error: domain=\(ns.domain) code=\(ns.code) "
                  + "underlying=\(underlying.map { "\($0.domain) \($0.code)" } ?? "none") (\(error))")
            print("probe missing-path: CocoaError.fileReadNoSuchFile=\((error as? CocoaError)?.code == .fileReadNoSuchFile)")
            XCTAssertTrue(DuplicatesIO.isNoSuchFile(error), "missing path must map to changed (ENOENT rule)")
        }

        // The sample helper agrees and maps a missing path to `changed`.
        let s = try DuplicatesIO.checkedSample(file, size: 1000, fileID: inode)
        XCTAssertEqual(s.inode, inode)
        XCTAssertThrowsError(try DuplicatesIO.checkedSample(file, size: 999, fileID: 0))
        XCTAssertThrowsError(try DuplicatesIO.checkedSample(path("probe/missing"), size: 1, fileID: 0)) { e in
            XCTAssertEqual((e as? DuplicatesIO.Failure)?.kind, .changed)
        }
    }

    // MARK: 3-15: the finder

    func testTrueDuplicates() throws {
        let size = 2 * 1_048_576
        let data = bytes(size)
        for n in ["c.bin", "a.bin", "sub/b.bin"] { try write(n, data) }
        try write("u.bin", bytes(size, salt: 1))
        try write("d.bin", data + Data([1]))
        var events: [DuplicateProgress] = []
        let r = find(try scan(), progress: { events.append($0) })

        XCTAssertEqual(events.first, DuplicateProgress(stage: .size, filesDone: 0, filesTotal: 0, bytesRead: 0))
        XCTAssertEqual(r.groups.count, 1)
        let g = try XCTUnwrap(r.groups.first)
        XCTAssertEqual(paths(g), [path("a.bin"), path("c.bin"), path("sub/b.bin")])
        XCTAssertEqual(g.stage, .bytes)
        XCTAssertEqual(g.logicalSize, Int64(size))
        XCTAssertEqual(g.reclaimableBytes, 2 * Int64(size))
        XCTAssertEqual(g.reclaimableAllocLowerBound, 2 * Int64(size))
        XCTAssertEqual(r.status, .complete)
        XCTAssertEqual(r.treeStatus, .complete)
        XCTAssertEqual(r.candidateFiles, 4)
        XCTAssertEqual(r.pendingFiles, 0)
        XCTAssertTrue(r.skipped.isEmpty)

        let json = try JSONEncoder().encode(g)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\"reclaimableBytes\":\(2 * size)"))
        XCTAssertEqual(try JSONDecoder().decode(DuplicateGroup.self, from: json), g)
        XCTAssertEqual(try JSONDecoder().decode(DuplicateReport.self, from: JSONEncoder().encode(r)), r)
    }

    /// When iCloud downloads cannot be turned off, nothing is read: the same candidates come back,
    /// every one skipped as not_local, and the run is partial.
    func testUnreadReportsEveryCandidateWithoutReading() throws {
        let size = 2 * 1_048_576
        let data = bytes(size)
        for n in ["c.bin", "a.bin", "sub/b.bin"] { try write(n, data) }
        try write("u.bin", bytes(size, salt: 1))
        let t = try scan()
        let r = DuplicateFinder.unread(in: t.nodes, rootPath: t.rootPath, detail: "no policy")
        XCTAssertEqual(r.candidateFiles, find(t).candidateFiles)
        XCTAssertEqual(r.pendingFiles, r.candidateFiles)
        XCTAssertEqual(r.skipped.map(\.path), [path("a.bin"), path("c.bin"), path("sub/b.bin"), path("u.bin")])
        XCTAssertTrue(r.skipped.allSatisfy { $0.reason == .notLocal && $0.detail == "no policy" })
        XCTAssertEqual(r.groups, [])
        XCTAssertEqual(r.bytesRead, 0)
        XCTAssertEqual(r.status, .partial)
    }

    func testUnreadRecognizesRefusalAlongsideNotLocalSkip() throws {
        let data = bytes(5000)
        for name in ["a", "b", "cloud"] { try write(name, data) }
        let tree = try scan { name, entry in if name == "cloud" { entry.allocSize = 0 } }
        let report = DuplicateFinder.unread(in: tree.nodes, rootPath: tree.rootPath, options: small, detail: "no policy")
        XCTAssertTrue(report.nothingRead(because: "no policy"))
        XCTAssertFalse(report.skipped.allSatisfy { $0.detail == "no policy" })
    }

    func testSameSizeDifferentTail() throws {
        let data = bytes(2 * 1_048_576)
        try write("a", data)
        try write("b", with(data, byteAt: data.count - 1))
        let r = find(try scan())
        XCTAssertTrue(r.groups.isEmpty)
        XCTAssertEqual(r.status, .complete)
        XCTAssertLessThanOrEqual(r.bytesRead, 2 * 2 * 65_536)
    }

    func testSameEdgesDifferentMiddle() throws {
        let data = bytes(2 * 1_048_576)
        try write("a", data)
        try write("b", with(data, byteAt: 1_500_000))   // past chunk 1, outside the tail window
        let r = find(try scan())
        XCTAssertTrue(r.groups.isEmpty)
        XCTAssertEqual(r.status, .complete)
        XCTAssertGreaterThan(r.bytesRead, 2 * 2 * 65_536)
    }

    func testDiffInFinalPartialChunk() throws {
        let data = bytes(1_050_000)
        try write("a", data)
        try write("b", with(data, byteAt: 920_000))
        let r = find(try scan(), options: DuplicateOptions(minSize: 1000, chunkBytes: 300_000))
        XCTAssertTrue(r.groups.isEmpty)
        XCTAssertEqual(r.status, .complete)
        XCTAssertGreaterThan(r.bytesRead, 2 * 900_000)
    }

    func testHardlinks() throws {
        let data = bytes(5000)
        let fm = FileManager.default
        try fm.linkItem(atPath: try write("solo/x", data), toPath: path("solo/y"))
        try fm.linkItem(atPath: try write("trio/x", data), toPath: path("trio/y"))
        try write("trio/z", data)
        let t = try scan()

        let solo = find(t, under: try XCTUnwrap(t.lookup(path: path("solo"))), options: small)
        XCTAssertTrue(solo.groups.isEmpty)
        XCTAssertEqual(solo.candidateFiles, 0)

        let trio = find(t, under: try XCTUnwrap(t.lookup(path: path("trio"))), options: small)
        XCTAssertEqual(trio.groups.count, 1)
        let g = try XCTUnwrap(trio.groups.first)
        XCTAssertEqual(paths(g), [path("trio/x"), path("trio/z")])
        XCTAssertEqual(g.members[0].aliases, [path("trio/y")])
        XCTAssertTrue(g.members[0].sharesStorage)
        XCTAssertEqual(g.members[1].aliases, [])
        XCTAssertFalse(g.members[1].sharesStorage)
        XCTAssertEqual(g.reclaimableBytes, 5000)
        XCTAssertEqual(g.reclaimableAllocLowerBound, 5000)   // z alone; x is shared, so its blocks never count
        XCTAssertEqual(g.stage, .bytes)
        XCTAssertEqual(trio.status, .complete)
    }

    func testHardlinkTheTreeHasNotCaughtUpOn() throws {
        let data = bytes(5000)
        try FileManager.default.linkItem(atPath: try write("x", data), toPath: path("y"))
        try write("z", data)
        // x was scanned before y was linked to it: the tree still says one link.
        let t = try scan { name, e in if name == "x" { e.linkCount = 1 } }
        let r = find(t, options: small)
        XCTAssertEqual(r.groups.count, 1)
        let g = try XCTUnwrap(r.groups.first)
        XCTAssertEqual(g.members.count, 2, "x and y are one file")
        XCTAssertEqual(g.members.first { $0.path == path("x") }?.aliases, [path("y")])
        XCTAssertEqual(g.reclaimableBytes, 5000)
    }

    func testClones() throws {
        let data = bytes(5000)
        let cases: [(dir: String, clones: (UInt64, UInt64), shared: Bool, grouped: Bool)] = [
            ("same-shared", (7, 7), true, false),
            ("same-unshared", (7, 7), false, true),
            ("diff-shared", (7, 8), true, true),
            ("zero-shared", (0, 0), true, true),
        ]
        for c in cases {
            try write("\(c.dir)/a", data)
            try write("\(c.dir)/b", data)
        }
        let t = try scan()
        // Set the clone identity on the built nodes, then rebuild so the dedup holders follow.
        var nodes = t.nodes
        for c in cases {
            let dir = try XCTUnwrap(t.lookup(path: path(c.dir)))
            for (name, clone) in [("a", c.clones.0), ("b", c.clones.1)] {
                let id = Int(try XCTUnwrap(t.child(named: name, of: dir)))
                nodes[id].cloneID = clone
                if c.shared { nodes[id].flags.insert(.cloneShared) }
            }
        }
        let cloned = FileTree(restoring: nodes, rootPath: t.rootPath, device: 1)
        cloned.recomputeAggregates()

        for c in cases {
            let r = find(cloned, under: try XCTUnwrap(cloned.lookup(path: path(c.dir))), options: small)
            XCTAssertEqual(r.groups.count, c.grouped ? 1 : 0, c.dir)
            if let g = r.groups.first {
                XCTAssertEqual(paths(g), [path("\(c.dir)/a"), path("\(c.dir)/b")], c.dir)
                XCTAssertEqual(g.stage, .bytes, c.dir)
                let shares = c.shared && c.clones.0 != 0
                XCTAssertEqual(g.members.map(\.sharesStorage), [shares, shares], c.dir)
                XCTAssertEqual(g.reclaimableBytes, 5000, c.dir)
            }
            XCTAssertEqual(r.status, .complete, c.dir)
        }
    }

    func testUnreadableChmod() throws {
        let data = bytes(5000)
        for n in ["a", "b", "c"] { try write(n, data) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path("b"))
        if FileManager.default.isReadableFile(atPath: path("b")) {
            throw XCTSkip("running as root: chmod 000 does not stop reads (test 10 covers unreadable)")
        }
        let r = find(try scan(), options: small)
        assertOneUnreadable(r, unreadable: path("b"), grouped: [path("a"), path("c")])
    }

    func testOpenHookThrows() throws {
        let data = bytes(5000)
        for n in ["a", "b", "c"] { try write(n, data) }
        struct Denied: Error {}
        let r = find(try scan(), options: small, open: { p in
            if p == self.path("b") { throw Denied() }
            return try DuplicatesIO.openForReading(p)
        })
        assertOneUnreadable(r, unreadable: path("b"), grouped: [path("a"), path("c")])
    }

    private func assertOneUnreadable(_ r: DuplicateReport, unreadable: String, grouped: [String],
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.skipped.map(\.path), [unreadable], file: file, line: line)
        XCTAssertEqual(r.skipped.first?.reason, .unreadable, file: file, line: line)
        XCTAssertEqual(r.groups.map(paths), [grouped], file: file, line: line)
        XCTAssertEqual(r.groups.first?.stage, .bytes, file: file, line: line)
        XCTAssertEqual(r.status, .partial, file: file, line: line)
    }

    func testChangedMidRun() throws {
        let data = bytes(5000)
        for n in ["a", "b", "c", "d"] { try write(n, data) }
        let t = try scan()
        var mutated = false
        let r = find(t, options: small, progress: { p in
            guard p.stage == .bytes, !mutated else { return }
            mutated = true
            do {
                let h = try FileHandle(forUpdating: URL(fileURLWithPath: self.path("a")))
                try h.seekToEnd()
                try h.write(contentsOf: Data([0]))
                try h.close()
                try FileManager.default.removeItem(atPath: self.path("c"))
            } catch { XCTFail("fixture mutation failed: \(error)") }
        })
        XCTAssertTrue(mutated)
        XCTAssertEqual(r.skipped.map(\.path), [path("a"), path("c")])
        XCTAssertEqual(r.skipped.map(\.reason), [.changed, .changed])
        XCTAssertEqual(r.groups.map(paths), [[path("b"), path("d")]])
        XCTAssertEqual(r.groups.first?.stage, .bytes)
        XCTAssertEqual(r.status, .partial)
    }

    func testFilesWithoutLocalDataAreNeverRead() throws {
        let data = bytes(5000)
        for n in ["a", "b", "cloud"] { try write(n, data) }
        try write("lonely", bytes(7000))
        let t = try scan { name, e in if name == "cloud" || name == "lonely" { e.allocSize = 0 } }
        var opened: [String] = []
        let r = find(t, options: small, open: { opened.append($0); return try DuplicatesIO.openForReading($0) })
        XCTAssertFalse(opened.contains(path("cloud")))
        XCTAssertEqual(r.skipped.map(\.path), [path("cloud")])
        XCTAssertEqual(r.skipped.first?.reason, .notLocal)
        XCTAssertEqual(r.groups.map(paths), [[path("a"), path("b")]])
        XCTAssertEqual(r.status, .partial)
        // Alone in its size it would not have been compared, so it is not reported either.
        XCTAssertFalse(r.skipped.map(\.path).contains(path("lonely")))
    }

    func testSymlinks() throws {
        let data = bytes(5000)
        try write("a", data)
        try write("b", data)
        try FileManager.default.createSymbolicLink(atPath: path("link"), withDestinationPath: path("a"))
        try FileManager.default.createSymbolicLink(atPath: path("slink"), withDestinationPath: path("b"))
        let t = try scan { name, e in
            switch name {
            case "link":   // a regular-file node on a path that is a symlink on disk
                e.isSymlink = false; e.logicalSize = 5000; e.allocSize = 5000; e.fileID = 0
            case "slink":  // a symlink node the size of the copies: never a candidate
                XCTAssertTrue(e.isSymlink)
                e.logicalSize = 5000; e.allocSize = 5000
            default: break
            }
        }
        let r = find(t, options: small)
        XCTAssertEqual(r.skipped.map(\.path), [path("link")])
        XCTAssertEqual(r.skipped.first?.reason, .changed)
        XCTAssertEqual(r.groups.map(paths), [[path("a"), path("b")]])
        XCTAssertEqual(r.groups.first?.stage, .bytes)
        XCTAssertEqual(r.candidateFiles, 3)
        XCTAssertEqual(r.status, .partial)
    }

    func testCancel() throws {
        try write("a1", bytes(3000)); try write("a2", bytes(3000))
        try write("b1", bytes(2000)); try write("b2", bytes(2000))
        var cancelled = false
        let r = find(try scan(), options: small, isCancelled: { cancelled }, progress: { p in
            if p.stage == .bytes { cancelled = true }
        })
        XCTAssertEqual(r.status, .cancelled)
        XCTAssertEqual(r.groups.map(paths), [[path("a1"), path("a2")]])
        XCTAssertEqual(r.groups.map(\.stage), [.edges])
        XCTAssertFalse(r.groups.contains { $0.stage == .bytes })
        XCTAssertEqual(r.candidateFiles, 4)
        XCTAssertEqual(r.pendingFiles, 2)
    }

    func testMinSizeBoundaryAndPartialTree() throws {
        try write("e1", bytes(4096)); try write("e2", bytes(4096))
        try write("s1", bytes(4095)); try write("s2", bytes(4095))
        try FileManager.default.createDirectory(atPath: path("locked"), withIntermediateDirectories: true)
        let t = try scan()
        let opts = DuplicateOptions(minSize: 4096, edgeBytes: 256, chunkBytes: 1000)

        let full = find(t, options: opts)
        XCTAssertEqual(full.groups.map(paths), [[path("e1"), path("e2")]])
        XCTAssertEqual(full.candidateFiles, 2)
        XCTAssertEqual(full.status, .complete)

        t.markUnavailable(try XCTUnwrap(t.lookup(path: path("locked"))))
        let partial = find(t, options: opts)
        XCTAssertEqual(partial.groups.map(paths), [[path("e1"), path("e2")]])
        XCTAssertEqual(partial.treeStatus, .partial)
        XCTAssertEqual(partial.status, .partial)

        for bad in [NodeID(-1), NodeID(t.nodes.count)] {
            let r = find(t, under: bad, options: opts)
            XCTAssertEqual(r.status, .partial)
            XCTAssertEqual(r.treeStatus, .unavailable)
            XCTAssertTrue(r.groups.isEmpty)
        }

        let gone = FileTree(rootPath: path("gone"), device: 1)
        gone.markUnavailable(FileTree.root)
        let r = find(gone, options: opts)
        XCTAssertEqual(r.status, .partial)
        XCTAssertEqual(r.treeStatus, .unavailable)
        XCTAssertTrue(r.groups.isEmpty)
    }

    func testOptionsClamped() throws {
        try write("a", bytes(3000)); try write("b", bytes(3000))
        let r = find(try scan(), options: DuplicateOptions(minSize: 1, edgeBytes: -5, chunkBytes: 0))
        XCTAssertEqual(r.groups.map(paths), [[path("a"), path("b")]])
        XCTAssertEqual(r.groups.first?.stage, .bytes)
        XCTAssertEqual(r.status, .complete)
    }
}
