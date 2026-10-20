import Foundation

/// Turns a stream of touch frames from one device into gestures.
/// Each device gets its own instances, so recognizers can keep state freely.
public protocol GestureRecognizer: AnyObject {
    func process(_ frame: TouchFrame) -> [Gesture]
    /// The near miss of the touch session that just ended, once (see `NearMiss`).
    func takeNearMiss() -> NearMiss?
}

/// Whether a gesture has a binding right now. A recognizer only fires (and stops for the rest of
/// the touch session) on bound gestures: an unbound 2-finger swipe must not swallow the 3-finger
/// swipe it turns into when the third finger lands.
public typealias IsBound = (Gesture) -> Bool

/// A 3+ finger swipe that came close but didn't fire, and why: written to the log, so misses in
/// everyday use can be seen and tuned.
public struct NearMiss: Equatable, CustomStringConvertible {
    public enum Reason: String {
        case tooShort = "too short"
        case drifted = "drifted sideways"
        case fingersDisagree = "fingers moved apart"
        case unbound = "no binding"
    }

    public let gesture: Gesture
    public let traveled: Double
    public let needed: Double
    public let reason: Reason

    public var description: String {
        String(format: "%@: %.3f of %.3f (%@)", gesture.description, traveled, needed, reason.rawValue)
    }
}

extension GestureRecognizer {
    /// Recognizers that don't report near misses.
    public func takeNearMiss() -> NearMiss? { nil }
}

/// Emits `.swipe` when every finger on the pad moves together past `threshold`.
/// Fires at most once per touch session (until all fingers are lifted).
public final class SwipeRecognizer: GestureRecognizer {
    /// Distance the fingers must travel together, in normalized trackpad units (0...1).
    public var threshold: Double
    /// Gestures with their own distance (taught), instead of `threshold`.
    public var thresholds: [Gesture: Double] = [:]
    /// For 2-finger swipes, the dominant axis must be this many times longer than the other one,
    /// on real lengths (x scaled by the trackpad's aspect). Stricter than for 3+ fingers: a
    /// diagonal 2-finger movement is a scroll.
    public var axisRatio: Double
    /// The same for 3+ fingers. Hands drift: a swipe right often heads down a little.
    public var physicalAxisRatio: Double
    /// A fast 3+ finger flick fires after `flickFraction` of the threshold, when it moves at
    /// `flickSpeed` (trackpad units per second, over the last `flickWindow` seconds) or faster.
    public var flickFraction: Double
    public var flickSpeed: Double
    public var flickWindow: Double
    /// Every finger must move the swipe's way by at least this share of the distance needed, so
    /// fingers spreading or turning aren't read as a swipe.
    public var agreeFraction: Double

    /// How far the fingers have moved since they settled (the mean of each finger's own
    /// movement, so a finger lifting doesn't make it jump), for showing progress.
    public private(set) var travel: (dx: Double, dy: Double) = (0, 0)

    private let isBound: IsBound
    /// The finger count being measured. With 3+ fingers it stays when fingers lift early.
    private var fingerCount = 0
    /// Where each measured finger was when the measure started.
    private var starts: [Int: (x: Double, y: Double)] = [:]
    /// Fingers already lifted from a 3+ finger measure: no finger can still land, so no wait.
    private var lifting = false
    /// When the first finger lifted. An early lift is the hand leaving: it gets `liftWindow` to
    /// finish the swipe, so 2 fingers scrolling on after a brushing third one can't carry it.
    private var liftedAt = 0.0
    public var liftWindow = 0.1
    private var firedThisSession = false
    /// Finger count of an unbound gesture already done this session: after it, a gesture with
    /// fewer fingers is the hand lifting, not a new swipe, so it can't fire.
    private var unboundAt: Int?

