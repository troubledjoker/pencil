# Pencil

Draw on top of everything on screen, snapshot it with the drawing, and paste it into
Claude Code. It's a small native macOS app (Swift + AppKit, macOS 14+).

## Cheat sheet

| Anywhere | |
| --- | --- |
| **⌥1** | Laser. Press again to turn it off |
| **⌥2** | Pen. Press again to turn it off (Off hides the ink) |
| **⌥3** | Snapshot the screen under the mouse, ink included, to a file and the clipboard |
| **⌥4** | Region capture to a file and the clipboard |
| **⌥5** | Start / stop a screen recording |
| **⇧⌥4** | Burst: capture several regions in a row, Esc when done |
| **⌥⇧V** | Paste the last burst one by one (for apps that take one image per paste) |
| **⌃⌘V** | Clipboard history |

| While drawing (no modifier) | |
| --- | --- |
| **P / H / L** | Pen / Highlighter / Laser |
| **1–5** | Red, yellow, green, blue, white |
| **Z** or **⌘Z** | Undo |
| **X** | Clear all |
| **⏎** | Capture the drawing: cropped to the ink plus some room around it, to the clipboard |
| **S** / **A** | Snapshot screen / Region capture |
| **Esc** | Stop drawing. Ink stays and clicks go through |
| **?** | Show this cheat sheet |

