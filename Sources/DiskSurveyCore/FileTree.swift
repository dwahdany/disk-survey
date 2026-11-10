import Foundation

/// Index of a node inside a ``FileTree``. The root is always `0`.
public typealias NodeID = UInt32

/// Index into ``FileTree/kinds`` (the tree's interned file-extension table). `0` means "no extension".
public typealias KindID = UInt16

/// Version of the Disk Survey engine, shared by the app and the CLI.
public enum DiskSurveyVersion {
    public static let string = "1.0.0"
}

/// Per-node attribute bits.
public struct NodeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    @inlinable public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// The node can have children. Its sizes are the sums of its children.
    public static let directory = NodeFlags(rawValue: 1 << 0)
    public static let symlink = NodeFlags(rawValue: 1 << 1)
    /// A directory presented as a single file by Finder (`.app`, `.photoslibrary`, …).
    /// Set automatically by the builder for directories with a known package extension.
    public static let package = NodeFlags(rawValue: 1 << 2)
    /// A further link to an inode that was already counted elsewhere. Stored with size 0.
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 3)
    /// Permission denied (or another error) while reading this node; its contents are unknown.
    public static let unreadable = NodeFlags(rawValue: 1 << 4)
    /// A directory on which another volume is mounted; not descended into.
    public static let mountPoint = NodeFlags(rawValue: 1 << 5)
    /// Cloud-only (dataless) file or directory: occupies no local space.
    public static let dataless = NodeFlags(rawValue: 1 << 6)
    /// Tombstone: the node was removed (or replaced) after the scan. Never listed among children.
    public static let removed = NodeFlags(rawValue: 1 << 7)
    /// Not a real filesystem entry (e.g. an aggregated "other files" node).
    public static let synthetic = NodeFlags(rawValue: 1 << 8)
}

/// One entry of a tree's kind table: a lowercase file extension and its category.
public struct FileKind: Sendable, Hashable {
    /// Lowercase extension without the dot; empty for "no extension".
    public let ext: String
    public let category: KindCategory

    public init(ext: String) {
        self.ext = ext
        self.category = FileKinds.category(forExtension: ext)
    }

    /// The reserved ``ext`` of the "Unix Executable" pseudo-kind: files without a usable
    /// extension that have an execute permission bit (the builder's `isExecutable:` hint).
    /// It contains a space, so it can never be the extension of a real file name; its category
    /// is ``KindCategory/application``. Do not print it as ".ext" — use ``displayName``.
    public static let unixExecutableExtension = "unix executable"

    /// Whether this is the "Unix Executable" pseudo-kind rather than a real extension.
    public var isUnixExecutable: Bool { ext == FileKind.unixExecutableExtension }

    /// Text for legends: ".mp4", "Unix Executable", or "No Extension".
    public var displayName: String { FileKind.displayName(forExtension: ext) }

    /// ``displayName`` for a bare extension string as found in ``ext``.
    public static func displayName(forExtension ext: String) -> String {
        if ext.isEmpty { return "No Extension" }
        return ext == unixExecutableExtension ? "Unix Executable" : "." + ext
    }
}

/// A compact, immutable-ish, `Sendable` snapshot of a scanned file hierarchy.
///
/// Storage is struct-of-arrays (about 50 bytes per node plus the name bytes), so trees with
/// millions of nodes stay small and cache friendly. Being a value type made of copy-on-write
/// arrays, a tree can be handed between threads freely; the two mutating operations
/// (``remove(_:)`` and ``replaceSubtree(at:with:)``) copy only the columns they touch if the
/// storage is shared.
///
/// Invariants (maintained by ``Builder`` and by the mutating operations):
/// - Node `0` is the root and is a directory. `parent(of: 0) == nil`.
/// - `size(of: dir)`, `logicalSize(of: dir)` and `fileCount(of: dir)` equal the sums over `children(of: dir)`.
/// - `children(of:)` is sorted by allocated size descending (ties: lower `NodeID` first) and
///   never contains nodes flagged ``NodeFlags/removed``. A removed node itself has no children
///   (`children(of:)` is empty and `childCount(of:)` is 0).
/// - Among the live links of one inode that were built with a `link:` identity, exactly one
///   carries the size; the others are flagged ``NodeFlags/hardLinkDuplicate`` with size 0.
/// - NodeIDs are stable for the lifetime of a tree value, including across mutations
///   (mutations only append nodes and tombstone old ones).
public struct FileTree: Sendable {
    /// Absolute path of the root node, without trailing slash (except for `/` itself).
    public let rootPath: String

