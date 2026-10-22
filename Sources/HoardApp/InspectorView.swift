import AppKit
import SwiftUI
import ScanCore

/// Trailing inspector (§1.5): the selection, or the scope when nothing is selected.
struct InspectorView: View {
    @ObservedObject var model: AppModel
    @State private var diagnosis: UnreadableDiagnosis?
    @State private var diagnosisKey = ""

    var body: some View {
        // The inspector runs under the toolbar. While the ScrollView took the toolbar as its top inset,
        // AppKit-backed controls (bordered buttons, `.help` tooltips) took the pointer one toolbar height
        // below where they were drawn (macOS 27): 鎖定… did nothing and 快速查看 opened its sheet. So the
        // ScrollView ignores the top safe area and the content pads itself by it instead.
        GeometryReader { geometry in
            ScrollView {
                content.padding(.top, geometry.safeAreaInsets.top)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.showInspector.toggle() } label: {
                    Label("顯示或隱藏檢閱器", systemImage: "sidebar.trailing")
                }
                .help("顯示或隱藏檢閱器")
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let merged = model.mergedSelection {
            mergedDetails(merged)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let tree = model.tree, Int(model.focus) < tree.nodeCount, !tree[model.focus].isRemoved {
            details(tree: tree, id: model.focus)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("沒有選取項目")
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }

    @ViewBuilder private func details(tree: FileTree, id: NodeID) -> some View {
        let node = tree[id]
        let path = tree.path(of: id)
        let parent = node.parent >= 0 ? tree[node.parent] : node
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: FileIcons.icon(forPath: path, isDirectory: node.isDirectory))
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name(of: id))
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                kindLabel(node, path: path)
            }
            .contextMenu { ItemMenu(model: model, ids: [id]) }
            VStack(alignment: .leading, spacing: 6) {
                Text(Fmt.sizeLong(node))
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityLabel(Fmt.sizeSpoken(node))
                if node.status == .unavailable {
                    if diagnosisKey == "\(id):\(path):\(node.status)", let diagnosis {
                        UnreadableExplanation(model: model, diagnosis: diagnosis)
                    } else {
                        Text("正在確認讀不到的原因⋯").font(.callout).foregroundStyle(.secondary)
                    }
                } else if node.status == .partial {
                    Text("裡面有讀不到的資料夾").font(.callout).foregroundStyle(.secondary)
                    Button("看原因…") { model.unreadableSheetNode = id }
                }
                if id != FileTree.root, let ratio = Fmt.ratio(node, of: parent) {
                    HStack {
                        ProgressView(value: ratio).frame(maxWidth: 120)
                        Text("佔上層 \(Fmt.share(node, of: parent))").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            field(String(localized: "位置"), Fmt.tildePath((path as NSString).deletingLastPathComponent))
            field(String(localized: "修改日期"), Fmt.relativeAndLong(Fmt.date(seconds: node.modTime)))
            if node.isDirectory && node.status != .unavailable {
                field(String(localized: "內容"), String(localized: "\(node.fileCount) 個檔案・\(max(0, node.dirCount - 1)) 個資料夾"))
            }
            if !node.isDirectory && node.rawAlloc != node.ownAlloc {
                VStack(alignment: .leading, spacing: 2) {
                    Label("與其他檔案共用空間", systemImage: "square.on.square")
                    Text("檔案系統回報 \(Fmt.bytes(node.rawAlloc))，去重後算 \(Fmt.bytes(node.ownAlloc))")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            protectionSection(tree: tree, id: id)
            Divider()
            actions(tree: tree, id: id)
        }
        .task(id: "\(id):\(path):\(node.status)") {
            diagnosis = nil
            diagnosisKey = "\(id):\(path):\(node.status)"
            guard node.status == .unavailable else { return }
            let access = model.fullDiskAccess
            let result = await Task.detached(priority: .userInitiated) {
                Unreadable.diagnose(path, fullDiskAccess: access)
            }.value
            if !Task.isCancelled { diagnosis = result }
        }
    }

    /// 保護: what covers this item (itself or a folder above it), its health and actions, and the
    /// buttons for the kinds that do not cover it yet.
    @ViewBuilder private func protectionSection(tree: FileTree, id: NodeID) -> some View {
        let snapshot = model.protection
        let key = model.protectionKey(of: id) ?? ""
        let rows = snapshot.covering(key)
        let inside = tree[id].isDirectory ? snapshot.inside(key).count : 0
        let covered = Set(rows.map(\.item.kind))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("保護")
                ProtectionHelpButton()
            }
            .font(.caption).foregroundStyle(.secondary)
            if !snapshot.loaded {
                Text("正在讀取⋯").foregroundStyle(.secondary)
            } else {
                if snapshot.readError != nil {
                    Label("讀不到保護清單，這裡的狀態可能不完整。", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if rows.isEmpty { Text("沒有保護") }
                ForEach(rows) { row in protectionCard(row, own: row.key == key) }
                if inside > 0 {
                    Text("裡面有 \(inside) 個受保護的項目。").font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ForEach([ProtectionKind.lock, .guarded].filter { !covered.contains($0) }, id: \.self) { kind in
                        Button("\(kind.title)…") { model.requestProtect(id, kind: kind) }.help(kind.explanation)
                    }
                }
            }
        }
    }

    private func protectionCard(_ row: ProtectionRow, own: Bool) -> some View {
        let item = row.item
        let who = AppModel.protectorName(item.createdBy)
        return VStack(alignment: .leading, spacing: 4) {
            Label(own ? item.kind.title : String(localized: "\(item.kind.title)（在「\(row.name)」的範圍內）"), systemImage: item.kind.symbol)
                .help(item.kind.explanation)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            HealthLabel(health: row.health)
            if row.health == .aclMissing {
                Text(item.kind == .lock ? String(localized: "有人在 Hoard 以外拿掉了鎖，現在可以被刪除。")
                     : String(localized: "有人在 Hoard 以外拿掉了保險庫的鎖，備份現在可以被刪除。"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("由\(who)加入・\(AppModel.agoText(item.createdAt, now: model.clock))")
                .foregroundStyle(.secondary)
                .help(Fmt.dayAndTime(item.createdAt))
            if let note = item.note, !note.isEmpty {
                Text("備註：\(note)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                switch row.health {
                case .aclMissing: Button("重新鎖定") { model.repairProtection(row) }
                case .vaultMissing: Button("重新備份") { model.refreshVault(row) }
                case .itemMissing(restorable: true): Button("放回") { model.restoreProtected(row) }
                default: EmptyView()
                }
                Button("解除保護…") { model.confirmUnprotect(row) }
            }
            .controlSize(.small)
        }
        .font(.callout)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    /// The ⓘ beside 保護. Resting the pointer on it shows what 鎖定 and 守護 do; a click keeps that open
    /// until Esc or a click elsewhere. A popover rather than `.help`, so a click shows it too.
    private struct ProtectionHelpButton: View {
        @State private var shown = false
        @State private var pinned = false
        @State private var hovering = false

        var body: some View {
            Button {
                pinned = !(shown && pinned)
                shown = pinned
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovering = inside
                if inside {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        if hovering { shown = true }
                    }
                } else if !pinned {
                    shown = false
                }
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ProtectionKind.lock.explanation)
                    Text(ProtectionKind.guarded.explanation)
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
            }
            .onChange(of: shown) { _, now in if !now { pinned = false } }
            .accessibilityLabel("鎖定與守護的說明")
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    /// "模型與資料・檔案", "資料夾", "App", "照片圖庫" (§1.5, §3.2).
    private func kindText(_ node: Node, path: String) -> String {
        if node.isDirectory {
            switch FileTree.fileExtension(node.name) {
            case "app": return "App"
            case "photoslibrary": return String(localized: "照片圖庫")
            case "bundle", "framework", "plugin", "kext": return String(localized: "套件")
            default: return String(localized: "資料夾")
            }
        }
        return String(localized: "\(FileCategory.of(extension: FileTree.fileExtension(node.name)).title)・檔案")
    }

    @ViewBuilder private func kindLabel(_ node: Node, path: String) -> some View {
        HStack(spacing: 6) {
            if !node.isDirectory {
                Circle().fill(FileCategory.of(extension: FileTree.fileExtension(node.name)).color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(kindText(node, path: path)).foregroundStyle(.secondary)
        }
    }

    private func mergedDetails(_ merged: MergedInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("其他 \(merged.count) 項").font(.title3.weight(.semibold))
            Text("這裡合併了 \(merged.count) 個較小的項目，共 \(Fmt.bytes(merged.bytes))。")
                .fixedSize(horizontal: false, vertical: true)
            Button("用清單查看") {
                model.view = .map
                model.mapMode = .list
                model.select(merged.parent)
            }
        }
    }

    @ViewBuilder private func actions(tree: FileTree, id: NodeID) -> some View {
        let blocked = model.trashBlockReason(id)
        VStack(alignment: .leading, spacing: 8) {
            Button("快速查看") { model.quickLook([id]) }
            Button("在 Finder 中顯示") { model.reveal(id) }
            Button("拷貝路徑") { model.copyPath(id) }
            Button("丟到垃圾桶…") { model.requestTrash([id]) }
                .disabled(blocked != nil)
                .help(blocked ?? String(localized: "把「\(model.name(of: id))」移到垃圾桶"))
        }
    }
}
