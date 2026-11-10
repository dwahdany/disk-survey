import Foundation
import Testing
@testable import DiskSurveyCore

@Suite struct SearchTests {
    let tree = demoTree()

    private func names(_ result: SearchResult) -> [String] { result.nodes.map { tree.name(of: $0) } }

    @Test func caseInsensitiveSubstring() {
        #expect(names(tree.search("MOV")) == ["Movies", "clip.mov"])
        #expect(names(tree.search(".mp4")) == ["holiday.MP4"])
        #expect(names(tree.search("e")).first == "Movies")
        #expect(tree.search("zzz").nodes.isEmpty)
        #expect(tree.search("zzz").totalMatches == 0)
        // The root itself is never a result.
        #expect(tree.search("Demo").totalMatches == 0)
        // An empty query matches every node below the root.
        #expect(tree.search("").totalMatches == tree.count - 1)
        #expect(SearchQuery().isUnconstrained)
        #expect(!SearchQuery(text: "a").isUnconstrained)
    }

    @Test func resultsAreLargestFirstAndCapped() {
        let all = tree.search("", limit: 100)
        let sizes = all.nodes.map { tree.size(of: $0) }
        #expect(sizes == sizes.sorted(by: >))
        let top3 = tree.search("", limit: 3)
        #expect(top3.nodes == Array(all.nodes.prefix(3)))
        #expect(top3.totalMatches == tree.count - 1)
        #expect(top3.matches.population == tree.count - 1)
        #expect(tree.search("", limit: 0).nodes.isEmpty)
    }

