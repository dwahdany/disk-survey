import Foundation
import Testing
import DiskSurveyCore
@testable import DiskSurveyTreemap

/// Opt-in developer tools, not assertions about speed:
///
///   DISKSURVEY_BENCH=1      print layout / render timings for a 2M-node tree at 3000×2000
///   DISKSURVEY_DUMP_DIR=…   write sample renders there as BMP (convert: `sips -s format png x.bmp --out x.png`)
///
/// Run in release mode for meaningful numbers:
///   Scripts/test.sh -c release -Xswiftc -enable-testing --scratch-path .build-treemap --filter DiskSurveyTreemapTests
@Suite(.serialized) struct BenchmarkAndDump {
    static let environment = ProcessInfo.processInfo.environment

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Best of `runs`, in milliseconds.
    static func best(_ runs: Int, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        var result = Double.infinity
        for _ in 0 ..< runs { result = min(result, milliseconds(clock.measure(body))) }
        return result
    }

    @Test(.enabled(if: environment["DISKSURVEY_BENCH"] != nil))
    func twoMillionNodesAt3000x2000() {
        let tree = FileTree.synthetic(nodeCount: 2_000_000, seed: 2026)
        let bounds = TreemapRect(x: 0, y: 0, width: 3000, height: 2000)
        let bitmap = TreemapBitmap(width: 3000, height: 2000)
        let variants: [(String, TreemapStyle, Int)] = [
            ("cushion", .cushion, .max), ("framed", .framed(scale: 2), .max), ("adaptive", .adaptive(scale: 2), .max),
            ("adaptive, depth 3", .adaptive(scale: 2), 3), ("adaptive, depth 1", .adaptive(scale: 2), 1),
        ]
        for (name, style, depth) in variants {
            var options = TreemapLayoutOptions(style: style, maxDepth: depth)
            // What the app asks for: collapsed folders take the colour of most of their contents.
            options.collapsedSample = .dominantKind
            var layout = TreemapLayout(tree: tree, bounds: bounds, options: options)
            let layoutTime = Self.best(7) { layout = TreemapLayout(tree: tree, bounds: bounds, options: options) }
            let coloring = TreemapColoring.byKind(tree)
            let renderTime = Self.best(9) { TreemapRenderer.render(layout, coloring: coloring, into: bitmap) }
            var single = TreemapRenderOptions()
            single.maxThreads = 1
            let singleTime = Self.best(3) { TreemapRenderer.render(layout, coloring: coloring, options: single, into: bitmap) }
            var hits = 0
            let hitTime = Self.best(3) {
                for i in 0 ..< 100_000 {
                    let p = TreemapPoint(x: Float((i * 7919) % 3000) + 0.5, y: Float((i * 104_729) % 2000) + 0.5)
                    if layout.hitTest(p) != nil { hits += 1 }
                }
            }
            var labels: [TreemapLabel] = []
            let labelTime = Self.best(5) { labels = layout.labels() }
            print(
                """
                [benchmark] \(name): 2,000,000 nodes -> 3000×2000 px
                [benchmark]   layout:            \(String(format: "%.2f", layoutTime)) ms (\(layout.cells.count) cells, \(layout.leafCount) tiles)
                [benchmark]   render (all cores): \(String(format: "%.2f", renderTime)) ms
                [benchmark]   render (1 thread):  \(String(format: "%.2f", singleTime)) ms
                [benchmark]   hitTest:           \(String(format: "%.0f", hitTime * 1e6 / 100_000)) ns each
                [benchmark]   labels:            \(String(format: "%.2f", labelTime)) ms (\(labels.count) labels)
                """)
            #expect(hits > 0)
        }
    }

