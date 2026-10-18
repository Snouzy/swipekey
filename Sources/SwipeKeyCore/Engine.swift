import CoreGraphics
import Foundation

/// A gesture plus the keyboard modifiers held while it happened.
public struct Trigger: Hashable, CustomStringConvertible {
    /// The modifiers a binding can require. Fn is left out: macOS sets it for arrow and function keys too.
    public static let holdableModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    public let gesture: Gesture
    private let heldRaw: UInt64

    public var held: CGEventFlags { CGEventFlags(rawValue: heldRaw) }

    public init(gesture: Gesture, held: CGEventFlags) {
        self.gesture = gesture
        self.heldRaw = held.intersection(Self.holdableModifiers).rawValue
    }

    public var description: String {
        let names: [(CGEventFlags, String)] = [(.maskControl, "control"), (.maskAlternate, "option"), (.maskShift, "shift"), (.maskCommand, "cmd")]
        let modifiers = names.filter { held.contains($0.0) }.map(\.1)
        return modifiers.isEmpty ? gesture.description : "\(modifiers.joined(separator: "+")) + \(gesture)"
    }
}

/// Routes touch frames to per-device recognizers and runs the actions bound to the gestures they emit.
public final class Engine {
    private let actions: [Trigger: [Action]]
    private let makeRecognizers: () -> [GestureRecognizer]
    private let heldModifiers: () -> CGEventFlags
    private var recognizersByDevice: [UInt: [GestureRecognizer]] = [:]
    private var fingersByDevice: [UInt: Int] = [:]
    private let lock = NSLock()

    /// Fingers currently pressed on the busiest trackpad (thread-safe).
    public var activeFingers: Int {
        lock.lock(); defer { lock.unlock() }
        return fingersByDevice.values.max() ?? 0
    }

    /// Called for every recognized gesture, bound or not (used by `--debug`).
    public var onGesture: ((Trigger) -> Void)?
    public var onActionError: ((Trigger, Error) -> Void)?

    /// `heldModifiers` reads the keyboard modifiers held right now; tests replace it.
    public init(
        config: Config,
        heldModifiers: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) }
    ) throws {
        var actions: [Trigger: [Action]] = [:]
        for binding in config.bindings {
            let held = try KeyCodes.flags(for: binding.holding)
            if held.contains(.maskSecondaryFn) {
                throw ConfigError("\"fn\" can't be used in \"holding\": use cmd, shift, option or control.")
            }
            actions[Trigger(gesture: binding.gesture, held: held), default: []].append(try binding.action.makeAction())
        }
        self.actions = actions
        self.heldModifiers = heldModifiers
        let swipeThreshold = config.swipeThreshold, pinchThreshold = config.pinchThreshold
        // New gesture types plug in here.
        self.makeRecognizers = { [SwipeRecognizer(threshold: swipeThreshold), PinchRecognizer(threshold: pinchThreshold)] }
    }

    /// Thread-safe: MultitouchSupport delivers each device's frames on its own thread.
    public func handle(_ frame: TouchFrame, device: UInt) {
        lock.lock()
        let recognizers = recognizersByDevice[device] ?? makeRecognizers()
        recognizersByDevice[device] = recognizers
        fingersByDevice[device] = frame.touches.filter(\.isTouching).count
        let gestures = recognizers.flatMap { $0.process(frame) }
        lock.unlock()

        for gesture in gestures {
            // Read modifiers when the gesture fires, not when the action runs on the main queue.
            let trigger = Trigger(gesture: gesture, held: heldModifiers())
            DispatchQueue.main.async { self.fire(trigger) }
        }
    }

    /// The actions bound to exactly this gesture and these held modifiers.
    public func actions(for trigger: Trigger) -> [Action] {
        actions[trigger] ?? []
    }

    private func fire(_ trigger: Trigger) {
        onGesture?(trigger)
        for action in actions(for: trigger) {
            do { try action.perform() } catch { onActionError?(trigger, error) }
        }
    }
}
