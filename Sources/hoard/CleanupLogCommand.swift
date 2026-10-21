import Darwin
import Foundation
import ScanCore

enum CleanupLogCommand {
    static func run(limit: Int) throws -> (fields: [String: Any], human: String) {
        let url = try logURL()
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            let ns = error as NSError
            if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == ENOENT) {
                return (["schema": "hoard/1", "command": "cleanup-log", "status": "complete",
                         "log": "none", "entries": [], "total_bytes": 0, "omitted": 0],
                        "No cleanup log yet: Hoard has not moved anything to the Trash.")
            }
            let reason = error.localizedDescription
            return (["schema": "hoard/1", "command": "cleanup-log", "status": "unavailable",
                     "log": shown(url.path), "reason": reason, "entries": [],
                     "total_bytes": NSNull(), "omitted": 0], "Cleanup log unavailable: \(reason)")
        }
        let all = CleanupLogFormat.recent(data, limit: .max)
        let entries = Array(all.prefix(limit))
        let partial = all.contains { $0.partial }
        let (total, overflow) = all.reduce((Int64(0), false)) { acc, entry in
            let (next, didOverflow) = acc.0.addingReportingOverflow(entry.bytes)
            return (next, acc.1 || didOverflow)
        }
        let formatter = ISO8601DateFormatter()
        let rows: [[String: Any]] = entries.map { entry in
            ["date": formatter.string(from: entry.date), "path": entry.path, "bytes": entry.bytes,
             "source": entry.source, "partial": entry.partial]
        }
        let totalValue: Any = partial || overflow ? NSNull() : total
        let fields: [String: Any] = ["schema": "hoard/1", "command": "cleanup-log", "status": "complete",
                                     "log": shown(url.path), "entries": rows, "total_bytes": totalValue,
                                     "omitted": all.count - entries.count]
        var lines = entries.map { entry in
            "\(formatter.string(from: entry.date))  \(entry.partial ? "≥" : "")\(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))  \(shown(entry.path))  [\(entry.source)]"
        }
        lines.append("Total: \(overflow ? "unknown" : (partial ? "≥" : "") + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
        return (fields, lines.joined(separator: "\n"))
    }

    static func displayPath() throws -> String { shown(try logURL().path) }

    private static func logURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["HOARD_CLEANUP_LOG"] {
            guard !override.isEmpty else { throw CLIError.runtime("HOARD_CLEANUP_LOG is set but empty") }
            let path = URL(fileURLWithPath: override).standardizedFileURL.path
            let temps = [FileManager.default.temporaryDirectory.path, "/private/tmp"].compactMap(realPath)
            guard let resolved = realPath(path), temps.contains(where: { resolved.hasPrefix($0 + "/") }) else {
                throw CLIError.usage("HOARD_CLEANUP_LOG must be a file inside the system temp directory (it is for tests): \(shown(override))")
            }
            return URL(fileURLWithPath: resolved)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(HoardStorage.folderName, isDirectory: true)
            .appendingPathComponent("cleanup-log.jsonl")
    }

    private static func realPath(_ path: String) -> String? {
        if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        var st = stat()
        if lstat(path, &st) == 0 { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, let base = realPath(parent) else { return nil }
        return (base as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    private static func shown(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
}
