#!/usr/bin/env swift
// Generates Disk Survey's app icon procedurally — no artwork files, no Xcode.
//
//   swift Scripts/make-icon.swift            # writes Resources/AppIcon.icns + Resources/AppIcon-1024.png
//   swift Scripts/make-icon.swift --png DIR  # additionally keeps every iconset PNG in DIR (for inspection)
//
// Concept: a dark glass tile holding a small treemap of cushion-shaded tiles. Everything is drawn
// on a 1024-unit design grid and rasterised separately for each iconset size, so small sizes are
// rendered crisply (with a simplified mosaic) instead of being downsampled from the large one.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Small helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

struct RGB {
    var r, g, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
    func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(colorSpace: sRGB, components: [r, g, b, alpha])! }
    /// Mixes towards white (t > 0) or black (t < 0).
    func shaded(_ t: CGFloat) -> RGB {
        let target: CGFloat = t >= 0 ? 1 : 0
        let k = abs(t)
        return RGB(r: r + (target - r) * k, g: g + (target - g) * k, b: b + (target - b) * k)
    }
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

/// Superellipse outline — a close match for the continuous-corner "squircle" of macOS app icons.
func squirclePath(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

// MARK: - The mosaic

/// One tile in unit coordinates (origin top-left of the mosaic area).
struct Tile {
    var x0, y0, x1, y1: CGFloat
    var color: RGB
}

// Jewel palette: cool hues carry the composition, two warm accents give it life.
let teal = RGB(0x12C4BC), blue = RGB(0x2F7DFF), indigo = RGB(0x5F55F5), violet = RGB(0xA24DF2)
let pink = RGB(0xF2468E), coral = RGB(0xFF6A45), amber = RGB(0xFFB321), green = RGB(0x25CC78)

/// Hand-composed treemap (a real slice-and-dice hierarchy, not random boxes) for sizes ≥ 64 px.
let detailedTiles: [Tile] = [
    // left column: one dominant "folder" and two children below it
    Tile(x0: 0.00, y0: 0.00, x1: 0.46, y1: 0.60, color: blue),
    Tile(x0: 0.00, y0: 0.60, x1: 0.27, y1: 1.00, color: indigo),
    Tile(x0: 0.27, y0: 0.60, x1: 0.46, y1: 0.82, color: violet),
    Tile(x0: 0.27, y0: 0.82, x1: 0.46, y1: 1.00, color: pink),
    // right column, top band
    Tile(x0: 0.46, y0: 0.00, x1: 0.80, y1: 0.36, color: teal),
    Tile(x0: 0.80, y0: 0.00, x1: 1.00, y1: 0.20, color: green),
    Tile(x0: 0.80, y0: 0.20, x1: 1.00, y1: 0.36, color: amber),
    // right column, middle band
    Tile(x0: 0.46, y0: 0.36, x1: 0.70, y1: 0.70, color: amber),
    Tile(x0: 0.70, y0: 0.36, x1: 1.00, y1: 0.56, color: coral),
    Tile(x0: 0.70, y0: 0.56, x1: 0.86, y1: 0.70, color: pink),
    Tile(x0: 0.86, y0: 0.56, x1: 1.00, y1: 0.70, color: violet),
    // right column, bottom band
    Tile(x0: 0.46, y0: 0.70, x1: 0.74, y1: 1.00, color: green),
    Tile(x0: 0.74, y0: 0.70, x1: 1.00, y1: 0.86, color: blue),
    Tile(x0: 0.74, y0: 0.86, x1: 0.88, y1: 1.00, color: teal),
    Tile(x0: 0.88, y0: 0.86, x1: 1.00, y1: 1.00, color: indigo),
]

/// Same composition reduced to its big shapes, so the icon still reads as a mosaic at 16–32 px.
let simpleTiles: [Tile] = [
    Tile(x0: 0.00, y0: 0.00, x1: 0.48, y1: 0.60, color: blue),
    Tile(x0: 0.00, y0: 0.60, x1: 0.48, y1: 1.00, color: indigo),
    Tile(x0: 0.48, y0: 0.00, x1: 1.00, y1: 0.38, color: teal),
    Tile(x0: 0.48, y0: 0.38, x1: 0.74, y1: 1.00, color: amber),
    Tile(x0: 0.74, y0: 0.38, x1: 1.00, y1: 0.70, color: coral),
    Tile(x0: 0.74, y0: 0.70, x1: 1.00, y1: 1.00, color: green),
]

// MARK: - Drawing (design grid: 1024 × 1024, y pointing down)

func drawIcon(in ctx: CGContext, pixels: Int) {
    let small = pixels <= 32
    // Apple's icon grid: an 824-unit tile centred in the 1024 canvas, leaving room for the shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squirclePath(in: tile)

    // Soft contact shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: RGB(0x05060F).cg(0.42))
    ctx.addPath(tilePath)
    ctx.setFillColor(RGB(0x12152B).cg())
    ctx.fillPath()
    ctx.restoreGState()

    // Tile body: deep blue-black, lit from above.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, RGB(0x2B3156).cg()), (0.55, RGB(0x161A33).cg()), (1, RGB(0x0A0C1C).cg())]),
        start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
    // A faint coloured glow behind the mosaic keeps the dark body from looking flat.
    ctx.drawRadialGradient(
        gradient([(0, RGB(0x4A6CFF).cg(0.30)), (1, RGB(0x4A6CFF).cg(0))]),
        startCenter: CGPoint(x: 400, y: 380), startRadius: 0,
        endCenter: CGPoint(x: 400, y: 380), endRadius: 560, options: [])

    // Glass: a broad sheen across the upper half, drawn under the mosaic so the tiles keep their full colour.
    let sheen = CGMutablePath()
    sheen.addEllipse(in: CGRect(x: tile.minX - 260, y: tile.minY - 560, width: tile.width + 520, height: 980))
    ctx.saveGState()
    ctx.addPath(sheen)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, CGColor(gray: 1, alpha: 0.20)), (1, CGColor(gray: 1, alpha: 0.03))]),
        start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.minY + 430), options: [])
    ctx.restoreGState()

    // The mosaic.
    let inset: CGFloat = small ? 96 : 104
    let area = tile.insetBy(dx: inset, dy: inset)
    let gap: CGFloat = small ? 34 : 17
    let tiles = small ? simpleTiles : detailedTiles
    for t in tiles {
        let rect = CGRect(
            x: area.minX + t.x0 * area.width, y: area.minY + t.y0 * area.height,
            width: (t.x1 - t.x0) * area.width, height: (t.y1 - t.y0) * area.height
        ).insetBy(dx: gap / 2, dy: gap / 2)
        drawTile(ctx, rect: rect, color: t.color, small: small)
    }

    ctx.restoreGState()

    // Rim light: bright along the top edge, fading to almost nothing at the bottom.
    let rimWidth: CGFloat = small ? 20 : 7
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.addPath(squirclePath(in: tile.insetBy(dx: rimWidth / 2, dy: rimWidth / 2)))
    ctx.setLineWidth(rimWidth)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, CGColor(gray: 1, alpha: 0.55)), (0.35, CGColor(gray: 1, alpha: 0.14)),
                  (1, CGColor(gray: 1, alpha: 0.07))]),
        start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
    ctx.restoreGState()
}

