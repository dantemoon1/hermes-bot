// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesBotUI",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "HermesBotUI", targets: ["HermesBotUI"])],
    targets: [
        .target(name: "HermesBotUI"),
        .testTarget(name: "HermesBotUITests", dependencies: ["HermesBotUI"]),
    ]
)
