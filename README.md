# swipekey

Map macOS trackpad gestures to keystrokes and commands. A tiny, open-source
alternative to BetterTouchTool for the "this swipe should press that key" use case.

Out of the box: **three-finger swipe up → Return**.

## Install

Requires macOS 13+ and Swift 5.9+ (Xcode or Command Line Tools).

```sh
make install
```

This builds `~/Applications/Swipekey.app` (a background app, no Dock icon), links
`~/.local/bin/swipekey` to it, writes a default config to `~/.config/swipekey/config.json`,
and registers a LaunchAgent so it starts at login.

Then:

1. **Free the gesture from macOS.** System Settings → Trackpad → More Gestures: set any
   gesture that uses the same fingers and direction to four fingers or off
   (three-finger swipe up is *Mission Control* by default).
2. **Grant Accessibility** to `Swipekey.app` (needed to post key events): `make permissions`
   opens the settings pane and reveals the app in Finder, drag it into the list.
3. `make restart`, then check `make logs` no longer says "Accessibility permission missing".

Outside the project folder, the same commands are
`launchctl kickstart -k gui/$(id -u)/io.github.swipekey` and `tail -f ~/Library/Logs/swipekey.log`.

`make uninstall` removes the app, the LaunchAgent and the shortcut, and keeps your config.

## Configure

```json
{
  "swipeThreshold": 0.12,
  "bindings": [
    { "gesture": { "type": "swipe", "fingers": 3, "direction": "up" },
      "action":  { "type": "key", "key": "return" } },

    { "gesture": { "type": "swipe", "fingers": 4, "direction": "left" },
      "action":  { "type": "key", "key": "[", "modifiers": ["cmd", "shift"] } },

    { "gesture": { "type": "swipe", "fingers": 3, "direction": "down" },
      "action":  { "type": "shell", "command": "open -a Terminal" } }
  ]
}
```

After editing, run `make restart`.

| Field | Values |
| --- | --- |
| `gesture.type` | `swipe` |
| `gesture.fingers` | `2` and up |
| `gesture.direction` | `up`, `down`, `left`, `right` |
| `action.type` | `key` (with `key`, optional `modifiers`) or `shell` (with `command`) |
| `key` | `a`–`z`, `0`–`9`, punctuation, `return`, `enter`, `tab`, `space`, `delete`, `escape`, arrows, `home`, `end`, `pageup`, `pagedown`, `f1`–`f12`, or a numeric virtual key code |
| `modifiers` | `cmd`, `shift`, `option`, `control`, `fn` |
| `swipeThreshold` | distance the fingers must travel, as a fraction of the trackpad (default `0.12`) |

Debug recognition with `swipekey --debug`, which logs every gesture it sees.
Your terminal app needs Accessibility permission to send keys when run that way.

## How it works

```
MultitouchSupport ─frames─▶ GestureRecognizer(s) ─Gesture─▶ Engine ─▶ Action(s)
 (CMultitouch, C)           (one set per device)           (config bindings)
```

- `Sources/CMultitouch`: loads Apple's private `MultitouchSupport.framework` with
  `dlopen` and forwards raw touch frames from every trackpad.
- `Sources/SwipeKeyCore/Gesture.swift`: the `Gesture` enum and its JSON form.
- `Sources/SwipeKeyCore/Recognizers.swift`: `GestureRecognizer` protocol and `SwipeRecognizer`.
- `Sources/SwipeKeyCore/Actions.swift`: `Action` protocol, `KeyPressAction`, `ShellAction`.
- `Sources/SwipeKeyCore/Engine.swift`: wires recognizers to the actions bound in the config.

## Extending

**A new action** (e.g. open a URL, run a Shortcut): add a case to `ActionSpec` with its
JSON decoding, implement `Action`, and return it from `ActionSpec.makeAction()`.

**A new gesture** (e.g. taps, pinches): add a case to `Gesture` with its JSON decoding,
write a `GestureRecognizer` that emits it from `TouchFrame`s, and add it to the list in
`Engine.init`. Recognizers are plain classes fed with frames, so they can be unit tested
without a trackpad (see `Tests/`).

```sh
make test
```

## Caveats

- `MultitouchSupport` is a private Apple framework. It has been stable for over a decade
  and is used by many tools, but a macOS update could break it.
- The app is ad-hoc signed, so macOS ties the Accessibility grant to that exact build.
  After reinstalling a new build, remove Swipekey from the Accessibility list and add it again.
- macOS still sees the gesture too. If a system gesture uses the same fingers and
  direction, both fire. Disable it as described above.

## License

MIT
