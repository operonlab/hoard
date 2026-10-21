import Darwin
import Foundation

public struct SizeReading: Codable, Sendable, Equatable {
    public var bytes: Int64?
    public var status: ScanStatus

    public init(bytes: Int64?, status: ScanStatus) {
        self.bytes = bytes
        self.status = status
    }
}

public enum SizeSource: String, Codable, Sendable { case tree, walk, listing, none }

public enum AppDataKind: String, Codable, Sendable, CaseIterable {
    case applicationSupport = "Application Support"
    case caches = "Caches"
    case containers = "Containers"
    case groupContainers = "Group Containers"
    case preferences = "Preferences"
    case logs = "Logs"
    case savedState = "Saved Application State"
    case httpStorages = "HTTPStorages"
    case webKit = "WebKit"
    case cookies = "Cookies"
}

public enum AppMatch: String, Codable, Sendable {
    case bundleID, embeddedBundleID, appGroup, teamBundleID, groupBundleID
}

public struct AppDataLocation: Codable, Sendable, Equatable {
    public var path: String
    public var kind: AppDataKind
    public var matchedBy: AppMatch
    public var matchedID: String
    public var size: SizeReading
    public var sizedFrom: SizeSource
    public var isSymlink: Bool
    public var sharedWith: [String]
}

public struct AppFootprint: Codable, Sendable, Equatable {
    public var appPath: String
    public var linkTarget: String?
    public var name: String
    public var bundleID: String?
    public var teamID: String?
    public var isApple: Bool
    public var appSize: SizeReading
    public var appSizedFrom: SizeSource
    /// Covers only bundle-id-named locations and explicitly entitled groups; other app data may be omitted.
    // # ponytail: A group can also be used by components outside the listed app roots, so a group
    // may appear here as exclusive data. Add more app roots (for example /System/Applications) to widen sharing detection.
    public var data: SizeReading
    public var sharedData: SizeReading
    public var locations: [AppDataLocation]
    public var lastUsed: Date?
}

public struct AppFootprintReport: Codable, Sendable, Equatable {
    public var apps: [AppFootprint]
    public var unreadable: [String]
}

public struct AppFootprintRoots: Sendable, Equatable {
    public var applications: [String]
    public var library: String

    public init(applications: [String], library: String) {
        self.applications = applications
        self.library = library
    }

    public static func user(home: String = NSHomeDirectory()) -> AppFootprintRoots {
        AppFootprintRoots(applications: ["/Applications", home + "/Applications"], library: home + "/Library")
    }
}

public enum AppFootprintAnalyzer {
    private struct MaterializationRefused: LocalizedError, CustomStringConvertible {
        var errorDescription: String? { Materialization.refusedDetail }
        var description: String { Materialization.refusedDetail }
    }
    private struct Candidate {
        var path: String
        var isSymlink: Bool
        var resolved: String?
    }

    private struct ListedLocation {
        var path: String
        var kind: AppDataKind
        var entry: ScanEntry
        var byHost: Bool
    }

    private static let unknown = SizeReading(bytes: nil, status: .unavailable)
    private static let empty = SizeReading(bytes: 0, status: .complete)
    private static let embeddedFolders = ["Contents/PlugIns": ".appex", "Contents/Library/LoginItems": ".app",
                                          "Contents/XPCServices": ".xpc", "Contents/Helpers": ".app"]

