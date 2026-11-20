import Foundation

/// Instant status signals from Claude Code hooks. The hooks (installed via HookInstaller) write
/// one small JSON file per session into ~/.claude-pets/events/<sessionId>.json. This reads them.
///
/// Hooks are optional: without them, transcript polling still detects working/done/error. Hooks
/// add instant permission and tool signals, which files alone can only guess at.
///
/// Only touched from SessionStore's background queue.
enum HookBridge {
    static let eventsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-pets/events")

    struct Event { let state: String; let ts: Double }

    /// Each session's last read, kept while its file's modification time stays the same. The
    /// folder collects a file for every session that ever ran (hundreds), and reading and parsing
    /// all of them every second was the app's biggest steady cost. Now it is one stat per live
    /// session, and a read only when a hook has actually fired.
    private struct Cached { let mtime: Double; let event: Event? }
    private static var cache: [String: Cached] = [:]

    /// Event files untouched this long belong to sessions long gone: `resolve` ignores any event
    /// older than the transcript anyway, so they are deleted to keep the folder small.
    static let pruneAfter: TimeInterval = 2 * 24 * 3600
    private static var lastPrune: Double = 0

    /// Latest hook event for each of these session ids (the live ones).
    static func events(for ids: [String], now: Double) -> [String: Event] {
        if now - lastPrune > 3600 { prune(now: now) }
        var out: [String: Event] = [:]
        var fresh: [String: Cached] = [:]
        for sid in ids {
            let path = (eventsDir as NSString).appendingPathComponent(sid + ".json")
            guard let mtime = FileStat.mtime(path) else { continue }
            let entry: Cached
            if let c = cache[sid], c.mtime == mtime { entry = c } else { entry = Cached(mtime: mtime, event: read(path)) }
            fresh[sid] = entry
            if let e = entry.event { out[sid] = e }
        }
        cache = fresh          // sessions that ended drop out of the cache with them
        return out
    }

    private static func read(_ path: String) -> Event? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = obj["state"] as? String else { return nil }
        let ts = (obj["ts"] as? Double) ?? (obj["ts"] as? Int).map(Double.init) ?? 0
        return Event(state: state, ts: ts)
    }

    private static func prune(now: Double) {
        lastPrune = now
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: eventsDir) else { return }
        for file in files where file.hasSuffix(".json") {
            let path = (eventsDir as NSString).appendingPathComponent(file)
            if let mtime = FileStat.mtime(path), now - mtime > pruneAfter {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
