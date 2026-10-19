// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swipekey",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "swipekey", targets: ["swipekey"]),
    ],
    targets: [
        // Thin C bridge over Apple's private MultitouchSupport framework (loaded with dlopen).
        .target(name: "CMultitouch"),
        // Gestures, recognizers, actions and config: everything testable without a trackpad.
        .target(name: "SwipeKeyCore", dependencies: ["CMultitouch"]),
        .executableTarget(name: "swipekey", dependencies: ["SwipeKeyCore"]),
        .testTarget(name: "SwipeKeyCoreTests", dependencies: ["SwipeKeyCore"], resources: [.copy("Fixtures")]),
    ]
)
