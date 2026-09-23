import AppKit
import PencilCore

/// The history sidebar: the full height of the screen's visible frame on the right edge,
/// solid near-black, sliding in and out from the edge.
///
/// Top to bottom: header (title, pause history, collapse), a banner while history is
/// paused, the search field, the current-clipboard card (hidden while searching), the
/// history list (a view-based NSTableView, so 1000 items cost only the visible rows),
/// and a footer with the count and "Clear history" (inline confirm).
///
/// It's a non-activating panel that CAN become key: opening it takes the keyboard
/// without activating Pencil, and closing it hands focus back to the previous app.
@MainActor
final class ClipboardPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let width: CGFloat = 360
    private static let headerHeight: CGFloat = 40
    private static let footerHeight: CGFloat = 36
    private static let bannerHeight: CGFloat = 34
    static let backgroundColor = NSColor(srgbRed: 0.078, green: 0.078, blue: 0.082, alpha: 1) // #141415
    private static let openDuration: CFTimeInterval = 0.22
    private static let closeDuration: CFTimeInterval = 0.2
    /// How far the sidebar travels while it fades in or out.
    private static let slideDistance: CGFloat = 56

    private enum Row {
        /// `member`: shown under an open folder.
        case item(ClipboardItem, member: Bool)
        /// Near-identical copies, or a burst, as one row (iOS-style folder).
        case folder(ClipboardGroup, open: Bool)
        case more(remaining: Int)
    }

    /// The one open folder (its `ClipboardGroup.key`); its members show as rows below it.
    private var openFolder: String?
    /// How many list entries (items and folders) exist beyond the shown ones.
    private var entryCount = 0

    var onVisibilityChange: ((Bool) -> Void)?
    private(set) var isOpen = false

    private unowned let history: ClipboardHistoryController
    private let window = ClipboardPanelWindow()
    private let slider = NSView()
    private let background = ClipboardSidebarBackground()
    private let titleLabel = ClipboardStyle.label(size: 13, weight: .semibold)
    private let pauseButton = ClipboardIconButton(symbol: "eye", size: 13, label: "Pause saving clipboard history")
    private let closeButton = ClipboardIconButton(symbol: "sidebar.right", size: 13, label: "Close")
    private let banner = NSView()
    private let bannerLabel = ClipboardStyle.label(size: 11.5, weight: .medium)
    private let bannerResume = ClipboardTextButton("Resume")
    private let search = NSSearchField()
    private let card = ClipboardCurrentCard()
    private let scroll = NSScrollView()
    private let table = ClipboardTableView()
    private let emptyLabel = ClipboardStyle.label(size: 12, color: ClipboardStyle.secondary)
    private let countLabel = ClipboardStyle.label(size: 11, color: ClipboardStyle.secondary)
    private let clearButton = ClipboardTextButton("Clear history…")
    private let confirmLabel = ClipboardStyle.label(size: 11.5, weight: .medium)
    private let confirmCancel = ClipboardTextButton("Cancel")
    private let confirmClear = ClipboardTextButton("Clear", destructive: true)
    private let preview = ClipboardPreviewPopup()

    private var rows: [Row] = []
    private var visibleCount = ClipboardStore.initialVisibleCount
    private var query = ""
    /// The query the table was last fully reloaded for (row notes depend on it).
    private var renderedQuery = ""
    private var confirming = false
    private var cardHeight: CGFloat = 80
    private var previousApp: NSRunningApplication?
    private var monitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?
    private var hoverWork: DispatchWorkItem?
    private var hoveredID: String?
    private var isDraggingRow = false
    private var generation = 0
    /// The sidebar's resting frame on screen (set on open).
    private var openFrame: NSRect = .zero
    private var footerMessageWork: DispatchWorkItem?

    init(history: ClipboardHistoryController) {
        self.history = history
        super.init()
        build()
        history.observe { [weak self] in
            guard let self, self.isOpen else { return }
            self.reload()
        }
    }

    // MARK: Build

    private func build() {
        let root = NSView()
        root.wantsLayer = true
        window.contentView = root
        slider.wantsLayer = true
        root.addSubview(slider)

        background.appearance = NSAppearance(named: .darkAqua)
        slider.addSubview(background)

        titleLabel.stringValue = "Clipboard"
        pauseButton.onClick = { [weak self] in
            guard let self else { return }
            self.history.setPaused(!self.history.isPaused)
        }
        closeButton.hint = "Close  " + ClipboardHistoryController.hotkeyLabel
        closeButton.onClick = { [weak self] in self?.close(restoreFocus: true) }

        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.16).cgColor
        banner.layer?.cornerRadius = 8
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.35).cgColor
        bannerLabel.stringValue = "History paused. New copies aren't saved."
        bannerLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        bannerResume.onClick = { [weak self] in self?.history.setPaused(false) }
        banner.addSubview(bannerLabel)
        banner.addSubview(bannerResume)

        search.placeholderString = "Search text, file names, text in images"
        search.delegate = self
        search.font = .systemFont(ofSize: 12)
        search.sendsSearchStringImmediately = true
        search.focusRingType = .none

        card.dragItemProvider = { [weak self] in
            guard let self, let current = self.history.store.current else { return nil }
            return self.history.dragPasteboardItem(for: current)
        }
        card.onDropRow = { [weak self] id in
            guard let self else { return }
            self.history.move(id: id, before: 0)
            self.card.flashCopied()
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.rowSizeStyle = .custom
        table.focusRingType = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.registerForDraggedTypes([ClipboardHistoryController.rowDragType])
        table.draggingDestinationFeedbackStyle = .gap
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.onReturn = { [weak self] in self?.activateSelection(close: true) }
        table.onCopy = { [weak self] in self?.activateSelection(close: false) }
        table.onDelete = { [weak self] in self?.deleteSelection() }
        table.onEscape = { [weak self] in self?.escape() }
        table.onFind = { [weak self] in self?.focusSearch(typing: nil) }
        table.onType = { [weak self] text in self?.focusSearch(typing: text) }
        table.onArrow = { [weak self] open in self?.arrow(open: open) }

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        emptyLabel.alignment = .center
        clearButton.onClick = { [weak self] in self?.setConfirming(true) }
        confirmCancel.onClick = { [weak self] in self?.setConfirming(false) }
        confirmClear.onClick = { [weak self] in
            self?.history.clearHistory()
            self?.setConfirming(false)
        }

        for v in [titleLabel, pauseButton, closeButton, banner, search, card, scroll, emptyLabel, countLabel,
                  clearButton, confirmLabel, confirmCancel, confirmClear] as [NSView] {
            background.addSubview(v)
        }
        window.initialFirstResponder = table
        window.onEscape = { [weak self] in self?.escape() }
        setConfirming(false)
    }

    // MARK: Open / close

    func open(on screen: NSScreen) {
        guard !isOpen else { return }
        isOpen = true
        generation += 1
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        query = ""
        search.stringValue = ""
        openFolder = nil
        visibleCount = ClipboardStore.initialVisibleCount
        confirming = false
        setConfirming(false)

        // Flush with the visible frame's right edge (left of a right-side Dock), running from its
        // bottom all the way to the top of the screen: the window sits just below the menu bar's
        // level, so the (often translucent) menu bar draws over the dark sidebar instead of over
        // wallpaper. Content starts below the menu bar via `topInset`.
        let v = screen.visibleFrame
        let w = Self.width
        let h = screen.frame.maxY - v.minY
        topInset = screen.frame.maxY - v.maxY
        let target = NSRect(x: v.maxX - w, y: v.minY, width: w, height: h)
        openFrame = target
        // One sheet: the WINDOW slides and fades as a whole; nothing inside animates on its own.
        let wasVisible = window.isVisible // reopened while a close was still running
        let gen = generation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slider.frame = NSRect(x: 0, y: 0, width: w, height: h)
        if !wasVisible {
            window.alphaValue = 0
            window.setFrame(target.offsetBy(dx: Self.slideDistance, dy: 0), display: false)
        } else if window.frame.size != target.size {
            window.setFrame(NSRect(origin: window.frame.origin, size: target.size), display: false)
        }
        reload()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.scrollRowToVisible(0)
        CATransaction.commit()

        // A non-activating panel that can become key: keyboard focus without activating Pencil.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.openDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.window.invalidateShadow()
            }
        })
        installMonitors()
        onVisibilityChange?(true)
    }

    /// `restoreFocus`: hand the keyboard back to the app that was in front (Esc, Return,
    /// the close button, the hotkey). Clicking into another app doesn't need it.
    func close(restoreFocus: Bool) {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        let gen = generation
        removeMonitors()
        hidePreview()
        HintCenter.shared.hide()
        setConfirming(false)
        onVisibilityChange?(false)

        // The whole window slides out and fades as one sheet; orderOut only at the end, then
        // alpha and frame are reset for the next open. A reopen mid-close bumps `generation`.
        let end = openFrame.offsetBy(dx: Self.slideDistance, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.closeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(end, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.window.orderOut(nil)
                self.window.alphaValue = 1
                self.window.setFrame(self.openFrame, display: false)
            }
        })

        if restoreFocus, let app = previousApp, !app.isTerminated,
           NSApp.isActive || NSWorkspace.shared.frontmostApplication == app {
            app.activate()
        }
        previousApp = nil
    }

    /// Clicking anywhere outside the panel closes it; so does switching to another app.
    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                          handler: { [weak self] _ in
            MainActor.assumeIsolated {
                // A Pencil capture or area picker in progress never closes the panel.
                guard !CaptureSession.isActive else { return }
                self?.close(restoreFocus: false)
            }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !CaptureSession.isActive else { return }
                // The dock (its Clipboard button toggles the sidebar) and its flyout don't count.
                if event.window !== self.window, !(event.window is DockPanel) {
                    self.close(restoreFocus: false)
                } else if event.window === self.window {
                    self.collapseIfClickedAway(event)
                }
            }
            return event
        }) {
            monitors.append(local)
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, !CaptureSession.isActive else { return }
                let isSelf = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
                if !isSelf, app != self.previousApp, !self.isDraggingRow { self.close(restoreFocus: false) }
            }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }

    // MARK: Data

    private func computeRows() -> [Row] {
        let store = history.store
        if isSearching {
            // Matches as flat rows: no folders while searching.
            entryCount = 0
            return store.filtered(query).map { Row.item($0, member: false) }
        }
        // Folders count as one entry toward "show 10", so duplicates never crowd the list.
        var entries = ClipboardGrouping.entries(store.items)
        // The current item is the card. On its own it isn't listed; if it has look-alikes,
        // their folder (which includes it) leads the list.
        if case .single? = entries.first { entries.removeFirst() }
        entryCount = entries.count
        let shown = entries.prefix(visibleCount)
        if let openFolder, !shown.contains(where: { $0.key == openFolder }) { self.openFolder = nil }
        var out: [Row] = []
        for entry in shown {
            switch entry {
            case .single(let item):
                out.append(.item(item, member: false))
            case .group(let group):
                let open = group.key == openFolder
                out.append(.folder(group, open: open))
                if open { out.append(contentsOf: group.items.map { Row.item($0, member: true) }) }
            }
        }
        let remaining = entries.count - shown.count
        return remaining > 0 ? out + [.more(remaining: remaining)] : out
    }

    private func reload() {
        let selectedID = selectedItem()?.id
        let selectedRow = table.selectedRow
        let old = rows
        rows = computeRows()
        hidePreview()
        if query != renderedQuery {
            // A new search: every row's "text in image" note may change.
            renderedQuery = query
            table.reloadData()
        } else {
            applyRowChanges(from: old, to: rows)
        }
        if let selectedID, let i = rows.firstIndex(where: { Self.key($0) == selectedID }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else if selectedRow >= 0, !rows.isEmpty {
            table.selectRowIndexes([min(selectedRow, rows.count - 1)], byExtendingSelection: false)
        }
        updateHeader()
        updateCard()
        updateFooter()
        layoutContent()
    }

    private static func key(_ row: Row) -> String {
        switch row {
        case .item(let item, let member): return member ? "member:" + item.id : item.id
        case .more: return "#more"
        case .folder(let group, _): return group.key
        }
    }

    private static func sameContent(_ a: Row, _ b: Row) -> Bool {
        switch (a, b) {
        case (.item(let x, _), .item(let y, _)): return x == y
        case (.more(let x), .more(let y)): return x == y
        case (.folder(let g, let o), .folder(let h, let p)): return g == h && o == p
        default: return false
        }
    }

    /// Updates the table in place: new rows slide in, removed rows fade out, rows whose
    /// content changed are refreshed, and the scroll position stays on the same rows.
    /// Falls back to a full reload for big reshuffles (search, first load).
    private func applyRowChanges(from old: [Row], to new: [Row]) {
        let diff = new.map(Self.key).difference(from: old.map(Self.key))
        guard window.isVisible, !old.isEmpty, diff.count <= 60 else {
            table.reloadData()
            return
        }
        var removals = IndexSet(), insertions = IndexSet()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }

        // Remember which row is at the top of the visible area (if scrolled) to keep it there.
        let clip = table.enclosingScrollView?.contentView
        var anchor: (key: String, offset: CGFloat)?
        if let clip, clip.bounds.minY > 1 {
            let top = table.row(at: NSPoint(x: 1, y: clip.bounds.minY + 1))
            if top >= 0, top < old.count {
                anchor = (Self.key(old[top]), table.rect(ofRow: top).minY - clip.bounds.minY)
            }
        }

        if !diff.isEmpty {
            table.beginUpdates()
            if !removals.isEmpty { table.removeRows(at: removals, withAnimation: .effectFade) }
            if !insertions.isEmpty { table.insertRows(at: insertions, withAnimation: .slideDown) }
            table.endUpdates()
        }

        let oldByKey = Dictionary(old.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let changed = IndexSet(new.indices.filter { i in
            guard !insertions.contains(i), let before = oldByKey[Self.key(new[i])] else { return false }
            return !Self.sameContent(before, new[i])
        })
        if !changed.isEmpty {
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<max(1, table.numberOfColumns)))
        }

        if let anchor, let clip, let i = new.firstIndex(where: { Self.key($0) == anchor.key }) {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, table.rect(ofRow: i).minY - anchor.offset)))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func updateHeader() {
        let paused = history.isPaused
        pauseButton.setSymbol(paused ? "eye.slash" : "eye", size: 13,
                              color: paused ? NSColor.systemOrange : NSColor.white.withAlphaComponent(0.8))
        let hint = paused ? "Resume saving clipboard history" : "Pause saving clipboard history"
        pauseButton.hint = hint
        pauseButton.setAccessibilityLabel(hint)
        banner.isHidden = !paused
    }

    private func updateCard() {
        // While searching, the results are the only thing shown; the current item appears
        // among them if it matches.
        card.isHidden = isSearching
        guard !isSearching else { return }
        let current = history.store.current
        let image = current.flatMap { history.thumbnails.cached($0, size: .large) ?? history.thumbnails.cached($0, size: .row) }
        cardHeight = card.show(current, image: image, width: Self.width - 20)
        guard let current, current.kind != .text, history.thumbnails.cached(current, size: .large) == nil else { return }
        let id = current.id
        history.thumbnails.load(current, size: .large) { [weak self] image in
            self?.card.setImage(image, for: id)
        }
    }

    private func updateFooter() {
        let store = history.store
        let pinned = store.items.filter(\.isPinned).count
        countLabel.stringValue = store.count == 0 ? "No history yet"
            : "\(store.count) item\(store.count == 1 ? "" : "s") · \(ClipboardFormat.bytes(store.totalBytes))"
        let clearable = store.count - pinned
        confirmLabel.stringValue = pinned > 0 ? "Clear \(clearable)? Pinned stay." : "Clear all \(clearable)?"
        clearButton.isEnabled = clearable > 0
        clearButton.alphaValue = clearable > 0 ? 1 : 0.4
        let q = query.trimmingCharacters(in: .whitespaces)
        emptyLabel.stringValue = isSearching ? "No matches for \u{201C}\(q)\u{201D}" : "Earlier copies show up here."
        emptyLabel.isHidden = !rows.isEmpty
    }

    private func setConfirming(_ on: Bool) {
        confirming = on
        countLabel.isHidden = on
        clearButton.isHidden = on
        confirmLabel.isHidden = !on
        confirmCancel.isHidden = !on
        confirmClear.isHidden = !on
    }

    /// A short message in the footer (e.g. a file that no longer exists).
    private func flashFooter(_ text: String) {
        footerMessageWork?.cancel()
        countLabel.stringValue = text
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.updateFooter() }
        }
        footerMessageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Layout

    /// Height of the menu-bar strip the window extends under; content is laid out below it.
    private var topInset: CGFloat = 0

    private func layoutContent() {
        let w = Self.width
        let h = window.frame.height
        slider.setFrameSize(NSSize(width: w, height: h))
        background.frame = NSRect(x: 0, y: 0, width: w, height: h)

        var top = h - topInset
        titleLabel.frame = NSRect(x: 16, y: top - 28, width: w - 100, height: 18)
        closeButton.frame = NSRect(x: w - 38, y: top - 31, width: 26, height: 24)
        pauseButton.frame = NSRect(x: w - 66, y: top - 31, width: 26, height: 24)
        top -= Self.headerHeight

        if !banner.isHidden {
            let bh = Self.bannerHeight
            banner.frame = NSRect(x: 12, y: top - bh, width: w - 24, height: bh)
            bannerResume.frame.origin = NSPoint(x: banner.frame.width - 8 - bannerResume.frame.width, y: (bh - 22) / 2)
            bannerLabel.frame = NSRect(x: 10, y: (bh - 16) / 2, width: bannerResume.frame.minX - 16, height: 16)
            top -= bh + 8
        }

        search.frame = NSRect(x: 12, y: top - 24, width: w - 24, height: 24)
        top -= 24 + 10

        if !card.isHidden {
            card.frame = NSRect(x: 10, y: top - cardHeight, width: w - 20, height: cardHeight)
            top -= cardHeight + 8
        }

        let fh = Self.footerHeight
        countLabel.frame = NSRect(x: 16, y: (fh - 15) / 2, width: w - 140, height: 15)
        clearButton.frame.origin = NSPoint(x: w - 12 - clearButton.frame.width, y: (fh - 22) / 2)
        confirmClear.frame.origin = NSPoint(x: w - 12 - confirmClear.frame.width, y: (fh - 22) / 2)
        confirmCancel.frame.origin = NSPoint(x: confirmClear.frame.minX - 6 - confirmCancel.frame.width, y: (fh - 22) / 2)
        confirmLabel.frame = NSRect(x: 16, y: (fh - 16) / 2, width: confirmCancel.frame.minX - 22, height: 16)

        scroll.frame = NSRect(x: 0, y: fh, width: w, height: max(40, top - fh))
        emptyLabel.frame = NSRect(x: 16, y: scroll.frame.maxY - 60, width: w - 32, height: 16)
        table.sizeLastColumnToFit()
    }

    // MARK: Actions

    private func selectedItem() -> ClipboardItem? {
        let r = table.selectedRow
        guard r >= 0, r < rows.count, case .item(let item, _) = rows[r] else { return nil }
        return item
    }

    @objc private func rowClicked() {
        let r = table.clickedRow
        guard r >= 0, r < rows.count else { return }
        switch rows[r] {
        case .more: showMore()
        case .item(let item, let member):
            // A click outside the open folder closes it (the click itself still counts).
            if !member { openFolder = nil }
            copy(item, close: false, flashRow: r)
        case .folder(let group, let open): folderActivated(group, open: open, row: r)
        }
    }

    /// Folders open in place. A burst is also made current (all of its files) when opened;
    /// a folder of look-alikes only opens, and a member is picked from inside.
    private func folderActivated(_ group: ClipboardGroup, open: Bool, row: Int) {
        if open {
            setFolder(nil)
            return
        }
        if case .burst(let batchID) = group.kind {
            flash(row: row)
            openFolder = group.key
            copyBatch(batchID, close: false)
        } else {
            setFolder(group.key)
        }
    }

    private func setFolder(_ key: String?) {
        guard openFolder != key else { return }
        openFolder = key
        reload()
        if let key, let i = rows.firstIndex(where: { Self.key($0) == key }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            // Bring the members into view.
            var members = 0
            if case .folder(let g, _) = rows[i] { members = g.items.count }
            let last = min(rows.count - 1, i + members)
            table.scrollRowToVisible(last)
            table.scrollRowToVisible(i)
        }
    }

    /// Clicks on the header, card, search or empty list area close an open folder. Clicks
    /// on rows are handled by `rowClicked` (so the row under the mouse doesn't shift first).
    private func collapseIfClickedAway(_ event: NSEvent) {
        guard openFolder != nil else { return }
        let p = table.convert(event.locationInWindow, from: nil)
        if table.visibleRect.contains(p), table.row(at: p) >= 0 { return }
        setFolder(nil)
    }

    /// Return (close: true) or ⌘C (close: false) on the selected row.
    private func activateSelection(close: Bool) {
        let r = table.selectedRow
        guard r >= 0, r < rows.count else {
            if close { self.close(restoreFocus: true) }
            return
        }
        switch rows[r] {
        case .more: showMore()
        case .item(let item, let member):
            if !member { openFolder = nil }
            copy(item, close: close, flashRow: close ? nil : r)
        case .folder(let group, let open):
            if open || !close {
                // ⌘C, or Return on an open folder: its newest member.
                copy(group.newest, close: close, flashRow: close ? nil : r)
            } else {
                folderActivated(group, open: false, row: r)
            }
        }
    }

    /// → opens the selected folder; ← closes it (from the folder or one of its members).
    private func arrow(open: Bool) {
        let r = table.selectedRow
        guard r >= 0, r < rows.count else { return }
        switch rows[r] {
        case .folder(let group, let isOpen):
            if open, !isOpen { folderActivated(group, open: false, row: r) }
            if !open, isOpen { setFolder(nil) }
        case .item(_, member: true) where !open:
            let key = openFolder
            setFolder(nil)
            if let key, let i = rows.firstIndex(where: { Self.key($0) == key }) {
                table.selectRowIndexes([i], byExtendingSelection: false)
            }
        default:
            break
        }
    }

    private func flash(row: Int) {
        (table.rowView(atRow: row, makeIfNecessary: false) as? ClipboardRowView)?.flashAccent()
    }

    /// Clicking a burst makes the whole batch current and opens it.
    private func copyBatch(_ id: String, close: Bool) {
        switch history.copyBatch(id) {
        case .copied:
            card.flashCopied()
            if close { self.close(restoreFocus: true) }
        case .missingFiles:
            flashFooter("Those files no longer exist")
            reload()
        case .notFound:
            break
        }
    }

    /// `flashRow`: the clicked row washes with the accent first, so the eye follows it up.
    private func copy(_ item: ClipboardItem, close: Bool, flashRow: Int? = nil) {
        let perform = { [weak self] in
            guard let self else { return }
            switch self.history.copy(id: item.id) {
            case .copied:
                self.card.flashCopied()
                if let i = self.rows.firstIndex(where: { Self.key($0) == item.id }) ?? (self.rows.isEmpty ? nil : 0) {
                    self.table.selectRowIndexes([i], byExtendingSelection: false)
                }
                if close { self.close(restoreFocus: true) }
            case .missingFiles:
                self.flashFooter("That file no longer exists")
            case .notFound:
                break
            }
        }
        guard let flashRow else { return perform() }
        flash(row: flashRow)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            MainActor.assumeIsolated { perform() }
        }
    }

    private func deleteSelection() {
        guard let item = selectedItem() else { return }
        let r = table.selectedRow
        history.delete(id: item.id)
        if !rows.isEmpty { table.selectRowIndexes([min(r, rows.count - 1)], byExtendingSelection: false) }
    }

    private func escape() {
        if openFolder != nil {
            setFolder(nil)
        } else if !search.stringValue.isEmpty {
            search.stringValue = ""
            filterChanged()
            window.makeFirstResponder(table)
        } else if confirming {
            setConfirming(false)
        } else {
            close(restoreFocus: true)
        }
    }

    private func focusSearch(typing text: String?) {
        window.makeFirstResponder(search)
        guard let text, let editor = search.currentEditor() as? NSTextView else { return }
        let end = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.insertText(text, replacementRange: NSRange(location: end, length: 0))
    }

    private func showMore() {
        visibleCount = ClipboardStore.visibleCount(afterShowingMore: visibleCount, total: entryCount)
        reload()
    }

    private func filterChanged() {
        query = search.stringValue
        visibleCount = ClipboardStore.initialVisibleCount
        reload()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.scrollRowToVisible(0)
    }

    @objc private func scrolled() {
        hidePreview()
        // After the first "Show more", scrolling to the end keeps loading.
        guard isOpen, !isSearching, visibleCount > ClipboardStore.initialVisibleCount,
              case .more? = rows.last else { return }
        let visible = scroll.contentView.documentVisibleRect
        if visible.maxY >= table.bounds.height - 120 { showMore() }
    }

    // MARK: Hover preview

    private func rowHover(_ rowView: ClipboardRowView, inside: Bool) {
        hoverWork?.cancel()
        guard inside, !isDraggingRow else {
            if hoveredID != nil { hidePreview() }
            return
        }
        let r = table.row(for: rowView)
        guard r >= 0, r < rows.count, case .item(let item, _) = rows[r] else { return }
        hoveredID = item.id
        let work = DispatchWorkItem { [weak self, weak rowView] in
            MainActor.assumeIsolated {
                guard let self, let rowView, self.hoveredID == item.id, self.isOpen else { return }
                self.showPreview(item, rowView: rowView)
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func showPreview(_ item: ClipboardItem, rowView: NSView) {
        guard let win = rowView.window else { return }
        let rect = win.convertToScreen(rowView.convert(rowView.bounds, to: nil))
        let thumbs = history.thumbnails
        if item.kind == .text {
            preview.show(item, text: history.fullText(of: item), image: nil, rowRect: rect, panelFrame: window.frame)
            return
        }
        let quick = thumbs.cached(item, size: .large) ?? thumbs.cached(item, size: .row)
        if quick != nil {
            preview.show(item, text: nil, image: quick, rowRect: rect, panelFrame: window.frame)
        }
        guard thumbs.cached(item, size: .large) == nil else { return }
        thumbs.load(item, size: .large) { [weak self] image in
            guard let self, self.hoveredID == item.id, self.isOpen, let image else { return }
            self.preview.show(item, text: nil, image: image, rowRect: rect, panelFrame: self.window.frame)
        }
    }

    private func hidePreview() {
        hoverWork?.cancel()
        hoveredID = nil
        preview.hide()
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return ClipboardRowCell.height }
        if case .more = rows[row] { return ClipboardShowMoreCell.height }
        if case .folder = rows[row] { return ClipboardFolderCell.height }
        return ClipboardRowCell.height
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("clipboard.rowview")
        let view = (tableView.makeView(withIdentifier: id, owner: nil) as? ClipboardRowView) ?? {
            let v = ClipboardRowView()
            v.identifier = id
            return v
        }()
        view.resetHover()
        view.onHover = { [weak self, weak view] inside in
            guard let self, let view else { return }
            self.rowHover(view, inside: inside)
        }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .more(let remaining):
            let cell = (tableView.makeView(withIdentifier: ClipboardShowMoreCell.identifier, owner: nil)
                as? ClipboardShowMoreCell) ?? ClipboardShowMoreCell(frame: .zero)
            cell.configure(remaining: remaining)
            return cell
        case .folder(let group, let open):
            let cell = (tableView.makeView(withIdentifier: ClipboardFolderCell.identifier, owner: nil)
                as? ClipboardFolderCell) ?? ClipboardFolderCell(frame: .zero)
            cell.configure(group, open: open, thumbnails: history.thumbnails, now: Date())
            return cell
        case .item(let item, let member):
            let cell = (tableView.makeView(withIdentifier: ClipboardRowCell.identifier, owner: nil)
                as? ClipboardRowCell) ?? ClipboardRowCell(frame: .zero)
            cell.isHovered = false
            cell.indent = member ? 10 : 0
            cell.configure(item, thumbnails: history.thumbnails, now: Date(),
                           matchedInImage: isSearching && item.matchesOnlyInImageText(query))
            let id = item.id
            cell.onPin = { [weak self] in self?.history.togglePin(id: id) }
            cell.onDelete = { [weak self] in self?.history.delete(id: id) }
            return cell
        }
    }

    // Drag out (file URL / text) and drag to reorder (private row type).

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .item(let item, _): return history.dragPasteboardItem(for: item)
        case .folder(let group, _): return history.dragPasteboardItem(for: group.newest) // moves the folder
        case .more: return nil
        }
    }

    /// Where a drop above list row `row` lands in the store: before that row's item (a
    /// folder's newest member), or after the last shown item at the end. Row 0 = current.
    private func storeIndex(forDropRow row: Int) -> Int {
        let store = history.store
        if row <= 0 { return 0 }
        func index(of r: Row) -> Int? {
            switch r {
            case .item(let item, _): return store.index(of: item.id)
            case .folder(let group, _): return store.index(of: group.newest.id)
            case .more: return nil
            }
        }
        if row < rows.count, let i = index(of: rows[row]) { return i }
        let lastShown = rows.compactMap(index(of:)).max() ?? (store.count - 1)
        return min(store.count, lastShown + 1)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        isDraggingRow = true
        hidePreview()
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingRow = false
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !isSearching,
              (info.draggingSource as? NSTableView) === table,
              info.draggingPasteboard.string(forType: ClipboardHistoryController.rowDragType) != nil
        else { return [] }
        var target = row
        if case .more? = rows.last { target = min(target, rows.count - 1) } // never below "Show more"
        if dropOperation == .on || target != row { tableView.setDropRow(target, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: ClipboardHistoryController.rowDragType) else { return false }
        history.move(id: id, before: storeIndex(forDropRow: row))
        if row == 0 { card.flashCopied() }
        return true
    }

    // MARK: Search field

    func controlTextDidChange(_ obj: Notification) {
        filterChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            window.makeFirstResponder(table)
            if table.selectedRow < 0, !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection(close: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            escape()
            return true
        default:
            return false
        }
    }
}

