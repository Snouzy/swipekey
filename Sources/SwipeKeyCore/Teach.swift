import Foundation

/// Teaching a gesture from examples, like enrolling a fingerprint: the user does it five times the
/// way they usually do, and the gesture gets its own distance from them.
public enum Teach {
    /// The share of the smallest example the gesture then needs: every example clears it well.
    public static let fraction = 0.6

    /// The distance proposed for `gesture` from its examples, against the `current` global value.
    /// An example under half the median is a slip, not the user's way, and is left out.
    public static func proposal(for gesture: Gesture, examples: [Double], current: Double) -> Double {
        let sorted = examples.sorted()
        guard !sorted.isEmpty else { return current }
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        let smallest = sorted.first { $0 >= median / 2 } ?? sorted[0]
        let raw = (smallest * fraction * 1000).rounded() / 1000
        return effective(raw, for: gesture, global: current)
    }

    /// A taught value as it applies next to the `global` one, whenever either changes: 3+ fingers
    /// never stricter than the global (teaching must not add misses), never under the settings'
    /// lowest value; 2 fingers never more eager than the global (they compete with scrolling and
    /// zooming), never over a ceiling.
    public static func effective(_ taught: Double, for gesture: Gesture, global: Double) -> Double {
        let (floor, ceiling): (Double, Double)
        switch gesture {
        case .swipe: (floor, ceiling) = (0.04, 0.25)
        case .pinch: (floor, ceiling) = (0.02, 0.15)
        }
        if gesture.fingers >= 3 { return max(min(taught, global), min(floor, global)) }
        return max(min(taught, max(ceiling, global)), global)
    }
}

/// One teaching run: feed it the trackpad's frames; at the end of each touch it says whether that
/// was a good example of the gesture, and why not. An example counts when the real recognizer
/// fires on it (so a resting thumb, an early lift or the 2-finger quickness rule are judged as in
/// everyday use); its size is the recognizer's own measure.
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
        /// A 2-finger swipe too slow or long to be told from a scroll.
        case tooSlow
        /// Far enough but drifting, or fingers not moving together.
        case notStraight
    }

    public static let examplesNeeded = 5

    public let gesture: Gesture
    public private(set) var examples: [Double] = []
    public var isDone: Bool { examples.count >= Self.examplesNeeded }

    /// The recognizer as in everyday use, bound to this gesture only, firing at the minimum size.
    private let swipe: SwipeRecognizer?
    private let pinch: PinchRecognizer?
    private let minimum: Double

    // The touch in progress.
    private var fired = false
    private var size = 0.0
    private var maxFingers = 0
    private var starts: [Int: (x: Double, y: Double)] = [:]
    private var startSpread = 0.0
    /// The largest movement seen for each gesture, at the gesture's finger count: for the reason
    /// an attempt didn't count.
    private var best: [Gesture: Double] = [:]

    public init(gesture: Gesture) {
        self.gesture = gesture
        let only: IsBound = { $0 == gesture }
        switch gesture {
        case .swipe:
            minimum = 0.02
            swipe = SwipeRecognizer(threshold: minimum, isBound: only)
            pinch = nil
        case .pinch:
            minimum = 0.01
            swipe = nil
            pinch = PinchRecognizer(threshold: minimum, isBound: only)
        }
    }

    public mutating func observe(_ frame: TouchFrame) -> Feedback? {
        let gestures = (swipe?.process(frame) ?? []) + (pinch?.process(frame) ?? [])
        if gestures.contains(gesture) { fired = true }
        size = max(size, recognizerSize())

        let active = frame.touches.filter(\.isTouching)
        guard !active.isEmpty else { return finishTouch() }
        maxFingers = max(maxFingers, active.count)
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

    /// How far the recognizer has measured the movement toward this gesture.
    private func recognizerSize() -> Double {
        switch gesture {
        case let .swipe(_, direction):
            guard let travel = swipe?.travel else { return 0 }
            switch direction {
            case .up: return travel.dy
            case .down: return -travel.dy
            case .right: return travel.dx
            case .left: return -travel.dx
            }
        case let .pinch(_, direction):
            let change = pinch?.spreadChange ?? 0
            return direction == .in ? -change : change
        }
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
            fired = false
            size = 0
            maxFingers = 0
            starts = [:]
            best = [:]
        }
        guard maxFingers >= 2, !isDone else { return nil }
        if fired, size >= minimum {
            let rounded = (size * 10_000).rounded() / 10_000
            examples.append(rounded)
            return .accepted(rounded)
        }
        guard maxFingers == gesture.fingers else { return .wrongFingers(maxFingers) }
        let mine = best[gesture] ?? 0
        if let top = best.max(by: { $0.value < $1.value }), top.key != gesture, top.value > mine { return .other(top.key) }
        guard mine >= minimum else { return .tooSmall }
        if case .swipe(2, _) = gesture { return .tooSlow }
        return .notStraight
    }

    /// The fingers' mean distance to their centre.
    private static func spread(_ touches: [Touch]) -> Double {
        let n = Double(touches.count)
        let cx = touches.map(\.x).reduce(0, +) / n
        let cy = touches.map(\.y).reduce(0, +) / n
        return touches.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / n
    }
}
