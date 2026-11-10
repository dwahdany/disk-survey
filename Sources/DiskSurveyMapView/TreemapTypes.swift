import AppKit
import DiskSurveyCore
import DiskSurveyTreemap

/// What the tile colours encode.
public enum TreemapColorMode: Sendable, Hashable, CaseIterable {
    /// File kind (extension), using `KindPalette`.
    case kind
    /// Time since last modification, using `AgePalette`.
    case age
}

/// How folders are set apart on the map.
public enum TreemapMapStyle: Sendable, Hashable, CaseIterable {
    /// Classic cushion treemap: structure is conveyed by shading alone; folder names float
    /// over the top-level folders.
    case cushion
    /// Cushions with thin gutters between folders.
    case grouped
    /// Nested frames with a title strip for the folders of the first two levels only.
    case framed
    /// Nested frames with a title strip for every folder, at any depth, whose rectangle is
    /// large enough to carry one; deeper levels get slimmer strips.
    case adaptive
}

/// Which tiles stay lit; everything else is dimmed.
public enum TreemapHighlight: Sendable, Equatable {
    /// No dimming.
    case none
    /// Search results as returned by `FileTree.matches` / `SearchResult.matches`. The view
    /// derives the "is or contains a match" mask itself, off the main thread.
    case matches(NodeBitset)
    /// A ready-made mask (`FileTree.containingMask(for:)`), used as is.
    case mask(NodeBitset)
    /// Files of these kinds (a click on a legend row).
    case kinds(Set<KindID>)
    /// Files of these categories.
    case categories(Set<KindCategory>)
}

/// What is under the pointer.
public struct TreemapHover: Sendable, Hashable {
    /// The file or folder. For ``isAggregate`` cells: the folder whose small items were merged.
    public var node: NodeID
    /// The cell stands for many items too small to draw individually.
    public var isAggregate: Bool
    /// Number of merged items (0 unless ``isAggregate``).
    public var mergedCount: Int
    /// Bytes the cell stands for, in the view's size metric.
    public var size: UInt64
    /// The cell's rectangle in the view's coordinate system.
    public var rect: CGRect
    /// Pointer location in the view's coordinate system.
    public var location: CGPoint
}

/// Callbacks from a ``TreemapView``. Every method has a default implementation, so a delegate
/// implements only what it needs.
///
/// Node ids always refer to the view's current ``TreemapView/tree``.
@MainActor
public protocol TreemapViewDelegate: AnyObject {
    /// The pointer moved onto another cell, or off the map (`nil`).
    func treemapView(_ view: TreemapView, didHover hover: TreemapHover?)

    /// The user changed the selection (click, keyboard, context click). Not called when the
    /// owner assigns ``TreemapView/selection``.
    func treemapView(_ view: TreemapView, didChangeSelection selection: Set<NodeID>, primary: NodeID?)

    /// The user asked to zoom (double-click, pinch, keyboard). The delegate decides by setting
    /// ``TreemapView/rootNode``; the default implementation does exactly that.
    func treemapView(_ view: TreemapView, didRequestZoomTo root: NodeID)

    /// Context menu for `nodes` (the selection, largest first, which contains `clicked`).
    func treemapView(_ view: TreemapView, menuFor nodes: [NodeID], clicked: NodeID) -> NSMenu?

    /// Space bar: preview these nodes. ``TreemapView/screenRect(for:)`` gives the source frame
    /// for the Quick Look zoom animation.
    func treemapView(_ view: TreemapView, didRequestQuickLook nodes: [NodeID])

    /// Double-click on a file that cannot be zoomed into: show it in Finder.
    func treemapView(_ view: TreemapView, didRequestReveal node: NodeID)

    /// Delete key, or a drag that ended on the Trash: move these nodes to the Trash (after
    /// whatever confirmation the app wants).
    func treemapView(_ view: TreemapView, didRequestTrash nodes: [NodeID])

    /// A drag of `nodes` out of the view ended with `operation` (`.move` means another app took
    /// the files, so the tree is stale there). Not called for `.delete`; that arrives as
    /// ``treemapView(_:didRequestTrash:)``.
    func treemapView(_ view: TreemapView, didDrag nodes: [NodeID], endedWith operation: NSDragOperation)
}

extension TreemapViewDelegate {
    public func treemapView(_ view: TreemapView, didHover hover: TreemapHover?) {}
    public func treemapView(_ view: TreemapView, didChangeSelection selection: Set<NodeID>, primary: NodeID?) {}
    public func treemapView(_ view: TreemapView, didRequestZoomTo root: NodeID) { view.rootNode = root }
    public func treemapView(_ view: TreemapView, menuFor nodes: [NodeID], clicked: NodeID) -> NSMenu? { nil }
    public func treemapView(_ view: TreemapView, didRequestQuickLook nodes: [NodeID]) {}
    public func treemapView(_ view: TreemapView, didRequestReveal node: NodeID) {}
    public func treemapView(_ view: TreemapView, didRequestTrash nodes: [NodeID]) {}
    public func treemapView(_ view: TreemapView, didDrag nodes: [NodeID], endedWith operation: NSDragOperation) {}
}

/// Maps between a layout's pixel space (top-left origin, y down) and a view's point space
/// (bottom-left origin, y up). The picture is always stretched over the whole view, so the
/// mapping stays valid while a stale image is shown during a resize.
struct MapGeometry {
    let layoutBounds: TreemapRect
    let viewSize: CGSize

    var sx: CGFloat { layoutBounds.width > 0 ? viewSize.width / CGFloat(layoutBounds.width) : 1 }
    var sy: CGFloat { layoutBounds.height > 0 ? viewSize.height / CGFloat(layoutBounds.height) : 1 }

    func viewRect(_ r: TreemapRect) -> CGRect {
        CGRect(
            x: CGFloat(r.minX) * sx, y: viewSize.height - CGFloat(r.maxY) * sy,
            width: CGFloat(r.width) * sx, height: CGFloat(r.height) * sy)
    }

    func layoutPoint(_ p: CGPoint) -> TreemapPoint {
        TreemapPoint(x: Float(p.x / sx), y: Float((viewSize.height - p.y) / sy))
    }
}

/// Storage identity of a tree value: two values with the same identity are the same tree, so
/// re-assigning it (SwiftUI does that on every update) costs nothing.
struct TreeIdentity: Equatable {
    let children: UnsafeRawPointer?
    let name: UnsafeRawPointer?
    let count: Int
    let revision: UInt64
    let rootChildCount: Int
    let rootPath: String

    init(_ tree: FileTree) {
        // The slices point into the tree's copy-on-write column buffers. A different scan
        // result lives in different buffers; an in-place mutation bumps `revision`.
        children = tree.children(of: tree.root).withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        name = tree.nameUTF8(of: tree.root).withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        count = tree.count
        revision = tree.revision
        rootChildCount = tree.childCount(of: tree.root)
        rootPath = tree.rootPath
    }
}
