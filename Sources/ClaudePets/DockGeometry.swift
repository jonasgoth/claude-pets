import AppKit
import ApplicationServices

/// Where the Dock is on screen, so pets can live in the wallpaper gaps beside it instead of
/// underneath it. Exact via Accessibility when the user has allowed it; otherwise estimated from
/// the Dock's own preferences (tile size and how many tiles it holds), which lands within an icon
/// or so. The Dock's window itself is no help: it claims the whole screen.
enum DockGeometry {
    struct Info {
        let rect: CGRect      // Cocoa coordinates (origin bottom-left), same as NSScreen frames
        let exact: Bool
    }

    /// Nil when the Dock is not along the bottom of this screen, or is hidden.
    static func current(on screen: NSScreen) -> Info? {
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        let orientation = prefs?.string(forKey: "orientation") ?? "bottom"
        guard orientation == "bottom" else { return nil }
        let dockHeight = screen.visibleFrame.minY - screen.frame.minY
        guard dockHeight > 4 else { return nil }            // auto-hidden (or no Dock here)

        if AXIsProcessTrusted(), let rect = accessibilityDockRect(mainScreenHeight: NSScreen.screens.first?.frame.height ?? 0) {
            return Info(rect: rect, exact: true)
        }
        return Info(rect: estimatedDockRect(on: screen, dockHeight: dockHeight, prefs: prefs), exact: false)
    }

    // MARK: - Exact (Accessibility)

    private static func accessibilityDockRect(mainScreenHeight: CGFloat) -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == (kAXListRole as String) else { continue }
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posRef, let sizeRef else { continue }
            var pos = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            // AX positions use a top-left origin; flip to Cocoa's bottom-left.
            return CGRect(x: pos.x, y: mainScreenHeight - (pos.y + size.height), width: size.width, height: size.height)
        }
        return nil
    }

    // MARK: - Estimate (from Dock preferences)

    private static func estimatedDockRect(on screen: NSScreen, dockHeight: CGFloat, prefs: UserDefaults?) -> CGRect {
        let tileSize = prefs?.double(forKey: "tilesize") ?? 0
        let t = CGFloat(tileSize > 0 ? tileSize : 48)

        let pinnedApps = (prefs?.array(forKey: "persistent-apps") as? [[String: Any]]) ?? []
        let pinnedOthers = (prefs?.array(forKey: "persistent-others") as? [[String: Any]]) ?? []
        var pinned = Set<String>()
        for entry in pinnedApps {
            if let tile = entry["tile-data"] as? [String: Any],
               let file = tile["file-data"] as? [String: Any],
               let url = file["_CFURLString"] as? String { pinned.insert(normalize(url)) }
        }

        var tiles = pinnedApps.count
        var sawFinder = pinned.contains { $0.hasSuffix("/Finder.app") }
        // Running apps that aren't pinned get a tile too.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let url = app.bundleURL?.absoluteString else { continue }
            if app.bundleIdentifier == "com.apple.finder" { if !sawFinder { tiles += 1; sawFinder = true }; continue }
            if !pinned.contains(normalize(url)) { tiles += 1 }
        }
        if !sawFinder { tiles += 1 }              // Finder is always first
        tiles += pinnedOthers.count + 1          // folders/documents + Trash

        // Calibrated on a tile size of 54: each tile ≈ t + 6 pt, one separator ≈ 8, end padding ≈ 8.
        let width = CGFloat(tiles) * (t + 6) + 8 + 8
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.minY, width: width, height: dockHeight)
    }

    private static func normalize(_ url: String) -> String {
        var s = url
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
