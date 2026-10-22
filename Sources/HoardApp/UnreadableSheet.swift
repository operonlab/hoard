import Darwin
import SwiftUI
import ScanCore

struct UnreadableExplanation: View {
    @ObservedObject var model: AppModel
    let diagnosis: UnreadableDiagnosis

    static func message(_ diagnosis: UnreadableDiagnosis) -> String {
        switch diagnosis.reason {
        case .needsFullDiskAccess: return String(localized: "macOS 需要你同意，Hoard 才能讀這個資料夾。")
        case .systemProtected: return String(localized: "這是 macOS 保護的資料夾，任何 App 都讀不到；它占的空間算在「看不到的空間」裡。")
        case .permission: return String(localized: "沒有權限讀取這個資料夾。")
        case .filePermissions:
            guard let owner = diagnosis.owner else { return String(localized: "這個資料夾的檔案權限不讓你讀。") }
            if owner == NSUserName() {
                return String(localized: "這個資料夾是你的，但它的權限設定連你也不能讀。可以在 Finder 的「取得資訊」›「共享與權限」查看。")
            }
            return String(localized: "這個資料夾的檔案權限不讓你讀；擁有者是「\(owner)」。")
        case .notDownloaded: return String(localized: "這個資料夾只在 iCloud，沒有下載到這台 Mac。Hoard 不會為了量大小而下載它。")
        case .gone: return String(localized: "這個資料夾已經不在了。")
        case .readableNow: return String(localized: "現在讀得到了，重新掃描就能補上。")
        case .error: return String(localized: "讀取時發生錯誤：\(String(cString: strerror(diagnosis.errno ?? EIO)))")
        case .unknown: return String(localized: "無法確認原因。")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Self.message(diagnosis))
            switch diagnosis.reason {
            case .needsFullDiskAccess: Button("授權方式…") { model.accessSheet = .info }
            case .readableNow: Button("重新掃描") { model.rescan() }
            default: EmptyView()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct UnreadableSheet: View {
    @ObservedObject var model: AppModel
    let node: NodeID
    @State private var results: [(path: String, diagnosis: UnreadableDiagnosis)]?
    @State private var total = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("讀不到的資料夾").font(.title2.bold())
            if let results {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Self.groups(results), id: \.key) { group in
                            let rows = group.rows
                            if !rows.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("\(group.reason.title)（\(rows.count)）").font(.headline)
                                    UnreadableExplanation(model: model, diagnosis: rows[0].diagnosis)
                                    ForEach(rows, id: \.path) { row in
                                        Text(Fmt.tildePath(row.path))
                                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            } else { ProgressView() }
            HStack {
                if let results, total > results.count {
                    Text("還有 \(total - results.count) 個沒有列出。").foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { model.unreadableSheetNode = nil }
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 360, idealHeight: 540)
        .task(id: node) {
            guard let tree = model.tree else { results = []; return }
            let list = Unreadable.folders(in: tree, under: node, limit: 300)
            total = list.total
            let access = model.fullDiskAccess
            results = await Task.detached(priority: .userInitiated) {
                list.paths.map { (path: $0, diagnosis: Unreadable.diagnose($0, fullDiskAccess: access)) }
            }.value
        }
    }

    /// One group per reason, split further by owner and by errno, because the explanation names them.
    private static func groups(_ results: [(path: String, diagnosis: UnreadableDiagnosis)])
        -> [(key: String, reason: UnreadableDiagnosis.Reason, rows: [(path: String, diagnosis: UnreadableDiagnosis)])] {
        UnreadableDiagnosis.Reason.allCases.flatMap { reason in
            let rows = results.filter { $0.diagnosis.reason == reason }
            var order: [String] = []
            var byKey: [String: [(path: String, diagnosis: UnreadableDiagnosis)]] = [:]
            for row in rows {
                let detail = reason == .filePermissions ? row.diagnosis.owner ?? ""
                    : reason == .error ? row.diagnosis.errno.map(String.init) ?? "" : ""
                let key = "\(reason.rawValue)/\(detail)"
                if byKey[key] == nil { order.append(key) }
                byKey[key, default: []].append(row)
            }
            return order.map { (key: $0, reason: reason, rows: byKey[$0]!) }
        }
    }
}

private extension UnreadableDiagnosis.Reason {
    static var allCases: [Self] {
        [.needsFullDiskAccess, .systemProtected, .permission, .filePermissions, .notDownloaded,
         .gone, .readableNow, .error, .unknown]
    }
    var title: String {
        switch self {
        case .needsFullDiskAccess: return String(localized: "需要完整磁碟取用權限")
        case .systemProtected: return String(localized: "macOS 保護")
        case .permission: return String(localized: "權限不足")
        case .filePermissions: return String(localized: "檔案權限不允許")
        case .notDownloaded: return String(localized: "只在 iCloud")
        case .gone: return String(localized: "資料夾已不存在")
        case .readableNow: return String(localized: "現在可以讀取")
        case .error: return String(localized: "讀取錯誤")
        case .unknown: return String(localized: "原因不明")
        }
    }
}
