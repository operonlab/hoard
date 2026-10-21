import XCTest
@testable import TreeCore

final class SuggestTests: XCTestCase {
    private static let mib: Int64 = 1_048_576
    private static let now: Int64 = 1_800_000_000
    private static let old: Int64 = now - 60 * 86_400
    private static let recent: Int64 = now - 86_400

    private struct E {
        var path: String
        var dir = false
        var size: Int64 = 0
        var mod: Int64 = 0
        var acc: Int64 = 0
        var links: UInt32 = 1
        var fileID: UInt64 = 0
    }

    private func f(_ path: String, _ size: Int64 = 2 * SuggestTests.mib, mod: Int64 = SuggestTests.old, acc: Int64 = 0,
                   links: UInt32 = 1, fileID: UInt64 = 0) -> E {
        E(path: path, size: size, mod: mod, acc: acc, links: links, fileID: fileID)
    }

    private func d(_ path: String) -> E { E(path: path, dir: true) }

    /// Synthetic tree, zero disk I/O. Intermediate folders are created on demand. `prepare` runs
    /// before `recomputeAggregates`, so status marks lift to ancestors.
    private func build(_ entries: [E], root: String = "/h/u", prepare: (FileTree) -> Void = { _ in }) -> FileTree {
        let tree = FileTree(rootPath: root, device: 1)
        var ids: [String: NodeID] = ["": FileTree.root]
        func dirID(_ p: String) -> NodeID {
            if let id = ids[p] { return id }
            let parts = p.split(separator: "/")
            let parent = dirID(parts.dropLast().joined(separator: "/"))
            let id = tree.addChild(of: parent, entry: ScanEntry(name: String(parts.last!), isDirectory: true, device: 1))
            ids[p] = id
            return id
        }
        for e in entries {
            if e.dir { _ = dirID(e.path); continue }
            let parts = e.path.split(separator: "/")
            let parent = dirID(parts.dropLast().joined(separator: "/"))
            ids[e.path] = tree.addChild(of: parent, entry: ScanEntry(
                name: String(parts.last!), isDirectory: false, allocSize: e.size, logicalSize: e.size, fileID: e.fileID,
                linkCount: e.links, modTime: e.mod, accessTime: e.acc, device: 1))
        }
        prepare(tree)
        tree.recomputeAggregates()
        return tree
    }

    private func id(_ tree: FileTree, _ rel: String) -> NodeID {
        let base = tree.rootPath.hasSuffix("/") ? String(tree.rootPath.dropLast()) : tree.rootPath
        guard let id = tree.lookup(path: base + "/" + rel) else { fatalError("no \(rel) in fixture") }
        return id
    }

    private func options(home: String = "/h/u", minBytes: Int64 = 0, limit: Int? = nil) -> SuggestOptions {
        SuggestOptions(home: home, now: Self.now, minBytes: minBytes, limit: limit)
    }

    private func appOptions(_ apps: InstalledApps?, check: (@Sendable (String) -> Bool?)? = nil,
                            group: (@Sendable (String) -> Bool?)? = nil, minBytes: Int64 = 0) -> SuggestOptions {
        SuggestOptions(home: "/h/u", now: Self.now, minBytes: minBytes, installedApps: apps,
                       isAppRegistered: check, appGroupInstalled: group)
    }

    func testAppLeftoversMatchAndSafetyGuards() throws {
        let tree = build([
            f("Library/Application Support/com.foo.app/data"),
            f("Library/Containers/com.exact.app/data"),
            f("Library/Application Support/Slack/data"),
            f("Library/Application Support/com.apple.fake/data"),
            f("Library/Application Support/Bitwarden Archive/data"),
            f("Library/Application Support/com.orphan.old/data"),
            f("Library/Application Support/com.young.old/data", mod: Self.recent),
            f("Library/WebKit/com.used.recent/data", acc: Self.recent),
            f("Library/Group Containers/UBF8T346G9.com.microsoft/data"),
            f("Library/Preferences/com.old.pref.plist"),
            f("Library/Preferences/readme.txt"),
            f("Library/Caches/com.orphan.old/data"),
        ])
        let apps = InstalledApps(bundleIDs: ["COM.FOO.APP.HELPER", "COM.EXACT.APP"], names: ["S l-a_c k"], source: "fixture")
        let report = try CleanupSuggester.suggest(in: tree, options: appOptions(apps, check: { _ in false }))
        let leftovers = report.suggestions.filter { $0.ruleID == "app_leftovers" }
        XCTAssertEqual(Set(leftovers.map(\.path)), [
            "/h/u/Library/Application Support/com.orphan.old",
            "/h/u/Library/Group Containers/UBF8T346G9.com.microsoft",
            "/h/u/Library/Preferences/com.old.pref.plist",
        ])
        XCTAssertTrue(leftovers.allSatisfy { $0.category == .appLeftover && $0.safety == .review })
        XCTAssertTrue(leftovers.first(where: { $0.path.contains("microsoft") })?.evidence.contains("com.microsoft") == true)
        XCTAssertEqual(report.suggestions.first(where: { $0.path.contains("/Caches/") })?.ruleID, "app_caches")
        XCTAssertFalse(report.skipped.contains { $0.why == .installedAppsUnknown })
    }

    func testAppLeftoversUnknownAndLaunchServices() throws {
        let tree = build([
            f("Library/Application Support/com.lookup.true/data"),
            f("Library/Containers/com.lookup.unknown/data"),
            f("Library/HTTPStorages/com.lookup.false/data"),
        ])
        let unknown = try CleanupSuggester.suggest(in: tree, options: appOptions(nil))
        XCTAssertEqual(unknown.suggestions, [])
        XCTAssertEqual(Set(unknown.skipped.map(\.path)), [
            "/h/u/Library/Application Support", "/h/u/Library/Containers", "/h/u/Library/HTTPStorages",
        ])
        XCTAssertTrue(unknown.skipped.allSatisfy { $0.why == .installedAppsUnknown })
        let unreadable = build([d("Library/Containers")]) { t in
            t.markUnavailable(self.id(t, "Library/Containers"))
        }
        let unreadableReport = try CleanupSuggester.suggest(in: unreadable, options: appOptions(nil))
        XCTAssertEqual(unreadableReport.skipped.first?.why, .installedAppsUnknown)
        XCTAssertEqual(unreadableReport.skipped.first?.status, .unavailable)

        let apps = InstalledApps(bundleIDs: [], names: [], source: "fixture")
        let report = try CleanupSuggester.suggest(in: tree, options: appOptions(apps, check: {
            switch $0 { case "com.lookup.true": return true; case "com.lookup.unknown": return nil; default: return false }
        }))
        XCTAssertEqual(report.suggestions.filter { $0.ruleID == "app_leftovers" }.map(\.path),
                       ["/h/u/Library/HTTPStorages/com.lookup.false"])
    }

