import AppKit
import Observation
import DiskSurveyCore
import DiskSurveyScan

/// Regression checks for the app target, run inside the app itself (`--self-test`): the target
/// is an executable without a test bundle, and most of what is checked here (row-view reuse in
/// the outline, focus-dependent menu commands, SwiftUI body evaluations) only exists in a
/// running app with a window.
///
/// Works on a throwaway folder it creates in the temporary directory and on a generated tree.
/// Nothing is ever moved to the Trash: confirmation stays on and requests are discarded.
/// Prints one `PASS`/`FAIL` line per check; the process exits with 1 if any failed.
@MainActor
final class SelfTest {
    private let model: WindowModel
    private var failures = 0
    private var fixture: URL?

    init(model: WindowModel) { self.model = model }

    // MARK: Plumbing

    private func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        let extra = detail()
        print("\(ok ? "PASS" : "FAIL")  \(label)\(extra.isEmpty ? "" : "  [\(extra)]")")
        if !ok { failures += 1 }
    }

    private func note(_ text: String) { print("      \(text)") }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func settle(_ extra: Double = 0.35) async {
        await pause(0.05)
        while model.phase == .scanning || model.busyMessage != nil { await pause(0.02) }
        await pause(extra)
    }

    /// CPU time the main thread has used; unlike wall time it ignores the pauses.
    private func mainThreadCPU() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1e6
    }

    private var outline: OutlineController? { model.outline }

    private func rowNodes() -> [NodeID] {
        guard let view = outline?.outlineView else { return [] }
        return (0 ..< view.numberOfRows).compactMap { (view.item(atRow: $0) as? NSNumber)?.uint32Value }
    }

    private func isExpanded(_ node: NodeID) -> Bool {
        outline?.outlineView.isItemExpanded(NSNumber(value: node)) ?? false
    }

    private func cell<T: NSView>(_ type: T.Type, node: NodeID, column: String) -> T? {
        guard let view = outline?.outlineView else { return nil }
        let row = view.row(forItem: NSNumber(value: node))
        let index = view.column(withIdentifier: NSUserInterfaceItemIdentifier(column))
        guard row >= 0, index >= 0 else { return nil }
        return view.view(atColumn: index, row: row, makeIfNecessary: false) as? T
    }

    private struct Counters {
        var cells: Int, rows: Int, configurations: Int, scanBodies: Int, toolbars: Int, iconLoads: Int

        @MainActor init() {
            cells = DebugCounters.nameCellInits
            rows = DebugCounters.rowViewsCreated
            configurations = DebugCounters.cellConfigurations
            scanBodies = DebugCounters.scanViewBodies
            toolbars = DebugCounters.toolbarBuilds
            iconLoads = DebugCounters.pathIconLoads
        }
    }

    private func delta(since start: Counters) -> Counters {
        var used = Counters()
        used.cells -= start.cells
        used.rows -= start.rows
        used.configurations -= start.configurations
        used.scanBodies -= start.scanBodies
        used.toolbars -= start.toolbars
        used.iconLoads -= start.iconLoads
        return used
    }

    // MARK: Run

    func run() async -> Int32 {
        model.preferences.confirmTrash = true
        model.preferences.showsInspector = true
        model.preferences.showsOutline = true
        commandPredicates()
        do {
            let folder = try makeFixture()
            fixture = folder
            // The way every scan root goes (sandboxed: through the access manager; the fixture
            // is in the temporary folder, which is inside the container).
            model.app.scan(folder, in: model, inPlace: true)
            await settle(0.8)
            if model.tree != nil, model.phase == .loaded {
                accessPlumbing(fixture: folder)
                await scanToast()
                await outlineMetricAndScheme()
                await staleRows()
                await explicitTrashRequests()
                await icons()
                await searchObservation()
                await splitLimits()
                await scanViewBodies()
                await mapDepth()
                await focusAndTrashCommand()
            } else {
                check(false, "fixture scan finished")
            }
        } catch {
            check(false, "fixture created", error.localizedDescription)
        }
        model.loadSynthetic(nodeCount: 300_000)
        await settle(1.0)
        check(model.access == nil, "a window that no longer shows a scanned folder holds no access lease")
        check(model.app.access.outstandingLeases == 0 && model.app.access.scopeStarts == model.app.access.scopeStops,
            "every security scope the app started has been stopped",
            "\(model.app.access.scopeStarts) starts, \(model.app.access.scopeStops) stops, \(model.app.access.outstandingLeases) leases out")
        if model.tree != nil, model.phase == .loaded {
            await revealBatching()
            await liveResize()
        } else {
            check(false, "synthetic tree loaded")
        }
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
        print(failures == 0 ? "self-test: all checks passed" : "self-test: \(failures) check(s) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// A small folder in which on-disk and logical sizes order the entries differently (sparse
    /// files are long but take no space), with a bundle that has an icon of its own.
    private func makeFixture() throws -> URL {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "disksurvey-selftest-\(UUID().uuidString)")
        func dense(_ path: String, _ bytes: Int) throws {
            let url = root.appending(path: path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: bytes).write(to: url)
        }
        func sparse(_ path: String, _ bytes: Int) throws {
            let url = root.appending(path: path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
        }
        try dense("a-dense.bin", 300_000)
        try sparse("b-sparse.bin", 5_000_000)
        try dense("sub/x.bin", 200_000)
        try sparse("sub/y-sparse.bin", 4_000_000)
        try dense("sub/deep/z.bin", 50_000)
        try sparse("sub/deep/w-sparse.bin", 900_000)
        try dense("other/keep.bin", 100_000)
        try dense("plain.txt", 2_000)
        try dense("Foo.app/Contents/MacOS/foo", 20_000)
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>dev.disksurvey.selftest.foo</string><key>CFBundleExecutable</key><string>foo</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>"
        try Data(plist.utf8).write(to: root.appending(path: "Foo.app/Contents/Info.plist"))
        // A plainly recognisable icon of its own.
        let icon = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            NSColor.systemPink.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 12, dy: 12)).fill()
            return true
        }
        NSWorkspace.shared.setIcon(icon, forFile: root.appending(path: "Foo.app").path, options: [])
        return root
    }

    // MARK: Sandbox and access

    /// The sandboxed edition's plumbing: detection, the real home folder, where harness output
    /// goes, and the access manager with real security-scoped bookmarks (made for the fixture,
    /// kept in memory, never in the user's settings). The bookmark checks run in both editions
    /// — the system calls are the same — against a manager that is told it is sandboxed and
    /// that nothing is reachable by itself.
    private func accessPlumbing(fixture: URL) {
        let app = model.app
        let sandboxed = AppSandbox.isSandboxed
        let home = AppSandbox.realHomeDirectory
        note("sandboxed: \(sandboxed); Full Disk Access: \(app.fullDiskAccess); stored grants: \(app.access.storedGrants.count)")

        // The signature decides; the environment variable only has to agree when sandboxed
        // (a normal build may inherit it from whoever started it).
        let entitled = AppSandbox.ownsEntitlement(AppSandbox.sandboxEntitlement)
        check(app.isSandboxed == sandboxed && sandboxed == (entitled ?? sandboxed)
            && (!sandboxed || ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil),
            "sandbox detection follows the signature’s entitlement", "sandboxed \(sandboxed), entitlement \(entitled.map(String.init) ?? "unreadable")")
        check(!AppSandbox.detect(environment: ["APP_SANDBOX_CONTAINER_ID": "inherited"], entitlement: false),
            "an inherited APP_SANDBOX_CONTAINER_ID does not make an unsandboxed build behave as sandboxed")
        check(home.hasPrefix("/") && !home.contains("/Library/Containers/") && (sandboxed ? NSHomeDirectory() != home : NSHomeDirectory() == home),
            "the real home folder comes from the user database, not from the container", "NSHomeDirectory is the \(NSHomeDirectory() == home ? "real home" : "container")")
        check(app.quickLocations.first?.url.path == home && app.quickLocations.contains { $0.url.path == home + "/Downloads" },
            "the Home and Downloads buttons point into the real home folder")
        check(LaunchOptions(arguments: ["--scan", "~/Library"]).scanPath == home + "/Library", "“~” in a launch argument is the real home folder")
        let tmp = URL(fileURLWithPath: "/container/tmp")
        check(SnapshotHarness.outputPath(for: "/somewhere/else/shot.png", sandboxed: true, temporaryDirectory: tmp) == "/container/tmp/shot.png"
            && SnapshotHarness.outputPath(for: "/somewhere/else/shot.png", sandboxed: false, temporaryDirectory: tmp) == "/somewhere/else/shot.png",
            "harness output is redirected into the container only when sandboxed")

        // The app's own manager and the window's lease.
        if sandboxed {
            check(app.access.coverage(for: fixture) == .implicit, "the temporary folder is reachable without a grant", "\(app.access.coverage(for: fixture))")
            check(model.access?.kind == .implicit && model.access?.covers(fixture) == true, "the scanning window holds a lease on its folder")
            let reach = DiskAccess.probePaths.contains { app.access.isWithinReach($0) }
            check(reach ? app.fullDiskAccess != .unknown : app.fullDiskAccess == .unknown,
                "Full Disk Access is “unknown” exactly while no grant reaches the protected folders", "in reach: \(reach), state: \(app.fullDiskAccess)")
            check(!app.access.allowsPanels, "harness runs never show the open panel")
        } else {
            check(app.access.coverage(for: fixture) == .unrestricted && app.access.coverage(for: URL(fileURLWithPath: "/")) == .unrestricted,
                "not sandboxed: every location is unrestricted")
            check(model.access == nil, "not sandboxed: the window needs no lease")
            check(app.fullDiskAccess != .unknown, "not sandboxed: Full Disk Access is yes or no")
            check(app.access.storedGrants.isEmpty && app.access.coversStartupDisk, "not sandboxed: no grants are stored or needed")
        }

        // A manager under sandbox rules with nothing reachable by itself.
        let store = GrantStore.inMemory()
        let manager = AccessManager(sandboxed: true, store: store, implicitRoots: [])
        manager.allowsPanels = false
        let inner = fixture.appending(path: "sub/deep")
        let outside = fixture.deletingLastPathComponent().appending(path: "disksurvey-selftest-elsewhere")
        check(manager.coverage(for: fixture) == .none && manager.lease(for: fixture) == nil, "no grant: the location is not covered")
        var answered = false, refused = false
        manager.obtain(fixture, userSelected: false, window: nil) { granted in
            answered = true
            refused = granted == nil
        }
        check(answered && refused, "no grant and no panel allowed: the request fails at once instead of waiting for a click")

        guard let adopted = manager.adopt(fixture) else {
            return check(false, "a user-selected folder is adopted", manager.lastBookmarkError ?? "no lease")
        }
        let first = adopted.lease
        check(first.kind == .scoped && first.covers(inner) && !first.covers(outside), "a user-selected folder is adopted and covers what is below it, nothing else")
        let bookmarked = manager.storedGrants.count == 1 && adopted.remembered
        check(bookmarked, "a security-scoped bookmark is stored for it", manager.lastBookmarkError ?? "\(manager.storedGrants.count) records")
        check(manager.coverage(for: inner) == .active && manager.coverage(for: outside) == .none, "an active grant for an ancestor covers a subfolder, not a sibling")
        let second = manager.lease(for: inner)
        check(second != nil && manager.activeGrantCount == 1 && manager.outstandingLeases == 2 && manager.scopeStarts <= 1,
            "a second lease shares the started scope", "\(manager.activeGrantCount) grants, \(manager.outstandingLeases) leases, \(manager.scopeStarts) starts")
        first.release()
        first.release()
        check(manager.outstandingLeases == 1 && manager.activeGrantCount == 1, "releasing one lease (twice) keeps the scope open for the other")
        second?.release()
        check(manager.outstandingLeases == 0 && manager.activeGrantCount == 0 && manager.scopeStarts == manager.scopeStops,
            "start and stop of the security scope are balanced", "\(manager.scopeStarts) starts, \(manager.scopeStops) stops")

        if bookmarked {
            check(manager.coverage(for: inner) == .stored, "with no lease out the grant is only stored")
            // What the next launch does: a new manager reads the table and resolves the bookmark.
            let relaunched = AccessManager(sandboxed: true, store: store, implicitRoots: [])
            relaunched.allowsPanels = false
            check(relaunched.storedGrants.map(\.path) == manager.storedGrants.map(\.path), "the stored table is read back")
            if let lease = relaunched.lease(for: inner) {
                let listing = opendir(inner.path)
                check(lease.kind == .scoped && listing != nil && relaunched.scopeStarts == 1, "a stored bookmark gives access to a subfolder without a panel")
                if let listing { closedir(listing) }
                lease.release()
                check(relaunched.scopeStarts == relaunched.scopeStops && relaunched.activeGrantCount == 0, "…and its scope is stopped when released")
            } else {
                check(false, "a stored bookmark gives access to a subfolder without a panel", relaunched.lastBookmarkError ?? "-")
            }
            // The background check (Full Disk Access on every activation) only looks.
            let written = store.load()
            let state = relaunched.withStoredAccess(covering: [inner.path]) { relaunched.isWithinReach(inner.path) }
            check(state && !relaunched.isWithinReach(inner.path) && relaunched.scopeStarts == relaunched.scopeStops, "a stored grant can be started for the length of one check")
            check(store.load() == written, "…and that check does not write the stored grants (no new “last used” date)")
            grantBookkeeping(manager: manager, fixture: fixture, inner: inner)
            relaunched.forget(relaunched.storedGrants.first?.path ?? "")
            check(relaunched.coverage(for: inner) == .none && AccessGrantTable(data: store.load()).isEmpty, "a forgotten grant is gone from the store")
            spellings(fixture: fixture)
            dataVolumeFolder()
        }

        // A bookmark that no longer resolves: dropped, and the answer is "ask again". One on
        // a disk that is not connected is kept for when the disk is back.
        let absent = "/Volumes/disksurvey-selftest-not-connected/folder"
        var broken = AccessGrantTable()
        broken.insert(path: fixture.path, bookmark: Data("not a bookmark".utf8), now: Date())
        broken.insert(path: absent, bookmark: Data("not a bookmark either".utf8), now: Date())
        let brokenStore = GrantStore.inMemory()
        brokenStore.save(broken.encoded())
        let damaged = AccessManager(sandboxed: true, store: brokenStore, implicitRoots: [])
        damaged.allowsPanels = false
        check(damaged.coverage(for: inner) == .stored, "fixture: a stored record with a bookmark that cannot be resolved")
        check(damaged.lease(for: inner) == nil && !damaged.storedGrants.contains { $0.path != absent }
            && AccessGrantTable(data: brokenStore.load()).records.map(\.path) == [absent],
            "an unresolvable bookmark is dropped from the table")
        check(damaged.coverage(for: inner) == .none, "…after which the location needs the open panel again")
        check(damaged.lease(for: URL(fileURLWithPath: absent + "/x")) == nil && damaged.storedGrants.map(\.path) == [absent]
            && AccessGrantTable(data: brokenStore.load()).records.map(\.path) == [absent],
            "a grant on a disk that is not connected is kept, not dropped", "\(damaged.storedGrants.count) records")
        check(damaged.withStoredAccess(covering: [absent]) { true } && damaged.storedGrants.count == 1, "…and the background check leaves it alone too")
    }

    /// Which choices add a stored grant and which do not; `manager` holds one for `fixture`.
    private func grantBookkeeping(manager: AccessManager, fixture: URL, inner: URL) {
        let root = manager.storedGrants.first?.path ?? ""
        // A stored grant already covers the choice: it is used, and no second record appears.
        let again = manager.adopt(inner)
        check(again?.lease.rootPath == root && again?.remembered == true && manager.storedGrants.count == 1,
            "a choice inside an allowed folder uses that grant and stores nothing new", "\(manager.storedGrants.count) records")
        again?.lease.release()
        let same = manager.adopt(fixture)
        check(same?.lease.rootPath == root && manager.storedGrants.count == 1, "choosing an allowed folder again stores nothing new")
        same?.lease.release()

        // Asked for by itself (the enclosing grant did not reach it): stored, and preferred
        // from then on, also while the broader grant is in use by another window.
        let forced = manager.adopt(inner, force: true)
        let innerRoot = forced?.lease.rootPath ?? ""
        check(manager.storedGrants.count == 2 && innerRoot != root && GrantPath.covers(root, innerRoot),
            "a folder asked for by itself gets a grant of its own", "\(manager.storedGrants.count) records")
        forced?.lease.release()
        let broad = manager.lease(for: fixture)
        let narrow = manager.lease(for: inner.appending(path: "z.bin"))
        check(broad?.rootPath == root && narrow?.rootPath == innerRoot && manager.activeGrantCount == 2,
            "the grant made for a folder wins over a broader one that is in use", "leased from \(narrow?.rootPath == innerRoot ? "the folder’s grant" : "the broader grant")")
        narrow?.release()
        manager.forget(innerRoot)
        check(manager.storedGrants.count == 1, "fixture: the folder’s own grant is removed again")

        // Removed in Settings while a window still uses it, then chosen again: remembered.
        manager.forget(root)
        check(manager.storedGrants.isEmpty && manager.coverage(for: fixture) == .active, "a removed grant stays in use until its window lets go")
        let chosen = manager.grantChosen(fixture)
        check(chosen?.remembered == true && manager.storedGrants.map(\.path) == [root] && manager.sessionGrants.isEmpty,
            "choosing a location again after removing it stores a bookmark, although its scope is still in use",
            "remembered \(chosen?.remembered == true), \(manager.storedGrants.count) records, error \(manager.lastBookmarkError ?? "-")")
        broad?.release()
        check(manager.outstandingLeases == 0 && manager.activeGrantCount == 0 && manager.scopeStarts == manager.scopeStops,
            "…and every scope is stopped afterwards", "\(manager.scopeStarts) starts, \(manager.scopeStops) stops, \(manager.outstandingLeases) leases")
    }

    /// A location reached through a symbolic link, or written in other letter case: the grant
    /// is filed under the spelling its bookmark resolves to, and found under either.
    private func spellings(fixture: URL) {
        let files = FileManager.default
        let link = fixture.deletingLastPathComponent().appending(path: "disksurvey-selftest-link-\(UUID().uuidString)")
        defer { try? files.removeItem(at: link) }
        guard (try? files.createSymbolicLink(at: link, withDestinationURL: fixture)) != nil,
            let real = GrantPath.canonical(fixture.appending(path: "sub/deep").path)
        else { return check(false, "fixture: a symbolic link to the scanned folder") }
        let through = link.appending(path: "sub/deep")
        let store = GrantStore.inMemory()
        let manager = AccessManager(sandboxed: true, store: store, implicitRoots: [])
        manager.allowsPanels = false
        check(GrantPath.normalized(through.path) != real && GrantPath.canonical(through.path) == real, "fixture: the link spells the folder differently")

        let adopted = manager.adopt(through)
        check(adopted?.remembered == true && manager.storedGrants.map(\.path) == [real] && adopted?.lease.rootPath == real,
            "a folder chosen through a symbolic link is stored under the path its bookmark resolves to",
            "remembered \(adopted?.remembered == true), \(manager.storedGrants.count) records, error \(manager.lastBookmarkError ?? "-")")
        check(adopted.map { GrantPath.normalized($0.url.path) == real && $0.lease.covers($0.url) } == true,
            "…and the location to scan is that spelling, so recents find the grant again")
        adopted?.lease.release()

        let relaunched = AccessManager(sandboxed: true, store: store, implicitRoots: [])
        relaunched.allowsPanels = false
        check(relaunched.coverage(for: through) == .stored, "after a relaunch the stored grant covers the spelling through the link")
        var granted: AccessManager.Granted?
        relaunched.obtain(through, userSelected: false, window: nil) { granted = $0 }
        check(granted.map { $0.lease.rootPath == real && GrantPath.normalized($0.url.path) == real } == true,
            "…and a scan of that spelling starts without a panel", relaunched.lastBookmarkError ?? "-")
        granted?.lease.release()
        // The disk's letter case, where the volume ignores case.
        let shouted = URL(fileURLWithPath: fixture.path).appending(path: "SUB/DEEP")
        if GrantPath.canonical(shouted.path) == real {
            let lease = relaunched.lease(for: shouted)
            check(lease?.rootPath == real, "a spelling in other letter case finds the stored grant")
            lease?.release()
        } else {
            note("the volume is case-sensitive: the letter-case check does not apply")
        }
        // A symbolic link itself cannot be bookmarked; what it points at is stored instead.
        let target = relaunched.adopt(link)
        check(target?.remembered == true && target.map { GrantPath.normalized($0.url.path) } == GrantPath.canonical(fixture.path),
            "a chosen symbolic link is stored as the folder it points at", relaunched.lastBookmarkError ?? "-")
        target?.lease.release()
        check(relaunched.outstandingLeases == 0 && relaunched.scopeStarts == relaunched.scopeStops, "…with every scope stopped")
    }

    /// A folder of the Data volume that no firmlink shows on the startup disk is not the
    /// system volume's folder of the same name, although a bookmark made for it resolves there.
    private func dataVolumeFolder() {
        let chosen = "/System/Volumes/Data/System/Library/CoreServices", twin = "/System/Library/CoreServices"
        var first = stat(), second = stat()
        guard stat(chosen, &first) == 0, stat(twin, &second) == 0, first.st_ino != second.st_ino || first.st_dev != second.st_dev else {
            return note("no Data-volume folder apart from its system-volume namesake here: that check does not apply")
        }
        check(GrantPath.normalized(chosen) == chosen && !GrantPath.covers(twin, chosen), "a Data-volume folder without a firmlink keeps its own path")
        let manager = AccessManager(sandboxed: true, store: .inMemory(), implicitRoots: [])
        manager.allowsPanels = false
        let adopted = manager.adopt(URL(fileURLWithPath: chosen, isDirectory: true))
        check(!manager.storedGrants.contains { GrantPath.covers($0.path, twin) || GrantPath.covers(twin, $0.path) }
            && manager.coverage(for: URL(fileURLWithPath: twin)) == .none,
            "choosing it never files a grant for the system volume’s folder of the same name",
            "stored \(manager.storedGrants.map(\.path)), adopted \(adopted.map { "\($0.lease.rootPath), remembered \($0.remembered)" } ?? "no")")
        if let adopted {
            check(adopted.lease.rootPath == chosen && GrantPath.normalized(adopted.url.path) == chosen, "…and what is scanned is the folder that was chosen", adopted.lease.rootPath)
        }
        adopted?.lease.release()
        check(manager.outstandingLeases == 0 && manager.scopeStarts == manager.scopeStops, "…with every scope stopped")
    }

    private func node(_ relativePath: String) -> NodeID? {
        guard let tree = model.tree else { return nil }
        return tree.node(atPath: relativePath.isEmpty ? tree.rootPath : tree.rootPath + "/" + relativePath)
    }

    // MARK: Checks

    /// #5 (pure part): the menu commands that share a key with text editing.
    private func commandPredicates() {
        var state = CommandState(canTrash: true, canZoomOut: true, canZoomIn: true)
        check(state.allowsTrashCommand && state.allowsEnclosingFolderCommand && state.allowsZoomIntoSelectionCommand, "commands enabled while no text is edited")
        state.textEditing = true
        check(!state.allowsTrashCommand, "Move to Trash (⌘⌫) is disabled while text is edited")
        check(!state.allowsEnclosingFolderCommand && !state.allowsZoomIntoSelectionCommand, "⌘↑ / ⌘↓ commands are disabled while text is edited")
        state.canTrash = false
        state.textEditing = false
        check(!state.allowsTrashCommand, "Move to Trash stays disabled without a selection")
    }

    /// #14: a clean scan ends without a toast over the map.
    private func scanToast() async {
        check(model.toast == nil, "no toast after a scan without problems", model.toast?.text ?? "")
    }

    /// The rows the outline should show for the folders that are expanded, in the given size mode
    /// under the default sort (size, descending).
    private func expectedRows(tree: FileTree, logical: Bool) -> [NodeID] {
        var result: [NodeID] = []
        func visit(_ node: NodeID) {
            result.append(node)
            guard isExpanded(node) else { return }
            var children = Array(tree.children(of: node))
            if logical { children.sort { tree.logicalSize(of: $0) > tree.logicalSize(of: $1) } }
            children.forEach(visit)
        }
        visit(tree.root)
        return result
    }

    /// #1: a size-mode or colour-scheme change keeps the row views, reorders where needed, and
    /// keeps expansion and selection.
    private func outlineMetricAndScheme() async {
        guard let tree = model.tree, let view = outline?.outlineView, let z = node("sub/deep/z.bin"), let sub = node("sub"),
            let deep = node("sub/deep"), let sparse = node("b-sparse.bin"), let foo = node("Foo.app/Contents/MacOS/foo")
        else { return check(false, "outline fixture nodes found") }
        let preferences = model.preferences
        model.reveal(z)
        await settle()
        check(isExpanded(sub) && isExpanded(deep), "revealing a file expands its folders")
        let allocatedOrder = rowNodes()
        check(allocatedOrder == expectedRows(tree: tree, logical: false), "outline rows follow on-disk order")
        let logicalOrder = expectedRows(tree: tree, logical: true)
        check(logicalOrder != allocatedOrder, "fixture: logical order differs from on-disk order")

        // Default sort (size): the order changes with the mode.
        var start = Counters()
        preferences.sizeMode = .logical
        await settle()
        var used = delta(since: start)
        check(rowNodes() == logicalOrder, "sort by size: rows are reordered for logical sizes")
        check(isExpanded(sub) && isExpanded(deep), "sort by size: expanded folders stay expanded across the switch")
        let selected = view.selectedRowIndexes.compactMap { (view.item(atRow: $0) as? NSNumber)?.uint32Value }
        check(selected == [z] && model.selection == [z], "sort by size: the selection stays on the same node")
        check(cell(SizeCellView.self, node: sparse, column: "size")?.accessibilityLabel() == Format.bytes(tree.logicalSize(of: sparse)), "sort by size: size cells show logical sizes")
        note("reorder: \(used.cells) name cells and \(used.rows) row views created for \(view.numberOfRows) rows")
        preferences.sizeMode = .allocated
        await settle()
        check(rowNodes() == allocatedOrder, "sort by size: rows return to on-disk order")
        check(model.selection == [z] && isExpanded(deep), "sort by size: selection and expansion survive the switch back")

        // Sorted by name the order cannot change: nothing may be rebuilt.
        view.sortDescriptors = [NSSortDescriptor(key: OutlineController.SortKey.name.rawValue, ascending: true)]
        await settle()
        let byName = rowNodes()
        start = Counters()
        preferences.sizeMode = .logical
        await settle()
        used = delta(since: start)
        check(used.cells == 0 && used.rows == 0, "sort by name: size-mode switch creates no row or cell views", "\(used.cells) cells, \(used.rows) rows")
        check(used.configurations > 0, "sort by name: the existing cells were reconfigured", "\(used.configurations) configurations")
        check(rowNodes() == byName, "sort by name: row order unchanged")
        check(cell(SizeCellView.self, node: sparse, column: "size")?.accessibilityLabel() == Format.bytes(tree.logicalSize(of: sparse)), "sort by name: size cells show logical sizes")
        preferences.sizeMode = .allocated
        await settle()
        check(cell(SizeCellView.self, node: sparse, column: "size")?.accessibilityLabel() == Format.bytes(tree.size(of: sparse)), "sort by name: size cells show on-disk sizes again")

        // Colour scheme: badges change colour in the cells that exist.
        let kind = Int(tree.kind(of: foo))
        let light = tree.kindColors(scheme: .light), dark = tree.kindColors(scheme: .dark)
        model.reveal(foo)
        await settle()
        preferences.mapPalette = .light
        await settle()
        let lightBadge = cell(NameCellView.self, node: foo, column: "name")?.badgeColor
        start = Counters()
        preferences.mapPalette = .dark
        await settle()
        used = delta(since: start)
        let darkBadge = cell(NameCellView.self, node: foo, column: "name")?.badgeColor
        check(used.cells == 0 && used.rows == 0, "scheme change creates no row or cell views", "\(used.cells) cells, \(used.rows) rows")
        if kind < light.count, kind < dark.count, light[kind] != dark[kind] {
            check(lightBadge == light[kind].nsColor.cgColor && darkBadge == dark[kind].nsColor.cgColor, "scheme change recolours the kind badges in place")
        } else {
            note("badge colours are the same in both schemes for this kind; recolouring not checked")
        }
        preferences.mapPalette = .system
        view.sortDescriptors = [NSSortDescriptor(key: OutlineController.SortKey.size.rawValue, ascending: false)]
        await settle()
        check(rowNodes() == expectedRows(tree: tree, logical: false), "back to sort by size: rows follow on-disk order")
    }

    /// #6: a result-list row whose node is gone must not let its menu act on the old selection.
    private func staleRows() async {
        guard let tree = model.tree, let keep = node("other/keep.bin"), let sub = node("sub"), let x = node("sub/x.bin")
        else { return check(false, "stale-row fixture nodes found") }
        let staleRow = FileRow(tree: tree, node: x, epoch: model.idEpoch, metric: .allocated)
        model.select([keep], primary: keep)
        model.enqueueMutation { [model] in await model.rescanSubtrees([sub], announce: false) }
        await pause(0.1)
        await settle()
        guard let current = model.tree, let newX = node("sub/x.bin") else { return check(false, "tree after subtree rescan") }
        check(current.isRemoved(x) && newX != x, "subtree rescan gives the folder's files new ids")
        check(model.selection == [keep], "selection outside the rescanned folder is kept")
        check(model.reveal(staleRow) == false, "reveal(row) reports a stale row")
        check(model.selection == [keep], "a stale row leaves the selection alone")
        var ran = false
        model.toast = nil
        model.act(on: staleRow) {
            ran = true
            $0.requestTrash()
        }
        check(!ran && model.trashRequest == nil, "menu action on a stale row does not run on the previous selection")
        check(model.toast?.text == "That item is no longer in the map", "a stale row says why nothing happened", model.toast?.text ?? "-")
        let freshRow = FileRow(tree: current, node: newX, epoch: model.idEpoch, metric: .allocated)
        model.act(on: freshRow) { $0.requestTrash() }
        check(model.trashRequest?.items.map(\.node) == [newX], "menu action on a live row targets that row")
        model.trashRequest = nil
        model.toast = nil
        await settle(0.5)
    }

    /// A drag onto the Trash hands over the dragged items, which need not be the selection;
    /// and the sheet's "Don’t ask again" only counts when the sheet is confirmed.
    private func explicitTrashRequests() async {
        guard let tree = model.tree, let a = node("a-dense.bin"), let b = node("b-sparse.bin"), let c = node("plain.txt"),
            let sub = node("sub"), let x = node("sub/x.bin"), let view = model.mapView
        else { return check(false, "explicit-trash fixture nodes found") }
        model.select([b, c], primary: b)
        model.treemapView(view, didRequestTrash: [a])
        check(model.trashRequest?.items.map(\.node) == [a], "a drop on the Trash lists the dragged item, not the selection")
        check(model.selection == [b, c], "…and leaves the selection as it was")
        model.trashRequest = nil
        model.select([], primary: nil)
        model.requestTrash()
        check(model.trashRequest == nil, "nothing selected, nothing named: no request")
        model.treemapView(view, didRequestTrash: [a])
        check(model.trashRequest?.items.map(\.node) == [a], "an empty selection still lists the dragged item")
        model.trashRequest = nil
        model.requestTrash(nodes: [sub, x])
        check(model.trashRequest?.items.map(\.node) == [sub], "a dragged folder covers a dragged item inside it")
        model.trashRequest = nil
        model.requestTrash(nodes: [NodeID(tree.count + 5), tree.root])
        check(model.trashRequest == nil && model.alert != nil, "unknown ids are dropped and the scan root is refused with an alert")
        model.alert = nil

        // "Don’t ask again": ticked and cancelled changes nothing; a new sheet starts unticked.
        model.requestTrash(nodes: [a])
        model.trashSheetStopsAsking = true
        model.trashSheetStopsAsking = false
        model.trashRequest = nil
        model.requestTrash(nodes: [a])
        model.trashSheetStopsAsking = true
        check(model.preferences.confirmTrash, "ticking “Don’t ask again” alone does not change the setting")
        model.trashRequest = nil  // dismissed without confirming (Escape)
        model.requestTrash(nodes: [a])
        check(model.trashRequest != nil && !model.trashSheetStopsAsking && model.preferences.confirmTrash, "a cancelled sheet leaves confirmation on, and the next sheet starts unticked")
        model.trashRequest = nil
        model.toast = nil
        await settle(0.2)
    }

    private func bitmap(_ image: NSImage, points: CGFloat = 32) -> Data? {
        IconCache.rasterize(image, points: points, dark: false).tiffRepresentation
    }

    /// #8 and #11: bundles show their own icon; table rows get plain bitmaps.
    private func icons() async {
        guard let tree = model.tree, let app = node("Foo.app"), let plain = node("plain.txt"), let sub = node("sub") else {
            return check(false, "icon fixture nodes found")
        }
        let cache = IconCache.shared
        check(tree.flags(of: app).contains(.package), "fixture: Foo.app is scanned as a package")
        var start = Counters()
        _ = cache.icon(for: tree, node: plain)
        _ = cache.icon(for: tree, node: sub)
        _ = cache.smallIcon(for: tree, node: plain, dark: false)
        check(delta(since: start).iconLoads == 0, "plain files and folders never read an icon from disk")

        _ = cache.icon(for: tree, node: app)
        for _ in 0 ..< 200 where cache.hasPendingLoads { await pause(0.02) }
        await pause(0.2)
        let typeIcon = cache.icon(forExtension: "app", isDirectory: true)
        let own = cache.icon(for: tree, node: app)
        check(own !== typeIcon && bitmap(own) != bitmap(typeIcon), "a bundle with its own icon shows it instead of the type's placeholder")
        start = Counters()
        _ = cache.icon(for: tree, node: app)
        check(delta(since: start).iconLoads == 0, "a loaded bundle icon is served from the cache")
        let small = cache.smallIcon(for: tree, node: app, dark: false)
        check(cell(NameCellView.self, node: app, column: "name")?.imageView?.image === cache.smallIcon(for: tree, node: app, dark: outline?.outlineView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua),
            "the outline row was updated with the bundle's icon when it arrived")
        check(bitmap(small, points: 16) != bitmap(cache.smallIcon(for: tree, node: plain, dark: false), points: 16), "the small bundle icon differs from a document's")
        let row = FileRow(tree: tree, node: app, epoch: model.idEpoch, metric: .allocated)
        check(row.iconPath == tree.path(of: app) && cache.icon(forExtension: row.ext, isDirectory: true, customIconPath: row.iconPath) === own, "result-list rows carry the bundle's icon")
        check(FileRow(tree: tree, node: plain, epoch: model.idEpoch, metric: .allocated).iconPath == nil, "result-list rows of plain files carry no icon path")

        // #11
        let smallPlain = cache.smallIcon(for: tree, node: plain, dark: false)
        check(smallPlain === cache.smallIcon(for: tree, node: plain, dark: false), "small icons are cached (same instance)")
        check(smallPlain.size == NSSize(width: 16, height: 16) && smallPlain.representations.count == 2 && smallPlain.representations.allSatisfy { $0 is NSBitmapImageRep },
            "small icons are 16 pt bitmaps at 1x and 2x")
        let solid = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let filled = IconCache.rasterize(solid, points: 16, dark: false).representations.compactMap { $0 as? NSBitmapImageRep }.allSatisfy { rep in
            [(1, 1), (rep.pixelsWide - 2, 1), (1, rep.pixelsHigh - 2), (rep.pixelsWide - 2, rep.pixelsHigh - 2)].allSatisfy { x, y in
                (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9
            }
        }
        check(filled, "small icons fill their bitmap at both scales (not drawn at half size)")
        let views = (0 ..< 150).map { _ in NSImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16)) }
        let fullImages = [cache.icon(for: tree, node: plain), cache.icon(for: tree, node: sub), typeIcon]
        let smallImages = [smallPlain, cache.smallIcon(for: tree, node: sub, dark: false), small]
        func assign(_ images: [NSImage]) -> Double {
            var best = Double.infinity
            for round in 0 ..< 5 {
                let begin = mainThreadCPU()
                for (index, view) in views.enumerated() { view.image = images[(index + round) % images.count] }
                best = min(best, mainThreadCPU() - begin)
            }
            return best
        }
        let full = assign(fullImages), fast = assign(smallImages)
        check(fast < 2.0 && fast < full, "assigning 150 small icons is cheap", String(format: "%.2f ms, IconServices-backed originals: %.2f ms", fast, full))
    }

    /// #9: views that ask "is a search on" or for the map highlight are not invalidated by a keystroke.
    private func searchObservation() async {
        func tracked(_ change: () -> Void) -> Bool {
            let fired = Flag()
            withObservationTracking {
                _ = model.searchIsActive
                _ = model.highlight
            } onChange: {
                fired.set()
            }
            change()
            return fired.value
        }
        model.clearSearch()
        await settle()
        check(tracked { model.searchText = "b" }, "starting a search invalidates searchIsActive/highlight")
        await settle(0.6)
        check(model.searchIsActive && model.inspectorTab == .search, "search is active and its tab shown")
        check(!tracked { model.searchText = "bi" }, "a further keystroke does not invalidate searchIsActive/highlight")
        let fired = Flag()
        withObservationTracking { _ = model.highlight } onChange: { fired.set() }
        await settle(0.6)
        check(fired.value && model.searchRows.contains { $0.name == "x.bin" }, "highlight is invalidated when the results arrive")
        check(tracked { model.toggleToken(SearchToken.sizes[0]) } == false, "adding a filter to an active search does not flip the flag")
        model.searchTokens = []
        check(tracked { model.searchText = "" }, "ending the search invalidates searchIsActive/highlight")
        check(!model.searchIsActive && model.inspectorTab != .search, "search is off and its tab gone")
        model.searchTokens = [SearchToken.sizes[0]]
        check(model.searchIsActive, "a filter alone makes the search active")
        model.clearSearch()
        await settle()
    }

    /// #2: zooming, typing a query and switching colour or size mode do not evaluate `ScanView`
    /// (and with it the toolbar).
    /// The depth setting reaches the map, is relative to the zoom root, steps and persists
    /// without rebuilding the toolbar, and the hover reports the collapsed folder.
    private func mapDepth() async {
        guard let sub = node("sub"), let map = model.mapView, let tree = model.tree else { return }
        let preferences = model.preferences
        check(preferences.mapDepth == MapDepth.all && map.maxDepth == nil, "map shows all levels by default")
        check(preferences.mapStyle == .adaptive && map.mapStyle == .adaptive, "adaptive frames are the default style")
        let start = Counters()
        preferences.mapDepth = 1
        await settle(0.5)
        let used = delta(since: start)
        check(map.maxDepth == 1, "depth 1 reaches the map", "\(String(describing: map.maxDepth))")
        check(used.scanBodies == 0 && used.toolbars == 0, "depth change: ScanView and toolbar are not re-evaluated", "\(used.scanBodies) bodies, \(used.toolbars) toolbars")
        // "sub" holds files and a folder; at depth 1 it is one block, so a file inside is drawn where the folder is.
        if let inside = node("sub/x.bin") {
            check(map.rect(for: inside) != nil && map.rect(for: inside) == map.rect(for: sub), "at depth 1 a folder is one block", "\(String(describing: map.rect(for: sub)))")
            let shown = map.showHover(for: sub)
            await pause(0.1)
            check(shown && model.hover?.node == sub && model.hover?.size == model.size(of: sub, in: tree), "hovering the block reports the folder and its size")
            map.clearHover()
        }
        model.zoom(to: sub)
        await settle(0.5)
        if let deep = node("sub/deep"), let file = node("sub/deep/z.bin"), let top = node("sub/x.bin") {
            check(map.maxDepth == 1 && map.rect(for: file) == map.rect(for: deep) && map.rect(for: top) != map.rect(for: deep), "the depth stays relative to the folder zoomed into")
        }
        model.zoomToRoot()
        check(MapDepth.less(than: 1) == nil && MapDepth.more(than: 1) == 2 && MapDepth.more(than: MapDepth.deepest) == MapDepth.all
            && MapDepth.less(than: MapDepth.all) == MapDepth.deepest && MapDepth.more(than: MapDepth.all) == nil, "depth steps: 1 … deepest, then all")
        check(UserDefaults(suiteName: "dev.disksurvey.app.harness")?.integer(forKey: "mapDepth") == 1, "depth is persisted")
        check(MapStyleSetting(frames: .adaptive, gutters: true) == .adaptive && MapStyleSetting(frames: .topLevels, gutters: false) == .framed
            && MapStyleSetting(frames: .none, gutters: true) == .grouped && MapStyleSetting(frames: .none, gutters: false) == .cushion
            && MapStyleSetting.grouped.frames == .none && MapStyleSetting.cushion.hasGutters == false, "frame style choices map onto the map styles")
        preferences.mapDepth = MapDepth.all
        await settle(0.4)
        if let inside = node("sub/x.bin") {
            check(map.maxDepth == nil && map.rect(for: inside) != map.rect(for: sub), "all levels again: files are drawn on their own")
        }
    }

    private func scanViewBodies() async {
        guard let sub = node("sub") else { return }
        let preferences = model.preferences
        check(DebugCounters.scanViewBodies > 0 && DebugCounters.toolbarBuilds > 0, "counters see ScanView and its toolbar being built")
        func measure(_ label: String, _ change: () -> Void) async {
            let start = Counters()
            change()
            await settle(0.5)
            let used = delta(since: start)
            check(used.scanBodies == 0 && used.toolbars == 0, "\(label): ScanView and toolbar are not re-evaluated", "\(used.scanBodies) bodies, \(used.toolbars) toolbars")
        }
        await measure("zoom in") { model.zoom(to: sub) }
        check(model.canGoBack, "zoom history is recorded")
        await measure("zoom back") { model.goBack() }
        await measure("search keystroke") { model.searchText = "x" }
        await measure("second keystroke") { model.searchText = "x." }
        await measure("clear search") { model.clearSearch() }
        await measure("colour by age") { preferences.colorMode = .age }
        await measure("colour by kind") { preferences.colorMode = .kind }
        await measure("logical sizes") { preferences.sizeMode = .logical }
        let logicalFirst = model.largest.first?.size
        await measure("on-disk sizes") { preferences.sizeMode = .allocated }
        check(logicalFirst != nil && model.largest.first?.size != logicalFirst, "size-mode change still refreshes the derived lists")
        await measure("selection") { model.reveal(sub) }
        // The counter must be able to fail: something ScanView does depend on.
        let start = Counters()
        preferences.showsInspector = false
        await settle(0.6)
        check(delta(since: start).scanBodies > 0, "control: hiding the inspector does re-evaluate ScanView")
        preferences.showsInspector = true
        await settle(0.8)
    }

    private func findView<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findView(type, in: subview) { return match }
        }
        return nil
    }

    private func menuItem(titled title: String) -> NSMenuItem? {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            submenu.delegate?.menuNeedsUpdate?(submenu)
            submenu.update()
            if let item = submenu.items.first(where: { $0.title == title }) { return item }
        }
        return nil
    }

    /// #5: with the search field being edited, Move to Trash is disabled, so ⌘⌫ reaches the text.
    private func focusAndTrashCommand() async {
        guard let window = model.window, let keep = node("other/keep.bin") else { return }
        let app = model.app
        model.select([keep], primary: keep)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        await settle(0.5)
        check(model.canTrash, "fixture: something trashable is selected")
        guard let field = findView(NSSearchField.self, in: window.contentView?.superview) else {
            return check(false, "search field found in the toolbar")
        }
        window.makeFirstResponder(model.mapView)
        await settle(0.3)
        check(!app.textEditing && app.commandState.allowsTrashCommand, "map focused: Move to Trash command allowed")
        let menuUsable = window.isKeyWindow
        if menuUsable {
            check(menuItem(titled: "Move to Trash…")?.isEnabled == true, "map focused: the menu item (⌘⌫) is enabled")
        } else {
            note("window is not key (screen locked or app in the background): menu item state not checked")
        }

        window.makeFirstResponder(field)
        // No event is processed here, so this relies on observing the window's first responder.
        await pause(0.3)
        check(AppModel.isEditingText(in: window), "search field focused: its field editor is the first responder")
        check(app.textEditing, "search field focused: the app notices without an event")
        check(app.commandState.canTrash && !app.commandState.allowsTrashCommand, "search field focused: Move to Trash command not allowed")
        if menuUsable {
            check(menuItem(titled: "Move to Trash…")?.isEnabled == false, "search field focused: the menu item (⌘⌫) is disabled, the key goes to the text")
            check(menuItem(titled: "Enclosing Folder")?.isEnabled == false, "search field focused: ⌘↑ is left to the text")
        }
        check(model.trashRequest == nil, "nothing was offered for the Trash")

        window.makeFirstResponder(outline?.outlineView)
        await pause(0.3)
        check(!app.textEditing && app.commandState.allowsTrashCommand, "outline focused: Move to Trash command allowed again")
        if menuUsable {
            check(menuItem(titled: "Move to Trash…")?.isEnabled == true, "outline focused: the menu item is enabled again")
        }
    }

    /// #7: the map keeps a usable width however the window is resized.
    ///
    /// The inspector stays open throughout: its show/hide animation does not finish while the
    /// app is in the background, which would leave the panes at in-between widths.
    private func splitLimits() async {
        guard let window = model.window, let split = outline?.scrollView.superview as? NSSplitView, split.subviews.count == 2 else {
            return check(false, "split view found")
        }
        func resize(_ width: CGFloat, _ height: CGFloat) async {
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size = NSSize(width: width, height: height)
            window.setFrame(frame, display: true)
            await settle(0.5)
        }
        func widths() -> (outline: CGFloat, map: CGFloat) { (split.subviews[0].frame.width, split.subviews[1].frame.width) }
        func inside() -> Bool {
            let frame = split.convert(split.bounds, to: nil)
            return frame.minX >= -0.5 && frame.maxX <= window.frame.width + 0.5
        }
        await resize(1320, 840)
        let wide = widths()
        note(String(format: "1320 pt window: outline %.0f, map %.0f", wide.outline, wide.map))
        await resize(900, 560)
        var now = widths()
        check(now.map >= 319.5 && now.outline >= 219.5 && inside(), "900 pt window with inspector: map keeps its minimum width", String(format: "outline %.0f, map %.0f", now.outline, now.map))
        await resize(760, 480)
        now = widths()
        check(now.map >= 319.5 && now.outline >= 219.5 && inside(), "smallest window with inspector: outline and map keep their minimum width, inside the window",
            String(format: "window %.0f, outline %.0f, map %.0f", window.frame.width, now.outline, now.map))
        check(window.frame.width >= MainSplit.SplitView.minimumWidth + InspectorView.idealWidth, "with the inspector open the window does not get narrower than its panes need", String(format: "%.0f", window.frame.width))
        await resize(1320, 840)
        now = widths()
        check(abs(now.outline - wide.outline) < 1.5, "widening the window gives the outline its width back", String(format: "outline %.0f, was %.0f", now.outline, wide.outline))
    }

    /// #4: revealing a deep file configures about as many cells as are shown, not a multiple.
    private func revealBatching() async {
        guard let tree = model.tree, let view = outline?.outlineView else { return }
        // The list is computed off the main thread; until then it still holds the previous tree's rows.
        for _ in 0 ..< 200 where model.largest.first?.epoch != model.idEpoch { await pause(0.05) }
        note("live resize before reveals: view \(view.inLiveResize), window \(view.window?.inLiveResize ?? false)")
        let targets = model.largest.filter { tree.depth(of: $0.node) >= 6 }.prefix(8)
        guard targets.count >= 3 else { return check(false, "synthetic tree has deep files to reveal") }
        var configurations: [Int] = [], times: [Double] = []
        for row in targets {
            let start = Counters()
            let begin = mainThreadCPU()
            model.reveal(row)
            await pause(0.35)
            times.append(mainThreadCPU() - begin)
            configurations.append(delta(since: start).configurations)
            let rowIndex = view.row(forItem: NSNumber(value: row.node))
            let visible = view.rows(in: view.visibleRect)
            if rowIndex < 0 || !visible.contains(rowIndex) || view.selectedRow != rowIndex {
                check(false, "revealed file is selected and scrolled into view", row.name)
            }
        }
        let visibleCells = view.rows(in: view.visibleRect).length * view.tableColumns.filter { !$0.isHidden }.count
        let median = configurations.sorted()[configurations.count / 2]
        check(median <= visibleCells * 5 / 2, "revealing a deep file configures at most ~2x the visible cells",
            "median \(median), all \(configurations), visible \(visibleCells)")
        note(String(format: "reveal: main-thread CPU median %.1f ms, worst %.1f ms", times.sorted()[times.count / 2], times.max() ?? 0))
    }

    /// #3: a far selection jump during a live resize must not build a view for every row passed.
    private func liveResize() async {
        guard let tree = model.tree, let view = outline?.outlineView else { return }
        for child in tree.children(of: tree.root) where view.numberOfRows < 20_000 {
            view.expandItem(NSNumber(value: child), expandChildren: true)
        }
        await settle(0.5)
        let total = view.numberOfRows
        guard total >= 5_000, let bottom = (view.item(atRow: total - 40) as? NSNumber)?.uint32Value,
            let top = (view.item(atRow: 30) as? NSNumber)?.uint32Value
        else { return check(false, "outline has thousands of rows for the live-resize check", "\(total)") }
        model.select([bottom], primary: bottom)
        await settle(0.6)
        note("live resize before the check: view \(view.inLiveResize), window \(view.window?.inLiveResize ?? false)")
        check(view.rows(in: view.visibleRect).contains(view.row(forItem: NSNumber(value: bottom))), "setup: a row near the bottom is shown", "\(total) rows")
        let visibleHeight = view.visibleRect.height

        view.liveResizeOverride = true
        let start = Counters()
        let begin = mainThreadCPU()
        model.select([top], primary: top)
        await pause(0.6)
        let cpu = mainThreadCPU() - begin
        let used = delta(since: start)
        let topRow = view.row(forItem: NSNumber(value: top))
        check(view.selectedRow == topRow, "during live resize: the new selection is applied")
        check(used.cells < 200 && view.subviews.count < 200 && view.preparedContentRect.height <= visibleHeight * 3,
            "during live resize: a far jump does not build the rows in between",
            String(format: "%d cells created, %d row views alive, prepared height %.0f (visible %.0f), %.0f ms main-thread CPU over %d rows", used.cells, view.subviews.count, view.preparedContentRect.height, visibleHeight, cpu, total - 70))
        check(cpu < 500, "during live resize: the update does not hang", String(format: "%.0f ms", cpu))
        check(view.rows(in: view.visibleRect).contains(topRow), "during live resize: the selected row is scrolled into view")

        // And back down, still resizing.
        let again = Counters()
        model.select([bottom], primary: bottom)
        await pause(0.6)
        check(view.rows(in: view.visibleRect).contains(view.row(forItem: NSNumber(value: bottom))) && delta(since: again).cells < 200,
            "during live resize: jumping back down is bounded too", "\(delta(since: again).cells) cells created")
        view.liveResizeOverride = nil
        await pause(0.3)
        check(view.subviews.count < 300, "after live resize: no pile of row views is left behind", "\(view.subviews.count)")
    }
}

/// A flag that an `@Sendable` observation callback can set.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    var value: Bool { lock.withLock { isSet } }
    func set() { lock.withLock { isSet = true } }
}
