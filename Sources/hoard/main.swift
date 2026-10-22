import Darwin
import CoreFoundation
import Foundation
import ScanCore

enum CLIError: Error, CustomStringConvertible {
    case usage(String), runtime(String)
    var description: String { switch self { case .usage(let s), .runtime(let s): return s } }
}
private let schema = "hoard/1"
let supportedCommands = ["scan", "top", "stale", "types", "history", "diff", "snapshot", "suggest", "dupes", "similar", "hidden", "apps", "uninstall-plan", "protect", "protected", "guardian", "cleanup-log", "doctor", "completion", "mcp"]
private let iso = ISO8601DateFormatter()
private func status(_ s: ScanStatus) -> String {
    switch s { case .complete: return "complete"; case .partial: return "partial"; case .unavailable: return "unavailable" }
}
private func absolute(_ input: String) -> String {
    let expanded = input == "~" ? NSHomeDirectory() : (input.hasPrefix("~/") ? NSHomeDirectory() + String(input.dropFirst()) : input)
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}
private func int(_ raw: String, _ flag: String, min: Int = 0) throws -> Int {
    guard let n = Int(raw), n >= min else { throw CLIError.usage("\(flag) requires integer >= \(min)") }
    return n
}
private func bytes(_ raw: String) throws -> Int64 {
    let s = raw.uppercased()
    let units: [(String, Int64)] = [("TIB", 1_099_511_627_776), ("GIB", 1_073_741_824), ("MIB", 1_048_576), ("KIB", 1_024),
                                   ("TB", 1_000_000_000_000), ("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1_000), ("B", 1)]
    let unit = units.first { s.hasSuffix($0.0) }
    let digits = unit.map { String(s.dropLast($0.0.count)) } ?? s
    guard let n = Int64(digits), n >= 0 else { throw CLIError.usage("invalid size: \(raw)") }
    let (value, overflow) = n.multipliedReportingOverflow(by: unit?.1 ?? 1)
    guard !overflow else { throw CLIError.usage("size too large: \(raw)") }
    return value
}
private struct Args {
    let command: String, path: String
    var json = false, strict = false, files = false, dirs = false, spotlight = true, save = false, sequential = false
    var lock = false, guarded = false, once = false
    var limit = 20, days = 180, threads = ScanOptions().threads
    var depth: Int?, from: String?, to = "now", note: String?
    var minSize: Int64 = 50_000_000
    var similarThreshold: Float = SimilarOptions().threshold
    var timeout: TimeInterval = 120
    var deadline: Date?
    /// Recorded as the protection's creator. Set by the MCP server; no CLI flag reaches it.
    var by = "cli"
    static let dataVolume = "/System/Volumes/Data"
    init(_ args: [String]) throws {
        let usage = "usage: hoard <scan|top|stale|types|history|diff|snapshot|suggest|dupes|similar> <path> [options], hoard hidden [<path>], hoard apps [--limit N], hoard uninstall-plan <app path|bundle id|app name> [--json], hoard protect <path> (--lock | --guard) [--note <text>], hoard protected [<path>], hoard guardian [--once], hoard cleanup-log [--limit N] [--json], hoard doctor [--json], hoard completion <zsh|bash|fish>, or hoard mcp"
        guard let first = args.first else { throw CLIError.usage(usage) }
        command = first
        guard supportedCommands.contains(command) else { throw CLIError.usage("unknown command: \(command)") }
        if command == "suggest" || command == "dupes" { minSize = 1_048_576 }
        if command == "similar" { minSize = SimilarOptions().minSize }
        var seen = Set<String>(), i = 1
        if command == "guardian" || command == "apps" || command == "cleanup-log" || command == "doctor" || (["protected", "hidden"].contains(command) && (args.count < 2 || args[1].hasPrefix("--"))) {
            path = command == "hidden" ? Self.dataVolume : ""
        } else {
            guard args.count >= 2 else { throw CLIError.usage(usage) }
            // "/" is the read-only system volume; the disk people mean is the data volume. Read through
            // "/", the data volume is counted twice: under /System/Volumes/Data and through the firmlinks.
            // Protection keeps the path as given: it records system paths (`PathForms.systemPath`).
            let given = command == "uninstall-plan" && !args[1].hasPrefix("/") && !args[1].hasPrefix("~")
                ? args[1] : absolute(args[1])
            let literal = ["uninstall-plan", "protect", "protected", "snapshot"].contains(command)
            path = given == "/" && !literal ? Self.dataVolume : given; i = 2
        }
        while i < args.count {
            let flag = args[i]
            guard seen.insert(flag).inserted else { throw CLIError.usage("duplicate option: \(flag)") }
            func next() throws -> String { i += 1; guard i < args.count else { throw CLIError.usage("missing value for \(flag)") }; return args[i] }
            switch flag {
            case "--json": json = true
            case "--strict" where command != "cleanup-log" && command != "doctor": strict = true
            case "--top" where command == "scan", "--limit" where ["top", "stale", "types", "suggest", "dupes", "similar", "apps", "cleanup-log"].contains(command): limit = try int(next(), flag)
            case "--threads" where command == "scan": threads = try int(next(), flag, min: 1)
            case "--sequential" where command == "scan": sequential = true
            case "--save" where command == "scan": save = true
            case "--files" where command == "top": files = true
            case "--dirs" where command == "top": dirs = true
            case "--depth" where command == "top": depth = try int(next(), flag)
            case "--days" where command == "stale":
                days = try int(next(), flag)
                guard days <= Int64.max / 86_400 else { throw CLIError.usage("--days is too large") }
            case "--min-size" where ["stale", "suggest", "dupes", "similar"].contains(command): minSize = try bytes(next())
            case "--threshold" where command == "similar":
                guard let value = Float(try next()), value.isFinite, value >= 0 else { throw CLIError.usage("--threshold requires a non-negative finite number") }
                similarThreshold = value
            case "--timeout" where command == "dupes" || command == "similar":
                guard let value = TimeInterval(try next()), value.isFinite, value >= 0 else { throw CLIError.usage("--timeout requires non-negative seconds") }
                timeout = value
            case "--no-spotlight" where command == "stale": spotlight = false
            case "--from" where command == "diff": from = try next()
            case "--to" where command == "diff": to = try next()
            case "--lock" where command == "protect": lock = true
            case "--guard" where command == "protect": guarded = true
            case "--note" where command == "protect": note = try next()
            case "--once" where command == "guardian": once = true
            default: throw CLIError.usage("unknown option for \(command): \(flag)")
            }
            i += 1
        }
        if command == "protect" && lock == guarded { throw CLIError.usage("protect requires exactly one of --lock or --guard") }
        if command == "cleanup-log" && limit > 1000 { throw CLIError.usage("--limit must be at most 1000") }
        if files && dirs { throw CLIError.usage("choose --files or --dirs") }
        if files && depth != nil { throw CLIError.usage("--depth applies to folders") }
        if ProcessInfo.processInfo.environment["_HOARD_MCP_CHILD"] == "1",
           let raw = ProcessInfo.processInfo.environment["_HOARD_MCP_DEADLINE"],
           let seconds = TimeInterval(raw), seconds.isFinite {
            deadline = Date(timeIntervalSince1970: seconds)
        }
    }
}
private final class ResultCapture {
    var value: [String: Any]?
}
private func jsonText(_ out: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
}
private func emit(_ out: [String: Any], _ json: Bool, to capture: ResultCapture? = nil, human: () -> Void) throws {
    if let capture { capture.value = out }
    else if json { print(try jsonText(out)) }
    else { human() }
}
private func fmt(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
private func knownBytes(_ value: Int64, _ state: ScanStatus) -> Any {
    state == .unavailable ? NSNull() : value as Any
}
private func displayBytes(_ value: Int64, _ state: ScanStatus) -> String {
    state == .unavailable ? "unknown" : fmt(value)
}
private func originLabel(_ source: String, _ age: TimeInterval?) -> String {
    age.map { String(format: "%@, age %.0fs", source, $0) } ?? "\(source), age n/a"
}
private func item(_ tree: FileTree, _ id: NodeID) -> [String: Any] {
    let n = tree[id]
    return ["path": tree.path(of: id), "bytes": knownBytes(n.isDirectory ? n.totalAlloc : n.ownAlloc, n.status),
            "files": n.fileCount, "is_dir": n.isDirectory, "scan_status": status(n.status)]
}
private func base(_ args: Args, _ tree: FileTree, _ source: String, _ age: TimeInterval?) -> [String: Any] {
    let r = tree[FileTree.root]
    return ["schema": schema, "command": args.command, "path": tree.rootPath, "source": source,
            "snapshot_age_seconds": age.map { $0 as Any } ?? NSNull(), "scan_status": status(r.status),
            "total_alloc": knownBytes(r.totalAlloc, r.status), "total_logical": knownBytes(r.totalLogical, r.status),
            "files": r.fileCount, "dirs": r.dirCount]
}
private func open(_ args: Args) throws -> (FileTree, String, TimeInterval?) {
    // Match IncrementalSession's root/device/FSEvents UUID guard. Read-only queries
    // do not need its write-back step after a fallback scan.
    let url = Snapshot.defaultURL(forRoot: args.path)
    if let (tree, meta) = try? Snapshot.read(from: url) {
        var st = stat()
        if lstat(args.path, &st) == 0,
           tree.rootPath == args.path, tree.device == st.st_dev,
           let uuid = LiveUpdater.eventsUUID(forDevice: st.st_dev),
           meta.eventsUUID == uuid, meta.lastEventId != 0 {
            // A snapshot is the state when it was saved. Replay what changed since, so the answer is
            // about now; if the journal cannot cover the gap in time, scan instead and say why.
            let available = min(30, max(0, args.deadline?.timeIntervalSinceNow ?? 30))
            // A snapshot saved after live updates may not know how long its scan took (0). Then bound the
            // replay by what scanning this many nodes takes: ~5-6 µs a node measured here, 8 µs for
            // margin. Waiting the full 30 s first made a 5 s scan of ~/workshop take 35 s.
            let expectedScan = meta.scanSeconds > 0 ? meta.scanSeconds : max(2, Double(tree.nodeCount) * 8e-6)
            // The switch compares against the scan time itself (5 µs a node), not the padded budget.
            let scanEstimate = meta.scanSeconds > 0 ? meta.scanSeconds : Double(tree.nodeCount) * 5e-6
            let replay = catchUp(tree, since: meta.lastEventId, timeout: min(available, expectedScan),
                                 available: available, scanEstimate: scanEstimate)
            if replay.finished {
                return (tree, "snapshot+replay", max(0, Date().timeIntervalSince(meta.createdAt)))
            }
            let estimated = meta.scanSeconds > 0 ? "" : ", estimated"
            let reason = replay.projected.map {
                replay.noProgress
                    ? "snapshot replay made no history progress in \(String(format: "%.1f", $0)) s, longer than a scan (\(String(format: "%.2g", scanEstimate)) s\(estimated)); scanning instead\n"
                    : "snapshot replay would take about \(String(format: "%.0f", $0)) s, longer than a scan (\(String(format: "%.2g", scanEstimate)) s\(estimated)); scanning instead\n"
            }
                ?? (replay.timedOut && expectedScan <= available
                    ? "snapshot replay did not finish within its budget; scanning instead\n"
                    : "snapshot could not be brought up to date; scanning instead\n")
            FileHandle.standardError.write(reason.data(using: .utf8)!)
        }
    }
    return (try Scanner().scan(root: args.path, isCancelled: args.deadline.map { deadline in { Date() >= deadline } }), "scan", nil)
}

/// Applies FSEvents recorded after `since` to `tree`. False when the replay did not finish within
/// the timeout, when history delivery exceeds the scan estimate (`projected`: estimated or elapsed
/// delivery time), or when the journal asked for a full rescan.
private func catchUp(_ tree: FileTree, since: UInt64, timeout: TimeInterval = 30,
                     available: TimeInterval, scanEstimate: TimeInterval)
    -> (finished: Bool, timedOut: Bool, projected: TimeInterval?, noProgress: Bool) {
    var finished = false, needsRescan = false
    // The query waits for this replay, so it keeps the foreground class instead of the app's utility.
    let updater = LiveUpdater(tree: tree, scanner: Scanner(), sinceEventId: since, qos: .userInitiated) { summary in
        if summary.requiresFullRescan { needsRescan = true }
    }
    updater.onReplayFinished = { finished = true }
    do { try updater.start() } catch { return (false, false, nil, false) }
    defer { updater.stop() }
    let start = Date(), deadline = start.addingTimeInterval(timeout)
    var deliveryEnd: Date?
    while !finished && !needsRescan {
        if updater.historyProgress == 1, deliveryEnd == nil { deliveryEnd = Date() }
        let cutoff = deliveryEnd.map {
            min($0.addingTimeInterval(scanEstimate), start.addingTimeInterval(max(0, available - scanEstimate)))
        } ?? deadline
        guard Date() < cutoff else { break }
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        // The history arrives at a near-constant rate (by event id). Once its delivery alone is heading
        // past a scan, scanning now beats replaying, and beats waiting out the timeout and scanning then.
        let elapsed = Date().timeIntervalSince(start)
        if !finished, let p = updater.historyProgress {
            if p == 0, elapsed >= max(0.5, scanEstimate) { return (false, false, elapsed, true) }
            if elapsed >= 0.5, p > 0, p < 1, elapsed / p > scanEstimate {
                return (false, false, elapsed / p, false)
            }
        }
    }
    return (finished && !needsRescan, !finished && !needsRescan, nil, false)
}
private func runInsights(_ a: Args, capture: ResultCapture?) throws -> Bool {
    if a.command == "uninstall-plan" {
        let expired = { a.deadline.map { Date() >= $0 } ?? false }
        let report = try AppFootprintAnalyzer.analyze(isCancelled: expired)
        let exact = report.apps.filter { PathForms.systemPath($0.appPath) == PathForms.systemPath(a.path) }
        let bundle = report.apps.filter { $0.bundleID?.localizedCaseInsensitiveCompare(a.path) == .orderedSame }
        let names = report.apps.filter { $0.name.localizedCaseInsensitiveCompare(a.path) == .orderedSame }
        let matches = !exact.isEmpty ? exact : (!bundle.isEmpty ? bundle : names)
        guard !matches.isEmpty else { throw CLIError.usage("找不到 App：\(a.path)") }
        guard matches.count == 1 else {
            throw CLIError.usage("找到多個 App，請指定完整路徑：\(matches.map(\.appPath).joined(separator: "、"))")
        }
        let plan = UninstallPlanner.plan(for: matches[0], in: report)
        let defaults = Set(plan.items.filter(\.selectedByDefault).map(\.path))
        let out: [String: Any] = ["schema": schema, "command": "uninstall-plan", "app_path": plan.appPath,
            "name": plan.name, "bundle_id": plan.bundleID.map { $0 as Any } ?? NSNull(),
            "refusal": plan.refusal.map { $0 as Any } ?? NSNull(),
            "items": plan.items.map { item in
                ["path": item.path, "role": item.role, "kind": item.kind.map { $0.rawValue as Any } ?? NSNull(),
                 "size": sizeObject(item.size), "why": item.why, "selected_by_default": item.selectedByDefault] as [String: Any]
            },
            "kept": plan.kept.map { ["path": $0.path, "why": $0.why] },
            "total_default": sizeObject(plan.total(selected: defaults))]
        try emit(out, a.json, to: capture) {
            print("解除安裝規劃：\(plan.name) — 唯讀，沒有移動任何檔案")
            if let refusal = plan.refusal { print("  \(refusal)") }
            for item in plan.items { print("  \(item.selectedByDefault ? "✓" : "○") \(item.role): \(item.path) — \(item.why)") }
            for kept in plan.kept { print("  保留：\(kept.path) — \(kept.why)") }
        }
        return false
    }
    if a.command == "apps" {
        let expired = { a.deadline.map { Date() >= $0 } ?? false }
        let report: AppFootprintReport?
        do { report = try AppFootprintAnalyzer.analyze(isCancelled: expired) }
        catch ScanError.cancelled { report = nil }
        let apps = Array((report?.apps ?? []).prefix(a.limit)).map { app -> [String: Any] in
            ["path": app.appPath, "link_target": app.linkTarget.map { $0 as Any } ?? NSNull(),
             "name": app.name, "bundle_id": app.bundleID.map { $0 as Any } ?? NSNull(),
             "team_id": app.teamID.map { $0 as Any } ?? NSNull(), "is_apple": app.isApple,
             "app_size": sizeObject(app.appSize), "app_sized_from": app.appSizedFrom.rawValue,
             "data": sizeObject(app.data), "shared_data": sizeObject(app.sharedData),
             "last_used": app.lastUsed.map { iso.string(from: $0) as Any } ?? NSNull(),
             "locations": app.locations.map { location in
                 ["path": location.path, "kind": location.kind.rawValue,
                  "matched_by": String(describing: location.matchedBy), "matched_id": location.matchedID,
                  "size": sizeObject(location.size), "sized_from": location.sizedFrom.rawValue,
                  "is_symlink": location.isSymlink, "shared_with": location.sharedWith] as [String: Any]
             }]
        }
        let incomplete = report.map { !$0.unreadable.isEmpty || $0.apps.contains {
            $0.appSize.status != .complete || $0.data.status != .complete || $0.sharedData.status != .complete
        } } ?? true
        let out: [String: Any] = ["schema": schema, "command": "apps", "status": report == nil ? "cancelled" : (incomplete ? "partial" : "complete"),
                                  "apps": apps, "unreadable": report?.unreadable ?? [], "omitted": max(0, (report?.apps.count ?? 0) - apps.count)]
        try emit(out, a.json, to: capture) {
            print("Apps [\(out["status"]!)]")
            for app in (report?.apps ?? []).prefix(a.limit) {
                let size = { (s: SizeReading) in s.bytes.map { (s.status == .complete ? "" : "≥ ") + fmt($0) } ?? "unknown" }
                print("  \(size(app.appSize)) app + \(size(app.data)) data  \(app.name)\(app.isApple ? " (Apple)" : "")  \(app.appPath)")
            }
        }
        return a.strict && (out["status"] as? String != "complete")
    }
    if a.command == "hidden" {
        let tree: FileTree?
        let source: String
        do { (tree, source, _) = try open(a) }
        catch ScanError.cancelled { tree = nil; source = "scan_cancelled" }
        let facts = tree.map(HiddenSpace.ScanFacts.init(tree:)) ??
            HiddenSpace.ScanFacts(rootPath: a.path, rootStatus: .unavailable, countedBytes: 0, unreadableFolders: 0)
        let report = HiddenSpace.report(facts)
        let lines: [[String: Any]] = report.lines.map { line in
            ["id": line.id, "label": line.label, "bytes": line.bytes.map { $0 as Any } ?? NSNull(),
             "state": line.state.rawValue, "kind": line.kind.rawValue,
             "count": line.count.map { $0 as Any } ?? NSNull(), "how": line.how]
        }
        let unreadable = tree.map { Unreadable.folders(in: $0, under: FileTree.root, limit: 100) }
        let access = FullDiskAccess.current()
        let diagnosed = (unreadable?.paths ?? []).map { path -> (String, UnreadableDiagnosis) in
            (path, Unreadable.diagnose(path, fullDiskAccess: access))
        }
        var byReason: [String: Int] = [:]
        let unreadableRows: [[String: Any]] = diagnosed.map { path, diagnosis in
            byReason[diagnosis.reason.rawValue, default: 0] += 1
            return ["path": path, "reason": diagnosis.reason.rawValue,
                    "errno": diagnosis.errno.map { $0 as Any } ?? NSNull(),
                    "owner": diagnosis.owner.map { $0 as Any } ?? NSNull()]
        }
        let out: [String: Any] = ["schema": schema, "command": "hidden", "path": report.rootPath,
                                  "source": source, "status": tree == nil ? "cancelled" : status(tree![FileTree.root].status),
                                  "mount_point": report.mountPoint.map { $0 as Any } ?? NSNull(),
                                  "covers_volume": report.coversVolume, "lines": lines,
                                  "unreadable_folders": unreadableRows,
                                  "unreadable_total": unreadable.map { $0.total as Any } ?? NSNull(),
                                  "unreadable_by_reason": byReason]
        try emit(out, a.json, to: capture) {
            for line in report.lines { print("\(line.label): \(line.bytes.map(fmt) ?? "unknown") [\(line.state.rawValue)]") }
        }
        return a.strict && (tree == nil || tree?[FileTree.root].status != .complete)
    }
    let tree: FileTree
    let source: String
    let age: TimeInterval?
    do { (tree, source, age) = try open(a) }
    catch ScanError.cancelled {
        let out: [String: Any]
        if a.command == "suggest" {
            out = ["schema": schema, "command": "suggest", "path": a.path, "status": "cancelled",
                   "scan_status": "unavailable", "suggestions": [], "skipped": [], "total_bytes": NSNull(),
                   "total_status": "unavailable", "omitted": 0]
        } else {
            out = ["schema": schema, "command": "dupes", "path": a.path, "status": "cancelled",
                   "scan_status": "unavailable", "tree_status": "unavailable", "groups": [], "skipped": [],
                   "candidate_files": 0, "pending_files": 0, "bytes_read": 0, "omitted": 0]
        }
        try emit(out, a.json, to: capture) { print("\(a.command): cancelled before scan completed") }
        return a.strict
    }
    var out = base(a, tree, source, age)
    if a.command == "suggest" {
        let report = try CleanupSuggester.suggest(in: tree, options: suggestAppsOptions(minBytes: a.minSize, limit: a.limit,
                                                                                        deadline: a.deadline))
        let store = try protectionStore()
        let storeDirectory = ProcessInfo.processInfo.environment["HOARD_PROTECTION_DIR"].map { absolute($0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
                .appendingPathComponent(HoardStorage.folderName).appendingPathComponent("Protection").path
        if FileManager.default.fileExists(atPath: storeDirectory),
           !FileManager.default.fileExists(atPath: storeDirectory + "/registry.lock") {
            throw CLIError.runtime("Protection registry lock is missing; read-only lookup cannot proceed")
        }
        var inside: [String: Int] = [:]
        let rows: [[String: Any]] = try report.suggestions.map { suggestion in
            let protection = store.item(covering: PathForms.systemPath(suggestion.path))
            // A folder can be unprotected itself and still hold protected items; the app refuses to
            // trash it, and an agent must not call it safe.
            let contained = store.items(inside: PathForms.systemPath(suggestion.path)).count
            inside[suggestion.path] = contained
            if let error = store.readError { throw CLIError.runtime(error) }
            return ["path": suggestion.path, "bytes": knownBytes(suggestion.bytes, suggestion.status),
             "scan_status": status(suggestion.status), "category": suggestion.category.rawValue,
             "safety": suggestion.safety.rawValue, "rule_id": suggestion.ruleID,
             "reason": suggestion.reason, "evidence": suggestion.evidence,
             "newest_modified_at": suggestion.newestModTime > 0 ? iso.string(from: Date(timeIntervalSince1970: Double(suggestion.newestModTime))) as Any : NSNull(),
             "shared_files": suggestion.sharedFiles,
             "protected": protection.map { ($0.kind == .lock ? "lock" : "guard") as Any } ?? NSNull(),
             "contains_protected": contained]
        }
        out["status"] = report.scopeStatus == .unavailable ? "unavailable" : (report.totalStatus == .partial ? "partial" : "complete")
        out["total_bytes"] = knownBytes(report.totalBytes, report.totalStatus)
        out["total_status"] = status(report.totalStatus)
        out["omitted"] = report.omitted
        out["suggestions"] = rows
        out["skipped"] = report.skipped.map { ["path": $0.path, "rule_id": $0.ruleID,
                                                 "reason": $0.why.rawValue, "scan_status": status($0.status)] }
        try emit(out, a.json, to: capture) {
            for category in SuggestCategory.allCases {
                let group = report.suggestions.filter { $0.category == category }
                if group.isEmpty { continue }
                // A lower bound is "≥ N"; a lower bound of nothing is not a size.
                let size = { (bytes: Int64, complete: Bool) in complete ? fmt(bytes) : bytes > 0 ? "≥ " + fmt(bytes) : "unknown" }
                print("\(category.rawValue): \(size(group.reduce(0) { $0 + $1.bytes }, group.allSatisfy { $0.status == .complete }))")
                for suggestion in group {
                    let held = inside[suggestion.path, default: 0]
                    print("  \(size(suggestion.bytes, suggestion.status == .complete)) \(suggestion.path) [\(suggestion.safety.rawValue)]"
                          + (held > 0 ? " [contains \(held) protected]" : "") + " \(suggestion.reason)")
                }
            }
            print("Total: \(displayBytes(report.totalBytes, report.totalStatus)) [\(status(report.totalStatus))]; omitted \(report.omitted)")
            print("Hoard 不會刪除任何檔案；要清理請在 app 或 Finder 裡自己丟到垃圾桶。")
        }
    } else {
        let deadline = a.deadline ?? Date().addingTimeInterval(a.timeout)
        // The finder skips files with no local data, but one can be evicted to the cloud after the
        // scan: make its read fail (reported as unreadable) instead of downloading it. Without the
        // policy nothing is read, and every candidate is reported as not_local.
        let report = Materialization.offForProcess()
            ? DuplicateFinder.find(in: tree.nodes, rootPath: tree.rootPath,
                                   options: DuplicateOptions(minSize: a.minSize), isCancelled: { Date() >= deadline })
            : DuplicateFinder.unread(in: tree.nodes, rootPath: tree.rootPath, options: DuplicateOptions(minSize: a.minSize),
                                     detail: Materialization.refusedDetail)
        out["status"] = report.status.rawValue
        out["tree_status"] = status(report.treeStatus)
        out["candidate_files"] = report.candidateFiles
        out["pending_files"] = report.pendingFiles
        out["bytes_read"] = report.bytesRead
        out["omitted"] = max(0, report.groups.count - a.limit)
        out["groups"] = report.groups.prefix(a.limit).map { group -> [String: Any] in
            // Only a byte-for-byte match frees anything; a group cut short by the deadline may not.
            let confirmed = group.stage == .bytes
            return ["logical_size": group.logicalSize,
             "reclaimable_bytes": confirmed ? group.reclaimableBytes as Any : NSNull(),
             "reclaimable_alloc_lower_bound": confirmed ? group.reclaimableAllocLowerBound as Any : NSNull(),
             "stage": group.stage == .bytes ? "bytes" : (group.stage == .edges ? "edges" : "size"),
             "members": group.members.map { member in
                 ["path": member.path, "aliases": member.aliases, "alloc_bytes": member.allocBytes,
                  "shares_storage": member.sharesStorage] as [String: Any]
             }]
        }
        out["skipped"] = report.skipped.map { ["path": $0.path, "reason": $0.reason.rawValue, "detail": $0.detail] }
        try emit(out, a.json, to: capture) {
            print("Duplicates [\(report.status.rawValue)]")
            for group in report.groups.prefix(a.limit) {
                let freed = group.stage == .bytes ? "\(fmt(group.reclaimableBytes)) reclaimable" : "not fully compared"
                print("  \(freed): \(group.members.map(\.path).joined(separator: ", ")) [\(group.stage)]")
            }
        }
    }
    return a.strict && (out["status"] as? String != "complete")
}
private func sizeObject(_ reading: SizeReading) -> [String: Any] {
    ["bytes": reading.bytes.map { $0 as Any } ?? NSNull(), "status": status(reading.status)]
}
private func run(_ a: Args, capture: ResultCapture? = nil) throws -> Bool {
    if ["suggest", "apps", "uninstall-plan", "similar", "doctor"].contains(a.command) { _ = Materialization.offForProcess() }
    if a.command == "doctor" {
        let report = DoctorCommand.run()
        try emit(report.fields, a.json, to: capture) { print(report.human) }
        return report.exitCode == 3
    }
    if a.command == "cleanup-log" {
        let report = try CleanupLogCommand.run(limit: a.limit)
        try emit(report.fields, a.json, to: capture) { print(report.human) }
        return false
    }
    if ["protect", "protected", "guardian"].contains(a.command) { return try runProtection(a, capture: capture) }
    if a.command == "similar" {
        var query = a
        query.deadline = a.deadline ?? Date().addingTimeInterval(a.timeout)
        let tree: FileTree, source: String, age: TimeInterval?
        do { (tree, source, age) = try open(query) }
        catch ScanError.cancelled {
            let out: [String: Any] = ["schema": schema, "command": "similar", "path": a.path,
                "status": "cancelled", "scan_status": "unavailable", "tree_status": "unavailable",
                "groups": [], "skipped": [], "revision": SimilarOptions().revision,
                "threshold": a.similarThreshold, "candidate_files": 0,
                "processed_files": 0, "pending_files": 0, "images_per_second": 0, "omitted": 0,
                "reclaimable_bytes": NSNull()]
            try emit(out, a.json, to: capture) { print("similar: cancelled before scan completed") }
            return a.strict
        }
        let result = SimilarCommand.run(tree: tree, minSize: a.minSize, threshold: a.similarThreshold,
                                        limit: a.limit, deadline: query.deadline!)
        let out = base(a, tree, source, age).merging(result.fields) { _, new in new }
        try emit(out, a.json, to: capture) { print(result.human) }
        return a.strict && (out["status"] as? String != "complete")
    }
    if ["suggest", "dupes", "hidden", "apps", "uninstall-plan"].contains(a.command) { return try runInsights(a, capture: capture) }
    if a.command == "snapshot" {
        let start = Date(), (tree, meta) = try Snapshot.read(from: URL(fileURLWithPath: a.path))
        var out = base(a, tree, "snapshot", max(0, Date().timeIntervalSince(meta.createdAt)))
        out["path"] = meta.rootPath; out["snapshot_file"] = a.path; out["created_at"] = iso.string(from: meta.createdAt)
        out["scan_seconds"] = meta.scanSeconds; out["last_event_id"] = meta.lastEventId; out["nodes"] = tree.nodeCount
        out["files_10mb_plus"] = tree.nodes.filter { !$0.isRemoved && !$0.isDirectory && $0.ownAlloc >= 10 * 1_048_576 }.count
        out["read_seconds"] = Date().timeIntervalSince(start)
        try emit(out, a.json, to: capture) { print("\(meta.rootPath): \(displayBytes(tree[FileTree.root].totalAlloc, tree[FileTree.root].status)), \(tree.nodeCount) nodes [\(status(tree[FileTree.root].status))]") }
        return a.strict && tree[FileTree.root].status != .complete
    }
    if a.command == "history" {
        let versions: [HistoryVersion]
        do { versions = try SnapshotHistory(rootPath: a.path).versions() }
        catch HistoryError.notImplemented { throw CLIError.runtime("history not available in this build") }
        let rows: [[String: Any]] = versions.map { ["id": $0.id, "created_at": iso.string(from: $0.createdAt),
            "total_alloc": knownBytes($0.totalAlloc, $0.status), "files": $0.fileCount, "dirs": $0.dirCount,
            "scan_status": status($0.status), "stored_bytes": $0.storedBytes] }
        try emit(["schema": schema, "command": "history", "path": a.path, "versions": rows], a.json, to: capture) {
            for v in versions { print("\(v.id) \(iso.string(from: v.createdAt)) \(displayBytes(v.totalAlloc, v.status)) \(v.fileCount) files [\(status(v.status))]") }
            if versions.isEmpty { print("No saved versions") }
        }
        return a.strict && versions.contains { $0.status != .complete }
    }
    if a.command == "scan" {
        let start = Date(), eventID = LiveUpdater.currentEventId()
        let scanner = Scanner(options: ScanOptions(threads: a.threads))
        let tree = try a.sequential ? scanner.scanSequential(root: a.path) : scanner.scan(root: a.path)
        let elapsed = Date().timeIntervalSince(start)
        if a.save {
            let meta = SnapshotMeta(rootPath: a.path, device: tree.device, createdAt: Date(), scanSeconds: elapsed,
                                    lastEventId: eventID, eventsUUID: LiveUpdater.eventsUUID(forDevice: tree.device))
            try Snapshot.write(tree, meta: meta, to: Snapshot.defaultURL(forRoot: a.path))
            do { _ = try SnapshotHistory(rootPath: a.path).record(tree) }
            catch HistoryError.notImplemented { throw CLIError.runtime("history not available in this build; snapshot was saved") }
        }
        let ids = Array(tree.sortedChildren(of: FileTree.root).prefix(a.limit))
        var out = base(a, tree, "scan", nil)
        out["seconds"] = elapsed; out["mode"] = a.sequential ? "sequential" : "parallel(\(a.threads))"
        out["saved"] = a.save; out["entries"] = ids.map { item(tree, $0) }
        try emit(out, a.json, to: capture) {
            print("\(a.path): \(displayBytes(tree[FileTree.root].totalAlloc, tree[FileTree.root].status)) [\(status(tree[FileTree.root].status))]")
            for id in ids { print("  \(displayBytes(tree[id].totalAlloc, tree[id].status)) \(tree.path(of: id)) [\(status(tree[id].status))]") }
            print(String(format: "elapsed %.2fs", elapsed))
        }
        return a.strict && tree[FileTree.root].status != .complete
    }
    if a.command == "diff" { return try runDiff(a, capture: capture) }
    let (tree, source, age) = try open(a)
    var out = base(a, tree, source, age)
    if a.command == "top" {
        let ids = a.files ? TreeQuery.largestFiles(in: tree.nodes, under: FileTree.root, limit: a.limit) :
            TreeQuery.largestDirs(in: tree.nodes, under: FileTree.root, depth: a.depth, limit: a.limit)
        out["kind"] = a.files ? "files" : "dirs"; out["depth"] = a.depth.map { $0 as Any } ?? NSNull()
        out["entries"] = ids.map { item(tree, $0) }
        try emit(out, a.json, to: capture) {
            print("\(a.path): largest \(a.files ? "files" : "folders") [\(status(tree[FileTree.root].status))] (\(originLabel(source, age)))")
            for id in ids { print("  \(displayBytes(tree[id].totalAlloc, tree[id].status)) \(tree.path(of: id)) [\(status(tree[id].status))]") }
        }
    } else if a.command == "types" {
        let stats = Array(tree.extensionStats(under: FileTree.root).prefix(a.limit))
        out["entries"] = stats.map { ["extension": $0.ext, "bytes": $0.bytes, "files": $0.count] }
        try emit(out, a.json, to: capture) {
            print("\(a.path): file types [\(status(tree[FileTree.root].status))] (\(originLabel(source, age)))")
            for s in stats { print("  \(fmt(s.bytes)) .\(s.ext) \(s.count) files") }
        }
    } else {
        let cutoff = Int64(Date().timeIntervalSince1970) - Int64(a.days) * 86_400
        var excluded = 0, unknown = 0, ids: [NodeID] = []
        var queried = 0, request = max(1, a.limit)
        while ids.count < a.limit {
            let candidates = TreeQuery.staleFiles(in: tree.nodes, under: FileTree.root, unusedSince: cutoff,
                                                   minSize: a.minSize, limit: request)
            for id in candidates.dropFirst(queried) {
                let opened = a.spotlight ? Spotlight.lastUsedDate(path: tree.path(of: id)) : nil
                if let opened, opened.timeIntervalSince1970 >= Double(cutoff) { excluded += 1; continue }
                if a.spotlight && opened == nil { unknown += 1 }
                ids.append(id)
                if ids.count >= a.limit { break }
            }
            queried = candidates.count
            if queried < request || queried == 0 || ids.count >= a.limit { break }
            request = min(tree.nodeCount, request > tree.nodeCount / 2 ? tree.nodeCount : request * 2)
            if request <= queried { break }
        }
        out["cutoff"] = iso.string(from: Date(timeIntervalSince1970: Double(cutoff)))
        out["min_size"] = a.minSize; out["spotlight_checked"] = a.spotlight
        out["excluded_recently_opened"] = excluded; out["spotlight_unknown"] = unknown
        out["entries"] = ids.map { id -> [String: Any] in
            var row = item(tree, id)
            row["accessed_at"] = tree[id].accessTime > 0 ? iso.string(from: Date(timeIntervalSince1970: Double(tree[id].accessTime))) as Any : NSNull()
            row["modified_at"] = tree[id].modTime > 0 ? iso.string(from: Date(timeIntervalSince1970: Double(tree[id].modTime))) as Any : NSNull()
            return row
        }
        try emit(out, a.json, to: capture) {
            print("\(a.path): stale files [\(status(tree[FileTree.root].status))] (\(originLabel(source, age))); Spotlight excluded \(excluded), unknown \(unknown)")
            for id in ids { print("  \(displayBytes(tree[id].ownAlloc, tree[id].status)) \(tree.path(of: id))") }
        }
    }
    return a.strict && tree[FileTree.root].status != .complete
}
private func runDiff(_ a: Args, capture: ResultCapture? = nil) throws -> Bool {
    let history = SnapshotHistory(rootPath: a.path)
    let versions: [HistoryVersion]
    do { versions = try history.versions() }
    catch HistoryError.notImplemented { throw CLIError.runtime("history not available in this build") }
    guard let fromID = a.from ?? versions.first?.id else { throw CLIError.runtime("history not available: no saved versions for \(a.path)") }
    let old: TreeSummary
    do { old = try history.load(fromID) }
    catch HistoryError.notImplemented { throw CLIError.runtime("history not available in this build") }
    catch HistoryError.notFound { throw CLIError.runtime("history version not found: \(fromID)") }
    let newest: TreeSummary
    var source = "history", age: TimeInterval? = nil, nowStatus: ScanStatus? = nil
    if a.to == "now" {
        let (tree, origin, snapshotAge) = try open(a)
        newest = TreeSummary(tree: tree, createdAt: Date()); source = origin; age = snapshotAge
        nowStatus = tree[FileTree.root].status
    } else {
        do { newest = try history.load(a.to) }
        catch HistoryError.notImplemented { throw CLIError.runtime("history not available in this build") }
        catch HistoryError.notFound { throw CLIError.runtime("history version not found: \(a.to)") }
    }
    let report = TreeDiff.compare(old, newest)
    let dirs: (DirChange) -> [String: Any] = { c in ["path": c.path, "kind": c.kind.rawValue,
        "before": c.before, "after": c.after, "delta": c.delta, "files_before": c.filesBefore, "files_after": c.filesAfter] }
    let files: [[String: Any]] = report.files.map { ["path": $0.path, "kind": $0.kind.rawValue,
        "before": $0.before, "after": $0.after, "delta": $0.delta] }
    let fromStatus = versions.first { $0.id == fromID }?.status ?? .unavailable
    let toStatus = a.to == "now" ? (nowStatus ?? .unavailable) :
        (versions.first { $0.id == a.to }?.status ?? .unavailable)
    let resultStatus: ScanStatus = fromStatus == .unavailable || toStatus == .unavailable ? .unavailable :
        (fromStatus == .partial || toStatus == .partial ? .partial : .complete)
    let partial = resultStatus != .complete
    let out: [String: Any] = ["schema": schema, "command": "diff", "path": a.path,
        "scan_status": status(resultStatus), "source": source, "snapshot_age_seconds": age.map { $0 as Any } ?? NSNull(),
        "from_id": fromID, "to_id": a.to, "from_date": iso.string(from: report.fromDate), "to_date": iso.string(from: report.toDate),
        "total_before": knownBytes(report.totalBefore, fromStatus),
        "total_after": knownBytes(report.totalAfter, toStatus),
        "total_delta": knownBytes(report.totalDelta, resultStatus),
        "grown": report.grown.map(dirs), "shrunk": report.shrunk.map(dirs), "files": files]
    try emit(out, a.json, to: capture) {
        // People read sizes; --json keeps exact bytes.
        func signed(_ v: Int64) -> String { (v >= 0 ? "+" : "−") + fmt(v.magnitude > Int64.max.magnitude ? Int64.max : Int64(v.magnitude)) }
        func mark(_ c: DirChange) -> String { c.uncertain ? "  (uncertain: not fully readable)" : "" }
        print("Total change: \(resultStatus == .unavailable ? "unknown" : signed(report.totalDelta)) [\(status(resultStatus))]")
        print("Grew:"); for c in report.grown { print("  \(signed(c.delta))  \(c.path)\(mark(c))") }
        print("Shrank:"); for c in report.shrunk { print("  \(signed(c.delta))  \(c.path)\(mark(c))") }
        print("Big files:"); for f in report.files { print("  \(signed(f.delta))  \(f.path) (\(f.kind.rawValue))") }
    }
    return a.strict && partial
}
// Protection: adding is open to everyone; removing needs a human in the app, so nothing here unprotects,
// strips an ACL, or deletes.
private let unprotectHint = "解除保護：在 Hoard app 的「受保護」裡確認。"
/// Paths and notes can come from agents: control characters are shown as escapes so they cannot rewrite
/// a human's terminal or split a one-line-per-action log, and paths stay unambiguous.
private func visible(_ text: String) -> String {
    text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "\\u{\(String($0.value, radix: 16))}" : String($0) }.joined()
}
/// realpath of the deepest existing ancestor plus the not-yet-created rest. nil when an existing entry
/// cannot be resolved, e.g. a dangling symlink (lstat sees it, realpath cannot follow it).
private func resolvedPath(_ path: String) -> String? {
    if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
    var st = stat()
    if lstat(path, &st) == 0 { return nil }
    let parent = (path as NSString).deletingLastPathComponent
    guard parent != path, let base = resolvedPath(parent) else { return nil }
    return (base as NSString).appendingPathComponent((path as NSString).lastPathComponent)
}
private func protectionStore() throws -> ProtectionStore {
    guard let dir = ProcessInfo.processInfo.environment["HOARD_PROTECTION_DIR"] else { return ProtectionStore() }
    // An empty value is a broken test setup; falling back to the real registry would touch real files.
    guard !dir.isEmpty else { throw CLIError.runtime("HOARD_PROTECTION_DIR is set but empty") }
    // The store gets a deny-delete ACL, so a store at ~ would lock the home folder: tests only, inside temp.
    let temps = [FileManager.default.temporaryDirectory.path, "/private/tmp"].compactMap { resolvedPath($0) }
    guard let resolved = resolvedPath(absolute(dir)), temps.contains(where: { resolved.hasPrefix($0 + "/") }) else {
        throw CLIError.usage("HOARD_PROTECTION_DIR must be a folder inside the system temp directory (it is for tests): \(visible(dir))")
    }
    return ProtectionStore(directory: URL(fileURLWithPath: resolved, isDirectory: true))
}
private func engine<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch let error as CLIError { throw error }
    catch { throw CLIError.runtime(error.localizedDescription) }
}
private func protectedItem(_ item: ProtectedItem) -> [String: Any] {
    ["id": item.id, "path": item.path, "kind": item.kind == .lock ? "lock" : "guard", "is_dir": item.isDirectory,
     "created_at": iso.string(from: item.createdAt), "created_by": item.createdBy,
     "note": item.note.map { $0 as Any } ?? NSNull()]
}
private func healthFields(_ health: ProtectionHealth) -> [String: Any] {
    switch health {
    case .intact: return ["health": "intact"]
    case .aclMissing: return ["health": "acl_missing"]
    case .vaultMissing: return ["health": "vault_missing"]
    case .itemMissing(let restorable): return ["health": "item_missing", "restorable": restorable]
    }
}
private func healthLabel(_ fields: [String: Any]) -> String {
    let health = fields["health"] as? String ?? "unknown"
    guard let restorable = fields["restorable"] as? Bool else { return health }
    return health + (restorable ? " (restorable)" : " (not restorable)")
}
private func runProtection(_ a: Args, capture: ResultCapture?) throws -> Bool {
    let store = try protectionStore()
    if a.command == "protect" {
        let item = try engine { try a.lock ? store.lock(a.path, by: a.by, note: a.note) : store.guardItem(a.path, by: a.by, note: a.note) }
        let health = healthFields(store.health(item.id))
        let out = health.merging(["schema": schema, "command": "protect", "item": protectedItem(item)]) { _, new in new }
        try emit(out, a.json, to: capture) {
            print("\(a.lock ? "locked" : "guarded") \(visible(item.path)) [\(healthLabel(health))]")
            print("id \(item.id)")
            print(unprotectHint)
        }
        return false
    }
    if a.command == "protected" {
        let target = a.path.isEmpty ? nil : a.path
        // Every read reloads the registry and may set or clear readError; keep the first failure.
        let items = store.items()
        var registryError = store.readError
        let rows: [(ProtectedItem, [String: Any])] = items.map { item in
            let health = healthFields(store.health(item.id))
            registryError = registryError ?? store.readError
            return (item, health)
        }
        var out: [String: Any] = ["schema": schema, "command": "protected", "path": target.map { $0 as Any } ?? NSNull(),
                                  "items": rows.map { protectedItem($0.0).merging($0.1) { old, _ in old } }]
        var covering: (ProtectedItem, [String: Any])?
        if let target {
            if let item = store.item(covering: target) {
                registryError = registryError ?? store.readError
                covering = rows.first { $0.0.id == item.id } ?? (item, healthFields(store.health(item.id)))
            }
            registryError = registryError ?? store.readError
            out["covering"] = covering.map { protectedItem($0.0).merging($0.1) { old, _ in old } as Any } ?? NSNull()
        }
        out["registry_error"] = registryError.map { $0 as Any } ?? NSNull()
        try emit(out, a.json, to: capture) {
            if let registryError { print("⚠ 保護清單讀不到：\(visible(registryError))") }
            for (item, health) in rows {
                print("  \(item.kind == .lock ? "lock " : "guard") \(healthLabel(health))  \(visible(item.path))\(item.note.map { "  — \(visible($0))" } ?? "")")
            }
            if rows.isEmpty && registryError == nil { print("No protected items") }
            if let target {
                let shown = visible(target)
                if let covering {
                    print("\(shown): covered by \(covering.0.kind == .lock ? "lock" : "guard") on \(visible(covering.0.path)) [\(healthLabel(covering.1))]")
                } else {
                    print(registryError == nil ? "\(shown): not protected" : "\(shown): unknown (protection list unreadable)")
                }
            }
            print(unprotectHint)
        }
        // An unreadable registry is "unknown", never "nothing is protected".
        if let registryError, items.isEmpty { throw CLIError.runtime(registryError) }
        return false
    }
    if a.once {
        let restored = try engine { try store.restoreMissing() }
        try emit(["schema": schema, "command": "guardian", "mode": "once", "restored": restored], a.json, to: capture) {
            for path in restored { print(visible(path)) }
            if restored.isEmpty { print("No deleted guarded items") }
        }
        return false
    }
    guard capture == nil else { throw CLIError.usage("guardian runs until stopped; use --once") }
    try watchGuarded(store, json: a.json)
}
private func watchGuarded(_ store: ProtectionStore, json: Bool) throws -> Never {
    let guardian = ProtectionGuardian(store: store) { action in
        let (name, path, message): (String, String, String?)
        switch action {
        case .restored(let p): (name, path, message) = ("restored", p, nil)
        case .refreshed(let p): (name, path, message) = ("refreshed", p, nil)
        case .failed(let p, let m): (name, path, message) = ("error", p, m)
        }
        fputs("\(name) \(visible(path))\(message.map { ": \(visible($0))" } ?? "")\n", stderr)
        guard json else { return }
        let line: [String: Any] = ["schema": schema, "command": "guardian", "action": name, "path": path,
                                   "message": message.map { $0 as Any } ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { guardian.stop(); exit(0) }
        source.resume()
        return source
    }
    try engine { try guardian.start() }
    withExtendedLifetime(sources) { dispatchMain() }
}
private func result(for args: Args) throws -> [String: Any] {
    let capture = ResultCapture()
    _ = try run(args, capture: capture)
    guard let result = capture.value else { throw CLIError.runtime("command produced no result") }
    return result
}

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func set(_ value: Data) { lock.lock(); bytes = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

/// Suggest and hidden-space probes have no cancellation callback. Isolate them (and app listing)
/// so a deadline never holds the single-request MCP server indefinitely.
private func boundedInsight(_ args: Args) throws -> [String: Any] {
    guard let deadline = args.deadline else { return try result(for: args) }
    let process = Process()
    guard let executable = Bundle.main.executableURL else { throw CLIError.runtime("cannot locate hoard executable") }
    process.executableURL = executable
    var words = [args.command]
    if args.command != "apps" && args.command != "cleanup-log" && args.command != "doctor" { words.append(args.path) }
    if ["suggest", "apps", "cleanup-log"].contains(args.command) { words += ["--limit", String(args.limit)] }
    if args.command == "suggest" { words += ["--min-size", "\(args.minSize)B"] }
    if args.command == "similar" {
        words += ["--limit", String(args.limit), "--min-size", "\(args.minSize)B",
                  "--threshold", String(args.similarThreshold)]
    }
    words.append("--json")
    process.arguments = words
    var environment = ProcessInfo.processInfo.environment
    environment["_HOARD_MCP_CHILD"] = "1"
    // hidden still probes the volume after its scan is cut off (tmutil alone may take 10 s): stop that
    // scan early enough for the volume lines to come back before the server's deadline.
    // similar and suggest finish the file in hand, group and encode after noticing the deadline: leave
    // them room, or the server kills the child and returns an empty stub instead of partial results.
    let margin: TimeInterval = ["hidden": 12, "similar": 8, "suggest": 5][args.command] ?? 0
    let childDeadline = deadline.addingTimeInterval(-margin)
    environment["_HOARD_MCP_DEADLINE"] = String(childDeadline.timeIntervalSince1970)
    process.environment = environment
    let pipe = Pipe(), captured = PipeCapture(), drained = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    process.standardOutput = pipe
    process.standardError = FileHandle.standardError
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    pipe.fileHandleForWriting.closeFile()
    DispatchQueue.global().async {
        captured.set(pipe.fileHandleForReading.readDataToEndOfFile())
        drained.signal()
    }
    if finished.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 0.1)
        switch args.command {
        case "suggest":
            return ["schema": schema, "command": "suggest", "path": args.path, "status": "cancelled",
                    "scan_status": "unavailable", "suggestions": [], "skipped": [], "total_bytes": NSNull(),
                    "total_status": "unavailable", "omitted": 0]
        case "similar":
            return ["schema": schema, "command": "similar", "path": args.path, "status": "cancelled",
                    "scan_status": "unavailable", "tree_status": "unavailable", "groups": [], "skipped": [],
                    "revision": SimilarOptions().revision, "threshold": args.similarThreshold,
                    "candidate_files": 0, "processed_files": 0,
                    "pending_files": 0, "images_per_second": 0, "reclaimable_bytes": NSNull(), "omitted": 0]
        case "hidden":
            return ["schema": schema, "command": "hidden", "path": args.path, "status": "cancelled",
                    "source": "deadline", "mount_point": NSNull(), "covers_volume": false, "lines": [],
                    "unreadable_folders": [], "unreadable_total": NSNull(), "unreadable_by_reason": [:]]
        case "cleanup-log":
            return ["schema": schema, "command": "cleanup-log", "status": "unavailable", "log": try CleanupLogCommand.displayPath(),
                    "reason": "deadline exceeded", "entries": [], "total_bytes": NSNull(), "omitted": 0]
        case "doctor": return DoctorCommand.timeoutFields()
        case "uninstall-plan":
            return ["schema": schema, "command": "uninstall-plan", "app_path": NSNull(), "name": NSNull(),
                    "bundle_id": NSNull(), "refusal": "分析逾時，沒有移動任何檔案。", "items": [], "kept": [],
                    "total_default": sizeObject(.init(bytes: nil, status: .unavailable))]
        default:
            return ["schema": schema, "command": "apps", "status": "cancelled", "apps": [],
                    "unreadable": [], "omitted": 0]
        }
    }
    _ = drained.wait(timeout: .now() + 1)
    guard (process.terminationStatus == 0 || (args.command == "doctor" && [1, 3].contains(process.terminationStatus))),
          let object = try JSONSerialization.jsonObject(with: captured.get()) as? [String: Any] else {
        throw CLIError.runtime("\(args.command) worker failed with exit \(process.terminationStatus)")
    }
    return object
}

private let mcpTools: [[String: Any]] = [
    tool("disk_suggest", "Find explainable cleanup candidates. Never modifies files.",
         properties: ["path": pathSchema(), "min_size_mb": ["type": "number", "minimum": 0], "limit": integerSchema()], required: ["path"]),
    tool("disk_similar_images", "Find visually similar images for human review; never modifies files.",
         properties: ["path": pathSchema(), "min_size_mb": ["type": "number", "minimum": 0],
                      "threshold": ["type": "number", "minimum": 0], "limit": integerSchema()], required: ["path"]),
    tool("disk_duplicates", "Find byte-identical files and estimated reclaimable space. Never modifies files.",
         properties: ["path": pathSchema(), "min_size_mb": ["type": "number", "minimum": 0],
                      "limit": integerSchema(), "timeout_seconds": ["type": "number", "minimum": 0, "maximum": 300]], required: ["path"]),
    tool("disk_hidden_space", "Explain measured and unknown disk space. Never modifies files.",
         properties: ["path": pathSchema()], required: []),
    tool("disk_apps", "List application bundles and matching user data. Never modifies files.",
         properties: ["limit": integerSchema()], required: []),
    tool("disk_uninstall_plan", "Read-only uninstall plan; removal happens only in the app with a person's confirmation. Nothing is removed here.",
         properties: ["app": ["type": "string", "description": "App path, bundle id, or app name"]], required: ["app"]),
    tool("disk_cleanup_log", "List what Hoard recorded moving to the Trash (minus ⌘Z undos; Finder put-backs and emptied items are not known). Never modifies files.",
         properties: ["limit": ["type": "integer", "minimum": 0, "maximum": 1000]], required: []),
    tool("disk_doctor", "Checks Hoard's macOS assumptions; writes only to its own temporary folder and never modifies the user's files.",
         properties: [:], required: []),
    tool("disk_top", "Largest files or folders; never modifies files.",
         properties: ["path": pathSchema(), "kind": ["type": "string", "enum": ["files", "dirs"]],
                      "limit": integerSchema(), "depth": integerSchema()], required: ["path", "kind"]),
    tool("disk_stale", "Large files unused for a number of days; never modifies files.",
         properties: ["path": pathSchema(), "days": integerSchema(), "min_size_mb": ["type": "number", "minimum": 0],
                      "limit": integerSchema(), "spotlight": ["type": "boolean"]], required: ["path"]),
    tool("disk_types", "Disk usage by file type; never modifies files.",
         properties: ["path": pathSchema(), "limit": integerSchema()], required: ["path"]),
    tool("disk_history", "Saved scan versions; never modifies files.",
         properties: ["path": pathSchema()], required: ["path"]),
    tool("disk_diff", "Changes since a saved scan; never modifies files.",
         properties: ["path": pathSchema(), "from": ["type": "string"], "to": ["type": "string"]], required: ["path"]),
    tool("disk_scan", "Full disk scan; save records a history version; never modifies files.",
         properties: ["path": pathSchema(), "save": ["type": "boolean"]], required: ["path"]),
    tool("disk_protect", "Adds protection to a file or folder. lock: cannot be deleted, moved or replaced (in-place writes still work). guard: editable; if deleted, Hoard restores it. Protection can only be removed by a human in the Hoard app.",
         properties: ["path": itemPathSchema(), "kind": ["type": "string", "enum": ["lock", "guard"]],
                      "note": ["type": "string"]], required: ["path", "kind"]),
    tool("disk_protected", "Lists protected files and folders and their health; with path, tells whether that path is protected. Never modifies files.",
         properties: ["path": itemPathSchema()], required: []),
    tool("disk_restore", "Restores guarded files and folders that were deleted. Never deletes or overwrites existing files.",
         properties: [:], required: [])
]
private func pathSchema() -> [String: Any] { ["type": "string", "description": "Absolute or ~-relative directory path"] }
private func itemPathSchema() -> [String: Any] { ["type": "string", "description": "Absolute or ~-relative file or folder path"] }
private func integerSchema() -> [String: Any] { ["type": "integer", "minimum": 0] }
private func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
    ["name": name, "description": description,
     "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
}

private func mcpArguments(_ name: String, _ raw: Any?) throws -> Args {
    let commands = ["disk_suggest": "suggest", "disk_duplicates": "dupes", "disk_similar_images": "similar", "disk_hidden_space": "hidden", "disk_apps": "apps", "disk_uninstall_plan": "uninstall-plan", "disk_cleanup_log": "cleanup-log", "disk_doctor": "doctor",
                    "disk_top": "top", "disk_stale": "stale", "disk_types": "types",
                    "disk_history": "history", "disk_diff": "diff", "disk_scan": "scan",
                    "disk_protect": "protect", "disk_protected": "protected", "disk_restore": "guardian"]
    guard let command = commands[name] else { throw CLIError.usage("unknown tool: \(name)") }
    guard let object = raw as? [String: Any] else { throw CLIError.usage("arguments must be an object") }
    let allowed: Set<String> = switch name {
    case "disk_suggest": ["path", "min_size_mb", "limit"]
    case "disk_similar_images": ["path", "min_size_mb", "threshold", "limit"]
    case "disk_duplicates": ["path", "min_size_mb", "limit", "timeout_seconds"]
    case "disk_hidden_space": ["path"]
    case "disk_apps": ["limit"]
    case "disk_uninstall_plan": ["app"]
    case "disk_cleanup_log": ["limit"]
    case "disk_doctor": []
    case "disk_top": ["path", "kind", "limit", "depth"]
    case "disk_stale": ["path", "days", "min_size_mb", "limit", "spotlight"]
    case "disk_types": ["path", "limit"]
    case "disk_history": ["path"]
    case "disk_diff": ["path", "from", "to"]
    case "disk_protect": ["path", "kind", "note"]
    case "disk_protected": ["path"]
    case "disk_restore": []
    default: ["path", "save"]
    }
    guard let extra = object.keys.first(where: { !allowed.contains($0) }) else {
        return try validatedMCPArguments(name, command, object)
    }
    throw CLIError.usage("unknown argument: \(extra)")
}
private func validatedMCPArguments(_ name: String, _ command: String, _ object: [String: Any]) throws -> Args {
    var words = [command]
    if name == "disk_uninstall_plan" {
        guard let app = object["app"] as? String, !app.isEmpty else { throw CLIError.usage("app must be a non-empty string") }
        words.append(app)
    } else if object["path"] != nil || !["disk_protected", "disk_restore", "disk_hidden_space", "disk_apps", "disk_cleanup_log", "disk_doctor"].contains(name) {
        guard let path = object["path"] as? String, !path.isEmpty,
              path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else {
            throw CLIError.usage("path must be absolute or ~-relative")
        }
        words.append(path)
    }
    words.append("--json")
    func number(_ key: String) throws -> Int? {
        guard let value = object[key] else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let parsed = Int(n.stringValue), parsed >= 0 else { throw CLIError.usage("\(key) must be a non-negative integer") }
        return parsed
    }
    func bool(_ key: String) throws -> Bool? {
        guard let value = object[key] else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw CLIError.usage("\(key) must be a boolean")
        }
        return n.boolValue
    }
    func string(_ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let s = value as? String, !s.isEmpty else { throw CLIError.usage("\(key) must be a non-empty string") }
        return s
    }
    if name == "disk_top" {
        guard let kind = try string("kind"), ["files", "dirs"].contains(kind) else {
            throw CLIError.usage("kind must be files or dirs")
        }
        words.append(kind == "files" ? "--files" : "--dirs")
        if let depth = try number("depth") {
            guard kind == "dirs" else { throw CLIError.usage("depth applies only to dirs") }
            words += ["--depth", String(depth)]
        }
    }
    if ["disk_top", "disk_stale", "disk_types", "disk_suggest", "disk_duplicates", "disk_similar_images", "disk_apps", "disk_cleanup_log"].contains(name), let limit = try number("limit") {
        words += ["--limit", String(limit)]
    }
    if ["disk_stale", "disk_suggest", "disk_duplicates", "disk_similar_images"].contains(name) {
        if let days = try number("days") { words += ["--days", String(days)] }
        if let value = object["min_size_mb"] {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0,
                  n.doubleValue < Double(Int64.max - 1_000_000) / 1_000_000 else {
                throw CLIError.usage("min_size_mb must be a non-negative number within range")
            }
            words += ["--min-size", "\(Int64((n.doubleValue * 1_000_000).rounded(.up)))B"]
        }
        if name == "disk_stale", try bool("spotlight") == false { words.append("--no-spotlight") }
    }
    if name == "disk_duplicates", let value = object["timeout_seconds"] {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue >= 0, n.doubleValue <= 300 else { throw CLIError.usage("timeout_seconds must be between 0 and 300") }
        words += ["--timeout", String(n.doubleValue)]
    }
    if name == "disk_similar_images", let value = object["threshold"] {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= Double(Float.greatestFiniteMagnitude) else {
            throw CLIError.usage("threshold must be a non-negative finite number")
        }
        words += ["--threshold", String(n.floatValue)]
    }
    if name == "disk_diff" {
        if let from = try string("from") { words += ["--from", from] }
        if let to = try string("to") { words += ["--to", to] }
    }
    if name == "disk_scan", try bool("save") == true { words.append("--save") }
    if name == "disk_protect" {
        guard let kind = try string("kind"), ["lock", "guard"].contains(kind) else {
            throw CLIError.usage("kind must be lock or guard")
        }
        words.append(kind == "lock" ? "--lock" : "--guard")
        if let note = try string("note") {
            // Scalars, not graphemes: one grapheme can carry any number of combining marks.
            guard note.unicodeScalars.count <= 500 else { throw CLIError.usage("note must be at most 500 characters") }
            words += ["--note", note]
        }
    }
    if name == "disk_restore" { words.append("--once") }
    return try Args(words)
}

private func rpcError(_ code: Int, _ message: String, id: Any = NSNull()) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
}
private func rpcResult(_ value: Any, id: Any) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "result": value]
}
/// `clientInfo.name` from `initialize`, safe to store as a protection's creator.
private func mcpClientName(_ info: Any?) -> String {
    let raw = (info as? [String: Any])?["name"] as? String ?? ""
    let name = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "unknown" : String(name.prefix(64))
}
private func mcpResponse(_ request: [String: Any], structured: inout Bool, client: inout String) -> [String: Any]? {
    let id = request["id"] ?? NSNull()
    guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
        return rpcError(-32600, "Invalid JSON-RPC request", id: id)
    }
    if method == "notifications/initialized" { return nil }
    if request["id"] == nil { return nil } // Other notifications have no response.
    guard id is String || (id is NSNumber && CFGetTypeID(id as! NSNumber) != CFBooleanGetTypeID()) else {
        return rpcError(-32600, "Invalid request id")
    }
    let params = request["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String
        let version = requested == "2025-06-18" ? requested! : "2025-06-18"
        structured = requested == "2025-06-18"
        client = mcpClientName(params["clientInfo"])
        return rpcResult(["protocolVersion": version, "capabilities": ["tools": [:]],
                          "serverInfo": ["name": "hoard", "version": "0.6.1"]], id: id)
    case "ping": return rpcResult([:], id: id)
    case "tools/list": return rpcResult(["tools": mcpTools], id: id)
    case "tools/call":
        guard let name = params["name"] as? String else { return rpcError(-32602, "tools/call requires a tool name", id: id) }
        var args: Args
        do { args = try mcpArguments(name, params["arguments"]) }
        catch { return rpcError(-32602, String(describing: error), id: id) }
        args.by = "mcp:\(client)"
        let seconds: TimeInterval? = switch name {
        case "disk_duplicates": (params["arguments"] as? [String: Any])?["timeout_seconds"] == nil ? 60 : args.timeout
        case "disk_hidden_space": 20
        case "disk_cleanup_log": 10
        case "disk_doctor": 30
        case "disk_apps", "disk_uninstall_plan", "disk_suggest", "disk_similar_images": 60
        default: nil
        }
        args.deadline = seconds.map { Date().addingTimeInterval($0) }
        do {
            let object = try ["disk_suggest", "disk_similar_images", "disk_hidden_space", "disk_apps", "disk_uninstall_plan", "disk_cleanup_log", "disk_doctor"].contains(name) ? boundedInsight(args) : result(for: args)
            var toolResult: [String: Any] = ["content": [["type": "text", "text": try jsonText(object)]]]
            if structured { toolResult["structuredContent"] = object }
            return rpcResult(toolResult, id: id)
        } catch {
            return rpcResult(["content": [["type": "text", "text": String(describing: error)]], "isError": true], id: id)
        }
    default: return rpcError(-32601, "Method not found: \(method)", id: id)
    }
}
private let maximumMCPLineBytes = 1_048_576
private func mcpLineResponse(_ line: Data, tooLong: Bool, structured: inout Bool, client: inout String) -> [String: Any]? {
    if tooLong { return rpcError(-32600, "Request larger than 1 MB") }
    if let value = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) {
        if let object = value as? [String: Any] {
            return mcpResponse(object, structured: &structured, client: &client)
        }
        return rpcError(-32600, "Invalid JSON-RPC request")
    }
    return rpcError(-32700, "Parse error")
}

