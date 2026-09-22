import CoreGraphics
import Foundation

/// What a snapshot captures.
public enum CaptureKind: Equatable, Sendable {
    /// The whole screen under the mouse.
    case screenUnderMouse
    /// A region the user drags out with Pencil's area picker.
    case region
    /// A fixed global rect (AppKit coordinates), e.g. the ink-fit crop.
    case area(CGRect)
}

/// Pure pieces of the capture flow: file naming and capture geometry.
public enum CapturePlan {
    public static func fileName(for date: Date, attempt: Int = 1, timeZone: TimeZone = .current,
                                prefix: String = "pencil", ext: String = "png") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = prefix + "-" + f.string(from: date)
        return attempt <= 1 ? "\(base).\(ext)" : "\(base)-\(attempt).\(ext)"
    }

    /// Context kept around the ink in a "capture my drawing" crop.
    public static let inkPadding: CGFloat = 120

    /// The ink-fit crop: the union of the ink's render bounds that fall on `screenFrame`,
    /// padded by `padding` on every side and clamped to the screen. Nil when there's no ink
    /// on that screen (the caller falls back to the whole screen).
    public static func inkCropRect(inkBounds: [CGRect], screenFrame: CGRect,
                                   padding: CGFloat = inkPadding) -> CGRect? {
        let onScreen = inkBounds.filter { !$0.isNull }
            .map { $0.intersection(screenFrame) }
            .filter { !$0.isNull }
        guard let first = onScreen.first else { return nil }
        let union = onScreen.dropFirst().reduce(first) { $0.union($1) }
        let padded = union.insetBy(dx: -padding, dy: -padding).intersection(screenFrame)
        guard !padded.isNull, padded.width >= 1, padded.height >= 1 else { return nil }
        return padded.integral.intersection(screenFrame)
    }

    /// Pixel size of a still of `rect` (display points) at the display's backing scale.
    public static func stillPixelSize(for rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((rect.width * scale).rounded())), max(1, Int((rect.height * scale).rounded())))
    }

    /// The global rect a capture covers: the whole screen, or the given area clamped to it.
    /// Nil for `.region`, which needs the area picker first.
    public static func captureRect(for kind: CaptureKind, screenFrame: CGRect) -> CGRect? {
        switch kind {
        case .screenUnderMouse: return screenFrame
        case .region: return nil
        case .area(let r):
            let clamped = r.intersection(screenFrame)
            return clamped.isNull || clamped.isEmpty ? nil : clamped
        }
    }
}

/// Pure geometry for screen recordings.
public enum RecordingPlan {
    /// Longest recording before it stops on its own.
    public static let maxDuration: TimeInterval = 5 * 60
    public static let framesPerSecond: Int32 = 30

    /// ScreenCaptureKit's `sourceRect`: the selection in the display's own points,
    /// top-left origin. `selection` and `screenFrame` are AppKit global rects.
    public static func sourceRect(selection: CGRect, screenFrame: CGRect) -> CGRect {
        let r = selection.intersection(screenFrame)
        return CGRect(x: r.minX - screenFrame.minX, y: screenFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Output pixel size at the display's scale, rounded down to even numbers (H.264 needs them).
    public static func pixelSize(for rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        func even(_ v: CGFloat) -> Int { max(2, Int((v * scale).rounded(.down)) & ~1) }
        return (even(rect.width), even(rect.height))
    }

    /// "0:12", "4:05".
    public static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// Normalizes a drag between two points into a rect clamped to `screenFrame`.
    public static func selection(from a: CGPoint, to b: CGPoint, in screenFrame: CGRect) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .intersection(screenFrame)
    }
}
