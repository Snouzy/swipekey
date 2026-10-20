# Keys tab: key remaps in the settings window

Date: 2026-10-20. Status: approved by Mathias (2026-10-20). Builder check done; its two questions are settled
below as my calls.

## Why

Key remaps (`remaps` in `config.json`) only exist in the file. Mathias now has two: the Logi
Options+ fix (Space sent by Logi Options+ → ⌃⌥Space) and the double tap he just asked for (@ @ →
Return, to send a dictated message with the left hand only). He opened the settings window, didn't
find them, and wants to see, create, edit and delete them there, without touching the file.

## Goals

1. See every remap in the settings window.
2. Create, edit and delete a remap there, in the same way as a gesture binding.
3. Changes apply right away, like bindings: no restart, no "Reload config".

## Non-goals

- Per-app rules for double taps (Mathias: "la segmentation en fonction des apps arrivera plus
  tard"). The config refuses `app` on a double tap today, and the window keeps it that way.
- New remap kinds (triple taps, long presses, sequences).
- Changing the double-tap timing (0.25 s, fixed in `DoubleTapper.defaultWindow`).

## Anti-goals

- **A remap stuck on, or a keyboard stuck off.** A broken remap tap must never swallow keys. Any
  reload of the remaps must leave a held-back double-tap press typed, not lost.
- The window writes a remap the running app refuses, or the file and the running app disagree.
- Recording a key in the editor triggers an existing remap (pressing @ to record it fires the
  double tap, or gets held back).

## What Mathias decided

- **Its own tab, "Keys"**, next to "Bindings" (mock-up A in
  `2026-10-20-keys-tab-mockups/keys-tab.html`, chosen over a section under the gestures; the
  editor mock-up is `remap-editor.html` next to it. They're fragments for the brainstorm server:
  open them for layout and wording, the colours are approximate).
  Tab order: Bindings, Keys, Sensitivity, General.
- **One card per remap**, same style as the gesture cards: what you press on the left, an arrow,
  what it becomes as key caps on the right, edit (pencil) and delete (trash) on each card. A
  primary "Add remap" button at the top right, a header with the count ("2 remaps — a key you
  press becomes another one.").
  - A double tap shows the key cap twice (`@` `@`), the title "Press @ twice" with a "double tap"
    badge, and the subtitle "a single @ still types @".
  - A remap with an `app` shows the subtitle "only when Logi Options+ sends it".
  - A plain every-press remap has the key's name as title (e.g. "Space"), no badge, and no
    subtitle unless it has an `app`.
- **Adding is three steps**, with the same step bar as the binding editor (`StepBar`):
  1. **Key**: press the key to remap (with modifiers, recorded exactly like a shortcut). Under it:
     "When: Every press / Pressed twice" (segmented), with the hint "Pressed twice: a single @ still
     types @, a quarter of a second late." Then an optional "Only when sent by" app field
     (placeholder "Any app (keyboard)", hint "For mouse utilities like Logi Options+"), disabled
     while "Pressed twice" is selected.
  2. **Becomes**: press the key or shortcut it should become.
  3. **Review**: the remap as key caps (`@` `@` → `Return`), notes, Save.
     For a double tap, the note "You won't be able to type "@@" anymore."
- **Changes apply right away**, without restarting swipekey (my guess; Mathias confirmed).
- **While a key is being recorded in the editor, existing remaps don't act on it** (my call;
  confirmed).
- **Two remaps on the same key are refused** with a clear message (my call; confirmed).

## Calls I made (to check)

- **Same key** means the same physical key (compare resolved key codes, as the binding clash
  check does, so two names for one key clash) with the same modifiers. Exception: two every-press
  remaps of the same key are fine when both name an `app` and the apps differ (the Logi case, if
  another mouse app ever needs it). A double tap clashes with every remap of its physical key,
  whatever the modifiers, since `DoubleTapper` already refuses two double taps on one key code and
  holds back presses from every sender.
- **The clash rule lives in the window only.** Loading `config.json` stays as it is (a stricter
  loader would stop existing hand-written configs from launching). Before saving, the window also
  runs `KeyRemapper` and `DoubleTapper` on the new list, so anything the app refuses is refused
  there too. Clashing remaps already in the file are listed with an orange "clashes with …" note on
  their card; saving an edit of one of them is refused while the clash remains, and the message
  says which remap to change or delete.
- **Undo after delete**: re-inserts the remap where it was, unless a remap added since clashes with
  it, in which case it says so and doesn't restore it.
- **The General tab** line "Scroll blocking and key remaps live in config.json." becomes "Scroll
  blocking lives in config.json."
- **Editing opens on the Review step**, and the step bar lets you go back, as for bindings.
- **Delete works like bindings**: no confirmation, with the same undo the Bindings tab offers.
- **Empty state**: the header says "No remaps yet", with one line on what a remap is, and the
  "Add remap" button.
- **The app field is free text** (name or bundle id, case-insensitive, as the config already
  matches it). No app picker: the senders that matter (Logi Options+ agent) are background
  processes that a running-apps list wouldn't show by a recognizable name.
- **Hand edits to `config.json` reach the remaps too**: when the window comes back to the front it
  already reloads the file (`refreshFromDisk`); remaps get re-applied there as well, so the file
  and the running app never disagree.

## How it fits the code (for the builder)

What exists:

- `KeyRemap` (`Sources/SwipeKeyCore/KeyRemap.swift`): the config form, with `from.taps` (1 or 2).
  `KeyRemapper` takes the every-press remaps, `DoubleTapper` (`DoubleTap.swift`) the double taps;
  both throw `ConfigError` on an invalid remap. `KeyRemapTap` holds both and runs the HID event tap.
- `main.swift` installs `KeyRemapTap` once at launch, only when `config.remaps` isn't empty.
  `reloadConfig()` restarts the process (`execv`), which is how remaps change today.
- `ConfigStore` (`Sources/swipekey/ConfigStore.swift`) writes one config key at a time
  (`Config.update(.bindings, toEncoded:)`), checks for outside edits first, and checks with the
  engine before writing. `Config.CodingKeys` already has `.remaps`.
- The binding editor (`BindingEditor.swift`): `StepBar`, `ShortcutField` / `RecorderView` (records a
  key name plus modifiers through its own HID tap while focused, and turns macOS shortcuts off),
  `KeyCap`, and the card layout in `BindingsView.swift`. `BindingDraft` / `BindingEdits`
  (`SwipeKeyCore/BindingEditing.swift`) hold the testable editing logic (draft → binding, clash,
  save, delete).

What's needed:

- **Live reload of the remap tap.** `KeyRemapTap` gets a way to swap in a new `KeyRemapper` and
  `DoubleTapper` on the main thread. A press held back by the old `DoubleTapper` is typed first
  (flush), never dropped. The tap is installed on the first remap if there was none at launch, and
  can stay installed (idle) when the last one is deleted. `ConfigStore` gets a `setRemaps(_:)`
  like `setBindings`: outside-edit check, validate with both `KeyRemapper` and `DoubleTapper`,
  write `.remaps`, apply. `refreshFromDisk` applies remaps too.
- **Recording isn't touched by remaps.** `RecorderView`'s tap is created after `KeyRemapTap`'s and
  both insert at the head, so it should see keys first and swallow them; the builder verifies this
  on the machine (record @ with the @@ remap on, and Space with the Logi remap) and, if it doesn't
  hold, pauses the remap tap while a recorder has focus.
- **Testable editing logic in `SwipeKeyCore`**, next to `BindingDraft`: a remap draft (key,
  modifiers, taps, app, target key and modifiers) → `KeyRemap`, the clash rule above, save and
  delete. The card text (title, subtitle, key caps) also comes from there, so it's tested.
- **README**: the Keys tab in the settings section, and the remap recipes say they can be made
  in the window.

## Done when

- The Keys tab lists Mathias's two remaps as in mock-up A (`keys-tab.html`).
- Adding, editing and deleting a remap works and applies at once: after adding @@ → Return in the
  window (with the file's rule deleted first), @@ sends Return without a restart.
- The config file only changes in its `remaps` key.
- Logic tests for the draft, the clash rule and the card text; all tests pass; CI is green.
- Never touch `~/.config/swipekey/config.json` in tests.

## Left to the builder

- View structure and file names; how much of `BindingEditor` / `BindingsView` to share or
  generalize versus copy.
- The exact wording of messages, within the tone of the existing window.
- The tab icon (SF Symbol, e.g. `keyboard`).
- What happens when the remap tap can't be installed on a first live add (no Accessibility
  permission): an error in the window, in the tone of the existing ones.
- Keeping keys from getting stuck when remaps are swapped mid-press (`KeyRemapper.pressed`).