    /// Interned extension table; `kinds[Int(kind(of: id))]`. Index 0 is always the empty extension.
    public internal(set) var kinds: [FileKind]

    /// Incremented by every mutation; handy as a cheap cache key for layouts.
    public internal(set) var revision: UInt64 = 0

    // Columns, all indexed by NodeID.
    @usableFromInline var _nameOffset: ContiguousArray<UInt32>
    @usableFromInline var _nameLength: ContiguousArray<UInt16>
    @usableFromInline var _parent: ContiguousArray<NodeID>
    @usableFromInline var _childStart: ContiguousArray<UInt32>
    @usableFromInline var _childCount: ContiguousArray<UInt32>
    @usableFromInline var _allocated: ContiguousArray<UInt64>
    @usableFromInline var _logical: ContiguousArray<UInt64>
    @usableFromInline var _fileCount: ContiguousArray<UInt32>
    @usableFromInline var _mtime: ContiguousArray<UInt32>
    @usableFromInline var _kind: ContiguousArray<KindID>
    @usableFromInline var _flags: ContiguousArray<UInt16>

    /// Sibling lists: node `n`'s children are `_childIndex[_childStart[n] ..< _childStart[n] + _childCount[n]]`.
    /// Keeping the order here (rather than in the NodeIDs) lets siblings be re-sorted without renumbering.
    @usableFromInline var _childIndex: ContiguousArray<NodeID>
    /// All names, UTF-8, back to back.
    @usableFromInline var _namePool: ContiguousArray<UInt8>

    var _kindLookup: [String: KindID]

    /// Hard-link identities, sparse: one entry per live file that was appended with a `link:`
    /// (the counted link and the duplicates alike), with the size that link would carry.
    var _links: [NodeID: LinkInfo]

    init(
        rootPath: String, kinds: [FileKind],
        nameOffset: ContiguousArray<UInt32>, nameLength: ContiguousArray<UInt16>,
        parent: ContiguousArray<NodeID>, childStart: ContiguousArray<UInt32>,
        childCount: ContiguousArray<UInt32>, allocated: ContiguousArray<UInt64>,
        logical: ContiguousArray<UInt64>, fileCount: ContiguousArray<UInt32>,
        mtime: ContiguousArray<UInt32>, kind: ContiguousArray<KindID>,
        flags: ContiguousArray<UInt16>, childIndex: ContiguousArray<NodeID>,
        namePool: ContiguousArray<UInt8>, links: [NodeID: LinkInfo] = [:]
    ) {
        self.rootPath = rootPath
        self.kinds = kinds
        _nameOffset = nameOffset; _nameLength = nameLength; _parent = parent
        _childStart = childStart; _childCount = childCount
        _allocated = allocated; _logical = logical; _fileCount = fileCount
        _mtime = mtime; _kind = kind; _flags = flags
        _childIndex = childIndex; _namePool = namePool
        _links = links
        var lookup: [String: KindID] = [:]
        lookup.reserveCapacity(kinds.count)
        for (i, k) in kinds.enumerated() { lookup[k.ext] = KindID(i) }
        _kindLookup = lookup
    }

    /// A tree consisting of just an empty root directory.
    public static func empty(rootPath: String = "/") -> FileTree {
        Builder(rootPath: rootPath).finalize()
    }

