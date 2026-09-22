import CoreGraphics
import Foundation

/// Pencil's artwork, drawn with Core Graphics only so it can be shared by the app
/// (dock tab, toolbar handle) and by `scripts/make-icon.swift` (the .icns).
///
/// All drawing functions take a CGContext with a bottom-left origin (CG default).
public enum IconArt {
    // MARK: Palette

    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    }

    /// The ink color used by the tip and trailing stroke.
    public static let inkHex: UInt32 = 0xFF4D6D

    // MARK: App icon

    /// Draws the full macOS-style app icon into a `size`×`size` square at the origin.
    public static func drawAppIcon(in ctx: CGContext, size: CGFloat) {
        let s = size
        // macOS icon grid: the tile is ~80.5% of the canvas, centered, slightly raised.
        let tile = CGRect(x: s * 0.0977, y: s * 0.0977 + s * 0.008, width: s * 0.805, height: s * 0.805)
        let shape = squirclePath(in: tile)

        // Drop shadow under the tile.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                      color: rgb(0x000000, 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(rgb(0x2A1670))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        drawBackground(in: ctx, rect: tile)
        // Pencil + trailing ink, laid out in the tile's unit square.
        ctx.translateBy(x: tile.minX, y: tile.minY)
        ctx.scaleBy(x: tile.width, y: tile.height)
        drawTrail(in: ctx, unit: 1)
        drawPencil(in: ctx, center: CGPoint(x: 0.56, y: 0.56), length: 0.74, width: 0.155,
                   angleDegrees: 45, shadowScale: 1)
        ctx.restoreGState()

        // Hairline edge light.
        ctx.saveGState()
        ctx.addPath(squirclePath(in: tile.insetBy(dx: s * 0.002, dy: s * 0.002)))
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
        ctx.setLineWidth(max(1, s * 0.004))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The deep indigo → violet background with a soft top highlight.
    public static func drawBackground(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: rect)
        let g = gradient([rgb(0x5B2EE0), rgb(0x3A1C9C), rgb(0x1E1060)], [0, 0.55, 1])
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        // A violet glow in the upper right and a faint highlight at the top.
        let glow = gradient([rgb(0xB65CFF, 0.55), rgb(0xB65CFF, 0)], [0, 1])
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.8),
                               startRadius: 0,
                               endCenter: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.8),
                               endRadius: rect.width * 0.7, options: [])
        let top = gradient([rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)], [0, 1])
        ctx.drawLinearGradient(top, start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.45), options: [])
        ctx.restoreGState()
    }

    /// Small artwork for UI: the background clipped to `path`, plus the pencil
    /// (without the trail, which gets lost at small sizes) fitted into `art`.
    public static func drawBadge(in ctx: CGContext, clip path: CGPath, art: CGRect, background: CGRect) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        drawBackground(in: ctx, rect: background)
        ctx.translateBy(x: art.minX, y: art.minY)
        ctx.scaleBy(x: art.width, y: art.height)
        drawPencil(in: ctx, center: CGPoint(x: 0.5, y: 0.5), length: 0.92, width: 0.2,
                   angleDegrees: 45, shadowScale: 0.5)
        ctx.restoreGState()
    }

    // MARK: Pre-rendered layers (for Core Animation)

    private static func bitmap(_ px: Int, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(ctx)
        return ctx.makeImage()
    }

    /// The icon background as a square image, to stretch behind the dock pencil.
    public static func backgroundImage(pixels px: Int) -> CGImage? {
        bitmap(px) { drawBackground(in: $0, rect: CGRect(x: 0, y: 0, width: px, height: px)) }
    }

    /// Just the pencil (with its drop shadow) on a transparent square, centered, at
    /// `angleDegrees` (90 = upright: eraser up, tip down; 45 = the icon's diagonal).
    /// Its length is 0.86 of the square, so it fits at any rotation around the center.
    public static func pencilImage(pixels px: Int, angleDegrees: CGFloat = 45) -> CGImage? {
        bitmap(px) { ctx in
            ctx.scaleBy(x: CGFloat(px), y: CGFloat(px))
            drawPencil(in: ctx, center: CGPoint(x: 0.5, y: 0.5), length: 0.86, width: 0.19,
                       angleDegrees: angleDegrees, shadowScale: 0.5)
        }
    }

    // MARK: Pieces

    /// A superellipse ("squircle") filling `rect`.
    public static func squirclePath(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2, b = rect.height / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let steps = 256
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let ct = cos(t), st = sin(t)
            let x = c.x + a * copysign(pow(abs(ct), 2 / n), ct)
            let y = c.y + b * copysign(pow(abs(st), 2 / n), st)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }

    /// A glowing ink stroke that ends at the pencil tip and fades toward its tail,
    /// like the laser mode. Drawn in unit coordinates.
    static func drawTrail(in ctx: CGContext, unit: CGFloat) {
        let tip = tipPoint(center: CGPoint(x: 0.56, y: 0.56), length: 0.74, angleDegrees: 45)
        let tail = CGPoint(x: 0.85, y: 0.2)
        let path = CGMutablePath()
        path.move(to: tail)
        path.addCurve(to: tip, control1: CGPoint(x: 0.66, y: 0.06), control2: CGPoint(x: 0.42, y: 0.2))

        // Each pass strokes the whole curve once and fills it with a gradient running
        // from the transparent tail to the bright head, so there are no seams.
        let passes: [(width: CGFloat, color: UInt32, alpha: CGFloat)] = [
            // Soft glow: several stacked strokes of shrinking width blend into a falloff.
            (0.13, inkHex, 0.05), (0.11, inkHex, 0.06), (0.09, inkHex, 0.07),
            (0.075, inkHex, 0.09), (0.06, inkHex, 0.12), (0.048, inkHex, 0.16),
            (0.034, inkHex, 1.0),   // colored body
            (0.012, 0xFFE8EE, 0.95) // hot core
        ]
        for pass in passes {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setLineWidth(pass.width)
            ctx.setLineCap(.round)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let g = gradient([rgb(pass.color, 0), rgb(pass.color, pass.alpha * 0.35), rgb(pass.color, pass.alpha)],
                             [0, 0.55, 1])
            ctx.drawLinearGradient(g, start: tail, end: tip, options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }

    static func tipPoint(center: CGPoint, length: CGFloat, angleDegrees: CGFloat) -> CGPoint {
        let a = angleDegrees * .pi / 180
        return CGPoint(x: center.x - cos(a) * length / 2, y: center.y - sin(a) * length / 2)
    }

    /// A bold pencil: colored tip, wood cone, faceted yellow body, metal band, pink eraser.
    /// Drawn along its local x axis (tip at -x) then rotated by `angleDegrees`.
    static func drawPencil(in ctx: CGContext, center: CGPoint, length L: CGFloat, width W: CGFloat,
                           angleDegrees: CGFloat, shadowScale: CGFloat) {
        let x0 = -L / 2
        let tipLen = L * 0.22
        let eraserLen = L * 0.12
        let bandLen = L * 0.085
        let bodyStart = x0 + tipLen
        let bandStart = L / 2 - eraserLen - bandLen
        let eraserStart = L / 2 - eraserLen
        let h = W / 2

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angleDegrees * .pi / 180)

        // Whole-pencil silhouette for the drop shadow.
        let silhouette = CGMutablePath()
        silhouette.move(to: CGPoint(x: x0, y: 0))
        silhouette.addLine(to: CGPoint(x: bodyStart, y: h))
        silhouette.addLine(to: CGPoint(x: L / 2 - h * 0.6, y: h))
        silhouette.addQuadCurve(to: CGPoint(x: L / 2, y: 0), control: CGPoint(x: L / 2, y: h))
        silhouette.addQuadCurve(to: CGPoint(x: L / 2 - h * 0.6, y: -h), control: CGPoint(x: L / 2, y: -h))
        silhouette.addLine(to: CGPoint(x: bodyStart, y: -h))
        silhouette.closeSubpath()

        ctx.saveGState()
        // CG shadow offset/blur live in unrotated device space, so scale them by the
        // current transform's zoom; the offset then falls down-right on screen.
        let t = ctx.userSpaceToDeviceSpaceTransform
        let k = hypot(t.a, t.b)
        ctx.setShadow(offset: CGSize(width: 0.02 * shadowScale * k, height: -0.028 * shadowScale * k),
                      blur: 0.035 * shadowScale * k, color: rgb(0x0A0530, 0.55))
        ctx.addPath(silhouette)
        ctx.setFillColor(rgb(0x000000, 0.9))
        ctx.fillPath()
        ctx.restoreGState()

        // Body: three facets, lighter on top.
        func band(_ y0: CGFloat, _ y1: CGFloat, from xa: CGFloat, to xb: CGFloat) -> CGRect {
            CGRect(x: xa, y: y0, width: xb - xa, height: y1 - y0)
        }
        let facets: [(CGFloat, CGFloat, UInt32, UInt32)] = [
            (h / 3, h, 0xFFD54A, 0xFFC21A),
            (-h / 3, h / 3, 0xFFB31A, 0xFFA000),
            (-h, -h / 3, 0xF08A00, 0xD97400),
        ]
        for (y0, y1, c0, c1) in facets {
            // Starts under the cone so its scalloped edge shows body color, not shadow.
            let r = band(y0, y1, from: bodyStart - W * 0.14, to: bandStart)
            ctx.saveGState()
            ctx.addPath(silhouette)
            ctx.clip()
            ctx.clip(to: r)
            ctx.drawLinearGradient(gradient([rgb(c0), rgb(c1)], [0, 1]),
                                   start: CGPoint(x: 0, y: y1), end: CGPoint(x: 0, y: y0), options: [])
            ctx.restoreGState()
        }
        // Facet lines.
        ctx.setStrokeColor(rgb(0x8A4B00, 0.35))
        ctx.setLineWidth(W * 0.02)
        for y in [h / 3, -h / 3] {
            ctx.move(to: CGPoint(x: bodyStart, y: y))
            ctx.addLine(to: CGPoint(x: bandStart, y: y))
        }
        ctx.strokePath()

        // Wood cone with a scalloped back edge.
        let cone = CGMutablePath()
        cone.move(to: CGPoint(x: x0, y: 0))
        cone.addLine(to: CGPoint(x: bodyStart, y: h))
        cone.addQuadCurve(to: CGPoint(x: bodyStart, y: h / 3), control: CGPoint(x: bodyStart - W * 0.12, y: h * 0.66))
        cone.addQuadCurve(to: CGPoint(x: bodyStart, y: -h / 3), control: CGPoint(x: bodyStart - W * 0.12, y: 0))
        cone.addQuadCurve(to: CGPoint(x: bodyStart, y: -h), control: CGPoint(x: bodyStart - W * 0.12, y: -h * 0.66))
        cone.closeSubpath()
        ctx.saveGState()
        ctx.addPath(cone)
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0xFBE3BD), rgb(0xE9BF86), rgb(0xC9955A)], [0, 0.55, 1]),
                               start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: -h), options: [])
        ctx.restoreGState()

        // Colored lead at the point.
        let leadLen = tipLen * 0.38
        let lead = CGMutablePath()
        lead.move(to: CGPoint(x: x0, y: 0))
        lead.addLine(to: CGPoint(x: x0 + leadLen, y: h * leadLen / tipLen))
        lead.addQuadCurve(to: CGPoint(x: x0 + leadLen, y: -h * leadLen / tipLen),
                          control: CGPoint(x: x0 + leadLen * 1.12, y: 0))
        lead.closeSubpath()
        ctx.saveGState()
        ctx.addPath(lead)
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0xFF8FA3), rgb(inkHex), rgb(0xC21E45)], [0, 0.5, 1]),
                               start: CGPoint(x: 0, y: h * 0.4), end: CGPoint(x: 0, y: -h * 0.4), options: [])
        ctx.restoreGState()

        // Metal band with ridges.
        let bandRect = band(-h * 1.03, h * 1.03, from: bandStart, to: eraserStart)
        ctx.saveGState()
        ctx.clip(to: bandRect)
        ctx.drawLinearGradient(gradient([rgb(0xF4F6FA), rgb(0xB9C0CC), rgb(0xE3E7EE), rgb(0x7E8796)],
                                        [0, 0.35, 0.6, 1]),
                               start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: -h), options: [])
        ctx.setStrokeColor(rgb(0x5E6675, 0.55))
        ctx.setLineWidth(W * 0.035)
        for k in 1...3 {
            let x = bandStart + (eraserStart - bandStart) * CGFloat(k) / 4
            ctx.move(to: CGPoint(x: x, y: -h * 1.03))
            ctx.addLine(to: CGPoint(x: x, y: h * 1.03))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Pink eraser, rounded end.
        let eraser = CGMutablePath()
        eraser.move(to: CGPoint(x: eraserStart, y: h))
        eraser.addLine(to: CGPoint(x: L / 2 - h * 0.6, y: h))
        eraser.addQuadCurve(to: CGPoint(x: L / 2, y: 0), control: CGPoint(x: L / 2, y: h))
        eraser.addQuadCurve(to: CGPoint(x: L / 2 - h * 0.6, y: -h), control: CGPoint(x: L / 2, y: -h))
        eraser.addLine(to: CGPoint(x: eraserStart, y: -h))
        eraser.closeSubpath()
        ctx.saveGState()
        ctx.addPath(eraser)
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0xFFB3C6), rgb(0xFF7FA0), rgb(0xE0557C)], [0, 0.5, 1]),
                               start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: -h), options: [])
        ctx.restoreGState()

        // Specular highlight along the top facet.
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.45))
        ctx.setLineWidth(W * 0.05)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: bodyStart + W * 0.25, y: h * 0.72))
        ctx.addLine(to: CGPoint(x: bandStart - W * 0.25, y: h * 0.72))
        ctx.strokePath()

        ctx.restoreGState()
    }
}
