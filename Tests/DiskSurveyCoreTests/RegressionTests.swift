import Foundation
import Testing
@testable import DiskSurveyCore

// MARK: - Builder: assembly memory handling

@Suite struct AssemblyStorageTests {
    @Test func columnHandsItsStorageOverWithoutCopying() {
        let column = Column<UInt32>(1000)
        for i in 0 ..< 1000 { column.p[i] = UInt32(i) }
        let address = UnsafeRawPointer(column.p)
        let array = column.take()
        #expect(array.count == 1000 && array[999] == 999)
        #expect(array.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress!) } == address)
        #expect(column.take().isEmpty)  // moved out: the column holds no second reference

        let zeroed = Column<UInt64>(64, zeroed: true)
        #expect(zeroed.take().allSatisfy { $0 == 0 })
        // Empty columns (the child index of a root-only tree) have an exact length of 0.
        #expect(Column<NodeID>(0).take().isEmpty)
        #expect(Column<NodeID>(0, zeroed: true).take().isEmpty)
    }

    @Test func chunksAreZeroFilledPageMappings() {
        let entries = RawChunk<RawEntry>(capacity: FileTree.Builder.Worker.entriesPerChunk)
        entries.p[FileTree.Builder.Worker.entriesPerChunk - 1].allocated = 7
        #expect(entries.p[0].allocated == 0 && entries.p[FileTree.Builder.Worker.entriesPerChunk - 1].allocated == 7)
        let odd = RawChunk<UInt8>(capacity: 3)  // rounded up to a page
        odd.p[2] = 1
        #expect(odd.p[0] == 0 && odd.p[2] == 1)
    }

    @Test func rootOnlyTreeBuildsAndMutates() {
        let builder = FileTree.Builder(rootPath: "/lonely", rootModified: 9)
        _ = builder.makeWorker()  // a worker that never appends
        #expect(builder.snapshot().count == 1)
        var tree = builder.finalize()
        #expect(tree.count == 1 && tree.children(of: 0).isEmpty && tree.size(of: 0) == 0)
        #expect(tree.name(of: 0) == "lonely" && tree.modified(of: 0) == 9)
        #expect(invariantViolations(tree).isEmpty)

        let empty = tree
        tree.replaceSubtree(at: 0, with: FileTree.make(rootPath: "/lonely", [.file("a.bin", 5)]))
        #expect(tree.size(of: 0) == 5 && tree.childNames(0) == ["a.bin"])
        #expect(empty.count == 1 && empty.size(of: 0) == 0)
        #expect(invariantViolations(tree).isEmpty)
    }

    /// The tree owns the only reference to its columns: a mutation right after building changes
    /// the tree in place and never leaks into an earlier copy.
    @Test func buildThenMutate() {
        var tree = demoTree()
        let copy = tree
        let before = tree.size(of: 0)
        let freed = tree.remove(tree.id("Movies"))
        #expect(freed.allocated == 4_120_000_000)
        #expect(tree.size(of: 0) == before - 4_120_000_000)
        #expect(copy.size(of: 0) == before && copy.childNames(0).first == "Movies")
        #expect(invariantViolations(tree).isEmpty && invariantViolations(copy).isEmpty)
    }

    /// Deterministic content for worker `w`: directories under the root and files inside them,
    /// crossing several entry chunks (8192) and name chunks, ending in a partially filled chunk.
    private static func feed(_ worker: FileTree.Builder.Worker, index w: Int, entries: Int, builder: FileTree.Builder) {
        var dirs: [FileTree.Builder.Ref] = []
        for i in 0 ..< entries {
            if i % 400 == 0 {
                let ref = worker.append(
                    to: .root, name: "w\(w)-dir\(i)", allocatedSize: 0, logicalSize: 0, modified: 1, flags: .directory)
                dirs.append(ref)
                if i % 1200 == 0 { builder.addFlags(.unreadable, to: ref) }
            } else {
                worker.append(
                    to: dirs[i % dirs.count], name: "w\(w)-file-\(i)-padding-for-the-name-chunks.jpg",
                    allocatedSize: UInt64(i % 97) * 512, logicalSize: UInt64(i), modified: Int64(i))
            }
        }
    }