    // MARK: - Hot accessors

    /// Number of node slots, including tombstoned (removed) nodes. Valid NodeIDs are `0 ..< count`.
    @inlinable public var count: Int { _parent.count }

    /// The root node (always `0`).
    @inlinable public var root: NodeID { 0 }

    /// Physical (allocated) size in bytes; for directories the sum over all descendants.
    @inlinable public func size(of id: NodeID) -> UInt64 { _allocated[Int(id)] }

    /// Logical size (end-of-file) in bytes; for directories the sum over all descendants.
    @inlinable public func logicalSize(of id: NodeID) -> UInt64 { _logical[Int(id)] }

    /// Number of non-directory descendants (1 for a plain file, 0 for an empty directory).
    @inlinable public func fileCount(of id: NodeID) -> Int { Int(_fileCount[Int(id)]) }

    /// Modification time in seconds since 1970, or 0 if unknown.
    @inlinable public func modified(of id: NodeID) -> Int64 { Int64(_mtime[Int(id)]) }

    @inlinable public func kind(of id: NodeID) -> KindID { _kind[Int(id)] }

    @inlinable public func flags(of id: NodeID) -> NodeFlags { NodeFlags(rawValue: _flags[Int(id)]) }

    @inlinable public func isDirectory(_ id: NodeID) -> Bool {
        _flags[Int(id)] & NodeFlags.directory.rawValue != 0
    }

    @inlinable public func isRemoved(_ id: NodeID) -> Bool {
        _flags[Int(id)] & NodeFlags.removed.rawValue != 0
    }

    /// The parent, or `nil` for the root.
    @inlinable public func parent(of id: NodeID) -> NodeID? {
        id == 0 ? nil : _parent[Int(id)]
    }

    /// Children sorted by allocated size, largest first. Never contains removed nodes, and is
    /// empty for a removed node.
    ///
    /// The result is a slice of the tree's shared child-index array: no allocation, but note that
    /// its indices do not start at 0 — use `startIndex`/`first`/iteration, or ``child(of:at:)``.
    @inlinable public func children(of id: NodeID) -> ArraySlice<NodeID> {
        let start = Int(_childStart[Int(id)])
        return _childIndex[start ..< start + Int(_childCount[Int(id)])]
    }

    @inlinable public func childCount(of id: NodeID) -> Int { Int(_childCount[Int(id)]) }

    /// The `index`-th largest child (zero based).
    @inlinable public func child(of id: NodeID, at index: Int) -> NodeID {
        precondition(index >= 0 && index < Int(_childCount[Int(id)]), "child index out of range")
        return _childIndex[Int(_childStart[Int(id)]) + index]
    }

    /// Raw UTF-8 bytes of the node's name (a slice of the shared pool; no allocation).
    @inlinable public func nameUTF8(of id: NodeID) -> ArraySlice<UInt8> {
        let start = Int(_nameOffset[Int(id)])
        return _namePool[start ..< start + Int(_nameLength[Int(id)])]
    }

    // MARK: - Names, paths, hierarchy

