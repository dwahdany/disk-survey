import Foundation
import DiskSurveyCore

/// How directories are set apart from their surroundings.
///
/// All lengths are in pixels (multiply point values by the backing scale factor) and should be
/// whole numbers so frame edges stay crisp.
public struct TreemapStyle: Sendable, Hashable {
    /// Inset on the left, right and bottom (and top, when there is no header) between a
    /// directory's rectangle and its contents. Two sibling directories end up `2 * padding` apart.
    public var padding: Float
    /// Directories at depth `< paddingDepth` are padded (the layout root has depth 0).
    public var paddingDepth: Int
    /// Height of the title strip reserved at the top of a directory, or 0 for none.
    public var header: Float
    /// Directories at depth `< headerDepth` get a header.
    public var headerDepth: Int
    /// A directory narrower than this gets no header (a name would not fit anyway).
    public var minHeaderWidth: Float
    /// A directory shorter than this gets no header (it would eat most of the cell).
    public var minHeaderHeight: Float
    /// Whether the layout root itself is framed. Usually `false`: the view already shows the
    /// root's name in its breadcrumb bar.
    public var framesRoot: Bool

    /// Frame metrics of one nesting level, for styles whose frames change with depth.
    public struct Level: Sendable, Hashable {
        /// Height of the title strip (0 for none).
        public var header: Float
        /// Inset between the directory's rectangle and its contents.
        public var padding: Float
        /// A directory narrower or shorter than this gets no header.
        public var minHeaderWidth: Float
        public var minHeaderHeight: Float
        /// Whether a directory too small for a header is still set apart by its padding. Off for
        /// the deep levels of an adaptive style: there a folder is framed completely or not at
        /// all, so the long tail of small folders costs no space and adds no lines.
        public var padsWithoutHeader: Bool

        public init(
            header: Float, padding: Float, minHeaderWidth: Float, minHeaderHeight: Float, padsWithoutHeader: Bool = true
        ) {
            self.header = header
            self.padding = padding
            self.minHeaderWidth = minHeaderWidth
            self.minHeaderHeight = minHeaderHeight
            self.padsWithoutHeader = padsWithoutHeader
        }
    }

    /// Frame metrics by nesting level: element 0 is for a frame that lies in no other frame,
    /// element 1 for a frame inside one other frame, …; the last element repeats. Empty (the
    /// default) means every level uses ``header``, ``padding``, ``minHeaderWidth`` and
    /// ``minHeaderHeight``.
    ///
    /// The level counts *frames*, not folders (``TreemapCell/frameLevel``): a folder that got
    /// no frame of its own does not use one up.
    public var levels: [Level] = []

    /// At most this many frames nest inside one another, whatever the depth of the folders.
    public var maxNestedFrames: Int = .max

    /// The frame metrics of a directory with `frameLevel` framed ancestors.
    @inlinable public func level(at frameLevel: Int) -> Level {
        if levels.isEmpty {
            return Level(header: header, padding: padding, minHeaderWidth: minHeaderWidth, minHeaderHeight: minHeaderHeight)
        }
        return levels[min(levels.count - 1, max(0, frameLevel))]
    }

    public init(
        padding: Float = 0, paddingDepth: Int = 0, header: Float = 0, headerDepth: Int = 0,
        minHeaderWidth: Float = 0, minHeaderHeight: Float = 0, framesRoot: Bool = false
    ) {
        self.padding = padding
        self.paddingDepth = paddingDepth
        self.header = header
        self.headerDepth = headerDepth
        self.minHeaderWidth = minHeaderWidth
        self.minHeaderHeight = minHeaderHeight
        self.framesRoot = framesRoot
    }

    /// Pure cushion treemap: no insets at all, structure is conveyed by shading alone.
    public static let cushion = TreemapStyle()

    /// Cushions with thin dark gutters around the directories of the first `depth` levels.
    public static func grouped(scale: Float = 1, depth: Int = 2) -> TreemapStyle {
        TreemapStyle(padding: max(1, (scale * 0.5).rounded()), paddingDepth: depth + 1)
    }

    /// Nested frames: the directories of the first `depth` levels get a title strip and a
    /// border, so the hierarchy can be read (and labelled) directly on the map.
    public static func framed(scale: Float = 1, depth: Int = 2) -> TreemapStyle {
        TreemapStyle(
            padding: max(1, scale.rounded()), paddingDepth: depth + 1,
            header: (15 * scale).rounded(), headerDepth: depth + 1,
            minHeaderWidth: (44 * scale).rounded(), minHeaderHeight: (36 * scale).rounded())
    }

    /// Size-adaptive nested frames: a directory at *any* depth gets a title strip and a border
    /// whenever its cell is large enough to carry them legibly. Frames inside frames get
    /// slimmer strips, and below the first two levels a folder too small for a title gets no
    /// frame at all — so the big folders inside big folders are named on the map while the long
    /// tail of small ones costs neither space nor clutter.
    ///
    /// `maxLevels` caps how many frames can nest (frames, not folder levels: a folder without a
    /// frame of its own does not count).
    public static func adaptive(scale: Float = 1, maxLevels: Int = 10) -> TreemapStyle {
        func px(_ points: Float) -> Float { max(1, (points * scale).rounded()) }
        let levels = [
            Level(header: px(17), padding: px(1.5), minHeaderWidth: px(44), minHeaderHeight: px(36)),
            Level(header: px(15), padding: px(1), minHeaderWidth: px(46), minHeaderHeight: px(36)),
            Level(header: px(13), padding: px(1), minHeaderWidth: px(50), minHeaderHeight: px(40), padsWithoutHeader: false),
            Level(header: px(12), padding: px(1), minHeaderWidth: px(54), minHeaderHeight: px(40), padsWithoutHeader: false),
        ]
        var style = TreemapStyle(
            padding: levels[0].padding, paddingDepth: .max, header: levels[0].header, headerDepth: .max,
            minHeaderWidth: levels[0].minHeaderWidth, minHeaderHeight: levels[0].minHeaderHeight)
        style.levels = levels
        style.maxNestedFrames = maxLevels
        return style
    }
}