    private var settle: FingerSettle
    /// When each touching finger landed, and where every finger was when the latest one landed:
    /// for spotting a finger (often the thumb) resting on the pad while the others swipe.
    private var landedAt: [Int: Double] = [:]
    private var anchor: [Int: (x: Double, y: Double)] = [:]
    private var lastLanding = 0.0
    /// A resting finger was down this long before the others landed, and moved less than this.
    private let restLead = 0.15, restSlack = 0.02
    /// Two-finger swipes are the same movement as horizontal scrolling, so they only fire when
    /// the fingers lift, for a quick (≥ `twoFingerMinSpeed` units/s), short (≤ `twoFingerMaxDuration`)
    /// swipe whose two fingers landed together (≤ `twoFingerLandingSpread` apart). Measured on
    /// Mathias's trackpad: swipes 1.2–2 units/s in 0.07–0.17 s, fingers ≤ 0.016 s apart;
    /// scrolling 0.3–0.45 units/s, one finger down 0.2–1.9 s before the other.
    public var twoFingerMinSpeed = 0.8, twoFingerMaxDuration = 0.35, twoFingerLandingSpread = 0.15
    private var measureStart = 0.0, lastTime = 0.0
    private var landedTogether = false
    /// The 2-finger swipe the fingers have done so far, fired if they lift now.
    private var twoFingerReady: (gesture: Gesture, along: Double)?
    /// The closest attempt of the session so far, and the one of the session that just ended.
    private var closestMiss: NearMiss?
    private var endedMiss: NearMiss?
    /// Recent travel, for the flick speed.
    private var samples: [(time: Double, dx: Double, dy: Double)] = []

    public init(
        threshold: Double = 0.12, axisRatio: Double = 2.0, isBound: @escaping IsBound = { _ in true }, settle: Double = 0.1,
        flickFraction: Double = 0.5, flickSpeed: Double = 1.0, flickWindow: Double = 0.05, agreeFraction: Double = 0.25,
        physicalAxisRatio: Double = 1.2
    ) {
        self.threshold = threshold
        self.axisRatio = axisRatio
        self.physicalAxisRatio = physicalAxisRatio
        self.isBound = isBound
        self.settle = FingerSettle(settle: settle)
        self.flickFraction = flickFraction
        self.flickSpeed = flickSpeed
        self.flickWindow = flickWindow
        self.agreeFraction = agreeFraction
    }

