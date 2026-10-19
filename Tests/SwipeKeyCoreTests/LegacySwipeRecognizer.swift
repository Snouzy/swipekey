import Foundation
@testable import SwipeKeyCore

/// The swipe recognizer as it was before step 1 (commit cdea72f), frozen: it checks that the
/// frames rebuilt from the probe log give what the probe saw at the time.
final class LegacySwipeRecognizer: GestureRecognizer {
    /// Distance the fingers' centroid must travel, in normalized trackpad units (0...1).
    var threshold: Double
    /// The dominant axis must be this many times larger than the other one.
    var axisRatio: Double

    /// How far the fingers' centroid has moved since they settled, for showing progress.
    private(set) var travel: (dx: Double, dy: Double) = (0, 0)

    private var fingerCount = 0
    private var origin: (x: Double, y: Double)?
    private var firedThisSession = false

    init(threshold: Double = 0.12, axisRatio: Double = 1.5) {
        self.threshold = threshold
        self.axisRatio = axisRatio
    }

    func process(_ frame: TouchFrame) -> [Gesture] {
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

