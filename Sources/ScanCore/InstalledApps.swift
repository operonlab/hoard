import CoreServices
import Darwin
import Foundation
import TreeCore

extension InstalledApps {
    static var appRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/System/Applications", "/System/Library/CoreServices", home.appendingPathComponent("Applications").path,
                "/opt/homebrew/Caskroom", "/usr/local/Caskroom"].map(URL.init(fileURLWithPath:))
    }

    public static func current(isCancelled: () -> Bool = { false }) -> InstalledApps? {
        guard let restore = Materialization.offForThread("installed apps") else { return nil }
        defer { restore() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        // CoreServices holds Apple apps (Siri, Spotlight, ...) whose data folders carry their names.
        let agents = [home.appendingPathComponent("Library/LaunchAgents").path,
                      "/Library/LaunchAgents", "/Library/LaunchDaemons"].map(URL.init(fileURLWithPath:))
        let tools = ["/opt/homebrew/bin", "/opt/homebrew/Cellar", "/usr/local/bin", "/usr/local/Cellar",
                     home.appendingPathComponent(".local/bin").path, home.appendingPathComponent("bin").path,
                     home.appendingPathComponent(".cargo/bin").path].map(URL.init(fileURLWithPath:))
        guard let paths = runningPaths() else { return nil }
        return current(roots: appRoots, launchAgentRoots: agents, processPaths: paths, toolRoots: tools, isCancelled: isCancelled)
    }

    /// `toolRoots`: folders whose entries are command-line tools or Homebrew formulae; each entry's
    /// name counts as an installed name.
    ///
    /// nil only when a whole root cannot be listed. A single item that cannot be read (an iOS app's
    /// wrapper, a dangling `.app` link, a corrupt launch plist) is counted in `source` and skipped, or
    /// one bad item would turn the whole feature off on that Mac; an unreadable app still counts by
    /// its file name, and its bundle id is still found through LaunchServices.
    static func current(roots: [URL], launchAgentRoots: [URL], processPaths: [String], toolRoots: [URL] = [],
                        home: String? = nil, isCancelled: () -> Bool = { false }) -> InstalledApps? {
        let fm = FileManager.default
        var ids = Set<String>(), names = Set<String>()
        var unreadable = 0
        func plist(_ url: URL) -> [String: Any]? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        func readApp(_ url: URL) {
            names.insert(url.deletingPathExtension().lastPathComponent)
            var bundleInfo = stat()
            guard stat(url.path, &bundleInfo) == 0,
                  bundleInfo.st_flags & UInt32(SF_DATALESS) == 0 else { unreadable += 1; return }
            // A Mac app keeps Contents/Info.plist; an iPhone or iPad app on Apple silicon is a wrapper.
            var candidates = [url.appendingPathComponent("Contents/Info.plist"), url.appendingPathComponent("WrappedBundle/Info.plist")]
            func status(_ path: String) -> (exists: Bool, unreadable: Bool) {
                var info = stat()
                if stat(path, &info) != 0 { return (false, errno != ENOENT) }
                return (true, info.st_flags & UInt32(SF_DATALESS) != 0)
            }
            let contents = status(url.appendingPathComponent("Contents").path)
            let wrapper = status(url.appendingPathComponent("Wrapper").path)
            if contents.unreadable || wrapper.unreadable { unreadable += 1; return }
            if wrapper.exists {
                guard let inner = try? fm.contentsOfDirectory(at: url.appendingPathComponent("Wrapper"), includingPropertiesForKeys: nil) else {
                    unreadable += 1
                    return
                }
                candidates += inner.filter { $0.pathExtension.lowercased() == "app" }.map { $0.appendingPathComponent("Info.plist") }
            }
            var readable: [URL] = []
            for candidate in candidates {
                var info = stat()
                if stat(candidate.path, &info) != 0 {
                    if errno != ENOENT { unreadable += 1; return }
                    continue
                }
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      info.st_flags & UInt32(SF_DATALESS) == 0 else { unreadable += 1; return }
                readable.append(candidate)
            }
            // A flat helper bundle with no Info.plist at all has only its file name to give, and that is recorded.
            if readable.isEmpty, !contents.exists, !wrapper.exists,
               (try? fm.contentsOfDirectory(atPath: url.path)) != nil { return }
            guard let info = readable.lazy.compactMap(plist).first(where: { ($0["CFBundleIdentifier"] as? String)?.isEmpty == false }),
                  let id = info["CFBundleIdentifier"] as? String else {
                unreadable += 1
                return
            }
            ids.insert(id.lowercased())
            if let display = info["CFBundleName"] as? String { names.insert(display) }
        }
        /// The root itself must list; nil = fail closed.
        func listRoot(_ root: URL, follow: Bool) -> [URL]?? {
            var info = stat()
            if (follow ? stat(root.path, &info) : lstat(root.path, &info)) != 0 { return errno == ENOENT ? .some(nil) : nil }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_flags & UInt32(SF_DATALESS) == 0,
                  let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
            return .some(children)
        }
        func linkedChildren(_ path: String) -> [URL]? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            let real = String(cString: resolved)
            guard let names = try? fm.contentsOfDirectory(atPath: real) else { return nil }
            return names.map { URL(fileURLWithPath: real).appendingPathComponent($0) }
        }
        let realHome: String? = {
            guard let path = realpath(home ?? fm.homeDirectoryForCurrentUser.path, nil) else { return nil }
            defer { free(path) }
            return String(cString: path)
        }()
        var visited: [String: Int] = [:]
        for root in roots {
            if isCancelled() { return nil }
            // follow: ~/Applications can be a link into a dotfiles or synced folder.
            guard let listed = listRoot(root, follow: true) else { return nil }
            guard let top = listed else { continue }
            var rootInfo = stat()
            if stat(root.path, &rootInfo) == 0 { visited["\(rootInfo.st_dev):\(rootInfo.st_ino)"] = 0 }
            var stack: [(URL, Int, [URL])] = [(root, 0, top)]
            while let (_, depth, children) = stack.popLast() {
                if isCancelled() { return nil }
                for child in children {
                    if child.pathExtension.lowercased() == "app" { readApp(child); continue }
                    guard depth < 3 else { continue }
                    var linkInfo = stat()
                    if lstat(child.path, &linkInfo) != 0 { if errno != ENOENT { unreadable += 1 }; continue }
                    let isLink = linkInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
                    var info = stat()
                    if stat(child.path, &info) != 0 { if !isLink && errno != ENOENT { unreadable += 1 }; continue }
                    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { continue }
                    if isLink {
                        guard info.st_dev == rootInfo.st_dev, let realHome,
                              let resolved = realpath(child.path, nil) else { continue }
                        defer { free(resolved) }
                        guard String(cString: resolved) != realHome else { continue }
                    }
                    if info.st_flags & UInt32(SF_DATALESS) != 0 { unreadable += 1; continue }
                    let key = "\(info.st_dev):\(info.st_ino)"
                    let nextDepth = depth + 1
                    if let prior = visited[key], prior <= nextDepth { continue }
                    visited[key] = nextDepth
                    if let inner = linkedChildren(child.path) {
                        stack.append((child, depth + 1, inner))
                    } else {
                        unreadable += 1
                    }
                }
            }
        }
        for path in processPaths {
            if isCancelled() { return nil }
            guard let range = path.range(of: ".app/Contents/MacOS/", options: .caseInsensitive) else { continue }
            readApp(URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app"))
        }
        for root in launchAgentRoots {
            if isCancelled() { return nil }
            guard let listed = listRoot(root, follow: true) else { return nil }
            for file in listed ?? [] where file.pathExtension.lowercased() == "plist" {
                guard let agent = plist(file) else { unreadable += 1; continue }
                // A disabled updater is often an empty dictionary: it names no app, so it changes nothing.
                if let label = agent["Label"] as? String, !label.isEmpty { ids.insert(label.lowercased()) }
            }
        }
        for root in toolRoots {
            if isCancelled() { return nil }
            // stat, not lstat: ~/bin is often a link into a dotfiles checkout.
            guard let listed = listRoot(root, follow: true) else { return nil }
            for entry in listed ?? [] { names.insert(entry.lastPathComponent) }
        }
        if names.contains("brew") { names.insert("homebrew") }
        let source = "/Applications, ~/Applications, Homebrew casks and formulae, command-line tools, running apps, launch agents, LaunchServices"
        return InstalledApps(bundleIDs: ids, names: names,
                             source: unreadable == 0 ? source : source + "; \(unreadable) item\(unreadable == 1 ? "" : "s") could not be read",
                             unreadableItems: unreadable)
    }

    public static func isRegistered(bundleID: String) -> Bool? {
        guard !bundleID.isEmpty else { return nil }
        var error: Unmanaged<CFError>?
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, &error)?.takeRetainedValue() else {
            guard let failure = error?.takeRetainedValue() else { return nil }
            return CFErrorGetCode(failure) == kLSApplicationNotFoundErr ? false : nil
        }
        _ = error?.takeRetainedValue()
        return CFArrayGetCount(urls) > 0
    }

    /// Returns nil when a process path cannot be inspected; only ESRCH (a process that exited) is skipped.
    public static func runningPaths() -> [String]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0, found < Int32(pids.count) else { return nil }
        var paths: [String] = []
        for pid in pids.prefix(Int(found)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                paths.append(String(cString: buffer))
            } else if errno != ESRCH {
                return nil
            }
        }
        return paths
    }
}
