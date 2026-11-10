import Foundation
import DiskSurveyCore

/// Moves scanned items to the Trash and works out what that does to a `FileTree`.
///
/// This is the one place that decides what may be trashed and whether an item on disk is still
/// the item the scan saw. It has no UI and takes the actual "move to Trash" step as a closure,
/// so the rules and the tree update can be tested without touching the user's Trash.
///
/// ## What is guaranteed
/// - A **file** is moved only if it is still the same kind of item with the same length.
/// - A **folder** is moved only if a fresh look at it finds exactly what the tree shows: the
///   same number of entries and files and the same total length, and no volume mounted anywhere
///   below it. A folder the scan never finished, a folder holding excluded items and a folder
///   that grew or shrank are therefore left alone ("changed since the scan").
/// - No symlink is followed on the way to the item, so a folder that was swapped for a link
///   cannot redirect the move to something outside the scanned tree.
/// - Put Back moves an item out of the Trash only if it is the very item that was put there.
///
/// These are checks followed by a move; the system offers no way to make the two one step. In
/// the moment between them an item can still change. Everything lands in the Trash, where it
/// can be recovered.
public struct TrashService: Sendable {
    /// Moves one item to the Trash and returns where it ended up (`nil` if the system does not say).
    public typealias Mover = @Sendable (URL) throws -> URL?
    /// Returns the mount point of every mounted filesystem, as the kernel spells it.
    public typealias MountPointSource = @Sendable () -> [String]

    /// Why a node is never offered for trashing — the coarse reasons reported by
    /// ``candidates(for:in:mountPointPaths:)``. ``review(_:in:rules:)`` reports finer ones.
    public enum Refusal: Sendable, Hashable {
        case scanRoot, mountPoint, synthetic, removed
        /// The item's name (or a folder's above it) is not valid UTF-8, so its path cannot be
        /// written as a `String` and the checks before a move could look at the wrong item.
        case unrepresentableName
    }

    /// What ``review(_:in:rules:)`` should know besides the tree.
    public struct Rules: Sendable {
        /// Mount points of volumes known to the caller, in any spelling. A node at one of them
        /// is protected, and so is every folder above one.
        public var mountPointPaths: Set<String>
        /// The ``ScanOptions/excludedPaths`` the tree was scanned with. A folder above one of
        /// them holds items the tree does not show and is protected.
        public var excludedPaths: [String]
        /// The ``ScanOptions/excludedPathsFollowSymlinks`` the tree was scanned with.
        public var excludedPathsFollowSymlinks: Bool
        /// The scan was stopped before it finished, so any folder may be shown with less than
        /// it holds. Folders are then protected until they are rescanned; files are not.
        public var scanWasCancelled: Bool

        public init(
            mountPointPaths: Set<String> = [], excludedPaths: [String] = [], scanWasCancelled: Bool = false,
            excludedPathsFollowSymlinks: Bool = true
        ) {
            self.mountPointPaths = mountPointPaths
            self.excludedPaths = excludedPaths
            self.excludedPathsFollowSymlinks = excludedPathsFollowSymlinks
            self.scanWasCancelled = scanWasCancelled
        }
    }

    /// A node that ``review(_:in:rules:)`` protects, and why.
    public struct Rejection: Sendable, Hashable {
        public enum Reason: Sendable, Hashable {
            case scanRoot, mountPoint, synthetic, removed
            /// A folder with a volume mounted somewhere below it. Moving the folder would carry
            /// the live volume into the Trash.
            case containsMountPoint
            /// A folder holding an item that was excluded from the scan.
            case containsExcludedPath
            /// A folder of a scan that was stopped early; its contents may not be fully known.
            case incompleteScan
            /// The item's path contains a name that is not valid UTF-8 (see
            /// `FileTree.hasLossyPath`). Its `String` path names nothing, or something else, so
            /// it is never examined or moved — and so can never be mistaken for a vanished item.
            case unrepresentableName
        }
        public var node: NodeID
        public var reason: Reason
        /// For ``Reason/containsMountPoint`` and ``Reason/containsExcludedPath``: the path of the
        /// mount point or excluded item (one of them, if there are several).
        public var detail: String?