/// Parameters of a layout pass.
public struct TreemapLayoutOptions: Sendable, Hashable {
    public enum SizeMetric: Sendable, Hashable {
        /// Physical (allocated) size — the default, and the fast path: the tree keeps children
        /// sorted by it.
        case allocated
        /// Logical (end-of-file) size. Children are re-sorted per visited directory.
        case logical
    }

    public var sizeMetric: SizeMetric
    /// Level of detail: a directory whose contents would be narrower or shorter than this many
    /// pixels is drawn as one leaf cell instead of being subdivided.
    public var minCellSide: Float
    /// Level of detail: siblings that would cover fewer than this many square pixels are merged
    /// into one aggregated "small items" cell.
    public var minCellArea: Float
    public var style: TreemapStyle
    /// Height of the first-level cushion ridges relative to their width (van Wijk's `h`).
    public var cushionHeight: Float
    /// Factor by which the ridge height shrinks per nesting level (van Wijk's `f`).
    public var cushionFalloff: Float
    /// Minimum ridge height of the tiles themselves, whatever their depth. In the classic
    /// algorithm deeply nested files end up almost flat; a floor keeps every tile a visible
    /// little pillow while the (decaying) ancestor ridges still shape the big picture.
    public var tileHeight: Float
    /// Draw packages (`.app`, `.photoslibrary`, …) as single cells, as Finder shows them.
    public var packagesAsLeaves: Bool
    /// Deepest level to subdivide, relative to the layout root (which is depth 0). A directory
    /// at this depth is drawn as one tile (``TreemapCell/isCollapsed``).
    public var maxDepth: Int

    /// Which file stands for a folder collapsed by ``maxDepth`` when the tile is coloured.
    public enum CollapsedSample: Sendable, Hashable {
        /// The largest file found by following the largest child (no extra work).
        case largestFile
        /// The largest file of the kind category that takes the most space in the folder, so
        /// the block has the colour most of its contents would have. Costs one walk over the
        /// collapsed subtrees.
        case dominantKind
        /// The largest file of the age class (``AgeBucket``, relative to `now` in epoch
        /// seconds) that takes the most space.
        case dominantAge(now: Int64)
    }
    public var collapsedSample: CollapsedSample = .largestFile

    public init(
        sizeMetric: SizeMetric = .allocated, minCellSide: Float = 3, minCellArea: Float = 6,
        style: TreemapStyle = .cushion, cushionHeight: Float = 0.34, cushionFalloff: Float = 0.75,
        tileHeight: Float = 0.30,         packagesAsLeaves: Bool = false, maxDepth: Int = .max
    ) {
        self.sizeMetric = sizeMetric
        self.minCellSide = minCellSide
        self.minCellArea = minCellArea
        self.style = style
        self.cushionHeight = cushionHeight
        self.cushionFalloff = cushionFalloff
        self.tileHeight = tileHeight
        self.packagesAsLeaves = packagesAsLeaves
        self.maxDepth = maxDepth
    }
}

/// Accumulated cushion surface of a cell: `z(x, y) = ax·x² + bx·x + ay·y² + by·y` in layout
/// coordinates (van Wijk & van de Wetering, "Cushion Treemaps"). Every nesting level adds one
/// parabolic ridge per axis, so a cell's surface is the sum of its own bump and its ancestors'.
public struct CushionSurface: Sendable, Hashable {
    public var ax: Float
    public var bx: Float
    public var ay: Float
    public var by: Float

    public static let flat = CushionSurface(ax: 0, bx: 0, ay: 0, by: 0)

    @inlinable public init(ax: Float, bx: Float, ay: Float, by: Float) {
        self.ax = ax
        self.bx = bx
        self.ay = ay
        self.by = by
    }

    /// Adds a ridge spanning `rect` whose peak is `height` times the rect's extent on each axis.
    @inlinable mutating func addRidge(over rect: TreemapRect, height: Float) {
        let w = rect.maxX - rect.minX
        if w > 0 {
            bx += 4 * height * (rect.maxX + rect.minX) / w
            ax -= 4 * height / w
        }
        let h = rect.maxY - rect.minY
        if h > 0 {
            by += 4 * height * (rect.maxY + rect.minY) / h
            ay -= 4 * height / h
        }
    }

    /// Surface slope (∂z/∂x, ∂z/∂y) at a point.
    @inlinable public func slope(at p: TreemapPoint) -> (dx: Float, dy: Float) {
        (2 * ax * p.x + bx, 2 * ay * p.y + by)
    }
}

