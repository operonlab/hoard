import Foundation
import XCTest
@testable import ScanCore

final class SpotlightTests: XCTestCase {
    func testMissingFileHasUnknownLastUsedDate() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoard-spotlight-\(UUID().uuidString)").path
        XCTAssertNil(Spotlight.lastUsedDate(path: missing))
    }
}
