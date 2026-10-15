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
            return []
        }

        guard !firedThisSession, fingerCount >= 2, let origin else { return [] }

        let dx = centroid.x - origin.x
        let dy = centroid.y - origin.y
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
        firedThisSession = false
    }
}
