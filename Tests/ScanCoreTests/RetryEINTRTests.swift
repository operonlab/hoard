import Darwin
import XCTest
@testable import ScanCore

final class RetryEINTRTests: XCTestCase {
    /// An open interrupted while the system checks app-data access succeeds when tried again.
    func testRetriesOnlyEINTRAndAtMostThreeTimes() {
        var calls = 0
        XCTAssertEqual(retryingEINTR { calls += 1; if calls < 3 { errno = EINTR; return -1 }; return 7 }, 7)
        XCTAssertEqual(calls, 3)

        calls = 0
        XCTAssertEqual(retryingEINTR { calls += 1; errno = EINTR; return -1 }, -1)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(errno, EINTR)

        calls = 0
        XCTAssertEqual(retryingEINTR { calls += 1; errno = EACCES; return -1 }, -1)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(errno, EACCES)
    }

    func testBulkEINTRRestartsListingWithoutDuplicatingEntries() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: path.path, contents: Data(repeating: 0, count: 8))
        defer { try? FileManager.default.removeItem(at: path) }
        let fd = open(path.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var calls = 0
        let listing: (entries: [Int], ok: Bool) = readBulkRestartingOnEINTR(dirfd: fd, bulkCall: {
            calls += 1
            switch calls {
            case 1: return 2
            case 2:
                _ = lseek(fd, 4, SEEK_SET)
                errno = EINTR
                return -1
            case 3:
                XCTAssertEqual(lseek(fd, 0, SEEK_CUR), 0)
                return 3
            default: return 0
            }
        }, appendBatch: { count, out in
            out += count == 2 ? [1, 2] : [1, 2, 3]
            return true
        })
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(listing.entries, [1, 2, 3])
        XCTAssertTrue(listing.ok)
    }
}
