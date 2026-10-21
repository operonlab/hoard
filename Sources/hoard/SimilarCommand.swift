import Foundation
import ScanCore

struct SimilarCommandResult {
    let fields: [String: Any]
    let human: String
}

enum SimilarCommand {
    static func run(tree: FileTree, minSize: Int64, threshold: Float, limit: Int,
                    deadline: Date) -> SimilarCommandResult {
        let report = SimilarImages.find(in: tree.nodes, rootPath: tree.rootPath,
                                        options: SimilarOptions(minSize: minSize, threshold: threshold),
                                        isCancelled: { Date() >= deadline })
        let shown = Array(report.groups.prefix(limit))
        // One group of video frames can hold thousands of images, and an iCloud library thousands of
        // skips: cap both so a tool result stays small, and say how many were left out.
        let memberCap = 50, skipCap = 100
        let groups: [[String: Any]] = shown.map { group in
            ["similar_not_identical": true, "partial": group.partial,
             "suggested_keep": group.suggestedKeep,
             "reclaimable_bytes": group.partial ? NSNull() as Any : group.reclaimableBytes,
             "members_omitted": max(0, group.members.count - memberCap),
             "members": group.members.prefix(memberCap).map { member -> [String: Any] in
                 ["path": member.path, "node": member.node, "aliases": member.aliases,
                  "width": member.width.map { $0 as Any } ?? NSNull(),
                  "height": member.height.map { $0 as Any } ?? NSNull(),
                  "logical_bytes": member.logicalBytes, "allocated_bytes": member.allocatedBytes,
                  "shared_storage": member.sharedStorage]
             }]
        }
        let fields: [String: Any] = [
            "status": report.status.rawValue, "tree_status": String(describing: report.treeStatus),
            "revision": report.revision, "threshold": threshold,
            "candidate_files": report.candidateFiles, "processed_files": report.processedFiles,
            "pending_files": report.pendingFiles, "images_per_second": report.imagesPerSecond,
            "reclaimable_bytes": report.status == .complete ? report.reclaimableBytes as Any : NSNull(),
            "omitted": max(0, report.groups.count - shown.count), "groups": groups,
            "skipped": report.skipped.prefix(skipCap).map { ["path": $0.path, "reason": $0.reason, "detail": $0.detail] },
            "skipped_omitted": max(0, report.skipped.count - skipCap),
            "skipped_by_reason": Dictionary(report.skipped.map { ($0.reason, 1) }, uniquingKeysWith: +)
        ]
        var lines = ["Similar images [\(report.status.rawValue)], Vision revision \(report.revision), threshold \(threshold)"]
        for group in shown {
            lines.append("  similar, not identical: \(group.members.count) images; estimated reclaimable \(group.partial ? "unknown" : ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file))")
            for member in group.members.prefix(10) {
                lines.append("    \(member.node == group.suggestedKeep ? "keep: " : "review: ")\(member.path)")
            }
            if group.members.count > 10 { lines.append("    … \(group.members.count - 10) more") }
        }
        return SimilarCommandResult(fields: fields, human: lines.joined(separator: "\n"))
    }
}
