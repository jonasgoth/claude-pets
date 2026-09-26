import AppKit
import ApplicationServices

/// Knows whether you could be looking at a Claude chat right now: which app is in front, for how
/// long, whether the screen is locked or asleep, which Claude window is focused (if Accessibility
/// permission was granted), and which terminal tab is selected (for CLI sessions).
///
/// State is sampled on the main thread and read from SessionStore's background queue via a lock.
final class SeenDetector {
    static let claudeBundleId = "com.anthropic.claudefordesktop"
    static let terminalBundleIds: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]

    struct Snapshot {
        var frontBundleId: String?
        var claudeFrontSince: Double?      // epoch when Claude became the front app; nil if it isn't
        var terminalFrontSince: Double?    // same for Terminal / iTerm2
        var terminalBundleId: String?
        var terminalSelectedTTY: String?   // e.g. "/dev/ttys004", when a terminal is front
        var claudeWindowTitle: String?     // focused Claude window title, only with Accessibility
        var axTrusted = false
        var isLocked = false
        var screensAsleep = false

        /// Nothing counts as seen while locked or asleep.
        var canSee: Bool { !isLocked && !screensAsleep }
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var timer: Timer?
    private var lastTTYRead: Double = 0

    /// Set by SessionStore when at least one CLI (terminal) session exists, so we only ask the
    /// terminal app for its tab (which triggers macOS's one-time Automation prompt) when needed.
    var wantsTerminalTTY = false

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.mutate { $0.isLocked = true }
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.mutate { $0.isLocked = false }
        }
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.mutate { $0.screensAsleep = true }
        }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.mutate { $0.screensAsleep = false }
        }

        sample()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    private func mutate(_ f: (inout Snapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        f(&state)
    }

    /// Ask macOS for Accessibility permission (shows the system prompt). User-initiated only.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Sampling (main thread)

    private func sample() {
        let now = Date().timeIntervalSince1970
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var s = snapshot()
        s.frontBundleId = front
        s.axTrusted = AXIsProcessTrusted()

        if front == Self.claudeBundleId {
            if s.claudeFrontSince == nil { s.claudeFrontSince = now }
            s.claudeWindowTitle = s.axTrusted ? Self.focusedWindowTitle(bundleId: Self.claudeBundleId) : nil
        } else {
            s.claudeFrontSince = nil
            s.claudeWindowTitle = nil
        }

        if let front, Self.terminalBundleIds.contains(front) {
            if s.terminalFrontSince == nil { s.terminalFrontSince = now }
            s.terminalBundleId = front
            if wantsTerminalTTY, now - lastTTYRead > 2 {
                lastTTYRead = now
                s.terminalSelectedTTY = Self.selectedTTY(terminalBundleId: front)
            }
        } else {
            s.terminalFrontSince = nil
            s.terminalBundleId = nil
            s.terminalSelectedTTY = nil
        }

        mutate { $0 = s }
    }

    /// Title of the focused window of the given app, via Accessibility. Nil without permission.
    private static func focusedWindowTitle(bundleId: String) -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else { return nil }
        let window = windowRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success else { return nil }
        return titleRef as? String
    }

    /// The tty of the selected tab in the front terminal window. Uses AppleScript, which makes
    /// macOS ask once for Automation permission for that terminal app.
    private static func selectedTTY(terminalBundleId: String) -> String? {
        let source: String
        switch terminalBundleId {
        case "com.apple.Terminal":
            source = "tell application \"Terminal\" to get tty of selected tab of front window"
        case "com.googlecode.iterm2":
            source = "tell application \"iTerm2\" to tell current session of current window to get tty"
        default:
            return nil
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result?.stringValue
    }

    /// tty device path for a process, e.g. "/dev/ttys004". Nil for processes with no terminal.
    static func tty(ofPid pid: Int) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return nil }
        ps.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !out.isEmpty, out != "??" else { return nil }
        return out.hasPrefix("/dev/") ? out : "/dev/" + out
    }
}
