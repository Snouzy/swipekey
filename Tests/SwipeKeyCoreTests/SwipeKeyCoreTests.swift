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
