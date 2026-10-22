// CONTRACT (FROZEN signatures): `SnapshotMeta`, `Snapshot.write`, `Snapshot.read`, `Snapshot.defaultURL`.

import Foundation
#if canImport(Compression)
import Compression
#endif

public struct SnapshotMeta: Codable, Sendable, Equatable {
    public static let currentFormat = 3  // 2: + accessTime per node; 3: chunked LZFSE
    public var formatVersion: Int
    public var rootPath: String
    public var device: Int32
    public var createdAt: Date
    public var scanSeconds: Double
    /// FSEvents id at the moment the scan started; replaying from here catches everything since.
    public var lastEventId: UInt64
    /// FSEventsCopyUUIDForDevice at scan time; a different value means the journal was reset.
    public var eventsUUID: String?

    public init(rootPath: String, device: Int32, createdAt: Date, scanSeconds: Double,
                lastEventId: UInt64, eventsUUID: String?) {
        self.formatVersion = Self.currentFormat
        self.rootPath = rootPath; self.device = device; self.createdAt = createdAt
        self.scanSeconds = scanSeconds; self.lastEventId = lastEventId; self.eventsUUID = eventsUUID
    }
}

public enum SnapshotError: Error, Equatable, LocalizedError {
    case notImplemented
    case badMagic
    case unsupportedVersion(Int)
    case truncated

    public var errorDescription: String? {
        switch self {
        case .notImplemented: "scan cache operation is not implemented"
        case .badMagic: "not a Hoard scan cache"
        case .unsupportedVersion(let version): "scan cache format \(version) is not supported by this version of Hoard"
        case .truncated: "the scan cache is damaged or incomplete"
        }
    }
}

