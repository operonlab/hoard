// CONTRACT (FROZEN): public signatures here are shared by Scanner, Snapshot, LiveUpdater and the app.
// Change them only through the main line; bug fixes inside bodies are fine.
//
// Threading: a FileTree is not thread-safe. Build it on one thread, then confine it to the main
// queue. Background work produces a detached FileTree (or [ScanEntry]) and the main queue grafts it.

import Foundation

public enum ScanStatus: UInt8, Codable, Sendable {
    case complete = 0      // every entry under this node was read
    case partial = 1       // something below could not be read; sizes are a lower bound
    case unavailable = 2   // this directory itself could not be opened; size unknown (not zero)
}

public struct NodeFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let directory = NodeFlags(rawValue: 1 << 0)
    public static let symlink = NodeFlags(rawValue: 1 << 1)
    /// APFS reports the file shares all its blocks with another file (EF_SHARES_ALL_BLOCKS).
    public static let cloneShared = NodeFlags(rawValue: 1 << 2)
    /// Another node with the same hardlink / clone key is the one that counts the bytes.
    public static let duplicate = NodeFlags(rawValue: 1 << 3)
    /// Tombstone: unlinked from its parent, slot kept so ids stay stable.
    public static let removed = NodeFlags(rawValue: 1 << 4)
    /// This folder's own listing stopped early. Distinguishes "partial because of me" from
    /// "partial because of a child", so the status can recover when the child does.
    public static let listingIncomplete = NodeFlags(rawValue: 1 << 5)
}

/// One row as the scanner read it from getattrlistbulk.
public struct ScanEntry: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var allocSize: Int64      // ATTR_FILE_ALLOCSIZE; 0 for directories
    public var logicalSize: Int64    // ATTR_FILE_TOTALSIZE; 0 for directories
    public var fileID: UInt64        // ATTR_CMN_FILEID
    public var linkCount: UInt32     // ATTR_FILE_LINKCOUNT; 1 for directories
    public var cloneID: UInt64       // ATTR_CMNEXT_CLONEID; 0 when unknown
    public var sharesAllBlocks: Bool // ATTR_CMNEXT_EXT_FLAGS & EF_SHARES_ALL_BLOCKS
    public var modTime: Int64        // ATTR_CMN_MODTIME, seconds since 1970
    /// ATTR_CMN_ACCTIME. APFS updates it on a read only when it is not newer than the mtime
    /// (relatime-like, measured 2026-10-20), so it is a lower bound on "last used", not an exact time.
    public var accessTime: Int64
    public var device: Int32         // ATTR_CMN_DEVID

    public init(name: String, isDirectory: Bool, isSymlink: Bool = false, allocSize: Int64 = 0,
                logicalSize: Int64 = 0, fileID: UInt64 = 0, linkCount: UInt32 = 1, cloneID: UInt64 = 0,
                sharesAllBlocks: Bool = false, modTime: Int64 = 0, accessTime: Int64 = 0, device: Int32 = 0) {
        self.name = name; self.isDirectory = isDirectory; self.isSymlink = isSymlink
        self.allocSize = allocSize; self.logicalSize = logicalSize; self.fileID = fileID
        self.linkCount = linkCount; self.cloneID = cloneID; self.sharesAllBlocks = sharesAllBlocks
        self.modTime = modTime; self.accessTime = accessTime; self.device = device
    }
}

public typealias NodeID = Int32

public struct Node: Sendable, Equatable {
    public var name: String
    public var parent: NodeID          // -1 for the root
    public var firstChild: NodeID      // -1 when none
    public var nextSibling: NodeID     // -1 when last
    public var flags: NodeFlags
    public var status: ScanStatus
    public var rawAlloc: Int64         // as reported by the file system
    public var ownAlloc: Int64         // what this node contributes after dedup (0 for duplicates and dirs)
    public var logicalSize: Int64
    public var modTime: Int64
    public var fileID: UInt64
    public var cloneID: UInt64
    public var linkCount: UInt32
    public var device: Int32
    // Subtree aggregates, inclusive of this node.
    public var totalAlloc: Int64
    public var totalLogical: Int64
    // Counts never exceed the node count, which never exceeds Int32.max (NodeID), so they are stored
    // as Int32 (stride 120 instead of 128). Snapshot.read rejects counts that do not add up, so live
    // mutation keeps every count within 0...node count.
    private var storedFileCount: Int32
    private var storedDirCount: Int32
    /// See `ScanEntry.accessTime`.
    public var accessTime: Int64 = 0

