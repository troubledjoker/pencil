import AppKit
import AVFoundation
import PencilCore
import ScreenCaptureKit

/// Screen recording with ScreenCaptureKit (`SCRecordingOutput`, macOS 15+):
/// pick an area with Pencil's own selector, record H.264 .mp4 at 30fps with the
/// cursor and the ink, and leave out Pencil's own chrome (dock, hints, toasts,
/// the recording controls). Stops on ⌥5, the Stop button, or after 5 minutes.
@MainActor
final class ScreenRecorder {
    private(set) var isRecording = false
    private var isStarting = false
    /// Windows that must stay in the recording (the ink overlays).
    var inkWindowNumbers: () -> [Int] = { [] }
    /// Called when recording starts/stops so the UI can reflect it.
    var onStateChange: ((Bool) -> Void)?
    var toast: Toast?

    private let selector = RegionSelector()
    private var session: AnyObject?   // RecordingSession (macOS 15)
    private let control = RecordingControlPanel()
    private let outline = RecordingOutline()
    private var ticker: Timer?
    private var startedAt: Date?
    /// Run once the file is finished (saved or failed), for "stop, save, then quit".
    private var afterFinish: [() -> Void] = []

    func toggle() {
        if isRecording { stop() } else { begin() }
    }

    private func begin() {
        guard !isStarting, !isRecording else { return }
        guard #available(macOS 15.0, *) else {
            toast?.show("Screen recording needs macOS 15", on: nil, isError: true)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            toast?.show("Allow Pencil in Screen Recording, then relaunch Pencil", on: nil, isError: true)
            return
        }
        isStarting = true
        CaptureSession.isActive = true
        selector.pick(.record) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { CaptureSession.isActive = false }
            }
            guard let (rect, screen) = result else {
                self.isStarting = false // cancelled
                return
            }
            self.start(rect: rect, screen: screen)
        }
    }

    private func start(rect: CGRect, screen: NSScreen) {
        guard #available(macOS 15.0, *) else { return }
        let url = Snapshotter.uniqueURL(prefix: "pencil-rec", ext: "mp4")
        do {
            try FileManager.default.createDirectory(at: Snapshotter.folder, withIntermediateDirectories: true)
        } catch {
            fail("Can't create \(Snapshotter.folder.path)")
            return
        }
        let session = RecordingSession(url: url, rect: rect, screen: screen, keep: inkWindowNumbers())
        session.onFinish = { [weak self] result in self?.finished(result) }
        self.session = session
        Task { @MainActor in
            do {
                try await session.start()
                self.isStarting = false
                self.isRecording = true
                self.startedAt = Date()
                self.outline.show(around: rect)
                self.control.show(on: screen, onStop: { [weak self] in self?.stop() })
                self.control.update(elapsed: 0)
                self.startTicker()
                self.onStateChange?(true)
            } catch {
                self.isStarting = false
                self.session = nil
                self.fail(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard isRecording, #available(macOS 15.0, *), let session = session as? RecordingSession else { return }
        isRecording = false
        ticker?.invalidate()
        ticker = nil
        control.hide()
        outline.hide()
        onStateChange?(false)
        Task { @MainActor in await session.stop() }
    }

    /// Stops a running recording and calls `done` once the file is saved (or failed, or after
    /// `timeout` as a safety net). Calls it right away when nothing is recording.
    func stopAndSave(timeout: TimeInterval = 6, _ done: @escaping () -> Void) {
        guard isRecording || session != nil else { done(); return }
        var called = false
        let once = { if !called { called = true; done() } }
        afterFinish.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated { once() }
        }
        stop()
    }

    private func startTicker() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startedAt = self.startedAt else { return }
                let elapsed = Date().timeIntervalSince(startedAt)
                self.control.update(elapsed: elapsed)
                if elapsed >= RecordingPlan.maxDuration { self.stop() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func finished(_ result: Result<URL, Error>) {
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        session = nil
        startedAt = nil
        switch result {
        case .success(let url):
            NSLog("Pencil: recording saved \(url.path)")
            if CaptureBatch.shared.isOpen {
                let n = CaptureBatch.shared.add(url)
                toast?.show("Recording added to burst (\(n))", on: nil, duration: 2)
            } else {
                Snapshotter.copyToPasteboard(fileURL: url, png: nil)
                toast?.show("Recording copied (\(RecordingPlan.elapsedLabel(elapsed)))", on: nil, duration: 2.5)
            }
        case .failure(let error):
            fail(error.localizedDescription)
        }
        let waiting = afterFinish
        afterFinish.removeAll()
        waiting.forEach { $0() }
    }

    private func fail(_ why: String) {
        NSLog("Pencil: recording failed: \(why)")
        toast?.show("Recording failed: \(why.prefix(80))", on: nil, isError: true)
    }
}

// MARK: - ScreenCaptureKit session

@available(macOS 15.0, *)
@MainActor
private final class RecordingSession: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput {
    let url: URL
    let rect: CGRect
    let screen: NSScreen
    let keepWindowNumbers: [Int]
    var onFinish: ((Result<URL, Error>) -> Void)?

    private var stream: SCStream?
    private var finished = false
    private let sampleQueue = DispatchQueue(label: "pencil.recording.samples")

    init(url: URL, rect: CGRect, screen: NSScreen, keep: [Int]) {
        self.url = url
        self.rect = rect
        self.screen = screen
        self.keepWindowNumbers = keep
    }

    func start() async throws {
        // Same filter as stills: everything but Pencil's own UI; the ink overlays stay.
        let filter = try await CaptureFilter.make(displayID: screen.displayID, keepWindowNumbers: keepWindowNumbers)

        let config = SCStreamConfiguration()
        let source = RecordingPlan.sourceRect(selection: rect, screenFrame: screen.frame)
        let px = RecordingPlan.pixelSize(for: source, scale: screen.backingScaleFactor)
        config.sourceRect = source
        config.width = px.width
        config.height = px.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: RecordingPlan.framesPerSecond)
        config.showsCursor = true
        config.capturesAudio = false
        config.queueDepth = 6

        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = url
        outputConfig.outputFileType = .mp4
        outputConfig.videoCodecType = .h264
        let recording = SCRecordingOutput(configuration: outputConfig, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // A no-op screen output keeps ScreenCaptureKit from logging dropped frames.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            finish(.failure(error))
        }
        // The file is complete once recordingOutputDidFinishRecording fires.
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        stream = nil
        onFinish?(result)
    }

    // SCStreamOutput: frames go to the recording output; nothing to do here.
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {}

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finish(.success(self.url)) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }
}

