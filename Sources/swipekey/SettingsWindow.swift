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
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Swipekey Settings"
            // The tab header's colour runs up under the title, as in System Settings.
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 560, height: 420)
            let controller = NSHostingController(rootView: SettingsView(store: store))
            // Let SwiftUI set only the minimum size, or it shrinks the window to it.
            controller.sizingOptions = .minSize
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 720, height: 580))
            window.center()
            // Back from editing config.json by hand: show what's in the file now.
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                try? self?.store.refreshFromDisk()
            }
            self.window = window
        }
        // A background app has to bring itself forward, or the window opens behind the current app.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Colours of the mock-up, with a dark-mode twin for each.
enum Theme {
    static let accent = adaptive(light: 0x2346D8, dark: 0x6F8CFF)
    static let header = adaptive(light: 0xECECF0, dark: 0x2A2A2D)
    static let content = adaptive(light: 0xF5F5F7, dark: 0x1F1F21)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x2C2C2F)
    static let cardBorder = adaptive(light: 0xE2E2E7, dark: 0x3A3A3E)
    static let padTop = adaptive(light: 0xECECF1, dark: 0x3A3A3E)
    static let padBottom = adaptive(light: 0xE0E0E6, dark: 0x313134)
    static let keycap = adaptive(light: 0xFFFFFF, dark: 0x3A3A3E)
    static let keycapBorder = adaptive(light: 0xC9C9D0, dark: 0x55555B)

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum SettingsTab: CaseIterable {
    case bindings, sensitivity, general

    var title: String {
        switch self {
        case .bindings: return "Bindings"
        case .sensitivity: return "Sensitivity"
        case .general: return "General"
        }
    }

    var icon: String {
        switch self {
        case .bindings: return "hand.draw"
        case .sensitivity: return "slider.horizontal.3"
        case .general: return "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @State private var tab = SettingsTab.bindings

    var body: some View {
        VStack(spacing: 0) {
            // Icon tabs under the title, like System Settings panes.
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon).font(.system(size: 18)).frame(height: 22)
                            Text(item.title).font(.system(size: 12, weight: .medium))
                        }
                        .frame(minWidth: 64)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(tab == item ? Theme.accent : .secondary)
                        .background(tab == item ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .noFocusRing()
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(Theme.header.ignoresSafeArea(edges: .top))
            Divider()
            Group {
                switch tab {
                case .bindings: BindingsView(store: store)
                case .sensitivity: SensitivityView(store: store)
                case .general: GeneralView(store: store)
                }
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.content)
        }
        .tint(Theme.accent)
        .frame(minWidth: 560, minHeight: 420)
    }
}

extension View {
    /// The selected tab is already tinted: the focus ring macOS adds on open is noise.
    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14, *) { focusEffectDisabled() } else { self }
    }
}

struct GeneralView: View {
    @ObservedObject var store: ConfigStore
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("General").font(.system(size: 20, weight: .bold))
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
                    Text("Scroll blocking and key remaps live in config.json.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open config.json") { attempt { try store.openInEditor() } }
                }
            }
        }
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
