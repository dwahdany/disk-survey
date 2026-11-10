import Foundation
import DiskSurveyCore

// MARK: - Options

/// What a scan covers and how hard it works.
///
/// ## Mount points (the short version)
/// By default a scan stays on the volume it starts on: a directory that has another filesystem
/// mounted on it is kept in the tree as an empty node flagged ``NodeFlags/mountPoint`` and is not
/// entered. Two refinements make scanning the startup disk (`/`) come out right:
///
/// - **Firmlinks.** On macOS the read-only system volume is mounted at `/` and the writable Data
///   volume at `/System/Volumes/Data`; directories such as `/Users`, `/Applications`, `/Library`,
///   `/private`, `/opt` are *firmlinks* from the first into the second. The kernel resolves
///   firmlinks transparently (same device id, not reported as mount points), so a scan of `/`
///   walks into the Data volume's content by itself. The Data volume's own mount point,
///   `/System/Volumes/Data`, is therefore never entered when the root is `/` — that would count
///   everything a second time.
/// - **Sibling volumes.** `/System/Volumes/VM` (swap), `Preboot`, `Update` and other local volumes
///   of the same APFS container (for example a `/nix` store volume) share the startup disk's free
///   space, so a scan of `/` includes them (``includeSiblingSystemVolumes``), flagged as mount
///   points. Volumes under `/Volumes`, volumes of other containers, network, `devfs`, `autofs`
///   and `nullfs` mounts are not entered.
public struct ScanOptions: Sendable, Hashable {
    /// Enter every mounted filesystem found below the root (other disks, network shares, disk
    /// images). Pseudo filesystems (`devfs`, `autofs`, `nullfs`, automount triggers) and — when
    /// the root is `/` — the Data volume's second appearance at `/System/Volumes/Data` are still
    /// skipped, because they hold no data of their own or would double count.
    public var crossMountPoints = false

    /// Number of scanning threads. `0` picks a value measured to be near the throughput plateau
    /// on Apple silicon and Intel Macs (see ``ScanOptions/automaticThreadCount``).
    public var threadCount = 0

    /// Absolute paths that are left out of the tree entirely (files or directories).
    ///
    /// Any spelling of a location works: the scanner resolves symlinks in each path (`/tmp/x`
    /// excludes `/private/tmp/x`, and naming a symlink to a folder excludes both the link and
    /// the folder) and matches the Data volume's two names (`/Users/x` and
    /// `/System/Volumes/Data/Users/x`) to whichever the scan root uses. Relative paths are ignored.
    public var excludedPaths: [String] = []

    /// Whether an exclusion that names a symlink also covers what the link points at (the
    /// default, which suits paths picked in a file dialog, where a link is resolved for the
    /// user). `false` excludes exactly the named entry: the link disappears from the tree and
    /// its target stays. Symlinks in the *directories leading to* the entry are resolved either
    /// way, so `/tmp/x` keeps matching `/private/tmp/x`.
    public var excludedPathsFollowSymlinks = true

    /// When scanning `/`: follow firmlinks into the Data volume (`/Users`, `/Applications`, …).
    /// Turning this off scans only the sealed system volume; firmlinked directories then appear
    /// as empty nodes flagged ``NodeFlags/mountPoint``. Has no effect for other roots.
    public var followFirmlinkedDataVolume = true

    /// When scanning `/`: also enter the other local volumes of the startup disk's APFS container
    /// (`/System/Volumes/VM`, `Preboot`, `Update`, …), which consume the same free space.
    public var includeSiblingSystemVolumes = true

    /// Diagnostic switch: `false` forces the portable `readdir` + `fstatat` enumeration that is
    /// otherwise used only on filesystems without `getattrlistbulk` support.
    public var useBulkAttributes = true

    /// Diagnostic switch: `false` disables the shortcuts that use directory entry counts to
    /// avoid opening empty directories and to save the final "no more entries" call. The
    /// resulting tree, flags and issues are the same either way; this exists to verify exactly
    /// that. (An empty directory is skipped only if its owner and mode say this process may
    /// read it; any other is opened and, if that fails, reported like every unreadable
    /// directory. The one difference left: an *empty* directory that the mode allows but an
    /// access-control list or macOS privacy protection denies is not reported while the
    /// shortcuts are on.)
    public var useEntryCountHints = true

    /// Diagnostic switch: `false` turns off the watchdog that gets a scan thread out of a
    /// directory `open` the system has stopped answering (see ``ScanStats/interruptedDirectoryOpens``).
    /// The tree is the same either way; without the watchdog each such `open` holds the scan
    /// up for five seconds.
    public var interruptStalledOpens = true

    public init() {}

    /// The thread count used for `threadCount == 0`: one per core, at most 16.
    ///
    /// Measured on a 12-core Apple silicon Mac (APFS, internal SSD): with everything cached the
    /// scan rate peaks at 6–8 threads (the performance cores) and stays within about 10% of
    /// that up to 12; when the kernel has to fetch metadata — the first scan, and any tree with
    /// more directories than the kernel's vnode cache holds — the scan is latency-bound and
    /// keeps improving up to one thread per core. The second case is where the seconds are, so
    /// it decides. Beyond the core count nothing improves.
    public static var automaticThreadCount: Int {
        max(2, min(ProcessInfo.processInfo.activeProcessorCount, 16))
    }
}

// MARK: - Progress

