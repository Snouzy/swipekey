# Smarter Recognition, Step 1: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make swipe and pinch recognition sturdier against the ways a real hand varies: fingers landing over time, unbound gestures locking a session, early lifts, short fast flicks, fingers that don't move together. Prove it on traces recorded from Mathias's trackpad.

**Architecture:** First, a guided recorder (`swipekey --record <dir>`) and a trace format, so real frames become test fixtures before any rule changes. Then the recognizers in `SwipeKeyCore` gain:
- a bound-gesture filter, supplied by the engine;
- a finger-count settle;
- per-finger travel;
- a flick rule and a finger-agreement rule;
- near-miss reports.

Each rule is pinned by synthetic unit tests and checked against the fixtures.

**Tech Stack:** Swift 5.9 package, macOS 13+, XCTest, private MultitouchSupport through the `CMultitouch` C bridge.

**Spec:** `docs/superpowers/specs/2026-10-19-smarter-recognition-design.md`

## Global Constraints

- macOS 13+, `swift-tools-version:5.9`. CI uses an older Swift compiler: one operation per line in numeric code, plain `Double`s, no long mixed CGFloat/Double expressions (see e836372).
- All recognition logic lives in `SwipeKeyCore` and is testable without a trackpad or UI.
- Existing `config.json` files keep working unchanged. `swipeThreshold` and `pinchThreshold` keep their meaning.
- 2-finger gestures never get easier to trigger: the flick rule and the early-lift rule apply only to 3+ fingers. For 2 fingers, the distance needed stays exactly as configured.
- No more than ~100 ms of extra delay on a normal swipe.
- Never read or write `~/.config/swipekey/config.json` in tests. Use temp files and `Config(...)` values.
- Never `git commit` or `git push` without Mathias's explicit go-ahead for that commit. Pushing to `main` is allowed in this repo: `git push origin main`, then verify with `git ls-remote`. Never `--force`. No co-author line, no "Generated with" line.
- Never use `rm -rf` (a hook blocks it).

## Review Focus

1. **A 3-finger swipe that starts with 2 fingers, in a direction that has a 2-finger binding** (2 left → ⌘←). Expected: only the 3-finger swipe fires, never ⌘←. Test: Task 4, `testThirdFingerLandingLateWinsOverBoundTwoFingerSwipe`.
2. **A long sideways 2-finger scroll.** Expected: it fires no more often than with today's recognizer. Test: Task 8, `testScrollFixtureFiresNoMoreThanBaseline`.
3. **A bound gesture that needs a held modifier, done without the modifier.** Expected: it doesn't fire and doesn't block a gesture bound without a modifier. Test: Task 3, `testModifierOnlyBindingDoesNotLockWithoutModifier`.
4. **Pause, capture mode or a config reload in the middle of a swipe.** Expected: the new per-session state is reset and nothing fires halfway. Test: Task 3, `testReloadMidSwipeStartsOver`.
5. **Frames with identical timestamps** (the existing tests use `timestamp: 0`). Expected: no division by zero in the speed rule and no NaN. Test: Task 6, `testSameTimestampFramesNeverFlick`.

---

### Task 1: Touch contact shape through the C bridge

**Files:**
- Modify: `Sources/CMultitouch/include/CMultitouch.h` (`SKTouch`)
- Modify: `Sources/CMultitouch/multitouch.c` (`contactCallback`)
- Modify: `Sources/SwipeKeyCore/Gesture.swift` (`Touch`)
- Modify: `Sources/SwipeKeyCore/MultitouchSource.swift`
- Test: `Tests/SwipeKeyCoreTests/SwipeKeyCoreTests.swift`

**Interfaces:**
- Produces: `SKTouch` gains `float size, majorAxis, minorAxis` (copied from `MTTouch.size`, `.majorAxis`, `.minorAxis`). `Touch` gains `public var size: Double`, `majorAxis: Double`, `minorAxis: Double`, all defaulting to `0` in `init(x:y:identifier:state:size:majorAxis:minorAxis:)`, so every existing call site compiles unchanged.

