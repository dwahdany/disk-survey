import Foundation
import DiskSurveyCore
import DiskSurveyScan

/// Exit statuses (documented in `--help`).
enum ExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    /// Interrupted by Ctrl-C; whatever was scanned up to then has been printed, marked partial.
    static let interrupted: Int32 = 130
}

/// What every command needs to produce output.
struct Context {
    let options: Options
    let out: Output
    let style: Style
    /// Terminal width of stdout, nil when stdout is not a terminal (then nothing is truncated).
    let columns: Int?
}

enum CLI {
    static func run(arguments: [String]) -> Int32 {
        // A closed pipe is reported to `Output` as EPIPE instead of killing the process.
        signal(SIGPIPE, SIG_IGN)

        let options: Options
        do {
            options = try ArgumentParser.parse(arguments)
        } catch let error as UsageError {
            complain(error.message, hint: "Try 'disksurvey --help'.")
            return ExitCode.usage
        } catch {
            complain("\(error)")
            return ExitCode.usage
        }

        let out = Output(fd: STDOUT_FILENO)
        if options.version {
            out.line("disksurvey \(DiskSurveyVersion.string)")
            out.flush()
            return ExitCode.success
        }
        if options.help || options.command == .help {
            out.write(Help.text)
            out.flush()
            return ExitCode.success
        }

        let context = Context(
            options: options, out: out, style: Style(mode: options.color, ascii: options.ascii, fd: STDOUT_FILENO),
            columns: Terminal.columns(STDOUT_FILENO))
        do {
            let status: Int32
            switch options.command {
            case .scan: status = try ScanCommand.run(context)
            case .top: status = try TopCommand.run(context)
            case .kinds: status = try KindsCommand.run(context)
            case .find: status = try FindCommand.run(context)
            case .export: status = try ExportCommand.run(context)
            case .volumes: status = VolumesCommand.run(context)
            case .help: status = ExitCode.success
            }
            out.flush()
            if out.failure != 0 {
                complain("cannot write output: \(String(cString: strerror(out.failure)))")
                return ExitCode.failure
            }
            return status
        } catch let error as UsageError {
            out.flush()
            complain(error.message, hint: "Try 'disksurvey --help'.")
            return ExitCode.usage
        } catch let error as RuntimeError {
            out.flush()
            complain(error.message)
            return ExitCode.failure
        } catch {
            out.flush()
            complain("\(error)")
            return ExitCode.failure
        }
    }

    static func complain(_ message: String, hint: String? = nil) {
        var text = "disksurvey: \(message)\n"
        if let hint { text += hint + "\n" }
        writeStderr(text)
    }

    static func note(_ message: String) {
        writeStderr(message + "\n")
    }

    /// Diagnostics are best effort: a closed or broken stderr (`2>&-`, a reader that has exited)
    /// must neither abort the program nor change its exit status. `FileHandle.write` raises an
    /// Objective-C exception on EBADF/EPIPE, and `Output` treats EPIPE as "the reader is done,
    /// exit 0" — both wrong here — so this writes the descriptor directly and drops what it cannot
    /// deliver. (SIGPIPE is ignored at startup, so a dead reader shows up as EPIPE.)
    static func writeStderr(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(STDERR_FILENO, base + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    // EBADF, EPIPE, ENOSPC, EIO, or EAGAIN on a non-blocking descriptor shared
                    // with the parent: there is nowhere left to report it.
                    return
                }
            }
        }
    }
}

// MARK: - Pieces shared by the scanning commands

enum Report {
    /// Scans the command's path (default: the current directory).
    static func scan(_ context: Context) throws -> ScanResult {
        let path = context.options.positionals.first ?? "."
        let result = try ScanRunner.run(path: path, options: context.options, style: context.style)
        if context.options.showIssues { listIssues(result, style: context.style) }
        if let note = slowOpenNote(result.stats) { CLI.note(note) }
        return result
    }

    /// The path to show as the report's subject. For a single-file scan the tree is rooted at the
    /// file's folder (a tree root is always a directory), which is not what was asked about.
    static func title(_ result: ScanResult) -> String {
        Text.sanitized(result.rootKind == .file ? result.resolvedRootPath : result.tree.rootPath)
    }

    static func status(for result: ScanResult) -> Int32 {
        result.wasCancelled ? ExitCode.interrupted : ExitCode.success
    }

    /// A stderr line saying that the scan was held up by the system rather than slow by itself;
    /// `nil` unless some directory took noticeably long to open.
    static func slowOpenNote(_ stats: ScanStats) -> String? {
        guard stats.slowDirectoryOpens > 0 else { return nil }
        var text = "disksurvey: held up \(Format.duration(stats.slowestDirectoryOpen)) opening "
        text += stats.slowestDirectoryPath.isEmpty ? "a folder" : Text.sanitized(stats.slowestDirectoryPath)
        if stats.slowDirectoryOpens > 1 {
            text += " (\(Format.count(Int(stats.slowDirectoryOpens))) folders took 0.1 s or longer to open)"
        }
        return text + "; the scan time says little about scanning speed"
    }

