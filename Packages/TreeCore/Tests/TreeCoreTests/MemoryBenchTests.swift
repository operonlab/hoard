import Foundation
import XCTest
import TreeCore
#if canImport(Glibc)
import Glibc
#endif

/// Bytes per FileTree node on a synthetic tree shaped like ~/workshop (measured 2026-10-20: 11% dirs;
/// names ≤15 B 46.6%, 16-31 B 30.4%, 32-63 B 22.5%, 64 B+ 0.4%; long names average 29.5 B and 40.4% are
/// distinct; nlink>1 0.13%). Linux only: readings come from /proc/self/status. Skips unless its env
/// vars are set, so the default `swift test` run is unaffected. Run with `swift test -c release`.
///
///   HOARD_BENCH_NODES=<n>          testBuild, testWriteSnapshot (the latter always builds 1,000,000)
///   HOARD_BENCH_SNAPSHOT=<path>    testWriteSnapshot, testRestore; must be under .build/
///   HOARD_BENCH_LABEL / _RUN / _COMMIT   recorded as given ("unset" when missing)
///   HOARD_BENCH_SHORT_NAMES=1      every name ≤15 B (name-heap share)
///   HOARD_BENCH_NO_DEDUP=1         no hardlinks or clones (holders share)
///   HOARD_BENCH_RESERVE=1          testBuild calls `tree.reserveCapacity(nodes:)` right after init
///
/// Secondary: `steady_trim_bpn` / `restore_trim_bpn` repeat the readings, before and after, each right
/// after glibc `malloc_trim(0)` hands freed pages back, so freed memory glibc keeps resident (e.g. a
/// dropped table below its dynamic mmap threshold) does not count. Taken after the primary reading
/// at each point; "unavailable" off glibc.
///
/// One `MEMBENCH {json}` line per run on stdout, also appended to bench-results/c3-memory.jsonl.
final class MemoryBenchTests: XCTestCase {
    private static let seed: UInt64 = 0xD15C
    private static let env = ProcessInfo.processInfo.environment

    // MARK: Readings

    private struct Status {
        var rss: Int?
        var hwm: Int?
        var anon: Int?
    }

