import Foundation

/// Pencil's keyboard scheme, kept in one place so the hotkeys, the in-draw keys,
/// the hints, the menu and the cheat sheet all agree.
public enum Shortcuts {
    // MARK: Global (Carbon hotkeys)

    /// Modifier sets for global keys, as NSEvent.ModifierFlags raw values (the same
    /// encoding macOS uses for its own shortcuts in com.apple.symbolichotkeys).
    public enum Mods {
        public static let shift = 1 << 17
        public static let control = 1 << 18
        public static let option = 1 << 19
        public static let command = 1 << 20
    }

    /// Every Pencil feature has exactly one global key. Adding a case forces a key code,
    /// modifiers, label and title (the switches are exhaustive), and the tests check that
    /// no two share a combo and every `Feature` has one.
    public enum Global: CaseIterable, Sendable {
        // Draw
        case laser, pen, highlighter, off
        // Edit
        case undo, clear
        // Capture
        case snapshot, region, burst, captureDrawing, record
        // Clipboard
        case clipboard, pasteAll
        // Pencil
        case toggleDock, shortcuts

        /// Virtual key code (kVK_ANSI_*).
        public var keyCode: Int {
            switch self {
            case .laser: return 18          // 1
            case .pen: return 19            // 2
            case .snapshot: return 20       // 3
            case .region, .burst: return 21 // 4
            case .record: return 23         // 5
            case .captureDrawing: return 22 // 6
            case .highlighter: return 26    // 7
            case .toggleDock: return 25     // 9
            case .off: return 29            // 0
            case .undo: return 6            // Z
            case .clear: return 7           // X
            case .shortcuts: return 44      // /
            case .pasteAll, .clipboard: return 9 // V
            }
        }

        /// NSEvent-style modifier mask (see `Mods`).
        public var modifiers: Int {
            switch self {
            case .burst, .pasteAll: return Mods.option | Mods.shift
            case .clipboard: return Mods.control | Mods.command
            default: return Mods.option
            }
        }

        public var label: String {
            switch self {
            case .laser: return "⌥1"
            case .pen: return "⌥2"
            case .snapshot: return "⌥3"
            case .region: return "⌥4"
            case .record: return "⌥5"
            case .captureDrawing: return "⌥6"
            case .highlighter: return "⌥7"
            case .toggleDock: return "⌥9"
            case .off: return "⌥0"
            case .undo: return "⌥Z"
            case .clear: return "⌥X"
            case .shortcuts: return "⌥/"
            case .burst: return "⇧⌥4"
            case .pasteAll: return "⌥⇧V"
            case .clipboard: return "⌃⌘V"
            }
        }

        public var title: String {
            switch self {
            case .laser: return "Laser (press again to turn off)"
            case .pen: return "Pen (press again to turn off)"
            case .highlighter: return "Highlighter (press again to turn off)"
            case .off: return "Off: stop drawing and hide the ink"
            case .undo: return "Undo"
            case .clear: return "Clear all ink"
            case .snapshot: return "Snapshot screen, ink included"
            case .region: return "Region capture"
            case .burst: return "Burst capture: several regions, Esc when done"
            case .captureDrawing: return "Capture the drawing (cropped to the ink)"
            case .record: return "Start / stop screen recording"
            case .clipboard: return "Clipboard history"
            case .pasteAll: return "Paste the last burst one by one"
            case .toggleDock: return "Open / close the toolbar"
            case .shortcuts: return "Show this cheat sheet"
            }
        }
    }

    /// Everything the toolbar, the Undo/Clear pill and the menu can do. Each maps to its
    /// global key (exhaustive switch), so a new feature can't ship without one.
    public enum Feature: CaseIterable, Sendable {
        case laser, pen, highlighter, off, undo, clear, snapshot, region, burst, captureDrawing,
             record, clipboard, pasteAll, toggleDock, shortcuts

        public var global: Global {
            switch self {
            case .laser: return .laser
            case .pen: return .pen
            case .highlighter: return .highlighter
            case .off: return .off
            case .undo: return .undo
            case .clear: return .clear
            case .snapshot: return .snapshot
            case .region: return .region
            case .burst: return .burst
            case .captureDrawing: return .captureDrawing
            case .record: return .record
            case .clipboard: return .clipboard
            case .pasteAll: return .pasteAll
            case .toggleDock: return .toggleDock
            case .shortcuts: return .shortcuts
            }
        }
    }

    /// The cheat sheet's global sections.
    public static let globalSections: [(title: String, keys: [Global])] = [
        ("Draw", [.laser, .pen, .highlighter, .off]),
        ("Edit", [.undo, .clear]),
        ("Capture", [.snapshot, .region, .burst, .captureDrawing, .record]),
        ("Clipboard", [.clipboard, .pasteAll]),
        ("Pencil", [.toggleDock, .shortcuts]),
    ]

