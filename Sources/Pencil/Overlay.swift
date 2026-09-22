import AppKit
import PencilCore

/// A transparent, borderless, full-screen panel that holds the ink for one screen.
/// It's a non-activating panel that can still become key: in a drawing mode it takes
/// the keyboard (P/H/L, 1–5, Esc…) immediately, without activating Pencil or
/// deactivating the user's app, so focus goes straight back when drawing stops.
final class OverlayWindow: NSPanel {
    let overlayView: OverlayView
    let screenID: CGDirectDisplayID

    init(screen: NSScreen, controller: AppController) {
        overlayView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        screenID = screen.displayID
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isFloatingPanel = false
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        overlayView.controller = controller
        overlayView.autoresizingMask = [.width, .height]
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Invalidates the part of this window covered by a global rect (nil = everything).
    func invalidate(global rect: CGRect?) {
        guard let rect else {
            overlayView.needsDisplay = true
            return
        }
        let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(overlayView.bounds)
        if !local.isNull, !local.isEmpty {
            overlayView.setNeedsDisplay(local.integral)
        }
    }
}

final class OverlayView: NSView {
    weak var controller: AppController?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let window, let controller else { return }
        ctx.clear(dirtyRect)
        let origin = window.frame.origin
        ctx.saveGState()
        ctx.translateBy(x: -origin.x, y: -origin.y)
        InkRenderer.draw(controller.store, in: ctx,
                         dirty: dirtyRect.offsetBy(dx: origin.x, dy: origin.y),
                         now: CACurrentMediaTime())
        ctx.restoreGState()
    }

    // MARK: Cursor

    override func resetCursorRects() {
        if controller?.mode.isDrawing == true {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited,
                                                 .mouseMoved, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }
    override func mouseEntered(with event: NSEvent) { updateCursor() }
    override func mouseMoved(with event: NSEvent) { updateCursor() }

    private func updateCursor() {
        if controller?.mode.isDrawing == true { NSCursor.crosshair.set() }
    }

    // MARK: Mouse

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        updateCursor()
        controller?.pointerDown(at: globalPoint(event))
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.pointerDragged(to: globalPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        controller?.pointerDragged(to: globalPoint(event))
        controller?.pointerUp()
    }

    // MARK: Keys (only while the overlay is key)

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        if !controller.handleLocalKey(event) { super.keyDown(with: event) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
