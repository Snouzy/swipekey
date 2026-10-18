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

// Rewrite key events listed in "remaps" (only installed when there are some: zero cost otherwise).
var keyRemapTap: KeyRemapTap?
if !config.remaps.isEmpty {
    do {
        let tap = KeyRemapTap(try KeyRemapper(config.remaps))
        if debug { tap.onRemap = { from, to, sender in log("remap key \(from) -> \(to) from \(sender)") } }
        if tap.start() {
            keyRemapTap = tap
            log("Remapping \(config.remaps.count) key(s).")
        } else {
            log("Could not install the key remapper (Accessibility permission?).")
        }
    } catch { fail("invalid remap: \(error)") }
}

// Keep multi-finger swipes from also scrolling the window under the cursor.
var scrollBlocker: ScrollBlocker?
if config.blockScrollWithFingers > 0 {
    let blocker = ScrollBlocker(minFingers: config.blockScrollWithFingers) { engine.activeFingers }
    if debug { blocker.onScroll = { n, phase, momentum, dropped in log("scroll fingers=\(n) phase=\(phase) momentum=\(momentum) \(dropped ? "DROPPED" : "passed")") } }
    if blocker.start() {
        scrollBlocker = blocker
        log("Blocking scroll while \(config.blockScrollWithFingers)+ fingers touch the trackpad.")
    } else {
        log("Could not install the scroll filter (Accessibility permission?): swipes may also scroll.")
    }
}

// After sleep, MultitouchSupport devices stop sending frames: restart them on wake.
let workspaceCenter = NSWorkspace.shared.notificationCenter
workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    _ = MultitouchSource.start(engine)
}

/// Restarts swipekey in place with the config file as it is now, so every setting applies.
/// The config is checked first: a broken file keeps the running instance and says why.
func reloadConfig() throws {
    if FileManager.default.fileExists(atPath: configURL.path) {
        let next = try Config.load(from: configURL)
        _ = try Engine(config: next)
        _ = try KeyRemapper(next.remaps)
    }
    log("Reloading \(configURL.path).")
    MultitouchSource.stop()
    // Same pid and same signed binary: launchd keeps tracking it and Accessibility stays granted.
    execv(Bundle.main.executablePath ?? CommandLine.arguments[0], CommandLine.unsafeArgv)
    throw ConfigError("Could not restart: \(String(cString: strerror(errno)))")
}

// A background app (LSUIElement): no Dock icon, only the optional menu bar icon.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var menuBar: MenuBar?
if config.menuBarIcon {
    let bar = MenuBar(engine: engine, config: config, configURL: configURL) {
        do { try reloadConfig() } catch { menuBar?.show(error) }
    }
    menuBar = bar
    engine.onGesture = { trigger in
        if debug { log("gesture: \(trigger)") }
        bar.gestureFired(trigger)
    }
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

app.run()
