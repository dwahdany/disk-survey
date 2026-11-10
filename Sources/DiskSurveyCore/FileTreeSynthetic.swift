import Foundation

extension FileTree {
    /// A node literal for building small trees in tests, previews and demos.
    ///
    /// ```swift
    /// let tree = FileTree.make(rootPath: "/Volumes/Demo", [
    ///     .dir("Movies", [
    ///         .file("holiday.mp4", 4_000_000_000),
    ///         .file("clip.mov", 120_000_000, modified: 1_700_000_000),
    ///     ]),
    ///     .dir("Empty"),
    ///     .file("notes.txt", 4096, logical: 1200),
    /// ])
    /// ```
    public struct Spec: Sendable {
        public var name: String
        public var allocated: UInt64
        public var logical: UInt64
        public var modified: Int64
        public var flags: NodeFlags
        public var itemCount: UInt32
        public var children: [Spec]
        /// Inode identity for a file with several hard links (see ``Builder/Worker``).
        public var link: LinkID? = nil
        /// The file has an execute permission bit.
        public var isExecutable = false

        /// A file. `logical` defaults to the allocated size.
        public static func file(
            _ name: String, _ size: UInt64, logical: UInt64? = nil, modified: Int64 = 0,
            flags: NodeFlags = [], itemCount: UInt32 = 1, link: LinkID? = nil, isExecutable: Bool = false
        ) -> Spec {
            Spec(
                name: name, allocated: size, logical: logical ?? size, modified: modified,
                flags: flags.subtracting(.directory), itemCount: itemCount, children: [], link: link,
                isExecutable: isExecutable)
        }

        /// A directory with the given children.
        public static func dir(
            _ name: String, modified: Int64 = 0, flags: NodeFlags = [], _ children: [Spec] = []
        ) -> Spec {
            Spec(
                name: name, allocated: 0, logical: 0, modified: modified,
                flags: flags.union(.directory), itemCount: 0, children: children)
        }
    }

    /// Builds a tree from nested literals (through the regular ``Builder``).
    public static func make(rootPath: String = "/Synthetic", rootModified: Int64 = 0, _ children: [Spec]) -> FileTree {
        let builder = Builder(rootPath: rootPath, rootModified: rootModified)
        let worker = builder.makeWorker()
        var pending: [(Builder.Ref, [Spec])] = [(.root, children)]
        while let (parent, specs) = pending.popLast() {
            for spec in specs {
                let ref = worker.append(
                    to: parent, name: spec.name, allocatedSize: spec.allocated, logicalSize: spec.logical,
                    modified: spec.modified, flags: spec.flags, itemCount: spec.itemCount, link: spec.link,
                    isExecutable: spec.isExecutable)
                if spec.flags.contains(.directory), !spec.children.isEmpty {
                    pending.append((ref, spec.children))
                }
            }
        }
        return builder.finalize()
    }

    /// The fixed "now" that ``synthetic(nodeCount:seed:rootPath:)`` dates its files against.
    public static let syntheticReferenceTime: Int64 = 1_790_000_000

