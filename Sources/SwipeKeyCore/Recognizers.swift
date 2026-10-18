import Foundation

/// Turns a stream of touch frames from one device into gestures.
/// Each device gets its own instances, so recognizers can keep state freely.
public protocol GestureRecognizer: AnyObject {
    func process(_ frame: TouchFrame) -> [Gesture]
}

/// Emits `.swipe` when every finger on the pad moves together past `threshold`.
/// Fires at most once per touch session (until all fingers are lifted).
public final class SwipeRecognizer: GestureRecognizer {
    /// Distance the fingers' centroid must travel, in normalized trackpad units (0...1).
    public var threshold: Double
    /// The dominant axis must be this many times larger than the other one.
    public var axisRatio: Double

    /// How far the fingers' centroid has moved since they settled, for showing progress.
    public private(set) var travel: (dx: Double, dy: Double) = (0, 0)

    private var fingerCount = 0
    private var origin: (x: Double, y: Double)?
    private var firedThisSession = false

    public init(threshold: Double = 0.12, axisRatio: Double = 1.5) {
        self.threshold = threshold
        self.axisRatio = axisRatio
    }

    public func process(_ frame: TouchFrame) -> [Gesture] {
        let active = frame.touches.filter(\.isTouching)
        guard !active.isEmpty else {
            reset()
            return []
        }

        let centroid = (
            x: active.map(\.x).reduce(0, +) / Double(active.count),
            y: active.map(\.y).reduce(0, +) / Double(active.count)
        )

        // Fingers rarely land at the exact same frame: restart measuring whenever the count changes.
        if active.count != fingerCount {
            fingerCount = active.count
            origin = centroid
            travel = (0, 0)
            return []
        }

        guard let origin else { return [] }
        let dx = centroid.x - origin.x
        let dy = centroid.y - origin.y
        travel = (dx, dy)
        guard !firedThisSession, fingerCount >= 2 else { return [] }

        let direction: Direction
        if abs(dy) >= threshold, abs(dy) >= abs(dx) * axisRatio {
            direction = dy > 0 ? .up : .down
        } else if abs(dx) >= threshold, abs(dx) >= abs(dy) * axisRatio {
            direction = dx > 0 ? .right : .left
        } else {
            return []
        }

        firedThisSession = true
        return [.swipe(fingers: fingerCount, direction: direction)]
    }

    private func reset() {
        fingerCount = 0
        origin = nil
        travel = (0, 0)
        firedThisSession = false
    }
}

/// Emits `.pinch` when the fingers move toward each other (`in`) or apart (`out`) past `threshold`,
/// while their centroid stays roughly in place. Fires at most once per touch session.
public final class PinchRecognizer: GestureRecognizer {
    /// Change in the fingers' mean distance to their centroid, in normalized trackpad units (0...1).
    public var threshold: Double
    /// The spread change must be this many times larger than the centroid's travel, so a swipe
    /// whose fingers drift together doesn't count as a pinch.
    public var dominance: Double

    /// How much the fingers' spread has changed since they settled (negative: closing in).
    public private(set) var spreadChange: Double = 0

    private var fingerCount = 0
    private var origin: (x: Double, y: Double, spread: Double)?
    private var firedThisSession = false

    public init(threshold: Double = 0.05, dominance: Double = 1.5) {
        self.threshold = threshold
        self.dominance = dominance
    }

    public func process(_ frame: TouchFrame) -> [Gesture] {
        let active = frame.touches.filter(\.isTouching)
        guard !active.isEmpty else {
            reset()
            return []
        }

        let n = Double(active.count)
        let cx = active.map(\.x).reduce(0, +) / n
        let cy = active.map(\.y).reduce(0, +) / n
        let spread = active.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / n

        // Same as swipes: restart measuring whenever the finger count changes.
        if active.count != fingerCount {
            fingerCount = active.count
            origin = (cx, cy, spread)
            spreadChange = 0
            return []
        }

        guard let origin else { return [] }
        let change = spread - origin.spread
        spreadChange = change
        guard !firedThisSession, fingerCount >= 2 else { return [] }

        let travel = hypot(cx - origin.x, cy - origin.y)
        guard abs(change) >= threshold, abs(change) >= travel * dominance else { return [] }

        firedThisSession = true
        return [.pinch(fingers: fingerCount, direction: change < 0 ? .in : .out)]
    }

    private func reset() {
        fingerCount = 0
        origin = nil
        spreadChange = 0
        firedThisSession = false
    }
}
