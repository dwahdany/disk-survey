import AppKit
import IOSurface
import QuartzCore
import Testing
import DiskSurveyCore
import DiskSurveyTreemap

@testable import DiskSurveyMapView

extension LiveViewTests {
@MainActor @Suite struct RenderTests {
    private func key(size: CGSize = CGSize(width: 800, height: 600), scale: CGFloat = 2, labels: Bool = true) -> RenderKey {
        FrameRenderer.makeKey(
            size: size, backingScale: scale, treeVersion: 1, idEpoch: 1, root: 0, style: .framed, sizeMetric: .allocated,
            packagesAsLeaves: false, colorMode: .kind, ageNow: FileTree.syntheticReferenceTime, scheme: .light,
            highlightVersion: 0, labels: labels)
    }

    private func render(_ tree: FileTree, _ key: RenderKey, target: RenderTarget = .image) -> RenderedFrame {
        FrameRenderer.render(RenderRequest(serial: 1, key: key, tree: tree, highlight: .none), mask: nil, target: target)
    }

    /// The image's pixels in a fixed format (sRGB, premultiplied BGRA, no row padding).
    private func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: FrameRenderer.sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    // MARK: Labels

    /// The layout reserves a rect for every overlay label and places tile labels around it;
    /// the pill the view draws must stay inside that rect, whatever the name measures.
    @Test func overlayPillsStayInsideTheReservedRect() {
        var fonts = FontCache()
        let white = CGColor(gray: 1, alpha: 1)
        var checked = 0
        var withDetail = 0
        var sample: TreemapLabel?
        for seed: UInt64 in [3, 5, 13, 17, 25, 29, 32, 34, 36] {
            let tree = FileTree.synthetic(nodeCount: 20_000, seed: seed)
            for size in [CGSize(width: 1660, height: 2200), CGSize(width: 2400, height: 1500), CGSize(width: 1200, height: 900)] {
                // Sizes are given in pixels; at scale 2 the view is half as many points.
                let key = FrameRenderer.makeKey(
                    size: CGSize(width: size.width / 2, height: size.height / 2), backingScale: 2, treeVersion: 1, idEpoch: 1,
                    root: 0, style: .cushion, sizeMetric: .allocated, packagesAsLeaves: false, colorMode: .kind,
                    ageNow: FileTree.syntheticReferenceTime, scheme: .light, highlightVersion: 0, labels: true)
                #expect(key.pixelWidth == Int(size.width) && key.pixelHeight == Int(size.height))
                let layout = TreemapLayout(
                    tree: tree, root: 0, bounds: TreemapRect(x: 0, y: 0, width: Float(key.pixelWidth), height: Float(key.pixelHeight)),
                    options: FrameRenderer.layoutOptions(for: key))
                let options = LabelRenderer.labelOptions(for: key)
                let pad = CGFloat(options.overlayPaddingPixels)
                for label in layout.labels(options) where label.kind == .overlay {
                    let box = CGRect(
                        x: CGFloat(label.rect.minX), y: CGFloat(label.rect.minY), width: CGFloat(label.rect.width),
                        height: CGFloat(label.rect.height))
                    guard
                        let overlay = LabelRenderer.overlayPill(
                            name: tree.name(of: label.node), sizeText: Format.bytes(tree.size(of: label.node)), label: label,
                            box: box, pad: pad, fonts: &fonts, textColor: white, detailColor: white)
                    else { continue }
                    checked += 1
                    sample = label
                    if overlay.detail != nil { withDetail += 1 }
                    #expect(overlay.pill.maxX <= CGFloat(label.rect.maxX) + 0.5, "seed \(seed), \(size): \(tree.name(of: label.node))")
                    #expect(overlay.pill.minX == box.minX)
                    // The text itself stays inside the pill's padding.
                    let text = overlay.name.width + (overlay.detail.map { $0.width + pad * 1.4 } ?? 0)
                    #expect(text <= box.width - 2 * pad + 0.5)
                }
            }
        }
        #expect(checked >= 27, "checked \(checked), with detail \(withDetail)")
        #expect(withDetail > 0)

        // Names far wider than the layout's estimate (wide glyphs, a box cut short by the
        // cell's edge): the name is truncated to the box, never the box widened to the name.
        guard var label = sample else { return }
        label.rect = TreemapRect(x: 10, y: 10, width: 150, height: 30)
        label.fontSize = 22
        label.fitsDetail = true
        let box = CGRect(x: 10, y: 10, width: 150, height: 30)
        for name in ["WWWWWWWWWWWWWWWWWWWWWWWW", "日本語のとても長いフォルダ名です", "Photos Library.photoslibrary", "ab"] {
            let overlay = LabelRenderer.overlayPill(
                name: name, sizeText: "123,4 GB", label: label, box: box, pad: 10, fonts: &fonts, textColor: white,
                detailColor: white)
            guard let overlay else { continue }
            #expect(overlay.pill.maxX <= box.maxX + 0.5, "\(name)")
            #expect(overlay.name.width <= box.width - 20 + 0.5)
            if name != "ab" { #expect(overlay.name.isTruncated && overlay.detail == nil) }
        }
        // Too narrow for any readable name: no pill at all.
        #expect(
            LabelRenderer.overlayPill(
                name: "Documents", sizeText: "1 GB", label: label, box: CGRect(x: 0, y: 0, width: 40, height: 30), pad: 10,
                fonts: &fonts, textColor: white, detailColor: white) == nil)
    }

