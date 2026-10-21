// TreeDiff.compare body. Directories are matched by path, done incrementally: the roots match, and a
// directory matches the same-named directory under its parent's match. That is exactly path equality
// below the root, but hashes one name per directory instead of building 2 × 500k path strings.
// Paths are built only for the entries that make it into the report.

import Foundation

enum DiffEngine {
    private struct DirKey: Hashable {
        var parent: Int32
        var name: String
    }

    /// A directory-level candidate: index into new (added / changed) or old (removed) dirs.
    private struct Candidate {
        var kind: DirChange.Kind
        var index: Int32
        var delta: Int64
    }

    static func compare(_ old: TreeSummary, _ new: TreeSummary, topN: Int, minDelta: Int64) -> DiffReport {
        let od = old.dirs, nd = new.dirs
        var report = DiffReport(rootPath: new.rootPath, fromDate: old.createdAt, toDate: new.createdAt,
                                totalBefore: od.first?.totalAlloc ?? 0, totalAfter: nd.first?.totalAlloc ?? 0,
                                grown: [], shrunk: [], files: [])
        report.rootStatusBefore = od.first?.status ?? .unavailable
        report.rootStatusAfter = nd.first?.status ?? .unavailable
        let limit = max(0, topN)
        let threshold = max(0, minDelta)

        // Match new dirs to old dirs.
        var newToOld = [Int32](repeating: -1, count: nd.count)
        var oldToNew = [Int32](repeating: -1, count: od.count)
        if !od.isEmpty && !nd.isEmpty {
            var oldIndex: [DirKey: Int32] = [:]
            oldIndex.reserveCapacity(od.count)
            for i in 1..<od.count { oldIndex[DirKey(parent: od[i].parent, name: od[i].name)] = Int32(i) }
            newToOld[0] = 0; oldToNew[0] = 0
            for i in 1..<nd.count {
                let op = newToOld[Int(nd[i].parent)]
                guard op >= 0, let o = oldIndex[DirKey(parent: op, name: nd[i].name)] else { continue }
                newToOld[i] = o
                oldToNew[Int(o)] = Int32(i)
            }
        }

        // Largest same-sign change among each matched new dir's direct children: matched or added
        // children from the new side, removed children from the old side.
        var maxGrow = [Int64](repeating: 0, count: nd.count)
        var maxShrink = [Int64](repeating: 0, count: nd.count)     // magnitude
        var candidates: [Candidate] = []
        func note(parent p: Int, _ d: Int64) {
            if d > 0 { maxGrow[p] = max(maxGrow[p], d) } else if d < 0 { maxShrink[p] = max(maxShrink[p], -d) }
        }
        func reportable(_ d: Int64) -> Bool { d != 0 && d.magnitude >= threshold.magnitude }
        for i in nd.indices.dropFirst() {
            let p = Int(nd[i].parent)
            guard newToOld[p] >= 0 else { continue }                   // inside an added subtree
            let o = newToOld[i]
            let d = o >= 0 ? nd[i].totalAlloc - od[Int(o)].totalAlloc : nd[i].totalAlloc
            note(parent: p, d)
            if o < 0 && reportable(d) { candidates.append(Candidate(kind: .added, index: Int32(i), delta: d)) }
        }
        for o in od.indices.dropFirst() where oldToNew[o] < 0 {
            let p = oldToNew[Int(od[o].parent)]
            guard p >= 0 else { continue }                              // inside a removed subtree
            let d = -od[o].totalAlloc
            note(parent: Int(p), d)
            if reportable(d) { candidates.append(Candidate(kind: .removed, index: Int32(o), delta: d)) }
        }
        // Hotspots: changed dirs whose change no single child explains (>= 80%, same sign).
        for i in nd.indices where newToOld[i] >= 0 {
            let d = nd[i].totalAlloc - od[Int(newToOld[i])].totalAlloc
            guard reportable(d) else { continue }
            let child = (d > 0 ? maxGrow[i] : maxShrink[i]).magnitude
            // child >= 80% of |d|, i.e. 5·child >= 4·|d|, without overflow.
            let c5 = child.multipliedFullWidth(by: 5), d4 = d.magnitude.multipliedFullWidth(by: 4)
            let explained = c5.high != d4.high ? c5.high > d4.high : c5.low >= d4.low
            if !explained { candidates.append(Candidate(kind: .changed, index: Int32(i), delta: d)) }
        }

        func change(_ c: Candidate) -> DirChange {
            switch c.kind {
            case .added:
                let n = nd[Int(c.index)]
                return DirChange(path: new.path(ofDir: c.index), kind: .added, before: 0, after: n.totalAlloc,
                                 filesBefore: 0, filesAfter: n.fileCount, uncertain: n.status != .complete)
            case .removed:
                let o = od[Int(c.index)]
                return DirChange(path: old.path(ofDir: c.index), kind: .removed, before: o.totalAlloc, after: 0,
                                 filesBefore: o.fileCount, filesAfter: 0,
                                 uncertain: o.status != .complete || !listedCompletely(c.index, old: old, new: new, oldToNew: oldToNew))
            case .changed:
                let n = nd[Int(c.index)], o = od[Int(newToOld[Int(c.index)])]
                return DirChange(path: new.path(ofDir: c.index), kind: .changed, before: o.totalAlloc,
                                 after: n.totalAlloc, filesBefore: o.fileCount, filesAfter: n.fileCount,
                                 uncertain: o.status != .complete || n.status != .complete)
            }
        }
        // Largest |delta| first; ties by path so the order does not depend on scan order.
        func top(_ list: [Candidate]) -> [DirChange] {
            guard limit > 0 else { return [] }
            let sorted = list.sorted { $0.delta.magnitude > $1.delta.magnitude }
            guard let cut = sorted.prefix(limit).last?.delta.magnitude else { return [] }
            // Keep every tie at the cut so the path tie-break below is honest.
            return sorted.prefix { $0.delta.magnitude >= cut }.map(change)
                .sorted { $0.delta.magnitude != $1.delta.magnitude ? $0.delta.magnitude > $1.delta.magnitude : $0.path < $1.path }
                .prefix(limit).map { $0 }
        }
        report.grown = top(candidates.filter { $0.delta > 0 })
        report.shrunk = top(candidates.filter { $0.delta < 0 })
        report.files = limit > 0 ? fileChanges(old, new, threshold: threshold, oldToNew: oldToNew).prefix(limit).map { $0 } : []
        return report
    }

