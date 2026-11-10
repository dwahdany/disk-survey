import Foundation

// MARK: - Node bitmap

/// A fixed-capacity set of NodeIDs, one bit per node. Used for search highlighting.
public struct NodeBitset: Sendable, Equatable {
    @usableFromInline var words: ContiguousArray<UInt64>
    /// Number of node slots this bitmap covers (the `count` of the tree it was made for).
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity
        words = ContiguousArray(repeating: 0, count: (capacity + 63) / 64)
    }

    /// `false` for ids beyond the capacity, so a bitmap made before a mutation that appended
    /// nodes can still be queried safely.
    @inlinable public func contains(_ id: NodeID) -> Bool {
        let word = Int(id >> 6)
        return word < words.count && words[word] & (1 << UInt64(id & 63)) != 0
    }

    @inlinable public mutating func insert(_ id: NodeID) {
        words[Int(id >> 6)] |= 1 << UInt64(id & 63)
    }

    @inlinable public mutating func remove(_ id: NodeID) {
        words[Int(id >> 6)] &= ~(1 << UInt64(id & 63))
    }

    /// Number of members.
    public var population: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    public var isEmpty: Bool { !words.contains { $0 != 0 } }

    /// Calls `body` for every member in ascending NodeID order.
    @inlinable public func forEach(_ body: (NodeID) throws -> Void) rethrows {
        for (w, word) in words.enumerated() where word != 0 {
            var bits = word
            while bits != 0 {
                try body(NodeID(w * 64 + bits.trailingZeroBitCount))
                bits &= bits - 1
            }
        }
    }

    /// All members in ascending order.
    public var members: [NodeID] {
        var result: [NodeID] = []
        forEach { result.append($0) }
        return result
    }
}

// MARK: - Search

/// What to look for in ``FileTree/search(_:under:limit:)``. All set criteria must hold.
public struct SearchQuery: Sendable, Hashable {
    public enum Scope: Sendable, Hashable {
        case all, files, directories
    }

    /// Case-insensitive substring of the file name. Empty matches every name.
    public var text: String
    /// Bounds on the node's allocated size (inclusive).
    public var minSize: UInt64?
    public var maxSize: UInt64?
    /// Restrict to these kinds (ids of the searched tree's kind table).
    public var kinds: Set<KindID>?
    /// Restrict to these categories.
    public var categories: Set<KindCategory>?
    /// Modified at or after / at or before these times (seconds since 1970). Nodes with unknown
    /// modification time never satisfy a date criterion.
    public var modifiedAfter: Int64?
    public var modifiedBefore: Int64?
    public var scope: Scope

    public init(
        text: String = "", minSize: UInt64? = nil, maxSize: UInt64? = nil,
        kinds: Set<KindID>? = nil, categories: Set<KindCategory>? = nil,
        modifiedAfter: Int64? = nil, modifiedBefore: Int64? = nil, scope: Scope = .all
    ) {
        self.text = text
        self.minSize = minSize
        self.maxSize = maxSize
        self.kinds = kinds
        self.categories = categories
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.scope = scope
    }

    /// `true` when the query has no criteria at all (it would match every node).
    public var isUnconstrained: Bool {
        text.isEmpty && minSize == nil && maxSize == nil && kinds == nil && categories == nil
            && modifiedAfter == nil && modifiedBefore == nil && scope == .all
    }
}

public struct SearchResult: Sendable {
    /// The largest matches, by allocated size descending, at most `limit` of them.
    public var nodes: [NodeID]
    /// Number of all matches (may exceed `nodes.count`).
    public var totalMatches: Int
    /// Every match, for highlighting. See ``FileTree/containingMask(for:)``.
    public var matches: NodeBitset
}

/// A query compiled against one tree: everything the per-node test needs, precomputed.
struct CompiledQuery: Sendable {
    var needle: ContiguousArray<UInt8>  // lowercased UTF-8
    var altNeedle: ContiguousArray<UInt8>?  // the other Unicode normal form, if different
    /// The needle as typed, for the full case-folding comparison.
    var needleText: String
    /// Lowercased with every final sigma made medial (see `lowercasedForMatching`).
    var needleLower: String
    var needleIsASCII: Bool
    /// The needle contains a character whose case folding is not its lowercase form ("ß").
    var needleNeedsFolding: Bool
    var minSize: UInt64
    var maxSize: UInt64
    var minTime: UInt32
    var maxTime: UInt32
    var checksTime: Bool
    var kindAllowed: [Bool]?
    var wantFiles: Bool
    var wantDirectories: Bool

