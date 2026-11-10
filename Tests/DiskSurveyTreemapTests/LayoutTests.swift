import Foundation
import Testing
import DiskSurveyCore
@testable import DiskSurveyTreemap

let testBounds = TreemapRect(x: 0, y: 0, width: 800, height: 600)

func testTree(_ nodes: Int = 20_000, seed: UInt64 = 42) -> FileTree {
    FileTree.synthetic(nodeCount: nodes, seed: seed)
}

let allStyles: [(name: String, style: TreemapStyle)] = [
    ("cushion", .cushion), ("grouped", .grouped(scale: 2)), ("framed", .framed(scale: 2)),
    ("adaptive", .adaptive(scale: 2)),
]

@Suite struct LayoutInvariants {
    @Test func rootCellCoversBounds() {
        let layout = TreemapLayout(tree: testTree(), bounds: testBounds)
        #expect(layout.cells[0].rect == testBounds)
        #expect(layout.cells[0].parent == -1)
        #expect(layout.cells[0].depth == 0)
        #expect(layout.cells[0].node == 0)
        #expect(layout.cells.count > 1000)
    }

    @Test(arguments: allStyles.indices) func structureIsConsistent(styleIndex: Int) {
        let style = allStyles[styleIndex].style
        let layout = TreemapLayout(tree: testTree(), bounds: testBounds, options: TreemapLayoutOptions(style: style))
        let cells = layout.cells
        var seenAsChild = 1  // the root
        for (index, cell) in cells.enumerated() {
            if cell.isLeaf {
                #expect(cell.children.isEmpty)
                continue
            }
            #expect(cell.isDirectory && !cell.isAggregate)
            #expect(cell.childCount > 0)
            // Parents precede children; children are contiguous and point back.
            #expect(Int(cell.firstChild) > index)
            seenAsChild += cell.children.count
            let content = layout.contentRect(ofCell: index)
            #expect(cell.rect.contains(content))
            var area: Float = 0
            for child in cell.children {
                let c = cells[child]
                #expect(Int(c.parent) == index)
                #expect(c.depth == cell.depth + 1)
                #expect(content.contains(c.rect, tolerance: 0.01), "child \(child) leaves its parent's content")
                #expect(c.rect.maxX >= c.rect.minX && c.rect.maxY >= c.rect.minY)
                area += c.rect.area
            }
            // The children tile the content exactly.
            #expect(abs(area - content.area) <= max(0.5, content.area * 2e-3), "cell \(index): \(area) vs \(content.area)")
            // No two siblings overlap.
            let children = Array(cell.children)
            if children.count <= 400 {
                for a in children.indices {
                    for b in children.indices where b > a {
                        let overlap = cells[children[a]].rect.intersection(cells[children[b]].rect)
                        #expect(overlap.width < 0.01 || overlap.height < 0.01)
                    }
                }
            }
        }
        // Every cell is the child of exactly one parent.
        #expect(seenAsChild == cells.count)
    }

    @Test func areaIsProportionalToSize() {
        let tree = testTree()
        let layout = TreemapLayout(tree: tree, bounds: testBounds)
        let scale = Double(testBounds.area) / Double(tree.size(of: 0))
        var checked = 0
        for cell in layout.cells where !cell.isAggregate {
            let expected = Double(tree.size(of: cell.node)) * scale
            let actual = Double(cell.rect.area)
            #expect(abs(actual - expected) <= max(0.75, expected * 0.01), "node \(cell.node): \(actual) vs \(expected)")
            checked += 1
        }
        #expect(checked > 1000)
    }

    @Test func aggregatesAccountForTheSmallSiblings() {
        let tree = testTree()
        let layout = TreemapLayout(tree: tree, bounds: testBounds)
        let scale = Double(testBounds.area) / Double(tree.size(of: 0))
        var aggregates = 0
        for (index, cell) in layout.cells.enumerated() where cell.isAggregate {
            aggregates += 1
            #expect(cell.isLeaf && cell.mergedCount >= 2)
            let parent = layout.cells[Int(cell.parent)]
            #expect(parent.node == cell.node)
            // Its area is what the parent's drawn children leave over.
            var drawn: UInt64 = 0
            for sibling in parent.children where sibling != index { drawn += tree.size(of: layout.cells[sibling].node) }
            let expected = Double(tree.size(of: cell.node) - drawn) * scale
            #expect(abs(Double(cell.rect.area) - expected) <= max(0.75, expected * 0.01))
            #expect(parent.children.count - 1 + cell.mergedCount == tree.childCount(of: cell.node))
            // The sample is a real file inside the directory.
            #expect(!tree.isDirectory(cell.sample))
            #expect(tree.isAncestor(cell.node, of: cell.sample))
        }
        #expect(aggregates > 10)
    }

