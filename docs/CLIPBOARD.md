# Clipboard history

Everything Pencil captures lands on the clipboard, and chat apps only show a pasted
image as "image". The clipboard history lets you see what's on the clipboard and pick
anything you copied earlier.

## Using it

- Open it with the **Clipboard** button in the Pencil toolbar (its own group, just above
  Off), with **⌃⌘V**, or with **Clipboard history** in the menu-bar menu. A dark sidebar
  slides in from the right edge of the screen under the mouse. It fills the full height of the
  screen and is 360pt wide, with a solid near-black background and nothing behind it showing
  through. While it's open, the toolbar's Clipboard button is highlighted.
  - **Current clipboard** card at the top: the image itself, the first lines of text, or
    the file's preview and name, plus when it was copied.
  - **History** below it, newest first. The first 10 are shown; **Show more** adds 50, and
    after that scrolling to the end keeps loading.
- **Click a row** to put it back on the clipboard. It moves to the top and the card flashes
  "Copied". What goes back on the clipboard:
  - images, and single image files such as Pencil snapshots: the file URL plus PNG and TIFF
    (TIFF is left out for PNGs over 8 MB)
  - other files: file URLs only
  - text: the text, plus its rich-text version when one was kept

  A picture or file never comes back with its path as plain text. Otherwise apps that
  check for text first would paste the path instead of the image.
- **Folders.** Copies that are "the same" fold into one row, like an iPhone home-screen
  folder: a small frosted tile with a 2×2 grid of the members and a soft count badge. The
  row's title and subtitle are the newest member's. "The same" means:
  - text that's identical after trimming whitespace
  - files with the same set of paths
  - images and image files with the same size (within 2px) and a perceptual hash (dHash)
    within 6 bits, so repeated screenshots of the same area group even though their bytes
    differ

  Burst captures are folders too. A folder sits where its newest member is, and counts as
  one entry toward the first 10, so duplicates never push other items out of view.
  - Click a folder to open it: its members appear as normal rows right below it, and the
    tile's border brightens. Click a member to make it current. Clicking anything else,
    inside or outside the sidebar, or pressing Esc, closes the folder. Only one folder is
    open at a time. → or Return opens the selected folder, and ← closes it.
  - Clicking a burst folder also makes the whole burst current (all of its files on the
    clipboard).
  - While searching, matches show as plain rows, with no folders.
- **Current card feedback.** The current-clipboard card always has a thin green border (this
  is what ⌘V pastes). When something becomes current by click, Return, dragging to the top,
  or opening a burst:
  - the clicked row flashes green
  - the card's border flares to 2pt with a soft glow for about 1.2s
  - a "✓ Copied" badge pops in and fades
  - the card gives a small bounce, which Reduce Motion skips
- **Drag a row out** into another app. Images and files arrive as files, which chat apps
  and Finder accept, and text arrives as text. The current card can be dragged out too.
- **Drag a row up or down** to reorder. Dropping it above the first row, or onto the card,
  makes it the current clipboard.
- **Hover a row** for a larger preview beside the sidebar, plus **pin** and **delete** buttons.
  Pinned items are never pruned, and clearing the history keeps them.
- **Search** (the field under the header, "Search text, file names, text in images") matches
  every word you type against an item's text, its file names and type, and **text found in
  images**. Screenshots and other images are OCR'd in the background. While you search, the
  current-clipboard card is hidden and the list shows only the matches, including the current
  item if it matches. A row that matched only because of text in its image says "text in
  image" in its subtitle. With no matches, the list says "No matches for “…”".
