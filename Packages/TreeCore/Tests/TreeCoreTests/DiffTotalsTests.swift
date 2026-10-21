import XCTest
@testable import TreeCore

final class DiffTotalsTests: XCTestCase {
    /// The 最近變動 rows list a folder and the items inside it; the totals must count each change once.
    func testNestedRowsAreCountedOnce() {
        let rows: [(path: String, delta: Int64)] = [
            ("/Demo", 234),                       // root: net of everything below
            ("/Demo/Movies", 126),
            ("/Demo/Movies/Holiday.mov", 126),
            ("/Demo/Downloads", 32),
            ("/Demo/Downloads/installer.dmg", 85),
            ("/Demo/Downloads/dataset.zip", -53),
            ("/Demo/node_modules/new", 12),       // a folder grown by files too small to list
        ]
        let totals = TreeDiff.listedTotals(rows)
        XCTAssertEqual(totals.grown, 126 + 85 + 12)
        XCTAssertEqual(totals.shrunk, -53)
    }

    /// A shared name prefix is not a parent: /a/bc is not inside /a/b.
    func testSiblingWithSharedPrefixIsNotAChild() {
        let totals = TreeDiff.listedTotals([("/a/b", 10), ("/a/bc", 5)])
        XCTAssertEqual(totals.grown, 15)
    }

    /// The volume root contains everything below it.
    func testFilesystemRootIsAParent() {
        let totals = TreeDiff.listedTotals([("/", 30), ("/Users/x/file", 30)])
        XCTAssertEqual(totals.grown, 30)
    }
}
