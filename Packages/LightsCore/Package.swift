// swift-tools-version: 6.0
import PackageDescription

// Everything that isn't SwiftUI or CoreMIDI: the rig, the show, colour mixing,
// fades and sACN. Kept apart from the app so `swift test` covers it.
let package = Package(
    name: "LightsCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "LightsCore", targets: ["LightsCore"])],
    targets: [
        .target(name: "LightsCore", resources: [.copy("Resources/DefaultShow.json")]),
        .testTarget(name: "LightsCoreTests", dependencies: ["LightsCore"]),
    ]
)
