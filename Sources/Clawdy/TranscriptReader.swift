import Foundation

/// A read of a session's JSONL transcript. Incremental: full file on first sight, then only the
/// bytes appended since last time. Only ever touched from SessionStore's background queue.
final class TranscriptReader {
    let sessionId: String
    private(set) var path: String?
    private var offset: UInt64 = 0
    private var leftover = ""

    // Signals folded from the record stream.
    private(set) var idle = false                 // last turn ended (real end_turn with text)
    private(set) var idleSince: Double = 0        // epoch seconds of that end_turn (the "doneAt")
    private(set) var title: String?
    private(set) var lastEventTime: Double = 0
    private(set) var errored = false              // api_error not yet superseded by a new turn
    private(set) var endedWithQuestion = false    // a question tool is parked, waiting on you
    private(set) var lastToolName = ""
    private(set) var lastToolLabel = ""            // the same tool in its own spelling ("Bash")
    private(set) var toolUnanswered = false        // a tool_use with no matching tool_result yet
    private(set) var lastToolUseTime: Double = 0
    private(set) var permissionModeIsAuto = false  // "auto"/"bypassPermissions"/"acceptEdits"
    private(set) var turnStartedAt: Double = 0     // epoch seconds of the prompt that began the current turn
    private(set) var lastPromptTime: Double = 0    // epoch seconds of the last message you sent (see isHumanPrompt)

    /// A shell started with `run_in_background`: where its output goes, and when it started.
    struct BackgroundShell { let outputPath: String; let startedAt: Double }
    /// Background shells by id, added when Bash hands one back and removed when its
    /// task-notification lands. Claude ends the turn and waits for that notification, so these
    /// hold the turn open the same way a sub-agent does.
    private(set) var backgroundShells: [String: BackgroundShell] = [:]

    /// Directory holding this session's sub-agent transcripts, once the main file is located.
    var subagentsDirectory: String? {
        guard let path else { return nil }
        let dir = (path as NSString).deletingLastPathComponent
        return "\(dir)/\(sessionId)/subagents"
    }

    /// Background shells that still look alive. One whose output file has been silent too long is
    /// given up on: a killed job never gets its notification, and a server started this way would
    /// otherwise hold the crab at "working" for the rest of the day.
    func activeBackgroundShells(now: Double, staleAfter: TimeInterval = 10 * 60) -> [String] {
        backgroundShells.compactMap { id, shell in
            let last = FileStat.mtime(shell.outputPath) ?? shell.startedAt
            return now - last <= staleAfter ? id : nil
        }
    }

    init(sessionId: String) { self.sessionId = sessionId }

