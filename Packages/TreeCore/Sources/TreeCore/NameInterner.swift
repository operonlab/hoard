import Foundation

/// One stored String per distinct name, so repeated long names (`__init__.cpython-312.pyc` thousands
/// of times) share one heap buffer. Names of 15 UTF-8 bytes or less are stored inline by Swift and
/// pass through untouched.
///
/// Keyed on the exact UTF-8 bytes, never on `String ==` or `Set<String>`: String equality is canonical
/// equivalence, so an NFC "café…" would stand in for an NFD one and change paths and snapshot bytes.
struct NameInterner {
    /// Longest name Swift stores inline (no heap buffer to share).
    static let inlineLimit = 15

    /// Tag and String side by side, so a probe costs one cache miss before the byte compare.
    private struct Slot {
        var tag: UInt32 = 0
        var string: String?
    }

    /// Open addressing, linear probing, at most 3/4 full.
    private var slots: [Slot]
    private var mask: Int
    private var count = 0

    init(expected: Int = 1024) {
        var size = 16
        while size * 3 < expected * 4 { size <<= 1 }
        slots = [Slot](repeating: Slot(), count: size)
        mask = size - 1
    }

    /// The stored String with the same bytes as `name`, or `name` itself (now stored) when there is none.
    mutating func intern(_ name: String) -> String {
        guard name.utf8.count > Self.inlineLimit else { return name }
        if let shared = name.utf8.withContiguousStorageIfAvailable({ intern(bytes: UnsafeRawBufferPointer($0)) { name } }) {
            return shared
        }
        var contiguous = name
        contiguous.makeContiguousUTF8()
        return intern(contiguous)
    }

    /// The stored String with these bytes; on a miss `make()` builds it (and may reject the bytes).
    mutating func intern(bytes: UnsafeRawBufferPointer, make: () throws -> String) rethrows -> String {
        let h = Self.hash(bytes)
        let tag = UInt32(truncatingIfNeeded: h)
        var i = Int(tag) & mask
        while let stored = slots[i].string {
            if slots[i].tag == tag && Self.equal(stored, bytes) { return stored }
            i = (i + 1) & mask
        }
        let made = try make()
        slots[i] = Slot(tag: tag, string: made)
        count += 1
        if count * 4 > slots.count * 3 { grow() }
        return made
    }

    private mutating func grow() {
        let size = slots.count * 2
        var fresh = [Slot](repeating: Slot(), count: size)
        let newMask = size - 1
        // The tag is the low 32 bits of the hash: it places entries in tables of up to 2^32 slots.
        for slot in slots where slot.string != nil {
            var i = Int(slot.tag) & newMask
            while fresh[i].string != nil { i = (i + 1) & newMask }
            fresh[i] = slot
        }
        slots = fresh
        mask = newMask
    }

    private static func equal(_ stored: String, _ bytes: UnsafeRawBufferPointer) -> Bool {
        let utf8 = stored.utf8
        guard utf8.count == bytes.count else { return false }
        guard bytes.count > 0 else { return true }
        return utf8.withContiguousStorageIfAvailable { memcmp($0.baseAddress!, bytes.baseAddress!, bytes.count) == 0 }
            ?? utf8.elementsEqual(bytes)
    }

    /// FNV-1a over 8-byte words with a fold after each step, then the MurmurHash3 finalizer.
    static func hash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ UInt64(bytes.count)
        var i = 0
        while i + 8 <= bytes.count {
            h = (h ^ bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0x0000_0100_0000_01b3
            h ^= h >> 29
            i += 8
        }
        while i < bytes.count {
            h = (h ^ UInt64(bytes[i])) &* 0x0000_0100_0000_01b3
            i += 1
        }
        h ^= h >> 33; h &*= 0xff51_afd7_ed55_8ccd
        h ^= h >> 33; h &*= 0xc4ce_b9fe_1a85_ec53
        h ^= h >> 33
        return h
    }
}

/// The name table of one thread of the parallel snapshot read. A slot is a hash tag and the id of
/// the first record with those name bytes: 8 bytes instead of a stored String, so the tables of many
/// threads stay small. The caller compares the bytes and owns the Strings.
struct RecordNameTable {
    private var slots: [UInt64]  // tag << 32 | (id + 1); 0 = empty
    private var mask: Int
    private var count = 0

    init(expected: Int) {
        var size = 16
        while size * 3 < expected * 4 { size <<= 1 }
        slots = [UInt64](repeating: 0, count: size)
        mask = size - 1
    }

    /// The id stored for the same name (`same(storedID)` compares the bytes); nil after storing `id`.
    mutating func firstID(hash h: UInt64, id: Int32, same: (Int32) -> Bool) -> Int32? {
        let tag = h & 0xFFFF_FFFF
        var i = Int(tag) & mask
        while slots[i] != 0 {
            let stored = Int32(truncatingIfNeeded: slots[i] & 0xFFFF_FFFF) - 1
            if slots[i] >> 32 == tag && same(stored) { return stored }
            i = (i + 1) & mask
        }
        slots[i] = tag << 32 | UInt64(id + 1)
        count += 1
        if count * 4 > slots.count * 3 { grow() }
        return nil
    }

    private mutating func grow() {
        let size = slots.count * 2
        var fresh = [UInt64](repeating: 0, count: size)
        let newMask = size - 1
        for slot in slots where slot != 0 {
            var i = Int(slot >> 32) & newMask
            while fresh[i] != 0 { i = (i + 1) & newMask }
            fresh[i] = slot
        }
        slots = fresh
        mask = newMask
    }
}
