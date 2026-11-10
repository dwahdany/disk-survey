import Foundation
import DiskSurveyCore
import DiskSurveyScan

// MARK: - scan

/// The default command: a tree of the largest entries.
enum ScanCommand {
    /// The children of one directory that make it into the report, and what was left out.
    private struct Selection {
        var shown: [NodeID] = []
        var omittedCount = 0
        var omittedAllocated: UInt64 = 0
        var omittedLogical: UInt64 = 0
    }

    private struct Plan {
        let tree: FileTree
        let options: Options
        let depth: Int

        func metric(_ id: NodeID) -> UInt64 { options.logical ? tree.logicalSize(of: id) : tree.size(of: id) }

        /// `level` is the depth of the children being selected (1 = directly below the root).
        func select(_ id: NodeID, level: Int) -> Selection {
            // Without an explicit --top the first level gets room and deeper levels stay terse,
            // which keeps the default report to about a screenful.
            let limit = options.limit ?? (level == 1 ? 10 : 4)
            var children = Array(tree.children(of: id))
            if options.logical {
                // The tree keeps siblings ordered by allocated size.
                children.sort { a, b in
                    let (la, lb) = (tree.logicalSize(of: a), tree.logicalSize(of: b))
                    return la != lb ? la > lb : a < b
                }
            }
            var selection = Selection()
            for child in children {
                if selection.shown.count < limit, metric(child) >= (options.minSize ?? 0) {
                    selection.shown.append(child)
                } else {
                    selection.omittedCount += 1
                    selection.omittedAllocated += tree.size(of: child)
                    selection.omittedLogical += tree.logicalSize(of: child)
                }
            }
            return selection
        }

        func descends(into id: NodeID, level: Int) -> Bool {
            let flags = tree.flags(of: id)
            return level < depth && flags.contains(.directory) && tree.childCount(of: id) > 0
                && !(options.packages && flags.contains(.package))
        }
    }

    static func run(_ context: Context) throws -> Int32 {
        let result = try Report.scan(context)
        let plan = Plan(tree: result.tree, options: context.options, depth: context.options.depth ?? 2)
        if context.options.json {
            writeJSON(context, result, plan)
        } else {
            writeText(context, result, plan)
        }
        return Report.status(for: result)
    }

    // MARK: Text

    private struct Row {
        var size: UInt64
        var prefix: String
        var label: String
        var color: RGB?
        var bold = false
        var note = ""
    }

    private static func writeText(_ context: Context, _ result: ScanResult, _ plan: Plan) {
        let style = context.style
        let tree = plan.tree
        let (branch, lastBranch, pipe, gap) =
            style.unicode ? ("├─ ", "└─ ", "│  ", "   ") : ("|- ", "`- ", "|  ", "   ")

        var rows: [Row] = []
        func walk(_ id: NodeID, level: Int, prefix: String) {
            let selection = plan.select(id, level: level)
            let entries = selection.shown.count + (selection.omittedCount > 0 ? 1 : 0)
            for (index, child) in selection.shown.enumerated() {
                let last = index == entries - 1
                let isDirectory = tree.isDirectory(child)
                rows.append(
                    Row(
                        size: plan.metric(child), prefix: prefix + (last ? lastBranch : branch),
                        label: Text.sanitized(tree.name(of: child)) + (isDirectory ? "/" : ""),
                        color: Report.color(tree, child, style), bold: isDirectory,
                        note: Report.annotation(tree, child).map { "  (\($0))" } ?? ""))
                if plan.descends(into: child, level: level) {
                    walk(child, level: level + 1, prefix: prefix + (last ? gap : pipe))
                }
            }
            if selection.omittedCount > 0 {
                rows.append(
                    Row(
                        size: context.options.logical ? selection.omittedLogical : selection.omittedAllocated,
                        prefix: prefix + lastBranch,
                        label: style.ellipsis + " " + Format.count(selection.omittedCount) + " more"))
            }
        }
        if plan.depth > 0 { walk(tree.root, level: 1, prefix: "") }

        Report.partialBanner(context, result)
        let total = plan.metric(tree.root)
        let header =
            style.bold(Report.title(result)) + "  "
            + Format.bytes(total) + (context.options.logical ? " logical" : "")
        context.out.line(header)
        if plan.depth > 0, rows.isEmpty { context.out.line(style.dim("(empty)")) }

        let sizes = rows.map { Format.bytes($0.size) }
        let sizeWidth = sizes.map(Text.width).max() ?? 0
        let barWidth = Report.barWidth(columns: context.columns)
        for (index, row) in rows.enumerated() {
            let fraction = total > 0 ? Double(row.size) / Double(total) : 0
            var line = Text.padded(sizes[index], to: sizeWidth, right: true) + "  "
            var used = sizeWidth + 2
            if barWidth > 0 {
                let bar = style.bar(fraction, width: barWidth)
                line += style.paint(bar.filled, row.color ?? style.folderColor) + bar.rest + " "
                used += barWidth + 1
            }
            line += Text.padded(Format.percent(fraction), to: 6, right: true) + "  "
            used += 8 + Text.width(row.prefix)
            var label = row.label
            var note = row.note
            if let columns = context.columns {
                let room = max(columns - used, 6)
                if Text.width(label) + Text.width(note) > room { note = "" }
                label = Text.truncated(label, to: room, cut: .middle, ellipsis: style.ellipsis)
            }
            line += style.dim(row.prefix)
            line += row.color == nil ? style.dim(label) : style.paint(label, row.color, bold: row.bold)
            line += style.dim(note)
            context.out.line(line)
        }
        Report.summary(context, result)
    }

