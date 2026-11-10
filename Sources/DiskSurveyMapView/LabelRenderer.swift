import AppKit
import CoreText
import DiskSurveyCore
import DiskSurveyTreemap

/// Draws the names on the map into a transparent image.
///
/// Labels change only when the layout changes, so they are drawn once per frame on the render
/// thread (Core Text is thread-safe) and shown as a layer above the cushion raster. The view
/// can then hide, fade or scale them without touching the raster.
enum LabelRenderer {
    static func labelOptions(for key: RenderKey) -> TreemapLabelOptions {
        var options = TreemapLabelOptions(scale: key.scale)
        options.minFontSize = 9.5
        options.maxFontSize = 13
        options.minTileWidth = 54
        options.headerFontSize = 12
        options.maxCount = 900
        return options
    }

    static func makePixels(
        layout: TreemapLayout, key: RenderKey, mask: NodeBitset?, tileColor: (NodeID) -> RGB, target: RenderTarget = .image
    ) -> FramePixels? {
        let labels = layout.labels(labelOptions(for: key))
        guard !labels.isEmpty else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // Work in layout pixels whatever the label image's own resolution is.
        let sx = CGFloat(key.labelWidth) / CGFloat(key.pixelWidth)
        let sy = CGFloat(key.labelHeight) / CGFloat(key.pixelHeight)

        if target == .layer, let surface = FramePixels.makeSurface(width: key.labelWidth, height: key.labelHeight) {
            surface.lock(options: [], seed: nil)
            // A new surface is zero-filled by the kernel, like any fresh shared memory, and
            // deliberately not cleared again here: untouched pages cost no memory, and the
            // label layer is mostly empty (clearing made every frame 18–64 MB heavier).
            let context = CGContext(
                data: surface.baseAddress, width: key.labelWidth, height: key.labelHeight, bitsPerComponent: 8,
                bytesPerRow: surface.bytesPerRow, space: FrameRenderer.sRGB, bitmapInfo: info)
            if let context {
                context.scaleBy(x: sx, y: sy)
                draw(labels, layout: layout, key: key, mask: mask, tileColor: tileColor, in: context)
            }
            surface.unlock(options: [], seed: nil)
            if context != nil { return FramePixels(surface: surface, alpha: .premultipliedFirst) }
        }
        guard
            let context = CGContext(
                data: nil, width: key.labelWidth, height: key.labelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: FrameRenderer.sRGB, bitmapInfo: info)
        else { return nil }
        context.scaleBy(x: sx, y: sy)
        draw(labels, layout: layout, key: key, mask: mask, tileColor: tileColor, in: context)
        return context.makeImage().map(FramePixels.init(image:))
    }

    /// The text and pill of one overlay label.
    struct OverlayPill {
        var name: TextLine
        var detail: TextLine?
        /// The dark rounded rectangle behind the text, in the coordinates of `box`.
        var pill: CGRect
    }

    /// Fits an overlay label into `box`, the label's reserved ``TreemapLabel/rect``. That rect
    /// is the contract with the layout (tile labels were placed around it), so the pill never
    /// extends past it: the name is truncated to the box, and the size is added only if the
    /// measured text still fits. `nil` if no readable name fits.
    ///
    /// - Parameter pad: `TreemapLabelOptions.overlayPaddingPixels` of the options the labels
    ///   were made with.
    static func overlayPill(
        name: String, sizeText: String, label: TreemapLabel, box: CGRect, pad: CGFloat, fonts: inout FontCache,
        textColor: CGColor, detailColor: CGColor
    ) -> OverlayPill? {
        let fontSize = CGFloat(label.fontSize)
        let available = box.width - 2 * pad
        guard available > fontSize * 2,
            let name = TextLine(name, font: fonts.font(fontSize, .semibold), color: textColor, maxWidth: available, truncation: .end)
        else { return nil }
        var detail: TextLine?
        // `fitsDetail` is the layout's estimate; real glyph widths decide.
        if !name.isTruncated,
            let line = TextLine(
                sizeText, font: fonts.font(fontSize * 0.92, .regular), color: detailColor,
                maxWidth: .greatestFiniteMagnitude, truncation: .end),
            name.width + line.width + pad * 1.4 <= available
        {
            detail = line
        }
        let textWidth = name.width + (detail.map { $0.width + pad * 1.4 } ?? 0)
        let pill = CGRect(x: box.minX, y: box.minY, width: min(textWidth + 2 * pad, box.width), height: box.height)
        return OverlayPill(name: name, detail: detail, pill: pill)
    }

