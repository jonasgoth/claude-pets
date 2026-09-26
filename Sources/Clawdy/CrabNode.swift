import AppKit
import SpriteKit

/// A crab's shell colour says which project it belongs to: every session running in the same folder
/// wears the same shell, and only the shell moves — props, eyes and highlights stay as drawn.
///
/// Colours are handed out in the order you start working. The first folder you open wears the pets'
/// own terracotta, the next indigo, the next blue, and so on down `projectHues`. Nothing is tied to a
/// folder forever: once you have not sent Claude a message for `idleReset` the slate is wiped, and
/// the folder you come back to starts again at terracotta. Which project is orange therefore depends
/// on where you started working, not on a calendar date — no midnight switch, and a day spent in one
/// project keeps that project orange the whole way through.
///
/// The clock is your messages, not Claude's: a background job or a sub-agent can keep a crab busy
/// all night while you sleep, and that must not stop the morning from starting fresh.
enum CrabPalette {
    /// The crab's own body color (terracotta), matching the artwork as drawn.
    static let standard = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

    /// The hue the artwork is already drawn at, so nothing gets rotated.
    static let standardHueDegrees: CGFloat = PetLibrary.baseHueDegrees

    /// Shell hues, in the order folders claim them: terracotta, indigo, blue, pink, green, purple,
    /// lime, teal. Terracotta first, so the folder you start in looks exactly as the art was drawn,
    /// and each next hue jumps far around the wheel so two projects on screen never read as the same
    /// colour; past eight folders in one stretch it wraps and repeats.
    static let projectHues: [CGFloat] = [standardHueDegrees, 245, 205, 325, 128, 280, 95, 170]

    /// This long between two of your messages and the colours start over from terracotta.
    static let idleReset: TimeInterval = 4 * 3600

    private static let huesKey = "projectHueByPath"
    private static let promptKey = "projectHueLastPrompt"

    private static var assigned: [String: Double] =
        (UserDefaults.standard.dictionary(forKey: "projectHueByPath") as? [String: Double]) ?? [:]
    private static var lastPrompt = UserDefaults.standard.double(forKey: "projectHueLastPrompt")

    /// Call at the top of each refresh, before any hue is asked for, with your newest message in any
    /// session and the folder it went to. If it came `idleReset` or more after the one before it,
    /// forget who had which colour; either way that folder claims its colour first, so the one you
    /// came back to is the one that gets terracotta. The last message time is on disk, so a gap
    /// counts whether Clawdy was running through it or not.
    static func notePrompt(at time: TimeInterval, project key: String) {
        guard time > lastPrompt else { return }
        if time - lastPrompt >= idleReset {
            assigned = [:]
            UserDefaults.standard.removeObject(forKey: huesKey)
        }
        lastPrompt = time
        UserDefaults.standard.set(time, forKey: promptKey)
        _ = hueDegrees(forProject: key)
    }

    /// The shell hue for one folder: the next colour in the list the first time that folder turns up
    /// in this stretch of work, then the same colour until the slate is wiped.
    static func hueDegrees(forProject key: String) -> CGFloat {
        if let hue = assigned[key] { return CGFloat(hue) }
        let picked = projectHues[assigned.count % projectHues.count]
        assigned[key] = Double(picked)
        UserDefaults.standard.set(assigned, forKey: huesKey)
        return picked
    }
}