    // MARK: JSON

    private static func writeJSON(_ context: Context, _ result: ScanResult, _ plan: Plan) {
        let json = JSONWriter(context.out, pretty: true)
        let tree = plan.tree
        Report.beginEnvelope(json, command: .scan, result: result)
        json.field("sortedBy", context.options.logical ? "logicalBytes" : "allocatedBytes")

        func node(_ id: NodeID, level: Int, path: String) {
            json.beginObject()
            Report.nodeFields(json, tree, id, path: path)
            // level is this node's depth; its children are at level + 1.
            if id == tree.root ? plan.depth > 0 : plan.descends(into: id, level: level) {
                let selection = plan.select(id, level: level + 1)
                json.key("children")
                json.beginArray()
                for child in selection.shown {
                    node(child, level: level + 1, path: path == "/" ? "/" + tree.name(of: child) : path + "/" + tree.name(of: child))
                }
                json.endArray()
                json.key("omitted")
                json.beginObject()
                json.field("count", selection.omittedCount)
                json.field("allocatedBytes", selection.omittedAllocated)
                json.field("logicalBytes", selection.omittedLogical)
                json.endObject()
            }
            json.endObject()
        }
        json.key("tree")
        node(tree.root, level: 0, path: tree.rootPath)
        json.endObject()
        json.finish()
    }
}

// MARK: - top

/// The largest individual files.
enum TopCommand {
    static func run(_ context: Context) throws -> Int32 {
        let result = try Report.scan(context)
        let tree = result.tree
        let nodes = tree.largestFiles(limit: context.options.limit ?? 25, packagesAsFiles: context.options.packages)

        if context.options.json {
            let json = JSONWriter(context.out, pretty: true)
            Report.beginEnvelope(json, command: .top, result: result)
            json.key("files")
            json.beginArray()
            for id in nodes {
                json.beginObject()
                Report.nodeFields(json, tree, id, path: tree.path(of: id))
                json.endObject()
            }
            json.endArray()
            json.endObject()
            json.finish()
        } else {
            let style = context.style
            Report.partialBanner(context, result)
            let what = context.options.packages ? "files and packages" : "files"
            context.out.line(
                style.bold("Largest \(what) in " + Report.title(result)) + "  " + Format.bytes(tree.size(of: tree.root)))
            if nodes.isEmpty { context.out.line(style.dim("(no files)")) }
            Report.list(context, tree, nodes)
            Report.summary(context, result)
        }
        return Report.status(for: result)
    }
}

// MARK: - kinds

