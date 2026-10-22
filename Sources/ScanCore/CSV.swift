import Foundation

public enum CSVValue: Equatable, Sendable {
    case text(String), integer(Int64), bool(Bool), empty
}

public struct CSVTable: Equatable, Sendable {
    public var header: [String]
    public var rows: [[CSVValue]]

    public init(header: [String], rows: [[CSVValue]]) {
        self.header = header
        self.rows = rows
    }

    public func encoded() -> Data {
        func field(_ value: CSVValue) -> String {
            switch value {
            case .integer(let number): return String(number)
            case .bool(let value): return value ? "true" : "false"
            case .empty: return ""
            case .text(let original):
                // By scalar, not Character: "=" followed by a combining mark is one Character but still a formula.
                let lead = original.unicodeScalars.first.map { "=+-@\t\r".unicodeScalars.contains($0) } == true
                let guarded = lead ? "'" + original : original
                if guarded.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) {
                    return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return guarded
            }
        }
        let lines = [header.map(CSVValue.text)] + rows
        return Data([0xEF, 0xBB, 0xBF]) + Data((lines.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

public enum TreeExport {
    public static func timestamp(_ seconds: Int64, timeZone: TimeZone = .current) -> CSVValue {
        guard seconds != 0 else { return .empty }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return .text(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds))))
    }

    public static func children(of node: NodeID, in tree: FileTree, timeZone: TimeZone = .current) -> CSVTable {
        let rows = tree.sortedChildren(of: node).map { id -> [CSVValue] in
            let item = tree[id]
            let status: String
            switch item.status {
            case .complete: status = "exact"
            case .partial: status = "at_least"
            case .unavailable: status = "unknown"
            }
            return [.text(item.name), .text(tree.path(of: id)), .text(item.isDirectory ? "folder" : "file"),
                    item.status == .unavailable ? .empty : .integer(item.totalAlloc), .text(status),
                    item.isDirectory && item.status != .unavailable ? .integer(item.fileCount) : .empty,
                    item.isDirectory && item.status != .unavailable ? .integer(item.dirCount - 1) : .empty,
                    timestamp(item.modTime, timeZone: timeZone)]
        }
        return CSVTable(header: ["name", "path", "kind", "size_bytes", "size_status", "files", "folders", "modified"], rows: rows)
    }
}
