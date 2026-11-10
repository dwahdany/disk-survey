import Foundation
import DiskSurveyCore

/// Supplies the base colour of each drawn tile.
///
/// Colours are given as ordinary sRGB-encoded ``RGB`` values (what the palette functions in
/// DiskSurveyCore return); the renderer converts them to linear light for shading itself.
///
/// A tile is coloured by its *sample* node (``TreemapCell/sample``): the file itself, or for a
/// collapsed directory or an aggregate of small items, the largest file inside — so a folder
/// too small to subdivide takes the colour of what mostly fills it.
public struct TreemapColoring: Sendable {
    enum Storage: Sendable {
        case kinds([SIMD3<Float>])
        case age(now: Int64, colors: [SIMD3<Float>])
        case custom(@Sendable (NodeID, FileTree) -> RGB)
    }

    let storage: Storage

    /// Colour by file kind using the standard palette for the tree's kind table.
    public static func byKind(_ tree: FileTree, scheme: PaletteScheme = .light) -> TreemapColoring {
        byKind(colors: tree.kindColors(scheme: scheme))
    }

    /// Colour by file kind with explicit colours indexed by `KindID` (kinds beyond the table
    /// use the last entry).
    public static func byKind(colors: [RGB]) -> TreemapColoring {
        let table = colors.isEmpty ? [RGB(r: 0.6, g: 0.6, b: 0.6)] : colors
        return TreemapColoring(storage: .kinds(table.map(ColorTables.linear)))
    }

    /// Colour by modification age relative to `now` (epoch seconds) using the standard age ramp.
    public static func byAge(now: Int64, scheme: PaletteScheme = .light) -> TreemapColoring {
        byAge(now: now, colors: AgePalette.colors(scheme: scheme))
    }

    /// Colour by modification age with explicit colours indexed by `AgeBucket.rawValue`.
    public static func byAge(now: Int64, colors: [RGB]) -> TreemapColoring {
        precondition(colors.count >= AgeBucket.allCases.count, "one colour per AgeBucket is required")
        return TreemapColoring(storage: .age(now: now, colors: colors.map(ColorTables.linear)))
    }

    /// Any other scheme. The closure is called once per drawn tile with the tile's sample node,
    /// concurrently from several threads.
    public static func custom(_ color: @escaping @Sendable (NodeID, FileTree) -> RGB) -> TreemapColoring {
        TreemapColoring(storage: .custom(color))
    }

    /// Every tile the same colour.
    public static func uniform(_ color: RGB) -> TreemapColoring {
        TreemapColoring(storage: .kinds([ColorTables.linear(color)]))
    }

    /// Linear-light colour of a sample node.
    @inline(__always) func linearColor(of node: NodeID, in tree: FileTree) -> SIMD3<Float> {
        switch storage {
        case .kinds(let table):
            return table[min(Int(tree.kind(of: node)), table.count - 1)]
        case .age(let now, let colors):
            return colors[AgeBucket(modified: tree.modified(of: node), now: now).rawValue]
        case .custom(let body):
            return ColorTables.linear(body(node, tree))
        }
    }
}