    init(_ query: SearchQuery, tree: FileTree) {
        let lower = query.text.lowercased()
        needleText = query.text
        needleLower = lowercasedForMatching(query.text)
        needle = ContiguousArray(lower.precomposedStringWithCanonicalMapping.utf8)
        let decomposed = ContiguousArray(lower.decomposedStringWithCanonicalMapping.utf8)
        altNeedle = decomposed == needle ? nil : decomposed
        needleIsASCII = needle.allSatisfy { $0 < 0x80 }
        var text = query.text
        needleNeedsFolding = text.withUTF8 { $0.isEmpty ? false : hasSpecialCaseFolding($0.baseAddress!, $0.count) }
        minSize = query.minSize ?? 0
        maxSize = query.maxSize ?? .max
        checksTime = query.modifiedAfter != nil || query.modifiedBefore != nil
        minTime = max(1, UInt32(clamping: query.modifiedAfter ?? 0))
        maxTime = UInt32(clamping: query.modifiedBefore ?? Int64(UInt32.max))
        if query.kinds != nil || query.categories != nil {
            kindAllowed = tree.kinds.enumerated().map { index, kind in
                (query.kinds?.contains(KindID(index)) ?? true) && (query.categories?.contains(kind.category) ?? true)
            }
        }
        wantFiles = query.scope != .directories
        wantDirectories = query.scope != .files
    }
}

@inline(__always)
private func asciiLower(_ byte: UInt8) -> UInt8 {
    byte &- 0x41 < 26 ? byte | 0x20 : byte
}

/// Case-insensitive (ASCII folding) substring test on raw bytes. `needle` must already be lowercase.
@inline(__always)
private func containsFolded(
    _ hay: UnsafePointer<UInt8>, _ hayLength: Int, _ needle: UnsafeBufferPointer<UInt8>
) -> Bool {
    let n = needle.count
    if n == 0 { return true }
    if n > hayLength { return false }
    let first = needle[0]
    var i = 0
    let last = hayLength - n
    while i <= last {
        if asciiLower(hay[i]) == first {
            var j = 1
            while j < n, asciiLower(hay[i + j]) == needle[j] { j += 1 }
            if j == n { return true }
        }
        i += 1
    }
    return false
}

/// Lowercases for a case-insensitive comparison. Plain `lowercased()` is context sensitive: it
/// turns a word-final "Σ" into "ς" but a medial one into "σ", so "ΣΑΣ.txt" (→ "σασ.txt") would
/// never be found by the natural lowercase needle "σας". Every sigma is therefore made medial.
private func lowercasedForMatching(_ string: String) -> String {
    let lower = string.lowercased()
    var previous: UInt8 = 0
    for byte in lower.utf8 {
        if previous == 0xCF, byte == 0x82 { return lower.replacingOccurrences(of: "ς", with: "σ") }
        previous = byte
    }
    return lower
}

/// Whether UTF-8 text contains a letter whose case folding differs from its lowercase form, so
/// that comparing lowercased strings is not enough: ß and ẞ ("ss"), ſ ("s"), µ (Greek "μ"),
/// the Kelvin sign ("k") and the ligatures ﬀ … ﬆ.
@inline(__always)
private func hasSpecialCaseFolding(_ text: UnsafePointer<UInt8>, _ length: Int) -> Bool {
    var i = 0
    while i + 1 < length {
        let lead = text[i]
        if lead >= 0xC2 {
            let next = text[i + 1]
            switch lead {
            case 0xC2: if next == 0xB5 { return true }  // µ
            case 0xC3: if next == 0x9F { return true }  // ß
            case 0xC5: if next == 0xBF { return true }  // ſ
            case 0xE1: if next == 0xBA, i + 2 < length, text[i + 2] == 0x9E { return true }  // ẞ
            case 0xE2: if next == 0x84, i + 2 < length, text[i + 2] == 0xAA { return true }  // K
            case 0xEF: if next == 0xAC, i + 2 < length, text[i + 2] & 0xF8 == 0x80 { return true }  // ﬀ … ﬆ
            default: break
            }
        }
        i += 1
    }
    return false
}

