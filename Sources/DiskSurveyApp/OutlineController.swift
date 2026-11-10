import AppKit
import DiskSurveyCore
import DiskSurveyMapView

/// The hierarchy as an `NSOutlineView` reading straight from the tree.
///
/// Items are node ids boxed in `NSNumber` (compared by value, so they survive reloads). Rows
/// are produced lazily from the tree's own size-sorted child lists; other sort orders are
/// sorted per expanded folder on demand. Nothing here walks the tree.
@MainActor
final class OutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    enum SortKey: String { case name, size, percent, items, modified }

    let scrollView = NSScrollView()
    let outlineView = DiskSurveyOutlineView()
    private unowned let model: WindowModel

    private var tree: FileTree?
    private var generation = -1
    private var epoch = -1
    private var metric = SizeMode.allocated
    private var packagesAsItems = false
    private var scheme = PaletteScheme.light
    private var kindColors: [RGB] = []
    private var sortKey = SortKey.size
    private var ascending = false
    /// Expanded folders, tracked here so they can be restored (by path) across new scans.
    private var expanded: Set<NodeID> = [0]
    private var sortedChildren: [NodeID: [NodeID]] = [:]
    private var isReloading = false
    private var applyingSelection = false
    private var appliedSelection: Set<NodeID> = []
    private var isDark = false

    private static let columns: [(id: String, title: String, width: CGFloat, min: CGFloat, key: SortKey)] = [
        ("name", "Name", 208, 120, .name),
        ("size", "Size", 88, 66, .size),
        ("percent", "%", 44, 40, .percent),
        ("items", "Items", 44, 40, .items),
        ("modified", "Modified", 80, 70, .modified),
    ]

    init(model: WindowModel) {
        self.model = model
        super.init()

        for spec in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.min
            column.headerCell.alignment = spec.id == "name" ? .left : .right
            // Sizes, counts and dates read best largest/newest first.
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.key.rawValue, ascending: spec.key == .name)
            column.resizingMask = spec.id == "name" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            // Dates are a click away in the header menu; by default the names get the room.
            column.isHidden = spec.id == "modified"
            outlineView.addTableColumn(column)
        }
        outlineView.outlineTableColumn = outlineView.tableColumns[0]
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // Otherwise the name column widens to its longest visible name and pushes the sizes out of view.
        outlineView.autoresizesOutlineColumn = false
        outlineView.style = .inset
        // The inset style's 17 pt between columns costs the names about 36 pt for nothing.
        outlineView.intercellSpacing = NSSize(width: 8, height: 0)
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 22
        outlineView.usesAutomaticRowHeights = false
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsTypeSelect = true
        outlineView.indentationPerLevel = 14
        if !LaunchOptions.current.isHarness {
            outlineView.autosaveName = "DiskSurveyOutline"
            outlineView.autosaveTableColumns = true
        }
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked)
        outlineView.controller = self
        outlineView.setDraggingSourceOperationMask([.copy, .delete], forLocal: false)
        outlineView.setAccessibilityLabel("Folder outline")
        outlineView.sortDescriptors = [NSSortDescriptor(key: SortKey.size.rawValue, ascending: false)]

        let headerMenu = NSMenu()
        headerMenu.delegate = self
        outlineView.headerView?.menu = headerMenu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Keep the columns within the pane: the name column takes up the slack.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewResized), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pathIconLoaded(_:)), name: IconCache.didLoadPathIcon, object: nil)
        isDark = Self.isDark(outlineView.effectiveAppearance)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// A bundle's own icon arrived: show it if that row is on screen.
    @objc private func pathIconLoaded(_ note: Notification) {
        guard let tree, let path = note.userInfo?["path"] as? String, let node = tree.node(atPath: path) else { return }
        let row = outlineView.row(forItem: NSNumber(value: node))
        let column = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard row >= 0, column >= 0, outlineView.rowView(atRow: row, makeIfNecessary: false) != nil else { return }
        outlineView.reloadData(forRowIndexes: [row], columnIndexes: [column])
    }

    /// Icons are rasterized per appearance, so the rows on screen need the other set.
    func effectiveAppearanceChanged() {
        let dark = Self.isDark(outlineView.effectiveAppearance)
        guard dark != isDark else { return }
        isDark = dark
        refreshLiveRows(nameOnly: true)
    }

    private var lastClipWidth: CGFloat = 0

    @objc private func clipViewResized() {
        let width = scrollView.contentView.bounds.width
        guard abs(width - lastClipWidth) > 0.5 else { return }
        lastClipWidth = width
        outlineView.sizeToFit()
    }

    // MARK: Inputs

    /// Brings the outline in line with the model. Called on every SwiftUI update; cheap when
    /// nothing changed.
    ///
    /// Only a change of structure (another tree, packages opened or closed, a different child
    /// order) reloads the outline. A change that merely alters what the rows show (sizes in the
    /// other mode, badge colours of the other scheme) reconfigures the row views that exist, in
    /// place: `reloadData()` would throw every one of them away and build them again.
    func update(
        tree newTree: FileTree?, generation newGeneration: Int, epoch newEpoch: Int, selection: Set<NodeID>, primary: NodeID?,
        metric newMetric: SizeMode, packagesAsItems newPackages: Bool, scheme newScheme: PaletteScheme
    ) {
        let treeChanged = newGeneration != generation
        let schemeChanged = newScheme != scheme
        let packagesChanged = newPackages != packagesAsItems
        let metricChanged = newMetric != metric
        scheme = newScheme
        packagesAsItems = newPackages

        var structural = false
        if treeChanged {
            if newEpoch != epoch, let old = tree, let new = newTree {
                // A new scan snapshot: ids changed, so carry the expanded folders over by path.
                let paths = expanded.filter { Int($0) < old.count && $0 != 0 }.map { old.path(of: $0) }
                expanded = Set(paths.compactMap { new.node(atPath: $0) })
                expanded.insert(0)
            } else if let new = newTree {
                expanded = expanded.filter { Int($0) < new.count && !new.isRemoved($0) }
                expanded.insert(0)
            } else {
                expanded = [0]
            }
            tree = newTree
            generation = newGeneration
            epoch = newEpoch
            kindColors = newTree?.kindColors(scheme: scheme) ?? []
            metric = newMetric
            reload()
            structural = true
        } else {
            if schemeChanged { kindColors = tree?.kindColors(scheme: scheme) ?? [] }
            if packagesChanged {
                // Changes which rows can be expanded and how many children they have.
                metric = newMetric
                reload()
                structural = true
            } else if metricChanged {
                structural = applyMetric(newMetric)
            } else if schemeChanged {
                refreshLiveRows(nameOnly: true)
            }
        }
        applySelection(selection, primary: primary, force: structural)
    }

    private func reload() {
        sortedChildren.removeAll(keepingCapacity: true)
        isReloading = true
        applyingSelection = true
        outlineView.reloadData()
        restoreExpansion()
        applyingSelection = false
        isReloading = false
        appliedSelection = []
    }

    /// Expands every folder in `expanded` that is not, as one batch: on its own each
    /// `expandItem` re-tiles the visible rows.
    private func restoreExpansion() {
        guard let tree else { return }
        outlineView.beginUpdates()
        // Parents before children, or the children have no rows to expand.
        for node in expanded.sorted(by: { tree.depth(of: $0) < tree.depth(of: $1) }) {
            outlineView.expandItem(NSNumber(value: node))
        }
        outlineView.endUpdates()
    }

    /// Switches the size mode. Returns whether rows moved (so that the selection has to be
    /// applied again).
    ///
    /// Sorted by name, items or date the order does not depend on the mode. Sorted by size it
    /// may: on-disk mode shows the tree's own order, logical mode a sort by logical size. Only
    /// the folders whose order really differs are reloaded.
    private func applyMetric(_ newMetric: SizeMode) -> Bool {
        guard let tree, sortKey == .size || sortKey == .percent else {
            metric = newMetric
            refreshLiveRows()
            return false
        }
        let open = expanded.filter { Int($0) < tree.count && !tree.isRemoved($0) && outlineView.isItemExpanded(NSNumber(value: $0)) }
        // Comparing orders is linear in the children shown; past a point a plain reload is no worse.
        guard open.reduce(0, { $0 + tree.childCount(of: $1) }) <= 200_000 else {
            metric = newMetric
            reload()
            return true
        }
        var before: [NodeID: [NodeID]] = [:]
        for folder in open { before[folder] = order(of: folder, in: tree) }
        metric = newMetric
        sortedChildren.removeAll(keepingCapacity: true)
        let changed = Set(open.filter { order(of: $0, in: tree) != before[$0] })
        guard !changed.isEmpty else {
            refreshLiveRows()
            return false
        }
        // Reloading a folder reloads everything below it, so only the outermost ones are needed.
        let outermost = changed.filter { folder in !tree.ancestors(of: folder).contains { changed.contains($0) } }
        // Reloading collapses the folders below; neither that nor the re-expansion is the user's doing.
        isReloading = true
        applyingSelection = true
        for folder in outermost { outlineView.reloadItem(NSNumber(value: folder), reloadChildren: true) }
        restoreExpansion()
        applyingSelection = false
        isReloading = false
        appliedSelection = []
        refreshLiveRows()
        return true
    }

    /// The children of `folder` in the order the outline shows them.
    private func order(of folder: NodeID, in tree: FileTree) -> [NodeID] {
        (0 ..< tree.childCount(of: folder)).map { child(of: folder, at: $0, in: tree) }
    }

    /// Reconfigures the row views that exist (the visible rows and the few kept ready around
    /// them) without replacing them. Other rows are configured when they scroll in.
    private func refreshLiveRows(nameOnly: Bool = false) {
        var rows = IndexSet()
        outlineView.enumerateAvailableRowViews { _, row in rows.insert(row) }
        guard !rows.isEmpty else { return }
        var columns = IndexSet(integersIn: 0 ..< outlineView.numberOfColumns)
        if nameOnly {
            let name = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            guard name >= 0 else { return }
            columns = [name]
        }
        outlineView.reloadData(forRowIndexes: rows, columnIndexes: columns)
    }

    // MARK: Children

    private var usesNativeOrder: Bool { sortKey == .size || sortKey == .percent ? metric == .allocated : false }

    private func isExpandable(_ node: NodeID, in tree: FileTree) -> Bool {
        guard tree.isDirectory(node), tree.childCount(of: node) > 0 else { return false }
        if packagesAsItems, node != tree.root, tree.flags(of: node).contains(.package) { return false }
        return true
    }

    private func child(of node: NodeID, at index: Int, in tree: FileTree) -> NodeID {
        let count = tree.childCount(of: node)
        if usesNativeOrder {
            return tree.child(of: node, at: ascending ? count - 1 - index : index)
        }
        if let sorted = sortedChildren[node], sorted.count == count { return sorted[index] }
        let sorted = sort(Array(tree.children(of: node)), in: tree)
        sortedChildren[node] = sorted
        return sorted[index]
    }

    private func sort(_ nodes: [NodeID], in tree: FileTree) -> [NodeID] {
        let ascending = ascending
        switch sortKey {
        case .name:
            // Finder-like ordering is expensive; huge folders fall back to a plain case-insensitive one.
            let names = nodes.map { ($0, tree.name(of: $0)) }
            let sorted: [(NodeID, String)]
            if names.count <= 20_000 {
                sorted = names.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
            } else {
                let folded = names.map { ($0.0, $0.1.lowercased()) }
                sorted = folded.sorted { $0.1 < $1.1 }
            }
            return ascending ? sorted.map(\.0) : sorted.reversed().map(\.0)
        case .size, .percent:
            let sorted = nodes.sorted { tree.logicalSize(of: $0) > tree.logicalSize(of: $1) }
            return ascending ? sorted.reversed() : sorted
        case .items:
            let sorted = nodes.sorted { tree.fileCount(of: $0) > tree.fileCount(of: $1) }
            return ascending ? sorted.reversed() : sorted
        case .modified:
            let sorted = nodes.sorted { tree.modified(of: $0) > tree.modified(of: $1) }
            return ascending ? sorted.reversed() : sorted
        }
    }

    private func node(_ item: Any?) -> NodeID? { (item as? NSNumber)?.uint32Value }

    /// The rows of the drag in progress and the tree generation their ids belong to.
    private var dragged: (nodes: [NodeID], generation: Int)?

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let tree else { return 0 }
        guard let node = node(item) else { return 1 }
        return isExpandable(node, in: tree) ? tree.childCount(of: node) : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let tree, let node = node(item) else { return NSNumber(value: 0 as UInt32) }
        return NSNumber(value: child(of: node, at: index, in: tree))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let tree, let node = node(item), Int(node) < tree.count else { return false }
        return isExpandable(node, in: tree)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let tree, let node = node(item), Int(node) < tree.count, !tree.flags(of: node).contains(.synthetic) else { return nil }
        return tree.url(of: node) as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        // What is dragged is what was grabbed — not necessarily the selection (a drag can start
        // on an unselected row). Remember it with the tree it belongs to.
        dragged = (draggedItems.compactMap { node($0) }, model.treeGeneration)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let (nodes, generation) = dragged else { return }
        dragged = nil
        // The tree changed during the drag (a scan snapshot, a rescan): the ids may mean other items now.
        guard generation == model.treeGeneration, !nodes.isEmpty else { return }
        if operation.contains(.delete) {
            model.requestTrash(nodes: nodes)
        } else if operation.contains(.move) {
            model.reconcileMissing(nodes)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key.flatMap(SortKey.init) else { return }
        sortKey = key
        ascending = descriptor.ascending
        let selection = model.selection
        reload()
        applySelection(selection, primary: model.primarySelection, force: true)
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let tree, let node = node(item), Int(node) < tree.count else { return nil }
        return tree.name(of: node)
    }

    // MARK: Delegate

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isReloading, let node = node(notification.userInfo?["NSObject"]) else { return }
        expanded.insert(node)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading, let node = node(notification.userInfo?["NSObject"]) else { return }
        expanded.remove(node)
        sortedChildren[node] = nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        var nodes = Set<NodeID>()
        for row in outlineView.selectedRowIndexes {
            if let node = node(outlineView.item(atRow: row)) { nodes.insert(node) }
        }
        let primaryRow = outlineView.selectedRow
        let primary = primaryRow >= 0 ? node(outlineView.item(atRow: primaryRow)) : nil
        appliedSelection = nodes
        model.select(nodes, primary: primary)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        return outlineView.makeView(withIdentifier: id, owner: self) as? NSTableRowView ?? {
            DebugCounters.rowViewsCreated += 1
            let row = NSTableRowView()
            row.identifier = id
            return row
        }()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tree, let column = tableColumn, let node = node(item), Int(node) < tree.count else { return nil }
        DebugCounters.cellConfigurations += 1
        let size = metric == .allocated ? tree.size(of: node) : tree.logicalSize(of: node)
        switch column.identifier.rawValue {
        case "name":
            let cell = reuse(NameCellView.self, id: "name")
            let flags = tree.flags(of: node)
            var badge: NSColor?
            if !flags.contains(.directory) || flags.contains(.package) {
                let kind = Int(tree.kind(of: node))
                if kind < kindColors.count { badge = kindColors[kind].nsColor }
            }
            cell.configure(
                name: node == tree.root ? rootTitle(tree) : tree.name(of: node), icon: IconCache.shared.smallIcon(for: tree, node: node, dark: isDark),
                badge: badge, status: Self.status(for: flags), dimmed: flags.contains(.unreadable) || flags.contains(.dataless))
            return cell
        case "size":
            let cell = reuse(SizeCellView.self, id: "size")
            var fraction = 1.0
            if let parent = tree.parent(of: node) {
                let whole = metric == .allocated ? tree.size(of: parent) : tree.logicalSize(of: parent)
                fraction = whole > 0 ? Double(size) / Double(whole) : 0
            }
            cell.configure(text: Format.bytes(size), fraction: fraction)
            return cell
        case "percent":
            let cell = reuse(TextCellView.self, id: "text")
            if let parent = tree.parent(of: node) {
                let whole = metric == .allocated ? tree.size(of: parent) : tree.logicalSize(of: parent)
                cell.configure(Format.percent(size, of: whole))
            } else {
                cell.configure("100%")
            }
            return cell
        case "items":
            let cell = reuse(TextCellView.self, id: "text")
            cell.configure(tree.isDirectory(node) ? Format.compactCount(tree.fileCount(of: node)) : "—")
            return cell
        default:
            let cell = reuse(TextCellView.self, id: "text")
            cell.configure(Format.date(tree.modified(of: node)))
            return cell
        }
    }

    private func rootTitle(_ tree: FileTree) -> String {
        model.title
    }

    private static func status(for flags: NodeFlags) -> (symbol: String, help: String)? {
        if flags.contains(.unreadable) { return ("lock.fill", "Disk Survey has no permission to read this folder") }
        if flags.contains(.dataless) { return ("icloud", "Stored in the cloud; takes no space on this disk") }
        if flags.contains(.mountPoint) { return ("externaldrive", "Another volume is mounted here") }
        if flags.contains(.hardLinkDuplicate) { return ("link", "Hard link to a file already counted elsewhere") }
        if flags.contains(.symlink) { return ("arrow.turn.up.right", "Symbolic link") }
        return nil
    }

    private func reuse<T: NSView>(_ type: T.Type, id: String) -> T {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? T { return view }
        let view = T(frame: .zero)
        view.identifier = identifier
        return view
    }

    // MARK: Selection sync

    /// Shows the model's selection: expands the folders above each selected node (bounded),
    /// selects the rows and scrolls the primary one into view.
    private func applySelection(_ selection: Set<NodeID>, primary: NodeID?, force: Bool) {
        guard let tree else { return }
        guard force || selection != appliedSelection else { return }
        appliedSelection = selection
        applyingSelection = true
        defer { applyingSelection = false }

        var rows = IndexSet()
        var primaryRow: Int?
        let nodes = selection.count <= 500 ? Array(selection) : Array(selection.prefix(500))
        // One batch for all the expansions: separately, each one updates the visible rows, and a
        // file ten levels down builds several screens of row views that are replaced at once.
        outlineView.beginUpdates()
        for node in nodes where Int(node) < tree.count && !tree.isRemoved(node) {
            // Expanding is only worth it for a handful; a big selection shows what is visible.
            if nodes.count <= 20 || node == primary { expandAncestors(of: node, in: tree) }
            let row = visibleRow(for: node, in: tree)
            if row >= 0 {
                rows.insert(row)
                if node == primary || primaryRow == nil { primaryRow = row }
            }
        }
        outlineView.endUpdates()
        if rows != outlineView.selectedRowIndexes {
            outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        }
        if let primaryRow, !force || !rows.isEmpty {
            scrollToReveal(primaryRow)
        }
    }

    /// The row of `node`, or of its nearest ancestor that has one (inside a collapsed package
    /// or an unexpanded folder); -1 if there is none.
    private func visibleRow(for node: NodeID, in tree: FileTree) -> Int {
        var target = node
        var row = outlineView.row(forItem: NSNumber(value: target))
        while row < 0, let parent = tree.parent(of: target) {
            target = parent
            row = outlineView.row(forItem: NSNumber(value: target))
        }
        return row
    }

    /// Scrolls `row` into view with two rows of context, if it is not comfortably visible.
    private func scrollToReveal(_ row: Int) {
        let visible = outlineView.rows(in: outlineView.visibleRect)
        if !visible.contains(row) || row >= visible.upperBound - 1 {
            outlineView.withoutLiveResize {
                outlineView.scrollRowToVisible(min(row + 2, outlineView.numberOfRows - 1))
                outlineView.scrollRowToVisible(max(row - 2, 0))
                outlineView.scrollRowToVisible(row)
            }
        }
    }

    private func expandAncestors(of node: NodeID, in tree: FileTree) {
        for ancestor in tree.ancestors(of: node).reversed() where !outlineView.isItemExpanded(NSNumber(value: ancestor)) {
            guard isExpandable(ancestor, in: tree) else { break }
            outlineView.expandItem(NSNumber(value: ancestor))
            expanded.insert(ancestor)
        }
    }

    // MARK: Actions

    @objc private func doubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = node(outlineView.item(atRow: row)) else { return }
        model.zoom(to: node)
    }

    func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, let node = node(outlineView.item(atRow: row)) else { return nil }
        if !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            model.select(model.selection, primary: node)
        }
        return model.contextMenu()
    }

    /// Keys the outline handles like the map does. Returns whether the event was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.charactersIgnoringModifiers == " ", modifiers.isEmpty {
            model.toggleQuickLook()
            return true
        }
        // Delete alone does nothing, as in the map and in Finder: Move to Trash is ⌘⌫, which
        // arrives through the File menu's key equivalent before it gets here.
        switch event.specialKey {
        case .carriageReturn where modifiers.isEmpty, .enter where modifiers.isEmpty:
            model.zoomIntoSelection()
            return true
        default:
            return false
        }
    }

    // MARK: Header menu (column visibility)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in outlineView.tableColumns where column.identifier.rawValue != "name" {
            let item = NSMenuItem(title: column.title == "%" ? "Percentage" : column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column
            item.state = column.isHidden ? .off : .on
            menu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.isHidden.toggle()
    }
}

