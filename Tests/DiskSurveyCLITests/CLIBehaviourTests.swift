import Foundation
import Testing
@testable import disksurvey_cli

// End-to-end tests: they run the built `disksurvey-cli` binary on fixtures in a temporary directory.

/// Anchor for locating the build products directory.
private final class BundleAnchor {}

private struct Run {
    var status: Int32
    var reason: Process.TerminationReason
    var stdout: String
    var stderr: String
}

private enum Stderr { case captured, closed, brokenPipe }

private enum Tool {
    /// SwiftPM builds the executable next to the test bundle.
    static let binary: URL = {
        var directory = Bundle(for: BundleAnchor.self).bundleURL
        for _ in 0..<6 {
            directory = directory.deletingLastPathComponent()
            let candidate = directory.appending(path: "disksurvey-cli")
            if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return URL(filePath: "disksurvey-cli-not-found")
    }()

    /// Runs the tool to completion. Output is captured in files rather than pipes: nothing has to
    /// drain them while the child runs, so tests running in parallel cannot stall each other.
    static func run(_ arguments: [String], cwd: URL? = nil, stderr mode: Stderr = .captured) throws -> Run {
        let capture = try Fixture()
        let outPath = capture.path("stdout")
        let errPath = capture.path("stderr")
        FileManager.default.createFile(atPath: outPath, contents: nil)
        FileManager.default.createFile(atPath: errPath, contents: nil)
        let out = try #require(FileHandle(forWritingAtPath: outPath))
        let err = try #require(FileHandle(forWritingAtPath: errPath))
        defer {
            try? out.close()
            try? err.close()
        }

        let process = Process()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        process.executableURL = binary
        process.arguments = arguments
        switch mode {
        case .captured:
            break
        case .closed:
            // Process cannot hand a child a closed descriptor; the shell can.
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", "exec \"$0\" \"$@\" 2>&-", binary.path(percentEncoded: false)] + arguments
        case .brokenPipe:
            // A pipe whose reader is gone before the child starts: every write fails with EPIPE.
            let pipe = Pipe()
            try pipe.fileHandleForReading.close()
            process.standardError = pipe
        }
        if let cwd { process.currentDirectoryURL = cwd }

        try process.run()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus, reason: process.terminationReason,
            stdout: String(decoding: try Data(contentsOf: URL(filePath: outPath)), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: URL(filePath: errPath)), as: UTF8.self))
    }
}

/// A temporary directory that is removed when the value goes away.
private final class Fixture {
    /// Resolved (/private/var/…, no trailing slash), like the paths the scanner reports.
    let rootPath: String
    var root: URL { URL(filePath: rootPath, directoryHint: .isDirectory) }

    init() throws {
        var template = Array((NSTemporaryDirectory() + "disksurvey-cli-tests.XXXXXXXX").utf8CString)
        guard mkdtemp(&template) != nil, let resolved = realpath(template, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { free(resolved) }
        rootPath = String(cString: resolved)
    }

    deinit {
        // Make everything removable again (some tests take permissions away).
        if let walker = FileManager.default.enumerator(atPath: rootPath) {
            for case let relative as String in walker { chmod(rootPath + "/" + relative, 0o755) }
        }
        try? FileManager.default.removeItem(atPath: rootPath)
    }

    func path(_ relative: String) -> String { relative.isEmpty ? rootPath : rootPath + "/" + relative }

    @discardableResult
    func file(_ relative: String, _ contents: String = "hello\n") throws -> String {
        let url = URL(filePath: path(relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url.path(percentEncoded: false)
    }

    @discardableResult
    func directory(_ relative: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
        return path(relative)
    }

    func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: destination)
    }

    func names(in relative: String = "") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path(relative)).sorted()
    }

    func read(_ relative: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(filePath: path(relative))), as: UTF8.self)
    }
}

private func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

/// The `path` column of a CSV export (fixture paths contain nothing that needs quoting).
private func csvPaths(_ text: String) -> [String] {
    text.split(separator: "\n").dropFirst().map { String($0.split(separator: ",", omittingEmptySubsequences: false)[0]) }
}

// MARK: - export -o

@Suite struct ExportDestinationTests {
    /// scan/{a.txt, sub/b.txt}: four entries with the root.
    private func tree(_ fixture: Fixture) throws -> String {
        try fixture.file("scan/a.txt")
        try fixture.file("scan/sub/b.txt")
        return fixture.path("scan")
    }

