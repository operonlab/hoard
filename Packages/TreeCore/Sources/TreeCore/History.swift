// CONTRACT (FROZEN signatures): version history and diff.
// Owner of the bodies: P2-2 (cloud lane). Placeholders throw / return empty until then.
//
// Why a separate format: a full snapshot of the whole data volume is 483 MB (3.88M nodes, measured
// 2026-10-20), too big to keep many of. A history version keeps only directories (493k) plus files
// at or above `bigFileThreshold`, which is what "what grew since last time" needs.

import Foundation

/// One saved version of a root, newest first in listings.
public struct HistoryVersion: Codable, Sendable, Equatable {
    /// Sortable UTC timestamp, e.g. "20261020T040512Z". Unique per root.
    public var id: String
    public var rootPath: String
    public var createdAt: Date
    public var totalAlloc: Int64
    public var fileCount: Int64
    public var dirCount: Int64
    public var status: ScanStatus
    /// Size of the stored version file on disk.
    public var storedBytes: Int64

    public init(id: String, rootPath: String, createdAt: Date, totalAlloc: Int64, fileCount: Int64,
                dirCount: Int64, status: ScanStatus, storedBytes: Int64) {
        self.id = id; self.rootPath = rootPath; self.createdAt = createdAt; self.totalAlloc = totalAlloc
        self.fileCount = fileCount; self.dirCount = dirCount; self.status = status; self.storedBytes = storedBytes
    }
}

/// Directory-level picture of a tree at one moment, plus every file at or above the threshold.
public struct TreeSummary: Sendable, Equatable {
    public struct Dir: Sendable, Equatable {
        public var parent: Int32        // -1 for the root; parents come before children
        public var name: String
        public var totalAlloc: Int64
        public var fileCount: Int64
        public var status: ScanStatus
        public init(parent: Int32, name: String, totalAlloc: Int64, fileCount: Int64, status: ScanStatus) {
            self.parent = parent; self.name = name; self.totalAlloc = totalAlloc
            self.fileCount = fileCount; self.status = status
        }
    }

    public struct BigFile: Sendable, Equatable {
        public var dir: Int32           // index into `dirs`
        public var name: String
        public var alloc: Int64         // counted (deduped) bytes
        public var modTime: Int64
        public var accessTime: Int64
        public init(dir: Int32, name: String, alloc: Int64, modTime: Int64, accessTime: Int64) {
            self.dir = dir; self.name = name; self.alloc = alloc; self.modTime = modTime; self.accessTime = accessTime
        }
    }

    public static let defaultBigFileThreshold: Int64 = 10 * 1_048_576

    public var rootPath: String
    public var createdAt: Date
    public var bigFileThreshold: Int64
    public var dirs: [Dir]
    public var bigFiles: [BigFile]

    public init(rootPath: String, createdAt: Date, bigFileThreshold: Int64, dirs: [Dir], bigFiles: [BigFile]) {
        self.rootPath = rootPath; self.createdAt = createdAt; self.bigFileThreshold = bigFileThreshold
        self.dirs = dirs; self.bigFiles = bigFiles
    }

    /// Builds the summary of a live tree (skips removed nodes). O(n).
    public init(tree: FileTree, createdAt: Date, bigFileThreshold: Int64 = TreeSummary.defaultBigFileThreshold) {
        let nodes = tree.nodes
        // Node ids grow from parent to child, so a forward sweep emits parents first.
        var dirIndex = [Int32](repeating: -1, count: nodes.count)
        var dirs: [Dir] = []
        var bigFiles: [BigFile] = []
        for i in nodes.indices {
            let n = nodes[i]
            if n.isRemoved { continue }
            let parent: Int32 = i == 0 ? -1 : dirIndex[Int(n.parent)]
            if i != 0 && parent < 0 { continue }   // parent not a live dir (should not happen)
            if n.isDirectory {
                dirIndex[i] = Int32(dirs.count)
                dirs.append(Dir(parent: parent, name: i == 0 ? tree.rootPath : n.name, totalAlloc: n.totalAlloc,
                                fileCount: n.fileCount, status: n.status))
            } else if n.ownAlloc >= bigFileThreshold {
                bigFiles.append(BigFile(dir: parent, name: n.name, alloc: n.ownAlloc, modTime: n.modTime,
                                        accessTime: n.accessTime))
            }
        }
        self.init(rootPath: tree.rootPath, createdAt: createdAt, bigFileThreshold: bigFileThreshold,
                  dirs: dirs, bigFiles: bigFiles)
    }

    /// Absolute path of `dirs[index]`.
    public func path(ofDir index: Int32) -> String {
        if index <= 0 { return rootPath }
        var parts: [String] = []
        var cur = index
        while cur > 0 && Int(cur) < dirs.count {
            parts.append(dirs[Int(cur)].name)
            cur = dirs[Int(cur)].parent
        }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return base + "/" + parts.reversed().joined(separator: "/")
    }
}

public struct HistoryRetention: Sendable, Equatable {
    public var maxVersions: Int
    public var maxAge: TimeInterval
    public init(maxVersions: Int = 30, maxAge: TimeInterval = 90 * 86_400) {
        self.maxVersions = maxVersions; self.maxAge = maxAge
    }
}

public enum HistoryError: Error, Equatable {
    case notImplemented
    case notFound(id: String)
    case corrupt(id: String)
}

/// Versions of one root, stored under `directory` (default: Application Support/Hoard/History/<root hash>).
public final class SnapshotHistory {
    public let rootPath: String
    public let directory: URL
    public let retention: HistoryRetention

