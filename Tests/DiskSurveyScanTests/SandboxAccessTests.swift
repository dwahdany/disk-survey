import Foundation
import Testing
@testable import DiskSurveyScan

/// The parts of the sandboxed edition that need neither a sandbox nor AppKit: detection, the
/// real home folder, which grant covers which path, the stored grant table and what happens
/// to bookmarks that are stale or no longer resolve, and the three-valued Full Disk Access.
@Suite struct SandboxAccessTests {
    // MARK: Detection and home

    @Test func detectionFollowsTheSignature() {
        // The signature's entitlement decides whenever it can be read.
        #expect(AppSandbox.detect(environment: [:], entitlement: true))
        #expect(AppSandbox.detect(environment: ["APP_SANDBOX_CONTAINER_ID": "dev.disksurvey.app"], entitlement: true))
        #expect(!AppSandbox.detect(environment: [:], entitlement: false))
        #expect(!AppSandbox.detect(environment: ["HOME": "/Users/x"], entitlement: false))
        // The variable is inherited by whatever a sandboxed app starts. A normal build that
        // carries it without the entitlement is not confined and must not behave as if it were.
        #expect(!AppSandbox.detect(environment: ["APP_SANDBOX_CONTAINER_ID": "x"], entitlement: false))
        #expect(!AppSandbox.detect(environment: ["APP_SANDBOX_CONTAINER_ID": "com.example.other"], entitlement: false))
        // Only when the signature cannot be read does the environment get a say.
        #expect(!AppSandbox.detect(environment: [:], entitlement: nil))
        #expect(!AppSandbox.detect(environment: ["APP_SANDBOX_CONTAINER_ID": ""], entitlement: nil))
        #expect(AppSandbox.detect(environment: ["APP_SANDBOX_CONTAINER_ID": "dev.disksurvey.app"], entitlement: nil))
    }

    @Test func theTestProcessIsNotSandboxed() {
        #expect(AppSandbox.ownsEntitlement(AppSandbox.sandboxEntitlement) == false)
        #expect(!AppSandbox.isSandboxed)
        #expect(AppSandbox.staticReadWritePaths.isEmpty)
        #expect(AppSandbox.containerPaths.isEmpty)
        #expect(AppSandbox.entitlementValue(AppSandbox.sandboxEntitlement) == nil)
    }

    @Test func realHomeComesFromTheUserDatabase() {
        let home = AppSandbox.realHomeDirectory
        #expect(home.hasPrefix("/") && !home.hasSuffix("/"))
        #expect(!home.contains("/Library/Containers/"))
        #expect(home == String(cString: getpwuid(getuid())!.pointee.pw_dir))
        #expect(DiskAccess.realHomeDirectory() == home)
    }

    @Test func tildeExpandsAgainstTheRealHome() {
        #expect(AppSandbox.expandingTilde("~", home: "/Users/alex") == "/Users/alex")
        #expect(AppSandbox.expandingTilde("~/Library/Caches", home: "/Users/alex") == "/Users/alex/Library/Caches")
        #expect(AppSandbox.expandingTilde("/usr/~/x", home: "/Users/alex") == "/usr/~/x")
        #expect(AppSandbox.expandingTilde("relative/~", home: "/Users/alex") == "relative/~")
        #expect(AppSandbox.expandingTilde("~root/x", home: "/Users/alex").hasSuffix("/x"))
        #expect(AppSandbox.expandingTilde("~") == AppSandbox.realHomeDirectory)
    }

    // MARK: Path coverage

    @Test func pathsAreNormalizedWithoutTouchingTheDisk() {
        #expect(GrantPath.normalized("/") == "/")
        #expect(GrantPath.normalized("//") == "/")
        #expect(GrantPath.normalized("/Users/alex/") == "/Users/alex")
        #expect(GrantPath.normalized("/Users//alex/./Documents/../Desktop") == "/Users/alex/Desktop")
        #expect(GrantPath.normalized("/../..") == "/")
        #expect(GrantPath.normalized("relative/path") == nil)
        #expect(GrantPath.normalized("") == nil)
        // Spellings of one place.
        #expect(GrantPath.normalized("/tmp/x") == "/private/tmp/x")
        #expect(GrantPath.normalized("/var/folders") == "/private/var/folders")
        #expect(GrantPath.normalized("/private/tmp/x") == "/private/tmp/x")
        #expect(GrantPath.normalized("/System/Volumes/Data/Users/alex") == "/Users/alex")
        #expect(GrantPath.normalized("/System/Volumes/Data/Users") == "/Users")
        #expect(GrantPath.normalized("/System/Volumes/Data") == "/System/Volumes/Data")
        #expect(GrantPath.normalized("/.nofollow/") == "/")
        #expect(GrantPath.normalized("/.nofollow/Users/alex") == "/Users/alex")
        #expect(GrantPath.normalized("/Users/alex/tmp") == "/Users/alex/tmp")
    }

