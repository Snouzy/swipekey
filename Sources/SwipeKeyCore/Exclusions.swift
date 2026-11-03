import AppKit
import Foundation

/// A place where shortcuts stay quiet: an app, or a website in the browser. With `only`, just the
/// named shortcuts do (see `shortcutName`); without it, all of them.
///
///     { "app": "com.googlecode.iterm2" }
///     { "url": "github.com/*/pull/*", "only": ["@@"] }
public struct Exclusion: Codable, Equatable {
    /// App name or bundle identifier, case-insensitive.
    public var app: String?
    /// See `URLPattern`.
    public var url: String?
    public var only: [String]?

    public init(app: String? = nil, url: String? = nil, only: [String]? = nil) {
        self.app = app; self.url = url; self.only = only
    }
}

/// `github.com` is the whole site, `github.com/a` that page and what's under it, and `*` is any text:
/// `github.com/*/pull/*`, `*.google.com`. The scheme, `www.`, the query and the fragment don't count.
public struct URLPattern {
    private let regex: NSRegularExpression

    public init(_ pattern: String) throws {
        var text = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let end = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<end]) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/*") { text.removeLast(2) }
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { throw ConfigError("An exclusion's \"url\" can't be empty: \"\(pattern)\".") }
        let body = text.components(separatedBy: "*").map(NSRegularExpression.escapedPattern).joined(separator: ".*")
        regex = try NSRegularExpression(pattern: "^\(body)(/.*)?$")
    }

    public func matches(_ url: String) -> Bool {
        let address = Self.address(of: url)
        return regex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil
    }

    /// Host and path, the part patterns are compared with.
    private static func address(of url: String) -> String {
        guard let parts = URLComponents(string: url) else { return url.lowercased() }
        var host = (parts.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = parts.path.lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }
}

/// Where a remap works: one app in front, or one website.
public struct RemapPlace {
    private let app: String?
    private let url: URLPattern?
    /// Two places with the same identity are the same place.
    public let identity: String

    /// Nil when neither is given: the remap works everywhere.
    public init?(inApp: String?, url: String?) throws {
        if inApp != nil && url != nil { throw ConfigError("A remap works in an \"inApp\" or on a \"url\", not both.") }
        guard inApp != nil || url != nil else { return nil }
        app = inApp?.lowercased()
        self.url = try url.map(URLPattern.init)
        identity = (app ?? url ?? "").lowercased()
    }

    /// `url` is nil when it isn't known: then it's not this website, and the key stays itself.
    public func contains(app current: ForegroundApp?, url address: String?) -> Bool {
        if let app { return current.map { app == $0.bundleID.lowercased() || app == $0.name.lowercased() } ?? false }
        if let url, let address { return url.matches(address) }
        return false
    }
}

public enum AppName {
    /// The app's name when `app` is a bundle identifier it can find, `app` itself otherwise.
    public static func display(_ app: String) -> String {
        guard let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return app }
        return FileManager.default.displayName(atPath: location.path).replacingOccurrences(of: ".app", with: "")
    }
}

public struct ForegroundApp: Equatable {
    public let name: String
    public let bundleID: String

    public init(name: String, bundleID: String) { self.name = name; self.bundleID = bundleID }
}

/// The exclusions of a config, checked and ready to ask.
public struct ExclusionList {
    private struct Rule {
        let app: String?
        let url: URLPattern?
        let only: Set<String>?
    }
    private let rules: [Rule]

    public init(_ exclusions: [Exclusion]) throws {
        rules = try exclusions.map { exclusion in
            guard (exclusion.app == nil) != (exclusion.url == nil) else {
                throw ConfigError("An exclusion names either an \"app\" or a \"url\".")
            }
            return Rule(app: exclusion.app?.lowercased(), url: try exclusion.url.map(URLPattern.init), only: exclusion.only.map(Set.init))
        }
    }

    public var watchesURLs: Bool { rules.contains { $0.url != nil } }

    /// `url` is nil when it isn't known: the shortcut then keeps working.
    public func excludes(_ shortcut: String, app: ForegroundApp?, url: String?) -> Bool {
        rules.contains { rule in
            if let only = rule.only, !only.contains(shortcut) { return false }
            if let wanted = rule.app, let app { return wanted == app.bundleID.lowercased() || wanted == app.name.lowercased() }
            if let pattern = rule.url, let url { return pattern.matches(url) }
            return false
        }
    }
}

extension KeyRemap {
    /// What `only` calls this remap: `@@` for a double tap, `shift+cmd+a` with modifiers.
    public var shortcutName: String {
        let held = KeyCodes.orderedModifiers(Set(from.modifiers.map(KeyCodes.canonicalModifier)))
        let key = from.taps == 1 ? from.key : from.key.count == 1 ? from.key + from.key : from.key + " twice"
        return (held + [key]).joined(separator: "+")
    }
}

extension Binding {
    /// What `only` calls this binding: `3-finger swipe up`, `cmd + 3-finger swipe up`.
    public var shortcutName: String { (try? trigger().description) ?? gesture.description }
}

/// Reads the active tab's address from the browsers that answer AppleScript. Firefox doesn't.
enum BrowserURL {
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    ]
    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    static func script(forBundleID id: String) -> String? {
        let tell: String
        if chromium.contains(id) { tell = "URL of active tab of front window" }
        else if safari.contains(id) { tell = "URL of front document" }
        else { return nil }
        return "with timeout of 2 seconds\ntell application id \"\(id)\" to get \(tell)\nend timeout"
    }
}

/// Knows what's in front, so shortcuts can ask whether they're excluded right now. Main thread.
///
/// Key events can't wait for a browser, so they read the address kept here. It's refreshed in the
/// background twice a second, and only while a browser is in front and an exclusion or a remap names a URL.
public final class Foreground {
    public static let refreshInterval: TimeInterval = 0.5

    private var list: ExclusionList
    private var app: ForegroundApp?
    private var url: String?
    private var timer: Timer?
    private var reading = false
    private var reported: Set<String> = []
    private let queue = DispatchQueue(label: "swipekey.browser-url")
    /// What's worth a line in the log. Addresses never go there.
    public var onLog: ((String) -> Void)?

    /// A remap names a URL: keep the address up to date for it.
    public var remapsWatchURLs = false {
        didSet { if remapsWatchURLs != oldValue { frontChanged() } }
    }

    public init(_ list: ExclusionList) { self.list = list }

    public func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.frontChanged()
        }
        frontChanged()
    }

    public func update(_ list: ExclusionList) {
        self.list = list
        frontChanged()
    }

    public func isExcluded(_ shortcut: String) -> Bool {
        list.excludes(shortcut, app: app, url: url)
    }

    public func isWithin(_ place: RemapPlace) -> Bool {
        place.contains(app: app, url: url)
    }

    private func frontChanged() {
        let front = NSWorkspace.shared.frontmostApplication
        app = front.map { ForegroundApp(name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier ?? "") }
        url = nil
        timer?.invalidate()
        timer = nil
        guard list.watchesURLs || remapsWatchURLs, let id = app?.bundleID, let source = BrowserURL.script(forBundleID: id) else { return }
        refresh(source, bundleID: id)
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.refresh(source, bundleID: id) }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh(_ source: String, bundleID: String) {
        guard !reading else { return }
        reading = true
        queue.async { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            var error: NSDictionary?
            let value = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            let code = error?[NSAppleScript.errorNumber] as? Int
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                self.report(bundleID, code: code, value: value, milliseconds: milliseconds)
                if self.app?.bundleID == bundleID { self.url = value }
            }
        }
    }

    /// Once per browser and kind of outcome. -1728: no window open, nothing wrong.
    private func report(_ bundleID: String, code: Int?, value: String?, milliseconds: Int) {
        let line: String
        if let code {
            if code == -1728 { return }
            line = code == -1743
                ? "Not allowed to read the address from \(bundleID): allow it in System Settings → Privacy & Security → Automation."
                : "Could not read the address from \(bundleID): error \(code)."
        } else {
            guard value != nil else { return }
            line = "Reading the address from \(bundleID) works (\(milliseconds) ms)."
        }
        if reported.insert(line.components(separatedBy: " (").first ?? line).inserted { onLog?(line) }
    }
}
