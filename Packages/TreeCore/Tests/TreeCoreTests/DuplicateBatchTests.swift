import XCTest
@testable import TreeCore

final class DuplicateBatchTests: XCTestCase {
    private func member(_ node: NodeID) -> DuplicateMember {
        DuplicateMember(path: "/file\(node)", node: node, aliases: [], allocBytes: 10,
                        sharesStorage: false)
    }

    private var group: DuplicateGroup {
        DuplicateGroup(logicalSize: 10, members: [member(1), member(2), member(3)],
                       stage: .bytes, reclaimableAllocLowerBound: 20)
    }

    func testKeeperSkipsMemberThatCannotRemain() {
        XCTAssertEqual(group.keeper { $0.node != 1 }?.node, 2)
    }

    func testEveryMemberPickedIsRefused() {
        XCTAssertNil(group.trashPlan(picked: [1, 2, 3], remains: { _ in true }))
    }

    func testTwoPickedKeepUnpickedMember() {
        let plan = group.trashPlan(picked: [1, 2], remains: { _ in true })
        XCTAssertEqual(plan?.trash.map(\.node), [1, 2])
        XCTAssertEqual(plan?.kept.map(\.node), [3])
    }

    func testUnpickedMemberThatCannotRemainIsRefused() {
        let pair = DuplicateGroup(logicalSize: 10, members: [member(1), member(2)],
                                  stage: .bytes, reclaimableAllocLowerBound: 10)
        XCTAssertNil(pair.trashPlan(picked: [1], remains: { $0.node == 1 }))
    }

    func testNothingPickedReturnsEmptyTrash() {
        let plan = group.trashPlan(picked: [], remains: { _ in true })
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.trash.count, 0)
        XCTAssertEqual(plan?.kept.count, 3)
    }
}
