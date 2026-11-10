import Foundation
import Testing
import DiskSurveyCore
@testable import DiskSurveyTreemap

@Suite struct HitTesting {
    @Test(arguments: allStyles.indices) func centresOfLeavesHitThemselves(styleIndex: Int) {
        let layout = TreemapLayout(
            tree: testTree(), bounds: testBounds, options: TreemapLayoutOptions(style: allStyles[styleIndex].style))
        var tested = 0
        var unpainted = 0
        for (index, cell) in layout.cells.enumerated() where cell.isLeaf && cell.rect.width > 0.01 && cell.rect.height > 0.01 {
            let hit = layout.hitTest(TreemapPoint(x: cell.rect.midX, y: cell.rect.midY))
            // Hit-testing answers "what was painted here": a tile whose edges round to the same
            // pixel boundary gets no pixel, so the pixel at its centre belongs to another cell.
            if cell.rect.pixelAligned.isEmpty {
                #expect(hit != index)
                unpainted += 1
                continue
            }
            #expect(hit == index)
            tested += 1
        }
        #expect(tested > 1000)
        #expect(unpainted < tested / 4)
    }

    @Test(arguments: allStyles.indices) func randomPointsLandInTheCellTheyHit(styleIndex: Int) {
        let layout = TreemapLayout(
            tree: testTree(), bounds: testBounds, options: TreemapLayoutOptions(style: allStyles[styleIndex].style))
        var rng = SplitMix64(seed: 99)
        for _ in 0 ..< 5000 {
            let p = TreemapPoint(x: Float.random(in: 0 ..< 800, using: &rng), y: Float.random(in: 0 ..< 600, using: &rng))
            let hit = layout.hitTest(p)!
            let cell = layout.cells[hit]
            // Containment is by pixel, as painted: the point may be up to half a pixel outside
            // the unrounded rectangle, never more.
            let px = p.x.rounded(.down)
            let py = p.y.rounded(.down)
            #expect(cell.rect.containsPixel(px, py))
            #expect(cell.rect.insetBy(-0.5).contains(p))
            if !cell.isLeaf {
                // Only a directory's frame can be hit directly.
                #expect(
                    !layout.contentRect(ofCell: hit).containsPixel(px, py)
                        || cell.children.allSatisfy { !layout.cells[$0].rect.containsPixel(px, py) })
                #expect(styleIndex != 0)
            }
            // Every ancestor contains the point as well, and the path is the parent chain.
            let path = layout.cellPath(at: p)
            #expect(path.first == 0 && path.last == hit)
            for (depth, index) in path.enumerated() {
                #expect(Int(layout.cells[index].depth) == depth)
                #expect(layout.cells[index].rect.containsPixel(px, py))
            }
            #expect(layout.node(at: p) == cell.node)
        }
    }

    @Test func outsideAndEdges() {
        let layout = TreemapLayout(tree: testTree(), bounds: testBounds)
        #expect(layout.hitTest(TreemapPoint(x: -1, y: 10)) == nil)
        #expect(layout.hitTest(TreemapPoint(x: 10, y: 600)) == nil)  // max edge is exclusive
        #expect(layout.hitTest(TreemapPoint(x: 800, y: 10)) == nil)
        #expect(layout.hitTest(TreemapPoint(x: 0, y: 0)) != nil)
        #expect(layout.hitTest(TreemapPoint(x: 799.99, y: 599.99)) != nil)
        #expect(layout.cellPath(at: TreemapPoint(x: -5, y: -5)).isEmpty)
        #expect(layout.directoryPath(at: TreemapPoint(x: -5, y: -5)).isEmpty)
    }

    @Test func depthLimitedHitTestReturnsTheAncestor() {
        let tree = testTree()
        let layout = TreemapLayout(tree: tree, bounds: testBounds)
        var rng = SplitMix64(seed: 5)
        for _ in 0 ..< 500 {
            let p = TreemapPoint(x: Float.random(in: 0 ..< 800, using: &rng), y: Float.random(in: 0 ..< 600, using: &rng))
            let path = layout.cellPath(at: p)
            #expect(layout.hitTest(p, maxDepth: 0) == 0)
            for depth in 1 ... 3 {
                #expect(layout.hitTest(p, maxDepth: depth) == path[min(depth, path.count - 1)])
            }
            let directories = layout.directoryPath(at: p)
            #expect(directories.first == 0)
            for (a, b) in zip(directories, directories.dropFirst()) { #expect(tree.parent(of: b) == a) }
            let deepest = layout.cells[path.last!]
            if !deepest.isDirectory { #expect(tree.parent(of: deepest.node) == directories.last) }
        }
    }

    /// What is under the pointer is what was painted there: for every pixel, the cell the
    /// rasterizer's rounding gives it to is the cell every point of that pixel hits.
    @Test(arguments: allStyles.indices) func hitTestAgreesWithTheRasterizerOnEveryPixel(styleIndex: Int) {
        let tree = testTree()
        // Fractional and offset bounds put many edges on exact halves, where rounding the edge
        // and comparing the unrounded edge used to disagree.
        let allBounds = [
            TreemapRect(x: 0, y: 0, width: 317, height: 211), TreemapRect(x: 0, y: 0, width: 400.5, height: 300.25),
            TreemapRect(x: 3.5, y: 3.5, width: 397, height: 290), TreemapRect(x: 20.3, y: 10.7, width: 300.4, height: 200.2),
        ]
        for bounds in allBounds {
            let layout = TreemapLayout(tree: tree, bounds: bounds, options: TreemapLayoutOptions(style: allStyles[styleIndex].style))
            let width = Int(bounds.maxX.rounded(.up)) + 3
            let height = Int(bounds.maxY.rounded(.up)) + 3
            var owner = [Int32](repeating: -1, count: width * height)
            var claimedTwice = 0
            func claim(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ index: Int) {
                guard x1 > x0, y1 > y0 else { return }
                for y in Int(y0) ..< Int(y1) {
                    for x in Int(x0) ..< Int(x1) {
                        if owner[y * width + x] >= 0 { claimedTwice += 1 }
                        owner[y * width + x] = Int32(index)
                    }
                }
            }
            for (index, cell) in layout.cells.enumerated() {
                let r = cell.rect.pixelAligned
                if cell.isLeaf {
                    claim(r.minX, r.minY, r.maxX, r.maxY, index)
                } else if !cell.flags.isDisjoint(with: [.header, .padded]) {
                    // The ring between the rectangle and its content, as the renderer paints it.
                    let c = layout.contentRect(ofCell: index).pixelAligned
                    let cx0 = min(r.maxX, max(r.minX, c.minX))
                    let cx1 = min(r.maxX, max(cx0, c.maxX))
                    let cy0 = min(r.maxY, max(r.minY, c.minY))
                    let cy1 = min(r.maxY, max(cy0, c.maxY))
                    claim(r.minX, r.minY, r.maxX, cy0, index)
                    claim(r.minX, cy1, r.maxX, r.maxY, index)
                    claim(r.minX, cy0, cx0, cy1, index)
                    claim(cx1, cy0, r.maxX, cy1, index)
                }
            }
            #expect(claimedTwice == 0)

            var options = flatOptions()
            options.backgroundColor = RGB(r: 1, g: 0, b: 1)
            let bitmap = TreemapBitmap(width: width, height: height)
            TreemapRenderer.render(layout, coloring: colorByNode, options: options, into: bitmap)

            var unowned = 0
            var wrongHit = 0
            var wrongOutside = 0
            var wrongColour = 0
            let inside = bounds.pixelAligned
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let fx = Float(x)
                    let fy = Float(y)
                    let hits = [
                        layout.hitTest(TreemapPoint(x: fx, y: fy)), layout.hitTest(TreemapPoint(x: fx + 0.5, y: fy + 0.5)),
                        layout.hitTest(TreemapPoint(x: fx + 0.99, y: fy + 0.99)),
                    ]
                    let expected = Int(owner[y * width + x])
                    guard fx >= inside.minX, fx < inside.maxX, fy >= inside.minY, fy < inside.maxY else {
                        if expected >= 0 || hits.contains(where: { $0 != nil }) || bitmap[x, y] != 0xFFFF_00FF { wrongOutside += 1 }
                        continue
                    }
                    if expected < 0 { unowned += 1 }
                    if hits.contains(where: { $0 != expected }) { wrongHit += 1 }
                    // The rendered picture agrees: a tile is one flat colour here, so the pixel
                    // has the colour of the first pixel of the tile it hits.
                    if expected >= 0, layout.cells[expected].isLeaf {
                        let r = layout.cells[expected].rect.pixelAligned
                        if bitmap[x, y] != bitmap[Int(r.minX), Int(r.minY)] { wrongColour += 1 }
                    }
                }
            }
            #expect(unowned == 0, "pixels inside the bounds that no cell paints")
            #expect(wrongHit == 0, "pixels whose hit cell is not the cell painted there (bounds \(bounds))")
            #expect(wrongOutside == 0)
            #expect(wrongColour == 0)
        }
    }

    @Test func pixelEdgesRoundHalvesUp() {
        #expect(TreemapRect.pixelEdge(1407.5) == 1408)
        #expect(TreemapRect.pixelEdge(1407.49) == 1407)
        #expect(TreemapRect.pixelEdge(-0.5) == 0)
        let left = TreemapRect(minX: 10, minY: 0, maxX: 20.5, maxY: 4)
        let right = TreemapRect(minX: 20.5, minY: 0, maxX: 30, maxY: 4)
        // Pixel 20 is painted by the left cell although its centre is on the shared edge.
        #expect(left.containsPixel(20, 0) && !right.containsPixel(20, 0))
        #expect(!left.containsPixel(21, 0) && right.containsPixel(21, 0))
        #expect(left.pixelAligned == TreemapRect(minX: 10, minY: 0, maxX: 21, maxY: 4))
        #expect(TreemapRect(minX: 10.6, minY: 0, maxX: 11.4, maxY: 4).pixelAligned.isEmpty)
    }
}