    /// Application Support folders are often named after the vendor (`Google` for Chrome): a dotless
    /// name equal to the vendor part of an installed bundle id is kept.
    func testAppLeftoversVendorFolderOfAnInstalledAppIsKept() throws {
        let tree = build([
            f("Library/Application Support/Google/data"),
            f("Library/Application Support/Blackmagic Design/data"),
            f("Library/Application Support/Acme/data"),
            f("Library/Application Support/com.google.gone/data"),
        ])
        let apps = InstalledApps(bundleIDs: ["com.google.Chrome", "com.blackmagic-design.DaVinciResolve"], names: [], source: "fixture")
        let report = try CleanupSuggester.suggest(in: tree, options: appOptions(apps, check: { _ in false }))
        XCTAssertEqual(Set(report.suggestions.filter { $0.ruleID == "app_leftovers" }.map(\.path)), [
            "/h/u/Library/Application Support/Acme",
            "/h/u/Library/Application Support/com.google.gone",
        ])
    }

    /// macOS keeps its own data in these places under names that are not com.apple.* (device backups,
    /// contacts, Shortcuts, Podcasts), and some group containers name no app at all: none of it is
    /// "left behind by an app that is no longer installed".
    func testAppLeftoversNeverClaimAppleOrUnattributableData() throws {
        let big = 20 * Self.mib
        let tree = build([
            f("Library/Application Support/MobileSync/Backup/x", big),
            f("Library/Application Support/CloudDocs/session/x"),
            f("Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Library/x"),
            f("Library/Group Containers/group.is.workflow.my.app/x"),
            f("Library/Group Containers/UBF8T346G9.Office/x"),
            f("Library/Group Containers/2BUA8C4S2C.com.agilebits/x"),
            f("Library/Logs/DiagnosticReports/x.ips"),
            f("Library/Logs/fsck_hfs.log", big),
            f("Library/Application Support/default.store", big),
            f("Library/Application Support/com.gone.app/x"),
        ])
        let apps = InstalledApps(bundleIDs: [], names: [], source: "fixture")
        let report = try CleanupSuggester.suggest(in: tree, options: appOptions(apps, check: { _ in false }))
        XCTAssertEqual(report.suggestions.filter { $0.ruleID == "app_leftovers" }.map(\.path),
                       ["/h/u/Library/Application Support/com.gone.app"])
        // A log file directly in Logs is an old log, not an app's leftover.
        XCTAssertEqual(report.suggestions.first { $0.path.hasSuffix("fsck_hfs.log") }?.ruleID, "library_logs")
    }

    func testAppLeftoversPreserveExistingLogRule() throws {
        let big = 20 * Self.mib
        let tree = build([
            f("Library/Logs/com.installed.tool/trace.log", big),
            f("Library/Logs/com.apple.tool/trace.log", big),
            f("Library/Logs/Bitwarden Archive/trace.log", big),
            f("Library/Logs/com.orphan.app/trace.log", big),
            f("Library/Logs/com.young.app/trace.log", big, mod: Self.recent),
        ])
        let apps = InstalledApps(bundleIDs: ["com.installed.tool"], names: [], source: "fixture")
        let report = try CleanupSuggester.suggest(in: tree, options: appOptions(apps, check: { _ in false }))
        XCTAssertEqual(Set(report.suggestions.filter { $0.ruleID == "library_logs" }.map(\.path)), [
            "/h/u/Library/Logs/com.installed.tool/trace.log",
        ])
        XCTAssertEqual(report.suggestions.filter { $0.ruleID == "app_leftovers" }.map(\.path),
                       ["/h/u/Library/Logs/com.orphan.app"])
    }

    private func suggest(_ tree: FileTree, scope: NodeID = FileTree.root, minBytes: Int64 = 0, limit: Int? = nil,
                         rules: [SuggestRule] = SuggestRule.defaults) throws -> SuggestReport {
        try CleanupSuggester.suggest(in: tree, under: scope, options: options(minBytes: minBytes, limit: limit), rules: rules)
    }

    private func only(_ report: SuggestReport, file: StaticString = #filePath, line: UInt = #line) -> Suggestion? {
        XCTAssertEqual(report.suggestions.count, 1, "\(report.suggestions.map(\.path))", file: file, line: line)
        return report.suggestions.first
    }

    // MARK: 1. Every default rule fires with its marker and not without it

    func testDefaultTableOrder() {
        XCTAssertEqual(SuggestRule.defaults.map(\.id), [
            "node_modules", "python_venv", "cocoapods", "cargo_target", "swiftpm_build", "gradle_project", "pycache",
            "xcode_derived_data", "build_output", "homebrew_cache", "pip_cache", "yarn_cache", "yarn_berry_cache",
            "npm_cache", "pnpm_store", "xcode_device_support", "simulator_caches", "app_caches", "app_leftovers", "installers",
            "disk_images", "downloaded_zip", "library_logs", "log_files",
        ])
        XCTAssertEqual(Set(SuggestRule.defaults.map(\.id)).count, SuggestRule.defaults.count)
    }

