import AppKit
import IOSurface
import DiskSurveyCore
import DiskSurveyTreemap

/// Everything that determines the picture, except the tree and highlight payloads themselves
/// (those are identified by version counters so the key stays cheap to compare).
struct RenderKey: Hashable, Sendable {
    var treeVersion: Int
    /// Bumped whenever node ids of the previous tree stop being valid (a new scan snapshot).
    var idEpoch: Int
    var root: NodeID
    var pixelWidth: Int
    var pixelHeight: Int
    var labelWidth: Int
    var labelHeight: Int
    /// Layout pixels per point.
    var scale: Float
    var style: TreemapMapStyle
    var sizeMetric: TreemapLayoutOptions.SizeMetric
    var packagesAsLeaves: Bool
    var colorMode: TreemapColorMode
    var ageNow: Int64
    var scheme: PaletteScheme
    var highlightVersion: Int
    /// Multiplier on the cushion relief (1 = the standard look, 0 = flat tiles).
    var relief: Float = 1
    /// Thin dark separators and bevels around tiles.
    var tileBorders: Bool = true
    /// Whether the names are laid out and drawn. Off while the view hides them, which saves
    /// the label pass; it does not change the picture itself (see ``sameContent(as:)``).
    var labels: Bool = true
    /// How many folder levels below the root are subdivided (`Int.max` = all of them).
    var depth: Int = .max

    /// The same picture at another size (a pure resize needs no transition).
    func sameContent(as other: RenderKey) -> Bool {
        var a = self
        a.pixelWidth = other.pixelWidth
        a.pixelHeight = other.pixelHeight
        a.labelWidth = other.labelWidth
        a.labelHeight = other.labelHeight
        a.scale = other.scale
        a.labels = other.labels
        return a == other
    }
}

struct RenderRequest: Sendable {
    var serial: Int
    var key: RenderKey
    var tree: FileTree
    var highlight: TreemapHighlight
    /// Colour samples of collapsed folders, kept by the view across the frames of one tree.
    var sampleCache: CollapsedSampleCache?
}

/// One finished picture: the layout it shows (for hit-testing and overlays), the cushion
/// raster and the transparent label layer.
final class RenderedFrame: @unchecked Sendable {
    let request: RenderRequest
    let layout: TreemapLayout
    let pixels: FramePixels
    /// `nil` when nothing is labelled, or when the frame was rendered without labels.
    let labelPixels: FramePixels?
    /// Seconds spent on layout + raster + labels.
    let duration: Double

    init(request: RenderRequest, layout: TreemapLayout, pixels: FramePixels, labelPixels: FramePixels?, duration: Double) {
        self.request = request
        self.layout = layout
        self.pixels = pixels
        self.labelPixels = labelPixels
        self.duration = duration
    }

    /// The cushion raster as an image (for drawing into a context and cutting out drag images).
    var image: CGImage { pixels.image }
    /// The transparent label layer as an image.
    var labels: CGImage? { labelPixels?.image }

    var key: RenderKey { request.key }
    var tree: FileTree { layout.tree }

    func size(of node: NodeID) -> UInt64 {
        key.sizeMetric == .allocated ? tree.size(of: node) : tree.logicalSize(of: node)
    }

    /// Bytes a cell stands for (an aggregate sums the items it merged).
    func size(ofCell index: Int) -> UInt64 {
        let cell = layout.cells[index]
        guard cell.isAggregate else { return size(of: cell.node) }
        guard cell.firstChild >= 0 else { return 0 }
        let children = tree.children(of: cell.node)
        let start = children.startIndex + Int(cell.firstChild)
        let end = min(children.endIndex, start + cell.mergedCount)
        guard start < end else { return 0 }
        var total: UInt64 = 0
        for i in start ..< end { total &+= size(of: children[i]) }
        return total
    }
}

/// What a frame is rendered for.
enum RenderTarget: Sendable {
    /// Drawing into a `CGContext` (snapshots): plain images.
    case image
    /// Layer contents of the live view: IOSurfaces.
    case layer
}

