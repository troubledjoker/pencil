import AppKit
import PencilCore

/// The floating edge dock: one pencil on the left edge of a screen that morphs
/// into the handle of a vertical toolbar and back.
///
/// Everything lives in ONE non-activating panel above the ink overlay: a single
/// persistent pencil view (its layers morph between tab and handle), the toolbar
/// background, and the sections. Only layers animate; the panel is resized
/// instantly (it's transparent) before expanding and after collapsing.
@MainActor
final class DockController {
    private let controller: AppController
    private let panel: DockPanel
    private let container: NSView
    private let background: NSVisualEffectView
    private let toolbar: NSView
    private let pencil: DockPencilView
    private var handleSpacer: NSView!
    private var toolButtons: [Tool: DockButton] = [:]
    private var clipboardButton: DockButton?
    private lazy var recordButton: DockButton = {
        let b = DockButton(symbol: "record.circle", hint: Shortcuts.hint("Screen recording", .record))
        b.onClick = { [weak self] in
            self?.flyout.close()
            self?.controller.toggleRecording()
        }
        return b
    }()
    private var swatch: DockSwatch!
    private let flyout = ColorFlyout()
    private var lastMode: Mode?

    private(set) var isExpanded = false
    /// Floating Undo / Clear, shown only while there's ink (collapsed or open).
    private let editPill = EditPill()
    private var hovering = false
    private var draggingTile = false
    /// Keeps the tile fully out right after collapsing (until the mouse moves away).
    private var holdOut = false
    /// Whether the collapsed tile is currently shown fully (vs. peeking half-hidden).
    private var tileIsOut = false
    private var restWork: DispatchWorkItem?
    /// How much of the tile hides past the screen edge at rest.
    private static let peekHidden: CGFloat = 18
    private static let peekDuration: CFTimeInterval = 0.18
    private static let restDelay: TimeInterval = 0
    /// Bumped on every transition so a stale completion never undoes a newer one.
    private var generation = 0
    /// Which way the open toolbar extends from the handle.
    private var direction: DockGeometry.GrowDirection = .down
    private var sections: [NSView] = []
    /// The final expanded frame (screen coordinates), computed before animating.
    private var expandedTarget: NSRect = .zero
    private var screenID: CGDirectDisplayID = 0
    /// Center of the tab, measured from the bottom of the screen's visible frame.
    private var offsetY: CGFloat = 0

    // Geometry
    static let expandedWidth: CGFloat = 48
    /// The pencil tile: flush with the screen edge (it looks like it comes out of it),
    /// the same size and place collapsed and as the open toolbar's handle.
    static let tileSize = NSSize(width: 36, height: 32)
    /// Room around the collapsed tile for its (small) shadow, so it's never clipped
    /// into a visible rectangle by the panel's bounds. The left side is the screen edge.
    private static let shadowRoom: CGFloat = 10
    static let collapsedSize = NSSize(width: tileSize.width + shadowRoom,
                                      height: tileSize.height + shadowRoom * 2)
    private static let sectionPadding: CGFloat = 5
    private static let sectionGap: CGFloat = 5
    private static let backgroundRadius: CGFloat = 12
    private static let slide: CGFloat = 8

