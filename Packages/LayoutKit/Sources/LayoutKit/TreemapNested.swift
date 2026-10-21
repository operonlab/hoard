/// One node of a weighted tree to lay out with `Treemap.layoutNested`.
/// `weight` is used as-is for the node's share among its siblings; it is not recomputed from `children`.
public struct TreemapNode: Equatable, Sendable {
    public var id: Int
    public var weight: Double
    public var children: [TreemapNode]

    public init(id: Int, weight: Double, children: [TreemapNode] = []) {
        self.id = id; self.weight = weight; self.children = children
    }
}

extension Treemap {
    /// Lays out a tree of nodes: `roots` are squarified inside `rect`, then each node's children are
    /// squarified inside the node's rect inset by `padding` on every side and by `headerHeight` more at the top.
    ///
    /// - Coordinates are y-down: the header strip sits at the node rect's minimum y.
    /// - Roots have depth 0; nodes are emitted while `depth < maxDepth` (`maxDepth: 1` gives roots only).
    /// - A node whose rect is smaller than 2x2 is neither emitted nor recursed into. A node whose inner
    ///   rect is smaller than 2x2 is emitted but its children are not.
    /// - Output is pre-order (each parent before its children), so drawing in order paints children on top.
    /// - Negative `padding` / `headerHeight` are treated as 0.
    public static func layoutNested(
        _ roots: [TreemapNode],
        in rect: LRect,
        maxDepth: Int,
        padding: Double,
        headerHeight: Double
    ) -> [(id: Int, rect: LRect, depth: Int)] {
        var out: [(id: Int, rect: LRect, depth: Int)] = []
        let pad = padding > 0 && padding.isFinite ? padding : 0
        let header = headerHeight > 0 && headerHeight.isFinite ? headerHeight : 0
        layoutLevel(roots, in: rect, depth: 0, maxDepth: maxDepth, padding: pad, header: header, into: &out)
        return out
    }

    private static func layoutLevel(
        _ nodes: [TreemapNode],
        in rect: LRect,
        depth: Int,
        maxDepth: Int,
        padding: Double,
        header: Double,
        into out: inout [(id: Int, rect: LRect, depth: Int)]
    ) {
        guard depth < maxDepth, !nodes.isEmpty else { return }
        let rects = squarify(weights: nodes.map(\.weight), in: rect)
        for (node, r) in zip(nodes, rects) where r.width >= 2 && r.height >= 2 {
            out.append((id: node.id, rect: r, depth: depth))
            guard !node.children.isEmpty, depth + 1 < maxDepth else { continue }
            let inner = LRect(
                x: r.x + padding,
                y: r.y + padding + header,
                width: r.width - 2 * padding,
                height: r.height - 2 * padding - header
            )
            guard inner.width >= 2, inner.height >= 2 else { continue }
            layoutLevel(node.children, in: inner, depth: depth + 1, maxDepth: maxDepth, padding: padding, header: header, into: &out)
        }
    }
}
