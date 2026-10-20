import CoreGraphics
import Foundation

/// A key remap being built in the settings window (the Keys tab), before it's valid. Pure, like
/// `BindingDraft`, so the editing workflow is tested without the interface.
public struct RemapDraft: Equatable {
    public var key: String?
    public var modifiers: Set<String> = []
    /// 1: every press. 2: pressed twice.
    public var taps = 1
    /// The sender to match, typed by hand; blank for any. Ignored for a double tap.
    public var app = ""
    public var toKey: String?
    public var toModifiers: Set<String> = []

    public init() {}

    public init(_ remap: KeyRemap) {
        key = remap.from.key
        modifiers = Set(remap.from.modifiers.map(KeyCodes.canonicalModifier))
        taps = remap.from.taps
        app = remap.from.app ?? ""
        toKey = remap.to.key
        toModifiers = Set(remap.to.modifiers.map(KeyCodes.canonicalModifier))
    }

    /// Both keys are there; not checked yet.
    private var candidate: KeyRemap? {
        guard let key, let toKey else { return nil }
        let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
        return KeyRemap(
            from: .init(key: key, modifiers: KeyCodes.orderedModifiers(modifiers), app: taps == 2 || trimmed.isEmpty ? nil : trimmed, taps: taps),
            to: .init(key: toKey, modifiers: KeyCodes.orderedModifiers(toModifiers))
        )
    }

    /// Why swipekey would refuse it, e.g. a key name typed by hand that doesn't exist. Nil when
    /// fine or still incomplete.
    public var error: String? {
        guard let candidate else { return nil }
        do {
            _ = try KeyRemapper([candidate])
            _ = try DoubleTapper([candidate])
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// The finished remap, or nil while a part is missing or invalid.
    public var remap: KeyRemap? { error == nil ? candidate : nil }
}

/// The changes the Keys tab makes to the remaps list. Each returns the new list; the caller saves it.
/// Unlike bindings, a clash is refused rather than replaced: the window checks `clashes` first.
public enum RemapEdits {
    /// Every remap, other than the one at `editing`, on the same key: the same physical key with the
    /// same modifiers, unless both name different apps. A double tap holds back every press of its
    /// key, so it clashes with any other remap of that key.
    public static func clashes(with remap: KeyRemap, editing: Int?, in list: [KeyRemap], layout: KeyboardLayout = SystemKeyboardLayout()) -> [Int] {
        guard let mine = resolve(remap, layout) else { return [] }
        return list.indices.filter { index in
            guard index != editing, let other = resolve(list[index], layout), other.code == mine.code else { return false }
            if remap.from.taps == 2 || list[index].from.taps == 2 { return true }
            guard other.flags == mine.flags else { return false }
            if let a = remap.from.app?.lowercased(), let b = list[index].from.app?.lowercased(), a != b { return false }
            return true
        }
    }

    /// Saves a new remap (`original` nil), or puts it in place of `original`, found by content
    /// since the list may have changed while the editor was open; `hint` is where it was. If
    /// `original` is gone, the edit is saved as a new remap.
    public static func save(_ remap: KeyRemap, replacing original: KeyRemap?, near hint: Int?, in list: [KeyRemap]) -> [KeyRemap] {
        var list = list
        let index = original.flatMap { original in
            hint.flatMap { list.indices.contains($0) && list[$0] == original ? $0 : nil } ?? list.firstIndex(of: original)
        }
        if let index { list[index] = remap } else { list.append(remap) }
        return list
    }

    public static func delete(at index: Int, in list: [KeyRemap]) -> (list: [KeyRemap], removed: KeyRemap)? {
        guard list.indices.contains(index) else { return nil }
        var list = list
        let removed = list.remove(at: index)
        return (list, removed)
    }

    /// Undoes a delete: back at its place. Nil when a remap added since uses the same key.
    public static func restore(_ remap: KeyRemap, at index: Int, in list: [KeyRemap], layout: KeyboardLayout = SystemKeyboardLayout()) -> [KeyRemap]? {
        guard clashes(with: remap, editing: nil, in: list, layout: layout).isEmpty else { return nil }
        var list = list
        list.insert(remap, at: min(max(index, 0), list.count))
        return list
    }

    private static func resolve(_ remap: KeyRemap, _ layout: KeyboardLayout) -> (code: CGKeyCode, flags: CGEventFlags)? {
        guard let action = try? KeyPressAction(key: remap.from.key, modifiers: remap.from.modifiers, layout: layout),
              let code = try? action.resolvedKeyCode() else { return nil }
        return (code, action.flags.intersection(Trigger.holdableModifiers))
    }
}

/// How a remap's card reads in the Keys tab.
extension KeyRemap {
    /// "Space", "⌘ @", or "Press @ twice".
    public var title: String {
        let caps = ActionSpec.key(from.key, modifiers: from.modifiers).keyCaps
        return from.taps == 2 ? "Press \(caps.joined()) twice" : caps.joined(separator: " ")
    }

    public var subtitle: String? {
        if from.taps == 2 {
            let typed = ActionSpec.key(from.key, modifiers: from.modifiers).keyCaps.joined()
            return "a single \(typed) still types \(typed)"
        }
        return from.app.map { "only when \($0) sends it" }
    }

    /// The pressed key as key caps, twice for a double tap.
    public var fromCaps: [String] {
        let caps = ActionSpec.key(from.key, modifiers: from.modifiers).keyCaps
        return from.taps == 2 ? caps + caps : caps
    }

    public var toCaps: [String] { ActionSpec.key(to.key, modifiers: to.modifiers).keyCaps }
}