public enum Snapshot {
    private static let recordSize = 118

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        var cursor = 0
        while bytes.count - cursor >= 8 {
            let word = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor, as: UInt64.self))
            h = (h ^ word) &* 0x100000001b3
            h = (h << 13) | (h >> 51)
            cursor += 8
        }
        while cursor < bytes.count {
            h = (h ^ UInt64(bytes[cursor])) &* 0x100000001b3
            h = (h << 13) | (h >> 51)
            cursor += 1
        }
        return h
    }

    /// Writes atomically (temp file + rename). Chunks of nodes encode in parallel and each writes its
    /// names and records straight to their place in the file, so no copy of the whole file is ever
    /// held in memory.
    public static func write(_ tree: FileTree, meta: SnapshotMeta, to url: URL) throws {
        try write(tree, meta: meta, to: url, block: 32_768)
    }

    /// `block`: nodes a writer chunk encodes before each write call; tests lower it to cross block boundaries.
    static func write(_ tree: FileTree, meta: SnapshotMeta, to url: URL, block: Int, chunkBytes: Int = 8 << 20) throws {
        #if canImport(Compression)
        guard chunkBytes > 0, chunkBytes <= Int(UInt32.max) else { throw SnapshotError.truncated }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rawURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).raw.tmp")
        defer { try? fm.removeItem(at: rawURL) }
        try writeUncompressed(tree, meta: meta, to: rawURL, block: block)
        let raw = try Data(contentsOf: rawURL, options: .alwaysMapped)
        try raw.withUnsafeBytes { source in
            guard source.count >= 12 else { throw SnapshotError.truncated }
            let jsonLength = Int(UInt32(littleEndian: source.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
            guard jsonLength <= source.count - 12 else { throw SnapshotError.truncated }
            let bodyStart = 12 + jsonLength
            let bodyLength = source.count - bodyStart
            let chunkCount = (bodyLength / chunkBytes) + (bodyLength % chunkBytes == 0 ? 0 : 1)
            guard chunkCount <= Int(UInt32.max) else { throw SnapshotError.truncated }
            var compressed = [[UInt8]](repeating: [], count: chunkCount)
            var checksums = [UInt64](repeating: 0, count: chunkCount)
            var failed = [Bool](repeating: false, count: chunkCount)
            compressed.withUnsafeMutableBufferPointer { outputs in
                checksums.withUnsafeMutableBufferPointer { hashes in
                    failed.withUnsafeMutableBufferPointer { failures in
                        DispatchQueue.concurrentPerform(iterations: chunkCount) { i in
                            let offset = bodyStart + i * chunkBytes
                            let length = min(chunkBytes, source.count - offset)
                            let input = UnsafeRawBufferPointer(start: source.baseAddress! + offset, count: length)
                            hashes[i] = checksum(input)
                            var output = [UInt8](repeating: 0, count: length + 64)
                            let encoded = output.withUnsafeMutableBufferPointer { dest in
                                compression_encode_buffer(dest.baseAddress!, dest.count,
                                                          input.baseAddress!.assumingMemoryBound(to: UInt8.self), length,
                                                          nil, COMPRESSION_LZFSE)
                            }
                            if encoded == 0 { failures[i] = true; return }
                            output.removeSubrange(encoded..<output.count)
                            outputs[i] = output
                        }
                    }
                }
            }
            guard !failed.contains(true) else { throw SnapshotError.truncated }
            var header = Data([0x44, 0x53, 0x43, 0x4e])
            func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
            var compressedMeta = meta
            compressedMeta.formatVersion = 3
            let json = try JSONEncoder().encode(compressedMeta)
            guard json.count <= Int(UInt32.max) else { throw SnapshotError.truncated }
            append(UInt32(3)); append(UInt32(json.count))
            header.append(json); append(UInt64(bodyLength)); append(UInt32(chunkCount))
            for i in 0..<chunkCount {
                append(UInt32(min(chunkBytes, bodyLength - i * chunkBytes)))
                append(UInt32(compressed[i].count)); append(checksums[i])
            }
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var closed = false
            do {
                defer { if !closed { close(fd) } }
                var offset = 0
                func put(_ bytes: UnsafeRawBufferPointer) throws {
                    let status = writeAll(fd, bytes, at: offset)
                    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
                    offset += bytes.count
                }
                try header.withUnsafeBytes { try put($0) }
                for chunk in compressed { try chunk.withUnsafeBytes { try put($0) } }
                closed = true
                guard close(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if rename(temp.path, url.path) != 0 { throw CocoaError(.fileWriteUnknown) }
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        }
        #else
        try writeUncompressed(tree, meta: meta, to: url, block: block)
        #endif
    }

    static func writeUncompressed(_ tree: FileTree, meta: SnapshotMeta, to url: URL, block: Int = 32_768) throws {
        var meta = meta
        meta.formatVersion = 2
        let metadata = try JSONEncoder().encode(meta)
        let old = tree.nodes
        let chunks = old.count < 65_536 ? 1 : min(ProcessInfo.processInfo.activeProcessorCount, 16)
        func bounds(_ chunk: Int) -> Range<Int> { old.count * chunk / chunks ..< old.count * (chunk + 1) / chunks }
        // Pass 1: live nodes and name bytes per chunk, then where each chunk starts in the output.
        var liveIn = [Int](repeating: 0, count: chunks), nameIn = [Int](repeating: 0, count: chunks)
        old.withUnsafeBufferPointer { all in
            liveIn.withUnsafeMutableBufferPointer { liveIn in
                nameIn.withUnsafeMutableBufferPointer { nameIn in
                    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                        var live = 0, bytes = 0
                        for i in bounds(chunk) where !all[i].isRemoved { live += 1; bytes += all[i].name.utf8.count }
                        liveIn[chunk] = live; nameIn[chunk] = bytes
                    }
                }
            }
        }
        var liveStart = [0], nameStart = [0]
        for chunk in 0..<chunks { liveStart.append(liveStart[chunk] + liveIn[chunk]); nameStart.append(nameStart[chunk] + nameIn[chunk]) }
        let liveCount = liveStart[chunks], nameCount = nameStart[chunks]
        guard metadata.count <= Int(UInt32.max), liveCount <= Int(UInt32.max), nameCount <= Int(UInt32.max) else {
            throw SnapshotError.truncated
        }
        let namesAt = 4 + 4 + 4 + metadata.count + 4 + 4
        let recordsAt = namesAt + nameCount
        let (recordsSize, overflow) = liveCount.multipliedReportingOverflow(by: recordSize)
        guard !overflow, recordsAt <= Int.max - recordsSize else { throw SnapshotError.truncated }
        // Pass 2: the id each live node gets in the file (removed nodes are dropped).
        var ids = [Int32](repeating: -1, count: old.count)
        old.withUnsafeBufferPointer { all in
            ids.withUnsafeMutableBufferPointer { ids in
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    var next = Int32(liveStart[chunk])
                    for i in bounds(chunk) where !all[i].isRemoved { ids[i] = next; next += 1 }
                }
            }
        }
        var header = Data([0x44, 0x53, 0x43, 0x4e])
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        append(UInt32(2))
        append(UInt32(metadata.count)); header.append(metadata)
        append(UInt32(liveCount))
        append(UInt32(nameCount))

        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var closed = false
        do {
            defer { if !closed { close(fd) } }
            var status = header.withUnsafeBytes { writeAll(fd, $0, at: 0) }
            // Pass 3: each chunk encodes blocks of nodes and writes their names and records in place.
            var failures = [Int32](repeating: 0, count: chunks)
            old.withUnsafeBufferPointer { all in
                ids.withUnsafeBufferPointer { ids in
                    failures.withUnsafeMutableBufferPointer { failures in
                        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                            failures[chunk] = writeChunk(all, ids, bounds(chunk), block: block, fd: fd,
                                                         names: (namesAt, nameStart[chunk]), records: (recordsAt, liveStart[chunk]))
                        }
                    }
                }
            }
            if status == 0 { status = failures.first { $0 != 0 } ?? 0 }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
            closed = true
            guard close(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if rename(temp.path, url.path) != 0 { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Writes every byte of `bytes` at `offset`; 0, or the errno that stopped it.
    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer, at offset: Int) -> Int32 {
        var done = 0
        while done < bytes.count {
            let n = pwrite(fd, bytes.baseAddress! + done, bytes.count - done, off_t(offset + done))
            if n < 0 {
                if errno == EINTR { continue }
                return errno
            }
            if n == 0 { return EIO }
            done += n
        }
        return 0
    }

    /// Encodes the live nodes of `range` and writes them: names from `names.base + names.start`,
    /// records from record number `records.first`. 0, or the errno that stopped it.
    private static func writeChunk(_ old: UnsafeBufferPointer<Node>, _ ids: UnsafeBufferPointer<Int32>, _ range: Range<Int>, block: Int, fd: Int32,
                                   names: (base: Int, start: Int), records: (base: Int, first: Int)) -> Int32 {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: block * recordSize, alignment: 8)
        defer { buffer.deallocate() }
        var nameBytes: [UInt8] = []
        var nameCursor = names.start, liveIndex = records.first
        func mapped(_ id: NodeID) -> Int32 { id < 0 ? -1 : ids[Int(id)] }
        var i = range.lowerBound
        while i < range.upperBound {
            let end = min(range.upperBound, i + block)
            let firstName = nameCursor, firstLive = liveIndex
            nameBytes.removeAll(keepingCapacity: true)
            var cursor = 0
            func put<T: FixedWidthInteger>(_ value: T) {
                buffer.storeBytes(of: value.littleEndian, toByteOffset: cursor, as: T.self)
                cursor += MemoryLayout<T>.size
            }
            for j in i..<end where !old[j].isRemoved {
                let n = old[j]
                var child = n.firstChild
                while child >= 0 && old[Int(child)].isRemoved { child = old[Int(child)].nextSibling }
                var sibling = n.nextSibling
                while sibling >= 0 && old[Int(sibling)].isRemoved { sibling = old[Int(sibling)].nextSibling }
                let length = n.name.utf8.count
                put(UInt32(nameCursor)); put(UInt32(length))
                put(mapped(n.parent)); put(mapped(child)); put(mapped(sibling))
                put(n.flags.rawValue); put(n.status.rawValue)
                put(n.rawAlloc); put(n.ownAlloc); put(n.logicalSize); put(n.modTime); put(n.accessTime)
                put(n.fileID); put(n.cloneID); put(n.linkCount); put(n.device)
                put(n.totalAlloc); put(n.totalLogical); put(n.fileCount); put(n.dirCount)
                nameBytes.append(contentsOf: n.name.utf8)
                nameCursor += length
                liveIndex += 1
            }
            let status = nameBytes.withUnsafeBytes { writeAll(fd, $0, at: names.base + firstName) }
            guard status == 0 else { return status }
            let written = writeAll(fd, UnsafeRawBufferPointer(rebasing: buffer[..<cursor]), at: records.base + firstLive * recordSize)
            guard written == 0 else { return written }
            i = end
        }
        return 0
    }

    public static func read(from url: URL) throws -> (tree: FileTree, meta: SnapshotMeta) {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try data.withUnsafeBytes { bytes in
            var cursor = 0
            func take<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
                guard cursor <= bytes.count, bytes.count - cursor >= MemoryLayout<T>.size else { throw SnapshotError.truncated }
                let result = T(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor, as: T.self))
                cursor += MemoryLayout<T>.size
                return result
            }
            func takeBytes(_ length: Int) throws -> UnsafeRawBufferPointer {
                guard length >= 0, cursor <= bytes.count, length <= bytes.count - cursor else { throw SnapshotError.truncated }
                let slice = UnsafeRawBufferPointer(rebasing: bytes[cursor..<(cursor + length)])
                cursor += length
                return slice
            }
            let magic = try takeBytes(4)
            guard Array(magic) == [0x44, 0x53, 0x43, 0x4e] else { throw SnapshotError.badMagic }
            let version = try take(UInt32.self)
            guard version == 2 || version == 3 else { throw SnapshotError.unsupportedVersion(Int(version)) }
            let jsonLength = try Int(take(UInt32.self))
            let json = try takeBytes(jsonLength)
            let meta: SnapshotMeta
            do { meta = try JSONDecoder().decode(SnapshotMeta.self, from: Data(json)) }
            catch { throw SnapshotError.truncated }
            guard meta.formatVersion == version else { throw SnapshotError.unsupportedVersion(meta.formatVersion) }
            if version == 2 {
                return try parseBody(UnsafeRawBufferPointer(rebasing: bytes[cursor...]), meta: meta)
            }
            #if canImport(Compression)
            let rawLength64 = try take(UInt64.self)
            guard rawLength64 <= Int.max else { throw SnapshotError.truncated }
            let rawLength = Int(rawLength64)
            let chunkCount = Int(try take(UInt32.self))
            guard chunkCount > 0, chunkCount <= (bytes.count - cursor) / 16 else { throw SnapshotError.truncated }
            struct Entry { let raw: Int; let compressed: Int; let hash: UInt64; let source: Int; let destination: Int }
            var table: [Entry] = []
            table.reserveCapacity(chunkCount)
            var rawOffset = 0
            for i in 0..<chunkCount {
                let length = Int(try take(UInt32.self))
                let compressed = Int(try take(UInt32.self))
                let hash = try take(UInt64.self)
                guard length > 0, length <= 8 << 20, compressed > 0, length <= rawLength - rawOffset,
                      (i == 0 || i == chunkCount - 1 || length == table[0].raw),
                      (i == 0 || i != chunkCount - 1 || length <= table[0].raw) else { throw SnapshotError.truncated }
                table.append(Entry(raw: length, compressed: compressed, hash: hash, source: 0, destination: rawOffset))
                rawOffset += length
            }
            guard rawOffset == rawLength else { throw SnapshotError.truncated }
            var compressedOffset = cursor
            for i in table.indices {
                guard table[i].compressed <= bytes.count - compressedOffset else { throw SnapshotError.truncated }
                let e = table[i]
                table[i] = Entry(raw: e.raw, compressed: e.compressed, hash: e.hash,
                                 source: compressedOffset, destination: e.destination)
                compressedOffset += e.compressed
            }
            guard compressedOffset == bytes.count else { throw SnapshotError.truncated }
            // Every byte is written by a chunk before it is read, so the buffer is not zero-filled first:
            // filling 560 MB cost more than decompressing it.
            let output = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: rawLength)
            defer { output.deallocate() }
            var failed = [Bool](repeating: false, count: chunkCount)
            do {
                failed.withUnsafeMutableBufferPointer { failures in
                    DispatchQueue.concurrentPerform(iterations: chunkCount) { i in
                        let e = table[i]
                        let dest = output.baseAddress! + e.destination
                        let source = (bytes.baseAddress! + e.source).assumingMemoryBound(to: UInt8.self)
                        let decoded = compression_decode_buffer(dest, e.raw, source, e.compressed, nil, COMPRESSION_LZFSE)
                        if decoded != e.raw || checksum(UnsafeRawBufferPointer(start: dest, count: e.raw)) != e.hash {
                            failures[i] = true
                        }
                    }
                }
            }
            guard !failed.contains(true) else { throw SnapshotError.truncated }
            return try parseBody(UnsafeRawBufferPointer(output), meta: meta)
            #else
            throw SnapshotError.unsupportedVersion(3)
            #endif
        }
    }

    private static func parseBody(_ bytes: UnsafeRawBufferPointer, meta: SnapshotMeta) throws -> (tree: FileTree, meta: SnapshotMeta) {
            var cursor = 0
            func take<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
                guard cursor <= bytes.count, bytes.count - cursor >= MemoryLayout<T>.size else { throw SnapshotError.truncated }
                let result = T(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor, as: T.self))
                cursor += MemoryLayout<T>.size
                return result
            }
            func takeBytes(_ length: Int) throws -> UnsafeRawBufferPointer {
                guard length >= 0, cursor <= bytes.count, length <= bytes.count - cursor else { throw SnapshotError.truncated }
                let slice = UnsafeRawBufferPointer(rebasing: bytes[cursor..<(cursor + length)])
                cursor += length
                return slice
            }
            let count = try Int(take(UInt32.self))
            let nameLength = try Int(take(UInt32.self))
            let names = try takeBytes(nameLength)
            guard count > 0, count <= (bytes.count - cursor) / recordSize,
                  bytes.count - cursor == count * recordSize else { throw SnapshotError.truncated }
            // Every record is in bounds (checked above), so fields load at fixed offsets in write order:
            // name offset, name length, parent, first child, next sibling, flags, status, rawAlloc, ownAlloc,
            // logicalSize, modTime, accessTime, fileID, cloneID, linkCount, device, totalAlloc, totalLogical,
            // fileCount, dirCount.
            let records = cursor
            func field<T: FixedWidthInteger>(_ record: Int, _ at: Int, _: T.Type) -> T {
                T(littleEndian: bytes.loadUnaligned(fromByteOffset: record + at, as: T.self))
            }
            /// The exact bytes as a String; nil for invalid UTF-8 (decoding would have repaired it,
            /// so the result's bytes differ from the input).
            func utf8String(_ raw: UnsafeRawBufferPointer) -> String? {
                let made = String(decoding: raw.assumingMemoryBound(to: UInt8.self), as: UTF8.self)
                guard made.utf8.count == raw.count else { return nil }
                return raw.count == 0 || made.utf8.withContiguousStorageIfAvailable({ memcmp($0.baseAddress!, raw.baseAddress!, raw.count) == 0 }) == true
                    ? made : nil
            }
            /// `nodes` holds every record of this chunk before `index`, already decoded.
            func decode(_ index: Int, _ table: inout RecordNameTable, _ nodes: UnsafeMutablePointer<Node>) throws -> Node {
                let r = records + index * recordSize
                let offset = Int(field(r, 0, UInt32.self))
                let length = Int(field(r, 4, UInt32.self))
                guard offset <= names.count, length <= names.count - offset else { throw SnapshotError.truncated }
                let nameBytes = UnsafeRawBufferPointer(rebasing: names[offset..<(offset + length)])
                let name: String
                if length > NameInterner.inlineLimit {
                    // Long names repeat: an earlier record with the same (validated) bytes lends its String.
                    let earlier = table.firstID(hash: NameInterner.hash(nameBytes), id: Int32(index)) { other in
                        let o = records + Int(other) * recordSize
                        return Int(field(o, 4, UInt32.self)) == length
                            && memcmp(names.baseAddress! + Int(field(o, 0, UInt32.self)), nameBytes.baseAddress!, length) == 0
                    }
                    if let earlier {
                        name = nodes[Int(earlier)].name
                    } else {
                        guard let made = utf8String(nameBytes) else { throw SnapshotError.truncated }
                        name = made
                    }
                } else {
                    guard let made = utf8String(nameBytes) else { throw SnapshotError.truncated }
                    name = made
                }
                let parent = field(r, 8, Int32.self)
                let first = field(r, 12, Int32.self)
                let next = field(r, 16, Int32.self)
                let flags = NodeFlags(rawValue: field(r, 20, UInt8.self))
                guard !flags.contains(.removed), let status = ScanStatus(rawValue: field(r, 21, UInt8.self)) else { throw SnapshotError.truncated }
                let rawAlloc = field(r, 22, Int64.self)
                let ownAlloc = field(r, 30, Int64.self)
                let logicalSize = field(r, 38, Int64.self)
                let modTime = field(r, 46, Int64.self)
                let accessTime = field(r, 54, Int64.self)
                let fileID = field(r, 62, UInt64.self)
                let cloneID = field(r, 70, UInt64.self)
                let linkCount = field(r, 78, UInt32.self)
                let device = field(r, 82, Int32.self)
                let totalAlloc = field(r, 86, Int64.self)
                let totalLogical = field(r, 94, Int64.self)
                let fileCount = field(r, 102, Int64.self)
                let dirCount = field(r, 110, Int64.self)
                // Node stores the counts as Int32; a value outside that range is a corrupt file, not a trap.
                guard 0...Int64(Int32.max) ~= fileCount, 0...Int64(Int32.max) ~= dirCount,
                      (index == 0 ? parent == -1 : parent >= 0 && parent < index),
                      first == -1 || first > index && first < count,
                      next == -1 || next != index && next >= 0 && next < count else { throw SnapshotError.truncated }
                return Node(name: name, parent: parent, firstChild: first, nextSibling: next,
                            flags: flags, status: status, rawAlloc: rawAlloc, ownAlloc: ownAlloc,
                            logicalSize: logicalSize, modTime: modTime, fileID: fileID, cloneID: cloneID,
                            linkCount: linkCount, device: device, totalAlloc: totalAlloc,
                            totalLogical: totalLogical, fileCount: fileCount, dirCount: dirCount,
                            accessTime: accessTime)
            }
            // Records decode in parallel chunks, each filling its own range of the array with its own name
            // table, and listing its nodes that need a dedup holder, in index order.
            let chunks = count < 65_536 ? 1 : min(ProcessInfo.processInfo.activeProcessorCount, 16)
            var decoded = [Int](repeating: 0, count: chunks)
            var failed = [Bool](repeating: false, count: chunks)
            var dedupIDs = [[Int32]](repeating: [], count: chunks)
            let nodes = try [Node](unsafeUninitializedCapacity: count) { buffer, initialized in
                let base = buffer.baseAddress!
                decoded.withUnsafeMutableBufferPointer { decoded in
                    failed.withUnsafeMutableBufferPointer { failed in
                        dedupIDs.withUnsafeMutableBufferPointer { dedupIDs in
                            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                                let lo = count * chunk / chunks, hi = count * (chunk + 1) / chunks
                                var ids: [Int32] = []
                                var table = RecordNameTable(expected: (hi - lo) / 8)
                                var index = lo
                                while index < hi {
                                    // Stop at the first bad record: the name table already holds its id, and a
                                    // later record with the same name would read that uninitialized node.
                                    guard let node = try? decode(index, &table, base) else { failed[chunk] = true; break }
                                    if !node.isDirectory && FileTree.dedupKey(node) != nil { ids.append(Int32(index)) }
                                    (base + index).initialize(to: node)
                                    index += 1
                                }
                                decoded[chunk] = index - lo
                                dedupIDs[chunk] = ids
                            }
                        }
                    }
                }
                if failed.contains(true) {
                    for chunk in 0..<chunks { (base + count * chunk / chunks).deinitialize(count: decoded[chunk]) }
                    throw SnapshotError.truncated
                }
                initialized = count
            }
            guard nodes[0].name == meta.rootPath, nodes[0].device == meta.device,
                  nodes[0].flags.contains(.directory), nodes[0].nextSibling == -1 else { throw SnapshotError.truncated }
            var visited = [Bool](repeating: false, count: count)
            var stack: [NodeID] = [0]
            while let id = stack.popLast() {
                guard !visited[Int(id)] else { throw SnapshotError.truncated }
                visited[Int(id)] = true
                var child = nodes[Int(id)].firstChild
                var steps = 0
                var files: Int64 = 0, dirs: Int64 = 0
                while child >= 0 {
                    guard steps < count, nodes[Int(child)].parent == id else { throw SnapshotError.truncated }
                    files += nodes[Int(child)].fileCount
                    dirs += nodes[Int(child)].dirCount
                    stack.append(child)
                    child = nodes[Int(child)].nextSibling
                    steps += 1
                }
                // Counts must add up (a folder is itself plus its children), so live mutation of a
                // restored tree can never carry one outside 0...Int32.max.
                let n = nodes[Int(id)]
                let expected = n.isDirectory ? (files, dirs + 1) : (Int64(1), Int64(0))
                guard n.isDirectory || steps == 0, n.fileCount == expected.0, n.dirCount == expected.1 else {
                    throw SnapshotError.truncated
                }
            }
            guard visited.allSatisfy({ $0 }) else { throw SnapshotError.truncated }
            return (FileTree(restoring: nodes, rootPath: meta.rootPath, device: meta.device,
                             dedupCandidates: Array(dedupIDs.joined())), meta)
    }

    /// ~/Library/Caches/Hoard/<stable hash of rootPath>.dscan (the folder is `HoardStorage.folderName`)
    public static func defaultURL(forRoot root: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var h: UInt64 = 0xcbf29ce484222325
        for b in root.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return caches.appendingPathComponent(HoardStorage.folderName, isDirectory: true)
            .appendingPathComponent(String(h, radix: 16) + ".dscan")
    }
}
