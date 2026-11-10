import AppKit
import SwiftUI
import DiskSurveyCore
import DiskSurveyScan

struct InspectorView: View {
    let model: WindowModel
    let scheme: PaletteScheme
    /// The inspector column's narrowest width, and the width it opens with; the window's
    /// minimum width counts on the latter.
    static let minimumWidth: CGFloat = 260
    static let idealWidth: CGFloat = 300

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Inspector", selection: $model.inspectorTab) {
                ForEach(tabs) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .labelStyle(.titleOnly)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            switch model.inspectorTab {
            case .kinds: KindsTab(model: model, scheme: scheme)
            case .largest: LargestTab(model: model, scheme: scheme)
            case .info: InfoTab(model: model, scheme: scheme)
            case .search: SearchTab(model: model, scheme: scheme)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var tabs: [InspectorTab] {
        model.searchIsActive ? InspectorTab.allCases : [.kinds, .largest, .info]
    }
}

// MARK: - Kinds

/// The legend: how much each kind takes and, when the map is coloured by kind, what its colours
/// mean. Clicking a row lights up those files in the map and narrows the Largest list to them.
struct KindsTab: View {
    let model: WindowModel
    let scheme: PaletteScheme

    private struct Row: Identifiable {
        enum Key: Hashable { case category(KindCategory), kind(KindID) }
        var key: Key
        var title: String
        var symbol: String?
        var color: Color
        var size: UInt64
        var count: Int
        var id: Key { key }
    }

