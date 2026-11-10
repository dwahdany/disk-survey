import Foundation
import Testing
@testable import DiskSurveyCore

@Suite struct RemoveTests {
    @Test func removeFileUpdatesAncestorsAndOrder() {
        var tree = demoTree()
        let original = tree
        let holiday = tree.id("Movies/holiday.MP4")
        let movies = tree.id("Movies")
        let rootSize = tree.size(of: 0)

        let freed = tree.remove(holiday)
        #expect(freed == FileTree.Totals(allocated: 4_000_000_000, logical: 4_000_000_000, fileCount: 1))
        #expect(tree.isRemoved(holiday))
        #expect(tree.size(of: holiday) == 0 && tree.fileCount(of: holiday) == 0)
        #expect(tree.size(of: movies) == 120_000_000)
        #expect(tree.fileCount(of: movies) == 1)
        #expect(tree.size(of: 0) == rootSize - 4_000_000_000)
        #expect(tree.fileCount(of: 0) == 7)
        #expect(tree.childNames(movies) == ["clip.mov"])
        #expect(tree.childNames(0) == ["Movies", "Projects", "archive.tar.gz", "notes.txt", "Empty"])
        #expect(tree.node(atPath: "/Volumes/Demo/Movies/holiday.MP4") == nil)
        #expect(tree.count == original.count)
        #expect(tree.revision == original.revision + 1)
        #expect(invariantViolations(tree).isEmpty)

        // Value semantics: the copy taken before is untouched.
        #expect(original.size(of: 0) == rootSize)
        #expect(original.childNames(movies) == ["holiday.MP4", "clip.mov"])

        // Removing again is a harmless no-op.
        #expect(tree.remove(holiday) == .zero)
        #expect(tree.revision == original.revision + 1)

        // Movies (120 MB) still leads; remove clip.mov and it must sink behind everything
        // non-empty — and behind "Empty" too: equal sizes order by NodeID, and Empty is older.
        tree.remove(tree.id("Movies/clip.mov"))
        #expect(tree.childNames(0) == ["Projects", "archive.tar.gz", "notes.txt", "Empty", "Movies"])
        #expect(invariantViolations(tree).isEmpty)
    }

    @Test func removeDirectoryTombstonesSubtree() {
        var tree = demoTree()
        let projects = tree.id("Projects")
        let binary = tree.id("Projects/Disk Survey.app/Contents/binary")
        let readme = tree.id("Projects/README.md")
        let before = tree.totals(of: 0)

        let freed = tree.remove(projects)
        #expect(freed == FileTree.Totals(allocated: 1_050_800, logical: 1_050_800, fileCount: 4))
        #expect(tree.isRemoved(projects) && tree.isRemoved(binary) && tree.isRemoved(readme))
        #expect(tree.size(of: binary) == 0)
        #expect(tree.size(of: 0) == before.allocated - 1_050_800)
        #expect(tree.fileCount(of: 0) == before.fileCount - 4)
        #expect(tree.childNames(0) == ["Movies", "archive.tar.gz", "notes.txt", "Empty"])
        #expect(invariantViolations(tree).isEmpty)

        // Queries no longer see anything from the removed subtree.
        #expect(tree.search("readme").totalMatches == 0)
        #expect(!tree.largestFiles(limit: 100).contains(binary))
        #expect(!tree.kindSummary().contains { $0.ext == "swift" })
        #expect(tree.largestFiles(under: projects, limit: 5).isEmpty)
    }

    @Test func removeManyCountsNestedNodesOnce() {
        var tree = demoTree()
        let ids = [tree.id("Projects/README.md"), tree.id("Projects"), tree.id("Projects/main.swift"), tree.id("notes.txt")]
        let freed = tree.remove(ids)
        // README (8000) first, then the rest of Projects, main.swift already gone, then notes.
        #expect(freed.allocated == 1_050_800 + 4096)
        #expect(freed.fileCount == 5)
        #expect(tree.size(of: 0) == 4_120_000_000 + 900_000)
        #expect(invariantViolations(tree).isEmpty)
    }

    @Test func removeEverythingOnSyntheticTree() {
        var tree = FileTree.synthetic(nodeCount: 20_000, seed: 7)
        var rng = SplitMix64(seed: 99)
        var freedTotal: UInt64 = 0
        let initial = tree.size(of: 0)
        for _ in 0 ..< 400 {
            let id = NodeID(1 + rng.next() % UInt64(tree.count - 1))
            freedTotal += tree.remove(id).allocated
        }
        #expect(tree.size(of: 0) == initial - freedTotal)
        #expect(invariantViolations(tree).isEmpty)
        for child in Array(tree.children(of: 0)) { tree.remove(child) }
        #expect(tree.size(of: 0) == 0 && tree.fileCount(of: 0) == 0 && tree.children(of: 0).isEmpty)
    }
}

