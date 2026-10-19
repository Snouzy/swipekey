import Foundation

/// Touch frames recorded from a real trackpad (`swipekey --record`), replayed by the tests.
/// `expect` is the gesture every session of the trace is meant to be, or nil for movements that
/// must fire nothing (scrolling).
public struct Trace: Equatable {
    public var name: String
    public var expect: Gesture?
    public var frames: [TouchFrame]

    public init(name: String, expect: Gesture?, frames: [TouchFrame]) {
        self.name = name
        self.expect = expect
        self.frames = frames
    }

    /// One touch session per element: from the first touching frame to the frame where every
    /// finger has lifted (included).
    public var sessions: [[TouchFrame]] {
        var result: [[TouchFrame]] = []
        var current: [TouchFrame] = []
        for frame in frames {
            let touching = frame.touches.contains(where: \.isTouching)
            if touching {
                current.append(frame)
            } else if !current.isEmpty {
                current.append(frame)
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func load(from url: URL) throws -> Trace {
        try JSONDecoder().decode(Trace.self, from: Data(contentsOf: url))
    }

    /// Writes only the frames that matter: those with a finger down, and the one ending each session.
    public func write(to url: URL) throws {
        var kept = self
        kept.frames = sessions.flatMap { $0 }
        try JSONEncoder().encode(kept).write(to: url)
    }
}

/// Compact on disk: each frame is `[timestamp, [[id, state, x, y, size, majorAxis, minorAxis], …]]`,
/// numbers rounded to 4 decimals, so a minute of scrolling stays small.
extension Trace: Codable {
    private enum CodingKeys: String, CodingKey { case name, expect, frames }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        expect = try c.decodeIfPresent(Gesture.self, forKey: .expect)
        var framesContainer = try c.nestedUnkeyedContainer(forKey: .frames)
        var frames: [TouchFrame] = []
        while !framesContainer.isAtEnd {
            var frame = try framesContainer.nestedUnkeyedContainer()
            let timestamp = try frame.decode(Double.self)
            let rows = try frame.decode([[Double]].self)
            let touches = try rows.map { row -> Touch in
                guard row.count == 7 else {
                    throw DecodingError.dataCorruptedError(in: frame, debugDescription: "a touch needs 7 numbers")
                }
                return Touch(x: row[2], y: row[3], identifier: Int(row[0]), state: Int(row[1]), size: row[4], majorAxis: row[5], minorAxis: row[6])
            }
            frames.append(TouchFrame(touches: touches, timestamp: timestamp))
        }
        self.frames = frames
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(expect, forKey: .expect)
        var framesContainer = c.nestedUnkeyedContainer(forKey: .frames)
        for frame in frames {
            var row = framesContainer.nestedUnkeyedContainer()
            try row.encode(Self.rounded(frame.timestamp))
            try row.encode(frame.touches.map { touch -> [Double] in
                [Double(touch.identifier), Double(touch.state), Self.rounded(touch.x), Self.rounded(touch.y),
                 Self.rounded(touch.size), Self.rounded(touch.majorAxis), Self.rounded(touch.minorAxis)]
            })
        }
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}