    @Test func everyNodeAboveTheThresholdIsDrawn() {
        let tree = testTree()
        let options = TreemapLayoutOptions()
        let layout = TreemapLayout(tree: tree, bounds: testBounds, options: options)
        var expanded = 0
        for (index, cell) in layout.cells.enumerated() where !cell.isLeaf {
            expanded += 1
            let content = layout.contentRect(ofCell: index)
            let scale = Double(content.area) / Double(tree.size(of: cell.node))
            let drawn = Set(cell.children.filter { !layout.cells[$0].isAggregate }.map { layout.cells[$0].node })
            for child in tree.children(of: cell.node) {
                if Double(tree.size(of: child)) * scale >= Double(options.minCellArea) * 1.001 {
                    #expect(drawn.contains(child), "node \(child) is big enough but missing")
                }
            }
            // And directories are only collapsed when they are too small to subdivide.
        }
        for cell in layout.cells where cell.isLeaf && cell.isDirectory && !cell.isAggregate {
            let tooSmall = min(cell.rect.width, cell.rect.height) < options.minCellSide
            let nothingToShow = tree.size(of: cell.node) == 0 || tree.childCount(of: cell.node) == 0
            // The third reason: all children are below the area threshold.
            let largest = tree.childCount(of: cell.node) > 0 ? tree.size(of: tree.child(of: cell.node, at: 0)) : 0
            let scale = Double(cell.rect.area) / Double(max(1, tree.size(of: cell.node)))
            let allTiny = Double(largest) * scale < Double(options.minCellArea)
            #expect(tooSmall || nothingToShow || allTiny)
        }
        #expect(expanded > 100)
    }

    @Test func aspectRatiosAreSane() {
        let layout = TreemapLayout(tree: testTree(), bounds: testBounds)
        var ratios: [Float] = []
        for cell in layout.cells where cell.isLeaf && cell.rect.area >= 64 {
            ratios.append(max(cell.rect.width / cell.rect.height, cell.rect.height / cell.rect.width))
        }
        ratios.sort()
        #expect(ratios.count > 200)
        let median = ratios[ratios.count / 2]
        let p90 = ratios[ratios.count * 9 / 10]
        #expect(median < 2.0, "median aspect ratio \(median)")
        #expect(p90 < 5.0, "90th percentile aspect ratio \(p90)")
    }

    @Test func layoutIsDeterministic() {
        let tree = testTree()
        for (_, style) in allStyles {
            let a = TreemapLayout(tree: tree, bounds: testBounds, options: TreemapLayoutOptions(style: style))
            let b = TreemapLayout(tree: tree, bounds: testBounds, options: TreemapLayoutOptions(style: style))
            #expect(a.cells == b.cells)
        }
        // A rebuilt identical tree gives the identical layout too.
        let again = TreemapLayout(tree: testTree(), bounds: testBounds)
        #expect(again.cells == TreemapLayout(tree: tree, bounds: testBounds).cells)
    }

    @Test(arguments: allStyles.indices) func parallelAndSerialLayoutsAgree(styleIndex: Int) {
        let tree = testTree(150_000, seed: 8)
        let bounds = TreemapRect(x: 0, y: 0, width: 1500, height: 1000)
        let options = TreemapLayoutOptions(style: allStyles[styleIndex].style)
        let parallel = TreemapLayout(tree: tree, bounds: bounds, options: options)
        let serial = TreemapLayout(tree: tree, root: 0, bounds: bounds, options: options, allowParallel: false)
        #expect(parallel.cells.count == serial.cells.count)
        #expect(parallel.cells.count > 20_000)
        // Same cells, possibly in a different order: compare everything but the indices.
        struct Key: Hashable {
            var node: NodeID, sample: NodeID, rect: TreemapRect, surface: CushionSurface
            var depth: UInt16, flags: TreemapCell.Flags, parentNode: NodeID, children: Int32
        }
        func keys(_ layout: TreemapLayout) -> Set<Key> {
            Set(layout.cells.map { cell in
                Key(
                    node: cell.node, sample: cell.sample, rect: cell.rect, surface: cell.surface, depth: cell.depth,
                    flags: cell.flags, parentNode: cell.parent < 0 ? .max : layout.cells[Int(cell.parent)].node,
                    children: cell.childCount)
            })
        }
        #expect(keys(parallel) == keys(serial))
        // The spliced layout keeps the structural guarantees.
        for (index, cell) in parallel.cells.enumerated() where !cell.isLeaf {
            #expect(Int(cell.firstChild) > index)
            for child in cell.children { #expect(Int(parallel.cells[child].parent) == index) }
        }
        // And the picture is identical.
        let a = TreemapRenderer.render(parallel, coloring: .byKind(tree))
        let b = TreemapRenderer.render(serial, coloring: .byKind(tree))
        #expect(a.width == b.width && memcmp(a.pixels, b.pixels, a.byteCount) == 0)
    }

    @Test func costDependsOnPixelsNotNodes() {
        let tree = testTree(200_000, seed: 3)
        let small = TreemapLayout(tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 200, height: 150))
        let large = TreemapLayout(tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 1600, height: 1200))
        #expect(small.cells.count < 200 * 150 / 4)
        #expect(small.cells.count < large.cells.count / 8)
        #expect(large.cells.count < tree.count)
    }

    @Test func tinyAndDegenerateBounds() {
        let tree = testTree(2000)
        for (w, h) in [(0, 0), (1, 1), (2, 300), (300, 2), (5, 5)] as [(Float, Float)] {
            let layout = TreemapLayout(tree: tree, bounds: TreemapRect(x: 0, y: 0, width: w, height: h))
            #expect(layout.cells[0].rect.width == w)
            for cell in layout.cells {
                #expect(cell.rect.minX.isFinite && cell.rect.maxX.isFinite && cell.rect.minY.isFinite && cell.rect.maxY.isFinite)
                #expect(layout.bounds.contains(cell.rect, tolerance: 0.01))
                #expect(cell.surface.ax.isFinite && cell.surface.bx.isFinite && cell.surface.ay.isFinite && cell.surface.by.isFinite)
            }
        }
    }

    @Test func offsetBoundsAreRespected() {
        let bounds = TreemapRect(x: 100, y: 50, width: 640, height: 480)
        let layout = TreemapLayout(tree: testTree(), bounds: bounds)
        for cell in layout.cells { #expect(bounds.contains(cell.rect, tolerance: 0.01)) }
        #expect(layout.hitTest(TreemapPoint(x: 50, y: 60)) == nil)
        #expect(layout.hitTest(TreemapPoint(x: 400, y: 300)) != nil)
    }
}

