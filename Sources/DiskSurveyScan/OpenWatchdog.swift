import Foundation
import os

/// Gets scan threads out of a directory `open` that the system has stopped answering.
///
/// ## The problem
/// Opening a directory in another app's container (`~/Library/Containers`, `Group Containers`,
/// Mail, …) makes the kernel's sandbox ask `sandboxd` whether this process may see that app's
/// data. Now and then — measured on macOS 27.2: about once per 10,000 such questions from one
/// thread, several times as often from twelve — the thread that asked is never woken up when
/// the answer arrives. It then sits in `open` until the kernel gives up after exactly 5 s and
/// fails the call with `EINTR`; the retry succeeds at once. The answer was there all along:
/// while a thread is stuck, another thread opens the very same directory in 0.2 ms. A plain C
/// program that walks `~/Library` with `opendir`/`readdir` shows the same stalls, with any
/// number of threads (one included), so nothing in the scanner causes them. But one stuck
/// thread holds the last subtrees of its part of the tree, so a 2 s scan took 7 s.
///
/// ## The remedy
/// That wait is interruptible. A watchdog thread looks at every worker a few times per second
/// and sends a signal to one that has been inside `open` for longer than its allowance; the
/// call then fails with `EINTR` right away and the worker's normal retry gets the directory.
/// Nothing is skipped and nothing is guessed — the same directory is opened by the same code,
/// only without the five-second wait.
///
/// An `open` that is slow for an honest reason (a network volume, a disk spinning up) is not
/// harmed: waits for local disk I/O are not interruptible in the first place, and where a wait
/// is, every interruption doubles the allowance of that directory until, past
/// ``allowanceLimit``, the watchdog leaves it alone.
///
/// The signal is `SIGURG`, whose default action is to be ignored, with an empty handler
/// installed without `SA_RESTART` (an ignored signal would not interrupt anything). If the
/// host process already has its own `SIGURG` handler the watchdog stays off and the scan
/// behaves as it did before.
final class OpenWatchdog: @unchecked Sendable {
    /// How long an `open` may take before it is interrupted the first time. Opens that do wait
    /// for `sandboxd` normally take 0.2–20 ms, and up to about 110 ms when twelve threads queue
    /// up behind each other there.
    static let initialAllowance: UInt64 = 250_000_000
    /// Beyond this the kernel's own 5 s limit is no worse, so the watchdog stops interfering.
    static let allowanceLimit: UInt64 = 4_000_000_000
    /// How often the workers are looked at.
    static let pollInterval: TimeInterval = 0.05

    /// One worker thread's state, shared between that thread and the watchdog.
    final class Slot: @unchecked Sendable {
        fileprivate struct State {
            var thread: pthread_t?
            /// When the current `open` attempt started (`CLOCK_UPTIME_RAW`); 0 = not in `open`.
            var since: UInt64 = 0
            var allowance: UInt64 = 0
            var interruptions: UInt64 = 0
        }

        fileprivate let state = OSAllocatedUnfairLock<State>(uncheckedState: State())
        /// The allowance every directory starts with.
        private let initial: UInt64
        /// Whether the thread had the signal blocked when it registered.
        fileprivate let wasBlocked: Bool

        fileprivate init(thread: pthread_t, initial: UInt64, wasBlocked: Bool) {
            self.initial = initial
            self.wasBlocked = wasBlocked
            state.withLockUnchecked {
                $0.thread = thread
                $0.allowance = initial
            }
        }

        /// The calling thread is about to open a directory (first attempt).
        @inline(__always)
        func beginOpen(at now: UInt64) {
            let initial = self.initial
            state.withLockUnchecked {
                $0.since = now
                $0.allowance = initial
            }
        }

        /// The calling thread retries after `EINTR`: the clock restarts, the allowance stays
        /// as the watchdog left it.
        func retryOpen() {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            state.withLockUnchecked { $0.since = now }
        }

        /// The `open` is over, however it ended. Once this returns no signal will be sent to
        /// the thread: the watchdog signals only while holding the same lock.
        @inline(__always)
        func endOpen() {
            state.withLockUnchecked { $0.since = 0 }
        }

