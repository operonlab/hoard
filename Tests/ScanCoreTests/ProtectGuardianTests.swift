import Foundation
@testable import ScanCore
import XCTest

final class ProtectGuardianTests: XCTestCase {
    private final class ActionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [GuardianAction] = []
        func append(_ action: GuardianAction) { lock.lock(); actions.append(action); lock.unlock() }
        var all: [GuardianAction] { lock.lock(); defer { lock.unlock() }; return actions }
        func refreshes(_ path: String) -> Int { all.filter { $0 == .refreshed(path) }.count }
    }

    private func makeRoot() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("guardian-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: raw.resolvingSymlinksInPath().path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        addTeardownBlock {
            // The store puts deny-delete ACLs on the vault; strip them inside this temp root only.
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-R", "-N", raw.path]
            try? chmod.run()
            chmod.waitUntilExit()
            try? FileManager.default.removeItem(at: raw)
        }
        return root
    }

    private func store(_ root: URL) -> ProtectionStore {
        ProtectionStore(directory: root.appendingPathComponent("store"), home: root.appendingPathComponent("home"))
    }

    private func wait(_ timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func startOrSkipUnavailableFSEvents(_ guardian: ProtectionGuardian) throws {
        do { try guardian.start() }
        catch {
            guard error.localizedDescription.contains("Cannot start the FSEvents stream") else { throw error }
            throw XCTSkip("FSEvents stream cannot start in this sandbox")
        }
    }

    func testRestoresDeletedFileAndKeepsTheLatestEdit() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("work/notes.txt")
        let original = Data("first version\n".utf8), edited = Data("edited version\n".utf8)
        try original.write(to: file)
        let store = store(root)
        let item = try store.guardItem(file.path, by: "test")
        let log = ActionLog()
        let guardian = ProtectionGuardian(store: store) { log.append($0) }
        try startOrSkipUnavailableFSEvents(guardian)
        defer { guardian.stop() }

        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(wait { (try? Data(contentsOf: file)) == original }, "deleted file not restored: \(log.all)")
        XCTAssertTrue(log.all.contains(.restored(item.path)), "\(log.all)")
        // The restore (and the vault clone) are FSEvents changes too. Putting back the latest copy is not an
        // edit, so it must not take a version: an earlier build refreshed about once a second forever and
        // pushed the real history out of the vault. Three latency periods are enough for those events to land.
        Thread.sleep(forTimeInterval: 3 * ProtectionGuardian.latency)
        XCTAssertEqual(log.refreshes(item.path), 0, "a restore or a vault clone was taken as an edit: \(log.all)")

        let before = log.refreshes(item.path)
        try edited.write(to: file, options: .atomic)
        XCTAssertTrue(wait { log.refreshes(item.path) > before }, "edit not refreshed: \(log.all)")
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(wait { (try? Data(contentsOf: file)) == edited }, "edited bytes not restored: \(log.all)")
        XCTAssertFalse(log.all.contains { if case .failed = $0 { return true }; return false }, "\(log.all)")
    }

    func testPicksUpItemsAddedByAnotherProcess() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("work/later.txt")
        let bytes = Data("added after start\n".utf8)
        try bytes.write(to: file)
        let log = ActionLog()
        let guardian = ProtectionGuardian(store: store(root)) { log.append($0) }
        try guardian.start()
        defer { guardian.stop() }

        // A second store on the same directory stands in for the app or another CLI process.
        let item = try store(root).guardItem(file.path, by: "other")
        if wait(3, { log.all.contains { if case .failed("registry", let reason) = $0 {
            return reason.contains("Cannot start the FSEvents stream")
        }; return false } }) {
            throw XCTSkip("FSEvents stream cannot start in this sandbox")
        }
        // The poll re-targets the stream onto work/; a refresh of the new item shows it is watched.
        XCTAssertTrue(wait {
            try? Data("added after start, edited\n".utf8).write(to: file, options: .atomic)
            return log.refreshes(item.path) >= 1
        }, "new item never watched: \(log.all)")
        let current = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(wait { (try? Data(contentsOf: file)) == current }, "new item not restored: \(log.all)")
    }

    func testReplacedGuardedFolderReportsSymlinkOnceAndNeverWritesThroughIt() throws {
        let root = try makeRoot()
        let folder = root.appendingPathComponent("work/guarded")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: folder.appendingPathComponent("note.txt"))
        let item = try store(root).guardItem(folder.path, by: "test")
        let log = ActionLog()
        let guardian = ProtectionGuardian(store: store(root)) { log.append($0) }

        try ProtectionACL.stripFixtureEntries(in: folder.path)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        XCTAssertEqual(store(root).items().count, 1)
        var replacement = stat()
        XCTAssertEqual(lstat(folder.path, &replacement), 0)
        XCTAssertEqual(replacement.st_mode & S_IFMT, S_IFLNK)
        guardian.handle([(path: item.path, rescan: false)])
        let expected = GuardianAction.failed(item.path, "replaced by a symlink; not restored through it")
        XCTAssertTrue(log.all.contains(expected), "symlink replacement not reported: \(log.all)")
        for index in 0..<3 {
            try Data("event".utf8).write(to: outside.appendingPathComponent("event-\(index)"))
            guardian.handle([(path: item.path, rescan: false)])
        }
        XCTAssertEqual(log.all.filter { $0 == expected }.count, 1, "duplicate symlink reports: \(log.all)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("note.txt").path))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guardian.handle([(path: item.path, rescan: false)])
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        guardian.handle([(path: item.path, rescan: false)])
        XCTAssertEqual(log.all.filter { $0 == expected }.count, 2, "a new replacement needs a new report")
    }

    func testStartRelocksAnInterruptedStore() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("work/notes.txt")
        try Data("safe".utf8).write(to: file)
        let store = store(root)
        let item = try store.guardItem(file.path, by: "test")
        try ProtectionACL.stripFixtureEntries(in: root.appendingPathComponent("store").path)
        let base = root.appendingPathComponent("store/vault/\(item.id)")
        let version = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).first)
        try ProtectionACL.change(base.path, directory: true, add: true)
        try ProtectionACL.change(version.path, directory: false, add: true)
        XCTAssertEqual(store.health(item.id), .aclMissing)
        let log = ActionLog()
        let guardian = ProtectionGuardian(store: store) { log.append($0) }
        // FSEventStreamStart is unavailable in some test sandboxes; ACL repair precedes it.
        do { try guardian.start() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Cannot start the FSEvents stream"), "\(error)") }
        guardian.stop()
        XCTAssertEqual(store.health(item.id), .intact, "startup did not relock the store: \(log.all)")
    }

    func testStartWithMissingStoreDoesNotCreateIt() throws {
        let root = try makeRoot()
        let storePath = root.appendingPathComponent("store")
        let guardian = ProtectionGuardian(store: store(root)) { _ in }
        try guardian.start()
        guardian.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: storePath.path))
    }

    func testAppCanRenderWhileGuardianWaitsForRegistryLock() throws {
        if ProcessInfo.processInfo.environment["CODEX_SANDBOX"] == "seatbelt" {
            throw XCTSkip("HoardApp cannot connect to WindowServer in this sandbox")
        }
        let root = try makeRoot()
        let file = root.appendingPathComponent("work/guarded.txt")
        try Data("safe".utf8).write(to: file)
        _ = try store(root).guardItem(file.path, by: "test")
        let lockPath = root.appendingPathComponent("store/registry.lock").path
        let fd = open(lockPath, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)

        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = repo.appendingPathComponent(".build/debug/HoardApp")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        let image = root.appendingPathComponent("render.png")
        let app = Process()
        app.executableURL = binary
        app.arguments = ["--render-to", image.path, "--render-after", "1", "--fresh",
                         "--protection-store", root.appendingPathComponent("store").path]
        app.standardOutput = FileHandle.nullDevice
        app.standardError = FileHandle.nullDevice
        defer {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            if app.isRunning { app.terminate() }
            app.waitUntilExit()
        }
        try app.run()
        // Generous for a loaded machine. The flock is held for the whole test, so a main thread that
        // waits on it never renders, however long the deadline.
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: image.path) && app.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path),
                      "the main thread waited for the registry flock instead of rendering")
        let quitDeadline = Date().addingTimeInterval(30)
        while app.isRunning && Date() < quitDeadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(app.isRunning, "guardian stop blocked the main thread during quit")
    }
}
