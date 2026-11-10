import Foundation
import Testing
@testable import DiskSurveyCore

/// Checks every structural invariant a FileTree promises; returns human-readable violations.
func invariantViolations(_ tree: FileTree, limit: Int = 5) -> [String] {
    var issues: [String] = []
    func report(_ message: String) { if issues.count < limit { issues.append(message) } }

    if !tree.isDirectory(0) { report("root is not a directory") }
    if tree.parent(of: 0) != nil { report("root has a parent") }
    var seenAsChild = 0
    for index in 0 ..< tree.count {
        let id = NodeID(index)
        if tree.isRemoved(id) {
            // Tombstones are empty: nothing listed below them, no size, no link identity.
            if tree.childCount(of: id) != 0 { report("removed node \(id) still lists \(tree.childCount(of: id)) children") }
            if tree.size(of: id) != 0 || tree.fileCount(of: id) != 0 { report("removed node \(id) has a size") }
            if tree.linkID(of: id) != nil { report("removed node \(id) keeps a link identity") }
            continue
        }
        let children = tree.children(of: id)
        if !tree.isDirectory(id) {
            if !children.isEmpty { report("file \(id) has children") }
            continue
        }
        var allocated: UInt64 = 0
        var logical: UInt64 = 0
        var files = 0
        var previous: NodeID?
        for child in children {
            seenAsChild += 1
            if tree.parent(of: child) != id { report("child \(child) of \(id) has parent \(String(describing: tree.parent(of: child)))") }
            if tree.isRemoved(child) { report("removed node \(child) listed under \(id)") }
            allocated += tree.size(of: child)
            logical += tree.logicalSize(of: child)
            files += tree.fileCount(of: child)
            if let previous {
                let a = tree.size(of: previous)
                let b = tree.size(of: child)
                if a < b || (a == b && previous > child) { report("children of \(id) not sorted at \(child)") }
            }
            previous = child
        }
        if allocated != tree.size(of: id) { report("dir \(id) size \(tree.size(of: id)) != children sum \(allocated)") }
        if logical != tree.logicalSize(of: id) { report("dir \(id) logical size mismatch") }
        if files != tree.fileCount(of: id) { report("dir \(id) file count \(tree.fileCount(of: id)) != \(files)") }
    }
    var live = 0
    for index in 0 ..< tree.count where !tree.isRemoved(NodeID(index)) { live += 1 }
    if seenAsChild != live - 1 { report("\(live - 1) live non-root nodes but \(seenAsChild) child links") }

    // Hard links: per inode exactly one live link carries the size, the others are zero duplicates.
    var counted: [FileTree.LinkID: Int] = [:]
    for (node, info) in tree._links {
        if tree.isDirectory(node) { report("directory \(node) has a link identity") }
        if tree.flags(of: node).contains(.hardLinkDuplicate) {
            counted[info.id, default: 0] += 0
            if tree.size(of: node) != 0 || tree.logicalSize(of: node) != 0 { report("duplicate link \(node) has a size") }
        } else {
            counted[info.id, default: 0] += 1
            if tree.size(of: node) != info.allocated || tree.logicalSize(of: node) != info.logical {
                report("counted link \(node) does not carry its size")
            }
        }
    }
    for (id, n) in counted where n != 1 { report("inode \(id.inode) is counted \(n) times") }
    return issues
}

/// A small fixed tree used by many tests.
///
///     /Volumes/Demo
///     ├── Movies          (4_120_000_000)
///     │   ├── holiday.MP4   4_000_000_000
///     │   └── clip.mov        120_000_000
///     ├── Projects        (1_050_800)
///     │   ├── Disk Survey.app   (1_000_000)   package
///     │   │   └── Contents
///     │   │       └── binary  1_000_000
///     │   ├── main.swift       40_000
///     │   ├── README.md         8_000
///     │   └── .gitignore        2_800
///     ├── Empty
///     ├── archive.tar.gz   900_000
///     └── notes.txt          4_096   (logical 1_200)
func demoTree() -> FileTree {
    FileTree.make(rootPath: "/Volumes/Demo", rootModified: 1_700_000_000, [
        .file("notes.txt", 4096, logical: 1200, modified: 1_600_000_000),
        .dir("Projects", modified: 1_650_000_000, [
            .file(".gitignore", 2800),
            .file("README.md", 8000, modified: 1_690_000_000),
            .file("main.swift", 40_000, modified: 1_699_000_000),
            .dir("Disk Survey.app", [.dir("Contents", [.file("binary", 1_000_000)])]),
        ]),
        .dir("Empty"),
        .file("archive.tar.gz", 900_000, modified: 1_500_000_000),
        .dir("Movies", [
            .file("clip.mov", 120_000_000, modified: 1_695_000_000),
            .file("holiday.MP4", 4_000_000_000, modified: 1_400_000_000),
        ]),
    ])
}

extension FileTree {
    func id(_ relativePath: String) -> NodeID {
        guard let id = node(atPath: rootPath + "/" + relativePath) else {
            Issue.record("no node at \(relativePath)")
            return 0
        }
        return id
    }

    func childNames(_ id: NodeID) -> [String] { children(of: id).map { name(of: $0) } }
}