/// One crab, standing for one Claude session (or, when `isBaby`, one sub-agent).
///
/// Session crabs are drawn with the animated Clawd pets (PetLibrary): one pet per state, so the
/// pose itself says what the session is doing. Baby crabs (sub-agents) keep the small pixel crab.
/// Origin is between the feet, so `position.y == floorY` means standing on the floor.
final class CrabNode: SKNode {
    /// Everything below is measured against a 120 pt cell; this shrinks the whole pet together.
    static let petScale: CGFloat = 0.88
    /// Pet frame cell shown at this many points (sheets are rendered at 2x).
    static let petSize: CGFloat = 120 * petScale
    /// Measured from the sheets: the pet's shadow ends 21 of 240 px above the cell's bottom edge,
    /// so anchoring there puts the node origin right under the shadow.
    static let petAnchorY: CGFloat = 21.0 / 240.0
    /// The same origin, but measured inside a frame whose shadow band has been cropped away — so a
    /// carried crab loses its shadow without shifting under the cursor. It lands just below the
    /// cropped frame, hence negative.
    static let petCropAnchorY: CGFloat = (petAnchorY - PetLibrary.shadowBand) / (1 - PetLibrary.shadowBand)
    /// The standing body, relative to that origin: feet 3 pt up, 40 wide, 26 tall.
    static let petBody = CGSize(width: 40 * petScale, height: 26 * petScale)
    static let petBodyBottom: CGFloat = 3 * petScale
    /// Name tag height above the origin: clear of the props that float over the head.
    static let petTagY: CGFloat = 58 * petScale
    /// A seen-and-done session is not worth reading, so its tag fades back to this much opacity.
    static let restingTagAlpha: CGFloat = 0.35
    static let babyScale: CGFloat = 0.42
    /// Status badges are off for now (the pet's pose already says it). Flip to bring them back.
    static var badgesEnabled = false

    let id: String
    let isBaby: Bool
    private let usesPet: Bool
    private let sprite: SKSpriteNode
    private let nameLabel = SKLabelNode()
    private let nameBackground = SKShapeNode()
    private let tagNode = SKNode()
    private var tagBaseY: CGFloat = 0
    /// The speech bubble shown while the cursor rests on this crab.
    private let bubble = HoverBubble()

    private let badgeNode = SKNode()
    private let badgeCircle = SKShapeNode(circleOfRadius: 8)
    private let badgeSymbol = SKSpriteNode()

    /// The pet sheet on screen right now, so `applyFacing` knows which pose it is mirroring.
    private var currentPetKey: String?

    /// True while the crab is held in the air by the cursor.
    private var carried = false { didSet { if carried != oldValue { applyShadowCrop() } } }

    /// How far the pose on screen hovers above the floor, and how far it drifts to each side.
    /// Zero for every pet that stands on the ground; the flying ones come out of the manifest.
    private var petLift: CGFloat = 0
    private var petSway: CGFloat = 0

    /// A pet off the floor — carried by the cursor, or flying under its own steam — plays frames
    /// cropped just above the ground shadow baked into the art, so no dark bar floats underneath.
    private var shadowCropped = false
    private var wantsShadowCrop: Bool { usesPet && (carried || petLift > 0) }

    private func applyShadowCrop() {
        guard shadowCropped != wantsShadowCrop else { return }
        shadowCropped = wantsShadowCrop
        sprite.size = CGSize(width: Self.petSize,
                             height: Self.petSize * (shadowCropped ? 1 - PetLibrary.shadowBand : 1))
        sprite.anchorPoint = CGPoint(x: 0.5, y: shadowCropped ? Self.petCropAnchorY : Self.petAnchorY)
    }

    /// Park the sprite at its hover height and start (or stop) the lazy side-to-side drift that
    /// goes with it. Called on every pose change, so a crab that stops flying settles back down.
    private func applyHover() {
        sprite.removeAction(forKey: "hover")
        sprite.position = CGPoint(x: 0, y: petLift)
        guard petSway > 0 else { return }
        let out = SKAction.moveBy(x: petSway, y: 0, duration: 1.3)
        let across = SKAction.moveBy(x: -petSway * 2, y: 0, duration: 2.6)
        let home = SKAction.moveBy(x: petSway, y: 0, duration: 1.3)
        for step in [out, across, home] { step.timingMode = .easeInEaseOut }
        sprite.run(.repeatForever(.sequence([out, across, home])), withKey: "hover")
    }

    private var status: CrabStatus = .working
    private var hueDegrees: CGFloat = PetLibrary.baseHueDegrees
    /// This crab's own working animation, picked once from the rotation and kept for life.
    private lazy var workingPetKey: String = PetLibrary.workingKey(for: id)
    // Pixel-crab textures (babies, or fallback when pet sheets are missing).
    private var tintedWalk: [SKTexture] = CrabSprite.walkTextures
    private var tintedIdle: SKTexture { tintedWalk.first ?? CrabSprite.idleTexture }