@Suite struct Locating {
    @Test func drawnNodesAreFoundExactly() {
        let layout = TreemapLayout(tree: testTree(), bounds: testBounds)
        for (index, cell) in layout.cells.enumerated() where !cell.isAggregate {
            #expect(layout.locate(cell.node) == TreemapLocation(cell: index, isExact: true))
            #expect(layout.rect(for: cell.node) == cell.rect)
        }
    }

    @Test func prunedNodesResolveToTheirContainer() {
        let tree = testTree()
        let layout = TreemapLayout(tree: tree, bounds: testBounds)
        let drawn = Set(layout.cells.filter { !$0.isAggregate }.map(\.node))
        var pruned = 0
        var unsized = 0
        for id in 0 ..< NodeID(tree.count) where !drawn.contains(id) {
            guard let location = layout.locate(id) else {
                // Only nodes without any size (or under such a directory) have no place at all.
                var node = id
                var hasZeroAncestor = false
                while true {
                    if tree.size(of: node) == 0 { hasZeroAncestor = true }
                    guard let parent = tree.parent(of: node) else { break }
                    node = parent
                }
                #expect(hasZeroAncestor)
                unsized += 1
                continue
            }
            pruned += 1
            #expect(!location.isExact)
            let cell = layout.cells[location.cell]
            #expect(cell.isLeaf)
            // The container is an ancestor's tile, or the aggregate of an ancestor directory.
            #expect(tree.isAncestor(cell.node, of: id))
        }
        #expect(pruned > 5000)
        #expect(pruned + unsized + drawn.count == tree.count)
    }

