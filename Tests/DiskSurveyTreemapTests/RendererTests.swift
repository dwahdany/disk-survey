import Foundation
import Testing
import DiskSurveyCore
@testable import DiskSurveyTreemap

/// Flat, unshaded rendering: every tile shows exactly its base colour.
func flatOptions() -> TreemapRenderOptions {
    var options = TreemapRenderOptions()
    options.ambient = 1
    options.diffuse = 0
    options.relief = 0
    options.separator = 0
    options.bevel = 0
    options.dither = false
    return options
}

/// A distinct, stable colour per node.
let colorByNode = TreemapColoring.custom { node, _ in
    let h = UInt32(node) &* 2_654_435_761
    return RGB(
        r: Double(40 + (h & 0x7F)) / 255, g: Double(40 + ((h >> 8) & 0x7F)) / 255, b: Double(40 + ((h >> 16) & 0x7F)) / 255)
}

func sameBitmap(_ a: TreemapBitmap, _ b: TreemapBitmap) -> Bool {
    a.width == b.width && a.height == b.height && memcmp(a.pixels, b.pixels, a.byteCount) == 0
}

@Suite struct Rasterizer {
    @Test(arguments: allStyles.indices) func everyPixelIsWritten(styleIndex: Int) {
        let tree = testTree()
        for (w, h) in [(800, 600), (801, 599), (317, 211), (64, 48), (3, 2)] {
            let layout = TreemapLayout(
                tree: tree, bounds: TreemapRect(x: 0, y: 0, width: Float(w), height: Float(h)),
                options: TreemapLayoutOptions(style: allStyles[styleIndex].style))
            let bitmap = TreemapBitmap(width: w, height: h)  // zero-filled: alpha 0 everywhere
            TreemapRenderer.render(layout, coloring: .byKind(tree), into: bitmap)
            var unwritten = 0
            for i in 0 ..< bitmap.pixelCount where bitmap.pixels[i] >> 24 != 255 { unwritten += 1 }
            #expect(unwritten == 0, "\(unwritten) pixels untouched at \(w)×\(h)")
        }
    }

    @Test func fractionalAndOffsetBoundsAreFilledToo() {
        let tree = testTree()
        let layout = TreemapLayout(tree: tree, bounds: TreemapRect(x: 20.3, y: 10.7, width: 300.4, height: 200.2))
        let bitmap = TreemapBitmap(width: 400, height: 260)
        var options = TreemapRenderOptions()
        options.backgroundColor = RGB(r: 1, g: 0, b: 0)
        TreemapRenderer.render(layout, coloring: .byKind(tree), options: options, into: bitmap)
        for i in 0 ..< bitmap.pixelCount { #expect(bitmap.pixels[i] >> 24 == 255) }
        // Outside the bounds: the background colour.
        #expect(bitmap[5, 5] == 0xFFFF_0000)
        #expect(bitmap[399, 259] == 0xFFFF_0000)
        #expect(bitmap[200, 100] != 0xFFFF_0000)
    }

    @Test func renderingIsDeterministicAndThreadCountIndependent() {
        let tree = testTree()
        for (_, style) in allStyles {
            let layout = TreemapLayout(tree: tree, bounds: testBounds, options: TreemapLayoutOptions(style: style))
            let a = TreemapRenderer.render(layout, coloring: .byKind(tree))
            let b = TreemapRenderer.render(layout, coloring: .byKind(tree))
            var options = TreemapRenderOptions()
            options.maxThreads = 1
            let single = TreemapRenderer.render(layout, coloring: .byKind(tree), options: options)
            options.maxThreads = 3
            let three = TreemapRenderer.render(layout, coloring: .byKind(tree), options: options)
            #expect(sameBitmap(a, b))
            #expect(sameBitmap(a, single))
            #expect(sameBitmap(a, three))
        }
    }

    @Test func bigTilesSplitIntoBandsSeamlessly() {
        // One huge tile is painted in several row bands by different threads; the result must
        // equal the single-threaded picture.
        let tree = FileTree.make([.file("huge.mov", 1_000_000), .file("small.txt", 1000)])
        let layout = TreemapLayout(tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 1200, height: 900))
        var options = TreemapRenderOptions()
        let parallel = TreemapRenderer.render(layout, coloring: .byKind(tree), options: options)
        options.maxThreads = 1
        #expect(sameBitmap(parallel, TreemapRenderer.render(layout, coloring: .byKind(tree), options: options)))
    }

