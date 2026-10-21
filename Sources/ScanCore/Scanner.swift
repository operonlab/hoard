// CONTRACT (FROZEN signatures): `Scanner`, `ScanOptions`, `ScanProgress`, `ScanError`, `scan`, `listDirectory`.
// `scan` runs the parallel walker in WalkParallel.swift; the original sequential walk lives on as
// `scanSequential` in WalkSequential.swift (test oracle and the CLI's `--sequential`).

import Darwin
import Foundation

public struct ScanOptions: Sendable {
    public var threads: Int
    /// Follow into other devices (mount points). Off by default, like `du -x`.
    public var crossDevices: Bool
    public init(threads: Int = ProcessInfo.processInfo.activeProcessorCount, crossDevices: Bool = false) {
        self.threads = threads
        self.crossDevices = crossDevices
    }
}

public struct ScanProgress: Sendable {
    public var files: Int
    public var dirs: Int
    public var bytes: Int64
    public var elapsed: TimeInterval
}

public enum ScanError: Error, Equatable {
    case cannotOpen(path: String, errno: Int32)
    case notADirectory(path: String)
    case cancelled
    /// The directory opened but reading it stopped early; the entries are not the full list.
    case incompleteListing(path: String)
}

public final class Scanner: @unchecked Sendable {
    public let options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Walks `root` with `options.threads` workers and returns a fully aggregated tree. `progress`
    /// may be called from any thread, at most every ~100 ms. `isCancelled` is polled per directory;
    /// on cancel this throws `ScanError.cancelled` once every worker has stopped.
    public func scan(root: String, progress: ((ScanProgress) -> Void)? = nil,
                     isCancelled: (() -> Bool)? = nil) throws -> FileTree {
        try scan(root: root, progress: progress, isCancelled: isCancelled, downloadsOff: Materialization.offForThread)
    }

    /// `scan` with the download switch injected (tests make it fail or record it).
    func scan(root: String, progress: ((ScanProgress) -> Void)?, isCancelled: (() -> Bool)?,
              downloadsOff: @escaping (String) -> (() -> Void)?) throws -> FileTree {
        var st = stat()
        guard lstat(root, &st) == 0 else { throw ScanError.cannotOpen(path: root, errno: errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ScanError.notADirectory(path: root) }
        let tree = FileTree(rootPath: root, device: st.st_dev, rootModTime: Int64(st.st_mtimespec.tv_sec))
        // The root is opened on this thread, the rest by the workers; neither downloads (see `work`).
        guard let restore = downloadsOff("scan") else {
            tree.setStatus(FileTree.root, .unavailable)
            return tree
        }
        defer { restore() }
        let fd = retryingEINTR { open(root, O_RDONLY | O_DIRECTORY) }
        guard fd >= 0 else { throw ScanError.cannotOpen(path: root, errno: errno) }
        let walk = ParallelWalk(tree: tree, rootFD: fd, crossDevices: options.crossDevices,
                                progress: progress, isCancelled: isCancelled, downloadsOff: downloadsOff)
        guard walk.run(threads: options.threads) else { throw ScanError.cancelled }
        tree.recomputeAggregates()
        progress?(walk.snapshot)
        return tree
    }

    /// Reads one directory level (no recursion). Used by the live updater to diff a changed folder.
    public func listDirectory(_ path: String) throws -> [ScanEntry] {
        try listDirectory(path, downloadsOff: Materialization.offForThread)
    }

    /// `listDirectory` with the download switch injected (tests make it fail or record it).
    func listDirectory(_ path: String, downloadsOff: (String) -> (() -> Void)?) throws -> [ScanEntry] {
        // As in `scan`: no download, and nothing read when downloads cannot be turned off.
        guard let restore = downloadsOff("live update") else {
            throw ScanError.incompleteListing(path: path)
        }
        defer { restore() }
        let fd = retryingEINTR { open(path, O_RDONLY | O_DIRECTORY) }
        guard fd >= 0 else { throw ScanError.cannotOpen(path: path, errno: errno) }
        defer { close(fd) }
        return try Self.complete(BulkReader().read(fd), path: path)
    }

    /// A listing cut short by an error is not the directory's contents: the live updater would read
    /// the missing names as deleted. Callers get an error instead and mark the folder unavailable.
    static func complete(_ listing: (entries: [ScanEntry], ok: Bool), path: String) throws -> [ScanEntry] {
        guard listing.ok else { throw ScanError.incompleteListing(path: path) }
        return listing.entries
    }
}

/// getattrlistbulk wrapper. One instance per thread (owns its buffer).
final class BulkReader {
    private var attrs = attrlist()
    private let bufSize = 256 * 1024
    private let buf: UnsafeMutableRawPointer

