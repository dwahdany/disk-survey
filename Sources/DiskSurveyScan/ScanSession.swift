import Foundation
import Synchronization
import DiskSurveyCore
import os

/// One scan of one root, from `start()` to a ``ScanResult``.
///
/// ```swift
/// let session = ScanSession(root: URL(filePath: "/Users/me"))
/// session.start()
/// // poll `session.progress` and `session.snapshot()` from a timer / background task …
/// let result = await session.result()
/// ```
///
/// ## How it works
/// `start()` returns immediately. A coordinator thread resolves the root and starts N worker
/// threads (real threads — the scan is blocking I/O and must stay off Swift's cooperative pool).
/// Each worker reads directories with `getattrlistbulk(2)`, which returns names and all needed
/// attributes for thousands of entries per system call, appends them to its private arena of the
/// shared ``FileTree/Builder`` and schedules subdirectories on a private depth-first stack,
/// sharing surplus with idle workers through a small pool (see `WorkPool`).
///
/// ## Accounting
/// - Size is the *allocated* (physical) size of all forks, so sparse and transparently
///   compressed files count what they occupy; the logical length is kept alongside.
/// - An inode with several hard links is counted once; later links are flagged
///   ``NodeFlags/hardLinkDuplicate`` with size 0. APFS clones cannot be detected cheaply and are
///   counted in full for each copy (as `du` and Finder do).
/// - Symlinks are recorded, never followed — except the root itself, which is resolved.
/// - Dataless (cloud-only) files and folders are flagged ``NodeFlags/dataless`` and never
///   materialized: the worker threads run with dataless materialization switched off.
/// - Mount points: see ``ScanOptions``.
/// - Unreadable directories stay in the tree flagged ``NodeFlags/unreadable`` and are listed in
///   ``ScanResult/issues``. No error aborts a scan.
///
/// ## Where the time goes
/// All of it is in the kernel: a profile shows the workers inside `open` and `getattrlistbulk`
/// and 1–2% of the CPU time in this module, so the append lock, the work pool and the way
/// directories are opened are not worth tuning (`openat` relative to the parent measured no
/// faster than opening by absolute path). The cost is mostly per *directory* rather than per
/// entry — about 10 µs to open one and 5 µs per bulk call on a single thread of an idle machine
/// — so the scanner saves system calls where it safely can: empty directories are recognized
/// from the parent's listing and confirmed with one cheap call instead of open + read + close,
/// and the final "no more entries" call is skipped when the announced entry count has been
/// reached (see `ScanWorker`).
///
/// Threads help less than linearly: the kernel's cost per call grows with the number of threads
/// making them (roughly threefold at 12 threads), which is contention inside the kernel, not in
/// this module. Workers can also be seen idle in `WorkPool.take` while a few of them sit in an
/// `open` that takes long; that is not lock contention either — the directories behind those
/// calls are all the work that is left. ``ScanStats/slowestDirectoryOpen`` records when that
/// happened, so a slow scan can be told from a slow scanner.
///
/// The one case of this that used to cost seconds is handled: macOS sometimes leaves a thread
/// waiting five seconds, in `open`, for a privacy decision about another app's container that
/// has already been made. A watchdog interrupts such a call after a quarter of a second and the
/// retry succeeds (see `OpenWatchdog`; ``ScanStats/interruptedDirectoryOpens`` counts them).
///
/// ## Measured throughput
/// Release build, 12-core Apple silicon Mac, APFS on the internal SSD, 12 threads:
/// - metadata cached: 0.8–1.1 million entries/s (`/Applications`, 590k entries: 0.55 s;
///   `/System/Library`, 459k entries in 160k directories: 0.55 s; one thread: 270–370k/s);
/// - whole startup disk (4.6 million entries, 837k directories — more than the kernel's vnode
///   cache holds, so never fully "warm"): about 11 s, 410k entries/s;
/// - `du -sk` reports identical totals on the same trees and is several times slower
///   (`/Applications`: 4.7 s).
/// Building the final tree adds about 20 ms per million entries.
public final class ScanSession: @unchecked Sendable {
    public let root: URL
    public let options: ScanOptions

    private enum Phase { case idle, running, finished }

    /// Guards the mutable state below and wakes blocking waiters.
    private let state = NSCondition()
    private var phase = Phase.idle
    private var cancelRequested = false
    private var context: ScanContext?
    private var startTime: UInt64 = 0
    private var finalProgress = ScanProgress()
    private var finalResult: ScanResult?
    private var continuations: [CheckedContinuation<ScanResult, Never>] = []