    /// The shape that makes depth-limited layouts expensive: one folder holds (nearly) the whole
    /// tree — "Library" in a home folder, "Users" on a startup disk — so the walk that finds the
    /// colour of a collapsed folder cannot simply run one folder per core.
    @Test(.enabled(if: environment["DISKSURVEY_BENCH"] != nil))
    func oneDominantFolderAtDepthLimits() {
        var tree = FileTree.make(rootPath: "/Volumes/Disk", [.dir("Users", [.file("placeholder", 1)]), .file("swapfile", 1 << 20)])
        tree.replaceSubtree(at: tree.child(of: 0, named: "Users")!, with: FileTree.synthetic(nodeCount: 2_000_000, seed: 2026))
        let bounds = TreemapRect(x: 0, y: 0, width: 3000, height: 2000)
        for depth in [1, 2, 3] {
            var options = TreemapLayoutOptions(style: .adaptive(scale: 2), maxDepth: depth)
            options.collapsedSample = .dominantKind
            let cold = Self.best(7) { _ = TreemapLayout(tree: tree, bounds: bounds, options: options) }
            let cache = CollapsedSampleCache()
            cache.use(generation: 1)
            _ = TreemapLayout(tree: tree, bounds: bounds, options: options, sampleCache: cache)
            let warm = Self.best(7) { _ = TreemapLayout(tree: tree, bounds: bounds, options: options, sampleCache: cache) }
            options.collapsedSample = .largestFile
            let plain = Self.best(7) { _ = TreemapLayout(tree: tree, bounds: bounds, options: options) }
            print(
                String(
                    format: "[benchmark] one dominant folder, depth %d: layout %.2f ms first time, %.2f ms cached (%.2f ms without colour walk)",
                    depth, cold, warm, plain))
        }
    }

    /// A tree shaped like a home directory: several top-level folders of very different sizes,
    /// each a synthetic subtree of its own.
    static func demoTree() -> FileTree {
        let folders: [(String, Int, UInt64)] = [
            ("Movies", 900, 3), ("Pictures", 9000, 12), ("Developer", 30_000, 5), ("Library", 16_000, 8),
            ("Documents", 5000, 21), ("Music", 2500, 9), ("Downloads", 1200, 17), ("Desktop", 300, 4),
            ("Archive", 4000, 30),
        ]
        var tree = FileTree.make(rootPath: "/Users/demo", folders.map { .dir($0.0, [.file("placeholder", 1)]) } + [.file("notes.txt", 40 << 20), .file("backup.zip", 900 << 20)])
        for (name, count, seed) in folders {
            let node = tree.child(of: 0, named: name)!
            tree.replaceSubtree(at: node, with: FileTree.synthetic(nodeCount: count, seed: seed))
        }
        return tree
    }

    @Test(.enabled(if: environment["DISKSURVEY_DUMP_DIR"] != nil))
    func dumpSampleRenders() throws {
        let directory = URL(fileURLWithPath: Self.environment["DISKSURVEY_DUMP_DIR"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tree = Self.demoTree()
        let bounds = TreemapRect(x: 0, y: 0, width: 1600, height: 1000)
        for scheme in PaletteScheme.allCases {
            let schemeName = scheme == .light ? "light" : "dark"
            for (name, style) in [
                ("cushion", TreemapStyle.cushion), ("grouped", .grouped(scale: 2)), ("framed", .framed(scale: 2)),
                ("adaptive", .adaptive(scale: 2)),
            ] {
                let layout = TreemapLayout(tree: tree, bounds: bounds, options: TreemapLayoutOptions(style: style))
                let bitmap = TreemapRenderer.render(
                    layout, coloring: .byKind(tree, scheme: scheme), options: .standard(scheme: scheme))
                try bitmap.writeBMP(to: directory.appendingPathComponent("\(name)-\(schemeName).bmp"))
            }
            let layout = TreemapLayout(tree: tree, bounds: bounds, options: TreemapLayoutOptions(style: .grouped(scale: 2)))
            let age = TreemapRenderer.render(
                layout, coloring: .byAge(now: FileTree.syntheticReferenceTime, scheme: scheme),
                options: .standard(scheme: scheme))
            try age.writeBMP(to: directory.appendingPathComponent("age-\(schemeName).bmp"))

            var dimmed = TreemapRenderOptions.standard(scheme: scheme)
            dimmed.highlight = tree.containingMask(for: tree.matches(SearchQuery(categories: [.image, .video])))
            let filtered = TreemapRenderer.render(layout, coloring: .byKind(tree, scheme: scheme), options: dimmed)
            try filtered.writeBMP(to: directory.appendingPathComponent("dimmed-\(schemeName).bmp"))
        }
    }
}
