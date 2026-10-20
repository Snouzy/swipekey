import CoreGraphics
import XCTest
@testable import SwipeKeyCore

/// A French AZERTY Mac: "@" is the key left of "&" (key code 10).
private struct Layout: KeyboardLayout {
    func keyCode(for character: Character) -> CGKeyCode? { ["@": 10, "a": 12][character] }
}

final class RemapEditingTests: XCTestCase {
    private let layout = Layout()
    private let atAt = KeyRemap(from: .init(key: "@", taps: 2), to: .init(key: "return"))
    private let logi = KeyRemap(from: .init(key: "space", app: "Logi Options+"), to: .init(key: "space", modifiers: ["control", "option"]))
    private func every(_ key: String, _ modifiers: [String] = [], app: String? = nil, to: String = "escape") -> KeyRemap {
        KeyRemap(from: .init(key: key, modifiers: modifiers, app: app), to: .init(key: to))
    }
    private func clashes(_ remap: KeyRemap, _ list: [KeyRemap], editing: Int? = nil) -> [Int] {
        RemapEdits.clashes(with: remap, editing: editing, in: list, layout: layout)
    }

    func testDraftBuildsADoubleTap() {
        var draft = RemapDraft()
        draft.key = "@"
        draft.taps = 2
        draft.app = "Logi"
        draft.toKey = "return"
        XCTAssertEqual(draft.remap, atAt, "a double tap has no app")
    }

    func testDraftTrimsTheApp() {
        var draft = RemapDraft(logi)
        draft.app = "  Logi Options+ "
        XCTAssertEqual(draft.remap?.from.app, "Logi Options+")
        draft.app = "   "
        XCTAssertEqual(draft.remap?.from.app, nil)
        XCTAssertNotNil(draft.remap)
    }

    func testDraftIncompleteOrInvalid() {
        var draft = RemapDraft()
        draft.key = "a"
        XCTAssertNil(draft.remap)
        XCTAssertNil(draft.error)
        draft.key = "nope-key"
        draft.toKey = "return"
        XCTAssertNil(draft.remap)
        XCTAssertNotNil(draft.error)
    }

    func testDraftRoundTrips() {
        XCTAssertEqual(RemapDraft(logi).remap, logi)
        XCTAssertEqual(RemapDraft(atAt).remap, atAt)
    }

    func testClashComparesPhysicalKeys() {
        XCTAssertEqual(clashes(every("@"), [every("10")]), [0])
    }

    func testDoubleTapClashesWhateverTheModifiers() {
        XCTAssertEqual(clashes(atAt, [every("@", ["cmd"])]), [0])
        XCTAssertEqual(clashes(every("@", ["cmd"]), [atAt]), [0])
    }

    func testSameKeyDifferentModifiersDontClash() {
        XCTAssertEqual(clashes(every("a"), [every("a", ["cmd"])]), [])
        XCTAssertEqual(clashes(every("a", ["command"]), [every("a", ["cmd"])]), [0], "same modifier, two spellings")
    }

    func testDifferentAppsDontClash() {
        XCTAssertEqual(clashes(logi, [every("space", app: "Other")]), [])
        XCTAssertEqual(clashes(logi, [every("space")]), [0], "any sender includes Logi Options+")
        XCTAssertEqual(clashes(logi, [every("space", app: "LOGI options+")]), [0])
    }

    func testEditingDoesntClashWithItself() {
        XCTAssertEqual(clashes(atAt, [atAt], editing: 0), [])
    }

    func testExistingClashIsReported() {
        let list = [every("a", to: "b"), every("a", to: "c")]
        XCTAssertEqual(clashes(list[0], list, editing: 0), [1])
    }

    func testSaveReplacesTheOriginalOrAppends() {
        let edited = KeyRemap(from: .init(key: "@", taps: 2), to: .init(key: "tab"))
        XCTAssertEqual(RemapEdits.save(edited, replacing: atAt, near: 1, in: [logi, atAt]), [logi, edited])
        // stale hint: found by content
        XCTAssertEqual(RemapEdits.save(edited, replacing: atAt, near: 0, in: [atAt, logi]), [edited, logi])
        // the original is gone: saved as new
        XCTAssertEqual(RemapEdits.save(edited, replacing: atAt, near: 0, in: [logi]), [logi, edited])
        XCTAssertEqual(RemapEdits.save(atAt, replacing: nil, near: nil, in: [logi]), [logi, atAt])
    }

    func testDeleteAlwaysWorks() throws {
        let list = [every("a", to: "b"), every("a", to: "c")]
        let (rest, removed) = try XCTUnwrap(RemapEdits.delete(at: 0, in: list))
        XCTAssertEqual(rest, [list[1]])
        XCTAssertEqual(removed, list[0])
        XCTAssertNil(RemapEdits.delete(at: 5, in: list))
    }

    func testRestore() {
        XCTAssertEqual(RemapEdits.restore(atAt, at: 0, in: [logi], layout: layout), [atAt, logi])
        XCTAssertEqual(RemapEdits.restore(atAt, at: 9, in: [logi], layout: layout), [logi, atAt])
        XCTAssertNil(RemapEdits.restore(atAt, at: 0, in: [every("@", to: "tab")], layout: layout), "a remap added since uses that key")
    }

    func testCardText() {
        XCTAssertEqual(atAt.title, "Press @ twice")
        XCTAssertEqual(atAt.subtitle, "a single @ still types @")
        XCTAssertEqual(atAt.fromCaps, ["@", "@"])
        XCTAssertEqual(atAt.toCaps, ["Return"])
        XCTAssertEqual(logi.title, "Space")
        XCTAssertEqual(logi.subtitle, "only when Logi Options+ sends it")
        XCTAssertEqual(logi.fromCaps, ["Space"])
        XCTAssertEqual(logi.toCaps, ["⌃", "⌥", "Space"])
        XCTAssertNil(every("a").subtitle)
    }
}
