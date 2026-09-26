import Foundation

/// Instant status signals from Claude Code hooks. The hooks (installed via HookInstaller) write
/// one small JSON file per session into ~/.claude-pets/events/<sessionId>.json. This reads them.
///
/// Hooks are optional: without them, transcript polling still detects working/done/error. Hooks
/// add instant permission and tool signals, which files alone can only guess at.
enum HookBridge {
    static let eventsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-pets/events")

    struct Event { let state: String; let ts: Double }

    /// Latest hook event per session id.
    static func scan() -> [String: Event] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: eventsDir) else { return [:] }
        var out: [String: Event] = [:]
        for file in files where file.hasSuffix(".json") {
            let sid = String(file.dropLast(5))
            let path = (eventsDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = obj["state"] as? String else { continue }
            let ts = (obj["ts"] as? Double) ?? (obj["ts"] as? Int).map(Double.init) ?? 0
            out[sid] = Event(state: state, ts: ts)
        }
        return out
    }
}
