import AppKit
import Combine
import SwipeKeyCore

/// The config as the menu and the settings window see it. Every change is written to the file
/// (only the key that changed) and applied to the engine right away.
final class ConfigStore: ObservableObject {
    /// Editors offered in "Open config with", shown only when installed. Any other app name
    /// works too when written by hand in the config ("editor": "Nova").
    static let knownEditors: [(name: String, bundleID: String)] = [
        ("TextEdit", "com.apple.TextEdit"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Zed", "dev.zed.Zed"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Xcode", "com.apple.dt.Xcode"),
    ]

    @Published private(set) var config: Config
    let url: URL
    let engine: Engine
    /// The live trackpad for recording and testing gestures in the settings window.
    lazy var lab = TouchLab(engine: engine)
    /// Called after `menuBarIcon` changes.
    var onMenuBarIconChange: ((Bool) -> Void)?

    init(config: Config, url: URL, engine: Engine) {
        self.config = config
        self.url = url
        self.engine = engine
    }

    /// Installed editors, plus the configured one if it's not in the list.
    var editorChoices: [String] {
        var names = Self.knownEditors
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
            .map(\.name)
        if let current = config.editor, !names.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            names.append(current)
        }
        return names
    }

    /// Picks up edits made to the file by hand. Throws, and keeps the current config, if it's invalid.
    func refreshFromDisk() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let fresh = try Config.load(from: url)
        try engine.reload(fresh)
        config = fresh
    }

    func setBindings(_ bindings: [Binding]) throws {
        var next = config
        next.bindings = bindings
        // Check before writing: a binding the engine refuses never reaches the file.
        try engine.reload(next)
        try ensureFile()
        try Config.update(.bindings, toEncoded: bindings, at: url)
        config = next
    }

    func setThresholds(swipe: Double, pinch: Double) throws {
        var next = config
        next.swipeThreshold = swipe
        next.pinchThreshold = pinch
        try engine.reload(next)
        try ensureFile()
        try Config.update(.swipeThreshold, to: swipe, at: url)
        try Config.update(.pinchThreshold, to: pinch, at: url)
        config = next
    }

    func setEditor(_ name: String?) throws {
        try ensureFile()
        try Config.update(.editor, to: name, at: url)
        config.editor = name
    }

    func setMenuBarIcon(_ shown: Bool) throws {
        try ensureFile()
        try Config.update(.menuBarIcon, to: shown, at: url)
        config.menuBarIcon = shown
        onMenuBarIconChange?(shown)
    }

    func openInEditor() throws {
        try ensureFile()
        if let editor = config.editor {
            try Self.run("/usr/bin/open", "-a", editor, url.path)
        } else if !NSWorkspace.shared.open(url) {
            // No app claims .json files: fall back to the default text editor.
            try Self.run("/usr/bin/open", "-t", url.path)
        }
    }

    /// Without a config file swipekey runs on defaults; write them out so there is something to change.
    private func ensureFile() throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((try config.jsonString() + "\n").utf8).write(to: url)
    }

    static func run(_ path: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
    }
}