    private static func sameTree(_ a: FileTree, _ b: FileTree) -> Bool {
        guard a.count == b.count, a.kinds == b.kinds else { return false }
        for index in 0 ..< a.count {
            let id = NodeID(index)
            guard a.nameUTF8(of: id).elementsEqual(b.nameUTF8(of: id)), a.parent(of: id) == b.parent(of: id),
                a.size(of: id) == b.size(of: id), a.logicalSize(of: id) == b.logicalSize(of: id),
                a.fileCount(of: id) == b.fileCount(of: id), a.flags(of: id) == b.flags(of: id),
                a.kind(of: id) == b.kind(of: id), a.modified(of: id) == b.modified(of: id),
                a.children(of: id).elementsEqual(b.children(of: id))
            else { return false }
        }
        return true
    }

    /// Snapshot assemblies run *while* finalize() consumes and frees the same arenas. A chunk
    /// must stay mapped for as long as any snapshot still reads it.
    @Test func finalizeFreesArenasWhileSnapshotsAreStillAssembling() {
        let workerCount = 6
        let perWorker = [20_011, 8192, 0, 17_000, 1, 30_500]  // partial, exact, empty, …
        let builder = FileTree.Builder(rootPath: "/stress")
        let workers = (0 ..< workerCount).map { _ in builder.makeWorker() }

        // Snapshots racing with the appends.
        let done = Mutex(false)
        let issues = Mutex([String]())
        let racing = Thread {
            while !done.withLock({ $0 }) {
                let partial = builder.snapshot()
                let found = invariantViolations(partial)
                if !found.isEmpty { issues.withLock { $0.append(contentsOf: found) } }
            }
        }
        racing.start()
        DispatchQueue.concurrentPerform(iterations: workerCount) { w in
            Self.feed(workers[w], index: w, entries: perWorker[w], builder: builder)
        }
        done.withLock { $0 = true }
        while !racing.isFinished { usleep(500) }

        // Reference: the same content fed single-threaded (NodeIDs depend only on the worker).
        let referenceBuilder = FileTree.Builder(rootPath: "/stress")
        let referenceWorkers = (0 ..< workerCount).map { _ in referenceBuilder.makeWorker() }
        for w in 0 ..< workerCount {
            Self.feed(referenceWorkers[w], index: w, entries: perWorker[w], builder: referenceBuilder)
        }
        let reference = referenceBuilder.finalize()
        #expect(reference.count == 1 + perWorker.reduce(0, +))
        #expect(invariantViolations(reference).isEmpty)

        // Capture several snapshots up front, then assemble them concurrently with finalize().
        let snapshots = 5
        let captures = (0 ..< snapshots).map { _ in builder.capture(final: false) }
        let results = Mutex([FileTree?](repeating: nil, count: snapshots + 1))
        DispatchQueue.concurrentPerform(iterations: snapshots + 1) { i in
            let tree: FileTree
            if i == snapshots {
                tree = builder.finalize()
            } else {
                // Repeated passes over the same shared chunks keep readers busy during the frees.
                tree = Assembler.assemble(
                    rootPath: builder.rootPath, rootFlags: captures[i].1, rootModified: 0, captures: captures[i].0)
            }
            results.withLock { $0[i] = tree }
        }
        let trees = results.withLock { $0 }.compactMap { $0 }
        #expect(trees.count == snapshots + 1)
        for tree in trees { #expect(Self.sameTree(tree, reference)) }
        #expect(issues.withLock { $0 } == [])

        // Patches made it (applied after the entry chunks were released).
        let final = trees[snapshots]
        #expect(final.flags(of: final.id("w0-dir0")).contains(.unreadable))
        #expect(!final.flags(of: final.id("w0-dir400")).contains(.unreadable))
        #expect(final.childCount(of: final.id("w4-dir0")) == 0)
    }
}

// MARK: - Builder: names at chunk boundaries

@Suite struct BuilderNameChunkTests {
    @Test func emptyNameAsFirstEntry() {
        let builder = FileTree.Builder(rootPath: "/r")
        let worker = builder.makeWorker()
        worker.append(to: .root, name: "", allocatedSize: 3, logicalSize: 3, modified: 0)
        #expect(builder.snapshot().count == 2)
        let tree = builder.finalize()
        #expect(tree.count == 2)
        #expect(tree.name(of: 1) == "" && tree.size(of: 0) == 3)
        #expect(invariantViolations(tree).isEmpty)
    }

