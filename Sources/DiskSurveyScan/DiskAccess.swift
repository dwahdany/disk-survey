import Foundation

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
    public static func hasFullDiskAccess() -> Bool {
        let home = realHomeDirectory()
        let probes = [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/CloudTabs.db",
            home + "/Library/Safari/Bookmarks.plist",
        ]
        for path in probes {
            let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
            // ENOENT and friends: this probe says nothing, try the next.
        }
        // Last resort: protected directories that exist on every account.
        for path in [home + "/Library/Safari", home + "/Library/Mail"] {
            if let directory = opendir(path) {
                closedir(directory)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return false
    }

    /// The account's home directory from the user database — inside an app sandbox
    /// `NSHomeDirectory()` would point at the container instead.
    static func realHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }
}