/// One rectangle of a ``TreemapLayout``.
public struct TreemapCell: Sendable, Hashable {
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        @inlinable public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// Drawn as a single tile at this level of detail (a file, or a directory too small —
        /// or too deep, or a package — to subdivide).
        public static let leaf = Flags(rawValue: 1 << 0)
        /// Stands for all the siblings too small to draw individually. Always a leaf.
        public static let aggregate = Flags(rawValue: 1 << 1)
        /// `node` is a directory.
        public static let directory = Flags(rawValue: 1 << 2)
        /// The cell reserves a title strip at its top (see ``TreemapLayout/headerRect(ofCell:)``).
        public static let header = Flags(rawValue: 1 << 3)
        /// The cell's contents are inset by the style's padding.
        public static let padded = Flags(rawValue: 1 << 4)
        /// A directory with contents that is drawn as one tile because it lies at the layout's
        /// depth limit (``TreemapLayoutOptions/maxDepth``) — not because it is too small.
        /// Always a leaf.
        public static let collapsed = Flags(rawValue: 1 << 5)
    }

    public var rect: TreemapRect
    public var surface: CushionSurface
    /// The node this cell shows. For an aggregate: the directory whose small children it merges.
    public var node: NodeID
    /// A representative file for colouring: the node itself for files, otherwise the largest
    /// file found by following the largest child downwards (for aggregates: starting at the
    /// largest merged child).
    public var sample: NodeID
    /// Index of the parent cell, or -1 for the root cell.
    public var parent: Int32
    /// Index of the first child cell; children are contiguous. For aggregates: the position in
    /// `tree.children(of: node)` where the merged run starts, or -1 if it is not a contiguous run.
    public var firstChild: Int32
    /// Number of child cells. For aggregates: the number of merged siblings.
    public var childCount: Int32
    /// Nesting level below the layout root (root cell: 0).
    public var depth: UInt16
    public var flags: Flags
    /// Number of ancestors that have a frame (``isFramed``). For a framed cell this is its own
    /// nesting level, which selects its metrics (``TreemapStyle/level(at:)``) and its tint.
    public var frameLevel: UInt8 = 0

    @inlinable public var isLeaf: Bool { flags.contains(.leaf) }
    @inlinable public var isAggregate: Bool { flags.contains(.aggregate) }
    @inlinable public var isDirectory: Bool { flags.contains(.directory) }
    @inlinable public var hasHeader: Bool { flags.contains(.header) }
    /// A folder shown as a single tile by the depth limit.
    @inlinable public var isCollapsed: Bool { flags.contains(.collapsed) }
    /// Whether the cell has a frame of its own (a header, padding, or both).
    @inlinable public var isFramed: Bool { !flags.isDisjoint(with: [.header, .padded]) }
    /// Number of siblings merged into an aggregate cell (0 for other cells). Includes
    /// zero-sized siblings.
    @inlinable public var mergedCount: Int { isAggregate ? Int(childCount) : 0 }
    /// Range of child cell indices (empty for leaves).
    @inlinable public var children: Range<Int> {
        isLeaf ? 0 ..< 0 : Int(firstChild) ..< Int(firstChild) + Int(childCount)
    }
}

/// A squarified treemap (Bruls, Huizing & van Wijk) of one subtree, pruned to what is visible
/// at the target resolution.
///
/// The cost of building a layout depends on the number of *pixels*, not the number of nodes:
/// directories whose cell is too small are not descended into, and the long tail of tiny
/// siblings in a directory is merged into a single aggregate cell without being visited.
///
/// `cells` is a flat array in breadth-first order (large maps: breadth-first at the top, then
/// one breadth-first block per subtree that was laid out on another core). That gives three
/// properties the rest of the module relies on: a parent always precedes its children, the
/// children of a cell are contiguous (`cell.children`), and the order is deterministic.
///
/// The leaf cells, together with the frames (padding and headers) of framed directories, tile
/// `bounds` exactly.
public struct TreemapLayout: Sendable {
    /// The tree the layout was computed from (a cheap copy-on-write reference).
    public let tree: FileTree
    /// The node shown as the whole map.
    public let root: NodeID
    public let bounds: TreemapRect
    public let options: TreemapLayoutOptions
    /// All cells, breadth-first; `cells[0]` is the root cell.
    public let cells: ContiguousArray<TreemapCell>

    /// Lays out the subtree under `root` into `bounds`.
    ///
    /// `root` should be a live node; a removed, empty or zero-sized root gives a layout with a
    /// single leaf cell covering `bounds`.
    ///
    /// `sampleCache` remembers the colour samples of folders collapsed by the depth limit
    /// between layouts of the same tree (see ``CollapsedSampleCache``).
    public init(
        tree: FileTree, root: NodeID = 0, bounds: TreemapRect,
        options: TreemapLayoutOptions = TreemapLayoutOptions(), sampleCache: CollapsedSampleCache? = nil
    ) {
        self.init(tree: tree, root: root, bounds: bounds, options: options, allowParallel: true, sampleCache: sampleCache)
    }

    /// `allowParallel: false` forces the single-threaded path (tests compare the two).
    init(
        tree: FileTree, root: NodeID, bounds: TreemapRect, options: TreemapLayoutOptions, allowParallel: Bool,
        sampleCache: CollapsedSampleCache? = nil
    ) {
        self.tree = tree
        self.root = root
        self.bounds = bounds
        self.options = options
        var builder = LayoutBuilder(options: options)
        builder.allowParallel = allowParallel
        builder.sampleCache = sampleCache
        self.cells = builder.build(tree, root: root, bounds: bounds)
    }

    /// A layout of the same tree and options for another root (zoom in or out) or size.
    public func relayout(root: NodeID? = nil, bounds: TreemapRect? = nil) -> TreemapLayout {
        TreemapLayout(tree: tree, root: root ?? self.root, bounds: bounds ?? self.bounds, options: options)
    }

    /// Whether this layout still describes `tree` (same storage generation and root path).
    /// A layout made from a scan snapshot is never current for the next snapshot: node ids change.
    public func isCurrent(for other: FileTree) -> Bool {
        tree.revision == other.revision && tree.count == other.count && tree.rootPath == other.rootPath
    }

    /// The area inside a directory cell where its children are laid out: the cell's rectangle
    /// minus header and padding. Equals `rect` for unframed cells.
    public func contentRect(ofCell index: Int) -> TreemapRect {
        let cell = cells[index]
        return options.style.contentRect(of: cell.rect, flags: cell.flags, level: Int(cell.frameLevel))
    }

    /// The title strip of a cell with a header (`nil` otherwise), full width of the cell.
    public func headerRect(ofCell index: Int) -> TreemapRect? {
        let cell = cells[index]
        guard cell.hasHeader else { return nil }
        return TreemapRect(
            minX: cell.rect.minX, minY: cell.rect.minY, maxX: cell.rect.maxX,
            maxY: min(cell.rect.maxY, cell.rect.minY + options.style.level(at: Int(cell.frameLevel)).header))
    }

    /// Number of leaf cells (the tiles actually painted).
    public var leafCount: Int { cells.reduce(0) { $0 + ($1.isLeaf ? 1 : 0) } }
}

