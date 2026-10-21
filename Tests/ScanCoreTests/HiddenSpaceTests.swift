import Darwin
import Foundation
import XCTest
@testable import ScanCore

final class HiddenSpaceTests: XCTestCase {
    private func fixturePath() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoard-hidden-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return realpath(path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? path
    }

    private func volume(_ mount: String, device: String = "/dev/disk3s1", type: String = "apfs",
                        total: Int64 = 200, available: Int64 = 100) -> HiddenSpace.VolumeFacts {
        .init(mountPoint: mount, device: device, fsType: type, total: total, available: available)
    }

    private func probes(_ mount: String) -> HiddenSpace.Probes {
        let root = volume(mount)
        let vm = volume("/System/Volumes/VM", device: "/dev/disk3s4")
        let other = volume("/System/Volumes/Preboot", device: "/dev/disk3s2")
        return .init(volume: { _ in root }, mountedVolumes: { [root, vm, other] },
                     spaceUsed: { $0 == vm.mountPoint ? 4 : ($0 == other.mountPoint ? 10 : nil) },
                     importantAvailable: { _ in 105 },
                     localSnapshots: { _ in ("Snapshots for disk /:\n", 0) },
                     swapTotal: { 4 }, fileAllocated: { _ in .absent })
    }

    private func facts(_ path: String, status: ScanStatus = .complete, scanned: Int64 = 60,
                       unreadable: Int = 0) -> HiddenSpace.ScanFacts {
        .init(rootPath: path, rootStatus: status, countedBytes: scanned, unreadableFolders: unreadable)
    }

    private func report(_ facts: HiddenSpace.ScanFacts, _ probes: HiddenSpace.Probes) -> HiddenSpace.Report {
        let result = HiddenSpace.report(facts, probes: probes)
        assertInvariant(result)
        if result.lines.contains(where: { $0.state == .unknown }) { assertNullKeys(result) }
        return result
    }

    private func line(_ id: String, in report: HiddenSpace.Report, file: StaticString = #filePath,
                      line: UInt = #line) -> HiddenSpace.Line {
        guard let found = report.lines.first(where: { $0.id == id }) else {
            XCTFail("missing \(id)", file: file, line: line)
            return .init(id: id, label: "", bytes: nil, state: .unknown, kind: .part,
                         count: nil, how: "missing")
        }
        return found
    }

    private func assertInvariant(_ report: HiddenSpace.Report, file: StaticString = #filePath,
                                 line: UInt = #line) {
        for item in report.lines {
            XCTAssertEqual(item.bytes == nil, item.state == .unknown, item.id, file: file, line: line)
        }
    }

    private func assertNullKeys(_ report: HiddenSpace.Report, file: StaticString = #filePath,
                                line: UInt = #line) {
        do {
            let data = try JSONEncoder().encode(report)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let lines = try XCTUnwrap(json["lines"] as? [[String: Any]])
            for (item, dict) in zip(report.lines, lines) where item.state == .unknown {
                XCTAssertTrue(dict.keys.contains("bytes"), item.id, file: file, line: line)
                XCTAssertTrue(dict["bytes"] is NSNull, item.id, file: file, line: line)
            }
        } catch { XCTFail("JSON encoding failed: \(error)", file: file, line: line) }
    }

    func testParseHeaderOnly() {
        XCTAssertEqual(HiddenSpace.parseLocalSnapshots("Snapshots for disk /:\n"), [])
    }

    func testParseTwoNames() {
        let first = "com.apple.TimeMachine.2026-10-19-091512.local"
        let second = "com.apple.TimeMachine.2026-10-20-101530.local"
        XCTAssertEqual(HiddenSpace.parseLocalSnapshots("Snapshots for disk /:\n\(first)\n\(second)\n"),
                       [first, second])
    }

    func testParseRejects() {
        XCTAssertNil(HiddenSpace.parseLocalSnapshots(""))
        XCTAssertNil(HiddenSpace.parseLocalSnapshots("tmutil: permission denied\n"))
        XCTAssertNil(HiddenSpace.parseLocalSnapshots("Snapshots for disk /:\nbad name\n"))
        XCTAssertNil(HiddenSpace.parseLocalSnapshots("Snapshots for disk /:\n name \n"))
    }

    func testApfsContainer() {
        XCTAssertEqual(HiddenSpace.apfsContainer(ofDevice: "/dev/disk3s1s1"), "disk3")
        XCTAssertEqual(HiddenSpace.apfsContainer(ofDevice: "/dev/disk3s5"), "disk3")
        XCTAssertEqual(HiddenSpace.apfsContainer(ofDevice: "/dev/disk12s2"), "disk12")
        XCTAssertNil(HiddenSpace.apfsContainer(ofDevice: "map auto_home"))
        XCTAssertNil(HiddenSpace.apfsContainer(ofDevice: "//u@h/share"))
    }

