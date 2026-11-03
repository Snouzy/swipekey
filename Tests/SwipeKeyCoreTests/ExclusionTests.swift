import CoreGraphics
import XCTest
@testable import SwipeKeyCore

private struct AtLayout: KeyboardLayout {
    func keyCode(for character: Character) -> CGKeyCode? { ["@": 10, "a": 12][character] }
}

final class ExclusionTests: XCTestCase {
    private func matches(_ pattern: String, _ url: String) throws -> Bool {
        try URLPattern(pattern).matches(url)
    }

    func testABareHostCoversTheWholeSiteAndNoOther() throws {
        XCTAssertTrue(try matches("github.com", "https://github.com/"))
        XCTAssertTrue(try matches("github.com", "https://www.github.com/a/b?tab=1#top"))
        XCTAssertTrue(try matches("GitHub.com", "http://github.com/a"))
        XCTAssertFalse(try matches("github.com", "https://notgithub.com/"))
        XCTAssertFalse(try matches("github.com", "https://gist.github.com/"))
        XCTAssertFalse(try matches("github.com", "https://example.com/github.com"))
    }

    func testAPathCoversThatPageAndWhatIsUnderIt() throws {
        XCTAssertTrue(try matches("github.com/snouzy", "https://github.com/snouzy"))
        XCTAssertTrue(try matches("github.com/snouzy", "https://github.com/snouzy/holt"))
        XCTAssertFalse(try matches("github.com/snouzy", "https://github.com/snouzy2"))
    }

    func testAStarMatchesAnyTextAndAQueryDoesNotGetInTheWay() throws {
        let pull = "github.com/*/pull/*"
        XCTAssertTrue(try matches(pull, "https://github.com/a/b/pull/12"))
        XCTAssertTrue(try matches(pull, "https://github.com/a/b/pull/12/files?w=1"))
        XCTAssertFalse(try matches(pull, "https://github.com/a/b/issues/12"))
        XCTAssertTrue(try matches("*.google.com", "https://docs.google.com/d/1"))
        XCTAssertTrue(try matches("docs.google.com/*", "https://docs.google.com/"))
    }

    func testAPatternMayBePastedWithItsScheme() throws {
        XCTAssertTrue(try matches("https://github.com/a/", "https://github.com/a/b"))
    }

    func testAnEmptyPatternIsRefused() {
        XCTAssertThrowsError(try URLPattern("  "))
        XCTAssertThrowsError(try URLPattern("https://"))
    }

    func testAnExclusionNamesExactlyOneAppOrURL() {
        XCTAssertThrowsError(try ExclusionList([Exclusion()]))
        XCTAssertThrowsError(try ExclusionList([Exclusion(app: "Safari", url: "a.com")]))
    }

    func testTheAppMatchesByBundleIdOrNameIgnoringCase() throws {
        let list = try ExclusionList([Exclusion(app: "com.googlecode.iTerm2"), Exclusion(app: "Figma")])
        XCTAssertTrue(list.excludes("@@", app: ForegroundApp(name: "iTerm2", bundleID: "com.googlecode.iterm2"), url: nil))
        XCTAssertTrue(list.excludes("@@", app: ForegroundApp(name: "figma", bundleID: "x"), url: nil))
        XCTAssertFalse(list.excludes("@@", app: ForegroundApp(name: "Notes", bundleID: "com.apple.Notes"), url: nil))
    }

    func testOnlyLimitsAnExclusionToTheNamedShortcuts() throws {
        let list = try ExclusionList([Exclusion(url: "github.com", only: ["@@"])])
        let chrome = ForegroundApp(name: "Chrome", bundleID: "com.google.Chrome")
        XCTAssertTrue(list.excludes("@@", app: chrome, url: "https://github.com/a"))
        XCTAssertFalse(list.excludes("&&", app: chrome, url: "https://github.com/a"))
        XCTAssertFalse(list.excludes("@@", app: chrome, url: "https://example.com/"))
        XCTAssertFalse(list.excludes("@@", app: chrome, url: nil), "URL unknown: the shortcut keeps working")
    }

    func testOnlyURLExclusionsNeedTheBrowser() throws {
        XCTAssertFalse(try ExclusionList([Exclusion(app: "Figma")]).watchesURLs)
        XCTAssertTrue(try ExclusionList([Exclusion(url: "a.com")]).watchesURLs)
    }

    func testShortcutNames() throws {
        XCTAssertEqual(KeyRemap(from: .init(key: "@", taps: 2), to: .init(key: "return")).shortcutName, "@@")
        XCTAssertEqual(KeyRemap(from: .init(key: "space", taps: 2), to: .init(key: "return")).shortcutName, "space twice")
        XCTAssertEqual(KeyRemap(from: .init(key: "a", modifiers: ["cmd", "shift"]), to: .init(key: "b")).shortcutName, "shift+cmd+a")
        XCTAssertEqual(Binding(gesture: .swipe(fingers: 3, direction: .up), holding: ["cmd"], action: .key("a", modifiers: [])).shortcutName, "cmd + 3-finger swipe up")
    }

