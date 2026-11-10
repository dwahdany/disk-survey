import Foundation
import Synchronization
import Testing
import DiskSurveyCore
@testable import DiskSurveyScan

/// The watchdog that gets scan threads out of a stalled `open`.
///
/// The real stall (the kernel never waking a thread that waits for a sandbox decision) cannot
/// be produced on demand, so these tests use the closest thing that can: opening a FIFO for
/// reading blocks, interruptibly, until somebody opens it for writing.
@Suite(.serialized) struct OpenWatchdogTests {
    /// A FIFO nobody writes to, plus a way to release whoever is blocked on it.
    final class Fifo: @unchecked Sendable {
        let path: String

        init(in fixture: Fixture, name: String = "fifo") {
            path = fixture.path + "/" + name
            precondition(mkfifo(path, 0o600) == 0)
        }

        /// Blocks until a writer appears or a signal arrives; returns `errno` (0 = opened).
        func blockingOpen() -> Int32 {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return 0
            }
            return errno
        }

        /// Lets a blocked reader through (the safety net that keeps a failing test from hanging).
        func release() {
            let fd = open(path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
        }
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start) / 1e9
    }

    @Test func aThreadStuckInOpenIsInterrupted() throws {
        let fixture = Fixture("watchdog")
        let fifo = Fifo(in: fixture)
        let watchdog = try #require(OpenWatchdog(initialAllowance: 50_000_000, pollInterval: 0.01))
        defer { watchdog.stop() }

        let outcome = Mutex<(errno: Int32, seconds: Double, interruptions: UInt64)?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let slot = watchdog.register()
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            slot.beginOpen(at: start)
            let code = fifo.blockingOpen()
            slot.endOpen()
            let elapsed = Self.seconds(since: start)
            outcome.withLock { $0 = (code, elapsed, slot.interruptions) }
            watchdog.unregister(slot)
            done.signal()
        }
        thread.start()
        if done.wait(timeout: .now() + 10) == .timedOut {
            fifo.release()
            done.wait()
        }
        let result = try #require(outcome.withLock { $0 })
        #expect(result.errno == EINTR)
        #expect(result.interruptions == 1)
        #expect(result.seconds >= 0.05 && result.seconds < 5)
    }

    @Test func aThreadOutsideOpenIsLeftAlone() throws {
        let fixture = Fixture("watchdog-idle")
        let fifo = Fifo(in: fixture)
        let watchdog = try #require(OpenWatchdog(initialAllowance: 20_000_000, pollInterval: 0.01))
        defer { watchdog.stop() }

        // Registered, and blocked in the same interruptible call, but not between
        // beginOpen/endOpen: no signal may arrive.
        let outcome = Mutex<(errno: Int32, interruptions: UInt64)?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let slot = watchdog.register()
            slot.beginOpen(at: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
            slot.endOpen()
            let code = fifo.blockingOpen()
            outcome.withLock { $0 = (code, slot.interruptions) }
            watchdog.unregister(slot)
            done.signal()
        }
        thread.start()
        #expect(done.wait(timeout: .now() + 0.4) == .timedOut)
        fifo.release()
        done.wait()
        let result = try #require(outcome.withLock { $0 })
        #expect(result.errno == 0)
        #expect(result.interruptions == 0)
    }

    @Test func everyInterruptionDoublesTheAllowanceUntilTheWatchdogGivesUp() throws {
        let fixture = Fixture("watchdog-backoff")
        let fifo = Fifo(in: fixture)
        // Allowances 20, 40, 80 ms are interrupted; the next would be 160 ms, past the limit.
        let watchdog = try #require(
            OpenWatchdog(initialAllowance: 20_000_000, allowanceLimit: 100_000_000, pollInterval: 0.005))
        defer { watchdog.stop() }

        let interruptions = Mutex<[Double]>([])
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let slot = watchdog.register()
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            slot.beginOpen(at: start)
            while fifo.blockingOpen() == EINTR {
                interruptions.withLock { $0.append(Self.seconds(since: start)) }
                slot.retryOpen()
            }
            slot.endOpen()
            watchdog.unregister(slot)
            done.signal()
        }
        thread.start()
        // 20 + 40 + 80 = 140 ms of interruptions, then silence.
        #expect(done.wait(timeout: .now() + 1.2) == .timedOut)
        fifo.release()
        done.wait()
        let times = interruptions.withLock { $0 }
        #expect(times.count == 3)
        if times.count == 3 {
            #expect(times[0] >= 0.02)
            #expect(times[1] - times[0] >= 0.04)
            #expect(times[2] - times[1] >= 0.08)
        }
    }

    /// End to end: one directory's `open` hangs the way the real one does (it blocks until it
    /// is interrupted, then fails with EINTR, and the retry works). The scan must not wait for
    /// it, and must come out complete.
    @Test func aStalledDirectoryOpenDoesNotHoldUpTheScan() throws {
        let fixture = Fixture("stalled-open")
        for index in 0 ..< 40 { fixture.file("d\(index)/f\(index)", size: 1000 + index) }
        fixture.file("stuck/inner/deep.bin", size: 50_000)
        fixture.file("stuck/top.bin", size: 7)
        let reference = ReferenceTotals.walk(fixture.path)
        let side = Fixture("stalled-open-fifo")
        let fifo = Fifo(in: side)
        let stuckPath = fixture.path + "/stuck"

        for bulk in [true, false] {
            let attempts = Atomic<Int>(0)
            let session = ScanSession(root: fixture.url, options: { var o = ScanOptions(); o.useBulkAttributes = bulk; return o }())
            session.openHook = { path, _ in
                guard strcmp(path, stuckPath) == 0 else { return nil }
                // Only the first attempt hangs.
                guard attempts.add(1, ordering: .relaxed).newValue == 1 else { return nil }
                let code = fifo.blockingOpen()
                errno = code == 0 ? EINTR : code
                return -1
            }
            // Safety net: without the watchdog the open would hang forever.
            let released = Atomic<Bool>(false)
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if !released.load(ordering: .relaxed) { fifo.release() }
            }
            session.start()
            let result = session.waitBlocking()
            released.store(true, ordering: .relaxed)

            #expect(attempts.load(ordering: .relaxed) == 2)
            #expect(result.stats.interruptedDirectoryOpens == 1)
            #expect(result.duration < 3, "the scan waited \(result.duration) s for a stalled open")
            #expect(result.stats.slowDirectoryOpens == 1)
            #expect(result.stats.slowestDirectoryPath == stuckPath)
            #expect(result.stats.slowestDirectoryOpen >= 0.25)

            // Nothing was dropped or flagged.
            let tree = result.tree
            #expect(result.issues.isEmpty)
            #expect(tree.size(of: tree.root) == reference.allocated)
            #expect(tree.logicalSize(of: tree.root) == reference.logical)
            #expect(Int(result.stats.files) == reference.files)
            #expect(Int(result.stats.directories) == reference.directories)
            let stuck = try #require(tree.node("stuck"))
            #expect(!tree.flags(of: stuck).contains(.unreadable))
            #expect(tree.logicalSize(of: stuck) == 50_007)
            #expect(tree.node("stuck/inner/deep.bin") != nil)
            #expect(tree.invariantViolations().isEmpty)
        }
    }

    @Test func theWatchdogCanBeSwitchedOffAndChangesNothingInANormalScan() {
        let fixture = Fixture("watchdog-off")
        for index in 0 ..< 50 { fixture.file("d\(index)/sub/f", size: 100 * index) }
        let on = scan(fixture.path)
        let off = scan(fixture.path) { $0.interruptStalledOpens = false }
        #expect(ScanOptions().interruptStalledOpens)
        #expect(on.stats.interruptedDirectoryOpens == 0)
        #expect(off.stats.interruptedDirectoryOpens == 0)
        #expect(on.tree.count == off.tree.count)
        #expect(on.tree.size(of: on.tree.root) == off.tree.size(of: off.tree.root))
        #expect(on.stats.files == off.stats.files && on.stats.directories == off.stats.directories)
        #expect(on.issues.isEmpty && off.issues.isEmpty)
    }

    @Test func theSignalHandlerDoesNotRestartSystemCalls() {
        #expect(OpenWatchdog.signalIsReady)
        var action = sigaction()
        #expect(sigaction(OpenWatchdog.signal, nil, &action) == 0)
        #expect(action.sa_flags & SA_RESTART == 0)
        // A real handler, not SIG_DFL (0) or SIG_IGN (1): an ignored signal interrupts nothing.
        #expect(unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) > 1)
    }
}