extension FileTree {
    @inline(__always)
    private func test(
        _ id: Int, _ q: CompiledQuery, pool: UnsafePointer<UInt8>,
        needle: UnsafeBufferPointer<UInt8>, alt: UnsafeBufferPointer<UInt8>?
    ) -> Bool {
        let flags = _flags[id]
        if flags & NodeFlags.removed.rawValue != 0 { return false }
        if flags & NodeFlags.directory.rawValue != 0 {
            if !q.wantDirectories { return false }
        } else if !q.wantFiles {
            return false
        }
        let size = _allocated[id]
        if size < q.minSize || size > q.maxSize { return false }
        if q.checksTime {
            let t = _mtime[id]
            if t < q.minTime || t > q.maxTime { return false }
        }
        if let allowed = q.kindAllowed, !allowed[Int(_kind[id])] { return false }
        if needle.isEmpty { return true }

        let name = pool + Int(_nameOffset[id])
        let length = Int(_nameLength[id])
        if containsFolded(name, length, needle) { return true }
        if let alt, containsFolded(name, length, alt) { return true }
        // The byte search above is only a shortcut for the common cases; a non-ASCII name needs
        // a Unicode-aware comparison ("É" vs "é"). ASCII-only names are done here.
        var hasHighByte = false
        for i in 0 ..< length where name[i] >= 0x80 {
            hasHighByte = true
            break
        }
        guard hasHighByte else { return false }
        if q.needleNeedsFolding || hasSpecialCaseFolding(name, length) {
            // A letter whose case folding is more than lowercasing is involved ("STRASSE" must
            // find "straße"): full case-insensitive comparison, locale independent. Correct for
            // everything, but several times slower than the path below, hence only here.
            let string = String(decoding: UnsafeBufferPointer(start: name, count: length), as: UTF8.self)
            return string.range(of: q.needleText, options: .caseInsensitive, range: nil, locale: nil) != nil
        }
        // Without such letters an ASCII needle can only match ASCII bytes, which the byte search
        // has already ruled out.
        if q.needleIsASCII { return false }
        let string = String(decoding: UnsafeBufferPointer(start: name, count: length), as: UTF8.self)
        return lowercasedForMatching(string).contains(q.needleLower)
    }

    /// All live nodes strictly below `root` that satisfy `query`, as a bitmap.
    ///
    /// Works on raw name bytes and runs in parallel for whole-tree searches: a few tens of
    /// milliseconds for millions of nodes.
    public func matches(_ query: SearchQuery, under root: NodeID = 0) -> NodeBitset {
        var result = NodeBitset(capacity: count)
        let q = CompiledQuery(query, tree: self)
        let n = count

        _namePool.withUnsafeBufferPointer { poolBuffer in
            q.needle.withUnsafeBufferPointer { needle in
                // The pool is never empty in practice: the root always has a name.
                guard let pool = poolBuffer.baseAddress else { return }
                func run(_ alt: UnsafeBufferPointer<UInt8>?) {
                    if root == 0 {
                        // Linear sweep over all nodes; blocks are multiples of 64 nodes so every
                        // block owns its bitmap words exclusively.
                        let block = 1 << 16
                        let blocks = (n + block - 1) / block
                        result.words.withUnsafeMutableBufferPointer { words in
                            let context = Unchecked((words: words.baseAddress!, pool: pool, needle: needle, alt: alt))
                            let tree = self
                            let scan: @Sendable (Int) -> Void = { b in
                                let c = context.value
                                let end = min(n, (b + 1) * block)
                                var id = max(1, b * block)
                                while id < end {
                                    if tree.test(id, q, pool: c.pool, needle: c.needle, alt: c.alt) {
                                        c.words[id >> 6] |= 1 << UInt64(id & 63)
                                    }
                                    id += 1
                                }
                            }
                            if blocks > 2 {
                                DispatchQueue.concurrentPerform(iterations: blocks, execute: scan)
                            } else {
                                for b in 0 ..< blocks { scan(b) }
                            }
                        }
                    } else if !isRemoved(root) {
                        forEachDescendant(of: root) { id in
                            if test(Int(id), q, pool: pool, needle: needle, alt: alt) { result.insert(id) }
                        }
                    }
                }
                if let altNeedle = q.altNeedle {
                    altNeedle.withUnsafeBufferPointer { run($0) }
                } else {
                    run(nil)
                }
            }
        }
        return result
    }