        /// The nearest ``Refusal``.
        public var refusal: Refusal {
            switch reason {
            case .scanRoot: .scanRoot
            case .mountPoint, .containsMountPoint, .containsExcludedPath, .incompleteScan: .mountPoint
            case .synthetic: .synthetic
            case .removed: .removed
            case .unrepresentableName: .unrepresentableName
            }
        }
    }

    /// What the tree shows inside a folder, for comparison with the folder on disk.
    public struct Contents: Sendable, Hashable {
        /// Entries of every kind below the folder.
        public var entries: Int
        /// Non-directory entries below the folder.
        public var files: Int
        public var logicalSize: UInt64
        /// Some file below is a further link to an inode counted elsewhere (stored with size 0).
        /// A fresh look at the folder alone counts such a file in full, so the length can then
        /// only be checked as a lower bound.
        public var hasHardLinkDuplicates: Bool

        public init(entries: Int, files: Int, logicalSize: UInt64, hasHardLinkDuplicates: Bool) {
            self.entries = entries
            self.files = files
            self.logicalSize = logicalSize
            self.hasHardLinkDuplicates = hasHardLinkDuplicates
        }
    }

    /// One item to trash, with what the scan knew about it.
    public struct Candidate: Sendable, Hashable {
        public var node: NodeID
        public var path: String
        public var isDirectory: Bool
        public var isSymlink: Bool
        /// Logical length recorded by the scan; `nil` when it is not comparable with `st_size`
        /// (hard-link duplicates are stored with size 0, cloud-only files have no local data).
        public var expectedLength: UInt64?
        /// For a folder: what the tree shows inside it. `nil` skips the comparison with the
        /// folder on disk (though not the search for volumes mounted inside it);
        /// ``review(_:in:rules:)`` always fills it in.
        public var expectedContents: Contents?

        public init(
            node: NodeID, path: String, isDirectory: Bool, isSymlink: Bool, expectedLength: UInt64?,
            expectedContents: Contents? = nil
        ) {
            self.node = node
            self.path = path
            self.isDirectory = isDirectory
            self.isSymlink = isSymlink
            self.expectedLength = expectedLength
            self.expectedContents = expectedContents
        }
    }

