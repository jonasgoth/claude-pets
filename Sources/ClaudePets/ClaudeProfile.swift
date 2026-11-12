import Foundation

/// One copy of the Claude app with its own sign-in and its own files. The normal app keeps its
/// Desktop data in ~/Library/Application Support/Claude and its Claude Code data in ~/.claude.
/// Extra profiles (made with the "Claude Profiles" app, e.g. "Claude Jgo") live side by side in
/// ~/Library/Application Support/Claude-<Name>, with their Claude Code data in its claude-config
/// folder, and run as their own app copy under claude-desktop-profiles/apps/Claude <Name>.app.
///
/// Every reader that used to look only at the normal app's folders now takes one of these.
struct ClaudeProfile: Hashable {
    let name: String        // "Claude", "Claude Jgo"
    let dataDir: String     // the Desktop app's own folder (Local Storage, claude-code-sessions, …)
    let configDir: String   // Claude Code's folder (sessions, projects)
    let appPath: String?    // the app to hand claude:// links to; nil = whatever macOS picks

    var isMain: Bool { configDir == Self.mainConfigDir }

    var sessionsDir: String { "\(configDir)/sessions" }
    var projectsDir: String { "\(configDir)/projects" }
    var desktopMetaDir: String { "\(dataDir)/claude-code-sessions" }
    var coworkDir: String { "\(dataDir)/local-agent-mode-sessions" }
    var localStorageDir: String { "\(dataDir)/Local Storage/leveldb" }

    private static let home = NSHomeDirectory() as NSString
    private static let appSupport = home.appendingPathComponent("Library/Application Support")
    private static let mainConfigDir = home.appendingPathComponent(".claude")
    private static let profileAppsDir = "\(appSupport)/claude-desktop-profiles/apps"

    static let main = ClaudeProfile(
        name: "Claude",
        dataDir: "\(appSupport)/Claude",
        configDir: mainConfigDir,
        appPath: ["/Applications/Claude.app", home.appendingPathComponent("Applications/Claude.app")]
            .first { FileManager.default.fileExists(atPath: $0) })

    /// The normal app first, then every extra profile that has a Claude Code folder.
    static func discover() -> [ClaudeProfile] {
        let fm = FileManager.default
        var out = [main]
        let names = (try? fm.contentsOfDirectory(atPath: appSupport)) ?? []
        for folder in names.sorted() where folder.hasPrefix("Claude-") {
            let dataDir = "\(appSupport)/\(folder)"
            let configDir = "\(dataDir)/claude-config"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: configDir, isDirectory: &isDir), isDir.boolValue else { continue }
            let suffix = String(folder.dropFirst("Claude-".count))
            let appName = "Claude \(suffix)"
            let app = "\(profileAppsDir)/\(appName).app"
            out.append(ClaudeProfile(name: appName, dataDir: dataDir, configDir: configDir,
                                     appPath: fm.fileExists(atPath: app) ? app : nil))
        }
        return out
    }
}