    private func locate() -> String? {
        if let path, FileManager.default.fileExists(atPath: path) { return path }
        let projects = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        guard let slugs = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return nil }
        for slug in slugs {
            let candidate = "\(projects)/\(slug)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: candidate) { path = candidate; return candidate }
        }
        return nil
    }

    func refresh() {
        guard let path = locate(), let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; leftover = "" }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = size
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        let text = leftover + chunk
        leftover = ""
        if let lastNewline = text.lastIndex(of: "\n") {
            let complete = text[..<lastNewline]
            leftover = String(text[text.index(after: lastNewline)...])
            for line in complete.split(separator: "\n", omittingEmptySubsequences: true) { consume(String(line)) }
        } else {
            leftover = text
        }
    }

    private func consume(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        var recordTime: Double = 0
        if let ts = obj["timestamp"] as? String, let epoch = Self.epoch(ts) {
            recordTime = epoch
            lastEventTime = max(lastEventTime, epoch)
        }

        // Bash's background jobs live outside the turn: the tool result hands back an id, and the
        // session only hears about the job again through a task-notification.
        if type == "user" || type == "queue-operation" { noteBackgroundShells(line) }

        switch type {
        case "custom-title":
            if let t = obj["customTitle"] as? String, !t.isEmpty { title = t }
        case "ai-title":
            if let t = obj["aiTitle"] as? String, !t.isEmpty, title == nil { title = t }
        case "user":
            if isHumanPrompt(obj) { lastPromptTime = max(lastPromptTime, recordTime > 0 ? recordTime : lastEventTime) }
            // You pressed stop. The turn ends right there and nothing else is coming until you
            // type again — without this the crab keeps "working" (or begging for a permission that
            // will never be answered) until it finally goes dormant.
            if isInterrupt(obj) {
                idle = true
                idleSince = recordTime > 0 ? recordTime : lastEventTime
                toolUnanswered = false
                endedWithQuestion = false
                errored = false
                return
            }
            // A new prompt or a returned tool result: Claude has more to do. Only a prompt that
            // follows a finished turn starts a new one (Desktop slips other user records in mid-turn).
            if !isToolResult(obj), idle || turnStartedAt == 0 {
                turnStartedAt = recordTime > 0 ? recordTime : lastEventTime
            }
            idle = false
            idleSince = 0
            errored = false
            endedWithQuestion = false
            if let mode = obj["permissionMode"] as? String { setPermissionMode(mode) }
            if isToolResult(obj) { toolUnanswered = false }
        case "assistant":
            guard let message = obj["message"] as? [String: Any] else { return }
            let stop = message["stop_reason"] as? String
            let content = message["content"] as? [[String: Any]] ?? []
            let blockTypes = Set(content.compactMap { $0["type"] as? String })

            if let tool = content.last(where: { $0["type"] as? String == "tool_use" }),
               let name = tool["name"] as? String {
                lastToolName = name.lowercased()
                lastToolLabel = name
                toolUnanswered = true
                lastToolUseTime = lastEventTime
                // Desktop's own sidebar calls a chat "awaiting input" for exactly three things:
                // AskUserQuestion, ExitPlanMode, and a pending tool permission. Match that, and only that.
                if name == "AskUserQuestion" || name == "ExitPlanMode" { endedWithQuestion = true }
            }

            if stop == "tool_use" {
                idle = false
                idleSince = 0
            } else if stop == "end_turn" {
                // A thinking-only end_turn is an intermediate extended-thinking event, not the real
                // end of a turn — ignore it so the crab doesn't flip to idle mid-thought.
                let realEnd = blockTypes.contains("text") || !blockTypes.isSubset(of: ["thinking"])
                if realEnd {
                    idle = true
                    idleSince = recordTime > 0 ? recordTime : lastEventTime
                }
            }
        case "system":
            if obj["subtype"] as? String == "api_error" {
                errored = true
                if !idle { idle = true; idleSince = recordTime > 0 ? recordTime : lastEventTime }
            }
        default:
            break
        }
    }

    private func noteBackgroundShells(_ line: String) {
        if line.contains("<task-id>") {
            let range = NSRange(line.startIndex..., in: line)
            for m in Self.taskIdPattern.matches(in: line, range: range) {
                if let r = Range(m.range(at: 1), in: line) { backgroundShells[String(line[r])] = nil }
            }
        }
        guard line.contains("Command running in background with ID:") else { return }
        let range = NSRange(line.startIndex..., in: line)
        for m in Self.backgroundStartPattern.matches(in: line, range: range) {
            guard let idRange = Range(m.range(at: 1), in: line),
                  let pathRange = Range(m.range(at: 2), in: line) else { continue }
            backgroundShells[String(line[idRange])] = BackgroundShell(outputPath: String(line[pathRange]),
                                                                     startedAt: lastEventTime)
        }
    }

    /// "Command running in background with ID: b8zb4io6g. Output is being written to: /…/b8zb4io6g.output."
    private static let backgroundStartPattern = try! NSRegularExpression(
        pattern: "Command running in background with ID: ([A-Za-z0-9_-]+)\\. Output is being written to: (\\S+\\.output)")
    /// The id inside a <task-notification>, which is how a background job says it is done.
    private static let taskIdPattern = try! NSRegularExpression(pattern: "<task-id>([A-Za-z0-9_-]+)</task-id>")

    private func setPermissionMode(_ mode: String) {
        permissionModeIsAuto = ["auto", "bypassPermissions", "acceptEdits", "plan"].contains(mode)
    }

    /// The record Claude writes when you interrupt a turn: a user message whose only text is
    /// "[Request interrupted by user]" (or "...by user for tool use]" when a tool was in hand).
    private func isInterrupt(_ obj: [String: Any]) -> Bool {
        guard let message = obj["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String { return Self.isInterruptText(text) }
        guard let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains {
            ($0["type"] as? String) == "text" && Self.isInterruptText($0["text"] as? String ?? "")
        }
    }

    private static func isInterruptText(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[Request interrupted by user")
    }

    /// A user record that you sent: a prompt, a slash command, pressing stop. Not a tool result, not
    /// text the app slips in alongside a prompt (isMeta), and not a background job's
    /// task-notification — that arrives as a user record too, and can land at 4 am with nobody there.
    private func isHumanPrompt(_ obj: [String: Any]) -> Bool {
        if obj["isMeta"] as? Bool == true || isToolResult(obj) { return false }
        // Newer records say who sent them ({"kind": "human"}); interrupts and older records don't.
        if let origin = obj["origin"] as? [String: Any] { return origin["kind"] as? String == "human" }
        let message = obj["message"] as? [String: Any]
        let text = message?["content"] as? String
            ?? (message?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return !text.hasPrefix("<task-notification>")
    }

    private func isToolResult(_ obj: [String: Any]) -> Bool {
        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            return content.contains { $0["type"] as? String == "tool_result" }
        }
        return false
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private static func epoch(_ iso: String) -> Double? {
        if let d = formatter.date(from: iso) { return d.timeIntervalSince1970 }
        return ISO8601DateFormatter().date(from: iso)?.timeIntervalSince1970
    }
}
