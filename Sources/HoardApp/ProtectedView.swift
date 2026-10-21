import SwiftUI
import ScanCore

/// 受保護 (⌘6): every locked or guarded item with its health, and the guardian's recent actions.
struct ProtectedView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let snapshot = model.protection
        VStack(spacing: 0) {
            ViewHeader(title: String(localized: "受保護"), sentence: sentence(snapshot), busy: !snapshot.loaded) { EmptyView() }
            if let error = snapshot.readError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    Text("讀不到保護清單：\(AppModel.protectionReadReason(error))。清單可能不完整。")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
            Divider()
            if !snapshot.loaded {
                Spacer()
            } else if snapshot.rows.isEmpty && snapshot.readError == nil && model.guardianLog.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        if snapshot.rows.isEmpty {
                            Text(snapshot.readError == nil ? String(localized: "目前沒有受保護的項目。") : String(localized: "目前讀不到任何項目。"))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.rows) { row in ProtectedRowView(model: model, row: row) }
                    } header: {
                        Text("受保護的項目")
                    }
                    Section {
                        if model.guardianLog.isEmpty {
                            Text("Hoard 執行期間放回檔案、更新備份或遇到問題時，會列在這裡。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.guardianLog) { entry in GuardianEntryRow(model: model, entry: entry) }
                    } header: {
                        Text("最近動作")
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("還沒有受保護的項目", systemImage: "lock.shield")
        } description: {
            Text("鎖定的項目不能刪除、搬移或取代，但可以直接修改內容。守護的項目可以自由修改，被刪除時 Hoard 會自動放回最新版本。\n\n在任何檔案或資料夾上按右鍵，選「鎖定…」或「守護…」。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sentence(_ snapshot: ProtectionSnapshot) -> String {
        guard snapshot.loaded else { return String(localized: "正在讀取保護清單⋯") }
        if snapshot.readError != nil { return String(localized: "保護清單讀取失敗，下面列的是最後一次讀到的內容。") }
        let rows = snapshot.rows
        guard !rows.isEmpty else { return String(localized: "防止檔案被誤刪：在 AI 程式工具或其他程式刪掉它之前先擋下，或刪掉後自動放回。") }
        let locks = rows.filter { $0.item.kind == .lock }.count
        let guards = rows.count - locks
        let parts = [locks > 0 ? String(localized: "\(locks) 個鎖定") : nil, guards > 0 ? String(localized: "\(guards) 個守護") : nil].compactMap { $0 }
        var text = String(localized: "\(rows.count) 個項目受到保護：\(parts.joined(separator: "、"))。")
        if snapshot.problemCount > 0 { text += String(localized: "其中 \(snapshot.problemCount) 個需要處理。") }
        return text
    }
}

struct ProtectedRowView: View {
    @ObservedObject var model: AppModel
    let row: ProtectionRow

    var body: some View {
        let item = row.item
        let who = AppModel.protectorName(item.createdBy)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.kind.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .help(item.kind.explanation)
                .accessibilityLabel(item.kind.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(Fmt.tildePath(item.path)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(item.note.map { String(localized: "\(item.path)\n備註：\($0)") } ?? item.path)
                if row.health == .aclMissing {
                    Text(item.kind == .lock ? String(localized: "有人在 Hoard 以外拿掉了鎖，現在可以被刪除。")
                         : String(localized: "有人在 Hoard 以外拿掉了保險庫的鎖，備份現在可以被刪除。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            Text("\(who)・\(AppModel.agoText(item.createdAt, now: model.clock))")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("由\(who)在 \(Fmt.dayAndTime(item.createdAt)) 加入")
                .frame(width: 140, alignment: .trailing)
            HealthLabel(health: row.health)
                .frame(width: 150, alignment: .leading)
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
            .frame(width: 170, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name)，\(item.kind.title)，\(AppModel.healthText(row.health))")
    }
}

/// 「已放回「X」」 after the guardian puts a deleted item back; it goes away on its own.
struct RestoredBanner: View {
    @ObservedObject var model: AppModel
    let notice: RestoredNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            Text(notice.text).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("查看") { model.view = .protected; model.restoredBanner = nil }
            Button { model.restoredBanner = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("關閉")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct HealthLabel: View {
    let health: ProtectionHealth

    var body: some View {
        let (symbol, color): (String, Color) = {
            switch health {
            case .intact: return ("checkmark.circle.fill", .green)
            case .itemMissing(restorable: false): return ("xmark.octagon.fill", .red)
            default: return ("exclamationmark.triangle.fill", .orange)
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(AppModel.healthText(health)).lineLimit(1)
                .foregroundStyle(health == .intact ? .secondary : .primary)
        }
    }
}

struct GuardianEntryRow: View {
    @ObservedObject var model: AppModel
    let entry: GuardianEntry

    var body: some View {
        let (symbol, color, text, path) = describe(entry.action)
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 20).accessibilityHidden(true)
            Text(text).lineLimit(2).truncationMode(.middle).help(path)
            Spacer(minLength: 8)
            Text(AppModel.agoText(entry.at, now: model.clock))
                .foregroundStyle(.secondary)
                .help(Fmt.dayAndTime(entry.at))
        }
    }

    private func describe(_ action: GuardianAction) -> (String, Color, String, String) {
        func name(_ path: String) -> String {
            path == "registry" ? String(localized: "保護清單") : path == "guardian" ? String(localized: "守護功能") : (path as NSString).lastPathComponent
        }
        switch action {
        case .restored(let path): return ("arrow.uturn.backward.circle.fill", .green, String(localized: "已放回「\(name(path))」"), path)
        case .refreshed(let path): return ("arrow.triangle.2.circlepath", .secondary, String(localized: "已更新「\(name(path))」的備份"), path)
        case .failed(let path, let message):
            return ("exclamationmark.triangle.fill", .orange, String(localized: "「\(name(path))」：\(AppModel.protectionMessage(message))"), path)
        }
    }
}
