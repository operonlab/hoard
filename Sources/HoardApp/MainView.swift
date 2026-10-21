import AppKit
import SwiftUI
import ScanCore

/// Sidebar + content + trailing inspector (§1.1), one unified toolbar (§1.4).
struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            ContentArea(model: model)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(model.windowTitle)
                .navigationSubtitle(model.subtitle)
                .toolbar { toolbarContent }
                .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("搜尋「\(model.scopeName)」"))
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else {
                return false
            }
            model.choose(folder.path)
            return true
        }
        .sheet(item: $model.trashRequest) { request in TrashSheet(model: model, request: request) }
        .sheet(item: $model.uninstallRequest) { request in UninstallSheet(model: model, request: request) }
        .sheet(item: $model.accessSheet) { mode in AccessSheet(model: model, mode: mode) }
        .sheet(item: $model.protectRequest) { request in ProtectSheet(model: model, request: request) }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("好") { model.alert = nil }
        } message: { Text(model.alert?.message ?? "") }
        // For renders: --settings opens the Settings window, which the render then draws.
        .task { if CommandLine.arguments.contains("--settings") { openSettings() } }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("返回", systemImage: "chevron.left") }
                .help("返回")
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Label("前進", systemImage: "chevron.right") }
                .help("前進")
                .disabled(!model.canGoForward)
        }
        ToolbarItem(placement: .principal) {
            if model.view == .map && model.tree != nil {
                Picker("顯示方式", selection: $model.mapMode) {
                    Label("圖", systemImage: "square.grid.2x2").tag(MapMode.graph).help("以圖顯示")
                    Label("清單", systemImage: "list.bullet.indent").tag(MapMode.list).help("以清單顯示")
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .fixedSize()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            AutoRefreshButton(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            if model.scanning {
                Button { model.stopScan() } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Image(systemName: "stop.fill")
                    }
                }
                .help("停止掃描")
                .accessibilityLabel("停止掃描")
            } else {
                Button { model.rescan() } label: { Label("重新掃描", systemImage: "arrow.clockwise") }
                    .help("重新掃描")
                    .disabled(model.rootPath == nil)
            }
        }
    }
}

/// What the content column shows for the current state and view.
struct ContentArea: View {
    @ObservedObject var model: AppModel

    var body: some View {
        main.safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = model.restoredBanner { RestoredBanner(model: model, notice: notice) }
        }
    }

    @ViewBuilder private var main: some View {
        if model.tree == nil && model.view == .protected {
            ProtectedView(model: model)
        } else if model.tree != nil {
            VStack(spacing: 0) {
                AccessBanner(model: model)
                if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsView(model: model)
                } else {
                    switch model.view {
                    case .map:
                        Group {
                            if model.mapMode == .graph { SpaceMapView(model: model) } else { DirectoryOutline(model: model) }
                        }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if model.selectedIDs.count > 1 { SelectionBar(model: model, ids: model.selectedIDs) }
                        }
                    case .largest: LargestFilesView(model: model)
                    case .types: FileTypesView(model: model)
                    case .stale: StaleFilesView(model: model)
                    case .cleanup: CleanupView(model: model)
                    case .changes: ChangesView(model: model)
                    case .protected: ProtectedView(model: model)
                    case .apps: AppFootprintView(model: model)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let batch = model.trashedBanner { TrashedBanner(model: model, batch: batch) }
            }
        } else if let failure = model.scanFailure {
            ScanFailureView(model: model, failure: failure)
        } else if model.scanning {
            ScanProgressView(model: model)
        } else {
            EmptyStateView(model: model)
        }
    }
}
