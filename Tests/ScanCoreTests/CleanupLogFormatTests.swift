import Foundation
import XCTest
@testable import ScanCore

final class CleanupLogFormatTests: XCTestCase {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

    private func trashed(_ path: String, _ seconds: TimeInterval) -> CleanupLogEntry {
        CleanupLogEntry(date: at(seconds), path: path, bytes: 10, source: "suggest", partial: false)
    }

    private func putBack(_ path: String, _ seconds: TimeInterval) -> CleanupLogEntry {
        CleanupLogEntry(date: at(seconds), path: path, bytes: 0, source: "undo", partial: false, restored: true)
    }

    func testLinesWrittenBeforeRestoredExistedStillRead() throws {
        let old = #"{"date":"2026-10-20T10:00:00Z","path":"/u/a","bytes":5,"source":"suggest","partial":false}"#
        let rows = CleanupLogFormat.recent(Data((old + "\n").utf8))
        XCTAssertEqual(rows.map(\.path), ["/u/a"])
        XCTAssertNil(rows.first?.restored)
    }

    func testPutBackItemsAreNotListedUntilTrashedAgain() throws {
        let data = try CleanupLogFormat.encode([
            trashed("/u/a", 1), trashed("/u/b", 2), putBack("/u/a", 3), trashed("/u/c", 4),
            trashed("/u/d", 5), putBack("/u/d", 6), trashed("/u/d", 7),
        ]) + Data("not json\n".utf8)
        XCTAssertEqual(CleanupLogFormat.recent(data).map(\.path), ["/u/d", "/u/c", "/u/b"])
    }

    func testRestoreTakesBackOnlyTheLatestTrashOfThatPath() throws {
        // Two trashes of /u/p (both in the Trash), then ⌘Z on the second: the first stays listed.
        let older = try CleanupLogFormat.encode([trashed("/u/p", 1), trashed("/u/p", 2), putBack("/u/p", 3)])
        XCTAssertEqual(CleanupLogFormat.recent(older).map(\.date), [at(1)])
        // Put back and trashed again within the same second: the new trash is listed.
        let sameSecond = try CleanupLogFormat.encode([trashed("/u/q", 5), putBack("/u/q", 6), trashed("/u/q", 6)])
        XCTAssertEqual(CleanupLogFormat.recent(sameSecond).map(\.path), ["/u/q"])
    }

    func testNewestTwentyFirst() throws {
        let data = try CleanupLogFormat.encode((0..<30).map { trashed("/u/f\($0)", Double($0)) })
        let rows = CleanupLogFormat.recent(data)
        XCTAssertEqual(rows.count, 20)
        XCTAssertEqual(rows.first?.path, "/u/f29")
        XCTAssertEqual(rows.last?.path, "/u/f10")
    }

    func testTrimmedKeepsTheNewestLines() throws {
        let data = try CleanupLogFormat.encode((0..<5).map { trashed("/u/f\($0)", Double($0)) })
        let kept = CleanupLogFormat.trimmed(data, keep: 2)
        XCTAssertEqual(CleanupLogFormat.recent(kept).map(\.path), ["/u/f4", "/u/f3"])
        XCTAssertEqual(kept.last, 0x0a)
        XCTAssertEqual(CleanupLogFormat.trimmed(Data(), keep: 2), Data())
    }
}