    /// Searches names (case-insensitive substring) with optional size/kind/date filters.
    ///
    /// - Returns: the `limit` largest matches (size descending), the total number of matches and
    ///   the full match bitmap.
    public func search(_ query: SearchQuery, under root: NodeID = 0, limit: Int = 1000) -> SearchResult {
        let matches = self.matches(query, under: root)
        var total = 0
        // Min-heap of the best `limit` candidates seen so far.
        var heap = BinaryHeap<NodeID> { a, b in
            let sa = self._allocated[Int(a)]
            let sb = self._allocated[Int(b)]
            return sa != sb ? sa < sb : a > b
        }
        matches.forEach { id in
            total += 1
            guard limit > 0 else { return }
            if heap.count < limit {
                heap.push(id)
            } else if let smallest = heap.first, heap.less(smallest, id) {
                heap.replaceFirst(with: id)
            }
        }
        var nodes: [NodeID] = []
        nodes.reserveCapacity(heap.count)
        while let id = heap.pop() { nodes.append(id) }
        nodes.reverse()
        return SearchResult(nodes: nodes, totalMatches: total, matches: matches)
    }

    /// Convenience: search by name only.
    public func search(_ text: String, under root: NodeID = 0, limit: Int = 1000) -> SearchResult {
        search(SearchQuery(text: text), under: root, limit: limit)
    }

    /// The given nodes plus all of their ancestors: "this node is, or contains, a match".
    /// A treemap can dim everything outside the mask; an outline can show only rows inside it.
    public func containingMask(for matches: NodeBitset) -> NodeBitset {
        var mask = matches
        if mask.words.count < (count + 63) / 64 {
            mask.words.append(contentsOf: repeatElement(0, count: (count + 63) / 64 - mask.words.count))
        }
        matches.forEach { id in
            guard Int(id) < count else { return }
            var node = id
            // Stop climbing as soon as we reach an ancestor that is already marked.
            while node != 0 {
                node = _parent[Int(node)]
                if mask.contains(node) { break }
                mask.insert(node)
            }
        }
        return mask
    }

    // MARK: - Largest files

    /// The largest files below `root`, largest first.
    ///
    /// Runs a best-first walk that exploits the sorted sibling lists, so the cost depends on
    /// `limit`, not on the size of the tree.
    ///
    /// - Parameter packagesAsFiles: treat packages (`.app`, `.photoslibrary`, …) as single items
    ///   instead of listing the files inside them.
    public func largestFiles(under root: NodeID = 0, limit: Int, packagesAsFiles: Bool = false) -> [NodeID] {
        guard limit > 0, !isRemoved(root) else { return [] }
        let leafBits = NodeFlags.directory.rawValue | (packagesAsFiles ? NodeFlags.package.rawValue : 0)
        @inline(__always) func isLeaf(_ id: NodeID) -> Bool {
            let f = _flags[Int(id)]
            return f & NodeFlags.directory.rawValue == 0 || (packagesAsFiles && f & leafBits == leafBits)
        }
        if isLeaf(root) && root != 0 { return [root] }

        // Each heap entry is a cursor into one sibling list; only the next unvisited (i.e.
        // largest remaining) sibling of every opened directory is ever in the heap.
        struct Cursor {
            var size: UInt64
            var position: Int
            var end: Int
        }
        var heap = BinaryHeap<Cursor> { a, b in
            a.size != b.size ? a.size > b.size : a.position < b.position
        }
        func open(_ dir: NodeID, into heap: inout BinaryHeap<Cursor>) {
            let start = Int(_childStart[Int(dir)])
            let count = Int(_childCount[Int(dir)])
            if count > 0 {
                heap.push(Cursor(size: _allocated[Int(_childIndex[start])], position: start, end: start + count))
            }
        }
        open(root, into: &heap)
        var result: [NodeID] = []
        result.reserveCapacity(min(limit, 4096))
        while result.count < limit, let cursor = heap.pop() {
            let node = _childIndex[cursor.position]
            if cursor.position + 1 < cursor.end {
                let next = cursor.position + 1
                heap.push(Cursor(size: _allocated[Int(_childIndex[next])], position: next, end: cursor.end))
            }
            if isLeaf(node) {
                result.append(node)
            } else {
                open(node, into: &heap)
            }
        }
        return result
    }

