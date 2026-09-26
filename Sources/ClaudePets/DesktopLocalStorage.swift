import Foundation

/// Reads two facts straight out of the Desktop app's own web storage (a Chromium LevelDB under
/// ~/Library/Application Support/Claude/Local Storage/leveldb):
///
///   - `epitaxy-unread-v1`        → which Code chats carry the sidebar's "unread" dot
///   - `epitaxy.sidePaneStore.v1` → `currentSessionId`, the chat the window is showing (nil on the
///                                   new-chat screen and other non-chat views)
///
/// Both are the Desktop app's ground truth for "did you look at this chat", which the per-chat
/// `lastFocusedAt` files cannot express (nothing is written when you open a new empty chat).
/// The catch: Chromium flushes web storage to disk lazily — usually within 5 s, but up to about a
/// minute when the app writes a lot — so `writtenAt` says how fresh the snapshot is and callers
/// treat it as a correction, never as an instant signal.
///
/// Everything here is tolerant: any unreadable or unexpected file is skipped and `state` stays
/// nil, which makes the store fall back to its older heuristics. Only used from SessionStore's
/// background queue.
final class DesktopLocalStorage {
    struct State {
        var unreadIds: Set<String> = []          // Desktop's own "unread" dot, by local_ id
        var explicitUnreadIds: Set<String> = []  // chats you marked unread on purpose
        var currentSessionId: String?            // chat on screen, nil = new chat / not a chat
        var writtenAt: Double = 0                // mtime of the newest storage file
    }

