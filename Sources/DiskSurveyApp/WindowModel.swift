import AppKit
import Observation
import SwiftUI
import DiskSurveyCore
import DiskSurveyMapView
import DiskSurveyScan
import DiskSurveyTreemap

/// A row of a result list (largest files, search results), captured off the main thread so
/// the list never touches the tree while drawing. `epoch` says which generation of node ids
/// `node` belongs to.
struct FileRow: Identifiable, Hashable, Sendable {
    var node: NodeID
    var epoch: Int
    var name: String
    var location: String
    var size: UInt64
    var isDirectory: Bool
    var ext: String
    var category: KindCategory
    var kind: KindID
    var modified: Int64
    /// Where to read the item's own icon from, for bundles that have one (see `IconCache`).
    var iconPath: String?
    var id: NodeID { node }

    init(tree: FileTree, node: NodeID, epoch: Int, metric: SizeMode) {
        self.node = node
        self.epoch = epoch
        name = tree.name(of: node)
        let parentPath = tree.parent(of: node).map { tree.path(of: $0) } ?? ""
        let root = tree.rootPath
        if parentPath == root {
            location = tree.name(of: tree.root)
        } else if parentPath.hasPrefix(root) {
            location = String(parentPath.dropFirst(root == "/" ? 1 : root.count + 1))
        } else {
            location = parentPath
        }
        size = metric == .allocated ? tree.size(of: node) : tree.logicalSize(of: node)
        isDirectory = tree.isDirectory(node)
        let fileKind = tree.fileKind(of: node)
        ext = fileKind.ext
        category = fileKind.category
        kind = tree.kind(of: node)
        modified = tree.modified(of: node)
        iconPath = IconCache.customIconPath(tree: tree, node: node)
    }
}

/// A filter chip in the search field.
struct SearchToken: Identifiable, Hashable, Sendable {
    enum Filter: Hashable, Sendable {
        case minSize(UInt64)
        case olderThanDays(Int)
        case category(KindCategory)
    }
    var filter: Filter
    var title: String
    var symbol: String
    var id: String { title }

    static let sizes = [
        SearchToken(filter: .minSize(100_000_000), title: "> 100 MB", symbol: "scalemass"),
        SearchToken(filter: .minSize(1_000_000_000), title: "> 1 GB", symbol: "scalemass.fill"),
    ]
    static let ages = [
        SearchToken(filter: .olderThanDays(183), title: "Older than 6 months", symbol: "clock"),
        SearchToken(filter: .olderThanDays(365), title: "Older than 1 year", symbol: "clock.arrow.circlepath"),
        SearchToken(filter: .olderThanDays(730), title: "Older than 2 years", symbol: "hourglass"),
    ]
    static let kinds: [SearchToken] = [
        KindCategory.video, .audio, .image, .document, .archive, .code, .application, .diskImage, .buildArtifact,
    ].map { SearchToken(filter: .category($0), title: $0.displayName, symbol: $0.symbolName) }
    static let all = sizes + ages + kinds
}

struct ToastMessage: Identifiable, Equatable {
    enum Action: Equatable { case undoTrash, showIssues, grantAccess }
    var id = UUID()
    var symbol: String
    var text: String
    var detail: String?
    var actionTitle: String?
    var action: Action?
}

struct ScanSummary {
    var duration: TimeInterval
    var files: Int
    var size: UInt64
    var issues: [ScanIssue]
    var totalIssueCount: Int
    var permissionDeniedCount: Int
    var wasCancelled: Bool
    var stats: ScanStats
    var date: Date
}

struct AlertInfo: Identifiable {
    var id = UUID()
    var title: String
    var message: String
    var paths: [String] = []
    var offersRescan = false
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case kinds, largest, info, search
    var id: String { rawValue }
    var title: String {
        switch self {
        case .kinds: "Kinds"
        case .largest: "Largest"
        case .info: "Info"
        case .search: "Search"
        }
    }
    var symbol: String {
        switch self {
        case .kinds: "square.grid.2x2"
        case .largest: "chart.bar.xaxis"
        case .info: "info.circle"
        case .search: "magnifyingglass"
        }
    }
}

enum KindGrouping: String, CaseIterable, Identifiable {
    case category, ext
    var id: String { rawValue }
    var title: String { self == .category ? "Category" : "Extension" }
}

/// Everything one window shows: its scan, the tree, navigation, selection and derived lists.
///
/// The tree is a value; every change (scan snapshot, deletion, partial rescan) assigns a new
/// one. Work that walks the tree runs detached and comes back tagged with a generation, so a
/// result for an older tree is dropped.
@MainActor @Observable
final class WindowModel: Identifiable {
    enum Phase { case start, scanning, loaded }

