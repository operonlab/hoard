import Foundation

// Read-only cleanup suggestions. Hoard never deletes: every suggestion only explains what could
// be removed and carries its proof (a marker file, a home-anchored location, or an age).

public enum SuggestCategory: String, Sendable, Codable, CaseIterable {
    case buildArtifact = "build_artifact", packageCache = "package_cache", appCache = "app_cache", installer,
         oldLog = "old_log", appLeftover = "app_leftover"
}

public enum SuggestSafety: String, Sendable, Codable, CaseIterable { case regenerable, redownloadable, review }

public enum SuggestTarget: Sendable, Equatable {
    case directoryNamed([String])                     // any live directory with one of these names (exact, case-sensitive)
    case homePath(String)                             // exactly <home>/<relative>
    case childOfHomePath(String)                      // each live child of <home>/<relative>
    case underHomePath(String, extensions: [String])  // files at any depth below it with a listed extension; [] = any file
    case underHomePaths([String], extensions: [String]) // files at any depth below any listed home-relative folder
    case fileExtension([String])                      // any live file with a listed extension
    case appLeftovers                                 // live children of known Library data folders
}

public enum SuggestMarker: Sendable, Equatable {
    case siblingAny([String])           // the parent folder lists one of these names
    case childAny([String])             // the candidate folder lists one of these names
    case onlyChildExtensions([String])  // ≥1 live child, and every live child is a file with a listed extension
    case location                       // the target itself is the proof: home-anchored and extension rules
}

public struct SuggestRule: Sendable, Equatable {
    public var id: String
    public var category: SuggestCategory
    public var safety: SuggestSafety
    public var target: SuggestTarget
    public var marker: SuggestMarker
    /// Non-empty and none present beside the candidate → safety becomes `.review`.
    public var confirmSiblings: [String]
    public var minAgeDays: Int?
    public var minBytes: Int64?
    /// Plain English, shown to the user.
    public var reason: String

    public init(id: String, category: SuggestCategory, safety: SuggestSafety, target: SuggestTarget, marker: SuggestMarker,
                confirmSiblings: [String] = [], minAgeDays: Int? = nil, minBytes: Int64? = nil, reason: String) {
        self.id = id; self.category = category; self.safety = safety; self.target = target; self.marker = marker
        self.confirmSiblings = confirmSiblings; self.minAgeDays = minAgeDays; self.minBytes = minBytes; self.reason = reason
    }
}

public struct InstalledApps: Sendable, Equatable {
    public var bundleIDs: Set<String>
    public var names: Set<String>
    /// The vendor part of each bundle id (`google` in `com.google.chrome`), normalized like `names`.
    public var vendors: Set<String>
    public var source: String
    /// Items in the listed places that could not be read. Their apps may be installed and unseen, so a
    /// folder is then claimed only when LaunchServices positively does not know its bundle id.
    public var unreadableItems: Int

    public init(bundleIDs: Set<String>, names: Set<String>, source: String, unreadableItems: Int = 0) {
        func normalized(_ s: some StringProtocol) -> String { s.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" } }
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        self.names = Set(names.map(normalized))
        self.vendors = Set(self.bundleIDs.compactMap { id in
            let parts = id.split(separator: ".")
            return parts.count >= 2 ? normalized(parts[1]) : nil
        })
        self.source = source
        self.unreadableItems = unreadableItems
    }
}

public struct SuggestOptions: Sendable, Equatable {
    public var home: String
    public var now: Int64          // seconds since 1970
    public var minBytes: Int64
    public var limit: Int?
    public var installedApps: InstalledApps?
    public var isAppRegistered: (@Sendable (String) -> Bool?)?
    public var downloadOrigin: (@Sendable (String) -> String?)?
    public var archiveHoldsInstaller: (@Sendable (String) -> Bool?)?
    public var appGroupInstalled: (@Sendable (String) -> Bool?)?

    public init(home: String, now: Int64, minBytes: Int64 = 1_048_576, limit: Int? = nil,
                installedApps: InstalledApps? = nil, isAppRegistered: (@Sendable (String) -> Bool?)? = nil,
                downloadOrigin: (@Sendable (String) -> String?)? = nil,
                archiveHoldsInstaller: (@Sendable (String) -> Bool?)? = nil,
                appGroupInstalled: (@Sendable (String) -> Bool?)? = nil) {
        self.home = home; self.now = now; self.minBytes = minBytes; self.limit = limit
        self.installedApps = installedApps; self.isAppRegistered = isAppRegistered
        self.downloadOrigin = downloadOrigin; self.archiveHoldsInstaller = archiveHoldsInstaller
        self.appGroupInstalled = appGroupInstalled
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.home == rhs.home && lhs.now == rhs.now && lhs.minBytes == rhs.minBytes && lhs.limit == rhs.limit
            && lhs.installedApps == rhs.installedApps && (lhs.isAppRegistered == nil) == (rhs.isAppRegistered == nil)
            && (lhs.downloadOrigin == nil) == (rhs.downloadOrigin == nil)
            && (lhs.archiveHoldsInstaller == nil) == (rhs.archiveHoldsInstaller == nil)
            && (lhs.appGroupInstalled == nil) == (rhs.appGroupInstalled == nil)
    }
}

public struct Suggestion: Sendable, Equatable {
    public var node: NodeID
    public var path: String          // in the tree's own form
    public var bytes: Int64          // node.totalAlloc; a lower bound when status is .partial
    public var status: ScanStatus    // never .unavailable
    public var category: SuggestCategory
    public var safety: SuggestSafety
    public var ruleID: String
    public var reason: String
    public var evidence: String      // e.g. "sibling package.json, package-lock.json"
    public var newestModTime: Int64  // max modTime over the live subtree; 0 = unknown
    public var sharedFiles: Int64    // files inside with linkCount > 1 or .cloneShared: may free less than bytes
}

public enum SuggestSkipReason: String, Sendable, Codable {
    case unreadable, markerUnknown = "marker_unknown", protectedPath = "protected_path", containsGit = "contains_git",
         ageUnknown = "age_unknown", installedAppsUnknown = "installed_apps_unknown"
}

public struct SkippedCandidate: Sendable, Equatable {
    public var node: NodeID
    public var path: String
    public var ruleID: String
    public var why: SuggestSkipReason
    public var status: ScanStatus
}

public struct SuggestReport: Sendable, Equatable {
    public var scopeStatus: ScanStatus
    public var suggestions: [Suggestion]   // largest bytes first, ties by path
    public var omitted: Int                // cut by `limit`
    public var totalBytes: Int64           // covers omitted suggestions too
    public var totalStatus: ScanStatus
    public var skipped: [SkippedCandidate] // sorted by path
}

public enum SuggestError: Error, Equatable { case invalidHome(String), invalidScope(NodeID) }