extension TreemapStyle {
    /// Which frame parts a directory cell of this size and depth gets.
    @inlinable func frameFlags(for rect: TreemapRect, depth: Int, frameLevel: Int, minCellSide: Float) -> TreemapCell.Flags {
        if depth == 0 && !framesRoot { return [] }
        if frameLevel >= maxNestedFrames { return [] }
        var flags: TreemapCell.Flags = []
        let w = rect.maxX - rect.minX
        let h = rect.maxY - rect.minY
        let level = level(at: frameLevel)
        if level.header > 0, depth < headerDepth, w >= level.minHeaderWidth,
            h >= max(level.minHeaderHeight, level.header + 2 * minCellSide)
        {
            flags.insert(.header)
        }
        // Frames must leave room for something worth framing.
        if level.padding > 0, depth < paddingDepth, min(w, h) >= 2 * level.padding + 2 * minCellSide,
            level.padsWithoutHeader || flags.contains(.header)
        {
            flags.insert(.padded)
        }
        return flags
    }

    @inlinable func contentRect(of rect: TreemapRect, flags: TreemapCell.Flags, level frameLevel: Int) -> TreemapRect {
        if flags.isDisjoint(with: [.header, .padded]) { return rect }
        let level = level(at: frameLevel)
        var r = rect
        let p: Float = flags.contains(.padded) ? level.padding : 0
        r.minX += p
        r.maxX -= p
        r.maxY -= p
        r.minY += flags.contains(.header) ? level.header : p
        return r
    }
}

// MARK: - Builder

/// One entry being squarified: a child node (or the aggregate of the small ones) and its area.
@usableFromInline struct LayoutItem {
    @usableFromInline var node: NodeID
    @usableFromInline var area: Float
    /// For the aggregate: number of merged siblings; 0 for ordinary items.
    @usableFromInline var merged: Int32
    /// For the aggregate: where the merged run starts among the parent's children, or -1.
    @usableFromInline var tailStart: Int32
}

/// Mutable state of one layout pass. The tree is deliberately *not* stored here but passed to
/// every method as a borrowed parameter: a stored copy made the optimizer copy the whole
/// builder (and retain all of the tree's columns) around each call in the hot loop.
struct LayoutBuilder {
    let options: TreemapLayoutOptions
    var cells = ContiguousArray<TreemapCell>()
    private var items: [LayoutItem] = []
    private var sortScratch: [(size: UInt64, node: NodeID)] = []
    /// `heights[d]` is the ridge height for a cell at depth `d` (index 0 unused: the root is flat).
    private var heights: [Float] = []

    /// Set in the private builder of a seed: the seed's nearest framed ancestor in the main
    /// array, if it has one (see `layOutSeeds`).
    var seedParent: TreemapCell?
    var allowParallel = true
    var sampleCache: CollapsedSampleCache?

    /// Share of the enclosing frame's content above which a directory is not framed again.
    static let dominantShare: Float = 0.8

    init(options: TreemapLayoutOptions) {
        self.options = options
    }

    private mutating func ridgeHeight(depth: Int) -> Float {
        while heights.count <= depth {
            heights.append(heights.isEmpty ? 0 : (heights.count == 1 ? options.cushionHeight : heights[heights.count - 1] * options.cushionFalloff))
        }
        return heights[depth]
    }

    mutating func build(_ tree: FileTree, root: NodeID, bounds: TreemapRect) -> ContiguousArray<TreemapCell> {
        let valid = Int(root) < tree.count && !tree.isRemoved(root)
        // The estimate only avoids regrowth; pruning keeps the real count far below it.
        cells.reserveCapacity(min(1 << 19, max(16, Int(bounds.area / 24))))
        items.reserveCapacity(1024)
        cells.append(
            TreemapCell(
                rect: bounds, surface: .flat, node: root, sample: root, parent: -1, firstChild: 0, childCount: 0,
                depth: 0, flags: valid && tree.isDirectory(root) ? [.directory] : []))
        guard valid else {
            cells[0].flags.insert(.leaf)
            return cells
        }

        // Large maps are split: the top of the hierarchy is laid out here, and every directory
        // cell below a certain size becomes a "seed" whose subtree is laid out on another core
        // and spliced in afterwards. Which cells become seeds depends only on the geometry, so
        // the result is the same on every run and machine.
        let parallel = allowParallel && bounds.area >= Self.parallelThreshold && ProcessInfo.processInfo.activeProcessorCount > 1
        let seedLimit = parallel ? bounds.area / 48 : 0
        var seeds: [Int] = []
        run(tree, deferBelow: seedLimit, seeds: &seeds)
        if !seeds.isEmpty { layOutSeeds(tree, seeds) }
        if options.collapsedSample != .largestFile, options.maxDepth < .max { sampleCollapsed(tree, cache: sampleCache) }
        return cells
    }

    /// Collapsed folders smaller than this many square pixels keep the largest-file sample:
    /// their colour is barely visible and there can be very many of them.
    static let minDominantArea: Float = 144

