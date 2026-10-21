import AppKit
import Foundation
import ScanCore

struct CleanupWorkResult: Sendable {
    let generation: Int
    let scope: NodeID
    let report: SuggestReport?
    let error: String?
}

enum AppFootprintOutcome: Sendable {
    case success(AppFootprintReport)
    case failure(String)
}

struct HiddenWorkResult: Sendable {
    let generation: Int
    let report: HiddenSpace.Report
}

struct AppWorkResult: Sendable {
    let generation: Int
    let outcome: AppFootprintOutcome
}

extension AppModel {
    func updateCleanup() {
        guard view == .cleanup, tree != nil else { return }
        cleanupPending = true
        cleanupJob.request()
        updateHiddenSpace()
        loadRecentCleanup()
    }

    func cleanupWork() -> (@Sendable () -> CleanupWorkResult)? {
        guard let tree, view == .cleanup else { return nil }
        let nodes = tree.nodes, rootPath = tree.rootPath, dir = scope
        let token = generation
        let groups: InstalledAppGroups
        if let cached = appGroupsCache, Date().timeIntervalSince(cached.createdAt) < 600 {
            groups = cached.groups
        } else {
            groups = InstalledAppGroups()
            appGroupsCache = (groups, Date())
        }
        return {
            do {
                let options = SuggestOptions(home: NSHomeDirectory(), now: Int64(Date().timeIntervalSince1970),
                                             installedApps: InstalledApps.current(),
                                             isAppRegistered: { InstalledApps.isRegistered(bundleID: $0) },
                                             downloadOrigin: { InstallerEvidence.downloadOrigin(path: $0) },
                                             archiveHoldsInstaller: { InstallerEvidence.archiveHoldsInstaller(path: $0) },
                                             appGroupInstalled: { groups.contains($0) })
                let report = try CleanupSuggester.suggest(in: nodes, rootPath: rootPath, under: dir, options: options)
                return CleanupWorkResult(generation: token, scope: dir, report: report, error: nil)
            } catch {
                return CleanupWorkResult(generation: token, scope: dir, report: nil, error: error.localizedDescription)
            }
        }
    }

    /// Results land even when live changes arrived meanwhile (on a busy root they always have, and the
    /// job runs one more pass on the newest state); rows check their node against the tree before acting.
    func landCleanup(_ result: CleanupWorkResult) {
        guard result.generation == generation else { return }
        if result.scope == scope, view == .cleanup {
            cleanupReport = result.report
            cleanupError = result.error
            cleanupPending = false
        }
    }

    private func updateHiddenSpace() {
        guard tree != nil else { return }
        hiddenPending = true
        hiddenJob.request()
    }

    func hiddenWork() -> (@Sendable () -> HiddenWorkResult)? {
        guard let tree, view == .cleanup else { return nil }
        let nodes = tree.nodes, rootPath = tree.rootPath
        let device = tree.device
        let token = generation
        return {
            let snapshot = FileTree(restoring: nodes, rootPath: rootPath, device: device)
            return HiddenWorkResult(generation: token,
                                    report: HiddenSpace.report(HiddenSpace.ScanFacts(tree: snapshot)))
        }
    }

    func landHidden(_ result: HiddenWorkResult) {
        guard result.generation == generation, view == .cleanup else { return }
        hiddenReport = result.report
        hiddenPending = false
    }

    func updateAppFootprint() {
        guard tree != nil, view == .apps else { return }
        appPending = true
        appFootprintJob.request()
    }