/// Appearance of the rasterized map.
public struct TreemapRenderOptions: Sendable {
    /// Direction *towards* the light in layout coordinates (y down, z out of the screen).
    /// Need not be normalised. The default lights from the top-left, slightly off vertical.
    public var lightDirection: SIMD3<Float>
    /// Brightness every surface has regardless of orientation (0…1).
    ///
    /// `ambient` and `diffuse` are *perceptual* brightness factors: the shaded brightness
    /// `ambient + diffuse · cos θ` is squared (gamma 2) to get the factor applied to the base
    /// colour in linear light. Specifying them perceptually keeps the shadows from going
    /// muddy, which is what makes classic linear-ramp cushion maps look harsh.
    public var ambient: Float
    /// Strength of the directional light; `ambient + diffuse` is the brightness of a surface
    /// facing the light squarely (1 reproduces the base colour).
    public var diffuse: Float
    /// Multiplier on the cushion slopes stored in the layout: 0 is flat, 1 the layout's own
    /// height, larger exaggerates.
    public var relief: Float
    /// How much the one-pixel bottom and right edges of each tile are darkened (0 = no
    /// separators, 1 = black). One device pixel wide, so it stays crisp at any scale factor.
    public var separator: Float
    /// How much the one-pixel top and left edges are lightened (0 = none) — a faint bevel that
    /// makes tiles read as lit from the top-left.
    public var bevel: Float
    /// Tiles narrower or shorter than this many pixels get neither separator nor bevel.
    public var minSeparatedSide: Int
    /// Fill colours of directory frames (padding and headers) by nesting level
    /// (``TreemapCell/frameLevel``): index 0 for a frame inside no other frame, index 1 for a
    /// frame inside one other, …; the last entry repeats.
    public var frameColors: [RGB]
    /// Colour of the one-pixel line along the outer edge of every directory frame, which keeps
    /// neighbouring folders (whose frames have the same fill) visibly apart. `nil` draws none.
    public var frameBorderColor: RGB?
    /// Colour of pixels outside the layout's bounds and of an empty map.
    public var backgroundColor: RGB
    /// When set, tiles whose node is NOT in the set are dimmed. Pass
    /// `tree.containingMask(for: matches)` rather than the bare matches so that collapsed
    /// directories containing a match stay lit. For an aggregate tile the first few hundred
    /// merged siblings are tested.
    public var highlight: NodeBitset?
    /// How far dimmed tiles move towards ``dimColor`` (0 = not at all, 1 = completely).
    public var dimAmount: Float
    public var dimColor: RGB
    /// Factor applied to ``relief`` for dimmed tiles (below 1 flattens them).
    public var dimRelief: Float
    /// Factor applied to ``relief`` for folders collapsed by the depth limit: a block that
    /// stands for a whole folder is a calmer surface than a file's pillow.
    public var collapsedRelief: Float = 0.55
    /// Whether folders collapsed by the depth limit get a one-pixel gutter around them.
    public var collapsedGutter = true
    /// Ordered dithering of the 8-bit output, which removes banding in large smooth cushions.
    public var dither: Bool
    /// Upper bound on worker threads; 0 uses all cores.
    public var maxThreads: Int

    public init(
        lightDirection: SIMD3<Float> = SIMD3(-0.24, -0.38, 1.0), ambient: Float = 0.56, diffuse: Float = 0.48,
        relief: Float = 1, separator: Float = 0.30, bevel: Float = 0.08, minSeparatedSide: Int = 4,
        frameColors: [RGB] = [
            RGB(r: 0.775, g: 0.785, b: 0.825), RGB(r: 0.835, g: 0.845, b: 0.88), RGB(r: 0.885, g: 0.892, b: 0.918),
            RGB(r: 0.925, g: 0.93, b: 0.948), RGB(r: 0.955, g: 0.958, b: 0.97),
        ], frameBorderColor: RGB? = RGB(r: 0.50, g: 0.51, b: 0.55), backgroundColor: RGB = RGB(r: 0.93, g: 0.93, b: 0.94),
        highlight: NodeBitset? = nil, dimAmount: Float = 0.85, dimColor: RGB = RGB(r: 0.80, g: 0.80, b: 0.815), dimRelief: Float = 0.45,
        dither: Bool = true, maxThreads: Int = 0
    ) {
        self.lightDirection = lightDirection
        self.ambient = ambient
        self.diffuse = diffuse
        self.relief = relief
        self.separator = separator
        self.bevel = bevel
        self.minSeparatedSide = minSeparatedSide
        self.frameColors = frameColors
        self.frameBorderColor = frameBorderColor
        self.backgroundColor = backgroundColor
        self.highlight = highlight
        self.dimAmount = dimAmount
        self.dimColor = dimColor
        self.dimRelief = dimRelief
        self.dither = dither
        self.maxThreads = maxThreads
    }

