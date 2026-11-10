import Foundation
import Testing
import DiskSurveyCore
@testable import DiskSurveyScan

/// Throughput measurement on a real directory. Disabled unless a path is given:
///
///     DISKSURVEY_BENCH=/System/Library Scripts/test.sh -c release -Xswiftc -enable-testing \
///         --scratch-path .build-scan --filter ScanBenchmark
///
/// Optional: `DISKSURVEY_BENCH_THREADS=1,2,4,8` (thread counts to compare; default: automatic),
/// `DISKSURVEY_BENCH_RUNS=3` (runs per thread count; the first run of the first count is the
/// coldest), `DISKSURVEY_BENCH_CROSS=1` (cross mount points), `DISKSURVEY_BENCH_FALLBACK=1`
/// (use the readdir fallback), `DISKSURVEY_BENCH_NOHINTS=1` (disable the entry-count shortcuts).
@Suite(.serialized) struct ScanBenchmark {
    static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["DISKSURVEY_BENCH"] != nil))
    func throughput() {
        let environment = Self.environment
        let path = environment["DISKSURVEY_BENCH"]!
        let threadCounts = (environment["DISKSURVEY_BENCH_THREADS"] ?? "0").split(separator: ",").compactMap { Int($0) }
        let runs = Int(environment["DISKSURVEY_BENCH_RUNS"] ?? "") ?? 3

        print("[bench] scanning \(path)")
        for threads in threadCounts {
            for run in 1 ... max(1, runs) {
                let result = scan(path) {
                    $0.threadCount = threads
                    $0.crossMountPoints = environment["DISKSURVEY_BENCH_CROSS"] != nil
                    $0.useBulkAttributes = environment["DISKSURVEY_BENCH_FALLBACK"] == nil
                    $0.useEntryCountHints = environment["DISKSURVEY_BENCH_NOHINTS"] == nil
                }
                let stats = result.stats
                let tree = result.tree
                let rate = Format.count(Int(stats.entriesPerSecond), symbols: .posix)
                let duration = String(format: "%.3f", result.duration)
                let size = Format.bytes(tree.size(of: 0), symbols: .posix)
                print(
                    "[bench] threads=\(stats.threadCount) run=\(run): \(Format.count(Int(stats.entries), symbols: .posix)) entries "
                        + "(\(stats.files) files, \(stats.directories) dirs) in \(duration) s = \(rate) entries/s; "
                        + "\(size) allocated (\(tree.size(of: 0) / 1024) KiB), "
                        + "\(Format.bytes(tree.logicalSize(of: 0), symbols: .posix)) logical; "
                        + "\(stats.hardLinkDuplicates) hard-link duplicates, \(stats.symlinks) symlinks, "
                        + "\(stats.datalessEntries) dataless, mounts entered/skipped \(stats.mountPointsEntered)/\(stats.mountPointsSkipped), "
                        + "\(result.totalIssueCount) issues, tree \(Format.bytes(UInt64(tree.memoryFootprint), symbols: .posix)); "
                        + "slowest open \(String(format: "%.1f", stats.slowestDirectoryOpen * 1000)) ms, "
                        + "\(stats.slowDirectoryOpens) opens over 100 ms"
                        + (stats.slowestDirectoryPath.isEmpty ? "" : " (slowest: \(stats.slowestDirectoryPath))"))
                #expect(stats.entries > 0)
            }
        }
    }
}
