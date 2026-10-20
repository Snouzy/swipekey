import Foundation

/// A binding being built in the settings window, before it's valid. Pure, so every editing
/// workflow can be tested without the interface.
public struct BindingDraft: Equatable {
    public enum Kind: Hashable { case swipe, pinch }

    public var kind: Kind = .swipe
    public var fingers = 3
    public var direction: Direction?
    public var pinch: PinchDirection?
    public var isShell = false
    public var key: String?
    public var modifiers: Set<String> = []
    public var command = ""
    public var holding: Set<String> = []
    /// Taught with Teach; nil for the global threshold.
    public var threshold: Double?

    public init() {}

    public init(_ binding: Binding) {
        record(binding.gesture)
        switch binding.action {
        case let .key(key, modifiers):
            self.key = key
            self.modifiers = Set(modifiers.map(KeyCodes.canonicalModifier))
        case let .shell(command):
            isShell = true
            self.command = command
        }
        holding = Set(binding.holding.map(KeyCodes.canonicalModifier))
        threshold = binding.threshold
    }

    /// Takes a gesture done on the trackpad (or picked by hand).
    public mutating func record(_ gesture: Gesture) {
        switch gesture {
        case let .swipe(fingers, direction): (kind, self.fingers, self.direction) = (.swipe, fingers, direction)
        case let .pinch(fingers, direction): (kind, self.fingers, pinch) = (.pinch, fingers, direction)
        }
    }

    public var gesture: Gesture? {
        switch kind {
        case .swipe: return direction.map { .swipe(fingers: fingers, direction: $0) }
        case .pinch: return pinch.map { .pinch(fingers: fingers, direction: $0) }
        }
    }

    /// The action, or nil while it's incomplete (no key yet, empty command).
    public var action: ActionSpec? {
        if isShell {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .shell(trimmed)
        }
        return key.map { .key($0, modifiers: KeyCodes.orderedModifiers(modifiers)) }
    }

    /// Why the action can't run, e.g. a key name typed by hand that doesn't exist. Nil when fine
    /// or still incomplete.
    public var actionError: String? {
        guard let action else { return nil }
        do {
            _ = try action.makeAction()
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// The finished binding, or nil while a part is missing or invalid.
    public var binding: Binding? {
        guard let gesture, let action, actionError == nil else { return nil }
        return Binding(gesture: gesture, holding: KeyCodes.orderedModifiers(holding), action: action, threshold: threshold)
    }
}

/// The changes the settings window makes to the bindings list. Each returns the new list; the
/// caller saves it. A gesture bound twice runs both actions, so every change keeps one binding
/// per trigger (gesture plus held modifiers).
public enum BindingEdits {
    /// The binding, other than the one at `editing`, that answers to the same trigger.
    public static func clash(with binding: Binding, editing: Int?, in list: [Binding]) -> Int? {
        clashes(with: binding, editing: editing, in: list).first
    }

    /// Every binding, other than the one at `editing`, on the same trigger (a hand-written list can
    /// hold several).
    public static func clashes(with binding: Binding, editing: Int?, in list: [Binding]) -> [Int] {
        guard let trigger = try? binding.trigger() else { return [] }
        return list.indices.filter { $0 != editing && (try? list[$0].trigger()) == trigger }
    }

    /// Saves a new binding (`editing` nil), or puts it in place of the one at `editing`.
    /// Bindings with the same trigger are replaced rather than doubled.
    public static func save(_ binding: Binding, editing: Int?, in list: [Binding]) -> [Binding] {
        var list = list
        // The list may have changed since the editor opened: an index past the end is a new binding.
        var at = editing.flatMap { list.indices.contains($0) ? $0 : nil }
        let others = clashes(with: binding, editing: at, in: list)
        // A new binding takes the slot of the one it replaces.
        if at == nil { at = others.first }
        for index in others.reversed() where index != at {
            list.remove(at: index)
            if let current = at, index < current { at = current - 1 }
        }
        if let at { list[at] = binding } else { list.append(binding) }
        return list
    }

    /// Saves an edit of `original`, found by its content rather than its position: the list may
    /// have changed while the editor was open (the file re-read). `hint` is where it was. If
    /// `original` is gone, the edit is saved as a new binding.
    public static func save(_ binding: Binding, replacing original: Binding, near hint: Int?, in list: [Binding]) -> [Binding] {
        let index = hint.flatMap { list.indices.contains($0) && list[$0] == original ? $0 : nil }
            ?? list.firstIndex(of: original)
        return save(binding, editing: index, in: list)
    }

    public static func delete(at index: Int, in list: [Binding]) -> (list: [Binding], removed: Binding)? {
        guard list.indices.contains(index) else { return nil }
        var list = list
        let removed = list.remove(at: index)
        return (list, removed)
    }

    /// Undoes a delete: back at its place, or in place of a binding added since on the same trigger.
    public static func restore(_ binding: Binding, at index: Int, in list: [Binding]) -> [Binding] {
        var list = list
        let others = clashes(with: binding, editing: nil, in: list)
        if let first = others.first {
            list[first] = binding
            for index in others.dropFirst().reversed() { list.remove(at: index) }
        } else {
            list.insert(binding, at: min(max(index, 0), list.count))
        }
        return list
    }
}

extension KeyCodes {
    /// "command", "alt", "ctrl"... as written by hand, mapped to one name each.
    public static func canonicalModifier(_ name: String) -> String {
        switch name.lowercased() {
        case "command": return "cmd"
        case "opt", "alt": return "option"
        case "ctrl": return "control"
        default: return name.lowercased()
        }
    }

    /// Modifier names in keyboard order (control, option, shift, cmd, fn). Names outside those
    /// are kept, after them, so nothing written by hand is lost on save.
    public static func orderedModifiers(_ names: Set<String>) -> [String] {
        let order = ["control", "option", "shift", "cmd", "fn"]
        return order.filter(names.contains) + names.subtracting(order).sorted()
    }
}