    @Test func scopeAndFilters() {
        #expect(names(tree.search(SearchQuery(text: "mov", scope: .files))) == ["clip.mov"])
        #expect(names(tree.search(SearchQuery(text: "mov", scope: .directories))) == ["Movies"])
        #expect(names(tree.search(SearchQuery(minSize: 100_000_000, scope: .files))) == ["holiday.MP4", "clip.mov"])
        #expect(names(tree.search(SearchQuery(minSize: 5000, maxSize: 50_000, scope: .files))) == ["main.swift", "README.md"])
        #expect(names(tree.search(SearchQuery(categories: [.video]))) == ["holiday.MP4", "clip.mov"])
        #expect(names(tree.search(SearchQuery(categories: [.code, .document], scope: .files))) == ["main.swift", "README.md", "notes.txt"])
        let gz = tree.kindID(forExtension: "gz")!
        #expect(names(tree.search(SearchQuery(kinds: [gz]))) == ["archive.tar.gz"])
        #expect(tree.search(SearchQuery(kinds: [gz], categories: [.video])).totalMatches == 0)
        // Dates: unknown (0) never matches a date criterion.
        #expect(names(tree.search(SearchQuery(modifiedBefore: 1_550_000_000))) == ["holiday.MP4", "archive.tar.gz"])
        #expect(names(tree.search(SearchQuery(modifiedAfter: 1_695_000_000))) == ["clip.mov", "main.swift"])
        #expect(names(tree.search(SearchQuery(text: "o", modifiedAfter: 1_500_000_000, modifiedBefore: 1_600_000_000)))
            == ["notes.txt"])
    }

    @Test func subtreeScope() {
        let projects = tree.id("Projects")
        #expect(names(tree.search("e", under: projects)) == ["Disk Survey.app", "Contents", "README.md", ".gitignore"])
        #expect(tree.search("Projects", under: projects).totalMatches == 0)
        #expect(tree.search("mov", under: projects).totalMatches == 0)
        #expect(tree.search("x", under: tree.id("notes.txt")).totalMatches == 0)
    }

    @Test func unicode() {
        let nfd = "Résumé Über.PDF".decomposedStringWithCanonicalMapping
        let tree = FileTree.make(rootPath: "/u", [
            .file(nfd, 10), .file("ÉCOLE.txt", 20), .file("日本語のファイル.txt", 30), .file("plain.txt", 40),
        ])
        func found(_ text: String) -> [String] { tree.search(text).nodes.map { tree.name(of: $0) }.sorted() }
        #expect(found("résumé") == [nfd])  // NFC needle, NFD name
        #expect(found("RÉSUMÉ") == [nfd])
        #expect(found("über.pdf") == [nfd])
        #expect(found("école") == ["ÉCOLE.txt"])  // non-ASCII case folding
        #expect(found("のファ") == ["日本語のファイル.txt"])
        #expect(found("sum") == [nfd])  // ASCII needle inside a non-ASCII name
        #expect(found("ñ").isEmpty)
        #expect(found("resume").isEmpty)  // case-insensitive, not diacritic-insensitive
    }

    /// Case folding rather than lowercasing: lowercasing is context sensitive (Greek final sigma)
    /// and cannot express foldings that change the length (ß ↔ SS).
    @Test func unicodeCaseFolding() {
        let tree = FileTree.make(rootPath: "/u", [
            .file("ΣΑΣ.txt", 10), .file("οδός.txt", 20), .file("straße.txt", 30), .file("GROSSE.txt", 40),
            .file("İstanbul.png", 45), .file("Profile µm.txt", 46),
            .file("Ärger.txt".decomposedStringWithCanonicalMapping, 50), .file("plain.txt", 60),
        ])
        func found(_ text: String) -> [String] {
            tree.search(text).nodes.map { tree.name(of: $0).precomposedStringWithCanonicalMapping }.sorted()
        }
        #expect(found("σας") == ["ΣΑΣ.txt"])  // the natural lowercase word, final sigma
        #expect(found("ΣΑΣ") == ["ΣΑΣ.txt"])
        #expect(found("σασ") == ["ΣΑΣ.txt"])
        #expect(found("ΟΔΌΣ") == ["οδός.txt"])
        #expect(found("οδός") == ["οδός.txt"])
        #expect(found("STRASSE") == ["straße.txt"])  // ASCII needle, non-ASCII name
        #expect(found("strasse") == ["straße.txt"])
        #expect(found("straße") == ["straße.txt"])
        #expect(found("GROSSE") == ["GROSSE.txt"])
        #expect(found("ﬁle") == ["Profile µm.txt"] && found("PROFILE ΜM") == ["Profile µm.txt"])
        // Not a simple case fold (İ is i + combining dot): needs the exact letter. Matching it
        // would take diacritic-insensitive search, which would also make "resume" find "résumé".
        #expect(found("istanbul").isEmpty)
        #expect(found("İSTANBUL") == ["İstanbul.png"])
        #expect(found("ärger") == ["Ärger.txt"])  // NFC needle, NFD name, different case
        #expect(found("ÄRGER") == ["Ärger.txt"])
        #expect(found("plain") == ["plain.txt"])
        #expect(found("σαςς").isEmpty)
        // Same answers on the parallel whole-tree path and under a subtree root.
        #expect(tree.matches(SearchQuery(text: "σας")).population == 1)
    }

    @Test func containingMaskMarksAncestors() {
        let result = tree.search("binary")
        #expect(result.totalMatches == 1)
        let mask = tree.containingMask(for: result.matches)
        let marked = Set(mask.members.map { tree.name(of: $0) })
        #expect(marked == ["Demo", "Projects", "Disk Survey.app", "Contents", "binary"])
        #expect(!mask.contains(tree.id("Movies")))
        #expect(mask.contains(0))
        #expect(!mask.contains(NodeID(tree.count + 500)))  // out of range is simply "no"
        #expect(tree.containingMask(for: NodeBitset(capacity: tree.count)).isEmpty)
    }

    @Test func bitsetBasics() {
        var set = NodeBitset(capacity: 200)
        #expect(set.isEmpty && set.population == 0)
        for id: NodeID in [0, 63, 64, 199] { set.insert(id) }
        #expect(set.members == [0, 63, 64, 199])
        #expect(set.contains(64) && !set.contains(65))
        set.remove(63)
        #expect(set.population == 3 && !set.contains(63))
    }

    @Test func parallelSearchAgreesWithBruteForce() {
        let tree = FileTree.synthetic(nodeCount: 300_000, seed: 11)  // large enough for the parallel path
        for query in [
            SearchQuery(text: "img_1"),
            SearchQuery(text: ".SWIFT", minSize: 4096, scope: .files),
            SearchQuery(minSize: 100_000_000, categories: [.video, .diskImage]),
            SearchQuery(text: "doc", scope: .directories),
        ] {
            let result = tree.search(query, limit: 50)
            var expected: [NodeID] = []
            let lowered = query.text.lowercased()
            for index in 1 ..< tree.count {
                let id = NodeID(index)
                if query.scope == .files, tree.isDirectory(id) { continue }
                if query.scope == .directories, !tree.isDirectory(id) { continue }
                if let min = query.minSize, tree.size(of: id) < min { continue }
                if let categories = query.categories, !categories.contains(tree.category(of: id)) { continue }
                if !lowered.isEmpty, !tree.name(of: id).lowercased().contains(lowered) { continue }
                expected.append(id)
            }
            #expect(result.totalMatches == expected.count, "query \(query.text)")
            #expect(result.matches.members == expected)
            expected.sort { tree.size(of: $0) != tree.size(of: $1) ? tree.size(of: $0) > tree.size(of: $1) : $0 < $1 }
            #expect(result.nodes == Array(expected.prefix(50)))
            #expect(expected.count > 0, "query \(query.text) should match something in the synthetic tree")

            // Subtree search agrees with filtering the global result by ancestry.
            let scope = tree.children(of: 0).first { tree.isDirectory($0) }!
            let scoped = tree.matches(query, under: scope).members
            #expect(scoped == expected.filter { tree.isAncestor(scope, of: $0) }.sorted())
        }
    }
}

