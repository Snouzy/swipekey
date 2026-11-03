import CoreGraphics
import XCTest
@testable import SwipeKeyCore

private struct Keys: KeyboardLayout {
    func keyCode(for character: Character) -> CGKeyCode? { ["@": 10, "a": 12, "b": 11, "c": 8][character] }
}

final class RemapPlaceTests: XCTestCase {
    private func remap(_ key: String = "a", to: String = "b", taps: Int = 1, inApp: String? = nil, url: String? = nil) -> KeyRemap {
        KeyRemap(from: .init(key: key, taps: taps, inApp: inApp, url: url), to: .init(key: to))
    }
    private func on(_ site: String) -> (RemapPlace) -> Bool { { $0.contains(app: nil, url: "https://\(site)/") } }
    private let nowhere: (RemapPlace) -> Bool = { _ in false }

    func testAPlaceIsOneAppOrOneWebsite() throws {
        XCTAssertThrowsError(try KeyRemapper([remap(inApp: "Figma", url: "a.com")], layout: Keys()))
        XCTAssertThrowsError(try KeyRemapper([remap(url: " ")], layout: Keys()))
        XCTAssertThrowsError(try DoubleTapper([remap(taps: 2, url: " ")], layout: Keys()))
        let figma = try RemapPlace(inApp: "Figma", url: nil)!
        XCTAssertTrue(figma.contains(app: ForegroundApp(name: "figma", bundleID: "x"), url: nil))
        XCTAssertFalse(figma.contains(app: nil, url: nil))
        XCTAssertFalse(try RemapPlace(inApp: nil, url: "a.com")!.contains(app: nil, url: nil), "address unknown: not there")
        XCTAssertNil(try RemapPlace(inApp: nil, url: nil))
    }

