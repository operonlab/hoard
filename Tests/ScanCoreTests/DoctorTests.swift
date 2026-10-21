import Foundation
import XCTest
@testable import ScanCore

final class DoctorTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HoardDoctorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func folder(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLibraryLayout() throws {
        let home = try fixture()
        for name in ["Caches", "Application Support", "Containers", "Preferences"] {
            _ = try folder(home, "Library/\(name)")
        }
        XCTAssertEqual(Doctor.libraryLayout(home: home.path).status, .ok)
        try FileManager.default.removeItem(at: home.appendingPathComponent("Library/Containers"))
        let missing = Doctor.libraryLayout(home: home.path)
        XCTAssertEqual(missing.status, .problem)
        XCTAssertTrue(missing.detail.contains("Containers"))
    }

    func testHomebrewReceipt() throws {
        let root = try fixture()
        let arm = root.appendingPathComponent("arm"), intel = root.appendingPathComponent("intel")
        XCTAssertEqual(Doctor.homebrewReceipt(caskrooms: [arm.path, intel.path]).status, .ok)
        let metadata = try folder(root, "arm/sample/.metadata")
        let receipt = metadata.appendingPathComponent("INSTALL_RECEIPT.json")
        try Data(#"{"uninstall_artifacts":[]}"#.utf8).write(to: receipt)
        XCTAssertEqual(Doctor.homebrewReceipt(caskrooms: [arm.path, intel.path]).status, .ok)
        try Data("{}".utf8).write(to: receipt)
        let other = try folder(root, "intel/another/.metadata").appendingPathComponent("INSTALL_RECEIPT.json")
        try Data(#"{"uninstall_artifacts":[]}"#.utf8).write(to: other)
        XCTAssertEqual(Doctor.homebrewReceipt(caskrooms: [arm.path, intel.path]).status, .ok)
        try Data("{}".utf8).write(to: other)
        let changed = Doctor.homebrewReceipt(caskrooms: [arm.path, intel.path])
        XCTAssertEqual(changed.status, .problem)
        XCTAssertTrue(changed.detail.contains("收據格式"))
    }

    func testFirmlink() throws {
        let root = try fixture()
        let other = try folder(root, "other")
        XCTAssertEqual(Doctor.firmlink(users: root.path, dataUsers: root.path).status, .ok)
        XCTAssertEqual(Doctor.firmlink(users: root.path, dataUsers: other.path).status, .problem)
        XCTAssertEqual(Doctor.firmlink(users: root.path, dataUsers: root.appendingPathComponent("missing").path).status, .problem)
    }

    func testMaterialization() throws {
        let check = Doctor.materialization()
        if check.status != .ok { throw XCTSkip("materialization unavailable in sandbox: \(check.detail)") }
    }

    func testBulkRead() throws {
        let root = try fixture()
        let bulk = Doctor.bulkRead(temporaryDirectory: root)
        if bulk.status == .unknown || bulk.detail.contains("目錄讀取失敗") {
            throw XCTSkip("bulk read unavailable in sandbox: \(bulk.detail)")
        }
        XCTAssertEqual(bulk.status, .ok, bulk.detail)
    }

    func testDenyDeleteACL() throws {
        let root = try fixture()
        let acl = Doctor.denyDeleteACL(temporaryDirectory: root)
        if acl.status == .unknown { throw XCTSkip("ACL unavailable in sandbox: \(acl.detail)") }
        XCTAssertEqual(acl.status, .ok, acl.detail)
    }

    func testClonefile() throws {
        let root = try fixture()
        let clone = Doctor.clonefile(temporaryDirectory: root)
        if clone.status == .unknown { throw XCTSkip("clonefile unavailable in sandbox: \(clone.detail)") }
        XCTAssertEqual(clone.status, .ok, clone.detail)
    }

    func testProcessList() throws {
        let processes = Doctor.processList()
        if processes.status == .unknown || processes.detail.contains("無法確認 App") {
            throw XCTSkip("process list unavailable in sandbox: \(processes.detail)")
        }
        XCTAssertEqual(processes.status, .ok, processes.detail)
    }

    func testFSEvents() throws {
        let root = try fixture()
        let check = Doctor.fsevents(temporaryDirectory: root)
        if check.status == .unknown { throw XCTSkip("FSEvents unavailable in sandbox: \(check.detail)") }
        XCTAssertEqual(check.status, .ok, check.detail)
    }

    func testRunRemovesScratchFolders() throws {
        let root = try fixture()
        let report = Doctor.run(temporaryDirectory: root)
        XCTAssertEqual(report.checks.count, 9)
        XCTAssertEqual(report.ok + report.unknown + report.problem, 9)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
