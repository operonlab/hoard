import AppKit
import Foundation
import SwiftUI
import ScanCore

extension ProtectionKind {
    var title: String { self == .lock ? String(localized: "鎖定") : String(localized: "守護") }
    var symbol: String { self == .lock ? "lock.fill" : "shield.lefthalf.filled" }
    /// Hover help wherever the kind is named; the add sheet says the same at length.
    var explanation: String {
        self == .lock
            ? String(localized: "鎖定：不能刪除、搬移或取代，但可以直接修改內容。適合已完成的成品，例如模型、資料集、照片、封存檔。")
            : String(localized: "守護：可以自由修改；被刪除時 Hoard 會自動放回最新版本（最多保留 3 個版本）。適合正在編輯的檔案。")
    }
}

/// One registry entry with its health, read off the main thread.
struct ProtectionRow: Identifiable, Equatable {
    let item: ProtectedItem
    let health: ProtectionHealth
    /// `item.path` in the form the rest of the app compares against (see `AppModel.protectionKey`).
    let key: String
    var id: String { item.id }
    var name: String {
        let name = (item.path as NSString).lastPathComponent
        return name.isEmpty ? item.path : name
    }
}

/// What the app knows about protection. Views and menus read this; they never call the store,
/// whose reads lock the registry and walk ACLs.
struct ProtectionSnapshot {
    var rows: [ProtectionRow] = []
    var readError: String?
    /// False until the first read lands: the view must not claim "nothing is protected" before that.
    var loaded = false
    /// Bumped only when rows or the error change, so the map and outline redraw only then.
    var version = 0

    /// Entries that cover `key`: the item itself or a protected folder above it, innermost first.
    func covering(_ key: String) -> [ProtectionRow] {
        rows.filter { $0.key == key || ($0.item.isDirectory && key.hasPrefix($0.key + "/")) }
            .sorted { $0.key.count > $1.key.count }
    }

    func kinds(_ key: String) -> [ProtectionKind] {
        let found = Set(covering(key).map(\.item.kind))
        return [ProtectionKind.lock, .guarded].filter { found.contains($0) }
    }

    /// Protected entries strictly inside the folder `key`.
    func inside(_ key: String) -> [ProtectionRow] {
        let prefix = key == "/" ? "/" : key + "/"
        return rows.filter { $0.key != key && $0.key.hasPrefix(prefix) }
    }

    var problemCount: Int { rows.filter { $0.health != .intact }.count }
}

/// 「已放回「X」」: guardian restores while the banner is up are folded into one line.
struct RestoredNotice: Identifiable {
    let id = UUID()
    let names: [String]
    var text: String {
        names.count == 1 ? String(localized: "已放回「\(names[0])」") : String(localized: "已放回「\(names.last ?? "")」等 \(names.count) 個項目")
    }
}

/// 鎖定… / 守護… on one item, waiting for the sheet's confirmation.
struct ProtectRequest: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let kind: ProtectionKind
    let isDirectory: Bool
}

/// Hands the store to the protection queue. It serialises its own state with a lock and the registry
/// with flock, which is what lets the guardian's queue call it too.
struct StoreRef: @unchecked Sendable { let store: ProtectionStore }
struct GuardianRef: @unchecked Sendable { let guardian: ProtectionGuardian }

/// One guardian (or 放回 button) action for 最近動作.
struct GuardianEntry: Identifiable {
    let id = UUID()
    let action: GuardianAction
    let at: Date
}

extension AppModel {
    // MARK: Store

    /// `--protection-store <dir>` points the app at a test registry. A flag without a usable directory
    /// stops the launch: falling back to the real registry would touch real files.
    static func makeProtectionStore() -> ProtectionStore {
        guard CommandLine.arguments.contains("--protection-store") else { return ProtectionStore() }
        guard let dir = LaunchOptions.value("--protection-store"), !dir.isEmpty, !dir.hasPrefix("--") else {
            FileHandle.standardError.write(Data("--protection-store needs a directory\n".utf8))
            exit(2)
        }
        return ProtectionStore(directory: URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL)
    }