    /// The tuned default look for a light or dark appearance.
    public static func standard(scheme: PaletteScheme = .light) -> TreemapRenderOptions {
        switch scheme {
        case .light:
            return TreemapRenderOptions()
        case .dark:
            return TreemapRenderOptions(
                ambient: 0.54, diffuse: 0.50, separator: 0.36, bevel: 0.06,
                frameColors: [
                    RGB(r: 0.115, g: 0.12, b: 0.135), RGB(r: 0.165, g: 0.17, b: 0.187), RGB(r: 0.215, g: 0.22, b: 0.24),
                    RGB(r: 0.265, g: 0.27, b: 0.292), RGB(r: 0.315, g: 0.32, b: 0.345),
                ],
                frameBorderColor: RGB(r: 0.035, g: 0.035, b: 0.045),
                backgroundColor: RGB(r: 0.09, g: 0.09, b: 0.10),
                dimColor: RGB(r: 0.17, g: 0.17, b: 0.185))
        }
    }
}

/// Cushion-shaded rasterizer for ``TreemapLayout``.
///
/// Shading follows van Wijk & van de Wetering: each tile's surface is a sum of parabolic
/// ridges (one per nesting level), lit by a single directional light. Lighting is computed in
/// linear light and encoded to sRGB through a lookup table with ordered dithering.
///
/// Tiles never overlap, so the work is split into batches of cells (large tiles additionally
/// into row bands) that are painted concurrently without any locking.
public enum TreemapRenderer {
    /// Renders into a new bitmap of the layout's size (bounds rounded up to whole pixels).
    public static func render(
        _ layout: TreemapLayout, coloring: TreemapColoring, options: TreemapRenderOptions = TreemapRenderOptions()
    ) -> TreemapBitmap {
        let bitmap = TreemapBitmap(
            width: max(0, Int(layout.bounds.maxX.rounded(.up))), height: max(0, Int(layout.bounds.maxY.rounded(.up))),
            cleared: false)
        render(layout, coloring: coloring, options: options, into: bitmap)
        return bitmap
    }

    /// Renders into an existing bitmap. Layout coordinates are bitmap pixel coordinates (top-left
    /// origin). Every pixel of the bitmap is written: those outside the layout's bounds get
    /// `options.backgroundColor`.
    public static func render(
        _ layout: TreemapLayout, coloring: TreemapColoring, options: TreemapRenderOptions = TreemapRenderOptions(),
        into bitmap: TreemapBitmap
    ) {
        guard bitmap.width > 0, bitmap.height > 0 else { return }
        let context = RenderContext(layout: layout, coloring: coloring, options: options, bitmap: bitmap)
        context.fillOutside()
        let tasks = context.makeTasks()
        let threads = options.maxThreads > 0 ? options.maxThreads : ProcessInfo.processInfo.activeProcessorCount
        if threads <= 1 || tasks.count <= 1 {
            let scratch = RenderScratch(width: bitmap.width)
            for task in tasks { context.run(task, scratch) }
        } else if options.maxThreads > 0 {
            // A bounded number of workers pulling tasks in strides.
            DispatchQueue.concurrentPerform(iterations: threads) { worker in
                let scratch = RenderScratch(width: bitmap.width)
                var index = worker
                while index < tasks.count {
                    context.run(tasks[index], scratch)
                    index += threads
                }
            }
        } else {
            DispatchQueue.concurrentPerform(iterations: tasks.count) { index in
                context.run(tasks[index], RenderScratch(width: bitmap.width))
            }
        }
    }
}

// MARK: - Implementation

/// Lookup tables shared by all renders.
enum ColorTables {
    static let encodeSize = 4096

    /// sRGB encoding of linear values `i / 4095`, scaled to 0…255 and kept fractional so the
    /// dither can decide the rounding. One extra entry so a clamped index of 4096 is valid.
    nonisolated(unsafe) static let encode: UnsafePointer<Float> = {
        let table = UnsafeMutablePointer<Float>.allocate(capacity: encodeSize + 1)
        for i in 0 ... encodeSize {
            let x = min(1, Double(i) / Double(encodeSize - 1))
            let s = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            table[i] = Float(s * 255)
        }
        return UnsafePointer(table)
    }()

