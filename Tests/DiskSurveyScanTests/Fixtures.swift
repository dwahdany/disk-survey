import Foundation
import DiskSurveyCore
@testable import DiskSurveyScan

/// A temporary directory tree that is removed when the fixture goes away.
final class Fixture {
    /// Canonical path (the temp dir lives behind the /var -> /private/var symlink).
    let path: String
    var url: URL { URL(filePath: path) }

    init(_ label: String = "fixture") {
        let base = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        let raw = base + "/disksurvey-\(label)-\(UUID().uuidString.prefix(8))"
        mkdir(raw, 0o755)
        let resolved = realpath(raw, nil)!
        path = String(cString: resolved)
        free(resolved)
    }

    deinit {
        // Make everything traversable again (tests chmod things to 000), then remove with
        // descriptor-relative calls so paths longer than PATH_MAX are no obstacle.
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 {
            Fixture.removeContents(of: fd)
            close(fd)
        }
        rmdir(path)
    }

    private static func removeContents(of fd: Int32) {
        guard let stream = fdopendir(dup(fd)) else { return }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if entry.pointee.d_type == DT_DIR {
                fchmodat(fd, name, 0o700, 0)
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if child >= 0 {
                    removeContents(of: child)
                    close(child)
                }
                unlinkat(fd, name, AT_REMOVEDIR)
            } else {
                unlinkat(fd, name, 0)
            }
        }
    }

    @discardableResult func dir(_ relative: String) -> String {
        let full = path + "/" + relative
        try! FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    /// Writes `size` bytes of non-zero data (so nothing can be stored as a hole).
    @discardableResult func file(_ relative: String, size: Int) -> String {
        let full = path + "/" + relative
        let parent = (full as NSString).deletingLastPathComponent
        try! FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let fd = open(full, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        precondition(fd >= 0, "cannot create \(full): \(String(cString: strerror(errno)))")
        if size > 0 {
            let chunk = [UInt8](repeating: 0xA5, count: min(size, 1 << 16))
            var remaining = size
            while remaining > 0 {
                let n = chunk.withUnsafeBytes { write(fd, $0.baseAddress, min(remaining, $0.count)) }
                precondition(n > 0)
                remaining -= n
            }
        }
        close(fd)
        return full
    }
}

/// What an independent, single-threaded lstat walk says about a tree — the oracle the scanner
/// is compared against.
struct ReferenceTotals: Equatable {
    var allocated: UInt64 = 0
    var logical: UInt64 = 0
    var files = 0
    var directories = 0

    static func walk(_ root: String) -> ReferenceTotals {
        var totals = ReferenceTotals()
        var seen = Set<UInt64>()
        func visit(_ path: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
            for name in names {
                let child = path + "/" + name
                var info = stat()
                guard lstat(child, &info) == 0 else { continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    totals.directories += 1
                    visit(child)
                } else {
                    totals.files += 1
                    if info.st_nlink > 1, !seen.insert(info.st_ino).inserted { continue }
                    totals.allocated += UInt64(info.st_blocks) * 512
                    totals.logical += UInt64(info.st_size)
                }
            }
        }
        visit(root)
        return totals
    }
}

func scan(_ path: String, _ configure: (inout ScanOptions) -> Void = { _ in }) -> ScanResult {
    var options = ScanOptions()
    configure(&options)
    let session = ScanSession(root: URL(filePath: path), options: options)
    session.start()
    return session.waitBlocking()
}

extension FileTree {
    /// Node for a path relative to the root, e.g. "a/b/c.txt".
    func node(_ relative: String) -> NodeID? {
        var current = root
        for component in relative.split(separator: "/") {
            guard let next = child(of: current, named: String(component)) else { return nil }
            current = next
        }
        return current
    }

    /// Structural invariants every tree (partial or final) must satisfy.
    func invariantViolations() -> [String] {
        var problems: [String] = []
        for index in 0 ..< count {
            let id = NodeID(index)
            if isRemoved(id) { continue }
            if id != root, parent(of: id) == nil { problems.append("node \(id) has no parent") }
            guard isDirectory(id) else { continue }
            var allocated: UInt64 = 0
            var logical: UInt64 = 0
            var files = 0
            var previous = UInt64.max
            for child in children(of: id) {
                if parent(of: child) != id { problems.append("child \(child) of \(id) has another parent") }
                let size = size(of: child)
                if size > previous { problems.append("children of \(id) not sorted") }
                previous = size
                allocated += size
                logical += logicalSize(of: child)
                files += fileCount(of: child)
            }
            if allocated != size(of: id) || logical != logicalSize(of: id) || files != fileCount(of: id) {
                problems.append("totals of \(id) do not add up")
            }
            if problems.count > 10 { break }
        }
        return problems
    }
}

/// A small disk image attached (hidden from Finder) at a directory inside a fixture, detached
/// again when the value goes away. `nil` when `hdiutil` cannot do it here.
final class MountedImage {
    let mountPoint: String
    private let image: String
    /// The device node behind the mount ("/dev/disk9s1"). Detaching goes by this: the mount
    /// point's recorded path goes stale if a folder above it is renamed.
    private let device: String
    private var attached = true

    init?(at mountPoint: String, imagePath: String) {
        self.mountPoint = mountPoint
        image = imagePath
        guard MountedImage.hdiutil(["create", "-size", "4m", "-fs", "HFS+", "-volname", "DiskSurveyTest", "-quiet", imagePath]),
            MountedImage.hdiutil(["attach", "-nobrowse", "-quiet", "-mountpoint", mountPoint, imagePath]),
            let mount = MountEntry(containing: mountPoint), mount.device.hasPrefix("/dev/disk")
        else {
            _ = MountedImage.hdiutil(["detach", "-force", "-quiet", mountPoint])
            unlink(imagePath)
            return nil
        }
        device = mount.device
    }

    deinit { detach() }

    func detach() {
        guard attached else { return }
        attached = false
        _ = MountedImage.hdiutil(["detach", "-force", "-quiet", device])
        unlink(image)
    }

    private static func hdiutil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