    nonisolated let id: UUID
    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored let preferences = Preferences.shared
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored weak var mapView: TreemapView?
    @ObservationIgnored weak var outline: OutlineController?
    @ObservationIgnored lazy var quickLook = QuickLookController(model: self)

    // MARK: Scan state

    private(set) var phase = Phase.start
    private(set) var scanRoot: URL?
    private(set) var tree: FileTree?
    /// Bumped whenever `tree` is assigned.
    private(set) var treeGeneration = 0
    /// Bumped whenever node ids of the previous tree stop being valid.
    private(set) var idEpoch = 0
    private(set) var progress = ScanProgress()
    private(set) var summary: ScanSummary?
    /// The volume, when the scan root is a whole volume.
    private(set) var rootVolume: Volume?
    private(set) var busyMessage: String?
    private(set) var locationMissing = false

    @ObservationIgnored private var session: ScanSession?
    /// The options the tree on screen was scanned with (the settings may have changed since).
    @ObservationIgnored private(set) var scanOptionsInUse = ScanOptions()
    @ObservationIgnored private var scanToken = 0
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var mutationTail: Task<Void, Never>?

    // MARK: Navigation and selection

    private(set) var rootNode: NodeID = 0
    private(set) var backStack: [NodeID] = []
    private(set) var forwardStack: [NodeID] = []
    private(set) var selection: Set<NodeID> = [] {
        didSet { if selection.isEmpty != selectionIsEmpty { selectionIsEmpty = selection.isEmpty } }
    }
    /// Changes only when the selection becomes empty or non-empty, so toolbar buttons and
    /// menus that merely need "is anything selected" are not rebuilt on every click.
    private(set) var selectionIsEmpty = true
    private(set) var primarySelection: NodeID?
    var hover: TreemapHover?

    // MARK: Inspector

    var inspectorTab = InspectorTab.kinds
    var kindGrouping = KindGrouping.category { didSet { if kindGrouping != oldValue { clearKindFilter() } } }
    private(set) var kindStats: [KindStat] = []
    private(set) var categoryStats: [CategoryStat] = []
    private(set) var selectedKinds: Set<KindID> = []
    private(set) var selectedCategories: Set<KindCategory> = []
    private(set) var largest: [FileRow] = []
    @ObservationIgnored private var derivedRunning = false
    @ObservationIgnored private var derivedDirty = false

    // MARK: Search

    var searchText = "" { didSet { if searchText != oldValue { searchChanged() } } }
    var searchTokens: [SearchToken] = [] { didSet { if searchTokens != oldValue { searchChanged() } } }
    /// Whether there is a query (text or filters). Stored, and written only when it flips: views
    /// that merely need to know "is a search on" must not be redrawn for every keystroke.
    private(set) var searchIsActive = false
    private(set) var searchRows: [FileRow] = []
    private(set) var searchTotalMatches = 0
    private(set) var searchTotalSize: UInt64 = 0
    private(set) var searchMatches: NodeBitset?
    private(set) var isSearching = false
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var tabBeforeSearch: InspectorTab?
    var searchFocusTick = 0

    // MARK: Transient UI

    var toast: ToastMessage?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    var trashRequest: TrashRequest?
    /// The confirmation sheet's "Don’t ask again" box. Sheet-local: reset for every request and
    /// written to the preferences only when the sheet is confirmed.
    var trashSheetStopsAsking = false
    var alert: AlertInfo?
    var showsIssues = false
    var showsVolumeInfo = false
    var isDropTargeted = false
    @ObservationIgnored var lastTrash: [TrashedItem] = [] { didSet { canUndoTrash = !lastTrash.isEmpty } }
    private(set) var canUndoTrash = false

    init(id: UUID, app: AppModel) {
        self.id = id
        self.app = app
    }

    func tearDown() {
        scanToken += 1
        session?.cancel()
        session = nil
        progressTask?.cancel()
        snapshotTask?.cancel()
        searchTask?.cancel()
        toastTask?.cancel()
    }

    // MARK: Derived values for the views

    var sizeMode: SizeMode { preferences.sizeMode }

    func size(of node: NodeID, in tree: FileTree) -> UInt64 {
        sizeMode == .allocated ? tree.size(of: node) : tree.logicalSize(of: node)
    }

    var title: String {
        guard let scanRoot, phase != .start else { return "Disk Survey" }
        if let rootVolume { return rootVolume.name }
        return scanRoot.path == "/" ? "Startup Disk" : scanRoot.lastPathComponent
    }

