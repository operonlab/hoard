import Foundation
import ScanCore

/// Options for `suggest` with the installed-app listing and installer evidence. Past `deadline` (an MCP
/// child's) nothing more is read: the listing is unknown and evidence is "could not tell", so the
/// result still comes back in time.
func suggestAppsOptions(minBytes: Int64, limit: Int?, deadline: Date? = nil) -> SuggestOptions {
    let expired: @Sendable () -> Bool = { deadline.map { Date() >= $0 } ?? false }
    let groups = InstalledAppGroups(isCancelled: expired)
    return SuggestOptions(home: NSHomeDirectory(), now: Int64(Date().timeIntervalSince1970),
                          minBytes: minBytes, limit: limit, installedApps: InstalledApps.current(isCancelled: expired),
                          isAppRegistered: { InstalledApps.isRegistered(bundleID: $0) },
                          downloadOrigin: { expired() ? nil : InstallerEvidence.downloadOrigin(path: $0) },
                          archiveHoldsInstaller: { expired() ? nil : InstallerEvidence.archiveHoldsInstaller(path: $0) },
                          appGroupInstalled: { groups.contains($0) })
}