    /// Gives every collapsed folder of some size the sample ``TreemapLayoutOptions/CollapsedSample``
    /// asks for.
    ///
    /// The folders are disjoint, so their subtrees are walked concurrently and each node is
    /// visited at most once. A folder holding much of the tree is split further — into its
    /// sub-folders, and theirs — so that one dominant folder ("Library" in a home folder,
    /// "Users" on a startup disk) is still spread over all cores. Answers are remembered in
    /// `cache`: a resize or a zoom lays out the same folders again and again.
    private mutating func sampleCollapsed(_ tree: FileTree, cache: CollapsedSampleCache?) {
        let mode = options.collapsedSample
        let allocated = options.sizeMetric == .allocated
        let packagesAsLeaves = options.packagesAsLeaves
        let cacheKey = CollapsedSampleCache.Key(mode: mode, allocated: allocated, packagesAsLeaves: packagesAsLeaves)
        let known = cache?.samples(for: cacheKey) ?? [:]

        var targets: [Int] = []
        for index in cells.indices where cells[index].flags.contains(.collapsed) && cells[index].rect.area >= Self.minDominantArea {
            if let sample = known[cells[index].node] {
                cells[index].sample = sample
            } else {
                targets.append(index)
            }
        }
        guard !targets.isEmpty else { return }

        // Work units: runs of subtree roots that belong to one target. `shallow` roots stand
        // for a folder's own files only (its sub-folders are roots of their own).
        struct Root {
            var node: NodeID
            var shallow: Bool
        }
        struct Unit {
            var slot: Int
            var start: Int
            var end: Int
        }
        @Sendable @inline(__always) func descends(_ node: NodeID) -> Bool {
            tree.isDirectory(node) && !(packagesAsLeaves && tree.flags(of: node).contains(.package))
        }
        var totalFiles = 0
        for index in targets { totalFiles += tree.fileCount(of: cells[index].node) }
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunk = allowParallel && cores > 1 ? max(8192, totalFiles / (cores * 8)) : Int.max
        var roots: [Root] = []
        var units: [Unit] = []
        var unitsPerSlot = [Int](repeating: 0, count: targets.count)
        var pending: [NodeID] = []
        for (slot, index) in targets.enumerated() {
            let top = cells[index].node
            if tree.fileCount(of: top) <= chunk {
                units.append(Unit(slot: slot, start: roots.count, end: roots.count + 1))
                roots.append(Root(node: top, shallow: false))
                unitsPerSlot[slot] = 1
                continue
            }
            // Split: big folders are opened, small ones are batched until a batch is worth a task.
            pending.removeAll(keepingCapacity: true)
            pending.append(top)
            var batchStart = roots.count
            var batchFiles = 0
            func closeBatch() {
                if roots.count > batchStart {
                    units.append(Unit(slot: slot, start: batchStart, end: roots.count))
                    unitsPerSlot[slot] += 1
                }
                batchStart = roots.count
                batchFiles = 0
            }
            while let node = pending.popLast() {
                let files = tree.fileCount(of: node)
                if files > chunk, node == top || descends(node) {
                    roots.append(Root(node: node, shallow: true))
                    batchFiles += tree.childCount(of: node)
                    for child in tree.children(of: node) where descends(child) { pending.append(child) }
                } else {
                    roots.append(Root(node: node, shallow: false))
                    batchFiles += files
                }
                if batchFiles >= chunk { closeBatch() }
            }
            closeBatch()
        }

        let kindCount = tree.kinds.count
        let categoryOfKind: [KindCategory] = tree.kinds.map(\.category)
        let bucketCount: Int
        switch mode {
        case .dominantAge: bucketCount = AgeBucket.allCases.count
        default: bucketCount = max(1, kindCount)
        }
        struct Tally {
            var bytes: [UInt64]
            var largest: [NodeID]
            var largestSize: [UInt64]
        }
        // The winning bucket's largest file, or nil if nothing in the folder takes space.
        @Sendable func winner(_ tally: Tally) -> NodeID? {
            var best = -1
            if case .dominantKind = mode {
                // The category with the most bytes, then its heaviest kind. Iterating kinds
                // (not a dictionary) keeps ties deterministic.
                var perCategory: [KindCategory: UInt64] = [:]
                for kind in 0 ..< bucketCount where tally.bytes[kind] > 0 {
                    perCategory[categoryOfKind[kind], default: 0] &+= tally.bytes[kind]
                }
                var top: (category: KindCategory, bytes: UInt64)?
                for kind in 0 ..< bucketCount where tally.bytes[kind] > 0 {
                    let category = categoryOfKind[kind]
                    let total = perCategory[category] ?? 0
                    if top == nil || total > top!.bytes { top = (category, total) }
                }
                if let top {
                    for kind in 0 ..< bucketCount where categoryOfKind[kind] == top.category {
                        if best < 0 || tally.bytes[kind] > tally.bytes[best] { best = kind }
                    }
                }
            } else {
                for bucket in 0 ..< bucketCount where tally.bytes[bucket] > 0 {
                    if best < 0 || tally.bytes[bucket] > tally.bytes[best] { best = bucket }
                }
            }
            return best >= 0 && tally.largestSize[best] > 0 ? tally.largest[best] : nil
        }

        let results = UnsafeMutablePointer<NodeID?>.allocate(capacity: targets.count)
        results.initialize(repeating: nil, count: targets.count)
        // Only the units of split folders keep their tallies (to be merged below).
        let partials = UnsafeMutablePointer<Tally?>.allocate(capacity: units.count)
        partials.initialize(repeating: nil, count: units.count)
        defer {
            results.deinitialize(count: targets.count)
            results.deallocate()
            partials.deinitialize(count: units.count)
            partials.deallocate()
        }
        let allUnits = units
        let allRoots = roots
        let perSlot = unitsPerSlot
        do {
            let output = UnsafeSendable(results)
            let partialOutput = UnsafeSendable(partials)
            let work: @Sendable (Int) -> Void = { unitIndex in
                let unit = allUnits[unitIndex]
                var tally = Tally(
                    bytes: [UInt64](repeating: 0, count: bucketCount), largest: [NodeID](repeating: 0, count: bucketCount),
                    largestSize: [UInt64](repeating: 0, count: bucketCount))
                @inline(__always) func count(_ node: NodeID) {
                    let size = allocated ? tree.size(of: node) : tree.logicalSize(of: node)
                    guard size > 0 else { return }
                    let bucket: Int
                    switch mode {
                    case .dominantAge(let now): bucket = AgeBucket(modified: tree.modified(of: node), now: now).rawValue
                    default: bucket = min(Int(tree.kind(of: node)), bucketCount - 1)
                    }
                    tally.bytes[bucket] &+= size
                    // Ties go to the lower node id, so the answer does not depend on the walk order.
                    if size > tally.largestSize[bucket] || (size == tally.largestSize[bucket] && node < tally.largest[bucket]) {
                        tally.largestSize[bucket] = size
                        tally.largest[bucket] = node
                    }
                }
                var stack: [NodeID] = []
                for root in allRoots[unit.start ..< unit.end] {
                    if root.shallow {
                        for child in tree.children(of: root.node) where !descends(child) { count(child) }
                        continue
                    }
                    // A root is a collapsed folder or one of its sub-folders: always opened.
                    stack.append(contentsOf: tree.children(of: root.node))
                    while let node = stack.popLast() {
                        if descends(node) {
                            stack.append(contentsOf: tree.children(of: node))
                        } else {
                            count(node)
                        }
                    }
                }
                if perSlot[unit.slot] == 1 {
                    output.value[unit.slot] = winner(tally)
                } else {
                    partialOutput.value[unitIndex] = tally
                }
            }
            if chunk == Int.max {
                for unitIndex in allUnits.indices { work(unitIndex) }
            } else {
                DispatchQueue.concurrentPerform(iterations: allUnits.count, execute: work)
            }
        }
        // Merge the tallies of split folders (units of one slot are contiguous).
        var unitIndex = 0
        while unitIndex < units.count {
            let slot = units[unitIndex].slot
            guard unitsPerSlot[slot] > 1 else {
                unitIndex += 1
                continue
            }
            var merged = Tally(
                bytes: [UInt64](repeating: 0, count: bucketCount), largest: [NodeID](repeating: 0, count: bucketCount),
                largestSize: [UInt64](repeating: 0, count: bucketCount))
            while unitIndex < units.count, units[unitIndex].slot == slot {
                if let part = partials[unitIndex] {
                    for bucket in 0 ..< bucketCount where part.bytes[bucket] > 0 {
                        merged.bytes[bucket] &+= part.bytes[bucket]
                        // Ties go to the lower node id, so the result does not depend on the split.
                        if part.largestSize[bucket] > merged.largestSize[bucket]
                            || (part.largestSize[bucket] == merged.largestSize[bucket] && part.largest[bucket] < merged.largest[bucket])
                        {
                            merged.largestSize[bucket] = part.largestSize[bucket]
                            merged.largest[bucket] = part.largest[bucket]
                        }
                    }
                }
                unitIndex += 1
            }
            results[slot] = winner(merged)
        }
        var fresh: [NodeID: NodeID] = [:]
        for (slot, index) in targets.enumerated() {
            let sample = results[slot] ?? cells[index].sample
            cells[index].sample = sample
            fresh[cells[index].node] = sample
        }
        cache?.store(fresh, for: cacheKey)
    }

