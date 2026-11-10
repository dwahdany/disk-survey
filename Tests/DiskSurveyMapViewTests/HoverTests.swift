import AppKit
import Testing
import DiskSurveyCore
import DiskSurveyTreemap

@testable import DiskSurveyMapView

extension LiveViewTests {
@MainActor @Suite struct HoverTests {
    private let rest = TreemapView.tooltipDelay + 0.3

    @Test func aNewPictureDoesNotBringTheTooltipBackWithoutMouseMovement() async throws {
        let map = await MapFixture(inWindow: true)
        let view = map.view
        let (point, _) = try #require(map.deepPoint(minDepth: 2))

        map.move(to: point)
        #expect(!view.isTooltipVisible)
        await pump(for: rest)
        #expect(view.isTooltipVisible)

        // Resize: hidden at once, and still hidden after the sharp picture has arrived.
        view.setFrameSize(CGSize(width: 900, height: 640))
        #expect(!view.isTooltipVisible)
        #expect(await map.awaitNewFrame())
        await pump(for: rest + 0.3)
        #expect(!view.isTooltipVisible)
        // The hover itself is still derived for the new picture.
        #expect(view.hoveredCell != nil)

        // The pointer coming to rest again brings it back.
        map.move(to: NSPoint(x: point.x + 1, y: point.y))
        await pump(for: rest)
        #expect(view.isTooltipVisible)

        // Keyboard zoom with the pointer parked.
        let folder = try #require(map.tree.children(of: 0).first { map.tree.isDirectory($0) && map.tree.childCount(of: $0) > 0 })
        view.rootNode = folder
        #expect(!view.isTooltipVisible)
        #expect(await map.awaitNewFrame())
        await pump(for: rest + 0.3)
        #expect(!view.isTooltipVisible)
    }

    @Test func aVisibleTooltipSurvivesARecolour() async throws {
        let map = await MapFixture(inWindow: true)
        let (point, _) = try #require(map.deepPoint(minDepth: 2))
        map.move(to: point)
        await pump(for: rest)
        #expect(map.view.isTooltipVisible)
        map.view.colorMode = .age
        #expect(await map.awaitNewFrame())
        #expect(map.view.isTooltipVisible)
        await pump(for: 0.2)
        #expect(map.view.isTooltipVisible)
    }

    @Test func aScanSnapshotKeepsHoverOutlineAndTooltip() async throws {
        let map = await MapFixture(inWindow: true) { $0.isScanning = true }
        let view = map.view
        let delegate = RecordingDelegate()
        view.delegate = delegate
        let (point, node) = try #require(map.deepPoint(minDepth: 2))
        view.selection = [node]
        map.move(to: point)
        await pump(for: rest)
        #expect(view.isTooltipVisible)
        #expect(delegate.hovers.count == 1)
        #expect(!view.selectionOutlineIsEmpty)

        for seed in [8, 9] as [UInt64] {
            let before = delegate.hovers.count
            // A snapshot: a fresh tree at revision 0 whose ids are unrelated to the old one.
            let next = FileTree.synthetic(nodeCount: 20_000, seed: seed)
            view.setTree(next, nodeIDsStable: false)
            view.selection = [1]  // the owner re-maps its selection right after the swap

            // Nothing blinks while the old picture is still up…
            #expect(view.interactiveFrame == nil)
            #expect(view.isTooltipVisible)
            #expect(view.hoveredCell != nil)
            #expect(!view.hoverOutlineIsEmpty)
            #expect(!view.selectionOutlineIsEmpty)
            // …a mouse move in the gap does not blank it either, and tells the delegate nothing
            // (there is no id of the new tree to report yet)…
            map.move(to: NSPoint(x: point.x + 0.5, y: point.y))
            #expect(view.isTooltipVisible)
            #expect(delegate.hovers.count == before)
            // …and no id of the old tree is handed out.
            #expect(view.node(at: point) == nil)

            #expect(await pump { view.interactiveFrame != nil })
            // The new picture took over without the tooltip going away.
            #expect(view.isTooltipVisible)
            // Exactly one report, with an id of the new tree, and no "nothing hovered" in between.
            #expect(delegate.hovers.count == before + 1)
            let hover = try #require(delegate.hovers.last ?? nil)
            #expect(Int(hover.node) < next.count)
            #expect(view.node(at: point) == hover.node || hover.isAggregate)
        }

        // Taking the tree away still clears everything, and says so.
        view.setTree(nil)
        #expect(view.hoveredCell == nil)
        #expect(!view.isTooltipVisible)
        #expect(view.hoverOutlineIsEmpty)
        #expect(view.selectionOutlineIsEmpty)
        #expect(delegate.hovers.last! == nil)
    }

    @Test func aPendingTooltipIsNotStarvedBySnapshots() async throws {
        let map = await MapFixture { $0.isScanning = true }
        let (point, _) = try #require(map.deepPoint(minDepth: 2))
        map.move(to: point)
        // Swap before the rest delay is over: the tooltip must still appear on time.
        await pump(for: 0.1)
        map.view.setTree(FileTree.synthetic(nodeCount: 20_000, seed: 8), nodeIDsStable: false)
        await pump(for: rest)
        #expect(map.view.isTooltipVisible)
    }

    @Test func leavingTheMapDuringTheGapReportsNoHover() async throws {
        let map = await MapFixture { $0.isScanning = true }
        let delegate = RecordingDelegate()
        map.view.delegate = delegate
        let (point, _) = try #require(map.deepPoint(minDepth: 2))
        map.move(to: point)
        #expect(delegate.hovers.count == 1)
        map.view.setTree(FileTree.synthetic(nodeCount: 20_000, seed: 8), nodeIDsStable: false)
        map.view.mouseExited(with: map.mouse(.mouseMoved, at: NSPoint(x: -5, y: -5), clickCount: 0))
        #expect(delegate.hovers.count == 2)
        #expect(delegate.hovers.last! == nil)
        #expect(await pump { map.view.interactiveFrame != nil })
        #expect(delegate.hovers.count == 2)
    }

    // MARK: Placeholder

    @Test func thePlaceholderFollowsTheBackingScale() async throws {
        let view = TreemapView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.backingScaleOverride = 2
        view.viewDidChangeBackingProperties()
        await pump(for: 0.05)
        #expect(view.placeholderContentsScale == 2)
        #expect(try #require(view.placeholderImage).width == Int(PlaceholderPainter.size.width) * 2)

        // The window moved to a 1x display; the placeholder state itself did not change.
        view.backingScaleOverride = 1
        view.viewDidChangeBackingProperties()
        #expect(view.placeholderContentsScale == 1)
        #expect(try #require(view.placeholderImage).width == Int(PlaceholderPainter.size.width))
    }
}
}
