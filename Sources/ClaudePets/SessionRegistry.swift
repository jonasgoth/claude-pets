import Foundation

/// One live Claude process, read from <profile config>/sessions/<pid>.json (~/.claude for the
/// normal app, Claude-<Name>/claude-config for an extra profile).
/// These files exist only while the process is running (CLI and Desktop Code tab).
struct LiveSession: Equatable {
    let sessionId: String
    let pid: Int
    let cwd: String
    let name: String          // registry-derived name, e.g. "claude-pets-21"
    let entrypoint: String     // "cli" or "claude-desktop"
    let startedAt: Double
    let profile: ClaudeProfile  // which Claude app (and folders) this session belongs to

    /// Last path component of cwd, e.g. "claude-pets". Used for color + fallback label.
    var projectName: String {
        (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent
    }
}

/// Scans the registry directory for currently-running sessions.
enum SessionRegistry {
    /// Every live session across all profiles, newest pid winning if two share a sessionId.
    /// Dead pids are skipped.
    static func scan(profiles: [ClaudeProfile]) -> [LiveSession] {
        let fm = FileManager.default
        var byId: [String: LiveSession] = [:]
        var seenPaths: Set<String> = []
        defer { cache = cache.filter { seenPaths.contains($0.key) } }
        for profile in profiles {
        let directory = profile.sessionsDir
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
        for entry in entries where entry.hasSuffix(".json") {
            let path = (directory as NSString).appendingPathComponent(entry)
            seenPaths.insert(path)
            guard let mtime = FileStat.mtime(path) else { continue }
            let parsed: LiveSession?
            if let c = cache[path], c.mtime == mtime, c.session.map({ $0.profile == profile }) ?? true {
                parsed = c.session
            } else {
                parsed = read(path, profile: profile)
                cache[path] = Cached(mtime: mtime, session: parsed)
            }
            guard let session = parsed, processIsAlive(session.pid) else { continue }
            let sessionId = session.sessionId, pid = session.pid
            // Keep the newest pid for a given session id.
            if let existing = byId[sessionId], existing.pid > pid { continue }
            byId[sessionId] = session
        }
        }
        return Array(byId.values)
    }

    /// Each registry file's last parse, reused while its modification time stays the same: the
    /// files are written once when a session starts, so re-reading every one every second was
    /// pure waste. Only touched from SessionStore's background queue.
    private struct Cached { let mtime: Double; let session: LiveSession? }
    private static var cache: [String: Cached] = [:]

    private static func read(_ path: String, profile: ClaudeProfile) -> LiveSession? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = obj["sessionId"] as? String,
              let pid = obj["pid"] as? Int else { return nil }
        return LiveSession(
            sessionId: sessionId,
            pid: pid,
            cwd: obj["cwd"] as? String ?? "",
            name: obj["name"] as? String ?? sessionId,
            entrypoint: obj["entrypoint"] as? String ?? "",
            startedAt: obj["startedAt"] as? Double ?? 0,
            profile: profile
        )
    }

    /// True if the process is still running. kill(pid, 0) is the standard liveness probe.
    static func processIsAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