    func testEveryDefaultRuleNeedsItsMarker() throws {
        let big = 20 * Self.mib
        // (rule, category, safety, fixture with the marker, candidate, fixture without it)
        let cases: [(String, SuggestCategory, SuggestSafety, [E], String, [E])] = [
            ("node_modules", .buildArtifact, .redownloadable,
             [f("p/package.json"), f("p/package-lock.json"), f("p/node_modules/x")], "p/node_modules",
             [f("p/README.md"), f("p/node_modules/x")]),
            ("python_venv", .buildArtifact, .redownloadable,
             [f("p/requirements.txt"), f("p/.venv/pyvenv.cfg"), f("p/.venv/lib/x")], "p/.venv",
             [f("p/requirements.txt"), f("p/.venv/lib/x")]),
            ("cocoapods", .buildArtifact, .redownloadable,
             [f("p/Podfile"), f("p/Podfile.lock"), f("p/Pods/x")], "p/Pods",
             [f("p/Podfile.lock"), f("p/Pods/x")]),
            ("cargo_target", .buildArtifact, .regenerable, [f("p/Cargo.toml"), f("p/target/x")], "p/target",
             [f("p/Cargo.lock"), f("p/target/x")]),
            ("swiftpm_build", .buildArtifact, .regenerable, [f("p/Package.swift"), f("p/.build/x")], "p/.build",
             [f("p/Package.resolved"), f("p/.build/x")]),
            ("gradle_project", .buildArtifact, .regenerable, [f("p/settings.gradle.kts"), f("p/.gradle/x")], "p/.gradle",
             [f("p/gradle.properties"), f("p/.gradle/x")]),
            ("pycache", .buildArtifact, .regenerable, [f("p/__pycache__/a.cpython-312.pyc")], "p/__pycache__",
             [f("p/__pycache__/a.cpython-312.pyc"), f("p/__pycache__/a.py")]),
            ("xcode_derived_data", .buildArtifact, .regenerable,
             [f("Library/Developer/Xcode/DerivedData/App-abc/x")], "Library/Developer/Xcode/DerivedData/App-abc",
             [f("other/Library/Developer/Xcode/DerivedData/App-abc/x")]),
            ("build_output", .buildArtifact, .review, [f("p/CMakeLists.txt"), f("p/build/x")], "p/build",
             [f("p/Makefile"), f("p/build/x")]),
            ("homebrew_cache", .packageCache, .redownloadable, [f("Library/Caches/Homebrew/x")], "Library/Caches/Homebrew",
             [f("other/Library/Caches/Homebrew/x")]),
            ("pip_cache", .packageCache, .redownloadable, [f("Library/Caches/pip/x")], "Library/Caches/pip",
             [f("other/Library/Caches/pip/x")]),
            ("yarn_cache", .packageCache, .redownloadable, [f("Library/Caches/Yarn/x")], "Library/Caches/Yarn",
             [f("other/Library/Caches/Yarn/x")]),
            ("yarn_berry_cache", .packageCache, .redownloadable, [f(".yarn/berry/cache/x")], ".yarn/berry/cache",
             [f("p/.yarn/berry/cache/x")]),
            ("npm_cache", .packageCache, .redownloadable, [f(".npm/_cacache/x")], ".npm/_cacache",
             [f("p/.npm/_cacache/x")]),
            ("pnpm_store", .packageCache, .redownloadable, [f("Library/pnpm/store/x")], "Library/pnpm/store",
             [f("other/Library/pnpm/store/x")]),
            ("xcode_device_support", .appCache, .redownloadable,
             [f("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)/x")],
             "Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)",
             [f("other/Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)/x")]),
            ("simulator_caches", .appCache, .regenerable, [f("Library/Developer/CoreSimulator/Caches/x")],
             "Library/Developer/CoreSimulator/Caches", [f("other/Library/Developer/CoreSimulator/Caches/x")]),
            ("app_caches", .appCache, .regenerable, [f("Library/Caches/com.example.app/x")], "Library/Caches/com.example.app",
             [f("other/Library/Caches/com.example.app/x")]),
            ("installers", .installer, .review, [f("Downloads/Tool.pkg")], "Downloads/Tool.pkg",
             [f("other/Tool.pkg")]),
            ("disk_images", .installer, .review, [f("Downloads/Tool.dmg")], "Downloads/Tool.dmg",
             [f("other/Tool.dmg")]),
            ("downloaded_zip", .installer, .review, [f("Downloads/sub/photos.zip")], "Downloads/sub/photos.zip",
             [f("other/photos.zip")]),
            ("library_logs", .oldLog, .review, [f("Library/Logs/App/trace.txt", big)], "Library/Logs/App/trace.txt",
             [f("other/Logs/App/trace.txt", big)]),
            ("log_files", .oldLog, .review, [f("p/server.log", big)], "p/server.log", [f("p/server.txt", big)]),
        ]
        XCTAssertEqual(Set(cases.map(\.0)), Set(SuggestRule.defaults.map(\.id).filter { $0 != "app_leftovers" }), "every generic default rule has a case")
        for (rule, category, safety, with, candidate, without) in cases {
            let tree = build(with)
            let report = try suggest(tree)
            XCTAssertEqual(report.suggestions.count, 1, "\(rule): \(report.suggestions.map(\.ruleID))")
            if let s = report.suggestions.first {
                XCTAssertEqual(s.ruleID, rule)
                XCTAssertEqual(s.path, "/h/u/" + candidate, rule)
                XCTAssertEqual(s.node, id(tree, candidate), rule)
                XCTAssertEqual(s.category, category, rule)
                XCTAssertEqual(s.safety, safety, rule)
                XCTAssertEqual(s.status, .complete, rule)
                XCTAssertFalse(s.evidence.isEmpty, rule)
                XCTAssertFalse(s.reason.isEmpty, rule)
            }
            XCTAssertEqual(report.skipped.filter { $0.ruleID != "app_leftovers" }, [], rule)
            let none = try suggest(build(without))
            XCTAssertEqual(none.suggestions.map(\.ruleID), [], "\(rule) fired without its marker")
            XCTAssertEqual(none.skipped.filter { $0.ruleID != "app_leftovers" }, [], rule)
        }
    }

    func testNodeModulesEvidenceNamesMarkerAndLockfile() throws {
        let tree = build([f("p/package.json"), f("p/package-lock.json"), f("p/node_modules/x")])
        let s = only(try suggest(tree))
        XCTAssertEqual(s?.evidence, "sibling package.json, package-lock.json")
        XCTAssertEqual(s?.newestModTime, Self.old)
    }

    // MARK: 2. node_modules

    func testNodeModulesWithoutLockfileIsReview() throws {
        let s = only(try suggest(build([f("p/package.json"), f("p/node_modules/x")])))
        XCTAssertEqual(s?.ruleID, "node_modules")
        XCTAssertEqual(s?.safety, .review)
    }

    func testNestedNodeModulesCountOnce() throws {
        let tree = build([f("a/package.json"), f("a/yarn.lock"), f("a/node_modules/b/package.json"),
                          f("a/node_modules/b/node_modules/x"), f("a/node_modules/c")])
        let s = only(try suggest(tree))
        XCTAssertEqual(s?.path, "/h/u/a/node_modules")
        XCTAssertEqual(s?.bytes, 6 * Self.mib)
    }

    func testGlobalInstallInnerNodeModulesIsNotSuggested() throws {
        let tree = build([f("lib/node_modules/pkg/package.json"), f("lib/node_modules/pkg/node_modules/x")])
        XCTAssertEqual(try suggest(tree).suggestions, [])
    }

    // MARK: 3. Python

    func testEnvWithoutPyvenvCfgIsNotSuggested() throws {
        XCTAssertEqual(try suggest(build([f("p/requirements.txt"), f("p/env/lib/x")])).suggestions, [])
    }

    func testVenvWithoutProjectFileIsReview() throws {
        let s = only(try suggest(build([f("p/venv/pyvenv.cfg"), f("p/venv/lib/x")])))
        XCTAssertEqual(s?.ruleID, "python_venv")
        XCTAssertEqual(s?.safety, .review)
    }

    func testPycacheHoldingSourceIsNotSuggested() throws {
        XCTAssertEqual(try suggest(build([f("p/__pycache__/a.pyc"), f("p/__pycache__/a.py")])).suggestions, [])
        XCTAssertEqual(try suggest(build([d("p/__pycache__")])).suggestions, [], "an empty __pycache__ proves nothing")
    }

    // MARK: 4. Home-anchored rules

    private let cachesFixture = ["Library/Caches/com.example.app/x", "Library/Caches/Homebrew/x"]

    private func ruleByPath(_ report: SuggestReport) -> [String: String] {
        Dictionary(uniqueKeysWithValues: report.suggestions.map { ($0.path, $0.ruleID) })
    }