    /// The node's file name. For the root this is the last component of ``rootPath`` (or "/").
    public func name(of id: NodeID) -> String {
        let start = Int(_nameOffset[Int(id)])
        let length = Int(_nameLength[Int(id)])
        return _namePool.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(rebasing: $0[start ..< start + length]), as: UTF8.self)
        }
    }

    /// Absolute path of the node.
    public func path(of id: NodeID) -> String {
        if id == 0 { return rootPath }
        var chain: [NodeID] = []
        var total = 0
        var node = id
        while node != 0 {
            chain.append(node)
            total += Int(_nameLength[Int(node)]) + 1
            node = _parent[Int(node)]
        }
        var bytes = ContiguousArray<UInt8>()
        bytes.reserveCapacity(rootPath.utf8.count + total)
        if rootPath != "/" { bytes.append(contentsOf: rootPath.utf8) }
        for node in chain.reversed() {
            bytes.append(0x2F)
            bytes.append(contentsOf: nameUTF8(of: node))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The exact bytes of the node's absolute path as the file system knows it (no trailing NUL):
    /// ``rootPath`` followed by the raw name bytes. Unlike ``path(of:)`` this is not lossy for
    /// names that are not valid UTF-8 — use it for `lstat`/`open` and friends.
    public func fileSystemPath(of id: NodeID) -> [UInt8] {
        var chain: [NodeID] = []
        var total = 0
        var node = id
        while node != 0 {
            chain.append(node)
            total += Int(_nameLength[Int(node)]) + 1
            node = _parent[Int(node)]
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rootPath.utf8.count + total)
        if rootPath != "/" || id == 0 { bytes.append(contentsOf: rootPath.utf8) }
        for node in chain.reversed() {
            bytes.append(0x2F)
            bytes.append(contentsOf: nameUTF8(of: node))
        }
        return bytes
    }

    /// Whether ``path(of:)`` cannot name this node on disk: its name, or the name of one of its
    /// ancestors below the root, is not valid UTF-8 (possible on NFS and some foreign volumes),
    /// so the `String` path had those bytes replaced by U+FFFD. Such a path must never be handed
    /// to the file system: at best the entry looks missing, at worst it names a different file.
    /// ``url(of:)`` and ``fileSystemPath(of:)`` stay exact.
    public func hasLossyPath(_ id: NodeID) -> Bool {
        var node = id
        while node != 0 {
            let name = nameUTF8(of: node)
            if name.contains(where: { $0 >= 0x80 }), String(validating: name, as: UTF8.self) == nil { return true }
            node = _parent[Int(node)]
        }
        return false
    }

    /// File URL of the node. Byte-exact even when ``hasLossyPath(_:)`` is true (the URL then
    /// carries the raw name bytes percent-encoded; read them back with
    /// `withUnsafeFileSystemRepresentation`, not `path`).
    public func url(of id: NodeID) -> URL {
        if hasLossyPath(id) {
            // CoreFoundation percent-encodes the raw bytes; `URL(fileURLWithFileSystemRepresentation:)`
            // would decode them as UTF-8 and bring U+FFFD back.
            let bytes = fileSystemPath(of: id)
            if let url = CFURLCreateFromFileSystemRepresentation(nil, bytes, bytes.count, isDirectory(id)) {
                return url as URL
            }
        }
        return URL(fileURLWithPath: path(of: id), isDirectory: isDirectory(id))
    }

    public func modificationDate(of id: NodeID) -> Date? {
        let t = _mtime[Int(id)]
        return t == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(t))
    }

    /// The kind table entry of a node.
    @inlinable public func fileKind(of id: NodeID) -> FileKind { kinds[Int(_kind[Int(id)])] }

    @inlinable public func category(of id: NodeID) -> KindCategory { kinds[Int(_kind[Int(id)])].category }

    /// Looks up the id of a (case-insensitive) extension in this tree's kind table.
    public func kindID(forExtension ext: String) -> KindID? { _kindLookup[ext.lowercased()] }

    /// Number of edges between the node and the root (root: 0).
    public func depth(of id: NodeID) -> Int {
        var depth = 0
        var node = id
        while node != 0 {
            depth += 1
            node = _parent[Int(node)]
        }
        return depth
    }

    /// Ancestors from the parent up to the root (nearest first); empty for the root.
    public func ancestors(of id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var node = id
        while node != 0 {
            node = _parent[Int(node)]
            result.append(node)
        }
        return result
    }

    /// The chain root → … → `id`, including both ends. Convenient for breadcrumbs.
    public func lineage(of id: NodeID) -> [NodeID] {
        var result = ancestors(of: id)
        result.reverse()
        result.append(id)
        return result
    }

    /// Whether `ancestor` is a strict ancestor of `node`.
    public func isAncestor(_ ancestor: NodeID, of node: NodeID) -> Bool {
        var current = node
        while current != 0 {
            current = _parent[Int(current)]
            if current == ancestor { return true }
        }
        return false
    }

    /// The direct child with exactly this name (byte-wise; falls back to Unicode canonical
    /// equivalence so NFC/NFD spellings of the same name both resolve).
    public func child(of id: NodeID, named name: String) -> NodeID? {
        var name = name
        let exact: NodeID? = name.withUTF8 { needle in
            _namePool.withUnsafeBufferPointer { pool in
                for child in children(of: id) {
                    let length = Int(_nameLength[Int(child)])
                    guard length == needle.count else { continue }
                    if length == 0
                        || memcmp(pool.baseAddress! + Int(_nameOffset[Int(child)]), needle.baseAddress!, length) == 0
                    {
                        return child
                    }
                }
                return nil
            }
        }
        if exact != nil || name.utf8.allSatisfy({ $0 < 0x80 }) { return exact }
        return children(of: id).first { self.name(of: $0) == name }
    }

    /// Resolves an absolute path to a node. Returns `nil` if the path is outside the tree,
    /// was not scanned, or has been removed.
    public func node(atPath path: String) -> NodeID? {
        var rest = Substring(path)
        if rootPath != "/" {
            guard rest.hasPrefix(rootPath) else { return nil }
            rest = rest.dropFirst(rootPath.count)
            guard rest.isEmpty || rest.first == "/" else { return nil }
        } else {
            guard rest.first == "/" else { return nil }
        }
        var node: NodeID = 0
        for component in rest.split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = child(of: node, named: String(component)) else { return nil }
            node = next
        }
        return node
    }

    /// Visits every live descendant of `root` (excluding `root` itself) in pre-order, larger
    /// siblings first. Visits nothing if `root` has been removed.
    @inlinable public func forEachDescendant(of root: NodeID, _ body: (NodeID) throws -> Void) rethrows {
        var stack: [NodeID] = []
        stack.append(contentsOf: children(of: root).reversed())
        while let node = stack.popLast() {
            try body(node)
            if _childCount[Int(node)] != 0 {
                stack.append(contentsOf: children(of: node).reversed())
            }
        }
    }

    /// Approximate heap memory used by this tree, in bytes.
    public var memoryFootprint: Int {
        let perNode =
            MemoryLayout<UInt32>.stride * 6  // nameOffset, parent, childStart, childCount, fileCount, mtime
            + MemoryLayout<UInt16>.stride * 3  // nameLength, kind, flags
            + MemoryLayout<UInt64>.stride * 2  // allocated, logical
        // Dictionaries keep some slack; 4/3 is their maximum load factor inverted.
        let links = _links.capacity * (MemoryLayout<NodeID>.stride + MemoryLayout<LinkInfo>.stride + 1)
        return count * perNode + _childIndex.count * MemoryLayout<NodeID>.stride + _namePool.count + links
    }
}

// MARK: - Hard links

extension FileTree {
    /// Identity of an inode: the device and file id of a file with several hard links.
    public struct LinkID: Hashable, Sendable {
        public var device: Int32
        public var inode: UInt64

        public init(device: Int32, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    /// What the tree remembers about one link of a multiply-linked file.
    struct LinkInfo: Hashable, Sendable {
        var id: LinkID
        /// The sizes this link carries when it is the counted one (as scanned).
        var allocated: UInt64
        var logical: UInt64
    }

    /// The inode identity of a live node that was built with one (a file with several hard
    /// links); `nil` for everything else, including removed nodes.
    public func linkID(of id: NodeID) -> LinkID? { _links[id]?.id }

    /// Number of live files recorded as links of multiply-linked inodes.
    public var linkedFileCount: Int { _links.count }
}
