import Foundation
import XCTest
@testable import ScanCore

final class ContainerLaneTests: XCTestCase {
    /// Folders under Library/Containers and Library/Group Containers go through the one-at-a-time lane;
    /// a parallel scan of many of them still finishes complete and counts what a sequential scan counts.
    func testContainerFoldersScanCompleteThroughTheLane() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("HoardLane-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        for kind in ["Containers", "Group Containers"] {
            for app in 0..<40 {
                let data = base.appendingPathComponent("Library/\(kind)/com.vendor.app\(app)/Data/Library/Caches")
                try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
                for f in 0..<5 { try Data(repeating: 1, count: 100).write(to: data.appendingPathComponent("f\(f)")) }
            }
        }
        let root = try XCTUnwrap(realpath(base.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        let parallel = try Scanner(options: ScanOptions(threads: 8)).scan(root: root)
        let sequential = try Scanner().scanSequential(root: root)
        XCTAssertEqual(parallel[FileTree.root].status, .complete)
        XCTAssertEqual(parallel[FileTree.root].fileCount, 400)
        XCTAssertEqual(parallel[FileTree.root].fileCount, sequential[FileTree.root].fileCount)
        XCTAssertEqual(parallel[FileTree.root].dirCount, sequential[FileTree.root].dirCount)
    }
}
