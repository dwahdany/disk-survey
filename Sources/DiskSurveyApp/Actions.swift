import AppKit
import Quartz
import DiskSurveyCore
import DiskSurveyMapView
import DiskSurveyScan

/// What the confirmation sheet shows before items go to the Trash.
struct TrashRequest: Identifiable {
    struct Item: Identifiable, Hashable {
        var node: NodeID
        var name: String
        var path: String
        var size: UInt64
        var isDirectory: Bool
        var fileCount: Int
        var id: NodeID { node }
    }
    var id = UUID()
    var items: [Item]
    var totalSize: UInt64
    var totalFiles: Int
    /// Selected items that are protected (the scan root, volumes, mount points), with the reason.
    var refused: [String]
}

typealias TrashedItem = TrashService.Trashed

/// A menu item that runs a closure.
@MainActor final class ActionMenuItem: NSMenuItem {
    private var handler: (@MainActor () -> Void)?

    convenience init(_ title: String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true, handler: @escaping @MainActor () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        self.handler = handler
        target = self
        isEnabled = enabled
        if !enabled { action = nil }
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @objc private func run() { handler?() }
}

extension WindowModel {
    // MARK: Simple file actions

    var canActOnFiles: Bool { phase != .start && !selectionIsEmpty && !locationMissing }

    var selectedURLs: [URL] {
        guard let tree else { return [] }
        return orderedSelection.prefix(500).filter { !tree.flags(of: $0).contains(.synthetic) }.map { tree.url(of: $0) }
    }