/// One cushion-shaded tile: the same "pillow" lighting the app's treemap uses — a highlight
/// towards the upper left falling off to a darker rim — plus a thin bevel so it sits in the tile.
func drawTile(_ ctx: CGContext, rect: CGRect, color: RGB, small: Bool) {
    let radius = min(min(rect.width, rect.height) * 0.26, small ? 60 : 44)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow so the tiles float slightly above the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: small ? 10 : 7), blur: small ? 16 : 14,
                  color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(path)
    ctx.setFillColor(color.cg())
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    // Base: lighter at the top, deeper at the bottom.
    ctx.drawLinearGradient(
        gradient([(0, color.shaded(0.10).cg()), (1, color.shaded(-0.22).cg())]),
        start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    // Cushion: highlight at the upper left, shading towards the far corner.
    let light = CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.24)
    let reach = hypot(rect.width, rect.height) * 0.92
    ctx.drawRadialGradient(
        gradient([(0, CGColor(gray: 1, alpha: 0.34)), (0.6, CGColor(gray: 1, alpha: 0))]),
        startCenter: light, startRadius: 0, endCenter: light, endRadius: reach, options: [])
    ctx.drawRadialGradient(
        gradient([(0.35, CGColor(gray: 0, alpha: 0)), (1, CGColor(gray: 0, alpha: 0.30))]),
        startCenter: light, startRadius: 0, endCenter: light, endRadius: reach,
        options: [.drawsAfterEndLocation])
    // Bevel: light upper edge, dark lower edge.
    let bevel: CGFloat = small ? 12 : 5
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: bevel / 2, dy: bevel / 2),
                       cornerWidth: max(radius - bevel / 2, 0), cornerHeight: max(radius - bevel / 2, 0),
                       transform: nil))
    ctx.setLineWidth(bevel)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, CGColor(gray: 1, alpha: 0.50)), (0.5, CGColor(gray: 1, alpha: 0.05)),
                  (1, CGColor(gray: 0, alpha: 0.22))]),
        start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    ctx.restoreGState()
}

// MARK: - Rasterising and packaging

func renderPNG(pixels: Int, to url: URL) throws {
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    // Map the 1024-unit, y-down design grid onto the bitmap.
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    drawIcon(in: ctx, pixels: pixels)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath))
let root = scriptURL.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")

var keepDir: URL?
if let i = CommandLine.arguments.firstIndex(of: "--png"), i + 1 < CommandLine.arguments.count {
    keepDir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
}

do {
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    let work = fm.temporaryDirectory.appendingPathComponent("disksurvey-icon-\(ProcessInfo.processInfo.processIdentifier)")
    let iconset = work.appendingPathComponent("AppIcon.iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    // (points, scale) pairs required by iconutil.
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try renderPNG(pixels: points * scale, to: iconset.appendingPathComponent(name))
        }
    }

    let icns = resources.appendingPathComponent("AppIcon.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", "--output", icns.path, iconset.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("make-icon: iconutil failed\n".utf8))
        exit(1)
    }

    let preview = resources.appendingPathComponent("AppIcon-1024.png")
    try? fm.removeItem(at: preview)
    try fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: preview)

    if let keepDir {
        try fm.createDirectory(at: keepDir, withIntermediateDirectories: true)
        for file in try fm.contentsOfDirectory(at: iconset, includingPropertiesForKeys: nil) {
            let dst = keepDir.appendingPathComponent(file.lastPathComponent)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: file, to: dst)
        }
    }
    print("make-icon: wrote \(icns.path)")
    print("make-icon: wrote \(preview.path)")
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
