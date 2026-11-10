import DiskSurveyCore

/// Where the view may draw a node's name.
public struct TreemapLabel: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// In the title strip of a framed directory.
        case header
        /// Over the top-left corner of an unframed directory (cushion styles).
        case overlay
        /// Inside the tile of a file, a package, or a directory too small to subdivide.
        case tile
        /// In the top-left corner of a folder that the depth limit collapsed into one tile
        /// (``TreemapCell/isCollapsed``): the view draws a folder glyph, the name and — if
        /// ``TreemapLabel/fitsDetail`` — a second line with the size and share.
        case folder
        /// Inside an aggregate tile; the text is up to the view ("1,234 small items").
        case aggregate
    }

    public var node: NodeID
    /// Index into ``TreemapLayout/cells``.
    public var cell: Int
    public var kind: Kind
    /// The box the text must stay inside, in layout pixels. Text should be drawn left-aligned
    /// and vertically centred for `.header`/`.overlay`, centred for tiles, and truncated to fit.
    public var rect: TreemapRect
    /// Suggested font size in pixels (divide by the backing scale factor for points).
    public var fontSize: Float
    /// For tiles: whether there is room for a second, smaller line (e.g. the size) below the
    /// name. For overlays: whether `rect` is wide enough for the size after the name.
    public var fitsDetail: Bool
}

/// Parameters for ``TreemapLayout/labels(_:)``. All lengths are in pixels.
public struct TreemapLabelOptions: Sendable, Hashable {
    /// Backing scale factor; the point-based defaults below are multiplied by it.
    public var scale: Float
    /// Font size range for tile labels, in points.
    public var minFontSize: Float
    public var maxFontSize: Float
    /// Font size for header and overlay labels, in points. A header label is never taller than
    /// four fifths of its strip, so the slimmer strips of deep frames get smaller type.
    public var headerFontSize: Float
    /// Largest font size for the name of a collapsed folder (``TreemapLabel/Kind/folder``), in
    /// points; small tiles go down to ``minFontSize``. Blocks of ordinary size stop at
    /// ``maxFontSize``-ish 15 pt; only very wide ones grow towards this.
    public var maxFolderFontSize: Float = 21
    /// A collapsed folder narrower than this many points gets no label. Lower than
    /// ``minTileWidth``: a folder's name is what a depth-limited map is for, so a short or
    /// truncated one is still worth showing.
    public var minFolderWidth: Float = 34
    /// Margin between a collapsed folder's tile edge and its label, in points.
    public var folderMargin: Float = 7
    /// A tile narrower than this many points gets no label.
    public var minTileWidth: Float
    /// Margin between a tile's edge and its label, in points.
    public var margin: Float
    /// Unframed directories down to this depth get an overlay label (0 disables overlays).
    public var overlayDepth: Int
    /// Horizontal padding between the edge of an overlay label's pill and its text, in points.
    /// The reserved ``TreemapLabel/rect`` of an overlay includes it on both sides; a view should
    /// take it from ``overlayPaddingPixels`` so that both agree.
    public var overlayPadding: Float = 5
    public var includeFiles: Bool
    public var includeAggregates: Bool
    /// At most this many labels are returned; larger cells win.
    public var maxCount: Int

    public init(
        scale: Float = 1, minFontSize: Float = 9, maxFontSize: Float = 15, headerFontSize: Float = 11,
        minTileWidth: Float = 46, margin: Float = 4, overlayDepth: Int = 1, includeFiles: Bool = true,
        includeAggregates: Bool = true, maxCount: Int = 600
    ) {
        self.scale = scale
        self.minFontSize = minFontSize
        self.maxFontSize = maxFontSize
        self.headerFontSize = headerFontSize
        self.minTileWidth = minTileWidth
        self.margin = margin
        self.overlayDepth = overlayDepth
        self.includeFiles = includeFiles
        self.includeAggregates = includeAggregates
        self.maxCount = maxCount
    }

    /// ``overlayPadding`` in whole pixels at ``scale``.
    public var overlayPaddingPixels: Float { (overlayPadding * max(0.1, scale)).rounded() }
}