- [ ] **Step 1: Write the failing test** `testTouchKeepsContactShapeAndDefaultsToZero`: `Touch(x: 0.1, y: 0.2, identifier: 1, state: 4, size: 0.5, majorAxis: 9, minorAxis: 7)` keeps those values. `Touch(x: 0.1, y: 0.2, identifier: 1)` has `size == 0`, `majorAxis == 0`, `minorAxis == 0`.
- [ ] **Step 2:** Run `swift test --filter testTouchKeepsContactShape`. Expected: compile failure (no such init).
- [ ] **Step 3:** Add the fields to `SKTouch`, fill them in `contactCallback`, add them to `Touch`, and pass them in `MultitouchSource.start`.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.

### Task 2: Trace format and the guided recorder

**Files:**
- Create: `Sources/SwipeKeyCore/Trace.swift`
- Modify: `Sources/swipekey/main.swift` (the `--record <dir>` flag and usage text)
- Create: `Sources/swipekey/Recorder.swift`
- Modify: `Package.swift` (test target: `resources: [.copy("Fixtures")]`)
- Create: `Tests/SwipeKeyCoreTests/Fixtures/.gitkeep`
- Test: `Tests/SwipeKeyCoreTests/SwipeKeyCoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct Trace: Codable, Equatable { public var name: String; public var expect: Gesture?; public var frames: [TouchFrame] }`.
  - `public static func load(from url: URL) throws -> Trace` and `func write(to url: URL) throws`.
  - `public var sessions: [[TouchFrame]]`: frames split at each frame with no touching finger. That frame ends its session and is included in it. Leading empty frames are dropped.
  - `TouchFrame` becomes `Equatable`.
- Compact encoding, to keep fixtures small. Each frame is `[timestamp, [[id, state, x, y, size, majorAxis, minorAxis], …]]`, with numbers rounded to 4 decimals. Only frames with at least one touch are written, plus the first empty frame after each session.
- Recorder steps, in this order. Each step has a file name, an instruction and an `expect` value:

| file | instruction | expect |
|---|---|---|
| `swipe-3-up` | 15 three-finger swipes up, mix quick and lazy | `.swipe(3,.up)` |
| `swipe-3-down` | 10 three-finger swipes down | `.swipe(3,.down)` |
| `swipe-3-left` | 10 three-finger swipes left | `.swipe(3,.left)` |
| `swipe-3-right` | 10 three-finger swipes right | `.swipe(3,.right)` |
| `swipe-2-left` | 10 two-finger swipes left | `.swipe(2,.left)` |
| `swipe-2-right` | 10 two-finger swipes right | `.swipe(2,.right)` |
| `scroll-2` | Scroll normally for about a minute: up, down and sideways, in a browser or a long document | `nil` |
| `pinch-2-in` | 10 two-finger pinches in | `.pinch(2,.in)` |
| `thumb-3-up` | 10 three-finger swipes up with your thumb resting on the trackpad | `.swipe(3,.up)` |

  The recorder prints the instruction, records every frame until Enter, then writes `<dir>/<file>.json` and moves to the next step. It does not start an engine. It first prints: "Pause swipekey from the menu bar first, so these gestures don't press keys."

- [ ] **Step 1: Write the failing tests:**
  - `testTraceRoundTripsThroughFile`: a trace with 2 sessions, written to a temp file and loaded back, is equal to the original, within the 4-decimal rounding.
  - `testTraceSplitsSessionsAtLift`: 3 frames with touches, 1 empty, 2 with touches, 1 empty → `sessions.count == 2`, `sessions[0].count == 4`.
- [ ] **Step 2:** Run `swift test --filter Trace`. Expected: compile failure.
- [ ] **Step 3:** Implement `Trace` in `Trace.swift`, `Recorder.swift`, and the `--record` flag in `main.swift`. The recorder reuses `sk_multitouch_start` like `MultitouchSource` does, and appends frames under a lock.
- [ ] **Step 4:** Run `swift test`. Expected: all pass. Then run `swift build -c release`, and `.build/release/swipekey --record <scratch dir>`: one step done with a single swipe writes a file that `Trace.load` reads.
- [ ] **Step 5: Checkpoint with Mathias.**
  1. Propose a commit for Tasks 1–2 and wait for his go-ahead.
  2. Run `make install`.
  3. Ask him to pause swipekey and run `~/.local/bin/swipekey --record ~/swipekey-traces`.
  4. Copy the 9 files into `Tests/SwipeKeyCoreTests/Fixtures/`. Each file must be ≤ 2 MB (the scroll one is the biggest).
  5. Ask him to resume swipekey.

