import AppKit
import Darwin
import Foundation
import SwiftUI
import ScanCore

struct UninstallRequest: Identifiable {
    let id = UUID()
    let plan: UninstallPlan
}

private enum FinderUninstallError: Error {
    /// `left`: the bundle is no longer at its path although Finder did not confirm the move.
    case cancelled, denied, changed, timedOut(left: Bool), failed(String, left: Bool)
}

/// Asks Finder to move one app bundle to the Trash; Finder asks for an administrator's approval when the
/// bundle belongs to root. Returns the path in the Trash, after checking it is still the confirmed file.
private func moveAppWithFinder(_ path: String, identity: FileIdentity) throws -> String {
    guard let restore = Materialization.offForThread("Finder uninstall move") else {
        throw FinderUninstallError.failed(Materialization.refusedDetail, left: false)
    }
    defer { restore() }
    var st = stat()
    guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, identity.stillAt(path) else {
        throw FinderUninstallError.changed
    }
    // An alias follows links: the script refuses unless it still names exactly this path (9001). The
    // timeout covers a person reading the password dialog; AppleScript's default is two minutes.
    let script = ["on run argv",
                  "set target to (POSIX file (item 1 of argv) as alias)",
                  "if POSIX path of target is not (item 2 of argv) then error \"changed\" number 9001",
                  "with timeout of 3600 seconds",
                  "tell application \"Finder\" to set moved to delete target",
                  "end timeout",
                  "return POSIX path of (moved as alias)",
                  "end run"]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = script.flatMap { ["-e", $0] } + [path, path.hasSuffix("/") ? path : path + "/"]
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout; process.standardError = stderr
    try process.run()
    // Read both to the end before waiting, so a full pipe cannot hold osascript.
    let errorData = DispatchGroup()
    var errorBytes = Data()
    errorData.enter()
    DispatchQueue.global(qos: .utility).async { errorBytes = stderr.fileHandleForReading.readDataToEndOfFile(); errorData.leave() }
    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    errorData.wait()
    process.waitUntilExit()
    let error = String(decoding: errorBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let left = !FileManager.default.fileExists(atPath: path)
    if process.terminationStatus != 0 {
        if error.contains("(-128)") && !left { throw FinderUninstallError.cancelled }
        if error.contains("(-1743)") && !left { throw FinderUninstallError.denied }
        if error.contains("(9001)") && !left { throw FinderUninstallError.changed }
        if error.contains("(-1712)") { throw FinderUninstallError.timedOut(left: left) }
        throw FinderUninstallError.failed(error, left: left)
    }
    guard left, output.hasPrefix("/"), identity.stillAt(output) else {
        throw FinderUninstallError.failed(String(localized: "Finder 沒有確認移走的是這個 App。請到垃圾桶檢查。"), left: left)
    }
    return output
}

/// One Finder move at a time: a second plan confirmed meanwhile would race the first.
@MainActor private var finderUninstallBusy = false

@MainActor private var pendingUninstallPath: (model: ObjectIdentifier, path: String, generation: Int)?

extension AppModel {
    /// A folder opens; an App opens its uninstall plan. Everything else is refused.
    @discardableResult func handleOpen(_ urls: [URL]) -> Bool {
        switch OpenRequest.first(of: urls) {
        case .folder(let path): choose(path); return true
        case .app(let path): requestUninstall(atPath: path); return true
        case .ignored: return false
        }
    }

    func requestUninstall(atPath path: String) {
        let canonical = OpenRequest.normalized(path)
        guard OpenRequest.isInAppFolders(canonical, roots: AppFootprintRoots.user().applications) else {
            alertAppNotFound()
            return
        }
        let token = generation
        pendingUninstallPath = (ObjectIdentifier(self), canonical, token)
        if tree == nil {
            // No App view to show progress on, so appPending stays as it is.
            Task { [weak self] in
                let outcome = await Task.detached(priority: .userInitiated) { () -> AppFootprintOutcome in
                    do { return .success(try AppFootprintAnalyzer.analyze(tree: nil)) }
                    catch { return .failure(error.localizedDescription) }
                }.value
                guard let self, pendingUninstallPath?.model == ObjectIdentifier(self),
                      pendingUninstallPath?.path == canonical else { return }
                guard self.generation == token else { pendingUninstallPath = nil; return }
                self.landUninstallReport(outcome)
            }
        } else {
            view = .apps
            if let report = appReport, !appPending {
                finishPendingUninstall(in: report)
            } else {
                updateAppFootprint()
            }
        }
    }

    func landUninstallReport(_ outcome: AppFootprintOutcome) {
        switch outcome {
        case .success(let report):
            appReport = report
            appError = nil
            appPending = false
            finishPendingUninstall(in: report)
        case .failure(let error):
            appReport = nil
            appError = error
            appPending = false
            if let pending = pendingUninstallPath, pending.model == ObjectIdentifier(self),
               pending.generation == generation {
                pendingUninstallPath = nil
                alert = AppAlert(title: String(localized: "無法分析 App"), message: error)
            }
        }
    }

    private func finishPendingUninstall(in report: AppFootprintReport) {
        guard let pending = pendingUninstallPath,
              pending.model == ObjectIdentifier(self), pending.generation == generation else { return }
        pendingUninstallPath = nil
        if let app = OpenRequest.app(at: pending.path, in: report.apps) {
            requestUninstall(app)
        } else {
            alertAppNotFound()
        }
    }

    private func alertAppNotFound() {
        alert = AppAlert(title: String(localized: "沒有找到這個 App"),
                         message: String(localized: "Hoard 只能解除安裝「應用程式」資料夾（/Applications 或 ~/Applications）裡的 App。"))
    }

    func requestUninstall(_ app: AppFootprint) {
        guard let report = appReport else { return }
        Task { [weak self] in
            let plan = await Task.detached(priority: .userInitiated) {
                UninstallPlanner.plan(for: app, in: report)
            }.value
            self?.uninstallRequest = UninstallRequest(plan: plan)
        }
    }

    func confirmUninstall(_ plan: UninstallPlan, selected: Set<String>) {
        uninstallRequest = nil
        guard !finderUninstallBusy else {
            alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: String(localized: "Finder 還在處理上一個解除安裝，請等它完成。"))
            return
        }
        guard plan.refusal == nil, let bundle = plan.items.first(where: { $0.role == "app" && $0.path == plan.appPath }) else { return }
        let store = StoreRef(store: protectionStore)
        protectionQueue.async { [weak self] in
            let protected = store.store.items()
            let readError = store.store.readError
            let running = InstalledApps.runningPaths()
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard readError == nil else {
                    self.alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: String(localized: "讀不到保護清單，無法確認項目是否受保護。"))
                    return
                }
                guard let running else {
                    self.alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: String(localized: "無法確認這個 App 有沒有在執行，所以沒有移除。"))
                    return
                }
                guard !UninstallPlanner.isRunning(appPath: plan.appPath, runningPaths: running),
                      plan.bundleID.map({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) ?? true else {
                    self.alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: String(localized: "「\(plan.name)」正在執行，請先結束它。"))
                    return
                }
                await self.moveUninstallToTrash(bundle: bundle, plan: plan, selected: selected, protected: protected)
            }
        }
    }

    private func moveUninstallToTrash(bundle: UninstallItem, plan: UninstallPlan, selected: Set<String>,
                                      protected protectedAtStart: [ProtectedItem]) async {
        var protected = protectedAtStart
        guard let restore = Materialization.offForThread("uninstall move") else {
            alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: Materialization.refusedDetail)
            return
        }
        defer { restore() }
        func check(_ item: UninstallItem) -> String? {
            var st = stat()
            guard lstat(item.path, &st) == 0 else { return String(localized: "檔案已不在原處。") }
            if st.st_flags & UInt32(SF_DATALESS) != 0 { return String(localized: "沒有本機資料（iCloud），無法確認。") }
            let forbidden = ["/Library", "/System", "/usr", "/private", "/Users/Shared"]
            if forbidden.contains(where: { item.path == $0 || item.path.hasPrefix($0 + "/") }) {
                return String(localized: "位置不在可移除範圍。")
            }
            if item.role == "app" {
                guard UninstallPlanner.withinAppRoots(item.path, roots: ["/Applications", NSHomeDirectory() + "/Applications"]) else {
                    return String(localized: "這個 App 不在「應用程式」資料夾裡，請到它實際的位置移除。")
                }
            } else {
                let library = NSHomeDirectory() + "/Library"
                guard item.path.hasPrefix(library + "/"),
                      let root = realpath(library, nil), let target = realpath(item.path, nil) else {
                    return String(localized: "位置不在使用者 Library。")
                }
                defer { free(root); free(target) }
                guard String(cString: target).hasPrefix(String(cString: root) + "/") else {
                    return String(localized: "位置不在使用者 Library。")
                }
            }
            let directory = st.st_mode & S_IFMT == S_IFDIR
            let resolved = realpath(item.path, nil)
            let key = Self.protectionKey(resolved.map { String(cString: $0) } ?? item.path)
            if let resolved { free(resolved) }
            if Self.trashConflict(key: key, isDirectory: directory, in: protected) != nil {
                return String(localized: "項目或其內容受保護。請先在「受保護」裡解除保護。")
            }
            guard FileIdentity(device: item.device, fileID: item.fileID).stillAt(item.path) else {
                return String(localized: "檔案身分已改變，請重新分析。")
            }
            return nil
        }
        if let failure = check(bundle) {
            alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: String(localized: "App 本體：\(failure)"))
            return
        }
        let extras = plan.items.filter { $0.role != "app" && selected.contains($0.path) }
        var ready: [UninstallItem] = []
        var skipped: [String] = []
        for item in extras {
            if let failure = check(item) { skipped.append(String(localized: "\((item.path as NSString).lastPathComponent)：\(failure)")) }
            else { ready.append(item) }
        }
        var moved: [TrashedBatch.Entry] = []
        var logged: [CleanupLogEntry] = []
        var bytes: Int64 = 0
        var partial = false
        func record(_ item: UninstallItem) {
            bytes += item.size.bytes ?? 0
            partial = partial || item.size.status != .complete || item.size.bytes == nil
            logged.append(CleanupLogEntry(date: Date(), path: item.path, bytes: item.size.bytes ?? 0,
                                          source: "uninstall", partial: item.size.status != .complete || item.size.bytes == nil))
            if let tree {
                let path = item.path
                let node = tree.lookup(path: path) ?? tree.lookup(path: "/System/Volumes/Data" + path)
                if let node, !tree[node].isRemoved {
                    if selection == node { selection = nil }
                    tree.removeSubtree(node)
                }
            }
        }
        func trash(_ item: UninstallItem) throws {
            var before = stat()
            guard lstat(item.path, &before) == 0 else { throw CocoaError(.fileNoSuchFile) }
            var resulting: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &resulting)
            if let inTrash = resulting as URL? {
                moved.append(.init(original: URL(fileURLWithPath: item.path), inTrash: inTrash,
                                   isDirectory: before.st_mode & S_IFMT == S_IFDIR))
            }
            record(item)
        }
        guard let running = InstalledApps.runningPaths() else {
            alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: String(localized: "無法確認這個 App 有沒有在執行，所以沒有移除。"))
            return
        }
        guard !UninstallPlanner.isRunning(appPath: plan.appPath, runningPaths: running),
              plan.bundleID.map({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) ?? true else {
            alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: String(localized: "「\(plan.name)」正在執行，請先結束它。"))
            return
        }
        let finderMoved = !UninstallPlanner.userCanMove(bundle.path)
        do {
            if finderMoved {
                // Finder acts with an administrator's approval: re-check everything, protection included,
                // right before handing it the path.
                let store = StoreRef(store: protectionStore)
                let fresh = await withCheckedContinuation { continuation in
                    protectionQueue.async { continuation.resume(returning: (store.store.items(), store.store.readError)) }
                }
                guard fresh.1 == nil else {
                    alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: String(localized: "讀不到保護清單，無法確認項目是否受保護。"))
                    return
                }
                protected = fresh.0
                if let failure = check(bundle) {
                    alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: String(localized: "App 本體：\(failure)"))
                    return
                }
                finderUninstallBusy = true
                defer { finderUninstallBusy = false }
                let identity = FileIdentity(device: bundle.device, fileID: bundle.fileID)
                _ = try await Task.detached(priority: .userInitiated) { try moveAppWithFinder(bundle.path, identity: identity) }.value
                record(bundle)
            } else { try trash(bundle) }
        }
        catch {
            let gone = String(localized: "「\(plan.name)」已不在原處，可能已在垃圾桶；它的資料沒有移除。")
            let message: String
            switch error {
            case FinderUninstallError.cancelled: message = String(localized: "你取消了，沒有移除任何東西。")
            case FinderUninstallError.denied: message = String(localized: "Hoard 沒有控制 Finder 的權限。可以在 系統設定 › 隱私權與安全性 › 自動化 允許，或在 Finder 裡自己把它丟到垃圾桶。")
            case FinderUninstallError.changed: message = String(localized: "App 在確認之後換了位置或內容，沒有移除任何東西。請重新分析。")
            case FinderUninstallError.timedOut(let left):
                message = left ? gone : String(localized: "Finder 一小時內沒有完成，Hoard 沒有移除任何東西。若之後完成，App 會出現在垃圾桶。")
            case FinderUninstallError.failed(let detail, let left):
                message = left ? gone + "\n" + detail : String(localized: "App 本體無法移動：\(detail)")
            default: message = String(localized: "App 本體無法移動：\(Self.reason(error))")
            }
            alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: message)
            return
        }
        for item in ready {
            // The filesystem may change while a preceding item is being moved.
            if let failure = check(item) { skipped.append(String(localized: "\((item.path as NSString).lastPathComponent)：\(failure)")); continue }
            do { try trash(item) }
            catch { skipped.append(String(localized: "\((item.path as NSString).lastPathComponent)：\(Self.reason(error))")) }
        }
        changed()
        let batch = TrashedBatch(entries: moved, count: logged.count, bytes: bytes, partial: partial)
        if !moved.isEmpty { trashUndo.append(batch) }
        trashedBanner = batch
        Self.announce(String(localized: "已丟到垃圾桶：\(logged.count) 個項目。"))
        let shown = batch.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if self?.trashedBanner?.id == shown { self?.trashedBanner = nil }
        }
        writeCleanupLog(logged, failureTitle: String(localized: "清理紀錄未寫入"), failureText: String(localized: "項目已移到垃圾桶，但無法保存清理紀錄"))
        if !skipped.isEmpty {
            alert = AppAlert(title: String(localized: "部分項目已保留"), message: skipped.joined(separator: "\n"))
        }
        if finderMoved {
            let note = String(localized: "「\(plan.name)」由 Finder 丟到垃圾桶。要放回，請在垃圾桶裡用「放回原處」。")
            alert = AppAlert(title: String(localized: "已丟到垃圾桶"), message: ([note] + skipped).joined(separator: "\n"))
        }
        updateAppFootprint()
    }
}