    /// Serializes `Builder.snapshot()` against `finalize()` (the builder traps on use after
    /// finalize) and guards the two properties below.
    private let treeLock = NSLock()
    private var builder: FileTree.Builder?
    private var finalTree: FileTree?

    /// Tests only; set before `start()`. See `ScanContext.openHook`.
    var openHook: OpenHook?

    public init(root: URL, options: ScanOptions = .init()) {
        self.root = root
        self.options = options
    }

    // MARK: Control

    /// Begins scanning on background threads. Calling it again has no effect.
    public func start() {
        state.lock()
        guard phase == .idle else {
            state.unlock()
            return
        }
        phase = .running
        startTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        state.unlock()

        let coordinator = Thread { [self] in coordinate() }
        coordinator.name = "DiskSurvey scan coordinator"
        coordinator.qualityOfService = .userInitiated
        coordinator.start()
    }

    /// Stops the scan. Workers notice within one directory read (well under 100 ms); the result
    /// then holds the partial tree with `wasCancelled == true`. Cancelling a session that was
    /// never started finishes it with an empty tree. Has no effect once finished.
    public func cancel() {
        state.lock()
        cancelRequested = true
        let context = self.context
        let neverStarted = phase == .idle
        if neverStarted { phase = .running }
        state.unlock()
        context?.cancelled.store(true, ordering: .relaxed)
        if neverStarted {
            let path = root.path(percentEncoded: false)
            let builder = FileTree.Builder(rootPath: path.isEmpty ? "/" : path)
            install(builder)
            finish(builder: builder, reports: [], threadCount: 0, rootKind: .directory, resolvedRoot: builder.rootPath)
        }
    }

    public var isFinished: Bool {
        state.lock()
        defer { state.unlock() }
        return phase == .finished
    }

    // MARK: Observation

