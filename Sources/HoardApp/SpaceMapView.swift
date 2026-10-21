import AppKit
import SwiftUI
import ScanCore
import LayoutKit

/// One drawn cell of the space map.
struct MapTile {
    var node: NodeID?           // nil for the merged "其他 N 項" cell
    var parent: NodeID
    var rect: CGRect = .zero
    var depth = 0
    var name: String
    var bytes: Int64
    var status: ScanStatus
    var isDirectory: Bool
    var ext: String
    var fileCount: Int64
    var mergedCount = 0
    /// A first-level folder whose children are drawn inside it, under an 18 pt title strip.
    var isFrame = false

    var category: FileCategory? { isDirectory || node == nil ? nil : FileCategory.of(extension: ext) }
}

/// Nested squarified layout of the scope (§3.1): first-level items, and inside each first-level
/// folder its own children. At most 300 items per level; the rest merge into one cell.
enum MapLayout {
    static let perLevel = 300
    static let header: Double = 18
    static let margin: CGFloat = 8

    static func build(tree: FileTree, scope: NodeID, size: CGSize) -> [MapTile] {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        guard bounds.width > 4, bounds.height > 4, Int(scope) < tree.nodeCount else { return [] }
        var infos: [MapTile] = []

        func level(_ parent: NodeID, depth: Int) -> [TreemapNode] {
            // Unreadable folders have no known size, so they get no area (§7.1).
            let kids = tree.sortedChildren(of: parent).filter { tree[$0].status != .unavailable }
            var out: [TreemapNode] = []
            for id in kids.prefix(perLevel) {
                let n = tree[id]
                let index = infos.count
                infos.append(MapTile(node: id, parent: parent, name: n.name, bytes: n.totalAlloc, status: n.status,
                                     isDirectory: n.isDirectory, ext: n.isDirectory ? "" : FileTree.fileExtension(n.name),
                                     fileCount: n.fileCount))
                let children = depth == 0 && n.isDirectory ? level(id, depth: 1) : []
                out.append(TreemapNode(id: index, weight: Double(max(1, n.totalAlloc)), children: children))
            }
            let hidden = kids.dropFirst(perLevel)
            if !hidden.isEmpty {
                let bytes = hidden.reduce(Int64(0)) { $0 + tree[$1].totalAlloc }
                let partial = hidden.contains { tree[$0].status != .complete }
                infos.append(MapTile(node: nil, parent: parent, name: String(localized: "其他 \(hidden.count) 項"), bytes: bytes,
                                     status: partial ? .partial : .complete, isDirectory: false, ext: "",
                                     fileCount: 0, mergedCount: hidden.count))
                out.append(TreemapNode(id: infos.count - 1, weight: Double(max(1, bytes))))
            }
            return out
        }

        let roots = level(scope, depth: 0)
        let placed = Treemap.layoutNested(roots, in: LRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                                                          height: bounds.height),
                                          maxDepth: 2, padding: 2, headerHeight: header)
        var tiles: [MapTile] = []
        tiles.reserveCapacity(placed.count)
        var frameIndex: [NodeID: Int] = [:]
        for item in placed {
            var tile = infos[item.id]
            tile.rect = CGRect(x: item.rect.x, y: item.rect.y, width: item.rect.width, height: item.rect.height)
            tile.depth = item.depth
            if item.depth == 0, let id = tile.node, tile.isDirectory {
                // Too small for a title strip and readable children: draw it as a plain cell.
                if tile.rect.width >= 48 && tile.rect.height >= 40 { tile.isFrame = true; frameIndex[id] = tiles.count }
            } else if item.depth == 1, frameIndex[tile.parent] == nil {
                continue
            }
            tiles.append(tile)
        }
        return tiles
    }
}

private final class MapLayoutCache {
    private var key: (ObjectIdentifier?, Int, NodeID, CGSize) = (nil, -1, -1, .zero)
    private(set) var tiles: [MapTile] = []
    private(set) var version = 0

