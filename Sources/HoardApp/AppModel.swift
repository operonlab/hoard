import AppKit
import Foundation
import SwiftUI
import ScanCore

struct SnapshotRejected: Error, CustomStringConvertible {
    let reason: String
    var description: String { "snapshot rejected: \(reason)" }
}

enum ViewKind: Int, CaseIterable, Identifiable, Hashable {
    case map = 1, largest = 2, types = 3, stale = 4, cleanup = 7, changes = 5, protected = 6, apps = 8
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .map: return String(localized: "空間地圖")
        case .largest: return String(localized: "最大的檔案")
        case .types: return String(localized: "檔案類型")
        case .stale: return String(localized: "很久沒動的檔案")
        case .cleanup: return String(localized: "可以清掉的")
        case .changes: return String(localized: "最近變動")
        case .protected: return String(localized: "受保護")
        case .apps: return String(localized: "App 佔用")
        }
    }
    var symbol: String {
        switch self {
        case .map: return "square.grid.2x2"
        case .largest: return "arrow.down.doc"
        case .types: return "chart.pie"
        case .stale: return "moon.zzz"
        case .cleanup: return "sparkles"
        case .changes: return "arrow.up.arrow.down"
        case .protected: return "lock.shield"
        case .apps: return "app.badge"
        }
    }
    /// 受保護 reads the protection registry, not the scan, so it works before anything is scanned.
    var needsTree: Bool { self != .protected }
}

enum MapMode: Hashable { case graph, list }

/// The fixed scan roots of the sidebar (§1.3).
enum Places {
    static let disk = "/System/Volumes/Data"
    static var home: String { NSHomeDirectory() }
    static var userName: String { NSUserName() }
    static var diskName: String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
    }
    static func displayName(of path: String) -> String {
        if path == disk { return diskName }
        if path == home { return userName }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
    static func isFixed(_ path: String) -> Bool { path == disk || path == home }
}

/// Last total per scan root and the recent-folders list, kept in UserDefaults.
enum RootMemory {
    private static let recentsKey = "recentRoots"
    private static let totalsKey = "rootTotals"
    private static let partialKey = "rootPartial"
    static let lastRootKey = "lastRoot"

    static var recents: [String] { UserDefaults.standard.stringArray(forKey: recentsKey) ?? [] }

