import Foundation

/// Finds a session's currently-running sub-agents. Each sub-agent has its own transcript at
/// <session>/subagents/agent-*.jsonl. One counts as running until its transcript ends with a
/// finished turn (a text reply that did not stop to call a tool).
///
/// Modification time alone is not enough: a sub-agent in the middle of a long API call or a slow
/// tool writes nothing for a minute, and would look finished. A killed sub-agent never writes its
/// end_turn, so a hard cap on silence stops it counting as running forever.
enum SubagentWatcher {
    static let staleAfter: TimeInterval = 10 * 60   // seconds of silence after which we give up on it

    private struct Cached { let size: UInt64; let mtime: Double; let finished: Bool }
    /// Per-file verdicts keyed by path, reused while the file has not changed. Only touched from
    /// SessionStore's background queue.
    private static var cache: [String: Cached] = [:]

    static func activeAgents(in directory: String, now: Double) -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var out: [String] = []
        for file in files where file.hasPrefix("agent-") && file.hasSuffix(".jsonl") {
            let path = (directory as NSString).appendingPathComponent(file)
            guard let modified = FileStat.mtime(path), now - modified <= staleAfter else { continue }
            if !hasFinished(path: path, mtime: modified) {
                out.append(String(file.dropLast(6)))   // strip ".jsonl"
            }
        }
        return out
    }

    /// True once the transcript's last record is a finished assistant turn.
    private static func hasFinished(path: String, mtime: Double) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if let c = cache[path], c.size == size, c.mtime == mtime { return c.finished }
        let tailLength: UInt64 = 64 * 1024
        let start = size > tailLength ? size - tailLength : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        let finished = lastRecordIsFinishedTurn(String(decoding: data, as: UTF8.self))
        cache[path] = Cached(size: size, mtime: mtime, finished: finished)
        return finished
    }

    private static func lastRecordIsFinishedTurn(_ tail: String) -> Bool {
        guard let line = tail.split(separator: "\n", omittingEmptySubsequences: true).last,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              message["stop_reason"] as? String != "tool_use" else { return false }
        // Finished sub-agents end on a text reply with end_turn, stop_sequence, or no stop reason
        // at all (older writers); a tool_use, or thinking with nothing said yet, is still going.
        let content = message["content"] as? [[String: Any]] ?? []
        return content.contains { $0["type"] as? String == "text" }
    }
}
