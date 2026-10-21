import Darwin
import Foundation

public enum HiddenSpace {
    public enum State: String, Codable, Sendable { case measured, estimated, unknown }
    public enum Kind: String, Codable, Sendable { case volume, part, detail }

    public struct Line: Equatable, Sendable, Encodable {
        public var id: String
        public var label: String
        public var bytes: Int64?
        public var state: State
        public var kind: Kind
        public var count: Int?
        public var how: String

        private enum CodingKeys: String, CodingKey { case id, label, bytes, state, kind, count, how }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(label, forKey: .label)
            try container.encode(bytes, forKey: .bytes)
            try container.encode(state, forKey: .state)
            try container.encode(kind, forKey: .kind)
            try container.encode(count, forKey: .count)
            try container.encode(how, forKey: .how)
        }
    }

    public struct Report: Equatable, Sendable, Encodable {
        public var rootPath: String
        public var mountPoint: String?
        public var coversVolume: Bool
        public var lines: [Line]

        private enum CodingKeys: String, CodingKey { case rootPath = "root_path", mountPoint = "mount_point", coversVolume = "covers_volume", lines }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rootPath, forKey: .rootPath)
            try container.encode(mountPoint, forKey: .mountPoint)
            try container.encode(coversVolume, forKey: .coversVolume)
            try container.encode(lines, forKey: .lines)
        }
    }

    public struct ScanFacts: Equatable, Sendable {
        public var rootPath: String
        public var rootStatus: ScanStatus
        public var countedBytes: Int64
        public var unreadableFolders: Int

        public init(tree: FileTree) {
            self.init(rootPath: tree.rootPath, rootStatus: tree[FileTree.root].status,
                      countedBytes: tree[FileTree.root].totalAlloc,
                      unreadableFolders: HiddenSpace.unreadableFolderCount(tree))
        }

        public init(rootPath: String, rootStatus: ScanStatus, countedBytes: Int64, unreadableFolders: Int) {
            self.rootPath = rootPath
            self.rootStatus = rootStatus
            self.countedBytes = countedBytes
            self.unreadableFolders = unreadableFolders
        }
    }

    public struct VolumeFacts {
        public var mountPoint: String
        public var device: String
        public var fsType: String
        public var total: Int64
        public var available: Int64
    }

    public enum FileProbe {
        case bytes(Int64)
        case absent
        case failed(errno: Int32)
    }

    public struct Probes {
        var volume: (String) -> VolumeFacts?
        var mountedVolumes: () -> [VolumeFacts]
        var spaceUsed: (String) -> Int64?
        var importantAvailable: (String) -> Int64?
        var localSnapshots: (String) -> (stdout: String, exitCode: Int32)?
        var swapTotal: () -> Int64?
        var fileAllocated: (String) -> FileProbe
    }

    public static func parseLocalSnapshots(_ text: String) -> [String]? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first?.trimmingCharacters(in: .whitespaces),
              header.hasPrefix("Snapshots for disk "), header.hasSuffix(":"),
              header.count > "Snapshots for disk :".count else { return nil }
        let names = Array(lines.dropFirst())
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard names.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return names
    }

    public static func apfsContainer(ofDevice device: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "^/dev/(disk[0-9]+)s[0-9]+(?:s[0-9]+)?$"),
              let match = regex.firstMatch(in: device, range: NSRange(device.startIndex..., in: device)),
              let range = Range(match.range(at: 1), in: device) else { return nil }
        return String(device[range])
    }

    /// The APFS volume behind a device, with a snapshot suffix dropped: "/dev/disk3s1s1" and
    /// "/dev/disk3s1" are the same volume.
    public static func apfsVolume(ofDevice device: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "^/dev/(disk[0-9]+s[0-9]+)(?:s[0-9]+)?$"),
              let match = regex.firstMatch(in: device, range: NSRange(device.startIndex..., in: device)),
              let range = Range(match.range(at: 1), in: device) else { return nil }
        return String(device[range])
    }

    public static func unreadableFolderCount(_ tree: FileTree) -> Int {
        tree.nodes.reduce(into: 0) { count, node in
            if node.isDirectory && !node.isRemoved &&
                (node.status == .unavailable || node.flags.contains(.listingIncomplete)) { count += 1 }
        }
    }

    /// Blocking: the Time Machine probe may take up to ten seconds. Call off the main thread.
    public static func report(_ facts: ScanFacts, probes: Probes = .live) -> Report {
        let volume = probes.volume(facts.rootPath)
        let mount = volume?.mountPoint
        let resolved = realpath(facts.rootPath, nil)
        let covers = resolved.map { pointer in
            defer { free(pointer) }
            return String(cString: pointer) == mount
        } ?? false
        var lines: [Line] = []

        func append(_ id: String, _ label: String, _ bytes: Int64?, _ state: State, _ kind: Kind,
                    count: Int? = nil, how: String) {
            lines.append(Line(id: id, label: label, bytes: state == .unknown ? nil : bytes,
                              state: state, kind: kind, count: count, how: how))
        }

        let apfs = volume?.fsType == "apfs"
        let scope = apfs ? "APFS container (shared by all its volumes)" : "scan root volume"
        let total = volume?.total
        let available = volume?.available
        let used: Int64? = if let total, let available, total >= available {
            total - available
        } else { nil }
        append("capacity", "\(scope) capacity", total, total == nil ? .unknown : .measured, .volume,
               how: volume == nil ? "statfs failed for \(facts.rootPath)" : "statfs f_blocks × f_bsize; \(scope)")
        append("available", "\(scope) available", available, available == nil ? .unknown : .measured, .volume,
               how: volume == nil ? "statfs failed for \(facts.rootPath)" : "statfs f_bavail × f_bsize; \(scope)")
        append("used", "\(scope) used", used, used == nil ? .unknown : .measured, .volume,
               how: volume == nil ? "statfs failed for \(facts.rootPath)" : "statfs capacity − available; \(scope)")

        if volume == nil {
            append("scanned", "Scanned files", nil, .unknown, .part, how: "statfs failed; volume accounting unavailable")
            append("unreadable", "Unreadable folders", nil, .unknown, .part,
                   count: facts.unreadableFolders,
                   how: "statfs failed; FileTree found \(facts.unreadableFolders) unreadable folders")
            append("unexplained", "Unexplained used space", nil, .unknown, .part,
                   how: "statfs failed; unmounted volumes (including Recovery) and container metadata land here")
            append("purgeable", "Purgeable space", nil, .unknown, .detail,
                   how: "statfs failed; no available-space baseline")
            return Report(rootPath: facts.rootPath, mountPoint: nil, coversVolume: false, lines: lines)
        }

        let scanned: Int64? = facts.rootStatus == .unavailable ? nil : facts.countedBytes
        let scannedState: State = facts.rootStatus == .unavailable ? .unknown :
            (facts.rootStatus == .partial ? .estimated : .measured)
        append("scanned", "Scanned files", scanned, scannedState, .part,
               how: facts.rootStatus == .unavailable ? "scan root could not be read" :
                   "FileTree root totalAlloc after dedup\(facts.rootStatus == .partial ? "; lower bound" : "")")

        let mounted = apfs ? probes.mountedVolumes() : []
        var vmMounted = false
        if apfs, let volume {
            let container = apfsContainer(ofDevice: volume.device)
            let sameContainer = mounted.filter { $0.fsType == "apfs" &&
                container != nil && apfsContainer(ofDevice: $0.device) == container }
            let vm = sameContainer.first { $0.mountPoint == "/System/Volumes/VM" && $0.mountPoint != mount }
            if let vm {
                vmMounted = true
                let bytes = probes.spaceUsed(vm.mountPoint).flatMap { $0 >= 0 ? $0 : nil }
                append("vm_volume", "VM volume", bytes, bytes == nil ? .unknown : .measured, .part,
                       how: "getattrlist ATTR_VOL_SPACEUSED at \(vm.mountPoint); swap detail uses vm.swapusage xsu_total")
            }
            // One volume can be mounted twice (the sealed system volume as a snapshot at / and again
            // during an update): count each volume once, and never the scanned one.
            var seen = Set([volume.device, vm?.device].compactMap { $0 }.map { apfsVolume(ofDevice: $0) ?? $0 })
            let others = sameContainer.filter { $0.mountPoint != mount && $0.mountPoint != vm?.mountPoint }
                .filter { seen.insert(apfsVolume(ofDevice: $0.device) ?? $0.device).inserted }
            var otherTotal: Int64 = 0
            var details: [String] = []
            var missing = mounted.isEmpty || container == nil
            for other in others {
                if let bytes = probes.spaceUsed(other.mountPoint), bytes >= 0,
                   otherTotal <= Int64.max - bytes {
                    otherTotal += bytes
                    details.append("\(other.mountPoint): \(bytes) bytes")
                } else {
                    missing = true
                    details.append("\(other.mountPoint): unknown")
                }
            }
            append("other_volumes", "Other mounted APFS volumes", missing ? nil : otherTotal,
                   missing ? .unknown : .measured, .part,
                   how: "getmntinfo(MNT_NOWAIT) + getattrlist ATTR_VOL_SPACEUSED; " +
                        (details.isEmpty ? (missing ? "mount list or APFS container unavailable" : "no other mounted volumes") : details.joined(separator: ", ")))

            let snapshotProbe = probes.localSnapshots(volume.mountPoint)
            let names = snapshotProbe.flatMap { $0.exitCode == 0 ? parseLocalSnapshots($0.stdout) : nil }
            let snapshotCount = names?.count
            append("snapshots", "Time Machine snapshots only", snapshotCount == 0 ? 0 : nil,
                   snapshotCount == 0 ? .measured : .unknown, .part, count: snapshotCount,
                   how: snapshotCount == nil ? "tmutil listlocalsnapshots \(volume.mountPoint) failed or output unrecognized; Time Machine snapshots only" :
                       snapshotCount == 0 ? "tmutil listlocalsnapshots \(volume.mountPoint); Time Machine snapshots only" :
                       "tmutil listlocalsnapshots \(volume.mountPoint) reports no sizes; Time Machine snapshots only")
        }

        // No usable scan (cancelled, or the root could not be read): the count is not known, not zero.
        if facts.rootStatus == .unavailable {
            append("unreadable", "Unreadable folders", nil, .unknown, .part,
                   how: "the scan of \(facts.rootPath) did not complete, so unreadable folders are not known")
        } else {
            let unreadableCount = facts.unreadableFolders
            append("unreadable", "Unreadable folders", unreadableCount == 0 ? 0 : nil,
                   unreadableCount == 0 ? .measured : .unknown, .part, count: unreadableCount,
                   how: "FileTree unavailable or listingIncomplete directories; \(unreadableCount) folders")
        }

        let parts = lines.filter { $0.kind == .part }
        var knownSum: Int64 = 0
        var sumOverflow = false
        for bytes in parts.compactMap(\.bytes) {
            let (sum, overflow) = knownSum.addingReportingOverflow(bytes)
            if overflow { sumOverflow = true; break }
            knownSum = sum
        }
        let residual = used.map { $0.subtractingReportingOverflow(knownSum) }
        let negative = sumOverflow || (residual.map { $0.overflow || $0.partialValue < 0 } ?? false)
        let unexplainedUnknown = used == nil || scanned == nil || !covers || negative
        let uncertain = parts.filter { $0.state != .measured }
        let reason: String
        if used == nil { reason = "volume usage unavailable" }
        else if scanned == nil { reason = "scan root could not be read" }
        else if !covers { reason = "scan covers only \(facts.rootPath), not \(mount ?? "the volume mount")" }
        else if negative { reason = "scan counted more than the volume reports" }
        else if uncertain.isEmpty { reason = "all counted parts measured" }
        else {
            reason = "includes " + uncertain.map { line in
                switch line.id {
                case "snapshots": return "snapshots" + line.count.map { " (\($0))" }.orEmpty
                case "unreadable": return "unreadable folders" + line.count.map { " (\($0))" }.orEmpty
                default: return line.id + (line.state == .estimated ? " (estimated)" : " (unknown)")
                }
            }.joined(separator: ", ")
        }
        let unexplainedState: State = unexplainedUnknown ? .unknown : (uncertain.isEmpty ? .measured : .estimated)
        append("unexplained", "Unexplained used space", unexplainedUnknown ? nil : residual?.partialValue,
               unexplainedState, .part,
               how: "used − known part bytes; \(reason); unmounted volumes (including Recovery) and container metadata land here")

        let important = probes.importantAvailable(facts.rootPath)
        let purgeable: Int64? = if let important, let available, important >= available {
            important - available
        } else { nil }
        append("purgeable", "Purgeable space", purgeable, purgeable == nil ? .unknown : .estimated, .detail,
               how: purgeable == nil ? "volumeAvailableCapacityForImportantUsage unavailable or below statfs available" :
                   "volumeAvailableCapacityForImportantUsage − statfs available; estimate")

        if vmMounted {
            let swap = probes.swapTotal()
            append("swap", "Swap allocation", swap, swap == nil ? .unknown : .measured, .detail,
                   how: "sysctlbyname vm.swapusage xsw_usage.xsu_total; inside VM volume")
            let paths = ["/System/Volumes/VM/sleepimage", "/private/var/vm/sleepimage"]
            var sleep: Int64? = 0
            var sleepHow = "lstat st_blocks × 512; neither sleepimage path exists"
            for path in paths {
                switch probes.fileAllocated(path) {
                case .bytes(let bytes): sleep = bytes; sleepHow = "lstat st_blocks × 512 at \(path)"; break
                case .absent: continue
                case .failed(let code): sleep = nil; sleepHow = "lstat \(path) failed (errno \(code))"; break
                }
                break
            }
            append("sleep_image", "Sleep image", sleep, sleep == nil ? .unknown : .measured, .detail, how: sleepHow)
        }
        return Report(rootPath: facts.rootPath, mountPoint: mount, coversVolume: covers, lines: lines)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
