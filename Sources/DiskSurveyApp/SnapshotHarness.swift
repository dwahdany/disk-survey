import AppKit
import QuartzCore
import DiskSurveyCore

/// Self-verification: `--scan <path> --snapshot <out.png>` (and friends, see `LaunchOptions`)
/// drives the app into a state, renders the window into a PNG and exits. Lets the UI be
/// checked from a terminal, without a person at the screen.
@MainActor
final class SnapshotHarness {
    static let shared = SnapshotHarness()

    private let options = LaunchOptions.current
    private var started = false
    private var settingsWindow: NSWindow?
    private var stalls = StallMonitor()

    func applicationLaunched() {
        guard options.isHarness else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        if options.measureStalls { stalls.start() }
        // A harness run must end even if no window ever appears.
        Task {
            try? await Task.sleep(for: .seconds(600))
            FileHandle.standardError.write(Data("disksurvey harness: timed out\n".utf8))
            exit(2)
        }
    }

    func settingsWindowAppeared(_ window: NSWindow) { settingsWindow = window }

    func windowAppeared(_ model: WindowModel) {
        guard options.isHarness, !started else { return }
        started = true
        Task { await run(model) }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func run(_ model: WindowModel) async {
        let preferences = model.preferences
        if let size = options.windowSize, let window = model.window {
            var frame = window.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            window.setFrame(frame, display: true)
        }
        if let show = options.showOutline { preferences.showsOutline = show }
        if options.inspector == "off" { preferences.showsInspector = false }

        if options.selfTest {
            exit(await SelfTest(model: model).run())
        }

        // Give a scan requested on the command line (or by an open-document event) time to start.
        await pause(0.3)
        if let seconds = options.duringScan {
            await pause(seconds)
        } else if let seconds = options.cancelAfter {
            await pause(seconds)
            let requested = Date()
            model.cancelScan()
            while model.phase == .scanning { await pause(0.01) }
            print(String(format: "cancel: settled in %.0f ms, toast: %@", Date().timeIntervalSince(requested) * 1000, model.toast?.text ?? "-"))
        } else {
            while model.phase == .scanning { await pause(0.05) }
        }
        if let summary = model.summary, let tree = model.tree {
            print("scan: \(Format.count(summary.files)) files, \(Format.bytes(summary.size)), \(Format.duration(summary.duration)), nodes \(tree.count), issues \(summary.totalIssueCount)")
        }

        switch options.colorMode {
        case "age": preferences.colorMode = .age
        case "kind": preferences.colorMode = .kind
        default: break
        }
        if let style = options.style.flatMap(MapStyleSetting.init) { preferences.mapStyle = style }
        if let depth = options.depth { preferences.mapDepth = depth }
        if let tree = model.tree {
            if let path = options.zoomPath, let node = tree.node(atPath: path) { model.zoom(to: node) }
            if let path = options.selectPath, let node = tree.node(atPath: path) { model.reveal(node) }
        }
        if let tab = options.inspector.flatMap(InspectorTab.init) {
            preferences.showsInspector = true
            model.inspectorTab = tab
        }
        if let query = options.search {
            // "big:" / "old:" prefixes exercise the filter tokens.
            var text = query
            if text.hasPrefix("big:") {
                text.removeFirst(4)
                model.searchTokens = [SearchToken.sizes[0]]
            }
            model.searchText = text
        }
        if options.showTrashSheet {
            if model.selection.isEmpty, let tree = model.tree, tree.childCount(of: model.rootNode) > 0 {
                let first = tree.child(of: model.rootNode, at: 0)
                model.select([first], primary: first)
            }
            model.requestTrash()
        }
        var target = model.window
        if let pane = options.showSettings {
            model.app.settingsState.tab = SettingsState.Pane(rawValue: pane) ?? .general
            model.app.openSettings?()
            for _ in 0 ..< 40 where settingsWindow == nil { await pause(0.05) }
            target = settingsWindow ?? target
        }

        await pause(options.snapshotDelay)
        if let path = options.hoverPath, let tree = model.tree, let node = tree.node(atPath: path) {
            let shown = model.mapView?.showHover(for: node) ?? false
            print("hover: \(shown ? "shown" : "not on the map") — status: \(model.hover.map { "\(tree.name(of: $0.node)) \(Format.bytes($0.size))" } ?? "-")")
            await pause(0.4)
        }
        // Bundle icons are read off the main thread; the picture should show them.
        if IconCache.shared.hasPendingLoads {
            for _ in 0 ..< 250 where IconCache.shared.hasPendingLoads { await pause(0.02) }
            await pause(0.3)
        }

        if options.exerciseActions { await exerciseActions(model) }
        if options.dumpMenu {
            // SwiftUI validates menu items against the key window, so make sure there is one.
            NSApp.activate()
            model.window?.makeKeyAndOrderFront(nil)
            await pause(0.5)
            print("key window: \(model.window?.isKeyWindow ?? false), main: \(model.window?.isMainWindow ?? false)")
            dumpMenu()
            // Does the Quick Look panel find this window's controller?
            if model.canActOnFiles {
                model.toggleQuickLook()
                await pause(0.6)
                print("quick look: panel visible \(model.quickLook.isVisible), controlled by window \(model.quickLook.controlsPanel)")
                model.toggleQuickLook()
            }
        }
        if options.measureStalls {
            print("after load: \(stalls.report())")
            await exerciseForStalls(model)
        }
        if let path = options.snapshotPath {
            if let window = target, let data = capture(window) {
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                    print("snapshot: \(path)")
                } catch {
                    FileHandle.standardError.write(Data("disksurvey harness: cannot write \(path): \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            } else {
                FileHandle.standardError.write(Data("disksurvey harness: no window to capture\n".utf8))
                exit(1)
            }
        }
        exit(0)
    }

    /// Renders the whole window, title bar and toolbar included, into PNG data.
    ///
    /// The window server's own picture of the window is preferred: it is the only one that
    /// contains glass and vibrancy as the user sees them. An app may always read its own
    /// windows, so this needs no screen-recording permission. If that fails (no window server
    /// session), AppKit's display cache is used; it misses materials but shows the layout.
    private func capture(_ window: NSWindow) -> Data? {
        window.displayIfNeeded()
        CATransaction.flush()
        if let image = serverImage(of: window) {
            let rep = NSBitmapImageRep(cgImage: image)
            if let sheet = window.attachedSheet, let sheetImage = serverImage(of: sheet), let context = NSGraphicsContext(bitmapImageRep: rep) {
                let scale = CGFloat(image.width) / max(1, window.frame.width)
                let origin = CGPoint(x: (sheet.frame.minX - window.frame.minX) * scale, y: (sheet.frame.minY - window.frame.minY) * scale)
                context.cgContext.setFillColor(CGColor(gray: 0, alpha: 0.25))
                context.cgContext.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                context.cgContext.draw(sheetImage, in: CGRect(x: origin.x, y: origin.y, width: CGFloat(sheetImage.width), height: CGFloat(sheetImage.height)))
            }
            print("capture: window server")
            return rep.representation(using: .png, properties: [:])
        }
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView,
            let sheetRep = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        {
            sheetView.cacheDisplay(in: sheetView.bounds, to: sheetRep)
            let origin = NSPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill(using: .sourceOver)
            sheetRep.draw(in: NSRect(origin: origin, size: sheetView.bounds.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        print("capture: display cache (materials not shown)")
        return rep.representation(using: .png, properties: [:])
    }

    /// `CGWindowListCreateImage` for one of our own windows. The function is no longer exposed
    /// to Swift, so it is looked up at run time; a missing symbol simply means "not available".
    private func serverImage(of window: NSWindow) -> CGImage? {
        typealias Function = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard window.windowNumber > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let function = unsafeBitCast(symbol, to: Function.self)
        // CGRectNull, kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        guard let image = function(.null, 1 << 3, UInt32(window.windowNumber), 1 | (1 << 3))?.takeRetainedValue(), image.width > 1, image.height > 1
        else { return nil }
        return Self.isBlank(image) ? nil : image
    }

    /// While the screen is locked the window server hands out an empty picture. Detected by
    /// scaling the image down and looking for any variation at all.
    private static func isBlank(_ image: CGImage) -> Bool {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        var low = UInt8.max, high = UInt8.min
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0 ..< 3 {
                low = min(low, pixels[index + channel])
                high = max(high, pixels[index + channel])
            }
        }
        return high - low < 6
    }

    private func dumpMenu() {
        guard let menu = NSApp.mainMenu else { return }
        print("command state: \(AppModel.shared.commandState), app active: \(NSApp.isActive)")
        for top in menu.items {
            guard let submenu = top.submenu else { continue }
            // What AppKit does before showing a menu: let its delegate rebuild it, then validate.
            submenu.delegate?.menuNeedsUpdate?(submenu)
            submenu.delegate?.menuWillOpen?(submenu)
            submenu.update()
            print("menu \(top.title) (delegate: \(submenu.delegate.map { String(describing: type(of: $0)) } ?? "none"), autoenables: \(submenu.autoenablesItems))")
            for item in submenu.items where !item.isSeparatorItem {
                var key = ""
                if !item.keyEquivalent.isEmpty {
                    let flags = item.keyEquivalentModifierMask
                    key = " [" + (flags.contains(.control) ? "^" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "")
                        + (flags.contains(.command) ? "⌘" : "") + item.keyEquivalent + "]"
                }
                print("  \(item.isEnabled ? "+" : "-") \(item.title)\(key)\(item.hasSubmenu ? " ▸" : "")")
            }
        }
    }

    /// Trash → undo → rescan on a throwaway folder, printing what the tree and the disk say
    /// after each step. Refuses to touch anything but a folder made for the purpose.
    private func exerciseActions(_ model: WindowModel) async {
        guard let root = model.scanRoot, root.lastPathComponent == "disksurvey-action-test", let tree = model.tree,
            tree.childCount(of: 0) > 0
        else {
            print("actions: skipped (scan root must be a folder named disksurvey-action-test)")
            return
        }
        func settle() async {
            await pause(0.2)
            while model.busyMessage != nil { await pause(0.05) }
            await pause(0.3)
        }
        func state(_ label: String) {
            guard let tree = model.tree else { return }
            print("actions: \(label): tree \(Format.exactBytes(tree.size(of: 0))), \(tree.fileCount(of: 0)) files; toast: \(model.toast?.text ?? "-") / \(model.toast?.detail ?? "-"); alert: \(model.alert?.title ?? "-")")
        }
        state("initial")
        let victim = tree.child(of: 0, at: 0)
        let victimPath = tree.path(of: victim)
        model.preferences.confirmTrash = false
        model.select([victim], primary: victim)
        model.requestTrash()
        await settle()
        state("after trash of \(tree.name(of: victim))")
        print("actions: victim exists on disk: \(FileManager.default.fileExists(atPath: victimPath)), undo available: \(model.canUndoTrash)")
        model.undoTrash()
        await settle()
        state("after undo")
        print("actions: victim exists on disk: \(FileManager.default.fileExists(atPath: victimPath)), back in tree: \(model.tree?.node(atPath: victimPath) != nil)")

        // A file that changed after the scan must be left alone.
        if let current = model.tree, let file = current.largestFiles(limit: 1).first {
            let path = current.path(of: file)
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(repeating: 7, count: 5000))
                try? handle.close()
            }
            model.select([file], primary: file)
            model.requestTrash()
            await settle()
            state("trash of a file modified after the scan")
            print("actions: modified file still on disk: \(FileManager.default.fileExists(atPath: path))")
            model.alert = nil
        }
        // A file that vanished is simply dropped from the tree.
        if let current = model.tree, let file = current.largestFiles(limit: 2).last {
            let path = current.path(of: file)
            try? FileManager.default.removeItem(atPath: path)
            model.select([file], primary: file)
            model.requestTrash()
            await settle()
            state("trash of a file deleted behind our back")
        }
        // Rescan of a subfolder picks up new content.
        if let current = model.tree, let folder = current.children(of: 0).first(where: { current.isDirectory($0) }) {
            let path = current.path(of: folder)
            FileManager.default.createFile(atPath: path + "/added-later.bin", contents: Data(repeating: 1, count: 300_000))
            model.zoom(to: folder)
            model.rescan()
            await settle()
            state("after rescan of \(current.name(of: folder))")
            print("actions: new file in tree: \(model.tree?.node(atPath: path + "/added-later.bin") != nil), zoom root kept: \(model.tree.map { $0.path(of: model.rootNode) == path } ?? false)")
        }
        // The scan root itself is protected.
        model.zoomToRoot()
        model.select([0], primary: 0)
        model.requestTrash()
        await pause(0.2)
        print("actions: trash of scan root refused: \(model.alert != nil && FileManager.default.fileExists(atPath: root.path))")
        model.alert = nil
    }

    /// Runs the operations most likely to hitch on a huge tree while the stall monitor
    /// watches, and reports the worst stall of each.
    private func exerciseForStalls(_ model: WindowModel) async {
        guard let tree = model.tree else { return }
        func step(_ label: String, wait: Double, _ body: () -> Void) async {
            stalls.reset()
            body()
            await pause(wait)
            print("  \(label): \(stalls.report())")
        }
        await step("idle", wait: 0.5) {}
        let top = Array(tree.children(of: tree.root).prefix(3))
        for (index, node) in top.enumerated() {
            await step("select top-level #\(index)", wait: 0.3) { model.reveal(node) }
            guard tree.isDirectory(node) else { continue }
            await step("zoom in", wait: 0.5) { model.zoom(to: node) }
            if let child = tree.children(of: node).first {
                await step("select child (\(tree.childCount(of: node)) siblings)", wait: 0.4) { model.reveal(child) }
            }
            await step("zoom out", wait: 0.5) { model.zoomOut() }
        }
        if let deep = model.largest.first {
            await step("reveal largest file (depth \(tree.depth(of: deep.node)))", wait: 0.5) { model.reveal(deep) }
        }
        await step("search 'a'", wait: 1.0) { model.searchText = "a" }
        await step("search 'report'", wait: 1.0) { model.searchText = "report" }
        await step("clear search", wait: 0.5) { model.searchText = "" }
        await step("color by age", wait: 0.6) { model.preferences.colorMode = .age }
        await step("logical sizes", wait: 1.0) { model.preferences.sizeMode = .logical }
        await step("on-disk sizes", wait: 1.0) { model.preferences.sizeMode = .allocated }
        await step("highlight videos", wait: 0.8) {
            model.preferences.colorMode = .kind
            model.toggleCategory(.video, extend: false)
        }
        await step("clear highlight", wait: 0.5) { model.clearKindFilter() }
        await step("inspector: largest", wait: 0.5) { model.inspectorTab = .largest }
        await step("inspector: info", wait: 0.5) { model.inspectorTab = .info }
        stalls.reset()
    }
}

/// Measures how long the main thread goes without servicing its queue: a background thread
/// posts a block every few milliseconds and records how late each one runs.
final class StallMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var worst = 0.0
    private var over50 = 0
    private var over100 = 0
    private var samples = 0
    private var running = false

    func start() {
        lock.lock()
        let already = running
        running = true
        lock.unlock()
        guard !already else { return }
        let thread = Thread { [self] in
            while true {
                let posted = DispatchTime.now().uptimeNanoseconds
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    let delay = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1e6
                    self.record(delay)
                    done.signal()
                }
                done.wait()
                usleep(4000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func record(_ milliseconds: Double) {
        lock.lock()
        samples += 1
        worst = max(worst, milliseconds)
        if milliseconds > 50 { over50 += 1 }
        if milliseconds > 100 { over100 += 1 }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        worst = 0
        over50 = 0
        over100 = 0
        samples = 0
        lock.unlock()
    }

    func report() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(format: "main-thread stalls: worst %.1f ms, over 50 ms: %d, over 100 ms: %d (%d samples)", worst, over50, over100, samples)
    }
}
