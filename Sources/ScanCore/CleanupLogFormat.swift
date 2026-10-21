import Foundation

/// One line of the app's cleanup log (JSON Lines): an item moved to the Trash, or, with `restored`,
/// the same path put back by ⌘Z.
public struct CleanupLogEntry: Codable, Sendable, Identifiable, Equatable {
    public let date: Date
    public let path: String
    public let bytes: Int64
    public let source: String
    public let partial: Bool
    public var restored: Bool?
    public var id: String { "\(date.timeIntervalSince1970):\(path)" }

    public init(date: Date, path: String, bytes: Int64, source: String, partial: Bool, restored: Bool? = nil) {
        self.date = date; self.path = path; self.bytes = bytes; self.source = source
        self.partial = partial; self.restored = restored
    }
}

public enum CleanupLogFormat {
    /// The newest `limit` items still trashed, newest first. Lines are matched in file order, not by
    /// date (dates are whole seconds): a restore line takes back the latest earlier trash of its path,
    /// so an older trash of the same path that is still in the Trash stays listed. Lines that do not
    /// decode are skipped.
    public static func recent(_ data: Data, limit: Int = 20) -> [CleanupLogEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var listed: [CleanupLogEntry] = []
        for line in data.split(separator: 0x0a) {
            guard let entry = try? decoder.decode(CleanupLogEntry.self, from: Data(line)) else { continue }
            if entry.restored == true {
                if let i = listed.lastIndex(where: { $0.path == entry.path }) { listed.remove(at: i) }
            } else {
                listed.append(entry)
            }
        }
        return Array(listed.suffix(limit).reversed())
    }

    /// The last `keep` lines of a log, newline-terminated.
    public static func trimmed(_ data: Data, keep: Int) -> Data {
        let lines = data.split(separator: 0x0a).suffix(keep)
        return lines.isEmpty ? Data() : Data(lines.joined(separator: [0x0a])) + Data([0x0a])
    }

    public static func encode(_ entries: [CleanupLogEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for entry in entries { data += try encoder.encode(entry) + Data([0x0a]) }
        return data
    }
}