    func revealInFinder() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls.prefix(50)))
    }

    func openSelection() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        if urls.count > 10 {
            let alert = NSAlert()
            alert.messageText = "Open \(urls.count) items?"
            alert.informativeText = "Each item opens in its default application."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard app.isSandboxed else {
            for url in urls { NSWorkspace.shared.open(url) }
            return
        }
        // Sandboxed, opening can be refused; say so instead of doing nothing.
        let refused = urls.filter { !NSWorkspace.shared.open($0) }
        if !refused.isEmpty {
            show(ToastMessage(
                symbol: "exclamationmark.triangle",
                text: refused.count == 1 ? "“\(refused[0].lastPathComponent)” could not be opened" : "\(refused.count) items could not be opened",
                detail: "macOS did not let the sandboxed Disk Survey open it. Reveal it in Finder and open it there."))
        }
    }

    func copyPaths() {
        guard let tree else { return }
        let nodes = orderedSelection.prefix(500).filter { !tree.flags(of: $0).contains(.synthetic) }
        guard !nodes.isEmpty else { return }
        // A name that is not valid UTF-8 has no text form that would lead back to the file;
        // copying the display string would hand out a path that names nothing.
        let paths = nodes.filter { !tree.hasLossyPath($0) }.map { tree.path(of: $0) }
        let skipped = nodes.count - paths.count
        guard !paths.isEmpty else {
            show(ToastMessage(
                symbol: "exclamationmark.triangle", text: "This path can’t be copied",
                detail: "The name is not valid text (UTF-8), so it has no path that could be pasted."), duration: 4)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        show(ToastMessage(
            symbol: "doc.on.doc", text: paths.count == 1 ? "Path copied" : "\(paths.count) paths copied",
            detail: skipped > 0 ? "\(Format.items(skipped)) skipped: the name is not valid text." : nil), duration: skipped > 0 ? 4 : 2)
    }

    func copyNames() {
        guard let tree else { return }
        let names = orderedSelection.prefix(500).filter { !tree.flags(of: $0).contains(.synthetic) }.map { tree.name(of: $0) }
        guard !names.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(names.joined(separator: "\n"), forType: .string)
        show(ToastMessage(symbol: "doc.on.doc", text: names.count == 1 ? "Name copied" : "\(names.count) names copied"), duration: 2)
    }

    func openInTerminal() {
        guard let tree, let node = orderedSelection.first ?? Optional(rootNode) else { return }
        let directory = tree.isDirectory(node) && !tree.flags(of: node).contains(.package) ? node : (tree.parent(of: node) ?? node)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        guard app.isSandboxed else {
            NSWorkspace.shared.open([tree.url(of: directory)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        // Whether the sandbox lets Disk Survey hand a folder to Terminal has not been verified;
        // if it does not, the command must not fail silently.
        NSWorkspace.shared.open([tree.url(of: directory)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let reason = error?.localizedDescription else { return }
            Task { @MainActor in
                self?.show(ToastMessage(
                    symbol: "exclamationmark.triangle", text: "Terminal could not be opened here",
                    detail: "\(reason) The sandboxed Disk Survey may not be allowed to do this; use Copy Path instead."))
            }
        }
    }

    func showInfo() {
        inspectorTab = .info
        preferences.showsInspector = true
    }

    func shareSelection() {
        let urls = selectedURLs
        guard !urls.isEmpty, let view = mapView ?? window?.contentView else { return }
        var anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        if let node = orderedSelection.first, let rect = mapView?.rect(for: node) { anchor = rect }
        NSSharingServicePicker(items: urls).show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    func toggleQuickLook() {
        guard canActOnFiles else { return }
        quickLook.toggle()
    }

    // MARK: Context menu (map and outline)

    func contextMenu() -> NSMenu? {
        guard let tree, phase != .start else { return nil }
        let nodes = orderedSelection
        guard let first = nodes.first else { return nil }
        let live = !locationMissing
        let single = nodes.count == 1
        let isFolder = tree.isDirectory(first)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionMenuItem("Open", symbol: "arrow.up.forward.app", enabled: live) { [weak self] in self?.openSelection() })
        menu.addItem(ActionMenuItem("Reveal in Finder", symbol: "folder", enabled: live) { [weak self] in self?.revealInFinder() })
        menu.addItem(ActionMenuItem("Quick Look", symbol: "eye", enabled: live) { [weak self] in self?.toggleQuickLook() })
        menu.addItem(.separator())
        if single, isFolder, first != rootNode, tree.childCount(of: first) > 0 {
            menu.addItem(ActionMenuItem("Zoom Into “\(tree.name(of: first))”", symbol: "arrow.down.right.and.arrow.up.left") { [weak self] in
                self?.zoom(to: first)
            })
        }
        if canZoomOut {
            menu.addItem(ActionMenuItem("Zoom Out", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in self?.zoomOut() })
        }
        if single, let parent = tree.parent(of: first) {
            menu.addItem(ActionMenuItem("Select Enclosing Folder", symbol: "arrow.turn.left.up") { [weak self] in
                self?.select([parent], primary: parent)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(single ? "Copy Path" : "Copy \(nodes.count) Paths", symbol: "doc.on.doc") { [weak self] in self?.copyPaths() })
        menu.addItem(ActionMenuItem(single ? "Copy Name" : "Copy Names", symbol: "textformat") { [weak self] in self?.copyNames() })
        menu.addItem(ActionMenuItem("Open in Terminal", symbol: "apple.terminal", enabled: live) { [weak self] in self?.openInTerminal() })
        menu.addItem(ActionMenuItem("Get Info", symbol: "info.circle") { [weak self] in self?.showInfo() })
        menu.addItem(ActionMenuItem("Share…", symbol: "square.and.arrow.up", enabled: live) { [weak self] in self?.shareSelection() })
        menu.addItem(.separator())
        if single, isFolder, phase == .loaded {
            menu.addItem(ActionMenuItem("Rescan Folder", symbol: "arrow.clockwise", enabled: live) { [weak self] in
                self?.enqueueMutation { await self?.rescanSubtrees([first], announce: true) }
            })
        }
        menu.addItem(ActionMenuItem("Move to Trash", symbol: "trash", enabled: live && phase == .loaded) { [weak self] in self?.requestTrash() })
        return menu
    }

    // MARK: Trash

    var canTrash: Bool { phase == .loaded && !selectionIsEmpty && !locationMissing }

    /// What `TrashService.review` should know about this window's tree.
    ///
    /// `scanWasCancelled` stays off on purpose: the window only knows that the *first* scan was
    /// stopped, which would refuse every folder — also the ones a later rescan completed.
    /// `TrashService.trash` reads each folder again before moving it and leaves alone exactly
    /// those whose contents differ from the tree, which covers folders of a stopped scan.
    var trashRules: TrashService.Rules {
        var excluded = scanOptionsInUse.excludedPaths
        for path in preferences.excludedPaths where !excluded.contains(path) { excluded.append(path) }
        return TrashService.Rules(
            mountPointPaths: Set(app.volumes.map { $0.url.standardizedFileURL.path }), excludedPaths: excluded,
            excludedPathsFollowSymlinks: scanOptionsInUse.excludedPathsFollowSymlinks)
    }

    /// Asks (or, with confirmation switched off, proceeds) to move items to the Trash: the
    /// selection, or `explicit` nodes when given (rows or tiles that were dragged onto the
    /// Trash, which need not be the selection). The model's selection is not changed.
    /// The scan root, volumes and mount points are never offered.
    func requestTrash(nodes explicit: [NodeID]? = nil) {
        guard phase == .loaded, !locationMissing, let tree else { return }
        let nodes: [NodeID]
        if let explicit {
            // `TrashService.review` drops nodes nested inside other listed nodes itself.
            nodes = explicit.filter { Int($0) < tree.count && !tree.isRemoved($0) }
        } else {
            nodes = topLevelSelection()
        }
        guard !nodes.isEmpty else { return }
        let (candidates, rejected) = TrashService.review(nodes, in: tree, rules: trashRules)
        let items = candidates.map { candidate in
            TrashRequest.Item(
                node: candidate.node, name: tree.name(of: candidate.node), path: candidate.path, size: size(of: candidate.node, in: tree),
                isDirectory: candidate.isDirectory, fileCount: tree.fileCount(of: candidate.node))
        }
        let refused = rejected.map { entry -> String in
            let name = tree.name(of: entry.node)
            return switch entry.reason {
            case .scanRoot: "“\(name)” is the scanned location itself."
            case .mountPoint: "“\(name)” is a volume or mount point."
            case .synthetic: "“\(name)” is not a real file."
            case .removed: "“\(name)” is no longer in the map."
            case .containsMountPoint:
                "“\(name)” contains a mounted volume (“\(((entry.detail ?? "") as NSString).lastPathComponent)”). Eject it first."
            case .containsExcludedPath: "“\(name)” contains an item excluded from scans (\(entry.detail ?? "see Settings"))."
            case .incompleteScan: "The scan was stopped; rescan “\(name)” before moving it to the Trash."
            case .unrepresentableName:
                "“\(name)” has a name that is not valid text (UTF-8), which Disk Survey cannot safely address. Use Finder."
            }
        }
        guard !items.isEmpty else {
            alert = AlertInfo(title: "These items can’t be moved to the Trash", message: refused.joined(separator: "\n"))
            return
        }
        let request = TrashRequest(
            items: items, totalSize: items.reduce(0) { $0 &+ $1.size }, totalFiles: items.reduce(0) { $0 + $1.fileCount },
            refused: refused)
        if preferences.confirmTrash {
            trashSheetStopsAsking = false
            trashRequest = request
        } else {
            performTrash(request)
        }
    }

    /// The sheet's "Move to Trash" button. "Don’t ask again" takes effect only here, so
    /// ticking it and then cancelling changes nothing.
    func performTrash(_ request: TrashRequest) {
        if trashRequest != nil, trashSheetStopsAsking { preferences.confirmTrash = false }
        trashSheetStopsAsking = false
        trashRequest = nil
        enqueueMutation { [weak self] in await self?.runTrash(request) }
    }

    private func runTrash(_ request: TrashRequest) async {
        guard phase == .loaded, let tree else { return }
        guard let scanRoot, FileManager.default.fileExists(atPath: scanRoot.path) else {
            alert = AlertInfo(title: "The scanned location is no longer available", message: "Nothing was moved to the Trash.")
            return
        }
        // The tree may have changed while the sheet was up: keep only items that are still the same node.
        let stillThere = request.items.map(\.node).filter { node in
            Int(node) < tree.count && !tree.isRemoved(node) && request.items.contains { $0.node == node && $0.path == tree.path(of: node) }
        }
        let jobs = TrashService.review(stillThere, in: tree, rules: trashRules).candidates
        guard !jobs.isEmpty else { return }
        // A folder is read again before it moves (about as long as scanning it took).
        let verb = jobs.contains(where: \.isDirectory) ? "Checking and moving" : "Moving"
        setBusy(jobs.count == 1 ? "\(verb) “\(tree.name(of: jobs[0].node))” to the Trash…" : "\(verb) \(jobs.count) items to the Trash…")
        let token = treeGeneration

        let outcome = await Task.detached(priority: .userInitiated) { TrashService().trash(jobs) }.value

        setBusy(nil)
        guard token == treeGeneration, phase == .loaded else { return }
        if !outcome.removedNodes.isEmpty {
            let (mutated, freed) = await Task.detached { () -> (FileTree, FileTree.Totals) in
                var copy = tree
                let freed = TrashService.apply(outcome, to: &copy)
                return (copy, freed)
            }.value
            guard token == treeGeneration else { return }
            adoptMutatedTree(mutated)
            // Put Back needs to know where the item went and to recognize it there.
            lastTrash = outcome.trashed.filter { $0.trashURL != nil && $0.identity != nil }
            if outcome.trashed.isEmpty {
                show(ToastMessage(
                    symbol: "questionmark.folder", text: "Already gone",
                    detail: "\(Format.items(outcome.missing.count)) no longer existed and left the map."))
            } else {
                let amount = sizeMode == .allocated ? freed.allocated : freed.logical
                let count = outcome.trashed.count
                var detail = count == 1 ? "“\((outcome.trashed[0].originalPath as NSString).lastPathComponent)” moved to the Trash" : "\(count) items moved to the Trash"
                // Sandboxed, the Trash usually lies outside what the user allowed, so the item
                // cannot be recognized there and Undo is not offered. Say where to turn instead.
                if app.isSandboxed, lastTrash.count < count {
                    detail += lastTrash.isEmpty
                        ? ". To restore, use Put Back in the Finder’s Trash: the sandbox keeps Disk Survey out of it."
                        : ". Undo covers \(lastTrash.count) of them; restore the others with Put Back in the Finder’s Trash."
                }
                show(ToastMessage(
                    symbol: "trash", text: "Freed \(Format.bytes(amount))", detail: detail,
                    actionTitle: lastTrash.isEmpty ? nil : "Undo", action: lastTrash.isEmpty ? nil : .undoTrash))
            }
        }
        if !outcome.failures.isEmpty {
            let changed = outcome.failures.contains { $0.reason == .changedSinceScan }
            let holdsVolume = outcome.failures.contains { $0.reason == .containsMountPoint }
            var message =
                changed
                ? "Some items no longer match the scan (they changed, the scan was stopped early, or they hold excluded items), so Disk Survey left them alone. Rescan the folder and try again."
                : "The items were left where they are."
            if holdsVolume { message += " A folder that contains a mounted volume can be moved once the volume is ejected." }
            alert = AlertInfo(
                title: outcome.failures.count == 1 ? "An item could not be moved to the Trash" : "\(outcome.failures.count) items could not be moved to the Trash",
                message: message,
                paths: outcome.failures.map { "\($0.path) — \($0.message)" }, offersRescan: changed)
        }
    }

    /// Puts the most recently trashed items back and rescans their folders.
    func undoTrash() {
        let items = lastTrash
        guard !items.isEmpty else { return }
        lastTrash = []
        enqueueMutation { [weak self] in await self?.runUndoTrash(items) }
    }

    private func runUndoTrash(_ items: [TrashedItem]) async {
        guard phase == .loaded else { return }
        setBusy("Putting back \(Format.items(items.count))…")
        let (restored, failed) = await Task.detached { TrashService.putBack(items) }.value
        let failures = failed.map { "\($0.path) — \($0.message)" }
        setBusy(nil)
        if let tree, !restored.isEmpty {
            // Rescan each affected folder once; a folder inside another affected folder is covered by it.
            var parents: [NodeID] = []
            for path in Set(restored.map { ($0 as NSString).deletingLastPathComponent }) {
                if let node = tree.node(atPath: path), !parents.contains(node) { parents.append(node) }
            }
            let outer = parents.filter { node in !parents.contains { $0 != node && tree.isAncestor($0, of: node) } }
            await rescanSubtrees(outer, announce: false)
            if let current = self.tree {
                let nodes = restored.compactMap { current.node(atPath: $0) }
                if !nodes.isEmpty { select(Set(nodes), primary: nodes.first) }
            }
            show(ToastMessage(symbol: "arrow.uturn.backward", text: "Put back \(Format.items(restored.count))"))
        }
        if !failures.isEmpty {
            alert = AlertInfo(
                title: "Some items could not be put back", message: "They are still in the Trash.", paths: failures)
        }
    }

    /// Removes nodes whose files no longer exist (after a drag that moved them elsewhere).
    func reconcileMissing(_ nodes: [NodeID]) {
        enqueueMutation { [weak self] in
            guard let self, self.phase == .loaded, let tree = self.tree else { return }
            // The exact bytes, not the display path: a name that is not valid UTF-8 would look
            // missing under its `String` spelling and be dropped from the tree for no reason.
            let candidates = nodes.filter { Int($0) < tree.count && !tree.isRemoved($0) && $0 != tree.root }
                .map { ($0, tree.fileSystemPath(of: $0) + [0]) }
            let token = self.treeGeneration
            let result = await Task.detached { () -> FileTree? in
                var info = stat()
                let gone = candidates.filter { candidate in
                    candidate.1.withUnsafeBufferPointer { bytes in
                        bytes.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { lstat($0, &info) != 0 && errno == ENOENT }
                    }
                }.map(\.0)
                guard !gone.isEmpty else { return nil }
                var copy = tree
                copy.remove(gone)
                return copy
            }.value
            if let result, token == self.treeGeneration { self.adoptMutatedTree(result) }
        }
    }
}

// MARK: - Quick Look

/// Feeds the shared Quick Look panel from a window's selection.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private unowned let model: WindowModel
    private var urls: [URL] = []
    private var nodes: [NodeID] = []
    private(set) var controlsPanel = false

    init(model: WindowModel) { self.model = model }

    var isVisible: Bool {
        controlsPanel && QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            refreshItems()
            guard !urls.isEmpty else { return }
            panel.makeKeyAndOrderFront(nil)
            // Normally the panel finds `QuickLookResponder` through the responder chain. If it
            // found no controller at all (no key window), feed it directly.
            if !controlsPanel, panel.dataSource == nil {
                begin(panel)
                panel.reloadData()
            }
        }
    }

    private func refreshItems() {
        guard let tree = model.tree else {
            urls = []
            nodes = []
            return
        }
        nodes = Array(model.orderedSelection.prefix(200)).filter { !tree.flags(of: $0).contains(.synthetic) }
        urls = nodes.map { tree.url(of: $0) }
    }

    func reload() {
        guard isVisible else { return }
        refreshItems()
        QLPreviewPanel.shared().reloadData()
    }

    func begin(_ panel: QLPreviewPanel) {
        controlsPanel = true
        refreshItems()
        panel.dataSource = self
        panel.delegate = self
    }

    func end(_ panel: QLPreviewPanel) {
        controlsPanel = false
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    /// Arrow keys keep driving the selection in the window behind the panel, as in Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, let responder = model.window?.firstResponder else { return false }
        switch event.specialKey {
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            responder.keyDown(with: event)
            return true
        default:
            return false
        }
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = item as? NSURL, let index = urls.firstIndex(of: url as URL), nodes.indices.contains(index),
            let rect = model.mapView?.screenRect(for: nodes[index])
        else { return .zero }
        return rect
    }
}

/// Sits behind a window in the responder chain and claims the Quick Look panel for that
/// window's selection. The panel looks for its controller along the chain, which the SwiftUI
/// content does not otherwise take part in.
final class QuickLookResponder: NSResponder {
    weak var model: WindowModel?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { model?.canActOnFiles ?? false }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { model?.quickLook.begin(panel) }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { model?.quickLook.end(panel) }
    }
}