    static var baseDir: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Claude/Local Storage/leveldb")
    }

    private(set) var state: State?

    private static let unreadKeySuffix = Array("\u{0}\u{1}epitaxy-unread-v1".utf8)
    private static let paneKeySuffix = Array("\u{0}\u{1}epitaxy.sidePaneStore.v1".utf8)

    private struct Entry { let seq: UInt64; let value: [UInt8]? }   // nil value = deleted
    private struct FileCache { let size: UInt64; let mtime: Double; let entries: [Int: Entry] }  // 0 unread, 1 pane
    private var cache: [String: FileCache] = [:]

    /// Re-read whatever changed and rebuild `state`. Cheap when nothing changed.
    func refresh() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.baseDir) else { state = nil; return }
        var newest: Double = 0
        var seen: Set<String> = []
        for name in names where name.hasSuffix(".ldb") || name.hasSuffix(".log") {
            let path = "\(Self.baseDir)/\(name)"
            var st = stat()
            guard stat(path, &st) == 0 else { continue }
            let size = UInt64(st.st_size)
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            newest = max(newest, mtime)
            seen.insert(path)
            if let c = cache[path], c.size == size, c.mtime == mtime { continue }
            guard let bytes = fm.contents(atPath: path).map({ [UInt8]($0) }) else { continue }
            let entries = name.hasSuffix(".ldb") ? Self.parseTable(bytes) : Self.parseLog(bytes)
            cache[path] = FileCache(size: size, mtime: mtime, entries: entries)
        }
        for path in Set(cache.keys).subtracting(seen) { cache[path] = nil }

        var latest: [Int: Entry] = [:]
        for (_, file) in cache {
            for (which, entry) in file.entries where (latest[which]?.seq ?? 0) < entry.seq { latest[which] = entry }
        }
        guard let unread = latest[0]?.value.flatMap(Self.decodeJSON),
              let unreadState = unread["state"] as? [String: Any] else { state = nil; return }
        var s = State()
        s.unreadIds = Set((unreadState["unreadIds"] as? [String]) ?? [])
        s.explicitUnreadIds = Set((unreadState["explicitUnreadIds"] as? [String]) ?? [])
        if let pane = latest[1]?.value.flatMap(Self.decodeJSON), let paneState = pane["state"] as? [String: Any] {
            s.currentSessionId = paneState["currentSessionId"] as? String
        }
        s.writtenAt = newest
        state = s
    }

    // MARK: - Value decoding

    /// Chromium prefixes each stored value with a byte: 0 = UTF-16LE, 1 = Latin-1.
    private static func decodeJSON(_ v: [UInt8]) -> [String: Any]? {
        guard let first = v.first else { return nil }
        let body = Array(v.dropFirst())
        let text: String?
        switch first {
        case 0: text = String(bytes: body, encoding: .utf16LittleEndian)
        case 1: text = String(bytes: body, encoding: .isoLatin1)
        default: text = nil
        }
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func wanted(_ key: ArraySlice<UInt8>) -> Int? {
        guard key.first == UInt8(ascii: "_") else { return nil }
        if key.count > unreadKeySuffix.count, key.suffix(unreadKeySuffix.count).elementsEqual(unreadKeySuffix) { return 0 }
        if key.count > paneKeySuffix.count, key.suffix(paneKeySuffix.count).elementsEqual(paneKeySuffix) { return 1 }
        return nil
    }

    // MARK: - LevelDB write-ahead log (*.log)

    private static func parseLog(_ b: [UInt8]) -> [Int: Entry] {
        var out: [Int: Entry] = [:]
        let blockSize = 32768
        var i = 0
        var fragment: [UInt8] = []
        while i + 7 <= b.count {
            let room = blockSize - (i % blockSize)
            if room < 7 { i += room; continue }                     // trailer padding
            let length = Int(b[i + 4]) | Int(b[i + 5]) << 8
            let type = b[i + 6]
            i += 7
            if type == 0 && length == 0 { break }                   // end of written data
            guard i + length <= b.count else { break }              // record still being written
            let payload = b[i..<(i + length)]
            i += length
            let batch: [UInt8]
            switch type {
            case 1: batch = Array(payload)
            case 2: fragment = Array(payload); continue
            case 3: fragment += payload; continue
            case 4: batch = fragment + payload; fragment = []
            default: continue
            }
            consumeBatch(batch, into: &out)
        }
        return out
    }

    private static func consumeBatch(_ b: [UInt8], into out: inout [Int: Entry]) {
        guard b.count >= 12 else { return }
        let seq = readU64(b, 0)
        let count = Int(readU32(b, 8))
        var i = 12
        for n in 0..<count {
            guard i < b.count else { return }
            let type = b[i]; i += 1
            guard let (klen, k0) = varint(b, i), k0 + klen <= b.count else { return }
            let key = b[k0..<(k0 + klen)]
            i = k0 + klen
            var value: [UInt8]? = nil
            if type == 1 {
                guard let (vlen, v0) = varint(b, i), v0 + vlen <= b.count else { return }
                value = Array(b[v0..<(v0 + vlen)])
                i = v0 + vlen
            }
            if let which = wanted(key) {
                let s = seq + UInt64(n)
                if (out[which]?.seq ?? 0) < s { out[which] = Entry(seq: s, value: value) }
            }
        }
    }

    // MARK: - LevelDB sorted table (*.ldb)

    private static func parseTable(_ b: [UInt8]) -> [Int: Entry] {
        var out: [Int: Entry] = [:]
        let magic: [UInt8] = [0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb]
        guard b.count >= 48, Array(b.suffix(8)) == magic else { return out }
        let footer = b.count - 48
        guard let (_, p1) = varint(b, footer), let (_, p2) = varint(b, p1),        // metaindex handle
              let (indexOffset, p3) = varint(b, p2), let (indexSize, _) = varint(b, p3),
              let index = readBlock(b, offset: indexOffset, size: indexSize) else { return out }
        for (_, handle) in blockEntries(index) {
            guard let (off, q) = varint(handle, 0), let (size, _) = varint(handle, q),
                  let block = readBlock(b, offset: off, size: size) else { continue }
            for (ikey, value) in blockEntries(block) {
                guard ikey.count >= 8 else { continue }
                let userKey = ikey[ikey.startIndex..<(ikey.endIndex - 8)]
                guard let which = wanted(userKey) else { continue }
                let tag = readU64(Array(ikey.suffix(8)), 0)
                let seq = tag >> 8
                let isValue = (tag & 0xff) == 1
                if (out[which]?.seq ?? 0) < seq { out[which] = Entry(seq: seq, value: isValue ? Array(value) : nil) }
            }
        }
        return out
    }

    /// A block is `data + 1 byte compression type + 4 byte crc`. Type 1 = Snappy.
    private static func readBlock(_ b: [UInt8], offset: Int, size: Int) -> [UInt8]? {
        guard offset >= 0, size >= 0, offset + size + 5 <= b.count else { return nil }
        let data = Array(b[offset..<(offset + size)])
        switch b[offset + size] {
        case 0: return data
        case 1: return snappyDecode(data)
        default: return nil
        }
    }

    /// Entries of one block: prefix-compressed keys, restart array at the end.
    private static func blockEntries(_ blk: [UInt8]) -> [(ArraySlice<UInt8>, [UInt8])] {
        var out: [(ArraySlice<UInt8>, [UInt8])] = []
        guard blk.count >= 4 else { return out }
        let restarts = Int(readU32(blk, blk.count - 4))
        let end = blk.count - 4 - 4 * restarts
        guard end >= 0 else { return out }
        var i = 0
        var key: [UInt8] = []
        while i < end {
            guard let (shared, a) = varint(blk, i), let (nonShared, c) = varint(blk, a),
                  let (valueLen, d) = varint(blk, c),
                  shared <= key.count, d + nonShared + valueLen <= blk.count else { break }
            key = Array(key.prefix(shared)) + blk[d..<(d + nonShared)]
            let value = Array(blk[(d + nonShared)..<(d + nonShared + valueLen)])
            out.append((key[...], value))
            i = d + nonShared + valueLen
        }
        return out
    }

    // MARK: - Snappy (raw format, as used inside LevelDB blocks)

    static func snappyDecode(_ src: [UInt8]) -> [UInt8]? {
        guard let (expected, start) = varint(src, 0) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(expected)
        var i = start
        func copyBack(_ offset: Int, _ length: Int) -> Bool {
            guard offset > 0, offset <= out.count else { return false }
            for _ in 0..<length { out.append(out[out.count - offset]) }
            return true
        }
        while i < src.count {
            let tag = src[i]; i += 1
            switch tag & 3 {
            case 0:
                var length = Int(tag >> 2) + 1
                if length > 60 {
                    let extra = length - 60
                    guard i + extra <= src.count else { return nil }
                    var v = 0
                    for k in 0..<extra { v |= Int(src[i + k]) << (8 * k) }
                    length = v + 1
                    i += extra
                }
                guard i + length <= src.count else { return nil }
                out.append(contentsOf: src[i..<(i + length)])
                i += length
            case 1:
                guard i < src.count else { return nil }
                let length = Int((tag >> 2) & 7) + 4
                let offset = (Int(tag >> 5) << 8) | Int(src[i]); i += 1
                guard copyBack(offset, length) else { return nil }
            case 2:
                guard i + 2 <= src.count else { return nil }
                let length = Int(tag >> 2) + 1
                let offset = Int(src[i]) | Int(src[i + 1]) << 8; i += 2
                guard copyBack(offset, length) else { return nil }
            default:
                guard i + 4 <= src.count else { return nil }
                let length = Int(tag >> 2) + 1
                let offset = Int(readU32(src, i)); i += 4
                guard copyBack(offset, length) else { return nil }
            }
        }
        return out.count == expected ? out : nil
    }

    // MARK: - Little helpers

    /// Unsigned LEB128, capped so a corrupt file can never yield a negative length.
    private static func varint(_ b: [UInt8], _ start: Int) -> (Int, Int)? {
        var result = 0, shift = 0, i = start
        while i < b.count, shift <= 56 {
            let c = b[i]; i += 1
            result |= Int(c & 0x7f) << shift
            if c < 0x80 { return result >= 0 ? (result, i) : nil }
            shift += 7
        }
        return nil
    }

    private static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static func readU64(_ b: [UInt8], _ i: Int) -> UInt64 {
        guard i + 8 <= b.count else { return 0 }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
        return v
    }
}
