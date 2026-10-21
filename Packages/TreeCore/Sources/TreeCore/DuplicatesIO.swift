import Foundation

/// File access for the duplicate finder: identity samples (lstat), bounded reads and FNV-1a 64.
///
/// Read-only by construction: files are opened with `FileHandle(forReadingFrom:)` and nothing else.
/// Only the throwing FileHandle APIs are used (`seek(toOffset:)`, `read(upToCount:)`, `close()`);
/// the legacy `readData(ofLength:)` / `seek(toFileOffset:)` / `readDataToEndOfFile()` trap on IO
/// errors, which would turn "unreadable → skipped" into a crash.
enum DuplicatesIO {
    // MARK: FNV-1a 64

    static let fnvBasis: UInt64 = 0xcbf29ce484222325
    static let fnvPrime: UInt64 = 0x100000001b3

    /// Byte-wise FNV-1a 64 (xor, then multiply). Pass a previous result as `seed` to continue.
    static func fnv1a64<S: Sequence>(_ bytes: S, seed: UInt64 = fnvBasis) -> UInt64 where S.Element == UInt8 {
        var h = seed
        for b in bytes {
            h ^= UInt64(b)
            h = h &* fnvPrime
        }
        return h
    }

    // MARK: Identity

    /// What lstat said about a file. Two samples must be equal around every open/close.
    struct Sample: Equatable {
        var size: Int64
        var inode: UInt64
        var modified: Date?
    }

    struct Failure: Error {
        enum Kind { case changed, unreadable }
        var kind: Kind
        var path: String
        var detail: String
    }

    /// lstat via `attributesOfItem(atPath:)`, which does not follow a final-component symlink.
    /// The file must still be a regular file of `size` bytes and, when `fileID != 0`, the same inode.
    /// A vanished file (ENOENT) is `changed`; any other lstat error is `unreadable`.
    static func checkedSample(_ path: String, size: Int64, fileID: UInt64) throws -> Sample {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            let kind: Failure.Kind = isNoSuchFile(error) ? .changed : .unreadable
            throw Failure(kind: kind, path: path, detail: "lstat: \(error)")
        }
        guard fileType(attrs[.type]) == .typeRegular else {
            throw Failure(kind: .changed, path: path, detail: "no longer a regular file (\(String(describing: attrs[.type])))")
        }
        let s = Sample(size: int64(attrs[.size]) ?? -1, inode: uint64(attrs[.systemFileNumber]) ?? 0,
                       modified: attrs[.modificationDate] as? Date)
        guard s.size == size else {
            throw Failure(kind: .changed, path: path, detail: "size \(s.size), expected \(size)")
        }
        guard fileID == 0 || s.inode == fileID else {
            throw Failure(kind: .changed, path: path, detail: "inode \(s.inode), expected \(fileID)")
        }
        return s
    }

    /// `CocoaError.fileReadNoSuchFile`, or an underlying POSIX errno 2 (ENOENT).
    /// macOS reports code 260 + underlying errno 2 (probed 2026-10-20).
    static func isNoSuchFile(_ error: Error) -> Bool {
        if let c = error as? CocoaError, c.code == .fileReadNoSuchFile { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileReadNoSuchFile.rawValue { return true }
        // Corelibs stores the underlying error as a Swift Error that does not cast `as? NSError`.
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            let un = u as NSError
            if un.domain == NSPOSIXErrorDomain && un.code == 2 { return true }
        }
        return false
    }

    /// Attribute values are NSNumber on corelibs and bridged numbers on macOS; accept either.
    static func int64(_ v: Any?) -> Int64? {
        switch v {
        case let n as NSNumber: return n.int64Value
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as UInt64: return Int64(exactly: n)
        default: return nil
        }
    }

    static func uint64(_ v: Any?) -> UInt64? {
        switch v {
        case let n as NSNumber: return n.uint64Value
        case let n as UInt64: return n
        case let n as Int: return UInt64(exactly: n)
        case let n as Int64: return UInt64(exactly: n)
        default: return nil
        }
    }

    static func fileType(_ v: Any?) -> FileAttributeType? {
        switch v {
        case let t as FileAttributeType: return t
        case let s as String: return FileAttributeType(rawValue: s)
        default: return nil
        }
    }

    // MARK: Reads

    typealias Opener = (String) throws -> FileHandle

    static func openForReading(_ path: String) throws -> FileHandle {
        try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    }

    /// lstat, open, run `body`, close, lstat again; both samples must agree (and match `expected`
    /// when given). Throws `Failure` for a changed or unreadable file; errors thrown by `body` that
    /// are not `Failure` pass through untouched.
    ///
    /// Foundation ceiling: FileHandle has no `O_NOFOLLOW`, so a symlink swapped in between the
    /// lstat and the open cannot be refused here; the re-lstat after close narrows that window and
    /// ScanCore can tighten it later with open(2). Intermediate path components are followed by
    /// necessity (the macOS temp dir lives under /var → /private/var).
    static func withFile<T>(_ path: String, size: Int64, fileID: UInt64, expected: Sample?,
                            open: Opener, _ body: (FileHandle) throws -> T) throws -> (T, Sample) {
        let before = try checkedSample(path, size: size, fileID: fileID)
        if let expected, expected != before {
            throw Failure(kind: .changed, path: path, detail: "identity changed since it was first read")
        }
        let result: T
        do {
            let handle: FileHandle
            do {
                handle = try open(path)
            } catch {
                throw Failure(kind: .unreadable, path: path, detail: "open: \(error)")
            }
            defer { try? handle.close() }
            result = try body(handle)
        }
        let after = try checkedSample(path, size: size, fileID: fileID)
        guard after == before else {
            throw Failure(kind: .changed, path: path, detail: "identity changed while reading")
        }
        return (result, after)
    }

    static func seek(_ handle: FileHandle, to offset: Int64, path: String) throws {
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
        } catch {
            throw Failure(kind: .unreadable, path: path, detail: "seek: \(error)")
        }
    }

    /// Reads exactly `count` bytes from the current offset, looping over short reads.
    /// A read error is `unreadable`; EOF before `count` (the file shrank) is `changed`.
    static func readExactly(_ handle: FileHandle, count: Int, path: String, bytesRead: inout Int64) throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk: Data?
            do {
                chunk = try drained { try handle.read(upToCount: count - data.count) }
            } catch {
                throw Failure(kind: .unreadable, path: path, detail: "read: \(error)")
            }
            guard let chunk, !chunk.isEmpty else { break }
            bytesRead += Int64(chunk.count)
            data.append(chunk)
        }
        guard data.count == count else {
            throw Failure(kind: .changed, path: path, detail: "short read: \(data.count) of \(count) bytes")
        }
        return data
    }

    /// On Darwin `read(upToCount:)` hands back an autoreleased NSData. A comparison run is one long
    /// loop with no pool boundary, so without this every chunk read stayed alive until the run ended
    /// (3.9 GB peak after reading 3.8 GB).
    private static func drained<T>(_ body: () throws -> T) rethrows -> T {
        #if canImport(ObjectiveC)
        return try autoreleasepool(invoking: body)
        #else
        return try body()
        #endif
    }

    /// FNV-1a 64 of the byte range `[start, start + count)`.
    static func hashRange(_ handle: FileHandle, start: Int64, count: Int, path: String,
                          bytesRead: inout Int64) throws -> UInt64 {
        guard count > 0 else { return fnvBasis }
        try seek(handle, to: start, path: path)
        return fnv1a64(try readExactly(handle, count: count, path: path, bytesRead: &bytesRead))
    }
}
