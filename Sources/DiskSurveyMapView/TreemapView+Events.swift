import AppKit
import DiskSurveyCore
import DiskSurveyTreemap

// Mouse, keyboard, gestures and drag-out.
extension TreemapView {
    // MARK: Selection by the user

    /// Changes the selection and tells the delegate (assigning ``selection`` does not).
    func setSelectionByUser(_ nodes: Set<NodeID>, primary: NodeID?) {
        guard nodes != selection || primary != primarySelection else { return }
        let changed = nodes != selection
        selectionChangeIsByUser = true
        selection = nodes
        selectionChangeIsByUser = false
        primarySelection = primary.flatMap { nodes.contains($0) ? $0 : nil }
        delegate?.treemapView(self, didChangeSelection: nodes, primary: primarySelection)
        if changed { announceSelection() }
    }

    private var primaryNode: NodeID? {
        if let primary = primarySelection, selection.contains(primary) { return primary }
        return orderedSelection.first
    }

    private func cell(at point: NSPoint) -> (frame: RenderedFrame, index: Int)? {
        guard let frame = interactiveFrame, bounds.contains(point),
            let hit = frame.layout.hitTest(geometry(for: frame).layoutPoint(point)), hit != 0
        else { return nil }
        return (frame, hit)
    }

    // MARK: Zoom

    private func requestZoom(to node: NodeID) {
        guard node != effectiveRoot else { return }
        hideTooltip()
        if let delegate {
            delegate.treemapView(self, didRequestZoomTo: node)
        } else {
            rootNode = node
        }
    }

    /// The child of the current root that contains `node` (`nil` if the node is not below it).
    func topLevelAncestor(of node: NodeID) -> NodeID? {
        guard let tree = currentTree, Int(node) < tree.count else { return nil }
        let root = effectiveRoot
        var current = node
        while let parent = tree.parent(of: current) {
            if parent == root { return current }
            current = parent
        }
        return nil
    }

    /// Zooms one level into the folder under `point` (view coordinates). Returns whether there
    /// was a folder to zoom into.
    @discardableResult
    public func zoomIn(at point: NSPoint) -> Bool {
        // While a zoom is still rendering, the picture shows another root than the one a new
        // request would be relative to.
        guard let (frame, index) = cell(at: point), frame.layout.root == effectiveRoot else { return false }
        guard let target = topLevelAncestor(of: frame.layout.cells[index].node), frame.tree.isDirectory(target),
            frame.tree.childCount(of: target) > 0
        else { return false }
        requestZoom(to: target)
        return true
    }

    /// Zooms one level towards the primary selection.
    @discardableResult
    public func zoomInOnSelection() -> Bool {
        guard let tree = currentTree, let node = primaryNode, let target = topLevelAncestor(of: node),
            tree.isDirectory(target), tree.childCount(of: target) > 0
        else { return false }
        requestZoom(to: target)
        return true
    }

    /// Zooms out to the parent of the current root.
    @discardableResult
    public func zoomOut() -> Bool {
        guard let parent = currentTree?.parent(of: effectiveRoot) else { return false }
        requestZoom(to: parent)
        return true
    }

