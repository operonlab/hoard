import Foundation
import XCTest
@testable import ScanCore

final class UninstallTests: XCTestCase {
    private var root: URL!
    private var home: String { root.appendingPathComponent("home").path }
    private var appPath: String { root.appendingPathComponent("Foo.app").path }
    private let id = "com.example.foo"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/UninstallTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: appPath + "/Contents/MacOS", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appPath)
        try FileManager.default.removeItem(at: root)
    }

    func testAppMovePermissionInPlan() throws {
        let normal = plan(app())
        XCTAssertNil(normal.refusal)
        XCTAssertFalse(normal.appNeedsAdmin)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: appPath)
        let restricted = plan(app())
        XCTAssertNil(restricted.refusal)
        XCTAssertTrue(restricted.appNeedsAdmin)
        XCTAssertEqual(restricted.items, normal.items)
        XCTAssertEqual(restricted.kept, normal.kept)
    }

    private func app(bundle: String? = "com.example.foo", apple: Bool = false, link: String? = nil,
                     locations: [AppDataLocation] = []) -> AppFootprint {
        let size = SizeReading(bytes: 100, status: .complete)
        return AppFootprint(appPath: appPath, linkTarget: link, name: "Foo", bundleID: bundle, teamID: nil,
                            isApple: apple, appSize: size, appSizedFrom: .walk, data: size, sharedData: size,
                            locations: locations, lastUsed: nil)
    }

    private func location(_ kind: AppDataKind, shared: [String] = [], symlink: Bool = false,
                          path: String? = nil) throws -> AppDataLocation {
        let path = path ?? home + "/Library/" + kind.rawValue + "/" + id
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if symlink { try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: appPath) }
        else { FileManager.default.createFile(atPath: path, contents: Data([1])) }
        return AppDataLocation(path: path, kind: kind, matchedBy: .bundleID, matchedID: id,
                               size: SizeReading(bytes: 10, status: .complete), sizedFrom: .listing,
                               isSymlink: symlink, sharedWith: shared)
    }

    private func plan(_ app: AppFootprint, running: [String]? = [], other: [String] = [],
                      caskrooms: [String] = [], system: [String] = [], appRoots: [String]? = nil) -> UninstallPlan {
        UninstallPlanner.plan(for: app, in: .init(apps: [app], unreadable: []), runningPaths: running,
                              otherInstalls: other, appRoots: appRoots ?? [root.path],
                              launchAgentRoots: [home + "/Library/LaunchAgents"],
                              systemAgentRoots: system, caskrooms: caskrooms, home: home)
    }

    private func agent(_ name: String, root: String? = nil, label: String, program: String? = nil) throws -> String {
        let folder = root ?? home + "/Library/LaunchAgents"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + name + ".plist"
        var plist: [String: Any] = ["Label": label]
        if let program { plist["Program"] = program }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testRefusals() throws {
        XCTAssertNotNil(plan(app(bundle: nil)).refusal)
        XCTAssertNotNil(plan(app(bundle: "com.apple.Finder", apple: true)).refusal)
        XCTAssertNil(plan(app(bundle: "com.apple.dt.Xcode", apple: true)).refusal)
        XCTAssertEqual(plan(app(bundle: "com.eset.foo")).refusal, "請用它自己的解除安裝程式移除。")
        XCTAssertNotNil(plan(app(link: "/Applications/Foo.app")).refusal)
        XCTAssertNotNil(plan(app(), running: nil).refusal)
        XCTAssertNotNil(plan(app(), running: [appPath + "/Contents/MacOS/Foo"]).refusal)
        XCTAssertTrue(plan(app(), running: nil).items.isEmpty)
        var systemXcode = app(bundle: "com.apple.dt.Xcode", apple: true)
        systemXcode.appPath = "/System/Applications/Xcode.app"
        XCTAssertFalse(UninstallPlanner.isRemovableApple(systemXcode))
        XCTAssertTrue(UninstallPlanner.isRemovableApple(app()))
    }

    func testRunningPathForms() {
        let installed = "/Applications/Foo.app"
        XCTAssertTrue(UninstallPlanner.isRunning(appPath: installed,
            runningPaths: ["/System/Volumes/Data" + installed + "/Contents/MacOS/Foo"]))
        XCTAssertTrue(UninstallPlanner.isRunning(appPath: installed,
            runningPaths: ["/private/var/folders/x/T/AppTranslocation/UUID/d/Foo.app/Contents/MacOS/Foo"]))
        XCTAssertFalse(UninstallPlanner.isRunning(appPath: installed,
            runningPaths: ["/Applications/Other.app/Contents/MacOS/Other"]))
    }

    func testAppRootRealpathContainment() throws {
        XCTAssertNil(plan(app(), appRoots: [root.path]).refusal)
        let allowed = root.appendingPathComponent("allowed")
        let outside = root.appendingPathComponent("outside-bundles")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("Foo.app/Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: allowed.appendingPathComponent("Applications"), withDestinationURL: outside)
        var linked = app()
        linked.appPath = allowed.appendingPathComponent("Applications/Foo.app").path
        XCTAssertEqual(plan(linked, appRoots: [allowed.path]).refusal,
                       "這個 App 不在「應用程式」資料夾裡，請到它實際的位置移除。")
    }

    func testSystemExtensionRefusals() throws {
        let systemExtension = appPath + "/Contents/Library/SystemExtensions/x.systemextension"
        try FileManager.default.createDirectory(atPath: systemExtension, withIntermediateDirectories: true)
        XCTAssertEqual(plan(app()).refusal, UninstallPlanner.systemExtensionRefusal)
        // A cask with an extension goes to brew, which runs the vendor's removal.
        let metadata = root.appendingPathComponent("Caskroom/foo/.metadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data(#"{"uninstall_artifacts":[{"app":["Foo.app"]}]}"#.utf8).write(to: metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
        XCTAssertTrue(plan(app(), caskrooms: [root.appendingPathComponent("Caskroom").path]).refusal?.contains("--cask foo") == true)
        try FileManager.default.removeItem(atPath: systemExtension)
        let kext = appPath + "/Contents/Library/Extensions/x.kext"
        try FileManager.default.createDirectory(atPath: kext, withIntermediateDirectories: true)
        XCTAssertEqual(plan(app()).refusal, UninstallPlanner.systemExtensionRefusal)
    }

    func testCaskReceiptRefusal() throws {
        let metadata = root.appendingPathComponent("Caskroom/foo/.metadata")
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("1/hash/Casks"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: metadata.appendingPathComponent("1/hash/Casks/foo.json"))
        try Data(#"{"uninstall_artifacts":[{"app":["Foo.app"]},{"zap":[{"trash":["~/Library/Caches/x"]}]}]}"#.utf8)
            .write(to: metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
        XCTAssertTrue(plan(app(), caskrooms: [root.appendingPathComponent("Caskroom").path]).refusal?.contains("--cask foo") == true)
    }

    func testCaskArtifactMatching() throws {
        func json(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8)) }
        func installs(_ text: String, path: String = "/Applications/Foo.app", home: String = "/Users/x") throws -> Bool {
            UninstallPlanner.caskInstalls(try json(text), appName: "Foo.app", appPath: path, home: home, bundleID: id)
        }
        XCTAssertTrue(try installs(#"[{"app":["Foo.app"]}]"#))
        XCTAssertTrue(try installs(#"[{"app":["Foo 2.app",{"target":"Foo.app"}]}]"#))
        XCTAssertFalse(try installs(#"[{"app":["Foo.app",{"target":"Bar.app"}]}]"#))
        XCTAssertTrue(try installs(#"[{"app":[["Foo 2.app",{"target":"Foo.app"}]]}]"#))
        XCTAssertTrue(try installs(#"[{"pkg":["Foo.pkg"]},{"uninstall":[{"pkgutil":"com.vendor.pkg","delete":["/Applications/Foo.app"]}]}]"#))
        XCTAssertTrue(try installs(#"[{"pkg":["Foo.pkg"]},{"uninstall":[{"pkgutil":"com.vendor.pkg","delete":"~/Applications/Foo.app"}]}]"#,
                                   path: "/Users/x/Applications/Foo.app"))
        XCTAssertTrue(try installs(#"[{"pkg":["Foo.pkg"]},{"uninstall":[{"pkgutil":"com.example.foo"}]}]"#))
        XCTAssertTrue(try installs(#"[{"pkg":["Foo.pkg"]},{"uninstall":[{"quit":["com.example.foo"],"pkgutil":"com.example.foo.pkg"}]}]"#))
        XCTAssertFalse(try installs(#"[{"pkg":["Driver.pkg"]},{"uninstall":[{"quit":"com.example.other","pkgutil":"com.example.driver"}]}]"#))
        XCTAssertFalse(try installs(#"[{"app":["Helper.app"]},{"uninstall":[{"quit":"com.example.foo"}]}]"#))
    }

    func testCaskRubyRefusal() throws {
        let cask = root.appendingPathComponent("Caskroom/foo-bar/.metadata/2/hash/Casks")
        try FileManager.default.createDirectory(at: cask, withIntermediateDirectories: true)
        try Data("cask \"foo-bar\" do\n  app \"Foo.app\"\nend\n".utf8).write(to: cask.appendingPathComponent("foo-bar.rb"))
        XCTAssertTrue(plan(app(), caskrooms: [root.appendingPathComponent("Caskroom").path]).refusal?.contains("--cask foo-bar") == true)
        try Data("cask \"foo-bar\" do\n  app \"FooPro.app\"\nend\n".utf8).write(to: cask.appendingPathComponent("foo-bar.rb"))
        XCTAssertNil(plan(app(), caskrooms: [root.appendingPathComponent("Caskroom").path]).refusal)
        try Data("cask \"foo-bar\" do\n  app \"Sub/Foo.app\"\nend\n".utf8).write(to: cask.appendingPathComponent("foo-bar.rb"))
        XCTAssertTrue(plan(app(), caskrooms: [root.appendingPathComponent("Caskroom").path]).refusal?.contains("--cask foo-bar") == true)
        try Data("cask \"foo-bar\" do\n  app \"Foo 2.app\", target: \"Foo.app\"\nend\n".utf8).write(to: cask.appendingPathComponent("foo-bar.rb"))
        XCTAssertTrue(plan(app(), caskrooms: [root.appendingPathComponent("Caskroom").path]).refusal?.contains("--cask foo-bar") == true)
    }

    func testCaskJSONRefusal() throws {
        let cask = root.appendingPathComponent("Caskroom/foo/.metadata/1/hash/Casks")
        try FileManager.default.createDirectory(at: cask, withIntermediateDirectories: true)
        try Data(#"{"artifacts":[{"app":["Foo.app"]}]}"#.utf8).write(to: cask.appendingPathComponent("foo.json"))
        XCTAssertTrue(plan(app(), caskrooms: [root.appendingPathComponent("Caskroom").path]).refusal?.contains("brew uninstall --cask foo") == true)
    }

    func testLocationSelectionAndKept() throws {
        var locations = try AppDataKind.allCases.map { try location($0) }
        let shared = try location(.caches, shared: ["Other.app"], path: home + "/Library/Caches/shared")
        let linked = try location(.logs, symlink: true, path: home + "/Library/Logs/link")
        let outside = try location(.caches, path: root.appendingPathComponent("outside").path)
        locations += [shared, linked, outside]
        let result = plan(app(locations: locations))
        XCTAssertEqual(result.items.filter { $0.role == "data" }.count, AppDataKind.allCases.count - 1)
        let group = try XCTUnwrap(locations.first { $0.kind == .groupContainers })
        XCTAssertTrue(result.kept.contains { $0.path == group.path && $0.why == "可能和其他 App 共用（Group Container）" })
        XCTAssertFalse(result.items.contains { $0.path == group.path })
        XCTAssertEqual(Set(result.items.filter { $0.role == "data" && $0.selectedByDefault }.compactMap(\.kind)),
                       Set([.caches, .logs, .savedState, .httpStorages, .webKit]))
        XCTAssertTrue(result.kept.contains { $0.path == shared.path && $0.why.contains("Other.app") })
        XCTAssertTrue(result.kept.contains { $0.path == linked.path && $0.why == "是連結" })
        XCTAssertFalse(result.items.contains { $0.path == outside.path })
        let other = plan(app(locations: locations), other: ["/Applications/Other.app"])
        XCTAssertEqual(other.items.map(\.role), ["app"])
        XCTAssertTrue(other.kept.contains { $0.why.contains("另一份") })
    }

    func testAgentsAndTotals() throws {
        let byLabel = try agent("label", label: id + ".helper")
        let byProgram = try agent("program", label: "unrelated", program: appPath + "/Contents/MacOS/helper")
        let otherBundle = try agent("other-bundle", label: id + ".helper", program: "/Applications/Other.app/Contents/MacOS/x")
        _ = try agent("other", label: "unrelated")
        _ = try agent("apple", label: "com.apple.helper", program: appPath + "/Contents/MacOS/helper")
        let systemRoot = root.appendingPathComponent("systemAgents").path
        let system = try agent("system", root: systemRoot, label: id)
        let result = plan(app(), system: [systemRoot])
        XCTAssertEqual(Set(result.items.filter { $0.role == "launchAgent" }.map(\.path)), Set([byLabel, byProgram]))
        XCTAssertFalse(result.items.contains { $0.path == otherBundle })
        XCTAssertTrue(result.kept.contains { $0.path == system && $0.why.contains("管理員") })
        let total = result.total(selected: Set(result.items.filter(\.selectedByDefault).map(\.path)))
        XCTAssertEqual(total.status, .complete)
        XCTAssertGreaterThan(total.bytes ?? 0, 100)
        XCTAssertEqual(result.total(selected: []).status, .unavailable)
        var uncertain = result
        uncertain.items[0].size = SizeReading(bytes: nil, status: .unavailable)
        XCTAssertEqual(uncertain.total(selected: Set(uncertain.items.map(\.path))).status, .partial)
        XCTAssertEqual(uncertain.total(selected: [appPath]).status, .unavailable)
    }
}
