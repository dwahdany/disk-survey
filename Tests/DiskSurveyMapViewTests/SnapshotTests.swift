import AppKit
import Testing
import DiskSurveyCore
import DiskSurveyMapView
import DiskSurveyTreemap

/// The view's offscreen pipeline (layout, raster, labels, overlays) is the same code the live
/// view runs, so rendering through it catches crashes and blank output without a window.
@Suite struct SnapshotTests {
    private func bitmap(_ data: Data) throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(data: data))
    }

    /// Number of clearly different colours on a coarse grid: a real map has many.
    private func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 4, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 40)) {
            for x in stride(from: 4, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 40)) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = UInt32(color.redComponent * 15), g = UInt32(color.greenComponent * 15), b = UInt32(color.blueComponent * 15)
                seen.insert(r << 8 | g << 4 | b)
            }
        }
        return seen.count
    }

    @Test(arguments: TreemapMapStyle.allCases)
    func rendersEveryStyleAtTheRequestedPixelSize(style: TreemapMapStyle) throws {
        let tree = FileTree.synthetic(nodeCount: 20_000, seed: 7)
        let data = TreemapView.renderSnapshotPNG(tree: tree, size: CGSize(width: 400, height: 300), scale: 2, style: style)
        let rep = try bitmap(data)
        #expect(rep.pixelsWide == 800)
        #expect(rep.pixelsHigh == 600)
        #expect(distinctColors(rep) > 12)
    }

    @Test func lightAndDarkAppearancesDiffer() throws {
        let tree = FileTree.synthetic(nodeCount: 5_000, seed: 3)
        let size = CGSize(width: 320, height: 240)
        let light = TreemapView.renderSnapshotPNG(tree: tree, size: size, scale: 1, appearance: NSAppearance(named: .aqua))
        let dark = TreemapView.renderSnapshotPNG(tree: tree, size: size, scale: 1, appearance: NSAppearance(named: .darkAqua))
        #expect(light != dark)
        #expect(distinctColors(try bitmap(dark)) > 12)
    }

    @Test func colourModesZoomSelectionAndHighlightAllRender() throws {
        let tree = FileTree.synthetic(nodeCount: 20_000, seed: 11)
        let size = CGSize(width: 320, height: 240)
        let folder = try #require(tree.children(of: tree.root).first { tree.isDirectory($0) && tree.childCount(of: $0) > 0 })
        let plain = TreemapView.renderSnapshotPNG(tree: tree, size: size, scale: 1)
        let byAge = TreemapView.renderSnapshotPNG(tree: tree, size: size, scale: 1, colorMode: .age, ageReferenceTime: FileTree.syntheticReferenceTime)
        let zoomed = TreemapView.renderSnapshotPNG(tree: tree, size: size, scale: 1, root: folder)
        let selected = TreemapView.renderSnapshotPNG(tree: tree, size: size, scale: 1, selection: [folder])
        let matches = tree.search("a", limit: 10).matches
        let dimmed = TreemapView.renderSnapshotPNG(tree: tree, size: size, scale: 1, highlight: .matches(matches))
        for variant in [byAge, zoomed, selected, dimmed] {
            #expect(variant != plain)
            #expect(try bitmap(variant).pixelsWide == 320)
        }
    }

    @Test func emptyAndMissingTreesProduceAPlaceholderInsteadOfCrashing() throws {
        let size = CGSize(width: 200, height: 120)
        #expect(try bitmap(TreemapView.renderSnapshotPNG(tree: nil, size: size, scale: 1)).pixelsWide == 200)
        #expect(try bitmap(TreemapView.renderSnapshotPNG(tree: .empty(rootPath: "/Nothing"), size: size, scale: 1)).pixelsWide == 200)
        #expect(try bitmap(TreemapView.renderSnapshotPNG(tree: nil, size: size, scale: 1, isScanning: true)).pixelsHigh == 120)
    }
}