/// A cheap point-in-time view of a running scan.
public struct ScanProgress: Sendable, Hashable {
    /// Non-directory entries seen so far (files, symlinks, sockets, …).
    public var filesScanned: UInt64 = 0
    /// Directory entries seen so far (not counting the root).
    public var directoriesScanned: UInt64 = 0
    /// Physical bytes; hard-link duplicates are not counted again.
    public var bytesAllocated: UInt64 = 0
    /// Logical bytes; hard-link duplicates are not counted again.
    public var bytesLogical: UInt64 = 0
    /// Directories or entries that could not be read.
    public var errorCount: UInt64 = 0
    /// A directory that was being read recently ("" before the scan starts).
    public var currentPath = ""
    /// Seconds since `start()`; frozen once the scan has finished.
    public var elapsed: TimeInterval = 0
    public var isFinished = false

    public init() {}

    public var entriesScanned: UInt64 { filesScanned + directoriesScanned }
    public var entriesPerSecond: Double { elapsed > 0 ? Double(entriesScanned) / elapsed : 0 }
}

// MARK: - Issues

/// Something the scanner could not read. The scan continues past every issue.
public struct ScanIssue: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// `EACCES` / `EPERM`: Unix permissions or macOS privacy protection (Full Disk Access).
        case permissionDenied
        case other
    }

    public var path: String
    public var errno: Int32
    public var kind: Kind

    public init(path: String, errno: Int32) {
        self.path = path
        self.errno = errno
        kind = (errno == EACCES || errno == EPERM) ? .permissionDenied : .other
    }

    /// The system's description of `errno` ("Permission denied").
    public var message: String { String(cString: strerror(errno)) }
}

// MARK: - Result

public struct ScanStats: Sendable, Hashable {
    /// Entries in the tree, not counting the root.
    public var entries: UInt64 = 0
    public var files: UInt64 = 0
    public var directories: UInt64 = 0
    public var symlinks: UInt64 = 0
    /// Additional links to an inode that was already counted (stored with size 0).
    public var hardLinkDuplicates: UInt64 = 0
    /// Files and directories whose content lives only in the cloud.
    public var datalessEntries: UInt64 = 0
    /// Mount points (and firmlinks, when not followed) that were kept but not entered.
    public var mountPointsSkipped: UInt64 = 0
    /// Mount points that were entered.
    public var mountPointsEntered: UInt64 = 0
    /// Entries left out because of ``ScanOptions/excludedPaths``.
    public var excludedEntries: UInt64 = 0
    /// Directories read through the `readdir` fallback.
    public var fallbackDirectories: UInt64 = 0
    public var threadCount = 0
    /// Entries per second over the whole scan (enumeration plus building the tree).
    public var entriesPerSecond: Double = 0
    /// Seconds spent reading the filesystem.
    public var enumerationDuration: TimeInterval = 0
    /// Seconds spent turning the collected entries into the final tree.
    public var assemblyDuration: TimeInterval = 0
    /// The longest any single directory took to open, in seconds. Opening normally takes tens
    /// of microseconds; a value in the seconds means the scan was held up by the system (the
    /// other threads have nothing to do while the last subtrees wait behind such a call), so
    /// the duration says little about scanning speed.
    public var slowestDirectoryOpen: TimeInterval = 0
    /// The directory behind ``slowestDirectoryOpen``; empty unless that open counted as slow.
    public var slowestDirectoryPath = ""
    /// Directories that took 0.1 s or longer to open.
    public var slowDirectoryOpens: UInt64 = 0
    /// Times a directory `open` that had stopped making progress was interrupted and retried.
    /// macOS occasionally leaves a thread waiting for five seconds for a privacy decision
    /// (access to another app's container) that has long been made; the scanner cuts that wait
    /// short after a quarter of a second. Each one still counts in ``slowDirectoryOpens``.
    public var interruptedDirectoryOpens: UInt64 = 0

    public init() {}
}

public struct ScanResult: Sendable {
    /// What the scan root turned out to be.
    public enum RootKind: Sendable, Hashable {
        case directory
        /// The root was a single file. The tree's root is then the file's *containing directory*
        /// (a tree root is always a directory) with that file as its only child.
        case file
        /// The root does not exist or could not be examined; the tree is empty and flagged
        /// ``NodeFlags/unreadable``, and `issues` says why.
        case inaccessible
    }

    /// At most this many issues are kept in ``issues``.
    public static let issueLimit = 1000

    public var tree: FileTree
    public var duration: TimeInterval
    /// The first ``issueLimit`` issues, sorted by path.
    public var issues: [ScanIssue]
    /// All issues that occurred, including those dropped from ``issues``.
    public var totalIssueCount: Int
    public var wasCancelled: Bool
    public var stats: ScanStats
    public var rootKind: RootKind
    /// The root with symlinks resolved — what was actually scanned. For a file root, the file.
    public var resolvedRootPath: String

    public var permissionDeniedCount: Int { issues.count { $0.kind == .permissionDenied } }

    /// Whether the scan root itself was refused for lack of permission, so that nothing below
    /// it was seen. Either it could not even be examined (`inaccessible`), or — the usual case
    /// for a folder macOS protects separately, which can be examined but not listed — it came
    /// back as a directory with no entries and the refusal as its issue.
    public var rootWasRefused: Bool {
        guard rootKind != .file, !wasCancelled, tree.count <= 1 else { return false }
        return issues.contains { $0.kind == .permissionDenied && $0.path == resolvedRootPath }
    }
}