    public var fileCount: Int64 {
        get { Int64(storedFileCount) }
        set { storedFileCount = Self.narrow(newValue) }
    }
    public var dirCount: Int64 {
        get { Int64(storedDirCount) }
        set { storedDirCount = Self.narrow(newValue) }
    }

    public var isDirectory: Bool { flags.contains(.directory) }
    public var isRemoved: Bool { flags.contains(.removed) }
    /// Another name points at the same data: a hardlink, or a full APFS clone. Freeing this file then
    /// frees less than its size.
    public var sharesStorage: Bool { linkCount > 1 || flags.contains(.cloneShared) }

    init(name: String, parent: NodeID, firstChild: NodeID, nextSibling: NodeID, flags: NodeFlags, status: ScanStatus,
         rawAlloc: Int64, ownAlloc: Int64, logicalSize: Int64, modTime: Int64, fileID: UInt64, cloneID: UInt64,
         linkCount: UInt32, device: Int32, totalAlloc: Int64, totalLogical: Int64, fileCount: Int64, dirCount: Int64,
         accessTime: Int64 = 0) {
        self.name = name; self.parent = parent; self.firstChild = firstChild; self.nextSibling = nextSibling
        self.flags = flags; self.status = status; self.rawAlloc = rawAlloc; self.ownAlloc = ownAlloc
        self.logicalSize = logicalSize; self.modTime = modTime; self.fileID = fileID; self.cloneID = cloneID
        self.linkCount = linkCount; self.device = device; self.totalAlloc = totalAlloc; self.totalLogical = totalLogical
        self.storedFileCount = Self.narrow(fileCount); self.storedDirCount = Self.narrow(dirCount)
        self.accessTime = accessTime
    }

    /// Lossless storage only; the range is Snapshot.read's and the tree's job.
    private static func narrow(_ value: Int64) -> Int32 {
        precondition(Int32(exactly: value) != nil, "count \(value) does not fit in Int32")
        return Int32(truncatingIfNeeded: value)
    }
}

public struct ExtensionStat: Sendable, Equatable {
    public var ext: String      // lowercased, "" when the name has none
    public var bytes: Int64     // counted (deduped) alloc
    public var count: Int64
}

struct DedupKey: Hashable {
    var hardlink: Bool
    var device: Int32
    var id: UInt64
}

public final class FileTree {
    public let rootPath: String
    public let device: Int32
    public internal(set) var nodes: [Node]
    /// key → holders in insertion order; the first live holder counts the bytes.
    var holders: [DedupKey: [NodeID]] = [:]
    /// Shares one String per distinct long name during the bulk build; dropped at the end of
    /// `recomputeAggregates()`, after which live inserts keep their own String.
    private var nameInterner: NameInterner?
    /// Lazy name indexes for wide directories touched by live updates; dropped after each live batch
    /// (`releaseNameIndexes()`) and by `recomputeAggregates()`.
    var childNameIndexes: [NodeID: ChildNameIndex] = [:]
    lazy var rootUTF8: [UInt8] = Array(rootPath.utf8)

    public static let root: NodeID = 0

    public init(rootPath: String, device: Int32, rootModTime: Int64 = 0) {
        self.rootPath = rootPath
        self.device = device
        self.nodes = [Node(name: rootPath, parent: -1, firstChild: -1, nextSibling: -1, flags: .directory,
                           status: .complete, rawAlloc: 0, ownAlloc: 0, logicalSize: 0, modTime: rootModTime,
                           fileID: 0, cloneID: 0, linkCount: 1, device: device, totalAlloc: 0,
                           totalLogical: 0, fileCount: 0, dirCount: 1)]
        self.nameInterner = NameInterner()
    }

