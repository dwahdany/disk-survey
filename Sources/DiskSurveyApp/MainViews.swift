import AppKit
import SwiftUI
import DiskSurveyCore
import DiskSurveyMapView
import DiskSurveyScan
import DiskSurveyTreemap

/// The content of a window: the start screen, or the scan (outline, map, inspector).
struct RootView: View {
    let model: WindowModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        Group {
            if model.phase == .start {
                StartView(model: model)
            } else {
                ScanView(model: model)
            }
        }
        .frame(minWidth: minimumWidth, minHeight: 480)
        .background(WindowAccessor(model: model))
        .background(WindowTitle(model: model))
        .modifier(DocumentProxy(url: model.phase == .start ? nil : model.scanRoot))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            // A dropped item comes with access of its own; in the sandboxed edition the
            // access manager keeps it (and asks, should that turn out not to be so).
            model.app.scan(url, in: model, userSelected: true)
            return true
        } isTargeted: { model.isDropTargeted = $0 }
        .sheet(item: $model.trashRequest) { request in
            TrashSheet(model: model, request: request)
        }
        .alert(
            model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { info in
            if info.offersRescan {
                Button("Rescan Folder") { model.rescan() }
                Button("OK", role: .cancel) {}
            } else if let url = info.accessURL {
                if info.offersGrantPanel {
                    Button("Grant Access…") { model.app.scan(url, in: model, forcePanel: true) }
                }
                if info.offersPrivacySettings {
                    Button("Open Privacy Settings…") { model.app.openFullDiskAccessSettings() }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { info in
            Text(([info.message] + info.paths.prefix(6) + (info.paths.count > 6 ? ["…and \(info.paths.count - 6) more"] : [])).joined(separator: "\n"))
        }
        .onAppear {
            model.app.adoptOpenWindow(openWindow)
            let settings = openSettings
            model.app.openSettings = { settings() }
        }
    }

    /// The narrowest window in which outline and map both keep their minimum width next to
    /// the inspector at the width it opens with (it does not give way to the panes by itself).
    /// An inspector dragged wider than that in the smallest window takes the difference from the map.
    private var minimumWidth: CGFloat {
        guard model.phase != .start else { return 760 }
        let preferences = model.preferences
        let split = preferences.showsOutline ? MainSplit.SplitView.minimumWidth : MainSplit.SplitView.minimumMapWidth
        return max(760, split + (preferences.showsInspector ? InspectorView.idealWidth + 1 : 0))
    }
}

/// Gives the window a proxy icon for the scanned folder.
private struct DocumentProxy: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url { content.navigationDocument(url) } else { content }
    }
}

/// Sets the window's title and subtitle. A view of its own, because the subtitle follows the
/// tree and the size mode, and `RootView` (sheets, alerts, the drop target) need not be
/// evaluated again for those.
private struct WindowTitle: View {
    let model: WindowModel

    var body: some View {
        Color.clear
            .navigationTitle(model.title)
            .navigationSubtitle(model.subtitle)
    }
}

/// Connects the model to its `NSWindow` (for sheets, Quick Look, the snapshot harness) and
/// tells the app which window is frontmost and when one closes.
struct WindowAccessor: NSViewRepresentable {
    let model: WindowModel

    final class Probe: NSView {
        var model: WindowModel?
        private var observers: [NSObjectProtocol] = []
        private var responderObservation: NSKeyValueObservation?
        private var quickLookResponder: QuickLookResponder?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            responderObservation = nil
            guard let window, let model else { return }
            model.window = window
            window.tabbingIdentifier = "DiskSurveyScan"
            if !(window.nextResponder is QuickLookResponder) {
                let responder = QuickLookResponder()
                responder.model = model
                responder.nextResponder = window.nextResponder
                window.nextResponder = responder
                quickLookResponder = responder
            }
            let app = model.app
            let id = model.id
            if window.isMainWindow || app.activeWindow == nil { app.activeWindow = model }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: window, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { if let model { app.activeWindow = model } }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { app.windowClosed(id) }
            })
            // Menu shortcuts that double as text-editing keys depend on where the focus is.
            responderObservation = window.observe(\.firstResponder) { _, _ in
                MainActor.assumeIsolated { app.refreshFocus() }
            }
            SnapshotHarness.shared.windowAppeared(model)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.model = model
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {}
}

