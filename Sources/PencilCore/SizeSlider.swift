import CoreGraphics

/// The horizontal stroke-size slider's track: maps the 7 size levels to evenly spaced
/// x positions (level 1 at `minX`, level 7 at `maxX`) and back, snapping to the nearest
/// level and clamping anything past either end.
public struct SizeTrack: Equatable, Sendable {
    public var minX: CGFloat
    public var maxX: CGFloat

    public init(minX: CGFloat, maxX: CGFloat) {
        self.minX = minX
        self.maxX = max(minX, maxX)
    }

    public var length: CGFloat { maxX - minX }

    /// Distance between two neighbouring levels.
    public var step: CGFloat {
        length / CGFloat(StrokeSize.levels.upperBound - StrokeSize.levels.lowerBound)
    }

    /// The x of a level's tick (the level is clamped to 1...7 first).
    public func x(for level: Int) -> CGFloat {
        minX + CGFloat(StrokeSize.clamp(level) - StrokeSize.levels.lowerBound) * step
    }

    /// 0 at `minX`, 1 at `maxX`, clamped.
    public func fraction(at x: CGFloat) -> CGFloat {
        guard length > 0 else { return 0 }
        return min(max((x - minX) / length, 0), 1)
    }

    /// The level nearest to `x` (snapped), clamped to 1...7 beyond the track's ends.
    public func level(at x: CGFloat) -> Int {
        let span = CGFloat(StrokeSize.levels.upperBound - StrokeSize.levels.lowerBound)
        let raw = (fraction(at: x) * span).rounded(.toNearestOrAwayFromZero)
        return StrokeSize.clamp(StrokeSize.levels.lowerBound + Int(raw))
    }

    /// The wedge's thickness at `x`: `thin` at the left end growing linearly to `thick`
    /// at the right end, clamped past the ends.
    public func wedgeThickness(at x: CGFloat, thin: CGFloat, thick: CGFloat) -> CGFloat {
        thin + (thick - thin) * fraction(at: x)
    }
}
