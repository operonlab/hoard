import Foundation
import ScanCore

enum DoctorCommand {
    static func timeoutFields() -> [String: Any] {
        let probes = [("materialization", "iCloud 自動下載", "不下載保證"),
                      ("firmlink", "Users 路徑連結", "保護比對、路徑換算"),
                      ("bulk-read", "批次目錄讀取", "掃描"),
                      ("fsevents", "檔案系統事件", "自動更新、守護"),
                      ("deny-delete-acl", "禁止刪除 ACL", "鎖定"),
                      ("clonefile", "APFS 檔案複製", "守護的備份"),
                      ("library-layout", "Library 資料夾", "App 佔用、解除安裝、已移除 App 的資料"),
                      ("process-list", "執行中程序", "解除安裝"),
                      ("homebrew-receipt", "Homebrew 安裝收據", "解除安裝的 Homebrew 判斷")]
        let checks: [[String: Any]] = probes.map { id, title, affects in
            ["id": id, "title": title, "status": "unknown", "detail": "30 秒期限已到，檢查未完成", "affects": affects]
        }
        return ["schema": "hoard/1", "command": "doctor",
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "verified_on": "macOS 27",
                "untested": ProcessInfo.processInfo.operatingSystemVersion.majorVersion != 27,
                "checks": checks, "summary": ["ok": 0, "unknown": 9, "problem": 0]]
    }

    static func run() -> (fields: [String: Any], human: String, exitCode: Int32) {
        let report = Doctor.run()
        let checks: [[String: Any]] = report.checks.map {
            ["id": $0.id, "title": $0.title, "status": $0.status.rawValue,
             "detail": $0.detail, "affects": $0.affects]
        }
        let fields: [String: Any] = ["schema": "hoard/1", "command": "doctor",
                                     "os_version": report.osVersion, "verified_on": report.verifiedOn,
                                     "untested": report.untested, "checks": checks,
                                     "summary": ["ok": report.ok, "unknown": report.unknown, "problem": report.problem]]
        let lines = report.checks.map { check in
            let symbol = switch check.status { case .ok: "✓"; case .unknown: "?"; case .problem: "✗" }
            return "\(symbol) \(check.title)：\(check.detail)"
        }
        let version = "macOS \(report.osVersion)" + (report.untested ? "：尚未在這個版本驗證過" : "")
        return (fields, (lines + [version]).joined(separator: "\n"),
                report.problem > 0 ? 1 : (report.unknown > 0 ? 3 : 0))
    }
}