// MARK: - Scan view

/// The scan: outline and map, inspector, toolbar and search field.
///
/// Evaluating this body rebuilds the toolbar, which costs several times what any other view
/// here does. So nothing that changes during ordinary use (zoom history, selection, search text,
/// colour or size mode, scan phase) is read here: each toolbar item and the search field read
/// their own state in a small view of their own.
struct ScanView: View {
    let model: WindowModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var preferences = model.preferences
        let _ = DebugCounters.scanViewBodies += 1
        SearchHost(model: model) {
            OutlineAndMap(model: model, scheme: mapScheme)
                .ignoresSafeArea(.container, edges: .bottom)
                .inspector(isPresented: $preferences.showsInspector) {
                    InspectorView(model: model, scheme: mapScheme)
                        .inspectorColumnWidth(min: InspectorView.minimumWidth, ideal: InspectorView.idealWidth, max: 420)
                }
        }
        .toolbar { toolbar }
        .onChange(of: preferences.packagesAsItems) { model.preferencesChanged() }
        .onChange(of: preferences.mapPalette) { model.mapView?.appearance = preferences.mapPalette.appearance }
        .onExitCommand { if model.phase == .scanning { model.cancelScan() } else if model.searchIsActive { model.clearSearch() } }
    }

    private var mapScheme: PaletteScheme {
        switch model.preferences.mapPalette {
        case .system: colorScheme.palette
        case .light: .light
        case .dark: .dark
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let model = model
        let _ = DebugCounters.toolbarBuilds += 1
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                ToolbarButton(title: "Back", symbol: "chevron.left", help: "Back to the previously shown folder (⌘[)") {
                    model.canGoBack
                } action: {
                    model.goBack()
                }
                ToolbarButton(title: "Forward", symbol: "chevron.right", help: "Forward (⌘])") {
                    model.canGoForward
                } action: {
                    model.goForward()
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            ScanButton(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            ColorModePicker(preferences: model.preferences)
        }
        ToolbarItem(placement: .primaryAction) {
            SizeModePicker(preferences: model.preferences)
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup(placement: .primaryAction) {
            ToolbarButton(title: "Quick Look", symbol: "eye", help: "Preview the selection (Space)") {
                model.canActOnFiles
            } action: {
                model.toggleQuickLook()
            }
            ToolbarButton(title: "Reveal in Finder", symbol: "folder", help: "Show the selection in Finder (⇧⌘R)") {
                model.canActOnFiles
            } action: {
                model.revealInFinder()
            }
            ToolbarButton(title: "Move to Trash", symbol: "trash", help: "Move the selection to the Trash (⌘⌫)") {
                model.canTrash
            } action: {
                model.requestTrash()
            }
            ToolbarButton(title: "Share", symbol: "square.and.arrow.up", help: "Share the selection") {
                model.canActOnFiles
            } action: {
                model.shareSelection()
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Button { model.preferences.showsInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

/// A toolbar button that reads its enabled state in its own body, so a change of that state
/// redraws this button and not the toolbar.
private struct ToolbarButton: View {
    let title: String
    let symbol: String
    let help: String
    let enabled: @MainActor () -> Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .disabled(!enabled())
            .help(help)
    }
}

/// Stop while scanning, Rescan otherwise.
private struct ScanButton: View {
    let model: WindowModel

    var body: some View {
        if model.phase == .scanning {
            Button { model.cancelScan() } label: { Label("Stop", systemImage: "stop.fill") }
                .help("Stop scanning (⌘.)")
        } else {
            Button {
                model.rescan(whole: NSEvent.modifierFlags.contains(.option))
            } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(model.locationMissing)
                .help("Rescan the folder shown in the map (⌘R). Hold Option to rescan everything.")
        }
    }
}

private struct ColorModePicker: View {
    let preferences: Preferences

    var body: some View {
        @Bindable var preferences = preferences
        Picker("Color", selection: $preferences.colorMode) {
            Label("Color by Kind", systemImage: "paintpalette").tag(ColorModeSetting.kind)
            Label("Color by Age", systemImage: "clock").tag(ColorModeSetting.age)
        }
        .pickerStyle(.segmented)
        .help("Color the map by file kind or by age")
    }
}

private struct SizeModePicker: View {
    let preferences: Preferences

    var body: some View {
        @Bindable var preferences = preferences
        Picker("Size", selection: $preferences.sizeMode) {
            Text("On Disk").tag(SizeMode.allocated)
            Text("Logical").tag(SizeMode.logical)
        }
        .pickerStyle(.menu)
        .help("Show the space taken on disk, or the files’ own length")
    }
}

/// Owns the search field. The bindings to the query are made here, and making them reads the
/// query: in `ScanView` that would rebuild the toolbar on every keystroke. `content` is built by
/// the caller and merely passed through, so a keystroke re-evaluates nothing but this body.
private struct SearchHost<Content: View>: View {
    let model: WindowModel
    let content: Content
    @FocusState private var searchFocused: Bool

    init(model: WindowModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        @Bindable var model = model
        content
            .searchable(text: $model.searchText, tokens: $model.searchTokens, placement: .toolbar, prompt: "Search names") { token in
                Label(token.title, systemImage: token.symbol)
            }
            .searchFocused($searchFocused)
            .onChange(of: model.searchFocusTick) { searchFocused = true }
    }
}

// MARK: - Split: outline | map

/// Reads the fast-changing state (tree, selection) on behalf of the split, so that a click in
/// the map re-evaluates only this small view and not the toolbar around it.
struct OutlineAndMap: View {
    let model: WindowModel
    let scheme: PaletteScheme

    var body: some View {
        let preferences = model.preferences
        MainSplit(
            model: model, tree: model.tree, generation: model.treeGeneration, epoch: model.idEpoch, selection: model.selection,
            primary: model.primarySelection, metric: preferences.sizeMode, packagesAsItems: preferences.packagesAsItems,
            scheme: scheme, showsOutline: preferences.showsOutline)
        // Here rather than in `ScanView`: this body follows the size mode anyway.
        .onChange(of: preferences.sizeMode) { model.preferencesChanged() }
    }
}

/// An `NSSplitView` holding the AppKit outline and the SwiftUI map pane. AppKit remembers the
/// divider position under an autosave name.
struct MainSplit: NSViewRepresentable {
    let model: WindowModel
    let tree: FileTree?
    let generation: Int
    let epoch: Int
    let selection: Set<NodeID>
    let primary: NodeID?
    let metric: SizeMode
    let packagesAsItems: Bool
    let scheme: PaletteScheme
    let showsOutline: Bool

    final class SplitView: NSSplitView, NSSplitViewDelegate {
        private var didPlaceDivider = false
        static let autosave = "DiskSurveyMainSplit"
        /// The narrowest the outline and the map get, by dragging the divider or by resizing the window.
        static let minimumOutlineWidth: CGFloat = 220
        static let minimumMapWidth: CGFloat = 320
        static let minimumWidth = minimumOutlineWidth + minimumMapWidth + 1
        /// The outline's width as the user (or the first layout) set it. A narrow window takes
        /// width from the outline to keep the map usable; a wider one gives it back up to this.
        private var preferredOutlineWidth: CGFloat?
        private var isAdjusting = false

        override func layout() {
            super.layout()
            // First layout without a saved position: give the outline a sensible share.
            if !didPlaceDivider, bounds.width > 100, subviews.count == 2 {
                didPlaceDivider = true
                if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(Self.autosave)") == nil || LaunchOptions.current.isHarness {
                    setPosition(min(500, bounds.width * 0.46), ofDividerAt: 0)
                }
                if let outline = subviews.first, !outline.isHidden { preferredOutlineWidth = outline.frame.width }
            }
            keepMapUsable()
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            keepMapUsable()
        }

        /// The outline keeps its width when the window is resized, so without this a smaller
        /// window squeezes the map alone, down to nothing. The limits that apply to dragging the
        /// divider are enforced here for every other way the split changes size (a saved
        /// position from a wider window included).
        private func keepMapUsable() {
            guard didPlaceDivider, !isAdjusting, subviews.count == 2, let outline = subviews.first, !outline.isHidden, bounds.width > 100
            else { return }
            let widest = max(Self.minimumOutlineWidth, bounds.width - dividerThickness - Self.minimumMapWidth)
            let target = min(preferredOutlineWidth ?? outline.frame.width, widest)
            guard abs(outline.frame.width - target) > 0.5 else { return }
            isAdjusting = true
            setPosition(target, ofDividerAt: 0)
            isAdjusting = false
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            // Only the user dragging the divider says how wide the outline should be; a window
            // resize or the inspector opening must not overwrite that.
            guard !isAdjusting, didPlaceDivider, notification.userInfo?["NSSplitViewDividerIndex"] != nil,
                let type = NSApp.currentEvent?.type, type == .leftMouseDragged || type == .leftMouseUp, window?.inLiveResize != true,
                let outline = subviews.first, !outline.isHidden
            else { return }
            preferredOutlineWidth = outline.frame.width
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            Self.minimumOutlineWidth
        }
        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            max(Self.minimumOutlineWidth, splitView.bounds.width - splitView.dividerThickness - Self.minimumMapWidth)
        }
        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            // The map takes up window resizes; the outline keeps its width.
            view !== subviews.first
        }
    }

    @MainActor final class Coordinator {
        let outline: OutlineController
        init(model: WindowModel) { outline = OutlineController(model: model) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> SplitView {
        let split = SplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = split
        let map = NSHostingView(rootView: MapPane(model: model))
        map.sizingOptions = []
        split.addArrangedSubview(context.coordinator.outline.scrollView)
        split.addArrangedSubview(map)
        if !LaunchOptions.current.isHarness { split.autosaveName = SplitView.autosave }
        model.outline = context.coordinator.outline
        apply(to: split, context: context)
        return split
    }

    func updateNSView(_ split: SplitView, context: Context) { apply(to: split, context: context) }

    private func apply(to split: SplitView, context: Context) {
        let outline = context.coordinator.outline
        if outline.scrollView.isHidden == showsOutline {
            outline.scrollView.isHidden = !showsOutline
            split.adjustSubviews()
        }
        outline.update(
            tree: tree, generation: generation, epoch: epoch, selection: selection, primary: primary, metric: metric,
            packagesAsItems: packagesAsItems, scheme: scheme)
    }
}

// MARK: - Map pane

struct MapPane: View {
    let model: WindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let preferences = model.preferences
        VStack(spacing: 0) {
            PathBar(model: model)
            Divider()
            ZStack(alignment: .bottom) {
                TreemapViewRepresentable(
                    tree: model.tree, rootNode: model.rootNode, selection: model.selection, primarySelection: model.primarySelection,
                    highlight: model.highlight, colorMode: preferences.colorMode.mapMode, mapStyle: preferences.mapStyle.mapStyle,
                    sizeMetric: preferences.sizeMode.metric, packagesAsLeaves: preferences.packagesAsItems,
                    showsLabels: preferences.showsLabels, showsTooltip: true, isScanning: model.phase == .scanning,
                    cushionStrength: Float(preferences.cushionStrength), showsTileBorders: preferences.showsTileBorders,
                    maxDepth: preferences.mapDepth == MapDepth.all ? nil : preferences.mapDepth,
                    delegate: model,
                    onCreate: { view in
                        model.mapView = view
                        view.appearance = model.preferences.mapPalette.appearance
                    }
                )
                .accessibilityLabel("Treemap")
                VStack(spacing: 10) {
                    if let toast = model.toast {
                        ToastView(model: model, toast: toast)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                    if model.phase == .scanning {
                        ScanHUD(model: model)
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, 14)
                .padding(.horizontal, 16)
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: model.toast)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.phase == .scanning)
            }
            Divider()
            StatusBar(model: model)
        }
        .background(.background)
    }
}

extension TreemapViewRepresentable {
    /// The app's full set of inputs, including the appearance options.
    init(
        tree: FileTree?, rootNode: NodeID, selection: Set<NodeID>, primarySelection: NodeID?, highlight: TreemapHighlight,
        colorMode: TreemapColorMode, mapStyle: TreemapMapStyle, sizeMetric: TreemapLayoutOptions.SizeMetric,
        packagesAsLeaves: Bool, showsLabels: Bool, showsTooltip: Bool, isScanning: Bool, cushionStrength: Float,
        showsTileBorders: Bool, maxDepth: Int?, delegate: (any TreemapViewDelegate)?,
        onCreate: (@MainActor (TreemapView) -> Void)?
    ) {
        self.init(
            tree: tree, rootNode: rootNode, selection: selection, primarySelection: primarySelection, highlight: highlight,
            colorMode: colorMode, mapStyle: mapStyle, sizeMetric: sizeMetric, packagesAsLeaves: packagesAsLeaves,
            showsLabels: showsLabels, showsTooltip: showsTooltip, isScanning: isScanning, delegate: delegate, onCreate: onCreate)
        self.cushionStrength = cushionStrength
        self.showsTileBorders = showsTileBorders
        self.maxDepth = maxDepth
    }
}

// MARK: - Path bar

/// Breadcrumbs for the folder shown in the map. Each segment zooms to that folder; its
/// chevron lists the sibling folders.
struct PathBar: View {
    let model: WindowModel

    var body: some View {
        HStack(spacing: 8) {
            if let tree = model.tree {
                let root = Int(model.rootNode) < tree.count ? model.rootNode : 0
                let lineage = tree.lineage(of: root)
                // Anchored at the trailing edge and rebuilt per folder, so the folder shown is
                // always in view; the outer levels scroll off to the left in a narrow window.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(Array(lineage.enumerated()), id: \.element) { index, node in
                            if index > 0 { siblingMenu(tree: tree, node: node) }
                            segment(tree: tree, node: node, isCurrent: node == root)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .defaultScrollAnchor(.trailing, for: .initialOffset)
                .defaultScrollAnchor(.leading, for: .alignment)
                // The breadcrumb is what the bar is for; in a narrow pane the figures give way.
                .frame(minWidth: 120)
                .id(root)
                Spacer(minLength: 0)
                // The figures repeat the window's subtitle; in a narrow pane they make room for
                // the breadcrumb and the depth control.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        Text("\(Format.bytes(model.size(of: root, in: tree))) · \(Format.files(tree.fileCount(of: root)))")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        DepthControl(preferences: model.preferences, title: .text)
                    }
                    DepthControl(preferences: model.preferences, title: .text)
                    // Never bare numbers: in a narrow pane a symbol stands in for the caption.
                    DepthControl(preferences: model.preferences, title: .symbol)
                }
                .padding(.trailing, 10)
            } else {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                Text(model.scanRoot?.path ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 32)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    private func segment(tree: FileTree, node: NodeID, isCurrent: Bool) -> some View {
        Button {
            model.zoom(to: node)
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: IconCache.shared.icon(for: tree, node: node))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(node == tree.root ? model.title : tree.name(of: node))
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tree.path(of: node))
        .accessibilityLabel(tree.name(of: node))
        .accessibilityHint(isCurrent ? "Shown in the map" : "Zoom out to this folder")
    }

    /// The separator before a segment doubles as a menu of that segment's sibling folders.
    private func siblingMenu(tree: FileTree, node: NodeID) -> some View {
        let siblings = siblingFolders(tree: tree, node: node)
        return Menu {
            ForEach(siblings, id: \.self) { sibling in
                Button {
                    model.zoom(to: sibling)
                } label: {
                    Text("\(tree.name(of: sibling)) — \(Format.bytes(model.size(of: sibling, in: tree)))")
                    Image(nsImage: IconCache.shared.icon(for: tree, node: sibling))
                }
                .disabled(sibling == node)
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 22)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Other folders next to “\(tree.name(of: node))”")
        .accessibilityLabel("Sibling folders of \(tree.name(of: node))")
    }

    private func siblingFolders(tree: FileTree, node: NodeID) -> [NodeID] {
        guard let parent = tree.parent(of: node) else { return [] }
        var result: [NodeID] = []
        // Children are sorted by size, so the first folders are the interesting ones.
        for child in tree.children(of: parent).prefix(400) where tree.isDirectory(child) && tree.childCount(of: child) > 0 {
            result.append(child)
            if result.count == 24 { break }
        }
        if !result.contains(node) { result.append(node) }
        return result
    }
}

/// The map's level of detail: how many folder levels below the folder shown are subdivided.
/// At 1 the map is just that folder's children as labelled blocks; "All" goes down to the files.
struct DepthControl: View {
    let preferences: Preferences
    enum Title {
        case text, symbol
    }
    let title: Title

    var body: some View {
        @Bindable var preferences = preferences
        HStack(spacing: 7) {
            switch title {
            case .text:
                Text("Depth")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            case .symbol:
                Image(systemName: "square.3.layers.3d")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Picker("Map depth", selection: $preferences.mapDepth) {
                ForEach(1 ... MapDepth.deepest, id: \.self) { level in
                    Text("\(level)").tag(level)
                        .accessibilityLabel(MapDepth.title(level))
                }
                Text("All").tag(MapDepth.all)
                    .accessibilityLabel(MapDepth.title(MapDepth.all))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .help("Folder levels shown below this folder: 1 shows only its folders as blocks, All goes down to the files (⌘− less, ⌘+ more)")
    }
}

// MARK: - Status bar

struct StatusBar: View {
    let model: WindowModel

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            if let busy = model.busyMessage {
                ProgressView().controlSize(.small)
                Text(busy).lineLimit(1)
            } else {
                Text(statusText)
                    .lineLimit(1)
                    // A hover chain keeps both ends; a hint loses whole words at its end.
                    .truncationMode(model.hover == nil ? .tail : .middle)
                    .foregroundStyle(.secondary)
                    .help(statusHelp)
            }
            Spacer(minLength: 8)
            if model.locationMissing {
                Label("Location unavailable", systemImage: "eject")
                    .foregroundStyle(.orange)
            }
            if let summary = model.summary, summary.totalIssueCount > 0 {
                Button {
                    model.showsIssues = true
                } label: {
                    Label("\(Format.count(summary.totalIssueCount)) unreadable", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                .buttonStyle(.plain)
                .help("Folders Disk Survey could not read")
                .popover(isPresented: $model.showsIssues, arrowEdge: .top) { IssuesPopover(model: model, summary: summary) }
            }
            if let volume = model.rootVolume, model.phase == .loaded {
                Button {
                    model.showsVolumeInfo = true
                } label: {
                    HStack(spacing: 6) {
                        CapacityBar(segments: VolumeBreakdown(volume: volume, model: model).segments)
                            .frame(width: 90, height: 6)
                        Text("\(Format.bytes(volume.availableCapacityForImportantUsage)) available")
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .help("How the space on “\(volume.name)” is used")
                .popover(isPresented: $model.showsVolumeInfo, arrowEdge: .top) { VolumePopover(model: model, volume: volume) }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }

    /// The full path of the hovered item, for when the breadcrumb of names is cut short.
    private var statusHelp: String {
        if let tree = model.tree, let hover = model.hover, Int(hover.node) < tree.count, !tree.isRemoved(hover.node) {
            return tree.path(of: hover.node)
        }
        return statusText
    }

    private var statusText: String {
        guard let tree = model.tree else { return model.phase == .scanning ? "Scanning…" : "" }
        if let hover = model.hover, Int(hover.node) < tree.count, !tree.isRemoved(hover.node) {
            // The folders around the item, each with its size, from the folder shown inwards:
            // pointing at a tile answers "which folder is the big one".
            var chain: [String] = []
            var current = hover.isAggregate ? hover.node : (tree.parent(of: hover.node) ?? model.rootNode)
            while current != model.rootNode, current != tree.root, chain.count < 32 {
                chain.append("\(tree.name(of: current)) (\(Format.bytes(model.size(of: current, in: tree))))")
                guard let parent = tree.parent(of: current) else { break }
                current = parent
            }
            let item =
                hover.isAggregate
                ? "\(Format.items(hover.mergedCount)) too small to draw — \(Format.bytes(hover.size))"
                : "\(tree.name(of: hover.node)) — \(Format.bytes(hover.size))"
            return (chain.reversed() + [item]).joined(separator: "  ›  ")
        }
        if let summary = model.selectionSummary { return summary }
        if model.phase == .scanning { return "The map fills in as folders are read." }
        return "Click to select · Double-click to zoom in · Space for Quick Look"
    }
}

// MARK: - Scan HUD and toasts

/// Live counters while scanning, floating over the map.
struct ScanHUD: View {
    let model: WindowModel

    var body: some View {
        let progress = model.progress
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                counter(Format.count(Int(progress.filesScanned)), "files")
                counter(Format.bytes(progress.bytesAllocated), "found")
                counter(Format.compactCount(Int(progress.entriesPerSecond)), "items/s")
                counter(Format.duration(progress.elapsed), "elapsed")
                Spacer(minLength: 12)
                Button("Stop") { model.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop scanning and keep what was found (Esc)")
            }
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Scan progress")
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Scanning")
            }
            Text(progress.currentPath.isEmpty ? (model.scanRoot?.path ?? "") : progress.currentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        // A material rather than glass: glass over saturated tiles costs the numbers their contrast.
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scan progress")
    }

    /// Known only for whole volumes: bytes found against bytes the volume reports as used.
    private var fraction: Double? {
        guard let volume = model.rootVolume, volume.usedCapacity > 0 else { return nil }
        return min(0.99, Double(model.progress.bytesAllocated) / Double(volume.usedCapacity))
    }

    private func counter(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct ToastView: View {
    let model: WindowModel
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.text)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                if let detail = toast.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            if let title = toast.actionTitle {
                Button(title) { model.performToastAction() }
                    .buttonStyle(.glass)
            }
            Button {
                model.toast = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Capacity

/// A horizontal bar of proportional coloured segments on a neutral track.
struct CapacityBar: View {
    struct Segment: Identifiable {
        var id: String
        var fraction: Double
        var color: Color
    }
    let segments: [Segment]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, geometry.size.width * segment.fraction))
                }
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(.capsule)
        }
        .accessibilityHidden(true)
    }
}

/// How a volume's capacity splits into what the scan saw, what it could not see, purgeable
/// space and free space.
struct VolumeBreakdown {
    var total: UInt64
    var scanned: UInt64
    var hidden: UInt64
    var purgeable: UInt64
    var free: UInt64

    @MainActor init(volume: Volume, model: WindowModel) {
        total = max(volume.totalCapacity, 1)
        let used = volume.usedCapacity
        let found = model.tree.map { $0.size(of: $0.root) } ?? 0
        scanned = min(found, used)
        hidden = used > found ? used - found : 0
        purgeable = volume.purgeableCapacity
        free = volume.availableCapacity
    }

    var segments: [CapacityBar.Segment] {
        let whole = Double(total)
        return [
            .init(id: "scanned", fraction: Double(scanned) / whole, color: .accentColor),
            .init(id: "hidden", fraction: Double(hidden) / whole, color: .orange),
            .init(id: "purgeable", fraction: Double(purgeable) / whole, color: .secondary.opacity(0.45)),
        ]
    }
}

struct VolumePopover: View {
    let model: WindowModel
    let volume: Volume

    var body: some View {
        let breakdown = VolumeBreakdown(volume: volume, model: model)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(volume.name).font(.headline)
                Spacer()
                Text(Format.bytes(volume.totalCapacity)).foregroundStyle(.secondary)
            }
            CapacityBar(segments: breakdown.segments).frame(height: 10)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row(.accentColor, "Shown in the map", breakdown.scanned)
                if model.preferences.showHiddenSpace {
                    row(.orange, "Not visible to Disk Survey", breakdown.hidden)
                }
                row(.secondary.opacity(0.45), "Purgeable", breakdown.purgeable)
                row(Color.primary.opacity(0.12), "Free", breakdown.free)
            }
            if model.preferences.showHiddenSpace {
                Text("“Not visible” is space the volume reports as used that the scan could not find: local snapshots, system-protected data, other volumes sharing the container, and folders Disk Survey may not read. Purgeable space is reclaimed by macOS when needed."
                    + (model.app.isSandboxed ? " In this sandboxed edition that includes every folder macOS protects separately; those need Full Disk Access in addition to the access you allowed." : ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.app.hasFullDiskAccess {
                    Button("Grant Full Disk Access…") { model.app.openFullDiskAccessSettings() }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func row(_ color: Color, _ title: String, _ bytes: UInt64) -> some View {
        GridRow {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text(title)
            Text(Format.bytes(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
        }
    }
}

struct IssuesPopover: View {
    let model: WindowModel
    let summary: ScanSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(Format.counted(summary.totalIssueCount, singular: "folder", plural: "folders")) could not be read")
                .font(.headline)
            Text(summary.permissionDeniedCount > 0 && !model.app.hasFullDiskAccess
                ? (model.app.isSandboxed
                    ? "Their contents are missing from the map. Most are protected by macOS separately from the access you allowed for this location: such folders need Full Disk Access as well. After switching it on, rescan to see whether they are included."
                    : "Their contents are missing from the map. Most are protected by macOS; granting Full Disk Access and rescanning includes them.")
                : "Their contents are missing from the map.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(Array(summary.issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 1) {
                    Text(issue.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(issue.path)
            }
            .listStyle(.bordered)
            .frame(height: min(260, CGFloat(summary.issues.count) * 40 + 12))
            if summary.totalIssueCount > summary.issues.count {
                Text("Showing the first \(Format.count(summary.issues.count)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.app.hasFullDiskAccess {
                Button("Grant Full Disk Access…") { model.app.openFullDiskAccessSettings() }
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

// MARK: - Trash confirmation

struct TrashSheet: View {
    let model: WindowModel
    let request: TrashRequest

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 40))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text("This frees about \(Format.bytes(request.totalSize)) (\(Format.files(request.totalFiles))). You can put the items back from the Trash until it is emptied.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            List(request.items.prefix(100)) { item in
                HStack(spacing: 8) {
                    Image(nsImage: IconCache.shared.icon(
                        forExtension: FileKinds.normalizedExtension(ofName: item.name), isDirectory: item.isDirectory,
                        customIconPath: item.isDirectory && IconCache.customIconExtensions.contains(FileKinds.normalizedExtension(ofName: item.name)) ? item.path : nil))
                        .resizable()
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text((item.path as NSString).deletingLastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    Text(Format.bytes(item.size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered)
            .frame(height: min(220, CGFloat(min(request.items.count, 100)) * 38 + 10))
            if request.items.count > 100 {
                Text("…and \(Format.count(request.items.count - 100)) more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(request.refused, id: \.self) { reason in
                Label("\(reason) It stays where it is.", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Don’t ask again", isOn: $model.trashSheetStopsAsking)
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.trashSheetStopsAsking = false
                    model.trashRequest = nil
                }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") { model.performTrash(request) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var title: String {
        if request.items.count == 1 { return "Move “\(request.items[0].name)” to the Trash?" }
        return "Move \(request.items.count) items to the Trash?"
    }
}
