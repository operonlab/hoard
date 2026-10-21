import Darwin
import Foundation
import XCTest
@testable import ScanCore

/// Automatic scans (the live updater, a rescan the app starts on its own) run at utility so they leave
/// the CPU and the disk to what the user is doing; a scan the user asked for keeps its speed.
final class ScanPriorityTests: XCTestCase {
    private func fixture() throws -> String {
        let path = FileManager.default.temporaryDirectory.path + "/ScanPriorityTests-\(UUID().uuidString)"
        for n in 0..<8 {
            try FileManager.default.createDirectory(atPath: path + "/d\(n)/e", withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    /// The QoS of every worker, read where each one turns downloads off before it reads anything.
    private final class QoSLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var classes: [qos_class_t] = []
        func record() { lock.lock(); classes.append(qos_class_self()); lock.unlock() }
    }

    private func workerClasses(callerQoS: DispatchQoS.QoSClass, threads: Int = 4) throws -> [qos_class_t] {
        let root = try fixture()
        var st = stat()
        XCTAssertEqual(lstat(root, &st), 0)
        let tree = FileTree(rootPath: root, device: st.st_dev, rootModTime: Int64(st.st_mtimespec.tv_sec))
        let fd = Darwin.open(root, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let log = QoSLog()
        let walk = ParallelWalk(tree: tree, rootFD: fd, crossDevices: false, progress: nil, isCancelled: nil,
                                downloadsOff: { _ in log.record(); return {} })
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: callerQoS).async {
            XCTAssertTrue(walk.run(threads: threads))
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "walk hang")
        XCTAssertEqual(log.classes.count, threads)
        return log.classes
    }

    func testWorkersOfAUtilityCallerRunAtUtility() throws {
        for qos in try workerClasses(callerQoS: .utility) { XCTAssertEqual(qos, QOS_CLASS_UTILITY) }
    }

    func testWorkersOfABackgroundCallerRunAtBackground() throws {
        for qos in try workerClasses(callerQoS: .background) { XCTAssertEqual(qos, QOS_CLASS_BACKGROUND) }
    }

    /// A scan the user asked for runs as it always has: workers at the default class, not lowered.
    func testWorkersOfAUserCallerKeepTheDefaultClass() throws {
        for qos in try workerClasses(callerQoS: .userInitiated) { XCTAssertEqual(qos, QOS_CLASS_DEFAULT) }
    }

    /// The app's automatic rescans: a utility task calling `scan` gets utility workers, the opening thread included.
    func testAScanInAUtilityTaskRunsAtUtility() async throws {
        let root = try fixture()
        let log = QoSLog()
        _ = try await Task.detached(priority: .utility) {
            try Scanner(options: ScanOptions(threads: 4)).scan(root: root, progress: nil, isCancelled: nil,
                                                                 downloadsOff: { _ in log.record(); return {} })
        }.value
        XCTAssertEqual(log.classes.count, 5)
        for qos in log.classes { XCTAssertEqual(qos, QOS_CLASS_UTILITY) }
    }

    /// Work the main thread hands the live updater runs at utility, not at the main thread's class.
    func testLiveUpdaterWorkRunsAtUtility() throws {
        let root = try fixture()
        let updater = LiveUpdater(tree: try Scanner().scan(root: root), scanner: Scanner(), sinceEventId: nil) { _ in }
        XCTAssertEqual(ranAt(updater.work), QOS_CLASS_UTILITY)
    }

    /// The CLI waits for its catch-up in the foreground, so it asks for its own class.
    func testLiveUpdaterTakesAClass() throws {
        let root = try fixture()
        let updater = LiveUpdater(tree: try Scanner().scan(root: root), scanner: Scanner(), sinceEventId: nil,
                                  qos: .userInitiated) { _ in }
        XCTAssertEqual(ranAt(updater.work), QOS_CLASS_USER_INITIATED)
    }

    /// The class a block submitted from the main thread runs at on `queue`.
    private func ranAt(_ queue: DispatchQueue) -> qos_class_t {
        XCTAssertTrue(Thread.isMainThread)
        let log = QoSLog()
        let done = DispatchSemaphore(value: 0)
        queue.async { log.record(); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        return log.classes.first ?? QOS_CLASS_UNSPECIFIED
    }
}
