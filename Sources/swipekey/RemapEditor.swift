import SwiftUI
import SwipeKeyCore

/// The sheet that adds or edits a key remap: the key, what it becomes, review.
struct RemapEditor: View {
    @ObservedObject var store: ConfigStore
    /// The remap being edited (nil for a new one), and where it was in the list.
    let original: KeyRemap?
    let hint: Int?
    @State private var draft: RemapDraft
    @State private var step: Int
    @State private var reached: Int
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: ConfigStore, original: KeyRemap?, hint: Int?) {
        self.store = store
        self.original = original
        self.hint = hint
        _draft = State(initialValue: original.map(RemapDraft.init) ?? RemapDraft())
        // Editing opens on the review, where every part can be changed.
        _step = State(initialValue: original == nil ? 1 : 3)
        _reached = State(initialValue: original == nil ? 1 : 3)
    }

    /// Where the original is in the list now, if it's still there.
    private var index: Int? {
        guard let original else { return nil }
        let list = store.config.remaps
        if let hint, list.indices.contains(hint), list[hint] == original { return hint }
        return list.firstIndex(of: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(original == nil ? "New remap" : "Edit remap").font(.title3.bold())
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .noFocusRing()
                    .accessibilityLabel("Close without saving")
                }
                StepBar(step: step, reached: reached, labels: ["Key", "Becomes", "Review"]) { step = $0 }
            }
            .padding([.horizontal, .top], 22)

            ScrollView {
                Group {
                    switch step {
                    case 1: keyStep
                    case 2: becomesStep
                    default: reviewStep
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 340)

            Divider()
            HStack {
                Button(step == 1 ? "Cancel" : "Back") {
                    if step == 1 { dismiss() } else { step -= 1 }
                }
                Spacer()
                Button(step == 3 ? "Save" : "Next") {
                    if step == 3 { save() } else { step += 1; reached = max(reached, step) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(Theme.header)
        }
        .frame(width: 560)
        .background(Theme.content)
        .tint(Theme.accent)
        .alert("Swipekey", isPresented: SwiftUI.Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var canAdvance: Bool {
        switch step {
        case 1: return draft.key != nil
        case 2: return draft.toKey != nil && draft.error == nil
        default: return draft.remap != nil && clash == nil
        }
    }

    /// The title of the remap already on this key, if any.
    private var clash: String? {
        guard let remap = draft.remap else { return nil }
        let list = store.config.remaps
        return RemapEdits.clashes(with: remap, editing: index, in: list).first.map { list[$0].title }
    }

    // MARK: Step 1, key

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Press the key to remap, with its modifiers if you want them.").font(.headline)
            ShortcutField(key: $draft.key, modifiers: $draft.modifiers)
            HStack(spacing: 10) {
                Text("When")
                Picker("When", selection: $draft.taps) {
                    Text("Every press").tag(1)
                    Text("Pressed twice").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
            if draft.taps == 2 {
                Text("Pressed twice: a single \(singleKey) still types \(singleKey), a quarter of a second late.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Only when sent by")
                    TextField("Any app (keyboard)", text: $draft.app)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                        .disabled(draft.taps == 2)
                        .accessibilityLabel("Only when sent by")
                }
                Text(draft.taps == 2 ? "Not available with \"Pressed twice\" yet." : "For mouse utilities like Logi Options+.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var singleKey: String {
        guard let key = draft.key else { return "key" }
        return ActionSpec.key(key, modifiers: KeyCodes.orderedModifiers(draft.modifiers)).keyCaps.joined()
    }

    // MARK: Step 2, becomes

    private var becomesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Press what it should become: a key or a shortcut.").font(.headline)
            ShortcutField(key: $draft.toKey, modifiers: $draft.toModifiers, valid: draft.error == nil)
            if let message = draft.error {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Step 3, review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let remap = draft.remap {
                RemapCard(remap: remap)
                ForEach(Array(notes(for: remap).enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: 10) {
                        Text(note.tag).bold()
                        Text(note.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(note.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                }
            } else if let message = draft.error {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func notes(for remap: KeyRemap) -> [(tag: String, text: String, color: Color)] {
        var notes: [(String, String, Color)] = []
        if let clash {
            notes.append(("In use", "\(clash) already uses this key. Change the key, or edit or delete that remap first.", .red))
        }
        if remap.from.taps == 2 {
            let typed = ActionSpec.key(remap.from.key, modifiers: remap.from.modifiers).keyCaps.joined()
            notes.append(("Note", "You won't be able to type \"\(typed)\(typed)\" anymore.", .orange))
        }
        return notes
    }

    private func save() {
        guard let remap = draft.remap, clash == nil else { return }
        do {
            try store.setRemaps(RemapEdits.save(remap, replacing: original, near: hint, in: store.config.remaps))
            dismiss()
        } catch { self.error = "\(error)" }
    }
}
