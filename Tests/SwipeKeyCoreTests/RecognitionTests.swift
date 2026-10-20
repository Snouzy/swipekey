import CoreGraphics
import XCTest
@testable import SwipeKeyCore

/// Builds touch frames on a clock, for the recognition rules that depend on time.
struct Hand {
    var time = 0.0
    /// Fingers spaced 0.1 apart from x = 0.3, at y = 0.4, moved by (dx, dy).
    static func fingers(_ count: Int, dx: Double = 0, dy: Double = 0, first id: Int = 0) -> [Touch] {
        (0..<count).map { Touch(x: 0.3 + Double($0) * 0.1 + dx, y: 0.4 + dy, identifier: id + $0) }
    }

    mutating func frame(_ touches: [Touch], at time: Double? = nil, advance: Double = 1.0 / 120) -> TouchFrame {
        if let time { self.time = time } else { self.time += advance }
        return TouchFrame(touches: touches, timestamp: self.time)
    }
}

/// Runs frames through a recognizer and collects everything it fires.
func feed(_ recognizer: GestureRecognizer, _ frames: [TouchFrame]) -> [Gesture] {
    frames.flatMap { recognizer.process($0) }
}

func only(_ gestures: Gesture...) -> IsBound {
    let set = Set(gestures)
    return { set.contains($0) }
}

final class BoundGestureTests: XCTestCase {
    func testUnboundTwoFingerSwipeDoesNotBlockThreeFinger() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: only(.swipe(fingers: 3, direction: .up)))
        let fired = feed(r, [
            hand.frame(Hand.fingers(2)),
            hand.frame(Hand.fingers(2, dy: 0.06)),
            hand.frame(Hand.fingers(3, dy: 0.06)),
            hand.frame(Hand.fingers(3, dy: 0.12)),
        ])
        XCTAssertEqual(fired, [.swipe(fingers: 3, direction: .up)])
    }

    /// Real session #143: after an unbound 4-finger swipe, the 3 fingers left slid down while
    /// lifting. That must not fire the 3-finger swipe down (⌘W).
    func testUnboundGestureStillBlocksFewerFingersAfter() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: only(.swipe(fingers: 3, direction: .down)))
        let fired = feed(r, [
            hand.frame(Hand.fingers(4)),
            hand.frame(Hand.fingers(4, dy: 0.1)),
            hand.frame(Hand.fingers(3, dy: 0.1)),
            hand.frame(Hand.fingers(3, dy: 0.0)),
        ])
        XCTAssertEqual(fired, [])
    }

    func testUnboundGestureNeverFires() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: { _ in false })
        XCTAssertEqual(feed(r, [hand.frame(Hand.fingers(3)), hand.frame(Hand.fingers(3, dy: 0.3))]), [])
    }

    func testModifierOnlyBindingDoesNotLockWithoutModifier() throws {
        let engine = try Engine(config: Config(bindings: [
            Binding(gesture: .swipe(fingers: 3, direction: .up), holding: ["cmd"], action: harmless),
            Binding(gesture: .swipe(fingers: 3, direction: .right), action: harmless),
        ]), heldModifiers: { [] })
        let fired = expectation(description: "right fires")
        engine.onGesture = { trigger in
            XCTAssertEqual(trigger.gesture, .swipe(fingers: 3, direction: .right))
            fired.fulfill()
        }
        var hand = Hand()
        for touches in [Hand.fingers(3), Hand.fingers(3, dy: 0.15), Hand.fingers(3, dx: 0.4, dy: 0.15)] {
            engine.handle(hand.frame(touches), device: 1)
        }
        wait(for: [fired], timeout: 1)
    }

    func testReloadMidSwipeStartsOver() throws {
        let config = Config(
            swipeThreshold: 0.1,
            bindings: [Binding(gesture: .swipe(fingers: 3, direction: .up), action: harmless)]
        )
        let engine = try Engine(config: config, heldModifiers: { [] })
        let fired = expectation(description: "nothing fires")
        fired.isInverted = true
        engine.onGesture = { _ in fired.fulfill() }
        var hand = Hand()
        engine.handle(hand.frame(Hand.fingers(3)), device: 1)
        engine.handle(hand.frame(Hand.fingers(3, dy: 0.04)), device: 1)
        try engine.reload(config)
        engine.handle(hand.frame(Hand.fingers(3, dy: 0.1)), device: 1)
        wait(for: [fired], timeout: 0.2)
    }
}

