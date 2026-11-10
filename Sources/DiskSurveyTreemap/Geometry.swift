import Foundation
import DiskSurveyCore

// Coordinate convention for the whole module: pixels, origin at the TOP-LEFT, x to the right,
// y DOWN. Row 0 of a ``TreemapBitmap`` is the top row. A view with a bottom-left origin flips.

/// A point in layout (pixel) coordinates.
public struct TreemapPoint: Sendable, Hashable {
    public var x: Float
    public var y: Float

    @inlinable public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    @_disfavoredOverload @inlinable public init(x: Double, y: Double) {
        self.x = Float(x)
        self.y = Float(y)
    }
}

/// An axis-aligned rectangle stored as its four edges.
///
/// Edges rather than origin + size because neighbouring treemap cells must share an edge
/// *bit for bit*: the rasterizer rounds edges to pixels, and identical floats round identically,
/// so the cells of a layout tile the bitmap with neither gaps nor overlaps.
public struct TreemapRect: Sendable, Hashable {
    public var minX: Float
    public var minY: Float
    public var maxX: Float
    public var maxY: Float

    @inlinable public init(minX: Float, minY: Float, maxX: Float, maxY: Float) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    @inlinable public init(x: Float, y: Float, width: Float, height: Float) {
        self.init(minX: x, minY: y, maxX: x + width, maxY: y + height)
    }

    @_disfavoredOverload @inlinable public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(x: Float(x), y: Float(y), width: Float(width), height: Float(height))
    }

    public static let zero = TreemapRect(minX: 0, minY: 0, maxX: 0, maxY: 0)

    @inlinable public var x: Float { minX }
    @inlinable public var y: Float { minY }
    @inlinable public var width: Float { maxX - minX }
    @inlinable public var height: Float { maxY - minY }
    @inlinable public var midX: Float { (minX + maxX) * 0.5 }
    @inlinable public var midY: Float { (minY + maxY) * 0.5 }
    @inlinable public var area: Float { max(0, maxX - minX) * max(0, maxY - minY) }
    @inlinable public var isEmpty: Bool { maxX <= minX || maxY <= minY }

    /// Half-open containment (`min` inclusive, `max` exclusive), so a point on a shared edge
    /// belongs to exactly one of two neighbouring cells.
    @inlinable public func contains(_ p: TreemapPoint) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    /// The pixel boundary an edge at `v` is drawn on: the nearest one, halves rounding up.
    ///
    /// This is the single rounding rule of the module. The rasterizer paints a cell over the
    /// pixels between its rounded edges and hit-testing asks the same question of the same
    /// numbers, so what is under the pointer is what was painted there.
    @inlinable public static func pixelEdge(_ v: Float) -> Float { (v + 0.5).rounded(.down) }

    /// The rectangle with every edge moved to its pixel boundary: the pixels the rasterizer
    /// gives this rectangle. Empty if the rectangle is narrower than half a pixel either way.
    @inlinable public var pixelAligned: TreemapRect {
        TreemapRect(
            minX: Self.pixelEdge(minX), minY: Self.pixelEdge(minY), maxX: Self.pixelEdge(maxX), maxY: Self.pixelEdge(maxY))
    }

    /// Whether the rasterizer gives the pixel in column `px`, row `py` (whole numbers) to this
    /// rectangle.
    @inlinable public func containsPixel(_ px: Float, _ py: Float) -> Bool {
        px >= Self.pixelEdge(minX) && px < Self.pixelEdge(maxX) && py >= Self.pixelEdge(minY) && py < Self.pixelEdge(maxY)
    }

    /// Whether `other` lies inside this rectangle (edges may touch), with `tolerance` of slack.
    @inlinable public func contains(_ other: TreemapRect, tolerance: Float = 0) -> Bool {
        other.minX >= minX - tolerance && other.maxX <= maxX + tolerance
            && other.minY >= minY - tolerance && other.maxY <= maxY + tolerance
    }

    /// Whether the interiors overlap (touching edges do not count).
    @inlinable public func intersects(_ other: TreemapRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    /// The common part; empty (possibly with negative extent clamped to zero) if disjoint.
    @inlinable public func intersection(_ other: TreemapRect) -> TreemapRect {
        let x0 = max(minX, other.minX)
        let y0 = max(minY, other.minY)
        return TreemapRect(minX: x0, minY: y0, maxX: max(x0, min(maxX, other.maxX)), maxY: max(y0, min(maxY, other.maxY)))
    }

    /// Shrinks the rectangle by `d` on every side (never past its centre).
    @inlinable public func insetBy(_ d: Float) -> TreemapRect {
        let dx = min(d, width * 0.5)
        let dy = min(d, height * 0.5)
        return TreemapRect(minX: minX + dx, minY: minY + dy, maxX: maxX - dx, maxY: maxY - dy)
    }

    /// Linear interpolation of all four edges towards `other`.
    @inlinable public func interpolated(to other: TreemapRect, _ t: Float) -> TreemapRect {
        TreemapRect(
            minX: minX + (other.minX - minX) * t, minY: minY + (other.minY - minY) * t,
            maxX: maxX + (other.maxX - maxX) * t, maxY: maxY + (other.maxY - maxY) * t)
    }
}

