import AppKit
import PencilCore

// MARK: - Shared style

enum ClipboardStyle {
    static let text = NSColor.white.withAlphaComponent(0.92)
    static let secondary = NSColor.white.withAlphaComponent(0.5)
    static let groupFill = NSColor.white.withAlphaComponent(0.07)
    static let groupStroke = NSColor.white.withAlphaComponent(0.06)
    /// "This is what ⌘V pastes": a clear green that reads well on the #141415 sidebar.
    static let accent = NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1) // #34C759

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A transform that scales a layer about its center (AppKit layers anchor at 0,0).
    static func scale(_ s: CGFloat, in bounds: CGRect) -> CATransform3D {
        let cx = bounds.midX, cy = bounds.midY
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium,
                       color: NSColor = NSColor.white.withAlphaComponent(0.8)) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    static func label(size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = text) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.cell?.truncatesLastVisibleLine = true
        return l
    }

    /// The symbol shown for items without a picture.
    static func placeholderSymbol(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return item.isVideo ? "film" : "doc"
        }
    }
}

/// A small borderless icon button for the row actions and the sidebar header, with an
/// optional hover hint (standard tooltips don't show for a non-activating panel).
final class ClipboardIconButton: NSButton {
    var onClick: (() -> Void)?
    var hint: String?
    private var hoverArea: NSTrackingArea?

    init(symbol: String, size: CGFloat = 12, label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setSymbol(symbol, size: size)
        setAccessibilityLabel(label)
        target = self
        action = #selector(fire)
        focusRingType = .none
        refusesFirstResponder = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSymbol(_ name: String, size: CGFloat = 12, color: NSColor = NSColor.white.withAlphaComponent(0.8)) {
        image = ClipboardStyle.symbol(name, size: size, color: color)
    }

    @objc private func fire() {
        HintCenter.shared.hide()
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard let hint, let window else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        HintCenter.shared.schedule(hint, anchor: anchor, placement: .below, owner: self)
    }

    override func mouseExited(with event: NSEvent) {
        HintCenter.shared.cancel(owner: self)
    }
}

/// A small text button ("Clear…", "Cancel", "Clear") matching the dark panel.
final class ClipboardTextButton: NSButton {
    var onClick: (() -> Void)?

    init(_ title: String, destructive: Bool = false) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = (destructive ? NSColor.systemRed.withAlphaComponent(0.75)
                                              : NSColor.white.withAlphaComponent(0.1)).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ])
        target = self
        action = #selector(fire)
        sizeToFit()
        frame.size.width += 16
        frame.size.height = 22
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { onClick?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Row

/// Selection and hover backgrounds as soft rounded rects (not the system blue bar).
final class ClipboardRowView: NSTableRowView {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false {
        didSet {
            needsDisplay = true
            (view(atColumn: 0) as? ClipboardRowCell)?.isHovered = isHovered
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover?(false)
    }

    func resetHover() {
        if isHovered { isHovered = false }
    }

    /// A quick accent wash, so the eye follows the row as it becomes the current clipboard.
    func flashAccent() {
        wantsLayer = true
        guard let root = layer else { return }
        let wash = CAShapeLayer()
        wash.frame = bounds
        wash.path = CGPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), cornerWidth: 8, cornerHeight: 8, transform: nil)
        wash.fillColor = ClipboardStyle.accent.withAlphaComponent(0.30).cgColor
        wash.strokeColor = ClipboardStyle.accent.withAlphaComponent(0.8).cgColor
        wash.lineWidth = 1.5
        wash.opacity = 0
        root.addSublayer(wash)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.5, 1]
        fade.duration = 0.5
        CATransaction.begin()
        CATransaction.setCompletionBlock { wash.removeFromSuperlayer() }
        wash.add(fade, forKey: "flash")
        CATransaction.commit()
    }

    override var isEmphasized: Bool { get { false } set {} }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