    func testCachesChildAndPackageCachePrecedence() throws {
        let report = try suggest(build(cachesFixture.map { f($0) }))
        XCTAssertEqual(ruleByPath(report), ["/h/u/Library/Caches/com.example.app": "app_caches",
                                            "/h/u/Library/Caches/Homebrew": "homebrew_cache"])
        XCTAssertEqual(report.suggestions.first { $0.ruleID == "homebrew_cache" }?.category, .packageCache)
        XCTAssertEqual(report.suggestions.first { $0.ruleID == "app_caches" }?.category, .appCache)
    }

    func testDataVolumeRootStillMatchesHome() throws {
        let tree = build(cachesFixture.map { f("h/u/" + $0) }, root: "/System/Volumes/Data")
        XCTAssertEqual(ruleByPath(try suggest(tree)), [
            "/System/Volumes/Data/h/u/Library/Caches/com.example.app": "app_caches",
            "/System/Volumes/Data/h/u/Library/Caches/Homebrew": "homebrew_cache",
        ])
    }

    func testRootBelowHomeStillMatches() throws {
        let tree = build(cachesFixture.map { f(String($0.dropFirst("Library/".count))) }, root: "/h/u/Library")
        XCTAssertEqual(ruleByPath(try suggest(tree)), ["/h/u/Library/Caches/com.example.app": "app_caches",
                                                       "/h/u/Library/Caches/Homebrew": "homebrew_cache"])
        let slash = build(cachesFixture.map { f(String($0.dropFirst("Library/".count))) }, root: "/h/u/Library/")
        XCTAssertEqual(try suggest(slash).suggestions.count, 2, "a trailing slash on rootPath")
    }

    func testOtherUsersHomeDoesNotMatch() throws {
        let tree = build([f("other/Library/Caches/x/y"), f("other/Library/Caches/Homebrew/y")], root: "/h")
        XCTAssertEqual(try suggest(tree).suggestions, [])
    }

    func testRootAtSlashMatchesBothHomeForms() throws {
        let tree = build([f("h/u/Library/Caches/Homebrew/x"), f("System/Volumes/Data/h/u/Library/Caches/Homebrew/x")],
                         root: "/")
        XCTAssertEqual(Set(try suggest(tree).suggestions.map(\.path)),
                       ["/h/u/Library/Caches/Homebrew", "/System/Volumes/Data/h/u/Library/Caches/Homebrew"])
    }

    // MARK: 5. Installers

    func testInstallerAgeAndLocation() throws {
        let tree = build([
            f("Downloads/old.pkg"),
            f("Downloads/new.pkg", mod: Self.recent),
            f("Downloads/used.pkg", mod: Self.old, acc: Self.recent),
            f("Downloads/zero.pkg", mod: 0, acc: 0),
            f("Downloads/old.zip"),
            f("other/old.pkg"),
            f("other/old.zip"),
        ])
        let report = try suggest(tree)
        XCTAssertEqual(ruleByPath(report), ["/h/u/Downloads/old.pkg": "installers", "/h/u/Downloads/old.zip": "downloaded_zip"])
        XCTAssertEqual(report.suggestions.first { $0.ruleID == "installers" }?.safety, .review)
        XCTAssertEqual(report.suggestions.first { $0.ruleID == "downloaded_zip" }?.safety, .review)
        XCTAssertEqual(report.skipped.map(\.path), ["/h/u/Downloads/zero.pkg"])
        XCTAssertEqual(report.skipped.first?.why, .ageUnknown)
        XCTAssertEqual(report.skipped.first?.ruleID, "installers")
    }

    func testInstallerExtensionIsCaseInsensitive() throws {
        XCTAssertEqual(only(try suggest(build([f("Downloads/Tool.PKG")])))?.ruleID, "installers")
        XCTAssertEqual(only(try suggest(build([f("Downloads/Disk.ISO")])))?.ruleID, "disk_images")
    }

