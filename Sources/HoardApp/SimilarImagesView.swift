import AppKit
import ScanCore
import SwiftUI

struct SimilarImagesView: View {
    @ObservedObject var model: AppModel
    @State private var report: SimilarReport?
    @State private var progress: SimilarProgress?
    @State private var pending = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("相似的照片").font(.headline)
            Text("相似不等於相同：丟掉前請先快速查看。")
                .foregroundStyle(.secondary)
            HStack {
                Button("找出相似的照片") { start() }.disabled(pending || model.tree == nil)
                if pending {
                    Button("取消") { task?.cancel() }
                    ProgressView().controlSize(.small)
                }
                if let progress, pending {
                    Text("\(progress.filesDone) / \(progress.filesTotal) 張")
                        .foregroundStyle(.secondary)
                }
            }
            if let report {
                if report.status != .complete {
                    Text(report.status == .cancelled ? String(localized: "已取消；以下僅列出已處理照片的相似結果。") : String(localized: "部分照片無法讀取；結果不完整。"))
                        .foregroundStyle(.orange)
                }
                if report.groups.isEmpty { Text("目前沒有找到相似的照片。") }
                ForEach(Array(report.groups.enumerated()), id: \.offset) { _, group in
                    DisclosureGroup("相似，並非相同・\(group.members.count) 張・\(group.partial ? String(localized: "未完成") : String(localized: "可考慮清理 \(Fmt.bytes(group.reclaimableBytes))"))") {
                        ForEach(group.members, id: \.path) { member in
                            row(member, keep: group.suggestedKeep, keepRemains: keepRemains(group))
                        }
                    }
                }
                Text("使用 Vision feature print 修訂版 \(report.revision)；找到 \(report.groups.count) 組。硬連結與共用儲存空間不計入可清理大小。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.scope) { _, _ in reset() }
        .onChange(of: model.generation) { _, _ in reset() }
        // A rescan of the same root installs a new tree without a new generation: node ids change.
        .onChange(of: model.tree.map(ObjectIdentifier.init)) { _, _ in reset() }
        .task(id: model.generation) { if LaunchOptions.findSimilar && model.tree != nil && report == nil { start() } }
        .onDisappear { task?.cancel() }
    }

    /// The image to keep is still there and not in a Trash: only then may the others go.
    private func keepRemains(_ group: SimilarGroup) -> Bool {
        guard let keep = group.members.first(where: { $0.node == group.suggestedKeep }),
              model.isLive(keep.node), model.tree?.path(of: keep.node) == keep.path else { return false }
        let components = AppModel.systemPath(keep.path).split(separator: "/")
        return !components.contains(".Trash") && !components.contains(".Trashes")
    }

    private func row(_ member: SimilarMember, keep: NodeID, keepRemains: Bool) -> some View {
        let live = model.isLive(member.node) && model.tree?.path(of: member.node) == member.path
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text((member.path as NSString).lastPathComponent)
                    if member.node == keep { Text("建議保留").font(.caption).foregroundStyle(.green) }
                }
                Text(Fmt.tildePath((member.path as NSString).deletingLastPathComponent))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Fmt.bytes(member.logicalBytes)).monospacedDigit()
            Menu {
                Button("快速查看") { model.quickLook([member.node]) }.disabled(!live)
                Button("在 Finder 中顯示") { model.reveal([member.node]) }.disabled(!live)
                if live && keepRemains && member.node != keep && model.trashBlockReason(member.node) == nil {
                    Divider()
                    Button("丟到垃圾桶…") { model.requestTrash([member.node], source: "similar") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.leading, 8)
    }

    private func start() {
        guard let tree = model.tree, !pending else { return }
        let nodes = tree.nodes, rootPath = tree.rootPath, scope = model.scope, generation = model.generation
        // A rescan of the same root keeps generation and may keep the scope: only the tree tells.
        weak let started = tree
        let current = { model.generation == generation && model.scope == scope && model.tree.map { $0 === started } == true }
        report = nil
        progress = nil
        pending = true
        task = Task {
            let worker = Task.detached(priority: .utility) {
                SimilarImages.find(in: nodes, rootPath: rootPath, under: scope,
                                   isCancelled: { Task<Never, Never>.isCancelled },
                                   progress: { value in
                    Task { @MainActor in
                        if current() { progress = value }
                    }
                })
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            // A user's 取消 still shows what was read; a result for a tree that is gone never lands.
            guard current() else { return }
            report = result
            pending = false
            task = nil
        }
    }

    private func reset() {
        task?.cancel()
        task = nil
        pending = false
        progress = nil
        report = nil
    }
}