    func testAPlaceIsKeptInTheFile() throws {
        let json = #"{"from":{"key":"a","url":"a.com"},"to":{"key":"b"}}"#
        let decoded = try JSONDecoder().decode(KeyRemap.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.from.url, "a.com")
        let again = try JSONDecoder().decode(KeyRemap.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(remap()), as: UTF8.self).contains("url"))
    }

    func testARemapWorksOnlyOnItsSite() throws {
        let r = try KeyRemapper([remap(url: "github.com")], layout: Keys())
        XCTAssertNotNil(r.map(keyCode: 12, flags: [], sender: { ("", "") }, within: on("github.com")))
        XCTAssertNil(r.map(keyCode: 12, flags: [], sender: { ("", "") }, within: on("example.com")))
    }

    func testTheSiteWinsOverTheGeneralRemapWhateverTheOrder() throws {
        let r = try KeyRemapper([remap(to: "c"), remap(url: "github.com")], layout: Keys())
        XCTAssertEqual(r.map(keyCode: 12, flags: [], sender: { ("", "") }, within: on("github.com"))?.keyCode, 11)
        XCTAssertEqual(r.map(keyCode: 12, flags: [], sender: { ("", "") }, within: on("example.com"))?.keyCode, 8)
    }

    func testTwoSitesCanGiveTheSameKeyTwoMeanings() throws {
        let r = try KeyRemapper([remap(to: "c", url: "a.com"), remap(url: "b.com")], layout: Keys())
        XCTAssertEqual(r.map(keyCode: 12, flags: [], sender: { ("", "") }, within: on("a.com"))?.keyCode, 8)
        XCTAssertEqual(r.map(keyCode: 12, flags: [], sender: { ("", "") }, within: on("b.com"))?.keyCode, 11)
    }

    func testAReleaseFollowsItsPressAfterLeavingTheSite() throws {
        var r = try KeyRemapper([remap(url: "a.com")], layout: Keys())
        XCTAssertNotNil(r.handle(keyCode: 12, flags: [], isDown: true, sender: { ("", "") }, within: on("a.com")))
        XCTAssertNotNil(r.handle(keyCode: 12, flags: [], isDown: false, sender: { ("", "") }, within: nowhere))
    }

    func testADoubleTapOnASiteDoesNotHoldTheKeyElsewhere() throws {
        var t = try DoubleTapper([remap("@", to: "return", taps: 2, url: "a.com")], layout: Keys())
        let pass = DoubleTapper.Decision(post: [], keep: true)
        XCTAssertEqual(t.handle(keyCode: 10, flags: [], isDown: true, isRepeat: false, at: 0, within: on("b.com")), pass)
        XCTAssertNil(t.deadline)
    }

    func testADoubleTapSendsWhatItsSiteAsks() throws {
        var t = try DoubleTapper([remap("@", to: "b", taps: 2), remap("@", to: "c", taps: 2, url: "a.com")], layout: Keys())
        _ = t.handle(keyCode: 10, flags: [], isDown: true, isRepeat: false, at: 0, within: on("a.com"))
        _ = t.handle(keyCode: 10, flags: [], isDown: false, isRepeat: false, at: 0.05, within: on("a.com"))
        let d = t.handle(keyCode: 10, flags: [], isDown: true, isRepeat: false, at: 0.1, within: on("a.com"))
        XCTAssertEqual(d.post.first?.keyCode, 8)
    }

    func testTwoDoubleTapsOnTheSameKeyAndPlaceAreRefused() {
        XCTAssertThrowsError(try DoubleTapper([remap("@", taps: 2, url: "a.com"), remap("@", to: "c", taps: 2, url: "A.com")], layout: Keys()))
    }

    func testARemapForAPlaceWinsOverAnExclusionButAGeneralOneDoesNot() throws {
        let all: (String) -> Bool = { _ in true }
        let scoped = try KeyRemapper([remap(url: "a.com")], layout: Keys())
        XCTAssertNotNil(scoped.map(keyCode: 12, flags: [], sender: { ("", "") }, excluded: all, within: on("a.com")))
        let general = try KeyRemapper([remap()], layout: Keys())
        XCTAssertNil(general.map(keyCode: 12, flags: [], sender: { ("", "") }, excluded: all, within: on("a.com")))

        var t = try DoubleTapper([remap("@", taps: 2, url: "a.com")], layout: Keys())
        _ = t.handle(keyCode: 10, flags: [], isDown: true, isRepeat: false, at: 0, excluded: all, within: on("a.com"))
        XCTAssertNotNil(t.deadline)
    }

    func testClashes() {
        func clashes(_ a: KeyRemap, _ b: KeyRemap) -> Bool {
            !RemapEdits.clashes(with: a, editing: nil, in: [b], layout: Keys()).isEmpty
        }
        XCTAssertFalse(clashes(remap(url: "a.com"), remap(url: "b.com")))
        XCTAssertTrue(clashes(remap(url: "a.com"), remap(to: "c", url: "a.com")))
        XCTAssertFalse(clashes(remap(url: "a.com"), remap(to: "c")), "the site wins")
        XCTAssertFalse(clashes(remap(taps: 2, url: "a.com"), remap(to: "c", taps: 2)), "the site wins")
        XCTAssertTrue(clashes(remap(url: "a.com"), remap(to: "c", taps: 2)), "the double tap holds the key back before the site's remap")
        XCTAssertFalse(clashes(remap(url: "a.com"), remap(to: "c", taps: 2, url: "b.com")))
    }

    func testTheDraftBuildsAndReadsBackAPlace() {
        var draft = RemapDraft()
        draft.key = "a"
        draft.toKey = "b"
        draft.place = .website
        XCTAssertFalse(draft.placeIsComplete)
        draft.placeValue = " github.com "
        XCTAssertTrue(draft.placeIsComplete)
        XCTAssertEqual(draft.remap?.from.url, "github.com")
        XCTAssertEqual(RemapDraft(draft.remap!).place, .website)
        draft.place = .everywhere
        XCTAssertNil(draft.remap?.from.url)
        XCTAssertEqual(remap(url: "a.com").subtitle, "only on a.com")
        XCTAssertEqual(remap(taps: 2, url: "a.com").subtitle, "a single A still types A, only on a.com")
    }
}
