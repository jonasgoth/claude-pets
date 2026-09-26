import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Read from the bundle so there is exactly one place the version is set: build.sh,
    /// which CI fills in from the git tag. A bare binary has no Info.plist, hence "dev".
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    /// The Accessibility ("Window checks") row is finished but hidden: we don't want to ask for
    /// that permission yet. Nothing else turns Accessibility on, so the feature simply stays off
    /// until we show the row again. To try it meanwhile:
    ///     defaults write app.claudepets.ClaudePets ShowWindowChecks -bool true
    static var showsWindowChecks: Bool {
        UserDefaults.standard.bool(forKey: "ShowWindowChecks")
    }

    private var statusItem: NSStatusItem!
    private var playpen: PlaypenController!
    private var store: SessionStore!
    private let seen = SeenDetector()
    private let updater = Updater()

    private var menu: NSMenu!
    private let headerItem = NSMenuItem()
    private let sessionsItem = NSMenuItem()
    private let sessionsView = MenuListView()
    private let quitItem = NSMenuItem()
    private let quitView = MenuListView()
    private let headerView = MenuHeaderView(version: AppDelegate.version)
    /// Every setting lives in one menu item: a two-column grid of tappable boxes.
    private let gridItem = NSMenuItem()
    private let gridView = MenuListView()

    /// Rows for busy sessions: their Claude asterisk is redrawn on a timer while the menu is open.
    private var spinTimer: Timer?
    private var spinFrame = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.carryOverFromClawdy()
        playpen = PlaypenController()
        seen.start()
        store = SessionStore(scene: playpen.scene, seen: seen)
        // Clicking a crab opened that chat, so the store can stop calling it unseen.
        playpen.scene.onOpened = { [weak self] id in self?.store.markOpened(id) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = CrabSprite.menuBarImage()
            button.toolTip = "Claude Pets"
        }

        menu = NSMenu()
        menu.delegate = self
        headerItem.view = headerView
        menu.addItem(headerItem)
        sessionsItem.view = sessionsView
        menu.addItem(sessionsItem)
        menu.addItem(Self.dividerItem())
        gridItem.view = gridView
        menu.addItem(gridItem)
        menu.addItem(Self.dividerItem())
        // Quit is drawn as one more settings row so the bottom of the menu matches the rest.
        quitView.setRows([MenuRow.Model(title: "Quit Claude Pets",
                                        leading: .glyph(IconFont.power),
                                        control: .action("⌘Q"),
                                        closesMenu: true,
                                        action: { NSApp.terminate(nil) })])
        quitItem.view = quitView
        quitItem.keyEquivalent = "q"
        quitItem.action = #selector(NSApplication.terminate(_:))
        menu.addItem(quitItem)
        statusItem.menu = menu

        store.onUpdate = { [weak self] in self?.updateStatusItem() }
        playpen.show()
        store.start()
        // A new version adds a row to the menu; nothing is downloaded until you click it.
        updater.onChange = { [weak self] in self?.refreshGrid() }
        updater.start()
    }

    /// Menu bar shows how many crabs are alive; turns red with a "!" when one needs you.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let rows = store.rows
        let attention = rows.contains { $0.status.needsYou }
        let text = rows.isEmpty ? "" : (attention ? " \(rows.count)!" : " \(rows.count)")
        let color: NSColor = attention ? .systemRed : .labelColor
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: attention ? .bold : .medium),
        ])
        button.imagePosition = .imageLeading
    }

    /// A slim hairline in place of AppKit's separator, which pads itself generously.
    private static func dividerItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuDividerView()
        item.isEnabled = false
        return item
    }

    private func toggleSounds() {
        SoundPlayer.enabled.toggle()
        refreshGrid()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildSessionRows()
        spinFrame = 0
        spinTimer?.invalidate()
        guard store.rows.contains(where: { $0.status.isBusy }) else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.spinTick() }
        RunLoop.main.add(t, forMode: .common)   // .common covers menu tracking, so it keeps ticking
        spinTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        spinTimer?.invalidate()
        spinTimer = nil
    }

    private func spinTick() {
        spinFrame = (spinFrame + 1) % ClaudeMark.steps
        sessionsView.setRows(sessionModels())
    }

    /// A plain menu-action icon, in the grey AppKit uses for the ones it adds itself.
    private static func actionIcon(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// The little mark in front of a session row: a tinted SF Symbol for every resting state.
    private static func markImage(_ status: CrabStatus) -> NSImage? {
        let style = BadgeStyle.forStatus(status)
        let name = style?.symbol ?? "circle"
        let color = style?.color ?? NSColor.tertiaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.size = NSSize(width: 14, height: 14)
        return image
    }

    private func togglePlaypen() {
        if playpen.isVisible { playpen.hide() } else { playpen.show() }
        refreshGrid()
    }

    /// Kept for the menu row that is hidden for now — see refreshGrid().
    private func resetCrabs() { playpen.scene.resetCrabs() }

    /// Session rows are a readout, not a button — but they need an action to avoid being greyed out.
    private func toggleHooks() {
        if HookInstaller.isInstalled {
            switch HookInstaller.uninstall() {
            case .success: notify("Instant updates off", "The Claude Pets hooks were removed from your Claude settings.")
            case .failure(let e): notify("Could not remove hooks", e.localizedDescription)
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "Turn on instant updates?"
            alert.informativeText = "Claude Pets will add hooks to your Claude Code settings (~/.claude/settings.json) so crabs react instantly to permission prompts and finished turns. Your settings file is backed up first. You can turn this off any time."
            alert.addButton(withTitle: "Turn on")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            switch HookInstaller.install() {
            case .success: notify("Instant updates on", "Restart or prompt any Claude session for the hooks to take effect.")
            case .failure(let e): notify("Could not install hooks", e.localizedDescription)
            }
        }
        refreshGrid()
    }

    /// Asks macOS for Accessibility permission so Claude Pets can read which Claude window is in front
    /// (used to clear Cowork "done" badges precisely). Only ever runs when you click this.
    /// Not granted yet: macOS shows its own "open System Settings" prompt. Already
    /// granted: nothing to ask for, so go straight to the pane where it can be taken back.
    private func requestAccessibility() {
        guard AXIsProcessTrusted() else { return SeenDetector.requestAccessibility() }
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    /// The app used to be called Clawdy, under the bundle id app.clawdy.Clawdy. Once, on the
    /// first launch under the new name, copy those settings over (pet picks, colours, sounds)
    /// and point hooks installed back then at the new script, so nothing resets.
    private static func carryOverFromClawdy() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "carriedOverFromClawdy") else { return }
        if let old = defaults.persistentDomain(forName: "app.clawdy.Clawdy") {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        HookInstaller.replaceClawdyHooks()
        defaults.set(true, forKey: "carriedOverFromClawdy")
    }

    /// Swaps this copy of Claude Pets for the new one, then relaunches. Only ever runs when you
    /// click the update row; a failure leaves the current version exactly as it was.
    private func installUpdate(_ release: Updater.Release) {
        let alert = NSAlert()
        alert.messageText = "Update Claude Pets to \(release.version)?"
        alert.informativeText = "Claude Pets will download the new version, replace itself and restart. Your settings and pets come back with it."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updater.install(release) { [weak self] problem in
            guard let problem else { return }
            self?.notify("Could not update Claude Pets", problem)
        }
    }

    private func notify(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func rebuildSessionRows() {
        refreshGrid()
        sessionsView.setRows(sessionModels())
    }

    /// One row per live session: its status mark, its name, and a click that jumps to the
    /// chat. Drawn as our own rows so they highlight in the same grey as everything else —
    /// a stock menu item always highlights in the system accent colour.
    private func sessionModels() -> [MenuRow.Model] {
        let rows = store.rows
        guard !rows.isEmpty else {
            return [MenuRow.Model(title: "No sessions running", leading: .none, control: .none)]
        }
        return rows.map { row in
            let mark = row.status.isBusy ? ClaudeMark.image(step: spinFrame) : Self.markImage(row.status)
            // Desktop chats open on click; a terminal session has nothing to open, so its
            // row keeps an empty action and stays a plain readout that still looks live.
            let open = row.open.map { SessionOpener.Request(sessionId: row.id, target: $0) }
            return MenuRow.Model(title: row.title,
                                 leading: .image(mark),
                                 control: .none,
                                 tooltip: open == nil ? nil : "Go to this chat",
                                 closesMenu: open != nil,
                                 action: { [weak self] in
                                     guard let open else { return }
                                     if SessionOpener.open(open.target) {
                                         self?.store.markOpened(open.sessionId)
                                     }
                                 })
        }
    }

    /// Rebuilds the settings list: one row per setting, its switch on the right.
    private func refreshGrid() {
        // macOS decides the window-checks one: the app can read whether permission was
        // granted, but only System Settings can change it, so the row opens that pane.
        let shown = playpen.isVisible
        let sound = SoundPlayer.enabled
        let hooks = HookInstaller.isInstalled
        var rows: [MenuRow.Model] = []
        if let release = updater.available {
            let busy = updater.isInstalling
            rows.append(MenuRow.Model(title: busy ? "Updating…" : "Update to \(release.version)",
                                      leading: .glyph(IconFont.sparkles),
                                      control: .action(busy ? "" : "Install"),
                                      tooltip: busy ? nil : "Download and restart Claude Pets",
                                      closesMenu: true,
                                      action: busy ? nil : { [weak self] in self?.installUpdate(release) }))
        }
        if Self.showsWindowChecks {
            rows.append(MenuRow.Model(title: "Window checks",
                                      leading: .glyph(IconFont.window),
                                      control: .toggle(AXIsProcessTrusted()),
                                      closesMenu: true,
                                      action: { [weak self] in self?.requestAccessibility() }))
        }
        rows.append(contentsOf: [
            MenuRow.Model(title: "Crab visibility",
                          leading: .glyph(shown ? IconFont.eye : IconFont.eyeOff),
                          control: .toggle(shown),
                          action: { [weak self] in self?.togglePlaypen() }),
            MenuRow.Model(title: "Sounds",
                          leading: .glyph(sound ? IconFont.volumeHigh : IconFont.volumeOff),
                          control: .toggle(sound),
                          action: { [weak self] in self?.toggleSounds() }),
            MenuRow.Model(title: "Instant updates",
                          leading: .glyph(hooks ? IconFont.flash : IconFont.flashOff),
                          control: .toggle(hooks),
                          action: { [weak self] in self?.toggleHooks() }),
        ])
        gridView.setRows(rows)
        gridItem.view = gridView
    }
}
