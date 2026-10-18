import AppKit
import SwiftUI
import SwipeKeyCore

/// A binding being built in the editor, before it's valid.
struct Draft {
    enum Kind: Hashable { case swipe, pinch }

    var kind: Kind = .swipe
    var fingers = 3
    var direction: Direction?
    var pinch: PinchDirection?
    var isShell = false
    var key: String?
    var modifiers: Set<String> = []
    var command = ""
    var holding: Set<String> = []

    init() {}

    init(_ binding: KeyBinding) {
        switch binding.gesture {
        case let .swipe(fingers, direction):
            (kind, self.fingers, self.direction) = (.swipe, fingers, direction)
        case let .pinch(fingers, direction):
            (kind, self.fingers, pinch) = (.pinch, fingers, direction)
        }
        switch binding.action {
        case let .key(key, modifiers):
            self.key = key
            self.modifiers = Set(modifiers.map(Self.canonical))
        case let .shell(command):
            isShell = true
            self.command = command
        }
        holding = Set(binding.holding.map(Self.canonical))
    }

    var gesture: SwipeKeyCore.Gesture? {
        switch kind {
        case .swipe: return direction.map { .swipe(fingers: fingers, direction: $0) }
        case .pinch: return pinch.map { .pinch(fingers: fingers, direction: $0) }
        }
    }

    var action: ActionSpec? {
        if isShell {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .shell(trimmed)
        }
        return key.map { .key($0, modifiers: Modifiers.ordered(modifiers)) }
    }

    var binding: KeyBinding? {
        guard let gesture, let action else { return nil }
        return KeyBinding(gesture: gesture, holding: Modifiers.ordered(holding), action: action)
    }

    /// "command", "alt", "ctrl"... written by hand map to the names the editor uses.
    private static func canonical(_ name: String) -> String {
        switch name.lowercased() {
        case "command": return "cmd"
        case "opt", "alt": return "option"
        case "ctrl": return "control"
        default: return name.lowercased()
        }
    }
}

