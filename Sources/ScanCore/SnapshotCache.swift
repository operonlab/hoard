import Darwin
import Foundation

public enum SnapshotCache {
    public enum Reason: String, Sendable { case rootGone = "root_gone", unused, unreadable, abandonedWrite = "abandoned_write" }

    public struct Removal: Equatable, Sendable {
        public var file: URL
        public var rootPath: String?
        public var reason: Reason
        public var bytesFreed: Int64
    }

    /// Removes cached scans in `directory` that will not be used again.
    public static func evict(in directory: URL, keep: Set<String>, now: Date,
                             maxAge: TimeInterval = 30 * 86_400,
                             isGone: (String) -> Bool = SnapshotCache.rootIsGone) -> [Removal] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var removed: [Removal] = []
        // A snapshot is written to `.<name>.dscan.<uuid>[.raw].tmp` and renamed into place; one left a day
        // later belongs to a save that never finished (the app quit or crashed), and nothing reads it.
        for file in files where file.lastPathComponent.hasPrefix(".") && file.lastPathComponent.contains(".dscan.")
            && file.pathExtension == "tmp" {
            guard let modified = try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
                  modified < now.addingTimeInterval(-86_400) else { continue }
            let bytes = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            do {
                try fm.removeItem(at: file)
                removed.append(Removal(file: file, rootPath: nil, reason: .abandonedWrite, bytesFreed: bytes))
            } catch {
                NSLog("Hoard 快取移除失敗 %@: %@", file.path, String(describing: error))
            }
        }
        for file in files where file.pathExtension == "dscan" {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let root = rootPath(of: file)
            let reason: Reason
            if let root {
                if keep.contains(root) { continue }
                if isGone(root) {
                    reason = .rootGone
                } else {
                    guard let modified = try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
                          modified < now.addingTimeInterval(-maxAge) else { continue }
                    reason = .unused
                }
            } else {
                reason = .unreadable
            }
            let bytes = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            do {
                try fm.removeItem(at: file)
                removed.append(Removal(file: file, rootPath: root, reason: reason, bytesFreed: bytes))
            } catch {
                NSLog("Hoard 快取移除失敗 %@: %@", file.path, String(describing: error))
            }
        }
        return removed
    }

    public static func rootIsGone(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if components.count >= 3 && components[1] == "Volumes" {
            let volume = URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2]).path
            let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
            if !mounted.contains(where: { $0.standardizedFileURL.path == volume }) { return false }
        }
        var info = stat()
        if lstat(path, &info) == 0 { return false }
        return errno == ENOENT || errno == ENOTDIR
    }

    static func rootPath(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12,
              header.prefix(4).elementsEqual([0x44, 0x53, 0x43, 0x4e]) else { return nil }
        let length = (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[8 + $1]) << (8 * $1) }
        guard length <= 1_048_576,
              let json = try? handle.read(upToCount: Int(length)), json.count == Int(length) else { return nil }
        struct Root: Decodable { let rootPath: String }
        return try? JSONDecoder().decode(Root.self, from: json).rootPath
    }
}
