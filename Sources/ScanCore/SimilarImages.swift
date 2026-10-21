import Accelerate
import Darwin
import Foundation
import ImageIO
import Vision

public struct SimilarOptions: Sendable {
    public var minSize: Int64
    /// Euclidean feature-print distance. Smaller means more similar.
    public var threshold: Float
    public var maxConcurrency: Int
    public var revision: Int

    public init(minSize: Int64 = 100_000, threshold: Float = 0.45,
                maxConcurrency: Int = min(8, ProcessInfo.processInfo.activeProcessorCount),
                revision: Int = VNGenerateImageFeaturePrintRequest.defaultRevision) {
        self.minSize = minSize
        self.threshold = threshold
        self.maxConcurrency = maxConcurrency
        self.revision = revision
    }
}

public struct SimilarFeature {
    public var vector: [Float]
    public var width: Int?
    public var height: Int?
    public init(vector: [Float], width: Int? = nil, height: Int? = nil) {
        self.vector = vector; self.width = width; self.height = height
    }
}

public struct SimilarMember: Sendable {
    public var path: String
    public var node: NodeID
    public var aliases: [String]
    public var width: Int?
    public var height: Int?
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var sharedStorage: Bool
}

public struct SimilarGroup: Sendable {
    public var members: [SimilarMember]
    public var suggestedKeep: NodeID
    public var reclaimableBytes: Int64
    /// A cancelled comparison can leave additional pairs unexamined.
    public var partial: Bool
}

public struct SimilarSkip: Sendable {
    public var path: String
    public var reason: String
    public var detail: String
}

public enum SimilarStatus: String, Sendable { case complete, partial, cancelled }

public struct SimilarProgress: Sendable {
    public var filesDone: Int
    public var filesTotal: Int
}

public struct SimilarReport: Sendable {
    public var groups: [SimilarGroup]
    public var skipped: [SimilarSkip]
    public var status: SimilarStatus
    public var treeStatus: ScanStatus
    public var revision: Int
    public var candidateFiles: Int
    public var processedFiles: Int
    public var pendingFiles: Int
    public var imagesPerSecond: Double
    /// Estimated allocated bytes from completed groups; cancelled groups are excluded.
    public var reclaimableBytes: Int64 {
        groups.filter { !$0.partial }.reduce(0) { $0 + $1.reclaimableBytes }
    }
}

