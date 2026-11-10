import Foundation

// MARK: - Small internals shared by the builder

/// A plain `os_unfair_lock` on the heap (so its address is stable).
final class UnfairLock: @unchecked Sendable {
    private let pointer: os_unfair_lock_t

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always) func lock() { os_unfair_lock_lock(pointer) }
    @inline(__always) func unlock() { os_unfair_lock_unlock(pointer) }
}

/// Column used while assembling a tree. Several threads fill disjoint ranges through the raw
/// pointer `p` (which side-steps Array's exclusivity rules), and the finished column is handed
/// to the tree by ``take()`` **without copying**: the elements are written straight into the
/// `ContiguousArray` the tree will own.
///
/// Invariants that make the escaped pointer valid:
/// - `storage` is uniquely referenced, never resized and never accessed through the array
///   between `init` and `take()`, so its buffer does not move and nothing else observes it;
/// - `p` must not be used after `take()`;
/// - `T` is a trivial type (plain integers): the array is marked as initialized before the
///   elements are written, so a column that is not `zeroed` must be filled completely.
final class Column<T: BitwiseCopyable>: @unchecked Sendable {
    private var storage: ContiguousArray<T>
    let p: UnsafeMutablePointer<T>
    let count: Int

    init(_ count: Int, zeroed: Bool = false) {
        self.count = count
        // Capacity is at least 1 so that even an empty column owns a buffer.
        storage = ContiguousArray(unsafeUninitializedCapacity: max(count, 1)) { buffer, initialized in
            if zeroed, count > 0 { memset(buffer.baseAddress!, 0, count * MemoryLayout<T>.stride) }
            initialized = count
        }
        // An empty array may still report no base address; such a column is never dereferenced.
        p = storage.withUnsafeMutableBufferPointer { $0.baseAddress }
            ?? UnsafeMutablePointer(bitPattern: MemoryLayout<T>.alignment)!
    }

    /// Moves the finished array out, leaving the column empty. The caller gets the only
    /// reference, so later in-place mutations of the tree do not trigger a copy.
    func take() -> ContiguousArray<T> {
        var result = ContiguousArray<T>()
        swap(&result, &storage)
        return result
    }
}

/// Carries pointers (and arrays of them) into `concurrentPerform` blocks. Safe where used because
/// every block touches a disjoint range of the pointed-to memory.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// A lowercase extension of up to 16 ASCII bytes packed into two words: cheap to hash and compare.
struct ExtKey: Hashable, Sendable {
    var lo: UInt64 = 0
    var hi: UInt64 = 0

    static let maxLength = 16

    /// The empty key ("no extension").
    init() {}

    /// Reserved key of the "Unix executable" pseudo-kind (``FileKind/unixExecutableExtension``).
    /// It contains a space, which `init?(name:length:)` never accepts, so no file name can
    /// produce it.
    static let unixExecutable: ExtKey = {
        var key = ExtKey()
        for (j, c) in FileKind.unixExecutableExtension.utf8.enumerated() {
            precondition(j < maxLength)
            if j < 8 { key.lo |= UInt64(c) << UInt64(8 * j) } else { key.hi |= UInt64(c) << UInt64(8 * (j - 8)) }
        }
        return key
    }()

    /// Parses the extension of a file name. Returns `nil` when there is none worth interning:
    /// no dot, a leading dot only (".gitignore"), longer than 16 bytes, characters other than
    /// ASCII letters/digits/`_`/`-`, or digits only ("log.1", "file.20240101").
    @inline(__always)
    init?(name: UnsafePointer<UInt8>, length: Int) {
        var i = length - 1
        let stop = max(1, length - 1 - ExtKey.maxLength)
        var sawLetter = false
        while i >= stop {
            let byte = name[i]
            if byte == 0x2E {
                let extLength = length - 1 - i
                guard extLength > 0, sawLetter else { return nil }
                for j in 0 ..< extLength {
                    var c = name[i + 1 + j]
                    if c &- 0x41 < 26 { c |= 0x20 }
                    if j < 8 { lo |= UInt64(c) << UInt64(8 * j) } else { hi |= UInt64(c) << UInt64(8 * (j - 8)) }
                }
                return
            }
            let lower = byte | 0x20
            if lower &- 0x61 < 26 || byte == 0x5F || byte == 0x2D {
                sawLetter = true
            } else if byte &- 0x30 >= 10 {
                return nil
            }
            i -= 1
        }
        return nil
    }

