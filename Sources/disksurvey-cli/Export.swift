import Foundation
import DiskSurveyCore
import DiskSurveyScan

/// `disksurvey export`: the complete tree, for other programs.
enum ExportCommand {
    static func run(_ context: Context) throws -> Int32 {
        let options = context.options
        guard let format = options.format else { throw UsageError("'export' needs --format json|csv|ncdu") }

        // Open the destination before scanning: a typo in -o should not cost a full scan.
        let toStdout = options.output == nil || options.output == "-"
        var sink = context.out
        var destination: ExportDestination?
        var scanContext = context
        if let path = options.output, !toStdout {
            let opened = try ExportDestination(path: path)
            destination = opened
            sink = Output(fd: opened.fd)
            // The export must not list its own output (or its temporary file) when -o lies inside
            // the scanned tree.
            var scanOptions = options
            scanOptions.excludes += opened.pathsToExclude
            scanContext = Context(options: scanOptions, out: context.out, style: context.style, columns: context.columns)
        }
        // Whatever goes wrong from here on, an existing output file stays as it was.
        defer { destination?.abandon() }

        let result = try Report.scan(scanContext)
        let tree = result.tree

        if let destination, destination.isAtomic, result.wasCancelled {
            // A partial csv or ncdu file is indistinguishable from a complete one, so an
            // interrupted scan never replaces (or creates) the output file.
            destination.abandon()
            CLI.note("disksurvey: the scan was interrupted; nothing was written to \(destination.path)")
            return Report.status(for: result)
        }

        var entries = 0
        switch format {
        case .json: entries = writeJSON(sink, result)
        case .csv: entries = writeCSV(sink, tree)
        case .ncdu: entries = writeNcdu(sink, tree)
        }
        sink.flush()
        if sink.failure != 0 {
            throw RuntimeError("cannot write '\(options.output ?? "standard output")': \(String(cString: strerror(sink.failure)))")
        }
        try destination?.commit()

        if !toStdout, let path = options.output {
            CLI.note(
                "Wrote \(Format.counted(entries, singular: "entry", plural: "entries")) "
                    + "(\(Format.bytes(sink.bytesWritten)), \(format.rawValue)) to \(path) — "
                    + "\(Format.bytes(tree.size(of: tree.root))) scanned in \(Format.duration(result.duration))")
        }
        if result.wasCancelled {
            CLI.note("disksurvey: the scan was interrupted; the export is partial")
        } else if result.totalIssueCount > 0, !options.showIssues {
            CLI.note(
                "disksurvey: \(Format.counted(result.totalIssueCount, singular: "item", plural: "items")) could not be read; --issues lists them")
        }
        return Report.status(for: result)
    }

    // MARK: JSON — the scan schema without limits; nodes carry names, not paths

    private static func writeJSON(_ out: Output, _ result: ScanResult) -> Int {
        let tree = result.tree
        let json = JSONWriter(out, pretty: false)
        var entries = 0
        Report.beginEnvelope(json, command: .export, result: result)

        func node(_ id: NodeID, path: String?) {
            entries += 1
            json.lineBreak()
            json.beginObject()
            Report.nodeFields(json, tree, id, path: path)
            if tree.isDirectory(id) {
                json.key("children")
                json.beginArray()
                for child in tree.children(of: id) { node(child, path: nil) }
                json.endArray()
            }
            json.endObject()
        }
        json.key("tree")
        node(tree.root, path: tree.rootPath)
        json.lineBreak()
        json.endObject()
        json.finish()
        return entries
    }

    // MARK: CSV — one row per entry, RFC 4180 quoting

