// CONTRACT (FROZEN signatures): `LiveUpdater`, `UpdateSummary`.
// Threading: callbacks arrive on the main queue and the tree is mutated only there.

import CoreServices
import Darwin
import Foundation

public struct UpdateSummary: Sendable, Equatable {
    public var dirsRescanned: Int
    public var nodesAdded: Int
    public var nodesRemoved: Int
    public var bytesDelta: Int64
    /// The journal could not cover the gap (UUID changed, history dropped, root changed):
    /// the caller should run a full scan.
    public var requiresFullRescan: Bool
    public var latestEventId: UInt64

    public init(dirsRescanned: Int = 0, nodesAdded: Int = 0, nodesRemoved: Int = 0, bytesDelta: Int64 = 0,
                requiresFullRescan: Bool = false, latestEventId: UInt64 = 0) {
        self.dirsRescanned = dirsRescanned; self.nodesAdded = nodesAdded; self.nodesRemoved = nodesRemoved
        self.bytesDelta = bytesDelta; self.requiresFullRescan = requiresFullRescan; self.latestEventId = latestEventId
    }
}

public final class LiveUpdater {
    public let tree: FileTree
    public let scanner: Scanner
    public private(set) var lastEventId: UInt64

    /// - sinceEventId: replay changes after this id (from a snapshot), or nil to watch from now.
    /// - onChange: called on the main queue after each batch has been applied to `tree`.
    public init(tree: FileTree, scanner: Scanner, sinceEventId: UInt64?,
                onChange: @escaping (UpdateSummary) -> Void) {
        self.tree = tree
        self.scanner = scanner
        self.lastEventId = sinceEventId ?? 0
        self.onChange = onChange
    }

    private final class SummaryBox: @unchecked Sendable {
        var value: UpdateSummary
        init(_ value: UpdateSummary) { self.value = value }
    }

    private final class WeakUpdater: @unchecked Sendable {
        weak var value: LiveUpdater?
        init(_ value: LiveUpdater) { self.value = value }
    }

    private struct EventBatch {
        var paths: [(String, Bool)]
        var id: UInt64
        var invalid: Bool
        var historyDone = false
    }

    private let onChange: (UpdateSummary) -> Void
    /// Called on the main queue once every event recorded before `start()` (since `sinceEventId`)
    /// has been applied. Only fires when started from a snapshot's event id, not "since now".
    public var onReplayFinished: (() -> Void)?
    /// Utility: an update the user did not ask for stays out of the way of what they are doing.
    /// A caller that waits for the result in the foreground passes its own class (LiveUpdaterQoS.swift).
    var work = DispatchQueue(label: "Hoard.LiveUpdater.scan", qos: .utility)
    private var stream: FSEventStreamRef?
    private var realRoot = ""
    private var pending: [EventBatch] = []
    private var processing = false
    /// Folders of the batch being applied that are still to do (LiveUpdaterActivity.swift).
    var activeFolders = 0
    /// While a replay's history is still arriving, batches only queue: applied together at the end,
    /// each folder is listed once instead of once per batch that names it.
    private var holdingHistory = false
    /// Event ids a replay must cover (`lastEventId` at start to the current id then) and the newest one
    /// delivered so far: FSEvents reads its journal in id order, so their ratio tracks the replay.
    var historyFrom: UInt64 = 0, historyTo: UInt64 = 0, historySeen: UInt64 = 0, historyComplete = false
    private var generation = 0

    // Posting from deinit would hand observers an object being freed, so only `stop()` reports the 0.
    deinit { halt() }