    var string: String {
        var bytes: [UInt8] = []
        for j in 0 ..< 16 {
            let c = UInt8(truncatingIfNeeded: j < 8 ? lo >> UInt64(8 * j) : hi >> UInt64(8 * (j - 8)))
            if c == 0 { break }
            bytes.append(c)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Builder

extension FileTree {
    /// Collects raw filesystem entries from any number of threads and turns them into a ``FileTree``.
    ///
    /// ## Model
    /// Every scanning thread owns a ``Worker`` (from ``makeWorker()``). A worker appends entries to
    /// its private arena; each `append` names the parent directory with a ``Ref`` and returns the
    /// `Ref` of the new entry, which is what you hand to whichever thread later lists that
    /// subdirectory. Refs are plain values, valid on every worker of the same builder. The root
    /// directory already exists as ``Ref/root``.
    ///
    /// ```swift
    /// let builder = FileTree.Builder(rootPath: "/Users/me", rootModified: mtime)
    /// // one worker per scanning thread:
    /// let worker = builder.makeWorker()
    /// // listing directory `dir` (a Ref; `.root` for the top) on that thread:
    /// for entry in directoryListing {
    ///     let ref = worker.append(
    ///         to: dir, name: entry.nameBytes,               // UnsafeBufferPointer<UInt8>, no NUL
    ///         allocatedSize: entry.allocated, logicalSize: entry.logical,
    ///         modified: entry.mtimeSeconds, flags: entry.isDirectory ? .directory : [])
    ///     if entry.isDirectory { queue.push(path: …, ref: ref) }   // any thread may pick this up
    /// }
    /// // if opening a queued directory later fails with EACCES:
    /// builder.addFlags(.unreadable, to: ref)
    /// // from a UI/progress thread, every now and then:
    /// let partial = builder.snapshot()
    /// // when all threads are done:
    /// let tree = builder.finalize()
    /// ```
    ///
    /// ## What the builder computes
    /// - NodeIDs, the name pool, and the kind table (lowercase extensions; ``NodeFlags/package`` is
    ///   added to directories with a known package extension).
    /// - Directory totals bottom-up: a directory's allocated/logical size and file count are the
    ///   sums of its children. **Sizes passed for a directory entry itself are ignored.**
    /// - Entries flagged ``NodeFlags/hardLinkDuplicate`` are stored with both sizes 0, so every
    ///   inode is counted once (detecting duplicates is the scanner's job). Pass the inode's
    ///   identity as `link:` for **every** link of a multiply-linked file (the counted one and
    ///   the duplicates, each with its real sizes): the tree then keeps "counted once" true when
    ///   links are later removed or a folder is rescanned on its own.
    /// - Files without a usable extension that are appended with `isExecutable: true` get the
    ///   "Unix Executable" pseudo-kind (``FileKind/unixExecutableExtension``) instead of kind 0.
    /// - Non-directory entries count as `itemCount` files (default 1; use more for a synthetic
    ///   node that aggregates several files).
    /// - Sibling lists sorted by allocated size descending.
    ///
    /// ## Thread-safety contract
    /// - `Builder` is fully thread-safe: ``makeWorker()``, ``addFlags(_:to:)``, ``entryCount``,
    ///   ``snapshot()`` and ``finalize()`` may be called from any thread at any time.
    /// - A `Worker` is safe to use from any thread, and even concurrently, but is designed for
    ///   one thread at a time: each `append` takes that worker's own lock, which is uncontended
    ///   (a few nanoseconds) when every thread uses its own worker. Workers never contend with
    ///   each other.
    /// - ``snapshot()`` briefly holds all worker locks at once to capture a consistent cut — every
    ///   entry in the snapshot has its parent in the snapshot — then assembles the tree with no
    ///   locks held. Scanning continues meanwhile. A directory may appear partially filled; its
    ///   totals reflect what has been appended so far. Assembling costs O(entries so far), so
    ///   throttle snapshots (e.g. no more often than a few times the last snapshot's duration).
    /// - NodeIDs are **not** comparable between two snapshots, or between a snapshot and the final
    ///   tree (ids are assigned per worker arena, and arenas keep growing). Carry selections across
    ///   snapshots by path (``FileTree/path(of:)`` / ``FileTree/node(atPath:)``), not by id.
    /// - ``finalize()`` must be called once, after all appends have returned. Appending or
    ///   snapshotting afterwards is a programming error and traps.
    public final class Builder: @unchecked Sendable {
        /// Identifies a directory (or any entry) added to a builder. A plain value; valid on all
        /// workers of the builder that produced it.
        public struct Ref: Hashable, Sendable {
            @usableFromInline let raw: UInt64
            @usableFromInline init(raw: UInt64) { self.raw = raw }
            /// The root directory of the tree.
            public static let root = Ref(raw: .max)
        }

        public let rootPath: String
        private let rootModified: Int64
        private let lock = UnfairLock()
        private var rootFlags: NodeFlags
        private var workers: [Worker] = []
        private var finalized = false

        /// - Parameters:
        ///   - rootPath: absolute path of the scanned directory. A trailing slash is dropped.
        ///   - rootModified: modification time of the root, seconds since 1970 (0 = unknown).
        ///   - rootFlags: extra flags for the root (``NodeFlags/directory`` is implied).
        public init(rootPath: String, rootModified: Int64 = 0, rootFlags: NodeFlags = []) {
            var path = rootPath
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            self.rootPath = path.isEmpty ? "/" : path
            self.rootModified = rootModified
            self.rootFlags = rootFlags.union(.directory)
        }

        /// Creates the arena for one scanning thread.
        public func makeWorker() -> Worker {
            lock.lock()
            defer { lock.unlock() }
            precondition(!finalized, "FileTree.Builder used after finalize()")
            let worker = Worker(index: UInt32(workers.count))
            workers.append(worker)
            return worker
        }

        /// ORs flags into an entry that was appended earlier (by any worker) — typically
        /// ``NodeFlags/unreadable`` once opening a directory fails.
        public func addFlags(_ flags: NodeFlags, to ref: Ref) {
            lock.lock()
            if ref == .root {
                rootFlags.formUnion(flags)
                lock.unlock()
                return
            }
            let workerIndex = Int(ref.raw >> 32)
            precondition(workerIndex < workers.count, "Ref does not belong to this builder")
            let worker = workers[workerIndex]
            lock.unlock()
            worker.addPatch(local: UInt32(truncatingIfNeeded: ref.raw), flags: flags)
        }

        /// Number of entries appended so far (excluding the root). Cheap; fine for progress UI.
        public var entryCount: Int {
            lock.lock()
            let workers = self.workers
            lock.unlock()
            var total = 0
            for worker in workers { total += worker.currentCount }
            return total
        }

        /// A consistent tree of everything appended so far. See the thread-safety contract above.
        public func snapshot() -> FileTree {
            let (captures, flags) = capture(final: false)
            return Assembler.assemble(
                rootPath: rootPath, rootFlags: flags, rootModified: rootModified, captures: captures)
        }

        /// Produces the final tree and releases the builder's arenas. The arenas are handed over
        /// to the assembly, which unmaps every chunk as soon as it has been copied into the tree.
        public func finalize() -> FileTree {
            let (captures, flags) = capture(final: true)
            return Assembler.assemble(
                rootPath: rootPath, rootFlags: flags, rootModified: rootModified, captures: captures)
        }

        func capture(final: Bool) -> (CaptureSet, NodeFlags) {
            lock.lock()
            defer { lock.unlock() }
            precondition(!finalized, "FileTree.Builder used after finalize()")
            finalized = final
            // All worker locks are held together so the cut is consistent: an entry can only be
            // appended after its parent's append returned, hence if the entry made the cut, so did
            // its parent.
            for worker in workers { worker.lock.lock() }
            let parts = workers.map { $0.capture(seal: final) }
            for worker in workers { worker.lock.unlock() }
            return (CaptureSet(parts), rootFlags)
        }

        // MARK: Worker

        /// A per-thread arena of raw entries. Obtain one per scanning thread via ``Builder/makeWorker()``.
        public final class Worker: @unchecked Sendable {
            static let entriesPerChunk = 8192
            static let nameChunkSize = 1 << 16
            static let maxNameLength = 4096

            let index: UInt32
            let lock = UnfairLock()

            // Chunks are raw fixed-capacity buffers that never move: a snapshot keeps references to
            // them and reads only the prefix that existed when it was captured, while the worker
            // keeps writing behind that prefix. That makes snapshots O(#chunks) instead of O(bytes).
            private var entryChunks: [RawChunk<RawEntry>] = []
            private var nameChunks: [RawChunk<UInt8>] = []
            /// Total name bytes appended before each entry chunk began.
            private var chunkNameStart: [Int] = []
            private var patches: [FlagPatch] = []
            private var links: [LinkRecord] = []
            private var entriesInLastChunk = Worker.entriesPerChunk
            private var bytesInLastNameChunk = Worker.nameChunkSize
            private var count = 0
            private var nameBytes = 0
            private var sealed = false

            init(index: UInt32) { self.index = index }

            /// Appends one directory entry.
            ///
            /// - Parameters:
            ///   - parent: the directory this entry lives in (``Ref/root`` or a `Ref` returned by an
            ///     earlier `append` on any worker for an entry flagged `.directory`).
            ///   - name: the entry's file name as UTF-8, without a trailing NUL (copied).
            ///   - allocatedSize: physical bytes on disk. Ignored for directories.
            ///   - logicalSize: logical length in bytes. Ignored for directories.
            ///   - modified: modification time, seconds since 1970 (0 = unknown).
            ///   - flags: include `.directory` for anything that will get children.
            ///   - itemCount: how many files this non-directory entry stands for (normally 1).
            ///   - link: identity of the inode, for files with more than one hard link. Pass it for
            ///     the counted link and for every ``NodeFlags/hardLinkDuplicate`` alike, always
            ///     together with the real sizes. Ignored for directories.
            ///   - isExecutable: the file has an execute permission bit. Only consulted for
            ///     non-directory, non-symlink entries whose name has no usable extension.
            /// - Returns: the `Ref` of the new entry, to be used as `parent` for its children.
            @discardableResult
            public func append(
                to parent: Ref,
                name: UnsafeBufferPointer<UInt8>,
                allocatedSize: UInt64,
                logicalSize: UInt64,
                modified: Int64,
                flags: NodeFlags = [],
                itemCount: UInt32 = 1,
                link: FileTree.LinkID? = nil,
                isExecutable: Bool = false
            ) -> Ref {
                let length = min(name.count, Worker.maxNameLength)
                lock.lock()
                defer { lock.unlock() }
                precondition(!sealed, "FileTree.Builder.Worker used after finalize()")

                // A new chunk is needed when the name does not fit, and also when the current chunk
                // is exactly full (which includes the "no chunk yet" initial state): otherwise an
                // empty name would be given offset 65536, which does not fit the 16-bit offset
                // field of `nameRef` (or, on a fresh worker, chunk index -1).
                if bytesInLastNameChunk + length > Worker.nameChunkSize
                    || bytesInLastNameChunk == Worker.nameChunkSize
                {
                    nameChunks.append(RawChunk(capacity: Worker.nameChunkSize))
                    bytesInLastNameChunk = 0
                }
                let nameChunk = nameChunks.count - 1
                if length > 0 {
                    memcpy(nameChunks[nameChunk].p + bytesInLastNameChunk, name.baseAddress!, length)
                }
                assert(nameChunk >= 0 && bytesInLastNameChunk < Worker.nameChunkSize)
                let nameRef = UInt32(nameChunk) << 16 | UInt32(bytesInLastNameChunk)
                bytesInLastNameChunk += length

                if entriesInLastChunk == Worker.entriesPerChunk {
                    entryChunks.append(RawChunk(capacity: Worker.entriesPerChunk))
                    chunkNameStart.append(nameBytes)
                    entriesInLastChunk = 0
                }
                entryChunks[entryChunks.count - 1].p[entriesInLastChunk] = RawEntry(
                    parent: parent.raw, allocated: allocatedSize, logical: logicalSize,
                    nameRef: nameRef, mtime: UInt32(clamping: modified), itemCount: itemCount,
                    nameLength: UInt16(length),
                    flags: (flags.rawValue & ~RawEntry.executableHint) | (isExecutable ? RawEntry.executableHint : 0))
                entriesInLastChunk += 1

                let local = count
                precondition(local < Int(UInt32.max), "too many entries in one worker")
                if let link, !flags.contains(.directory) {
                    links.append(
                        LinkRecord(
                            local: UInt32(local), device: link.device, inode: link.inode,
                            allocated: allocatedSize, logical: logicalSize))
                }
                count += 1
                nameBytes += length
                return Ref(raw: UInt64(index) << 32 | UInt64(local))
            }

            /// Convenience overload taking a `String` name.
            @discardableResult
            public func append(
                to parent: Ref,
                name: String,
                allocatedSize: UInt64,
                logicalSize: UInt64,
                modified: Int64,
                flags: NodeFlags = [],
                itemCount: UInt32 = 1,
                link: FileTree.LinkID? = nil,
                isExecutable: Bool = false
            ) -> Ref {
                var name = name
                return name.withUTF8 {
                    append(
                        to: parent, name: $0, allocatedSize: allocatedSize, logicalSize: logicalSize,
                        modified: modified, flags: flags, itemCount: itemCount, link: link,
                        isExecutable: isExecutable)
                }
            }

            var currentCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }

            func addPatch(local: UInt32, flags: NodeFlags) {
                lock.lock()
                defer { lock.unlock() }
                precondition(Int(local) < count, "Ref does not belong to this builder")
                // Flags are kept beside the entries, not written into them, because a snapshot may
                // be reading the entry chunks without holding the lock.
                patches.append(FlagPatch(local: local, flags: flags.rawValue))
            }

            /// Must be called with `lock` held.
            func capture(seal: Bool) -> Capture {
                let capture = Capture(
                    entryChunks: entryChunks, nameChunks: nameChunks, chunkNameStart: chunkNameStart,
                    patches: patches, links: links, count: count, nameBytes: nameBytes)
                if seal {
                    sealed = true
                    entryChunks = []
                    nameChunks = []
                    chunkNameStart = []
                    patches = []
                    links = []
                }
                return capture
            }
        }
    }
}

// MARK: - Arena records

struct RawEntry {
    var parent: UInt64
    var allocated: UInt64
    var logical: UInt64
    var nameRef: UInt32  // name chunk index << 16 | offset in chunk
    var mtime: UInt32
    var itemCount: UInt32
    var nameLength: UInt16
    var flags: UInt16  // NodeFlags bits, plus `executableHint`

    /// Arena-only bit (not a ``NodeFlags`` member): the entry had an execute permission bit.
    static let executableHint: UInt16 = 1 << 15
    /// Bits that never reach the tree's flags column from the arena.
    static let arenaOnlyFlags: UInt16 = executableHint | NodeFlags.removed.rawValue
}

struct FlagPatch {
    var local: UInt32
    var flags: UInt16
}

/// Inode identity and real sizes of one link of a multiply-linked file (kept beside the entries).
struct LinkRecord {
    var local: UInt32
    var device: Int32
    var inode: UInt64
    var allocated: UInt64
    var logical: UInt64
}

/// A fixed-capacity, never-moving buffer of the builder's arenas.
///
/// Backed by its own anonymous mapping rather than `malloc`: chunks are large (320 KiB of
/// entries, 64 KiB of names) and short-lived, and `munmap` gives the pages back the moment the
/// last reference goes, whereas freed malloc blocks of this size linger in the allocator and
/// keep the process footprint at its peak for seconds. Chunks are freed only by dropping
/// references (never explicitly), so a snapshot that still holds one keeps it valid.
final class RawChunk<T: BitwiseCopyable>: @unchecked Sendable {
    let p: UnsafeMutablePointer<T>
    private let byteCount: Int

    init(capacity: Int) {
        let page = Int(getpagesize())
        byteCount = (max(capacity, 1) * MemoryLayout<T>.stride + page - 1) / page * page
        let mapping = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let mapping, mapping != MAP_FAILED else {
            fatalError("FileTree.Builder: cannot map \(byteCount) bytes: \(String(cString: strerror(errno)))")
        }
        p = mapping.bindMemory(to: T.self, capacity: capacity)
    }

    deinit { munmap(p, byteCount) }
}

/// What a snapshot takes from one worker: chunk references plus the extent that was valid.
struct Capture: @unchecked Sendable {
    var entryChunks: [RawChunk<RawEntry>]
    var nameChunks: [RawChunk<UInt8>]
    var chunkNameStart: [Int]
    var patches: [FlagPatch]
    var links: [LinkRecord]
    var count: Int
    var nameBytes: Int
}

/// Hands a set of captures to the assembler *by ownership*: `take()` moves them out, so the
/// assembler's references are the only ones the snapshot/finalize call holds, and dropping them
/// during assembly really frees the chunks (when no live worker still owns them).
final class CaptureSet: @unchecked Sendable {
    private var parts: [Capture]
    init(_ parts: [Capture]) { self.parts = parts }

    func take() -> [Capture] {
        var result: [Capture] = []
        swap(&result, &parts)
        return result
    }
}

// MARK: - Assembly

enum Assembler {
    /// Interns extensions within one fill task; the per-task tables are merged afterwards.
    private struct LocalKinds {
        var map: [ExtKey: UInt16] = [:]
        var keys: [ExtKey] = [ExtKey()]  // local id 0 = no extension
        var isPackage: [Bool] = [false]
        var lastKey = ExtKey()
        var lastID: UInt16 = 0

        @inline(__always)
        mutating func intern(_ key: ExtKey) -> UInt16 {
            if key == lastKey { return lastID }
            let id: UInt16
            if let found = map[key] {
                id = found
            } else if keys.count < Int(UInt16.max) {
                id = UInt16(keys.count)
                map[key] = id
                keys.append(key)
                isPackage.append(FileKinds.isPackageExtension(key.string))
            } else {
                id = 0
            }
            lastKey = key
            lastID = id
            return id
        }
    }

    private struct FillTask {
        var part: Int
        var chunk: Int
        var entries: Int
    }

    /// Builds the tree from captured arenas.
    ///
    /// Peak memory matters here (a whole-disk scan has millions of entries), so:
    /// - the captures are consumed: each entry chunk is released by the fill task that copied it
    ///   out and the name chunks right after phase 1 — in the `finalize()` path that unmaps them
    ///   before the remaining columns are even allocated (in the `snapshot()` path the live
    ///   workers still hold them, so nothing is freed and nothing changes);
    /// - the result columns are built directly in the arrays the tree will own (see ``Column``).
    static func assemble(rootPath: String, rootFlags: NodeFlags, rootModified: Int64, captures: CaptureSet) -> FileTree {
        let dirBit = NodeFlags.directory.rawValue
        let rootName = Array((rootPath == "/" ? "/" : String(rootPath.split(separator: "/").last ?? "/")).utf8)

        // Take everything the later phases need out of the captures; the chunk references end up
        // in `entrySlots` and `nameChunkLists` only, so that they can be dropped early.
        let counts: [Int]
        let chunkNameStarts: [[Int]]
        let patchLists: [[FlagPatch]]
        let linkLists: [[LinkRecord]]
        var nameChunkLists: [[RawChunk<UInt8>]]
        var entryChunkLists: [[RawChunk<RawEntry>]]

        // NodeIDs: root = 0, then each worker's entries in append order, worker after worker.
        var baseList: [Int] = []
        var nameBaseList: [Int] = []
        var nodeTotal = 1
        var nameTotal = rootName.count
        do {
            let parts = captures.take()
            counts = parts.map(\.count)
            chunkNameStarts = parts.map(\.chunkNameStart)
            patchLists = parts.map(\.patches)
            linkLists = parts.map(\.links)
            nameChunkLists = parts.map(\.nameChunks)
            entryChunkLists = parts.map(\.entryChunks)
            for part in parts {
                baseList.append(nodeTotal)
                nameBaseList.append(nameTotal)
                nodeTotal += part.count
                nameTotal += part.nameBytes
            }
        }
        // Immutable from here on, so the parallel blocks below may capture them.
        let (bases, nameBases, n, poolSize) = (baseList, nameBaseList, nodeTotal, nameTotal)
        precondition(n <= Int(UInt32.max), "FileTree supports at most 2^32 - 1 nodes")
        precondition(poolSize <= Int(UInt32.max), "FileTree name pool is limited to 4 GB")

        let nameOffset = Column<UInt32>(n), nameLength = Column<UInt16>(n)
        let parent = Column<NodeID>(n)
        let allocated = Column<UInt64>(n), logical = Column<UInt64>(n)
        let fileCount = Column<UInt32>(n), mtime = Column<UInt32>(n)
        let kind = Column<KindID>(n), flags = Column<UInt16>(n)
        let pool = Column<UInt8>(poolSize)

        memcpy(pool.p, rootName, rootName.count)
        nameOffset.p[0] = 0
        nameLength.p[0] = UInt16(rootName.count)
        parent.p[0] = 0
        allocated.p[0] = 0
        logical.p[0] = 0
        fileCount.p[0] = 0
        mtime.p[0] = UInt32(clamping: rootModified)
        kind.p[0] = 0
        flags.p[0] = rootFlags.union(.directory).rawValue

        // Phase 1 (parallel over entry chunks): copy attributes and names, intern extensions locally.
        var taskList: [FillTask] = []
        for (p, count) in counts.enumerated() {
            var remaining = count
            var chunk = 0
            while remaining > 0 {
                let entries = min(remaining, FileTree.Builder.Worker.entriesPerChunk)
                taskList.append(FillTask(part: p, chunk: chunk, entries: entries))
                remaining -= entries
                chunk += 1
            }
        }
        let tasks = taskList
        let localTables = UnsafeMutablePointer<LocalKinds>.allocate(capacity: max(tasks.count, 1))
        localTables.initialize(repeating: LocalKinds(), count: tasks.count)
        defer {
            localTables.deinitialize(count: tasks.count)
            localTables.deallocate()
        }
        let tables = Unchecked(localTables)

        do {
            // One slot per fill task holding that task's entry chunk (a task maps to exactly one
            // chunk). Each task clears its own slot when done; slots are disjoint, so that is
            // safe inside `concurrentPerform`.
            let entrySlots = UnsafeMutablePointer<RawChunk<RawEntry>?>.allocate(capacity: max(tasks.count, 1))
            for (t, task) in tasks.enumerated() {
                (entrySlots + t).initialize(to: entryChunkLists[task.part][task.chunk])
            }
            entryChunkLists = []
            defer {
                entrySlots.deinitialize(count: tasks.count)
                entrySlots.deallocate()
            }
            let slots = Unchecked(entrySlots)
            // Raw pointers into the name chunks; valid only inside the `withExtendedLifetime`
            // below. Name chunks are shared by all tasks of a part, so they go after the phase.
            let namePointers = Unchecked(nameChunkLists.map { $0.map { UnsafePointer($0.p) } })

            withExtendedLifetime(nameChunkLists) {
                DispatchQueue.concurrentPerform(iterations: tasks.count) { t in
                    let task = tasks[t]
                    guard let chunk = slots.value[t] else { return }
                    let names = namePointers.value[task.part]
                    var node = bases[task.part] + task.chunk * FileTree.Builder.Worker.entriesPerChunk
                    var poolOffset = nameBases[task.part] + chunkNameStarts[task.part][task.chunk]
                    var kinds = LocalKinds()
                    withExtendedLifetime(chunk) {
                        let entries = UnsafePointer(chunk.p)
                        for i in 0 ..< task.entries {
                            let e = entries[i]
                            let length = Int(e.nameLength)
                            let source = names[Int(e.nameRef >> 16)] + Int(e.nameRef & 0xFFFF)
                            memcpy(pool.p + poolOffset, source, length)
                            nameOffset.p[node] = UInt32(poolOffset)
                            nameLength.p[node] = e.nameLength
                            poolOffset += length

                            if e.parent == UInt64.max {
                                parent.p[node] = 0
                            } else {
                                let worker = Int(e.parent >> 32)
                                let local = Int(e.parent & 0xFFFF_FFFF)
                                precondition(
                                    worker < counts.count && local < counts[worker],
                                    "FileTree.Builder: parent Ref does not belong to this builder")
                                parent.p[node] = NodeID(bases[worker] + local)
                            }

                            var f = e.flags & ~RawEntry.arenaOnlyFlags
                            var k: UInt16 = 0
                            if let key = ExtKey(name: source, length: length) {
                                k = kinds.intern(key)
                            } else if e.flags & RawEntry.executableHint != 0,
                                f & (dirBit | NodeFlags.symlink.rawValue) == 0
                            {
                                // An extensionless executable: "Unix Executable" instead of kind 0.
                                k = kinds.intern(.unixExecutable)
                            }
                            if f & dirBit != 0 {
                                // Plain folders have no kind; packages keep theirs (".app", ".photoslibrary").
                                if kinds.isPackage[Int(k)] { f |= NodeFlags.package.rawValue } else { k = 0 }
                                allocated.p[node] = 0
                                logical.p[node] = 0
                                fileCount.p[node] = 0
                            } else if f & NodeFlags.hardLinkDuplicate.rawValue != 0 {
                                allocated.p[node] = 0
                                logical.p[node] = 0
                                fileCount.p[node] = e.itemCount
                            } else {
                                allocated.p[node] = e.allocated
                                logical.p[node] = e.logical
                                fileCount.p[node] = e.itemCount
                            }
                            kind.p[node] = k
                            flags.p[node] = f
                            mtime.p[node] = e.mtime
                            node += 1
                        }
                    }
                    tables.value[t] = kinds
                    // Done with this entry chunk: drop the assembly's reference (frees it unless
                    // a live worker or another snapshot still holds it).
                    slots.value[t] = nil
                }
            }
        }
        nameChunkLists = []

        // Late flag additions (e.g. "unreadable" discovered when opening a directory).
        for (p, patches) in patchLists.enumerated() {
            for patch in patches where Int(patch.local) < counts[p] {
                flags.p[bases[p] + Int(patch.local)] |= patch.flags & ~RawEntry.arenaOnlyFlags
            }
        }

        // Phase 2: merge the local kind tables into the tree's table and remap.
        var kindTable: [FileKind] = [FileKind(ext: "")]
        var globalIDs: [ExtKey: KindID] = [:]
        var remaps: [[KindID]] = []
        remaps.reserveCapacity(tasks.count)
        for t in 0 ..< tasks.count {
            var remap: [KindID] = [0]
            for key in localTables[t].keys.dropFirst() {
                if let id = globalIDs[key] {
                    remap.append(id)
                } else if kindTable.count < Int(KindID.max) {
                    let id = KindID(kindTable.count)
                    globalIDs[key] = id
                    kindTable.append(FileKind(ext: key.string))
                    remap.append(id)
                } else {
                    remap.append(0)
                }
            }
            remaps.append(remap)
        }
        let kindRemaps = remaps
        DispatchQueue.concurrentPerform(iterations: tasks.count) { t in
            let task = tasks[t]
            let remap = kindRemaps[t]
            let start = bases[task.part] + task.chunk * FileTree.Builder.Worker.entriesPerChunk
            for node in start ..< start + task.entries {
                kind.p[node] = remap[Int(kind.p[node])]
            }
        }

        // Phase 3: sibling lists (counting sort by parent).
        let childCount = Column<UInt32>(n, zeroed: true)
        let childStart = Column<UInt32>(n)
        let childIndex = Column<NodeID>(n - 1)
        for node in 1 ..< max(n, 1) { childCount.p[Int(parent.p[node])] &+= 1 }
        do {
            let cursor = Column<UInt32>(n)
            var running: UInt32 = 0
            for node in 0 ..< n {
                childStart.p[node] = running
                cursor.p[node] = running
                let c = childCount.p[node]
                running &+= c
                if c != 0 && flags.p[node] & dirBit == 0 {
                    // Tolerate a scanner that forgot `.directory` on something it then filled.
                    flags.p[node] |= dirBit
                    allocated.p[node] = 0
                    logical.p[node] = 0
                    fileCount.p[node] = 0
                }
            }
            for node in 1 ..< max(n, 1) {
                let p = Int(parent.p[node])
                childIndex.p[Int(cursor.p[p])] = NodeID(node)
                cursor.p[p] &+= 1
            }
        }

        // Phase 4: directory totals. `order` lists directories parents-first, so walking it
        // backwards sees every directory after all of its subdirectories.
        var order: [NodeID] = [0]
        var head = 0
        while head < order.count {
            let dir = Int(order[head])
            head += 1
            let start = Int(childStart.p[dir])
            for k in start ..< start + Int(childCount.p[dir]) {
                let child = childIndex.p[k]
                if flags.p[Int(child)] & dirBit != 0 { order.append(child) }
            }
        }
        for dir in order.reversed() {
            let d = Int(dir)
            let start = Int(childStart.p[d])
            var a: UInt64 = 0
            var l: UInt64 = 0
            var c: UInt64 = 0
            for k in start ..< start + Int(childCount.p[d]) {
                let child = Int(childIndex.p[k])
                a &+= allocated.p[child]
                l &+= logical.p[child]
                c &+= UInt64(fileCount.p[child])
            }
            allocated.p[d] = a
            logical.p[d] = l
            fileCount.p[d] = UInt32(clamping: c)
        }

        // Phase 5 (parallel over directories): sort each sibling list by size, largest first.
        let stride = 512
        let directories = order
        DispatchQueue.concurrentPerform(iterations: (directories.count + stride - 1) / stride) { block in
            let end = min(directories.count, (block + 1) * stride)
            for i in block * stride ..< end {
                let d = Int(directories[i])
                let c = Int(childCount.p[d])
                guard c > 1 else { continue }
                var siblings = UnsafeMutableBufferPointer(start: childIndex.p + Int(childStart.p[d]), count: c)
                siblings.sort { x, y in
                    let sx = allocated.p[Int(x)]
                    let sy = allocated.p[Int(y)]
                    return sx != sy ? sx > sy : x < y
                }
            }
        }

        // Hard-link identities (sparse): only non-directories keep one.
        var links: [NodeID: FileTree.LinkInfo] = [:]
        let linkTotal = linkLists.reduce(0) { $0 + $1.count }
        if linkTotal > 0 {
            links.reserveCapacity(linkTotal)
            for (p, records) in linkLists.enumerated() {
                for record in records where Int(record.local) < counts[p] {
                    let node = bases[p] + Int(record.local)
                    guard flags.p[node] & dirBit == 0 else { continue }
                    links[NodeID(node)] = FileTree.LinkInfo(
                        id: FileTree.LinkID(device: record.device, inode: record.inode),
                        allocated: record.allocated, logical: record.logical)
                }
            }
        }

        return FileTree(
            rootPath: rootPath, kinds: kindTable,
            nameOffset: nameOffset.take(), nameLength: nameLength.take(), parent: parent.take(),
            childStart: childStart.take(), childCount: childCount.take(),
            allocated: allocated.take(), logical: logical.take(), fileCount: fileCount.take(),
            mtime: mtime.take(), kind: kind.take(), flags: flags.take(),
            childIndex: childIndex.take(), namePool: pool.take(), links: links)
    }
}
