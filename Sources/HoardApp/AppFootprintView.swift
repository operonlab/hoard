import AppKit
import SwiftUI
import ScanCore

struct AppFootprintView: View {
    @ObservedObject var model: AppModel

    private var apps: [AppFootprint] {
        (model.appReport?.apps ?? []).sorted {
            if $0.isApple != $1.isApple { return !$0.isApple }
            let left = ($0.appSize.bytes ?? 0) + ($0.data.bytes ?? 0)
            let right = ($1.appSize.bytes ?? 0) + ($1.data.bytes ?? 0)
            return left != right ? left > right : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewHeader(title: String(localized: "App 佔用"), sentence: String(localized: "顯示 App 本體與能對上的使用者資料；資料可能不完整。Apple App 排在最後。確認後才會移到垃圾桶。"), busy: model.appPending) { EmptyView() }
            if let error = model.appError {
                Text("無法分析 App 佔用：\(error)").foregroundStyle(.orange).padding()
            }
            if let report = model.appReport, !report.unreadable.isEmpty {
                Text("有 \(report.unreadable.count) 個位置無法讀取，部分大小可能不足或無法得知。")
                    .foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider()
            if apps.isEmpty, !model.appPending {
                ContentUnavailableView("沒有找到 App", systemImage: "app.badge", description: Text("目前找不到可分析的 App。"))
            } else {
                List {
                    HStack {
                        Text("App").frame(maxWidth: .infinity, alignment: .leading)
                        Text("App 大小").frame(width: 110, alignment: .trailing)
                        Text("資料大小").frame(width: 110, alignment: .trailing)
                        Text("上次使用").frame(width: 100, alignment: .trailing)
                        Color.clear.frame(width: Self.actionWidth, height: 1)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(apps, id: \.appPath) { app in
                        DisclosureGroup {
                            if app.locations.isEmpty {
                                Text("沒有找到可對應的使用者資料位置。")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(app.locations, id: \.path) { location in
                                HStack {
                                    Text(location.kind.localizedTitle)
                                        .frame(width: 140, alignment: .leading)
                                    Text(Fmt.tildePath(location.path))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(location.size.displayText).monospacedDigit()
                                    Button("在 Finder 中顯示") { reveal(location.path) }
                                        .buttonStyle(.link)
                                }
                            }
                            if app.sharedData.bytes != nil {
                                Text("部分資料可能由多個 App 共用，請勿把各列大小直接相加。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("在 Finder 中顯示 App") { reveal(app.appPath) }
                                .buttonStyle(.link)
                        } label: {
                            HStack {
                                HStack(spacing: 5) {
                                    Text(app.name).lineLimit(1)
                                    if app.isApple { Text("Apple").font(.caption).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(app.appSize.displayText).frame(width: 110, alignment: .trailing)
                                Text(app.data.displayText).frame(width: 110, alignment: .trailing)
                                Text(Fmt.relative(app.lastUsed)).frame(width: 100, alignment: .trailing)
                                Button("解除安裝…") { model.requestUninstall(app) }
                                    .disabled(!UninstallPlanner.isRemovableApple(app))
                                    .help(!UninstallPlanner.isRemovableApple(app) ? String(localized: "這個 Apple App 不能由 Hoard 移除。") : String(localized: "查看解除安裝規劃"))
                                    .frame(width: Self.actionWidth, alignment: .trailing)
                            }
                            .monospacedDigit()
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private static let actionWidth: CGFloat = 96

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

private extension SizeReading {
    var displayText: String {
        guard let bytes, status != .unavailable else { return String(localized: "無法得知") }
        return status == .partial ? (bytes > 0 ? String(localized: "≥ \(Fmt.bytes(bytes))") : String(localized: "無法得知")) : Fmt.bytes(bytes)
    }
}

private extension AppDataKind {
    var localizedTitle: String {
        switch self {
        case .applicationSupport: String(localized: "App 支援資料")
        case .caches: String(localized: "快取")
        case .containers: String(localized: "容器")
        case .groupContainers: String(localized: "群組容器")
        case .preferences: String(localized: "偏好設定")
        case .logs: String(localized: "紀錄檔")
        case .savedState: String(localized: "App 儲存狀態")
        case .httpStorages: String(localized: "HTTP 儲存空間")
        case .webKit: String(localized: "WebKit 資料")
        case .cookies: String(localized: "Cookie")
        }
    }
}