    /// 8×8 Bayer thresholds in (0, 1), row-major.
    nonisolated(unsafe) static let bayer: UnsafePointer<Float> = {
        let table = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        for y in 0 ..< 8 {
            for x in 0 ..< 8 {
                // Bit-reversed interleave of (x xor y) and y: the low coordinate bits become the
                // high threshold bits, which is what spreads the pattern evenly.
                var value = 0
                for bit in 0 ..< 3 {
                    value = value << 2 | (((x ^ y) >> bit) & 1) << 1 | ((y >> bit) & 1)
                }
                table[y * 8 + x] = (Float(value) + 0.5) / 64
            }
        }
        return UnsafePointer(table)
    }()

    @inline(__always) static func decode(_ c: Double) -> Float {
        let x = min(1, max(0, c))
        return Float(x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4))
    }

    /// sRGB-encoded colour to linear light.
    static func linear(_ color: RGB) -> SIMD3<Float> {
        SIMD3(decode(color.r), decode(color.g), decode(color.b))
    }

    /// Linear colour to a packed opaque pixel, rounding to nearest.
    static func pixel(_ linear: SIMD3<Float>) -> UInt32 {
        func channel(_ v: Float) -> UInt32 {
            UInt32(encode[Int(min(1, max(0, v)) * Float(encodeSize - 1) + 0.5)] + 0.5)
        }
        return 0xFF00_0000 | channel(linear.x) << 16 | channel(linear.y) << 8 | channel(linear.z)
    }
}

/// Per-thread working memory: one float per column for each of the per-column terms.
final class RenderScratch {
    let nxL: UnsafeMutablePointer<Float>
    let nx2: UnsafeMutablePointer<Float>
    let columnScale: UnsafeMutablePointer<Float>
    let intensity: UnsafeMutablePointer<Float>

    init(width: Int) {
        let n = max(8, width + 8)
        nxL = .allocate(capacity: n)
        nx2 = .allocate(capacity: n)
        columnScale = .allocate(capacity: n)
        intensity = .allocate(capacity: n)
    }

    deinit {
        nxL.deallocate()
        nx2.deallocate()
        columnScale.deallocate()
        intensity.deallocate()
    }
}

/// A unit of parallel work: a run of cells, or (for one big tile) a band of its rows.
struct RenderTask {
    var firstCell: Int
    var endCell: Int
    var rowStart: Int
    var rowEnd: Int
}

struct RenderContext: @unchecked Sendable {
    let layout: TreemapLayout
    let coloring: TreemapColoring
    let options: TreemapRenderOptions
    let bitmap: TreemapBitmap
    let light: SIMD3<Float>
    let frameLinear: [SIMD3<Float>]
    let framePixels: [UInt32]
    let frameBorder: UInt32?
    let dimLinear: SIMD3<Float>
    let background: UInt32
    /// With a highlight: for each cell index, whether an aggregate cell merges at least one
    /// highlighted item. Computed once, before the concurrent phase; empty without a highlight.
    let litAggregates: [Bool]

    init(layout: TreemapLayout, coloring: TreemapColoring, options: TreemapRenderOptions, bitmap: TreemapBitmap) {
        self.layout = layout
        self.coloring = coloring
        self.options = options
        self.bitmap = bitmap
        let l = options.lightDirection
        let length = (l.x * l.x + l.y * l.y + l.z * l.z).squareRoot()
        light = length > 0 ? l / length : SIMD3(0, 0, 1)
        frameLinear = (options.frameColors.isEmpty ? [options.backgroundColor] : options.frameColors).map(ColorTables.linear)
        framePixels = frameLinear.map(ColorTables.pixel)
        frameBorder = options.frameBorderColor.map { ColorTables.pixel(ColorTables.linear($0)) }
        dimLinear = ColorTables.linear(options.dimColor)
        background = ColorTables.pixel(ColorTables.linear(options.backgroundColor))
        litAggregates = options.highlight.map { Self.litAggregates(of: layout, mask: $0) } ?? []
    }