    @Test func aFailedScanLeavesThePreviousExportUntouched() throws {
        let fixture = try Fixture()
        try fixture.file("out/keep.json", "precious\n")
        let run = try Tool.run(["export", fixture.path("nonexistent"), "-f", "json", "-o", fixture.path("out/keep.json")])
        #expect(run.reason == .exit && run.status == 1)
        #expect(run.stderr.contains("cannot scan"))
        #expect(try fixture.read("out/keep.json") == "precious\n")
        #expect(try fixture.names(in: "out") == ["keep.json"])
    }

    @Test func aFailedScanCreatesNoOutputFile() throws {
        let fixture = try Fixture()
        try fixture.directory("out")
        let run = try Tool.run(["export", fixture.path("nonexistent"), "-f", "csv", "-o", fixture.path("out/new.csv")])
        #expect(run.status == 1)
        #expect(try fixture.names(in: "out") == [])
    }

    @Test func aSuccessfulExportReplacesTheFileCompletely() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        try fixture.file("out/export.json", String(repeating: "old contents that are longer than nothing\n", count: 500))
        try fixture.file("out/export.csv", "old\n")
        chmod(fixture.path("out/export.csv"), 0o600)

        let jsonRun = try Tool.run(["export", root, "-f", "json", "-o", fixture.path("out/export.json")])
        #expect(jsonRun.reason == .exit && jsonRun.status == 0)
        #expect(jsonRun.stdout.isEmpty)
        #expect(jsonRun.stderr.contains("Wrote 4 entries"))
        let object = try json(try fixture.read("out/export.json"))
        #expect(object["command"] as? String == "export")
        #expect(object["root"] as? String == root)

        let csvRun = try Tool.run(["export", root, "-f", "csv", "-o", fixture.path("out/export.csv")])
        #expect(csvRun.status == 0)
        let csv = try fixture.read("out/export.csv")
        #expect(csv.hasPrefix("path,type,allocated_bytes,"))
        #expect(csvPaths(csv).sorted() == [root, root + "/a.txt", root + "/sub", root + "/sub/b.txt"])
        // The replacement keeps the permissions of the file it replaced.
        var info = stat()
        #expect(stat(fixture.path("out/export.csv"), &info) == 0 && info.st_mode & 0o777 == 0o600)

