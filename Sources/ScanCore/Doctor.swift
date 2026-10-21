import CoreServices
import Darwin
import Foundation

public struct DoctorCheck {
    public enum Status: String { case ok, unknown, problem }
    public let id: String
    public let title: String
    public let status: Status
    public let detail: String
    public let affects: String

    init(_ id: String, _ title: String, _ status: Status, _ detail: String, _ affects: String) {
        self.id = id; self.title = title; self.status = status; self.detail = detail; self.affects = affects
    }
}

public struct DoctorReport {
    public let osVersion: String
    public let verifiedOn = "macOS 27"
    public let untested: Bool
    public let checks: [DoctorCheck]
    public var ok: Int { checks.filter { $0.status == .ok }.count }
    public var unknown: Int { checks.filter { $0.status == .unknown }.count }
    public var problem: Int { checks.filter { $0.status == .problem }.count }
}

public enum Doctor {
    private static let fm = FileManager.default

    public static func run(temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> DoctorReport {
        DoctorReport(osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                     untested: ProcessInfo.processInfo.operatingSystemVersion.majorVersion != 27,
                     checks: [materialization(), firmlink(), bulkRead(temporaryDirectory: temporaryDirectory),
                              fsevents(temporaryDirectory: temporaryDirectory),
                              denyDeleteACL(temporaryDirectory: temporaryDirectory),
                              clonefile(temporaryDirectory: temporaryDirectory), libraryLayout(),
                              processList(), homebrewReceipt()])
    }

    public static func materialization(reader: String = "doctor") -> DoctorCheck {
        let id = "materialization", title = "iCloud 自動下載", affects = "不下載保證"
        guard let restore = Materialization.offForThread(reader) else {
            return .init(id, title, .problem, "關不掉 iCloud 自動下載：所有讀檔功能會改成不讀", affects)
        }
        restore()
        return .init(id, title, .ok, "執行緒可關閉並還原自動下載", affects)
    }

    public static func firmlink(users: String = "/Users", dataUsers: String = "/System/Volumes/Data/Users") -> DoctorCheck {
        let id = "firmlink", title = "Users 路徑連結", affects = "保護比對、路徑換算"
        var first = stat(), second = stat()
        if stat(users, &first) != 0 {
            let code = errno
            return .init(id, title, code == EACCES || code == EPERM ? .unknown : .problem,
                         "無法檢查 \(users)：errno \(code)", affects)
        }
        if stat(dataUsers, &second) != 0 {
            let code = errno
            return .init(id, title, code == EACCES || code == EPERM ? .unknown : .problem,
                         code == ENOENT ? "Data 的 Users 路徑不存在" : "無法檢查 \(dataUsers)：errno \(code)", affects)
        }
        let same = first.st_dev == second.st_dev && first.st_ino == second.st_ino
        let mapping = PathForms.systemPath("/System/Volumes/Data/Users/x") == "/Users/x"
        return .init(id, title, same && mapping ? .ok : .problem,
                     same && mapping ? "兩個 Users 路徑指向同一資料夾，路徑換算正確" : "Users firmlink 或路徑換算不一致", affects)
    }

    public static func bulkRead(temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> DoctorCheck {
        withScratch("bulk-read", "批次目錄讀取", "掃描", in: temporaryDirectory) { root in
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            try Data([1]).write(to: a); try Data([2]).write(to: b)
            do {
                let entries = try Scanner().listDirectory(root.path)
                let found = entries.filter { ["a", "b"].contains($0.name) && $0.fileID != 0 }
                return .init("bulk-read", "批次目錄讀取", found.count == 2 ? .ok : .problem,
                             found.count == 2 ? "兩個檔案及 fileID 均可讀取" : "檔案或 fileID 遺漏", "掃描")
            } catch {
                return .init("bulk-read", "批次目錄讀取", .problem, "目錄讀取失敗：\(error)", "掃描")
            }
        }
    }

    private final class EventBox {
        let root: String
        let realRoot: String
        let signal = DispatchSemaphore(value: 0)
        init(_ root: String) {
            self.root = root
            if let resolved = realpath(root, nil) {
                realRoot = String(cString: resolved)
                free(resolved)
            } else { realRoot = root }
        }
    }

    public static func fsevents(temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> DoctorCheck {
        withScratch("fsevents", "檔案系統事件", "自動更新、守護", in: temporaryDirectory) { root in
            let box = EventBox(root.path)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
                                               kFSEventStreamCreateFlagNoDefer |
                                               kFSEventStreamCreateFlagWatchRoot)
            guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, _, _ in
                guard let info else { return }
                let box = Unmanaged<EventBox>.fromOpaque(info).takeUnretainedValue()
                let values = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
                for i in 0..<count {
                    let path = unsafeBitCast(CFArrayGetValueAtIndex(values, i), to: CFString.self) as String
                    if path == box.root || path.hasPrefix(box.root + "/") ||
                       path == box.realRoot || path.hasPrefix(box.realRoot + "/") {
                        box.signal.signal(); return
                    }
                }
            }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else {
                let code = errno
                return .init("fsevents", "檔案系統事件", .unknown,
                             "FSEventStreamCreate 回傳 nil（\(eventError(code))）", "自動更新、守護")
            }
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "Hoard.Doctor.FSEvents"))
            guard FSEventStreamStart(stream) else {
                let code = errno
                FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
                return .init("fsevents", "檔案系統事件", .unknown,
                             "FSEventStreamStart 回傳 false（\(eventError(code))）", "自動更新、守護")
            }
            defer { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
            try Data([1]).write(to: root.appendingPathComponent("changed"))
            let received = box.signal.wait(timeout: .now() + 5) == .success
            return .init("fsevents", "檔案系統事件", received ? .ok : .problem,
                         received ? "五秒內收到測試資料夾事件" : "五秒內未收到事件", "自動更新、守護")
        }
    }