final class SettleTests: XCTestCase {
    private let lefts = only(.swipe(fingers: 2, direction: .left), .swipe(fingers: 3, direction: .left))

    func testThirdFingerLandingLateWinsOverBoundTwoFingerSwipe() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: lefts)
        let fired = feed(r, [
            hand.frame(Hand.fingers(2), at: 0),
            hand.frame(Hand.fingers(2, dx: -0.03), at: 0.015),
            hand.frame(Hand.fingers(2, dx: -0.06), at: 0.03),
            hand.frame(Hand.fingers(3, dx: -0.06), at: 0.04),
            hand.frame(Hand.fingers(3, dx: -0.09), at: 0.07),
            hand.frame(Hand.fingers(3, dx: -0.12), at: 0.10),
        ])
        XCTAssertEqual(fired, [.swipe(fingers: 3, direction: .left)])
    }

    /// With a 3-finger swipe bound too, a 2-finger swipe still fires: when the fingers lift.
    func testTwoFingerSwipeFiresOnLiftWhenLargerIsBound() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: lefts)
        XCTAssertEqual(feed(r, [hand.frame(Hand.fingers(2), at: 0), hand.frame(Hand.fingers(2, dx: -0.12), at: 0.08)]), [])
        XCTAssertEqual(r.process(hand.frame([], at: 0.1)), [.swipe(fingers: 2, direction: .left)])
    }

    func testNoWaitWhenNoLargerGestureIsBound() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: only(.swipe(fingers: 3, direction: .up)))
        XCTAssertEqual(r.process(hand.frame(Hand.fingers(3), at: 0)), [])
        XCTAssertEqual(r.process(hand.frame(Hand.fingers(3, dy: 0.06), at: 0.02)), [.swipe(fingers: 3, direction: .up)])
    }
}

final class EarlyLiftTests: XCTestCase {
    func testEarlyLiftKeepsThreeFingerTravel() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.1, isBound: only(.swipe(fingers: 3, direction: .up)))
        let lifted = Array(Hand.fingers(3, dy: 0.06).dropFirst())
        let fired = feed(r, [
            hand.frame(Hand.fingers(3)),
            hand.frame(Hand.fingers(3, dy: 0.06)),
            hand.frame(lifted),
            hand.frame(lifted.map { var t = $0; t.y += 0.06; return t }),
        ])
        XCTAssertEqual(fired, [.swipe(fingers: 3, direction: .up)])
    }

    func testTwoFingerSessionStillRestartsOnLift() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.1, isBound: only(.swipe(fingers: 2, direction: .up)))
        let fired = feed(r, [
            hand.frame(Hand.fingers(2), at: 0),
            hand.frame(Hand.fingers(2, dy: 0.06), at: 0.2),
            hand.frame([Hand.fingers(2, dy: 0.06)[1]], at: 0.25),
            hand.frame([Hand.fingers(2, dy: 0.12)[1]], at: 0.3),
        ])
        XCTAssertEqual(fired, [])
    }

    func testLiftDoesNotFakeMovement() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.1, isBound: only(.swipe(fingers: 3, direction: .down)))
        let spread = [Touch(x: 0.3, y: 0.3, identifier: 0), Touch(x: 0.4, y: 0.3, identifier: 1), Touch(x: 0.5, y: 0.6, identifier: 2)]
        XCTAssertEqual(feed(r, [hand.frame(spread), hand.frame(spread), hand.frame(Array(spread.prefix(2)))]), [])
        XCTAssertEqual(r.travel.dx, 0, accuracy: 0.001)
        XCTAssertEqual(r.travel.dy, 0, accuracy: 0.001)
    }
}

