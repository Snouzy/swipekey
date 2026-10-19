import CoreGraphics
import XCTest
@testable import SwipeKeyCore

final class SwipeRecognizerTests: XCTestCase {
    /// Each frame 0.25 s after the last: past the finger-count settle, so these tests check
    /// distances and directions only.
    private var clock = 0.0

    private func frame(_ points: [(Double, Double)], state: Int = 4) -> TouchFrame {
        clock += 0.25
        return TouchFrame(
            touches: points.enumerated().map { Touch(x: $1.0, y: $1.1, identifier: $0, state: state) },
            timestamp: clock
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

final class PinchRecognizerTests: XCTestCase {
    /// Each frame 0.25 s after the last, past the finger-count settle.
    private var clock = 0.0

    /// Two fingers `gap` apart horizontally, centred on (cx, 0.5).
    private func two(gap: Double, cx: Double = 0.5) -> TouchFrame {
        clock += 0.25
        return TouchFrame(
            touches: [Touch(x: cx - gap / 2, y: 0.5, identifier: 0), Touch(x: cx + gap / 2, y: 0.5, identifier: 1)],
            timestamp: clock
        )
    }

    func testTwoFingerPinchIn() {
        let r = PinchRecognizer(threshold: 0.05)
        XCTAssertEqual(r.process(two(gap: 0.4)), [])
        XCTAssertEqual(r.process(two(gap: 0.35)), [])
        XCTAssertEqual(r.process(two(gap: 0.25)), [.pinch(fingers: 2, direction: .in)])
    }

    func testTwoFingerPinchOut() {
        let r = PinchRecognizer()
        _ = r.process(two(gap: 0.1))
        XCTAssertEqual(r.process(two(gap: 0.3)), [.pinch(fingers: 2, direction: .out)])
    }

    func testFiresOncePerSessionAndRearmsAfterLift() {
        let r = PinchRecognizer()
        _ = r.process(two(gap: 0.4))
        XCTAssertEqual(r.process(two(gap: 0.2)).count, 1)
        XCTAssertEqual(r.process(two(gap: 0.05)), [])
        _ = r.process(TouchFrame(touches: [], timestamp: clock))
        _ = r.process(two(gap: 0.4))
        XCTAssertEqual(r.process(two(gap: 0.2)).count, 1)
    }

    func testSwipeWithFingersDriftingTogetherIsNotAPinch() {
        let r = PinchRecognizer()
        _ = r.process(two(gap: 0.3, cx: 0.3))
        XCTAssertEqual(r.process(two(gap: 0.18, cx: 0.6)), [])
    }

    func testPinchDoesNotTriggerASwipe() {
        let r = SwipeRecognizer()
        _ = r.process(two(gap: 0.4))
        XCTAssertEqual(r.process(two(gap: 0.1)), [])
    }

    func testDecodesPinchBinding() throws {
        let json = #"{ "bindings": [ { "gesture": { "type": "pinch", "fingers": 2, "direction": "in" }, "action": { "type": "key", "key": "@", "modifiers": ["cmd"] } } ] }"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.bindings[0].gesture, .pinch(fingers: 2, direction: .in))
        XCTAssertEqual(config.pinchThreshold, 0.05)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(config.jsonString().utf8)), config)
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

final class ScrollFilterTests: XCTestCase {
    private let began = ScrollFilter.phaseBegan, changed: Int64 = 2, ended = ScrollFilter.phaseEnded

    func testTwoFingerScrollPassesThrough() {
        var f = ScrollFilter(minFingers: 3)
        XCTAssertFalse(f.shouldDrop(fingers: 2, scrollPhase: began, momentumPhase: 0))
        XCTAssertFalse(f.shouldDrop(fingers: 2, scrollPhase: changed, momentumPhase: 0))
        XCTAssertFalse(f.shouldDrop(fingers: 0, scrollPhase: 0, momentumPhase: 2)) // its own inertia
    }

    func testThreeFingerScrollAndItsTailAreSwallowed() {
        var f = ScrollFilter(minFingers: 3)
        XCTAssertTrue(f.shouldDrop(fingers: 3, scrollPhase: began, momentumPhase: 0))
        XCTAssertTrue(f.shouldDrop(fingers: 3, scrollPhase: changed, momentumPhase: 0))
        // fingers lifted: the gesture's end and the inertia still belong to the swipe
        XCTAssertTrue(f.shouldDrop(fingers: 0, scrollPhase: ended, momentumPhase: 0))
        XCTAssertTrue(f.shouldDrop(fingers: 0, scrollPhase: 0, momentumPhase: 1))
        XCTAssertTrue(f.shouldDrop(fingers: 0, scrollPhase: 0, momentumPhase: 2))
        XCTAssertTrue(f.shouldDrop(fingers: 0, scrollPhase: 0, momentumPhase: ScrollFilter.momentumEnd))
        // then normal scrolling is back
        XCTAssertFalse(f.shouldDrop(fingers: 2, scrollPhase: began, momentumPhase: 0))
    }

    func testFingersLiftingOneByOneStillSwallowsTheInertia() {
        // Recorded with --debug: a three-finger swipe up in a terminal, fingers lifting unevenly.
        var f = ScrollFilter(minFingers: 3)
        XCTAssertTrue(f.shouldDrop(fingers: 3, scrollPhase: began, momentumPhase: 0))
        XCTAssertTrue(f.shouldDrop(fingers: 3, scrollPhase: changed, momentumPhase: 0))
        XCTAssertTrue(f.shouldDrop(fingers: 2, scrollPhase: changed, momentumPhase: 0))
        XCTAssertTrue(f.shouldDrop(fingers: 1, scrollPhase: changed, momentumPhase: 0))
        XCTAssertTrue(f.shouldDrop(fingers: 1, scrollPhase: ended, momentumPhase: 0))
        XCTAssertTrue(f.shouldDrop(fingers: 0, scrollPhase: 0, momentumPhase: 1))
        XCTAssertTrue(f.shouldDrop(fingers: 0, scrollPhase: 128, momentumPhase: 0)) // "may begin"
        for _ in 0..<80 { XCTAssertTrue(f.shouldDrop(fingers: 0, scrollPhase: 0, momentumPhase: 2)) }
        XCTAssertTrue(f.shouldDrop(fingers: 1, scrollPhase: 0, momentumPhase: ScrollFilter.momentumEnd))
        XCTAssertFalse(f.shouldDrop(fingers: 2, scrollPhase: began, momentumPhase: 0))
        XCTAssertFalse(f.shouldDrop(fingers: 2, scrollPhase: changed, momentumPhase: 0))
    }

    func testMouseWheelEndsSwallowing() {
        var f = ScrollFilter(minFingers: 3)
        XCTAssertTrue(f.shouldDrop(fingers: 3, scrollPhase: changed, momentumPhase: 0))
        XCTAssertFalse(f.shouldDrop(fingers: 0, scrollPhase: 0, momentumPhase: 0))
    }

    func testFreshScrollEndsSwallowingEvenWithoutMomentum() {
        var f = ScrollFilter(minFingers: 3)
        XCTAssertTrue(f.shouldDrop(fingers: 3, scrollPhase: changed, momentumPhase: 0))
        XCTAssertFalse(f.shouldDrop(fingers: 2, scrollPhase: began, momentumPhase: 0))
        XCTAssertFalse(f.shouldDrop(fingers: 2, scrollPhase: changed, momentumPhase: 0))
    }

    func testMouseWheelPassesThrough() {
        var f = ScrollFilter(minFingers: 3)
        XCTAssertFalse(f.shouldDrop(fingers: 0, scrollPhase: 0, momentumPhase: 0))
    }

    func testDisabledWithZero() {
        var f = ScrollFilter(minFingers: 0)
        XCTAssertFalse(f.shouldDrop(fingers: 5, scrollPhase: changed, momentumPhase: 0))
    }
}

final class FingerCountTests: XCTestCase {
    func testEngineTracksTheBusiestTrackpad() throws {
        let engine = try Engine(config: Config(bindings: []))
        let three = TouchFrame(touches: (0..<3).map { Touch(x: 0.3 + Double($0) * 0.1, y: 0.5, identifier: $0) }, timestamp: 0)
        engine.handle(three, device: 1)
        engine.handle(TouchFrame(touches: [Touch(x: 0.5, y: 0.5, identifier: 0)], timestamp: 0), device: 2)
        XCTAssertEqual(engine.activeFingers, 3)
        engine.handle(TouchFrame(touches: [], timestamp: 0.1), device: 1)
        XCTAssertEqual(engine.activeFingers, 1)
    }

    func testHoveringFingersDontCount() throws {
        let engine = try Engine(config: Config(bindings: []))
        engine.handle(TouchFrame(touches: (0..<3).map { Touch(x: 0.5, y: 0.5, identifier: $0, state: 2) }, timestamp: 0), device: 1)
        XCTAssertEqual(engine.activeFingers, 0)
    }
}

/// For bindings an engine test really fires: the engine runs the action, and a key action would
/// type into whatever app has focus while the tests run.
let harmless = ActionSpec.shell("true")

/// Only bound gestures fire: engine tests that watch `onGesture` bind the swipe they do.
let swipeUpBound = Config(bindings: [Binding(gesture: .swipe(fingers: 3, direction: .up), action: harmless)])

final class PauseTests: XCTestCase {
    private func swipeUp(_ engine: Engine) {
        for dy in [0.0, 0.2] {
            engine.handle(TouchFrame(touches: (0..<3).map { Touch(x: 0.3 + Double($0) * 0.1, y: 0.3 + dy, identifier: $0) }, timestamp: dy), device: 1)
        }
    }

    func testPausedEngineFiresNothingAndBlocksNoScroll() throws {
        let engine = try Engine(config: swipeUpBound)
        let fired = expectation(description: "gesture")
        fired.isInverted = true
        engine.onGesture = { _ in fired.fulfill() }
        engine.isEnabled = false
        swipeUp(engine)
        XCTAssertEqual(engine.activeFingers, 0)
        wait(for: [fired], timeout: 0.2)
    }

    func testResumedEngineFiresAgain() throws {
        let engine = try Engine(config: swipeUpBound)
        let fired = expectation(description: "gesture")
        engine.onGesture = { trigger in
            XCTAssertEqual(trigger.gesture, .swipe(fingers: 3, direction: .up))
            fired.fulfill()
        }
        engine.isEnabled = false
        engine.isEnabled = true
        swipeUp(engine)
        wait(for: [fired], timeout: 1)
    }
}

final class MenuSettingsTests: XCTestCase {
    func testMenuBarIconDefaultsOnAndEditorToNone() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{ "bindings": [] }"#.utf8))
        XCTAssertTrue(config.menuBarIcon)
        XCTAssertNil(config.editor)
        let set = try JSONDecoder().decode(Config.self, from: Data(#"{ "bindings": [], "menuBarIcon": false, "editor": "Cursor" }"#.utf8))
        XCTAssertFalse(set.menuBarIcon)
        XCTAssertEqual(set.editor, "Cursor")
    }

    func testUpdateChangesOneSettingAndKeepsTheRest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swipekey-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{ "swipeThreshold": 0.09, "bindings": [ { "gesture": { "type": "swipe", "fingers": 3, "direction": "up" }, "action": { "type": "key", "key": "return" } } ] }"#.utf8).write(to: url)

        try Config.update(.editor, to: "Zed", at: url)
        var config = try Config.load(from: url)
        XCTAssertEqual(config.editor, "Zed")
        XCTAssertEqual(config.swipeThreshold, 0.09)
        XCTAssertEqual(config.bindings.count, 1)
        // Only what the user wrote plus the new key: no defaults filled in.
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["swipeThreshold", "bindings", "editor"])

        try Config.update(.editor, to: nil, at: url)
        config = try Config.load(from: url)
        XCTAssertNil(config.editor)
    }

    func testActionsReadLikeShortcuts() {
        XCTAssertEqual(ActionSpec.key("@", modifiers: ["cmd"]).description, "⌘@")
        XCTAssertEqual(ActionSpec.key("tab", modifiers: ["shift", "control"]).description, "⌃⇧Tab")
        XCTAssertEqual(ActionSpec.key("return", modifiers: []).description, "Return")
        XCTAssertEqual(ActionSpec.shell("open -a Terminal").description, "Run: open -a Terminal")
        XCTAssertEqual(ActionSpec.shell(String(repeating: "x", count: 50)).description, "Run: " + String(repeating: "x", count: 39) + "…")
    }

    func testBindingTriggerIncludesHeldModifiers() throws {
        let binding = Binding(gesture: .swipe(fingers: 3, direction: .up), holding: ["cmd"], action: .key("return", modifiers: []))
        XCTAssertEqual(try binding.trigger(), Trigger(gesture: .swipe(fingers: 3, direction: .up), held: .maskCommand))
    }
}

final class SettingsWindowSupportTests: XCTestCase {
    func testReloadAppliesNewBindingsRightAway() throws {
        let up = Trigger(gesture: .swipe(fingers: 3, direction: .up), held: [])
        let engine = try Engine(config: Config(bindings: []))
        XCTAssertTrue(engine.actions(for: up).isEmpty)
        try engine.reload(Config(bindings: [Binding(gesture: .swipe(fingers: 3, direction: .up), action: .key("return", modifiers: []))]))
        XCTAssertEqual(engine.actions(for: up).count, 1)
    }

    func testInvalidReloadKeepsTheCurrentBindings() throws {
        let up = Trigger(gesture: .swipe(fingers: 3, direction: .up), held: [])
        let engine = try Engine(config: Config(bindings: [Binding(gesture: .swipe(fingers: 3, direction: .up), action: .key("return", modifiers: []))]))
        XCTAssertThrowsError(try engine.reload(Config(bindings: [Binding(gesture: .swipe(fingers: 3, direction: .up), action: .key("nope-key", modifiers: []))])))
        XCTAssertEqual(engine.actions(for: up).count, 1)
    }

    func testRecordedKeyCodesGetTheirConfigNames() {
        XCTAssertEqual(KeyCodes.name(forKeyCode: 36), "return")
        XCTAssertEqual(KeyCodes.name(forKeyCode: 53), "escape")
        XCTAssertEqual(KeyCodes.name(forKeyCode: 51), "delete")
        XCTAssertEqual(KeyCodes.name(forKeyCode: 96), "f5")
        XCTAssertEqual(KeyCodes.name(forKeyCode: 126), "up")
        XCTAssertNil(KeyCodes.name(forKeyCode: 10), "character keys are recorded by the character they type")
    }

    func testKeyCapsForDrawing() {
        XCTAssertEqual(ActionSpec.key("tab", modifiers: ["shift", "control"]).keyCaps, ["⌃", "⇧", "Tab"])
        XCTAssertEqual(ActionSpec.key("escape", modifiers: []).keyCaps, ["Esc"])
        XCTAssertEqual(ActionSpec.key("up", modifiers: ["cmd"]).keyCaps, ["⌘", "↑"])
        XCTAssertEqual(ActionSpec.shell("ls").keyCaps, [])
    }

    func testSavingBindingsKeepsTheRestOfTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swipekey-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{ "swipeThreshold": 0.09, "editor": "Zed", "bindings": [] }"#.utf8).write(to: url)
        let bindings = [Binding(gesture: .pinch(fingers: 2, direction: .in), holding: ["cmd"], action: .key("@", modifiers: ["cmd"]))]
        try Config.update(.bindings, toEncoded: bindings, at: url)
        let config = try Config.load(from: url)
        XCTAssertEqual(config.bindings, bindings)
        XCTAssertEqual(config.swipeThreshold, 0.09)
        XCTAssertEqual(config.editor, "Zed")
    }
}

final class CaptureTests: XCTestCase {
    private func three(dy: Double) -> TouchFrame {
        TouchFrame(touches: (0..<3).map { Touch(x: 0.3 + Double($0) * 0.1, y: 0.3 + dy, identifier: $0) }, timestamp: dy)
    }