    /// Rebuilds a tree from decoded nodes (Snapshot). Dedup holders are reconstructed from flags.
    public convenience init(restoring nodes: [Node], rootPath: String, device: Int32) {
        let candidates = nodes.indices.filter { !nodes[$0].isDirectory && Self.dedupKey(nodes[$0]) != nil }
        self.init(restoring: nodes, rootPath: rootPath, device: device, dedupCandidates: candidates.map { NodeID($0) })
    }

    /// `dedupCandidates`: every node with a dedup key, in increasing id order.
    init(restoring nodes: [Node], rootPath: String, device: Int32, dedupCandidates: [NodeID]) {
        precondition(!nodes.isEmpty, "a tree always has a root")
        self.rootPath = rootPath
        self.device = device
        self.nodes = nodes
        // Primaries first so that holders[0] is the one counting the bytes.
        for pass in 0..<2 {
            for id in dedupCandidates where !nodes[Int(id)].isRemoved {
                guard let key = Self.dedupKey(nodes[Int(id)]) else { continue }
                let isPrimary = !nodes[Int(id)].flags.contains(.duplicate)
                if (pass == 0) == isPrimary { holders[key, default: []].append(id) }
            }
        }
    }

    public subscript(id: NodeID) -> Node { nodes[Int(id)] }
    public var nodeCount: Int { nodes.count }

    // MARK: Building

    /// Appends a child. Does not touch ancestor aggregates: call `recomputeAggregates()` after a bulk
    /// build, or use `insert(_:under:)` for a single live insertion.
    ///
    /// Under a removed parent (a live update that lands after its folder was removed) the child is
    /// born removed: every node that is not removed must stay reachable from the root.
    @discardableResult
    public func addChild(of parent: NodeID, entry: ScanEntry) -> NodeID {
        let id = NodeID(nodes.count)
        let orphaned = nodes[Int(parent)].isRemoved
        var flags: NodeFlags = orphaned ? [.removed] : []
        if entry.isDirectory { flags.insert(.directory) }
        if entry.isSymlink { flags.insert(.symlink) }
        if entry.sharesAllBlocks { flags.insert(.cloneShared) }
        let name = nameInterner?.intern(entry.name) ?? entry.name
        var node = Node(name: name, parent: parent, firstChild: -1, nextSibling: nodes[Int(parent)].firstChild,
                        flags: flags, status: .complete, rawAlloc: entry.allocSize, ownAlloc: entry.allocSize,
                        logicalSize: entry.logicalSize, modTime: entry.modTime, fileID: entry.fileID,
                        cloneID: entry.cloneID, linkCount: entry.linkCount, device: entry.device,
                        totalAlloc: 0, totalLogical: 0, fileCount: 0, dirCount: 0, accessTime: entry.accessTime)
        if entry.isDirectory { node.ownAlloc = 0 }
        if !orphaned, let key = Self.dedupKey(node) {
            if let existing = holders[key], existing.contains(where: { !nodes[Int($0)].isRemoved }) {
                node.ownAlloc = 0
                node.flags.insert(.duplicate)
            }
            holders[key, default: []].append(id)
        }
        nodes.append(node)
        nodes[Int(parent)].firstChild = id
        if !orphaned { indexChildAdded(id, to: parent) }
        return id
    }

    public func setStatus(_ id: NodeID, _ status: ScanStatus) {
        nodes[Int(id)].status = status
    }

    /// Identity fields a grafted folder inherits from the listing that found it.
    public func setIdentity(_ id: NodeID, fileID: UInt64, modTime: Int64? = nil) {
        nodes[Int(id)].fileID = fileID
        if let modTime { nodes[Int(id)].modTime = modTime }
    }

    /// The scanner read only part of this folder. It stays partial until a complete listing.
    public func markListingIncomplete(_ id: NodeID) {
        nodes[Int(id)].flags.insert(.listingIncomplete)
        if nodes[Int(id)].status == .complete { nodes[Int(id)].status = .partial }
    }