    /// Re-reads the registry and every entry's health on the protection queue.
    func refreshProtection() {
        protectionLoadToken += 1
        let token = protectionLoadToken
        let store = StoreRef(store: protectionStore)
        protectionQueue.async { [weak self] in
            let loaded = AppModel.loadProtection(store.store)
            Task { @MainActor in
                guard let self, token == self.protectionLoadToken else { return }
                if self.protection.loaded && loaded.rows == self.protection.rows && loaded.readError == self.protection.readError {
                    return
                }
                var next = loaded
                next.version = self.protection.version + 1
                self.protection = next
            }
        }
    }

    /// `readError` is read after the calls that set it, the same way the CLI does.
    nonisolated static func loadProtection(_ store: ProtectionStore) -> ProtectionSnapshot {
        let items = store.items()
        var error = store.readError
        let rows = items.map { item -> ProtectionRow in
            let health = store.health(item.id)
            error = error ?? store.readError
            return ProtectionRow(item: item, health: health, key: protectionKey(item.path))
        }
        let ordered = rows.sorted {
            ($0.health != .intact) != ($1.health != .intact) ? $0.health != .intact : $0.item.createdAt > $1.item.createdAt
        }
        return ProtectionSnapshot(rows: ordered, readError: error, loaded: true)
    }

    // MARK: Matching tree nodes to entries

    /// The comparison form of a real path: the data volume's firmlinked view ("/Users/…", not
    /// "/System/Volumes/Data/Users/…"). The store keeps realpaths, so entries added through either
    /// form end up comparable.
    nonisolated static func protectionKey(_ path: String) -> String { systemPath(path) }

    /// The comparison form of a path inside the current tree. The tree keeps the root as typed
    /// ("/tmp/x"); the store keeps realpaths ("/private/tmp/x").
    func protectionKey(forTreePath path: String) -> String {
        guard let tree else { return Self.protectionKey(path) }
        let root = tree.rootPath
        let base: String
        if let cached = protectionRootKey, cached.root == root {
            base = cached.key
        } else {
            var resolved = root
            if let real = realpath(root, nil) { resolved = String(cString: real); free(real) }
            base = Self.protectionKey(resolved)
            protectionRootKey = (root, base)
        }
        guard path.hasPrefix(root) else { return Self.protectionKey(path) }
        var rest = String(path.dropFirst(root.count))
        if rest.isEmpty { return base }
        if !rest.hasPrefix("/") { rest = "/" + rest }
        return base == "/" ? rest : base + rest
    }

    func protectionKey(of id: NodeID) -> String? {
        guard let tree, isLive(id) else { return nil }
        return protectionKey(forTreePath: tree.path(of: id))
    }

    /// Entries covering this node, innermost first.
    func protections(of id: NodeID) -> [ProtectionRow] {
        guard let key = protectionKey(of: id) else { return [] }
        return protection.covering(key)
    }

    func protectionKinds(of id: NodeID) -> [ProtectionKind] {
        guard let key = protectionKey(of: id) else { return [] }
        return protection.kinds(key)
    }

    func protectionKinds(forTreePath path: String) -> [ProtectionKind] {
        protection.rows.isEmpty ? [] : protection.kinds(protectionKey(forTreePath: path))
    }

    /// Why protection keeps this item out of the Trash, or nil. Part of `trashBlockReason`.
    func protectionTrashReason(_ id: NodeID) -> String? {
        guard let tree, let key = protectionKey(of: id) else { return nil }
        let name = self.name(of: id)
        guard protection.loaded else { return String(localized: "正在確認「\(name)」有沒有受保護⋯") }
        if protection.readError != nil {
            return String(localized: "讀不到保護清單，Hoard 無法確認「\(name)」有沒有受保護，暫時不會把它丟到垃圾桶。")
        }
        let kinds = protection.kinds(key)
        if !kinds.isEmpty { return Self.protectedTrashText(name, kinds) }
        if tree[id].isDirectory, !protection.inside(key).isEmpty {
            return String(localized: "「\(name)」裡面有受保護的項目，不能丟到垃圾桶。要先在「受保護」裡解除保護。")
        }
        return nil
    }

    static func protectedTrashText(_ name: String, _ kinds: [ProtectionKind]) -> String {
        String(localized: "「\(name)」受保護（\(kinds.map(\.title).joined(separator: "／"))），不能丟到垃圾桶。要先在「受保護」裡解除保護。")
    }

