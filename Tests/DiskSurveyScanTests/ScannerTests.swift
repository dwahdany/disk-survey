import Foundation
import Testing
import DiskSurveyCore
@testable import DiskSurveyScan

@Suite struct ScannerTests {
    // MARK: Sizes and structure

    @Test func sizesAndNestingMatchAnIndependentWalk() {
        let fixture = Fixture("sizes")
        fixture.file("a.txt", size: 1)
        fixture.file("b.bin", size: 4096)
        fixture.file("docs/report.pdf", size: 150_000)
        fixture.file("docs/notes/todo.md", size: 12_345)
        fixture.file("docs/notes/deep/er/still.dat", size: 70_000)
        fixture.file("empty-file", size: 0)
        fixture.dir("empty-dir")
        fixture.dir("nested/empty/dirs")

        let result = scan(fixture.path)
        let tree = result.tree
        let reference = ReferenceTotals.walk(fixture.path)

        #expect(result.rootKind == .directory)
        #expect(!result.wasCancelled)
        #expect(result.issues.isEmpty)
        #expect(tree.rootPath == fixture.path)
        #expect(tree.size(of: tree.root) == reference.allocated)
        #expect(tree.logicalSize(of: tree.root) == reference.logical)
        #expect(tree.logicalSize(of: tree.root) == 1 + 4096 + 150_000 + 12_345 + 70_000)
        #expect(tree.fileCount(of: tree.root) == 6)
        #expect(Int(result.stats.files) == reference.files)
        #expect(Int(result.stats.directories) == reference.directories)
        #expect(tree.count == reference.files + reference.directories + 1)
        #expect(tree.invariantViolations().isEmpty)

        let report = try! #require(tree.node("docs/report.pdf"))
        #expect(tree.logicalSize(of: report) == 150_000)
        #expect(tree.size(of: report) >= 150_000)  // whole blocks
        #expect(tree.size(of: report) % 4096 == 0)
        #expect(tree.fileKind(of: report).ext == "pdf")
        #expect(tree.path(of: report) == fixture.path + "/docs/report.pdf")
        #expect(abs(tree.modified(of: report) - Int64(Date().timeIntervalSince1970)) < 300)

        let notes = try! #require(tree.node("docs/notes"))
        #expect(tree.isDirectory(notes))
        #expect(tree.logicalSize(of: notes) == 12_345 + 70_000)
        #expect(tree.fileCount(of: notes) == 2)

        let emptyDir = try! #require(tree.node("empty-dir"))
        #expect(tree.isDirectory(emptyDir) && tree.childCount(of: emptyDir) == 0 && tree.size(of: emptyDir) == 0)
        #expect(tree.node("nested/empty/dirs") != nil)
        let emptyFile = try! #require(tree.node("empty-file"))
        #expect(!tree.isDirectory(emptyFile) && tree.size(of: emptyFile) == 0)

        // The final progress agrees with the result.
        #expect(result.stats.entries == UInt64(tree.count - 1))
        #expect(result.duration > 0)
    }

    @Test func sparseFilesCountWhatTheyOccupy() {
        let fixture = Fixture("sparse")
        let path = fixture.path + "/sparse.img"
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
        ftruncate(fd, 64 << 20)
        close(fd)
        let tree = scan(fixture.path).tree
        let node = try! #require(tree.node("sparse.img"))
        #expect(tree.logicalSize(of: node) == 64 << 20)
        #expect(tree.size(of: node) < 1 << 20)
        #expect(tree.size(of: tree.root) == ReferenceTotals.walk(fixture.path).allocated)
    }

    @Test func packagesAreFlagged() {
        let fixture = Fixture("package")
        fixture.file("Thing.app/Contents/MacOS/thing", size: 10_000)
        fixture.file("Plain/file", size: 10)
        let tree = scan(fixture.path).tree
        #expect(tree.flags(of: try! #require(tree.node("Thing.app"))).contains(.package))
        #expect(!tree.flags(of: try! #require(tree.node("Plain"))).contains(.package))
    }

    // MARK: Links

    @Test func hardLinksAreCountedOnce() {
        let fixture = Fixture("hardlinks")
        let original = fixture.file("a/original.bin", size: 200_000)
        fixture.dir("b")
        fixture.dir("c/d")
        #expect(link(original, fixture.path + "/b/second.bin") == 0)
        #expect(link(original, fixture.path + "/c/d/third.bin") == 0)
        fixture.file("single.bin", size: 50_000)

        for threads in [1, 4] {
            let result = scan(fixture.path) { $0.threadCount = threads }
            let tree = result.tree
            let links = ["a/original.bin", "b/second.bin", "c/d/third.bin"].map { tree.node($0)! }
            let duplicates = links.filter { tree.flags(of: $0).contains(.hardLinkDuplicate) }
            let primaries = links.filter { !tree.flags(of: $0).contains(.hardLinkDuplicate) }
            #expect(duplicates.count == 2)
            #expect(primaries.count == 1)
            #expect(duplicates.allSatisfy { tree.size(of: $0) == 0 && tree.logicalSize(of: $0) == 0 })
            #expect(tree.logicalSize(of: primaries[0]) == 200_000)
            #expect(tree.logicalSize(of: tree.root) == 250_000)
            #expect(tree.size(of: tree.root) == ReferenceTotals.walk(fixture.path).allocated)
            #expect(tree.fileCount(of: tree.root) == 4)  // every name is still an item
            #expect(result.stats.hardLinkDuplicates == 2)
            #expect(!tree.flags(of: tree.node("single.bin")!).contains(.hardLinkDuplicate))
        }
    }