    /// Draws into a context whose units are layout pixels with the origin at the BOTTOM left
    /// (plain Core Graphics), flipping the layout's y-down rectangles itself.
    static func draw(
        _ labels: [TreemapLabel], layout: TreemapLayout, key: RenderKey, mask: NodeBitset?,
        tileColor: (NodeID) -> RGB, in context: CGContext
    ) {
        let tree = layout.tree
        let height = CGFloat(layout.bounds.height)
        let scale = CGFloat(key.scale)
        var fonts = FontCache()
        let dark = key.scheme == .dark
        // The same padding the layout reserved the overlay boxes with.
        let overlayPad = CGFloat(labelOptions(for: key).overlayPaddingPixels)

        // Frames are near-white in the light scheme and near-black in the dark one.
        let frameText = dark ? CGColor(gray: 0.93, alpha: 0.92) : CGColor(gray: 0.10, alpha: 0.88)
        let frameDetail = dark ? CGColor(gray: 0.93, alpha: 0.52) : CGColor(gray: 0.10, alpha: 0.50)
        let lightText = CGColor(gray: 1, alpha: 0.96)
        let lightDetail = CGColor(gray: 1, alpha: 0.74)
        let darkText = CGColor(gray: 0.05, alpha: 0.90)
        let darkDetail = CGColor(gray: 0.05, alpha: 0.62)

        func flip(_ r: TreemapRect) -> CGRect {
            CGRect(x: CGFloat(r.minX), y: height - CGFloat(r.maxY), width: CGFloat(r.width), height: CGFloat(r.height))
        }
        func size(_ node: NodeID) -> UInt64 {
            key.sizeMetric == .allocated ? tree.size(of: node) : tree.logicalSize(of: node)
        }

        for label in labels {
            let cell = layout.cells[label.cell]
            let lit = mask?.contains(label.node) ?? true
            let box = flip(label.rect)
            let fontSize = CGFloat(label.fontSize)

            switch label.kind {
            case .header:
                context.saveGState()
                // The outer two levels carry the map's structure; deeper titles step back.
                let deep = cell.frameLevel >= 2
                context.setAlpha((lit ? 1 : 0.45) * (deep ? 0.9 : 1))
                let font = fonts.font(fontSize, deep ? .medium : .semibold)
                // The size goes to the right edge; the name gets the rest. If that would cut
                // away much of the name, the name wins: the area already says "big".
                let detail = TextLine(
                    Format.bytes(size(label.node)), font: fonts.font((fontSize * 0.92).rounded(), .regular), color: frameDetail,
                    maxWidth: .greatestFiniteMagnitude, truncation: .end)
                let gap = (fontSize * 0.7).rounded()
                let unlimited = CGFloat.greatestFiniteMagnitude
                // A folder that fills its parent's frame shares the title, "a/b/c" — as much of
                // the chain as fits whole; the frame's own name is never shortened for it.
                let names = layout.titleChain(ofCell: label.cell).map { tree.name(of: $0) }
                func line(_ count: Int, _ width: CGFloat) -> TextLine? {
                    TextLine(names.prefix(count).joined(separator: "/"), font: font, color: frameText, maxWidth: width, truncation: .end)
                }
                let room = detail.map { box.width - $0.width - gap } ?? 0
                var name: TextLine?
                var showsDetail = false
                // 1. As much of the chain as fits whole next to the size.
                if room > 0 {
                    for count in stride(from: names.count, through: 1, by: -1) {
                        if let whole = line(count, unlimited), whole.width <= room {
                            name = whole
                            showsDetail = true
                            break
                        }
                    }
                }
                // 2. The frame's own name, lightly shortened, next to the size.
                if name == nil, let whole = line(1, unlimited), room >= max(whole.width * 0.65, fontSize * 4.4) {
                    name = line(1, room)
                    showsDetail = name != nil
                }
                // 3. No size: as much of the chain as fits whole, else the name cut to the strip.
                if name == nil {
                    for count in stride(from: names.count, through: 1, by: -1) {
                        if let whole = line(count, unlimited), whole.width <= box.width {
                            name = whole
                            break
                        }
                    }
                }
                if name == nil { name = line(1, box.width) }
                name?.draw(in: context, x: box.minX, centerY: box.midY)
                if showsDetail, let detail { detail.draw(in: context, x: box.maxX - detail.width, centerY: box.midY) }
                context.restoreGState()

            case .overlay:
                // A dark pill behind the text: an overlay sits on arbitrary tile colours.
                guard let overlay = overlayPill(
                    name: tree.name(of: label.node), sizeText: Format.bytes(size(label.node)), label: label, box: box,
                    pad: overlayPad, fonts: &fonts, textColor: lightText, detailColor: lightDetail)
                else { continue }
                let pill = overlay.pill
                context.saveGState()
                context.setAlpha(lit ? 1 : 0.5)
                let radius = min(5 * scale, pill.height / 2)
                context.addPath(CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(CGColor(gray: 0, alpha: dark ? 0.58 : 0.50))
                context.fillPath()
                overlay.name.draw(in: context, x: pill.minX + overlayPad, centerY: pill.midY)
                overlay.detail?.draw(
                    in: context, x: pill.minX + overlayPad + overlay.name.width + overlayPad * 1.4, centerY: pill.midY)
                context.restoreGState()

            case .folder:
                // A folder collapsed into one block: glyph and name in the top-left corner, the
                // size and its share of the folder shown on the line below.
                let onLight = Self.prefersDarkText(on: tileColor(cell.sample))
                var primary = onLight ? darkText : lightText
                var secondary = onLight ? darkDetail : lightDetail
                if !lit {
                    // The block is washed out towards the dim colour: the text goes with the
                    // scheme, not with the colour the block no longer has.
                    primary = dark ? CGColor(gray: 1, alpha: 0.62) : CGColor(gray: 0.05, alpha: 0.60)
                    secondary = dark ? CGColor(gray: 1, alpha: 0.42) : CGColor(gray: 0.05, alpha: 0.42)
                }
                // Narrow blocks drop the glyph before they drop letters.
                let showsGlyph = box.width >= fontSize * 5.2
                let glyphWidth = showsGlyph ? (fontSize * 1.18).rounded() : 0
                let gap = showsGlyph ? (fontSize * 0.42).rounded() : 0
                let nameFont = fonts.font(fontSize, .semibold)
                let nameWidth = box.width - glyphWidth - gap
                let text = tree.name(of: label.node)
                guard var name = TextLine(text, font: nameFont, color: primary, maxWidth: nameWidth, truncation: .end)
                else { continue }
                // A long name in a narrow, tall block runs on to a second line.
                var second: TextLine?
                if name.isTruncated, box.height >= name.lineHeight * 2.3,
                    let lines = TextLine.wrapped(text, font: nameFont, color: primary, firstWidth: nameWidth, restWidth: box.width)
                {
                    name = lines.first
                    second = lines.second
                }
                let nameHeight = name.lineHeight + (second.map { $0.lineHeight + fontSize * 0.08 } ?? 0)
                var detail: TextLine?
                let detailSize = max(9.5 * scale, (fontSize * 0.86).rounded())
                if label.fitsDetail, box.height >= nameHeight + fontSize * 0.22 + detailSize * 1.15 {
                    let detailFont = fonts.font(detailSize, .regular)
                    let bytes = Format.bytes(size(label.node))
                    let share = Format.percent(size(label.node), of: size(layout.root))
                    var candidates = ["\(bytes)  ·  \(share)", bytes]
                    if fontSize >= 14 * scale {
                        // Large blocks also say how much is inside.
                        candidates.insert("\(bytes)  ·  \(share)  ·  \(Format.items(tree.fileCount(of: label.node)))", at: 0)
                    }
                    for candidate in candidates {
                        if let line = TextLine(candidate, font: detailFont, color: secondary, maxWidth: box.width, truncation: .end),
                            !line.isTruncated
                        {
                            detail = line
                            break
                        }
                    }
                }
                context.saveGState()
                context.clip(to: flip(cell.rect))
                if lit {
                    context.setShadow(
                        offset: CGSize(width: 0, height: onLight ? 0 : -0.75 * scale), blur: (onLight ? 2.5 : 2) * scale,
                        color: onLight ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.55))
                }
                let lineCenter = box.maxY - name.lineHeight / 2
                if showsGlyph {
                    let glyph = CGRect(
                        x: box.minX, y: lineCenter - fontSize * 0.45, width: glyphWidth, height: (fontSize * 0.9).rounded())
                    context.addPath(folderGlyph(in: glyph))
                    context.setFillColor(primary)
                    context.fillPath()
                }
                name.draw(in: context, x: box.minX + glyphWidth + gap, centerY: lineCenter)
                if let second {
                    second.draw(in: context, x: box.minX, centerY: box.maxY - name.lineHeight - fontSize * 0.08 - second.lineHeight / 2)
                }
                if let detail {
                    let top = box.maxY - nameHeight - fontSize * 0.22
                    detail.draw(in: context, x: box.minX, centerY: top - detail.lineHeight / 2)
                }
                context.restoreGState()

            case .tile, .aggregate:
                guard lit else { continue }
                // Black or white text, whichever contrasts with the tile's own colour.
                let onLight = Self.prefersDarkText(on: tileColor(cell.sample))
                let isAggregate = label.kind == .aggregate
                let text: String
                let truncation: CTLineTruncationType
                if isAggregate {
                    text = Format.counted(cell.mergedCount, singular: "small item", plural: "small items")
                    truncation = .end
                } else {
                    text = tree.name(of: label.node)
                    // Middle truncation keeps a file's extension visible.
                    truncation = cell.isDirectory ? .end : .middle
                }
                let font = fonts.font(fontSize, isAggregate ? .regular : .medium)
                let primary = onLight ? darkText : lightText
                guard let name = TextLine(text, font: font, color: isAggregate ? (onLight ? darkDetail : lightDetail) : primary, maxWidth: box.width, truncation: truncation)
                else { continue }
                var detail: TextLine?
                if label.fitsDetail, !isAggregate {
                    detail = TextLine(
                        Format.bytes(size(label.node)), font: fonts.font(max(9 * scale, fontSize * 0.86), .regular),
                        color: onLight ? darkDetail : lightDetail, maxWidth: box.width, truncation: .end)
                }
                context.saveGState()
                context.clip(to: flip(cell.rect))
                // A soft halo of the opposite tone keeps the text readable across the cushion's
                // highlight and shadow.
                context.setShadow(
                    offset: CGSize(width: 0, height: onLight ? 0 : -0.75 * scale), blur: (onLight ? 2.5 : 2) * scale,
                    color: onLight ? CGColor(gray: 1, alpha: 0.55) : CGColor(gray: 0, alpha: 0.6))
                if let detail {
                    let gap = fontSize * 0.18
                    let total = name.lineHeight + gap + detail.lineHeight
                    let top = box.midY + total / 2
                    name.draw(in: context, x: box.midX - name.width / 2, centerY: top - name.lineHeight / 2)
                    detail.draw(
                        in: context, x: box.midX - detail.width / 2, centerY: top - name.lineHeight - gap - detail.lineHeight / 2)
                } else {
                    name.draw(in: context, x: box.midX - name.width / 2, centerY: box.midY)
                }
                context.restoreGState()
            }
        }
    }
}