    @Test func pixelsShowTheTileTheyHitTest() {
        let tree = testTree()
        let layout = TreemapLayout(tree: tree, bounds: testBounds)
        let bitmap = TreemapRenderer.render(layout, coloring: colorByNode, options: flatOptions())
        var rng = SplitMix64(seed: 17)
        var mismatches = 0
        for _ in 0 ..< 20_000 {
            let x = Int.random(in: 0 ..< 800, using: &rng)
            let y = Int.random(in: 0 ..< 600, using: &rng)
            let cell = layout.cells[layout.hitTest(TreemapPoint(x: Float(x) + 0.5, y: Float(y) + 0.5))!]
            guard case .custom(let color) = colorByNode.storage else { return }
            let expected = color(cell.sample, tree).bytes
            let actual = bitmap.color(x: x, y: y)
            // Encoding goes through a 12-bit table: allow one level of rounding.
            let close =
                abs(Int(actual.r) - Int(expected.r)) <= 1 && abs(Int(actual.g) - Int(expected.g)) <= 1
                && abs(Int(actual.b) - Int(expected.b)) <= 1
            if !close { mismatches += 1 }
        }
        // Only pixel centres lying exactly on a cell edge may be attributed differently.
        #expect(mismatches <= 20, "\(mismatches) of 20000 sampled pixels show the wrong tile")
    }

