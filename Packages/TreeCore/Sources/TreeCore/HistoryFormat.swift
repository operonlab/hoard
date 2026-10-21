// On-disk layout of one history version (<id>.dshist), little-endian:
//
//   "DSHV"  u32 formatVersion (1)  u32 jsonLength  HistoryVersion JSON
//   u8 flags (bit 0: payload is LZFSE-compressed)
//   payload:
//     u64 createdAt (Double bit pattern, seconds since 2001)  i64 bigFileThreshold
//     u32 rootPathLength  rootPath UTF-8
//     u32 dirCount  u32 bigFileCount  u32 namesLength  names (UTF-8, concatenated)
//     dirCount × 29 bytes:     u32 nameOffset  u32 nameLength  i32 parent  u8 status  i64 totalAlloc  i64 fileCount
//     bigFileCount × 36 bytes: u32 nameOffset  u32 nameLength  i32 dir  i64 alloc  i64 modTime  i64 accessTime
//
// The JSON header is readable without touching the payload, so listing versions stays cheap.
// Readers accept both flag values; a compressed payload on a platform without Compression is corrupt.

import Foundation

enum HistoryFormat {
    static let magic: [UInt8] = [0x44, 0x53, 0x48, 0x56]   // "DSHV"
    static let formatVersion: UInt32 = 1
    static let flagCompressed: UInt8 = 1 << 0
    static let dirRecordSize = 29
    static let fileRecordSize = 36
    /// magic + version + json length
    static let prefixSize = 12

    struct Malformed: Error {}

    // MARK: Encoding

    static func encodePayload(_ s: TreeSummary) throws -> Data {
        var names = Data()
        var dirRanges: [(UInt32, UInt32)] = []
        var fileRanges: [(UInt32, UInt32)] = []
        dirRanges.reserveCapacity(s.dirs.count)
        fileRanges.reserveCapacity(s.bigFiles.count)
        func intern(_ name: String) throws -> (UInt32, UInt32) {
            let bytes = Array(name.utf8)
            guard names.count <= Int(UInt32.max) - bytes.count else { throw Malformed() }
            let range = (UInt32(names.count), UInt32(bytes.count))
            names.append(contentsOf: bytes)
            return range
        }
        for d in s.dirs { dirRanges.append(try intern(d.name)) }
        for f in s.bigFiles { fileRanges.append(try intern(f.name)) }
        let root = Array(s.rootPath.utf8)
        guard s.dirs.count <= Int(UInt32.max), s.bigFiles.count <= Int(UInt32.max) else { throw Malformed() }

        var w = ByteWriter(capacity: 32 + root.count + names.count
                           + s.dirs.count * dirRecordSize + s.bigFiles.count * fileRecordSize)
        w.put(s.createdAt.timeIntervalSinceReferenceDate.bitPattern)
        w.put(s.bigFileThreshold)
        w.put(UInt32(root.count)); w.put(bytes: root)
        w.put(UInt32(s.dirs.count)); w.put(UInt32(s.bigFiles.count))
        w.put(UInt32(names.count)); w.put(bytes: names)
        for (d, r) in zip(s.dirs, dirRanges) {
            w.put(r.0); w.put(r.1); w.put(d.parent); w.put(d.status.rawValue); w.put(d.totalAlloc); w.put(d.fileCount)
        }
        for (f, r) in zip(s.bigFiles, fileRanges) {
            w.put(r.0); w.put(r.1); w.put(f.dir); w.put(f.alloc); w.put(f.modTime); w.put(f.accessTime)
        }
        return w.data
    }

    /// Payload as stored, plus the flag byte describing it.
    static func pack(_ payload: Data) -> (flags: UInt8, body: Data) {
        #if canImport(Compression)
        // LZFSE stops at its end-of-stream marker and ignores anything after it, so the compressed
        // body carries both lengths: raw (u64) and compressed (u64), then the stream. Without them a
        // truncated-then-padded or appended file decodes as valid (caught on macOS, 2026-10-20).
        if let packed = try? (payload as NSData).compressed(using: .lzfse) as Data {
            var w = ByteWriter(capacity: 16 + packed.count)
            w.put(UInt64(payload.count))
            w.put(UInt64(packed.count))
            w.put(bytes: packed)
            return (flagCompressed, w.data)
        }
        #endif
        return (0, payload)
    }

    static func unpack(flags: UInt8, body: Data) throws -> Data {
        guard flags & ~flagCompressed == 0 else { throw Malformed() }
        if flags & flagCompressed == 0 { return body }
        #if canImport(Compression)
        var r = ByteReader(body)
        let rawLength = try r.u64()
        let packedLength = try r.u64()
        guard packedLength == UInt64(r.remaining) else { throw Malformed() }
        guard let raw = try? (Data(try r.bytes(r.remaining)) as NSData).decompressed(using: .lzfse) as Data,
              UInt64(raw.count) == rawLength else { throw Malformed() }
        return raw
        #else
        throw Malformed()
        #endif
    }