extension LabelRenderer {
    /// Whether text on a tile of this colour should be dark. White (with its soft shadow) is
    /// the default; dark text is for clearly light tiles only, so the many mid-tone greys and
    /// blues of a map all come out the same way instead of flipping between neighbours.
    static func prefersDarkText(on color: RGB) -> Bool {
        let luminance = 0.2126 * color.r * color.r + 0.7152 * color.g * color.g + 0.0722 * color.b * color.b
        return luminance > 0.64
    }

    /// A small filled folder (tab on the top left) fitted into `rect`; y-up coordinates.
    static func folderGlyph(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let radius = rect.height * 0.16
        let bodyHeight = rect.height * 0.80
        path.addRoundedRect(
            in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bodyHeight), cornerWidth: radius,
            cornerHeight: radius)
        // The tab: reaches down behind the body so the two shapes read as one.
        let tabHeight = rect.height * 0.5
        path.addRoundedRect(
            in: CGRect(x: rect.minX, y: rect.maxY - tabHeight, width: rect.width * 0.46, height: tabHeight),
            cornerWidth: radius, cornerHeight: radius)
        return path
    }
}

/// System fonts by pixel size and weight; creating a font per label would dominate the cost.
struct FontCache {
    private struct Key: Hashable {
        var size: Int
        var weight: Int
    }
    enum Weight: Int {
        case regular, medium, semibold
    }
    private var fonts: [Key: CTFont] = [:]