    static let parallelThreshold: Float = 400_000
    /// Directories smaller than this many square pixels are not worth handing to another core.
    static let minSeedArea: Float = 1500

    /// Breadth-first pass. `cells` doubles as the work queue, which makes each cell's children
    /// contiguous and puts parents before children. Directory cells with an area in
    /// `minSeedArea ..< deferBelow` are left untouched and reported in `seeds` instead.
    private mutating func run(_ tree: FileTree, deferBelow: Float, seeds: inout [Int]) {
        var index = 0
        while index < cells.count {
            let cell = cells[index]
            if deferBelow > 0, cell.flags == [.directory], cell.parent >= 0 {
                let area = cell.rect.area
                if area < deferBelow, area >= Self.minSeedArea {
                    seeds.append(index)
                    index += 1
                    continue
                }
            }
            if !cell.flags.contains(.aggregate), !subdivide(tree, index) {
                let sample = representative(tree, of: cell.node)
                cells[index].flags.insert(.leaf)
                cells[index].sample = sample
                let extra = options.tileHeight - ridgeHeight(depth: Int(cell.depth))
                if extra > 0, cell.parent >= 0 { cells[index].surface.addRidge(over: cell.rect, height: extra) }
            }
            index += 1
        }
    }

    /// Lays out the subtree of every seed cell concurrently and appends the results.
    ///
    /// Each seed gets a private builder whose cell 0 is the seed; afterwards the private arrays
    /// are concatenated in seed order and their indices rebased, which keeps both layout
    /// guarantees (parents first, children contiguous).
    private mutating func layOutSeeds(_ tree: FileTree, _ seeds: [Int]) {
        let options = self.options
        let results = UnsafeMutablePointer<ContiguousArray<TreemapCell>>.allocate(capacity: seeds.count)
        results.initialize(repeating: [], count: seeds.count)
        defer {
            results.deinitialize(count: seeds.count)
            results.deallocate()
        }
        cells.withUnsafeBufferPointer { main in
            // Sendable wrappers for the two raw pointers; every iteration writes only its own slot.
            let input = UnsafeSendable(main)
            let output = UnsafeSendable(results)
            DispatchQueue.concurrentPerform(iterations: seeds.count) { slot in
                let seed = input.value[seeds[slot]]
                var builder = LayoutBuilder(options: options)
                // The seed's nearest framed ancestor (see `framedAncestor`).
                var ancestor = Int(seed.parent)
                while ancestor >= 0, !input.value[ancestor].isFramed { ancestor = Int(input.value[ancestor].parent) }
                builder.seedParent = ancestor >= 0 ? input.value[ancestor] : nil
                builder.cells.reserveCapacity(max(16, Int(seed.rect.area / 16)))
                builder.cells.append(seed)
                var none: [Int] = []
                builder.run(tree, deferBelow: 0, seeds: &none)
                output.value[slot] = builder.cells
            }
        }

        var total = cells.count
        for slot in 0 ..< seeds.count { total += results[slot].count - 1 }
        cells.reserveCapacity(total)
        for slot in 0 ..< seeds.count {
            let local = results[slot]
            let seedIndex = seeds[slot]
            // Local index k > 0 lands at base + k; local 0 is the seed cell itself.
            let base = Int32(cells.count - 1)
            @inline(__always) func rebased(_ cell: TreemapCell) -> TreemapCell {
                var cell = cell
                if !cell.flags.contains(.leaf) { cell.firstChild += base }
                return cell
            }
            cells[seedIndex] = rebased(local[0])
            for k in 1 ..< local.count {
                var cell = rebased(local[k])
                cell.parent = cell.parent == 0 ? Int32(seedIndex) : cell.parent + base
                cells.append(cell)
            }
        }
    }