    /// Big files matched by full path, largest |delta| first.
    private static func fileChanges(_ old: TreeSummary, _ new: TreeSummary, threshold: Int64,
                                    oldToNew: [Int32]) -> [FileChange] {
        let oldFiles = filesByPath(old)
        let newFiles = filesByPath(new)
        var out: [FileChange] = []
        func keep(_ d: Int64) -> Bool { d != 0 && d.magnitude >= threshold.magnitude }
        for (path, after) in newFiles {
            if let before = oldFiles[path]?.alloc {
                let d = after.alloc - before
                if keep(d) { out.append(FileChange(path: path, kind: d > 0 ? .grown : .shrunk, before: before, after: after.alloc)) }
            } else if keep(after.alloc) {
                out.append(FileChange(path: path, kind: .added, before: 0, after: after.alloc))
            }
        }
        for (path, before) in oldFiles where newFiles[path] == nil && keep(before.alloc)
            && listedCompletely(before.dir, old: old, new: new, oldToNew: oldToNew) {
            out.append(FileChange(path: path, kind: .removed, before: before.alloc, after: 0))
        }
        return out.sorted {
            $0.delta.magnitude != $1.delta.magnitude ? $0.delta.magnitude > $1.delta.magnitude : $0.path < $1.path
        }
    }

    /// The nearest old ancestor still matched in the new tree must have been listed completely.
    /// Looking at the root would mark unrelated deletions uncertain whenever another branch is partial.
    private static func listedCompletely(_ oldDir: Int32, old: TreeSummary, new: TreeSummary,
                                         oldToNew: [Int32]) -> Bool {
        guard !oldToNew.isEmpty else { return false }
        var index = Int(oldDir)
        while index > 0 && oldToNew[index] < 0 { index = Int(old.dirs[index].parent) }
        let matched = oldToNew[index]
        return matched >= 0 && new.dirs[Int(matched)].status == .complete
    }

    private static func filesByPath(_ s: TreeSummary) -> [String: (alloc: Int64, dir: Int32)] {
        var dirPaths: [Int32: String] = [:]
        var out: [String: (alloc: Int64, dir: Int32)] = [:]
        out.reserveCapacity(s.bigFiles.count)
        let slashRoot = s.rootPath.hasSuffix("/")
        for f in s.bigFiles {
            let dir: String
            if let cached = dirPaths[f.dir] { dir = cached } else { dir = s.path(ofDir: f.dir); dirPaths[f.dir] = dir }
            let path = f.dir == 0 && slashRoot ? dir + f.name : dir + "/" + f.name
            out[path] = (f.alloc, f.dir)
        }
        return out
    }
}