@Suite struct LayoutContent {
    static let small = FileTree.make(rootPath: "/Demo", [
        .dir("Movies", [.file("a.mp4", 4000), .file("b.mov", 2000), .dir("Empty")]),
        .dir("Docs", [.file("x.pdf", 1000), .file("zero.txt", 0), .file("y.txt", 1000, logical: 9000)]),
        .file("big.zip", 2000),
        .dir("Nothing", [.file("hollow", 0)]),
    ])

    @Test func zeroSizedNodesAreSkipped() {
        let tree = Self.small
        let layout = TreemapLayout(tree: tree, bounds: testBounds)
        let nodes = Set(layout.cells.map(\.node))
        for name in ["/Demo/Movies/Empty", "/Demo/Docs/zero.txt", "/Demo/Nothing", "/Demo/Nothing/hollow"] {
            let node = tree.node(atPath: name)!
            #expect(!nodes.contains(node), "\(name) has no size and must not get a cell")
            #expect(layout.locate(node) == nil)
        }
        // root + Movies, Docs, big.zip + a, b + x, y
        #expect(layout.cells.count == 8)
        #expect(layout.leafCount == 5)
        for cell in layout.cells { #expect(cell.rect.area > 0) }
    }

    @Test func removedNodesAreSkipped() {
        var tree = Self.small
        let movies = tree.node(atPath: "/Demo/Movies")!
        let pdf = tree.node(atPath: "/Demo/Docs/x.pdf")!
        tree.remove(movies)
        tree.remove(pdf)
        let layout = TreemapLayout(tree: tree, bounds: testBounds)
        #expect(!layout.cells.contains { $0.node == movies || $0.node == pdf })
        #expect(layout.locate(movies) == nil)
        // root + Docs, big.zip + y.txt
        #expect(layout.cells.count == 4)
        let leafArea = layout.cells.filter(\.isLeaf).reduce(Float(0)) { $0 + $1.rect.area }
        #expect(abs(leafArea - testBounds.area) < 1)

        // A removed root gives a single inert cell rather than a crash.
        let gone = TreemapLayout(tree: tree, root: movies, bounds: testBounds)
        #expect(gone.cells.count == 1 && gone.cells[0].isLeaf)
    }

    @Test func emptyTreeIsOneLeaf() {
        let layout = TreemapLayout(tree: FileTree.empty(), bounds: testBounds)
        #expect(layout.cells.count == 1)
        #expect(layout.cells[0].isLeaf)
        #expect(layout.hitTest(TreemapPoint(x: 10, y: 10)) == 0)
        #expect(layout.labels().isEmpty)
    }

    @Test func fileRootIsOneLeaf() {
        let tree = Self.small
        let file = tree.node(atPath: "/Demo/big.zip")!
        let layout = TreemapLayout(tree: tree, root: file, bounds: testBounds)
        #expect(layout.cells.count == 1 && layout.cells[0].isLeaf && layout.cells[0].sample == file)
    }

    @Test func logicalMetricUsesLogicalSizes() {
        let tree = Self.small
        let layout = TreemapLayout(
            tree: tree, bounds: testBounds, options: TreemapLayoutOptions(sizeMetric: .logical))
        let y = tree.node(atPath: "/Demo/Docs/y.txt")!
        let cell = layout.cells[layout.cell(for: y)!]
        let expected = Double(testBounds.area) * 9000 / Double(tree.logicalSize(of: 0))
        #expect(abs(Double(cell.rect.area) - expected) < expected * 0.01)
        // Children are ordered by the chosen metric: Docs (10,000 logical) now outweighs Movies.
        #expect(layout.cells[1].node == tree.node(atPath: "/Demo/Docs")!)
    }

    @Test func partialSnapshotTreesLayOut() {
        let builder = FileTree.Builder(rootPath: "/Scan")
        let worker = builder.makeWorker()
        let dir = worker.append(to: .root, name: "a", allocatedSize: 0, logicalSize: 0, modified: 0, flags: .directory)
        for i in 0 ..< 50 {
            worker.append(to: dir, name: "f\(i)", allocatedSize: UInt64(1000 + i * 37), logicalSize: 1, modified: 0)
        }
        let first = TreemapLayout(tree: builder.snapshot(), bounds: testBounds)
        for i in 0 ..< 50 {
            worker.append(to: .root, name: "g\(i)", allocatedSize: UInt64(5000 + i), logicalSize: 1, modified: 0)
        }
        let second = TreemapLayout(tree: builder.snapshot(), bounds: testBounds)
        let final = TreemapLayout(tree: builder.finalize(), bounds: testBounds)
        #expect(first.leafCount == 50)
        #expect(second.leafCount == 100)
        #expect(final.leafCount == 100)
        for layout in [first, second, final] {
            let area = layout.cells.filter(\.isLeaf).reduce(Float(0)) { $0 + $1.rect.area }
            #expect(abs(area - testBounds.area) < 1)
        }
    }

    @Test func manyTinyFilesMergeIntoOneAggregate() {
        var specs: [FileTree.Spec] = [.file("huge.bin", 50_000_000), .file("large.bin", 30_000_000)]
        for i in 0 ..< 5000 { specs.append(.file("tiny\(i).txt", 512)) }
        let tree = FileTree.make([.dir("mixed", specs)])
        let layout = TreemapLayout(tree: tree, bounds: testBounds)
        // root, mixed, huge, large, aggregate
        #expect(layout.cells.count == 5)
        let aggregate = layout.cells.first { $0.isAggregate }!
        #expect(aggregate.mergedCount == 5000)
        #expect(aggregate.node == tree.node(atPath: "/Synthetic/mixed")!)
        #expect(aggregate.firstChild == 2)
        let share = aggregate.rect.area / testBounds.area
        #expect(abs(share - Float(5000.0 * 512 / (80_000_000 + 5000 * 512))) < 0.002)
        // A pruned file resolves to the aggregate that stands for it.
        let tiny = tree.node(atPath: "/Synthetic/mixed/tiny17.txt")!
        let location = layout.locate(tiny)!
        #expect(!location.isExact && layout.cells[location.cell].isAggregate)
        #expect(layout.rect(for: tiny) == aggregate.rect)

        // When nothing in a directory is big enough, the directory itself is the tile.
        let onlyTiny = FileTree.make([.dir("dust", (0 ..< 20_000).map { .file("f\($0)", 4096) })])
        let dust = TreemapLayout(tree: onlyTiny, bounds: TreemapRect(x: 0, y: 0, width: 100, height: 100))
        #expect(dust.cells.count == 2 && dust.cells[1].isLeaf && !dust.cells[1].isAggregate)
        #expect(!onlyTiny.isDirectory(dust.cells[1].sample))
    }

    @Test func packagesCanBeLeaves() {
        let tree = FileTree.make([
            .dir("Thing.app", [.dir("Contents", [.file("binary", 5000), .file("data.car", 3000)])]),
            .file("other.txt", 2000),
        ])
        let open = TreemapLayout(tree: tree, bounds: testBounds)
        #expect(open.leafCount == 3)
        let closed = TreemapLayout(tree: tree, bounds: testBounds, options: TreemapLayoutOptions(packagesAsLeaves: true))
        #expect(closed.leafCount == 2)
        let app = tree.node(atPath: "/Synthetic/Thing.app")!
        let cell = closed.cells[closed.cell(for: app)!]
        #expect(cell.isLeaf && cell.sample == app)
        // Zooming into the package still shows its contents.
        #expect(closed.relayout(root: app).leafCount == 2)
    }

    @Test func maxDepthLimitsSubdivision() {
        let tree = testTree()
        let shallow = TreemapLayout(tree: tree, bounds: testBounds, options: TreemapLayoutOptions(maxDepth: 1))
        #expect(shallow.cells.allSatisfy { $0.depth <= 1 })
        #expect(shallow.cells.dropFirst().allSatisfy { $0.isLeaf })
    }

    @Test func framesReserveHeaderAndPadding() {
        let tree = FileTree.make([
            .dir("A", [.file("a1", 3000), .file("a2", 2000), .dir("Inner", [.file("i1", 2500), .file("i2", 2500)])]),
            .dir("B", [.file("b1", 4000), .file("b2", 1000)]),
        ])
        let style = TreemapStyle.framed(scale: 2)
        let layout = TreemapLayout(tree: tree, bounds: testBounds, options: TreemapLayoutOptions(style: style))
        // The root is not framed.
        #expect(layout.contentRect(ofCell: 0) == testBounds)
        #expect(layout.headerRect(ofCell: 0) == nil)
        let a = layout.cell(for: tree.node(atPath: "/Synthetic/A")!)!
        #expect(layout.cells[a].hasHeader && layout.cells[a].flags.contains(.padded))
        let header = layout.headerRect(ofCell: a)!
        let content = layout.contentRect(ofCell: a)
        #expect(header.height == style.header)
        #expect(header.minX == layout.cells[a].rect.minX && header.maxX == layout.cells[a].rect.maxX)
        #expect(content.minY == header.maxY)
        #expect(content.minX == layout.cells[a].rect.minX + style.padding)
        #expect(content.maxY == layout.cells[a].rect.maxY - style.padding)
        // A point on the header hits the directory, a point inside hits a file.
        #expect(layout.hitTest(TreemapPoint(x: header.midX, y: header.midY)) == a)
        let inside = layout.hitTest(TreemapPoint(x: content.midX, y: content.midY))!
        #expect(layout.cells[inside].isLeaf && tree.isAncestor(layout.cells[a].node, of: layout.cells[inside].node))
        // Sibling areas stay proportional among themselves inside a frame.
        let b1 = layout.cells[layout.cell(for: tree.node(atPath: "/Synthetic/B/b1")!)!]
        let b2 = layout.cells[layout.cell(for: tree.node(atPath: "/Synthetic/B/b2")!)!]
        #expect(abs(b1.rect.area / b2.rect.area - 4) < 0.05)
    }

    @Test func dominantChildIsNotFramedTwice() {
        let tree = FileTree.make([
            .dir("Outer", [.dir("Chain", [.dir("Deep", [.file("x", 6000), .file("y", 4000)])])]),
            .file("side", 5000),
        ])
        let layout = TreemapLayout(
            tree: tree, bounds: testBounds, options: TreemapLayoutOptions(style: .framed(scale: 1, depth: 5)))
        let outer = layout.cells[layout.cell(for: tree.node(atPath: "/Synthetic/Outer")!)!]
        let chain = layout.cells[layout.cell(for: tree.node(atPath: "/Synthetic/Outer/Chain")!)!]
        let deep = layout.cells[layout.cell(for: tree.node(atPath: "/Synthetic/Outer/Chain/Deep")!)!]
        #expect(outer.hasHeader)
        #expect(!chain.hasHeader && chain.flags.isDisjoint(with: [.header, .padded]))
        // The comparison is with the nearest framed ancestor, so the whole chain gets one frame.
        #expect(!deep.isFramed)
    }

    // MARK: Adaptive frames

    /// A tree with big folders several levels down: root/Big/Mid/Deep/Deeper/… next to small ones.
    static func nestedTree() -> FileTree {
        func files(_ prefix: String, _ count: Int, _ size: UInt64) -> [FileTree.Spec] {
            (0 ..< count).map { .file("\(prefix)\($0).bin", size) }
        }
        return FileTree.make([
            .dir("Big", [
                .dir("Mid", [
                    .dir("Deep", [
                        .dir("Deeper", [.dir("Deepest", files("e", 6, 900)), .dir("Other", files("o", 5, 700))]),
                        .dir("Side", files("s", 8, 500)),
                    ]),
                    .dir("Next", files("n", 6, 800)),
                ]),
                .dir("Tiny", files("t", 3, 2)),
                .dir("Second", files("x", 5, 900)),
            ]),
            .dir("Small", files("m", 4, 300)),
        ])
    }

    @Test func adaptiveFramesReachAnyDepthWhereThereIsRoom() {
        let tree = Self.nestedTree()
        let bounds = TreemapRect(x: 0, y: 0, width: 1600, height: 1200)
        let framed = TreemapLayout(tree: tree, bounds: bounds, options: TreemapLayoutOptions(style: .framed(scale: 1)))
        let adaptive = TreemapLayout(tree: tree, bounds: bounds, options: TreemapLayoutOptions(style: .adaptive(scale: 1)))
        func cell(_ layout: TreemapLayout, _ path: String) -> TreemapCell {
            layout.cells[layout.cell(for: tree.node(atPath: "/Synthetic/" + path)!)!]
        }
        // The classic style stops after two levels; the adaptive one names the big folders below.
        #expect(cell(framed, "Big/Mid").hasHeader && !cell(framed, "Big/Mid/Deep").isFramed)
        for path in ["Big", "Big/Mid", "Big/Mid/Deep", "Big/Mid/Deep/Deeper", "Big/Mid/Deep/Deeper/Deepest", "Big/Mid/Next"] {
            #expect(cell(adaptive, path).hasHeader, "\(path) should carry a title")
        }
        // Deeper levels get slimmer strips, never taller ones.
        var previous = Float.infinity
        for path in ["Big", "Big/Mid", "Big/Mid/Deep", "Big/Mid/Deep/Deeper", "Big/Mid/Deep/Deeper/Deepest"] {
            let index = adaptive.cell(for: tree.node(atPath: "/Synthetic/" + path)!)!
            let header = adaptive.headerRect(ofCell: index)!
            #expect(header.height <= previous && header.height >= 12)
            #expect(header.height == adaptive.options.style.level(at: Int(adaptive.cells[index].frameLevel)).header)
            #expect(adaptive.contentRect(ofCell: index).minY == header.maxY)
            previous = header.height
        }
        // A folder too small for a title gets no frame at all below the first two levels…
        let small = TreemapLayout(
            tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 420, height: 300),
            options: TreemapLayoutOptions(style: .adaptive(scale: 1)))
        for (index, cell) in small.cells.enumerated() where cell.depth >= 3 && !cell.isLeaf {
            #expect(cell.hasHeader == cell.isFramed)
            if cell.hasHeader {
                let level = small.options.style.level(at: Int(cell.frameLevel))
                #expect(cell.rect.width >= level.minHeaderWidth && cell.rect.height >= level.minHeaderHeight)
                // …and a title never takes more than about a quarter of what it titles.
                #expect(small.headerRect(ofCell: index)!.height <= cell.rect.height * 0.3)
            }
        }
        // Frames are capped in number, however deep the tree.
        var chain: [FileTree.Spec] = [.file("leaf-a", 500), .file("leaf-b", 400)]
        var total: UInt64 = 900
        for level in 0 ..< 14 {
            // A sibling half the size keeps each level from dominating its parent.
            chain = [.dir("level\(level)", chain), .file("beside\(level)", total / 2)]
            total += total / 2
        }
        let deep = TreemapLayout(
            tree: FileTree.make(chain), bounds: TreemapRect(x: 0, y: 0, width: 3000, height: 2400),
            options: TreemapLayoutOptions(style: .adaptive(scale: 1, maxLevels: 8)))
        #expect(deep.cells.contains { $0.depth > 8 && !$0.isLeaf })
        #expect(deep.cells.allSatisfy { !$0.isFramed || $0.depth <= 8 })
        #expect(deep.cells.contains { $0.depth == 8 && $0.hasHeader })
    }