    /// `--issues`: what could not be read, on stderr so it never mixes into piped reports.
    static func listIssues(_ result: ScanResult, style: Style) {
        guard result.totalIssueCount > 0 else { return }
        var text = ""
        for issue in result.issues {
            text += "disksurvey: \(Text.sanitized(issue.path)): \(issue.message)\n"
        }
        if result.totalIssueCount > result.issues.count {
            text += "disksurvey: \(style.ellipsis) and \(Format.count(result.totalIssueCount - result.issues.count)) more\n"
        }
        CLI.writeStderr(text)
    }

    static func partialBanner(_ context: Context, _ result: ScanResult) {
        guard result.wasCancelled else { return }
        context.out.line(context.style.warning("PARTIAL RESULT") + " — the scan was interrupted; sizes and counts are incomplete")
    }

    /// The closing lines of every human-readable report.
    static func summary(_ context: Context, _ result: ScanResult) {
        let style = context.style
        let tree = result.tree
        let root = tree.root
        var parts = [
            Format.files(tree.fileCount(of: root)),
            Format.counted(Int(result.stats.directories), singular: "folder", plural: "folders"),
            Format.bytes(tree.size(of: root)) + " on disk (" + Format.bytes(tree.logicalSize(of: root)) + " logical)",
            Format.duration(result.duration) + ", " + Format.compactCount(Int(result.stats.entriesPerSecond))
                + " entries/s",
        ]
        if result.totalIssueCount > 0 {
            parts.append(Format.counted(result.totalIssueCount, singular: "issue", plural: "issues"))
        }
        context.out.line()
        context.out.line(style.dim(parts.joined(separator: style.separator)))
        if result.wasCancelled {
            context.out.line(style.warning("Partial result: the scan was interrupted."))
        }
        if result.totalIssueCount > 0 {
            let denied = result.permissionDeniedCount
            var hint = Format.counted(result.totalIssueCount, singular: "item", plural: "items") + " could not be read"
            if denied > 0 {
                hint += " (permission denied). Grant your terminal Full Disk Access in System Settings, or use sudo"
            }
            if !context.options.showIssues { hint += "; --issues lists them" }
            context.out.line(style.dim(hint + "."))
        }
    }

    // MARK: JSON

    /// Opens the top-level object and writes the fields common to every scanning command.
    static func beginEnvelope(_ json: JSONWriter, command: Command, result: ScanResult) {
        let tree = result.tree
        json.beginObject()
        json.field("disksurvey", DiskSurveyVersion.string)
        json.field("schemaVersion", 1)
        json.field("command", command.rawValue)
        json.field("root", result.resolvedRootPath)
        json.field("partial", result.wasCancelled)
        json.key("summary")
        json.beginObject()
        json.field("files", tree.fileCount(of: tree.root))
        json.field("directories", result.stats.directories)
        json.field("symlinks", result.stats.symlinks)
        json.field("hardLinkDuplicates", result.stats.hardLinkDuplicates)
        json.field("datalessEntries", result.stats.datalessEntries)
        json.field("mountPointsSkipped", result.stats.mountPointsSkipped)
        json.field("allocatedBytes", tree.size(of: tree.root))
        json.field("logicalBytes", tree.logicalSize(of: tree.root))
        json.field("elapsedSeconds", result.duration)
        json.field("entriesPerSecond", Int(result.stats.entriesPerSecond.rounded()))
        json.field("threads", result.stats.threadCount)
        json.field("issues", result.totalIssueCount)
        // Attribution for a slow scan: one directory `open` that blocks holds everything up.
        json.field("slowestOpenSeconds", result.stats.slowestDirectoryOpen)
        json.field("slowOpens", result.stats.slowDirectoryOpens)
        json.field("slowestOpenPath", result.stats.slowestDirectoryPath)
        json.endObject()
        json.key("issues")
        json.beginArray()
        for issue in result.issues {
            json.beginObject()
            json.field("path", issue.path)
            json.field("errno", Int(issue.errno))
            json.field("message", issue.message)
            json.endObject()
        }
        json.endArray()
    }

    static func isUnixExecutable(_ tree: FileTree, _ id: NodeID) -> Bool {
        !tree.isDirectory(id) && tree.fileKind(of: id).isUnixExecutable
    }

    static func typeName(_ flags: NodeFlags) -> String {
        if flags.contains(.package) { return "package" }
        if flags.contains(.directory) { return "directory" }
        if flags.contains(.symlink) { return "symlink" }
        return "file"
    }

