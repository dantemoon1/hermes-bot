// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "HermesKit", targets: ["HermesKit"]),
        .executable(name: "hermes-bot-probe", targets: ["hermes-bot-probe"]),
    ],
    targets: [
        .target(name: "HermesKit"),
        .executableTarget(name: "hermes-bot-probe", dependencies: ["HermesKit"]),
        .testTarget(name: "HermesKitTests", dependencies: ["HermesKit"]),
    ]
)
