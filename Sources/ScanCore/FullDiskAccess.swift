import Darwin

/// Whether this process has Full Disk Access, probed directly instead of guessed from unreadable
/// folders: with FDA granted, about two hundred system folders on the data volume are still
/// unreadable (root-only or SIP-protected, measured 2026-10-20), so "something is unreadable"
/// says nothing about the permission.
public enum FullDiskAccess {
    public enum State: Equatable, Sendable {
        case granted
        case denied
        /// The probe could not decide (probe file missing, unexpected error). Not the same as denied.
        case unknown(errno: Int32)
    }

    /// The system TCC database: readable only by processes that hold Full Disk Access.
    static let probePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    public static func current() -> State {
        state(openingResult: open(probePath, O_RDONLY), errno: errno)
    }

    static func state(openingResult fd: Int32, errno err: Int32) -> State {
        if fd >= 0 { close(fd); return .granted }
        switch err {
        case EPERM, EACCES: return .denied
        default: return .unknown(errno: err)
        }
    }
}