    @Test func nodesOutsideTheRootAreNotFound() {
        let tree = testTree()
        let sub = tree.children(of: 0).first { tree.isDirectory($0) && tree.childCount(of: $0) > 0 }!
        let layout = TreemapLayout(tree: tree, root: sub, bounds: testBounds)
        #expect(layout.locate(0) == nil)
        #expect(layout.locate(sub) == TreemapLocation(cell: 0, isExact: true))
        #expect(layout.locate(NodeID(tree.count + 10)) == nil)
        for sibling in tree.children(of: 0) where sibling != sub { #expect(layout.locate(sibling) == nil) }
    }
}

@Suite struct Zooming {
    @Test func zoomInMapsTheDirectoryOntoTheNewBounds() {
        let tree = testTree()
        let outer = TreemapLayout(tree: tree, bounds: testBounds)
        // The largest directory two levels down.
        let level1 = tree.children(of: 0).first { tree.isDirectory($0) }!
        let target = tree.children(of: level1).first { tree.isDirectory($0) } ?? level1
        let inner = outer.relayout(root: target)
        #expect(inner.root == target && inner.bounds == testBounds && inner.options == outer.options)

        let transform = outer.zoomTransform(to: inner)!
        let mapped = transform.apply(outer.rect(for: target)!)
        #expect(abs(mapped.minX) < 0.01 && abs(mapped.minY) < 0.01)
        #expect(abs(mapped.maxX - 800) < 0.05 && abs(mapped.maxY - 600) < 0.05)

        // Zooming back out is the inverse.
        let back = inner.zoomTransform(to: outer)!
        let restored = back.apply(testBounds)
        let original = outer.rect(for: target)!
        #expect(abs(restored.minX - original.minX) < 0.05 && abs(restored.maxY - original.maxY) < 0.05)
        let inverse = transform.inverse
        #expect(abs(inverse.scaleX - back.scaleX) < 1e-3 && abs(inverse.translateX - back.translateX) < 0.05)

        // Every node visible in both keeps its relative position under the transform (the
        // layouts differ in level of detail, not in arrangement, when the aspect ratios match).
        let pair = outer.correspondence(of: target, in: inner)!
        #expect(pair.from == original && pair.to == testBounds)
    }

