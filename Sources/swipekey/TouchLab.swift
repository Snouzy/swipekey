import AppKit
import Combine
import SwiftUI
import SwipeKeyCore

/// The trackpad as the settings window sees it: where the fingers are, how close the movement
/// is to firing, and the gesture it fires, with the thresholds being tuned. While a view uses
/// it, the engine hands it every frame and runs no action, so testing presses nothing.
final class TouchLab: ObservableObject {
    struct Finger: Identifiable {
        let id: Int
        /// Normalized, origin top-left (ready to draw).
        let x: Double, y: Double
    }

    enum Outcome: Equatable {
        case fired(SwipeKeyCore.Gesture)
        case tooShort(traveled: Double, needed: Double)
    }

    @Published private(set) var fingers: [Finger] = []
    /// 0...1: how far the current movement is toward the threshold.
    @Published private(set) var progress: Double = 0
    @Published private(set) var heading: String?
    @Published private(set) var outcome: Outcome?

    /// Called with each gesture recognized while capturing (on the main queue).
    var onGesture: ((SwipeKeyCore.Gesture) -> Void)?

    private let engine: Engine
    private var users = 0
    private var swipe = SwipeRecognizer()
    private var pinch = PinchRecognizer()
    private var fired = false
    private var longestSwipe = 0.0

    init(engine: Engine) { self.engine = engine }

    var swipeThreshold: Double { swipe.threshold }
    var pinchThreshold: Double { pinch.threshold }

    /// Fresh recognizers with these thresholds, e.g. while a slider moves.
    func setThresholds(swipe: Double, pinch: Double) {
        self.swipe = SwipeRecognizer(threshold: swipe)
        self.pinch = PinchRecognizer(threshold: pinch)
    }

    /// Starts capturing for one more view; the engine goes back to normal when the last one stops.
    func start(swipe: Double, pinch: Double) {
        setThresholds(swipe: swipe, pinch: pinch)
        users += 1
        guard users == 1 else { return }
        clear()
        engine.capture = { [weak self] frame in
            DispatchQueue.main.async { self?.process(frame) }
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        engine.capture = nil
        clear()
    }

    private func clear() {
        fingers = []
        progress = 0
        heading = nil
        outcome = nil
    }

    private func process(_ frame: TouchFrame) {
        guard users > 0 else { return }
        let gestures = swipe.process(frame) + pinch.process(frame)
        let active = frame.touches.filter(\.isTouching)
        fingers = active.map { Finger(id: $0.identifier, x: $0.x, y: 1 - $0.y) }

        guard !active.isEmpty else {
            // Lifted: a real attempt that didn't get there says by how much.
            if !fired, longestSwipe > swipe.threshold * 0.25 {
                outcome = .tooShort(traveled: longestSwipe, needed: swipe.threshold)
            }
            fired = false
            longestSwipe = 0
            progress = 0
            heading = nil
            return
        }
        if fired { return }

        if active.count >= 2 {
            let (dx, dy) = swipe.travel
            let distance = max(abs(dx), abs(dy))
            longestSwipe = max(longestSwipe, distance)
            let swipeProgress = distance / swipe.threshold
            let pinchProgress = abs(pinch.spreadChange) / pinch.threshold
            progress = min(1, max(swipeProgress, pinchProgress))
            if pinchProgress > swipeProgress {
                heading = pinch.spreadChange < 0 ? "Pinching in…" : "Pinching out…"
            } else if distance > 0.01 {
                heading = "Swiping " + (abs(dy) >= abs(dx) ? (dy > 0 ? "up" : "down") : (dx > 0 ? "right" : "left")) + "…"
            }
            if outcome != nil, progress > 0.1 { outcome = nil }
        }

        if let gesture = gestures.first {
            fired = true
            progress = 1
            heading = nil
            outcome = .fired(gesture)
            onGesture?(gesture)
        }
    }
}

/// A trackpad drawn at the size of the view, with the real fingers on it.
struct LiveTrackpad<Idle: View>: View {
    @ObservedObject var lab: TouchLab
    @ViewBuilder var idle: () -> Idle

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [Theme.padTop, Theme.padBottom], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.cardBorder)
                if lab.fingers.isEmpty {
                    idle().padding()
                }
                ForEach(lab.fingers) { finger in
                    Circle()
                        .fill(Theme.accent.opacity(0.85))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.accent.opacity(0.18)).padding(-8))
                        .position(x: finger.x * geometry.size.width, y: finger.y * geometry.size.height)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Live trackpad")
        .accessibilityValue(lab.fingers.isEmpty ? "No fingers" : "\(lab.fingers.count) fingers")
    }
}

extension View {
    /// Captures the trackpad while this view is on screen in the key window: a window in the
    /// background must not swallow gestures meant for other apps.
    func capturingTouches(_ lab: TouchLab, swipe: Double, pinch: Double) -> some View {
        modifier(CaptureTouches(lab: lab, swipe: swipe, pinch: pinch))
    }
}

private struct CaptureTouches: ViewModifier {
    let lab: TouchLab
    let swipe: Double
    let pinch: Double
    @State private var visible = false
    @State private var windowIsKey = false
    @State private var capturing = false

    // The window's real key state, not \.controlActiveState: inside a sheet that one reports the
    // parent window, which is inactive while the sheet is up, so recording never started there.
    func body(content: Content) -> some View {
        content
            .background(KeyWindowObserver { windowIsKey = $0; update() })
            .onAppear { visible = true; update() }
            .onDisappear { visible = false; update() }
    }

    private func update() {
        let should = visible && windowIsKey
        if should, !capturing { lab.start(swipe: swipe, pinch: pinch) }
        if !should, capturing { lab.stop() }
        capturing = should
    }
}

/// Reports whether the window holding this view is the key window, and every change of it.
private struct KeyWindowObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) { view.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                report(false)
                return
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    self?.report(note.name == NSWindow.didBecomeKeyNotification)
                })
            }
            report(window.isKeyWindow)
        }

        private func report(_ isKey: Bool) {
            // Out of the view update in progress: SwiftUI state can't change during one.
            DispatchQueue.main.async { [weak self] in self?.onChange?(isKey) }
        }
    }
}
