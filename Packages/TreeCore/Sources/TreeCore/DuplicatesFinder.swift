import Foundation

/// Read-only duplicate-file finder over a value snapshot of a file tree.
///
/// Like `TreeQuery`, it works on a copy of `FileTree.nodes` and can run off the main queue.
/// Three stages narrow the candidates: equal logical size (in memory), equal FNV-1a 64 of the head
/// and tail (`edgeBytes` at each end), then a byte-by-byte comparison to EOF. Names that already
/// share storage (hardlinks, full APFS clones, same `FileTree.dedupKey`) collapse into one unit and
/// are read once. Files are only ever opened for reading.
public enum DuplicateFinder {
    /// Finds groups of byte-identical files under `root`.
    ///
    /// `isCancelled` is polled before every open and between chunks; a cancelled run returns the
    /// groups confirmed so far (`.bytes`) and the edge-matched ones (`.edges`).
    // ponytail: reads bump atime when atime <= mtime, so stale results are unreliable for read candidates; upgrade: ScanCore restores atime after a run, or the wiring slice warns first
    public static func find(in nodes: [Node], rootPath: String, under root: NodeID = FileTree.root,
                            options: DuplicateOptions = DuplicateOptions(), isCancelled: () -> Bool = { false },
                            progress: (DuplicateProgress) -> Void = { _ in }) -> DuplicateReport {
        find(in: nodes, rootPath: rootPath, under: root, options: options, isCancelled: isCancelled,
             progress: progress, open: DuplicatesIO.openForReading)
    }

    /// The report of a run that must not read at all (iCloud downloads could not be turned off): the
    /// same candidates `find` would compare, each skipped as `not_local` with `detail`, none opened.
    public static func unread(in nodes: [Node], rootPath: String, under root: NodeID = FileTree.root,
                              options: DuplicateOptions = DuplicateOptions(), detail: String) -> DuplicateReport {
        guard root >= 0, Int(root) < nodes.count, !nodes[Int(root)].isRemoved else {
            return DuplicateReport(groups: [], skipped: [], status: .partial, treeStatus: .unavailable,
                                   candidateFiles: 0, pendingFiles: 0, bytesRead: 0)
        }
        var state = State(units: [])
        let buckets = sizeBuckets(in: nodes, rootPath: rootPath, under: root, minSize: max(1, options.minSize),
                                  units: &state.units, notLocal: &state.skips)
        let refused = buckets.flatMap { $0 }.map { DuplicateSkip(path: state.units[$0].path, reason: .notLocal, detail: detail) }
        return DuplicateReport(groups: [], skipped: (state.skips + refused).sorted { $0.path < $1.path }, status: .partial,
                               treeStatus: nodes[Int(root)].status, candidateFiles: buckets.reduce(0) { $0 + $1.count },
                               pendingFiles: buckets.reduce(0) { $0 + $1.count }, bytesRead: 0)
    }

    /// Same as the public `find`, with the file opener injectable for tests.
    static func find(in nodes: [Node], rootPath: String, under root: NodeID = FileTree.root,
                     options: DuplicateOptions = DuplicateOptions(), isCancelled: () -> Bool = { false },
                     progress: (DuplicateProgress) -> Void = { _ in },
                     open: (String) throws -> FileHandle) -> DuplicateReport {
        guard root >= 0, Int(root) < nodes.count, !nodes[Int(root)].isRemoved else {
            return DuplicateReport(groups: [], skipped: [], status: .partial, treeStatus: .unavailable,
                                   candidateFiles: 0, pendingFiles: 0, bytesRead: 0)
        }
        let minSize = max(1, options.minSize)
        let edgeBytes = max(0, options.edgeBytes)
        let chunkBytes = max(1, options.chunkBytes)

        progress(DuplicateProgress(stage: .size, filesDone: 0, filesTotal: 0, bytesRead: 0))
        var state = State(units: [])
        let buckets = sizeBuckets(in: nodes, rootPath: rootPath, under: root, minSize: minSize, units: &state.units,
                                  notLocal: &state.skips)
        var pending = 0

        for bucket in buckets {
            if state.cancelled { pending += bucket.count; continue }
            let subgroups = edgeStage(bucket, edgeBytes: edgeBytes, state: &state, pending: &pending,
                                      isCancelled: isCancelled, progress: progress, open: open)
            if state.cancelled {
                for sub in subgroups { state.addGroup(sub, stage: .edges) }
                continue
            }
            byteStage(subgroups, chunkBytes: chunkBytes, state: &state,
                      isCancelled: isCancelled, progress: progress, open: open)
        }

        let treeStatus = nodes[Int(root)].status
        let status: DuplicateRunStatus = state.cancelled ? .cancelled
            : (!state.skips.isEmpty || treeStatus != .complete) ? .partial : .complete
        let groups = state.groups.sorted {
            $0.reclaimableBytes != $1.reclaimableBytes ? $0.reclaimableBytes > $1.reclaimableBytes
                : ($0.members.first?.path ?? "") < ($1.members.first?.path ?? "")
        }
        return DuplicateReport(groups: groups, skipped: state.skips.sorted { $0.path < $1.path }, status: status,
                               treeStatus: treeStatus, candidateFiles: buckets.reduce(0) { $0 + $1.count },
                               pendingFiles: pending, bytesRead: state.bytesRead)
    }

