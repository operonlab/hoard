import Darwin
import Foundation

public struct UnreadableDiagnosis: Equatable, Sendable {
    public enum Reason: String, Sendable, Codable {
        case needsFullDiskAccess = "needs_full_disk_access"
        case systemProtected = "system_protected"
        case permission, filePermissions = "file_permissions", notDownloaded = "not_downloaded"
        case gone, readableNow = "readable_now", error, unknown
    }
    public var reason: Reason
    public var errno: Int32?
    public var owner: String?
}

public enum Unreadable {
    static func classify(lstatErrno: Int32?, flags: UInt32, opened: Bool, openErrno: Int32?,
                         fullDiskAccess: FullDiskAccess.State, owner: String?) -> UnreadableDiagnosis {
        func result(_ reason: UnreadableDiagnosis.Reason, _ error: Int32? = nil, _ owner: String? = nil) -> UnreadableDiagnosis {
            UnreadableDiagnosis(reason: reason, errno: error, owner: owner)
        }
        if let error = lstatErrno { return result(error == ENOENT || error == ENOTDIR ? .gone : .error, error) }
        if flags & UInt32(SF_DATALESS) != 0 { return result(.notDownloaded) }
        // SF_RESTRICTED (SIP) forbids changes, not reading, so only the open below can tell.
        if opened { return result(.readableNow) }
        guard let error = openErrno else { return result(.unknown) }
        switch error {
        case EACCES: return result(.filePermissions, error, owner)
        case EPERM:
            switch fullDiskAccess {
            case .denied: return result(.needsFullDiskAccess, error)
            case .granted: return result(.systemProtected, error)
            case .unknown: return result(.permission, error)
            }
        case ENOENT, ENOTDIR: return result(.gone, error)
        default: return result(.error, error)
        }
    }

    public static func diagnose(_ path: String, fullDiskAccess: FullDiskAccess.State) -> UnreadableDiagnosis {
        var info = stat()
        let rc = path.withCString { lstat($0, &info) }
        let statError: Int32? = rc == 0 ? nil : errno
        if let statError { return classify(lstatErrno: statError, flags: 0, opened: false, openErrno: nil,
                                           fullDiskAccess: fullDiskAccess, owner: nil) }
        let flags = UInt32(info.st_flags)
        if flags & UInt32(SF_DATALESS) != 0 {
            return classify(lstatErrno: nil, flags: flags, opened: false, openErrno: nil,
                            fullDiskAccess: fullDiskAccess, owner: nil)
        }
        guard let restore = Materialization.offForThread("unreadable diagnosis") else {
            return classify(lstatErrno: nil, flags: flags, opened: false, openErrno: nil,
                            fullDiskAccess: fullDiskAccess, owner: nil)
        }
        defer { restore() }
        let fd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        if fd >= 0 {
            close(fd)
            return classify(lstatErrno: nil, flags: flags, opened: true, openErrno: nil,
                            fullDiskAccess: fullDiskAccess, owner: nil)
        }
        let openError = errno
        return classify(lstatErrno: nil, flags: flags, opened: false, openErrno: openError,
                        fullDiskAccess: fullDiskAccess, owner: userName(info.st_uid))
    }

    /// `getpwuid_r`, because the inspector and the list diagnose on different threads at once.
    private static func userName(_ uid: uid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        return buffer.withUnsafeMutableBufferPointer { storage -> String? in
            var entry = passwd()
            var found: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(uid, &entry, storage.baseAddress!, storage.count, &found) == 0,
                  found != nil, let name = entry.pw_name else { return nil }
            return String(cString: name)
        }
    }

    /// Diagnoses `paths` in order on a thread of their own, for at most `timeout` seconds: an `open` on
    /// a stalled network volume can block for good, so whatever is not done by then is `unknown`.
    public static func diagnose(_ paths: [String], fullDiskAccess: FullDiskAccess.State,
                                timeout: TimeInterval) -> [UnreadableDiagnosis] {
        diagnose(paths, timeout: timeout) { diagnose($0, fullDiskAccess: fullDiskAccess) }
    }

    static func diagnose(_ paths: [String], timeout: TimeInterval,
                         using diagnoseOne: @escaping @Sendable (String) -> UnreadableDiagnosis) -> [UnreadableDiagnosis] {
        let results = DiagnosisResults(count: paths.count)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            for (index, path) in paths.enumerated() { results.set(index, diagnoseOne(path)) }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + max(0, timeout))
        return results.snapshot()
    }

    public static func folders(in tree: FileTree, under node: NodeID, limit: Int) -> (paths: [String], total: Int) {
        guard node >= 0, Int(node) < tree.nodeCount, !tree[node].isRemoved else { return ([], 0) }
        var pending = [node]
        var paths: [String] = []
        while let id = pending.popLast() {
            let item = tree[id]
            if item.isDirectory && (item.status == .unavailable || item.flags.contains(.listingIncomplete)) {
                paths.append(tree.path(of: id))
            }
            pending.append(contentsOf: tree.children(of: id))
        }
        paths.sort()
        return (Array(paths.prefix(max(0, limit))), paths.count)
    }
}

private final class DiagnosisResults: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UnreadableDiagnosis?]
    init(count: Int) { items = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: UnreadableDiagnosis) { lock.lock(); items[index] = value; lock.unlock() }
    func snapshot() -> [UnreadableDiagnosis] {
        lock.lock(); defer { lock.unlock() }
        return items.map { $0 ?? UnreadableDiagnosis(reason: .unknown, errno: nil, owner: nil) }
    }
}
