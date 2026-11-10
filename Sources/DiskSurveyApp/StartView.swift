import AppKit
import SwiftUI
import DiskSurveyCore
import DiskSurveyScan

/// The window before a scan: drop a folder, pick a volume, a common folder or a recent scan.
struct StartView: View {
    let model: WindowModel

    private var app: AppModel { model.app }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                if app.isSandboxed {
                    if !AppSandbox.staticReadWritePaths.isEmpty { testAccessCard }
                    // First things first: without a grant the sandbox reads next to nothing.
                    if !app.access.coversStartupDisk { sandboxAccessCard }
                    // Shown once it is known to be missing; "unknown" (nothing allowed yet
                    // reaches the protected folders) is covered by the card above.
                    if app.fullDiskAccess == .notGranted, !app.preferences.fullDiskAccessCardDismissed { accessCard }
                } else if !app.hasFullDiskAccess, !app.preferences.fullDiskAccessCardDismissed {
                    accessCard
                }
                section("Volumes") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(app.volumes) { volume in VolumeCard(model: model, volume: volume) }
                    }
                }
                section("Folders") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(app.quickLocations) { location in
                            Button {
                                app.scan(location.url, in: model)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: location.symbol)
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                        .frame(width: 24)
                                    Text(location.name)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
                                .contentShape(.rect(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .help("Scan \(location.url.path)")
                        }
                    }
                }
                if !app.recents.isEmpty {
                    section("Recent Scans", trailing: {
                        Button("Clear") { app.clearRecents() }
                            .buttonStyle(.link)
                            .font(.callout)
                    }) {
                        VStack(spacing: 0) {
                            ForEach(Array(app.recents.enumerated()), id: \.element.id) { index, recent in
                                if index > 0 { Divider().padding(.leading, 44) }
                                recentRow(recent)
                            }
                        }
                        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { app.chooseFolder(for: model) } label: { Label("Choose Folder…", systemImage: "folder.badge.plus") }
                    .help("Choose a folder to scan (⌘O)")
            }
        }
    }

    // MARK: Pieces

    private var hero: some View {
        HStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("See what fills your disk")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Drop a folder here or pick a location. Disk Survey reads millions of files in seconds and draws them as a map — the bigger the tile, the bigger the file.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    app.chooseFolder(for: model)
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(model.isDropTargeted ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(0.45)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    model.isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary),
                    style: StrokeStyle(lineWidth: model.isDropTargeted ? 2 : 1, dash: [6, 5]))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop a folder or choose a location")
    }

    private var accessCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(app.isSandboxed ? "Protected folders need Full Disk Access as well" : "Give Disk Survey Full Disk Access for complete results")
                    .font(.headline)
                Text(app.isSandboxed
                    ? "Allowing a disk or folder here does not cover what macOS protects separately: Mail, Messages, Safari, the Trash, other apps’ data and more. Those folders need Full Disk Access in addition; without it they are marked as unreadable and are missing from the totals. Disk Survey only reads file names and sizes; nothing leaves your Mac."
                    : "macOS protects Mail, Messages, Photos, other apps’ data and more. Without Full Disk Access those folders show up empty, and macOS may ask for permission folder by folder. Disk Survey only reads file names and sizes; nothing leaves your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings…") { app.openFullDiskAccessSettings() }
                    .help("Opens System Settings and shows the Disk Survey icon to drag into the Full Disk Access list")
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button {
                app.preferences.fullDiskAccessCardDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(16)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.3)))
    }

    /// The harness build (`--sandbox-test-access`) must not pass for the real sandboxed
    /// edition: it reads everything without asking and never shows the open-panel flows.
    private var testAccessCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Test build — not for distribution")
                    .font(.headline)
                Text("This build is signed with a temporary exception that lets it read and write \(AppSandbox.staticReadWritePaths == ["/"] ? "the whole disk" : AppSandbox.staticReadWritePaths.joined(separator: ", ")) without asking. It exists for automated checks only and does not behave like the sandboxed edition: nothing here asks for access.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.red.opacity(0.1), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.red.opacity(0.4)))
        .accessibilityElement(children: .combine)
    }

    /// Sandboxed edition: the one choice that makes everything below a single click.
    private var sandboxAccessCard: some View {
        let disk = app.startupDiskName
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow access to “\(disk)” to scan with one click")
                    .font(.headline)
                Text("This edition of Disk Survey runs in the macOS App Sandbox and can only read the disks and folders you choose. Choose “\(disk)” once, and the volumes, folders and recent scans below start without asking again. Without it, macOS asks you to confirm each location in an open panel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Access to “\(disk)”…") { app.allowStartupDiskAccess(from: model) }
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.tint.opacity(0.08), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.tint.opacity(0.3)))
        .accessibilityElement(children: .contain)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }

    private func section<Trailing: View, Content: View>(
        _ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func recentRow(_ recent: RecentScan) -> some View {
        let exists = app.isAvailable(recent)
        return Button {
            app.scan(URL(fileURLWithPath: recent.path), in: model)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: IconCache.shared.folderIcon)
                    .resizable()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(recent.name)
                    Text(recent.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Format.bytes(recent.size))
                        .monospacedDigit()
                    Text(exists ? Format.relativeDate(Int64(recent.date.timeIntervalSince1970)) : "Not available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(.rect)
            .opacity(exists ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .contextMenu {
            Button("Scan Again") { app.scan(URL(fileURLWithPath: recent.path), in: model) }.disabled(!exists)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recent.path)]) }.disabled(!exists)
            Divider()
            Button("Remove from Recents") { app.removeRecent(recent) }
        }
        .accessibilityLabel("\(recent.name), \(Format.bytes(recent.size))")
    }
}

/// A mounted volume with its capacity split into used, purgeable and free.
struct VolumeCard: View {
    let model: WindowModel
    let volume: Volume

    var body: some View {
        let total = Double(max(volume.totalCapacity, 1))
        let purgeable = volume.purgeableCapacity
        let firmlyUsed = volume.usedCapacity > purgeable ? volume.usedCapacity - purgeable : 0
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: volume.url.path))
                .resizable()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(volume.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if volume.isNetwork { Image(systemName: "network").foregroundStyle(.secondary) }
                    if volume.isReadOnly, !volume.isRoot { Image(systemName: "lock").foregroundStyle(.secondary).help("Read-only") }
                    Spacer(minLength: 4)
                }
                CapacityBar(segments: [
                    .init(id: "used", fraction: Double(firmlyUsed) / total, color: firmlyUsed > UInt64(total * 0.9) ? .red : .accentColor),
                    .init(id: "purgeable", fraction: Double(purgeable) / total, color: .accentColor.opacity(0.35)),
                ])
                .frame(height: 7)
                Text(caption(purgeable: purgeable))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Scan") { model.app.scan(volume.url, in: model) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Scan \(volume.name)")
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
        .contextMenu {
            Button("Scan") { model.app.scan(volume.url, in: model) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([volume.url]) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(volume.name), \(Format.bytes(volume.availableCapacityForImportantUsage)) available of \(Format.bytes(volume.totalCapacity))")
    }

    private func caption(purgeable: UInt64) -> String {
        var text = "\(Format.bytes(volume.availableCapacityForImportantUsage)) available of \(Format.bytes(volume.totalCapacity))"
        if purgeable > volume.totalCapacity / 200 { text += " · \(Format.bytes(purgeable)) purgeable" }
        return text
    }
}