/// One history row: thumbnail (or a symbol for text), title, "5m ago · 1280×720",
/// and pin/delete on hover.
final class ClipboardRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("clipboard.row")
    static let height: CGFloat = 54

    var onPin: (() -> Void)?
    var onDelete: (() -> Void)?
    var isHovered = false { didSet { updateActions() } }

    private let thumbBox = CALayer()
    private let thumbLayer = CALayer()
    private let symbolLayer = CALayer()
    private let playBadge = CALayer()
    private let title = ClipboardStyle.label(size: 12.5, weight: .medium)
    private let subtitle = ClipboardStyle.label(size: 11, color: ClipboardStyle.secondary)
    private let pinBadge = NSImageView()
    private let pinButton = ClipboardIconButton(symbol: "pin", label: "Pin")
    private let deleteButton = ClipboardIconButton(symbol: "trash", label: "Delete")
    private(set) var itemID: String?
    private var isPinned = false
    /// Extra left inset for members of an expanded burst.
    var indent: CGFloat = 0 { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        thumbBox.cornerRadius = 7
        thumbBox.masksToBounds = true
        thumbBox.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        thumbBox.borderWidth = 0.5
        thumbBox.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        thumbLayer.contentsGravity = .resizeAspectFill
        symbolLayer.contentsGravity = .center
        playBadge.contents = ClipboardStyle.symbol("play.circle.fill", size: 14, color: .white)
        playBadge.contentsGravity = .center
        playBadge.shadowOpacity = 0.5
        playBadge.shadowRadius = 2
        playBadge.shadowOffset = .zero
        thumbBox.addSublayer(thumbLayer)
        thumbBox.addSublayer(symbolLayer)
        thumbBox.addSublayer(playBadge)
        layer?.addSublayer(thumbBox)

        pinBadge.image = ClipboardStyle.symbol("pin.fill", size: 9, color: NSColor.white.withAlphaComponent(0.55))
        for v in [title, subtitle, pinBadge, pinButton, deleteButton] as [NSView] { addSubview(v) }
        pinButton.onClick = { [weak self] in self?.onPin?() }
        deleteButton.onClick = { [weak self] in self?.onDelete?() }
        updateActions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        for l in [thumbBox, thumbLayer, symbolLayer, playBadge] { l.contentsScale = s }
    }

    /// `matchedInImage`: the current search matched this item only through its OCR text.
    func configure(_ item: ClipboardItem, thumbnails: ClipboardThumbnails, now: Date, matchedInImage: Bool = false) {
        itemID = item.id
        isPinned = item.isPinned
        let t = item.title
        title.stringValue = t.isEmpty ? "(blank)" : t
        subtitle.stringValue = ClipboardFormat.subtitle(for: item, now: now) + (matchedInImage ? " · text in image" : "")
        setAccessibilityLabel("\(title.stringValue), \(subtitle.stringValue)")
        pinButton.setSymbol(item.isPinned ? "pin.slash" : "pin")
        pinButton.setAccessibilityLabel(item.isPinned ? "Unpin" : "Pin")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playBadge.isHidden = !item.isVideo
        symbolLayer.contents = ClipboardStyle.symbol(ClipboardStyle.placeholderSymbol(for: item), size: 15)
        let cached = thumbnails.cached(item, size: .row)
        setThumb(cached)
        CATransaction.commit()

        if cached == nil, item.kind != .text {
            let id = item.id
            thumbnails.load(item, size: .row) { [weak self] image in
                guard let self, self.itemID == id else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.setThumb(image)
                CATransaction.commit()
            }
        }
        updateActions()
        needsLayout = true
    }

    private func setThumb(_ image: NSImage?) {
        thumbLayer.contents = image
        thumbLayer.isHidden = image == nil
        symbolLayer.isHidden = image != nil
    }

    private func updateActions() {
        pinButton.isHidden = !isHovered
        deleteButton.isHidden = !isHovered
        pinBadge.isHidden = isHovered || !isPinned
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let side: CGFloat = 40
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbBox.frame = CGRect(x: 14 + indent, y: (h - side) / 2, width: side, height: side)
        thumbLayer.frame = thumbBox.bounds
        symbolLayer.frame = thumbBox.bounds
        playBadge.frame = thumbBox.bounds
        CATransaction.commit()

        let x: CGFloat = 14 + indent + side + 10
        let trailing: CGFloat = isHovered ? 62 : (isPinned ? 26 : 12)
        let w = max(20, bounds.width - x - trailing)
        title.frame = NSRect(x: x, y: h / 2 + 1, width: w, height: 17)
        subtitle.frame = NSRect(x: x, y: h / 2 - 16, width: w, height: 15)
        pinBadge.frame = NSRect(x: bounds.width - 24, y: h / 2 + 3, width: 12, height: 12)
        deleteButton.frame = NSRect(x: bounds.width - 34, y: (h - 22) / 2, width: 24, height: 22)
        pinButton.frame = NSRect(x: bounds.width - 58, y: (h - 22) / 2, width: 24, height: 22)
    }
}

