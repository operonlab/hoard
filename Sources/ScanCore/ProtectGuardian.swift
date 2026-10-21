import CoreServices
import Darwin
import Foundation

public enum GuardianAction: Equatable, Sendable {
    case restored(String)
    case refreshed(String)
    case failed(String, String)
}

/// Keeps guarded items in place: restores a deleted one from the vault and refreshes the vault copy
/// after an edit. Lock items are left alone — a stripped lock ACL is reported by `ProtectionStore.health`
/// and never re-applied, because a human may have removed it on purpose.
/// `onAction` runs on the guardian's own queue. Call `stop()` before releasing the guardian.
public final class ProtectionGuardian {
    static let latency: CFTimeInterval = 1.0
    // ponytail: polls the registry every 2 s because ProtectionStore keeps its directory private;
    // switch to an FSEvents watch on registry.json once the store exposes that path.
    static let registryPoll: DispatchTimeInterval = .seconds(2)

    private let store: ProtectionStore
    private let onAction: (GuardianAction) -> Void
    private let queue = DispatchQueue(label: "Hoard.ProtectionGuardian")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var guarded: [ProtectedItem] = []
    private var watchedRoots: [String] = []
    private var lastRegistryError: String?
    private var reportedSymlinks = Set<String>()
    private var running = false

    public init(store: ProtectionStore, onAction: @escaping (GuardianAction) -> Void) {
        self.store = store
        self.onAction = onAction
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    public func start() throws {
        try onQueue {
            guard !running else { return }
            do { try store.relockStore() }
            catch { emit(.failed("store", error.localizedDescription)) }
            guarded = currentGuarded()
            try retarget()
            running = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.registryPoll, repeating: Self.registryPoll)
            timer.setEventHandler { [weak self] in self?.pollRegistry() }
            timer.resume()
            self.timer = timer
            // Items deleted while no guardian was running produce no event; catch them up once.
            queue.async { [weak self] in
                guard let self, self.running else { return }
                let missing = self.guarded.first { self.rootState($0.path) == .missing }?.path
                for item in self.guarded { _ = self.reportRootState(item) }
                self.restorePass(trigger: missing ?? "startup")
            }
        }
    }

    public func stop() {
        onQueue {
            running = false
            timer?.cancel()
            timer = nil
            close(stream)
            stream = nil
            watchedRoots = []
        }
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        DispatchQueue.getSpecific(key: queueKey) == true ? try body() : try queue.sync(execute: body)
    }

    private func currentGuarded() -> [ProtectedItem] {
        store.items().filter { $0.kind == .guarded }
    }

    private enum RootState: Equatable { case present, missing, symlink }

    private func rootState(_ path: String) -> RootState {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        return (st.st_mode & S_IFMT) == S_IFLNK ? .symlink : .present
    }

    @discardableResult private func reportRootState(_ item: ProtectedItem) -> RootState {
        let state = rootState(item.path)
        if state == .symlink {
            if reportedSymlinks.insert(item.path).inserted {
                emit(.failed(item.path, "replaced by a symlink; not restored through it"))
            }
        } else {
            reportedSymlinks.remove(item.path)
        }
        return state
    }

    private func emit(_ action: GuardianAction) { onAction(action) }

    /// Parent folders of the guarded items, so deleting an item itself is an event inside a watched tree.
    static func watchRoots(for items: [ProtectedItem]) -> [String] {
        let parents = Set(items.map { ($0.path as NSString).deletingLastPathComponent }).sorted()
        return parents.filter { root in !parents.contains { root != $0 && root.hasPrefix($0 == "/" ? "/" : $0 + "/") } }
    }

    static func covers(_ item: ProtectedItem, _ path: String) -> Bool {
        path == item.path || (item.isDirectory && path.hasPrefix(item.path + "/"))
    }

    private func retarget() throws {
        let roots = Self.watchRoots(for: guarded)
        guard roots != watchedRoots || (stream == nil && !roots.isEmpty) else { return }
        // Open the new stream before closing the old one so no event falls in between.
        let replacement: FSEventStreamRef? = try roots.isEmpty ? nil : open(roots)
        close(stream)
        stream = replacement
        watchedRoots = roots
    }

    private func open(_ roots: [String]) throws -> FSEventStreamRef {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let guardian = Unmanaged<ProtectionGuardian>.fromOpaque(info).takeUnretainedValue()
            guardian.receive(count: count, paths: paths, flags: flags)
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags) else {
            throw ProtectionError.command("Cannot create the FSEvents stream for guarded items")
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw ProtectionError.command("Cannot start the FSEvents stream for guarded items")
        }
        return created
    }

    private func close(_ stream: FSEventStreamRef?) {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func receive(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) {
        guard running else { return }
        let cfPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) |
            FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) |
            FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        var events: [(String, Bool)] = []
        for i in 0..<count {
            let path = unsafeBitCast(CFArrayGetValueAtIndex(cfPaths, i), to: CFString.self) as String
            events.append((path, flags[i] & rescanFlags != 0))
        }
        handle(events)
    }

    func handle(_ events: [(path: String, rescan: Bool)]) {
        if guarded.isEmpty { guarded = currentGuarded() }
        var touched: [String: ProtectedItem] = [:]
        var rootMissing = Set<String>()
        var missing: [String] = []
        for (path, rescan) in events {
            for item in guarded {
                let probe: String
                if Self.covers(item, path) { probe = path }
                else if rescan && (item.path.hasPrefix(path + "/") || path == "/") { probe = item.path }
                else { continue }
                let state = reportRootState(item)
                if state == .symlink { continue }
                touched[item.id] = item
                if state == .missing { rootMissing.insert(item.id); missing.append(item.path) }
                else if rootState(probe) == .missing { missing.append(probe) }
            }
        }
        if let trigger = missing.sorted().first { restorePass(trigger: trigger) }
        // refresh() restores missing children before it snapshots, and a vanished temp file from an
        // atomic save sits next to a real edit, so touched folders are refreshed even after a restore.
        // An item whose root was gone now holds exactly its latest copy; there is nothing new to save.
        for item in touched.values.sorted(by: { $0.path < $1.path }) where !rootMissing.contains(item.id) {
            guard reportRootState(item) == .present else { continue }
            do {
                if try store.refresh(item.path) { emit(.refreshed(item.path)) }
            } catch {
                emit(.failed(item.path, error.localizedDescription))
            }
        }
    }

    private func restorePass(trigger: String) {
        do {
            let replaced = Set(guarded.filter { reportRootState($0) == .symlink }.map(\.path))
            for path in try store.restoreMissing(excluding: replaced) { emit(.restored(path)) }
        } catch {
            emit(.failed(trigger, error.localizedDescription))
        }
    }

    private func pollRegistry() {
        guard running else { return }
        let latest = currentGuarded()
        if let error = store.readError {
            if error != lastRegistryError { emit(.failed("registry", error)) }
            lastRegistryError = error
            return
        }
        lastRegistryError = nil
        for item in latest { _ = reportRootState(item) }
        guard latest.map({ [$0.id, $0.path] }) != guarded.map({ [$0.id, $0.path] }) else { return }
        guarded = latest
        do {
            try retarget()
        } catch {
            emit(.failed("registry", error.localizedDescription))
        }
    }
}
