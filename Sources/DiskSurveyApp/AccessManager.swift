import AppKit
import Observation
import DiskSurveyScan

/// A window's hold on a location it scans.
///
/// In the sandboxed edition a scan root is readable only while its security scope is started.
/// The window that shows a scan keeps a lease for as long as the tree is on screen (rescans,
/// Quick Look, icons and Move to Trash all go back to the disk), and gives it up when it
/// closes or scans something else. Leases on one grant are counted: the scope is stopped when
/// the last one is released, once for the one time it was started.
@MainActor
final class AccessLease {
    enum Kind: Equatable {
        /// Not sandboxed: nothing to keep.
        case unrestricted
        /// The app's own container, or a static exception in the signature: nothing to keep.
        case implicit
        /// A started security scope (a bookmark, or a URL the system handed over).
        case scoped
    }

    let kind: Kind
    /// The granted location this lease rests on, normalized; "/" for an unrestricted lease.
    let rootPath: String
    private weak var manager: AccessManager?
    /// The started scope behind a `scoped` lease.
    private let grant: ActiveGrant?
    private(set) var isReleased = false

    fileprivate init(kind: Kind, rootPath: String, manager: AccessManager?, grant: ActiveGrant? = nil) {
        self.kind = kind
        self.rootPath = rootPath
        self.manager = manager
        self.grant = grant
    }

    /// Whether the lease reaches `url` (the granted location or anything below it).
    func covers(_ url: URL) -> Bool {
        guard !isReleased else { return false }
        if kind == .unrestricted { return true }
        guard let path = GrantPath.normalized(url.path(percentEncoded: false)) else { return false }
        return GrantPath.covers(rootPath, path)
    }

    /// Gives the lease up. Safe to call more than once.
    func release() {
        guard !isReleased else { return }
        isReleased = true
        if let grant { manager?.released(grant) }
    }
}

/// A security scope that is started right now.
@MainActor
fileprivate final class ActiveGrant {
    let path: String
    /// The exact URL instance `startAccessingSecurityScopedResource` was called on.
    let url: URL
    /// Whether that call succeeded and so has to be balanced.
    let needsStop: Bool
    /// The disk the location is on, when known (see `AccessGrantRecord.volumeUUID`).
    let volumeUUID: String?
    var leases = 0

    init(path: String, url: URL, needsStop: Bool, volumeUUID: String?) {
        self.path = path
        self.url = url
        self.needsStop = needsStop
        self.volumeUUID = volumeUUID
    }

    /// Whether this scope serves a grant for `record`: the same location on the same disk.
    func serves(_ record: AccessGrantRecord) -> Bool {
        record.isSameGrant(as: AccessGrantRecord(path: path, bookmark: Data(), created: .distantPast, lastUsed: .distantPast, volumeUUID: volumeUUID))
    }
}

/// Where the stored grants live.
struct GrantStore {
    var load: () -> Data?
    var save: (Data) -> Void

    static func userDefaults(_ defaults: UserDefaults, key: String = "accessGrants") -> GrantStore {
        GrantStore(load: { defaults.data(forKey: key) }, save: { defaults.set($0, forKey: key) })
    }

    /// Forgotten when the process ends (the self-test).
    @MainActor static func inMemory() -> GrantStore {
        final class Box { var data: Data? }
        let box = Box()
        return GrantStore(load: { box.data }, save: { box.data = $0 })
    }
}

/// The one place that decides whether a location may be scanned, and that asks the user when
/// it may not.
///
/// Not sandboxed, it answers "yes" at once and does nothing else. Sandboxed, every scan root
/// — whether it comes from an open panel, a drop, an open-document event, a volume card, a
/// folder button, a recent scan, a rescan or a launch argument — needs one of:
///
/// - the app's own container (or, in the harness build only, a static exception),
/// - a grant that is in use right now,
/// - a stored grant: a security-scoped bookmark (read-write, app scope) of a folder or disk
///   the user chose before, kept in the user defaults; a grant covers everything below it,
/// - or a new choice in an open panel pointed at the location ("Grant Access").
@MainActor @Observable
final class AccessManager {
    /// What a successful request gives: the lease, and the location to scan. The location is
    /// the one asked for, unless the user chose something else in the panel, or the grant
    /// knows the location under another spelling (through a symbolic link, or in other letter
    /// case): then it is the spelling the grant covers, so that the scan, its window and the
    /// recent-scans list all name the place the way a stored grant will find it again.
    struct Granted {
        var lease: AccessLease
        var url: URL
    }

