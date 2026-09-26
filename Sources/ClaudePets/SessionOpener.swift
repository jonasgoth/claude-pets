import AppKit

/// Takes you to the chat behind a crab.
///
/// Two kinds of session, two ways in:
///   • Desktop (Code tab, Cowork): the Claude app registers the `claude://` scheme, and
///     `claude://code/continue?session=local_…` switches it to that chat. The id has to be
///     Desktop's own ("local_…"), not the CLI session id.
///   • Terminal: nothing to link to, so we find the terminal app the session is running under
///     and raise its window — picking the right tab by tty where the app can be scripted.
enum SessionOpener {
    enum Target: Equatable {
        case desktop(URL)                      // a Desktop chat's claude:// link
        case terminal(tty: String, pid: Int)   // a CLI session: its tty + the claude process
    }

    /// One clickable thing: where to go, and which session it was. The session id rides along so
    /// that once we have actually taken you there, that crab can be marked seen.
    final class Request {
        let sessionId: String
        let target: Target
        init(sessionId: String, target: Target) {
            self.sessionId = sessionId
            self.target = target
        }
    }

    /// `path` is "continue" for a Code chat, "needs-input" for a Cowork task (Desktop routes that
    /// one through its own session list, which is where Cowork tasks live).
    static func desktopTarget(localId: String?, path: String = "continue") -> Target? {
        guard let localId, localId.hasPrefix("local_"),
              let url = URL(string: "claude://code/\(path)?session=\(localId)") else { return nil }
        return .desktop(url)
    }

    /// Returns true when we really did put that chat in front of you — the caller uses that to
    /// count the chat as seen. False means nothing opened (no Claude app, terminal gone).
    @discardableResult
    static func open(_ target: Target) -> Bool {
        switch target {
        case .desktop(let url):
            return NSWorkspace.shared.open(url)
        case .terminal(let tty, let pid):
            return openTerminal(tty: tty, pid: pid)
        }
    }

    // MARK: - Terminal sessions

    private static func openTerminal(tty: String, pid: Int) -> Bool {
        guard let app = owningApp(ofPid: pid) else { return false }
        app.activate()
        // Terminal.app and iTerm2 can be asked for the right tab; anything else just gets raised —
        // still a window with that session in it, so it counts either way.
        guard let script = focusScript(bundleId: app.bundleIdentifier ?? "", tty: tty) else { return true }
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return true
    }

    /// The app the process is running inside: walk up the parent chain until a pid belongs to a
    /// real (Dock-visible) application. That is the terminal, whatever brand it is.
    private static func owningApp(ofPid pid: Int) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<10 {
            if let app = NSRunningApplication(processIdentifier: pid_t(current)),
               app.bundleIdentifier != nil, app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPid(of pid: Int) -> Int? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "ppid=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return nil }
        ps.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Select the window/tab whose tty matches. Uses AppleScript, so macOS asks once for
    /// Automation permission for that terminal app (the same prompt the "seen" check uses).
    private static func focusScript(bundleId: String, tty: String) -> String? {
        let tty = tty.replacingOccurrences(of: "\"", with: "")
        switch bundleId {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected tab of w to t
                    set frontmost of w to true
                    return
                  end if
                end repeat
              end repeat
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      select s
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        default:
            return nil
        }
    }
}