// MARK: - Area picker

/// Pencil's "drag a rectangle" picker, used by region captures and recordings. A light
/// dim, a small hint pill at the top, and the selection shown clear with a W×H readout.
/// The drag's mouse-up finishes it (no confirm step); a click without a drag, or Esc,
/// cancels. Space/Return quietly pick the whole screen under the mouse. Its windows
/// close before any capture starts (and are excluded from captures anyway).
@MainActor
final class RegionSelector {
    enum Purpose {
        case capture, record
        /// Stays up after each capture; the count shows in the pill.
        case burst(count: Int)
        var prompt: String {
            switch self {
            case .capture: return "Drag to capture · Esc to cancel"
            case .record: return "Drag to record · Space: whole screen · Esc to cancel"
            case .burst(let n):
                return n == 0 ? "Burst · drag to capture · Esc when done"
                              : "Burst · \(n) captured · Esc when done"
            }
        }
    }

    private var panels: [SelectorPanel] = []
    private var completion: (((CGRect, NSScreen)?) -> Void)?
    /// Burst mode: called for every finished drag while the picker stays up.
    private var repeating: ((CGRect, NSScreen) -> Void)?
    private var onEnd: (() -> Void)?

    /// Burst: the picker stays up; `onRect` runs per drag, `onEnd` on Esc.
    func pickRepeating(onRect: @escaping (CGRect, NSScreen) -> Void, onEnd: @escaping () -> Void) {
        pick(.burst(count: 0)) { _ in }
        completion = nil
        repeating = onRect
        self.onEnd = onEnd
    }

