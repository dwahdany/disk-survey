import Foundation
import Testing
@testable import DiskSurveyCore

/// Not assertions about speed (CI machines vary) — these print the numbers and check sanity.
@Suite(.serialized) struct Benchmarks {
    @Test func twoMillionNodeSyntheticTree() {
        let n = 2_000_000
        let clock = ContinuousClock()
        var tree = FileTree.empty()
        let build = clock.measure { tree = FileTree.synthetic(nodeCount: n, seed: 2026) }
        #expect(tree.count == n)

        let perNode = Double(tree.memoryFootprint) / Double(n)
        var names = 0
        for index in stride(from: 0, to: n, by: 1) { names += tree.nameUTF8(of: NodeID(index)).count }
        let withoutNames = Double(tree.memoryFootprint - names) / Double(n)

        var hits = 0
        let search = clock.measure { hits = tree.search("img_12", limit: 100).totalMatches }
        var largest: [NodeID] = []
        let top = clock.measure { largest = tree.largestFiles(limit: 1000) }
        var kinds = 0
        let summary = clock.measure { kinds = tree.kindSummary().count }
        var mutated = tree
        let removal = clock.measure { mutated.remove(largest[0]) }

        print(
            """
            [benchmark] synthetic tree, \(n) nodes (\(tree.fileCount(of: 0)) files, \(Format.bytes(tree.size(of: 0), symbols: .posix)))
            [benchmark]   generate + build:      \(build)
            [benchmark]   memory:                \(String(format: "%.1f", perNode)) bytes/node incl. names, \(String(format: "%.1f", withoutNames)) excl. names (\(Format.bytes(UInt64(tree.memoryFootprint), symbols: .posix)) total)
            [benchmark]   search "img_12":       \(search) (\(hits) matches)
            [benchmark]   largestFiles(1000):    \(top)
            [benchmark]   kindSummary:           \(summary) (\(kinds) kinds)
            [benchmark]   remove (copy-on-write): \(removal)
            """)
        #expect(withoutNames <= 52)
        #expect(largest.count == 1000)
        #expect(hits > 0 && kinds > 10)
        #expect(mutated.size(of: 0) == tree.size(of: 0) - tree.size(of: largest[0]))
    }

    @Test func parallelFeedAndFinalize() {
        // What a scanner does: N threads appending raw entries, then one finalize.
        let threads = 8
        let perThread = 250_000
        let builder = FileTree.Builder(rootPath: "/bench")
        let workers = (0 ..< threads).map { _ in builder.makeWorker() }
        let clock = ContinuousClock()
        let feed = clock.measure {
            DispatchQueue.concurrentPerform(iterations: threads) { t in
                let worker = workers[t]
                var rng = SplitMix64(seed: UInt64(t))
                var dirs: [FileTree.Builder.Ref] = [.root]
                var name = Array("file-000000.jpeg".utf8)
                for i in 0 ..< perThread {
                    var v = i
                    for digit in 0 ..< 6 {
                        name[10 - digit] = UInt8(0x30 + v % 10)
                        v /= 10
                    }
                    let parent = dirs[Int(rng.next() % UInt64(dirs.count))]
                    let isDir = i % 12 == 0
                    let ref = name.withUnsafeBufferPointer {
                        worker.append(
                            to: parent, name: $0, allocatedSize: rng.next() % 10_000_000, logicalSize: 1,
                            modified: 1_700_000_000, flags: isDir ? .directory : [])
                    }
                    if isDir { dirs.append(ref) }
                }
            }
        }
        var partial = FileTree.empty()
        let snapshot = clock.measure { partial = builder.snapshot() }
        var tree = FileTree.empty()
        let finalize = clock.measure { tree = builder.finalize() }
        let total = threads * perThread
        print(
            """
            [benchmark] builder, \(threads) threads x \(perThread) entries
            [benchmark]   append:    \(feed)  (\(String(format: "%.0f", feed / .nanoseconds(1) / Double(perThread))) ns/entry per thread)
            [benchmark]   snapshot:  \(snapshot)
            [benchmark]   finalize:  \(finalize)
            """)
        #expect(partial.count == total + 1 && tree.count == total + 1)
        #expect(partial.size(of: 0) == tree.size(of: 0))
        #expect(tree.fileCount(of: 0) == total - threads * ((perThread + 11) / 12))
    }
}