    @Test func theDataVolumePrefixIsFoldedOnlyBelowFirmlinks() throws {
        // Firmlinked: the same place as on the startup disk.
        #expect(GrantPath.normalized("/System/Volumes/Data/Applications/Safari.app") == "/Applications/Safari.app")
        #expect(GrantPath.normalized("/System/Volumes/Data/private/var/db") == "/private/var/db")
        #expect(GrantPath.normalized("/System/Volumes/Data/usr/local/bin") == "/usr/local/bin")
        #expect(GrantPath.normalized("/System/Volumes/Data/System/Library/Caches/x") == "/System/Library/Caches/x")
        // Not firmlinked: folders of the Data volume in their own right. Folding them would file
        // a grant under the sealed system volume's folder of the same name.
        for path in [
            "/System/Volumes/Data/System/Library", "/System/Volumes/Data/System/Library/CoreServices", "/System/Volumes/Data/System",
            "/System/Volumes/Data/usr", "/System/Volumes/Data/usr/share", "/System/Volumes/Data/usr/localized", "/System/Volumes/Data/mnt",
            "/System/Volumes/Data/Userspace", "/System/Volumes/Data/.Spotlight-V100",
        ] {
            #expect(GrantPath.normalized(path) == path)
        }
        #expect(!GrantPath.covers(try #require(GrantPath.normalized("/System/Volumes/Data/System/Library")), "/System/Library/Frameworks"))
        #expect(!GrantPath.covers("/System/Library", try #require(GrantPath.normalized("/System/Volumes/Data/System/Library/x"))))

        // The list in the code is the one this system uses.
        let listed = try String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8).split(separator: "\n")
            .compactMap { $0.split(separator: "\t").first.map(String.init) }
        #expect(listed.count >= 10)
        for path in listed {
            #expect(GrantPath.normalized("/System/Volumes/Data" + path + "/item") == path + "/item", "firmlink \(path) is missing from GrantPath.firmlinks")
        }
        #expect(Set(GrantPath.firmlinks.map { "/" + $0.joined(separator: "/") }).isSuperset(of: listed))
    }

    @Test func theCanonicalSpellingFollowsLinksAndLetterCase() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "disksurvey-grantpath-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appending(path: "Real/Sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base.appending(path: "link").path, withDestinationPath: "Real")
        let real = try #require(GrantPath.canonical(base.appending(path: "Real/Sub").path))
        #expect(real.hasPrefix("/private/") && real.hasSuffix("/Real/Sub"))
        // Through a symbolic link: lexically another path, canonically the same.
        let through = base.appending(path: "link/Sub").path
        #expect(GrantPath.normalized(through) != real)
        #expect(GrantPath.canonical(through) == real)
        #expect(GrantPath.canonical(through + "/") == real)
        // A tail that does not exist is kept as given below the resolved part.
        #expect(GrantPath.canonical(through + "/not/there") == real + "/not/there")
        // Letter case, where the volume ignores it.
        let shouted = base.appending(path: "REAL/SUB").path
        if FileManager.default.fileExists(atPath: shouted) {
            #expect(GrantPath.canonical(shouted) == real)
        }
        #expect(GrantPath.canonical("/") == "/")
        #expect(GrantPath.canonical("relative") == nil)
        #expect(GrantPath.canonical("/Volumes/disksurvey-no-such-volume/x") == "/Volumes/disksurvey-no-such-volume/x")
    }

    @Test func aGrantCoversItsFolderAndEverythingBelow() {
        #expect(GrantPath.covers("/", "/"))
        #expect(GrantPath.covers("/", "/Users/alex/Library"))
        #expect(GrantPath.covers("/", "/Volumes/Backup"))
        #expect(GrantPath.covers("/Users/alex", "/Users/alex"))
        #expect(GrantPath.covers("/Users/alex", "/Users/alex/Library/Mail"))
        #expect(!GrantPath.covers("/Users/alex", "/Users"))
        #expect(!GrantPath.covers("/Users/alex", "/Users/alexander"))
        #expect(!GrantPath.covers("/Users/al", "/Users/alex"))
        #expect(!GrantPath.covers("/Users/alex/Documents", "/Users/alex/Desktop"))
        #expect(!GrantPath.covers("/Volumes/Backup", "/"))
        #expect(GrantPath.depth("/") == 0 && GrantPath.depth("/Users/alex") == 2)
    }

    // MARK: The stored table

    private let day0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func bookmark(_ text: String) -> Data { Data(text.utf8) }

    @Test func tableSurvivesEncodingAndRejectsWhatItCannotRead() {
        var table = AccessGrantTable()
        table.insert(path: "/Users/alex/", bookmark: bookmark("home"), now: day0)
        table.insert(path: "/Volumes/Backup", bookmark: bookmark("backup"), now: day0.addingTimeInterval(60))
        let decoded = AccessGrantTable(data: table.encoded())
        #expect(decoded == table)
        #expect(decoded.records.map(\.path).sorted() == ["/Users/alex", "/Volumes/Backup"])
        #expect(decoded.records.first { $0.path == "/Users/alex" }?.bookmark == bookmark("home"))
        #expect(decoded.records.first { $0.path == "/Users/alex" }?.created == day0)

        #expect(AccessGrantTable(data: nil).isEmpty)
        #expect(AccessGrantTable(data: Data()).isEmpty)
        #expect(AccessGrantTable(data: Data("not a property list".utf8)).isEmpty)
        // A table from a newer version is not guessed at.
        struct Future: Codable {
            var version = 99
            var records: [AccessGrantRecord] = []
        }
        var future = Future()
        future.records = table.records
        #expect(AccessGrantTable(data: try! PropertyListEncoder().encode(future)).isEmpty)
    }

    @Test func storedRecordsAreSanitizedWhenRead() throws {
        struct Stored: Codable {
            var version = 1
            var records: [AccessGrantRecord]
        }
        let raw = Stored(records: [
            AccessGrantRecord(path: "/tmp/scans/", bookmark: bookmark("a"), created: day0, lastUsed: day0),
            AccessGrantRecord(path: "/private/tmp/scans", bookmark: bookmark("duplicate"), created: day0, lastUsed: day0),
            AccessGrantRecord(path: "relative", bookmark: bookmark("b"), created: day0, lastUsed: day0),
            AccessGrantRecord(path: "/Users/alex", bookmark: Data(), created: day0, lastUsed: day0),
        ])
        let table = AccessGrantTable(data: try PropertyListEncoder().encode(raw))
        #expect(table.records.map(\.path) == ["/private/tmp/scans"])
        #expect(table.records[0].bookmark == bookmark("a"))
    }

    @Test func anAncestorGrantCoversEverythingBelowIt() {
        var table = AccessGrantTable()
        table.insert(path: "/Users/alex/Documents", bookmark: bookmark("documents"), now: day0)
        table.insert(path: "/Volumes/Backup", bookmark: bookmark("backup"), now: day0)
        #expect(table.covers("/Users/alex/Documents/Taxes"))
        #expect(!table.covers("/Users/alex/Library") && !table.covers("/Users/alex"))

        table.insert(path: "/Users/alex", bookmark: bookmark("home"), now: day0.addingTimeInterval(10))
        #expect(table.covers("/Users/alex/Library") && table.covers("/Users/alex/Documents/Taxes"))
        #expect(!table.covers("/Applications"))

        // The startup disk covers every path, other volumes included.
        table.insert(path: "/", bookmark: bookmark("disk"), now: day0.addingTimeInterval(20))
        #expect(table.covers("/Volumes/Other/x") && table.covers("/private/var") && table.covers("/") && table.covers("/Applications"))
        // What was chosen before stays on record.
        #expect(table.records.map(\.path).sorted() == ["/", "/Users/alex", "/Users/alex/Documents", "/Volumes/Backup"])

        // Granting the same place again keeps one record, with the new bookmark and the old date.
        table.insert(path: "/", bookmark: bookmark("disk again"), now: day0.addingTimeInterval(30))
        let disk = table.records.filter { $0.path == "/" }
        #expect(disk.count == 1 && disk[0].bookmark == bookmark("disk again"))
        #expect(disk[0].created == day0.addingTimeInterval(20) && disk[0].lastUsed == day0.addingTimeInterval(30))

        #expect(table.remove(path: "/") && !table.remove(path: "/"))
        #expect(!table.covers("/Applications") && table.covers("/Users/alex/Desktop"))
        table.removeAll()
        table.insert(path: "relative", bookmark: bookmark("x"), now: day0)
        table.insert(path: "/empty", bookmark: Data(), now: day0)
        #expect(table.isEmpty)
    }

    @Test func candidatesComeMostSpecificFirst() {
        var table = AccessGrantTable()
        table.insert(path: "/", bookmark: bookmark("disk"), now: day0)
        table.insert(path: "/Users/alex/Library", bookmark: bookmark("library"), now: day0)
        table.insert(path: "/Users/alex", bookmark: bookmark("home"), now: day0)
        #expect(table.candidates(covering: "/Users/alex/Library/Caches/x").map(\.path) == ["/Users/alex/Library", "/Users/alex", "/"])
        #expect(table.candidates(covering: "/Users/alex/Desktop").map(\.path) == ["/Users/alex", "/"])
        #expect(table.candidates(covering: "/Applications").map(\.path) == ["/"])
        #expect(AccessGrantTable().candidates(covering: "/Applications").isEmpty)
        // Only those more specific than a grant that is already in use.
        #expect(table.candidates(covering: "/Users/alex/Library/Caches/x", deeperThan: 0).map(\.path) == ["/Users/alex/Library", "/Users/alex"])
        #expect(table.candidates(covering: "/Users/alex/Library/Caches/x", deeperThan: 2).map(\.path) == ["/Users/alex/Library"])
        #expect(table.candidates(covering: "/Users/alex/Library/Caches/x", deeperThan: 3).isEmpty)
    }

    @Test func theLeastRecentlyUsedGrantsGoWhenTheTableIsFull() {
        var table = AccessGrantTable()
        for index in 0 ..< AccessGrantTable.capacity + 5 {
            table.insert(path: "/Volumes/v\(index)", bookmark: bookmark("\(index)"), now: day0.addingTimeInterval(Double(index)))
        }
        #expect(table.records.count == AccessGrantTable.capacity)
        #expect(!table.covers("/Volumes/v0") && !table.covers("/Volumes/v4"))
        #expect(table.covers("/Volumes/v5") && table.covers("/Volumes/v\(AccessGrantTable.capacity + 4)"))
    }

    @Test func aFullTableDropsWhatABroaderGrantCoversBeforeAnythingElse() {
        // The home folder, granted first and never touched again, and folders inside it.
        var table = AccessGrantTable()
        table.insert(path: "/Users/alex", bookmark: bookmark("home"), now: day0)
        table.insert(path: "/Volumes/Backup", bookmark: bookmark("backup"), now: day0.addingTimeInterval(1))
        for index in 0 ..< AccessGrantTable.capacity + 3 {
            table.insert(path: "/Users/alex/Projects/p\(index)", bookmark: bookmark("\(index)"), now: day0.addingTimeInterval(Double(10 + index)))
        }
        #expect(table.records.count == AccessGrantTable.capacity)
        // The oldest records are the two broad ones; they stay, the oldest folders inside go.
        #expect(table.records.contains { $0.path == "/Users/alex" } && table.records.contains { $0.path == "/Volumes/Backup" })
        #expect(!table.records.contains { $0.path == "/Users/alex/Projects/p0" } && !table.records.contains { $0.path == "/Users/alex/Projects/p4" })
        #expect(table.records.contains { $0.path == "/Users/alex/Projects/p5" })
        #expect(table.covers("/Users/alex/Desktop") && table.covers("/Users/alex/Projects/p0"))
        // The record just stored is never the one to go, even when a broader grant covers it.
        #expect(table.records.contains { $0.path == "/Users/alex/Projects/p\(AccessGrantTable.capacity + 2)" })
    }

    // MARK: Disks that come and go

    @Test func twoDisksUnderOneNameKeepAGrantEach() {
        var table = AccessGrantTable()
        table.insert(path: "/Volumes/Untitled", bookmark: bookmark("card A"), volumeUUID: "AAAA", now: day0)
        table.insert(path: "/Volumes/Untitled", bookmark: bookmark("card B"), volumeUUID: "BBBB", now: day0.addingTimeInterval(10))
        #expect(table.records.map(\.volumeUUID) == ["AAAA", "BBBB"])
        // The same disk again replaces its own record (UUIDs compare without regard to case).
        table.insert(path: "/Volumes/Untitled", bookmark: bookmark("card A again"), volumeUUID: "aaaa", now: day0.addingTimeInterval(20))
        #expect(table.records.count == 2 && table.records.first { $0.volumeUUID == "aaaa" }?.created == day0)
        // On the startup disk the path alone identifies a grant, whatever the UUID says.
        table.insert(path: "/Users/alex", bookmark: bookmark("home"), volumeUUID: "DATA-1", now: day0)
        table.insert(path: "/Users/alex", bookmark: bookmark("home again"), volumeUUID: "DATA-2", now: day0)
        #expect(table.records.filter { $0.path == "/Users/alex" }.map(\.bookmark) == [bookmark("home again")])
        // A record without a UUID is replaced by any grant for its path.
        table.insert(path: "/Volumes/Share", bookmark: bookmark("share"), now: day0)
        table.insert(path: "/Volumes/Share", bookmark: bookmark("share again"), volumeUUID: "CCCC", now: day0)
        #expect(table.records.filter { $0.path == "/Volumes/Share" }.count == 1)
        // Removing a location removes every disk's grant for it; the table survives encoding.
        #expect(AccessGrantTable(data: table.encoded()) == table)
        #expect(table.remove(path: "/Volumes/Untitled") && !table.covers("/Volumes/Untitled/DCIM"))
    }

    @Test func aRecordWrittenBeforeVolumeUUIDsWereKeptStillReads() throws {
        struct OldRecord: Codable {
            var path: String, bookmark: Data, created: Date, lastUsed: Date
        }
        struct OldStored: Codable {
            var version = 1
            var records: [OldRecord]
        }
        let data = try PropertyListEncoder().encode(OldStored(records: [OldRecord(path: "/Volumes/Backup", bookmark: bookmark("b"), created: day0, lastUsed: day0)]))
        let table = AccessGrantTable(data: data)
        #expect(table.records.map(\.path) == ["/Volumes/Backup"] && table.records[0].volumeUUID == nil)
    }

    @Test func aDiskThatIsNotConnectedIsToldFromABrokenBookmark() {
        let startup = [MountedVolumeIdentity(mountPoint: "/", uuid: "SYS"), MountedVolumeIdentity(mountPoint: "/System/Volumes/Data", uuid: "DATA")]
        func record(_ path: String, _ uuid: String?) -> AccessGrantRecord {
            AccessGrantRecord(path: path, bookmark: bookmark("x"), created: day0, lastUsed: day0, volumeUUID: uuid)
        }
        // Known disk: absent unless that very disk is mounted, whatever is mounted under its name.
        #expect(record("/Volumes/Untitled/DCIM", "AAAA").isOnAbsentVolume(mounted: startup))
        #expect(record("/Volumes/Untitled", "AAAA").isOnAbsentVolume(mounted: startup + [MountedVolumeIdentity(mountPoint: "/Volumes/Untitled", uuid: "BBBB")]))
        #expect(!record("/Volumes/Untitled", "AAAA").isOnAbsentVolume(mounted: startup + [MountedVolumeIdentity(mountPoint: "/Volumes/Untitled 1", uuid: "aaaa")]))
        // No UUID on record: by mount point.
        #expect(record("/Volumes/Share/x", nil).isOnAbsentVolume(mounted: startup))
        #expect(!record("/Volumes/Share/x", nil).isOnAbsentVolume(mounted: startup + [MountedVolumeIdentity(mountPoint: "/Volumes/Share", uuid: nil)]))
        // The startup disk is always there: a bookmark on it that fails is broken.
        #expect(!record("/Users/alex", "GONE").isOnAbsentVolume(mounted: startup))
        #expect(!record("/", nil).isOnAbsentVolume(mounted: []))
        #expect(!record("/Volumes", "GONE").isOnAbsentVolume(mounted: startup))
        #expect(record("/Volumes/Untitled/DCIM", nil).removableMountPoint == "/Volumes/Untitled" && record("/Users/alex", nil).removableMountPoint == nil)
    }

    @Test func theLiveMountTableKnowsTheStartupDisk() {
        let mounted = VolumeInfo.mountedIdentities()
        #expect(mounted.contains { $0.mountPoint == "/" && $0.uuid != nil })
        #expect(VolumeInfo.volumeUUID(of: URL(fileURLWithPath: "/")) == mounted.first { $0.mountPoint == "/" }?.uuid)
    }

    // MARK: Resolving stored bookmarks

    /// A stand-in for the system's bookmark resolution: what each bookmark resolves to.
    private struct FakeBookmarks {
        var targets: [Data: (path: String, stale: Bool)] = [:]
        var renewals: [String: Data?] = [:]
        /// Bookmarks on disks that are not connected.
        var absent: Set<Data> = []
        var resolved: [Data] = []
        var renewed: [String] = []

        mutating func resolve(
            _ table: inout AccessGrantTable, _ path: String, deeperThan depth: Int? = nil, now: Date
        ) -> (record: AccessGrantRecord, handle: String)? {
            var resolved: [Data] = [], renewed: [String] = []
            let targets = targets, renewals = renewals, absent = absent
            let result = table.resolve(
                covering: path, deeperThan: depth, now: now,
                resolve: { record in
                    resolved.append(record.bookmark)
                    return targets[record.bookmark].map { AccessGrantTable.Resolved(handle: $0.path, path: $0.path, isStale: $0.stale) }
                },
                isUnavailable: { absent.contains($0.bookmark) },
                renew: { handle in
                    renewed.append(handle)
                    return renewals[handle] ?? nil
                })
            self.resolved += resolved
            self.renewed += renewed
            return result
        }

        mutating func peek(_ table: AccessGrantTable, _ path: String) -> (record: AccessGrantRecord, handle: String)? {
            var resolved: [Data] = []
            let targets = targets
            let result = table.peek(covering: path) { record in
                resolved.append(record.bookmark)
                return targets[record.bookmark].map { AccessGrantTable.Resolved(handle: $0.path, path: $0.path, isStale: $0.stale) }
            }
            self.resolved += resolved
            return result
        }
    }

    @Test func aWorkingBookmarkIsUsedAndTouched() {
        var table = AccessGrantTable()
        table.insert(path: "/Users/alex", bookmark: bookmark("home"), now: day0)
        var system = FakeBookmarks(targets: [bookmark("home"): ("/Users/alex", false)])
        let later = day0.addingTimeInterval(3600)
        let found = system.resolve(&table, "/Users/alex/Library", now: later)
        #expect(found?.handle == "/Users/alex" && found?.record.path == "/Users/alex")
        #expect(table.records[0].lastUsed == later && table.records[0].created == day0)
        #expect(system.renewed.isEmpty)
        // Nothing stored covers this one: the bookmark is not even looked at.
        system.resolved = []
        #expect(system.resolve(&table, "/Applications", now: later) == nil)
        #expect(system.resolved.isEmpty && table.records.count == 1)
    }

    @Test func anUnresolvableBookmarkIsDropped() {
        var table = AccessGrantTable()
        table.insert(path: "/Volumes/Gone", bookmark: bookmark("gone"), now: day0)
        table.insert(path: "/Users/alex", bookmark: bookmark("home"), now: day0)
        var system = FakeBookmarks(targets: [bookmark("home"): ("/Users/alex", false)])
        #expect(system.resolve(&table, "/Volumes/Gone/x", now: day0) == nil)
        #expect(table.records.map(\.path) == ["/Users/alex"])
    }

    @Test func aGrantOnADiskThatIsNotConnectedIsKept() {
        var table = AccessGrantTable()
        table.insert(path: "/Volumes/Untitled", bookmark: bookmark("card A"), volumeUUID: "AAAA", now: day0)
        table.insert(path: "/Volumes/Gone", bookmark: bookmark("broken"), now: day0)
        // Card B is mounted under the same name: A's bookmark does not resolve, but A is merely away.
        var system = FakeBookmarks(absent: [bookmark("card A")])
        #expect(system.resolve(&table, "/Volumes/Untitled/DCIM", now: day0) == nil)
        #expect(table.records.map(\.path) == ["/Volumes/Untitled", "/Volumes/Gone"])
        // The user grants card B; each card then finds its own record, and neither loses it.
        table.insert(path: "/Volumes/Untitled", bookmark: bookmark("card B"), volumeUUID: "BBBB", now: day0.addingTimeInterval(5))
        system.targets = [bookmark("card B"): ("/Volumes/Untitled", false)]
        #expect(system.resolve(&table, "/Volumes/Untitled/DCIM", now: day0)?.record.volumeUUID == "BBBB")
        system = FakeBookmarks(targets: [bookmark("card A"): ("/Volumes/Untitled", false)], absent: [bookmark("card B")])
        #expect(system.resolve(&table, "/Volumes/Untitled/DCIM", now: day0)?.record.volumeUUID == "AAAA")
        #expect(table.records.filter { $0.path == "/Volumes/Untitled" }.count == 2)
        // A bookmark that fails on a disk that is there is broken, and goes.
        #expect(system.resolve(&table, "/Volumes/Gone/x", now: day0) == nil)
        #expect(!table.records.contains { $0.path == "/Volumes/Gone" })
    }

    @Test func onlyGrantsMoreSpecificThanTheOneInUseAreResolved() {
        var table = AccessGrantTable()
        table.insert(path: "/", bookmark: bookmark("disk"), now: day0)
        table.insert(path: "/Users/alex/Library/Mail", bookmark: bookmark("mail"), now: day0)
        var system = FakeBookmarks(targets: [bookmark("disk"): ("/", false), bookmark("mail"): ("/Users/alex/Library/Mail", false)])
        // "/" is in use by another window (depth 0): the folder's own grant is still found…
        #expect(system.resolve(&table, "/Users/alex/Library/Mail/V10", deeperThan: 0, now: day0)?.record.path == "/Users/alex/Library/Mail")
        // …and where there is none, nothing is resolved (the caller keeps the grant in use).
        system.resolved = []
        #expect(system.resolve(&table, "/Users/alex/Desktop", deeperThan: 0, now: day0) == nil)
        #expect(system.resolved.isEmpty && table.records.count == 2)
    }

    @Test func peekingChangesNothing() {
        var table = AccessGrantTable()
        table.insert(path: "/", bookmark: bookmark("disk"), now: day0)
        table.insert(path: "/Users/alex", bookmark: bookmark("home"), now: day0)
        table.insert(path: "/Users/alex/Library", bookmark: bookmark("library"), now: day0)
        let before = table
        // The most specific one is broken, the next one stale: neither is dropped or renewed,
        // and nothing is marked as used.
        var system = FakeBookmarks(targets: [bookmark("home"): ("/Users/alex", true), bookmark("disk"): ("/", false)])
        let found = system.peek(table, "/Users/alex/Library/Safari")
        #expect(found?.record.path == "/Users/alex" && found?.handle == "/Users/alex")
        #expect(system.resolved == [bookmark("library"), bookmark("home")] && system.renewed.isEmpty)
        #expect(table == before && table.encoded() == before.encoded())
        // Nothing resolves: still nothing is dropped.
        system = FakeBookmarks()
        #expect(system.peek(table, "/Users/alex/Library/Safari") == nil && table == before)
        // A moved folder is used where it is now, if that still reaches the path.
        system = FakeBookmarks(targets: [bookmark("library"): ("/Users/alex/Elsewhere", false), bookmark("home"): ("/Users/alex", false)])
        #expect(system.peek(table, "/Users/alex/Library/Safari")?.record.path == "/Users/alex")
        #expect(table == before)
    }

    @Test func aStaleBookmarkIsRenewedOrDropped() {
        var table = AccessGrantTable()
        table.insert(path: "/Users/alex", bookmark: bookmark("old"), now: day0)
        var system = FakeBookmarks(targets: [bookmark("old"): ("/Users/alex", true)], renewals: ["/Users/alex": bookmark("fresh")])
        let found = system.resolve(&table, "/Users/alex/Desktop", now: day0)
        #expect(found?.record.bookmark == bookmark("fresh"))
        #expect(table.records.map(\.bookmark) == [bookmark("fresh")] && system.renewed == ["/Users/alex"])

        // Renewal refused: the record goes and the caller has to ask again.
        table = AccessGrantTable()
        table.insert(path: "/Users/alex", bookmark: bookmark("old"), now: day0)
        system = FakeBookmarks(targets: [bookmark("old"): ("/Users/alex", true)])
        #expect(system.resolve(&table, "/Users/alex/Desktop", now: day0) == nil)
        #expect(table.isEmpty)
        // An empty renewal counts as refused.
        table.insert(path: "/Users/alex", bookmark: bookmark("old"), now: day0)
        system = FakeBookmarks(targets: [bookmark("old"): ("/Users/alex", true)], renewals: ["/Users/alex": Data()])
        #expect(system.resolve(&table, "/Users/alex/Desktop", now: day0) == nil && table.isEmpty)
    }

    @Test func aBrokenGrantFallsBackToTheNextOneThatCovers() {
        var table = AccessGrantTable()
        table.insert(path: "/Users/alex", bookmark: bookmark("home"), now: day0)
        table.insert(path: "/Users/alex/Library", bookmark: bookmark("library"), now: day0)
        var system = FakeBookmarks(targets: [bookmark("home"): ("/Users/alex", false)])
        let found = system.resolve(&table, "/Users/alex/Library/Caches", now: day0)
        #expect(found?.record.path == "/Users/alex")
        #expect(system.resolved == [bookmark("library"), bookmark("home")])
        #expect(table.records.map(\.path) == ["/Users/alex"])
    }

    @Test func aMovedFolderTakesItsGrantAlong() {
        var table = AccessGrantTable()
        table.insert(path: "/Users/alex/Projects", bookmark: bookmark("projects"), now: day0)
        // Renamed to Work: the bookmark still resolves, to the new place, and is stale.
        var system = FakeBookmarks(
            targets: [bookmark("projects"): ("/Users/alex/Work", true)], renewals: ["/Users/alex/Work": bookmark("work")])
        #expect(system.resolve(&table, "/Users/alex/Projects/app", now: day0) == nil)
        #expect(table.records.map(\.path) == ["/Users/alex/Work"] && table.records[0].bookmark == bookmark("work"))
        // …and from then on it serves the new location.
        system.targets = [bookmark("work"): ("/Users/alex/Work", false)]
        #expect(system.resolve(&table, "/Users/alex/Work/app", now: day0)?.handle == "/Users/alex/Work")
    }

    @Test func resolvedSpellingsOfTheStartupDiskStillMatch() {
        var table = AccessGrantTable()
        table.insert(path: "/", bookmark: bookmark("disk"), now: day0)
        // macOS 26.1 resolved a bookmark of "/" to "/.nofollow/".
        var system = FakeBookmarks(targets: [bookmark("disk"): ("/.nofollow/", false)])
        #expect(system.resolve(&table, "/Users/alex", now: day0)?.record.path == "/")
        #expect(table.records.map(\.path) == ["/"])
    }

    // MARK: A scan root that was refused

    @Test func aRefusedScanRootIsAnsweredTruthfully() {
        // Reached through the grant for the whole disk: the folder itself has not been chosen
        // yet, and Full Disk Access is not known to be on.
        #expect(RootDenialAdvice(root: "/Users/alex/Library/Mail", grantRoot: "/", fullDiskAccess: .notGranted)
            == RootDenialAdvice(offersGrantPanel: true, pointsToFullDiskAccess: true))
        #expect(RootDenialAdvice(root: "/Users/alex/Library/Mail", grantRoot: "/Users/alex", fullDiskAccess: .unknown)
            == RootDenialAdvice(offersGrantPanel: true, pointsToFullDiskAccess: true))
        // The user chose exactly this folder and macOS still refused: asking again is a loop.
        #expect(RootDenialAdvice(root: "/Users/alex/Library/Mail", grantRoot: "/Users/alex/Library/Mail", fullDiskAccess: .notGranted)
            == RootDenialAdvice(offersGrantPanel: false, pointsToFullDiskAccess: true))
        #expect(!RootDenialAdvice(root: "/Users/alex/Library/Mail/", grantRoot: "/System/Volumes/Data/Users/alex/Library/Mail", fullDiskAccess: .notGranted).offersGrantPanel)
        #expect(!RootDenialAdvice(root: "/tmp/disksurvey-denied", grantRoot: "/private/tmp/disksurvey-denied", fullDiskAccess: .unknown).offersGrantPanel)
        // Full Disk Access is on: it is not the missing piece, so it is not pointed to.
        #expect(RootDenialAdvice(root: "/Volumes/Backup/x", grantRoot: "/", fullDiskAccess: .granted)
            == RootDenialAdvice(offersGrantPanel: true, pointsToFullDiskAccess: false))
        #expect(RootDenialAdvice(root: "/Volumes/Backup", grantRoot: "/Volumes/Backup", fullDiskAccess: .granted)
            == RootDenialAdvice(offersGrantPanel: false, pointsToFullDiskAccess: false))
        // No grant at all (should not happen, since the scan would not have started): ask.
        #expect(RootDenialAdvice(root: "/Users/alex", grantRoot: nil, fullDiskAccess: .unknown).offersGrantPanel)
    }

    @Test func aRootThatMayNotBeListedCountsAsRefused() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "disksurvey-refused-\(UUID().uuidString)")
        let locked = base.appending(path: "locked"), open = base.appending(path: "open"), partly = base.appending(path: "partly")
        defer {
            chmod(locked.path, 0o700)
            chmod(partly.appending(path: "inner").path, 0o700)
            try? FileManager.default.removeItem(at: base)
        }
        for folder in [locked.appending(path: "inside"), open, partly.appending(path: "inner")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: partly.appending(path: "file.txt"))
        #expect(chmod(locked.path, 0) == 0 && chmod(partly.appending(path: "inner").path, 0) == 0)

        // Can be examined, cannot be listed: this is how a privacy-protected folder answers.
        let refused = await ScanSession.scan(locked)
        #expect(refused.rootKind == .directory && refused.rootWasRefused && refused.permissionDeniedCount == 1)
        // An empty folder is just empty; one with an unreadable folder inside is not refused.
        #expect(!(await ScanSession.scan(open)).rootWasRefused)
        let inner = await ScanSession.scan(partly)
        #expect(!inner.rootWasRefused && inner.permissionDeniedCount == 1)
        // Missing is not a matter of permission.
        let missing = await ScanSession.scan(base.appending(path: "nowhere"))
        #expect(missing.rootKind == .inaccessible && !missing.rootWasRefused)
    }

    // MARK: Full Disk Access

    private func access(
        sandboxed: Bool, reachable: Set<String> = [], readable: Set<String> = [], denied: Set<String> = []
    ) -> (FullDiskAccess, [String]) {
        var probed: [String] = []
        let state = DiskAccess.evaluate(home: "/Users/alex", sandboxed: sandboxed, reachable: { path in reachable.contains { GrantPath.covers($0, path) } }) { path, _ in
            probed.append(path)
            return readable.contains(path) ? .readable : (denied.contains(path) ? .denied : .absent)
        }
        return (state, probed)
    }

    private let userDatabase = "/Users/alex/Library/Application Support/com.apple.TCC/TCC.db"
    private let systemDatabase = "/Library/Application Support/com.apple.TCC/TCC.db"

    @Test func withoutASandboxTheAnswerIsYesOrNo() {
        #expect(access(sandboxed: false, readable: [userDatabase]).0 == .granted)
        #expect(access(sandboxed: false, denied: [userDatabase]).0 == .notGranted)
        // The first conclusive probe decides.
        let (state, probed) = access(sandboxed: false, readable: [systemDatabase], denied: ["/Users/alex/Library/Mail"])
        #expect(state == .granted && probed == [userDatabase, systemDatabase])
        // Nothing to probe has always meant "no".
        let nothing = access(sandboxed: false)
        #expect(nothing.0 == .notGranted && nothing.1.count == DiskAccess.probeLocations(home: "/Users/alex").count)
    }

    @Test func inTheSandboxOnlyProbesWithinAGrantCount() {
        // No grant in reach: the sandbox would refuse every probe, so none is made.
        let blind = access(sandboxed: true, denied: [userDatabase, systemDatabase])
        #expect(blind.0 == .unknown && blind.1.isEmpty)
        // A grant for some project folder says nothing either.
        #expect(access(sandboxed: true, reachable: ["/Users/alex/Projects"], denied: [userDatabase]).0 == .unknown)
        // The home folder is granted: its probes count, the system-wide database is skipped.
        let home = access(sandboxed: true, reachable: ["/Users/alex"], denied: [userDatabase])
        #expect(home.0 == .notGranted && home.1 == [userDatabase])
        let allowed = access(sandboxed: true, reachable: ["/Users/alex"], readable: ["/Users/alex/Library/Safari"])
        #expect(allowed.0 == .granted && !allowed.1.contains(systemDatabase))
        // The disk is granted: everything is probed.
        #expect(access(sandboxed: true, reachable: ["/"], readable: [systemDatabase]).0 == .granted)
        #expect(access(sandboxed: true, reachable: ["/"], denied: [systemDatabase]).0 == .notGranted)
        // In reach, but none of the probe files exists: still not known.
        #expect(access(sandboxed: true, reachable: ["/"]).0 == .unknown)
    }

    @Test func theLiveStateAgreesWithTheBoolean() {
        let state = DiskAccess.fullDiskAccessState()
        #expect(state != .unknown)
        #expect((state == .granted) == DiskAccess.hasFullDiskAccess())
        // Forced into the sandboxed rule with nothing in reach.
        #expect(DiskAccess.fullDiskAccessState(sandboxed: true) == .unknown)
    }
}
