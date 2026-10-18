import SwiftUI
import SwipeKeyCore

/// SwiftUI has its own `Binding`: the config's is spelled out here.
typealias KeyBinding = SwipeKeyCore.Binding

/// The Bindings tab: one card per binding, add / edit in a sheet, delete with undo.
struct BindingsView: View {
    @ObservedObject var store: ConfigStore
    /// The binding being edited: nil index for a new one.
    @State private var editing: EditorTarget?
    @State private var undo: (binding: KeyBinding, index: Int)?
    @State private var undoTimer: Timer?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bindings").font(.system(size: 20, weight: .bold))
                    Text("\(countLabel) — what each gesture does. Changes apply as soon as you save.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    open(nil)
                } label: {
                    Label("Add binding", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if store.config.bindings.isEmpty {
                Text("No bindings yet. Add one to turn a gesture into a shortcut.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.tertiary))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(store.config.bindings.enumerated()), id: \.offset) { index, binding in
                            BindingCard(
                                binding: binding,
                                edit: { open(index) },
                                delete: { delete(at: index) }
                            )
                        }
                    }
                }
            }
        }
        // Full height, so the toast sits at the bottom even when the list is short or empty.
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { undoToast }
        .sheet(item: $editing) { target in
            BindingEditor(store: store, original: target.original, hint: target.index)
        }
        .alert("Swipekey", isPresented: SwiftUI.Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var countLabel: String {
        store.config.bindings.count == 1 ? "1 binding" : "\(store.config.bindings.count) bindings"
    }

    @ViewBuilder private var undoToast: some View {
        if let undo {
            HStack(spacing: 14) {
                Text("Deleted \(undo.binding.gesture.description).")
                Button("Undo") { restore() }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8, y: 3)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Opens the editor on a copy of the binding: the list can change under it (file re-read).
    private func open(_ index: Int?) {
        // An undo after other edits could bring back a binding the user replaced since.
        undoTimer?.invalidate()
        undo = nil
        editing = EditorTarget(index: index, original: index.map { store.config.bindings[$0] })
    }

    private func delete(at index: Int) {
        guard let (bindings, removed) = BindingEdits.delete(at: index, in: store.config.bindings) else { return }
        do {
            try store.setBindings(bindings)
            withAnimation { undo = (removed, index) }
            undoTimer?.invalidate()
            undoTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
                withAnimation { undo = nil }
            }
        } catch { self.error = "\(error)" }
    }

    private func restore() {
        guard let undo else { return }
        do { try store.setBindings(BindingEdits.restore(undo.binding, at: undo.index, in: store.config.bindings)) } catch { self.error = "\(error)" }
        undoTimer?.invalidate()
        withAnimation { self.undo = nil }
    }
}

/// Which binding the editor sheet works on.
struct EditorTarget: Identifiable {
    let id = UUID()
    let index: Int?
    let original: KeyBinding?
}

struct BindingCard: View {
    let binding: KeyBinding
    /// Nil on a card that only shows the binding (the editor's review): no buttons then.
    var edit: (() -> Void)?
    var delete: (() -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            MiniTrackpad(gesture: binding.gesture)
            VStack(alignment: .leading, spacing: 2) {
                Text(binding.gesture.description).font(.system(size: 15, weight: .semibold))
                if !binding.holding.isEmpty {
                    Text("while holding \(Modifiers.symbols(binding.holding).joined(separator: " "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
            ActionView(action: binding.action)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let edit, let delete {
                HStack(spacing: 2) {
                    iconButton("pencil", "Edit \(binding.gesture.description)", edit)
                    iconButton("trash", "Delete \(binding.gesture.description)", delete)
                }
            }
        }
        .padding(.vertical, 12).padding(.leading, 14).padding(.trailing, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardBorder))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { edit?() }
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }
}

/// A key action drawn as key caps, a shell action as its command.
struct ActionView: View {
    let action: ActionSpec

    var body: some View {
        switch action {
        case .key:
            HStack(spacing: 5) {
                ForEach(Array(action.keyCaps.enumerated()), id: \.offset) { _, cap in KeyCap(label: cap) }
            }
        case let .shell(command):
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct KeyCap: View {
    let label: String
    var large = false

    var body: some View {
        let radius: CGFloat = large ? 10 : 7
        Text(label)
            .font(.system(size: large ? 18 : 13, weight: .semibold))
            .frame(minWidth: large ? 44 : 28, minHeight: large ? 44 : 28)
            .padding(.horizontal, large ? 12 : 8)
            .background(
                RoundedRectangle(cornerRadius: radius).fill(Theme.keycap)
                    .shadow(color: Theme.keycapBorder, radius: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.keycapBorder))
    }
}

/// A small trackpad with the gesture's fingers sliding or pinching on a loop.
struct MiniTrackpad: View {
    let gesture: SwipeKeyCore.Gesture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.9) / 1.9
            Canvas { canvas, size in
                for dot in dots(at: t, in: size) {
                    let rect = CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12)
                    canvas.fill(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(Theme.accent.opacity(0.18 * dot.alpha)))
                    canvas.fill(Path(ellipseIn: rect), with: .color(Theme.accent.opacity(dot.alpha)))
                }
            }
        }
        .frame(width: 96, height: 64)
        .background(
            LinearGradient(colors: [Theme.padTop, Theme.padBottom], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardBorder))
        .accessibilityHidden(true)
    }

    private func dots(at t: Double, in size: CGSize) -> [(x: Double, y: Double, alpha: Double)] {
        // Fade in, move, fade out.
        let alpha = t < 0.2 ? t / 0.2 : (t > 0.75 ? max(0, (1 - t) / 0.25) : 1)
        let travel = (t - 0.5) * 2 // -1 ... 1
        let cx = size.width / 2, cy = size.height / 2
        switch gesture {
        case let .swipe(fingers, direction):
            let (dx, dy): (Double, Double) = switch direction {
            case .up: (0, -14 * travel)
            case .down: (0, 14 * travel)
            case .left: (-18 * travel, 0)
            case .right: (18 * travel, 0)
            }
            // Tighter with many fingers, so a 5-finger sideways swipe stays on the pad.
            let spacing = min(15, 44 / Double(max(fingers - 1, 1)))
            return (0..<fingers).map { i in
                (cx + (Double(i) - Double(fingers - 1) / 2) * spacing + dx, cy + dy, alpha)
            }
        case let .pinch(fingers, direction):
            // Fingers on a circle around the centre: the radius shrinks (in) or grows (out).
            let radius = 20 - 10 * (direction == .in ? (travel + 1) / 2 : 1 - (travel + 1) / 2)
            return (0..<fingers).map { i in
                let angle = Double.pi * 0.85 + 2 * Double.pi * Double(i) / Double(fingers)
                return (cx + cos(angle) * radius * 1.3, cy + sin(angle) * radius, alpha)
            }
        }
    }
}

enum Modifiers {
    /// Config names in the order keyboards show them, with their symbols.
    static let all: [(name: String, symbol: String, label: String)] = [
        ("control", "⌃", "Control"), ("option", "⌥", "Option"), ("shift", "⇧", "Shift"), ("cmd", "⌘", "Command"),
    ]

    static func symbols(_ names: [String]) -> [String] {
        let flags = (try? KeyCodes.flags(for: names)) ?? []
        let byFlag: [(CGEventFlags, String)] = [(.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
        return byFlag.filter { flags.contains($0.0) }.map(\.1)
    }

    static func ordered(_ names: Set<String>) -> [String] { KeyCodes.orderedModifiers(names) }
}
