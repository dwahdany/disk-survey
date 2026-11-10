import Foundation

/// Path arithmetic for sandbox access grants.
///
/// A grant for a folder covers everything below it, so "is this path covered" is a question
/// about path components. `normalized` and `covers` answer it without touching the file system
/// (a stored record must be comparable before any grant is active); `canonical` asks the file
/// system for the one spelling a bookmark resolves to.
public enum GrantPath {
    /// The folders of the Data volume that the startup disk shows at the same path through a
    /// firmlink (`/usr/share/firmlinks`). Only below these does `/System/Volumes/Data/<path>`
    /// name the same place as `/<path>`: `/System/Volumes/Data/System/Library`, say, is a
    /// folder of its own, not the sealed system volume's `/System/Library`.
    static let firmlinks: [[Substring]] = [
        "AppleInternal", "Applications", "Library", "System/Library/Caches", "System/Library/Assets",
        "System/Library/PreinstalledAssets", "System/Library/AssetsV2", "System/Library/PreinstalledAssetsV2",
        "System/Library/CoreServices/CoreTypes.bundle/Contents/Library", "System/Library/Speech", "Users", "Volumes",
        "cores", "opt", "pkg", "private", "usr/local", "usr/libexec/cups", "usr/share/snmp",
    ].map { ($0 as String).split(separator: "/").map { Substring(String($0)) } }

    /// Brings an absolute path into the form grants are compared in: no trailing slash, no
    /// empty, `.` or `..` components, and the spellings that name the same place folded into
    /// one (`/tmp` → `/private/tmp`, `/System/Volumes/Data/Users` → `/Users` for firmlinked
    /// folders, and the `/.nofollow/` prefix macOS 26.1 put in front of a resolved bookmark of
    /// the startup disk). `nil` unless the path is absolute.
    public static func normalized(_ raw: String) -> String? {
        guard raw.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        if parts.first == ".nofollow" { parts.removeFirst() }
        // The Data volume's own mount point. The volume root itself is left as it is, because
        // it is not the startup disk (the system volume is not below it), and so is everything
        // on it that no firmlink shows on the startup disk.
        if parts.count > 3, parts[0] == "System", parts[1] == "Volumes", parts[2] == "Data" {
            let rest = parts[3...]
            if firmlinks.contains(where: { rest.count >= $0.count && zip(rest, $0).allSatisfy { $0 == $1 } }) {
                parts.removeFirst(3)
            }
        }
        if let first = parts.first, first == "tmp" || first == "var" || first == "etc" { parts.insert("private", at: 0) }
        return "/" + parts.joined(separator: "/")
    }

    /// The normalized path with symbolic links resolved and, on a volume that ignores case, the
    /// letter case the disk has: the spelling a bookmark of the location resolves to. A tail
    /// that does not exist (or cannot be examined) is kept as given. `nil` unless the path is
    /// absolute.
    ///
    /// Unlike `normalized` this asks the file system. A sandboxed process may do that for
    /// locations it cannot read (measured on macOS 27.2); where it may not, the answer is the
    /// normalized path.
    public static func canonical(_ raw: String) -> String? {
        guard let given = normalized(raw) else { return nil }
        return normalized(PathSpelling.resolvingExistingPrefix(given)) ?? given
    }

    /// Whether a grant for `root` reaches `path`: the same location or anything below it.
    /// Both must be normalized. Compared by whole components (`/Users/al` does not cover
    /// `/Users/alex`).
    public static func covers(_ root: String, _ path: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        let rootParts = root.split(separator: "/"), pathParts = path.split(separator: "/")
        guard rootParts.count <= pathParts.count else { return false }
        return zip(rootParts, pathParts).allSatisfy { $0 == $1 }
    }

    /// Number of components; the startup disk is 0. Smaller means a broader grant.
    public static func depth(_ path: String) -> Int { path.split(separator: "/").count }
}

/// A mounted volume as far as grants care: where it is mounted and which disk it is.
public struct MountedVolumeIdentity: Equatable, Sendable {
    public var mountPoint: String
    public var uuid: String?

