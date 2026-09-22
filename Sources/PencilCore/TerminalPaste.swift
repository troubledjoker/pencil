import Foundation

/// Terminals only read plain text from the pasteboard, so an image (or an image/video file)
/// pastes nothing there. Claude Code turns a pasted file path into an image attachment, so
/// while a terminal is frontmost the pasteboard also carries the file's path as text; in
/// any other app that text is taken off again (chat apps would paste the path instead).
public enum TerminalPaste {
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
    ]

    public static func isTerminal(_ bundleID: String?) -> Bool {
        bundleID.map(terminalBundleIDs.contains) ?? false
    }

    /// Characters Terminal's drag-and-drop escapes with a backslash.
    static let shellSpecial = Set(" !\"#$&'()*,;<>?[\\]^`{|}~\t")

    /// A POSIX path quoted the way Terminal does when you drop a file on it:
    /// `/Users/me/My Shots/a (1).png` → `/Users/me/My\ Shots/a\ \(1\).png`.
    public static func escaped(_ path: String) -> String {
        var out = ""
        for c in path {
            if shellSpecial.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Several files (a burst): escaped paths separated by spaces.
    public static func pasteText(for paths: [String]) -> String {
        paths.map(escaped).joined(separator: " ")
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Rewrite the pasteboard with the same content plus the path as text.
        case addPath
        /// Rewrite it without the text we added.
        case removePath
        /// The user copied something newer since we added the text: leave it, forget ours.
        case forget
    }

    /// - frontIsTerminal: a terminal is the frontmost app
    /// - enabled: the "Paste images as file paths in terminals" setting
    /// - hasPlainText: the pasteboard already carries text (then nothing to add)
    /// - hasImageOrMedia: the first item is image data, or an image/video file URL
    /// - bridgedChangeCount: the change count of our own "with path" write, if one is active
    /// - changeCount: the pasteboard's change count now
    public static func decide(frontIsTerminal: Bool, enabled: Bool, hasPlainText: Bool, hasImageOrMedia: Bool,
                              bridgedChangeCount: Int?, changeCount: Int) -> Action {
        if let bridged = bridgedChangeCount {
            guard bridged == changeCount else { return .forget }
            return frontIsTerminal && enabled ? .none : .removePath
        }
        return frontIsTerminal && enabled && hasImageOrMedia && !hasPlainText ? .addPath : .none
    }
}
