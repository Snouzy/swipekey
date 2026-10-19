# Smarter gesture recognition: design

Date: 2026-10-19. Status: approved; step 1 implemented on branch `smarter-recognition`.

**Step 1 outcome:** on the 163 real sessions the probe logged (169 swipes: up, down, left, right,
thumb resting), 168 fire as meant (148 before), with no wrong-direction fire. Final values:
settle 0.1 s, flick at 0.5 × threshold and ≥ 1.0 units/s over 0.05 s, agreeFraction 0.25,
direction on physical lengths with ratio 1.2 for 3+ fingers and 2.0 for 2 fingers (after the final review), an early lift holding for 0.1 s at most. Two changes
from this document, both driven by the real data: direction now uses millimetres (item 7 was
deferred), and the thumb rule uses motion (a resting finger), not contact size. Pinch got settle
and bound-only, not the early-lift rule (a lift changes the spread). Every decision is in the
plan's ledger.

**Follow-up, same day:** horizontal 2-finger scrolling fired ⌘←/⌘→ (the old recognizer fires 4
times in 15 s of Mathias's recorded scrolling). 2-finger swipes now fire on lift, only when quick
(≥ 0.8 units/s), short (≤ 0.35 s) and with both fingers landing within 0.15 s. On the recording:
8/8 left, 11/11 right, 0 during scrolling (`Fixtures/two-finger.json`).

## Why

Mathias finds that some swipes, mostly 3-finger up, are not recognized, "sometimes yes, sometimes no".
His words: the machine should learn a bit, because swipes are never done exactly the same way, and
it must recognize them anyway.

What we measured on 2026-10-19 with a probe (25 lazy and quick 3-finger swipes up, current
recognizer, `swipeThreshold` 0.05): **25 of 25 recognized**. Vertical travel 0.13 to 0.38, sideways
drift under 0.09, 3-finger phase 64 to 168 ms, fingers landing over 0 to 70 ms. macOS system
gestures are all off. So the misses happen in situations the probe didn't catch, and we don't know
which yet. The trace is in the session scratchpad (`probe2/up.log`) and is copied into the test
fixtures (see step 1). Note: that file holds only per-swipe summaries, not raw frames, so it
can't be replayed; real traces have to be recorded (step 1, item 9).

Weak spots found in `SwipeRecognizer` (`Sources/SwipeKeyCore/Recognizers.swift`):

- **An unbound gesture locks the session.** Recognizers emit every gesture, bound or not, and
  `firedThisSession` then blocks the rest of the touch session. If 2 fingers land and move ≥ 0.05
  before the 3rd one lands, a "2-finger swipe up" (bound to nothing) fires and the 3-finger swipe
  never does. In the probe, 2 fingers had already moved 0.033 before the 3rd landed.
- **Every finger-count change restarts the measure** (`origin` reset), including a finger lifting
  early or a thumb brushing the pad. The distance traveled so far is lost.
- **Distance only.** A short, fast flick that means "swipe" doesn't count.
- **Centroid only.** It doesn't check that the fingers move together, and counts any contact
  (thumb, palm) as a finger.
- **Normalized units.** The same 0.05 is a shorter movement on a built-in trackpad than on a
  Magic Trackpad.

The industry reference is libinput (the Linux trackpad driver, `src/evdev-mt-touchpad-gestures.c`).
It waits 100 ms for the finger count to settle (`DEFAULT_GESTURE_SWITCH_TIMEOUT`). It decides
between scroll, swipe and pinch only once each finger has moved ~1 mm, or after 150 ms
(`DEFAULT_GESTURE_SWIPE_TIMEOUT`). It keeps one finger count per gesture. It measures in mm, adds
slack per extra finger, checks that the fingers' directions agree, and ignores thumbs and palms.

## Goals

1. Recognize the user's swipes reliably, even when they're done differently each time.
2. Let swipekey learn from the user: from a few examples, then from everyday use.
3. Make every decision explainable: why a gesture fired or not, and what was tuned.

## Non-goals

- No opaque model (neural network, cloud). The rules and numbers stay readable.
- No new gesture types (taps, shapes, drawn letters).
- No change to the bindings, remaps or actions.

## Anti-goals (a failure even if it works)

- **A gesture fires by mistake during normal use**, especially 2-finger scrolling. A false
  trigger is worse than a miss: Mathias has bindings on 2-finger left/right (⌘← / ⌘→), which can
  go back a page in a browser. Every change leans towards caution, and learning can never make
  2-finger recognition more eager than its configured value.
- The learning drifts silently, until swipekey behaves strangely and nobody knows why.
- Recognition gets visibly slower (more than ~100 ms of extra delay on a normal swipe).

## Constraints

- Swift package, macOS 13+, CI on GitHub Actions (older Swift compiler: keep the math simple;
  see e836372).
- All recognition logic stays in `SwipeKeyCore`, testable without the interface or a trackpad.
- MultitouchSupport is private. The raw `MTTouch` struct already has velocity, size, majorAxis and
  minorAxis (`Sources/CMultitouch/multitouch.c`), but only x, y, id and state are passed on today.
  Physical size in mm: `MTDeviceGetSensorSurfaceDimensions` is the usual call (hundredths of mm,
  per jitouch and OpenMultitouchSupport). The builder must verify it on this Mac before relying on
  it; if it's unavailable, fall back to normalized units and the current behavior.
- Config compatibility: existing `config.json` files keep working unchanged. `swipeThreshold` and
  `pinchThreshold` keep their meaning as the defaults.
- Never touch `~/.config/swipekey/config.json` in tests.

## The three steps

Each step ships and gets measured before the next one starts. Steps 2 and 3 are sketched here
and get re-confirmed with Mathias after step 1's data is in.

### Step 1: sturdier recognition (no learning)

1. **The finger count settles.** A finger-count change is accepted once it has held ~100 ms
   (libinput's value; tune with the fixtures). A session can **upgrade** to more fingers: a
   2-finger movement becomes a 3-finger one if the 3rd finger lands while it's still settling, and
   the travel is then measured from the 3-finger start.
2. **Only bound gestures fire and lock.** The recognizers learn which gestures are bound (finger
   count, kind, direction) from the engine. A binding that needs held modifiers counts as bound
   only while those modifiers are held, checked when the gesture would fire (the engine already
   reads the held modifiers at that moment). (My call.) An unbound gesture doesn't fire and doesn't block the
   session. The settings window (`TouchLab`, recording a new binding) still needs every gesture:
   there, the recognizers run the **new rules** with an "every gesture counts as bound" switch, so
   the sensitivity test and step 2's examples predict what fires in real use. (My call.)
3. **An early lift keeps the movement.** When fingers lift one by one at the end, the decision
   uses the highest settled finger count and its travel, not a restart.
**2-finger gestures never get easier to trigger** (anti-goal): items 3 and 4 below apply only
to 3+ finger gestures. For 2 fingers, items 1, 2 and 5 apply, which can only make firing stricter
or fix wrong locks; the distance needed stays exactly as configured. (My call.)

4. **Speed counts.** A swipe also fires on a shorter distance if it's fast: e.g. at least half the
   threshold, at a speed well above a slow scroll. The exact rule is the builder's call, tuned on
   the fixtures, with the anti-goal above as the limit.
5. **The fingers agree.** Each finger's own movement must go in roughly the swipe's direction
   (libinput-style neighbouring directions allowed). This guards against pinches and rotations
   being read as swipes.
6. **Thumbs and palms are ignored**, using the contact size or axes, if the fixtures show a clean
   separation. Otherwise skip this item and say so.
7. **Millimetres: deferred.** Mathias uses a single trackpad (the log shows 1 device), so converting
   to mm brings him nothing now and would shift the up/down vs left/right balance. Kept as a later
   item for people with several trackpads. (My call.)
8. **A near-miss log.** When a 2+-finger session ends without firing but came close (e.g. ≥ 50%
   of the threshold in a bound direction), one line goes to the existing log
   (`~/Library/Logs/swipekey.log`): gesture, travel vs. needed, finger timing, reason
   ("too short", "drifted sideways", "finger count changed", "unbound").
9. **Recorded traces as tests.** A small trace format (frames of x, y, id, state, timestamp, plus
   any new fields) with a recorder (a hidden CLI flag, or a debug option). The recorder is built
   first; Mathias then records a session (see below) that becomes the first fixtures, and the
   tuning (settle time, speed rule, thumb cutoff) is done on those real frames. Every real miss Mathias reports becomes another. The tests replay
   every fixture through the recognizers and check what fires and what doesn't, including
   2-finger scrolls that must **not** fire.

Recording session (Mathias agreed on 2026-10-19, ~5 minutes): 3-finger swipes in each direction, done lazily and
quickly; 2-finger left/right swipes; normal 2-finger scrolling (vertical and sideways, e.g. in a
browser and a long document); pinches; resting the thumb while swiping.

Done when: all existing tests pass; the fixtures pass (every recorded bound swipe fires its
gesture, recorded scrolls fire nothing); the 2-then-3-fingers case has a test; CI is green; the near-miss log works on
Mathias's machine.

### Step 2: tune from examples (sketch)

- A "Teach" button on each binding in the editor: do the gesture 5 times.
- swipekey proposes that gesture's own threshold (e.g. ~60% of the shortest example, within
  bounds) and shows the examples and the proposed value before saving.
- Stored per binding in the config as an optional field. Bindings without it use the global
  `swipeThreshold` / `pinchThreshold`.

### Step 3: learn in everyday use (sketch)

- A near miss followed within a few seconds by a successful retry of the same gesture makes that
  binding's threshold slightly lower. An undo (⌘Z) right after a gesture fired makes it slightly
  higher.
- Small steps, with a floor and a ceiling. Never below what step 2 measured as safe, and never
  more eager than the configured value for 2-finger gestures (anti-goal).
- Every adjustment shows in the menu and the log ("3-finger up tuned: 0.05 → 0.045"), with a
  reset button. Visible learning was proposed with the plan and Mathias accepted the plan.

## Calls I made (to check)

- Step 1 ships alone first, then gets measured before steps 2 and 3. (Mathias agreed to the
  order.)
- No machine-learning model: measured thresholds and rules (best practice for straight swipes;
  the $1-recognizer family is for drawn shapes).
- 100 ms settle time, taken from libinput, to be tuned on the fixtures.
- In step 1, pinch gets the same settle, bound-only and early-lift fixes, but no speed rule.

## Left to the builder

- The exact speed rule, the near-miss cutoff, the thumb/palm cutoff, all tuned on the fixtures.
- The trace file format and where the recorder lives.
- How the bound-gesture list reaches the recognizers (through the engine's `build()`).