    func testCaptureGetsTheFramesAndRunsNoAction() throws {
        let engine = try Engine(config: swipeUpBound)
        let fired = expectation(description: "gesture")
        fired.isInverted = true
        engine.onGesture = { _ in fired.fulfill() }
        var frames = 0
        engine.capture = { _ in frames += 1 }
        engine.handle(three(dy: 0), device: 1)
        engine.handle(three(dy: 0.3), device: 1)
        XCTAssertEqual(frames, 2)
        XCTAssertEqual(engine.activeFingers, 3, "still counted, so scrolling stays blocked while testing")
        wait(for: [fired], timeout: 0.2)
    }

    func testGesturesFireAgainOnceCaptureEnds() throws {
        let engine = try Engine(config: swipeUpBound)
        let fired = expectation(description: "gesture")
        engine.onGesture = { _ in fired.fulfill() }
        engine.capture = { _ in }
        engine.capture = nil
        engine.handle(three(dy: 0), device: 1)
        engine.handle(three(dy: 0.3), device: 1)
        wait(for: [fired], timeout: 1)
    }

    func testSwipeRecognizerReportsItsTravel() {
        let r = SwipeRecognizer(threshold: 0.5)
        _ = r.process(three(dy: 0))
        _ = r.process(three(dy: 0.08))
        XCTAssertEqual(r.travel.dy, 0.08, accuracy: 1e-9)
        _ = r.process(TouchFrame(touches: [], timestamp: 1))
        XCTAssertEqual(r.travel.dy, 0)
    }