    /// Reads `tree` on the calling thread; pass a detached copy when working off the main queue.
    public static func analyze(roots: AppFootprintRoots = .user(), tree: FileTree? = nil,
                               scanner: Scanner = Scanner(),
                               signing: (String) -> AppSigning? = AppSigning.read(bundlePath:),
                               lastUsed: (String) -> Date? = Spotlight.lastUsedDate(path:),
                               isCancelled: (() -> Bool)? = nil) throws -> AppFootprintReport {
        guard let restore = Materialization.offForThread("app footprint") else { throw MaterializationRefused() }
        defer { restore() }
        var unreadable = Set<String>()
        var candidates: [Candidate] = []
        for root in roots.applications {
            guard let entries = listing(root, scanner: scanner, unreadable: &unreadable) else { continue }
            for entry in entries {
                let path = root + "/" + entry.name
                if entry.name.hasSuffix(".app"), entry.isDirectory || entry.isSymlink {
                    candidates.append(Candidate(path: path, isSymlink: entry.isSymlink,
                                                resolved: resolvedPath(path)))
                } else if entry.isDirectory, !entry.isSymlink,
                          let children = listing(path, scanner: scanner, unreadable: &unreadable) {
                    for child in children where child.name.hasSuffix(".app") && (child.isDirectory || child.isSymlink) {
                        let childPath = path + "/" + child.name
                        candidates.append(Candidate(path: childPath, isSymlink: child.isSymlink,
                                                    resolved: resolvedPath(childPath)))
                    }
                }
            }
        }

        var chosen: [String: Candidate] = [:]
        var dangling: [Candidate] = []
        for candidate in candidates {
            guard let key = candidate.resolved else { dangling.append(candidate); continue }
            if let old = chosen[key] {
                if (old.isSymlink && !candidate.isSymlink) ||
                    (old.isSymlink == candidate.isSymlink && candidate.path < old.path) {
                    chosen[key] = candidate
                }
            } else {
                chosen[key] = candidate
            }
        }
        let appsToRead = (Array(chosen.values) + dangling).sorted { $0.path < $1.path }

        var locations: [ListedLocation] = []
        for kind in AppDataKind.allCases {
            let folder = roots.library + "/" + kind.rawValue
            if let entries = listing(folder, scanner: scanner, unreadable: &unreadable) {
                locations += entries.map { ListedLocation(path: folder + "/" + $0.name, kind: kind,
                                                          entry: $0, byHost: false) }
            }
            if kind == .preferences {
                let byHost = folder + "/ByHost"
                if let entries = listing(byHost, scanner: scanner, unreadable: &unreadable) {
                    locations += entries.map { ListedLocation(path: byHost + "/" + $0.name, kind: kind,
                                                              entry: $0, byHost: true) }
                }
            }
        }

        var apps: [AppFootprint] = []
        var appUnknown: [Bool] = []
        for candidate in appsToRead {
            if isCancelled?() == true { throw ScanError.cancelled }
            let target = (candidate.isSymlink ? candidate.resolved : nil) ?? candidate.path
            let plist = propertyList(target + "/Contents/Info.plist")
            let bundleID = plist?["CFBundleIdentifier"] as? String
            let filename = String(candidate.path.split(separator: "/").last ?? "")
            let name = (plist?["CFBundleDisplayName"] as? String) ??
                       (plist?["CFBundleName"] as? String) ?? String(filename.dropLast(4))
            let (appSize, appSource) = try candidate.isSymlink && candidate.resolved == nil
                ? (unknown, .none)
                : sizeDirectory(target, tree: tree, scanner: scanner, isCancelled: isCancelled)
            var ids: [(String, AppMatch)] = []
            var unknownMatch = false
            if let bundleID {
                ids.append((bundleID, .bundleID))
                for (relative, suffix) in embeddedFolders.sorted(by: { $0.key < $1.key }) {
                    let folder = target + "/" + relative
                    guard let entries = listing(folder, scanner: scanner, unreadable: &unreadable) else {
                        if unreadable.contains(folder) { unknownMatch = true }
                        continue
                    }
                    for entry in entries where entry.name.hasSuffix(suffix) && (entry.isDirectory || entry.isSymlink) {
                        let info = folder + "/" + entry.name + "/Contents/Info.plist"
                        if let embedded = propertyList(info), let id = embedded["CFBundleIdentifier"] as? String {
                            ids.append((id, .embeddedBundleID))
                        } else if exists(info) {
                            unknownMatch = true
                        }
                    }
                }
            }
            let signature = signing(target)
            if signature == nil { unknownMatch = true }
            let app = AppFootprint(appPath: candidate.path,
                                   linkTarget: candidate.isSymlink ? candidate.resolved : nil,
                                   name: name, bundleID: bundleID, teamID: signature?.teamID,
                                   isApple: (bundleID?.hasPrefix("com.apple.") == true) ||
                                            target.hasPrefix("/System/"),
                                   appSize: appSize, appSizedFrom: appSource,
                                   data: bundleID == nil ? unknown : empty,
                                   sharedData: bundleID == nil ? unknown : empty,
                                   locations: bundleID == nil ? [] : try locations.compactMap { item in
                                       guard let match = match(item, ids: ids, signing: signature) else { return nil }
                                       let (size, source) = try sizeLocation(item, tree: tree, scanner: scanner,
                                                                            isCancelled: isCancelled)
                                       return AppDataLocation(path: item.path, kind: item.kind, matchedBy: match.1,
                                                              matchedID: match.0, size: size, sizedFrom: source,
                                                              isSymlink: item.entry.isSymlink, sharedWith: [])
                                   },
                                   lastUsed: lastUsed(target))
            apps.append(app)
            appUnknown.append(unknownMatch)
        }

        let claimants = Dictionary(grouping: apps.flatMap { app in app.locations.map { ($0.path, app.appPath) } },
                                   by: { $0.0 }).mapValues { pairs in pairs.map(\.1).sorted() }
        for index in apps.indices {
            let unknownMatch = appUnknown[index] || unreadable.contains { $0.hasPrefix(roots.library + "/") }
            for locationIndex in apps[index].locations.indices {
                let path = apps[index].locations[locationIndex].path
                apps[index].locations[locationIndex].sharedWith =
                    (claimants[path] ?? []).filter { $0 != apps[index].appPath }
            }
            if apps[index].bundleID != nil {
                apps[index].data = total(apps[index].locations.filter { $0.sharedWith.isEmpty }.map(\.size),
                                         unknown: unknownMatch)
                apps[index].sharedData = total(apps[index].locations.filter { !$0.sharedWith.isEmpty }.map(\.size),
                                               unknown: unknownMatch)
            }
            apps[index].locations.sort {
                if $0.size.bytes == nil { return $1.size.bytes == nil && $0.path < $1.path }
                if $1.size.bytes == nil { return true }
                return $0.size.bytes == $1.size.bytes ? $0.path < $1.path : $0.size.bytes! > $1.size.bytes!
            }
        }
        apps.sort {
            let lhs = ($0.appSize.bytes ?? 0) + ($0.data.bytes ?? 0)
            let rhs = ($1.appSize.bytes ?? 0) + ($1.data.bytes ?? 0)
            return lhs == rhs ? $0.appPath < $1.appPath : lhs > rhs
        }
        return AppFootprintReport(apps: apps, unreadable: unreadable.sorted())
    }

