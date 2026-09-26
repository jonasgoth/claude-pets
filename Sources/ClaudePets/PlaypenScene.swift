import AppKit
import SpriteKit

/// The speed curve of one walk or run: wind up to full speed, hold it, then wind down.
///
/// A flat speed looks robotic and a single ease-in-out (the old curve) is a bell — it only ever
/// touches top speed for an instant. This is the shape a real walker makes instead: a short
/// acceleration, a long steady middle, and a slightly longer, softer stop. The two ramps are set
/// separately, which is what sells it — getting going is brisker than coming to a halt.
///
/// If the trip is too short to fit both ramps there is simply no steady middle and the top speed
/// comes out lower: a small step is a slow step, exactly like the real thing.
struct Gait {
    /// How long the whole trip takes.
    let duration: TimeInterval
    /// Wind-up and wind-down, as fractions of `duration`.
    private let up: CGFloat
    private let down: CGFloat
    /// Distance covered, as a fraction of "top speed for the whole duration".
    private let area: CGFloat
    /// Top speed reached, as a fraction of the asked-for cruise speed (1 unless the trip is short).
    private let peak: CGFloat

    /// A trip of `distance` points that cruises at `cruise` points per second, spending about
    /// `rampUp` seconds getting there and `rampDown` seconds stopping.
    init(distance: CGFloat, cruise: CGFloat, rampUp: TimeInterval, rampDown: TimeInterval) {
        let d = max(abs(distance), 0.01)
        let speed = max(cruise, 1)
        let ramps = max(rampUp + rampDown, 0.01)
        // Each ramp covers half the ground a full-speed stretch of the same length would, so the
        // steady middle only has to make up what is left.
        let flat = max(TimeInterval(d / speed) - ramps / 2, 0)
        let total = max(flat + ramps, 0.05)
        duration = total
        up = CGFloat(rampUp / total)
        down = CGFloat(rampDown / total)
        area = max(1 - up / 2 - down / 2, 0.01)
        peak = min(d / (CGFloat(total) * area) / speed, 1)
    }

    /// A straight line at `cruise` speed — the neutral default.
    init() {
        duration = 1; up = 0; down = 0; area = 1; peak = 1
    }