    var title: String = "" { didSet { if title != oldValue { updateLabel() } } }
    /// This crab's project shell hue, in degrees. See `CrabPalette`.
    var projectHue: CGFloat = CrabPalette.standardHueDegrees { didSet { if projectHue != oldValue { applyColor() } } }

    /// Unflipped, the pet art walks *left*: the planted leg sweeps toward +x, which shoves the
    /// body the other way. So for pets, facing right is the mirrored sprite, not the plain one.
    /// The pixel crab (babies, and the fallback) is drawn the other way round — unflipped it
    /// walks right — so it mirrors on the opposite sign. See `applyFacing`.
    var facingRight = true { didSet { if facingRight != oldValue { applyFacing() } } }

    /// Poses whose art carries a prop that reads wrong back-to-front — the "200" crab holds a
    /// green check — so they always play unmirrored, whichever way the crab was last headed.
    private static let unmirroredPets: Set<String> = ["doneUnseen"]
    private var canMirror: Bool { !Self.unmirroredPets.contains(currentPetKey ?? "") }

    private func applyFacing() {
        // `usesPet` decides which way "unflipped" points, so each art set walks the way it moves.
        let mirrored = usesPet ? (facingRight && canMirror) : !facingRight
        sprite.xScale = (mirrored ? -1 : 1) * abs(sprite.xScale)
    }

    /// The body's footprint (not the whole pet cell), used for spacing and clamping.
    var size: CGSize { usesPet ? Self.petBody : sprite.size }
    var bodyFrame: CGRect {
        if usesPet {
            return CGRect(x: position.x - Self.petBody.width / 2, y: position.y + Self.petBodyBottom,
                          width: Self.petBody.width, height: Self.petBody.height)
        }
        let s = sprite.size
        return CGRect(x: position.x - s.width / 2, y: position.y, width: s.width, height: s.height)
    }
    var currentStatus: CrabStatus { status }

    /// Width of the name tag, so the scene can keep neighbours' tags from overlapping.
    private(set) var tagWidth: CGFloat = 22
    /// 0 = normal height; higher levels lift the tag so it clears a close neighbour's tag.
    var tagLevel = 0 {
        didSet {
            guard tagLevel != oldValue else { return }
            // Only cancel a previous lift — killing every action here would also kill an
            // in-flight fade and strand the tag half-dim until the next status change.
            tagNode.removeAction(forKey: "lift")
            tagNode.run(.moveTo(y: tagBaseY + CGFloat(tagLevel) * 15, duration: 0.15), withKey: "lift")
        }
    }

    // MARK: Wander state (driven by PlaypenScene)

    var wanderTarget: CGFloat?
    var nextWanderAt: TimeInterval = 0
    /// Earliest scene time this crab may take another "you're too close" step aside.
    var nextUnstackAt: TimeInterval = 0
    var holdUntil: TimeInterval = 0
    private(set) var isMoving = false
    /// Where the crab is running to when it switches sides (working side <-> done side),
    /// plus where it set off from and how far along it is, so the scene can ease the run.
    private(set) var dashTarget: CGFloat?
    private(set) var dashFromX: CGFloat = 0
    private(set) var dashGait = Gait()
    var dashElapsed: TimeInterval = 0
    /// The same three for a stroll: where it set off from, how far along it is, and its speed curve.
    private(set) var wanderFromX: CGFloat = 0
    private(set) var wanderGait = Gait()
    var wanderElapsed: TimeInterval = 0
    var isDashing: Bool { dashTarget != nil }
    /// How much faster the legs go at full sprint than during a stroll.
    static let dashGaitSpeed: CGFloat = 2.5

    /// Only relaxed crabs roam. Working crabs (and everyone else) stand still and just animate.
    var canWander: Bool { !isBaby && status == .doneSeen }