final class FlickTests: XCTestCase {
    private func move(_ fingers: Int, dy: Double = 0, dx: Double = 0, over duration: Double, steps: Int = 4) -> [TouchFrame] {
        var hand = Hand()
        return (0...steps).map { i in
            let f = Double(i) / Double(steps)
            return hand.frame(Hand.fingers(fingers, dx: dx * f, dy: dy * f), at: duration * f)
        }
    }

    func testFastShortThreeFingerFlickFires() {
        let r = SwipeRecognizer(threshold: 0.1, isBound: only(.swipe(fingers: 3, direction: .up)))
        XCTAssertEqual(feed(r, move(3, dy: 0.06, over: 0.04)), [.swipe(fingers: 3, direction: .up)])
    }

    func testSlowShortThreeFingerMoveDoesNot() {
        let r = SwipeRecognizer(threshold: 0.1, isBound: only(.swipe(fingers: 3, direction: .up)))
        XCTAssertEqual(feed(r, move(3, dy: 0.06, over: 0.5)), [])
    }

    func testTwoFingerFlickDoesNotFire() {
        let r = SwipeRecognizer(threshold: 0.1, isBound: only(.swipe(fingers: 2, direction: .left)))
        var frames = move(2, dx: -0.06, over: 0.04)
        var hand = Hand(time: 0.2)
        frames.append(hand.frame(Hand.fingers(2, dx: -0.065), at: 0.2))
        XCTAssertEqual(feed(r, frames), [])
    }

    func testSameTimestampFramesNeverFlick() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.1, isBound: only(.swipe(fingers: 3, direction: .up)))
        let frames = [0.0, 0.03, 0.06].map { hand.frame(Hand.fingers(3, dy: $0), at: 1) }
        XCTAssertEqual(feed(r, frames), [])
        XCTAssertFalse(r.travel.dy.isNaN)
    }
}

final class AgreementTests: XCTestCase {
    private func three(_ dys: [Double]) -> [Touch] {
        dys.enumerated().map { Touch(x: 0.3 + Double($0) * 0.1, y: 0.4 + $1, identifier: $0) }
    }

    func testFingersMovingApartVerticallyIsNotASwipe() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.1, isBound: only(.swipe(fingers: 3, direction: .up)))
        XCTAssertEqual(feed(r, [hand.frame(three([0, 0, 0]), at: 0), hand.frame(three([0.2, 0.2, -0.05]), at: 0.3)]), [])
    }

    func testOneLaggingFingerStillCountsAboveFraction() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.1, isBound: only(.swipe(fingers: 3, direction: .up)))
        XCTAssertEqual(
            feed(r, [hand.frame(three([0, 0, 0]), at: 0), hand.frame(three([0.15, 0.15, 0.03]), at: 0.3)]),
            [.swipe(fingers: 3, direction: .up)]
        )
    }
}

final class AspectTests: XCTestCase {
    /// Mathias's trackpad: 124.8 × 76.8 mm.
    private let wide = 124.8 / 76.8

    private func swipe(_ fingers: Int, dx: Double, dy: Double, aspect: Double) -> [TouchFrame] {
        var hand = Hand()
        var frames = [hand.frame(Hand.fingers(fingers), at: 0), hand.frame(Hand.fingers(fingers, dx: dx, dy: dy), at: 0.3)]
        frames = frames.map { var f = $0; f.aspect = aspect; return f }
        return frames
    }

    private let all = only(
        .swipe(fingers: 3, direction: .right), .swipe(fingers: 3, direction: .down),
        .swipe(fingers: 2, direction: .left), .swipe(fingers: 2, direction: .up)
    )

