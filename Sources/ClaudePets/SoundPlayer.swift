import AppKit

/// Soft system sounds for the two moments that matter: a session finishing, and a session needing
/// you. Off by default (Claude Code can already play its own permission sound). Toggle in the menu.
enum SoundPlayer {
    enum Kind { case done, attention }

    private static let key = "soundsEnabled"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static var lastPlayed: [String: TimeInterval] = [:]

    static func play(_ kind: Kind) {
        guard enabled else { return }
        let name = kind == .done ? "Glass" : "Pop"      // built-in macOS alert sounds
        let now = Date().timeIntervalSince1970
        if let last = lastPlayed[name], now - last < 1.0 { return }   // several at once → one sound
        lastPlayed[name] = now
        NSSound(named: NSSound.Name(name))?.play()
    }
}
