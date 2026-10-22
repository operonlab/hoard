import AppKit
import SwiftUI

enum UpdateCheck {
    static let releasesURL = URL(string: "https://github.com/operonlab/hoard/releases")!
    static let formula = "operonlab/tap/hoard"

    /// The hoard command-line tool came from Homebrew: its keg exists.
    static var cliFromHomebrew: Bool {
        ["/opt/homebrew/Cellar/hoard", "/usr/local/Cellar/hoard"].contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    /// A login shell finds Homebrew on PATH wherever it was installed.
    static let script = """
    #!/bin/zsh -l
    # Written by Hoard: updates the hoard command-line tool with Homebrew.
    if ! command -v brew >/dev/null 2>&1; then
      echo "Homebrew was not found: https://brew.sh"
      exit 1
    fi
    brew upgrade operonlab/tap/hoard
    """

    /// `failed` runs on the main queue when the script cannot be written or Terminal cannot open it.
    static func runInTerminal(failed: @escaping @MainActor (Error) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoard-update.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            Task { @MainActor in failed(error) }
            return
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in failed(error) } }
        }
    }
}

struct UpdateSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("檢查更新")
                .font(.title2.weight(.semibold))
            Text(String(localized: "目前版本：Hoard \(WhatsNew.currentVersion)"))
            Text("Hoard 不會自己連網，所以不會自動檢查。打開版本頁，看看有沒有比目前更新的版本。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("打開版本頁") { NSWorkspace.shared.open(UpdateCheck.releasesURL) }
            Divider()
            if UpdateCheck.cliFromHomebrew {
                Text("命令列工具是用 Homebrew 安裝的。")
                Button("在終端機更新命令列工具") {
                    // The sheet closes first: an alert set while a sheet is up is not shown.
                    model.updateCheckShown = false
                    UpdateCheck.runInTerminal { error in
                        model.alert = AppAlert(title: String(localized: "無法打開終端機"),
                                               message: error.localizedDescription)
                    }
                }
                .help("打開「終端機」執行 brew upgrade operonlab/tap/hoard")
            } else {
                Text("命令列工具可以用 Homebrew 安裝：")
                Text(verbatim: "brew install operonlab/tap/hoard")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            Text("App 要到版本頁下載新的 Hoard 壓縮檔，換掉「應用程式」裡的 Hoard.app。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("完成") { model.updateCheckShown = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
