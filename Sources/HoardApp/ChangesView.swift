import AppKit
import Foundation
import SwiftUI
import ScanCore

/// What 最近變動 can show (§6). Three states plus the report: no baseline is not "no change",
/// and a history error is neither.
enum ChangesState {
    case noBaseline
    case failed(String)
    case report(DiffReport, baseline: HistoryVersion)
}

/// One row of the change list: a folder hotspot or a big file.
struct ChangeRow: Identifiable {
    enum Kind { case grown, shrunk, added, removed }
    let id: String          // absolute path
    let name: String
    let location: String    // parent, relative to the scope
    let kind: Kind
    let before: Int64
    let after: Int64
    let isDirectory: Bool
    /// Either side of a folder was not fully readable: sizes are lower bounds and the change may be
    /// a permission change rather than growth or freed space.
    var uncertain = false
    var delta: Int64 { after - before }
}

extension AppModel {
    /// Saves a history version of `tree`. Placeholder bodies throw `notImplemented`: that is expected
    /// until the history lane lands, so it is not logged as a failure.
    nonisolated static func recordHistory(_ tree: FileTree) {
        do {
            try SnapshotHistory(rootPath: tree.rootPath).record(tree)
        } catch HistoryError.notImplemented {
        } catch {
            NSLog("Hoard 無法保存比較基準：%@", String(describing: error))
        }
    }

    func scheduleChanges(delay: TimeInterval) {
        changesDebounce?.cancel()
        guard tree != nil else { return }
        changesDebounce = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.updateChanges()
        }
    }

    /// D2: latest saved version vs the live tree, via `TreeSummary(tree:createdAt:)` and `TreeDiff.compare`.
    // ponytail: rebuilds the live summary from scratch (O(n)) at most every 5 s of live changes;
    // update the summary incrementally if whole-disk roots make this noticeable.
    private func updateChanges() {
        guard let tree else { return }
        changesPending = true
        let device = tree.device
        runJob("changes", work: { nodes, rootPath, _ in
            let history = SnapshotHistory(rootPath: rootPath)
            do {
                guard let latest = try history.versions().first else { return ChangesState.noBaseline }
                let baseline: TreeSummary
                do {
                    baseline = try history.load(latest.id)
                } catch HistoryError.notFound, HistoryError.notImplemented {
                    return .noBaseline
                }
                let live = TreeSummary(tree: FileTree(restoring: nodes, rootPath: rootPath, device: device), createdAt: Date())
                return .report(TreeDiff.compare(baseline, live), baseline: latest)
            } catch HistoryError.notImplemented {
                return .noBaseline
            } catch {
                return .failed(String(describing: error))
            }
        }, apply: { [weak self] state in
            self?.changes = state
            self?.changesPending = false
        })
    }

    /// 從現在重新比較: the current tree becomes the baseline. Touches no user file.
    func resetChangesBaseline() {
        guard let tree else { return }
        let nodes = tree.nodes, rootPath = tree.rootPath, device = tree.device
        changesPending = true
        Task { [weak self] in
            let outcome: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try SnapshotHistory(rootPath: rootPath).record(FileTree(restoring: nodes, rootPath: rootPath, device: device))
                    return nil
                } catch HistoryError.notImplemented {
                    return String(localized: "這個版本還不能保存比較基準。")
                } catch {
                    return String(localized: "無法保存比較基準：\(error.localizedDescription)")
                }
            }.value
            guard let self else { return }
            self.changesNote = outcome
            self.scheduleChanges(delay: 0)
        }
    }

    /// Net change of the whole root, for the sidebar badge (shown above 100 MB).
    var changesNet: Int64? {
        guard case .report(let report, _) = changes else { return nil }
        return report.totalDelta
    }

    /// Rows inside the scope, largest |change| first, each change at or above 1 MB.
    func changeRows(_ report: DiffReport) -> [ChangeRow] {
        guard let tree else { return [] }
        let scopePath = tree.path(of: scope)
        let base = scopePath.hasSuffix("/") ? String(scopePath.dropLast()) : scopePath
        func inScope(_ path: String) -> Bool { scope == FileTree.root || path.hasPrefix(base + "/") }
        func location(_ path: String) -> String {
            let parent = (path as NSString).deletingLastPathComponent
            return parent == base ? "" : parent.hasPrefix(base + "/") ? String(parent.dropFirst(base.count + 1)) : parent
        }
        var rows: [ChangeRow] = []
        for change in report.grown + report.shrunk where inScope(change.path) && abs(change.delta) >= 1_048_576 {
            let kind: ChangeRow.Kind = change.kind == .added ? .added : change.kind == .removed ? .removed
                : change.delta >= 0 ? .grown : .shrunk
            rows.append(ChangeRow(id: change.path, name: (change.path as NSString).lastPathComponent,
                                  location: location(change.path), kind: kind, before: change.before,
                                  after: change.after, isDirectory: true, uncertain: change.uncertain))
        }
        for change in report.files where inScope(change.path) && abs(change.delta) >= 1_048_576 {
            let kind: ChangeRow.Kind
            switch change.kind {
            case .added: kind = .added
            case .removed: kind = .removed
            case .grown: kind = .grown
            case .shrunk: kind = .shrunk
            }
            rows.append(ChangeRow(id: change.path, name: (change.path as NSString).lastPathComponent,
                                  location: location(change.path), kind: kind, before: change.before,
                                  after: change.after, isDirectory: false))
        }
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }.sorted { abs($0.delta) > abs($1.delta) }
    }
}