    var subtitle: String {
        switch phase {
        case .start: return ""
        case .scanning: return "Scanning…"
        case .loaded:
            guard let tree else { return "" }
            let files = Format.files(tree.fileCount(of: tree.root))
            return "\(Format.bytes(size(of: tree.root, in: tree))) · \(files)"
        }
    }

    var kindFilterIsActive: Bool { !selectedKinds.isEmpty || !selectedCategories.isEmpty }

    var highlight: TreemapHighlight {
        if searchIsActive {
            if let searchMatches { return .matches(searchMatches) }
            return .none
        }
        if !selectedKinds.isEmpty { return .kinds(selectedKinds) }
        if !selectedCategories.isEmpty { return .categories(selectedCategories) }
        return .none
    }

    /// The selection, primary first, then by size; nested items are kept.
    var orderedSelection: [NodeID] {
        guard let tree else { return [] }
        let valid = selection.filter { Int($0) < tree.count && !tree.isRemoved($0) }
        var nodes = valid.sorted { a, b in
            let sa = tree.size(of: a), sb = tree.size(of: b)
            return sa != sb ? sa > sb : a < b
        }
        if let primary = primarySelection, let index = nodes.firstIndex(of: primary), index != 0 {
            nodes.remove(at: index)
            nodes.insert(primary, at: 0)
        }
        return nodes
    }

    /// The selection without items that sit inside another selected item.
    func topLevelSelection() -> [NodeID] {
        guard let tree else { return [] }
        return orderedSelection.filter { node in
            var current = tree.parent(of: node)
            while let ancestor = current {
                if selection.contains(ancestor) { return false }
                current = tree.parent(of: ancestor)
            }
            return true
        }
    }

    var selectionSummary: String? {
        guard let tree, !selection.isEmpty else { return nil }
        let nodes = topLevelSelection()
        guard !nodes.isEmpty else { return nil }
        var total: UInt64 = 0
        for node in nodes { total &+= size(of: node, in: tree) }
        if nodes.count == 1 {
            return "\(tree.path(of: nodes[0])) — \(Format.bytes(total))"
        }
        return "\(Format.items(nodes.count)) selected, \(Format.bytes(total))"
    }

    var canGoBack: Bool { phase == .loaded && !backStack.isEmpty }
    var canGoForward: Bool { phase == .loaded && !forwardStack.isEmpty }
    var canZoomOut: Bool { tree?.parent(of: rootNode) != nil }
    var hasSelection: Bool { !selectionIsEmpty && phase != .start }
    var isLoaded: Bool { phase == .loaded }

    /// Space the volume reports as used that the scan did not find.
    var hiddenSpace: UInt64? {
        guard phase == .loaded, let rootVolume, let tree, summary?.wasCancelled != true else { return nil }
        let scanned = tree.size(of: tree.root)
        return rootVolume.usedCapacity > scanned ? rootVolume.usedCapacity - scanned : 0
    }

    // MARK: Scanning

