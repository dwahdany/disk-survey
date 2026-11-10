import AppKit
import Observation
import SwiftUI
import DiskSurveyCore
import UniformTypeIdentifiers

/// Counts of expensive things, read by the self-test (`--self-test`) to check that an
/// operation did not rebuild what it should have reused.
@MainActor enum DebugCounters {
    static var nameCellInits = 0
    static var rowViewsCreated = 0
    static var cellConfigurations = 0
    static var scanViewBodies = 0
    static var toolbarBuilds = 0
    static var pathIconLoads = 0
}

/// File icons.
///
/// An outline over millions of files must never ask the disk for an icon per row, so icons come
/// from the type system: one lookup per extension, then cached. The exception is bundles that
/// carry an icon of their own (applications above all): theirs is read from the bundle, off the
/// main thread and only for rows that are actually shown; until it arrives the type's icon stands in.
///
/// The images AppKit hands out are backed by IconServices and resolve their bitmap again on
/// every assignment to an image view (about 80 µs each). Table rows therefore get a copy
/// rasterized once at 16 pt (`smallIcon`); larger views keep the multi-resolution original.
@MainActor @Observable
final class IconCache {
    static let shared = IconCache()

    /// Posted on the main thread when a bundle's own icon has been loaded; `userInfo["path"]`.
    static let didLoadPathIcon = Notification.Name("DiskSurveyIconCacheDidLoadPathIcon")

    /// Lowercase extensions of packages that usually have their own icon. Frameworks and plain
    /// bundles show the type's icon in Finder too, so they are not worth a disk read.
    nonisolated static let customIconExtensions: Set<String> = ["app", "prefpane", "appex", "plugin", "saver", "qlgenerator"]

    private struct SmallKey: Hashable {
        enum Source: Hashable { case folder, generic, volume, symlink, type(String), path(String) }
        var source: Source
        var dark: Bool
    }

    @ObservationIgnored private var byExtension: [String: NSImage] = [:]
    @ObservationIgnored private lazy var folder = NSWorkspace.shared.icon(for: .folder)
    @ObservationIgnored private lazy var generic = NSWorkspace.shared.icon(for: .data)
    @ObservationIgnored private lazy var volume = NSWorkspace.shared.icon(for: .volume)
    @ObservationIgnored private lazy var symlink = NSWorkspace.shared.icon(for: .symbolicLink)
    @ObservationIgnored private var small: [SmallKey: NSImage] = [:]

    @ObservationIgnored private var byPath: [String: NSImage] = [:]
    @ObservationIgnored private var withoutOwnIcon: Set<String> = []
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private let queue = DispatchQueue(label: "dev.disksurvey.icons", qos: .utility)
    /// Bumped when a bundle icon arrives. Read (only) by lookups that had to fall back to the
    /// type's icon, so that a SwiftUI view showing the stand-in is drawn again.
    private(set) var pathIconRevision = 0
    /// Reads a bundle's icon from disk; nil if there is nothing at the path. Replaceable for tests.
    @ObservationIgnored var loader: @Sendable (String) -> NSImage? = { path in
        // For a path that no longer exists AppKit returns a generic document icon.
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    // MARK: By type

    func icon(forExtension ext: String, isDirectory: Bool) -> NSImage {
        if ext.isEmpty { return isDirectory ? folder : generic }
        let key = isDirectory ? "d." + ext : ext
        if let cached = byExtension[key] { return cached }
        let image: NSImage
        if ext == FileKind.unixExecutableExtension {
            // The pseudo-kind of extensionless executables is not a file name extension.
            image = NSWorkspace.shared.icon(for: .unixExecutable)
        } else if let type = UTType(filenameExtension: ext, conformingTo: isDirectory ? .directory : .data) ?? UTType(filenameExtension: ext) {
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = isDirectory ? folder : generic
        }
        byExtension[key] = image
        return image
    }

    /// The icon for a row that knows its extension and, for a bundle with its own icon, its path.
    func icon(forExtension ext: String, isDirectory: Bool, customIconPath: String?) -> NSImage {
        if let customIconPath, let image = pathIcon(customIconPath) { return image }
        return icon(forExtension: ext, isDirectory: isDirectory)
    }

    func icon(for tree: FileTree, node: NodeID) -> NSImage {
        if let path = Self.customIconPath(tree: tree, node: node), let image = pathIcon(path) { return image }
        return typeIcon(for: tree, node: node).image
    }

    /// A 16 pt bitmap of the node's icon for table rows, drawn for a light or dark appearance.
    func smallIcon(for tree: FileTree, node: NodeID, dark: Bool) -> NSImage {
        if let path = Self.customIconPath(tree: tree, node: node), let image = pathIcon(path) {
            return rasterized(image, key: SmallKey(source: .path(path), dark: dark))
        }
        let (image, source) = typeIcon(for: tree, node: node)
        return rasterized(image, key: SmallKey(source: source, dark: dark))
    }

    var folderIcon: NSImage { folder }

    private func typeIcon(for tree: FileTree, node: NodeID) -> (image: NSImage, source: SmallKey.Source) {
        let flags = tree.flags(of: node)
        if flags.contains(.mountPoint) { return (volume, .volume) }
        if flags.contains(.symlink) { return (symlink, .symlink) }
        let isDirectory = flags.contains(.directory)
        // Only packages keep their extension's icon; "foo.d" directories are plain folders.
        if isDirectory, !flags.contains(.package) { return (folder, .folder) }
        let ext = tree.fileKind(of: node).ext
        if ext.isEmpty { return isDirectory ? (folder, .folder) : (generic, .generic) }
        return (icon(forExtension: ext, isDirectory: isDirectory), .type(isDirectory ? "d." + ext : ext))
    }

    // MARK: Rasterized copies

    private func rasterized(_ image: NSImage, key: SmallKey) -> NSImage {
        if let cached = small[key] { return cached }
        let result = Self.rasterize(image, points: 16, dark: key.dark)
        small[key] = result
        return result
    }

    /// Draws `image` into plain bitmaps at 1x and 2x, so that it stays sharp on either kind of display.
    static func rasterize(_ image: NSImage, points: CGFloat, dark: Bool) -> NSImage {
        let size = NSSize(width: points, height: points)
        let result = NSImage(size: size)
        // Folder and document icons differ between the light and dark appearance.
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            for scale in [1, 2] {
                let pixels = Int(points) * scale
                guard
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { continue }
                // Before the context is made: its coordinates are the rep's points, not its pixels.
                rep.size = size
                guard let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.imageInterpolation = .high
                image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                result.addRepresentation(rep)
            }
        }
        return result
    }