    public func start() throws {
        precondition(Thread.isMainThread)
        guard stream == nil else { return }
        realRoot = Self.realPath(tree.rootPath) ?? tree.rootPath
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
                                           kFSEventStreamCreateFlagNoDefer |
                                           kFSEventStreamCreateFlagWatchRoot)
        let since = lastEventId == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : FSEventStreamEventId(lastEventId)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, ids in
            guard let info else { return }
            let updater = Unmanaged<LiveUpdater>.fromOpaque(info).takeUnretainedValue()
            updater.receive(count: count, paths: paths, flags: flags, ids: ids)
        }, &context, [tree.rootPath] as CFArray, since, 0.5, flags) else {
            throw LiveUpdaterError.cannotCreateStream
        }
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw LiveUpdaterError.cannotStartStream
        }
        stream = created
        generation += 1
        if lastEventId != 0 {
            holdingHistory = true
            historyFrom = lastEventId
            historyTo = FSEventsGetCurrentEventId()
            historySeen = lastEventId
            historyComplete = false
            // FSEvents ends a history with HistoryDone; if that never comes, apply what arrived.
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.historyWait) { [weak self] in
                guard let self, token == self.generation, self.holdingHistory else { return }
                self.holdingHistory = false
                self.runNext()
            }
        }
    }

    static let historyWait: TimeInterval = 30

    /// Tries again every folder currently marked unavailable (for example after Full Disk Access was
    /// granted). Readable ones are rescanned and grafted; the rest stay unavailable. Returns how many
    /// folders were queued. During a held replay, the retry joins history and runs at HistoryDone. Main queue only.
    @discardableResult
    public func retryUnavailable() -> Int {
        precondition(Thread.isMainThread)
        var paths: [(String, Bool)] = []
        for i in tree.nodes.indices {
            let n = tree.nodes[i]
            if n.isDirectory && !n.isRemoved && n.status == .unavailable && i != 0 {
                paths.append((tree.path(of: NodeID(i)), true))
            }
        }
        if !paths.isEmpty { applyDirectoryEvents(paths, eventId: lastEventId) }
        return paths.count
    }

    public func stop() {
        let wasActive = activeFolders != 0
        halt()
        if wasActive { NotificationCenter.default.post(name: Self.activityDidChange, object: self) }
    }

    private func halt() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        generation += 1
        pending.removeAll()
        processing = false
        holdingHistory = false
        activeFolders = 0
    }

    /// Current FSEvents id, to store in a snapshot taken now.
    public static func currentEventId() -> UInt64 { FSEventsGetCurrentEventId() }

    /// FSEventsCopyUUIDForDevice for the volume, as a string; nil when unavailable.
    public static func eventsUUID(forDevice dev: Int32) -> String? {
        guard let value = FSEventsCopyUUIDForDevice(dev) else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, value) as String
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func mapEventPath(_ path: String, rootPath: String, realRoot: String) -> String? {
        let root = realRoot.hasSuffix("/") ? String(realRoot.dropLast()) : realRoot
        let spelling = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        if path == root { return spelling }
        guard path.hasPrefix(root + "/") else { return nil }
        return spelling + path.dropFirst(root.count)
    }

    private func receive(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>,
                         ids: UnsafePointer<FSEventStreamEventId>) {
        precondition(Thread.isMainThread)
        let cfPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
        var items: [(String, Bool)] = []
        var maxID = lastEventId
        var invalid = false
        var historyDone = false
        for i in 0..<count {
            let flag = flags[i]
            maxID = max(maxID, ids[i])
            if flag & (FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) |
                       FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)) != 0 { invalid = true }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { historyDone = true; continue }
            let path = unsafeBitCast(CFArrayGetValueAtIndex(cfPaths, i), to: CFString.self) as String
            if let mapped = Self.mapEventPath(path, rootPath: tree.rootPath, realRoot: realRoot) {
                let full = flag & (FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) |
                                   FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) |
                                   FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)) != 0
                items.append((mapped, full))
            }
        }
        historySeen = max(historySeen, maxID)
        if historyDone { historyComplete = true }
        applyDirectoryEvents(items, eventId: maxID, invalid: invalid, historyDone: historyDone)
    }

    // Internal seam for deterministic directory-event tests; the FSEvents callback uses the same path.
    func applyDirectoryEvents(_ paths: [(String, Bool)], eventId: UInt64, invalid: Bool = false,
                              historyDone: Bool = false) {
        precondition(Thread.isMainThread)
        let batch = EventBatch(paths: paths, id: eventId, invalid: invalid, historyDone: historyDone)
        if invalid { pending = [batch] } else { pending.append(batch) }
        if holdingHistory {
            guard historyDone || invalid else { return }
            holdingHistory = false
        }
        runNext()
    }

    private func runNext() {
        guard !processing, !pending.isEmpty else { return }
        processing = true
        var batch = pending.removeFirst()
        // Batches that queued while the previous one was applied go as one: a relisting reads the folder
        // as it is now, so listing it once for all of them leaves the same tree. A replay of hours of
        // history arrives as thousands of batches that name the same folders again and again.
        while !batch.invalid, let next = pending.first, !next.invalid {
            pending.removeFirst()
            batch.paths += next.paths
            batch.id = max(batch.id, next.id)
            batch.historyDone = batch.historyDone || next.historyDone
        }
        if batch.paths.isEmpty && !batch.invalid {
            lastEventId = max(lastEventId, batch.id)
            processing = false
            if batch.historyDone { onReplayFinished?() }
            runNext()
            return
        }
        let token = generation
        if batch.invalid {
            pending.removeAll()
            processing = false
            stop()
            onChange(UpdateSummary(requiresFullRescan: true, latestEventId: lastEventId))
            return
        }
        var paths: [String: Bool] = [:]
        for (path, full) in batch.paths { paths[path] = (paths[path] ?? false) || full }
        // A path under a folder that is rescanned in full is covered by that rescan. Looking up each
        // ancestor keeps this linear in the number of paths; a whole replay can name 10^5 folders.
        let fullPaths = Set(paths.compactMap { $0.value ? $0.key : nil })
        let plans = paths.keys.sorted { $0.count < $1.count }.filter { path in
            guard !fullPaths.isEmpty else { return true }
            var ancestor = Substring(path)
            while let slash = ancestor.lastIndex(of: "/") {
                ancestor = ancestor[..<slash]
                if fullPaths.contains(String(ancestor)) { return false }
            }
            return true
        }.map { ($0, paths[$0]!) }
        let summary = SummaryBox(UpdateSummary(latestEventId: batch.id))
        let originalBytes = tree[0].totalAlloc
        func finish() {
            guard token == generation else { return }
            setActiveFolders(0)
            tree.releaseNameIndexes()
            summary.value.bytesDelta = tree[0].totalAlloc - originalBytes
            lastEventId = max(lastEventId, batch.id)
            summary.value.latestEventId = lastEventId
            onChange(summary.value)
            processing = false
            if batch.historyDone { onReplayFinished?() }
            runNext()
        }
        func next(_ index: Int) {
            guard token == generation else { return }
            guard index < plans.count else { finish(); return }
            setActiveFolders(plans.count - index)
            let (eventPath, full) = plans[index]
            guard let (target, path) = resolveDirectory(for: eventPath) else { next(index + 1); return }
            if full {
                let parent = tree[target].parent
                let name = tree[target].name
                var st = stat()
                let fileID = lstat(path, &st) == 0 ? UInt64(st.st_ino) : tree[target].fileID
                let scanner = scanner
                let updater = WeakUpdater(self)
                work.async {
                    let result = Result { try scanner.scan(root: path) }
                    DispatchQueue.main.async {
                        guard let self = updater.value, token == self.generation else { return }
                        switch result {
                        case .success(let sub):
                            summary.value.nodesRemoved += Int(self.tree[target].fileCount + self.tree[target].dirCount) - (target == 0 ? 1 : 0)
                            if target == 0 {
                                self.replaceRootContents(with: sub)
                            } else {
                                let inserted = self.tree.graft(sub, as: name, under: parent)
                                self.tree.setIdentity(inserted, fileID: fileID)
                            }
                            // Under a folder removed meanwhile, graft adds nothing that counts.
                            if target == 0 || !self.tree[parent].isRemoved {
                                summary.value.nodesAdded += Int(sub[0].fileCount + sub[0].dirCount) - (target == 0 ? 1 : 0)
                            }
                            summary.value.dirsRescanned += 1
                        case .failure:
                            self.handleUnreadable(target, path: path, summary: summary)
                        }
                        next(index + 1)
                    }
                }
                return
            }
            let scanner = scanner
            let updater = WeakUpdater(self)
            work.async {
                let listing = Result { try scanner.listDirectory(path) }
                DispatchQueue.main.async {
                    guard let self = updater.value, token == self.generation else { return }
                    switch listing {
                    case .failure:
                        self.handleUnreadable(target, path: path, summary: summary)
                        next(index + 1)
                    case .success(let entries):
                        summary.value.dirsRescanned += 1
                        self.apply(entries, to: target, summary: summary) {
                            // A full listing just succeeded: a folder that was unreadable can recover.
                            self.tree.markListed(target)
                            next(index + 1)
                        }
                    }
                }
            }
        }
        next(0)
    }

    private func setActiveFolders(_ count: Int) {
        guard count != activeFolders else { return }
        activeFolders = count
        NotificationCenter.default.post(name: Self.activityDidChange, object: self)
    }

    /// The folder to relist for an event: the deepest known folder on its path, or that folder's
    /// parent when it is gone. The path is rebuilt from the tree's own names, so the bridged FSEvents
    /// string is walked once and never compared or split again.
    func resolveDirectory(for eventPath: String) -> (NodeID, String)? {
        guard var target = tree.deepestNode(onPath: eventPath) else { return nil }
        if !tree[target].isDirectory { target = tree[target].parent }
        var path = tree.path(of: target)
        if target != FileTree.root && !FileManager.default.fileExists(atPath: path) {
            target = tree[target].parent
            path = tree.path(of: target)
        }
        return (target, path)
    }

    private func markUnavailable(_ id: NodeID) {
        tree.markUnavailable(id)
    }

    /// A folder we knew could not be read this time. If it is gone, remove it. If it is still there,
    /// its old contents are no longer known: drop them so the "≥" size stays a lower bound.
    private func handleUnreadable(_ id: NodeID, path: String, summary: SummaryBox) {
        var st = stat()
        if id != FileTree.root && lstat(path, &st) != 0 && errno == ENOENT {
            summary.value.nodesRemoved += Int(tree[id].fileCount + tree[id].dirCount)
            tree.removeSubtree(id)
            return
        }
        summary.value.nodesRemoved += Int(tree[id].fileCount + tree[id].dirCount) - (tree[id].isDirectory ? 1 : 0)
        tree.clearContents(id)
        tree.markUnavailable(id)
    }

    private func replaceRootContents(with sub: FileTree) {
        for id in tree.children(of: 0) { tree.removeSubtree(id) }
        tree.setIdentity(0, fileID: tree[0].fileID, modTime: sub[0].modTime)
        tree.setStatus(0, sub[0].status)
        var mapped: [NodeID: NodeID] = [0: 0]
        for index in 1..<sub.nodeCount {
            let node = sub[NodeID(index)]
            guard !node.isRemoved, let parent = mapped[node.parent] else { continue }
            let inserted = tree.insert(ScanEntry(name: node.name, isDirectory: node.isDirectory,
                                                 isSymlink: node.flags.contains(.symlink), allocSize: node.rawAlloc,
                                                 logicalSize: node.logicalSize, fileID: node.fileID,
                                                 linkCount: node.linkCount, cloneID: node.cloneID,
                                                 sharesAllBlocks: node.flags.contains(.cloneShared),
                                                 modTime: node.modTime, accessTime: node.accessTime, device: node.device), under: parent)
            tree.setStatus(inserted, node.status)
            if node.flags.contains(.listingIncomplete) { tree.markListingIncomplete(inserted) }
            mapped[NodeID(index)] = inserted
        }
        if sub[0].flags.contains(.listingIncomplete) { tree.markListingIncomplete(0) }
    }

    private func apply(_ entries: [ScanEntry], to parent: NodeID, summary: SummaryBox,
                       completion: @escaping () -> Void) {
        // Same rule as the full scan: a folder on another device (a volume mounted here) is not ours.
        let crossDevices = scanner.options.crossDevices
        let entries = entries.filter { crossDevices || !$0.isDirectory || $0.device == tree.device }
        // Keep the first on a duplicate name instead of trapping: a race between a graft and a listing
        // must cost one stale row, not a crash of the app.
        let existing = Dictionary(tree.children(of: parent).map { (tree[$0].name, $0) }, uniquingKeysWith: { a, _ in a })
        let incoming = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for (name, id) in existing where incoming[name] == nil {
            summary.value.nodesRemoved += Int(tree[id].fileCount + tree[id].dirCount)
            tree.removeSubtree(id)
        }
        var subdirs: [(ScanEntry, String)] = []
        for entry in entries {
            let path = tree.path(of: parent) + "/" + entry.name
            if let id = existing[entry.name], !tree[id].isRemoved {
                let old = tree[id]
                if old.isDirectory != entry.isDirectory ||
                    old.isDirectory && old.fileID != entry.fileID {
                    summary.value.nodesRemoved += Int(old.fileCount + old.dirCount)
                    tree.removeSubtree(id)
                    if entry.isDirectory { subdirs.append((entry, path)) }
                    else { tree.insert(entry, under: parent); summary.value.nodesAdded += 1 }
                } else if !old.isDirectory &&
                            (old.rawAlloc != entry.allocSize || old.logicalSize != entry.logicalSize ||
                             old.modTime != entry.modTime || old.fileID != entry.fileID ||
                             old.cloneID != entry.cloneID || old.linkCount != entry.linkCount ||
                             old.flags.contains(.symlink) != entry.isSymlink ||
                             old.flags.contains(.cloneShared) != entry.sharesAllBlocks) {
                    if old.fileID != entry.fileID || old.flags.contains(.symlink) != entry.isSymlink ||
                        old.cloneID != entry.cloneID || old.flags.contains(.cloneShared) != entry.sharesAllBlocks {
                        tree.removeSubtree(id)
                        tree.insert(entry, under: parent)
                    } else { tree.updateFile(id, with: entry) }
                }
            } else if entry.isDirectory {
                subdirs.append((entry, path))
            } else {
                tree.insert(entry, under: parent)
                summary.value.nodesAdded += 1
            }
        }
        guard !subdirs.isEmpty else { completion(); return }
        let token = generation
        let scanner = scanner
        let updater = WeakUpdater(self)
        work.async {
            let scanned = subdirs.map { (entry, path) in (entry, Result { try scanner.scan(root: path) }) }
            DispatchQueue.main.async {
                guard let self = updater.value, token == self.generation else { return }
                for (entry, result) in scanned {
                    switch result {
                    case .success(let sub):
                        let inserted = self.tree.graft(sub, as: entry.name, under: parent)
                        self.tree.setIdentity(inserted, fileID: entry.fileID)
                        if !self.tree[inserted].isRemoved { summary.value.nodesAdded += Int(sub[0].fileCount + sub[0].dirCount) }
                    case .failure:
                        let id = self.tree.insert(entry, under: parent)
                        self.markUnavailable(id)
                        summary.value.nodesAdded += 1
                    }
                }
                completion()
            }
        }
    }
}
