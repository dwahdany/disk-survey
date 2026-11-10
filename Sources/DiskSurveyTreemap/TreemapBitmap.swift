import Foundation

/// A 32-bit pixel buffer the rasterizer draws into.
///
/// **Pixel format:** one `UInt32` per pixel with value `0xAARRGGBB`, i.e. the bytes in memory
/// are B, G, R, A (little-endian). Alpha is always 255 after rendering, so the data is valid
/// both as premultiplied and as alpha-skipped. To wrap it in a `CGImage` / `CGBitmapContext`
/// without conversion use
///
///     bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.bytesPerRow,
///     space: CGColorSpace(name: CGColorSpace.sRGB)!,
///     bitmapInfo: CGBitmapInfo(rawValue: TreemapBitmap.cgBitmapInfo)
///     // == CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
///
/// which is the native layout of macOS window backing stores. Colour values are sRGB encoded.
/// Row 0 is the TOP row.
///
/// The class owns its memory (page-aligned, not zero-filled until first use) and is reusable
/// across frames. It is `Sendable` so a render task can hand it to the main thread; it is not
/// synchronised — do not read it while a render into it is in progress.
public final class TreemapBitmap: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// Always `width * 4`: rows are not padded.
    public let bytesPerRow: Int
    /// `width * height` pixels, row-major from the top row.
    public let pixels: UnsafeMutablePointer<UInt32>

    /// Raw value for `CGBitmapInfo`: `premultipliedFirst | byteOrder32Little` (BGRA in memory).
    public static let cgBitmapInfo: UInt32 = 2 | (2 << 12)

    /// Allocates a bitmap. With `cleared == false` the contents are undefined until rendered into.
    public init(width: Int, height: Int, cleared: Bool = true) {
        precondition(width >= 0 && height >= 0, "bitmap dimensions must not be negative")
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        let count = max(1, width * height)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: count * 4, alignment: 16384)
        pixels = raw.bindMemory(to: UInt32.self, capacity: count)
        if cleared { pixels.update(repeating: 0, count: count) }
    }

    deinit { UnsafeMutableRawPointer(pixels).deallocate() }

    public var pixelCount: Int { width * height }
    public var byteCount: Int { width * height * 4 }

    /// The raw bytes (B, G, R, A per pixel). Valid for the lifetime of the bitmap.
    public var bytes: UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(pixels), count: byteCount)
    }

    /// A copy of the pixel bytes.
    public var data: Data { Data(bytes: UnsafeRawPointer(pixels), count: byteCount) }

    /// The pixel bytes without copying. The returned `Data` keeps the bitmap alive; drawing into
    /// the bitmap afterwards changes what the `Data` (and any `CGImage` made from it) shows.
    public var unsafeData: Data {
        let retained = Unmanaged.passRetained(self)
        return Data(
            bytesNoCopy: UnsafeMutableRawPointer(pixels), count: byteCount,
            deallocator: .custom { _, _ in retained.release() })
    }

    /// Sets every pixel to one colour (sRGB bytes).
    public func fill(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        pixels.update(repeating: Self.pack(r: r, g: g, b: b, a: a), count: pixelCount)
    }

    static func pack(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> UInt32 {
        UInt32(a) << 24 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }

    /// The raw `0xAARRGGBB` value at a pixel.
    @inlinable public subscript(x: Int, y: Int) -> UInt32 {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel out of range")
        return pixels[y * width + x]
    }

    /// The sRGB components at a pixel.
    public func color(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let p = self[x, y]
        return (UInt8(truncatingIfNeeded: p >> 16), UInt8(truncatingIfNeeded: p >> 8), UInt8(truncatingIfNeeded: p), UInt8(truncatingIfNeeded: p >> 24))
    }

    // MARK: Dumps (no image framework needed)

    /// The image as a binary PPM (P6, RGB). Convert with e.g. `sips -s format png in.ppm --out out.png`
    /// if your tools read PPM; otherwise use ``bmpData()``.
    public func ppmData() -> Data {
        var out = Data("P6\n\(width) \(height)\n255\n".utf8)
        var rgb = [UInt8](repeating: 0, count: pixelCount * 3)
        for i in 0 ..< pixelCount {
            let p = pixels[i]
            rgb[i * 3] = UInt8(truncatingIfNeeded: p >> 16)
            rgb[i * 3 + 1] = UInt8(truncatingIfNeeded: p >> 8)
            rgb[i * 3 + 2] = UInt8(truncatingIfNeeded: p)
        }
        out.append(contentsOf: rgb)
        return out
    }

    /// The image as an uncompressed 24-bit Windows BMP, readable by `sips`, Preview and Quick Look.
    public func bmpData() -> Data {
        let rowBytes = (width * 3 + 3) & ~3
        let imageBytes = rowBytes * height
        var out = [UInt8](repeating: 0, count: 54 + imageBytes)
        func put32(_ value: Int, at offset: Int) {
            for k in 0 ..< 4 { out[offset + k] = UInt8(truncatingIfNeeded: value >> (8 * k)) }
        }
        out[0] = 0x42
        out[1] = 0x4D
        put32(54 + imageBytes, at: 2)
        put32(54, at: 10)
        put32(40, at: 14)
        put32(width, at: 18)
        put32(height, at: 22)  // positive height: rows are stored bottom-up
        out[26] = 1
        out[28] = 24
        put32(imageBytes, at: 34)
        put32(2835, at: 38)
        put32(2835, at: 42)
        for y in 0 ..< height {
            var o = 54 + (height - 1 - y) * rowBytes
            let row = pixels + y * width
            for x in 0 ..< width {
                let p = row[x]
                out[o] = UInt8(truncatingIfNeeded: p)
                out[o + 1] = UInt8(truncatingIfNeeded: p >> 8)
                out[o + 2] = UInt8(truncatingIfNeeded: p >> 16)
                o += 3
            }
        }
        return Data(out)
    }

    public func writePPM(to url: URL) throws { try ppmData().write(to: url) }
    public func writeBMP(to url: URL) throws { try bmpData().write(to: url) }
}
