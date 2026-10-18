import AppKit
import SwipeKeyCore

/// The icon in the menu bar and its menu: status, pause, last gesture, bindings, config and log.
/// The menu is rebuilt each time it opens, so it always shows the current state.
final class MenuBar: NSObject, NSMenuDelegate {
    /// Editors offered in "Open config with", shown only when installed. Any other app name
    /// works too when written by hand in the config ("editor": "Nova").
    private static let editors: [(name: String, bundleID: String)] = [
        ("TextEdit", "com.apple.TextEdit"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Zed", "dev.zed.Zed"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Xcode", "com.apple.dt.Xcode"),
    ]
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/swipekey.log")

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let engine: Engine
    private var config: Config
    private let configURL: URL
    private let reload: () -> Void
    private var lastGesture: String?
    private var canPostEvents = CGPreflightPostEventAccess()
    private var permissionTimer: Timer?

    /// `reload` restarts swipekey with the config file as it is now.
    init(engine: Engine, config: Config, configURL: URL, reload: @escaping () -> Void) {
        self.engine = engine
        self.config = config
        self.configURL = configURL
        self.reload = reload
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
        // The permission can be granted or revoked at any time: keep the icon honest.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CGPreflightPostEventAccess()
            if now != canPostEvents {
                canPostEvents = now
                refreshIcon()
            }
        }
    }

    /// Called on the main queue for every recognized gesture.
    func gestureFired(_ trigger: Trigger) {
        let actions = config.bindings.filter { (try? $0.trigger()) == trigger }.map(\.action.description)
        lastGesture = "\(trigger) → \(actions.isEmpty ? "no binding" : actions.joined(separator: ", "))"
    }

    private func refreshIcon() {
        guard let button = item.button else { return }
        let symbol = canPostEvents ? "hand.draw" : "exclamationmark.triangle"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Swipekey") {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "SK"
        }
        button.appearsDisabled = !engine.isEnabled
        button.toolTip = "Swipekey: \(status)"
    }

    private var status: String {
        if !canPostEvents { return "can't send keystrokes" }
        return engine.isEnabled ? "running" : "paused"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled("Swipekey: \(status)"))
        if !canPostEvents {
            menu.addItem(action("Open Accessibility settings…", #selector(openAccessibility)))
        }
        let toggle = action("Enabled", #selector(toggleEnabled))
        toggle.state = engine.isEnabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(disabled("Last: \(lastGesture ?? "none yet")"))

        let bindings = NSMenu()
        for binding in config.bindings {
            let trigger = (try? binding.trigger())?.description ?? binding.gesture.description
            bindings.addItem(disabled("\(trigger) → \(binding.action)"))
        }
        if config.bindings.isEmpty { bindings.addItem(disabled("No bindings")) }
        menu.addItem(submenu("Bindings", bindings))

        menu.addItem(.separator())
        menu.addItem(action("Edit config…", #selector(editConfig)))
        menu.addItem(submenu("Settings", settingsMenu()))
        menu.addItem(action("Reload config", #selector(reloadConfig)))
        let log = action("Show log", #selector(showLog))
        log.isEnabled = FileManager.default.fileExists(atPath: Self.logURL.path)
        menu.addItem(log)
        menu.addItem(.separator())
        menu.addItem(action("Quit Swipekey", #selector(quit)))
    }

    private func settingsMenu() -> NSMenu {
        let editors = NSMenu()
        let current = config.editor
        let byDefault = action("Default app", #selector(chooseEditor(_:)))
        byDefault.state = current == nil ? .on : .off
        editors.addItem(byDefault)
        editors.addItem(.separator())
        var names = Self.editors
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
            .map(\.name)
        if let current, !names.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            names.append(current)
        }
        for name in names {
            let choice = action(name, #selector(chooseEditor(_:)))
            choice.representedObject = name
            choice.state = current?.caseInsensitiveCompare(name) == .orderedSame ? .on : .off
            editors.addItem(choice)
        }

        let settings = NSMenu()
        settings.addItem(submenu("Open config with", editors))
        let icon = action("Show menu bar icon", #selector(hideIcon))
        icon.state = .on
        icon.toolTip = "Unchecking hides this icon. To bring it back, set \"menuBarIcon\": true in the config and reload."
        settings.addItem(icon)
        return settings
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        engine.isEnabled.toggle()
        refreshIcon()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func editConfig() {
        do {
            try ensureConfigFile()
            if let editor = config.editor {
                try run("/usr/bin/open", "-a", editor, configURL.path)
            } else if !NSWorkspace.shared.open(configURL) {
                // No app claims .json files: fall back to the default text editor.
                try run("/usr/bin/open", "-t", configURL.path)
            }
        } catch { show(error) }
    }

    @objc private func chooseEditor(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String
        do {
            try ensureConfigFile()
            try Config.update(.editor, to: name, at: configURL)
            config.editor = name
        } catch { show(error) }
    }

    @objc private func hideIcon() {
        do {
            try ensureConfigFile()
            try Config.update(.menuBarIcon, to: false, at: configURL)
            NSStatusBar.system.removeStatusItem(item)
            permissionTimer?.invalidate()
        } catch { show(error) }
    }

    @objc private func reloadConfig() { reload() }

    @objc private func showLog() {
        try? run("/usr/bin/open", "-a", "Console", Self.logURL.path)
    }

    @objc private func quit() {
        MultitouchSource.stop()
        // A clean exit: the LaunchAgent only relaunches swipekey after a crash.
        exit(0)
    }

    // MARK: Helpers

    /// Without a config file swipekey runs on defaults; write them out so there is something to edit.
    private func ensureConfigFile() throws {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((try config.jsonString() + "\n").utf8).write(to: configURL)
    }

    private func run(_ path: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
    }

    func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Swipekey"
        alert.informativeText = "\(error)"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