        /// Number of times this thread was interrupted so far.
        var interruptions: UInt64 { state.withLockUnchecked { $0.interruptions } }
    }

    private let slots = OSAllocatedUnfairLock<[Slot]>(initialState: [])
    private let wake = NSCondition()
    private var stopping = false
    private var stopped = false
    private let allowance: UInt64
    private let limit: UInt64
    private let pollInterval: TimeInterval

    /// Starts the watchdog thread, or returns nil when the signal cannot be used.
    init?(
        initialAllowance: UInt64 = OpenWatchdog.initialAllowance,
        allowanceLimit: UInt64 = OpenWatchdog.allowanceLimit,
        pollInterval: TimeInterval = OpenWatchdog.pollInterval
    ) {
        guard OpenWatchdog.signalIsReady else { return nil }
        allowance = initialAllowance
        limit = allowanceLimit
        self.pollInterval = pollInterval
        let thread = Thread { [self] in watch() }
        thread.name = "DiskSurvey scan watchdog"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Registers the calling thread. Pair with ``unregister(_:)``, on the same thread, before
    /// it exits.
    ///
    /// The signal is unblocked for the thread until then: threads inherit their creator's
    /// signal mask, and a host that blocks signals (the SwiftPM test runner does) would
    /// otherwise leave the watchdog without effect.
    func register() -> Slot {
        var signals = sigset_t()
        var previous = sigset_t()
        sigemptyset(&signals)
        sigaddset(&signals, OpenWatchdog.signal)
        pthread_sigmask(SIG_UNBLOCK, &signals, &previous)
        let slot = Slot(
            thread: pthread_self(), initial: allowance, wasBlocked: sigismember(&previous, OpenWatchdog.signal) == 1)
        slots.withLock { $0.append(slot) }
        return slot
    }

    func unregister(_ slot: Slot) {
        slot.state.withLockUnchecked {
            $0.thread = nil
            $0.since = 0
        }
        slots.withLock { all in all.removeAll { $0 === slot } }
        if slot.wasBlocked {
            var signals = sigset_t()
            sigemptyset(&signals)
            sigaddset(&signals, OpenWatchdog.signal)
            pthread_sigmask(SIG_BLOCK, &signals, nil)
        }
    }

    /// Stops the watchdog thread and waits until it is gone.
    func stop() {
        wake.lock()
        stopping = true
        wake.broadcast()
        while !stopped { wake.wait() }
        wake.unlock()
    }

    private func watch() {
        wake.lock()
        while !stopping {
            wake.unlock()
            sweep()
            wake.lock()
            if stopping { break }
            wake.wait(until: Date(timeIntervalSinceNow: pollInterval))
        }
        stopped = true
        wake.broadcast()
        wake.unlock()
    }

    private func sweep() {
        let current = slots.withLock { $0 }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for slot in current {
            slot.state.withLockUnchecked { state in
                guard let thread = state.thread, state.since != 0, now > state.since,
                    now - state.since >= state.allowance, state.allowance <= limit
                else { return }
                // Sent under the slot's lock, so the thread is still alive and has not yet
                // been told (by `endOpen`) that the call is over.
                pthread_kill(thread, OpenWatchdog.signal)
                state.interruptions += 1
                state.since = now
                state.allowance &*= 2
            }
        }
    }

    // MARK: Signal

    static let signal = SIGURG

    /// Installs the empty handler once per process. False when `SIGURG` already has a handler
    /// that is not ours (it is left alone, and no watchdog runs).
    static let signalIsReady: Bool = {
        var existing = sigaction()
        guard sigaction(signal, nil, &existing) == 0 else { return false }
        // SIG_DFL is 0 and SIG_IGN is 1; anything else is somebody's handler.
        let handler = unsafeBitCast(existing.__sigaction_u.__sa_handler, to: Int.self)
        guard handler == 0 || handler == 1 else { return false }
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0  // no SA_RESTART: the point is that `open` fails with EINTR
        return sigaction(signal, &action, nil) == 0
    }()
}
