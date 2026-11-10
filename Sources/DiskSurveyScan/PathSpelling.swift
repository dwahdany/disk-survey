import Foundation

/// The different ways one location can be written, and how to bring a caller's spelling into
/// the form a scan uses.
///
/// A scan builds every path as "resolved root + names". A path that comes from somewhere else —
/// an exclusion from the settings, a volume's mount point — may name the same place differently:
/// through a symlink (`/tmp` for `/private/tmp`, `/var`, `/etc`, any user symlink) or through the
/// Data volume's own mount point (`/System/Volumes/Data/Users` for `/Users`). Comparing such a
/// path byte for byte with scan paths silently never matches, so both sides go through here.
enum PathSpelling {
    static let dataVolumePrefix = MountPolicy.dataVolumeMountPoint

    /// Removes trailing slashes; `nil` unless the path is absolute.
    static func trimmed(_ raw: String) -> String? {
        var path = raw
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.hasPrefix("/") ? path : nil
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `realpath` that tolerates a tail that does not exist (or cannot be examined): the longest
    /// ancestor that resolves is resolved and the remaining components are appended as given.
    static func resolvingExistingPrefix(_ path: String) -> String {
        if let whole = realPath(path) { return whole }
        var head = Substring(path)
        var tail: [Substring] = []
        while let slash = head.lastIndex(of: "/") {
            tail.append(head[head.index(after: slash)...])
            head = head[..<slash]
            let ancestor = head.isEmpty ? "/" : String(head)
            if let resolved = realPath(ancestor) {
                let rest = tail.reversed().joined(separator: "/")
                return resolved == "/" ? "/" + rest : resolved + "/" + rest
            }
            if head.isEmpty { break }
        }
        return path
    }

    /// The path with everything but its last component resolved. This is how a scan spells an
    /// *entry*: a symlink appears under its own name in its (real) parent directory. It also
    /// never touches the item itself, so it is safe for mount points of unreachable volumes.
    static func resolvingParent(_ path: String) -> String {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return path }
        let parent = slash == path.startIndex ? "/" : String(path[..<slash])
        let resolved = resolvingExistingPrefix(parent)
        let name = path[path.index(after: slash)...]
        return resolved == "/" ? "/" + name : resolved + "/" + name
    }

    /// Every spelling under which `raw` can show up among the paths of a scan rooted at
    /// `rootPath` (already resolved). Empty when `raw` is not absolute.
    ///
    /// - Parameter resolvingItem: also resolve the item itself, so that naming a symlink covers
    ///   what it points at. Leave it off for paths whose last component must not be examined.
    static func variants(of raw: String, rootPath: String, resolvingItem: Bool = true) -> [String] {
        guard let given = trimmed(raw) else { return [] }
        var spellings = [given]
        func add(_ path: String) { if !spellings.contains(path) { spellings.append(path) } }
        add(resolvingParent(given))
        if resolvingItem { add(resolvingExistingPrefix(given)) }

        // `realpath` leaves the Data volume's mount point alone in both directions, so add the
        // spelling that agrees with how the root is written.
        let rootIsAliased = rootPath == dataVolumePrefix || rootPath.hasPrefix(dataVolumePrefix + "/")
        for path in spellings {
            let aliased = path.hasPrefix(dataVolumePrefix + "/")
            if rootIsAliased {
                if !aliased, path != dataVolumePrefix, !path.hasPrefix("/System/Volumes/") {
                    add(path == "/" ? dataVolumePrefix : dataVolumePrefix + path)
                }
            } else if aliased {
                add(String(path.dropFirst(dataVolumePrefix.count)))
            }
        }
        return spellings
    }

    /// `path` without a leading Data-volume mount point (`/System/Volumes/Data/Users` → `/Users`),
    /// which is the form the kernel's mount table uses.
    static func strippingDataVolumePrefix(_ path: String) -> String {
        path.hasPrefix(dataVolumePrefix + "/") ? String(path.dropFirst(dataVolumePrefix.count)) : path
    }

    /// Whether `path` lies strictly below `directory` (compared by path components).
    static func isPath(_ path: String, below directory: String) -> Bool {
        directory == "/" ? path.count > 1 && path.hasPrefix("/") : path.hasPrefix(directory + "/")
    }
}
