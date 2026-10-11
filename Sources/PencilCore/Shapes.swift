import CoreGraphics
import Foundation

/// The outlines of the shape tools, as polylines in global screen points. Shapes are
/// ordinary strokes made of these points, so undo, the erasers and capture all treat
/// them like pen ink; the renderer draws them with straight segments.
public enum ShapeGeometry {
    /// Segments in a full ellipse. Enough to look round at any size on screen.
    static let ellipseSegments = 72
    /// Angle between an arrowhead's wings and its shaft.
    static let arrowWingAngle: CGFloat = .pi / 7

    /// A drag shorter than this is a click: no shape.
    public static func isTooSmall(from a: CGPoint, to b: CGPoint) -> Bool {
        abs(b.x - a.x) < 3 && abs(b.y - a.y) < 3
    }

    /// Where the drag effectively ends with Shift held: lines and arrows snap to the
    /// nearest 45°, rectangles and ellipses become squares and circles.
    public static func constrainedEnd(_ tool: Tool, from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        switch tool {
        case .line, .arrow:
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return b }
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
        case .rectangle, .ellipse:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
        default:
            return b
        }
    }

    /// The polyline for `tool` dragged from `a` to `b`.
    public static func points(_ tool: Tool, from a: CGPoint, to b: CGPoint,
                              constrain: Bool, lineWidth: CGFloat) -> [CGPoint] {
        let b = constrain ? constrainedEnd(tool, from: a, to: b) : b
        switch tool {
        case .line:
            return [a, b]
        case .arrow:
            return arrow(from: a, to: b, lineWidth: lineWidth)
        case .rectangle:
            return [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y), a]
        case .ellipse:
            return ellipse(in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        default:
            return [a, b]
        }
    }

    /// Shaft from `a` to the tip at `b`, then both wings, drawn as one path:
    /// tail → tip → wing → tip → wing.
    static func arrow(from a: CGPoint, to b: CGPoint, lineWidth: CGFloat) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length >= 1 else { return [a, b] }
        // Scales with the stroke so thick arrows keep a visible head, but never longer
        // than about half the shaft.
        let head = min(max(12, lineWidth * 3.5), length * 0.5)
        let back = atan2(-dy, -dx)
        func wing(_ turn: CGFloat) -> CGPoint {
            CGPoint(x: b.x + cos(back + turn) * head, y: b.y + sin(back + turn) * head)
        }
        return [a, b, wing(arrowWingAngle), b, wing(-arrowWingAngle)]
    }

    /// A closed polyline around the ellipse inscribed in `rect`.
    static func ellipse(in rect: CGRect) -> [CGPoint] {
        let rx = rect.width / 2, ry = rect.height / 2
        let n = ellipseSegments
        return (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n) * 2 * .pi
            return CGPoint(x: rect.midX + cos(t) * rx, y: rect.midY + sin(t) * ry)
        }
    }
}
