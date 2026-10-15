import CoreGraphics
import XCTest
@testable import SwipeKeyCore

final class SwipeRecognizerTests: XCTestCase {
    private func frame(_ points: [(Double, Double)], state: Int = 4) -> TouchFrame {
        TouchFrame(
            touches: points.enumerated().map { Touch(x: $1.0, y: $1.1, identifier: $0, state: state) },
            timestamp: 0
        )
    }

    private func three(dx: Double = 0, dy: Double = 0) -> TouchFrame {
        frame([(0.4 + dx, 0.3 + dy), (0.5 + dx, 0.3 + dy), (0.6 + dx, 0.3 + dy)])
    }

    func testThreeFingerSwipeUp() {
        let r = SwipeRecognizer(threshold: 0.12)
        XCTAssertEqual(r.process(three()), [])
        XCTAssertEqual(r.process(three(dy: 0.05)), [])
        XCTAssertEqual(r.process(three(dy: 0.15)), [.swipe(fingers: 3, direction: .up)])
    }

    func testEachDirection() {
        let cases: [(Double, Double, Direction)] = [(0, 0.2, .up), (0, -0.2, .down), (0.2, 0, .right), (-0.2, 0, .left)]
        for (dx, dy, direction) in cases {
            let r = SwipeRecognizer()
            _ = r.process(three())
            XCTAssertEqual(r.process(three(dx: dx, dy: dy)), [.swipe(fingers: 3, direction: direction)])
        }
    }

    func testFiresOncePerSessionAndRearmsAfterLift() {
        let r = SwipeRecognizer()
        _ = r.process(three())
        XCTAssertEqual(r.process(three(dy: 0.2)).count, 1)
        XCTAssertEqual(r.process(three(dy: 0.4)), [])
        _ = r.process(frame([]))
        _ = r.process(three())
        XCTAssertEqual(r.process(three(dy: 0.2)).count, 1)
    }

    func testDiagonalMovementIsIgnored() {
        let r = SwipeRecognizer()
        _ = r.process(three())
        XCTAssertEqual(r.process(three(dx: 0.15, dy: 0.15)), [])
    }

    func testOriginResetsWhenFingerCountChanges() {
        let r = SwipeRecognizer()
        _ = r.process(frame([(0.4, 0.1), (0.5, 0.1)]))
        // Third finger lands higher: must not count as an upward move of the centroid.
        XCTAssertEqual(r.process(frame([(0.4, 0.1), (0.5, 0.1), (0.6, 0.5)])), [])
        XCTAssertEqual(r.process(frame([(0.4, 0.15), (0.5, 0.15), (0.6, 0.55)])), [])
    }

    func testSingleFingerNeverSwipes() {
        let r = SwipeRecognizer()
        _ = r.process(frame([(0.5, 0.1)]))
        XCTAssertEqual(r.process(frame([(0.5, 0.9)])), [])
    }

    func testHoveringFingersAreIgnored() {
        let r = SwipeRecognizer()
        _ = r.process(frame([(0.4, 0.3), (0.5, 0.3), (0.6, 0.3)], state: 2))
        XCTAssertEqual(r.process(frame([(0.4, 0.6), (0.5, 0.6), (0.6, 0.6)], state: 2)), [])
    }
}

