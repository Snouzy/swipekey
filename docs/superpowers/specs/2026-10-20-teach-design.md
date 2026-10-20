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
  global `swipeThreshold` / `pinchThreshold`. When several bindings of one gesture (with different
  held modifiers) have one, the smallest is used for that gesture (the recognizer decides the
  gesture before the modifiers matter).
- The binding card shows a small "taught" tag.

## The numbers (my calls)

- An example's size is measured as the recognizer measures it: the mean of each finger's own
  travel along the gesture's axis, from when the gesture's finger count settled (swipes); the
  change of the fingers' mean distance to their centre (pinches).
- **Proposal: 60% of the smallest example**, rounded to 3 decimals, then bounded:
  - **3+ fingers: never above the current global value**, never below 0.03 (swipe) / 0.015
    (pinch). Teaching must not create misses that the 5 examples didn't show (Mathias's complaint
    was misses). If his examples are all long, the value stays where it is, and the sheet says so.
  - **2 fingers: never below the current global value** (the anti-goal: learning never makes
    2-finger gestures more eager, they compete with scrolling and zoom), never above 0.25 (swipe)
    / 0.15 (pinch).
- Example rejected when: a different finger count; another direction (the largest movement was
  along another direction, or a pinch the other way); under 0.02 (swipe) / 0.01 (pinch). Touches
  with one finger are ignored (clicks).

## Not in this step

- Step 3 (learning from everyday use, visible in the menu, with a reset).
- Per-binding values for the flick, agreement or direction rules: only the distance is taught.

## Done when

- Tests: example measurement and rejection reasons, the proposal bounds (3+ and 2 fingers), config
  round trip of `threshold`, recognizers using a per-gesture threshold, the engine building it, and
  Mathias's 163 real sessions and the 2-finger recording still passing.
- The sheet works on the machine; all tests pass; CI green on the branch.
