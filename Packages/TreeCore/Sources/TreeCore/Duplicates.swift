import Foundation

/// Tuning for `DuplicateFinder.find`. The finder clamps at use: `max(1, minSize)`,
/// `max(0, edgeBytes)`, `max(1, chunkBytes)`.
public struct DuplicateOptions: Sendable, Equatable {
    /// Smallest logical size considered, in bytes (default 1 MiB).
    public var minSize: Int64
    /// Bytes hashed at each end of a file in stage 2.
    public var edgeBytes: Int
    /// Read size for the byte-by-byte comparison in stage 3.
    public var chunkBytes: Int

    public init(minSize: Int64 = 1_048_576, edgeBytes: Int = 65_536, chunkBytes: Int = 1_048_576) {
        self.minSize = minSize; self.edgeBytes = edgeBytes; self.chunkBytes = chunkBytes
    }
}

/// How far a group got: same size, same head and tail hashes, or byte-identical to EOF.
public enum DuplicateStage: UInt8, Sendable, Codable, Comparable {
    case size = 1, edges = 2, bytes = 3

    public static func < (a: DuplicateStage, b: DuplicateStage) -> Bool { a.rawValue < b.rawValue }
}

/// One storage unit in a group: a file plus the other names that share its storage.
public struct DuplicateMember: Sendable, Equatable, Codable {
    /// Canonical name: the smallest path of this storage unit.
    public var path: String
    public var node: NodeID
    /// Other names in the subtree with the same hardlink / clone key, sorted.
    public var aliases: [String]
    /// The canonical node's `rawAlloc`.
    public var allocBytes: Int64
    /// The names share storage (hardlink or full APFS clone).
    public var sharesStorage: Bool
}

public struct DuplicateGroup: Sendable, Equatable, Codable {
    public var logicalSize: Int64
    /// Sorted by path.
    public var members: [DuplicateMember]
    public var stage: DuplicateStage
    /// Bytes freed by keeping one copy. The primary number.
    public var reclaimableBytes: Int64 { logicalSize * Int64(max(0, members.count - 1)) }
    /// Allocated bytes freed by keeping one copy, as a lower bound (sparse or compressed files,
    /// names that share storage). Extra information, never a replacement for `reclaimableBytes`.
    public var reclaimableAllocLowerBound: Int64

    private enum CodingKeys: String, CodingKey {
        case logicalSize, members, stage, reclaimableAllocLowerBound
    }

    private enum EncodingKeys: String, CodingKey {
        case logicalSize, members, stage, reclaimableBytes, reclaimableAllocLowerBound
    }

    /// Also emits the computed `reclaimableBytes`; decoding ignores it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EncodingKeys.self)
        try c.encode(logicalSize, forKey: .logicalSize)
        try c.encode(members, forKey: .members)
        try c.encode(stage, forKey: .stage)
        try c.encode(reclaimableBytes, forKey: .reclaimableBytes)
        try c.encode(reclaimableAllocLowerBound, forKey: .reclaimableAllocLowerBound)
    }
}

public enum DuplicateSkipReason: String, Sendable, Codable {
    /// Open, seek, read or lstat failed for a reason other than "it is gone".
    case unreadable
    /// The file vanished, stopped being a regular file, or changed size, inode or mtime.
    case changed
    /// No data blocks on this Mac (a cloud placeholder, or a file that is all holes). Reading it could
    /// download it, so it is not read.
    case notLocal = "not_local"
}

/// A storage unit dropped from its group. A file that merely differs is never skipped.
public struct DuplicateSkip: Sendable, Equatable, Codable {
    public var path: String
    public var reason: DuplicateSkipReason
    public var detail: String
}

public enum DuplicateRunStatus: String, Sendable, Codable {
    case complete, partial, cancelled
}

public struct DuplicateProgress: Sendable, Equatable {
    public var stage: DuplicateStage
    /// Units of the current bucket finished in this stage (matched, differed or skipped).
    public var filesDone: Int
    /// Units of the current bucket in this stage (stage 3: the units that entered it).
    /// The single `.size` event carries 0 / 0.
    public var filesTotal: Int
    /// Run total so far.
    public var bytesRead: Int64
}

public struct DuplicateReport: Sendable, Equatable, Codable {
    /// Largest `reclaimableBytes` first, then first path.
    public var groups: [DuplicateGroup]
    /// Sorted by path.
    public var skipped: [DuplicateSkip]
    public var status: DuplicateRunStatus
    /// `nodes[root].status`; `.unavailable` for an invalid root.
    public var treeStatus: ScanStatus
    /// Storage units in size buckets that had 2+ units after stage 1.
    public var candidateFiles: Int
    /// Units of those buckets never edge-hashed (0 when complete).
    public var pendingFiles: Int
    /// Bytes read in the whole run.
    public var bytesRead: Int64
}