/// Outline view that forwards a few keys and context clicks to its controller.
final class DiskSurveyOutlineView: NSOutlineView {
    weak var controller: OutlineController?

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return controller?.contextMenu(forRow: row) ?? super.menu(for: event)
    }

    /// Lets the self-test put the outline into the live-resize state without a person dragging.
    var liveResizeOverride: Bool?
    private var suppressesLiveResize = false

    override var inLiveResize: Bool { suppressesLiveResize ? false : liveResizeOverride ?? super.inLiveResize }

    /// Runs a programmatic scroll as if no live resize were going on.
    ///
    /// While a table is in a live resize (window edge, divider, the inspector sliding in or
    /// out, which can linger) it keeps the row views it has and only adds to them, as one
    /// contiguous range. That suits a resize, where rows come and go at the bottom edge. For a
    /// jump of the selection across thousands of rows it means building a view for every row
    /// between the old and the new position: seconds to half a minute of hang, and a pile of
    /// views that slows every later update. With the state masked the table swaps the old
    /// screenful for the new one, as it does at any other time.
    func withoutLiveResize(_ body: () -> Void) {
        let previous = suppressesLiveResize
        suppressesLiveResize = true
        body()
        suppressesLiveResize = previous
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.effectiveAppearanceChanged()
    }
}