        #expect(try fixture.names(in: "out") == ["export.csv", "export.json"])
    }

    @Test func theExportDoesNotListItself() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        let expected = [root, root + "/a.txt", root + "/sub", root + "/sub/b.txt"]

        // A new output file inside the scanned tree, given relative to the working directory.
        let first = try Tool.run(["export", ".", "-f", "csv", "-o", "out.csv"], cwd: URL(filePath: root))
        #expect(first.status == 0)
        #expect(first.stderr.contains("Wrote 4 entries"))
        #expect(csvPaths(try fixture.read("scan/out.csv")).sorted() == expected)

        // And again, now that the output exists: neither it nor the temporary file is a row.
        let second = try Tool.run(["export", root, "-f", "csv", "-o", root + "/out.csv"])
        #expect(second.status == 0)
        #expect(second.stderr.contains("Wrote 4 entries"))
        #expect(csvPaths(try fixture.read("scan/out.csv")).sorted() == expected)
        #expect(try fixture.names(in: "scan") == ["a.txt", "out.csv", "sub"])

        // The summary in a JSON export agrees.
        let third = try Tool.run(["export", root, "-f", "json", "-o", root + "/sub/out.json"])
        #expect(third.status == 0)
        let summary = try #require(try json(try fixture.read("scan/sub/out.json"))["summary"] as? [String: Any])
        #expect(summary["files"] as? Int == 3)   // a.txt, sub/b.txt and the earlier out.csv
        #expect(try fixture.names(in: "scan/sub") == ["b.txt", "out.json"])
    }

    @Test func anUnwritableDestinationFailsBeforeScanning() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        let missing = try Tool.run(["export", root, "-f", "csv", "-o", fixture.path("no-such-dir/out.csv")])
        #expect(missing.reason == .exit && missing.status == 1)
        #expect(missing.stderr.contains("cannot write"))
        #expect(!missing.stderr.contains("cannot scan"))
        // Proof that no scan ran: a root that does not exist is not what gets reported.
        let unscanned = try Tool.run(["export", fixture.path("nonexistent"), "-f", "csv", "-o", fixture.path("no-such-dir/out.csv")])
        #expect(unscanned.status == 1)
        #expect(unscanned.stderr.contains("cannot write") && !unscanned.stderr.contains("cannot scan"))

        // A directory is not a file to write to, and stays a directory.
        try fixture.directory("out")
        let directory = try Tool.run(["export", root, "-f", "csv", "-o", fixture.path("out")])
        #expect(directory.status == 1 && directory.stderr.contains("cannot write"))
        #expect(try fixture.names(in: "out") == [])

        // A read-only file is refused (when permissions apply at all), and keeps its contents.
        try fixture.file("out/readonly.csv", "keep\n")
        chmod(fixture.path("out/readonly.csv"), 0o444)
        if geteuid() != 0 {
            let readOnly = try Tool.run(["export", root, "-f", "csv", "-o", fixture.path("out/readonly.csv")])
            #expect(readOnly.status == 1 && readOnly.stderr.contains("cannot write"))
            #expect(try fixture.read("out/readonly.csv") == "keep\n")
            #expect(try fixture.names(in: "out") == ["readonly.csv"])
        }
    }

    @Test func devicesAndStandardOutputAreWrittenDirectly() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)

        let null = try Tool.run(["export", root, "-f", "csv", "-o", "/dev/null"])
        #expect(null.reason == .exit && null.status == 0)
        #expect(null.stdout.isEmpty)
        var info = stat()
        #expect(lstat("/dev/null", &info) == 0 && info.st_mode & S_IFMT == S_IFCHR)

        let dash = try Tool.run(["export", root, "-f", "csv", "-o", "-"])
        #expect(dash.status == 0)
        #expect(csvPaths(dash.stdout).count == 4)

        let devStdout = try Tool.run(["export", root, "-f", "csv", "-o", "/dev/stdout"])
        #expect(devStdout.status == 0)
        #expect(csvPaths(devStdout.stdout).count == 4)

        let implicit = try Tool.run(["export", root, "-f", "ncdu"])
        #expect(implicit.status == 0)
        #expect(try JSONSerialization.jsonObject(with: Data(implicit.stdout.utf8)) is [Any])
    }

    @Test func aSymlinkedDestinationKeepsTheLinkAndUpdatesItsTarget() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        try fixture.file("real/target.csv", "old\n")
        try fixture.directory("links")
        try fixture.symlink("links/latest.csv", to: "../real/target.csv")

        let run = try Tool.run(["export", root, "-f", "csv", "-o", fixture.path("links/latest.csv")])
        #expect(run.status == 0)
        var info = stat()
        #expect(lstat(fixture.path("links/latest.csv"), &info) == 0 && info.st_mode & S_IFMT == S_IFLNK)
        #expect(lstat(fixture.path("real/target.csv"), &info) == 0 && info.st_mode & S_IFMT == S_IFREG)
        #expect(csvPaths(try fixture.read("real/target.csv")).count == 4)
        #expect(try fixture.names(in: "links") == ["latest.csv"])
        #expect(try fixture.names(in: "real") == ["target.csv"])

        // A failed scan through the link leaves the target alone as well.
        let before = try fixture.read("real/target.csv")
        let failed = try Tool.run(["export", fixture.path("nonexistent"), "-f", "csv", "-o", fixture.path("links/latest.csv")])
        #expect(failed.status == 1)
        #expect(try fixture.read("real/target.csv") == before)
        #expect(try fixture.names(in: "real") == ["target.csv"])
    }
}

/// `ExportDestination` and `PendingOutput` directly. Serialized: the pending path is process-wide.
@Suite(.serialized) struct PendingOutputTests {
    @Test func abandoningKeepsTheOldFileAndCommittingReplacesIt() throws {
        let fixture = try Fixture()
        let path = try fixture.file("out.csv", "old\n")

        let abandoned = try ExportDestination(path: path)
        #expect(abandoned.isAtomic)
        #expect(try fixture.names().count == 2)                    // the file and its temporary sibling
        #expect(abandoned.pathsToExclude.contains(path))
        #expect(abandoned.pathsToExclude.count == 2)
        #expect(abandoned.pathsToExclude.allSatisfy { $0.hasPrefix(fixture.rootPath + "/") })
        _ = Array("new\n".utf8).withUnsafeBytes { Darwin.write(abandoned.fd, $0.baseAddress, $0.count) }
        abandoned.abandon()
        #expect(try fixture.names() == ["out.csv"])
        #expect(try fixture.read("out.csv") == "old\n")

        let committed = try ExportDestination(path: path)
        _ = Array("new\n".utf8).withUnsafeBytes { Darwin.write(committed.fd, $0.baseAddress, $0.count) }
        try committed.commit()
        committed.abandon()                                        // a no-op after commit
        #expect(try fixture.names() == ["out.csv"])
        #expect(try fixture.read("out.csv") == "new\n")
    }

