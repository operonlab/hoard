import AppKit
import SwiftUI
import ScanCore

/// Why the Full Disk Access sheet is open (§2.2.1).
enum AccessSheetMode: Identifiable {
    case beforeScan(String)   // about to scan this path
    case info                 // from the banner's 授權方式…

    static let skippedKey = "skippedFDAPrompt"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    var id: String {
        switch self {
        case .beforeScan(let path): return "scan:" + path
        case .info: return "info"
        }
    }
}

struct AccessSheet: View {
    @ObservedObject var model: AppModel
    let mode: AccessSheetMode
    @State private var showManualPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 36)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("要算出整顆磁碟的用量，需要「完整磁碟取用權限」").font(.title3.weight(.semibold))
            Text("郵件、訊息、Safari 等資料夾受到系統保護。Hoard 需要權限才能讀到它們的大小。Hoard 只讀檔案大小和日期，不讀檔案內容，也不會上傳任何資料。")
                .fixedSize(horizontal: false, vertical: true)
            Text("不授權也可以掃描：讀不到的資料夾會標成「無法讀取」，總量會顯示為「至少 ⋯」。")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("授權方式").fontWeight(.semibold)
                Text("1. 按「打開系統設定」")
                Text("2. 在「完整磁碟取用權限」清單中打開 Hoard。清單裡沒有的話，按「+」加入 Hoard。")
                    .fixedSize(horizontal: false, vertical: true)
                Text("3. 回到 Hoard，按「重新掃描」。")
            }
            if showManualPath {
                Text("請打開「系統設定 › 隱私權與安全性 › 完整磁碟取用權限」。").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                switch mode {
                case .beforeScan(let path):
                    Button("先不用，直接掃描") {
                        UserDefaults.standard.set(true, forKey: AccessSheetMode.skippedKey)
                        model.accessSheet = nil
                        model.open(path)
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("打開系統設定") {
                        openSettings()
                        model.accessSheet = nil
                        model.open(path)
                    }
                    .keyboardShortcut(.defaultAction)
                case .info:
                    Button("關閉") { model.accessSheet = nil }.keyboardShortcut(.cancelAction)
                    Button("打開系統設定") {
                        openSettings()
                        if !showManualPath { model.accessSheet = nil }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func openSettings() {
        model.openedSettings = true
        if let url = AccessSheetMode.settingsURL, NSWorkspace.shared.open(url) { return }
        // The deep link did not open: open System Settings and spell out the path instead.
        showManualPath = true
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

/// Non-modal banner above the content (§2.3, §2.2 step 5). Warns only when the permission is missing.
struct AccessBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let tree = model.tree, !model.accessBannerDismissed {
            if model.accessGained {
                banner(icon: "checkmark.shield", tint: Color.secondary.opacity(0.08)) {
                    Text("已取得權限，重新掃描以補上先前讀不到的資料夾。")
                    Spacer(minLength: 8)
                    Button("重新掃描") { model.rescan() }
                }
            } else if model.fullDiskAccess == .denied && model.unreadableCount > 0 && tree[FileTree.root].status != .complete {
                banner(icon: "lock.fill", tint: Color.orange.opacity(0.12)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("有 \(model.unreadableCount) 個資料夾因為權限讀不到，所以總量顯示為「\(Fmt.sizeLong(tree[FileTree.root]))」。")
                        if model.openedSettings {
                            Text("如果你已經打開開關，請結束 Hoard 再重新打開。").foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("授權方式…") { model.accessSheet = .info }
                }
            }
        }
    }

    private func banner<Content: View>(icon: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).accessibilityHidden(true)
            content()
            Button { model.accessBannerDismissed = true } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("關閉提示")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(tint)
    }
}

/// Never scanned anything: three ways to start (§2.1).
struct EmptyStateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("看看這台 Mac 的空間都用在哪裡", systemImage: "internaldrive")
        } description: {
            Text("選一個位置開始。Hoard 只讀取檔案的大小和日期，不會更動或上傳任何東西。")
        } actions: {
            VStack(spacing: 10) {
                option(icon: "internaldrive", title: String(localized: "整個磁碟「\(Places.diskName)」"), detail: volumeUsage) {
                    model.choose(Places.disk)
                }
                option(icon: "house", title: String(localized: "家目錄「\(Places.userName)」"), detail: nil) { model.choose(Places.home) }
                option(icon: "folder", title: String(localized: "選擇資料夾…"), detail: nil) { FolderPicker.choose(model) }
                Text("也可以把資料夾拖到這個視窗。").font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            }
            .frame(maxWidth: 460)
        }
    }

    private var volumeUsage: (String, Double)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        let used = Int64(total) - free
        return (String(localized: "已使用 \(Fmt.bytes(used))，共 \(Fmt.bytes(Int64(total)))"), Double(used) / Double(total))
    }

    private func option(icon: String, title: String, detail: (String, Double)?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).frame(width: 30).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.medium))
                    if let detail {
                        HStack {
                            Text(detail.0).font(.callout).foregroundStyle(.secondary)
                            ProgressView(value: detail.1).frame(width: 120)
                        }
                    }
                }
                Spacer()
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }
}

/// First scan of a location, nothing to show yet (§2.4).
struct ScanProgressView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let progress = model.progress
        VStack(spacing: 14) {
            Text("正在掃描「\(model.rootPath.map(Places.displayName(of:)) ?? "")」").font(.title2.weight(.semibold))
            if let estimate = model.progressEstimate, estimate > 0 {
                let ratio = min(0.99, Double(progress?.bytes ?? 0) / Double(estimate))
                HStack {
                    ProgressView(value: ratio).frame(width: 360)
                    Text("約 \(Int(ratio * 100))%").monospacedDigit()
                }
                Text("以上次掃描的 \(Fmt.bytes(estimate)) 估算").font(.callout).foregroundStyle(.secondary)
            } else {
                // D6: no cheap denominator for a first scan, so no percentage that could stall or go back.
                ProgressView().progressViewStyle(.linear).frame(width: 360)
            }
            if let progress {
                Text("已找到 \(Fmt.bytes(progress.bytes))・\(progress.files) 個檔案・\(progress.dirs) 個資料夾")
                    .monospacedDigit()
                Text(Fmt.elapsed(progress.elapsed)).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("正在準備⋯").foregroundStyle(.secondary)
            }
            Button("停止掃描") { model.stopScan() }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// The scan root vanished or cannot be read (§7.4).
struct ScanFailureView: View {
    @ObservedObject var model: AppModel
    let failure: ScanFailure

    var body: some View {
        ContentUnavailableView {
            Label("無法掃描「\(Places.displayName(of: failure.path))」", systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.reason)
        } actions: {
            HStack {
                Button("重試") { model.open(failure.path) }
                Button("選擇其他位置") { FolderPicker.choose(model) }
            }
        }
    }
}
