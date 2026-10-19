import Foundation
import SwipeKeyCore

/// `swipekey --record <dir>`: guides through a few gestures and saves each one's raw frames as a
/// trace, for the recognition tests. Runs no engine, so nothing is pressed.
enum Recorder {
    struct Step {
        let file: String
        let instruction: String
        let expect: Gesture?
    }

    static let steps: [Step] = [
        Step(file: "swipe-3-up", instruction: "15 three-finger swipes up, mix quick and lazy", expect: .swipe(fingers: 3, direction: .up)),
        Step(file: "swipe-3-down", instruction: "10 three-finger swipes down", expect: .swipe(fingers: 3, direction: .down)),
        Step(file: "swipe-3-left", instruction: "10 three-finger swipes left", expect: .swipe(fingers: 3, direction: .left)),
        Step(file: "swipe-3-right", instruction: "10 three-finger swipes right", expect: .swipe(fingers: 3, direction: .right)),
        Step(file: "swipe-2-left", instruction: "10 two-finger swipes left", expect: .swipe(fingers: 2, direction: .left)),
        Step(file: "swipe-2-right", instruction: "10 two-finger swipes right", expect: .swipe(fingers: 2, direction: .right)),
        Step(file: "scroll-2", instruction: "Scroll normally for about a minute: up, down and sideways, in a browser or a long document", expect: nil),
        Step(file: "pinch-2-in", instruction: "10 two-finger pinches in", expect: .pinch(fingers: 2, direction: .in)),
        Step(file: "thumb-3-up", instruction: "10 three-finger swipes up with your thumb resting on the trackpad", expect: .swipe(fingers: 3, direction: .up)),
    ]

    static func run(into directory: URL) -> Never {
        let lock = NSLock()
        nonisolated(unsafe) var frames: [TouchFrame] = []
        guard let devices = MultitouchSource.start({ frame, _ in
            lock.lock(); frames.append(frame); lock.unlock()
        }), devices > 0 else {
            fail("no multitouch device found")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { fail("can't create \(directory.path): \(error)") }

        print("Pause swipekey from the menu bar first, so these gestures don't press keys.")
        print("Each step: do the gestures, then press Enter to save. Type r then Enter to redo a step.\n")
        var index = 0
        while index < steps.count {
            let step = steps[index]
            print("[\(index + 1)/\(steps.count)] \(step.instruction)")
            lock.lock(); frames = []; lock.unlock()
            let answer = readLine() ?? ""
            lock.lock(); let recorded = frames; lock.unlock()
            if answer.trimmingCharacters(in: .whitespaces).lowercased() == "r" {
                print("Discarded, again:")
                continue
            }
            let trace = Trace(name: step.file, expect: step.expect, frames: recorded)
            let url = directory.appendingPathComponent(step.file + ".json")
            do { try trace.write(to: url) } catch { fail("can't write \(url.path): \(error)") }
            let gestures = trace.sessions.filter { session in
                session.contains { $0.touches.filter(\.isTouching).count >= 2 }
            }.count
            print("  saved \(gestures) gesture(s) to \(url.path)\n")
            index += 1
        }
        MultitouchSource.stop()
        print("Done. You can resume swipekey.")
        exit(0)
    }
}