    /// What the second Ctrl-C (and a signal during writing) does before the process ends.
    @Test func discardingRemovesTheTemporaryFile() throws {
        let fixture = try Fixture()
        let path = try fixture.file("out.csv", "old\n")
        let destination = try ExportDestination(path: path)
        #expect(try fixture.names().count == 2)
        PendingOutput.discard()
        #expect(try fixture.names() == ["out.csv"])
        #expect(try fixture.read("out.csv") == "old\n")
        PendingOutput.discard()                                    // nothing pending: harmless
        destination.abandon()
        #expect(try fixture.names() == ["out.csv"])
    }

    @Test func aMissingFolderIsReportedAtOnce() throws {
        let fixture = try Fixture()
        #expect(throws: RuntimeError.self) { _ = try ExportDestination(path: fixture.path("missing/out.csv")) }
        #expect(try fixture.names() == [])
    }
}

// MARK: - stderr that cannot be written

@Suite struct BrokenStderrTests {
    @Test func aClosedStderrDoesNotAbortAnErrorExit() throws {
        let fixture = try Fixture()
        let open = try Tool.run([fixture.path("nonexistent")])
        #expect(open.reason == .exit && open.status == 1)
        #expect(open.stderr.contains("cannot scan"))

        let closed = try Tool.run([fixture.path("nonexistent")], stderr: .closed)
        #expect(closed.reason == .exit)
        #expect(closed.status == 1)

        let usage = try Tool.run(["--no-such-option"], stderr: .closed)
        #expect(usage.reason == .exit)
        #expect(usage.status == 2)
    }

    @Test func aBrokenStderrPipeDoesNotAbortOrTurnAnErrorIntoSuccess() throws {
        let fixture = try Fixture()
        let run = try Tool.run([fixture.path("nonexistent")], stderr: .brokenPipe)
        #expect(run.reason == .exit)
        #expect(run.status == 1)
    }

    @Test func anExportWhoseNoteCannotBeWrittenStillSucceeds() throws {
        let fixture = try Fixture()
        try fixture.file("scan/a.txt")
        for mode in [Stderr.closed, .brokenPipe] {
            let run = try Tool.run(["export", fixture.path("scan"), "-f", "json", "-o", fixture.path("out.json")], stderr: mode)
            #expect(run.reason == .exit)
            #expect(run.status == 0)
            let object = try json(try fixture.read("out.json"))
            #expect(object["command"] as? String == "export")
            #expect(try fixture.names() == ["out.json", "scan"])
        }
    }

    /// A root that cannot be listed at all is an error (exit 1), not an empty report; an
    /// unreadable folder further down is only an issue.
    @Test func anUnreadableRootFailsButAnUnreadableSubfolderDoesNot() throws {
        guard geteuid() != 0 else { return }
        let fixture = try Fixture()
        try fixture.file("scan/a.txt")
        try fixture.file("scan/locked/b.txt")
        chmod(fixture.path("scan/locked"), 0o000)

        let root = try Tool.run([fixture.path("scan/locked")])
        #expect(root.reason == .exit && root.status == 1)
        #expect(root.stdout.isEmpty)
        #expect(root.stderr.contains("disksurvey: cannot scan '" + fixture.path("scan/locked") + "': Permission denied"))
        #expect(root.stderr.contains("Full Disk Access"))
        let asJSON = try Tool.run([fixture.path("scan/locked"), "--json"])
        #expect(asJSON.status == 1 && asJSON.stdout.isEmpty)

        // `export -o` neither creates the output file nor leaves a temporary one behind.
        let export = try Tool.run(["export", fixture.path("scan/locked"), "-f", "csv", "-o", fixture.path("out.csv")])
        #expect(export.status == 1)
        #expect(try fixture.names() == ["scan"])

        let parent = try Tool.run([fixture.path("scan"), "--json"])
        #expect(parent.reason == .exit && parent.status == 0)
        let summary = try #require(try json(parent.stdout)["summary"] as? [String: Any])
        #expect(summary["issues"] as? Int == 1)
        #expect(summary["files"] as? Int == 1)
        // The attribution fields for slow scans are always there.
        #expect(summary["slowOpens"] as? Int == 0)
        #expect(summary["slowestOpenSeconds"] as? Double != nil)
        #expect(summary["slowestOpenPath"] as? String == "")
    }

