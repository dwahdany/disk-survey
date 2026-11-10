import Foundation

/// What is known about Full Disk Access for this process.
public enum FullDiskAccess: Equatable, Sendable {
    /// A location that only Full Disk Access unlocks could be read.
    case granted
    /// Such a location exists, was within reach of the process, and macOS refused it.
    case notGranted
    /// Sandboxed only: none of the probe locations is covered by a folder or disk the user
    /// allowed, so the sandbox refuses them whatever the privacy setting says.
    case unknown
}

/// Detects whether macOS privacy protection (TCC) lets this process read the whole disk.
public enum DiskAccess {
    /// Opens the Full Disk Access pane of System Settings when passed to the workspace / `open`.
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!

    /// Whether the process appears to have Full Disk Access.
    ///
    /// There is no API for this, so the check probes files that only Full Disk Access unlocks:
    /// the privacy databases themselves and a few other always-protected locations. Reading
    /// those without the permission fails with `EPERM` *silently* — unlike Desktop, Documents,
    /// Downloads or removable volumes, they never raise a consent prompt, so this is safe to
    /// call at launch. If none of the probe files exists the answer is `false`.
    ///
    /// This is the answer for a process that is not sandboxed. Inside the App Sandbox the same
    /// probes are refused by the sandbox first; use `fullDiskAccessState(reachable:)` there.
    public static func hasFullDiskAccess() -> Bool {
        evaluate(home: realHomeDirectory(), sandboxed: false, reachable: { _ in true }, probe: probe) == .granted
    }

    /// Full Disk Access as far as it can be told, in either edition.
    ///
    /// Not sandboxed, the answer is `granted` or `notGranted`, exactly as `hasFullDiskAccess()`.
    /// Sandboxed, Full Disk Access comes on top of the access the user gave by choosing a disk
    /// or folder: a probe location says something only if such a grant reaches it right now
    /// (`reachable`). With none in reach the answer is `unknown`.
    public static func fullDiskAccessState(
        sandboxed: Bool = AppSandbox.isSandboxed, reachable: (String) -> Bool = { _ in false }
    ) -> FullDiskAccess {
        evaluate(home: realHomeDirectory(), sandboxed: sandboxed, reachable: reachable, probe: probe)
    }

    /// The paths the check looks at (for callers that have to bring them within reach first).
    public static var probePaths: [String] { probeLocations(home: realHomeDirectory()).map(\.path) }

    /// The locations the check looks at, in order; `directory` ones are opened as folders.
    static func probeLocations(home: String) -> [(path: String, directory: Bool)] {
        [
            (home + "/Library/Application Support/com.apple.TCC/TCC.db", false),
            ("/Library/Application Support/com.apple.TCC/TCC.db", false),
            (home + "/Library/Safari/CloudTabs.db", false),
            (home + "/Library/Safari/Bookmarks.plist", false),
            // Last resort: protected directories that exist on every account.
            (home + "/Library/Safari", true),
            (home + "/Library/Mail", true),
        ]
    }

    enum ProbeResult { case readable, denied, absent }

    /// The decision, with the file system passed in.
    static func evaluate(
        home: String, sandboxed: Bool, reachable: (String) -> Bool, probe: (_ path: String, _ directory: Bool) -> ProbeResult
    ) -> FullDiskAccess {
        for location in probeLocations(home: home) {
            if sandboxed, !reachable(location.path) { continue }
            switch probe(location.path, location.directory) {
            case .readable: return .granted
            case .denied: return .notGranted
            case .absent: continue  // ENOENT and friends: this probe says nothing, try the next.
            }
        }
        // Nothing conclusive. Not sandboxed that has always counted as "no"; sandboxed it means
        // that no probe location was within reach (or none exists).
        return sandboxed ? .unknown : .notGranted
    }

    private static func probe(_ path: String, directory: Bool) -> ProbeResult {
        if directory {
            if let handle = opendir(path) {
                closedir(handle)
                return .readable
            }
        } else {
            let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            if fd >= 0 {
                close(fd)
                return .readable
            }
        }
        return errno == EPERM || errno == EACCES ? .denied : .absent
    }

    /// The account's home directory from the user database — inside an app sandbox
    /// `NSHomeDirectory()` would point at the container instead.
    public static func realHomeDirectory() -> String { AppSandbox.realHomeDirectory }
}
