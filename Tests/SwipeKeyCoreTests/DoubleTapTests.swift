import CoreGraphics
import XCTest
@testable import SwipeKeyCore

/// A French AZERTY Mac: "@" is the key left of "&" (key code 10), typed without Shift.
private struct AtLayout: KeyboardLayout {
    func keyCode(for character: Character) -> CGKeyCode? { ["@": 10, "a": 12][character] }
}

final class DoubleTapTests: XCTestCase {
    private let at: CGKeyCode = 10, a: CGKeyCode = 12, enter: CGKeyCode = 36
    private let atAtIsEnter = KeyRemap(from: .init(key: "@", taps: 2), to: .init(key: "return"))
    private let drop = DoubleTapper.Decision(post: [], keep: false)
    private let pass = DoubleTapper.Decision(post: [], keep: true)

    private func tapper() throws -> DoubleTapper { try DoubleTapper([atAtIsEnter], layout: AtLayout()) }
    private func down(_ code: CGKeyCode, _ flags: CGEventFlags = []) -> KeystrokeEvent { KeystrokeEvent(kind: .keyDown, keyCode: code, flags: flags) }
    private func up(_ code: CGKeyCode, _ flags: CGEventFlags = []) -> KeystrokeEvent { KeystrokeEvent(kind: .keyUp, keyCode: code, flags: flags) }

    func testTwoQuickPressesSendTheOtherKeyAndNothingElse() throws {
        var t = try tapper()
        XCTAssertEqual(t.handle(keyCode: at, flags: [], isDown: true, isRepeat: false, at: 0), drop)
        XCTAssertEqual(t.handle(keyCode: at, flags: [], isDown: false, isRepeat: false, at: 0.08), drop)
        XCTAssertEqual(t.handle(keyCode: at, flags: [], isDown: true, isRepeat: false, at: 0.16),
                       DoubleTapper.Decision(post: [down(enter), up(enter)], keep: false))
        XCTAssertEqual(t.handle(keyCode: at, flags: [], isDown: false, isRepeat: false, at: 0.22), drop)
        XCTAssertNil(t.deadline)
        XCTAssertEqual(t.expire(at: 1), [])
    }

    func testASinglePressTypesTheKeyOnceTheWindowHasPassed() throws {
        var t = try tapper()
        _ = t.handle(keyCode: at, flags: [], isDown: true, isRepeat: false, at: 0)
        _ = t.handle(keyCode: at, flags: [], isDown: false, isRepeat: false, at: 0.08)
        XCTAssertEqual(t.deadline, DoubleTapper.defaultWindow)
        XCTAssertEqual(t.expire(at: 0.1), [], "too early")
        XCTAssertEqual(t.expire(at: DoubleTapper.defaultWindow), [down(at), up(at)])
        XCTAssertNil(t.deadline)
    }

    func testAnotherKeyTypesTheHeldBackPressFirst() throws {
        var t = try tapper()
        _ = t.handle(keyCode: at, flags: [], isDown: true, isRepeat: false, at: 0)
        _ = t.handle(keyCode: at, flags: [], isDown: false, isRepeat: false, at: 0.05)
        // "x@a…": the "a" must come after the "@"
        XCTAssertEqual(t.handle(keyCode: a, flags: [], isDown: true, isRepeat: false, at: 0.1),
                       DoubleTapper.Decision(post: [down(at), up(at)], keep: true))
        XCTAssertEqual(t.handle(keyCode: a, flags: [], isDown: false, isRepeat: false, at: 0.15), pass)
        XCTAssertEqual(t.expire(at: 1), [])
    }

    func testWithModifiersTheKeyIsUntouched() throws {
        var t = try tapper()
        // ⌘@ starts and stops Wispr Flow: no delay
        XCTAssertEqual(t.handle(keyCode: at, flags: .maskCommand, isDown: true, isRepeat: false, at: 0), pass)
        XCTAssertEqual(t.handle(keyCode: at, flags: .maskCommand, isDown: false, isRepeat: false, at: 0.05), pass)
        XCTAssertEqual(t.handle(keyCode: at, flags: .maskCommand, isDown: true, isRepeat: false, at: 0.1), pass)
        XCTAssertNil(t.deadline)
    }

    func testHoldingTheKeyRepeatsItAsUsual() throws {
        var t = try tapper()
        _ = t.handle(keyCode: at, flags: [], isDown: true, isRepeat: false, at: 0)
        XCTAssertEqual(t.handle(keyCode: at, flags: [], isDown: true, isRepeat: true, at: 0.2),
                       DoubleTapper.Decision(post: [down(at)], keep: true))
        XCTAssertEqual(t.handle(keyCode: at, flags: [], isDown: true, isRepeat: true, at: 0.25), pass)
        XCTAssertEqual(t.handle(keyCode: at, flags: [], isDown: false, isRepeat: false, at: 0.4), pass)
    }

    func testStillHeldWhenTheWindowEndsItGoesDownAndItsReleasePasses() throws {
        var t = try tapper()
        _ = t.handle(keyCode: at, flags: [], isDown: true, isRepeat: false, at: 0)
        XCTAssertEqual(t.expire(at: 0.3), [down(at)])
        XCTAssertEqual(t.handle(keyCode: at, flags: [], isDown: false, isRepeat: false, at: 0.35), pass)
    }

    func testASecondPressTooLateIsAFreshStart() throws {
        var t = try tapper()
        _ = t.handle(keyCode: at, flags: [], isDown: true, isRepeat: false, at: 0)
        _ = t.handle(keyCode: at, flags: [], isDown: false, isRepeat: false, at: 0.05)
        // the timer hasn't run yet, but the window is over: type the first, hold back the second
        XCTAssertEqual(t.handle(keyCode: at, flags: [], isDown: true, isRepeat: false, at: 0.4),
                       DoubleTapper.Decision(post: [down(at), up(at)], keep: false))
        XCTAssertEqual(t.deadline, 0.4 + DoubleTapper.defaultWindow)
    }

    func testOnlyDoubleTapRemapsAreTaken() throws {
        let single = KeyRemap(from: .init(key: "a"), to: .init(key: "escape"))
        var t = try DoubleTapper([single], layout: AtLayout())
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.handle(keyCode: a, flags: [], isDown: true, isRepeat: false, at: 0), pass)
        // and the plain remapper leaves double taps to it
        XCTAssertNil(try KeyRemapper([atAtIsEnter], layout: AtLayout()).map(keyCode: at, flags: [], sender: { ("hardware", "") }))
    }

    func testOnlyOneOrTwoTaps() {
        let triple = KeyRemap(from: .init(key: "@", taps: 3), to: .init(key: "return"))
        XCTAssertThrowsError(try DoubleTapper([triple], layout: AtLayout()))
        XCTAssertThrowsError(try KeyRemapper([triple], layout: AtLayout()))
    }

    func testTapsInTheConfig() throws {
        let json = #"[{"from":{"key":"@","taps":2},"to":{"key":"return"}},{"from":{"key":"space"},"to":{"key":"escape"}}]"#
        let remaps = try JSONDecoder().decode([KeyRemap].self, from: Data(json.utf8))
        XCTAssertEqual(remaps.map(\.from.taps), [2, 1])
        let written = String(decoding: try JSONEncoder().encode(remaps[1]), as: UTF8.self)
        XCTAssertFalse(written.contains("taps"), "a plain remap is written as before")
    }
}