    /// Counters for a progress display. Costs a handful of atomic loads; fine to poll per frame.
    public var progress: ScanProgress {
        state.lock()
        let phase = self.phase
        let context = self.context
        let startTime = self.startTime
        let final = finalProgress
        state.unlock()

        switch phase {
        case .idle: return ScanProgress()
        case .finished: return final
        case .running:
            var progress = ScanProgress()
            progress.elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- startTime) / 1e9
            guard let context else { return progress }
            progress.filesScanned = context.files.load(ordering: .relaxed)
            progress.directoriesScanned = context.directories.load(ordering: .relaxed)
            progress.bytesAllocated = context.bytesAllocated.load(ordering: .relaxed)
            progress.bytesLogical = context.bytesLogical.load(ordering: .relaxed)
            progress.errorCount = context.errors.load(ordering: .relaxed)
            progress.currentPath = context.currentPath.withLock { String(decoding: $0, as: UTF8.self) }
            return progress
        }
    }

    /// A consistent tree of everything scanned so far, for drawing while the scan runs. After
    /// the scan has finished this is the final tree.
    ///
    /// Costs time and memory proportional to the entries scanned so far: roughly 0.1 s per
    /// million entries at utility priority (0.46–0.55 s at five million), and a second copy of
    /// the tree's columns for as long as the snapshot is kept. Call it from a background
    /// thread, and less often as the scan grows — ``snapshotDelay(entries:lastCost:)`` is the
    /// policy the app uses. NodeIDs are not stable from one snapshot to the next — carry
    /// selections across by path.
    public func snapshot() -> FileTree {
        treeLock.lock()
        defer { treeLock.unlock() }
        if let finalTree { return finalTree }
        if let builder { return builder.snapshot() }
        let path = root.path(percentEncoded: false)
        return FileTree.empty(rootPath: path.isEmpty ? "/" : path)
    }

    /// Entries (files + directories) up to which live snapshots are taken at the normal pace.
    public static let snapshotComfortableEntries: UInt64 = 1_000_000
    /// Entries beyond which no more live snapshots are taken.
    public static let snapshotEntryLimit: UInt64 = 2_000_000

    /// How long to wait before the next ``snapshot()`` of a running scan, or `nil` to take no
    /// more of them.
    ///
    /// Small scans refresh every 0.6 s, or less often if a snapshot is slow (eight times its
    /// cost, at most 3 s). Past ``snapshotComfortableEntries`` the wait grows with the tree —
    /// two seconds per million entries — because each snapshot then copies hundreds of
    /// megabytes; past ``snapshotEntryLimit`` snapshots stop. The snapshot on screen stays in
    /// memory until the final tree replaces it, so the fewer and the earlier the snapshots of a
    /// large scan, the lower its peak memory. Measured in the app on a 5.4-million-entry disk:
    /// 0.68 GB peak without snapshots, 0.86–0.89 GB with these limits, 1.04–1.08 GB when
    /// snapshots continued up to four million entries.
    ///
    /// - Parameters:
    ///   - entries: `progress.entriesScanned` just before the snapshot.
    ///   - lastCost: seconds the previous snapshot took (0 if none was taken yet).
    public static func snapshotDelay(entries: UInt64, lastCost: TimeInterval) -> TimeInterval? {
        if entries > snapshotEntryLimit { return nil }
        let paced = min(3, max(0.6, lastCost * 8))
        guard entries > snapshotComfortableEntries else { return paced }
        return max(paced, Double(entries) / 1_000_000 * 2)
    }

    /// Suspends until the scan has finished or was cancelled. Never blocks a thread. The session
    /// must be started (or cancelled) by someone, or this waits forever; cancelling the awaiting
    /// task does not cancel the scan — call ``cancel()`` or use ``scan(_:options:)``.
    public func result() async -> ScanResult {
        await withCheckedContinuation { continuation in
            state.lock()
            if let finalResult {
                state.unlock()
                continuation.resume(returning: finalResult)
            } else {
                continuations.append(continuation)
                state.unlock()
            }
        }
    }

    /// Blocks the calling thread until the scan has finished. For command-line tools and tests;
    /// never call it from the main thread of an app or from async code.
    public func waitBlocking() -> ScanResult {
        state.lock()
        defer { state.unlock() }
        while finalResult == nil { state.wait() }
        return finalResult!
    }

    /// Scans `root` and returns the result; cancelling the calling task cancels the scan.
    public static func scan(_ root: URL, options: ScanOptions = .init()) async -> ScanResult {
        let session = ScanSession(root: root, options: options)
        return await withTaskCancellationHandler {
            session.start()
            return await session.result()
        } onCancel: {
            session.cancel()
        }
    }

    // MARK: Coordinator

    private func install(_ builder: FileTree.Builder) {
        treeLock.lock()
        self.builder = builder
        treeLock.unlock()
    }

    private func coordinate() {
        ScanWorker.configureThread()
        let requested = root.path(percentEncoded: false)
        let requestedPath = requested.isEmpty ? "/" : requested

        // Resolve symlinks in the root only: "scan ~/link-to-folder" means the folder.
        guard let resolved = realpath(requestedPath, nil) else {
            failRoot(path: requestedPath, errno: errno)
            return
        }
        let rootPath = String(cString: resolved)
        free(resolved)
        var info = stat()
        guard lstat(rootPath, &info) == 0 else {
            failRoot(path: rootPath, errno: errno)
            return
        }

        if info.st_mode & S_IFMT != S_IFDIR {
            scanSingleFile(path: rootPath, info: info)
            return
        }

        let threadCount = options.threadCount > 0 ? min(options.threadCount, 64) : ScanOptions.automaticThreadCount
        let builder = FileTree.Builder(rootPath: rootPath, rootModified: Int64(info.st_mtimespec.tv_sec))
        let policy = MountPolicy(table: .current(), options: options, rootPath: rootPath)
        // Gets workers out of an `open` the system has stopped answering (see `OpenWatchdog`).
        let watchdog = options.interruptStalledOpens ? OpenWatchdog() : nil
        let context = ScanContext(
            builder: builder, options: options, policy: policy, threadCount: threadCount, watchdog: watchdog,
            openHook: openHook)
        install(builder)
        state.lock()
        self.context = context
        // A cancel that arrived before the context existed had nothing to flip.
        if cancelRequested { context.cancelled.store(true, ordering: .relaxed) }
        state.unlock()

        context.pool.push(DirWork.make(path: rootPath, ref: .root))

        let reports = OSAllocatedUnfairLock<[WorkerReport]>(initialState: [])
        let group = DispatchGroup()
        for index in 0 ..< threadCount {
            group.enter()
            let thread = Thread {
                ScanWorker.configureThread()
                let report = ScanWorker(context: context).run()
                reports.withLock { $0.append(report) }
                group.leave()
            }
            thread.name = "DiskSurvey scan \(index)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
        watchdog?.stop()
        context.pool.drain()

        finish(
            builder: builder, reports: reports.withLock { $0 }, threadCount: threadCount, rootKind: .directory,
            resolvedRoot: rootPath)
    }

    /// The root is missing or cannot be examined: an empty, unreadable tree plus one issue.
    private func failRoot(path: String, errno code: Int32) {
        let builder = FileTree.Builder(rootPath: path, rootFlags: .unreadable)
        install(builder)
        var report = WorkerReport()
        report.issues.append(ScanIssue(path: path, errno: code))
        finish(builder: builder, reports: [report], threadCount: 0, rootKind: .inaccessible, resolvedRoot: path)
    }

    /// The root is a file (or socket, device, …): the tree is its parent directory holding just it.
    private func scanSingleFile(path: String, info: stat) {
        let url = URL(filePath: path)
        let parent = url.deletingLastPathComponent().path(percentEncoded: false)
        var parentInfo = stat()
        let parentModified = lstat(parent, &parentInfo) == 0 ? Int64(parentInfo.st_mtimespec.tv_sec) : 0
        let builder = FileTree.Builder(rootPath: parent, rootModified: parentModified)
        install(builder)

        var report = WorkerReport()
        var flags: NodeFlags = []
        if info.st_flags & 0x4000_0000 != 0 {  // SF_DATALESS
            flags.insert(.dataless)
            report.stats.datalessEntries = 1
        }
        let allocated = UInt64(max(0, info.st_blocks)) * 512
        let logical = UInt64(max(0, info.st_size))
        builder.makeWorker().append(
            to: .root, name: url.lastPathComponent, allocatedSize: allocated, logicalSize: logical,
            modified: Int64(info.st_mtimespec.tv_sec), flags: flags)
        report.stats.files = 1
        finish(builder: builder, reports: [report], threadCount: 1, rootKind: .file, resolvedRoot: path)
    }

    private func finish(
        builder: FileTree.Builder, reports: [WorkerReport], threadCount: Int, rootKind: ScanResult.RootKind,
        resolvedRoot: String
    ) {
        let enumerationEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        treeLock.lock()
        let tree = builder.finalize()
        finalTree = tree
        self.builder = nil
        treeLock.unlock()

        var stats = ScanStats()
        stats.assemblyDuration = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- enumerationEnd) / 1e9
        var issues: [ScanIssue] = []
        for report in reports {
            stats.files += report.stats.files
            stats.directories += report.stats.directories
            stats.symlinks += report.stats.symlinks
            stats.hardLinkDuplicates += report.stats.hardLinkDuplicates
            stats.datalessEntries += report.stats.datalessEntries
            stats.mountPointsSkipped += report.stats.mountPointsSkipped
            stats.mountPointsEntered += report.stats.mountPointsEntered
            stats.excludedEntries += report.stats.excludedEntries
            stats.fallbackDirectories += report.stats.fallbackDirectories
            stats.slowDirectoryOpens += report.stats.slowDirectoryOpens
            stats.interruptedDirectoryOpens += report.stats.interruptedDirectoryOpens
            if report.stats.slowestDirectoryOpen > stats.slowestDirectoryOpen {
                stats.slowestDirectoryOpen = report.stats.slowestDirectoryOpen
                stats.slowestDirectoryPath = report.stats.slowestDirectoryPath
            }
            issues.append(contentsOf: report.issues)
        }
        stats.entries = stats.files + stats.directories
        stats.threadCount = threadCount
        issues.sort { $0.path < $1.path }

        state.lock()
        let context = self.context
        // Workers cap what they keep, so the true total comes from the shared counter.
        let totalIssues = max(issues.count, Int(context?.errors.load(ordering: .relaxed) ?? 0))
        if issues.count > ScanResult.issueLimit { issues.removeSubrange(ScanResult.issueLimit...) }
        let duration = startTime == 0 ? 0 : Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- startTime) / 1e9
        stats.entriesPerSecond = duration > 0 ? Double(stats.entries) / duration : 0
        stats.enumerationDuration = max(0, duration - stats.assemblyDuration)

        var progress = ScanProgress()
        progress.filesScanned = stats.files
        progress.directoriesScanned = stats.directories
        progress.bytesAllocated = tree.size(of: tree.root)
        progress.bytesLogical = tree.logicalSize(of: tree.root)
        progress.errorCount = UInt64(totalIssues)
        progress.currentPath = resolvedRoot
        progress.elapsed = duration
        progress.isFinished = true

        let result = ScanResult(
            tree: tree, duration: duration, issues: issues, totalIssueCount: totalIssues,
            wasCancelled: cancelRequested, stats: stats, rootKind: rootKind, resolvedRootPath: resolvedRoot)
        finalProgress = progress
        finalResult = result
        phase = .finished
        self.context = nil
        let waiting = continuations
        continuations = []
        state.broadcast()
        state.unlock()

        for continuation in waiting { continuation.resume(returning: result) }
    }
}
