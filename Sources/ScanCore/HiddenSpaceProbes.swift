import Darwin
import Foundation

private final class SnapshotOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    func store(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    func load() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
}

extension HiddenSpace.Probes {
    public static let live = HiddenSpace.Probes(
        volume: HiddenSpace.liveVolume,
        mountedVolumes: HiddenSpace.liveMountedVolumes,
        spaceUsed: HiddenSpace.liveSpaceUsed,
        importantAvailable: HiddenSpace.liveImportantAvailable,
        localSnapshots: HiddenSpace.liveLocalSnapshots,
        swapTotal: HiddenSpace.liveSwapTotal,
        fileAllocated: HiddenSpace.liveFileAllocated
    )
}

private extension HiddenSpace {
    static func liveVolume(_ path: String) -> VolumeFacts? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return volumeFacts(fs)
    }

    static func volumeFacts(_ fs: statfs) -> VolumeFacts {
        var fs = fs
        return withUnsafePointer(to: &fs.f_mntonname) { mount in
            withUnsafePointer(to: &fs.f_mntfromname) { device in
                withUnsafePointer(to: &fs.f_fstypename) { type in
                    VolumeFacts(mountPoint: mount.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) },
                                device: device.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) },
                                fsType: type.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) },
                                total: Int64(fs.f_blocks) * Int64(fs.f_bsize),
                                available: Int64(fs.f_bavail) * Int64(fs.f_bsize))
                }
            }
        }
    }

    static func liveMountedVolumes() -> [VolumeFacts] {
        var pointer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&pointer, MNT_NOWAIT)
        guard count > 0, let pointer else { return [] }
        return (0..<Int(count)).map { volumeFacts(pointer[$0]) }
    }

    static func liveSpaceUsed(_ mountPoint: String) -> Int64? {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attrs.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        // The returned bitmap decides whether the value was supplied. The offset follows the
        // kernel's fixed-field packing: length, returned attribute_set_t, then one uint64.
        let valueOffset = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
        let capacity = valueOffset + MemoryLayout<UInt64>.size
        var buffer = [UInt8](repeating: 0, count: capacity)
        guard getattrlist(mountPoint, &attrs, &buffer, buffer.count, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let length = raw.loadUnaligned(as: UInt32.self)
            guard length >= capacity else { return nil }
            let returned = raw.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: attribute_set_t.self)
            guard returned.volattr & attrgroup_t(ATTR_VOL_SPACEUSED) != 0 else { return nil }
            let used = raw.loadUnaligned(fromByteOffset: valueOffset, as: UInt64.self)
            return Int64(exactly: used)
        }
    }

    static func liveImportantAvailable(_ path: String) -> Int64? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let amount = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int64(amount)
    }

    static func liveLocalSnapshots(_ mountPoint: String) -> (stdout: String, exitCode: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", mountPoint]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        output.fileHandleForWriting.closeFile()
        let captured = SnapshotOutput()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            captured.store(output.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }
        let deadline = DispatchTime.now() + 10
        guard finished.wait(timeout: deadline) == .success else {
            if process.isRunning { process.terminate() }
            return nil
        }
        guard drained.wait(timeout: deadline) == .success, let data = captured.load() else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, process.terminationStatus)
    }

    static func liveSwapTotal() -> Int64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0,
              size >= MemoryLayout<xsw_usage>.size else { return nil }
        return Int64(exactly: usage.xsu_total)
    }

    static func liveFileAllocated(_ path: String) -> FileProbe {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? .absent : .failed(errno: errno)
        }
        let (bytes, overflow) = Int64(info.st_blocks).multipliedReportingOverflow(by: 512)
        return overflow ? .failed(errno: EOVERFLOW) : .bytes(bytes)
    }
}
