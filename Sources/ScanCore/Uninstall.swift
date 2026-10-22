import CoreServices
import Darwin
import Foundation

public struct UninstallItem: Codable, Sendable, Equatable {
    public var path: String
    public var role: String
    public var kind: AppDataKind?
    public var size: SizeReading
    public var why: String
    public var selectedByDefault: Bool
    public var device: Int32
    public var fileID: UInt64

    public init(path: String, role: String, kind: AppDataKind?, size: SizeReading, why: String,
                selectedByDefault: Bool, device: Int32, fileID: UInt64) {
        self.path = path; self.role = role; self.kind = kind; self.size = size; self.why = why
        self.selectedByDefault = selectedByDefault; self.device = device; self.fileID = fileID
    }
}

public struct UninstallKept: Codable, Sendable, Equatable {
    public var path: String
    public var why: String
    public init(path: String, why: String) { self.path = path; self.why = why }
}

public struct UninstallPlan: Codable, Sendable, Equatable {
    public var appPath: String
    public var name: String
    public var bundleID: String?
    public var refusal: String?
    public var appNeedsAdmin: Bool
    public var items: [UninstallItem]
    public var kept: [UninstallKept]

    public init(appPath: String, name: String, bundleID: String?, refusal: String? = nil,
                items: [UninstallItem] = [], kept: [UninstallKept] = [], appNeedsAdmin: Bool = false) {
        self.appPath = appPath; self.name = name; self.bundleID = bundleID
        self.refusal = refusal; self.items = items; self.kept = kept; self.appNeedsAdmin = appNeedsAdmin
    }

    private enum CodingKeys: String, CodingKey { case appPath, name, bundleID, refusal, items, kept, appNeedsAdmin }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(appPath: try values.decode(String.self, forKey: .appPath),
                  name: try values.decode(String.self, forKey: .name),
                  bundleID: try values.decodeIfPresent(String.self, forKey: .bundleID),
                  refusal: try values.decodeIfPresent(String.self, forKey: .refusal),
                  items: try values.decode([UninstallItem].self, forKey: .items),
                  kept: try values.decode([UninstallKept].self, forKey: .kept),
                  appNeedsAdmin: try values.decodeIfPresent(Bool.self, forKey: .appNeedsAdmin) ?? false)
    }

    public func total(selected: Set<String>) -> SizeReading {
        let sizes = items.filter { selected.contains($0.path) }.map(\.size)
        let known = sizes.compactMap(\.bytes)
        guard !known.isEmpty else { return SizeReading(bytes: nil, status: .unavailable) }
        let sum = known.reduce(Int64(0)) { result, value in
            let (next, overflow) = result.addingReportingOverflow(value)
            return overflow ? Int64.max : next
        }
        return SizeReading(bytes: sum, status: sizes.allSatisfy { $0.status == .complete } ? .complete : .partial)
    }
}

public enum UninstallPlanner {
    public static func userCanMove(_ path: String) -> Bool {
        access(path, W_OK) == 0 && access((path as NSString).deletingLastPathComponent, W_OK) == 0
    }
    private static let removableApple: Set<String> = [
        "com.apple.dt.Xcode", "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote",
        "com.apple.garageband10", "com.apple.iMovieApp", "com.apple.FinalCut", "com.apple.logic10",
        "com.apple.mainstage3", "com.apple.motionapp", "com.apple.Compressor"
    ]
    private static let managedPrefixes = ["com.eset.", "com.jamf", "com.jamfsoftware.", "com.crowdstrike.",
        "com.sentinelone.", "com.paloaltonetworks.", "com.microsoft.wdav",
        "com.kandji.", "com.mosyle."]
    private static let forbidden = ["/Library", "/System", "/usr", "/private", "/Users/Shared"]
    static let systemExtensionRefusal = "這個 App 帶有系統延伸功能（例如網路過濾、攝影機或驅動程式），要由它自己的解除安裝程式或 Finder 移除，Hoard 不移除。"

    public static func isRemovableApple(_ app: AppFootprint) -> Bool {
        guard app.isApple else { return true }
        return app.bundleID.map { removableApple.contains($0) } == true && !app.appPath.hasPrefix("/System/")
    }