    func testPinchRecognizerReportsItsSpreadChange() {
        let r = PinchRecognizer(threshold: 0.5)
        let two = { (gap: Double) in TouchFrame(touches: [Touch(x: 0.5 - gap / 2, y: 0.5, identifier: 0), Touch(x: 0.5 + gap / 2, y: 0.5, identifier: 1)], timestamp: 0) }
        _ = r.process(two(0.4))
        _ = r.process(two(0.3))
        XCTAssertEqual(r.spreadChange, -0.05, accuracy: 1e-9)
    }
}

final class BlockScrollConfigTests: XCTestCase {
    func testDefaultsToThreeAndCanBeTurnedOff() throws {
        let plain = #"{"bindings":[]}"#, off = #"{"blockScrollWithFingers":0,"bindings":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(plain.utf8)).blockScrollWithFingers, 3)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(off.utf8)).blockScrollWithFingers, 0)
    }
}

final class KeyRemapTests: XCTestCase {
    private let logi = ("logi options+", "com.logi.optionsplus")
    private func remapper(_ remaps: [KeyRemap]) throws -> KeyRemapper { try KeyRemapper(remaps, layout: FakeAZERTY()) }
    private let spaceFromLogi = KeyRemap(from: .init(key: "space", app: "Logi Options+"), to: .init(key: "space", modifiers: ["control", "option"]))

    func testAddsTheLostModifiersOnlyForTheNamedApp() throws {
        let r = try remapper([spaceFromLogi])
        let out = r.map(keyCode: 49, flags: [], sender: { self.logi })
        XCTAssertEqual(out?.keyCode, 49)
        XCTAssertEqual(out?.flags, [.maskControl, .maskAlternate])
        // the real space bar (hardware) is untouched
        XCTAssertNil(r.map(keyCode: 49, flags: [], sender: { ("hardware", "") }))
    }

    func testAppMatchesNameOrBundleIdCaseInsensitively() throws {
        let byBundle = KeyRemap(from: .init(key: "space", app: "COM.LOGI.OPTIONSPLUS"), to: .init(key: "escape"))
        XCTAssertEqual(try remapper([byBundle]).map(keyCode: 49, flags: [], sender: { self.logi })?.keyCode, 53)
    }

    func testModifiersMustMatchExactly() throws {
        let r = try remapper([spaceFromLogi])
        XCTAssertNil(r.map(keyCode: 49, flags: .maskShift, sender: { self.logi }))
        XCTAssertNotNil(r.map(keyCode: 49, flags: .maskAlphaShift, sender: { self.logi })) // caps lock isn't a held modifier
    }

    func testNoAppMeansAnySender() throws {
        let r = try remapper([KeyRemap(from: .init(key: "f5"), to: .init(key: "return"))])
        XCTAssertEqual(r.map(keyCode: 96, flags: [], sender: { ("hardware", "") })?.keyCode, 36)
    }

    func testCharactersFollowTheLayout() throws {
        // "z" on AZERTY is key code 13 on both sides of the rule
        let r = try remapper([KeyRemap(from: .init(key: "z", modifiers: ["cmd"]), to: .init(key: "z", modifiers: ["cmd", "shift"]))])
        XCTAssertEqual(r.map(keyCode: 13, flags: .maskCommand, sender: { ("hardware", "") })?.flags, [.maskCommand, .maskShift])
        XCTAssertNil(r.map(keyCode: 6, flags: .maskCommand, sender: { ("hardware", "") }))
    }

    func testKeepsNonModifierFlags() throws {
        let out = try remapper([spaceFromLogi]).map(keyCode: 49, flags: .maskNonCoalesced, sender: { self.logi })
        XCTAssertTrue(out!.flags.contains(.maskNonCoalesced))
    }

    func testReleaseIsPairedWithItsPressEvenWithTheAddedModifiersHeld() throws {
        // F13 -> ctrl+opt+F14: by the time F13 comes up, ctrl+opt look held (we pressed them).
        var r = try remapper([KeyRemap(from: .init(key: "105"), to: .init(key: "107", modifiers: ["control", "option"]))])
        let down = r.handle(keyCode: 105, flags: .maskSecondaryFn, isDown: true, sender: { ("hardware", "") })
        XCTAssertEqual(down?.keyCode, 107)
        XCTAssertEqual(down?.pressesModifiers, true)
        let up = r.handle(keyCode: 105, flags: [.maskControl, .maskAlternate, .maskSecondaryFn], isDown: false, sender: { ("hardware", "") })
        XCTAssertEqual(up, down)
        // and only once: a later lone key-up isn't rewritten
        XCTAssertNil(r.handle(keyCode: 105, flags: [.maskControl, .maskAlternate], isDown: false, sender: { ("hardware", "") }))
    }

    func testRewriteWithoutNewModifiersStaysInPlace() throws {
        let out = try remapper([KeyRemap(from: .init(key: "f5"), to: .init(key: "return"))]).map(keyCode: 96, flags: [], sender: { ("hardware", "") })
        XCTAssertEqual(out?.pressesModifiers, false)
    }

