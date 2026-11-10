import Foundation
import Synchronization
import DiskSurveyCore

/// A directory waiting to be read: its absolute path (malloc'd, NUL-terminated, owned by whoever
/// holds the item) and the builder reference its entries hang under.
struct DirWork {
    var path: UnsafeMutablePointer<UInt8>
    var length: Int
    var ref: FileTree.Builder.Ref
    /// Number of entries the parent's listing announced for this directory; -1 = unknown.
    var expectedEntries = -1

    func free() { Darwin.free(path) }

    var string: String { String(decoding: UnsafeBufferPointer(start: path, count: length), as: UTF8.self) }

    /// `parent + "/" + name`, without doubling the slash under "/".
    @inline(__always)
    static func joining(
        _ parent: UnsafePointer<UInt8>, _ parentLength: Int, _ name: UnsafePointer<UInt8>, _ nameLength: Int,
        ref: FileTree.Builder.Ref
    ) -> DirWork {
        let prefix = parentLength == 1 ? 0 : parentLength  // parent "/" contributes only the separator
        let total = prefix + 1 + nameLength
        let p = malloc(total + 1)!.assumingMemoryBound(to: UInt8.self)
        memcpy(p, parent, prefix)
        p[prefix] = 0x2F
        memcpy(p + prefix + 1, name, nameLength)
        p[total] = 0
        return DirWork(path: p, length: total, ref: ref)
    }

    static func make(path: String, ref: FileTree.Builder.Ref) -> DirWork {
        let bytes = Array(path.utf8)
        let p = malloc(bytes.count + 1)!.assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeBufferPointer { if $0.count > 0 { memcpy(p, $0.baseAddress!, $0.count) } }
        p[bytes.count] = 0
        return DirWork(path: p, length: bytes.count, ref: ref)
    }
}

/// The shared half of the scheduler.
///
/// Every worker keeps a private LIFO stack of directories (depth-first, so the number of pending
/// directories stays small and paths stay hot in the name cache) and touches this shared pool
/// only to donate surplus work or when it has run dry. That keeps the lock out of the hot path:
/// a worker deep in a big subtree takes it once per few hundred directories, not once per
/// directory.
///
/// Termination: the scan is over when the pool is empty and every worker is waiting on it —
/// work can only be added by a worker that is not waiting.
final class WorkPool: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [DirWork] = []
    private var waiting = 0
    private var finished = false
    private let workerCount: Int

    /// Number of workers blocked in `take` — read without the lock by busy workers to decide
    /// whether donating is worthwhile.
    let hungry = Atomic<Int>(0)
    /// Approximate pool size, same purpose.
    let available = Atomic<Int>(0)

    init(workerCount: Int) { self.workerCount = workerCount }

    func push(_ work: DirWork) {
        condition.lock()
        items.append(work)
        available.store(items.count, ordering: .relaxed)
        condition.signal()
        condition.unlock()
    }

    /// Moves the oldest `count` items of a worker's stack into the pool. The oldest items are
    /// the shallowest directories, i.e. usually the biggest subtrees — the best ones to hand to
    /// another thread.
    func donate(from local: inout [DirWork], count: Int) {
        guard count > 0 else { return }
        condition.lock()
        items.append(contentsOf: local[0 ..< count])
        available.store(items.count, ordering: .relaxed)
        if waiting > 0 { condition.broadcast() }
        condition.unlock()
        local.removeFirst(count)
    }

    /// Blocks until work is available and moves a fair share of it into `local`.
    /// Returns false when the whole scan is finished.
    func take(into local: inout [DirWork]) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if !items.isEmpty {
                // A share, not everything: the other hungry workers want some too.
                let share = max(1, min(items.count / workerCount, 64))
                local.append(contentsOf: items[(items.count - share)...])
                items.removeLast(share)
                available.store(items.count, ordering: .relaxed)
                return true
            }
            if finished { return false }
            waiting += 1
            if waiting == workerCount {
                finished = true
                condition.broadcast()
                return false
            }
            hungry.add(1, ordering: .relaxed)
            condition.wait()
            hungry.subtract(1, ordering: .relaxed)
            waiting -= 1
        }
    }

    /// Frees whatever is left (only non-empty if workers were never started).
    func drain() {
        condition.lock()
        for item in items { item.free() }
        items.removeAll()
        condition.unlock()
    }
}
