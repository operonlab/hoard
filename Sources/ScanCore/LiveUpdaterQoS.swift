import Foundation

extension LiveUpdater {
    /// A live updater whose listings and rescans run at `qos` instead of utility: for a caller that
    /// waits for the replay in the foreground, such as a CLI query catching a snapshot up.
    public convenience init(tree: FileTree, scanner: Scanner, sinceEventId: UInt64?, qos: DispatchQoS,
                            onChange: @escaping (UpdateSummary) -> Void) {
        self.init(tree: tree, scanner: scanner, sinceEventId: sinceEventId, onChange: onChange)
        work = DispatchQueue(label: "Hoard.LiveUpdater.scan", qos: qos)
    }
}