    private static let duration: CFTimeInterval = 0.28
    private static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)

    private enum Key {
        static let offsetY = "dock.offsetY"
        static let displayID = "dock.displayID"
    }

    init(controller: AppController) {
        self.controller = controller
        panel = DockPanel(contentRect: NSRect(origin: .zero, size: Self.collapsedSize))
        panel.hasShadow = false

        container = DockContainer(frame: NSRect(origin: .zero, size: Self.collapsedSize))
        container.wantsLayer = true
        panel.contentView = container

        // Toolbar background: dark HUD vibrancy, square on the screen edge, rounded on the right.
        background = NSVisualEffectView(frame: .zero)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.maskImage = Self.rightRoundedMask(radius: Self.backgroundRadius)
        background.isHidden = true
        container.addSubview(background)

        toolbar = DockContainer(frame: .zero)
        toolbar.wantsLayer = true
        toolbar.alphaValue = 0
        toolbar.isHidden = true
        container.addSubview(toolbar)

        // The one pencil, above everything. It spans the container but only its
        // current tile rect takes clicks; the rest falls through to the toolbar.
        pencil = DockPencilView(frame: container.bounds)
        pencil.autoresizingMask = [.width, .height]
        container.addSubview(pencil)
        pencil.onClick = { [weak self] in self?.toggleExpanded() }
        pencil.onDrag = { [weak self] start, now in
            guard let self else { return }
            if !self.draggingTile {
                self.draggingTile = true // a drag peeks the tile out
                self.updatePeek()
            }
            self.drag(from: start, to: now)
        }
        pencil.onDragEnd = { [weak self] in
            guard let self else { return }
            self.savePosition()
            self.draggingTile = false
            self.updatePeek()
        }
        pencil.onHover = { [weak self] inside in self?.hoverChanged(inside) }

        buildToolbar()
        editPill.onUndo = { [weak self] in self?.controller.undo() }
        editPill.onClear = { [weak self] in self?.controller.clear() }
        flyout.companion = panel
        flyout.onPick = { [weak self] color in
            self?.controller.setColor(color)
            self?.flyout.close()
        }
        flyout.onOpenChange = { [weak self] open in
            guard let self else { return }
            self.swatch.isOpen = open
        }
        ClipboardHistoryController.shared.observeOpen { [weak self] open in
            self?.clipboardButton?.isSelected = open
        }
        restorePosition()
        refresh()
        setPanelFrame(collapsedFrame())
        applyLayout(expanded: false, duration: 0)
        panel.orderFrontRegardless()
    }

    // MARK: Toolbar

    private func buildToolbar() {
        let w = Self.expandedWidth
        // Sections from the handle end: handle, Draw, Edit, Capture, Clipboard, Off.
        // The handle slot is empty: the persistent pencil view sits on top of it.
        sections = []
        handleSpacer = NSView(frame: NSRect(x: 0, y: 0, width: 44, height: 40))
        sections.append(handleSpacer)

        let tools: [(Tool, String, String)] = [
            (.pen, "pencil.tip", Shortcuts.hint("Pen", .pen)),
            (.highlighter, "highlighter", Shortcuts.hint("Highlighter")),
            (.laser, "wand.and.rays", Shortcuts.hint("Laser", .laser)),
        ]
        var drawItems: [NSView] = []
        for (tool, symbol, tip) in tools {
            let b = DockButton(symbol: symbol, hint: tip)
            b.onClick = { [weak self] in
                self?.flyout.close()
                self?.controller.setMode(.draw(tool))
            }
            toolButtons[tool] = b
            drawItems.append(b)
        }
        // The color chip closes out the Draw group.
        swatch = DockSwatch()
        swatch.hint = Shortcuts.hint("Ink color")
        swatch.onClick = { [weak self] in self?.toggleFlyout() }
        drawItems.append(swatch)
        sections.append(DockGroup(drawItems))

        func action(_ symbol: String, _ tip: String, _ run: @escaping () -> Void) -> DockButton {
            let b = DockButton(symbol: symbol, hint: tip)
            b.onClick = { [weak self] in
                self?.flyout.close()
                run()
            }
            return b
        }
        sections.append(DockGroup([
            action("camera.viewfinder", Shortcuts.hint("Snapshot screen", .snapshot)) { [weak self] in
                self?.controller.snapshot(.screenUnderMouse)
            },
            action("crop", Shortcuts.hint("Region capture", .region) + " · ⇧-click: burst "
                   + Shortcuts.Global.burst.label) { [weak self] in
                // ⇧-click starts a burst (several regions, Esc when done).
                if NSEvent.modifierFlags.contains(.shift) {
                    self?.controller.startBurst()
                } else {
                    self?.controller.snapshot(.region)
                }
            },
            action("pencil.and.outline", Shortcuts.hint("Capture drawing")) { [weak self] in
                self?.controller.captureDrawing()
            },
            recordButton,
        ]))

        // Clipboard history: its own group above Off. Toggles the right-edge sidebar.
        let clipboard = action("doc.on.clipboard", "Clipboard history  " + ClipboardHistoryController.hotkeyLabel) {
            ClipboardHistoryController.shared.toggle()
        }
        clipboardButton = clipboard
        sections.append(DockGroup([clipboard]))

        let off = DockButton(symbol: "xmark.circle", hint: "Off (hide ink)")
        off.onClick = { [weak self] in
            self?.controller.setMode(.off)
            self?.setExpanded(false)
        }
        sections.append(off)

        let total = sections.reduce(Self.sectionPadding * 2 + Self.sectionGap * CGFloat(sections.count - 1)) {
            $0 + $1.frame.height
        }
        toolbar.frame = NSRect(x: 0, y: 0, width: w, height: total)
        sections.forEach(toolbar.addSubview)
        layoutSections()
    }

    /// Stacks the sections from the handle end: handle on top when growing down,
    /// on the bottom (order reversed) when growing up.
    private func layoutSections() {
        let w = Self.expandedWidth
        let order = direction == .down ? sections : sections.reversed()
        var y = toolbar.frame.height - Self.sectionPadding
        for section in order {
            y -= section.frame.height
            section.frame.origin = NSPoint(x: (w - section.frame.width) / 2, y: y)
            y -= Self.sectionGap
        }
    }

    /// Distance from the toolbar's handle end to the handle's center.
    private var handleOffset: CGFloat { Self.sectionPadding + handleSpacer.frame.height / 2 }

    private var expandedHeight: CGFloat { toolbar.frame.height }

    /// Reflects the current mode and color.
    // MARK: Peek (collapsed tile half-hidden at rest)

    /// Fully out while hovered, dragged, drawing (ink ring), recording (red dot), open or
    /// just collapsed; otherwise half hidden past the edge.
    private var shouldBeOut: Bool {
        hovering || draggingTile || holdOut || isExpanded
            || controller.mode.isDrawing || controller.recorder.isRecording
    }

    private func hoverChanged(_ inside: Bool) {
        restWork?.cancel()
        if inside {
            if !hovering {
                hovering = true
                if isExpanded { applyLayout(expanded: true, duration: 0.14) } else { updatePeek() }
            }
            return
        }
        // Leaving: wait a moment so a quick pass doesn't make it flicker.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hovering = false
                if self.isExpanded { self.applyLayout(expanded: true, duration: 0.14) } else { self.updatePeek() }
            }
        }
        restWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restDelay, execute: work)
    }

    /// Slides the collapsed tile out or back in if its state changed (no slide with Reduce Motion).
    private func updatePeek() {
        guard !isExpanded else { return }
        let out = shouldBeOut
        let changed = out != tileIsOut
        tileIsOut = out
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        applyLayout(expanded: false, duration: changed && !reduce ? Self.peekDuration : (changed ? 0 : 0.14))
    }

    private func artAngle(expanded: Bool) -> CGFloat {
        if expanded || controller.mode.isDrawing { return DockPencilView.openAngle }
        return tileIsOut && hovering ? DockPencilView.hoverAngle : DockPencilView.uprightAngle
    }

    func refresh() {
        updateEditPill(duration: 0.18)
        pencil.ringColor = controller.mode.isDrawing ? nsColor(controller.color) : nil
        pencil.setArtAngle(artAngle(expanded: isExpanded),
                           animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let recording = controller.recorder.isRecording
        pencil.isRecording = recording
        recordButton.isSelected = recording
        recordButton.contentTint = recording ? .systemRed : nil
        recordButton.hint = Shortcuts.hint(recording ? "Stop recording" : "Screen recording", .record)
        for (tool, b) in toolButtons {
            let active = controller.mode.tool == tool
            b.isSelected = active
            // The active tool's icon takes the ink color.
            b.contentTint = active ? nsColor(controller.color) : nil
        }
        swatch.color = controller.color
        swatch.isOpen = flyout.isOpen
        flyout.select(controller.color)
        // Picking a mode (from the dock, a hotkey or Esc) closes the color flyout.
        if let lastMode, lastMode != controller.mode { flyout.close() }
        lastMode = controller.mode
        updatePeek()
    }

    // MARK: Color flyout

    private func toggleFlyout() {
        if flyout.isOpen {
            flyout.close()
        } else {
            // Level with the swatch, just right of the toolbar.
            let onScreen = panel.convertToScreen(swatch.convert(swatch.bounds, to: nil))
            flyout.open(anchorX: expandedTarget.maxX + 2, centerY: onScreen.midY, selected: controller.color)
        }
        swatch.isOpen = flyout.isOpen
    }

    // MARK: Expand / collapse (one pencil, morphing)

    func toggleExpanded() { setExpanded(!isExpanded) }

    func setExpanded(_ expand: Bool) {
        guard expand != isExpanded else { return }
        isExpanded = expand
        generation += 1
        let gen = generation
        if !expand { flyout.close() }
        HintCenter.shared.hide()

        if expand {
            // 1. Work out the final, anchored and clamped frame up front.
            let layout = expandedLayout(preferring: .down)
            direction = layout.direction
            expandedTarget = layout.frame
            layoutSections()
            updateEditPill(duration: Self.duration)
            // 2. Grow the (transparent) panel instantly to cover both states,
            //    keeping everything visually where it is.
            setPanelFrame(expandedTarget.union(collapsedFrame()))
            applyLayout(expanded: false, duration: 0)
            background.isHidden = false
            toolbar.isHidden = false
            // 3. Animate only the layers.
            applyLayout(expanded: true, duration: Self.duration) { [weak self] in
                guard let self, self.generation == gen else { return }
                // 4. Trim the panel to the toolbar so nothing outside it catches clicks.
                self.setPanelFrame(self.expandedTarget)
                self.applyLayout(expanded: true, duration: 0)
                self.panel.hasShadow = true
                self.panel.invalidateShadow()
            }
        } else {
            holdOut = true
            tileIsOut = true
            panel.hasShadow = false
            updateEditPill(duration: Self.duration)
            setPanelFrame(expandedTarget.union(collapsedFrame()))
            applyLayout(expanded: true, duration: 0)
            applyLayout(expanded: false, duration: Self.duration) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.background.isHidden = true
                self.toolbar.isHidden = true
                // Shrink the panel back to the tab only after the animation finished.
                self.setPanelFrame(self.collapsedFrame())
                self.applyLayout(expanded: false, duration: 0)
                // Back at the full position; slide in once the mouse isn't over it.
                self.holdOut = false
                self.updatePeek()
            }
        }
    }

    /// Resizes the panel without animation.
    private func setPanelFrame(_ frame: NSRect) {
        guard panel.frame != frame else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(frame, display: false)
            container.frame = NSRect(origin: .zero, size: frame.size)
            CATransaction.commit()
        }
    }

    private func local(_ r: NSRect) -> NSRect {
        r.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
    }

    /// Places the pencil, background and sections for a state (in the panel's
    /// current coordinates), animating everything together when duration > 0.
    private func applyLayout(expanded: Bool, duration: CFTimeInterval, completion: (() -> Void)? = nil) {
        let tab = local(tabScreenRect())
        let pencilState: DockPencilView.State
        let bgRect: NSRect
        let toolbarOrigin: NSPoint
        let toolbarAlpha: CGFloat

        let finalToolbar = local(expandedTarget)
        let slide = direction == .down ? Self.slide : -Self.slide
        if expanded {
            let cy = direction == .down ? finalToolbar.maxY - handleOffset : finalToolbar.minY + handleOffset
            // Same flush spot and size as the collapsed tile.
            pencilState = .handle(NSRect(x: finalToolbar.minX, y: cy - Self.tileSize.height / 2,
                                         width: Self.tileSize.width, height: Self.tileSize.height))
            bgRect = NSRect(x: finalToolbar.minX, y: finalToolbar.minY, width: Self.expandedWidth,
                            height: finalToolbar.height)
            toolbarOrigin = finalToolbar.origin
            toolbarAlpha = 1
        } else {
            pencilState = .tab(tab)
            // The background starts as the pencil tile itself and grows out of it.
            bgRect = tab
            // Sections sit slightly tucked toward the handle while hidden.
            toolbarOrigin = NSPoint(x: finalToolbar.minX, y: finalToolbar.minY + slide)
            toolbarAlpha = 0
        }

        // The pencil tips over as the toolbar opens (same start time), stands back up as
        // it closes, and tips on hover. While a drawing mode is on it stays "down", writing.
        pencil.setArtAngle(artAngle(expanded: expanded),
                           animated: duration > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = Self.timing
            ctx.allowsImplicitAnimation = duration > 0
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(Self.timing)
            CATransaction.setDisableActions(duration == 0)

            pencil.apply(pencilState, hover: hovering, hidden: expanded || tileIsOut ? 0 : Self.peekHidden)
            if duration > 0 {
                background.animator().frame = bgRect
                toolbar.animator().setFrameOrigin(toolbarOrigin)
            } else {
                background.frame = bgRect
                toolbar.setFrameOrigin(toolbarOrigin)
            }
            CATransaction.commit()
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })

        // Sections fade on their own, quicker on the way out.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration == 0 ? 0 : (expanded ? duration : duration * 0.55)
            ctx.timingFunction = Self.timing
            if duration > 0 {
                toolbar.animator().alphaValue = toolbarAlpha
            } else {
                toolbar.alphaValue = toolbarAlpha
            }
        }
    }

    // MARK: Snapshots

    /// Esc while the flyout is open closes it. Returns true if it did.
    func handleEscape() -> Bool {
        guard flyout.isOpen else { return false }
        flyout.close()
        return true
    }

    // MARK: Geometry & dragging

    private var screen: NSScreen {
        NSScreen.screens.first { $0.displayID == screenID } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func centerY(on screen: NSScreen) -> CGFloat { screen.visibleFrame.minY + offsetY }

    private func collapsedFrame() -> NSRect {
        let s = screen
        let size = Self.collapsedSize
        let y = DockGeometry.clampY(centerY(on: s) - size.height / 2, height: size.height, in: s.visibleFrame)
        return NSRect(x: s.frame.minX, y: y, width: size.width, height: size.height)
    }

    /// The tab's own rect on screen (inside the collapsed panel's margins).
    /// The collapsed tile fully out (its anchor), or half hidden past the edge at rest.
    private func tabScreenRect() -> NSRect {
        let c = collapsedFrame()
        let hidden = tileIsOut ? 0 : Self.peekHidden
        return NSRect(x: c.minX - hidden, y: c.midY - Self.tileSize.height / 2,
                      width: Self.tileSize.width, height: Self.tileSize.height)
    }

    /// The open toolbar's frame, with the handle centered where the tab is.
    private func expandedLayout(preferring preferred: DockGeometry.GrowDirection)
        -> (frame: NSRect, direction: DockGeometry.GrowDirection) {
        let s = screen
        return DockGeometry.anchoredFrame(anchorY: collapsedFrame().midY, handleOffset: handleOffset,
                                          x: s.frame.minX, width: Self.expandedWidth,
                                          height: expandedHeight,
                                          in: s.visibleFrame, preferring: preferred)
    }

    /// Re-anchors after the tab position or screen changed (no animation).
    private func relayoutInPlace() {
        if isExpanded {
            let layout = expandedLayout(preferring: direction)
            if layout.direction != direction {
                direction = layout.direction
                layoutSections()
            }
            expandedTarget = layout.frame
            setPanelFrame(layout.frame)
        } else {
            expandedTarget = expandedLayout(preferring: .down).frame
            setPanelFrame(collapsedFrame())
        }
        applyLayout(expanded: isExpanded, duration: 0)
        if isExpanded { panel.invalidateShadow() }
        updateEditPill(duration: 0)
    }

    // MARK: Undo / Clear pill

    /// Shows the pill while there's persistent ink, placed past the dock's far end (below
    /// the tile when collapsed; opposite the handle when open), and moves it with the dock.
    private func updateEditPill(duration: CFTimeInterval) {
        guard controller.store.hasPersistentInk else {
            editPill.hide(duration: duration == 0 ? 0 : 0.18)
            return
        }
        let s = screen
        let anchor: NSRect
        let preferBelow: Bool
        if isExpanded {
            anchor = NSRect(x: expandedTarget.minX, y: expandedTarget.minY,
                            width: Self.expandedWidth, height: expandedTarget.height)
            preferBelow = direction == .down
        } else {
            // The tile's fully-out rect: the pill doesn't peek.
            let c = collapsedFrame()
            anchor = NSRect(x: c.minX, y: c.midY - Self.tileSize.height / 2,
                            width: Self.tileSize.width, height: Self.tileSize.height)
            preferBelow = true
        }
        let frame = DockGeometry.editPillFrame(anchor: anchor, x: s.frame.minX, size: EditPill.size,
                                               preferBelow: preferBelow, in: s.visibleFrame)
        editPill.show(at: frame, duration: duration)
    }

    /// Mouse Y and dock offset when the current drag started (or last changed screen).
    private var dragBase: (mouseY: CGFloat, offset: CGFloat)?

    /// `start` and `now` are global mouse locations. Vertical only; moving the
    /// mouse onto another screen moves the dock to that screen's left edge.
    private func drag(from start: NSPoint, to now: NSPoint) {
        flyout.close()
        HintCenter.shared.hide()
        if let target = NSScreen.screens.first(where: { NSMouseInRect(now, $0.frame, false) }),
           target.displayID != screenID {
            screenID = target.displayID
            dragBase = (now.y, now.y - target.visibleFrame.minY)
        }
        let base = dragBase ?? (start.y, offsetY)
        dragBase = base
        offsetY = base.offset + (now.y - base.mouseY)
        // Keep the tab (and so the handle) inside the visible frame.
        offsetY = collapsedFrame().midY - screen.visibleFrame.minY
        relayoutInPlace()
    }

    private func savePosition() {
        dragBase = nil
        let d = UserDefaults.standard
        d.set(Double(offsetY), forKey: Key.offsetY)
        d.set(Int(screenID), forKey: Key.displayID)
    }

    private func restorePosition() {
        let d = UserDefaults.standard
        let savedID = CGDirectDisplayID(d.integer(forKey: Key.displayID))
        if NSScreen.screens.contains(where: { $0.displayID == savedID }) {
            screenID = savedID
        } else {
            screenID = (NSScreen.main ?? NSScreen.screens[0]).displayID
        }
        if d.object(forKey: Key.offsetY) != nil {
            offsetY = CGFloat(d.double(forKey: Key.offsetY))
        } else {
            offsetY = screen.visibleFrame.height * 0.6
        }
        expandedTarget = expandedLayout(preferring: .down).frame
    }

    /// Screens changed: re-dock to the saved screen or fall back to the main one.
    func screensChanged() {
        if !NSScreen.screens.contains(where: { $0.displayID == screenID }) {
            screenID = (NSScreen.main ?? NSScreen.screens[0]).displayID
        }
        relayoutInPlace()
    }

    // MARK: Helpers

    /// A resizable mask: square on the left (flush to the edge), rounded on the right.
    private static func rightRoundedMask(radius r: CGFloat) -> NSImage {
        let size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: morphPath(rect, left: 0, right: r)).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}

