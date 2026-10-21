import Darwin
import Foundation

/// The app groups (`com.apple.security.application-groups`) that installed apps' signatures claim. A
/// group id need not share its app's bundle id: OrbStack is `dev.kdrag0n.MacVirt` and keeps its VM disk
/// in `Group Containers/HUAQ24HBR6.dev.orbstack`. Read once, on the first question (~0.6 s for 272 apps).
public final class InstalledAppGroups: @unchecked Sendable {
    private let lock = NSLock()
    private let isCancelled: @Sendable () -> Bool
    private let roots: [URL]
    private let includeRunningApps: Bool
    private let signing: (String) -> AppSigning?
    private var loaded = false
    private var groups = Set<String>()
    private var unknown = false

    public convenience init(isCancelled: @escaping @Sendable () -> Bool = { false }) {
        // Apple's apps under /System own only com.apple.* groups, which the leftovers rule never claims.
        self.init(isCancelled: isCancelled, roots: InstalledApps.appRoots.filter { !$0.path.hasPrefix("/System/") },
                  includeRunningApps: true)
    }

    init(isCancelled: @escaping @Sendable () -> Bool, roots: [URL], includeRunningApps: Bool = false,
         signing: @escaping (String) -> AppSigning? = AppSigning.read(bundlePath:)) {
        self.isCancelled = isCancelled
        self.roots = roots
        self.includeRunningApps = includeRunningApps
        self.signing = signing
    }

    public func contains(_ group: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            (groups, unknown) = load()
            loaded = true
        }
        if groups.contains(group.lowercased()) { return true }
        return unknown ? nil : false
    }

    private func load() -> (Set<String>, Bool) {
        guard let restore = Materialization.offForThread("app groups") else { return ([], true) }
        defer { restore() }
        let fm = FileManager.default
        let realHome: String? = {
            guard let path = realpath(fm.homeDirectoryForCurrentUser.path, nil) else { return nil }
            defer { free(path) }
            return String(cString: path)
        }()
        var found = Set<String>()
        var uncertain = false
        var walkedApps = Set<String>()
        func linkedChildren(_ path: String) -> [URL]? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            let real = String(cString: resolved)
            guard let names = try? fm.contentsOfDirectory(atPath: real) else { return nil }
            return names.map { URL(fileURLWithPath: real).appendingPathComponent($0) }
        }
        func readSignature(_ app: URL) {
            walkedApps.insert(app.standardizedFileURL.path)
            var appInfo = stat()
            guard stat(app.path, &appInfo) == 0,
                  appInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  appInfo.st_flags & UInt32(SF_DATALESS) == 0 else { uncertain = true; return }
            func folderStatus(_ name: String) -> (exists: Bool, unreadable: Bool) {
                var info = stat()
                if stat(app.appendingPathComponent(name).path, &info) != 0 { return (false, errno != ENOENT) }
                return (true, info.st_flags & UInt32(SF_DATALESS) != 0 ||
                        info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR))
            }
            let contents = folderStatus("Contents"), wrapper = folderStatus("Wrapper")
            if contents.unreadable || wrapper.unreadable { uncertain = true; return }
            let candidates: [URL]
            if wrapper.exists {
                guard let inner = linkedChildren(app.appendingPathComponent("Wrapper").path) else {
                    uncertain = true; return
                }
                candidates = inner.filter { $0.pathExtension.lowercased() == "app" }
                if candidates.isEmpty { uncertain = true; return }
            } else if contents.exists {
                candidates = [app]
            } else {
                return
            }
            for candidate in candidates {
                var info = stat()
                guard stat(candidate.path, &info) == 0,
                      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                      info.st_flags & UInt32(SF_DATALESS) == 0 else { uncertain = true; continue }
                if let signature = signing(candidate.path) {
                    found.formUnion(signature.appGroups.map { $0.lowercased() })
                } else {
                    uncertain = true
                }
            }
        }
        var visited: [String: Int] = [:]
        for root in roots {
            if isCancelled() { return (found, true) }
            var rootInfo = stat()
            if stat(root.path, &rootInfo) != 0 {
                if errno != ENOENT { uncertain = true }
                continue
            }
            guard rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  rootInfo.st_flags & UInt32(SF_DATALESS) == 0 else { uncertain = true; continue }
            guard let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                uncertain = true
                continue
            }
            visited["\(rootInfo.st_dev):\(rootInfo.st_ino)"] = 0
            var stack: [(URL, Int)] = top.map { ($0, 0) }
            while let (url, depth) = stack.popLast() {
                if isCancelled() { return (found, true) }
                var linkInfo = stat()
                if lstat(url.path, &linkInfo) != 0 { if errno != ENOENT { uncertain = true }; continue }
                let isLink = linkInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
                var info = stat()
                if stat(url.path, &info) != 0 { if !isLink && errno != ENOENT { uncertain = true }; continue }
                if info.st_flags & UInt32(SF_DATALESS) != 0 { uncertain = true; continue }
                if url.pathExtension.lowercased() == "app" {
                    readSignature(url)
                    continue
                }
                guard depth < 3, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { continue }
                if isLink {
                    guard info.st_dev == rootInfo.st_dev, let realHome,
                          let resolved = realpath(url.path, nil) else { continue }
                    defer { free(resolved) }
                    guard String(cString: resolved) != realHome else { continue }
                }
                let key = "\(info.st_dev):\(info.st_ino)"
                let nextDepth = depth + 1
                if let prior = visited[key], prior <= nextDepth { continue }
                visited[key] = nextDepth
                if let children = linkedChildren(url.path) {
                    stack += children.map { ($0, nextDepth) }
                } else {
                    uncertain = true
                }
            }
        }
        if includeRunningApps {
            guard let paths = InstalledApps.runningPaths() else { return (found, true) }
            var runningApps = Set<String>()
            for path in paths {
                if isCancelled() { return (found, true) }
                guard let range = path.range(of: ".app/Contents/MacOS/", options: .caseInsensitive) else { continue }
                let app = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app").standardizedFileURL
                guard runningApps.insert(app.path).inserted, !walkedApps.contains(app.path) else { continue }
                readSignature(app)
            }
        }
        return (found, uncertain)
    }
}