    /// Executables without an extension are a kind of their own, shown by name and never as a
    /// made-up extension.
    @Test func extensionlessExecutablesAreNamedNotGivenAnExtension() throws {
        let fixture = try Fixture()
        try fixture.file("scan/tool", String(repeating: "x", count: 9000))
        try fixture.file("scan/notes")
        try fixture.file("scan/a.txt")
        chmod(fixture.path("scan/tool"), 0o755)

        let text = try Tool.run(["kinds", fixture.path("scan")])
        #expect(text.status == 0)
        #expect(text.stdout.contains("Unix Executable") && !text.stdout.contains(".unix executable"))

        let kinds = try #require(try json(try Tool.run(["kinds", fixture.path("scan"), "--json"]).stdout)["kinds"] as? [[String: Any]])
        let names = Set(kinds.map { "\($0["extension"] as? String ?? "?")|\($0["name"] as? String ?? "?")" })
        #expect(names == ["|Unix Executable", "|", "txt|.txt"])

        let csv = try Tool.run(["export", fixture.path("scan"), "-f", "csv"]).stdout
        let toolRow = try #require(csv.split(separator: "\n").first { $0.hasPrefix(fixture.path("scan/tool") + ",") })
        #expect(toolRow.hasSuffix(",,application,1,unixExecutable"))

        let found = try Tool.run(["find", fixture.path("scan"), "--kind", "unix-executable", "--json"])
        let matches = try #require(try json(found.stdout)["matches"] as? [[String: Any]])
        #expect(matches.map { $0["name"] as? String } == ["tool"])
        #expect(matches.first?["extension"] as? String == "")
        #expect((matches.first?["flags"] as? [String])?.contains("unixExecutable") == true)
    }

    @Test func issuesListedOnABrokenStderrDoNotAbort() throws {
        // Permissions do not stop root, so there would be no issue to list.
        guard geteuid() != 0 else { return }
        let fixture = try Fixture()
        try fixture.file("scan/a.txt")
        try fixture.file("scan/locked/b.txt")
        chmod(fixture.path("scan/locked"), 0o000)

        let open = try Tool.run([fixture.path("scan"), "--issues", "-d", "0"])
        #expect(open.reason == .exit && open.status == 0)
        // The fixture really does record an issue, so the listing code runs below.
        #expect(open.stderr.contains("disksurvey: " + fixture.path("scan/locked") + ": "))

        for mode in [Stderr.closed, .brokenPipe] {
            let run = try Tool.run([fixture.path("scan"), "--issues", "-d", "0"], stderr: mode)
            #expect(run.reason == .exit)
            #expect(run.status == 0)
            #expect(run.stdout.contains(fixture.path("scan")))
        }
    }
}

// MARK: - Empty path arguments

@Suite struct EmptyPathTests {
    @Test func anEmptyPathIsAUsageError() {
        #expect(throws: UsageError.self) { try ArgumentParser.parse([""]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["scan", ""]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["top", ""]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["kinds", ""]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["export", "", "-f", "csv"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["find", "", "x"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse([".", "--exclude", ""]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse([".", "--exclude="]) }
    }

    @Test func whatIsNotAnEmptyPathStillParses() throws {
        // No path at all means the current directory.
        #expect(try ArgumentParser.parse([]).positionals == [])
        #expect(try ArgumentParser.parse(["export", "-f", "csv"]).positionals == [])
        // find's query may be empty when a filter does the selecting.
        #expect(try ArgumentParser.parse(["find", ".", "", "--min-size", "1k"]).positionals == [".", ""])
        // A name made of blanks is a legal file name.
        #expect(try ArgumentParser.parse([" "]).positionals == [" "])
        #expect(try ArgumentParser.parse([".", "--exclude", " "]).excludes == [" "])
        // Help and version win over everything else on the line.
        #expect(try ArgumentParser.parse(["", "--help"]).help)
    }

    @Test func anEmptyPathNeverBecomesTheWorkingDirectory() {
        #expect(ScanRunner.absolutePath("") == "")
        #expect(ScanRunner.absolutePath(".").hasPrefix("/"))
    }