If another app already owns one of these keys, Pencil says which one, once, in a toast. If
one of them is also a macOS shortcut (for example "Copy picture of selected area to the
clipboard" remapped to ⌥4 under Keyboard Shortcuts → Screenshots), both would fire, so
Pencil leaves that key to macOS and says so. Change the macOS one to get Pencil's back.

## Build and run

```sh
scripts/bundle.sh          # renders the icon, swift build -c release, assembles and signs build/Pencil.app
open build/Pencil.app
swift test                 # stroke model, laser fade, dock geometry, capture, shortcuts
```

The app icon is drawn in code (`Sources/PencilCore/IconArt.swift`, shared with the dock tab).
`scripts/make-icon.sh` compiles `scripts/make-icon.swift` against it and writes
`Resources/AppIcon.iconset`, `Resources/AppIcon.icns` and a 1024px `Resources/icon-preview.png`.
`bundle.sh` runs it, copies the icon into the app, and re-registers the app with
LaunchServices so Finder and Spotlight show the new icon.

Pencil has no Dock icon. It lives in a **pencil tab on the left edge of the screen**,
with a small fallback item in the menu bar.

## The edge dock

- Collapsed, it's a small pencil tile (the Pencil icon artwork) peeking half out of the left
  edge. Hover it and it slides all the way out (and back in shortly after you move away). It
  stays fully out while you draw, record or drag it. The pencil stands upright in it; on hover it tilts a little, and when you
  click it tips over as the toolbar opens (and stands back up when it closes). It lifts slightly when you hover it, gets a ring in the current ink color while a drawing mode is on,
  and a red dot while recording.
- **Click the pencil** to open the toolbar in place. The pencil stays exactly where it is and
  becomes the toolbar's handle; the toolbar grows out of it. Collapsing reverses that.
  The toolbar grows down from it, or up (handle at the bottom, sections reversed) when the
  tab is too close to the bottom of the screen. It's split into small groups:
  - **Draw:** Pen, Highlighter, Laser, and the ink-color chip. Click the chip and a pill with the five colors slides out to the right. Picking one sets it and closes the pill. Clicking
    the chip again, clicking anywhere else, pressing Esc while drawing, or picking a mode
    also closes it. The active tool's icon takes the ink color.
  - **Edit:** Undo, Clear
  - **Capture:** Snapshot (whole screen), Capture region, Capture drawing, Screen recording
  - **Clipboard:** opens the clipboard history sidebar (⌃⌘V)
  - **Off** at the end
- The toolbar stays open while you draw, so you can switch color or undo mid-drawing.
  Click the pencil handle at the top to collapse it. Off turns drawing off and collapses it.
- **Drag the tab** (or the handle) up or down to move it. It stays locked to the left
  edge. Drag onto another display to move it there. The position is remembered.
- Hover any button for a moment to see its name and its global shortcut, if it has one.
  The single keys you use while drawing are in the cheat sheet (**?**).
- The dock never takes focus from the app you're working in. Captures and recordings leave
  Pencil's own UI (dock, clipboard sidebar, hints, toasts) out of the picture without hiding it,
  so nothing blinks. Your ink is always included.

## Clipboard history

Everything you copy, including every Pencil capture, is kept in a history. Open it with the
dock's **Clipboard** button, **⌃⌘V**, or **Clipboard history** in the menu. A dark sidebar
slides in on the right with the current clipboard at the top and your earlier copies below.
Click one to put it back on the clipboard, or drag it into another app. Search matches text,
file names, and text inside images (screenshots are OCR'd). Password-manager copies are never
saved. See [docs/CLIPBOARD.md](docs/CLIPBOARD.md).

## Modes

| Mode | What it does |
| --- | --- |
| Off | Ink hidden, clicks go to your apps. Ink is kept and comes back when you draw again, unless you cleared it. |
| Pen | Solid 4pt strokes that stay until cleared. |
| Highlighter | Thick, 35% opacity, flat-capped strokes that stay until cleared. |
| Laser | Thin glowing stroke that fades from the tail about 2.5s after each point is drawn. Nothing stays. |
| Pass-through | Ink stays visible, but clicks go through to your apps. Press Esc while drawing to get here. |

## Keyboard

See the cheat sheet at the top. A drawing mode started from ⌥1 or ⌥2 takes the keyboard
right away, so the single keys work without a click. Esc or Off hands focus back to the
app you were typing in. **Keyboard shortcuts…** in the menu (or **?** while drawing) shows
the cheat sheet on screen.

## Burst capture

Press **⇧⌥4** (or ⇧-click the toolbar's region button, or use the menu) when one message
needs several screenshots. The picker stays up: drag, it flashes and saves, drag again.
The pill counts them ("Burst · 3 captured · Esc when done"). ⌥3 snapshots and ⌥5
recordings made meanwhile join the same burst. **Esc** finishes.

The clipboard holds the whole burst as separate files, so **⌘V** in Finder, Slack, Mail and
similar apps pastes them all at once. For apps that take one image per paste (many chat
apps, Claude Code), press **⌥⇧V**: Pencil pastes them one after another into the front app.
That needs Accessibility permission once (System Settings → Privacy & Security →
Accessibility → Pencil; the menu has **Open Accessibility settings**). With no burst, ⌥⇧V is
a normal paste.

In the clipboard history a burst is one row with a small stack of thumbnails, "Burst · 4
captures · 12:45". Clicking it puts the whole burst back on the clipboard and opens it; the
single captures under it stay clickable on their own.

## Capture my drawing

Draw, then press **⏎** (or use the toolbar's Capture drawing button, or the menu). Pencil
crops to the ink on the screen under the mouse, pen and highlighter strokes plus any laser
still showing, adds 120pt of room on every side, and copies the result like any other
snapshot. You stay in the same mode with the ink kept. With no ink on that screen it takes
the whole screen and says so.

## Screen recording

Press **⌥5**, or use the record button in the toolbar or the menu. The screen dims a little:
drag out an area (the size shows by the cursor) and recording starts when you let go, or
press **Space** for the whole screen under the mouse. **Esc** or a plain click cancels. While recording:

- A small control at the top of the screen shows the time and a Stop button. A thin red
  frame marks the area, and the dock's pencil gets a red dot.
- Drawing keeps working, and the ink and the cursor are in the video. Pencil's own dock,
  hints, toasts and controls are not.
- Stop with **⌥5** again or the Stop button. It also stops on its own after 5 minutes.

The video is H.264 `.mp4` at 30fps, at the display's full resolution, with no audio. It's
saved as `~/Pictures/Pencil/pencil-rec-YYYYMMDD-HHmmss.mp4` and copied to the clipboard as
a file ("Recording copied (0:12)"). Recording needs macOS 15 and the same Screen Recording
permission as snapshots.

## Snapshots and Claude Code

⌥3 (whole screen), ⌥4 (region: drag an area and it's captured when you let go; Esc or
a plain click cancels) and ⏎ while drawing (just the drawing) save `~/Pictures/Pencil/pencil-YYYYMMDD-HHmmss.png`,
copy it to the clipboard, and show a short "Copied" toast. Your mode doesn't change and
your ink stays in the picture. Cancelling a region with Esc saves nothing and shows no toast.

The clipboard gets the file and the image (no text), so pasting gives you the picture:

- In **Claude Code**, press **Ctrl+V** in the prompt to paste the image (Ctrl+V, not ⌘V).
- In **Finder, Mail, Slack, chat apps, editors or a browser upload field**, ⌘V pastes the
  PNG itself. Recordings go on the clipboard as the `.mp4` file.

**One-time permission:** snapshots need Screen Recording access. Go to System
Settings → Privacy & Security → Screen Recording (or use **Open Screen Recording
settings** in Pencil's menu), turn on **Pencil**, then use **Relaunch Pencil** from the menu.
macOS only picks up the grant after a relaunch.

The grant is tied to the app's signature. Run `scripts/make-signing-identity.sh` once. It
creates a local "Pencil Local Signing" identity in your login keychain, and `bundle.sh` then
signs every build with it, so the grant survives rebuilds. Without it, builds are ad-hoc
signed and each rebuild needs the permission granted again. If captures still fail after
switching signatures, run `tccutil reset ScreenCapture com.haim.pencil`, relaunch Pencil,
and grant it once more.

## Menu bar

The menu bar item is a minimal fallback. It shows the current mode (the icon changes
with the mode, filled for Pen) and has Laser, Pen, **Snapshot screen**, **Capture region…**,
**Capture drawing**, **Start / Stop screen recording**, **Keyboard shortcuts…**, the Screen
Recording helpers, **Start at login** (on by default, set on first launch through
`SMAppService`), **Open snapshots folder**, and **Quit**.
