import Foundation
import Testing
@testable import DiskSurveyCore

@Suite struct FileTreeBasics {
    let tree = demoTree()

    @Test func totalsAndCounts() {
        #expect(tree.count == 14)
        #expect(tree.size(of: 0) == 4_120_000_000 + 1_050_800 + 900_000 + 4096)
        #expect(tree.logicalSize(of: 0) == 4_120_000_000 + 1_050_800 + 900_000 + 1200)
        #expect(tree.fileCount(of: 0) == 8)
        #expect(tree.size(of: tree.id("Projects")) == 1_050_800)
        #expect(tree.fileCount(of: tree.id("Projects")) == 4)
        #expect(tree.size(of: tree.id("Projects/Disk Survey.app")) == 1_000_000)
        #expect(tree.size(of: tree.id("Empty")) == 0)
        #expect(tree.fileCount(of: tree.id("Empty")) == 0)
        #expect(tree.fileCount(of: tree.id("notes.txt")) == 1)
        #expect(invariantViolations(tree).isEmpty)
    }

    @Test func childrenSortedBySizeDescending() {
        #expect(tree.childNames(0) == ["Movies", "Projects", "archive.tar.gz", "notes.txt", "Empty"])
        #expect(tree.childNames(tree.id("Projects")) == ["Disk Survey.app", "main.swift", "README.md", ".gitignore"])
        #expect(tree.childNames(tree.id("Movies")) == ["holiday.MP4", "clip.mov"])
        #expect(tree.childCount(of: 0) == 5)
        #expect(tree.name(of: tree.child(of: 0, at: 1)) == "Projects")
        #expect(tree.children(of: tree.id("notes.txt")).isEmpty)
    }

    @Test func namesPathsAndLookup() {
        #expect(tree.rootPath == "/Volumes/Demo")
        #expect(tree.name(of: 0) == "Demo")
        #expect(tree.path(of: 0) == "/Volumes/Demo")
        let binary = tree.id("Projects/Disk Survey.app/Contents/binary")
        #expect(tree.name(of: binary) == "binary")
        #expect(tree.path(of: binary) == "/Volumes/Demo/Projects/Disk Survey.app/Contents/binary")
        #expect(tree.url(of: binary).path == "/Volumes/Demo/Projects/Disk Survey.app/Contents/binary")
        #expect(tree.url(of: tree.id("Movies")).hasDirectoryPath)
        #expect(Array(tree.nameUTF8(of: binary)) == Array("binary".utf8))

        #expect(tree.node(atPath: "/Volumes/Demo") == 0)
        #expect(tree.node(atPath: "/Volumes/Demo/") == 0)
        #expect(tree.node(atPath: "/Volumes/Demo/Movies/") == tree.id("Movies"))
        #expect(tree.node(atPath: "/Volumes/Demo/Movies/nope.mp4") == nil)
        #expect(tree.node(atPath: "/Volumes/Demolition") == nil)
        #expect(tree.node(atPath: "/Elsewhere/Movies") == nil)
        #expect(tree.child(of: 0, named: "Movies") == tree.id("Movies"))
        #expect(tree.child(of: 0, named: "movies") == nil)
        #expect(tree.child(of: 0, named: "") == nil)
    }

    @Test func hierarchyQueries() {
        let binary = tree.id("Projects/Disk Survey.app/Contents/binary")
        let projects = tree.id("Projects")
        #expect(tree.depth(of: 0) == 0)
        #expect(tree.depth(of: binary) == 4)
        #expect(tree.ancestors(of: 0).isEmpty)
        #expect(tree.ancestors(of: binary).map { tree.name(of: $0) } == ["Contents", "Disk Survey.app", "Projects", "Demo"])
        #expect(tree.lineage(of: binary).map { tree.name(of: $0) } == ["Demo", "Projects", "Disk Survey.app", "Contents", "binary"])
        #expect(tree.isAncestor(projects, of: binary))
        #expect(tree.isAncestor(0, of: binary))
        #expect(!tree.isAncestor(binary, of: projects))
        #expect(!tree.isAncestor(projects, of: projects))
        #expect(!tree.isAncestor(tree.id("Movies"), of: binary))
        #expect(tree.parent(of: projects) == 0)

        var visited: [String] = []
        tree.forEachDescendant(of: projects) { visited.append(tree.name(of: $0)) }
        #expect(visited == ["Disk Survey.app", "Contents", "binary", "main.swift", "README.md", ".gitignore"])
    }