    private static func eventError(_ code: Int32) -> String {
        code == 0 ? "系統未提供 errno" : "errno \(code)"
    }

    /// Locks a temp folder and the file in it with the lock's own ACL code (`ProtectionACL`), then
    /// tries to delete the file and move the folder; both must be refused.
    public static func denyDeleteACL(temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> DoctorCheck {
        withScratch("deny-delete-acl", "禁止刪除 ACL", "鎖定", in: temporaryDirectory) { root in
            let folder = root.appendingPathComponent("locked"), file = folder.appendingPathComponent("file")
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data([1]).write(to: file)
            defer { clearTestACLs(folder: folder.path, file: file.path) }
            do {
                try ProtectionACL.change(folder.path, directory: true, add: true, inherit: true)
                try ProtectionACL.change(file.path, directory: false, add: true)
            } catch {
                return .init("deny-delete-acl", "禁止刪除 ACL", .unknown, "無法加上測試 ACL：\(error)", "鎖定")
            }
            let fileRemoved = unlink(file.path) == 0
            let fileCode = errno
            let folderMoved = rename(folder.path, root.appendingPathComponent("moved").path) == 0
            let folderCode = errno
            let escaped = [fileRemoved ? "檔案被刪掉" : nil, folderMoved ? "資料夾被搬走" : nil].compactMap { $0 }
            if !escaped.isEmpty {
                return .init("deny-delete-acl", "禁止刪除 ACL", .problem, "鎖定擋不住：\(escaped.joined(separator: "、"))", "鎖定")
            }
            let refused: Set<Int32> = [EPERM, EACCES]
            guard refused.contains(fileCode), refused.contains(folderCode) else {
                return .init("deny-delete-acl", "禁止刪除 ACL", .unknown,
                             "刪除測試未完成：檔案 errno \(fileCode)、資料夾 errno \(folderCode)", "鎖定")
            }
            return .init("deny-delete-acl", "禁止刪除 ACL", .ok, "刪除檔案與搬移資料夾都被擋下", "鎖定")
        }
    }

    /// Removes only the test entries; a step that already removed or moved the item has nothing to clear.
    private static func clearTestACLs(folder: String, file: String) {
        try? ProtectionACL.change(file, directory: false, add: false)
        try? ProtectionACL.change(folder, directory: true, add: false, inherit: true)
    }

    public static func clonefile(temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> DoctorCheck {
        withScratch("clonefile", "APFS 檔案複製", "守護的備份", in: temporaryDirectory) { root in
            let source = root.appendingPathComponent("source"), copy = root.appendingPathComponent("copy")
            try Data("Hoard doctor".utf8).write(to: source)
            guard Darwin.clonefile(source.path, copy.path, 0) == 0 else {
                let code = errno
                return .init("clonefile", "APFS 檔案複製", code == ENOTSUP || code == EXDEV ? .problem : .unknown,
                             "clonefile 失敗：errno \(code)", "守護的備份")
            }
            let same = try safeRead(source) == safeRead(copy)
            return .init("clonefile", "APFS 檔案複製", same ? .ok : .problem,
                         same ? "複製成功且內容相同" : "複製內容不相同", "守護的備份")
        }
    }

    public static func libraryLayout(home: String = NSHomeDirectory()) -> DoctorCheck {
        let names = ["Caches", "Application Support", "Containers", "Preferences"]
        var missing: [String] = [], blocked: [String] = []
        for name in names {
            let path = (home as NSString).appendingPathComponent("Library/\(name)")
            var st = stat()
            if lstat(path, &st) != 0 {
                if errno == EACCES || errno == EPERM { blocked.append(name) } else { missing.append(name) }
            } else if (st.st_mode & S_IFMT) != S_IFDIR { missing.append(name) }
        }
        let affects = "App 佔用、解除安裝、已移除 App 的資料"
        if !blocked.isEmpty { return .init("library-layout", "Library 資料夾", .unknown, "無法檢查：\(blocked.joined(separator: "、"))", affects) }
        return .init("library-layout", "Library 資料夾", missing.isEmpty ? .ok : .problem,
                     missing.isEmpty ? "四個標準資料夾都存在" : "缺少：\(missing.joined(separator: "、"))", affects)
    }

    public static func processList(runningPaths: [String]? = InstalledApps.runningPaths(), pid: pid_t = getpid()) -> DoctorCheck {
        let id = "process-list", title = "執行中程序", affects = "解除安裝"
        guard let paths = runningPaths else {
            return .init(id, title, .problem, "無法確認 App 是否在執行：解除安裝會一律拒絕", affects)
        }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            return .init(id, title, .unknown, "無法取得本程序路徑：errno \(errno)", affects)
        }
        let found = paths.contains(String(cString: path))
        return .init(id, title, found ? .ok : .problem,
                     found ? "程序清單包含本程序" : "程序清單漏掉本程序", affects)
    }

    public static func homebrewReceipt(caskrooms: [String] = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]) -> DoctorCheck {
        let id = "homebrew-receipt", title = "Homebrew 安裝收據", affects = "解除安裝的 Homebrew 判斷"
        var exists = false
        var unreadable: String?
        for root in caskrooms {
            var st = stat()
            if lstat(root, &st) != 0 {
                if errno == ENOENT { continue }
                unreadable = unreadable ?? "無法檢查 \(root)：errno \(errno)"
                continue
            }
            exists = true
            guard (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            let tokens: [String]
            do { tokens = try fm.contentsOfDirectory(atPath: root) }
            catch { unreadable = unreadable ?? "無法列出 \(root)：\(error)"; continue }
            for token in tokens {
                let receipt = URL(fileURLWithPath: root).appendingPathComponent(token)
                    .appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
                var receiptStat = stat()
                if lstat(receipt.path, &receiptStat) != 0 {
                    if errno == ENOENT { continue }
                    unreadable = unreadable ?? "無法檢查收據：errno \(errno)"
                    continue
                }
                if (receiptStat.st_mode & S_IFMT) != S_IFREG { continue }
                let data: Data
                do { data = try safeRead(receipt) }
                catch { unreadable = unreadable ?? "無法安全讀取收據：\(error)"; continue }
                do {
                    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       object["uninstall_artifacts"] is [Any] {
                        return .init(id, title, .ok, "找到可解析的 Homebrew cask 收據", affects)
                    }
                } catch { continue }
            }
        }
        if let unreadable { return .init(id, title, .unknown, unreadable, affects) }
        return .init(id, title, exists ? .problem : .ok,
                     exists ? "Homebrew 收據格式變了：cask 偵測會漏判" : "沒有 Homebrew cask", affects)
    }

    private enum DoctorReadError: Error, CustomStringConvertible {
        case dataless, materialization
        var description: String { switch self { case .dataless: "SF_DATALESS"; case .materialization: "無法關閉 iCloud 自動下載" } }
    }

    private static func safeRead(_ url: URL) throws -> Data {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        guard st.st_flags & UInt32(SF_DATALESS) == 0 else { throw DoctorReadError.dataless }
        guard let restore = Materialization.offForThread("doctor") else { throw DoctorReadError.materialization }
        defer { restore() }
        return try Data(contentsOf: url)
    }

    private static func withScratch(_ id: String, _ title: String, _ affects: String, in base: URL,
                                    _ body: (URL) throws -> DoctorCheck) -> DoctorCheck {
        let root = base.appendingPathComponent("HoardDoctor-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: root, withIntermediateDirectories: false) }
        catch { return .init(id, title, .unknown, "無法建立測試資料夾：\(error)", affects) }
        let result: DoctorCheck
        do { result = try body(root) }
        catch { result = .init(id, title, .unknown, "測試未完成：\(error)", affects) }
        do { try fm.removeItem(at: root); return result }
        catch {
            if id == "deny-delete-acl" {
                let folder = root.appendingPathComponent("locked")
                clearTestACLs(folder: folder.path, file: folder.appendingPathComponent("file").path)
                if (try? fm.removeItem(at: root)) != nil { return result }
            }
            return .init(id, title, .unknown, "無法清理測試資料夾：\(error)", affects)
        }
    }
}
