import CoreGraphics

/// One piece of a smoothed stroke. `control == nil` means a straight line.
/// `pointIndex` is the input point this piece belongs to (used for laser fade).
public struct PathSegment: Equatable, Sendable {
    public var start: CGPoint
    public var control: CGPoint?
    public var end: CGPoint
    public var pointIndex: Int
}

@inline(__always)
func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}

/// Smooths a polyline by running quadratic curves through the midpoints of
/// consecutive points, using each point as the control point.
public func smoothSegments(_ points: [CGPoint]) -> [PathSegment] {
    switch points.count {
    case 0:
        return []
    case 1:
        return [PathSegment(start: points[0], control: nil, end: points[0], pointIndex: 0)]
    case 2:
        return [PathSegment(start: points[0], control: nil, end: points[1], pointIndex: 0)]
    default:
        var segs: [PathSegment] = []
        segs.reserveCapacity(points.count)
        segs.append(PathSegment(start: points[0], control: nil,
                                end: midpoint(points[0], points[1]), pointIndex: 0))
        for i in 1..<(points.count - 1) {
            segs.append(PathSegment(start: midpoint(points[i - 1], points[i]),
                                    control: points[i],
                                    end: midpoint(points[i], points[i + 1]),
                                    pointIndex: i))
        }
        let n = points.count - 1
        segs.append(PathSegment(start: midpoint(points[n - 1], points[n]), control: nil,
                                end: points[n], pointIndex: n))
        return segs
    }
}

/// A single continuous smoothed path through the points.
public func smoothPath(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    let segs = smoothSegments(points)
    guard let first = segs.first else { return path }
    path.move(to: first.start)
    for s in segs {
        if let c = s.control {
            path.addQuadCurve(to: s.end, control: c)
        } else {
            path.addLine(to: s.end)
        }
    }
    return path
}

/// Geometry for the edge dock: keeps a vertically-dragged panel inside a frame.
public enum DockGeometry {
    /// Clamps the panel's bottom Y so a panel of `height` stays inside `visible`.
    public static func clampY(_ y: CGFloat, height: CGFloat, in visible: CGRect) -> CGFloat {
        let lo = visible.minY
        let hi = max(lo, visible.maxY - height)
        return min(max(y, lo), hi)
    }

    public enum GrowDirection: Equatable, Sendable {
        /// Handle at the top, toolbar extends downward.
        case down
        /// Handle at the bottom, toolbar extends upward.
        case up
    }

    /// Frame for an expanded toolbar whose handle stays where the collapsed tab was.
    ///
    /// - `anchorY`: the tab's vertical center; the handle's center lands here.
    /// - `handleOffset`: distance from the toolbar's handle end to the handle's center.
    ///
    /// Tries `preferred`, then the other direction. Only if neither fits inside
    /// `visible` is the frame shifted, by as little as possible. The result always
    /// lies inside `visible` when it is tall enough to hold it.
    public static func anchoredFrame(anchorY: CGFloat, handleOffset: CGFloat, x: CGFloat,
                                     width: CGFloat, height: CGFloat, in visible: CGRect,
                                     preferring preferred: GrowDirection = .down)
        -> (frame: CGRect, direction: GrowDirection) {
        func frame(_ d: GrowDirection) -> CGRect {
            let y = d == .down ? anchorY + handleOffset - height : anchorY - handleOffset
            return CGRect(x: x, y: y, width: width, height: height)
        }
        func overflow(_ r: CGRect) -> CGFloat {
            max(0, visible.minY - r.minY) + max(0, r.maxY - visible.maxY)
        }
        let other: GrowDirection = preferred == .down ? .up : .down
        for d in [preferred, other] where overflow(frame(d)) < 0.5 {
            return (frame(d), d)
        }
        if height >= visible.height {
            // Taller than the screen: keep the handle end on screen.
            let y = preferred == .down ? visible.maxY - height : visible.minY
            return (CGRect(x: x, y: y, width: width, height: height), preferred)
        }
        // Neither fits: take the direction that needs the smaller shift, then shift it in.
        let d = overflow(frame(preferred)) <= overflow(frame(other)) ? preferred : other
        var r = frame(d)
        r.origin.y = clampY(r.minY, height: height, in: visible)
        return (r, d)
    }

    /// True once a press has moved far enough to count as a drag.
    public static func isDrag(from a: CGPoint, to b: CGPoint, threshold: CGFloat = 4) -> Bool {
        let dx = b.x - a.x, dy = b.y - a.y
        return dx * dx + dy * dy >= threshold * threshold
    }
}
