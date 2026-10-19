/// How long the number of fingers on the pad has stayed the same. Fingers land over tens of
/// milliseconds, so a gesture with fewer fingers waits for the count to hold before it fires
/// when a gesture with more fingers could still be starting (libinput waits 100 ms too).
struct FingerSettle {
    var settle: Double
    private(set) var count = 0
    private var since = 0.0

    init(settle: Double) { self.settle = settle }

    mutating func observe(count: Int, at time: Double) {
        guard count != self.count else { return }
        self.count = count
        since = time
    }

    /// True once `count` fingers have been touching for at least `settle` seconds.
    func held(_ count: Int, at time: Double) -> Bool {
        count == self.count && time - since >= settle
    }
}

extension Gesture {
    /// Every gesture with this many fingers, for asking whether any of them is bound.
    static func all(fingers: Int) -> [Gesture] {
        Direction.allCases.map { .swipe(fingers: fingers, direction: $0) }
            + PinchDirection.allCases.map { .pinch(fingers: fingers, direction: $0) }
    }
}

/// True when a gesture with more than `fingers` fingers is bound: the hand may still be landing.
func largerGestureBound(than fingers: Int, _ isBound: IsBound) -> Bool {
    guard fingers < 5 else { return false }
    return (fingers + 1...5).contains { count in Gesture.all(fingers: count).contains(where: isBound) }
}
