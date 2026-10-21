import SwiftUI
import ScanCore

/// 最大的檔案 (§4.1): the 1,000 largest counted files in the scope, from `TreeQuery.largestFiles`.
struct LargestFilesView: View {
    @ObservedObject var model: AppModel
    @State private var filter: FileCategory?

    var body: some View {
        let rows = filter.map { wanted in model.largestRows.filter { $0.category == wanted } } ?? model.largestRows
        VStack(spacing: 0) {
            ViewHeader(title: String(localized: "最大的檔案"), sentence: sentence(rows), busy: model.largestPending) {
                Picker("類型：", selection: $filter) {
                    Text("全部").tag(FileCategory?.none)
                    Divider()
                    ForEach(FileCategory.allCases) { category in
                        Text(category.title).tag(Optional(category))
                    }
                }
                .fixedSize()
            }
            Divider()
            if rows.isEmpty && !model.largestPending {
                ContentUnavailableView(filter.map { String(localized: "沒有「\($0.title)」檔案") } ?? String(localized: "沒有檔案"),
                                       systemImage: "doc",
                                       description: Text("「\(model.scopeName)」裡沒有符合的檔案。"))
            } else {
                FileTable(model: model, rows: rows)
                    .opacity(model.largestPending && !rows.isEmpty ? 0.5 : 1)
            }
        }
    }

    private func sentence(_ rows: [FileRow]) -> String {
        if model.largestPending && rows.isEmpty { return String(localized: "正在找出「\(model.scopeName)」裡最大的檔案⋯") }
        let total = rows.reduce(Int64(0)) { $0 + $1.bytes }
        if let filter {
            return String(localized: "\(model.scopeName) 裡前 \(rows.count) 個最大的「\(filter.title)」檔案，共 \(Fmt.bytes(total))。")
        }
        return String(localized: "\(model.scopeName) 裡前 \(rows.count) 個最大的檔案，共 \(Fmt.bytes(total))。")
    }
}

/// Search results (§4.3) replace the current view while the search field has text.
struct SearchResultsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("搜尋範圍", selection: $model.searchWholeTree) {
                    Text("目前資料夾").tag(false)
                    Text("整個掃描範圍").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if model.searchPending { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            if let result = model.searchResult {
                if result.count == 0 {
                    ContentUnavailableView.search(text: result.query)
                } else {
                    Text(summary(result))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    Divider()
                    FileTable(model: model, rows: result.rows)
                        .opacity(model.searchPending ? 0.5 : 1)
                }
            } else {
                Spacer()
            }
        }
    }

    private func summary(_ result: SearchResult) -> String {
        if result.count > result.rows.count {
            return String(localized: "找到 \(result.count) 個項目，共 \(Fmt.bytes(result.bytes))。列出最大的 \(result.rows.count) 個。")
        }
        return String(localized: "找到 \(result.count) 個項目，共 \(Fmt.bytes(result.bytes))。")
    }
}