// MARK: - Cells

/// Icon (with a dot in the file kind's map colour), name and an optional status symbol.
final class NameCellView: NSTableCellView {
    private let icon = NSImageView()
    private let badge = NSView()
    private let label = NSTextField(labelWithString: "")
    private let status = NSImageView()
    private var statusWidth: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        DebugCounters.nameCellInits += 1
        icon.imageScaling = .scaleProportionallyUpOrDown
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.borderWidth = 1
        label.lineBreakMode = .byTruncatingMiddle
        // A name cut short shows in full when the pointer rests on it.
        label.allowsExpansionToolTips = true
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        status.contentTintColor = .tertiaryLabelColor
        for view in [icon, badge, label, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = label
        statusWidth = status.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            badge.widthAnchor.constraint(equalToConstant: 8),
            badge.heightAnchor.constraint(equalToConstant: 8),
            badge.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
            badge.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            status.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusWidth,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The kind badge's colour, nil when the badge is hidden (read by the self-test).
    var badgeColor: CGColor? { badge.isHidden ? nil : badge.layer?.backgroundColor }

    func configure(name: String, icon image: NSImage, badge color: NSColor?, status info: (symbol: String, help: String)?, dimmed: Bool) {
        label.stringValue = name
        label.textColor = dimmed ? .secondaryLabelColor : .labelColor
        icon.image = image
        badge.isHidden = color == nil
        if let color {
            badge.layer?.backgroundColor = color.cgColor
            badge.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        }
        if let info {
            status.image = NSImage(systemSymbolName: info.symbol, accessibilityDescription: info.help)
            status.toolTip = info.help
            status.isHidden = false
            statusWidth.constant = 14
        } else {
            status.isHidden = true
            statusWidth.constant = 0
        }
        setAccessibilityLabel(info.map { "\(name), \($0.help)" } ?? name)
    }
}

/// Right-aligned secondary text (percentages, counts, dates).
final class TextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ text: String) { label.stringValue = text }
}

/// The size with a bar showing the share of the parent folder.
final class SizeCellView: NSTableCellView {
    private var text = ""
    private var fraction = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    func configure(text: String, fraction: Double) {
        self.text = text
        self.fraction = max(0, min(1, fraction))
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let emphasized = backgroundStyle == .emphasized
        // The widest size, "999,9 MB" in small monospaced digits, is about 50 pt.
        let textWidth: CGFloat = 52
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: bounds.maxX - 2 - size.width, y: (bounds.height - size.height) / 2), withAttributes: attributes)

        let barWidth = bounds.width - textWidth - 8
        guard barWidth >= 16 else { return }
        let track = NSRect(x: 2, y: (bounds.height - 5) / 2, width: barWidth, height: 5)
        (emphasized ? NSColor.white.withAlphaComponent(0.25) : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        if fraction > 0 {
            var fill = track
            fill.size.width = max(3, track.width * fraction)
            (emphasized ? NSColor.white : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
}
