import AppKit
import QuartzCore
import DiskSurveyCore
import DiskSurveyTreemap

/// Hosts the map's layers. A layer-hosting view owns its layer tree outright, so AppKit never
/// reorders or redraws it; events fall through to the ``TreemapView`` around it.
private final class CanvasView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The treemap: a cushion-shaded picture of a ``FileTree`` with hover, selection, animated zoom
/// and drag-out.
///
/// All inputs are plain properties that may be set at any time on the main actor; setting one
/// to its current value costs nothing, and several changes in one run-loop turn produce a
/// single render. Layout and rasterization run on a background queue (newest request wins) and
/// arrive as layer contents, so the main thread only ever swaps images and moves layers.
///
/// The view does not own navigation state: zoom requests go to the delegate, which answers by
/// setting ``rootNode`` (the default delegate implementation, and a view without a delegate,
/// do that directly).
public final class TreemapView: NSView, NSDraggingSource {
    // MARK: Inputs

    public weak var delegate: (any TreemapViewDelegate)?

    /// The tree to show. Assigning the tree value the view already has is free. Node ids are
    /// assumed to survive only in-place mutations (`remove`, `replaceSubtree`) of the previous
    /// tree; use ``setTree(_:nodeIDsStable:)`` to say otherwise.
    public var tree: FileTree? {
        get { currentTree }
        set { setTree(newValue) }
    }

    /// The folder shown as the whole map. Changing it animates a zoom. An id that is not a live
    /// directory of the tree shows the tree's root.
    public var rootNode: NodeID = 0 {
        didSet {
            guard rootNode != oldValue else { return }
            // While the picture of the previous tree is kept across a snapshot swap, a new id
            // is only the same folder renumbered; a real zoom hides the HUD when it starts.
            if !keepsStalePicture { hideTooltip() }
            scheduleRender()
        }
    }

    /// Outlined nodes. Nodes outside the current ``rootNode`` are kept but not drawn; nodes too
    /// small to have their own tile outline the tile that contains them.
    public var selection: Set<NodeID> = [] {
        didSet {
            guard selection != oldValue else { return }
            if let primary = primarySelection, !selection.contains(primary) { primarySelection = nil }
            navigationAnchor = nil
            updateSelectionOverlay()
            invalidateAccessibility()
            // A change by the user is announced in words (see `setSelectionByUser`); re-reading
            // the whole summary on top of that would only be noise.
            if !selectionChangeIsByUser { postAccessibility(.valueChanged) }
            postAccessibility(.selectedChildrenChanged)
        }
    }

    /// The selected node keyboard navigation starts from (the last one clicked). `nil`, or a
    /// node outside ``selection``, means the largest selected node.
    public var primarySelection: NodeID?

    /// Dims everything that does not match.
    public var highlight: TreemapHighlight = .none {
        didSet {
            guard highlight != oldValue else { return }
            highlightVersion += 1
            scheduleRender()
        }
    }

    public var colorMode: TreemapColorMode = .kind {
        didSet { if colorMode != oldValue { scheduleRender() } }
    }

    public var mapStyle: TreemapMapStyle = .adaptive {
        didSet { if mapStyle != oldValue { scheduleRender() } }
    }

    /// Level of detail: how many folder levels below ``rootNode`` are subdivided. At 1 the map
    /// shows only the folder's immediate children, each as one labelled block; at 2 their
    /// children; and so on. `nil` (the default) subdivides down to the files. The level is
    /// relative to the folder shown, so it stays the same when zooming.
    public var maxDepth: Int? {
        didSet {
            if let depth = maxDepth, depth < 1 { maxDepth = 1 }
            if maxDepth != oldValue { scheduleRender() }
        }
    }

    /// Which size the tile areas show.
    public var sizeMetric: TreemapLayoutOptions.SizeMetric = .allocated {
        didSet { if sizeMetric != oldValue { scheduleRender() } }
    }

    /// Draw packages (apps, photo libraries) as single tiles, as Finder shows them.
    public var packagesAsLeaves = false {
        didSet { if packagesAsLeaves != oldValue { scheduleRender() } }
    }

    /// Strength of the cushion shading: 1 is the standard look, 0 draws flat tiles.
    public var cushionStrength: Float = 1 {
        didSet { if cushionStrength != oldValue { scheduleRender() } }
    }

    /// Thin separators and bevels around the tiles.
    public var showsTileBorders = true {
        didSet { if showsTileBorders != oldValue { scheduleRender() } }
    }

