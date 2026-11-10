import Foundation
import Synchronization
import DiskSurveyCore
import os

// MARK: - Shared scan state

struct InodeKey: Hashable, Sendable {
    var device: Int32
    var inode: UInt64
}

/// The set of multiply-linked inodes already counted. Only files with a link count above one
/// ever get here (a tiny fraction of a normal disk), so a sharded lock is plenty.
final class HardLinkTable: Sendable {
    private static let shardCount = 64
    private let shards: [OSAllocatedUnfairLock<Set<InodeKey>>]

    init() { shards = (0 ..< HardLinkTable.shardCount).map { _ in OSAllocatedUnfairLock(initialState: []) } }

    /// True the first time a (device, inode) pair is seen.
    func insert(_ key: InodeKey) -> Bool {
        // Inode numbers are sequential; fold the device in and spread the low bits.
        let hash = (key.inode &* 0x9E37_79B9_7F4A_7C15) ^ UInt64(UInt32(bitPattern: key.device))
        let shard = Int(truncatingIfNeeded: hash >> 58) & (HardLinkTable.shardCount - 1)
        return shards[shard].withLock { $0.insert(key).inserted }
    }
}

/// Everything the worker threads of one scan share.
final class ScanContext: @unchecked Sendable {
    let builder: FileTree.Builder
    let pool: WorkPool
    let options: ScanOptions
    let policy: MountPolicy
    let hardLinks = HardLinkTable()
    let threadCount: Int
    /// Excluded absolute paths as raw bytes (compared without building strings).
    let excluded: [[UInt8]]
    /// Devices whose directory entry counts are believed (used only to skip redundant system
    /// calls): APFS volumes, where the count is stored in the inode and where the shortcut was
    /// verified against full scans. Everything else takes the unoptimized path.
    let countTrustedDevices: Set<Int32>
    /// Every mount point path, as bytes (for the readdir fallback, which gets no mount flag).
    let mountPoints: [[UInt8]]
    /// Interrupts directory opens the system has stopped answering; nil when switched off.
    let watchdog: OpenWatchdog?
    /// Tests only: stands in for `open` when it returns a value (a descriptor, or -1 with
    /// `errno` set); nil means "open normally".
    let openHook: OpenHook?

    private let effectiveUser = geteuid()

    /// Whether owner and mode alone leave no doubt that this process can list the directory.
    /// "No" only means "open it and see". Deliberately one-sided: for a directory of another
    /// owner both the group and the other bits must allow it, so that group membership does
    /// not have to be worked out.
    @inline(__always)
    func canSurelyRead(owner: UInt32, mode: UInt32) -> Bool {
        if effectiveUser == 0 { return true }
        let needed: UInt32 = owner == effectiveUser ? 0o500 : 0o055
        return mode & needed == needed
    }

    let cancelled = Atomic<Bool>(false)
    let files = Atomic<UInt64>(0)
    let directories = Atomic<UInt64>(0)
    let bytesAllocated = Atomic<UInt64>(0)
    let bytesLogical = Atomic<UInt64>(0)
    let errors = Atomic<UInt64>(0)
    /// The directory some worker was reading most recently (bytes, for the progress display).
    let currentPath = OSAllocatedUnfairLock<ContiguousArray<UInt8>>(initialState: [])

    init(
        builder: FileTree.Builder, options: ScanOptions, policy: MountPolicy, threadCount: Int,
        watchdog: OpenWatchdog? = nil, openHook: OpenHook? = nil
    ) {
        self.watchdog = watchdog
        self.openHook = openHook
        self.builder = builder
        self.options = options
        self.policy = policy
        self.threadCount = threadCount
        pool = WorkPool(workerCount: threadCount)
        mountPoints = policy.table.byMountPoint.keys.map { Array($0.utf8) }
        countTrustedDevices =
            options.useEntryCountHints
            ? Set(policy.table.byMountPoint.values.filter { $0.fileSystemType == "apfs" }.map(\.deviceID)) : []
        // Workers compare exclusions byte for byte with "resolved root + names", so every
        // spelling an exclusion can take in this scan is worked out once, here (a caller's
        // `/tmp/x` has to match the scan's `/private/tmp/x`).
        var spellings: [String] = []
        for raw in options.excludedPaths {
            let variants = PathSpelling.variants(
                of: raw, rootPath: builder.rootPath, resolvingItem: options.excludedPathsFollowSymlinks)
            for path in variants where !spellings.contains(path) {
                spellings.append(path)
            }
        }
        excluded = spellings.map { Array($0.utf8) }
    }
}

