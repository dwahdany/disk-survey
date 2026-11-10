import AppKit
import DiskSurveyCore
import DiskSurveyTreemap

import Testing
@testable import DiskSurveyMapView

/// Parent of every suite that waits on the main actor. Serialized as a whole, so that
/// one test's waits are not filled with another test's work on the main thread.
@MainActor @Suite(.serialized) enum LiveViewTests {}

// Everything here drives the view in-process: events are objects handed straight to the view's
// handlers, windows are created but never ordered on screen. Nothing is posted to the system.

/// Waits, with the main actor released (renders arrive and timers fire on the main queue),
/// until `condition` holds.
@MainActor @discardableResult
func pump(timeout: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor
func pump(for seconds: TimeInterval) async {
    try? await Task.sleep(for: .seconds(seconds))
}

/// Swallows keys the map does not handle (they would otherwise end in a system beep).
final class KeySink: NSView {
    var unhandledKeys = 0
    override func keyDown(with event: NSEvent) { unhandledKeys += 1 }
}

@MainActor
final class RecordingDelegate: TreemapViewDelegate {
    var hovers: [TreemapHover?] = []
    var selections: [Set<NodeID>] = []
    var trashRequests: [[NodeID]] = []
    var drags: [[NodeID]] = []

    func treemapView(_ view: TreemapView, didHover hover: TreemapHover?) { hovers.append(hover) }
    func treemapView(_ view: TreemapView, didChangeSelection selection: Set<NodeID>, primary: NodeID?) {
        selections.append(selection)
    }
    func treemapView(_ view: TreemapView, didRequestTrash nodes: [NodeID]) { trashRequests.append(nodes) }
    func treemapView(_ view: TreemapView, didDrag nodes: [NodeID], endedWith operation: NSDragOperation) {
        drags.append(nodes)
    }
}

/// A map with a rendered picture. `inWindow` puts it in a window that is never shown (needed
/// for transitions and accessibility posts).
@MainActor
struct MapFixture {
    let view: TreemapView
    let sink: KeySink
    let window: NSWindow?
    let tree: FileTree

    init(
        nodeCount: Int = 20_000, seed: UInt64 = 7, size: CGSize = CGSize(width: 800, height: 600), inWindow: Bool = false,
        configure: (TreemapView) -> Void = { _ in }
    ) async {
        tree = FileTree.synthetic(nodeCount: nodeCount, seed: seed)
        view = TreemapView(frame: CGRect(origin: .zero, size: size))
        sink = KeySink(frame: CGRect(origin: .zero, size: size))
        sink.addSubview(view)
        if inWindow {
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = sink
            self.window = window
        } else {
            window = nil
        }
        configure(view)
        view.tree = tree
        await pump { view.interactiveFrame != nil }
    }

    /// Waits for a picture newer than the one shown now.
    func awaitNewFrame(timeout: TimeInterval = 10) async -> Bool {
        let serial = view.displayed?.request.serial ?? -1
        return await pump(timeout: timeout) { (view.displayed?.request.serial ?? -1) > serial && view.interactiveFrame != nil }
    }

    /// A point over a node at least `minDepth` levels below the root.
    func deepPoint(minDepth: Int) -> (point: NSPoint, node: NodeID)? {
        for y in stride(from: 20.0, to: Double(view.bounds.height), by: 23) {
            for x in stride(from: 20.0, to: Double(view.bounds.width), by: 23) {
                let point = NSPoint(x: x, y: y)
                if let node = view.node(at: point), tree.depth(of: node) >= minDepth { return (point, node) }
            }
        }
        return nil
    }

    /// Leaf-ish nodes under distinct points, none an ancestor of another.
    func distinctNodes(_ count: Int) -> [(point: NSPoint, node: NodeID)] {
        var found: [(NSPoint, NodeID)] = []
        var seen = Set<NodeID>()
        for y in stride(from: 6.0, to: Double(view.bounds.height), by: 9) {
            for x in stride(from: 6.0, to: Double(view.bounds.width), by: 9) {
                let point = NSPoint(x: x, y: y)
                guard let node = view.node(at: point), !tree.isDirectory(node), seen.insert(node).inserted else { continue }
                found.append((point, node))
                if found.count == count { return found }
            }
        }
        return found
    }

    func mouse(_ type: NSEvent.EventType, at point: NSPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0)!
    }

    func click(at point: NSPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        view.mouseDown(with: mouse(.leftMouseDown, at: point, modifiers: modifiers, clickCount: clickCount))
        view.mouseUp(with: mouse(.leftMouseUp, at: point, modifiers: modifiers, clickCount: clickCount))
    }

    func move(to point: NSPoint) {
        view.mouseMoved(with: mouse(.mouseMoved, at: point, clickCount: 0))
    }

    func key(_ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }
}

/// A scroll-wheel event with chosen phases; `NSEvent` offers no constructor for one.
final class ScrollEvent: NSEvent, @unchecked Sendable {
    private var fakePhase: NSEvent.Phase = []
    private var fakeMomentum: NSEvent.Phase = []
    private var fakeDeltaY: CGFloat = 0
    private var fakePrecise = true
    private var fakeModifiers: NSEvent.ModifierFlags = []
    private var fakeLocation = NSPoint.zero

    static func make(
        deltaY: CGFloat, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [], precise: Bool = true,
        modifiers: NSEvent.ModifierFlags = .option, location: NSPoint = .zero
    ) -> ScrollEvent {
        let event = ScrollEvent()
        event.fakeDeltaY = deltaY
        event.fakePhase = phase
        event.fakeMomentum = momentum
        event.fakePrecise = precise
        event.fakeModifiers = modifiers
        event.fakeLocation = location
        return event
    }

    override var type: NSEvent.EventType { .scrollWheel }
    override var phase: NSEvent.Phase { fakePhase }
    override var momentumPhase: NSEvent.Phase { fakeMomentum }
    override var scrollingDeltaY: CGFloat { fakeDeltaY }
    override var scrollingDeltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { fakePrecise }
    override var modifierFlags: NSEvent.ModifierFlags { fakeModifiers }
    override var locationInWindow: NSPoint { fakeLocation }
}
