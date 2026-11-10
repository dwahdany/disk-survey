import SwiftUI
import DiskSurveyCore
import DiskSurveyTreemap

/// SwiftUI wrapper around ``TreemapView``.
///
/// It holds no state of its own: every input is a plain value that the owner keeps in its
/// model, and user actions come back through the delegate, which the owner (a long-lived
/// model object) implements. Assigning unchanged values on every SwiftUI update is free.
public struct TreemapViewRepresentable: NSViewRepresentable {
    public var tree: FileTree?
    public var rootNode: NodeID
    public var selection: Set<NodeID>
    public var primarySelection: NodeID?
    public var highlight: TreemapHighlight
    public var colorMode: TreemapColorMode
    public var mapStyle: TreemapMapStyle
    public var sizeMetric: TreemapLayoutOptions.SizeMetric
    public var packagesAsLeaves: Bool
    public var showsLabels: Bool
    public var showsTooltip: Bool
    public var isScanning: Bool
    /// See ``TreemapView/cushionStrength`` and ``TreemapView/showsTileBorders``.
    public var cushionStrength: Float = 1
    public var showsTileBorders: Bool = true
    /// See ``TreemapView/maxDepth``.
    public var maxDepth: Int?
    /// Held weakly by the view.
    public var delegate: (any TreemapViewDelegate)?
    /// Called once with the new view, for owners that want to send it commands (zoom, focus).
    public var onCreate: (@MainActor (TreemapView) -> Void)?

    public init(
        tree: FileTree?, rootNode: NodeID = 0, selection: Set<NodeID> = [], primarySelection: NodeID? = nil,
        highlight: TreemapHighlight = .none, colorMode: TreemapColorMode = .kind, mapStyle: TreemapMapStyle = .adaptive,
        sizeMetric: TreemapLayoutOptions.SizeMetric = .allocated, packagesAsLeaves: Bool = false,
        showsLabels: Bool = true, showsTooltip: Bool = true, isScanning: Bool = false,
        delegate: (any TreemapViewDelegate)? = nil, onCreate: (@MainActor (TreemapView) -> Void)? = nil
    ) {
        self.tree = tree
        self.rootNode = rootNode
        self.selection = selection
        self.primarySelection = primarySelection
        self.highlight = highlight
        self.colorMode = colorMode
        self.mapStyle = mapStyle
        self.sizeMetric = sizeMetric
        self.packagesAsLeaves = packagesAsLeaves
        self.showsLabels = showsLabels
        self.showsTooltip = showsTooltip
        self.isScanning = isScanning
        self.delegate = delegate
        self.onCreate = onCreate
    }

    public func makeNSView(context: Context) -> TreemapView {
        let view = TreemapView(frame: .zero)
        apply(to: view)
        onCreate?(view)
        return view
    }

    public func updateNSView(_ view: TreemapView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: TreemapView) {
        view.delegate = delegate
        view.isScanning = isScanning
        view.mapStyle = mapStyle
        view.sizeMetric = sizeMetric
        view.packagesAsLeaves = packagesAsLeaves
        view.colorMode = colorMode
        view.showsLabels = showsLabels
        view.showsTooltip = showsTooltip
        view.cushionStrength = cushionStrength
        view.showsTileBorders = showsTileBorders
        view.maxDepth = maxDepth
        // Tree first: root and selection ids refer to it.
        view.tree = tree
        view.rootNode = rootNode
        view.highlight = highlight
        view.selection = selection
        if let primarySelection { view.primarySelection = primarySelection }
    }
}
