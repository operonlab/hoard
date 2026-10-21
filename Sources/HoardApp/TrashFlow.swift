import AppKit
import SwiftUI
import ScanCore

/// One item the user asked to move to the Trash, with what it was when the sheet opened.
struct TrashItem: Identifiable {
    let id: NodeID
    let path: String
    let name: String
    let bytes: Int64
    let status: ScanStatus
    let isDirectory: Bool
    let identity: FileIdentity
    let sharesSpace: Bool
    let isAppData: Bool
}

struct TrashRequest: Identifiable {
    let id = UUID()
    let items: [TrashItem]
    let source: String
    /// The tree the items' node ids belong to. Weak, and compared by identity: an address (an
    /// ObjectIdentifier) can be reused by the next tree once this one is freed.
    weak var tree: FileTree?
    /// Set for a duplicate: the copy being trashed and the other copies, one of which must remain.
    var duplicate: (copy: DuplicateCopy, others: [DuplicateCopy])?
    var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var totalText: String {
        if items.contains(where: { $0.status != .complete }) {
            return total > 0 ? "≥ \(Fmt.bytes(total))" : String(localized: "無法得知")
        }
        return Fmt.bytes(total)
    }
}

/// What one confirmed request moved, for the banner and ⌘Z.
struct TrashedBatch: Identifiable {
    struct Entry { let original: URL; let inTrash: URL; let isDirectory: Bool }
    let id = UUID()
    let entries: [Entry]
    let count: Int
    let bytes: Int64
    let partial: Bool
}

extension AppModel {
    /// Asks to trash one copy of a duplicate group. Nothing is offered unless the copy and at least one
    /// other copy are still live in the tree at the paths the comparison used.
    func requestDuplicateTrash(_ member: DuplicateMember, others: [DuplicateMember]) {
        guard let tree, isLive(member.node), tree.path(of: member.node) == member.path,
              let copy = duplicateBaseline[member.node] else { return }
        let kept = others.filter { remainsAfterTrash($0) }.compactMap { duplicateBaseline[$0.node] }
        guard !kept.isEmpty else { return }
        requestTrash([member.node], source: "duplicates")
        guard trashRequest?.items.map(\.id) == [member.node] else { return }
        trashRequest?.duplicate = (copy, kept)
    }

    /// A copy that can be what stays: live at its compared path, and not itself in a Trash (emptying
    /// the Trash would then take both).
    func remainsAfterTrash(_ member: DuplicateMember) -> Bool {
        guard let tree, isLive(member.node), tree.path(of: member.node) == member.path else { return false }
        // Any user's ~/.Trash (root's too) or a volume's .Trashes.
        let components = Self.systemPath(member.path).split(separator: "/")
        return !components.contains(".Trash") && !components.contains(".Trashes")
    }

    func requestTrash(_ ids: [NodeID], source: String? = nil) {
        guard let tree else { return }
        let allowed = ids.filter { trashBlockReason($0) == nil }
        guard !allowed.isEmpty, allowed.count == ids.count else { return }
        let home = NSHomeDirectory()
        // Nested selections: trashing a folder already takes its contents.
        let paths = Set(allowed.map { tree.path(of: $0) })
        let items = allowed.compactMap { id -> TrashItem? in
            let path = tree.path(of: id)
            if paths.contains(where: { path.hasPrefix($0 + "/") }) { return nil }
            let node = tree[id]
            let system = Self.systemPath(path)
            return TrashItem(id: id, path: path, name: node.name, bytes: node.totalAlloc, status: node.status,
                             isDirectory: node.isDirectory,
                             identity: FileIdentity(node), sharesSpace: sharesSpace(id, in: tree),
                             isAppData: system.hasPrefix(home + "/Library/") || path.contains(".app/"))
        }
        let origin = source ?? { () -> String in
            switch view {
            case .map: return "map"
            case .stale: return "stale"
            case .largest: return "largest"
            case .types: return "types"
            case .changes: return "changes"
            case .cleanup: return "suggest"
            case .apps: return "apps"
            case .protected: return "protected"
            }
        }()
        trashRequest = TrashRequest(items: items, source: origin, tree: tree)
    }