    func tiles(tree: FileTree?, revision: Int, scope: NodeID, size: CGSize) -> [MapTile] {
        let identity = tree.map(ObjectIdentifier.init)
        if identity != key.0 || revision != key.1 || scope != key.2 || size != key.3 {
            key = (identity, revision, scope, size)
            tiles = tree.map { MapLayout.build(tree: $0, scope: scope, size: size) } ?? []
            version += 1
        }
        return tiles
    }

    private var badgeKey = (-1, -1)
    private(set) var badges: [NodeID: [ProtectionKind]] = [:]

    /// Kind glyphs for the tiles big enough to carry one, recomputed only when the layout or the
    /// protection list changes (hover re-runs the view body on every mouse move).
    func badges(for version: Int, protection: Int, kinds: (NodeID) -> [ProtectionKind]) -> [NodeID: [ProtectionKind]] {
        guard badgeKey != (version, protection) else { return badges }
        badgeKey = (version, protection)
        badges = [:]
        for tile in tiles {
            guard let id = tile.node, tile.rect.width >= MapCanvas.badgeMinimum.width + 1,
                  tile.rect.height >= MapCanvas.badgeMinimum.height + 1 else { continue }
            let found = kinds(id)
            if !found.isEmpty { badges[id] = found }
        }
        return badges
    }
}

enum TextScale {
    static let key = "textScaleIndex"
    static let steps: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]
    static func factor(_ index: Int) -> Double { steps[max(0, min(steps.count - 1, index))] }
}