/// Plain container that lets clicks on empty space fall through its subviews.
final class DockContainer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A rounded rect with separate left/right corner radii, always built from the
/// same path elements so Core Animation can morph between any two of them.
func morphPath(_ r: CGRect, left: CGFloat, right: CGFloat) -> CGPath {
    let k: CGFloat = 0.4477 // 1 - 0.5523: cubic control distance for a quarter circle
    let lr = min(left, r.width / 2, r.height / 2), rr = min(right, r.width / 2, r.height / 2)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + lr, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - rr, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + rr),
               control1: CGPoint(x: r.maxX - rr * k, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + rr * k))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rr))
    p.addCurve(to: CGPoint(x: r.maxX - rr, y: r.maxY),
               control1: CGPoint(x: r.maxX, y: r.maxY - rr * k), control2: CGPoint(x: r.maxX - rr * k, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + lr, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - lr),
               control1: CGPoint(x: r.minX + lr * k, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - lr * k))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + lr))
    p.addCurve(to: CGPoint(x: r.minX + lr, y: r.minY),
               control1: CGPoint(x: r.minX, y: r.minY + lr * k), control2: CGPoint(x: r.minX + lr * k, y: r.minY))
    p.closeSubpath()
    return p
}

// MARK: - The one pencil