    @Test(arguments: [false, true]) func emptyNameRightAfterAnExactlyFullNameChunk(followUp: Bool) {
        let builder = FileTree.Builder(rootPath: "/r")
        let worker = builder.makeWorker()
        // 16 names of 4096 bytes fill one 64 KiB name chunk exactly.
        let long = (0 ..< 16).map { i in String(repeating: Character(UnicodeScalar(UInt8(0x61 + i))), count: 4096) }
        for name in long { worker.append(to: .root, name: name, allocatedSize: 1, logicalSize: 1, modified: 0) }
        worker.append(to: .root, name: "", allocatedSize: 1, logicalSize: 1, modified: 0)
        if followUp { worker.append(to: .root, name: "after.txt", allocatedSize: 1, logicalSize: 1, modified: 0) }

        let expected = long + [""] + (followUp ? ["after.txt"] : [])
        for tree in [builder.snapshot(), builder.finalize()] {
            #expect(tree.count == expected.count + 1)
            #expect((1 ..< tree.count).map { tree.name(of: NodeID($0)) } == expected)
            #expect(invariantViolations(tree).isEmpty)
        }
    }
}

// MARK: - Kinds: extensionless executables

@Suite struct ExecutableKindTests {
    @Test func executableHintClassifiesExtensionlessFilesOnly() {
        let builder = FileTree.Builder(rootPath: "/r")
        let w = builder.makeWorker()
        func add(_ name: String, exec: Bool, flags: NodeFlags = [], to parent: FileTree.Builder.Ref = .root) -> FileTree.Builder.Ref {
            w.append(to: parent, name: name, allocatedSize: 10, logicalSize: 10, modified: 0, flags: flags, isExecutable: exec)
        }
        let bin = add("bin", exec: true, flags: .directory)
        _ = add("tool", exec: true, to: bin)
        _ = add("XUL", exec: true, to: bin)
        _ = add("README", exec: false)
        _ = add("photo.jpg", exec: true)  // exFAT/SMB: everything is +x, known extensions win
        _ = add("data.xyz", exec: true)
        _ = add("log.1", exec: true)  // digits only: no usable extension
        _ = add("link", exec: true, flags: .symlink)
        _ = add("dup", exec: true, flags: .hardLinkDuplicate)
        _ = add("cloud", exec: true, flags: .dataless)
        let tree = builder.finalize()

        func kind(_ path: String) -> FileKind { tree.fileKind(of: tree.id(path)) }
        #expect(kind("bin/tool").isUnixExecutable)
        #expect(kind("bin/tool").category == .application)
        #expect(kind("bin/tool").displayName == "Unix Executable")
        #expect(tree.kind(of: tree.id("bin/tool")) == tree.kind(of: tree.id("bin/XUL")))
        #expect(kind("README").ext == "" && kind("README").category == .other)
        #expect(kind("photo.jpg").ext == "jpg" && kind("photo.jpg").category == .image)
        #expect(kind("data.xyz").ext == "xyz")
        #expect(kind("log.1").isUnixExecutable)
        #expect(kind("link").ext == "")  // symlinks are never executables
        #expect(kind("dup").isUnixExecutable && kind("cloud").isUnixExecutable)
        #expect(tree.kind(of: tree.id("bin")) == 0)  // directories have no kind
        // The hint is not a node flag.
        #expect(tree.flags(of: tree.id("bin/tool")) == [])
        #expect(tree.flags(of: tree.id("bin")) == .directory)
        #expect(tree.kinds[0].ext == "")
        #expect(tree.kindID(forExtension: FileKind.unixExecutableExtension) == tree.kind(of: tree.id("bin/tool")))

        let stats = tree.kindSummary()
        let exec = stats.first { $0.isUnixExecutable }
        #expect(exec?.category == .application && exec?.fileCount == 5 && exec?.displayName == "Unix Executable")
        #expect(tree.categorySummary().first { $0.category == .application }?.fileCount == 5)
        #expect(tree.search(SearchQuery(categories: [.application])).totalMatches == 5)
        #expect(tree.kindDescription(of: tree.id("bin/tool")) == "Unix executable")
        #expect(tree.kindDescription(of: tree.id("README")) == "File")
    }