/// A folder: the newest member's title and subtitle next to a small frosted "glass" tile
/// holding a 2×2 grid of member thumbnails (or tiny text snippets), with a soft count badge.
/// Used for near-identical copies and for bursts alike; it sits in the same slot as a
/// normal row's thumbnail so it blends into the list.
final class ClipboardFolderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("clipboard.folder")
    static let height: CGFloat = ClipboardRowCell.height
    static let tileSide: CGFloat = 40

    private let tile = CALayer()
    private let highlight = CAGradientLayer()
    private var cells: [CALayer] = []
    private var snippets: [CATextLayer] = []
    private let badge = CATextLayer()
    private let badgeBack = CALayer()
    private let title = ClipboardStyle.label(size: 12.5, weight: .medium)
    private let subtitle = ClipboardStyle.label(size: 11, color: ClipboardStyle.secondary)
    private var ids: [String] = []
    private var isOpen = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        tile.cornerRadius = 10
        tile.masksToBounds = true
        tile.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        tile.borderWidth = 1
        // Soft inner highlight across the top, like light on frosted glass.
        highlight.colors = [NSColor.white.withAlphaComponent(0.14).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        highlight.startPoint = CGPoint(x: 0.5, y: 1)
        highlight.endPoint = CGPoint(x: 0.5, y: 0.45)
        tile.addSublayer(highlight)
        for _ in 0..<4 {
            let c = CALayer()
            c.cornerRadius = 3.5
            c.masksToBounds = true
            c.contentsGravity = .resizeAspectFill
            c.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
            tile.addSublayer(c)
            cells.append(c)
            let t = CATextLayer()
            t.fontSize = 3.6
            t.font = NSFont.systemFont(ofSize: 4, weight: .medium)
            t.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
            t.isWrapped = true
            t.truncationMode = .end
            c.addSublayer(t)
            snippets.append(t)
        }
        layer?.addSublayer(tile)
        badgeBack.backgroundColor = NSColor(white: 0.28, alpha: 0.95).cgColor
        badgeBack.borderWidth = 0.5
        badgeBack.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        badge.fontSize = 9
        badge.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        badgeBack.addSublayer(badge)
        layer?.addSublayer(badgeBack)
        for v in [title, subtitle] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        ([tile, highlight, badge, badgeBack] + cells + snippets).forEach { $0.contentsScale = s }
    }

    func configure(_ group: ClipboardGroup, open: Bool, thumbnails: ClipboardThumbnails, now: Date) {
        let newest = group.newest
        ids = group.items.map(\.id)
        isOpen = open
        let t = newest.title
        title.stringValue = t.isEmpty ? "(blank)" : t
        subtitle.stringValue = ClipboardFormat.subtitle(for: newest, now: now)
        setAccessibilityLabel("\(title.stringValue), \(group.items.count) copies, \(subtitle.stringValue)")
        setAccessibilityRole(.disclosureTriangle)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.borderColor = NSColor.white.withAlphaComponent(open ? 0.34 : 0.18).cgColor
        tile.backgroundColor = NSColor.white.withAlphaComponent(open ? 0.12 : 0.09).cgColor
        badge.string = "\(group.items.count)"
        let members = Array(group.items.prefix(4))
        for (i, cell) in cells.enumerated() {
            guard i < members.count else {
                cell.isHidden = true
                continue
            }
            cell.isHidden = false
            let m = members[i]
            let isText = m.kind == .text
            snippets[i].isHidden = !isText
            snippets[i].string = isText ? String((m.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) : ""
            cell.contents = isText ? nil : thumbnails.cached(m, size: .row)
            if !isText, cell.contents == nil {
                let id = m.id
                thumbnails.load(m, size: .row) { [weak self, weak cell] image in
                    guard let self, let cell, self.ids.contains(id) else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    cell.contents = image
                    CATransaction.commit()
                }
            }
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let side = Self.tileSide
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.frame = CGRect(x: 14, y: (h - side) / 2, width: side, height: side)
        highlight.frame = tile.bounds
        let pad: CGFloat = 4, gap: CGFloat = 2.5
        let c = (side - pad * 2 - gap) / 2
        for (i, cell) in cells.enumerated() {
            let col = CGFloat(i % 2), row = CGFloat(i / 2)
            // Row 0 on top (the newest in the top-left, like an iOS folder).
            cell.frame = CGRect(x: pad + col * (c + gap), y: side - pad - c - row * (c + gap), width: c, height: c)
            snippets[i].frame = cell.bounds.insetBy(dx: 1.5, dy: 1.5)
        }
        let bw: CGFloat = max(15, CGFloat(badge.string.map { "\($0)".count } ?? 1) * 6 + 7), bh: CGFloat = 14
        badgeBack.frame = CGRect(x: tile.frame.maxX - bw + 5, y: tile.frame.maxY - bh + 4, width: bw, height: bh)
        badgeBack.cornerRadius = bh / 2
        badge.frame = CGRect(x: 0, y: 1, width: bw, height: bh - 2)
        CATransaction.commit()

        let x: CGFloat = 14 + side + 10
        let w = max(20, bounds.width - x - 12)
        title.frame = NSRect(x: x, y: h / 2 + 1, width: w, height: 17)
        subtitle.frame = NSRect(x: x, y: h / 2 - 16, width: w, height: 15)
    }
}

/// The last row while older items are hidden.
final class ClipboardShowMoreCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("clipboard.more")
    static let height: CGFloat = 34
    private let label = ClipboardStyle.label(size: 11.5, weight: .medium, color: NSColor.white.withAlphaComponent(0.65))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(remaining: Int) {
        label.stringValue = "Show more  ·  \(remaining) older"
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
    }
}