    public init(mountPoint: String, uuid: String?) {
        self.mountPoint = mountPoint
        self.uuid = uuid
    }
}

/// One stored grant: a location the user chose, and the security-scoped bookmark that lets a
/// later launch reach it again without an open panel.
public struct AccessGrantRecord: Codable, Hashable, Sendable {
    /// The granted location (`GrantPath.normalized`), in the spelling its bookmark resolves to.
    public var path: String
    public var bookmark: Data
    public var created: Date
    public var lastUsed: Date
    /// The UUID of the volume the location is on, when it is known. It tells a disk that is not
    /// connected from a broken bookmark, and two disks that mount under one name apart.
    public var volumeUUID: String?

    public init(path: String, bookmark: Data, created: Date, lastUsed: Date, volumeUUID: String? = nil) {
        self.path = path
        self.bookmark = bookmark
        self.created = created
        self.lastUsed = lastUsed
        self.volumeUUID = volumeUUID
    }

    /// The mount point of the volume the location is on, if it is one that comes and goes
    /// (`/Volumes/<name>`); `nil` for the startup disk, which is always there.
    public var removableMountPoint: String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/" + parts[1]
    }

    /// Whether `other` is a grant for the same location: the same path, and not known to be on
    /// another disk (two memory cards that both mount as `/Volumes/Untitled` are two locations).
    public func isSameGrant(as other: AccessGrantRecord) -> Bool {
        guard path == other.path else { return false }
        guard removableMountPoint != nil, let mine = volumeUUID, let theirs = other.volumeUUID else { return true }
        return mine.caseInsensitiveCompare(theirs) == .orderedSame
    }

    /// Whether the disk the location is on is not connected right now (or another disk is
    /// mounted under its name). A bookmark on such a disk cannot be resolved, which says
    /// nothing about the bookmark: the grant is kept for when the disk is back.
    public func isOnAbsentVolume(mounted: [MountedVolumeIdentity]) -> Bool {
        guard let mountPoint = removableMountPoint else { return false }
        if let volumeUUID {
            return !mounted.contains { $0.uuid?.caseInsensitiveCompare(volumeUUID) == .orderedSame }
        }
        return !mounted.contains { $0.mountPoint == mountPoint }
    }
}

/// The stored grants, as they are kept in the user defaults.
///
/// A value type with no file-system or AppKit dependency: resolving a bookmark is passed in
/// as a closure, so the rules (which grant covers what, when a record is dropped or renewed)
/// can be tested without a sandbox.
public struct AccessGrantTable: Equatable, Sendable {
    public static let currentVersion = 1
    /// More than anyone grants by hand. When it is full, grants that a broader one makes
    /// redundant go first, then the least recently used.
    public static let capacity = 64

    public private(set) var records: [AccessGrantRecord] = []

    public init() {}

    private struct Stored: Codable {
        var version: Int
        var records: [AccessGrantRecord]
    }

    /// Reads a stored table. Missing data, data that does not decode and data written by a
    /// newer version all give an empty table: the worst consequence is one more open panel.
    public init(data: Data?) {
        guard let data, let stored = try? PropertyListDecoder().decode(Stored.self, from: data),
            stored.version == Self.currentVersion
        else { return }
        for record in stored.records {
            // Never trust stored paths to be in today's normal form.
            guard let path = GrantPath.normalized(record.path), !record.bookmark.isEmpty else { continue }
            var copy = record
            copy.path = path
            if !records.contains(where: { $0.isSameGrant(as: copy) }) { records.append(copy) }
        }
    }

