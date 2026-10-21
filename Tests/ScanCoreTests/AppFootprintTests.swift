import Darwin
import Foundation
import XCTest
@testable import ScanCore

final class AppFootprintTests: XCTestCase {
    private var base = ""
    private let id = "com.example.Foo"
    private let signed = AppSigning(teamID: "TEAM123456", appGroups: ["TEAM123456.shared.store"])

    override func setUpWithError() throws {
        var template = Array((FileManager.default.temporaryDirectory.path + "/AppFootprintTests.XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(.init(rawValue: errno)!) }
        guard let resolved = realpath(String(cString: template), nil) else { throw POSIXError(.init(rawValue: errno)!) }
        base = String(cString: resolved)
        free(resolved)
    }

    override func tearDownWithError() throws {
        if !base.isEmpty { try FileManager.default.removeItem(atPath: base) }
    }

    private func roots(_ label: String) throws -> AppFootprintRoots {
        let root = base + "/" + label
        try FileManager.default.createDirectory(atPath: root + "/Applications", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/Library", withIntermediateDirectories: true)
        return AppFootprintRoots(applications: [root + "/Applications", root + "/UserApps"],
                                 library: root + "/Library")
    }

    @discardableResult private func file(_ path: String, count: Int = 4096) throws -> String {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: count).write(to: URL(fileURLWithPath: path))
        return path
    }

    @discardableResult private func folder(_ path: String) throws -> String {
        try file(path + "/payload", count: 8192)
        return path
    }

    @discardableResult private func app(_ path: String, id: String? = "com.example.Foo",
                                        binary: Bool = false) throws -> String {
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        if let id {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id],
                                                          format: binary ? .binary : .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        }
        try file(path + "/Contents/resource", count: 8192)
        return path
    }

    private func analyze(_ roots: AppFootprintRoots,
                         signing: @escaping (String) -> AppSigning? = { _ in AppSigning(teamID: nil, appGroups: []) },
                         lastUsed: @escaping (String) -> Date? = { _ in nil },
                         tree: FileTree? = nil,
                         isCancelled: (() -> Bool)? = nil) throws -> AppFootprintReport {
        try AppFootprintAnalyzer.analyze(roots: roots, tree: tree, scanner: ScanCore.Scanner(),
                                         signing: signing, lastUsed: lastUsed, isCancelled: isCancelled)
    }

    private func alloc(_ path: String) throws -> Int64 {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return try XCTUnwrap(ScanCore.Scanner().listDirectory(parent).first { $0.name == name }).allocSize
    }

    private func reading(_ bytes: Int64?, _ status: ScanStatus) -> SizeReading {
        SizeReading(bytes: bytes, status: status)
    }

    func testAllKindsExactMatch() throws {
        let r = try roots("all")
        try app(r.applications[0] + "/Foo.app", binary: true)
        let uuid = UUID().uuidString
        let directoryNames: [(AppDataKind, String)] = [
            (.applicationSupport, id), (.caches, id), (.containers, id), (.logs, id), (.webKit, id),
            (.httpStorages, id), (.savedState, id + ".savedState")
        ]
        var expected: [String: (AppDataKind, Int64)] = [:]
        for (kind, name) in directoryNames {
            let path = try folder(r.library + "/" + kind.rawValue + "/" + name)
            expected[path] = (kind, try ScanCore.Scanner().scan(root: path)[FileTree.root].totalAlloc)
        }
        let files: [(AppDataKind, String)] = [
            (.httpStorages, id + ".binarycookies"), (.cookies, id + ".binarycookies"),
            (.preferences, id + ".plist"), (.preferences, "ByHost/" + id + "." + uuid + ".plist")
        ]
        for (kind, name) in files {
            let path = try file(r.library + "/" + kind.rawValue + "/" + name)
            expected[path] = (kind, try alloc(path))
        }
        let report = try analyze(r)
        let footprint = try XCTUnwrap(report.apps.first)
        XCTAssertEqual(report.apps.count, 1)
        XCTAssertEqual(footprint.bundleID, id)
        XCTAssertEqual(footprint.locations.count, expected.count)
        for location in footprint.locations {
            let match = try XCTUnwrap(expected[location.path])
            XCTAssertEqual(location.kind, match.0)
            XCTAssertEqual(location.matchedBy, .bundleID)
            XCTAssertEqual(location.matchedID, id)
            XCTAssertEqual(location.size, reading(match.1, .complete))
        }
        XCTAssertEqual(footprint.data, reading(expected.values.reduce(0) { $0 + $1.1 }, .complete))
        XCTAssertEqual(footprint.sharedData, reading(0, .complete))
        XCTAssertTrue(report.unreadable.isEmpty)
    }

    func testDecoysNeverMatch() throws {
        let r = try roots("decoys")
        try app(r.applications[0] + "/Foo.app")
        let names = ["Application Support/Foo", "Caches/com.example.Foo.Pro", "Containers/com.example",
                     "Preferences/com.example.Foo.plist.bak", "Preferences/ByHost/com.example.Foo.Pro.\(UUID().uuidString).plist",
                     "Group Containers/TEAM123456.other", "Group Containers/ZZZ9999999.com.example.Foo",
                     "Logs/COM.EXAMPLE.FOO"]
        for name in names { try folder(r.library + "/" + name) }
        let result = try analyze(r, signing: { _ in self.signed })
        let footprint = try XCTUnwrap(result.apps.first)
        XCTAssertTrue(footprint.locations.isEmpty)
        XCTAssertEqual(footprint.data, reading(0, .complete))
        XCTAssertEqual(footprint.sharedData, reading(0, .complete))
    }

    func testEmbeddedAndGroups() throws {
        let r = try roots("embedded")
        let bundle = try app(r.applications[0] + "/Foo.app")
        try app(bundle + "/Contents/PlugIns/Share.appex", id: id + ".Share")
        let names: [(String, AppMatch, String)] = [
            ("Containers/" + id + ".Share", .embeddedBundleID, id + ".Share"),
            ("Group Containers/TEAM123456.shared.store", .appGroup, "TEAM123456.shared.store"),
            ("Group Containers/TEAM123456." + id, .teamBundleID, id),
            ("Group Containers/group." + id, .groupBundleID, id)
        ]
        for item in names { try folder(r.library + "/" + item.0) }
        let footprint = try XCTUnwrap(analyze(r, signing: { _ in self.signed }).apps.first)
        XCTAssertEqual(footprint.teamID, "TEAM123456")
        XCTAssertEqual(footprint.locations.count, names.count)
        for (name, source, matchedID) in names {
            let location = try XCTUnwrap(footprint.locations.first { $0.path == r.library + "/" + name })
            XCTAssertEqual(location.matchedBy, source)
            XCTAssertEqual(location.matchedID, matchedID)
        }
    }

    func testSharedGoesToSharedData() throws {
        let r = try roots("shared")
        try app(r.applications[0] + "/Foo.app")
        try app(r.applications[1] + "/Foo.app")
        let path = try folder(r.library + "/Caches/" + id)
        let bytes = try ScanCore.Scanner().scan(root: path)[FileTree.root].totalAlloc
        let result = try analyze(r)
        XCTAssertEqual(result.apps.count, 2)
        for footprint in result.apps {
            XCTAssertEqual(footprint.data, reading(0, .complete))
            XCTAssertEqual(footprint.sharedData, reading(bytes, .complete))
            XCTAssertEqual(footprint.locations.count, 1)
            XCTAssertEqual(footprint.locations[0].sharedWith,
                           result.apps.filter { $0.appPath != footprint.appPath }.map(\.appPath))
        }
    }

    func testUnknownIsNeverZero() throws {
        let noID = try roots("no-id")
        try app(noID.applications[0] + "/Foo.app", id: nil)
        let missing = try XCTUnwrap(analyze(noID).apps.first)
        XCTAssertNil(missing.bundleID)
        XCTAssertEqual(missing.data, reading(nil, .unavailable))
        XCTAssertEqual(missing.sharedData, reading(nil, .unavailable))
        XCTAssertFalse(try analyze(noID).unreadable.contains(noID.applications[1]))

        let lockedLocation = try roots("locked-location")
        try app(lockedLocation.applications[0] + "/Foo.app")
        let readable = try folder(lockedLocation.library + "/Application Support/" + id)
        let bytes = try ScanCore.Scanner().scan(root: readable)[FileTree.root].totalAlloc
        let locked = try folder(lockedLocation.library + "/Caches/" + id)
        XCTAssertEqual(chmod(locked, 0), 0)
        defer { chmod(locked, 0o755) }
        let first = try XCTUnwrap(analyze(lockedLocation).apps.first)
        XCTAssertEqual(try XCTUnwrap(first.locations.first { $0.path == locked }).size, reading(nil, .unavailable))
        XCTAssertEqual(first.data, reading(bytes, .partial))

        let lockedRoot = try roots("locked-root")
        try app(lockedRoot.applications[0] + "/Foo.app")
        let caches = try folder(lockedRoot.library + "/Caches/" + id)
        XCTAssertEqual(chmod(lockedRoot.library + "/Caches", 0), 0)
        defer { chmod(lockedRoot.library + "/Caches", 0o755) }
        let secondReport = try analyze(lockedRoot)
        XCTAssertTrue(secondReport.unreadable.contains(lockedRoot.library + "/Caches"))
        XCTAssertEqual(secondReport.apps[0].data, reading(nil, .unavailable))
        _ = caches
        let other = try folder(lockedRoot.library + "/Logs/" + id)
        let otherBytes = try ScanCore.Scanner().scan(root: other)[FileTree.root].totalAlloc
        XCTAssertEqual(try XCTUnwrap(analyze(lockedRoot).apps.first).data, reading(otherBytes, .partial))

        let noSigning = try roots("no-signing")
        try app(noSigning.applications[0] + "/Foo.app")
        let dataPath = try folder(noSigning.library + "/Caches/" + id)
        let dataBytes = try ScanCore.Scanner().scan(root: dataPath)[FileTree.root].totalAlloc
        XCTAssertEqual(try XCTUnwrap(analyze(noSigning, signing: { _ in nil }).apps.first).data,
                       reading(dataBytes, .partial))

        let embedded = try roots("locked-embedded")
        let bundle = try app(embedded.applications[0] + "/Foo.app")
        let plugs = try folder(bundle + "/Contents/PlugIns")
        let known = try folder(embedded.library + "/Caches/" + id)
        let knownBytes = try ScanCore.Scanner().scan(root: known)[FileTree.root].totalAlloc
        XCTAssertEqual(chmod(plugs, 0), 0)
        defer { chmod(plugs, 0o755) }
        let embeddedReport = try analyze(embedded)
        XCTAssertTrue(embeddedReport.unreadable.contains(plugs))
        XCTAssertEqual(embeddedReport.apps[0].data, reading(knownBytes, .partial))
        XCTAssertEqual(embeddedReport.apps[0].appSize.status, .partial)

        let badPlist = try roots("bad-embedded-plist")
        let parent = try app(badPlist.applications[0] + "/Foo.app")
        let child = try app(parent + "/Contents/PlugIns/Share.appex", id: id + ".Share")
        try Data("invalid plist".utf8).write(to: URL(fileURLWithPath: child + "/Contents/Info.plist"))
        let present = try folder(badPlist.library + "/Caches/" + id)
        let presentBytes = try ScanCore.Scanner().scan(root: present)[FileTree.root].totalAlloc
        let badReport = try analyze(badPlist)
        XCTAssertEqual(badReport.apps[0].data, reading(presentBytes, .partial))
        XCTAssertFalse(badReport.unreadable.contains(child + "/Contents/Info.plist"))
    }

    func testTreeBeatsWalk() throws {
        let r = try roots("tree")
        let bundle = try app(r.applications[0] + "/Foo.app")
        let twin = base + "/tree/0aaa/twin"
        try FileManager.default.createDirectory(atPath: (twin as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        XCTAssertEqual(link(bundle + "/Contents/resource", twin), 0)
        let tree = try ScanCore.Scanner().scan(root: base + "/tree")
        let node = try XCTUnwrap(tree.lookup(path: bundle))
        let walk = try ScanCore.Scanner().scan(root: bundle)[FileTree.root].totalAlloc
        let first = try XCTUnwrap(analyze(r, tree: tree).apps.first)
        XCTAssertEqual(first.appSizedFrom, .tree)
        XCTAssertEqual(first.appSize.bytes, tree[node].totalAlloc)
        XCTAssertLessThan(try XCTUnwrap(first.appSize.bytes), walk)

        let rerooted = FileTree(restoring: tree.nodes, rootPath: "/System/Volumes/Data" + base + "/tree",
                                device: tree.device)
        let second = try XCTUnwrap(analyze(r, tree: rerooted).apps.first)
        XCTAssertEqual(second.appSizedFrom, .tree)
        XCTAssertEqual(second.appSize.bytes, first.appSize.bytes)
        let unrelated = try ScanCore.Scanner().scan(root: r.library)
        XCTAssertEqual(try XCTUnwrap(analyze(r, tree: unrelated).apps.first).appSizedFrom, .walk)
    }

    func testSymlinks() throws {
        let r = try roots("links")
        let real = try app(base + "/links/elsewhere/Real.app", id: "com.example.Real")
        let hop = base + "/links/hop/Mid.app"
        try FileManager.default.createDirectory(atPath: (hop as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: hop, withDestinationPath: real)
        let linked = r.applications[0] + "/Linked.app"
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: hop)
        let brokenPath = r.applications[0] + "/Broken.app"
        try FileManager.default.createSymbolicLink(atPath: brokenPath,
                                                   withDestinationPath: base + "/nowhere")
        let foo = try app(r.applications[0] + "/Foo.app")
        try FileManager.default.createDirectory(atPath: r.applications[1], withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: r.applications[1] + "/Alias.app", withDestinationPath: foo)
        let cache = try folder(r.library + "/Caches/" + id)
        let cacheBytes = try ScanCore.Scanner().scan(root: cache)[FileTree.root].totalAlloc
        let symlinkData = r.library + "/Application Support/" + id
        try FileManager.default.createDirectory(atPath: (symlinkData as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try folder(base + "/links/elsewhere/data")
        try FileManager.default.createSymbolicLink(atPath: symlinkData,
                                                   withDestinationPath: base + "/links/elsewhere/data")
        var signingPaths: [String] = []
        var usedPaths: [String] = []
        let date = Date(timeIntervalSince1970: 123456)
        let result = try analyze(r, signing: { path in signingPaths.append(path); return self.signed },
                                 lastUsed: { path in usedPaths.append(path); return path == real ? date : nil })
        XCTAssertEqual(result.apps.count, 3)
        let resolved = try XCTUnwrap(result.apps.first { $0.appPath == linked })
        XCTAssertEqual(resolved.linkTarget, real)
        XCTAssertEqual(resolved.bundleID, "com.example.Real")
        XCTAssertEqual(resolved.appSize.status, .complete)
        XCTAssertGreaterThan(try XCTUnwrap(resolved.appSize.bytes), 0)
        XCTAssertEqual(resolved.lastUsed, date)
        XCTAssertTrue(signingPaths.contains(real))
        XCTAssertTrue(usedPaths.contains(real))
        XCTAssertTrue(signingPaths.contains(brokenPath))
        XCTAssertTrue(usedPaths.contains(brokenPath))
        let broken = try XCTUnwrap(result.apps.first { $0.appPath.hasSuffix("Broken.app") })
        XCTAssertNil(broken.linkTarget)
        XCTAssertNil(broken.bundleID)
        XCTAssertFalse(broken.isApple)
        XCTAssertEqual(broken.appSize, reading(nil, .unavailable))
        XCTAssertEqual(broken.appSizedFrom, .none)
        XCTAssertEqual(broken.data, reading(nil, .unavailable))
        XCTAssertEqual(broken.sharedData, reading(nil, .unavailable))
        let tree = try ScanCore.Scanner().scan(root: base + "/links")
        let brokenWithTree = try XCTUnwrap(analyze(r, tree: tree).apps.first { $0.appPath == brokenPath })
        XCTAssertEqual(brokenWithTree.appSize, reading(nil, .unavailable))
        XCTAssertEqual(brokenWithTree.appSizedFrom, .none)
        let actual = try XCTUnwrap(result.apps.first { $0.appPath == foo })
        XCTAssertEqual(actual.locations.count, 2)
        XCTAssertTrue(actual.locations.allSatisfy { $0.sharedWith.isEmpty })
        XCTAssertEqual(actual.data, reading(cacheBytes, .partial))
        XCTAssertEqual(actual.sharedData, reading(0, .complete))
        let linkedData = try XCTUnwrap(actual.locations.first { $0.path == symlinkData })
        XCTAssertTrue(linkedData.isSymlink)
        XCTAssertEqual(linkedData.size, reading(nil, .unavailable))
        XCTAssertEqual(linkedData.sizedFrom, .none)
    }

    func testEnumerationFlagsOrderCancel() throws {
        let r = try roots("enumeration")
        let foo = try app(r.applications[0] + "/Foo.app")
        try app(foo + "/Contents/Helpers/H.app", id: "com.example.Helper")
        let nested = try app(r.applications[0] + "/Utilities/Sub.app", id: "com.apple.Fake")
        try app(r.applications[0] + "/X.bundle", id: "com.example.Bundle")
        let large = try app(r.applications[0] + "/Large.app", id: "com.example.Large")
        try file(large + "/Contents/large", count: 128 * 1024)
        let date = Date(timeIntervalSince1970: 234567)
        let report = try analyze(r, lastUsed: { $0 == nested ? date : nil })
        XCTAssertEqual(Set(report.apps.map(\.appPath)), Set([foo, nested, large]))
        XCTAssertEqual(report.apps.first?.appPath, large)
        XCTAssertTrue(try XCTUnwrap(report.apps.first { $0.appPath == nested }).isApple)
        XCTAssertEqual(try XCTUnwrap(report.apps.first { $0.appPath == nested }).lastUsed, date)
        XCTAssertNil(try XCTUnwrap(report.apps.first { $0.appPath == foo }).lastUsed)
        XCTAssertThrowsError(try analyze(r, isCancelled: { true })) { error in
            XCTAssertEqual(error as? ScanError, .cancelled)
        }

        let tied = try roots("ties")
        let a = try app(tied.applications[0] + "/A.app")
        let b = try app(tied.applications[0] + "/B.app")
        let http = try file(tied.library + "/HTTPStorages/" + id + ".binarycookies")
        let pref = try file(tied.library + "/Preferences/" + id + ".plist")
        let symlink = tied.library + "/Application Support/" + id
        try folder(base + "/ties/external")
        try FileManager.default.createDirectory(atPath: (symlink as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: base + "/ties/external")
        let ordered = try analyze(tied).apps
        XCTAssertEqual(ordered.map(\.appPath), [a, b])
        XCTAssertEqual(ordered[0].appSize, ordered[1].appSize)
        XCTAssertEqual(try alloc(http), try alloc(pref))
        XCTAssertEqual(ordered[0].locations.map(\.path), [http, pref, symlink])
    }

    func testSigningReaderUnsigned() throws {
        let r = try roots("unsigned")
        let bundle = try app(r.applications[0] + "/Unsigned.app")
        XCTAssertEqual(AppSigning.read(bundlePath: bundle), AppSigning(teamID: nil, appGroups: []))
    }

    func testRealMachineProbe() throws {
        guard ProcessInfo.processInfo.environment["HOARD_REAL_APPS"] == "1" else {
            throw XCTSkip("Set HOARD_REAL_APPS=1 from a Full Disk Access terminal")
        }
        let report = try AppFootprintAnalyzer.analyze()
        var unavailable = 0
        for app in report.apps {
            for size in [app.appSize, app.data, app.sharedData] + app.locations.map(\.size) {
                XCTAssertEqual(size.bytes == nil, size.status == .unavailable)
            }
            if app.bundleID?.hasPrefix("com.apple.") == true { XCTAssertTrue(app.isApple) }
            for location in app.locations {
                if location.size.status == .unavailable { unavailable += 1 }
                let name = (location.path as NSString).lastPathComponent
                let id = location.matchedID
                switch location.matchedBy {
                case .appGroup: XCTAssertEqual(name, id)
                case .teamBundleID: XCTAssertEqual(name, app.teamID.map { $0 + "." + id })
                case .groupBundleID: XCTAssertEqual(name, "group." + id)
                case .bundleID, .embeddedBundleID:
                    switch location.kind {
                    case .applicationSupport, .caches, .containers, .logs, .webKit:
                        XCTAssertEqual(name, id)
                    case .httpStorages: XCTAssertTrue(name == id || name == id + ".binarycookies")
                    case .cookies: XCTAssertEqual(name, id + ".binarycookies")
                    case .preferences:
                        if location.path.contains("/ByHost/") {
                            XCTAssertTrue(name.hasPrefix(id + ".") && name.hasSuffix(".plist"))
                            XCTAssertNotNil(UUID(uuidString: String(name.dropFirst(id.count + 1).dropLast(6))))
                        } else { XCTAssertEqual(name, id + ".plist") }
                    case .savedState: XCTAssertEqual(name, id + ".savedState")
                    case .groupContainers: XCTFail("group match must identify its group rule")
                    }
                }
            }
        }
        print("FDA: \(FullDiskAccess.current()); unavailable locations: \(unavailable)")
        for app in report.apps.prefix(10) { print("\(app.appPath): \(String(describing: app.appSize.bytes))") }
    }
}
