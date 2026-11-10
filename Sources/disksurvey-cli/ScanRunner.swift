import Foundation
import Synchronization
import DiskSurveyCore
import DiskSurveyScan

/// Runs a scan in the foreground: live progress on stderr, Ctrl-C cancels cleanly.
enum ScanRunner {
    static func run(path: String, options: Options, style: Style) throws -> ScanResult {
        var scanOptions = ScanOptions()
        scanOptions.threadCount = options.threads
        scanOptions.crossMountPoints = options.crossMounts
        scanOptions.excludedPaths = options.excludes.map(exclusionPath)
        // `--exclude link` leaves out the link, not what it points to.
        scanOptions.excludedPathsFollowSymlinks = false

        let session = ScanSession(root: URL(filePath: absolutePath(path)), options: scanOptions)

        let progress: ProgressLine? =
            !options.noProgress && Terminal.isTTY(STDERR_FILENO) && ProcessInfo.processInfo.environment["TERM"] != "dumb"
            ? ProgressLine(session: session, style: Style(mode: options.color, ascii: options.ascii, fd: STDERR_FILENO))
            : nil
        let interrupt = Interrupt(session: session, progress: progress)

        session.start()
        progress?.start()
        let result = session.waitBlocking()
        progress?.stop()
        interrupt.disarm()

        if result.rootKind == .inaccessible {
            let reason = result.issues.first?.message ?? "not accessible"
            throw RuntimeError("cannot scan '\(path)': \(reason)")
        }
        if let message = unreadableRootMessage(result, path: path) { throw RuntimeError(message) }
        return result
    }

    /// The error for a scan whose root exists but could not be listed at all — an empty report
    /// with exit status 0 would read as "this folder is empty". `nil` when anything was read,
    /// when the scan was interrupted, or when the root is fine (an unreadable *sub*folder is an
    /// issue, not a failure).
    static func unreadableRootMessage(_ result: ScanResult, path: String) -> String? {
        let tree = result.tree
        guard !result.wasCancelled, result.rootKind == .directory, tree.flags(of: tree.root).contains(.unreadable),
            tree.childCount(of: tree.root) == 0
        else { return nil }
        let issue = result.issues.first { $0.path == result.resolvedRootPath }
        var message = "cannot scan '\(path)': \(issue?.message ?? "Permission denied")"
        if issue == nil || issue?.kind == .permissionDenied {
            message += " (grant your terminal Full Disk Access in System Settings, or use sudo)"
        }
        return message
    }

    /// Absolute and, where the path exists, fully resolved — the scanner works on resolved paths,
    /// so an exclusion given as `/tmp/x` has to become `/private/tmp/x` to match.
    static func absolutePath(_ path: String) -> String {
        // An empty path is rejected when the arguments are parsed; if one gets here anyway it
        // stays empty (and fails as "no such file") rather than turning into the working directory.
        guard !path.isEmpty else { return path }
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
    }

    /// The path of an `--exclude`, as the scanner will see that entry: absolute, with the folder
    /// resolved but the last component kept as given. The scanner matches an exclusion against
    /// the folder's resolved path plus the entry's own name and never follows symlinks, so
    /// resolving the name as well would exclude what a symlink points to instead of the symlink.
    static func exclusionPath(_ path: String) -> String {
        var trimmed = path
        // `dir/link/` means the entry `link`; with the slash, realpath would follow it.
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, trimmed != "/" else { return absolutePath(trimmed) }

        let parent: String
        let name: String
        if let slash = trimmed.lastIndex(of: "/") {
            parent = slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
            name = String(trimmed[trimmed.index(after: slash)...])
        } else {
            parent = "."
            name = trimmed
        }
        // No literal name to keep.
        if name == "." || name == ".." { return absolutePath(trimmed) }

        guard let resolved = realpath(parent, nil) else {
            // The folder does not exist, so the exclusion cannot match anything; still absolute.
            return absolutePath(trimmed)
        }
        defer { free(resolved) }
        let folder = String(cString: resolved)
        return folder == "/" ? "/" + name : folder + "/" + name
    }
}

// MARK: - Ctrl-C

/// First SIGINT/SIGTERM: cancel the scan and let the command print what it has, marked partial.
/// Second: leave immediately.
private final class Interrupt: @unchecked Sendable {
    private let queue = DispatchQueue(label: "disksurvey.signals")
    private var sources: [DispatchSourceSignal] = []
    private var count = 0