    func startScan(_ url: URL) {
        let url = url.standardizedFileURL
        tearDown()
        scanToken += 1
        let token = scanToken
        IconCache.shared.invalidatePathIcons(under: url.path)

        scanRoot = url
        phase = .scanning
        locationMissing = false
        progress = ScanProgress()
        summary = nil
        busyMessage = nil
        toast = nil
        hover = nil
        lastTrash = []
        resetNavigation()
        clearSearch()
        selectedKinds = []
        selectedCategories = []
        setTree(nil, idsStable: false)
        let volume = VolumeInfo.volume(containing: url)
        rootVolume = volume.flatMap { $0.url.standardizedFileURL.path == url.path ? $0 : nil }

        scanOptionsInUse = preferences.scanOptions
        let session = ScanSession(root: url, options: scanOptionsInUse)
        self.session = session
        session.start()

        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.scanToken == token, self.phase == .scanning else { return }
                self.progress = session.progress
            }
        }
        // Partial trees for the map and outline. A snapshot costs time proportional to the
        // entries found so far, so the interval stretches as the scan grows.
        // On top of that every snapshot is a second copy of the tree's columns, so past two
        // million entries the map stops refreshing and the counters carry the progress display
        // (see `ScanSession.snapshotDelay`).
        snapshotTask = Task.detached(priority: .utility) { [weak self] in
            var delay = 0.25
            while !session.isFinished, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                if session.isFinished || Task.isCancelled { break }
                let entries = session.progress.entriesScanned
                guard ScanSession.snapshotDelay(entries: entries, lastCost: 0) != nil else {
                    // Too large for live pictures. Look again later: nothing else to do here.
                    delay = 1
                    continue
                }
                let start = Date()
                let snapshot = session.snapshot()
                let cost = Date().timeIntervalSince(start)
                await self?.applySnapshot(snapshot, token: token)
                delay = ScanSession.snapshotDelay(entries: entries, lastCost: cost) ?? 1
            }
        }
        Task { [weak self] in
            let result = await session.result()
            self?.finishScan(result, token: token)
        }
    }

    func cancelScan() {
        guard phase == .scanning else { return }
        session?.cancel()
    }

    private func applySnapshot(_ snapshot: FileTree, token: Int) {
        guard token == scanToken, phase == .scanning else { return }
        replaceTreeCarryingStateByPath(snapshot)
    }

    /// Assigns a tree whose node ids are unrelated to the current one, carrying the zoom root
    /// and (a bounded part of) the selection across by path.
    private func replaceTreeCarryingStateByPath(_ new: FileTree) {
        var rootPath: String?
        var selectionPaths: [String] = []
        var primaryPath: String?
        var hoverPath: String?
        if let old = tree {
            if let hover, Int(hover.node) < old.count { hoverPath = old.path(of: hover.node) }
            if rootNode != 0 { rootPath = old.path(of: rootNode) }
            selectionPaths = selection.prefix(200).map { old.path(of: $0) }
            primaryPath = primarySelection.map { old.path(of: $0) }
        }
        setTree(new, idsStable: false)
        backStack = []
        forwardStack = []
        if let rootPath, let node = new.node(atPath: rootPath), new.isDirectory(node) { rootNode = node } else { rootNode = 0 }
        selection = Set(selectionPaths.compactMap { new.node(atPath: $0) })
        primarySelection = primaryPath.flatMap { new.node(atPath: $0) }.flatMap { selection.contains($0) ? $0 : nil }
        // The hovered item is carried across too, so the status bar does not blink on every
        // scan snapshot. Never as is: its node id belongs to the old tree. (The view follows up
        // with a hover made from the new picture as soon as that is on screen.)
        if var carried = hover, let path = hoverPath, let node = new.node(atPath: path) {
            carried.node = node
            hover = carried
        } else if hover != nil {
            hover = nil
        }
    }

    private func finishScan(_ result: ScanResult, token: Int) {
        guard token == scanToken else { return }
        progressTask?.cancel()
        snapshotTask?.cancel()
        session = nil
        progress = result.tree.count > 1 ? finalProgress(result) : progress

        if result.rootKind == .inaccessible {
            let issue = result.issues.first
            phase = .start
            setTree(nil, idsStable: false)
            alert = AlertInfo(
                title: "“\(scanRoot?.lastPathComponent ?? "Folder")” can’t be scanned",
                message: issue.map { "\($0.message).\n\($0.path)" } ?? "The location could not be read.")
            return
        }
        if result.wasCancelled, result.tree.count <= 1 {
            phase = .start
            setTree(nil, idsStable: false)
            return
        }

        replaceTreeCarryingStateByPath(result.tree)
        phase = .loaded
        let tree = result.tree
        let files = tree.fileCount(of: tree.root)
        summary = ScanSummary(
            duration: result.duration, files: files, size: tree.size(of: tree.root), issues: result.issues,
            totalIssueCount: result.totalIssueCount, permissionDeniedCount: result.permissionDeniedCount,
            wasCancelled: result.wasCancelled, stats: result.stats, date: Date())
        if let volume = rootVolume { rootVolume = VolumeInfo.volume(containing: volume.url) ?? volume }

        // The figures of a finished scan are in the window's subtitle and the path bar, and the
        // duration in the Info tab; a toast repeating them only covers the map. What does need
        // saying is that the result is incomplete.
        if result.wasCancelled {
            let figures = "\(Format.compactCount(files)) files · \(Format.bytes(size(of: tree.root, in: tree))) · \(Format.duration(result.duration))"
            show(ToastMessage(symbol: "stop.circle", text: "Scan stopped — showing partial results", detail: figures))
        } else {
            app.noteRecent(path: scanRoot?.path ?? tree.rootPath, size: tree.size(of: tree.root), fileCount: files)
            if result.totalIssueCount > 0 {
                show(ToastMessage(
                    symbol: "exclamationmark.triangle",
                    text: "\(Format.counted(result.totalIssueCount, singular: "folder", plural: "folders")) could not be read",
                    actionTitle: "Details", action: .showIssues))
            }
        }
        // Select the root's largest child so the inspector and status bar start out useful.
        if selection.isEmpty, app.launch.isHarness == false { /* nothing preselected: the map speaks for itself */ }
    }

    private func finalProgress(_ result: ScanResult) -> ScanProgress {
        var final = session?.progress ?? progress
        final.isFinished = true
        final.elapsed = result.duration
        return final
    }

    /// Development aid (`--synthetic N`): a generated tree, to exercise the UI at sizes no
    /// disk at hand provides.
    func loadSynthetic(nodeCount: Int) {
        tearDown()
        scanToken += 1
        let token = scanToken
        scanRoot = URL(fileURLWithPath: "/Synthetic")
        phase = .scanning
        Task.detached { [weak self] in
            let start = Date()
            let tree = FileTree.synthetic(nodeCount: nodeCount)
            let duration = Date().timeIntervalSince(start)
            await self?.finishSynthetic(tree, duration: duration, token: token)
        }
    }

    private func finishSynthetic(_ tree: FileTree, duration: TimeInterval, token: Int) {
        guard token == scanToken else { return }
        replaceTreeCarryingStateByPath(tree)
        phase = .loaded
        summary = ScanSummary(
            duration: duration, files: tree.fileCount(of: 0), size: tree.size(of: 0), issues: [], totalIssueCount: 0,
            permissionDeniedCount: 0, wasCancelled: false, stats: ScanStats(), date: Date())
    }

    func volumeDisappeared(mountPoint: String) {
        guard let scanRoot, phase != .start else { return }
        let path = scanRoot.path
        guard mountPoint != "/", path == mountPoint || path.hasPrefix(mountPoint + "/") else { return }
        if phase == .scanning { cancelScan() }
        locationMissing = true
        show(ToastMessage(
            symbol: "eject", text: "“\(title)” is no longer available",
            detail: "The map shows the last scan; file actions are disabled."))
    }

    // MARK: Tree assignment

    private func setTree(_ new: FileTree?, idsStable: Bool) {
        tree = new
        treeGeneration += 1
        if !idsStable { idEpoch += 1 }
        if new == nil {
            kindStats = []
            categoryStats = []
            largest = []
        }
        refreshDerived()
        if searchIsActive { runSearch(debounce: false) }
        if quickLook.isVisible { quickLook.reload() }
    }

    /// Runs tree mutations one after another: each starts from the tree the previous one left.
    func enqueueMutation(_ body: @escaping @MainActor () async -> Void) {
        let previous = mutationTail
        mutationTail = Task {
            await previous?.value
            await body()
        }
    }

    /// Replaces the tree after an in-place mutation (ids of surviving nodes unchanged) and
    /// drops references to nodes that no longer exist.
    func adoptMutatedTree(_ new: FileTree) {
        setTree(new, idsStable: true)
        let alive: (NodeID) -> Bool = { Int($0) < new.count && !new.isRemoved($0) }
        if !alive(rootNode) || !new.isDirectory(rootNode) {
            rootNode = backStack.last(where: { alive($0) && new.isDirectory($0) }) ?? 0
        }
        backStack.removeAll { !alive($0) }
        forwardStack.removeAll { !alive($0) }
        let kept = selection.filter(alive)
        if kept.count != selection.count { selection = kept }
        if let primary = primarySelection, !alive(primary) { primarySelection = nil }
        hover = nil
        if let volume = rootVolume { rootVolume = VolumeInfo.volume(containing: volume.url) ?? volume }
    }

    func setBusy(_ message: String?) { busyMessage = message }

    // MARK: Rescan

    /// Rescans the folder shown in the map and splices the result into the tree; the whole
    /// scan when at the top or when asked to.
    func rescan(whole: Bool = false) {
        guard phase == .loaded, let scanRoot, !locationMissing else { return }
        if whole || rootNode == 0 {
            startScan(scanRoot)
        } else {
            let node = rootNode
            enqueueMutation { [weak self] in await self?.rescanSubtrees([node], announce: true) }
        }
    }

    /// Rescans directories and splices each into the tree. Must run inside `enqueueMutation`.
    func rescanSubtrees(_ nodes: [NodeID], announce: Bool) async {
        for node in nodes {
            guard phase == .loaded, let tree, Int(node) < tree.count, !tree.isRemoved(node), tree.isDirectory(node) else { continue }
            let name = tree.name(of: node)
            // A folder whose path holds a name that is not valid UTF-8 cannot be addressed by a
            // `String` path: scanning that would find nothing and take the folder off the map.
            guard !tree.hasLossyPath(node) else {
                if announce {
                    show(ToastMessage(
                        symbol: "exclamationmark.triangle", text: "“\(name)” can’t be rescanned by itself",
                        detail: "Its name is not valid text (UTF-8). Rescan everything instead."))
                }
                continue
            }
            let path = tree.path(of: node)
            busyMessage = "Rescanning “\(name)”…"
            let token = scanToken
            let result = await ScanSession.scan(URL(fileURLWithPath: path), options: preferences.scanOptions)
            guard token == scanToken, phase == .loaded else { return }
            IconCache.shared.invalidatePathIcons(under: path)
            guard result.rootKind == .directory else {
                // The folder is gone: take it out, unless it is the scan root itself.
                if node != tree.root, !FileManager.default.fileExists(atPath: path) {
                    let mutated = await Task.detached { () -> FileTree in
                        var copy = tree
                        copy.remove(node)
                        return copy
                    }.value
                    guard token == scanToken else { return }
                    adoptMutatedTree(mutated)
                }
                continue
            }
            // Selected items below the folder get new ids; find them again by path.
            let selectedPaths = selection.prefix(200).filter { $0 != node && tree.isAncestor(node, of: $0) }.map { tree.path(of: $0) }
            let primaryPath = primarySelection.flatMap { selection.contains($0) ? tree.path(of: $0) : nil }
            let replacement = result.tree
            let (mutated, before, after) = await Task.detached { () -> (FileTree, FileTree.Totals, FileTree.Totals) in
                var copy = tree
                let change = copy.replaceSubtree(at: node, with: replacement)
                return (copy, change.before, change.after)
            }.value
            guard token == scanToken else { return }
            adoptMutatedTree(mutated)
            let restored = selectedPaths.compactMap { mutated.node(atPath: $0) }
            if !restored.isEmpty { selection.formUnion(restored) }
            if let primaryPath, let primary = mutated.node(atPath: primaryPath), selection.contains(primary) {
                primarySelection = primary
            }
            if announce {
                let delta = Int64(after.allocated) - Int64(before.allocated)
                let change: String
                if delta == 0 {
                    change = "no change in size"
                } else {
                    change = "\(Format.bytes(UInt64(abs(delta)))) \(delta > 0 ? "larger" : "smaller")"
                }
                show(ToastMessage(symbol: "arrow.clockwise", text: "Rescanned “\(name)”", detail: "\(Format.bytes(after.allocated)), \(change)"))
            }
        }
        busyMessage = nil
    }

    // MARK: Navigation

    private func resetNavigation() {
        rootNode = 0
        backStack = []
        forwardStack = []
        selection = []
        primarySelection = nil
    }

    /// Shows `node` as the whole map. A file zooms to its folder and gets selected.
    func zoom(to node: NodeID, recordHistory: Bool = true) {
        guard let tree, Int(node) < tree.count, !tree.isRemoved(node) else { return }
        var target = node
        if !tree.isDirectory(node) {
            guard let parent = tree.parent(of: node) else { return }
            target = parent
            select([node], primary: node)
        }
        guard target != rootNode else { return }
        if recordHistory {
            backStack.append(rootNode)
            if backStack.count > 100 { backStack.removeFirst() }
            forwardStack = []
        }
        rootNode = target
        hover = nil
        refreshDerived()
        if searchIsActive { runSearch(debounce: false) }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(rootNode)
        zoom(to: previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(rootNode)
        zoom(to: next, recordHistory: false)
    }

    func zoomOut() {
        guard let parent = tree?.parent(of: rootNode) else { return }
        // The folder we came out of stays selected, so ⌘↓ goes straight back in.
        let child = rootNode
        zoom(to: parent)
        if selection.isEmpty { select([child], primary: child) }
    }

    func zoomToRoot() { zoom(to: 0) }

    var canZoomIntoSelection: Bool {
        guard let tree, let node = orderedSelection.first else { return false }
        if tree.isDirectory(node) { return node != rootNode && tree.childCount(of: node) > 0 }
        return tree.parent(of: node) != rootNode
    }

    func zoomIntoSelection() {
        guard let node = orderedSelection.first else { return }
        zoom(to: node)
    }

    // MARK: Selection

    func select(_ nodes: Set<NodeID>, primary: NodeID? = nil) {
        if nodes != selection { selection = nodes }
        let newPrimary = primary.flatMap { nodes.contains($0) ? $0 : nil }
        if newPrimary != primarySelection { primarySelection = newPrimary }
        if quickLook.isVisible { quickLook.reload() }
    }

    /// Selects a row from a result list: the map zooms out if the item is outside the current
    /// folder, and the outline scrolls to it. Returns false, changing nothing, if the row's node
    /// no longer exists (the list is refreshed off the main thread and can trail the tree).
    @discardableResult
    func reveal(_ row: FileRow) -> Bool {
        guard row.epoch == idEpoch, let tree, Int(row.node) < tree.count, !tree.isRemoved(row.node) else { return false }
        reveal(row.node)
        return true
    }

    /// Runs a selection-based action (reveal in Finder, trash, …) for a row of a result list.
    /// The action only runs if the row could be selected: otherwise it would act on whatever
    /// was selected before, which is not what the user pointed at.
    func act(on row: FileRow, _ action: (WindowModel) -> Void) {
        guard reveal(row) else {
            show(ToastMessage(symbol: "exclamationmark.triangle", text: "That item is no longer in the map"), duration: 2)
            return
        }
        action(self)
    }

    func reveal(_ node: NodeID) {
        guard let tree else { return }
        if node != rootNode, !tree.isAncestor(rootNode, of: node) { zoom(to: 0) }
        select([node], primary: node)
    }

    // MARK: Kinds, largest files

    func toggleKind(_ kind: KindID, extend: Bool) {
        selectedCategories = []
        if extend {
            if selectedKinds.contains(kind) { selectedKinds.remove(kind) } else { selectedKinds.insert(kind) }
        } else {
            selectedKinds = selectedKinds == [kind] ? [] : [kind]
        }
        refreshDerived()
    }

    func toggleCategory(_ category: KindCategory, extend: Bool) {
        selectedKinds = []
        if extend {
            if selectedCategories.contains(category) { selectedCategories.remove(category) } else { selectedCategories.insert(category) }
        } else {
            selectedCategories = selectedCategories == [category] ? [] : [category]
        }
        refreshDerived()
    }

    func clearKindFilter() {
        guard kindFilterIsActive else { return }
        selectedKinds = []
        selectedCategories = []
        refreshDerived()
    }

    func preferencesChanged() { refreshDerived() }

    /// Recomputes the kind legend and the largest-files list for the current folder, off the
    /// main thread. Requests made while one is running collapse into a single follow-up.
    func refreshDerived() {
        guard tree != nil else { return }
        if derivedRunning {
            derivedDirty = true
            return
        }
        derivedRunning = true
        runDerived()
    }

    private func runDerived() {
        guard let tree else {
            derivedRunning = false
            return
        }
        derivedDirty = false
        let generation = treeGeneration
        let epoch = idEpoch
        let root = Int(rootNode) < tree.count && !tree.isRemoved(rootNode) ? rootNode : 0
        let packages = preferences.packagesAsItems
        let metric = sizeMode
        let kinds = selectedKinds
        let categories = selectedCategories
        Task.detached(priority: .userInitiated) { [weak self] in
            let kindStats = tree.kindSummary(under: root)
            let categoryStats = tree.categorySummary(under: root)
            let nodes: [NodeID]
            if !kinds.isEmpty {
                nodes = tree.search(SearchQuery(kinds: kinds, scope: .files), under: root, limit: 200).nodes
            } else if !categories.isEmpty {
                nodes = tree.search(SearchQuery(categories: categories, scope: .files), under: root, limit: 200).nodes
            } else {
                nodes = tree.largestFiles(under: root, limit: 200, packagesAsFiles: packages)
            }
            let rows = nodes.map { FileRow(tree: tree, node: $0, epoch: epoch, metric: metric) }
            await self?.finishDerived(generation: generation, kindStats: kindStats, categoryStats: categoryStats, rows: rows)
        }
    }

    private func finishDerived(generation: Int, kindStats: [KindStat], categoryStats: [CategoryStat], rows: [FileRow]) {
        if generation == treeGeneration || !derivedDirty {
            let logical = sizeMode == .logical
            self.kindStats = logical ? kindStats.sorted { $0.logicalSize > $1.logicalSize } : kindStats
            self.categoryStats = logical ? categoryStats.sorted { $0.logicalSize > $1.logicalSize } : categoryStats
            // Rows of an older id generation are useless (and their ids dangerous).
            self.largest = rows.first.map { $0.epoch == idEpoch } ?? true ? rows : []
        }
        if derivedDirty { runDerived() } else { derivedRunning = false }
    }

    // MARK: Search

    func focusSearch() { searchFocusTick += 1 }

    func clearSearch() {
        searchText = ""
        searchTokens = []
    }

    func toggleToken(_ token: SearchToken) {
        if let index = searchTokens.firstIndex(of: token) {
            searchTokens.remove(at: index)
        } else {
            // One size and one age filter at a time; kinds accumulate.
            switch token.filter {
            case .minSize: searchTokens.removeAll { if case .minSize = $0.filter { true } else { false } }
            case .olderThanDays: searchTokens.removeAll { if case .olderThanDays = $0.filter { true } else { false } }
            case .category: break
            }
            searchTokens.append(token)
        }
    }

    private func searchChanged() {
        let active = !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !searchTokens.isEmpty
        if active != searchIsActive { searchIsActive = active }
        if active {
            if inspectorTab != .search {
                tabBeforeSearch = inspectorTab
                inspectorTab = .search
            }
            runSearch(debounce: true)
        } else {
            searchTask?.cancel()
            searchGeneration += 1
            searchRows = []
            searchMatches = nil
            searchTotalMatches = 0
            searchTotalSize = 0
            isSearching = false
            if inspectorTab == .search { inspectorTab = tabBeforeSearch ?? .kinds }
            tabBeforeSearch = nil
        }
    }

    private var currentQuery: SearchQuery {
        var query = SearchQuery(text: searchText.trimmingCharacters(in: .whitespaces))
        var categories: Set<KindCategory> = []
        let now = Int64(Date().timeIntervalSince1970)
        for token in searchTokens {
            switch token.filter {
            case .minSize(let bytes): query.minSize = max(query.minSize ?? 0, bytes)
            case .olderThanDays(let days):
                let limit = now - Int64(days) * 86_400
                query.modifiedBefore = min(query.modifiedBefore ?? limit, limit)
            case .category(let category): categories.insert(category)
            }
        }
        if !categories.isEmpty { query.categories = categories }
        // Filters describe files; a bare name search finds folders too.
        if !searchTokens.isEmpty { query.scope = .files }
        return query
    }

    private func runSearch(debounce: Bool) {
        searchTask?.cancel()
        guard let tree, searchIsActive else { return }
        searchGeneration += 1
        let generation = searchGeneration
        let epoch = idEpoch
        let query = currentQuery
        let root = Int(rootNode) < tree.count && !tree.isRemoved(rootNode) ? rootNode : 0
        let metric = sizeMode
        isSearching = true
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(180)) }
            if Task.isCancelled { return }
            let result = tree.search(query, under: root, limit: 500)
            // Total without double counting a matching folder and the matches inside it.
            var total: UInt64 = 0
            result.matches.forEach { node in
                var current = tree.parent(of: node)
                while let ancestor = current, ancestor != root {
                    if result.matches.contains(ancestor) { return }
                    current = tree.parent(of: ancestor)
                }
                total &+= metric == .allocated ? tree.size(of: node) : tree.logicalSize(of: node)
            }
            if Task.isCancelled { return }
            let rows = result.nodes.map { FileRow(tree: tree, node: $0, epoch: epoch, metric: metric) }
            await self?.finishSearch(generation: generation, rows: rows, result: result, total: total)
        }
    }

    private func finishSearch(generation: Int, rows: [FileRow], result: SearchResult, total: UInt64) {
        guard generation == searchGeneration else { return }
        searchRows = rows
        searchMatches = result.matches
        searchTotalMatches = result.totalMatches
        searchTotalSize = total
        isSearching = false
    }

    // MARK: Toasts

    func show(_ message: ToastMessage, duration: Double = 6) {
        toastTask?.cancel()
        toast = message
        let id = message.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(message.action == nil ? duration : max(duration, 10)))
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            self.toast = nil
        }
    }

    func performToastAction() {
        guard let action = toast?.action else { return }
        toast = nil
        switch action {
        case .undoTrash: undoTrash()
        case .showIssues: showsIssues = true
        case .grantAccess: app.openFullDiskAccessSettings()
        }
    }
}