    /// The same check against a registry read just now, for the moment of moving to the Trash.
    nonisolated static func trashConflict(key: String, isDirectory: Bool, in items: [ProtectedItem]) -> [ProtectionKind]? {
        let keyed = items.map { (protectionKey($0.path), $0) }
        let covering = keyed.filter { $0.0 == key || ($0.1.isDirectory && key.hasPrefix($0.0 + "/")) }.map(\.1.kind)
        if !covering.isEmpty { return [ProtectionKind.lock, .guarded].filter { covering.contains($0) } }
        let prefix = key == "/" ? "/" : key + "/"
        let inside = keyed.filter { $0.0 != key && $0.0.hasPrefix(prefix) }
        return isDirectory && !inside.isEmpty ? [] : nil
    }

    // MARK: Adding protection

    func requestProtect(_ id: NodeID, kind: ProtectionKind) {
        guard let tree, isLive(id) else { return }
        let path = tree.path(of: id)
        protectRequest = ProtectRequest(path: path, name: name(of: id), kind: kind, isDirectory: tree[id].isDirectory)
    }

    /// Adds protection on the protection queue. Returns the refusal in plain Chinese, or nil on success.
    func addProtection(_ request: ProtectRequest, note: String) async -> String? {
        protectionAddsRunning += 1
        defer { protectionAddsRunning -= 1 }
        let store = StoreRef(store: protectionStore)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // The firmlinked form, so an entry added while scanning the whole disk ("/System/Volumes/Data/Users/…")
        // compares equal to one the CLI added through "~/…".
        let path = Self.systemPath(request.path)
        let result: Result<ProtectedItem, Error> = await withCheckedContinuation { continuation in
            protectionQueue.async {
                continuation.resume(returning: Result {
                    request.kind == .lock
                        ? try store.store.lock(path, by: "app", note: trimmed.isEmpty ? nil : trimmed)
                        : try store.store.guardItem(path, by: "app", note: trimmed.isEmpty ? nil : trimmed)
                })
            }
        }
        refreshProtection()
        switch result {
        case .success:
            Self.announce(String(localized: "已\(request.kind.title)「\(request.name)」"))
            return nil
        case .failure(let error):
            return Self.protectionReason(error)
        }
    }