    func testInstallerLocationsAndOriginEvidence() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HoardSuggest-\(UUID().uuidString)").path
        let entries = [f("Desktop/sub/Tool.pkg"), f("Library/Downloads/Tool.xip"),
                       f("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/Mail.pkg"),
                       f("Documents/sub/Disk.dmg"), f("Downloads/Unknown.pkg")]
        let tree = build(entries, root: home)
        let report = try CleanupSuggester.suggest(in: tree, options: SuggestOptions(
            home: home, now: Self.now, minBytes: 0,
            downloadOrigin: {
                if $0.hasSuffix("Desktop/sub/Tool.pkg") { return "https://example.com/private?token=secret" }
                if $0.hasSuffix("Documents/sub/Disk.dmg") { return "http://images.example/disk.dmg?key=hidden" }
                return nil
            }))
        XCTAssertEqual(report.suggestions.count, entries.count)
        let desktop = try XCTUnwrap(report.suggestions.first { $0.path.hasSuffix("Desktop/sub/Tool.pkg") })
        XCTAssertEqual(desktop.safety, .redownloadable)
        XCTAssertTrue(desktop.evidence.contains("downloaded from https://example.com"))
        XCTAssertFalse(desktop.evidence.contains("private"))
        XCTAssertFalse(desktop.evidence.contains("token"))
        XCTAssertEqual(report.suggestions.first { $0.path.hasSuffix("Downloads/Unknown.pkg") }?.safety, .review)
        XCTAssertEqual(report.suggestions.first { $0.path.hasSuffix("Mail Downloads/Mail.pkg") }?.ruleID, "installers")
        XCTAssertEqual(report.suggestions.first { $0.path.hasSuffix("Library/Downloads/Tool.xip") }?.ruleID, "installers")
        XCTAssertEqual(report.suggestions.first { $0.path.hasSuffix("Documents/sub/Disk.dmg") }?.safety, .review)
        XCTAssertTrue(report.suggestions.first { $0.path.hasSuffix("Documents/sub/Disk.dmg") }?.evidence
            .contains("downloaded from http://images.example") == true)
        XCTAssertFalse(report.suggestions.first { $0.path.hasSuffix("Documents/sub/Disk.dmg") }?.evidence
            .contains("key=hidden") == true)
    }

    /// Apple ids in other dress (`systemgroup.com.apple.*`, `<team>.group.com.apple.*`) are Apple's too.
    func testAppleIdsBehindOtherPrefixesAreNotLeftovers() throws {
        let tree = build([f("Library/Group Containers/ABCDE12345.group.com.apple.notes/x"),
                          f("Library/Group Containers/systemgroup.com.apple.configurationprofiles/x"),
                          f("Library/Group Containers/ABCDE12345.group.com.gone.app/x")])
        let report = try CleanupSuggester.suggest(in: tree, options: appOptions(InstalledApps(bundleIDs: [], names: [], source: "fixture"),
                                                                                 check: { _ in false }))
        XCTAssertEqual(report.suggestions.filter { $0.ruleID == "app_leftovers" }.map(\.path),
                       ["/h/u/Library/Group Containers/ABCDE12345.group.com.gone.app"])
    }

    /// When some installed items could not be read, an unseen app may own a folder: only a reverse-DNS
    /// id that LaunchServices positively does not know is claimed.
    func testUnreadableItemsLimitClaimsToIdsLaunchServicesDoesNotKnow() throws {
        let tree = build([f("Library/Application Support/Vendor/x"),
                          f("Library/Group Containers/ABCDE12345.com.vendor/x"),
                          f("Library/Application Support/com.vendor.helper/x")])
        func leftovers(_ unreadable: Int) throws -> Set<String> {
            let apps = InstalledApps(bundleIDs: [], names: [], source: "fixture", unreadableItems: unreadable)
            return Set(try CleanupSuggester.suggest(in: tree, options: appOptions(apps, check: { _ in false }))
                .suggestions.filter { $0.ruleID == "app_leftovers" }.map(\.path))
        }
        XCTAssertEqual(try leftovers(1), ["/h/u/Library/Application Support/com.vendor.helper"])
        XCTAssertEqual(try leftovers(0), ["/h/u/Library/Application Support/Vendor", "/h/u/Library/Group Containers/ABCDE12345.com.vendor",
                                          "/h/u/Library/Application Support/com.vendor.helper"])
    }

    func testGroupContainersUseInstalledVendorAndUnreadableGate() throws {
        let tree = build([f("Library/Group Containers/group.com.vendor.shared/data"),
                          f("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/data")])
        func claimed(_ apps: InstalledApps) throws -> Set<String> {
            Set(try CleanupSuggester.suggest(in: tree, options: appOptions(apps, check: { _ in true }))
                .suggestions.filter { $0.ruleID == "app_leftovers" }.map(\.path))
        }
        XCTAssertEqual(try claimed(InstalledApps(bundleIDs: ["com.vendor.app"], names: [], source: "fixture")),
                       ["/h/u/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"])
        XCTAssertEqual(try claimed(InstalledApps(bundleIDs: [], names: [], source: "fixture")),
                       ["/h/u/Library/Group Containers/group.com.vendor.shared",
                        "/h/u/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"])
        XCTAssertEqual(try claimed(InstalledApps(bundleIDs: [], names: [], source: "fixture", unreadableItems: 1)), [])
    }

    func testGroupContainerUsesSignedClaim() throws {
        let name = "HUAQ24HBR6.dev.orbstack"
        let tree = build([f("Library/Group Containers/\(name)/disk", 2 * Self.mib)])
        let apps = InstalledApps(bundleIDs: ["dev.kdrag0n.MacVirt"], names: [], source: "fixture")
        func report(_ answer: Bool?) throws -> SuggestReport {
            try CleanupSuggester.suggest(in: tree, options: appOptions(apps, group: { group in
                group == name ? answer : nil
            }, minBytes: Self.mib))
        }
        XCTAssertEqual(try report(true).suggestions, [])
        XCTAssertEqual(try report(false).suggestions.map(\.path), ["/h/u/Library/Group Containers/\(name)"])
        let unknown = try report(nil)
        XCTAssertEqual(unknown.suggestions, [])
        XCTAssertEqual(unknown.skipped.map(\.why), [.installedAppsUnknown])
        XCTAssertEqual(unknown.skipped.map(\.path), ["/h/u/Library/Group Containers/\(name)"])
    }

    func testGroupContainerUsesKnownName() throws {
        let tree = build([f("Library/Group Containers/group.foo/data")])
        let apps = InstalledApps(bundleIDs: [], names: ["foo"], source: "fixture")
        let report = try CleanupSuggester.suggest(in: tree, options: appOptions(apps))
        XCTAssertEqual(report.suggestions, [])
    }

    func testUnreadableInstalledAppsGateHasSkipForLargeFolder() throws {
        let tree = build([f("Library/Application Support/Some Vendor/data", 2 * Self.mib)])
        let apps = InstalledApps(bundleIDs: [], names: [], source: "fixture", unreadableItems: 1)
        let report = try CleanupSuggester.suggest(in: tree, options: appOptions(apps, minBytes: Self.mib))
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.skipped.map(\.why), [.installedAppsUnknown])
        XCTAssertEqual(report.skipped.map(\.path), ["/h/u/Library/Application Support/Some Vendor"])

        // A folder used last week would not be suggested anyway: the gate says nothing about it.
        let young = build([f("Library/Application Support/Some Vendor/data", 2 * Self.mib, mod: Self.recent)])
        XCTAssertEqual(try CleanupSuggester.suggest(in: young, options: appOptions(apps, minBytes: Self.mib)).skipped, [])
    }

    /// With installed apps known (the normal case) the leftover rule sees `Containers/com.apple.mail`
    /// first; it is Apple's, so no leftover, but the walk must still reach Mail Downloads below it.
    func testMailDownloadsReachedWhenInstalledAppsAreKnown() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HoardSuggest-\(UUID().uuidString)").path
        let tree = build([f("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/Mail.pkg"),
                          f("Library/Containers/com.gone.app/Data/x")], root: home)
        let report = try CleanupSuggester.suggest(in: tree, options: SuggestOptions(
            home: home, now: Self.now, minBytes: 0, installedApps: InstalledApps(bundleIDs: [], names: [], source: "fixture"),
            isAppRegistered: { _ in false }))
        XCTAssertEqual(report.suggestions.first { $0.path.hasSuffix("Mail Downloads/Mail.pkg") }?.ruleID, "installers")
        XCTAssertFalse(report.suggestions.contains { $0.path.hasSuffix("com.apple.mail") })
        XCTAssertTrue(report.suggestions.contains { $0.path.hasSuffix("Containers/com.gone.app") && $0.ruleID == "app_leftovers" })
    }

    func testZipInspectionFalseTrueAndUnknown() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HoardSuggest-\(UUID().uuidString)").path
        let tree = build([f("Desktop/sub/Tool.zip")], root: home)
        func report(_ holds: @escaping @Sendable (String) -> Bool?) throws -> SuggestReport {
            try CleanupSuggester.suggest(in: tree, options: SuggestOptions(
                home: home, now: Self.now, minBytes: 0, archiveHoldsInstaller: holds))
        }
        XCTAssertTrue(try report { _ in false }.suggestions.isEmpty)
        let found = try XCTUnwrap(report { _ in true }.suggestions.first)
        XCTAssertEqual(found.ruleID, "downloaded_zip")
        XCTAssertEqual(found.safety, .review)
        XCTAssertTrue(found.evidence.contains("holds an installer (.app/.pkg/.dmg/.xip)"))
        let unknown = try XCTUnwrap(report { _ in nil }.suggestions.first)
        XCTAssertFalse(unknown.evidence.contains("holds an installer"))
        XCTAssertEqual(try CleanupSuggester.suggest(in: tree, options: SuggestOptions(home: home, now: Self.now,
                                                                                     minBytes: 0)).suggestions.count, 1)
    }

    // MARK: 6. Logs

    func testOldLargeLogs() throws {
        let tree = build([
            f("Library/Logs/big.log", 20 * Self.mib),
            f("p/big.log", 20 * Self.mib),
            f("p/small.log", 5 * Self.mib),
            f("p/recent.log", 20 * Self.mib, mod: Self.recent),
            f("Library/Logs/small.txt", 5 * Self.mib),
        ])
        let report = try suggest(tree)
        XCTAssertEqual(ruleByPath(report), ["/h/u/Library/Logs/big.log": "library_logs", "/h/u/p/big.log": "log_files"])
        XCTAssertTrue(report.suggestions.allSatisfy { $0.category == .oldLog && $0.safety == .review })
    }

    // MARK: 7. Protected paths hold for any rule table

    private func anyNamed(_ names: [String]) -> [SuggestRule] {
        [SuggestRule(id: "custom", category: .appCache, safety: .regenerable, target: .directoryNamed(names),
                     marker: .location, reason: "test")]
    }

    func testProtectedPathsAreNeverSuggested() throws {
        let tree = build([f("u/Documents/a"), f("u/Desktop/a"), f("u/proj/.git/HEAD"), f("u/Pictures/X.photoslibrary/db")],
                         root: "/h")
        let report = try suggest(tree, rules: anyNamed(["Documents", "Desktop", "u", ".git", "X.photoslibrary"]))
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.skipped.map(\.path), ["/h/u", "/h/u/Desktop", "/h/u/Documents", "/h/u/Pictures/X.photoslibrary",
                                                    "/h/u/proj/.git"])
        XCTAssertTrue(report.skipped.allSatisfy { $0.why == .protectedPath })
    }

    func testFolderHoldingDocumentsOrHomeIsProtected() throws {
        let tree = build([f("u/Documents/a")], root: "/h")
        let report = try suggest(tree, rules: anyNamed(["u"]))
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.skipped.map(\.why), [.protectedPath])
    }

    func testRootInsidePhotosLibraryYieldsNothing() throws {
        let tree = build([f("originals/a/x"), f("caches/x")], root: "/h/u/Pictures/X.photoslibrary")
        let report = try suggest(tree, rules: anyNamed(["originals", "a", "caches"]))
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.skipped.map(\.path), [tree.rootPath])
        XCTAssertEqual(report.totalStatus, .partial)
    }

    func testScopeInsideGitYieldsNothing() throws {
        let tree = build([f("p/.git/objects/pack/x")])
        let report = try suggest(tree, scope: id(tree, "p/.git/objects"), rules: anyNamed(["pack"]))
        XCTAssertEqual(report.suggestions, [])
    }

    func testBuildInsideXcodeProjectIsNotSuggested() throws {
        let tree = build([f("Foo.xcodeproj/CMakeLists.txt"), f("Foo.xcodeproj/build/object.o")])
        let report = try suggest(tree)
        XCTAssertFalse(report.suggestions.contains { $0.path.contains("Foo.xcodeproj") })
    }

    func testScopeInsideXcodeProjectReportsProtectedSkip() throws {
        let tree = build([f("Foo.xcodeproj/build/object.o")])
        let scope = id(tree, "Foo.xcodeproj/build")
        let report = try suggest(tree, scope: scope)
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.totalStatus, .partial)
        XCTAssertEqual(report.skipped, [SkippedCandidate(node: scope, path: "/h/u/Foo.xcodeproj/build",
                                                          ruleID: "package", why: .protectedPath, status: .complete)])
        let unavailable = build([f("Foo.xcodeproj/build/object.o")]) { tree in
            tree.markUnavailable(self.id(tree, "Foo.xcodeproj/build"))
        }
        let blocked = try suggest(unavailable, scope: id(unavailable, "Foo.xcodeproj/build"))
        XCTAssertEqual(blocked.totalStatus, .partial)
        XCTAssertEqual(blocked.skipped.map(\.status), [.unavailable])
    }

    func testCandidateHoldingPhotosLibraryIsProtected() throws {
        let tree = build([f("Pictures/X.photoslibrary/db"), f("Pictures/y")])
        let report = try suggest(tree, rules: anyNamed(["Pictures"]))
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.skipped.map(\.why), [.protectedPath])
    }

    func testGuardsIgnoreCase() throws {
        let photos = build([f("Pictures/Old.PhotosLibrary/db"), f("Pictures/y")])
        XCTAssertEqual(try suggest(photos, rules: anyNamed(["Pictures"])).skipped.map(\.why), [.protectedPath])
        let git = build([f("p/package.json"), f("p/yarn.lock"), f("p/node_modules/dep/.GIT"), f("p/node_modules/dep/x")])
        XCTAssertEqual(try suggest(git).skipped.first?.why, .containsGit)
    }

    func testNodeModulesHoldingGitIsSkipped() throws {
        let tree = build([f("p/package.json"), f("p/yarn.lock"), f("p/node_modules/dep/.git"), f("p/node_modules/dep/x")])
        let report = try suggest(tree)
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.skipped.map(\.path), ["/h/u/p/node_modules"])
        XCTAssertEqual(report.skipped.first?.why, .containsGit)
    }

    // MARK: 7b. Package checkouts are not a repository

    func testDerivedDataPackageCheckoutsAreAllowed() throws {
        let dd = "Library/Developer/Xcode/DerivedData/"
        let tree = build([
            f(dd + "P/SourcePackages/checkouts/x/.git/HEAD"), f(dd + "P/SourcePackages/checkouts/y/.git/HEAD"),
            f(dd + "P/Build/x"),
            f(dd + "Q/MyRepo/.git/HEAD"),
            f(dd + "R/SourcePackages/checkouts/x/sub/.git/HEAD"),
        ])
        let report = try suggest(tree)
        let s = only(report)
        XCTAssertEqual(s?.path, "/h/u/" + dd + "P")
        XCTAssertEqual(s?.ruleID, "xcode_derived_data")
        XCTAssertEqual(s?.safety, .regenerable)
        XCTAssertTrue(s?.evidence.contains("contains 2 package checkouts (git clones)") ?? false, s?.evidence ?? "")
        XCTAssertEqual(report.skipped.map(\.path), ["/h/u/" + dd + "Q", "/h/u/" + dd + "R"])
        XCTAssertTrue(report.skipped.allSatisfy { $0.why == .containsGit })
    }

    func testSwiftPMCheckoutsAreAllowed() throws {
        let tree = build([f("pkg/Package.swift"), f("pkg/.build/checkouts/dep/.git/HEAD"), f("pkg/.build/debug/x")])
        let s = only(try suggest(tree))
        XCTAssertEqual(s?.ruleID, "swiftpm_build")
        XCTAssertTrue(s?.evidence.contains("contains 1 package checkouts (git clones)") ?? false)
    }

    func testGitDirectlyInCheckoutsFolderStillCounts() throws {
        let tree = build([f("pkg/Package.swift"), f("pkg/.build/checkouts/.git/HEAD")])
        XCTAssertEqual(try suggest(tree).skipped.map(\.why), [.containsGit])
    }

    // MARK: 8. Three-state

    func testUnavailableCandidateIsUnreadable() throws {
        let tree = build([f("p/package.json"), d("p/node_modules")]) { t in
            t.markUnavailable(self.id(t, "p/node_modules"))
        }
        let report = try suggest(tree)
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.skipped.map(\.why), [.unreadable])
        XCTAssertEqual(report.skipped.first?.status, .unavailable)
        XCTAssertEqual(report.totalStatus, .partial)
    }

    func testPartialCandidateIsReviewLowerBound() throws {
        let tree = build([f("q/package.json"), f("q/package-lock.json"), f("q/node_modules/a"), d("q/node_modules/deep")]) { t in
            t.markUnavailable(self.id(t, "q/node_modules/deep"))
        }
        let s = only(try suggest(tree))
        XCTAssertEqual(s?.status, .partial)
        XCTAssertEqual(s?.safety, .review)
        XCTAssertEqual(s?.bytes, tree[self.id(tree, "q/node_modules")].totalAlloc)
        XCTAssertEqual(s?.bytes, 2 * Self.mib)
        XCTAssertTrue(s?.evidence.contains("some folders inside could not be read") ?? false)
        XCTAssertEqual(try suggest(tree).totalStatus, .partial)
    }

    func testMissingMarkerUnderIncompleteListingIsUnknown() throws {
        let tree = build([f("r/node_modules/x")]) { t in t.markListingIncomplete(self.id(t, "r")) }
        let report = try suggest(tree)
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.skipped.map(\.why), [.markerUnknown])
        XCTAssertEqual(report.skipped.first?.ruleID, "node_modules")
    }

    func testParentPartialOnlyThroughDeepChildHasCompleteListing() throws {
        let tree = build([f("r/node_modules/x"), d("r/deep/z")]) { t in t.markUnavailable(self.id(t, "r/deep/z")) }
        XCTAssertEqual(tree[id(tree, "r")].status, .partial)
        let report = try suggest(tree)
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.skipped.map(\.why), [], "absent from a complete listing → no match")
    }

    func testIncompletePycache() throws {
        let tree = build([f("s/__pycache__/a.pyc"), f("t/__pycache__/a.pyc"), f("t/__pycache__/a.py")]) { t in
            t.markListingIncomplete(self.id(t, "s/__pycache__"))
            t.markListingIncomplete(self.id(t, "t/__pycache__"))
        }
        let report = try suggest(tree)
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.skipped.map(\.path), ["/h/u/s/__pycache__"])
        XCTAssertEqual(report.skipped.first?.why, .markerUnknown)
    }

    func testUnavailableScope() throws {
        let tree = build([f("p/package.json"), d("dead")]) { t in t.markUnavailable(self.id(t, "dead")) }
        let report = try suggest(tree, scope: id(tree, "dead"))
        XCTAssertEqual(report.scopeStatus, .unavailable)
        XCTAssertEqual(report.totalStatus, .unavailable)
        XCTAssertEqual(report.suggestions, [])
        XCTAssertEqual(report.totalBytes, 0)
    }

    // MARK: 9. Bytes are totalAlloc

    func testHardlinkOwnedElsewhereIsNotCounted() throws {
        let tree = build([f("a/shared", 4 * Self.mib, links: 2, fileID: 7),
                          f("p/package.json"), f("p/yarn.lock"),
                          f("p/node_modules/shared", 4 * Self.mib, links: 2, fileID: 7),
                          f("p/node_modules/own", Self.mib)])
        let s = only(try suggest(tree))
        XCTAssertEqual(s?.bytes, Self.mib)
        XCTAssertEqual(s?.sharedFiles, 1)
    }

    // MARK: 10. Removed nodes

    func testRemovedCandidateOrMarkerIsIgnored() throws {
        let tree = build([f("a/package.json"), f("a/node_modules/x"), f("b/package.json"), f("b/node_modules/x")])
        tree.removeSubtree(id(tree, "a/node_modules"))
        tree.removeSubtree(id(tree, "b/package.json"))
        XCTAssertEqual(try suggest(tree).suggestions, [])
    }

    // MARK: 11. Ordering, limits, scope, errors

    private func threeProjects() -> FileTree {
        build([f("b/package.json"), f("b/yarn.lock"), f("b/node_modules/x", 3 * Self.mib),
               f("a/package.json"), f("a/yarn.lock"), f("a/node_modules/x", 2 * Self.mib),
               f("c/package.json"), f("c/yarn.lock"), f("c/node_modules/x", 2 * Self.mib)])
    }

    func testSortTiesAndLimit() throws {
        let tree = threeProjects()
        let all = try suggest(tree)
        XCTAssertEqual(all.suggestions.map(\.path), ["/h/u/b/node_modules", "/h/u/a/node_modules", "/h/u/c/node_modules"])
        XCTAssertEqual(all.totalBytes, 7 * Self.mib)
        XCTAssertEqual(all.omitted, 0)
        XCTAssertEqual(all.totalStatus, .complete)
        let cut = try suggest(tree, limit: 2)
        XCTAssertEqual(cut.suggestions.map(\.path), ["/h/u/b/node_modules", "/h/u/a/node_modules"])
        XCTAssertEqual(cut.omitted, 1)
        XCTAssertEqual(cut.totalBytes, 7 * Self.mib)
    }

    func testMinBytesDropsSmallMatches() throws {
        let report = try suggest(threeProjects(), minBytes: 2 * Self.mib + 1)
        XCTAssertEqual(report.suggestions.map(\.path), ["/h/u/b/node_modules"])
        XCTAssertEqual(report.totalBytes, 3 * Self.mib)
        let defaults = try CleanupSuggester.suggest(in: build([f("p/package.json"), f("p/node_modules/x", 1000)]),
                                                    options: SuggestOptions(home: "/h/u", now: Self.now))
        XCTAssertEqual(defaults.suggestions, [], "default minBytes is 1 MiB")
    }

    func testScopeLimitsTheWalk() throws {
        let tree = threeProjects()
        let report = try suggest(tree, scope: id(tree, "a"))
        XCTAssertEqual(report.suggestions.map(\.path), ["/h/u/a/node_modules"])
        XCTAssertEqual(report.totalBytes, 2 * Self.mib)
    }

    func testScopeItselfIsNeverSuggested() throws {
        let tree = build([f("p/package.json"), f("p/build/x")])
        XCTAssertEqual(try suggest(tree, scope: id(tree, "p/build")).suggestions, [])
        XCTAssertEqual(try suggest(tree, scope: id(tree, "p")).suggestions.map(\.path), ["/h/u/p/build"])
    }

    func testInvalidHomeOrScopeThrows() throws {
        let tree = threeProjects()
        for home in ["", "/", "//", "h/u", "~/x"] {
            XCTAssertThrowsError(try CleanupSuggester.suggest(in: tree, options: options(home: home))) { error in
                XCTAssertEqual(error as? SuggestError, .invalidHome(home))
            }
        }
        XCTAssertNoThrow(try CleanupSuggester.suggest(in: tree, options: options(home: "/h/u/")))
        let removed = id(tree, "a/node_modules")
        tree.removeSubtree(removed)
        for scope in [NodeID(-1), NodeID(tree.nodeCount), removed] {
            XCTAssertThrowsError(try suggest(tree, scope: scope)) { error in
                XCTAssertEqual(error as? SuggestError, .invalidScope(scope))
            }
        }
    }

    func testTrailingSlashHomeMatches() throws {
        let report = try CleanupSuggester.suggest(in: build([f("Library/Caches/Homebrew/x")]),
                                                  options: options(home: "/h/u/"))
        XCTAssertEqual(report.suggestions.map(\.ruleID), ["homebrew_cache"])
    }

    // MARK: 12. Rules are data

    func testCustomRuleFires() throws {
        let vendor = SuggestRule(id: "composer_vendor", category: .buildArtifact, safety: .redownloadable,
                                 target: .directoryNamed(["vendor"]), marker: .siblingAny(["composer.json"]),
                                 confirmSiblings: ["composer.lock"], reason: "Composer packages.")
        let tree = build([f("p/composer.json"), f("p/composer.lock"), f("p/vendor/x"), f("q/vendor/x")])
        let s = only(try suggest(tree, rules: [vendor]))
        XCTAssertEqual(s?.path, "/h/u/p/vendor")
        XCTAssertEqual(s?.ruleID, "composer_vendor")
        XCTAssertEqual(s?.safety, .redownloadable)
        XCTAssertEqual(s?.evidence, "sibling composer.json, composer.lock")
    }

    func testNodesOverloadMatchesTreeOverload() throws {
        let tree = threeProjects()
        let nodes = tree.nodes
        let fromNodes = try CleanupSuggester.suggest(in: nodes, rootPath: tree.rootPath, options: options())
        XCTAssertEqual(fromNodes, try suggest(tree))
    }

    // MARK: 13. Timing

    func testThirtyThousandDeepProjectsIsFast() throws {
        let tree = FileTree(rootPath: "/h/u/code", device: 1)
        func dir(_ name: String, _ parent: NodeID) -> NodeID {
            tree.addChild(of: parent, entry: ScanEntry(name: name, isDirectory: true, device: 1))
        }
        func file(_ name: String, _ parent: NodeID, _ size: Int64 = 4096) {
            tree.addChild(of: parent, entry: ScanEntry(name: name, isDirectory: false, allocSize: size, logicalSize: size,
                                                       modTime: Self.old, device: 1))
        }
        for g in 0..<300 {
            var parent = dir("g\(g)", FileTree.root)
            for level in 1...10 { parent = dir("l\(level)", parent) }
            for p in 0..<100 {
                let project = dir("p\(p)", parent)   // 12 directories below the root
                file("package.json", project)
                file("package-lock.json", project)
                for k in 0..<10 { file("src\(k).ts", project) }
                file("f", dir("node_modules", project), 2 * Self.mib)
            }
        }
        tree.recomputeAggregates()
        XCTAssertGreaterThan(tree.nodeCount, 450_000)
        let nodes = tree.nodes
        let start = Date()
        let report = try CleanupSuggester.suggest(in: nodes, rootPath: tree.rootPath,
                                                  options: SuggestOptions(home: "/h/u", now: Self.now))
        let elapsed = Date().timeIntervalSince(start)
        print("CleanupSuggester 30k deep projects: \(String(format: "%.3f", elapsed)) s")
        XCTAssertEqual(report.suggestions.count, 30_000)
        XCTAssertEqual(report.totalBytes, 30_000 * 2 * Self.mib)
        XCTAssertEqual(report.skipped, [])
        #if !DEBUG
        XCTAssertLessThan(elapsed, 2.0)
        #endif
    }

    /// The parallel walk splits big folders on the caller and hands the rest to workers, each with the
    /// rule context of its folder. Folders below Downloads carry the installer rules into the workers.
    func testParallelWalkGivesTheSingleThreadReport() throws {
        var entries: [E] = []
        for p in 0..<40 {
            entries.append(f("Projects/p\(p)/package.json"))
            for i in 0..<300 { entries.append(f("Projects/p\(p)/node_modules/m\(i)/index.js")) }
        }
        entries.append(f("Projects/p0/node_modules/m0/.git/HEAD"))
        for q in 0..<12 {
            for i in 0..<600 { entries.append(f("Downloads/batch\(q)/note\(i).txt")) }
            entries += [f("Downloads/batch\(q)/setup\(q).dmg"), f("Downloads/batch\(q)/a\(q).zip"),
                        f("Downloads/batch\(q)/deep/x\(q).pkg"), f("Downloads/batch\(q)/run\(q).log", 12 * Self.mib)]
        }
        for k in 0..<30 { entries.append(f("Library/Caches/com.app\(k)/blob")) }
        for k in 0..<20 { entries.append(f("Library/Application Support/com.orphan\(k)/data")) }
        entries.append(f("Library/Application Support/com.foo.app/data"))
        for k in 0..<10 { entries.append(f("Library/Logs/out\(k).txt", 12 * Self.mib)) }
        for w in 0..<35 {
            entries.append(f("Work/w\(w)/run.log", 12 * Self.mib))
            for i in 0..<1000 { entries.append(f("Work/w\(w)/src/f\(i).swift")) }
        }
        let tree = build(entries)
        XCTAssertGreaterThanOrEqual(tree.nodeCount, FileTree.parallelThreshold)
        let apps = InstalledApps(bundleIDs: ["com.foo.app"], names: [], source: "fixture")
        for opts in [options(), appOptions(apps, check: { _ in false })] {
            let one = try CleanupSuggester.suggest(in: tree.nodes, rootPath: tree.rootPath, options: opts, workers: 1)
            let many = try CleanupSuggester.suggest(in: tree.nodes, rootPath: tree.rootPath, options: opts, workers: 8)
            XCTAssertEqual(many, one)
            let rules = Set(one.suggestions.map(\.ruleID))
            XCTAssertTrue(rules.isSuperset(of: ["node_modules", "disk_images", "downloaded_zip", "installers", "log_files",
                                                "app_caches", "library_logs"]), "\(rules)")
            XCTAssertTrue(one.skipped.contains { $0.why == .containsGit })
            XCTAssertGreaterThan(one.suggestions.count, 100)
        }
    }
}
