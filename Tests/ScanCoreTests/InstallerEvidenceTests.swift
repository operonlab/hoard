import Darwin
import Foundation
import XCTest
@testable import ScanCore

final class InstallerEvidenceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HoardInstaller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writeOrigins(_ origins: [String], to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: origins, format: .binary, options: 0)
        let result = data.withUnsafeBytes { bytes in
            path.withCString { setxattr($0, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        }
        XCTAssertEqual(result, 0, "setxattr errno \(errno)")
    }

    func testWhereFromsReturnsFirstHTTPOriginAndIgnoresOtherSchemes() throws {
        let file = root.appendingPathComponent("installer.pkg")
        try Data("local installer fixture".utf8).write(to: file)
        try writeOrigins(["file:///tmp/other.pkg", "https://example.com/file.pkg?token=secret", "http://later.example/file"], to: file.path)
        XCTAssertEqual(InstallerEvidence.downloadOrigin(path: file.path), "https://example.com/file.pkg?token=secret")
        try writeOrigins(["file:///tmp/other.pkg", "ftp://example.com/file.pkg"], to: file.path)
        XCTAssertNil(InstallerEvidence.downloadOrigin(path: file.path))
    }

    private func zipped(_ name: String, file: String) throws -> URL {
        let input = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: input)
        let archive = root.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", archive.lastPathComponent, file]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    func testZipCentralDirectoryFindsInstallerWithoutDecompression() throws {
        let app = try zipped("app.zip", file: "Foo.app/Contents/Info.plist")
        let notes = try zipped("notes.zip", file: "notes.txt")
        XCTAssertEqual(InstallerEvidence.archiveHoldsInstaller(path: app.path), true)
        XCTAssertEqual(InstallerEvidence.archiveHoldsInstaller(path: notes.path), false)
        var commented = try Data(contentsOf: app)
        let commentStart = commented.count - 22
        commented[(commentStart + 20)..<(commentStart + 22)] = Data([0xff, 0xff])
        commented.append(contentsOf: repeatElement(UInt8(0x41), count: 65_535))
        let commentedPath = root.appendingPathComponent("max-comment.zip")
        try commented.write(to: commentedPath)
        XCTAssertEqual(InstallerEvidence.archiveHoldsInstaller(path: commentedPath.path), true)
        let truncated = root.appendingPathComponent("broken.zip")
        try Data([0x50, 0x4b, 0x03]).write(to: truncated)
        XCTAssertNil(InstallerEvidence.archiveHoldsInstaller(path: truncated.path))
        var zip64 = try Data(contentsOf: app)
        let eocd = zip64.count - 22
        XCTAssertEqual(Array(zip64[eocd..<(eocd + 4)]), [0x50, 0x4b, 0x05, 0x06])
        zip64[(eocd + 10)..<(eocd + 12)] = Data([0xff, 0xff])
        let zip64Path = root.appendingPathComponent("zip64.zip")
        try zip64.write(to: zip64Path)
        XCTAssertNil(InstallerEvidence.archiveHoldsInstaller(path: zip64Path.path))
    }

    func testZeroBlockFileIsNotInspected() throws {
        let empty = root.appendingPathComponent("sparse.pkg")
        XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: Data()))
        try writeOrigins(["https://example.com/sparse.pkg"], to: empty.path)
        var info = stat()
        XCTAssertEqual(lstat(empty.path, &info), 0)
        XCTAssertEqual(info.st_blocks, 0, "fixture must have no local data blocks")
        XCTAssertNil(InstallerEvidence.downloadOrigin(path: empty.path))
        XCTAssertNil(InstallerEvidence.archiveHoldsInstaller(path: empty.path))
    }
}
