import CoreGraphics
import Foundation

/// Double-tap remaps (`"from": { "key": "@", "taps": 2 }`): two quick presses of a key send another
/// key instead. The first press is held back, since only time tells a single press from a double
/// tap: a single press is typed once `window` has passed, or as soon as another key comes, so nothing
/// ever shows up and then gets erased. Pressed with other modifiers, or held down, the key is untouched.
///
/// Pure state with explicit times, so it's tested without a keyboard; `KeyRemapTap` feeds it the
/// real events and calls `expire` when `deadline` comes.
public struct DoubleTapper {
    public static let defaultWindow: TimeInterval = 0.25

    struct Rule {
        let fromFlags: UInt64
        let toCode: CGKeyCode
        let toFlags: CGEventFlags
    }

    /// The first press of a possible double tap, not typed yet.
    private struct Pending {
        let code: CGKeyCode
        let flags: CGEventFlags
        let at: TimeInterval
        var released = false
    }

    /// What to do with one key event: post `post` first, then let the event go on if `keep`.
    public struct Decision: Equatable {
        public var post: [KeystrokeEvent]
        public var keep: Bool
    }

    public let window: TimeInterval
    private var rules: [CGKeyCode: Rule] = [:]
    private var pending: Pending?
    /// The second press of a double tap: its release is dropped too.
    private var swallowRelease: Set<CGKeyCode> = []

    public var isEmpty: Bool { rules.isEmpty }
    /// When the held-back press must be typed, if there is one.
    public var deadline: TimeInterval? { pending.map { $0.at + window } }

    public init(_ remaps: [KeyRemap], window: TimeInterval = defaultWindow, layout: KeyboardLayout = SystemKeyboardLayout()) throws {
        self.window = window
        for r in remaps {
            try r.checkTaps()
            guard r.from.taps == 2 else { continue }
            if r.from.app != nil { throw ConfigError("A double-tap remap can't have an \"app\" yet.") }
            let from = try KeyPressAction(key: r.from.key, modifiers: r.from.modifiers, layout: layout)
            let to = try KeyPressAction(key: r.to.key, modifiers: r.to.modifiers, layout: layout)
            let code = try from.resolvedKeyCode()
            if rules[code] != nil { throw ConfigError("Two double-tap remaps for \"\(r.from.key)\".") }
            rules[code] = Rule(fromFlags: from.flags.intersection(Trigger.holdableModifiers).rawValue,
                               toCode: try to.resolvedKeyCode(), toFlags: to.flags)
        }
    }

    public mutating func handle(keyCode: CGKeyCode, flags: CGEventFlags, isDown: Bool, isRepeat: Bool, at time: TimeInterval) -> Decision {
        if var first = pending {
            if keyCode == first.code && isDown && !isRepeat && matches(keyCode, flags) && time - first.at <= window {
                pending = nil
                swallowRelease.insert(keyCode)
                let rule = rules[keyCode]!
                return Decision(post: Keystroke.press(rule.toCode, flags: rule.toFlags) + Keystroke.release(rule.toCode, flags: rule.toFlags), keep: false)
            }
            if keyCode == first.code && !isDown && !first.released {
                first.released = true
                pending = first
                return Decision(post: [], keep: false)
            }
            // Anything else (another key, a repeat, a press too late): type the first press, then
            // look at this event afresh.
            let typed = flush()
            var next = handle(keyCode: keyCode, flags: flags, isDown: isDown, isRepeat: isRepeat, at: time)
            next.post = typed + next.post
            return next
        }
        if !isDown, swallowRelease.remove(keyCode) != nil { return Decision(post: [], keep: false) }
        if isDown && !isRepeat && matches(keyCode, flags) {
            pending = Pending(code: keyCode, flags: flags, at: time)
            return Decision(post: [], keep: false)
        }
        return Decision(post: [], keep: true)
    }

    /// The held-back press, typed when its window has passed (nothing before that).
    public mutating func expire(at time: TimeInterval) -> [KeystrokeEvent] {
        guard let deadline, time >= deadline else { return [] }
        return flush()
    }

    private func matches(_ keyCode: CGKeyCode, _ flags: CGEventFlags) -> Bool {
        rules[keyCode]?.fromFlags == flags.intersection(Trigger.holdableModifiers).rawValue
    }

    /// Types the held-back press; when the key is still down, its real release goes through later.
    private mutating func flush() -> [KeystrokeEvent] {
        guard let first = pending else { return [] }
        pending = nil
        let press = KeystrokeEvent(kind: .keyDown, keyCode: first.code, flags: first.flags)
        return first.released ? [press, KeystrokeEvent(kind: .keyUp, keyCode: first.code, flags: first.flags)] : [press]
    }
}