### Task 3: Only bound gestures fire and lock

**Files:**
- Modify: `Sources/SwipeKeyCore/Recognizers.swift`
- Modify: `Sources/SwipeKeyCore/Engine.swift` (`build`, `init`, the `onGesture` doc comment)
- Test: `Tests/SwipeKeyCoreTests/SwipeKeyCoreTests.swift` (new `BoundGestureTests`)
- Create: `Tests/SwipeKeyCoreTests/FixtureTests.swift`

**Interfaces:**
- Produces:
  - `public typealias IsBound = (Gesture) -> Bool`.
  - `SwipeRecognizer.init(threshold: Double = 0.12, axisRatio: Double = 1.5, isBound: @escaping IsBound = { _ in true })`, and the same `isBound:` parameter on `PinchRecognizer.init`.
  - A recognizer emits a gesture, and sets `firedThisSession`, only when `isBound(gesture)` is true. Otherwise it keeps measuring.
  - The engine's `build(_ config:, heldModifiers:)` passes `{ g in actions[Trigger(gesture: g, held: heldModifiers())] != nil }`. `actions` is the dictionary just built, captured by value. `heldModifiers` is read only when a gesture would fire, not on every frame.
  - `TouchLab` keeps the default (`{ _ in true }`), so the settings window still sees every gesture.
- `FixtureTests` produces:
  - `let mathiasBindings: [Binding]`: the 7 bindings of his current config. Gestures only; every action is `.key("a")`.
  - `func replay(_ trace: Trace, make: () -> [GestureRecognizer]) -> [[Gesture]]`: what fired per session, with fresh recognizers for each session.
  - `testFixtureReport()`: prints, for each fixture, `name: fired expected in X/Y sessions, other gestures: […]`. Sessions whose highest finger count is below the expected count are skipped (stray taps). This test asserts nothing; it skips when the Fixtures folder is empty.

- [ ] **Step 1: Write the failing tests** in `BoundGestureTests`:
  - `testUnboundTwoFingerSwipeDoesNotBlockThreeFinger`: `isBound` true only for `.swipe(3,.up)`. 2 fingers move up 0.06, the 3rd lands, then 3 fingers move up 0.06 → `[.swipe(fingers: 3, direction: .up)]` fires.
  - `testUnboundGestureNeverFires`: `isBound` always false. A 0.3 swipe up fires nothing.
  - `testModifierOnlyBindingDoesNotLockWithoutModifier`: through an `Engine`. Bindings: `.swipe(3,.up)` holding `cmd`, and `.swipe(3,.right)` without a modifier. `heldModifiers` returns `[]`. A swipe that goes up 0.15, then right 0.3 in the same session → the right binding's action runs. Use the fake-action pattern from `HoldingTests`.
  - `testReloadMidSwipeStartsOver`: engine with 3-up bound and `swipeThreshold` 0.1. Move up 0.04, call `reload` with the same config, then move to 0.1 total → nothing fires (only 0.06 since the reload).
- [ ] **Step 2:** Run `swift test --filter BoundGestureTests`. Expected: FAIL.
- [ ] **Step 3:** Implement as in Interfaces. Update the `onGesture` comment to "Called for every bound gesture that fires".
- [ ] **Step 4:** Run `swift test`. Expected: all pass. Fix any existing engine test that relied on unbound gestures firing by giving it a binding, and say which ones in the report.
- [ ] **Step 5:** Run `swift test --filter testFixtureReport`. Save the printed table as **the baseline** in a comment at the top of `FixtureTests.swift`. Run it on the code before this task's change (`git stash` the Recognizers/Engine diff): the baseline must describe today's behavior, including how many 2-finger gestures `scroll-2` fires.

