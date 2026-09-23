import AppKit
import PencilCore
import ServiceManagement

/// Minimal menu-bar fallback: current mode, captures, Start at login, snapshots folder, Quit.
/// The icon mirrors the mode (filled while drawing).
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let modeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at login", action: nil, keyEquivalent: "")
    private let terminalPathsItem = NSMenuItem(title: "Paste images as file paths in terminals", action: nil, keyEquivalent: "")
    /// Set by the app delegate: the dock lives there.
    var onToggleDock: (() -> Void)?
    var onCollapseDock: (() -> Void)?
    /// Quit Pencil (⌘Q while the menu is open) goes through the confirmation.
    var onQuit: (() -> Void)?
    private let recordItem = NSMenuItem(title: "Start screen recording…", action: nil, keyEquivalent: "5")

    init(controller: AppController) {
        self.controller = controller
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        modeItem.isEnabled = false
        menu.addItem(modeItem)
        menu.addItem(.separator())

        loginItem.target = self
        loginItem.action = #selector(toggleLogin)
        menu.addItem(loginItem)

        let laser = NSMenuItem(title: "Laser", action: #selector(toggleLaser), keyEquivalent: "1")
        laser.keyEquivalentModifierMask = [.option]
        laser.target = self
        menu.addItem(laser)
        let pen = NSMenuItem(title: "Pen", action: #selector(togglePen), keyEquivalent: "2")
        pen.keyEquivalentModifierMask = [.option]
        pen.target = self
        menu.addItem(pen)
        func addOptionItem(_ title: String, _ key: String, _ action: Selector) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = [.option]
            it.target = self
            menu.addItem(it)
        }
        addOptionItem("Highlighter", "7", #selector(toggleHighlighter))
        addOptionItem("Off (hide ink)", "0", #selector(turnOff))
        addOptionItem("Undo", "z", #selector(undo))
        addOptionItem("Clear all", "x", #selector(clearAll))
        addOptionItem("Open / close toolbar", "9", #selector(toggleDock))

        let shot = NSMenuItem(title: "Snapshot screen", action: #selector(snapshotScreen), keyEquivalent: "3")
        shot.keyEquivalentModifierMask = [.option]
        shot.target = self
        menu.addItem(shot)
        let region = NSMenuItem(title: "Capture region…", action: #selector(snapshotRegion), keyEquivalent: "4")
        region.keyEquivalentModifierMask = [.option]
        region.target = self
        menu.addItem(region)
        let burst = NSMenuItem(title: "Burst capture…", action: #selector(startBurst), keyEquivalent: "4")
        burst.keyEquivalentModifierMask = [.option, .shift]
        burst.target = self
        menu.addItem(burst)
        let pasteAll = NSMenuItem(title: "Paste last burst one by one", action: #selector(pasteAll), keyEquivalent: "v")
        pasteAll.keyEquivalentModifierMask = [.option, .shift]
        pasteAll.target = self
        menu.addItem(pasteAll)

        let drawing = NSMenuItem(title: "Capture drawing", action: #selector(captureDrawing), keyEquivalent: "6")
        drawing.keyEquivalentModifierMask = [.option]
        drawing.target = self
        menu.addItem(drawing)
        recordItem.target = self
        recordItem.action = #selector(toggleRecording)
        recordItem.keyEquivalentModifierMask = [.option]
        menu.addItem(recordItem)

        let cheat = NSMenuItem(title: "Keyboard shortcuts…", action: #selector(showShortcuts), keyEquivalent: "/")
        cheat.keyEquivalentModifierMask = [.option]
        cheat.target = self
        menu.addItem(cheat)
        menu.addItem(.separator())

        let ax = NSMenuItem(title: "Open Accessibility settings", action: #selector(openAccessibility), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)
        let privacy = NSMenuItem(title: "Open Screen Recording settings",
                                 action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        privacy.target = self
        menu.addItem(privacy)
        let relaunch = NSMenuItem(title: "Relaunch Pencil", action: #selector(relaunch), keyEquivalent: "")
        relaunch.target = self
        menu.addItem(relaunch)
        menu.addItem(.separator())

        let clipboard = NSMenuItem(title: "Clipboard history", action: #selector(toggleClipboard), keyEquivalent: "v")
        clipboard.keyEquivalentModifierMask = [.command, .control]
        clipboard.target = self
        menu.addItem(clipboard)
        terminalPathsItem.target = self
        terminalPathsItem.action = #selector(toggleTerminalPaths)
        menu.addItem(terminalPathsItem)

        let folder = NSMenuItem(title: "Open snapshots folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Pencil", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        refresh()
    }

    func refresh() {
        let symbol: String
        switch controller.mode {
        case .off: symbol = "pencil"
        case .passThrough: symbol = "pencil.circle"
        case .draw(.pen): symbol = "pencil.circle.fill"
        case .draw(.highlighter): symbol = "highlighter"
        case .draw(.laser): symbol = "wand.and.rays"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pencil")
            ?? NSImage(systemSymbolName: "pencil", accessibilityDescription: "Pencil")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Pencil: \(controller.mode.displayName)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        modeItem.title = "Mode: \(controller.mode.displayName) · \(controller.color.name)"
        loginItem.state = LoginItem.isEnabled ? .on : .off
        terminalPathsItem.state = TerminalPasteBridge.shared.isEnabled ? .on : .off
        recordItem.title = controller.recorder.isRecording ? "Stop screen recording" : "Start screen recording…"
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func startBurst() {
        DispatchQueue.main.async { [controller] in
            MainActor.assumeIsolated { controller.startBurst() }
        }
    }

    @objc private func pasteAll() {
        // Let the menu close and focus return to the target app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [controller] in
            MainActor.assumeIsolated { BatchPaster.shared.pasteAll(toast: controller.toast) }
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(BatchPaster.accessibilitySettingsURL)
    }

    @objc private func captureDrawing() {
        DispatchQueue.main.async { [controller] in
            MainActor.assumeIsolated { controller.captureDrawing() }
        }
    }

    @objc private func toggleRecording() {
        DispatchQueue.main.async { [controller] in
            MainActor.assumeIsolated { controller.toggleRecording() }
        }
    }

    @objc private func toggleClipboard() { ClipboardHistoryController.shared.toggle() }
    @objc private func toggleTerminalPaths() { TerminalPasteBridge.shared.isEnabled.toggle() }
    @objc private func toggleHighlighter() { controller.toggleTool(.highlighter) }
    @objc private func turnOff() {
        controller.setMode(.off)
        onCollapseDock?()
    }
    @objc private func undo() { controller.undo() }
    @objc private func clearAll() { controller.clear() }
    @objc private func toggleDock() { onToggleDock?() }

    @objc private func toggleLaser() { controller.toggleTool(.laser) }
    @objc private func togglePen() { controller.toggleTool(.pen) }

    @objc private func showShortcuts() {
        DispatchQueue.main.async { [controller] in
            MainActor.assumeIsolated { controller.shortcutsHUD.show() }
        }
    }

    // Run after the menu has closed so it isn't in the capture.
    @objc private func snapshotScreen() {
        DispatchQueue.main.async { [controller] in
            MainActor.assumeIsolated { controller.snapshot(.screenUnderMouse) }
        }
    }

    @objc private func snapshotRegion() {
        DispatchQueue.main.async { [controller] in
            MainActor.assumeIsolated { controller.snapshot(.region) }
        }
    }

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screen Recording access is read once per process, so a fresh grant needs a relaunch.
    @objc private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("Pencil: relaunch failed: \(error.localizedDescription)")
        }
    }

    @objc private func openFolder() { Snapshotter.openFolder() }
    // After the menu has closed, so the confirmation can take the keyboard.
    @objc private func quit() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onQuit?() }
        }
    }
}

/// Start-at-login via SMAppService. Failures (e.g. running outside an app bundle,
/// or an ad-hoc signature the system rejects) are logged, never fatal.
@MainActor
enum LoginItem {
    private static let attemptedKey = "loginItem.attemptedDefault"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// On first launch, turn Start at login on by default.
    static func registerByDefaultOnFirstLaunch() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: attemptedKey) else { return }
        d.set(true, forKey: attemptedKey)
        setEnabled(true)
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Pencil: could not \(enabled ? "enable" : "disable") start at login: \(error.localizedDescription)")
        }
    }
}
