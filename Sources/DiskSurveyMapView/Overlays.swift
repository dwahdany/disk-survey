import AppKit
import CoreText
import DiskSurveyCore
import DiskSurveyTreemap

/// Geometry and look of the selection and hover outlines, shared by the live layers and the
/// offscreen snapshot so both show the same thing.
enum Overlay {
    /// Cap on outlined cells: a "select all matches" selection can hold millions of nodes, and
    /// beyond a few thousand outlines nothing is distinguishable anyway.
    static let maxSelectionRects = 4000

    static let selectionStroke: CGFloat = 3
    static let hoverStroke: CGFloat = 1.5

    /// View rectangles of the selected nodes that are visible under the frame's root. A node
    /// pruned by the level of detail outlines the cell that contains it.
    static func selectionRects(frame: RenderedFrame, selection: Set<NodeID>, geometry: MapGeometry) -> [CGRect] {
        guard !selection.isEmpty else { return [] }
        var cells = Set<Int>()
        var rects: [CGRect] = []
        for node in selection {
            // The root fills the whole view; outlining it would only frame the window.
            guard node != frame.layout.root, let location = frame.layout.locate(node) else { continue }
            guard location.cell != 0, cells.insert(location.cell).inserted else { continue }
            rects.append(displayRect(geometry.viewRect(frame.layout.cells[location.cell].rect)))
            if rects.count >= maxSelectionRects { break }
        }
        return rects
    }

    /// The hovered cell's rectangle and those of the folders around it, innermost first: the
    /// first element is the folder the item is directly in, the rest its ancestors up to (not
    /// including) the folder shown as the whole map.
    static func hoverRects(frame: RenderedFrame, cell: Int, geometry: MapGeometry) -> (cell: CGRect, chain: [CGRect]) {
        let cells = frame.layout.cells
        var chain: [CGRect] = []
        var index = Int(cells[cell].parent)
        while index > 0 {
            chain.append(geometry.viewRect(cells[index].rect))
            index = Int(cells[index].parent)
        }
        return (geometry.viewRect(cells[cell].rect), chain)
    }

    /// Cells of a point or two would vanish under their own outline; give them a visible minimum.
    static func displayRect(_ rect: CGRect) -> CGRect {
        let minimum: CGFloat = 8
        var r = rect
        if r.width < minimum { r = r.insetBy(dx: (r.width - minimum) / 2, dy: 0) }
        if r.height < minimum { r = r.insetBy(dx: 0, dy: (r.height - minimum) / 2) }
        return r
    }

    /// Outline path running `inset` inside each rectangle, so the stroke stays within the cell.
    static func path(_ rects: [CGRect], inset: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for rect in rects {
            let d = min(inset, rect.width / 2 - 0.25, rect.height / 2 - 0.25)
            path.addRect(rect.insetBy(dx: max(0, d), dy: max(0, d)))
        }
        return path
    }

    static func accentColor() -> CGColor {
        NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
    }

    // MARK: Layer styling

    @MainActor static func styleSelection(glow: CAShapeLayer, line: CAShapeLayer, accent: CGColor) {
        glow.fillColor = accent.copy(alpha: 0.10)
        glow.strokeColor = accent
        glow.lineWidth = selectionStroke
        glow.shadowColor = accent
        glow.shadowOpacity = 1
        glow.shadowRadius = 5
        glow.shadowOffset = .zero
        // A white hairline inside the accent band keeps the outline crisp on any tile colour.
        line.fillColor = nil
        line.strokeColor = CGColor(gray: 1, alpha: 0.92)
        line.lineWidth = 1
    }

    /// Stroke of the outline around the hovered item's own folder; the folders further out get
    /// a fainter hairline, so the eye finds "which folder is this in" first.
    static let hoverParentStroke: CGFloat = 2
    static let hoverParentAlpha: CGFloat = 0.9
    static let hoverAncestorAlpha: CGFloat = 0.62