    static func remember(_ path: String) {
        UserDefaults.standard.set(path, forKey: lastRootKey)
        guard !Places.isFixed(path) else { return }
        var list = recents.filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(5)), forKey: recentsKey)
    }

    static func forget(_ path: String) {
        UserDefaults.standard.set(recents.filter { $0 != path }, forKey: recentsKey)
    }

    static func setTotal(_ node: Node, for path: String) {
        var totals = UserDefaults.standard.dictionary(forKey: totalsKey) as? [String: Int64] ?? [:]
        var partial = UserDefaults.standard.dictionary(forKey: partialKey) as? [String: Bool] ?? [:]
        totals[path] = node.totalAlloc
        partial[path] = node.status != .complete
        UserDefaults.standard.set(totals, forKey: totalsKey)
        UserDefaults.standard.set(partial, forKey: partialKey)
    }

    static func total(for path: String) -> Int64? {
        (UserDefaults.standard.dictionary(forKey: totalsKey)?[path] as? NSNumber)?.int64Value
    }

    /// "412 GB", "≥ 412 GB", or nil when this root was never scanned.
    static func totalText(for path: String) -> String? {
        guard let totals = UserDefaults.standard.dictionary(forKey: totalsKey),
              let bytes = (totals[path] as? NSNumber)?.int64Value else { return nil }
        let partial = (UserDefaults.standard.dictionary(forKey: partialKey)?[path] as? Bool) ?? false
        return partial ? "≥ \(Fmt.bytes(bytes))" : Fmt.bytes(bytes)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tree: FileTree?
    @Published private(set) var revision = 0
    @Published private(set) var rootPath: String?
    /// The one folder every view looks at (§1.2). Selection never moves it.
    @Published private(set) var scope: NodeID = FileTree.root
    /// The selected item; nil means the inspector shows the scope. Setting it to an item outside
    /// `selectedIDs` makes it the only one selected, so every other writer keeps the two in step.
    @Published var selection: NodeID? {
        didSet {
            if let selection {
                if !selectedIDs.contains(selection) { selectedIDs = [selection] }
            } else if !selectedIDs.isEmpty {
                selectedIDs = []
            }
        }
    }
    /// Everything selected in the space map or its list, in the order picked; the last one is `selection`.
    @Published private(set) var selectedIDs: [NodeID] = []
    @Published private(set) var mergedSelection: MergedInfo?
    @Published var view: ViewKind = .map {
        didSet {
            guard view != oldValue else { return }
            keepOnlyInspectedSelection()
            refreshDerived()
        }
    }
    @Published var mapMode: MapMode = .graph
    @Published var showInspector = true
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            if oldValue.isEmpty { keepOnlyInspectedSelection() }
            scheduleSearch()
        }
    }
    /// 目前資料夾 (false) ｜整個掃描範圍 (true).
    @Published var searchWholeTree = false { didSet { if searchWholeTree != oldValue { scheduleSearch() } } }
    @Published private(set) var searchResult: SearchResult?
    @Published private(set) var searchPending = false
    private var searchDebounce: Task<Void, Never>?
    private var jobs: [String: Task<Void, Never>] = [:]
    private var didEvictSnapshotCache = false
    @Published private(set) var recents: [String] = RootMemory.recents
    @Published private(set) var stats: [ExtensionStat] = []
    @Published var staleMonths = 12 { didSet { if staleMonths != oldValue { updateStale() } } }
    @Published var staleMinSize: Int64 = 100_000_000 { didSet { if staleMinSize != oldValue { updateStale() } } }
    @Published var staleIncludeSystem = false { didSet { if staleIncludeSystem != oldValue { updateStale() } } }
    @Published var staleResult: StaleResult?
    @Published var stalePending = false
    @Published var cleanupReport: SuggestReport?
    /// Items checked on the Cleanup page, per section, with the path each had when it was checked.
    @Published var suggestionPicks: [NodeID: String] = [:]
    @Published var duplicatePicks: [NodeID: String] = [:]
    @Published var similarPicks: [NodeID: String] = [:]
    @Published var cleanupError: String?
    @Published var cleanupPending = false
    @Published var hiddenReport: HiddenSpace.Report?
    @Published var hiddenPending = false
    @Published var appReport: AppFootprintReport?
    @Published var appError: String?
    @Published var appPending = false
    @Published var duplicateReport: DuplicateReport?
    /// Each reported copy as the comparison read it, by node.
    var duplicateBaseline: [NodeID: DuplicateCopy] = [:]
    @Published var duplicateProgress: DuplicateProgress?
    @Published var duplicatePending = false
    @Published var duplicateMinSize: Int64 = 50_000_000 {
        didSet { if duplicateMinSize != oldValue { cancelDuplicates() } }
    }
    var duplicateTask: Task<Void, Never>?
    var duplicateRun = 0
    @Published var recentCleanup: [CleanupLogEntry] = []
    var recentCleanupLoaded = false
    var recentCleanupVersion = 0
    /// Spotlight's last-opened date per checked row (nil = Spotlight does not know).
    @Published var lastOpened: [NodeID: Date?] = [:]
    var spotlightQueue: [(NodeID, String)] = []
    var spotlightTask: Task<Void, Never>?
    // First run, access and errors (§2, §7)
    @Published var accessSheet: AccessSheetMode?
    @Published var accessBannerDismissed = false
    @Published var accessGained = false
    @Published var openedSettings = false
    @Published var scanFailure: ScanFailure?
    /// Denominator for the first-scan progress bar: the last known total of this root (D6).
    @Published private(set) var progressEstimate: Int64?
    var lastProgressAt = Date.distantPast
    // Trash (§8)
    @Published var trashRequest: TrashRequest?
    @Published var whatsNew: [WhatsNewRelease]?
    @Published var updateCheckShown = false
    @Published var uninstallRequest: UninstallRequest?
    @Published var trashedBanner: TrashedBatch?
    @Published var alert: AppAlert?
    var trashUndo: [TrashedBatch] = []
    @Published var changes: ChangesState?
    @Published var changesPending = false
    @Published var changesNote: String?
    var changesDebounce: Task<Void, Never>?
    @Published private(set) var largestRows: [FileRow] = []
    @Published private(set) var largestPending = false
    @Published private(set) var scanning = false
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var scanStarted: Date?
    /// Ticks so relative times in the subtitle ("3 分鐘前更新") stay true.
    @Published private(set) var clock = Date()

    private var scanTask: Task<Void, Never>?
    private var scanWorker: Task<FileTree, Error>?
    private var updater: LiveUpdater?
    var generation = 0
    private var pendingScope: String?
    private var pendingSelection: String?
    @Published private(set) var updaterActive = false
    @Published private(set) var updaterFailed = false
    @Published private(set) var dataChangedAt: Date?
    @Published private(set) var cacheAge: Date?
    @Published private(set) var replaying = false
    @Published private(set) var lastUpdate: (delta: Int64, at: Date)?
    /// Folders the live updater is working through right now (the toolbar's 自動更新 button).
    @Published private(set) var autoRefreshFolders = 0
    /// The scan running now was started by the app itself (`open(automatic:)`).
    @Published private(set) var scanIsAutomatic = false
    private var activityObserver: NSObjectProtocol?
    private var saveTask: Task<Void, Never>?
    private var saveSince: UInt64 = 0
    private var replayPendingFrom: UInt64?
    var appGroupsCache: (groups: InstalledAppGroups, createdAt: Date)?
    /// How long the last full scan of this root took, carried into every snapshot written for it:
    /// the CLI stops replaying a snapshot once replay takes longer than a fresh scan would.
    private var lastScanSeconds: Double = 0
    // ponytail: one entry per visited scope for the life of the tree; evict old scopes if a whole-disk
    // session visiting thousands of folders shows up in memory.
    private var statsCache: [NodeID: ScopeStats] = [:]
    /// Folders under the scope that could not be opened (§7.1 legend item).
    @Published private(set) var scopeUnreadable: [String] = []
    @Published private(set) var statsPending = false
    /// Dominant category of each folder tile in the scope (§3.2). May lag the tree by one pass.
    @Published private(set) var folderMix = FolderMixes.none
    private var folderMixCache: [NodeID: FolderMixes] = [:]
    private lazy var folderMixJob = CoalescedJob<FolderMixes>(make: { [weak self] in self?.folderMixWork() },
                                                              deliver: { [weak self] in self?.landFolderMix($0) })
    /// The map lights up only this category (legend click) or extension (from 檔案類型).
    @Published var highlight: Highlight?
    private var statsShown: (scope: NodeID, revision: Int) = (-1, -1)
    private lazy var statsJob = CoalescedJob<ScopeStats>(make: { [weak self] in self?.statsWork() },
                                                         deliver: { [weak self] in self?.landStats($0) })
    lazy var cleanupJob = CoalescedJob<CleanupWorkResult>(make: { [weak self] in self?.cleanupWork() },
                                                          deliver: { [weak self] in self?.landCleanup($0) })
    lazy var hiddenJob = CoalescedJob<HiddenWorkResult>(make: { [weak self] in self?.hiddenWork() },
                                                        deliver: { [weak self] in self?.landHidden($0) })
    lazy var appFootprintJob = CoalescedJob<AppWorkResult>(make: { [weak self] in self?.appFootprintWork() },
                                                           deliver: { [weak self] in self?.landAppFootprint($0) })
    private var clockTimer: Timer?
    // Protection (P2-8b)
    let protectionStore = AppModel.makeProtectionStore()
    /// Store calls lock the registry and walk ACLs; they run here, one at a time, never on main.
    let protectionQueue = DispatchQueue(label: "Hoard.protection", qos: .userInitiated)
    @Published var protection = ProtectionSnapshot()
    @Published var guardianLog: [GuardianEntry] = []
    @Published var protectRequest: ProtectRequest?
    /// Locks and guards being added right now; a quit must not cut one short (see `quitClosingSheets`).
    var protectionAddsRunning = 0
    @Published var restoredBanner: RestoredNotice?
    /// Restores deleted guarded items and refreshes their vault copies while the app runs.
    var guardian: ProtectionGuardian?
    var protectionLoadToken = 0
    var protectionRootKey: (root: String, key: String)?

    init() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.clock = Date()
                // Agents can add protection through the CLI or MCP while the app is open.
                self?.refreshProtection()
            }
        }
        refreshProtection()
        startGuardian()
        // Posted on the main queue by the updater itself; a stopped or replaced updater's posts are ignored.
        activityObserver = NotificationCenter.default.addObserver(forName: LiveUpdater.activityDidChange, object: nil,
                                                                  queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let source = note.object as? LiveUpdater, source === self.updater else { return }
                self.autoRefreshFolders = source.foldersInProgress
            }
        }
    }

    var rootIsPartial: Bool { tree?[FileTree.root].status == .partial }

    /// Probed directly: unreadable folders alone do not mean the permission is missing.
    @Published private(set) var fullDiskAccess: FullDiskAccess.State = FullDiskAccess.current()
    /// Folders marked unavailable in the current tree (system-protected ones stay here even with FDA).
    @Published private(set) var unreadableCount = 0

    func closeWhatsNew() {
        whatsNew = nil
        if !CommandLine.arguments.contains("--whats-new") { WhatsNew.recordSeen() }
    }

    /// Re-probes the permission (on activation). When it has just been granted, retries only the
    /// folders that could not be read, instead of rescanning everything.
    func refreshAccess() {
        let now = FullDiskAccess.current()
        let gained = now == .granted && fullDiskAccess != .granted
        fullDiskAccess = now
        if gained && unreadableCount > 0 { accessGained = true }
        if gained, let updater, !scanning { updater.retryUnavailable() }
    }

    private func countUnreadable() {
        guard let tree else { unreadableCount = 0; return }
        var n = 0
        for node in tree.nodes where node.isDirectory && !node.isRemoved && node.status == .unavailable { n += 1 }
        unreadableCount = n
    }

    // MARK: Names and status

    func name(of id: NodeID) -> String {
        guard let tree else { return "" }
        return id == FileTree.root ? Places.displayName(of: tree.rootPath) : tree[id].name
    }

    var scopeName: String { tree == nil ? "Hoard" : name(of: scope) }

    var windowTitle: String { Fmt.title(scopeName) }

    /// The node the inspector describes: the selection, else the scope.
    var focus: NodeID { selection ?? scope }

    /// Root first, scope last.
    var breadcrumbs: [(NodeID, String)] {
        guard let tree, Int(scope) < tree.nodeCount else { return [] }
        var result: [(NodeID, String)] = []
        var current = scope
        while current >= 0 {
            result.append((current, name(of: current)))
            current = tree[current].parent
        }
        return result.reversed()
    }

    /// Window subtitle (§7.3).
    var subtitle: String {
        guard let tree else { return scanning ? String(localized: "正在掃描⋯") : "" }
        let root = tree[FileTree.root]
        let total = Fmt.sizeLong(root)
        if scanning {
            return String(localized: "正在重新掃描⋯ \(Fmt.bytes(progress?.bytes ?? 0))")
        }
        // Whether 自動更新 is on, at work or stopped is the toolbar button's to say (`autoRefresh`).
        if replaying, let cacheAge {
            return String(localized: "\(total)・上次掃描：\(Fmt.relative(cacheAge, now: clock))")
        }
        if let lastUpdate, lastUpdate.delta != 0, clock.timeIntervalSince(lastUpdate.at) < Self.justUpdatedFor {
            return String(localized: "\(total)・剛更新：\(Fmt.delta(lastUpdate.delta))")
        }
        guard root.status == .complete, let dataChangedAt else { return total }
        return String(localized: "\(total)・\(Self.agoText(dataChangedAt, now: clock))更新")
    }

    /// How long the subtitle's 剛更新 and the button's 剛更新 stay up after a change is applied.
    static let justUpdatedFor: TimeInterval = 5

    /// The toolbar's 自動更新 button; nil hides it (no results yet, or a scan the user started).
    var autoRefresh: AutoRefreshState? {
        guard tree != nil else { return nil }
        if scanning { return scanIsAutomatic ? .rescanning : nil }
        if updaterFailed { return .stopped }
        if replaying { return .catchingUp }
        if autoRefreshFolders > 0 { return .working(folders: autoRefreshFolders) }
        guard updaterActive else { return nil }
        if let lastUpdate, clock.timeIntervalSince(lastUpdate.at) < Self.justUpdatedFor { return .justUpdated }
        return .idle
    }

    static func agoText(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return String(localized: "剛剛") }
        if minutes < 60 { return String(localized: "\(minutes) 分鐘前") }
        if minutes < 24 * 60 { return String(localized: "\(minutes / 60) 小時前") }
        return String(localized: "\(minutes / (24 * 60)) 天前")
    }

    // MARK: Scope and history

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { tree != nil && scope != FileTree.root }

    /// Opens a folder: the scope moves into it. Files are revealed in Finder instead (§3.4).
    func enter(_ id: NodeID) {
        guard let tree, Int(id) < tree.nodeCount, !tree[id].isRemoved else { return }
        if tree[id].isDirectory { setScope(id) } else { reveal(id) }
    }

    func setScope(_ id: NodeID) {
        guard let tree, Int(id) < tree.nodeCount, tree[id].isDirectory, !tree[id].isRemoved, id != scope else { return }
        backStack.append(tree.path(of: scope))
        forwardStack.removeAll()
        moveScope(to: id)
    }

    func goBack() { step(from: &backStack, to: &forwardStack) }
    func goForward() { step(from: &forwardStack, to: &backStack) }

    func goUp() {
        guard let tree, scope != FileTree.root else { return }
        let parent = tree[scope].parent
        let child = scope
        setScope(parent)
        selection = child
    }

    private func step(from source: inout [String], to target: inout [String]) {
        guard let tree else { return }
        while let path = source.popLast() {
            guard let id = tree.lookup(path: path), tree[id].isDirectory else { continue }
            target.append(tree.path(of: scope))
            moveScope(to: id)
            return
        }
    }

    private func moveScope(to id: NodeID) {
        cancelDuplicates()
        cleanupReport = nil
        scope = id
        selection = nil
        mergedSelection = nil
        refreshDerived()
    }

    func select(_ id: NodeID?) {
        mergedSelection = nil
        guard let id else { selection = nil; return }
        guard let tree, Int(id) < tree.nodeCount, !tree[id].isRemoved else { return }
        selectedIDs = [id]
        selection = id
    }

    /// ⌘-click or ⇧-click: adds the item to the selection, or takes it out.
    /// Leaving the map or its list for another view or the search results: the cells picked there are no
    /// longer on screen, so only the one the inspector shows stays selected. ⌘⌫ must not reach the others.
    private func keepOnlyInspectedSelection() {
        guard selectedIDs.count > 1 else { return }
        selectedIDs = selection.map { [$0] } ?? []
    }

    func toggleSelected(_ id: NodeID) {
        guard let tree, Int(id) < tree.nodeCount, !tree[id].isRemoved else { return }
        mergedSelection = nil
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
            selection = selectedIDs.last
        } else {
            selectedIDs.append(id)
            selection = id
        }
    }

    /// The list's own selection, `primary` (the row picked last) shown in the inspector.
    func select(_ ids: [NodeID], primary: NodeID?) {
        mergedSelection = nil
        guard let tree else { return }
        var live = ids.filter { Int($0) < tree.nodeCount && !tree[$0].isRemoved && $0 != primary }
        if let primary, Int(primary) < tree.nodeCount, !tree[primary].isRemoved { live.append(primary) }
        selectedIDs = live
        selection = live.last
    }

    func selectMerged(_ info: MergedInfo) {
        selection = nil
        mergedSelection = info
    }

    /// "{範圍} 共 {大小}。最大的是「{名稱}」（{大小}，{p}%）。" (§11.4)
    var summarySentence: String {
        guard let tree else { return "" }
        let scopeNode = tree[scope]
        let head = scopeNode.status == .complete ? String(localized: "\(scopeName) 共 \(Fmt.bytes(scopeNode.totalAlloc))。")
            : scopeNode.status == .partial ? String(localized: "\(scopeName) 至少 \(Fmt.bytes(scopeNode.totalAlloc))。")
            : String(localized: "沒有權限讀取「\(scopeName)」。")
        guard let biggest = tree.sortedChildren(of: scope).first(where: { tree[$0].status != .unavailable }) else { return head }
        let node = tree[biggest]
        return String(localized: "\(head)最大的是「\(node.name)」（\(Fmt.size(node))，\(Fmt.share(node, of: scopeNode))）。")
    }

    // MARK: Opening and scanning

    /// A location picked by the user. For the whole disk or the home folder, explain Full Disk Access
    /// first when the probe says it is missing (§2.2) — the scan works either way.
    func choose(_ path: String) {
        let skipped = UserDefaults.standard.bool(forKey: AccessSheetMode.skippedKey)
        if Places.isFixed(path), !skipped, FullDiskAccess.current() == .denied {
            accessSheet = .beforeScan(path)
        } else {
            open(path)
        }
    }

    /// `automatic`: the app started this scan on its own, so it runs at utility and leaves the CPU and
    /// the disk to what the user is doing. A scan the user asked for keeps its speed.
    func open(_ path: String, scope relativeScope: String? = nil, select relativePath: String? = nil,
              skipCache: Bool = false, automatic: Bool = false) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        generation += 1
        let token = generation
        scanTask?.cancel()
        scanWorker?.cancel()
        scanWorker = nil
        cancelDuplicates()
        jobs.values.forEach { $0.cancel() }
        jobs = [:]
        if skipCache && standardized == rootPath {
            replayPendingFrom = replayPendingFrom ?? updater?.lastEventId
        }
        updater?.stop()
        updater = nil
        updaterActive = false
        updaterFailed = false
        autoRefreshFolders = 0
        replaying = false
        lastUpdate = nil
        rootPath = standardized
        RootMemory.remember(standardized)
        recents = RootMemory.recents
        pendingScope = relativeScope
        pendingSelection = relativePath
        scanning = true
        scanIsAutomatic = automatic
        scanStarted = Date()
        progress = nil
        saveTask?.cancel()
        scanFailure = nil
        accessBannerDismissed = false
        accessGained = false
        progressEstimate = tree?.rootPath == standardized ? tree?[FileTree.root].totalAlloc : RootMemory.total(for: standardized)
        if !skipCache || tree?.rootPath != standardized {
            replayPendingFrom = nil
            largestRows = []
            searchResult = nil
            staleResult = nil
            cleanupReport = nil
            hiddenReport = nil
            appReport = nil
            cancelDuplicates()
            lastOpened = [:]
            changes = nil
            changesNote = nil
            tree = nil
            backStack = []
            forwardStack = []
            revision += 1
        }
        scanTask = Task { [weak self] in
            guard let self else { return }
            let url = Snapshot.defaultURL(forRoot: standardized)
            if !skipCache {
                do {
                    let cached = try await Task.detached(priority: .userInitiated) { try Snapshot.read(from: url) }.value
                    guard token == self.generation, !Task.isCancelled else { return }
                    // A snapshot is only safe to replay when FSEvents can cover the gap since it was taken.
                    var st = stat()
                    let reject: String? =
                        cached.tree.rootPath != standardized ? "root mismatch"
                        : lstat(standardized, &st) != 0 || st.st_dev != cached.tree.device ? "volume changed"
                        : cached.meta.lastEventId == 0 ? "no replay event id"
                        : cached.meta.eventsUUID == nil || cached.meta.eventsUUID != LiveUpdater.eventsUUID(forDevice: st.st_dev) ? "FSEvents journal changed"
                        : nil
                    if let reject { throw SnapshotRejected(reason: reject) }
                    self.install(cached.tree, token: token)
                    self.scanning = false
                    self.lastScanSeconds = cached.meta.scanSeconds
                    self.cacheAge = cached.meta.createdAt
                    self.dataChangedAt = cached.meta.createdAt
                    self.replaying = true
                    self.replayPendingFrom = cached.meta.lastEventId
                    let replayStarted = Date()
                    self.startUpdater(tree: cached.tree, since: cached.meta.lastEventId, token: token)
                    // A long history can take longer to arrive than a scan (9 hours of ~/workshop: 14-18 s
                    // against 4 s). Then scan now; the cached tree stays on screen until the scan lands.
                    let expectedScan = cached.meta.scanSeconds > 0 ? cached.meta.scanSeconds
                        : Double(cached.tree.nodeCount) * 5e-6
                    Task { [weak self] in
                        for _ in 0..<3 {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            guard let self, token == self.generation, let p = self.updater?.historyProgress, p < 1
                            else { return }
                            guard p > 0 else { continue }
                            let projected = Date().timeIntervalSince(replayStarted) / p
                            guard projected > expectedScan else { continue }
                            NSLog("Hoard 快取補播預估約 %.0f 秒，比全新掃描（%.1f 秒）久，改為重新掃描", projected, expectedScan)
                            self.rescan(automatic: true)
                            return
                        }
                    }
                    // HistoryDone normally ends the replay; if FSEvents never sends it, the held batches are
                    // applied after `historyWait`, and the banner must not stay up for good.
                    self.armReplayFallback(token: token)
                    // The cache may predate a permission grant: retry just the folders it could not read.
                    self.fullDiskAccess = FullDiskAccess.current()
                    if self.fullDiskAccess == .granted { self.updater?.retryUnavailable() }
                    self.evictSnapshotCacheOnce(keeping: standardized)
                    return
                } catch {
                    NSLog("Hoard 不使用快取，改全新掃描：%@", String(describing: error))
                }
            }
            guard token == self.generation, !Task.isCancelled else { return }
            self.evictSnapshotCacheOnce(keeping: standardized)
            let eventID = LiveUpdater.currentEventId()
            let scanner = ScanCore.Scanner()
            let started = Date()
            do {
                let report: @Sendable (ScanProgress) -> Void = { [weak self] update in
                    Task { @MainActor [weak self] in
                        // At most four updates a second (§2.4).
                        guard let self, self.generation == token, Date().timeIntervalSince(self.lastProgressAt) >= 0.25 else { return }
                        self.lastProgressAt = Date()
                        self.progress = update
                    }
                }
                let worker = Task.detached(priority: automatic ? .utility : .userInitiated) {
                    try scanner.scan(root: standardized, progress: report,
                                     isCancelled: { Task.isCancelled })
                }
                self.scanWorker = worker
                let scanned = try await worker.value
                guard token == self.generation, !Task.isCancelled else { return }
                self.scanWorker = nil
                let elapsed = Date().timeIntervalSince(started)
                self.lastScanSeconds = elapsed
                self.install(scanned, token: token)
                self.replayPendingFrom = nil
                self.scanning = false
                self.cacheAge = nil
                self.dataChangedAt = Date()
                Self.announce(String(localized: "掃描完成：\(Places.displayName(of: standardized))，\(Fmt.sizeSpoken(scanned[FileTree.root]))"))
                let meta = SnapshotMeta(rootPath: standardized, device: scanned.device, createdAt: Date(),
                                        scanSeconds: elapsed, lastEventId: eventID,
                                        eventsUUID: LiveUpdater.eventsUUID(forDevice: scanned.device))
                self.startUpdater(tree: scanned, since: eventID, token: token)
                let nodes = scanned.nodes
                let device = scanned.device
                Task.detached(priority: .utility) {
                    let copy = FileTree(restoring: nodes, rootPath: standardized, device: device)
                    do {
                        try Snapshot.write(copy, meta: meta, to: url)
                    } catch SnapshotError.notImplemented {
                    } catch {
                        NSLog("Hoard 快取寫入失敗：%@", String(describing: error))
                    }
                    // D2: every completed full scan is a comparison baseline for 最近變動.
                    AppModel.recordHistory(copy)
                    await MainActor.run { [weak self] in self?.scheduleChanges(delay: 0) }
                }
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.scanning = false
                self.scanWorker = nil
                if self.tree == nil {
                    self.scanFailure = ScanFailure(path: standardized, error: error)
                } else {
                    // A failed rescan keeps the previous results; say so without a modal error.
                    self.restartUpdaterForDisplayedTree(token: token)
                    self.alert = AppAlert(title: String(localized: "無法重新掃描「\(Places.displayName(of: standardized))」"),
                                          message: ScanFailure(path: standardized, error: error).reason)
                }
            }
        }
    }

    private func evictSnapshotCacheOnce(keeping root: String) {
        guard !didEvictSnapshotCache, !CommandLine.arguments.contains("--render-to") else { return }
        didEvictSnapshotCache = true
        Task.detached(priority: .utility) {
            let removed = SnapshotCache.evict(
                in: Snapshot.defaultURL(forRoot: "/").deletingLastPathComponent(),
                keep: [root], now: Date())
            if !removed.isEmpty {
                NSLog("Hoard 已移除 %d 個舊快取，合計 %lld bytes", removed.count,
                      removed.reduce(Int64(0)) { $0 + $1.bytesFreed })
            }
        }
    }

    func rescan(automatic: Bool = false) {
        guard let rootPath else { return }
        let relScope = tree.map { relative($0.path(of: scope), to: rootPath) } ?? nil
        let relSelection = tree.flatMap { t in selection.flatMap { relative(t.path(of: $0), to: rootPath) } }
        open(rootPath, scope: relScope, select: relSelection, skipCache: true, automatic: automatic)
    }

    /// Stops a running scan. With results on screen they stay; otherwise back to the start screen.
    func stopScan() {
        guard scanning else { return }
        generation += 1
        scanTask?.cancel()
        scanWorker?.cancel()
        scanWorker = nil
        scanning = false
        progress = nil
        if tree != nil {
            // A stopped rescan keeps the previous results; watch them again.
            restartUpdaterForDisplayedTree(token: generation)
        } else {
            rootPath = nil
        }
    }

    private func restartUpdaterForDisplayedTree(token: Int) {
        guard let tree else { return }
        replaying = replayPendingFrom != nil
        startUpdater(tree: tree, since: replayPendingFrom ?? max(saveSince, LiveUpdater.currentEventId()), token: token)
        if replaying { armReplayFallback(token: token) }
        if fullDiskAccess == .granted { updater?.retryUnavailable() }
    }

    private func armReplayFallback(token: Int) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((LiveUpdater.historyHoldLimit + 10) * 1e9))
            guard let self, token == self.generation, self.replaying else { return }
            self.replaying = false
        }
    }

    private func relative(_ path: String, to root: String) -> String? {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    func forgetRecent(_ path: String) {
        RootMemory.forget(path)
        recents = RootMemory.recents
    }

    // MARK: File actions

    func reveal(_ id: NodeID) {
        guard let tree else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tree.path(of: id))])
    }

    func copyPath(_ id: NodeID) {
        guard let tree else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tree.path(of: id), forType: .string)
    }

    // MARK: Tree lifecycle

    private func install(_ value: FileTree, token: Int) {
        guard token == generation else { return }
        let replaced = tree !== value
        tree = value
        if replaced {
            // A node id from the previous tree names another node, or none, in this one (a rescan
            // keeps the old results on screen until it lands).
            largestRows = []
            searchResult = nil
            staleResult = nil
            cleanupReport = nil
            cancelDuplicates()
            lastOpened = [:]
            spotlightQueue = []
            if trashRequest != nil {
                trashRequest = nil
                // In a later turn: an alert set while the sheet is being dismissed can be dropped.
                Task { @MainActor [weak self] in
                    self?.alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: String(localized: "掃描結果換新了，確認單已關閉，沒有動任何項目。請重新選取後再試。"))
                }
            }
        }
        statsCache = [:]
        statsShown = (-1, -1)
        folderMixCache = [:]
        folderMix = .none
        countUnreadable()
        RootMemory.setTotal(value[FileTree.root], for: value.rootPath)
        scope = FileTree.root
        selection = nil
        revision += 1
        if let pendingScope {
            let path = (value.rootPath as NSString).appendingPathComponent(pendingScope)
            if let id = value.lookup(path: path), value[id].isDirectory { scope = id }
            self.pendingScope = nil
        }
        if let pendingSelection {
            let path = (value.rootPath as NSString).appendingPathComponent(pendingSelection)
            if let id = value.lookup(path: path) { selection = id }
            self.pendingSelection = nil
        }
        refreshDerived()
    }

    private func startUpdater(tree: FileTree, since: UInt64, token: Int) {
        let observer = LiveUpdater(tree: tree, scanner: ScanCore.Scanner(), sinceEventId: since) { [weak self] change in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if change.requiresFullRescan { self.rescan(automatic: true); return }
                if change.dirsRescanned > 0 {
                    self.lastUpdate = (change.bytesDelta, Date())
                    self.dataChangedAt = Date()
                    self.clock = Date()
                    // The clock ticks every 20 s: tick once more when 剛更新 is due to go.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64((Self.justUpdatedFor + 0.1) * 1e9))
                        self?.clock = Date()
                    }
                }
                self.changed()
                self.scheduleSave()
            }
        }
        observer.onReplayFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.replaying = false
                self.replayPendingFrom = nil
            }
        }
        updater = observer
        autoRefreshFolders = 0
        saveSince = since
        do {
            try observer.start()
            updaterActive = true
        } catch {
            NSLog("Hoard 自動更新啟動失敗：%@", String(describing: error))
            updaterFailed = true
        }
    }

    func changed() {
        // Duplicate results survive live changes: each trash re-checks the copy and a remaining copy.
        guard let tree else { return }
        let alive = selectedIDs.filter { Int($0) < tree.nodeCount && !tree[$0].isRemoved }
        if alive != selectedIDs {
            selectedIDs = alive
            selection = alive.last
        }
        if let selection, Int(selection) >= tree.nodeCount || tree[selection].isRemoved { self.selection = nil }
        if Int(scope) >= tree.nodeCount || tree[scope].isRemoved {
            var up = scope
            while up > FileTree.root, Int(up) < tree.nodeCount, tree[up].isRemoved { up = tree[up].parent }
            scope = max(FileTree.root, up)
        }
        revision += 1
        countUnreadable()
        RootMemory.setTotal(tree[FileTree.root], for: tree.rootPath)
        refreshDerived()
    }

    /// What quitting still has to write, captured on the main thread so it can run off it: the
    /// snapshot (as `snapshotSaveWork`) and a history version, from one detached copy. nil when there
    /// is nothing to save.
    func quitSaveWork() -> (@Sendable () -> Void)? {
        saveTask?.cancel()  // the debounced save would otherwise run on the main thread mid-quit
        guard let tree, !scanning else { return nil }
        let nodes = tree.nodes, root = tree.rootPath, device = tree.device
        let replayFrom = max(updater?.lastEventId ?? 0, saveSince)
        let meta: SnapshotMeta? = root == rootPath && replayFrom > 0
            ? SnapshotMeta(rootPath: root, device: device, createdAt: Date(), scanSeconds: lastScanSeconds, lastEventId: replayFrom,
                           eventsUUID: LiveUpdater.eventsUUID(forDevice: device))
            : nil
        return {
            let copy = FileTree(restoring: nodes, rootPath: root, device: device)
            if let meta {
                do { try Snapshot.write(copy, meta: meta, to: Snapshot.defaultURL(forRoot: root)) }
                catch { NSLog("Hoard 快取寫入失敗：%@", String(describing: error)) }
            }
            // The state at quit is what the next launch compares against.
            AppModel.recordHistory(copy)
        }
    }

    /// The current tree with the newest applied event id, as work that writes a copy off the main
    /// thread (a whole-disk snapshot takes about a second), so the next launch replays only what
    /// changed after this point. nil when there is nothing to save.
    private func snapshotSaveWork() -> (@Sendable () -> Void)? {
        guard let tree, let rootPath, tree.rootPath == rootPath, !scanning else { return nil }
        let replayFrom = max(updater?.lastEventId ?? 0, saveSince)
        guard replayFrom > 0 else { return nil }
        let nodes = tree.nodes, device = tree.device
        let meta = SnapshotMeta(rootPath: rootPath, device: device, createdAt: Date(), scanSeconds: lastScanSeconds,
                                lastEventId: replayFrom, eventsUUID: LiveUpdater.eventsUUID(forDevice: device))
        return {
            let copy = FileTree(restoring: nodes, rootPath: rootPath, device: device)
            do { try Snapshot.write(copy, meta: meta, to: Snapshot.defaultURL(forRoot: rootPath)) }
            catch { NSLog("Hoard 快取寫入失敗：%@", String(describing: error)) }
        }
    }

    /// Debounced after live changes.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let work = self?.snapshotSaveWork() else { return }
            await Task.detached(priority: .utility) { work() }.value
        }
    }

    // MARK: Derived data (background, keyed on scope + revision)

    /// Recomputes whatever the current view needs for the current scope.
    func refreshDerived() {
        if view == .protected { refreshProtection() }
        updateStats()
        if view == .map { updateFolderMix() }
        if view == .largest { updateLargestFiles() } else { cancelJob("largest"); largestPending = false }
        if view == .stale { updateStale() } else { cancelJob("stale"); stalePending = false }
        if view == .cleanup { updateCleanup() }
        else if duplicatePending { cancelDuplicates() }
        if view == .apps { updateAppFootprint() }
        // The sidebar shows the net change too, so keep it fresh; live updates are debounced.
        scheduleChanges(delay: view == .changes ? 0.3 : 5)
        if !searchText.isEmpty { scheduleSearch() }
    }

    /// Extension stats and unreadable folders for the scope, cached per scope and tree revision. A
    /// scope seen before shows its last result at once and is refreshed quietly after live changes;
    /// `statsPending` (the spinner) means only that this scope has no result yet.
    private func updateStats() {
        guard tree != nil else { stats = []; scopeUnreadable = []; statsPending = false; return }
        let cached = statsCache[scope]
        if let cached, statsShown != (cached.scope, cached.revision) { show(cached) }
        statsPending = cached == nil
        if cached?.revision != revision { statsJob.request() }
    }

    private func statsWork() -> (@Sendable () -> ScopeStats)? {
        guard let tree, statsCache[scope]?.revision != revision else { return nil }
        let nodes = tree.nodes  // copy-on-write value snapshot; no copy unless the tree mutates meanwhile
        let rootPath = tree.rootPath, dir = scope, token = generation, current = revision
        return {
            ScopeStats(generation: token, scope: dir, revision: current,
                       stats: FileTree.extensionStats(in: nodes, under: dir),
                       unreadable: AppModel.unreadableFolders(in: nodes, rootPath: rootPath, under: dir))
        }
    }

    private func landStats(_ values: ScopeStats) {
        guard values.generation == generation, tree != nil else { return }
        statsCache[values.scope] = values
        if values.scope == scope { show(values); statsPending = false }
    }

    private func show(_ values: ScopeStats) {
        stats = values.stats
        scopeUnreadable = values.unreadable
        statsShown = (values.scope, values.revision)
    }

    /// Paths of the folders under `dir` that could not be opened, shortest first.
    nonisolated static func unreadableFolders(in nodes: [Node], rootPath: String, under dir: NodeID) -> [String] {
        var found: [NodeID] = []
        var stack = [dir]
        while let id = stack.popLast() {
            let node = nodes[Int(id)]
            if node.isRemoved || !node.isDirectory { continue }
            if node.status == .unavailable { found.append(id); continue }
            if node.status == .complete { continue }  // nothing unreadable below a complete folder
            var child = node.firstChild
            while child >= 0 { stack.append(child); child = nodes[Int(child)].nextSibling }
        }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return found.map { id in
            var parts: [String] = []
            var cur = id
            while cur > FileTree.root { parts.append(nodes[Int(cur)].name); cur = nodes[Int(cur)].parent }
            return base + "/" + parts.reversed().joined(separator: "/")
        }.sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
    }

    /// Folder tile colors for the space map: cached per scope and tree revision. The previous result
    /// stays on screen while a newer one is computed; a scope with no result yet draws neutral.
    private func updateFolderMix() {
        guard tree != nil else { folderMix = .none; return }
        let cached = folderMixCache[scope]
        if folderMix.scope != scope { folderMix = cached ?? .none }
        if cached?.revision != revision { folderMixJob.request() }
    }

    private func folderMixWork() -> (@Sendable () -> FolderMixes)? {
        guard let tree, view == .map, folderMixCache[scope]?.revision != revision else { return nil }
        let nodes = tree.nodes  // copy-on-write value snapshot
        let dir = scope, token = generation, current = revision
        return {
            FolderMixes(generation: token, scope: dir, revision: current, byFolder: FolderMixes.compute(nodes: nodes, scope: dir))
        }
    }

    private func landFolderMix(_ mixes: FolderMixes) {
        guard mixes.generation == generation, tree != nil else { return }
        folderMixCache[mixes.scope] = mixes
        if mixes.scope == scope { folderMix = mixes }
    }

    /// Bytes per category in the scope, largest first (from the extension stats).
    var categoryTotals: [(category: FileCategory, bytes: Int64, count: Int64)] {
        var acc: [FileCategory: (Int64, Int64)] = [:]
        for stat in stats {
            let category = FileCategory.of(extension: stat.ext)
            let v = acc[category, default: (0, 0)]
            acc[category] = (v.0 + stat.bytes, v.1 + stat.count)
        }
        return acc.map { ($0.key, $0.value.0, $0.value.1) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.category.rawValue < $1.category.rawValue }
    }

    /// Runs `work` on a node snapshot off the main thread and applies the result only if the tree,
    /// its revision and the scope are still the ones it was computed for. One job per key.
    func runJob<T: Sendable>(_ key: String, work: @escaping @Sendable ([Node], String, NodeID) -> T,
                             apply: @escaping (T) -> Void) {
        jobs[key]?.cancel()
        guard let tree else { return }
        let token = generation, currentRevision = revision, dir = scope
        let nodes = tree.nodes  // copy-on-write value snapshot
        let rootPath = tree.rootPath
        let worker = Task.detached(priority: .utility) { work(nodes, rootPath, dir) }
        jobs[key] = Task { [weak self] in
            let value = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, token == self.generation,
                  currentRevision == self.revision, dir == self.scope else { return }
            self.jobs[key] = nil
            apply(value)
        }
    }

    func cancelJob(_ key: String) {
        jobs[key]?.cancel()
        jobs[key] = nil
    }

    private func updateLargestFiles() {
        guard tree != nil else { largestRows = []; return }
        largestPending = true
        runJob("largest", work: { nodes, rootPath, dir in
            let ids = TreeQuery.largestFiles(in: nodes, under: dir, limit: FileRow.limit)
            return FileRow.build(ids, nodes: nodes, rootPath: rootPath, base: dir)
        }, apply: { [weak self] rows in
            self?.largestRows = rows
            self?.largestPending = false
        })
    }

    // MARK: Search (§4.3)

    /// Debounced: typing restarts the 200 ms timer.
    private func scheduleSearch() {
        searchDebounce?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, tree != nil else {
            cancelJob("search")
            searchResult = nil
            searchPending = false
            return
        }
        searchPending = true
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.runSearch(query)
        }
    }

    private func runSearch(_ query: String) {
        let whole = searchWholeTree
        runJob("search", work: { nodes, rootPath, dir in
            let base = whole ? FileTree.root : dir
            let found = AppModel.search(query, in: nodes, under: base, limit: FileRow.limit)
            return SearchResult(query: query, rows: FileRow.build(found.ids, nodes: nodes, rootPath: rootPath, base: base),
                                count: found.count, bytes: found.bytes)
        }, apply: { [weak self] result in
            self?.searchResult = result
            self?.searchPending = false
        })
    }

    /// Case-insensitive name substring match below `root`. Keeps the `limit` largest matches; the
    /// byte total counts a matched folder once, not again for matches inside it.
    nonisolated static func search(_ query: String, in nodes: [Node], under root: NodeID,
                                   limit: Int) -> (ids: [NodeID], count: Int, bytes: Int64) {
        guard nodes.indices.contains(Int(root)) else { return ([], 0, 0) }
        var kept: [NodeID] = []
        var count = 0
        var bytes: Int64 = 0
        var stack: [(NodeID, Bool)] = []
        var child = nodes[Int(root)].firstChild
        while child >= 0 { stack.append((child, false)); child = nodes[Int(child)].nextSibling }
        func size(_ id: NodeID) -> Int64 { nodes[Int(id)].isDirectory ? nodes[Int(id)].totalAlloc : nodes[Int(id)].ownAlloc }
        var visited = 0
        while let (id, insideMatch) = stack.popLast() {
            visited += 1
            if visited % 50_000 == 0 && Task.isCancelled { return ([], 0, 0) }
            let node = nodes[Int(id)]
            if node.isRemoved { continue }
            let hit = node.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            if hit {
                count += 1
                if !insideMatch { bytes += size(id) }
                kept.append(id)
                if kept.count > limit * 4 {
                    kept.sort { size($0) > size($1) }
                    kept.removeLast(kept.count - limit)
                }
            }
            if node.isDirectory {
                var c = node.firstChild
                while c >= 0 { stack.append((c, insideMatch || hit)); c = nodes[Int(c)].nextSibling }
            }
        }
        kept.sort { size($0) > size($1) }
        return (Array(kept.prefix(limit)), count, bytes)
    }
}

struct SearchResult: Sendable {
    let query: String
    let rows: [FileRow]
    let count: Int
    let bytes: Int64
}

struct ScopeStats: Sendable {
    var generation: Int
    var scope: NodeID
    var revision: Int
    var stats: [ExtensionStat]
    var unreadable: [String]
}

enum Highlight: Hashable {
    case category(FileCategory)
    case ext(String)

    func matches(_ ext: String) -> Bool {
        switch self {
        case .category(let category): return FileCategory.of(extension: ext) == category
        case .ext(let wanted): return ext == wanted
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Why a scan could not start (§7.4), worded for people.
struct ScanFailure: Equatable {
    let path: String
    let reason: String

    init(path: String, error: Error) {
        self.path = path
        let gone = !FileManager.default.fileExists(atPath: path)
        switch error as? ScanError {
        case _ where gone: reason = String(localized: "這個資料夾已經不存在。")
        case .cannotOpen(_, let code) where code == EACCES || code == EPERM: reason = String(localized: "你沒有權限讀取這個資料夾。")
        case .notADirectory: reason = String(localized: "這不是資料夾。")
        default: reason = error.localizedDescription
        }
    }
}

extension AppModel {
    /// VoiceOver announcement (§8.4, §9.3).
    static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
