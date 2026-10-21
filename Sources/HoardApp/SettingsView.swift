import AppKit
import ServiceManagement
import SwiftUI

/// The login item that runs `hoard guardian` while the app is closed. scripts/make-app.sh puts
/// the plist in Contents/Library/LaunchAgents; off by default.
enum BackgroundGuardian {
    /// Named after the bundle id, so a development build carries (and can only register) its own agent.
    static let plistName = "\(Bundle.main.bundleIdentifier ?? "com.operonlab.hoard").guardian.plist"
    static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    /// Whether this build carries the plist. `status` alone cannot say: it reported `.notFound` for the
    /// bundled, never-registered agent of an app started from the shell.
    static var isBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)").path)
    }

    static func statusText(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return String(localized: "已開啟")
        case .notRegistered: return String(localized: "已關閉")
        case .requiresApproval: return String(localized: "需要在系統設定允許")
        case .notFound: return isBundled ? String(localized: "已關閉") : String(localized: "這個版本的 App 裡沒有背景守護程式")
        @unknown default: return String(localized: "狀態不明")
        }
    }
}

/// 設定 (⌘,).
struct SettingsView: View {
    @State private var status = BackgroundGuardian.service.status
    @State private var failure: String?
    @State private var language = AppLanguage.saved

    var body: some View {
        Form {
            Section {
                Picker("語言", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.name).tag($0) }
                }
                .onChange(of: language) { _, chosen in AppLanguage.save(chosen) }
                if language != AppLanguage.atLaunch {
                    HStack {
                        Text("重新開啟 Hoard 後套用。").foregroundStyle(.secondary)
                        Spacer()
                        Button("立即重新開啟") { AppLanguage.relaunch() }
                    }
                }
            } header: {
                Text("語言")
            }
            Section {
                Toggle("App 關閉時也守護（登入後在背景執行）", isOn: Binding(
                    get: { status == .enabled || status == .requiresApproval },
                    set: { change(to: $0) }))
                    .disabled(!BackgroundGuardian.isBundled)
                LabeledContent(String(localized: "狀態")) {
                    HStack(spacing: 8) {
                        Text(BackgroundGuardian.statusText(status))
                        if status == .requiresApproval {
                            Button("打開系統設定") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                }
                Text("開啟後，登入時會在背景執行 Hoard 的守護程式：守護的項目在 App 沒開的時候被刪除，也會自動放回。鎖定不需要它。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("背景守護")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { status = BackgroundGuardian.service.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = BackgroundGuardian.service.status
        }
    }

    private func change(to on: Bool) {
        failure = nil
        do {
            if on { try BackgroundGuardian.service.register() } else { try BackgroundGuardian.service.unregister() }
        } catch {
            failure = on ? String(localized: "無法開啟背景守護：\(error.localizedDescription)")
                         : String(localized: "無法關閉背景守護：\(error.localizedDescription)")
        }
        status = BackgroundGuardian.service.status
    }
}
