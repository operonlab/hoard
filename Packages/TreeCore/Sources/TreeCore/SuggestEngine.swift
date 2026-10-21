import Foundation

/// Finds cleanup candidates in an already-scanned tree. Read-only: it never touches the disk, the
/// clock or the environment (home and now come in `SuggestOptions`), so it is safe on a background
/// thread over a value copy of `FileTree.nodes`.
///
/// One walk over the scope, O(nodes): each folder's child list is scanned a constant number of
/// times, and each candidate's subtree once (candidates never nest). Paths are built only for
/// entries that end up in the report.
public enum CleanupSuggester {
    public static func suggest(in tree: FileTree, under scope: NodeID = FileTree.root,
                               options: SuggestOptions, rules: [SuggestRule] = SuggestRule.defaults) throws -> SuggestReport {
        try suggest(in: tree.nodes, rootPath: tree.rootPath, under: scope, options: options, rules: rules)
    }

    public static func suggest(in nodes: [Node], rootPath: String, under scope: NodeID = FileTree.root,
                               options: SuggestOptions, rules: [SuggestRule] = SuggestRule.defaults) throws -> SuggestReport {
        try suggest(in: nodes, rootPath: rootPath, under: scope, options: options, rules: rules,
                    workers: min(ProcessInfo.processInfo.activeProcessorCount, 16))
    }

