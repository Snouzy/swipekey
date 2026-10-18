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

    /// Called for every recognized gesture, bound or not (used by `--debug`).
    public var onGesture: ((Trigger) -> Void)?
    public var onActionError: ((Trigger, Error) -> Void)?

    /// `heldModifiers` reads the keyboard modifiers held right now; tests replace it.
    public init(
        config: Config,
        heldModifiers: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) }
    ) throws {
        (actions, makeRecognizers) = try Self.build(config)
        self.heldModifiers = heldModifiers
    }

    /// Applies new bindings and thresholds right away, without restarting (thread-safe).
    /// Throws, and keeps the current ones, when the config is invalid.
    public func reload(_ config: Config) throws {
        let (actions, makeRecognizers) = try Self.build(config)
        lock.lock(); defer { lock.unlock() }
        self.actions = actions
        self.makeRecognizers = makeRecognizers
        recognizersByDevice = [:]
    }

    private static func build(_ config: Config) throws -> ([Trigger: [Action]], () -> [GestureRecognizer]) {
        var actions: [Trigger: [Action]] = [:]
        for binding in config.bindings {
            if try KeyCodes.flags(for: binding.holding).contains(.maskSecondaryFn) {
                throw ConfigError("\"fn\" can't be used in \"holding\": use cmd, shift, option or control.")
            }
            actions[try binding.trigger(), default: []].append(try binding.action.makeAction())
        }
        let swipeThreshold = config.swipeThreshold, pinchThreshold = config.pinchThreshold
        // New gesture types plug in here.
        return (actions, { [SwipeRecognizer(threshold: swipeThreshold), PinchRecognizer(threshold: pinchThreshold)] })
    }

    /// Thread-safe: MultitouchSupport delivers each device's frames on its own thread.
    public func handle(_ frame: TouchFrame, device: UInt) {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }
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
