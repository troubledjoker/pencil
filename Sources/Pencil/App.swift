import AppKit
import Carbon.HIToolbox
import PencilCore

@main
enum PencilMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu-bar only, even when run outside the bundle
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()
    private var dock: DockController?
    private var statusMenu: StatusMenuController?
    private var hotkeys: HotkeyCenter?
    /// Grabs Esc while a drawing tool is on (see `registerHotkeys`).
    private var grabEscape: ((Bool) -> Void)?
    private lazy var quitConfirmation = QuitConfirmation(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        ScreenAccess.logState()
        controller.start()
        let dock = DockController(controller: controller)
        let statusMenu = StatusMenuController(controller: controller)
        self.dock = dock
        statusMenu.onToggleDock = { [weak dock] in dock?.toggleExpanded() }
        statusMenu.onCollapseDock = { [weak dock] in dock?.setExpanded(false) }
        let confirmQuit: () -> Void = { [weak self] in self?.quitConfirmation.show() }
        statusMenu.onQuit = confirmQuit
        dock.onQuit = confirmQuit
        self.statusMenu = statusMenu

        controller.onStateChange = { [weak self, weak dock, weak statusMenu] in
            dock?.refresh()
            statusMenu?.refresh()
            guard let self else { return }
            self.grabEscape?(self.controller.mode.isDrawing)
        }
        ClipboardHistoryController.shared.start()
        // Captures exclude Pencil's UI via ScreenCaptureKit, so nothing is hidden; only the
        // transient hover hint is dismissed.
        controller.willCapture = { HintCenter.shared.hide() }
        controller.escapeInterceptor = { [weak dock] in dock?.handleEscape() ?? false }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak dock] _ in
            MainActor.assumeIsolated { dock?.screensChanged() }
        }

        registerHotkeys()
        LoginItem.registerByDefaultOnFirstLaunch()
    }

    private func registerHotkeys() {
        let h = HotkeyCenter()
        let c = controller
        let dock = self.dock
        let quitConfirmation = self.quitConfirmation
        func action(_ g: Shortcuts.Global) -> () -> Void {
            switch g {
            case .laser: return { c.toggleTool(.laser) }
            case .pen: return { c.toggleTool(.pen) }
            case .highlighter: return { c.toggleTool(.highlighter) }
            case .eraser: return { c.toggleTool(.eraser) }
            case .objectEraser: return { c.toggleTool(.objectEraser) }
            case .off: return {
                // Like the toolbar's Off: stop drawing, hide the ink, collapse.
                c.setMode(.off)
                dock?.setExpanded(false)
            }
            case .bigger: return { c.changeSize(by: 1, announce: true) }
            case .smaller: return { c.changeSize(by: -1, announce: true) }
            case .undo: return { c.undo() }
            case .clear: return { c.clear() }
            case .snapshot: return { c.snapshot(.screenUnderMouse) }
            case .region: return { c.snapshot(.region) }
            case .burst: return { c.startBurst() }
            case .captureDrawing: return { c.captureDrawing() }
            case .record: return { c.toggleRecording() }
            case .clipboard: return { ClipboardHistoryController.shared.toggle() }
            case .pasteAll: return { BatchPaster.shared.pasteAll(toast: c.toast) }
            case .toggleDock: return { dock?.toggleExpanded() }
            case .shortcuts: return { c.shortcutsHUD.show() }
            case .quit: return { quitConfirmation.show() }
            }
        }
        // A key macOS itself uses (e.g. a screenshot shortcut remapped to ⌥4) would fire
        // both, so Pencil leaves those to macOS and says so once.
        let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        let conflicts = Shortcuts.systemConflicts(hotkeys)
        var taken: [String] = []
        for g in Shortcuts.Global.allCases {
            if let conflict = conflicts.first(where: { $0.0 == g }) {
                NSLog("Pencil: \(g.label) is macOS shortcut #\(conflict.id); not registering it")
                continue
            }
            if !h.register(keyCode: g.keyCode, modifiers: Self.carbonModifiers(g.modifiers), action(g)) {
                taken.append(g.label)
            }
        }
        // Esc while drawing, as a hotkey: it works on the first press wherever the keyboard
        // focus is (the overlay only gets keys while it's the key window). Only grabbed while
        // a drawing tool is on; the rest of the time Esc belongs to the user's apps.
        grabEscape = h.registerSwitchable(keyCode: Int(Shortcuts.escapeKeyCode), modifiers: 0) {
            Self.escapeWhileDrawing(c)
        }
        grabEscape?(c.mode.isDrawing)
        self.hotkeys = h
        warnOnceAboutSystemConflicts(conflicts, toast: c.toast)
        warnOnceAboutTakenKeys(taken, toast: c.toast)
    }

    /// Esc from the hotkey. A Pencil window that has the keyboard and handles Esc itself
    /// (the area picker, the clipboard sidebar, the quit dialog) gets it as a normal key
    /// press; otherwise it stops drawing.
    private static func escapeWhileDrawing(_ c: AppController) {
        if let key = NSApp.keyWindow, !(key is OverlayWindow), key.isVisible,
           let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: key.windowNumber, context: nil,
                                        characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                        isARepeat: false, keyCode: Shortcuts.escapeKeyCode) {
            key.sendEvent(event)
            return
        }
        c.escape()
    }

    private static func carbonModifiers(_ mods: Int) -> UInt32 {
        var m = 0
        if mods & Shortcuts.Mods.option != 0 { m |= optionKey }
        if mods & Shortcuts.Mods.shift != 0 { m |= shiftKey }
        if mods & Shortcuts.Mods.control != 0 { m |= controlKey }
        if mods & Shortcuts.Mods.command != 0 { m |= cmdKey }
        return UInt32(m)
    }

    private func warnOnceAboutSystemConflicts(_ conflicts: [(Shortcuts.Global, id: Int)], toast: Toast) {
        guard let first = conflicts.first else { return }
        let list = conflicts.map(\.0.label).joined(separator: ", ")
        let key = "hotkeys.warnedSystemConflicts"
        guard UserDefaults.standard.string(forKey: key) != list else { return }
        UserDefaults.standard.set(list, forKey: key)
        let name = Shortcuts.systemShortcutNames[first.id].map { "“\($0)”" } ?? "a macOS shortcut"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                toast.show("\(first.0.label) is macOS's \(name), so Pencil leaves it alone. "
                           + "Change it under Keyboard Shortcuts → Screenshots to use Pencil's.",
                           on: nil, isError: true, duration: 8)
            }
        }
    }

    /// If another app already owns one of our ⌥ keys, say which, once per key set.
    private func warnOnceAboutTakenKeys(_ taken: [String], toast: Toast) {
        guard !taken.isEmpty else { return }
        let list = taken.joined(separator: ", ")
        let key = "hotkeys.warnedTaken"
        guard UserDefaults.standard.string(forKey: key) != list else { return }
        UserDefaults.standard.set(list, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainActor.assumeIsolated {
                toast.show("\(list) is already used by another app, so Pencil can't use it", on: nil,
                           isError: true, duration: 6)
            }
        }
    }
}
