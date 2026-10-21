import AppKit
import SwiftUI
import ScanCore

struct CleanupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ViewHeader(title: String(localized: "可以清掉的"), sentence: summary, busy: model.cleanupPending) {
                    Button("全部丟到垃圾桶…") {
                        let rows = liveSuggestions
                        model.requestBatchTrash(rows.map(\.node), source: "suggest", reviewCount: reviewCount(rows))
                    }
                    .disabled(liveSuggestions.isEmpty)
                    .help("把所有清理建議一起丟到垃圾桶；會先列出項目讓你確認。")
                }
                hiddenCard
                if let error = model.cleanupError {
                    Label("無法產生清理建議：\(error)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let report = model.cleanupReport {
                    if report.scopeStatus == .unavailable {
                        Text("這個位置無法讀取，因此無法判斷哪些項目可以清理。")
                            .foregroundStyle(.secondary)
                    } else if report.suggestions.isEmpty {
                        Text(report.scopeStatus == .partial
                             ? String(localized: "目前讀到的部分沒有符合條件的清理建議；無法讀取的位置尚未判斷。")
                             : String(localized: "目前沒有符合條件的清理建議。"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(CleanupSection.allCases, id: \.self) { section in
                        let rows = report.suggestions.filter { section.categories.contains($0.category) }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(section.title).font(.headline)
                                    Spacer()
                                    let selectable = rows.filter { selectableSuggestion($0) }
                                    let allPicked = !selectable.isEmpty && selectable.allSatisfy { model.suggestionPicks[$0.node] == $0.path }
                                    Button(allPicked ? "取消全選" : "全選這一類") {
                                        for row in selectable {
                                            if allPicked { model.suggestionPicks.removeValue(forKey: row.node) }
                                            else { model.suggestionPicks[row.node] = row.path }
                                        }
                                    }
                                    .disabled(selectable.isEmpty)
                                }
                                ForEach(rows, id: \.node) { row in
                                    SuggestionRow(model: model, suggestion: row)
                                }
                            }
                        }
                    }
                    if report.omitted > 0 {
                        Text("另有 \(report.omitted) 個項目未列出。")
                            .foregroundStyle(.secondary)
                    }
                }
                duplicatesSection
                SimilarImagesView(model: model)
                recentSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            if !model.validPicks(model.suggestionPicks).isEmpty ||
                !model.validPicks(model.duplicatePicks).isEmpty ||
                !model.validPicks(model.similarPicks).isEmpty {
                selectionBar
            }
        }
        // The similar-photo results live in their view and are gone after leaving the page; picks must go too.
        .onAppear { model.similarPicks = [:] }
        .onChange(of: model.generation) { _, _ in clearPicks() }
        .onChange(of: model.scope) { _, _ in clearPicks() }
        .onChange(of: model.tree.map(ObjectIdentifier.init)) { _, _ in clearPicks() }
        .onChange(of: model.cleanupReport) { _, report in
            let paths = Dictionary(uniqueKeysWithValues: (report?.suggestions ?? []).map { ($0.node, $0.path) })
            model.suggestionPicks = model.suggestionPicks.filter { paths[$0.key] == $0.value }
        }
    }

    private var liveSuggestions: [Suggestion] {
        model.cleanupReport?.suggestions.filter { model.isLive($0.node) && model.tree?.path(of: $0.node) == $0.path } ?? []
    }

    private func selectableSuggestion(_ row: Suggestion) -> Bool {
        model.isLive(row.node) && model.tree?.path(of: row.node) == row.path && model.trashBlockReason(row.node) == nil
    }

    private func reviewCount(_ rows: [Suggestion]) -> Int {
        rows.filter { $0.safety == .review && model.trashBlockReason($0.node) == nil }.count
    }

    private func clearPicks() {
        model.suggestionPicks = [:]
        model.duplicatePicks = [:]
        model.similarPicks = [:]
    }

    private var selectionBar: some View {
        let suggestions = model.validPicks(model.suggestionPicks)
        let duplicates = model.validPicks(model.duplicatePicks)
        let similar = model.validPicks(model.similarPicks)
        return VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty {
                HStack {
                    Text("清理建議：已選 \(suggestions.count) 項，共 \(pickedSize(suggestions))")
                    Spacer()
                    Button("取消選取") { model.suggestionPicks = [:] }
                    Button("丟到垃圾桶…") {
                        let rows = liveSuggestions.filter { suggestions.contains($0.node) }
                        model.requestBatchTrash(suggestions, source: "suggest", reviewCount: reviewCount(rows))
                    }
                }
            }
            if !duplicates.isEmpty {
                HStack {
                    Text("重複的檔案：已選 \(duplicates.count) 份，共 \(pickedSize(duplicates))")
                    Spacer()
                    Button("取消選取") { model.duplicatePicks = [:] }
                    Button("丟到垃圾桶…") { model.requestDuplicateBatch(model.duplicateReport?.groups ?? [], picked: Set(duplicates)) }
                }
            }
            if !similar.isEmpty {
                HStack {
                    Text("相似的照片：已選 \(similar.count) 張，共 \(pickedSize(similar))")
                    Spacer()
                    Button("取消選取") { model.similarPicks = [:] }
                    Button("丟到垃圾桶…") { model.requestBatchTrash(similar, source: "similar") }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func pickedSize(_ ids: [NodeID]) -> String {
        guard let tree = model.tree else { return String(localized: "無法得知") }
        let bytes = ids.reduce(Int64(0)) { $0 + tree[$1].totalAlloc }
        return ids.contains { tree[$0].status != .complete } ? String(localized: "至少 \(Fmt.bytes(bytes))") : Fmt.bytes(bytes)
    }

    private var summary: String {
        guard let report = model.cleanupReport else { return model.cleanupPending ? String(localized: "正在尋找可考慮清理的項目⋯") : "" }
        guard report.scopeStatus != .unavailable else { return String(localized: "無法讀取目前位置。") }
        if report.totalBytes == 0, report.totalStatus != .complete {
            return String(localized: "目前讀到的部分沒有清理建議；未讀到的位置仍無法判斷。")
        }
        // Both safe kinds count here: a .venv or node_modules is 可重新下載, and leaving it out read as if
        // only build caches were safe to remove.
        let recoverable = report.suggestions.filter { $0.safety == .regenerable || $0.safety == .redownloadable }
        let rebuildBytes = recoverable.reduce(Int64(0)) { $0 + $1.bytes }
        let total = Fmt.bytes(report.totalBytes), rebuild = Fmt.bytes(rebuildBytes)
        let rebuildPartial = recoverable.contains { $0.status != .complete }
        if report.totalStatus != .complete {
            return rebuildPartial
                ? String(localized: "\(model.scopeName) 裡有至少 \(total) 可以考慮清理，其中至少 \(rebuild) 刪了之後可以重新產生或重新下載。")
                : String(localized: "\(model.scopeName) 裡有至少 \(total) 可以考慮清理，其中 \(rebuild) 刪了之後可以重新產生或重新下載。")
        }
        return rebuildPartial
            ? String(localized: "\(model.scopeName) 裡有 \(total) 可以考慮清理，其中至少 \(rebuild) 刪了之後可以重新產生或重新下載。")
            : String(localized: "\(model.scopeName) 裡有 \(total) 可以考慮清理，其中 \(rebuild) 刪了之後可以重新產生或重新下載。")
    }

    private var hiddenCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("看不到的空間", systemImage: "internaldrive")
                    .font(.headline)
                if model.hiddenPending { ProgressView().controlSize(.small) }
            }
            if let report = model.hiddenReport {
                Text(hiddenSummary(report)).foregroundStyle(.secondary)
                ForEach(report.lines, id: \.id) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.title)
                            if let count = line.count, count > 0 {
                                Text("（\(count) 個）").foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(line.sizeText).monospacedDigit()
                        }
                        if line.state == .unknown {
                            Text(line.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(line.explanation)
                }
            } else {
                Text("正在核對磁碟容量與掃描範圍⋯").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func hiddenSummary(_ report: HiddenSpace.Report) -> String {
        let used = report.lines.first { $0.id == "used" }
        let scanned = report.lines.first { $0.id == "scanned" }
        if !report.coversVolume {
            return String(localized: "目前只掃到所選位置，無法用它算出整個磁碟其餘的用量。")
        }
        return String(localized: "磁碟已用 \(used?.sizeText ?? String(localized: "無法得知"))，掃到的檔案佔 \(scanned?.sizeText ?? String(localized: "無法得知"))，其餘在下面。")
    }

    private var duplicatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("重複的檔案").font(.headline)
            Text("只在按下按鈕後讀取檔案內容並逐位元組比對；不會自動刪除。")
                .foregroundStyle(.secondary)
            HStack {
                Picker("最小檔案", selection: $model.duplicateMinSize) {
                    Text("1 MB").tag(Int64(1_000_000))
                    Text("10 MB").tag(Int64(10_000_000))
                    Text("50 MB").tag(Int64(50_000_000))
                    Text("100 MB").tag(Int64(100_000_000))
                    Text("1 GB").tag(Int64(1_000_000_000))
                }
                .fixedSize()
                Button("找出重複的檔案") { model.findDuplicates() }
                    .disabled(model.duplicatePending)
                if model.duplicatePending {
                    Button("取消") { model.cancelDuplicates() }
                    ProgressView().controlSize(.small)
                }
            }
            if let progress = model.duplicateProgress, model.duplicatePending {
                Text("正在比對：\(progress.stage.title)，\(progress.filesDone) / \(progress.filesTotal) 個，已讀取 \(Fmt.bytes(progress.bytesRead))")
                    .foregroundStyle(.secondary)
            }
            if let report = model.duplicateReport {
                if report.groups.contains(where: { $0.stage == .bytes }) {
                    Button("每組只留一份…") {
                        let picked = Set(report.groups.filter { $0.stage == .bytes }.flatMap { group in
                            group.members.filter { model.isLive($0.node) && $0.node != group.keeper(remains: model.remainsAfterTrash)?.node }.map(\.node)
                        })
                        model.requestDuplicateBatch(report.groups, picked: picked)
                    }
                    .help("每組保留路徑排序最前面的一份，其餘丟到垃圾桶；會先列出項目讓你確認。")
                }
                let refused = report.nothingRead(because: Materialization.refusedDetail)
                if model.cleanupReport != nil {
                    Text("重複檔案和上面的建議可能重疊，兩個數字不要相加。")
                        .foregroundStyle(.secondary)
                }
                if refused {
                    Text("無法關閉 iCloud 下載，所以沒有讀取任何檔案。").foregroundStyle(.orange)
                } else if report.status != .complete {
                    Text("結果不完整：\(report.status == .cancelled ? String(localized: "已取消") : String(localized: "部分檔案無法比對"))；尚有 \(report.pendingFiles) 個待查。")
                        .foregroundStyle(.orange)
                }
                if report.groups.isEmpty && !refused { Text("沒有找到已確認的重複檔案。") }
                Text("可清理大小按檔案內容計算；硬連結、APFS 複製或壓縮檔可能讓實際釋放量較少。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(report.groups.enumerated()), id: \.offset) { _, group in
                    DisclosureGroup(group.stage == .bytes
                                    ? String(localized: "\(Fmt.bytes(group.logicalSize)) × \(group.members.count) 份・可考慮清理 \(Fmt.bytes(group.reclaimableBytes))")
                                    : String(localized: "\(Fmt.bytes(group.logicalSize)) × \(group.members.count) 份・尚待完整比對")) {
                        if group.stage == .bytes {
                            Button("只留一份") {
                                let keeper = group.keeper(remains: model.remainsAfterTrash)?.node
                                for member in group.members {
                                    if member.node != keeper && model.isLive(member.node) { model.duplicatePicks[member.node] = member.path }
                                    else { model.duplicatePicks.removeValue(forKey: member.node) }
                                }
                            }
                        }
                        if group.stage != .bytes {
                            Text("這組尚未逐位元組確認，請先核對內容。")
                                .foregroundStyle(.orange)
                        }
                        ForEach(group.members, id: \.path) { member in
                            DuplicateMemberRow(model: model, member: member, confirmed: group.stage == .bytes,
                                               others: group.members.filter { $0.path != member.path })
                        }
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近清理").font(.headline)
            if model.recentCleanup.isEmpty {
                Text("還沒有從 Hoard 移到垃圾桶的紀錄。")
                    .foregroundStyle(.secondary)
            } else {
                Text("最近 \(model.recentCleanup.count) 項，共 \(recentTotal)。項目仍在垃圾桶時，空間尚未釋放。")
                    .foregroundStyle(.secondary)
                ForEach(model.recentCleanup) { entry in
                    HStack {
                        Text((entry.path as NSString).lastPathComponent).lineLimit(1)
                        Text(Fmt.tildePath((entry.path as NSString).deletingLastPathComponent))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(entry.partial ? (entry.bytes > 0 ? String(localized: "≥ \(Fmt.bytes(entry.bytes))") : String(localized: "無法得知")) : Fmt.bytes(entry.bytes)).monospacedDigit()
                        Text(Fmt.relative(entry.date)).foregroundStyle(.secondary)
                    }
                    .help(entry.path)
                }
            }
        }
    }

    private var recentTotal: String {
        let bytes = model.recentCleanup.reduce(Int64(0)) { $0 + $1.bytes }
        if model.recentCleanup.contains(where: { $0.partial }) {
            return bytes > 0 ? String(localized: "至少 \(Fmt.bytes(bytes))") : String(localized: "大小無法得知")
        }
        return Fmt.bytes(bytes)
    }
}

private struct SuggestionRow: View {
    @ObservedObject var model: AppModel
    let suggestion: Suggestion

    var body: some View {
        let id = suggestion.node
        // The report can trail the tree: act on the node only while it is still the suggested path.
        let live = model.isLive(id) && model.tree?.path(of: id) == suggestion.path
        let isDirectory = live && model.tree?[id].isDirectory == true
        let blocked = live ? model.trashBlockReason(id) : String(localized: "這個項目已經不在了。")
        let key = model.protectionKey(forTreePath: suggestion.path)
        let protected = !model.protection.kinds(key).isEmpty ||
            (isDirectory && !model.protection.inside(key).isEmpty)
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(get: { model.suggestionPicks[id] == suggestion.path }, set: { picked in
                if picked { model.suggestionPicks[id] = suggestion.path }
                else { model.suggestionPicks.removeValue(forKey: id) }
            })) { Text((suggestion.path as NSString).lastPathComponent) }
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel((suggestion.path as NSString).lastPathComponent)
                .disabled(!live || blocked != nil)
            Image(systemName: isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text((suggestion.path as NSString).lastPathComponent).fontWeight(.medium)
                    if protected { Image(systemName: "lock.shield.fill").help("受保護，不能丟到垃圾桶") }
                    Text(suggestion.safety.title).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(Fmt.tildePath((suggestion.path as NSString).deletingLastPathComponent))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(suggestion.reasonText).font(.callout)
                Text("依據：\(suggestion.evidenceText)・上次修改：\(Fmt.relative(Fmt.date(seconds: suggestion.newestModTime)))")
                    .font(.caption).foregroundStyle(.secondary)
                if suggestion.sharedFiles > 0 {
                    Text("有 \(suggestion.sharedFiles) 個檔案共用儲存空間，實際釋放可能較少。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(suggestion.status == .complete ? Fmt.bytes(suggestion.bytes)
                 : suggestion.bytes > 0 ? String(localized: "≥ \(Fmt.bytes(suggestion.bytes))") : String(localized: "無法得知"))
                .monospacedDigit()
            Menu {
                Button("在 Finder 中顯示") { model.reveal([id]) }.disabled(!live)
                Button("快速查看") { model.quickLook([id]) }.disabled(!live)
                if blocked == nil {
                    Divider()
                    Button("丟到垃圾桶…") { model.requestTrash([id], source: "suggest") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .help(blocked ?? suggestion.reasonText)
    }
}

private struct DuplicateMemberRow: View {
    @ObservedObject var model: AppModel
    let member: DuplicateMember
    let confirmed: Bool
    let others: [DuplicateMember]

    var body: some View {
        let live = model.isLive(member.node) && model.tree?.path(of: member.node) == member.path
        let otherLive = others.contains { model.remainsAfterTrash($0) }
        HStack {
            if confirmed && live {
                let picked = model.duplicatePicks[member.node] == member.path
                let canCheck = others.contains { other in
                    model.remainsAfterTrash(other) && model.duplicatePicks[other.node] != other.path
                }
                Toggle(isOn: Binding(get: { picked }, set: { selected in
                    if selected { model.duplicatePicks[member.node] = member.path }
                    else { model.duplicatePicks.removeValue(forKey: member.node) }
                })) { Text((member.path as NSString).lastPathComponent) }
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel((member.path as NSString).lastPathComponent)
                    .disabled(!picked && !canCheck)
                    .help(!picked && !canCheck ? String(localized: "這組至少要留一份。") : member.path)
            }
            Text((member.path as NSString).lastPathComponent)
            Text(Fmt.tildePath((member.path as NSString).deletingLastPathComponent))
                .foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if member.sharesStorage { Text("共用儲存空間").foregroundStyle(.secondary) }
            Menu {
                Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: member.path)]) }
                Button("快速查看") { QuickLook.shared.show([URL(fileURLWithPath: member.path)]) }
                if confirmed, live, otherLive, model.trashBlockReason(member.node) == nil {
                    Divider()
                    Button("丟到垃圾桶…") { model.requestDuplicateTrash(member, others: others) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
        .padding(.leading, 8)
        ForEach(member.aliases, id: \.self) { alias in
            HStack {
                Text((alias as NSString).lastPathComponent)
                Text(Fmt.tildePath((alias as NSString).deletingLastPathComponent))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("共用儲存空間").foregroundStyle(.secondary)
                Button("在 Finder 中顯示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: alias)])
                }
                .buttonStyle(.link)
            }
            .padding(.leading, 20)
        }
    }
}

private enum CleanupSection: CaseIterable {
    case build, caches, leftovers, installers, logs

    var title: String {
        switch self {
        case .build: return String(localized: "建置產物")
        case .caches: return String(localized: "快取")
        case .leftovers: return String(localized: "已移除 App 的資料")
        case .installers: return String(localized: "安裝檔")
        case .logs: return String(localized: "紀錄檔")
        }
    }

    var categories: [SuggestCategory] {
        switch self {
        case .build: return [.buildArtifact]
        case .caches: return [.packageCache, .appCache]
        case .leftovers: return [.appLeftover]
        case .installers: return [.installer]
        case .logs: return [.oldLog]
        }
    }
}

private extension SuggestSafety {
    var title: String {
        switch self {
        case .regenerable: return String(localized: "可重新產生")
        case .redownloadable: return String(localized: "可重新下載")
        case .review: return String(localized: "需要你判斷")
        }
    }
}

private extension Suggestion {
    var reasonText: String {
        switch ruleID {
        case "node_modules": return String(localized: "專案套件，可用套件管理工具重新安裝。")
        case "python_venv": return String(localized: "Python 虛擬環境，可依專案需求重新建立。")
        case "cocoapods": return String(localized: "CocoaPods 套件，可重新下載。")
        case "cargo_target": return String(localized: "Rust 編譯產物，可重新建置。")
        case "swiftpm_build": return String(localized: "Swift 編譯產物，可重新建置。")
        case "gradle_project": return String(localized: "Gradle 專案快取，可重新建立。")
        case "pycache": return String(localized: "Python 編譯快取，使用時會重新產生。")
        case "xcode_derived_data": return String(localized: "Xcode 專案建置資料，可重新建置。")
        case "build_output": return String(localized: "可能是建置產物；請先確認沒有唯一檔案。")
        case "homebrew_cache", "pip_cache", "yarn_cache", "yarn_berry_cache", "npm_cache", "pnpm_store": return String(localized: "已下載套件的快取，需要時可重新下載。")
        case "xcode_device_support": return String(localized: "裝置除錯符號，連線時可重新取得。")
        case "simulator_caches": return String(localized: "模擬器快取，可重新產生。")
        case "app_caches": return String(localized: "App 快取，下次使用時會重新產生。")
        case "app_leftovers": return String(localized: "這個 App 已經不在這台 Mac 上，它留下的資料還在；請確認不再需要。")
        case "installers": return evidence.contains("downloaded from ")
            ? String(localized: "從網路下載的安裝檔，超過一個月沒用，可以重新下載。")
            : String(localized: "超過一個月的安裝檔；找不到下載來源，請先確認。")
        case "disk_images": return String(localized: "超過一個月的磁碟映像檔；可能是安裝檔，也可能是你自己做的映像，請先確認。")
        case "downloaded_zip": return evidence.contains("holds an installer (.app/.pkg/.dmg/.xip)")
            ? String(localized: "裡面有 App 或安裝檔的壓縮檔，超過一個月沒用；請確認不再需要。")
            : String(localized: "超過一個月的壓縮檔；請確認它不是唯一副本。")
        case "library_logs", "log_files": return String(localized: "超過一個月沒有寫入的大型紀錄檔。")
        default: return String(localized: "請先確認這個項目仍可清理。")
        }
    }

    var evidenceText: String {
        evidence.components(separatedBy: "; ").map { part in
            if part.hasPrefix("sibling ") { return String(localized: "同層有 \(part.dropFirst(8))") }
            if part.hasPrefix("contains "), part.hasSuffix(" package checkouts (git clones)") {
                return String(localized: "含有 Git 套件副本")
            }
            if part.hasPrefix("contains ") { return String(localized: "內有 \(part.dropFirst(9))") }
            if part.hasPrefix("only "), part.hasSuffix(" files inside") {
                return String(localized: "內部只有 \(part.dropFirst(5).dropLast(13)) 檔案")
            }
            if part.hasPrefix("at ") { return String(localized: "位於 \(part.dropFirst(3))") }
            if part.hasPrefix("inside ") { return String(localized: "位於 \(part.dropFirst(7)) 之內") }
            if part.hasPrefix("under ") { return String(localized: "位於 \(part.dropFirst(6)) 之下") }
            if part.hasPrefix("none of "), part.hasSuffix(" beside it") {
                return String(localized: "同層未找到 \(part.dropFirst(8).dropLast(10))")
            }
            if part.hasPrefix("no recorded use for "), part.hasSuffix(" days") {
                return String(localized: "\(part.dropFirst(20).dropLast(5)) 天沒有修改或開啟的紀錄")
            }
            if part == "some folders inside could not be read" { return String(localized: "內部有資料夾無法讀取") }
            if part.hasSuffix(" file") { return String(localized: "副檔名為 \(part.dropLast(5))") }
            return part
        }.joined(separator: "；")
    }
}

private extension DuplicateStage {
    var title: String {
        switch self { case .size: return String(localized: "大小"); case .edges: return String(localized: "檔案頭尾"); case .bytes: return String(localized: "完整內容") }
    }
}

private extension HiddenSpace.Line {
    var title: String {
        switch id {
        case "capacity": return String(localized: "磁碟總容量")
        case "available": return String(localized: "可用空間")
        case "used": return String(localized: "已用空間")
        case "scanned": return String(localized: "掃到的檔案")
        case "vm_volume": return String(localized: "虛擬記憶體磁區")
        case "other_volumes": return String(localized: "其他已掛載磁區")
        case "snapshots": return String(localized: "Time Machine 本機快照")
        case "unreadable": return String(localized: "無法讀取的資料夾")
        case "unexplained": return String(localized: "其餘無法對上的空間")
        case "purgeable": return String(localized: "可清除空間")
        case "swap": return String(localized: "交換檔")
        case "sleep_image": return String(localized: "睡眠映像檔")
        default: return label
        }
    }
    var sizeText: String {
        guard let bytes, state != .unknown else { return String(localized: "無法得知") }
        if state == .estimated, bytes == 0 { return String(localized: "無法得知") }
        if id == "scanned", state == .estimated { return String(localized: "至少 \(Fmt.bytes(bytes))") }
        return state == .estimated ? String(localized: "約 \(Fmt.bytes(bytes))") : Fmt.bytes(bytes)
    }
    var explanation: String {
        switch id {
        case "capacity", "available", "used": return state == .unknown ? String(localized: "無法讀取磁碟容量資訊。") : String(localized: "依磁碟提供的容量資訊計算。")
        case "scanned": return state == .unknown ? String(localized: "掃描位置無法讀取。") : String(localized: "來自掃描結果；未完整讀取時只顯示下限。")
        case "vm_volume", "other_volumes": return state == .unknown ? String(localized: "無法取得其他磁區的用量。") : String(localized: "由系統回報的磁區用量。")
        case "snapshots": return state == .unknown ? String(localized: "系統只提供快照數量，沒有提供大小。") : String(localized: "Time Machine 本機快照的數量為零。")
        case "unreadable": return state == .unknown ? String(localized: "有資料夾無法讀取，大小無法得知。") : String(localized: "掃描中沒有發現無法讀取的資料夾。")
        case "unexplained": return state == .unknown ? String(localized: "掃描範圍或其他磁區資料不足，無法計算差額。") : String(localized: "已用空間扣除目前可量測的項目；估計值可能包含未量測項目。")
        case "purgeable": return state == .unknown ? String(localized: "系統沒有提供可清除空間的可靠數值。") : String(localized: "依系統提供的可用空間估算。")
        case "swap": return state == .unknown ? String(localized: "無法讀取交換檔用量。") : String(localized: "由系統回報的交換檔用量。")
        case "sleep_image": return state == .unknown ? String(localized: "無法讀取睡眠映像檔大小。") : String(localized: "磁碟上的睡眠映像檔大小。")
        default: return state == .unknown ? String(localized: "系統沒有提供可靠數值。") : String(localized: "由系統提供的數值。")
        }
    }
}
