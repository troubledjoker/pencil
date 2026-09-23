import AppKit

/// A view that wants a specific cursor while the mouse is over it (buttons, rows, the tile).
protocol PointerCursorProviding: NSView {
    var pointerCursor: NSCursor { get }
}

/// One place that decides the cursor for every Pencil window.
///
/// Pencil's panels are non-activating and rarely key, and the ink overlay is key while
/// drawing, so AppKit's cursor rects can't arbitrate between them. Instead every tracking
/// event (enter, move, exit, cursorUpdate) in any Pencil view calls `update()`, which
/// looks at what is actually under the mouse and sets the one right cursor. Because all
/// callers compute the same answer, overlapping tracking areas never fight.
@MainActor
enum PencilCursor {
    /// Held while a control is being dragged (slider knob, the pencil tile), so hover events
    /// from other views can't swap the cursor mid-drag.
    private(set) static var pressed: NSCursor?

    static func beginPress(_ cursor: NSCursor) {
        pressed = cursor
        cursor.set()
    }

    static func endPress() {
        pressed = nil
        update()
    }

    /// Sets the cursor for whatever is under the mouse right now.
    static func update() {
        _ = enableBackgroundCursor
        apply()
        // The frontmost app still gets its own cursor updates as the mouse crosses its
        // windows, and can set the arrow just after we set a hand. Re-assert once the mouse
        // settles (coalesced: one pending re-check at a time).
        reassert?.cancel()
        let work = DispatchWorkItem { if pressed != nil || resolveOwn() != nil { apply() } }
        reassert = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private static var reassert: DispatchWorkItem?

    private static func apply() {
        (pressed ?? resolve()).set()
    }

    /// Pencil is almost never the active app, and the window server ignores `NSCursor.set()`
    /// from a background app unless its connection opts in. This is the (private, long-stable)
    /// CoreGraphics connection property that background utilities use for exactly this.
    /// Looked up at run time so a missing symbol just means no hand cursor, not a crash.
    private static let enableBackgroundCursor: Void = {
        typealias MainConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let mainSym = dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let cid = unsafeBitCast(mainSym, to: MainConnection.self)()
        _ = unsafeBitCast(setSym, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString,
                                                        kCFBooleanTrue)
    }()

    /// Adds a panel-wide tracking area to a Pencil window's content view, so moving over any
    /// part of the panel (background included) keeps the cursor right even though the panel
    /// is not key.
    static func track(_ view: NSView) {
        guard !view.trackingAreas.contains(where: { $0.owner === PanelCursorTracker.shared }) else { return }
        view.addTrackingArea(NSTrackingArea(rect: .zero,
                                            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                                      .activeAlways, .inVisibleRect],
                                            owner: PanelCursorTracker.shared))
    }

    /// Re-resolves on the next turn of the run loop (after a window has actually left the
    /// screen) and once more after the usual show/hide animation, since a panel appearing or
    /// vanishing under a still mouse sends no tracking events, and making the overlay key can
    /// reset the cursor to the arrow a moment later.
    static func updateSoon() {
        DispatchQueue.main.async { update() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { update() }
    }

    /// Like `updateSoon`, but only if `frame` (screen coordinates) is under the mouse, so a
    /// panel showing or hiding elsewhere never touches the cursor over another app.
    static func updateSoon(ifMouseIn frame: NSRect) {
        let check = { if frame.contains(NSEvent.mouseLocation) { update() } }
        DispatchQueue.main.async(execute: check)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
    }

    /// The cursor for the point under the mouse. Over another app's window this is the arrow:
    /// only Pencil's own tracking events call this, and that app re-sets its own cursor as the
    /// mouse moves on.
    static func resolve(at point: NSPoint = NSEvent.mouseLocation) -> NSCursor {
        resolveOwn(at: point) ?? .arrow
    }

    /// The cursor Pencil wants at `point`, or nil when no Pencil window claims it (another
    /// app's window or the desktop, which own the cursor there).
    private static func resolveOwn(at point: NSPoint = NSEvent.mouseLocation) -> NSCursor? {
        var below = 0
        // Walk down through the window stack at this point, skipping Pencil windows that
        // let the mouse through (hints, toasts, pass-through ink, transparent dock areas).
        for _ in 0..<16 {
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: below)
            guard number > 0,
                  let window = NSApp.windows.first(where: { $0.windowNumber == number }) else {
                return nil // the desktop or someone else's window
            }
            below = number
            guard window.isVisible, !window.ignoresMouseEvents, window.alphaValue > 0.01 else { continue }
            if let overlay = window as? OverlayWindow {
                if overlay.overlayView.isDrawing { return .crosshair }
                continue
            }
            guard let content = window.contentView else { continue }
            let local = content.superview.map { $0.convert(window.convertPoint(fromScreen: point), from: nil) }
                ?? window.convertPoint(fromScreen: point)
            guard let hit = content.hitTest(local) else { continue } // transparent area: look below
            return cursor(for: hit)
        }
        return nil
    }

    private static func cursor(for hit: NSView) -> NSCursor {
        var view: NSView? = hit
        while let v = view {
            if let p = v as? PointerCursorProviding { return p.pointerCursor }
            if v is NSTextView { return .iBeam }
            if let field = v as? NSTextField, field.isEditable { return .iBeam }
            view = v.superview
        }
        return .arrow
    }
}

/// Owner of the panel-wide tracking areas: every event just re-resolves the cursor.
@MainActor
final class PanelCursorTracker: NSResponder {
    static let shared = PanelCursorTracker()

    override func mouseEntered(with event: NSEvent) { PencilCursor.update() }
    override func mouseMoved(with event: NSEvent) { PencilCursor.update() }
    override func mouseExited(with event: NSEvent) { PencilCursor.update() }
    override func cursorUpdate(with event: NSEvent) { PencilCursor.update() }
}
