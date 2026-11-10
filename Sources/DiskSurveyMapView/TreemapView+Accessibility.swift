import AppKit
import DiskSurveyCore
import DiskSurveyTreemap

/// One top-level tile as seen by VoiceOver. Pressing it selects the item.
final class TreemapAccessibilityElement: NSAccessibilityElement {
    weak var view: TreemapView?
    var node: NodeID = 0

    override func accessibilityPerformPress() -> Bool {
        // AppKit calls this on the main thread; only Sendable values cross into the closure.
        let node = node
        let target = view
        return MainActor.assumeIsolated {
            guard let view = target else { return false }
            view.setSelectionByUser([node], primary: node)
            return true
        }
    }
}

// VoiceOver sees the map as a group: a summary of the folder shown, plus its largest items as
// child elements that can be explored spatially and pressed to select.
extension TreemapView {
    /// More children than this add noise rather than information for a screen-reader user.
    private static let maxAccessibilityChildren = 40

    func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("disk usage map")
    }

    /// Drops the cached child elements. Posts nothing: it runs for every new picture.
    func invalidateAccessibility() {
        accessibilityCache = nil
    }

    /// Posts a notification about the map (nothing is listening before the view is in a window).
    func postAccessibility(_ notification: NSAccessibility.Notification) {
        guard window != nil else { return }
        accessibilityPoster(self, notification, nil)
    }

    /// Speaks the selection after the user changed it: arrow keys usually land on nested tiles
    /// that are not accessibility children, so without this a move is silent.
    func announceSelection() {
        guard let window else { return }
        accessibilityPoster(
            window, .announcementRequested,
            [.announcement: selectionAnnouncement, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// What one item is, as spoken: "folder", "image", "unix executable", "file".
    static func spokenKind(of node: NodeID, in tree: FileTree) -> String {
        if tree.isDirectory(node) { return "folder" }
        let kind = tree.fileKind(of: node)
        return kind.isUnixExecutable ? "unix executable" : kind.category.singularName.lowercased()
    }

    /// "Movies, folder, 12.4 GB" / "3 items selected, 1.2 GB" / "No selection".
    var selectionAnnouncement: String {
        guard let tree = currentTree else { return "No selection" }
        let selected = orderedSelection
        if selected.isEmpty { return "No selection" }
        if selected.count == 1 {
            let node = selected[0]
            let kind = Self.spokenKind(of: node, in: tree)
            let size = sizeMetric == .allocated ? tree.size(of: node) : tree.logicalSize(of: node)
            return "\(tree.name(of: node)), \(kind), \(Format.bytes(size))"
        }
        let bytes = selected.reduce(UInt64(0)) { $0 &+ (sizeMetric == .allocated ? tree.size(of: $1) : tree.logicalSize(of: $1)) }
        return "\(Format.count(selected.count)) items selected, \(Format.bytes(bytes))"
    }

    /// The top-level tiles that are selected or contain a selected item, so the selection can
    /// be reached even when it is a nested tile without an element of its own.
    public override func accessibilitySelectedChildren() -> [Any]? {
        (accessibilityChildren() ?? []).filter { ($0 as? NSAccessibilityElement)?.isAccessibilitySelected() == true }
    }

    public override func accessibilityLabel() -> String? {
        guard let tree = currentTree else { return "Disk usage map" }
        return "Disk usage map of \(tree.name(of: effectiveRoot))"
    }

    public override func accessibilityValue() -> Any? {
        accessibilitySummary
    }

    public override func accessibilityHelp() -> String? {
        "Arrow keys move between items. Return zooms into a folder, Escape zooms out. Space previews, Command-Delete moves to the Trash."
    }

    /// A spoken overview: what is shown, its size, the largest items and the selection.
    public var accessibilitySummary: String {
        guard let tree = currentTree else { return isScanning ? "Scanning." : "No folder scanned." }
        let root = effectiveRoot
        let total = sizeMetric == .allocated ? tree.size(of: root) : tree.logicalSize(of: root)
        guard total > 0 else { return isScanning ? "Scanning." : "\(tree.name(of: root)) is empty." }
        var parts = ["\(tree.name(of: root)), \(Format.bytes(total)), \(Format.items(tree.fileCount(of: root)))."]
        if isScanning { parts.append("Still scanning.") }
        let largest = tree.children(of: root).prefix(5).map { child in
            "\(tree.name(of: child)) \(Format.percent(tree.size(of: child), of: tree.size(of: root)))"
        }
        if !largest.isEmpty { parts.append("Largest: " + largest.joined(separator: ", ") + ".") }
        let selected = orderedSelection
        if selected.count == 1 {
            parts.append("Selected: \(tree.name(of: selected[0])), \(Format.bytes(tree.size(of: selected[0]))).")
        } else if selected.count > 1 {
            let bytes = selected.reduce(UInt64(0)) { $0 &+ tree.size(of: $1) }
            parts.append("\(Format.count(selected.count)) items selected, \(Format.bytes(bytes)).")
        }
        return parts.joined(separator: " ")
    }

    public override func accessibilityChildren() -> [Any]? {
        guard let frame = interactiveFrame else { return [] }
        if let cache = accessibilityCache, cache.serial == frame.request.serial { return cache.elements }
        let tree = frame.tree
        let layout = frame.layout
        let geometry = geometry(for: frame)
        let rootSize = frame.size(of: layout.root)
        // Selected here means "is or contains a selected item".
        let selectedTiles = Set(selection.prefix(1000).compactMap { topLevelAncestor(of: $0) })
        var elements: [NSAccessibilityElement] = []
        for index in layout.cells[0].children.prefix(Self.maxAccessibilityChildren) {
            let cell = layout.cells[index]
            let element = TreemapAccessibilityElement()
            element.view = self
            element.node = cell.node
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityFrameInParentSpace(geometry.viewRect(cell.rect))
            let size = frame.size(ofCell: index)
            let share = Format.percent(size, of: rootSize)
            if cell.isAggregate {
                element.setAccessibilityLabel(
                    "\(Format.counted(cell.mergedCount, singular: "small item", plural: "small items")), \(Format.bytes(size)), \(share)")
            } else {
                let kind = Self.spokenKind(of: cell.node, in: tree)
                element.setAccessibilityLabel("\(tree.name(of: cell.node)), \(kind), \(Format.bytes(size)), \(share)")
            }
            element.setAccessibilitySelected(!cell.isAggregate && selectedTiles.contains(cell.node))
            elements.append(element)
        }
        accessibilityCache = (frame.request.serial, elements)
        return elements
    }
}