    public func encoded() -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return (try? encoder.encode(Stored(version: Self.currentVersion, records: records))) ?? Data()
    }

    public var isEmpty: Bool { records.isEmpty }

    /// Whether a stored grant reaches `path` (normalized).
    public func covers(_ path: String) -> Bool { records.contains { GrantPath.covers($0.path, path) } }

    /// The stored grants that reach `path`, the most specific first: it is the one closest to
    /// what the user chose (a folder picked by itself may be readable where the same folder
    /// reached through a grant for the whole disk is held back by privacy protection).
    ///
    /// - Parameter depth: only grants more specific than this many path components.
    public func candidates(covering path: String, deeperThan depth: Int? = nil) -> [AccessGrantRecord] {
        records.filter { record in GrantPath.covers(record.path, path) && (depth.map { GrantPath.depth(record.path) > $0 } ?? true) }
            .sorted { a, b in
                let da = GrantPath.depth(a.path), db = GrantPath.depth(b.path)
                if da != db { return da > db }
                return a.path != b.path ? a.path < b.path : a.lastUsed > b.lastUsed
            }
    }

    /// Stores a grant, replacing one for the same location. Grants for folders inside it are
    /// kept: the user chose those as well, and they stay usable should the broader one break.
    public mutating func insert(path: String, bookmark: Data, volumeUUID: String? = nil, now: Date) {
        guard let path = GrantPath.normalized(path), !bookmark.isEmpty else { return }
        var record = AccessGrantRecord(path: path, bookmark: bookmark, created: now, lastUsed: now, volumeUUID: volumeUUID)
        record.created = records.first { $0.isSameGrant(as: record) }?.created ?? now
        records.removeAll { $0.isSameGrant(as: record) }
        records.append(record)
        trim(keeping: record)
    }

    /// Brings the table back to its capacity. A grant that lies inside another one goes before
    /// any grant that stands alone (losing it costs nothing while the broader one works), and
    /// within each group the least recently used goes first. The record just stored stays.
    private mutating func trim(keeping kept: AccessGrantRecord) {
        while records.count > Self.capacity {
            let removable = records.indices.filter { records[$0] != kept }
            let redundant = removable.filter { index in
                records.contains { $0.path != records[index].path && GrantPath.covers($0.path, records[index].path) }
            }
            let pool = redundant.isEmpty ? removable : redundant
            guard let victim = pool.min(by: { records[$0].lastUsed < records[$1].lastUsed }) else { return }
            records.remove(at: victim)
        }
    }

    /// Removes every grant for `path`.
    @discardableResult
    public mutating func remove(path: String) -> Bool {
        let before = records.count
        records.removeAll { $0.path == path }
        return records.count != before
    }

    /// Removes exactly `record`.
    @discardableResult
    public mutating func remove(_ record: AccessGrantRecord) -> Bool {
        guard let index = records.firstIndex(of: record) else { return false }
        records.remove(at: index)
        return true
    }

    public mutating func removeAll() { records = [] }

    /// What resolving a stored bookmark gave.
    public struct Resolved<Handle> {
        /// Whatever the caller needs to use the grant (the security-scoped URL).
        public var handle: Handle
        /// Where the bookmark points now.
        public var path: String
        /// The system asks for the bookmark to be made again.
        public var isStale: Bool

        public init(handle: Handle, path: String, isStale: Bool) {
            self.handle = handle
            self.path = path
            self.isStale = isStale
        }
    }

    /// Finds a stored grant that reaches `path` and still works, repairing the table on the way.
    ///
    /// - A bookmark that does not resolve is dropped, unless its disk is merely not connected
    ///   (`isUnavailable`): then the record is kept and passed over.
    /// - A bookmark that resolves to another place (the folder was moved or renamed) is filed
    ///   under the new place; it counts only if that still reaches `path`.
    /// - A stale bookmark is made again through `renew`; if that fails the record is dropped.
    ///
    /// When nothing usable is left the answer is `nil` and the caller asks the user again.
    /// - Parameters:
    ///   - depth: only grants more specific than this many path components.
    ///   - resolve: turns a record's bookmark into a handle, or `nil` when it cannot be resolved.
    ///   - isUnavailable: whether a record that did not resolve is on a disk that is not there.
    ///   - renew: makes a fresh bookmark for a resolved handle, or `nil` when that is refused.
    public mutating func resolve<Handle>(
        covering path: String, deeperThan depth: Int? = nil, now: Date, resolve: (AccessGrantRecord) -> Resolved<Handle>?,
        isUnavailable: (AccessGrantRecord) -> Bool = { _ in false }, renew: (Handle) -> Data?
    ) -> (record: AccessGrantRecord, handle: Handle)? {
        for candidate in candidates(covering: path, deeperThan: depth) {
            guard let index = records.firstIndex(of: candidate) else { continue }
            guard let resolved = resolve(candidate), let resolvedPath = GrantPath.normalized(resolved.path) else {
                if !isUnavailable(candidate) { records.remove(at: index) }
                continue
            }
            var record = candidate
            if resolvedPath != record.path {
                // Moved: the grant follows the folder. Another record may already be there.
                records.remove(at: index)
                record.path = resolvedPath
                if records.contains(where: { $0.isSameGrant(as: record) }) { continue }
                records.append(record)
            }
            guard let current = records.firstIndex(of: record) else { continue }
            if resolved.isStale {
                guard let fresh = renew(resolved.handle), !fresh.isEmpty else {
                    records.remove(at: current)
                    continue
                }
                records[current].bookmark = fresh
            }
            guard GrantPath.covers(record.path, path) else { continue }
            records[current].lastUsed = now
            return (records[current], resolved.handle)
        }
        return nil
    }

    /// Finds a stored grant that reaches `path` and resolves right now, without changing the
    /// table: nothing is dropped, renewed, refiled or marked as used. For checks that run in
    /// the background (the Full Disk Access probe on every activation of the app), which must
    /// neither write the settings nor lose a grant over a failure that may be passing.
    public func peek<Handle>(
        covering path: String, resolve: (AccessGrantRecord) -> Resolved<Handle>?
    ) -> (record: AccessGrantRecord, handle: Handle)? {
        for candidate in candidates(covering: path) {
            guard let resolved = resolve(candidate), let resolvedPath = GrantPath.normalized(resolved.path),
                GrantPath.covers(resolvedPath, path)
            else { continue }
            var record = candidate
            record.path = resolvedPath
            return (record, resolved.handle)
        }
        return nil
    }
}