/// Usage by category and by file extension.
enum KindsCommand {
    static func run(_ context: Context) throws -> Int32 {
        let result = try Report.scan(context)
        let tree = result.tree
        let logical = context.options.logical
        let categories = tree.categorySummary().sorted {
            let (a, b) = logical ? ($0.logicalSize, $1.logicalSize) : ($0.size, $1.size)
            return a != b ? a > b : $0.category.rawValue < $1.category.rawValue
        }
        let allKinds = tree.kindSummary().sorted {
            let (a, b) = logical ? ($0.logicalSize, $1.logicalSize) : ($0.size, $1.size)
            return a != b ? a > b : $0.ext < $1.ext
        }

        if context.options.json {
            // JSON lists every extension unless -n asks for fewer.
            let kinds = context.options.limit.map { Array(allKinds.prefix($0)) } ?? allKinds
            let json = JSONWriter(context.out, pretty: true)
            Report.beginEnvelope(json, command: .kinds, result: result)
            json.field("sortedBy", logical ? "logicalBytes" : "allocatedBytes")
            json.key("categories")
            json.beginArray()
            for stat in categories {
                json.beginObject()
                json.field("category", ArgumentParser.categoryName(stat.category))
                json.field("name", stat.category.displayName)
                json.field("allocatedBytes", stat.size)
                json.field("logicalBytes", stat.logicalSize)
                json.field("files", stat.fileCount)
                json.endObject()
            }
            json.endArray()
            json.field("totalKinds", allKinds.count)
            json.key("kinds")
            json.beginArray()
            for stat in kinds {
                json.beginObject()
                // The pseudo-kind of extensionless executables is not an extension: it has an
                // empty one and is told apart from "no extension" by its name.
                json.field("extension", stat.isUnixExecutable ? "" : stat.ext)
                json.field("name", stat.ext.isEmpty ? "" : stat.displayName)
                json.field("category", ArgumentParser.categoryName(stat.category))
                json.field("allocatedBytes", stat.size)
                json.field("logicalBytes", stat.logicalSize)
                json.field("files", stat.fileCount)
                json.endObject()
            }
            json.endArray()
            json.endObject()
            json.finish()
            return Report.status(for: result)
        }

        let style = context.style
        let total = logical ? tree.logicalSize(of: tree.root) : tree.size(of: tree.root)
        let kinds = Array(allKinds.prefix(context.options.limit ?? 15))
        let barWidth = Report.barWidth(columns: context.columns)

        struct Line {
            var name: String
            var detail: String
            var size: UInt64
            var files: Int
            var color: RGB
        }
        func table(_ lines: [Line]) {
            let sizes = lines.map { Format.bytes($0.size) }
            let counts = lines.map { Format.files($0.files) }
            let nameWidth = lines.map { Text.width($0.name) }.max() ?? 0
            let detailWidth = lines.map { Text.width($0.detail) }.max() ?? 0
            let sizeWidth = sizes.map(Text.width).max() ?? 0
            let countWidth = counts.map(Text.width).max() ?? 0
            for (index, line) in lines.enumerated() {
                let fraction = total > 0 ? Double(line.size) / Double(total) : 0
                var text = "  " + style.paint(Text.padded(line.name, to: nameWidth), line.color, bold: true) + "  "
                if detailWidth > 0 { text += style.dim(Text.padded(line.detail, to: detailWidth)) + "  " }
                text += Text.padded(sizes[index], to: sizeWidth, right: true) + "  "
                if barWidth > 0 {
                    let bar = style.bar(fraction, width: barWidth)
                    text += style.paint(bar.filled, line.color) + bar.rest + " "
                }
                text += Text.padded(Format.percent(fraction), to: 6, right: true) + "  "
                text += style.dim(Text.padded(counts[index], to: countWidth, right: true))
                context.out.line(text)
            }
        }

        Report.partialBanner(context, result)
        context.out.line(
            style.bold("Usage by kind in " + Report.title(result)) + "  " + Format.bytes(total)
                + (logical ? " logical" : ""))
        if categories.isEmpty {
            context.out.line(style.dim("(no files)"))
        } else {
            context.out.line()
            context.out.line(style.bold("By category"))
            table(
                categories.map {
                    Line(
                        name: $0.category.displayName, detail: "", size: logical ? $0.logicalSize : $0.size,
                        files: $0.fileCount, color: KindPalette.color(for: $0.category, scheme: style.scheme))
                })
            context.out.line()
            let heading =
                kinds.count < allKinds.count
                ? "By extension (top \(kinds.count) of \(Format.count(allKinds.count)))" : "By extension"
            context.out.line(style.bold(heading))
            table(
                kinds.map {
                    Line(
                        name: $0.ext.isEmpty ? "(none)" : $0.displayName, detail: $0.category.displayName,
                        size: logical ? $0.logicalSize : $0.size, files: $0.fileCount,
                        color: KindPalette.color(forExtension: $0.ext, category: $0.category, scheme: style.scheme))
                })
        }
        Report.summary(context, result)
        return Report.status(for: result)
    }
}

