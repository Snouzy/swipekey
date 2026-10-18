import AppKit
import SwiftUI
import SwipeKeyCore

/// The "Swipekey Settings…" window. One instance, reused: closing only hides it.
final class SettingsWindow {
    private let store: ConfigStore
    private var window: NSWindow?

    init(store: ConfigStore) { self.store = store }

    func show() {
        do { try store.refreshFromDisk() } catch { MenuBar.show(error) }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Swipekey Settings"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 560, height: 420)
            let controller = NSHostingController(rootView: SettingsView(store: store))
            // Let SwiftUI set only the minimum size, or it shrinks the window to it.
            controller.sizingOptions = .minSize
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 720, height: 580))
            window.center()
            self.window = window
        }
        // A background app has to bring itself forward, or the window opens behind the current app.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        TabView {
            BindingsView(store: store)
                .tabItem { Label("Bindings", systemImage: "hand.draw") }
            GeneralView(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }
}

struct GeneralView: View {
    @ObservedObject var store: ConfigStore
    @State private var error: String?

    var body: some View {
        Form {
            Toggle("Show the icon in the menu bar", isOn: Binding(
                get: { store.config.menuBarIcon },
                set: { shown in attempt { try store.setMenuBarIcon(shown) } }
            ))
            Picker("Open config with", selection: Binding(
                get: { store.config.editor ?? "" },
                set: { name in attempt { try store.setEditor(name.isEmpty ? nil : name) } }
            )) {
                Text("Default app").tag("")
                ForEach(store.editorChoices, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Text("Thresholds, scroll blocking and key remaps live in config.json.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open config.json") { attempt { try store.openInEditor() } }
            }
        }
        .padding(8)
        .alert("Swipekey", isPresented: SwiftUI.Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func attempt(_ change: () throws -> Void) {
        do { try change() } catch { self.error = "\(error)" }
    }
}