    private static func listing(_ path: String, scanner: Scanner, unreadable: inout Set<String>) -> [ScanEntry]? {
        do { return try scanner.listDirectory(path) }
        catch ScanError.cannotOpen(_, let code) where code == ENOENT { return nil }
        catch { unreadable.insert(path); return nil }
    }

    private static func resolvedPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 || errno != ENOENT
    }

    private static func propertyList(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return plist as? [String: Any]
    }

    private static func match(_ item: ListedLocation, ids: [(String, AppMatch)],
                              signing: AppSigning?) -> (String, AppMatch)? {
        let name = item.entry.name
        if item.kind == .groupContainers, let signing {
            if signing.appGroups.contains(name) { return (name, .appGroup) }
        }
        for (id, source) in ids {
            if item.byHost {
                let prefix = id + "."
                if name.hasPrefix(prefix), name.hasSuffix(".plist") {
                    let uuid = String(name.dropFirst(prefix.count).dropLast(".plist".count))
                    if UUID(uuidString: uuid) != nil { return (id, source) }
                }
                continue
            }
            switch item.kind {
            case .applicationSupport, .caches, .containers, .logs, .webKit:
                if name == id { return (id, source) }
            case .httpStorages:
                if name == id || name == id + ".binarycookies" { return (id, source) }
            case .cookies:
                if name == id + ".binarycookies" { return (id, source) }
            case .preferences:
                if name == id + ".plist" { return (id, source) }
            case .savedState:
                if name == id + ".savedState" { return (id, source) }
            case .groupContainers:
                if let teamID = signing?.teamID, name == teamID + "." + id { return (id, .teamBundleID) }
                if name == "group." + id { return (id, .groupBundleID) }
            }
        }
        return nil
    }

    private static func sizeLocation(_ item: ListedLocation, tree: FileTree?, scanner: Scanner,
                                     isCancelled: (() -> Bool)?) throws -> (SizeReading, SizeSource) {
        if item.entry.isSymlink { return (unknown, .none) }
        if item.entry.isDirectory {
            return try sizeDirectory(item.path, tree: tree, scanner: scanner, isCancelled: isCancelled)
        }
        return (SizeReading(bytes: item.entry.allocSize, status: .complete), .listing)
    }

    private static func sizeDirectory(_ path: String, tree: FileTree?, scanner: Scanner,
                                      isCancelled: (() -> Bool)?) throws -> (SizeReading, SizeSource) {
        // # ponytail: Separate walks do not deduplicate clones across bundles and containers.
        // Tree sizes follow the tree's dedup owner; a union walk would give cross-location totals.
        if let tree {
            var nodeID = tree.lookup(path: path)
            if nodeID == nil, !path.hasPrefix("/System/") {
                nodeID = tree.lookup(path: "/System/Volumes/Data" + path)
            }
            if let nodeID {
                let node = tree[nodeID]
                return (SizeReading(bytes: node.status == .unavailable ? nil : node.totalAlloc,
                                    status: node.status), .tree)
            }
        }
        do {
            let walk = try scanner.scan(root: path, isCancelled: isCancelled)
            let node = walk[FileTree.root]
            return (SizeReading(bytes: node.status == .unavailable ? nil : node.totalAlloc,
                                status: node.status), .walk)
        } catch ScanError.cancelled {
            throw ScanError.cancelled
        } catch {
            return (unknown, .none)
        }
    }

    private static func total(_ readings: [SizeReading], unknown: Bool) -> SizeReading {
        let known = readings.compactMap(\.bytes)
        if known.isEmpty { return unknown || !readings.isEmpty ? self.unknown : empty }
        let sum = known.reduce(Int64(0), +)
        let exact = !unknown && readings.allSatisfy { $0.status == .complete }
        return SizeReading(bytes: sum, status: exact ? .complete : .partial)
    }
}