extension TreemapLayout {
    /// Average glyph advance as a fraction of the font size — a deliberately generous estimate
    /// for the system font, used only to decide what fits. The view measures real text.
    private static let glyphAdvance: Float = 0.56

    /// The same for the semibold face of overlay labels, which runs wider. An overlay's box is a
    /// promise to the view (the pill must stay inside it), so this errs on the generous side.
    private static let overlayGlyphAdvance: Float = 0.62

    /// Characters assumed for the size shown after an overlay's name ("123,4 GB" and a little air).
    private static let overlayDetailCharacters: Float = 9

    /// Estimated width of a UTF-8 name in units of an average Latin glyph: one per character,
    /// none for combining marks, and a full em for wide (CJK, emoji) characters.
    static func estimatedGlyphs<Bytes: Sequence<UInt8>>(_ utf8: Bytes, advance: Float) -> Float {
        var narrow = 0
        var wide = 0
        var scalar: UInt32 = 0
        var pending = 0
        func count(_ scalar: UInt32) {
            switch scalar {
            case 0x0300 ..< 0x0370, 0x200B ... 0x200F, 0xFE00 ... 0xFE0F, 0x1F3FB ... 0x1F3FF, 0xE0100 ... 0xE01EF:
                break  // combining marks, zero-width characters, variation selectors, skin tones
            case 0x1100 ... 0x115F, 0x2E80 ... 0xA4CF, 0xAC00 ... 0xD7A3, 0xF900 ... 0xFAFF, 0xFE30 ... 0xFE4F,
                0xFF00 ... 0xFF60, 0xFFE0 ... 0xFFE6, 0x1F000 ... 0x1FAFF, 0x20000 ... 0x3FFFD:
                wide += 1
            default: narrow += 1
            }
        }
        for byte in utf8 {
            if byte & 0xC0 == 0x80, pending > 0 {
                scalar = scalar << 6 | UInt32(byte & 0x3F)
                pending -= 1
                if pending == 0 { count(scalar) }
            } else if byte < 0x80 {
                pending = 0
                narrow += 1
            } else if byte >= 0xF0 {
                scalar = UInt32(byte & 0x07)
                pending = 3
            } else if byte >= 0xE0 {
                scalar = UInt32(byte & 0x0F)
                pending = 2
            } else if byte >= 0xC0 {
                scalar = UInt32(byte & 0x1F)
                pending = 1
            } else {
                pending = 0  // a stray continuation byte: file names need not be valid UTF-8
                narrow += 1
            }
        }
        return Float(narrow) + Float(wide) / advance
    }