    /// Speed at ramp position `u` (0...1), as a fraction of top speed. Smooth at both ends, so
    /// there is no kick when the legs start or when they stop.
    private static func ramp(_ u: CGFloat) -> CGFloat {
        let x = min(max(u, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Ground covered by a ramp up to position `u`, as a fraction of "top speed x ramp length".
    /// This is just the area under `ramp`, which is half a full ramp end to end.
    private static func rampDistance(_ u: CGFloat) -> CGFloat {
        let x = min(max(u, 0), 1)
        return x * x * x - x * x * x * x / 2
    }

    /// How much of the trip is behind the crab `t` seconds in (0 at the start, 1 on arrival).
    func progress(_ t: TimeInterval) -> CGFloat {
        let x = min(max(CGFloat(t / duration), 0), 1)
        let cruiseEnd = 1 - down
        if up > 0, x <= up { return up * Self.rampDistance(x / up) / area }
        if x <= cruiseEnd { return (up / 2 + (x - up)) / area }
        let u = down > 0 ? (x - cruiseEnd) / down : 1
        return (up / 2 + (cruiseEnd - up) + down * (0.5 - Self.rampDistance(1 - u))) / area
    }

    /// How fast the crab is going `t` seconds in, 1 being the cruise speed. Paces the legs.
    func pace(_ t: TimeInterval) -> CGFloat {
        let x = min(max(CGFloat(t / duration), 0), 1)
        let cruiseEnd = 1 - down
        if up > 0, x <= up { return peak * Self.ramp(x / up) }
        if x <= cruiseEnd { return peak }
        let u = down > 0 ? (x - cruiseEnd) / down : 1
        return peak * Self.ramp(1 - u)
    }
}

/// The 2D floor the crabs stand on. Owns the crabs (and sub-agent baby crabs), handles dragging,
/// runs the little wander brain, and lets the SessionStore add / update / remove crabs.
final class PlaypenScene: SKScene {
    /// Pets sit 2px below the strip's bottom edge. Their sprites carry a hair of transparent
    /// padding under the feet, so standing at exactly 0 reads as floating. The 2px bleeds off
    /// the bottom of the screen on purpose.
    static let floorInset: CGFloat = -2
    /// How far from the herd's center a crab will roam (grows a little with the herd).
    static let baseHerdSpread: CGFloat = 160
    /// How fast a relaxed crab ambles during its occasional shuffle.
    static let strollSpeed: CGFloat = 34
    /// Top speed of a crab switching sides (started working, or finished). It winds up to this,
    /// holds it for most of the run, then eases off.
    static let dashSpeed: CGFloat = 750
    /// How long a stroll takes to get up to speed, and to come to a stop. Stopping is the slower
    /// of the two, which is what makes the walk read as a walk.
    static let strollRampUp: TimeInterval = 0.3
    static let strollRampDown: TimeInterval = 0.45
    /// Same for a run: a brisk push off the mark, a longer glide into the stop.
    static let dashRampUp: TimeInterval = 0.28
    static let dashRampDown: TimeInterval = 0.5
    /// Minimum breathing room between crabs.
    static let spacing: CGFloat = 96
    /// Closer than this and two crabs are touching — fine for a moment, but worth a step aside.
    static let snugGap: CGFloat = 44
    /// Closer than this and one crab is standing on the other. Always worth fixing, fast.
    static let stackedGap: CGFloat = 22

    /// A crab only steps aside for a cosy neighbour this often, so crowding never turns into shoving.
    static let unstackCooldown: TimeInterval = 30
    /// But properly stacked crabs untangle almost straight away — no waiting out the long cooldown.
    static let stackedCooldown: TimeInterval = 1.5
    /// After you drop a crab it stays put this long before rejoining the herd.
    static let holdAfterDrag: TimeInterval = 45
    /// Speed of the little walk home after you drop a crab somewhere it cannot stand.
    static let walkHomeSpeed: CGFloat = 120
    /// How hard random spots lean toward the outer edge of a side. 1 = no lean, higher = further out.
    static let outwardBias: CGFloat = 2.0
    /// Closest a baby will stand to its parent's edge, and how much further out it may wander.
    static let babyNearGap: CGFloat = 6
    static let babyRoamSpread: CGFloat = 20
    /// Babies shuffle slower than the grown-ups, and stand still for this long between strolls.
    static let babyStep: CGFloat = 1.4
    /// Wandered past its leash (usually because the parent ran off): it scurries, up to this
    /// much faster than its normal shuffle, until it is back within reach.
    static let babyCatchUpStep: CGFloat = 6
    static let babyDawdle: ClosedRange<TimeInterval> = 0.6...4.5

    /// Pick a parent up and its babies come along on a stretchy leash: each one chases the crab
    /// in front of it, so it is always a little behind and always catching up. How far back each
    /// one tries to sit, how much the line droops, and how hard/loose the leash pulls.
    static let towGap: CGFloat = 22
    static let towDroop: CGFloat = 12
    static let towStiffness: CGFloat = 46
    /// Leftover speed kept per 60th of a second — lower is soggier, higher swings more.
    static let towDamping: CGFloat = 0.88
    static let towMaxSpeed: CGFloat = 1800
    /// Once you let go, the babies drop back to the floor at this rate.
    static let towGravity: CGFloat = 1500

    /// Called with a session id right after a click on its crab actually opened that chat.
    var onOpened: ((String) -> Void)?
    /// Fires with `true` the moment a crab is picked up (the window grows to the whole screen so
    /// it can be carried right to the top) and `false` once everyone is back on the floor.
    var onNeedsTallWindow: ((Bool) -> Void)?
    private var needsTallWindow = false

    private(set) var crabs: [CrabNode] = []
    private var byId: [String: CrabNode] = [:]
    private var babies: [String: CrabNode] = [:]
    private var babyParent: [String: String] = [:]
    /// Where each baby currently wants to stand, as an offset from its parent, and when it will
    /// get bored of that spot and pick a new one.
    private var babyRoam: [String: (offset: CGFloat, until: TimeInterval)] = [:]
    /// Babies riding along with a crab you have picked up: the line they are in (front first),
    /// how fast each is travelling, and whether you have let go yet.
    private var towLine: [String] = []
    private var towVelocity: [String: CGVector] = [:]
    private var towLeader: CrabNode?
    private var towReleased = false
    private var leaving: Set<String> = []

    private var dragged: CrabNode?
    private var pressStart: CGPoint = .zero
    private var didDrag = false
    private var dragOffset = CGPoint.zero
    private var lastDragX: CGFloat = 0

    /// The crab under the cursor, and where the cursor was (scene coordinates) when we last heard.
    private var hovered: CrabNode?
    private var hoverPoint = CGPoint(x: -1000, y: -1000)
    /// The cursor must rest on a crab this long before its bubble pops (no flashing while crossing).
    static let hoverDelay: TimeInterval = 0.25

    private var sceneTime: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0
    /// Keep the frame rate up for a moment after something changes, so short animations look smooth.
    private var boostUntil: TimeInterval = 0

    var isDragging: Bool { dragged != nil }
    var floorY: CGFloat { Self.floorInset }

    /// The Dock's footprint in scene x (with margin). Pets live in the gaps on either side of it.
    var blockedX: ClosedRange<CGFloat>? {
        didSet {
            guard blockedX != oldValue else { return }
            for crab in crabs where crab !== dragged {
                let x = clampX(crab.position.x, for: crab)
                if x != crab.position.x { stroll(crab, to: x) }
            }
        }
    }

    /// Where pets may stand: one range per wallpaper gap (or the whole floor if there is no Dock here).
    private var allowedRanges: [ClosedRange<CGFloat>] {
        let edge: CGFloat = 40
        guard let b = blockedX else { return [edge...max(edge, size.width - edge)] }
        var out: [ClosedRange<CGFloat>] = []
        if b.lowerBound - edge > edge + 60 { out.append(edge...(b.lowerBound)) }
        if size.width - edge - b.upperBound > 60 { out.append(b.upperBound...(size.width - edge)) }
        return out.isEmpty ? [edge...max(edge, size.width - edge)] : out
    }

    private func range(containing x: CGFloat) -> ClosedRange<CGFloat> {
        let ranges = allowedRanges
        if let r = ranges.first(where: { $0.contains(x) }) { return r }
        return ranges.min(by: { distance(x, to: $0) < distance(x, to: $1) }) ?? ranges[0]
    }

    private func distance(_ x: CGFloat, to r: ClosedRange<CGFloat>) -> CGFloat {
        x < r.lowerBound ? r.lowerBound - x : (x > r.upperBound ? x - r.upperBound : 0)
    }

    /// The two sides of the floor. Left is the working side, right is the done side. With the Dock
    /// in our row that is simply the left gap and the right gap; otherwise the floor is split in half.
    private var sides: (working: ClosedRange<CGFloat>, done: ClosedRange<CGFloat>) {
        let ranges = allowedRanges
        if ranges.count >= 2 { return (ranges[0], ranges[ranges.count - 1]) }
        let r = ranges[0]
        let mid = (r.lowerBound + r.upperBound) / 2
        let aisle = min(30, (r.upperBound - r.lowerBound) / 4)   // a little no-man's-land in the middle
        return (r.lowerBound...(mid - aisle), (mid + aisle)...r.upperBound)
    }

    private func side(for status: CrabStatus) -> ClosedRange<CGFloat> {
        status.isWorkingSide ? sides.working : sides.done
    }

    /// Where a crab will be standing once it stops: its dash or stroll target, else where it is.
    private func restingX(of crab: CrabNode) -> CGFloat {
        crab.dashTarget ?? crab.wanderTarget ?? crab.position.x
    }

    /// True when the outer (screen-edge) end of a side is its left end.
    private func outerIsLeft(_ r: ClosedRange<CGFloat>) -> Bool {
        r.lowerBound < size.width - r.upperBound
    }

    /// How far along a side a crab stands, 0 at the screen edge and 1 at the inner end.
    private func inwardness(_ x: CGFloat, in r: ClosedRange<CGFloat>) -> CGFloat {
        let span = max(r.upperBound - r.lowerBound, 1)
        let t = min(max((x - r.lowerBound) / span, 0), 1)
        return outerIsLeft(r) ? t : 1 - t
    }

    /// A random x on a side, still anywhere on it but landing further out more often than not.
    private func outwardX(in r: ClosedRange<CGFloat>, inset: CGFloat) -> CGFloat {
        let lo = r.lowerBound + inset
        let hi = max(lo, r.upperBound - inset)
        let t = pow(CGFloat.random(in: 0...1), Self.outwardBias)   // 0 = right at the outer edge
        return outerIsLeft(r) ? lo + t * (hi - lo) : hi - t * (hi - lo)
    }

    override init(size: CGSize) {
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        anchorPoint = .zero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Session-driven crabs

    /// Apply a full snapshot from the store: add/update/remove crabs and babies in one pass.
    func apply(_ snapshot: SessionStore.Snapshot) {
        let ids = Set(snapshot.crabs.map { $0.id })
        for id in Array(byId.keys) where !ids.contains(id) { removeCrab(id: id) }
        for c in snapshot.crabs { syncCrab(id: c.id, title: c.title, hue: c.hue, status: c.status) }
        for b in snapshot.babies { syncBaby(id: b.id, parentId: b.parentId, hue: b.hue) }
        pruneBabies(keeping: Set(snapshot.babies.map { $0.id }))
        for c in snapshot.crabs {
            byId[c.id]?.detail = c.detail
            byId[c.id]?.openTarget = c.open
            byId[c.id]?.openSessionId = c.id
        }
        // A sub-agent belongs to its parent's chat, so clicking a baby goes to the same place.
        for (babyId, parentId) in babyParent {
            babies[babyId]?.openTarget = byId[parentId]?.openTarget
            babies[babyId]?.openSessionId = parentId
        }
        for crab in crabs { crab.helpers = babyParent.values.filter { $0 == crab.id }.count }
    }

    func syncCrab(id: String, title: String, hue: CGFloat, status: CrabStatus) {
        if let crab = byId[id] {
            crab.title = title
            crab.projectHue = hue
            let old = crab.currentStatus
            if dragged !== crab, old != status {
                crab.setStatus(status)
                boostUntil = sceneTime + 2
                // Switching sides beats a hand placement: the crab runs over right away.
                if old.isWorkingSide != status.isWorkingSide { crab.holdUntil = 0 }
                if status == .doneUnseen, old.isBusy { SoundPlayer.play(.done) }
                if status.needsYou, !old.needsYou { SoundPlayer.play(.attention) }
            }
            return
        }
        let crab = CrabNode(id: id)
        crab.title = title
        crab.projectHue = hue
        crab.position = CGPoint(x: landingX(in: side(for: status), for: nil), y: floorY)
        crab.setStatus(status)
        crab.nextWanderAt = sceneTime + 3
        addChild(crab)
        crabs.append(crab)
        byId[id] = crab
        boostUntil = sceneTime + 2
        crab.setScale(0.6); crab.alpha = 0
        crab.run(.sequence([.group([.fadeIn(withDuration: 0.2), .scale(to: 1, duration: 0.25)]),
                            .run { crab.wave() }]))
    }

    func removeCrab(id: String) {
        guard let crab = byId[id], !leaving.contains(id) else { return }
        leaving.insert(id)
        byId[id] = nil
        crabs.removeAll { $0 === crab }
        if dragged === crab { dragged = nil }
        if hovered === crab { setHovered(nil, at: nil) }
        for (babyId, parent) in babyParent where parent == id { removeBaby(id: babyId) }
        // Hand this crab's working animation back, so the next arrival can take it.
        PetLibrary.releaseWorkingKey(for: id)
        walkOff(crab, id: id)
    }

    // MARK: - Sub-agent baby crabs

    func syncBaby(id: String, parentId: String, hue: CGFloat) {
        let baby: CrabNode
        if let existing = babies[id] {
            baby = existing
        } else {
            baby = CrabNode(id: id, isBaby: true)
            baby.projectHue = hue
            baby.position = CGPoint(x: (byId[parentId]?.position.x ?? size.width / 2), y: floorY)
            baby.setStatus(.working)
            addChild(baby)
            babies[id] = baby
            babyParent[id] = parentId
            baby.setScale(0.4); baby.alpha = 0
            baby.run(.group([.fadeIn(withDuration: 0.2), .scale(to: 1, duration: 0.25)]))
        }
        baby.projectHue = hue
    }

    func pruneBabies(keeping active: Set<String>) {
        for id in Set(babies.keys).subtracting(active) { removeBaby(id: id) }
    }

    private func removeBaby(id: String) {
        guard let baby = babies[id] else { return }
        babies[id] = nil
        babyParent[id] = nil
        babyRoam[id] = nil
        towLine.removeAll { $0 == id }
        towVelocity[id] = nil
        baby.run(.sequence([.group([.fadeOut(withDuration: 0.2), .scale(to: 0.4, duration: 0.2)]),
                            .removeFromParent()]))
    }

    // MARK: - Per-frame brain

    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdate == 0 ? 0 : min(currentTime - lastUpdate, 0.1)
        lastUpdate = currentTime
        sceneTime = currentTime

        keepSides()
        wander(dt: dt)
        unstack()
        towBabies(dt: dt)
        followParents(dt: dt)
        layoutTags()
        hoverCheck()
        adaptFrameRate()
        settleTallWindow()
    }

    /// Ask for the full-height window while a crab is in the air; hand the extra room back the
    /// moment nothing is being carried, dropped or towed any more.
    private func settleTallWindow() {
        guard needsTallWindow, !isDragging, towLeader == nil else { return }
        let airborne = crabs.contains { $0.position.y > floorY + 1 || $0.action(forKey: "settle") != nil }
        guard !airborne else { return }
        needsTallWindow = false
        onNeedsTallWindow?(false)
    }

    /// Left is the working side, right is the done side. Anyone standing on the wrong side runs
    /// over (a crab you just placed by hand waits out its hold first). A crab whose status flips
    /// mid-run turns around.
    private func keepSides() {
        let slack: CGFloat = 24
        for crab in crabs where crab !== dragged && sceneTime >= crab.holdUntil {
            let home = side(for: crab.currentStatus)
            if let target = crab.dashTarget {
                if !home.contains(target) { dash(crab, to: landingX(in: home, for: crab)) }
                continue
            }
            guard !(home.lowerBound - slack...home.upperBound + slack).contains(crab.position.x) else { continue }
            dash(crab, to: landingX(in: home, for: crab))
        }
    }

    private func dash(_ crab: CrabNode, to x: CGFloat, speed: CGFloat = PlaypenScene.dashSpeed) {
        crab.startDash(to: x, gait: Gait(distance: x - crab.position.x, cruise: speed,
                                         rampUp: Self.dashRampUp, rampDown: Self.dashRampDown))
        boostUntil = sceneTime + 2
    }

    /// Send a crab strolling to `x` at walking pace, on the same wind-up / hold / wind-down curve.
    private func stroll(_ crab: CrabNode, to x: CGFloat) {
        crab.startStroll(to: x, gait: Gait(distance: x - crab.position.x, cruise: Self.strollSpeed,
                                           rampUp: Self.strollRampUp, rampDown: Self.strollRampDown))
    }

    /// Only relaxed crabs roam, and barely: they stand and live their little life, and every now
    /// and then take one short shuffle. Working crabs stay put and just play their animation.
    /// A crab switching sides runs, fast, and does nothing else until it gets there.
    private func wander(dt: TimeInterval) {
        for crab in crabs where crab !== dragged {
            if let target = crab.dashTarget {
                crab.dashElapsed += dt
                let done = crab.dashGait.progress(crab.dashElapsed)
                crab.position.x = crab.dashFromX + (target - crab.dashFromX) * done
                crab.setDashPace(crab.dashGait.pace(crab.dashElapsed))
                if crab.dashElapsed >= crab.dashGait.duration {
                    crab.position.x = target
                    crab.finishDash()
                    crab.nextWanderAt = sceneTime + .random(in: 12...30)
                }
                continue
            }

            let home = side(for: crab.currentStatus)
            let mates = crabs.filter { $0 !== crab && home.contains(restingX(of: $0)) }
            let herdCenter = mates.isEmpty ? (home.lowerBound + home.upperBound) / 2
                : mates.map { restingX(of: $0) }.reduce(0, +) / CGFloat(mates.count)

            if let target = crab.wanderTarget {
                crab.wanderElapsed += dt
                let done = crab.wanderGait.progress(crab.wanderElapsed)
                let next = crab.wanderFromX + (target - crab.wanderFromX) * done
                // Someone moved into the way mid-stroll? Stop here rather than climb on them.
                if wouldBump(crab, movingTo: next) {
                    crab.wanderTarget = nil
                    crab.stopMoving()
                    crab.nextWanderAt = sceneTime + .random(in: 6...12)
                    continue
                }
                crab.position.x = next
                crab.setStrollPace(crab.wanderGait.pace(crab.wanderElapsed))
                if crab.wanderElapsed >= crab.wanderGait.duration {
                    crab.position.x = target
                    crab.wanderTarget = nil
                    crab.stopMoving()
                    crab.nextWanderAt = sceneTime + .random(in: 12...30)
                }
                continue
            }

            guard crab.canWander, sceneTime >= crab.nextWanderAt, sceneTime >= crab.holdUntil else { continue }

            // Most of the time it just stays where it is.
            if CGFloat.random(in: 0..<1) < 0.8 {
                crab.nextWanderAt = sceneTime + .random(in: 8...18)
                continue
            }

            // One short shuffle, leaning back toward the herd if it has drifted off.
            let towardHerd: CGFloat = herdCenter > crab.position.x ? 1 : -1
            let drifted = abs(herdCenter - crab.position.x) > Self.baseHerdSpread
            // Each shuffle leans toward the outer edge, more so the further in the crab stands, so
            // the herd settles around the outer third instead of anywhere on its side.
            let outward: CGFloat = outerIsLeft(home) ? -1 : 1
            let goOut = CGFloat.random(in: 0..<1) < min(0.2 + 0.9 * inwardness(crab.position.x, in: home), 0.9)
            let direction: CGFloat = drifted ? towardHerd : (goOut ? outward : -outward)
            let wish = crab.position.x + direction * .random(in: 18...55)
            let target = freeSpot(near: wish, in: home, for: crab)
            if abs(target - crab.position.x) < 8 {
                crab.nextWanderAt = sceneTime + .random(in: 6...12)
                continue
            }
            stroll(crab, to: target)
        }
    }

    /// Two crabs standing too close take one short step apart — a single shuffle, not a continuous
    /// shove. Brushing shoulders is fine, so that only gets sorted out every `unstackCooldown`
    /// seconds; standing right on top of each other is never fine, and gets sorted out at once.
    /// Crabs you placed by hand stay where you put them, and crabs that want your attention or are
    /// asleep hold their ground too — unless they are the ones stacked, where nobody wins by waiting.
    private func unstack() {
        let free = crabs.filter { $0 !== dragged && !$0.isDashing }.sorted { $0.position.x < $1.position.x }
        guard free.count > 1 else { return }
        func fixed(_ c: CrabNode, stacked: Bool) -> Bool {
            if c.holdUntil > sceneTime { return true }
            if stacked { return false }
            return c.currentStatus.needsYou || c.currentStatus == .dormant
        }
        for i in 1..<free.count {
            let a = free[i - 1], b = free[i]
            let gap = b.position.x - a.position.x
            guard gap < Self.snugGap else { continue }
            let stacked = gap < Self.stackedGap
            let aFixed = fixed(a, stacked: stacked), bFixed = fixed(b, stacked: stacked)
            let room = Self.snugGap - gap
            let wait = stacked ? Self.stackedCooldown : Self.unstackCooldown
            if !aFixed { stepAside(a, by: -(bFixed ? room : room / 2), wait: wait) }
            if !bFixed { stepAside(b, by: aFixed ? room : room / 2, wait: wait) }
        }
    }

    /// One short walk about `dx` points sideways — to the nearest spot that is actually clear — then
    /// a cooldown before this crab budges again. A crab already walking, or still held after a
    /// drag, is left alone.
    private func stepAside(_ crab: CrabNode, by dx: CGFloat, wait: TimeInterval) {
        guard crab.wanderTarget == nil, sceneTime >= crab.nextUnstackAt, sceneTime >= crab.holdUntil else { return }
        crab.nextUnstackAt = sceneTime + wait
        let home = side(for: crab.currentStatus)
        let step = dx + (dx < 0 ? -8 : 8)   // a touch extra, so they end up clearly apart
        let target = freeSpot(near: crab.position.x + step, in: home, for: crab, gap: Self.snugGap)
        guard abs(target - crab.position.x) > 2 else { return }
        stroll(crab, to: target)
    }

    /// Every x another crab occupies: where it stands now, and where it is headed. Both count, so
    /// two crabs never pick the same spot and then discover each other once they arrive.
    private func occupied(excluding crab: CrabNode?) -> [CGFloat] {
        crabs.filter { $0 !== crab }.flatMap { [$0.position.x, restingX(of: $0)] }
    }

    /// The spot closest to `x`, inside `home`, that keeps `gap` points clear of every other crab.
    /// If the side is too packed for that it returns the roomiest spot it found instead — a crab
    /// never deliberately walks onto another one, however crowded things get.
    private func freeSpot(near x: CGFloat, in home: ClosedRange<CGFloat>, for crab: CrabNode?,
                          gap: CGFloat = PlaypenScene.spacing) -> CGFloat {
        let half = (crab?.size.width ?? 0) / 2 + 8
        let lo = home.lowerBound + half
        let hi = max(lo, home.upperBound - half)
        let taken = occupied(excluding: crab)
        func clearance(_ v: CGFloat) -> CGFloat { taken.map { abs($0 - v) }.min() ?? .greatestFiniteMagnitude }

        let start = min(max(x, lo), hi)
        var best = start
        var bestClearance = clearance(start)
        if bestClearance >= gap { return start }
        var step: CGFloat = 8
        while step <= hi - lo + 8 {
            for candidate in [start - step, start + step] where candidate >= lo && candidate <= hi {
                let c = clearance(candidate)
                if c >= gap { return candidate }
                if c > bestClearance { bestClearance = c; best = candidate }
            }
            step += 8
        }
        return best
    }

    /// True when this next step would press the crab into a neighbour it is not already inside —
    /// it stops short rather than walking over someone standing in the way.
    private func wouldBump(_ crab: CrabNode, movingTo next: CGFloat) -> Bool {
        crabs.contains { other in
            guard other !== crab, other !== dragged else { return false }
            let after = abs(other.position.x - next)
            return after < Self.snugGap && after < abs(other.position.x - crab.position.x)
        }
    }

    /// A fresh spot for a baby to potter off to, as an offset from its parent. Either side, never
    /// far, and sometimes barely a step from where it already is so it looks like it is loitering.
    private func randomBabyOffset(near parent: CrabNode) -> CGFloat {
        let inner = parent.size.width * 0.5 + Self.babyNearGap
        let side: CGFloat = Bool.random() ? -1 : 1
        return side * CGFloat.random(in: inner...(inner + Self.babyRoamSpread))
    }

    /// The leash: furthest a baby is ever allowed to be from its parent's middle.
    private func babyReach(of parent: CrabNode) -> CGFloat {
        parent.size.width * 0.5 + Self.babyNearGap + Self.babyRoamSpread
    }

    // MARK: - Carrying a family

    /// You picked `parent` up: line its babies up behind it, nearest one at the front.
    private func beginTow(for parent: CrabNode) {
        if towLeader !== parent { endTow() }
        let mine = babyParent.filter { $0.value == parent.id }.map(\.key)
        guard !mine.isEmpty else { return }
        towLeader = parent
        towReleased = false
        towLine = mine.sorted {
            abs((babies[$0]?.position.x ?? 0) - parent.position.x)
                < abs((babies[$1]?.position.x ?? 0) - parent.position.x)
        }
        for id in towLine {
            towVelocity[id] = .zero
            babies[id]?.zPosition = 9      // under the crab in your hand, over everyone else
        }
    }

    /// The stretchy leash, one frame at a time. Each baby springs toward the crab in front of it —
    /// the parent for the one at the head of the line — so a yank travels down the chain and
    /// everybody arrives late, scrabbling to catch up. Once you let go, gravity joins in.
    private func towBabies(dt: TimeInterval) {
        guard let parent = towLeader, dt > 0 else { return }
        towLine.removeAll { babies[$0] == nil }
        // A sub-agent that starts up mid-carry joins the back of the line.
        for id in babyParent.filter({ $0.value == parent.id }).map(\.key) where !towLine.contains(id) {
            towLine.append(id)
            towVelocity[id] = .zero
            babies[id]?.zPosition = 9
        }
        guard !towLine.isEmpty else { endTow(); return }

        let step = CGFloat(dt)
        let damp = pow(Self.towDamping, step * 60)
        var lead = parent.position
        var leadWidth = parent.size.width
        var allSettled = towReleased

        for id in towLine {
            guard let baby = babies[id] else { continue }
            var v = towVelocity[id] ?? .zero

            // Aim for a spot behind whoever is in front — on the side the baby is already on, so
            // it never cuts through them — and a little lower, so the line droops like a tail.
            let behind: CGFloat = baby.position.x < lead.x ? -1 : 1
            let target = CGPoint(x: lead.x + behind * (leadWidth * 0.4 + Self.towGap),
                                 y: max(floorY, lead.y - Self.towDroop))

            v.dx += (target.x - baby.position.x) * Self.towStiffness * step
            v.dy += (target.y - baby.position.y) * Self.towStiffness * step
            if towReleased { v.dy -= Self.towGravity * step }
            v.dx *= damp
            v.dy *= damp
            let speed = hypot(v.dx, v.dy)
            if speed > Self.towMaxSpeed {
                v.dx *= Self.towMaxSpeed / speed
                v.dy *= Self.towMaxSpeed / speed
            }

            baby.position.x = min(max(baby.position.x + v.dx * step, 0), size.width)
            baby.position.y = min(baby.position.y + v.dy * step, size.height - baby.size.height)
            if baby.position.y <= floorY {
                baby.position.y = floorY
                if v.dy < 0 { v.dy = 0 }
            }

            // Being hauled along: lean into the pull, and only churn the legs when actually moving.
            baby.zRotation = max(-0.3, min(0.3, -v.dx / 900))
            if abs(v.dx) > 12 { baby.facingRight = v.dx > 0 }
            if abs(v.dx) > 24 { baby.startMoving() } else { baby.stopMoving() }
            towVelocity[id] = v

            if baby.position.y > floorY + 1 || speed > 40 { allSettled = false }
            lead = baby.position
            leadWidth = baby.size.width
        }
        if allSettled { endTow() }
    }

    /// Everyone is back on the floor: hand them over to their normal pottering, standing where
    /// they landed rather than snapping back to some old spot.
    private func endTow() {
        for id in towLine {
            guard let baby = babies[id] else { continue }
            baby.position.y = floorY
            baby.zPosition = 0
            baby.stopMoving()
            baby.run(.rotate(toAngle: 0, duration: 0.18, shortestUnitArc: true))
            if let parentId = babyParent[id], let parent = byId[parentId] {
                let offset = baby.position.x - parent.position.x
                let reach = babyReach(of: parent)
                babyRoam[id] = (abs(offset) <= reach ? offset : randomBabyOffset(near: parent),
                                sceneTime + .random(in: Self.babyDawdle))
            }
        }
        towLine = []
        towVelocity = [:]
        towLeader = nil
        towReleased = false
    }

    private func followParents(dt: TimeInterval) {
        for (babyId, baby) in babies where !towLine.contains(babyId) {
            guard let parentId = babyParent[babyId], let parent = byId[parentId] else { continue }

            // Anyone still hanging in the air after a carry sinks back down to the floor.
            if baby.position.y > floorY {
                baby.position.y = max(floorY, baby.position.y - 260 * CGFloat(dt))
            }

            var roam = babyRoam[babyId] ?? (randomBabyOffset(near: parent), 0)
            let targetX = clampX(parent.position.x + roam.offset, for: baby)
            let dx = targetX - baby.position.x

            // Off the leash — the parent dashed away, or a drop left it stranded. The further
            // behind it is, the faster it scurries, so it never trails off across the screen.
            let stray = abs(baby.position.x - parent.position.x) - babyReach(of: parent)
            let step = stray > 0
                ? Self.babyStep + min(stray * 0.25, Self.babyCatchUpStep)
                : Self.babyStep

            if abs(dx) > 1 {
                // Still walking there — legs only churn while it is actually going somewhere.
                baby.facingRight = dx > 0
                baby.position.x += max(-step, min(step, dx * 0.15))
                baby.startMoving()
            } else if roam.until == 0 {
                // Just arrived — stand around for a moment before choosing somewhere new.
                baby.stopMoving()
                roam.until = sceneTime + TimeInterval.random(in: Self.babyDawdle)
            } else if sceneTime >= roam.until {
                roam = (randomBabyOffset(near: parent), 0)
            }
            babyRoam[babyId] = roam
        }
    }

    /// Neighbouring crabs get their name tags stacked at different heights so they stay readable.
    private func layoutTags() {
        var placed: [(x: CGFloat, width: CGFloat, lift: CGFloat, height: CGFloat)] = []
        for crab in crabs.sorted(by: { $0.position.x < $1.position.x }) {
            guard crab.tagWidth > 0 else { continue }        // untitled crab: no tag to stack
            let near = placed.filter { abs($0.x - crab.position.x) < ($0.width + crab.tagWidth) / 2 + 6 }
            // Hop up over any close neighbour's tag in the way (tags can be one or two lines tall).
            var lift: CGFloat = 0
            for _ in 0..<3 {
                let inTheWay = near.filter { $0.lift < lift + crab.tagHeight && lift < $0.lift + $0.height }
                guard let top = inTheWay.map({ $0.lift + $0.height }).max() else { break }
                lift = top
            }
            crab.tagLift = lift
            placed.append((crab.position.x, crab.tagWidth, lift, crab.tagHeight))
        }
    }

    /// 30 fps (the pets' own frame rate) while any crab is awake; 15 fps once everyone is asleep.
    private func adaptFrameRate() {
        guard let view else { return }
        let awake = isDragging || !leaving.isEmpty || !babies.isEmpty || sceneTime < boostUntil
            || crabs.contains { $0.currentStatus != .dormant }
        let fps = awake ? 30 : 15
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
    }

    // MARK: - Placement

    private func walkOff(_ crab: CrabNode, id: String) {
        // The going-away pet walks itself out of frame; afterwards the node fades and is removed.
        crab.showLeaving { [weak self, weak crab] in
            guard let crab else { self?.leaving.remove(id); return }
            crab.run(.sequence([.fadeOut(withDuration: 0.2), .removeFromParent(),
                                .run { [weak self] in self?.leaving.remove(id) }]))
        }
        if !PetLibrary.isAvailable || crab.isBaby {
            let exitX: CGFloat = crab.position.x < size.width / 2 ? -crab.size.width : size.width + crab.size.width
            crab.facingRight = exitX > crab.position.x
            crab.run(.move(to: CGPoint(x: exitX, y: floorY),
                           duration: TimeInterval(abs(exitX - crab.position.x) / 220)), withKey: "exit")
        }
    }

    /// A free spot on a side, near whoever is already there (or on their way there). New crabs
    /// are born on one, and a crab switching sides runs to one.
    private func landingX(in home: ClosedRange<CGFloat>, for crab: CrabNode?) -> CGFloat {
        let others = crabs.filter { $0 !== crab }.map { restingX(of: $0) }
        let mates = others.filter { home.contains($0) }
        let center = mates.isEmpty ? (home.lowerBound + home.upperBound) / 2
            : mates.reduce(0, +) / CGFloat(mates.count)
        let inset = min(26, (home.upperBound - home.lowerBound) / 2)
        let spot = outwardX(in: home, inset: inset)
        let wish = mates.isEmpty ? spot : (center + spot) / 2
        return freeSpot(near: wish, in: home, for: crab)
    }

    /// Keep x inside the wallpaper gap it is in (or the nearest one).
    private func clampX(_ x: CGFloat, for crab: CrabNode) -> CGFloat {
        let half = crab.size.width / 2 + 8
        let r = range(containing: x)
        return min(max(x, r.lowerBound + half), r.upperBound - half)
    }

    /// While dragging, the whole floor is fair game (so you can carry a pet across the Dock).
    private func clamp(_ p: CGPoint, for crab: CrabNode) -> CGPoint {
        let half = crab.size.width / 2
        return CGPoint(x: min(max(p.x, half), size.width - half),
                       y: min(max(p.y, floorY), size.height - crab.size.height))
    }

    /// Spread everyone out evenly on their own side and forget any "stay here" holds.
    func resetCrabs() {
        let s = sides
        let groups: [(ClosedRange<CGFloat>, [CrabNode])] = [
            (s.working, crabs.filter { $0.currentStatus.isWorkingSide }),
            (s.done, crabs.filter { !$0.currentStatus.isWorkingSide }),
        ]
        for (r, bucket) in groups {
            let inset: CGFloat = 40
            let lo = r.lowerBound + inset, hi = r.upperBound - inset
            let step = bucket.count > 1 ? (hi - lo) / CGFloat(bucket.count - 1) : 0
            for (i, crab) in bucket.enumerated() {
                crab.removeAction(forKey: "settle")
                crab.finishDash()
                crab.wanderTarget = nil
                crab.stopMoving()
                crab.holdUntil = 0
                crab.nextWanderAt = sceneTime + 2
                crab.position = CGPoint(x: bucket.count == 1 ? (lo + hi) / 2 : lo + CGFloat(i) * step, y: floorY)
            }
        }
    }

    // MARK: - Hover

    /// The crab the cursor is on (nil when it is not on one). Its bubble pops after a short rest.
    func setHovered(_ crab: CrabNode?, at point: CGPoint?) {
        hoverPoint = point ?? CGPoint(x: -1000, y: -1000)
        guard crab !== hovered else { return }
        hovered?.hideBubble()
        removeAction(forKey: "hover")
        hovered = crab
        guard let crab else { return }
        boostUntil = sceneTime + 1
        run(.sequence([.wait(forDuration: Self.hoverDelay), .run { [weak crab] in crab?.showBubble() }]),
            withKey: "hover")
    }

    /// A hovered crab can walk out from under a resting cursor; drop its bubble when it does.
    private func hoverCheck() {
        guard let h = hovered, crab(at: hoverPoint) !== h else { return }
        setHovered(nil, at: nil)
    }

    // MARK: - Dragging

    /// Movement under this (in points) still counts as a click, not a drag.
    static let clickSlop: CGFloat = 4

    func crab(at point: CGPoint, slop: CGFloat = 6) -> CrabNode? {
        crabs.last { $0.bodyFrame.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        guard let crab = crab(at: p) else { return }
        dragged = crab
        pressStart = p
        didDrag = false
        setHovered(nil, at: nil)
        lastDragX = p.x
        crab.zPosition = 10
        // Just holding the mouse down is not picking the crab up: it keeps doing whatever it was
        // doing. The carry pose starts in mouseDragged, once you actually move.
    }

    override func mouseDragged(with event: NSEvent) {
        guard let crab = dragged else { return }
        let p = event.location(in: self)
        // A few points of wobble is still a click; past that you are carrying the crab, and
        // letting go must not yank you into the chat.
        if hypot(p.x - pressStart.x, p.y - pressStart.y) <= Self.clickSlop { return }
        if !didDrag {
            // First real movement: now it is in your hand. Grab it from wherever it has got to
            // (it may have kept walking while you held the button down).
            didDrag = true
            dragOffset = CGPoint(x: crab.position.x - p.x, y: crab.position.y - p.y)
            if !needsTallWindow {
                needsTallWindow = true
                onNeedsTallWindow?(true)
            }
            crab.removeAction(forKey: "settle")
            crab.showDragging()
            beginTow(for: crab)
        }
        if abs(p.x - lastDragX) > 1 { crab.facingRight = p.x >= lastDragX; lastDragX = p.x }
        crab.position = clamp(CGPoint(x: p.x + dragOffset.x, y: p.y + dragOffset.y), for: crab)
    }

    override func mouseUp(with event: NSEvent) {
        guard let crab = dragged else { return }
        dragged = nil
        crab.zPosition = 0

        // Pressed and let go without moving = a click: go to that chat and leave the crab alone —
        // it was never picked up, so there is nothing to restore or drop.
        guard didDrag else {
            // Taking you to the chat is also proof you have now seen it, so the store hears about it.
            if let target = crab.openTarget, SessionOpener.open(target), let id = crab.openSessionId {
                onOpened?(id)
            }
            return
        }

        // The babies keep chasing while the crab drops and walks off, then land and settle.
        if towLeader === crab { towReleased = true }
        crab.holdUntil = sceneTime + Self.holdAfterDrag
        crab.nextWanderAt = crab.holdUntil
        crab.restoreStatus()

        // However you let go, the crab drops straight down — never a sideways fly-off.
        let dropX = crab.position.x
        let height = max(crab.position.y - floorY, 0)
        // Free-fall timing: t = sqrt(2h / g), so a drop from the top of the screen takes about a second.
        let fall = SKAction.move(to: CGPoint(x: dropX, y: floorY),
                                 duration: TimeInterval(max(0.1, sqrt(2 * height / Self.towGravity))))
        fall.timingMode = .easeIn

        // Landed on the Dock or off the edge? Once it touches down it walks back to a spot it may
        // stand on — always on its own side (working left, everyone else right), picked at random
        // but leaning toward the outer edge.
        guard clampX(dropX, for: crab) != dropX else {
            crab.run(fall, withKey: "settle")
            return
        }
        let home = side(for: crab.currentStatus)
        let half = crab.size.width / 2 + 8
        let target = freeSpot(near: outwardX(in: home, inset: half), in: home, for: crab)
        crab.run(.sequence([fall, .run { [weak self, weak crab] in
            guard let self, let crab else { return }
            self.dash(crab, to: target, speed: Self.walkHomeSpeed)
        }]), withKey: "settle")
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        for crab in crabs { crab.position = clamp(crab.position, for: crab) }
    }
}