    /// The largest file under `node`, found by always taking the largest child. Packages stand
    /// for themselves when they are drawn as files.
    private func representative(_ tree: FileTree, of node: NodeID) -> NodeID {
        var current = node
        while tree.isDirectory(current), tree.childCount(of: current) > 0 {
            if options.packagesAsLeaves, tree.flags(of: current).contains(.package) { break }
            let largest = tree.child(of: current, at: 0)
            if tree.size(of: largest) == 0 && options.sizeMetric == .allocated { break }
            current = largest
        }
        return current
    }

    /// The nearest ancestor cell of `index` that has a frame, if any. In a seed's private
    /// builder the chain continues in the main array with `seedParent`, which `layOutSeeds`
    /// sets to the seed's nearest framed ancestor there.
    private func framedAncestor(of index: Int) -> TreemapCell? {
        var current = index
        while current != 0 {
            let parent = Int(cells[current].parent)
            if cells[parent].isFramed { return cells[parent] }
            current = parent
        }
        return seedParent
    }

    @inline(__always) private func metric(_ tree: FileTree, _ node: NodeID) -> UInt64 {
        options.sizeMetric == .allocated ? tree.size(of: node) : tree.logicalSize(of: node)
    }

    /// Lays out the children of cell `index`. Returns false if the cell should be a leaf.
    private mutating func subdivide(_ tree: FileTree, _ index: Int) -> Bool {
        let cell = cells[index]
        let node = cell.node
        let depth = Int(cell.depth)
        guard cell.flags.contains(.directory) else { return false }
        if depth > 0, options.packagesAsLeaves, tree.flags(of: node).contains(.package) { return false }
        let childCount = tree.childCount(of: node)
        let total = metric(tree, node)
        guard childCount > 0, total > 0 else { return false }
        if depth >= options.maxDepth {
            // The level of detail the caller asked for ends here: the folder is one tile.
            cells[index].flags.insert(.collapsed)
            return false
        }

        let frameLevel = Int(cell.frameLevel)
        var frame = options.style.frameFlags(for: cell.rect, depth: depth, frameLevel: frameLevel, minCellSide: options.minCellSide)
        // A directory that fills (nearly) all of the frame around it — "a/b/c" chains — would
        // just stack a second title on the first and waste the space; it goes unframed. The
        // comparison is with the nearest *framed* ancestor, so a whole chain of single-child
        // folders gets one frame, not every other one.
        if !frame.isEmpty, cell.parent >= 0, let outer = framedAncestor(of: index) {
            let outerContent = options.style.contentRect(of: outer.rect, flags: outer.flags, level: Int(outer.frameLevel))
            if cell.rect.area >= Self.dominantShare * outerContent.area { frame = [] }
        }
        let content = options.style.contentRect(of: cell.rect, flags: frame, level: frameLevel)
        let width = content.maxX - content.minX
        let height = content.maxY - content.minY
        guard width >= options.minCellSide, height >= options.minCellSide else { return false }

        // Pixels per byte. Double: sizes exceed Float's 24-bit mantissa by far.
        let scale = Double(width) * Double(height) / Double(total)
        let minSize = Double(options.minCellArea) / scale

        // Collect the children big enough to draw. They are sorted largest-first, so the first
        // one below the threshold ends the walk: the tail is never visited, which is what makes
        // the cost proportional to pixels rather than nodes.
        items.removeAll(keepingCapacity: true)
        var prefix: UInt64 = 0
        var taken = 0
        var tailStart: Int32 = -1
        var tailLargest: NodeID = node
        if options.sizeMetric == .allocated {
            let children = tree.children(of: node)
            for child in children {
                let size = tree.size(of: child)
                if Double(size) < minSize {
                    tailLargest = child
                    break
                }
                items.append(LayoutItem(node: child, area: Float(Double(size) * scale), merged: 0, tailStart: -1))
                prefix &+= size
                taken += 1
            }
            tailStart = Int32(taken)
        } else {
            sortScratch.removeAll(keepingCapacity: true)
            for child in tree.children(of: node) { sortScratch.append((tree.logicalSize(of: child), child)) }
            sortScratch.sort { $0.size != $1.size ? $0.size > $1.size : $0.node < $1.node }
            for entry in sortScratch {
                if Double(entry.size) < minSize {
                    tailLargest = entry.node
                    break
                }
                items.append(LayoutItem(node: entry.node, area: Float(Double(entry.size) * scale), merged: 0, tailStart: -1))
                prefix &+= entry.size
                taken += 1
            }
        }

        // Directory sizes are the sums of their children, so the tail's total needs no walk.
        let tail = total >= prefix ? total - prefix : 0
        let tailCount = childCount - taken
        if tail > 0, tailCount > 0 {
            let area = Float(Double(tail) * scale)
            if tailCount == 1 {
                // A lone small sibling is simply itself.
                items.append(LayoutItem(node: tailLargest, area: area, merged: 0, tailStart: -1))
            } else {
                // Everything is too small to tell apart: the directory itself is the tile.
                if items.isEmpty { return false }
                // Keep the list sorted: many small files together can outweigh the big ones.
                var position = items.count
                while position > 0, items[position - 1].area < area { position -= 1 }
                items.insert(
                    LayoutItem(node: tailLargest, area: area, merged: Int32(clamping: tailCount), tailStart: tailStart),
                    at: position)
            }
        }
        guard !items.isEmpty else { return false }

        let first = cells.count
        let childDepth = depth + 1
        let ridge = ridgeHeight(depth: childDepth)
        squarify(
            tree, into: content, parent: index, parentNode: node, depth: childDepth,
            frameLevel: UInt8(clamping: frameLevel + (frame.isEmpty ? 0 : 1)), surface: cell.surface, ridge: ridge)
        cells[index].flags.formUnion(frame)
        cells[index].firstChild = Int32(first)
        cells[index].childCount = Int32(cells.count - first)
        return true
    }