    /// The translucent wash inside the hover and selection outlines suits a file tile. Over a
    /// cell larger than this (a folder block, mostly) it would only grey out the colour the
    /// user is pointing at, so those get the outline alone.
    static let maxWashedArea: CGFloat = 120 * 90
    static func isWashed(_ rect: CGRect) -> Bool { rect.width * rect.height <= maxWashedArea }
    static let hoverWash = CGColor(gray: 1, alpha: 0.10)

    @MainActor static func styleHover(cell: CAShapeLayer, parent: CAShapeLayer, chain: CAShapeLayer) {
        parent.fillColor = nil
        parent.strokeColor = CGColor(gray: 1, alpha: hoverParentAlpha)
        parent.lineWidth = hoverParentStroke
        parent.shadowColor = CGColor(gray: 0, alpha: 1)
        parent.shadowOpacity = 1
        parent.shadowRadius = 1
        parent.shadowOffset = .zero
        cell.fillColor = hoverWash
        cell.strokeColor = CGColor(gray: 1, alpha: 0.95)
        cell.lineWidth = hoverStroke
        cell.shadowColor = CGColor(gray: 0, alpha: 1)
        cell.shadowOpacity = 0.9
        cell.shadowRadius = 1.2
        cell.shadowOffset = .zero
        chain.fillColor = nil
        chain.strokeColor = CGColor(gray: 1, alpha: hoverAncestorAlpha)
        chain.lineWidth = 1
        chain.shadowColor = CGColor(gray: 0, alpha: 1)
        chain.shadowOpacity = 0.8
        chain.shadowRadius = 0.8
        chain.shadowOffset = .zero
    }

    // MARK: Core Graphics rendition (snapshots)

    /// Paints the same outlines the layers show. Context units are points, y up.
    static func paint(
        selection: [CGRect], hover: (cell: CGRect, chain: [CGRect])?, accent: CGColor, in context: CGContext
    ) {
        if let hover {
            if hover.chain.count > 1 {
                context.saveGState()
                context.setShadow(offset: .zero, blur: 1.6, color: CGColor(gray: 0, alpha: 0.8))
                context.addPath(path(Array(hover.chain.dropFirst()), inset: 0.5))
                context.setStrokeColor(CGColor(gray: 1, alpha: hoverAncestorAlpha))
                context.setLineWidth(1)
                context.strokePath()
                context.restoreGState()
            }
            if let parent = hover.chain.first {
                context.saveGState()
                context.setShadow(offset: .zero, blur: 2, color: CGColor(gray: 0, alpha: 1))
                context.addPath(path([parent], inset: hoverParentStroke / 2))
                context.setStrokeColor(CGColor(gray: 1, alpha: hoverParentAlpha))
                context.setLineWidth(hoverParentStroke)
                context.strokePath()
                context.restoreGState()
            }

            context.saveGState()
            let outline = path([hover.cell], inset: hoverStroke / 2)
            if isWashed(hover.cell) {
                context.addPath(outline)
                context.setFillColor(hoverWash)
                context.fillPath()
            }
            context.setShadow(offset: .zero, blur: 2.4, color: CGColor(gray: 0, alpha: 0.9))
            context.addPath(outline)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            context.setLineWidth(hoverStroke)
            context.strokePath()
            context.restoreGState()
        }
        guard !selection.isEmpty else { return }
        let band = path(selection, inset: selectionStroke / 2)
        context.saveGState()
        if selection.allSatisfy(isWashed) {
            context.addPath(band)
            context.setFillColor(accent.copy(alpha: 0.10) ?? accent)
            context.fillPath()
        }
        context.setShadow(offset: .zero, blur: 10, color: accent)
        context.addPath(band)
        context.setStrokeColor(accent)
        context.setLineWidth(selectionStroke)
        context.strokePath()
        context.restoreGState()
        context.addPath(band)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
        context.setLineWidth(1)
        context.strokePath()
    }
}

/// What the view shows instead of a map.
enum PlaceholderState: Equatable {
    case none
    /// No tree assigned.
    case noTree
    /// The tree (or zoomed folder) takes no space.
    case empty
    /// A scan runs but nothing has been measured yet.
    case scanning