    @Test func rescanKeepsExecutableKind() {
        var tree = FileTree.make(rootPath: "/r", [.dir("bin", [.file("old", 1, isExecutable: true)]), .file("notes", 2)])
        let rescanned = FileTree.make(rootPath: "/r/bin", [.file("tool", 5, isExecutable: true), .file("plain", 1)])
        tree.replaceSubtree(at: tree.id("bin"), with: rescanned)
        #expect(tree.fileKind(of: tree.id("bin/tool")).isUnixExecutable)
        #expect(tree.fileKind(of: tree.id("bin/plain")).ext == "")
        #expect(tree.kinds.filter(\.isUnixExecutable).count == 1)
        #expect(invariantViolations(tree).isEmpty)

        // …and a tree that never had one learns the kind from the graft.
        var plain = FileTree.make(rootPath: "/r", [.dir("bin"), .file("notes", 2)])
        plain.replaceSubtree(at: plain.id("bin"), with: rescanned)
        #expect(plain.category(of: plain.id("bin/tool")) == .application)
    }

    @Test func kindDescriptions() {
        let tree = FileTree.make(rootPath: "/r", [
            .dir("Code.app", [.file("x", 1)]), .dir("Photos.photoslibrary", [.file("y", 1)]),
            .dir("Folder", [.file("z", 1)]), .dir("Vol", flags: .mountPoint),
            .file("pic.PNG", 1), .file("main.swift", 1), .file("mystery.qqq", 1), .file("LICENSE", 1),
            .file("alias", 1, flags: .symlink), .file("run", 1, isExecutable: true),
        ])
        func describe(_ path: String) -> String { tree.kindDescription(of: tree.id(path)) }
        #expect(describe("Code.app") == "Application (.app)")
        #expect(describe("Photos.photoslibrary") == "Image package (.photoslibrary)")
        #expect(describe("Folder") == "Folder")
        #expect(describe("Vol") == "Volume")
        #expect(describe("pic.PNG") == "Image (.png)")
        #expect(describe("main.swift") == "Source Code (.swift)")
        #expect(describe("mystery.qqq") == "File (.qqq)")
        #expect(describe("LICENSE") == "File")
        #expect(describe("alias") == "Symbolic link")
        #expect(describe("run") == "Unix executable")
        #expect(tree.kindDescription(of: 0) == "Folder")
    }
}

// MARK: - Paths of names that are not valid UTF-8

@Suite struct LossyPathTests {
    @Test func invalidUTF8NamesAreDetectedAndKeepExactBytes() {
        let raw: [UInt8] = [0x66, 0xFF, 0x6F, 0x2E, 0x74, 0x78, 0x74]  // "f\xFFo.txt"
        let builder = FileTree.Builder(rootPath: "/R")
        let w = builder.makeWorker()
        func add(_ bytes: [UInt8], to parent: FileTree.Builder.Ref, dir: Bool = false) -> FileTree.Builder.Ref {
            bytes.withUnsafeBufferPointer {
                w.append(to: parent, name: $0, allocatedSize: 10, logicalSize: 10, modified: 0, flags: dir ? .directory : [])
            }
        }
        _ = add(raw, to: .root)
        let badDir = add([0x64, 0xC3], to: .root, dir: true)  // truncated sequence
        _ = add(Array("inner.txt".utf8), to: badDir)
        let goodDir = add(Array("Über 日本".utf8), to: .root, dir: true)
        _ = add(Array("ok.txt".utf8), to: goodDir)
        let tree = builder.finalize()

        let lossy = tree.children(of: 0).first { tree.nameUTF8(of: $0).elementsEqual(raw) }!
        let dir = tree.children(of: 0).first { tree.nameUTF8(of: $0).elementsEqual([0x64, 0xC3]) }!
        let inner = tree.children(of: dir).first!
        let ok = tree.id("Über 日本/ok.txt")

        #expect(tree.hasLossyPath(lossy))
        #expect(tree.hasLossyPath(dir) && tree.hasLossyPath(inner))  // below a lossy directory
        #expect(!tree.hasLossyPath(ok) && !tree.hasLossyPath(tree.id("Über 日本")) && !tree.hasLossyPath(0))

        #expect(tree.path(of: lossy) == "/R/f\u{FFFD}o.txt")  // display only
        #expect(tree.fileSystemPath(of: lossy) == Array("/R/".utf8) + raw)
        #expect(tree.fileSystemPath(of: inner) == Array("/R/".utf8) + [0x64, 0xC3] + Array("/inner.txt".utf8))
        #expect(tree.fileSystemPath(of: ok) == Array(tree.path(of: ok).utf8))
        #expect(tree.fileSystemPath(of: 0) == Array("/R".utf8))

        // The URL names the real entry, not the U+FFFD spelling.
        func bytes(_ url: URL) -> [UInt8] {
            url.withUnsafeFileSystemRepresentation { pointer in
                guard let pointer else { return [] }
                return Array(UnsafeBufferPointer(start: pointer, count: strlen(pointer))).map { UInt8(bitPattern: $0) }
            }
        }
        #expect(bytes(tree.url(of: lossy)) == Array("/R/".utf8) + raw)
        #expect(bytes(tree.url(of: inner)) == Array("/R/".utf8) + [0x64, 0xC3] + Array("/inner.txt".utf8))
        #expect(tree.url(of: ok).path == "/R/Über 日本/ok.txt")
        #expect(tree.url(of: ok) == URL(fileURLWithPath: "/R/Über 日本/ok.txt", isDirectory: false))
    }