    init(id: String, isBaby: Bool = false) {
        self.id = id
        self.isBaby = isBaby
        self.usesPet = !isBaby && PetLibrary.isAvailable
        if usesPet {
            sprite = SKSpriteNode(texture: nil, size: CGSize(width: Self.petSize, height: Self.petSize))
            sprite.shader = PetLibrary.hueShader
            sprite.setValue(PetLibrary.hueValue(degrees: hueDegrees), forAttribute: PetLibrary.hueAttribute)
        } else {
            let scale = isBaby ? Self.babyScale : 1.0
            sprite = SKSpriteNode(texture: CrabSprite.idleTexture)
            sprite.size = CGSize(width: CrabSprite.frameSize.width * scale,
                                 height: CrabSprite.frameSize.height * scale)
        }
        sprite.anchorPoint = CGPoint(x: 0.5, y: usesPet ? Self.petAnchorY : 0)
        super.init()
        applyFacing()
        addChild(sprite)
        if !isBaby { buildNameTag(); addChild(bubble) }
        buildBadge()
        alpha = isBaby ? 0.9 : 1
        setStatus(.working)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Name tag

    private func buildNameTag() {
        nameLabel.fontName = "Menlo-Bold"
        nameLabel.fontSize = 9.5
        nameLabel.fontColor = .white
        nameLabel.verticalAlignmentMode = .center
        nameLabel.horizontalAlignmentMode = .center
        nameLabel.zPosition = 2
        nameBackground.strokeColor = .clear
        nameBackground.fillColor = NSColor.black.withAlphaComponent(0.62)
        nameBackground.zPosition = 1
        nameBackground.alpha = 1
        // Above the body, and above the props (brackets, wrenches, question marks) that float over it.
        tagBaseY = usesPet ? Self.petTagY : sprite.size.height + 9
        tagNode.position = CGPoint(x: 0, y: tagBaseY)
        tagNode.zPosition = 6
        tagNode.addChild(nameBackground)
        tagNode.addChild(nameLabel)
        addChild(tagNode)
    }

    private func updateLabel() {
        guard !isBaby else { return }
        let short = title.count > 17 ? String(title.prefix(16)) + "…" : title
        // No chat title yet (just-started or shutting-down session): no tag at all.
        tagNode.isHidden = short.isEmpty
        nameLabel.text = short
        let w = max(nameLabel.frame.width + 14, 24), h: CGFloat = 15
        tagWidth = short.isEmpty ? 0 : w
        nameBackground.path = CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                                     cornerWidth: 4, cornerHeight: 4, transform: nil)
    }

    /// Dim the whole tag (pill + text) once the session is done and seen; full strength otherwise.
    /// A sleeping crab is a seen crab that has rested a minute, so its tag stays dim too —
    /// otherwise the name flashes back to full white a minute after you read the chat.
    private func updateTagFade() {
        guard !isBaby else { return }
        let resting = status == .doneSeen || status == .dormant
        let wanted: CGFloat = resting ? Self.restingTagAlpha : 1
        guard abs(tagNode.alpha - wanted) > 0.01 else { return }
        tagNode.removeAction(forKey: "fade")
        tagNode.run(.fadeAlpha(to: wanted, duration: 0.45), withKey: "fade")
    }

    // MARK: - Hover bubble

    /// What the bubble says beyond the status. The store sets it every tick.
    var detail: CrabDetail? {
        didSet { if detail != oldValue, bubble.isShowing { refreshBubble() } }
    }
    /// Where a click on this crab takes you (nil while we don't know the session's chat).
    var openTarget: SessionOpener.Target?
    /// Whose chat that is. A baby carries its parent's session id, so opening from a baby marks
    /// the parent seen.
    var openSessionId: String?
    /// Sub-agents working for this session right now (the scene counts its babies).
    var helpers = 0 {
        didSet { if helpers != oldValue, bubble.isShowing { refreshBubble() } }
    }

    func showBubble() {
        guard !isBaby else { return }
        bubble.show { [weak self] in self?.refreshBubble() }
    }

    func hideBubble() { bubble.hide() }

    /// Rebuild the bubble's text and put it just above the name tag (wherever the tag is stacked).
    private func refreshBubble() {
        let now = Date().timeIntervalSince1970
        let lines = (detail ?? CrabDetail()).lines(status: status, helpers: helpers, now: now)
        bubble.position = CGPoint(x: 0, y: tagBaseY + CGFloat(tagLevel) * 15 + 7.5 + 3)
        bubble.render(lines: lines, dotColor: HoverBubble.dotColor(for: status),
                      spinning: status == .working || status == .usingTool,
                      worldX: position.x, sceneWidth: scene?.size.width ?? .greatestFiniteMagnitude)
    }

    // MARK: - Badge

