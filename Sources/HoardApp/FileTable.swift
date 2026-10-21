import AppKit
import SwiftUI
import ScanCore

/// One file (or folder, in search results) in a table, built off the main thread from a node snapshot.
struct FileRow: Identifiable, Sendable {
    let id: NodeID
    let name: String
    let bytes: Int64
    let status: ScanStatus
    let isDirectory: Bool
    let ext: String
    /// Parent folder relative to the table's base folder ("" when directly inside it).
    let location: String
    let parentPath: String
    let modTime: Int64
    let accessTime: Int64

    /// Newest of modification and access time: what 很久沒動 judges by (D1).
    var lastUsed: Int64 { max(modTime, accessTime) }
    var category: FileCategory { FileCategory.of(extension: ext) }
    var categoryTitle: String { isDirectory ? String(localized: "資料夾") : category.title }
    var size: String {
        switch status {
        case .complete: return Fmt.bytes(bytes)
        case .partial: return String(localized: "≥ \(Fmt.bytes(bytes))")
        case .unavailable: return String(localized: "無法讀取")
        }
    }

    static let limit = 1_000

    /// Rows for `ids`, with locations relative to `base`. Pure; safe on any thread.
    static func build(_ ids: [NodeID], nodes: [Node], rootPath: String, base: NodeID) -> [FileRow] {
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return ids.compactMap { id in
            guard nodes.indices.contains(Int(id)) else { return nil }
            let node = nodes[Int(id)]
            var absolute: [String] = []
            var relative: [String] = []
            var reachedBase = false
            var cur = node.parent
            while cur > FileTree.root {
                if cur == base { reachedBase = true }
                absolute.append(nodes[Int(cur)].name)
                if !reachedBase { relative.append(nodes[Int(cur)].name) }
                cur = nodes[Int(cur)].parent
            }
            if cur == base { reachedBase = true }
            let parentPath = absolute.isEmpty ? root : root + "/" + absolute.reversed().joined(separator: "/")
            return FileRow(id: id, name: node.name, bytes: node.isDirectory ? node.totalAlloc : node.ownAlloc,
                           status: node.status, isDirectory: node.isDirectory,
                           ext: node.isDirectory ? "" : FileTree.fileExtension(node.name),
                           location: reachedBase ? relative.reversed().joined(separator: "/") : Fmt.tildePath(parentPath),
                           parentPath: parentPath, modTime: node.modTime, accessTime: node.accessTime)
        }
    }
}

/// The shared file table of §4.1 / §4.3 / §5.2: multi-select, sortable, context menu, double-click
/// reveals in Finder, and a selection bar once something is selected.
struct FileTable: View {
    @ObservedObject var model: AppModel
    let rows: [FileRow]
    var dateTitle = String(localized: "修改日期")
    var showsType = true
    var useAccessDate = false
    var onRowAppear: ((FileRow) -> Void)? = nil
    @State private var selection = Set<NodeID>()
    @State private var sortOrder = [KeyPathComparator(\FileRow.bytes, order: .reverse)]
    @State private var sorted: [FileRow] = []
    @AppStorage(TextScale.key) private var scaleIndex = 1

    var body: some View {
        let scale = TextScale.factor(scaleIndex)
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名稱", value: \FileRow.name) { row in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.icon(forPath: row.parentPath + "/" + row.name, isDirectory: row.isDirectory))
                        .resizable()
                        .frame(width: 16 * scale, height: 16 * scale)
                        .accessibilityHidden(true)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    ProtectionGlyphs(kinds: model.protectionKinds(forTreePath: row.parentPath + "/" + row.name))
                }
                .help(row.name)
                .onAppear { onRowAppear?(row) }
            }
            .width(min: 160, ideal: 260)
            TableColumn("大小", value: \FileRow.bytes) { row in
                SizeText(row: row)
            }
            .width(min: 80, ideal: 96)
            TableColumn(showsType ? String(localized: "類型") : "", value: \FileRow.categoryTitle) { row in
                if showsType { TypeLabel(row: row) }
            }
            .width(min: showsType ? 90 : 0, ideal: showsType ? 120 : 0, max: showsType ? 200 : 0)
            TableColumn("位置", value: \FileRow.location) { row in
                Text(row.location.isEmpty ? model.scopeName : row.location)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(Fmt.tildePath(row.parentPath))
            }
            .width(min: 120, ideal: 220)
            TableColumn(dateTitle, value: useAccessDate ? \FileRow.lastUsed : \FileRow.modTime) { row in
                let date = Fmt.date(seconds: useAccessDate ? row.lastUsed : row.modTime)
                Text(Fmt.relative(date)).help(Fmt.relativeAndLong(date))
            }
            .width(min: 80, ideal: 100)
        }
        .font(.system(size: 13 * scale))
        .contextMenu(forSelectionType: NodeID.self) { ids in
            ItemMenu(model: model, ids: Array(ids))
        } primaryAction: { ids in
            model.reveal(Array(ids))
        }
        .onKeyPress(.space) {
            guard !selection.isEmpty else { return .ignored }
            model.quickLook(Array(selection))
            return .handled
        }
        .onChange(of: selection) { _, ids in
            // ⌘Y and ⌘⌫ act on the rows selected here, in the order shown; the last one is inspected.
            if ids.count == 1, let id = ids.first {
                model.select(id)
            } else if ids.count > 1 {
                let shown = sorted.map(\.id).filter(ids.contains)
                model.select(shown, primary: shown.last)
            }
        }
        .onChange(of: sortOrder) { _, order in sorted = rows.sorted(using: order) }
        .onChange(of: rows.map(\.id)) { _, _ in resort() }
        // A new tree reuses node ids for other files: never carry a selection across it.
        .onChange(of: model.tree.map(ObjectIdentifier.init)) { _, _ in selection = [] }
        .onAppear { resort() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty { SelectionBar(model: model, ids: Array(selection)) }
        }
    }

    private func resort() {
        sorted = rows.sorted(using: sortOrder)
        let live = Set(rows.map(\.id))
        selection = selection.filter { live.contains($0) }
    }
}