    @Test func flagsKindsAndDates() {
        #expect(tree.isDirectory(0))
        #expect(tree.flags(of: tree.id("Projects/Disk Survey.app")).contains([.directory, .package]))
        #expect(!tree.flags(of: tree.id("Projects")).contains(.package))
        #expect(!tree.isDirectory(tree.id("notes.txt")))

        #expect(tree.kinds[0].ext == "")
        #expect(tree.fileKind(of: tree.id("Movies/holiday.MP4")).ext == "mp4")
        #expect(tree.category(of: tree.id("Movies/holiday.MP4")) == .video)
        #expect(tree.fileKind(of: tree.id("archive.tar.gz")).ext == "gz")
        #expect(tree.fileKind(of: tree.id("Projects/.gitignore")).ext == "")
        #expect(tree.fileKind(of: tree.id("Projects/Disk Survey.app")).ext == "app")
        #expect(tree.kind(of: tree.id("Projects")) == 0)
        #expect(tree.kind(of: tree.id("Projects/Disk Survey.app/Contents/binary")) == 0)
        #expect(tree.kindID(forExtension: "MOV") == tree.kind(of: tree.id("Movies/clip.mov")))
        #expect(tree.kindID(forExtension: "xyz") == nil)
        #expect(Set(tree.kinds.map(\.ext)).count == tree.kinds.count)

        #expect(tree.modified(of: 0) == 1_700_000_000)
        #expect(tree.modified(of: tree.id("notes.txt")) == 1_600_000_000)
        #expect(tree.modificationDate(of: tree.id("notes.txt")) == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(tree.modificationDate(of: tree.id("Empty")) == nil)
        #expect(tree.memoryFootprint > 0)
    }

    @Test func emptyTreeAndRootPaths() {
        let empty = FileTree.empty(rootPath: "/Users/someone/")
        #expect(empty.count == 1)
        #expect(empty.rootPath == "/Users/someone")
        #expect(empty.name(of: 0) == "someone")
        #expect(empty.size(of: 0) == 0)
        #expect(empty.children(of: 0).isEmpty)
        #expect(empty.largestFiles(limit: 5).isEmpty)
        #expect(empty.kindSummary().isEmpty)
        #expect(empty.search("x").totalMatches == 0)

        let slash = FileTree.make(rootPath: "/", [.dir("usr", [.file("ls", 100)])])
        #expect(slash.name(of: 0) == "/")
        #expect(slash.path(of: slash.id("usr/ls")) == "/usr/ls")
        #expect(slash.node(atPath: "/usr/ls") != nil)
        #expect(slash.node(atPath: "/") == 0)
        #expect(slash.node(atPath: "usr") == nil)
    }

    @Test func unicodeNamesResolveAcrossNormalForms() {
        let nfc = "Café".precomposedStringWithCanonicalMapping
        let nfd = "Café".decomposedStringWithCanonicalMapping
        let tree = FileTree.make(rootPath: "/r", [.dir(nfd, [.file("日本語.txt", 10)])])
        #expect(tree.node(atPath: "/r/\(nfc)/日本語.txt") != nil)
        #expect(tree.node(atPath: "/r/\(nfd)") != nil)
        #expect(tree.name(of: tree.id(nfd)) == nfc)  // String equality is canonical
    }
}

@Suite struct BuilderTests {
    @Test func directorySizesIgnoredHardLinksCountedOnceAndItemCounts() {
        let builder = FileTree.Builder(rootPath: "/r")
        let w = builder.makeWorker()
        let dir = w.append(to: .root, name: "dir", allocatedSize: 999, logicalSize: 999, modified: 5, flags: .directory)
        w.append(to: dir, name: "a.bin", allocatedSize: 100, logicalSize: 90, modified: 0)
        w.append(to: dir, name: "a-link.bin", allocatedSize: 100, logicalSize: 90, modified: 0, flags: .hardLinkDuplicate)
        w.append(
            to: dir, name: "other files", allocatedSize: 50, logicalSize: 40, modified: 0, flags: .synthetic,
            itemCount: 7)
        w.append(to: .root, name: "cloud.pdf", allocatedSize: 0, logicalSize: 5000, modified: -5, flags: .dataless)
        let tree = builder.finalize()

        #expect(tree.size(of: 0) == 150)
        #expect(tree.logicalSize(of: 0) == 5130)
        #expect(tree.fileCount(of: 0) == 10)
        let link = tree.id("dir/a-link.bin")
        #expect(tree.size(of: link) == 0 && tree.logicalSize(of: link) == 0)
        #expect(tree.flags(of: link).contains(.hardLinkDuplicate))
        #expect(tree.fileCount(of: tree.id("dir/other files")) == 7)
        #expect(tree.flags(of: tree.id("cloud.pdf")) == .dataless)
        #expect(tree.modified(of: tree.id("cloud.pdf")) == 0)  // negative times clamp to "unknown"
        #expect(tree.modified(of: tree.id("dir")) == 5)
        #expect(invariantViolations(tree).isEmpty)
    }

