import Darwin
import Foundation

public enum LiveUpdaterError: Error {
    case cannotCreateStream
    case cannotStartStream
}

public enum IncrementalSessionError: Error {
    case rootMismatch
}

public final class IncrementalSession {
    public enum Source {
        case snapshot(age: TimeInterval, replayFrom: UInt64)
        case fullScan(seconds: Double)
    }

    public static var log: (String) -> Void = { message in
        fputs("Hoard incremental: \(message)\n", stderr)
    }

    private let root: String

    public init(root: String) { self.root = root }

    public static func open(root: String, scanner: Scanner,
                            progress: ((ScanProgress) -> Void)? = nil) throws -> (tree: FileTree, source: Source) {
        try open(root: root, scanner: scanner, progress: progress,
                 snapshotURL: Snapshot.defaultURL(forRoot: root))
    }

    static func open(root: String, scanner: Scanner, progress: ((ScanProgress) -> Void)? = nil,
                     snapshotURL url: URL, currentEventId: () -> UInt64 = LiveUpdater.currentEventId,
                     eventsUUID: (Int32) -> String? = LiveUpdater.eventsUUID) throws -> (tree: FileTree, source: Source) {
        var reason = "no snapshot at \(url.path)"
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let (tree, meta) = try Snapshot.read(from: url)
                var st = stat()
                let rootExists = lstat(root, &st) == 0
                let uuid = rootExists ? eventsUUID(st.st_dev) : nil
                if tree.rootPath != root {
                    reason = "snapshot root mismatch"
                } else if !rootExists || tree.device != st.st_dev {
                    reason = "root volume changed or unavailable"
                } else if uuid == nil || meta.eventsUUID != uuid {
                    reason = "FSEvents volume UUID unavailable or changed"
                } else if meta.lastEventId == 0 {
                    reason = "snapshot has no replay event id"
                } else {
                    let age = max(0, Date().timeIntervalSince(meta.createdAt))
                    log("snapshot \(url.path), age \(age)s, replay from \(meta.lastEventId)")
                    return (tree, .snapshot(age: age, replayFrom: meta.lastEventId))
                }
            } catch {
                reason = "snapshot rejected: \(error)"
            }
        }
        log("full scan \(root): \(reason)")
        let eventID = currentEventId()
        let start = Date()
        let tree = try scanner.scan(root: root, progress: progress)
        let seconds = Date().timeIntervalSince(start)
        let meta = SnapshotMeta(rootPath: root, device: tree.device, createdAt: Date(),
                                scanSeconds: seconds, lastEventId: eventID,
                                eventsUUID: eventsUUID(tree.device))
        try Snapshot.write(tree, meta: meta, to: url)
        log("full scan completed in \(seconds)s; snapshot \(url.path), replay from \(eventID)")
        return (tree, .fullScan(seconds: seconds))
    }

    public func save(tree: FileTree, lastEventId: UInt64) throws {
        try save(tree: tree, lastEventId: lastEventId, to: Snapshot.defaultURL(forRoot: root))
    }

    func save(tree: FileTree, lastEventId: UInt64, to url: URL) throws {
        guard tree.rootPath == root else { throw IncrementalSessionError.rootMismatch }
        let meta = SnapshotMeta(rootPath: root, device: tree.device, createdAt: Date(),
                                scanSeconds: 0, lastEventId: lastEventId,
                                eventsUUID: LiveUpdater.eventsUUID(forDevice: tree.device))
        try Snapshot.write(tree, meta: meta, to: url)
        Self.log("saved snapshot \(url.path), replay from \(lastEventId)")
    }
}