    /// Real session #135: a swipe right that drifted down.
    func testDiagonalRightSwipeIsHorizontalOnAWideTrackpad() {
        let r = SwipeRecognizer(threshold: 0.05, isBound: all)
        XCTAssertEqual(feed(r, swipe(3, dx: 0.067, dy: -0.076, aspect: wide)), [.swipe(fingers: 3, direction: .right)])
    }

    func testSameMoveWithoutAspectFiresNothing() {
        let r = SwipeRecognizer(threshold: 0.05, isBound: all)
        XCTAssertEqual(feed(r, swipe(3, dx: 0.067, dy: -0.076, aspect: 1)), [])
    }

    /// 2-finger swipes need a straighter line than 3-finger ones (ratio 2 on real lengths): a
    /// diagonal one that a 3-finger swipe would accept stays a scroll. Both end with a quick lift.
    func testTwoFingerNeedsAStraighterSwipe() {
        let diagonal = swipe(2, dx: -0.12, dy: 0.11, aspect: wide) + [TouchFrame(touches: [], timestamp: 0.31, aspect: wide)]
        XCTAssertEqual(feed(SwipeRecognizer(threshold: 0.05, isBound: all), quick(diagonal)), [])
        let straight = swipe(2, dx: -0.12, dy: 0.03, aspect: wide) + [TouchFrame(touches: [], timestamp: 0.31, aspect: wide)]
        XCTAssertEqual(feed(SwipeRecognizer(threshold: 0.05, isBound: all), quick(straight)), [.swipe(fingers: 2, direction: .left)])
    }

    /// The same frames, 0.1 s long: quick enough for a 2-finger swipe.
    private func quick(_ frames: [TouchFrame]) -> [TouchFrame] {
        frames.map { var f = $0; f.timestamp /= 3; return f }
    }
}

final class RestingFingerTests: XCTestCase {
    private let thumb = Touch(x: 0.2, y: 0.1, identifier: 9)

    /// The thumb rests from t=0; three fingers land at t=0.5 and swipe up.
    private func swipe(from start: Double, ids first: Int, fingers: Int = 3, dx: Double = 0, dy: Double = 0.1) -> [TouchFrame] {
        var hand = Hand()
        return [
            hand.frame([thumb] + Hand.fingers(fingers, first: first), at: start),
            hand.frame([thumb] + Hand.fingers(fingers, dx: dx / 2, dy: dy / 2, first: first), at: start + 0.1),
            hand.frame([thumb] + Hand.fingers(fingers, dx: dx, dy: dy, first: first), at: start + 0.2),
            hand.frame([thumb], at: start + 0.25),
        ]
    }

    func testRestingFingerIsIgnored() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: only(.swipe(fingers: 3, direction: .up)))
        let frames = [hand.frame([thumb], at: 0), hand.frame([thumb], at: 0.4)] + swipe(from: 0.5, ids: 0)
        XCTAssertEqual(feed(r, frames), [.swipe(fingers: 3, direction: .up)])
    }

    func testRestingFingerDoesNotBlockNextSwipe() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: only(.swipe(fingers: 3, direction: .up)))
        let frames = [hand.frame([thumb], at: 0)] + swipe(from: 0.5, ids: 0) + swipe(from: 1.0, ids: 10)
        XCTAssertEqual(feed(r, frames), [.swipe(fingers: 3, direction: .up), .swipe(fingers: 3, direction: .up)])
    }

    /// Thumb plus two fingers going left must stay a 3-touch gesture: never ⌘← (2-finger left).
    func testRestingFingerNeverMakesATwoFingerSwipe() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: only(.swipe(fingers: 2, direction: .left)))
        let frames = [hand.frame([thumb], at: 0)] + swipe(from: 0.5, ids: 0, fingers: 2, dx: -0.15, dy: 0)
        XCTAssertEqual(feed(r, frames), [])
    }
}

final class NearMissTests: XCTestCase {
    private let up = only(.swipe(fingers: 3, direction: .up))