### Task 4: Finger count settles before a smaller gesture fires

**Files:**
- Create: `Sources/SwipeKeyCore/FingerSettle.swift`
- Modify: `Sources/SwipeKeyCore/Recognizers.swift`
- Test: `Tests/SwipeKeyCoreTests/SwipeKeyCoreTests.swift` (new `SettleTests`; existing recognizer test helpers)

**Interfaces:**
- Produces:
  - `struct FingerSettle { var settle: Double; mutating func observe(count: Int, at time: Double); func held(_ count: Int, at time: Double) -> Bool }`. `held` is true once `count` has been the touching count for at least `settle` seconds.
  - Recognizer inits gain `settle: Double = 0.08`.
- Rule: a gesture with `n` fingers fires only if no gesture with more fingers (n+1…5, any kind, any direction) is bound, or once the `n` count has held for `settle`. While waiting, travel keeps counting. At the first frame where the count has held, it fires if it still qualifies.
- When the count goes **up**, the measure restarts from the new count, as today.

- [ ] **Step 1: Make the existing helpers timestamped.** The `frame`/`three`/`two` helpers in `SwipeRecognizerTests`, `PinchRecognizerTests` and `CaptureTests` take a timestamp that advances 0.1 s per call (a counter on the test case). Run `swift test`. Expected: all pass, no behavior change.
- [ ] **Step 2: Write the failing tests:**
  - `testThirdFingerLandingLateWinsOverBoundTwoFingerSwipe`: `isBound` true for `.swipe(2,.left)` and `.swipe(3,.left)`, threshold 0.05. Timeline: t=0, 2 fingers. t=0.03, they have moved left 0.06. t=0.04, the 3rd lands. Then 3 fingers move left 0.06 by t=0.10 → only `.swipe(3,.left)` fires, never `.swipe(2,.left)`.
  - `testTwoFingerSwipeFiresAfterSettle`: same bindings. 2 fingers move left 0.06 by t=0.03 → nothing yet. Next frame at t=0.09 → `.swipe(2,.left)`.
  - `testNoWaitWhenNoLargerGestureIsBound`: only `.swipe(3,.up)` bound. 3 fingers move up 0.06 by t=0.02 → fires on that frame.
- [ ] **Step 3:** Run `swift test --filter SettleTests`. Expected: FAIL.
- [ ] **Step 4:** Implement `FingerSettle` and use it in both recognizers.
- [ ] **Step 5:** Run `swift test` and `swift test --filter testFixtureReport`. Expected: all pass. Report the table's change from the baseline.

### Task 5: Per-finger travel and early lift (3+ fingers)

**Files:**
- Modify: `Sources/SwipeKeyCore/Recognizers.swift` (`SwipeRecognizer`)
- Test: `Tests/SwipeKeyCoreTests/SwipeKeyCoreTests.swift` (new `EarlyLiftTests`)

**Interfaces:**
- Produces: `travel` becomes the mean, over touching fingers, of each finger's displacement since the current count began. A finger lifting doesn't make the centroid jump.
- **Count goes down, session had settled at ≥ 3 fingers:** keep each remaining finger's start point. The gesture keeps the session's settled count. Travel continues while ≥ 2 fingers remain.
- **Count goes down to 1, or session was 2 fingers:** restart as today.
- Pinch: unchanged in this task. A finger lifting changes the spread, so early lift is skipped for pinch. Note this in the spec's "Calls I made".

- [ ] **Step 1: Write the failing tests:**
  - `testEarlyLiftKeepsThreeFingerTravel`: threshold 0.1. 3 fingers move up 0.06, the left finger lifts, the 2 others continue to 0.12 → `.swipe(3,.up)`.
  - `testTwoFingerSessionStillRestartsOnLift`: 3-finger swipes not bound, `.swipe(2,.up)` bound. 2 fingers move 0.06, one lifts, one continues → nothing.
  - `testLiftDoesNotFakeMovement`: 3 fingers at y 0.3, 0.3 and 0.6, none moving. The y=0.6 finger lifts → `travel` stays (0, 0), within 0.001.
