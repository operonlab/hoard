import SwiftUI

/// What 自動更新 (the live updater) is doing, for the toolbar.
enum AutoRefreshState: Equatable {
    /// Watching; no file has changed, so nothing runs.
    case idle
    /// Re-reading folders that changed.
    case working(folders: Int)
    /// Applied a change in the last few seconds. Most changes take milliseconds, so without this the
    /// button would never be seen at work.
    case justUpdated
    /// Applying what changed while the app was closed.
    case catchingUp
    /// Too much changed to follow one folder at a time: the app is rescanning the whole location.
    case rescanning
    /// It could not start or lost track; changes are not picked up.
    case stopped

    var isWorking: Bool {
        switch self {
        case .working, .catchingUp, .rescanning: return true
        case .idle, .justUpdated, .stopped: return false
        }
    }

    // The counts go in as integers so English can pick "1 folder" or "3 folders".
    var title: String {
        switch self {
        case .idle: return String(localized: "自動更新・待命")
        case .working(let folders): return String(localized: "自動更新中⋯ \(folders) 個資料夾")
        case .justUpdated: return String(localized: "自動更新・剛更新")
        case .catchingUp: return String(localized: "自動更新中⋯ 補上變動")
        case .rescanning: return String(localized: "自動更新中⋯ 重新掃描")
        case .stopped: return String(localized: "自動更新已停止")
        }
    }

    var now: String {
        switch self {
        case .idle: return String(localized: "待命中，目前沒有資料夾需要重算。")
        case .working(let folders): return String(localized: "正在重算 \(folders) 個有變動的資料夾。")
        case .justUpdated: return String(localized: "剛重算完有變動的資料夾，沒有其他事要做。")
        case .catchingUp: return String(localized: "正在補上 app 關著的這段期間的變動，畫面先顯示上次的結果。")
        case .rescanning: return String(localized: "變動太多，一個個資料夾跟不上，正在背景重新掃描整個位置。上次的結果先留在畫面上。")
        case .stopped: return String(localized: "已停止，檔案變動不會自動反映。按 ⌘R 重新掃描就會重新開始。")
        }
    }
}

/// Toolbar button: grey while it waits, a spinner while it works; click for what it is in plain words.
struct AutoRefreshButton: View {
    @ObservedObject var model: AppModel
    @State private var showInfo = false

    var body: some View {
        if let state = model.autoRefresh {
            Button { showInfo.toggle() } label: {
                HStack(spacing: 5) {
                    if state.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: state == .stopped ? "exclamationmark.triangle"
                              : state == .justUpdated ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    }
                    Text(state.title).monospacedDigit()
                }
                .foregroundStyle(state == .idle ? .secondary : .primary)
            }
            .help("自動更新：檔案變動時自己重算，在背景低優先權執行")
            .accessibilityLabel(state.title)
            .popover(isPresented: $showInfo, arrowEdge: .bottom) { AutoRefreshInfo(model: model, state: state) }
        }
    }
}

private struct AutoRefreshInfo: View {
    @ObservedObject var model: AppModel
    let state: AutoRefreshState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自動更新").font(.headline)
            Text("檔案有變動時，Hoard 會自己重算大小，不用你按重新掃描。它在背景用低優先權跑，你正在用的 app 優先。")
            Divider()
            Text("現在：\(state.now)")
            if let changed = model.dataChangedAt {
                Text("上次更新：\(Fmt.relative(changed, now: model.clock))").foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 300, alignment: .leading)
        .padding(14)
    }
}
