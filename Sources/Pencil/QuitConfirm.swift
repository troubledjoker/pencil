import AppKit
import PencilCore

/// "Quit Pencil?": a small centered HUD in Pencil's dark style, used by the toolbar's Quit
/// button, ⌥Q and the menu bar's Quit Pencil. Return quits, Esc or a click outside cancels.
/// It sits above the ink overlay and takes the keyboard while open (without activating
/// Pencil), so it works in the middle of drawing.
@MainActor
final class QuitConfirmation {
    private let controller: AppController
    private var panel: QuitPanel?
    private var monitors: [Any] = []
    private var quitting = false
    private(set) var isShown = false

    static let violet = NSColor(srgbRed: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255, alpha: 1)

    init(controller: AppController) {
        self.controller = controller
    }

    func show() {
        guard !quitting else { return }
        if isShown, let panel {
            // Already open: just bring it back to the front with the keyboard.
            panel.makeKeyAndOrderFront(nil)
            return
        }
        HintCenter.shared.hide()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        let panel = self.panel ?? QuitPanel()
        self.panel = panel
        panel.onKey = { [weak self] key in
            switch key {
            case .confirm: self?.quit()
            case .cancel: self?.cancel()
            }
        }
        let content = makeContent(recording: controller.recorder.isRecording)
        let size = content.frame.size
        let v = screen.visibleFrame
        panel.setFrame(NSRect(x: round(v.midX - size.width / 2), y: round(v.midY - size.height / 2 + v.height * 0.06),
                              width: size.width, height: size.height), display: false)
        panel.contentView = content
        isShown = true

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduce ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(content)
        if !reduce {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            if let layer = content.layer {
                let b = content.bounds
                let from = CATransform3DConcat(
                    CATransform3DConcat(CATransform3DMakeTranslation(-b.midX, -b.midY, 0),
                                        CATransform3DMakeScale(0.94, 0.94, 1)),
                    CATransform3DMakeTranslation(b.midX, b.midY, 0))
                let anim = CABasicAnimation(keyPath: "transform")
                anim.fromValue = NSValue(caTransform3D: from)
                anim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                anim.duration = 0.15
                anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                layer.add(anim, forKey: "appear")
            }
        }
        installMonitors()
    }

    func cancel() {
        guard isShown, !quitting else { return }
        close()
        // Drawing was on: the overlay gets the keyboard back for the in-draw keys.
        controller.rekeyOverlayIfDrawing()
    }

    private func quit() {
        guard isShown, !quitting else { return }
        quitting = true
        close()
        // A running recording is stopped and its file finished before Pencil goes away.
        controller.recorder.stopAndSave {
            NSApp.terminate(nil)
        }
    }

    private func close() {
        isShown = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel?.orderOut(nil)
    }

    /// A click anywhere outside the panel (another app, the desktop, or another Pencil
    /// window such as the dock or the ink) cancels.
    private func installMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                     handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                    handler: { [weak self] event in
            var consumed = false
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if event.window !== panel {
                    self.cancel()
                    consumed = true // the click only dismisses; it doesn't also draw or press a tool
                }
            }
            return consumed ? nil : event
        }) { monitors.append(l) }
    }

    // MARK: Content

    private func makeContent(recording: Bool) -> NSView {
        let width: CGFloat = 320
        let effect = QuitContentView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor

        let icon = NSImageView(image: Self.iconImage(size: 56))
        icon.imageScaling = .scaleNone

        let title = NSTextField(labelWithString: "Quit Pencil?")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.alignment = .center

        func body(_ text: String) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: text)
            f.font = .systemFont(ofSize: 12.5)
            f.textColor = NSColor.white.withAlphaComponent(0.72)
            f.alignment = .center
            f.preferredMaxLayoutWidth = width - 48
            f.isSelectable = false
            return f
        }
        var texts: [NSView] = [
            body("Anything you've drawn on screen will be cleared. Your clipboard history and captures are saved."),
        ]
        if recording { texts.append(body("Your screen recording will be stopped and saved.")) }

        let cancel = QuitButton(title: "Cancel", primary: false)
        cancel.onClick = { [weak self] in self?.cancel() }
        let quit = QuitButton(title: "Quit", primary: true)
        quit.onClick = { [weak self] in self?.quit() }
        let buttonWidth = (width - 48 - 10) / 2
        for b in [cancel, quit] {
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: buttonWidth),
                b.heightAnchor.constraint(equalToConstant: 30),
            ])
        }
        let buttons = NSStackView(views: [cancel, quit])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [icon, title] + texts + [buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(18, after: texts.last!)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        effect.frame = NSRect(origin: .zero, size: stack.fittingSize)
        effect.layoutSubtreeIfNeeded()
        return effect
    }

    private static func iconImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            IconArt.drawAppIcon(in: ctx, size: size)
            return true
        }
    }
}

// MARK: - Panel

/// Borderless, non-activating, but able to take the keyboard: Return and Esc arrive here
/// even while Pencil is in the background and the ink overlay was key.
final class QuitPanel: NSPanel {
    enum Key { case confirm, cancel }
    var onKey: ((Key) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true // before `level`: it resets the level
        // Above the ink overlay, the dock and the hints.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override var contentView: NSView? {
        didSet { if let contentView { PencilCursor.track(contentView) } }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Shortcuts.escapeKeyCode {
            onKey?(.cancel)
        } else if Shortcuts.returnKeyCodes.contains(event.keyCode) {
            onKey?(.confirm)
        }
        // Everything else is swallowed: the in-draw single keys shouldn't fire underneath.
    }

    override func cancelOperation(_ sender: Any?) { onKey?(.cancel) }

    /// ⌘Q (or ⌘.) while it's open: Return is the one way to confirm, so just keep it up.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == Shortcuts.escapeKeyCode { onKey?(.cancel); return true }
        return true
    }

    /// Keep the keyboard while open (e.g. if drawing re-keys the overlay underneath).
    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                // Only take it back from Pencil's own windows, never from another app.
                if let key = NSApp.keyWindow, key !== self { self.makeKey() }
            }
        }
    }

    override func orderOut(_ sender: Any?) {
        let f = frame
        super.orderOut(sender)
        PencilCursor.updateSoon(ifMouseIn: f)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        PencilCursor.updateSoon(ifMouseIn: frame)
    }
}

/// The panel's background; accepts first responder so the panel's key handling is reached.
final class QuitContentView: NSVisualEffectView {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Buttons

/// A rounded pill button: filled violet for the primary action, a soft white tint otherwise.
final class QuitButton: NSView, PointerCursorProviding {
    var onClick: (() -> Void)?
    private let primary: Bool
    private let label: NSTextField
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    var pointerCursor: NSCursor { .pointingHand }

    init(title: String, primary: Bool) {
        self.primary = primary
        label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        label.font = .systemFont(ofSize: 13, weight: primary ? .semibold : .medium)
        label.textColor = primary ? .white : NSColor.white.withAlphaComponent(0.9)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The label shouldn't swallow the click or the cursor.
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                                      .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; PencilCursor.update() }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false; PencilCursor.update() }
    override func mouseMoved(with event: NSEvent) { PencilCursor.update() }
    override func cursorUpdate(with event: NSEvent) { PencilCursor.update() }

    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if primary {
            let base = QuitConfirmation.violet
            let fill = pressed ? base.blended(withFraction: 0.18, of: .black)
                : (hovering ? base.blended(withFraction: 0.12, of: .white) : base)
            (fill ?? base).setFill()
            path.fill()
        } else {
            NSColor.white.withAlphaComponent(pressed ? 0.22 : (hovering ? 0.16 : 0.1)).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
