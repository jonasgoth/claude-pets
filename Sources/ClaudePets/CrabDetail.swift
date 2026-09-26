import Foundation

/// What the hover bubble says about a session beyond its status: where it lives, which tool it
/// has in hand, and when its current state began. Built by SessionStore, read by CrabNode.
struct CrabDetail: Equatable {
    /// Project folder name, e.g. "claude-pets".
    var project = ""
    /// Where the session runs: "Terminal", "Claude app" or "Cowork".
    var source = ""
    /// The tool running or waiting for approval, in its own spelling ("Bash", "Edit").
    /// Nil while Claude is thinking or the turn is over.
    var tool: String?
    /// Epoch seconds when the current state began: the turn started, the tool asked for approval,
    /// or the turn ended. 0 when unknown.
    var since: Double = 0
    /// Auto / accept-edits / bypass permission mode: it will not stop to ask.
    var autoMode = false
    /// Background shell jobs still running. They hold the turn open but get no crab of their own,
    /// so the bubble is the only place you can see them.
    var jobs = 0

    /// The bubble's lines, top to bottom. Empty lines are left out.
    func lines(status: CrabStatus, helpers: Int, now: Double) -> [String] {
        var place: [String] = []
        if !project.isEmpty { place.append(project) }
        if !source.isEmpty { place.append(source) }
        if autoMode { place.append("auto") }
        if helpers > 0 { place.append(helpers == 1 ? "1 helper" : "\(helpers) helpers") }
        if jobs > 0 { place.append(jobs == 1 ? "1 job" : "\(jobs) jobs") }
        return [headline(status: status), timing(status: status, now: now), place.joined(separator: " · ")]
            .filter { !$0.isEmpty }
    }

    /// The words Claude Code spins through in the terminal while it thinks. Mostly silly on
    /// purpose — that is the joke upstream, and the bubble borrows it.
    static let thinkingWords = ["Pondering", "Noodling", "Booping", "Frolicking", "Honking",
                                "Schlepping", "Smooshing", "Wibbling", "Percolating", "Simmering"]

    /// One word per turn, picked from the turn's start time and the project name. Deterministic,
    /// so the bubble does not reshuffle every second it refreshes — but a new turn gets a new word.
    var thinkingWord: String {
        var h: UInt64 = 5381
        for b in project.utf8 { h = (h &* 33) &+ UInt64(b) }
        h = (h &* 33) &+ UInt64(max(since, 0))
        return Self.thinkingWords[Int(h % UInt64(Self.thinkingWords.count))]
    }

    private func headline(status: CrabStatus) -> String {
        switch status {
        case .working, .usingTool: return tool.map { "Running \($0)" } ?? "\(thinkingWord)…"
        case .needsPermission:     return tool.map { "Wants to run \($0)" } ?? "Waiting for your OK"
        case .needsQuestion:       return "Asked you a question"
        case .doneUnseen:          return "Done. Take a look"
        case .doneSeen:            return "Done"
        case .dormant:             return "Napping"
        case .error:               return "Hit an error"
        }
    }

    private func timing(status: CrabStatus, now: Double) -> String {
        guard since > 0 else { return "" }
        let span = Self.span(max(now - since, 0))
        switch status {
        case .working, .usingTool:             return "Busy for \(span)"
        case .needsPermission, .needsQuestion: return "Waiting \(span)"
        case .doneUnseen, .doneSeen:           return "Finished \(span) ago"
        case .error:                           return "Failed \(span) ago"
        case .dormant:                         return "Quiet for \(span)"
        }
    }

    /// "12 s", "3 min", "1 h 12 min".
    static func span(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, rest = m % 60
        return rest == 0 ? "\(h) h" : "\(h) h \(rest) min"
    }

    /// "Bash" stays "Bash"; an MCP tool like "mcp__trello__read_board" becomes "read board".
    static func toolLabel(_ raw: String) -> String {
        guard raw.hasPrefix("mcp__") else { return raw }
        let parts = raw.components(separatedBy: "__")
        guard parts.count >= 3, let last = parts.last, !last.isEmpty else { return raw }
        return last.replacingOccurrences(of: "_", with: " ")
    }
}
