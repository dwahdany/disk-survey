import AppKit
import Testing
import DiskSurveyCore
import DiskSurveyTreemap

@testable import DiskSurveyMapView

extension LiveViewTests {
@MainActor @Suite struct EventTests {
    // MARK: Click counts and modifiers

    @Test func optionClicksWalkOutwardsWhateverTheirClickCount() async throws {
        let map = await MapFixture()
        let (point, node) = try #require(map.deepPoint(minDepth: 5))
        let tree = map.tree
        let parent = try #require(tree.parent(of: node))
        let grandparent = try #require(tree.parent(of: parent))
        let great = try #require(tree.parent(of: grandparent))

        // Fast repeats arrive as click counts 1, 2, 3: each must walk one folder further out.
        map.click(at: point, modifiers: .option, clickCount: 1)
        #expect(map.view.selection == [parent])
        map.click(at: point, modifiers: .option, clickCount: 2)
        #expect(map.view.selection == [grandparent])
        map.click(at: point, modifiers: .option, clickCount: 3)
        #expect(map.view.selection == [great])
        #expect(map.view.rootNode == 0)
        #expect(map.view.press == nil)
    }

    @Test func commandClicksToggleWhateverTheirClickCount() async throws {
        let map = await MapFixture()
        let (point, node) = try #require(map.deepPoint(minDepth: 2))
        map.click(at: point, modifiers: .command, clickCount: 1)
        #expect(map.view.selection == [node])
        map.click(at: point, modifiers: .command, clickCount: 2)
        #expect(map.view.selection.isEmpty)
        map.click(at: point, modifiers: .command, clickCount: 3)
        #expect(map.view.selection == [node])
        #expect(map.view.rootNode == 0)
    }

    @Test func plainDoubleClickStillZoomsAndATripleClickIsIgnored() async throws {
        let map = await MapFixture()
        let (point, node) = try #require(map.deepPoint(minDepth: 3))
        var top = node
        while let parent = map.tree.parent(of: top), parent != 0 { top = parent }

        map.click(at: point, clickCount: 1)
        #expect(map.view.selection == [node])
        map.click(at: point, clickCount: 2)
        #expect(map.view.rootNode == top)
        // The third click of a triple must neither zoom on nor re-select.
        map.click(at: point, clickCount: 3)
        #expect(map.view.rootNode == top)
        #expect(map.view.selection == [node])
    }

    // MARK: ⌘-press, drag and the Trash

    @Test func commandPressOnASelectedTileDeselectsOnlyOnMouseUp() async throws {
        let map = await MapFixture()
        let delegate = RecordingDelegate()
        map.view.delegate = delegate
        let picks = map.distinctNodes(3)
        try #require(picks.count == 3)
        let all = Set(picks.map(\.node))
        map.view.selection = all

        // Press: nothing changes yet, so a drag from here carries the whole selection.
        map.view.mouseDown(with: map.mouse(.leftMouseDown, at: picks[0].point, modifiers: .command))
        #expect(map.view.selection == all)
        #expect(delegate.selections.isEmpty)
        #expect(Set(map.view.dragNodes(startingAt: picks[0].node)) == all)

        // Release without a drag: now the tile is deselected.
        map.view.mouseUp(with: map.mouse(.leftMouseUp, at: picks[0].point, modifiers: .command))
        #expect(map.view.selection == all.subtracting([picks[0].node]))
        #expect(delegate.selections == [all.subtracting([picks[0].node])])
    }

    @Test func commandPressThatBecameADragKeepsTheSelection() async throws {
        let map = await MapFixture()
        let picks = map.distinctNodes(2)
        try #require(picks.count == 2)
        let all = Set(picks.map(\.node))
        map.view.selection = all
        map.view.mouseDown(with: map.mouse(.leftMouseDown, at: picks[0].point, modifiers: .command))
        // What `mouseDragged` records once the pointer has travelled far enough (starting a
        // real dragging session needs the window server, so that part is not run here).
        map.view.press?.dragged = true
        map.view.mouseUp(with: map.mouse(.leftMouseUp, at: picks[0].point, modifiers: .command))
        #expect(map.view.selection == all)
    }

