import Foundation
import Security

/// Whether this process runs inside the macOS App Sandbox, and the facts that differ there.
///
/// One code base serves both editions: the sandbox is applied by the code signature
/// (`com.apple.security.app-sandbox`), not by the compiler, so everything that has to behave
/// differently asks `AppSandbox.isSandboxed` at run time.
public enum AppSandbox {
    /// The entitlement that puts a process in the sandbox.
    public static let sandboxEntitlement = "com.apple.security.app-sandbox"
    /// Static read-write exceptions for absolute paths. Only the harness build
    /// (`Scripts/build-app.sh --sandbox --sandbox-test-access`) carries this; it stands in for
    /// a person choosing the disk in an open panel.
    public static let absolutePathExceptionEntitlement = "com.apple.security.temporary-exception.files.absolute-path.read-write"

    /// Whether the process is sandboxed. Fixed for the life of the process.
    public static let isSandboxed: Bool = detect(
        environment: ProcessInfo.processInfo.environment, entitlement: ownsEntitlement(sandboxEntitlement))

    /// The rule behind `isSandboxed`.
    ///
    /// The process's own signature decides: the sandbox is switched on by the entitlement in it
    /// and by nothing else. `APP_SANDBOX_CONTAINER_ID`, which the system sets for a sandboxed
    /// process, is inherited by whatever that process starts, so by itself it proves nothing: a
    /// normal build started from a shell that descends from a sandboxed app carries the variable
    /// without being confined. It is consulted only when the signature cannot be read at all.
    ///
    /// - Parameter entitlement: what the signature says about `com.apple.security.app-sandbox`
    ///   (absent counts as `false`); `nil` when the process's entitlements cannot be read.
    public static func detect(environment: [String: String], entitlement: Bool?) -> Bool {
        if let entitlement { return entitlement }
        if let container = environment["APP_SANDBOX_CONTAINER_ID"], !container.isEmpty { return true }
        return false
    }

    /// The value of one of this process's own entitlements; `nil` when it has none by that name.
    public static func entitlementValue(_ name: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }

    /// Whether this process's signature carries the boolean entitlement `name` set to true.
    /// `false` when it is absent; `nil` only when the entitlements cannot be read at all.
    public static func ownsEntitlement(_ name: String) -> Bool? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, name as CFString, &error)
        if let error {
            error.release()
            if value == nil { return nil }
        }
        return (value as? Bool) ?? false
    }

    /// The account's home directory from the user database.
    ///
    /// Inside the sandbox `NSHomeDirectory()`, `FileManager.homeDirectoryForCurrentUser` and
    /// `~` expansion all name the app's container instead; everything shown to the user as
    /// "Home", "Desktop" and so on must come from here.
    public static let realHomeDirectory: String = {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            let path = String(cString: directory)
            if path.hasPrefix("/") { return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
        }
        return NSHomeDirectory()
    }()

    /// `path` with a leading `~` replaced by the real home directory (`~user` is left to
    /// Foundation, which reads the user database for it).
    public static func expandingTilde(_ path: String, home: String = realHomeDirectory) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        return path
    }

    /// Absolute paths the signature lets the process read and write without anybody choosing
    /// them (see `absolutePathExceptionEntitlement`). Empty in every build meant for people.
    public static let staticReadWritePaths: [String] = {
        guard isSandboxed, let paths = entitlementValue(absolutePathExceptionEntitlement) as? [String] else { return [] }
        return paths.compactMap(GrantPath.normalized)
    }()

    /// Locations a sandboxed process may always use: its container and its temporary folder,
    /// in every spelling they are likely to be met in. Empty when not sandboxed.
    public static let containerPaths: [String] = {
        guard isSandboxed else { return [] }
        var result: [String] = []
        for raw in [NSHomeDirectory(), NSTemporaryDirectory()] {
            for candidate in [raw, PathSpelling.resolvingExistingPrefix(raw)] {
                if let path = GrantPath.normalized(candidate), path != "/", !result.contains(path) { result.append(path) }
            }
        }
        return result
    }()
}