    @Test func theToolRejectsAnEmptyPathWithoutScanning() throws {
        let fixture = try Fixture()
        try fixture.file("a.txt")
        let cwd = fixture.root

        let scan = try Tool.run([""], cwd: cwd)
        #expect(scan.reason == .exit && scan.status == 2)
        #expect(scan.stdout.isEmpty)
        #expect(scan.stderr.contains("empty path"))

        let export = try Tool.run(["export", "", "-f", "csv", "-o", "out.csv"], cwd: cwd)
        #expect(export.status == 2)
        #expect(try fixture.names() == ["a.txt"])

        let find = try Tool.run(["find", "", "txt"], cwd: cwd)
        #expect(find.status == 2 && find.stdout.isEmpty)

        let exclude = try Tool.run([".", "--exclude", ""], cwd: cwd)
        #expect(exclude.status == 2 && exclude.stdout.isEmpty)

        // The default is unchanged.
        let implicit = try Tool.run(["--json"], cwd: cwd)
        #expect(implicit.status == 0)
        #expect(try json(implicit.stdout)["root"] as? String == fixture.path(""))
    }
}

// MARK: - --exclude and symlinks

@Suite struct ExcludeTests {
    /// sub/{deep/a.log, realdir/f, sym.log -> deep/a.log, dirlink -> realdir}
    private func tree(_ fixture: Fixture) throws -> String {
        try fixture.file("sub/deep/a.log")
        try fixture.file("sub/realdir/f")
        try fixture.symlink("sub/sym.log", to: "deep/a.log")
        try fixture.symlink("sub/dirlink", to: "realdir")
        return fixture.path("sub")
    }

    private func exportedPaths(_ root: String, _ extra: [String], cwd: URL? = nil) throws -> [String] {
        let run = try Tool.run(["export", root, "-f", "csv"] + extra, cwd: cwd)
        #expect(run.reason == .exit && run.status == 0)
        return csvPaths(run.stdout).sorted()
    }

    @Test func excludingASymlinkExcludesTheLinkNotItsTarget() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        let everything = [
            root, root + "/deep", root + "/deep/a.log", root + "/dirlink", root + "/realdir", root + "/realdir/f",
            root + "/sym.log",
        ]
        #expect(try exportedPaths(root, []) == everything)

