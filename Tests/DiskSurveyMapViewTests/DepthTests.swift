import AppKit
import Testing
import DiskSurveyCore
import DiskSurveyTreemap

@testable import DiskSurveyMapView

extension LiveViewTests {
/// The depth limit ("level of detail"), nested frames and the hover's folder chain in the live view.
@MainActor @Suite struct DepthTests {
    @Test func depthLimitShowsFoldersAsBlocksAndStaysRelativeToTheRoot() async throws {
        let map = await MapFixture(inWindow: true)
        let view = map.view
        let tree = map.tree
        #expect(view.maxDepth == nil)
        #expect(try #require(view.interactiveFrame).layout.cells.contains { $0.depth > 2 })

        view.maxDepth = 1
        #expect(await map.awaitNewFrame())
        var frame = try #require(view.interactiveFrame)
        #expect(frame.key.depth == 1)
        #expect(frame.layout.cells.dropFirst().allSatisfy { $0.isLeaf && $0.parent == 0 })
        let block = try #require(frame.layout.cells.indices.first { frame.layout.cells[$0].isCollapsed })
        let folder = frame.layout.cells[block].node
        #expect(tree.parent(of: folder) == 0)

        // The block is the folder for hit-testing, selection and hover.
        let rect = try #require(view.rect(for: folder))
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        #expect(view.node(at: centre) == folder)
        let delegate = RecordingDelegate()
        view.delegate = delegate
        map.click(at: centre)
        #expect(view.selection == [folder])
        #expect(!view.selectionOutlineIsEmpty)
        map.move(to: centre)
        #expect(delegate.hovers.last??.node == folder)
        #expect(delegate.hovers.last??.size == tree.size(of: folder))
        // An item inside it is found in the block.
        let inside = tree.child(of: folder, at: 0)
        #expect(view.rect(for: inside) == rect)
        view.delegate = nil

        // A double-click goes into the block, and the level of detail is the same there.
        map.click(at: centre, clickCount: 2)
        #expect(view.rootNode == folder)
        #expect(await map.awaitNewFrame())
        frame = try #require(view.interactiveFrame)
        #expect(frame.layout.root == folder && frame.key.depth == 1)
        #expect(frame.layout.cells.dropFirst().allSatisfy { $0.isLeaf && $0.parent == 0 })

        // Values below 1 mean 1; nil brings the files back.
        view.maxDepth = 0
        #expect(view.maxDepth == 1)
        view.rootNode = 0
        view.maxDepth = nil
        #expect(await map.awaitNewFrame())
        #expect(await pump { view.interactiveFrame?.layout.root == 0 && view.interactiveFrame?.key.depth == .max })
        #expect(try #require(view.interactiveFrame).layout.cells.contains { $0.depth > 2 })
    }

    @Test func deeperLevelsAddOneLevelOfBlocksEach() async throws {
        let map = await MapFixture()
        var tiles: [Int] = []
        for depth in [1, 2, 3] {
            map.view.maxDepth = depth
            #expect(await map.awaitNewFrame())
            let layout = try #require(map.view.interactiveFrame).layout
            #expect(layout.cells.allSatisfy { Int($0.depth) <= depth })
            #expect(layout.cells.contains { Int($0.depth) == depth && $0.isCollapsed })
            tiles.append(layout.leafCount)
        }
        #expect(tiles[0] < tiles[1] && tiles[1] < tiles[2])
    }

    @Test func doubleClickOnAFoldersTitleGoesStraightIntoIt() async throws {
        let map = await MapFixture(size: CGSize(width: 1400, height: 1000))
        let view = map.view
        let frame = try #require(view.interactiveFrame)
        let layout = frame.layout
        // A framed folder at least two levels down.
        let index = try #require(layout.cells.indices.first { layout.cells[$0].hasHeader && layout.cells[$0].depth >= 2 })
        let header = try #require(layout.headerRect(ofCell: index))
        let point = view.geometry(for: frame).viewRect(header)
        let centre = NSPoint(x: point.midX, y: point.midY)
        #expect(view.node(at: centre) == layout.cells[index].node)
        map.click(at: centre)
        map.click(at: centre, clickCount: 2)
        #expect(view.rootNode == layout.cells[index].node)
    }