/// How far a location is within reach of a sandboxed process.
public enum AccessCoverage: Equatable, Sendable {
    /// Not sandboxed: every path is as reachable as the system allows.
    case unrestricted
    /// Inside the app's own container, or covered by a static exception in the signature.
    case implicit
    /// A grant that is in use right now covers it.
    case active
    /// A stored grant covers it; it has to be resolved and started first.
    case stored
    /// Nothing covers it: the user has to choose it in an open panel.
    case none
}

/// What can honestly be offered when the sandboxed edition was refused the scan root itself
/// although a grant covered it.
///
/// Two things can be behind that. macOS protects the folder separately (Mail, Safari,
/// Messages, other apps' data): that needs Full Disk Access in addition, and a grant does not
/// lift it. Or the grant in use, made for an enclosing folder, does not reach the location:
/// then choosing the location itself can help. Once the grant in use *is* the user's choice of
/// exactly this location, asking for it again cannot change anything and is not offered.
public struct RootDenialAdvice: Equatable, Sendable {
    /// Offer the open panel for exactly this location.
    public var offersGrantPanel: Bool
    /// Point to Full Disk Access (it is not known to be on).
    public var pointsToFullDiskAccess: Bool

    public init(offersGrantPanel: Bool, pointsToFullDiskAccess: Bool) {
        self.offersGrantPanel = offersGrantPanel
        self.pointsToFullDiskAccess = pointsToFullDiskAccess
    }

    /// - Parameters:
    ///   - root: the scan root that was refused.
    ///   - grantRoot: the location of the grant the scan ran under; `nil` when there was none.
    ///   - fullDiskAccess: what is known about Full Disk Access.
    public init(root: String, grantRoot: String?, fullDiskAccess: FullDiskAccess) {
        let chosenItself = grantRoot.flatMap(GrantPath.canonical) == GrantPath.canonical(root) && grantRoot != nil
        self.init(offersGrantPanel: !chosenItself, pointsToFullDiskAccess: fullDiskAccess != .granted)
    }
}
