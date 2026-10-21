import AppKit
import SwiftUI
import ScanCore

/// The sheet before 鎖定 / 守護: what it means, an optional note, and the engine's refusal if any.
struct ProtectSheet: View {
    @ObservedObject var model: AppModel
    let request: ProtectRequest
    @State private var note = ""
    @State private var refusal: String?
    @State private var busy = false
    /// 守護 is asked first whether the engine would refuse (a file only in iCloud, the size ceilings).
    @State private var checking: Bool
    @State private var refusedBeforeConfirm = false

    init(model: AppModel, request: ProtectRequest) {
        self.model = model
        self.request = request
        _checking = State(initialValue: request.kind == .guarded)
    }

    var body: some View {
        let kind = request.kind
        VStack(alignment: .leading, spacing: 14) {
            Text("\(kind.title)「\(request.name)」")
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Image(nsImage: FileIcons.icon(forPath: request.path, isDirectory: request.isDirectory)).resizable().frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(Fmt.tildePath(request.path)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 8) {
                if kind == .lock {
                    Text("不能刪除、搬移或取代；可以直接修改內容。適合已完成的成品：模型、資料集、照片、封存檔。")
                        .fixedSize(horizontal: false, vertical: true)
                    Label("注意：用「另存新檔再取代」方式存檔的程式（多數編輯器、AI 程式工具）會無法修改它。",
                          systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("可以自由修改；被刪除時 Hoard 會自動放回最新版本，最多保留 3 個版本，不額外佔空間直到內容改變。適合正在編輯的檔案。Hoard 需要在執行中（或開啟下方的背景守護）。")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Image(systemName: "moon.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text("App 關閉時也守護：\(BackgroundGuardian.statusText(BackgroundGuardian.service.status))")
                            .foregroundStyle(.secondary)
                        SettingsLink { Text("打開設定…") }
                            .controlSize(.small)
                    }
                }
                if request.isDirectory {
                    Text("資料夾裡的所有檔案和子資料夾都會一起受到保護。").foregroundStyle(.secondary)
                }
            }
            TextField("備註（選填）", text: $note)
                .textFieldStyle(.roundedBorder)
                .disabled(busy)
            if let refusal {
                Label(refusal, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("無法\(kind.title)：\(refusal)")
            }
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("正在\(kind.title)⋯").foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { model.protectRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button(kind.title) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || checking || refusedBeforeConfirm)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task(id: request.id) {
            guard request.kind == .guarded else { return }
            let failure = await model.guardRefusal(request)
            guard !Task.isCancelled else { return }
            if let failure {
                refusal = failure
                refusedBeforeConfirm = true
            }
            checking = false
        }
    }

    private func confirm() {
        busy = true
        refusal = nil
        Task {
            let failure = await model.addProtection(request, note: note)
            busy = false
            if let failure {
                refusal = failure
                AppModel.announce(String(localized: "無法\(request.kind.title)：\(failure)"))
            } else if model.protectRequest?.id == request.id {
                model.protectRequest = nil
            }
        }
    }
}

extension AppModel {
    static let defaultUnprotectReason = "使用者在 Hoard 確認解除"

    /// 解除保護…: a destructive-style alert whose confirm button is the only place the app removes
    /// protection. 取消 is the default button, so Return (also from the reason field) cancels.
    func confirmUnprotect(_ row: ProtectionRow) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "解除「\(row.name)」的保護？")
        // The engine keeps the vault's version count private, so this sentence carries no number.
        alert.informativeText = row.item.kind == .guarded
            ? String(localized: "解除後，任何程式——包括 AI agent——都可以刪除或取代它。保險庫裡的備份版本也會一併刪除。")
            : String(localized: "解除後，任何程式——包括 AI agent——都可以刪除或取代它。")
        // Fixed frames: the alert sizes its accessory from the view's frame, and a stack view shrank the field.
        let width: CGFloat = 230
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        field.placeholderString = String(localized: "使用者在 Hoard 確認解除")
        field.setAccessibilityLabel(String(localized: "原因（選填）"))
        let caption = NSTextField(labelWithString: String(localized: "原因（選填）"))
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: 0, y: 26, width: width, height: 16)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 42))
        accessory.addSubview(caption)
        accessory.addSubview(field)
        alert.accessoryView = accessory
        alert.addButton(withTitle: String(localized: "取消"))
        let remove = alert.addButton(withTitle: String(localized: "解除保護"))
        remove.hasDestructiveAction = true
        remove.keyEquivalent = ""
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let removal = ProtectionRemoval.confirmedByHuman(reason: typed.isEmpty ? Self.defaultUnprotectReason : typed)
            self.runProtection(failure: String(localized: "無法解除「\(row.name)」的保護")) { store in try store.remove(row.item.id, removal) }
        }
        let main = NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.attachedSheet == nil && $0.contentView != nil
            && $0.identifier?.rawValue.contains("Settings") != true }
        if let window = NSApp.keyWindow.flatMap({ $0.isSheet || $0.attachedSheet != nil ? nil : $0 }) ?? main {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}

/// The kind glyphs shown after a protected (or covered) item's name.
struct ProtectionGlyphs: View {
    let kinds: [ProtectionKind]

    var body: some View {
        if !kinds.isEmpty {
            HStack(spacing: 2) {
                ForEach(kinds, id: \.self) { kind in Image(systemName: kind.symbol).imageScale(.small) }
            }
            .foregroundStyle(.secondary)
            .help("受保護（\(kinds.map(\.title).joined(separator: "／"))）")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("受保護，\(kinds.map(\.title).joined(separator: "、"))")
        }
    }
}

/// 鎖定… / 守護… for a context menu, or 已鎖定 / 已守護 (disabled) when that kind already covers it.
struct ProtectMenuItems: View {
    @ObservedObject var model: AppModel
    let ids: [NodeID]

    var body: some View {
        let one = ids.count == 1 ? ids[0] : nil
        let kinds = one.map { model.protectionKinds(of: $0) } ?? []
        ForEach([ProtectionKind.lock, .guarded], id: \.self) { kind in
            if kinds.contains(kind) {
                Button(kind == .lock ? String(localized: "已鎖定") : String(localized: "已守護")) {}.disabled(true)
            } else {
                Button("\(kind.title)…") { if let one { model.requestProtect(one, kind: kind) } }
                    .disabled(one == nil || !model.protection.loaded)
            }
        }
    }
}
