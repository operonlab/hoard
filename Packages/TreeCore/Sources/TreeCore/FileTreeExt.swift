import Foundation

/// A file's extension as `FileTree.fileExtension` gives it, as a key that needs no String for the
/// common case: up to 8 ASCII bytes, lowercased and packed into an integer. Longer or non-ASCII
/// extensions keep the String the slow path returns, so every name maps to the same extension.
public struct ExtensionKey: Hashable, Sendable {
    let packed: UInt64      // 0 = no extension
    let other: String?

    public init(fileName name: String) {
        if let key = name.utf8.withContiguousStorageIfAvailable({ Self.fast($0) }) ?? nil {
            self = key
        } else {
            self.init(extension: FileTree.fileExtension(name))
        }
    }

    /// From an extension already lowercased the way `FileTree.fileExtension` does it.
    public init(extension ext: String) {
        if let packed = Self.pack(ext.utf8) { self.init(packed: packed, other: nil) } else { self.init(packed: 0, other: ext) }
    }

    private init(packed: UInt64, other: String?) {
        self.packed = packed
        self.other = other
    }

    public var string: String {
        if let other { return other }
        var bytes: [UInt8] = []
        var p = packed
        while p != 0 { bytes.append(UInt8(truncatingIfNeeded: p)); p >>= 8 }
        return String(decoding: bytes.reversed(), as: UTF8.self)
    }

    /// nil = needs the slow path (a long or non-ASCII extension).
    private static func fast(_ b: UnsafeBufferPointer<UInt8>) -> ExtensionKey? {
        guard let dot = b.lastIndex(of: 0x2E), dot != 0 else { return ExtensionKey(packed: 0, other: nil) }
        if dot == b.count - 1 { return b[dot - 1] < 0x80 ? ExtensionKey(packed: 0, other: nil) : nil }
        // `fileExtension` looks for "." as a whole Character: a prepend mark before it or a combining
        // mark after it merges the dot into a larger cluster, and non-ASCII lowercases differently.
        guard b.count - dot - 1 <= 8, b[dot - 1] < 0x80 else { return nil }
        var p: UInt64 = 0
        for i in (dot + 1)..<b.count {
            var c = b[i]
            guard c < 0x80, c != 0 else { return nil }
            if c >= 0x41 && c <= 0x5A { c += 0x20 }
            p = p << 8 | UInt64(c)
        }
        return ExtensionKey(packed: p, other: nil)
    }

    private static func pack(_ utf8: String.UTF8View) -> UInt64? {
        guard utf8.count <= 8 else { return nil }
        var p: UInt64 = 0
        for c in utf8 {
            guard c < 0x80, c != 0 else { return nil }
            p = p << 8 | UInt64(c)
        }
        return p
    }
}

extension FileTree {
    /// Below this many nodes one thread is faster than splitting the work.
    static let parallelThreshold = 50_000

    /// `extensionStats` in parallel chunks with integer keys. A root scope reads the node array
    /// straight through (every live node is reachable from the root); a sub-scope first collects
    /// its files with one walk.
    static func fastExtensionStats(in nodes: [Node], under id: NodeID) -> [ExtensionStat] {
        guard Int(id) < nodes.count, !nodes[Int(id)].isRemoved else { return [] }
        var files: [Int32] = []
        if id != Self.root {
            var stack = [id]
            while let cur = stack.popLast() {
                let n = nodes[Int(cur)]
                if n.isRemoved { continue }
                if n.isDirectory {
                    var c = n.firstChild
                    while c >= 0 { stack.append(c); c = nodes[Int(c)].nextSibling }
                } else {
                    files.append(cur)
                }
            }
        }
        let total = id == Self.root ? nodes.count : files.count
        let chunks = total < parallelThreshold ? 1 : min(ProcessInfo.processInfo.activeProcessorCount, 16)
        var partial = [[ExtensionKey: (Int64, Int64)]](repeating: [:], count: chunks)
        nodes.withUnsafeBufferPointer { all in
            files.withUnsafeBufferPointer { subset in
                partial.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                        let lo = total * chunk / chunks, hi = total * (chunk + 1) / chunks
                        var acc: [ExtensionKey: (Int64, Int64)] = [:]
                        for i in lo..<hi {
                            let n = all[id == Self.root ? i : Int(subset[i])]
                            if n.isRemoved || n.isDirectory { continue }
                            let key = ExtensionKey(fileName: n.name)
                            let v = acc[key, default: (0, 0)]
                            acc[key] = (v.0 + n.ownAlloc, v.1 + 1)
                        }
                        out[chunk] = acc
                    }
                }
            }
        }
        // The last fold is keyed by String, as before: String equality is canonical equivalence, so a
        // spelling like U+037E joins the row of ";" instead of making a second row that looks the same.
        var merged: [String: (Int64, Int64)] = [:]
        for part in partial {
            for (key, v) in part {
                let m = merged[key.string, default: (0, 0)]
                merged[key.string] = (m.0 + v.0, m.1 + v.1)
            }
        }
        return merged.map { ExtensionStat(ext: $0.key, bytes: $0.value.0, count: $0.value.1) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.ext < $1.ext }
    }
}
