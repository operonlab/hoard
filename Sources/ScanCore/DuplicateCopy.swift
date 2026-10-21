import Darwin

/// One copy of a duplicate group as the comparison read it. Trashing a copy needs both it and another
/// copy to still be exactly that, so the last copy, or one edited since, is never taken.
public struct DuplicateCopy: Sendable, Equatable {
    public let path: String
    public let identity: FileIdentity
    public let size: Int64
    public let modTime: Int64

    public init(_ node: Node, path: String) {
        self.path = path
        identity = FileIdentity(node)
        size = node.logicalSize
        modTime = node.modTime
    }

    /// Same file (device and inode), same size and same modification second as when compared.
    public func unchanged() -> Bool {
        var st = stat()
        guard identity.stillAt(path), lstat(path, &st) == 0 else { return false }
        return Int64(st.st_size) == size && Int64(st.st_mtimespec.tv_sec) == modTime
    }
}