/// The pixels of one picture (the raster, or the label layer).
///
/// For the live view they live in an `IOSurface`. Core Animation colour-matches a `CGImage`
/// whose colour space is not the display's profile on the CPU, in the thread that commits the
/// transaction — the main thread, 8–12 ms for a full-window picture on a non-sRGB display. A
/// tagged surface is handed to the window server as it is and matched on the GPU.
final class FramePixels: @unchecked Sendable {
    private let surface: IOSurface?
    private let stored: CGImage?
    private let alpha: CGImageAlphaInfo

    init(image: CGImage) {
        stored = image
        surface = nil
        alpha = image.alphaInfo
    }

    /// The surface must be complete and unlocked; it is never written to again.
    init(surface: IOSurface, alpha: CGImageAlphaInfo) {
        self.surface = surface
        self.alpha = alpha
        stored = nil
    }

    /// What to assign to `CALayer.contents`.
    var layerContents: Any { surface ?? stored as Any }

    var isSurface: Bool { surface != nil }

    /// The pixels as an image. For a surface this wraps its memory without copying; the image
    /// holds a read lock on the surface for as long as it (or anything cut out of it) lives.
    var image: CGImage {
        if let stored { return stored }
        let surface = surface!
        surface.lock(options: .readOnly, seed: nil)
        let retained = Unmanaged.passRetained(surface)
        let provider = CGDataProvider(
            dataInfo: retained.toOpaque(), data: UnsafeRawPointer(surface.baseAddress),
            size: surface.bytesPerRow * surface.height,
            releaseData: { info, _, _ in
                guard let info else { return }
                let surface = Unmanaged<IOSurface>.fromOpaque(info).takeRetainedValue()
                surface.unlock(options: .readOnly, seed: nil)
            })!
        let info = CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: surface.bytesPerRow, space: FrameRenderer.sRGB, bitmapInfo: info, provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// A BGRA surface tagged as sRGB (zero-filled by the system), or `nil` if none can be had.
    static func makeSurface(width: Int, height: Int) -> IOSurface? {
        guard width > 0, height > 0,
            let surface = IOSurface(properties: [
                .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: UInt32(0x4247_5241),  // 'BGRA'
            ])
        else { return nil }
        if let profile = sRGBPropertyList {
            IOSurfaceSetValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace, profile)
        }
        return surface
    }

    /// Immutable once created.
    private nonisolated(unsafe) static let sRGBPropertyList: CFPropertyList? = FrameRenderer.sRGB.copyPropertyList()

    /// Copies a finished raster into a surface (rows of a surface may be padded).
    static func surface(copying bitmap: TreemapBitmap) -> IOSurface? {
        guard let surface = makeSurface(width: bitmap.width, height: bitmap.height) else { return nil }
        surface.lock(options: [], seed: nil)
        let source = UnsafeRawPointer(bitmap.pixels)
        let rowBytes = bitmap.bytesPerRow
        if surface.bytesPerRow == rowBytes {
            surface.baseAddress.copyMemory(from: source, byteCount: bitmap.byteCount)
        } else {
            let stride = surface.bytesPerRow
            for y in 0 ..< bitmap.height {
                (surface.baseAddress + y * stride).copyMemory(from: source + y * rowBytes, byteCount: rowBytes)
            }
        }
        surface.unlock(options: [], seed: nil)
        return surface
    }
}

enum FrameRenderer {
    /// Upper bound on rasterized pixels. Beyond it (a 5K or 6K display, full screen) the map is
    /// rendered slightly below native resolution and scaled by the compositor; cushions are
    /// smooth gradients, so this is invisible while keeping a frame around 10 ms.
    static let maxPixels = 8_000_000
    /// Labels are text and do suffer from scaling, so they get a more generous budget.
    static let maxLabelPixels = 16_000_000

