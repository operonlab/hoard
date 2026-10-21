import Foundation

/// Runs one background pass at a time over the current tree state. A request that arrives while a
/// pass is running does not cancel it: a cached root replays about a dozen live batches a second, and
/// cancel-and-restart on a 0.3 s pass then never finishes. The request marks the job dirty instead,
/// and one more pass runs on the newest state after this one lands.
/// ponytail: no throttle between passes, so a change stream keeps one utility thread busy; add a
/// minimum spacing if that shows up in Activity Monitor.
@MainActor
final class CoalescedJob<Value: Sendable> {
    private var running = false
    private var dirty = false
    /// Called on the main actor when a pass starts; captures the state to work on, or returns nil
    /// when there is nothing to do.
    private let make: () -> (@Sendable () -> Value)?
    private let deliver: (Value) -> Void

    init(make: @escaping () -> (@Sendable () -> Value)?, deliver: @escaping (Value) -> Void) {
        self.make = make
        self.deliver = deliver
    }

    func request() {
        if running { dirty = true } else { launch() }
    }

    private func launch() {
        dirty = false
        guard let work = make() else { return }
        running = true
        Task { [weak self] in
            let value = await Task.detached(priority: .utility, operation: work).value
            guard let self else { return }
            self.running = false
            self.deliver(value)
            if self.dirty { self.launch() }
        }
    }
}