    @Test func addFlagsAfterTheFact() {
        let builder = FileTree.Builder(rootPath: "/r")
        let a = builder.makeWorker()
        let b = builder.makeWorker()
        let secret = a.append(to: .root, name: "secret", allocatedSize: 0, logicalSize: 0, modified: 0, flags: .directory)
        b.append(to: .root, name: "x", allocatedSize: 1, logicalSize: 1, modified: 0)
        builder.addFlags(.unreadable, to: secret)
        builder.addFlags(.mountPoint, to: .root)
        #expect(builder.entryCount == 2)

        let partial = builder.snapshot()
        #expect(partial.flags(of: partial.id("secret")) == [.directory, .unreadable])
        let tree = builder.finalize()
        #expect(tree.flags(of: tree.id("secret")) == [.directory, .unreadable])
        #expect(tree.flags(of: 0) == [.directory, .mountPoint])
    }

    @Test func snapshotsAreIndependentOfLaterAppends() {
        let builder = FileTree.Builder(rootPath: "/r")
        let w = builder.makeWorker()
        let d = w.append(to: .root, name: "d", allocatedSize: 0, logicalSize: 0, modified: 0, flags: .directory)
        w.append(to: d, name: "one.txt", allocatedSize: 10, logicalSize: 10, modified: 0)
        let first = builder.snapshot()
        w.append(to: d, name: "two.txt", allocatedSize: 30, logicalSize: 30, modified: 0)
        let other = builder.makeWorker()
        other.append(to: d, name: "three.jpg", allocatedSize: 20, logicalSize: 20, modified: 0)
        let second = builder.snapshot()
        let final = builder.finalize()

        #expect(first.count == 3 && first.size(of: 0) == 10)
        #expect(first.childNames(first.id("d")) == ["one.txt"])
        #expect(second.count == 5 && second.size(of: 0) == 60)
        #expect(final.childNames(final.id("d")) == ["two.txt", "three.jpg", "one.txt"])
        #expect(invariantViolations(first).isEmpty && invariantViolations(second).isEmpty)
    }

    @Test func extensionInterning() {
        func ext(_ name: String) -> String { FileKinds.normalizedExtension(ofName: name) }
        #expect(ext("movie.MP4") == "mp4")
        #expect(ext("archive.tar.gz") == "gz")
        #expect(ext(".gitignore") == "")
        #expect(ext("Makefile") == "")
        #expect(ext("trailing.") == "")
        #expect(ext("log.1") == "")
        #expect(ext("backup.20240101") == "")
        #expect(ext("song.mp3") == "mp3")
        #expect(ext("db.sqlite-wal") == "sqlite-wal")
        #expect(ext("file.with space") == "")
        #expect(ext("x.abcdefghijklmnop") == "abcdefghijklmnop")
        #expect(ext("x.abcdefghijklmnopq") == "")
        #expect(ext("naïve.txt") == "txt")
        #expect(ext("x.naïve") == "")
        #expect(ext("") == "")
    }

    @Test func manyChunksSingleWorker() {
        // Crosses several entry chunks (8192) and name chunks (64 KB) within one worker.
        let builder = FileTree.Builder(rootPath: "/big")
        let w = builder.makeWorker()
        let n = 40_000
        var dirs: [FileTree.Builder.Ref] = [.root]
        for i in 0 ..< n {
            let parent = dirs[i % dirs.count]
            if i % 50 == 0 {
                dirs.append(
                    w.append(to: parent, name: "dir-\(i)", allocatedSize: 0, logicalSize: 0, modified: 0, flags: .directory))
            } else {
                w.append(to: parent, name: "file-with-a-longer-name-\(i).dat", allocatedSize: UInt64(i), logicalSize: 1, modified: Int64(i))
            }
        }
        let tree = builder.finalize()
        #expect(tree.count == n + 1)
        #expect(tree.fileCount(of: 0) == n - n / 50)
        #expect(tree.size(of: 0) == UInt64((0 ..< n).filter { $0 % 50 != 0 }.reduce(0, +)))
        #expect(invariantViolations(tree).isEmpty)
        // Every name landed at the right node.
        for index in stride(from: 1, to: tree.count, by: 997) {
            let id = NodeID(index)
            let i = index - 1
            #expect(tree.name(of: id) == (i % 50 == 0 ? "dir-\(i)" : "file-with-a-longer-name-\(i).dat"))
            #expect(tree.node(atPath: tree.path(of: id)) == id)
        }
    }

