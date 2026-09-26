import AppKit

// Menu-bar-only app: no Dock icon, no main window. Everything lives in AppDelegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
