import Darwin
import Foundation
import XCTest
@testable import ScanCore

/// The toolbar's 自動更新 button shows the updater at work only while it really is: the folder count it
/// reads rises when a batch starts, counts down, and is back at 0 by the time the batch is reported.
final class LiveUpdaterActivityTests: XCTestCase {
    private func fixture() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HoardActivity-\(UUID().uuidString)")
        for dir in ["a", "b", "c"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let path = try XCTUnwrap(realpath(url.path, nil))
        defer { free(path) }
        let resolved = String(cString: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: resolved) }
        return resolved
    }

    func testFolderCountRisesCountsDownAndEndsAtZero() throws {
        let root = try fixture()
        let scanner = ScanCore.Scanner()
        let tree = try scanner.scan(root: root)
        var atReport: Int?
        let done = expectation(description: "batch applied")
        var updater: LiveUpdater!
        updater = LiveUpdater(tree: tree, scanner: scanner, sinceEventId: nil) { _ in
            atReport = updater.foldersInProgress
            done.fulfill()
        }
        var seen: [Int] = []
        let token = NotificationCenter.default.addObserver(forName: LiveUpdater.activityDidChange, object: updater,
                                                           queue: nil) { _ in seen.append(updater.foldersInProgress) }
        defer { NotificationCenter.default.removeObserver(token) }
        try Data(repeating: 65, count: 10).write(to: URL(fileURLWithPath: root + "/a/new"))
        updater.applyDirectoryEvents([(root + "/a", false), (root + "/b", false), (root + "/c", true)], eventId: 11)
        wait(for: [done], timeout: 10)
        XCTAssertEqual(seen, [3, 2, 1, 0], "one step down per folder done, 0 once the batch is applied")
        XCTAssertEqual(atReport, 0)
        XCTAssertEqual(updater.foldersInProgress, 0)
    }

    /// Stopping drops the batch in flight, so the button must not stay at work.
    func testStoppedUpdaterReportsNothingInProgress() throws {
        let root = try fixture()
        let scanner = ScanCore.Scanner()
        let updater = LiveUpdater(tree: try scanner.scan(root: root), scanner: scanner, sinceEventId: nil) { _ in }
        updater.applyDirectoryEvents([(root + "/a", false)], eventId: 11)
        XCTAssertEqual(updater.foldersInProgress, 1)
        var seen: [Int] = []
        let token = NotificationCenter.default.addObserver(forName: LiveUpdater.activityDidChange, object: updater,
                                                           queue: nil) { _ in seen.append(updater.foldersInProgress) }
        defer { NotificationCenter.default.removeObserver(token) }
        updater.stop()
        XCTAssertEqual(updater.foldersInProgress, 0)
        XCTAssertEqual(seen, [0], "an observer learns that the work stopped")
        updater.stop()
        XCTAssertEqual(seen, [0], "stopping an idle updater says nothing")
    }
}
