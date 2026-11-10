import AppKit
import ImageIO
import DiskSurveyCore
import DiskSurveyTreemap

extension TreemapView {
    /// Renders the map offscreen, exactly as the view would show it, and returns PNG data.
    ///
    /// Runs the same pipeline as the live view (layout, cushion raster, labels, selection and
    /// hover outlines, placeholder for an empty map) synchronously on the calling thread, which
    /// may be any thread. Useful for tests, previews, exports and the command-line tool.
    ///
    /// - Parameters:
    ///   - tree: The tree to draw; `nil` gives the "no folder" placeholder.
    ///   - size: Size in points.
    ///   - scale: Pixels per point (the image is `size * scale` pixels).
    ///   - appearance: Light or dark; `nil` means light.
    ///   - root: The folder shown as the whole map.
    ///   - selection: Nodes to outline.
    ///   - hover: A node to draw the hover outline around.
    ///   - maxDepth: Folder levels to subdivide below `root` (`nil` = all).
    public nonisolated static func renderSnapshotPNG(
        tree: FileTree?, size: CGSize, scale: CGFloat = 2, appearance: NSAppearance? = nil, root: NodeID = 0,
        selection: Set<NodeID> = [], hover: NodeID? = nil, highlight: TreemapHighlight = .none,
        colorMode: TreemapColorMode = .kind, style: TreemapMapStyle = .adaptive,
        sizeMetric: TreemapLayoutOptions.SizeMetric = .allocated, packagesAsLeaves: Bool = false,
        showsLabels: Bool = true, isScanning: Bool = false, ageReferenceTime: Int64? = nil, maxDepth: Int? = nil
    ) -> Data {
        let scheme: PaletteScheme = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let pixels = FrameRenderer.pixelSize(for: size, backingScale: scale, budget: .max)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard size.width >= 1, size.height >= 1,
            let context = CGContext(
                data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: FrameRenderer.sRGB, bitmapInfo: info)
        else { return Data() }
        let pixelRect = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
        context.setFillColor(TreemapRenderOptions.standard(scheme: scheme).backgroundColor.cgColor)
        context.fill(pixelRect)

        var state = PlaceholderState.none
        var validRoot = root
        if let tree {
            if Int(root) >= tree.count || tree.isRemoved(root) || !tree.isDirectory(root) { validRoot = 0 }
            let total = sizeMetric == .allocated ? tree.size(of: validRoot) : tree.logicalSize(of: validRoot)
            if total == 0 { state = isScanning ? .scanning : .empty }
        } else {
            state = isScanning ? .scanning : .noTree
        }

        if state == .none, let tree {
            let now = ageReferenceTime ?? Int64(Date().timeIntervalSince1970)
            var key = FrameRenderer.makeKey(
                size: size, backingScale: scale, treeVersion: 0, idEpoch: 0, root: validRoot, style: style,
                sizeMetric: sizeMetric, packagesAsLeaves: packagesAsLeaves, colorMode: colorMode, ageNow: now,
                scheme: scheme, highlightVersion: 0, labels: showsLabels, depth: max(1, maxDepth ?? .max))
            // A snapshot is rendered at exactly the requested resolution, whatever its size.
            key.pixelWidth = pixels.width
            key.pixelHeight = pixels.height
            key.labelWidth = pixels.width
            key.labelHeight = pixels.height
            key.scale = Float(pixels.scale)
            let request = RenderRequest(serial: 0, key: key, tree: tree, highlight: highlight)
            let frame = FrameRenderer.render(request, mask: FrameRenderer.resolveMask(highlight, tree: tree))
            context.draw(frame.image, in: pixelRect)
            if showsLabels, let labels = frame.labels { context.draw(labels, in: pixelRect) }

            // Outlines are specified in points, like the live layers.
            context.saveGState()
            context.scaleBy(x: CGFloat(pixels.width) / size.width, y: CGFloat(pixels.height) / size.height)
            let geometry = MapGeometry(layoutBounds: frame.layout.bounds, viewSize: size)
            var hoverShapes: (cell: CGRect, chain: [CGRect])?
            if let hover, let location = frame.layout.locate(hover), location.cell != 0 {
                hoverShapes = Overlay.hoverRects(frame: frame, cell: location.cell, geometry: geometry)
            }
            Overlay.paint(
                selection: Overlay.selectionRects(frame: frame, selection: selection, geometry: geometry),
                hover: hoverShapes, accent: Overlay.accentColor(), in: context)
            context.restoreGState()
        } else {
            context.saveGState()
            context.scaleBy(x: CGFloat(pixels.width) / size.width, y: CGFloat(pixels.height) / size.height)
            let block = CGRect(
                x: (size.width - PlaceholderPainter.size.width) / 2, y: (size.height - PlaceholderPainter.size.height) / 2,
                width: PlaceholderPainter.size.width, height: PlaceholderPainter.size.height)
            PlaceholderPainter.draw(state, in: block, scheme: scheme, scale: pixels.scale, context: context)
            context.restoreGState()
        }

        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : Data()
    }
}