    public static func plan(for app: AppFootprint, in report: AppFootprintReport) -> UninstallPlan {
        guard let restore = Materialization.offForThread("uninstall plan") else {
            return UninstallPlan(appPath: app.appPath, name: app.name, bundleID: app.bundleID,
                                 refusal: Materialization.refusedDetail)
        }
        defer { restore() }
        var installs: [String] = []
        let appIdentity = FileIdentity.current(atPath: app.appPath)
        if let id = app.bundleID {
            var error: Unmanaged<CFError>?
            if let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, &error)?.takeRetainedValue() {
                for case let url as URL in urls as NSArray {
                    let path = url.standardizedFileURL.path
                    var st = stat()
                    if lstat(path, &st) == 0 && !path.contains("/.Trash/") && !path.contains("/.Trashes/")
                        && PathForms.systemPath(path) != PathForms.systemPath(app.appPath)
                        && path != app.linkTarget
                        && (appIdentity == nil || FileIdentity.current(atPath: path) != appIdentity) {
                        installs.append(path)
                    }
                }
            }
            _ = error?.takeRetainedValue()
        }
        installs += report.apps.filter { $0.bundleID == app.bundleID && $0.appPath != app.appPath
            && $0.linkTarget != app.appPath }.map(\.appPath)
        let home = NSHomeDirectory()
        return plan(for: app, in: report, runningPaths: InstalledApps.runningPaths(), otherInstalls: Array(Set(installs)),
                    appRoots: ["/Applications", home + "/Applications"],
                    launchAgentRoots: [home + "/Library/LaunchAgents"],
                    systemAgentRoots: ["/Library/LaunchAgents", "/Library/LaunchDaemons"],
                    caskrooms: ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"], home: home)
    }

    public static func plan(for app: AppFootprint, in report: AppFootprintReport,
                            runningPaths: [String]?, otherInstalls: [String],
                            appRoots: [String],
                            launchAgentRoots: [String], systemAgentRoots: [String],
                            caskrooms: [String], home: String) -> UninstallPlan {
        guard let restore = Materialization.offForThread("uninstall plan") else {
            return UninstallPlan(appPath: app.appPath, name: app.name, bundleID: app.bundleID,
                                 refusal: Materialization.refusedDetail)
        }
        defer { restore() }
        _ = report
        var result = UninstallPlan(appPath: app.appPath, name: app.name, bundleID: app.bundleID)
        func refuse(_ reason: String) -> UninstallPlan { result.refusal = reason; return result }
        guard let id = app.bundleID else { return refuse("讀不到這個 App 的識別碼，無法確認哪些資料屬於它。") }
        guard isRemovableApple(app) else { return refuse("這個 Apple App 不能由 Hoard 移除。") }
        guard !managedPrefixes.contains(where: { id.hasPrefix($0) }) else {
            return refuse("請用它自己的解除安裝程式移除。")
        }
        guard app.linkTarget == nil else { return refuse("這是連結，請到它實際的位置或用安裝它的工具移除。") }
        // Before the extension check: brew's uninstall runs the vendor's removal, extensions included.
        if let token = caskToken(appPath: app.appPath, bundleID: id, roots: caskrooms, home: home) {
            return refuse("這個 App 由 Homebrew 安裝，請在終端機執行 `brew uninstall --cask \(token)`。")
        }
        guard !hasSystemExtension(appPath: app.appPath) else {
            return refuse(systemExtensionRefusal)
        }
        guard let runningPaths else { return refuse("無法確認它有沒有在執行，所以不移除。") }
        guard !isRunning(appPath: app.appPath, runningPaths: runningPaths) else {
            return refuse("「\(app.name)」正在執行，請先結束它。")
        }
        guard withinAppRoots(app.appPath, roots: appRoots) else {
            return refuse("這個 App 不在「應用程式」資料夾裡，請到它實際的位置移除。")
        }
        if let st = lstatInfo(app.appPath), st.st_flags & UInt32(SF_DATALESS) != 0 {
            result.kept.append(.init(path: app.appPath, why: "沒有本機資料（iCloud），無法確認"))
            return refuse("App 本體沒有本機資料，無法安全移除。")
        }
        guard safe(app.appPath), let bundle = item(app.appPath, role: "app", kind: nil, size: app.appSize,
                                                    why: "App 本體", selected: true) else {
            return refuse("無法安全確認 App 本體的位置，請重新分析。")
        }
        result.items.append(bundle)
        result.appNeedsAdmin = !userCanMove(app.appPath)
        let other = otherInstalls.sorted().first
        for location in app.locations {
            let path = location.path
            if location.kind == .groupContainers {
                result.kept.append(.init(path: path, why: "可能和其他 App 共用（Group Container）")); continue
            }
            guard safe(path) else { continue }
            let st = lstatInfo(path)
            if let st, st.st_flags & UInt32(SF_DATALESS) != 0 {
                result.kept.append(.init(path: path, why: "沒有本機資料（iCloud），無法確認")); continue
            }
            if let other { result.kept.append(.init(path: path, why: "另一份 \(other) 也在使用這些資料")); continue }
            if !location.sharedWith.isEmpty {
                result.kept.append(.init(path: path, why: "也屬於 \(location.sharedWith.joined(separator: "、"))")); continue
            }
            if location.isSymlink { result.kept.append(.init(path: path, why: "是連結")); continue }
            guard st != nil else { result.kept.append(.init(path: path, why: "無法確認檔案身分")); continue }
            let selected: Bool = [.caches, .logs, .savedState, .httpStorages, .webKit].contains(location.kind)
            let match = location.matchedBy == .appGroup ? "app group \(location.matchedID)" : "bundle id \(location.matchedID)"
            guard withinUserLibrary(path, home: home) else { continue }
            if let offered = item(path, role: "data", kind: location.kind, size: location.size,
                                  why: match, selected: selected) { result.items.append(offered) }
        }
        for (roots, system) in [(launchAgentRoots, false), (systemAgentRoots, true)] {
            for root in roots {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
                for name in names.sorted() where name.hasSuffix(".plist") {
                    let path = root + "/" + name
                    guard let st = lstatInfo(path), st.st_mode & S_IFMT == S_IFREG else { continue }
                    if st.st_flags & UInt32(SF_DATALESS) != 0 {
                        result.kept.append(.init(path: path, why: "沒有本機資料（iCloud），無法確認")); continue
                    }
                    guard let reason = agentMatch(path, id: id, appPath: app.appPath) else { continue }
                    if system {
                        result.kept.append(.init(path: path, why: "系統層級，需要管理員權限，Hoard 不移除"))
                    } else if safe(path), withinUserLibrary(path, home: home) {
                        let size = SizeReading(bytes: Int64(st.st_blocks) * 512, status: .complete)
                        if let offered = item(path, role: "launchAgent", kind: nil, size: size,
                                              why: reason, selected: true) { result.items.append(offered) }
                    }
                }
            }
        }
        result.items = result.items.filter { $0.path == app.appPath || $0.path.hasPrefix(home + "/Library/") }
        return result
    }