/// The persistent pencil: a gradient tile with the pencil art, a soft shadow,
/// a two-tone border and an ink-color ring. `apply(_:)` morphs its layers between
/// the collapsed tab and the toolbar handle; the view itself never moves.
final class DockPencilView: DragSurface {
    enum State {
        /// The visible tab rect, flush with the screen edge.
        case tab(NSRect)
        /// The handle squircle's rect.
        case handle(NSRect)
    }

    var onHover: ((Bool) -> Void)?
    var ringColor: NSColor? { didSet { updateRing() } }
    /// Small red dot on the pencil while a screen recording runs.
    var isRecording = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            recDot.isHidden = !isRecording
            CATransaction.commit()
        }
    }
    private let recDot = CALayer()

    private let holder = CALayer()        // carries the shadow
    private let tile = CALayer()          // gradient, clipped by `shape`
    private let shape = CAShapeLayer()    // mask
    private let darkBorder = CAShapeLayer()
    private let lightBorder = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let art = CALayer()
    private var activeRect: NSRect = .zero
    private var isTab = true

    private static let cornerRadius: CGFloat = 9
    /// How far the tile extends past the screen edge (hidden there).
    private static let bleed: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let root = layer else { return }
        tile.contents = IconArt.backgroundImage(pixels: 256)
        tile.contentsGravity = .resize
        tile.mask = shape
        for s in [darkBorder, lightBorder, ring] {
            s.fillColor = nil
            tile.addSublayer(s)
        }
        darkBorder.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
        darkBorder.lineWidth = 2 // half of it is clipped by the mask
        lightBorder.lineWidth = 1
        ring.lineWidth = 5       // shows 2.5pt inside the mask
        ring.isHidden = true
        // Drawn upright; the layer's rotation tilts it (0 = upright, −45° = the icon's diagonal).
        art.contents = IconArt.pencilImage(pixels: 192, angleDegrees: 90)
        art.contentsGravity = .resizeAspect
        holder.addSublayer(tile)
        holder.addSublayer(art)
        recDot.backgroundColor = NSColor.systemRed.cgColor
        recDot.cornerRadius = 4
        recDot.borderWidth = 1
        recDot.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        recDot.isHidden = true
        holder.addSublayer(recDot)
        holder.shadowOffset = CGSize(width: 0, height: -1)
        root.addSublayer(holder)
        updateScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for l in [holder, tile, shape, darkBorder, lightBorder, ring, art] { l.contentsScale = scale }
    }

    /// Pencil angles (radians, positive = counterclockwise). Upright at rest, tipped to the
    /// icon's diagonal when hovered and while the toolbar is open.
    static let uprightAngle: CGFloat = 0
    static let hoverAngle: CGFloat = openAngle
    static let openAngle: CGFloat = -45 * .pi / 180
    private var artAngle: CGFloat = 0

    /// Rotates only the art, with a light spring from wherever it is right now (so an
    /// interrupted open/close never snaps). `animated: false` jumps (Reduce Motion).
    func setArtAngle(_ angle: CGFloat, animated: Bool) {
        // Same target: let a running spring finish instead of snapping it.
        guard angle != artAngle else { return }
        let current = (art.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? artAngle
        art.removeAnimation(forKey: "tilt")
        artAngle = angle
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        guard animated, abs(current - angle) > 0.001 else { return }
        let spring = CASpringAnimation(keyPath: "transform.rotation.z")
        spring.fromValue = current
        spring.toValue = angle
        spring.mass = 1
        spring.stiffness = 190
        spring.damping = 15 // settles in ~0.4s with a small overshoot
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        art.add(spring, forKey: "tilt")
    }

    /// Sets every layer for `state`. Call inside a CATransaction to animate.
    /// `hidden`: how much of the tile is tucked past the screen edge (the art centers
    /// in what's visible).
    func apply(_ state: State, hover: Bool, hidden: CGFloat = 0) {
        let tileFrame: CGRect, left: CGFloat, right: CGFloat, artFrame: CGRect
        switch state {
        // Collapsed and open, the pencil is the same edge tile in the same place; only the
        // toolbar grows out of it. The tile extends `bleed` past the screen edge, so its
        // square left side, and the borders and ring along it, are off-screen.
        case .tab(let r), .handle(let r):
            if case .tab = state { isTab = true } else { isTab = false }
            activeRect = CGRect(x: r.minX, y: r.minY - 3, width: r.width + 3, height: r.height + 6)
            tileFrame = CGRect(x: r.minX - Self.bleed, y: r.minY, width: r.width + Self.bleed, height: r.height)
            left = 0
            right = Self.cornerRadius
            let a: CGFloat = 30
            let visibleMidX = Self.bleed + hidden + (r.width - hidden) / 2
            artFrame = CGRect(x: visibleMidX - a / 2, y: (r.height - a) / 2, width: a, height: a)
        }
        let bounds = CGRect(origin: .zero, size: tileFrame.size)
        let path = morphPath(bounds, left: left, right: right)

        holder.frame = tileFrame
        holder.shadowPath = path
        // Hover lifts the tile slightly (a touch deeper shadow + brighter edge), no colored halo.
        holder.shadowColor = NSColor.black.cgColor
        // Small and soft so it stays well inside the panel (a clipped shadow reads as a box).
        holder.shadowOpacity = 0.22 + (hover ? 0.12 : 0)
        holder.shadowRadius = 3 + (hover ? 1.5 : 0)
        tile.frame = bounds
        shape.frame = bounds
        shape.path = path
        darkBorder.frame = bounds
        darkBorder.path = path
        lightBorder.frame = bounds
        lightBorder.path = morphPath(bounds.insetBy(dx: 1.5, dy: 1.5), left: max(0, left - 1.5), right: right - 1.5)
        lightBorder.strokeColor = NSColor.white.withAlphaComponent(hover ? 0.45 : 0.28).cgColor
        ring.frame = bounds
        ring.path = path
        // bounds + position (not frame): the layer carries a rotation.
        art.bounds = CGRect(origin: .zero, size: artFrame.size)
        art.position = CGPoint(x: artFrame.midX, y: artFrame.midY)
        recDot.frame = CGRect(x: bounds.maxX - 12, y: bounds.maxY - 12, width: 8, height: 8)

        hint = isTab ? "Pencil — click to open" : "Pencil — click to collapse, drag to move"
        updateTrackingAreas()
    }

    private func updateRing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.isHidden = ringColor == nil
        ring.strokeColor = ringColor?.cgColor
        CATransaction.commit()
    }

    /// Only the pencil's current rect takes clicks; everything else falls through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return hotRect.contains(p) ? self : nil
    }

    /// The clickable/hoverable area: the tile plus a few points.
    private var hotRect: CGRect { activeRect }

    override var trackingRect: NSRect { hotRect }
    override func hoverChanged(_ inside: Bool) { onHover?(inside) }
}