struct BindingEditor: View {
    @ObservedObject var store: ConfigStore
    /// Index of the binding being edited, nil for a new one.
    let index: Int?
    @State var draft: Draft
    @State private var step = 1
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: ConfigStore, index: Int?, draft: Draft) {
        self.store = store
        self.index = index
        _draft = State(initialValue: draft)
        // Editing opens on the review, where every part can be changed.
        _step = State(initialValue: index == nil ? 1 : 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(index == nil ? "New binding" : "Edit binding").font(.title3.bold())
                StepBar(step: step, labels: ["Gesture", "Action", "Review"]) { step = $0 }
            }
            .padding([.horizontal, .top], 22)

            Group {
                switch step {
                case 1: gestureStep
                case 2: actionStep
                default: reviewStep
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)

            Divider()
            HStack {
                Button(step == 1 ? "Cancel" : "Back") {
                    if step == 1 { dismiss() } else { step -= 1 }
                }
                Spacer()
                Button(step == 3 ? "Save" : "Next") {
                    if step == 3 { save() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 560)
        .alert("Swipekey", isPresented: SwiftUI.Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var canAdvance: Bool {
        switch step {
        case 1: return draft.gesture != nil
        case 2: return draft.action != nil
        default: return draft.binding != nil
        }
    }

    // MARK: Step 1, gesture

    private var gestureStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Gesture", selection: $draft.kind) {
                    Text("Swipe").tag(Draft.Kind.swipe)
                    Text("Pinch").tag(Draft.Kind.pinch)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                Spacer()
                Picker("Fingers", selection: $draft.fingers) {
                    ForEach(2...5, id: \.self) { Text("\($0) fingers").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }

            HStack(alignment: .center, spacing: 28) {
                if draft.kind == .swipe {
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow { Color.clear.frame(width: 1, height: 1); arrow(.up); Color.clear.frame(width: 1, height: 1) }
                        GridRow { arrow(.left); Color.clear.frame(width: 1, height: 1); arrow(.right) }
                        GridRow { Color.clear.frame(width: 1, height: 1); arrow(.down); Color.clear.frame(width: 1, height: 1) }
                    }
                } else {
                    VStack(spacing: 8) {
                        pinchButton(.in, "Pinch in", "fingers toward the centre")
                        pinchButton(.out, "Pinch out", "fingers apart")
                    }
                }
                if let gesture = draft.gesture {
                    VStack(spacing: 8) {
                        MiniTrackpad(gesture: gesture).scaleEffect(1.4).frame(width: 140, height: 92)
                        Text(gesture.description).font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(draft.kind == .swipe ? "Pick the direction of the swipe." : "Pick a pinch.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func arrow(_ direction: Direction) -> some View {
        let symbol = ["up": "arrow.up", "down": "arrow.down", "left": "arrow.left", "right": "arrow.right"][direction.rawValue]!
        let selected = draft.direction == direction
        return Button { draft.direction = direction } label: {
            Image(systemName: symbol).font(.title2.weight(.semibold)).frame(width: 52, height: 52)
        }
        .buttonStyle(ChoiceStyle(selected: selected))
        .accessibilityLabel("Swipe \(direction.rawValue)")
    }

    private func pinchButton(_ direction: PinchDirection, _ title: String, _ detail: String) -> some View {
        Button { draft.pinch = direction } label: {
            VStack(spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).opacity(0.8)
            }
            .frame(width: 190, height: 56)
        }
        .buttonStyle(ChoiceStyle(selected: draft.pinch == direction))
    }

    // MARK: Step 2, action

    private var actionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Action", selection: $draft.isShell) {
                Text("Shortcut").tag(false)
                Text("Command").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)

            if draft.isShell {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command to run").font(.headline)
                    TextField("open -a Terminal", text: $draft.command)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Text("Runs with /bin/sh. Shortcuts work too: shortcuts run \"My Shortcut\".")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ShortcutField(key: $draft.key, modifiers: $draft.modifiers)
                HStack(spacing: 8) {
                    Text("Or build it:").foregroundStyle(.secondary)
                    modifierChips($draft.modifiers)
                    Text("+").foregroundStyle(.secondary)
                    TextField("key, e.g. @ or return", text: Binding(
                        get: { draft.key ?? "" },
                        set: { draft.key = $0.trimmingCharacters(in: .whitespaces).lowercased().nilIfEmpty }
                    ))
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                    .accessibilityLabel("Key")
                }
                .font(.callout)
            }

            Divider()
            HStack(spacing: 8) {
                Text("Only while holding")
                modifierChips($draft.holding)
                Text("optional: same gesture, another action").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func modifierChips(_ selection: SwiftUI.Binding<Set<String>>) -> some View {
        HStack(spacing: 4) {
            ForEach(Modifiers.all, id: \.name) { modifier in
                let on = selection.wrappedValue.contains(modifier.name)
                Button {
                    if on { selection.wrappedValue.remove(modifier.name) } else { selection.wrappedValue.insert(modifier.name) }
                } label: {
                    Text(modifier.symbol).font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 26)
                }
                .buttonStyle(ChoiceStyle(selected: on))
                .accessibilityLabel(modifier.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    // MARK: Step 3, review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let binding = draft.binding {
                BindingCard(binding: binding, edit: { step = 1 }, delete: { dismiss() })
                    .allowsHitTesting(false)
                ForEach(Array(notes(for: binding).enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: 10) {
                        Text(note.tag).bold()
                        Text(note.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(note.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func notes(for binding: KeyBinding) -> [(tag: String, text: String, color: Color)] {
        var notes: [(String, String, Color)] = []
        if let clash = clashIndex(for: binding) {
            notes.append(("Replaces", "This gesture already does \(store.config.bindings[clash].action). Saving replaces it.", .orange))
        }
        switch binding.gesture {
        case .swipe(4, _):
            notes.append(("macOS", "By default macOS uses four-finger swipes for Mission Control and switching spaces. If they're on, turn them off in Trackpad settings or this binding won't fire.", .red))
        case .pinch(let fingers, _) where fingers >= 4:
            notes.append(("macOS", "By default macOS uses a four- or five-finger pinch for Launchpad and showing the desktop. Turn that off in Trackpad settings first.", .red))
        case .pinch(2, _):
            notes.append(("Note", "Apps that zoom (Safari, Preview) will zoom too. You can turn off \"Zoom in or out\" in Trackpad settings.", .blue))
        case .swipe(2, _):
            notes.append(("Note", "Two-finger swipes also scroll the window under the cursor.", .blue))
        default:
            break
        }
        return notes
    }

    /// Another binding with exactly the same gesture and held modifiers.
    private func clashIndex(for binding: KeyBinding) -> Int? {
        let trigger = try? binding.trigger()
        return store.config.bindings.indices.first { $0 != index && (try? store.config.bindings[$0].trigger()) == trigger }
    }

    private func save() {
        guard let binding = draft.binding else { return }
        var bindings = store.config.bindings
        var at = index
        if let clash = clashIndex(for: binding) {
            if let current = at {
                bindings.remove(at: clash)
                if clash < current { at = current - 1 }
            } else {
                at = clash
            }
        }
        if let at { bindings[at] = binding } else { bindings.append(binding) }
        do {
            try store.setBindings(bindings)
            dismiss()
        } catch { self.error = "\(error)" }
    }
}

/// "1. Gesture  2. Action  3. Review", each step clickable once reached.
struct StepBar: View {
    let step: Int
    let labels: [String]
    let go: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                Button { go(i + 1) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(i + 1 <= step ? Color.accentColor : Color(nsColor: .separatorColor)).frame(height: 4)
                        Text("\(i + 1). \(label)").font(.caption.weight(.semibold))
                            .foregroundStyle(i + 1 == step ? Color.accentColor : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(i + 1 > step)
            }
        }
    }
}

/// A toggle-like button: filled with the accent colour when selected.
struct ChoiceStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor)))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Click, then press a shortcut: records the key and its modifiers on the current keyboard layout.
struct ShortcutField: View {
    @SwiftUI.Binding var key: String?
    @SwiftUI.Binding var modifiers: Set<String>
    @State private var recording = false
    @State private var held: Set<String> = []

    var body: some View {
        ZStack {
            RecorderRepresentable(
                onKey: { key, modifiers in
                    self.key = key
                    self.modifiers = modifiers
                    held = []
                },
                onModifiers: { held = $0 },
                onFocus: { recording = $0; if !$0 { held = [] } }
            )
            HStack(spacing: 8) {
                let caps = shownCaps
                if caps.isEmpty {
                    Text(recording ? "Press your shortcut now…" : "Click here, then press your shortcut")
                        .foregroundStyle(recording ? Color.accentColor : .secondary)
                } else {
                    ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in KeyCap(label: cap, large: true) }
                }
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(recording ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(recording ? Color.accentColor : Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 2, dash: recording ? [] : [6]))
        )
        .accessibilityElement()
        .accessibilityLabel("Shortcut recorder")
        .accessibilityValue(shownCaps.joined(separator: " "))
    }

    /// While modifiers are held mid-recording, show them; otherwise the recorded shortcut.
    private var shownCaps: [String] {
        if recording, !held.isEmpty { return Modifiers.symbols(Modifiers.ordered(held)) }
        guard let key else { return Modifiers.symbols(Modifiers.ordered(modifiers)) }
        return ActionSpec.key(key, modifiers: Modifiers.ordered(modifiers)).keyCaps
    }
}

private struct RecorderRepresentable: NSViewRepresentable {
    let onKey: (String, Set<String>) -> Void
    let onModifiers: (Set<String>) -> Void
    let onFocus: (Bool) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        update(view)
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) { update(view) }

    private func update(_ view: RecorderView) {
        view.onKey = onKey
        view.onModifiers = onModifiers
        view.onFocus = onFocus
    }
}

/// Takes keyboard focus on click and turns every key press into a config key name plus modifiers,
/// including ⌘-shortcuts that would otherwise be key equivalents.
final class RecorderView: NSView {
    var onKey: ((String, Set<String>) -> Void)?
    var onModifiers: ((Set<String>) -> Void)?
    var onFocus: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocus?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocus?(false)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) { record(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        record(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        onModifiers?(Self.names(event.modifierFlags))
    }

    private func record(_ event: NSEvent) {
        // Named keys by code; character keys by the character the layout types without modifiers
        // (Shift aside), so "@" on AZERTY records as "@".
        let key = KeyCodes.name(forKeyCode: event.keyCode)
            ?? event.charactersIgnoringModifiers?.lowercased().nilIfEmpty
        guard let key else { return }
        onKey?(key, Self.names(event.modifierFlags))
    }

    private static func names(_ flags: NSEvent.ModifierFlags) -> Set<String> {
        var names: Set<String> = []
        if flags.contains(.control) { names.insert("control") }
        if flags.contains(.option) { names.insert("option") }
        if flags.contains(.shift) { names.insert("shift") }
        if flags.contains(.command) { names.insert("cmd") }
        return names
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