    mutating func font(_ size: CGFloat, _ weight: Weight) -> CTFont {
        // Quarter-pixel buckets: finer steps are invisible and would defeat the cache.
        let key = Key(size: Int((size * 4).rounded()), weight: weight.rawValue)
        if let font = fonts[key] { return font }
        let nsWeight: NSFont.Weight =
            switch weight {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            }
        let font = NSFont.systemFont(ofSize: CGFloat(key.size) / 4, weight: nsWeight) as CTFont
        fonts[key] = font
        return font
    }
}

/// One line of text, measured and truncated to a width.
struct TextLine {
    let line: CTLine
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let isTruncated: Bool

    var lineHeight: CGFloat { ascent + descent }

    /// `nil` if the text is empty or nothing useful fits into `maxWidth`.
    init?(_ text: String, font: CTFont, color: CGColor, maxWidth: CGFloat, truncation: CTLineTruncationType) {
        guard !text.isEmpty, maxWidth > 0 else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        var truncated = false
        if width > maxWidth {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            guard let short = CTLineCreateTruncatedLine(line, Double(maxWidth), truncation, ellipsis) else { return nil }
            // An ellipsis with one or two glyphs is noise, not a name.
            guard CTLineGetGlyphCount(short) >= 4 else { return nil }
            line = short
            width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            truncated = true
        }
        self.line = line
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.isTruncated = truncated
    }