- [ ] **Step 2:** Run `swift test --filter EarlyLiftTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Track a start point per identifier, in a dictionary.
- [ ] **Step 4:** Run `swift test` and the fixture report. Expected: all pass, and the report doesn't lose any swipe compared with Task 4.

### Task 6: Flick rule (3+ fingers)

**Files:**
- Modify: `Sources/SwipeKeyCore/Recognizers.swift` (`SwipeRecognizer`)
- Test: `Tests/SwipeKeyCoreTests/SwipeKeyCoreTests.swift` (new `FlickTests`)

**Interfaces:**
- Produces: `SwipeRecognizer.init` gains `flickFraction: Double = 0.5, flickSpeed: Double = 1.0, flickWindow: Double = 0.05`.
- Rule, for a gesture of 3+ fingers: it fires when the travel along its axis is ≥ `flickFraction × threshold` **and** the speed along that axis is ≥ `flickSpeed`. Speed is measured over the last `flickWindow` seconds, in normalized units per second. The axis-ratio rule still applies.
- When the frames in the window span 0 s, the speed is 0.
- 2-finger gestures ignore this rule.

- [ ] **Step 1: Write the failing tests:**
  - `testFastShortThreeFingerFlickFires`: threshold 0.1, 3 fingers. Up 0.06 over 0.04 s, at 1.5/s → `.swipe(3,.up)`.
  - `testSlowShortThreeFingerMoveDoesNot`: up 0.06 over 0.5 s → nothing.
  - `testTwoFingerFlickDoesNotFire`: `.swipe(2,.left)` bound, 2 fingers, left 0.06 over 0.04 s, threshold 0.1, past the settle time → nothing.
  - `testSameTimestampFramesNeverFlick`: 3 frames at the same timestamp, moving 0.06 → nothing, and no crash.
- [ ] **Step 2:** Run `swift test --filter FlickTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. A small ring of `(time, along-axis travel)` samples is enough.
- [ ] **Step 4:** Run `swift test` and the fixture report. Expected: all pass. `scroll-2` fires no more 2-finger gestures than the baseline.

### Task 7: Fingers must agree

**Files:**
- Modify: `Sources/SwipeKeyCore/Recognizers.swift` (`SwipeRecognizer`)
- Test: `Tests/SwipeKeyCoreTests/SwipeKeyCoreTests.swift` (new `AgreementTests`)

**Interfaces:**
- Produces: `SwipeRecognizer.init` gains `agreeFraction: Double = 0.25`.
- Rule: when the gesture would fire, every touching finger's own displacement along the axis must have the swipe's sign and be ≥ `agreeFraction × distance needed`. The distance needed is the threshold, or the flick distance when the flick rule applies. This applies to 2+ fingers, since it only makes firing stricter.

- [ ] **Step 1: Write the failing tests:**
  - `testFingersMovingApartVerticallyIsNotASwipe`: 3 fingers. Two move up 0.2, one moves down 0.05. The centroid still goes up past 0.1 → nothing.
  - `testOneLaggingFingerStillCountsAboveFraction`: threshold 0.1. Two fingers move up 0.15, one moves up 0.03 (≥ 0.025) → `.swipe(3,.up)`.
- [ ] **Step 2:** Run `swift test --filter AgreementTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test` and the fixture report. Expected: all pass. If a recorded real swipe is now lost, lower `agreeFraction` to the largest value that keeps every recorded swipe. Report the value.

### Task 8: Thumbs and palms, and the strict fixture tests

**Files:**
- Modify: `Sources/SwipeKeyCore/Recognizers.swift` (both recognizers filter `active`)
- Modify: `Tests/SwipeKeyCoreTests/FixtureTests.swift`
- Modify: `docs/superpowers/specs/2026-10-19-smarter-recognition-design.md` (record the decision)

**Interfaces:**
- From `thumb-3-up`, compare the `size`/`majorAxis` of the resting thumb with the fingers.
  - **If one cutoff separates them in every session:** add `Touch.isLikelyThumbOrPalm` with that cutoff. Both recognizers then ignore such touches, as if lifted. Add the unit test `testRestingThumbIsIgnored` with the cutoff's values.
  - **Otherwise:** skip the thumb rule, and write in the spec why (the numbers).
