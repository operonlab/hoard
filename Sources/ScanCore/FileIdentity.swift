import Darwin

/// What a node pointed at when it was scanned. Destructive actions re-check it right before acting,
/// so a path that now names a different file (deleted and recreated, renamed over) is never touched.
public struct FileIdentity: Equatable, Sendable {
    public var device: Int32
    public var fileID: UInt64

    public init(device: Int32, fileID: UInt64) {
        self.device = device
        self.fileID = fileID
    }

    public init(_ node: Node) {
        self.init(device: node.device, fileID: node.fileID)
    }

    /// Identity of whatever is at `path` right now (symlinks are not followed), or nil if nothing is.
    public static func current(atPath path: String) -> FileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileIdentity(device: st.st_dev, fileID: UInt64(st.st_ino))
    }

    /// True only when `path` still names this exact file. An unknown identity (fileID 0) never matches.
    public func stillAt(_ path: String) -> Bool {
        guard fileID != 0, let now = Self.current(atPath: path) else { return false }
        return now == self
    }
}
