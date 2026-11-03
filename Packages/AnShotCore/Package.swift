// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnShotCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AnShotCore", targets: ["AnShotCore"])
    ],
    targets: [
        .target(name: "AnShotCore"),
        .testTarget(name: "AnShotCoreTests", dependencies: ["AnShotCore"], resources: [.copy("Fixtures/Scrollshot")])
    ]
)