func nsColor(_ c: InkColor) -> NSColor {
    NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
}

// MARK: - Panel

final class DockPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Above the ink overlay (.screenSaver) so the overlay never eats dock clicks.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    // Never take key focus away from the user's app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controls

/// Base for every dock control: tells a click from a drag using a small movement
/// threshold (reporting global mouse locations), tracks hover, and shows a custom
/// hint (standard tooltips don't appear for a non-activating panel of a background app).
class DragSurface: NSView {
    var onClick: (() -> Void)?
    var onDrag: ((_ start: NSPoint, _ now: NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    /// Text for the hover hint, e.g. "Pen  ⌥2".
    var hint: String?
    var hintPlacement: HintCenter.Placement = .right
    /// The area that counts as "hovering" (and anchors the hint). Override to narrow it.
    var trackingRect: NSRect { bounds }
    private(set) var isHovering = false

    private var downPoint: NSPoint?
    private var dragging = false
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: trackingRect, options: [.activeAlways, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        hoverChanged(true)
        if let hint, let window {
            let anchor = window.convertToScreen(convert(trackingRect, to: nil))
            HintCenter.shared.schedule(hint, anchor: anchor, placement: hintPlacement, owner: self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoverChanged(false)
        HintCenter.shared.cancel(owner: self)
    }

    /// Subclasses react to hover here.
    func hoverChanged(_ inside: Bool) {}

    override func mouseDown(with event: NSEvent) {
        HintCenter.shared.hide()
        downPoint = NSEvent.mouseLocation
        dragging = false
        pressChanged(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let now = NSEvent.mouseLocation
        if !dragging, DockGeometry.isDrag(from: start, to: now), onDrag != nil {
            dragging = true
            pressChanged(false)
        }
        if dragging { onDrag?(start, now) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil; dragging = false }
        pressChanged(false)
        if dragging {
            onDragEnd?()
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    func pressChanged(_ pressed: Bool) {}
}

final class DockButton: DragSurface {
    private let imageView = NSImageView()
    private var pressed = false { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true; updateTint() } }
    var contentTint: NSColor? { didSet { updateTint() } }

    init(symbol: String, hint: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 32))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: hint)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: hint)
        imageView.image = image
        imageView.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        imageView.imageScaling = .scaleNone
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        self.hint = hint
        setAccessibilityLabel(hint)
        setAccessibilityRole(.button)
        updateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateTint() {
        imageView.contentTintColor = contentTint ?? (isSelected ? .white : NSColor.white.withAlphaComponent(0.8))
    }

    override func hoverChanged(_ inside: Bool) { needsDisplay = true }
    override func pressChanged(_ pressed: Bool) { self.pressed = pressed }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isSelected ? 0.28 : (pressed ? 0.22 : (isHovering ? 0.12 : 0))
        guard alpha > 0 else { return }
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
    }
}

/// One color in the flyout: a small rounded square.
final class DockColorDot: DragSurface {
    let inkColor: InkColor
    var isSelected = false { didSet { needsDisplay = true } }

    init(color: InkColor, width: CGFloat = 34) {
        inkColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        setAccessibilityLabel(color.name)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hoverChanged(_ inside: Bool) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = isHovering ? 16 : 14
        let chip = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        nsColor(inkColor).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.45).setStroke()
        let inner = NSBezierPath(roundedRect: chip.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.3, yRadius: 3.3)
        inner.lineWidth = 0.75
        inner.stroke()
        if isSelected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(roundedRect: chip.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6)
            ring.lineWidth = 1.75
            ring.stroke()
        }
    }
}

