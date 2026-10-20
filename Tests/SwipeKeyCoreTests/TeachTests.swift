import CoreGraphics
import XCTest
@testable import SwipeKeyCore

private let up3 = Gesture.swipe(fingers: 3, direction: .up)
private let left2 = Gesture.swipe(fingers: 2, direction: .left)
private let pinchIn2 = Gesture.pinch(fingers: 2, direction: .in)

/// Two fingers `gap` apart around (0.5, 0.4).
private func pair(_ gap: Double) -> [Touch] {
    [Touch(x: 0.5 - gap / 2, y: 0.4, identifier: 0), Touch(x: 0.5 + gap / 2, y: 0.4, identifier: 1)]
}

final class TaughtThresholdTests: XCTestCase {
    func testBindingKeepsItsThresholdInTheConfig() throws {
        let json = #"{"gesture":{"type":"swipe","fingers":3,"direction":"up"},"action":{"type":"key","key":"return"},"threshold":0.07}"#
        let binding = try JSONDecoder().decode(Binding.self, from: Data(json.utf8))
        XCTAssertEqual(binding.threshold, 0.07)
        let plain = Binding(gesture: up3, action: .key("return", modifiers: []))
        XCTAssertNil(plain.threshold)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("threshold"))
        XCTAssertEqual(try JSONDecoder().decode(Binding.self, from: JSONEncoder().encode(binding)), binding)
    }

    func testSwipeUsesTheGesturesOwnThreshold() {
        var hand = Hand()
        let r = SwipeRecognizer(threshold: 0.12, isBound: only(up3, .swipe(fingers: 3, direction: .left)))
        r.thresholds = [up3: 0.05]
        XCTAssertEqual(feed(r, [hand.frame(Hand.fingers(3)), hand.frame(Hand.fingers(3, dy: 0.06))]), [up3])
        let other = SwipeRecognizer(threshold: 0.12, isBound: only(up3, .swipe(fingers: 3, direction: .left)))
        other.thresholds = [up3: 0.05]
        hand = Hand()
        XCTAssertEqual(feed(other, [hand.frame(Hand.fingers(3)), hand.frame(Hand.fingers(3, dx: -0.05))]), [], "left keeps 0.12 (0.06 as a flick)")
    }

    func testPinchUsesTheGesturesOwnThreshold() {
        var hand = Hand()
        let r = PinchRecognizer(threshold: 0.1, isBound: only(pinchIn2))
        r.thresholds = [pinchIn2: 0.02]
        XCTAssertEqual(feed(r, [hand.frame(pair(0.3)), hand.frame(pair(0.24))]), [pinchIn2])
    }

    func testEngineBuildsTheSmallestTaughtThresholdPerGesture() throws {
        let engine = try Engine(config: Config(swipeThreshold: 0.12, bindings: [
            Binding(gesture: up3, action: harmless, threshold: 0.08),
            Binding(gesture: up3, holding: ["cmd"], action: harmless, threshold: 0.05),
        ]), heldModifiers: { [] })
        let fired = expectation(description: "up fires at 0.06")
        engine.onGesture = { _ in fired.fulfill() }
        var hand = Hand()
        engine.handle(hand.frame(Hand.fingers(3)), device: 1)
        engine.handle(hand.frame(Hand.fingers(3, dy: 0.06)), device: 1)
        wait(for: [fired], timeout: 1)
    }

    func testEngineRefusesAThresholdOutOfRange() {
        for bad in [0.0, -0.1, 1.0] {
            XCTAssertThrowsError(try Engine(config: Config(bindings: [Binding(gesture: up3, action: harmless, threshold: bad)])), "\(bad)")
        }
    }

    func testATaughtValueOnlyGoesWithItsGesture() {
        var draft = BindingDraft(Binding(gesture: up3, action: .key("return", modifiers: [])))
        draft.teach(0.04)
        XCTAssertEqual(draft.binding?.threshold, 0.04)
        draft.direction = .down
        XCTAssertNil(draft.binding?.threshold, "taught for swipe up, not down")
        draft.direction = .up
        XCTAssertEqual(draft.binding?.threshold, 0.04)
        draft.teach(nil)
        XCTAssertNil(draft.binding?.threshold)
    }

    func testDraftCarriesTheThreshold() {
        let binding = Binding(gesture: up3, action: .key("return", modifiers: []), threshold: 0.07)
        XCTAssertEqual(BindingDraft(binding).binding, binding)
    }
}

