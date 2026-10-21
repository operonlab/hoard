#if canImport(Darwin)
import Darwin
import XCTest
@testable import TreeCore

/// Reading for a comparison must not keep what it read: on Darwin each FileHandle read is an
/// autoreleased NSData, and a run is one loop with no pool boundary.
final class DuplicatesMemoryTests: XCTestCase {
    private func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    func testComparingLargeFilesDoesNotKeepWhatItRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicatesMemory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = 96 * 1_048_576
        let content = Data(repeating: 0x5A, count: size)
        let t = FileTree(rootPath: dir.path, device: 1)
        for name in ["a.bin", "b.bin"] {
            let url = dir.appendingPathComponent(name)
            try content.write(to: url)
            let a = try FileManager.default.attributesOfItem(atPath: url.path)
            t.addChild(of: FileTree.root, entry: ScanEntry(name: name, isDirectory: false, allocSize: Int64(size), logicalSize: Int64(size),
                                                           fileID: DuplicatesIO.uint64(a[.systemFileNumber]) ?? 0, device: 1))
        }
        t.recomputeAggregates()
        let before = footprint()
        XCTAssertGreaterThan(before, 0)
        let report = DuplicateFinder.find(in: t.nodes, rootPath: t.rootPath,
                                          options: DuplicateOptions(minSize: 1, chunkBytes: 1_048_576))
        let grown = footprint() - before
        XCTAssertEqual(report.groups.first?.members.count, 2)
        XCTAssertGreaterThanOrEqual(report.bytesRead, Int64(2 * size))
        XCTAssertLessThan(grown, 64 * 1_048_576, "the run kept \(grown >> 20) MB after reading \(report.bytesRead >> 20) MB")
    }
}
#endif