// MARK: - Current clipboard card

/// The larger card at the top of the panel: the actual image (aspect-fit), the first
/// lines of text, or the file's thumbnail and name, plus when it was copied. It is a drag
/// source (drag the current item into another app) and a drop target (drop a row on it
/// to make that row current).
final class ClipboardCurrentCard: NSView, NSDraggingSource {
    var onDropRow: ((String) -> Void)?
    var dragItemProvider: (() -> NSPasteboardItem?)?

    private let caption = ClipboardStyle.label(size: 10.5, weight: .semibold, color: NSColor.white.withAlphaComponent(0.5))
    private let copiedBadge = ClipboardCopiedBadge()
    /// The accent outline: 1px at rest (always: this is what ⌘V pastes), 2pt + glow on a swap.
    private let accent = CAShapeLayer()
    private let imageView = NSImageView()
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let fileThumb = NSImageView()
    private let fileName = ClipboardStyle.label(size: 13, weight: .semibold)
    private let fileInfo = ClipboardStyle.label(size: 11, color: ClipboardStyle.secondary)
    private let footer = ClipboardStyle.label(size: 11, color: ClipboardStyle.secondary)
    private let empty = ClipboardStyle.label(size: 12, color: ClipboardStyle.secondary)
    private var item: ClipboardItem?
    private var dropHighlight = false { didSet { needsDisplay = true } }
    private var downEvent: NSEvent?

