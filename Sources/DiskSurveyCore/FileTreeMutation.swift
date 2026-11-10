import Foundation

extension FileTree {
    /// Aggregate sizes of a node or subtree.
    public struct Totals: Sendable, Hashable {
        public var allocated: UInt64
        public var logical: UInt64
        public var fileCount: Int

        public init(allocated: UInt64 = 0, logical: UInt64 = 0, fileCount: Int = 0) {
            self.allocated = allocated
            self.logical = logical
            self.fileCount = fileCount
        }

        public static let zero = Totals()
    }

    /// Sizes and file count of a node (for directories: of the whole subtree).
    public func totals(of id: NodeID) -> Totals {
        Totals(allocated: size(of: id), logical: logicalSize(of: id), fileCount: fileCount(of: id))
    }

    // MARK: - Remove

    /// Removes a node (and its whole subtree) from the tree, e.g. after moving it to the Trash.
    ///
    /// The node and its descendants are flagged ``NodeFlags/removed`` with sizes and counts zeroed
    /// and no children, the node disappears from its parent's `children`, all ancestors' totals
    /// shrink accordingly and their positions among their siblings are re-sorted. NodeIDs of other
    /// nodes are unchanged.
    ///
    /// Hard links: if the removed subtree held the counted link of an inode and another link of
    /// that inode is still in the tree (see `link:` on ``Builder/Worker``), the lowest-numbered
    /// surviving link takes over the size and loses ``NodeFlags/hardLinkDuplicate`` — removing
    /// one name of a file does not free its blocks.
    ///
    /// - Returns: what was freed, i.e. by how much the root's totals shrank. `.zero` if the node
    ///   had already been removed.
    /// - Precondition: `id` is not the root.
    @discardableResult
    public mutating func remove(_ id: NodeID) -> Totals {
        remove(CollectionOfOne(id))
    }

    /// Removes several nodes; nodes nested inside other removed nodes are counted once, and an
    /// inode whose links are all among the removed nodes is freed exactly once.
    @discardableResult
    public mutating func remove(_ ids: some Sequence<NodeID>) -> Totals {
        let before = totals(of: 0)
        var touched = Set<LinkID>()
        for id in ids {
            precondition(id != 0, "the root of a FileTree cannot be removed")
            guard !isRemoved(id) else { continue }
            let gone = totals(of: id)
            let parent = _parent[Int(id)]

            tombstoneDescendants(of: id, touched: &touched)
            tombstone(id, touched: &touched)
            detach(id, from: parent)
            adjustAncestors(
                startingAt: parent,
                allocated: -Int64(bitPattern: gone.allocated),
                logical: -Int64(bitPattern: gone.logical),
                fileCount: -Int64(gone.fileCount))
            revision &+= 1
        }
        reconcileLinks(touched)
        let after = totals(of: 0)
        return Totals(
            allocated: before.allocated &- after.allocated, logical: before.logical &- after.logical,
            fileCount: before.fileCount - after.fileCount)
    }

    // MARK: - Replace

