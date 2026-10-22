import AppKit
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