    /// The cap and the per-level metrics count frames, not folders: a folder that got no frame
    /// (here: every other one, which fills its parent) does not use a level up, so big folders
    /// far down a deep path are still named.
    @Test func unframedFoldersDoNotUseUpFrameLevels() {
        var chain: [FileTree.Spec] = [.file("leaf-a", 500), .file("leaf-b", 400)]
        var total: UInt64 = 900
        for level in 0 ..< 12 {
            if level % 2 == 0 {
                chain = [.dir("only\(level)", chain)]  // fills its parent: merged into its title
            } else {
                chain = [.dir("level\(level)", chain), .file("beside\(level)", total / 2)]
                total += total / 2
            }
        }
        let tree = FileTree.make(chain)
        let layout = TreemapLayout(
            tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 3000, height: 2400),
            options: TreemapLayoutOptions(style: .adaptive(scale: 1, maxLevels: 8)))
        // Every cell knows how many frames surround it.
        for cell in layout.cells where cell.parent >= 0 {
            let parent = layout.cells[Int(cell.parent)]
            #expect(Int(cell.frameLevel) == Int(parent.frameLevel) + (parent.isFramed ? 1 : 0))
        }
        let framed = layout.cells.filter(\.isFramed)
        #expect(framed.allSatisfy { $0.frameLevel < 8 })
        // Twelve folder levels, six of them framed — the deepest at depth 11, far past 8.
        #expect(framed.map { Int($0.depth) }.max() == 11)
        #expect(framed.count == 6)
        // A frame's title names the folders merged into it.
        let outer = layout.cells.firstIndex { $0.isFramed && $0.frameLevel == 0 }!
        #expect(layout.titleChain(ofCell: outer).map { tree.name(of: $0) } == ["level11", "only10"])
    }

    @Test func siblingsStayProportionalInsideNestedFrames() {
        let tree = Self.nestedTree()
        let layout = TreemapLayout(
            tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 1600, height: 1200),
            options: TreemapLayoutOptions(style: .adaptive(scale: 2)))
        // Inside every frame the children share the content in proportion to their sizes.
        for (index, cell) in layout.cells.enumerated() where !cell.isLeaf {
            let content = layout.contentRect(ofCell: index)
            let scale = Double(content.area) / Double(tree.size(of: cell.node))
            for child in cell.children where !layout.cells[child].isAggregate {
                let expected = Double(tree.size(of: layout.cells[child].node)) * scale
                #expect(abs(Double(layout.cells[child].rect.area) - expected) <= max(1, expected * 0.01))
            }
        }
        // Chrome does not eat the map: the tiles keep most of it even with five nested frames.
        let tiles = layout.cells.reduce(Float(0)) { $0 + ($1.isLeaf ? $1.rect.area : 0) }
        #expect(tiles >= layout.bounds.area * 0.8)
    }

    // MARK: Depth limit

    @Test(arguments: [1, 2, 3]) func depthLimitCollapsesFoldersIntoSingleTiles(depth: Int) {
        let tree = testTree()
        let bounds = TreemapRect(x: 0, y: 0, width: 1600, height: 1200)
        let layout = TreemapLayout(
            tree: tree, bounds: bounds, options: TreemapLayoutOptions(style: .adaptive(scale: 2), maxDepth: depth))
        #expect(layout.cells.allSatisfy { Int($0.depth) <= depth })
        var collapsed = 0
        for (index, cell) in layout.cells.enumerated() {
            if cell.isCollapsed {
                collapsed += 1
                #expect(cell.isLeaf && cell.isDirectory && !cell.isAggregate && !cell.isFramed)
                #expect(Int(cell.depth) == depth)
                #expect(tree.childCount(of: cell.node) > 0)
                // Hit-testing and locating treat the block as the folder and everything in it.
                let centre = TreemapPoint(x: cell.rect.midX, y: cell.rect.midY)
                if cell.rect.width >= 2, cell.rect.height >= 2 {
                    #expect(layout.hitTest(centre) == index)
                    #expect(layout.node(at: centre) == cell.node)
                }
                #expect(layout.locate(cell.node) == TreemapLocation(cell: index, isExact: true))
                let inside = tree.child(of: cell.node, at: 0)
                #expect(layout.locate(inside) == TreemapLocation(cell: index, isExact: false))
            } else if cell.isLeaf, cell.isDirectory, !cell.isAggregate, Int(cell.depth) == depth {
                // Only an empty folder at the limit is not "collapsed".
                #expect(tree.childCount(of: cell.node) == 0 || tree.size(of: cell.node) == 0)
            }
        }
        #expect(collapsed > 0)
        // Without a limit nothing is collapsed, and the limit is relative to the layout root.
        #expect(!TreemapLayout(tree: tree, bounds: bounds).cells.contains { $0.isCollapsed })
        let folder = tree.children(of: 0).first { tree.isDirectory($0) && tree.childCount(of: $0) > 3 }!
        let zoomed = layout.relayout(root: folder)
        #expect(zoomed.cells.allSatisfy { Int($0.depth) <= depth })
        #expect(zoomed.cells.contains { $0.isCollapsed } || !tree.children(of: folder).contains { tree.isDirectory($0) })
        // At level 1 the map is exactly the root's children.
        if depth == 1 {
            #expect(layout.cells.dropFirst().allSatisfy { $0.isLeaf && $0.parent == 0 })
            #expect(!layout.cells[0].isFramed)
        }
    }

    @Test func collapsedFoldersTakeTheColourOfMostOfTheirContents() {
        // One big video, but far more bytes of source code in many files.
        let code: [FileTree.Spec] = (0 ..< 20).map { .file("file\($0).swift", 1000) }
        let tree = FileTree.make([
            .dir("Project", [.file("demo.mp4", 30000), .dir("Sources", code), .dir("Tests", code), .file("notes.swift", 500)]),
            .dir("Media", [.file("a.mp4", 5000), .file("b.swift", 100)]),
        ])
        var options = TreemapLayoutOptions(maxDepth: 1)
        let largest = TreemapLayout(tree: tree, bounds: testBounds, options: options)
        options.collapsedSample = .dominantKind
        let dominant = TreemapLayout(tree: tree, bounds: testBounds, options: options)
        let project = tree.node(atPath: "/Synthetic/Project")!
        let media = tree.node(atPath: "/Synthetic/Media")!
        func sample(_ layout: TreemapLayout, _ node: NodeID) -> String { tree.name(of: layout.cells[layout.cell(for: node)!].sample) }
        #expect(sample(largest, project) == "demo.mp4")
        #expect(sample(dominant, project).hasSuffix(".swift"))
        #expect(sample(dominant, media) == "a.mp4")
        // The sample is always a file inside the folder, and geometry is unaffected.
        for (a, b) in zip(largest.cells, dominant.cells) {
            #expect(a.rect == b.rect && a.flags == b.flags)
            if b.isCollapsed { #expect(!tree.isDirectory(b.sample) && tree.isAncestor(b.node, of: b.sample)) }
        }
        // Age: most bytes are old, the single largest file is new.
        let now = FileTree.syntheticReferenceTime
        options.collapsedSample = .dominantAge(now: now)
        let aged = TreemapLayout(tree: tree, bounds: testBounds, options: options)
        #expect(aged.cells.filter(\.isCollapsed).allSatisfy { tree.isAncestor($0.node, of: $0.sample) })
    }

    /// A folder that holds most of the tree is walked in pieces on several cores; the answer
    /// must be the one a single walk gives, and a cache must not change it either.
    @Test func splitAndCachedColourWalksAgreeWithTheSerialOne() {
        var tree = FileTree.make([.dir("Everything", [.file("placeholder", 1)]), .file("beside", 4096)])
        tree.replaceSubtree(at: tree.child(of: 0, named: "Everything")!, with: FileTree.synthetic(nodeCount: 400_000, seed: 7))
        let now = FileTree.syntheticReferenceTime
        for mode in [TreemapLayoutOptions.CollapsedSample.dominantKind, .dominantAge(now: now)] {
            for depth in [1, 2, 3] {
                var options = TreemapLayoutOptions(style: .adaptive(scale: 2), maxDepth: depth)
                options.collapsedSample = mode
                let bounds = TreemapRect(x: 0, y: 0, width: 1600, height: 1200)
                let serial = TreemapLayout(tree: tree, root: 0, bounds: bounds, options: options, allowParallel: false)
                let parallel = TreemapLayout(tree: tree, bounds: bounds, options: options)
                let cache = CollapsedSampleCache()
                cache.use(generation: 1)
                let first = TreemapLayout(tree: tree, bounds: bounds, options: options, sampleCache: cache)
                let second = TreemapLayout(tree: tree, bounds: bounds, options: options, sampleCache: cache)
                // Another size finds most folders in the cache and walks only the new ones.
                let resized = TreemapLayout(
                    tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 1200, height: 900), options: options, sampleCache: cache)
                let reference = TreemapLayout(tree: tree, bounds: resized.bounds, options: options)
                #expect(serial.cells.contains { $0.isCollapsed })
                // Cell order differs between the serial and the parallel layout; compare by node.
                func samples(_ layout: TreemapLayout) -> [NodeID: NodeID] {
                    var result: [NodeID: NodeID] = [:]
                    for cell in layout.cells where cell.isCollapsed { result[cell.node] = cell.sample }
                    return result
                }
                #expect(samples(serial) == samples(parallel))
                #expect(samples(first) == samples(parallel) && samples(second) == samples(parallel))
                #expect(samples(resized) == samples(reference))
                // A new generation forgets: the cache must never answer for another tree.
                cache.use(generation: 2)
                #expect(samples(TreemapLayout(tree: tree, bounds: bounds, options: options, sampleCache: cache)) == samples(parallel))
            }
        }
    }

    /// A depth-limited map exists to name folders, so narrow blocks are labelled too (the view
    /// shortens or wraps the name) — down to a width where nothing readable fits.
    @Test func narrowCollapsedFoldersStillGetALabel() {
        // Twelve equal folders in a 480×200 pt strip at 2x: blocks of roughly 40–80 pt.
        let tree = FileTree.make((0 ..< 12).map { .dir("repository-\($0)", [.file("a.bin", 1000), .file("b.bin", 900)]) })
        let layout = TreemapLayout(
            tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 960, height: 400),
            options: TreemapLayoutOptions(style: .adaptive(scale: 2), maxDepth: 1))
        var options = TreemapLabelOptions(scale: 2)
        options.minTileWidth = 54
        let labels = layout.labels(options)
        let blocks = layout.cells.indices.filter { layout.cells[$0].isCollapsed }
        #expect(blocks.count == 12)
        for index in blocks {
            let rect = layout.cells[index].rect
            let label = labels.first { $0.cell == index }
            if rect.width >= options.minFolderWidth * 2, rect.height >= 40 {
                #expect(label?.kind == .folder, "a \(rect.width / 2) pt wide block should be named")
            }
            if let label {
                #expect(label.rect.minX >= rect.minX && label.rect.maxX <= rect.maxX)
                #expect(label.rect.minY >= rect.minY && label.rect.maxY <= rect.maxY)
                #expect(label.fontSize >= options.minFontSize * 2)
            }
        }
        // Some of these blocks are narrower than a file tile would need for a label.
        let narrow = blocks.filter { layout.cells[$0].rect.width < 54 * 2 }
        #expect(narrow.isEmpty || narrow.contains { index in labels.contains { $0.cell == index } })
        // Below the minimum there is no label at all.
        let tiny = TreemapLayout(
            tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 300, height: 400),
            options: TreemapLayoutOptions(style: .adaptive(scale: 2), maxDepth: 1))
        for label in tiny.labels(options) { #expect(tiny.cells[label.cell].rect.width >= options.minFolderWidth * 2) }
    }

    @Test func cushionSurfaceMatchesTheRidgeFormula() {
        let tree = FileTree.make([.file("only", 1000)])
        let options = TreemapLayoutOptions(cushionHeight: 0.5, tileHeight: 0)
        let layout = TreemapLayout(tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 200, height: 100), options: options)
        let cell = layout.cells[1]
        // One ridge of height 0.5: slope +2 at the left/top edge, 0 in the middle, -2 at the far edge.
        #expect(abs(cell.surface.slope(at: TreemapPoint(x: 0, y: 0)).dx - 2) < 1e-4)
        #expect(abs(cell.surface.slope(at: TreemapPoint(x: 100, y: 50)).dx) < 1e-4)
        #expect(abs(cell.surface.slope(at: TreemapPoint(x: 100, y: 50)).dy) < 1e-4)
        #expect(abs(cell.surface.slope(at: TreemapPoint(x: 200, y: 100)).dy + 2) < 1e-4)
        #expect(layout.cells[0].surface == .flat)

        // The tile-height floor lifts deep tiles that the falloff would flatten.
        let deep = FileTree.make([.dir("a", [.dir("b", [.dir("c", [.dir("d", [.file("f", 10), .file("g", 10)])])])])])
        let flat = TreemapLayout(tree: deep, bounds: testBounds, options: TreemapLayoutOptions(cushionFalloff: 0.1, tileHeight: 0))
        let lifted = TreemapLayout(tree: deep, bounds: testBounds, options: TreemapLayoutOptions(cushionFalloff: 0.1, tileHeight: 0.3))
        #expect(abs(lifted.cells.last!.surface.ax) > abs(flat.cells.last!.surface.ax) * 1.2)
    }
}