    @Test func hiddenLabelsAreNotRendered() async {
        let tree = FileTree.synthetic(nodeCount: 20_000, seed: 7)
        let with = render(tree, key(labels: true))
        let without = render(tree, key(labels: false))
        #expect(with.labels != nil)
        #expect(without.labels == nil)
        #expect(without.labelPixels == nil)
        // The raster is the same picture either way.
        #expect(bytes(with.image) == bytes(without.image))
    }

    @Test func theLabelFlagDoesNotMakeADifferentPicture() async {
        let on = key(labels: true)
        let off = key(labels: false)
        #expect(on != off)  // so that turning labels on is not swallowed as "already submitted"
        #expect(on.sameContent(as: off))  // and presents without a transition
        var other = off
        other.colorMode = .age
        #expect(!on.sameContent(as: other))
    }

    @Test func turningLabelsOnInTheLiveViewRendersThem() async {
        let map = await MapFixture { $0.showsLabels = false }
        #expect(map.view.displayed?.labelPixels == nil)
        #expect(map.view.displayed?.key.labels == false)
        map.view.showsLabels = true
        #expect(await map.awaitNewFrame())
        #expect(map.view.displayed?.labelPixels != nil)
        // Turning them off again needs no render: the layer is hidden at once.
        let serial = map.view.displayed?.request.serial
        map.view.showsLabels = false
        await pump(for: 0.2)
        #expect(map.view.displayed?.request.serial == serial)
    }

    // MARK: Layer contents

