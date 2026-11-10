import Foundation

/// A mounted volume, as shown on the start screen.
public struct Volume: Sendable, Hashable, Identifiable {
    /// The mount point path without a trailing slash (except "/"); unique among mounted volumes.
    public var id: String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
    /// The user-visible name ("Macintosh HD").
    public var name: String
    /// The mount point.
    public var url: URL
    /// Size of the volume — for APFS, of the container the volume shares with its siblings.
    public var totalCapacity: UInt64
    /// Free bytes right now, as the filesystem reports them.
    public var availableCapacity: UInt64
    /// Free bytes counting space the system would reclaim on demand (purgeable caches, local
    /// snapshots). This is the "Available" figure Finder shows; falls back to
    /// ``availableCapacity`` where the system does not report it.
    public var availableCapacityForImportantUsage: UInt64
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isNetwork: Bool
    /// The startup volume, mounted at `/`.
    public var isRoot: Bool
    public var isReadOnly: Bool
    /// False for volumes the system hides from the Finder (Preboot, VM, Recovery, …).
    public var isBrowsable: Bool
    /// "apfs", "hfs", "exfat", "smbfs", …
    public var fileSystemType: String
    /// The device or share behind the volume ("/dev/disk3s5", "//user@host/share").
    public var device: String

    /// Bytes in use, counting purgeable space as used (matches what a scan can find).
    public var usedCapacity: UInt64 { totalCapacity >= availableCapacity ? totalCapacity - availableCapacity : 0 }
    /// Space the system could free on demand.
    public var purgeableCapacity: UInt64 {
        availableCapacityForImportantUsage >= availableCapacity ? availableCapacityForImportantUsage - availableCapacity : 0
    }
    /// Fraction in use, 0…1.
    public var usedFraction: Double { totalCapacity > 0 ? Double(usedCapacity) / Double(totalCapacity) : 0 }
}

/// Mounted volumes and their capacities. Foundation and `statfs` only — no AppKit.
public enum VolumeInfo {
    private static let keys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
        .volumeIsBrowsableKey,
    ]

    /// The volumes a user would recognize: the startup disk first, then the others by name.
    ///
    /// - Parameter includeHidden: also list volumes hidden from the Finder (system helper
    ///   volumes, `devfs`, …). Volumes with no capacity (pseudo filesystems) are always left out
    ///   unless this is set.
    public static func mounted(includeHidden: Bool = false) -> [Volume] {
        var volumes: [Volume] = []
        for mount in MountTable.readMounts() {
            guard let volume = volume(for: mount) else { continue }
            if !includeHidden, !volume.isRoot {
                if !volume.isBrowsable || volume.totalCapacity == 0 { continue }
                // The Data volume and the other members of the startup volume group report
                // themselves as browsable, but to the user they are part of the startup disk.
                if mount.mountPoint.hasPrefix("/System/Volumes/") { continue }
            }
            volumes.append(volume)
        }
        return volumes.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Every mounted filesystem with its volume UUID, hidden ones included. Used to tell a
    /// disk that is not connected from a bookmark that no longer works.
    public static func mountedIdentities() -> [MountedVolumeIdentity] {
        MountTable.readMounts().map { mount in
            let url = URL(filePath: mount.mountPoint, directoryHint: .isDirectory)
            return MountedVolumeIdentity(mountPoint: mount.mountPoint, uuid: volumeUUID(of: url))
        }
    }

    /// The UUID of the volume `url` is on; `nil` when the volume has none or it cannot be read.
    public static func volumeUUID(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// The volume a path lives on, if it can be determined.
    public static func volume(containing url: URL) -> Volume? {
        var fs = statfs()
        guard statfs(url.path(percentEncoded: false), &fs) == 0 else { return nil }
        return volume(for: MountEntry(fs))
    }

    private static func volume(for mount: MountEntry) -> Volume? {
        let url = URL(filePath: mount.mountPoint, directoryHint: .isDirectory)
        let values = try? url.resourceValues(forKeys: keys)

        // statfs is the fallback for anything the resource values do not provide (they can be
        // missing for pseudo and some third-party filesystems).
        var fs = statfs()
        let haveStat = statfs(mount.mountPoint, &fs) == 0
        let blockSize = UInt64(fs.f_bsize)
        let statTotal = haveStat ? UInt64(fs.f_blocks) &* blockSize : 0
        let statAvailable = haveStat ? UInt64(fs.f_bavail) &* blockSize : 0

        let total = values?.volumeTotalCapacity.map { UInt64(max(0, $0)) } ?? statTotal
        let available = values?.volumeAvailableCapacity.map { UInt64(max(0, $0)) } ?? statAvailable
        // The "important usage" figure is reported as 0 on volumes that do not support it.
        let important = values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? 0

        // Not `volumeIsRootFileSystem`: that is also true for the Data volume of the startup
        // volume group, and there must be exactly one startup entry.
        let isRoot = mount.mountPoint == "/"
        let name =
            values?.volumeLocalizedName ?? values?.volumeName
            ?? (isRoot ? "/" : URL(filePath: mount.mountPoint).lastPathComponent)

        return Volume(
            name: name, url: url, totalCapacity: total, availableCapacity: available,
            availableCapacityForImportantUsage: max(important, available),
            isInternal: values?.volumeIsInternal ?? false, isRemovable: values?.volumeIsRemovable ?? false,
            isEjectable: values?.volumeIsEjectable ?? false, isNetwork: !(values?.volumeIsLocal ?? mount.isLocal),
            isRoot: isRoot, isReadOnly: values?.volumeIsReadOnly ?? mount.isReadOnly,
            isBrowsable: values?.volumeIsBrowsable ?? mount.isBrowsable, fileSystemType: mount.fileSystemType,
            device: mount.device)
    }
}
