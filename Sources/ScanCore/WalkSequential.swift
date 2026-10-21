// The original single-threaded walk (the main line's seed). Kept as the test oracle for the
// parallel `scan` and behind the CLI's `--sequential`, which is why it is public: the CLI is a
// separate module and cannot reach an internal method.

import Darwin
import Foundation

extension Scanner {
    /// Recursive depth-first walk on the calling thread. Same contract as `scan`.
    public func scanSequential(root: String, progress: ((ScanProgress) -> Void)? = nil,
                               isCancelled: (() -> Bool)? = nil) throws -> FileTree {
        var st = stat()
        guard lstat(root, &st) == 0 else { throw ScanError.cannotOpen(path: root, errno: errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ScanError.notADirectory(path: root) }
        let tree = FileTree(rootPath: root, device: st.st_dev, rootModTime: Int64(st.st_mtimespec.tv_sec))
        // As in `scan`: no download, and nothing read when downloads cannot be turned off.
        guard let restore = Materialization.offForThread("scan") else {
            tree.setStatus(FileTree.root, .unavailable)
            return tree
        }
        defer { restore() }
        let fd = retryingEINTR { open(root, O_RDONLY | O_DIRECTORY) }
        guard fd >= 0 else { throw ScanError.cannotOpen(path: root, errno: errno) }
        let reader = BulkReader()
        let start = Date()
        var files = 0, dirs = 0
        var bytes: Int64 = 0
        var lastReport = start

        func walk(_ dirfd: Int32, _ node: NodeID) throws {
            if isCancelled?() == true { throw ScanError.cancelled }
            let (entries, ok) = reader.read(dirfd)
            if !ok { tree.markListingIncomplete(node) }
            var subdirs: [(String, NodeID)] = []
            for e in entries {
                if e.isDirectory && !options.crossDevices && e.device != tree.device { continue }
                let id = tree.addChild(of: node, entry: e)
                if e.isDirectory { dirs += 1; subdirs.append((e.name, id)) } else { files += 1; bytes += e.allocSize }
            }
            if let progress, Date().timeIntervalSince(lastReport) > 0.1 {
                lastReport = Date()
                progress(ScanProgress(files: files, dirs: dirs, bytes: bytes, elapsed: lastReport.timeIntervalSince(start)))
            }
            for (name, id) in subdirs {
                let cfd = retryingEINTR { openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
                if cfd < 0 { tree.setStatus(id, .unavailable); continue }
                defer { close(cfd) }
                try walk(cfd, id)
            }
        }
        defer { close(fd) }
        try walk(fd, FileTree.root)
        tree.recomputeAggregates()
        progress?(ScanProgress(files: files, dirs: dirs, bytes: bytes, elapsed: Date().timeIntervalSince(start)))
        return tree
    }
}
