import AppKit
import PencilCore

/// Owns the ink, the mode, and the per-screen overlay windows.
@MainActor
final class AppController {
    let store = InkStore()
    let toast = Toast()

    private(set) var mode: Mode = .off
    private(set) var lastDrawingTool: Tool = .pen
    private(set) var color: InkColor = .red

    /// Called after any change the UI should reflect (mode, color, ink).
    var onStateChange: (() -> Void)?
    /// Called around a snapshot so floating UI (the dock) can get out of the picture.
    var willCapture: (() -> Void)?
    /// Gets first chance at Esc (the dock uses it to close the color flyout).
    var escapeInterceptor: (() -> Bool)?

    private var overlays: [OverlayWindow] = []
    /// The app that had focus before drawing started; it gets focus back afterwards.
    private var previousApp: NSRunningApplication?
    let shortcutsHUD = ShortcutsHUD()
    let recorder = ScreenRecorder()
    private var fadeTimer: Timer?
    private var isCapturing = false

    func start() {
        recorder.toast = toast
        recorder.inkWindowNumbers = { [weak self] in self?.overlays.map(\.windowNumber) ?? [] }
        recorder.onStateChange = { [weak self] _ in
            self?.rekeyOverlayIfDrawing() // the area picker took the keyboard
            self?.onStateChange?()
        }
        rebuildOverlays()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildOverlays() }
        }
    }

    // MARK: Overlays

    private func rebuildOverlays() {
        store.end()
        overlays.forEach { $0.orderOut(nil); $0.close() }
        overlays = NSScreen.screens.map { OverlayWindow(screen: $0, controller: self) }
        applyMode()
    }

    private func applyMode() {
        switch mode {
        case .off:
            overlays.forEach { $0.orderOut(nil) }
            restoreFocus()
        case .passThrough:
            let hadKey = overlays.contains(where: \.isKeyWindow)
            for w in overlays {
                w.ignoresMouseEvents = true
                // Re-ordering front drops key status without hiding the ink.
                if w.isKeyWindow { w.orderOut(nil) }
                w.orderFrontRegardless()
                w.invalidateCursorRects(for: w.overlayView)
            }
            if hadKey { restoreFocus() }
        case .draw:
            if previousApp == nil {
                let front = NSWorkspace.shared.frontmostApplication
                if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
            }
            for w in overlays {
                w.ignoresMouseEvents = false
                w.orderFrontRegardless()
                w.invalidateCursorRects(for: w.overlayView)
            }
            // The overlay is a non-activating panel that can become key, so the in-draw
            // keys work right away (even from a global hotkey) without activating Pencil.
            let target = overlayUnderMouse() ?? overlays.first
            target?.makeKeyAndOrderFront(nil)
            target?.makeFirstResponder(target?.overlayView)
            NSCursor.crosshair.set()
        }
        invalidate(nil)
    }

    func rekeyOverlayIfDrawing() {
        guard mode.isDrawing else { return }
        let target = overlayUnderMouse() ?? overlays.first
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.overlayView)
    }

    /// Hands keyboard focus back to the app the user was in before drawing.
    private func restoreFocus() {
        guard let app = previousApp else { return }
        previousApp = nil
        // Only if the user hasn't moved on to another app in the meantime.
        guard !app.isTerminated,
              NSApp.isActive || NSWorkspace.shared.frontmostApplication == app else { return }
        app.activate()
    }

    private func overlayUnderMouse() -> OverlayWindow? {
        let mouse = NSEvent.mouseLocation
        return overlays.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    private func invalidate(_ globalRect: CGRect?) {
        overlays.forEach { $0.invalidate(global: globalRect) }
    }

    // MARK: Mode & color

    func setMode(_ newMode: Mode) {
        invalidate(store.end())
        if let tool = newMode.tool { lastDrawingTool = tool }
        mode = newMode
        applyMode()
        onStateChange?()
    }

    func toggleOff() {
        setMode(mode == .off ? .draw(lastDrawingTool) : .off)
    }

    func setColor(_ c: InkColor) {
        color = c
        onStateChange?()
    }

    func setColor(index: Int) {
        guard InkColor.palette.indices.contains(index) else { return }
        setColor(InkColor.palette[index])
    }

    func undo() {
        invalidate(store.undo())
        onStateChange?()
    }

    func clear() {
        invalidate(store.clear())
        onStateChange?()
    }

    // MARK: Pointer input (global screen coordinates)

    func pointerDown(at p: CGPoint) {
        guard let tool = mode.tool else { return }
        invalidate(store.begin(tool: tool, color: color, at: p, time: CACurrentMediaTime()))
        if tool == .laser { startFadeTimer() }
    }

    func pointerDragged(to p: CGPoint) {
        invalidate(store.extend(to: p, time: CACurrentMediaTime()))
        // The in-progress laser stroke can fully fade while the mouse is held still.
        if mode.tool == .laser { startFadeTimer() }
    }

    func pointerUp() {
        invalidate(store.end())
        onStateChange?()
    }

    /// Keys handled while an overlay has key focus. Returns true if handled.
    func handleLocalKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let command = Shortcuts.localCommand(
            keyCode: event.keyCode, characters: event.characters,
            bareCharacters: event.charactersIgnoringModifiers,
            command: mods.contains(.command), control: mods.contains(.control), option: mods.contains(.option))
        else { return false }
        switch command {
        case .passThrough:
            // Esc peels one layer at a time: the help, then the color flyout, then drawing.
            if shortcutsHUD.isShown { shortcutsHUD.hide(); return true }
            if escapeInterceptor?() == true { return true }
            if mode.isDrawing { setMode(.passThrough) }
        case .tool(let tool): setMode(.draw(tool))
        case .color(let index): setColor(index: index)
        case .undo: undo()
        case .clear: clear()
        case .snapshot: snapshot(.screenUnderMouse)
        case .region: snapshot(.region)
        case .help: shortcutsHUD.show()
        case .captureDrawing: captureDrawing()
        }
        return true
    }

    /// ⌥5: pick an area and start recording, or stop the running recording.
    func toggleRecording() {
        recorder.toggle()
    }

    /// ⌥1 / ⌥2: turn the tool on, or off if it's already on.
    func toggleTool(_ tool: Tool) {
        setMode(Shortcuts.toggled(mode, tool: tool))
    }

    // MARK: Laser fade loop (runs only while fading ink exists)

    private func startFadeTimer() {
        guard fadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func fadeTick() {
        invalidate(store.pruneLaser(now: CACurrentMediaTime()))
        if !store.hasFadingInk {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    // MARK: Snapshot

    /// Return while drawing (and the dock/menu): capture just the drawing, cropped to the
    /// ink on the screen under the mouse plus some context. No ink: the whole screen.
    func captureDrawing() {
        guard let screen = Snapshotter.screenUnderMouse() else { return }
        let bounds = store.visibleStrokes.filter { !$0.points.isEmpty }.map(\.renderBounds)
        if let rect = CapturePlan.inkCropRect(inkBounds: bounds, screenFrame: screen.frame) {
            snapshot(.area(rect))
        } else {
            snapshot(.screenUnderMouse, successMessage: "No ink here, so copied the whole screen")
        }
    }

    /// Area picker for region captures and bursts (the same one recordings use).
    private let regionPicker = RegionSelector()
    /// ⇧⌥4 until Esc: the picker stays up and every capture joins the batch.
    private(set) var burstActive = false

    private func ensureCapturePermission(on screen: NSScreen?) -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            NSLog("Pencil: no Screen Recording access (CGPreflightScreenCaptureAccess returned false)")
            toast.show("Allow Pencil in Screen Recording, then relaunch Pencil", on: screen, isError: true)
            return false
        }
        return true
    }

    /// Still capture. Nothing on screen is hidden: ScreenCaptureKit leaves Pencil's own
    /// UI out of the picture and keeps the ink. During a burst, ⌥3 / ink-fit captures join it.
    func snapshot(_ kind: CaptureKind = .screenUnderMouse, successMessage: String = "Copied") {
        guard !isCapturing, let screen = Snapshotter.screenUnderMouse() else { return }
        if burstActive, kind == .region { return } // the burst's picker is already up
        guard ensureCapturePermission(on: screen) else { return }
        isCapturing = true
        CaptureSession.isActive = true
        willCapture?()
        overlays.forEach { $0.displayIfNeeded() }

        if kind == .region {
            regionPicker.pick(.capture) {
                [weak self] result in
                guard let self else { return }
                self.rekeyOverlayIfDrawing() // the picker had the keyboard
                guard let (rect, pickedScreen) = result else {
                    self.endCapture() // cancelled: no file, no toast
                    return
                }
                self.runCapture(rect: rect, screen: pickedScreen, successMessage: successMessage)
            }
            return
        }
        guard let rect = CapturePlan.captureRect(for: kind, screenFrame: screen.frame) else {
            endCapture()
            return
        }
        runCapture(rect: rect, screen: screen, successMessage: successMessage)
    }

    private func runCapture(rect: CGRect, screen: NSScreen, successMessage: String,
                            then: ((URL?) -> Void)? = nil) {
        Snapshotter.capture(rect: rect, screen: screen, keepWindowNumbers: overlays.map(\.windowNumber)) {
            [weak self] result in
            guard let self else { return }
            self.endCapture()
            let toastScreen = Snapshotter.screenUnderMouse() ?? screen
            switch result {
            case .success(let url):
                if CaptureBatch.shared.isOpen {
                    let n = CaptureBatch.shared.add(url)
                    self.regionPicker.setPurpose(.burst(count: n))
                    self.toast.show("✓ \(n) captured", on: toastScreen, duration: 0.9)
                } else {
                    self.toast.show(successMessage, on: toastScreen,
                                    duration: successMessage == "Copied" ? nil : 2.5)
                }
                then?(url)
            case .failure(.noPermission):
                self.toast.show("Allow Pencil in Screen Recording, then relaunch Pencil",
                                on: toastScreen, isError: true)
                then?(nil)
            case .failure(.captureFailed(let why)):
                NSLog("Pencil: snapshot failed: \(why)")
                let short = why.split(separator: "\n").first.map(String.init) ?? why
                self.toast.show("Snapshot failed: \(short.prefix(80))", on: toastScreen, isError: true)
                then?(nil)
            }
        }
    }

    private func endCapture() {
        isCapturing = false
        guard !burstActive else { return } // the burst keeps the session open until Esc
        // Let trailing clicks / app-switch notifications from the picker pass first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated { CaptureSession.isActive = false }
        }
    }

    // MARK: Burst (⇧⌥4)

    /// Several region captures in a row: the picker stays up, each drag is saved and
    /// joins one batch (all of it on the clipboard), Esc finishes.
    func startBurst() {
        guard !burstActive, !isCapturing else { return }
        guard ensureCapturePermission(on: Snapshotter.screenUnderMouse()) else { return }
        burstActive = true
        CaptureSession.isActive = true
        willCapture?()
        overlays.forEach { $0.displayIfNeeded() }
        CaptureBatch.shared.begin()
        regionPicker.pickRepeating(onRect: { [weak self] rect, screen in
            guard let self, !self.isCapturing else { return }
            self.isCapturing = true
            self.regionPicker.flash(rect)
            self.runCapture(rect: rect, screen: screen, successMessage: "Copied")
        }, onEnd: { [weak self] in
            self?.endBurst()
        })
    }

    private func endBurst() {
        burstActive = false
        let n = CaptureBatch.shared.end()
        rekeyOverlayIfDrawing()
        endCapture()
        switch n {
        case 0: break
        case 1: toast.show("Copied", on: Snapshotter.screenUnderMouse())
        default:
            toast.show("\(n) captures copied, ⌘V pastes all · ⌥⇧V pastes one by one",
                       on: Snapshotter.screenUnderMouse(), duration: 4)
        }
    }
}