    @Test func rootSlashPaths() {
        let tree = FileTree.make(rootPath: "/", [.dir("usr", [.file("x", 1)])])
        #expect(tree.fileSystemPath(of: 0) == [0x2F])
        #expect(tree.fileSystemPath(of: tree.node(atPath: "/usr/x")!) == Array("/usr/x".utf8))
    }
}

// MARK: - Tombstones

@Suite struct TombstoneTests {
    @Test func removedDirectoriesListNoChildren() {
        var tree = FileTree.make(rootPath: "/R", [
            .dir("d", [.file("a", 10), .dir("e", [.file("b", 5)])]), .file("keep", 1),
        ])
        let (d, a, e, b) = (tree.id("d"), tree.id("d/a"), tree.id("d/e"), tree.id("d/e/b"))
        let freed = tree.remove(d)
        #expect(freed == FileTree.Totals(allocated: 15, logical: 15, fileCount: 2))
        #expect(tree.totals(of: 0) == FileTree.Totals(allocated: 1, logical: 1, fileCount: 1))
        for node in [d, a, e, b] {
            #expect(tree.isRemoved(node))
            #expect(tree.children(of: node).isEmpty && tree.childCount(of: node) == 0)
        }
        var visited = 0
        tree.forEachDescendant(of: d) { _ in visited += 1 }
        tree.forEachDescendant(of: e) { _ in visited += 1 }
        #expect(visited == 0)
        #expect(tree.childNames(0) == ["keep"])
        // Tombstones still know where they were.
        #expect(tree.parent(of: b) == e && tree.path(of: b) == "/R/d/e/b")
        #expect(invariantViolations(tree).isEmpty)
    }