/// 最近變動 (§6).
struct ChangesView: View {
    @ObservedObject var model: AppModel
    @State private var filter: Filter = .all
    @State private var selection = Set<String>()

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", grown = "變大", shrunk = "變小", added = "新增", removed = "已移除"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "全部")
            case .grown: String(localized: "變大")
            case .shrunk: String(localized: "變小")
            case .added: String(localized: "新增")
            case .removed: String(localized: "已移除")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch model.changes {
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noBaseline:
                ContentUnavailableView {
                    Label("還沒有可以比較的掃描", systemImage: "arrow.up.arrow.down")
                } description: {
                    Text("Hoard 會記住這次的結果。下次打開時，這裡會列出期間變大、變小、新增和移除的項目。")
                } actions: {
                    if let note = model.changesNote { Text(note).foregroundStyle(.secondary) }
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("無法讀取先前的掃描", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("從現在重新比較") { model.resetChangesBaseline() }
                }
            case .report(let report, let baseline):
                content(report, baseline: baseline)
            }
        }
    }

    @ViewBuilder private func content(_ report: DiffReport, baseline: HistoryVersion) -> some View {
        let rows = model.changeRows(report)
        let shown = rows.filter(matches)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("最近變動").font(.title2.weight(.semibold))
                if model.changesPending { ProgressView().controlSize(.small) }
                Spacer()
                Button("從現在重新比較") { model.resetChangesBaseline() }
            }
            Text("和 \(Fmt.dayAndTime(baseline.createdAt)) 的掃描相比（\(Fmt.relative(baseline.createdAt))）")
                .foregroundStyle(.secondary)
            if let note = model.changesNote { Text(note).font(.callout).foregroundStyle(.secondary) }
            summaryCards(rows, report: report)
            HStack {
                Picker("篩選", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("只列出變化超過 1 MB 的項目").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        Divider()
        if rows.isEmpty {
            ContentUnavailableView("沒有變化", systemImage: "checkmark.circle",
                                   description: Text("自 \(Fmt.day(baseline.createdAt)) 以來沒有超過 1 MB 的變化。"))
        } else {
            Table(shown, selection: $selection) {
                TableColumn("名稱") { row in name(row) }.width(min: 200, ideal: 320)
                TableColumn("變化") { row in delta(row) }.width(min: 90, ideal: 110)
                TableColumn("現在") { row in
                    Text(row.kind == .removed ? "—" : size(row.after, row)).monospacedDigit()
                }
                .width(min: 80, ideal: 90)
                TableColumn("之前") { row in
                    Text(row.kind == .added ? "—" : size(row.before, row)).monospacedDigit()
                }
                .width(min: 80, ideal: 90)
            }
            .contextMenu(forSelectionType: String.self) { paths in
                menu(for: paths)
            } primaryAction: { paths in
                if let id = paths.first.flatMap({ model.tree?.lookup(path: $0) }) { model.reveal(id) }
            }
        }
    }

    private func matches(_ row: ChangeRow) -> Bool {
        switch filter {
        case .all: return true
        // An uncertain row may be a permission change, not growth or freed space (same rule as the totals).
        case .grown: return !row.uncertain && row.delta > 0
        case .shrunk: return !row.uncertain && row.delta < 0
        case .added: return row.kind == .added
        case .removed: return row.kind == .removed
        }
    }

    private func summaryCards(_ rows: [ChangeRow], report: DiffReport) -> some View {
        // Uncertain rows may be permission changes, not growth or freed space: kept out of the totals.
        let certain = rows.filter { !$0.uncertain }
        let uncertainCount = rows.count - certain.count
        // A folder row already contains the rows listed inside it: count each change once.
        let (up, down) = TreeDiff.listedTotals(certain.map { (path: $0.id, delta: $0.delta) })
        // Below the root the report has no exact total for the scope; the listed changes are the estimate.
        let net = model.scope == FileTree.root ? report.totalDelta : up + down
        // The root totals include changes omitted by the row threshold and top-N filter.
        let netUncertain = model.scope == FileTree.root &&
            (report.rootStatusBefore != .complete || report.rootStatusAfter != .complete)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                card(String(localized: "⬆ 變大"), Fmt.delta(up), tint: .orange)
                card(String(localized: "⬇ 變小"), Fmt.delta(down), tint: .green)
                card(String(localized: "淨變化"), netUncertain ? String(localized: "不確定") : Fmt.delta(net), tint: netUncertain ? .secondary : .primary)
            }
            if uncertainCount > 0 {
                Text("另有 \(uncertainCount) 項變化不確定").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func card(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    private func name(_ row: ChangeRow) -> some View {
        HStack(spacing: 6) {
            Image(systemName: row.isDirectory ? "folder" : "doc").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                if !row.location.isEmpty {
                    Text(row.location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if row.kind == .added || row.kind == .removed {
                Text(row.kind == .added ? String(localized: "新增") : String(localized: "已移除"))
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().stroke(Color.secondary.opacity(0.6)))
            }
        }
        .foregroundStyle(row.kind == .removed ? .secondary : .primary)
        .help(row.id)
    }

    /// 現在／之前: a lower bound when the change is uncertain (§7.1).
    private func size(_ bytes: Int64, _ row: ChangeRow) -> String {
        row.uncertain ? String(localized: "≥ \(Fmt.bytes(bytes))") : Fmt.bytes(bytes)
    }

    @ViewBuilder private func delta(_ row: ChangeRow) -> some View {
        if row.uncertain {
            Text("不確定")
                .foregroundStyle(.secondary)
                .help("有些內容沒有權限讀取，這個變化可能只是權限改變")
                .accessibilityLabel("變化不確定")
        } else {
            signedDelta(row)
        }
    }

    private func signedDelta(_ row: ChangeRow) -> some View {
        HStack(spacing: 3) {
            Text(row.delta >= 0 ? "⬆" : "⬇").accessibilityHidden(true)
            Text(Fmt.delta(row.delta)).monospacedDigit()
        }
        .foregroundStyle(row.delta >= 0 ? Color.orange : Color.green)
        .accessibilityLabel(row.delta >= 0 ? String(localized: "變大 \(Fmt.bytes(row.delta))") : String(localized: "變小 \(Fmt.bytes(-row.delta))"))
    }

    @ViewBuilder private func menu(for paths: Set<String>) -> some View {
        let ids = paths.compactMap { model.tree?.lookup(path: $0) }
        if ids.isEmpty {
            // Removed items only offer their path (§6.3).
            Button("拷貝路徑") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths.sorted().joined(separator: "\n"), forType: .string)
            }
        } else {
            ItemMenu(model: model, ids: ids)
        }
    }
}