    /// Which aggregate cells contain a highlighted item, exactly: an aggregate stands for the
    /// children of its directory that take space but have no cell of their own — the same rule
    /// by which ``TreemapLayout/locate(_:)`` sends a node to the aggregate.
    ///
    /// The directory's own bit says nothing by itself: a containing mask also sets it when the
    /// only matches are the big children drawn as separate tiles.
    static func litAggregates(of layout: TreemapLayout, mask: NodeBitset) -> [Bool] {
        let tree = layout.tree
        let allocated = layout.options.sizeMetric == .allocated
        var lit = [Bool](repeating: false, count: layout.cells.count)
        var drawn = Set<NodeID>()
        layout.cells.withUnsafeBufferPointer { cells in
            for index in cells.indices where cells[index].isAggregate {
                let cell = cells[index]
                if mask.contains(cell.sample) {
                    lit[index] = true
                    continue
                }
                // No highlighted child without the directory's bit: skips the walk for the many
                // directories a search does not touch.
                guard mask.contains(cell.node), cell.parent >= 0, Int(cell.node) < tree.count else { continue }
                drawn.removeAll(keepingCapacity: true)
                for sibling in cells[Int(cell.parent)].children where sibling != index { drawn.insert(cells[sibling].node) }
                for child in tree.children(of: cell.node) where mask.contains(child) {
                    let size = allocated ? tree.size(of: child) : tree.logicalSize(of: child)
                    if size > 0, !drawn.contains(child) {
                        lit[index] = true
                        break
                    }
                }
            }
        }
        return lit
    }

    @inline(__always) private func snap(_ v: Float, _ limit: Int) -> Int {
        // Same float, same result: shared edges land on the same pixel boundary. The rule is
        // shared with hit-testing.
        let r = TreemapRect.pixelEdge(v)
        return r <= 0 ? 0 : (r >= Float(limit) ? limit : Int(r))
    }

