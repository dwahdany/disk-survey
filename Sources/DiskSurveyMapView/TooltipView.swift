import AppKit
import DiskSurveyCore
import DiskSurveyTreemap

/// The text of the hover HUD.
struct TooltipContent: Equatable {
    var name: String
    var swatch: RGB
    /// "12.4 GB · 34% of Movies · 2.1% of Macintosh HD"
    var sizeLine: String
    /// "Video · .mp4 · Modified 3 weeks ago"
    var kindLine: String
    /// Containing folder, as a path. Shown only when ``folders`` is empty.
    var path: String

    /// One enclosing folder with its size.
    struct Folder: Equatable {
        var name: String
        var size: String
    }
    /// The folders around the item between the folder shown as the whole map (excluded) and
    /// the item, outermost first — so the last one is the folder the item is directly in.
    /// At most ``maxFolders``; ``foldersElided`` says that outer ones were left out.
    var folders: [Folder] = []
    var foldersElided = false
    static let maxFolders = 4

    init(frame: RenderedFrame, cell index: Int) {
        let tree = frame.tree
        let layout = frame.layout
        let cell = layout.cells[index]
        let node = cell.node
        let size = frame.size(ofCell: index)
        let key = frame.key

        switch key.colorMode {
        case .kind:
            let colors = tree.kinds
            swatch = KindPalette.color(for: colors[min(Int(tree.kind(of: cell.sample)), colors.count - 1)], scheme: key.scheme)
        case .age:
            swatch = AgePalette.color(modified: tree.modified(of: cell.sample), now: key.ageNow, scheme: key.scheme)
        }

        // What the cell is a share of: its folder, and the folder shown as the whole map.
        let container = cell.isAggregate ? node : (tree.parent(of: node) ?? node)
        var shares: [String] = [Format.bytes(size)]
        if container != node || cell.isAggregate {
            shares.append("\(Format.percent(size, of: frame.size(of: container))) of \(tree.name(of: container))")
        }
        if container != layout.root, node != layout.root {
            shares.append("\(Format.percent(size, of: frame.size(of: layout.root))) of \(tree.name(of: layout.root))")
        }
        sizeLine = shares.joined(separator: "  ·  ")

        // The enclosing folders with their sizes: "which folder is the big one" at a glance.
        var chain: [NodeID] = []
        var current = cell.isAggregate ? node : (tree.parent(of: node) ?? layout.root)
        while current != layout.root, chain.count < 64 {
            chain.append(current)
            guard let parent = tree.parent(of: current) else { break }
            current = parent
        }
        if node == layout.root { chain = [] }
        foldersElided = chain.count > Self.maxFolders
        folders = chain.prefix(Self.maxFolders).reversed().map {
            Folder(name: tree.name(of: $0), size: Format.bytes(frame.size(of: $0)))
        }

        let flags = tree.flags(of: node)
        if cell.isAggregate {
            name = Format.counted(cell.mergedCount, singular: "small item", plural: "small items")
            kindLine = "Too small to draw individually"
            path = tree.path(of: node)
            return
        }
        name = tree.name(of: node)
        var facts: [String] = []
        if flags.contains(.directory) {
            if flags.contains(.mountPoint) {
                facts.append("Volume")
            } else if flags.contains(.package) {
                facts.append("Package")
            } else {
                facts.append("Folder")
            }
            facts.append(Format.items(tree.fileCount(of: node)))
            if flags.contains(.unreadable) { facts.append("No access") }
        } else {
            let kind = tree.fileKind(of: node)
            if flags.contains(.synthetic) {
                facts.append("Not itemized")
            } else if flags.contains(.symlink) {
                facts.append("Symbolic link")
            } else {
                // One item, so the singular ("Image", not "Images"); the pseudo-kind of
                // extensionless executables has no extension to add.
                if kind.isUnixExecutable {
                    facts.append("Unix executable")
                } else {
                    facts.append(kind.category.singularName)
                    if !kind.ext.isEmpty { facts.append(kind.displayName) }
                }
            }
            if flags.contains(.dataless) { facts.append("In iCloud, not downloaded") }
            if flags.contains(.hardLinkDuplicate) { facts.append("Hard link, counted once") }
        }
        let modified = tree.modified(of: node)
        if modified > 0 { facts.append("Modified \(Format.relativeDate(modified).lowercased())") }
        kindLine = facts.joined(separator: "  ·  ")
        path = tree.parent(of: node).map { tree.path(of: $0) } ?? tree.path(of: node)
    }
}