    /// Squarified layout of `items` (sorted by area, descending, summing to the area of `rect`).
    ///
    /// Rows are placed along the shorter side of the remaining rectangle; an item joins the
    /// current row while that does not worsen the row's worst aspect ratio.
    private mutating func squarify(
        _ tree: FileTree, into rect: TreemapRect, parent: Int, parentNode: NodeID, depth: Int, frameLevel: UInt8,
        surface: CushionSurface, ridge: Float
    ) {
        var x0 = rect.minX
        var y0 = rect.minY
        let x1 = rect.maxX
        let y1 = rect.maxY
        let count = items.count
        let depth16 = UInt16(clamping: depth)
        var i = 0
        while i < count {
            let w = x1 - x0
            let h = y1 - y0
            let side = min(w, h)
            let side2 = side * side

            // Grow the row. Items are sorted, so the row's maximum is its first item and its
            // minimum the latest one.
            let rowMax = items[i].area
            var sum = rowMax
            var worst = max(side2 * rowMax / (sum * sum), sum * sum / (side2 * rowMax))
            var j = i + 1
            while j < count {
                let area = items[j].area
                let nextSum = sum + area
                let next = max(side2 * rowMax / (nextSum * nextSum), nextSum * nextSum / (side2 * area))
                // `!(<=)` also stops on NaN (degenerate, zero-area remainders).
                if !(next <= worst) { break }
                sum = nextSum
                worst = next
                j += 1
            }

            let isLastRow = j == count
            let vertical = w >= h  // the row is a column on the left, items stacked top to bottom
            // Thickness of the row. The last row takes whatever is left, so rounding errors
            // never leave a sliver uncovered or push a cell outside its parent.
            var far: Float
            if vertical {
                far = isLastRow ? x1 : min(x1, x0 + (h > 0 ? sum / h : 0))
            } else {
                far = isLastRow ? y1 : min(y1, y0 + (w > 0 ? sum / w : 0))
            }
            if far.isNaN { far = vertical ? x1 : y1 }

            let length = vertical ? h : w
            let start = vertical ? y0 : x0
            let end = vertical ? y1 : x1
            var running: Float = 0
            var near = start
            for k in i ..< j {
                let item = items[k]
                running += item.area
                // Each edge is computed once and shared by both neighbours (see TreemapRect).
                var next = k == j - 1 ? end : start + (sum > 0 ? running / sum : 0) * length
                if !(next >= near) { next = near }
                if next > end { next = end }
                let cellRect =
                    vertical
                    ? TreemapRect(minX: x0, minY: near, maxX: far, maxY: next)
                    : TreemapRect(minX: near, minY: y0, maxX: next, maxY: far)
                near = next

                var cellSurface = surface
                cellSurface.addRidge(over: cellRect, height: ridge)
                if item.merged > 0 {
                    let sample = representative(tree, of: item.node)
                    if options.tileHeight > ridge { cellSurface.addRidge(over: cellRect, height: options.tileHeight - ridge) }
                    cells.append(
                        TreemapCell(
                            rect: cellRect, surface: cellSurface, node: parentNode,
                            sample: sample, parent: Int32(parent),
                            firstChild: item.tailStart, childCount: item.merged, depth: depth16,
                            flags: [.leaf, .aggregate, .directory], frameLevel: frameLevel))
                } else {
                    let flags: TreemapCell.Flags = tree.isDirectory(item.node) ? [.directory] : []
                    cells.append(
                        TreemapCell(
                            rect: cellRect, surface: cellSurface, node: item.node, sample: item.node,
                            parent: Int32(parent), firstChild: 0, childCount: 0, depth: depth16, flags: flags,
                            frameLevel: frameLevel))
                }
            }
            if vertical { x0 = far } else { y0 = far }
            i = j
        }
    }
}

/// Lets a raw pointer cross into a `concurrentPerform` closure. Safe where used because each
/// iteration reads shared immutable memory and writes only its own element.
struct UnsafeSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Remembers which file stands for each folder collapsed by the depth limit
/// (``TreemapLayoutOptions/CollapsedSample``), so that laying out the same tree again — a
/// resize, a zoom, another depth — does not walk those folders again.
///
/// The cache knows nothing about the tree: whoever owns it says which tree it is for with
/// ``use(generation:)`` and passes a new value whenever the tree (or its node ids) changed.
public final class CollapsedSampleCache: @unchecked Sendable {
    struct Key: Hashable {
        var mode: TreemapLayoutOptions.CollapsedSample
        var allocated: Bool
        var packagesAsLeaves: Bool
    }

    private let lock = NSLock()
    private var generation: Int?
    private var samples: [Key: [NodeID: NodeID]] = [:]

    public init() {}

    /// Declares which tree the following layouts are of; a new value forgets everything.
    public func use(generation: Int) {
        lock.lock()
        if self.generation != generation {
            self.generation = generation
            samples.removeAll()
        }
        lock.unlock()
    }

    func samples(for key: Key) -> [NodeID: NodeID] {
        lock.lock()
        defer { lock.unlock() }
        return samples[key] ?? [:]
    }

    func store(_ fresh: [NodeID: NodeID], for key: Key) {
        lock.lock()
        // One colouring at a time: an age ramp's `now` moves, and old entries are dead weight.
        if samples.count > 3, samples[key] == nil { samples.removeAll() }
        samples[key, default: [:]].merge(fresh) { _, new in new }
        lock.unlock()
    }
}