struct SpaceMapView: View {
    @ObservedObject var model: AppModel
    @AppStorage(TextScale.key) private var scaleIndex = 1
    @AppStorage("mapHintDismissed") private var hintDismissed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cache = MapLayoutCache()
    @State private var hovered: Int?
    @State private var hoverPoint: CGPoint?
    @State private var pendingZoom: CGRect?
    @State private var zoomFrom: CGRect?
    @State private var fading = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PathBar(model: model)
            Divider()
            GeometryReader { geometry in
                let tiles = cache.tiles(tree: model.tree, revision: model.revision, scope: model.scope, size: geometry.size)
                map(tiles: tiles, size: geometry.size)
            }
            Divider()
            LegendRow(model: model)
            InfoBar(text: infoText)
            if !hintDismissed {
                HStack {
                    Image(systemName: "lightbulb").foregroundStyle(.secondary)
                    Text("面積越大代表佔用越多。按兩下資料夾可以進去看。")
                    Spacer()
                    Button { hintDismissed = true } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("關閉提示")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .onChange(of: model.scope) { _, _ in
            hovered = nil
            if let from = pendingZoom, !reduceMotion {
                zoomFrom = from
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.25)) { zoomFrom = nil } }
            } else {
                fading = true
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.2)) { fading = false } }
            }
            pendingZoom = nil
        }
    }

    // MARK: Map

    private func map(tiles: [MapTile], size: CGSize) -> some View {
        let scale = TextScale.factor(scaleIndex)
        let badges = model.protection.rows.isEmpty ? [:]
            : cache.badges(for: cache.version, protection: model.protection.version) { model.protectionKinds(of: $0) }
        return ZStack(alignment: .topLeading) {
            MapCanvas(tiles: tiles, version: cache.version, mixes: currentMixes, highlight: model.highlight, scale: scale,
                      badges: badges, badgeVersion: model.protection.version)
                .equatable()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityLabel(tiles))
                .accessibilityChildren { accessibilityCells(tiles) }
            MapOverlay(tiles: tiles, hovered: hovered, selected: selectedIndices(tiles))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .scaleEffect(x: zoomScale(size).width, y: zoomScale(size).height, anchor: .topLeading)
        .offset(x: zoomFrom?.minX ?? 0, y: zoomFrom?.minY ?? 0)
        .opacity(fading ? 0 : 1)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = hit(point, tiles); hoverPoint = point
            case .ended: hovered = nil; hoverPoint = nil
            }
        }
        .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { value in
            focused = true
            // ⌘ or ⇧ adds or removes a cell, as in Finder's icon view (a range has no meaning on a map).
            let toggles = !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
            if let index = hit(value.location, tiles) {
                if toggles, let id = tiles[index].node { model.toggleSelected(id) } else { choose(tiles[index]) }
            } else if !toggles {
                clearSelection()
            }
        })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
            guard let index = hit(value.location, tiles), let id = tiles[index].node else { return }
            open(id, from: tiles[index].rect)
        })
        .contextMenu {
            // Hit-test the pointer against the tiles drawn now: `hovered` indexes the tiles of the last
            // hover event, and a live update in between can shrink the array (a crash) or shift it, which
            // would point the menu (Move to Trash included) at a different item.
            if let point = hoverPoint, let index = hit(point, tiles), let id = tiles[index].node {
                ItemMenu(model: model, ids: model.selectedIDs.contains(id) ? model.selectedIDs : [id])
            }
        }
        .onKeyPress(.escape) { clearSelection(); return .handled }
        .onKeyPress(.return) {
            guard let index = selectedIndex(tiles), let id = tiles[index].node else { return .ignored }
            open(id, from: tiles[index].rect)
            return .handled
        }
        .onKeyPress(.space) {
            guard !model.selectedIDs.isEmpty else { return .ignored }
            model.quickLook(model.selectedIDs)
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            move(press.key, tiles)
            return .handled
        }
    }

    private func zoomScale(_ size: CGSize) -> CGSize {
        guard let from = zoomFrom, size.width > 0, size.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: max(0.01, from.width / size.width), height: max(0.01, from.height / size.height))
    }

    private func hit(_ point: CGPoint, _ tiles: [MapTile]) -> Int? {
        tiles.indices.reversed().first { tiles[$0].rect.contains(point) }
    }

    private func selectedIndex(_ tiles: [MapTile]) -> Int? {
        if let merged = model.mergedSelection {
            return tiles.firstIndex { $0.node == nil && $0.parent == merged.parent }
        }
        guard let id = model.selection else { return nil }
        return tiles.firstIndex { $0.node == id }
    }

    private func selectedIndices(_ tiles: [MapTile]) -> [Int] {
        guard model.selectedIDs.count > 1 else { return selectedIndex(tiles).map { [$0] } ?? [] }
        let chosen = Set(model.selectedIDs)
        return tiles.indices.filter { tiles[$0].node.map(chosen.contains) ?? false }
    }

    private func choose(_ tile: MapTile) {
        if let id = tile.node {
            model.select(id)
        } else {
            model.selectMerged(MergedInfo(parent: tile.parent, count: tile.mergedCount, bytes: tile.bytes))
        }
    }

    private func clearSelection() { model.select(nil) }

    private func open(_ id: NodeID, from rect: CGRect) {
        guard let tree = model.tree else { return }
        if tree[id].isDirectory {
            pendingZoom = rect
            hintDismissed = true
        }
        model.enter(id)
    }

    /// Moves the selection to the nearest cell in the arrow's direction.
    private func move(_ key: KeyEquivalent, _ tiles: [MapTile]) {
        guard !tiles.isEmpty else { return }
        guard let current = selectedIndex(tiles) else { choose(tiles[0]); return }
        let from = CGPoint(x: tiles[current].rect.midX, y: tiles[current].rect.midY)
        var best: (Int, CGFloat)?
        for (index, tile) in tiles.enumerated() where index != current {
            let dx = tile.rect.midX - from.x, dy = tile.rect.midY - from.y
            let (along, across): (CGFloat, CGFloat)
            switch key {
            case .leftArrow: (along, across) = (-dx, dy)
            case .rightArrow: (along, across) = (dx, dy)
            case .upArrow: (along, across) = (-dy, dx)
            default: (along, across) = (dy, dx)
            }
            guard along > 1 else { continue }
            let score = along + 2 * abs(across)
            if best == nil || score < best!.1 { best = (index, score) }
        }
        if let best { choose(tiles[best.0]) }
    }

    /// Folder colors for the scope on screen; empty until its first pass lands (folders draw neutral).
    private var currentMixes: FolderMixes {
        model.folderMix.scope == model.scope ? model.folderMix : .none
    }

    /// "・主要是模型與資料（62%）", "・類型混合", or "" while the folder's mix is not known.
    private func mixText(_ id: NodeID) -> String {
        guard let mix = currentMixes.byFolder[id] else { return "" }
        guard let tint = mix.tint else { return String(localized: "・類型混合") }
        return String(localized: "・主要是\(tint.title)（\(Int((mix.share * 100).rounded()))%）")
    }

    // MARK: Text

    private var infoText: String {
        guard let tree = model.tree else { return "" }
        let scopeNode = tree[model.scope]
        let cache = self.cache
        if let index = hovered, index < cache.tiles.count {
            let tile = cache.tiles[index]
            guard let id = tile.node else { return String(localized: "\(tile.name) — \(Fmt.bytes(tile.bytes))") }
            let node = tree[id]
            var path = tile.name
            if tile.depth == 1, tile.parent != model.scope { path = "\(tree[tile.parent].name) › \(tile.name)" }
            let head = String(localized: "\(path) — \(Fmt.size(node))・佔 \(model.scopeName) \(Fmt.share(node, of: scopeNode))")
            return node.isDirectory ? String(localized: "\(head)・資料夾・\(node.fileCount) 個檔案\(mixText(id))")
                : String(localized: "\(head)・\(FileCategory.of(extension: FileTree.fileExtension(node.name)).title)")
        }
        return model.summarySentence
    }

    private func accessibilityLabel(_ tiles: [MapTile]) -> String {
        guard let tree = model.tree else { return String(localized: "空間地圖") }
        let shown = tiles.filter { $0.node != nil }.count
        return String(localized: "空間地圖，\(model.scopeName)，\(Fmt.sizeSpoken(tree[model.scope]))，顯示 \(shown) 個項目")
    }

    private func tileAccessibilityLabel(_ tile: MapTile, id: NodeID, node: Node, kinds: [ProtectionKind]) -> String {
        let protectedNames = protectionNames(kinds)
        if node.isDirectory {
            let mix = mixText(id).replacingOccurrences(of: "・", with: "，")
            return kinds.isEmpty ? String(localized: "\(node.name)，資料夾\(mix)")
                : String(localized: "\(node.name)，資料夾\(mix)，受保護（\(protectedNames)）")
        }
        let category = tile.category?.title ?? ""
        return kinds.isEmpty ? String(localized: "\(node.name)，\(category)")
            : String(localized: "\(node.name)，\(category)，受保護（\(protectedNames)）")
    }

    /// The 100 largest cells, largest first (§9.3), each with its own actions.
    @ViewBuilder private func accessibilityCells(_ tiles: [MapTile]) -> some View {
        if let tree = model.tree {
            let scopeNode = tree[model.scope]
            let cells = tiles.filter { $0.node != nil }.sorted { $0.bytes > $1.bytes }.prefix(100)
            ForEach(Array(cells), id: \.node) { tile in
                let id = tile.node!
                let node = tree[id]
                let kinds = model.protectionKinds(of: id)
                Rectangle()
                    .frame(width: tile.rect.width, height: tile.rect.height)
                    .position(x: tile.rect.midX, y: tile.rect.midY)
                    .accessibilityLabel(tileAccessibilityLabel(tile, id: id, node: node, kinds: kinds))
                    .accessibilityValue(String(localized: "\(Fmt.sizeSpoken(node))，佔 \(model.scopeName) \(Fmt.share(node, of: scopeNode))"))
                    .accessibilityAddTraits(model.selectedIDs.contains(id) ? .isSelected : [])
                    .accessibilityAction { model.select(id) }
                    .accessibilityAction(named: "打開") { model.enter(id) }
                    .accessibilityAction(named: "在 Finder 中顯示") { model.reveal(id) }
                    .accessibilityAction(named: "快速查看") { model.quickLook([id]) }
                    .accessibilityAction(named: "丟到垃圾桶") { model.requestTrash([id]) }
            }
        }
    }
}