    // MARK: Bundles with their own icon

    /// The path to read a node's own icon from, or nil if the type's icon is the right one.
    /// Cloud-only and unreadable items are left alone: asking for their icon could start a
    /// download or a permission prompt.
    nonisolated static func customIconPath(tree: FileTree, node: NodeID) -> String? {
        let flags = tree.flags(of: node)
        guard flags.contains(.package), flags.isDisjoint(with: [.dataless, .unreadable, .synthetic, .mountPoint, .symlink]) else { return nil }
        guard customIconExtensions.contains(tree.fileKind(of: node).ext) else { return nil }
        return tree.path(of: node)
    }

    /// Whether a load is under way (the snapshot harness waits for these).
    var hasPendingLoads: Bool { !loading.isEmpty }

    /// The bundle's own icon if it has been loaded; otherwise nil, and a load is started.
    private func pathIcon(_ path: String) -> NSImage? {
        if let image = byPath[path] { return image }
        if withoutOwnIcon.contains(path) { return nil }
        _ = pathIconRevision
        guard loading.insert(path).inserted else { return nil }
        DebugCounters.pathIconLoads += 1
        let loader = loader
        // Reading a bundle's icon touches its Info.plist and icon file, and can block on a slow volume.
        queue.async {
            let loaded = LoadedIcon(image: loader(path))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { IconCache.shared.finishLoading(path, loaded.image) }
            }
        }
        return nil
    }

    private func finishLoading(_ path: String, _ image: NSImage?) {
        loading.remove(path)
        guard let image else {
            if withoutOwnIcon.count >= 2000 { withoutOwnIcon.removeAll() }
            withoutOwnIcon.insert(path)
            return
        }
        if byPath.count >= 600 { dropPathIcons { _ in true } }
        byPath[path] = image
        pathIconRevision += 1
        NotificationCenter.default.post(name: Self.didLoadPathIcon, object: self, userInfo: ["path": path])
    }

    /// Forgets the bundle icons at or below `path`: after a rescan an application may be a
    /// different version, or gone.
    func invalidatePathIcons(under path: String) {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        dropPathIcons { $0 == path || $0.hasPrefix(prefix) }
    }

    private func dropPathIcons(where matches: (String) -> Bool) {
        byPath = byPath.filter { !matches($0.key) }
        withoutOwnIcon = withoutOwnIcon.filter { !matches($0) }
        small = small.filter { entry in
            if case .path(let path) = entry.key.source { return !matches(path) }
            return true
        }
    }
}

/// Carries an image from the loading queue to the main thread; it is not touched in between.
private struct LoadedIcon: @unchecked Sendable {
    let image: NSImage?
}

extension RGB {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}

extension ColorScheme {
    var palette: PaletteScheme { self == .dark ? .dark : .light }
}
