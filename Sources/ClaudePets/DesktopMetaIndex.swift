import Foundation

/// Reads the Desktop app's per-chat metadata for the Code tab:
/// ~/Library/Application Support/Claude/claude-code-sessions/<acct>/<org>/local_*.json
///
/// The important field is `lastFocusedAt`: the Desktop app updates it when you click into that
/// chat. That is our "you looked at it" signal. Files are re-read only when their mtime changes,
/// so polling stays cheap even with hundreds of old chats on disk.
final class DesktopMetaIndex {
    struct Meta {
        let cliSessionId: String
        let localId: String            // Desktop's own id ("local_…"), used by its unread list
        let title: String?
        let lastFocusedAt: Double      // epoch seconds (file stores ms)
        let lastActivityAt: Double
        let isArchived: Bool
    }

    static var baseDir: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    private var cache: [String: (mtime: Double, meta: Meta?)] = [:]   // by file path
    private var byCliId: [String: Meta] = [:]
    private var lastListing: Double = 0
    private var files: [String] = []

    /// Rescan: relist the folder, re-read only files whose mtime changed. The caller only invokes
    /// this when FSEvents reported a change (or as a slow fallback), so it is rarely called.
    func refresh(now: Double) {
        lastListing = now
        files = Self.listMetadataFiles()
        var changed = false
        for path in files {
            guard let mtime = FileStat.mtime(path) else { continue }
            if let cached = cache[path], cached.mtime == mtime { continue }
            cache[path] = (mtime, Self.parse(path))
            changed = true
        }
        if changed || byCliId.isEmpty {
            var map: [String: Meta] = [:]
            for (_, entry) in cache { if let m = entry.meta { map[m.cliSessionId] = m } }
            byCliId = map
        }
    }

    func meta(for cliSessionId: String) -> Meta? { byCliId[cliSessionId] }

    /// The chat the Desktop app most recently focused (highest lastFocusedAt, not archived).
    var mostRecentlyFocusedId: String? {
        byCliId.values.filter { !$0.isArchived }.max(by: { $0.lastFocusedAt < $1.lastFocusedAt })?.cliSessionId
    }

    private static func parse(_ path: String) -> Meta? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cli = obj["cliSessionId"] as? String else { return nil }
        let localId = (obj["sessionId"] as? String) ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".json", with: "")
        func seconds(_ key: String) -> Double {
            let v = (obj[key] as? Double) ?? (obj[key] as? Int).map(Double.init) ?? 0
            return v > 1e11 ? v / 1000 : v      // ms → s
        }
        return Meta(cliSessionId: cli,
                    localId: localId,
                    title: (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    lastFocusedAt: seconds("lastFocusedAt"),
                    lastActivityAt: seconds("lastActivityAt"),
                    isArchived: obj["isArchived"] as? Bool ?? false)
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
}