/// The squarified cells. Equatable on the layout version so hover redraws only the overlay.
private struct MapCanvas: View, Equatable {
    let tiles: [MapTile]
    let version: Int
    let mixes: FolderMixes
    let highlight: Highlight?
    let scale: Double
    /// Protection kind glyphs per node, drawn in the top-right corner of tiles at least `badgeMinimum`.
    let badges: [NodeID: [ProtectionKind]]
    let badgeVersion: Int
    static let badgeMinimum = CGSize(width: 40, height: 28)
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColor

    static func == (a: MapCanvas, b: MapCanvas) -> Bool {
        a.version == b.version && a.highlight == b.highlight && a.scale == b.scale && a.badgeVersion == b.badgeVersion
            && a.mixes.generation == b.mixes.generation && a.mixes.scope == b.mixes.scope
            && a.mixes.revision == b.mixes.revision
    }

    var body: some View {
        let look = FileCategory.Look(dark: scheme == .dark, highContrast: contrast == .increased)
        Canvas { context, _ in
            for tile in tiles { draw(tile, in: &context, look: look) }
        }
    }

    /// The category an inner folder tile is filled with (§3.2): its dominant one, nil when it is mixed,
    /// not known yet, or the tile is a first-level frame.
    private func tint(_ tile: MapTile) -> FileCategory? {
        guard tile.isDirectory, !tile.isFrame, let id = tile.node else { return nil }
        return mixes.byFolder[id]?.tint
    }

