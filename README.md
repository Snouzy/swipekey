<img src=".github/assets/icon.svg" width="72" alt="">

# swipekey

Turn Mac trackpad gestures into keystrokes and commands. Three fingers up, and it presses Return.

One small background app, one JSON file, no account, no subscription. The code is free software under the MIT license.

[![License: MIT](https://img.shields.io/badge/license-MIT-141a2e)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-2346d8)](#run-it)
[![CI](https://github.com/Snouzy/swipekey/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Snouzy/swipekey/actions/workflows/ci.yml)

[Run it](#run-it) · [Configure](#configure) · [Extend it](#extend-it) · [License](LICENSE)

## Why

I wanted a three-finger swipe up to press Return. macOS can't map a gesture to a key, and the tool that can, BetterTouchTool, is paid and closed for what is one line of configuration. The open-source options I found were abandoned or did something else. So swipekey does that one thing, and is built so the next gesture or action is a small addition, not a rewrite.

## How it works

```
trackpad ─frames─▶ recognizers ─gesture─▶ engine ─▶ actions
           (MultitouchSupport)            (your config)
```

swipekey reads raw touches from Apple's `MultitouchSupport` framework, the same source the system gestures use. A recognizer turns them into gestures (for now, swipes with any number of fingers), and the engine runs the actions you bound to them: a keystroke with modifiers, or a shell command. It needs Accessibility permission to post keystrokes, and nothing else: no network, no telemetry.

## Run it

```sh
make install
```

Swift 5.9 or later (Xcode or the Command Line Tools) on macOS 13 or later. This builds `~/Applications/Swipekey.app`, writes a default config and registers a LaunchAgent, so swipekey **starts by itself every time you log in** and restarts if it crashes.

Then, once:

1. **Free the gesture.** System Settings → Trackpad → More Gestures: move *Mission Control* (or any gesture on the same fingers and direction) to four fingers, or turn it off.
2. **Allow it.** `make permissions` opens System Settings → Privacy & Security → Accessibility and shows the app in Finder: drag `Swipekey.app` into the list.
3. `make restart`, and swipe.

| Command | What it does |
|---|---|
| `make restart` | Reload after editing the config or granting permission |
| `make logs` | Follow the log (`~/Library/Logs/swipekey.log`) |
| `make test` | Unit tests, no trackpad needed |
| `make uninstall` | Remove the app and the LaunchAgent, keep the config |

`swipekey --debug` prints every gesture it recognizes.

## Configure

`~/.config/swipekey/config.json`, then `make restart`:

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

| Field | Values |
|---|---|
| `gesture` | `swipe` with `fingers` (2 and up) and `direction` (`up`, `down`, `left`, `right`) |
| `action` | `key` with `key` and optional `modifiers` (`cmd`, `shift`, `option`, `control`, `fn`), or `shell` with `command` |
| `key` | `a`–`z`, `0`–`9`, punctuation, `return`, `enter`, `tab`, `space`, `delete`, `escape`, arrows, `home`, `end`, `pageup`, `pagedown`, `f1`–`f12`, or a numeric key code |
| `swipeThreshold` | how far the fingers travel before it fires, as a fraction of the trackpad (default `0.12`) |

## Examples

Each recipe is one or two entries to paste into `bindings`. Some recipes use the same gesture: pick one per gesture, since a gesture bound twice runs both actions. Before using one, check that macOS doesn't already use that gesture (System Settings → Trackpad → More Gestures).

### Press Enter with a three-finger swipe on Mac

Send messages, confirm dialogs or run terminal commands without reaching for the keyboard.

```json
{ "gesture": { "type": "swipe", "fingers": 3, "direction": "up" },
  "action":  { "type": "key", "key": "return" } }
```

### Switch browser tabs with a trackpad swipe

Previous and next tab in Safari, Chrome, Arc, Firefox and most editors (`⌘⇧[` and `⌘⇧]`).

```json
{ "gesture": { "type": "swipe", "fingers": 4, "direction": "left" },
  "action":  { "type": "key", "key": "[", "modifiers": ["cmd", "shift"] } },
{ "gesture": { "type": "swipe", "fingers": 4, "direction": "right" },
  "action":  { "type": "key", "key": "]", "modifiers": ["cmd", "shift"] } }
```

### Close a tab or window with a gesture

```json
{ "gesture": { "type": "swipe", "fingers": 4, "direction": "down" },
  "action":  { "type": "key", "key": "w", "modifiers": ["cmd"] } }
```

### Undo and redo with a swipe

```json
{ "gesture": { "type": "swipe", "fingers": 3, "direction": "left" },
  "action":  { "type": "key", "key": "z", "modifiers": ["cmd"] } },
{ "gesture": { "type": "swipe", "fingers": 3, "direction": "right" },
  "action":  { "type": "key", "key": "z", "modifiers": ["cmd", "shift"] } }
```

### Press Escape with the trackpad (Vim, dialogs, full screen)

```json
{ "gesture": { "type": "swipe", "fingers": 3, "direction": "down" },
  "action":  { "type": "key", "key": "escape" } }
```

### Take a screenshot with a gesture

Opens the macOS selection screenshot (`⌘⇧4`).

```json
{ "gesture": { "type": "swipe", "fingers": 5, "direction": "up" },
  "action":  { "type": "key", "key": "4", "modifiers": ["cmd", "shift"] } }
```

### Play or pause music with a swipe

Apple Music; replace `Music` with `Spotify` for Spotify.

```json
{ "gesture": { "type": "swipe", "fingers": 5, "direction": "down" },
  "action":  { "type": "shell", "command": "osascript -e 'tell application \"Music\" to playpause'" } }
```

### Change the volume with a trackpad gesture

```json
{ "gesture": { "type": "swipe", "fingers": 5, "direction": "right" },
  "action":  { "type": "shell", "command": "osascript -e 'set volume output volume ((output volume of (get volume settings)) + 10)'" } },
{ "gesture": { "type": "swipe", "fingers": 5, "direction": "left" },
  "action":  { "type": "shell", "command": "osascript -e 'set volume output volume ((output volume of (get volume settings)) - 10)'" } }
```

### Open an app or a website with a swipe

```json
{ "gesture": { "type": "swipe", "fingers": 4, "direction": "up" },
  "action":  { "type": "shell", "command": "open -a Terminal" } }
```

`open https://github.com` works the same way for a URL.

### Run an Apple Shortcut from the trackpad

Anything you built in the Shortcuts app: toggle Focus, start a timer, post to a webhook.

```json
{ "gesture": { "type": "swipe", "fingers": 2, "direction": "up" },
  "action":  { "type": "shell", "command": "shortcuts run \"My Shortcut\"" } }
```

Two-finger swipes also scroll the page, so keep them for actions where that doesn't matter.

### Lock the screen with a gesture

Turns the display off; it locks if *Require password* is set to *Immediately* in Lock Screen settings.

```json
{ "gesture": { "type": "swipe", "fingers": 5, "direction": "down" },
  "action":  { "type": "shell", "command": "pmset displaysleepnow" } }
```

## Extend it

- **A new action** (open a URL, run a Shortcut): a case in `ActionSpec` and a type that conforms to `Action`, in [`Actions.swift`](Sources/SwipeKeyCore/Actions.swift).
- **A new gesture** (taps, pinches): a case in [`Gesture`](Sources/SwipeKeyCore/Gesture.swift), a `GestureRecognizer` in [`Recognizers.swift`](Sources/SwipeKeyCore/Recognizers.swift), and one line in `Engine.init`. Recognizers are plain classes fed with touch frames, so they are tested without a trackpad.

## Repository

- `Sources/CMultitouch/`: the C bridge that loads `MultitouchSupport` and forwards touch frames.
- `Sources/SwipeKeyCore/`: gestures, recognizers, actions, config and the engine.
- `Sources/swipekey/`: the command-line entry point.
- `support/`: the app's `Info.plist` and the LaunchAgent template.
- `Tests/`: unit tests for recognition and config.

## Caveats

- `MultitouchSupport` is private Apple API. It has been stable for over a decade and many tools rely on it, but a macOS update could break it.
- The app is ad-hoc signed, so macOS ties the Accessibility grant to that exact build. After installing a new build, remove Swipekey from the Accessibility list and add it again.
- macOS still sees the gesture. If a system gesture uses the same fingers and direction, both fire.

## License

Copyright (C) 2026 Snouzy and the swipekey contributors. [MIT](LICENSE).