/// See ``ScanContext/openHook``.
typealias OpenHook = @Sendable (_ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32?

/// What one worker hands back when it exits.
struct WorkerReport: Sendable {
    var stats = ScanStats()
    var issues: [ScanIssue] = []
}

// MARK: - Attribute constants

// Spelled out as UInt32 here because the SDK macros import with mixed signedness.
private let attrCmnName: UInt32 = 0x0000_0001
private let attrCmnDevID: UInt32 = 0x0000_0002
private let attrCmnObjType: UInt32 = 0x0000_0008
private let attrCmnModTime: UInt32 = 0x0000_0400
private let attrCmnFlags: UInt32 = 0x0004_0000
private let attrCmnOwnerID: UInt32 = 0x0000_8000
private let attrCmnGroupID: UInt32 = 0x0001_0000
private let attrCmnAccessMask: UInt32 = 0x0002_0000
private let attrCmnFileID: UInt32 = 0x0200_0000
private let attrCmnError: UInt32 = 0x2000_0000
private let attrCmnReturnedAttrs: UInt32 = 0x8000_0000
private let attrDirEntryCount: UInt32 = 0x0000_0002
private let attrDirMountStatus: UInt32 = 0x0000_0004
private let attrFileLinkCount: UInt32 = 0x0000_0001
private let attrFileAllocSize: UInt32 = 0x0000_0004
private let attrFileDataLength: UInt32 = 0x0000_0200

private let vnodeRegular: UInt32 = 1  // VREG
private let vnodeDirectory: UInt32 = 2  // VDIR
private let vnodeSymlink: UInt32 = 5  // VLNK
private let flagDataless: UInt32 = 0x4000_0000  // SF_DATALESS
private let flagFirmlink: UInt32 = 0x0080_0000  // SF_FIRMLINK
/// DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER: something is, or would be, mounted here.
private let mountStatusMask: UInt32 = 0x3

// MARK: - Worker

/// One scanning thread: reads directories with `getattrlistbulk`, appends entries to its own
/// builder arena and schedules subdirectories.
///
/// The per-entry path is allocation-free: names stay as bytes inside the kernel's reply buffer
/// until the builder copies them; a path is built (one `malloc`) only for subdirectories, and a
/// `String` only for the rare events — mount points, errors.
final class ScanWorker {
    /// 256 KiB holds roughly 2,000–3,000 entries per system call. Larger buffers did not measure
    /// faster (the cost is per entry in the kernel), smaller ones cost extra calls on big
    /// directories.
    static let bufferSize = 256 * 1024
    /// Progress counters are flushed to the shared atomics in batches so that twelve threads do
    /// not bounce one cache line on every directory.
    static let flushThreshold: UInt64 = 512

    private let context: ScanContext
    private let arena: FileTree.Builder.Worker
    private let buffer: UnsafeMutableRawPointer
    private var attributes = attrlist()
    private var entryCountProbe = attrlist()
    /// One-element cache of "is this device in `context.countTrustedDevices`".
    private var lastDevice: Int32 = -1
    private var lastDeviceTrusted = false
    private var local: [DirWork] = []
    private var report = WorkerReport()
    /// This thread's entry with the open watchdog, while `run()` is executing.
    private var watchdogSlot: OpenWatchdog.Slot?

    /// Longest single directory open so far, in nanoseconds, and (only when it counts as
    /// slow) which directory that was.
    private var slowestOpen: UInt64 = 0
    private var slowestOpenPath = ""
    static let slowOpenThreshold: UInt64 = 100_000_000

    private var pendingFiles: UInt64 = 0
    private var pendingDirectories: UInt64 = 0
    private var pendingAllocated: UInt64 = 0
    private var pendingLogical: UInt64 = 0

    init(context: ScanContext) {
        self.context = context
        arena = context.builder.makeWorker()
        buffer = .allocate(byteCount: ScanWorker.bufferSize, alignment: 16)
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr =
            attrCmnReturnedAttrs | attrCmnName | attrCmnDevID | attrCmnObjType | attrCmnModTime | attrCmnAccessMask
            | attrCmnFlags | attrCmnFileID | attrCmnError
        attributes.dirattr = attrDirEntryCount | attrDirMountStatus
        entryCountProbe.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        entryCountProbe.commonattr = attrCmnReturnedAttrs | ScanWorker.probeOwnership
        entryCountProbe.dirattr = attrDirEntryCount
        attributes.fileattr = attrFileLinkCount | attrFileAllocSize | attrFileDataLength
        local.reserveCapacity(256)
    }

    deinit { buffer.deallocate() }

    /// Per-thread I/O policy: listing a disk must not change it.
    static func configureThread() {
        // Never ask a File Provider (iCloud Drive, Dropbox, …) to download anything: with this
        // policy, touching a dataless object fails instead of materializing it.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        // And do not dirty directory access times.
        setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_THREAD, IOPOL_ATIME_UPDATES_OFF)
    }

    func run() -> WorkerReport {
        let pool = context.pool
        watchdogSlot = context.watchdog?.register()
        defer {
            if let watchdogSlot {
                report.stats.interruptedDirectoryOpens = watchdogSlot.interruptions
                context.watchdog?.unregister(watchdogSlot)
            }
            watchdogSlot = nil
        }
        while true {
            if local.isEmpty {
                flushProgress(publishing: nil)
                guard pool.take(into: &local) else { break }
            }
            let work = local.removeLast()
            // After a cancel the remaining work is only drained, so every path is freed and the
            // termination protocol still runs to completion.
            if !context.cancelled.load(ordering: .relaxed) { scan(work) }
            work.free()

            // Share surplus work while someone is idle or the pool is running low.
            if local.count >= 2,
                pool.hungry.load(ordering: .relaxed) > 0 || pool.available.load(ordering: .relaxed) < context.threadCount
            {
                pool.donate(from: &local, count: local.count / 2)
            }
        }
        flushProgress(publishing: nil)
        report.stats.slowestDirectoryOpen = Double(slowestOpen) / 1e9
        report.stats.slowestDirectoryPath = slowestOpenPath
        if let watchdogSlot { report.stats.interruptedDirectoryOpens = watchdogSlot.interruptions }
        return report
    }

    // MARK: Progress and issues

    private func flushProgress(publishing work: DirWork?) {
        if pendingFiles != 0 { context.files.add(pendingFiles, ordering: .relaxed) }
        if pendingDirectories != 0 { context.directories.add(pendingDirectories, ordering: .relaxed) }
        if pendingAllocated != 0 { context.bytesAllocated.add(pendingAllocated, ordering: .relaxed) }
        if pendingLogical != 0 { context.bytesLogical.add(pendingLogical, ordering: .relaxed) }
        pendingFiles = 0
        pendingDirectories = 0
        pendingAllocated = 0
        pendingLogical = 0
        if let work {
            let bytes = UnsafeBufferPointer(start: UnsafePointer(work.path), count: work.length)
            // Best effort: if another thread holds the slot, its path is just as current.
            _ = context.currentPath.withLockIfAvailableUnchecked { slot in
                slot.removeAll(keepingCapacity: true)
                slot.append(contentsOf: bytes)
            }
        }
    }

    private func recordIssue(path: String, errno code: Int32) {
        context.errors.add(1, ordering: .relaxed)
        // Each worker keeps at most the global limit; the merge trims again.
        if report.issues.count < ScanResult.issueLimit { report.issues.append(ScanIssue(path: path, errno: code)) }
    }

    // MARK: Opening directories

    private static let openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Opens a directory by absolute path. Paths beyond PATH_MAX are opened piecewise with
    /// `openat`, so depth is not limited.
    ///
    /// `EINTR` is retried. That is not a formality here: it is how a stalled `open` ends,
    /// whether the kernel gives up on it after five seconds or the watchdog interrupts it
    /// sooner (see `OpenWatchdog`), and the retry is what gets the directory.
    private func openDirectory(_ work: DirWork, startingAt start: UInt64) -> Int32 {
        let path = UnsafeRawPointer(work.path).assumingMemoryBound(to: CChar.self)
        let slot = watchdogSlot
        slot?.beginOpen(at: start)
        var fd: Int32
        var failure: Int32 = 0
        while true {
            fd = context.openHook?(path, ScanWorker.openFlags) ?? open(path, ScanWorker.openFlags)
            if fd >= 0 { break }
            failure = errno
            if failure != EINTR { break }
            slot?.retryOpen()
        }
        // From here on the watchdog leaves this thread alone.
        slot?.endOpen()
        if fd < 0, failure == ENAMETOOLONG { return openLongPath(work) }
        errno = failure
        return fd
    }

    /// Walks an over-long absolute path in chunks that each fit PATH_MAX.
    ///
    /// O_NOFOLLOW applies to the last component of every chunk; that is safe because the scan
    /// root was resolved with `realpath` and everything below it was reported as a directory.
    private func openLongPath(_ work: DirWork) -> Int32 {
        let chunkLimit = 1000
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        var position = 1  // skip the leading slash
        let segment = UnsafeMutablePointer<CChar>.allocate(capacity: chunkLimit + 1)
        defer { segment.deallocate() }
        while position < work.length {
            var end = min(work.length, position + chunkLimit)
            if end < work.length {
                // Back up to a component boundary. A single component is at most 255 bytes, so
                // a boundary always exists inside the chunk.
                while end > position, work.path[end] != 0x2F { end -= 1 }
                guard end > position else {
                    close(fd)
                    errno = ENAMETOOLONG
                    return -1
                }
            }
            memcpy(segment, work.path + position, end - position)
            segment[end - position] = 0
            var next: Int32
            repeat { next = openat(fd, segment, ScanWorker.openFlags) } while next < 0 && errno == EINTR
            let failure = errno
            close(fd)
            guard next >= 0 else {
                errno = failure
                return -1
            }
            fd = next
            position = end + 1
        }
        return fd
    }

    // MARK: Reading one directory

    private func scan(_ work: DirWork) {
        // Two clock reads per directory (tens of nanoseconds) attribute a slow scan: a single
        // `open` that blocks for seconds leaves every other worker idle (see `ScanStats`).
        let openStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let fd = openDirectory(work, startingAt: openStart)
        let openFailure = errno
        let openDuration = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- openStart
        if openDuration > slowestOpen {
            slowestOpen = openDuration
            if openDuration >= ScanWorker.slowOpenThreshold { slowestOpenPath = work.string }
        }
        if openDuration >= ScanWorker.slowOpenThreshold { report.stats.slowDirectoryOpens += 1 }
        errno = openFailure
        guard fd >= 0 else {
            let code = errno
            // A directory that vanished between being listed and being opened is normal on a
            // live system; it simply stays in the tree as an empty directory.
            if code == ENOENT { return }
            context.builder.addFlags(.unreadable, to: work.ref)
            recordIssue(path: work.string, errno: code)
            return
        }
        defer { close(fd) }

        if !context.options.useBulkAttributes {
            scanWithReaddir(fd: fd, work)
        } else {
            scanWithBulkAttributes(fd: fd, work)
        }
        if pendingFiles + pendingDirectories >= ScanWorker.flushThreshold { flushProgress(publishing: work) }
    }

    private func scanWithBulkAttributes(fd: Int32, _ work: DirWork) {
        var firstCall = true
        var total = 0
        while true {
            if context.cancelled.load(ordering: .relaxed) { return }
            let count = Int(getattrlistbulk(fd, &attributes, buffer, ScanWorker.bufferSize, 0))
            if count == 0 { return }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                // Filesystems without bulk attribute support (some network and FUSE volumes)
                // refuse the very first call; anything later is a real error.
                if firstCall, code == ENOTSUP || code == EINVAL || code == ENOSYS {
                    scanWithReaddir(fd: fd, work)
                    return
                }
                if code == EACCES || code == EPERM { context.builder.addFlags(.unreadable, to: work.ref) }
                recordIssue(path: work.string, errno: code)
                return
            }
            firstCall = false

            // Reply layout (see getattrlistbulk(2)): per entry a 4-byte total length, the
            // returned-attributes bitmap, then the attributes that bitmap announces — error
            // first, then common, directory and file attributes in bit order. Fixed-size
            // attributes are 4-byte aligned; the name is an (offset, length) reference to bytes
            // stored after the fixed part, the offset counting from the reference itself.
            var entry = UnsafeRawPointer(buffer)
            for _ in 0 ..< count {
                let entryLength = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                let common = field.loadUnaligned(as: UInt32.self)
                let directory = field.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
                let file = field.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                field += 20  // attribute_set_t: five 32-bit groups

                var entryError: UInt32 = 0
                if common & attrCmnError != 0 {
                    entryError = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var name: UnsafePointer<UInt8>?
                var nameLength = 0
                if common & attrCmnName != 0 {
                    let offset = Int(field.loadUnaligned(as: Int32.self))
                    let length = Int(field.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                    name = (field + offset).assumingMemoryBound(to: UInt8.self)
                    nameLength = max(0, length - 1)  // the length includes the terminating NUL
                    field += 8
                }
                var device: Int32 = 0
                if common & attrCmnDevID != 0 {
                    device = field.loadUnaligned(as: Int32.self)
                    field += 4
                }
                var type: UInt32 = 0
                if common & attrCmnObjType != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var modified: Int64 = 0
                if common & attrCmnModTime != 0 {
                    modified = field.loadUnaligned(as: Int64.self)  // timespec.tv_sec
                    field += 16
                }
                // The permission bits, only to tell extensionless executables from other files.
                // (Bit order: the access mask, 0x20000, comes before the BSD flags, 0x40000.)
                var mode: UInt32 = 0
                if common & attrCmnAccessMask != 0 {
                    mode = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var bsdFlags: UInt32 = 0
                if common & attrCmnFlags != 0 {
                    bsdFlags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var inode: UInt64 = 0
                if common & attrCmnFileID != 0 {
                    inode = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                var entryCount = -1
                if directory & attrDirEntryCount != 0 {
                    entryCount = Int(field.loadUnaligned(as: UInt32.self))
                    field += 4
                }
                var mountStatus: UInt32 = 0
                if directory & attrDirMountStatus != 0 {
                    mountStatus = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var linkCount: UInt32 = 1
                if file & attrFileLinkCount != 0 {
                    linkCount = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var allocated: Int64 = 0
                if file & attrFileAllocSize != 0 {
                    allocated = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                var logical: Int64 = 0
                if file & attrFileDataLength != 0 {
                    logical = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                entry += entryLength

                guard let name, nameLength > 0 else { continue }
                if entryError != 0 {
                    // The kernel could not get this entry's attributes; without a reliable type
                    // or size it cannot be placed in the tree.
                    let child = DirWork.joining(work.path, work.length, name, nameLength, ref: work.ref)
                    recordIssue(path: child.string, errno: Int32(bitPattern: entryError))
                    child.free()
                    continue
                }
                consume(
                    parent: work, name: name, nameLength: nameLength, isDirectory: type == vnodeDirectory,
                    isSymlink: type == vnodeSymlink, isRegular: type == vnodeRegular, device: device, inode: inode,
                    mode: mode, bsdFlags: bsdFlags, isMount: mountStatus & mountStatusMask != 0, linkCount: linkCount,
                    allocated: UInt64(max(0, allocated)), logical: UInt64(max(0, logical)), modified: modified,
                    entryCount: entryCount)
            }

            // Normally only a call that returns 0 proves the directory is exhausted — a second
            // system call for every directory, and most directories fit in one reply. It can be
            // skipped when two independent signs agree that this reply was the last: we now hold
            // exactly as many entries as the parent's listing announced, and the reply left most
            // of the buffer unused (the kernel stopped for lack of entries, not of space).
            total += count
            if total == work.expectedEntries, entry - UnsafeRawPointer(buffer) < ScanWorker.bufferSize / 2 { return }
        }
    }

    private static let probeOwnership = attrCmnOwnerID | attrCmnGroupID | attrCmnAccessMask

    /// Asks the filesystem, by path, how many entries a directory has. Returns nil when it
    /// does not say — or when it is not plain from the directory's owner and mode that this
    /// process may open it: an empty directory that cannot be read must still be opened, so
    /// that it fails, is flagged ``NodeFlags/unreadable`` and is reported exactly as it is
    /// without the shortcut.
    ///
    /// Owner and mode come with the same call at no measurable cost (1.3 → 1.6 µs per probe).
    /// Asking the kernel for the verdict instead (`ATTR_CMN_USERACCESS`, or `faccessat`) is
    /// exact but took 11–19 µs, which is most of what the shortcut saves.
    private func entryCount(atPath path: UnsafePointer<UInt8>) -> Int? {
        // Reply: u32 length, attribute_set_t (20 bytes), then the common attributes in bit
        // order — u32 owner, u32 group, u32 mode — then the directory's u32 entry count.
        var reply = (
            UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0),
            UInt32(0)
        )
        let status = getattrlist(
            UnsafeRawPointer(path).assumingMemoryBound(to: CChar.self), &entryCountProbe, &reply,
            MemoryLayout.size(ofValue: reply), UInt32(FSOPT_NOFOLLOW))
        // reply.1 is the returned commonattr group, reply.3 the returned dirattr group. All
        // four attributes must be there, or the fixed offsets below do not hold.
        guard status == 0, reply.1 & ScanWorker.probeOwnership == ScanWorker.probeOwnership,
            reply.3 & attrDirEntryCount != 0
        else { return nil }
        guard context.canSurelyRead(owner: reply.6, mode: reply.8) else { return nil }
        return Int(reply.9)
    }

    /// Portable enumeration for filesystems without `getattrlistbulk`: one `fstatat` per entry.
    private func scanWithReaddir(fd: Int32, _ work: DirWork) {
        report.stats.fallbackDirectories += 1
        var own = stat()
        guard fstat(fd, &own) == 0 else {
            recordIssue(path: work.string, errno: errno)
            return
        }
        // fdopendir takes ownership of its descriptor; the caller closes `fd`, so hand over a copy.
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0, let stream = fdopendir(copy) else {
            let code = errno
            if copy >= 0 { close(copy) }
            recordIssue(path: work.string, errno: code)
            return
        }
        defer { closedir(stream) }
        // Firmlinks (only looked for when they are to be skipped): `fstatat` resolves a firmlink
        // and describes its target, so neither the flag nor the device gives it away. What does
        // is the volume the path resolves to; that costs one `statfs` per subdirectory.
        let detectFirmlinks = context.policy.skipsFirmlinks
        var ownVolume = statfs()
        var ownVolumeKnown: Bool?

        while true {
            if context.cancelled.load(ordering: .relaxed) { return }
            errno = 0
            guard let entry = readdir(stream) else {
                let code = errno
                if code != 0 { recordIssue(path: work.string, errno: code) }
                return
            }
            let nameLength = Int(entry.pointee.d_namlen)
            // d_name is a fixed char array at a known offset inside the dirent.
            let namePointer = UnsafeRawPointer(entry).advanced(by: MemoryLayout<dirent>.offset(of: \.d_name)!)
            let name = namePointer.assumingMemoryBound(to: UInt8.self)
            if nameLength == 0 || (name[0] == 0x2E && (nameLength == 1 || (nameLength == 2 && name[1] == 0x2E))) {
                continue
            }
            var info = stat()
            if fstatat(fd, namePointer.assumingMemoryBound(to: CChar.self), &info, AT_SYMLINK_NOFOLLOW) != 0 {
                let code = errno
                if code == ENOENT { continue }  // removed while we were listing
                let child = DirWork.joining(work.path, work.length, name, nameLength, ref: work.ref)
                recordIssue(path: child.string, errno: code)
                child.free()
                // Protected items (data vaults) refuse even lstat. The directory entry still
                // says what kind of thing it is, so keep it visible like the bulk path does.
                let type = Int32(entry.pointee.d_type)
                if type != DT_UNKNOWN {
                    let isDirectory = type == DT_DIR
                    arena.append(
                        to: work.ref, name: UnsafeBufferPointer(start: name, count: nameLength), allocatedSize: 0,
                        logicalSize: 0, modified: 0, flags: isDirectory ? [.directory, .unreadable] : [])
                    if isDirectory {
                        report.stats.directories += 1
                        pendingDirectories += 1
                    } else {
                        report.stats.files += 1
                        pendingFiles += 1
                    }
                }
                continue
            }
            let format = info.st_mode & S_IFMT
            // lstat describes the *mounted* root, so a mount point normally shows another
            // device. Not always: the startup volume group reports one device for the system
            // and Data volumes, so the mount table is consulted as well.
            let isMount =
                format == S_IFDIR
                && (info.st_dev != own.st_dev || isKnownMountPoint(parent: work, name: name, nameLength: nameLength))
            var bsdFlags = info.st_flags
            if detectFirmlinks, format == S_IFDIR, !isMount {
                if ownVolumeKnown == nil { ownVolumeKnown = fstatfs(fd, &ownVolume) == 0 }
                if ownVolumeKnown == true {
                    let child = DirWork.joining(work.path, work.length, name, nameLength, ref: work.ref)
                    var childVolume = statfs()
                    // A failure means "not known to be a firmlink"; opening it reports any error.
                    if statfs(UnsafeRawPointer(child.path).assumingMemoryBound(to: CChar.self), &childVolume) == 0,
                        !ScanWorker.sameMountPoint(&ownVolume, &childVolume)
                    {
                        bsdFlags |= flagFirmlink
                    }
                    child.free()
                }
            }
            consume(
                parent: work, name: name, nameLength: nameLength, isDirectory: format == S_IFDIR,
                isSymlink: format == S_IFLNK, isRegular: format == S_IFREG, device: info.st_dev, inode: info.st_ino,
                mode: UInt32(info.st_mode), bsdFlags: bsdFlags, isMount: isMount,
                linkCount: UInt32(info.st_nlink), allocated: UInt64(max(0, info.st_blocks)) * 512,
                logical: UInt64(max(0, info.st_size)), modified: Int64(info.st_mtimespec.tv_sec), entryCount: -1)
        }
    }

    /// Whether two filesystems are mounted at the same place. (Not `f_fsid`: the system and
    /// Data volumes of the startup volume group report the same device.)
    private static func sameMountPoint(_ a: inout statfs, _ b: inout statfs) -> Bool {
        withUnsafeBytes(of: &a.f_mntonname) { first in
            withUnsafeBytes(of: &b.f_mntonname) { second in
                strncmp(
                    first.baseAddress!.assumingMemoryBound(to: CChar.self),
                    second.baseAddress!.assumingMemoryBound(to: CChar.self), first.count) == 0
            }
        }
    }

    // MARK: One entry

    @inline(__always)
    private func consume(
        parent: DirWork, name: UnsafePointer<UInt8>, nameLength: Int, isDirectory: Bool, isSymlink: Bool,
        isRegular: Bool, device: Int32, inode: UInt64, mode: UInt32, bsdFlags: UInt32, isMount: Bool,
        linkCount: UInt32, allocated: UInt64,
        logical: UInt64, modified: Int64, entryCount: Int
    ) {
        if !context.excluded.isEmpty, isExcluded(parent: parent, name: name, nameLength: nameLength) {
            report.stats.excludedEntries += 1
            return
        }
        let nameBuffer = UnsafeBufferPointer(start: name, count: nameLength)

        if isDirectory {
            var flags: NodeFlags = .directory
            var enter = true
            if bsdFlags & flagDataless != 0 {
                // A dataless directory has no local listing; reading it would ask the provider
                // to fetch one (and fails under our I/O policy). Keep it as an empty node.
                flags.insert(.dataless)
                report.stats.datalessEntries += 1
                enter = false
            }
            var child: DirWork?
            if isMount {
                flags.insert(.mountPoint)
                let candidate = DirWork.joining(parent.path, parent.length, name, nameLength, ref: .root)
                if enter, context.policy.shouldEnter(mountPoint: candidate.string) {
                    report.stats.mountPointsEntered += 1
                    child = candidate
                } else {
                    report.stats.mountPointsSkipped += 1
                    candidate.free()
                    enter = false
                }
            } else if bsdFlags & flagFirmlink != 0, context.policy.skipsFirmlinks {
                flags.insert(.mountPoint)
                report.stats.mountPointsSkipped += 1
                enter = false
            }
            let ref = arena.append(
                to: parent.ref, name: nameBuffer, allocatedSize: 0, logicalSize: 0, modified: modified, flags: flags)
            report.stats.directories += 1
            pendingDirectories += 1
            guard enter else { return }
            if var child {
                // The root of a mounted volume: the listing described the directory underneath.
                child.ref = ref
                local.append(child)
                return
            }
            var work = DirWork.joining(parent.path, parent.length, name, nameLength, ref: ref)
            // The entry count announced by the parent's listing lets us skip work (see
            // `countTrustedDevices` for when it is believed at all). It describes the directory
            // *as stored in the parent's volume*, though: for a firmlink or a grafted volume
            // (system assets) that is an empty stand-in for a directory that lives elsewhere and
            // is found only by path. So a positive count is used merely as a hint that is
            // cross-checked while reading, and "empty" is confirmed by path before the directory
            // is skipped — still several times cheaper than open + read + close, which matters
            // because empty directories are surprisingly common (60% of /System/Library). The
            // same call returns owner and mode; a directory that may not be readable takes the
            // normal route and, if it is not, ends up flagged unreadable as without the shortcut.
            if entryCount >= 0, bsdFlags & flagFirmlink == 0, isCountTrusted(device) {
                if entryCount > 0 {
                    work.expectedEntries = entryCount
                } else if self.entryCount(atPath: work.path) == 0 {
                    work.free()
                    return
                }
            }
            local.append(work)
            return
        }

        var flags: NodeFlags = []
        if isSymlink {
            flags.insert(.symlink)
            report.stats.symlinks += 1
        }
        if bsdFlags & flagDataless != 0 {
            flags.insert(.dataless)
            report.stats.datalessEntries += 1
        }
        // Several names for one inode: the first one a thread reaches carries the size, the
        // others are zero-sized duplicates. Which name wins is a race between threads and may
        // differ between runs; the totals do not.
        if linkCount > 1, !context.hardLinks.insert(InodeKey(device: device, inode: inode)) {
            flags.insert(.hardLinkDuplicate)
            report.stats.hardLinkDuplicates += 1
        } else {
            pendingAllocated += allocated
            pendingLogical += logical
        }
        // Every name of a multiply-linked file carries the inode's identity and its real sizes —
        // the counted one and the duplicates alike — so that the tree can hand the size to a
        // surviving link when the counted one is removed or rescanned away.
        let link = linkCount > 1 ? FileTree.LinkID(device: device, inode: inode) : nil
        arena.append(
            to: parent.ref, name: nameBuffer, allocatedSize: allocated, logicalSize: logical, modified: modified,
            flags: flags, link: link, isExecutable: isRegular && mode & 0o111 != 0)
        report.stats.files += 1
        pendingFiles += 1
    }

    @inline(__always)
    private func isCountTrusted(_ device: Int32) -> Bool {
        if device != lastDevice {
            lastDevice = device
            lastDeviceTrusted = context.countTrustedDevices.contains(device)
        }
        return lastDeviceTrusted
    }

    private func isExcluded(parent: DirWork, name: UnsafePointer<UInt8>, nameLength: Int) -> Bool {
        ScanWorker.contains(context.excluded, parent: parent, name: name, nameLength: nameLength)
    }

    private func isKnownMountPoint(parent: DirWork, name: UnsafePointer<UInt8>, nameLength: Int) -> Bool {
        ScanWorker.contains(context.mountPoints, parent: parent, name: name, nameLength: nameLength)
    }

    /// Whether `parent/name` is one of `paths`, compared as bytes without building the path.
    private static func contains(
        _ paths: [[UInt8]], parent: DirWork, name: UnsafePointer<UInt8>, nameLength: Int
    ) -> Bool {
        let prefix = parent.length == 1 ? 0 : parent.length
        let total = prefix + 1 + nameLength
        for path in paths where path.count == total {
            let same = path.withUnsafeBufferPointer { bytes -> Bool in
                let base = bytes.baseAddress!
                return memcmp(base, parent.path, prefix) == 0 && base[prefix] == 0x2F
                    && memcmp(base + prefix + 1, name, nameLength) == 0
            }
            if same { return true }
        }
        return false
    }
}