    /// A deterministic, realistic-looking random tree with exactly `nodeCount` nodes (including
    /// the root), for benchmarks, demos and tests. The same arguments always give the same tree.
    ///
    /// Directories are themed (media, photos, source code, build output, …) so extensions and
    /// sizes cluster the way they do on real disks; sizes are roughly log-normal; modification
    /// times spread over the six years before ``syntheticReferenceTime``.
    public static func synthetic(nodeCount: Int, seed: UInt64 = 1, rootPath: String = "/Synthetic") -> FileTree {
        precondition(nodeCount >= 1, "a tree has at least its root")
        let builder = Builder(rootPath: rootPath, rootModified: syntheticReferenceTime)
        let worker = builder.makeWorker()
        var rng = SplitMix64(seed: seed)
        var remaining = nodeCount - 1
        var frontier: [(ref: Builder.Ref, depth: Int, theme: Int)] = [(.root, 0, 0)]
        var name: [UInt8] = []
        name.reserveCapacity(64)
        let themes = SyntheticTheme.all

        while remaining > 0 {
            if frontier.isEmpty { frontier.append((.root, 0, 0)) }
            // Picking from the most recent few dozen directories mixes deep chains with wide levels.
            let window = min(frontier.count, 48)
            let pick = frontier.count - 1 - rng.below(window)
            frontier.swapAt(pick, frontier.count - 1)
            let (dir, depth, themeIndex) = frontier.removeLast()
            let theme = themes[themeIndex]

            let roll = rng.unit()
            // Mostly small directories with a long tail, averaging ~11 entries (≈ 9 % directories).
            var fanout =
                roll < 0.85 ? 1 + rng.below(8)
                : roll < 0.98 ? 8 + rng.below(30)
                : roll < 0.999 ? 40 + rng.below(200)
                : 500 + rng.below(2500)
            fanout = min(fanout, remaining)
            remaining -= fanout
            let directoryChance = depth < 3 ? 0.40 : depth < 8 ? 0.20 : depth < 14 ? 0.08 : 0.0

            for _ in 0 ..< fanout {
                let modified = syntheticReferenceTime - Int64(pow(rng.unit(), 2.2) * 6 * 365 * 86_400)
                if rng.unit() < directoryChance {
                    // Subdirectories mostly inherit the theme; near the top they pick their own.
                    let childTheme =
                        depth < 2 || rng.unit() < 0.15
                        ? SyntheticTheme.weighted[rng.below(SyntheticTheme.weighted.count)] : themeIndex
                    name.removeAll(keepingCapacity: true)
                    name.append(contentsOf: themes[childTheme].folderWords[rng.below(themes[childTheme].folderWords.count)])
                    appendDecimal(rng.below(1000), to: &name)
                    if rng.unit() < 0.01 { name.append(contentsOf: Array(".app".utf8)) }
                    let ref = name.withUnsafeBufferPointer {
                        worker.append(
                            to: dir, name: $0, allocatedSize: 0, logicalSize: 0, modified: modified, flags: .directory)
                    }
                    frontier.append((ref, depth + 1, childTheme))
                } else {
                    let kind = theme.kinds[rng.below(theme.kinds.count)]
                    name.removeAll(keepingCapacity: true)
                    name.append(contentsOf: theme.fileWords[rng.below(theme.fileWords.count)])
                    appendDecimal(rng.below(100_000), to: &name)
                    if !kind.ext.isEmpty {
                        name.append(0x2E)
                        name.append(contentsOf: kind.ext)
                    }
                    // Sum of three uniforms ≈ a bell curve; exponentiate for a log-normal size.
                    let bell = rng.unit() + rng.unit() + rng.unit() - 1.5
                    // The -2.5 keeps the long tail from dominating: totals land near 1 MB per file.
                    let logical = UInt64(pow(2, min(36, kind.log2Size - 2.5 + bell * kind.spread * 0.45)))
                    let allocated = (logical + 4095) & ~4095
                    name.withUnsafeBufferPointer {
                        _ = worker.append(
                            to: dir, name: $0, allocatedSize: allocated, logicalSize: logical, modified: modified)
                    }
                }
            }
        }
        return builder.finalize()
    }

    private static func appendDecimal(_ value: Int, to bytes: inout [UInt8]) {
        var digits: [UInt8] = []
        var v = value
        repeat {
            digits.append(UInt8(0x30 + v % 10))
            v /= 10
        } while v > 0
        bytes.append(contentsOf: digits.reversed())
    }
}

/// SplitMix64: tiny, fast, and — unlike the system generator — reproducible from a seed.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0 ..< 1.
    mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }

    /// Uniform in 0 ..< bound (bound > 0). The slight modulo bias is irrelevant for test data.
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

private struct SyntheticTheme {
    struct Kind {
        var ext: [UInt8]
        var log2Size: Double
        var spread: Double

        init(_ ext: String, _ log2Size: Double, _ spread: Double = 4) {
            self.ext = Array(ext.utf8)
            self.log2Size = log2Size
            self.spread = spread
        }
    }

    var folderWords: [[UInt8]]
    var fileWords: [[UInt8]]
    var kinds: [Kind]