    /// "Now" for colour-by-age, in epoch seconds. `nil` uses the current time.
    public var ageReferenceTime: Int64? {
        didSet { if ageReferenceTime != oldValue { scheduleRender() } }
    }

    /// Names on the map. Hiding them is immediate and stops the label pass for following
    /// pictures; showing them again takes one render (the raster itself does not change, so
    /// the names appear without a transition).
    public var showsLabels = true {
        didSet {
            guard showsLabels != oldValue else { return }
            withoutActions { labelLayer?.isHidden = !showsLabels }
            if showsLabels { scheduleRender() }
        }
    }

    /// The built-in hover HUD. Turn off to show hover information elsewhere only.
    public var showsTooltip = true {
        didSet { if !showsTooltip { hideTooltip() } }
    }

    /// Live mode: the tree is being replaced with partial snapshots. Renders are throttled,
    /// successive pictures cross-fade and a shimmer shows that the map is still filling in.
    public var isScanning = false {
        didSet {
            guard isScanning != oldValue else { return }
            updateShimmer()
            scheduleRender()
        }
    }

    // MARK: Read-only state

    /// The palette scheme matching the view's effective appearance (use it for legends).
    public var paletteScheme: PaletteScheme {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// The folder currently shown as the whole map (``rootNode``, validated against the tree).
    public var effectiveRoot: NodeID {
        guard let tree = currentTree, Int(rootNode) < tree.count, !tree.isRemoved(rootNode), tree.isDirectory(rootNode)
        else { return 0 }
        return rootNode
    }

    public var canZoomOut: Bool { currentTree?.parent(of: effectiveRoot) != nil }

    /// Seconds the most recent picture took to lay out and rasterize (0 before the first).
    public var lastRenderDuration: Double { displayed?.duration ?? 0 }

    /// Seconds the main thread spent putting the most recent picture on screen (swapping layer
    /// contents, starting the transition, re-deriving outlines). A diagnostic, like
    /// ``lastRenderDuration``.
    public private(set) var lastPresentDuration: Double = 0

    // MARK: State

    private(set) var currentTree: FileTree?
    private var treeIdentity: TreeIdentity?
    private var treeVersion = 0
    private let sampleCache = CollapsedSampleCache()
    /// Node ids are comparable only between trees of the same epoch.
    private(set) var idEpoch = 0
    private var highlightVersion = 0

    private let renderQueue = RenderQueue()
    private var nextSerial = 1
    private var minAcceptedSerial = 0
    private var renderDirty = false
    private var flushScheduled = false
    private var lastSubmitTime: CFTimeInterval = 0
    private var lastSubmittedKey: RenderKey?

    /// The frame on screen (possibly of an older tree, size or root than the inputs ask for).
    private(set) var displayed: RenderedFrame?
    private var transitionToken = 0
    private var placeholder = PlaceholderState.none
    private var placeholderRendition: (state: PlaceholderState, scheme: PaletteScheme, scale: CGFloat)?

    private let canvas = CanvasView()
    private let mapContainer = CALayer()
    private var frameLayer: CALayer?
    private var labelLayer: CALayer?
    private let overlayContainer = CALayer()
    private let hoverChainLayer = CAShapeLayer()
    private let hoverParentLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private let selectionGlowLayer = CAShapeLayer()
    private let selectionLineLayer = CAShapeLayer()
    private let placeholderLayer = CALayer()
    private var shimmerLayer: CAGradientLayer?
    private let tooltip = TooltipView()

    // Interaction state, used by the event handling extension.
    var hoveredCell: Int?
    var lastMouseLocation: NSPoint?
    private var reportedHover: (node: NodeID, isAggregate: Bool, epoch: Int)?
    /// Set between an id-changing tree swap and the first picture of the new tree, while the
    /// old picture is still shown: hover outline, selection outlines and tooltip keep
    /// describing that picture instead of blinking off until the new one arrives.
    private(set) var keepsStalePicture = false
    /// The root last announced to assistive clients (tree root path, shown folder path).
    private var announcedRoot: (tree: String, root: String)?
    var selectionChangeIsByUser = false
    /// Where accessibility notifications go; replaced by tests, which cannot observe real posts.
    var accessibilityPoster: (Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]?) -> Void = {
        element, notification, userInfo in
        if let userInfo {
            NSAccessibility.post(element: element, notification: notification, userInfo: userInfo)
        } else {
            NSAccessibility.post(element: element, notification: notification)
        }
    }
    /// Test seam: stands in for the window's backing scale.
    var backingScaleOverride: CGFloat?
    private var tooltipToken = 0
    private var tooltipPending = false
    var navigationAnchor: TreemapPoint?
    var press: Press?
    var draggedNodes: [NodeID] = []
    var gestureMagnification: CGFloat = 0
    var scrollAccumulator = CGPoint.zero
    var swipeConsumed = false
    var lastZoomGestureTime: CFTimeInterval = 0
    var accessibilityCache: (serial: Int, elements: [NSAccessibilityElement])?

