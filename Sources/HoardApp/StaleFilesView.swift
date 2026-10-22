import Foundation
import SwiftUI
import ScanCore

struct StaleResult: Sendable {
    let rows: [FileRow]       // the largest `FileRow.limit` matches
    let count: Int
    let bytes: Int64
    let cutoff: Date
    let months: Int
    let minSize: Int64
}

extension AppModel {
    static let staleMonthChoices = [6, 12, 24, 36]
    static let staleSizeChoices: [Int64] = [10_000_000, 100_000_000, 1_000_000_000]

    static func periodText(_ months: Int) -> String { months < 12 ? String(localized: "\(months) 個月") : String(localized: "\(months / 12) 年") }

    /// D1: `TreeQuery.staleFiles` (newest of modification and access time older than the cutoff),
    /// then the default exclusions of §5.2. Spotlight confirms the visible rows later.
    func updateStale() {
        guard view == .stale, tree != nil else { return }
        let months = staleMonths, minSize = staleMinSize, includeSystem = staleIncludeSystem
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .month, value: -months, to: Date()) ?? Date()
        let cutoffSeconds = Int64(cutoff.timeIntervalSince1970)
        let home = NSHomeDirectory()
        stalePending = true
        runJob("stale", work: { nodes, rootPath, dir in
            let ids = TreeQuery.staleFiles(in: nodes, under: dir, unusedSince: cutoffSeconds, minSize: minSize, limit: .max)
            let kept = includeSystem ? ids : ids.filter { !AppModel.isRoutinelyStale($0, nodes: nodes, rootPath: rootPath, home: home) }
            let bytes = kept.reduce(Int64(0)) { $0 + nodes[Int($1)].ownAlloc }
            let rows = FileRow.build(Array(kept.prefix(FileRow.limit)), nodes: nodes, rootPath: rootPath, base: dir)
            return StaleResult(rows: rows, count: kept.count, bytes: bytes, cutoff: cutoff, months: months, minSize: minSize)
        }, apply: { [weak self] result in
            self?.staleResult = result
            self?.stalePending = false
        })
    }

    /// Inside an app bundle, a system folder, ~/Library or a .git folder: places where files are
    /// expected not to change and removing them can break things (§5.2).
    nonisolated static func isRoutinelyStale(_ id: NodeID, nodes: [Node], rootPath: String, home: String) -> Bool {
        var parts: [String] = []
        var cur = nodes[Int(id)].parent
        while cur > FileTree.root {
            let name = nodes[Int(cur)].name
            if name == ".git" || name.lowercased().hasSuffix(".app") { return true }
            parts.append(name)
            cur = nodes[Int(cur)].parent
        }
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        let path = systemPath(root + "/" + parts.reversed().joined(separator: "/"))
        let roots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", home + "/Library"]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Queues a visible row for the Spotlight check (D1). Runs off the main thread in small batches.
    func confirmWithSpotlight(_ row: FileRow) {
        guard lastOpened[row.id] == nil, !spotlightQueue.contains(where: { $0.0 == row.id }) else { return }
        spotlightQueue.append((row.id, row.parentPath + "/" + row.name))
        guard spotlightTask == nil else { return }
        spotlightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            while true {
                guard let self, !self.spotlightQueue.isEmpty else { break }
                let batch = self.spotlightQueue
                self.spotlightQueue = []
                let owner = self.tree.map(ObjectIdentifier.init)
                let found = await Task.detached(priority: .utility) {
                    batch.map { ($0.0, Spotlight.lastUsedDate(path: $0.1)) }
                }.value
                // Ids from a tree replaced meanwhile name other files now.
                guard self.tree.map(ObjectIdentifier.init) == owner else { continue }
                for (id, date) in found { self.lastOpened[id] = .some(date) }
            }
            self?.spotlightTask = nil
        }
    }

    /// Rows Spotlight says were opened after the cutoff.
    func openedSinceCutoff(_ result: StaleResult) -> Set<NodeID> {
        Set(result.rows.compactMap { row in
            guard case .some(.some(let date)) = lastOpened[row.id], date > result.cutoff else { return nil }
            return row.id
        })
    }
}

/// 很久沒動的檔案 (§5).
struct StaleFilesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let result = model.staleResult
        let dropped = result.map { model.openedSinceCutoff($0) } ?? []
        let rows = model.visibleStaleRows
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("很久沒動的檔案").font(.title2.weight(.semibold))
                    if model.stalePending { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 6) {
                    Text("超過")
                    Picker("期間", selection: $model.staleMonths) {
                        ForEach(AppModel.staleMonthChoices, id: \.self) { Text(AppModel.periodText($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("沒有修改或取用、而且至少")
                    Picker("大小", selection: $model.staleMinSize) {
                        ForEach(AppModel.staleSizeChoices, id: \.self) { Text(Fmt.bytes($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("的檔案")
                }
                HStack {
                    Text(sentence(result, dropped: dropped)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("也顯示 App、系統與開發工具的資料", isOn: $model.staleIncludeSystem)
                }
                Text(basis).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if let result, rows.isEmpty, !model.stalePending {
                ContentUnavailableView {
                    Label("沒有符合的檔案", systemImage: "moon.zzz")
                } description: {
                    Text("\(model.scopeName) 裡沒有超過 \(AppModel.periodText(result.months)) 沒修改或取用、又大於 \(Fmt.bytes(result.minSize)) 的檔案。\n試試縮短期間或降低大小。")
                }
            } else {
                FileTable(model: model, rows: rows, dateTitle: String(localized: "上次修改或取用"), showsType: false, useAccessDate: true,
                          onRowAppear: { model.confirmWithSpotlight($0) })
                    .opacity(model.stalePending && !rows.isEmpty ? 0.5 : 1)
            }
        }
    }

    private var basis: String {
        if !model.staleIncludeSystem {
            return String(localized: "依「上次修改」與「上次取用」中較晚的日期判斷，畫面上的檔案再用 Spotlight 的「上次打開」核對。已略過 App、系統與 Git 資料，這些檔案很久不變是正常的。")
        }
        return String(localized: "依「上次修改」與「上次取用」中較晚的日期判斷，畫面上的檔案再用 Spotlight 的「上次打開」核對。")
    }

    private func sentence(_ result: StaleResult?, dropped: Set<NodeID>) -> String {
        guard let result else { return model.stalePending ? String(localized: "正在尋找⋯") : "" }
        let droppedBytes = result.rows.filter { dropped.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
        if !dropped.isEmpty {
            return String(localized: "\(model.scopeName) 裡找到 \(result.count - dropped.count) 個，共 \(Fmt.bytes(result.bytes - droppedBytes))。已排除 \(dropped.count) 個 Spotlight 記錄最近打開過的檔案。")
        }
        return String(localized: "\(model.scopeName) 裡找到 \(result.count - dropped.count) 個，共 \(Fmt.bytes(result.bytes - droppedBytes))。")
    }
}

extension AppModel {
    var visibleStaleRows: [FileRow] {
        guard let result = staleResult else { return [] }
        let dropped = openedSinceCutoff(result)
        return result.rows.filter { !dropped.contains($0.id) }
    }
}