    /// What taking over a location the system handed over gave (see `adopt`).
    struct Adopted {
        var lease: AccessLease
        /// The location in the spelling the lease covers.
        var url: URL
        /// Whether a stored grant covers the location, so that a later launch need not ask.
        var remembered: Bool
    }

    let isSandboxed: Bool
    /// Off in harness runs: nobody is there to click, so a request that would need the panel
    /// fails at once instead.
    @ObservationIgnored var allowsPanels = true

    /// The stored grants, for the start screen and Settings.
    private(set) var storedGrants: [AccessGrantRecord] = []
    /// Locations allowed for this run only: the user chose them, but macOS would not make a
    /// bookmark (it could not for the startup disk on macOS 26.0 and 26.1). Kept open until
    /// the app quits.
    private(set) var sessionGrants: [String] = []
    @ObservationIgnored private var sessionLeases: [AccessLease] = []

    @ObservationIgnored private var table = AccessGrantTable()
    @ObservationIgnored private var active: [String: ActiveGrant] = [:]
    @ObservationIgnored private let store: GrantStore
    @ObservationIgnored private let implicitRoots: [String]

    /// How often a security scope was started and stopped; equal when no lease is out.
    @ObservationIgnored private(set) var scopeStarts = 0
    @ObservationIgnored private(set) var scopeStops = 0
    /// Why the last bookmark could not be made or used; for diagnostics (`--sandbox-report`).
    @ObservationIgnored private(set) var lastBookmarkError: String?

    init(sandboxed: Bool = AppSandbox.isSandboxed, store: GrantStore, implicitRoots: [String]? = nil) {
        isSandboxed = sandboxed
        self.store = store
        self.implicitRoots = implicitRoots ?? (AppSandbox.containerPaths + AppSandbox.staticReadWritePaths)
        guard sandboxed else { return }
        table = AccessGrantTable(data: store.load())
        storedGrants = table.records
    }

    // MARK: Questions

    private func normalized(_ url: URL) -> String? { GrantPath.normalized(url.path(percentEncoded: false)) }

    /// One way of writing a location, and the URL that goes with it.
    private struct Spelling {
        var path: String
        var url: URL
    }

    /// The ways `url` may be covered: as it was given, and as the file system spells it
    /// (symbolic links resolved, the disk's letter case), which is how grants are filed.
    private func spellings(of url: URL) -> [Spelling] {
        guard let given = normalized(url) else { return [] }
        var result = [Spelling(path: given, url: url)]
        if let canonical = GrantPath.canonical(given), canonical != given {
            result.append(Spelling(path: canonical, url: URL(fileURLWithPath: canonical, isDirectory: true)))
        }
        return result
    }

    private func implicitRoot(covering path: String) -> String? {
        implicitRoots.first { GrantPath.covers($0, path) }
    }

    /// The most specific grant in use that reaches `path`.
    private func activeGrant(covering path: String) -> ActiveGrant? {
        active.values.filter { GrantPath.covers($0.path, path) }.max { GrantPath.depth($0.path) < GrantPath.depth($1.path) }
    }

    /// How `url` can be reached right now, without asking anybody.
    func coverage(for url: URL) -> AccessCoverage {
        guard isSandboxed else { return .unrestricted }
        let paths = spellings(of: url).map(\.path)
        if paths.contains(where: { implicitRoot(covering: $0) != nil }) { return .implicit }
        if paths.contains(where: { activeGrant(covering: $0) != nil }) { return .active }
        if paths.contains(where: table.covers) { return .stored }
        return .none
    }

    /// Whether `path` can be opened right now as far as the sandbox is concerned.
    func isWithinReach(_ path: String) -> Bool {
        guard isSandboxed else { return true }
        guard let path = GrantPath.normalized(path) else { return false }
        return implicitRoot(covering: path) != nil || activeGrant(covering: path) != nil
    }