// MARK: - find

/// Search by name, size, kind and age.
enum FindCommand {
    static func run(_ context: Context) throws -> Int32 {
        let options = context.options
        let text = options.positionals.count > 1 ? options.positionals[1] : ""
        let hasFilter =
            options.minSize != nil || options.maxSize != nil || !options.kinds.isEmpty || !options.categories.isEmpty
            || options.modifiedBefore != nil || options.modifiedAfter != nil
        guard !text.isEmpty || hasFilter else {
            throw UsageError(
                "'find' needs something to look for: disksurvey find <path> <query>, or a filter such as --min-size, --kind, --older-than")
        }

        let result = try Report.scan(context)
        let tree = result.tree
        var query = SearchQuery(
            text: text, minSize: options.minSize, maxSize: options.maxSize,
            categories: options.categories.isEmpty ? nil : Set(options.categories),
            modifiedAfter: options.modifiedAfter, modifiedBefore: options.modifiedBefore, scope: options.scope)
        if !options.kinds.isEmpty {
            // Extensions that do not occur in the tree simply match nothing.
            query.kinds = Set(options.kinds.compactMap { tree.kindID(forExtension: $0) })
        }
        let found = tree.search(query, limit: options.limit ?? 50)

        if options.json {
            let json = JSONWriter(context.out, pretty: true)
            Report.beginEnvelope(json, command: .find, result: result)
            json.key("query")
            json.beginObject()
            json.field("text", text)
            json.key("minSize")
            if let v = options.minSize { json.value(v) } else { json.null() }
            json.key("maxSize")
            if let v = options.maxSize { json.value(v) } else { json.null() }
            json.field("extensions", strings: options.kinds)
            json.field("categories", strings: options.categories.map(ArgumentParser.categoryName))
            json.key("modifiedBefore")
            if let v = options.modifiedBefore { json.value(Int(v)) } else { json.null() }
            json.key("modifiedAfter")
            if let v = options.modifiedAfter { json.value(Int(v)) } else { json.null() }
            json.field("scope", options.scope == .files ? "files" : options.scope == .directories ? "directories" : "all")
            json.endObject()
            json.field("totalMatches", found.totalMatches)
            json.key("matches")
            json.beginArray()
            for id in found.nodes {
                json.beginObject()
                Report.nodeFields(json, tree, id, path: tree.path(of: id))
                json.endObject()
            }
            json.endArray()
            json.endObject()
            json.finish()
        } else {
            let style = context.style
            Report.partialBanner(context, result)
            var title = Format.counted(found.totalMatches, singular: "match", plural: "matches")
            if !text.isEmpty { title += " for \"" + Text.sanitized(text) + "\"" }
            title += " in " + Report.title(result)
            var line = style.bold(title)
            if found.nodes.count < found.totalMatches {
                line += style.dim("  (the \(Format.count(found.nodes.count)) largest; -n 0 shows all)")
            }
            context.out.line(line)
            Report.list(context, tree, found.nodes)
            Report.summary(context, result)
        }
        return Report.status(for: result)
    }
}

// MARK: - volumes