    private func dimmed(_ tile: MapTile) -> Bool {
        guard let highlight else { return false }
        if tile.isFrame || tile.node == nil { return false }
        if tile.isDirectory {
            if case .category(let category) = highlight, tint(tile) == category { return false }
            return true
        }
        return !highlight.matches(tile.ext)
    }

    private func draw(_ tile: MapTile, in context: inout GraphicsContext, look: FileCategory.Look) {
        let box = tile.rect.insetBy(dx: 0.5, dy: 0.5)
        guard box.width >= 1, box.height >= 1 else { return }
        let radius = min(tile.depth == 0 ? 4 : 2, box.width / 2, box.height / 2)
        let shape = Path(roundedRect: box, cornerRadius: radius)
        var ctx = context
        if dimmed(tile) { ctx.opacity = 0.25 }
        let labelColor: Color
        if tile.isFrame {
            ctx.fill(shape, with: .color(.primary.opacity(0.06)))
            var strip = ctx
            strip.clip(to: shape)
            strip.fill(Path(CGRect(x: box.minX, y: box.minY, width: box.width, height: min(box.height, MapLayout.header))),
                       with: .color(.primary.opacity(0.10)))
            labelColor = .primary
        } else if let category = tile.category {
            ctx.fill(shape, with: .color(category.fill(look).color))
            labelColor = category.labelIsBlack(look) ? .black : .white
        } else if let category = tint(tile) {
            ctx.fill(shape, with: .color(category.folderFill(look).color))
            labelColor = category.folderLabelIsBlack(look) ? .black : .white
        } else {
            ctx.fill(shape, with: .color(.primary.opacity(tile.node == nil ? 0.08 : 0.12)))
            labelColor = .primary
        }
        if tile.status == .partial { hatch(box, shape: shape, in: &ctx) }
        if look.highContrast { ctx.stroke(shape, with: .color(.primary.opacity(0.4)), lineWidth: 1) }
        if noColor, let category = tile.category ?? tint(tile), box.width >= 40, box.height >= 28 {
            ctx.draw(Text(Image(systemName: category.symbol)).font(.system(size: 10 * scale)).foregroundColor(labelColor),
                     at: CGPoint(x: box.minX + 4, y: box.minY + 3), anchor: .topLeading)
        }
        var badgeWidth: CGFloat = 0
        if let id = tile.node, let kinds = badges[id], box.width >= Self.badgeMinimum.width, box.height >= Self.badgeMinimum.height {
            let glyphs = ctx.resolve(kinds.reduce(Text(verbatim: "")) { $0 + Text(Image(systemName: $1.symbol)) }
                .font(.system(size: 10 * scale)).foregroundColor(labelColor))
            badgeWidth = glyphs.measure(in: box.size).width + 4
            let point = tile.isFrame ? CGPoint(x: box.maxX - 4, y: box.minY + min(box.height, MapLayout.header) / 2)
                : CGPoint(x: box.maxX - 4, y: box.minY + 3)
            ctx.draw(glyphs, at: point, anchor: tile.isFrame ? .trailing : .topTrailing)
        }
        labels(tile, box: box, color: labelColor, badgeWidth: badgeWidth, in: &ctx)
    }

