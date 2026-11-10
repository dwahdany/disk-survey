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
    /// What is known about Full Disk Access. `unknown` only occurs in the sandboxed edition,
    /// while no folder or disk the user allowed reaches the locations the check looks at.
    private(set) var fullDiskAccess = FullDiskAccess.granted
    /// Whether guidance about Full Disk Access is uncalled for.
    var hasFullDiskAccess: Bool { fullDiskAccess == .granted }
    /// Decides whether a location may be scanned and asks the user when it may not (sandbox).
    let access = AppModel.makeAccessManager()
    /// Whether this is the sandboxed (App Store) edition; see `AppSandbox`.
    var isSandboxed: Bool { access.isSandboxed }
    /// The model of the main window; menu commands act on it.
    var activeWindow: WindowModel?
    /// Whether the keyboard focus is in a text being edited (the search field, above all).
    /// Menu shortcuts that are also editing keys (⌘⌫, ⌘↑, ⌘↓) are switched off meanwhile, so
    /// the keystroke reaches the text instead of acting on the selection in the map.
    private(set) var textEditing = false

    // Not observed: looked up while SwiftUI builds a scene, where publishing a change is not allowed.
    @ObservationIgnored private var windows: [UUID: WindowModel] = [:]
    @ObservationIgnored private var pendingScans: [UUID: (url: URL, access: AccessLease?)] = [:]
    @ObservationIgnored private var launchPathConsumed = false
    /// Captured from the first window's environment so AppKit entry points (Dock drops,
    /// `open -a`) can create windows too.
    @ObservationIgnored var openWindow: ((UUID) -> Void)?
    @ObservationIgnored var openSettings: (() -> Void)?
    let settingsState = SettingsState()

    /// Harness runs keep their grants apart from the user's, as they do with the settings.
    private static func makeAccessManager() -> AccessManager {
        let harness = LaunchOptions.current.isHarness
        let defaults = harness ? UserDefaults(suiteName: "dev.disksurvey.app.harness-grants") ?? .standard : .standard
        let manager = AccessManager(store: .userDefaults(defaults))
        // Nobody is there to click in a harness run: needing the open panel is a failure.
        manager.allowsPanels = !harness
        return manager
    }

    private init() {
        loadRecents()
        refreshEnvironment()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                let unmounted = note.name == NSWorkspace.didUnmountNotification
                MainActor.assumeIsolated {
                    // A disk coming or going says nothing about Full Disk Access. Sandboxed,
                    // asking again would resolve a stored bookmark for nothing.
                    self?.refreshEnvironment(probingAccess: self?.isSandboxed == false)
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
        if let pending = pendingScans.removeValue(forKey: id) {
            model.startScan(pending.url, access: pending.access)
        } else if !launchPathConsumed {
            // The first window takes the path given on the command line.
            launchPathConsumed = true
            if let count = launch.syntheticNodes {
                model.loadSynthetic(nodeCount: count)
            } else if let url = launch.actionFixture ? SnapshotHarness.makeActionFixture() : launch.scanPath.map({ URL(fileURLWithPath: $0) }) {
                if isSandboxed {
                    // A path named on the command line carries no access, and this runs while
                    // SwiftUI builds the scene: no place to put up an open panel.
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.scan(url, in: model, inPlace: true) }
                    }
                } else {
                    model.startScan(url)
                }
            }
        }
        return model
    }

    func windowClosed(_ id: UUID) {
        guard let model = windows.removeValue(forKey: id) else { return }
        model.tearDown()
        model.releaseAccess()
        if activeWindow === model { activeWindow = nil }
    }

    var openWindows: [WindowModel] { Array(windows.values) }

    /// Every way of choosing a scan root ends here: the open panel, a drop on a window or the
    /// Dock icon, an open-document event, a volume card, a folder button, a recent scan, a
    /// rescan of everything and a path on the command line.
    ///
    /// Not sandboxed, the scan starts at once. Sandboxed, the access manager first finds or
    /// asks for a grant that covers `url`; if the user declines, nothing happens.
    ///
    /// - Parameters:
    ///   - model: the window the request came from. It takes the scan while it is still on the
    ///     start screen (or when `inPlace`); otherwise an idle or a new window does.
    ///   - userSelected: the system handed `url` over with access of its own (open panel,
    ///     drop, open-document event), so no further question is needed.
    ///   - inPlace: scan in `model` even though it already shows a scan (rescan).
    ///   - forcePanel: ask for exactly this location although a grant seems to cover it.
    func scan(_ url: URL, in model: WindowModel?, userSelected: Bool = false, inPlace: Bool = false, forcePanel: Bool = false) {
        guard isSandboxed else {
            if let model, inPlace || model.phase == .start { model.startScan(url) } else { open(url, access: nil) }
            return
        }
        let window = (model ?? activeWindow)?.window
        access.obtain(url, userSelected: userSelected, displayName: displayName(for: url), forcePanel: forcePanel, window: window) { [weak self, weak model] granted in
            guard let self else { return }
            guard let granted else {
                // Declined in the panel: stay where we are. In a harness run there is no panel.
                if self.launch.isHarness { SnapshotHarness.shared.needsAccess(to: url) }
                return
            }
            if let model, inPlace || model.phase == .start {
                model.startScan(granted.url, access: granted.lease)
            } else {
                self.open(granted.url, access: granted.lease)
            }
            // A grant may have brought the Full Disk Access probes within reach.
            self.refreshFullDiskAccess()
        }
    }

    /// Scans `url`: in the frontmost window if it is still on the start screen, else in a new one.
    private func open(_ url: URL, access lease: AccessLease?) {
        let idle = activeWindow.flatMap { $0.phase == .start ? $0 : nil } ?? windows.values.first { $0.phase == .start }
        if let active = idle {
            active.startScan(url, access: lease)
            active.window?.makeKeyAndOrderFront(nil)
        } else {
            openNewWindow(scanning: url, access: lease)
        }
    }

    /// A new window; `url` must already be within reach (see `scan`).
    func openNewWindow(scanning url: URL? = nil, access lease: AccessLease? = nil) {
        let id = UUID()
        if let url { pendingScans[id] = (url, lease) }
        if let openWindow {
            openWindow(id)
        } else {
            // Too early in launch: the menu bar has not been built yet. Try again shortly.
            pendingScans[id] = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.openNewWindow(scanning: url, access: lease) }
            }
        }
    }

    /// What to call a location when asking for access to it.
    func displayName(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let volume = volumes.first(where: { $0.url.standardizedFileURL.path == path }) { return volume.name }
        return AccessManager.displayName(for: url)
    }

    /// The name of the startup disk as the Finder shows it.
    var startupDiskName: String { volumes.first(where: \.isRoot)?.name ?? "the startup disk" }

    /// Sandboxed edition: asks once for the whole startup disk, after which every volume card,
    /// folder button and recent scan starts without an open panel.
    func allowStartupDiskAccess(from model: WindowModel?) {
        let name = startupDiskName
        access.requestGrant(for: URL(fileURLWithPath: "/"), displayName: name, window: model?.window) { [weak self] granted in
            guard let self, let granted else { return }
            self.refreshFullDiskAccess()
            let window = model ?? self.activeWindow
            if !granted.remembered {
                window?.show(ToastMessage(
                    symbol: "exclamationmark.shield", text: "Access allowed until Disk Survey quits",
                    detail: "macOS did not let the choice be remembered, so Disk Survey will ask again after the next launch."), duration: 10)
            } else if GrantPath.normalized(granted.url.path(percentEncoded: false)) != "/" {
                // Something else was chosen in the panel. Say what that means.
                window?.show(ToastMessage(
                    symbol: "checkmark.shield", text: "Access allowed for “\(self.displayName(for: granted.url))”",
                    detail: "Other locations still ask. Choose “\(name)” itself to allow everything at once."))
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
            self?.scan(url, in: model, userSelected: true)
        }
        if let window = model?.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    // MARK: Environment

    func refreshEnvironment(probingAccess: Bool = true) {
        // The Data volume is part of the startup disk as far as a person is concerned.
        let mounted = VolumeInfo.mounted().filter { !$0.url.path.hasPrefix("/System/Volumes/") }
        if mounted != volumes { volumes = mounted }
        if probingAccess { refreshFullDiskAccess() }
    }

    func refreshFullDiskAccess() {
        let state: FullDiskAccess
        if isSandboxed {
            // The probes only say something through a grant; one that is merely stored is
            // started for the moment of the check. That only looks at the stored grants: it
            // writes nothing and drops nothing (see `AccessManager.withStoredAccess`).
            let manager = access
            state = manager.withStoredAccess(covering: DiskAccess.probePaths) {
                DiskAccess.fullDiskAccessState { path in manager.isWithinReach(path) }
            }
        } else {
            state = DiskAccess.hasFullDiskAccess() ? .granted : .notGranted
        }
        if state != fullDiskAccess { fullDiskAccess = state }
        if state == .granted { AppDragPanel.shared.close() }
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
        // From the user database: inside the sandbox every other notion of "home" is the
        // app's container.
        let home = URL(fileURLWithPath: AppSandbox.realHomeDirectory, isDirectory: true)
        var result = [
            Location(name: "Home", symbol: "house", url: home),
            Location(name: "Desktop", symbol: "menubar.dock.rectangle", url: home.appending(path: "Desktop")),
            Location(name: "Documents", symbol: "doc", url: home.appending(path: "Documents")),
            Location(name: "Downloads", symbol: "arrow.down.circle", url: home.appending(path: "Downloads")),
            Location(name: "Applications", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")),
            Location(name: "Library", symbol: "building.columns", url: home.appending(path: "Library")),
        ]
        let cloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        if mayExist(cloud.path) {
            result.append(Location(name: "iCloud Drive", symbol: "icloud", url: cloud))
        }
        return result.filter { mayExist($0.url.path) }
    }

    /// Whether a recent scan's location can be offered.
    func isAvailable(_ recent: RecentScan) -> Bool { mayExist(recent.path) }

    /// Whether something is at `path`, as far as can be told. The sandbox lets the existence
    /// of most locations be checked without a grant (measured on macOS 27.2); where it does
    /// not, "cannot tell" must not hide a location the user could still allow.
    private func mayExist(_ path: String) -> Bool {
        if FileManager.default.fileExists(atPath: path) { return true }
        guard isSandboxed else { return false }
        var info = stat()
        return lstat(path, &info) != 0 && (errno == EPERM || errno == EACCES)
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

    /// Scans a recent location chosen from a list that does not check availability first
    /// (File › Open Recent).
    ///
    /// Sandboxed, a location that is not there stops here: asking the access manager for it
    /// would resolve a bookmark on a disk that is not connected, and end in an open panel
    /// pointed at nothing.
    func scanRecent(_ recent: RecentScan, in model: WindowModel?) {
        guard isSandboxed, !isAvailable(recent) else { return scan(URL(fileURLWithPath: recent.path), in: model) }
        let title = "“\(recent.name)” is not available"
        let message = "Nothing is at this location right now. If it is on an external disk or a network volume, connect it and try again."
        if let window = model ?? activeWindow {
            window.alert = AlertInfo(title: title, message: message + "\n" + recent.path)
        } else {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message + "\n" + recent.path
            alert.runModal()
        }
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
        let opened = NSWorkspace.shared.open(DiskAccess.fullDiskAccessSettingsURL)
        // The icon to drag into the list; useful even when the link was refused.
        if !hasFullDiskAccess { AppDragPanel.shared.show() }
        // Sandboxed, the link into System Settings may be refused; point the way in words.
        if !opened, isSandboxed {
            activeWindow?.show(ToastMessage(
                symbol: "lock.shield", text: "Open System Settings yourself",
                detail: "Privacy & Security › Full Disk Access. macOS did not let the sandboxed Disk Survey open it."))
        }
    }

}
