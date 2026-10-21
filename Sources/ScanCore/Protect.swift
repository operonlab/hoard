import Darwin
import Foundation

public enum ProtectionKind: String, Codable, Sendable { case lock, guarded }

public struct ProtectedItem: Codable, Sendable, Equatable {
    public var id: String
    public var path: String
    public var kind: ProtectionKind
    public var isDirectory: Bool
    public var createdAt: Date
    public var createdBy: String
    public var note: String?
}

public enum ProtectionHealth: Equatable, Sendable {
    case intact, aclMissing, vaultMissing
    case itemMissing(restorable: Bool)
}

/// The app's human confirmation dialog is the only intended caller of this factory.
/// Swift access control prevents direct construction, but cannot authenticate a human caller.
public struct ProtectionRemoval {
    public let reason: String
    private init(reason: String) { self.reason = reason }
    public static func confirmedByHuman(reason: String) -> Self { Self(reason: reason) }
}

public enum ProtectionError: Error, LocalizedError {
    case invalid(String)
    case command(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .command(let s): return s }
    }
}

public final class ProtectionStore {
    // ponytail: 5,000-directory lock ceiling; raise only after profiling larger ACL trees.
    static let maximumLockDirectories = 5_000
    // ponytail: 20,000 entries is the guard ceiling; use per-file vault refresh before raising it.
    static let maximumGuardEntries = 20_000
    // ponytail: 5 GB guard ceiling (logical bytes); guard is for working files, lock covers big finished ones.
    // Raise it only with per-file vault refresh, since every refresh clones the whole item.
    static let maximumGuardBytes: Int64 = 5_000_000_000
    // ponytail: fixed free-space floor for a new guard version (10 GB or 5% of the volume, whichever is more);
    // make it a setting if owners on small or very full disks hit it.
    static let minimumFreeBytes: Int64 = 10_000_000_000
    static let minimumFreeFraction = 0.05

    /// Tests lower these; the defaults are the constants above and the volume's real free space.
    var guardByteCeiling = ProtectionStore.maximumGuardBytes
    var volumeSpace: (String) -> (free: Int64, total: Int64)? = ProtectionStore.statfsSpace

