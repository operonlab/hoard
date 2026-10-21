// Parallel getattrlistbulk walk behind `Scanner.scan` (grown from bench/bulkscan_par.swift).
//
// N worker threads share a LIFO stack of directory jobs. A worker pops a job, opens and reads the
// directory with its own BulkReader outside the lock, then takes the lock once to add every entry
// to the tree, push the subdirectory jobs and bump the counters. Ids are handed out under the lock
// before a child job can be popped, so children still get larger ids than their parents and
// `recomputeAggregates()` stays a valid post-order sweep.

import Darwin
import Foundation
import os

final class ParallelWalk: @unchecked Sendable {
    struct Job {
        var path: String
        var node: NodeID
        var fd: Int32  // already open (the root), or -1
    }

    private let tree: FileTree
    private let crossDevices: Bool
    private let progress: ((ScanProgress) -> Void)?
    private let isCancelled: (() -> Bool)?
    /// Runs on the worker after each folder open, outside the lock, with whether it opened; tests order
    /// the workers with it.
    private let afterOpenAttempt: ((ParallelWalk, _ opened: Bool) -> Void)?
    /// `Materialization.offForThread`; tests make it fail.
    private let downloadsOff: (String) -> (() -> Void)?

    // Everything below, and `tree`, is guarded by `cond`.
    private let cond = NSCondition()
    /// Folders inside app containers are opened and read one at a time (see `work`). An unfair lock
    /// lends a waiter's class to the holder, so a user's scan never waits behind a utility rescan's turn.
    private static let containerLane = OSAllocatedUnfairLock()
    private var stack: [Job]
    private var stackedFDs = 1
    private var openReaders = 0
    private var fdWaiters = 0
    private var fdReleaseEpoch = 0
    private var closedFDs = 0  // folders workers have closed; unlike the epoch, failed opens do not count
    private var pressureCount = 0
    private var pending = 1  // jobs queued or being read
    private var cancelled = false
    private var files = 0, dirs = 0
    private var bytes: Int64 = 0
    private let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    private var lastReport: UInt64

    init(tree: FileTree, rootFD: Int32, crossDevices: Bool,
         progress: ((ScanProgress) -> Void)?, isCancelled: (() -> Bool)?,
         afterOpenAttempt: ((ParallelWalk, _ opened: Bool) -> Void)? = nil,
         downloadsOff: @escaping (String) -> (() -> Void)? = Materialization.offForThread) {
        self.tree = tree
        self.crossDevices = crossDevices
        self.progress = progress
        self.isCancelled = isCancelled
        self.afterOpenAttempt = afterOpenAttempt
        self.downloadsOff = downloadsOff
        stack = [Job(path: tree.rootPath, node: FileTree.root, fd: rootFD)]
        lastReport = start
    }

    /// Runs the walk on `threads` new threads and blocks until all of them have stopped.
    /// Returns false when it was cancelled; the tree is then incomplete.
    func run(threads: Int) -> Bool {
        let group = DispatchGroup()
        // New threads start at the default class whoever calls. A caller below it (the live updater, a
        // rescan the app starts on its own) passes its class on, so the walk leaves the CPU and the disk
        // to what the user is doing; a scan the user asked for keeps the default.
        let caller = qos_class_self()
        let lowered = caller != QOS_CLASS_UNSPECIFIED && caller.rawValue < QOS_CLASS_DEFAULT.rawValue
        for _ in 0..<max(1, threads) {
            group.enter()
            Thread.detachNewThread {
                if lowered, pthread_set_qos_class_self_np(caller, 0) != 0 {
                    NSLog("Hoard scan: cannot lower a worker to class %u; it runs at the default", caller.rawValue)
                }
                self.work()
                group.leave()
            }
        }
        group.wait()
        if cancelled {
            cond.lock()
            for job in stack where job.fd >= 0 { close(job.fd) }
            stack.removeAll()
            stackedFDs = 0
            cond.unlock()
        }
        return !cancelled
    }

    var fdPressureEvents: Int {
        cond.lock(); defer { cond.unlock() }
        return pressureCount
    }

    var closedFDCount: Int {
        cond.lock(); defer { cond.unlock() }
        return closedFDs
    }