    struct Press {
        var location: NSPoint
        var node: NodeID
        /// A click on one of several selected items collapses the selection only on mouse-up,
        /// so that the whole selection can still be dragged.
        var collapseOnRelease: Bool
        /// A ⌘-click on a selected item deselects it only on mouse-up, so that a ⌘-drag still
        /// carries the whole selection, the pressed item included.
        var deselectOnRelease = false
        var dragged = false
    }

    static let zoomDuration: CFTimeInterval = 0.28
    static let fadeDuration: CFTimeInterval = 0.18
    /// How long the pointer rests on a tile before the tooltip appears.
    static let tooltipDelay: TimeInterval = 0.35

    // MARK: Setup

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        canvas.frame = bounds
        addSubview(canvas)

        let root = canvas.layer!
        mapContainer.masksToBounds = true
        root.addSublayer(mapContainer)
        placeholderLayer.contentsGravity = .center
        placeholderLayer.isHidden = true
        root.addSublayer(placeholderLayer)
        for layer in [hoverChainLayer, hoverParentLayer, hoverLayer, selectionGlowLayer, selectionLineLayer] {
            overlayContainer.addSublayer(layer)
        }
        root.addSublayer(overlayContainer)
        Overlay.styleHover(cell: hoverLayer, parent: hoverParentLayer, chain: hoverChainLayer)