    private func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ pixel: UInt32) {
        guard x1 > x0, y1 > y0 else { return }
        for y in y0 ..< y1 {
            (bitmap.pixels + y * bitmap.width + x0).update(repeating: pixel, count: x1 - x0)
        }
    }

    /// Paints whatever part of the bitmap the layout does not cover.
    func fillOutside() {
        let w = bitmap.width
        let h = bitmap.height
        let b = layout.bounds
        let x0 = snap(b.minX, w)
        let x1 = max(x0, snap(b.maxX, w))
        let y0 = snap(b.minY, h)
        let y1 = max(y0, snap(b.maxY, h))
        fill(0, 0, w, y0, background)
        fill(0, y1, w, h, background)
        fill(0, y0, x0, y1, background)
        fill(x1, y0, w, y1, background)
    }

    func makeTasks() -> [RenderTask] {
        var tasks: [RenderTask] = []
        // Batches of roughly this many pixels keep scheduling overhead negligible while still
        // balancing well across cores.
        let batchPixels: Float = 24_000
        let bigTile: Float = 96_000
        var start = 0
        var accumulated: Float = 0
        layout.cells.withUnsafeBufferPointer { cells in
            for index in cells.indices {
                let cell = cells[index]
                guard cell.isLeaf else {
                    if !cell.flags.isDisjoint(with: [.header, .padded]) { accumulated += 256 }
                    continue
                }
                let area = cell.rect.area
                if area > bigTile {
                    if index > start { tasks.append(RenderTask(firstCell: start, endCell: index, rowStart: 0, rowEnd: .max)) }
                    let y0 = snap(cell.rect.minY, bitmap.height)
                    let y1 = snap(cell.rect.maxY, bitmap.height)
                    let rows = max(8, Int(batchPixels / max(1, cell.rect.width)))
                    var y = y0
                    while y < y1 {
                        tasks.append(RenderTask(firstCell: index, endCell: index + 1, rowStart: y, rowEnd: min(y1, y + rows)))
                        y += rows
                    }
                    start = index + 1
                    accumulated = 0
                } else {
                    accumulated += area + 24
                    if accumulated >= batchPixels {
                        tasks.append(RenderTask(firstCell: start, endCell: index + 1, rowStart: 0, rowEnd: .max))
                        start = index + 1
                        accumulated = 0
                    }
                }
            }
            if start < cells.count {
                tasks.append(RenderTask(firstCell: start, endCell: cells.count, rowStart: 0, rowEnd: .max))
            }
        }
        return tasks
    }

    func run(_ task: RenderTask, _ scratch: RenderScratch) {
        layout.cells.withUnsafeBufferPointer { cells in
            for index in task.firstCell ..< task.endCell {
                let cell = cells[index]
                if cell.isLeaf {
                    paintTile(cell, index: index, rowStart: task.rowStart, rowEnd: task.rowEnd, scratch)
                } else if !cell.flags.isDisjoint(with: [.header, .padded]) {
                    paintFrame(cell)
                }
            }
        }
    }

    /// The ring between a framed directory's rectangle and its content rectangle.
    private func paintFrame(_ cell: TreemapCell) {
        let w = bitmap.width
        let h = bitmap.height
        let content = layout.options.style.contentRect(of: cell.rect, flags: cell.flags, level: Int(cell.frameLevel))
        let x0 = snap(cell.rect.minX, w)
        let x1 = snap(cell.rect.maxX, w)
        let y0 = snap(cell.rect.minY, h)
        let y1 = snap(cell.rect.maxY, h)
        let cx0 = min(x1, max(x0, snap(content.minX, w)))
        let cx1 = min(x1, max(cx0, snap(content.maxX, w)))
        let cy0 = min(y1, max(y0, snap(content.minY, h)))
        let cy1 = min(y1, max(cy0, snap(content.maxY, h)))
        let pixel = framePixels[min(framePixels.count - 1, Int(cell.frameLevel))]
        fill(x0, y0, x1, cy0, pixel)
        fill(x0, cy1, x1, y1, pixel)
        fill(x0, cy0, cx0, cy1, pixel)
        fill(cx1, cy0, x1, cy1, pixel)
        // A hairline along the outer edge, wherever the frame has any thickness there.
        guard let border = frameBorder, x1 - x0 >= 3, y1 - y0 >= 3 else { return }
        if cy0 > y0 { fill(x0, y0, x1, y0 + 1, border) }
        if cy1 < y1 { fill(x0, y1 - 1, x1, y1, border) }
        if cx0 > x0 { fill(x0, y0, x0 + 1, y1, border) } else if cy0 > y0 { fill(x0, y0, x0 + 1, cy0, border) }
        if cx1 < x1 { fill(x1 - 1, y0, x1, y1, border) } else if cy0 > y0 { fill(x1 - 1, y0, x1, cy0, border) }
    }

    private func isHighlighted(_ cell: TreemapCell, index: Int, _ mask: NodeBitset) -> Bool {
        cell.isAggregate ? litAggregates[index] : mask.contains(cell.node)
    }

    private func paintTile(_ cell: TreemapCell, index: Int, rowStart: Int, rowEnd: Int, _ scratch: RenderScratch) {
        let width = bitmap.width
        var x0 = snap(cell.rect.minX, width)
        var x1 = snap(cell.rect.maxX, width)
        var top = snap(cell.rect.minY, bitmap.height)
        var bottom = snap(cell.rect.maxY, bitmap.height)
        if cell.flags.contains(.collapsed), options.collapsedGutter, x1 - x0 >= 8, bottom - top >= 8 {
            // A folder shown as one block is set apart from its neighbours by a one-pixel ring
            // in the tint of the frame around it, so two blocks of the same colour stay two.
            let ring = framePixels[min(framePixels.count - 1, max(0, Int(cell.frameLevel) - 1))]
            let r0 = max(top, rowStart)
            let r1 = min(bottom, rowEnd)
            if r1 > r0 {
                if top >= rowStart { fill(x0, top, x1, top + 1, ring) }
                if bottom <= rowEnd { fill(x0, bottom - 1, x1, bottom, ring) }
                fill(x0, r0, x0 + 1, r1, ring)
                fill(x1 - 1, r0, x1, r1, ring)
            }
            x0 += 1
            x1 -= 1
            top += 1
            bottom -= 1
        }
        let y0 = max(top, rowStart)
        let y1 = min(bottom, rowEnd)
        let w = x1 - x0
        guard w > 0, y1 > y0 else { return }

        let tree = layout.tree
        // An empty map (root without contents) is just background.
        if cell.parent < 0, cell.isDirectory {
            fill(x0, y0, x1, y1, background)
            return
        }
        var base = coloring.linearColor(of: cell.sample, in: tree)
        var relief = options.relief
        if cell.flags.contains(.collapsed) { relief *= options.collapsedRelief }
        if let mask = options.highlight, !isHighlighted(cell, index: index, mask) {
            base += (dimLinear - base) * options.dimAmount
            // Dimmed tiles are also flattened so they recede behind the lit ones.
            relief *= options.dimRelief
        }
        // Pre-scaled to lookup-table indices.
        let scale = Float(ColorTables.encodeSize - 1)
        let r = base.x * scale
        let g = base.y * scale
        let b = base.z * scale
        let limit = scale

        let ax = cell.surface.ax * relief * 2
        let bx = cell.surface.bx * relief
        let ay = cell.surface.ay * relief * 2
        let by = cell.surface.by * relief
        let lx = light.x
        let ly = light.y
        let lz = light.z
        let ambient = options.ambient
        let diffuse = options.diffuse

        let nxL = scratch.nxL
        let nx2 = scratch.nx2
        let columnScale = scratch.columnScale
        let intensity = scratch.intensity

        // Everything that depends on the column only.
        let fx0 = Float(x0) + 0.5
        for i in 0 ..< w {
            let nx = -(ax * (fx0 + Float(i)) + bx)
            nxL[i] = nx * lx
            nx2[i] = nx * nx + 1
            columnScale[i] = 1
        }
        let edged = w >= options.minSeparatedSide && bottom - top >= options.minSeparatedSide
        let dark = 1 - options.separator
        let bright = 1 + options.bevel
        if edged {
            columnScale[0] = bright
            columnScale[w - 1] = dark
        }

        let encode = ColorTables.encode
        let bayer = ColorTables.bayer
        let dither = options.dither
        for y in y0 ..< y1 {
            let ny = -(ay * (Float(y) + 0.5) + by)
            let c0 = ny * ly + lz
            let d0 = ny * ny
            var rowScale: Float = 1
            if edged {
                if y == bottom - 1 { rowScale = dark } else if y == top { rowScale = bright }
            }
            let rowAmbient = ambient * rowScale
            let rowDiffuse = diffuse * rowScale
            // Pass 1: lighting, branch-free so it vectorises.
            for i in 0 ..< w {
                let cosine = (nxL[i] + c0) / (nx2[i] + d0).squareRoot()
                let lit = cosine > 0 ? cosine : 0
                let v = (rowAmbient + rowDiffuse * lit) * columnScale[i]
                // Brightness is specified perceptually; squaring (gamma 2) takes it to linear light.
                intensity[i] = v * v
            }
            // Pass 2: tint, encode, dither, store.
            let out = bitmap.pixels + y * width + x0
            let thresholds = bayer + (y & 7) * 8
            for i in 0 ..< w {
                let k = intensity[i]
                let t: Float = dither ? thresholds[(x0 + i) & 7] : 0.5
                let rr = UInt32(encode[Int(min(r * k, limit))] + t)
                let gg = UInt32(encode[Int(min(g * k, limit))] + t)
                let bb = UInt32(encode[Int(min(b * k, limit))] + t)
                out[i] = 0xFF00_0000 | rr << 16 | gg << 8 | bb
            }
        }
    }
}