    init() {
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCTIME) | attrgroup_t(ATTR_CMN_FILEID)
        attrs.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        // With FSOPT_ATTR_CMN_EXTENDED these travel in the fork group (sys/attr.h).
        attrs.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
    }

    deinit { buf.deallocate() }

    /// Returns the entries and whether the listing completed without error.
    func read(_ dirfd: Int32) -> (entries: [ScanEntry], ok: Bool) {
        readBulkRestartingOnEINTR(dirfd: dirfd,
                                  bulkCall: { getattrlistbulk(dirfd, &attrs, buf, bufSize, UInt64(FSOPT_ATTR_CMN_EXTENDED)) }) { n, out in
            var ok = true
            var entry = UnsafeRawPointer(buf)
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var cur = entry + 4
                let returned = cur.loadUnaligned(as: attribute_set_t.self)
                cur += MemoryLayout<attribute_set_t>.size
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    let err = cur.loadUnaligned(as: UInt32.self); cur += 4
                    if err != 0 { ok = false; continue }
                }
                var e = ScanEntry(name: "", isDirectory: false)
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = cur.loadUnaligned(as: attrreference_t.self)
                    e.name = String(cString: (cur + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    cur += MemoryLayout<attrreference_t>.size
                }
                if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 { e.device = cur.loadUnaligned(as: Int32.self); cur += 4 }
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    let t = cur.loadUnaligned(as: UInt32.self); cur += 4
                    e.isDirectory = t == VDIR.rawValue
                    e.isSymlink = t == VLNK.rawValue
                }
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    e.modTime = Int64(cur.loadUnaligned(as: timespec.self).tv_sec); cur += MemoryLayout<timespec>.size
                }
                // Attributes come back in bit order: MODTIME (0x400) before ACCTIME (0x1000) before FILEID.
                if returned.commonattr & attrgroup_t(ATTR_CMN_ACCTIME) != 0 {
                    e.accessTime = Int64(cur.loadUnaligned(as: timespec.self).tv_sec); cur += MemoryLayout<timespec>.size
                }
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 { e.fileID = cur.loadUnaligned(as: UInt64.self); cur += 8 }
                if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { e.linkCount = cur.loadUnaligned(as: UInt32.self); cur += 4 }
                if returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 { e.logicalSize = cur.loadUnaligned(as: Int64.self); cur += 8 }
                if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 { e.allocSize = cur.loadUnaligned(as: Int64.self); cur += 8 }
                if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 { e.cloneID = cur.loadUnaligned(as: UInt64.self); cur += 8 }
                if returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
                    e.sharesAllBlocks = cur.loadUnaligned(as: UInt64.self) & 0x40 != 0  // EF_SHARES_ALL_BLOCKS
                    cur += 8
                }
                if e.isDirectory { e.allocSize = 0; e.logicalSize = 0; e.linkCount = 1 }
                out.append(e)
            }
            return ok
        }
    }
}

/// An interrupted bulk call may have advanced the directory offset. Discard the partial listing
/// and restart at offset zero, with three attempts total.
func readBulkRestartingOnEINTR<Entry>(dirfd: Int32, bulkCall: () -> Int32,
                                      appendBatch: (Int32, inout [Entry]) -> Bool) -> (entries: [Entry], ok: Bool) {
    var out: [Entry] = []
    var ok = true
    var attempt = 1
    while true {
        let n = bulkCall()
        let callError = errno
        if n == 0 { return (out, ok) }
        if n < 0 {
            if callError == EINTR, attempt < 3, lseek(dirfd, 0, SEEK_SET) >= 0 {
                attempt += 1
                out.removeAll(keepingCapacity: true)
                ok = true
                continue
            }
            return (out, false)
        }
        if !appendBatch(n, &out) { ok = false }
    }
}
