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

    let baseDir: String

    init(baseDir: String) { self.baseDir = baseDir }

    private var cache: [String: (mtime: Double, meta: Meta?)] = [:]   // by file path
    private var byCliId: [String: Meta] = [:]
    private var lastListing: Double = 0
    private var files: [String] = []

    /// Rescan: relist the folder, re-read only files whose mtime changed. The caller only invokes
    /// this when FSEvents reported a change (or as a slow fallback), so it is rarely called.
    func refresh(now: Double) {
        lastListing = now
        files = Self.listMetadataFiles(in: baseDir)
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

    /// The only fields we use. Each file also carries the chat's whole MCP setup (about 1 MB),
    /// and there is one file per chat ever opened: well over a thousand, close to a gigabyte. Fully
    /// parsing them all at launch, and each again whenever Desktop touched it, was the app's worst
    /// cost by far. These six sit in the first couple of KB, so only that much is read and scanned.
    private static let wanted: Set<String> = ["cliSessionId", "sessionId", "title",
                                              "lastFocusedAt", "lastActivityAt", "isArchived"]
    private static let headBytes = 16 * 1024

    private static func parse(_ path: String) -> Meta? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headBytes) else { return nil }
        var obj = TopLevelJSON.fields(in: head, wanted: wanted)
        // Not all six in the head (a field missing from this file, or an unusual key order):
        // scan the whole file instead. Still no full parse.
        if obj == nil, head.count == headBytes,
           let rest = try? handle.readToEnd() {
            obj = TopLevelJSON.fields(in: head + rest, wanted: wanted, complete: true)
        }
        guard let obj, let cli = obj["cliSessionId"] as? String else { return nil }
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

    private static func listMetadataFiles(in baseDir: String) -> [String] {
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

/// Pulls a few top-level fields out of a JSON object without parsing the rest of it. Values it
/// does not want are stepped over byte by byte (strings and nesting only), never decoded; the
/// wanted ones are handed to JSONSerialization on their own.
enum TopLevelJSON {
    /// The wanted fields found. Nil when the text ends before every wanted field turned up,
    /// unless `complete` says this is the whole document: then whatever was found is the answer.
    static func fields(in data: Data, wanted: Set<String>, complete: Bool = false) -> [String: Any]? {
        data.withUnsafeBytes { raw -> [String: Any]? in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var i = 0
            var out: [String: Any] = [:]

            func skipSpace() { while i < n, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 } }
            /// i sits on an opening quote; leaves i just past the closing one. False if cut off.
            func skipString() -> Bool {
                i += 1
                while i < n {
                    switch b[i] {
                    case 0x5C: i += 2                   // backslash: skip the escaped byte
                    case 0x22: i += 1; return true      // closing quote
                    default: i += 1
                    }
                }
                return false
            }
            /// Steps over one value of any kind. False if the text ends inside it.
            func skipValue() -> Bool {
                guard i < n else { return false }
                switch b[i] {
                case 0x22: return skipString()
                case 0x7B, 0x5B:                         // { or [
                    var depth = 0
                    while i < n {
                        switch b[i] {
                        case 0x22: if !skipString() { return false }; continue
                        case 0x7B, 0x5B: depth += 1
                        case 0x7D, 0x5D: depth -= 1; if depth == 0 { i += 1; return true }
                        default: break
                        }
                        i += 1
                    }
                    return false
                default:                                 // number, true, false, null
                    while i < n, b[i] != 0x2C, b[i] != 0x7D, b[i] != 0x5D,
                          b[i] != 0x20, b[i] != 0x0A, b[i] != 0x0D, b[i] != 0x09 { i += 1 }
                    return i < n
                }
            }

            skipSpace()
            guard i < n, b[i] == 0x7B else { return nil }
            i += 1
            while true {
                skipSpace()
                guard i < n else { return complete ? out : nil }
                if b[i] == 0x7D { return out }           // end of object: everything there was
                guard b[i] == 0x22 else { return nil }
                let keyStart = i + 1
                guard skipString() else { return complete ? out : nil }
                let key = String(decoding: UnsafeBufferPointer(rebasing: b[keyStart..<(i - 1)]), as: UTF8.self)
                skipSpace()
                guard i < n, b[i] == 0x3A else { return complete ? out : nil }
                i += 1
                skipSpace()
                let valueStart = i
                guard skipValue() else { return complete ? out : nil }
                if wanted.contains(key) {
                    let slice = Data(UnsafeBufferPointer(rebasing: b[valueStart..<i]))
                    if let v = try? JSONSerialization.jsonObject(with: slice, options: .fragmentsAllowed) { out[key] = v }
                    if out.count == wanted.count { return out }
                }
                skipSpace()
                if i < n, b[i] == 0x2C { i += 1 }
            }
        }
    }
}