    private func buildBadge() {
        let r: CGFloat = isBaby ? 6 : 8
        badgeCircle.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        badgeCircle.strokeColor = NSColor.white.withAlphaComponent(0.85)
        badgeCircle.lineWidth = 1
        badgeCircle.zPosition = 1
        badgeSymbol.zPosition = 2
        badgeSymbol.size = CGSize(width: r * 1.4, height: r * 1.4)
        badgeNode.addChild(badgeCircle)
        badgeNode.addChild(badgeSymbol)
        if usesPet {
            badgeNode.position = CGPoint(x: Self.petBody.width * 0.5 + 4,
                                         y: Self.petBodyBottom + Self.petBody.height - 2)
        } else {
            badgeNode.position = CGPoint(x: sprite.size.width * 0.42, y: sprite.size.height - r * 0.5)
        }
        badgeNode.zPosition = 5
        badgeNode.isHidden = true
        addChild(badgeNode)
    }

    private func updateBadge() {
        guard Self.badgesEnabled, let style = BadgeStyle.forStatus(status) else {
            badgeNode.isHidden = true
            badgeNode.removeAction(forKey: "pulse")
            return
        }
        badgeNode.isHidden = false
        badgeCircle.fillColor = style.color
        badgeSymbol.texture = BadgeIcon.texture(style.symbol, pointSize: isBaby ? 8 : 11)
        badgeNode.removeAction(forKey: "pulse")
        if status.needsYou {
            let pulse = SKAction.sequence([.scale(to: 1.18, duration: 0.5), .scale(to: 1.0, duration: 0.5)])
            pulse.timingMode = .easeInEaseOut
            badgeNode.run(.repeatForever(pulse), withKey: "pulse")
        } else {
            badgeNode.setScale(1)
        }
    }

    // MARK: - Color

    private func applyColor() {
        hueDegrees = projectHue
        if usesPet {
            // The pet's frames are shared; the colour is a per-sprite shader value.
            sprite.setValue(PetLibrary.hueValue(degrees: hueDegrees), forAttribute: PetLibrary.hueAttribute)
            return
        }
        tintedWalk = CrabSprite.walkTextures(hueDegrees: hueDegrees)
        // Restart the current animation so it picks up the recolored frames.
        if isMoving { playMoving() } else { applyGait(force: true) }
    }

    // MARK: - Status + animation

    func setStatus(_ newStatus: CrabStatus) {
        let old = status
        let changed = newStatus != status
        status = newStatus
        if changed { updateBadge(); updateTagFade(); if bubble.isShowing { refreshBubble() } }
        // A tool pause may finish the current walk (so a crab never stops on top of a neighbour);
        // any other non-roaming status stops it where it is. A dash to the other side keeps going.
        if changed, !canWander, newStatus != .usingTool, !isDashing { wanderTarget = nil; isMoving = false }
        if !isMoving { applyGait(force: changed || sprite.action(forKey: "gait") == nil) }
        if changed, newStatus == .doneUnseen, old.isBusy, !usesPet { celebrate() }
    }

    private func applyGait(force: Bool) {
        guard force else { return }
        sprite.removeAction(forKey: "gait")
        removeAction(forKey: "hop")
        removeAction(forKey: "zzz")
        sprite.position = .zero
        sprite.zRotation = 0
        sprite.yScale = 1
        sprite.alpha = 1
        sprite.speed = 1
        if usesPet { petGait() } else { pixelGait() }
    }

    /// Pets carry their own animation per state; we just play the right sheet.
    private func petGait() {
        let key: String
        switch status {
        case .working:         key = workingPetKey
        case .usingTool:       key = workingPetKey  // same animation as working, by request
        case .needsPermission: key = "needsPermission"
        case .needsQuestion:   key = "needsQuestion"
        case .doneUnseen:      key = "doneUnseen"
        case .doneSeen:        key = "doneSeen"
        case .dormant:         key = "dormant"
        case .error:           key = "error"
        }
        playPet(key, loop: true)
        if status == .dormant { sprite.alpha = 0.8 }
    }