    /// Grafts a freshly scanned tree in place of node `id` (used to rescan a single folder).
    ///
    /// `id` keeps its NodeID, name and parent, and takes over the sizes, counts, modification time
    /// and children of `replacement`'s root. The replacement's other nodes are appended to this
    /// tree with new NodeIDs; the previous descendants of `id` become tombstones
    /// (``NodeFlags/removed``). Ancestor totals and sibling order are fixed up.
    ///
    /// The old descendants' slots and name bytes are not reclaimed, so a tree grows a little with
    /// every replacement; rescan from the root to get a compact tree again.
    ///
    /// Hard links: an inode stays counted once. If a link grafted in is a further link to an
    /// inode that is already counted outside `id`, the grafted one becomes the
    /// ``NodeFlags/hardLinkDuplicate`` (nodes outside the rescanned folder keep their sizes); if
    /// the counted link was among the old descendants and is gone, a surviving link takes over.
    ///
    /// - Returns: the totals of `id` before and after (after hard-link accounting), so callers
    ///   can report the change.
    @discardableResult
    public mutating func replaceSubtree(at id: NodeID, with replacement: FileTree) -> (before: Totals, after: Totals) {
        precondition(!isRemoved(id), "cannot replace a removed node")
        let before = totals(of: id)
        let after = replacement.totals(of: 0)
        var touched = Set<LinkID>()
        let added = replacement.count - 1
        precondition(count + added <= Int(UInt32.max), "FileTree supports at most 2^32 - 1 nodes")
        precondition(
            _namePool.count + replacement._namePool.count <= Int(UInt32.max),
            "FileTree name pool is limited to 4 GB")

        tombstoneDescendants(of: id, touched: &touched)
        if !_links.isEmpty, let own = _links.removeValue(forKey: id) { touched.insert(own.id) }

        // Map the replacement's kind ids into this tree's table.
        var kindMap: [KindID] = []
        kindMap.reserveCapacity(replacement.kinds.count)
        for kind in replacement.kinds {
            if let existing = _kindLookup[kind.ext] {
                kindMap.append(existing)
            } else if kinds.count < Int(KindID.max) {
                let new = KindID(kinds.count)
                kinds.append(kind)
                _kindLookup[kind.ext] = new
                kindMap.append(new)
            } else {
                kindMap.append(0)
            }
        }

        // Replacement node r (r >= 1) becomes base + r - 1; its root becomes `id`.
        let base = UInt32(count)
        let poolBase = UInt32(_namePool.count)
        let indexBase = UInt32(_childIndex.count)
        @inline(__always) func mapped(_ r: NodeID) -> NodeID { r == 0 ? id : base + r - 1 }

        _namePool.append(contentsOf: replacement._namePool)
        _childIndex.reserveCapacity(_childIndex.count + replacement._childIndex.count)
        for r in replacement._childIndex { _childIndex.append(mapped(r)) }

        let total = count + added
        _nameOffset.reserveCapacity(total); _nameLength.reserveCapacity(total)
        _parent.reserveCapacity(total); _childStart.reserveCapacity(total)
        _childCount.reserveCapacity(total); _allocated.reserveCapacity(total)
        _logical.reserveCapacity(total); _fileCount.reserveCapacity(total)
        _mtime.reserveCapacity(total); _kind.reserveCapacity(total); _flags.reserveCapacity(total)
        for r in 1 ..< max(replacement.count, 1) {
            _nameOffset.append(poolBase + replacement._nameOffset[r])
            _nameLength.append(replacement._nameLength[r])
            _parent.append(mapped(replacement._parent[r]))
            _childStart.append(indexBase + replacement._childStart[r])
            _childCount.append(replacement._childCount[r])
            _allocated.append(replacement._allocated[r])
            _logical.append(replacement._logical[r])
            _fileCount.append(replacement._fileCount[r])
            _mtime.append(replacement._mtime[r])
            _kind.append(kindMap[Int(replacement._kind[r])])
            _flags.append(replacement._flags[r])
        }
        for (r, info) in replacement._links where r != 0 {
            _links[mapped(r)] = info
            touched.insert(info.id)
        }

        // The grafted node itself: identity (name, parent, kind) stays, content comes from the new root.
        let i = Int(id)
        let keep = NodeFlags(rawValue: _flags[i]).intersection([.package, .mountPoint, .symlink])
        _flags[i] = replacement.flags(of: 0).union(keep).rawValue
        _childStart[i] = indexBase + replacement._childStart[0]
        _childCount[i] = replacement._childCount[0]
        _allocated[i] = after.allocated
        _logical[i] = after.logical
        _fileCount[i] = UInt32(clamping: after.fileCount)
        if replacement._mtime[0] != 0 { _mtime[i] = replacement._mtime[0] }

        if id != 0 {
            repositionAmongSiblings(id)
            adjustAncestors(
                startingAt: _parent[i],
                allocated: Int64(bitPattern: after.allocated &- before.allocated),
                logical: Int64(bitPattern: after.logical &- before.logical),
                fileCount: Int64(after.fileCount) - Int64(before.fileCount))
        }
        // Grafted links are numbered above everything that existed before, so "the lowest
        // NodeID keeps the size" prefers links outside the rescanned folder.
        reconcileLinks(touched)
        revision &+= 1
        return (before, totals(of: id))
    }

    // MARK: - Helpers

    /// Flags the node removed and empties it: no size, no files, no children, no link identity.
    private mutating func tombstone(_ id: NodeID, touched: inout Set<LinkID>) {
        let i = Int(id)
        _flags[i] |= NodeFlags.removed.rawValue
        _allocated[i] = 0
        _logical[i] = 0
        _fileCount[i] = 0
        // A removed node lists no children. `_childStart` can stay: the slice is empty.
        if _childCount[i] != 0 { _childCount[i] = 0 }
        if !_links.isEmpty, let info = _links.removeValue(forKey: id) { touched.insert(info.id) }
    }

