import CoreGraphics

/// One keyboard event of a keystroke, as a real keyboard would send it.
public struct KeystrokeEvent: Equatable {
    public enum Kind: Equatable { case modifierDown, modifierUp, keyDown, keyUp }
    public let kind: Kind
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags
}

/// Builds the event sequence of a shortcut the way hardware does: each modifier goes down on its own
/// (flagsChanged), then the key, then the modifiers come back up in reverse order. Some apps (Wispr Flow,
/// many hotkey recorders) track modifier presses and ignore a key that merely carries modifier flags.
public enum Keystroke {
    /// Tag on every event swipekey posts ("SWKY"), so its own taps let them through untouched.
    public static let marker: Int64 = 0x5357_4B59
    /// Left-hand modifier keys, in the order people press them.
    static let modifiers: [(CGEventFlags, CGKeyCode)] = [
        (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55), (.maskSecondaryFn, 63),
    ]

    /// Modifiers down, then the key down.
    public static func press(_ keyCode: CGKeyCode, flags: CGEventFlags) -> [KeystrokeEvent] {
        var held: CGEventFlags = []
        var events: [KeystrokeEvent] = []
        for (flag, code) in modifiers where flags.contains(flag) {
            held.insert(flag)
            events.append(KeystrokeEvent(kind: .modifierDown, keyCode: code, flags: held))
        }
        events.append(KeystrokeEvent(kind: .keyDown, keyCode: keyCode, flags: flags))
        return events
    }

    /// The key up, then the modifiers up in reverse order.
    public static func release(_ keyCode: CGKeyCode, flags: CGEventFlags) -> [KeystrokeEvent] {
        var held = flags
        var events = [KeystrokeEvent(kind: .keyUp, keyCode: keyCode, flags: flags)]
        for (flag, code) in modifiers.reversed() where flags.contains(flag) {
            held.remove(flag)
            events.append(KeystrokeEvent(kind: .modifierUp, keyCode: code, flags: held))
        }
        return events
    }

    /// A CGEvent for one step, ready to post.
    public static func cgEvent(_ e: KeystrokeEvent, source: CGEventSource?) -> CGEvent? {
        let isDown = e.kind == .keyDown || e.kind == .modifierDown
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: e.keyCode, keyDown: isDown) else { return nil }
        if e.kind == .modifierDown || e.kind == .modifierUp { event.type = .flagsChanged }
        event.flags = e.flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    /// Posts the steps in order at the HID level. A plain post keeps the flags we set; injecting from
    /// inside a tap (tapPostEvent) does not always, which leaves apps believing modifiers are still held.
    public static func post(_ steps: [KeystrokeEvent]) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        for step in steps {
            guard let event = cgEvent(step, source: source) else { throw ConfigError("Could not create keyboard event") }
            event.post(tap: .cghidEventTap)
        }
    }
}
