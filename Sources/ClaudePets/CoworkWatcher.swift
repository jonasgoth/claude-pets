import Foundation

/// Cowork sessions run in a sandbox and do NOT appear in ~/.claude/sessions. They live under
/// ~/Library/Application Support/Claude/local-agent-mode-sessions/<acct>/<org>/local_*.json, with
/// a sibling folder holding audit.jsonl. Hooks don't fire for them, so status comes from the audit
/// log. We only show a crab while a session is genuinely active, to avoid ghosts from old runs.
///
/// Cheap by design: the folder listing is refreshed every 5 s, the audit file's mtime is checked
/// (a stat) before anything is parsed, and metadata JSON is cached by mtime.
final class CoworkWatcher {
    struct Session {
        let sessionId: String
        let localId: String          // Desktop's own id ("local_…"), what the claude:// link wants
        let title: String
        let projectName: String
        let status: CrabStatus
        let lastActivity: Double     // audit.jsonl mtime (epoch seconds)
    }

    static let liveWindow: TimeInterval = 300

    static var baseDir: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    }

    private var files: [String] = []
    private var lastListing: Double = 0
    private var metaCache: [String: (mtime: Double, title: String, cliId: String?, archived: Bool)] = [:]

    func scan(now: Double) -> [Session] {
        lastListing = now
        files = Self.listMetadataFiles()
        var out: [Session] = []
        for meta in files {
            // Stat the audit log first; skip everything that isn't fresh.
            let folder = String(meta.dropLast(5))
            let audit = "\(folder)/audit.jsonl"
            guard let auditMtime = FileStat.mtime(audit),
                  now - auditMtime <= Self.liveWindow else { continue }

            guard let m = cachedMeta(meta), !m.archived else { continue }
            let outcome = Self.interpret(tail: Self.tailString(ofPath: audit, maxBytes: 48_000))
            if outcome.ended { continue }
            let localId = ((meta as NSString).lastPathComponent as NSString).deletingPathExtension
            let id = "cowork:" + (m.cliId ?? (meta as NSString).lastPathComponent)
            out.append(Session(sessionId: id, localId: localId, title: m.title, projectName: "cowork-\(m.title)",
                               status: outcome.status, lastActivity: auditMtime))
        }
        return out
    }

    private func cachedMeta(_ path: String) -> (mtime: Double, title: String, cliId: String?, archived: Bool)? {
        let fm = FileManager.default
        guard let mtime = FileStat.mtime(path) else { return nil }
        if let cached = metaCache[path], cached.mtime == mtime { return cached }
        guard let data = fm.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let entry = (mtime: mtime,
                     title: (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Cowork",
                     cliId: obj["cliSessionId"] as? String,
                     archived: obj["isArchived"] as? Bool ?? false)
        metaCache[path] = entry
        return entry
    }

    private static func listMetadataFiles() -> [String] {
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(atPath: baseDir) else { return [] }
        var out: [String] = []
        for account in accounts {
            let accountPath = "\(baseDir)/\(account)"
            guard let orgs = try? fm.contentsOfDirectory(atPath: accountPath) else { continue }
            for org in orgs {
                let orgPath = "\(accountPath)/\(org)"
                guard let entries = try? fm.contentsOfDirectory(atPath: orgPath) else { continue }
                for entry in entries where entry.hasPrefix("local_") && entry.hasSuffix(".json") {
                    out.append("\(orgPath)/\(entry)")
                }
            }
        }
        return out
    }

    /// Read status from the audit tail: pending permission, ended, or working/done.
    private static func interpret(tail: String) -> (status: CrabStatus, ended: Bool) {
        var pendingPermission = false
        var ended = false
        var erroredEnd = false
        var lastWasAssistantText = false

        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "system":
                switch obj["subtype"] as? String {
                case "permission_request": pendingPermission = true
                case "permission_response", "permission_auto_approved": pendingPermission = false
                default: break
                }
                lastWasAssistantText = false
            case "result":
                ended = true
                erroredEnd = (obj["is_error"] as? Bool == true) || (obj["stop_reason"] as? String == "error")
            case "assistant":
                if let message = obj["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    lastWasAssistantText = content.contains { $0["type"] as? String == "text" }
                }
            case "user":
                lastWasAssistantText = false
            default:
                break
            }
        }

        if ended { return (erroredEnd ? .error : .doneUnseen, true) }
        if pendingPermission { return (.needsPermission, false) }
        if lastWasAssistantText { return (.doneUnseen, false) }
        return (.working, false)
    }

    private static func tailString(ofPath path: String, maxBytes: Int) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        var text = String(data: data, encoding: .utf8) ?? ""
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }
}