    @Test func aDragCarriesExactlyWhatIsReportedWhenItEndsOnTheTrash() async throws {
        let map = await MapFixture(nodeCount: 60_000, size: CGSize(width: 1400, height: 1000))
        let delegate = RecordingDelegate()
        map.view.delegate = delegate
        let picks = map.distinctNodes(100)
        try #require(picks.count == 100)
        let selected = Set(picks.prefix(99).map(\.node))
        map.view.selection = selected

        // More than the old cap of 64: every selected file is part of the drag.
        let dragged = map.view.dragNodes(startingAt: picks[0].node)
        #expect(dragged.count == 99)
        #expect(Set(dragged) == selected)
        // A tile outside the selection is dragged alone and leaves the selection alone.
        #expect(map.view.dragNodes(startingAt: picks[99].node) == [picks[99].node])
        #expect(map.view.selection == selected)

        // The end of the session hands the delegate the dragged nodes, not the selection.
        // (A session object made by hand logs an error when it is disposed of; keep it alive.)
        let session = Unmanaged.passRetained(NSDraggingSession()).takeUnretainedValue()
        map.view.draggedNodes = [picks[99].node]
        map.view.draggingSession(session, endedAt: .zero, operation: .delete)
        #expect(delegate.trashRequests == [[picks[99].node]])
        #expect(map.view.draggedNodes.isEmpty)
        map.view.draggedNodes = dragged
        map.view.draggingSession(session, endedAt: .zero, operation: .move)
        #expect(delegate.drags == [dragged])
    }

    // MARK: Keyboard

    @Test func onlyCommandDeleteRequestsTrash() async throws {
        let map = await MapFixture()
        let delegate = RecordingDelegate()
        map.view.delegate = delegate
        let (_, node) = try #require(map.deepPoint(minDepth: 2))
        map.view.selection = [node]

        map.key("\u{7F}", code: 51)  // Backspace
        map.key("\u{F728}", code: 117)  // Forward Delete
        #expect(delegate.trashRequests.isEmpty)
        #expect(map.sink.unhandledKeys == 2)

        map.key("\u{7F}", code: 51, modifiers: .command)
        map.key("\u{F728}", code: 117, modifiers: .command)
        #expect(delegate.trashRequests == [[node], [node]])
        #expect(map.sink.unhandledKeys == 2)
    }

    // MARK: ⌥-scroll

    private func depthOfRoot(_ map: MapFixture) -> Int { map.tree.depth(of: map.view.effectiveRoot) }

    private func deepFolder(_ map: MapFixture, depth: Int) -> NodeID? {
        (0 ..< NodeID(map.tree.count)).first {
            map.tree.isDirectory($0) && map.tree.depth(of: $0) == depth && map.tree.childCount(of: $0) > 0
        }
    }

    @Test func optionScrollIgnoresTheMomentumAfterAFlick() async throws {
        let map = await MapFixture()
        map.view.rootNode = try #require(deepFolder(map, depth: 6))
        let start = depthOfRoot(map)
        #expect(start == 6)

        // The stroke itself: one level out.
        map.view.scrollWheel(with: ScrollEvent.make(deltaY: 0, phase: .began))
        for _ in 0 ..< 5 { map.view.scrollWheel(with: ScrollEvent.make(deltaY: -24, phase: .changed)) }
        map.view.scrollWheel(with: ScrollEvent.make(deltaY: 0, phase: .ended))
        #expect(depthOfRoot(map) == start - 1)

        // The momentum tail: well over the step threshold, and the rate limiter is taken out
        // of the picture, so only the momentum filter can stop it.
        map.view.scrollWheel(with: ScrollEvent.make(deltaY: -22, momentum: .began))
        for _ in 0 ..< 30 {
            map.view.lastZoomGestureTime = 0
            map.view.scrollWheel(with: ScrollEvent.make(deltaY: -22, momentum: .changed))
        }
        map.view.scrollWheel(with: ScrollEvent.make(deltaY: 0, momentum: .ended))
        #expect(depthOfRoot(map) == start - 1)
    }

    @Test func mouseWheelNotchesStillZoomOneLevelEach() async throws {
        let map = await MapFixture()
        map.view.rootNode = try #require(deepFolder(map, depth: 6))
        for step in 1 ... 3 {
            map.view.lastZoomGestureTime = 0
            // A classic wheel: no phases at all, line deltas.
            map.view.scrollWheel(with: ScrollEvent.make(deltaY: -1, precise: false))
            #expect(depthOfRoot(map) == 6 - step)
        }
    }
}
}