        tooltip.isHidden = true
        addSubview(tooltip)

        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self, userInfo: nil))
        updateColors()
        layoutLayers()
        configureAccessibility()
    }

    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { false }

    // MARK: Tree

    /// Assigns the tree, optionally stating whether node ids of the previous tree are still
    /// valid in the new one. While they are (a deletion, a partial rescan spliced in with
    /// `replaceSubtree`), selection and hover carry over and the change cross-fades; otherwise
    /// (a new scan snapshot) outlines wait for the first picture of the new tree.
    public func setTree(_ newTree: FileTree?, nodeIDsStable: Bool? = nil) {
        let identity = newTree.map(TreeIdentity.init)
        if identity == treeIdentity { return }
        let stable: Bool
        if let old = currentTree, let new = newTree {
            // In-place mutations bump the revision and never shrink the node table; a fresh
            // scan result starts again at revision 0.
            stable = nodeIDsStable ?? (new.rootPath == old.rootPath && new.revision > old.revision && new.count >= old.count)
        } else {
            stable = false
        }
        currentTree = newTree
        treeIdentity = identity
        treeVersion += 1
        if stable {
            updateOverlays()
        } else {
            idEpoch += 1
            navigationAnchor = nil
            if newTree != nil, displayed != nil {
                // The old picture stays up until the new tree's first frame; so do its outlines
                // and the tooltip, which describe that picture (the frame keeps its own tree
                // and layout). `present` re-derives everything, and reports the hover with the
                // new ids then. Nothing that produces node ids uses the stale picture.
                keepsStalePicture = true
            } else {
                keepsStalePicture = false
                setHoveredCell(nil)
                updateOverlays()
            }
        }
        invalidateAccessibility()
        scheduleRender()
    }

    // MARK: Geometry and appearance

    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { sizeDidChange() }
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        sizeDidChange()
    }

    private func sizeDidChange() {
        // The old picture stretches immediately (its layer simply follows the bounds); a sharp
        // one follows as soon as the render queue gets to it.
        layoutLayers()
        updateOverlays()
        hideTooltip()
        scheduleRender()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleRender()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            hideTooltip()
            return
        }
        updateColors()
        updateShimmer()
        scheduleRender()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A placeholder has no render to follow the new scale; redraw it here (free if the
        // scale is unchanged).
        updatePlaceholderLayer()
        scheduleRender()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
        scheduleRender()
    }

    private var backingScale: CGFloat {
        backingScaleOverride ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func updateColors() {
        let background = TreemapRenderOptions.standard(scheme: paletteScheme).backgroundColor.cgColor
        withoutActions {
            layer?.backgroundColor = background
            canvas.layer?.backgroundColor = background
            // Resolved colours do not follow appearance or accent changes by themselves.
            Overlay.styleSelection(glow: selectionGlowLayer, line: selectionLineLayer, accent: Overlay.accentColor())
        }
        updatePlaceholderLayer()
    }

    private func layoutLayers() {
        let rect = CGRect(origin: .zero, size: bounds.size)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        withoutActions {
            mapContainer.frame = rect
            overlayContainer.frame = rect
            for layer in [hoverChainLayer, hoverParentLayer, hoverLayer, selectionGlowLayer, selectionLineLayer] { layer.frame = rect }
            // bounds + position rather than frame: `frame` is undefined under a transform, and
            // a zoom may be animating this layer's transform right now.
            if let frameLayer {
                frameLayer.bounds = rect
                frameLayer.position = center
                labelLayer?.frame = rect
            }
            placeholderLayer.bounds = CGRect(origin: .zero, size: PlaceholderPainter.size)
            placeholderLayer.position = CGPoint(x: center.x.rounded(), y: center.y.rounded())
        }
        if shimmerLayer != nil { updateShimmer() }
    }

    // MARK: Render scheduling

    /// Marks the picture stale. Coalesces everything set in the current run-loop turn.
    func scheduleRender() {
        renderDirty = true
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushRender() }
        }
    }

    /// Minimum time between render starts. The queue already runs one render at a time; this
    /// only keeps a live resize or a scan from occupying every core continuously.
    private var minimumRenderInterval: CFTimeInterval {
        if inLiveResize { return 1.0 / 40 }
        if isScanning { return 0.1 }
        return 0
    }

    private func flushRender() {
        flushScheduled = false
        guard renderDirty else { return }
        let wait = lastSubmitTime + minimumRenderInterval - CACurrentMediaTime()
        if wait > 0.002 {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated { self?.flushRender() }
            }
            return
        }
        renderDirty = false
        submitRender()
    }

    private func currentPlaceholderState() -> PlaceholderState {
        guard let tree = currentTree else { return isScanning ? .scanning : .noTree }
        let root = effectiveRoot
        let size = sizeMetric == .allocated ? tree.size(of: root) : tree.logicalSize(of: root)
        if size == 0 { return isScanning ? .scanning : .empty }
        return .none
    }

    private func submitRender() {
        let state = currentPlaceholderState()
        if state != placeholder {
            placeholder = state
            updatePlaceholderLayer()
        }
        guard state == .none, let tree = currentTree else {
            dropFrames()
            return
        }
        let size = bounds.size
        guard size.width >= 1, size.height >= 1 else { return }
        let ageNow = ageReferenceTime ?? (Int64(Date().timeIntervalSince1970) / 3600 + 1) * 3600
        let key = FrameRenderer.makeKey(
            size: size, backingScale: backingScale, treeVersion: treeVersion, idEpoch: idEpoch, root: effectiveRoot,
            style: mapStyle, sizeMetric: sizeMetric, packagesAsLeaves: packagesAsLeaves, colorMode: colorMode,
            ageNow: ageNow, scheme: paletteScheme, highlightVersion: highlightVersion,
            relief: max(0, min(2, cushionStrength)), tileBorders: showsTileBorders, labels: showsLabels,
            depth: maxDepth ?? .max)
        guard key != lastSubmittedKey else { return }
        lastSubmittedKey = key
        lastSubmitTime = CACurrentMediaTime()
        let request = RenderRequest(serial: nextSerial, key: key, tree: tree, highlight: highlight, sampleCache: sampleCache)
        nextSerial += 1
        renderQueue.submit(request) { [weak self] frame in self?.receive(frame) }
    }

    /// Removes the picture (the placeholder takes over) and disowns renders still in flight.
    private func dropFrames() {
        renderQueue.cancelPending()
        minAcceptedSerial = nextSerial
        lastSubmittedKey = nil
        guard displayed != nil || frameLayer != nil else { return }
        displayed = nil
        keepsStalePicture = false
        transitionToken += 1
        withoutActions {
            mapContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
            frameLayer = nil
            labelLayer = nil
        }
        setHoveredCell(nil)
        updateOverlays()
        invalidateAccessibility()
        if announcedRoot != nil {
            announcedRoot = nil
            postAccessibility(.layoutChanged)
        }
    }

    private func receive(_ frame: RenderedFrame) {
        guard frame.request.serial >= minAcceptedSerial else { return }
        if let displayed, displayed.request.serial >= frame.request.serial { return }
        present(frame)
    }

    // MARK: Presentation

    private enum Transition {
        case instant
        case fade(CFTimeInterval)
        case zoom(old: CGRect, new: CGRect)
    }

    private func transition(from old: RenderedFrame?, to new: RenderedFrame) -> Transition {
        guard let old, window != nil else { return old == nil ? .fade(Self.fadeDuration) : .instant }
        let a = old.key
        let b = new.key
        if a.sameContent(as: b) { return .instant }
        // The system cross-fades an appearance switch itself; follow it without a second fade.
        if a.scheme != b.scheme { return .instant }
        if a.idEpoch != b.idEpoch { return .fade(isScanning ? Self.fadeDuration : 0.25) }
        if a.root != b.root {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .fade(0.22) }
            guard let transform = old.layout.zoomTransform(to: new.layout) else { return .fade(0.22) }
            // An extreme magnification (zooming into a speck) shows nothing but one blurred
            // tile; a fade reads better.
            guard max(transform.scaleX, transform.scaleY) < 300, min(transform.scaleX, transform.scaleY) > 1.0 / 300
            else { return .fade(0.22) }
            let size = bounds.size
            let oldGeometry = MapGeometry(layoutBounds: old.layout.bounds, viewSize: size)
            let newGeometry = MapGeometry(layoutBounds: new.layout.bounds, viewSize: size)
            // Where the old picture ends up (in the new picture's space) and where the new one
            // starts (in the old picture's space). Animating both linearly between these and
            // the view's bounds keeps the two pictures registered on each other throughout.
            return .zoom(
                old: newGeometry.viewRect(transform.apply(old.layout.bounds)),
                new: oldGeometry.viewRect(transform.inverse.apply(new.layout.bounds)))
        }
        if a.treeVersion != b.treeVersion { return .fade(isScanning ? Self.fadeDuration : 0.25) }
        return .fade(0.15)
    }

    /// The transform that makes a layer filling `bounds` appear at `target`.
    private func transform(placing bounds: CGRect, at target: CGRect) -> CATransform3D {
        let sx = target.width / max(1, bounds.width)
        let sy = target.height / max(1, bounds.height)
        return CATransform3DConcat(
            CATransform3DMakeScale(sx, sy, 1),
            CATransform3DMakeTranslation(target.midX - bounds.midX, target.midY - bounds.midY, 0))
    }

    private func present(_ frame: RenderedFrame) {
        let started = CACurrentMediaTime()
        defer { lastPresentDuration = CACurrentMediaTime() - started }
        let previous = displayed
        let outgoing = frameLayer
        let rect = CGRect(origin: .zero, size: bounds.size)
        let kind = transition(from: previous, to: frame)

        let incoming = CALayer()
        incoming.contents = frame.pixels.layerContents
        incoming.contentsGravity = .resize
        incoming.isOpaque = true
        incoming.minificationFilter = .trilinear
        let labels = CALayer()
        labels.contents = frame.labelPixels?.layerContents
        labels.contentsGravity = .resize
        labels.isHidden = !showsLabels

        transitionToken += 1
        let token = transitionToken
        withoutActions {
            incoming.bounds = rect
            incoming.position = CGPoint(x: rect.midX, y: rect.midY)
            labels.frame = rect
            incoming.addSublayer(labels)
            // Settle whatever an interrupted transition left behind: only the picture that was
            // on top stays, at rest, under the new one.
            for layer in mapContainer.sublayers ?? [] where layer !== outgoing { layer.removeFromSuperlayer() }
            outgoing?.removeAllAnimations()
            outgoing?.transform = CATransform3DIdentity
            outgoing?.opacity = 1
            mapContainer.addSublayer(incoming)
            if case .instant = kind { outgoing?.removeFromSuperlayer() }
        }
        displayed = frame
        frameLayer = incoming
        labelLayer = labels

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.finishTransition(token) }
        }
        switch kind {
        case .instant:
            break
        case .fade(let duration):
            incoming.add(animation("opacity", from: 0, to: 1, duration: duration, timing: .init(name: .easeInEaseOut)), forKey: "fade")
        case .zoom(let oldTarget, let newStart):
            let duration = Self.zoomDuration
            // Fast start, long soft landing: reads like a spring without overshooting, which
            // would expose the background at the edges.
            let timing = CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.24, 1)
            let oldTransform = transform(placing: rect, at: oldTarget)
            if let outgoing {
                withoutActions { outgoing.transform = oldTransform }
                outgoing.add(
                    animation("transform", from: CATransform3DIdentity, to: oldTransform, duration: duration, timing: timing),
                    forKey: "zoom")
                // Its labels would be magnified into mush.
                outgoing.sublayers?.first?.add(
                    animation("opacity", from: 1, to: 0, duration: duration * 0.5, timing: .init(name: .easeOut)), forKey: "fade")
                withoutActions { outgoing.sublayers?.first?.opacity = 0 }
            }
            incoming.add(
                animation(
                    "transform", from: transform(placing: rect, at: newStart), to: CATransform3DIdentity,
                    duration: duration, timing: timing), forKey: "zoom")
            incoming.add(
                animation("opacity", from: 0, to: 1, duration: duration * 0.8, timing: .init(name: .easeInEaseOut)), forKey: "fade")
            // Outlines belong to the new picture's final geometry; bring them in at the end.
            let overlays = CAKeyframeAnimation(keyPath: "opacity")
            overlays.values = [0, 0, 1]
            overlays.keyTimes = [0, 0.75, 1]
            overlays.duration = duration + 0.08
            overlayContainer.add(overlays, forKey: "fade")
            hideTooltip()
        }
        CATransaction.commit()

        // Cell indices belong to a layout; re-derive everything that referred to the old one.
        // The hover follows where the pointer is now, and a new picture alone never pops the
        // tooltip up: that takes the pointer coming to rest.
        keepsStalePicture = false
        hoveredCell = nil
        updateHover(at: currentPointerLocation(), armTooltip: false)
        updateOverlays()
        invalidateAccessibility()

        // Assistive clients hear about another folder being shown, not about every picture
        // (scan snapshots and resizes arrive many times a second).
        let shown = (tree: frame.tree.rootPath, root: frame.tree.path(of: frame.layout.root))
        if announcedRoot?.tree != shown.tree || announcedRoot?.root != shown.root {
            announcedRoot = shown
            postAccessibility(.layoutChanged)
            postAccessibility(.titleChanged)
        }
    }

    /// The pointer in view coordinates (`nil` = not over the map), for re-deriving the hover
    /// without a mouse event. The point of the last event goes stale when the view moves or
    /// resizes under a resting pointer, so the real position is used whenever it can be known;
    /// offscreen (tests, snapshots) the last event's point is all there is.
    private func currentPointerLocation() -> NSPoint? {
        guard press == nil, let window, window.isVisible, NSApp?.isActive == true else { return lastMouseLocation }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point),
            NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
        else { return nil }
        return point
    }

    private func animation(
        _ keyPath: String, from: Any, to: Any, duration: CFTimeInterval, timing: CAMediaTimingFunction
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        return animation
    }

    private func finishTransition(_ token: Int) {
        // A newer transition has taken over; it cleans up after itself.
        guard token == transitionToken else { return }
        withoutActions {
            for layer in mapContainer.sublayers ?? [] where layer !== frameLayer { layer.removeFromSuperlayer() }
        }
    }

    // MARK: Placeholder and shimmer

    private func updatePlaceholderLayer() {
        let scale = backingScale
        let scheme = paletteScheme
        withoutActions {
            placeholderLayer.isHidden = placeholder == .none
            guard placeholder != .none else { return }
            if let current = placeholderRendition, current == (placeholder, scheme, scale) { return }
            placeholderLayer.contents = PlaceholderPainter.image(placeholder, scheme: scheme, scale: scale)
            placeholderLayer.contentsScale = scale
            placeholderRendition = (placeholder, scheme, scale)
        }
    }

    /// A soft band of light sweeping over the map while a scan runs.
    private func updateShimmer() {
        let wanted = isScanning && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard wanted else {
            shimmerLayer?.removeFromSuperlayer()
            shimmerLayer = nil
            return
        }
        let size = bounds.size
        let band = max(160, size.width * 0.45)
        let layer: CAGradientLayer
        if let shimmerLayer {
            layer = shimmerLayer
        } else {
            layer = CAGradientLayer()
            layer.startPoint = CGPoint(x: 0, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 0.5)
            layer.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.13), CGColor(gray: 1, alpha: 0)]
            canvas.layer?.insertSublayer(layer, above: mapContainer)
            shimmerLayer = layer
        }
        withoutActions {
            layer.bounds = CGRect(x: 0, y: 0, width: band, height: size.height)
            layer.position = CGPoint(x: -band, y: size.height / 2)
        }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -band / 2
        sweep.toValue = size.width + band / 2
        sweep.duration = 1.9
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(sweep, forKey: "sweep")
    }

    // MARK: Overlays

    /// The displayed frame, if its node ids are those of the current tree. Everything
    /// interactive goes through this, so a stale picture is never hit-tested with new ids.
    var interactiveFrame: RenderedFrame? {
        guard let displayed, displayed.key.idEpoch == idEpoch else { return nil }
        return displayed
    }

    func geometry(for frame: RenderedFrame) -> MapGeometry {
        MapGeometry(layoutBounds: frame.layout.bounds, viewSize: bounds.size)
    }

    func updateOverlays() {
        updateSelectionOverlay()
        updateHoverOverlay()
    }

    /// The frame that hover outline and tooltip describe: the one on screen, as long as it
    /// either belongs to the current tree or is deliberately kept across a swap.
    private var hoverFrame: RenderedFrame? { keepsStalePicture ? displayed : interactiveFrame }

    func updateSelectionOverlay() {
        // The selection already holds ids of the new tree; the outlines of the old picture
        // stay as they are until `present` replaces both.
        if keepsStalePicture { return }
        var rects: [CGRect] = []
        if let frame = interactiveFrame {
            rects = Overlay.selectionRects(frame: frame, selection: selection, geometry: geometry(for: frame))
        }
        withoutActions {
            let band = rects.isEmpty ? nil : Overlay.path(rects, inset: Overlay.selectionStroke / 2)
            selectionGlowLayer.path = band
            selectionGlowLayer.fillColor = rects.allSatisfy(Overlay.isWashed) ? Overlay.accentColor().copy(alpha: 0.10) : nil
            selectionLineLayer.path = band
        }
    }

    func updateHoverOverlay() {
        var shapes: (cell: CGRect, chain: [CGRect])?
        if let frame = hoverFrame, let cell = hoveredCell, cell < frame.layout.cells.count {
            shapes = Overlay.hoverRects(frame: frame, cell: cell, geometry: geometry(for: frame))
        }
        withoutActions {
            hoverLayer.path = shapes.map { Overlay.path([$0.cell], inset: Overlay.hoverStroke / 2) }
            hoverLayer.fillColor = shapes.map { Overlay.isWashed($0.cell) } ?? true ? Overlay.hoverWash : nil
            hoverParentLayer.path = shapes.flatMap { $0.chain.first }.map {
                Overlay.path([$0], inset: Overlay.hoverParentStroke / 2)
            }
            hoverChainLayer.path = shapes.flatMap { $0.chain.count > 1 ? Overlay.path(Array($0.chain.dropFirst()), inset: 0.5) : nil }
        }
    }

    // MARK: Hover and tooltip

    /// Re-evaluates what is under `point` (view coordinates; `nil` = pointer outside).
    /// `armTooltip: false` keeps a visible tooltip up to date but does not start the appear
    /// timer: for re-derivations that are not the pointer coming to rest.
    func updateHover(at point: NSPoint?, armTooltip: Bool = true) {
        lastMouseLocation = point
        var cell: Int?
        if let point, bounds.contains(point), let frame = hoverFrame {
            // Cell 0 is the map's own background frame, not an item.
            if let hit = frame.layout.hitTest(geometry(for: frame).layoutPoint(point)), hit != 0 { cell = hit }
        }
        setHoveredCell(cell)
        refreshTooltip(arm: armTooltip)
    }

    func setHoveredCell(_ cell: Int?) {
        let changed = cell != hoveredCell
        hoveredCell = cell
        if changed { updateHoverOverlay() }
        if cell == nil { hideTooltip() }

        var hover: TreemapHover?
        if let cell {
            // A cell of a stale picture has no id in the current tree: the delegate hears
            // about it when the new picture is presented.
            guard let frame = interactiveFrame else { return }
            if let location = lastMouseLocation {
                let info = frame.layout.cells[cell]
                hover = TreemapHover(
                    node: info.node, isAggregate: info.isAggregate, mergedCount: info.mergedCount,
                    size: frame.size(ofCell: cell), rect: geometry(for: frame).viewRect(info.rect), location: location)
            }
        }
        // A new picture re-derives the hovered cell; tell the delegate only about real changes
        // (the same id in another epoch is another node).
        let identity = hover.map { (node: $0.node, isAggregate: $0.isAggregate, epoch: idEpoch) }
        if identity?.node != reportedHover?.node || identity?.isAggregate != reportedHover?.isAggregate
            || identity?.epoch != reportedHover?.epoch
        {
            reportedHover = identity
            delegate?.treemapView(self, didHover: hover)
        }
    }

    private func refreshTooltip(arm: Bool) {
        guard showsTooltip, press == nil, let frame = hoverFrame, let cell = hoveredCell,
            cell < frame.layout.cells.count, let point = lastMouseLocation
        else {
            hideTooltip()
            return
        }
        if tooltip.isHidden {
            // Appear after a short rest, so sweeping across the map does not flash a HUD.
            guard arm, !tooltipPending else { return }
            tooltipPending = true
            tooltipToken += 1
            let token = tooltipToken
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tooltipDelay) { [weak self] in
                MainActor.assumeIsolated { self?.showTooltip(token) }
            }
        } else {
            tooltip.update(TooltipContent(frame: frame, cell: cell))
            tooltip.place(near: point, in: bounds)
        }
    }

    private func showTooltip(_ token: Int) {
        guard token == tooltipToken else { return }
        tooltipPending = false
        guard showsTooltip, press == nil, let frame = hoverFrame, let cell = hoveredCell,
            cell < frame.layout.cells.count, let point = lastMouseLocation
        else { return }
        tooltip.update(TooltipContent(frame: frame, cell: cell))
        tooltip.place(near: point, in: bounds)
        tooltip.alphaValue = 0
        tooltip.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            tooltip.animator().alphaValue = 1
        }
    }

    /// Puts the hover on `node` as if the pointer rested in the middle of its tile, tooltip
    /// included, without a mouse event (scripted checks and screenshots). Returns `false` if
    /// the node is not on the map.
    @discardableResult
    public func showHover(for node: NodeID) -> Bool {
        guard let frame = interactiveFrame, let location = frame.layout.locate(node), location.cell != 0 else { return false }
        let rect = geometry(for: frame).viewRect(frame.layout.cells[location.cell].rect)
        lastMouseLocation = NSPoint(x: rect.midX, y: rect.midY)
        setHoveredCell(location.cell)
        tooltipToken += 1
        tooltipPending = true
        showTooltip(tooltipToken)
        return true
    }

    /// Ends a hover started with ``showHover(for:)``.
    public func clearHover() { updateHover(at: nil) }

    // Internal views of private state, for tests.
    var isTooltipVisible: Bool { !tooltip.isHidden }
    var placeholderImage: CGImage? {
        guard !placeholderLayer.isHidden, let contents = placeholderLayer.contents else { return nil }
        return (contents as! CGImage)
    }
    var placeholderContentsScale: CGFloat { placeholderLayer.contentsScale }
    var selectionOutlineIsEmpty: Bool { selectionLineLayer.path == nil }
    var hoverOutlineIsEmpty: Bool { hoverLayer.path == nil }
    var hoverParentOutlineIsEmpty: Bool { hoverParentLayer.path == nil }
    var hoverAncestorOutlineIsEmpty: Bool { hoverChainLayer.path == nil }
    var tooltipContent: TooltipContent? { tooltip.isHidden ? nil : tooltip.content }

    func hideTooltip() {
        tooltipToken += 1
        tooltipPending = false
        if !tooltip.isHidden { tooltip.isHidden = true }
    }

    // MARK: Queries for the owner

    /// The node under a point in view coordinates (for an aggregate tile: its folder).
    public func node(at point: NSPoint) -> NodeID? {
        guard let frame = interactiveFrame, bounds.contains(point),
            let hit = frame.layout.hitTest(geometry(for: frame).layoutPoint(point)), hit != 0
        else { return nil }
        return frame.layout.cells[hit].node
    }

    /// Where a node is drawn, in view coordinates; for a node without its own tile, the tile
    /// containing it. `nil` if it is not on the map.
    public func rect(for node: NodeID) -> NSRect? {
        guard let frame = interactiveFrame, let rect = frame.layout.rect(for: node) else { return nil }
        return geometry(for: frame).viewRect(rect)
    }

    /// ``rect(for:)`` in screen coordinates — the source frame for a Quick Look panel.
    public func screenRect(for node: NodeID) -> NSRect? {
        guard let rect = rect(for: node), let window else { return nil }
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// The selection as a list, primary first, then by size.
    public var orderedSelection: [NodeID] {
        guard let tree = currentTree else { return [] }
        let valid = selection.filter { Int($0) < tree.count && !tree.isRemoved($0) }
        return valid.sorted { a, b in
            if a == primarySelection { return true }
            if b == primarySelection { return false }
            let sa = tree.size(of: a)
            let sb = tree.size(of: b)
            return sa != sb ? sa > sb : a < b
        }
    }
}