    private func playPet(_ key: String, loop: Bool, completion: (() -> Void)? = nil) {
        let hover = PetLibrary.hover(key)
        let frames = PetLibrary.frames(key, withoutShadow: usesPet && (carried || hover.lift > 0))
        guard !frames.isEmpty else { return }
        petLift = hover.lift
        petSway = hover.sway
        applyShadowCrop()
        applyHover()
        currentPetKey = key
        applyFacing()
        sprite.removeAction(forKey: "gait")
        let anim = SKAction.animate(with: frames, timePerFrame: 1.0 / PetLibrary.fps, resize: false, restore: false)
        if loop {
            sprite.run(.repeatForever(anim), withKey: "gait")
        } else if let completion {
            sprite.run(.sequence([anim, .run(completion)]), withKey: "gait")
        } else {
            sprite.run(anim, withKey: "gait")
        }
    }

    /// The pixel crab has no poses of its own, so we act them out with small motions.
    private func pixelGait() {
        switch status {
        case .working:
            // A baby only churns its legs while it is walking (the scene calls `startMoving`);
            // standing next to its parent it just bobs.
            if isBaby {
                sprite.texture = tintedIdle
                breathe()
            } else {
                march(timePerFrame: 0.07)
            }
        case .usingTool:
            sprite.texture = tintedIdle
            breathe()
        case .needsPermission, .needsQuestion:
            sprite.texture = tintedIdle
            jump()
        case .doneUnseen:
            sprite.texture = tintedIdle
            breathe()
            occasionalHop()
        case .doneSeen:
            sprite.texture = tintedIdle
            breathe()
        case .dormant:
            sprite.texture = tintedIdle
            sleep()
        case .error:
            sprite.texture = tintedIdle
            dizzy()
        }
    }

    private func march(timePerFrame: TimeInterval) {
        sprite.removeAction(forKey: "gait")
        sprite.position = .zero
        let walk = SKAction.animate(with: tintedWalk, timePerFrame: timePerFrame, resize: false, restore: false)
        sprite.run(.repeatForever(walk), withKey: "gait")
    }

    private func breathe() {
        let bob = SKAction.sequence([.moveBy(x: 0, y: 2, duration: 0.7), .moveBy(x: 0, y: -2, duration: 0.7)])
        bob.timingMode = .easeInEaseOut
        sprite.run(.repeatForever(bob), withKey: "gait")
    }

    private func jump() {
        let up = SKAction.moveBy(x: 0, y: 10, duration: 0.22); up.timingMode = .easeOut
        let down = SKAction.moveBy(x: 0, y: -10, duration: 0.22); down.timingMode = .easeIn
        sprite.run(.repeatForever(.sequence([up, down, .wait(forDuration: 0.25)])), withKey: "gait")
    }

    private func occasionalHop() {
        let hop = SKAction.sequence([.moveBy(x: 0, y: 7, duration: 0.18), .moveBy(x: 0, y: -7, duration: 0.18)])
        run(.repeatForever(.sequence([.wait(forDuration: 3.0, withRange: 2.0), hop])), withKey: "hop")
    }

    private func dizzy() {
        let wobble = SKAction.sequence([.rotate(toAngle: 0.12, duration: 0.25),
                                        .rotate(toAngle: -0.12, duration: 0.25)])
        wobble.timingMode = .easeInEaseOut
        sprite.run(.repeatForever(wobble), withKey: "gait")
    }

    private func sleep() {
        sprite.alpha = 0.55
        sprite.yScale = 0.72
        let spawnZ = SKAction.run { [weak self] in self?.floatZ() }
        run(.repeatForever(.sequence([.wait(forDuration: 2.4, withRange: 1.2), spawnZ])), withKey: "zzz")
    }

    private func floatZ() {
        let z = SKLabelNode(text: "z")
        z.fontName = "Menlo-Bold"
        z.fontSize = isBaby ? 7 : 9
        z.fontColor = BadgeStyle.Palette.sleep
        z.position = CGPoint(x: sprite.size.width * 0.25, y: sprite.size.height * 0.6)
        z.zPosition = 4
        addChild(z)
        let drift = SKAction.group([.moveBy(x: 6, y: 16, duration: 1.6), .fadeOut(withDuration: 1.6)])
        drift.timingMode = .easeOut
        z.run(.sequence([drift, .removeFromParent()]))
    }