    private func hatch(_ box: CGRect, shape: Path, in context: inout GraphicsContext) {
        var ctx = context
        ctx.clip(to: shape)
        var lines = Path()
        var x = box.minX - box.height
        while x < box.maxX {
            lines.move(to: CGPoint(x: x, y: box.maxY))
            lines.addLine(to: CGPoint(x: x + box.height, y: box.minY))
            x += 6
        }
        ctx.stroke(lines, with: .color(.primary.opacity(0.25)), lineWidth: 1)
    }

    /// `badgeWidth`: room taken by the protection glyphs at the top-right, kept clear of the labels.
    private func labels(_ tile: MapTile, box: CGRect, color: Color, badgeWidth: CGFloat, in context: inout GraphicsContext) {
        let size = tile.status == .partial ? String(localized: "≥ \(Fmt.bytes(tile.bytes))") : Fmt.bytes(tile.bytes)
        let inset: CGFloat = noColor && (tile.category ?? tint(tile)) != nil && box.width >= 40 && box.height >= 28 ? 16 : 4
        if tile.isFrame {
            let font = Font.system(size: 11 * scale, weight: .semibold)
            let sizeText = context.resolve(Text(size).font(.system(size: 11 * scale)).foregroundColor(.secondary))
            let sizeWidth = sizeText.measure(in: box.size).width
            let showSize = sizeWidth + 8 + badgeWidth <= box.width - 40
            let room = box.width - 8 - badgeWidth - (showSize ? sizeWidth + 8 : 0)
            let y = box.minY + min(box.height, MapLayout.header) / 2
            if room > 12 {
                let title = fitted(tile.name, font: font, width: room, context: context)
                context.draw(context.resolve(Text(title).font(font).foregroundColor(color)),
                             at: CGPoint(x: box.minX + 4, y: y), anchor: .leading)
            }
            if showSize {
                context.draw(sizeText, at: CGPoint(x: box.maxX - 4 - badgeWidth, y: y), anchor: .trailing)
            }
            return
        }
        guard box.width >= 48, box.height >= 18 else { return }
        let font = Font.system(size: 10 * scale)
        let lineHeight = 13 * scale
        guard box.height >= lineHeight + 4 else { return }
        let title = fitted(tile.name, font: font, width: box.width - inset - 4 - badgeWidth, context: context)
        context.draw(context.resolve(Text(title).font(font).foregroundColor(color)),
                     at: CGPoint(x: box.minX + inset, y: box.minY + 2), anchor: .topLeading)
        if box.height >= 32 * scale {
            context.draw(context.resolve(Text(size).font(font).foregroundColor(color.opacity(0.8))),
                         at: CGPoint(x: box.minX + inset, y: box.minY + 2 + lineHeight), anchor: .topLeading)
        }
    }