    static let pad: CGFloat = 12
    static let maxImageHeight: CGFloat = 180

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        caption.stringValue = "CURRENT CLIPBOARD"
        copiedBadge.alphaValue = 0
        accent.fillColor = nil
        accent.strokeColor = Self.restingAccent
        accent.lineWidth = 1
        accent.shadowColor = ClipboardStyle.accent.cgColor
        accent.shadowOffset = .zero
        accent.shadowRadius = 10
        accent.shadowOpacity = 0
        layer?.addSublayer(accent)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        textLabel.font = .systemFont(ofSize: 12.5)
        textLabel.textColor = ClipboardStyle.text
        textLabel.maximumNumberOfLines = 7
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.cell?.truncatesLastVisibleLine = true
        fileThumb.imageScaling = .scaleProportionallyUpOrDown
        empty.stringValue = "Copy something and it shows up here."
        empty.alignment = .center
        for v in [caption, copiedBadge, imageView, textLabel, fileThumb, fileName, fileInfo, footer, empty] as [NSView] {
            addSubview(v)
        }
        registerForDraggedTypes([ClipboardHistoryController.rowDragType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Only the card takes the mouse; labels and images inside don't swallow drags.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows `item` and returns the card height that fits it at `width`.
    @discardableResult
    func show(_ item: ClipboardItem?, image: NSImage?, width: CGFloat) -> CGFloat {
        self.item = item
        let inner = width - Self.pad * 2
        [imageView, textLabel, fileThumb, fileName, fileInfo, empty].forEach { $0.isHidden = true }
        footer.isHidden = item == nil

        var y = Self.pad // build bottom-up
        var height: CGFloat
        if let item {
            footer.stringValue = "Copied " + ClipboardFormat.subtitle(for: item).prefix(1).lowercased()
                + ClipboardFormat.subtitle(for: item).dropFirst()
            footer.frame = NSRect(x: Self.pad, y: y, width: inner, height: 15)
            y += 15 + 8
            switch item.kind {
            case .image:
                let ratio = CGFloat(item.pixelHeight ?? 1) / CGFloat(max(1, item.pixelWidth ?? 1))
                let h = min(Self.maxImageHeight, max(40, inner * ratio))
                imageView.image = image
                imageView.isHidden = false
                imageView.frame = NSRect(x: Self.pad, y: y, width: inner, height: h)
                y += h
            case .file where item.pixelWidth != nil || item.isVideo:
                // Image and video files: a real preview, name underneath.
                fileName.stringValue = item.title
                fileName.isHidden = false
                fileName.frame = NSRect(x: Self.pad, y: y, width: inner, height: 17)
                y += 17 + 6
                let ratio = item.pixelWidth.map { CGFloat(item.pixelHeight ?? $0) / CGFloat(max(1, $0)) } ?? 0.5625
                let h = min(Self.maxImageHeight, max(40, inner * ratio))
                imageView.image = image
                imageView.isHidden = false
                imageView.frame = NSRect(x: Self.pad, y: y, width: inner, height: h)
                y += h
            case .file:
                fileThumb.image = image
                fileThumb.isHidden = false
                fileName.stringValue = item.title
                fileInfo.stringValue = [item.fileTypeName, item.fileSize.map(ClipboardFormat.bytes)]
                    .compactMap { $0 }.joined(separator: " · ")
                fileName.isHidden = false
                fileInfo.isHidden = false
                fileThumb.frame = NSRect(x: Self.pad, y: y, width: 56, height: 56)
                fileName.frame = NSRect(x: Self.pad + 66, y: y + 30, width: inner - 66, height: 17)
                fileInfo.frame = NSRect(x: Self.pad + 66, y: y + 12, width: inner - 66, height: 15)
                y += 56
            case .text:
                textLabel.stringValue = String((item.text ?? "").prefix(1200))
                textLabel.isHidden = false
                textLabel.preferredMaxLayoutWidth = inner
                let fit = textLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 120)).height ?? 40
                let h = min(120, max(17, ceil(fit)))
                textLabel.frame = NSRect(x: Self.pad, y: y, width: inner, height: h)
                y += h
            }
        } else {
            empty.isHidden = false
            empty.frame = NSRect(x: Self.pad, y: y + 6, width: inner, height: 17)
            y += 30
        }
        y += 8
        caption.frame = NSRect(x: Self.pad, y: y, width: inner - 70, height: 14)
        copiedBadge.frame = NSRect(x: width - Self.pad - copiedBadge.frame.width + 4, y: y - 4,
                                   width: copiedBadge.frame.width, height: copiedBadge.frame.height)
        y += 14 + Self.pad - 2
        height = y
        needsDisplay = true
        return height
    }