/// A scale-and-translate mapping between two layouts' coordinate spaces, used for the animated
/// zoom: `x' = x * scaleX + translateX`, `y' = y * scaleY + translateY`.
public struct TreemapTransform: Sendable, Hashable {
    public var scaleX: Float
    public var scaleY: Float
    public var translateX: Float
    public var translateY: Float

    public static let identity = TreemapTransform(scaleX: 1, scaleY: 1, translateX: 0, translateY: 0)

    @inlinable public init(scaleX: Float, scaleY: Float, translateX: Float, translateY: Float) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.translateX = translateX
        self.translateY = translateY
    }

    /// The transform that carries the rectangle `source` exactly onto `destination`.
    /// A degenerate source (zero width or height) maps with scale 1 on that axis.
    public init(mapping source: TreemapRect, onto destination: TreemapRect) {
        let sx = source.width > 0 ? destination.width / source.width : 1
        let sy = source.height > 0 ? destination.height / source.height : 1
        self.init(
            scaleX: sx, scaleY: sy,
            translateX: destination.minX - source.minX * sx,
            translateY: destination.minY - source.minY * sy)
    }

    @inlinable public var isIdentity: Bool { self == .identity }

    @inlinable public func apply(_ p: TreemapPoint) -> TreemapPoint {
        TreemapPoint(x: p.x * scaleX + translateX, y: p.y * scaleY + translateY)
    }

    @inlinable public func apply(_ r: TreemapRect) -> TreemapRect {
        TreemapRect(
            minX: r.minX * scaleX + translateX, minY: r.minY * scaleY + translateY,
            maxX: r.maxX * scaleX + translateX, maxY: r.maxY * scaleY + translateY)
    }

    /// The reverse mapping. Scales of zero invert to identity scale.
    public var inverse: TreemapTransform {
        let sx = scaleX != 0 ? 1 / scaleX : 1
        let sy = scaleY != 0 ? 1 / scaleY : 1
        return TreemapTransform(scaleX: sx, scaleY: sy, translateX: -translateX * sx, translateY: -translateY * sy)
    }

    /// The transform part-way from identity (`t == 0`) to `self` (`t == 1`).
    ///
    /// Scale is interpolated geometrically, which makes a zoom feel uniform in speed, and the
    /// translation is chosen so the fixed point of the full transform stays fixed throughout.
    public func interpolated(_ t: Float) -> TreemapTransform {
        func axis(_ scale: Float, _ translate: Float) -> (Float, Float) {
            guard scale > 0, abs(scale - 1) > 1e-6 else { return (1 + (scale - 1) * t, translate * t) }
            let s = Float(pow(Double(scale), Double(t)))
            // translate / (1 - scale) is the fixed point of x -> x * scale + translate.
            return (s, translate / (1 - scale) * (1 - s))
        }
        let (sx, tx) = axis(scaleX, translateX)
        let (sy, ty) = axis(scaleY, translateY)
        return TreemapTransform(scaleX: sx, scaleY: sy, translateX: tx, translateY: ty)
    }
}
