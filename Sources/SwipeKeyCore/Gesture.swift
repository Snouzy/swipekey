/// One contact on the trackpad. Coordinates are normalized to 0...1, origin bottom-left.
public struct Touch: Equatable {
    public var x: Double
    public var y: Double
    public var identifier: Int
    /// Raw MultitouchSupport state (3 = make touch, 4 = touching, 5 = break touch, ...).
    public var state: Int
    /// Contact size and ellipse axes, raw from MultitouchSupport (0 when unknown).
    public var size: Double
    public var majorAxis: Double
    public var minorAxis: Double

    public init(x: Double, y: Double, identifier: Int, state: Int = 4, size: Double = 0, majorAxis: Double = 0, minorAxis: Double = 0) {
        self.x = x
        self.y = y
        self.identifier = identifier
        self.state = state
        self.size = size
        self.majorAxis = majorAxis
        self.minorAxis = minorAxis
    }

    /// True while the finger is actually pressed on the surface (not hovering or lifting).
    public var isTouching: Bool { state == 3 || state == 4 }
}

public struct TouchFrame: Equatable {
    public var touches: [Touch]
    public var timestamp: Double

    public init(touches: [Touch], timestamp: Double) {
        self.touches = touches
        self.timestamp = timestamp
    }
}

public enum Direction: String, Codable, CaseIterable {
    case up, down, left, right
}

public enum PinchDirection: String, Codable, CaseIterable {
    /// Fingers move toward each other.
    case `in`
    /// Fingers spread apart.
    case out
}

/// Every gesture swipekey can recognize. To add one: add a case here, teach `Codable` its
/// `type` name below, and write a `GestureRecognizer` that emits it.
public enum Gesture: Hashable, CustomStringConvertible {
    case swipe(fingers: Int, direction: Direction)
    case pinch(fingers: Int, direction: PinchDirection)

    public var description: String {
        switch self {
        case let .swipe(fingers, direction): return "\(fingers)-finger swipe \(direction.rawValue)"
        case let .pinch(fingers, direction): return "\(fingers)-finger pinch \(direction.rawValue)"
        }
    }
}

extension Gesture: Codable {
    private enum CodingKeys: String, CodingKey { case type, fingers, direction }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "swipe":
            self = .swipe(
                fingers: try c.decode(Int.self, forKey: .fingers),
                direction: try c.decode(Direction.self, forKey: .direction)
            )
        case "pinch":
            self = .pinch(
                fingers: try c.decode(Int.self, forKey: .fingers),
                direction: try c.decode(PinchDirection.self, forKey: .direction)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown gesture type \"\(type)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .swipe(fingers, direction):
            try c.encode("swipe", forKey: .type)
            try c.encode(fingers, forKey: .fingers)
            try c.encode(direction, forKey: .direction)
        case let .pinch(fingers, direction):
            try c.encode("pinch", forKey: .type)
            try c.encode(fingers, forKey: .fingers)
            try c.encode(direction, forKey: .direction)
        }
    }
}