    func testConfigReadsAndKeepsExclusions() throws {
        let json = #"{"bindings":[],"exclusions":[{"app":"Figma"},{"url":"a.com","only":["@@"]}]}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.exclusions, [Exclusion(app: "Figma"), Exclusion(url: "a.com", only: ["@@"])])
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"bindings":[]}"#.utf8))
        XCTAssertEqual(old.exclusions, [])
    }

    // MARK: The keyboard

    func testAnExcludedDoubleTapKeyIsNotHeldBack() throws {
        var t = try DoubleTapper([KeyRemap(from: .init(key: "@", taps: 2), to: .init(key: "return"))], layout: AtLayout())
        let pass = DoubleTapper.Decision(post: [], keep: true)
        XCTAssertEqual(t.handle(keyCode: 10, flags: [], isDown: true, isRepeat: false, at: 0, excluded: { $0 == "@@" }), pass)
        XCTAssertNil(t.deadline)
        XCTAssertEqual(t.handle(keyCode: 10, flags: [], isDown: false, isRepeat: false, at: 0.05, excluded: { $0 == "@@" }), pass)
        XCTAssertEqual(t.handle(keyCode: 10, flags: [], isDown: true, isRepeat: false, at: 0.1, excluded: { $0 == "@@" }), pass)
    }

    func testAnExcludedRemapLeavesTheKeyAlone() throws {
        let r = try KeyRemapper([KeyRemap(from: .init(key: "@"), to: .init(key: "a"))], layout: AtLayout())
        XCTAssertNil(r.map(keyCode: 10, flags: [], sender: { ("", "") }, excluded: { $0 == "@" }))
        XCTAssertNotNil(r.map(keyCode: 10, flags: [], sender: { ("", "") }, excluded: { _ in false }))
    }

    func testAPressRewrittenBeforeAnExclusionStillReleasesRewritten() throws {
        var r = try KeyRemapper([KeyRemap(from: .init(key: "@"), to: .init(key: "a"))], layout: AtLayout())
        XCTAssertNotNil(r.handle(keyCode: 10, flags: [], isDown: true, sender: { ("", "") }, excluded: { _ in false }))
        XCTAssertNotNil(r.handle(keyCode: 10, flags: [], isDown: false, sender: { ("", "") }, excluded: { _ in true }))
    }

    // MARK: The trackpad

    func testAnExcludedGestureRunsNothing() throws {
        let config = Config(bindings: [Binding(gesture: .swipe(fingers: 3, direction: .up), action: .key("return", modifiers: []))])
        let engine = try Engine(config: config, heldModifiers: { [] })
        engine.isExcluded = { $0 == "3-finger swipe up" }
        var fired = false
        engine.onGesture = { _ in fired = true }
        engine.fire(Trigger(gesture: .swipe(fingers: 3, direction: .up), held: []))
        XCTAssertFalse(fired)
    }

    // MARK: The browser

    func testOnlyKnownBrowsersAreAsked() {
        XCTAssertNotNil(BrowserURL.script(forBundleID: "com.google.Chrome"))
        XCTAssertNotNil(BrowserURL.script(forBundleID: "com.brave.Browser"))
        XCTAssertNotNil(BrowserURL.script(forBundleID: "com.apple.Safari"))
        XCTAssertNil(BrowserURL.script(forBundleID: "org.mozilla.firefox"))
        XCTAssertNil(BrowserURL.script(forBundleID: "com.apple.Notes"))
    }
}

final class DockIconConfigTests: XCTestCase {
    func testTheDockIconIsOffUnlessAsked() throws {
        XCTAssertFalse(try JSONDecoder().decode(Config.self, from: Data(#"{"bindings":[]}"#.utf8)).dockIcon)
        XCTAssertTrue(try JSONDecoder().decode(Config.self, from: Data(#"{"bindings":[],"dockIcon":true}"#.utf8)).dockIcon)
    }
}

final class DockQuitTests: XCTestCase {
    func testQuittingFromTheDockKeepsSwipekeyInTheMenuBar() {
        XCTAssertTrue(DockQuit.staysInMenuBar(menuBarIcon: true, systemReason: nil))
    }
    func testLoggingOutOrShuttingDownIsNeverHeldBack() {
        XCTAssertFalse(DockQuit.staysInMenuBar(menuBarIcon: true, systemReason: 0x7368_7574))
    }
    func testWithoutAMenuBarIconThereIsNothingToStayIn() {
        XCTAssertFalse(DockQuit.staysInMenuBar(menuBarIcon: false, systemReason: nil))
    }
}
