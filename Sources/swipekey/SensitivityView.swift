import SwiftUI
import SwipeKeyCore

/// The Sensitivity tab: two thresholds, and a test area with the real fingers and a bar that
/// fills toward the threshold. Nothing fires while testing; the thresholds save when a slider is let go.
struct SensitivityView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var lab: TouchLab
    @State private var swipe: Double
    @State private var pinch: Double
    @State private var error: String?

    init(store: ConfigStore) {
        self.store = store
        lab = store.lab
        _swipe = State(initialValue: store.config.swipeThreshold)
        _pinch = State(initialValue: store.config.pinchThreshold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sensitivity").font(.system(size: 20, weight: .bold))
                Text("How far your fingers travel before a gesture fires. Try it on your trackpad: the bar fills, and the gesture fires when it's full.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(spacing: 14) {
                    slider("Swipe distance", value: $swipe, range: 0.04...0.25, low: "Hair trigger", high: "Long swipes only")
                    slider("Pinch distance", value: $pinch, range: 0.02...0.12, low: "Small pinch", high: "Big pinch")
                }
                .frame(minWidth: 220, maxWidth: 300)
                testArea
            }
        }
        .capturingTouches(lab, swipe: swipe, pinch: pinch)
        .alert("Swipekey", isPresented: SwiftUI.Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func slider(_ title: String, value: SwiftUI.Binding<Double>, range: ClosedRange<Double>, low: String, high: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            Slider(value: value, in: range, step: 0.01) { editing in
                if !editing { save() }
            }
            .onChange(of: value.wrappedValue) { _ in lab.setThresholds(swipe: swipe, pinch: pinch) }
            .accessibilityLabel(title)
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardBorder))
    }

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Test area").font(.headline)
            LiveTrackpad(lab: lab) {
                Text("Swipe or pinch on your trackpad.\nNothing fires while you test here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 200)
            ProgressView(value: lab.progress)
                .tint(lab.progress >= 1 ? .green : Theme.accent)
                .animation(.easeOut(duration: 0.08), value: lab.progress)
                .accessibilityLabel("Progress toward firing")
            Text(status.text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(status.color)
                .frame(minHeight: 20, alignment: .leading)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .frame(maxWidth: .infinity)
    }

    private var status: (text: String, color: Color) {
        switch lab.outcome {
        case let .fired(gesture):
            let actions = store.config.bindings.filter { $0.gesture == gesture && $0.holding.isEmpty }.map(\.action.description)
            return ("Fired: \(gesture) → \(actions.isEmpty ? "no binding" : actions.joined(separator: ", "))", .green)
        case let .tooShort(traveled, needed):
            return (String(format: "Too short: traveled %.2f, needs %.2f. Lower the distance or swipe further.", traveled, needed), .orange)
        case .notQuick:
            return ("Far enough, but not read as a swipe: too slow, too diagonal, or the fingers didn't land together. A quick, straight flick works best.", .orange)
        case nil:
            return (lab.heading ?? "", .secondary)
        }
    }

    private func save() {
        // Slider steps are 0.01: keep the file free of 0.09000000000000001.
        let rounded = { (value: Double) in (value * 100).rounded() / 100 }
        do { try store.setThresholds(swipe: rounded(swipe), pinch: rounded(pinch)) } catch { self.error = "\(error)" }
    }
}