    /// Bytes available to this user and the volume's size, or nil when statfs fails.
    static func statfsSpace(_ path: String) -> (free: Int64, total: Int64)? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let block = Int64(fs.f_bsize)
        return (Int64(fs.f_bavail) * block, Int64(fs.f_blocks) * block)
    }

    private struct Registry: Codable {
        var items: [ProtectedItem] = []
        var versions: [String: [String]] = [:]
    }

    private let directory: URL
    private let home: String
    /// The home path as written, before symlinks are resolved; owner-only checks look at both.
    private let lexicalHome: String
    private let vault: URL
    private let registryURL: URL
    private let fm = FileManager.default
    private let mutex = NSRecursiveLock()
    private var registry: Registry

    public init(directory: URL? = nil, home: URL? = nil) {
        let homeURL = home ?? FileManager.default.homeDirectoryForCurrentUser
        if let resolved = realpath(homeURL.path, nil) {
            self.home = String(cString: resolved)
            free(resolved)
        } else {
            self.home = homeURL.standardizedFileURL.path
        }
        self.lexicalHome = homeURL.standardizedFileURL.path
        self.directory = directory ?? homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(HoardStorage.folderName, isDirectory: true)
            .appendingPathComponent("Protection", isDirectory: true)
        self.vault = self.directory.appendingPathComponent("vault", isDirectory: true)
        self.registryURL = self.directory.appendingPathComponent("registry.json")
        self.registry = Registry()
    }

    public func items() -> [ProtectedItem] {
        mutex.lock(); defer { mutex.unlock() }
        return withReadLock { registry.items }
    }

    public func item(covering path: String) -> ProtectedItem? {
        mutex.lock(); defer { mutex.unlock() }
        return withReadLock {
            let canonical = canonicalPath(path)
            return registry.items.filter { $0.path == canonical || ($0.isDirectory && canonical.hasPrefix($0.path + "/")) }
                .max { $0.path.count < $1.path.count }
        }
    }

    /// Protected items strictly inside the folder at `path` (not the folder itself).
    public func items(inside path: String) -> [ProtectedItem] {
        mutex.lock(); defer { mutex.unlock() }
        return withReadLock {
            let canonical = canonicalPath(path)
            let prefix = canonical.hasSuffix("/") ? canonical : canonical + "/"
            return registry.items.filter { $0.path.hasPrefix(prefix) }
        }
    }

    @discardableResult public func lock(_ path: String, by: String, note: String? = nil) throws -> ProtectedItem {
        try add(path, kind: .lock, by: by, note: note)
    }

    @discardableResult public func guardItem(_ path: String, by: String, note: String? = nil) throws -> ProtectedItem {
        try add(path, kind: .guarded, by: by, note: note)
    }

    /// The checks `guardItem` makes on what it would copy (no file without local data, the size
    /// ceilings), so the app can show the refusal before the user confirms. Reads metadata only.
    public func checkGuardable(_ path: String) throws {
        guard let resolved = realpath(path, nil) else { throw ProtectionError.invalid("Path does not exist: \(path)") }
        defer { free(resolved) }
        guard let restore = Materialization.offForThread("guard size check") else {
            throw ProtectionError.invalid(Materialization.refusedDetail)
        }
        defer { restore() }
        mutex.lock()
        let ceiling = guardByteCeiling
        mutex.unlock()
        try checkSizeCeiling(String(cString: resolved), kind: .guarded, maximumBytes: ceiling)
    }

    private func add(_ path: String, kind: ProtectionKind, by: String, note: String?) throws -> ProtectedItem {
        mutex.lock(); defer { mutex.unlock() }
        guard let resolved = realpath(path, nil) else { throw ProtectionError.invalid("Path does not exist: \(path)") }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        try validateProtectedPath(canonical, kind: kind, by: by, requested: path)
        let storePath = canonicalPath(directory.path)
        guard canonical != storePath, !canonical.hasPrefix(storePath + "/"),
              !storePath.hasPrefix(canonical + "/") else {
            throw ProtectionError.invalid("Protection store and its ancestors cannot be protected")
        }
        var st = stat(), parent = stat()
        guard lstat(canonical, &st) == 0 else { throw ProtectionError.invalid("Cannot stat: \(canonical)") }
        let parentPath = (canonical as NSString).deletingLastPathComponent
        guard stat(parentPath, &parent) == 0, st.st_dev == parent.st_dev else {
            throw ProtectionError.invalid("Volume root cannot be protected: \(canonical)")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR || (st.st_mode & S_IFMT) == S_IFREG else {
            throw ProtectionError.invalid("Only regular files and directories can be protected")
        }
        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        if kind == .guarded {
            try checkGuardable(canonical)
        } else if isDirectory {
            try checkSizeCeiling(canonical, kind: kind, maximumBytes: guardByteCeiling)
        }
        return try withRegistryLock(.exclusive, create: true) {
        guard !registry.items.contains(where: { $0.kind == kind &&
            ($0.path == canonical || ($0.isDirectory && canonical.hasPrefix($0.path + "/"))) }) else {
            throw ProtectionError.invalid("Path is already covered by \(kind.rawValue) protection")
        }
        if kind == .guarded {
            try ensureStore()
            var vaultStat = stat()
            guard stat(vault.path, &vaultStat) == 0, vaultStat.st_dev == st.st_dev else {
                throw ProtectionError.invalid("Guarded path must be on the vault's volume")
            }
        }
        let item = ProtectedItem(id: UUID().uuidString, path: canonical, kind: kind,
                                 isDirectory: isDirectory,
                                 createdAt: Date(), createdBy: by, note: note)
        if kind == .lock {
            try lockTree(canonical, isDirectory: item.isDirectory)
        }
        do {
            if kind == .guarded { try makeVersion(for: item) }
            registry.items.append(item)
            try save()
            return item
        } catch {
            if kind == .lock { try? unlockTree(canonical, isDirectory: item.isDirectory) }
            registry.items.removeAll { $0.id == item.id }
            throw error
        }
        }
    }

    /// `by == "app"` is the owner in the Hoard app; `requested` is the path as the caller wrote it,
    /// checked too because a symlinked dotfile resolves to a name outside home.
    func validateProtectedPath(_ input: String, kind: ProtectionKind, by: String, requested: String? = nil) throws {
        let path = canonicalPath(input)
        let parent = (path as NSString).deletingLastPathComponent
        if path == "/" || path == "/System" || path.hasPrefix("/System/") {
            throw ProtectionError.invalid("System or volume root cannot be protected: \(path)")
        }
        if parent == "/" || parent == "/private" {
            throw ProtectionError.invalid("Top-level system directory cannot be protected: \(path)")
        }
        if path == home || home.hasPrefix(path + "/") {
            throw ProtectionError.invalid("Home directory and its ancestors cannot be protected: \(path)")
        }
        // A protected launch item would be a login item the owner cannot delete: refuse both kinds there.
        let autostart = [(home as NSString).appendingPathComponent("Library/LaunchAgents"),
                         (home as NSString).appendingPathComponent("Library/Application Support/com.apple.backgroundtaskmanagementagent"),
                         "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/StartupItems"]
        if let dir = autostart.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            throw ProtectionError.invalid("Launch and login items cannot be protected: \(dir)")
        }
        if by != "app" {
            let written = requested.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            if let what = ([path] + (written.map { [$0] } ?? [])).lazy.compactMap(ownerOnlyTarget).first {
                throw ProtectionError.invalid("\(what) can only be protected by you, in the Hoard app (只能在 Hoard app 裡由你本人保護): \(path)")
            }
        }
        let library = (home as NSString).appendingPathComponent("Library")
        if path == library || (kind == .lock && path.hasPrefix(library + "/")) {
            throw ProtectionError.invalid("Lock cannot cover ~/Library; the Library root cannot be protected: \(path)")
        }
    }

    static let shellStartupFiles: Set<String> = [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bashrc", ".bash_profile",
                                                 ".bash_login", ".profile"]

    /// Why `path` may be protected only by the owner, or nil: a protection an agent asked for would hurt
    /// the owner (SSH keys and shell startup files they cannot replace, an app bundle that cannot update).
    /// Case-insensitive, like the default APFS volume.
    private func ownerOnlyTarget(_ path: String) -> String? {
        let lower = path.lowercased()
        if (lower as NSString).pathComponents.contains(where: { $0.hasSuffix(".app") }) { return "An app bundle" }
        for home in Set([home.lowercased(), lexicalHome.lowercased()]) {
            let ssh = home + "/.ssh", fish = home + "/.config/fish"
            if lower == ssh || lower.hasPrefix(ssh + "/") { return "SSH keys and settings" }
            if lower == fish || lower.hasPrefix(fish + "/") || fish.hasPrefix(lower + "/") { return "Shell startup files" }
            if (lower as NSString).deletingLastPathComponent == home,
               Self.shellStartupFiles.contains((lower as NSString).lastPathComponent) { return "A shell startup file" }
        }
        // Where those entries really live when they are links into a dotfiles repo: the same files, and a
        // folder holding them would cover them.
        let entries = [(".ssh", "SSH keys and settings", true), (".config/fish", "Shell startup files", true)]
            + Self.shellStartupFiles.map { ($0, "A shell startup file", false) }
        for (entry, what, subtree) in entries {
            let real = canonicalPath((home as NSString).appendingPathComponent(entry)).lowercased()
            if lower == real || (subtree && lower.hasPrefix(real + "/")) || real.hasPrefix(lower + "/") { return what }
        }
        return nil
    }

    func checkSizeCeiling(_ path: String, kind: ProtectionKind,
                          maximumDirectories: Int = ProtectionStore.maximumLockDirectories,
                          maximumEntries: Int = ProtectionStore.maximumGuardEntries,
                          maximumBytes: Int64 = ProtectionStore.maximumGuardBytes,
                          newVersion: Bool = false) throws {
        var bytes: Int64 = 0
        func countBytes(_ st: stat, at entryPath: String) throws {
            if kind == .guarded && Self.isDataless(st) {
                throw ProtectionError.invalid("\(entryPath) has no data on this Mac (iCloud); Hoard does not download it, so it cannot be guarded")
            }
            guard kind == .guarded, (st.st_mode & S_IFMT) == S_IFREG else { return }
            bytes += Int64(st.st_size)
            if bytes > maximumBytes {
                if newVersion {
                    throw ProtectionError.invalid("guard is for working files: \(path) grew past 5 GB; existing versions stay")
                }
                throw ProtectionError.invalid("\(path) is over \(formattedCeiling(Int(maximumBytes))) bytes: guard is for working files; lock large finished files instead")
            }
        }
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else { throw ProtectionError.invalid("Cannot stat: \(path)") }
        try countBytes(rootStat, at: path)
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else { return }
        var stack = [path]
        var directories = 0
        var entries = 0
        while let current = stack.popLast() {
            for name in try fm.contentsOfDirectory(atPath: current) {
                let child = (current as NSString).appendingPathComponent(name)
                entries += 1
                if kind == .guarded && entries > maximumEntries {
                    throw ProtectionError.invalid("Guard folder exceeds \(formattedCeiling(maximumEntries)) entries: \(path)")
                }
                var st = stat()
                guard lstat(child, &st) == 0 else {
                    throw ProtectionError.invalid("Cannot inspect folder entry: \(child)")
                }
                try countBytes(st, at: child)
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    directories += 1
                    if kind == .lock && directories > maximumDirectories {
                        throw ProtectionError.invalid("Lock folder exceeds \(formattedCeiling(maximumDirectories)) directories: \(path)")
                    }
                    stack.append(child)
                }
            }
        }
    }

    private func formattedCeiling(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public func remove(_ id: String, _ removal: ProtectionRemoval) throws {
        mutex.lock(); defer { mutex.unlock() }
        try withRegistryLock(.exclusive, create: true) {
        guard !removal.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProtectionError.invalid("Human removal reason is required")
        }
        guard let item = registry.items.first(where: { $0.id == id }) else { throw ProtectionError.invalid("Unknown protection id") }
        if item.kind == .lock { try unlockTree(item.path, isDirectory: item.isDirectory) }
        registry.items.removeAll { $0.id == id }
        registry.versions[id] = nil
        try save()
        if item.kind == .guarded {
            try withUnlockedStore {
                let location = vault.appendingPathComponent(id)
                if aclPresent(location.path, directory: true) { try changeACL(location.path, directory: true, add: false) }
                if fm.fileExists(atPath: location.path) {
                    for version in try fm.contentsOfDirectory(at: location, includingPropertiesForKeys: nil) {
                        try unlockTree(version.path, isDirectory: item.isDirectory)
                    }
                    try fm.removeItem(at: location)
                }
            }
        }
        }
    }

    /// Re-applies Hoard's ACL entries that were stripped outside Hoard (health `.aclMissing`).
    /// It only adds protection back, so unlike `remove` it needs no human token.
    public func repair(_ id: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        try withRegistryLock(.exclusive, create: true) { // create: true re-locks the store and vault
            guard let item = registry.items.first(where: { $0.id == id }) else { throw ProtectionError.invalid("Unknown protection id") }
            guard fm.fileExists(atPath: item.path) else { throw ProtectionError.invalid("Protected item is missing: \(item.path)") }
            if item.kind == .lock {
                try addMissingACLs(item.path, isDirectory: item.isDirectory)
                return
            }
            let base = vault.appendingPathComponent(item.id)
            if fm.fileExists(atPath: base.path), !aclPresent(base.path, directory: true) {
                try changeACL(base.path, directory: true, add: true)
            }
            if let snapshot = latestVersion(item) { try addMissingACLs(snapshot.path, isDirectory: item.isDirectory) }
        }
    }

    private func addMissingACLs(_ path: String, isDirectory: Bool) throws {
        for candidate in isDirectory ? try directories(under: path) : [path] where !aclPresent(candidate, directory: isDirectory) {
            try changeACL(candidate, directory: isDirectory, add: true, inherit: isDirectory)
        }
    }

    public func health(_ id: String) -> ProtectionHealth {
        mutex.lock(); defer { mutex.unlock() }
        return withReadLock {
        guard let item = registry.items.first(where: { $0.id == id }) else { return .itemMissing(restorable: false) }
        var st = stat()
        let present = lstat(item.path, &st) == 0
        if !present || (st.st_mode & S_IFMT) == S_IFLNK {
            // A symlink where the item was is not the item, and restore never writes through one.
            return .itemMissing(restorable: !present && item.kind == .guarded && latestVersion(item) != nil)
        }
        if item.kind == .lock {
            let paths = item.isDirectory ? (try? directories(under: item.path)) : [item.path]
            return paths?.allSatisfy { aclPresent($0, directory: item.isDirectory) } == true ? .intact : .aclMissing
        }
        guard let snapshot = latestVersion(item) else { return .vaultMissing }
        let base = vault.appendingPathComponent(item.id)
        guard aclPresent(directory.path, directory: true), aclPresent(vault.path, directory: true),
              aclPresent(base.path, directory: true) else { return .aclMissing }
        let snapshotPaths = item.isDirectory ? (try? directories(under: snapshot.path)) : [snapshot.path]
        return snapshotPaths?.allSatisfy { aclPresent($0, directory: item.isDirectory) } == true ? .intact : .aclMissing
        }
    }

    @discardableResult public func restoreMissing() throws -> [String] {
        try restoreMissing(excluding: [])
    }

    @discardableResult func restoreMissing(excluding paths: Set<String>) throws -> [String] {
        mutex.lock(); defer { mutex.unlock() }
        return try withRegistryLock(.exclusive, create: false) { try restoreMissingLocked(excluding: paths) }
    }

    private func restoreMissingLocked(excluding paths: Set<String> = []) throws -> [String] {
        var restored: [String] = []
        var failures: [String] = []
        for item in registry.items where item.kind == .guarded && !paths.contains(item.path) {
            guard let snapshot = latestVersion(item) else {
                failures.append("\(item.path): vault copy missing")
                continue
            }
            var st = stat()
            if lstat(item.path, &st) != 0 {
                do { try createMissingParents(of: item.path) } catch {
                    failures.append("\(item.path): \(error.localizedDescription)")
                    continue
                }
            }
            restore(from: snapshot, to: URL(fileURLWithPath: item.path), restored: &restored, failures: &failures)
        }
        if !failures.isEmpty {
            throw ProtectionError.command("Restore partially failed. Restored: \(restored.joined(separator: ", ")). Failed: \(failures.joined(separator: "; "))")
        }
        return restored
    }

    /// Takes a new vault version of the guarded item covering `path` when its content changed.
    /// Returns whether a version was written.
    @discardableResult public func refresh(_ path: String) throws -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        return try withRegistryLock(.exclusive, create: false) {
        let canonical = canonicalPath(path)
        guard let item = registry.items.first(where: { $0.kind == .guarded &&
            ($0.path == canonical || ($0.isDirectory && canonical.hasPrefix($0.path + "/"))) }) else { return false }
        guard fm.fileExists(atPath: item.path) else { return false } // Preserve the latest copy after a deletion event.
        guard let snapshot = latestVersion(item) else {
            // The vault copy vanished (重新備份): start the history again from what is there now.
            try makeVersion(for: item)
            try save()
            return true
        }
        var restored: [String] = [], failures: [String] = []
        restore(from: snapshot, to: URL(fileURLWithPath: item.path), restored: &restored, failures: &failures)
        if !failures.isEmpty { throw ProtectionError.command("Restore failed: \(failures.joined(separator: "; "))") }
        // Cloning the item into the vault is itself an FSEvents change on the item. Without this check the
        // guardian refreshes forever and three identical copies push the real history out of the vault.
        if try Self.fingerprint(item.path) == Self.fingerprint(snapshot.path),
           try Self.allRegularFilesShareBlocks(item.path) { return false }
        try makeVersion(for: item)
        try save()
        return true
        }
    }

    /// What a vault copy must match to count as unchanged: each entry's relative path and type, plus size
    /// and modification time for files (clonefile keeps both) and the target for links. Folder mtimes are
    /// left out (the vault's are creation times); transient files are skipped as in the vault.
    static func fingerprint(_ root: String) throws -> [String] {
        var out: [String] = []
        func visit(_ path: String, _ relative: String) throws {
            var st = stat()
            guard lstat(path, &st) == 0 else { throw ProtectionError.invalid("Cannot stat: \(path)") }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                out.append("d\t\(relative)")
                for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() where !isTransient(name) {
                    try visit((path as NSString).appendingPathComponent(name), relative + "/" + name)
                }
            case S_IFLNK:
                out.append("l\t\(relative)\t\(try FileManager.default.destinationOfSymbolicLink(atPath: path))")
            default:
                out.append("f\t\(relative)\t\(st.st_size)\t\(st.st_mtimespec.tv_sec)\t\(st.st_mtimespec.tv_nsec)")
            }
        }
        try visit(root, "")
        return out
    }

    /// clonefile leaves the source sharing all blocks with its vault copy. An in-place write breaks
    /// that sharing even when a caller restores the original size and mtime.
    private static func allRegularFilesShareBlocks(_ root: String) throws -> Bool {
        var pending = [root]
        while let path = pending.popLast() {
            var st = stat()
            guard lstat(path, &st) == 0 else { throw ProtectionError.invalid("Cannot stat: \(path)") }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                pending += try FileManager.default.contentsOfDirectory(atPath: path)
                    .filter { !isTransient($0) }.map { (path as NSString).appendingPathComponent($0) }
            case S_IFREG where st.st_size > 0:
                var attrs = attrlist()
                attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
                attrs.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
                var buffer = [UInt8](repeating: 0, count: 128)
                let result = buffer.withUnsafeMutableBytes {
                    getattrlist(path, &attrs, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
                }
                guard result == 0 else { return false }
                let returned = buffer.withUnsafeBytes {
                    $0.baseAddress!.advanced(by: 4).loadUnaligned(as: attribute_set_t.self)
                }
                guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 else { return false }
                let flags = buffer.withUnsafeBytes {
                    $0.baseAddress!.advanced(by: 4 + MemoryLayout<attribute_set_t>.size).loadUnaligned(as: UInt64.self)
                }
                if flags & 0x40 == 0 { return false } // EF_SHARES_ALL_BLOCKS
            default: break
            }
        }
        return true
    }

    private enum RegistryLockMode { case shared, exclusive }

    /// Why the last read of the registry failed, or nil. Reads then answer from the last copy that
    /// loaded, so a damaged registry.json cannot take down the app or the MCP server; callers report this.
    public private(set) var readError: String?

    private func withReadLock<T>(_ body: () -> T) -> T {
        do {
            let value = try withRegistryLock(.shared, create: false, body)
            readError = nil
            return value
        } catch {
            readError = "Protection registry cannot be read: \(error.localizedDescription)"
            return body()
        }
    }

    private func reloadRegistry() throws {
        guard fm.fileExists(atPath: registryURL.path) else { registry = Registry(); return }
        registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: registryURL))
    }

    private func withRegistryLock<T>(_ mode: RegistryLockMode, create: Bool, _ body: () throws -> T) throws -> T {
        if create { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        else if !fm.fileExists(atPath: directory.path) {
            registry = Registry()
            return try body()
        }
        let lockPath = directory.appendingPathComponent("registry.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw ProtectionError.invalid("Cannot open protection registry lock: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard flock(fd, mode == .shared ? LOCK_SH : LOCK_EX) == 0 else {
            throw ProtectionError.invalid("Cannot lock protection registry")
        }
        defer { _ = flock(fd, LOCK_UN) }
        if create { try ensureStore() }
        try reloadRegistry()
        return try body()
    }

    private func ensureStore() throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        if !aclPresent(directory.path, directory: true) { try changeACL(directory.path, directory: true, add: true) }
        if !aclPresent(vault.path, directory: true) { try changeACL(vault.path, directory: true, add: true) }
    }

    /// Repairs the store ACL after an interrupted write without creating a missing store.
    public func relockStore() throws {
        mutex.lock(); defer { mutex.unlock() }
        var st = stat()
        guard lstat(directory.path, &st) == 0 else {
            if errno == ENOENT { return }
            throw ProtectionError.invalid("Cannot stat protection store: \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw ProtectionError.invalid("Protection store is not a directory: \(directory.path)")
        }
        try ensureStore()
    }

    private func save() throws {
        try ensureStore()
        let data = try JSONEncoder().encode(registry)
        try withUnlockedStore {
            try data.write(to: registryURL, options: .atomic)
        }
    }

    private func withUnlockedStore<T>(_ body: () throws -> T) throws -> T {
        // Atomic rename and version pruning require delete_child on the parent. Reapply even if the write fails.
        try changeACL(vault.path, directory: true, add: false)
        do { try changeACL(directory.path, directory: true, add: false) }
        catch { try? changeACL(vault.path, directory: true, add: true); throw error }
        let result = Result { try body() }
        let relockDirectory = Result { try changeACL(directory.path, directory: true, add: true) }
        let relockVault = Result { try changeACL(vault.path, directory: true, add: true) }
        try relockDirectory.get()
        try relockVault.get()
        return try result.get()
    }

    /// Refuses a new vault version when the vault's volume is low; the existing versions are untouched.
    private func ensureFreeSpace() throws {
        guard let space = volumeSpace(vault.path) else {
            throw ProtectionError.invalid("Cannot read free space on the vault's volume; no new guard version was made")
        }
        let floor = max(Self.minimumFreeBytes, Int64(Double(space.total) * Self.minimumFreeFraction))
        guard space.free >= floor else {
            throw ProtectionError.invalid("not enough free space for a new guard version (\(formattedCeiling(Int(space.free))) bytes free, \(formattedCeiling(Int(floor))) needed); the previous versions stay")
        }
    }

    private func makeVersion(for item: ProtectedItem) throws {
        guard let restore = Materialization.offForThread("guard version") else {
            throw ProtectionError.invalid(Materialization.refusedDetail)
        }
        defer { restore() }
        try checkSizeCeiling(item.path, kind: .guarded, maximumBytes: guardByteCeiling, newVersion: true)
        try ensureStore()
        try ensureFreeSpace()
        let version = UUID().uuidString
        try withUnlockedStore {
            let base = vault.appendingPathComponent(item.id, isDirectory: true)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            if aclPresent(base.path, directory: true) { try changeACL(base.path, directory: true, add: false) }
            let operation = Result {
                let target = base.appendingPathComponent(version)
                try cloneTree(URL(fileURLWithPath: item.path), to: target)
                try lockTree(target.path, isDirectory: item.isDirectory)
                var versions = registry.versions[item.id, default: []]
                versions.insert(version, at: 0)
                for old in versions.dropFirst(3) {
                    let path = base.appendingPathComponent(old)
                    try unlockTree(path.path, isDirectory: item.isDirectory)
                    try fm.removeItem(at: path)
                }
                registry.versions[item.id] = Array(versions.prefix(3))
            }
            try changeACL(base.path, directory: true, add: true)
            try operation.get()
        }
    }

    private func latestVersion(_ item: ProtectedItem) -> URL? {
        guard let version = registry.versions[item.id]?.first else { return nil }
        let path = vault.appendingPathComponent(item.id).appendingPathComponent(version)
        return fm.fileExists(atPath: path.path) ? path : nil
    }

    /// Editor swap and lock files and Finder metadata: never copied into the vault, so never restored.
    static func isTransient(_ name: String) -> Bool {
        if name == ".DS_Store" || name == "4913" { return true } // 4913: vim's write-permission probe
        if name.hasPrefix(".#") || name.hasPrefix(".~lock.") || (name.count > 1 && name.hasPrefix("#") && name.hasSuffix("#")) { return true }
        if name.hasSuffix("~") { return true }
        return ["swp", "swo", "swx", "tmp", "crdownload", "part"].contains((name as NSString).pathExtension.lowercased())
    }

    static func isDataless(_ st: stat) -> Bool {
        st.st_flags & UInt32(SF_DATALESS) != 0
    }

    private func cloneTree(_ source: URL, to target: URL) throws {
        var sourceStat = stat()
        guard lstat(source.path, &sourceStat) == 0 else {
            throw ProtectionError.invalid("Missing entry in guarded tree: \(source.path)")
        }
        guard !Self.isDataless(sourceStat) else {
            throw ProtectionError.invalid("\(source.path) has no data on this Mac (iCloud); Hoard does not download it, so it cannot be guarded")
        }
        if (sourceStat.st_mode & S_IFMT) == S_IFLNK {
            // Copy the link itself; following it could pull files from outside the guarded tree.
            let destination = try fm.destinationOfSymbolicLink(atPath: source.path)
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
            return
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw ProtectionError.invalid("Source disappeared: \(source.path)") }
        if isDir.boolValue {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            where !Self.isTransient(child.lastPathComponent) {
                try cloneTree(child, to: target.appendingPathComponent(child.lastPathComponent))
            }
        } else if clonefile(source.path, target.path, 0) != 0 {
            throw ProtectionError.invalid("clonefile failed for \(source.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Recreates what is missing under `target`; existing entries are never overwritten. lstat throughout:
    /// a symlink where the vault has a real file or folder is reported, never written through.
    private func restore(from source: URL, to target: URL, restored: inout [String], failures: inout [String]) {
        var sourceStat = stat(), targetStat = stat()
        guard lstat(source.path, &sourceStat) == 0 else { return }
        let sourceType = sourceStat.st_mode & S_IFMT
        guard lstat(target.path, &targetStat) == 0 else {
            do {
                try cloneTree(source, to: target)
                restored.append(target.path)
            } catch {
                failures.append("\(target.path): \(error.localizedDescription)")
            }
            return
        }
        let targetType = targetStat.st_mode & S_IFMT
        if targetType == S_IFLNK && sourceType != S_IFLNK {
            failures.append("\(target.path): replaced by a symlink; not restored through it")
            return
        }
        guard sourceType == S_IFDIR, targetType == S_IFDIR else { return }
        do {
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                restore(from: child, to: target.appendingPathComponent(child.lastPathComponent),
                        restored: &restored, failures: &failures)
            }
        } catch {
            failures.append("\(target.path): \(error.localizedDescription)")
        }
    }

    /// Recreates the missing folders above a deleted guarded item. Refuses when an existing component
    /// is a symlink (the item would land outside the path that was guarded) or not a folder.
    private func createMissingParents(of path: String) throws {
        var current = ""
        var creating = false
        for component in ((path as NSString).deletingLastPathComponent as NSString).pathComponents {
            current = current.isEmpty ? component : (current as NSString).appendingPathComponent(component)
            var st = stat()
            if !creating && lstat(current, &st) == 0 {
                switch st.st_mode & S_IFMT {
                case S_IFDIR: continue
                case S_IFLNK: throw ProtectionError.invalid("parent folder replaced by a symlink: \(current)")
                default: throw ProtectionError.invalid("parent is not a folder: \(current)")
                }
            }
            creating = true
            guard mkdir(current, 0o777) == 0 else {
                throw ProtectionError.invalid("Cannot recreate parent folder \(current): \(String(cString: strerror(errno)))")
            }
        }
    }

    private func lockTree(_ path: String, isDirectory: Bool) throws {
        let paths = isDirectory ? try directories(under: path) : [path]
        for candidate in paths {
            guard !aclPresent(candidate, directory: isDirectory) else {
                throw ProtectionError.invalid("Matching ACL already exists; cannot take ownership of it: \(candidate)")
            }
        }
        var applied: [String] = []
        do {
            for candidate in paths {
                try changeACL(candidate, directory: isDirectory, add: true, inherit: isDirectory)
                applied.append(candidate)
            }
        } catch {
            for candidate in applied.reversed() { try? changeACL(candidate, directory: isDirectory, add: false, inherit: isDirectory) }
            throw error
        }
    }

    private func directories(under path: String) throws -> [String] {
        var result = [path]
        for child in try fm.contentsOfDirectory(atPath: path) {
            let full = (path as NSString).appendingPathComponent(child)
            var st = stat()
            if lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                result += try directories(under: full)
            }
        }
        return result
    }

    private func unlockTree(_ path: String, isDirectory: Bool) throws {
        guard fm.fileExists(atPath: path) else { return }
        if isDirectory {
            for child in try fm.contentsOfDirectory(atPath: path) {
                let full = (path as NSString).appendingPathComponent(child)
                var st = stat()
                guard lstat(full, &st) == 0 else { continue }
                if (st.st_mode & S_IFMT) == S_IFDIR { try unlockTree(full, isDirectory: true) }
                else if (st.st_mode & S_IFMT) == S_IFREG, aclInherited(full, directory: false) {
                    try changeACL(full, directory: false, add: false, includeInherited: true)
                }
            }
        }
        if aclPresent(path, directory: isDirectory) { try changeACL(path, directory: isDirectory, add: false, inherit: isDirectory) }
    }

    private func changeACL(_ path: String, directory: Bool, add: Bool, inherit: Bool = false,
                           includeInherited: Bool = false) throws {
        try ProtectionACL.change(path, directory: directory, add: add, inherit: inherit,
                                 includeInherited: includeInherited || inherit)
    }

    private func aclPresent(_ path: String, directory: Bool) -> Bool {
        ProtectionACL.contains(path, directory: directory)
    }

    private func aclInherited(_ path: String, directory: Bool) -> Bool {
        ProtectionACL.contains(path, directory: directory, inheritedOnly: true)
    }

    private func canonicalPath(_ path: String) -> String {
        if let result = realpath(path, nil) { defer { free(result) }; return String(cString: result) }
        let parent = (path as NSString).deletingLastPathComponent
        if parent == path { return path }
        return (canonicalPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }
}