    /// One level in at the pointer if it is over the map, otherwise towards the selection.
    @discardableResult
    public func zoomIn() -> Bool {
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point), zoomIn(at: point) { return true }
        }
        return zoomInOnSelection()
    }

    /// Gestures deliver a stream of events; one zoom step per third of a second keeps a single
    /// pinch from racing through several levels.
    private func zoomGestureReady() -> Bool {
        let now = CACurrentMediaTime()
        guard now - lastZoomGestureTime > 0.32 else { return false }
        lastZoomGestureTime = now
        return true
    }

    // MARK: Pointer

    public override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        updateHover(at: nil)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        hideTooltip()
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let (frame, index) = cell(at: point) else {
            if !modifiers.contains(.command), !modifiers.contains(.shift) { setSelectionByUser([], primary: nil) }
            return
        }
        let tree = frame.tree
        let node = frame.layout.cells[index].node

        // Clicks that edit the selection (⌘, ⇧, ⌥) are single clicks however fast they follow
        // each other: the click count depends on timing alone, and a quick ⌥-click pair means
        // "walk out twice", not "zoom".
        let editsSelection = !modifiers.isDisjoint(with: [.command, .shift, .option])
        if !editsSelection {
            if event.clickCount == 2 {
                // The first click of the pair already selected the item.
                // A folder shown as one block, or a folder's title strip, is the folder: go
                // straight into it, however many levels down it is.
                let hit = frame.layout.cells[index]
                let layoutPoint = geometry(for: frame).layoutPoint(point)
                let onTitle = frame.layout.headerRect(ofCell: index).map { $0.contains(layoutPoint) } ?? false
                if hit.isCollapsed || onTitle, frame.layout.root == effectiveRoot, tree.childCount(of: hit.node) > 0 {
                    requestZoom(to: hit.node)
                    return
                }
                if !zoomIn(at: point), let target = topLevelAncestor(of: node), !frame.layout.cells[index].isAggregate,
                    !tree.isDirectory(target)
                {
                    delegate?.treemapView(self, didRequestReveal: target)
                }
                return
            }
            // The third click of a fast triple would land in the freshly zoomed map.
            guard event.clickCount == 1 else { return }
        }

        var collapseOnRelease = false
        var deselectOnRelease = false
        var pressed = node
        if modifiers.contains(.command) {
            var nodes = selection
            if nodes.contains(node) {
                // Removed on mouse-up, unless this press turns into a drag of the selection.
                deselectOnRelease = true
            } else {
                nodes.insert(node)
                setSelectionByUser(nodes, primary: node)
            }
        } else if modifiers.contains(.shift) {
            setSelectionByUser(selection.union([node]), primary: node)
        } else if modifiers.contains(.option) {
            // The enclosing folder; repeating the click walks further out, up to the top level.
            var target = tree.parent(of: node) ?? node
            if selection.count == 1, let current = selection.first, current == target || tree.isAncestor(current, of: target),
                let parent = tree.parent(of: current)
            {
                target = parent
            }
            let root = effectiveRoot
            if target == root || !tree.isAncestor(root, of: target) { target = topLevelAncestor(of: node) ?? node }
            pressed = target
            setSelectionByUser([target], primary: target)
        } else if selection.contains(node), selection.count > 1 {
            collapseOnRelease = true
            primarySelection = node
        } else {
            setSelectionByUser([node], primary: node)
        }
        press = Press(
            location: point, node: pressed, collapseOnRelease: collapseOnRelease, deselectOnRelease: deselectOnRelease)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard var current = press, !current.dragged else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - current.location.x, point.y - current.location.y) > 4 else { return }
        current.dragged = true
        press = current
        beginDrag(of: current.node, with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if let press, !press.dragged {
            if press.collapseOnRelease {
                setSelectionByUser([press.node], primary: press.node)
            } else if press.deselectOnRelease, selection.contains(press.node) {
                var nodes = selection
                nodes.remove(press.node)
                setSelectionByUser(nodes, primary: primarySelection == press.node ? nil : primarySelection)
            }
        }
        press = nil
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        hideTooltip()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let (frame, index) = cell(at: point) else { return super.menu(for: event) }
        let node = frame.layout.cells[index].node
        // A context click on an unselected item selects it, as in Finder.
        if !selection.contains(node) {
            setSelectionByUser([node], primary: node)
        } else {
            primarySelection = node
        }
        return delegate?.treemapView(self, menuFor: orderedSelection, clicked: node) ?? super.menu(for: event)
    }

    // MARK: Gestures

    public override func magnify(with event: NSEvent) {
        if event.phase == .began { gestureMagnification = 0 }
        gestureMagnification += event.magnification
        let point = convert(event.locationInWindow, from: nil)
        if gestureMagnification > 0.3 {
            gestureMagnification = 0
            if zoomGestureReady() { zoomIn(at: point) }
        } else if gestureMagnification < -0.3 {
            gestureMagnification = 0
            if zoomGestureReady() { zoomOut() }
        }
    }

    public override func smartMagnify(with event: NSEvent) {
        if !zoomIn(at: convert(event.locationInWindow, from: nil)) { zoomOut() }
    }

    public override func swipe(with event: NSEvent) {
        // Three-finger swipe, where enabled: either horizontal direction means "back".
        if event.deltaX != 0 { zoomOut() } else { super.swipe(with: event) }
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.phase == .began || event.phase == .mayBegin {
            scrollAccumulator = .zero
            swipeConsumed = false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.option) {
            // ⌥-scroll zooms one level per notch (or per decent trackpad stroke). The momentum
            // that follows a flick is not a stroke: it would step on for a second or two.
            // (Mouse wheels have neither phase nor momentum phase and are unaffected.)
            if event.momentumPhase != [] { return }
            scrollAccumulator.y += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 40
            if abs(scrollAccumulator.y) >= 40 {
                let zoomingIn = scrollAccumulator.y > 0
                scrollAccumulator.y = 0
                if zoomGestureReady() {
                    if zoomingIn { zoomIn(at: convert(event.locationInWindow, from: nil)) } else { zoomOut() }
                }
            }
            return
        }
        // A two-finger swipe to the right is "back", as in Finder and Safari. Only real
        // gestures count (they have phases); momentum and mouse wheels do not.
        if event.phase != [], event.momentumPhase == [], abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            scrollAccumulator.x += event.scrollingDeltaX
            if !swipeConsumed, scrollAccumulator.x > 90 {
                swipeConsumed = true
                zoomOut()
            }
            return
        }
        super.scrollWheel(with: event)
    }

    // MARK: Keyboard

    private enum Direction {
        case left, right, up, down
    }

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        hideTooltip()
        switch event.specialKey {
        case .leftArrow where modifiers.isEmpty: moveSelection(.left)
        case .rightArrow where modifiers.isEmpty: moveSelection(.right)
        case .upArrow where modifiers.isEmpty: moveSelection(.up)
        case .downArrow where modifiers.isEmpty: moveSelection(.down)
        case .upArrow where modifiers == .command: zoomOut()
        case .downArrow where modifiers == .command: zoomInOnSelection()
        case .upArrow where modifiers == .option: selectParent()
        case .downArrow where modifiers == .option: selectLargestChild()
        case .carriageReturn where modifiers.isEmpty, .enter where modifiers.isEmpty:
            zoomInOnSelection()
        // ⌘ is required, as in Finder: a stray Backspace must never move files.
        case .delete where modifiers == .command, .deleteForward where modifiers == .command:
            let nodes = orderedSelection
            if nodes.isEmpty { super.keyDown(with: event) } else { delegate?.treemapView(self, didRequestTrash: nodes) }
        default:
            switch event.charactersIgnoringModifiers ?? "" {
            case " " where modifiers.isEmpty:
                let nodes = orderedSelection
                if !nodes.isEmpty { delegate?.treemapView(self, didRequestQuickLook: nodes) }
            // Bare keys only: with ⌘ these are the menu's "more / fewer folder levels".
            case "+" where modifiers.subtracting(.shift).isEmpty, "=" where modifiers.isEmpty:
                zoomIn()
            case "-" where modifiers.isEmpty, "_" where modifiers.subtracting(.shift).isEmpty:
                zoomOut()
            case "\u{1B}":
                // Escape steps out; at the top it is free for the app (close search, …).
                if !zoomOut() { super.keyDown(with: event) }
            default:
                super.keyDown(with: event)
            }
        }
    }

    /// Moves the selection to the neighbouring tile in a direction.
    ///
    /// Works by probing: step just past the current tile's edge and see what is there, at the
    /// current tile's nesting level. Within a folder that walks the siblings; at the folder's
    /// edge it continues into the neighbouring folder — the map behaves like one surface.
    private func moveSelection(_ direction: Direction) {
        guard let frame = interactiveFrame else { return }
        let layout = frame.layout
        let cells = layout.cells
        guard cells.count > 1 else { return }

        var start: Int?
        if let node = primaryNode, let location = layout.locate(node), location.cell != 0 { start = location.cell }
        guard let current = start else {
            // Nothing selected on the map: begin with the largest tile.
            var index = 0
            while !cells[index].isLeaf, let first = cells[index].children.first { index = first }
            if cells[index].isAggregate { index = Int(cells[index].parent) }
            guard index > 0 else { return }
            setSelectionByUser([cells[index].node], primary: cells[index].node)
            return
        }

        let rect = cells[current].rect
        let depth = Int(cells[current].depth)
        let anchor = navigationAnchor ?? TreemapPoint(x: rect.midX, y: rect.midY)
        let ax = min(max(anchor.x, rect.minX + 0.5), rect.maxX - 0.5)
        let ay = min(max(anchor.y, rect.minY + 0.5), rect.maxY - 0.5)
        var found: Int?
        // Growing steps hop over gutters and folder headers between tiles.
        for step in [0.5, 2, 4, 8, 14, 22, 34] as [Float] {
            let d = step * frame.key.scale
            let probe: TreemapPoint =
                switch direction {
                case .left: TreemapPoint(x: rect.minX - d, y: ay)
                case .right: TreemapPoint(x: rect.maxX + d - 0.5, y: ay)
                case .up: TreemapPoint(x: ax, y: rect.minY - d)
                case .down: TreemapPoint(x: ax, y: rect.maxY + d - 0.5)
                }
            guard layout.bounds.contains(probe) else { break }
            guard let hit = layout.hitTest(probe, maxDepth: depth), hit != current, hit != 0 else { continue }
            let cell = cells[hit]
            // A shallower non-leaf is the frame of an enclosing folder; aggregates are not items.
            if cell.isAggregate || (!cell.isLeaf && Int(cell.depth) < depth) { continue }
            found = hit
            break
        }
        guard let found else { return }
        let node = cells[found].node
        setSelectionByUser([node], primary: node)
        // Keep the cross-axis position, so going right-right-right follows a straight line
        // instead of drifting to wherever each tile's centre happens to be.
        let target = cells[found].rect
        switch direction {
        case .left, .right: navigationAnchor = TreemapPoint(x: target.midX, y: ay)
        case .up, .down: navigationAnchor = TreemapPoint(x: ax, y: target.midY)
        }
    }

    private func selectParent() {
        guard let tree = currentTree, let node = primaryNode, let parent = tree.parent(of: node), parent != effectiveRoot,
            tree.isAncestor(effectiveRoot, of: parent)
        else { return }
        setSelectionByUser([parent], primary: parent)
    }

    private func selectLargestChild() {
        guard let tree = currentTree, let node = primaryNode, tree.childCount(of: node) > 0 else { return }
        let child = tree.child(of: node, at: 0)
        setSelectionByUser([child], primary: child)
    }

    // MARK: Drag source

    /// Tiles beyond this many are dragged without a picture of their own.
    static let maxDragImages = 64

    /// What a drag started on `node` carries: the whole selection if the node is part of it,
    /// otherwise the node alone. These are exactly the files put on the pasteboard and the
    /// nodes reported to the delegate when the drag ends, so a drop on the Trash acts on what
    /// was dragged and nothing else.
    func dragNodes(startingAt node: NodeID) -> [NodeID] {
        guard let tree = interactiveFrame?.tree else { return [] }
        let candidates = selection.contains(node) ? orderedSelection : [node]
        // Synthetic entries stand for space that has no file of its own.
        return candidates.filter { Int($0) < tree.count && !tree.flags(of: $0).contains(.synthetic) }
    }

    private func beginDrag(of node: NodeID, with event: NSEvent) {
        guard let frame = interactiveFrame else { return }
        let tree = frame.tree
        let nodes = dragNodes(startingAt: node)
        guard !nodes.isEmpty else { return }
        hideTooltip()

        let geometry = geometry(for: frame)
        let pointer = convert(event.locationInWindow, from: nil)
        var items: [NSDraggingItem] = []
        // One image for the whole drag: every cut-out refers to it.
        let picture = frame.image
        for (position, node) in nodes.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: tree.url(of: node) as NSURL)
            var rect = CGRect(x: pointer.x - 16, y: pointer.y - 16, width: 32, height: 32)
            if position >= Self.maxDragImages {
                // Still on the pasteboard, just without a picture: a pile of hundreds of tile
                // images adds nothing.
                item.draggingFrame = rect
                items.append(item)
                continue
            }
            var image: NSImage?
            if let location = frame.layout.locate(node) {
                let cellRect = frame.layout.cells[location.cell].rect
                rect = geometry.viewRect(cellRect)
                // The tile itself is the drag image: cut it out of the picture.
                let crop = CGRect(
                    x: CGFloat(cellRect.minX), y: CGFloat(cellRect.minY), width: CGFloat(cellRect.width),
                    height: CGFloat(cellRect.height)
                ).integral
                if let cut = picture.cropping(to: crop) { image = NSImage(cgImage: cut, size: rect.size) }
                // A tile half the window wide makes a clumsy drag image; shrink it around the pointer.
                let limit: CGFloat = 160
                let factor = min(1, limit / max(rect.width, rect.height))
                if factor < 1 {
                    let size = CGSize(width: rect.width * factor, height: rect.height * factor)
                    let fx = rect.width > 0 ? (pointer.x - rect.minX) / rect.width : 0.5
                    let fy = rect.height > 0 ? (pointer.y - rect.minY) / rect.height : 0.5
                    let anchorX = rect.contains(pointer) ? fx : 0.5
                    let anchorY = rect.contains(pointer) ? fy : 0.5
                    rect = CGRect(
                        x: pointer.x - size.width * anchorX, y: pointer.y - size.height * anchorY, width: size.width,
                        height: size.height)
                }
            }
            item.setDraggingFrame(rect, contents: image ?? NSWorkspace.shared.icon(forFile: tree.path(of: node)))
            items.append(item)
        }
        draggedNodes = nodes
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = items.count > 1 ? .pile : .none
    }

    public func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .outsideApplication: [.copy, .move, .link, .generic, .delete]
        default: [.copy, .generic]
        }
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let nodes = draggedNodes
        draggedNodes = []
        press = nil
        guard !nodes.isEmpty, !operation.isEmpty else { return }
        // A drop on the Trash only reports `.delete`; removing the files is the source's job.
        if operation.contains(.delete) {
            delegate?.treemapView(self, didRequestTrash: nodes)
        } else {
            delegate?.treemapView(self, didDrag: nodes, endedWith: operation)
        }
    }
}
