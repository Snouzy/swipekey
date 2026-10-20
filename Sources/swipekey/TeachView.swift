import AppKit
import SwiftUI
import SwipeKeyCore

/// Teaches a gesture from five examples, like enrolling a fingerprint: a ring fills one segment
/// per good example, a wrong one says why. Nothing fires meanwhile (the window captures the pad).
struct TeachView: View {
    @ObservedObject var store: ConfigStore
    let gesture: SwipeKeyCore.Gesture
    /// The taught value, or nil when the global one is kept.
    let onUse: (Double?) -> Void
    @State private var session: TeachSession
    @State private var feedback: TeachSession.Feedback?
    @Environment(\.dismiss) private var dismiss

    init(store: ConfigStore, gesture: SwipeKeyCore.Gesture, onUse: @escaping (Double?) -> Void) {
        self.store = store
        self.gesture = gesture
        self.onUse = onUse
        _session = State(initialValue: TeachSession(gesture: gesture))
    }

    /// The global value for this kind of gesture.
    private var current: Double {
        if case .pinch = gesture { return store.config.pinchThreshold }
        return store.config.swipeThreshold
    }

    private var proposal: Double { Teach.proposal(for: gesture, examples: session.examples, current: current) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                Text("Teach \(gesture.description)").font(.title3.bold())
                ring
                if session.isDone { result } else { teaching }
            }
            .padding(24)
            .frame(maxWidth: .infinity)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if !session.examples.isEmpty {
                    Button("Start over") {
                        session = TeachSession(gesture: gesture)
                        feedback = nil
                    }
                }
                Button("Use it") {
                    onUse(proposal == current ? nil : proposal)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.isDone)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(Theme.header)
        }
        .frame(width: 520)
        .background(Theme.content)
        .tint(Theme.accent)
        // The whole sheet captures, result screen included: a gesture done there must not run
        // its action for real.
        .capturingTouches(store.lab, swipe: store.config.swipeThreshold, pinch: store.config.pinchThreshold)
        .onAppear { store.lab.onFrame = observe }
        .onDisappear { store.lab.onFrame = nil }
    }

    /// Five segments around the gesture's animation, filling as examples come in.
    private var ring: some View {
        let count = TeachSession.examplesNeeded
        let gap = 0.02
        return ZStack {
            ForEach(0..<count, id: \.self) { i in
                let start = Double(i) / Double(count) + gap / 2
                let end = Double(i + 1) / Double(count) - gap / 2
                Circle()
                    .trim(from: start, to: end)
                    .stroke(i < session.examples.count ? Theme.accent : Color(nsColor: .separatorColor),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if session.isDone {
                Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.accent)
                    .transition(.scale.combined(with: .opacity))
            } else {
                MiniTrackpad(gesture: gesture)
            }
        }
        .frame(width: 150, height: 150)
        .animation(.easeOut(duration: 0.3), value: session.examples.count)
        .accessibilityElement()
        .accessibilityLabel("Examples")
        .accessibilityValue("\(session.examples.count) of \(count)")
    }

    private var teaching: some View {
        VStack(spacing: 12) {
            Text(prompt).font(.headline).multilineTextAlignment(.center)
            Text(feedbackText).font(.callout)
                .foregroundStyle(feedbackIsGood ? Color.green : Color.orange)
                .frame(minHeight: 20)
            LiveTrackpad(lab: store.lab) {
                Text("Your fingers show up here").font(.caption).foregroundStyle(.secondary)
            }
            .frame(height: 150)
        }
    }

    private var prompt: String {
        let left = TeachSession.examplesNeeded - session.examples.count
        let how: String
        switch gesture {
        case let .swipe(fingers, direction): how = "Swipe \(direction.rawValue) with \(fingers) fingers"
        case let .pinch(fingers, direction): how = "Pinch \(direction == .in ? "in" : "out") with \(fingers) fingers"
        }
        return session.examples.isEmpty ? "\(how), the way you usually do." : "Again: \(left) more to go."
    }

    private var feedbackIsGood: Bool {
        if case .accepted = feedback { return true }
        return false
    }

    private var feedbackText: String {
        switch feedback {
        case nil: return ""
        case .accepted: return "Got it."
        case let .wrongFingers(n): return "That was \(n) fingers."
        case let .other(seen): return "That looked like a \(seen.description)."
        case .tooSmall: return "A bit further."
        case .tooSlow: return "Quicker and straighter: a slow two-finger swipe reads as a scroll."
        case .notStraight:
            if case .pinch = gesture { return "Keep the fingers around the same centre." }
            return "Straighter, with the fingers moving together."
        }
    }

    private func observe(_ frame: TouchFrame) {
        guard let got = session.observe(frame) else { return }
        feedback = got
        let performer = NSHapticFeedbackManager.defaultPerformer
        if case .accepted = got {
            performer.perform(.levelChange, performanceTime: .now)
        } else {
            performer.perform(.generic, performanceTime: .now)
        }
    }

    /// The examples as bars, the line where the gesture will fire, and what changes.
    private var result: some View {
        let largest = max(session.examples.max() ?? 1, proposal)
        return VStack(alignment: .leading, spacing: 12) {
            Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(session.examples.enumerated()), id: \.offset) { _, size in
                    RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.7))
                        .frame(width: 34, height: CGFloat(90 * size / largest))
                }
            }
            .frame(height: 90, alignment: .bottom)
            .overlay(alignment: .bottom) {
                // Where it will fire.
                Rectangle().fill(Color.orange).frame(height: 2)
                    .offset(y: -CGFloat(90 * proposal / largest))
            }
            Text("Bars: your 5 examples. Orange line: where it will fire.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        let now = Self.percent(current), next = Self.percent(proposal)
        if proposal == current {
            return gesture.fingers >= 3
                ? "Your examples already clear the current setting (\(now) of the trackpad) easily: nothing to change."
                : "Two-finger gestures never get easier than the current setting (\(now) of the trackpad), so it stays."
        }
        return "It will fire after \(next) of the trackpad instead of \(now)."
    }

    /// "5%", "4.8%", "12%": one decimal under 10%, none when it's zero.
    static func percent(_ value: Double) -> String {
        let tenths = (value * 1000).rounded()
        if tenths >= 100 || tenths.truncatingRemainder(dividingBy: 10) == 0 { return String(format: "%.0f%%", value * 100) }
        return String(format: "%.1f%%", tenths / 10)
    }
}