        // Naming a symlink excludes the link itself…
        let withoutFileLink = try exportedPaths(root, ["--exclude", root + "/sym.log"])
        let withoutFolderLink = try exportedPaths(root, ["--exclude", root + "/dirlink"])
        let withTrailingSlash = try exportedPaths(root, ["--exclude", root + "/dirlink/"])
        #expect(!withoutFileLink.contains(root + "/sym.log"))
        #expect(!withoutFolderLink.contains(root + "/dirlink"))
        #expect(!withTrailingSlash.contains(root + "/dirlink"))
        let totals = try json(try Tool.run([root, "--json", "--exclude", root + "/sym.log"]).stdout)
        let summary = try #require(totals["summary"] as? [String: Any])
        // …and nothing else: what it points to was never named and stays counted.
        #expect(withoutFileLink == everything.filter { $0 != root + "/sym.log" })
        #expect(withoutFolderLink == everything.filter { $0 != root + "/dirlink" })
        #expect(withTrailingSlash == everything.filter { $0 != root + "/dirlink" })
        #expect(summary["files"] as? Int == 3)        // a.log, f and the dirlink symlink
        // Naming the target excludes the target, and leaves the link to it.
        #expect(
            try exportedPaths(root, ["--exclude", root + "/realdir"])
                == everything.filter { !$0.hasPrefix(root + "/realdir") })
    }

    @Test func theFolderOfAnExclusionIsStillResolved() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        // The same folder reached through a symlink…
        try fixture.symlink("alias", to: "sub")
        let viaLink = try exportedPaths(root, ["--exclude", fixture.path("alias/deep")])
        #expect(!viaLink.contains(root + "/deep") && !viaLink.contains(root + "/deep/a.log"))
        #expect(viaLink.contains(root + "/realdir/f"))
        // …through "..", and through the unresolved spelling of the temporary directory.
        let dotted = try exportedPaths(root, ["--exclude", root + "/realdir/../deep/a.log"])
        #expect(!dotted.contains(root + "/deep/a.log") && dotted.contains(root + "/deep"))
        let unresolved = NSTemporaryDirectory() + (fixture.rootPath as NSString).lastPathComponent
        let spelled = try exportedPaths(root, ["--exclude", unresolved + "/sub/deep"])
        #expect(!spelled.contains(root + "/deep"))
    }

    @Test func relativeExclusionsResolveAgainstTheWorkingDirectory() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        let cwd = URL(filePath: root)
        let bare = try exportedPaths(".", ["--exclude", "sym.log"], cwd: cwd)
        #expect(!bare.contains(root + "/sym.log"))
        #expect(bare.contains(root + "/deep/a.log"))
        let nested = try exportedPaths(".", ["--exclude", "deep/a.log"], cwd: cwd)
        #expect(!nested.contains(root + "/deep/a.log") && nested.contains(root + "/sym.log"))
        let dotSlash = try exportedPaths(".", ["--exclude", "./dirlink/"], cwd: cwd)
        #expect(!dotSlash.contains(root + "/dirlink"))
        #expect(dotSlash.contains(root + "/realdir/f"))
    }

    @Test func exclusionPathsAreAbsoluteAndKeepTheLastComponent() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        #expect(ScanRunner.exclusionPath(root + "/sym.log") == root + "/sym.log")
        #expect(ScanRunner.exclusionPath(root + "/dirlink///") == root + "/dirlink")
        #expect(ScanRunner.exclusionPath(root + "/dirlink/f") == root + "/realdir/f")
        // Nothing literal to keep: fully resolved.
        #expect(ScanRunner.exclusionPath(root + "/deep/..") == root)
        #expect(ScanRunner.exclusionPath(root + "/dirlink/.") == root + "/realdir")
        #expect(ScanRunner.exclusionPath("/") == "/")
        #expect(ScanRunner.exclusionPath("/tmp") == "/tmp")              // the entry in "/", itself a symlink
        #expect(ScanRunner.exclusionPath("/tmp/x") == "/private/tmp/x")
        // Paths that do not exist do not crash and are still absolute.
        #expect(ScanRunner.exclusionPath(root + "/missing") == root + "/missing")
        #expect(ScanRunner.exclusionPath(root + "/missing/dir/file").hasPrefix("/"))
        #expect(ScanRunner.exclusionPath("no-such-dir/file").hasPrefix("/"))
        #expect(ScanRunner.exclusionPath("bare-name").hasPrefix("/"))
        #expect(ScanRunner.exclusionPath("bare-name").hasSuffix("/bare-name"))

        let missing = try exportedPaths(root, ["--exclude", root + "/missing/dir/file"])
        #expect(missing.count == 7)
    }
}

// MARK: - -n 0

@Suite struct LimitTests {
    @Test func zeroMeansAllForEveryCommandAndSpelling() throws {
        for command in ["scan", "top", "kinds", "find"] {
            let tail = command == "find" ? [".", "x"] : ["."]
            #expect(try ArgumentParser.parse([command] + tail + ["-n", "0"]).limit == Int.max)
            #expect(try ArgumentParser.parse([command] + tail + ["-n0"]).limit == Int.max)
            #expect(try ArgumentParser.parse([command] + tail + ["--limit", "0"]).limit == Int.max)
            #expect(try ArgumentParser.parse([command] + tail + ["--limit=7"]).limit == 7)
            #expect(try ArgumentParser.parse([command] + tail).limit == nil)
        }
        #expect(try ArgumentParser.parse([".", "--top", "0"]).limit == Int.max)
        #expect(try ArgumentParser.parse(["scan", ".", "--top=0"]).limit == Int.max)
        #expect(try ArgumentParser.parse([".", "--top", "3"]).limit == 3)
    }

