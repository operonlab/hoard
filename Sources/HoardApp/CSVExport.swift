import AppKit
import Foundation
import ScanCore
import UniformTypeIdentifiers

extension FileCategory {
    /// Follows the titles, but in English whatever the UI language, for scripts reading the export.
    var csvName: String {
        switch self {
        case .video: "video"
        case .image: "image"
        case .audio: "audio"
        case .document: "document"
        case .code: "code_or_development"
        case .archive: "archive_or_disk_image"
        case .app: "app_or_library"
        case .model: "model_or_data"
        case .design: "design_or_3d"
        case .other: "other"
        }
    }
}

extension AppModel {
    private func csvSize(_ bytes: Int64?, _ status: ScanStatus) -> (CSVValue, CSVValue) {
        let label: String
        switch status {
        case .complete: label = "exact"
        case .partial: label = "at_least"
        case .unavailable: label = "unknown"
        }
        return (status == .unavailable ? .empty : bytes.map(CSVValue.integer) ?? .empty, .text(label))
    }

    private func csvDate(_ date: Date?) -> CSVValue {
        guard let date else { return .empty }
        return TreeExport.timestamp(Int64(date.timeIntervalSince1970))
    }

    var canExportCSV: Bool {
        // Same test as the content area: a search of only spaces still shows the view.
        guard tree != nil, searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch view {
        case .map: return true
        case .largest: return !largestPending
        case .stale: return !stalePending && staleResult != nil
        case .types: return !statsPending && tree?[scope].status != .unavailable
        case .changes:
            if case .report = changes { return !changesPending }
            return false
        case .apps: return !appPending && appReport != nil
        case .cleanup, .protected: return false
        }
    }

    private var csvViewName: String {
        switch view {
        case .map: "folder"
        case .largest: "largest"
        case .stale: "stale"
        case .types: "types"
        case .changes: "changes"
        case .apps: "apps"
        case .cleanup, .protected: "folder"
        }
    }

    func csvTable() -> CSVTable? {
        guard canExportCSV, let tree else { return nil }
        switch view {
        case .map:
            return TreeExport.children(of: scope, in: tree)
        case .largest, .stale:
            let stale = view == .stale
            let files = stale ? visibleStaleRows : visibleLargestRows
            let header = stale
                ? ["name", "path", "kind", "size_bytes", "size_status", "modified", "last_used"]
                : ["name", "path", "kind", "category", "size_bytes", "size_status", "modified"]
            let rows = files.map { row -> [CSVValue] in
                let size = csvSize(row.bytes, row.status)
                let prefix: [CSVValue] = [.text(row.name), .text((row.parentPath as NSString).appendingPathComponent(row.name)),
                                          .text(row.isDirectory ? "folder" : "file")]
                if stale {
                    return prefix + [size.0, size.1, TreeExport.timestamp(row.modTime), TreeExport.timestamp(row.lastUsed)]
                }
                return prefix + [.text(row.isDirectory ? "folder" : row.category.csvName), size.0, size.1,
                                 TreeExport.timestamp(row.modTime)]
            }
            return CSVTable(header: header, rows: rows)
        case .types:
            let status = tree[scope].status
            let rows = visibleTypeGroups.map { group -> [CSVValue] in
                let size = csvSize(group.bytes, status)
                return [.text(group.category.csvName), size.0, size.1, .integer(group.count)]
            }
            return CSVTable(header: ["category", "size_bytes", "size_status", "files"], rows: rows)
        case .changes:
            guard case .report(let report, _) = changes else { return nil }
            let rows = changeRows(report).filter { changeMatches($0) }.map { row -> [CSVValue] in
                let kind: String
                switch row.kind {
                case .grown: kind = "grown"
                case .shrunk: kind = "shrunk"
                case .added: kind = "added"
                case .removed: kind = "removed"
                }
                return [.text(row.name), .text(row.id), .text(kind),
                        row.kind == .added ? .empty : .integer(row.before),
                        row.kind == .removed ? .empty : .integer(row.after),
                        // Uncertain: a side was not fully readable, so both sizes are lower bounds.
                        row.uncertain ? .empty : .integer(row.delta), .text(row.uncertain ? "at_least" : "exact")]
            }
            return CSVTable(header: ["name", "path", "change", "before_bytes", "after_bytes", "delta_bytes", "size_status"], rows: rows)
        case .apps:
            let rows = visibleApps.map { app -> [CSVValue] in
                let size = csvSize(app.appSize.bytes, app.appSize.status)
                let data = csvSize(app.data.bytes, app.data.status)
                return [.text(app.name), .text(app.appPath), app.bundleID.map(CSVValue.text) ?? .empty,
                        .bool(app.isApple), size.0, size.1, data.0, data.1, csvDate(app.lastUsed)]
            }
            return CSVTable(header: ["name", "path", "bundle_id", "apple", "app_bytes", "app_status",
                                     "data_bytes", "data_status", "last_used"], rows: rows)
        case .cleanup, .protected: return nil
        }
    }

    func exportCSV() {
        guard let table = csvTable() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let safeScope = scopeName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Hoard-\(csvViewName)-\(safeScope)-\(formatter.string(from: Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try table.encoded().write(to: url, options: .atomic)
        } catch {
            alert = AppAlert(title: String(localized: "無法匯出"), message: error.localizedDescription)
        }
    }
}
