import AppKit
import Carbon.HIToolbox
import Quartz
import SwiftUI
import DiskSurveyCore

@main
struct DiskSurveyApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let app = AppModel.shared

    init() {
        // AppKit would treat a bare path argument as a document to open, and SwiftUI then
        // shows no window at all. `DiskSurvey <path>` is handled by `LaunchOptions` instead.
        // A scan lives only in memory, so there is nothing to restore after a crash, a forced
        // quit or a restart with "reopen windows". Left on, AppKit starts in restoration mode,
        // SwiftUI then discards the restored windows (`restorationBehavior(.disabled)`), and the
        // app comes up with no window at all.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO", "NSQuitAlwaysKeepsWindows": false])
    }

    var body: some Scene {
        WindowGroup(id: "scan", for: UUID.self) { $id in
            RootView(model: app.windowModel(for: id))
        } defaultValue: {
            UUID()
        }
        .defaultSize(width: 1320, height: 840)
        .restorationBehavior(.disabled)
        .commands { DiskSurveyCommands(app: app) }

        Settings {
            SettingsView(app: app, state: app.settingsState)
        }

        Window("Disk Survey Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 560, height: 640)
        .restorationBehavior(.disabled)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Launched as a bare executable (development, the harness) there is no Info.plist to
        // make this a regular app with a Dock icon and menu bar.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            // Run from the checkout: borrow the icon the bundle would have.
            if let icon = NSImage(contentsOfFile: "Resources/AppIcon-1024.png") { NSApp.applicationIconImage = icon }
        }
        NSWindow.allowsAutomaticWindowTabbing = true
        installOpenHandler()
        switch LaunchOptions.current.appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    /// SwiftUI's own handling of "open documents" does not reach a `WindowGroup` keyed by a
    /// value, so the Apple event (Dock drop, `open -a "Disk Survey" <folder>`, Open With) is taken
    /// here directly.
    private func installOpenHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleOpenDocuments(_:reply:)), forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        var descriptors: [NSAppleEventDescriptor] = []
        if direct.numberOfItems > 0 {
            for index in 1 ... direct.numberOfItems {
                if let item = direct.atIndex(index) { descriptors.append(item) }
            }
        } else {
            descriptors = [direct]
        }
        let urls = descriptors.compactMap { descriptor -> URL? in
            guard let data = descriptor.coerce(toDescriptorType: typeFileURL)?.data else { return nil }
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        application(NSApp, open: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installOpenHandler()
        if Bundle.main.bundleIdentifier == nil { NSApp.activate() }
        SnapshotHarness.shared.applicationLaunched()
        AppModel.shared.ensureWindowAfterLaunch()
    }

    /// Dock drops, `open -a "Disk Survey" <folder>` and "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        // The harness passes file paths as option values; AppKit may mistake one for a document.
        guard !LaunchOptions.current.isHarness || LaunchOptions.current.scanPath == nil else { return }
        for url in urls where url.isFileURL { AppModel.shared.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// MARK: - Menu bar

/// What the menu bar needs to know about the frontmost window.
struct CommandState: Equatable {
    var hasScan = false
    var loaded = false
    var scanning = false
    var canAct = false
    var canTrash = false
    var canUndoTrash = false
    var canGoBack = false
    var canGoForward = false
    var canZoomOut = false
    var canZoomIn = false
    var locationMissing = false
    /// The keyboard focus is in editable text (see `AppModel.textEditing`).
    var textEditing = false

    // Commands whose shortcut is also a text-editing key. AppKit offers a ⌘ keystroke to the
    // menu before the text being edited, and an enabled item takes it: ⌘⌫ in the search field
    // would trash the selection instead of deleting to the start of the line. A disabled item
    // lets the keystroke through.
    var allowsTrashCommand: Bool { canTrash && !textEditing }
    var allowsEnclosingFolderCommand: Bool { canZoomOut && !textEditing }
    var allowsZoomIntoSelectionCommand: Bool { canZoomIn && !textEditing }
}

/// A menu command whose enabled state follows the frontmost window.
///
/// The state is read inside a view body on purpose: a `Commands` body is not re-evaluated when
/// an observable model changes, so `.disabled(...)` computed there froze at its launch-time
/// value and left Rescan, Quick Look, Move to Trash and the rest permanently dimmed.
private struct WindowCommand: View {
    let app: AppModel
    let title: String
    let enabled: (CommandState) -> Bool
    let action: @MainActor (WindowModel) -> Void

    init(_ title: String, app: AppModel, enabled: @escaping (CommandState) -> Bool, action: @escaping @MainActor (WindowModel) -> Void) {
        self.app = app
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(title) {
            if let model = app.activeWindow { action(model) }
        }
        .disabled(!enabled(app.commandState))
    }
}

/// "Open Recent", rebuilt whenever the list of recent scans changes.
private struct RecentsMenu: View {
    let app: AppModel

    var body: some View {
        Menu("Open Recent") {
            ForEach(app.recents) { recent in
                Button(recent.path) { app.open(URL(fileURLWithPath: recent.path)) }
            }
            if !app.recents.isEmpty { Divider() }
            Button("Clear Menu") { app.clearRecents() }
                .disabled(app.recents.isEmpty)
        }
    }
}

private struct InspectorTabMenu: View {
    let app: AppModel

    var body: some View {
        Menu("Inspector Tab") {
            tab("Kinds", .kinds, key: "1")
            tab("Largest Files", .largest, key: "2")
            tab("Info", .info, key: "3")
        }
        .disabled(!app.commandState.hasScan)
    }

    private func tab(_ title: String, _ tab: InspectorTab, key: KeyEquivalent) -> some View {
        Button(title) {
            app.activeWindow?.inspectorTab = tab
            app.preferences.showsInspector = true
        }
        .keyboardShortcut(key, modifiers: [.command, .option])
    }
}

/// View › Map Depth: the level of detail, and one step less or more. A view of its own so the
/// items' enabled state follows the setting (see `WindowCommand`).
private struct DepthMenu: View {
    let preferences: Preferences

    var body: some View {
        @Bindable var preferences = preferences
        Menu("Map Depth") {
            Picker("Map Depth", selection: $preferences.mapDepth) {
                ForEach(MapDepth.choices, id: \.self) { Text(MapDepth.title($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Button("Fewer Folder Levels") {
            if let depth = MapDepth.less(than: preferences.mapDepth) { preferences.mapDepth = depth }
        }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(MapDepth.less(than: preferences.mapDepth) == nil)
        Button("More Folder Levels") {
            if let depth = MapDepth.more(than: preferences.mapDepth) { preferences.mapDepth = depth }
        }
        .keyboardShortcut("+", modifiers: .command)
        .disabled(MapDepth.more(than: preferences.mapDepth) == nil)
        Button("All Folder Levels") { preferences.mapDepth = MapDepth.all }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(preferences.mapDepth == MapDepth.all)
    }
}

struct DiskSurveyCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Commands exist before any window does, so this is where AppKit entry points (a
        // folder dropped on the Dock icon at launch) get their way to open a window.
        let _ = app.adoptOpenWindow(openWindow)
        @Bindable var preferences = app.preferences

        CommandGroup(replacing: .newItem) {
            Button("New Window") { app.openNewWindow() }
                .keyboardShortcut("n")
            Button("Open…") { app.chooseFolder(for: app.activeWindow) }
                .keyboardShortcut("o")
            RecentsMenu(app: app)
            Divider()
            WindowCommand("Rescan Folder", app: app, enabled: { $0.loaded && !$0.locationMissing }) { $0.rescan() }
                .keyboardShortcut("r")
            WindowCommand("Rescan Everything", app: app, enabled: { $0.loaded && !$0.locationMissing }) { $0.rescan(whole: true) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            WindowCommand("Stop Scan", app: app, enabled: { $0.scanning }) { $0.cancelScan() }
                .keyboardShortcut(".")
        }
        CommandGroup(after: .saveItem) {
            Divider()
            WindowCommand("Open Item", app: app, enabled: { $0.canAct }) { $0.openSelection() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            WindowCommand("Reveal in Finder", app: app, enabled: { $0.canAct }) { $0.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            WindowCommand("Quick Look", app: app, enabled: { $0.canAct }) { $0.toggleQuickLook() }
                .keyboardShortcut("y")
            WindowCommand("Open in Terminal", app: app, enabled: { $0.hasScan && !$0.locationMissing }) { $0.openInTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            WindowCommand("Get Info", app: app, enabled: { $0.hasScan }) { $0.showInfo() }
                .keyboardShortcut("i")
            WindowCommand("Share…", app: app, enabled: { $0.canAct }) { $0.shareSelection() }
            Divider()
            WindowCommand("Move to Trash…", app: app, enabled: { $0.allowsTrashCommand }) { model in
                // The menu's state can trail the focus by one event; never trash on a keystroke meant for text.
                guard !AppModel.isEditingText(in: NSApp.keyWindow) else { return }
                model.requestTrash()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            WindowCommand("Put Back Trashed Items", app: app, enabled: { $0.canUndoTrash }) { $0.undoTrash() }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            WindowCommand("Copy Path", app: app, enabled: { $0.canAct }) { $0.copyPaths() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            WindowCommand("Copy Name", app: app, enabled: { $0.canAct }) { $0.copyNames() }
                .keyboardShortcut("c", modifiers: [.command, .control])
            Divider()
            WindowCommand("Find…", app: app, enabled: { $0.hasScan }) { $0.focusSearch() }
                .keyboardShortcut("f")
        }
        CommandGroup(before: .toolbar) {
            Picker("Color By", selection: $preferences.colorMode) {
                Text("Kind").tag(ColorModeSetting.kind).keyboardShortcut("1")
                Text("Age").tag(ColorModeSetting.age).keyboardShortcut("2")
            }
            Picker("Sizes", selection: $preferences.sizeMode) {
                Text("On Disk").tag(SizeMode.allocated)
                Text("Logical").tag(SizeMode.logical)
            }
            Picker("Map Style", selection: $preferences.mapStyle) {
                ForEach(MapStyleSetting.allCases) { Text($0.title).tag($0) }
            }
            DepthMenu(preferences: app.preferences)
            Toggle("Names on the Map", isOn: $preferences.showsLabels)
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Toggle("Packages as Single Items", isOn: $preferences.packagesAsItems)
            Divider()
            Toggle("Outline", isOn: $preferences.showsOutline)
                .keyboardShortcut("s", modifiers: [.command, .option])
            Toggle("Inspector", isOn: $preferences.showsInspector)
                .keyboardShortcut("i", modifiers: [.command, .option])
            InspectorTabMenu(app: app)
            Divider()
        }
        CommandMenu("Go") {
            WindowCommand("Back", app: app, enabled: { $0.canGoBack }) { $0.goBack() }
                .keyboardShortcut("[")
            WindowCommand("Forward", app: app, enabled: { $0.canGoForward }) { $0.goForward() }
                .keyboardShortcut("]")
            Divider()
            WindowCommand("Enclosing Folder", app: app, enabled: { $0.allowsEnclosingFolderCommand }) { $0.zoomOut() }
                .keyboardShortcut(.upArrow)
            WindowCommand("Zoom Into Selection", app: app, enabled: { $0.allowsZoomIntoSelectionCommand }) { $0.zoomIntoSelection() }
                .keyboardShortcut(.downArrow)
            WindowCommand("Zoom to Top", app: app, enabled: { $0.canZoomOut }) { $0.zoomToRoot() }
                .keyboardShortcut("0")
            Divider()
            WindowCommand("Select Enclosing Folder", app: app, enabled: { $0.canAct }) { model in
                if let tree = model.tree, let node = model.orderedSelection.first, let parent = tree.parent(of: node) {
                    model.select([parent], primary: parent)
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Disk Survey Help") { openWindow(id: "help") }
                .keyboardShortcut("?")
            Button("Full Disk Access…") { app.openFullDiskAccessSettings() }
        }
    }
}

// MARK: - Help

struct HelpView: View {
    private static let shortcuts: [(String, String)] = [
        ("Click", "Select a file or folder"),
        ("⌥ Click", "Select the enclosing folder; repeat to go further out"),
        ("Double-click · ⌘↓ · Return", "Zoom into the folder (a folder’s title or block: straight into it)"),
        ("Esc · ⌘↑ · swipe right", "Zoom out one level"),
        ("⌘[  ⌘]", "Back and forward in the zoom history"),
        ("⌘0", "Zoom to the top"),
        ("⌘−  ⌘+  ⌥⌘0", "Show fewer · more · all folder levels in the map"),
        ("Arrow keys", "Move the selection across the map"),
        ("Space · ⌘Y", "Quick Look"),
        ("⇧⌘R", "Reveal in Finder"),
        ("⌥⌘C", "Copy path"),
        ("⌘⌫", "Move to Trash (asks first, unless turned off in Settings)"),
        ("⌘R · ⌥⌘R", "Rescan the folder shown · rescan everything"),
        ("⌘F", "Search; matches stay bright in the map"),
        ("⌘1 · ⌘2", "Color by kind · by age"),
        ("⌥⌘I · ⌥⌘S", "Show or hide the inspector · the outline"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Disk Survey \(DiskSurveyVersion.string)")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text("Every file is a tile whose area is the space it takes on disk. Folders are groups of tiles; colors show the kind of file, or its age. Look for the big tiles, select them, and decide what to keep.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Sizes").font(.headline)
                Text("“On Disk” is what deleting a file gives back. Hard links are counted once, cloud-only files count as zero, and other volumes are not double counted. When you scan a whole volume, the status bar shows how much space the volume uses that Disk Survey cannot see, such as local snapshots.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Full Disk Access").font(.headline)
                Text("macOS hides some folders from apps. Add Disk Survey under System Settings › Privacy & Security › Full Disk Access to include them.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Shortcuts").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    ForEach(Self.shortcuts, id: \.0) { keys, meaning in
                        GridRow {
                            Text(keys)
                                .fontWeight(.medium)
                                .gridColumnAlignment(.trailing)
                            Text(meaning)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 400)
    }
}