    /// Makes the byte owner of each hardlink / clone group independent of scan order: the member with
    /// the lexicographically smallest path counts the bytes. Without this, a parallel scan moves
    /// gigabytes between folders from one run to the next (observed: assets/ 5.05 GB vs 9.06 GB).
    public func canonicalizeDedupOwners() {
        for (key, list) in holders {
            let live = list.filter { !nodes[Int($0)].isRemoved }
            guard live.count > 1 else { continue }
            var owner = live[0]
            var ownerPath = path(of: owner)
            for id in live.dropFirst() {
                let p = path(of: id)
                if p < ownerPath { owner = id; ownerPath = p }
            }
            for id in live {
                if id == owner {
                    nodes[Int(id)].flags.remove(.duplicate)
                    nodes[Int(id)].ownAlloc = nodes[Int(id)].rawAlloc
                } else {
                    nodes[Int(id)].flags.insert(.duplicate)
                    nodes[Int(id)].ownAlloc = 0
                }
            }
            holders[key] = [owner] + list.filter { $0 != owner }
        }
    }

    /// Post-order recompute of every aggregate. O(n). Also lifts partial/unavailable up to ancestors.
    /// Dedup owners are canonicalized first, so a bulk build gives the same per-folder sizes every time.
    public func recomputeAggregates() {
        canonicalizeDedupOwners()
        // Children always have larger ids than parents (addChild appends), so a reverse sweep is post-order.
        // Fields are updated in place: copying a whole Node would retain its name, and interned names are
        // shared objects scattered over the heap, so every copy would be a cache miss.
        nodes.withUnsafeMutableBufferPointer { nodes in
            for i in nodes.indices {
                let removed = nodes[i].isRemoved, directory = nodes[i].isDirectory
                nodes[i].totalAlloc = removed ? 0 : nodes[i].ownAlloc
                nodes[i].totalLogical = removed || directory ? 0 : nodes[i].logicalSize
                nodes[i].fileCount = removed || directory ? 0 : 1
                nodes[i].dirCount = removed || !directory ? 0 : 1
            }
            for i in nodes.indices.reversed() where i != 0 {
                if nodes[i].isRemoved { continue }
                let p = Int(nodes[i].parent)
                nodes[p].totalAlloc += nodes[i].totalAlloc
                nodes[p].totalLogical += nodes[i].totalLogical
                nodes[p].fileCount += nodes[i].fileCount
                nodes[p].dirCount += nodes[i].dirCount
                if nodes[i].status != .complete && nodes[p].status == .complete { nodes[p].status = .partial }
            }
        }
        nameInterner = nil
        childNameIndexes.removeAll(keepingCapacity: false)
    }

    // MARK: Live mutation (keeps aggregates correct, O(depth) per call)

    /// Inserts one entry under `parent` and propagates its contribution to every ancestor.
    @discardableResult
    public func insert(_ entry: ScanEntry, under parent: NodeID) -> NodeID {
        let id = addChild(of: parent, entry: entry)
        let n = nodes[Int(id)]
        if n.isRemoved { return id }
        nodes[Int(id)].totalAlloc = n.ownAlloc
        nodes[Int(id)].totalLogical = n.isDirectory ? 0 : n.logicalSize
        nodes[Int(id)].fileCount = n.isDirectory ? 0 : 1
        nodes[Int(id)].dirCount = n.isDirectory ? 1 : 0
        propagate(from: parent, alloc: n.ownAlloc, logical: n.isDirectory ? 0 : n.logicalSize,
                  files: n.isDirectory ? 0 : 1, dirs: n.isDirectory ? 1 : 0)
        // A live insert must pick the same owner a full scan would.
        if let key = Self.dedupKey(n) { reassignOwner(key) }
        return id
    }