    @Test func oldSubdirectoriesUnderAGraftListNoChildren() {
        var tree = FileTree.make(rootPath: "/R", [.dir("d", [.file("a", 10), .dir("e", [.file("b", 5)])])])
        let (d, a, e, b) = (tree.id("d"), tree.id("d/a"), tree.id("d/e"), tree.id("d/e/b"))
        tree.replaceSubtree(at: d, with: FileTree.make(rootPath: "/R/d", [.dir("new", [.file("n", 3)])]))
        for node in [a, e, b] {
            #expect(tree.isRemoved(node) && tree.children(of: node).isEmpty && tree.childCount(of: node) == 0)
        }
        #expect(!tree.isRemoved(d) && tree.childNames(d) == ["new"])
        var names: [String] = []
        tree.forEachDescendant(of: d) { names.append(tree.name(of: $0)) }
        #expect(names == ["new", "n"])
        #expect(invariantViolations(tree).isEmpty)
    }
}

// MARK: - Hard links across mutations

@Suite struct HardLinkMutationTests {
    static let inode = FileTree.LinkID(device: 1, inode: 4242)
    static let big: UInt64 = 4_194_304

    /// /R/A/big.bin is the counted link, /R/B/link.bin the duplicate, plus B/small.txt (4096).
    static func fixture() -> FileTree {
        FileTree.make(rootPath: "/R", [
            .dir("A", [.file("big.bin", big, logical: big - 4, link: inode)]),
            .dir("B", [
                .file("link.bin", big, logical: big - 4, flags: .hardLinkDuplicate, link: inode),
                .file("small.txt", 4096),
            ]),
        ])
    }

    @Test func builderRecordsLinkIdentity() {
        let tree = Self.fixture()
        #expect(tree.size(of: 0) == Self.big + 4096)
        #expect(tree.linkID(of: tree.id("A/big.bin")) == Self.inode)
        #expect(tree.linkID(of: tree.id("B/link.bin")) == Self.inode)
        #expect(tree.linkID(of: tree.id("B/small.txt")) == nil && tree.linkID(of: tree.id("A")) == nil)
        #expect(tree.linkedFileCount == 2)
        #expect(tree.size(of: tree.id("B/link.bin")) == 0)
        #expect(invariantViolations(tree).isEmpty)

        // Snapshots carry the identities too.
        let builder = FileTree.Builder(rootPath: "/R")
        let w = builder.makeWorker()
        w.append(to: .root, name: "one", allocatedSize: 8, logicalSize: 8, modified: 0, link: Self.inode)
        let partial = builder.snapshot()
        w.append(to: .root, name: "two", allocatedSize: 8, logicalSize: 8, modified: 0, flags: .hardLinkDuplicate, link: Self.inode)
        // A directory never keeps a link identity.
        w.append(to: .root, name: "dir", allocatedSize: 0, logicalSize: 0, modified: 0, flags: .directory, link: Self.inode)
        #expect(partial.linkedFileCount == 1)
        #expect(builder.finalize().linkedFileCount == 2)
    }

    @Test func removingTheCountedLinkMovesTheSizeToTheSurvivor() {  // (a)
        var tree = Self.fixture()
        let (a, b, link) = (tree.id("A"), tree.id("B"), tree.id("B/link.bin"))
        let root = tree.totals(of: 0)
        let freed = tree.remove(a)
        #expect(freed == FileTree.Totals(allocated: 0, logical: 0, fileCount: 1))  // one name gone, no bytes
        #expect(tree.size(of: 0) == root.allocated && tree.logicalSize(of: 0) == root.logical)
        #expect(tree.size(of: link) == Self.big && tree.logicalSize(of: link) == Self.big - 4)
        #expect(!tree.flags(of: link).contains(.hardLinkDuplicate))
        #expect(tree.size(of: b) == Self.big + 4096)
        #expect(tree.childNames(b) == ["link.bin", "small.txt"])  // re-sorted: the link now leads
        #expect(tree.childNames(0) == ["B"])
        #expect(tree.linkedFileCount == 1)
        #expect(invariantViolations(tree).isEmpty)

        // Removing the file itself (not its folder) behaves the same.
        var other = Self.fixture()
        #expect(other.remove(other.id("A/big.bin")).allocated == 0)
        #expect(other.size(of: 0) == root.allocated && other.size(of: other.id("A")) == 0)
        #expect(invariantViolations(other).isEmpty)
        // …and removing the last link frees the bytes after all.
        #expect(other.remove(other.id("B/link.bin")).allocated == Self.big)
        #expect(other.size(of: 0) == 4096)
        #expect(invariantViolations(other).isEmpty)
    }

