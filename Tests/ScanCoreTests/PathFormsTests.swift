import XCTest
@testable import ScanCore

final class PathFormsTests: XCTestCase {
    func testSystemPathOnlyRewritesDataVolumePrefix() {
        XCTAssertEqual(PathForms.systemPath("/System/Volumes/Data"), "/")
        XCTAssertEqual(PathForms.systemPath("/System/Volumes/Data/Users/x"), "/Users/x")
        XCTAssertEqual(PathForms.systemPath("/Users/x"), "/Users/x")
        XCTAssertEqual(PathForms.systemPath("/System/Volumes/Database"), "/System/Volumes/Database")
    }
}