    private func session(_ fingers: Int, dx: Double = 0, dy: Double = 0, into r: SwipeRecognizer) {
        var hand = Hand()
        _ = feed(r, [
            hand.frame(Hand.fingers(fingers), at: 0),
            hand.frame(Hand.fingers(fingers, dx: dx / 2, dy: dy / 2), at: 0.3),
            hand.frame(Hand.fingers(fingers, dx: dx, dy: dy), at: 0.6),
            hand.frame([], at: 0.65),
        ])
    }

    func testShortSwipeReportsTooShort() throws {
        let r = SwipeRecognizer(threshold: 0.1, isBound: up)
        session(3, dy: 0.07, into: r)
        let miss = try XCTUnwrap(r.takeNearMiss())
        XCTAssertEqual(miss.gesture, .swipe(fingers: 3, direction: .up))
        XCTAssertEqual(miss.traveled, 0.07, accuracy: 0.001)
        XCTAssertEqual(miss.needed, 0.1, accuracy: 0.001)
        XCTAssertEqual(miss.reason, .tooShort)
        XCTAssertEqual(miss.description, "3-finger swipe up: 0.070 of 0.100 (too short)")
    }

    func testTinyMovementReportsNothing() {
        let r = SwipeRecognizer(threshold: 0.1, isBound: up)
        session(3, dy: 0.02, into: r)
        XCTAssertNil(r.takeNearMiss())
    }

    func testTwoFingerSessionReportsNothing() {
        let r = SwipeRecognizer(threshold: 0.1, isBound: only(.swipe(fingers: 2, direction: .up)))
        session(2, dy: 0.07, into: r)
        XCTAssertNil(r.takeNearMiss())
    }

    func testUnboundReported() throws {
        let r = SwipeRecognizer(threshold: 0.1, isBound: up)
        session(3, dx: -0.15, into: r)
        XCTAssertEqual(try XCTUnwrap(r.takeNearMiss()).reason, .unbound)
    }

    func testDriftReported() throws {
        let r = SwipeRecognizer(threshold: 0.1, isBound: up)
        session(3, dx: 0.13, dy: 0.15, into: r)
        XCTAssertEqual(try XCTUnwrap(r.takeNearMiss()).reason, .drifted)
    }

    func testReportedOnce() {
        let r = SwipeRecognizer(threshold: 0.1, isBound: up)
        session(3, dy: 0.07, into: r)
        XCTAssertNotNil(r.takeNearMiss())
        XCTAssertNil(r.takeNearMiss())
    }

    func testFiredSwipeReportsNothing() {
        let r = SwipeRecognizer(threshold: 0.1, isBound: up)
        session(3, dy: 0.2, into: r)
        XCTAssertNil(r.takeNearMiss())
    }
}

final class EngineNearMissTests: XCTestCase {
    func testEngineReportsNearMisses() throws {
        let engine = try Engine(config: Config(swipeThreshold: 0.1, bindings: swipeUpBound.bindings), heldModifiers: { [] })
        let reported = expectation(description: "near miss")
        engine.onNearMiss = { miss in
            XCTAssertEqual(miss.reason, .tooShort)
            reported.fulfill()
        }
        var hand = Hand()
        for frame in [hand.frame(Hand.fingers(3), at: 0), hand.frame(Hand.fingers(3, dy: 0.07), at: 0.5), hand.frame([], at: 0.6)] {
            engine.handle(frame, device: 1)
        }
        wait(for: [reported], timeout: 1)
    }
}

/// Two-finger swipes look like horizontal scrolling: they fire when the fingers lift, and only
/// for a quick, short swipe with both fingers landing together.
final class TwoFingerLiftTests: XCTestCase {
    private let left = only(.swipe(fingers: 2, direction: .left))