final class TeachSessionTests: XCTestCase {
    /// One attempt: `count` fingers land, move by (dx, dy) in 10 frames, lift.
    private func attempt(_ session: inout TeachSession, _ hand: inout Hand, fingers count: Int = 3, dx: Double = 0, dy: Double = 0) -> TeachSession.Feedback? {
        var feedback: TeachSession.Feedback?
        for i in 0...10 {
            let f = Double(i) / 10
            if let got = session.observe(hand.frame(Hand.fingers(count, dx: dx * f, dy: dy * f))) { feedback = got }
        }
        if let got = session.observe(hand.frame([])) { feedback = got }
        return feedback
    }

    func testAGoodSwipeIsMeasuredAlongItsDirection() {
        var session = TeachSession(gesture: up3)
        var hand = Hand()
        XCTAssertEqual(attempt(&session, &hand, dx: 0.02, dy: 0.15), .accepted(0.15))
        XCTAssertEqual(session.examples, [0.15])
    }

    func testWrongAttemptsSayWhy() {
        var session = TeachSession(gesture: up3)
        var hand = Hand()
        XCTAssertEqual(attempt(&session, &hand, fingers: 2, dy: 0.15), .wrongFingers(2))
        XCTAssertEqual(attempt(&session, &hand, dx: -0.15), .other(.swipe(fingers: 3, direction: .left)))
        XCTAssertEqual(attempt(&session, &hand, dy: 0.01), .tooSmall)
        XCTAssertEqual(session.examples, [])
    }

    func testOneFingerIsIgnored() {
        var session = TeachSession(gesture: up3)
        var hand = Hand()
        XCTAssertNil(attempt(&session, &hand, fingers: 1, dy: 0.2))
    }

    func testFingersLiftingAtTheEndKeepTheMeasure() {
        var session = TeachSession(gesture: up3)
        var hand = Hand()
        _ = session.observe(hand.frame(Hand.fingers(3)))
        _ = session.observe(hand.frame(Hand.fingers(3, dy: 0.12)))
        _ = session.observe(hand.frame(Array(Hand.fingers(3, dy: 0.12).prefix(2))))
        XCTAssertEqual(session.observe(hand.frame([])), .accepted(0.12))
    }

    func testDoneAfterFiveGoodOnes() {
        var session = TeachSession(gesture: up3)
        var hand = Hand()
        for dy in [0.1, 0.2, 0.15, 0.12, 0.3] { _ = attempt(&session, &hand, dy: dy) }
        XCTAssertTrue(session.isDone)
        XCTAssertNil(attempt(&session, &hand, dy: 0.2), "nothing more once done")
        XCTAssertEqual(session.examples.count, 5)
    }

    func testPinchesAreMeasuredByTheirSpread() {
        var session = TeachSession(gesture: pinchIn2)
        var hand = Hand()
        var feedback: TeachSession.Feedback?
        for gap in stride(from: 0.3, through: 0.18, by: -0.02) { feedback = session.observe(hand.frame(pair(gap))) ?? feedback }
        feedback = session.observe(hand.frame([])) ?? feedback
        guard case let .accepted(size) = feedback else { return XCTFail("\(String(describing: feedback))") }
        XCTAssertEqual(size, 0.06, accuracy: 1e-9)
        hand = Hand()
        for gap in stride(from: 0.2, through: 0.32, by: 0.02) { feedback = session.observe(hand.frame(pair(gap))) ?? feedback }
        XCTAssertEqual(session.observe(hand.frame([])), .other(.pinch(fingers: 2, direction: .out)))
    }
}

final class TeachProposalTests: XCTestCase {
    func testSixtyPercentOfTheSmallest() {
        XCTAssertEqual(Teach.proposal(for: up3, examples: [0.1, 0.08, 0.2], current: 0.12), 0.048, accuracy: 1e-9)
    }

    func testThreeFingersNeverGetStricterThanNow() {
        XCTAssertEqual(Teach.proposal(for: up3, examples: [0.3, 0.25], current: 0.05), 0.05)
        XCTAssertEqual(Teach.proposal(for: up3, examples: [0.02], current: 0.05), 0.03, "floor")
    }

    func testTwoFingersNeverGetEasierThanNow() {
        XCTAssertEqual(Teach.proposal(for: left2, examples: [0.05], current: 0.05), 0.05)
        XCTAssertEqual(Teach.proposal(for: left2, examples: [0.2], current: 0.05), 0.12, accuracy: 1e-9)
        XCTAssertEqual(Teach.proposal(for: left2, examples: [0.9], current: 0.05), 0.25, "ceiling")
        XCTAssertEqual(Teach.proposal(for: pinchIn2, examples: [0.01], current: 0.03), 0.03)
        XCTAssertEqual(Teach.proposal(for: pinchIn2, examples: [0.5], current: 0.03), 0.15)
    }
}