    // MARK: State

    /// One storage unit: a canonical name plus the names sharing its storage.
    private struct Unit {
        var node: NodeID
        var path: String
        var aliases: [String]
        var size: Int64
        var fileID: UInt64
        var allocBytes: Int64
        var sharesStorage: Bool
        /// The identity seen at the first open; every later open must see the same.
        var sample: DuplicatesIO.Sample?
        var skipped = false
    }

    private struct State {
        var units: [Unit]
        var bytesRead: Int64 = 0
        var skips: [DuplicateSkip] = []
        var groups: [DuplicateGroup] = []
        var cancelled = false

        mutating func skip(_ u: Int, _ f: DuplicatesIO.Failure) {
            units[u].skipped = true
            skips.append(DuplicateSkip(path: units[u].path, reason: f.kind == .changed ? .changed : .unreadable,
                                       detail: f.detail))
        }

        mutating func addGroup(_ us: [Int], stage: DuplicateStage) {
            let live = us.filter { !units[$0].skipped }
            guard live.count >= 2 else { return }
            let members = live.map { u in
                DuplicateMember(path: units[u].path, node: units[u].node, aliases: units[u].aliases,
                                allocBytes: units[u].allocBytes, sharesStorage: units[u].sharesStorage)
            }.sorted { $0.path < $1.path }
            let costs = members.map { $0.sharesStorage ? 0 : $0.allocBytes }
            let keep = members.contains { $0.sharesStorage } ? 0 : (costs.max() ?? 0)
            groups.append(DuplicateGroup(logicalSize: units[live[0]].size, members: members, stage: stage,
                                         reclaimableAllocLowerBound: costs.reduce(0, +) - keep))
        }
    }

    private struct Cancelled: Error {}

    // MARK: Stage 1: sizes