    /// Whether a stored or static grant covers the whole startup disk.
    var coversStartupDisk: Bool {
        guard isSandboxed else { return true }
        return implicitRoots.contains("/") || storedGrants.contains { $0.path == "/" } || sessionGrants.contains("/")
    }

    var activeGrantCount: Int { active.count + detached }
    var outstandingLeases: Int { leasesOut }
    /// Scopes that are still held by a window although another disk has taken their path.
    @ObservationIgnored private var detached = 0
    @ObservationIgnored private var leasesOut = 0

    // MARK: Leases without asking

    /// A lease on `url` from what is already there: the container, a grant in use, or a
    /// stored bookmark. `nil` when the user would have to be asked.
    func lease(for url: URL) -> AccessLease? { reach(url)?.lease }

    /// The lease `lease(for:)` describes, together with the spelling of `url` it covers.
    private func reach(_ url: URL) -> Granted? {
        guard isSandboxed else { return Granted(lease: AccessLease(kind: .unrestricted, rootPath: "/", manager: nil), url: url) }
        // The spelling the most specific grant knows comes first; as given when they tie.
        func bestDepth(_ path: String) -> Int {
            var depths = table.candidates(covering: path).prefix(1).map { GrantPath.depth($0.path) }
            if let root = implicitRoot(covering: path) { depths.append(GrantPath.depth(root)) }
            if let grant = activeGrant(covering: path) { depths.append(GrantPath.depth(grant.path)) }
            return depths.max() ?? -1
        }
        // (The sort is stable only by construction: there are at most two spellings.)
        var ranked = spellings(of: url).map { (spelling: $0, depth: bestDepth($0.path)) }.filter { $0.depth >= 0 }
        if ranked.count == 2, ranked[1].depth > ranked[0].depth { ranked.swapAt(0, 1) }
        for spelling in ranked.map(\.spelling) {
            if let root = implicitRoot(covering: spelling.path) {
                return Granted(lease: AccessLease(kind: .implicit, rootPath: root, manager: self), url: spelling.url)
            }
            // A stored grant closer to the location than the one in use comes first: it is
            // what the user chose for it (a folder picked by itself can be readable where a
            // grant for the whole disk, held open by another window, does not reach it).
            let inUse = activeGrant(covering: spelling.path)
            if let lease = leaseFromStore(covering: spelling.path, deeperThan: inUse.map { GrantPath.depth($0.path) }) {
                return Granted(lease: lease, url: spelling.url)
            }
            if let inUse { return Granted(lease: retain(inUse), url: spelling.url) }
        }
        return nil
    }

    /// The spelling of `url` that `lease` covers, if it covers one.
    private func location(of url: URL, under lease: AccessLease) -> URL? {
        if lease.kind == .unrestricted { return url }
        return spellings(of: url).first { GrantPath.covers(lease.rootPath, $0.path) }?.url
    }

    /// A lease from the most specific stored grant that reaches `path` and still works. The
    /// table is repaired on the way (see `AccessGrantTable.resolve`) and written back if that
    /// changed it.
    private func leaseFromStore(covering path: String, deeperThan depth: Int? = nil) -> AccessLease? {
        let before = table
        defer { if table != before { persist() } }
        var mounted: [MountedVolumeIdentity]?
        // A record whose scope cannot be started is as good as unresolvable: drop it, look again.
        while let found = table.resolve(
            covering: path, deeperThan: depth, now: Date(), resolve: resolveRecord,
            isUnavailable: { record in
                if mounted == nil { mounted = VolumeInfo.mountedIdentities() }
                return record.isOnAbsentVolume(mounted: mounted ?? [])
            }, renew: renewBookmark)
        {
            if let lease = startLease(on: found.record, handle: found.handle) { return lease }
            lastBookmarkError = "the security scope of \(found.record.path) could not be started"
            table.remove(found.record)
        }
        return nil
    }