    /// Hardlinked or APFS-cloned content inside `id` (bounded walk; a huge folder stops early).
    private func sharesSpace(_ id: NodeID, in tree: FileTree) -> Bool {
        var stack = [id]
        var budget = 200_000
        while let cur = stack.popLast(), budget > 0 {
            budget -= 1
            let node = tree[cur]
            if node.isRemoved { continue }
            if !node.isDirectory {
                if node.linkCount > 1 || node.cloneID != 0 || node.flags.contains(.cloneShared) { return true }
                continue
            }
            var child = node.firstChild
            while child >= 0 { stack.append(child); child = tree[child].nextSibling }
        }
        return false
    }

    /// Re-reads the protection registry (off the main thread: the guardian may hold it during a refresh),
    /// then moves what is still unprotected.
    func confirmTrash(_ request: TrashRequest) {
        trashRequest = nil
        let store = StoreRef(store: protectionStore)
        protectionQueue.async { [weak self] in
            let items = store.store.items()
            let readError = store.store.readError
            Task { @MainActor in
                // The request's node ids belong to the tree it was made from; a rescan meanwhile drops it.
                guard let self else { return }
                guard let current = self.tree, let requested = request.tree, current === requested else {
                    self.alert = AppAlert(title: String(localized: "沒有丟到垃圾桶"), message: String(localized: "掃描結果在確認期間換新了，所以沒有動任何項目。請重新選取後再試。"))
                    return
                }
                self.moveToTrash(request, protected: items, readError: readError)
            }
        }
    }