public enum SimilarImages {
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "dng", "cr2", "cr3", "nef", "arw"]

    private struct Key: Hashable { let device: Int32; let id: UInt64; let clone: Bool }
    private struct Unit {
        let node: NodeID
        let path: String
        var aliases: [String]
        let snapshot: Node
        let shared: Bool
    }
    private struct Result { let unit: Unit; let feature: SimilarFeature }
    private struct CacheKey: Hashable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let revision: Int
    }
    private final class FeatureCache: @unchecked Sendable {
        private let lock = NSLock()
        private var features: [CacheKey: SimilarFeature] = [:]
        func get(_ key: CacheKey) -> SimilarFeature? {
            lock.lock(); defer { lock.unlock() }
            return features[key]
        }
        func put(_ feature: SimilarFeature, for key: CacheKey) {
            lock.lock(); defer { lock.unlock() }
            if features.count >= 20_000 { features.removeAll(keepingCapacity: true) }
            features[key] = feature
        }
    }
    private static let cache = FeatureCache()
    private final class Work: @unchecked Sendable {
        let lock = NSLock()
        var next = 0
        var results: [Result] = []
        var skips: [SimilarSkip] = []
        var cancelled = false
        var policyFailed = false
    }

    /// Candidate selection reads only the value snapshot; it does not inspect image contents.
    public static func candidates(in nodes: [Node], rootPath: String, under root: NodeID = FileTree.root,
                                  minSize: Int64 = 100_000) -> (paths: [String], skipped: [SimilarSkip]) {
        let selected = select(in: nodes, rootPath: rootPath, under: root, minSize: minSize)
        return (selected.units.map(\.path), selected.skips)
    }

    public static func find(in nodes: [Node], rootPath: String, under root: NodeID = FileTree.root,
                            options: SimilarOptions = SimilarOptions(), isCancelled: @escaping () -> Bool = { false },
                            progress: @escaping (SimilarProgress) -> Void = { _ in }) -> SimilarReport {
        find(in: nodes, rootPath: rootPath, under: root, options: options, isCancelled: isCancelled,
             progress: progress, extract: extract, cacheEnabled: true, materializationOff: noMaterialize)
    }

    static func noMaterialize() -> (() -> Void)? { Materialization.offForThread("similar") }

    /// Injectable extractor allows tests to prove that excluded paths are never opened.
    static func find(in nodes: [Node], rootPath: String, under root: NodeID = FileTree.root,
                     options: SimilarOptions = SimilarOptions(), isCancelled: @escaping () -> Bool = { false },
                     progress: @escaping (SimilarProgress) -> Void = { _ in },
                     extract: @escaping (String, Int) throws -> SimilarFeature,
                     cacheEnabled: Bool = false,
                     materializationOff: @escaping () -> (() -> Void)? = noMaterialize) -> SimilarReport {
        let selected = select(in: nodes, rootPath: rootPath, under: root, minSize: options.minSize)
        let units = selected.units
        let treeStatus: ScanStatus = root >= 0 && Int(root) < nodes.count ? nodes[Int(root)].status : .unavailable
        let started = ProcessInfo.processInfo.systemUptime
        let work = Work()
        progress(SimilarProgress(filesDone: 0, filesTotal: units.count))
        let workers = min(max(1, options.maxConcurrency), 8, max(1, units.count))
        let done = DispatchGroup()
        for _ in 0..<workers {
            done.enter()
            Thread.detachNewThread {
                defer { done.leave() }
                // Vision and ImageIO read on this thread: without the policy a file evicted to iCloud
                // after the check below would be downloaded, so this worker reads nothing at all.
                guard let restore = materializationOff() else {
                    work.lock.lock(); work.policyFailed = true; work.lock.unlock()
                    return
                }
                defer { restore() }
                while true {
                    work.lock.lock()
                    if isCancelled() { work.cancelled = true }
                    guard !work.cancelled && work.next < units.count else { work.lock.unlock(); break }
                    let index = work.next
                    work.next += 1
                    work.lock.unlock()
                    let unit = units[index]
                    let outcome: Result?
                    var skip: SimilarSkip?
                    if !unchanged(unit.snapshot, at: unit.path) {
                        outcome = nil
                        skip = SimilarSkip(path: unit.path, reason: "changed", detail: "file identity changed since scan")
                    } else {
                        do {
                            let before = cacheKey(unit.snapshot, at: unit.path, revision: options.revision)
                            let cached = cacheEnabled ? before.flatMap { cache.get($0) } : nil
                            let feature = try cached ?? extract(unit.path, options.revision)
                            let after = cacheKey(unit.snapshot, at: unit.path, revision: options.revision)
                            if before != nil, before == after, feature.vector.count > 0,
                               feature.vector.allSatisfy(\.isFinite) {
                                outcome = Result(unit: unit, feature: feature)
                                if cacheEnabled, cached == nil, let before { cache.put(feature, for: before) }
                            } else {
                                outcome = nil
                                skip = SimilarSkip(path: unit.path, reason: "changed", detail: "file changed during extraction or invalid print")
                            }
                        } catch {
                            outcome = nil
                            skip = SimilarSkip(path: unit.path, reason: "unreadable", detail: String(describing: error))
                        }
                    }
                    work.lock.lock()
                    if let outcome { work.results.append(outcome) }
                    if let skip { work.skips.append(skip) }
                    let count = work.results.count + work.skips.count
                    work.lock.unlock()
                    progress(SimilarProgress(filesDone: count, filesTotal: units.count))
                }
            }
        }
        // Ask on this thread too: a closure like `Task.isCancelled` only answers on the caller's own
        // thread, never on the worker threads above.
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if isCancelled() { work.lock.lock(); work.cancelled = true; work.lock.unlock() }
        }
        if work.policyFailed && !work.cancelled {
            for unit in units[work.next...] {
                work.skips.append(SimilarSkip(path: unit.path, reason: "not_local",
                                              detail: Materialization.refusedDetail))
            }
        }
        let results = work.results.sorted { $0.unit.path < $1.unit.path }
        let elapsed = max(0.000_001, ProcessInfo.processInfo.systemUptime - started)
        var skips = selected.skips + work.skips
        var status: SimilarStatus = work.cancelled || isCancelled() ? .cancelled : .complete
        if status == .complete && (!skips.isEmpty || treeStatus != .complete) { status = .partial }
        // Dimension mismatch is a failed extraction, never a zero distance.
        // The length most prints have: one odd print (another revision from a cache) must not make
        // every other file the odd one out.
        var lengths: [Int: Int] = [:]
        for result in results { lengths[result.feature.vector.count, default: 0] += 1 }
        let dimension = lengths.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? 0
        let usable = results.filter { result in
            if result.feature.vector.count != dimension {
                skips.append(SimilarSkip(path: result.unit.path, reason: "unreadable", detail: "feature-print dimensions differ"))
                return false
            }
            return true
        }
        if !skips.isEmpty && status == .complete { status = .partial }
        // Best first, by the rule that picks the image to keep: most pixels, then largest file, then newest.
        let order = usable.indices.sorted { x, y in
            let a = usable[x], b = usable[y]
            let pa = Int64(a.feature.width ?? 0) * Int64(a.feature.height ?? 0)
            let pb = Int64(b.feature.width ?? 0) * Int64(b.feature.height ?? 0)
            if pa != pb { return pa > pb }
            if a.unit.snapshot.logicalSize != b.unit.snapshot.logicalSize { return a.unit.snapshot.logicalSize > b.unit.snapshot.logicalSize }
            if a.unit.snapshot.modTime != b.unit.snapshot.modTime { return a.unit.snapshot.modTime > b.unit.snapshot.modTime }
            return x < y
        }
        // A run cancelled while extracting still groups what it read (a cancelled report keeps its
        // partial groups); a cancel that arrives during grouping stops it between batches.
        let alreadyCancelled = status == .cancelled
        let (components, groupingCancelled) = leaderGroups(usable.map { $0.feature.vector }, threshold: options.threshold,
                                                           order: order, isCancelled: { !alreadyCancelled && isCancelled() })
        if groupingCancelled { status = .cancelled }
        var groups: [SimilarGroup] = components.map { component in
            let members: [SimilarMember] = component.map { index in
                let result = usable[index], n = result.unit.snapshot
                return SimilarMember(path: result.unit.path, node: result.unit.node, aliases: result.unit.aliases,
                                     width: result.feature.width, height: result.feature.height,
                                     logicalBytes: n.logicalSize, allocatedBytes: n.rawAlloc,
                                     sharedStorage: result.unit.shared)
            }
            let keep = members[0].node  // the leader: every other member is within the threshold of it
            let reclaimable = members.filter { $0.node != keep && !$0.sharedStorage }
                .reduce(Int64(0)) { $0 + $1.allocatedBytes }
            return SimilarGroup(members: members, suggestedKeep: keep, reclaimableBytes: reclaimable,
                                partial: status == .cancelled)
        }
        groups.sort { $0.reclaimableBytes > $1.reclaimableBytes }
        return SimilarReport(groups: groups, skipped: skips.sorted { $0.path < $1.path }, status: status,
                             treeStatus: treeStatus, revision: options.revision, candidateFiles: units.count,
                             processedFiles: work.results.count + work.skips.count,
                             pendingFiles: units.count - work.results.count - work.skips.count,
                             imagesPerSecond: Double(work.results.count) / elapsed)
    }

    /// Never looked inside: a file in a package belongs to it (see `Packages`), and what is in the
    /// Trash is already being thrown away.
    private static let skippedFolders: Set<String> = [".Trash", ".Trashes", ".DocumentRevisions-V100", ".Spotlight-V100",
                                                      ".fseventsd", ".MobileBackups", ".TemporaryItems"]

    private static func select(in nodes: [Node], rootPath: String, under root: NodeID,
                               minSize: Int64) -> (units: [Unit], skips: [SimilarSkip]) {
        guard root >= 0, Int(root) < nodes.count, !nodes[Int(root)].isRemoved else { return ([], []) }
        // A scope that is a package, or lies inside one or in a Trash, has nothing to offer.
        let scopePath = path(root, nodes, rootPath)
        if Packages.enclosing(scopePath + "/x") != nil
            || scopePath.split(separator: "/").contains(where: { skippedFolders.contains(String($0)) }) { return ([], []) }
        var ids: [NodeID] = [], stack = [root], budget = nodes.count
        while budget > 0, let id = stack.popLast() {
            budget -= 1
            guard id >= 0, Int(id) < nodes.count else { continue }
            let n = nodes[Int(id)]
            if n.isRemoved { continue }
            if n.isDirectory {
                if id != root && (skippedFolders.contains(n.name) || Packages.isPackage(name: n.name)) { continue }
                var child = n.firstChild, siblings = nodes.count
                while child >= 0 && Int(child) < nodes.count && siblings > 0 {
                    stack.append(child); child = nodes[Int(child)].nextSibling; siblings -= 1
                }
            } else if !n.flags.contains(.symlink) && n.logicalSize >= max(1, minSize),
                      extensions.contains((n.name as NSString).pathExtension.lowercased()) {
                ids.append(id)
            }
        }
        var keyed: [Key: Int] = [:], units: [Unit] = [], skips: [SimilarSkip] = []
        for id in ids.sorted(by: { path($0, nodes, rootPath) < path($1, nodes, rootPath) }) {
            let n = nodes[Int(id)], p = path(id, nodes, rootPath)
            if n.rawAlloc <= 0 {
                skips.append(SimilarSkip(path: p, reason: "not_local", detail: "no local data blocks; reading may download it"))
                continue
            }
            let key: Key? = n.cloneID != 0 && n.flags.contains(.cloneShared)
                ? Key(device: n.device, id: n.cloneID, clone: true)
                : n.fileID != 0 ? Key(device: n.device, id: n.fileID, clone: false) : nil
            if let key, let index = keyed[key] {
                units[index].aliases.append(p)
            } else {
                if let key { keyed[key] = units.count }
                units.append(Unit(node: id, path: p, aliases: [], snapshot: n,
                                  shared: n.linkCount > 1 || n.flags.contains(.cloneShared) || n.flags.contains(.duplicate)))
            }
        }
        return (units, skips)
    }

    private static func path(_ id: NodeID, _ nodes: [Node], _ rootPath: String) -> String {
        var parts: [String] = [], current = id, budget = nodes.count
        while current != FileTree.root && current >= 0 && Int(current) < nodes.count && budget > 0 {
            parts.append(nodes[Int(current)].name)
            current = nodes[Int(current)].parent
            budget -= 1
        }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return base + "/" + parts.reversed().joined(separator: "/")
    }

    private static func unchanged(_ node: Node, at path: String) -> Bool {
        var s = stat()
        guard lstat(path, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG else { return false }
        return s.st_dev == node.device && UInt64(s.st_ino) == node.fileID &&
            s.st_size == node.logicalSize && s.st_mtimespec.tv_sec == node.modTime && s.st_blocks > 0
    }

    private static func cacheKey(_ node: Node, at path: String, revision: Int) -> CacheKey? {
        var s = stat()
        guard lstat(path, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG,
              s.st_dev == node.device, UInt64(s.st_ino) == node.fileID,
              s.st_size == node.logicalSize, s.st_mtimespec.tv_sec == node.modTime,
              s.st_blocks > 0 else { return nil }
        return CacheKey(path: path, device: s.st_dev, inode: UInt64(s.st_ino), size: s.st_size,
                        modifiedSeconds: Int64(s.st_mtimespec.tv_sec),
                        modifiedNanoseconds: Int64(s.st_mtimespec.tv_nsec), revision: revision)
    }

    static func extract(_ path: String, revision: Int) throws -> SimilarFeature {
        let url = URL(fileURLWithPath: path)
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = revision
        try VNImageRequestHandler(url: url).perform([request])
        guard let observation = request.results?.first else { throw NSError(domain: "HoardSimilar", code: 1) }
        let vector = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var width: Int?, height: Int?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = properties[kCGImagePropertyPixelWidth] as? Int
            height = properties[kCGImagePropertyPixelHeight] as? Int
        }
        return SimilarFeature(vector: vector, width: width, height: height)
    }

    /// Normalize for SGEMM, then restore the original magnitudes for Euclidean distance.
    /// This preserves Vision's computeDistance ordering while keeping dot products bounded.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        let na = sqrt(a.reduce(Float(0)) { $0 + $1 * $1 })
        let nb = sqrt(b.reduce(Float(0)) { $0 + $1 * $1 })
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return sqrt(max(0, na * na + nb * nb - 2 * dot))
    }

    static func groups(_ vectors: [[Float]], threshold: Float, order: [Int]? = nil) -> [[Int]] {
        leaderGroups(vectors, threshold: threshold, order: order).groups
    }

    /// Groups by leaders, not by chains: images are visited in `order` (best first; index order when
    /// nil), and each one not yet in a group leads a group of every other ungrouped image within
    /// `threshold` of it. So every member is similar to the leader, the image a group suggests
    /// keeping. Single linkage would join A and C through B even when A and C look nothing alike
    /// (on a folder of video frames it made one group of 2,338 images).
    ///
    /// Leaders go 128 at a time through one SGEMM against every image: memory stays at 128 rows of
    /// dot products however dense the set is, and cancellation is checked between batches.
    static func leaderGroups(_ vectors: [[Float]], threshold: Float, order: [Int]? = nil,
                             isCancelled: () -> Bool = { false }) -> (groups: [[Int]], cancelled: Bool) {
        let n = vectors.count
        guard n > 1, let dimension = vectors.first?.count, dimension > 0 else { return ([], false) }
        var norms = [Float](repeating: 0, count: n)
        var flat = [Float](repeating: 0, count: n * dimension)
        for (i, vector) in vectors.enumerated() {
            let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
            norms[i] = norm
            if norm > 0 { for k in 0..<dimension { flat[i * dimension + k] = vector[k] / norm } }
        }
        let visit = order ?? Array(0..<n)
        let batch = 128
        var grouped = [Bool](repeating: false, count: n)
        var leaders: [Int] = []
        var rows = [Float](repeating: 0, count: batch * dimension)
        var dots = [Float](repeating: 0, count: batch * n)
        var result: [[Int]] = []
        var position = 0
        let limit = threshold * threshold
        while position < visit.count {
            if isCancelled() { return (result, true) }
            leaders.removeAll(keepingCapacity: true)
            while position < visit.count && leaders.count < batch {
                if !grouped[visit[position]] { leaders.append(visit[position]) }
                position += 1
            }
            if leaders.isEmpty { break }
            for (r, leader) in leaders.enumerated() {
                for k in 0..<dimension { rows[r * dimension + k] = flat[leader * dimension + k] }
            }
            rows.withUnsafeBufferPointer { a in
                flat.withUnsafeBufferPointer { b in
                    dots.withUnsafeMutableBufferPointer { c in
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(leaders.count), Int32(n), Int32(dimension),
                                    1, a.baseAddress!, Int32(dimension), b.baseAddress!, Int32(dimension), 0,
                                    c.baseAddress!, Int32(n))
                    }
                }
            }
            for (r, leader) in leaders.enumerated() where !grouped[leader] {
                grouped[leader] = true
                var group = [leader]
                for j in 0..<n where !grouped[j] {
                    let squared = norms[leader] * norms[leader] + norms[j] * norms[j] - 2 * norms[leader] * norms[j] * dots[r * n + j]
                    if max(0, squared) <= limit {
                        grouped[j] = true
                        group.append(j)
                    }
                }
                if group.count > 1 { result.append(group) }
            }
        }
        return (result, false)
    }
}