    /// Two fingers landing at `land` (the second `lag` later), moving left by `dx` over `duration`, then lifting.
    private func swipe(dx: Double, over duration: Double, lag: Double = 0, back: Double? = nil) -> [TouchFrame] {
        var hand = Hand()
        let first = [Hand.fingers(2)[0]]
        var frames = [hand.frame(first, at: 0)]
        let start = lag
        for i in 0...4 {
            let f = Double(i) / 4
            frames.append(hand.frame(Hand.fingers(2, dx: dx * f), at: start + 0.001 + duration * f))
        }
        if let back { frames.append(hand.frame(Hand.fingers(2, dx: back), at: start + duration + 0.02)) }
        frames.append(hand.frame([], at: start + duration + 0.05))
        return frames
    }

    func testQuickTwoFingerSwipeFiresOnLift() {
        let r = SwipeRecognizer(threshold: 0.05, isBound: left)
        let frames = swipe(dx: -0.15, over: 0.1)
        XCTAssertEqual(feed(r, Array(frames.dropLast())), [], "nothing before the lift")
        XCTAssertEqual(r.process(frames.last!), [.swipe(fingers: 2, direction: .left)])
    }

    func testSlowScrollPieceDoesNotFire() {
        let r = SwipeRecognizer(threshold: 0.05, isBound: left)
        XCTAssertEqual(feed(r, swipe(dx: -0.07, over: 0.2)), [])
    }

    func testLongTwoFingerMoveDoesNotFire() {
        let r = SwipeRecognizer(threshold: 0.05, isBound: left)
        XCTAssertEqual(feed(r, swipe(dx: -0.5, over: 0.5)), [])
    }

    func testSecondFingerLandingLateDoesNotFire() {
        let r = SwipeRecognizer(threshold: 0.05, isBound: left)
        XCTAssertEqual(feed(r, swipe(dx: -0.15, over: 0.1, lag: 0.4)), [])
    }

    func testSwipeTakenBackBeforeLiftDoesNotFire() {
        let r = SwipeRecognizer(threshold: 0.05, isBound: left)
        XCTAssertEqual(feed(r, swipe(dx: -0.15, over: 0.1, back: -0.01)), [])
    }

    func testThirdFingerLandingCancelsTwoFingerSwipe() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: left)
        let fired = feed(r, [
            hand.frame(Hand.fingers(2), at: 0),
            hand.frame(Hand.fingers(2, dx: -0.1), at: 0.05),
            hand.frame(Hand.fingers(3, dx: -0.1), at: 0.06),
            hand.frame([], at: 0.1),
        ])
        XCTAssertEqual(fired, [])
    }
}

/// Final review: an early lift must not let a 2-finger scroll carry a 3-finger swipe.
final class EarlyLiftScrollTests: XCTestCase {
    private let mathias = FixtureTests.mathiasIsBound

    /// 2 fingers scroll down at 0.3 units/s for `seconds` from `start`.
    private func scroll(from start: Double, seconds: Double, y0: Double, hand: inout Hand) -> [TouchFrame] {
        stride(from: 0.0, through: seconds, by: 1.0 / 60).map { t in
            hand.frame(Hand.fingers(2, dy: y0 - 0.3 * t), at: start + t)
        }
    }

    func testFingerBrushingDuringTwoFingerScrollFiresNothing() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: mathias)
        var frames = scroll(from: 0, seconds: 0.5, y0: 0, hand: &hand)
        let brushed = Hand.fingers(2, dy: -0.15) + [Touch(x: 0.7, y: 0.2, identifier: 7)]
        frames.append(hand.frame(brushed, at: 0.52))
        frames.append(hand.frame(brushed, at: 0.55))
        frames += scroll(from: 0.56, seconds: 0.33, y0: -0.15, hand: &hand)
        frames.append(hand.frame([], at: 0.95))
        XCTAssertEqual(feed(r, frames), [])
    }

    func testThreeLandOneLiftsThenScrollFiresNothing() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.05, isBound: mathias)
        var frames = [hand.frame(Hand.fingers(3), at: 0), hand.frame(Hand.fingers(3), at: 0.1)]
        frames += scroll(from: 0.12, seconds: 0.4, y0: 0, hand: &hand)
        frames.append(hand.frame([], at: 0.6))
        XCTAssertEqual(feed(r, frames), [])
    }
}
