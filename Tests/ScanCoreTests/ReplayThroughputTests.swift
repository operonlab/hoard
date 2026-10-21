import Foundation
import XCTest
@testable import ScanCore

final class ReplayThroughputTests: XCTestCase {
    func testFiftyThousandChangePathResolutions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HoardReplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = FileTree(rootPath: root.path, device: 1)
        for i in 0..<200 {
            tree.addChild(of: 0, entry: ScanEntry(name: "item\(i)", isDirectory: false, device: 1))
        }
        tree.recomputeAggregates()
        let updater = LiveUpdater(tree: tree, scanner: Scanner(), sinceEventId: nil) { _ in }
        let paths = (0..<50_000).map { (root.path + "/item\($0 % 200)" as NSString) as String }

        func oldLookup(_ path: String) -> NodeID? {
            let base = tree.rootPath.hasSuffix("/") ? String(tree.rootPath.dropLast()) : tree.rootPath
            var p = path
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            if p == base || p == tree.rootPath { return 0 }
            guard p.hasPrefix(base + "/") else { return nil }
            var current: NodeID = 0
            for component in p.dropFirst(base.count + 1).split(separator: "/") {
                var child = tree[current].firstChild
                while child >= 0 && tree[child].name != component { child = tree[child].nextSibling }
                guard child >= 0 else { return nil }
                current = child
            }
            return current
        }
        func oldResolve(_ eventPath: String) -> NodeID? {
            var path = eventPath
            var id = oldLookup(path)
            while id == nil && path != tree.rootPath {
                path = (path as NSString).deletingLastPathComponent
                id = oldLookup(path)
            }
            guard let nodeID = id else { return nil }
            if !tree[nodeID].isDirectory { path = (path as NSString).deletingLastPathComponent }
            if path != tree.rootPath && !FileManager.default.fileExists(atPath: path) {
                path = (path as NSString).deletingLastPathComponent
            }
            return oldLookup(path)
        }
        func measure(_ body: (String) -> NodeID?) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var checksum: Int64 = 0
            for path in paths { checksum += Int64(body(path) ?? -1) }
            XCTAssertEqual(checksum, 0)
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        }

        // Interleaved, best of three: a busy machine stalls single runs, rarely all three of one side.
        var before = Double.infinity, after = Double.infinity
        for _ in 0..<3 {
            before = min(before, measure(oldResolve))
            after = min(after, measure { updater.resolveDirectory(for: $0)?.0 })
        }
        print(String(format: "REPLAY_THROUGHPUT paths=50000 before=%.3fs after=%.3fs", before, after))
        XCTAssertLessThanOrEqual(after, before)
    }

    func testResolveDirectoryPicksTheFolderToRelist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HoardResolve-\(UUID().uuidString)")
        let nfd = "cafe\u{301}", nfc = "caf\u{E9}"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(nfd), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = FileTree(rootPath: root.path, device: 1)
        let a = tree.addChild(of: 0, entry: ScanEntry(name: "a", isDirectory: true, device: 1))
        let b = tree.addChild(of: a, entry: ScanEntry(name: "b", isDirectory: true, device: 1))
        tree.addChild(of: b, entry: ScanEntry(name: "c", isDirectory: false, device: 1))
        let gone = tree.addChild(of: a, entry: ScanEntry(name: "gone", isDirectory: true, device: 1))
        let accented = tree.addChild(of: 0, entry: ScanEntry(name: nfd, isDirectory: true, device: 1))
        tree.recomputeAggregates()
        let updater = LiveUpdater(tree: tree, scanner: Scanner(), sinceEventId: nil) { _ in }
        let base = root.path
        func resolve(_ p: String) -> (NodeID, String)? { updater.resolveDirectory(for: (p as NSString) as String) }

        XCTAssertEqual(resolve(base + "/a/b/c")?.0, b)
        XCTAssertEqual(resolve(base + "/a/b/c")?.1, base + "/a/b")
        XCTAssertEqual(resolve(base + "/a/b/new/deeper")?.0, b)
        XCTAssertEqual(resolve(base + "/a/gone/x")?.0, a)
        XCTAssertNotEqual(resolve(base + "/a/gone/x")?.0, gone)
        XCTAssertEqual(resolve(base + "/a/gone/x")?.1, base + "/a")
        XCTAssertEqual(resolve(base)?.0, FileTree.root)
        XCTAssertEqual(resolve(base + "/")?.1, base)
        // An NFC event for an NFD folder lands on it and relists it under the name the disk gave.
        XCTAssertEqual(resolve(base + "/" + nfc + "/new")?.0, accented)
        XCTAssertEqual(resolve(base + "/" + nfc + "/new").map { Array($0.1.utf8) }, Array((base + "/" + nfd).utf8))
    }

    func testBatchReleasesNameIndexes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HoardIndexRelease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("wide"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<100 { try Data([1]).write(to: root.appendingPathComponent("wide/f\(i)")) }
        let scanner = ScanCore.Scanner()
        let tree = try scanner.scan(root: root.path)
        let done = expectation(description: "batch")
        let updater = LiveUpdater(tree: tree, scanner: scanner, sinceEventId: 1) { _ in done.fulfill() }
        // Built by the lookup this batch makes, then released when the batch ends.
        XCTAssertNotNil(tree.lookup(path: root.path + "/wide/f50"))
        XCTAssertEqual(tree.indexedFolderCount, 1)
        try Data([1, 2]).write(to: root.appendingPathComponent("wide/f7"))
        updater.applyDirectoryEvents([(root.path + "/wide/f7", false)], eventId: 2)
        wait(for: [done], timeout: 10)
        XCTAssertEqual(tree.indexedFolderCount, 0)
        XCTAssertEqual(tree[try XCTUnwrap(tree.lookup(path: root.path + "/wide/f7"))].logicalSize, 2)
    }

    func testEventOutsideRootResolvesToNothing() {
        let tree = FileTree(rootPath: "/nonexistent-hoard-root", device: 1)
        tree.recomputeAggregates()
        let updater = LiveUpdater(tree: tree, scanner: Scanner(), sinceEventId: nil) { _ in }
        XCTAssertNil(updater.resolveDirectory(for: "/elsewhere/deep/file"))
        XCTAssertNil(updater.resolveDirectory(for: "/"))
    }
}
