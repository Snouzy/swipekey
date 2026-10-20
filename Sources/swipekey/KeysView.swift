import SwiftUI
import SwipeKeyCore

/// The Keys tab: one card per key remap, add / edit in a sheet, delete with undo.
struct KeysView: View {
    @ObservedObject var store: ConfigStore
    @State private var editing: RemapTarget?
    @State private var undo: (remap: KeyRemap, index: Int)?
    @State private var undoTimer: Timer?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keys").font(.system(size: 20, weight: .bold))
                    Text("\(countLabel) — a key you press becomes another one. Changes apply as soon as you save.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    open(nil)
                } label: {
                    Label("Add remap", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            let remaps = store.config.remaps
            if remaps.isEmpty {
                Text("No remaps yet. Add one to turn a key, or a key pressed twice, into another.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.tertiary))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(remaps.enumerated()), id: \.offset) { index, remap in
                            RemapCard(
                                remap: remap,
                                clash: RemapEdits.clashes(with: remap, editing: index, in: remaps).first.map { remaps[$0].title },
                                edit: { open(index) },
                                delete: { delete(at: index) }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { undoToast }
        .sheet(item: $editing) { target in
            RemapEditor(store: store, original: target.original, hint: target.index)
        }
        .alert("Swipekey", isPresented: SwiftUI.Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var countLabel: String {
        store.config.remaps.count == 1 ? "1 remap" : "\(store.config.remaps.count) remaps"
    }

    @ViewBuilder private var undoToast: some View {
        if let undo {
            HStack(spacing: 14) {
                Text("Deleted \(undo.remap.title).")
                Button("Undo") { restore() }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8, y: 3)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func open(_ index: Int?) {
        undoTimer?.invalidate()
        undo = nil
        editing = RemapTarget(index: index, original: index.map { store.config.remaps[$0] })
    }

    private func delete(at index: Int) {
        guard let (remaps, removed) = RemapEdits.delete(at: index, in: store.config.remaps) else { return }
        do {
            try store.setRemaps(remaps)
            withAnimation { undo = (removed, index) }
            undoTimer?.invalidate()
            undoTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
                withAnimation { undo = nil }
            }
        } catch { self.error = "\(error)" }
    }

    private func restore() {
        guard let undo else { return }
        undoTimer?.invalidate()
        withAnimation { self.undo = nil }
        guard let remaps = RemapEdits.restore(undo.remap, at: undo.index, in: store.config.remaps) else {
            error = "\(undo.remap.title) can't come back: another remap now uses that key."
            return
        }
        do { try store.setRemaps(remaps) } catch { self.error = "\(error)" }
    }
}

/// Which remap the editor sheet works on.
struct RemapTarget: Identifiable {
    let id = UUID()
    let index: Int?
    let original: KeyRemap?
}

struct RemapCard: View {
    let remap: KeyRemap
    /// The title of another remap on the same key (a list written by hand can hold one).
    var clash: String?
    /// Nil on a card that only shows the remap (the editor's review): no buttons then.
    var edit: (() -> Void)?
    var delete: (() -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            caps(remap.fromCaps).frame(minWidth: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(remap.title).font(.system(size: 15, weight: .semibold))
                    if remap.from.taps == 2 {
                        Text("double tap")
                            .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                if let subtitle = remap.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if let clash {
                    Text("clashes with \(clash): change or delete one of them").font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
            caps(remap.toCaps).frame(maxWidth: .infinity, alignment: .leading)
            if let edit, let delete {
                HStack(spacing: 2) {
                    iconButton("pencil", "Edit \(remap.title)", edit)
                    iconButton("trash", "Delete \(remap.title)", delete)
                }
            }
        }
        .padding(.vertical, 12).padding(.leading, 14).padding(.trailing, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardBorder))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { edit?() }
    }

    private func caps(_ labels: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, cap in KeyCap(label: cap) }
        }
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
