import DiskSurveyCore

/// Where a node ended up in a layout.
public struct TreemapLocation: Sendable, Hashable {
    /// Index into ``TreemapLayout/cells``.
    public var cell: Int
    /// `true` if the cell shows exactly the requested node; `false` if the node was pruned by
    /// the level of detail and `cell` is the smallest drawn cell that contains it (a collapsed
    /// ancestor, or the aggregate "small items" cell of its directory).
    public var isExact: Bool
}

extension TreemapLayout {
    // MARK: Hit testing

    /// The deepest cell drawn at `point`, or `nil` outside ``bounds``.
    ///
    /// The answer is the cell the rasterizer painted the pixel under `point` with: cell edges
    /// are rounded to pixel boundaries exactly as ``TreemapRenderer`` rounds them
    /// (``TreemapRect/pixelEdge(_:)``), so every point of a pixel hits the same cell, and a
    /// cell too thin to be given any pixel cannot be hit.
    ///
    /// A point on a directory's frame (header or padding) returns that directory's cell.
    /// Cost: one pass over the child cells of each level on the way down.
    public func hitTest(_ point: TreemapPoint) -> Int? {
        hitTest(point, maxDepth: .max)
    }

    /// Like ``hitTest(_:)`` but stops descending at `maxDepth` (0 returns the root cell):
    /// "which top-level folder is under the pointer?".
    public func hitTest(_ point: TreemapPoint, maxDepth: Int) -> Int? {
        // The pixel under the point.
        let px = point.x.rounded(.down)
        let py = point.y.rounded(.down)
        guard !cells.isEmpty, bounds.containsPixel(px, py) else { return nil }
        return cells.withUnsafeBufferPointer { cells in
            var current = 0
            descend: while true {
                let cell = cells[current]
                if cell.isLeaf || Int(cell.depth) >= maxDepth { return current }
                for child in cell.children where cells[child].rect.containsPixel(px, py) {
                    current = child
                    continue descend
                }
                return current
            }
        }
    }

    /// The node under `point`. For an aggregate cell this is the directory whose small items it
    /// merges; for a collapsed directory, that directory.
    public func node(at point: TreemapPoint) -> NodeID? {
        hitTest(point).map { cells[$0].node }
    }

    /// The chain of cells from the root cell down to the deepest cell containing `point`
    /// (empty outside ``bounds``). Element `k` is the cell at depth `k`.
    public func cellPath(at point: TreemapPoint) -> [Int] {
        guard var cell = hitTest(point) else { return [] }
        var path = [cell]
        while cells[cell].parent >= 0 {
            cell = Int(cells[cell].parent)
            path.append(cell)
        }
        path.reverse()
        return path
    }

    /// The directories containing `point`, outermost first, starting with the layout root.
    /// An aggregate cell contributes nothing of its own (its directory is already in the chain).
    public func directoryPath(at point: TreemapPoint) -> [NodeID] {
        var result: [NodeID] = []
        for index in cellPath(at: point) {
            let cell = cells[index]
            if cell.isDirectory, !cell.isAggregate { result.append(cell.node) }
        }
        return result
    }

    // MARK: Locating nodes

    /// Finds the cell of `node`, or — if the level of detail pruned it — the smallest drawn
    /// cell containing it. Returns `nil` if the node is not inside the layout root, has been
    /// removed, or takes no space at all in an expanded directory.
    public func locate(_ node: NodeID) -> TreemapLocation? {
        guard Int(node) < tree.count, !tree.isRemoved(node), !cells.isEmpty else { return nil }
        // Chain from the node up to (excluding) the layout root.
        var chain: [NodeID] = []
        var current = node
        while current != root {
            chain.append(current)
            guard let parent = tree.parent(of: current) else { return nil }
            current = parent
        }
        var cellIndex = 0
        for wanted in chain.reversed() {
            let cell = cells[cellIndex]
            if cell.isLeaf { return TreemapLocation(cell: cellIndex, isExact: false) }
            var found = -1
            var aggregate = -1
            for child in cell.children {
                if cells[child].isAggregate {
                    aggregate = child
                } else if cells[child].node == wanted {
                    found = child
                    break
                }
            }
            if found < 0 {
                // Not drawn on its own: it is one of the merged small items, unless it has no size.
                let size = options.sizeMetric == .allocated ? tree.size(of: wanted) : tree.logicalSize(of: wanted)
                guard size > 0 else { return nil }
                return TreemapLocation(cell: aggregate >= 0 ? aggregate : cellIndex, isExact: false)
            }
            cellIndex = found
        }
        return TreemapLocation(cell: cellIndex, isExact: true)
    }

    /// The cell index of `node`, falling back to the smallest drawn cell containing it.
    public func cell(for node: NodeID) -> Int? { locate(node)?.cell }

    /// The rectangle of `node`, falling back to the smallest drawn cell containing it.
    public func rect(for node: NodeID) -> TreemapRect? {
        locate(node).map { cells[$0.cell].rect }
    }

    // MARK: Zoom

    /// The transform that carries this layout's picture onto `other`'s during a zoom between
    /// two roots of the same tree, or `nil` if neither root contains the other.
    ///
    /// Zooming in (`other.root` is inside this layout's root): the rectangle that `other.root`
    /// occupies here is mapped onto `other.bounds`. Zooming out: `bounds` is mapped onto the
    /// rectangle this layout's root occupies in `other`.
    ///
    /// To animate with progress `t` in 0…1, draw this layout's bitmap under
    /// `transform.interpolated(t)` and `other`'s bitmap under
    /// `transform.inverse.interpolated(1 - t)`, cross-fading from the first to the second: the
    /// two pictures then stay registered on each other for the whole transition.
    public func zoomTransform(to other: TreemapLayout) -> TreemapTransform? {
        if other.root == root {
            return TreemapTransform(mapping: bounds, onto: other.bounds)
        }
        if let location = locate(other.root), tree.isAncestor(root, of: other.root) {
            // If the target was pruned here, growing out of its enclosing cell is the best
            // available approximation and still reads as "zooming into that spot".
            return TreemapTransform(mapping: cells[location.cell].rect, onto: other.bounds)
        }
        if let location = other.locate(root), other.tree.isAncestor(other.root, of: root) {
            return TreemapTransform(mapping: bounds, onto: other.cells[location.cell].rect)
        }
        return nil
    }

    /// Where `node`'s rectangle in this layout ends up in `other` — the pair a view needs to
    /// animate one node between two layouts. `nil` if the node is absent from either.
    public func correspondence(of node: NodeID, in other: TreemapLayout) -> (from: TreemapRect, to: TreemapRect)? {
        guard let a = rect(for: node), let b = other.rect(for: node) else { return nil }
        return (a, b)
    }
}
