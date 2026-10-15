import CoreGraphics
import Foundation

/// Decides which scroll events to swallow. With system gestures off, macOS turns a three-finger
/// swipe into ordinary scrolling, so the window under the cursor scrolls while swipekey acts.
public struct ScrollFilter {
    // CGScrollPhase and CGMomentumScrollPhase raw values.
    public static let phaseBegan: Int64 = 1, phaseEnded: Int64 = 4, phaseCancelled: Int64 = 8
    public static let momentumEnd: Int64 = 3

    public let minFingers: Int
    private var swallowing = false

    public init(minFingers: Int) { self.minFingers = minFingers }

    /// True when the event should be dropped. `fingers` is the count on the trackpad right now.
    public mutating func shouldDrop(fingers: Int, scrollPhase: Int64, momentumPhase: Int64) -> Bool {
        guard minFingers > 0 else { return false }
        if fingers >= minFingers {
            swallowing = true
            return true
        }
        guard swallowing else { return false }
        // Fingers rarely lift together, so the swipe's own events keep coming with fewer fingers,
        // then macOS adds inertia. Only a scroll that really starts anew ends the swallowing:
        // a trackpad scroll that begins, or a mouse wheel (no phase at all).
        let mouseWheel = scrollPhase == 0 && momentumPhase == 0
        if scrollPhase == Self.phaseBegan || mouseWheel {
            swallowing = false
            return false
        }
        if momentumPhase == Self.momentumEnd { swallowing = false }
        return true
    }
}

/// Applies a ScrollFilter to the real scroll events through a session event tap.
/// Needs the same Accessibility permission swipekey already uses to post keystrokes.
public final class ScrollBlocker {
    private var filter: ScrollFilter
    private let fingers: () -> Int
    private var tap: CFMachPort?
    /// Called for every scroll event with what the filter saw and decided (used by `--debug`).
    public var onScroll: ((_ fingers: Int, _ phase: Int64, _ momentum: Int64, _ dropped: Bool) -> Void)?

    public init(minFingers: Int, fingers: @escaping () -> Int) {
        self.filter = ScrollFilter(minFingers: minFingers)
        self.fingers = fingers
    }

    /// Installs the tap on the main run loop. Returns false if macOS refuses it.
    public func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<ScrollBlocker>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            },
            userInfo: me
        ) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that is too slow or after secure input; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        let n = fingers(), phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let drop = filter.shouldDrop(fingers: n, scrollPhase: phase, momentumPhase: momentum)
        onScroll?(n, phase, momentum, drop)
        return drop ? nil : Unmanaged.passUnretained(event)
    }
}