    /// Updates a file's sizes in place (the file changed but kept its name).
    public func updateFile(_ id: NodeID, with entry: ScanEntry) {
        precondition(!nodes[Int(id)].isDirectory, "updateFile is for files")
        let old = nodes[Int(id)]
        // Same hardlinked inode, new size: every name of it changes together, and it still counts once.
        if let key = Self.dedupKey(old), key.hardlink, entry.linkCount > 1, entry.fileID == old.fileID,
           entry.device == old.device, !entry.isSymlink {
            for h in holders[key] ?? [] where !nodes[Int(h)].isRemoved {
                let n = nodes[Int(h)]
                let counts = !n.flags.contains(.duplicate)
                let dAlloc = counts ? entry.allocSize - n.ownAlloc : 0
                let dLogical = entry.logicalSize - n.logicalSize
                nodes[Int(h)].rawAlloc = entry.allocSize
                nodes[Int(h)].logicalSize = entry.logicalSize
                nodes[Int(h)].modTime = entry.modTime
                nodes[Int(h)].accessTime = entry.accessTime
                nodes[Int(h)].totalLogical = entry.logicalSize
                if counts {
                    nodes[Int(h)].ownAlloc = entry.allocSize
                    nodes[Int(h)].totalAlloc = entry.allocSize
                }
                propagate(from: n.parent, alloc: dAlloc, logical: dLogical, files: 0, dirs: 0)
            }
            return
        }
        // Any other change of dedup identity: remove and re-insert.
        if Self.dedupKey(old) != nil || entry.linkCount > 1 || entry.sharesAllBlocks {
            let parent = old.parent
            removeSubtree(id)
            insert(entry, under: parent)
            return
        }
        let dAlloc = entry.allocSize - old.ownAlloc
        let dLogical = entry.logicalSize - old.logicalSize
        nodes[Int(id)].rawAlloc = entry.allocSize
        nodes[Int(id)].ownAlloc = entry.allocSize
        nodes[Int(id)].logicalSize = entry.logicalSize
        nodes[Int(id)].modTime = entry.modTime
        nodes[Int(id)].accessTime = entry.accessTime
        nodes[Int(id)].totalAlloc = entry.allocSize
        nodes[Int(id)].totalLogical = entry.logicalSize
        propagate(from: old.parent, alloc: dAlloc, logical: dLogical, files: 0, dirs: 0)
    }

    /// Unlinks `id` and its subtree, releases dedup claims (promoting the next holder, whose bytes
    /// then count where it lives), and propagates the change to ancestors.
    public func removeSubtree(_ id: NodeID) {
        precondition(id != Self.root, "cannot remove the root")
        let n = nodes[Int(id)]
        guard !n.isRemoved else { return }
        unlink(id)
        propagate(from: n.parent, alloc: -n.totalAlloc, logical: -n.totalLogical,
                  files: -n.fileCount, dirs: -n.dirCount)
        defer { if n.status != .complete { refreshAncestorStatus(from: n.parent) } }
        // Flag the whole subtree before releasing dedup claims, so no node inside it can be promoted.
        var doomed: [NodeID] = []
        var stack = [id]
        while let cur = stack.popLast() {
            nodes[Int(cur)].flags.insert(.removed)
            if !childNameIndexes.isEmpty { childNameIndexes[cur] = nil }
            doomed.append(cur)
            var c = nodes[Int(cur)].firstChild
            while c >= 0 { stack.append(c); c = nodes[Int(c)].nextSibling }
        }
        for cur in doomed { releaseDedup(cur) }
    }