    public func process(_ frame: TouchFrame) -> [Gesture] {
        let touching = frame.touches.filter(\.isTouching)
        trackLandings(touching, at: frame.timestamp)
        var active = touching
        // A resting finger is left out, as if lifted, when 3+ fingers still swipe without it: a
        // thumb on the pad must not turn a 3-finger swipe into a 4-finger one. Never below 3, so
        // it can't make a 2-finger swipe out of thumb + 2 fingers.
        if touching.count >= 4, let resting = restingFinger(in: touching) {
            active.removeAll { $0.identifier == resting }
        }
        settle.observe(count: active.count, at: frame.timestamp)
        // Fewer than 2 fingers end the session (a resting finger may stay down between swipes).
        guard active.count >= 2 else {
            let lifted = takeTwoFingerSwipe()
            reset()
            return lifted
        }

        let known = active.allSatisfy { starts[$0.identifier] != nil }
        // A 3+ finger swipe keeps its measure while fingers lift one by one (an early lift). Any
        // other change (a finger landing, a 2-finger touch losing one) starts measuring anew.
        let earlyLift = known && fingerCount >= 3 && active.count < fingerCount && active.count >= 2
        if !earlyLift && (!known || active.count != fingerCount) {
            fingerCount = active.count
            starts = Dictionary(active.map { ($0.identifier, (x: $0.x, y: $0.y)) }, uniquingKeysWith: { first, _ in first })
            lifting = false
            travel = (0, 0)
            samples = [(frame.timestamp, 0, 0)]
            measureStart = frame.timestamp
            lastTime = frame.timestamp
            twoFingerReady = nil
            let landings = active.compactMap { landedAt[$0.identifier] }
            landedTogether = (landings.max() ?? 0) - (landings.min() ?? 0) <= twoFingerLandingSpread
            return []
        }
        if earlyLift, !lifting {
            lifting = true
            liftedAt = frame.timestamp
        }

        var dx = 0.0, dy = 0.0
        for touch in active {
            guard let start = starts[touch.identifier] else { continue }
            dx += touch.x - start.x
            dy += touch.y - start.y
        }
        dx /= Double(active.count)
        dy /= Double(active.count)
        travel = (dx, dy)
        samples.append((frame.timestamp, dx, dy))
        lastTime = frame.timestamp
        while samples.count > 2, samples[1].time <= frame.timestamp - flickWindow { samples.removeFirst() }
        guard !firedThisSession, fingerCount >= 2, fingerCount >= (unboundAt ?? 0) else { return [] }
        if lifting, frame.timestamp - liftedAt > liftWindow { return [] }

        // Directions on real lengths, with a stricter ratio for 2-finger swipes.
        let ratio = fingerCount >= 3 ? physicalAxisRatio : axisRatio
        let width = abs(dx) * frame.aspect
        let vertical = abs(dy) >= width
        let straight = vertical ? abs(dy) >= width * ratio : width >= abs(dy) * ratio
        let along = vertical ? abs(dy) : abs(dx)
        let direction: Direction = vertical ? (dy > 0 ? .up : .down) : (dx > 0 ? .right : .left)
        let gesture = Gesture.swipe(fingers: fingerCount, direction: direction)
        let distance = thresholds[gesture] ?? threshold
        let needed = fingerCount >= 3 && speed(vertical: vertical) >= flickSpeed ? distance * flickFraction : distance
        let sign: Double = (vertical ? dy : dx) > 0 ? 1 : -1
        let agree = active.allSatisfy { touch in
            guard let start = starts[touch.identifier] else { return false }
            let own = vertical ? touch.y - start.y : touch.x - start.x
            return own * sign >= needed * agreeFraction
        }
        let bound = isBound(gesture)

        guard along > 0, along >= needed, straight, agree, bound else {
            twoFingerReady = nil
            if along >= needed, straight, agree { unboundAt = fingerCount }
            noteMiss(gesture, along: along, needed: needed, reason:
                !bound ? .unbound : !straight ? .drifted : !agree ? .fingersDisagree : .tooShort)
            return []
        }
        if fingerCount == 2 {
            twoFingerReady = (gesture, along)
            return []
        }
        // Another finger may still land: wait until the count has held, measuring on.
        if !lifting, largerGestureBound(than: fingerCount, isBound), !settle.held(fingerCount, at: frame.timestamp) { return [] }
        firedThisSession = true
        return [gesture]
    }

    /// The 2-finger swipe done when the fingers lift, if it was quick, short and together.
    private func takeTwoFingerSwipe() -> [Gesture] {
        defer { twoFingerReady = nil }
        guard fingerCount == 2, !firedThisSession, landedTogether, let ready = twoFingerReady else { return [] }
        let duration = lastTime - measureStart
        guard duration > 0, duration <= twoFingerMaxDuration, ready.along / duration >= twoFingerMinSpeed else { return [] }
        firedThisSession = true
        return [ready.gesture]
    }

    /// Keeps the closest 3+ finger attempt of the session, reported if the session ends unfired.
    private func noteMiss(_ gesture: Gesture, along: Double, needed: Double, reason: NearMiss.Reason) {
        guard fingerCount >= 3, needed > 0, along >= needed * 0.5 else { return }
        if let best = closestMiss, best.traveled / best.needed >= along / needed { return }
        closestMiss = NearMiss(gesture: gesture, traveled: along, needed: needed, reason: reason)
    }

    public func takeNearMiss() -> NearMiss? {
        defer { endedMiss = nil }
        return endedMiss
    }

