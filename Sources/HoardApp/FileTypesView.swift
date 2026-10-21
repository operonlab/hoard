import SwiftUI
import ScanCore

/// 檔案類型 (§4.2): categories, each expandable into its extensions, from `extensionStats`.
struct FileTypesView: View {
    @ObservedObject var model: AppModel
    @State private var picked: Highlight?
    @State private var expanded: Set<FileCategory> = []
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let groups = self.groups
        let total = max(1, model.tree.map { $0[model.scope].totalAlloc } ?? 1)
        let status = model.tree.map { $0[model.scope].status } ?? .complete
        VStack(spacing: 0) {
            if status == .unavailable {
                // Unknown, not empty (§7.1): no totals at all.
                ViewHeader(title: String(localized: "檔案類型"), sentence: String(localized: "沒有權限讀取「\(model.scopeName)」。")) { EmptyView() }
                Divider()
                ContentUnavailableView {
                    Label("無法讀取", systemImage: "lock.fill")
                } description: {
                    Text("沒有權限讀取這個資料夾")
                }
            } else {
                content(groups, total: total, lowerBound: status == .partial)
            }
        }
    }

    @ViewBuilder private func content(_ groups: [Group], total: Int64, lowerBound: Bool) -> some View {
        ViewHeader(title: String(localized: "檔案類型"), sentence: sentence(groups), busy: model.statsPending) { EmptyView() }
        Divider()
        header
        List(selection: $picked) {
            ForEach(groups, id: \.category) { group in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(group.category) },
                                                    set: { if $0 { expanded.insert(group.category) } else { expanded.remove(group.category) } })) {
                    ForEach(group.stats, id: \.ext) { stat in
                        row(title: stat.ext.isEmpty ? String(localized: "（沒有副檔名）") : ".\(stat.ext)", category: group.category,
                            swatch: false, bytes: stat.bytes, lowerBound: lowerBound, count: stat.count, total: total)
                            .tag(Highlight.ext(stat.ext))
                    }
                } label: {
                    row(title: group.category.title, category: group.category, swatch: true, bytes: group.bytes,
                        lowerBound: lowerBound, count: group.count, total: total)
                        .fontWeight(.medium)
                }
                .tag(Highlight.category(group.category))
            }
        }
        .listStyle(.inset)
        .opacity(model.statsPending && !groups.isEmpty ? 0.5 : 1)
        Divider()
        HStack {
            Spacer()
            Button("在空間地圖中標示") {
                model.highlight = picked
                model.mapMode = .graph
                model.view = .map
            }
            .disabled(picked == nil)
        }
        .padding(10)
    }

    private struct Group {
        let category: FileCategory
        let bytes: Int64
        let count: Int64
        let stats: [ExtensionStat]
    }

    private var groups: [Group] {
        var byCategory: [FileCategory: [ExtensionStat]] = [:]
        for stat in model.stats { byCategory[FileCategory.of(extension: stat.ext), default: []].append(stat) }
        return byCategory.map { category, stats in
            Group(category: category, bytes: stats.reduce(0) { $0 + $1.bytes }, count: stats.reduce(0) { $0 + $1.count },
                  stats: stats.sorted { $0.bytes > $1.bytes })
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.category.rawValue < $1.category.rawValue }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("類型").frame(maxWidth: .infinity, alignment: .leading)
            Text("大小").frame(width: 90, alignment: .trailing)
            Text("比例").frame(width: 170, alignment: .leading)
            Text("檔案數").frame(width: 80, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 30)
        .padding(.vertical, 5)
    }

    private func row(title: String, category: FileCategory, swatch: Bool, bytes: Int64, lowerBound: Bool,
                     count: Int64, total: Int64) -> some View {
        let ratio = min(1, Double(bytes) / Double(total))
        let look = FileCategory.Look(dark: scheme == .dark, highContrast: contrast == .increased)
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                if swatch {
                    RoundedRectangle(cornerRadius: 2).fill(category.color).frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                }
                Text(title).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(lowerBound ? String(localized: "≥ \(Fmt.bytes(bytes))") : Fmt.bytes(bytes)).monospacedDigit()
                .frame(width: 90, alignment: .trailing)
                .accessibilityLabel(lowerBound ? String(localized: "至少 \(Fmt.bytes(bytes))") : Fmt.bytes(bytes))
            HStack(spacing: 6) {
                // Same fill as the category's file tiles on the map (§3.2 rule 1).
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule().fill(category.fill(look).color)
                                .frame(width: max(ratio > 0 ? 3 : 0, geometry.size.width * ratio))
                        }
                    }
                    .frame(width: 110, height: 6)
                    .accessibilityHidden(true)
                Text(Fmt.percent(ratio)).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(width: 170, alignment: .leading)
            Text(Fmt.count(count)).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func sentence(_ groups: [Group]) -> String {
        guard let tree = model.tree else { return "" }
        let scopeNode = tree[model.scope]
        let partial = scopeNode.status == .partial
        // Totals below a partial scope are lower bounds (§7.1).
        let unreadable = model.scopeUnreadable.isEmpty ? String(localized: "有些資料夾讀不到，實際可能更多。")
            : String(localized: "有 \(model.scopeUnreadable.count) 個資料夾讀不到，實際可能更多。")
        guard let top = groups.first else {
            if model.statsPending { return String(localized: "正在統計「\(model.scopeName)」的檔案類型⋯") }
            return partial ? String(localized: "「\(model.scopeName)」裡讀得到的部分沒有檔案。\n\(unreadable)") : String(localized: "「\(model.scopeName)」裡沒有檔案。")
        }
        let ratio = scopeNode.totalAlloc > 0 ? Double(top.bytes) / Double(scopeNode.totalAlloc) : 0
        let size = partial ? String(localized: "共至少 \(Fmt.bytes(top.bytes))") : String(localized: "共 \(Fmt.bytes(top.bytes))")
        if partial {
            return String(localized: "\(model.scopeName) 裡最多的是「\(top.category.title)」，\(size)（\(Fmt.percent(ratio))）。比例以讀得到的部分計算。\n\(unreadable)")
        }
        return String(localized: "\(model.scopeName) 裡最多的是「\(top.category.title)」，\(size)（\(Fmt.percent(ratio))）。")
    }
}