    // MARK: - Kind statistics

    /// Per-kind totals of the files below `root`, sorted by allocated size descending.
    /// Kinds without any file are omitted.
    public func kindSummary(under root: NodeID = 0) -> [KindStat] {
        var sizes = [UInt64](repeating: 0, count: kinds.count)
        var logicals = [UInt64](repeating: 0, count: kinds.count)
        var counts = [Int](repeating: 0, count: kinds.count)
        let skip = NodeFlags.directory.rawValue | NodeFlags.removed.rawValue

        @inline(__always) func add(_ id: Int) {
            guard _flags[id] & skip == 0 else { return }
            let k = Int(_kind[id])
            sizes[k] &+= _allocated[id]
            logicals[k] &+= _logical[id]
            counts[k] += Int(_fileCount[id])
        }
        if root == 0 {
            for id in 1 ..< max(count, 1) { add(id) }
        } else if !isRemoved(root) {
            add(Int(root))
            forEachDescendant(of: root) { add(Int($0)) }
        }

        var stats: [KindStat] = []
        for k in 0 ..< kinds.count where counts[k] > 0 {
            stats.append(
                KindStat(
                    kind: KindID(k), ext: kinds[k].ext, category: kinds[k].category,
                    size: sizes[k], logicalSize: logicals[k], fileCount: counts[k]))
        }
        stats.sort { $0.size != $1.size ? $0.size > $1.size : $0.kind < $1.kind }
        return stats
    }

    /// Per-category totals of the files below `root`, sorted by allocated size descending.
    public func categorySummary(under root: NodeID = 0) -> [CategoryStat] {
        var byCategory: [KindCategory: CategoryStat] = [:]
        for stat in kindSummary(under: root) {
            byCategory[stat.category, default: CategoryStat(category: stat.category, size: 0, logicalSize: 0, fileCount: 0)]
                .add(stat)
        }
        return byCategory.values.sorted {
            $0.size != $1.size ? $0.size > $1.size : $0.category.rawValue < $1.category.rawValue
        }
    }
}

/// Totals of one file kind (extension) within a subtree.
public struct KindStat: Sendable, Hashable, Identifiable {
    public var kind: KindID
    /// Lowercase extension, empty for "no extension".
    public var ext: String
    public var category: KindCategory
    /// Allocated bytes.
    public var size: UInt64
    public var logicalSize: UInt64
    public var fileCount: Int

    public var id: KindID { kind }
    /// ".mp4", "Unix Executable", or "No Extension".
    public var displayName: String { FileKind.displayName(forExtension: ext) }
    /// Whether this is the "Unix Executable" pseudo-kind (``FileKind/unixExecutableExtension``).
    public var isUnixExecutable: Bool { ext == FileKind.unixExecutableExtension }
}

/// Totals of one ``KindCategory`` within a subtree.
public struct CategoryStat: Sendable, Hashable, Identifiable {
    public var category: KindCategory
    public var size: UInt64
    public var logicalSize: UInt64
    public var fileCount: Int

    public var id: KindCategory { category }

    mutating func add(_ stat: KindStat) {
        size &+= stat.size
        logicalSize &+= stat.logicalSize
        fileCount += stat.fileCount
    }
}

// MARK: - Heap

/// Minimal binary heap; `first` is the element for which `less` holds against all others.
struct BinaryHeap<Element> {
    private(set) var items: [Element] = []
    let less: (Element, Element) -> Bool

    init(less: @escaping (Element, Element) -> Bool) { self.less = less }

    var count: Int { items.count }
    var first: Element? { items.first }

    mutating func push(_ element: Element) {
        items.append(element)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard less(items[child], items[parent]) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Element? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            siftDown()
        }
        return top
    }

    mutating func replaceFirst(with element: Element) {
        items[0] = element
        siftDown()
    }

    private mutating func siftDown() {
        var parent = 0
        let n = items.count
        while true {
            var best = parent
            let left = 2 * parent + 1
            let right = left + 1
            if left < n, less(items[left], items[best]) { best = left }
            if right < n, less(items[right], items[best]) { best = right }
            if best == parent { return }
            items.swapAt(parent, best)
            parent = best
        }
    }
}