    /// Replaces (or adds) the subtree for `name` under `parent` with the contents of `sub`, whose
    /// root becomes that child. Used when a directory is rescanned in the background.
    @discardableResult
    public func graft(_ sub: FileTree, as name: String, under parent: NodeID) -> NodeID {
        // The folder this was scanned for is gone: nothing below it can be reached, so copy nothing.
        if nodes[Int(parent)].isRemoved {
            return insert(ScanEntry(name: name, isDirectory: true, device: sub[FileTree.root].device), under: parent)
        }
        if let existing = child(named: name, of: parent) { removeSubtree(existing) }
        let subRoot = sub[FileTree.root]
        let newRoot = insert(ScanEntry(name: name, isDirectory: true, modTime: subRoot.modTime,
                                       device: subRoot.device), under: parent)
        nodes[Int(newRoot)].status = subRoot.status
        var map: [NodeID: NodeID] = [FileTree.root: newRoot]
        // Ids in `sub` grow from parent to child, so a forward sweep sees parents first.
        for i in 1..<sub.nodes.count {
            let s = sub.nodes[i]
            if s.isRemoved { continue }
            guard let p = map[s.parent] else { continue }
            let id = insert(ScanEntry(name: s.name, isDirectory: s.isDirectory, isSymlink: s.flags.contains(.symlink),
                                      allocSize: s.rawAlloc, logicalSize: s.logicalSize, fileID: s.fileID,
                                      linkCount: s.linkCount, cloneID: s.cloneID,
                                      sharesAllBlocks: s.flags.contains(.cloneShared), modTime: s.modTime, accessTime: s.accessTime,
                                      device: s.device), under: p)
            nodes[Int(id)].status = s.status
            if s.flags.contains(.listingIncomplete) { nodes[Int(id)].flags.insert(.listingIncomplete) }
            map[NodeID(i)] = id
        }
        if subRoot.flags.contains(.listingIncomplete) { nodes[Int(newRoot)].flags.insert(.listingIncomplete) }
        refreshAncestorStatus(from: parent)
        return newRoot
    }

    /// Drops everything below a folder whose contents can no longer be read, so the sizes shown as
    /// "≥" stay a lower bound instead of counting files that may be gone.
    public func clearContents(_ id: NodeID) {
        for child in children(of: id) { removeSubtree(child) }
    }

    /// The folder could not be opened at all: its size is unknown, its ancestors become partial.
    public func markUnavailable(_ id: NodeID) {
        nodes[Int(id)].status = .unavailable
        refreshAncestorStatus(from: nodes[Int(id)].parent)
    }

    /// A complete listing of this folder just succeeded: it is no longer partial on its own account.
    public func markListed(_ id: NodeID) {
        nodes[Int(id)].flags.remove(.listingIncomplete)
        nodes[Int(id)].status = derivedStatus(id)
        refreshAncestorStatus(from: nodes[Int(id)].parent)
    }

    /// Re-derives status upward from `start`: partial when the folder's own listing was cut short or
    /// any child is not complete, otherwise complete. Unavailable folders keep their status.
    func refreshAncestorStatus(from start: NodeID) {
        var cur = start
        while cur >= 0 {
            if nodes[Int(cur)].isRemoved { return }
            if nodes[Int(cur)].status != .unavailable { nodes[Int(cur)].status = derivedStatus(cur) }
            cur = nodes[Int(cur)].parent
        }
    }

    private func derivedStatus(_ id: NodeID) -> ScanStatus {
        if nodes[Int(id)].flags.contains(.listingIncomplete) { return .partial }
        var c = nodes[Int(id)].firstChild
        while c >= 0 {
            if !nodes[Int(c)].isRemoved && nodes[Int(c)].status != .complete { return .partial }
            c = nodes[Int(c)].nextSibling
        }
        return .complete
    }

    // MARK: Queries

    public func children(of id: NodeID) -> [NodeID] {
        var out: [NodeID] = []
        var c = nodes[Int(id)].firstChild
        while c >= 0 {
            if !nodes[Int(c)].isRemoved { out.append(c) }
            c = nodes[Int(c)].nextSibling
        }
        return out
    }

    /// Children ordered by counted size, largest first; ties by name.
    public func sortedChildren(of id: NodeID) -> [NodeID] {
        children(of: id).sorted {
            let a = nodes[Int($0)], b = nodes[Int($1)]
            return a.totalAlloc != b.totalAlloc ? a.totalAlloc > b.totalAlloc : a.name < b.name
        }
    }

    public func child(named name: String, of id: NodeID) -> NodeID? {
        childLookup(name, of: id)
    }

    /// Absolute path of a node.
    public func path(of id: NodeID) -> String {
        if id == Self.root { return rootPath }
        var parts: [String] = []
        var cur = id
        while cur != Self.root && cur >= 0 {
            parts.append(nodes[Int(cur)].name)
            cur = nodes[Int(cur)].parent
        }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return base + "/" + parts.reversed().joined(separator: "/")
    }

