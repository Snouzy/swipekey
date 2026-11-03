import AppKit
import SwiftUI
import SwipeKeyCore

/// The Exclusions tab: apps and websites where shortcuts stay quiet.
struct ExclusionsView: View {
    @ObservedObject var store: ConfigStore
    @State private var editing: ExclusionTarget?
    @State private var undo: (exclusion: Exclusion, index: Int)?
    @State private var undoTimer: Timer?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Exclusions").font(.system(size: 20, weight: .bold))
                    Text("Apps and websites where your shortcuts stay quiet.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    open(nil)
                } label: {
                    Label("Add exclusion", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            let exclusions = store.config.exclusions
            if exclusions.isEmpty {
                Text("Nothing excluded. Your shortcuts work everywhere.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.tertiary))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(exclusions.enumerated()), id: \.offset) { index, exclusion in
                            ExclusionCard(exclusion: exclusion, edit: { open(index) }, delete: { delete(at: index) })
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { undoToast }
        .sheet(item: $editing) { target in
            ExclusionEditor(store: store, index: target.index, original: target.original)
        }
        .alert("Swipekey", isPresented: SwiftUI.Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder private var undoToast: some View {
        if let undo {
            HStack(spacing: 14) {
                Text("Deleted \(undo.exclusion.title).")
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
        editing = ExclusionTarget(index: index, original: index.map { store.config.exclusions[$0] })
    }

    private func delete(at index: Int) {
        var list = store.config.exclusions
        let removed = list.remove(at: index)
        do {
            try store.setExclusions(list)
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
        var list = store.config.exclusions
        list.insert(undo.exclusion, at: min(undo.index, list.count))
        do { try store.setExclusions(list) } catch { self.error = "\(error)" }
    }
}

/// Which exclusion the editor sheet works on.
struct ExclusionTarget: Identifiable {
    let id = UUID()
    let index: Int?
    let original: Exclusion?
}

extension Exclusion {
    /// The app's name when it can be found, the website otherwise.
    var title: String { url ?? app.map(AppName.display) ?? "" }

    var scope: String {
        guard let only else { return "All shortcuts" }
        return only.isEmpty ? "No shortcuts" : only.joined(separator: ", ")
    }

    var icon: NSImage? {
        guard let app, let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return nil }
        return NSWorkspace.shared.icon(forFile: location.path)
    }
}

struct ExclusionCard: View {
    let exclusion: Exclusion
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let icon = exclusion.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: exclusion.url != nil ? "globe" : "app").font(.system(size: 20)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(exclusion.title).font(.system(size: 15, weight: .semibold))
                Text(exclusion.scope).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            button("pencil", "Edit \(exclusion.title)", edit)
            button("trash", "Delete \(exclusion.title)", delete)
        }
        .padding(.vertical, 12).padding(.leading, 14).padding(.trailing, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardBorder))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }
}

/// The sheet that adds or edits an exclusion.
struct ExclusionEditor: View {
    private enum Kind { case app, website }

    @ObservedObject var store: ConfigStore
    let index: Int?
    @State private var kind: Kind
    @State private var app: String
    @State private var website: String
    @State private var allShortcuts: Bool
    @State private var only: Set<String>
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: ConfigStore, index: Int?, original: Exclusion?) {
        self.store = store
        self.index = index
        _kind = State(initialValue: original?.url != nil ? .website : .app)
        _app = State(initialValue: original?.app ?? "")
        _website = State(initialValue: original?.url ?? "")
        _allShortcuts = State(initialValue: original?.only == nil)
        _only = State(initialValue: Set(original?.only ?? []))
    }

    /// Every shortcut in the config, plus the ones this exclusion still names.
    private var shortcuts: [String] {
        let known = store.config.remaps.map(\.shortcutName) + store.config.bindings.map(\.shortcutName)
        var seen = Set<String>()
        return (known + only.sorted()).filter { seen.insert($0).inserted }
    }

    private var result: Exclusion? {
        let scope = allShortcuts ? nil : shortcuts.filter(only.contains)
        if scope?.isEmpty == true { return nil }
        let exclusion: Exclusion
        switch kind {
        case .app:
            guard !app.isEmpty else { return nil }
            exclusion = Exclusion(app: app, only: scope)
        case .website:
            exclusion = Exclusion(url: website.trimmingCharacters(in: .whitespacesAndNewlines), only: scope)
        }
        return (try? ExclusionList([exclusion])) == nil ? nil : exclusion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(index == nil ? "New exclusion" : "Edit exclusion").font(.title3.bold())
            Picker("Where", selection: $kind) {
                Text("App").tag(Kind.app)
                Text("Website").tag(Kind.website)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch kind {
            case .app:
                AppChooser(app: $app)
            case .website:
                VStack(alignment: .leading, spacing: 6) {
                    TextField("github.com/*/pull/*", text: $website)
                        .textFieldStyle(.roundedBorder)
                    Text("github.com is the whole site, github.com/a that page and what's under it, * is any text. Works in Chrome, Brave, Edge, Arc, Vivaldi and Safari, not Firefox. macOS asks once per browser to allow it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("Shortcuts", selection: $allShortcuts) {
                    Text("All shortcuts").tag(true)
                    Text("Only these").tag(false)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                if !allShortcuts {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(shortcuts, id: \.self) { name in
                                Toggle(name, isOn: SwiftUI.Binding(
                                    get: { only.contains(name) },
                                    set: { if $0 { only.insert(name) } else { only.remove(name) } }
                                ))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                }
            }

            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(result == nil)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func save() {
        guard let result else { return }
        var list = store.config.exclusions
        if let index, list.indices.contains(index) { list[index] = result } else { list.append(result) }
        do {
            try store.setExclusions(list)
            dismiss()
        } catch { self.error = "\(error)" }
    }
}

/// Picks an app: one that's open, or any other from the Applications folder. Holds its bundle identifier.
struct AppChooser: View {
    @SwiftUI.Binding var app: String

    private var apps: [(name: String, id: String)] {
        var list = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { running in running.bundleIdentifier.map { (name: running.localizedName ?? $0, id: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !app.isEmpty, !list.contains(where: { $0.id == app }) {
            list.insert((name: AppName.display(app), id: app), at: 0)
        }
        return list
    }

    var body: some View {
        HStack {
            Picker("App", selection: $app) {
                Text("Choose an open app").tag("")
                ForEach(apps, id: \.id) { Text($0.name).tag($0.id) }
            }
            Button("Other…", action: choose)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let location = panel.url, let id = Bundle(url: location)?.bundleIdentifier else { return }
        app = id
    }
}