    @Test func layerFramesAreSurfacesWithTheSamePixelsAsImages() async throws {
        let tree = FileTree.synthetic(nodeCount: 20_000, seed: 7)
        // An odd width: surface rows are padded, image rows are not.
        let k = key(size: CGSize(width: 801, height: 533), scale: 1)
        let image = render(tree, k, target: .image)
        let layer = render(tree, k, target: .layer)

        #expect(!image.pixels.isSurface)
        #expect(layer.pixels.isSurface)
        let surface = try #require(layer.pixels.layerContents as? IOSurface)
        #expect(surface.width == k.pixelWidth)
        #expect(surface.height == k.pixelHeight)
        // Tagged, so the window server colour-matches it instead of taking the bytes as display values.
        #expect(IOSurfaceCopyValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace) != nil)

        #expect(layer.image.width == image.image.width)
        #expect(layer.image.alphaInfo == .noneSkipFirst)
        #expect(bytes(layer.image) == bytes(image.image))

        let labelSurface = try #require(layer.labelPixels?.layerContents as? IOSurface)
        #expect(labelSurface.width == k.labelWidth)
        // Also proves the surface started out clear: it is transparent wherever nothing was
        // drawn, on first use and after earlier surfaces have been released.
        let expectedLabels = bytes(try #require(image.labels))
        #expect(bytes(try #require(layer.labels)) == expectedLabels)
        for _ in 0 ..< 3 {
            #expect(bytes(try #require(render(tree, k, target: .layer).labels)) == expectedLabels)
        }

        // What the drag image is cut from.
        let crop = try #require(layer.image.cropping(to: CGRect(x: 10, y: 20, width: 64, height: 48)))
        #expect(bytes(crop) == bytes(try #require(image.image.cropping(to: CGRect(x: 10, y: 20, width: 64, height: 48)))))
    }

    @Test func theLiveViewShowsSurfaces() async {
        let map = await MapFixture()
        #expect(map.view.displayed?.pixels.isSurface == true)
        #expect(map.view.displayed?.labelPixels?.isSurface == true)
    }

    // MARK: Measurements (DISKSURVEY_BENCH=1; printed, not asserted)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISKSURVEY_BENCH"] != nil))
    func benchmarkLabelPassAndCommit() async {
        let tree = FileTree.synthetic(nodeCount: 500_000, seed: 7)
        let size = CGSize(width: 1320, height: 840)

        // Variants are interleaved and the best of many runs is reported next to the median:
        // other work on the machine only ever adds time.
        func stats(_ times: [Double]) -> String {
            let sorted = times.sorted()
            return String(format: "%.2f ms (best %.2f)", sorted[sorted.count / 2] * 1000, sorted[0] * 1000)
        }
        for style in TreemapMapStyle.allCases {
            var on = key(size: size, labels: true)
            on.style = style
            var off = on
            off.labels = false
            _ = render(tree, on, target: .layer)
            var times: [[Double]] = [[], [], [], []]
            for _ in 0 ..< 25 {
                times[0].append(render(tree, on, target: .image).duration)
                times[1].append(render(tree, off, target: .image).duration)
                times[2].append(render(tree, on, target: .layer).duration)
                times[3].append(render(tree, off, target: .layer).duration)
            }
            print(
                "BENCH render \(style) 2640x1680, 500k nodes: images+labels \(stats(times[0])), images no labels \(stats(times[1])), "
                    + "surfaces+labels \(stats(times[2])), surfaces no labels \(stats(times[3]))")
        }

        // Memory held per retained frame (at 2x the label layer is as large as the raster here).
        func footprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return Double(info.phys_footprint) / 1_048_576
        }
        for target in [RenderTarget.image, .layer] {
            let before = footprint()
            var held: [RenderedFrame] = []
            for i in 0 ..< 4 {
                var k = key(size: size)
                k.relief = 1 + Float(i) * 0.01
                held.append(render(tree, k, target: target))
            }
            print(String(format: "BENCH footprint per retained frame (%@): %.1f MB", "\(target)", (footprint() - before) / 4))
            held.removeAll()
        }

        // Main-thread cost of committing a new picture to a window (never shown).
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: CGRect(origin: .zero, size: size))
        host.wantsLayer = true
        let root = CALayer()
        host.layer = root
        window.contentView = host
        CATransaction.flush()
        var seed = 0
        func commit(_ target: RenderTarget) -> Double {
            var k = key(size: size)
            seed += 1
            k.relief = 1 + Float(seed) * 0.01
            let frame = render(tree, k, target: target)
            let picture = CALayer()
            picture.frame = root.bounds
            picture.isOpaque = true
            picture.contents = frame.pixels.layerContents
            let labels = CALayer()
            labels.frame = root.bounds
            labels.contents = frame.labelPixels?.layerContents
            picture.addSublayer(labels)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.sublayers?.forEach { $0.removeFromSuperlayer() }
            root.addSublayer(picture)
            CATransaction.commit()
            let start = CACurrentMediaTime()
            CATransaction.flush()
            return CACurrentMediaTime() - start
        }
        var images: [Double] = []
        var surfaces: [Double] = []
        for _ in 0 ..< 15 {
            images.append(commit(.image))
            surfaces.append(commit(.layer))
        }
        print(
            "BENCH commit on the main thread (picture + labels, window colour space \(window.colorSpace?.localizedName ?? "?")): "
                + "CGImage \(stats(images)), IOSurface \(stats(surfaces))")
    }
}
}