final class ConfigTests: XCTestCase {
    func testDecodesBindings() throws {
        let json = """
        {
          "swipeThreshold": 0.2,
          "bindings": [
            { "gesture": { "type": "swipe", "fingers": 3, "direction": "up" },
              "action": { "type": "key", "key": "return" } },
            { "gesture": { "type": "swipe", "fingers": 4, "direction": "left" },
              "action": { "type": "shell", "command": "open -a Safari" } }
          ]
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.swipeThreshold, 0.2)
        XCTAssertEqual(config.bindings, [
            Binding(gesture: .swipe(fingers: 3, direction: .up), action: .key("return", modifiers: [])),
            Binding(gesture: .swipe(fingers: 4, direction: .left), action: .shell("open -a Safari")),
        ])
    }

    func testDefaultConfigRoundTrips() throws {
        let json = try Config.default.jsonString()
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(json.utf8)), .default)
    }

    func testUnknownGestureTypeFails() {
        let json = #"{"bindings":[{"gesture":{"type":"pinch"},"action":{"type":"key","key":"a"}}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(json.utf8)))
    }

    func testKeyActionValidation() throws {
        XCTAssertEqual(try KeyPressAction(key: "return").resolvedKeyCode(), 36)
        XCTAssertEqual(try KeyPressAction(key: "42").resolvedKeyCode(), 42)
        XCTAssertTrue(try KeyPressAction(key: "c", modifiers: ["cmd"]).flags.contains(.maskCommand))
        XCTAssertThrowsError(try KeyPressAction(key: "nope"))
        XCTAssertThrowsError(try KeyPressAction(key: "a", modifiers: ["hyper"]))
    }

    func testDecodesHolding() throws {
        let json = #"{"bindings":[{"gesture":{"type":"swipe","fingers":3,"direction":"up"},"holding":["cmd"],"action":{"type":"key","key":"return"}}]}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.bindings.first?.holding, ["cmd"])
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(config.jsonString().utf8)), config)
    }
}

/// French AZERTY: letters a/q, z/w and m sit elsewhere than on US QWERTY; "1" is the "&1" key.
private struct FakeAZERTY: KeyboardLayout {
    let keys: [Character: CGKeyCode] = ["q": 0, "z": 13, "a": 12, "w": 6, "m": 41, "1": 18, "^": 33]
    func keyCode(for character: Character) -> CGKeyCode? { keys[character] }
}

final class KeyboardLayoutTests: XCTestCase {
    func testCharactersFollowTheLayout() throws {
        XCTAssertEqual(try KeyPressAction(key: "z", modifiers: ["cmd"], layout: FakeAZERTY()).resolvedKeyCode(), 13)
        XCTAssertEqual(try KeyPressAction(key: "Q", layout: FakeAZERTY()).resolvedKeyCode(), 0)
        XCTAssertEqual(try KeyPressAction(key: "m", layout: FakeAZERTY()).resolvedKeyCode(), 41)
    }

    func testNamedKeysIgnoreTheLayout() throws {
        XCTAssertEqual(try KeyPressAction(key: "tab", layout: FakeAZERTY()).resolvedKeyCode(), 48)
        XCTAssertEqual(try KeyPressAction(key: "left", layout: FakeAZERTY()).resolvedKeyCode(), 123)
    }

    func testFallsBackToQWERTYPosition() throws {
        // "x" is missing from the fake layout: use its US QWERTY position.
        XCTAssertEqual(try KeyPressAction(key: "x", layout: FakeAZERTY()).resolvedKeyCode(), 7)
    }

    func testSystemLayoutFindsLetters() {
        // Whatever layout runs the tests, a Latin layout has an "a" key.
        XCTAssertNotNil(SystemKeyboardLayout().keyCode(for: "a"))
    }
}

final class HoldingTests: XCTestCase {
    private let swipeUp = Gesture.swipe(fingers: 3, direction: .up)

    private func engine() throws -> Engine {
        try Engine(config: Config(bindings: [
            Binding(gesture: swipeUp, action: .key("return", modifiers: [])),
            Binding(gesture: swipeUp, holding: ["cmd"], action: .key("tab", modifiers: [])),
            Binding(gesture: swipeUp, holding: ["cmd", "shift"], action: .key("escape", modifiers: [])),
        ]))
    }

    private func keyCodes(_ engine: Engine, held: CGEventFlags) throws -> [CGKeyCode] {
        try engine.actions(for: Trigger(gesture: swipeUp, held: held)).map {
            try XCTUnwrap($0 as? KeyPressAction).resolvedKeyCode()
        }
    }

    func testHeldModifiersPickTheBinding() throws {
        let engine = try engine()
        XCTAssertEqual(try keyCodes(engine, held: []), [36])
        XCTAssertEqual(try keyCodes(engine, held: .maskCommand), [48])
        XCTAssertEqual(try keyCodes(engine, held: [.maskCommand, .maskShift]), [53])
    }

    func testUnboundCombinationDoesNothing() throws {
        XCTAssertEqual(try keyCodes(engine(), held: .maskAlternate), [])
    }

    func testIrrelevantFlagsAreIgnored() throws {
        // Caps Lock or fn being on must not hide the plain binding.
        XCTAssertEqual(try keyCodes(engine(), held: [.maskAlphaShift, .maskSecondaryFn]), [36])
    }

    func testFnCannotBeHeld() {
        let config = Config(bindings: [Binding(gesture: swipeUp, holding: ["fn"], action: .key("a", modifiers: []))])
        XCTAssertThrowsError(try Engine(config: config))
    }
}
