import Foundation
import XCTest
@testable import ScanCore

final class InstalledAppsTests: XCTestCase {
    func testInjectedApplicationsAndAnUnreadableInfoCountsByName() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Applications")
        let app = root.appendingPathComponent("Nested/Example App.app")
        let info = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "Com.Example.App",
                                                                     "CFBundleName": "Example App"], format: .xml, options: 0)
        try data.write(to: info)
        let found = InstalledApps.current(roots: [root], launchAgentRoots: [], processPaths: [])
        XCTAssertEqual(found?.bundleIDs, ["com.example.app"])
        XCTAssertEqual(found?.names, ["exampleapp"])

        // One app that cannot be read must not turn the whole listing off: it counts by its file name.
        try Data("not a plist".utf8).write(to: info)
        let partial = try XCTUnwrap(InstalledApps.current(roots: [root], launchAgentRoots: [], processPaths: []))
        XCTAssertEqual(partial.bundleIDs, [])
        XCTAssertEqual(partial.names, ["exampleapp"])
        XCTAssertTrue(partial.source.hasSuffix("1 item could not be read"), partial.source)

        // A root that is there but cannot be listed still fails closed.
        let file = base.appendingPathComponent("not-a-folder")
        try Data().write(to: file)
        XCTAssertNil(InstalledApps.current(roots: [file], launchAgentRoots: [], processPaths: []))
    }

    /// An iPhone or iPad app installed on Apple silicon is a wrapper with no Contents/Info.plist.
    func testWrappedIOSAppIsReadFromItsInnerBundle() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let inner = base.appendingPathComponent("Applications/Game.app/Wrapper/Game.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.studio.game"], format: .xml, options: 0)
            .write(to: inner.appendingPathComponent("Info.plist"))
        let found = InstalledApps.current(roots: [base.appendingPathComponent("Applications")], launchAgentRoots: [], processPaths: [])
        XCTAssertEqual(found?.bundleIDs, ["com.studio.game"])
        XCTAssertEqual(found?.source.contains("could not be read"), false)
    }

    /// /System/Library/CoreServices/liquiddetectiond.app is a flat bundle with no Info.plist at all.
    /// Nothing in it went unread, so it must not switch the leftovers rule to its cautious mode.
    func testBundleWithNoInfoPlistIsReadNotUnreadable() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Applications")
        let flat = root.appendingPathComponent("helperd.app")
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        try Data().write(to: flat.appendingPathComponent("helperd"))
        let found = try XCTUnwrap(InstalledApps.current(roots: [root], launchAgentRoots: [], processPaths: []))
        XCTAssertEqual(found.names, ["helperd"])
        XCTAssertEqual(found.unreadableItems, 0, found.source)

        // A bundle that is there but cannot be opened still counts as unread.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Gone.app"),
                                                   withDestinationURL: base.appendingPathComponent("missing.app"))
        let partial = try XCTUnwrap(InstalledApps.current(roots: [root], launchAgentRoots: [], processPaths: []))
        XCTAssertEqual(partial.unreadableItems, 1, partial.source)
    }

    func testUnreadableContentsDoesNotCountAsFlatBundle() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Applications")
        let contents = root.appendingPathComponent("Foo.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: contents.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: contents.path) }
        let found = try XCTUnwrap(InstalledApps.current(roots: [root], launchAgentRoots: [], processPaths: []))
        XCTAssertEqual(found.unreadableItems, 1)
    }

    /// A dangling link names nothing. Neither listing should call it unreadable.
    func testLinksAreNotUnreadable() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Applications")
        let target = base.appendingPathComponent("Real.bundle/Contents")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tools"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Glyphs.bundle"),
                                                   withDestinationURL: base.appendingPathComponent("Real.bundle"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Tools/gone"),
                                                   withDestinationURL: base.appendingPathComponent("missing"))
        let found = try XCTUnwrap(InstalledApps.current(roots: [root], launchAgentRoots: [], processPaths: []))
        XCTAssertEqual(found.unreadableItems, 0, found.source)
        XCTAssertEqual(InstalledAppGroups(isCancelled: { false }, roots: [root]).contains("group.com.vendor.shared"), false)
    }

    func testFolderLinkFindsAppAndCycleEnds() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Applications")
        let real = base.appendingPathComponent("RealTools")
        let info = real.appendingPathComponent("Foo.app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.vendor.foo"],
                                           format: .xml, options: 0).write(to: info)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Tools"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("Back"), withDestinationURL: root)
        let found = try XCTUnwrap(InstalledApps.current(roots: [root], launchAgentRoots: [], processPaths: []))
        XCTAssertTrue(found.bundleIDs.contains("com.vendor.foo"))
        XCTAssertEqual(found.unreadableItems, 0)
    }

    /// An unsigned app has a readable, empty signature (see `AppFootprintTests`), so it claims no group.
    /// A signature that cannot be read makes every answer unknown.
    func testFolderLinkedAppSignatureIsRead() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Applications")
        let real = base.appendingPathComponent("RealTools")
        let info = real.appendingPathComponent("Foo.app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.vendor.foo"],
                                           format: .xml, options: 0).write(to: info)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Tools"), withDestinationURL: real)
        XCTAssertEqual(InstalledAppGroups(isCancelled: { false }, roots: [root]).contains("group.com.vendor.shared"), false)
        var asked: [String] = []
        let claiming = InstalledAppGroups(isCancelled: { false }, roots: [root]) { path in
            asked.append(path)
            return AppSigning(teamID: "TEAM", appGroups: ["group.com.vendor.shared"])
        }
        XCTAssertEqual(claiming.contains("group.com.vendor.shared"), true)
        XCTAssertEqual(asked.map { URL(fileURLWithPath: $0).lastPathComponent }, ["Foo.app"])
        let unreadable = InstalledAppGroups(isCancelled: { false }, roots: [root]) { _ in nil }
        XCTAssertNil(unreadable.contains("group.com.vendor.shared"))
    }

    func testHomeFolderLinkIsSkippedWithoutUnreadableItem() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Home"),
                                                   withDestinationURL: URL(fileURLWithPath: NSHomeDirectory()))
        let found = try XCTUnwrap(InstalledApps.current(roots: [root], launchAgentRoots: [], processPaths: []))
        XCTAssertEqual(found.unreadableItems, 0, found.source)
        XCTAssertEqual(InstalledAppGroups(isCancelled: { false }, roots: [root]).contains("group.com.vendor.shared"), false)

        // With a home that holds an app, the link to it is still not walked: that app stays unseen.
        let fakeHome = base.appendingPathComponent("home")
        let info = fakeHome.appendingPathComponent("Tools/Fake.app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.home.fake"], format: .xml, options: 0)
            .write(to: info)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("FakeHome"), withDestinationURL: fakeHome)
        let skipped = try XCTUnwrap(InstalledApps.current(roots: [root], launchAgentRoots: [], processPaths: [], home: fakeHome.path))
        XCTAssertFalse(skipped.bundleIDs.contains("com.home.fake"))
        // The same folder is walked when it is not the home folder.
        let walked = try XCTUnwrap(InstalledApps.current(roots: [root], launchAgentRoots: [], processPaths: [], home: base.path))
        XCTAssertTrue(walked.bundleIDs.contains("com.home.fake"))
    }

    func testWrappedAppSignatureIsReadFromInnerApp() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Applications")
        let inner = root.appendingPathComponent("Foo.app/Wrapper/Inner.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.vendor.inner"],
                                           format: .xml, options: 0).write(to: inner.appendingPathComponent("Info.plist"))
        XCTAssertEqual(InstalledAppGroups(isCancelled: { false }, roots: [root]).contains("group.com.vendor.shared"), false)
        var asked: [String] = []
        let recording = InstalledAppGroups(isCancelled: { false }, roots: [root]) { path in
            asked.append(path)
            return nil
        }
        XCTAssertNil(recording.contains("group.com.vendor.shared"))
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked.first?.hasSuffix("/Foo.app/Wrapper/Inner.app") == true, "\(asked)")
        // An .app folder with neither Contents nor Wrapper is not an app: nothing is read, nothing is unknown.
        let flatRoot = base.appendingPathComponent("FlatApplications")
        try FileManager.default.createDirectory(at: flatRoot.appendingPathComponent("Helper.app"), withIntermediateDirectories: true)
        var flatAsked = 0
        let flat = InstalledAppGroups(isCancelled: { false }, roots: [flatRoot]) { _ in flatAsked += 1; return nil }
        XCTAssertEqual(flat.contains("group.com.vendor.shared"), false)
        XCTAssertEqual(flatAsked, 0)
    }

    func testInjectedRunningAppAndLaunchAgent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let app = base.appendingPathComponent("Running.app")
        let info = app.appendingPathComponent("Contents/Info.plist")
        let agents = base.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.running.app"], format: .xml, options: 0)
            .write(to: info)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.helper.agent"], format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("helper.plist"))
        let found = InstalledApps.current(roots: [], launchAgentRoots: [agents],
                                          processPaths: [app.appendingPathComponent("Contents/MacOS/runner").path])
        XCTAssertEqual(found?.bundleIDs, ["com.running.app", "com.helper.agent"])
        XCTAssertNil(InstalledApps.current(roots: [], launchAgentRoots: [agents], processPaths: [], isCancelled: { true }))
    }

    /// Command-line tools keep data in Application Support too (`ccusage`): every entry of a tool
    /// folder counts as an installed name.
    func testCommandLineToolsCountAsInstalledNames() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let bin = base.appendingPathComponent("bin"), cellar = base.appendingPathComponent("Cellar")
        try FileManager.default.createDirectory(at: cellar.appendingPathComponent("yt-dlp/2026.1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: bin.appendingPathComponent("ccusage"))
        let found = InstalledApps.current(roots: [], launchAgentRoots: [], processPaths: [],
                                          toolRoots: [bin, cellar, base.appendingPathComponent("missing")])
        XCTAssertEqual(found?.names, ["ccusage", "ytdlp"])
    }

    /// An updater disabled by replacing its plist with an empty dictionary names nothing: skip it.
    /// A plist that cannot be parsed is skipped and counted, not a reason to list nothing.
    func testLaunchAgentWithoutLabelOrUnparseableIsSkipped() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let agents = base.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("com.vendor.updater.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.helper.agent"], format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("helper.plist"))
        XCTAssertEqual(InstalledApps.current(roots: [], launchAgentRoots: [agents], processPaths: [])?.bundleIDs, ["com.helper.agent"])

        try Data("not a plist".utf8).write(to: agents.appendingPathComponent("broken.plist"))
        let found = try XCTUnwrap(InstalledApps.current(roots: [], launchAgentRoots: [agents], processPaths: []))
        XCTAssertEqual(found.bundleIDs, ["com.helper.agent"])
        XCTAssertTrue(found.source.hasSuffix("1 item could not be read"), found.source)
    }
}
