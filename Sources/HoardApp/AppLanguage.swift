import AppKit

/// Settings › 語言: the app's own language over the macOS one (docs/plans/v0.6-i18n.md). macOS reads it
/// from the app's AppleLanguages default at launch, so a change applies after the app is reopened.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "", zhHant = "zh-Hant", en, ja, ko

    var id: String { rawValue }

    /// Each language in its own words, so anyone can find theirs whatever the app shows now.
    var name: String {
        switch self {
        case .system: return String(localized: "系統預設")
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }

    private static let key = "AppleLanguages"

    /// The choice saved for this app. Read from the app's own domain: `UserDefaults.standard` would
    /// also return the global AppleLanguages, which is the macOS order, not a choice.
    static var saved: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = list.first else { return .system }
        return AppLanguage(rawValue: first) ?? .system
    }

    /// What this run of the app was started with.
    static let atLaunch = saved

    static func save(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    /// Quits, then opens the app again once this process is gone, so the two never run at once
    /// (they would share the cache and history).
    @MainActor static func relaunch() {
        let wait = Process()
        wait.executableURL = URL(fileURLWithPath: "/bin/sh")
        wait.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                          "relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try wait.run()
        } catch {
            NSLog("Hoard 無法重新開啟：%@", String(describing: error))
            return
        }
        NSApp.terminate(nil)
    }
}
