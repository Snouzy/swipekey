import AppKit
import CoreGraphics

/// The JSON form of a remap: rewrite a key event into another one, optionally only when a given
/// app sent it (e.g. a mouse utility that loses modifiers on some keyboard layouts).
///
///     { "from": { "key": "space", "app": "Logi Options+" },
///       "to":   { "key": "space", "modifiers": ["control", "option"] } }
public struct KeyRemap: Codable, Equatable {
    public struct From: Codable, Equatable {
        public var key: String
        /// Modifiers that must be held, exactly (like a binding's `holding`). Empty: none held.
        public var modifiers: [String]
        /// Sender to match: app name or bundle identifier, case-insensitive. Nil: any sender.
        public var app: String?

        public init(key: String, modifiers: [String] = [], app: String? = nil) {
            self.key = key; self.modifiers = modifiers; self.app = app
        }
        private enum CodingKeys: String, CodingKey { case key, modifiers, app }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? []
            app = try c.decodeIfPresent(String.self, forKey: .app)
        }
    }
    public struct To: Codable, Equatable {
        public var key: String
        public var modifiers: [String]

        public init(key: String, modifiers: [String] = []) { self.key = key; self.modifiers = modifiers }
        private enum CodingKeys: String, CodingKey { case key, modifiers }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        }
    }

    public var from: From
    public var to: To

    public init(from: From, to: To) { self.from = from; self.to = to }
}

/// The hot path. Built once from the config; `map` is a dictionary lookup on the key code, and the
/// sender is only identified (lazily) for key codes that have a rule.
public struct KeyRemapper {
    struct Rule {
        let fromFlags: UInt64
        let app: String? // lowercased
        let toCode: CGKeyCode
        let toFlags: CGEventFlags
    }
    private(set) var rules: [CGKeyCode: [Rule]] = [:]
    /// Keys whose press was rewritten: their release gets the same rewrite, whatever is held by then
    /// (the rewrite itself may have pressed modifiers), so nothing is ever left stuck.
    private var pressed: [CGKeyCode: Output] = [:]

    /// A rewrite: the new key and flags, and whether modifiers must be pressed around it
    /// (true when the rule adds modifiers the source didn't hold).
    public struct Output: Equatable {
        public let keyCode: CGKeyCode
        public let flags: CGEventFlags
        public let pressesModifiers: Bool
    }
    static let modifierMask = Trigger.holdableModifiers.union(.maskSecondaryFn)

    public var isEmpty: Bool { rules.isEmpty }

    public init(_ remaps: [KeyRemap], layout: KeyboardLayout = SystemKeyboardLayout()) throws {
        for r in remaps {
            let from = try KeyPressAction(key: r.from.key, modifiers: r.from.modifiers, layout: layout)
            if from.flags.contains(.maskSecondaryFn) { throw ConfigError("\"fn\" can't be used in a remap's \"from\".") }
            let to = try KeyPressAction(key: r.to.key, modifiers: r.to.modifiers, layout: layout)
            let rule = Rule(fromFlags: from.flags.intersection(Trigger.holdableModifiers).rawValue,
                            app: r.from.app?.lowercased(), toCode: try to.resolvedKeyCode(), toFlags: to.flags)
            rules[try from.resolvedKeyCode(), default: []].append(rule)
        }
    }

    /// Same as `map`, but pairs each key-up with the rewrite of its key-down.
    public mutating func handle(keyCode: CGKeyCode, flags: CGEventFlags, isDown: Bool, sender: () -> (String, String)) -> Output? {
        if !isDown, let done = pressed.removeValue(forKey: keyCode) { return done }
        guard let out = map(keyCode: keyCode, flags: flags, sender: sender) else { return nil }
        if isDown { pressed[keyCode] = out }
        return out
    }

    /// The replacement key code and flags, or nil to leave the event alone.
    /// `sender` returns the sending app's lowercased (name, bundle id); it is only called on a key-code match.
    public func map(keyCode: CGKeyCode, flags: CGEventFlags, sender: () -> (String, String)) -> Output? {
        guard let candidates = rules[keyCode] else { return nil }
        let held = flags.intersection(Trigger.holdableModifiers).rawValue
        var who: (String, String)?
        for rule in candidates where rule.fromFlags == held {
            if let app = rule.app {
                if who == nil { who = sender() }
                guard app == who!.0 || app == who!.1 else { continue }
            }
            // keep non-modifier bits (keypad, non-coalesced...), replace the modifiers
            let added = rule.toFlags.intersection(Self.modifierMask).rawValue & ~rule.fromFlags
            return Output(keyCode: rule.toCode, flags: flags.subtracting(Self.modifierMask).union(rule.toFlags), pressesModifiers: added != 0)
        }
        return nil
    }
}

/// Rewrites matching key events in place at the HID level, before any app (or other tap) sees them.
public final class KeyRemapTap {
    private var remapper: KeyRemapper
    private var tap: CFMachPort?
    private var senders: [Int64: (String, String)] = [:]
    /// Called on each rewrite (used by `--debug`).
    public var onRemap: ((_ from: CGKeyCode, _ to: CGKeyCode, _ sender: String) -> Void)?

    public init(_ remapper: KeyRemapper) { self.remapper = remapper }

    public func start() -> Bool {
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                Unmanaged<KeyRemapTap>.fromOpaque(refcon!).takeUnretainedValue().handle(proxy, type, event)
            },
            userInfo: me
        ) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // pids get reused: forget senders as apps quit
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.senders.removeAll()
        }
        return true
    }

    private func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        guard let out = remapper.handle(keyCode: code, flags: event.flags, isDown: type == .keyDown, sender: { sender(of: event) }) else {
            return Unmanaged.passUnretained(event)
        }
        let newCode = out.keyCode, newFlags = out.flags
        onRemap?(code, newCode, senders[event.getIntegerValueField(.eventSourceUnixProcessID)]?.0 ?? "hardware")
        if !out.pressesModifiers {
            // Nothing to press: rewrite in place, the cheapest path.
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(newCode))
            event.flags = newFlags
            return Unmanaged.passUnretained(event)
        }
        // New modifiers: replay what a keyboard sends (modifiers down, key, modifiers up), injected right
        // here so the order is kept, and drop the original event.
        let steps = type == .keyDown ? Keystroke.press(newCode, flags: newFlags) : Keystroke.release(newCode, flags: newFlags)
        // A neutral source: copying the original event's source makes its modifier state override our flags.
        let source = CGEventSource(stateID: .privateState)
        for step in steps { if let e = Keystroke.cgEvent(step, source: source) { e.tapPostEvent(proxy) } }
        return nil
    }

    private func sender(of event: CGEvent) -> (String, String) {
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        if let known = senders[pid] { return known }
        let app = pid == 0 ? nil : NSRunningApplication(processIdentifier: pid_t(pid))
        let who = ((app?.localizedName ?? (pid == 0 ? "hardware" : "")).lowercased(), (app?.bundleIdentifier ?? "").lowercased())
        senders[pid] = who
        return who
    }
}