    @Test func flatShadingReproducesTheBaseColour() {
        let tree = FileTree.make([.file("one.bin", 1000)])
        let layout = TreemapLayout(tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 64, height: 64))
        for color in [RGB(r: 0.2, g: 0.5, b: 0.8), RGB(r: 1, g: 1, b: 1), RGB(r: 0, g: 0, b: 0), RGB(r: 0.5, g: 0.5, b: 0.5)] {
            let bitmap = TreemapRenderer.render(layout, coloring: .uniform(color), options: flatOptions())
            let expected = color.bytes
            for (x, y) in [(0, 0), (31, 31), (63, 63), (10, 50)] {
                let p = bitmap.color(x: x, y: y)
                #expect(abs(Int(p.r) - Int(expected.r)) <= 1 && abs(Int(p.g) - Int(expected.g)) <= 1 && abs(Int(p.b) - Int(expected.b)) <= 1)
                #expect(p.a == 255)
            }
        }
    }

    @Test func cushionIsLitFromTheTopLeft() {
        let tree = FileTree.make([.file("one.bin", 1000)])
        let layout = TreemapLayout(tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 200, height: 200))
        var options = TreemapRenderOptions()
        options.separator = 0
        options.bevel = 0
        let bitmap = TreemapRenderer.render(layout, coloring: .uniform(RGB(r: 0.5, g: 0.5, b: 0.5)), options: options)
        // The highlight sits up and to the left of the centre, where the surface faces the light.
        let highlight = Int(bitmap.color(x: 80, y: 72).g)
        let centre = Int(bitmap.color(x: 100, y: 100).g)
        let bottomRight = Int(bitmap.color(x: 180, y: 180).g)
        #expect(highlight > centre && centre > bottomRight)
        #expect(Int(bitmap.color(x: 4, y: 4).g) > Int(bitmap.color(x: 195, y: 195).g))
        #expect(Int(bitmap.color(x: 100, y: 4).g) > Int(bitmap.color(x: 100, y: 195).g))
        #expect(Int(bitmap.color(x: 4, y: 100).g) > Int(bitmap.color(x: 195, y: 100).g))
        // Soft, not harsh: the darkest corner keeps well over a third of the peak brightness.
        #expect(Int(bitmap.color(x: 199, y: 199).g) > highlight * 4 / 10)
        // The shading is smooth: neighbouring pixels differ by at most a couple of levels.
        for x in 1 ..< 200 {
            #expect(abs(Int(bitmap.color(x: x, y: 100).g) - Int(bitmap.color(x: x - 1, y: 100).g)) <= 2)
        }
        // Relief 0 is flat.
        options.relief = 0
        options.dither = false
        let flat = TreemapRenderer.render(layout, coloring: .uniform(RGB(r: 0.5, g: 0.5, b: 0.5)), options: options)
        #expect(flat[10, 10] == flat[190, 190])
    }

    @Test func separatorsAndBevelMarkTileEdges() {
        let tree = FileTree.make([.file("one.bin", 1000)])
        let layout = TreemapLayout(tree: tree, bounds: TreemapRect(x: 0, y: 0, width: 100, height: 100))
        var options = flatOptions()
        options.ambient = 0.8
        options.separator = 0.4
        options.bevel = 0.1
        let bitmap = TreemapRenderer.render(layout, coloring: .uniform(RGB(r: 0.5, g: 0.5, b: 0.5)), options: options)
        let inner = Int(bitmap.color(x: 50, y: 50).g)
        #expect(Int(bitmap.color(x: 99, y: 50).g) < inner)  // right edge darker
        #expect(Int(bitmap.color(x: 50, y: 99).g) < inner)  // bottom edge darker
        #expect(Int(bitmap.color(x: 0, y: 50).g) > inner)  // left edge lighter
        #expect(Int(bitmap.color(x: 50, y: 0).g) > inner)  // top edge lighter
        #expect(Int(bitmap.color(x: 98, y: 50).g) == inner)  // exactly one pixel wide
        #expect(Int(bitmap.color(x: 1, y: 50).g) == inner)
    }

    @Test func highlightDimsEverythingElse() {
        let tree = FileTree.make([
            .dir("keep", [.file("a.mp4", 4000), .file("b.mp4", 4000)]),
            .dir("drop", [.file("c.zip", 4000), .file("d.zip", 4000)]),
        ])
        let layout = TreemapLayout(tree: tree, bounds: testBounds)
        let plain = TreemapRenderer.render(layout, coloring: .byKind(tree), options: flatOptions())
        var options = flatOptions()
        options.highlight = tree.containingMask(for: tree.matches(SearchQuery(text: ".mp4")))
        options.dimColor = RGB(r: 0.9, g: 0.9, b: 0.9)
        options.dimAmount = 1
        let dimmed = TreemapRenderer.render(layout, coloring: .byKind(tree), options: options)
        for name in ["a.mp4", "b.mp4", "c.zip", "d.zip"] {
            let node = tree.search(name).nodes[0]
            let rect = layout.rect(for: node)!
            let x = Int(rect.midX)
            let y = Int(rect.midY)
            if name.hasSuffix("mp4") {
                #expect(dimmed[x, y] == plain[x, y])
            } else {
                #expect(dimmed[x, y] != plain[x, y])
                let p = dimmed.color(x: x, y: y)
                #expect(abs(Int(p.r) - 230) <= 1 && abs(Int(p.g) - 230) <= 1 && abs(Int(p.b) - 230) <= 1)
            }
        }

        // A collapsed directory containing a match stays lit; an aggregate with a match too.
        var specs: [FileTree.Spec] = [.file("big.bin", 80_000_000)]
        for i in 0 ..< 3000 { specs.append(.file("note\(i).txt", 512)) }
        let mixed = FileTree.make([.dir("mixed", specs)])
        let mixedLayout = TreemapLayout(tree: mixed, bounds: testBounds)
        let aggregate = mixedLayout.cells.first { $0.isAggregate }!
        var mixedOptions = flatOptions()
        mixedOptions.dimAmount = 1
        mixedOptions.dimColor = RGB(r: 0, g: 0, b: 0)
        mixedOptions.highlight = mixed.containingMask(for: mixed.matches(SearchQuery(text: "note17.txt")))
        let lit = TreemapRenderer.render(mixedLayout, coloring: .byKind(mixed), options: mixedOptions)
        #expect(lit[Int(aggregate.rect.midX), Int(aggregate.rect.midY)] != 0xFF00_0000)
        mixedOptions.highlight = mixed.containingMask(for: mixed.matches(SearchQuery(text: "big.bin")))
        let unlit = TreemapRenderer.render(mixedLayout, coloring: .byKind(mixed), options: mixedOptions)
        #expect(unlit[Int(aggregate.rect.midX), Int(aggregate.rect.midY)] == 0xFF00_0000)
    }

    /// An aggregate tile is lit exactly when one of the items it merges is highlighted —
    /// wherever in the directory that item is, and in either size metric.
    @Test(arguments: [TreemapLayoutOptions.SizeMetric.allocated, .logical])
    func aggregateIsLitExactlyWhenItMergesAMatch(metric: TreemapLayoutOptions.SizeMetric) throws {
        var render = flatOptions()
        render.dimAmount = 1
        render.dimColor = RGB(r: 0, g: 0, b: 0)
        let coloring = TreemapColoring.uniform(RGB(r: 0.9, g: 0.2, b: 0.2))
        let black: UInt32 = 0xFF00_0000

        // Small: one task per tile. Large: the aggregate is painted in several row bands.
        for (items, bounds) in [(5000, TreemapRect(x: 0, y: 0, width: 100, height: 60)), (60_000, TreemapRect(x: 0, y: 0, width: 600, height: 500))] {
            var specs: [FileTree.Spec] = [.file("big.bin", 3_000_000), .file("empty.txt", 0)]
            for i in 0 ..< items { specs.append(.file("item\(i).dat", 1000)) }
            let tree = FileTree.make(specs)
            let children = tree.children(of: 0)
            let big = tree.search("big.bin").nodes[0]
            let empty = tree.search("empty.txt").nodes[0]
            #expect(children.first == big)

            let layout = TreemapLayout(tree: tree, bounds: bounds, options: TreemapLayoutOptions(sizeMetric: metric))
            let index = try #require(layout.cells.firstIndex { $0.isAggregate })
            let aggregate = layout.cells[index]
            #expect(aggregate.mergedCount == items + 1)
            #expect((aggregate.rect.area > 96_000) == (items > 5000))
            #expect(aggregate.rect.area > 0.6 * bounds.area)
            let bigRect = try #require(layout.rect(for: big))
            // Sample points: the aggregate's centre and its first and last rows, and big.bin.
            let r = aggregate.rect.pixelAligned
            let probes = [
                (Int(aggregate.rect.midX), Int(aggregate.rect.midY)), (Int(r.minX), Int(r.minY)), (Int(r.maxX) - 1, Int(r.maxY) - 1),
            ]
            let bigProbe = (Int(bigRect.midX), Int(bigRect.midY))
            let plain = TreemapRenderer.render(layout, coloring: coloring, options: render)
            #expect(plain[probes[0].0, probes[0].1] != black)

            func rendered(highlighting nodes: [NodeID], containing: Bool = true) -> TreemapBitmap {
                var matches = NodeBitset(capacity: tree.count)
                for node in nodes { matches.insert(node) }
                var options = render
                options.highlight = containing ? tree.containingMask(for: matches) : matches
                return TreemapRenderer.render(layout, coloring: coloring, options: options)
            }
            func isLit(_ bitmap: TreemapBitmap) -> Bool? {
                let lit = probes.map { bitmap[$0.0, $0.1] == plain[$0.0, $0.1] }
                let dim = probes.map { bitmap[$0.0, $0.1] == black }
                return lit.allSatisfy { $0 } ? true : (dim.allSatisfy { $0 } ? false : nil)
            }

            // Merged items anywhere in the directory, none of them the aggregate's sample.
            let merged = children.filter { $0 != big && $0 != empty && $0 != aggregate.sample }
            for needle in [merged[0], merged[1], merged[300], merged[4000], merged[merged.count - 1]] {
                #expect(layout.locate(needle) == TreemapLocation(cell: index, isExact: false))
                let bitmap = rendered(highlighting: [needle])
                #expect(isLit(bitmap) == true, "match at child position \(children.firstIndex(of: needle)! - children.startIndex)")
                #expect(bitmap[bigProbe.0, bigProbe.1] == black)
            }
            #expect(isLit(rendered(highlighting: [aggregate.sample])) == true)

            // Matches that are not in the aggregate leave it dimmed, although a containing mask
            // sets the directory's own bit for each of them.
            let onlyBig = rendered(highlighting: [big])
            #expect(isLit(onlyBig) == false)
            #expect(onlyBig[bigProbe.0, bigProbe.1] == plain[bigProbe.0, bigProbe.1])
            #expect(isLit(rendered(highlighting: [0])) == false)
            #expect(isLit(rendered(highlighting: [0], containing: false)) == false)
            // An item without size is nowhere on the map, the aggregate included.
            #expect(layout.locate(empty) == nil)
            #expect(isLit(rendered(highlighting: [empty])) == false)
            #expect(isLit(rendered(highlighting: [])) == false)
            // Several at once.
            #expect(isLit(rendered(highlighting: [big, empty, merged[2500]])) == true)
        }
    }

    @Test func coloringModes() {
        let now = FileTree.syntheticReferenceTime
        let tree = FileTree.make([
            .file("new.mp4", 4000, modified: now - 3600), .file("old.mp4", 4000, modified: now - 5 * 365 * 86_400),
        ])
        let layout = TreemapLayout(tree: tree, bounds: testBounds)
        let byKind = TreemapRenderer.render(layout, coloring: .byKind(tree), options: flatOptions())
        let byAge = TreemapRenderer.render(layout, coloring: .byAge(now: now), options: flatOptions())
        let a = layout.rect(for: tree.search("new.mp4").nodes[0])!
        let b = layout.rect(for: tree.search("old.mp4").nodes[0])!
        // Same kind, same colour; different age, different colour.
        #expect(byKind[Int(a.midX), Int(a.midY)] == byKind[Int(b.midX), Int(b.midY)])
        #expect(byAge[Int(a.midX), Int(a.midY)] != byAge[Int(b.midX), Int(b.midY)])
        let expected = KindPalette.color(forExtension: "mp4").bytes
        let actual = byKind.color(x: Int(a.midX), y: Int(a.midY))
        #expect(abs(Int(actual.r) - Int(expected.r)) <= 1 && abs(Int(actual.g) - Int(expected.g)) <= 1)
        let age = AgePalette.color(modified: now - 3600, now: now).bytes
        let shown = byAge.color(x: Int(a.midX), y: Int(a.midY))
        #expect(abs(Int(shown.r) - Int(age.r)) <= 1 && abs(Int(shown.b) - Int(age.b)) <= 1)
    }

    @Test func framesArePaintedInTheFrameColour() {
        let tree = FileTree.make([
            .dir("A", [.file("a1", 3000), .file("a2", 2000)]), .dir("B", [.file("b1", 4000), .file("b2", 1000)]),
        ])
        let layout = TreemapLayout(tree: tree, bounds: testBounds, options: TreemapLayoutOptions(style: .framed(scale: 2)))
        var options = flatOptions()
        options.frameColors = [RGB(r: 0, g: 1, b: 0)]
        options.frameBorderColor = nil
        let bitmap = TreemapRenderer.render(layout, coloring: .uniform(RGB(r: 1, g: 0, b: 0)), options: options)
        let a = layout.cell(for: tree.node(atPath: "/Synthetic/A")!)!
        let header = layout.headerRect(ofCell: a)!
        let content = layout.contentRect(ofCell: a)
        #expect(bitmap[Int(header.midX), Int(header.midY)] == 0xFF00_FF00)
        #expect(bitmap[Int(content.midX), Int(content.midY)] == 0xFFFF_0000)
        #expect(bitmap[Int(layout.cells[a].rect.minX), Int(content.midY)] == 0xFF00_FF00)  // left padding
        #expect(bitmap[Int(content.midX), Int(layout.cells[a].rect.maxY) - 1] == 0xFF00_FF00)  // bottom padding

        // With a border, the outermost pixel of every frame edge is the border colour and the
        // rest of the frame keeps its fill: neighbouring folders are visibly apart.
        options.frameBorderColor = RGB(r: 0, g: 0, b: 1)
        let bordered = TreemapRenderer.render(layout, coloring: .uniform(RGB(r: 1, g: 0, b: 0)), options: options)
        let rect = layout.cells[a].rect
        #expect(bordered[Int(rect.minX), Int(content.midY)] == 0xFF00_00FF)
        #expect(bordered[Int(rect.maxX) - 1, Int(content.midY)] == 0xFF00_00FF)
        #expect(bordered[Int(content.midX), Int(rect.minY)] == 0xFF00_00FF)
        #expect(bordered[Int(content.midX), Int(rect.maxY) - 1] == 0xFF00_00FF)
        #expect(bordered[Int(rect.minX) + 1, Int(content.midY)] == 0xFF00_FF00)
        #expect(bordered[Int(header.midX), Int(header.midY)] == 0xFF00_FF00)
        #expect(bordered[Int(content.midX), Int(content.midY)] == 0xFFFF_0000)
    }

    @Test func nestedFramesGetTheirLevelsTintAndCollapsedFoldersAreCalmer() {
        let tree = LayoutContent.nestedTree()
        let bounds = TreemapRect(x: 0, y: 0, width: 1600, height: 1200)
        let layout = TreemapLayout(tree: tree, bounds: bounds, options: TreemapLayoutOptions(style: .adaptive(scale: 2)))
        var options = flatOptions()
        options.frameBorderColor = nil
        options.frameColors = [RGB(r: 0, g: 1, b: 0), RGB(r: 0, g: 0, b: 1), RGB(r: 0, g: 1, b: 1)]
        let bitmap = TreemapRenderer.render(layout, coloring: .uniform(RGB(r: 1, g: 0, b: 0)), options: options)
        let expected: [UInt32] = [0xFF00_FF00, 0xFF00_00FF, 0xFF00_FFFF, 0xFF00_FFFF]
        for (depth, path) in ["Big", "Big/Mid", "Big/Mid/Deep", "Big/Mid/Deep/Deeper"].enumerated() {
            let header = layout.headerRect(ofCell: layout.cell(for: tree.node(atPath: "/Synthetic/" + path)!)!)!
            #expect(bitmap[Int(header.midX), Int(header.midY)] == expected[depth], "\(path)")
        }

        // A collapsed folder is shaded with less relief than the same tile would be as a file.
        let shallow = TreemapLayout(tree: tree, bounds: bounds, options: TreemapLayoutOptions(maxDepth: 1))
        let big = shallow.cells[shallow.cell(for: tree.node(atPath: "/Synthetic/Big")!)!]
        #expect(big.isCollapsed)
        func contrast(_ relief: Float) -> Int {
            var options = TreemapRenderOptions()
            options.separator = 0
            options.bevel = 0
            options.dither = false
            options.collapsedRelief = relief
            let picture = TreemapRenderer.render(shallow, coloring: .uniform(RGB(r: 0.5, g: 0.5, b: 0.5)), options: options)
            let centre = picture.color(x: Int(big.rect.midX), y: Int(big.rect.midY))
            let corner = picture.color(x: Int(big.rect.maxX) - 3, y: Int(big.rect.maxY) - 3)
            return Int(centre.g) - Int(corner.g)
        }
        #expect(contrast(1) > contrast(0.5) && contrast(0.5) > 0)
    }

    @Test func emptyMapIsBackground() {
        var options = TreemapRenderOptions()
        options.backgroundColor = RGB(r: 0, g: 0, b: 1)
        let layout = TreemapLayout(tree: FileTree.empty(), bounds: TreemapRect(x: 0, y: 0, width: 40, height: 30))
        let bitmap = TreemapRenderer.render(layout, coloring: .byKind(FileTree.empty()), options: options)
        #expect(bitmap.width == 40 && bitmap.height == 30)
        for i in 0 ..< bitmap.pixelCount { #expect(bitmap.pixels[i] == 0xFF00_00FF) }
        // Zero-sized bitmaps are a no-op.
        TreemapRenderer.render(layout, coloring: .byKind(FileTree.empty()), into: TreemapBitmap(width: 0, height: 0))
    }

    @Test func ditherTableIsAPermutation() {
        var seen = Set<Int>()
        for i in 0 ..< 64 { seen.insert(Int(ColorTables.bayer[i] * 64)) }
        #expect(seen.count == 64)
        // Each 2×2 block holds one value from each quarter of the range: evenly spread.
        for y in stride(from: 0, to: 8, by: 2) {
            for x in stride(from: 0, to: 8, by: 2) {
                let quarter = Set([(0, 0), (1, 0), (0, 1), (1, 1)].map { Int(ColorTables.bayer[(y + $0.1) * 8 + x + $0.0] * 4) })
                #expect(quarter.count == 4)
            }
        }
        // The encode table is monotonic and spans 0…255.
        #expect(ColorTables.encode[0] == 0 && abs(ColorTables.encode[4095] - 255) < 1e-3)
        for i in 1 ..< 4096 { #expect(ColorTables.encode[i] >= ColorTables.encode[i - 1]) }
        let packed = ColorTables.pixel(ColorTables.linear(RGB(r: 0.25, g: 0.5, b: 0.75)))
        #expect(packed >> 24 == 255)
        #expect(abs(Int((packed >> 16) & 255) - 64) <= 1 && abs(Int((packed >> 8) & 255) - 128) <= 1 && abs(Int(packed & 255) - 191) <= 1)
    }
}

@Suite struct Bitmap {
    @Test func formatAndDumps() throws {
        let bitmap = TreemapBitmap(width: 3, height: 2)
        #expect(bitmap.bytesPerRow == 12 && bitmap.byteCount == 24 && bitmap.pixelCount == 6)
        #expect(TreemapBitmap.cgBitmapInfo == 8194)  // premultipliedFirst | byteOrder32Little
        bitmap.fill(r: 10, g: 20, b: 30)
        // In memory: B, G, R, A.
        #expect(Array(bitmap.bytes.prefix(4)) == [30, 20, 10, 255])
        #expect(bitmap[2, 1] == 0xFF0A_141E)
        let c = bitmap.color(x: 0, y: 0)
        #expect(c.r == 10 && c.g == 20 && c.b == 30 && c.a == 255)
        bitmap.pixels[0] = 0xFFFF_0000  // top-left red

        let ppm = bitmap.ppmData()
        let header = Array("P6\n3 2\n255\n".utf8)
        #expect(Array(ppm.prefix(header.count)) == header)
        #expect(ppm.count == header.count + 18)
        #expect(Array(ppm[header.count ..< header.count + 6]) == [255, 0, 0, 10, 20, 30])

        let bmp = bitmap.bmpData()
        #expect(bmp[0] == 0x42 && bmp[1] == 0x4D)
        #expect(bmp.count == 54 + 2 * 12)  // rows padded to 4 bytes
        // Bottom-up: the top-left pixel is the first of the LAST stored row, as B, G, R.
        #expect(Array(bmp[54 + 12 ..< 54 + 15]) == [0, 0, 255])

        #expect(bitmap.data.count == 24)
        let shared = bitmap.unsafeData
        #expect(shared.count == 24 && shared[2] == 255)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("disksurvey-test-\(UUID().uuidString).bmp")
        try bitmap.writeBMP(to: url)
        #expect(try Data(contentsOf: url) == bmp)
        try FileManager.default.removeItem(at: url)
    }
}