    /// Middle-truncates `text` to fit `width`.
    private func fitted(_ text: String, font: Font, width: CGFloat, context: GraphicsContext) -> String {
        func fits(_ s: String) -> Bool {
            context.resolve(Text(s).font(font)).measure(in: CGSize(width: 10_000, height: 100)).width <= width
        }
        if fits(text) { return text }
        let chars = Array(text)
        var low = 0, high = chars.count
        while low < high {
            let mid = (low + high + 1) / 2
            let head = mid / 2 + mid % 2, tail = mid / 2
            if fits(String(chars.prefix(head)) + "…" + String(chars.suffix(tail))) { low = mid } else { high = mid - 1 }
        }
        guard low > 0 else { return "" }
        return String(chars.prefix(low / 2 + low % 2)) + "…" + String(chars.suffix(low / 2))
    }
}

/// Hover and selection outlines, redrawn without touching the cells.
private struct MapOverlay: View {
    let tiles: [MapTile]
    let hovered: Int?
    let selected: [Int]
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Canvas { context, _ in
            if let hovered, hovered < tiles.count, !selected.contains(hovered) {
                let box = tiles[hovered].rect.insetBy(dx: 0.5, dy: 0.5)
                context.stroke(Path(roundedRect: box, cornerRadius: 2), with: .color(.primary.opacity(0.6)), lineWidth: 1)
            }
            for selected in selected where selected < tiles.count {
                let box = tiles[selected].rect.insetBy(dx: 1, dy: 1)
                let accent: Color = activeState == .inactive ? .secondary : .accentColor
                context.stroke(Path(roundedRect: box, cornerRadius: 3), with: .color(accent), lineWidth: 2)
                context.stroke(Path(roundedRect: box.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 2),
                               with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1)
            }
        }
    }
}

/// Clickable path from the scan root to the scope (§3.1), 28 pt.
struct PathBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let crumbs = model.breadcrumbs
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.element.0) { index, crumb in
                    let last = index == crumbs.count - 1
                    Button { model.setScope(crumb.0) } label: {
                        Text(crumb.1).fontWeight(last ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    .disabled(last)
                    if !last {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 28)
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("路徑")
    }
}

/// Category legend with the unreadable-folder count at the trailing end (§3.1).
struct LegendRow: View {
    @ObservedObject var model: AppModel
    @State private var showUnreadable = false
    private let visibleCount = 5

    var body: some View {
        let totals = model.categoryTotals.filter { $0.bytes > 0 }
        HStack(spacing: 10) {
            ForEach(totals.prefix(visibleCount), id: \.category) { item in
                chip(item.category, bytes: item.bytes)
            }
            if totals.count > visibleCount {
                Menu("⋯") {
                    ForEach(totals.dropFirst(visibleCount), id: \.category) { item in
                        Button("\(item.category.title) \(Fmt.bytes(item.bytes))") { toggle(item.category) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("其他類別")
            }
            Spacer(minLength: 8)
            if !model.scopeUnreadable.isEmpty {
                Button { showUnreadable.toggle() } label: {
                    Label("\(model.scopeUnreadable.count) 個資料夾無法讀取", systemImage: "lock.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showUnreadable) { unreadableList }
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    private func chip(_ category: FileCategory, bytes: Int64) -> some View {
        let active = model.highlight == .category(category)
        let dimmed = model.highlight != nil && !active
        return Button { toggle(category) } label: {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(category.color).frame(width: 10, height: 10)
                Text(category.title).fontWeight(active ? .semibold : .regular)
                Text(Fmt.bytes(bytes)).foregroundStyle(.secondary).monospacedDigit()
            }
            .opacity(dimmed ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .help(active ? String(localized: "取消標示") : String(localized: "只標示「\(category.title)」"))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func toggle(_ category: FileCategory) {
        model.highlight = model.highlight == .category(category) ? nil : .category(category)
    }

    private var unreadableList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("沒有權限讀取這些資料夾").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.scopeUnreadable.prefix(200), id: \.self) { path in
                        Text(Fmt.tildePath(path)).font(.callout).textSelection(.enabled)
                    }
                    if model.scopeUnreadable.count > 200 {
                        Text("還有 \(model.scopeUnreadable.count - 200) 個").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .frame(width: 380)
    }
}

/// Fixed-position line under the map: the summary, or the hovered cell (§3.4).
struct InfoBar: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 10)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