    /// Feeds one builder from several threads, each adding children to directories created by
    /// *other* threads, while another thread keeps taking snapshots.
    @Test func multiThreadedFeedingWithLiveSnapshots() {
        let threads = 8
        let dirsPerThread = 60
        let filesPerDir = 150
        let builder = FileTree.Builder(rootPath: "/mt")
        let workers = (0 ..< threads).map { _ in builder.makeWorker() }

        // Phase A: every thread creates its directories under the root.
        let refs = Mutex([[FileTree.Builder.Ref]](repeating: [], count: threads))
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            var mine: [FileTree.Builder.Ref] = []
            for d in 0 ..< dirsPerThread {
                mine.append(
                    workers[t].append(
                        to: .root, name: "t\(t)-d\(d)", allocatedSize: 0, logicalSize: 0, modified: 1, flags: .directory))
            }
            refs.withLock { $0[t] = mine }
        }
        let allRefs = refs.withLock { $0 }

        // Phase B: thread t fills the directories of thread t+1, with snapshots racing.
        let done = Mutex(false)
        let snapshotIssues = Mutex([String]())
        let snapshotCount = Mutex(0)
        let snapshotter = Thread {
            var lastCount = 0
            while true {
                let finished = done.withLock { $0 }
                let partial = builder.snapshot()
                var issues = invariantViolations(partial)
                if partial.count < lastCount { issues.append("snapshot shrank") }
                lastCount = partial.count
                if !issues.isEmpty { snapshotIssues.withLock { $0.append(contentsOf: issues) } }
                snapshotCount.withLock { $0 += 1 }
                if finished { break }
            }
        }
        snapshotter.start()

        DispatchQueue.concurrentPerform(iterations: threads) { t in
            let targets = allRefs[(t + 1) % threads]
            for (d, dir) in targets.enumerated() {
                let sub = workers[t].append(
                    to: dir, name: "sub", allocatedSize: 0, logicalSize: 0, modified: 2, flags: .directory)
                for f in 0 ..< filesPerDir {
                    workers[t].append(
                        to: f % 2 == 0 ? dir : sub, name: "f\(f)-by\(t).jpg",
                        allocatedSize: UInt64(4096 * (1 + (f + d) % 7)), logicalSize: 1000, modified: 3)
                }
            }
        }
        done.withLock { $0 = true }
        while !snapshotter.isFinished { usleep(1000) }

        let tree = builder.finalize()
        let dirs = threads * dirsPerThread
        #expect(snapshotIssues.withLock { $0 } == [])
        #expect(snapshotCount.withLock { $0 } >= 1)
        #expect(tree.count == 1 + dirs * (2 + filesPerDir))
        #expect(tree.fileCount(of: 0) == dirs * filesPerDir)
        #expect(tree.logicalSize(of: 0) == UInt64(dirs * filesPerDir * 1000))
        var expected: UInt64 = 0
        for d in 0 ..< dirsPerThread { for f in 0 ..< filesPerDir { expected += UInt64(4096 * (1 + (f + d) % 7)) } }
        #expect(tree.size(of: 0) == expected * UInt64(threads))
        #expect(invariantViolations(tree).isEmpty)
        #expect(tree.kinds.map(\.ext) == ["", "jpg"])

        // Spot-check that children ended up under the directory they were appended to.
        let d = tree.id("t3-d7")
        #expect(tree.childCount(of: d) == 1 + filesPerDir / 2)
        #expect(tree.fileCount(of: d) == filesPerDir)
        #expect(tree.child(of: d, named: "f0-by2.jpg") != nil)
        #expect(tree.child(of: tree.id("t3-d7/sub"), named: "f1-by2.jpg") != nil)
    }
}

/// Minimal lock box for the tests (Synchronization.Mutex needs a newer deployment story than we want here).
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
