import CMultitouch

/// Feeds frames from every multitouch device (built-in trackpad, Magic Trackpad) into an engine.
public enum MultitouchSource {
    // The C callback cannot capture context, so the target engine lives here.
    nonisolated(unsafe) private static var engine: Engine?

    /// Returns the number of devices started, or nil when MultitouchSupport could not be loaded.
    public static func start(_ engine: Engine) -> Int? {
        self.engine = engine
        let count = sk_multitouch_start { device, touches, count, timestamp in
            guard let engine = MultitouchSource.engine else { return }
            let buffer = UnsafeBufferPointer(start: touches, count: Int(count))
            let frame = TouchFrame(
                touches: buffer.map {
                    Touch(x: Double($0.x), y: Double($0.y), identifier: Int($0.identifier), state: Int($0.state))
                },
                timestamp: timestamp
            )
            engine.handle(frame, device: device)
        }
        return count < 0 ? nil : Int(count)
    }

    public static func stop() {
        sk_multitouch_stop()
        engine = nil
    }
}