    /// Finds the node for an absolute path inside this tree, or nil.
    public func lookup(path: String) -> NodeID? {
        guard let walked = walk(path: path), walked.complete else { return nil }
        return walked.deepest
    }

    /// Bytes and file counts per extension for the subtree at `id`, largest first. O(subtree).
    public func extensionStats(under id: NodeID = FileTree.root) -> [ExtensionStat] {
        Self.extensionStats(in: nodes, under: id)
    }

    /// Same as `extensionStats(under:)` on a copy of `nodes`, so a background thread can work on a
    /// value snapshot without rebuilding a tree.
    public static func extensionStats(in nodes: [Node], under id: NodeID) -> [ExtensionStat] {
        fastExtensionStats(in: nodes, under: id)
    }

    public static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, dot != name.index(before: name.endIndex) else {
            return ""
        }
        return name[name.index(after: dot)...].lowercased()
    }

    // MARK: Internals

    static func dedupKey(_ n: Node) -> DedupKey? {
        if n.isDirectory { return nil }
        if n.linkCount > 1 && n.fileID != 0 { return DedupKey(hardlink: true, device: n.device, id: n.fileID) }
        if n.flags.contains(.cloneShared) && n.cloneID != 0 { return DedupKey(hardlink: false, device: n.device, id: n.cloneID) }
        return nil
    }

    private func unlink(_ id: NodeID) {
        let parent = nodes[Int(id)].parent
        indexChildUnlinked(id, from: parent)
        var c = nodes[Int(parent)].firstChild
        if c == id {
            nodes[Int(parent)].firstChild = nodes[Int(id)].nextSibling
            return
        }
        while c >= 0 {
            let next = nodes[Int(c)].nextSibling
            if next == id { nodes[Int(c)].nextSibling = nodes[Int(id)].nextSibling; return }
            c = next
        }
    }

    private func releaseDedup(_ id: NodeID) {
        let n = nodes[Int(id)]
        guard let key = Self.dedupKey(n), var list = holders[key] else { return }
        list.removeAll { $0 == id }
        holders[key] = list.isEmpty ? nil : list
        if !list.isEmpty { reassignOwner(key) }
    }

    /// Moves the bytes of a dedup group to its lexicographically smallest live member, keeping
    /// ancestor totals right. Same rule as `canonicalizeDedupOwners`, applied to one group, O(group).
    private func reassignOwner(_ key: DedupKey) {
        guard let list = holders[key] else { return }
        let live = list.filter { !nodes[Int($0)].isRemoved }
        guard let first = live.first else { return }
        var owner = first
        var ownerPath = path(of: owner)
        for id in live.dropFirst() {
            let p = path(of: id)
            if p < ownerPath { owner = id; ownerPath = p }
        }
        for id in live where id != owner && !nodes[Int(id)].flags.contains(.duplicate) {
            let bytes = nodes[Int(id)].ownAlloc
            nodes[Int(id)].flags.insert(.duplicate)
            nodes[Int(id)].ownAlloc = 0
            nodes[Int(id)].totalAlloc = 0
            propagate(from: nodes[Int(id)].parent, alloc: -bytes, logical: 0, files: 0, dirs: 0)
        }
        if nodes[Int(owner)].flags.contains(.duplicate) {
            let bytes = nodes[Int(owner)].rawAlloc
            nodes[Int(owner)].flags.remove(.duplicate)
            nodes[Int(owner)].ownAlloc = bytes
            nodes[Int(owner)].totalAlloc = bytes
            propagate(from: nodes[Int(owner)].parent, alloc: bytes, logical: 0, files: 0, dirs: 0)
        }
        holders[key] = [owner] + list.filter { $0 != owner }
    }

    private func propagate(from start: NodeID, alloc: Int64, logical: Int64, files: Int64, dirs: Int64) {
        var cur = start
        while cur >= 0 {
            if nodes[Int(cur)].isRemoved { return }
            nodes[Int(cur)].totalAlloc += alloc
            nodes[Int(cur)].totalLogical += logical
            nodes[Int(cur)].fileCount += files
            nodes[Int(cur)].dirCount += dirs
            cur = nodes[Int(cur)].parent
        }
    }
}