/// Size with the three-state rule (§7.1).
struct SizeText: View {
    let row: FileRow

    var body: some View {
        HStack(spacing: 3) {
            if row.status != .complete {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).imageScale(.small)
            }
            Text(row.size).monospacedDigit().foregroundStyle(row.status == .unavailable ? .secondary : .primary)
        }
        .help(row.status == .partial ? String(localized: "有些內容沒有權限讀取，實際大小至少這麼多") : row.status == .unavailable ? String(localized: "大小未知") : "")
        .accessibilityLabel(row.status == .partial ? String(localized: "至少 \(Fmt.bytes(row.bytes))，部分內容無法讀取")
                            : row.status == .unavailable ? String(localized: "大小未知，沒有權限讀取") : row.size)
    }
}

struct TypeLabel: View {
    let row: FileRow

    var body: some View {
        HStack(spacing: 5) {
            if !row.isDirectory {
                RoundedRectangle(cornerRadius: 2).fill(row.category.color).frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
            Text(row.categoryTitle).lineLimit(1)
        }
    }
}

/// "已選 {n} 個檔案，共 {大小}" with the selection actions (§5.2).
struct SelectionBar: View {
    @ObservedObject var model: AppModel
    let ids: [NodeID]

    var body: some View {
        let live = ids.filter { model.isLive($0) }
        let total = live.reduce(Int64(0)) { sum, id in
            guard let tree = model.tree else { return sum }
            return sum + (tree[id].isDirectory ? tree[id].totalAlloc : tree[id].ownAlloc)
        }
        let blocked = live.compactMap { model.trashBlockReason($0) }.first
        // Three-state (§7.1): a partial item makes the sum a lower bound; an unavailable one adds nothing known.
        let unknown = live.filter { model.tree?[$0].status == .unavailable }.count
        let partial = live.contains { model.tree?[$0].status == .partial }
        let totalText = unknown > 0 ? String(localized: "\(Fmt.bytes(total)) 以上（\(unknown) 項大小未知）")
            : partial ? String(localized: "至少 \(Fmt.bytes(total))") : Fmt.bytes(total)
        HStack(spacing: 10) {
            if live.contains(where: { model.tree?[$0].isDirectory == true }) {
                Text("已選 \(live.count) 個項目，共 \(totalText)").monospacedDigit()
            } else {
                Text("已選 \(live.count) 個檔案，共 \(totalText)").monospacedDigit()
            }
            Spacer()
            Button("快速查看") { model.quickLook(live) }
            Button("在 Finder 中顯示") { model.reveal(live) }
            Button("丟到垃圾桶…") { model.requestTrash(live) }
                .disabled(live.isEmpty || blocked != nil)
                .help(blocked ?? "")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Title + one-sentence answer above each list view, with a spinner after 300 ms of work (§7.2).
struct ViewHeader<Trailing: View>: View {
    let title: String
    let sentence: String
    var busy = false
    @ViewBuilder var trailing: () -> Trailing
    @State private var showSpinner = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.title2.weight(.semibold))
                if busy && showSpinner { ProgressView().controlSize(.small) }
                Spacer()
                trailing()
            }
            Text(sentence).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .task(id: busy) {
            showSpinner = false
            guard busy else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            showSpinner = !Task.isCancelled
        }
    }
}
