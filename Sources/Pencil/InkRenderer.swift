import CoreGraphics
import PencilCore

/// Draws strokes with Core Graphics. The context must already be in global
/// screen coordinates (the overlay view translates by its window origin).
enum InkRenderer {
    static func draw(_ store: InkStore, in ctx: CGContext, dirty: CGRect, now: Double) {
        for stroke in store.visibleStrokes where stroke.renderBounds.intersects(dirty) {
            switch stroke.tool {
            case .pen, .highlighter:
                drawSolid(stroke, in: ctx)
            case .laser:
                drawLaser(stroke, store: store, in: ctx, now: now)
            }
        }
    }

    private static func drawSolid(_ stroke: Stroke, in ctx: CGContext) {
        let pts = stroke.points.map(\.location)
        guard !pts.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(stroke.lineWidth)
        ctx.setStrokeColor(stroke.color.cgColor(alpha: stroke.tool.opacity))
        ctx.setLineJoin(.round)
        if stroke.tool == .highlighter {
            ctx.setLineCap(.butt)
            if pts.count == 1 {
                // A flat-capped zero-length line draws nothing; show a short square mark.
                let w = stroke.lineWidth
                ctx.setFillColor(stroke.color.cgColor(alpha: stroke.tool.opacity))
                ctx.fill(CGRect(x: pts[0].x - w / 4, y: pts[0].y - w / 2, width: w / 2, height: w))
                return
            }
        } else {
            ctx.setLineCap(.round)
        }
        ctx.addPath(smoothPath(pts))
        ctx.strokePath()
    }

    /// Each segment gets the opacity of the point it belongs to, so the tail
    /// (oldest points) fades out first while the head stays bright.
    private static func drawLaser(_ stroke: Stroke, store: InkStore, in ctx: CGContext, now: Double) {
        let pts = stroke.points
        guard !pts.isEmpty else { return }
        let segs = smoothSegments(pts.map(\.location))
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let base = stroke.lineWidth
        // Two passes: a wide faint glow, then the bright core on top.
        for pass in 0..<2 {
            for seg in segs {
                let life = store.remainingLife(ofPointDrawnAt: pts[seg.pointIndex].time, now: now)
                guard life > 0.01 else { continue }
                let eased = life * life * (3 - 2 * life) // smoothstep
                if pass == 0 {
                    ctx.setLineWidth(base * 3.5)
                    ctx.setStrokeColor(stroke.color.cgColor(alpha: 0.22 * eased))
                } else {
                    ctx.setLineWidth(base * (0.55 + 0.45 * life))
                    ctx.setStrokeColor(stroke.color.cgColor(alpha: stroke.tool.opacity * eased))
                }
                ctx.move(to: seg.start)
                if let c = seg.control {
                    ctx.addQuadCurve(to: seg.end, control: c)
                } else {
                    ctx.addLine(to: seg.end)
                }
                ctx.strokePath()
            }
        }
    }
}