    var symbol: String {
        switch self {
        case .none: ""
        case .noTree: "square.grid.3x3.topleft.filled"
        case .empty: "tray"
        case .scanning: "magnifyingglass"
        }
    }

    var title: String {
        switch self {
        case .none: ""
        case .noTree: "No Folder Scanned"
        case .empty: "Nothing Here"
        case .scanning: "Scanning…"
        }
    }

    var subtitle: String {
        switch self {
        case .none: ""
        case .noTree: "Choose a folder or volume to see what fills it."
        case .empty: "This folder doesn’t use any disk space."
        case .scanning: "The map fills in as folders are measured."
        }
    }
}

enum PlaceholderPainter {
    /// Size of the placeholder block in points.
    static let size = CGSize(width: 380, height: 150)

    /// Draws symbol, title and subtitle centred in `rect`. Context units are points, y up;
    /// `scale` is the context's pixels per point (for a sharp symbol).
    static func draw(_ state: PlaceholderState, in rect: CGRect, scheme: PaletteScheme, scale: CGFloat, context: CGContext) {
        guard state != .none else { return }
        let dark = scheme == .dark
        let primary = dark ? CGColor(gray: 1, alpha: 0.82) : CGColor(gray: 0, alpha: 0.78)
        let secondary = dark ? CGColor(gray: 1, alpha: 0.50) : CGColor(gray: 0, alpha: 0.48)
        let tertiary = dark ? CGColor(gray: 1, alpha: 0.30) : CGColor(gray: 0, alpha: 0.26)

        let title = TextLine(
            state.title, font: NSFont.systemFont(ofSize: 17, weight: .semibold) as CTFont, color: primary,
            maxWidth: rect.width, truncation: .end)
        let subtitle = TextLine(
            state.subtitle, font: NSFont.systemFont(ofSize: 12.5, weight: .regular) as CTFont, color: secondary,
            maxWidth: rect.width, truncation: .end)
        let symbolHeight: CGFloat = 46
        let block = symbolHeight + 14 + (title?.lineHeight ?? 0) + 5 + (subtitle?.lineHeight ?? 0)
        var top = rect.midY + block / 2

        // The symbol is drawn as a mask and tinted, so it follows the scheme without AppKit's
        // appearance machinery (this also runs off the main thread, for snapshots).
        let configuration = NSImage.SymbolConfiguration(pointSize: 38, weight: .light)
        if let symbol = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        {
            let natural = symbol.size
            let fit = min(symbolHeight / max(1, natural.height), 1.4)
            let drawSize = CGSize(width: natural.width * fit, height: natural.height * fit)
            var proposed = CGRect(x: 0, y: 0, width: drawSize.width * scale, height: drawSize.height * scale)
            if let image = symbol.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
                let target = CGRect(
                    x: rect.midX - drawSize.width / 2, y: top - symbolHeight + (symbolHeight - drawSize.height) / 2,
                    width: drawSize.width, height: drawSize.height)
                context.saveGState()
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.draw(image, in: target)
                context.setBlendMode(.sourceIn)
                context.setFillColor(tertiary)
                context.fill(target.insetBy(dx: -2, dy: -2))
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
        top -= symbolHeight + 14
        if let title {
            title.draw(in: context, x: rect.midX - title.width / 2, centerY: top - title.lineHeight / 2)
            top -= title.lineHeight + 5
        }
        if let subtitle {
            subtitle.draw(in: context, x: rect.midX - subtitle.width / 2, centerY: top - subtitle.lineHeight / 2)
        }
    }

    /// The placeholder block as an image for a layer.
    static func image(_ state: PlaceholderState, scheme: PaletteScheme, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: FrameRenderer.sRGB,
                bitmapInfo: info)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(state, in: CGRect(origin: .zero, size: size), scheme: scheme, scale: scale, context: context)
        return context.makeImage()
    }
}

extension RGB {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}
