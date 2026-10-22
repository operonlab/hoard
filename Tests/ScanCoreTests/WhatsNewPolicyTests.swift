import XCTest
@testable import ScanCore

final class WhatsNewPolicyTests: XCTestCase {
    func testFreshInstallShowsNothing() {
        XCTAssertEqual(WhatsNewPolicy.versionsToShow(current: "0.6.1", lastSeen: nil,
                                                     hasPriorUse: false, available: ["0.6.1"]), [])
    }

    func testUnrecordedPriorUseShowsCurrentNotes() {
        XCTAssertEqual(WhatsNewPolicy.versionsToShow(current: "0.6.1", lastSeen: nil,
                                                     hasPriorUse: true, available: ["0.6.1"]), ["0.6.1"])
    }

    func testUpdateShowsEveryAvailableVersionInReverseOrder() {
        XCTAssertEqual(WhatsNewPolicy.versionsToShow(current: "0.7.0", lastSeen: "0.6.1",
                                                     hasPriorUse: true, available: ["0.6.1", "0.6.2", "0.7.0"]),
                       ["0.7.0", "0.6.2"])
    }

    func testSameVersionAndDowngradeShowNothing() {
        XCTAssertEqual(WhatsNewPolicy.versionsToShow(current: "0.6.1", lastSeen: "0.6.1",
                                                     hasPriorUse: true, available: ["0.6.1"]), [])
        XCTAssertEqual(WhatsNewPolicy.versionsToShow(current: "0.6.0", lastSeen: "0.6.1",
                                                     hasPriorUse: true, available: ["0.6.0"]), [])
    }

    func testNumericOrderingAndUnavailableVersion() {
        XCTAssertEqual(WhatsNewPolicy.compare("0.10.0", "0.9.2"), .orderedDescending)
        XCTAssertEqual(WhatsNewPolicy.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(WhatsNewPolicy.versionsToShow(current: "0.10.0", lastSeen: "0.9.2",
                                                     hasPriorUse: true, available: ["0.9.2"]), [])
    }
}