    @Test func removingADuplicateChangesNothingElse() {  // (b)
        var tree = Self.fixture()
        let big = tree.id("A/big.bin")
        let freed = tree.remove(tree.id("B"))
        #expect(freed == FileTree.Totals(allocated: 4096, logical: 4096, fileCount: 2))
        #expect(tree.size(of: big) == Self.big && !tree.flags(of: big).contains(.hardLinkDuplicate))
        #expect(tree.size(of: 0) == Self.big)
        #expect(invariantViolations(tree).isEmpty)
    }

    @Test func rescanningTheDuplicateSideDoesNotDoubleCount() {  // (c)
        var tree = Self.fixture()
        let root = tree.totals(of: 0)
        // Scanned on its own, B sees the inode for the first time and counts it.
        let rescanned = FileTree.make(rootPath: "/R/B", [
            .file("link.bin", Self.big, logical: Self.big - 4, link: Self.inode), .file("small.txt", 4096),
        ])
        #expect(rescanned.size(of: 0) == Self.big + 4096)
        let b = tree.id("B")
        let change = tree.replaceSubtree(at: b, with: rescanned)
        #expect(change.before == change.after)
        #expect(change.after.allocated == 4096)
        #expect(tree.totals(of: 0) == root)
        let link = tree.id("B/link.bin")
        #expect(tree.size(of: link) == 0 && tree.flags(of: link).contains(.hardLinkDuplicate))
        #expect(tree.size(of: tree.id("A/big.bin")) == Self.big)  // nodes outside the folder are untouched
        #expect(tree.childNames(b) == ["small.txt", "link.bin"])
        #expect(invariantViolations(tree).isEmpty)

        // Rescanning the counted side: the fresh node is the only counted link again.
        let a = tree.id("A")
        let again = tree.replaceSubtree(
            at: a, with: FileTree.make(rootPath: "/R/A", [.file("big.bin", Self.big, logical: Self.big - 4, link: Self.inode)]))
        #expect(again.before == again.after && tree.totals(of: 0) == root)
        #expect(invariantViolations(tree).isEmpty)
    }

    @Test func rescanWithoutTheCountedLinkPromotesTheSurvivor() {  // (d)
        var tree = Self.fixture()
        let root = tree.totals(of: 0)
        let change = tree.replaceSubtree(at: tree.id("A"), with: FileTree.empty(rootPath: "/R/A"))
        #expect(change.before.allocated == Self.big && change.after.allocated == 0)
        let link = tree.id("B/link.bin")
        #expect(tree.size(of: link) == Self.big && !tree.flags(of: link).contains(.hardLinkDuplicate))
        #expect(tree.size(of: 0) == root.allocated)  // the inode is still on disk
        #expect(tree.fileCount(of: 0) == root.fileCount - 1)
        #expect(tree.childNames(0) == ["B", "A"])
        #expect(invariantViolations(tree).isEmpty)
    }

    @Test func removingAllLinksTogetherFreesTheInodeOnce() {  // (e)
        for order in [["A", "B"], ["B", "A"]] {
            var tree = Self.fixture()
            let freed = tree.remove(order.map { tree.id($0) })
            #expect(freed == FileTree.Totals(allocated: Self.big + 4096, logical: Self.big - 4 + 4096, fileCount: 3))
            #expect(tree.totals(of: 0) == .zero && tree.linkedFileCount == 0)
            #expect(invariantViolations(tree).isEmpty)
        }
    }

