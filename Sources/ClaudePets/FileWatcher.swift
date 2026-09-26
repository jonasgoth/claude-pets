import Foundation
import CoreServices

/// Cheap file helpers + an FSEvents watcher, so the pollers only rescan a folder tree when macOS
/// says something inside it changed. Idle cost drops to almost nothing.
enum FileStat {
    /// Modification time in epoch seconds via stat(2) — far cheaper than FileManager's attributes.
    static func mtime(_ path: String) -> Double? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }
}

final class FileWatcher {
    private let roots: [String]
    private let lock = NSLock()
    private var dirty: Set<String>
    private var stream: FSEventStreamRef?

    init(roots: [String]) {
        self.roots = roots
        self.dirty = Set(roots)      // everything is "changed" until the first scan
    }

    func start(queue: DispatchQueue) {
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var changed: [String] = []
            for i in 0..<min(count, array.count) { if let p = array[i] as? String { changed.append(p) } }
            watcher.note(changed)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func note(_ paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        for p in paths { for r in roots where p.hasPrefix(r) { dirty.insert(r) } }
    }

    /// True (and resets the flag) if anything under `root` changed since the last call.
    func consume(_ root: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return dirty.remove(root) != nil
    }
}