    /// Two quick hops (pixel crabs only; the celebrating pet jumps by itself).
    func celebrate() {
        removeAction(forKey: "celebrate")
        let hop = SKAction.sequence([.moveBy(x: 0, y: 12, duration: 0.15), .moveBy(x: 0, y: -12, duration: 0.15)])
        hop.timingMode = .easeOut
        run(.sequence([hop, .wait(forDuration: 0.1), hop]), withKey: "celebrate")
    }

    /// A quick side-to-side wiggle when a crab arrives.
    func wave() {
        let wiggle = SKAction.sequence([.rotate(toAngle: 0.2, duration: 0.1),
                                        .rotate(toAngle: -0.2, duration: 0.2),
                                        .rotate(toAngle: 0.2, duration: 0.2),
                                        .rotate(toAngle: 0, duration: 0.1)])
        sprite.run(wiggle, withKey: "wave")
    }

    // MARK: - Moving, leaving, dragging

    private func playMoving() {
        sprite.speed = isDashing ? Self.dashGaitSpeed : 1
        if usesPet { playPet("moving", loop: true) } else { march(timePerFrame: status == .working ? 0.07 : 0.1) }
    }

    func startMoving() {
        guard !isMoving else { return }
        isMoving = true
        removeAction(forKey: "hop")
        playMoving()
    }

    func stopMoving() {
        guard isMoving else { return }
        isMoving = false
        applyGait(force: true)
    }

    /// Run (fast) to `x`, the crab's spot on its new side, on the speed curve in `gait`.
    /// Any stroll in progress is dropped.
    func startDash(to x: CGFloat, gait: Gait) {
        dashTarget = x
        dashFromX = position.x
        dashGait = gait
        dashElapsed = 0
        wanderTarget = nil
        facingRight = x > position.x
        removeAction(forKey: "zzz")
        sprite.zRotation = 0; sprite.yScale = 1; sprite.alpha = 1; sprite.position = .zero
        isMoving = false    // restart the walk cycle so it picks up the dash speed
        startMoving()
    }

    /// Stroll to `x` at walking pace, on the speed curve in `gait`.
    func startStroll(to x: CGFloat, gait: Gait) {
        wanderTarget = x
        wanderFromX = position.x
        wanderGait = gait
        wanderElapsed = 0
        facingRight = x > position.x
        startMoving()
    }

    /// How hard the legs are going right now: 0 is a walk, 1 is a full sprint.
    func setDashPace(_ pace: CGFloat) {
        sprite.speed = 1 + (Self.dashGaitSpeed - 1) * min(max(pace, 0), 1)
    }

    /// The same for a stroll: the walk cycle winds up and down with the crab, so it never looks
    /// like it is skating across the floor as it sets off or stops.
    func setStrollPace(_ pace: CGFloat) {
        sprite.speed = 0.5 + 0.5 * min(max(pace, 0), 1)
    }

    /// Arrived on the other side: settle into the status pose.
    func finishDash() {
        dashTarget = nil
        stopMoving()
    }

    /// Plays the leaving animation once, then calls `completion`. Pixel crabs just keep marching.
    func showLeaving(completion: @escaping () -> Void) {
        wanderTarget = nil
        dashTarget = nil
        isMoving = false
        carried = false   // a crab can be dropped from the hand straight into leaving
        sprite.speed = 1
        removeAction(forKey: "hop"); removeAction(forKey: "zzz"); removeAction(forKey: "celebrate")
        sprite.zRotation = 0; sprite.yScale = 1; sprite.alpha = 1
        if usesPet, !PetLibrary.frames("leaving").isEmpty {
            playPet("leaving", loop: false, completion: completion)
        } else {
            march(timePerFrame: 0.05)
            completion()
        }
    }

    func showDragging() {
        wanderTarget = nil
        dashTarget = nil
        isMoving = false
        sprite.speed = 1
        removeAction(forKey: "hop"); removeAction(forKey: "zzz"); removeAction(forKey: "celebrate")
        sprite.zRotation = 0; sprite.yScale = 1; sprite.alpha = 1
        carried = true
        if usesPet { playPet("moving", loop: true) } else { march(timePerFrame: 0.05) }
    }

    func restoreStatus() {
        carried = false
        applyGait(force: true)
    }
}
