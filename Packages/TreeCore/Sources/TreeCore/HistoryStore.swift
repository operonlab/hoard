// File handling behind SnapshotHistory: ids, paths, atomic writes, header-only listing.

import Foundation

extension SnapshotHistory {
    static let fileExtension = "dshist"

    /// Application Support/Hoard/History/<16-hex FNV-1a of rootPath>
    static func defaultDirectory(forRoot root: String) -> URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return support.appendingPathComponent(HoardStorage.folderName, isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent(rootHash(root), isDirectory: true)
    }

    static func rootHash(_ root: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in root.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// "20261020T040512Z" for the UTC second of `date`.
    static func timestampID(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?, _ width: Int) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return pad(c.year, 4) + pad(c.month, 2) + pad(c.day, 2) + "T" + pad(c.hour, 2) + pad(c.minute, 2)
            + pad(c.second, 2) + "Z"
    }

    /// Newest first: by date, then by same-second suffix (-10 after -9), then by id.
    static func newestFirst(_ a: HistoryVersion, _ b: HistoryVersion) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        let (ab, an) = splitID(a.id), (bb, bn) = splitID(b.id)
        if ab != bb { return ab > bb }
        if an != bn { return an > bn }
        return a.id > b.id
    }

    private static func splitID(_ id: String) -> (String, Int) {
        guard let dash = id.lastIndex(of: "-"), let n = Int(id[id.index(after: dash)...]) else { return (id, 1) }
        return (String(id[..<dash]), n)
    }

    func url(for id: String) -> URL {
        directory.appendingPathComponent(id + "." + Self.fileExtension)
    }

    func fileURL(forExisting id: String) throws -> URL {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { throw HistoryError.notFound(id: id) }
        let u = url(for: id)
        guard FileManager.default.fileExists(atPath: u.path) else { throw HistoryError.notFound(id: id) }
        return u
    }

    func versionFiles() throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == Self.fileExtension && !$0.lastPathComponent.hasPrefix(".") }
    }

    /// Reads the fixed prefix and the JSON header only, never the payload.
    func readHeader(of url: URL) -> HistoryVersion? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: HistoryFormat.prefixSize), prefix.count == HistoryFormat.prefixSize,
              let length = try? HistoryFormat.headerLength(prefix: prefix),
              let json = try? handle.read(upToCount: length), json.count == length,
              let header = try? HistoryFormat.decodeHeader(json),
              header.id + "." + Self.fileExtension == url.lastPathComponent else { return nil }
        return header
    }

    /// Writes `summary` as a new version with a unique id. Atomic and exclusive: the complete temp file is
    /// published with link(2), which never replaces an existing name, so two writers in the same second
    /// (two processes) cannot take the same id; the loser re-encodes under the next suffix.
    // ponytail: link(2) needs hard links (APFS, HFS+, ext4); add an O_EXCL reservation if history ever lives on exFAT.
    func write(_ summary: TreeSummary) throws -> HistoryVersion {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = Self.timestampID(summary.createdAt)
        var n = 1
        var id: String { n == 1 ? base : "\(base)-\(n)" }
        while fm.fileExists(atPath: url(for: id).path) { n += 1 }

        let root = summary.dirs.first
        let payload = try HistoryFormat.encodePayload(summary)
        let (flags, body) = HistoryFormat.pack(payload)
        let temp = directory.appendingPathComponent(".\(base).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temp) }
        while true {
            var version = HistoryVersion(id: id, rootPath: summary.rootPath, createdAt: summary.createdAt,
                                         totalAlloc: root?.totalAlloc ?? 0, fileCount: root?.fileCount ?? 0,
                                         dirCount: Int64(summary.dirs.count), status: root?.status ?? .complete,
                                         storedBytes: 0)
            // storedBytes describes the file it lives in; its own digits change the length, so iterate to a fixed point.
            var file = Data()
            for _ in 0..<4 {
                let header = try JSONEncoder().encode(version)
                file = HistoryFormat.file(header: header, flags: flags, body: body)
                if version.storedBytes == Int64(file.count) { break }
                version.storedBytes = Int64(file.count)
            }
            try file.write(to: temp)
            if link(temp.path, url(for: version.id).path) == 0 { return version }
            guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown) }
            n += 1
        }
    }
}
