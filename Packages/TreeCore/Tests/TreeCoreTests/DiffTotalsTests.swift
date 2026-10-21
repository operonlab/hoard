import XCTest
@testable import TreeCore

final class DiffTotalsTests: XCTestCase {
    /// The 最近變動 rows list a folder and the items inside it; the totals must count each change once.
    func testNestedRowsAreCountedOnce() {
        let rows: [(path: String, delta: Int64)] = [
            ("/Demo", 234),                       // 64 of it from files too small to list
            ("/Demo/Movies", 126),
            ("/Demo/Movies/Holiday.mov", 126),
            ("/Demo/Downloads", 32),
            ("/Demo/Downloads/installer.dmg", 85),
            ("/Demo/Downloads/dataset.zip", -53),
            ("/Demo/node_modules/new", 12),       // a folder grown by files too small to list
        ]
        let totals = TreeDiff.listedTotals(rows)
        XCTAssertEqual(totals.grown, 126 + 85 + 12 + 64)
        XCTAssertEqual(totals.shrunk, -53)
        XCTAssertEqual(totals.grown + totals.shrunk, 234, "Larger and Smaller must add up to the net change")
    }

    /// A folder's change that no listed row explains still counts, in its own direction.
    func testUnlistedPartOfAFolderCounts() {
        let grewMore = TreeDiff.listedTotals([("/a", 2), ("/a/big", 1)])
        XCTAssertEqual(grewMore.grown, 2)
        XCTAssertEqual(grewMore.shrunk, 0)

        let grewWhileChildShrank = TreeDiff.listedTotals([("/a", 2), ("/a/big", -1)])
        XCTAssertEqual(grewWhileChildShrank.grown, 3)
        XCTAssertEqual(grewWhileChildShrank.shrunk, -1)
    }

    /// An uncertain row stays out of the totals, and so does its part of the folders above it.
    func testUncertainRowsAreLeftOut() {
        let totals = TreeDiff.listedTotals([("/a", 7), ("/a/locked", 5), ("/a/file", 2)], uncertain: ["/a/locked"])
        XCTAssertEqual(totals.grown, 2)
        XCTAssertEqual(totals.shrunk, 0)
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
