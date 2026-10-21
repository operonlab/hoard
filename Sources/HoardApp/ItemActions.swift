import AppKit
import Quartz
import SwiftUI
import ScanCore

/// Finder's answer per ancestor folder (`isPackage`: a type that conforms to com.apple.package, or the
/// bundle bit). A folder's kind changes only when an app registers a new package type.
@MainActor private var finderPackageAnswers: [String: Bool] = [:]

/// The merged "其他 N 項" cell, which has no node of its own.
struct MergedInfo: Equatable {
    let parent: NodeID
    let count: Int
    let bytes: Int64
}

/// 快速查看／在 Finder 中顯示／拷貝路徑／丟到垃圾桶… for one or more items (§3.4, §11.8).
struct ItemMenu: View {
    @ObservedObject var model: AppModel
    let ids: [NodeID]

    var body: some View {
        let live = ids.filter { model.isLive($0) }
        Button("快速查看") { model.quickLook(live) }.disabled(live.isEmpty)
        Button("在 Finder 中顯示") { model.reveal(live) }.disabled(live.isEmpty)
        Button("拷貝路徑") { model.copyPaths(live) }.disabled(live.isEmpty)
        Divider()
        ProtectMenuItems(model: model, ids: live)
        Divider()
        Button("丟到垃圾桶…") { model.requestTrash(live) }
            .disabled(live.isEmpty || live.contains { model.trashBlockReason($0) != nil })
    }
}

extension AppModel {
    func isLive(_ id: NodeID) -> Bool {
        guard let tree else { return false }
        return Int(id) < tree.nodeCount && !tree[id].isRemoved
    }

    /// Why this item cannot go to the Trash, or nil when it can (§8.3). Shown as `.help`.
    func trashBlockReason(_ id: NodeID) -> String? {
        guard let tree, isLive(id) else { return String(localized: "這個項目已經不在了。") }
        if id == FileTree.root || id == scope { return String(localized: "這是你正在檢視的位置，不能丟到垃圾桶。") }
        let node = tree[id]
        if node.status == .unavailable { return String(localized: "沒有權限讀取這個資料夾，Hoard 不會把它丟到垃圾桶。") }
        let path = Self.systemPath(tree.path(of: id))
        let protectedRoots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private"]
        let isProtected = path == NSHomeDirectory() || path == "/Applications" || path == "/Users"
            || protectedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
        if isProtected { return String(localized: "「\(node.name)」是系統需要的資料夾，Hoard 不會把它丟到垃圾桶。") }
        // A file inside a Photos library, an app or another package belongs to it: the library would
        // point at a missing original, the app would fail its signature check. The whole package can still go.
        if let package = Packages.enclosing(path) {
            return String(localized: "這個項目在「\(package)」裡面，由它自己管理；只丟掉裡面的檔案會把它弄壞。")
        }
        // The name list misses types that installed apps declare (Scrivener, DEVONthink): ask Finder too.
        var ancestor = URL(fileURLWithPath: path).deletingLastPathComponent()
        while ancestor.path != "/" {
            let folder = ancestor.path
            let isPackage = finderPackageAnswers[folder] ?? {
                // Unknown metadata blocks Trash too: it cannot prove this is a plain folder.
                guard let value = try? ancestor.resolvingSymlinksInPath().resourceValues(forKeys: [.isPackageKey]).isPackage else {
                    return true
                }
                finderPackageAnswers[folder] = value
                return value
            }()
            if isPackage {
                return String(localized: "這個項目在「\(ancestor.lastPathComponent)」裡面，由它自己管理；只丟掉裡面的檔案會把它弄壞。")
            }
            ancestor.deleteLastPathComponent()
        }
        return protectionTrashReason(id)
    }

    /// The path as the rest of the system names it: the data volume's firmlinked view.
    nonisolated static func systemPath(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        if path == data { return "/" }
        if path.hasPrefix(data + "/") { return String(path.dropFirst(data.count)) }
        return path
    }

    func reveal(_ ids: [NodeID]) {
        guard let tree, !ids.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: tree.path(of: $0)) })
    }

    func copyPaths(_ ids: [NodeID]) {
        guard let tree, !ids.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ids.map { tree.path(of: $0) }.joined(separator: "\n"), forType: .string)
    }

    func quickLook(_ ids: [NodeID]) {
        guard let tree else { return }
        QuickLook.shared.show(ids.filter { isLive($0) }.map { URL(fileURLWithPath: tree.path(of: $0)) })
    }
}

/// Owns the shared Quick Look panel. It is the panel's data source and, through the app
/// delegate, its controller in the responder chain.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private(set) var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        // Normally the app delegate hands the data source over as the panel's controller.
        if panel.dataSource == nil { panel.dataSource = self; panel.reloadData() }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
