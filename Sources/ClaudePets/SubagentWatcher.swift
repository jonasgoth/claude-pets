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

    /// Each folder's agent files, re-listed only when the folder itself changes (a new sub-agent
    /// adds a file, which bumps the folder's mtime; appends to a file do not, and need not).
    private struct Listing { let mtime: Double; let files: [String] }
    private static var listings: [String: Listing] = [:]

    static func activeAgents(in directory: String, now: Double) -> [String] {
        guard let dirMtime = FileStat.mtime(directory) else { listings[directory] = nil; return [] }
        let files: [String]
        if let l = listings[directory], l.mtime == dirMtime {
            files = l.files
        } else {
            let all = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            files = all.filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
            listings[directory] = Listing(mtime: dirMtime, files: files)
        }
        var out: [String] = []
        for file in files {
            let path = (directory as NSString).appendingPathComponent(file)
            guard let info = FileStat.info(path), now - info.mtime <= staleAfter else { continue }
            if !hasFinished(path: path, mtime: info.mtime, size: info.size) {
                out.append(String(file.dropLast(6)))   // strip ".jsonl"
            }
        }
        return out
    }

    /// True once the transcript's last record is a finished assistant turn. The file is only
    /// opened when it changed since the last look.
    private static func hasFinished(path: String, mtime: Double, size: UInt64) -> Bool {
        if let c = cache[path], c.size == size, c.mtime == mtime { return c.finished }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let tailLength: UInt64 = 64 * 1024
        let start = size > tailLength ? size - tailLength : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.read(upToCount: Int(size - start))) ?? Data()
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