    /// Buckets of 2+ storage units with the same logical size, largest size first; each bucket is
    /// a list of indices into `units`, sorted by path. Paths are built only for surviving buckets.
    private static func sizeBuckets(in nodes: [Node], rootPath: String, under root: NodeID, minSize: Int64,
                                    units: inout [Unit], notLocal: inout [DuplicateSkip]) -> [[Int]] {
        var bySize: [Int64: [NodeID]] = [:]
        var stack = [root]
        var budget = nodes.count   // a malformed array cannot make the walk loop
        while budget > 0, let id = stack.popLast() {
            budget -= 1
            let n = nodes[Int(id)]
            if n.isRemoved { continue }
            if n.isDirectory {
                var c = n.firstChild
                var remaining = nodes.count
                while c >= 0, Int(c) < nodes.count, remaining > 0 {
                    stack.append(c)
                    c = nodes[Int(c)].nextSibling
                    remaining -= 1
                }
            } else if !n.flags.contains(.symlink) && n.logicalSize >= minSize {
                bySize[n.logicalSize, default: []].append(id)
            }
        }

        var buckets: [[Int]] = []
        for size in bySize.keys.sorted(by: >) {
            let ids = bySize[size]!
            var keyed: [DedupKey: [NodeID]] = [:]
            var shared: Set<DedupKey> = []
            var loose: [NodeID] = []
            var absent: [NodeID] = []
            for id in ids {
                let n = nodes[Int(id)]
                if n.rawAlloc == 0 { absent.append(id); continue }
                if let key = FileTree.dedupKey(n) {
                    keyed[key, default: []].append(id)
                    shared.insert(key)
                } else if n.fileID != 0 {
                    // Keyed by inode too: two names of one file are one unit even when the tree has
                    // not caught up on the link count of one of them.
                    keyed[DedupKey(hardlink: true, device: n.device, id: n.fileID), default: []].append(id)
                } else {
                    loose.append(id)
                }
            }
            // Only files that would otherwise have been compared are reported.
            if !absent.isEmpty && loose.count + keyed.count + absent.count >= 2 {
                notLocal += absent.map { DuplicateSkip(path: path(of: $0, in: nodes, rootPath: rootPath), reason: .notLocal,
                                                       detail: "no data blocks on this Mac; reading it could download it") }
            }
            guard loose.count + keyed.count >= 2 else { continue }
            var bucket: [Int] = []
            func add(_ names: [NodeID], shares: Bool) {
                let named = names.map { (id: $0, path: path(of: $0, in: nodes, rootPath: rootPath)) }
                    .sorted { $0.path < $1.path }
                let n = nodes[Int(named[0].id)]
                bucket.append(units.count)
                units.append(Unit(node: named[0].id, path: named[0].path, aliases: named.dropFirst().map { $0.path },
                                  size: size, fileID: n.fileID, allocBytes: n.rawAlloc, sharesStorage: shares))
            }
            for id in loose { add([id], shares: false) }
            for (key, names) in keyed { add(names, shares: shared.contains(key) || names.count > 1) }
            buckets.append(bucket.sorted { units[$0].path < units[$1].path })
        }
        return buckets
    }

    /// `FileTree.path(of:)` on a value snapshot, bounded against malformed parent links.
    private static func path(of id: NodeID, in nodes: [Node], rootPath: String) -> String {
        if id == FileTree.root { return rootPath }
        var parts: [String] = []
        var cur = id
        var budget = nodes.count
        while cur != FileTree.root, cur >= 0, Int(cur) < nodes.count, budget > 0 {
            parts.append(nodes[Int(cur)].name)
            cur = nodes[Int(cur)].parent
            budget -= 1
        }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return base + "/" + parts.reversed().joined(separator: "/")
    }

    // MARK: Stage 2: edges

    private struct EdgeKey: Hashable { var head: UInt64; var tail: UInt64 }

    /// Hashes head and tail of every unit in the bucket and returns the subgroups of 2+ with equal
    /// hashes, in path order. On cancel, returns the subgroups among the units hashed so far and
    /// counts the rest as pending.
    private static func edgeStage(_ bucket: [Int], edgeBytes: Int, state: inout State, pending: inout Int,
                                  isCancelled: () -> Bool, progress: (DuplicateProgress) -> Void,
                                  open: DuplicatesIO.Opener) -> [[Int]] {
        progress(DuplicateProgress(stage: .edges, filesDone: 0, filesTotal: bucket.count, bytesRead: state.bytesRead))
        var byKey: [EdgeKey: [Int]] = [:]
        var order: [EdgeKey] = []
        for (i, u) in bucket.enumerated() {
            if isCancelled() {
                state.cancelled = true
                pending += bucket.count - i
                break
            }
            let unit = state.units[u]
            let headCount = Int(min(Int64(edgeBytes), unit.size))
            let tailStart = max(0, unit.size - Int64(edgeBytes))
            do {
                let (key, sample) = try DuplicatesIO.withFile(unit.path, size: unit.size, fileID: unit.fileID,
                                                              expected: unit.sample, open: open) { h in
                    EdgeKey(head: try DuplicatesIO.hashRange(h, start: 0, count: headCount, path: unit.path,
                                                             bytesRead: &state.bytesRead),
                            tail: try DuplicatesIO.hashRange(h, start: tailStart, count: Int(unit.size - tailStart),
                                                             path: unit.path, bytesRead: &state.bytesRead))
                }
                state.units[u].sample = sample
                if byKey[key] == nil { order.append(key) }
                byKey[key, default: []].append(u)
            } catch let f as DuplicatesIO.Failure {
                state.skip(u, f)
            } catch {
                state.skip(u, DuplicatesIO.Failure(kind: .unreadable, path: unit.path, detail: "\(error)"))
            }
            progress(DuplicateProgress(stage: .edges, filesDone: i + 1, filesTotal: bucket.count,
                                       bytesRead: state.bytesRead))
        }
        return order.compactMap { byKey[$0]!.count >= 2 ? byKey[$0]! : nil }
    }