    static func file(header: Data, flags: UInt8, body: Data) -> Data {
        var w = ByteWriter(capacity: prefixSize + header.count + 1 + body.count)
        w.put(bytes: magic)
        w.put(formatVersion)
        w.put(UInt32(header.count)); w.put(bytes: header)
        w.put(flags)
        w.put(bytes: body)
        return w.data
    }

    // MARK: Decoding

    /// Parses magic, version and JSON length from the first `prefixSize` bytes.
    static func headerLength(prefix: Data) throws -> Int {
        var r = ByteReader(prefix)
        guard try r.bytes(4).elementsEqual(magic), try r.u32() == formatVersion else { throw Malformed() }
        return Int(try r.u32())
    }

    static func decodeHeader(_ json: Data) throws -> HistoryVersion {
        do { return try JSONDecoder().decode(HistoryVersion.self, from: json) } catch { throw Malformed() }
    }

    /// Whole file → header + summary.
    static func decode(_ data: Data) throws -> (HistoryVersion, TreeSummary) {
        var r = ByteReader(data)
        guard try r.bytes(4).elementsEqual(magic), try r.u32() == formatVersion else { throw Malformed() }
        let header = try decodeHeader(Data(try r.bytes(Int(try r.u32()))))
        let flags = try r.u8()
        let payload = try unpack(flags: flags, body: Data(try r.bytes(r.remaining)))
        let summary = try decodePayload(payload)
        guard summary.rootPath == header.rootPath else { throw Malformed() }
        return (header, summary)
    }

    static func decodePayload(_ data: Data) throws -> TreeSummary {
        var r = ByteReader(data)
        let created = Date(timeIntervalSinceReferenceDate: Double(bitPattern: try r.u64()))
        let threshold = try r.i64()
        guard let rootPath = String(bytes: try r.bytes(Int(try r.u32())), encoding: .utf8) else { throw Malformed() }
        let dirCount = Int(try r.u32())
        let fileCount = Int(try r.u32())
        let names = Array(try r.bytes(Int(try r.u32())))
        // Check sizes before allocating anything proportional to the counts.
        guard dirCount >= 1, dirCount <= r.remaining / dirRecordSize,
              fileCount <= (r.remaining - dirCount * dirRecordSize) / fileRecordSize,
              r.remaining == dirCount * dirRecordSize + fileCount * fileRecordSize else { throw Malformed() }
        func name(_ offset: UInt32, _ length: UInt32) throws -> String {
            let o = Int(offset), l = Int(length)
            guard o <= names.count, l <= names.count - o,
                  let s = String(bytes: names[o..<(o + l)], encoding: .utf8) else { throw Malformed() }
            return s
        }
        var dirs: [TreeSummary.Dir] = []
        dirs.reserveCapacity(dirCount)
        for i in 0..<dirCount {
            let off = try r.u32(), len = try r.u32()
            let parent = try r.i32()
            guard let status = ScanStatus(rawValue: try r.u8()) else { throw Malformed() }
            let total = try r.i64(), files = try r.i64()
            guard i == 0 ? parent == -1 : (parent >= 0 && Int(parent) < i) else { throw Malformed() }
            dirs.append(TreeSummary.Dir(parent: parent, name: try name(off, len), totalAlloc: total,
                                        fileCount: files, status: status))
        }
        var bigFiles: [TreeSummary.BigFile] = []
        bigFiles.reserveCapacity(fileCount)
        for _ in 0..<fileCount {
            let off = try r.u32(), len = try r.u32()
            let dir = try r.i32()
            let alloc = try r.i64(), mod = try r.i64(), access = try r.i64()
            guard dir >= 0, Int(dir) < dirCount else { throw Malformed() }
            bigFiles.append(TreeSummary.BigFile(dir: dir, name: try name(off, len), alloc: alloc,
                                                modTime: mod, accessTime: access))
        }
        return TreeSummary(rootPath: rootPath, createdAt: created, bigFileThreshold: threshold,
                           dirs: dirs, bigFiles: bigFiles)
    }
}

struct ByteWriter {
    private(set) var data: Data
    init(capacity: Int) { data = Data(); data.reserveCapacity(capacity) }
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    mutating func put<C: Collection>(bytes: C) where C.Element == UInt8 { data.append(contentsOf: bytes) }
}

/// Bounds-checked little-endian reader; every overrun throws instead of trapping.
struct ByteReader {
    private let buf: [UInt8]
    private var cursor = 0
    init(_ data: Data) { buf = [UInt8](data) }
    var remaining: Int { buf.count - cursor }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw HistoryFormat.Malformed() }
        defer { cursor += count }
        return buf[cursor..<(cursor + count)]
    }
    private mutating func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
        var v: T = 0
        for (shift, b) in try bytes(MemoryLayout<T>.size).enumerated() { v |= T(truncatingIfNeeded: b) << (shift * 8) }
        return v
    }
    mutating func u8() throws -> UInt8 { try int(UInt8.self) }
    mutating func u32() throws -> UInt32 { try int(UInt32.self) }
    mutating func i32() throws -> Int32 { try int(Int32.self) }
    mutating func u64() throws -> UInt64 { try int(UInt64.self) }
    mutating func i64() throws -> Int64 { try int(Int64.self) }
}