    /// glibc `malloc_trim(0)`, looked up at run time (malloc.h is not in the Glibc module).
    private func trimHeap() -> Bool {
        #if canImport(Glibc)
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "malloc_trim") else { return false }
        typealias Trim = @convention(c) (Int) -> Int32
        _ = unsafeBitCast(symbol, to: Trim.self)(0)
        return true
        #else
        return false
        #endif
    }

    private func readKiB(_ text: String, _ field: String) -> Int? {
        for line in text.split(separator: "\n") where line.hasPrefix(field + ":") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let kib = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            return kib * 1024
        }
        return nil
    }

    private func status() throws -> Status {
        guard let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else {
            throw XCTSkip("unavailable: cannot read /proc/self/status")
        }
        let normalized = text.replacingOccurrences(of: "\t", with: " ")
        return Status(rss: readKiB(normalized, "VmRSS"), hwm: readKiB(normalized, "VmHWM"),
                      anon: readKiB(normalized, "RssAnon"))
    }

    /// Resets VmHWM to the current RSS (Linux ≥ 4.0), so the peak is measured from the baseline.
    private func resetHighWaterMark() -> Bool {
        guard let handle = FileHandle(forWritingAtPath: "/proc/self/clear_refs") else { return false }
        defer { try? handle.close() }
        do { try handle.write(contentsOf: Data("5".utf8)) } catch { return false }
        return true
    }

    private func readNumber(_ path: String) -> Int? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != "max", let n = Int(value), n < (1 << 62) else { return nil }
        return n
    }

    /// min(MemAvailable, cgroup headroom); "meminfo-only" when no cgroup file can be read.
    private func memoryLimit() -> (bytes: Int?, source: String) {
        var available: Int?
        if let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) {
            available = readKiB(text.replacingOccurrences(of: "\t", with: " "), "MemAvailable")
        }
        var headroom: Int?
        var sawCgroup = false
        for (maxPath, currentPath) in [("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory.current"),
                                       ("/sys/fs/cgroup/memory/memory.limit_in_bytes", "/sys/fs/cgroup/memory/memory.usage_in_bytes")] {
            guard FileManager.default.isReadableFile(atPath: maxPath),
                  let current = readNumber(currentPath) else { continue }
            sawCgroup = true
            if let limit = readNumber(maxPath) { headroom = limit - current }
            break
        }
        let bytes = [available, headroom].compactMap { $0 }.min()
        return (bytes, sawCgroup ? "cgroup" : "meminfo-only")
    }

    private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    // MARK: Generator

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// Everything the build loop needs, allocated before the baseline reading. Entry i becomes node i + 1.
    private final class Plan {
        var parent: [Int32] = []
        var kind: [UInt8] = []          // 0 file, 1 dir, 2 hardlink, 3 clone
        var dedupID: [UInt32] = []
        var nameStart: [UInt32] = []
        var nameLength: [UInt16] = []
        var pool: [UInt8] = []
        var dirs = 0
        var longSlots = 0
        var longDistinct = 0
        var longBytes = 0
        var multibyte = 0
    }

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789_-.".utf8)

    private func makePlan(entries n: Int, shortNames: Bool, noDedup: Bool) -> Plan {
        var rng = SplitMix64(state: Self.seed)
        let plan = Plan()
        plan.parent.reserveCapacity(n); plan.kind.reserveCapacity(n); plan.dedupID.reserveCapacity(n)
        plan.nameStart.reserveCapacity(n); plan.nameLength.reserveCapacity(n)

        // Breadth-first: each folder in id order gets 1...19 children, 11% of them folders. The last child
        // of a batch becomes a folder when no folder is pending, so the walk never runs dry.
        var queue: [Int32] = [0]
        var next = 0
        while plan.parent.count < n {
            let p = queue[next]
            next += 1
            let k = 1 + rng.below(19)
            for c in 0..<k where plan.parent.count < n {
                let id = Int32(plan.parent.count + 1)
                let isDir = rng.unit() < 0.11 || (c == k - 1 && next >= queue.count)
                plan.parent.append(p)
                plan.kind.append(isDir ? 1 : 0)
                if isDir { queue.append(id); plan.dirs += 1 }
            }
            if next >= queue.count { queue.append(0) }
        }

        // Dedup: 0.5% of files in hardlink pairs, 0.5% in clone pairs, 0.25% singletons of each kind.
        var nextGroup: UInt32 = 1
        plan.dedupID = [UInt32](repeating: 0, count: n)
        if !noDedup {
            var openHard: UInt32 = 0, openClone: UInt32 = 0
            for i in 0..<n where plan.kind[i] == 0 {
                let r = rng.unit()
                if r < 0.005 {
                    plan.kind[i] = 2
                    if openHard == 0 { openHard = nextGroup; nextGroup += 1; plan.dedupID[i] = openHard }
                    else { plan.dedupID[i] = openHard; openHard = 0 }
                } else if r < 0.010 {
                    plan.kind[i] = 3
                    if openClone == 0 { openClone = nextGroup; nextGroup += 1; plan.dedupID[i] = openClone }
                    else { plan.dedupID[i] = openClone; openClone = 0 }
                } else if r < 0.0125 {
                    plan.kind[i] = 2; plan.dedupID[i] = nextGroup; nextGroup += 1
                } else if r < 0.015 {
                    plan.kind[i] = 3; plan.dedupID[i] = nextGroup; nextGroup += 1
                }
            }
        }

        // Names. Short: 1...15 B, one per entry. Long: a pool of D = 40.4% of the long slots, each used
        // once, the other long slots drawing from it at random. Pool lengths 16-31 / 32-63 / 64-127 B in
        // the ratio 30.4 : 22.5 : 0.4, skewed low (u^2.3) so the mean lands near 29.5 B.
        plan.pool.reserveCapacity(n * 16)
        func appendName(_ length: Int) -> UInt32 {
            let start = UInt32(plan.pool.count)
            for _ in 0..<length { plan.pool.append(Self.alphabet[rng.below(Self.alphabet.count)]) }
            if length >= 2 && rng.unit() < 0.02 {
                let at = Int(start) + rng.below(length - 1)
                plan.pool[at] = 0xC3; plan.pool[at + 1] = 0xA9  // é
                plan.multibyte += 1
            }
            return start
        }
        var isLong = [Bool](repeating: false, count: n)
        for i in 0..<n { isLong[i] = !shortNames && rng.unit() >= 0.466 }
        let longCount = isLong.lazy.filter { $0 }.count
        let distinct = Int((Double(longCount) * 0.404).rounded())
        var longPool: [(UInt32, UInt16)] = []
        longPool.reserveCapacity(distinct)
        for _ in 0..<distinct {
            let r = rng.unit() * (30.4 + 22.5 + 0.4)
            let (lo, hi) = r < 30.4 ? (16, 31) : r < 52.9 ? (32, 63) : (64, 127)
            let length = lo + min(hi - lo, Int(Double(hi - lo + 1) * pow(rng.unit(), 2.3)))
            longPool.append((appendName(length), UInt16(length)))
        }
        var slots = [Int32](repeating: 0, count: longCount)
        for j in 0..<longCount { slots[j] = Int32(j < distinct ? j : rng.below(distinct)) }
        for j in stride(from: longCount - 1, to: 0, by: -1) { slots.swapAt(j, rng.below(j + 1)) }
        var slot = 0
        for i in 0..<n {
            if isLong[i] {
                let (start, length) = longPool[Int(slots[slot])]
                slot += 1
                plan.nameStart.append(start); plan.nameLength.append(length)
                plan.longBytes += Int(length)
            } else {
                let length = 1 + rng.below(15)
                plan.nameStart.append(appendName(length)); plan.nameLength.append(UInt16(length))
            }
        }
        plan.longSlots = longCount
        plan.longDistinct = distinct
        return plan
    }

    private struct BuildResult {
        var tree: FileTree
        var before: Status
        var after: Status
        var buildSeconds: Double
        var recomputeSeconds: Double
    }

    /// Fresh String per entry (as the scanner allocates names), then ScanEntry, then addChild.
    private func build(_ plan: Plan, entries n: Int, before: Status, reserve: Bool) -> BuildResult {
        let t0 = now()
        let tree = FileTree(rootPath: "/bench", device: 1, rootModTime: 1_600_000_000)
        if reserve { tree.reserveCapacity(nodes: n + 1) }
        plan.pool.withUnsafeBufferPointer { pool in
            for i in 0..<n {
                let start = Int(plan.nameStart[i])
                let name = String(decoding: UnsafeBufferPointer(rebasing: pool[start..<(start + Int(plan.nameLength[i]))]),
                                  as: UTF8.self)
                let kind = plan.kind[i]
                let size = kind == 1 ? 0 : Int64((UInt64(i) &* 0x9E37_79B9_7F4A_7C15) >> 50) * 4096
                var entry = ScanEntry(name: name, isDirectory: kind == 1, allocSize: size, logicalSize: max(0, size - Int64(i % 4096)),
                                      fileID: UInt64(i + 1), modTime: 1_600_000_000 + Int64(i % 86_400),
                                      accessTime: 1_700_000_000 + Int64(i % 3600), device: 1)
                if kind == 2 { entry.fileID = (1 << 40) | UInt64(plan.dedupID[i]); entry.linkCount = 2 }
                if kind == 3 { entry.cloneID = UInt64(plan.dedupID[i]); entry.sharesAllBlocks = true }
                tree.addChild(of: plan.parent[i], entry: entry)
            }
        }
        let t1 = now()
        tree.recomputeAggregates()
        let t2 = now()
        return BuildResult(tree: tree, before: before, after: Status(), buildSeconds: t1 - t0, recomputeSeconds: t2 - t1)
    }

    // MARK: Output

    private func packageRoot(_ file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    private func json(_ value: Any?) -> String {
        switch value {
        case nil: return "\"unavailable\""
        case let s as String: return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case let d as Double: return String(format: "%.4f", d)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        default: return "\"\(value!)\""
        }
    }

    private func emit(_ fields: [(String, Any?)]) throws {
        let out = packageRoot().appendingPathComponent("bench-results/c3-memory.jsonl")
        let all = fields + [("jsonl", out.path)]
        let line = "{" + all.map { json($0.0) + ":" + json($0.1) }.joined(separator: ",") + "}"
        print("MEMBENCH " + line)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: out.path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: record)
        } else {
            try record.write(to: out)
        }
    }

    private func common(n: Int, limitSource: String) -> [(String, Any?)] {
        [("label", Self.env["HOARD_BENCH_LABEL"] ?? "unset"),
         ("run", Self.env["HOARD_BENCH_RUN"].flatMap { Int($0) }.map { $0 as Any } ?? "unset"),
         ("commit", Self.env["HOARD_BENCH_COMMIT"] ?? "unset"),
         ("method", "proc-status"), ("n", n), ("seed", Int(Self.seed)), ("limit_source", limitSource),
         ("stride", MemoryLayout<Node>.stride)]
    }

    private func perNode(_ a: Int?, _ b: Int?, _ n: Int) -> Double? {
        guard let a, let b else { return nil }
        return Double(a - b) / Double(n)
    }

    private func snapshotURL() throws -> URL {
        guard let path = Self.env["HOARD_BENCH_SNAPSHOT"], !path.isEmpty else {
            throw XCTSkip("HOARD_BENCH_SNAPSHOT not set")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathComponents.contains(".build") else {
            XCTFail("HOARD_BENCH_SNAPSHOT must be under .build/: \(url.path)")
            throw XCTSkip("snapshot path outside .build/")
        }
        return url
    }

    /// Builds the plan, takes the baseline, builds the tree, takes the after reading.
    private func measureBuild(entries requested: Int, forceN: Int? = nil, reserve: Bool = false) throws
        -> (fields: [(String, Any?)], tree: FileTree, plan: Plan) {
        let limit = memoryLimit()
        var n = forceN ?? requested
        if forceN == nil, let bytes = limit.bytes, bytes < 2 << 30 { n = min(n, 1_000_000) }
        let shortNames = Self.env["HOARD_BENCH_SHORT_NAMES"] == "1"
        let noDedup = Self.env["HOARD_BENCH_NO_DEDUP"] == "1"
        let plan = makePlan(entries: n, shortNames: shortNames, noDedup: noDedup)
        let before = try status()
        let trimmedBefore = trimHeap() ? try status() : nil
        let hwmReset = resetHighWaterMark()
        let hwmAfterReset = try status().hwm
        var result = build(plan, entries: n, before: before, reserve: reserve)
        result.after = try status()
        let end = try status()
        let trimmed = trimHeap() ? try status() : nil
        let fields: [(String, Any?)] = common(n: n, limitSource: limit.source) + [
            ("capacity", result.tree.nodes.capacity),
            ("rss_before", before.rss), ("rss_anon_before", before.anon), ("hwm_before", before.hwm),
            ("hwm_reset", hwmReset), ("hwm_after_reset", hwmAfterReset),
            ("rss_after", result.after.rss), ("rss_anon_after", result.after.anon), ("hwm", end.hwm),
            ("steady_bpn", perNode(result.after.rss, before.rss, n)),
            ("peak_bpn", perNode(end.hwm, before.rss, n)),
            ("anon_bpn", perNode(result.after.anon, before.anon, n)),
            ("rss_after_trim", trimmed?.rss), ("rss_before_trim", trimmedBefore?.rss),
            ("steady_trim_bpn", perNode(trimmed?.rss, trimmedBefore?.rss, n)),
            ("build_s", result.buildSeconds), ("recompute_s", result.recomputeSeconds),
            ("short_names", shortNames), ("no_dedup", noDedup), ("reserve", reserve),
            ("gen_dirs", plan.dirs), ("gen_long_slots", plan.longSlots), ("gen_long_distinct", plan.longDistinct),
            ("gen_long_avg_bytes", plan.longSlots > 0 ? Double(plan.longBytes) / Double(plan.longSlots) : nil),
            ("gen_multibyte", plan.multibyte),
        ]
        return (fields, result.tree, plan)
    }

    // MARK: Tests

    func testBuild() throws {
        guard let value = Self.env["HOARD_BENCH_NODES"], let requested = Int(value), requested > 0 else {
            throw XCTSkip("HOARD_BENCH_NODES not set")
        }
        _ = try status()
        let (fields, tree, plan) = try measureBuild(entries: requested, reserve: Self.env["HOARD_BENCH_RESERVE"] == "1")
        try emit(fields)
        withExtendedLifetime((tree, plan)) {}
    }

    func testWriteSnapshot() throws {
        guard let value = Self.env["HOARD_BENCH_NODES"], Int(value) != nil else {
            throw XCTSkip("HOARD_BENCH_NODES not set")
        }
        let url = try snapshotURL()
        _ = try status()
        let (fields, tree, plan) = try measureBuild(entries: 1_000_000, forceN: 1_000_000)
        let meta = SnapshotMeta(rootPath: tree.rootPath, device: tree.device, createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                scanSeconds: 0, lastEventId: 0, eventsUUID: nil)
        let t0 = now()
        try Snapshot.write(tree, meta: meta, to: url)
        let writeSeconds = now() - t0
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        try emit(fields + [("write_s", writeSeconds), ("file_bytes", size), ("snapshot", url.path)])
        withExtendedLifetime((tree, plan)) {}
    }

    func testRestore() throws {
        let url = try snapshotURL()
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no snapshot at \(url.path)") }
        let limit = memoryLimit()
        _ = try status()
        let before = try status()
        let trimmedBefore = trimHeap() ? try status() : nil
        let hwmReset = resetHighWaterMark()
        let t0 = now()
        let (tree, _) = try Snapshot.read(from: url)
        let readSeconds = now() - t0
        let after = try status()
        let trimmed = trimHeap() ? try status() : nil
        let n = tree.nodeCount
        try emit(common(n: n, limitSource: limit.source) + [
            ("capacity", tree.nodes.capacity),
            ("rss_before", before.rss), ("rss_anon_before", before.anon), ("hwm_before", before.hwm),
            ("hwm_reset", hwmReset),
            ("rss_after", after.rss), ("rss_anon_after", after.anon), ("hwm", after.hwm),
            ("steady_bpn", perNode(after.rss, before.rss, n)),
            ("peak_bpn", perNode(after.hwm, before.rss, n)),
            ("read_s", readSeconds), ("restore_bpn", perNode(after.anon, before.anon, n)),
            ("restore_trim_bpn", perNode(trimmed?.anon, trimmedBefore?.anon, n)),
            ("snapshot", url.path),
        ])
        withExtendedLifetime(tree) {}
    }
}
