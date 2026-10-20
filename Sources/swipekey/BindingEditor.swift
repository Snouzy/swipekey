import AppKit
import SwiftUI
import SwipeKeyCore

struct BindingEditor: View {
    @ObservedObject var store: ConfigStore
    /// The binding being edited (nil for a new one), and where it was in the list.
    let original: KeyBinding?
    let hint: Int?
    @State var draft: BindingDraft
    @State private var step: Int
    /// The furthest step reached: the step bar lets you jump back and forth up to it.
    @State private var reached: Int
    @State private var pickByHand = false
    @State private var teaching = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: ConfigStore, original: KeyBinding?, hint: Int?) {
        self.store = store
        self.original = original
        self.hint = hint
        _draft = State(initialValue: original.map(BindingDraft.init) ?? BindingDraft())
        // Editing opens on the review, where every part can be changed.
        _step = State(initialValue: original == nil ? 1 : 3)
        _reached = State(initialValue: original == nil ? 1 : 3)
    }

    /// Where the original is in the list now, if it's still there.
    private var index: Int? {
        guard let original else { return nil }
        let list = store.config.bindings
        if let hint, list.indices.contains(hint), list[hint] == original { return hint }
        return list.firstIndex(of: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(original == nil ? "New binding" : "Edit binding").font(.title3.bold())
                    Spacer()
                    // Leaves without saving from any step; Esc does the same (unless recording a shortcut).
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .noFocusRing()
                    .accessibilityLabel("Close without saving")
                }
                StepBar(step: step, reached: reached, labels: ["Gesture", "Action", "Review"]) { step = $0 }
            }
            .padding([.horizontal, .top], 22)

            // A sheet keeps the size it opened with: a fixed-height, scrollable body, so
            // "Or pick it by hand" opening never pushes its buttons under the footer.
            ScrollView {
                Group {
                    switch step {
                    case 1: gestureStep
                    case 2: actionStep
                    default: reviewStep
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 380)

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
        case 1: return draft.gesture != nil
        case 2: return draft.action != nil && draft.actionError == nil
        default: return draft.binding != nil
        }
    }

    // MARK: Step 1, gesture

    private var gestureStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                LiveTrackpad(lab: store.lab) {
                    VStack(spacing: 4) {
                        Text("Do your gesture on the trackpad").font(.headline)
                        Text("Swipe or pinch, with as many fingers as you like.").font(.caption).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
                .frame(height: 160)
                if let gesture = draft.gesture {
                    VStack(spacing: 8) {
                        Text("Recognized").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        MiniTrackpad(gesture: gesture).scaleEffect(1.3).frame(width: 125, height: 84)
                        Text(gesture.description).font(.headline).multilineTextAlignment(.center)
                    }
                    .frame(width: 160)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.25), value: draft.gesture)
            .capturingTouches(store.lab, swipe: store.config.swipeThreshold, pinch: store.config.pinchThreshold)
            .onAppear { store.lab.onGesture = { draft.record($0) } }
            .onDisappear { store.lab.onGesture = nil }

            DisclosureGroup("Or pick it by hand", isExpanded: $pickByHand) {
                manualGesture.padding(.top, 10)
            }
        }
    }

    private var manualGesture: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Gesture", selection: $draft.kind) {
                    Text("Swipe").tag(BindingDraft.Kind.swipe)
                    Text("Pinch").tag(BindingDraft.Kind.pinch)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                Spacer()
                Picker("Fingers", selection: $draft.fingers) {
                    ForEach(2...5, id: \.self) { Text("\($0) fingers").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }
            if draft.kind == .swipe {
                HStack(spacing: 6) {
                    ForEach([Direction.left, .up, .down, .right], id: \.self) { arrow($0) }
                }
            } else {
                HStack(spacing: 8) {
                    pinchButton(.in, "Pinch in", "fingers toward the centre")
                    pinchButton(.out, "Pinch out", "fingers apart")
                }
            }
        }
    }

    private func arrow(_ direction: Direction) -> some View {
        let symbol = ["up": "arrow.up", "down": "arrow.down", "left": "arrow.left", "right": "arrow.right"][direction.rawValue]!
        let selected = draft.direction == direction
        return Button { draft.direction = direction } label: {
            Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 44, height: 40)
        }
        .buttonStyle(ChoiceStyle(selected: selected))
        .accessibilityLabel("Swipe \(direction.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func pinchButton(_ direction: PinchDirection, _ title: String, _ detail: String) -> some View {
        Button { draft.pinch = direction } label: {
            VStack(spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).opacity(0.8)
            }
            .frame(width: 190, height: 48)
        }
        .buttonStyle(ChoiceStyle(selected: draft.pinch == direction))
        .accessibilityAddTraits(draft.pinch == direction ? .isSelected : [])
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
                        .accessibilityLabel("Command to run")
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Text("Runs with /bin/sh. Shortcuts work too: shortcuts run \"My Shortcut\".")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ShortcutField(key: $draft.key, modifiers: $draft.modifiers, valid: draft.actionError == nil)
                HStack(spacing: 8) {
                    Text("Or build it:").foregroundStyle(.secondary)
                    modifierChips($draft.modifiers, withFn: true)
                    Text("+").foregroundStyle(.secondary)
                    TextField("key, e.g. @ or return", text: Binding(
                        get: { draft.key ?? "" },
                        // "page up" and "Page Up" both mean "pageup".
                        set: { draft.key = $0.filter { !$0.isWhitespace }.lowercased().nilIfEmpty }
                    ))
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                    .accessibilityLabel("Key")
                }
                .font(.callout)
            }
            // Not while a key name is still being typed ("ret" on the way to "return").
            if let message = draft.actionError, !Self.isPartOfKeyName(draft.key) {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack(spacing: 8) {
                Text("Only while holding")
                modifierChips($draft.holding)
                Text("optional: same gesture, another action").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static func isPartOfKeyName(_ key: String?) -> Bool {
        guard let key, key.count > 1 else { return false }
        return KeyCodes.named.keys.contains { $0.hasPrefix(key) && $0 != key }
    }

    /// `fn` only for the shortcut: it can't be held on purpose with a gesture (macOS sets it for arrows).
    private func modifierChips(_ selection: SwiftUI.Binding<Set<String>>, withFn: Bool = false) -> some View {
        HStack(spacing: 4) {
            ForEach(Modifiers.all + (withFn ? [("fn", "fn", "Function")] : []), id: \.name) { modifier in
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
                BindingCard(binding: binding)
                sensitivity(for: binding)
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

    /// How far this gesture must go, and Teach to set it from examples.
    private func sensitivity(for binding: KeyBinding) -> some View {
        let global: Double
        if case .pinch = binding.gesture { global = store.config.pinchThreshold } else { global = store.config.swipeThreshold }
        return HStack(spacing: 10) {
            Image(systemName: "hand.point.up.left").foregroundStyle(Theme.accent)
            if let taught = binding.threshold {
                Text("Taught: fires after \(TeachView.percent(taught)) of the trackpad")
            } else {
                Text("Fires after \(TeachView.percent(global)) of the trackpad (default)")
            }
            Spacer()
            if binding.threshold != nil {
                Button("Reset") { draft.teach(nil) }
            }
            Button(binding.threshold == nil ? "Teach…" : "Teach again…") { teaching = true }
        }
        .font(.callout)
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardBorder))
        .sheet(isPresented: $teaching) {
            TeachView(store: store, gesture: binding.gesture) { draft.teach($0) }
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

    private func clashIndex(for binding: KeyBinding) -> Int? {
        BindingEdits.clash(with: binding, editing: index, in: store.config.bindings)
    }

    private func save() {
        guard let binding = draft.binding else { return }
        do {
            let list = store.config.bindings
            try store.setBindings(original.map { BindingEdits.save(binding, replacing: $0, near: hint, in: list) }
                ?? BindingEdits.save(binding, editing: nil, in: list))
            dismiss()
        } catch { self.error = "\(error)" }
    }
}

/// "1. Gesture  2. Action  3. Review", each step clickable once reached.
struct StepBar: View {
    let step: Int
    let reached: Int
    let labels: [String]
    let go: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                Button { go(i + 1) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(i + 1 <= step ? Theme.accent : Color(nsColor: .separatorColor)).frame(height: 4)
                        Text("\(i + 1). \(label)").font(.caption.weight(.semibold))
                            .foregroundStyle(i + 1 == step ? Theme.accent : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(i + 1 > reached)
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
                RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent : Theme.card)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accent : Theme.keycapBorder))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Click, then press a shortcut: records the key and its modifiers on the current keyboard layout.
struct ShortcutField: View {
    @SwiftUI.Binding var key: String?
    @SwiftUI.Binding var modifiers: Set<String>
    /// False while the key typed by hand isn't a real key: no key cap for it.
    var valid = true
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
                        .foregroundStyle(recording ? Theme.accent : .secondary)
                } else {
                    ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in KeyCap(label: cap, large: true) }
                }
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(recording ? Theme.accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(recording ? Theme.accent : Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 2, dash: recording ? [] : [6]))
        )
        .accessibilityElement()
        .accessibilityLabel("Shortcut recorder")
        .accessibilityValue(shownCaps.joined(separator: " "))
    }

    /// While modifiers are held mid-recording, show them; otherwise the recorded shortcut.
    private var shownCaps: [String] {
        if recording, !held.isEmpty { return Modifiers.symbols(Modifiers.ordered(held)) }
        guard let key, valid else { return Modifiers.symbols(Modifiers.ordered(modifiers)) }
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

/// Takes keyboard focus on click and turns every key press into a config key name plus modifiers.
/// While it has focus it reads the keyboard through an event tap, ahead of macOS: otherwise system
/// shortcuts like ⌘Space (Spotlight) or ⌘Tab never reach it and can't be recorded.
final class RecorderView: NSView {
    var onKey: ((String, Set<String>) -> Void)?
    var onModifiers: ((Set<String>) -> Void)?
    var onFocus: ((Bool) -> Void)?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var windowObservers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool { true }

    deinit { stopTap() }

    override func becomeFirstResponder() -> Bool {
        // The window records the new first responder after this returns.
        DispatchQueue.main.async { [weak self] in self?.startTap() }
        onFocus?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopTap()
        onFocus?(false)
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopTap() }
    }

    // A sheet that closes doesn't always take focus from its views first: stop as soon as the
    // window stops being the key window, and pick up again if it comes back with focus here.
    override func viewDidMoveToWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.stopTap()
            })
        }
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, window.firstResponder === self else { return }
            startTap()
        })
    }

    /// Only while this view is on screen, focused, in the key window.
    private var shouldCapture: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.isVisible && window.firstResponder === self
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // Without the tap (no Accessibility permission) keys still arrive the usual way.
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
        // Named keys by code; character keys by what the key types with no modifier at all, Shift
        // included: ⇧2 is "2" + shift (not "@" + shift, which would press Shift twice in effect),
        // and "@" on AZERTY, a key of its own, records as "@".
        let key = KeyCodes.name(forKeyCode: event.keyCode)
            ?? event.characters(byApplyingModifiers: [])?.lowercased().nilIfEmpty
            ?? event.charactersIgnoringModifiers?.lowercased().nilIfEmpty
        guard let key else { return }
        onKey?(key, Self.names(event.modifierFlags))
    }

    private func startTap() {
        guard tap == nil, shouldCapture else { return }
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<RecorderView>.fromOpaque(refcon!).takeUnretainedValue().handleTap(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        SystemHotKeys.setEnabled(false)
        // Last line of defence: the keyboard must never stay swallowed once the recorder is gone.
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !shouldCapture { stopTap() }
        }
    }

    private func stopTap() {
        watchdog?.invalidate()
        watchdog = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        tapSource = nil
        SystemHotKeys.setEnabled(true)
    }

    /// Swallows every key press while recording (the shortcut is being recorded, not used).
    private func handleTap(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Keystrokes swipekey posts itself go through untouched.
        if event.getIntegerValueField(.eventSourceUserData) == Keystroke.marker { return Unmanaged.passUnretained(event) }
        if type == .keyDown, let nsEvent = NSEvent(cgEvent: event) { record(nsEvent) }
        return nil
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

/// Turns macOS's own shortcuts (⌘Space, ⌘Tab, ⌃Space...) off while a shortcut is being recorded,
/// as shortcut recorders do. Private CoreGraphics calls, looked up at run time: if they're gone,
/// recording still works for every other shortcut. The setting belongs to this process, so macOS
/// restores the shortcuts by itself if swipekey quits or crashes.
enum SystemHotKeys {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetMode = @convention(c) (Int32, Int32) -> Int32

    static func setEnabled(_ enabled: Bool) {
        guard
            let handle = dlopen(nil, RTLD_NOW),
            let connection = dlsym(handle, "CGSMainConnectionID"),
            let setMode = dlsym(handle, "CGSSetGlobalHotKeyOperatingMode")
        else { return }
        let cid = unsafeBitCast(connection, to: MainConnection.self)()
        // 0: shortcuts on, 1: off.
        _ = unsafeBitCast(setMode, to: SetMode.self)(cid, enabled ? 0 : 1)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
