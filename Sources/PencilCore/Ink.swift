import CoreGraphics
import Foundation

/// A drawing tool. Pen and highlighter ink persists; laser ink fades.
public enum Tool: String, CaseIterable, Sendable {
    case pen, highlighter, laser

    public var isPersistent: Bool { self != .laser }

    /// Width at the default size level (3). The stroke size scales it.
    public var baseLineWidth: CGFloat {
        switch self {
        case .pen: return 4
        case .highlighter: return 18
        case .laser: return 3
        }
    }

    public var opacity: CGFloat {
        switch self {
        case .pen: return 1
        case .highlighter: return 0.35
        case .laser: return 0.9
        }
    }

    /// Width at a stroke size level (1...7).
    public func lineWidth(level: Int) -> CGFloat {
        baseLineWidth * StrokeSize.multiplier(level)
    }

    /// Extra margin around a stroke of `width` that its rendering can touch
    /// (half the line width, plus the laser glow).
    public func renderPadding(width: CGFloat) -> CGFloat {
        switch self {
        case .laser: return max(12, width * 1.75 + 2) // the glow is 3.5× wide
        default: return width / 2 + 2
        }
    }

    public var displayName: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .laser: return "Laser"
        }
    }
}

/// One stroke size shared by every tool: a level from 1 to 7 that scales each tool's
/// base width, so the highlighter stays proportionally thicker than the pen.
public enum StrokeSize {
    public static let levels: ClosedRange<Int> = 1...7
    public static let defaultLevel = 3
    /// Width multiplier per level (index 0 = level 1). Level 3 is today's widths.
    public static let multipliers: [CGFloat] = [0.5, 0.7, 1.0, 1.4, 1.9, 2.6, 3.4]

    public static func clamp(_ level: Int) -> Int { min(max(level, levels.lowerBound), levels.upperBound) }

    public static func multiplier(_ level: Int) -> CGFloat { multipliers[clamp(level) - 1] }
}

/// The current stroke size level, persisted in UserDefaults.
public final class StrokeSizeSetting {
    public static let defaultsKey = "ink.sizeLevel"

    private let defaults: UserDefaults
    public private(set) var level: Int

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.defaultsKey) as? Int
        level = StrokeSize.clamp(stored ?? StrokeSize.defaultLevel)
    }

    /// Sets the level (clamped). Returns true if it changed.
    @discardableResult
    public func set(_ newLevel: Int) -> Bool {
        let clamped = StrokeSize.clamp(newLevel)
        guard clamped != level else { return false }
        level = clamped
        defaults.set(clamped, forKey: Self.defaultsKey)
        return true
    }

    /// Steps the level by `delta` (clamped). Returns true if it changed.
    @discardableResult
    public func step(by delta: Int) -> Bool { set(level + delta) }

    public func width(for tool: Tool) -> CGFloat { tool.lineWidth(level: level) }
}

/// The app's overall mode.
public enum Mode: Equatable, Sendable {
    /// Overlay hidden, clicks pass through, ink hidden but kept.
    case off
    /// Ink visible, clicks pass through to apps underneath.
    case passThrough
    /// Overlay captures the mouse and draws with the tool.
    case draw(Tool)

    public var tool: Tool? {
        if case .draw(let t) = self { return t }
        return nil
    }

    public var isDrawing: Bool { tool != nil }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .passThrough: return "Pass-through (ink visible)"
        case .draw(let t): return t.displayName
        }
    }
}

public struct InkColor: Equatable, Sendable {
    public let name: String
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat

    public init(name: String, red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let red = InkColor(name: "Red", red: 1.0, green: 0.23, blue: 0.19)
    public static let yellow = InkColor(name: "Yellow", red: 1.0, green: 0.84, blue: 0.04)
    public static let green = InkColor(name: "Green", red: 0.20, green: 0.80, blue: 0.35)
    public static let blue = InkColor(name: "Blue", red: 0.04, green: 0.52, blue: 1.0)
    public static let white = InkColor(name: "White", red: 1.0, green: 1.0, blue: 1.0)

    /// Palette order matches the 1–5 keys.
    public static let palette: [InkColor] = [.red, .yellow, .green, .blue, .white]

    public func cgColor(alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

public struct InkPoint: Equatable, Sendable {
    public var location: CGPoint
    public var time: TimeInterval

    public init(_ location: CGPoint, time: TimeInterval) {
        self.location = location
        self.time = time
    }
}

public struct Stroke: Identifiable, Sendable {
    public let id: Int
    public let tool: Tool
    public let color: InkColor
    /// Fixed when the stroke starts, so changing the size never restyles existing ink.
    public let lineWidth: CGFloat
    public private(set) var points: [InkPoint]
    /// Bounding box of the points (a midpoint-quadratic curve stays inside it).
    public private(set) var pointBounds: CGRect

    init(id: Int, tool: Tool, color: InkColor, lineWidth: CGFloat, first: InkPoint) {
        self.id = id
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
        self.points = [first]
        self.pointBounds = CGRect(origin: first.location, size: .zero)
    }

    /// Area the rendered stroke can touch.
    public var renderBounds: CGRect {
        pointBounds.insetBy(dx: -renderPadding, dy: -renderPadding)
    }

    public var renderPadding: CGFloat { tool.renderPadding(width: lineWidth) }

    mutating func append(_ p: InkPoint) {
        points.append(p)
        pointBounds = pointBounds.union(CGRect(origin: p.location, size: .zero))
    }

    /// Removes points drawn at or before `cutoff`. Returns true if anything was removed.
    mutating func dropPoints(drawnAtOrBefore cutoff: TimeInterval) -> Bool {
        // Points are appended in time order, so expired ones are a prefix.
        guard let firstLive = points.firstIndex(where: { $0.time > cutoff }) else {
            let hadPoints = !points.isEmpty
            points.removeAll()
            pointBounds = .null
            return hadPoints
        }
        guard firstLive > 0 else { return false }
        points.removeFirst(firstLive)
        recomputeBounds()
        return true
    }

    private mutating func recomputeBounds() {
        guard let first = points.first else { pointBounds = .null; return }
        var r = CGRect(origin: first.location, size: .zero)
        for p in points.dropFirst() { r = r.union(CGRect(origin: p.location, size: .zero)) }
        pointBounds = r
    }
}

/// All ink on screen. Coordinates are global screen points (AppKit, bottom-left origin).
/// Every mutating call returns the global rect that needs redrawing (nil = nothing changed).
public final class InkStore {
    public static let defaultLaserLifetime: TimeInterval = 2.5

    public let laserLifetime: TimeInterval
    /// Minimum distance between recorded points, to keep paths light.
    public var minimumPointSpacing: CGFloat = 1.0

    public private(set) var strokes: [Stroke] = []        // persistent (pen, highlighter)
    public private(set) var laserStrokes: [Stroke] = []   // finished laser strokes still fading
    public private(set) var current: Stroke?
    private var nextID = 1

    public init(laserLifetime: TimeInterval = InkStore.defaultLaserLifetime) {
        self.laserLifetime = laserLifetime
    }

    /// Everything to render, bottom to top.
    public var visibleStrokes: [Stroke] {
        var all = strokes
        all.append(contentsOf: laserStrokes)
        if let current { all.append(current) }
        return all
    }

    public var hasPersistentInk: Bool { !strokes.isEmpty }

    /// True while any laser point still needs to fade.
    public var hasFadingInk: Bool {
        if !laserStrokes.isEmpty { return true }
        if let current, current.tool == .laser, !current.points.isEmpty { return true }
        return false
    }

    @discardableResult
    public func begin(tool: Tool, color: InkColor, width: CGFloat? = nil, at location: CGPoint,
                      time: TimeInterval) -> CGRect? {
        let dirty = end()
        let stroke = Stroke(id: nextID, tool: tool, color: color, lineWidth: width ?? tool.baseLineWidth,
                            first: InkPoint(location, time: time))
        nextID += 1
        current = stroke
        return union(dirty, stroke.renderBounds)
    }

    @discardableResult
    public func extend(to location: CGPoint, time: TimeInterval) -> CGRect? {
        guard var stroke = current else { return nil }
        if let last = stroke.points.last {
            let dx = location.x - last.location.x, dy = location.y - last.location.y
            if (dx * dx + dy * dy).squareRoot() < minimumPointSpacing { return nil }
        }
        stroke.append(InkPoint(location, time: time))
        current = stroke
        // Adding a point reshapes only the tail: the last three points cover it.
        let tail = stroke.points.suffix(3).map(\.location)
        var r = CGRect(origin: tail[tail.startIndex], size: .zero)
        for p in tail { r = r.union(CGRect(origin: p, size: .zero)) }
        return r.insetBy(dx: -stroke.renderPadding, dy: -stroke.renderPadding)
    }

    /// Finishes the in-progress stroke, if any.
    @discardableResult
    public func end() -> CGRect? {
        guard let stroke = current else { return nil }
        current = nil
        if stroke.points.isEmpty { return nil }
        if stroke.tool.isPersistent {
            strokes.append(stroke)
        } else {
            laserStrokes.append(stroke)
        }
        return stroke.renderBounds
    }

    /// Removes the last persistent stroke.
    @discardableResult
    public func undo() -> CGRect? {
        guard let removed = strokes.popLast() else { return nil }
        return removed.renderBounds
    }

    /// Removes all ink, including fading laser ink and any stroke in progress.
    @discardableResult
    public func clear() -> CGRect? {
        let dirty = visibleStrokes.reduce(nil as CGRect?) { union($0, $1.renderBounds) }
        strokes.removeAll()
        laserStrokes.removeAll()
        current = nil
        return dirty
    }

    /// Fraction of life left for a point drawn at `time` (1 = fresh, 0 = gone).
    public func remainingLife(ofPointDrawnAt time: TimeInterval, now: TimeInterval) -> CGFloat {
        let age = now - time
        return CGFloat(max(0, min(1, 1 - age / laserLifetime)))
    }

    /// Drops laser points older than the lifetime. Returns the area that changed.
    /// Call this every frame while `hasFadingInk` is true; the returned rect covers
    /// all live laser ink, since every laser point's opacity changes each frame.
    @discardableResult
    public func pruneLaser(now: TimeInterval) -> CGRect? {
        let cutoff = now - laserLifetime
        var dirty: CGRect?
        for i in laserStrokes.indices {
            dirty = union(dirty, laserStrokes[i].renderBounds)
            _ = laserStrokes[i].dropPoints(drawnAtOrBefore: cutoff)
        }
        laserStrokes.removeAll { $0.points.isEmpty }
        if var stroke = current, stroke.tool == .laser {
            dirty = union(dirty, stroke.renderBounds)
            _ = stroke.dropPoints(drawnAtOrBefore: cutoff)
            current = stroke
        }
        return dirty
    }

    private func union(_ a: CGRect?, _ b: CGRect) -> CGRect? {
        guard !b.isNull else { return a }
        guard let a, !a.isNull else { return b }
        return a.union(b)
    }
}