/// Mounted volumes with capacity bars. Does not scan anything.
enum VolumesCommand {
    static func run(_ context: Context) -> Int32 {
        // The Data half of the startup volume group reports itself as a second, browsable
        // "Macintosh HD"; it is the same disk the "/" row already describes.
        let volumes = VolumeInfo.mounted(includeHidden: context.options.all).filter {
            context.options.all || !$0.id.hasPrefix("/System/Volumes/")
        }
        /// Mount point without the trailing slash that directory URLs carry.
        func mountPoint(_ volume: Volume) -> String {
            let path = volume.id
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }

        if context.options.json {
            let json = JSONWriter(context.out, pretty: true)
            json.beginObject()
            json.field("disksurvey", DiskSurveyVersion.string)
            json.field("schemaVersion", 1)
            json.field("command", "volumes")
            json.key("volumes")
            json.beginArray()
            for volume in volumes {
                json.beginObject()
                json.field("name", volume.name)
                json.field("mountPoint", mountPoint(volume))
                json.field("device", volume.device)
                json.field("fileSystem", volume.fileSystemType)
                json.field("totalBytes", volume.totalCapacity)
                json.field("usedBytes", volume.usedCapacity)
                json.field("availableBytes", volume.availableCapacity)
                json.field("availableForImportantUsageBytes", volume.availableCapacityForImportantUsage)
                json.field("purgeableBytes", volume.purgeableCapacity)
                json.field("usedFraction", volume.usedFraction)
                json.field("startup", volume.isRoot)
                json.field("internal", volume.isInternal)
                json.field("removable", volume.isRemovable)
                json.field("ejectable", volume.isEjectable)
                json.field("network", volume.isNetwork)
                json.field("readOnly", volume.isReadOnly)
                json.field("hidden", !volume.isBrowsable)
                json.endObject()
            }
            json.endArray()
            json.endObject()
            json.finish()
            return ExitCode.success
        }

        let style = context.style
        let columns = context.columns ?? 120
        let barWidth = columns >= 100 ? 20 : columns >= 64 ? 10 : 0
        let names = volumes.map {
            Text.truncated(Text.sanitized($0.name), to: columns >= 100 ? 28 : 18, ellipsis: style.ellipsis)
        }
        let usage = volumes.map { Format.bytes($0.usedCapacity) + " of " + Format.bytes($0.totalCapacity) }
        let free = volumes.map { volume -> String in
            var text = Format.bytes(volume.availableCapacity) + " free"
            // Space macOS would reclaim on demand; worth a mention only when it is noticeable.
            if columns >= 100, volume.purgeableCapacity > volume.totalCapacity / 100 {
                text += " + " + Format.bytes(volume.purgeableCapacity) + " purgeable"
            }
            return text
        }
        let nameWidth = names.map(Text.width).max() ?? 0
        let usageWidth = usage.map(Text.width).max() ?? 0
        let freeWidth = free.map(Text.width).max() ?? 0
        let typeWidth = volumes.map { Text.width($0.fileSystemType) }.max() ?? 0

        if volumes.isEmpty { context.out.line(style.dim("(no volumes)")) }
        for (index, volume) in volumes.enumerated() {
            let fraction = volume.usedFraction
            // Traffic-light colours: the bar is a warning light, not a kind.
            let color =
                fraction >= 0.9
                ? RGB(r: 0.93, g: 0.33, b: 0.31) : fraction >= 0.75 ? RGB(r: 0.92, g: 0.70, b: 0.22) : RGB(r: 0.30, g: 0.76, b: 0.46)
            var line = style.bold(Text.padded(names[index], to: nameWidth)) + "  "
            if barWidth > 0 {
                let bar = style.bar(fraction, width: barWidth, track: true)
                line += style.paint(bar.filled, color) + style.dim(bar.rest) + " "
            }
            line += Text.padded(Format.percent(fraction), to: 6, right: true) + "  "
            line += Text.padded(usage[index], to: usageWidth, right: true) + "  "
            line += style.dim(Text.padded(free[index], to: freeWidth)) + "  "
            if columns >= 90 { line += style.dim(Text.padded(volume.fileSystemType, to: typeWidth)) + "  " }
            line += Text.sanitized(mountPoint(volume))
            context.out.line(line)
        }
        return ExitCode.success
    }
}