    // MARK: Conflicts with macOS's own shortcuts

    /// Names for the macOS shortcuts that most often collide (AppleSymbolicHotKeys ids).
    public static let systemShortcutNames: [Int: String] = [
        28: "Save picture of screen as a file",
        29: "Copy picture of screen to the clipboard",
        30: "Save picture of selected area as a file",
        31: "Copy picture of selected area to the clipboard",
        184: "Screenshot and recording options",
    ]

    /// Pencil keys that an enabled macOS shortcut already uses. Both would fire (macOS
    /// doesn't refuse the registration), so Pencil must leave these alone. `symbolicHotKeys`
    /// is the `AppleSymbolicHotKeys` dictionary from com.apple.symbolichotkeys.
    public static func systemConflicts(_ symbolicHotKeys: [String: Any]?) -> [(Global, id: Int)] {
        guard let symbolicHotKeys else { return [] }
        var result: [(Global, id: Int)] = []
        for (key, value) in symbolicHotKeys {
            guard let id = Int(key), let entry = value as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue ?? (entry["enabled"] as? Bool) ?? false,
                  let v = entry["value"] as? [String: Any],
                  let params = v["parameters"] as? [Any], params.count >= 3,
                  let code = (params[1] as? NSNumber)?.intValue,
                  let mods = (params[2] as? NSNumber)?.intValue else { continue }
            let relevant = Mods.shift | Mods.control | Mods.option | Mods.command
            for g in Global.allCases where g.keyCode == code && g.modifiers == (mods & relevant) {
                result.append((g, id))
            }
        }
        return result.sorted { $0.0.label < $1.0.label }
    }

    /// ⌥1 / ⌥2: switch to the tool, or turn drawing off if it's already on.
    public static func toggled(_ mode: Mode, tool: Tool) -> Mode {
        mode == .draw(tool) ? .off : .draw(tool)
    }

    // MARK: Single keys while drawing (the overlay has focus)

    public enum LocalCommand: Equatable, Sendable {
        case tool(Tool)
        case color(index: Int)
        case undo
        case clear
        case snapshot
        case region
        /// Esc: stop drawing, keep the ink visible, let clicks through.
        case passThrough
        case help
        /// Return / Enter: capture just the drawing (ink-fit crop).
        case captureDrawing
    }

    public static let escapeKeyCode: UInt16 = 53
    /// Return and the keypad's Enter.
    public static let returnKeyCodes: Set<UInt16> = [36, 76]

    /// Maps a key press to a command. `characters` is the typed text (so "?" arrives
    /// as "?"), `bareCharacters` the same key without modifiers.
    public static func localCommand(keyCode: UInt16, characters: String?, bareCharacters: String?,
                                    command: Bool, control: Bool, option: Bool) -> LocalCommand? {
        if keyCode == escapeKeyCode { return .passThrough }
        if returnKeyCodes.contains(keyCode), !command, !control, !option { return .captureDrawing }
        let bare = bareCharacters?.lowercased()
        if command, !control, !option { return bare == "z" ? .undo : nil }
        guard !command, !control, !option else { return nil }
        if characters == "?" { return .help }
        switch bare {
        case "p": return .tool(.pen)
        case "h": return .tool(.highlighter)
        case "l": return .tool(.laser)
        case "z": return .undo
        case "x": return .clear
        case "s": return .snapshot
        case "a": return .region
        case let s? where s.count == 1:
            if let n = Int(s), (1...5).contains(n) { return .color(index: n - 1) }
            return nil
        default: return nil
        }
    }

    // MARK: Cheat sheet

    public static let globalRows: [(String, String)] = Global.allCases.map { ($0.label, $0.title) }

    /// Hover-hint text: the name plus its global shortcut, if it has one. The in-draw
    /// single keys are only in the cheat sheet.
    public static func hint(_ name: String, _ global: Global? = nil) -> String {
        guard let global else { return name }
        return "\(name)  \(global.label)"
    }

    public static let drawingRows: [(String, String)] = [
        ("P  H  L", "Pen · Highlighter · Laser"),
        ("1 – 5", "Red · Yellow · Green · Blue · White"),
        ("Z  or  ⌘Z", "Undo"),
        ("X", "Clear all"),
        ("⏎", "Capture the drawing (cropped to the ink)"),
        ("S", "Snapshot screen"),
        ("A", "Region capture"),
        ("Esc", "Stop drawing (ink stays, clicks go through)"),
        ("?", "Show this"),
    ]
}
