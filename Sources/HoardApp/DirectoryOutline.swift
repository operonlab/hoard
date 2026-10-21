import AppKit
import SwiftUI
import ScanCore

func protectionNames(_ kinds: [ProtectionKind]) -> String {
    if kinds.contains(.lock) && kinds.contains(.guarded) { return String(localized: "鎖定、守護") }
    if kinds.contains(.lock) { return String(localized: "鎖定") }
    if kinds.contains(.guarded) { return String(localized: "守護") }
    return ""
}

/// 清單 mode of the space map (§3.5): the scope as an outline. NSOutlineView keeps it fast at
/// hundreds of thousands of rows.
struct DirectoryOutline: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @AppStorage(TextScale.key) private var scaleIndex = 1

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = MenuOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = true
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.open(_:))
        outline.menuHandler = { [weak coordinator = context.coordinator] event in coordinator?.menu(for: event) }
        outline.keyHandler = { [weak coordinator = context.coordinator] event in coordinator?.key(event) ?? false }
        let columns: [(String, String, CGFloat, Bool)] = [
            ("name", String(localized: "名稱"), 260, true), ("size", String(localized: "大小"), 110, false), ("percent", String(localized: "佔上層"), 120, false),
            ("files", String(localized: "檔案數"), 90, false), ("date", String(localized: "修改日期"), 110, false)
        ]
        for (key, title, width, ascending) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = width
            column.minWidth = key == "name" ? 170 : 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: ascending)
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        outline.setAccessibilityLabel(String(localized: "清單，\(model.scopeName)"))
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        context.coordinator.outline = outline
        context.coordinator.apply(scale: TextScale.factor(scaleIndex))
        outline.reloadData()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.outline != nil else { return }
        coordinator.model = model
        coordinator.apply(scale: TextScale.factor(scaleIndex))
        if coordinator.lastRevision != model.revision || coordinator.lastScope != model.scope
            || coordinator.lastProtection != model.protection.version {
            coordinator.lastRevision = model.revision
            coordinator.lastScope = model.scope
            coordinator.lastProtection = model.protection.version
            coordinator.refresh()
        }
        coordinator.syncSelection()
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var model: AppModel
        weak var outline: MenuOutlineView?
        var lastRevision = -1
        var lastScope: NodeID = -1
        var lastProtection = -1
        private var scale: Double = 0
        private var sortedCache: [NodeID: [NodeID]] = [:]
        private var expandedPaths: Set<String> = []
        private var syncing = false

        init(model: AppModel) { self.model = model }

        func apply(scale: Double) {
            guard scale != self.scale, let outline else { return }
            self.scale = scale
            outline.rowHeight = (22 * scale).rounded()
            outline.reloadData()
        }

        // MARK: Data

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let tree = model.tree else { return 0 }
            let id = (item as? NSNumber)?.int32Value ?? model.scope
            guard Int(id) < tree.nodeCount else { return 0 }
            return children(of: id, tree: tree).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let tree = model.tree else { return NSNumber(value: FileTree.root) }
            let id = (item as? NSNumber)?.int32Value ?? model.scope
            return NSNumber(value: children(of: id, tree: tree)[index])
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let tree = model.tree, let id = (item as? NSNumber)?.int32Value else { return false }
            return tree[id].isDirectory && tree[id].firstChild >= 0
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            refresh()
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let tree = model.tree, let id = (item as? NSNumber)?.int32Value,
                  let column = tableColumn else { return nil }
            let node = tree[id]
            let key = column.identifier.rawValue
            let cell = (outlineView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView) ?? makeCell(key: key)
            guard let label = cell.textField else { return cell }
            label.font = .systemFont(ofSize: 13 * scale)
            label.textColor = .labelColor
            cell.toolTip = nil
            let parent = node.parent >= 0 ? tree[node.parent] : node
            switch key {
            case "name":
                let kinds = model.protectionKinds(of: id)
                if kinds.isEmpty {
                    label.stringValue = node.name
                    label.setAccessibilityLabel(nil)
                } else {
                    label.attributedStringValue = Self.name(node.name, glyphs: kinds, font: label.font ?? .systemFont(ofSize: 13))
                    label.setAccessibilityLabel(String(localized: "\(node.name)，受保護，\(protectionNames(kinds))"))
                }
                cell.imageView?.image = FileIcons.icon(forPath: tree.path(of: id), isDirectory: node.isDirectory)
                cell.toolTip = tree.path(of: id)
            case "size":
                label.stringValue = Fmt.size(node)
                label.textColor = node.status == .unavailable ? .secondaryLabelColor : .labelColor
                (cell as? StatusCell)?.locked = node.status != .complete
                cell.toolTip = node.status == .partial ? String(localized: "有些內容沒有權限讀取，實際大小至少這麼多")
                    : node.status == .unavailable ? String(localized: "沒有權限讀取這個資料夾") : nil
                label.setAccessibilityLabel(Fmt.sizeSpoken(node))
            case "percent":
                label.stringValue = Fmt.share(node, of: parent)
                (cell as? PercentCell)?.ratio = Fmt.ratio(node, of: parent) ?? 0
                if Fmt.ratio(node, of: parent) == nil { cell.toolTip = String(localized: "大小未知") }
            case "files":
                label.stringValue = node.status == .unavailable ? "—" : Fmt.count(node.fileCount)
            case "date":
                let date = Fmt.date(seconds: node.modTime)
                label.stringValue = Fmt.relative(date)
                cell.toolTip = Fmt.relativeAndLong(date)
            default: break
            }
            return cell
        }

        /// "name 🔒": the kind glyphs after the name, in the secondary label color.
        private static func name(_ name: String, glyphs: [ProtectionKind], font: NSFont) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            let text = NSMutableAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.labelColor,
                                                                            .paragraphStyle: paragraph])
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.85, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
            for kind in glyphs {
                guard let image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: protectionNames([kind]))?
                    .withSymbolConfiguration(config) else { continue }
                let attachment = NSTextAttachment()
                attachment.image = image
                text.append(NSAttributedString(string: " ", attributes: [.font: font]))
                text.append(NSAttributedString(attachment: attachment))
            }
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            return text
        }

        // MARK: Selection and actions

        private var selectedIDs: [NodeID] {
            guard let outline else { return [] }
            return outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? NSNumber)?.int32Value }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline else { return }
            // `selectedRow` is the row added to the selection last: the inspector shows that one.
            let primary = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? NSNumber)?.int32Value : nil
            model.select(selectedIDs, primary: primary)
        }

        @objc func open(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0,
                  let id = (outline.item(atRow: outline.clickedRow) as? NSNumber)?.int32Value else { return }
            model.enter(id)
        }

        /// Return opens, Space previews, Esc clears (§3.4).
        func key(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 36, 76:  // return, enter
                guard let id = selectedIDs.first else { return false }
                model.enter(id)
                return true
            case 49:  // space
                guard !selectedIDs.isEmpty else { return false }
                model.quickLook(selectedIDs)
                return true
            case 53:  // escape
                outline?.deselectAll(nil)
                model.select(nil)
                return true
            default:
                return false
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let tree = model.tree, let id = (notification.userInfo?["NSObject"] as? NSNumber)?.int32Value else { return }
            expandedPaths.insert(tree.path(of: id))
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let tree = model.tree, let id = (notification.userInfo?["NSObject"] as? NSNumber)?.int32Value else { return }
            expandedPaths.remove(tree.path(of: id))
        }

        func refresh() {
            guard let outline, let tree = model.tree else { return }
            sortedCache.removeAll(keepingCapacity: true)
            // Paths survive snapshot replacements and node ID shifts after live mutations.
            syncing = true
            outline.reloadData()
            for path in expandedPaths.sorted(by: { $0.count < $1.count }) {
                guard let id = tree.lookup(path: path), isBelowScope(id, tree: tree) else { continue }
                outline.expandItem(NSNumber(value: id))
            }
            outline.setAccessibilityLabel(String(localized: "清單，\(model.scopeName)"))
            syncing = false
            syncSelection()
        }

        func syncSelection() {
            guard let outline, let tree = model.tree else { return }
            let wanted = model.selectedIDs.filter { Int($0) < tree.nodeCount && isBelowScope($0, tree: tree) }
            if Set(wanted) == Set(selectedIDs) { return }
            syncing = true
            // Expand every ancestor first: each expansion shifts the rows below it.
            for id in wanted {
                var ancestors: [NodeID] = []
                var current = tree[id].parent
                while current >= 0 && current != model.scope { ancestors.append(current); current = tree[current].parent }
                for ancestor in ancestors.reversed() { outline.expandItem(NSNumber(value: ancestor)) }
            }
            let rows = IndexSet(wanted.map { outline.row(forItem: NSNumber(value: $0)) }.filter { $0 >= 0 })
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            if let last = wanted.last {
                let row = outline.row(forItem: NSNumber(value: last))
                if row >= 0 { outline.scrollRowToVisible(row) }
            }
            syncing = false
        }

        private func isBelowScope(_ id: NodeID, tree: FileTree) -> Bool {
            var current = tree[id].parent
            while current >= 0 {
                if current == model.scope { return true }
                current = tree[current].parent
            }
            return false
        }

        func menu(for event: NSEvent) -> NSMenu? {
            guard let outline else { return nil }
            let point = outline.convert(event.locationInWindow, from: nil)
            let row = outline.row(at: point)
            guard row >= 0, let clicked = (outline.item(atRow: row) as? NSNumber)?.int32Value else { return nil }
            let ids = selectedIDs.contains(clicked) ? selectedIDs : [clicked]
            let menu = NSMenu()
            add(String(localized: "快速查看"), #selector(quickLook(_:)), ids, to: menu)
            add(String(localized: "在 Finder 中顯示"), #selector(reveal(_:)), ids, to: menu)
            add(String(localized: "拷貝路徑"), #selector(copyPath(_:)), ids, to: menu)
            menu.addItem(.separator())
            let kinds = ids.count == 1 ? model.protectionKinds(of: ids[0]) : []
            for kind in [ProtectionKind.lock, .guarded] {
                let covered = kinds.contains(kind)
                let item = add(covered ? (kind == .lock ? String(localized: "已鎖定") : String(localized: "已守護"))
                                       : (kind == .lock ? String(localized: "鎖定…") : String(localized: "守護…")),
                               kind == .lock ? #selector(lock(_:)) : #selector(guardItem(_:)), ids, to: menu)
                item.isEnabled = !covered && ids.count == 1 && model.protection.loaded
            }
            menu.addItem(.separator())
            let trash = add(String(localized: "丟到垃圾桶…"), #selector(trash(_:)), ids, to: menu)
            if let reason = ids.compactMap({ model.trashBlockReason($0) }).first {
                trash.isEnabled = false
                trash.toolTip = reason
            }
            menu.autoenablesItems = false
            return menu
        }

        @discardableResult
        private func add(_ title: String, _ action: Selector, _ ids: [NodeID], to menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = ids.map { NSNumber(value: $0) }
            menu.addItem(item)
            return item
        }

        private func ids(_ item: NSMenuItem) -> [NodeID] {
            (item.representedObject as? [NSNumber])?.map(\.int32Value) ?? []
        }

        @objc private func quickLook(_ item: NSMenuItem) { model.quickLook(ids(item)) }
        @objc private func reveal(_ item: NSMenuItem) { model.reveal(ids(item)) }
        @objc private func copyPath(_ item: NSMenuItem) { model.copyPaths(ids(item)) }
        @objc private func trash(_ item: NSMenuItem) { model.requestTrash(ids(item)) }
        @objc private func lock(_ item: NSMenuItem) { ids(item).first.map { model.requestProtect($0, kind: .lock) } }
        @objc private func guardItem(_ item: NSMenuItem) { ids(item).first.map { model.requestProtect($0, kind: .guarded) } }

        // MARK: Sorting

        private func children(of id: NodeID, tree: FileTree) -> [NodeID] {
            if let cached = sortedCache[id] { return cached }
            let descriptor = outline?.sortDescriptors.first
            let key = descriptor?.key ?? "size"
            let ascending = descriptor?.ascending ?? false
            let list = tree.children(of: id).sorted { a, b in
                let x = tree[a], y = tree[b]
                // Unknown sizes go last in either direction (§7.1).
                if (x.status == .unavailable) != (y.status == .unavailable) { return y.status == .unavailable }
                let order: ComparisonResult
                switch key {
                case "name": order = x.name.localizedStandardCompare(y.name)
                case "files": order = x.fileCount == y.fileCount ? .orderedSame : x.fileCount < y.fileCount ? .orderedAscending : .orderedDescending
                case "date": order = x.modTime == y.modTime ? .orderedSame : x.modTime < y.modTime ? .orderedAscending : .orderedDescending
                default: order = x.totalAlloc == y.totalAlloc ? .orderedSame : x.totalAlloc < y.totalAlloc ? .orderedAscending : .orderedDescending
                }
                if order == .orderedSame { return x.name < y.name }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            sortedCache[id] = list
            return list
        }

        private func makeCell(key: String) -> NSTableCellView {
            let cell: NSTableCellView = key == "percent" ? PercentCell() : key == "size" ? StatusCell() : NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier(key)
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            if key != "name" { label.alignment = key == "percent" ? .left : .right }
            cell.addSubview(label)
            cell.textField = label
            if key == "name" {
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                cell.imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalTo: icon.heightAnchor),
                    icon.heightAnchor.constraint(equalTo: cell.heightAnchor, multiplier: 0.75),
                    label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5)
                ])
            } else {
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: key == "size" ? 18 : 5).isActive = true
            }
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
    }
}

final class MenuOutlineView: NSOutlineView {
    var menuHandler: ((NSEvent) -> NSMenu?)?
    var keyHandler: ((NSEvent) -> Bool)?
    override func menu(for event: NSEvent) -> NSMenu? { menuHandler?(event) }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

/// Size cell with a lock for partial / unreadable sizes (§7.1).
private final class StatusCell: NSTableCellView {
    var locked = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard locked, let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) else { return }
        let side = min(11, bounds.height - 4)
        let rect = NSRect(x: 4, y: (bounds.height - side) / 2, width: side, height: side)
        NSColor.secondaryLabelColor.set()
        image.isTemplate = true
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.6)
    }
}

private final class PercentCell: NSTableCellView {
    var ratio: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bar = NSRect(x: 4, y: 2, width: max(0, bounds.width - 8) * min(1, max(0, ratio)), height: 3)
        NSColor.controlAccentColor.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }
}