    /// What identifies an item in the Trash as the one that was moved there.
    public struct Identity: Sendable, Hashable {
        public var device: Int32
        public var inode: UInt64
        /// `st_mode & S_IFMT`.
        public var type: UInt16
        /// Length, for regular files (inode numbers can be reused after a deletion).
        public var length: UInt64?

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            type = UInt16(info.st_mode & S_IFMT)
            length = info.st_mode & S_IFMT == S_IFREG ? UInt64(max(0, info.st_size)) : nil
        }
    }

    public struct Trashed: Sendable, Hashable {
        public var node: NodeID
        public var originalPath: String
        /// Location inside the Trash; `nil` if unknown, in which case the item cannot be put back.
        public var trashURL: URL?
        /// The item as it lies in the Trash; `nil` if it could not be examined there, in which
        /// case it cannot be put back either (nothing would say it is still the same item).
        public var identity: Identity?
    }

    public struct Failure: Sendable, Hashable {
        public enum Reason: Sendable, Hashable {
            /// The item is a different kind of thing, or a file of a different length, or a
            /// folder with other contents, than at scan time — or it is now reached through a
            /// symlink.
            case changedSinceScan
            /// A volume is mounted somewhere below the folder.
            case containsMountPoint
            case error(String)
        }
        public var path: String
        public var reason: Reason

        public var message: String {
            switch reason {
            case .changedSinceScan: "Changed since the scan"
            case .containsMountPoint: "Contains a mounted volume; eject it first"
            case .error(let text): text
            }
        }
    }

    public struct Outcome: Sendable {
        public var trashed: [Trashed] = []
        /// Items that no longer existed. They leave the tree as well, but nothing was freed by us.
        public var missing: [NodeID] = []
        public var failures: [Failure] = []

        /// Every node that should leave the tree.
        public var removedNodes: [NodeID] { trashed.map(\.node) + missing }
    }

    private let mover: Mover
    private let mountPoints: MountPointSource

    /// - Parameters:
    ///   - mover: the "move to Trash" step; defaults to `FileManager.trashItem`.
    ///   - mountPoints: the current mount points; defaults to the kernel's mount table, read
    ///     without waiting for unresponsive volumes.
    public init(mover: Mover? = nil, mountPoints: MountPointSource? = nil) {
        self.mover = mover ?? { url in
            var resulting: NSURL?
            try FileManager().trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }
        self.mountPoints = mountPoints ?? { MountTable.readMounts().map(\.mountPoint) }
    }

    // MARK: What may be trashed

    /// Splits `nodes` into items that may be trashed and items that are protected.
    ///
    /// Protected: the scan root, mount points (by flag or by `mountPointPaths`) and folders with
    /// a mount point anywhere below them, synthetic entries and nodes already removed. A node
    /// inside another listed node is dropped silently, because trashing the outer one covers it.
    ///
    /// A folder above a mount point is reported as ``Refusal/mountPoint``; use
    /// ``review(_:in:rules:)`` to tell the cases apart and to apply the other rules.
    public static func candidates(
        for nodes: [NodeID], in tree: FileTree, mountPointPaths: Set<String> = []
    ) -> (candidates: [Candidate], refused: [(node: NodeID, reason: Refusal)]) {
        let result = review(nodes, in: tree, rules: Rules(mountPointPaths: mountPointPaths))
        return (result.candidates, result.rejected.map { ($0.node, $0.refusal) })
    }

    /// Splits `nodes` into items that may be trashed and items that are protected, saying
    /// precisely why. See ``Rules`` and ``Rejection/Reason``.
    ///
    /// Walks the tree below each selected folder once (no I/O beyond resolving the few paths in
    /// `rules`), so it is fine to call on the main thread.
    public static func review(
        _ nodes: [NodeID], in tree: FileTree, rules: Rules = Rules()
    ) -> (candidates: [Candidate], rejected: [Rejection]) {
        var listed = NodeBitset(capacity: tree.count)
        for node in nodes where Int(node) < tree.count { listed.insert(node) }
        var seen = NodeBitset(capacity: tree.count)
        var candidates: [Candidate] = []
        var rejected: [Rejection] = []
        // Paths from outside are brought into the tree's spelling once, and only if needed.
        var mountSpellings: [String]?
        var excludedSpellings: [String]?
        func spellings(_ paths: some Sequence<String>, resolvingItem: Bool) -> [String] {
            var all: [String] = []
            for raw in paths {
                all.append(contentsOf: PathSpelling.variants(of: raw, rootPath: tree.rootPath, resolvingItem: resolvingItem))
            }
            return all
        }

        for node in nodes where Int(node) < tree.count && !seen.contains(node) {
            seen.insert(node)
            if tree.isRemoved(node) {
                rejected.append(Rejection(node: node, reason: .removed))
                continue
            }
            var covered = false
            var current = tree.parent(of: node)
            while let ancestor = current {
                if listed.contains(ancestor) { covered = true; break }
                current = tree.parent(of: ancestor)
            }
            if covered { continue }
            let flags = tree.flags(of: node)
            let path = tree.path(of: node)
            if node == tree.root {
                rejected.append(Rejection(node: node, reason: .scanRoot))
                continue
            }
            if !rules.mountPointPaths.isEmpty, mountSpellings == nil {
                // The mount points themselves are not examined: one may be unreachable.
                mountSpellings = spellings(rules.mountPointPaths, resolvingItem: false)
            }
            if flags.contains(.mountPoint) || mountSpellings?.contains(path) == true {
                rejected.append(Rejection(node: node, reason: .mountPoint))
                continue
            }
            if flags.contains(.synthetic) {
                rejected.append(Rejection(node: node, reason: .synthetic))
                continue
            }
            if tree.hasLossyPath(node) {
                rejected.append(Rejection(node: node, reason: .unrepresentableName))
                continue
            }
            guard tree.isDirectory(node) else {
                let comparable = !flags.contains(.hardLinkDuplicate) && !flags.contains(.dataless)
                candidates.append(Candidate(
                    node: node, path: path, isDirectory: false, isSymlink: flags.contains(.symlink),
                    expectedLength: comparable ? tree.logicalSize(of: node) : nil))
                continue
            }

            // A folder goes with everything inside it, so what is inside decides.
            var entries = 0
            var hardLinks = false
            var mountBelow: NodeID?
            tree.forEachDescendant(of: node) { id in
                let flags = tree.flags(of: id)
                if flags.contains(.synthetic) { return }
                entries += 1
                if flags.contains(.hardLinkDuplicate) { hardLinks = true }
                // Also set on firmlinks that were not followed; a folder holding one of those
                // does not belong in the Trash either.
                if mountBelow == nil, flags.contains(.mountPoint) { mountBelow = id }
            }
            if let mountBelow {
                rejected.append(Rejection(node: node, reason: .containsMountPoint, detail: tree.path(of: mountBelow)))
                continue
            }
            if let mount = mountSpellings?.first(where: { PathSpelling.isPath($0, below: path) }) {
                rejected.append(Rejection(node: node, reason: .containsMountPoint, detail: mount))
                continue
            }
            if !rules.excludedPaths.isEmpty {
                if excludedSpellings == nil {
                    excludedSpellings = spellings(
                        rules.excludedPaths, resolvingItem: rules.excludedPathsFollowSymlinks)
                }
                if let excluded = excludedSpellings?.first(where: { PathSpelling.isPath($0, below: path) }) {
                    rejected.append(Rejection(node: node, reason: .containsExcludedPath, detail: excluded))
                    continue
                }
            }
            if rules.scanWasCancelled {
                rejected.append(Rejection(node: node, reason: .incompleteScan))
                continue
            }
            candidates.append(Candidate(
                node: node, path: path, isDirectory: true, isSymlink: false, expectedLength: nil,
                expectedContents: Contents(
                    entries: entries, files: tree.fileCount(of: node), logicalSize: tree.logicalSize(of: node),
                    hasHardLinkDuplicates: hardLinks)))
        }
        return (candidates, rejected)
    }

    // MARK: Trashing

    /// Moves the candidates to the Trash. Blocking; call it off the main thread.
    ///
    /// Only what the scan saw is trashed (see the type's documentation for the exact checks).
    /// For a folder that means reading it again first, which takes about as long as scanning
    /// that folder did. An item that vanished is reported as `missing`.
    public func trash(_ candidates: [Candidate]) -> Outcome {
        var outcome = Outcome()
        var mounted: [String]?
        for candidate in candidates {
            func fail(_ reason: Failure.Reason) { outcome.failures.append(Failure(path: candidate.path, reason: reason)) }

            // Like lstat, but refusing symlinks in the directories leading to the item as well:
            // scan paths contain none, so one that appears now is a folder that was swapped.
            var info = stat()
            if fstatat(AT_FDCWD, candidate.path, &info, AT_SYMLINK_NOFOLLOW_ANY) != 0 {
                let code = errno
                if code == ENOENT || code == ENOTDIR {
                    outcome.missing.append(candidate.node)
                } else if code == ELOOP {
                    fail(.changedSinceScan)
                } else {
                    fail(.error(String(cString: strerror(code))))
                }
                continue
            }
            let type = info.st_mode & S_IFMT
            let sameType = candidate.isSymlink ? type == S_IFLNK : (candidate.isDirectory ? type == S_IFDIR : type != S_IFDIR && type != S_IFLNK)
            let sameLength =
                candidate.isDirectory || candidate.isSymlink || candidate.expectedLength == nil
                || UInt64(max(0, info.st_size)) == candidate.expectedLength
            guard sameType, sameLength else {
                fail(.changedSinceScan)
                continue
            }
            if candidate.isDirectory {
                // Whatever the tree says, look at what is mounted now: a volume may have been
                // mounted after the scan, or be unknown to whoever built the candidates.
                if mounted == nil { mounted = mountPoints() }
                if TrashService.mountPoint(below: candidate.path, among: mounted ?? []) != nil {
                    fail(.containsMountPoint)
                    continue
                }
                if let problem = TrashService.compare(candidate.expectedContents, withFolderAt: candidate.path) {
                    fail(problem)
                    continue
                }
            }
            do {
                let destination = try mover(URL(fileURLWithPath: candidate.path))
                // Remember the item as it lies in the Trash (a move to another volume's Trash
                // copies, which gives it a new inode), so that Put Back can recognize it.
                var identity: Identity?
                var moved = stat()
                if let destination, lstat(destination.path, &moved) == 0 { identity = Identity(moved) }
                outcome.trashed.append(Trashed(
                    node: candidate.node, originalPath: candidate.path, trashURL: destination, identity: identity))
            } catch {
                fail(.error(error.localizedDescription))
            }
        }
        return outcome
    }

    /// The first of `mountPoints` that lies below `directory`, if any.
    ///
    /// The kernel spells mount points with symlinks resolved and without the Data volume's
    /// prefix, so the directory is brought into that form first. (A mount point's recorded path
    /// goes stale when a folder above it is renamed, so this cannot be the only check.)
    static func mountPoint(below directory: String, among mountPoints: [String]) -> String? {
        var forms = [directory]
        if let resolved = PathSpelling.realPath(directory), resolved != directory { forms.append(resolved) }
        for form in forms {
            let stripped = PathSpelling.strippingDataVolumePrefix(form)
            if !forms.contains(stripped) { forms.append(stripped) }
        }
        return mountPoints.first { mount in forms.contains { PathSpelling.isPath(mount, below: $0) } }
    }

    /// Reads the folder again and says how it differs from what the tree showed, if it does.
    ///
    /// Uses the scanner itself, with default options: fast, and it never enters another volume
    /// nor honours exclusions — so a mount point below shows up as such, and excluded items
    /// count as the contents they are.
    /// Without `expected` only mount points are looked for.
    private static func compare(_ expected: Contents?, withFolderAt path: String) -> Failure.Reason? {
        let session = ScanSession(root: URL(fileURLWithPath: path, isDirectory: true))
        session.start()
        let result = session.waitBlocking()
        guard result.rootKind == .directory, !result.wasCancelled else { return .changedSinceScan }
        if result.stats.mountPointsSkipped != 0 || result.stats.mountPointsEntered != 0 { return .containsMountPoint }
        guard let expected else { return nil }
        let tree = result.tree
        guard tree.count - 1 == expected.entries, tree.fileCount(of: tree.root) == expected.files else {
            return .changedSinceScan
        }
        let length = tree.logicalSize(of: tree.root)
        let sameLength = expected.hasHardLinkDuplicates ? expected.logicalSize <= length : expected.logicalSize == length
        return sameLength ? nil : .changedSinceScan
    }

    /// Takes everything the outcome removed out of `tree` and returns what left it.
    /// Ancestor totals and sibling order are fixed up by `FileTree.remove`.
    @discardableResult
    public static func apply(_ outcome: Outcome, to tree: inout FileTree) -> FileTree.Totals {
        let nodes = outcome.removedNodes.filter { Int($0) < tree.count && $0 != tree.root }
        guard !nodes.isEmpty else { return .zero }
        return tree.remove(nodes)
    }

    // MARK: Putting back

    /// Moves trashed items back to where they were.
    ///
    /// Never overwrites: if something else now has the original name, the item stays in the
    /// Trash and is reported as a failure. Never moves a stranger: what lies at the remembered
    /// place in the Trash must be the item that was put there (the Trash may have been emptied
    /// and the name reused since). And never follows a symlink that replaced a folder on the
    /// way to the original location.
    public static func putBack(_ items: [Trashed]) -> (restored: [String], failures: [Failure]) {
        var restored: [String] = []
        var failures: [Failure] = []
        let manager = FileManager()
        for item in items {
            func fail(_ text: String) { failures.append(Failure(path: item.originalPath, reason: .error(text))) }
            guard let source = item.trashURL else {
                fail("Its place in the Trash is not known")
                continue
            }
            guard let identity = item.identity else {
                fail("It could not be identified in the Trash")
                continue
            }
            var info = stat()
            if lstat(source.path, &info) != 0 {
                let code = errno
                fail(code == ENOENT || code == ENOTDIR ? "No longer in the Trash" : String(cString: strerror(code)))
                continue
            }
            guard Identity(info) == identity else {
                fail("The item in the Trash is not the one Disk Survey moved there")
                continue
            }
            if lstat(item.originalPath, &info) == 0 {
                fail("An item with this name exists now")
                continue
            }
            let parent = (item.originalPath as NSString).deletingLastPathComponent
            if fstatat(AT_FDCWD, parent, &info, AT_SYMLINK_NOFOLLOW_ANY) != 0 || info.st_mode & S_IFMT != S_IFDIR {
                fail("The folder it was in no longer exists")
                continue
            }
            do {
                try manager.moveItem(at: source, to: URL(fileURLWithPath: item.originalPath))
                restored.append(item.originalPath)
            } catch {
                fail(error.localizedDescription)
            }
        }
        return (restored, failures)
    }
}