    // MARK: Stage 3: bytes

    private enum Comparison { case same, differ }

    /// Confirms each edge subgroup byte by byte. Every member is compared with one reference; the
    /// ones that differ form the next round with a new reference. A skipped reference restarts the
    /// round without it, so a `.bytes` group always matched one surviving reference to EOF.
    // ponytail: reference re-read per member, multi-way chunk partition if large groups dominate
    private static func byteStage(_ subgroups: [[Int]], chunkBytes: Int, state: inout State,
                                  isCancelled: () -> Bool, progress: (DuplicateProgress) -> Void,
                                  open: DuplicatesIO.Opener) {
        let total = subgroups.reduce(0) { $0 + $1.count }
        var done = 0
        func report() {
            progress(DuplicateProgress(stage: .bytes, filesDone: done, filesTotal: total, bytesRead: state.bytesRead))
        }
        report()
        for sub in subgroups {
            if state.cancelled { state.addGroup(sub, stage: .edges); continue }
            var remaining = sub
            rounds: while remaining.count >= 2 {
                let ref = remaining[0]
                var matched: [Int] = []
                var differ: [Int] = []
                for (k, m) in remaining.dropFirst().enumerated() {
                    do {
                        switch try compare(ref, m, chunkBytes: chunkBytes, state: &state,
                                           isCancelled: isCancelled, open: open) {
                        case .same: matched.append(m)
                        case .differ: differ.append(m)
                        }
                    } catch is Cancelled {
                        state.cancelled = true
                        state.addGroup(remaining, stage: .edges)
                        break rounds
                    } catch {
                        let f = error as? DuplicatesIO.Failure
                            ?? DuplicatesIO.Failure(kind: .unreadable, path: state.units[m].path, detail: "\(error)")
                        let failed = f.path == state.units[ref].path ? ref : m
                        state.skip(failed, f)
                        done += 1
                        if failed == ref {
                            // Members that matched this reference are no longer proven: start over.
                            remaining = remaining.filter { !state.units[$0].skipped }
                            if remaining.count < 2 { done += remaining.count }
                            report()
                            continue rounds
                        }
                    }
                    if k == remaining.count - 2 {
                        // Round over: the reference and its matches are settled, the rest go again.
                        if !matched.isEmpty { state.addGroup([ref] + matched, stage: .bytes) }
                        done += 1 + matched.count
                        remaining = differ
                        if remaining.count < 2 { done += remaining.count }
                    }
                    report()
                }
            }
        }
    }

    /// Reads `ref` and `m` side by side in `chunkBytes` reads until they differ or reach EOF.
    /// Throws `Failure` (attributed by path) or `Cancelled`.
    private static func compare(_ ref: Int, _ m: Int, chunkBytes: Int, state: inout State,
                                isCancelled: () -> Bool, open: DuplicatesIO.Opener) throws -> Comparison {
        if isCancelled() { throw Cancelled() }
        let r = state.units[ref], u = state.units[m]
        let ((result, memberSample), refSample) = try DuplicatesIO.withFile(
            r.path, size: r.size, fileID: r.fileID, expected: r.sample, open: open
        ) { hr in
            if isCancelled() { throw Cancelled() }
            return try DuplicatesIO.withFile(u.path, size: u.size, fileID: u.fileID, expected: u.sample,
                                             open: open) { hm -> Comparison in
                var offset: Int64 = 0
                while offset < r.size {
                    if offset > 0 && isCancelled() { throw Cancelled() }
                    let n = Int(min(Int64(chunkBytes), r.size - offset))
                    let a = try DuplicatesIO.readExactly(hr, count: n, path: r.path, bytesRead: &state.bytesRead)
                    let b = try DuplicatesIO.readExactly(hm, count: n, path: u.path, bytesRead: &state.bytesRead)
                    if a != b { return .differ }
                    offset += Int64(n)
                }
                return .same
            }
        }
        state.units[ref].sample = refSample
        state.units[m].sample = memberSample
        return result
    }
}