    var body: some View {
        @Bindable var model = model
        let rows = self.rows
        let total = max(1, rows.reduce(0) { $0 + Double($1.size) })
        let largestSize = Double(rows.first?.size ?? 1)
        VStack(spacing: 0) {
            HStack {
                Picker("Group by", selection: $model.kindGrouping) {
                    ForEach(KindGrouping.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if model.kindFilterIsActive {
                    Button("Show All") { model.clearKindFilter() }
                        .controlSize(.small)
                        .help("Stop highlighting the selected kinds")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if model.preferences.colorMode == .age {
                AgeLegend(scheme: scheme)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            if rows.isEmpty {
                EmptyState(symbol: "square.grid.2x2", title: model.phase == .scanning ? "Reading files…" : "No files", detail: nil)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows.prefix(400)) { row in
                            rowView(row, total: total, largest: largestSize)
                        }
                        if rows.count > 400 {
                            Text("…and \(Format.count(rows.count - 400)) more extensions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var rows: [Row] {
        let logical = model.sizeMode == .logical
        switch model.kindGrouping {
        case .category:
            return model.categoryStats.filter { $0.fileCount > 0 }.map {
                Row(
                    key: .category($0.category), title: $0.category.displayName, symbol: $0.category.symbolName,
                    color: KindPalette.color(for: $0.category, scheme: scheme).color, size: logical ? $0.logicalSize : $0.size,
                    count: $0.fileCount)
            }
        case .ext:
            return model.kindStats.map {
                Row(
                    key: .kind($0.kind), title: $0.displayName, symbol: nil,
                    color: KindPalette.color(forExtension: $0.ext, category: $0.category, scheme: scheme).color,
                    size: logical ? $0.logicalSize : $0.size, count: $0.fileCount)
            }
        }
    }

    private func isSelected(_ row: Row) -> Bool {
        switch row.key {
        case .category(let category): model.selectedCategories.contains(category)
        case .kind(let kind): model.selectedKinds.contains(kind)
        }
    }

    private func rowView(_ row: Row, total: Double, largest: Double) -> some View {
        let selected = isSelected(row)
        let dimmed = model.kindFilterIsActive && !selected
        // Coloured by age, the map shows none of the kind hues; swatches in them would be read
        // as a key to the map (purple tiles are a year old, not videos).
        let colorsByKind = model.preferences.colorMode != .age
        return Button {
            let extend = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
            switch row.key {
            case .category(let category): model.toggleCategory(category, extend: extend)
            case .kind(let kind): model.toggleKind(kind, extend: extend)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Group {
                        if colorsByKind {
                            RoundedRectangle(cornerRadius: 3.5)
                                .fill(row.color)
                                .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                        } else {
                            Image(systemName: row.symbol ?? "doc")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 13, height: 13)
                    Text(row.title)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Format.bytes(row.size))
                        .monospacedDigit()
                }
                HStack(spacing: 7) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(.quaternary)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(colorsByKind ? AnyShapeStyle(row.color) : AnyShapeStyle(.secondary))
                                    .frame(width: max(3, geometry.size.width * Double(row.size) / largest))
                            }
                    }
                    .frame(height: 4)
                    Text("\(Format.percent(Double(row.size) / total)) · \(Format.compactCount(row.count))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
            .contentShape(.rect)
            .opacity(dimmed ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(Format.bytes(row.size)), \(Format.files(row.count))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Highlights these files in the map")
    }
}

/// The colour ramp of colour-by-age.
struct AgeLegend: View {
    let scheme: PaletteScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Map colors: last modified")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(AgeBucket.allCases.filter { $0 != .unknown }, id: \.rawValue) { bucket in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(AgePalette.color(for: bucket, scheme: scheme).color)
                            .frame(height: 8)
                        Text(Self.short(bucket))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .help(bucket.displayName)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map colors show the time since last modification, from one day to more than two years")
    }

    private static func short(_ bucket: AgeBucket) -> String {
        switch bucket {
        case .day: "1d"
        case .week: "1w"
        case .month: "1m"
        case .quarter: "3m"
        case .year: "1y"
        case .twoYears: "2y"
        case .older: "2y+"
        case .unknown: "?"
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - File lists (largest, search)

struct FileRowList: View {
    let model: WindowModel
    let rows: [FileRow]
    let scheme: PaletteScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }

    private func rowView(_ row: FileRow) -> some View {
        let selected = row.epoch == model.idEpoch && model.selection.contains(row.node)
        return Button {
            model.reveal(row)
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: IconCache.shared.icon(forExtension: row.ext, isDirectory: row.isDirectory, customIconPath: row.iconPath))
                    .resizable()
                    .frame(width: 20, height: 20)
                    .overlay(alignment: .bottomTrailing) {
                        if !row.isDirectory {
                            Circle()
                                .fill(KindPalette.color(forExtension: row.ext, category: row.category, scheme: scheme).color)
                                .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                                .frame(width: 8, height: 8)
                                .offset(x: 2, y: 1)
                        }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 6)
                Text(Format.bytes(row.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") { model.act(on: row) { $0.revealInFinder() } }
            Button("Quick Look") { model.act(on: row) { $0.toggleQuickLook() } }
            Button("Copy Path") { model.act(on: row) { $0.copyPaths() } }
            Divider()
            Button("Move to Trash…") { model.act(on: row) { $0.requestTrash() } }
        }
        .help("\(row.location)/\(row.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(Format.bytes(row.size)), in \(row.location)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct LargestTab: View {
    let model: WindowModel
    let scheme: PaletteScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(header)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if model.kindFilterIsActive {
                    Button("Show All") { model.clearKindFilter() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if model.largest.isEmpty {
                EmptyState(symbol: "chart.bar.xaxis", title: model.phase == .scanning ? "Reading files…" : "No files", detail: nil)
            } else {
                FileRowList(model: model, rows: model.largest, scheme: scheme)
            }
        }
    }

    private var header: String {
        guard let tree = model.tree, Int(model.rootNode) < tree.count else { return "" }
        let place = model.rootNode == tree.root ? model.title : tree.name(of: model.rootNode)
        let what = model.kindFilterIsActive ? "Largest of the highlighted kinds" : "Largest files"
        return "\(what) in “\(place)”"
    }
}

struct SearchTab: View {
    let model: WindowModel
    let scheme: PaletteScheme

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if model.isSearching { ProgressView().controlSize(.small) }
                    Text(header)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                FlowLayout(spacing: 5) {
                    ForEach(SearchToken.sizes + SearchToken.ages) { token in chip(token) }
                    Menu {
                        ForEach(SearchToken.kinds) { token in
                            Toggle(isOn: Binding(get: { model.searchTokens.contains(token) }, set: { _ in model.toggleToken(token) })) {
                                Label(token.title, systemImage: token.symbol)
                            }
                        }
                    } label: {
                        Text("Kind")
                            .font(.caption)
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if model.searchRows.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass", title: model.isSearching ? "Searching…" : "No matches",
                    detail: model.isSearching ? nil : "Nothing in the folder shown in the map matches.")
            } else {
                FileRowList(model: model, rows: model.searchRows, scheme: scheme)
            }
        }
    }

    private var header: String {
        guard model.searchTotalMatches > 0 else { return model.isSearching ? "Searching…" : "No matches" }
        let shown = model.searchRows.count < model.searchTotalMatches ? " · largest \(model.searchRows.count) listed" : ""
        return "\(Format.counted(model.searchTotalMatches, singular: "match", plural: "matches")) · \(Format.bytes(model.searchTotalSize))\(shown)"
    }

    private func chip(_ token: SearchToken) -> some View {
        let active = model.searchTokens.contains(token)
        return Button {
            model.toggleToken(token)
        } label: {
            Text(token.title)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .capsule)
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// Lays children out in rows, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

// MARK: - Info

struct InfoTab: View {
    let model: WindowModel
    let scheme: PaletteScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let tree = model.tree {
                    let nodes = model.topLevelSelection()
                    if nodes.count == 1 {
                        single(tree: tree, node: nodes[0])
                    } else if nodes.count > 1 {
                        multiple(tree: tree, nodes: nodes)
                    } else {
                        overview(tree: tree)
                    }
                } else {
                    EmptyState(symbol: "info.circle", title: "Scanning…", detail: nil)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // One item.
    @ViewBuilder private func single(tree: FileTree, node: NodeID) -> some View {
        let flags = tree.flags(of: node)
        let path = tree.path(of: node)
        let isDirectory = tree.isDirectory(node)
        HStack(spacing: 12) {
            Image(nsImage: IconCache.shared.icon(for: tree, node: node))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(node == tree.root ? model.title : tree.name(of: node))
                    .font(.headline)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(kindDescription(tree: tree, node: node))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        pathBlock(path)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            fact("On disk", Format.bytes(tree.size(of: node)), detail: Format.exactBytes(tree.size(of: node)))
            fact("Logical", Format.bytes(tree.logicalSize(of: node)), detail: Format.exactBytes(tree.logicalSize(of: node)))
            if let parent = tree.parent(of: node) {
                fact("Share", "\(Format.percent(model.size(of: node, in: tree), of: model.size(of: parent, in: tree))) of “\(tree.name(of: parent))”")
                fact("Of scan", Format.percent(model.size(of: node, in: tree), of: model.size(of: tree.root, in: tree)))
            }
            if isDirectory {
                fact("Contains", "\(Format.files(tree.fileCount(of: node))), \(Format.items(tree.childCount(of: node))) at top level")
            }
            fact("Modified", Format.date(tree.modified(of: node), includingTime: true), detail: Format.relativeDate(tree.modified(of: node)))
        }
        let notes = Self.notes(for: flags)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.text) { note in
                    Label(note.text, systemImage: note.symbol)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Divider()
        actions(zoomable: isDirectory && node != model.rootNode && tree.childCount(of: node) > 0, node: node)
    }

    @ViewBuilder private func multiple(tree: FileTree, nodes: [NodeID]) -> some View {
        let allocated = nodes.reduce(UInt64(0)) { $0 &+ tree.size(of: $1) }
        let logical = nodes.reduce(UInt64(0)) { $0 &+ tree.logicalSize(of: $1) }
        let files = nodes.reduce(0) { $0 + tree.fileCount(of: $1) }
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.items(nodes.count)) selected").font(.headline)
                Text(Format.files(files)).font(.callout).foregroundStyle(.secondary)
            }
        }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            fact("On disk", Format.bytes(allocated), detail: Format.exactBytes(allocated))
            fact("Logical", Format.bytes(logical), detail: Format.exactBytes(logical))
            fact("Of scan", Format.percent(model.sizeMode == .allocated ? allocated : logical, of: model.size(of: tree.root, in: tree)))
        }
        Divider()
        actions(zoomable: false, node: nodes[0])
    }

    /// Nothing selected: the scan as a whole.
    @ViewBuilder private func overview(tree: FileTree) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: IconCache.shared.icon(for: tree, node: tree.root))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline)
                Text(model.phase == .scanning ? "Scanning…" : "Scanned location")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        pathBlock(model.scanRoot?.path ?? tree.rootPath)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            fact("On disk", Format.bytes(tree.size(of: tree.root)), detail: Format.exactBytes(tree.size(of: tree.root)))
            fact("Logical", Format.bytes(tree.logicalSize(of: tree.root)), detail: Format.exactBytes(tree.logicalSize(of: tree.root)))
            fact("Files", Format.count(tree.fileCount(of: tree.root)))
            if let summary = model.summary {
                if summary.stats.directories > 0 { fact("Folders", Format.count(Int(summary.stats.directories))) }
                fact("Scanned", "\(Format.relativeDate(Int64(summary.date.timeIntervalSince1970))) in \(Format.duration(summary.duration))")
                if summary.stats.entriesPerSecond > 0 {
                    fact("Speed", "\(Format.compactCount(Int(summary.stats.entriesPerSecond))) items/s on \(summary.stats.threadCount) threads")
                }
                if summary.stats.hardLinkDuplicates > 0 {
                    fact("Hard links", "\(Format.count(Int(summary.stats.hardLinkDuplicates))) counted once")
                }
                if summary.stats.datalessEntries > 0 {
                    fact("Cloud-only", "\(Format.count(Int(summary.stats.datalessEntries))) items not downloaded")
                }
                if summary.totalIssueCount > 0 {
                    fact("Unreadable", Format.counted(summary.totalIssueCount, singular: "folder", plural: "folders"))
                }
            }
        }
        if let volume = model.rootVolume, model.phase == .loaded, model.preferences.showHiddenSpace {
            Divider()
            let breakdown = VolumeBreakdown(volume: volume, model: model)
            VStack(alignment: .leading, spacing: 8) {
                Text("Volume capacity").font(.subheadline).fontWeight(.semibold)
                CapacityBar(segments: breakdown.segments).frame(height: 8)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    fact("Total", Format.bytes(volume.totalCapacity))
                    fact("In the map", Format.bytes(breakdown.scanned))
                    fact("Not visible", Format.bytes(breakdown.hidden))
                    fact("Purgeable", Format.bytes(breakdown.purgeable))
                    fact("Free", Format.bytes(breakdown.free))
                }
                Text("“Not visible” covers local snapshots, system-protected data and folders Disk Survey may not read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Text("Select an item in the map or the outline to see its details.")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pathBlock(_ path: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
                model.show(ToastMessage(symbol: "doc.on.doc", text: "Path copied"), duration: 2)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the path")
            .accessibilityLabel("Copy path")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder private func fact(_ label: String, _ value: String, detail: String? = nil) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }

    private func actions(zoomable: Bool, node: NodeID) -> some View {
        FlowLayout(spacing: 6) {
            if zoomable {
                Button { model.zoom(to: node) } label: { Label("Zoom In", systemImage: "arrow.down.right.and.arrow.up.left") }
            }
            Button { model.revealInFinder() } label: { Label("Reveal", systemImage: "folder") }
            Button { model.toggleQuickLook() } label: { Label("Quick Look", systemImage: "eye") }
            Button { model.openSelection() } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Button { model.copyPaths() } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            Button(role: .destructive) { model.requestTrash() } label: { Label("Trash…", systemImage: "trash") }
                .disabled(!model.canTrash)
        }
        .controlSize(.small)
        .disabled(model.locationMissing)
    }

    private func kindDescription(tree: FileTree, node: NodeID) -> String {
        tree.kindDescription(of: node)
    }

    private static func notes(for flags: NodeFlags) -> [(symbol: String, text: String)] {
        var notes: [(String, String)] = []
        if flags.contains(.unreadable) { notes.append(("lock.fill", "Disk Survey has no permission to read this folder, so its contents are not counted.")) }
        if flags.contains(.dataless) { notes.append(("icloud", "Stored in the cloud. It takes no space on this disk until it is downloaded.")) }
        if flags.contains(.hardLinkDuplicate) { notes.append(("link", "A hard link to a file already counted elsewhere, so it counts as zero here.")) }
        if flags.contains(.mountPoint) { notes.append(("externaldrive", "Another volume is mounted here. It is protected from Move to Trash.")) }
        if flags.contains(.synthetic) { notes.append(("questionmark.square.dashed", "A placeholder entry, not a real file.")) }
        return notes
    }
}