    @Test func rescanAtTheRootAndThreeWayLinks() {
        let third = FileTree.Spec.file("third.bin", Self.big, logical: Self.big - 4, flags: .hardLinkDuplicate, link: Self.inode)
        var tree = FileTree.make(rootPath: "/R", [
            .dir("A", [.file("big.bin", Self.big, logical: Self.big - 4, link: Self.inode)]),
            .dir("B", [.file("link.bin", Self.big, logical: Self.big - 4, flags: .hardLinkDuplicate, link: Self.inode)]),
            .dir("C", [third, .file("other.bin", 100, link: FileTree.LinkID(device: 1, inode: 7))]),
        ])
        #expect(invariantViolations(tree).isEmpty)
        tree.remove(tree.id("A"))
        // The lowest-numbered survivor is promoted, and only that one.
        let counted = ["B/link.bin", "C/third.bin"].filter { !tree.flags(of: tree.id($0)).contains(.hardLinkDuplicate) }
        #expect(counted.count == 1)
        #expect(tree.size(of: 0) == Self.big + 100)
        #expect(invariantViolations(tree).isEmpty)

        // A different device with the same inode number is a different file.
        let foreign = FileTree.make(rootPath: "/R/A", [.file("x", 50, link: FileTree.LinkID(device: 2, inode: 4242))])
        tree.replaceSubtree(at: tree.id("B"), with: foreign)
        #expect(tree.size(of: tree.id("B/x")) == 50)
        #expect(tree.size(of: 0) == Self.big + 150)
        #expect(invariantViolations(tree).isEmpty)

        // Replacing everything replaces the link table as well.
        tree.replaceSubtree(at: 0, with: Self.fixture())
        #expect(tree.size(of: 0) == Self.big + 4096 && tree.linkedFileCount == 2)
        #expect(invariantViolations(tree).isEmpty)
    }

    /// Random trees full of hard links, random removals and isolated "rescans" of subfolders in
    /// which every inode is seen afresh — the root total must always equal the bytes of the
    /// distinct inodes still linked somewhere.
    @Test func randomizedMutationsKeepEveryInodeCountedOnce() {
        var rng = SplitMix64(seed: 2027)
        for round in 0 ..< 30 {
            // Folders f0…f5 with files; inode i has size 1000 + i and 1…4 links.
            var folders = [[(name: String, inode: UInt64)]](repeating: [], count: 6)
            for inode in 0 ..< 40 as Range<UInt64> {
                for link in 0 ..< 1 + rng.next() % 4 {
                    folders[Int(rng.next() % 6)].append(("i\(inode)-\(link)", inode))
                }
            }
            func spec(_ files: [(name: String, inode: UInt64)], seen: inout Set<UInt64>) -> [FileTree.Spec] {
                files.map { file in
                    let first = seen.insert(file.inode).inserted
                    return .file(
                        file.name, 1000 + file.inode, flags: first ? [] : .hardLinkDuplicate,
                        link: FileTree.LinkID(device: 9, inode: file.inode))
                }
            }
            var seen = Set<UInt64>()
            var tree = FileTree.make(
                rootPath: "/R", folders.enumerated().map { index, files in .dir("f\(index)", spec(files, seen: &seen)) })

            func expectedTotal() -> UInt64 {
                var live = Set<UInt64>()
                for files in folders { for file in files { live.insert(file.inode) } }
                return live.reduce(0) { $0 + 1000 + $1 }
            }
            #expect(tree.size(of: 0) == expectedTotal())
            for step in 0 ..< 12 {
                let f = Int(rng.next() % 6)
                guard let folder = tree.node(atPath: "/R/f\(f)") else { continue }
                switch rng.next() % 3 {
                case 0:  // trash one file
                    guard !folders[f].isEmpty else { continue }
                    let k = Int(rng.next() % UInt64(folders[f].count))
                    let before = tree.size(of: 0)
                    let freed = tree.remove(tree.id("f\(f)/\(folders[f][k].name)"))
                    folders[f].remove(at: k)
                    #expect(freed.allocated == before - tree.size(of: 0))
                case 1:  // trash the folder
                    tree.remove(folder)
                    folders[f] = []
                default:  // rescan the folder alone, after dropping some of its files
                    folders[f].removeAll { _ in rng.next() % 3 == 0 }
                    var fresh = Set<UInt64>()
                    let replacement = FileTree.make(rootPath: "/R/f\(f)", spec(folders[f], seen: &fresh))
                    let change = tree.replaceSubtree(at: folder, with: replacement)
                    #expect(change.after == tree.totals(of: folder))
                }
                #expect(tree.size(of: 0) == expectedTotal(), "round \(round) step \(step)")
                let issues = invariantViolations(tree)
                #expect(issues.isEmpty, "round \(round) step \(step): \(issues)")
            }
        }
    }
}