    var snapshot: ScanProgress {
        cond.lock(); defer { cond.unlock() }
        return makeProgress(now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    private func makeProgress(now: UInt64) -> ScanProgress {
        ScanProgress(files: files, dirs: dirs, bytes: bytes, elapsed: Double(now - start) / 1e9)
    }

    private func work() {
        let reader = BulkReader()
        // A scan never downloads: reading a folder evicted to iCloud fails, and the folder is unknown,
        // not zero, instead of its listing being fetched. A worker that cannot turn downloads off reads nothing.
        let restore = downloadsOff("scan")
        defer { restore?() }
        while true {
            cond.lock()
            while stack.isEmpty && pending > 0 && !cancelled { cond.wait() }
            if cancelled || stack.isEmpty {
                cond.unlock()
                return
            }
            var job = stack.removeLast()
            if job.fd >= 0 { stackedFDs -= 1; openReaders += 1 }
            cond.unlock()

            if isCancelled?() == true {
                if job.fd >= 0 {
                    close(job.fd)
                    readerClosed()
                }
                cond.lock()
                cancelled = true
                cond.broadcast()
                cond.unlock()
                return
            }

            // Opened and read concurrently, folders in other apps' containers stalled about a third of
            // ~/Library scans: the system's app-data check held an open for 5 s, then failed it with
            // EINTR. One at a time they never stalled in 20 runs, and the rest of the walk stays parallel.
            // The plain substring test spares the lowercased copy for the folders that cannot match.
            let laned = job.path.contains("ontainers/") && {
                let lowerPath = job.path.lowercased()
                return lowerPath.contains("/library/containers/") || lowerPath.contains("/library/group containers/")
                    || lowerPath.contains("/library/daemon containers/")
            }()
            if laned { Self.containerLane.lock() }

            // A failed path open may be caused solely by readers held by other workers. Wait for
            // one to release its fd, or process an already-open stacked job before trying again.
            var fd = job.fd
            if restore == nil, fd >= 0 {
                close(fd)
                readerClosed()
                fd = -1
            }
            while fd < 0 && restore != nil {
                cond.lock()
                if cancelled { cond.unlock(); if laned { Self.containerLane.unlock() }; return }
                openReaders += 1
                let closedBeforeOpen = closedFDs
                cond.unlock()
                fd = openDirectory(job.path)
                let openError = errno
                afterOpenAttempt?(self, fd >= 0)
                if fd >= 0 { break }
                cond.lock()
                openReaders -= 1
                fdReleaseEpoch += 1
                if fdWaiters > 0 { cond.broadcast() }
                guard openError == EMFILE || openError == ENFILE else { cond.unlock(); break }
                pressureCount += 1
                // A reader that closed after this open began may have freed the descriptor it lacked,
                // and `openReaders` no longer shows that reader. Each retry needs a new close, so it ends.
                if closedFDs != closedBeforeOpen { cond.unlock(); continue }
                if openReaders > 0 {
                    let seen = fdReleaseEpoch
                    fdWaiters += 1
                    while !cancelled && fdReleaseEpoch == seen { cond.wait() }
                    fdWaiters -= 1
                    let stopped = cancelled
                    cond.unlock()
                    if stopped { if laned { Self.containerLane.unlock() }; return }
                    continue
                }
                if stackedFDs > 0, let index = stack.lastIndex(where: { $0.fd >= 0 }) {
                    stack.insert(job, at: 0)
                    job = stack.remove(at: index + 1)
                    stackedFDs -= 1
                    openReaders += 1
                    fd = job.fd
                }
                cond.unlock()
                break
            }
            var entries: [ScanEntry] = []
            var ok = true
            if fd >= 0 {
                (entries, ok) = reader.read(fd)
                close(fd)
                readerClosed()
            }
            if laned { Self.containerLane.unlock() }
            let base = job.path.hasSuffix("/") ? job.path : job.path + "/"
            let childPaths = entries.map { $0.isDirectory ? base + $0.name : "" }

            var report: ScanProgress?
            cond.lock()
            var pushed = 0
            if fd < 0 {
                tree.setStatus(job.node, .unavailable)
            } else {
                if !ok { tree.markListingIncomplete(job.node) }
                for (i, e) in entries.enumerated() {
                    if e.isDirectory && !crossDevices && e.device != tree.device { continue }
                    let id = tree.addChild(of: job.node, entry: e)
                    if e.isDirectory {
                        dirs += 1
                        stack.append(Job(path: childPaths[i], node: id, fd: -1))
                        pushed += 1
                    } else {
                        files += 1
                        bytes += e.allocSize
                    }
                }
            }
            pending += pushed - 1
            if progress != nil {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if now - lastReport >= 100_000_000 {
                    lastReport = now
                    report = makeProgress(now: now)
                }
            }
            if pushed > 0 || pending == 0 { cond.broadcast() }
            cond.unlock()
            if let report { progress?(report) }
        }
    }

    private func readerClosed() {
        cond.lock()
        openReaders -= 1
        closedFDs += 1
        fdReleaseEpoch += 1
        if fdWaiters > 0 { cond.broadcast() }
        cond.unlock()
    }
}

/// Calls `body` again while it fails with EINTR, up to three times. Opening a folder in another app's
/// container can wait 5 s on the system's app-data check and then fail with EINTR; measured on
/// ~/Library, the second try opened at once. Without it a scan came back partial about half the time.
func retryingEINTR(_ body: () -> Int32) -> Int32 {
    var result: Int32 = -1
    for _ in 0..<3 {
        result = body()
        if result >= 0 || errno != EINTR { break }
    }
    return result
}

/// Opens a directory below the scan root without following a symlink in the last component.
/// Paths longer than PATH_MAX fail with ENAMETOOLONG; those are opened one component at a time.
func openDirectory(_ path: String) -> Int32 {
    let fd = retryingEINTR { open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
    if fd >= 0 || errno != ENAMETOOLONG { return fd }
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    var cur = path.hasPrefix("/") ? retryingEINTR { open("/", O_RDONLY | O_DIRECTORY) } : AT_FDCWD
    if cur < 0 && cur != AT_FDCWD { return -1 }
    for (i, part) in parts.enumerated() {
        let flags = O_RDONLY | O_DIRECTORY | (i == parts.count - 1 ? O_NOFOLLOW : 0)
        let next = retryingEINTR { openat(cur, String(part), flags) }
        let err = errno
        if cur != AT_FDCWD { close(cur) }
        if next < 0 {
            errno = err
            return -1
        }
        cur = next
    }
    return cur == AT_FDCWD ? open(".", O_RDONLY | O_DIRECTORY) : cur
}
