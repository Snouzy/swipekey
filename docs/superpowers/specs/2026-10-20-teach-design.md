# Teach a gesture (recognition step 2): design

Date: 2026-10-20. Status: built overnight on branch `teach` with Mathias's go-ahead ("tu peux faire
ça… dans le doute tu le fais et on corrigera demain matin"), not merged. Every call below is mine
unless marked as Mathias's; he reviews them in the morning.

## Why

Step 2 of `2026-10-19-smarter-recognition-design.md`: tune a gesture from a few examples of the
way Mathias does it. His words when he said yes: "un peu comme le Touch ID quand on paramètre un
nouveau Mac".

## What it does

- **Teach button** in the binding editor's Review step, next to the binding's sensitivity line
  ("Sensitivity: default" / "Sensitivity: taught"). Also "Reset to default" once taught.
- **A Touch ID-like sheet** (Mathias's analogy): the live trackpad in the middle, a ring of 5
  segments around the gesture's animation, a prompt ("Swipe up with 3 fingers, the way you usually
  do"). Each good example fills a segment (with a trackpad haptic tap); a wrong one says why
  ("That was 2 fingers", "That went left", "A bit further"). After 5: a check mark, the 5 examples
  as bars, the proposed value against the current one, and "Use it" / "Start over" / "Cancel".
- Nothing fires while teaching (the settings window's existing capture mode).
- "Use it" sets the value on the draft; the binding is written when the editor's Save is pressed,
  like every other part of a binding.
- **Stored per binding** as an optional `"threshold"` in the config. Bindings without it use the
  global `swipeThreshold` / `pinchThreshold`. Each binding keeps its own: a plain swipe up taught
  and ⌘ + swipe up untaught don't affect each other (the recognizer looks the value up with the
  modifiers held, as it already does for "is this gesture bound").
- The binding card shows a small "taught" tag.

## The numbers (my calls)

- **An example counts only when the real recognizer fires on it** (bound to that gesture alone,
  at the minimum size), so a resting thumb, an early lift, straightness, finger agreement and the
  2-finger quickness rule are judged exactly as in everyday use. Its size is the recognizer's own
  measure (mean per-finger travel along the axis; change of the fingers' spread for pinches).
  Checked on Mathias's 163 recorded sessions: every real swipe is accepted.
- **Proposal: 60% of the smallest example**, leaving out an example under half the median (a
  slip), rounded to 3 decimals, then bounded:
  - **3+ fingers: never above the current global value**, never below the settings' lowest
    values, 0.04 (swipe) / 0.02 (pinch). Teaching must not create misses that the 5 examples didn't show (Mathias's complaint
    was misses). If his examples are all long, the value stays where it is, and the sheet says so.
  - **2 fingers: never below the current global value** (the anti-goal: learning never makes
    2-finger gestures more eager, they compete with scrolling and zoom), never above 0.25 (swipe)
    / 0.15 (pinch).
- **The bounds hold whenever the global value moves**, not only when teaching: the engine applies
  them to every taught value (`Teach.effective`). Raising the global for 2-finger swipes raises a
  taught 2-finger value with it; lowering it for 3+ fingers lowers theirs.
- When an example doesn't count, the sheet says why: another number of fingers, another
  direction, too small (under 0.02 swipe / 0.01 pinch), too slow for a 2-finger swipe (it reads as
  a scroll), or not straight. Touches with one finger are ignored (clicks).
- The whole sheet captures the trackpad, result screen included: nothing fires while it's open.

## Not in this step

- Step 3 (learning from everyday use, visible in the menu, with a reset).
- Per-binding values for the flick, agreement or direction rules: only the distance is taught.

## Done when

- Tests: example measurement and rejection reasons, the proposal bounds (3+ and 2 fingers), config
  round trip of `threshold`, recognizers using a per-gesture threshold, the engine building it, and
  Mathias's 163 real sessions and the 2-finger recording still passing.
- The sheet works on the machine; all tests pass; CI green on the branch.
