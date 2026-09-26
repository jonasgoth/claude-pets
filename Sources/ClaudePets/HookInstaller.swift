import AppKit

/// Installs / removes the Claude Code hooks for Claude Pets. The hooks write one small event file
/// per session into ~/.claude-pets/events, which HookBridge reads for instant permission / tool /
/// done signals.
///
/// Modifying ~/.claude/settings.json is a persistent config change, so this only runs when the user
/// explicitly asks for it (a menu item), never automatically. settings.json is backed up first.
/// The one exception: hooks installed back when the app was called Clawdy are swapped for
/// the new ones once, since you already said yes to them.
enum HookInstaller {
    static let appDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-pets")
    static let scriptPath = (appDir as NSString).appendingPathComponent("claude-pets-hook.sh")
    static let settingsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    /// The script's name back when the app was called Clawdy (in ~/.clawdy).
    private static let clawdyScript = "clawdy-hook.sh"
    private static let clawdyDir = (NSHomeDirectory() as NSString).appendingPathComponent(".clawdy")

    /// The one shell script all hooks call. It reads the hook JSON on stdin, pulls out the session
    /// id, and writes ~/.claude-pets/events/<sid>.json with the state passed as $1.
    static let scriptBody = #"""
#!/bin/bash
# Claude Pets hook. Usage: claude-pets-hook.sh <state>   (hook JSON on stdin)
dir="$HOME/.claude-pets/events"
mkdir -p "$dir"
payload="$(cat)"
sid="$(printf '%s' "$payload" | /usr/bin/python3 -c 'import sys,json;
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: print("")' 2>/dev/null)"
[ -z "$sid" ] && exit 0
printf '{"state":"%s","ts":%s}\n' "$1" "$(date +%s)" > "$dir/$sid.json"
exit 0
"""#

    private static let hookMap: [(event: String, state: String, matcher: Bool)] = [
        ("UserPromptSubmit", "working", false),
        ("PreToolUse", "tool", true),
        ("PostToolUse", "working", true),
        ("PermissionRequest", "permission", true),
        ("Stop", "done", false),
        ("SessionEnd", "end", false),
    ]

    static var isInstalled: Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any] else { return false }
        // Consider us installed if any hook command points at our script.
        return JSONString(hooks).contains("claude-pets-hook.sh")
    }

    @discardableResult
    static func install() -> Result<Void, Error> {
        do {
            try FileManager.default.createDirectory(atPath: appDir, withIntermediateDirectories: true)
            try scriptBody.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

            var settings = loadSettings()
            backupSettings()
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            for entry in hookMap {
                var groups = hooks[entry.event] as? [[String: Any]] ?? []
                groups.removeAll { isOurs($0) }   // avoid duplicates
                let hook: [String: Any] = ["type": "command",
                                           "command": "\(shellQuoted(scriptPath)) \(entry.state)"]
                var group: [String: Any] = ["hooks": [hook]]
                if entry.matcher { group["matcher"] = "*" }
                groups.append(group)
                hooks[entry.event] = groups
            }
            settings["hooks"] = hooks
            try saveSettings(settings)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    static func uninstall() -> Result<Void, Error> {
        do {
            var settings = loadSettings()
            guard var hooks = settings["hooks"] as? [String: Any] else { return .success(()) }
            backupSettings()
            for (event, value) in hooks {
                guard var groups = value as? [[String: Any]] else { continue }
                groups.removeAll { isOurs($0) }
                if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
            try saveSettings(settings)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Swaps hooks left over from the Clawdy days for ours: install() drops the old entries
    /// as it adds the new ones. Then the old script folder goes, since nothing writes to it now.
    static func replaceClawdyHooks() {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              String(decoding: data, as: UTF8.self).contains(clawdyScript),
              case .success = install() else { return }
        try? FileManager.default.removeItem(atPath: clawdyDir)
    }

    // MARK: - settings.json helpers

    private static func loadSettings() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func saveSettings(_ settings: [String: Any]) throws {
        let dir = (settingsPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: settingsPath))
    }

    private static func backupSettings() {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = "\(settingsPath).claude-pets-backup-\(stamp)"
        try? FileManager.default.copyItem(atPath: settingsPath, toPath: backup)
    }

    /// A hook group that calls our script, under the new name or the old one.
    private static func isOurs(_ group: Any) -> Bool {
        let json = JSONString(group)
        return json.contains("claude-pets-hook.sh") || json.contains(clawdyScript)
    }

    private static func JSONString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func shellQuoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