private func serveMCP() {
    var structured = false, client = "unknown"
    var line = Data()
    var tooLong = false
    func respond() {
        defer { line.removeAll(keepingCapacity: true); tooLong = false }
        let response = mcpLineResponse(line, tooLong: tooLong, structured: &structured, client: &client)
        guard let response else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        } catch {
            fputs("hoard mcp: response encoding failed: \(error)\n", stderr)
        }
    }
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = read(STDIN_FILENO, &chunk, chunk.count)
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            fputs("hoard mcp: stdin read failed: \(String(cString: strerror(errno)))\n", stderr)
            break
        }
        for byte in chunk[..<count] {
            if byte == 10 {
                // No run loop drains a pool here: without one, every reply and every child's output
                // stayed alive for the life of the server (+0.3 MB a 100 KB call).
                autoreleasepool { respond() }
            } else if !tooLong {
                if line.count == maximumMCPLineBytes {
                    tooLong = true
                    line.removeAll(keepingCapacity: false)
                } else {
                    line.append(byte)
                }
            }
        }
    }
    if tooLong || !line.isEmpty { respond() }
}
// The copy inside a development app (Contents/MacOS/hoard-cli, where Bundle.main is that app) works
// on the development data, like the app itself: its background guardian must never touch the owner's store.
if Bundle.main.bundleIdentifier == "com.operonlab.hoard.dev" { HoardStorage.folderName = "Hoard Dev" }
do {
    if CommandLine.arguments.dropFirst().first == "mcp" {
        guard CommandLine.arguments.count == 2 else { throw CLIError.usage("usage: hoard mcp") }
        serveMCP()
        exit(0)
    }
    if CommandLine.arguments.dropFirst().first == "completion" {
        guard CommandLine.arguments.count == 3,
              let script = Completion.script(shell: CommandLine.arguments[2], commands: supportedCommands) else {
            throw CLIError.usage("usage: hoard completion <zsh|bash|fish>")
        }
        print(script)
        exit(0)
    }
    let args = try Args(Array(CommandLine.arguments.dropFirst()))
    if args.command == "doctor" {
        _ = Materialization.offForProcess()
        let report = DoctorCommand.run()
        try emit(report.fields, args.json) { print(report.human) }
        exit(report.exitCode)
    }
    if try run(args) { exit(3) }
} catch let error as CLIError {
    fputs("hoard: \(error.description)\n", stderr)
    switch error { case .usage: exit(2); case .runtime: exit(1) }
} catch {
    fputs("hoard: \(error)\n", stderr)
    exit(1)
}
