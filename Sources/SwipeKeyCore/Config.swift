import Foundation

public struct Binding: Codable, Equatable {
    public var gesture: Gesture
    /// Keyboard modifiers that must be held during the gesture, e.g. `["cmd"]`.
    /// Empty means the gesture only fires with no modifier held.
    public var holding: [String]
    public var action: ActionSpec
    /// This gesture's own distance, taught from examples (Teach). Nil: the global threshold.
    public var threshold: Double?

    public init(gesture: Gesture, holding: [String] = [], action: ActionSpec, threshold: Double? = nil) {
        self.gesture = gesture
        self.holding = holding
        self.action = action
        self.threshold = threshold
    }

    private enum CodingKeys: String, CodingKey { case gesture, holding, action, threshold }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gesture = try c.decode(Gesture.self, forKey: .gesture)
        holding = try c.decodeIfPresent([String].self, forKey: .holding) ?? []
        action = try c.decode(ActionSpec.self, forKey: .action)
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(gesture, forKey: .gesture)
        if !holding.isEmpty { try c.encode(holding, forKey: .holding) }
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(threshold, forKey: .threshold)
    }

    /// The gesture plus held modifiers this binding answers to.
    public func trigger() throws -> Trigger {
        Trigger(gesture: gesture, held: try KeyCodes.flags(for: holding))
    }
}

public struct Config: Codable, Equatable {
    /// Swipe distance in normalized trackpad units (0...1 across the pad).
    public var swipeThreshold: Double
    /// How much the fingers' spread must change for a pinch, in normalized trackpad units.
    public var pinchThreshold: Double
    /// Swallow scroll events while this many fingers (or more) touch the trackpad, so a swipe
    /// doesn't also scroll the window underneath. 0 turns it off.
    public var blockScrollWithFingers: Int
    public var bindings: [Binding]
    /// Key events to rewrite, e.g. to fix a shortcut another app sends without its modifiers.
    public var remaps: [KeyRemap]
    /// Show the icon in the menu bar.
    public var menuBarIcon: Bool
    /// App that "Edit config…" opens the file with, e.g. "Cursor". Nil uses the default app for JSON.
    public var editor: String?

    public init(
        swipeThreshold: Double = 0.12, pinchThreshold: Double = 0.05, blockScrollWithFingers: Int = 3,
        bindings: [Binding], remaps: [KeyRemap] = [], menuBarIcon: Bool = true, editor: String? = nil
    ) {
        self.remaps = remaps
        self.menuBarIcon = menuBarIcon
        self.editor = editor
        self.swipeThreshold = swipeThreshold
        self.pinchThreshold = pinchThreshold
        self.blockScrollWithFingers = blockScrollWithFingers
        self.bindings = bindings
    }

    public enum CodingKeys: String, CodingKey { case swipeThreshold, pinchThreshold, blockScrollWithFingers, bindings, remaps, menuBarIcon, editor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swipeThreshold = try c.decodeIfPresent(Double.self, forKey: .swipeThreshold) ?? 0.12
        pinchThreshold = try c.decodeIfPresent(Double.self, forKey: .pinchThreshold) ?? 0.05
        blockScrollWithFingers = try c.decodeIfPresent(Int.self, forKey: .blockScrollWithFingers) ?? 3
        bindings = try c.decode([Binding].self, forKey: .bindings)
        remaps = try c.decodeIfPresent([KeyRemap].self, forKey: .remaps) ?? []
        menuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .menuBarIcon) ?? true
        editor = try c.decodeIfPresent(String.self, forKey: .editor)
    }

    /// Used when no config file exists: three-finger swipe up presses Return.
    public static let `default` = Config(bindings: [
        Binding(gesture: .swipe(fingers: 3, direction: .up), action: .key("return", modifiers: [])),
    ])

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/swipekey/config.json")
    }

    public static func load(from url: URL) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    /// Sets one top-level setting in the file and leaves everything else as the user wrote it
    /// (no defaults filled in). A nil value removes the key.
    public static func update(_ key: CodingKeys, to value: Any?, at url: URL) throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard var settings = object as? [String: Any] else { throw ConfigError("\(url.path) is not a JSON object") }
        settings[key.rawValue] = value
        let data = try JSONSerialization.data(withJSONObject: shortestNumbers(settings), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    /// JSONSerialization writes doubles with 17 digits (0.09 → 0.089999999999999997). As decimals
    /// they come out the way a person writes them; Swift's description is the shortest exact form.
    private static func shortestNumbers(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues(shortestNumbers)
        case let array as [Any]: return array.map(shortestNumbers)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID() && CFNumberIsFloatType(number):
            return NSDecimalNumber(string: String(describing: number.doubleValue))
        default: return value
        }
    }

    /// Same as `update(_:to:at:)` for a Codable value, e.g. the whole `bindings` list.
    public static func update<T: Encodable>(_ key: CodingKeys, toEncoded value: T, at url: URL) throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
        try update(key, to: json, at: url)
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