    func setPurpose(_ purpose: Purpose) {
        panels.forEach { $0.selectorView.prompt = purpose.prompt; $0.selectorView.needsDisplay = true }
    }

    /// A quick white flash over a just-captured area (global rect).
    func flash(_ rect: CGRect) {
        for p in panels where p.frame.intersects(rect) {
            p.selectorView.flash(rect.offsetBy(dx: -p.frame.minX, dy: -p.frame.minY))
        }
    }

    func pick(_ purpose: Purpose, _ completion: @escaping ((CGRect, NSScreen)?) -> Void) {
        close()
        repeating = nil
        onEnd = nil
        self.completion = completion
        panels = NSScreen.screens.map { screen in
            let p = SelectorPanel(screen: screen)
            p.selectorView.prompt = purpose.prompt
            p.selectorView.onDone = { [weak self] rect in
                NSLog("Pencil: area picker drag ended with rect \(NSStringFromRect(rect))")
                self?.finish((rect, screen))
            }
            p.selectorView.onWholeScreen = { [weak self] in
                let s = Snapshotter.screenUnderMouse() ?? screen
                NSLog("Pencil: area picker whole screen \(NSStringFromRect(s.frame))")
                self?.finish((s.frame, s))
            }
            p.selectorView.onCancel = { [weak self] reason in
                NSLog("Pencil: area picker cancelled (\(reason))")
                self?.cancel(reason)
            }
            p.orderFrontRegardless()
            return p
        }
        let target = panels.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? panels.first
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.selectorView)
        NSCursor.crosshair.set()
        NSLog("Pencil: area picker shown (\(purpose)) on \(panels.count) screen(s), key=\(target?.isKeyWindow ?? false)")
    }

    private func finish(_ result: (CGRect, NSScreen)) {
        if let repeating {
            panels.forEach { $0.selectorView.resetSelection() }
            repeating(result.0, result.1)
        } else {
            done(result)
        }
    }

    private func cancel(_ reason: String) {
        if repeating != nil {
            // In a burst a stray click just does nothing; Esc ends it.
            guard reason == "Esc" else {
                panels.forEach { $0.selectorView.resetSelection() }
                return
            }
            let end = onEnd
            repeating = nil
            onEnd = nil
            close()
            end?()
        } else {
            done(nil)
        }
    }

    private func done(_ result: (CGRect, NSScreen)?) {
        let completion = self.completion
        self.completion = nil
        close()
        // Let the compositor drop the picker (at least a frame) before anything is captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            MainActor.assumeIsolated { completion?(result) }
        }
    }

    private func close() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

private final class SelectorPanel: NSPanel {
    let selectorView: SelectorView