    init(folders: String, files: String, kinds: [Kind]) {
        folderWords = folders.split(separator: " ").map { Array($0.utf8) }
        fileWords = files.split(separator: " ").map { Array($0.utf8) }
        self.kinds = kinds
    }

    /// Theme indices repeated by how common such folders are: lots of code, caches and build
    /// products; few (but heavy) media folders.
    static let weighted = [0, 0, 1, 2, 2, 3, 4, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7]

    static let all: [SyntheticTheme] = [
        SyntheticTheme(
            folders: "Documents Projects Archive Work Notes Reports Shared",
            files: "report- invoice_ notes- draft_ scan_ letter- summary_",
            kinds: [
                Kind("pdf", 19), Kind("pdf", 21), Kind("docx", 16), Kind("xlsx", 15), Kind("txt", 11),
                Kind("md", 11), Kind("pages", 18), Kind("key", 21), Kind("zip", 20, 6), Kind("", 12),
            ]),
        SyntheticTheme(
            folders: "Movies Recordings Footage Exports Clips Season",
            files: "clip_ MVI_ recording- export_ episode-",
            kinds: [
                Kind("mp4", 25, 5), Kind("mov", 26, 5), Kind("mkv", 27, 4), Kind("m4v", 24), Kind("srt", 14, 2),
                Kind("jpg", 19, 2),
            ]),
        SyntheticTheme(
            folders: "Pictures Photos Camera Album Screenshots Trip",
            files: "IMG_ DSC_ Screenshot- photo_ scan-",
            kinds: [
                Kind("jpg", 21, 2), Kind("jpg", 22, 2), Kind("heic", 21, 2), Kind("png", 20, 4), Kind("cr3", 24.5, 1),
                Kind("mov", 24, 4), Kind("psd", 24, 4),
            ]),
        SyntheticTheme(
            folders: "Music Albums Podcasts Samples Stems",
            files: "track_ song- episode_ take- mix_",
            kinds: [Kind("mp3", 22, 2), Kind("m4a", 22.5, 2), Kind("flac", 24.5, 2), Kind("wav", 24, 4), Kind("jpg", 17, 2)]),
        SyntheticTheme(
            folders: "src lib Sources tests include pkg internal components utils",
            files: "main_ util_ view- model_ test_ index- handler_ types-",
            kinds: [
                Kind("swift", 12), Kind("ts", 11.5), Kind("js", 11.5), Kind("py", 12), Kind("h", 11), Kind("c", 12.5),
                Kind("json", 11, 6), Kind("md", 11), Kind("yml", 9.5, 2), Kind("rs", 12), Kind("go", 12), Kind("html", 12),
                Kind("css", 11.5), Kind("", 10),
            ]),
        SyntheticTheme(
            folders: "build DerivedData node_modules target dist cache obj Intermediates",
            files: "module_ chunk- obj_ lib part-",
            kinds: [
                Kind("o", 15, 5), Kind("o", 16, 5), Kind("a", 19, 6), Kind("dylib", 19, 6), Kind("swiftmodule", 15),
                Kind("js", 12, 5), Kind("map", 14, 5), Kind("d", 10, 2), Kind("pcm", 19, 4), Kind("json", 10, 4),
            ]),
        SyntheticTheme(
            folders: "Library Caches Containers Preferences Support Logs Data",
            files: "com.example. cache_ state- data_ store. log-",
            kinds: [
                Kind("plist", 11, 3), Kind("db", 18, 7), Kind("sqlite", 19, 7), Kind("log", 15, 6), Kind("dat", 16, 7),
                Kind("cache", 15, 5), Kind("bin", 18, 7), Kind("", 13, 6),
            ]),
        SyntheticTheme(
            folders: "Downloads Installers Backups Images VMs",
            files: "installer- backup_ image- setup_ archive-",
            kinds: [
                Kind("dmg", 25, 6), Kind("zip", 22, 7), Kind("iso", 28, 3), Kind("pkg", 24, 5), Kind("tar", 23, 6),
                Kind("gz", 20, 7), Kind("pdf", 20), Kind("ttf", 17, 2),
            ]),
    ]
}