    func testRejectsFnInFrom() {
        XCTAssertThrowsError(try remapper([KeyRemap(from: .init(key: "a", modifiers: ["fn"]), to: .init(key: "b"))]))
    }

    func testDecodesFromJSON() throws {
        let json = #"{"bindings":[],"remaps":[{"from":{"key":"space","app":"Logi Options+"},"to":{"key":"space","modifiers":["control","option"]}}]}"#
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(json.utf8)).remaps, [spaceFromLogi])
    }

    // Performance: ordinary typing must not pay for remaps.
    func testSenderIsNeverLookedUpForKeysWithoutARule() throws {
        let r = try remapper([spaceFromLogi])
        var lookups = 0
        for code in CGKeyCode(0)..<128 where code != 49 {
            XCTAssertNil(r.map(keyCode: code, flags: [], sender: { lookups += 1; return self.logi }))
        }
        XCTAssertEqual(lookups, 0)
    }

    func testAMillionUnmatchedKeysStayFast() throws {
        let r = try remapper([spaceFromLogi])
        let start = Date()
        var hits = 0
        for i in 0..<1_000_000 where r.map(keyCode: CGKeyCode(i % 48), flags: [], sender: { self.logi }) != nil { hits += 1 }
        XCTAssertEqual(hits, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}

final class KeystrokeTests: XCTestCase {
    func testControlOptionSpaceLikeAKeyboard() {
        let f: CGEventFlags = [.maskControl, .maskAlternate]
        XCTAssertEqual(Keystroke.press(49, flags: f) + Keystroke.release(49, flags: f), [
            KeystrokeEvent(kind: .modifierDown, keyCode: 59, flags: .maskControl),
            KeystrokeEvent(kind: .modifierDown, keyCode: 58, flags: [.maskControl, .maskAlternate]),
            KeystrokeEvent(kind: .keyDown, keyCode: 49, flags: f),
            KeystrokeEvent(kind: .keyUp, keyCode: 49, flags: f),
            KeystrokeEvent(kind: .modifierUp, keyCode: 58, flags: .maskControl),
            KeystrokeEvent(kind: .modifierUp, keyCode: 59, flags: []),
        ])
    }

    func testPlainKeyIsJustDownAndUp() {
        XCTAssertEqual(Keystroke.press(36, flags: []).map(\.kind), [.keyDown])
        XCTAssertEqual(Keystroke.release(36, flags: []).map(\.kind), [.keyUp])
    }

    func testModifierEventsAreFlagsChanged() {
        let step = KeystrokeEvent(kind: .modifierDown, keyCode: 55, flags: .maskCommand)
        let e = Keystroke.cgEvent(step, source: nil)
        XCTAssertEqual(e?.type, .flagsChanged)
        XCTAssertEqual(e?.getIntegerValueField(.keyboardEventKeycode), 55)
        XCTAssertEqual(e?.flags.contains(.maskCommand), true)
    }

    func testPostedEventsCarrySwipekeysMarker() {
        let e = Keystroke.cgEvent(KeystrokeEvent(kind: .keyDown, keyCode: 49, flags: []), source: nil)
        XCTAssertEqual(e?.getIntegerValueField(.eventSourceUserData), Keystroke.marker)
    }
}

private let up3 = Gesture.swipe(fingers: 3, direction: .up)
private let down3 = Gesture.swipe(fingers: 3, direction: .down)
private let left4 = Gesture.swipe(fingers: 4, direction: .left)
private let pinchIn2 = Gesture.pinch(fingers: 2, direction: .in)
private let pinchOut5 = Gesture.pinch(fingers: 5, direction: .out)

/// The bindings list used by the workflow tests: four triggers, one of them held with ⌘.
private let sample = [
    Binding(gesture: up3, action: .key("return", modifiers: [])),
    Binding(gesture: down3, action: .key("w", modifiers: ["cmd"])),
    Binding(gesture: pinchIn2, action: .shell("open -a Terminal")),
    Binding(gesture: up3, holding: ["cmd"], action: .key("tab", modifiers: ["control", "shift"])),
]

private func triggers(_ list: [Binding]) throws -> [Trigger] { try list.map { try $0.trigger() } }

/// What the editor's Next / Save button allows on each step (BindingEditor.canAdvance).
private func canAdvance(_ draft: BindingDraft, step: Int) -> Bool {
    switch step {
    case 1: return draft.gesture != nil
    case 2: return draft.action != nil && draft.actionError == nil
    default: return draft.binding != nil
    }
}

final class BindingWorkflowTests: XCTestCase {
    /// Opens the binding at `index`, lets `change` edit the draft, and saves it like the editor does.
    private func edit(_ index: Int, in list: [Binding], _ change: (inout BindingDraft) -> Void) throws -> [Binding] {
        var draft = BindingDraft(list[index])
        change(&draft)
        let binding = try XCTUnwrap(draft.binding)
        return BindingEdits.save(binding, editing: index, in: list)
    }

    func testChangingOnlyTheGesture() throws {
        let list = try edit(1, in: sample) { $0.record(left4) }
        XCTAssertEqual(list.count, sample.count)
        XCTAssertEqual(list[1], Binding(gesture: left4, action: .key("w", modifiers: ["cmd"])))
        XCTAssertEqual(list[0], sample[0])
        XCTAssertEqual(Array(list[2...]), Array(sample[2...]))
    }

    func testChangingOnlyTheAction() throws {
        let list = try edit(2, in: sample) { $0.isShell = false; $0.key = "f5"; $0.modifiers = ["option"] }
        XCTAssertEqual(list.count, sample.count)
        XCTAssertEqual(list[2], Binding(gesture: pinchIn2, action: .key("f5", modifiers: ["option"])))
        XCTAssertEqual(Array(list[..<2]), Array(sample[..<2]))
        XCTAssertEqual(list[3], sample[3])
    }

    func testChangingOnlyTheHeldModifiers() throws {
        let list = try edit(1, in: sample) { $0.holding = ["shift", "cmd"] }
        XCTAssertEqual(list.count, sample.count)
        XCTAssertEqual(list[1], Binding(gesture: down3, holding: ["shift", "cmd"], action: .key("w", modifiers: ["cmd"])))
        XCTAssertEqual(list[0], sample[0])
        XCTAssertEqual(Array(list[2...]), Array(sample[2...]))
    }

    func testChangingThingsAndBackLeavesTheListAsItWas() throws {
        let list = try edit(1, in: sample) { draft in
            draft.record(pinchOut5)
            draft.isShell = true
            draft.command = "say hi"
            draft.holding = ["control"]
            draft.modifiers = []
            draft.record(down3)
            draft.isShell = false
            draft.modifiers = ["cmd"]
            draft.holding = []
        }
        XCTAssertEqual(list, sample)
    }

    func testSavingWithoutChangesLeavesTheListAsItWas() throws {
        for index in sample.indices {
            XCTAssertEqual(try edit(index, in: sample) { _ in }, sample, "binding \(index)")
        }
    }

    func testSavingAHandWrittenBindingUnchangedKeepsWhatItDoes() throws {
        let handWritten = Binding(gesture: up3, holding: ["Command", "ctrl"], action: .key("Return", modifiers: ["fn", "alt", "command", "shift"]))
        let list = try edit(0, in: [handWritten]) { _ in }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(try list[0].trigger(), try handWritten.trigger())
        XCTAssertEqual(list[0].holding, ["control", "cmd"])
        XCTAssertEqual(list[0].action, .key("Return", modifiers: ["option", "shift", "cmd", "fn"]))
        let before = try handWritten.action.makeAction() as? KeyPressAction
        let after = try list[0].action.makeAction() as? KeyPressAction
        XCTAssertEqual(after?.flags, before?.flags)
        XCTAssertEqual(after?.key, before?.key)
    }

    func testEditingOntoTheTriggerOfAnEarlierBindingReplacesIt() throws {
        let list = try edit(2, in: sample) { $0.record(up3) }
        XCTAssertEqual(list, [
            sample[1],
            Binding(gesture: up3, action: .shell("open -a Terminal")),
            sample[3],
        ])
        XCTAssertEqual(Set(try triggers(list)).count, list.count)
    }

    func testEditingOntoTheTriggerOfALaterBindingReplacesIt() throws {
        let list = try edit(0, in: sample) { $0.record(pinchIn2) }
        XCTAssertEqual(list, [
            Binding(gesture: pinchIn2, action: .key("return", modifiers: [])),
            sample[1],
            sample[3],
        ])
        XCTAssertEqual(Set(try triggers(list)).count, list.count)
    }

    func testEditingTheLastBindingOntoTheFirstsTrigger() throws {
        let list = try edit(3, in: sample) { $0.holding = [] }
        XCTAssertEqual(list, [sample[1], sample[2], Binding(gesture: up3, action: sample[3].action)])
    }

    func testTheEditedBindingIsNotItsOwnClash() {
        XCTAssertNil(BindingEdits.clash(with: sample[2], editing: 2, in: sample))
        XCTAssertEqual(BindingEdits.clash(with: sample[2], editing: nil, in: sample), 2)
        XCTAssertEqual(BindingEdits.clash(with: sample[2], editing: 0, in: sample), 2)
    }

    func testAddingANewTriggerAppends() {
        let new = Binding(gesture: left4, action: .key("[", modifiers: ["cmd"]))
        XCTAssertNil(BindingEdits.clash(with: new, editing: nil, in: sample))
        XCTAssertEqual(BindingEdits.save(new, editing: nil, in: sample), sample + [new])
    }

    func testAddingOnAnExistingTriggerReplacesItInPlace() throws {
        var draft = BindingDraft()
        draft.record(down3)
        draft.key = "t"
        draft.modifiers = ["cmd"]
        let new = try XCTUnwrap(draft.binding)
        XCTAssertEqual(BindingEdits.clash(with: new, editing: nil, in: sample), 1)
        let list = BindingEdits.save(new, editing: nil, in: sample)
        XCTAssertEqual(list, [sample[0], new, sample[2], sample[3]])
    }

    func testSameGestureWithOtherHeldModifiersIsNotAClash() {
        let held = Binding(gesture: down3, holding: ["cmd"], action: .key("q", modifiers: ["cmd"]))
        XCTAssertNil(BindingEdits.clash(with: held, editing: nil, in: sample))
        let list = BindingEdits.save(held, editing: nil, in: sample)
        XCTAssertEqual(list, sample + [held])
        XCTAssertNil(BindingEdits.clash(with: sample[0], editing: 0, in: sample), "⌘ + swipe up is its own trigger")
    }

    func testHeldModifiersMatchWhateverTheirOrderOrSpelling() {
        let list = [Binding(gesture: down3, holding: ["command", "shift"], action: .key("a", modifiers: []))]
        let new = Binding(gesture: down3, holding: ["shift", "cmd"], action: .key("b", modifiers: []))
        XCTAssertEqual(BindingEdits.clash(with: new, editing: nil, in: list), 0)
        XCTAssertEqual(BindingEdits.save(new, editing: nil, in: list), [new])
    }

    func testSavingIntoAnEmptyList() {
        XCTAssertNil(BindingEdits.clash(with: sample[0], editing: nil, in: []))
        XCTAssertEqual(BindingEdits.save(sample[0], editing: nil, in: []), [sample[0]])
        XCTAssertEqual(BindingEdits.save(sample[0], editing: 0, in: []), [sample[0]])
    }

    func testEditingAnIndexThatNoLongerExistsSavesAsNew() {
        let shrunk = Array(sample[..<2])
        let new = Binding(gesture: left4, action: .key("x", modifiers: []))
        XCTAssertEqual(BindingEdits.save(new, editing: 3, in: shrunk), shrunk + [new])
        XCTAssertEqual(BindingEdits.save(new, editing: -1, in: shrunk), shrunk + [new])
        let onFirst = Binding(gesture: up3, action: .key("x", modifiers: []))
        XCTAssertEqual(BindingEdits.save(onFirst, editing: 3, in: shrunk), [onFirst, shrunk[1]])
    }

    /// Hand-written configs may bind a trigger twice (both actions run). Saving through the editor
    /// promises one binding per trigger.
    func testSavingLeavesOneBindingPerTriggerEvenWithHandWrittenDuplicates() throws {
        let twice = [
            Binding(gesture: up3, action: .key("a", modifiers: [])),
            Binding(gesture: up3, action: .key("b", modifiers: [])),
            Binding(gesture: up3, action: .key("c", modifiers: [])),
        ]
        let list = try edit(0, in: twice) { $0.key = "z" }
        XCTAssertEqual(list, [Binding(gesture: up3, action: .key("z", modifiers: []))])
    }

    func testDeleteThenUndoPutsItBackAtItsPlace() throws {
        for index in sample.indices {
            let (list, removed) = try XCTUnwrap(BindingEdits.delete(at: index, in: sample))
            XCTAssertEqual(removed, sample[index])
            XCTAssertEqual(list.count, sample.count - 1)
            XCTAssertFalse(list.contains(removed))
            XCTAssertEqual(BindingEdits.restore(removed, at: index, in: list), sample, "index \(index)")
        }
    }

    func testDeleteTheOnlyBindingThenUndo() throws {
        let (list, removed) = try XCTUnwrap(BindingEdits.delete(at: 0, in: [sample[2]]))
        XCTAssertEqual(list, [])
        XCTAssertEqual(BindingEdits.restore(removed, at: 0, in: list), [sample[2]])
    }

    func testDeleteOutOfRangeDoesNothing() {
        XCTAssertNil(BindingEdits.delete(at: sample.count, in: sample))
        XCTAssertNil(BindingEdits.delete(at: -1, in: sample))
        XCTAssertNil(BindingEdits.delete(at: 0, in: []))
    }

    func testDeleteThenAddOnTheSameTriggerThenUndoKeepsOne() throws {
        let (afterDelete, removed) = try XCTUnwrap(BindingEdits.delete(at: 1, in: sample))
        let added = Binding(gesture: down3, action: .shell("say added"))
        let afterAdd = BindingEdits.save(added, editing: nil, in: afterDelete)
        XCTAssertEqual(afterAdd, [sample[0], sample[2], sample[3], added])
        let restored = BindingEdits.restore(removed, at: 1, in: afterAdd)
        XCTAssertEqual(restored.filter { $0.gesture == down3 && $0.holding.isEmpty }, [removed])
        XCTAssertEqual(restored.count, sample.count)
        XCTAssertEqual(Set(try triggers(restored)).count, restored.count)
    }

    func testTwoDeletesThenUndoOfTheLastOne() throws {
        let (once, first) = try XCTUnwrap(BindingEdits.delete(at: 0, in: sample))
        let (twice, second) = try XCTUnwrap(BindingEdits.delete(at: 2, in: once))
        XCTAssertEqual(first, sample[0])
        XCTAssertEqual(second, sample[3])
        XCTAssertEqual(BindingEdits.restore(second, at: 2, in: twice), [sample[1], sample[2], sample[3]])

        let (again, sameIndex) = try XCTUnwrap(BindingEdits.delete(at: 0, in: once))
        XCTAssertEqual(sameIndex, sample[1])
        XCTAssertEqual(BindingEdits.restore(sameIndex, at: 0, in: again), once)
    }

    func testUndoAfterTheListShrankGoesAtTheEnd() throws {
        let (list, removed) = try XCTUnwrap(BindingEdits.delete(at: 3, in: sample))
        let shrunk = Array(list[..<1])
        XCTAssertEqual(BindingEdits.restore(removed, at: 3, in: shrunk), [sample[0], sample[3]])
        XCTAssertEqual(BindingEdits.restore(removed, at: -5, in: shrunk), [sample[3], sample[0]])
    }

    /// Undo puts the deleted binding back in place of whatever now answers to its trigger, even a
    /// binding that existed before the delete and was only edited onto that trigger since: that
    /// binding is gone after the undo.
    func testUndoAfterEditingAnotherBindingOntoTheDeletedTrigger() throws {
        let (afterDelete, removed) = try XCTUnwrap(BindingEdits.delete(at: 1, in: sample))
        let edited = try edit(0, in: afterDelete) { $0.record(down3) }
        XCTAssertEqual(edited[0], Binding(gesture: down3, action: .key("return", modifiers: [])))
        let restored = BindingEdits.restore(removed, at: 1, in: edited)
        XCTAssertEqual(restored, [sample[1], sample[2], sample[3]])
    }

    func testAnEditorLeftOpenWhileTheListShrankDoesNotOverwriteAnotherBinding() throws {
        var draft = BindingDraft(sample[1])
        draft.key = "t"
        let shrunk = Array(sample.dropFirst())
        let list = BindingEdits.save(try XCTUnwrap(draft.binding), replacing: sample[1], near: 1, in: shrunk)
        XCTAssertEqual(list.filter { $0.gesture == down3 }.count, 1)
        XCTAssertTrue(list.contains(sample[2]), "the pinch was never edited and must survive")
    }
}

final class BindingDraftTests: XCTestCase {
    func testANewDraftIsIncomplete() {
        let draft = BindingDraft()
        XCTAssertNil(draft.gesture)
        XCTAssertNil(draft.action)
        XCTAssertNil(draft.actionError)
        XCTAssertNil(draft.binding)
        XCTAssertFalse(canAdvance(draft, step: 1))
    }

    func testStepsUnlockAsTheDraftFillsIn() {
        var draft = BindingDraft()
        draft.record(up3)
        XCTAssertTrue(canAdvance(draft, step: 1))
        XCTAssertFalse(canAdvance(draft, step: 2))
        draft.key = "return"
        XCTAssertTrue(canAdvance(draft, step: 2))
        XCTAssertTrue(canAdvance(draft, step: 3))
        XCTAssertEqual(draft.binding, Binding(gesture: up3, action: .key("return", modifiers: [])))
    }

    func testEveryGestureShapeRoundTrips() {
        for fingers in 2...5 {
            let gestures = Direction.allCases.map { Gesture.swipe(fingers: fingers, direction: $0) }
                + PinchDirection.allCases.map { Gesture.pinch(fingers: fingers, direction: $0) }
            for gesture in gestures {
                let binding = Binding(gesture: gesture, action: .key("a", modifiers: []))
                XCTAssertEqual(BindingDraft(binding).binding, binding, "\(gesture)")
            }
        }
    }

    func testKeysWithModifiersRoundTrip() {
        let actions: [ActionSpec] = [
            .key("return", modifiers: []),
            .key("@", modifiers: ["cmd"]),
            .key("tab", modifiers: ["control", "shift"]),
            .key("f5", modifiers: ["control", "option", "shift", "cmd", "fn"]),
            .key("left", modifiers: ["fn"]),
            .key("36", modifiers: ["option"]),
        ]
        for action in actions {
            let binding = Binding(gesture: down3, action: action)
            XCTAssertEqual(BindingDraft(binding).binding, binding, "\(action)")
        }
    }

    func testHandWrittenModifierNamesAreSavedUnderOneName() throws {
        let binding = Binding(gesture: down3, holding: ["opt", "CMD"], action: .key("w", modifiers: ["command", "alt", "ctrl", "opt", "fn", "Shift"]))
        let draft = BindingDraft(binding)
        XCTAssertEqual(draft.modifiers, ["cmd", "option", "control", "fn", "shift"])
        XCTAssertEqual(draft.holding, ["option", "cmd"])
        let saved = try XCTUnwrap(draft.binding)
        XCTAssertEqual(saved.action, .key("w", modifiers: ["control", "option", "shift", "cmd", "fn"]))
        XCTAssertEqual(saved.holding, ["option", "cmd"])
        XCTAssertEqual(try saved.trigger(), try binding.trigger())
    }

    func testCanonicalModifierNames() {
        let expected = ["command": "cmd", "cmd": "cmd", "Command": "cmd", "alt": "option", "opt": "option", "option": "option",
                        "ctrl": "control", "control": "control", "shift": "shift", "fn": "fn", "FN": "fn", "hyper": "hyper"]
        for (name, canonical) in expected {
            XCTAssertEqual(KeyCodes.canonicalModifier(name), canonical, name)
        }
    }

    func testModifiersAreOrderedLikeAKeyboardAndUnknownNamesKept() {
        XCTAssertEqual(KeyCodes.orderedModifiers(["fn", "cmd", "shift", "option", "control"]), ["control", "option", "shift", "cmd", "fn"])
        XCTAssertEqual(KeyCodes.orderedModifiers(["zeta", "cmd", "alpha"]), ["cmd", "alpha", "zeta"])
        XCTAssertEqual(KeyCodes.orderedModifiers([]), [])
    }

    func testAnUnknownModifierIsAnError() {
        var draft = BindingDraft(Binding(gesture: up3, action: .key("a", modifiers: ["hyper"])))
        XCTAssertEqual(draft.modifiers, ["hyper"])
        XCTAssertNotNil(draft.actionError)
        XCTAssertNil(draft.binding)
        XCTAssertFalse(canAdvance(draft, step: 2))
        draft.modifiers = ["cmd"]
        XCTAssertNil(draft.actionError)
        XCTAssertNotNil(draft.binding)
    }

    func testShellCommandsRoundTripTrimmed() throws {
        let binding = Binding(gesture: pinchOut5, holding: ["shift"], action: .shell("open -a Terminal"))
        XCTAssertEqual(BindingDraft(binding).binding, binding)

        var draft = BindingDraft()
        draft.record(up3)
        draft.isShell = true
        draft.command = "  \n say hi \t\n"
        XCTAssertEqual(draft.action, .shell("say hi"))
        XCTAssertNil(draft.actionError)
        XCTAssertEqual(draft.binding?.action, .shell("say hi"))
    }

    func testABlankCommandIsIncomplete() {
        var draft = BindingDraft()
        draft.record(up3)
        draft.isShell = true
        for command in ["", "   ", "\n\t "] {
            draft.command = command
            XCTAssertNil(draft.action, "\"\(command)\"")
            XCTAssertNil(draft.actionError)
            XCTAssertNil(draft.binding)
            XCTAssertFalse(canAdvance(draft, step: 2))
        }
    }

    func testHeldModifiersRoundTrip() {
        for holding in [["cmd"], ["control", "option", "shift", "cmd"], ["shift"]] {
            let binding = Binding(gesture: left4, holding: holding, action: .key("a", modifiers: []))
            XCTAssertEqual(BindingDraft(binding).binding, binding, "\(holding)")
        }
    }

    func testInvalidKeyTextsBlockTheActionStep() {
        var draft = BindingDraft()
        draft.record(up3)
        for key in ["cmd+w", "", "nope-key", "page up", "70000", "-1", "⌘w"] {
            draft.key = key
            XCTAssertNotNil(draft.action, key)
            XCTAssertNotNil(draft.actionError, key)
            XCTAssertNil(draft.binding, key)
            XCTAssertFalse(canAdvance(draft, step: 2), key)
        }
    }

    func testValidKeyTexts() throws {
        var draft = BindingDraft()
        draft.record(up3)
        for key in ["36", "0", "65535", "@", "a", "[", "é", "return", "f12", "esc", "Return", "F5"] {
            draft.key = key
            XCTAssertNil(draft.actionError, key)
            XCTAssertEqual(draft.binding?.action, .key(key, modifiers: []), key)
            XCTAssertTrue(canAdvance(draft, step: 2), key)
        }
    }

    func testAnUppercaseKeyNameIsKeptAsWrittenAndPressesTheSameKey() throws {
        let upper = try XCTUnwrap(BindingDraft(Binding(gesture: up3, action: .key("Return", modifiers: []))).binding)
        XCTAssertEqual(upper.action, .key("Return", modifiers: []))
        let pressed = try upper.action.makeAction() as? KeyPressAction
        XCTAssertEqual(pressed?.key, .code(36))
        XCTAssertEqual(upper.action.keyCaps, ["Return"])
    }

    func testSwitchingFromSwipeToPinchClearsTheGestureUntilADirectionIsPicked() {
        var draft = BindingDraft()
        draft.record(up3)
        draft.kind = .pinch
        XCTAssertNil(draft.gesture)
        XCTAssertNil(draft.binding)
        XCTAssertFalse(canAdvance(draft, step: 1))
        draft.pinch = .out
        XCTAssertEqual(draft.gesture, .pinch(fingers: 3, direction: .out))
        draft.kind = .swipe
        XCTAssertEqual(draft.gesture, up3, "the swipe direction picked before is kept")
    }

    func testOpeningAPinchThenSwitchingToSwipeNeedsADirection() {
        var draft = BindingDraft(Binding(gesture: pinchIn2, action: .key("a", modifiers: [])))
        draft.kind = .swipe
        XCTAssertNil(draft.gesture)
        draft.direction = .right
        XCTAssertEqual(draft.gesture, .swipe(fingers: 2, direction: .right))
    }

    func testRecordingReplacesTheGestureAndKeepsTheOtherKindsDirection() {
        var draft = BindingDraft()
        draft.record(up3)
        draft.record(pinchIn2)
        XCTAssertEqual(draft.gesture, pinchIn2)
        draft.kind = .swipe
        XCTAssertEqual(draft.gesture, .swipe(fingers: 2, direction: .up), "a swipe the user never did, but its arrow shows selected")
    }

    func testChangingFingersKeepsTheDirection() {
        var draft = BindingDraft(Binding(gesture: up3, action: .key("a", modifiers: [])))
        for fingers in 2...5 {
            draft.fingers = fingers
            XCTAssertEqual(draft.gesture, .swipe(fingers: fingers, direction: .up))
        }
    }

    func testSwitchingActionKindKeepsWhatWasTypedInEach() {
        var draft = BindingDraft(Binding(gesture: up3, action: .key("w", modifiers: ["cmd"])))
        draft.isShell = true
        XCTAssertNil(draft.action)
        draft.command = "ls"
        XCTAssertEqual(draft.action, .shell("ls"))
        draft.isShell = false
        XCTAssertEqual(draft.action, .key("w", modifiers: ["cmd"]))
        draft.isShell = true
        XCTAssertEqual(draft.action, .shell("ls"))
    }

    func testAnOpenedDraftMatchesWhatTheEditorShows() {
        let draft = BindingDraft(Binding(gesture: pinchOut5, holding: ["cmd"], action: .shell("ls")))
        XCTAssertEqual(draft.kind, .pinch)
        XCTAssertEqual(draft.fingers, 5)
        XCTAssertEqual(draft.pinch, .out)
        XCTAssertNil(draft.direction)
        XCTAssertTrue(draft.isShell)
        XCTAssertEqual(draft.command, "ls")
        XCTAssertNil(draft.key)
        XCTAssertEqual(draft.holding, ["cmd"])
    }

    /// The editor's chips only offer control, option, shift and cmd, but a draft holding something
    /// else is still turned into a binding: the engine is what refuses it.
    func testHoldingTheEngineRefusesStillMakesABinding() throws {
        for holding: Set<String> in [["fn"], ["hyper"]] {
            var draft = BindingDraft()
            draft.record(up3)
            draft.key = "a"
            draft.holding = holding
            let binding = try XCTUnwrap(draft.binding)
            let engine = try Engine(config: Config(bindings: [sample[0]]))
            XCTAssertThrowsError(try engine.reload(Config(bindings: [binding])), "\(holding)")
            XCTAssertEqual(engine.actions(for: try sample[0].trigger()).count, 1)
        }
    }

    func testABindingWithAnInvalidHoldingNeverClashes() {
        let odd = Binding(gesture: up3, holding: ["hyper"], action: .key("a", modifiers: []))
        XCTAssertNil(BindingEdits.clash(with: odd, editing: nil, in: sample))
        XCTAssertNil(BindingEdits.clash(with: sample[0], editing: nil, in: [odd]))
        XCTAssertEqual(BindingEdits.save(odd, editing: nil, in: sample), sample + [odd])
    }
}

/// The settings window's save path (ConfigStore.setBindings): check with the engine, then write
/// only the bindings key of the file.
final class BindingFileWorkflowTests: XCTestCase {
    private var url: URL!
    private var config: Config!
    private var engine: Engine!

    private let original = #"""
    {
      "swipeThreshold": 0.09,
      "pinchThreshold": 0.07,
      "blockScrollWithFingers": 4,
      "editor": "Zed",
      "menuBarIcon": false,
      "remaps": [ { "from": { "key": "space", "app": "Logi Options+" }, "to": { "key": "space", "modifiers": ["control", "option"] } } ],
      "bindings": [
        { "gesture": { "type": "swipe", "fingers": 3, "direction": "up" }, "action": { "type": "key", "key": "return" } },
        { "gesture": { "type": "swipe", "fingers": 3, "direction": "down" }, "action": { "type": "key", "key": "w", "modifiers": ["command", "fn"] } },
        { "gesture": { "type": "pinch", "fingers": 2, "direction": "in" }, "holding": ["cmd"], "action": { "type": "shell", "command": "open -a Terminal" } }
      ]
    }
    """#

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("swipekey-\(UUID()).json")
        try Data(original.utf8).write(to: url)
        config = try Config.load(from: url)
        engine = try Engine(config: config)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func setBindings(_ bindings: [Binding]) throws {
        var next = config!
        next.bindings = bindings
        try engine.reload(next)
        try Config.update(.bindings, toEncoded: bindings, at: url)
        config = next
    }

    private func fileObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func assertOtherKeysUntouched(file: StaticString = #filePath, line: UInt = #line) throws {
        let start = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        XCTAssertEqual(Set(try fileObject().keys), Set(start.keys), file: file, line: line)
        var expected = try JSONDecoder().decode(Config.self, from: Data(original.utf8))
        let now = try Config.load(from: url)
        expected.bindings = now.bindings
        XCTAssertEqual(now, expected, file: file, line: line)
    }

    private func assertSavedAndLive(_ expected: [Binding], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Config.load(from: url).bindings, expected, file: file, line: line)
        XCTAssertEqual(config.bindings, expected, file: file, line: line)
        for binding in expected {
            XCTAssertEqual(engine.actions(for: try binding.trigger()).count, 1, "\(binding.gesture)", file: file, line: line)
        }
        try assertOtherKeysUntouched(file: file, line: line)
    }

    private func liveKey(_ gesture: Gesture, held: CGEventFlags = []) -> KeyPressAction? {
        engine.actions(for: Trigger(gesture: gesture, held: held)).first as? KeyPressAction
    }

    func testASequenceOfEditsReachesTheFileAndTheEngine() throws {
        var draft = BindingDraft(config.bindings[0])
        draft.record(left4)
        var list = BindingEdits.save(try XCTUnwrap(draft.binding), editing: 0, in: config.bindings)
        try setBindings(list)
        try assertSavedAndLive(list)
        XCTAssertTrue(engine.actions(for: Trigger(gesture: up3, held: [])).isEmpty)
        XCTAssertEqual(liveKey(left4)?.key, .code(36))

        draft = BindingDraft()
        draft.record(up3)
        draft.key = "tab"
        draft.modifiers = ["control"]
        draft.holding = ["shift"]
        list = BindingEdits.save(try XCTUnwrap(draft.binding), editing: nil, in: list)
        try setBindings(list)
        try assertSavedAndLive(list)
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(liveKey(up3, held: .maskShift)?.flags, .maskControl)

        let (afterDelete, removed) = try XCTUnwrap(BindingEdits.delete(at: 1, in: list))
        try setBindings(afterDelete)
        try assertSavedAndLive(afterDelete)
        XCTAssertTrue(engine.actions(for: Trigger(gesture: down3, held: [])).isEmpty)

        list = BindingEdits.restore(removed, at: 1, in: afterDelete)
        try setBindings(list)
        try assertSavedAndLive(list)
        XCTAssertEqual(liveKey(down3)?.flags, [.maskCommand, .maskSecondaryFn])

        draft = BindingDraft()
        draft.record(left4)
        draft.isShell = true
        draft.command = "say replaced"
        list = BindingEdits.save(try XCTUnwrap(draft.binding), editing: nil, in: list)
        try setBindings(list)
        try assertSavedAndLive(list)
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list[0].action, .shell("say replaced"))
        XCTAssertNil(liveKey(left4))
        XCTAssertEqual(engine.actions(for: Trigger(gesture: left4, held: [])).count, 1)
    }

    func testFnWrittenByHandSurvivesAnEditThroughTheFile() throws {
        var draft = BindingDraft(config.bindings[1])
        draft.record(.swipe(fingers: 2, direction: .right))
        try setBindings(BindingEdits.save(try XCTUnwrap(draft.binding), editing: 1, in: config.bindings))
        let saved = try fileObject()["bindings"] as? [[String: Any]]
        let action = try XCTUnwrap(saved?[1]["action"] as? [String: Any])
        XCTAssertEqual(action["modifiers"] as? [String], ["cmd", "fn"])
        XCTAssertEqual(liveKey(.swipe(fingers: 2, direction: .right))?.flags, [.maskCommand, .maskSecondaryFn])
    }

    func testSavingEveryBindingUnchangedKeepsTheFileMeaning() throws {
        let before = config.bindings
        var list = before
        for index in list.indices {
            list = BindingEdits.save(try XCTUnwrap(BindingDraft(list[index]).binding), editing: index, in: list)
        }
        try setBindings(list)
        let reloaded = try Config.load(from: url)
        XCTAssertEqual(try triggers(reloaded.bindings), try triggers(before))
        XCTAssertEqual(reloaded.bindings.count, 3)
        XCTAssertEqual(reloaded.bindings[0], sample[0])
        XCTAssertEqual(reloaded.bindings[1].action, .key("w", modifiers: ["cmd", "fn"]))
        XCTAssertEqual(reloaded.bindings[2], Binding(gesture: pinchIn2, holding: ["cmd"], action: .shell("open -a Terminal")))
        try assertOtherKeysUntouched()
    }

    func testHandWrittenNumbersKeepTheirSpellingInTheFile() throws {
        try setBindings(config.bindings)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("0.09,") || text.contains("0.09\n"), text)
        XCTAssertFalse(text.contains("0.0899999"), text)
        XCTAssertFalse(text.contains("0.0700000"), text)
    }

    func testAnInvalidBindingIsRefusedAndNothingChanges() throws {
        let before = try Data(contentsOf: url)
        let bad = config.bindings + [Binding(gesture: left4, action: .key("nope-key", modifiers: []))]
        XCTAssertThrowsError(try setBindings(bad))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(config.bindings.count, 3)
        XCTAssertEqual(liveKey(up3)?.key, .code(36))
        XCTAssertTrue(engine.actions(for: Trigger(gesture: left4, held: [])).isEmpty)

        let fnHeld = [Binding(gesture: left4, holding: ["fn"], action: .key("a", modifiers: []))]
        XCTAssertThrowsError(try setBindings(fnHeld))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(liveKey(up3)?.key, .code(36))
    }

    func testDeletingEverythingThenUndoing() throws {
        var removed: [(Binding, Int)] = []
        while let (list, binding) = BindingEdits.delete(at: 0, in: config.bindings) {
            try setBindings(list)
            removed.append((binding, 0))
        }
        try assertSavedAndLive([])
        XCTAssertEqual((try fileObject()["bindings"] as? [Any])?.count, 0)
        let (last, index) = try XCTUnwrap(removed.last)
        try setBindings(BindingEdits.restore(last, at: index, in: config.bindings))
        try assertSavedAndLive([last])
    }
}

final class TouchShapeTests: XCTestCase {
    func testTouchKeepsContactShapeAndDefaultsToZero() {
        let shaped = Touch(x: 0.1, y: 0.2, identifier: 1, state: 4, size: 0.5, majorAxis: 9, minorAxis: 7)
        XCTAssertEqual(shaped.size, 0.5)
        XCTAssertEqual(shaped.majorAxis, 9)
        XCTAssertEqual(shaped.minorAxis, 7)
        let plain = Touch(x: 0.1, y: 0.2, identifier: 1)
        XCTAssertEqual(plain.size, 0)
        XCTAssertEqual(plain.majorAxis, 0)
        XCTAssertEqual(plain.minorAxis, 0)
    }
}

final class TraceTests: XCTestCase {
    private func frame(_ t: Double, _ ys: [Double]) -> TouchFrame {
        TouchFrame(touches: ys.enumerated().map { Touch(x: 0.3 + Double($0) * 0.1, y: $1, identifier: $0, state: 4, size: 0.42, majorAxis: 8.5, minorAxis: 7.25) }, timestamp: t)
    }

    func testTraceRoundTripsThroughFile() throws {
        let trace = Trace(name: "swipe-3-up", expect: .swipe(fingers: 3, direction: .up), frames: [
            frame(10.0, [0.3, 0.3, 0.3]), frame(10.0083, [0.35, 0.35, 0.35]), frame(10.0166, []),
            frame(11.0, [0.2, 0.2]), frame(11.0083, []),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try trace.write(to: url)
        XCTAssertEqual(try Trace.load(from: url), trace)
    }

    func testTraceSplitsSessionsAtLift() {
        let trace = Trace(name: "t", expect: nil, frames: [
            frame(0, []), frame(1, [0.3]), frame(2, [0.3, 0.3]), frame(3, [0.4, 0.4]), frame(4, []),
            frame(5, [0.5]), frame(6, [0.5]), frame(7, []),
        ])
        XCTAssertEqual(trace.sessions.count, 2)
        XCTAssertEqual(trace.sessions[0].count, 4)
        XCTAssertEqual(trace.sessions[1].count, 3)
    }
}