    struct PixelSize {
        var width: Int
        var height: Int
        var scale: CGFloat
    }

    static func pixelSize(for size: CGSize, backingScale: CGFloat, budget: Int = maxPixels) -> PixelSize {
        let area = max(1, size.width * size.height)
        let scale = min(max(0.5, backingScale), (CGFloat(budget) / area).squareRoot())
        return PixelSize(
            width: max(1, Int((size.width * scale).rounded())), height: max(1, Int((size.height * scale).rounded())),
            scale: scale)
    }

    static func makeKey(
        size: CGSize, backingScale: CGFloat, treeVersion: Int, idEpoch: Int, root: NodeID, style: TreemapMapStyle,
        sizeMetric: TreemapLayoutOptions.SizeMetric, packagesAsLeaves: Bool, colorMode: TreemapColorMode,
        ageNow: Int64, scheme: PaletteScheme, highlightVersion: Int, relief: Float = 1, tileBorders: Bool = true,
        labels drawsLabels: Bool = true, depth: Int = .max
    ) -> RenderKey {
        let map = pixelSize(for: size, backingScale: backingScale)
        let labels = pixelSize(for: size, backingScale: backingScale, budget: maxLabelPixels)
        return RenderKey(
            treeVersion: treeVersion, idEpoch: idEpoch, root: root, pixelWidth: map.width, pixelHeight: map.height,
            labelWidth: labels.width, labelHeight: labels.height, scale: Float(map.scale), style: style,
            sizeMetric: sizeMetric, packagesAsLeaves: packagesAsLeaves, colorMode: colorMode, ageNow: ageNow,
            scheme: scheme, highlightVersion: highlightVersion, relief: relief, tileBorders: tileBorders,
            labels: drawsLabels, depth: depth)
    }

    static func layoutOptions(for key: RenderKey) -> TreemapLayoutOptions {
        var options = TreemapLayoutOptions()
        options.sizeMetric = key.sizeMetric
        options.packagesAsLeaves = key.packagesAsLeaves
        switch key.style {
        case .cushion: options.style = .cushion
        case .grouped: options.style = .grouped(scale: key.scale)
        case .framed: options.style = .framed(scale: key.scale)
        case .adaptive: options.style = .adaptive(scale: key.scale)
        }
        options.maxDepth = max(1, key.depth)
        // A folder shown as one block takes the colour most of its contents have.
        switch key.colorMode {
        case .kind: options.collapsedSample = .dominantKind
        case .age: options.collapsedSample = .dominantAge(now: key.ageNow)
        }
        return options
    }

    /// The "is or contains a match" mask the rasterizer wants.
    static func resolveMask(_ highlight: TreemapHighlight, tree: FileTree) -> NodeBitset? {
        switch highlight {
        case .none: return nil
        case .mask(let mask): return mask
        case .matches(let matches): return tree.containingMask(for: matches)
        case .kinds(let kinds):
            return tree.containingMask(for: tree.matches(SearchQuery(kinds: kinds, scope: .files)))
        case .categories(let categories):
            return tree.containingMask(for: tree.matches(SearchQuery(categories: categories, scope: .files)))
        }
    }

