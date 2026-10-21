import AppKit
import Darwin
import UniformTypeIdentifiers

/// File icons that never download a file: an iCloud placeholder (or anything `lstat` cannot see) gets
/// the icon of its type, without touching the file. Owner decision 2026-10-21: only a Quick Look the
/// user asks for may download.
enum FileIcons {
    @MainActor static func icon(forPath path: String, isDirectory directoryHint: Bool?) -> NSImage {
        var st = stat()
        let found = lstat(path, &st) == 0
        if !found || st.st_flags & UInt32(SF_DATALESS) != 0 {
            let isDirectory = found ? (st.st_mode & S_IFMT) == S_IFDIR : directoryHint ?? path.hasSuffix("/")
            let type: UTType = isDirectory ? .folder :
                (UTType(filenameExtension: (path as NSString).pathExtension) ?? .data)
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(forFile: path)
    }
}