    /// The engine's refusal to guard `request`, asked before the user confirms; nil when it can go ahead.
    func guardRefusal(_ request: ProtectRequest) async -> String? {
        let store = StoreRef(store: protectionStore)
        let path = Self.systemPath(request.path)
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            protectionQueue.async {
                continuation.resume(returning: Result { try store.store.checkGuardable(path) })
            }
        }
        if case .failure(let error) = result { return Self.protectionReason(error) }
        return nil
    }

    // MARK: Actions that only add protection back

    /// 重新鎖定: re-applies stripped ACLs.
    func repairProtection(_ row: ProtectionRow) {
        runProtection(failure: String(localized: "無法重新鎖定「\(row.name)」")) { store in try store.repair(row.item.id) }
    }

    /// 重新備份: takes a new vault copy.
    func refreshVault(_ row: ProtectionRow) {
        runProtection(failure: String(localized: "無法重新備份「\(row.name)」")) { store in try store.refresh(row.item.path) }
    }

    /// 放回: restores every deleted guarded item that has a vault copy.
    func restoreProtected(_ row: ProtectionRow) {
        runProtection(failure: String(localized: "無法放回「\(row.name)」")) { store in
            try store.restoreMissing().map { GuardianAction.restored($0) }
        }
    }

    /// Runs one store call on the protection queue, then re-reads the registry. Restores it reports
    /// go to 最近動作 like the guardian's.
    func runProtection(failure title: String, _ work: @escaping (ProtectionStore) throws -> Void) {
        runProtection(failure: title) { store -> [GuardianAction] in try work(store); return [] }
    }

    func runProtection(failure title: String, _ work: @escaping (ProtectionStore) throws -> [GuardianAction]) {
        let store = StoreRef(store: protectionStore)
        protectionQueue.async { [weak self] in
            let result = Result { try work(store.store) }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let actions): actions.forEach { self.logGuardian($0) }
                case .failure(let error): self.alert = AppAlert(title: title, message: Self.protectionReason(error))
                }
                self.refreshProtection()
            }
        }
    }

    // MARK: Guardian

    func startGuardian() {
        guard guardian == nil else { return }
        // A render without a test store must not run a guardian against the real registry.
        let args = CommandLine.arguments
        if args.contains("--render-to") && !args.contains("--protection-store") { return }
        let guardian = ProtectionGuardian(store: protectionStore) { [weak self] action in
            Task { @MainActor in self?.guardianDid(action) }
        }
        self.guardian = guardian
        let ref = GuardianRef(guardian: guardian)
        protectionQueue.async { [weak self] in
            do { try ref.guardian.start() }
            catch {
                let reason = error.localizedDescription
                Task { @MainActor in
                    guard let self else { return }
                    if self.guardian === ref.guardian { self.guardian = nil }
                    self.logGuardian(.failed("guardian", reason))
                }
            }
        }
    }

    func stopGuardian() -> (@Sendable () -> Void)? {
        let ref = guardian.map(GuardianRef.init)
        guardian = nil
        let queue = protectionQueue
        return ref.map { ref -> @Sendable () -> Void in
            { queue.sync { ref.guardian.stop() } }
        }
    }

    private func guardianDid(_ action: GuardianAction) {
        logGuardian(action)
        if case .restored(let path) = action {
            let name = (path as NSString).lastPathComponent
            var names = restoredBanner?.names ?? []
            names.append(name)
            let notice = RestoredNotice(names: names)
            restoredBanner = notice
            Self.announce(notice.text)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if self?.restoredBanner?.id == notice.id { self?.restoredBanner = nil }
            }
        }
        refreshProtection()
    }

    func logGuardian(_ action: GuardianAction) {
        guardianLog.insert(GuardianEntry(action: action, at: Date()), at: 0)
        if guardianLog.count > 20 { guardianLog.removeLast(guardianLog.count - 20) }
    }

    // MARK: Wording

    /// `app` → 你, `cli` → 終端機, `mcp:<client>` → the client's name.
    static func protectorName(_ createdBy: String) -> String {
        switch createdBy {
        case "app": return String(localized: "你")
        case "cli": return String(localized: "終端機")
        default:
            guard createdBy.hasPrefix("mcp:") else { return createdBy }
            let client = String(createdBy.dropFirst(4))
            let known = ["claude-code": "Claude Code", "claude-ai": "Claude", "codex-mcp-client": "Codex",
                         "codex": "Codex", "cursor-vscode": "Cursor", "unknown": String(localized: "AI 工具")]
            return known[client.lowercased()] ?? client
        }
    }

    /// The engine's refusals and failures in plain Chinese; anything unrecognised keeps its original text.
    static func protectionReason(_ error: Error) -> String {
        guard let engine = error as? ProtectionError else { return reason(error) }
        return protectionMessage(engine.localizedDescription)
    }

    /// The engine reports in English (shared with the CLI and MCP); this is the app's wording.
    static func protectionMessage(_ message: String) -> String {
        func number() -> String {
            message.range(of: "[0-9][0-9,]*", options: .regularExpression).map { String(message[$0]) } ?? ""
        }
        let table: [(String, () -> String)] = [
            ("Path does not exist", { String(localized: "這個項目已經不在了。") }),
            ("System or volume root cannot be protected", { String(localized: "系統資料夾和磁碟的根目錄不能保護。") }),
            ("Top-level system directory cannot be protected", { String(localized: "磁碟最上層的系統資料夾不能保護。") }),
            ("Home directory and its ancestors cannot be protected", { String(localized: "家目錄本身和它上層的資料夾不能保護。請改選家目錄裡的檔案或資料夾。") }),
            ("Launch and login items cannot be protected", { String(localized: "開機或登入時自動執行的項目不能保護，否則你會無法移除它們。") }),
            ("Lock cannot cover ~/Library", { String(localized: "「資源庫」（~/Library）本身不能保護，裡面的項目也不能鎖定，因為 App 需要能取代自己的檔案。裡面的項目可以改用守護。") }),
            ("Protection store and its ancestors cannot be protected", { String(localized: "Hoard 存放保護資料的資料夾和它上層的資料夾不能保護。") }),
            ("Volume root cannot be protected", { String(localized: "磁碟或卷宗的根目錄不能保護。") }),
            ("Only regular files and directories can be protected", { String(localized: "只能保護一般的檔案和資料夾，不能保護替身、捷徑或裝置檔。") }),
            ("Guard folder exceeds", { String(localized: "這個資料夾太大了：守護最多涵蓋 \(number()) 個項目。請改守護裡面較小的資料夾，或改用鎖定。") }),
            ("Lock folder exceeds", { String(localized: "這個資料夾太大了：鎖定最多涵蓋 \(number()) 個資料夾。請改鎖定裡面較小的資料夾。") }),
            ("Cannot inspect folder entry", { String(localized: "資料夾裡有讀不到的項目，Hoard 無法確認它有多大。") }),
            ("Cannot stat", { String(localized: "讀不到這個項目的資訊。") }),
            ("Path is already covered by lock", { String(localized: "它已經在鎖定的範圍內了。") }),
            ("Path is already covered by guarded", { String(localized: "它已經在守護的範圍內了。") }),
            ("Guarded path must be on the vault's volume", { String(localized: "只能守護和 Hoard 保險庫在同一顆磁碟上的項目；外接硬碟或其他卷宗上的不行。") }),
            ("Matching ACL already exists", { String(localized: "這個項目已經有一樣的存取限制，不是 Hoard 設的，Hoard 不會接手。") }),
            ("clonefile failed", { String(localized: "無法替它建立備份複本。") }),
            ("Guard vault copy missing", { String(localized: "保險庫裡沒有可用的備份，無法從備份更新。") }),
            ("Protected item is missing", { String(localized: "這個項目已經不在了，無法重新鎖定。") }),
            ("Unknown protection id", { String(localized: "保護清單裡已經沒有這個項目了。") }),
            ("Human removal reason is required", { String(localized: "解除保護需要填寫原因。") }),
            ("Cannot open protection registry lock", { String(localized: "無法開啟保護清單。") }),
            ("Cannot lock protection registry", { String(localized: "保護清單正在被別的程式使用，請稍後再試。") }),
            ("Restore partially failed", { String(localized: "有些項目沒能放回：\(message)") }),
            ("Protection registry cannot be read", { String(localized: "讀不到保護清單：\(protectionReadReason(message))") }),
            ("ACL path is missing or is a symlink", { String(localized: "項目不見了，或被換成了替身，Hoard 沒有動它。") }),
            ("Hoard ACL entry not found", { String(localized: "找不到 Hoard 設的存取限制。") }),
            ("Missing entry in guarded tree", { String(localized: "備份期間有檔案不見了，請再試一次。") }),
            ("Source disappeared", { String(localized: "備份期間有檔案不見了，請再試一次。") }),
            ("Cannot create the FSEvents stream", { String(localized: "無法開始監看受守護的項目。") }),
            ("Cannot start the FSEvents stream", { String(localized: "無法開始監看受守護的項目。") }),
        ]
        if let match = table.first(where: { message.hasPrefix($0.0) }) { return match.1() }
        // These two start with the path they are about, so they are matched by their fixed ending.
        let datalessTail = " has no data on this Mac (iCloud); Hoard does not download it, so it cannot be guarded"
        if message.hasSuffix(datalessTail) {
            let name = (String(message.dropLast(datalessTail.count)) as NSString).lastPathComponent
            return String(localized: "「\(name)」只在 iCloud，這台 Mac 上沒有它的資料。Hoard 不會下載檔案，所以無法守護它（資料夾裡有這樣的檔案時也一樣）。")
        }
        let ceilingTail = " bytes: guard is for working files; lock large finished files instead"
        if message.hasSuffix(ceilingTail) {
            let head = message.dropLast(ceilingTail.count)
            if let over = head.range(of: " is over ", options: .backwards),
               let ceiling = Int64(head[over.upperBound...].replacingOccurrences(of: ",", with: "")) {
                return String(localized: "這個項目超過 \(Fmt.bytes(ceiling))。守護是給正在編輯的檔案用的；大型的完成品請改用鎖定。")
            }
        }
        // System call failures ("<call> failed for <path>: <errno text>") and anything newer than this table.
        return String(localized: "Hoard 無法完成這個動作（\(message)）。")
    }

    /// The registry error without the engine's English lead-in.
    static func protectionReadReason(_ error: String) -> String {
        let lead = "Protection registry cannot be read: "
        return error.hasPrefix(lead) ? String(error.dropFirst(lead.count)) : error
    }

    static func healthText(_ health: ProtectionHealth) -> String {
        switch health {
        case .intact: return String(localized: "完好")
        case .aclMissing: return String(localized: "鎖被移除了")
        case .vaultMissing: return String(localized: "備份不見了")
        case .itemMissing(let restorable): return restorable ? String(localized: "已被刪除・可以放回") : String(localized: "已被刪除")
        }
    }
}