    init(screen: NSScreen) {
        selectorView = SelectorView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = selectorView
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectorView: NSView {
    var onDone: ((CGRect) -> Void)?
    var onWholeScreen: (() -> Void)?
    var onCancel: ((String) -> Void)?
    var prompt = ""

    private var start: NSPoint?
    private var current: NSPoint?
    private var flashRect: NSRect?
    private var flashAlpha: CGFloat = 0
    /// Below this, a press counts as a click, which cancels.

    func resetSelection() {
        start = nil
        current = nil
        needsDisplay = true
    }

    /// White flash over a just-captured area that fades out in ~0.25s.
    func flash(_ rect: NSRect) {
        flashRect = rect
        flashAlpha = 0.45
        needsDisplay = true
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.flashAlpha -= 0.03
                if self.flashAlpha <= 0 { self.flashAlpha = 0; self.flashRect = nil; timer.invalidate() }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }
    private static let minDrag: CGFloat = 4

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return RecordingPlan.selection(from: start, to: current, in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        current = start
        NSLog("Pencil: area picker drag started")
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let sel = selection, let window else { return }
        guard sel.width >= Self.minDrag, sel.height >= Self.minDrag else {
            onCancel?("click without a drag")
            return
        }
        onDone?(sel.offsetBy(dx: window.frame.minX, dy: window.frame.minY))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case Shortcuts.escapeKeyCode: onCancel?("Esc")
        case 49: onWholeScreen?() // Space
        case let k where Shortcuts.returnKeyCodes.contains(k): onWholeScreen?()
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.15).setFill()
        bounds.fill()
        if let flashRect, flashAlpha > 0 {
            NSColor.white.withAlphaComponent(flashAlpha).setFill()
            flashRect.fill(using: .sourceOver)
        }
        if let sel = selection {
            NSColor.clear.setFill()
            sel.fill(using: .copy)
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            if let current {
                drawPill("\(Int(sel.width)) × \(Int(sel.height))",
                         at: NSPoint(x: current.x + 14, y: current.y - 30), font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold))
            }
        }
        // Short hint at the top center, out of the way of the content.
        let size = pillSize(prompt, font: .systemFont(ofSize: 12, weight: .medium))
        drawPill(prompt, at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 44),
                 font: .systemFont(ofSize: 12, weight: .medium))
    }

    private func pillSize(_ text: String, font: NSFont) -> NSSize {
        let s = NSAttributedString(string: text, attributes: [.font: font]).size()
        return NSSize(width: ceil(s.width) + 20, height: ceil(s.height) + 10)
    }

    private func drawPill(_ text: String, at origin: NSPoint, font: NSFont) {
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = pillSize(text, font: font)
        var o = origin
        o.x = min(max(o.x, bounds.minX + 6), bounds.maxX - size.width - 6)
        o.y = min(max(o.y, bounds.minY + 6), bounds.maxY - size.height - 6)
        let box = NSRect(origin: o, size: size)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        str.draw(at: NSPoint(x: box.minX + 10, y: box.minY + 5))
    }
}

// MARK: - While recording

/// Red dot, elapsed time, and Stop, near the top center of the recorded screen.
/// It's a Pencil window, so it's excluded from the recording.
@MainActor
final class RecordingControlPanel {
    private var panel: NSPanel?
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private var onStop: (() -> Void)?

    func show(on screen: NSScreen, onStop: @escaping () -> Void) {
        self.onStop = onStop
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = NSSize(width: 150, height: 34)
        let v = screen.visibleFrame
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.maxY - size.height - 10,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func update(elapsed: TimeInterval) {
        timeLabel.stringValue = RecordingPlan.elapsedLabel(elapsed)
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = DockPanel(contentRect: NSRect(x: 0, y: 0, width: 150, height: 34))
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 150, height: 34))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 17
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let dot = NSView(frame: NSRect(x: 14, y: 12, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        effect.addSubview(dot)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.frame = NSRect(x: 30, y: 8, width: 50, height: 18)
        effect.addSubview(timeLabel)

        let stop = DockButton(symbol: "stop.fill", hint: Shortcuts.hint("Stop recording", .record))
        stop.frame = NSRect(x: 150 - 44, y: 1, width: 34, height: 32)
        stop.onClick = { [weak self] in self?.onStop?() }
        effect.addSubview(stop)

        p.contentView = effect
        p.hasShadow = true
        return p
    }
}

/// A thin red frame drawn just outside the recorded area (and excluded anyway).
@MainActor
final class RecordingOutline {
    private var panel: NSPanel?

    func show(around rect: CGRect) {
        let frame = rect.insetBy(dx: -3, dy: -3)
        let p = panel ?? makePanel()
        panel = p
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let v = OutlineView()
        v.autoresizingMask = [.width, .height]
        p.contentView = v
        return p
    }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
    }
}
