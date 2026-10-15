import Foundation

public struct Binding: Codable, Equatable {
    public var gesture: Gesture
    public var action: ActionSpec

    public init(gesture: Gesture, action: ActionSpec) {
        self.gesture = gesture
        self.action = action
    }
}

public struct Config: Codable, Equatable {
    /// Swipe distance in normalized trackpad units (0...1 across the pad).
    public var swipeThreshold: Double
    public var bindings: [Binding]

    public init(swipeThreshold: Double = 0.12, bindings: [Binding]) {
        self.swipeThreshold = swipeThreshold
        self.bindings = bindings
    }

    private enum CodingKeys: String, CodingKey { case swipeThreshold, bindings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swipeThreshold = try c.decodeIfPresent(Double.self, forKey: .swipeThreshold) ?? 0.12
        bindings = try c.decode([Binding].self, forKey: .bindings)
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

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
