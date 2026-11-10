import Foundation
import Testing
import DiskSurveyCore
import os
@testable import DiskSurveyScan

/// The rules of Move to Trash and the tree update that follows it.
///
/// Every test but the last uses a stand-in "mover" that moves items into a second temporary
/// directory, so the user's Trash is not touched. The last one goes through the real Trash and
/// only runs when `DISKSURVEY_TEST_REAL_TRASH=1`; it removes what it trashed.
@Suite struct TrashServiceTests {
    /// A mover that relocates items into `bin` (a stand-in Trash) and records what it was given.
    private static func fakeTrash(into bin: Fixture) -> TrashService {
        let binURL = bin.url
        return TrashService { url in
            let destination = binURL.appending(path: url.lastPathComponent + "-" + UUID().uuidString.prefix(6))
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    private static func makeFixture() throws -> Fixture {
        let fixture = Fixture("trash")
        let manager = FileManager.default
        try manager.createDirectory(atPath: fixture.path + "/keep", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: fixture.path + "/junk/nested", withIntermediateDirectories: true)
        try Data(repeating: 1, count: 300_000).write(to: URL(filePath: fixture.path + "/keep/a.bin"))
        try Data(repeating: 2, count: 200_000).write(to: URL(filePath: fixture.path + "/junk/b.bin"))
        try Data(repeating: 3, count: 100_000).write(to: URL(filePath: fixture.path + "/junk/nested/c.bin"))
        try Data(repeating: 4, count: 50_000).write(to: URL(filePath: fixture.path + "/top.bin"))
        return fixture
    }

    private static func scan(_ fixture: Fixture) -> FileTree {
        ScanSession(root: fixture.url).also { $0.start() }.waitBlocking().tree
    }

    @Test func trashingAFolderUpdatesTheTreeAndReportsWhatWasFreed() throws {
        let fixture = try Self.makeFixture()
        let bin = Fixture("bin")
        var tree = Self.scan(fixture)
        let before = tree.totals(of: tree.root)
        let junk = try #require(tree.node(atPath: fixture.path + "/junk"))
        let junkTotals = tree.totals(of: junk)
        #expect(junkTotals.fileCount == 2)

        let (candidates, refused) = TrashService.candidates(for: [junk], in: tree)
        #expect(refused.isEmpty)
        let outcome = Self.fakeTrash(into: bin).trash(candidates)
        #expect(outcome.trashed.count == 1)
        #expect(outcome.failures.isEmpty && outcome.missing.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/junk"))

        let freed = TrashService.apply(outcome, to: &tree)
        #expect(freed == junkTotals)
        let after = tree.totals(of: tree.root)
        #expect(after.allocated == before.allocated - junkTotals.allocated)
        #expect(after.logical == before.logical - junkTotals.logical)
        #expect(after.fileCount == before.fileCount - 2)
        #expect(tree.node(atPath: fixture.path + "/junk") == nil)
        #expect(tree.node(atPath: fixture.path + "/junk/nested/c.bin") == nil)
        #expect(tree.isRemoved(junk))
        #expect(!tree.children(of: tree.root).contains(junk))

        // The updated tree is what a fresh scan of the folder finds.
        let rescanned = Self.scan(fixture)
        #expect(rescanned.totals(of: rescanned.root) == after)
    }

    @Test func protectedItemsAreRefusedAndNestedSelectionsCollapse() throws {
        let fixture = try Self.makeFixture()
        let tree = Self.scan(fixture)
        let junk = try #require(tree.node(atPath: fixture.path + "/junk"))
        let nested = try #require(tree.node(atPath: fixture.path + "/junk/nested/c.bin"))
        let keep = try #require(tree.node(atPath: fixture.path + "/keep"))

        let (candidates, refused) = TrashService.candidates(
            for: [nested, junk, junk, keep], in: tree, mountPointPaths: [fixture.path + "/keep"])
        #expect(candidates.map(\.node) == [junk])
        #expect(refused.map(\.reason) == [.mountPoint])

        // The scan root is never offered, and it covers everything selected along with it.
        let withRoot = TrashService.candidates(for: [junk, tree.root], in: tree)
        #expect(withRoot.candidates.isEmpty)
        #expect(withRoot.refused.map(\.reason) == [.scanRoot])

        let literal = FileTree.make(rootPath: "/T", [
            .dir("Volume", flags: .mountPoint), .file("free space", 10, flags: .synthetic), .file("real", 10),
        ])
        let all = Array(literal.children(of: literal.root))
        let result = TrashService.candidates(for: all, in: literal)
        #expect(result.candidates.map { literal.name(of: $0.node) } == ["real"])
        #expect(Set(result.refused.map(\.reason)) == [.mountPoint, .synthetic])
    }

    @Test func aFileChangedAfterTheScanIsLeftAlone() throws {
        let fixture = try Self.makeFixture()
        let bin = Fixture("bin")
        var tree = Self.scan(fixture)
        let before = tree.totals(of: tree.root)
        let top = try #require(tree.node(atPath: fixture.path + "/top.bin"))
        let handle = try FileHandle(forWritingTo: URL(filePath: fixture.path + "/top.bin"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 9, count: 1234))
        try handle.close()

        let outcome = Self.fakeTrash(into: bin).trash(TrashService.candidates(for: [top], in: tree).candidates)
        #expect(outcome.trashed.isEmpty)
        #expect(outcome.failures.map(\.reason) == [.changedSinceScan])
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/top.bin"))
        #expect(TrashService.apply(outcome, to: &tree) == .zero)
        #expect(tree.totals(of: tree.root) == before)
    }

    @Test func aFileReplacedByAFolderIsLeftAlone() throws {
        let fixture = try Self.makeFixture()
        let bin = Fixture("bin")
        let tree = Self.scan(fixture)
        let top = try #require(tree.node(atPath: fixture.path + "/top.bin"))
        try FileManager.default.removeItem(atPath: fixture.path + "/top.bin")
        try FileManager.default.createDirectory(atPath: fixture.path + "/top.bin", withIntermediateDirectories: false)

        let outcome = Self.fakeTrash(into: bin).trash(TrashService.candidates(for: [top], in: tree).candidates)
        #expect(outcome.failures.map(\.reason) == [.changedSinceScan])
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/top.bin"))
    }

    @Test func anItemThatVanishedLeavesTheTreeWithoutBeingTrashed() throws {
        let fixture = try Self.makeFixture()
        let bin = Fixture("bin")
        var tree = Self.scan(fixture)
        let top = try #require(tree.node(atPath: fixture.path + "/top.bin"))
        let size = tree.size(of: top)
        let before = tree.size(of: tree.root)
        try FileManager.default.removeItem(atPath: fixture.path + "/top.bin")

        let outcome = Self.fakeTrash(into: bin).trash(TrashService.candidates(for: [top], in: tree).candidates)
        #expect(outcome.trashed.isEmpty && outcome.failures.isEmpty)
        #expect(outcome.missing == [top])
        TrashService.apply(outcome, to: &tree)
        #expect(tree.size(of: tree.root) == before - size)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)
    }

    @Test func aMoverErrorIsReportedAndTheTreeIsUnchanged() throws {
        let fixture = try Self.makeFixture()
        var tree = Self.scan(fixture)
        let before = tree.totals(of: tree.root)
        let top = try #require(tree.node(atPath: fixture.path + "/top.bin"))
        let service = TrashService { _ in throw CocoaError(.fileWriteNoPermission) }
        let outcome = service.trash(TrashService.candidates(for: [top], in: tree).candidates)
        #expect(outcome.failures.count == 1)
        #expect(TrashService.apply(outcome, to: &tree) == .zero)
        #expect(tree.totals(of: tree.root) == before)
    }

    @Test func putBackRestoresItemsButNeverOverwrites() throws {
        let fixture = try Self.makeFixture()
        let bin = Fixture("bin")
        let tree = Self.scan(fixture)
        let junk = try #require(tree.node(atPath: fixture.path + "/junk"))
        let top = try #require(tree.node(atPath: fixture.path + "/top.bin"))
        let outcome = Self.fakeTrash(into: bin).trash(TrashService.candidates(for: [junk, top], in: tree).candidates)
        #expect(outcome.trashed.count == 2)
        // Something new took the file's name in the meantime.
        try Data("new".utf8).write(to: URL(filePath: fixture.path + "/top.bin"))

        let (restored, failures) = TrashService.putBack(outcome.trashed)
        #expect(restored == [fixture.path + "/junk"])
        #expect(failures.map(\.path) == [fixture.path + "/top.bin"])
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/junk/nested/c.bin"))
        #expect(try Data(contentsOf: URL(filePath: fixture.path + "/top.bin")) == Data("new".utf8))

        let rescanned = Self.scan(fixture)
        let restoredJunk = try #require(rescanned.node(atPath: fixture.path + "/junk"))
        #expect(rescanned.totals(of: restoredJunk) == tree.totals(of: junk))
    }

    // MARK: Mounted volumes below a folder

    @Test func aFolderAboveAMountPointIsRefused() throws {
        let tree = FileTree.make(rootPath: "/T", [
            .dir("holder", [.dir("vol", flags: .mountPoint), .file("note", 10)]),
            .dir("holder2", [.dir("vol"), .file("note", 10)]),
            .dir("deep", [.dir("a", [.dir("b", [.dir("vol", flags: .mountPoint)])])]),
        ])
        let holder = try #require(tree.node("holder"))
        let holder2 = try #require(tree.node("holder2"))
        let deep = try #require(tree.node("deep"))
        let note = try #require(tree.node("holder/note"))

        let flagged = TrashService.review([holder, deep, holder2], in: tree)
        #expect(flagged.candidates.map(\.node) == [holder2])
        #expect(flagged.rejected.map(\.reason) == [.containsMountPoint, .containsMountPoint])
        #expect(flagged.rejected.map(\.detail) == ["/T/holder/vol", "/T/deep/a/b/vol"])
        // The older entry point is just as safe; it only says less about why.
        let legacy = TrashService.candidates(for: [holder, deep, holder2], in: tree)
        #expect(legacy.candidates.map(\.node) == [holder2])
        #expect(legacy.refused.map(\.reason) == [.mountPoint, .mountPoint])
        // A sibling of the mount point is fine by itself.
        #expect(TrashService.review([note], in: tree).candidates.map(\.node) == [note])

        // Known only from the caller's list of volumes (mounted after the scan, say) …
        let listed = TrashService.review([holder2], in: tree, rules: .init(mountPointPaths: ["/T/holder2/vol"]))
        #expect(listed.candidates.isEmpty)
        #expect(listed.rejected.map(\.reason) == [.containsMountPoint])
        #expect(TrashService.candidates(for: [holder2], in: tree, mountPointPaths: ["/T/holder2/vol/"]).candidates.isEmpty)
        // … compared by path component, not by string prefix.
        let boundary = TrashService.review([holder], in: tree.removing("holder/vol"), rules: .init(mountPointPaths: ["/T/holder2/vol"]))
        #expect(boundary.rejected.isEmpty && boundary.candidates.count == 1)

        // A mount point that already left the tree no longer blocks.
        let without = tree.removing("holder/vol")
        let free = TrashService.review([try #require(without.node("holder"))], in: without)
        #expect(free.rejected.isEmpty)
        #expect(free.candidates.first?.expectedContents?.entries == 1)
    }

    @Test func volumePathsAreMatchedInAnySpelling() throws {
        // The app hands over standardized paths, which lose "/private" (/tmp, /var).
        let fixture = Fixture("spelling")
        fixture.file("holder/vol/x", size: 10)
        fixture.file("other/y", size: 10)
        let tree = Self.scan(fixture)
        #expect(fixture.path.hasPrefix("/private/"))
        let short = String(fixture.path.dropFirst("/private".count))
        let holder = try #require(tree.node("holder"))
        let vol = try #require(tree.node("holder/vol"))
        let other = try #require(tree.node("other"))
        let result = TrashService.review([holder, other], in: tree, rules: .init(mountPointPaths: [short + "/holder/vol"]))
        #expect(result.candidates.map(\.node) == [other])
        #expect(result.rejected.map(\.reason) == [.containsMountPoint])
        #expect(TrashService.review([vol], in: tree, rules: .init(mountPointPaths: [short + "/holder/vol"])).rejected.map(\.reason) == [.mountPoint])
    }

    @Test func aVolumeMountedAfterTheScanStopsTheMove() throws {
        let fixture = try Self.makeFixture()
        let bin = Fixture("bin")
        let tree = Self.scan(fixture)
        let junk = try #require(tree.node(atPath: fixture.path + "/junk"))
        let keep = try #require(tree.node(atPath: fixture.path + "/keep"))
        let candidates = TrashService.candidates(for: [junk, keep], in: tree).candidates
        #expect(candidates.count == 2)

        // The mount table now lists something below "junk" — in the kernel's spelling — and
        // something below a folder that merely starts with the same letters.
        let binURL = bin.url
        let counted = OSAllocatedUnfairLock(initialState: 0)
        let service = TrashService(
            mover: { url in
                let destination = binURL.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            },
            mountPoints: { [path = fixture.path] in
                counted.withLock { $0 += 1 }
                return ["/", path + "/junk/nested", path + "/keeper/vol"]
            })
        let outcome = service.trash(candidates)
        #expect(outcome.failures.map(\.reason) == [.containsMountPoint])
        #expect(outcome.failures.first?.path == fixture.path + "/junk")
        #expect(outcome.failures.first?.message.contains("volume") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/junk/nested/c.bin"))
        #expect(outcome.trashed.map(\.node) == [keep])
        #expect(counted.withLock { $0 } == 1)  // read once per call, not per item

        // Path forms: through a symlink and through the Data volume's own mount point.
        #expect(TrashService.mountPoint(below: "/tmp", among: ["/private/tmp/x/vol"]) == "/private/tmp/x/vol")
        #expect(TrashService.mountPoint(below: "/System/Volumes/Data/private/tmp", among: ["/private/tmp/x"]) != nil)
        #expect(TrashService.mountPoint(below: "/private/tmp/a", among: ["/private/tmp/a2/vol", "/private/tmp/a"]) == nil)
    }

    /// The real thing: a disk image attached below a folder. The folder must be refused when
    /// the scan saw the volume, and must not move when the volume appeared afterwards.
    @Test func aFolderHoldingALiveVolumeNeverMoves() throws {
        let fixture = Fixture("mount")
        let images = Fixture("images")
        let bin = Fixture("bin")
        fixture.file("early/note.txt", size: 100)
        fixture.dir("early/vol")
        fixture.file("late/note.txt", size: 100)
        fixture.dir("late/vol")

        guard let early = MountedImage(at: fixture.path + "/early/vol", imagePath: images.path + "/early.dmg") else {
            print("[trash] hdiutil unavailable; mounted-volume test skipped")
            return
        }
        defer { early.detach() }
        try Data(repeating: 7, count: 5000).write(to: URL(filePath: early.mountPoint + "/on-volume.bin"))

        let tree = Self.scan(fixture)
        let earlyNode = try #require(tree.node("early"))
        let lateNode = try #require(tree.node("late"))
        #expect(tree.flags(of: try #require(tree.node("early/vol"))).contains(.mountPoint))
        #expect(tree.fileCount(of: earlyNode) == 1)  // the volume's file is not in the tree

        let review = TrashService.review([earlyNode, lateNode], in: tree)
        #expect(review.rejected.map(\.node) == [earlyNode])
        #expect(review.rejected.first?.reason == .containsMountPoint)
        #expect(review.rejected.first?.detail == fixture.path + "/early/vol")
        #expect(TrashService.candidates(for: [earlyNode], in: tree).candidates.isEmpty)

        // A second volume arrives after the scan, below a folder that was accepted.
        guard let late = MountedImage(at: fixture.path + "/late/vol", imagePath: images.path + "/late.dmg") else { return }
        defer { late.detach() }
        let outcome = Self.fakeTrash(into: bin).trash(review.candidates)
        #expect(outcome.trashed.isEmpty)
        #expect(outcome.failures.map(\.reason) == [.containsMountPoint])
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/late/note.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)

        // Even with a mount table that does not list it (its recorded path can be stale), the
        // fresh look at the folder finds the mount point.
        let blind = TrashService(mover: { _ in Issue.record("must not move"); return nil }, mountPoints: { [] })
        #expect(blind.trash(review.candidates).failures.map(\.reason) == [.containsMountPoint])
        // And a hand-made candidate for the folder that was refused fares no better.
        let forced = TrashService.Candidate(
            node: earlyNode, path: fixture.path + "/early", isDirectory: true, isSymlink: false, expectedLength: nil)
        #expect(Self.fakeTrash(into: bin).trash([forced]).failures.map(\.reason) == [.containsMountPoint])
        #expect(FileManager.default.fileExists(atPath: early.mountPoint + "/on-volume.bin"))
    }

    // MARK: Folders are trashed with what the scan saw

    @Test func aFolderThatGainedContentsIsLeftAlone() throws {
        let fixture = try Self.makeFixture()
        let bin = Fixture("bin")
        var tree = Self.scan(fixture)
        let before = tree.totals(of: tree.root)
        let junk = try #require(tree.node(atPath: fixture.path + "/junk"))
        let keep = try #require(tree.node(atPath: fixture.path + "/keep"))
        let candidates = TrashService.candidates(for: [junk, keep], in: tree).candidates
        #expect(candidates.first?.expectedContents == .init(entries: 3, files: 2, logicalSize: 300_000, hasHardLinkDuplicates: false))

        // Two levels down, so the folder's own modification date does not change.
        try Data(repeating: 5, count: 500_000).write(to: URL(filePath: fixture.path + "/junk/nested/important.bin"))
        var outcome = Self.fakeTrash(into: bin).trash(candidates)
        #expect(outcome.failures.map(\.reason) == [.changedSinceScan])
        #expect(outcome.failures.first?.path == fixture.path + "/junk")
        #expect(outcome.trashed.map(\.node) == [keep])  // the untouched folder still goes
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/junk/nested/important.bin"))
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/junk/b.bin"))
        TrashService.apply(outcome, to: &tree)
        #expect(tree.totals(of: tree.root).fileCount == before.fileCount - 1)

        // Same number of entries, different length.
        try FileManager.default.removeItem(atPath: fixture.path + "/junk/nested/important.bin")
        try Data(repeating: 5, count: 1).write(to: URL(filePath: fixture.path + "/junk/nested/c.bin"))
        outcome = Self.fakeTrash(into: bin).trash([candidates[0]])
        #expect(outcome.failures.map(\.reason) == [.changedSinceScan])
        // An empty folder in place of a file: same number of entries, fewer files.
        try Data(repeating: 3, count: 100_000).write(to: URL(filePath: fixture.path + "/junk/nested/c.bin"))
        try FileManager.default.removeItem(atPath: fixture.path + "/junk/b.bin")
        try FileManager.default.createDirectory(atPath: fixture.path + "/junk/b.bin", withIntermediateDirectories: false)
        outcome = Self.fakeTrash(into: bin).trash([candidates[0]])
        #expect(outcome.failures.map(\.reason) == [.changedSinceScan])

        // After a rescan the folder is what the tree shows, and goes.
        let fresh = Self.scan(fixture)
        let again = TrashService.candidates(for: [try #require(fresh.node("junk"))], in: fresh).candidates
        outcome = Self.fakeTrash(into: bin).trash(again)
        #expect(outcome.trashed.count == 1 && outcome.failures.isEmpty)
    }

    @Test func aFolderHoldingExcludedItemsIsRefused() throws {
        let fixture = Fixture("excluded")
        let bin = Fixture("bin")
        fixture.file("proj/x.bin", size: 10)
        fixture.file("proj/keepme/big.bin", size: 400_000)
        fixture.file("proj/sub/y.bin", size: 20)
        fixture.file("projector/z.bin", size: 30)
        let excluded = [fixture.path + "/proj/keepme"]
        let tree = DiskSurveyScanTests.scan(fixture.path) { $0.excludedPaths = excluded }.tree
        let proj = try #require(tree.node("proj"))
        let x = try #require(tree.node("proj/x.bin"))
        let sub = try #require(tree.node("proj/sub"))
        let projector = try #require(tree.node("projector"))
        #expect(tree.fileCount(of: proj) == 2 && tree.logicalSize(of: proj) == 30)

        let review = TrashService.review([proj, projector], in: tree, rules: .init(excludedPaths: excluded))
        #expect(review.rejected.map(\.reason) == [.containsExcludedPath])
        #expect(review.rejected.first?.detail == excluded[0])
        #expect(review.candidates.map(\.node) == [projector])
        let inside = TrashService.review([x, sub], in: tree, rules: .init(excludedPaths: excluded))
        #expect(inside.rejected.isEmpty && inside.candidates.count == 2)
        // The exclusion in the spelling the settings store (no "/private").
        let short = [String(fixture.path.dropFirst("/private".count)) + "/proj/keepme/"]
        #expect(TrashService.review([proj], in: tree, rules: .init(excludedPaths: short)).rejected.map(\.reason) == [.containsExcludedPath])

        // A caller that does not pass the exclusions gets a candidate, but the move finds
        // that the folder holds more than the tree shows.
        let unaware = TrashService.candidates(for: [proj], in: tree).candidates
        let outcome = Self.fakeTrash(into: bin).trash(unaware)
        #expect(outcome.failures.map(\.reason) == [.changedSinceScan])
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/proj/keepme/big.bin"))
    }

    @Test func foldersOfAStoppedScanAreNotTrusted() throws {
        let fixture = Fixture("partial")
        let bin = Fixture("bin")
        fixture.file("done/a.bin", size: 100)
        fixture.file("unread/inner/b.bin", size: 200)
        fixture.file("top.bin", size: 300)
        // What a stopped scan leaves behind: "unread" was listed in its parent but never opened.
        let partial = FileTree.make(rootPath: fixture.path, [
            .dir("done", [.file("a.bin", 4096, logical: 100)]), .dir("unread"), .file("top.bin", 4096, logical: 300),
        ])
        let done = try #require(partial.node("done"))
        let unread = try #require(partial.node("unread"))
        let top = try #require(partial.node("top.bin"))

        // Told that the scan was stopped, no folder is offered; files still are.
        let review = TrashService.review([done, unread, top], in: partial, rules: .init(scanWasCancelled: true))
        #expect(review.rejected.map(\.reason) == [.incompleteScan, .incompleteScan])
        #expect(review.candidates.map(\.node) == [top])

        // Not told, the move itself notices which folder holds more than the tree shows.
        let candidates = TrashService.candidates(for: [done, unread, top], in: partial).candidates
        #expect(candidates.count == 3)
        let outcome = Self.fakeTrash(into: bin).trash(candidates)
        #expect(outcome.failures.map(\.path) == [fixture.path + "/unread"])
        #expect(outcome.failures.map(\.reason) == [.changedSinceScan])
        #expect(Set(outcome.trashed.map(\.node)) == [done, top])
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/unread/inner/b.bin"))

        // The same with a scan that really was cancelled, wherever it happened to stop.
        let big = Fixture("partial-big")
        for index in 0 ..< 3000 { big.file("d\(index % 300)/s\(index % 7)/f\(index)", size: 1) }
        let session = ScanSession(root: big.url, options: { var o = ScanOptions(); o.threadCount = 2; return o }())
        session.start()
        while session.progress.entriesScanned < 200, !session.isFinished { usleep(200) }
        session.cancel()
        let result = session.waitBlocking()
        let tree = result.tree
        let folders = Array(tree.children(of: tree.root))
        let cancelledOutcome = Self.fakeTrash(into: bin).trash(TrashService.candidates(for: folders, in: tree).candidates)
        // Whatever was moved held exactly ten files, as every complete folder does.
        for item in cancelledOutcome.trashed {
            let url = try #require(item.trashURL)
            #expect(tree.fileCount(of: item.node) == 10)
            #expect(FileManager.default.enumerator(atPath: url.path)!.allObjects.count == 7 + 10)
        }
        #expect(cancelledOutcome.failures.allSatisfy { $0.reason == .changedSinceScan })
        #expect(cancelledOutcome.trashed.count + cancelledOutcome.failures.count == folders.count)
        if result.wasCancelled, folders.count < 300 || tree.fileCount(of: tree.root) < 3000 {
            let rules = TrashService.Rules(scanWasCancelled: result.wasCancelled)
            #expect(TrashService.review(folders, in: tree, rules: rules).candidates.isEmpty)
        }
    }

    @Test func hardLinksAndEmptyFoldersDoNotLookLikeChanges() throws {
        let fixture = Fixture("links")
        let bin = Fixture("bin")
        fixture.file("a/one.bin", size: 5000)
        fixture.file("b/other.bin", size: 100)
        fixture.dir("b/empty/emptier")
        fixture.dir("hollow")
        #expect(link(fixture.path + "/a/one.bin", fixture.path + "/b/two.bin") == 0)
        #expect(symlink("../a", fixture.path + "/b/up") == 0)
        // One thread, so which name of the hard link carries the size is the same every time.
        var tree = DiskSurveyScanTests.scan(fixture.path) { $0.threadCount = 1 }.tree
        let a = try #require(tree.node("a"))
        let b = try #require(tree.node("b"))
        let hollow = try #require(tree.node("hollow"))
        let candidates = TrashService.candidates(for: [a, b, hollow], in: tree).candidates
        #expect(candidates.compactMap(\.expectedContents?.hasHardLinkDuplicates).filter { $0 }.count == 1)
        let outcome = Self.fakeTrash(into: bin).trash(candidates)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.trashed.count == 3)
        TrashService.apply(outcome, to: &tree)
        #expect(tree.childCount(of: tree.root) == 0)
        #expect(TrashService.putBack(outcome.trashed).restored.count == 3)
        #expect(FileManager.default.fileExists(atPath: fixture.path + "/b/empty/emptier"))
    }

    /// Trashing the folder that holds the counted link of a file frees nothing for that file:
    /// its other name survives, takes over the size, and the totals say so.
    @Test func trashingTheCountedHardLinkFreesOnlyWhatIsReallyGone() throws {
        let fixture = Fixture("links-freed")
        let bin = Fixture("bin")
        fixture.file("A/big.bin", size: 300_000)
        fixture.file("A/small.bin", size: 7_000)
        fixture.dir("B")
        #expect(link(fixture.path + "/A/big.bin", fixture.path + "/B/link.bin") == 0)
        // One thread: A is read first, so A/big.bin is the counted link.
        var tree = DiskSurveyScanTests.scan(fixture.path) { $0.threadCount = 1 }.tree
        let counted = [try #require(tree.node("A/big.bin")), try #require(tree.node("B/link.bin"))]
            .first { !tree.flags(of: $0).contains(.hardLinkDuplicate) }!
        let folder = try #require(tree.parent(of: counted))
        let other = try #require(tree.node(folder == tree.node("A") ? "B/link.bin" : "A/big.bin"))
        let before = tree.totals(of: tree.root)
        #expect(tree.logicalSize(of: other) == 0)

        let review = TrashService.review([folder], in: tree)
        #expect(review.rejected.isEmpty)
        let outcome = Self.fakeTrash(into: bin).trash(review.candidates)
        #expect(outcome.failures.isEmpty && outcome.trashed.count == 1)
        let freed = TrashService.apply(outcome, to: &tree)

        // The 300 kB file still has a name in the tree, so only what else was in the folder is freed.
        let holdsSmall = folder == tree.node("A")
        #expect(freed.logical == (holdsSmall ? 7_000 : 0))
        #expect(freed.fileCount == (holdsSmall ? 2 : 1))
        #expect(tree.logicalSize(of: other) == 300_000)
        #expect(!tree.flags(of: other).contains(.hardLinkDuplicate))
        #expect(tree.totals(of: tree.root).logical == before.logical - freed.logical)
        #expect(tree.invariantViolations().isEmpty)
        // …which is what a fresh scan finds.
        let rescanned = DiskSurveyScanTests.scan(fixture.path).tree
        #expect(rescanned.totals(of: rescanned.root) == tree.totals(of: tree.root))
    }

    /// A name that is not valid UTF-8 has no `String` path. Such an item is refused up front:
    /// examined under its display path it would look missing and silently leave the tree.
    @Test func itemsWithUnrepresentableNamesAreRefusedNotMissing() throws {
        let fixture = Fixture("lossy")
        fixture.file("fine.txt", size: 10)
        let builder = FileTree.Builder(rootPath: fixture.path)
        let worker = builder.makeWorker()
        func add(_ bytes: [UInt8], to parent: FileTree.Builder.Ref, directory: Bool = false) -> FileTree.Builder.Ref {
            bytes.withUnsafeBufferPointer {
                worker.append(to: parent, name: $0, allocatedSize: 10, logicalSize: 10, modified: 0, flags: directory ? .directory : [])
            }
        }
        _ = add([0x66, 0xFF, 0x6F], to: .root)                      // "f\xFFo"
        let badFolder = add([0x64, 0xC3], to: .root, directory: true)  // truncated sequence
        _ = add(Array("inner.txt".utf8), to: badFolder)
        _ = add(Array("fine.txt".utf8), to: .root)
        var tree = builder.finalize()
        let nodes = Array(tree.children(of: tree.root))
        let lossy = nodes.filter { tree.hasLossyPath($0) }
        #expect(lossy.count == 2)
        let lossyFolder = try #require(lossy.first { tree.isDirectory($0) })
        let inner = try #require(tree.children(of: lossyFolder).first)

        let review = TrashService.review(nodes + [inner], in: tree)
        #expect(review.candidates.map(\.path) == [fixture.path + "/fine.txt"])
        #expect(Set(review.rejected.map(\.node)) == Set(lossy))     // `inner` is covered by its folder
        #expect(review.rejected.allSatisfy { $0.reason == .unrepresentableName && $0.refusal == .unrepresentableName })
        // On its own, an item below a lossy folder is refused as well.
        #expect(TrashService.review([inner], in: tree).rejected.map(\.reason) == [.unrepresentableName])
        #expect(TrashService.candidates(for: lossy, in: tree).candidates.isEmpty)

        // Nothing lossy reaches the mover or is reported missing; the tree keeps those nodes.
        let moved = OSAllocatedUnfairLock(initialState: [String]())
        let service = TrashService(mover: { url in
            moved.withLock { $0.append(url.path) }
            return nil
        })
        let outcome = service.trash(review.candidates)
        #expect(outcome.missing.isEmpty && outcome.failures.isEmpty)
        #expect(moved.withLock { $0 } == [fixture.path + "/fine.txt"])
        TrashService.apply(outcome, to: &tree)
        #expect(lossy.allSatisfy { !tree.isRemoved($0) })
    }

    // MARK: Swapped folders

    @Test func aSwappedAncestorDoesNotRedirectTheMove() throws {
        let fixture = Fixture("swap")
        let bin = Fixture("bin")
        fixture.file("scan/A/data.bin", size: 100)
        fixture.file("scan/A/folder/inner.bin", size: 50)
        fixture.file("scan/A/gone/x", size: 1)
        fixture.file("elsewhere/data.bin", size: 100)
        fixture.file("elsewhere/folder/inner.bin", size: 50)
        let tree = DiskSurveyScanTests.scan(fixture.path + "/scan").tree
        let data = try #require(tree.node("A/data.bin"))
        let folder = try #require(tree.node("A/folder"))
        let candidates = TrashService.candidates(for: [data, folder], in: tree).candidates

        try FileManager.default.moveItem(atPath: fixture.path + "/scan/A", toPath: fixture.path + "/scan/A.old")
        #expect(symlink("../elsewhere", fixture.path + "/scan/A") == 0)
        let outcome = Self.fakeTrash(into: bin).trash(candidates)
        #expect(outcome.trashed.isEmpty && outcome.missing.isEmpty)
        #expect(outcome.failures.map(\.reason) == [.changedSinceScan, .changedSinceScan])
        for path in ["/elsewhere/data.bin", "/elsewhere/folder/inner.bin", "/scan/A.old/data.bin", "/scan/A.old/folder/inner.bin"] {
            #expect(FileManager.default.fileExists(atPath: fixture.path + path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)

        // An ancestor that is simply gone means the item is gone.
        unlink(fixture.path + "/scan/A")
        let missing = Self.fakeTrash(into: bin).trash(candidates)
        #expect(missing.missing == [data, folder])
        #expect(missing.failures.isEmpty)
    }

    @Test func rootsBehindSymlinksAndUnusualNamesStillTrash() throws {
        let fixture = Fixture("viaLink")
        let bin = Fixture("bin")
        let decomposed = "cafe\u{301}"  // "é" as two scalars; APFS keeps what it was given
        fixture.file("real/\(decomposed)/menu.txt", size: 10)
        fixture.file("real/\(decomposed)/dir/x", size: 5)
        fixture.file("real/plain.txt", size: 10)
        #expect(symlink("real", fixture.path + "/link") == 0)
        // Reached through a symlink (and, like every temp dir, through /var).
        let unresolved = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        #expect(!unresolved.hasPrefix("/private"))
        let viaLink = unresolved + "/" + (fixture.path as NSString).lastPathComponent + "/link"
        let tree = DiskSurveyScanTests.scan(viaLink).tree
        #expect(tree.rootPath == fixture.path + "/real")
        let menu = try #require(tree.node("\(decomposed)/menu.txt"))
        let dir = try #require(tree.node("\(decomposed)/dir"))
        let plain = try #require(tree.node("plain.txt"))
        let outcome = Self.fakeTrash(into: bin).trash(TrashService.candidates(for: [menu, dir, plain], in: tree).candidates)
        #expect(outcome.failures.isEmpty && outcome.missing.isEmpty)
        #expect(outcome.trashed.count == 3)
        #expect(TrashService.putBack(outcome.trashed).failures.isEmpty)
    }

    // MARK: Put Back identity

    @Test func putBackOnlyMovesTheItemThatWasTrashed() throws {
        let fixture = try Self.makeFixture()
        let bin = Fixture("bin")
        let tree = Self.scan(fixture)
        let top = try #require(tree.node(atPath: fixture.path + "/top.bin"))
        let a = try #require(tree.node(atPath: fixture.path + "/keep/a.bin"))
        let junk = try #require(tree.node(atPath: fixture.path + "/junk"))
        let outcome = Self.fakeTrash(into: bin).trash(TrashService.candidates(for: [top, a, junk], in: tree).candidates)
        #expect(outcome.trashed.count == 3)
        #expect(outcome.trashed.allSatisfy { $0.identity != nil })
        let trashedTop = try #require(outcome.trashed.first { $0.node == top })
        let trashedA = try #require(outcome.trashed.first { $0.node == a })
        let trashedJunk = try #require(outcome.trashed.first { $0.node == junk })
        let topURL = try #require(trashedTop.trashURL)
        let aURL = try #require(trashedA.trashURL)
        let junkURL = try #require(trashedJunk.trashURL)

        // The Trash was emptied, and unrelated items now have the remembered names:
        // another file, a folder where a file was, and nothing at all.
        try FileManager.default.removeItem(at: topURL)
        try Data("UNRELATED".utf8).write(to: topURL)
        try FileManager.default.removeItem(at: aURL)
        try FileManager.default.createDirectory(at: aURL.appending(path: "sub"), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: junkURL)

        let (restored, failures) = TrashService.putBack([trashedTop, trashedA, trashedJunk])
        #expect(restored.isEmpty)
        #expect(failures.map(\.path) == [fixture.path + "/top.bin", fixture.path + "/keep/a.bin", fixture.path + "/junk"])
        #expect(failures[0].message.contains("not the one"))
        #expect(failures[1].message.contains("not the one"))
        #expect(failures[2].message == "No longer in the Trash")
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/top.bin"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "/keep/a.bin"))
        #expect(try Data(contentsOf: topURL) == Data("UNRELATED".utf8))
        #expect(FileManager.default.fileExists(atPath: aURL.appending(path: "sub").path))

        // An item whose place or identity in the Trash is unknown is never moved blind.
        var anonymous = trashedTop
        anonymous.identity = nil
        #expect(TrashService.putBack([anonymous]).restored.isEmpty)
        let silent = TrashService(mover: { url in
            try FileManager.default.removeItem(at: url)
            return nil
        })
        let nested = try #require(tree.node(atPath: fixture.path + "/keep"))
        let unknown = silent.trash(TrashService.candidates(for: [nested], in: tree).candidates)
        #expect(unknown.trashed.first?.identity == nil)
        #expect(TrashService.putBack(unknown.trashed).restored.isEmpty)
    }

    @Test func putBackDoesNotFollowAReplacedFolder() throws {
        let fixture = Fixture("putback")
        let bin = Fixture("bin")
        fixture.file("dir/file.bin", size: 100)
        fixture.dir("elsewhere")
        let tree = Self.scan(fixture)
        let file = try #require(tree.node("dir/file.bin"))
        let outcome = Self.fakeTrash(into: bin).trash(TrashService.candidates(for: [file], in: tree).candidates)
        #expect(outcome.trashed.count == 1)
        try FileManager.default.moveItem(atPath: fixture.path + "/dir", toPath: fixture.path + "/dir.old")
        #expect(symlink("elsewhere", fixture.path + "/dir") == 0)
        let (restored, failures) = TrashService.putBack(outcome.trashed)
        #expect(restored.isEmpty && failures.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path + "/elsewhere").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).count == 1)
    }

    /// Goes through `FileManager.trashItem`: the items must land in the user's Trash, and are
    /// deleted from there again at the end.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISKSURVEY_TEST_REAL_TRASH"] == "1"))
    func realTrashReceivesTheItems() throws {
        let fixture = try Self.makeFixture()
        var tree = Self.scan(fixture)
        let junk = try #require(tree.node(atPath: fixture.path + "/junk"))
        let top = try #require(tree.node(atPath: fixture.path + "/top.bin"))
        let expected = tree.totals(of: junk).allocated + tree.size(of: top)

        let outcome = TrashService().trash(TrashService.candidates(for: [junk, top], in: tree).candidates)
        defer {
            for item in outcome.trashed {
                guard let url = item.trashURL else { continue }
                try? FileManager.default.removeItem(at: url)
                print("removed from Trash: \(!FileManager.default.fileExists(atPath: url.path))")
            }
        }
        #expect(outcome.failures.isEmpty)
        #expect(outcome.trashed.count == 2)
        for item in outcome.trashed {
            let url = try #require(item.trashURL)
            print("trashed \(item.originalPath) -> \(url.path)")
            #expect(url.path.contains("/.Trash"))
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(!FileManager.default.fileExists(atPath: item.originalPath))
        }
        #expect(TrashService.apply(outcome, to: &tree).allocated == expected)
    }
}

private extension FileTree {
    /// A copy without the node at `relative` (and everything below it).
    func removing(_ relative: String) -> FileTree {
        var copy = self
        if let node = node(relative) { copy.remove(node) }
        return copy
    }
}

private extension ScanSession {
    func also(_ body: (ScanSession) -> Void) -> ScanSession {
        body(self)
        return self
    }
}
