import AppKit
import ScanCore
import SwiftUI

struct WhatsNewItem {
    let symbol: String
    let title: String
    let body: String
}

struct WhatsNewRelease: Identifiable {
    let version: String
    let items: [WhatsNewItem]
    var id: String { version }
}

enum WhatsNew {
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(version: "0.6.3", items: [
            WhatsNewItem(symbol: "trash", title: String(localized: "App Store 的 App 也能解除安裝"),
                         body: String(localized: "這類 App 屬於系統管理員，以前按下確認後才會失敗。現在解除安裝單會先說明，確認後請 Finder 把它丟到垃圾桶（可能要允許 Hoard 控制 Finder，並輸入管理員密碼）；它的資料仍由 Hoard 處理。要放回，請在垃圾桶裡用「放回原處」。")),
        ]),
        WhatsNewRelease(version: "0.6.2", items: [
            WhatsNewItem(symbol: "questionmark.folder", title: String(localized: "讀不到的資料夾會說原因"),
                         body: String(localized: "檢閱器和「看不到的空間」的新清單會逐個說明讀不到的原因：需要完整磁碟取用權限、macOS 保護、檔案權限、只在 iCloud、已不存在或讀取錯誤；有辦法解決的會附上按鈕。")),
            WhatsNewItem(symbol: "tablecells", title: String(localized: "匯出成 CSV"),
                         body: String(localized: "「檔案 › 匯出為 CSV…」（⌘⇧E）把畫面上的清單存成試算表能開的檔案。查不到的大小會留空，不會寫成 0。")),
            WhatsNewItem(symbol: "folder", title: String(localized: "用 Hoard 打開"),
                         body: String(localized: "新增「用 Hoard 打開」服務，也可以把資料夾拖到 Dock 上的 Hoard 圖示來打開。")),
            WhatsNewItem(symbol: "trash", title: String(localized: "把 App 拖進來解除安裝"),
                         body: String(localized: "把 App 拖到 Hoard 的視窗，會列出它和它的資料，確認後才丟到垃圾桶。")),
            WhatsNewItem(symbol: "archivebox", title: String(localized: "掃描快取變小了"),
                         body: String(localized: "存下來的掃描結果改成壓縮，整顆磁碟的快取從約 560 MB 變成約 115 MB；已經不在或 30 天沒用的位置，快取會自動清掉。")),
        ]),
        WhatsNewRelease(version: "0.6.1", items: [
            WhatsNewItem(symbol: "checklist", title: String(localized: "一次清掉很多項"),
                         body: String(localized: "「可以清掉的」裡的建議、重複檔和相似的照片都能勾選，建議還能整類全選，或按「全部丟到垃圾桶…」。丟之前一樣先列出來讓你確認，受保護的會略過，⌘Z 可以整批放回。")),
            WhatsNewItem(symbol: "doc.on.doc", title: String(localized: "重複檔只留一份"),
                         body: String(localized: "每組按「只留一份」，或按「每組只留一份…」一次處理全部，一組永遠至少留一份。最小檔案多了 1 MB 和 10 MB，小一點的重複檔也找得到。")),
            WhatsNewItem(symbol: "internaldrive", title: String(localized: "「系統資料」是什麼"),
                         body: String(localized: "新的說明頁逐項解釋「看不到的空間」每一行，以及為什麼和系統設定的數字不一樣。從「說明」選單打開。")),
            WhatsNewItem(symbol: "arrow.down.circle", title: String(localized: "檢查更新"),
                         body: String(localized: "「Hoard › 檢查更新…」會打開版本頁；命令列工具若是用 Homebrew 裝的，可以一鍵在終端機更新。Hoard 本身照樣不連網。")),
            WhatsNewItem(symbol: "wrench.and.screwdriver", title: String(localized: "修正"),
                         body: String(localized: "「最近變動」的變大、變小不再重複計算；確認單不再把每個檔案都說成和其他檔案共用空間；一次丟很多項時，每個沒丟成的都會列出來。")),
        ]),
    ]
    static let seenKey = "whatsNewSeenVersion"
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Records the running version as seen, but never lowers it: after running an older build, the
    /// newer build's notes would otherwise show again.
    static func recordSeen() {
        let defaults = UserDefaults.standard
        if let seen = defaults.string(forKey: seenKey),
           WhatsNewPolicy.compare(seen, currentVersion) == .orderedDescending { return }
        defaults.set(currentVersion, forKey: seenKey)
    }
}

struct WhatsNewSheet: View {
    let releases: [WhatsNewRelease]
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let newest = releases.first {
                Text(String(localized: "Hoard \(newest.version) 的新功能"))
                    .font(.title2.weight(.semibold))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(releases.enumerated()), id: \.element.id) { index, release in
                        if index > 0 {
                            Text(String(localized: "\(release.version) 的新功能"))
                                .font(.subheadline.weight(.semibold))
                        }
                        ForEach(release.items.indices, id: \.self) { itemIndex in
                            let item = release.items[itemIndex]
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.symbol)
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.headline)
                                    Text(item.body).font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Button("完整更新紀錄") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/operonlab/hoard/blob/main/CHANGELOG.md")!)
                }
                Spacer()
                Button("好") { model.closeWhatsNew() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