    /// Layout, raster and labels. Runs on any thread; takes roughly 10–20 ms for millions of nodes.
    static func render(_ request: RenderRequest, mask: NodeBitset?, target: RenderTarget = .image) -> RenderedFrame {
        let start = DispatchTime.now().uptimeNanoseconds
        let key = request.key
        let tree = request.tree
        let bounds = TreemapRect(x: 0, y: 0, width: Float(key.pixelWidth), height: Float(key.pixelHeight))
        request.sampleCache?.use(generation: key.treeVersion)
        let layout = TreemapLayout(
            tree: tree, root: key.root, bounds: bounds, options: layoutOptions(for: key), sampleCache: request.sampleCache)

        var options = TreemapRenderOptions.standard(scheme: key.scheme)
        options.highlight = mask
        options.relief *= key.relief
        if !key.tileBorders {
            options.separator = 0
            options.bevel = 0
        }
        let kindColors = tree.kindColors(scheme: key.scheme)
        let ageColors = AgePalette.colors(scheme: key.scheme)
        let coloring: TreemapColoring =
            switch key.colorMode {
            case .kind: .byKind(colors: kindColors)
            case .age: .byAge(now: key.ageNow, colors: ageColors)
            }
        // Not cleared: the renderer writes every pixel.
        let bitmap = TreemapBitmap(width: key.pixelWidth, height: key.pixelHeight, cleared: false)
        TreemapRenderer.render(layout, coloring: coloring, options: options, into: bitmap)

        let tileColor: (NodeID) -> RGB = { sample in
            switch key.colorMode {
            case .kind: kindColors[min(Int(tree.kind(of: sample)), kindColors.count - 1)]
            case .age: ageColors[AgeBucket(modified: tree.modified(of: sample), now: key.ageNow).rawValue]
            }
        }
        // Hidden labels are not laid out or drawn at all.
        let labels =
            key.labels
            ? LabelRenderer.makePixels(layout: layout, key: key, mask: mask, tileColor: tileColor, target: target) : nil
        let pixels: FramePixels
        if target == .layer, let surface = FramePixels.surface(copying: bitmap) {
            // Alpha is always 255, so declare it skipped: an opaque picture composites faster.
            pixels = FramePixels(surface: surface, alpha: .noneSkipFirst)
        } else {
            pixels = FramePixels(image: makeImage(bitmap))
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        return RenderedFrame(request: request, layout: layout, pixels: pixels, labelPixels: labels, duration: seconds)
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Wraps the bitmap's memory in a `CGImage` without copying; the image keeps the bitmap alive.
    static func makeImage(_ bitmap: TreemapBitmap) -> CGImage {
        let retained = Unmanaged.passRetained(bitmap)
        let provider = CGDataProvider(
            dataInfo: retained.toOpaque(), data: UnsafeRawPointer(bitmap.pixels), size: bitmap.byteCount,
            releaseData: { info, _, _ in
                if let info { Unmanaged<TreemapBitmap>.fromOpaque(info).release() }
            })!
        // Alpha is always 255, so declare it skipped: an opaque image composites faster.
        let info = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bitmap.bytesPerRow, space: sRGB, bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// Runs renders one at a time on a background queue. Only the newest waiting request survives
/// (latest wins), so a burst of changes — a live resize, scan snapshots — costs at most one
/// render in flight plus one queued, and the main thread never waits.
final class RenderQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (request: RenderRequest, deliver: @MainActor @Sendable (RenderedFrame) -> Void)?
    private var running = false
    private let queue = DispatchQueue(label: "dev.disksurvey.mapview.render", qos: .userInitiated)

    // Touched only on `queue`. Deriving a mask walks the whole tree, so it is kept while the
    // tree and the highlight stay the same (every frame of a resize would otherwise redo it).
    private var maskCache: (treeVersion: Int, highlightVersion: Int, mask: NodeBitset?)?

    func submit(_ request: RenderRequest, deliver: @escaping @MainActor @Sendable (RenderedFrame) -> Void) {
        lock.lock()
        pending = (request, deliver)
        let start = !running
        if start { running = true }
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Drops the request that has not started yet, if any.
    func cancelPending() {
        lock.lock()
        pending = nil
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            let key = job.request.key
            let mask: NodeBitset?
            if let cache = maskCache, cache.treeVersion == key.treeVersion, cache.highlightVersion == key.highlightVersion {
                mask = cache.mask
            } else {
                mask = FrameRenderer.resolveMask(job.request.highlight, tree: job.request.tree)
                maskCache = (key.treeVersion, key.highlightVersion, mask)
            }
            let frame = FrameRenderer.render(job.request, mask: mask, target: .layer)
            let deliver = job.deliver
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(frame) } }
        }
    }
}