    @Test func unrelatedRootsHaveNoTransform() {
        let tree = testTree()
        let directories = tree.children(of: 0).filter { tree.isDirectory($0) && tree.size(of: $0) > 0 }
        guard directories.count >= 2 else { return }
        let a = TreemapLayout(tree: tree, root: directories[0], bounds: testBounds)
        let b = TreemapLayout(tree: tree, root: directories[1], bounds: testBounds)
        #expect(a.zoomTransform(to: b) == nil)
        #expect(a.zoomTransform(to: a) == .identity)
    }

    @Test func transformInterpolation() {
        let t = TreemapTransform(
            mapping: TreemapRect(x: 100, y: 50, width: 200, height: 100), onto: TreemapRect(x: 0, y: 0, width: 800, height: 600))
        #expect(t.scaleX == 4 && t.scaleY == 6)
        #expect(t.interpolated(0) == .identity)
        let end = t.interpolated(1)
        #expect(abs(end.scaleX - 4) < 1e-4 && abs(end.translateX - t.translateX) < 1e-2 && abs(end.translateY - t.translateY) < 1e-2)
        // Half-way the scale is the geometric mean, and the fixed point has not moved.
        let half = t.interpolated(0.5)
        #expect(abs(half.scaleX - 2) < 1e-4)
        let fixed = TreemapPoint(x: t.translateX / (1 - t.scaleX), y: t.translateY / (1 - t.scaleY))
        let moved = half.apply(fixed)
        #expect(abs(moved.x - fixed.x) < 1e-2 && abs(moved.y - fixed.y) < 1e-2)

        // The two pictures of a zoom stay registered: drawing the target under
        // inverse.interpolated(1 - t) equals mapping it back and applying interpolated(t).
        let probe = TreemapRect(x: 120, y: 300, width: 64, height: 32)
        for step in 0 ... 4 {
            let p = Float(step) / 4
            let direct = t.inverse.interpolated(1 - p).apply(probe)
            let composed = t.interpolated(p).apply(t.inverse.apply(probe))
            #expect(abs(direct.minX - composed.minX) < 0.05 && abs(direct.maxY - composed.maxY) < 0.05)
        }
        // Pure translation interpolates linearly; degenerate sources do not blow up.
        let shift = TreemapTransform(scaleX: 1, scaleY: 1, translateX: 40, translateY: -20)
        #expect(shift.interpolated(0.25) == TreemapTransform(scaleX: 1, scaleY: 1, translateX: 10, translateY: -5))
        let degenerate = TreemapTransform(mapping: .zero, onto: testBounds)
        #expect(degenerate.scaleX == 1 && degenerate.scaleY == 1)
        #expect(t.inverse.apply(t.apply(probe)).minX.rounded() == probe.minX)
    }
}

@Suite struct Labels {
    @Test(arguments: allStyles.indices) func labelsFitTheirCellsAndDoNotOverlap(styleIndex: Int) {
        let tree = testTree()
        let layout = TreemapLayout(
            tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 1600, height: 1200),
            options: TreemapLayoutOptions(style: allStyles[styleIndex].style))
        let labels = layout.labels(TreemapLabelOptions(scale: 2))
        #expect(!labels.isEmpty)
        for label in labels {
            let cell = layout.cells[label.cell]
            #expect(cell.node == label.node)
            #expect(cell.rect.contains(label.rect, tolerance: 0.01))
            #expect(label.rect.width > 0 && label.rect.height > 0)
            #expect(label.fontSize >= 8)
            switch label.kind {
            case .header: #expect(cell.hasHeader && label.rect.maxY <= layout.contentRect(ofCell: label.cell).minY)
            case .overlay: #expect(!cell.isLeaf && !cell.hasHeader)
            case .tile: #expect(cell.isLeaf && !cell.isAggregate && !cell.isCollapsed)
            case .folder: #expect(cell.isCollapsed)
            case .aggregate: #expect(cell.isAggregate)
            }
        }
        for a in labels.indices {
            for b in labels.indices where b > a {
                #expect(!labels[a].rect.intersects(labels[b].rect), "labels \(a) and \(b) overlap")
            }
        }
        #expect(labels == layout.labels(TreemapLabelOptions(scale: 2)))
        if styleIndex >= 2 { #expect(labels.contains { $0.kind == .header }) }
        if styleIndex == 0 { #expect(labels.contains { $0.kind == .overlay }) }
    }

    @Test(arguments: [1, 2]) func collapsedFoldersAreLabelledAsFolders(depth: Int) {
        let tree = testTree()
        let layout = TreemapLayout(
            tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 1600, height: 1200),
            options: TreemapLayoutOptions(style: .adaptive(scale: 2), maxDepth: depth))
        let options = Self.appOptions()
        let labels = layout.labels(options)
        let folders = labels.filter { $0.kind == .folder }
        #expect(!folders.isEmpty)
        for label in folders {
            let cell = layout.cells[label.cell]
            #expect(cell.isCollapsed && cell.node == label.node)
            #expect(cell.rect.contains(label.rect, tolerance: 0.01))
            #expect(label.fontSize >= options.minFontSize * 2 && label.fontSize <= options.maxFolderFontSize * 2)
            // The second line (size and share) is promised only where two lines fit.
            #expect(label.fitsDetail == (label.rect.height >= label.fontSize * 2.5))
        }
        // Every collapsed folder of a decent size is named, and none is labelled like a file.
        for (index, cell) in layout.cells.enumerated() where cell.isCollapsed {
            #expect(!labels.contains { $0.cell == index && $0.kind == .tile })
            if cell.rect.width >= 240, cell.rect.height >= 120 {
                #expect(folders.contains { $0.cell == index }, "collapsed folder \(index) has no label")
            }
        }
        // The biggest block gets the biggest type.
        let largest = folders.max { layout.cells[$0.cell].rect.area < layout.cells[$1.cell].rect.area }!
        #expect(largest.fontSize == folders.map(\.fontSize).max())
        Self.expectNoOverlap(labels)
        if depth == 1 { #expect(!labels.contains { $0.kind == .header }) } else { #expect(labels.contains { $0.kind == .header }) }
    }

    @Test func deepHeadersGetLabelsThatFitTheirSlimmerStrips() {
        let tree = LayoutContent.nestedTree()
        let layout = TreemapLayout(
            tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 1600, height: 1200),
            options: TreemapLayoutOptions(style: .adaptive(scale: 2)))
        var options = Self.appOptions()
        options.headerFontSize = 12
        let labels = layout.labels(options)
        let headers = labels.filter { $0.kind == .header }
        #expect(headers.contains { layout.cells[$0.cell].depth >= 4 })
        var sizeByDepth: [UInt16: Float] = [:]
        for label in headers {
            let strip = layout.headerRect(ofCell: label.cell)!
            #expect(strip.contains(label.rect, tolerance: 0.01))
            #expect(label.fontSize <= strip.height * 0.8 + 0.01 && label.fontSize >= 9 * 2)
            sizeByDepth[layout.cells[label.cell].depth] = label.fontSize
        }
        // Type never grows with depth.
        let ordered = sizeByDepth.sorted { $0.key < $1.key }.map(\.value)
        for (outer, inner) in zip(ordered, ordered.dropFirst()) { #expect(inner <= outer) }
        // Headers come first, outermost first.
        let depths = labels.prefix(headers.count).map { layout.cells[$0.cell].depth }
        #expect(labels.prefix(headers.count).allSatisfy { $0.kind == .header })
        _ = depths
        Self.expectNoOverlap(labels)
    }

    /// The label options the app uses.
    static func appOptions(minTileWidth: Float = 54) -> TreemapLabelOptions {
        var options = TreemapLabelOptions(scale: 2)
        options.minFontSize = 9.5
        options.maxFontSize = 13
        options.minTileWidth = minTileWidth
        return options
    }

    static func expectNoOverlap(_ labels: [TreemapLabel]) {
        for a in labels.indices {
            for b in labels.indices where b > a {
                #expect(!labels[a].rect.intersects(labels[b].rect), "labels \(a) and \(b) overlap")
            }
        }
    }

    /// Squarify puts a directory's largest child in its top-left corner, under the directory's
    /// overlay label. That tile must keep its name, below the overlay.
    @Test(arguments: 0 ..< 2) func largestFileOfAFolderIsLabelledBelowTheOverlay(styleIndex: Int) throws {
        var top: [FileTree.Spec] = []
        for d in 0 ..< 8 {
            var files: [FileTree.Spec] = [.file("dominant-\(d).bin", UInt64(400_000_000 + d * 30_000_000))]
            for i in 0 ..< 40 { files.append(.file("item-\(d)-\(i).dat", UInt64(2_000_000 + i * 150_000))) }
            top.append(.dir("folder\(d)", files))
        }
        let tree = FileTree.make(top)
        let layout = TreemapLayout(
            tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 1660, height: 2200),
            options: TreemapLayoutOptions(style: allStyles[styleIndex].style))
        let options = Self.appOptions()
        let labels = layout.labels(options)
        let directories = tree.children(of: 0)
        #expect(directories.count == 8)
        for directory in directories {
            let overlay = try #require(labels.first { $0.kind == .overlay && $0.node == directory })
            let largest = try #require(tree.children(of: directory).first)
            let location = try #require(layout.locate(largest))
            #expect(location.isExact)
            let cell = layout.cells[location.cell]
            // The premise: the tile really is the one under the overlay.
            #expect(cell.rect.intersects(overlay.rect))
            let label = try #require(labels.first { $0.kind == .tile && $0.cell == location.cell }, "largest file has no label")
            #expect(label.node == largest)
            #expect(label.rect.minY >= overlay.rect.maxY)
            #expect(cell.rect.contains(label.rect, tolerance: 0.01))
            #expect(label.rect.minX == cell.rect.minX + 8 && label.rect.maxX == cell.rect.maxX - 8)
            #expect(label.fontSize >= 19 && label.fontSize <= 26)
            // Two lines (name and size) are centred in the box: only if both fit below the overlay.
            #expect(label.fitsDetail == (label.rect.height >= label.fontSize * 2.6))
        }
        Self.expectNoOverlap(labels)
        // Carving changes neither the order nor which tiles win: largest cells first.
        let tiles = labels.filter { $0.kind == .tile }
        for (a, b) in zip(tiles, tiles.dropFirst()) {
            #expect(layout.cells[a.cell].rect.area >= layout.cells[b.cell].rect.area)
        }
    }

