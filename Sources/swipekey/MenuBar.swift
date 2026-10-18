import AppKit
import SwipeKeyCore

/// The icon in the menu bar and its menu: status, pause, last gesture, bindings, config and log.
/// The menu is rebuilt each time it opens, so it always shows the current state.
final class MenuBar: NSObject, NSMenuDelegate {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/swipekey.log")

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let store: ConfigStore
    private let reload: () -> Void
    private let openSettings: () -> Void
    private var lastGesture: String?
    private var canPostEvents = CGPreflightPostEventAccess()
    private var permissionTimer: Timer?

    /// `reload` restarts swipekey with the config file as it is now.
    init(store: ConfigStore, reload: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.store = store
        self.reload = reload
        self.openSettings = openSettings
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

    /// Takes the icon out of the menu bar for good (a new MenuBar brings it back).
    func remove() {
        permissionTimer?.invalidate()
        NSStatusBar.system.removeStatusItem(item)
    }

    /// Called on the main queue for every recognized gesture.
    func gestureFired(_ trigger: Trigger) {
        let actions = store.config.bindings.filter { (try? $0.trigger()) == trigger }.map(\.action.description)
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
        button.appearsDisabled = !store.engine.isEnabled
        button.toolTip = "Swipekey: \(status)"
    }

    private var status: String {
        if !canPostEvents { return "can't send keystrokes" }
        return store.engine.isEnabled ? "running" : "paused"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let config = store.config
        menu.removeAllItems()
        menu.addItem(disabled("Swipekey: \(status)"))
        if !canPostEvents {
            menu.addItem(action("Open Accessibility settings…", #selector(openAccessibility)))
        }
        let toggle = action("Enabled", #selector(toggleEnabled))
        toggle.state = store.engine.isEnabled ? .on : .off
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
        menu.addItem(action("Settings…", #selector(showSettings), key: ","))
        menu.addItem(action("Edit config…", #selector(editConfig)))
        menu.addItem(submenu("Open config with", editorsMenu()))
        menu.addItem(action("Reload config", #selector(reloadConfig)))
        let log = action("Show log", #selector(showLog))
        log.isEnabled = FileManager.default.fileExists(atPath: Self.logURL.path)
        menu.addItem(log)
        menu.addItem(.separator())
        menu.addItem(action("Quit Swipekey", #selector(quit)))
    }

    private func editorsMenu() -> NSMenu {
        let editors = NSMenu()
        let current = store.config.editor
        let byDefault = action("Default app", #selector(chooseEditor(_:)))
        byDefault.state = current == nil ? .on : .off
        editors.addItem(byDefault)
        editors.addItem(.separator())
        for name in store.editorChoices {
            let choice = action(name, #selector(chooseEditor(_:)))
            choice.representedObject = name
            choice.state = current?.caseInsensitiveCompare(name) == .orderedSame ? .on : .off
            editors.addItem(choice)
        }
        return editors
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
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
        store.engine.isEnabled.toggle()
        refreshIcon()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func showSettings() { openSettings() }

    @objc private func editConfig() {
        do { try store.openInEditor() } catch { Self.show(error) }
    }

    @objc private func chooseEditor(_ sender: NSMenuItem) {
        do { try store.setEditor(sender.representedObject as? String) } catch { Self.show(error) }
    }

    @objc private func reloadConfig() { reload() }

    @objc private func showLog() {
        try? ConfigStore.run("/usr/bin/open", "-a", "Console", Self.logURL.path)
    }

    @objc private func quit() {
        MultitouchSource.stop()
        // A clean exit: the LaunchAgent only relaunches swipekey after a crash.
        exit(0)
    }

    static func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Swipekey"
        alert.informativeText = "\(error)"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
