import Foundation

/// One line of the kernel's mount table.
struct MountEntry: Sendable {
    var mountPoint: String
    var device: String  // f_mntfromname, e.g. "/dev/disk3s5" or "//user@host/share"
    var fileSystemType: String  // "apfs", "smbfs", "devfs", …
    var flags: UInt32
    /// The `st_dev` of everything on this filesystem (`f_fsid.val[0]`).
    var deviceID: Int32 = 0

    var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }
    var isReadOnly: Bool { flags & UInt32(MNT_RDONLY) != 0 }
    var isBrowsable: Bool { flags & UInt32(MNT_DONTBROWSE) == 0 }
    var isAutomounted: Bool { flags & UInt32(MNT_AUTOMOUNTED) != 0 }

    /// "disk3" for "/dev/disk3s1s1": the whole disk, which for APFS is the container.
    var containerDisk: String? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        let digits = device.dropFirst("/dev/disk".count).prefix { $0.isNumber }
        return digits.isEmpty ? nil : "disk" + digits
    }
}

/// A snapshot of the mount table, taken once per scan. Mount points are rare, so lookups by
/// path string are fine; the hot loop only gets here for entries the kernel flagged as mounts.
struct MountTable: Sendable {
    private(set) var byMountPoint: [String: MountEntry] = [:]

    init(entries: [MountEntry] = []) {
        for entry in entries { byMountPoint[entry.mountPoint] = entry }
    }

    static func current() -> MountTable { MountTable(entries: readMounts()) }

    subscript(path: String) -> MountEntry? { byMountPoint[path] }

    static func readMounts() -> [MountEntry] {
        // The table can grow between the sizing call and the real one; ask with some slack.
        let count = Int(getfsstat(nil, 0, MNT_NOWAIT))
        guard count > 0 else { return [] }
        let capacity = count + 8
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let filled = Int(getfsstat(buffer, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT))
        guard filled > 0 else { return [] }
        return (0 ..< min(filled, capacity)).map { MountEntry(buffer[$0]) }
    }
}

extension MountEntry {
    init(_ fs: statfs) {
        var fs = fs
        mountPoint = MountEntry.string(&fs.f_mntonname)
        device = MountEntry.string(&fs.f_mntfromname)
        fileSystemType = MountEntry.string(&fs.f_fstypename)
        flags = fs.f_flags
        deviceID = fs.f_fsid.val.0
    }

    /// The entry of the filesystem that `path` is on, straight from the kernel; `nil` if it
    /// cannot be examined. For a mount point this is what is mounted there.
    init?(containing path: String) {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        self.init(fs)
    }

    /// Reads a fixed-size C char array (imported as a tuple) as a string.
    private static func string<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// Decides which mount points a scan enters. See ``ScanOptions`` for the user-facing rules.
struct MountPolicy: Sendable {
    /// Filesystems that hold no data of their own: device nodes, automount maps, and `nullfs`
    /// re-exports of directories that exist elsewhere (entering those would double count).
    static let pseudoFileSystems: Set<String> = ["devfs", "autofs", "nullfs", "fdesc", "volfs"]
    static let dataVolumeMountPoint = "/System/Volumes/Data"

    let table: MountTable
    let options: ScanOptions
    /// True when the scan root is `/`, the only root from which the Data volume is reachable
    /// twice (through firmlinks and through its mount point).
    let rootIsStartupRoot: Bool
    private let rootContainer: String?
    /// Where the filesystem holding the scan root is mounted, in the kernel's spelling.
    private let rootMountPoint: String?

    init(table: MountTable, options: ScanOptions, rootPath: String) {
        self.table = table
        self.options = options
        rootIsStartupRoot = rootPath == "/"
        rootContainer = table["/"]?.containerDisk
        rootMountPoint = MountEntry(containing: rootPath)?.mountPoint
    }

    /// Firmlinked directories are skipped only on request, and only where they are firmlinks
    /// *out of* the scanned volume (i.e. when scanning the system volume from `/`).
    var skipsFirmlinks: Bool { rootIsStartupRoot && !options.followFirmlinkedDataVolume }

    /// Whether the scan descends into what is mounted at `path` (a path as the scan spells it).
    func shouldEnter(mountPoint path: String) -> Bool {
        if let mount = table[path] { return shouldEnter(mount) }
        // Not in the table under this name. Either it was mounted after the scan began, or the
        // scan spells the path differently from the kernel: a root given as
        // `/System/Volumes/Data/…` keeps that prefix, the mount table says `/private/var/…`.
        // Without the options that can let a scan in there is nothing to find out.
        guard options.crossMountPoints || (rootIsStartupRoot && options.includeSiblingSystemVolumes) else { return false }
        // Ask the kernel what is mounted there, so the rules below — above all "never enter a
        // pseudo filesystem" — apply however the path was spelled.
        guard let mount = MountEntry(containing: path) else {
            // Nothing can be found out about it; only the explicit "cross everything" applies.
            return options.crossMountPoints
        }
        // The answer describes the scan root's own filesystem: as far as the kernel can tell
        // this is no separate mount, so there is still no information to act on.
        if let rootMountPoint, mount.mountPoint == rootMountPoint { return false }
        return shouldEnter(mount)
    }

    /// The rules proper, for a mount whose table entry is known. They look at the entry's own
    /// (canonical) mount point, never at the spelling it was found under.
    func shouldEnter(_ mount: MountEntry) -> Bool {
        if MountPolicy.pseudoFileSystems.contains(mount.fileSystemType) || mount.isAutomounted { return false }
        if rootIsStartupRoot, mount.mountPoint == MountPolicy.dataVolumeMountPoint { return false }
        if options.crossMountPoints { return true }
        if rootIsStartupRoot, options.includeSiblingSystemVolumes, mount.isLocal,
            mount.fileSystemType == "apfs", let container = mount.containerDisk, container == rootContainer,
            !mount.mountPoint.hasPrefix("/Volumes/")
        {
            return true
        }
        return false
    }
}
