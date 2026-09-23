import AppKit
import CoreGraphics

/// Screen Recording permission: the check every capture path goes through, the message
/// shown when it's missing, and a reset for a grant that's stuck.
///
/// macOS ties the grant to the app's code signature, not its name. A switch that's on
/// for an older build (another signature) stays on in System Settings but doesn't
/// apply, and toggling it doesn't refresh it. Only removing the entry does, which is
/// what `reset()` does.
@MainActor
enum ScreenAccess {
    /// Read once per process by macOS, so a fresh grant needs a relaunch.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Opened straight from Downloads / AirDrop with the quarantine flag, macOS runs the app
    /// from a random read-only copy ("App Translocation") and the grant doesn't stick.
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    static var deniedMessage: String {
        isTranslocated
            ? "Move Pencil to Applications and open it from there, then allow Screen Recording"
            : "Allow Pencil in Screen Recording, then relaunch. Still stuck? Menu → Reset Screen Recording permission"
    }

    /// True when access is granted. Otherwise asks macOS (which prompts once), logs why,
    /// and shows `deniedMessage` on `toast`.
    static func ensure(toast: Toast?, on screen: NSScreen?) -> Bool {
        if isGranted { return true }
        CGRequestScreenCaptureAccess()
        NSLog("Pencil: no Screen Recording access (translocated: \(isTranslocated), path: \(Bundle.main.bundlePath))")
        toast?.show(deniedMessage, on: screen, isError: true)
        return false
    }

    /// Logged at launch so `log show --predicate 'process == "Pencil"'` explains a denial.
    static func logState() {
        NSLog("Pencil: Screen Recording granted: \(isGranted), translocated: \(isTranslocated), path: \(Bundle.main.bundlePath)")
    }

    /// Removes every Screen Recording entry for Pencil's bundle id (stale signatures
    /// included), then asks again so this build is the one that gets listed.
    static func reset(toast: Toast?) {
        guard !isTranslocated else {
            toast?.show(deniedMessage, on: nil, isError: true)
            return
        }
        let id = Bundle.main.bundleIdentifier ?? "com.haim.pencil"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", id]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("Pencil: tccutil reset failed: \(error.localizedDescription)")
        }
        NSLog("Pencil: tccutil reset ScreenCapture \(id) exited \(task.terminationStatus)")
        guard task.terminationStatus == 0 else {
            toast?.show("Couldn't reset. In Terminal: tccutil reset ScreenCapture \(id)", on: nil, isError: true)
            return
        }
        CGRequestScreenCaptureAccess()
        openSettings()
        toast?.show("Reset. Turn Pencil on in Screen Recording, then Menu → Relaunch Pencil",
                    on: nil, duration: 8)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("Pencil: relaunch failed: \(error.localizedDescription)")
        }
    }
}