    public init(rootPath: String, directory: URL? = nil, retention: HistoryRetention = HistoryRetention()) {
        self.rootPath = rootPath
        self.retention = retention
        self.directory = directory ?? SnapshotHistory.defaultDirectory(forRoot: rootPath)
    }

    /// Saves a version of `tree` and applies retention. Returns what was saved.
    @discardableResult
    public func record(_ tree: FileTree, at date: Date = Date()) throws -> HistoryVersion {
        let summary = TreeSummary(tree: tree, createdAt: date)
        let saved = try write(summary)
        try prune(now: date)
        return saved
    }

    /// All saved versions, newest first. Reads only the JSON headers; unreadable files are skipped.
    public func versions() throws -> [HistoryVersion] {
        try versionFiles().compactMap { readHeader(of: $0) }.sorted(by: Self.newestFirst)
    }

    public func load(_ id: String) throws -> TreeSummary {
        let url = try fileURL(forExisting: id)
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw HistoryError.notFound(id: id) }
        do { return try HistoryFormat.decode(data).1 } catch { throw HistoryError.corrupt(id: id) }
    }

    /// Deletes versions beyond retention. Returns the removed ids.
    @discardableResult
    public func prune(now: Date = Date()) throws -> [String] {
        let all = try versions()
        var removed: [String] = []
        // all[0] is the newest and is never deleted.
        for (rank, v) in all.enumerated() where rank > 0 {
            if rank >= retention.maxVersions || now.timeIntervalSince(v.createdAt) > retention.maxAge {
                try FileManager.default.removeItem(at: url(for: v.id))
                removed.append(v.id)
            }
        }
        return removed
    }
}

public struct DirChange: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case added, removed, changed }
    public var path: String
    public var kind: Kind
    public var before: Int64
    public var after: Int64
    public var filesBefore: Int64
    public var filesAfter: Int64
    /// Either side was not fully readable (partial / unavailable): the delta may be a permission
    /// change rather than real growth or freed space. Show it as uncertain, never as reclaimed.
    public var uncertain: Bool
    public var delta: Int64 { after - before }
    public init(path: String, kind: Kind, before: Int64, after: Int64, filesBefore: Int64, filesAfter: Int64,
                uncertain: Bool = false) {
        self.path = path; self.kind = kind; self.before = before; self.after = after
        self.filesBefore = filesBefore; self.filesAfter = filesAfter; self.uncertain = uncertain
    }
}

public struct FileChange: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case added, removed, grown, shrunk }
    public var path: String
    public var kind: Kind
    public var before: Int64      // 0 when added
    public var after: Int64       // 0 when removed
    public var delta: Int64 { after - before }
    public init(path: String, kind: Kind, before: Int64, after: Int64) {
        self.path = path; self.kind = kind; self.before = before; self.after = after
    }
}

public struct DiffReport: Codable, Sendable, Equatable {
    public var rootPath: String
    public var fromDate: Date
    public var toDate: Date
    public var totalBefore: Int64
    public var totalAfter: Int64
    /// Scan completeness for the whole root, independent of the report's filtered rows.
    public var rootStatusBefore: ScanStatus = .complete
    public var rootStatusAfter: ScanStatus = .complete
    public var totalDelta: Int64 { totalAfter - totalBefore }
    /// Largest growth first. Each entry is a "hotspot": its change is not explained by a single child
    /// (a 1 GB file added deep down is reported once, at the folder that holds it, not at every ancestor).
    public var grown: [DirChange]
    /// Largest shrink first, same hotspot rule.
    public var shrunk: [DirChange]
    /// Big files (>= threshold in either version) that appeared, vanished or changed size, largest |delta| first.
    public var files: [FileChange]
    public init(rootPath: String, fromDate: Date, toDate: Date, totalBefore: Int64, totalAfter: Int64,
                grown: [DirChange], shrunk: [DirChange], files: [FileChange]) {
        self.rootPath = rootPath; self.fromDate = fromDate; self.toDate = toDate; self.totalBefore = totalBefore
        self.totalAfter = totalAfter; self.grown = grown; self.shrunk = shrunk; self.files = files
    }

    private enum CodingKeys: String, CodingKey {
        case rootPath, fromDate, toDate, totalBefore, totalAfter, rootStatusBefore, rootStatusAfter, grown, shrunk, files
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try values.decode(String.self, forKey: .rootPath)
        fromDate = try values.decode(Date.self, forKey: .fromDate)
        toDate = try values.decode(Date.self, forKey: .toDate)
        totalBefore = try values.decode(Int64.self, forKey: .totalBefore)
        totalAfter = try values.decode(Int64.self, forKey: .totalAfter)
        rootStatusBefore = try values.decodeIfPresent(ScanStatus.self, forKey: .rootStatusBefore) ?? .complete
        rootStatusAfter = try values.decodeIfPresent(ScanStatus.self, forKey: .rootStatusAfter) ?? .complete
        grown = try values.decode([DirChange].self, forKey: .grown)
        shrunk = try values.decode([DirChange].self, forKey: .shrunk)
        files = try values.decode([FileChange].self, forKey: .files)
    }
}

public enum TreeDiff {
    /// Matches directories by path. Changes smaller than `minDelta` bytes are ignored; each list holds at most `topN`.
    public static func compare(_ old: TreeSummary, _ new: TreeSummary, topN: Int = 50,
                               minDelta: Int64 = 1_048_576) -> DiffReport {
        DiffEngine.compare(old, new, topN: topN, minDelta: minDelta)
    }
}