@Suite struct LargestFilesTests {
    @Test func demoTree() {
        let tree = DiskSurveyCoreTests.demoTree()
        func names(_ ids: [NodeID]) -> [String] { ids.map { tree.name(of: $0) } }
        #expect(names(tree.largestFiles(limit: 4)) == ["holiday.MP4", "clip.mov", "binary", "archive.tar.gz"])
        #expect(names(tree.largestFiles(limit: 100)).count == 8)
        #expect(names(tree.largestFiles(limit: 4, packagesAsFiles: true)) == ["holiday.MP4", "clip.mov", "Disk Survey.app", "archive.tar.gz"])
        #expect(names(tree.largestFiles(under: tree.id("Projects"), limit: 2)) == ["binary", "main.swift"])
        #expect(tree.largestFiles(limit: 0).isEmpty)
        #expect(tree.largestFiles(under: tree.id("Empty"), limit: 3).isEmpty)
        let notes = tree.id("notes.txt")
        #expect(tree.largestFiles(under: notes, limit: 3) == [notes])
    }

    @Test func agreesWithBruteForce() {
        var tree = FileTree.synthetic(nodeCount: 60_000, seed: 21)
        // Make it interesting: mutate first.
        tree.remove(tree.child(of: 0, at: 0))
        func brute(under root: NodeID) -> [UInt64] {
            var sizes: [UInt64] = []
            tree.forEachDescendant(of: root) { if !tree.isDirectory($0) { sizes.append(tree.size(of: $0)) } }
            return sizes.sorted(by: >)
        }
        for limit in [1, 10, 500, 100_000] {
            let found = tree.largestFiles(limit: limit)
            #expect(found.map { tree.size(of: $0) } == Array(brute(under: 0).prefix(limit)))
            #expect(Set(found).count == found.count)
            #expect(found.allSatisfy { !tree.isDirectory($0) && !tree.isRemoved($0) })
        }
        let sub = tree.children(of: 0).first { tree.isDirectory($0) }!
        #expect(tree.largestFiles(under: sub, limit: 25).map { tree.size(of: $0) } == Array(brute(under: sub).prefix(25)))
    }
}

@Suite struct KindSummaryTests {
    @Test func demoTree() {
        let tree = DiskSurveyCoreTests.demoTree()
        let stats = tree.kindSummary()
        #expect(stats.map(\.ext) == ["mp4", "mov", "", "gz", "swift", "md", "txt"])
        #expect(stats[0] == KindStat(kind: tree.kindID(forExtension: "mp4")!, ext: "mp4", category: .video,
                                     size: 4_000_000_000, logicalSize: 4_000_000_000, fileCount: 1))
        // "" = binary (1_000_000) + .gitignore (2_800)
        #expect(stats[2].size == 1_002_800 && stats[2].fileCount == 2)
        #expect(stats[2].displayName == "No Extension" && stats[0].displayName == ".mp4")
        #expect(stats.last?.logicalSize == 1200)
        #expect(stats.reduce(0) { $0 + $1.size } == tree.size(of: 0))
        #expect(stats.reduce(0) { $0 + $1.fileCount } == tree.fileCount(of: 0))

        let projects = tree.kindSummary(under: tree.id("Projects"))
        #expect(projects.map(\.ext) == ["", "swift", "md"])
        #expect(tree.kindSummary(under: tree.id("notes.txt")).map(\.ext) == ["txt"])

        let categories = tree.categorySummary()
        #expect(categories.first?.category == .video)
        #expect(categories.first?.size == 4_120_000_000 && categories.first?.fileCount == 2)
        #expect(categories.reduce(0) { $0 + $1.size } == tree.size(of: 0))
    }

    @Test func syntheticTotalsAddUp() {
        let tree = FileTree.synthetic(nodeCount: 50_000, seed: 2)
        let stats = tree.kindSummary()
        #expect(stats.reduce(0) { $0 + $1.size } == tree.size(of: 0))
        #expect(stats.reduce(0) { $0 + $1.logicalSize } == tree.logicalSize(of: 0))
        #expect(stats.reduce(0) { $0 + $1.fileCount } == tree.fileCount(of: 0))
        #expect(stats.map(\.size) == stats.map(\.size).sorted(by: >))
        let sub = tree.child(of: 0, at: 0)
        #expect(tree.kindSummary(under: sub).reduce(0) { $0 + $1.size } == tree.size(of: sub))
    }
}

@Suite struct SyntheticTests {
    @Test func deterministicAndExact() {
        for n in [1, 2, 17, 1000, 25_000] {
            let a = FileTree.synthetic(nodeCount: n, seed: 42)
            #expect(a.count == n)
            #expect(invariantViolations(a).isEmpty)
        }
        let a = FileTree.synthetic(nodeCount: 25_000, seed: 42)
        let b = FileTree.synthetic(nodeCount: 25_000, seed: 42)
        let c = FileTree.synthetic(nodeCount: 25_000, seed: 43)
        #expect(a.size(of: 0) == b.size(of: 0))
        #expect((0 ..< 25_000).allSatisfy { a.name(of: NodeID($0)) == b.name(of: NodeID($0)) && a.size(of: NodeID($0)) == b.size(of: NodeID($0)) })
        #expect(Array(a.children(of: 0)) == Array(b.children(of: 0)))
        #expect(a.size(of: 0) != c.size(of: 0))
        // Looks like a disk: several categories, some depth, some packages.
        #expect(a.categorySummary().count >= 8)
        #expect((0 ..< a.count).map { a.depth(of: NodeID($0)) }.max()! >= 5)
        #expect(a.rootPath == "/Synthetic")
    }
}