    private mutating func tombstoneDescendants(of id: NodeID, touched: inout Set<LinkID>) {
        var stack = Array(children(of: id))
        while let node = stack.popLast() {
            // Collect the children before tombstoning, which empties the node's child list.
            if _childCount[Int(node)] != 0 { stack.append(contentsOf: children(of: node)) }
            tombstone(node, touched: &touched)
        }
    }

    /// Restores "every inode is counted once" for the given inodes after links were removed or
    /// added: among the live links of each inode exactly one carries the size. The lowest NodeID
    /// wins, which is deterministic and, after a graft, favours nodes that were already there.
    private mutating func reconcileLinks(_ touched: Set<LinkID>) {
        guard !touched.isEmpty, !_links.isEmpty else { return }
        var groups: [LinkID: [NodeID]] = [:]
        for (node, info) in _links where touched.contains(info.id) {
            groups[info.id, default: []].append(node)
        }
        let duplicate = NodeFlags.hardLinkDuplicate.rawValue
        for var nodes in groups.values {
            nodes.sort()
            var counted: NodeID?
            for node in nodes where _flags[Int(node)] & duplicate == 0 {
                if counted == nil {
                    counted = node
                } else {
                    // A second counted link: make it a duplicate.
                    let i = Int(node)
                    let (allocated, logical) = (_allocated[i], _logical[i])
                    _flags[i] |= duplicate
                    _allocated[i] = 0
                    _logical[i] = 0
                    resize(node, allocated: -Int64(bitPattern: allocated), logical: -Int64(bitPattern: logical))
                }
            }
            if counted == nil, let heir = nodes.first, let info = _links[heir] {
                // The counted link is gone: the first survivor takes over the size.
                let i = Int(heir)
                _flags[i] &= ~duplicate
                _allocated[i] = info.allocated
                _logical[i] = info.logical
                resize(heir, allocated: Int64(bitPattern: info.allocated), logical: Int64(bitPattern: info.logical))
            }
        }
    }

    /// After a file's own size changed by the given deltas: re-sorts it among its siblings and
    /// propagates the change to all ancestors.
    private mutating func resize(_ node: NodeID, allocated: Int64, logical: Int64) {
        guard node != 0, allocated != 0 || logical != 0 else { return }
        repositionAmongSiblings(node)
        adjustAncestors(startingAt: _parent[Int(node)], allocated: allocated, logical: logical, fileCount: 0)
    }

    /// Takes `id` out of `parent`'s sibling list, keeping the rest in order.
    private mutating func detach(_ id: NodeID, from parent: NodeID) {
        let start = Int(_childStart[Int(parent)])
        let end = start + Int(_childCount[Int(parent)])
        guard var k = (start ..< end).first(where: { _childIndex[$0] == id }) else { return }
        while k + 1 < end {
            _childIndex[k] = _childIndex[k + 1]
            k += 1
        }
        _childCount[Int(parent)] -= 1
    }

    /// Applies signed deltas to `node` and every ancestor above it, re-sorting each among its siblings.
    private mutating func adjustAncestors(startingAt node: NodeID, allocated: Int64, logical: Int64, fileCount: Int64) {
        var current = node
        while true {
            let i = Int(current)
            _allocated[i] = UInt64(bitPattern: Int64(bitPattern: _allocated[i]) &+ allocated)
            _logical[i] = UInt64(bitPattern: Int64(bitPattern: _logical[i]) &+ logical)
            _fileCount[i] = UInt32(clamping: Int64(_fileCount[i]) + fileCount)
            if current == 0 { break }
            repositionAmongSiblings(current)
            current = _parent[i]
        }
    }

    /// Restores the "largest first" order of a sibling list after one member's size changed.
    private mutating func repositionAmongSiblings(_ id: NodeID) {
        let parent = Int(_parent[Int(id)])
        let start = Int(_childStart[parent])
        let end = start + Int(_childCount[parent])
        guard var k = (start ..< end).first(where: { _childIndex[$0] == id }) else { return }
        while k > start, precedes(id, _childIndex[k - 1]) {
            _childIndex[k] = _childIndex[k - 1]
            k -= 1
        }
        while k + 1 < end, precedes(_childIndex[k + 1], id) {
            _childIndex[k] = _childIndex[k + 1]
            k += 1
        }
        _childIndex[k] = id
    }

    /// Sibling order: larger allocated size first, then lower NodeID.
    @inline(__always)
    private func precedes(_ a: NodeID, _ b: NodeID) -> Bool {
        let sa = _allocated[Int(a)]
        let sb = _allocated[Int(b)]
        return sa != sb ? sa > sb : a < b
    }
}
