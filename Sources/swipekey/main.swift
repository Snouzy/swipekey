import AppKit
import Foundation
import SwipeKeyCore

let usage = """
usage: swipekey [--config <path>] [--debug] [--print-default-config]

  --config <path>          Config file (default: ~/.config/swipekey/config.json)
  --debug                  Log every recognized gesture
  --print-default-config   Print the built-in config as JSON and exit
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("swipekey: \(message)\n".utf8))
    exit(1)
}

// Under launchd stdout is a file: flush each line so the log is readable live.
setvbuf(stdout, nil, _IOLBF, 0)

let timestampFormatter = ISO8601DateFormatter()
func log(_ message: String) {
    print("[\(timestampFormatter.string(from: Date()))] \(message)")
}

var configURL = Config.defaultURL
var debug = false
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--config":
        guard let path = args.popFirst() else { fail("--config needs a path") }
        configURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    case "--debug":
        debug = true
    case "--print-default-config":
        print(try Config.default.jsonString())
        exit(0)
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        fail("unknown argument \(arg)\n\(usage)")
    }
}

let config: Config
if FileManager.default.fileExists(atPath: configURL.path) {
    do { config = try Config.load(from: configURL) } catch { fail("invalid config \(configURL.path): \(error)") }
} else {
    config = .default
    log("No config at \(configURL.path), using defaults (3-finger swipe up → Return).")
}

// Posting key events is gated by its own check (CGPreflightPostEventAccess), which can differ
// from the general Accessibility trust; CGRequestPostEventAccess shows the system prompt once.
let canPostEvents = CGPreflightPostEventAccess() || CGRequestPostEventAccess()
log("Permissions: post key events \(canPostEvents ? "yes" : "no"), accessibility trusted \(AXIsProcessTrusted() ? "yes" : "no").")
if !canPostEvents {
    log("Swipekey can't send keystrokes: allow it in System Settings → Privacy & Security → Accessibility, then restart it.")
}

let engine: Engine
do { engine = try Engine(config: config) } catch { fail("\(error)") }
engine.onGesture = { gesture in if debug { log("gesture: \(gesture)") } }
engine.onActionError = { gesture, error in log("action for \(gesture) failed: \(error)") }

guard let deviceCount = MultitouchSource.start(engine) else {
    fail("could not load MultitouchSupport.framework")
}
if deviceCount == 0 { fail("no multitouch device found") }
log("swipekey running on \(deviceCount) device(s) with \(config.bindings.count) binding(s).")

// After sleep, MultitouchSupport devices stop sending frames: restart them on wake.
let workspaceCenter = NSWorkspace.shared.notificationCenter
workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    _ = MultitouchSource.start(engine)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalSources = [SIGINT, SIGTERM].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        MultitouchSource.stop()
        exit(0)
    }
    source.resume()
    return source
}

RunLoop.main.run()