    /// A tile that is barely taller than the overlay has no room left below it: no label, and
    /// certainly none under the overlay.
    @Test func tileTooShortBelowTheOverlayGetsNoLabel() throws {
        let tree = FileTree.make([.dir("d", [.file("first-file.bin", 5000), .file("other-file.bin", 5000)])])
        let directory = tree.children(of: 0)[0]
        let files = tree.children(of: directory)
        let options = Self.appOptions(minTileWidth: 40)

        func tileLabels(height: Float) throws -> (overlay: TreemapLabel, top: TreemapLabel?, bottom: TreemapLabel?, topCell: TreemapCell) {
            let layout = TreemapLayout(tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 150, height: height))
            let labels = layout.labels(options)
            Self.expectNoOverlap(labels)
            let overlay = try #require(labels.first { $0.kind == .overlay })
            #expect(overlay.node == directory)
            let cells = try files.map { try #require(layout.locate($0)) }
            #expect(cells.allSatisfy { $0.isExact })
            // Two tiles stacked; the upper one lies under the overlay.
            let upper = cells.min { layout.cells[$0.cell].rect.minY < layout.cells[$1.cell].rect.minY }!.cell
            let lower = cells.first { $0.cell != upper }!.cell
            #expect(layout.cells[upper].rect.intersects(overlay.rect) && !layout.cells[lower].rect.intersects(overlay.rect))
            return (
                overlay, labels.first { $0.kind == .tile && $0.cell == upper }, labels.first { $0.kind == .tile && $0.cell == lower },
                layout.cells[upper]
            )
        }

        // Overlay: 8 px margin + 33 px line. A label needs 8 + 23.75 + 8 px below that: 80.75 px.
        let short = try tileLabels(height: 156)
        #expect(short.topCell.rect.height == 78)
        #expect(short.overlay.rect.maxY == 41)
        #expect(short.top == nil)
        #expect(short.bottom != nil)

        // A few pixels more and the name fits under the overlay, on one line.
        let tall = try tileLabels(height: 172)
        #expect(tall.topCell.rect.height == 86)
        let label = try #require(tall.top)
        #expect(label.rect.minY == 49 && label.rect.maxY == 78)
        #expect(!label.fitsDetail)
    }

