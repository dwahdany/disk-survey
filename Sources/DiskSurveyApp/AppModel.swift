import AppKit
import Observation
import SwiftUI
import DiskSurveyCore
import DiskSurveyScan

/// App-wide state: the open windows, mounted volumes, recent scans and Full Disk Access.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let preferences = Preferences.shared
    let launch = LaunchOptions.current

    var volumes: [Volume] = []
    var recents: [RecentScan] = []
    var hasFullDiskAccess = true
    /// The model of the main window; menu commands act on it.
    var activeWindow: WindowModel?
    /// Whether the keyboard focus is in a text being edited (the search field, above all).
    /// Menu shortcuts that are also editing keys (⌘⌫, ⌘↑, ⌘↓) are switched off meanwhile, so
    /// the keystroke reaches the text instead of acting on the selection in the map.
    private(set) var textEditing = false

    // Not observed: looked up while SwiftUI builds a scene, where publishing a change is not allowed.
    @ObservationIgnored private var windows: [UUID: WindowModel] = [:]
    @ObservationIgnored private var pendingScans: [UUID: URL] = [:]
    @ObservationIgnored private var launchPathConsumed = false
    /// Captured from the first window's environment so AppKit entry points (Dock drops,
    /// `open -a`) can create windows too.
    @ObservationIgnored var openWindow: ((UUID) -> Void)?
    @ObservationIgnored var openSettings: (() -> Void)?
    let settingsState = SettingsState()

    private init() {
        loadRecents()
        refreshEnvironment()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                let unmounted = note.name == NSWorkspace.didUnmountNotification
                MainActor.assumeIsolated {
                    self?.refreshEnvironment()
                    if unmounted, let path { self?.volumeDisappeared(path) }
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEnvironment() }
        }
        // The first responder is not observable app-wide. Windows are sent `update` after every
        // event, which is when the focus can have moved; scan windows also observe their own
        // first responder (see `WindowAccessor`), which catches a focus set from code.
        for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFocus() }
            }
        }
    }

    /// Whether `window`'s first responder is editable text (a field editor or a text view).
    static func isEditingText(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSText)?.isEditable == true
    }

    func refreshFocus() {
        let editing = Self.isEditingText(in: NSApp.keyWindow ?? activeWindow?.window)
        if editing != textEditing { textEditing = editing }
    }

    var commandState: CommandState {
        guard let model = activeWindow, model.phase != .start else { return CommandState() }
        return CommandState(
            hasScan: true, loaded: model.phase == .loaded, scanning: model.phase == .scanning, canAct: model.canActOnFiles,
            canTrash: model.canTrash, canUndoTrash: model.canUndoTrash, canGoBack: model.canGoBack,
            canGoForward: model.canGoForward, canZoomOut: model.canZoomOut, canZoomIn: model.canActOnFiles,
            locationMissing: model.locationMissing, textEditing: textEditing)
    }

    // MARK: Windows

    /// The model for a window id, created on first use. A window opened for a specific folder
    /// finds its scan waiting here.
    func windowModel(for id: UUID) -> WindowModel {
        if let existing = windows[id] { return existing }
        let model = WindowModel(id: id, app: self)
        windows[id] = model
        if let url = pendingScans.removeValue(forKey: id) {
            model.startScan(url)
        } else if !launchPathConsumed {
            // The first window takes the path given on the command line.
            launchPathConsumed = true
            if let count = launch.syntheticNodes {
                model.loadSynthetic(nodeCount: count)
            } else if let path = launch.scanPath {
                model.startScan(URL(fileURLWithPath: path))
            }
        }
        return model
    }

    func windowClosed(_ id: UUID) {
        guard let model = windows.removeValue(forKey: id) else { return }
        model.tearDown()
        if activeWindow === model { activeWindow = nil }
    }

    var openWindows: [WindowModel] { Array(windows.values) }

    /// Scans `url`: in the frontmost window if it is still on the start screen, else in a new one.
    func open(_ url: URL) {
        let idle = activeWindow.flatMap { $0.phase == .start ? $0 : nil } ?? windows.values.first { $0.phase == .start }
        if let active = idle {
            active.startScan(url)
            active.window?.makeKeyAndOrderFront(nil)
        } else {
            openNewWindow(scanning: url)
        }
    }

    func openNewWindow(scanning url: URL? = nil) {
        let id = UUID()
        if let url { pendingScans[id] = url }
        if let openWindow {
            openWindow(id)
        } else {
            // Too early in launch: the menu bar has not been built yet. Try again shortly.
            pendingScans[id] = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.openNewWindow(scanning: url) }
            }
        }
    }

    /// A launch must end with a window on screen. SwiftUI normally opens one, but not when
    /// AppKit believes it is restoring a previous session (saved state left by a crash or a
    /// forced quit): the restored windows are discarded and nothing replaces them.
    func ensureWindowAfterLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.windows.isEmpty, self.pendingScans.isEmpty else { return }
                self.openNewWindow()
            }
        }
    }

    func adoptOpenWindow(_ action: OpenWindowAction) {
        if openWindow == nil { openWindow = { action(id: "scan", value: $0) } }
    }

    func chooseFolder(for model: WindowModel?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Scan"
        panel.message = "Choose a folder or volume to analyze"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if let model, model.phase == .start { model.startScan(url) } else { self?.open(url) }
        }
        if let window = model?.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    // MARK: Environment

    func refreshEnvironment() {
        // The Data volume is part of the startup disk as far as a person is concerned.
        let mounted = VolumeInfo.mounted().filter { !$0.url.path.hasPrefix("/System/Volumes/") }
        if mounted != volumes { volumes = mounted }
        let access = DiskAccess.hasFullDiskAccess()
        if access != hasFullDiskAccess { hasFullDiskAccess = access }
    }

    private func volumeDisappeared(_ path: String) {
        for model in windows.values { model.volumeDisappeared(mountPoint: path) }
    }

    /// Quick locations that exist on this Mac.
    struct Location: Identifiable, Hashable {
        var name: String
        var symbol: String
        var url: URL
        var id: String { url.path }
    }

    var quickLocations: [Location] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result = [
            Location(name: "Home", symbol: "house", url: home),
            Location(name: "Desktop", symbol: "menubar.dock.rectangle", url: home.appending(path: "Desktop")),
            Location(name: "Documents", symbol: "doc", url: home.appending(path: "Documents")),
            Location(name: "Downloads", symbol: "arrow.down.circle", url: home.appending(path: "Downloads")),
            Location(name: "Applications", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")),
            Location(name: "Library", symbol: "building.columns", url: home.appending(path: "Library")),
        ]
        let cloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: cloud.path) {
            result.append(Location(name: "iCloud Drive", symbol: "icloud", url: cloud))
        }
        return result.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    // MARK: Recents

    private static let recentsKey = "recentScans"

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentsKey),
            let decoded = try? JSONDecoder().decode([RecentScan].self, from: data)
        else { return }
        recents = decoded
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: Self.recentsKey) }
    }

    func noteRecent(path: String, size: UInt64, fileCount: Int) {
        // The harness must not leave traces in the user's recents.
        guard !launch.isHarness else { return }
        recents.removeAll { $0.path == path }
        recents.insert(RecentScan(path: path, size: size, fileCount: fileCount, date: Date()), at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        saveRecents()
        NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
    }

    func removeRecent(_ recent: RecentScan) {
        recents.removeAll { $0.path == recent.path }
        saveRecents()
    }

    func clearRecents() {
        recents = []
        saveRecents()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(DiskAccess.fullDiskAccessSettingsURL)
    }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
