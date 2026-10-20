import Foundation

/// Teaching a gesture from examples, like enrolling a fingerprint: the user does it five times the
/// way they usually do, and the gesture gets its own distance from them.
public enum Teach {
    /// The share of the smallest example the gesture then needs: every example clears it well.
    public static let fraction = 0.6

    /// The distance proposed for `gesture` from its examples, against the `current` global value.
    /// 3+ fingers never get stricter than now (teaching must not add misses the examples didn't
    /// show); 2 fingers never get more eager than now (they compete with scrolling and zooming).
    public static func proposal(for gesture: Gesture, examples: [Double], current: Double) -> Double {
        guard let smallest = examples.min() else { return current }
        let raw = (smallest * fraction * 1000).rounded() / 1000
        let (floor, ceiling): (Double, Double)
        switch gesture {
        case .swipe: (floor, ceiling) = (0.03, 0.25)
        case .pinch: (floor, ceiling) = (0.015, 0.15)
        }
        if gesture.fingers >= 3 { return min(max(raw, min(floor, current)), current) }
        return max(min(raw, max(ceiling, current)), current)
    }
}

/// One teaching run: feed it the trackpad's frames; at the end of each touch it says whether that
/// was a good example of the gesture, and why not.
public struct TeachSession {
    public enum Feedback: Equatable {
        /// A good example, with its size (swipe distance or pinch spread change).
        case accepted(Double)
        /// Done with another number of fingers.
        case wrongFingers(Int)
        /// It moved more like this other gesture.
        case other(Gesture)
        /// Right gesture, but too small to count.
        case tooSmall
    }

    public static let examplesNeeded = 5

    public let gesture: Gesture
    public private(set) var examples: [Double] = []
    public var isDone: Bool { examples.count >= Self.examplesNeeded }

    // The touch in progress.
    private var maxFingers = 0
    private var starts: [Int: (x: Double, y: Double)] = [:]
    private var startSpread = 0.0
    /// The largest movement seen for each gesture, at the gesture's finger count.
    private var best: [Gesture: Double] = [:]

    public init(gesture: Gesture) { self.gesture = gesture }

    public mutating func observe(_ frame: TouchFrame) -> Feedback? {
        let active = frame.touches.filter(\.isTouching)
        guard !active.isEmpty else { return finishTouch() }
        maxFingers = max(maxFingers, active.count)
        // Measured only with the gesture's fingers, from when that set landed; fingers lifting at
        // the end stop the measure without losing it.
        guard active.count == gesture.fingers else { return nil }
        if !active.allSatisfy({ starts[$0.identifier] != nil }) {
            starts = Dictionary(active.map { ($0.identifier, (x: $0.x, y: $0.y)) }, uniquingKeysWith: { first, _ in first })
            startSpread = Self.spread(active)
            return nil
        }
        switch gesture {
        case .swipe: measureSwipe(active, aspect: frame.aspect)
        case .pinch: measurePinch(active)
        }
        return nil
    }

    private mutating func measureSwipe(_ active: [Touch], aspect: Double) {
        var dx = 0.0, dy = 0.0
        for touch in active {
            guard let start = starts[touch.identifier] else { continue }
            dx += touch.x - start.x
            dy += touch.y - start.y
        }
        dx /= Double(active.count)
        dy /= Double(active.count)
        let vertical = abs(dy) >= abs(dx) * aspect
        let direction: Direction = vertical ? (dy > 0 ? .up : .down) : (dx > 0 ? .right : .left)
        note(.swipe(fingers: active.count, direction: direction), vertical ? abs(dy) : abs(dx))
    }

    private mutating func measurePinch(_ active: [Touch]) {
        let change = Self.spread(active) - startSpread
        note(.pinch(fingers: active.count, direction: change < 0 ? .in : .out), abs(change))
    }

    private mutating func note(_ gesture: Gesture, _ size: Double) {
        best[gesture] = max(best[gesture] ?? 0, size)
    }

    private mutating func finishTouch() -> Feedback? {
        defer {
            maxFingers = 0
            starts = [:]
            best = [:]
        }
        guard maxFingers >= 2, !isDone else { return nil }
        guard maxFingers == gesture.fingers else { return .wrongFingers(maxFingers) }
        let mine = best[gesture] ?? 0
        if let top = best.max(by: { $0.value < $1.value }), top.key != gesture, top.value > mine { return .other(top.key) }
        let minimum: Double
        switch gesture {
        case .swipe: minimum = 0.02
        case .pinch: minimum = 0.01
        }
        guard mine >= minimum else { return .tooSmall }
        let size = (mine * 10_000).rounded() / 10_000
        examples.append(size)
        return .accepted(size)
    }

    /// The fingers' mean distance to their centre.
    private static func spread(_ touches: [Touch]) -> Double {
        let n = Double(touches.count)
        let cx = touches.map(\.x).reduce(0, +) / n
        let cy = touches.map(\.y).reduce(0, +) / n
        return touches.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / n
    }
}