    init(session: ScanSession, progress: ProgressLine?) {
        for number in [SIGINT, SIGTERM] {
            // Dispatch only sees a signal whose default action is out of the way.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [self] in
                count += 1
                if count == 1 {
                    progress?.noteCancelling()
                    session.cancel()
                } else {
                    progress?.stop()
                    // An export in progress must not leave its temporary file behind.
                    PendingOutput.discard()
                    _exit(130)
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    /// After the scan, Ctrl-C goes back to ending the program (a long report may be printing).
    func disarm() {
        queue.sync {
            for source in sources { source.cancel() }
            sources.removeAll()
        }
        PendingOutput.restoreDefaultSignals()
    }
}

// MARK: - Unfinished output file

/// The temporary file of an `export -o` that has not been moved into place yet. It is recorded
/// process-wide so that every way of being interrupted — the second Ctrl-C during the scan, or a
/// signal while the export is being written — removes it instead of leaving it next to the output.
enum PendingOutput {
    /// The address of a strdup'd path, or 0. Atomic because it is read from a signal handler
    /// (and held as an integer because a raw pointer is not Sendable).
    private static let path = Atomic<UInt>(0)

    private static func exchange(_ replacement: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
        UnsafeMutablePointer(bitPattern: path.exchange(UInt(bitPattern: replacement), ordering: .sequentiallyConsistent))
    }

    static func register(_ temporaryPath: String) {
        free(exchange(strdup(temporaryPath)))
    }

    /// Forgets the file without touching it (it was renamed into place, or already removed).
    static func clear() {
        free(exchange(nil))
    }

    /// Removes the file, if there is one. Only async-signal-safe calls: the pointer is taken out
    /// atomically and deliberately not freed.
    static func discard() {
        if let pending = exchange(nil) { unlink(pending) }
    }

    /// SIGINT/SIGTERM end the program again once the scan is over; while an output file is
    /// pending they remove it first.
    static func restoreDefaultSignals() {
        let pending = path.load(ordering: .sequentiallyConsistent) != 0
        for number in [SIGINT, SIGTERM] {
            if pending {
                signal(number) { number in
                    PendingOutput.discard()
                    signal(number, SIG_DFL)
                    raise(number)
                }
            } else {
                signal(number, SIG_DFL)
            }
        }
    }
}

// MARK: - Progress line

/// One self-overwriting status line on stderr, redrawn ten times a second.
final class ProgressLine: @unchecked Sendable {
    private let session: ScanSession
    private let style: Style
    private let queue = DispatchQueue(label: "disksurvey.progress")
    private var timer: DispatchSourceTimer?
    private var frame = 0
    private var drawn = false
    private var cancelling = false
    private var stopped = false

    init(session: ScanSession, style: Style) {
        self.session = session
        self.style = style
    }

    func start() {
        queue.sync {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            // Scans that finish within a blink never flash a progress line.
            timer.schedule(deadline: .now() + .milliseconds(150), repeating: .milliseconds(100))
            timer.setEventHandler { [self] in draw() }
            timer.resume()
            self.timer = timer
        }
    }

    func noteCancelling() {
        queue.async { [self] in
            cancelling = true
            draw()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
            if drawn { emit("\r\u{1B}[K") }
            drawn = false
        }
    }

    private func draw() {
        guard !stopped else { return }
        let progress = session.progress
        let columns = (Terminal.columns(STDERR_FILENO) ?? 80) - 1
        let spinner = style.unicode ? ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"] : ["|", "/", "-", "\\"]
        frame += 1

        let rate = Format.compactCount(Int(progress.entriesPerSecond)) + "/s"
        let head =
            (cancelling ? "Cancelling" : "Scanning") + "  "
            + Format.count(Int(progress.entriesScanned)) + " items" + style.separator
            + Format.bytes(progress.bytesAllocated) + style.separator + rate
        var plain = spinner[frame % spinner.count] + " " + head
        var tail = ""
        let room = columns - Text.width(plain) - 2
        if room >= 12, !progress.currentPath.isEmpty {
            tail = Text.truncated(Text.sanitized(progress.currentPath), to: room, cut: .middle, ellipsis: style.ellipsis)
        }
        plain = Text.truncated(plain, to: max(columns, 1), ellipsis: style.ellipsis)
        emit("\r" + style.bold(plain) + (tail.isEmpty ? "" : "  " + style.dim(tail)) + "\u{1B}[K")
        drawn = true
    }

    private func emit(_ text: String) {
        var bytes = Array(text.utf8)
        _ = Darwin.write(STDERR_FILENO, &bytes, bytes.count)
    }
}