    /// Draws with the left edge at `x`, vertically centred on `centerY` (y-up context).
    func draw(in context: CGContext, x: CGFloat, centerY: CGFloat) {
        // Centre on the cap height rather than ascent + descent: text looks optically centred.
        context.textPosition = CGPoint(x: x, y: centerY - (ascent - descent) / 2 + descent * 0.25)
        CTLineDraw(line, context)
    }

    /// Breaks `text` into a first line of at most `firstWidth` and a second of at most
    /// `restWidth` (truncated if the rest is still too long). `nil` if a break would leave
    /// fewer than two characters on either line.
    static func wrapped(
        _ text: String, font: CTFont, color: CGColor, firstWidth: CGFloat, restWidth: CGFloat
    ) -> (first: TextLine, second: TextLine)? {
        guard firstWidth > 0, restWidth > 0 else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let string = text as NSString
        let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var count = CTTypesetterSuggestClusterBreak(typesetter, 0, Double(firstWidth))
        guard count >= 2, count < string.length else { return nil }
        // Break after a separator if the first line has one; otherwise inside the word, but
        // never leaving a stub of one or two letters on either line.
        let separators = CharacterSet(charactersIn: " -_.")
        var natural = count
        while natural > 2, let scalar = UnicodeScalar(string.character(at: natural - 1)), !separators.contains(scalar) { natural -= 1 }
        if natural > 2 {
            count = natural
        } else {
            count = min(count, string.length - 3)
            guard count >= 3 else { return nil }
        }
        let head = string.substring(to: count).trimmingCharacters(in: .whitespaces)
        let tail = string.substring(from: count).trimmingCharacters(in: .whitespaces)
        guard let first = TextLine(head, font: font, color: color, maxWidth: .greatestFiniteMagnitude, truncation: .end),
            let second = TextLine(tail, font: font, color: color, maxWidth: restWidth, truncation: .end)
        else { return nil }
        return (first, second)
    }
}
