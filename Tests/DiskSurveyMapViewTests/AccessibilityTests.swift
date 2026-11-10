import AppKit
import Testing
import DiskSurveyCore
import DiskSurveyTreemap

@testable import DiskSurveyMapView

extension LiveViewTests {
@MainActor @Suite struct AccessibilityTests {
    @MainActor final class Log {
        var posts: [(notification: NSAccessibility.Notification, text: String?, onWindow: Bool)] = []
        func count(_ notification: NSAccessibility.Notification) -> Int { posts.filter { $0.notification == notification }.count }
        var announcements: [String] { posts.compactMap(\.text) }
    }

    private func attach(_ map: MapFixture) -> Log {
        let log = Log()
        map.view.accessibilityPoster = { element, notification, userInfo in
            MainActor.assumeIsolated {
                log.posts.append((notification, userInfo?[.announcement] as? String, element is NSWindow))
            }
        }
        return log
    }

    @Test func userSelectionChangesAreAnnouncedOnce() async throws {
        let map = await MapFixture(inWindow: true)
        let log = attach(map)
        let (point, node) = try #require(map.deepPoint(minDepth: 3))
        let tree = map.tree

        map.click(at: point)
        // One item is spoken in the singular ("image", not "images").
        let kind = TreemapView.spokenKind(of: node, in: tree)
        #expect(kind == (tree.isDirectory(node) ? "folder" : tree.category(of: node).singularName.lowercased()))
        #expect(log.announcements == ["\(tree.name(of: node)), \(kind), \(Format.bytes(tree.size(of: node)))"])
        #expect(log.posts.first { $0.text != nil }?.onWindow == true)
        #expect(log.count(.selectedChildrenChanged) == 1)
        // Spoken once: no re-read of the whole summary on top of the announcement.
        #expect(log.count(.valueChanged) == 0)

        // Arrow keys: one announcement per move that lands somewhere.
        var moves = 0
        for (character, code) in [("\u{F703}", 124), ("\u{F702}", 123), ("\u{F700}", 126), ("\u{F701}", 125)] as [(String, UInt16)] {
            let before = map.view.selection
            map.key(character, code: code)
            if map.view.selection != before { moves += 1 }
        }
        #expect(moves > 0)
        #expect(log.announcements.count == 1 + moves)

        // Several items, then none.
        let others = map.distinctNodes(3).map(\.node)
        map.view.setSelectionByUser(Set(others), primary: nil)
        let bytes = others.reduce(UInt64(0)) { $0 + tree.size(of: $1) }
        #expect(log.announcements.last == "3 items selected, \(Format.bytes(bytes))")
        map.view.setSelectionByUser([], primary: nil)
        #expect(log.announcements.last == "No selection")
    }

    @Test func programmaticSelectionIsNotAnnouncedButNotified() async throws {
        let map = await MapFixture(inWindow: true)
        let log = attach(map)
        let (_, node) = try #require(map.deepPoint(minDepth: 3))
        map.view.selection = [node]
        #expect(log.announcements.isEmpty)
        #expect(log.count(.valueChanged) == 1)
        #expect(log.count(.selectedChildrenChanged) == 1)
        // Assigning the same selection again is silent.
        map.view.selection = [node]
        #expect(log.posts.count == 2)
    }

    @Test func layoutChangeIsPostedOncePerShownFolderOnly() async throws {
        let map = await MapFixture(inWindow: true)
        let log = attach(map)
        let view = map.view
        let folder = try #require(map.tree.children(of: 0).first { map.tree.isDirectory($0) && map.tree.childCount(of: $0) > 0 })

        // Same folder, new pictures: recolour, resize, an in-place deletion.
        view.colorMode = .age
        #expect(await map.awaitNewFrame())
        view.setFrameSize(CGSize(width: 700, height: 500))
        #expect(await map.awaitNewFrame())
        var mutated = map.tree
        let victim = try #require(map.tree.children(of: folder).first)
        _ = mutated.remove(victim)
        view.tree = mutated
        #expect(await map.awaitNewFrame())
        #expect(log.count(.layoutChanged) == 0)
        #expect(log.count(.titleChanged) == 0)

        // A zoom: once.
        view.rootNode = folder
        #expect(await map.awaitNewFrame())
        #expect(log.count(.layoutChanged) == 1)
        #expect(log.count(.titleChanged) == 1)
        view.rootNode = 0
        #expect(await map.awaitNewFrame())
        #expect(log.count(.layoutChanged) == 2)

        // Scan snapshots of the same location: silent.
        view.setTree(FileTree.synthetic(nodeCount: 20_000, seed: 8), nodeIDsStable: false)
        #expect(await pump { view.interactiveFrame != nil })
        #expect(log.count(.layoutChanged) == 2)

        // Another location: once.
        view.setTree(FileTree.synthetic(nodeCount: 5_000, seed: 3, rootPath: "/Elsewhere"), nodeIDsStable: false)
        #expect(await pump { view.interactiveFrame != nil })
        #expect(log.count(.layoutChanged) == 3)
    }

    @Test func nothingIsPostedWithoutAWindow() async throws {
        let map = await MapFixture()
        let log = attach(map)
        let (point, _) = try #require(map.deepPoint(minDepth: 3))
        map.click(at: point)
        map.view.selection = []
        #expect(log.posts.isEmpty)
    }

    @Test func selectedChildrenContainTheTileAroundANestedSelection() async throws {
        let map = await MapFixture(inWindow: true)
        let (_, node) = try #require(map.deepPoint(minDepth: 4))
        var top = node
        while let parent = map.tree.parent(of: top), parent != 0 { top = parent }

        #expect(map.view.accessibilitySelectedChildren()?.isEmpty == true)
        map.view.selection = [node]
        let selected = try #require(map.view.accessibilitySelectedChildren() as? [TreemapAccessibilityElement])
        #expect(selected.map(\.node) == [top])
    }
}
}