    /// A lease on the scope of `record`: the one in use, or `handle` started now. `nil` when
    /// the scope cannot be started.
    private func startLease(on record: AccessGrantRecord, handle: URL) -> AccessLease? {
        if let grant = active[record.path] {
            if grant.serves(record) { return retain(grant) }
            // Another disk is mounted where the grant in use was made (two memory cards under
            // one name). Its windows keep their scope; this path now belongs to the new disk.
            detached += 1
            active[record.path] = nil
        }
        guard handle.startAccessingSecurityScopedResource() else { return nil }
        scopeStarts += 1
        let grant = ActiveGrant(path: record.path, url: handle, needsStop: true, volumeUUID: record.volumeUUID)
        active[grant.path] = grant
        return retain(grant)
    }

    /// Resolves a stored bookmark. Never with user interface and never by mounting anything:
    /// this runs on the main thread, and a bookmark on a network share that is not connected
    /// must fail at once instead of trying to mount the share.
    private func resolveBookmark(_ data: Data) -> AccessGrantTable.Resolved<URL>? {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil,
                bookmarkDataIsStale: &stale)
            return AccessGrantTable.Resolved(handle: url, path: url.path(percentEncoded: false), isStale: stale)
        } catch {
            lastBookmarkError = "resolve: \(error.localizedDescription)"
            return nil
        }
    }

    private func resolveRecord(_ record: AccessGrantRecord) -> AccessGrantTable.Resolved<URL>? {
        guard let resolved = resolveBookmark(record.bookmark) else { return nil }
        // On a disk that comes and goes the bookmark must lead to the disk it was made on, not
        // to another one that is mounted under the same name.
        if record.removableMountPoint != nil, let expected = record.volumeUUID, let actual = VolumeInfo.volumeUUID(of: resolved.handle),
            expected.caseInsensitiveCompare(actual) != .orderedSame
        {
            lastBookmarkError = "resolve: the bookmark for \(record.path) leads to another disk"
            return nil
        }
        return resolved
    }

    /// A fresh bookmark for a resolved (stale) one. Making it needs the scope to be open.
    private func renewBookmark(_ url: URL) -> Data? {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return makeBookmark(url)
    }

    private func makeBookmark(_ url: URL) -> Data? {
        do {
            // Read-write on purpose: Move to Trash needs to write to the item's folder.
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            lastBookmarkError = "create: \(error.localizedDescription)"
            return nil
        }
    }

    private func retain(_ grant: ActiveGrant) -> AccessLease {
        grant.leases += 1
        leasesOut += 1
        return AccessLease(kind: .scoped, rootPath: grant.path, manager: self, grant: grant)
    }

    fileprivate func released(_ grant: ActiveGrant) {
        grant.leases -= 1
        leasesOut -= 1
        guard grant.leases <= 0 else { return }
        if grant.needsStop {
            grant.url.stopAccessingSecurityScopedResource()
            scopeStops += 1
        }
        if active[grant.path] === grant { active[grant.path] = nil } else { detached -= 1 }
    }

    private func persist() {
        // Views only care which locations are stored; a changed "last used" date need not
        // redraw them.
        if storedGrants.map(\.path) != table.records.map(\.path) { storedGrants = table.records }
        store.save(table.encoded())
    }

    // MARK: Locations the system handed over

    /// Takes over a URL that came with access of its own — chosen in an open panel, dropped
    /// on a window or the Dock icon, or sent in an open-document event — and returns a lease.
    ///
    /// If a stored grant already covers the location, that grant is used and nothing new is
    /// stored (with the whole disk allowed, a hundred dropped folders are no hundred records).
    /// Otherwise a bookmark is made and stored for later launches, filed under the spelling it
    /// resolves to. A grant that is merely in use without being on record (it was removed in
    /// Settings, or no bookmark could be made for it) does not count as stored: the new choice
    /// is the user's wish to have it remembered.
    ///
    /// - Parameter force: store a grant for exactly this location although a stored grant for
    ///   an enclosing folder covers it; for a choice made because that grant did not reach it.
    /// - Returns: `nil` when the URL turns out not to be readable after all; the caller then asks.
    func adopt(_ url: URL, force: Bool = false) -> Adopted? {
        guard isSandboxed else {
            return Adopted(lease: AccessLease(kind: .unrestricted, rootPath: "/", manager: nil), url: url, remembered: true)
        }
        let spellings = spellings(of: url)
        guard let given = spellings.first, let canonical = spellings.last else { return nil }
        for spelling in spellings {
            if let root = implicitRoot(covering: spelling.path) {
                return Adopted(lease: AccessLease(kind: .implicit, rootPath: root, manager: self), url: spelling.url, remembered: true)
            }
        }
        if !force {
            for spelling in spellings {
                if let lease = leaseFromStore(covering: spelling.path) {
                    return Adopted(lease: lease, url: spelling.url, remembered: true)
                }
            }
        }

        // A symbolic link itself cannot be bookmarked; what it points at can.
        var bookmark = makeBookmark(url)
        if bookmark == nil, canonical.path != given.path { bookmark = makeBookmark(canonical.url) }
        // File the bookmark the way a later launch will find it: under the path it resolves to,
        // provided that is the item the user chose (a bookmark made for a folder of the Data
        // volume that no firmlink shows resolves to the system volume's folder of that name).
        if let bookmark, let resolved = resolveBookmark(bookmark), let key = GrantPath.normalized(resolved.path),
            Self.isSameItem(url.path(percentEncoded: false), resolved.path) ?? (key == canonical.path)
        {
            let uuid = VolumeInfo.volumeUUID(of: resolved.handle) ?? VolumeInfo.volumeUUID(of: url)
            let record = AccessGrantRecord(path: key, bookmark: bookmark, created: Date(), lastUsed: Date(), volumeUUID: uuid)
            // Use the bookmark the way a later launch will: start the scope it resolved to.
            if let lease = startLease(on: record, handle: resolved.handle) {
                table.insert(path: key, bookmark: bookmark, volumeUUID: uuid, now: Date())
                persist()
                return Adopted(lease: lease, url: location(of: url, under: lease) ?? URL(fileURLWithPath: key, isDirectory: true), remembered: true)
            }
            lastBookmarkError = "the security scope of a new bookmark for \(key) could not be started"
        }

        // No bookmark (macOS 26.0 and 26.1 could not make one for the startup disk), or it
        // does not lead back here. The URL itself is good until the app quits; it just is not kept.
        if let grant = active[canonical.path] { return Adopted(lease: retain(grant), url: canonical.url, remembered: false) }
        let started = url.startAccessingSecurityScopedResource()
        if started { scopeStarts += 1 }
        guard started || Self.canOpen(url) else { return nil }
        let grant = ActiveGrant(path: canonical.path, url: url, needsStop: started, volumeUUID: VolumeInfo.volumeUUID(of: url))
        active[grant.path] = grant
        return Adopted(lease: retain(grant), url: canonical.url, remembered: false)
    }

    /// Whether two paths name the same item on disk; `nil` when either cannot be examined.
    private static func isSameItem(_ a: String, _ b: String) -> Bool? {
        var first = stat(), second = stat()
        guard stat(a, &first) == 0, stat(b, &second) == 0 else { return nil }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    /// Whether the sandbox lets `url` be opened at all. Refusals come back at once, without a
    /// consent prompt.
    private static func canOpen(_ url: URL) -> Bool {
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno != EPERM && errno != EACCES }
        close(fd)
        return true
    }

    // MARK: Asking

    /// Gets access to `url`, asking the user in an open panel when nothing else covers it.
    ///
    /// - Parameters:
    ///   - userSelected: the URL came from the system with access of its own (see `adopt`).
    ///   - displayName: what to call the location in the panel's message.
    ///   - forcePanel: do not rely on a grant for an enclosing folder; ask for this location.
    ///     Used after such a grant turned out not to reach it.
    ///   - completion: called on the main actor, at once when no panel is needed. `nil`:
    ///     the user cancelled, or panels are off (harness) and nothing covers the location.
    func obtain(
        _ url: URL, userSelected: Bool, displayName: String? = nil, forcePanel: Bool = false, window: NSWindow?,
        completion: @escaping @MainActor (Granted?) -> Void
    ) {
        if !forcePanel {
            if userSelected, let adopted = adopt(url) { return completion(Granted(lease: adopted.lease, url: adopted.url)) }
            if let found = reach(url) { return completion(found) }
        }
        guard allowsPanels else { return completion(nil) }
        let name = displayName ?? Self.displayName(for: url)
        runPanel(
            pointingAt: url,
            message: "Disk Survey runs in the App Sandbox and can only read what you choose. To scan “\(name)”, click Grant Access. To scan something else, select it first.",
            window: window
        ) { [weak self] chosen in
            guard let self, let chosen, let adopted = self.adopt(chosen, force: forcePanel) else { return completion(nil) }
            // What was asked for when the choice reaches it; otherwise what was chosen.
            completion(Granted(lease: adopted.lease, url: self.location(of: url, under: adopted.lease) ?? adopted.url))
        }
    }

    /// Asks for a grant without scanning anything (the start screen's "Allow Access to
    /// <startup disk>"). `completion` gets the granted location and whether it will be
    /// remembered by the next launch, or `nil` if cancelled.
    func requestGrant(
        for url: URL, displayName: String, window: NSWindow?, completion: @escaping @MainActor ((url: URL, remembered: Bool)?) -> Void
    ) {
        guard isSandboxed, allowsPanels else { return completion(nil) }
        runPanel(
            pointingAt: url,
            message: "Click Grant Access to let Disk Survey read “\(displayName)”. Scans of it and of everything on it then start without asking again. Folders that macOS protects separately still need Full Disk Access.",
            window: window
        ) { [weak self] chosen in
            guard let self, let chosen, let adopted = self.adopt(chosen) else { return completion(nil) }
            self.settle(adopted)
            completion((adopted.url, adopted.remembered))
        }
    }

    /// Ends a grant that was asked for without a scan to use it. A remembered one lives on in
    /// its stored bookmark; one that could not be stored holds until the app quits, so its
    /// lease is kept.
    private func settle(_ adopted: Adopted) {
        if adopted.remembered {
            adopted.lease.release()
        } else {
            sessionLeases.append(adopted.lease)
            if !sessionGrants.contains(adopted.lease.rootPath) { sessionGrants.append(adopted.lease.rootPath) }
        }
    }

    /// `requestGrant` without the panel: what happens once the user has chosen `url` there.
    /// For the self-test, which has nobody to click.
    func grantChosen(_ url: URL) -> (url: URL, remembered: Bool)? {
        guard let adopted = adopt(url) else { return nil }
        settle(adopted)
        return (adopted.url, adopted.remembered)
    }

    private func runPanel(pointingAt url: URL, message: String, window: NSWindow?, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = url
        panel.prompt = "Grant Access"
        panel.message = message
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.url : nil)
        }
        if let window, window.isVisible, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    static func displayName(for url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path == "/" ? "the startup disk" : url.lastPathComponent
    }

    // MARK: Housekeeping

    /// Removes a stored grant. A scope that is in use stays open until its windows let go.
    func forget(_ path: String) {
        guard table.remove(path: path) else { return }
        persist()
    }

    func forgetAll() {
        guard !table.isEmpty else { return }
        table.removeAll()
        persist()
    }

    /// Runs `body` with every stored grant that covers one of `paths` started, and stops
    /// them again afterwards. For short checks outside any window (the Full Disk Access probe).
    ///
    /// This runs whenever the app becomes active, so it only looks: the stored table is not
    /// written, a grant is not marked as used, and one that fails to resolve at this moment is
    /// left alone. Dropping a grant is for a scan the user asked for.
    func withStoredAccess<T>(covering paths: [String], _ body: () -> T) -> T {
        var leases: [AccessLease] = []
        if isSandboxed {
            for path in paths where !isWithinReach(path) {
                guard let normalized = GrantPath.normalized(path), let found = table.peek(covering: normalized, resolve: resolveRecord),
                    let lease = startLease(on: found.record, handle: found.handle)
                else { continue }
                leases.append(lease)
            }
        }
        defer { leases.forEach { $0.release() } }
        return body()
    }
}
