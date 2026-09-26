import AppKit

/// One place for the menu's side padding. The rows sit `sideInset` in from the menu's
/// own edge, and their icons and switches sit `rowInset` further in again, so the
/// header, the rows and the dividers all line up on the same two numbers.
enum MenuMetrics {
    static let sideInset: CGFloat = 5
    static let rowInset: CGFloat = 7
    /// Where the icons, titles and switches actually start.
    static var contentInset: CGFloat { sideInset + rowInset }
}

/// A switch drawn by hand. AppKit's own NSSwitch dims itself inside a menu — a menu's
/// window never becomes the key window, so the control believes it is sitting in a
/// background window and greys out — which made every "on" row look off.
final class MenuToggle: NSView {
    static let size = NSSize(width: 34, height: 20)

    var isOn = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { Self.size }

    /// The row owns the click and flips the setting, so the switch takes no events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The "off" track has to hold up on both a dark and a light menu.
    private static let offTrack = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 1, alpha: 0.22)
            : NSColor(calibratedWhite: 0, alpha: 0.17)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        (isOn ? NSColor.controlAccentColor : Self.offTrack).setFill()
        track.fill()

        let inset: CGFloat = 2
        let side = bounds.height - inset * 2
        let x = isOn ? bounds.maxX - inset - side : bounds.minX + inset
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: inset, width: side, height: side)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The one-line header at the top of the menu: the app on the left, its version on
/// the right. Both quiet — it is a label, not something to act on.
final class MenuHeaderView: NSView {
    static let height: CGFloat = 24

    private let nameLabel = NSTextField(labelWithString: "Claude Pets")
    private let versionLabel = NSTextField(labelWithString: "")

    init(version: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 288, height: Self.height))
        autoresizingMask = [.width]
        nameLabel.font = .systemFont(ofSize: 13, weight: .regular)
        nameLabel.textColor = .secondaryLabelColor
        versionLabel.font = .systemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.stringValue = version
        versionLabel.alignment = .right
        addSubview(nameLabel)
        addSubview(versionLabel)
        setAccessibilityLabel("Claude Pets \(version)")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func width(of label: NSTextField) -> CGFloat {
        let font = label.font ?? .systemFont(ofSize: 12)
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + 6
    }

    override func layout() {
        super.layout()
        // Left edge lines up with the row icons, right edge with their switches.
        let midY = bounds.height / 2
        let inset = MenuMetrics.contentInset
        nameLabel.frame = NSRect(x: inset, y: midY - 8, width: width(of: nameLabel), height: 17)
        let versionWidth = width(of: versionLabel)
        versionLabel.frame = NSRect(x: bounds.width - inset - versionWidth, y: midY - 8,
                                    width: versionWidth, height: 17)
    }
}

/// One line in the menu's settings list: a small icon and a name on the left, and on
/// the right either a switch you flip (everyday settings) or a word you click (one-off
/// actions like tidying the crabs up). Rows light up faintly under the pointer.
final class MenuRow: NSView {
    struct Model {
        /// A row either flips a switch or performs a one-off action.
        enum Control {
            case toggle(Bool)
            case action(String)
            /// Nothing on the right: session rows and the empty-state line.
            case none
        }

        /// What sits at the left edge of the row.
        enum Leading {
            case glyph(IconFont.Icon)
            /// Already-drawn art, e.g. a session's status mark or its spinner frame.
            case image(NSImage?)
            case none
        }

        var title: String
        var leading: Leading
        var control: Control
        /// Hover text, e.g. "Go to this chat" on a session row.
        var tooltip: String?
        /// Actions that change something on the desktop dismiss the menu so you can see it.
        var closesMenu: Bool = false
        /// A row with no action is a readout: no hover, and its title stays grey.
        var action: (() -> Void)?
    }

    static let height: CGFloat = 27

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let toggle = MenuToggle()
    private let icon = NSImageView()
    private var hovering = false
    private var model: Model