    private func trackLandings(_ touching: [Touch], at time: Double) {
        let ids = Set(touching.map(\.identifier))
        landedAt = landedAt.filter { ids.contains($0.key) }
        var landed = false
        for touch in touching where landedAt[touch.identifier] == nil {
            landedAt[touch.identifier] = time
            landed = true
        }
        if landed {
            lastLanding = time
            anchor = Dictionary(touching.map { ($0.identifier, (x: $0.x, y: $0.y)) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The one finger that was down well before the others landed and has stayed still since.
    private func restingFinger(in touching: [Touch]) -> Int? {
        let early = touching.filter { (landedAt[$0.identifier] ?? lastLanding) <= lastLanding - restLead }
        guard early.count == 1, let finger = early.first, let start = anchor[finger.identifier] else { return nil }
        return hypot(finger.x - start.x, finger.y - start.y) < restSlack ? finger.identifier : nil
    }

    /// Speed along the axis, in the direction travelled, over the last `flickWindow` seconds.
    /// Zero when the samples span no time.
    private func speed(vertical: Bool) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let elapsed = last.time - first.time
        guard elapsed > 0 else { return 0 }
        let moved = vertical ? last.dy - first.dy : last.dx - first.dx
        let heading = vertical ? last.dy : last.dx
        return (heading < 0 ? -moved : moved) / elapsed
    }

    private func reset() {
        if !firedThisSession, let closestMiss { endedMiss = closestMiss }
        closestMiss = nil
        samples = []
        fingerCount = 0
        starts = [:]
        lifting = false
        travel = (0, 0)
        firedThisSession = false
        unboundAt = nil
    }
}

/// Emits `.pinch` when the fingers move toward each other (`in`) or apart (`out`) past `threshold`,
/// while their centroid stays roughly in place. Fires at most once per touch session.
public final class PinchRecognizer: GestureRecognizer {
    /// Change in the fingers' mean distance to their centroid, in normalized trackpad units (0...1).
    public var threshold: Double
    /// Gestures with their own spread change (taught), instead of `threshold`.
    public var thresholds: [Gesture: Double] = [:]
    /// The spread change must be this many times larger than the centroid's travel, so a swipe
    /// whose fingers drift together doesn't count as a pinch.
    public var dominance: Double

    /// How much the fingers' spread has changed since they settled (negative: closing in).
    public private(set) var spreadChange: Double = 0

    private let isBound: IsBound
    private var fingerCount = 0
    private var origin: (x: Double, y: Double, spread: Double)?
    private var firedThisSession = false
    /// As for swipes: after an unbound pinch, fewer fingers can't fire.
    private var unboundAt: Int?

    private var settle: FingerSettle

    public init(threshold: Double = 0.05, dominance: Double = 1.5, isBound: @escaping IsBound = { _ in true }, settle: Double = 0.1) {
        self.threshold = threshold
        self.dominance = dominance
        self.isBound = isBound
        self.settle = FingerSettle(settle: settle)
    }

    public func process(_ frame: TouchFrame) -> [Gesture] {
        let active = frame.touches.filter(\.isTouching)
        settle.observe(count: active.count, at: frame.timestamp)
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
        guard !firedThisSession, fingerCount >= 2, fingerCount >= (unboundAt ?? 0) else { return [] }

        let travel = hypot(cx - origin.x, cy - origin.y)
        let gesture = Gesture.pinch(fingers: fingerCount, direction: change < 0 ? .in : .out)
        guard abs(change) >= thresholds[gesture] ?? threshold, abs(change) >= travel * dominance else { return [] }

        guard isBound(gesture) else {
            unboundAt = fingerCount
            return []
        }
        if largerGestureBound(than: fingerCount, isBound), !settle.held(fingerCount, at: frame.timestamp) { return [] }
        firedThisSession = true
        return [gesture]
    }

    private func reset() {
        fingerCount = 0
        origin = nil
        spreadChange = 0
        firedThisSession = false
        unboundAt = nil
    }
}
