import AppKit
import ImageIO
import PencilCore
import ScreenCaptureKit
import UniformTypeIdentifiers

enum SnapshotError: Error {
    case noPermission
    case captureFailed(String)
}

/// True while a Pencil capture (or its area picker) is running. Panels that close on
/// outside clicks or app switches check it so a capture never dismisses them.
@MainActor
enum CaptureSession {
    static var isActive = false
}

/// Builds the ScreenCaptureKit filter shared by stills and recordings: the whole
/// display minus every Pencil window (dock, flyout, clipboard sidebar, hints, toasts,
/// the area picker, recording controls — including ones created later), except the
/// ink overlays, so the drawing is always in the picture.
enum CaptureFilter {
    static func make(displayID: CGDirectDisplayID, keepWindowNumbers: [Int]) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw SnapshotError.captureFailed("Display not found")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let me = content.applications.filter { $0.processID == pid }
        let keep = content.windows.filter { keepWindowNumbers.contains(Int($0.windowID)) }
        return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: keep)
    }
}

/// Still captures with ScreenCaptureKit (`SCScreenshotManager`): a global rect on one
/// screen, ink included, Pencil's own UI excluded, no cursor. Saves a PNG under
/// ~/Pictures/Pencil and copies it to the pasteboard. Nothing is hidden or moved.
@MainActor
enum Snapshotter {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Pencil", isDirectory: true)
    }

    static func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// The screen under the mouse, falling back to the main screen.
    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Captures `rect` (AppKit global coordinates) on `screen`.
    static func capture(rect: CGRect, screen: NSScreen, keepWindowNumbers: [Int],
                        completion: @escaping @MainActor (Result<URL, SnapshotError>) -> Void) {
        guard ScreenAccess.isGranted else {
            completion(.failure(.noPermission))
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            completion(.failure(.captureFailed("Can't create \(folder.path)")))
            return
        }
        let url = uniqueURL()
        NSLog("Pencil: capture started, rect \(NSStringFromRect(rect)) on display \(screen.displayID)")
        let source = RecordingPlan.sourceRect(selection: rect, screenFrame: screen.frame)
        let px = CapturePlan.stillPixelSize(for: source, scale: screen.backingScaleFactor)
        let displayID = screen.displayID
        Task { @MainActor in
            do {
                let filter = try await CaptureFilter.make(displayID: displayID, keepWindowNumbers: keepWindowNumbers)
                let config = SCStreamConfiguration()
                config.sourceRect = source
                config.width = px.width
                config.height = px.height
                config.showsCursor = false
                config.capturesAudio = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let data = pngData(image) else {
                    throw SnapshotError.captureFailed("Couldn't encode the PNG")
                }
                try data.write(to: url, options: .atomic)
                NSLog("Pencil: capture saved \(url.path) (\(image.width)×\(image.height) px)")
                copyToPasteboard(fileURL: url, png: data)
                completion(.success(url))
            } catch let error as SnapshotError {
                NSLog("Pencil: capture failed: \(error)")
                completion(.failure(error))
            } catch {
                NSLog("Pencil: ScreenCaptureKit capture failed: \(error)")
                completion(.failure(.captureFailed(error.localizedDescription)))
            }
        }
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// One pasteboard item carrying the file and the image, so pasting works everywhere:
    /// Finder / Mail / Slack / upload fields take the file URL (the real PNG), image-aware
    /// apps and Claude Code's Ctrl+V take the PNG data. Recordings pass `png: nil` (file URL only).
    static func copyToPasteboard(fileURL url: URL, png: Data?) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let png {
            item.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        }
        // No plain-text path: apps that accept text would paste the path instead of the image.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    static func uniqueURL(prefix: String = "pencil", ext: String = "png") -> URL {
        let now = Date()
        var attempt = 1
        var url = folder.appendingPathComponent(CapturePlan.fileName(for: now, prefix: prefix, ext: ext))
        while FileManager.default.fileExists(atPath: url.path) {
            attempt += 1
            url = folder.appendingPathComponent(CapturePlan.fileName(for: now, attempt: attempt, prefix: prefix, ext: ext))
        }
        return url
    }
}