    /// Every name of a multiply-linked file carries the inode's identity, so partial rescans
    /// keep counting the file exactly once, whichever folder is rescanned.
    @Test func rescanningEitherSideOfAHardLinkKeepsTheTotal() throws {
        let fixture = Fixture("hardlink-rescan")
        let big = fixture.file("A/big.bin", size: 300_000)
        fixture.file("A/other.bin", size: 10_000)
        fixture.dir("B")
        #expect(link(big, fixture.path + "/B/link.bin") == 0)
        fixture.file("B/plain.bin", size: 20_000)

        for threads in [1, 4] {
            var tree = scan(fixture.path) { $0.threadCount = threads }.tree
            let total = tree.totals(of: tree.root)
            #expect(total.logical == 330_000)
            let a = try #require(tree.node("A/big.bin"))
            let b = try #require(tree.node("B/link.bin"))
            #expect(tree.linkID(of: a) != nil && tree.linkID(of: a) == tree.linkID(of: b))
            #expect(tree.linkID(of: try #require(tree.node("A/other.bin"))) == nil)
            #expect(tree.linkedFileCount == 2)

            // A scan of one folder alone sees its link as the only one and counts it in full;
            // grafted into the tree, the inode must still be counted once.
            for folder in ["A", "B", "A", "B", "B"] {
                let alone = scan(fixture.path + "/" + folder).tree
                tree.replaceSubtree(at: try #require(tree.node(folder)), with: alone)
                #expect(tree.totals(of: tree.root) == total, "after rescanning \(folder)")
                #expect(tree.invariantViolations().isEmpty)
                let links = [try #require(tree.node("A/big.bin")), try #require(tree.node("B/link.bin"))]
                #expect(links.filter { tree.flags(of: $0).contains(.hardLinkDuplicate) }.count == 1)
                #expect(links.map { tree.logicalSize(of: $0) }.sorted() == [0, 300_000])
            }
        }
    }

    // MARK: Executables

    /// Files without an extension that have an execute bit get the "Unix Executable" kind, on
    /// both enumeration paths; an extension wins over the bit, and directories and symlinks
    /// are never executables.
    @Test(arguments: [true, false])
    func extensionlessExecutablesGetTheirOwnKind(bulk: Bool) throws {
        let fixture = Fixture("executables")
        fixture.file("bin/tool", size: 5000)
        fixture.file("notes", size: 100)
        fixture.file("a.jpg", size: 3000)
        fixture.dir("folder")
        #expect(chmod(fixture.path + "/bin/tool", 0o755) == 0)
        #expect(chmod(fixture.path + "/notes", 0o644) == 0)
        #expect(chmod(fixture.path + "/a.jpg", 0o755) == 0)
        #expect(symlink("bin/tool", fixture.path + "/shortcut") == 0)

        let result = scan(fixture.path) { $0.useBulkAttributes = bulk }
        let tree = result.tree
        #expect(result.stats.fallbackDirectories > 0 || bulk)
        let tool = tree.fileKind(of: try #require(tree.node("bin/tool")))
        #expect(tool.isUnixExecutable && tool.category == .application)
        #expect(tree.kindDescription(of: try #require(tree.node("bin/tool"))) == "Unix executable")
        let notes = tree.fileKind(of: try #require(tree.node("notes")))
        #expect(!notes.isUnixExecutable && notes.ext.isEmpty)
        let picture = tree.fileKind(of: try #require(tree.node("a.jpg")))
        #expect(picture.ext == "jpg" && picture.category == .image)
        // Directories are searchable (0755) and symlinks are 0755 too: neither is an executable.
        #expect(!tree.fileKind(of: try #require(tree.node("folder"))).isUnixExecutable)
        #expect(!tree.fileKind(of: try #require(tree.node("bin"))).isUnixExecutable)
        #expect(!tree.fileKind(of: try #require(tree.node("shortcut"))).isUnixExecutable)
        // Sizes are untouched by the extra attribute in the bulk request.
        #expect(tree.logicalSize(of: tree.root) == 8100 + UInt64("bin/tool".utf8.count))
    }

    @Test func symlinksAreRecordedButNeverFollowed() {
        let fixture = Fixture("symlinks")
        fixture.file("real/big.bin", size: 300_000)
        #expect(symlink(fixture.path + "/real", fixture.path + "/link-to-dir") == 0)
        #expect(symlink("real/big.bin", fixture.path + "/link-to-file") == 0)
        #expect(symlink("/nonexistent/target", fixture.path + "/dangling") == 0)
        #expect(symlink(".", fixture.path + "/real/loop") == 0)

        let result = scan(fixture.path)
        let tree = result.tree
        for name in ["link-to-dir", "link-to-file", "dangling", "real/loop"] {
            let node = try! #require(tree.node(name))
            #expect(tree.flags(of: node).contains(.symlink))
            #expect(!tree.isDirectory(node))
            #expect(tree.childCount(of: node) == 0)
            #expect(tree.size(of: node) < 4096 * 2)
        }
        #expect(tree.logicalSize(of: tree.node("real")!) == 300_000 + 1)  // big.bin + the 1-byte link "."
        #expect(result.stats.symlinks == 4)
        #expect(tree.size(of: tree.root) == ReferenceTotals.walk(fixture.path).allocated)
        #expect(result.issues.isEmpty)
    }

    @Test func aSymlinkedRootIsResolved() {
        let fixture = Fixture("rootlink")
        fixture.file("target/inner/file.txt", size: 5000)
        let linkPath = fixture.path + "/alias"
        #expect(symlink(fixture.path + "/target", linkPath) == 0)

        let result = scan(linkPath)
        #expect(result.rootKind == .directory)
        #expect(result.resolvedRootPath == fixture.path + "/target")
        #expect(result.tree.rootPath == fixture.path + "/target")
        #expect(result.tree.node("inner/file.txt") != nil)
        #expect(result.tree.logicalSize(of: result.tree.root) == 5000)
    }

    // MARK: Roots that are not readable directories

    @Test func aFileRootYieldsItsParentWithOneChild() {
        let fixture = Fixture("fileroot")
        let path = fixture.file("only.dat", size: 123_456)
        fixture.file("sibling.dat", size: 999)

        let result = scan(path)
        let tree = result.tree
        #expect(result.rootKind == .file)
        #expect(result.resolvedRootPath == path)
        #expect(tree.rootPath == fixture.path)
        #expect(tree.childCount(of: tree.root) == 1)
        let node = tree.child(of: tree.root, at: 0)
        #expect(tree.name(of: node) == "only.dat")
        #expect(tree.logicalSize(of: node) == 123_456)
        #expect(tree.size(of: tree.root) == tree.size(of: node))
        #expect(tree.path(of: node) == path)
        #expect(result.issues.isEmpty)
    }

    @Test func aMissingRootIsReportedNotThrown() {
        let result = scan("/nonexistent-\(UUID().uuidString)/nothing")
        #expect(result.rootKind == .inaccessible)
        #expect(result.tree.flags(of: result.tree.root).contains(.unreadable))
        #expect(result.tree.count == 1)
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.errno == ENOENT)
        #expect(result.issues.first?.kind == .other)
        #expect(result.totalIssueCount == 1)
    }

    @Test(.enabled(if: getuid() != 0, "root can read everything"))
    func unreadableDirectoriesAreKeptAndReported() {
        let fixture = Fixture("unreadable")
        fixture.file("ok/visible.txt", size: 8000)
        fixture.file("locked/secret.txt", size: 8000)
        chmod(fixture.path + "/locked", 0o000)

        let session = ScanSession(root: fixture.url)
        session.start()
        let result = session.waitBlocking()
        let tree = result.tree
        let locked = try! #require(tree.node("locked"))
        #expect(tree.flags(of: locked).contains(.unreadable))
        #expect(tree.isDirectory(locked))
        #expect(tree.childCount(of: locked) == 0)
        #expect(tree.node("ok/visible.txt") != nil)
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.path == fixture.path + "/locked")
        #expect(result.issues.first?.kind == .permissionDenied)
        #expect(result.issues.first?.errno == EACCES)
        #expect(result.totalIssueCount == 1)
        #expect(result.permissionDeniedCount == 1)
        #expect(session.progress.errorCount == 1)
        #expect(!result.wasCancelled)
    }

    @Test(.enabled(if: getuid() != 0, "root can read everything"))
    func anUnreadableRootIsFlagged() {
        let fixture = Fixture("unreadable-root")
        fixture.file("inner/file", size: 10)
        chmod(fixture.path + "/inner", 0o000)
        let result = scan(fixture.path + "/inner")
        #expect(result.rootKind == .directory)
        #expect(result.tree.flags(of: result.tree.root).contains(.unreadable))
        #expect(result.issues.first?.kind == .permissionDenied)
        #expect(result.tree.count == 1)
    }

    // MARK: Names and shapes

    @Test func unicodeAndLongNamesSurvive() {
        let fixture = Fixture("names")
        let longName = String(repeating: "x", count: 251) + ".txt"  // NAME_MAX is 255 bytes
        let names = [
            "Übergröße.txt", "日本語のファイル.md", "emoji 🧩🗂️.png", "cafe\u{301}.txt",  // decomposed é
            "spaces and (parens) [brackets].txt", "trailing.dot.", ".hidden", "new\nline.txt", longName,
        ]
        for (index, name) in names.enumerated() { fixture.file("dir é/" + name, size: 100 + index) }

        for bulk in [true, false] {
            let tree = scan(fixture.path) { $0.useBulkAttributes = bulk }.tree
            let dir = try! #require(tree.node("dir é"))
            #expect(tree.childCount(of: dir) == names.count)
            for (index, name) in names.enumerated() {
                let node = try! #require(tree.child(of: dir, named: name), "missing \(name.debugDescription)")
                #expect(tree.logicalSize(of: node) == UInt64(100 + index))
                // The stored bytes are exactly what the filesystem holds.
                var info = stat()
                #expect(lstat(tree.path(of: node), &info) == 0)
            }
            #expect(tree.fileKind(of: tree.child(of: dir, named: "emoji 🧩🗂️.png")!).ext == "png")
        }
    }

    @Test func treesDeeperThanPathMaxAreScanned() {
        let fixture = Fixture("deep")
        // 300 levels of 40-byte names: about 12,000 bytes of path, far beyond PATH_MAX (1024).
        let component = String(repeating: "d", count: 40)
        let depth = 300
        var fd = open(fixture.path, O_RDONLY | O_DIRECTORY)
        for level in 0 ..< depth {
            #expect(mkdirat(fd, component, 0o755) == 0)
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY)
            close(fd)
            fd = next
            if level % 50 == 49 || level == depth - 1 {
                let file = openat(fd, "marker-\(level).txt", O_WRONLY | O_CREAT, 0o644)
                #expect(write(file, "hello", 5) == 5)
                close(file)
            }
        }
        close(fd)

        for bulk in [true, false] {
            let result = scan(fixture.path) {
                $0.useBulkAttributes = bulk
                $0.threadCount = 3
            }
            let tree = result.tree
            #expect(result.issues.isEmpty)
            #expect(result.stats.directories == UInt64(depth))
            #expect(tree.fileCount(of: tree.root) == 6)
            #expect(tree.logicalSize(of: tree.root) == 30)
            // Walk down to the bottom and find the last marker there.
            var node = tree.root
            var levels = 0
            while let next = tree.child(of: node, named: component) {
                node = next
                levels += 1
            }
            #expect(levels == depth)
            #expect(tree.child(of: node, named: "marker-\(depth - 1).txt") != nil)
            #expect(tree.path(of: node).utf8.count > 12_000)
        }
    }

    @Test func aDirectoryWithAHundredThousandFiles() {
        let fixture = Fixture("many")
        let count = 100_000
        let dirPath = fixture.dir("big")
        let dirFD = open(dirPath, O_RDONLY | O_DIRECTORY)
        for index in 0 ..< count {
            let fd = openat(dirFD, "file-\(index).dat", O_WRONLY | O_CREAT, 0o644)
            precondition(fd >= 0)
            if index % 1000 == 0 { _ = write(fd, "0123456789", 10) }
            close(fd)
        }
        close(dirFD)

        for bulk in [true, false] {
            let result = scan(fixture.path) { $0.useBulkAttributes = bulk }
            let tree = result.tree
            let big = try! #require(tree.node("big"))
            #expect(tree.childCount(of: big) == count)
            #expect(tree.fileCount(of: tree.root) == count)
            #expect(tree.logicalSize(of: tree.root) == UInt64(count / 1000 * 10))
            #expect(tree.child(of: big, named: "file-0.dat") != nil)
            #expect(tree.child(of: big, named: "file-\(count - 1).dat") != nil)
            #expect(Set(tree.children(of: big).map { tree.name(of: $0) }).count == count)
            #expect(result.stats.fallbackDirectories == (bulk ? 0 : 2))
            #expect(result.stats.enumerationDuration > 0 && result.stats.assemblyDuration > 0)
        }
    }

    // MARK: Options

    @Test func theFallbackEnumerationAgreesWithBulkAttributes() {
        let fixture = Fixture("fallback")
        for directory in 0 ..< 20 {
            for file in 0 ..< 30 { fixture.file("d\(directory)/sub\(file % 3)/f\(file).bin", size: file * 977) }
        }
        let original = fixture.path + "/d0/sub0/f0.bin"
        #expect(link(original, fixture.path + "/d1/hard") == 0)
        #expect(symlink("d2", fixture.path + "/soft") == 0)

        let bulk = scan(fixture.path)
        let fallback = scan(fixture.path) { $0.useBulkAttributes = false }
        #expect(bulk.stats.fallbackDirectories == 0)
        #expect(fallback.stats.fallbackDirectories == bulk.stats.directories + 1)
        #expect(bulk.tree.count == fallback.tree.count)
        #expect(bulk.tree.size(of: 0) == fallback.tree.size(of: 0))
        #expect(bulk.tree.logicalSize(of: 0) == fallback.tree.logicalSize(of: 0))
        #expect(bulk.stats.symlinks == 1 && fallback.stats.symlinks == 1)
        #expect(bulk.stats.hardLinkDuplicates == 1 && fallback.stats.hardLinkDuplicates == 1)
        // Same nodes, same attributes (ids differ between scans, so compare by path).
        func listing(_ tree: FileTree) -> [String] {
            var lines: [String] = []
            tree.forEachDescendant(of: tree.root) { id in
                let flags = tree.flags(of: id).subtracting(.hardLinkDuplicate)
                let sized = !tree.flags(of: id).contains(.hardLinkDuplicate) && !tree.isDirectory(id)
                lines.append(
                    "\(tree.path(of: id)) \(flags.rawValue) \(tree.modified(of: id)) \(sized ? tree.size(of: id) : 0)")
            }
            return lines.sorted()
        }
        let a = listing(bulk.tree).filter { !$0.contains("/hard ") && !$0.contains("/f0.bin ") }
        let b = listing(fallback.tree).filter { !$0.contains("/hard ") && !$0.contains("/f0.bin ") }
        #expect(a == b)
    }

    @Test func excludedPathsAreLeftOut() {
        let fixture = Fixture("excluded")
        fixture.file("keep/a.txt", size: 1000)
        fixture.file("skip/b.txt", size: 2000)
        fixture.file("keep/skip/c.txt", size: 4000)
        fixture.file("keep/secret.txt", size: 8000)

        let result = scan(fixture.path) {
            $0.excludedPaths = [fixture.path + "/skip/", fixture.path + "/keep/secret.txt", "relative/ignored"]
        }
        let tree = result.tree
        #expect(tree.node("skip") == nil)
        #expect(tree.node("keep/secret.txt") == nil)
        #expect(tree.node("keep/skip/c.txt") != nil)  // only the exact path is excluded
        #expect(tree.logicalSize(of: tree.root) == 5000)
        #expect(result.stats.excludedEntries == 2)
    }

    @Test func exclusionsMatchInAnySpelling() {
        // The temp dir is reached through /var -> /private/var; scan paths use the resolved form.
        let fixture = Fixture("spelled")
        fixture.file("keep/b", size: 100)
        fixture.file("skip/a", size: 200)
        fixture.file("realdir/skip/c", size: 400)
        fixture.file("realdir/stay/d", size: 800)
        #expect(symlink("realdir", fixture.path + "/link") == 0)
        #expect(symlink("keep", fixture.path + "/alias") == 0)
        #expect(fixture.path.hasPrefix("/private/"))
        let unresolved = String(fixture.path.dropFirst("/private".count))
        let everything = scan(fixture.path)
        #expect(everything.tree.logicalSize(of: 0) > 1500)

        func check(root: String, excluding path: String, gone: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let result = scan(root) { $0.excludedPaths = [path] }
            #expect(result.stats.excludedEntries == 1, "\(root) excluding \(path)", sourceLocation: sourceLocation)
            #expect(result.tree.node(gone) == nil, sourceLocation: sourceLocation)
            #expect(result.tree.count == everything.tree.count - (gone == "skip" || gone == "realdir/skip" ? 2 : 1), sourceLocation: sourceLocation)
            #expect(result.issues.isEmpty, sourceLocation: sourceLocation)
        }
        // Resolved root, exclusion without "/private" (what the app's settings store).
        check(root: fixture.path, excluding: unresolved + "/skip", gone: "skip")
        // Both in the unresolved spelling.
        check(root: unresolved, excluding: unresolved + "/skip/", gone: "skip")
        check(root: unresolved, excluding: fixture.path + "/skip", gone: "skip")
        // Reached through a symlinked directory inside the tree.
        check(root: fixture.path, excluding: fixture.path + "/link/skip", gone: "realdir/skip")
        check(root: fixture.path, excluding: unresolved + "/link/skip", gone: "realdir/skip")
        // A symlink entry itself, in either spelling: naming a symlink to a folder leaves out
        // the link and the folder.
        var result = scan(fixture.path) { $0.excludedPaths = [unresolved + "/alias"] }
        #expect(result.stats.excludedEntries == 2)
        #expect(result.tree.node("alias") == nil && result.tree.node("keep") == nil)

        // Paths that do not exist match nothing and break nothing, whatever part is missing.
        result = scan(fixture.path) {
            $0.excludedPaths = [unresolved + "/nothing/here", "/nonexistent-\(UUID())/x/y", unresolved + "/skip/a/not-a-dir", "/"]
        }
        #expect(result.stats.excludedEntries == 0)
        #expect(result.tree.count == everything.tree.count)

        // The Data volume's own mount point names the same folders a second way.
        let aliased = "/System/Volumes/Data" + fixture.path
        if FileManager.default.fileExists(atPath: aliased + "/skip/a") {
            check(root: aliased, excluding: fixture.path + "/skip", gone: "skip")
            check(root: aliased, excluding: unresolved + "/skip", gone: "skip")
            check(root: aliased, excluding: aliased + "/skip", gone: "skip")
            check(root: fixture.path, excluding: aliased + "/skip", gone: "skip")
        }
    }

    /// With `excludedPathsFollowSymlinks` off, an exclusion names one entry: a link goes, what
    /// it points to stays. The folders leading to the entry are resolved either way.
    @Test func exclusionsCanNameASymlinkWithoutItsTarget() throws {
        let fixture = Fixture("exclude-link")
        fixture.file("real/data.bin", size: 4000)
        fixture.file("log.txt", size: 100)
        #expect(symlink("real", fixture.path + "/dirlink") == 0)
        #expect(symlink("log.txt", fixture.path + "/filelink") == 0)
        let unresolved = NSTemporaryDirectory() + (fixture.path as NSString).lastPathComponent

        for spelling in [fixture.path, unresolved] {
            let following = scan(fixture.path) { $0.excludedPaths = [spelling + "/dirlink", spelling + "/filelink"] }.tree
            #expect(following.node("dirlink") == nil && following.node("real") == nil)
            #expect(following.node("filelink") == nil && following.node("log.txt") == nil)

            let literal = scan(fixture.path) {
                $0.excludedPaths = [spelling + "/dirlink", spelling + "/filelink"]
                $0.excludedPathsFollowSymlinks = false
            }
            #expect(literal.tree.node("dirlink") == nil && literal.tree.node("filelink") == nil)
            #expect(literal.tree.node("real/data.bin") != nil && literal.tree.node("log.txt") != nil)
            #expect(literal.stats.excludedEntries == 2)
        }
    }

    /// How often the app takes a live snapshot: often for small scans, rarely for large ones,
    /// not at all for huge ones (each snapshot is a second copy of the tree).
    @Test func snapshotPacingThinsOutAsTheTreeGrows() {
        typealias S = ScanSession
        #expect(S.snapshotDelay(entries: 0, lastCost: 0) == 0.6)
        #expect(S.snapshotDelay(entries: 500_000, lastCost: 0.01) == 0.6)
        #expect(S.snapshotDelay(entries: 500_000, lastCost: 0.2) == 1.6)        // eight times the cost
        #expect(S.snapshotDelay(entries: 1_000_000, lastCost: 5) == 3)          // capped
        #expect(S.snapshotDelay(entries: S.snapshotComfortableEntries, lastCost: 0.1) == 0.8)
        #expect(S.snapshotDelay(entries: 2_000_000, lastCost: 0.2) == 4)        // two seconds per million
        #expect(S.snapshotDelay(entries: 1_500_000, lastCost: 0.1) == 3)
        #expect(S.snapshotDelay(entries: S.snapshotEntryLimit, lastCost: 0.5) == 4)
        #expect(S.snapshotDelay(entries: 3_500_000, lastCost: 0.4) == nil)
        #expect(S.snapshotDelay(entries: S.snapshotEntryLimit + 1, lastCost: 0.5) == nil)
        #expect(S.snapshotDelay(entries: 50_000_000, lastCost: 0) == nil)
        // Never shorter for a larger tree at the same cost.
        var previous = 0.0
        for entries in stride(from: UInt64(0), through: S.snapshotEntryLimit, by: 100_000) {
            let delay = S.snapshotDelay(entries: entries, lastCost: 0.05)!
            #expect(delay >= previous)
            previous = delay
        }
    }

    @Test func pathSpellings() {
        #expect(PathSpelling.trimmed("/a/b//") == "/a/b")
        #expect(PathSpelling.trimmed("/") == "/")
        #expect(PathSpelling.trimmed("a/b") == nil)
        #expect(PathSpelling.resolvingExistingPrefix("/tmp/no-such-\(1)/x") == "/private/tmp/no-such-1/x")
        #expect(PathSpelling.resolvingExistingPrefix("/no-such-dir/x") == "/no-such-dir/x")
        #expect(PathSpelling.resolvingParent("/tmp") == "/tmp")
        #expect(PathSpelling.resolvingParent("/tmp/x") == "/private/tmp/x")
        #expect(PathSpelling.variants(of: "/tmp/x/", rootPath: "/private/tmp") == ["/tmp/x", "/private/tmp/x"])
        #expect(PathSpelling.variants(of: "relative", rootPath: "/") == [])
        #expect(PathSpelling.variants(of: "/tmp", rootPath: "/") == ["/tmp", "/private/tmp"])
        #expect(PathSpelling.variants(of: "/tmp", rootPath: "/", resolvingItem: false) == ["/tmp"])
        #expect(PathSpelling.variants(of: "/System/Volumes/Data/Users/x", rootPath: "/Users").contains("/Users/x"))
        #expect(PathSpelling.variants(of: "/Users/x", rootPath: "/System/Volumes/Data/Users").contains("/System/Volumes/Data/Users/x"))
        #expect(PathSpelling.variants(of: "/System/Volumes/Data", rootPath: "/System/Volumes") == ["/System/Volumes/Data"])
        #expect(PathSpelling.variants(of: "/System/Volumes/VM", rootPath: "/System/Volumes/Data") == ["/System/Volumes/VM"])
        #expect(PathSpelling.isPath("/a/b", below: "/a") && PathSpelling.isPath("/a", below: "/"))
        #expect(!PathSpelling.isPath("/ab/c", below: "/a") && !PathSpelling.isPath("/a", below: "/a"))
    }

    @Test func everyThreadCountGivesTheSameTree() {
        let fixture = Fixture("threads")
        for directory in 0 ..< 40 {
            for file in 0 ..< 25 { fixture.file("d\(directory % 7)/e\(directory)/f\(file).txt", size: directory * file) }
        }
        let reference = ReferenceTotals.walk(fixture.path)
        for threads in [1, 2, 5, 16, 64, 1000] {
            let result = scan(fixture.path) { $0.threadCount = threads }
            #expect(result.stats.threadCount == min(threads, 64))
            #expect(result.tree.size(of: 0) == reference.allocated)
            #expect(result.tree.logicalSize(of: 0) == reference.logical)
            #expect(Int(result.stats.files) == reference.files)
            #expect(Int(result.stats.directories) == reference.directories)
            #expect(result.tree.invariantViolations().isEmpty)
        }
        #expect(scan(fixture.path).stats.threadCount == ScanOptions.automaticThreadCount)
    }

    // MARK: Session behaviour

    @Test func progressAndAsyncResult() async {
        let fixture = Fixture("progress")
        for index in 0 ..< 200 { fixture.file("p\(index % 10)/f\(index).bin", size: 1000) }

        let session = ScanSession(root: fixture.url)
        let before = session.progress
        #expect(before.entriesScanned == 0 && !before.isFinished && before.elapsed == 0)
        #expect(session.snapshot().count == 1)
        #expect(!session.isFinished)

        session.start()
        session.start()  // idempotent
        async let first = session.result()
        async let second = session.result()
        let (a, b) = await (first, second)
        #expect(a.tree.count == 211 && b.tree.count == 211)

        let progress = session.progress
        #expect(progress.isFinished && session.isFinished)
        #expect(progress.filesScanned == 200)
        #expect(progress.directoriesScanned == 10)
        #expect(progress.bytesLogical == 200_000)
        #expect(progress.bytesAllocated == a.tree.size(of: 0))
        #expect(progress.errorCount == 0)
        #expect(progress.elapsed == a.duration)
        #expect(progress.entriesPerSecond > 0)
        // After the scan the snapshot is the final tree, and results stay available.
        #expect(session.snapshot().count == 211)
        #expect(await session.result().tree.count == 211)
        #expect(session.waitBlocking().tree.count == 211)

        let viaHelper = await ScanSession.scan(fixture.url)
        #expect(viaHelper.tree.count == 211)
    }

    /// A large, immutable directory on the sealed system volume: good for timing-sensitive tests.
    static let largeSystemDirectory = "/System/Library"

    @Test func cancellationIsPrompt() {
        // The other tests run in parallel and keep every core busy, so take the best of a few
        // attempts: the claim is about the scanner, not about the scheduler under load.
        var best = Duration.seconds(10)
        var last: (ScanSession, ScanResult)?
        for _ in 0 ..< 5 {
            let session = ScanSession(root: URL(filePath: Self.largeSystemDirectory))
            session.start()
            while session.progress.entriesScanned < 2000 { usleep(500) }
            var result: ScanResult?
            let latency = ContinuousClock().measure {
                session.cancel()
                result = session.waitBlocking()
            }
            best = min(best, latency)
            last = (session, result!)
            #expect(result!.wasCancelled)
            #expect(latency < .seconds(2))
        }
        let (session, cancelled) = last!
        print("[scan] cancel latency: \(best) (best of 5), last after \(cancelled.stats.entries) entries")
        #expect(best < .milliseconds(100))
        // The partial tree is still a valid tree.
        #expect(cancelled.tree.count > 1000)
        #expect(cancelled.tree.invariantViolations().isEmpty)
        #expect(session.progress.isFinished)
        session.cancel()  // harmless afterwards
        #expect(session.waitBlocking().wasCancelled)
    }

    @Test func cancellingBeforeOrRightAtStart() async {
        let never = ScanSession(root: URL(filePath: "/usr"))
        never.cancel()
        let empty = await never.result()
        #expect(empty.wasCancelled && empty.tree.count == 1 && empty.tree.rootPath == "/usr")
        never.start()  // no effect once finished
        #expect(never.isFinished)

        let immediate = ScanSession(root: URL(filePath: Self.largeSystemDirectory))
        immediate.start()
        immediate.cancel()
        let result = await immediate.result()
        #expect(result.wasCancelled)
        #expect(result.tree.invariantViolations().isEmpty)
    }

    @Test func taskCancellationStopsTheHelper() async {
        let task = Task { await ScanSession.scan(URL(filePath: Self.largeSystemDirectory)) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let result = await task.value
        #expect(result.wasCancelled)
    }

    @Test func snapshotsDuringAScanAreConsistent() {
        let session = ScanSession(root: URL(filePath: Self.largeSystemDirectory))
        session.start()
        var snapshots = 0
        var previousCount = 0
        var sawPartial = false
        var largestPartial = 0
        while !session.isFinished {
            let tree = session.snapshot()
            snapshots += 1
            #expect(tree.rootPath == Self.largeSystemDirectory)
            #expect(tree.count >= previousCount)  // a scan only ever adds
            previousCount = tree.count
            let problems = tree.invariantViolations()
            #expect(problems.isEmpty, "snapshot \(snapshots): \(problems)")
            if tree.count > 1, !session.isFinished {
                sawPartial = true
                largestPartial = tree.count
            }
            // Paths resolve inside a partial tree.
            if let first = tree.children(of: tree.root).first {
                #expect(tree.node(atPath: tree.path(of: first)) == first)
            }
        }
        let result = session.waitBlocking()
        print(
            "[scan] \(snapshots) snapshots during a scan of \(result.stats.entries) entries in \(result.duration) s; "
                + "the largest partial one had \(largestPartial) nodes")
        #expect(sawPartial)
        #expect(result.tree.count >= previousCount)
        #expect(result.tree.invariantViolations().isEmpty)
        #expect(session.snapshot().count == result.tree.count)
        // The sealed system volume cannot change, so a second scan must agree exactly.
        let again = scan(Self.largeSystemDirectory)
        #expect(again.tree.count == result.tree.count)
        #expect(again.tree.size(of: 0) == result.tree.size(of: 0))
        #expect(again.tree.logicalSize(of: 0) == result.tree.logicalSize(of: 0))
    }

    @Test func descriptorsAreReleased() {
        let fixture = Fixture("fds")
        for index in 0 ..< 300 { fixture.file("a\(index % 30)/b\(index)/c.txt", size: 10) }
        func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        let before = openDescriptors()
        for round in 0 ..< 30 {
            let session = ScanSession(root: fixture.url)
            session.start()
            if round % 3 == 0 { session.cancel() }
            _ = session.waitBlocking()
        }
        // Other tests run in parallel and open files of their own; a leak of one descriptor per
        // directory or per scan would still be far above this.
        #expect(openDescriptors() - before < 25)
    }

    // MARK: Mount points

    @Test(arguments: [true, false])
    func mountPointsAreKeptButNotEntered(bulk: Bool) {
        // /System/Volumes holds the Data volume's mount point and several helper volumes. The
        // Data volume reports the same device id as the system volume, so the readdir fallback
        // cannot rely on device ids alone.
        let result = scan("/System/Volumes") { $0.useBulkAttributes = bulk }
        let tree = result.tree
        guard let data = tree.node("Data") else { return }  // not a volume-group system
        #expect(tree.flags(of: data).contains(.mountPoint))
        #expect(tree.isDirectory(data))
        #expect(tree.childCount(of: data) == 0)
        #expect(result.stats.mountPointsSkipped >= 1)
        #expect(result.stats.mountPointsEntered == 0)
        #expect(tree.count < 1000)
        for child in tree.children(of: tree.root) where tree.flags(of: child).contains(.mountPoint) {
            #expect(tree.childCount(of: child) == 0)
        }
    }

    @Test func crossingMountPointsEntersRealVolumesOnly() {
        let result = scan("/System/Volumes") {
            $0.crossMountPoints = true
            $0.excludedPaths = ["/System/Volumes/Data"]  // millions of entries; not needed here
        }
        let tree = result.tree
        guard let preboot = tree.node("Preboot") else { return }
        #expect(tree.flags(of: preboot).contains(.mountPoint))
        #expect(tree.childCount(of: preboot) > 0)
        #expect(tree.size(of: preboot) > 0)
        #expect(result.stats.mountPointsEntered >= 1)
        #expect(result.stats.excludedEntries == 1)
        #expect(tree.node("Data") == nil)
    }

    @Test func entryCountShortcutsDoNotChangeTheTree() {
        // Empty directories, single-reply directories and multi-reply directories on a fixture …
        let fixture = Fixture("hints")
        for index in 0 ..< 50 { fixture.dir("empties/e\(index)/inner") }
        for index in 0 ..< 3000 { fixture.file("wide/f\(index)-\(String(repeating: "n", count: 120))", size: 0) }
        fixture.file("one/only.txt", size: 10)
        fixture.dir("mixed/empty")
        fixture.file("mixed/full/a", size: 1)
        for hints in [true, false] {
            let result = scan(fixture.path) { $0.useEntryCountHints = hints }
            #expect(result.stats.directories == 50 * 2 + 1 + 1 + 1 + 3)
            #expect(result.stats.files == 3002)
            #expect(result.tree.childCount(of: result.tree.node("wide")!) == 3000)
            #expect(result.tree.node("empties/e49/inner") != nil)
        }

        // … and on the system volume, where "grafted" asset directories announce 0 entries in
        // their parent's listing but are not empty. The volume is sealed, so both must agree.
        let with = scan(Self.largeSystemDirectory)
        let without = scan(Self.largeSystemDirectory) { $0.useEntryCountHints = false }
        #expect(with.stats.files == without.stats.files)
        #expect(with.stats.directories == without.stats.directories)
        #expect(with.tree.size(of: 0) == without.tree.size(of: 0))
        #expect(with.tree.logicalSize(of: 0) == without.tree.logicalSize(of: 0))
        #expect(with.stats.hardLinkDuplicates == without.stats.hardLinkDuplicates)
    }

    @Test(.enabled(if: getuid() != 0, "root can read everything"))
    func entryCountShortcutsKeepUnreadableEmptyDirectoriesReported() {
        // An empty directory is normally skipped without being opened. One that cannot be
        // opened must still end up flagged and reported, as it is without the shortcut.
        let fixture = Fixture("hints-locked")
        fixture.dir("lockedEmpty")
        fixture.dir("openEmpty")
        fixture.dir("searchOnly")
        fixture.dir("readOnly")
        fixture.file("lockedFull/secret", size: 10)
        fixture.file("plain/file", size: 10)
        chmod(fixture.path + "/lockedEmpty", 0o000)
        chmod(fixture.path + "/lockedFull", 0o000)
        chmod(fixture.path + "/searchOnly", 0o111)
        chmod(fixture.path + "/readOnly", 0o444)

        struct Observed: Equatable {
            var nodes: [String]
            var issues: [String]
            var total: Int
            var denied: Int
        }
        var seen: [Observed] = []
        for (hints, bulk) in [(true, true), (false, true), (true, false), (false, false)] {
            let result = scan(fixture.path) {
                $0.useEntryCountHints = hints
                $0.useBulkAttributes = bulk
            }
            let tree = result.tree
            var nodes: [String] = []
            tree.forEachDescendant(of: tree.root) { nodes.append("\(tree.path(of: $0)) \(tree.flags(of: $0).rawValue)") }
            seen.append(Observed(
                nodes: nodes.sorted(), issues: result.issues.map { "\($0.path) \($0.errno)" }, total: result.totalIssueCount,
                denied: result.permissionDeniedCount))
            #expect(tree.flags(of: tree.node("lockedEmpty")!).contains(.unreadable), "hints \(hints), bulk \(bulk)")
            #expect(!tree.flags(of: tree.node("openEmpty")!).contains(.unreadable))
        }
        // The shortcut changes nothing, with either enumeration.
        #expect(seen[0] == seen[1])
        #expect(seen[2] == seen[3])
        // The two enumerations agree as well — except on a directory that may be read but not
        // searched: `readdir` lists it (as empty), `getattrlistbulk` refuses.
        func withoutReadOnly(_ observed: Observed) -> Observed {
            var copy = observed
            copy.nodes.removeAll { $0.contains("/readOnly ") }
            let before = copy.issues.count
            copy.issues.removeAll { $0.contains("/readOnly ") }
            copy.total -= before - copy.issues.count
            copy.denied -= before - copy.issues.count
            return copy
        }
        #expect(withoutReadOnly(seen[0]) == withoutReadOnly(seen[2]))
        let expected = ["lockedEmpty", "lockedFull", "searchOnly"].map { fixture.path + "/\($0) \(EACCES)" }
        #expect(withoutReadOnly(seen[0]).issues == expected)
        #expect(withoutReadOnly(seen[0]).total == 3 && withoutReadOnly(seen[0]).denied == 3)
    }

    @Test func firmlinksAreSkippedOnRequestByBothEnumerations() {
        // "/" without the Data volume: the firmlinked directories (/Users, /cores, …) stay
        // empty. The readdir fallback gets no firmlink flag from `fstatat` and has to find out
        // by other means. Everything big is excluded so that this takes milliseconds.
        var results: [ScanResult] = []
        for bulk in [true, false] {
            let result = scan("/") {
                $0.followFirmlinkedDataVolume = false
                $0.includeSiblingSystemVolumes = false
                $0.useBulkAttributes = bulk
                $0.excludedPaths = ["/System", "/usr", "/Library", "/Applications", "/private", "/opt", "/nix", "/bin", "/sbin"]
            }
            let tree = result.tree
            guard let users = tree.node("Users"), tree.node("System") == nil else { return }
            #expect(tree.flags(of: users).contains(.mountPoint), "bulk \(bulk)")
            #expect(tree.childCount(of: users) == 0, "bulk \(bulk)")
            if let cores = tree.node("cores") {
                #expect(tree.flags(of: cores).contains(.mountPoint), "bulk \(bulk)")
                #expect(tree.childCount(of: cores) == 0)
            }
            #expect(result.stats.mountPointsEntered == 0)
            #expect(tree.count < 200)
            results.append(result)
        }
        #expect(results[0].stats.mountPointsSkipped == results[1].stats.mountPointsSkipped)
        #expect(results[0].tree.count == results[1].tree.count)
        func flagged(_ tree: FileTree) -> [String] {
            tree.children(of: tree.root).filter { tree.flags(of: $0).contains(.mountPoint) }.map { tree.name(of: $0) }.sorted()
        }
        #expect(flagged(results[0].tree) == flagged(results[1].tree))

        // Firmlinks further down (/usr/local) are found the same way.
        var nested: [Bool] = []
        for bulk in [true, false] {
            let result = scan("/usr") { $0.useBulkAttributes = bulk }
            guard result.tree.node("local") != nil else { return }
            nested.append(result.tree.flags(of: result.tree.node("local")!).contains(.mountPoint))
        }
        #expect(nested == [false, false])  // only "/" as the root skips firmlinks
    }

    @Test func openLatencyIsReported() {
        let fixture = Fixture("latency")
        for index in 0 ..< 200 { fixture.file("d\(index)/f", size: 1) }
        for bulk in [true, false] {
            let result = scan(fixture.path) { $0.useBulkAttributes = bulk }
            #expect(result.stats.slowestDirectoryOpen > 0)
            #expect(result.stats.slowestDirectoryOpen < 5)
            if result.stats.slowDirectoryOpens == 0 {
                #expect(result.stats.slowestDirectoryOpen < 0.1)
                #expect(result.stats.slowestDirectoryPath.isEmpty)
            } else {
                // A loaded machine can make even this slow; then the culprit must be named.
                #expect(result.stats.slowestDirectoryPath.hasPrefix(fixture.path))
            }
        }
        #expect(scan("/nonexistent-\(UUID())").stats.slowestDirectoryOpen == 0)
    }

    @Test func pseudoFileSystemsStayOutHoweverThePathIsSpelled() {
        func entry(_ path: String, _ type: String, auto: Bool = false, device: String = "/dev/disk9s1") -> MountEntry {
            MountEntry(
                mountPoint: path, device: device, fileSystemType: type,
                flags: UInt32(MNT_LOCAL) | (auto ? UInt32(MNT_AUTOMOUNTED) : 0))
        }
        var options = ScanOptions()
        options.crossMountPoints = true
        // The rules look at the entry alone, so they hold for one found by asking the kernel
        // about an aliased path just as for one found in the table.
        var policy = MountPolicy(table: MountTable(), options: options, rootPath: "/System/Volumes/Data/private/var")
        for type in MountPolicy.pseudoFileSystems { #expect(!policy.shouldEnter(entry("/private/var/x/mirror", type))) }
        #expect(!policy.shouldEnter(entry("/private/var/x/auto", "apfs", auto: true)))
        #expect(policy.shouldEnter(entry("/private/var/x/disk", "apfs")))
        #expect(policy.shouldEnter(entry("/private/var/x/share", "smbfs")))
        #expect(policy.shouldEnter(entry("/System/Volumes/Data", "apfs")))  // not from "/": no double counting
        policy = MountPolicy(table: MountTable(), options: options, rootPath: "/")
        #expect(!policy.shouldEnter(entry("/System/Volumes/Data", "apfs")))
        #expect(policy.shouldEnter(entry("/Volumes/USB", "exfat")))

        // A path missing from the table is looked up in the kernel: "/dev" is devfs and stays
        // out; the scan root's own filesystem is no mount point at all.
        policy = MountPolicy(table: MountTable(), options: options, rootPath: "/")
        #expect(!policy.shouldEnter(mountPoint: "/dev"))
        #expect(!policy.shouldEnter(mountPoint: "/usr/bin"))
        #expect(policy.shouldEnter(mountPoint: "/nonexistent-\(UUID())"))
        // Without an option that could let the scan in, nothing is entered (or even asked).
        options = ScanOptions()
        policy = MountPolicy(table: MountTable(), options: options, rootPath: "/System/Volumes")
        #expect(!policy.shouldEnter(mountPoint: "/dev"))
        #expect(!policy.shouldEnter(mountPoint: "/System/Volumes/VM"))
        // Sibling volumes of "/" are recognized even when the table has not caught up.
        let live = MountTable.current()
        if let vm = live["/System/Volumes/VM"], vm.containerDisk == live["/"]?.containerDisk {
            let stale = MountTable(entries: live.byMountPoint.values.filter { $0.mountPoint != "/System/Volumes/VM" })
            policy = MountPolicy(table: stale, options: options, rootPath: "/")
            #expect(policy.shouldEnter(mountPoint: "/System/Volumes/VM"))
            #expect(!policy.shouldEnter(mountPoint: "/dev"))
        }
    }

    /// A pseudo filesystem below a root spelled through the Data volume's mount point: the
    /// mount table knows it under another name, and it must still not be entered.
    @Test func aliasedRootsDoNotEnterPseudoFileSystems() {
        let alias = MountPolicy.dataVolumeMountPoint
        let candidates = MountTable.readMounts().filter {
            (MountPolicy.pseudoFileSystems.contains($0.fileSystemType) || $0.isAutomounted)
                && !$0.mountPoint.hasPrefix("/System/") && $0.mountPoint != "/dev"
                && FileManager.default.fileExists(atPath: alias + ($0.mountPoint as NSString).deletingLastPathComponent)
        }
        guard let mount = candidates.first(where: { $0.fileSystemType == "nullfs" }) ?? candidates.first else {
            print("[scan] no pseudo filesystem below a firmlinked path; aliased-root test skipped")
            return
        }
        let parent = (mount.mountPoint as NSString).deletingLastPathComponent
        let name = (mount.mountPoint as NSString).lastPathComponent
        // Leave everything else in that directory out; only the mount point matters.
        let siblings = ((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []).filter { $0 != name }
        for root in [parent, alias + parent] {
            for cross in [false, true] {
                let result = scan(root) {
                    $0.crossMountPoints = cross
                    $0.excludedPaths = siblings.map { parent + "/" + $0 }
                }
                guard let node = result.tree.node(name) else { continue }  // unmounted meanwhile
                #expect(result.tree.flags(of: node).contains(.mountPoint), "\(root), cross \(cross)")
                #expect(result.tree.childCount(of: node) == 0, "\(root), cross \(cross): entered \(mount.fileSystemType)")
                #expect(result.stats.mountPointsEntered == 0)
                #expect(result.stats.mountPointsSkipped == 1)
            }
        }
    }

    /// The other half: a real volume must still be entered when crossing is asked for, through
    /// either spelling of the root — and stay out otherwise.
    @Test func realVolumesAreEnteredOnRequestThroughEitherSpelling() {
        let fixture = Fixture("cross")
        let images = Fixture("images")
        fixture.file("holder/beside.bin", size: 100)
        fixture.dir("holder/vol")
        guard let image = MountedImage(at: fixture.path + "/holder/vol", imagePath: images.path + "/cross.dmg") else {
            print("[scan] hdiutil unavailable; mounted-volume test skipped")
            return
        }
        defer { image.detach() }
        try! Data(repeating: 7, count: 5000).write(to: URL(filePath: image.mountPoint + "/on-volume.bin"))

        var roots = [fixture.path]
        let aliased = MountPolicy.dataVolumeMountPoint + fixture.path
        if FileManager.default.fileExists(atPath: aliased + "/holder/beside.bin") { roots.append(aliased) }
        for root in roots {
            for bulk in [true, false] {
                let stay = scan(root) { $0.useBulkAttributes = bulk }
                let vol = try! #require(stay.tree.node("holder/vol"))
                #expect(stay.tree.flags(of: vol).contains(.mountPoint))
                #expect(stay.tree.childCount(of: vol) == 0, "\(root), bulk \(bulk)")
                #expect(stay.stats.mountPointsSkipped == 1 && stay.stats.mountPointsEntered == 0)

                let cross = scan(root) {
                    $0.crossMountPoints = true
                    $0.useBulkAttributes = bulk
                }
                #expect(cross.tree.node("holder/vol/on-volume.bin") != nil, "\(root), bulk \(bulk)")
                #expect(cross.stats.mountPointsEntered == 1 && cross.stats.mountPointsSkipped == 0)
                #expect(cross.tree.flags(of: cross.tree.node("holder/vol")!).contains(.mountPoint))
            }
        }
    }

    @Test func mountPolicy() {
        func entry(_ path: String, _ device: String, _ type: String = "apfs", local: Bool = true, auto: Bool = false)
            -> MountEntry
        {
            var flags: UInt32 = local ? UInt32(MNT_LOCAL) : 0
            if auto { flags |= UInt32(MNT_AUTOMOUNTED) }
            return MountEntry(mountPoint: path, device: device, fileSystemType: type, flags: flags)
        }
        let table = MountTable(entries: [
            entry("/", "/dev/disk3s1s1"),
            entry("/dev", "devfs", "devfs"),
            entry("/System/Volumes/Data", "/dev/disk3s5"),
            entry("/System/Volumes/VM", "/dev/disk3s6"),
            entry("/System/Volumes/Preboot", "/dev/disk3s2"),
            entry("/System/Volumes/Hardware", "/dev/disk1s3"),
            entry("/System/Volumes/Data/home", "map auto_home", "autofs", auto: true),
            entry("/nix", "/dev/disk3s7"),
            entry("/Volumes/Recovery", "/dev/disk3s3"),
            entry("/Volumes/USB", "/dev/disk30s1", "exfat"),
            entry("/Volumes/share", "//me@nas/share", "smbfs", local: false),
            entry("/private/var/x/mirror", "/Applications/Some.app/Wrapper", "nullfs"),
        ])
        #expect(table["/"]?.containerDisk == "disk3")
        #expect(table["/Volumes/USB"]?.containerDisk == "disk30")
        #expect(table["/Volumes/share"]?.containerDisk == nil)

        // Default options, scanning the startup disk.
        var policy = MountPolicy(table: table, options: ScanOptions(), rootPath: "/")
        #expect(!policy.skipsFirmlinks)
        #expect(!policy.shouldEnter(mountPoint: "/System/Volumes/Data"))  // reached through firmlinks
        #expect(policy.shouldEnter(mountPoint: "/System/Volumes/VM"))
        #expect(policy.shouldEnter(mountPoint: "/System/Volumes/Preboot"))
        #expect(policy.shouldEnter(mountPoint: "/nix"))
        #expect(!policy.shouldEnter(mountPoint: "/System/Volumes/Hardware"))  // another container
        #expect(!policy.shouldEnter(mountPoint: "/Volumes/Recovery"))
        #expect(!policy.shouldEnter(mountPoint: "/Volumes/USB"))  // disk30 is not disk3
        #expect(!policy.shouldEnter(mountPoint: "/Volumes/share"))
        #expect(!policy.shouldEnter(mountPoint: "/dev"))
        #expect(!policy.shouldEnter(mountPoint: "/private/var/x/mirror"))
        #expect(!policy.shouldEnter(mountPoint: "/somewhere/unknown"))

        var options = ScanOptions()
        options.includeSiblingSystemVolumes = false
        options.followFirmlinkedDataVolume = false
        policy = MountPolicy(table: table, options: options, rootPath: "/")
        #expect(policy.skipsFirmlinks)
        #expect(!policy.shouldEnter(mountPoint: "/System/Volumes/VM"))
        #expect(!policy.shouldEnter(mountPoint: "/nix"))

        // Any other root stays on its volume …
        policy = MountPolicy(table: table, options: options, rootPath: "/System/Volumes")
        #expect(!policy.skipsFirmlinks)
        #expect(!policy.shouldEnter(mountPoint: "/System/Volumes/VM"))
        #expect(!policy.shouldEnter(mountPoint: "/System/Volumes/Data"))

        // … unless asked to cross; pseudo filesystems and the Data alias stay out regardless.
        options = ScanOptions()
        options.crossMountPoints = true
        policy = MountPolicy(table: table, options: options, rootPath: "/")
        #expect(policy.shouldEnter(mountPoint: "/Volumes/USB"))
        #expect(policy.shouldEnter(mountPoint: "/Volumes/share"))
        #expect(policy.shouldEnter(mountPoint: "/System/Volumes/Hardware"))
        #expect(policy.shouldEnter(mountPoint: "/somewhere/unknown"))
        #expect(!policy.shouldEnter(mountPoint: "/System/Volumes/Data"))
        #expect(!policy.shouldEnter(mountPoint: "/dev"))
        #expect(!policy.shouldEnter(mountPoint: "/System/Volumes/Data/home"))
        #expect(!policy.shouldEnter(mountPoint: "/private/var/x/mirror"))
        policy = MountPolicy(table: table, options: options, rootPath: "/System/Volumes")
        #expect(policy.shouldEnter(mountPoint: "/System/Volumes/Data"))  // no double counting from here
    }

    // MARK: Volumes and disk access

    @Test func mountedVolumesIncludeTheStartupDisk() {
        let volumes = VolumeInfo.mounted()
        let root = try! #require(volumes.first)
        #expect(root.isRoot)
        #expect(root.url.path(percentEncoded: false) == "/")
        #expect(root.totalCapacity > 0)
        #expect(root.availableCapacity > 0 && root.availableCapacity < root.totalCapacity)
        #expect(root.availableCapacityForImportantUsage >= root.availableCapacity)
        #expect(root.usedFraction > 0 && root.usedFraction < 1)
        #expect(!root.name.isEmpty && !root.fileSystemType.isEmpty)
        #expect(!root.isNetwork)
        #expect(Set(volumes.map(\.id)).count == volumes.count)
        #expect(volumes.filter(\.isRoot).count == 1)

        let all = VolumeInfo.mounted(includeHidden: true)
        #expect(all.count >= volumes.count)
        #expect(all.contains { $0.fileSystemType == "devfs" })
        #expect(VolumeInfo.volume(containing: URL(filePath: "/usr/bin"))?.isRoot == true)
        #expect(VolumeInfo.volume(containing: URL(filePath: "/nonexistent-\(UUID())")) == nil)
    }

    @Test func fullDiskAccessProbeAnswersWithoutSideEffects() {
        let first = DiskAccess.hasFullDiskAccess()
        #expect(DiskAccess.hasFullDiskAccess() == first)
        #expect(DiskAccess.realHomeDirectory().hasPrefix("/"))
        #expect(DiskAccess.fullDiskAccessSettingsURL.scheme == "x-apple.systempreferences")
        print("[scan] Full Disk Access: \(first)")
    }
}