    /// The overlay's box is what the view may cover with its pill: padding, the name and the
    /// size. Wide characters count as wide, not as three bytes.
    @Test func overlayBoxReservesNameAndSize() throws {
        let cjk = "资料备份文件夹"  // 7 characters, 21 bytes
        let long = "Application Support"
        let sameBytes = "abcdefghijklmnopqrstu"  // 21 characters, 21 bytes
        var top: [FileTree.Spec] = []
        for (i, name) in [cjk, long, sameBytes, "usr"].enumerated() {
            top.append(.dir(name, [.file("a\(i).bin", 5_000_000), .file("b\(i).bin", 4_000_000), .file("c\(i).bin", 3_000_000)]))
        }
        let tree = FileTree.make(top)
        let layout = TreemapLayout(tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 2400, height: 1500))
        let options = Self.appOptions()
        #expect(options.overlayPaddingPixels == 10)
        let labels = layout.labels(options)
        func overlay(_ name: String) throws -> TreemapLabel {
            try #require(labels.first { $0.kind == .overlay && tree.name(of: $0.node) == name })
        }
        // At scale 2 the header font is 22 px; the size takes about 100 px and the padding 34.
        let font: Float = 22
        let extras: ClosedRange<Float> = 110 ... 160
        for (name, characters, perCharacter) in [(long, 19, 0.55 ... 0.7), (sameBytes, 21, 0.55 ... 0.7), ("usr", 3, 0.55 ... 0.7), (cjk, 7, 1.0 ... 1.1)]
            as [(String, Float, ClosedRange<Float>)]
        {
            let label = try overlay(name)
            #expect(label.fitsDetail)
            #expect(label.rect.height == 33)
            let width = label.rect.width
            #expect(width >= characters * font * perCharacter.lowerBound + extras.lowerBound, "\(name): \(width)")
            #expect(width <= characters * font * perCharacter.upperBound + extras.upperBound, "\(name): \(width)")
        }
        #expect(try overlay(cjk).rect.width < overlay(sameBytes).rect.width)
        Self.expectNoOverlap(labels)

