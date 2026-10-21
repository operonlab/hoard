import Darwin
import Foundation
import XCTest
@testable import ScanCore

final class ProtectTests: XCTestCase {
    private var fixtureRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in fixtureRoots {
            try ProtectionACL.stripFixtureEntries(in: root.path)
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Fixture root remains: \(root.path)")
        }
        fixtureRoots.removeAll()
        try super.tearDownWithError()
    }

    private func fixture() throws -> (URL, ProtectionStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HoardProtect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        fixtureRoots.append(root)
        return (root, ProtectionStore(directory: root.appendingPathComponent("store"), home: home))
    }

    private func remove(_ item: ProtectedItem, from store: ProtectionStore) throws {
        // No overload without ProtectionRemoval exists; a caller must supply the human-confirmation token.
        try store.remove(item.id, .confirmedByHuman(reason: "test cleanup"))
    }

    func testDatalessFlagDetection() {
        var st = stat()
        XCTAssertFalse(ProtectionStore.isDataless(st))
        st.st_flags = UInt32(SF_DATALESS)
        XCTAssertTrue(ProtectionStore.isDataless(st))
    }

    func testFileLockBlocksDeletionAndRenameButAllowsInPlaceWrite() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("locked.txt")
        try Data("first".utf8).write(to: file)
        let item = try store.lock(file.path, by: "test")
        defer { try? remove(item, from: store) }
        XCTAssertEqual(store.health(item.id), .intact)
        XCTAssertEqual(unlink(file.path), -1)
        XCTAssertTrue(errno == EPERM || errno == EACCES)
        let fd = open(file.path, O_WRONLY | O_TRUNC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        if fd >= 0 { _ = write(fd, "new", 3); close(fd) }
        XCTAssertEqual(try String(contentsOf: file), "new")
        let replacement = root.appendingPathComponent("replacement.txt")
        try Data("other".utf8).write(to: replacement)
        XCTAssertEqual(rename(replacement.path, file.path), -1)
        XCTAssertTrue(errno == EPERM || errno == EACCES)
        try remove(item, from: store)
        let ls = Process(); ls.executableURL = URL(fileURLWithPath: "/bin/ls")
        ls.arguments = ["-led", file.path]
        let aclOutput = Pipe(); ls.standardOutput = aclOutput
        try ls.run(); ls.waitUntilExit()
        let aclText = String(data: aclOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertFalse(aclText.contains("everyone deny delete"))
        XCTAssertEqual(unlink(file.path), 0)
        XCTAssertEqual(store.health(item.id), .itemMissing(restorable: false))
    }

    func testFolderLockCoversNestedDirectories() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let deepFile = nested.appendingPathComponent("deep.txt")
        try Data("x".utf8).write(to: deepFile)
        let item = try store.lock(folder.path, by: "test")
        defer { try? remove(item, from: store) }
        XCTAssertEqual(unlink(deepFile.path), -1)
        XCTAssertTrue(errno == EPERM || errno == EACCES)
        let added = nested.appendingPathComponent("new.txt")
        try Data("created".utf8).write(to: added)
        XCTAssertEqual(unlink(added.path), -1)
        let newDir = nested.appendingPathComponent("newdir")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let deeper = newDir.appendingPathComponent("deeper.txt")
        try Data("created".utf8).write(to: deeper)
        XCTAssertEqual(unlink(deeper.path), -1)
        try remove(item, from: store)
        XCTAssertEqual(unlink(deepFile.path), 0)
        XCTAssertEqual(unlink(added.path), 0)
        XCTAssertEqual(unlink(deeper.path), 0)
    }

    func testGuardFileRestoresAndRetainsThreeVersions() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("guarded.txt")
        try Data("first".utf8).write(to: file)
        let item = try store.guardItem(file.path, by: "test")
        defer { try? remove(item, from: store) }
        let reopened = ProtectionStore(directory: root.appendingPathComponent("store"))
        XCTAssertEqual(reopened.items(), [item])
        XCTAssertEqual(reopened.item(covering: file.path), item)
        let firstVersionDir = root.appendingPathComponent("store/vault/\(item.id)")
        let firstVersion = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: firstVersionDir.path).first)
        XCTAssertEqual(unlink(firstVersionDir.appendingPathComponent(firstVersion).path), -1)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(store.health(item.id), .itemMissing(restorable: true))
        try store.refresh(file.path) // A deletion event must not replace the vault with an empty snapshot.
        XCTAssertEqual(try store.restoreMissing(), [item.path])
        XCTAssertEqual(try String(contentsOf: file), "first")
        for value in ["second", "third", "fourth"] {
            try Data(value.utf8).write(to: file, options: .atomic)
            try store.refresh(file.path)
        }
        let versions = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("store/vault/\(item.id)").path)
        XCTAssertEqual(versions.count, 3)
        try FileManager.default.removeItem(at: file)
        _ = try store.restoreMissing()
        XCTAssertEqual(try String(contentsOf: file), "fourth")
    }

    func testRefreshWithoutChangeKeepsHistory() throws {
        // The guardian calls refresh on every FSEvents change, including the one its own vault clone causes.
        let (root, store) = try fixture()
        let folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sub/data.txt")
        try Data("v1".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "sub/data.txt")
        let item = try store.guardItem(folder.path, by: "test")
        let versions = root.appendingPathComponent("store/vault/\(item.id)").path
        for _ in 0..<3 { try store.refresh(file.path) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: versions).count, 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" v2".utf8)); try handle.close()
        for _ in 0..<3 { try store.refresh(file.path) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: versions).count, 2)
        try FileManager.default.removeItem(at: file)
        _ = try store.restoreMissing()
        try store.refresh(folder.path) // restoring the latest copy is not a change either
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: versions).count, 2)
        XCTAssertEqual(try String(contentsOf: file), "v1 v2")
    }

    func testSameSizeInPlaceRewriteWithRestoredMtimeGetsNewVersion() throws {
        let (root, store) = try fixture()
        let file = root.appendingPathComponent("rewritten.txt")
        try Data("old bytes".utf8).write(to: file)
        var initial = stat()
        XCTAssertEqual(stat(file.path, &initial), 0)
        var savedTimes = [timeval(tv_sec: initial.st_atimespec.tv_sec, tv_usec: Int32(initial.st_atimespec.tv_nsec / 1_000)),
                          timeval(tv_sec: initial.st_mtimespec.tv_sec, tv_usec: Int32(initial.st_mtimespec.tv_nsec / 1_000))]
        XCTAssertEqual(utimes(file.path, &savedTimes), 0)
        let item = try store.guardItem(file.path, by: "test")
        let versions = root.appendingPathComponent("store/vault/\(item.id)")
        let before = try FileManager.default.contentsOfDirectory(atPath: versions.path)
        let fd = open(file.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        if fd >= 0 {
            XCTAssertEqual("new bytes".withCString { write(fd, $0, 9) }, 9)
            XCTAssertEqual(close(fd), 0)
        }
        XCTAssertEqual(utimes(file.path, &savedTimes), 0)
        let vaultCopy = versions.appendingPathComponent(try XCTUnwrap(before.first))
        XCTAssertEqual(try ProtectionStore.fingerprint(file.path), try ProtectionStore.fingerprint(vaultCopy.path),
                       "fixture must defeat the old fast fingerprint")
        XCTAssertTrue(try store.refresh(file.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: versions.path).count, 2)
        try FileManager.default.removeItem(at: file)
        _ = try store.restoreMissing()
        XCTAssertEqual(try String(contentsOf: file), "new bytes")
        XCTAssertFalse(try store.refresh(file.path), "restore must not create another version")
    }

    func testHealthDoesNotFollowASymlinkThatReplacedTheItem() throws {
        let (root, store) = try fixture()
        let folder = root.appendingPathComponent("work")
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let item = try store.guardItem(folder.path, by: "test")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(atPath: folder.path, withDestinationPath: elsewhere.path)
        XCTAssertEqual(store.health(item.id), .itemMissing(restorable: false))
    }

    func testRefreshStartsANewHistoryWhenTheVaultCopyIsGone() throws {
        let (root, store) = try fixture()
        let file = root.appendingPathComponent("guarded.txt")
        try Data("kept".utf8).write(to: file)
        let item = try store.guardItem(file.path, by: "test")
        let base = root.appendingPathComponent("store/vault/\(item.id)")
        try ProtectionACL.stripFixtureEntries(in: root.appendingPathComponent("store").path)
        for version in try FileManager.default.contentsOfDirectory(atPath: base.path) {
            try FileManager.default.removeItem(at: base.appendingPathComponent(version))
        }
        XCTAssertEqual(store.health(item.id), .vaultMissing)
        try store.refresh(file.path)
        XCTAssertEqual(store.health(item.id), .intact)
    }

    func testGuardFolderRestoresNestedFile() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("data.txt")
        try Data("kept".utf8).write(to: file)
        let item = try store.guardItem(folder.path, by: "test")
        defer { try? remove(item, from: store) }
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try store.restoreMissing(), [(item.path as NSString).appendingPathComponent("nested/data.txt")])
        XCTAssertEqual(try String(contentsOf: file), "kept")
        XCTAssertEqual(store.health(item.id), .intact)
    }

    func testLockHealthDetectsStrippedACL() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("locked.txt")
        try Data("x".utf8).write(to: file)
        let item = try store.lock(file.path, by: "test")
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-a", "everyone deny delete", file.path]
        try chmod.run(); chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        XCTAssertEqual(store.health(item.id), .aclMissing)
        try remove(item, from: store)
    }

    func testFolderHealthDetectsStrippedNestedACL() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let item = try store.lock(folder.path, by: "test")
        defer { try? remove(item, from: store) }
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-a", "everyone deny delete,delete_child,file_inherit,directory_inherit", nested.path]
        try chmod.run(); chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        XCTAssertEqual(store.health(item.id), .aclMissing)
    }

    func testLaunchItemsCannotBeProtected() throws {
        let (root, store) = try fixture()
        let agents = root.appendingPathComponent("home/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("com.example.evil.plist")
        try Data("<plist/>".utf8).write(to: plist)
        for attempt in [{ try store.guardItem(plist.path, by: "mcp:test") }, { try store.guardItem(agents.path, by: "mcp:test") },
                        { try store.lock(plist.path, by: "mcp:test") }] {
            XCTAssertThrowsError(try attempt()) { error in
                XCTAssertTrue(error.localizedDescription.contains("Launch and login items"), "\(error)")
            }
        }
        XCTAssertEqual(store.items(), [])
    }

    func testOwnerOnlyTargetsRefuseEveryoneButTheApp() throws {
        let (root, store) = try fixture()
        let fm = FileManager.default
        let home = root.appendingPathComponent("home")
        func file(_ url: URL) throws -> URL {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            return url
        }
        let key = try file(home.appendingPathComponent(".ssh/id_ed25519"))
        let zshrc = try file(home.appendingPathComponent(".zshrc"))
        let fishConfig = try file(home.appendingPathComponent(".config/fish/config.fish"))
        let plist = try file(root.appendingPathComponent("Tool.app/Contents/Info.plist"))
        // A dotfile symlinked from a repo (GNU Stow): the name in home is what makes it a startup file.
        let dotfile = try file(root.appendingPathComponent("dotfiles/bashrc"))
        let bashrc = home.appendingPathComponent(".bashrc")
        try fm.createSymbolicLink(at: bashrc, withDestinationURL: dotfile)
        let bashLogin = try file(home.appendingPathComponent(".bash_login"))
        // ~/.ssh kept in a repo and linked into home: the real location is owner-only too.
        let realSSH = try file(root.appendingPathComponent("dotfiles/ssh/config"))
        try fm.moveItem(at: key, to: realSSH.deletingLastPathComponent().appendingPathComponent("id_ed25519"))
        try fm.removeItem(at: key.deletingLastPathComponent())
        try fm.createSymbolicLink(at: key.deletingLastPathComponent(), withDestinationURL: realSSH.deletingLastPathComponent())
        let targets = [key, key.deletingLastPathComponent(), realSSH, realSSH.deletingLastPathComponent(),
                       dotfile, dotfile.deletingLastPathComponent(), bashLogin, zshrc, bashrc, fishConfig,
                       fishConfig.deletingLastPathComponent(), home.appendingPathComponent(".config"),
                       plist, root.appendingPathComponent("Tool.app")]
        for target in targets {
            for attempt in [{ try store.lock(target.path, by: "mcp:test") }, { try store.guardItem(target.path, by: "cli") }] {
                XCTAssertThrowsError(try attempt(), target.path) { error in
                    XCTAssertTrue(error.localizedDescription.contains("只能在 Hoard app 裡由你本人保護"), "\(error)")
                }
            }
        }
        XCTAssertEqual(store.items(), [])
        // The owner, in the app, may protect them; launch items stay refused even there.
        let locked = try store.lock(key.path, by: "app")
        let guarded = try store.guardItem(zshrc.path, by: "app")
        XCTAssertEqual(Set(store.items().map(\.id)), [locked.id, guarded.id])
        let agent = try file(root.appendingPathComponent("home/LaunchAgents-not/notes.txt"))
        XCTAssertNoThrow(try store.lock(agent.path, by: "mcp:test"), "an ordinary file stays open to agents")
        let launch = try file(home.appendingPathComponent("Library/LaunchAgents/com.example.plist"))
        XCTAssertThrowsError(try store.lock(launch.path, by: "app")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Launch and login items"), "\(error)")
        }
    }

    func testGuardSkipsTransientFilesAndKeepsSymlinks() throws {
        let (root, store) = try fixture()
        let folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["real.txt", ".real.txt.swp", ".DS_Store", "notes.txt~"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "real.txt")
        let item = try store.guardItem(folder.path, by: "test")
        for name in ["real.txt", ".real.txt.swp", ".DS_Store", "notes.txt~", "link"] {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        let restored = try store.restoreMissing().map { ($0 as NSString).lastPathComponent }.sorted()
        XCTAssertEqual(restored, ["link", "real.txt"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link").path), "real.txt")
        XCTAssertEqual(store.health(item.id), .intact)
    }

    func testRestoreNeverWritesThroughASymlink() throws {
        let (root, store) = try fixture()
        let fm = FileManager.default
        let folder = root.appendingPathComponent("work")
        let sub = folder.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("top".utf8).write(to: folder.appendingPathComponent("top.txt"))
        try Data("nested".utf8).write(to: sub.appendingPathComponent("nested.txt"))
        _ = try store.guardItem(folder.path, by: "test")
        let other = root.appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)

        // A folder inside the guarded tree replaced by a link to another folder.
        try fm.removeItem(at: sub)
        try fm.createSymbolicLink(at: sub, withDestinationURL: other)
        try fm.removeItem(at: folder.appendingPathComponent("top.txt"))
        XCTAssertThrowsError(try store.restoreMissing()) { error in
            XCTAssertTrue(error.localizedDescription.contains("replaced by a symlink"), "\(error)")
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: other.path), [])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("top.txt")), "top", "siblings still restored")
        XCTAssertThrowsError(try store.refresh(folder.appendingPathComponent("top.txt").path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("replaced by a symlink"), "\(error)")
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: other.path), [])

        // The guarded folder itself replaced by a link. (refresh resolves the link to `other`, which is
        // not guarded, so it does nothing.)
        try fm.removeItem(at: folder)
        try fm.createSymbolicLink(at: folder, withDestinationURL: other)
        XCTAssertThrowsError(try store.restoreMissing()) { error in
            XCTAssertTrue(error.localizedDescription.contains("replaced by a symlink"), "\(error)")
        }
        try store.refresh(folder.path)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: other.path), [])
    }

    func testRestoreRebuildsMissingParentFolders() throws {
        let (root, store) = try fixture()
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appendingPathComponent("data.db")
        try Data("rows".utf8).write(to: file)
        let item = try store.guardItem(file.path, by: "test")
        try FileManager.default.removeItem(at: work)
        XCTAssertEqual(try store.restoreMissing(), [item.path])
        XCTAssertEqual(try String(contentsOf: file), "rows")
    }

    func testRestoreDoesNotRebuildParentsThroughASymlink() throws {
        let (root, store) = try fixture()
        let fm = FileManager.default
        let work = root.appendingPathComponent("work")
        let sub = work.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("data.db")
        try Data("rows".utf8).write(to: file)
        _ = try store.guardItem(file.path, by: "test")
        let other = root.appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try fm.removeItem(at: work)
        try fm.createSymbolicLink(at: work, withDestinationURL: other)
        XCTAssertThrowsError(try store.restoreMissing()) { error in
            XCTAssertTrue(error.localizedDescription.contains("symlink"), "\(error)")
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: other.path), [])
    }

    func testRepairRestoresStrippedLockWithoutHumanToken() throws {
        let (root, store) = try fixture()
        let folder = root.appendingPathComponent("folder")
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let item = try store.lock(folder.path, by: "test")
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-a", "everyone deny delete,delete_child,file_inherit,directory_inherit", nested.path]
        try chmod.run(); chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        let unguarded = nested.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: unguarded)
        XCTAssertEqual(unlink(unguarded.path), 0) // the strip really opened a hole
        let file = nested.appendingPathComponent("b.txt")
        try Data("x".utf8).write(to: file)
        try store.repair(item.id)
        XCTAssertEqual(store.health(item.id), .intact)
        XCTAssertEqual(unlink(file.path), -1)
        XCTAssertTrue(errno == EPERM || errno == EACCES)
        try store.repair(item.id) // repairing an intact item changes nothing
        XCTAssertEqual(store.health(item.id), .intact)
    }

    func testRepairRelocksGuardVault() throws {
        let (root, store) = try fixture()
        let file = root.appendingPathComponent("guarded.txt")
        try Data("kept".utf8).write(to: file)
        let item = try store.guardItem(file.path, by: "test")
        let vault = root.appendingPathComponent("store/vault")
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-a", "everyone deny delete,delete_child", vault.path]
        try chmod.run(); chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        XCTAssertEqual(store.health(item.id), .aclMissing)
        try store.repair(item.id)
        XCTAssertEqual(store.health(item.id), .intact)
    }

    func testRefusals() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try store.lock("/", by: "test"))
        XCTAssertThrowsError(try store.lock("/System", by: "test"))
        XCTAssertThrowsError(try store.lock(root.appendingPathComponent("store").path, by: "test"))
        let file = root.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        let item = try store.lock(file.path, by: "test")
        defer { try? remove(item, from: store) }
        XCTAssertThrowsError(try store.lock(file.path, by: "test"))
    }

    func testTwoStoreInstancesKeepBothRegistrations() throws {
        let (root, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store")
        let homeURL = root.appendingPathComponent("home")
        let second = ProtectionStore(directory: storeURL, home: homeURL)
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let firstItem = try first.lock(a.path, by: "test")
        let secondItem = try second.guardItem(b.path, by: "test")
        let ids = Set([firstItem.id, secondItem.id])
        XCTAssertEqual(Set(first.items().map(\.id)), ids)
        XCTAssertEqual(Set(second.items().map(\.id)), ids)
        XCTAssertEqual(Set(ProtectionStore(directory: storeURL, home: homeURL).items().map(\.id)), ids)
        try remove(firstItem, from: first)
        try remove(secondItem, from: second)
    }

    func testReadsDoNotCreateMissingStore() throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("missing-store")
        let store = ProtectionStore(directory: directory, home: root.appendingPathComponent("home"))
        XCTAssertEqual(store.items(), [])
        XCTAssertNil(store.item(covering: root.path))
        XCTAssertEqual(store.health("missing"), .itemMissing(restorable: false))
        XCTAssertEqual(try store.restoreMissing(), [])
        try store.refresh(root.appendingPathComponent("missing").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testHomeAndSystemPathRefusalsAndLibraryGuard() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let library = home.appendingPathComponent("Library")
        let app = library.appendingPathComponent("Example")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let file = app.appendingPathComponent("state")
        try Data("saved".utf8).write(to: file)
        for path in [home.path, root.path, library.path, "/Applications", "/Library", "/usr",
                     "/opt", "/private", "/Volumes", "/private/var", "/private/etc", "/private/tmp",
                     "/var", "/etc", "/tmp"] {
            XCTAssertThrowsError(try store.validateProtectedPath(path, kind: .lock, by: "app"), path)
        }
        XCTAssertThrowsError(try store.validateProtectedPath(library.path, kind: .guarded, by: "app"))
        XCTAssertThrowsError(try store.lock(home.path, by: "test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store").path))
        XCTAssertThrowsError(try store.lock(file.path, by: "test"))
        let guarded = try store.guardItem(file.path, by: "test")
        XCTAssertEqual(store.health(guarded.id), .intact)
        try remove(guarded, from: store)
    }

    func testRestoreAttemptsLaterItemsAndReportsPartialResult() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var items: [ProtectedItem] = []
        for name in ["first", "broken", "last"] {
            let file = root.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            items.append(try store.guardItem(file.path, by: "test"))
        }
        defer { for item in items { try? remove(item, from: store) } }
        let brokenBase = root.appendingPathComponent("store/vault/\(items[1].id)")
        let version = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: brokenBase, includingPropertiesForKeys: nil).first)
        for (path, rule) in [(brokenBase.path, "everyone deny delete,delete_child"),
                             (version.path, "everyone deny delete")] {
            let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-a", rule, path]
            try chmod.run(); chmod.waitUntilExit()
            XCTAssertEqual(chmod.terminationStatus, 0)
        }
        try FileManager.default.removeItem(at: version)
        for item in items { try FileManager.default.removeItem(atPath: item.path) }
        XCTAssertThrowsError(try store.restoreMissing()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains(items[0].path))
            XCTAssertTrue(message.contains(items[1].path))
            XCTAssertTrue(message.contains(items[2].path))
            XCTAssertTrue(message.contains("vault copy missing"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: items[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[2].path))
    }

    func testFolderSizeCeilingsBeforeStoreACL() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(ProtectionStore.maximumLockDirectories, 5_000)
        XCTAssertEqual(ProtectionStore.maximumGuardEntries, 20_000)
        let lockFolder = root.appendingPathComponent("too-many-dirs")
        try FileManager.default.createDirectory(at: lockFolder, withIntermediateDirectories: true)
        for index in 0...5_000 {
            try FileManager.default.createDirectory(at: lockFolder.appendingPathComponent("d\(index)"), withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try store.lock(lockFolder.path, by: "test")) { error in
            XCTAssertTrue(error.localizedDescription.contains("5,000 directories"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store").path))

        let guardFolder = root.appendingPathComponent("too-many-entries")
        try FileManager.default.createDirectory(at: guardFolder, withIntermediateDirectories: true)
        for index in 0...20_000 {
            let path = guardFolder.appendingPathComponent("f\(index)").path
            let fd = open(path, O_CREAT | O_WRONLY, mode_t(0o600))
            XCTAssertGreaterThanOrEqual(fd, 0)
            if fd >= 0 { close(fd) }
        }
        XCTAssertThrowsError(try store.guardItem(guardFolder.path, by: "test")) { error in
            XCTAssertTrue(error.localizedDescription.contains("20,000 entries"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store").path))
    }

    func testGuardRefusesItemsOverTheByteCeiling() throws {
        let (root, store) = try fixture()
        XCTAssertEqual(ProtectionStore.maximumGuardBytes, 5_000_000_000)
        store.guardByteCeiling = 1_000
        let big = root.appendingPathComponent("big.bin")
        try Data(count: 2_000).write(to: big)
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data(count: 600).write(to: folder.appendingPathComponent("a.bin"))
        try Data(count: 600).write(to: folder.appendingPathComponent("nested/b.bin"))
        for target in [big, folder] {
            XCTAssertThrowsError(try store.guardItem(target.path, by: "test"), target.path) { error in
                XCTAssertTrue(error.localizedDescription.contains("guard is for working files; lock large finished files instead"), "\(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store").path))
        let small = root.appendingPathComponent("small.txt")
        try Data(count: 1_000).write(to: small)
        XCTAssertNoThrow(try store.guardItem(small.path, by: "test"))
        XCTAssertNoThrow(try store.lock(big.path, by: "test"), "lock has no byte ceiling")
    }

    func testGuardableCheckRefusesWhatGuardRefusesAndWritesNothing() throws {
        let (root, store) = try fixture()
        store.guardByteCeiling = 1_000
        let big = root.appendingPathComponent("big.bin")
        try Data(count: 2_000).write(to: big)
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 600).write(to: folder.appendingPathComponent("a.bin"))
        try Data(count: 600).write(to: folder.appendingPathComponent("b.bin"))
        let small = root.appendingPathComponent("small.txt")
        try Data(count: 1_000).write(to: small)
        for target in [big, folder] {
            XCTAssertThrowsError(try store.checkGuardable(target.path), target.path) { error in
                XCTAssertTrue(error.localizedDescription.contains("guard is for working files; lock large finished files instead"), "\(error)")
            }
        }
        XCTAssertThrowsError(try store.checkGuardable(root.appendingPathComponent("missing").path)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Path does not exist"), "\(error)")
        }
        XCTAssertNoThrow(try store.checkGuardable(small.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store").path), "checking writes nothing")
    }

    func testNewGuardVersionNeedsFreeSpaceAndKeepsPreviousOnes() throws {
        let (root, store) = try fixture()
        XCTAssertNotNil(ProtectionStore.statfsSpace(root.path))
        let file = root.appendingPathComponent("guarded.txt")
        try Data("first".utf8).write(to: file)
        let item = try store.guardItem(file.path, by: "test")
        let versionsDir = root.appendingPathComponent("store/vault/\(item.id)").path
        let before = try FileManager.default.contentsOfDirectory(atPath: versionsDir)
        try Data("second".utf8).write(to: file)
        let gb: Int64 = 1_000_000_000
        // Under 10 GB; under 5% of a 1 TB volume; free space unreadable.
        for space in [(free: 9 * gb, total: 100 * gb), (free: 40 * gb, total: 1_000 * gb)] as [(free: Int64, total: Int64)?] + [nil] {
            store.volumeSpace = { _ in space }
            XCTAssertThrowsError(try store.refresh(file.path), "\(String(describing: space))") { error in
                XCTAssertTrue(error.localizedDescription.lowercased().contains("free space"), "\(error)")
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: versionsDir), before)
        }
        let other = root.appendingPathComponent("other.txt")
        try Data("x".utf8).write(to: other)
        store.volumeSpace = { _ in (free: 9 * gb, total: 100 * gb) }
        XCTAssertThrowsError(try store.guardItem(other.path, by: "test")) { error in
            XCTAssertTrue(error.localizedDescription.contains("not enough free space for a new guard version"), "\(error)")
        }
        XCTAssertEqual(store.items(), [item])
        store.volumeSpace = { _ in (free: 60 * gb, total: 1_000 * gb) }
        try store.refresh(file.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: versionsDir).count, 2)
        try FileManager.default.removeItem(at: file)
        _ = try store.restoreMissing()
        XCTAssertEqual(try String(contentsOf: file), "second")
    }

    func testRefreshRefusesFileThatGrewPastCeilingAndKeepsVersions() throws {
        let (root, store) = try fixture()
        store.guardByteCeiling = 10
        let file = root.appendingPathComponent("growing.txt")
        try Data("small".utf8).write(to: file)
        let item = try store.guardItem(file.path, by: "test")
        let versions = root.appendingPathComponent("store/vault/\(item.id)")
        let before = try FileManager.default.contentsOfDirectory(atPath: versions.path)
        try Data(repeating: 65, count: 11).write(to: file)
        XCTAssertThrowsError(try store.refresh(file.path)) { error in
            XCTAssertEqual(error.localizedDescription,
                           "guard is for working files: \(item.path) grew past 5 GB; existing versions stay")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: versions.path), before)
    }

    func testDamagedRegistryKeepsLastGoodCopyAndReportsIt() throws {
        let (root, store) = try fixture()
        let file = root.appendingPathComponent("locked.txt")
        try Data("x".utf8).write(to: file)
        let item = try store.lock(file.path, by: "test")
        XCTAssertEqual(store.items(), [item])
        XCTAssertNil(store.readError)
        // An in-place write still works inside the locked store, so damage it that way.
        try Data("{not json".utf8).write(to: root.appendingPathComponent("store/registry.json"))
        XCTAssertEqual(store.items(), [item])
        XCTAssertEqual(store.item(covering: file.path), item)
        XCTAssertNotNil(store.readError)
        let fresh = ProtectionStore(directory: root.appendingPathComponent("store"), home: root.appendingPathComponent("home"))
        XCTAssertEqual(fresh.items(), [])
        XCTAssertNotNil(fresh.readError)
    }

}
