// swift-tools-version: 6.0
import PackageDescription

// The Mac app, run with `swift run` during development. It becomes a signed app bundle later.
let package = Package(
    name: "HermesBot",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Packages/HermesKit"),
        .package(path: "../Packages/HermesBotUI"),
    ],
    targets: [
        .executableTarget(name: "HermesBot", dependencies: ["HermesKit", "HermesBotUI"]),
        .testTarget(name: "HermesBotTests", dependencies: ["HermesBot", "HermesKit"]),
    ]
)
