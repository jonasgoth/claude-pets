import AppKit

/// Everything a crab can be. One value per session, chosen by SessionStore using the plan's
/// priority order: permission > question > error > done-not-seen > working/tool > done-seen > dormant.
enum CrabStatus: Equatable {
    case working            // generating, or a tool is running normally
    case usingTool          // a specific tool is running (shows a tool badge)
    case needsPermission    // waiting for you to approve something
    case needsQuestion      // finished its turn by asking you a question
    case doneUnseen         // finished, and you have not looked yet
    case doneSeen           // finished, and you have looked (badge gone, relaxed)
    case dormant            // no activity for a long time
    case error              // an API error ended the turn

    /// True while the session is actively doing work (legs should march).
    var isBusy: Bool { self == .working || self == .usingTool }

    /// True when the crab wants your attention.
    var needsYou: Bool { self == .needsPermission || self == .needsQuestion }

    /// True for the states the "seen" rule can clear. A question is not one of them: looking at it
    /// does not answer it, so a seen question would wrongly relax into the done-and-seen crab while
    /// it is still waiting on you. Only answering clears it (the tool_result lands in the transcript).
    var isUnseenFinish: Bool { self == .doneUnseen || self == .error }

    /// Which side of the floor the crab lives on. Left is the working side: Claude is busy, or is
    /// paused mid-task waiting on you — a permission or a question, which block the same way and
    /// belong together. Right is the done side: the turn is over (finished, errored, or dormant).
    var isWorkingSide: Bool { self == .working || self == .usingTool || needsYou }
}

/// How to draw the badge for a status: SF Symbol name + circle color. Nil = no badge.
struct BadgeStyle {
    let symbol: String
    let color: NSColor

    static func forStatus(_ status: CrabStatus) -> BadgeStyle? {
        switch status {
        case .needsPermission: return BadgeStyle(symbol: "exclamationmark", color: Palette.bad)
        case .needsQuestion:   return BadgeStyle(symbol: "questionmark", color: Palette.ask)
        case .error:           return BadgeStyle(symbol: "xmark", color: Palette.bad)
        case .doneUnseen:      return BadgeStyle(symbol: "checkmark", color: Palette.ok)
        case .usingTool:       return BadgeStyle(symbol: "wrench.and.screwdriver.fill", color: Palette.tool)
        case .dormant:         return BadgeStyle(symbol: "zzz", color: Palette.sleep)
        case .working, .doneSeen: return nil
        }
    }

    enum Palette {
        static let ok = NSColor(srgbRed: 0.18, green: 0.62, blue: 0.36, alpha: 1)
        static let bad = NSColor(srgbRed: 0.85, green: 0.27, blue: 0.25, alpha: 1)
        static let ask = NSColor(srgbRed: 0.85, green: 0.60, blue: 0.17, alpha: 1)
        static let tool = NSColor(srgbRed: 0.36, green: 0.42, blue: 0.52, alpha: 1)
        static let sleep = NSColor(srgbRed: 0.48, green: 0.52, blue: 0.60, alpha: 1)
    }
}