struct UninstallSheet: View {
    @ObservedObject var model: AppModel
    let request: UninstallRequest
    @State private var selected: Set<String> = []

    private var plan: UninstallPlan { request.plan }
    private var total: SizeReading { plan.total(selected: selected.union([plan.appPath])) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("解除安裝「\(plan.name)」").font(.title3.weight(.semibold))
            if let refusal = plan.refusal {
                Text(refusal).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("好") { model.uninstallRequest = nil }.keyboardShortcut(.defaultAction) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(plan.items, id: \.path) { item in
                            HStack(alignment: .top, spacing: 8) {
                                if item.role == "app" {
                                    Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary)
                                        .frame(width: 20).accessibilityLabel("必選")
                                } else {
                                    Toggle(isOn: Binding(get: { selected.contains(item.path) }, set: { on in
                                        if on { selected.insert(item.path) } else { selected.remove(item.path) }
                                    })) { EmptyView() }.labelsHidden().frame(width: 20)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.kind?.rawValue ?? (item.role == "app" ? String(localized: "App 本體") : "LaunchAgent"))
                                        .fontWeight(.medium)
                                    Text(Fmt.tildePath(item.path)).lineLimit(1).truncationMode(.middle)
                                    Text(item.why).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 10)
                                Text(sizeText(item.size)).monospacedDigit()
                            }
                        }
                        if !plan.kept.isEmpty {
                            Divider()
                            Text("保留不動").fontWeight(.semibold)
                            ForEach(plan.kept, id: \.path) { kept in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Fmt.tildePath(kept.path)).lineLimit(1).truncationMode(.middle)
                                    Text(kept.why).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 330)
                Text("已選總計 \(sizeText(total))").fontWeight(.medium)
                if plan.appNeedsAdmin {
                    Text("「\(plan.name)」屬於系統管理員（例如從 App Store 安裝）。按下後會請 Finder 把它丟到垃圾桶，macOS 可能先問是否允許 Hoard 控制 Finder，再要求管理員密碼。它的資料仍由 Hoard 丟到垃圾桶。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    if plan.appNeedsAdmin {
                        bullet(String(localized: "這些項目會移到垃圾桶。App 本體要在垃圾桶裡用「放回原處」放回；它的資料也可以在 Hoard 選「編輯 › 還原」。"))
                    } else {
                        bullet(String(localized: "這些項目會移到垃圾桶。之後可以從垃圾桶放回原處，或在 Hoard 選「編輯 › 還原」。"))
                    }
                    bullet(String(localized: "清空垃圾桶後才會釋放空間；實際可能因共用資料不同。"))
                    bullet(String(localized: "其中有 App 的資料（位於 ~/Library）。刪除後，相關 App 可能需要重新下載資料，或無法正常運作。"))
                    bullet(String(localized: "已在執行的背景項目會到下次登入才停止。"))
                }.font(.callout)
                HStack {
                    Spacer()
                    Button("取消") { model.uninstallRequest = nil }.keyboardShortcut(.cancelAction)
                    Button("丟到垃圾桶") { model.confirmUninstall(plan, selected: selected) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 620)
        .onAppear { selected = Set(plan.items.filter(\.selectedByDefault).map(\.path)) }
    }

    private func sizeText(_ size: SizeReading) -> String {
        guard let bytes = size.bytes, size.status != .unavailable else { return String(localized: "無法得知") }
        return size.status == .partial ? (bytes > 0 ? "≥ \(Fmt.bytes(bytes))" : String(localized: "無法得知")) : Fmt.bytes(bytes)
    }

    private func bullet(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
    }
}