    /// Updates the picture once it has loaded, if the card still shows that item.
    func setImage(_ image: NSImage?, for id: String) {
        guard item?.id == id else { return }
        imageView.image = image
        fileThumb.image = image
    }

    private static let restingAccent = ClipboardStyle.accent.withAlphaComponent(0.45).cgColor

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        accent.frame = bounds
        accent.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 10, cornerHeight: 10, transform: nil)
        accent.shadowPath = nil
        CATransaction.commit()
    }

    /// The new current clipboard just landed: the border flares to a 2pt accent with a
    /// soft glow, holds, and settles back; a "✓ Copied" badge pops in and fades; the card
    /// gives a small bounce (skipped with Reduce Motion).
    func flashCopied() {
        let reduce = ClipboardStyle.reduceMotion
        let total: CFTimeInterval = 0.2 + 1.2 + 0.5
        let times: [NSNumber] = [0, NSNumber(value: 0.2 / total), NSNumber(value: 1.4 / total), 1]
        func key(_ path: String, _ values: [Any]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = values
            a.keyTimes = times
            a.duration = total
            a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear),
                                 CAMediaTimingFunction(name: .easeInEaseOut)]
            return a
        }
        let bright = ClipboardStyle.accent.cgColor
        accent.add(key("lineWidth", [1, 2, 2, 1]), forKey: "flareWidth")
        accent.add(key("strokeColor", [Self.restingAccent, bright, bright, Self.restingAccent]), forKey: "flareColor")
        accent.add(key("shadowOpacity", [0, 0.85, 0.85, 0]), forKey: "flareGlow")

        if !reduce, let root = layer {
            let bounce = CAKeyframeAnimation(keyPath: "transform")
            bounce.values = [CATransform3DIdentity, ClipboardStyle.scale(1.02, in: bounds), CATransform3DIdentity]
                .map { NSValue(caTransform3D: $0) }
            bounce.keyTimes = [0, 0.4, 1]
            bounce.duration = 0.32
            bounce.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            root.add(bounce, forKey: "bounce")
        }
        copiedBadge.pop(reduceMotion: reduce)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        (dropHighlight ? NSColor.white.withAlphaComponent(0.14) : ClipboardStyle.groupFill).setFill()
        path.fill()
        if dropHighlight {
            NSColor.white.withAlphaComponent(0.4).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: Drag out

    override func mouseDown(with event: NSEvent) { downEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, item != nil, let pbItem = dragItemProvider?() else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard DockGeometry.isDrag(from: a, to: b) else { return }
        downEvent = nil
        let dragging = NSDraggingItem(pasteboardWriter: pbItem)
        let source = imageView.isHidden ? (fileThumb.isHidden ? nil : fileThumb) : imageView
        let rect = source?.frame ?? NSRect(x: bounds.midX - 24, y: bounds.midY - 24, width: 48, height: 48)
        let picture = (source?.image).map { img -> NSImage in img } ?? ClipboardStyle.symbol("doc.on.clipboard", size: 28)
        dragging.setDraggingFrame(rect, contents: picture)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { downEvent = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    // MARK: Drop a row here

    private func isRowDrag(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? NSTableView) != nil
            && info.draggingPasteboard.string(forType: ClipboardHistoryController.rowDragType) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isRowDrag(sender) else { return [] }
        dropHighlight = true
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isRowDrag(sender) ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        guard isRowDrag(sender), let id = sender.draggingPasteboard.string(forType: ClipboardHistoryController.rowDragType)
        else { return false }
        onDropRow?(id)
        return true
    }
}

// MARK: - Hover preview

/// A larger preview beside the panel while a row is hovered: the image or file preview,
/// or more of the text. Click-through, never key.
@MainActor
final class ClipboardPreviewPopup {
    private let panel: NSPanel
    private let background = NSView()
    private let imageView = NSImageView()
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let caption = ClipboardStyle.label(size: 11, color: ClipboardStyle.secondary)
    private var shownID: String?
    private static let maxSide: CGFloat = 360
    private static let pad: CGFloat = 10
    /// Text previews wrap up to this many lines; longer text ends in "…".
    private static let maxTextLines = 12

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.09, alpha: 0.96).cgColor
        background.layer?.cornerRadius = 10
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .white
        textLabel.maximumNumberOfLines = Self.maxTextLines
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.cell?.truncatesLastVisibleLine = true
        [imageView, textLabel, caption].forEach(background.addSubview)
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the preview to the left of `panelFrame`, level with `rowRect` (screen coords).
    func show(_ item: ClipboardItem, text: String?, image: NSImage?, rowRect: NSRect, panelFrame: NSRect) {
        shownID = item.id
        let pad = Self.pad
        var size: NSSize
        if item.kind == .text {
            // The text once, wrapped, with only a meta line under it (no repeated title).
            let full = text ?? item.text ?? ""
            caption.stringValue = ClipboardFormat.textMeta(copiedAt: item.copiedAt, characters: full.count)
            imageView.isHidden = true
            textLabel.isHidden = false
            textLabel.stringValue = String(full.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
            let w: CGFloat = 320
            let lineHeight = ceil(NSFont.systemFont(ofSize: 13).boundingRectForFont.height)
            let maxH = lineHeight * CGFloat(Self.maxTextLines)
            let fit = textLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: maxH)).height ?? lineHeight
            let h = min(maxH, ceil(fit))
            textLabel.frame = NSRect(x: pad, y: pad + 20, width: w, height: h)
            size = NSSize(width: w + pad * 2, height: h + pad * 2 + 20)
        } else {
            caption.stringValue = item.title.isEmpty ? ClipboardFormat.subtitle(for: item)
                                                     : "\(item.title)  ·  \(ClipboardFormat.subtitle(for: item))"
            textLabel.isHidden = true
            imageView.isHidden = false
            imageView.image = image
            let px = image?.size ?? NSSize(width: 4, height: 3)
            let scale = min(Self.maxSide / max(px.width, 1), Self.maxSide / max(px.height, 1))
            let fit = NSSize(width: max(120, floor(px.width * scale)), height: max(60, floor(px.height * scale)))
            imageView.frame = NSRect(x: pad, y: pad + 20, width: fit.width, height: fit.height)
            size = NSSize(width: fit.width + pad * 2, height: fit.height + pad * 2 + 20)
        }
        caption.frame = NSRect(x: pad, y: pad, width: size.width - pad * 2, height: 15)

        var origin = NSPoint(x: panelFrame.minX - size.width - 10, y: rowRect.midY - size.height / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: panelFrame.midX, y: panelFrame.midY), $0.frame, false) }) {
            let v = screen.visibleFrame
            origin.x = max(origin.x, v.minX + 4)
            origin.y = min(max(origin.y, v.minY + 4), v.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        shownID = nil
        panel.orderOut(nil)
    }
}

/// "✓ Copied" in white on the accent, top-right on the current card. Pops in (scales up
/// slightly unless Reduce Motion is on) and fades after about 1.5s.
final class ClipboardCopiedBadge: NSView {
    private let label = NSTextField(labelWithString: "✓ Copied")
    private var fadeWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 78, height: 21))
        wantsLayer = true
        layer?.backgroundColor = ClipboardStyle.accent.cgColor
        layer?.cornerRadius = 10.5
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        label.font = .systemFont(ofSize: 11.5, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 2.5, width: 78, height: 16)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func pop(reduceMotion: Bool) {
        fadeWork?.cancel()
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
        if !reduceMotion, let l = layer {
            let s = CAKeyframeAnimation(keyPath: "transform")
            s.values = [ClipboardStyle.scale(0.8, in: bounds), ClipboardStyle.scale(1.06, in: bounds), CATransform3DIdentity]
                .map { NSValue(caTransform3D: $0) }
            s.keyTimes = [0, 0.6, 1]
            s.duration = 0.25
            l.add(s, forKey: "pop")
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.4
                    self.animator().alphaValue = 0
                }
            }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
