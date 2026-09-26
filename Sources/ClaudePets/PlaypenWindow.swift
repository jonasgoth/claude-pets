import AppKit
import SpriteKit

/// The see-through strip the crabs live in. Never takes keyboard focus.
final class PlaypenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PlaypenView: SKView {
    /// A click on a crab should grab it right away, not just "activate" the panel first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel and keeps it "solid only over crabs": the panel ignores the mouse
/// unless the cursor is on a crab or a drag is in progress, so clicks on empty strip
/// go straight through to whatever app is behind it.
final class PlaypenController {
    static let stripHeight: CGFloat = 175

    let panel: PlaypenPanel
    let skView: PlaypenView
    let scene: PlaypenScene
    private var monitors: [Any] = []

    init() {
        let frame = Self.stripFrame()

        panel = PlaypenPanel(contentRect: frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        skView = PlaypenView(frame: NSRect(origin: .zero, size: frame.size))
        skView.allowsTransparency = true
        skView.ignoresSiblingOrder = true
        skView.preferredFramesPerSecond = 30
        skView.autoresizingMask = [.width, .height]
        // When the panel grows to full height (a crab being carried) the Metal layer would show its
        // last frame stretched over the new size for an instant — every pet balloons. Pinning the
        // old picture to the bottom-left instead keeps the pets exactly where they were.
        skView.wantsLayer = true
        skView.layer?.contentsGravity = .bottomLeft

        scene = PlaypenScene(size: frame.size)
        skView.presentScene(scene)
        panel.contentView = skView
        scene.onNeedsTallWindow = { [weak self] tall in
            guard let self, self.isTall != tall else { return }
            self.isTall = tall
            self.panel.setFrame(Self.stripFrame(tall: tall), display: true)
        }

        // Global = events going to other apps (cursor over empty strip or elsewhere).
        // Local = events going to us (cursor over a crab, or mid-drag). Need both.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.updateMousePassthrough()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.updateMousePassthrough()
            return event
        }) { monitors.append(m) }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        }
    }

    /// Full width along the very bottom of the main screen — the same row as the Dock. The Dock
    /// draws above us, and the scene keeps the pets out of its footprint (see updateDockZone).
    static func stripFrame(tall: Bool = false) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        return NSRect(x: frame.minX, y: frame.minY, width: frame.width,
                      height: tall ? frame.height : stripHeight)
    }

    /// While a crab is carried (and until it and any towed babies land) the panel covers the
    /// whole screen, so it can be lifted right to the top. It stays see-through and click-through
    /// everywhere except on a crab, so nothing behind it notices.
    private var isTall = false

    /// Extra room kept between the pets and the Dock's edge.
    static let dockMargin: CGFloat = 18
    private var dockTimer: Timer?

    /// Tell the scene which x-range the Dock occupies (in scene coordinates), if any.
    func updateDockZone() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        guard let dock = DockGeometry.current(on: screen),
              dock.rect.maxY > panel.frame.minY else {   // Dock not in our row → nothing to avoid
            scene.blockedX = nil
            return
        }
        let minX = dock.rect.minX - panel.frame.minX - Self.dockMargin
        let maxX = dock.rect.maxX - panel.frame.minX + Self.dockMargin
        if scene.blockedX != minX...maxX {
            debugLog("dock zone \(dock.exact ? "exact" : "estimated"): x \(Int(dock.rect.minX))…\(Int(dock.rect.maxX)) (blocked \(Int(minX))…\(Int(maxX)))")
        }
        scene.blockedX = minX...maxX
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        reposition()
        updateDockZone()
        if dockTimer == nil {
            let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in self?.updateDockZone() }
            RunLoop.main.add(t, forMode: .common)
            dockTimer = t
        }
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.logCrabRect() }
    }

    func hide() {
        scene.setHovered(nil, at: nil)
        panel.orderOut(nil)
    }

    func reposition() {
        panel.setFrame(Self.stripFrame(tall: isTall), display: true)
        updateDockZone()
    }

    func updateMousePassthrough() {
        guard panel.isVisible else { return }
        let screenPoint = NSEvent.mouseLocation
        var under: CrabNode?
        var scenePoint: CGPoint?
        if panel.frame.contains(screenPoint) {
            let windowPoint = panel.convertPoint(fromScreen: screenPoint)
            let p = skView.convert(windowPoint, to: scene)
            scenePoint = p
            under = scene.crab(at: p)
        }
        let solid = scene.isDragging || under != nil
        scene.setHovered(scene.isDragging ? nil : under, at: scenePoint)   // the speech bubble
        if panel.ignoresMouseEvents == solid {
            panel.ignoresMouseEvents = !solid
            debugLog(solid ? "solid (cursor on crab)" : "pass-through")
            if !solid { logCrabRect() }
        }
    }

    /// Set CLAUDE_PETS_DEBUG=1 to see pass-through flips and the crab's screen rect on stderr.
    private static let debugEnabled = ProcessInfo.processInfo.environment["CLAUDE_PETS_DEBUG"] == "1"

    private func debugLog(_ message: String) {
        guard Self.debugEnabled else { return }
        FileHandle.standardError.write(("[claude-pets] " + message + "\n").data(using: .utf8)!)
    }

    /// Screen-coordinate rect of the first crab (bottom-left origin). Debug only.
    func logCrabRect() {
        guard Self.debugEnabled, let crab = scene.crabs.first else { return }
        let sceneRect = crab.bodyFrame
        let a = skView.convert(CGPoint(x: sceneRect.minX, y: sceneRect.minY), from: scene)
        let b = skView.convert(CGPoint(x: sceneRect.maxX, y: sceneRect.maxY), from: scene)
        let viewRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let screenRect = panel.convertToScreen(viewRect)
        debugLog("crab screen rect x=\(Int(screenRect.minX)) y=\(Int(screenRect.minY)) w=\(Int(screenRect.width)) h=\(Int(screenRect.height)) panel=\(panel.frame)")
    }
}
