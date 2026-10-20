import XCTest
@testable import SwipeKeyCore

/// Mathias's bindings (gestures only; the actions don't matter here).
let mathiasBindings: [Binding] = [
    .swipe(fingers: 3, direction: .up), .swipe(fingers: 3, direction: .left), .swipe(fingers: 3, direction: .right),
    .swipe(fingers: 3, direction: .down), .pinch(fingers: 2, direction: .in),
    .swipe(fingers: 2, direction: .left), .swipe(fingers: 2, direction: .right),
].map { Binding(gesture: $0, action: .key("a", modifiers: [])) }

/// One real touch session from `Fixtures/probe-session.log`: what the hand meant, what the probe
/// saw fire at the time (old recognizer, threshold 0.05), and the frames rebuilt from its summary.
struct RealSession {
    let number: Int
    let intent: Gesture
    /// Each swipe done in the session (several when a finger rests on the pad between them).
    let expectedCount: Int
    let firedThen: [String]
    let frames: [TouchFrame]
}

enum RealSessions {
    /// Mathias did the gestures in this order while the probe ran (2026-10-19).
    static func intent(_ number: Int) -> Direction {
        switch number {
        case 63...87, 103...118, 155...157: return .down
        case 119...130: return .left
        case 131...140: return .right
        default: return .up
        }
    }

    /// Sessions where one finger rests on the trackpad while the others swipe.
    static let resting: ClosedRange<Int> = 141...144

    static func load() throws -> [RealSession] {
        guard let url = Bundle.module.url(forResource: "probe-session", withExtension: "log", subdirectory: "Fixtures") else {
            throw XCTSkip("no probe-session.log fixture")
        }
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        var sessions: [RealSession] = []
        var header: (number: Int, fired: [String])?
        var segments: [(n: Int, ms: Double, dx: Double, dy: Double)] = []

        func flush() {
            guard let header else { return }
            let resting = Self.resting.contains(header.number)
            let swipes = resting ? segments.filter { $0.n == 4 && hypot($0.dx, $0.dy) >= 0.05 }.count : 1
            sessions.append(RealSession(
                number: header.number,
                intent: .swipe(fingers: 3, direction: intent(header.number)),
                expectedCount: swipes,
                firedThen: header.fired,
                frames: frames(from: segments, resting: resting)
            ))
        }

        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if line.hasPrefix("#"), let number = Int(fields[0].dropFirst()) {
                flush()
                let fired = line.components(separatedBy: "fired=").last ?? "[]"
                let names = fired.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).components(separatedBy: "\", \"")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }.filter { !$0.isEmpty }
                header = (number, names)
                segments = []
            } else if fields.count == 4, fields[0].hasSuffix("f"), let n = Int(fields[0].dropLast()),
                      let ms = Double(fields[1].dropLast(2)),
                      let dx = Double(fields[2].dropFirst(2)), let dy = Double(fields[3].dropFirst(2)) {
                segments.append((n, ms, dx, dy))
            }
        }
        flush()
        return sessions
    }

    /// Rebuilds frames at 120 Hz: within a segment every moving finger moves in a straight line by
    /// the segment's travel. A resting finger (finger 0 in resting sessions) stays put while
    /// others touch, so the others move a little more to give the same centroid travel.
    /// Mathias's built-in trackpad, 124.8 × 76.8 mm (MTDeviceGetSensorSurfaceDimensions).
    static let aspect = 124.8 / 76.8

    static func frames(from segments: [(n: Int, ms: Double, dx: Double, dy: Double)], resting: Bool) -> [TouchFrame] {
        let step = 1.0 / 120
        var time = 100.0
        var fingers: [(id: Int, x: Double, y: Double)] = []
        var nextID = 0
        var result: [TouchFrame] = []

        for segment in segments {
            while fingers.count < segment.n {
                let x = 0.35 + 0.1 * Double(fingers.count)
                let y = fingers.last?.y ?? 0.45
                fingers.append((nextID, x, y))
                nextID += 1
            }
            while fingers.count > segment.n { fingers.removeLast() }
            let start = fingers
            let count = max(1, Int((segment.ms / 1000 / step).rounded()) + 1)
            let movers = resting && segment.n > 1 ? Double(segment.n - 1) : Double(segment.n)
            let scale = Double(segment.n) / movers
            for i in 0..<count {
                let f = count == 1 ? 1.0 : Double(i) / Double(count - 1)
                for (k, finger) in start.enumerated() where !(resting && segment.n > 1 && finger.id == 0) {
                    fingers[k].x = finger.x + segment.dx * scale * f
                    fingers[k].y = finger.y + segment.dy * scale * f
                }
                result.append(TouchFrame(touches: fingers.map { Touch(x: $0.x, y: $0.y, identifier: $0.id) }, timestamp: time, aspect: aspect))
                time += step
            }
        }
        result.append(TouchFrame(touches: [], timestamp: time, aspect: aspect))
        return result
    }
}

/// Fresh recognizers per session, as the engine makes them per device.
func replay(_ frames: [TouchFrame], make: () -> [GestureRecognizer]) -> [Gesture] {
    let recognizers = make()
    return frames.flatMap { frame in recognizers.flatMap { $0.process(frame) } }
}

