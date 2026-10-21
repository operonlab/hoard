import XCTest
import TreeCore

final class DiffTests: XCTestCase {
    static let mb: Int64 = 1_048_576
    static let gb: Int64 = 1_073_741_824

    /// Builds a summary from relative file paths and sizes; a trailing "/" makes an empty directory.
    private func summary(_ files: [String: Int64], day: Double = 0) -> TreeSummary {
        let t = FileTree(rootPath: "/r", device: 1)
        func dir(_ comps: ArraySlice<Substring>) -> NodeID {
            var cur = FileTree.root
            for c in comps {
                cur = t.child(named: String(c), of: cur)
                    ?? t.addChild(of: cur, entry: ScanEntry(name: String(c), isDirectory: true, device: 1))
            }
            return cur
        }
        for (path, size) in files.sorted(by: { $0.key < $1.key }) {
            let comps = path.split(separator: "/")
            if path.hasSuffix("/") { _ = dir(comps[...]); continue }
            t.addChild(of: dir(comps.dropLast()), entry: ScanEntry(name: String(comps.last!), isDirectory: false,
                                                                    allocSize: size, device: 1))
        }
        t.recomputeAggregates()
        return TreeSummary(tree: t, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + day * 86_400))
    }

    func testFolderThatBecameUnreadableIsUncertainNotFreed() {
        // Before: "locked" held 100 MB. After: permission lost, the folder reads as unavailable with 0 bytes.
        let before = summary(["locked/a.bin": 100 * Self.mb, "ok/b.bin": 5 * Self.mb])
        var after = summary(["locked/": 0, "ok/b.bin": 5 * Self.mb], day: 1)
        let lockedIndex = after.dirs.firstIndex { $0.name == "locked" }!
        after.dirs[lockedIndex].status = .unavailable
        let report = TreeDiff.compare(before, after)
        let shrink = report.shrunk.first { $0.path == "/r/locked" }
        XCTAssertNotNil(shrink)
        XCTAssertEqual(shrink?.uncertain, true, "lost permission is not reclaimed space")
        XCTAssertFalse(report.grown.contains { $0.uncertain }, "nothing else is uncertain")
    }

    /// Marks `name` unavailable and its ancestors partial, as FileTree does when a folder cannot be read.
    private func makeUnreadable(_ name: String, in s: inout TreeSummary) {
        var i = s.dirs.firstIndex { $0.name == name }!
        s.dirs[i].status = .unavailable
        while s.dirs[i].parent >= 0 {
            i = Int(s.dirs[i].parent)
            s.dirs[i].status = .partial
        }
    }

    func testBigFileInAFolderThatBecameUnreadableIsNotRemoved() {
        let mb = Self.mb
        let before = summary(["locked/big.bin": 100 * mb, "locked/sub/deep.bin": 50 * mb, "ok/b.bin": 5 * mb])
        var after = summary(["locked/": 0, "ok/b.bin": 5 * mb], day: 1)
        makeUnreadable("locked", in: &after)
        let report = TreeDiff.compare(before, after)
        XCTAssertEqual(report.files, [], "an unreadable folder may still hold them")
    }

    func testRemovedFolderUnderUnreadableAncestorIsUncertain() {
        let before = summary(["a/b/file.bin": 10 * Self.mb, "ok/file.bin": Self.mb])
        var after = summary(["a/": 0, "ok/file.bin": Self.mb], day: 1)
        makeUnreadable("a", in: &after)
        let report = TreeDiff.compare(before, after)
        let removed = report.shrunk.first { $0.path == "/r/a/b" }
        XCTAssertEqual(removed?.kind, .removed)
        XCTAssertEqual(removed?.uncertain, true)
        XCTAssertEqual(report.rootStatusBefore, .complete)
        XCTAssertEqual(report.rootStatusAfter, .partial)
    }

    func testRootStatusSurvivesRowFilteringAndLegacyDecoding() throws {
        let before = summary(["a/file": 128])
        var after = summary(["a/": 0], day: 1)
        makeUnreadable("a", in: &after)
        let report = TreeDiff.compare(before, after, topN: 0, minDelta: Self.mb)
        XCTAssertTrue(report.grown.isEmpty && report.shrunk.isEmpty && report.files.isEmpty)
        XCTAssertEqual(report.rootStatusBefore, .complete)
        XCTAssertEqual(report.rootStatusAfter, .partial)
        XCTAssertEqual(try JSONDecoder().decode(DiffReport.self, from: JSONEncoder().encode(report)), report)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        legacy.removeValue(forKey: "rootStatusBefore")
        legacy.removeValue(forKey: "rootStatusAfter")
        let decoded = try JSONDecoder().decode(DiffReport.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.rootStatusBefore, .complete)
        XCTAssertEqual(decoded.rootStatusAfter, .complete)
    }

    func testRemovalNextToAnUnreadableFolderIsStillReported() {
        // The root is partial because of "locked", but "ok" listed completely: its files really are gone.
        let mb = Self.mb
        let before = summary(["ok/gone.bin": 50 * mb, "ok/keep.bin": 1 * mb, "ok/sub/deep.bin": 30 * mb,
                              "locked/x.bin": 20 * mb])
        var after = summary(["ok/keep.bin": 1 * mb, "locked/": 0], day: 1)
        makeUnreadable("locked", in: &after)
        XCTAssertEqual(after.dirs[0].status, .partial)
        let report = TreeDiff.compare(before, after)
        XCTAssertEqual(report.files, [FileChange(path: "/r/ok/gone.bin", kind: .removed, before: 50 * mb, after: 0),
                                      FileChange(path: "/r/ok/sub/deep.bin", kind: .removed, before: 30 * mb, after: 0)])
    }

    func testDeepGrowthIsReportedOnceAtTheHotspot() {
        let mb = Self.mb, gb = Self.gb
        let old = summary(["a/b/c/d/old.bin": 5 * mb, "a/x.txt": 1 * mb, "z/y.bin": 2 * mb])
        let new = summary(["a/b/c/d/old.bin": 5 * mb, "a/b/c/d/new.bin": gb, "a/x.txt": 1 * mb, "z/y.bin": 2 * mb],
                          day: 1)
        let r = TreeDiff.compare(old, new)
        XCTAssertEqual(r.totalBefore, 8 * mb)
        XCTAssertEqual(r.totalAfter, 8 * mb + gb)
        XCTAssertEqual(r.totalDelta, gb)
        XCTAssertEqual(r.grown, [DirChange(path: "/r/a/b/c/d", kind: .changed, before: 5 * mb, after: 5 * mb + gb,
                                           filesBefore: 1, filesAfter: 2)])
        XCTAssertEqual(r.shrunk, [])
        XCTAssertEqual(r.files, [FileChange(path: "/r/a/b/c/d/new.bin", kind: .added, before: 0, after: gb)])
        XCTAssertEqual(r.fromDate, old.createdAt)
        XCTAssertEqual(r.toDate, new.createdAt)
    }

    func testSpreadGrowthIsReportedAtTheParent() {
        // 60/40 split: no child explains 80%, so the parent is a hotspot (and so is each leaf child).
        let mb = Self.mb
        let old = summary(["p/a/f": mb, "p/b/f": mb])
        let new = summary(["p/a/f": 61 * mb, "p/b/f": 41 * mb])
        let r = TreeDiff.compare(old, new)
        XCTAssertEqual(r.grown.map(\.path), ["/r/p", "/r/p/a", "/r/p/b"])   // /r is explained by /r/p alone
        XCTAssertEqual(r.grown.map(\.delta), [100 * mb, 60 * mb, 40 * mb])

        // Exactly 80% from one child counts as explained.
        let new80 = summary(["p/a/f": 81 * mb, "p/b/f": 21 * mb])
        XCTAssertEqual(TreeDiff.compare(old, new80).grown.map(\.path), ["/r/p/a", "/r/p/b"])
    }

    func testGrownAndShrunkSplitAndOrdering() {
        let mb = Self.mb
        let old = summary(["a/f": 10 * mb, "b/f": 50 * mb, "c/f": 10 * mb, "d/f": 30 * mb, "e/f": 10 * mb])
        let new = summary(["a/f": 40 * mb, "b/f": 20 * mb, "c/f": 30 * mb, "d/f": 25 * mb, "e/f": 10 * mb])
        let r = TreeDiff.compare(old, new)
        XCTAssertEqual(r.grown.map(\.path), ["/r/a", "/r/c"])
        XCTAssertEqual(r.grown.map(\.delta), [30 * mb, 20 * mb])
        XCTAssertEqual(r.shrunk.map(\.path), ["/r/b", "/r/d"])
        XCTAssertEqual(r.shrunk.map(\.delta), [-30 * mb, -5 * mb])
        XCTAssertTrue(r.grown.allSatisfy { $0.kind == .changed })
        // Root: +50 -35 = +15 MB; largest child (+30) is 200% of it, so not a hotspot.
        XCTAssertEqual(r.totalDelta, 15 * mb)
    }

    func testMinDeltaFilter() {
        let mb = Self.mb
        let old = summary(["a/f": 10 * mb, "b/f": 10 * mb])
        let new = summary(["a/f": 10 * mb + 512 * 1024, "b/f": 13 * mb])
        XCTAssertEqual(TreeDiff.compare(old, new).grown.map(\.path), ["/r/b"])
        XCTAssertEqual(TreeDiff.compare(old, new, minDelta: 4 * mb).grown, [])
        XCTAssertEqual(TreeDiff.compare(old, new, minDelta: 4 * mb).files, [])
        XCTAssertEqual(TreeDiff.compare(old, new, minDelta: 1).grown.map(\.path), ["/r/b", "/r/a"])
    }

    func testAddedAndRemovedReportSubtreeRootsOnly() {
        let mb = Self.mb
        let old = summary(["keep/f": mb, "gone/x/y/f": 20 * mb, "gone/x/g": 5 * mb, "gone/z/": 0])
        let new = summary(["keep/f": mb, "fresh/p/q/f": 30 * mb, "fresh/p/h": 2 * mb, "fresh/empty/": 0])
        let r = TreeDiff.compare(old, new)
        XCTAssertEqual(r.grown, [DirChange(path: "/r/fresh", kind: .added, before: 0, after: 32 * mb,
                                           filesBefore: 0, filesAfter: 2)])
        XCTAssertEqual(r.shrunk, [DirChange(path: "/r/gone", kind: .removed, before: 25 * mb, after: 0,
                                            filesBefore: 2, filesAfter: 0)])
        // The root changed by +7 MB, but /r/fresh (+32) explains it in the same direction.
        XCTAssertFalse(r.grown.contains { $0.path == "/r" })
    }

    func testRemovedChildExplainsShrinkingParent() {
        let mb = Self.mb
        let old = summary(["a/gone/f": 100 * mb, "a/keep/f": mb])
        let new = summary(["a/keep/f": mb])
        let r = TreeDiff.compare(old, new)
        XCTAssertEqual(r.shrunk.map(\.path), ["/r/a/gone"])
        XCTAssertEqual(r.shrunk.first?.kind, .removed)
        XCTAssertEqual(r.grown, [])
    }

    func testAddedDirUnderChangedParentExplainsIt() {
        let gb = Self.gb
        let old = summary(["a/b/c/f": 1])
        let new = summary(["a/b/c/f": 1, "a/b/c/d/big": gb])
        let r = TreeDiff.compare(old, new)
        XCTAssertEqual(r.grown.map(\.path), ["/r/a/b/c/d"])
        XCTAssertEqual(r.grown.first?.kind, .added)
    }

    func testBigFilesGrownShrunkAddedRemoved() {
        let mb = Self.mb
        let old = summary(["v/grow.mov": 20 * mb, "v/shrink.mov": 40 * mb, "v/gone.mov": 15 * mb,
                           "v/same.mov": 12 * mb, "v/tiny.mov": 30 * mb])
        let new = summary(["v/grow.mov": 50 * mb, "v/shrink.mov": 30 * mb, "v/new.mov": 11 * mb,
                           "v/same.mov": 12 * mb, "v/tiny.mov": 30 * mb + 100])
        let r = TreeDiff.compare(old, new)
        XCTAssertEqual(r.files, [
            FileChange(path: "/r/v/grow.mov", kind: .grown, before: 20 * mb, after: 50 * mb),
            FileChange(path: "/r/v/gone.mov", kind: .removed, before: 15 * mb, after: 0),
            FileChange(path: "/r/v/new.mov", kind: .added, before: 0, after: 11 * mb),
            FileChange(path: "/r/v/shrink.mov", kind: .shrunk, before: 40 * mb, after: 30 * mb),
        ])
    }

    func testTopNCut() {
        let mb = Self.mb
        var oldFiles: [String: Int64] = [:], newFiles: [String: Int64] = [:]
        for i in 1...10 {
            oldFiles["g\(i)/f.bin"] = 20 * mb; newFiles["g\(i)/f.bin"] = (20 + Int64(i)) * mb
            oldFiles["s\(i)/f.bin"] = 20 * mb; newFiles["s\(i)/f.bin"] = (20 - Int64(i)) * mb
        }
        let r = TreeDiff.compare(summary(oldFiles), summary(newFiles), topN: 3)
        XCTAssertEqual(r.grown.map(\.path), ["/r/g10", "/r/g9", "/r/g8"])
        XCTAssertEqual(r.shrunk.map(\.path), ["/r/s10", "/r/s9", "/r/s8"])
        XCTAssertEqual(r.files.map(\.path), ["/r/g10/f.bin", "/r/s10/f.bin", "/r/g9/f.bin"])
        XCTAssertEqual(TreeDiff.compare(summary(oldFiles), summary(newFiles), topN: 0).grown, [])
    }

    func testIdenticalSummariesHaveNoChanges() {
        let s = summary(["a/f": 100 * Self.mb])
        let r = TreeDiff.compare(s, s)
        XCTAssertEqual(r.grown, []); XCTAssertEqual(r.shrunk, []); XCTAssertEqual(r.files, [])
        XCTAssertEqual(r.totalDelta, 0)
    }

    func testLargeSyntheticDiffIsFast() {
        // 500k dirs: 1000 top-level dirs × 499 children, plus the root and the 1000 parents → 500,001.
        let mb = Self.mb
        func build(_ shift: Int64) -> TreeSummary {
            var dirs: [TreeSummary.Dir] = [TreeSummary.Dir(parent: -1, name: "/r", totalAlloc: 0, fileCount: 0, status: .complete)]
            dirs.reserveCapacity(500_001)
            var files: [TreeSummary.BigFile] = []
            var rootTotal: Int64 = 0
            for top in 0..<1000 {
                let p = Int32(dirs.count)
                dirs.append(TreeSummary.Dir(parent: 0, name: "top\(top)", totalAlloc: 0, fileCount: 0, status: .complete))
                var sub: Int64 = 0
                for leaf in 0..<499 {
                    // Every 1000th leaf changes size between versions.
                    let size = 3 * mb + ((top * 499 + leaf) % 1000 == 0 ? shift * Int64(top + 1) : 0)
                    if leaf == 0 { files.append(TreeSummary.BigFile(dir: Int32(dirs.count), name: "f", alloc: size, modTime: 0, accessTime: 0)) }
                    dirs.append(TreeSummary.Dir(parent: p, name: "d\(leaf)", totalAlloc: size, fileCount: 1, status: .complete))
                    sub += size
                }
                dirs[Int(p)].totalAlloc = sub
                rootTotal += sub
            }
            dirs[0].totalAlloc = rootTotal
            return TreeSummary(rootPath: "/r", createdAt: Date(timeIntervalSince1970: 0), bigFileThreshold: mb,
                               dirs: dirs, bigFiles: files)
        }
        let old = build(0), new = build(mb)
        XCTAssertEqual(new.dirs.count, 500_001)
        let start = Date()
        let r = TreeDiff.compare(old, new)
        let elapsed = Date().timeIntervalSince(start)
        print("TreeDiff.compare 500k dirs: \(String(format: "%.3f", elapsed)) s")
        XCTAssertEqual(r.grown.count, 50)
        XCTAssertEqual(r.grown.first?.path, "/r")                    // ~500 spread changes: the root is a hotspot
        XCTAssertEqual(r.grown[1].path, "/r/top997/d497")   // 997·499 + 497 = 498000
        XCTAssertEqual(r.grown[1].delta, 998 * mb)
        #if !DEBUG
        XCTAssertLessThan(elapsed, 2.0)
        #endif
    }
}
