import AppKit
import SpriteKit

/// The speech bubble that pops up over a crab while the cursor rests on it: what the session is
/// doing, for how long, and where it lives. A child of the crab, with its origin at the tail's tip.
final class HoverBubble: SKNode {
    static let lineHeight: CGFloat = 13
    static let padX: CGFloat = 9
    static let padY: CGFloat = 6
    static let tailHeight: CGFloat = 6
    static let maxChars = 34

    /// Claude Code's terminal spinner: a dot that swells into an asterisk and back.
    static let spinnerFrames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    /// The two ends of the swell hold a beat longer, the way the terminal one eases.
    static let spinnerHolds: [TimeInterval] = [0.2, 0.1, 0.1, 0.1, 0.1, 0.2, 0.1, 0.1, 0.1, 0.1]

    private let shape = SKShapeNode()
    private let dot = SKShapeNode(circleOfRadius: 3.5)
    private let spinner = SKLabelNode()
    private var labels: [SKLabelNode] = []
    private(set) var isShowing = false

    override init() {
        super.init()
        zPosition = 20
        isHidden = true
        shape.fillColor = NSColor(white: 0.08, alpha: 0.86)
        shape.strokeColor = NSColor.white.withAlphaComponent(0.18)
        shape.lineWidth = 1
        addChild(shape)
        dot.strokeColor = .clear
        dot.zPosition = 1
        addChild(dot)
        spinner.fontName = "Menlo"
        spinner.fontSize = 11
        spinner.horizontalAlignmentMode = .center
        spinner.verticalAlignmentMode = .center
        spinner.zPosition = 1
        spinner.isHidden = true
        addChild(spinner)
        for i in 0..<3 {
            let label = SKLabelNode()
            label.fontName = i == 0 ? "Menlo-Bold" : "Menlo"
            label.fontSize = i == 0 ? 10 : 9.5
            label.fontColor = NSColor.white.withAlphaComponent(0.78)
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .center
            label.zPosition = 2
            addChild(label)
            labels.append(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pop in, and call `refresh` now and once a second while showing (the times in it tick).
    func show(refresh: @escaping () -> Void) {
        guard !isShowing else { return }
        isShowing = true
        removeAllActions()
        refresh()
        isHidden = false
        alpha = 0
        setScale(0.85)
        run(.group([.fadeIn(withDuration: 0.12), .scale(to: 1, duration: 0.16)]), withKey: "pop")
        run(.repeatForever(.sequence([.wait(forDuration: 1), .run(refresh)])), withKey: "tick")
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        removeAllActions()
        spinner.removeAction(forKey: "spin")
        run(.sequence([.fadeOut(withDuration: 0.1), .hide()]), withKey: "pop")
    }

    /// Lay out `lines` (top to bottom) with a colored dot before the first — or, while the session
    /// is busy (`spinning`), Claude Code's twinkling asterisk in that color. The box slides sideways
    /// to stay inside the scene: `worldX` is where the tail points (the crab), `sceneWidth` the room.
    func render(lines: [String], dotColor: NSColor, spinning: Bool,
                worldX: CGFloat, sceneWidth: CGFloat) {
        let text = lines.prefix(3).map {
            $0.count > Self.maxChars ? String($0.prefix(Self.maxChars - 1)) + "…" : $0
        }
        let dotSpace: CGFloat = 12
        var w: CGFloat = 0
        for (i, label) in labels.enumerated() {
            if i < text.count {
                label.text = text[i]
                label.isHidden = false
                w = max(w, label.frame.width + (i == 0 ? dotSpace : 0))
            } else {
                label.text = nil
                label.isHidden = true
            }
        }
        w = max(w + Self.padX * 2, 40)
        let h = CGFloat(text.count) * Self.lineHeight + Self.padY * 2

        let margin: CGFloat = 6
        var offset: CGFloat = 0
        if worldX - w / 2 < margin {
            offset = margin - (worldX - w / 2)
        } else if worldX + w / 2 > sceneWidth - margin {
            offset = sceneWidth - margin - (worldX + w / 2)
        }
        shape.path = Self.path(width: w, height: h, boxOffset: offset)

        let left = offset - w / 2 + Self.padX
        let top = Self.tailHeight + h - Self.padY
        let markX = left + 3.5, markY = top - Self.lineHeight / 2
        labels.first?.fontColor = dotColor
        dot.isHidden = spinning
        dot.fillColor = dotColor
        dot.position = CGPoint(x: markX, y: markY)
        spinner.isHidden = !spinning
        spinner.fontColor = dotColor
        spinner.position = CGPoint(x: markX, y: markY)
        if spinning {
            startSpinning()
        } else {
            spinner.removeAction(forKey: "spin")
        }
        for (i, label) in labels.enumerated() where !label.isHidden {
            label.position = CGPoint(x: left + (i == 0 ? dotSpace : 0),
                                     y: top - Self.lineHeight * (CGFloat(i) + 0.5))
        }
    }

    /// Run the asterisk cycle, unless it is already running (render is called every second, and
    /// restarting would snap the twinkle back to its first frame each time).
    private func startSpinning() {
        guard spinner.action(forKey: "spin") == nil else { return }
        var steps: [SKAction] = []
        for (i, frame) in Self.spinnerFrames.enumerated() {
            steps.append(.run { [weak self] in self?.spinner.text = frame })
            steps.append(.wait(forDuration: Self.spinnerHolds[i]))
        }
        spinner.run(.repeatForever(.sequence(steps)), withKey: "spin")
    }

    /// A rounded box sitting `tailHeight` above the origin, with a little tail down to the origin.
    private static func path(width w: CGFloat, height h: CGFloat, boxOffset: CGFloat) -> CGPath {
        let r: CGFloat = 6, tw: CGFloat = 5
        let l = boxOffset - w / 2, rt = boxOffset + w / 2
        let b = tailHeight, t = tailHeight + h
        let tailX = min(max(0, l + r + tw), rt - r - tw)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: tailX - tw, y: b))
        p.addLine(to: CGPoint(x: tailX, y: 0))
        p.addLine(to: CGPoint(x: tailX + tw, y: b))
        p.addArc(tangent1End: CGPoint(x: rt, y: b), tangent2End: CGPoint(x: rt, y: t), radius: r)
        p.addArc(tangent1End: CGPoint(x: rt, y: t), tangent2End: CGPoint(x: l, y: t), radius: r)
        p.addArc(tangent1End: CGPoint(x: l, y: t), tangent2End: CGPoint(x: l, y: b), radius: r)
        p.addArc(tangent1End: CGPoint(x: l, y: b), tangent2End: CGPoint(x: tailX - tw, y: b), radius: r)
        p.closeSubpath()
        return p
    }

    /// The dot's color: the same palette as the (currently hidden) badges.
    static func dotColor(for status: CrabStatus) -> NSColor {
        switch status {
        case .working, .usingTool: return ClaudeMark.color
        case .needsPermission, .error: return BadgeStyle.Palette.bad
        case .needsQuestion:       return BadgeStyle.Palette.ask
        case .doneUnseen, .doneSeen: return BadgeStyle.Palette.ok
        case .dormant:             return BadgeStyle.Palette.sleep
        }
    }
}