    /// Moves each item to the Trash after re-checking that it is not protected (an agent may have added
    /// protection while the sheet was open) and that its path still names the same file.
    private func moveToTrash(_ request: TrashRequest, protected: [ProtectedItem], readError: String?) {
        guard let tree else { return }
        var moved: [TrashedBatch.Entry] = []
        var movedCount = 0
        var bytes: Int64 = 0
        var partial = false
        var failure: AppAlert?
        var logged: [CleanupLogEntry] = []
        for item in request.items {
            if readError != nil {
                failure = AppAlert(title: String(localized: "無法把「\(item.name)」丟到垃圾桶"),
                                   message: String(localized: "讀不到保護清單，Hoard 無法確認它有沒有受保護，所以沒有動它。"))
                continue
            }
            if let kinds = Self.trashConflict(key: protectionKey(forTreePath: item.path), isDirectory: item.isDirectory, in: protected) {
                failure = AppAlert(title: String(localized: "無法把「\(item.name)」丟到垃圾桶"),
                                   message: kinds.isEmpty ? String(localized: "「\(item.name)」裡面有受保護的項目。要先在「受保護」裡解除保護。")
                                       : Self.protectedTrashText(item.name, kinds))
                continue
            }
            // The path may name a different file by now (deleted and recreated while the sheet was open).
            guard item.identity.stillAt(item.path) else {
                failure = AppAlert(title: String(localized: "無法把「\(item.name)」丟到垃圾桶"),
                                   message: String(localized: "它在確認期間被換成別的檔案或已經不在了，所以沒有動它。請重新選取後再試。"))
                continue
            }
            if let duplicate = request.duplicate {
                guard duplicate.copy.unchanged() else {
                    failure = AppAlert(title: String(localized: "無法把「\(item.name)」丟到垃圾桶"),
                                       message: String(localized: "它在比對之後被修改過，可能已經不是重複檔，所以沒有動它。請重新找重複檔。"))
                    continue
                }
                guard duplicate.others.contains(where: { $0.unchanged() }) else {
                    failure = AppAlert(title: String(localized: "無法把「\(item.name)」丟到垃圾桶"),
                                       message: String(localized: "其他副本已經不在或被修改過，這可能是最後一份，所以沒有動它。"))
                    continue
                }
            }
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &resulting)
                movedCount += 1
                if let inTrash = resulting as URL? {
                    moved.append(.init(original: URL(fileURLWithPath: item.path), inTrash: inTrash, isDirectory: item.isDirectory))
                }
                bytes += item.bytes
                partial = partial || item.status != .complete
                logged.append(CleanupLogEntry(date: Date(), path: item.path, bytes: item.bytes,
                                              source: request.source, partial: item.status != .complete))
                if selection == item.id { selection = nil }
                if Int(item.id) < tree.nodeCount, !tree[item.id].isRemoved, tree.path(of: item.id) == item.path {
                    tree.removeSubtree(item.id)
                }
            } catch {
                failure = AppAlert(title: String(localized: "無法把「\(item.name)」丟到垃圾桶"), message: Self.reason(error))
            }
        }
        if movedCount > 0 {
            changed()
            let batch = TrashedBatch(entries: moved, count: movedCount, bytes: bytes, partial: partial)
            if !moved.isEmpty { trashUndo.append(batch) }
            trashedBanner = batch
            let sizeText = partial ? (bytes > 0 ? String(localized: "至少 \(Fmt.bytes(bytes))") : String(localized: "大小無法得知")) : Fmt.bytes(bytes)
            Self.announce(String(localized: "已丟到垃圾桶：\(movedCount) 個項目，\(sizeText)。"))
            let shown = batch.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if self?.trashedBanner?.id == shown { self?.trashedBanner = nil }
            }
        }
        if let failure { alert = failure }
        writeCleanupLog(logged, failureTitle: String(localized: "清理紀錄未寫入"), failureText: String(localized: "項目已移到垃圾桶，但無法保存清理紀錄"))
    }

    /// Appends to the cleanup log off the main thread; the recent list updates when it lands.
    func writeCleanupLog(_ entries: [CleanupLogEntry], failureTitle: String, failureText: String) {
        guard !entries.isEmpty else { return }
        recentCleanupVersion += 1   // a load still in flight must not overwrite what this write returns
        let version = recentCleanupVersion
        CleanupLog.append(entries) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let rows): if self.recentCleanupVersion == version { self.recentCleanup = rows }
                case .failure(let error):
                    let detail = String(localized: "\(failureText)：\(error.localizedDescription)")
                    if let alert = self.alert {
                        self.alert = AppAlert(title: alert.title, message: alert.message + "\n" + detail)
                    } else {
                        self.alert = AppAlert(title: failureTitle, message: detail)
                    }
                }
            }
        }
    }

    var canUndoTrash: Bool { !trashUndo.isEmpty }

    /// 編輯 › 還原丟到垃圾桶 (⌘Z): puts the last batch back where it was.
    func undoTrash() {
        guard let batch = trashUndo.popLast() else { return }
        if trashedBanner?.id == batch.id { trashedBanner = nil }
        var restored = 0
        var putBack: [CleanupLogEntry] = []
        defer {
            writeCleanupLog(putBack, failureTitle: String(localized: "清理紀錄未更新"), failureText: String(localized: "項目已還原，但清理紀錄仍列著它"))
        }
        for entry in batch.entries {
            do {
                try FileManager.default.moveItem(at: entry.inTrash, to: entry.original)
                restored += 1
                putBack.append(CleanupLogEntry(date: Date(), path: entry.original.path, bytes: 0, source: "undo",
                                               partial: false, restored: true))
                reinsert(entry)
            } catch {
                alert = AppAlert(title: String(localized: "無法還原「\(entry.original.lastPathComponent)」"),
                                 message: FileManager.default.fileExists(atPath: entry.inTrash.path)
                                     ? Self.reason(error) : String(localized: "它已經不在垃圾桶裡。"))
            }
        }
        if restored > 0 { Self.announce(String(localized: "已還原 \(restored) 個項目。")) }
    }

    /// The live updater picks up a restored item from FSEvents; without it, read it back here.
    private func reinsert(_ entry: TrashedBatch.Entry) {
        guard !updaterActive, let tree else { return }
        let parentPath = entry.original.deletingLastPathComponent().path
        guard let parent = tree.lookup(path: parentPath) ?? tree.lookup(path: "/System/Volumes/Data" + parentPath),
              tree.child(named: entry.original.lastPathComponent, of: parent) == nil else { return }
        let scanner = ScanCore.Scanner()
        if entry.isDirectory {
            let path = entry.original.path
            let name = entry.original.lastPathComponent
            Task { [weak self] in
                guard let sub = try? await Task.detached(priority: .userInitiated, operation: { try scanner.scan(root: path) }).value,
                      let self, let tree = self.tree,
                      let parent = tree.lookup(path: parentPath) ?? tree.lookup(path: "/System/Volumes/Data" + parentPath) else { return }
                tree.graft(sub, as: name, under: parent)
                self.changed()
            }
        } else if let entries = try? scanner.listDirectory(parentPath),
                  let found = entries.first(where: { $0.name == entry.original.lastPathComponent }) {
            tree.insert(found, under: parent)
            changed()
        }
    }

    static func reason(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError) {
            return String(localized: "你沒有權限修改這個項目。")
        }
        return ns.localizedDescription
    }

    func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }
}