// MARK: - Hover hints

/// A small dark label next to the hovered control. Its own click-through,
/// non-activating panel above the dock, so it shows even while Pencil is in the background.
@MainActor
final class HintCenter {
    static let shared = HintCenter()

    enum Placement { case right, above, below, left }

    private let panel: NSPanel
    private let label: NSTextField
    private var pending: DispatchWorkItem?
    private weak var owner: NSView?
    private static let delay: TimeInterval = 0.35

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        bg.layer?.cornerRadius = 6
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        bg.addSubview(label)
        panel.contentView = bg
    }

    func schedule(_ text: String, anchor: NSRect, placement: Placement, owner: NSView) {
        pending?.cancel()
        self.owner = owner
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.show(text, anchor: anchor, placement: placement) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// Hides the hint if it belongs to `owner` (mouse left that control).
    func cancel(owner: NSView) {
        guard self.owner === owner else { return }
        hide()
    }

    func hide() {
        pending?.cancel()
        pending = nil
        owner = nil
        panel.orderOut(nil)
    }

    private func show(_ text: String, anchor: NSRect, placement: Placement) {
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + 16, height: ceil(label.frame.height) + 8)
        label.frame.origin = NSPoint(x: 8, y: 4)
        var origin: NSPoint
        switch placement {
        case .right: origin = NSPoint(x: anchor.maxX + 8, y: anchor.midY - size.height / 2)
        case .above: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 6)
        case .below: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        case .left: origin = NSPoint(x: anchor.minX - size.width - 8, y: anchor.midY - size.height / 2)
        }
        // Keep it on the screen it belongs to.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: anchor.midX, y: anchor.midY), $0.frame, false) }) {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX), v.maxX - size.width)
            origin.y = min(max(origin.y, v.minY), v.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

// MARK: - Toolbar sections

/// A subtle rounded group behind related toolbar items (like macOS toolbar groups).
final class DockGroup: NSView {
    static let width: CGFloat = 40
    private static let inset: CGFloat = 2

    init(_ items: [NSView]) {
        let h = items.reduce(Self.inset * 2) { $0 + $1.frame.height }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: h))
        var y = h - Self.inset
        for item in items {
            y -= item.frame.height
            item.frame.origin = NSPoint(x: (Self.width - item.frame.width) / 2, y: y)
            addSubview(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.white.withAlphaComponent(0.07).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.06).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The ink-color chip: a rounded square in the current color with a light inner border.
final class DockSwatch: DragSurface {
    var color: InkColor = .red { didSet { needsDisplay = true } }
    var isOpen = false { didSet { needsDisplay = true } }
    var onHoverChange: ((Bool) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 32))
        setAccessibilityLabel("Ink color")
        setAccessibilityRole(.popUpButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hoverChanged(_ inside: Bool) {
        needsDisplay = true
        onHoverChange?(inside)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering || isOpen {
            NSColor.white.withAlphaComponent(isOpen ? 0.22 : 0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
        let side: CGFloat = 18
        let chip = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        nsColor(color).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
        // Thin dark edge so white/yellow read on the light group background, light inner edge on top.
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let edge = NSBezierPath(roundedRect: chip.insetBy(dx: 0.25, dy: 0.25), xRadius: 5, yRadius: 5)
        edge.lineWidth = 0.5
        edge.stroke()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let inner = NSBezierPath(roundedRect: chip.insetBy(dx: 1.5, dy: 1.5), xRadius: 3.8, yRadius: 3.8)
        inner.lineWidth = 1
        inner.stroke()
    }
}

// MARK: - Color flyout

/// A small pill of the five colors that slides out to the right of the swatch.
/// It's its own non-activating panel at the dock's level, so it sits above the
/// ink overlay, takes clicks, and never steals focus.
@MainActor
final class ColorFlyout {
    private static let dotWidth: CGFloat = 28
    private static let pad: CGFloat = 6
    static let size = NSSize(width: CGFloat(InkColor.palette.count) * dotWidth + pad * 2, height: 34)

    private let panel: DockPanel
    private var dots: [DockColorDot] = []
    private var monitors: [Any] = []
    private(set) var isOpen = false

    /// The dock's own panel: clicks there don't count as "clicking elsewhere".
    weak var companion: NSWindow?
    var onPick: ((InkColor) -> Void)?
    var onOpenChange: ((Bool) -> Void)?

    init() {
        let size = Self.size
        panel = DockPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.hasShadow = true

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.maskImage = Self.pillMask(height: size.height)
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        for (i, c) in InkColor.palette.enumerated() {
            let dot = DockColorDot(color: c, width: Self.dotWidth)
            dot.frame.origin = NSPoint(x: Self.pad + CGFloat(i) * Self.dotWidth, y: (size.height - dot.frame.height) / 2)
            dot.hint = c.name
            dot.hintPlacement = .above // to the right would cover the next color
            dot.onClick = { [weak self] in self?.onPick?(c) }
            dots.append(dot)
            effect.addSubview(dot)
        }
        let border = PillBorder(frame: effect.bounds)
        border.autoresizingMask = [.width, .height]
        effect.addSubview(border)
    }

    func select(_ color: InkColor) {
        for dot in dots { dot.isSelected = dot.inkColor == color }
    }

    func open(anchorX x: CGFloat, centerY: CGFloat, selected: InkColor) {
        guard !isOpen else { return }
        select(selected)
        isOpen = true
        let size = Self.size
        let target = NSRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
        panel.setFrame(NSRect(x: x, y: target.minY, width: size.height, height: size.height), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        installMonitors()
        onOpenChange?(true)
    }

    func close() {
        guard isOpen else { return }
        HintCenter.shared.hide()
        isOpen = false
        removeMonitors()
        onOpenChange?(false)
        let f = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(NSRect(x: f.minX, y: f.minY, width: f.height, height: f.height), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Clicking anywhere else closes the flyout. Global mouse monitors need no
    /// Accessibility permission (only key monitors do); a local monitor covers
    /// clicks on Pencil's own windows such as the ink overlay.
    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                          handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The flyout's own dots and the dock (whose swatch toggles it) handle themselves.
                if event.window !== self.panel, event.window !== self.companion { self.close() }
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private static func pillMask(height h: CGFloat) -> NSImage {
        let r = h / 2
        let image = NSImage(size: NSSize(width: h + 1, height: h), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}

/// Hairline border for the flyout pill, matching the toolbar's look.
final class PillBorder: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Undo / Clear pill

/// A small floating pill on the screen edge with Undo and Clear, shown only while there's
/// ink. Same dark look as the toolbar: square and borderless on the edge side, rounded
/// outer corners, window shadow that follows the shape. Its own non-activating panel at
/// the dock's level (above the ink, and left out of captures as a Pencil window).
@MainActor
final class EditPill {
    static let size = NSSize(width: 36, height: 66)

    var onUndo: (() -> Void)?
    var onClear: (() -> Void)?

    private let panel: DockPanel
    private var isShown = false
    private var generation = 0
    /// How far it slides out of the edge when appearing.
    private static let slide: CGFloat = 10

    init() {
        let size = Self.size
        panel = DockPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.hasShadow = true

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.maskImage = Self.edgeMask(radius: 9)
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        let undo = DockButton(symbol: "arrow.uturn.backward", hint: "Undo · Z")
        let clear = DockButton(symbol: "trash", hint: "Clear all · X")
        undo.onClick = { [weak self] in self?.onUndo?() }
        clear.onClick = { [weak self] in self?.onClear?() }
        undo.frame.origin = NSPoint(x: (size.width - undo.frame.width) / 2, y: size.height - 1 - undo.frame.height)
        clear.frame.origin = NSPoint(x: (size.width - clear.frame.width) / 2, y: 1)
        effect.addSubview(undo)
        effect.addSubview(clear)
    }

    /// Shows (fade + slide out of the edge) or moves it to `frame`.
    func show(at frame: NSRect, duration: CFTimeInterval) {
        generation += 1
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !isShown {
            isShown = true
            panel.setFrame(reduce ? frame : frame.offsetBy(dx: -Self.slide, dy: 0), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        let d = duration == 0 ? 0 : max(duration, 0.18)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = d
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide(duration: CFTimeInterval) {
        guard isShown else { return }
        isShown = false
        generation += 1
        let gen = generation
        HintCenter.shared.hide()
        let f = panel.frame
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if !reduce { panel.animator().setFrame(f.offsetBy(dx: -Self.slide, dy: 0), display: true) }
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Square on the edge (left) side, rounded on the right.
    private static func edgeMask(radius r: CGFloat) -> NSImage {
        let size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: morphPath(rect, left: 0, right: r)).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}