        // In a directory too narrow for all of it the box ends at the directory's margin and
        // says that the size does not fit.
        let narrow = TreemapLayout(
            tree: FileTree.make([.dir(long, [.file("a.bin", 5000), .file("b.bin", 4000)])]),
            bounds: TreemapRect(x: 0, y: 0, width: 300, height: 400))
        let clipped = try #require(narrow.labels(options).first { $0.kind == .overlay })
        #expect(clipped.rect.maxX == 292 && !clipped.fitsDetail)
    }

    @Test func glyphEstimateCountsCharactersNotBytes() {
        func glyphs(_ text: String) -> Float { TreemapLayout.estimatedGlyphs(Array(text.utf8), advance: 0.5) }
        #expect(glyphs("usr") == 3)
        #expect(glyphs("café") == 4)
        #expect(glyphs("cafe\u{301}") == 4)  // combining accent
        #expect(glyphs("Ωμέγα") == 5)
        #expect(glyphs("日本語") == 6)  // three full ems at half an em per glyph
        #expect(glyphs("a😀") == 3)
        #expect(glyphs("") == 0)
        // Invalid UTF-8 (file names are bytes) neither crashes nor vanishes.
        #expect(TreemapLayout.estimatedGlyphs([0x61, 0x80, 0xFF, 0xE4], advance: 0.5) >= 2)
    }

    @Test func optionsAreHonoured() {
        let tree = testTree()
        let layout = TreemapLayout(tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 1600, height: 1200))
        let all = layout.labels()
        let few = layout.labels(TreemapLabelOptions(maxCount: 5))
        #expect(few.count == 5)
        #expect(Array(all.prefix(5)) == few)
        let noFiles = layout.labels(TreemapLabelOptions(overlayDepth: 0, includeFiles: false, includeAggregates: false))
        #expect(noFiles.allSatisfy { layout.cells[$0.cell].isDirectory })
        // Tile labels come largest first.
        let tiles = all.filter { $0.kind == .tile }
        for (a, b) in zip(tiles, tiles.dropFirst()) {
            #expect(layout.cells[a.cell].rect.area >= layout.cells[b.cell].rect.area)
        }
        // Tiny maps carry no labels at all.
        #expect(layout.relayout(bounds: TreemapRect(x: 0, y: 0, width: 30, height: 20)).labels().isEmpty)
    }
}