@Suite struct ReplaceSubtreeTests {
    @Test func graftGrowsAndShrinks() {
        var tree = demoTree()
        let projects = tree.id("Projects")
        let oldReadme = tree.id("Projects/README.md")
        let countBefore = tree.count
        let rootBefore = tree.totals(of: 0)

        // Rescan result: Projects is now far bigger than Movies and has a new kind.
        let rescanned = FileTree.make(rootPath: "/Volumes/Demo/Projects", rootModified: 1_800_000_000, [
            .file("main.swift", 50_000),
            .dir("Models", [.file("weights.safetensors", 9_000_000_000, logical: 8_999_999_000)]),
            .file("clip.MOV", 1000),
        ])
        let change = tree.replaceSubtree(at: projects, with: rescanned)
        #expect(change.before.allocated == 1_050_800)
        #expect(change.after.allocated == 9_000_051_000)

        #expect(tree.count == countBefore + rescanned.count - 1)
        #expect(tree.name(of: projects) == "Projects")
        #expect(tree.parent(of: projects) == 0)
        #expect(tree.size(of: projects) == 9_000_051_000)
        #expect(tree.fileCount(of: projects) == 3)
        #expect(tree.modified(of: projects) == 1_800_000_000)
        #expect(tree.size(of: 0) == rootBefore.allocated - 1_050_800 + 9_000_051_000)
        #expect(tree.logicalSize(of: 0) == rootBefore.logical - 1_050_800 + 9_000_050_000)
        #expect(tree.fileCount(of: 0) == rootBefore.fileCount - 4 + 3)
        #expect(tree.childNames(0) == ["Projects", "Movies", "archive.tar.gz", "notes.txt", "Empty"])
        #expect(tree.childNames(projects) == ["Models", "main.swift", "clip.MOV"])
        #expect(tree.isRemoved(oldReadme))
        #expect(tree.node(atPath: "/Volumes/Demo/Projects/README.md") == nil)

        let weights = tree.id("Projects/Models/weights.safetensors")
        #expect(tree.path(of: weights) == "/Volumes/Demo/Projects/Models/weights.safetensors")
        #expect(tree.fileKind(of: weights).ext == "safetensors")
        #expect(tree.category(of: weights) == .data)
        // Existing kinds are reused rather than duplicated.
        #expect(tree.kind(of: tree.id("Projects/clip.MOV")) == tree.kind(of: tree.id("Movies/clip.mov")))
        #expect(Set(tree.kinds.map(\.ext)).count == tree.kinds.count)
        #expect(tree.kindID(forExtension: "safetensors") != nil)
        #expect(invariantViolations(tree).isEmpty)
        #expect(tree.largestFiles(limit: 1) == [weights])
        #expect(tree.search("readme").totalMatches == 0)

        // Shrink it again: an empty rescan.
        tree.replaceSubtree(at: projects, with: FileTree.empty(rootPath: "/Volumes/Demo/Projects"))
        #expect(tree.size(of: projects) == 0 && tree.children(of: projects).isEmpty)
        #expect(tree.isRemoved(weights))
        #expect(tree.size(of: 0) == rootBefore.allocated - 1_050_800)
        #expect(tree.childNames(0) == ["Movies", "archive.tar.gz", "notes.txt", "Projects", "Empty"])
        #expect(invariantViolations(tree).isEmpty)
    }

    @Test func graftKeepsPackageFlagAndWorksDeepAndAtRoot() {
        var tree = demoTree()
        let app = tree.id("Projects/Disk Survey.app")
        tree.replaceSubtree(
            at: app, with: FileTree.make(rootPath: "/Volumes/Demo/Projects/Disk Survey.app", [.file("Info.plist", 2_000_000)]))
        #expect(tree.flags(of: app).contains([.directory, .package]))
        #expect(tree.size(of: app) == 2_000_000)
        #expect(tree.size(of: tree.id("Projects")) == 2_050_800)
        #expect(tree.id("Projects/Disk Survey.app/Info.plist") != 0)
        #expect(invariantViolations(tree).isEmpty)

        let fresh = FileTree.make(rootPath: "/Volumes/Demo", [.file("only.bin", 42)])
        tree.replaceSubtree(at: 0, with: fresh)
        #expect(tree.size(of: 0) == 42)
        #expect(tree.childNames(0) == ["only.bin"])
        #expect(tree.path(of: tree.id("only.bin")) == "/Volumes/Demo/only.bin")
        #expect(invariantViolations(tree).isEmpty)
    }

    @Test func repeatedGraftsOfSyntheticTreesStayConsistent() {
        var tree = FileTree.synthetic(nodeCount: 5000, seed: 3)
        var rng = SplitMix64(seed: 5)
        for round in 0 ..< 20 {
            // Pick a live directory.
            var target: NodeID = 0
            for _ in 0 ..< 1000 {
                let candidate = NodeID(rng.next() % UInt64(tree.count))
                if tree.isDirectory(candidate), !tree.isRemoved(candidate) {
                    target = candidate
                    break
                }
            }
            let replacement = FileTree.synthetic(
                nodeCount: 1 + Int(rng.next() % 800), seed: UInt64(round), rootPath: tree.path(of: target))
            let expectedRoot = tree.size(of: 0) - tree.size(of: target) + replacement.size(of: 0)
            tree.replaceSubtree(at: target, with: replacement)
            #expect(tree.size(of: 0) == expectedRoot)
            #expect(invariantViolations(tree).isEmpty)
        }
    }
}
