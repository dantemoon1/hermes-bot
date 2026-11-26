// swift-tools-version: 6.0
import PackageDescription

// The Mac app, run with `swift run` during development. It becomes a signed app bundle later.
let package = Package(
    name: "HermesBot",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Packages/HermesKit"),
        .package(path: "../Packages/HermesBotUI"),
        // Installs updates. An exact version, chosen when it was a month old.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(name: "HermesBot", dependencies: ["HermesKit", "HermesBotUI", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "HermesBotTests", dependencies: ["HermesBot", "HermesKit"]),
    ]
)
