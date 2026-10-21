import Darwin
import Foundation

/// Reading a file that has no data on this Mac (evicted to iCloud) downloads it, unless downloads are
/// turned off for the reading thread or process. Every reader that must not download asks here, and
/// reads nothing when the answer is no: a policy that cannot be set fails closed.
public enum Materialization {
    /// Turns downloads off for the calling thread and returns the undo; nil when the policy cannot be
    /// read or set.
    public static func offForThread(_ reader: String) -> (() -> Void)? {
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(policy, IOPOL_SCOPE_THREAD)
        guard previous >= 0 else {
            NSLog("Hoard %@: cannot read thread materialization policy: errno %d", reader, errno)
            return nil
        }
        guard setiopolicy_np(policy, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            NSLog("Hoard %@: cannot disable materialization: errno %d", reader, errno)
            return nil
        }
        return {
            if setiopolicy_np(policy, IOPOL_SCOPE_THREAD, previous) != 0 {
                NSLog("Hoard %@: cannot restore materialization policy: errno %d", reader, errno)
            }
        }
    }

    /// Turns downloads off for the whole process (a CLI run); false when it could not be set.
    public static func offForProcess() -> Bool {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
    }

    public static let refusedDetail = "could not turn off iCloud downloads, so nothing was read"
}
