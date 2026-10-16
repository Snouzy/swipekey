import CoreGraphics
import Foundation

/// Something to do when a gesture fires. To add one: add a case to `ActionSpec`
/// and return a new `Action` from `ActionSpec.makeAction()`.
public protocol Action {
    func perform() throws
}

/// The JSON form of an action, e.g. `{"type": "key", "key": "return", "modifiers": ["cmd"]}`.
public enum ActionSpec: Codable, Equatable {
    case key(String, modifiers: [String])
    case shell(String)

    private enum CodingKeys: String, CodingKey { case type, key, modifiers, command }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "key":
            self = .key(
                try c.decode(String.self, forKey: .key),
                modifiers: try c.decodeIfPresent([String].self, forKey: .modifiers) ?? []
            )
        case "shell":
            self = .shell(try c.decode(String.self, forKey: .command))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown action type \"\(type)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .key(key, modifiers):
            try c.encode("key", forKey: .type)
            try c.encode(key, forKey: .key)
            if !modifiers.isEmpty { try c.encode(modifiers, forKey: .modifiers) }
        case let .shell(command):
            try c.encode("shell", forKey: .type)
            try c.encode(command, forKey: .command)
        }
    }

    /// Validates the spec and builds the runnable action.
    public func makeAction() throws -> Action {
        switch self {
        case let .key(key, modifiers):
            return try KeyPressAction(key: key, modifiers: modifiers)
        case let .shell(command):
            return ShellAction(command: command)
        }
    }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Posts a key down / key up pair, as if typed on the keyboard. Needs Accessibility permission.
///
/// Named keys (`return`, `tab`, arrows...) have fixed key codes. A character key (`z`, `[`, `4`)
/// is looked up in the current keyboard layout, so `cmd` + `z` is undo on AZERTY too; if the
/// layout has no such key, the US QWERTY position is used.
public struct KeyPressAction: Action {
    public enum Key: Equatable {
        case code(CGKeyCode)
        case character(Character, fallback: CGKeyCode?)
    }

    public let key: Key
    public let flags: CGEventFlags
    private let layout: KeyboardLayout

    public init(key: String, modifiers: [String] = [], layout: KeyboardLayout = SystemKeyboardLayout()) throws {
        let lowered = key.lowercased()
        if let code = KeyCodes.named[lowered] {
            self.key = .code(code)
        } else if lowered.count == 1, let character = lowered.first {
            self.key = .character(character, fallback: KeyCodes.ansiCharacters[character])
        } else if let code = CGKeyCode(key) {
            self.key = .code(code)
        } else {
            throw ConfigError("Unknown key \"\(key)\". Use a name like \"return\" or \"f5\", a single character like \"a\", or a numeric key code.")
        }
        self.flags = try KeyCodes.flags(for: modifiers)
        self.layout = layout
    }

    /// The key code to post right now, given the current layout.
    public func resolvedKeyCode() throws -> CGKeyCode {
        switch key {
        case let .code(code):
            return code
        case let .character(character, fallback):
            if let code = layout.keyCode(for: character) ?? fallback { return code }
            throw ConfigError("No key types \"\(character)\" in the current keyboard layout")
        }
    }

    public func perform() throws {
        let keyCode = try resolvedKeyCode()
        let source = CGEventSource(stateID: .hidSystemState)
        // Like a real keyboard: modifiers down, key down, key up, modifiers up.
        for step in Keystroke.press(keyCode, flags: flags) + Keystroke.release(keyCode, flags: flags) {
            guard let event = Keystroke.cgEvent(step, source: source) else { throw ConfigError("Could not create keyboard event") }
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Runs a command with /bin/sh, without waiting for it to finish.
public struct ShellAction: Action {
    public let command: String

    public func perform() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
    }
}

public enum KeyCodes {
    public static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "option": .maskAlternate, "opt": .maskAlternate, "alt": .maskAlternate,
        "control": .maskControl, "ctrl": .maskControl,
        "fn": .maskSecondaryFn,
    ]

    public static func flags(for modifiers: [String]) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            guard let flag = Self.modifiers[modifier.lowercased()] else {
                throw ConfigError("Unknown modifier \"\(modifier)\". Use cmd, shift, option, control or fn.")
            }
            flags.insert(flag)
        }
        return flags
    }

    /// Layout-independent keys, from HIToolbox/Events.h.
    public static let named: [String: CGKeyCode] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "enter": 76, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// Character positions on a US QWERTY keyboard: the fallback when the current layout
    /// has no key for a character (e.g. "z" on a Cyrillic layout, where shortcuts use QWERTY).
    public static let ansiCharacters: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]
}
