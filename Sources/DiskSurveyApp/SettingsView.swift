import AppKit
import SwiftUI
import DiskSurveyScan

/// The Settings window (⌘,).
struct SettingsView: View {
    let app: AppModel
    /// Selected tab; lives in a tiny model because view-local state is not available here.
    let state: SettingsState

    var body: some View {
        @Bindable var state = state
        TabView(selection: $state.tab) {
            Tab("General", systemImage: "gearshape", value: SettingsState.Pane.general) { GeneralSettings(preferences: app.preferences) }
            Tab("Scanning", systemImage: "internaldrive", value: SettingsState.Pane.scanning) { ScanningSettings(preferences: app.preferences, state: state) }
            Tab("Appearance", systemImage: "paintpalette", value: SettingsState.Pane.appearance) { AppearanceSettings(preferences: app.preferences) }
        }
        .scenePadding()
        .frame(width: 520)
        .background(SettingsWindowProbe())
    }
}

@MainActor @Observable
final class SettingsState {
    enum Pane: String, Hashable { case general, scanning, appearance }
    var tab = Pane.general
    var selectedExclusion: String?
}

/// Lets the snapshot harness find the Settings window.
private struct SettingsWindowProbe: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { SnapshotHarness.shared.settingsWindowAppeared(window) }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

private struct GeneralSettings: View {
    let preferences: Preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Picker("Sizes show", selection: $preferences.sizeMode) {
                    Text("Space on disk").tag(SizeMode.allocated)
                    Text("Logical file size").tag(SizeMode.logical)
                }
                Toggle("Treat packages as single items", isOn: $preferences.packagesAsItems)
            } footer: {
                Text("Space on disk is what deleting a file gives back. Packages are folders Finder shows as one file, such as apps and photo libraries.")
            }
            Section {
                Toggle("Ask before moving items to the Trash", isOn: $preferences.confirmTrash)
                Toggle("Show space that is not visible to Disk Survey", isOn: $preferences.showHiddenSpace)
            } footer: {
                Text("When a whole volume is scanned, Disk Survey compares what it found with what the volume reports as used, and shows the difference.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 340)
    }
}

private struct ScanningSettings: View {
    let preferences: Preferences
    let state: SettingsState

    var body: some View {
        @Bindable var preferences = preferences
        @Bindable var state = state
        Form {
            Section {
                Toggle("Scan into other volumes mounted inside a folder", isOn: $preferences.crossMountPoints)
                Picker("Threads", selection: $preferences.threadCount) {
                    Text("Automatic (\(ScanOptions.automaticThreadCount))").tag(0)
                    Divider()
                    ForEach([1, 2, 4, 6, 8, 12, 16], id: \.self) { Text("\($0)").tag($0) }
                }
            } footer: {
                Text("Fewer threads are gentler on spinning disks and network volumes.")
            }
            Section("Excluded folders") {
                List(selection: $state.selectedExclusion) {
                    ForEach(preferences.excludedPaths, id: \.self) { path in
                        Label(path, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .tag(path)
                    }
                }
                .frame(minHeight: 96)
                .overlay {
                    if preferences.excludedPaths.isEmpty {
                        Text("Nothing is excluded")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button {
                        addExclusion()
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add excluded folder")
                    Button {
                        if let path = state.selectedExclusion { preferences.excludedPaths.removeAll { $0 == path } }
                        state.selectedExclusion = nil
                    } label: { Image(systemName: "minus") }
                        .disabled(state.selectedExclusion == nil)
                        .accessibilityLabel("Remove excluded folder")
                    Spacer()
                    Text("Excluded folders are left out of every scan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 390)
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            // Shown as the real location (`realpath`, which keeps /private where
            // `resolvingSymlinksInPath` would strip it); any spelling works for the scanner.
            var path = url.standardizedFileURL.path
            if let resolved = realpath(path, nil) {
                path = String(cString: resolved)
                free(resolved)
            }
            if !preferences.excludedPaths.contains(path) { preferences.excludedPaths.append(path) }
        }
    }
}

private struct AppearanceSettings: View {
    let preferences: Preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Picker("Folder frames", selection: Binding(
                    get: { preferences.mapStyle.frames },
                    set: { preferences.mapStyle = MapStyleSetting(frames: $0, gutters: preferences.mapStyle.hasGutters) })
                ) {
                    ForEach(FolderFrames.allCases) { Text($0.title).tag($0) }
                }
                if preferences.mapStyle.frames == .none {
                    Toggle("Thin gutters between folders", isOn: Binding(
                        get: { preferences.mapStyle.hasGutters },
                        set: { preferences.mapStyle = MapStyleSetting(frames: .none, gutters: $0) }))
                }
                Picker("Depth", selection: $preferences.mapDepth) {
                    ForEach(MapDepth.choices, id: \.self) { Text(MapDepth.title($0)).tag($0) }
                }
                Picker("Palette", selection: $preferences.mapPalette) {
                    ForEach(MapPaletteSetting.allCases) { Text($0.title).tag($0) }
                }
                Picker("Color by", selection: $preferences.colorMode) {
                    Text("File kind").tag(ColorModeSetting.kind)
                    Text("Age (last modified)").tag(ColorModeSetting.age)
                }
            } header: {
                Text("Map")
            } footer: {
                Text(framesNote)
            }
            Section("Tiles") {
                LabeledContent("Cushion strength") {
                    HStack {
                        Text("Flat").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $preferences.cushionStrength, in: 0...1.6)
                            .accessibilityLabel("Cushion strength")
                        Text("Deep").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Tile borders", isOn: $preferences.showsTileBorders)
                Toggle("Names on the map", isOn: $preferences.showsLabels)
            }
        }
        .formStyle(.grouped)
        .frame(height: 450)
    }

    private var framesNote: String {
        switch preferences.mapStyle.frames {
        case .adaptive: "Every folder large enough to carry its name gets a frame with name and size, however deep it is. Depth limits how many folder levels the map shows below the current folder."
        case .topLevels: "Only the folders of the first two levels get a frame with name and size. Depth limits how many folder levels the map shows below the current folder."
        case .none: "Folders are told apart by shading alone. Depth limits how many folder levels the map shows below the current folder."
        }
    }
}