    private static func writeCSV(_ out: Output, _ tree: FileTree) -> Int {
        out.line("path,type,allocated_bytes,logical_bytes,file_count,modified,extension,category,depth,flags")
        var entries = 0

        // Byte-wise check: this runs once per entry, and Character iteration would dominate.
        func field(_ text: String) -> String {
            guard text.utf8.contains(where: { $0 == 0x2C || $0 == 0x22 || $0 == 0x0A || $0 == 0x0D }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func row(_ id: NodeID, path: String, depth: Int) {
            entries += 1
            let flags = tree.flags(of: id)
            let kind = tree.fileKind(of: id)
            let isPlainDirectory = flags.contains(.directory) && !flags.contains(.package)
            var line = field(path)
            line += "," + Report.typeName(flags)
            line += ",\(tree.size(of: id)),\(tree.logicalSize(of: id)),\(tree.fileCount(of: id)),"
            line += iso8601(tree.modified(of: id))
            line += "," + (isPlainDirectory || kind.isUnixExecutable ? "" : field(kind.ext))
            line += "," + (isPlainDirectory ? "" : ArgumentParser.categoryName(kind.category))
            line += ",\(depth)," + Report.flagNames(flags, executable: Report.isUnixExecutable(tree, id)).joined(separator: "|")
            out.line(line)
            for child in tree.children(of: id) {
                let name = tree.name(of: child)
                row(child, path: path == "/" ? "/" + name : path + "/" + name, depth: depth + 1)
            }
        }
        row(tree.root, path: tree.rootPath, depth: 0)
        return entries
    }

    /// "2026-11-09T12:34:56Z"; empty for unknown timestamps.
    private static func iso8601(_ epoch: Int64) -> String {
        guard epoch > 0 else { return "" }
        var time = time_t(epoch)
        var parts = tm()
        gmtime_r(&time, &parts)
        func two(_ value: Int32) -> String { value < 10 ? "0\(value)" : "\(value)" }
        let year = Int(parts.tm_year) + 1900
        return "\(year < 1000 ? "0" : "")\(year)-\(two(parts.tm_mon + 1))-\(two(parts.tm_mday))T"
            + "\(two(parts.tm_hour)):\(two(parts.tm_min)):\(two(parts.tm_sec))Z"
    }

    // MARK: ncdu — https://dev.yorhel.nl/ncdu/jsonfmt, readable with `ncdu -f file`
    //
    // [1, 0, {metadata}, directory]; a directory is an array whose first element describes the
    // directory itself and whose other elements are files (objects) or directories (arrays).
    // `asize` is the apparent size and `dsize` the disk usage of the entry itself, so directories
    // carry none: ncdu sums the children, exactly like the Disk Survey tree. Hard-link duplicates
    // are exported with size 0 (they were counted once already), not with ncdu's inode fields.

    private static func writeNcdu(_ out: Output, _ tree: FileTree) -> Int {
        let json = JSONWriter(out, pretty: false)
        var entries = 0

        func info(_ id: NodeID, name: String) {
            entries += 1
            let flags = tree.flags(of: id)
            let isDirectory = flags.contains(.directory)
            json.beginObject()
            json.field("name", name)
            if !isDirectory {
                json.field("asize", tree.logicalSize(of: id))
                json.field("dsize", tree.size(of: id))
            }
            if flags.contains(.unreadable) { json.field("read_error", true) }
            // A mount point that was kept but not entered is what ncdu calls "otherfs".
            if flags.contains(.mountPoint), tree.childCount(of: id) == 0 { json.field("excluded", "otherfs") }
            if flags.contains(.symlink) { json.field("notreg", true) }
            json.endObject()
        }
        func directory(_ id: NodeID, name: String) {
            json.beginArray()
            info(id, name: name)
            for child in tree.children(of: id) {
                json.lineBreak()
                if tree.isDirectory(child) {
                    directory(child, name: tree.name(of: child))
                } else {
                    info(child, name: tree.name(of: child))
                }
            }
            json.endArray()
        }

        json.beginArray()
        json.value(1)
        json.value(0)
        json.beginObject()
        json.field("progname", "disksurvey")
        json.field("progver", DiskSurveyVersion.string)
        json.field("timestamp", Int(Date().timeIntervalSince1970))
        json.endObject()
        json.lineBreak()
        directory(tree.root, name: tree.rootPath)
        json.endArray()
        json.finish()
        return entries
    }
}

// MARK: - Destination file

/// The file behind `export -o`.
///
/// A regular file is never written in place: the export goes to a temporary file in the same
/// folder, which replaces the destination with one `rename` once it is complete. A failed or
/// interrupted export therefore leaves a previous export untouched instead of truncated.
/// Anything that is not a regular file (/dev/stdout, /dev/null, a FIFO) is opened directly —
/// renaming over it would replace the device or pipe with a file.
final class ExportDestination {
    /// The path as given, for messages.
    let path: String
    let fd: Int32
    /// True when the export is written to a temporary file and renamed into place.
    var isAtomic: Bool { temporaryPath != nil }
    /// Resolved paths the scan has to leave out so that the export does not list itself.
    private(set) var pathsToExclude: [String] = []

    /// Where the finished export goes: `path` with a symlink resolved, so the link survives.
    private let finalPath: String
    private let temporaryPath: String?
    private var isOpen = true
    private var finished = false

    init(path: String) throws {
        self.path = path
        func failure(_ code: Int32 = errno) -> RuntimeError {
            RuntimeError("cannot write '\(path)': \(String(cString: strerror(code)))")
        }

        // Write next to the target of a symlink rather than replacing the link.
        var target = path
        var info = stat()
        if !path.hasPrefix("/dev/"), lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK,
            let resolved = realpath(path, nil)
        {
            target = String(cString: resolved)
            free(resolved)
        }
        let exists = stat(target, &info) == 0
        let dangling = !exists && lstat(target, &info) == 0   // a symlink whose target is missing

        // /dev/stdout and /dev/fd/N describe whatever the descriptor is open on — a regular file
        // when the shell redirected it — but they are descriptors, not files in a folder, and
        // are opened as given.
        let isDevice = target.hasPrefix("/dev/")

        if (exists && info.st_mode & S_IFMT != S_IFREG) || dangling || isDevice {
            // Devices, pipes, sockets (and directories, which fail here with EISDIR). A dangling
            // symlink is created through, as before: there is no earlier content to protect.
            let fd = open(target, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw failure() }
            self.fd = fd
            finalPath = target
            temporaryPath = nil
            return
        }
        // rename() would happily replace a file that is not writable; opening it never did.
        if exists, access(target, W_OK) != 0 { throw failure() }

        let (folder, name) = Self.split(target)
        let temporary = (folder == "/" ? "/" : folder + "/") + ".\(name).tmp.\(getpid())"
        // Same folder: the rename stays on one volume and is atomic. This also fails fast on a
        // missing folder or missing permission, before the scan.
        var fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        if fd < 0, errno == EEXIST {
            // Left behind by an earlier, killed run that had this process ID.
            unlink(temporary)
            fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        }
        guard fd >= 0 else { throw failure() }
        // The replacement keeps the permissions of the file it replaces.
        if exists { fchmod(fd, info.st_mode & 0o7777) }
        self.fd = fd
        finalPath = target
        temporaryPath = temporary
        PendingOutput.register(temporary)

        // The scanner compares resolved paths (/tmp is /private/tmp), so resolve the folder.
        if let resolved = realpath(folder, nil) {
            let resolvedFolder = String(cString: resolved)
            free(resolved)
            pathsToExclude.append((resolvedFolder == "/" ? "/" : resolvedFolder + "/") + ".\(name).tmp.\(getpid())")
        }
        if exists, let resolved = realpath(target, nil) {
            pathsToExclude.append(String(cString: resolved))
            free(resolved)
        }
    }

    deinit { abandon() }

    /// The export is complete: move it into place. Throws if that fails; the destination is then
    /// unchanged.
    func commit() throws {
        guard !finished else { return }
        let closed = closeDescriptor()
        guard let temporaryPath else {
            finished = true
            if !closed { throw RuntimeError("cannot write '\(path)': \(String(cString: strerror(errno)))") }
            return
        }
        guard closed, rename(temporaryPath, finalPath) == 0 else {
            let code = errno
            abandon()
            throw RuntimeError("cannot write '\(path)': \(String(cString: strerror(code)))")
        }
        finished = true
        PendingOutput.clear()
    }

    /// Gives up: closes the file and removes the temporary one. Does nothing after `commit`.
    func abandon() {
        closeDescriptor()
        guard !finished else { return }
        finished = true
        if let temporaryPath {
            unlink(temporaryPath)
            PendingOutput.clear()
        }
    }

    @discardableResult
    private func closeDescriptor() -> Bool {
        guard isOpen else { return true }
        isOpen = false
        return close(fd) == 0
    }

    /// ("/a/b", "c") for "/a/b/c"; (".", "c") for "c".
    private static func split(_ path: String) -> (folder: String, name: String) {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return (".", trimmed) }
        return (slash == trimmed.startIndex ? "/" : String(trimmed[..<slash]), String(trimmed[trimmed.index(after: slash)...]))
    }
}