    /// Chooses the cells large enough to carry a name and where the name goes.
    ///
    /// Labels never overlap one another: header labels live in the strips reserved by the
    /// layout, tile labels stay inside their own (disjoint) tiles, and a tile label that would
    /// collide with a directory's overlay label is moved below the overlay, or dropped if
    /// nothing fits there. An overlay's box is as wide as its pill may be drawn: padding, the
    /// name and (if ``TreemapLabel/fitsDetail``) the size.
    ///
    /// The result is ordered by importance: headers and overlays (shallowest first), then tiles
    /// from largest to smallest.
    public func labels(_ options: TreemapLabelOptions = TreemapLabelOptions()) -> [TreemapLabel] {
        let scale = max(0.1, options.scale)
        let margin = options.margin * scale
        let headerFont = options.headerFontSize * scale
        let minFont = options.minFontSize * scale
        let maxFont = max(minFont, options.maxFontSize * scale)
        let minWidth = options.minTileWidth * scale
        let advance = Self.glyphAdvance

        var structural: [TreemapLabel] = []  // headers and overlays
        var tiles: [(area: Float, characters: Int, label: TreemapLabel)] = []

        // Font size and room for a detail line for a name of `characters` in `box` (the tile
        // minus its margin, or what an overlay leaves of that); nil if no label fits.
        func fit(_ box: TreemapRect, characters: Int) -> (fontSize: Float, fitsDetail: Bool)? {
            let width = box.width
            let height = box.height
            guard height >= minFont * 1.25 else { return nil }
            // The largest size at which the whole name fits, within the allowed range. If even
            // the minimum does not fit, the view truncates — but at least six characters must show.
            let fitting = width / (Float(characters) * advance)
            let fontSize = min(maxFont, max(minFont, min(fitting, height * 0.42)))
            guard width >= min(Float(characters), 6) * fontSize * advance else { return nil }
            return (fontSize.rounded(.down), height >= fontSize * 2.6)
        }
        let overlayPad = options.overlayPaddingPixels
        let overlayDetail = Self.overlayDetailCharacters * headerFont * 0.92 * advance

        for index in cells.indices {
            let cell = cells[index]
            let rect = cell.rect
            if !cell.isLeaf {
                if cell.hasHeader, let strip = headerRect(ofCell: index) {
                    let box = TreemapRect(
                        minX: strip.minX + margin, minY: strip.minY, maxX: strip.maxX - margin, maxY: strip.maxY)
                    guard box.width >= headerFont * 2 else { continue }
                    structural.append(
                        TreemapLabel(
                            node: cell.node, cell: index, kind: .header, rect: box,
                            fontSize: min(headerFont, (strip.height * 0.8).rounded(.down)), fitsDetail: false))
                } else if cell.depth >= 1, Int(cell.depth) <= options.overlayDepth {
                    // A one-line box in the top-left corner, as wide as the pill the view draws
                    // may get: padding, the name, a gap of 1.4 paddings, the size, padding.
                    let lineHeight = (headerFont * 1.5).rounded()
                    guard rect.width >= minWidth * 1.5, rect.height >= lineHeight * 3 else { continue }
                    let glyphs = Self.estimatedGlyphs(tree.nameUTF8(of: cell.node), advance: Self.overlayGlyphAdvance)
                    let nameWidth = glyphs * headerFont * Self.overlayGlyphAdvance
                    let wanted = nameWidth + overlayDetail + 3.4 * overlayPad
                    let limit = rect.maxX - margin
                    let box = TreemapRect(
                        minX: rect.minX + margin, minY: rect.minY + margin,
                        maxX: min(limit, rect.minX + margin + wanted),
                        maxY: rect.minY + margin + lineHeight)
                    // Nested directories often share their top-left corner; the outer one wins.
                    if structural.contains(where: { $0.kind == .overlay && $0.rect.intersects(box) }) { continue }
                    structural.append(
                        TreemapLabel(
                            node: cell.node, cell: index, kind: .overlay, rect: box, fontSize: headerFont,
                            fitsDetail: rect.minX + margin + wanted <= limit))
                }
                continue
            }

            // An empty map (a root with nothing in it) has nothing to name.
            if cell.parent < 0, cell.isDirectory { continue }
            if cell.isAggregate ? !options.includeAggregates : (!options.includeFiles && !cell.isDirectory) { continue }
            if cell.isCollapsed {
                // A folder shown as one block: its name goes to the top-left corner, like the
                // title of a frame, and grows with the block.
                guard rect.width >= options.minFolderWidth * scale else { continue }
                let pad = min(options.folderMargin * scale, max(3 * scale, min(rect.width, rect.height) * 0.10)).rounded()
                let box = TreemapRect(
                    minX: rect.minX + pad, minY: rect.minY + pad, maxX: rect.maxX - pad, maxY: rect.maxY - pad)
                guard box.height >= minFont * 1.3 else { continue }
                // Up to 15 pt the type follows the width; beyond, only very wide blocks grow on.
                let regular = 15 * scale
                let largest = max(regular, options.maxFolderFontSize * scale)
                var wanted = box.width / 11
                if wanted > regular { wanted = min(largest, regular + (box.width - regular * 11) / 40) }
                let fontSize = max(minFont, min(wanted, box.height * 0.30)).rounded(.down)
                // Three characters and an ellipsis must fit; the view drops the glyph if it must.
                guard box.width >= fontSize * 4 * advance else { continue }
                tiles.append(
                    (
                        rect.area, max(1, tree.nameUTF8(of: cell.node).count),
                        TreemapLabel(
                            node: cell.node, cell: index, kind: .folder, rect: box, fontSize: fontSize,
                            fitsDetail: box.height >= fontSize * 2.5)
                    ))
                continue
            }
            guard rect.width >= minWidth else { continue }
            // Aggregates are captioned by the view; assume a caption like "1,234 items".
            let characters = cell.isAggregate ? 11 : max(1, tree.nameUTF8(of: cell.node).count)
            let box = TreemapRect(
                minX: rect.minX + margin, minY: rect.minY + margin, maxX: rect.maxX - margin, maxY: rect.maxY - margin)
            guard let fitted = fit(box, characters: characters) else { continue }
            tiles.append(
                (
                    rect.area, characters,
                    TreemapLabel(
                        node: cell.node, cell: index, kind: cell.isAggregate ? .aggregate : .tile, rect: box,
                        fontSize: fitted.fontSize, fitsDetail: fitted.fitsDetail)
                ))
        }

        // A directory's overlay sits on the top-left corner of its contents — exactly where the
        // squarified layout puts its largest child. That tile keeps its label, in the part of
        // the tile below the overlay. This runs after the loop so it sees the final set of
        // overlays whatever the order of the cells.
        let overlays = structural.filter { $0.kind == .overlay }
        if !overlays.isEmpty {
            var kept = 0
            for index in tiles.indices {
                var tile = tiles[index]
                var floor = -Float.infinity
                for overlay in overlays where overlay.rect.intersects(tile.label.rect) {
                    floor = max(floor, overlay.rect.maxY)
                }
                if floor > -Float.infinity {
                    tile.label.rect.minY = floor + margin
                    if tile.label.kind == .folder {
                        // Top-aligned anyway: it only has to still fit below the overlay.
                        guard tile.label.rect.height >= tile.label.fontSize * 1.3 else { continue }
                        tile.label.fitsDetail = tile.label.rect.height >= tile.label.fontSize * 2.5
                    } else {
                        guard tile.label.rect.maxY > tile.label.rect.minY,
                            let fitted = fit(tile.label.rect, characters: tile.characters)
                        else { continue }
                        tile.label.fontSize = fitted.fontSize
                        tile.label.fitsDetail = fitted.fitsDetail
                    }
                }
                tiles[kept] = tile
                kept += 1
            }
            tiles.removeSubrange(kept...)
        }
        // Largest first; the cell index breaks ties so the order is deterministic.
        tiles.sort { $0.area != $1.area ? $0.area > $1.area : $0.label.cell < $1.label.cell }

        // Outer frames first, and within a level the larger ones: if the cap ever cuts, it cuts
        // the least important names. (Stable, so equal cells keep their deterministic order.)
        if structural.count > options.maxCount {
            let keyed = structural.enumerated().sorted { a, b in
                let da = cells[a.element.cell].depth
                let db = cells[b.element.cell].depth
                if da != db { return da < db }
                let aa = cells[a.element.cell].rect.area
                let ab = cells[b.element.cell].rect.area
                return aa != ab ? aa > ab : a.offset < b.offset
            }
            structural = keyed.map(\.element)
        }
        var result = structural
        if result.count > options.maxCount { result.removeSubrange(options.maxCount...) }
        result.append(contentsOf: tiles.prefix(max(0, options.maxCount - result.count)).map(\.label))
        return result
    }

    /// The folders whose names a frame's title stands for: the framed directory of cell
    /// `index` itself, followed by the chain of directories below it that fill (nearly) all of
    /// the frame and therefore got no frame of their own — "a/b/c" with one title.
    public func titleChain(ofCell index: Int) -> [NodeID] {
        var chain = [cells[index].node]
        guard cells[index].isFramed else { return chain }
        let threshold = LayoutBuilder.dominantShare * contentRect(ofCell: index).area
        var current = index
        while chain.count < 6 {
            let cell = cells[current]
            guard !cell.isLeaf, cell.childCount > 0 else { break }
            // Children are laid out largest first.
            let first = Int(cell.firstChild)
            let child = cells[first]
            guard child.isDirectory, !child.isLeaf, !child.isFramed, child.rect.area >= threshold else { break }
            chain.append(child.node)
            current = first
        }
        return chain
    }
}
