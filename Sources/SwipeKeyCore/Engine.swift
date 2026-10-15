import Foundation

/// Routes touch frames to per-device recognizers and runs the actions bound to the gestures they emit.
public final class Engine {
    private let actions: [Gesture: [Action]]
    private let makeRecognizers: () -> [GestureRecognizer]
    private var recognizersByDevice: [UInt: [GestureRecognizer]] = [:]
    private let lock = NSLock()

    /// Called for every recognized gesture, bound or not (used by `--debug`).
    public var onGesture: ((Gesture) -> Void)?
    public var onActionError: ((Gesture, Error) -> Void)?

    public init(config: Config) throws {
        var actions: [Gesture: [Action]] = [:]
        for binding in config.bindings {
            actions[binding.gesture, default: []].append(try binding.action.makeAction())
        }
        self.actions = actions
        let threshold = config.swipeThreshold
        // New gesture types plug in here.
        self.makeRecognizers = { [SwipeRecognizer(threshold: threshold)] }
    }

    /// Thread-safe: MultitouchSupport delivers each device's frames on its own thread.
    public func handle(_ frame: TouchFrame, device: UInt) {
        lock.lock()
        let recognizers = recognizersByDevice[device] ?? makeRecognizers()
        recognizersByDevice[device] = recognizers
        let gestures = recognizers.flatMap { $0.process(frame) }
        lock.unlock()

        for gesture in gestures {
            DispatchQueue.main.async { self.fire(gesture) }
        }
    }

    private func fire(_ gesture: Gesture) {
        onGesture?(gesture)
        for action in actions[gesture] ?? [] {
            do { try action.perform() } catch { onActionError?(gesture, error) }
        }
    }
}
