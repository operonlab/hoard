import XCTest
@testable import ScanCore

final class OpenRequestTests: XCTestCase {
    func testRoutingAndFirstRoutableItem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HoardOpen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder")
        let app = root.appendingPathComponent("X.app")
        let bundle = root.appendingPathComponent("Thing.bundle")
        let rtfd = root.appendingPathComponent("Doc.rtfd")
        for item in [folder, app, bundle, rtfd] {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        }
        let file = root.appendingPathComponent("file.txt")
        try Data().write(to: file)
        let link = root.appendingPathComponent("Shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)

        XCTAssertEqual(OpenRequest.route(folder), .folder(folder.path))
        XCTAssertEqual(OpenRequest.route(app), .app(app.path))
        XCTAssertEqual(OpenRequest.route(bundle), .folder(bundle.path))
        XCTAssertEqual(OpenRequest.route(rtfd), .folder(rtfd.path))
        XCTAssertEqual(OpenRequest.route(file), .ignored)
        XCTAssertEqual(OpenRequest.route(root.appendingPathComponent("missing")), .ignored)
        XCTAssertEqual(OpenRequest.route(link), .app(link.path), "a link names itself, not the App it points to")
        XCTAssertEqual(OpenRequest.first(of: [file, folder]), .folder(folder.path))
    }

    func testDroppedAppMatchesOnlyItsOwnPath() {
        func app(_ path: String, link: String? = nil) -> AppFootprint {
            let size = SizeReading(bytes: 100, status: .complete)
            return AppFootprint(appPath: path, linkTarget: link, name: "X", bundleID: nil, teamID: nil, isApple: false,
                                appSize: size, appSizedFrom: .walk, data: size, sharedData: size, locations: [], lastUsed: nil)
        }
        let apps = [app("/Applications/Real.app"), app("/Applications/Linked.app", link: "/opt/Elsewhere.app")]
        XCTAssertEqual(OpenRequest.app(at: "/Applications/Real.app", in: apps)?.appPath, "/Applications/Real.app")
        XCTAssertEqual(OpenRequest.app(at: "/System/Volumes/Data/Applications/Real.app/", in: apps)?.appPath,
                       "/Applications/Real.app")
        // A link elsewhere that points to Real.app, or the target of Linked.app, is not that App.
        XCTAssertNil(OpenRequest.app(at: "/Applications/Shortcut.app", in: apps))
        XCTAssertNil(OpenRequest.app(at: "/opt/Elsewhere.app", in: apps))

        let roots = ["/Applications", "/Users/someone/Applications"]
        XCTAssertTrue(OpenRequest.isInAppFolders("/Applications/Utilities/X.app", roots: roots))
        XCTAssertTrue(OpenRequest.isInAppFolders("/System/Volumes/Data/Applications/X.app", roots: roots))
        XCTAssertFalse(OpenRequest.isInAppFolders("/Users/someone/Downloads/X.app", roots: roots))
        XCTAssertFalse(OpenRequest.isInAppFolders("/ApplicationsX/X.app", roots: roots))
    }
}