/// The HUD that follows the pointer: name, size and shares, kind, containing folder.
///
/// A subview of the map rather than a window, so it needs no window ordering and never
/// outlives the view; it is clamped to the map's bounds.
final class TooltipView: NSView {
    // Classic vibrancy rather than Liquid Glass: glass refracts the saturated tiles beneath it,
    // which costs the small text its contrast. A blurred material keeps it readable everywhere.
    private let effect = NSVisualEffectView()
    private let swatch = NSView()
    private let nameField = TooltipView.makeField(.systemFont(ofSize: 13, weight: .semibold), .labelColor)
    private let sizeField = TooltipView.makeField(.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), .labelColor)
    private let kindField = TooltipView.makeField(.systemFont(ofSize: 11.5), .secondaryLabelColor)
    private let pathField = TooltipView.makeField(.systemFont(ofSize: 10.5), .tertiaryLabelColor)

    private let separator = NSBox()
    private let elisionField = TooltipView.makeField(.systemFont(ofSize: 11, weight: .semibold), .tertiaryLabelColor)
    private var folderRows: [FolderRow] = []

    /// The views of one enclosing folder: glyph, name, size.
    @MainActor private struct FolderRow {
        let glyph = NSImageView()
        let name = TooltipView.makeField(.systemFont(ofSize: 11.5), .secondaryLabelColor)
        let size = TooltipView.makeField(.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), .secondaryLabelColor)

        init() {
            glyph.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            glyph.imageScaling = .scaleProportionallyDown
            name.lineBreakMode = .byTruncatingMiddle
            size.alignment = .right
        }
    }

    private(set) var content: TooltipContent?

    static let maxWidth: CGFloat = 360
    private static let padding = NSEdgeInsets(top: 9, left: 11, bottom: 9, right: 12)

    private static func makeField(_ font: NSFont, _ color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 1
        field.allowsDefaultTighteningForTruncation = true
        return field
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The shadow lives on this (unclipped) view; the material below is clipped to the radius.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        self.shadow = shadow

        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.layer?.cornerCurve = .continuous
        swatch.layer?.borderWidth = 0.5
        pathField.lineBreakMode = .byTruncatingHead
        for view in [swatch, nameField, sizeField, kindField, pathField] { effect.addSubview(view) }
        separator.boxType = .separator
        separator.isHidden = true
        elisionField.stringValue = "…"
        elisionField.isHidden = true
        effect.addSubview(separator)
        effect.addSubview(elisionField)
        updateBorder()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The HUD must never swallow clicks meant for the map under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            effect.layer?.borderColor = NSColor.separatorColor.cgColor
            swatch.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
        }
    }

    /// Sets the text and resizes the view to fit it.
    func update(_ content: TooltipContent) {
        guard content != self.content else { return }
        self.content = content
        nameField.stringValue = content.name
        sizeField.stringValue = content.sizeLine
        kindField.stringValue = content.kindLine
        pathField.stringValue = content.folders.isEmpty ? content.path : ""
        swatch.layer?.backgroundColor = content.swatch.cgColor

        let pad = Self.padding
        let swatchSide: CGFloat = 11
        let swatchGap: CGFloat = 7
        let inner = Self.maxWidth - pad.left - pad.right
        let rows: [(field: NSTextField, indent: CGFloat)] = [
            (nameField, swatchSide + swatchGap), (sizeField, 0), (kindField, 0), (pathField, 0),
        ]
        var width: CGFloat = 0
        var heights: [CGFloat] = []
        for row in rows {
            let fitting = row.field.stringValue.isEmpty ? .zero : row.field.intrinsicContentSize
            width = max(width, min(inner, ceil(fitting.width) + row.indent))
            heights.append(ceil(fitting.height))
        }

        // The folder chain: one row per enclosing folder, indented a step per level, its size
        // in a right-aligned column.
        while folderRows.count < content.folders.count {
            let row = FolderRow()
            for view in [row.glyph, row.name, row.size] as [NSView] { effect.addSubview(view) }
            folderRows.append(row)
        }
        let step: CGFloat = 9
        let glyphWidth: CGFloat = 15
        let sizeGap: CGFloat = 14
        var folderHeight: CGFloat = 0
        var sizeColumn: CGFloat = 0
        var nameWidths: [CGFloat] = []
        for (index, folder) in content.folders.enumerated() {
            let row = folderRows[index]
            row.name.stringValue = folder.name
            row.size.stringValue = folder.size
            // The folder the item is directly in is the one being asked about.
            let innermost = index == content.folders.count - 1
            row.name.textColor = innermost ? .labelColor : .secondaryLabelColor
            row.size.textColor = innermost ? .labelColor : .secondaryLabelColor
            row.glyph.contentTintColor = innermost ? .secondaryLabelColor : .tertiaryLabelColor
            let nameSize = row.name.intrinsicContentSize
            nameWidths.append(ceil(nameSize.width) + 4)
            sizeColumn = max(sizeColumn, ceil(row.size.intrinsicContentSize.width) + 4)
            folderHeight = max(folderHeight, ceil(nameSize.height))
        }
        for (index, nameWidth) in nameWidths.enumerated() {
            width = max(width, min(inner, CGFloat(index) * step + glyphWidth + nameWidth + sizeGap + sizeColumn))
        }
        elisionField.isHidden = !content.foldersElided || content.folders.isEmpty
        width = max(width, 150)

        let spacing: [CGFloat] = [5, 2, 3]
        var total = pad.top + pad.bottom
        for (i, h) in heights.enumerated() where h > 0 { total += h + (i > 0 ? spacing[i - 1] : 0) }
        let folderSpacing: CGFloat = 2
        let separatorGap: CGFloat = 7
        let elisionHeight: CGFloat = elisionField.isHidden ? 0 : ceil(elisionField.intrinsicContentSize.height) - 3
        if !content.folders.isEmpty {
            total += separatorGap * 2 + 1 + elisionHeight
            total += CGFloat(content.folders.count) * folderHeight + CGFloat(content.folders.count - 1) * folderSpacing
        }
        setFrameSize(NSSize(width: width + pad.left + pad.right, height: total))

        var y = total - pad.top
        for (i, row) in rows.enumerated() {
            let h = heights[i]
            row.field.isHidden = h == 0
            guard h > 0 else { continue }
            if i > 0 { y -= spacing[i - 1] }
            y -= h
            row.field.frame = NSRect(x: pad.left + row.indent, y: y, width: width - row.indent, height: h)
            if i == 0 {
                swatch.frame = NSRect(x: pad.left, y: y + (h - swatchSide) / 2, width: swatchSide, height: swatchSide)
            }
        }
        separator.isHidden = content.folders.isEmpty
        if !content.folders.isEmpty {
            y -= separatorGap + 1
            separator.frame = NSRect(x: pad.left, y: y, width: width, height: 1)
            y -= separatorGap
            if !elisionField.isHidden {
                y -= elisionHeight
                elisionField.frame = NSRect(x: pad.left + 2, y: y - 2, width: 30, height: elisionHeight + 4)
            }
        }
        for (index, row) in folderRows.enumerated() {
            let visible = index < content.folders.count
            for view in [row.glyph, row.name, row.size] as [NSView] { view.isHidden = !visible }
            guard visible else { continue }
            if index > 0 { y -= folderSpacing }
            y -= folderHeight
            let indent = CGFloat(index) * step
            row.glyph.frame = NSRect(x: pad.left + indent, y: y + (folderHeight - 12) / 2, width: 13, height: 12)
            let nameX = pad.left + indent + glyphWidth
            row.size.frame = NSRect(x: pad.left + width - sizeColumn, y: y, width: sizeColumn, height: folderHeight)
            row.name.frame = NSRect(
                x: nameX, y: y, width: max(20, pad.left + width - sizeColumn - sizeGap - nameX), height: folderHeight)
        }
    }

    /// Places the HUD next to the pointer, flipping to the other side at the container's edges.
    func place(near point: NSPoint, in container: NSRect) {
        let size = frame.size
        let offset: CGFloat = 16
        var origin = NSPoint(x: point.x + offset, y: point.y - offset - size.height)
        if origin.x + size.width > container.maxX - 4 { origin.x = point.x - offset - size.width }
        if origin.y < container.minY + 4 { origin.y = point.y + offset }
        origin.x = min(max(origin.x, container.minX + 4), max(container.minX + 4, container.maxX - 4 - size.width))
        origin.y = min(max(origin.y, container.minY + 4), max(container.minY + 4, container.maxY - 4 - size.height))
        // Whole points: text inside stays sharp.
        setFrameOrigin(NSPoint(x: origin.x.rounded(), y: origin.y.rounded()))
    }
}