- Strict fixture tests replace the report-only assertions (keep the report):
  - `testBoundSwipesFireTheirGesture`: in every fixture with `expect`, every counted session fires exactly `[expect]`. Exception: if a session fails, the test lists it by index and finger timing. Mathias decides on it at the review, and an accepted miss goes in an explicit `knownMisses` list with a reason.
  - `testScrollFixtureFiresNoMoreThanBaseline`: on `scroll-2` with `mathiasBindings`, the number of fired gestures ≤ the baseline's, and 0 of them have 3+ fingers.

- [ ] **Step 1:** Write the strict tests. Run them and record what fails.
- [ ] **Step 2:** Decide on the thumb rule from the data, as above. Implement it, or document why it's skipped.
- [ ] **Step 3:** Run `swift test`. Expected: all pass, with any `knownMisses` justified.

### Task 9: Near-miss log

**Files:**
- Modify: `Sources/SwipeKeyCore/Recognizers.swift`
- Modify: `Sources/SwipeKeyCore/Engine.swift`
- Modify: `Sources/swipekey/main.swift`
- Test: `Tests/SwipeKeyCoreTests/SwipeKeyCoreTests.swift` (new `NearMissTests`)

**Interfaces:**
- Produces:
  - `public struct NearMiss: Equatable { public enum Reason: String { case tooShort, drifted, fingersDisagree, unbound }; public let gesture: Gesture; public let traveled: Double; public let needed: Double; public let reason: Reason }`.
  - `public var description: String`, e.g. `3-finger swipe up: 0.042 of 0.050 (too short)`.
  - `SwipeRecognizer.takeNearMiss() -> NearMiss?`. It returns a value once, on the frame that ends a session (all fingers lifted). It applies only when nothing fired, the settled count was ≥ 3, and the travel along the dominant axis was ≥ 0.5 × the distance needed.
  - Reason precedence: `unbound` (the gesture isn't bound), then `drifted` (the axis ratio failed), then `fingersDisagree`, then `tooShort`.
  - `GestureRecognizer` gains `func takeNearMiss() -> NearMiss?`, with a default `nil` in a protocol extension.
  - `Engine.onNearMiss: ((NearMiss) -> Void)?`, called on the main queue.
  - `main.swift` logs `near miss: <description>` through `log`.

- [ ] **Step 1: Write the failing tests:**
  - `testShortSwipeReportsTooShort`: threshold 0.1, 3 fingers up 0.07 then lift → `NearMiss(gesture: .swipe(3,.up), traveled: 0.07, needed: 0.1, reason: .tooShort)`, with a 0.001 tolerance on the numbers.
  - `testTinyMovementReportsNothing`: up 0.02 then lift → nil.
  - `testTwoFingerSessionReportsNothing`: 2 fingers up 0.07 then lift → nil.
  - `testUnboundReported`: only 3-up bound. 3 fingers left 0.15 then lift → `.unbound`.
  - `testReportedOnce`: a second `takeNearMiss()` → nil.
- [ ] **Step 2:** Run `swift test --filter NearMissTests`. Expected: FAIL.
- [ ] **Step 3:** Implement and wire it up.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.

### Task 10: Docs, install, live check

**Files:**
- Modify: `README.md` (how recognition works: settle, flick, early lift, near-miss lines in the log, `--record`)
- Modify: `docs/superpowers/specs/2026-10-19-smarter-recognition-design.md` (status: step 1 done, the final values)

- [ ] **Step 1:** Update the README and the spec.
- [ ] **Step 2:** Run `swift test` and `swift build -c release`. Expected: all pass. Then `make install`, and check that `~/Library/Logs/swipekey.log` shows a fresh "swipekey running" line.
- [ ] **Step 3: Live check with Mathias.** He uses swipekey normally for a while. Then read the near-miss lines in the log together. Any real miss he reports gets recorded (`--record`) and added as a fixture.
- [ ] **Step 4:** Propose the commit or commits with a diff summary. Wait for the go-ahead, then `git push origin main` and `git ls-remote origin main`, and wait for CI to be green.
