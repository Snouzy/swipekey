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
    private var actions: [Trigger: [Action]]
    private var makeRecognizers: () -> [GestureRecognizer]
    private let heldModifiers: () -> CGEventFlags
    private var recognizersByDevice: [UInt: [GestureRecognizer]] = [:]
    private var fingersByDevice: [UInt: Int] = [:]
    private var enabled = true
    private var captureHandler: ((TouchFrame) -> Void)?
    private let lock = NSLock()

    /// Fingers currently pressed on the busiest trackpad (thread-safe). Zero while paused,
    /// so scrolling is never blocked then.
    public var activeFingers: Int {
        lock.lock(); defer { lock.unlock() }
        return enabled ? fingersByDevice.values.max() ?? 0 : 0
    }

    /// False pauses swipekey: no gesture fires and no scroll is blocked (thread-safe).
    public var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set {
            lock.lock(); defer { lock.unlock() }
            enabled = newValue
            // Gestures in progress start over on resume instead of firing halfway through.
            recognizersByDevice = [:]
        }
    }

    /// While set, every frame goes to this handler instead of the recognizers, so no action runs:
    /// the settings window records and tests gestures with it. Called on a MultitouchSupport
    /// thread. Thread-safe.
    public var capture: ((TouchFrame) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return captureHandler }
        set {
            lock.lock(); defer { lock.unlock() }
            captureHandler = newValue
            recognizersByDevice = [:]
        }
    }

    /// Called for every bound gesture that fires (used by `--debug` and the menu).
    public var onGesture: ((Trigger) -> Void)?
    public var onActionError: ((Trigger, Error) -> Void)?
    /// Called on the main queue when a 3+ finger swipe came close but didn't fire.
    public var onNearMiss: ((NearMiss) -> Void)?

    /// `heldModifiers` reads the keyboard modifiers held right now; tests replace it.
    public init(
        config: Config,
        heldModifiers: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) }
    ) throws {
        (actions, makeRecognizers) = try Self.build(config, heldModifiers: heldModifiers)
        self.heldModifiers = heldModifiers
    }

    /// Applies new bindings and thresholds right away, without restarting (thread-safe).
    /// Throws, and keeps the current ones, when the config is invalid.
    public func reload(_ config: Config) throws {
        let (actions, makeRecognizers) = try Self.build(config, heldModifiers: heldModifiers)
        lock.lock(); defer { lock.unlock() }
        self.actions = actions
        self.makeRecognizers = makeRecognizers
        recognizersByDevice = [:]
    }

    private static func build(
        _ config: Config, heldModifiers: @escaping () -> CGEventFlags
    ) throws -> ([Trigger: [Action]], () -> [GestureRecognizer]) {
        var actions: [Trigger: [Action]] = [:]
        for binding in config.bindings {
            if try KeyCodes.flags(for: binding.holding).contains(.maskSecondaryFn) {
                throw ConfigError("\"fn\" can't be used in \"holding\": use cmd, shift, option or control.")
            }
            actions[try binding.trigger(), default: []].append(try binding.action.makeAction())
        }
        let swipeThreshold = config.swipeThreshold, pinchThreshold = config.pinchThreshold
        // Taught distances, per gesture: the smallest when bindings of one gesture differ.
        var taught: [Gesture: Double] = [:]
        for binding in config.bindings {
            guard let threshold = binding.threshold else { continue }
            guard threshold > 0, threshold < 1 else {
                throw ConfigError("\(binding.gesture): \"threshold\" must be between 0 and 1, not \(threshold).")
            }
            taught[binding.gesture] = min(taught[binding.gesture] ?? threshold, threshold)
        }
        // Bound with the modifiers held when the gesture would fire: a binding that needs ⌘ doesn't
        // count, and doesn't lock the session, while ⌘ is up.
        let bound = actions
        let isBound: IsBound = { bound[Trigger(gesture: $0, held: heldModifiers())] != nil }
        // New gesture types plug in here.
        return (actions, {
            let swipe = SwipeRecognizer(threshold: swipeThreshold, isBound: isBound)
            let pinch = PinchRecognizer(threshold: pinchThreshold, isBound: isBound)
            swipe.thresholds = taught
            pinch.thresholds = taught
            return [swipe, pinch]
        })
    }

    /// Thread-safe: MultitouchSupport delivers each device's frames on its own thread.
    public func handle(_ frame: TouchFrame, device: UInt) {
        lock.lock()
        if let captureHandler {
            // Still counted, so a test swipe doesn't scroll the window underneath.
            fingersByDevice[device] = frame.touches.filter(\.isTouching).count
            lock.unlock()
            captureHandler(frame)
            return
        }
        guard enabled else {
            lock.unlock()
            return
        }
        let recognizers = recognizersByDevice[device] ?? makeRecognizers()
        recognizersByDevice[device] = recognizers
        fingersByDevice[device] = frame.touches.filter(\.isTouching).count
        let gestures = recognizers.flatMap { $0.process(frame) }
        let misses = recognizers.compactMap { $0.takeNearMiss() }
        lock.unlock()

        for miss in misses {
            DispatchQueue.main.async { self.onNearMiss?(miss) }
        }

        for gesture in gestures {
            // Read modifiers when the gesture fires, not when the action runs on the main queue.
            let trigger = Trigger(gesture: gesture, held: heldModifiers())
            DispatchQueue.main.async { self.fire(trigger) }
        }
    }

    /// The actions bound to exactly this gesture and these held modifiers.
    public func actions(for trigger: Trigger) -> [Action] {
        lock.lock(); defer { lock.unlock() }
        return actions[trigger] ?? []
    }

    private func fire(_ trigger: Trigger) {
        onGesture?(trigger)
        for action in actions(for: trigger) {
            do { try action.perform() } catch { onActionError?(trigger, error) }
        }
    }
}
