import CMultitouch

/// Feeds frames from every multitouch device (built-in trackpad, Magic Trackpad) into an engine.
public enum MultitouchSource {
    // The C callback cannot capture context, so the target lives here.
    nonisolated(unsafe) private static var handler: ((TouchFrame, UInt) -> Void)?

    /// Returns the number of devices started, or nil when MultitouchSupport could not be loaded.
    public static func start(_ engine: Engine) -> Int? {
        start { frame, device in engine.handle(frame, device: device) }
    }

    /// Calls `handler` with every frame of every device, on MultitouchSupport threads.
    public static func start(_ handler: @escaping (TouchFrame, UInt) -> Void) -> Int? {
        self.handler = handler
        let count = sk_multitouch_start { device, touches, count, timestamp, aspect in
            guard let handler = MultitouchSource.handler else { return }
            let buffer = UnsafeBufferPointer(start: touches, count: Int(count))
            let frame = TouchFrame(
                touches: buffer.map {
                    Touch(
                        x: Double($0.x), y: Double($0.y), identifier: Int($0.identifier), state: Int($0.state),
                        size: Double($0.size), majorAxis: Double($0.majorAxis), minorAxis: Double($0.minorAxis)
                    )
                },
                timestamp: timestamp,
                aspect: aspect
            )
            handler(frame, device)
        }
        return count < 0 ? nil : Int(count)
    }

    public static func stop() {
        sk_multitouch_stop()
        handler = nil
    }
}