    public static func isRunning(appPath: String, runningPaths: [String]) -> Bool {
        let prefix = PathForms.systemPath(appPath) + "/"
        let name = (appPath as NSString).lastPathComponent
        return runningPaths.contains { path in
            if PathForms.systemPath(path).hasPrefix(prefix) { return true }
            guard path.contains("/AppTranslocation/") else { return false }
            return path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) == Substring(name)
        }
    }

    public static func withinAppRoots(_ appPath: String, roots: [String]) -> Bool {
        guard let resolved = realpath(appPath, nil) else { return false }
        defer { free(resolved) }
        let path = PathForms.systemPath(String(cString: resolved))
        guard !forbidden.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
        return roots.contains { root in
            guard let resolvedRoot = realpath(root, nil) else { return false }
            defer { free(resolvedRoot) }
            return path.hasPrefix(PathForms.systemPath(String(cString: resolvedRoot)) + "/")
        }
    }

    private static func hasSystemExtension(appPath: String) -> Bool {
        let library = appPath + "/Contents/Library"
        return [("SystemExtensions", ".systemextension"), ("Extensions", ".kext")].contains { folder, suffix in
            let path = library + "/" + folder
            return (try? FileManager.default.contentsOfDirectory(atPath: path))?.contains(where: { $0.hasSuffix(suffix) }) == true
        }
    }

    private static func safe(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized == path && path.hasPrefix("/") && !forbidden.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func withinUserLibrary(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/Library/"),
              let root = realpath(home + "/Library", nil),
              let resolved = realpath(path, nil) else { return false }
        defer { free(root); free(resolved) }
        return String(cString: resolved).hasPrefix(String(cString: root) + "/")
    }

    private static func lstatInfo(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    private static func item(_ path: String, role: String, kind: AppDataKind?, size: SizeReading,
                             why: String, selected: Bool) -> UninstallItem? {
        guard let st = lstatInfo(path), st.st_flags & UInt32(SF_DATALESS) == 0,
              st.st_mode & S_IFMT != S_IFLNK,
              let identity = FileIdentity.current(atPath: path) else { return nil }
        return UninstallItem(path: path, role: role, kind: kind, size: size, why: why,
                             selectedByDefault: selected, device: identity.device, fileID: identity.fileID)
    }

    private static func agentMatch(_ path: String, id: String, appPath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let label = plist["Label"] as? String ?? ""
        guard !label.hasPrefix("com.apple.") else { return nil }
        let programs = [(plist["Program"] as? String), (plist["ProgramArguments"] as? [String])?.first].compactMap { $0 }
        guard !programs.contains(where: { $0.contains(".app/") && !$0.hasPrefix(appPath + "/") }) else { return nil }
        if label == id || label.hasPrefix(id + ".") { return "Label \(label)" }
        guard let program = programs.first(where: { $0.hasPrefix(appPath + "/") }) else { return nil }
        return "Program \(program)"
    }

    /// Whether a cask's artifacts (`uninstall_artifacts` of an install receipt, or `artifacts` of a cask
    /// file) install this app: an `app` artifact whose installed name (its `target`, else its source) is
    /// `appName`, a `pkgutil` id equal to the bundle id, or, for a pkg cask, a `quit` of the bundle id.
    /// `quit` alone is not enough: a driver cask may quit an unrelated app (blackhole-2ch quits Audio MIDI Setup).
    static func caskInstalls(_ artifacts: Any, appName: String, appPath: String, home: String, bundleID: String) -> Bool {
        var apps: [[Any]] = [], pkgutil: [String] = [], quit: [String] = [], paths: [String] = [], hasPkg = false
        func leaves(_ value: Any) -> [String] {
            if let string = value as? String { return [string] }
            return (value as? [Any])?.flatMap(leaves) ?? []
        }
        func walk(_ value: Any) {
            if let array = value as? [Any] { array.forEach(walk); return }
            guard let object = value as? [String: Any] else { return }
            for (key, child) in object {
                switch key {
                case "app": if let stanza = child as? [Any] { apps.append(stanza) }
                case "pkgutil": pkgutil += leaves(child)
                case "quit": quit += leaves(child)
                case "delete", "rmdir": paths += leaves(child)
                case "pkg": hasPkg = true
                default: walk(child)
                }
            }
        }
        walk(artifacts)
        func installedNames(_ stanza: [Any]) -> [String] {
            var names: [String] = []
            if let source = stanza.compactMap({ $0 as? String }).first {
                let target = stanza.compactMap { ($0 as? [String: Any])?["target"] as? String }.first
                names.append(((target ?? source) as NSString).lastPathComponent)
            }
            for nested in stanza.compactMap({ $0 as? [Any] }) { names += installedNames(nested) }
            return names
        }
        return apps.flatMap(installedNames).contains(appName)
            || paths.contains { ($0.hasPrefix("~/") ? home + String($0.dropFirst()) : $0) == appPath }
            || pkgutil.contains(bundleID) || (hasPkg && quit.contains(bundleID))
    }

    private static func caskToken(appPath: String, bundleID: String, roots: [String], home: String) -> String? {
        let appName = (appPath as NSString).lastPathComponent
        func localJSON(_ path: String) -> Any? {
            guard let st = lstatInfo(path), st.st_flags & UInt32(SF_DATALESS) == 0, st.st_mode & S_IFMT == S_IFREG,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        for root in roots {
            guard let tokens = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for token in tokens.sorted() {
                let metadata = root + "/" + token + "/.metadata"
                // Current Homebrew records what it installed in the receipt; the Casks/*.json beside it can be `{}`.
                if let receipt = localJSON(metadata + "/INSTALL_RECEIPT.json") as? [String: Any],
                   let artifacts = receipt["uninstall_artifacts"],
                   caskInstalls(artifacts, appName: appName, appPath: appPath, home: home, bundleID: bundleID) { return token }
                guard let versions = try? FileManager.default.contentsOfDirectory(atPath: metadata) else { continue }
                for version in versions {
                    let versionPath = metadata + "/" + version
                    guard let hashes = try? FileManager.default.contentsOfDirectory(atPath: versionPath) else { continue }
                    for hash in hashes {
                        let casks = versionPath + "/" + hash + "/Casks"
                        guard let files = try? FileManager.default.contentsOfDirectory(atPath: casks) else { continue }
                        for file in files where file.hasSuffix(".json") || file.hasSuffix(".rb") {
                            let path = casks + "/" + file
                            guard let st = lstatInfo(path), st.st_flags & UInt32(SF_DATALESS) == 0,
                                  st.st_mode & S_IFMT == S_IFREG,
                                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
                            if file.hasSuffix(".json"),
                               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let artifacts = object["artifacts"],
                               caskInstalls(artifacts, appName: appName, appPath: appPath, home: home, bundleID: bundleID) { return token }
                            if file.hasSuffix(".rb"), let text = String(data: data, encoding: .utf8),
                               rubyAppNames(text).contains(appName) {
                                return token
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func rubyAppNames(_ text: String) -> [String] {
        let pattern = #"(?m)^\s*app\s+["']([^"']+)["'](?:\s*,\s*target:\s*["']([^"']+)["'])?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let range = match.range(at: match.range(at: 2).location == NSNotFound ? 1 : 2)
            guard range.location != NSNotFound else { return nil }
            return (source.substring(with: range) as NSString).lastPathComponent
        }
    }
}
