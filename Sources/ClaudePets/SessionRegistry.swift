import Foundation

/// One live Claude process, read from ~/.claude/sessions/<pid>.json.
/// These files exist only while the process is running (CLI and Desktop Code tab).
struct LiveSession: Equatable {
    let sessionId: String
    let pid: Int
    let cwd: String
    let name: String          // registry-derived name, e.g. "claude-pets-21"
    let entrypoint: String     // "cli" or "claude-desktop"
    let startedAt: Double

    /// Last path component of cwd, e.g. "claude-pets". Used for color + fallback label.
    var projectName: String {
        (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent
    }
}

/// Scans the registry directory for currently-running sessions.
enum SessionRegistry {
    static let directory = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")

    /// Every live session, newest pid winning if two share a sessionId. Dead pids are skipped.
    static func scan() -> [LiveSession] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        var byId: [String: LiveSession] = [:]
        for entry in entries where entry.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(entry)
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = obj["sessionId"] as? String,
                  let pid = obj["pid"] as? Int,
                  processIsAlive(pid) else { continue }

            let session = LiveSession(
                sessionId: sessionId,
                pid: pid,
                cwd: obj["cwd"] as? String ?? "",
                name: obj["name"] as? String ?? sessionId,
                entrypoint: obj["entrypoint"] as? String ?? "",
                startedAt: obj["startedAt"] as? Double ?? 0
            )
            // Keep the newest pid for a given session id.
            if let existing = byId[sessionId], existing.pid > pid { continue }
            byId[sessionId] = session
        }
        return Array(byId.values)
    }

    /// True if the process is still running. kill(pid, 0) is the standard liveness probe.
    static func processIsAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
