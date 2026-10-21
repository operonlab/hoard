import Darwin
import Foundation

public enum InstallerEvidence {
    public static func downloadOrigin(path: String) -> String? {
        guard localRegularFile(path) != nil else { return nil }
        return withNoMaterialization {
            let key = "com.apple.metadata:kMDItemWhereFroms"
            let size = path.withCString { getxattr($0, key, nil, 0, 0, XATTR_NOFOLLOW) }
            guard size > 0, size <= 1_048_576 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { bytes in
                path.withCString { getxattr($0, key, bytes.baseAddress, size, 0, XATTR_NOFOLLOW) }
            }
            guard read == size,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return nil }
            return plist.first { value in
                guard let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme), let host = url.host else { return false }
                return !host.isEmpty
            }
        }
    }

    public static func archiveHoldsInstaller(path: String) -> Bool? {
        guard let original = localRegularFile(path) else { return nil }
        return withNoMaterialization {
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var current = stat()
            guard fstat(fd, &current) == 0, (current.st_mode & S_IFMT) == S_IFREG,
                  current.st_blocks > 0, current.st_dev == original.st_dev,
                  current.st_ino == original.st_ino else { return nil }
            let length = current.st_size
            guard length >= 22 else { return nil }
            let tailLength = min(Int64(65_557), length)
            guard let tail = readExactly(fd, at: length - tailLength, count: Int(tailLength)) else { return nil }
            guard tail.count >= 22 else { return nil }
            var eocd: Int?
            for i in stride(from: tail.count - 22, through: 0, by: -1) where word(tail, i) == 0x0605_4b50 {
                if i + 22 + Int(half(tail, i + 20)) == tail.count { eocd = i; break }
            }
            guard let eocd else { return nil }
            if eocd >= 20 && word(tail, eocd - 20) == 0x0706_4b50 { return nil }
            let disk = half(tail, eocd + 4), cdDisk = half(tail, eocd + 6)
            let diskEntries = half(tail, eocd + 8), entries = half(tail, eocd + 10)
            let cdSize = word(tail, eocd + 12), cdOffset = word(tail, eocd + 16)
            guard disk == 0, cdDisk == 0, diskEntries == entries,
                  entries != 0xffff, cdSize != 0xffff_ffff, cdOffset != 0xffff_ffff,
                  cdSize <= 8 * 1_048_576,
                  UInt64(cdOffset) + UInt64(cdSize) <= UInt64(length - tailLength + Int64(eocd)) else { return nil }
            guard let cd = readExactly(fd, at: Int64(cdOffset), count: Int(cdSize)) else { return nil }
            var cursor = 0
            var foundInstaller = false
            for _ in 0..<Int(entries) {
                guard cursor + 46 <= cd.count, word(cd, cursor) == 0x0201_4b50 else { return nil }
                let nameLength = Int(half(cd, cursor + 28))
                let extraLength = Int(half(cd, cursor + 30))
                let commentLength = Int(half(cd, cursor + 32))
                let end = cursor + 46 + nameLength + extraLength + commentLength
                guard end <= cd.count, word(cd, cursor + 42) != 0xffff_ffff else { return nil }
                var extra = cursor + 46 + nameLength
                let extraEnd = extra + extraLength
                while extra < extraEnd {
                    guard extra + 4 <= extraEnd else { return nil }
                    let field = half(cd, extra), fieldLength = Int(half(cd, extra + 2))
                    guard field != 0x0001, extra + 4 + fieldLength <= extraEnd else { return nil }
                    extra += 4 + fieldLength
                }
                let name = String(decoding: cd[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self).lowercased()
                if name.hasSuffix(".pkg") || name.hasSuffix(".dmg") || name.hasSuffix(".xip") || name.contains(".app/") {
                    foundInstaller = true
                }
                cursor = end
            }
            return cursor == cd.count ? foundInstaller : nil
        }
    }

    private static func localRegularFile(_ path: String) -> stat? {
        var s = stat()
        guard lstat(path, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG, s.st_blocks > 0 else { return nil }
        return s
    }

    /// Runs `body` with iCloud downloads turned off for this thread; nil (could not tell) without it.
    private static func withNoMaterialization<T>(_ body: () -> T?) -> T? {
        guard let restore = Materialization.offForThread("installer evidence") else { return nil }
        defer { restore() }
        return body()
    }

    private static func readExactly(_ fd: Int32, at offset: Int64, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var readCount = 0
        while readCount < count {
            let n = bytes.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress!.advanced(by: readCount), count - readCount, offset + Int64(readCount))
            }
            guard n > 0 else { return nil }
            readCount += n
        }
        return bytes
    }

    private static func half(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func word(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(half(b, i)) | (UInt32(half(b, i + 2)) << 16)
    }
}