    @Test func badLimitsAreUsageErrorsNamedAfterTheOptionTyped() {
        for option in ["-n", "--limit", "--top"] {
            for value in ["-1", "many", "1.5", "", "10000001"] {
                do {
                    _ = try ArgumentParser.parse(["scan", ".", option, value])
                    Issue.record("\(option) \(value) was accepted")
                } catch let error as UsageError {
                    #expect(error.message.hasPrefix(option + " expects"))
                } catch {
                    Issue.record("unexpected error \(error)")
                }
            }
        }
        // --top stays a scan option.
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["top", ".", "--top", "0"]) }
    }

    /// 30 files with 17 different extensions at the top, and 6 more in a subfolder: more than
    /// every command's default limit (scan 10 and 4 nested, kinds 15, top 25).
    private func tree(_ fixture: Fixture) throws -> String {
        for index in 0..<30 { try fixture.file("scan/file\(index).e\(index % 17)", String(repeating: "x", count: 100 + index)) }
        for index in 0..<6 { try fixture.file("scan/sub/nested\(index).e0") }
        return fixture.path("scan")
    }

    @Test func scanListsEveryEntry() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        for option in [["-n", "0"], ["--top", "0"], ["--limit=0"]] {
            let text = try Tool.run([root, "--no-color"] + option)
            #expect(text.reason == .exit && text.status == 0)
            #expect(!text.stdout.contains(" more"))
            for index in 0..<30 { #expect(text.stdout.contains("file\(index).e\(index % 17)\n")) }
            for index in 0..<6 { #expect(text.stdout.contains("nested\(index).e0\n")) }

            let object = try json(try Tool.run([root, "--json"] + option).stdout)
            let node = try #require(object["tree"] as? [String: Any])
            let children = try #require(node["children"] as? [[String: Any]])
            #expect(children.count == 31)
            #expect((node["omitted"] as? [String: Any])?["count"] as? Int == 0)
            let sub = try #require(children.first { $0["name"] as? String == "sub" })
            #expect((sub["children"] as? [[String: Any]])?.count == 6)
            #expect((sub["omitted"] as? [String: Any])?["count"] as? Int == 0)
        }
        // Without a limit the defaults still apply: 10 at the top, 4 below.
        let plain = try json(try Tool.run([root, "--json"]).stdout)
        let node = try #require(plain["tree"] as? [String: Any])
        let children = try #require(node["children"] as? [[String: Any]])
        #expect(children.count == 10)
        #expect((node["omitted"] as? [String: Any])?["count"] as? Int == 21)
        let sub = try #require(children.first { $0["name"] as? String == "sub" })
        #expect((sub["children"] as? [[String: Any]])?.count == 4)
    }

    @Test func kindsListsEveryExtension() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        let text = try Tool.run(["kinds", root, "-n", "0", "--no-color"])
        #expect(text.reason == .exit && text.status == 0)
        #expect(text.stdout.contains("By extension\n"))
        #expect(!text.stdout.contains("(top "))
        for index in 0..<17 { #expect(text.stdout.contains("  .e\(index) ")) }

        let object = try json(try Tool.run(["kinds", root, "-n", "0", "--json"]).stdout)
        #expect(object["totalKinds"] as? Int == 17)
        #expect((object["kinds"] as? [[String: Any]])?.count == 17)

        // Unchanged: a real limit, and the defaults (text 15, JSON all).
        let limited = try json(try Tool.run(["kinds", root, "-n", "3", "--json"]).stdout)
        #expect((limited["kinds"] as? [[String: Any]])?.count == 3)
        #expect(try Tool.run(["kinds", root, "--no-color"]).stdout.contains("By extension (top 15 of 17)"))
        #expect((try json(try Tool.run(["kinds", root, "--json"]).stdout)["kinds"] as? [[String: Any]])?.count == 17)
    }

    @Test func topListsEveryFile() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        let object = try json(try Tool.run(["top", root, "-n", "0", "--json"]).stdout)
        #expect((object["files"] as? [[String: Any]])?.count == 36)
        let text = try Tool.run(["top", root, "-n", "0", "--no-color"])
        #expect(text.reason == .exit && text.status == 0)
        #expect(text.stdout.contains("sub/nested5.e0\n"))
        // Unchanged: the default and an explicit limit.
        #expect((try json(try Tool.run(["top", root, "--json"]).stdout)["files"] as? [[String: Any]])?.count == 25)
        #expect((try json(try Tool.run(["top", root, "-n", "2", "--json"]).stdout)["files"] as? [[String: Any]])?.count == 2)
    }

    @Test func findStillListsEveryMatch() throws {
        let fixture = try Fixture()
        let root = try tree(fixture)
        for index in 0..<30 { try fixture.file("scan/more/extra\(index).e1") }
        let all = try json(try Tool.run(["find", root, ".e", "--files", "-n", "0", "--json"]).stdout)
        #expect(all["totalMatches"] as? Int == 66)
        #expect((all["matches"] as? [[String: Any]])?.count == 66)
        let byDefault = try json(try Tool.run(["find", root, ".e", "--files", "--json"]).stdout)
        #expect((byDefault["matches"] as? [[String: Any]])?.count == 50)
    }
}
