import AppKit

/// A small "Copied" style confirmation. It's its own click-through panel, shown
/// only after a capture finishes, so it never ends up in a snapshot.
@MainActor
final class Toast {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    func show(_ text: String, on screen: NSScreen?, isError: Bool = false, duration: TimeInterval? = nil) {
        guard let screen = screen ?? NSScreen.main else { return }
        hideWork?.cancel()
        generation += 1

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let size = NSSize(width: label.frame.width + 36, height: label.frame.height + 18)
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24,
                           width: size.width, height: size.height)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frame, display: false)

        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.cornerRadius = size.height / 2
        bg.layer?.backgroundColor = (isError ? NSColor.systemRed.withAlphaComponent(0.9)
                                             : NSColor.black.withAlphaComponent(0.78)).cgColor
        label.frame.origin = NSPoint(x: 18, y: 9)
        bg.addSubview(label)
        panel.contentView = bg

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (duration ?? (isError ? 3.0 : 1.2)), execute: work)
    }

    private func fadeOut() {
        guard let panel else { return }
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // A newer toast may have been shown while this one faded.
                if self.generation == gen { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        return p
    }
}
