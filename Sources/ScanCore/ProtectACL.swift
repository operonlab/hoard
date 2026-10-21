import Darwin
import Darwin.membership
import Foundation

/// Hoard's macOS ACL entry operations. Writes use the link variant so a replaced path
/// cannot redirect an ACL write through a symlink.
enum ProtectionACL {
    static func contains(_ path: String, directory: Bool, inheritedOnly: Bool = false) -> Bool {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let everyone = everyoneUUID() else { return false }
        return (try? entries(in: acl).contains { entry in
            matches(entry, everyone: everyone, directory: directory, inheritedOnly: inheritedOnly,
                    inherit: nil, exact: false)
        }) ?? false
    }

    static func change(_ path: String, directory: Bool, add: Bool, inherit: Bool = false,
                       includeInherited: Bool = false) throws {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else {
            throw ProtectionError.invalid("ACL path is missing or is a symlink: \(path)")
        }
        var acl = acl_get_file(path, ACL_TYPE_EXTENDED)
        if acl == nil && add { acl = acl_init(1) }
        guard acl != nil else { throw systemError("acl_get_file", path) }
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        guard let everyone = everyoneUUID() else { throw systemError("mbr_gid_to_uuid", path) }

        if add {
            var entry: acl_entry_t?
            guard acl_create_entry_np(&acl, &entry, Int32(ACL_FIRST_ENTRY.rawValue)) == 0,
                  let entry else { throw systemError("acl_create_entry_np", path) }
            guard acl_set_tag_type(entry, ACL_EXTENDED_DENY) == 0,
                  everyone.withUnsafeBytes({ acl_set_qualifier(entry, $0.baseAddress) }) == 0 else {
                throw systemError("acl_set_qualifier", path)
            }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0, let permissions,
                  acl_clear_perms(permissions) == 0,
                  acl_add_perm(permissions, ACL_DELETE) == 0 else {
                throw systemError("acl_add_perm", path)
            }
            if directory && acl_add_perm(permissions, ACL_DELETE_CHILD) != 0 {
                throw systemError("acl_add_perm", path)
            }
            var flags: acl_flagset_t?
            guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0, let flags,
                  acl_clear_flags_np(flags) == 0 else { throw systemError("acl_get_flagset_np", path) }
            if inherit && (acl_add_flag_np(flags, ACL_ENTRY_FILE_INHERIT) != 0 ||
                           acl_add_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) != 0) {
                throw systemError("acl_add_flag_np", path)
            }
        } else {
            let matching = try entries(in: acl!).filter { entry in
                matches(entry, everyone: everyone, directory: directory, inheritedOnly: false,
                        inherit: inherit, exact: true, includeInherited: includeInherited)
            }
            guard let entry = matching.first else { throw ProtectionError.invalid("Hoard ACL entry not found: \(path)") }
            guard acl_delete_entry(acl, entry) == 0 else { throw systemError("acl_delete_entry", path) }
        }
        guard acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) == 0 else {
            throw systemError("acl_set_link_np", path)
        }
    }

    /// Test fixture cleanup: strip only Hoard's exact ACL shapes from the fixture tree.
    static func stripFixtureEntries(in root: String) throws {
        guard FileManager.default.fileExists(atPath: root) else { return }
        var paths = [root]
        var index = 0
        while index < paths.count {
            let path = paths[index]
            index += 1
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: path) {
                    paths.append((path as NSString).appendingPathComponent(name))
                }
            }
        }
        for path in paths.reversed() {
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { continue }
            let directory = (st.st_mode & S_IFMT) == S_IFDIR
            try stripExactEntries(at: path, directory: directory)
        }
    }

    private static func stripExactEntries(at path: String, directory: Bool) throws {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let everyone = everyoneUUID() else { throw systemError("mbr_gid_to_uuid", path) }
        let owned = try entries(in: acl).filter { entry in
            matches(entry, everyone: everyone, directory: directory, inheritedOnly: false,
                    inherit: nil, exact: true)
        }
        for entry in owned { guard acl_delete_entry(acl, entry) == 0 else { throw systemError("acl_delete_entry", path) } }
        if !owned.isEmpty && acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) != 0 {
            throw systemError("acl_set_link_np", path)
        }
    }

    private static func entries(in acl: acl_t) throws -> [acl_entry_t] {
        var result: [acl_entry_t] = []
        var entry: acl_entry_t?
        var next = Int32(ACL_FIRST_ENTRY.rawValue)
        while true {
            errno = 0
            let status = acl_get_entry(acl, next, &entry)
            if status == -1 && errno == EINVAL { break }
            guard status == 0, let entry else { throw systemError("acl_get_entry", "ACL") }
            result.append(entry)
            next = Int32(ACL_NEXT_ENTRY.rawValue)
        }
        return result
    }

    private static func matches(_ entry: acl_entry_t, everyone: [UInt8], directory: Bool,
                                inheritedOnly: Bool, inherit: Bool?, exact: Bool,
                                includeInherited: Bool = true) -> Bool {
        var tag = ACL_UNDEFINED_TAG
        guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY,
              let qualifier = acl_get_qualifier(entry) else { return false }
        defer { acl_free(qualifier) }
        guard everyone.withUnsafeBytes({ memcmp(qualifier, $0.baseAddress, 16) }) == 0 else { return false }
        var permissions: acl_permset_t?
        guard acl_get_permset(entry, &permissions) == 0, let permissions,
              acl_get_perm_np(permissions, ACL_DELETE) == 1 else { return false }
        let child = acl_get_perm_np(permissions, ACL_DELETE_CHILD) == 1
        var flags: acl_flagset_t?
        guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0, let flags else { return false }
        let inherited = acl_get_flag_np(flags, ACL_ENTRY_INHERITED) == 1
        guard directory ? child : (!child || inherited) else { return false }
        if inheritedOnly && !inherited { return false }
        if !includeInherited && inherited { return false }
        let fileInherit = acl_get_flag_np(flags, ACL_ENTRY_FILE_INHERIT) == 1
        let directoryInherit = acl_get_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) == 1
        if let inherit, fileInherit != inherit || directoryInherit != inherit { return false }
        if exact {
            var mask: acl_permset_mask_t = 0
            guard acl_get_permset_mask_np(entry, &mask) == 0 else { return false }
            let wanted = UInt64(ACL_DELETE.rawValue) | (directory || inherited && child ? UInt64(ACL_DELETE_CHILD.rawValue) : 0)
            guard mask == wanted else { return false }
            if acl_get_flag_np(flags, ACL_ENTRY_LIMIT_INHERIT) == 1 ||
                acl_get_flag_np(flags, ACL_ENTRY_ONLY_INHERIT) == 1 { return false }
        }
        return true
    }

    private static func everyoneUUID() -> [UInt8]? {
        var value = [UInt8](repeating: 0, count: 16)
        let status = value.withUnsafeMutableBufferPointer { mbr_gid_to_uuid(12, $0.baseAddress) }
        return status == 0 ? value : nil
    }

    private static func systemError(_ operation: String, _ path: String) -> ProtectionError {
        .command("\(operation) failed for \(path): \(String(cString: strerror(errno)))")
    }
}