    /// `workers` threads walk trees of at least `FileTree.parallelThreshold` nodes; 1 walks on the caller.
    static func suggest(in nodes: [Node], rootPath: String, under scope: NodeID = FileTree.root, options: SuggestOptions,
                        rules: [SuggestRule] = SuggestRule.defaults, workers: Int) throws -> SuggestReport {
        var home = options.home
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        guard home.hasPrefix("/"), home != "/" else { throw SuggestError.invalidHome(options.home) }
        guard scope >= 0, Int(scope) < nodes.count, !nodes[Int(scope)].isRemoved else {
            throw SuggestError.invalidScope(scope)
        }

        let scopeStatus = nodes[Int(scope)].status
        var walker = Walker(nodes: nodes, rootPath: rootPath, home: home, options: options, rules: rules)
        if walker.insideNoEntryZone(scope) {
            let skip = SkippedCandidate(node: scope, path: walker.path(of: scope), ruleID: "package",
                                        why: .protectedPath, status: scopeStatus)
            return SuggestReport(scopeStatus: scopeStatus, suggestions: [], omitted: 0, totalBytes: 0,
                                 totalStatus: .partial, skipped: [skip])
        }
        if scopeStatus == .unavailable {
            return SuggestReport(scopeStatus: .unavailable, suggestions: [], omitted: 0, totalBytes: 0,
                                 totalStatus: .unavailable, skipped: [])
        }
        walker.run(scope: scope, workers: workers)

        var suggestions = walker.suggestions
        suggestions.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : ($0.path != $1.path ? $0.path < $1.path : $0.node < $1.node) }
        let totalBytes = suggestions.reduce(Int64(0)) { $0 + $1.bytes }
        let anyPartial = scopeStatus == .partial || suggestions.contains { $0.status == .partial }
        var omitted = 0
        if let limit = options.limit, suggestions.count > max(0, limit) {
            omitted = suggestions.count - max(0, limit)
            suggestions.removeLast(omitted)
        }
        let skipped = walker.skipped.sorted { $0.path != $1.path ? $0.path < $1.path : ($0.ruleID != $1.ruleID ? $0.ruleID < $1.ruleID : $0.node < $1.node) }
        return SuggestReport(scopeStatus: scopeStatus, suggestions: suggestions, omitted: omitted, totalBytes: totalBytes,
                             totalStatus: anyPartial ? .partial : .complete, skipped: skipped)
    }

    /// The macOS firmlink prefix: a whole-disk scan is rooted at the Data volume, so home shows up
    /// there as `/System/Volumes/Data` + home.
    private static let dataVolume = "/System/Volumes/Data"
    private static let leftoverLocations = ["Library/Application Support", "Library/Containers", "Library/Group Containers",
                                            "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit",
                                            "Library/Logs", "Library/Preferences"]
    private static let neverDelete = ["1password", "agilebits", "keychain", "bitwarden", "lastpass", "keepass", "dashlane",
                                      "enpass", "ssh", "gpg", "gnupg"]
    /// Data macOS itself keeps in the leftover locations under names that are not `com.apple.*`.
    /// None of it belongs to an app you could have removed (device backups, contacts, call history…).
    private static let appleNames: Set<String> = [
        "accounts", "addressbook", "animoji", "assistant", "baseband", "callhistorydb", "callhistorytransactions",
        "cloudkit", "clouddocs", "contacts", "controlcenter", "coresimulator", "crashreporter", "diagnosticreports",
        "differentialprivacy", "diskimages", "dock", "facetime", "fileprovider", "finder", "homeenergyd", "icdd",
        "icloud", "intelligenceflow", "knowledge", "locationaccessstored", "loginwindow", "mobilesync", "music",
        "networkserviceproxy", "photossearch.aapbz", "photosupgrade.aapbz", "privacypreservingmeasurement",
        "safari", "sirittsservice", "syncservices", "systempreferences", "systemsettings"]

    /// Folders the walk never enters, and that make a scope or root inside them yield nothing.
    static func isNoEntryName(_ name: String) -> Bool {
        // `Packages.isPackage` without building a String: for an ASCII name the extension key is
        // `fileExtension` in integer form, and `.git` is the list's only name.
        if let fast = ASCIIName.check(name, { ASCIIName.equals($0, "node_modules") || ASCIIName.equals($0, ".git") }) {
            return fast || packageKeys.contains(ExtensionKey(fileName: name))
        }
        return name.lowercased() == "node_modules" || Packages.isPackage(name: name)
    }
    private static let packageKeys = Set(Packages.extensions.map { ExtensionKey(extension: $0) })

    /// `.git` and photos libraries, in any case: the default volume is case-insensitive, so
    /// `Foo.PhotosLibrary` is still a library.
    static func isGit(_ name: String) -> Bool {
        ASCIIName.check(name, { ASCIIName.equals($0, ".git") }) ?? (name.lowercased() == ".git")
    }
    static func isPhotosLibrary(_ name: String) -> Bool {
        ASCIIName.check(name, { ASCIIName.hasSuffix($0, ".photoslibrary") }) ?? name.lowercased().hasSuffix(".photoslibrary")
    }

    /// Case-insensitive tests on an all-ASCII name's bytes, so the walk builds no lowercased String per
    /// node. A name with any non-ASCII byte takes `lowercased()`: the Kelvin sign lowercases to "k".
    private enum ASCIIName {
        static func check(_ name: String, _ body: (UnsafeBufferPointer<UInt8>) -> Bool) -> Bool? {
            name.utf8.withContiguousStorageIfAvailable { b in b.allSatisfy { $0 < 0x80 } ? body(b) : nil } ?? nil
        }
        /// `pattern` is lowercase ASCII.
        static func equals(_ b: UnsafeBufferPointer<UInt8>, _ pattern: StaticString) -> Bool {
            b.count == pattern.utf8CodeUnitCount && matches(b, from: 0, pattern)
        }
        static func hasSuffix(_ b: UnsafeBufferPointer<UInt8>, _ pattern: StaticString) -> Bool {
            b.count >= pattern.utf8CodeUnitCount && matches(b, from: b.count - pattern.utf8CodeUnitCount, pattern)
        }
        private static func matches(_ b: UnsafeBufferPointer<UInt8>, from start: Int, _ pattern: StaticString) -> Bool {
            let p = pattern.utf8Start
            for i in 0..<pattern.utf8CodeUnitCount {
                var c = b[start + i]
                if c >= 0x41 && c <= 0x5A { c += 0x20 }
                if c != p[i] { return false }
            }
            return true
        }
    }

    private enum MarkerResult { case pass(String), fail, unknown }
    private enum InstalledResult { case installed, gated, absent }

    private struct SubtreeStats {
        var newestMod: Int64 = 0
        var newestAccess: Int64 = 0
        var shared: Int64 = 0
        var checkouts = 0
        var git = false
        var photosLibrary = false
    }

    private struct Walker {
        let nodes: [Node]
        let rootPath: String
        let base: String
        let homeForms: [String]
        let options: SuggestOptions
        let rules: [SuggestRule]
        /// Rule indices by trigger, each list ascending so the first matching row still wins.
        var byName: [String: [Int]] = [:]
        var byExt: [String: [Int]] = [:]
        var exactAnchor: [NodeID: [Int]] = [:]
        var childAnchor: [NodeID: [Int]] = [:]
        var underAnchor: [NodeID: [Int]] = [:]
        /// Lowercased extension filter per `underHomePath` rule; empty = any file.
        var underExts: [Int: Set<String>] = [:]
        var leftoverParents: [NodeID: String] = [:]
        /// Every anchored folder and its ancestors: a leftover candidate skipped as Apple's or
        /// unattributable (`com.apple.mail`) is still walked into when an anchor lies below it (Mail Downloads).
        var anchorAncestors: Set<NodeID> = []
        /// Active `underHomePath` rule sets; a stack frame carries an index into this list.
        var contexts: [[Int]] = []

        var suggestions: [Suggestion] = []
        var skipped: [SkippedCandidate] = []

        /// `byExt` answers by integer extension key, so a file costs no String; the String table still decides.
        var extMemo: [ExtensionKey: (rules: [Int]?, ext: String)] = [:]

        // Per folder being expanded.
        var curDir: NodeID = 0
        var curNames: Set<String>?
        var curChildRules: [Int]?
        /// False when `curDir` is not an anchor or above one: then none of its children is an anchor.
        var curHoldsAnchors = false

        init(nodes: [Node], rootPath: String, home: String, options: SuggestOptions, rules: [SuggestRule]) {
            self.nodes = nodes
            self.rootPath = rootPath
            self.base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
            var forms = [home, CleanupSuggester.dataVolume + home]
            if home.hasPrefix(CleanupSuggester.dataVolume + "/") {
                forms.append(String(home.dropFirst(CleanupSuggester.dataVolume.count)))
            }
            var seen = Set<String>()
            self.homeForms = forms.filter { seen.insert($0).inserted }
            self.options = options
            self.rules = rules

            for (i, rule) in rules.enumerated() {
                switch rule.target {
                case .directoryNamed(let names):
                    for name in Set(names) { byName[name, default: []].append(i) }
                case .fileExtension(let exts):
                    for ext in Set(exts.map { $0.lowercased() }) { byExt[ext, default: []].append(i) }
                case .homePath(let rel):
                    for id in resolveAnchors(rel) { exactAnchor[id, default: []].append(i) }
                case .childOfHomePath(let rel):
                    for id in resolveAnchors(rel) { childAnchor[id, default: []].append(i) }
                case .underHomePath(let rel, let exts):
                    underExts[i] = Set(exts.map { $0.lowercased() })
                    for id in resolveAnchors(rel) { underAnchor[id, default: []].append(i) }
                case .underHomePaths(let rels, let exts):
                    underExts[i] = Set(exts.map { $0.lowercased() })
                    for rel in rels {
                        for id in resolveAnchors(rel) { underAnchor[id, default: []].append(i) }
                    }
                case .appLeftovers:
                    for rel in CleanupSuggester.leftoverLocations {
                        for id in resolveAnchors(rel) {
                            childAnchor[id, default: []].append(i)
                            leftoverParents[id] = rel
                        }
                    }
                }
            }
            for anchor in Set(exactAnchor.keys).union(childAnchor.keys).union(underAnchor.keys) {
                var cur = anchor
                while cur >= 0, anchorAncestors.insert(cur).inserted { cur = nodes[Int(cur)].parent }
            }
        }

        // MARK: Paths

        /// `<homeForm>/<relative>` for every home form, resolved the way `FileTree.lookup(path:)` does.
        private func resolveAnchors(_ relative: String) -> [NodeID] {
            var rel = Substring(relative)
            while rel.hasPrefix("/") { rel = rel.dropFirst() }
            var out: [NodeID] = []
            for form in homeForms {
                if let id = resolve(rel.isEmpty ? form : form + "/" + rel), !out.contains(id) { out.append(id) }
            }
            return out
        }

        private func resolve(_ absolute: String) -> NodeID? {
            var p = absolute
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            if p == base || p == rootPath { return FileTree.root }
            guard p.hasPrefix(base + "/") else { return nil }
            var cur = FileTree.root
            for comp in p.dropFirst(base.count + 1).split(separator: "/") {
                guard let next = liveChild(named: comp, of: cur) else { return nil }
                cur = next
            }
            return cur
        }

        private func liveChild(named name: Substring, of id: NodeID) -> NodeID? {
            var c = nodes[Int(id)].firstChild
            while c >= 0 {
                if !nodes[Int(c)].isRemoved && nodes[Int(c)].name == name { return c }
                c = nodes[Int(c)].nextSibling
            }
            return nil
        }

        func path(of id: NodeID) -> String {
            if id == FileTree.root { return rootPath }
            var parts: [String] = []
            var cur = id
            while cur != FileTree.root && cur >= 0 {
                parts.append(nodes[Int(cur)].name)
                cur = nodes[Int(cur)].parent
            }
            return base + "/" + parts.reversed().joined(separator: "/")
        }

        /// A path equal to or above a home form, `<home>/Documents`, `<home>/Desktop`, or a `.git` or
        /// photos library entry. Holds for any rule table.
        private func isProtected(_ path: String, name: String) -> Bool {
            if CleanupSuggester.isGit(name) || CleanupSuggester.isPhotosLibrary(name) { return true }
            for h in homeForms {
                if path == h || h.hasPrefix(path + "/") || path == h + "/Documents" || path == h + "/Desktop" {
                    return true
                }
            }
            return false
        }

        /// True when the root or scope is, or sits inside, a folder the walk never enters.
        func insideNoEntryZone(_ scope: NodeID) -> Bool {
            if rootPath.split(separator: "/").contains(where: { CleanupSuggester.isNoEntryName(String($0)) }) {
                return true
            }
            var cur = scope
            while cur != FileTree.root && cur >= 0 {
                if CleanupSuggester.isNoEntryName(nodes[Int(cur)].name) { return true }
                cur = nodes[Int(cur)].parent
            }
            return false
        }

        // MARK: Walk

        mutating func run(scope: NodeID, workers: Int) {
            // `underHomePath` anchors at or above the scope are already active.
            var initial: [Int] = []
            var cur = scope
            while cur >= 0 {
                if let r = underAnchor[cur] { initial.append(contentsOf: r) }
                if cur == FileTree.root { break }
                cur = nodes[Int(cur)].parent
            }
            contexts = [Array(Set(initial)).sorted()]
            recordUnknownApps(at: scope)

            var stack: [(NodeID, Int)] = [(scope, 0)]
            var kids: [NodeID] = []
            guard workers > 1, nodes.count >= FileTree.parallelThreshold else {
                while let (dir, ctx) = stack.popLast() { expand(dir, ctx: ctx, into: &stack, kids: &kids) }
                return
            }
            // Each folder is expanded exactly once with the same parent and rule context as in a single
            // walk, and the report is sorted afterwards, so the split changes the time, not the answer.
            // Folders bigger than `target` are expanded here; the rest are walked on worker threads.
            let sizes = subtreeSizes()
            let target = max(Int32(FileTree.parallelThreshold / 8), sizes[Int(scope)] / Int32(workers * 8))
            var tasks: [(NodeID, Int)] = []
            while let (dir, ctx) = stack.popLast() {
                if sizes[Int(dir)] <= target { tasks.append((dir, ctx)) } else { expand(dir, ctx: ctx, into: &stack, kids: &kids) }
            }
            let bins = Self.pack(tasks, sizes: sizes, into: workers * 4)
            var results = [(suggestions: [Suggestion], skipped: [SkippedCandidate])](repeating: ([], []), count: bins.count)
            let template = self
            results.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: bins.count) { b in
                    var w = template
                    w.suggestions = []
                    w.skipped = []
                    var stack = bins[b], kids: [NodeID] = []
                    while let (dir, ctx) = stack.popLast() { w.expand(dir, ctx: ctx, into: &stack, kids: &kids) }
                    out[b] = (w.suggestions, w.skipped)
                }
            }
            for r in results {
                suggestions += r.suggestions
                skipped += r.skipped
            }
        }

        /// Evaluates a folder's children and pushes the ones to walk into.
        private mutating func expand(_ dir: NodeID, ctx: Int, into stack: inout [(NodeID, Int)], kids: inout [NodeID]) {
            kids.removeAll(keepingCapacity: true)
            var c = nodes[Int(dir)].firstChild
            while c >= 0 {
                if !nodes[Int(c)].isRemoved { kids.append(c) }
                c = nodes[Int(c)].nextSibling
            }
            curDir = dir
            curNames = nil
            curChildRules = childAnchor[dir]
            curHoldsAnchors = anchorAncestors.contains(dir)
            for k in kids {
                if curHoldsAnchors { recordUnknownApps(at: k) }
                let descend = evaluate(k, ctx: ctx)
                guard descend, nodes[Int(k)].isDirectory, nodes[Int(k)].status != .unavailable,
                      !CleanupSuggester.isNoEntryName(nodes[Int(k)].name) else { continue }
                var childCtx = ctx
                if curHoldsAnchors, let added = underAnchor[k] {
                    contexts.append(Array(Set(contexts[ctx] + added)).sorted())
                    childCtx = contexts.count - 1
                }
                stack.append((k, childCtx))
            }
        }

        /// Live nodes in each subtree, used only to split the walk evenly. A parent comes before its
        /// children in `nodes` wherever the tree came from; a node that broke that would only make a
        /// count low and the split less even.
        private func subtreeSizes() -> [Int32] {
            var sizes = [Int32](repeating: 0, count: nodes.count)
            nodes.withUnsafeBufferPointer { all in
                sizes.withUnsafeMutableBufferPointer { s in
                    for i in stride(from: all.count - 1, through: 0, by: -1) where !all[i].isRemoved {
                        s[i] += 1
                        let p = Int(all[i].parent)
                        if p >= 0 && p < i { s[p] += s[i] }
                    }
                }
            }
            return sizes
        }

        /// Largest first into the least loaded bin.
        private static func pack(_ tasks: [(NodeID, Int)], sizes: [Int32], into count: Int) -> [[(NodeID, Int)]] {
            var bins = [[(NodeID, Int)]](repeating: [], count: min(count, tasks.count))
            var load = [Int](repeating: 0, count: bins.count)
            for t in tasks.sorted(by: { sizes[Int($0.0)] > sizes[Int($1.0)] }) {
                var best = 0
                for b in load.indices where load[b] < load[best] { best = b }
                bins[best].append(t)
                load[best] += Int(sizes[Int(t.0)])
            }
            return bins
        }

        private mutating func recordUnknownApps(at id: NodeID) {
            guard options.installedApps == nil, leftoverParents[id] != nil,
                  rules.contains(where: { $0.id == "app_leftovers" }) else { return }
            skipped.append(SkippedCandidate(node: id, path: path(of: id), ruleID: "app_leftovers",
                                            why: .installedAppsUnknown, status: nodes[Int(id)].status))
        }

        /// Runs the rule table on one node. Returns whether the walk may descend into it.
        private mutating func evaluate(_ id: NodeID, ctx: Int) -> Bool {
            var candidates: [Int] = []
            var sources = 0
            if nodes[Int(id)].isDirectory {
                if let r = byName[nodes[Int(id)].name] { candidates += r; sources += 1 }
            } else if !byExt.isEmpty || !contexts[ctx].isEmpty {
                let key = ExtensionKey(fileName: nodes[Int(id)].name)
                let info: (rules: [Int]?, ext: String)
                if let hit = extMemo[key] {
                    info = hit
                } else {
                    let ext = key.string
                    info = (byExt[ext], ext)
                    extMemo[key] = info
                }
                if let r = info.rules { candidates += r; sources += 1 }
                var under = false
                for r in contexts[ctx] where underExts[r].map({ $0.isEmpty || $0.contains(info.ext) }) ?? false {
                    candidates.append(r); under = true
                }
                if under { sources += 1 }
            }
            if curHoldsAnchors, let r = exactAnchor[id] { candidates += r; sources += 1 }
            if let r = curChildRules { candidates += r; sources += 1 }
            if candidates.isEmpty { return true }
            if sources > 1 { candidates.sort() }
            let n = nodes[Int(id)]

            for r in candidates {
                let rule = rules[r]
                if rule.target == .appLeftovers {
                    guard let location = leftoverParents[curDir] else { continue }
                    if options.installedApps == nil { continue }
                    if location == "Library/Preferences" && (n.isDirectory || !n.name.lowercased().hasSuffix(".plist")) { continue }
                    // An app's data is a folder; a loose file here (a log in Logs, a database in
                    // Application Support) is left to the other rules.
                    if !n.isDirectory && location != "Library/Preferences" && location != "Library/HTTPStorages" { continue }
                    guard let key = leftoverKey(n.name, location: location) else { return anchorAncestors.contains(id) }
                    switch isInstalled(key, name: n.name, location: location) {
                    case .installed: return true
                    case .gated:
                        // Say so only for what the rule would otherwise suggest: big enough and not used lately.
                        if n.totalAlloc >= max(options.minBytes, rule.minBytes ?? 0) {
                            let stats = subtreeStats(id)
                            let newest = max(stats.newestMod, stats.newestAccess)
                            if rule.minAgeDays.map({ newest < options.now - Int64($0) * 86_400 }) ?? true {
                                skipped.append(SkippedCandidate(node: id, path: path(of: id), ruleID: rule.id,
                                                                why: .installedAppsUnknown, status: n.status))
                            }
                        }
                        return true
                    case .absent: break
                    }
                    let marker = MarkerResult.pass("no installed app \(key) (checked \(options.installedApps?.source ?? "unknown"))")
                    let before = suggestions.count
                    let descend = claim(id, rule: rule, marker: marker)
                    return descend || suggestions.count == before
                }
                let marker = markerResult(rule, id)
                if case .fail = marker { continue }
                return claim(id, rule: rule, marker: marker)
            }
            return true
        }

        private func leftoverKey(_ name: String, location: String) -> String? {
            var key = name.lowercased()
            for suffix in [".savedstate", ".binarycookies", ".plist"] where key.hasSuffix(suffix) {
                key.removeLast(suffix.count)
            }
            if location == "Library/Group Containers" {
                if key.hasPrefix("group.") { key.removeFirst(6) }
                let parts = key.split(separator: ".", maxSplits: 1)
                if parts.count == 2 && parts[0].count == 10 && parts[0].allSatisfy({ $0.isLetter || $0.isNumber }) {
                    key = String(parts[1])
                    if key.hasPrefix("group.") { key.removeFirst(6) }
                    // `UBF8T346G9.Office`: what is left names no app, so it cannot be attributed.
                    if !key.contains(".") { return nil }
                }
            }
            // Apple's ids also come as groups.com.apple.*, systemgroup.com.apple.*, <team>.group.com.apple.*.
            guard !key.isEmpty, !key.contains("com.apple."), !key.hasPrefix("is.workflow."),
                  !CleanupSuggester.appleNames.contains(key),
                  !CleanupSuggester.neverDelete.contains(where: { key.contains($0) }) else { return nil }
            return key
        }

        private func isInstalled(_ key: String, name: String, location: String) -> InstalledResult {
            let apps = options.installedApps ?? InstalledApps(bundleIDs: [], names: [], source: "unknown")
            if location == "Library/Group Containers" {
                if apps.unreadableItems > 0 { return .gated }
                let parts = key.split(separator: ".")
                let vendor = parts.count >= 2 ? parts.prefix(2).joined(separator: ".") : key
                if apps.bundleIDs.contains(where: { $0 == vendor || $0.hasPrefix(vendor + ".") }) { return .installed }
                if parts.count <= 2 {
                    let normalized = key.filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
                    if apps.names.contains(normalized) || apps.vendors.contains(normalized) { return .installed }
                }
                if let check = options.appGroupInstalled {
                    switch check(name) {
                    case true: return .installed
                    case nil: return .gated
                    case false: break
                    }
                }
                return .absent
            }
            if apps.bundleIDs.contains(key) || apps.bundleIDs.contains(where: { $0.hasPrefix(key + ".") || key.hasPrefix($0 + ".") }) {
                return .installed
            }
            let normalized = key.filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
            if apps.names.contains(normalized) { return .installed }
            // A dotless folder named after the vendor of an installed app (`Google` for Chrome).
            if !key.contains("."), apps.vendors.contains(normalized) { return .installed }
            let reverseDNS = key.filter({ $0 == "." }).count >= 2 && key.contains(where: { $0.isLetter })
            if reverseDNS, let check = options.isAppRegistered, check(key) != false { return .installed }
            // Some installed items could not be read: only a reverse-DNS id that LaunchServices
            // positively does not know can be claimed; a name match could be one of the unseen apps.
            if apps.unreadableItems > 0 && !(reverseDNS && options.isAppRegistered != nil) { return .gated }
            return .absent
        }

        private mutating func parentNames() -> Set<String> {
            if let s = curNames { return s }
            var s = Set<String>()
            var c = nodes[Int(curDir)].firstChild
            while c >= 0 {
                if !nodes[Int(c)].isRemoved { s.insert(nodes[Int(c)].name) }
                c = nodes[Int(c)].nextSibling
            }
            curNames = s
            return s
        }

        private mutating func markerResult(_ rule: SuggestRule, _ id: NodeID) -> MarkerResult {
            let n = nodes[Int(id)]
            switch rule.marker {
            case .location:
                return .pass(locationEvidence(rule.target))
            case .siblingAny(let names):
                let present = parentNames()
                let found = names.filter { present.contains($0) }
                if !found.isEmpty { return .pass("sibling " + found.joined(separator: ", ")) }
                return nodes[Int(curDir)].flags.contains(.listingIncomplete) ? .unknown : .fail
            case .childAny(let names):
                guard n.isDirectory else { return .fail }
                var found: [String] = []
                var c = n.firstChild
                while c >= 0 {
                    let child = nodes[Int(c)]
                    if !child.isRemoved && names.contains(child.name) && !found.contains(child.name) { found.append(child.name) }
                    c = child.nextSibling
                }
                if !found.isEmpty { return .pass("contains " + found.joined(separator: ", ")) }
                return n.flags.contains(.listingIncomplete) || n.status == .unavailable ? .unknown : .fail
            case .onlyChildExtensions(let exts):
                guard n.isDirectory else { return .fail }
                let allowed = Set(exts.map { $0.lowercased() })
                var count = 0
                var c = n.firstChild
                while c >= 0 {
                    let child = nodes[Int(c)]
                    if !child.isRemoved {
                        if child.isDirectory || !allowed.contains(FileTree.fileExtension(child.name)) { return .fail }
                        count += 1
                    }
                    c = child.nextSibling
                }
                if n.flags.contains(.listingIncomplete) || n.status == .unavailable { return .unknown }
                if count == 0 { return .fail }
                return .pass("only " + exts.map { "." + $0 }.joined(separator: ", ") + " files inside")
            }
        }

        private func locationEvidence(_ target: SuggestTarget) -> String {
            switch target {
            case .homePath(let rel): return "at ~/" + rel
            case .childOfHomePath(let rel): return "inside ~/" + rel
            case .underHomePath(let rel, let exts):
                return "under ~/" + rel + (exts.isEmpty ? "" : ", " + exts.map { "." + $0 }.joined(separator: " "))
            case .underHomePaths(let rels, let exts):
                return "under " + rels.map { "~/" + $0 }.joined(separator: " or ")
                    + (exts.isEmpty ? "" : ", " + exts.map { "." + $0 }.joined(separator: " "))
            case .fileExtension(let exts): return exts.map { "." + $0 }.joined(separator: " ") + " file"
            case .directoryNamed(let names): return "named " + names.joined(separator: " ")
            case .appLeftovers: return "app data location"
            }
        }

        /// The rule claimed the node. Records a suggestion or a skip; returns whether to descend
        /// (only a protected skip is walked further, so home's contents are still reached).
        private mutating func claim(_ id: NodeID, rule: SuggestRule, marker: MarkerResult) -> Bool {
            let n = nodes[Int(id)]
            let path = path(of: id)
            func skip(_ why: SuggestSkipReason) -> SkippedCandidate {
                SkippedCandidate(node: id, path: path, ruleID: rule.id, why: why, status: n.status)
            }
            if isProtected(path, name: n.name) { skipped.append(skip(.protectedPath)); return true }
            if n.status == .unavailable { skipped.append(skip(.unreadable)); return false }
            let threshold = max(options.minBytes, rule.minBytes ?? 0)
            let bigEnough = n.totalAlloc >= threshold
            guard case .pass(let markerEvidence) = marker else {
                if bigEnough { skipped.append(skip(.markerUnknown)) }
                return false
            }

            let stats = subtreeStats(id)
            if stats.photosLibrary { skipped.append(skip(.protectedPath)); return true }
            guard bigEnough else { return false }
            if stats.git { skipped.append(skip(.containsGit)); return false }

            var evidence = [markerEvidence]
            var safety = rule.safety
            if !rule.confirmSiblings.isEmpty {
                let present = parentNames()
                let found = rule.confirmSiblings.filter { present.contains($0) }
                if found.isEmpty {
                    safety = .review
                    evidence.append("none of " + rule.confirmSiblings.joined(separator: ", ") + " beside it")
                } else if case .siblingAny = rule.marker {
                    evidence[0] += ", " + found.joined(separator: ", ")
                } else {
                    evidence.append("sibling " + found.joined(separator: ", "))
                }
            }
            if let days = rule.minAgeDays {
                let newest = max(stats.newestMod, stats.newestAccess)
                if newest == 0 { skipped.append(skip(.ageUnknown)); return false }
                guard newest < options.now - Int64(days) * 86_400 else { return false }
                // Access times are a lower bound (APFS updates them lazily): say what was recorded.
                evidence.append("no recorded use for \((options.now - newest) / 86_400) days")
            }
            if rule.id == "downloaded_zip" {
                if let holdsInstaller = options.archiveHoldsInstaller?(path) {
                    guard holdsInstaller else { return false }
                    evidence.append("holds an installer (.app/.pkg/.dmg/.xip)")
                }
            }
            if rule.id == "installers" || rule.id == "disk_images" {
                let origin = options.downloadOrigin?(path)
                let url = origin.flatMap { URLComponents(string: $0) }
                if let scheme = url?.scheme?.lowercased(), ["http", "https"].contains(scheme),
                   let host = url?.host, !host.isEmpty {
                    evidence.append("downloaded from \(scheme)://\(host)")
                    if rule.id == "installers" { safety = .redownloadable }
                } else if rule.id == "installers" {
                    safety = .review
                }
            }
            if stats.checkouts > 0 {
                evidence.append("contains \(stats.checkouts) package checkouts (git clones)")
            }
            var status = ScanStatus.complete
            if n.status == .partial {
                status = .partial
                safety = .review
                evidence.append("some folders inside could not be read")
            }
            suggestions.append(Suggestion(node: id, path: path, bytes: n.totalAlloc, status: status, category: rule.category,
                                          safety: safety, ruleID: rule.id, reason: rule.reason,
                                          evidence: evidence.joined(separator: "; "), newestModTime: stats.newestMod,
                                          sharedFiles: stats.shared))
            return false
        }

        /// One walk over a candidate: times, shared files, and the `.git` / photos library guards.
        private func subtreeStats(_ candidate: NodeID) -> SubtreeStats {
            var s = SubtreeStats()
            var stack = [candidate]
            // Fields are read in place: copying a whole Node retains and releases its name.
            nodes.withUnsafeBufferPointer { all in
                while let cur = stack.popLast() {
                    let i = Int(cur)
                    if all[i].isRemoved { continue }
                    s.newestMod = max(s.newestMod, all[i].modTime)
                    s.newestAccess = max(s.newestAccess, all[i].accessTime)
                    if cur != candidate {
                        if CleanupSuggester.isGit(all[i].name) {
                            if isPackageCheckoutGit(cur, in: candidate) { s.checkouts += 1; continue }
                            s.git = true
                            return
                        }
                        if CleanupSuggester.isPhotosLibrary(all[i].name) { s.photosLibrary = true; return }
                    }
                    if all[i].isDirectory {
                        var c = all[i].firstChild
                        while c >= 0 { stack.append(c); c = all[Int(c)].nextSibling }
                    } else if all[i].sharesStorage {
                        s.shared += 1
                    }
                }
            }
            return s
        }

        /// `.git` exactly at `<candidate>/checkouts/<name>/.git` or
        /// `<candidate>/SourcePackages/checkouts/<name>/.git`: an Xcode or SwiftPM package clone.
        private func isPackageCheckoutGit(_ git: NodeID, in candidate: NodeID) -> Bool {
            let clone = nodes[Int(git)].parent
            guard clone >= 0, clone != candidate else { return false }
            let checkouts = nodes[Int(clone)].parent
            guard checkouts >= 0, checkouts != candidate, nodes[Int(checkouts)].name == "checkouts" else { return false }
            let above = nodes[Int(checkouts)].parent
            if above == candidate { return true }
            guard above >= 0, nodes[Int(above)].name == "SourcePackages" else { return false }
            return nodes[Int(above)].parent == candidate
        }
    }
}
