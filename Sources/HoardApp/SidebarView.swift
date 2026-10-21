import SwiftUI
import ScanCore

/// 位置 / 最近 / 檢視 (§1.3). Locations are actions (they change the scan root); the list selection
/// is the current view.
struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: Binding<ViewKind?>(get: { model.tree == nil && model.view.needsTree ? nil : model.view },
                                          set: { if let kind = $0 { model.view = kind } })) {
            Section("位置") {
                locationRow(Places.disk, icon: "internaldrive", title: Places.diskName, spoken: String(localized: "整個磁碟，\(Places.diskName)"))
                locationRow(Places.home, icon: "house", title: Places.userName, spoken: String(localized: "家目錄，\(Places.userName)"))
                Button { FolderPicker.choose(model) } label: {
                    Label("選擇資料夾…", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }
            if !model.recents.isEmpty {
                Section("最近") {
                    ForEach(model.recents, id: \.self) { path in
                        locationRow(path, icon: "folder", title: Places.displayName(of: path), spoken: nil)
                            .help(path)
                            .contextMenu {
                                Button("從最近項目移除") { model.forgetRecent(path) }
                            }
                    }
                }
            }
            Section("檢視") {
                ForEach(ViewKind.allCases) { kind in
                    HStack {
                        Label(kind.title, systemImage: kind.symbol)
                        Spacer(minLength: 4)
                        if kind == .changes, let net = model.changesNet, abs(net) > 100_000_000 {
                            Text(Fmt.delta(net)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if kind == .protected { protectedCount }
                    }
                    .tag(kind)
                    .disabled(model.tree == nil && kind.needsTree)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// "3", or a warning when the list is unreadable or an entry needs attention.
    @ViewBuilder private var protectedCount: some View {
        let snapshot = model.protection
        if snapshot.loaded {
            HStack(spacing: 4) {
                if snapshot.readError != nil || snapshot.problemCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help(snapshot.readError != nil ? String(localized: "讀不到保護清單") : String(localized: "\(snapshot.problemCount) 個項目需要處理"))
                }
                if snapshot.readError == nil || !snapshot.rows.isEmpty {
                    Text(Fmt.count(snapshot.rows.count)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(snapshot.readError != nil ? String(localized: "讀不到保護清單")
                                : snapshot.problemCount > 0 ? String(localized: "\(snapshot.rows.count) 個項目，\(snapshot.problemCount) 個需要處理")
                                : String(localized: "\(snapshot.rows.count) 個項目"))
        }
    }

    private func locationRow(_ path: String, icon: String, title: String, spoken: String?) -> some View {
        let current = model.rootPath == path
        return Button { model.choose(path) } label: {
            HStack {
                // The name gets the room first; the size truncates before it does.
                Label(title, systemImage: icon)
                    .fontWeight(current ? .semibold : .regular)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let total = RootMemory.totalText(for: path) {
                    Text(total).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken ?? title)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
