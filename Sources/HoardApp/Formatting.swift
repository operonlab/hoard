import Foundation
import ScanCore

/// Every number and date the UI shows goes through here, so the three-state size rule (§7.1) and the
/// localized wording live in one place.
enum Fmt {
    static let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hant")

    static func bytes(_ count: Int64) -> String {
        max(0, count).formatted(.byteCount(style: .file).locale(locale))
    }

    /// Signed change, with U+2212 for negative values (§6.3).
    static func delta(_ count: Int64) -> String {
        count >= 0 ? "+\(bytes(count))" : "\u{2212}\(bytes(-count))"
    }

    /// Table / list form: "4.79 GB", "≥ 4.79 GB", "無法讀取".
    static func size(_ node: Node) -> String {
        switch node.status {
        case .complete: return bytes(node.totalAlloc)
        case .partial: return "≥ \(bytes(node.totalAlloc))"
        case .unavailable: return String(localized: "無法讀取")
        }
    }

    /// Sentence / inspector form: "4.79 GB", "至少 4.79 GB", "無法讀取".
    static func sizeLong(_ node: Node) -> String {
        switch node.status {
        case .complete: return bytes(node.totalAlloc)
        case .partial: return String(localized: "至少 \(bytes(node.totalAlloc))")
        case .unavailable: return String(localized: "無法讀取")
        }
    }

    static func sizeSpoken(_ node: Node) -> String {
        switch node.status {
        case .complete: return bytes(node.totalAlloc)
        case .partial: return String(localized: "至少 \(bytes(node.totalAlloc))，部分內容無法讀取")
        case .unavailable: return String(localized: "大小未知，沒有權限讀取")
        }
    }

    /// Share of `node` in `whole`: "37.8%", "≥ 37.8%" when either is a lower bound, "—" when unknown.
    static func share(_ node: Node, of whole: Node) -> String {
        guard let ratio = ratio(node, of: whole) else { return "—" }
        let text = percent(ratio)
        return node.status == .complete && whole.status == .complete ? text : "≥ \(text)"
    }

    static func ratio(_ node: Node, of whole: Node) -> Double? {
        guard node.status != .unavailable, whole.status != .unavailable else { return nil }
        guard whole.totalAlloc > 0 else { return 0 }
        return min(1, Double(node.totalAlloc) / Double(whole.totalAlloc))
    }

    static func percent(_ ratio: Double) -> String {
        if ratio > 0 && ratio < 0.01 { return "<1%" }
        return (ratio * 100).formatted(.number.precision(.fractionLength(1)).locale(locale)) + "%"
    }

    static func count(_ n: Int64) -> String { n.formatted(.number.locale(locale)) }
    static func count(_ n: Int) -> String { n.formatted(.number.locale(locale)) }

    static func date(seconds: Int64) -> Date? {
        seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
    }

    /// Table form (§5.3): "今天", "昨天", "3 年前".
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        if calendar.isDateInToday(date) { return String(localized: "今天") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
        return date.formatted(Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .wide,
                                                       locale: locale, calendar: calendar))
    }

    /// Long date: "2024年3月2日".
    static func longDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale))
    }

    /// Inspector / hover form: "2 年前（2024年3月2日）".
    static func relativeAndLong(_ date: Date?) -> String {
        guard let date else { return "—" }
        return String(localized: "\(relative(date))（\(longDate(date))）")
    }

    /// "10月18日 下午3:42".
    static func dayAndTime(_ date: Date) -> String {
        let day = date.formatted(Date.FormatStyle(locale: locale).month(.defaultDigits).day())
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
        return String(localized: "\(day) \(time)")
    }

    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).month(.defaultDigits).day())
    }

    /// "已經過 12 秒" / "已經過 2 分 5 秒" (§11.3).
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s < 60 ? String(localized: "已經過 \(s) 秒") : String(localized: "已經過 \(s / 60) 分 \(s % 60) 秒")
    }

    /// Window title: at most 15 characters, middle-truncated (§1.2).
    static func title(_ name: String) -> String {
        guard name.count > 15 else { return name }
        return "\(name.prefix(7))…\(name.suffix(7))"
    }

    /// Absolute path with the home directory written as "~".
    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        for base in [home, "/System/Volumes/Data" + home] {
            if path == base { return "~" }
            if path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
        }
        return path
    }
}