- **Keyboard** (the sidebar takes focus while it's open):

  | Key | |
  | --- | --- |
  | ↑ / ↓ | Select |
  | Return | Copy the selected item and close |
  | ⌘C | Copy the selected item, keep the sidebar open |
  | ⌫ | Delete the selected item |
  | ⌘F, or just start typing | Search |
  | Esc | Clear the search, or close |

- **Pause history** (the eye button in the header) stops saving new copies until you resume.
  While it's paused, the button shows a crossed-out eye and a banner under the header says
  "History paused. New copies aren't saved." with a **Resume** button. The setting is
  remembered.
- **Clear history…** in the footer asks inline for confirmation, with no dialog. Pinned
  items stay.
- The sidebar closes with Esc, Return, ⌃⌘V, the collapse button in the header (or the
  toolbar's Clipboard button), a click outside it, or switching to another app. All of these
  except clicking or switching away hand focus back to the app you were in.

## What's saved, and what isn't

The pasteboard is checked every 0.4s. On each change, Pencil saves one item:

| Pasteboard has | Saved as |
| --- | --- |
| File URLs (Finder copies, Pencil captures) | **file**: paths, type, size, and a thumbnail (ImageIO for images, Quick Look for videos, PDFs and other files) |
| Image data (PNG, TIFF, JPEG, HEIC) with no real text | **image**: stored as a PNG plus a thumbnail |
| Text | **text**: the plain string, plus RTF when it's 1 MB or smaller |

A Pencil capture (file URL plus PNG, with or without a path string) is one file item. It's
identified by its path, so copying it again moves it to the top instead of adding a duplicate.
A picture next to real text, which Office, Pages and Numbers add, counts as text. A picture
next to a one-line URL or path, which browsers add, counts as an image.

**Text in images (OCR):** image items and single image files get Vision text recognition
(accurate, with language correction), one at a time, off the main thread. New copies go
first. Items saved before OCR existed are processed in the background at low priority. The
text is stored with the item (`ocrText` in the index, capped at 20,000 characters) and is only
used for search.

**Never saved:** anything that carries `org.nspasteboard.ConcealedType`,
`org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType`, or any
`com.agilebits.*` type (1Password). That covers password managers. Nothing is saved while
history is paused, and Pencil's own writes (picking a row) are never saved again.

**Duplicates:** content that's already in the history (same text, same image bytes, or the
same file paths) moves that item to the top instead of adding a new one.

**Deleting the current item** also takes it off the clipboard: the next item becomes
current, or the clipboard is cleared if nothing is left. That way a secret you copied by
mistake is really gone. **Clear history** does the same.

## Storage

`~/Library/Application Support/Pencil/Clipboard/`

```
index.json              order + metadata (+ text up to 32K characters, OCR text, image hash)
items/<id>/             one folder per item:
  clipboard-<time>.png    the image (image items)
  thumb.png               thumbnail (images and files)
  rich.rtf                rich text, when kept
  text.txt                full text, for text longer than 32K characters
```

- The history survives relaunches. On launch, image items whose PNG is missing are
  dropped, and item folders that no index entry refers to are deleted.
- Limits: **1000 items or 2 GB**, whichever is hit first. The oldest items go first, where
  "oldest" means the bottom of the list, so dragging an item up keeps it longer.
  **Pinned items and the current clipboard are never pruned.** Copied files are not copied
  into the store, so only their thumbnails count toward the 2 GB.
- A corrupt `index.json` is renamed to `index.corrupt-<time>.json` and the history starts
  empty.

## Code

| File | What |
| --- | --- |
| `Sources/PencilCore/ClipboardStore.swift` | `ClipboardItem`, `ClipboardStore` (order, dedupe, move-to-top, reorder, pin, prune, search incl. OCR text, paging), `ClipboardIndex` (JSON) |
| `Sources/PencilCore/ClipboardStoreDisk.swift` | Index and blob files, orphan sweep |
| `Sources/PencilCore/ClipboardStoreSimilarity.swift` | dHash, the "same" rule, and folder grouping |
| `Sources/PencilCore/ClipboardStoreSupport.swift` | Privacy filter, content classifier, file fingerprint, relative time and subtitles |
| `Sources/Pencil/ClipboardHistoryController.swift` | The entry point: owns the store, the save pipeline, OCR, actions and index saving |
| `Sources/Pencil/ClipboardWatcher.swift` | Pasteboard polling and reading, background processing (hash, PNG, thumbnails), writing items back |
| `Sources/Pencil/ClipboardOCR.swift` | Vision text recognition for images, one at a time, off the main thread |
| `Sources/Pencil/ClipboardThumbnails.swift` | Off-main thumbnail and preview loading with an NSCache (ImageIO, Quick Look) |
| `Sources/Pencil/ClipboardPanel.swift` | The sidebar: window, layout, search, paused banner, table data source, keyboard, drag and drop |
| `Sources/Pencil/ClipboardRows.swift` | Row and cell views, the current-clipboard card, the hover preview |

The PencilCore parts are AppKit-free and covered by `ClipboardStoreTests`,
`ClipboardStoreDiskTests` and `ClipboardStoreSupportTests`.

## Integration

Wired in:
- `App.swift`: `ClipboardHistoryController.shared.start()` at launch, and ⌃⌘V registered
  to `toggle()`.
- `StatusMenu.swift`: the **Clipboard history** item.
- `Dock.swift`: the Clipboard group in the toolbar. Its highlight follows
  `observeOpen`.

If you change the hotkey, change `ClipboardHistoryController.hotkeyLabel` too, because the
hints show it.
