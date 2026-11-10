import AppKit
import Observation
import SwiftUI

/// A small panel that floats above System Settings and holds the app's icon, ready to be
/// dragged into the Full Disk Access list. It stands in for "reveal the app in Finder, then
/// drag it from there".
@MainActor
final class AppDragPanel {
    static let shared = AppDragPanel()
    private static let size = NSSize(width: 230, height: 190)
    private static let gap: CGFloat = 14
    private var panel: NSPanel?
    private let placement = Placement()
    private var follower: Task<Void, Never>?

    @MainActor @Observable
    final class Placement {
        enum Side { case right, left, inside, none }
        var side = Side.none
    }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "Full Disk Access"
        panel.level = .floating
        // System Settings becomes the active app; the panel has to stay while it is.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = NSHostingView(rootView: AppDragPanelContent(placement: placement))
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - Self.size.width / 2, y: area.minY + 60))
        }
        self.panel = panel
        panel.orderFrontRegardless()
        follow()
    }

    func close() {
        follower?.cancel()
        follower = nil
        panel?.close()
        panel = nil
        placement.side = .none
    }

    /// Keeps the panel beside the System Settings window: macOS lets an app read where another
    /// app's windows are, not move them, so the panel is the one that follows. Ends when the
    /// panel is closed, and closes the panel once a Settings window that was there is gone.
    private func follow() {
        follower?.cancel()
        follower = Task { [weak self] in
            var seen = false
            var missing = 0
            while !Task.isCancelled {
                guard let self, let panel = self.panel, panel.isVisible else { break }
                if let target = Self.settingsWindowFrame() {
                    seen = true
                    missing = 0
                    self.place(panel, beside: target)
                } else if seen {
                    missing += 1
                    if missing > 8 { break }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if !Task.isCancelled { self?.close() }
        }
    }

    private func place(_ panel: NSPanel, beside target: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: target.maxX + Self.gap, y: target.midY - size.height / 2)
        var side = Placement.Side.right
        if origin.x + size.width > area.maxX {
            origin.x = target.minX - Self.gap - size.width
            side = .left
        }
        if origin.x < area.minX {
            // No room on either side: sit in the window's lower right corner.
            origin = NSPoint(x: target.maxX - size.width - 20, y: target.minY + 20)
            side = .inside
        }
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        if placement.side != side { placement.side = side }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    /// The frame, in AppKit screen coordinates, of the System Settings window on screen.
    private static func settingsWindowFrame() -> NSRect? {
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first
        else { return nil }
        var best: CGRect?
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == settings.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 200, rect.height > 200
            else { continue }
            if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
        }
        guard let best else { return nil }
        // Window bounds are measured from the top left of the primary screen.
        return NSRect(x: best.minX, y: primary.frame.maxY - best.maxY, width: best.width, height: best.height)
    }
}

private struct AppDragPanelContent: View {
    let placement: AppDragPanel.Placement

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if placement.side == .right { arrow("arrow.left") }
                AppIconDragSource()
                    .frame(width: 72, height: 72)
                    .help("Drag into the Full Disk Access list")
                if placement.side == .left { arrow("arrow.right") }
            }
            Text("Drag Disk Survey into the list")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Drop it on the Full Disk Access list, then switch it on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .frame(width: 230, height: 190)
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
    }
}

/// The app's icon as a drag source that carries the app bundle's file URL.
struct AppIconDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> AppIconDragView { AppIconDragView() }
    func updateNSView(_ view: AppIconDragView, context: Context) {}
}

final class AppIconDragView: NSImageView, NSDraggingSource {
    private let bundleURL = Bundle.main.bundleURL

    init() {
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityLabel("Disk Survey, drag into the Full Disk Access list")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // The panel never becomes key, so the first click has to start the drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        // Swallowed: NSImageView would otherwise track the click itself.
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }
}