    func appFootprintWork() -> (@Sendable () -> AppWorkResult)? {
        guard let tree, view == .apps else { return nil }
        let nodes = tree.nodes, rootPath = tree.rootPath
        let device = tree.device
        let token = generation
        return {
            let outcome: AppFootprintOutcome
            do {
                let snapshot = FileTree(restoring: nodes, rootPath: rootPath, device: device)
                outcome = .success(try AppFootprintAnalyzer.analyze(tree: snapshot))
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            return AppWorkResult(generation: token, outcome: outcome)
        }
    }

    func landAppFootprint(_ result: AppWorkResult) {
        guard result.generation == generation, view == .apps else { return }
        switch result.outcome {
        case .success(let report): appReport = report; appError = nil
        case .failure(let error): appReport = nil; appError = error
        }
        appPending = false
    }

    func findDuplicates() {
        guard let tree, !duplicatePending else { return }
        duplicateRun += 1
        let run = duplicateRun, token = generation, dir = scope
        let nodes = tree.nodes, rootPath = tree.rootPath, minSize = duplicateMinSize
        duplicateReport = nil
        duplicateBaseline = [:]
        duplicateProgress = nil
        duplicatePending = true
        duplicateTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { [weak self] () -> (DuplicateReport, [NodeID: DuplicateCopy]) in
                // The finder skips files with no local data, but one can be evicted to iCloud after
                // the scan: make its read fail instead of downloading it. The pass runs on this thread
                // without suspending, so a thread-scoped policy covers it; it is put back for the pool.
                // Without the policy nothing is read.
                guard let restore = Materialization.offForThread("duplicates") else {
                    return (DuplicateFinder.unread(in: nodes, rootPath: rootPath, under: dir, options: DuplicateOptions(minSize: minSize),
                                                   detail: Materialization.refusedDetail), [:])
                }
                defer { restore() }
                let report = DuplicateFinder.find(in: nodes, rootPath: rootPath, under: dir,
                                                  options: DuplicateOptions(minSize: minSize),
                                                  isCancelled: { Task<Never, Never>.isCancelled },
                                                  progress: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.duplicateRun == run else { return }
                        self.duplicateProgress = progress
                    }
                })
                // What the comparison read; a trash later needs the files to still be exactly this.
                var baseline: [NodeID: DuplicateCopy] = [:]
                for member in report.groups.flatMap(\.members) {
                    baseline[member.node] = DuplicateCopy(nodes[Int(member.node)], path: member.path)
                }
                return (report, baseline)
            }
            let (report, baseline) = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            // Live changes do not discard the result (they arrive many times a second on a busy root);
            // the rows and the trash request check each copy against the tree and the disk instead.
            guard let self, !Task.isCancelled, run == self.duplicateRun,
                  token == self.generation, dir == self.scope else { return }
            self.duplicateReport = report
            self.duplicateBaseline = baseline
            self.duplicatePending = false
            self.duplicateTask = nil
        }
    }

    func cancelDuplicates() {
        duplicateRun += 1
        duplicateTask?.cancel()
        duplicateTask = nil
        duplicatePending = false
        duplicateProgress = nil
        duplicateReport = nil
        duplicateBaseline = [:]
    }
}

/// The app's record of what it moved to the Trash (Application Support/<storage>/cleanup-log.jsonl).
/// The line format and what counts as recent live in ScanCore's CleanupLogFormat.
enum CleanupLog {
    private static let queue = DispatchQueue(label: "Hoard.cleanupLog", qos: .utility)
    /// Past this size the file keeps only its newest `keepLines` lines.
    private static let maxBytes = 256 * 1024
    private static let keepLines = 1000

    private static func url() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(HoardStorage.folderName, isDirectory: true)
            .appendingPathComponent("cleanup-log.jsonl")
    }

    /// Appends off the main thread and hands back the recent list.
    static func append(_ entries: [CleanupLogEntry],
                       _ completed: @escaping @Sendable (Result<[CleanupLogEntry], Error>) -> Void) {
        queue.async {
            completed(Result {
                let target = url()
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try CleanupLogFormat.encode(entries)
                if !FileManager.default.fileExists(atPath: target.path) {
                    guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: target)
                let size = try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
                if Int(size) + data.count > maxBytes {
                    try CleanupLogFormat.trimmed(try Data(contentsOf: target), keep: keepLines).write(to: target, options: .atomic)
                }
                return try read()
            })
        }
    }

    static func load(_ completed: @escaping @Sendable (Result<[CleanupLogEntry], Error>) -> Void) {
        queue.async {
            do { completed(.success(try read())) }
            catch { completed(.failure(error)) }
        }
    }

    private static func read() throws -> [CleanupLogEntry] {
        let target = url()
        guard FileManager.default.fileExists(atPath: target.path) else { return [] }
        return CleanupLogFormat.recent(try Data(contentsOf: target))
    }
}

extension AppModel {
    func loadRecentCleanup() {
        guard !recentCleanupLoaded else { return }
        recentCleanupLoaded = true
        let version = recentCleanupVersion
        CleanupLog.load { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.recentCleanupVersion == version else { return }
                switch result {
                case .success(let rows): self.recentCleanup = rows
                case .failure(let error):
                    self.recentCleanupLoaded = false
                    NSLog("Hoard 無法讀取清理紀錄：%@", String(describing: error))
                }
            }
        }
    }
}