    func testUnreadableFolderCount() throws {
        let tree = FileTree(rootPath: try fixturePath(), device: 1)
        let a = tree.addChild(of: FileTree.root, entry: .init(name: "a", isDirectory: true))
        let b = tree.addChild(of: a, entry: .init(name: "b", isDirectory: true))
        let c = tree.addChild(of: FileTree.root, entry: .init(name: "c", isDirectory: true))
        let removed = tree.addChild(of: FileTree.root, entry: .init(name: "removed", isDirectory: true))
        let hidden = tree.addChild(of: removed, entry: .init(name: "hidden", isDirectory: true))
        tree.markUnavailable(b)
        tree.markListingIncomplete(c)
        tree.markUnavailable(hidden)
        tree.recomputeAggregates()
        tree.removeSubtree(removed)
        XCTAssertEqual(HiddenSpace.unreadableFolderCount(tree), 2)
        XCTAssertEqual(HiddenSpace.ScanFacts(tree: tree).unreadableFolders, 2)
    }

    func testArithmeticAllKnown() throws {
        let path = try fixturePath()
        let result = report(facts(path), probes(path))
        XCTAssertEqual(result.lines.map(\.id), ["capacity", "available", "used", "scanned",
                                               "vm_volume", "other_volumes", "snapshots", "unreadable",
                                               "unexplained", "purgeable", "swap", "sleep_image"])
        XCTAssertTrue(result.coversVolume)
        XCTAssertEqual(line("unexplained", in: result).bytes, 26)
        XCTAssertEqual(line("unexplained", in: result).state, .measured)
        XCTAssertEqual(result.lines.filter { $0.kind == .part }.compactMap(\.bytes).reduce(0, +), 100)
        XCTAssertTrue(line("used", in: result).label.contains("APFS container"))
        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["root_path"] as? String, path)
        XCTAssertEqual(json["mount_point"] as? String, path)
        XCTAssertEqual(json["covers_volume"] as? Bool, true)
    }

    func testSnapshotsPresent() throws {
        let path = try fixturePath()
        var fake = probes(path)
        fake.localSnapshots = { _ in ("Snapshots for disk /:\na\nb\nc\n", 0) }
        let result = report(facts(path), fake)
        XCTAssertEqual(line("snapshots", in: result).count, 3)
        XCTAssertNil(line("snapshots", in: result).bytes)
        XCTAssertEqual(line("snapshots", in: result).state, .unknown)
        XCTAssertEqual(line("unexplained", in: result).state, .estimated)
        XCTAssertTrue(line("unexplained", in: result).how.contains("snapshots (3)"))
    }

    func testUnfinishedScanLeavesUnreadableUnknown() throws {
        let path = try fixturePath()
        let result = report(facts(path, status: .unavailable, scanned: 0, unreadable: 0), probes(path))
        XCTAssertEqual(line("unreadable", in: result).state, .unknown)
        XCTAssertNil(line("unreadable", in: result).bytes)
        XCTAssertNil(line("unreadable", in: result).count)
    }

    func testApfsVolume() {
        XCTAssertEqual(HiddenSpace.apfsVolume(ofDevice: "/dev/disk3s1s1"), "disk3s1")
        XCTAssertEqual(HiddenSpace.apfsVolume(ofDevice: "/dev/disk3s1"), "disk3s1")
        XCTAssertEqual(HiddenSpace.apfsVolume(ofDevice: "/dev/disk12s5"), "disk12s5")
        XCTAssertNil(HiddenSpace.apfsVolume(ofDevice: "map auto_home"))
    }

    func testVolumeMountedTwiceCountsOnce() throws {
        let path = try fixturePath()
        let data = volume(path, device: "/dev/disk3s5")
        let system = volume("/", device: "/dev/disk3s1s1")
        let systemAgain = volume("/System/Volumes/Update/mnt1", device: "/dev/disk3s1")
        let preboot = volume("/System/Volumes/Preboot", device: "/dev/disk3s2")
        let fake = HiddenSpace.Probes(volume: { _ in data }, mountedVolumes: { [data, system, systemAgain, preboot] },
                                      spaceUsed: { $0 == preboot.mountPoint ? 3 : 10 },
                                      importantAvailable: { _ in 105 },
                                      localSnapshots: { _ in ("Snapshots for disk /:\n", 0) },
                                      swapTotal: { 4 }, fileAllocated: { _ in .absent })
        XCTAssertEqual(line("other_volumes", in: report(facts(path), fake)).bytes, 13)
    }

    func testUnreadableKeepsCount() throws {
        let path = try fixturePath()
        let result = report(facts(path, unreadable: 212), probes(path))
        XCTAssertEqual(line("unreadable", in: result).count, 212)
        XCTAssertNil(line("unreadable", in: result).bytes)
        XCTAssertEqual(line("unreadable", in: result).state, .unknown)
        XCTAssertEqual(line("unexplained", in: result).state, .estimated)
        XCTAssertTrue(line("unexplained", in: result).how.contains("unreadable folders (212)"))
    }

    func testSnapshotProbeFailure() throws {
        let path = try fixturePath()
        var fake = probes(path)
        fake.localSnapshots = { _ in ("Snapshots for disk /:\n", 1) }
        let failed = report(facts(path), fake)
        XCTAssertNil(line("snapshots", in: failed).count)
        XCTAssertEqual(line("snapshots", in: failed).state, .unknown)
        fake.localSnapshots = { _ in nil }
        let timedOut = report(facts(path), fake)
        XCTAssertNil(line("snapshots", in: timedOut).count)
        XCTAssertEqual(line("snapshots", in: timedOut).state, .unknown)
    }

    func testPurgeable() throws {
        let path = try fixturePath()
        var fake = probes(path)
        fake.importantAvailable = { _ in nil }
        XCTAssertEqual(line("purgeable", in: report(facts(path), fake)).state, .unknown)
        fake.importantAvailable = { _ in 99 }
        XCTAssertEqual(line("purgeable", in: report(facts(path), fake)).state, .unknown)
        fake.importantAvailable = { _ in 105 }
        let result = report(facts(path), fake)
        XCTAssertEqual(line("purgeable", in: result).bytes, 5)
        XCTAssertEqual(line("purgeable", in: result).state, .estimated)
    }

    func testScannedPartial() throws {
        let path = try fixturePath()
        let result = report(facts(path, status: .partial), probes(path))
        XCTAssertEqual(line("scanned", in: result).bytes, 60)
        XCTAssertEqual(line("scanned", in: result).state, .estimated)
    }

    func testScannedUnavailable() throws {
        let path = try fixturePath()
        let result = report(facts(path, status: .unavailable), probes(path))
        XCTAssertEqual(line("scanned", in: result).state, .unknown)
        XCTAssertEqual(line("unexplained", in: result).state, .unknown)
        XCTAssertTrue(line("unexplained", in: result).how.contains("scan root could not be read"))
    }

    func testNotCoveringVolume() throws {
        let path = try fixturePath()
        let other = try fixturePath()
        let partial = report(facts(path), probes(other))
        XCTAssertFalse(partial.coversVolume)
        XCTAssertEqual(line("unexplained", in: partial).state, .unknown)
        let missing = report(facts(path + "/missing"), probes(path))
        XCTAssertFalse(missing.coversVolume)
        XCTAssertEqual(line("unexplained", in: missing).state, .unknown)
    }

    func testScannedExceedsUsed() throws {
        let path = try fixturePath()
        let result = report(facts(path, scanned: 101), probes(path))
        XCTAssertEqual(line("unexplained", in: result).state, .unknown)
        XCTAssertTrue(line("unexplained", in: result).how.contains("scan counted more than the volume reports"))
    }

    func testStatfsNil() throws {
        let path = try fixturePath()
        var fake = probes(path)
        fake.volume = { _ in nil }
        let result = report(facts(path, unreadable: 2), fake)
        XCTAssertEqual(result.lines.map(\.id), ["capacity", "available", "used", "scanned",
                                               "unreadable", "unexplained", "purgeable"])
        XCTAssertTrue(result.lines.allSatisfy { $0.state == .unknown })
        XCTAssertEqual(line("unreadable", in: result).count, 2)
    }

    func testNonAPFS() throws {
        let path = try fixturePath()
        var fake = probes(path)
        fake.volume = { _ in self.volume(path, type: "msdos") }
        let result = report(facts(path), fake)
        XCTAssertEqual(result.lines.map(\.id), ["capacity", "available", "used", "scanned",
                                               "unreadable", "unexplained", "purgeable"])
        XCTAssertFalse(line("used", in: result).label.contains("APFS container"))
    }

    func testNoVMVolume() throws {
        let path = try fixturePath()
        var fake = probes(path)
        fake.mountedVolumes = { [self.volume(path)] }
        let result = report(facts(path), fake)
        XCTAssertFalse(result.lines.contains { ["vm_volume", "swap", "sleep_image"].contains($0.id) })
    }

    func testSleepImageFailed() throws {
        let path = try fixturePath()
        var fake = probes(path)
        fake.fileAllocated = { _ in .failed(errno: EACCES) }
        let result = report(facts(path), fake)
        XCTAssertEqual(line("sleep_image", in: result).state, .unknown)
        XCTAssertNil(line("sleep_image", in: result).bytes)
    }

    func testLiveInvariants() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOARD_LIVE_PROBES"] == "1")
        let path = try fixturePath()
        let result = report(facts(path), .live)
        let capacity = try XCTUnwrap(line("capacity", in: result).bytes)
        let used = try XCTUnwrap(line("used", in: result).bytes)
        XCTAssertGreaterThanOrEqual(capacity, used)
        XCTAssertGreaterThanOrEqual(used, 0)
    }
}