    init(model: Model) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 288, height: Self.height))
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(toggle)
        setAccessibilityRole(.button)
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Flipping a switch redraws the same row rather than building a new one, so the row
    /// survives the click that is still being handled inside it.
    func update(_ model: Model) {
        self.model = model
        apply()
    }

    private func apply() {
        titleLabel.stringValue = model.title
        titleLabel.textColor = model.action == nil ? .secondaryLabelColor : .labelColor
        switch model.leading {
        case .glyph(let glyph):
            icon.isHidden = false
            icon.image = IconFont.image(glyph, pointSize: 15, colour: .secondaryLabelColor)
        case .image(let art):
            icon.isHidden = false
            icon.image = art
        case .none:
            icon.isHidden = true
        }

        switch model.control {
        case .toggle(let isOn):
            toggle.isHidden = false
            toggle.isOn = isOn
            statusLabel.isHidden = true
            setAccessibilityLabel("\(model.title): \(isOn ? "on" : "off")")
        case .none:
            toggle.isHidden = true
            statusLabel.isHidden = true
            setAccessibilityLabel(model.title)
        case .action(let word):
            toggle.isHidden = true
            statusLabel.isHidden = false
            statusLabel.stringValue = word
            statusLabel.textColor = .secondaryLabelColor
            setAccessibilityLabel("\(model.title): \(word)")
        }
        toolTip = model.tooltip
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let pad = MenuMetrics.rowInset
        let side: CGFloat = 15
        icon.frame = NSRect(x: pad, y: (bounds.height - side) / 2, width: side, height: side)

        let textX = pad + side + 8
        var rightEdge = bounds.width - pad
        if !toggle.isHidden {
            let size = toggle.intrinsicContentSize
            toggle.frame = NSRect(x: bounds.width - pad - size.width,
                                  y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height)
            rightEdge -= size.width + 8
        } else if !statusLabel.isHidden {
            // The word on the right takes only what it needs; the title keeps the rest.
            // Measured from the string itself — the label's own intrinsic size lags a
            // text change by a layout pass, which truncated longer words.
            let font = statusLabel.font ?? .systemFont(ofSize: 12.5)
            let drawn = (statusLabel.stringValue as NSString)
                .size(withAttributes: [.font: font]).width
            // Plus slack for the cell's own inset, which the raw string width misses.
            let width = min(max(0, bounds.width - textX - pad), ceil(drawn) + 6)
            statusLabel.frame = NSRect(x: bounds.width - pad - width,
                                       y: (bounds.height - 17) / 2,
                                       width: width, height: 17)
            rightEdge -= width + 8
        }
        titleLabel.frame = NSRect(x: textX, y: (bounds.height - 17) / 2,
                                  width: max(0, rightEdge - textX), height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        path.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = model.action != nil
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    /// Clicking anywhere on the row does what the row does — clicks that land on the
    /// switch itself never reach here, so a toggle can't fire twice.
    override func mouseUp(with event: NSEvent) {
        guard let action = model.action,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if model.closesMenu { enclosingMenuItem?.menu?.cancelTracking() }
        action()
    }
}

/// The block of settings at the bottom of the menu: one row per setting, stacked.
final class MenuListView: NSView {
    private static let gap: CGFloat = 2
    private static let sideInset = MenuMetrics.sideInset
    private static let topInset: CGFloat = 2
    private static let bottomInset: CGFloat = 2

    private var rows: [MenuRow] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 288, height: 0))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError() }

    func setRows(_ models: [MenuRow.Model]) {
        if models.count == rows.count {
            zip(rows, models).forEach { $0.update($1) }
            return
        }
        subviews.forEach { $0.removeFromSuperview() }
        rows = models.map(MenuRow.init(model:))
        rows.forEach(addSubview)
        let height = rows.isEmpty ? 0
            : Self.topInset + Self.bottomInset
              + CGFloat(rows.count) * MenuRow.height + CGFloat(rows.count - 1) * Self.gap
        setFrameSize(NSSize(width: frame.width, height: height))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let usable = bounds.width - Self.sideInset * 2
        var y = bounds.height - Self.topInset - MenuRow.height
        for row in rows {
            row.frame = NSRect(x: Self.sideInset, y: y, width: usable, height: MenuRow.height)
            y -= MenuRow.height + Self.gap
        }
    }
}

/// A hairline between blocks. AppKit's own `NSMenuItem.separator()` reserves a lot of
/// empty space above and below its line; this one keeps just enough to breathe.
final class MenuDividerView: NSView {
    static let height: CGFloat = 9
    private static let sideInset = MenuMetrics.contentInset

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 288, height: Self.height))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let line = NSRect(x: Self.sideInset, y: (bounds.height - 1) / 2,
                          width: bounds.width - Self.sideInset * 2, height: 1)
        NSColor.separatorColor.setFill()
        line.fill()
    }
}