// MARK: - Window

/// Non-activating, but it can become key so the keyboard works while it's open.
final class ClipboardPanelWindow: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: ClipboardPanelController.width, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Just below the menu bar, so the menu bar draws over the sidebar's top strip. That is
        // below the ink overlay too, which only matters while a drawing mode is on.
        // Transparent so the content can slide in from the edge; the sidebar itself is solid.
        // isFloatingPanel resets the level to .floating, so it must come first.
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Pencil has no Edit menu, so the usual text shortcuts are routed by hand for the filter field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags == .command, firstResponder is NSText {
            let action: Selector?
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "x": action = #selector(NSText.cut(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Table

/// Keyboard for the list: ↑/↓ (built in), →/← (open/close a folder), Return, ⌫, Esc, ⌘F,
/// ⌘C, and typing to search.
final class ClipboardTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFind: (() -> Void)?
    var onType: ((String) -> Void)?
    var onArrow: ((_ open: Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: onReturn?(); return            // Return, Enter
        case 51, 117: onDelete?(); return           // Delete, Forward Delete
        case 53: onEscape?(); return                // Esc
        case 124: onArrow?(true); return            // → opens a folder
        case 123: onArrow?(false); return           // ← closes it
        default: break
        }
        let bare = event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.command) {
            if bare == "f" { onFind?(); return }
            if bare == "c" { onCopy?(); return }
            super.keyDown(with: event)
            return
        }
        if !flags.contains(.control), let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }) {
            onType?(chars)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Background

/// Solid near-black with a hairline on the left edge. No vibrancy: nothing behind shows through.
final class ClipboardSidebarBackground: NSView {
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        ClipboardPanelController.backgroundColor.setFill()
        bounds.fill()
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }
}