    /// `executable`: the node has the "Unix Executable" pseudo-kind (no extension, an execute
    /// permission bit), which is reported here rather than as a made-up extension.
    static func flagNames(_ flags: NodeFlags, executable: Bool = false) -> [String] {
        var names: [String] = []
        if executable { names.append("unixExecutable") }
        if flags.contains(.hardLinkDuplicate) { names.append("hardLinkDuplicate") }
        if flags.contains(.unreadable) { names.append("unreadable") }
        if flags.contains(.mountPoint) { names.append("mountPoint") }
        if flags.contains(.dataless) { names.append("dataless") }
        if flags.contains(.synthetic) { names.append("synthetic") }
        return names
    }

    /// The fields of a node object, without `children`. The caller opens and closes the object.
    static func nodeFields(_ json: JSONWriter, _ tree: FileTree, _ id: NodeID, path: String?) {
        let flags = tree.flags(of: id)
        json.field("name", tree.name(of: id))
        if let path { json.field("path", path) }
        json.field("type", typeName(flags))
        json.field("allocatedBytes", tree.size(of: id))
        json.field("logicalBytes", tree.logicalSize(of: id))
        json.field("fileCount", tree.fileCount(of: id))
        json.key("modified")
        let modified = tree.modified(of: id)
        if modified > 0 { json.value(Int(modified)) } else { json.null() }
        if !flags.contains(.directory) || flags.contains(.package) {
            let kind = tree.fileKind(of: id)
            json.field("extension", kind.isUnixExecutable ? "" : kind.ext)
            json.field("category", ArgumentParser.categoryName(kind.category))
        }
        json.field("flags", strings: flagNames(flags, executable: isUnixExecutable(tree, id)))
    }

    // MARK: Rows

    static func color(_ tree: FileTree, _ id: NodeID, _ style: Style) -> RGB {
        let flags = tree.flags(of: id)
        if flags.contains(.directory), !flags.contains(.package) { return style.folderColor }
        return KindPalette.color(for: tree.fileKind(of: id), scheme: style.scheme)
    }

    /// A short parenthetical for entries whose size needs explaining.
    static func annotation(_ tree: FileTree, _ id: NodeID) -> String? {
        let flags = tree.flags(of: id)
        if flags.contains(.unreadable) { return "unreadable" }
        if flags.contains(.mountPoint), tree.childCount(of: id) == 0 { return "other volume, not scanned" }
        if flags.contains(.mountPoint) { return "volume" }
        if flags.contains(.dataless) { return "in iCloud, not downloaded" }
        if flags.contains(.hardLinkDuplicate) { return "hard link, counted elsewhere" }
        if flags.contains(.symlink) { return "symlink" }
        return nil
    }

    static func barWidth(columns: Int?) -> Int {
        guard let columns else { return 16 }
        return columns >= 110 ? 20 : columns >= 80 ? 14 : columns >= 56 ? 8 : 0
    }

    /// Path of a node relative to the scan root ("Library/Caches/x.bin").
    static func relativePath(_ tree: FileTree, _ id: NodeID) -> String {
        let lineage = tree.lineage(of: id).dropFirst()
        return lineage.isEmpty ? "." : lineage.map { tree.name(of: $0) }.joined(separator: "/")
    }

    /// One flat row per node — the body of `top` and `find`:
    /// size, share bar, share, age, path (truncated in the middle on a terminal).
    static func list(_ context: Context, _ tree: FileTree, _ nodes: [NodeID]) {
        let style = context.style
        let total = tree.size(of: tree.root)
        let sizes = nodes.map { Format.bytes(tree.size(of: $0)) }
        let ages = nodes.map { Format.relativeDate(tree.modified(of: $0)) }
        let sizeWidth = sizes.map(Text.width).max() ?? 0
        let ageWidth = (context.columns ?? 100) >= 72 ? (ages.map(Text.width).max() ?? 0) : 0
        let barWidth = Report.barWidth(columns: context.columns)

        for (index, id) in nodes.enumerated() {
            let fraction = total > 0 ? Double(tree.size(of: id)) / Double(total) : 0
            let color = Report.color(tree, id, style)
            var line = Text.padded(sizes[index], to: sizeWidth, right: true) + "  "
            var used = sizeWidth + 2
            if barWidth > 0 {
                let bar = style.bar(fraction, width: barWidth)
                line += style.paint(bar.filled, color) + bar.rest + " "
                used += barWidth + 1
            }
            line += Text.padded(Format.percent(fraction), to: 6, right: true) + "  "
            used += 8
            if ageWidth > 0 {
                line += style.dim(Text.padded(ages[index], to: ageWidth)) + "  "
                used += ageWidth + 2
            }
            var path = Text.sanitized(relativePath(tree, id))
            if tree.isDirectory(id) { path += "/" }
            var note = annotation(tree, id).map { "  (\($0))" } ?? ""
            if let columns = context.columns {
                let room = max(columns - used, 8)
                if Text.width(path) + Text.width(note) > room { note = "" }
                path = Text.truncated(path, to: room, cut: .middle, ellipsis: style.ellipsis)
            }
            line += style.paint(path, color, bold: tree.isDirectory(id)) + style.dim(note)
            context.out.line(line)
        }
    }
}
