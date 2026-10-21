import Foundation
import XCTest
import TreeCore

/// Names are built with `String(decoding:as:)` from byte arrays, never from literals: literals share
/// immortal storage and would make the sharing test pass without any interning.
final class NameInterningTests: XCTestCase {
    private func name(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }
    private func name(_ text: String) -> String { name(Array(text.utf8)) }

    private func file(_ name: String, _ size: Int64, fileID: UInt64) -> ScanEntry {
        ScanEntry(name: name, isDirectory: false, allocSize: size, logicalSize: size, fileID: fileID, device: 1)
    }

    private func dir(_ name: String) -> ScanEntry { ScanEntry(name: name, isDirectory: true, device: 1) }

    private func address(_ s: String) -> UInt {
        var copy = s
        return copy.withUTF8 { UInt(bitPattern: $0.baseAddress) }
    }

    private func roundTrip(_ tree: FileTree) throws -> FileTree {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tree.dscan")
        try Snapshot.write(tree, meta: SnapshotMeta(rootPath: tree.rootPath, device: tree.device, createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                                    scanSeconds: 0, lastEventId: 0, eventsUUID: nil), to: url)
        return try Snapshot.read(from: url).tree
    }

    // "café-a-long-shared-name.txt" precomposed (NFC) and decomposed (NFD): canonically equal, different bytes.
    private let nfcBytes: [UInt8] = Array("caf".utf8) + [0xC3, 0xA9] + Array("-a-long-shared-name.txt".utf8)
    private let nfdBytes: [UInt8] = Array("cafe".utf8) + [0xCC, 0x81] + Array("-a-long-shared-name.txt".utf8)

    func testExactBytesSurviveInterning() throws {
        XCTAssertEqual(name(nfcBytes), name(nfdBytes))
        let fifteen = Array("fifteen-bytes.t".utf8), sixteen = Array("sixteen-bytes.tx".utf8)
        XCTAssertEqual(fifteen.count, 15); XCTAssertEqual(sixteen.count, 16)
        let t = FileTree(rootPath: "/i", device: 1)
        let same = t.addChild(of: FileTree.root, entry: dir("same"))
        let x = t.addChild(of: FileTree.root, entry: dir("x"))
        let y = t.addChild(of: FileTree.root, entry: dir("y"))
        let inputs: [(NodeID, [UInt8])] = [
            (same, nfcBytes), (same, nfdBytes), (x, nfcBytes), (y, nfdBytes),
            (same, fifteen), (same, sixteen), (x, fifteen), (y, sixteen),
        ]
        var ids: [NodeID] = []
        for (i, (parent, bytes)) in inputs.enumerated() {
            ids.append(t.addChild(of: parent, entry: file(name(bytes), 10, fileID: UInt64(100 + i))))
        }
        t.recomputeAggregates()
        let restored = try roundTrip(t)
        for tree in [t, restored] {
            for (id, (_, bytes)) in zip(ids, inputs) {
                XCTAssertEqual(Array(tree[id].name.utf8), bytes, "node \(id)")
            }
            // Ids the unchanged source returns: String == is canonical equivalence, and the most
            // recently added sibling comes first.
            XCTAssertEqual(tree.child(named: name(nfcBytes), of: same), 5)
            XCTAssertEqual(tree.child(named: name(nfdBytes), of: same), 5)
            XCTAssertEqual(tree.child(named: name(nfdBytes), of: x), 6)
            XCTAssertEqual(tree.child(named: name(nfcBytes), of: y), 7)
            XCTAssertEqual(tree.child(named: name(fifteen), of: same), 8)
            XCTAssertEqual(tree.child(named: name(sixteen), of: same), 9)
            XCTAssertEqual(tree.lookup(path: "/i/y/" + name(nfcBytes)), 7)
        }
    }

    func testEqualLongNamesShareStorage() throws {
        let bytes = Array("a-thirty-byte-long-shared-name".utf8)
        XCTAssertEqual(bytes.count, 30)
        let t = FileTree(rootPath: "/s", device: 1)
        let a = t.addChild(of: FileTree.root, entry: dir("a"))
        let b = t.addChild(of: FileTree.root, entry: dir("b"))
        let first = t.addChild(of: a, entry: file(name(bytes), 1, fileID: 1))
        let second = t.addChild(of: b, entry: file(name(bytes), 2, fileID: 2))
        t.recomputeAggregates()
        XCTAssertEqual(address(t[first].name), address(t[second].name), "after the build")
        let restored = try roundTrip(t)
        XCTAssertEqual(Array(restored[first].name.utf8), bytes)
        XCTAssertEqual(address(restored[first].name), address(restored[second].name), "after Snapshot.read")
    }

    func testLiveMutationAfterBuild() throws {
        let long = Array("a-long-name-used-again-after-the-build.bin".utf8)
        let t = FileTree(rootPath: "/m", device: 1)
        let a = t.addChild(of: FileTree.root, entry: dir("a"))
        let kept = t.addChild(of: a, entry: file(name(long), 100, fileID: 1))
        let doomed = t.addChild(of: a, entry: file(name("doomed-file-with-a-long-name.tmp"), 7, fileID: 2))
        t.recomputeAggregates()

        let inserted = t.insert(file(name(long), 50, fileID: 3), under: FileTree.root)
        XCTAssertEqual(Array(t[inserted].name.utf8), long)
        XCTAssertNotEqual(address(t[inserted].name), address(t[kept].name), "live inserts keep their own String")

        let sub = FileTree(rootPath: "/elsewhere", device: 1)
        let subDir = sub.addChild(of: FileTree.root, entry: dir(name("grafted-subdirectory-name")))
        sub.addChild(of: subDir, entry: file(name(long), 30, fileID: 4))
        sub.addChild(of: subDir, entry: file(name(long), 30, fileID: 5))
        sub.recomputeAggregates()
        let grafted = t.graft(sub, as: name("grafted-root-with-long-name"), under: a)

        t.removeSubtree(doomed)

        XCTAssertEqual(t[FileTree.root].totalAlloc, 100 + 50 + 60)
        XCTAssertEqual(t[FileTree.root].fileCount, 4)
        XCTAssertEqual(t[FileTree.root].dirCount, 4)
        XCTAssertEqual(t[a].totalAlloc, 160)
        XCTAssertEqual(t[grafted].totalAlloc, 60)
        XCTAssertNil(t.child(named: name("doomed-file-with-a-long-name.tmp"), of: a))
        XCTAssertEqual(t.path(of: grafted), "/m/a/grafted-root-with-long-name")
        let graftedDir = try XCTUnwrap(t.lookup(path: "/m/a/grafted-root-with-long-name/grafted-subdirectory-name"))
        XCTAssertEqual(t.children(of: graftedDir).map { Array(t[$0].name.utf8) }, [long, long])
        XCTAssertEqual(t.lookup(path: "/m/" + name(long)), inserted)
        XCTAssertEqual(t.lookup(path: "/m/a/" + name(long)), kept)
    }
}