/// The confirmation sheet of §8.2.
struct TrashSheet: View {
    @ObservedObject var model: AppModel
    let request: TrashRequest

    var body: some View {
        let items = request.items
        let shared = items.filter(\.sharesSpace).count
        VStack(alignment: .leading, spacing: 14) {
            Text(items.count == 1 ? String(localized: "要把「\(items[0].name)」丟到垃圾桶嗎？") : String(localized: "要把 \(items.count) 個項目丟到垃圾桶嗎？"))
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.prefix(5)) { item in
                    HStack(spacing: 8) {
                        Image(nsImage: FileIcons.icon(forPath: item.path, isDirectory: item.isDirectory)).resizable().frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                        Text(item.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading)
                        Text(item.status == .complete ? Fmt.bytes(item.bytes) :
                             item.bytes > 0 ? "≥ \(Fmt.bytes(item.bytes))" : String(localized: "無法得知"))
                            .monospacedDigit().frame(width: 80, alignment: .trailing)
                        Text(Fmt.tildePath((item.path as NSString).deletingLastPathComponent))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                if items.count > 5 {
                    Text("還有 \(items.count - 5) 個項目").foregroundStyle(.secondary)
                }
            }
            Text("共 \(request.totalText)").fontWeight(.medium)
            VStack(alignment: .leading, spacing: 6) {
                bullet(items.count == 1 ? String(localized: "這個項目會移到垃圾桶。之後可以從垃圾桶放回原處，或在 Hoard 選「編輯 › 還原」。")
                       : String(localized: "這些項目會移到垃圾桶。之後可以從垃圾桶放回原處，或在 Hoard 選「編輯 › 還原」。"))
                bullet(String(localized: "清空垃圾桶後才會釋放空間；目前估算 \(request.totalText)，實際可能因共用資料不同。"))
                if shared > 0 {
                    bullet(String(localized: "其中 \(shared) 個項目和其他檔案共用磁碟空間（APFS 複製或硬連結），實際釋放的空間可能比較少。"))
                }
                if items.contains(where: \.isAppData) {
                    Label("其中有 App 的資料（位於 ~/Library）。刪除後，相關 App 可能需要重新下載資料，或無法正常運作。",
                          systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("取消") { model.trashRequest = nil }.keyboardShortcut(.cancelAction)
                Button("丟到垃圾桶") { model.confirmTrash(request) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "已丟到垃圾桶：{n} 個項目，{大小}。［還原］［打開垃圾桶］" (§8.4).
struct TrashedBanner: View {
    @ObservedObject var model: AppModel
    let batch: TrashedBatch

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("已丟到垃圾桶：\(batch.count) 個項目，\(batch.partial ? (batch.bytes > 0 ? "≥ \(Fmt.bytes(batch.bytes))" : String(localized: "大小無法得知")) : Fmt.bytes(batch.bytes))。")
            Spacer()
            Button("還原") { model.undoTrash() }.disabled(batch.entries.isEmpty)
            Button("打開垃圾桶") { model.openTrash() }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
