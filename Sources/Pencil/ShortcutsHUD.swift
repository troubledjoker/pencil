import AppKit
import PencilCore

/// The keyboard cheat sheet as a small HUD. Shown by "Keyboard shortcuts…" in the
/// menu or "?" while drawing; goes away after a few seconds, on Esc, or on any click.
@MainActor
final class ShortcutsHUD {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private(set) var isShown = false

    func show(on screen: NSScreen? = nil, seconds: TimeInterval = 8) {
        let screen = screen ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let content = Self.makeContent()
        let size = content.fittingSize
        let v = screen.visibleFrame
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        panel.contentView = content
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        isShown = true

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        installMonitors()
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isShown = false
        panel?.orderOut(nil)
    }

    /// Any click closes it (global mouse monitors need no permission). Esc is handled by
    /// the overlay while drawing, or by a local key monitor when Pencil is active.
    private func installMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            var consumed = false
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .keyDown {
                    if event.keyCode == Shortcuts.escapeKeyCode { self.hide(); consumed = true }
                } else {
                    self.hide()
                }
            }
            return consumed ? nil : event
        }) { monitors.append(l) }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }

    private static func makeContent() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        func header(_ text: String) -> NSTextField {
            let f = NSTextField(labelWithString: text.uppercased())
            f.font = .systemFont(ofSize: 11, weight: .semibold)
            f.textColor = NSColor.white.withAlphaComponent(0.55)
            return f
        }
        func grid(_ rows: [(String, String)]) -> NSGridView {
            let views: [[NSView]] = rows.map { key, title in
                let k = NSTextField(labelWithString: key)
                k.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
                k.textColor = .white
                let t = NSTextField(labelWithString: title)
                t.font = .systemFont(ofSize: 13)
                t.textColor = NSColor.white.withAlphaComponent(0.85)
                return [k, t]
            }
            let g = NSGridView(views: views)
            g.rowSpacing = 5
            g.columnSpacing = 16
            g.column(at: 0).xPlacement = .trailing
            return g
        }

        // Two columns: the global keys by group, and the single keys while drawing.
        func column(_ views: [NSView], gapsAfter: [Int]) -> NSStackView {
            let v = NSStackView(views: views)
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 6
            for i in gapsAfter where i < views.count { v.setCustomSpacing(14, after: views[i]) }
            return v
        }
        var left: [NSView] = []
        var gaps: [Int] = []
        for section in Shortcuts.globalSections {
            left.append(header(section.title))
            left.append(grid(section.keys.map { ($0.label, $0.title) }))
            gaps.append(left.count - 1)
        }
        let right = column([header("While drawing (no modifier)"), grid(Shortcuts.drawingRows)], gapsAfter: [])
        let stack = NSStackView(views: [column(left, gapsAfter: gaps), right])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 32
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        effect.frame = NSRect(origin: .zero, size: stack.fittingSize)
        return effect
    }
}