final class FixtureTests: XCTestCase {
    /// The recognizers as the engine builds them for Mathias's config.
    static let mathiasIsBound: IsBound = { gesture in mathiasBindings.contains { $0.gesture == gesture && $0.holding.isEmpty } }

    static func mathiasRecognizers() -> [GestureRecognizer] {
        [SwipeRecognizer(threshold: 0.05, isBound: mathiasIsBound), PinchRecognizer(threshold: 0.03, isBound: mathiasIsBound)]
    }

    /// The old recognizer, as the probe ran it.
    static func probeRecognizers() -> [GestureRecognizer] {
        [LegacySwipeRecognizer(threshold: 0.05)]
    }

    /// The rebuilt frames must give what the probe saw at the time, or the fixture proves nothing.
    func testRebuiltFramesReproduceTheProbe() throws {
        let sessions = try RealSessions.load()
        XCTAssertEqual(sessions.count, 163)
        var mismatches: [String] = []
        for session in sessions {
            let fired = replay(session.frames, make: Self.probeRecognizers).map(\.description)
            if fired != session.firedThen { mismatches.append("#\(session.number): probe \(session.firedThen), replay \(fired)") }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// Real misses accepted, with why. Everything else in the session must fire as meant.
    static let knownMisses: [Int: String] = [
        144: "first swipe: the thumb landed 16 ms before the fingers, like a real 4-finger swipe",
    ]

    /// Every real session fires its intended 3-finger gesture (once per swipe), and nothing else.
    func testRealSessionSwipesFire() throws {
        var failures: [String] = []
        for session in try RealSessions.load() where Self.knownMisses[session.number] == nil {
            let fired = replay(session.frames, make: Self.mathiasRecognizers)
            let expected = Array(repeating: session.intent, count: session.expectedCount)
            if fired != expected { failures.append("#\(session.number): fired \(fired.map(\.description)), meant \(expected.count)× \(session.intent)") }
        }
        XCTAssertEqual(failures, [])
    }

    /// Accepted misses still never fire a wrong gesture.
    func testKnownMissesFireNothingWrong() throws {
        for session in try RealSessions.load() where Self.knownMisses[session.number] != nil {
            let fired = replay(session.frames, make: Self.mathiasRecognizers)
            XCTAssertTrue(fired.allSatisfy { $0 == session.intent }, "#\(session.number): \(fired)")
        }
    }

    /// Recorded 2026-10-19: 8 two-finger swipes left (15–24 s), 11 right (27–40 s, plus two
    /// vertical flicks), then horizontal scrolling in a scrollbar (42–57 s), all with the
    /// trackpad's real timing. Only the swipes may fire.
    func testTwoFingerSwipesFireAndScrollingDoesNot() throws {
        guard let url = Bundle.module.url(forResource: "two-finger", withExtension: "json", subdirectory: "Fixtures") else {
            throw XCTSkip("no two-finger.json fixture")
        }
        let trace = try Trace.load(from: url)
        let start = try XCTUnwrap(trace.sessions.first?.first?.timestamp)
        var lefts = 0, rights = 0
        var wrong: [String] = []
        for session in trace.sessions {
            let at = session[0].timestamp - start
            for gesture in replay(session, make: Self.mathiasRecognizers) {
                switch (gesture, at) {
                case (.swipe(fingers: 2, direction: .left), 15..<24): lefts += 1
                case (.swipe(fingers: 2, direction: .right), 27..<40): rights += 1
                default: wrong.append(String(format: "%.2f s: %@", at, gesture.description))
                }
            }
        }
        XCTAssertEqual(wrong, [], "fired outside the swipes (scrolling or wrong direction)")
        XCTAssertEqual(lefts, 8)
        XCTAssertEqual(rights, 11)
    }

    /// Teach accepts Mathias's real swipes as examples, resting thumb included: it judges them
    /// with the recognizer itself.
    func testTeachAcceptsTheRealSwipes() throws {
        var refused: [String] = []
        for session in try RealSessions.load() where Self.knownMisses[session.number] == nil && session.expectedCount == 1 {
            var teach = TeachSession(gesture: session.intent)
            var feedback: TeachSession.Feedback?
            for frame in session.frames { feedback = teach.observe(frame) ?? feedback }
            if case .accepted = feedback { continue }
            refused.append("#\(session.number): \(String(describing: feedback))")
        }
        XCTAssertEqual(refused, [])
    }

    /// Prints how each intent does with the current recognizers. Asserts nothing.
    func testFixtureReport() throws {
        let sessions = try RealSessions.load()
        var lines: [String] = []
        for direction in Direction.allCases {
            let mine = sessions.filter { $0.intent == .swipe(fingers: 3, direction: direction) }
            let expected = mine.map(\.expectedCount).reduce(0, +)
            var hits = 0
            var misses: [String] = []
            for session in mine {
                let fired = replay(session.frames, make: Self.mathiasRecognizers)
                let good = fired.filter { $0 == session.intent }.count
                hits += min(good, session.expectedCount)
                if good < session.expectedCount || fired.contains(where: { $0 != session.intent }) {
                    misses.append("#\(session.number) \(fired.map(\.description))")
                }
            }
            lines.append("3-finger \(direction.rawValue): \(hits)/\(expected) fired. Misses: \(misses.joined(separator: ", "))")
        }
        print("FIXTURE REPORT\n" + lines.joined(separator: "\n"))
    }
}