    @Test func hoverOutlinesTheParentFolderAndItsAncestorsSeparately() async throws {
        let map = await MapFixture(size: CGSize(width: 1400, height: 1000), inWindow: true)
        let view = map.view
        let frame = try #require(view.interactiveFrame)
        let cells = frame.layout.cells
        // A tile whose parent and grandparent cells both lie below the root cell.
        let deep = try #require(cells.indices.first {
            cells[$0].isLeaf && !cells[$0].isAggregate && cells[$0].depth >= 3 && cells[$0].rect.width > 6 && cells[$0].rect.height > 6
        })
        let geometry = view.geometry(for: frame)
        let shapes = Overlay.hoverRects(frame: frame, cell: deep, geometry: geometry)
        #expect(shapes.chain.count == Int(cells[deep].depth) - 1)
        #expect(shapes.chain.first == geometry.viewRect(cells[Int(cells[deep].parent)].rect))
        // Innermost first: every folder contains the one before it.
        for (inner, outer) in zip(shapes.chain, shapes.chain.dropFirst()) {
            #expect(outer.insetBy(dx: -0.01, dy: -0.01).contains(inner))
        }

        #expect(view.hoverParentOutlineIsEmpty && view.hoverAncestorOutlineIsEmpty)
        #expect(view.showHover(for: cells[deep].node))
        #expect(!view.hoverOutlineIsEmpty && !view.hoverParentOutlineIsEmpty && !view.hoverAncestorOutlineIsEmpty)

        // The tooltip names the enclosing folders with their sizes, innermost last.
        let content = try #require(view.tooltipContent)
        let tree = map.tree
        var expected: [NodeID] = []
        var current = try #require(tree.parent(of: cells[deep].node))
        while current != 0 {
            expected.append(current)
            current = try #require(tree.parent(of: current))
        }
        let shown = Array(expected.prefix(TooltipContent.maxFolders).reversed())
        #expect(content.folders.map(\.name) == shown.map { tree.name(of: $0) })
        #expect(content.folders.map(\.size) == shown.map { Format.bytes(tree.size(of: $0)) })
        #expect(content.foldersElided == (expected.count > TooltipContent.maxFolders))
        #expect(content.folders.last?.name == tree.name(of: try #require(tree.parent(of: cells[deep].node))))

        // A top-level item has no folder chain, and its parent outline is empty.
        let top = try #require(cells[0].children.first { !cells[$0].isAggregate })
        #expect(view.showHover(for: cells[top].node))
        #expect(view.hoverParentOutlineIsEmpty)
        #expect(try #require(view.tooltipContent).folders.isEmpty)
        view.updateHover(at: nil)
        #expect(view.hoverOutlineIsEmpty && view.tooltipContent == nil)
    }

    @Test func snapshotsRenderEveryDepthAndCollapsedFoldersDifferFromFiles() throws {
        let tree = FileTree.synthetic(nodeCount: 20_000, seed: 7)
        let size = CGSize(width: 480, height: 320)
        var pictures: [Data] = []
        for depth in [1, 2, 3, nil] as [Int?] {
            let data = TreemapView.renderSnapshotPNG(tree: tree, size: size, scale: 1, maxDepth: depth)
            #expect(NSBitmapImageRep(data: data)?.pixelsWide == 480)
            pictures.append(data)
        }
        #expect(Set(pictures).count == 4)
        // Highlight and age colouring work on collapsed folders too.
        // One file's name: only the blocks that contain such a file stay lit.
        let file = tree.largestFiles(limit: 1)[0]
        let matches = tree.search(tree.name(of: file), limit: 10).matches
        let dimmed = TreemapView.renderSnapshotPNG(tree: tree, size: size, scale: 1, highlight: .matches(matches), maxDepth: 2)
        let aged = TreemapView.renderSnapshotPNG(
            tree: tree, size: size, scale: 1, colorMode: .age, ageReferenceTime: FileTree.syntheticReferenceTime, maxDepth: 1)
        #expect(dimmed != pictures[1])
        #expect(aged != pictures[0])
    }

    @Test func accessibilityChildrenDescribeCollapsedFolders() async throws {
        let map = await MapFixture(inWindow: true) { $0.maxDepth = 1 }
        let view = map.view
        let frame = try #require(view.interactiveFrame)
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(!children.isEmpty)
        let first = frame.layout.cells[frame.layout.cells[0].children.first!]
        #expect(first.isCollapsed)
        let label = try #require(children.first?.accessibilityLabel())
        #expect(label.hasPrefix(map.tree.name(of: first.node) + ", folder, "))
    }
}
}