// MARK: - Map delegate

extension WindowModel: TreemapViewDelegate {
    func treemapView(_ view: TreemapView, didHover hover: TreemapHover?) {
        if self.hover != hover { self.hover = hover }
    }

    func treemapView(_ view: TreemapView, didChangeSelection selection: Set<NodeID>, primary: NodeID?) {
        select(selection, primary: primary)
    }

    func treemapView(_ view: TreemapView, didRequestZoomTo root: NodeID) {
        guard phase != .start else { return }
        if root == tree?.parent(of: rootNode) { zoomOut() } else { zoom(to: root) }
    }

    func treemapView(_ view: TreemapView, menuFor nodes: [NodeID], clicked: NodeID) -> NSMenu? {
        contextMenu()
    }

    func treemapView(_ view: TreemapView, didRequestQuickLook nodes: [NodeID]) { toggleQuickLook() }

    func treemapView(_ view: TreemapView, didRequestReveal node: NodeID) {
        select([node], primary: node)
        revealInFinder()
    }

    func treemapView(_ view: TreemapView, didRequestTrash nodes: [NodeID]) { requestTrash(nodes: nodes) }

    func treemapView(_ view: TreemapView, didDrag nodes: [NodeID], endedWith operation: NSDragOperation) {
        // Another app moved the files away: drop whatever is no longer there.
        if operation.contains(.move) { reconcileMissing(nodes) }
    }
}
