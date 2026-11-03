// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnShotCapture",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AnShotCapture", targets: ["AnShotCapture"])
    ],
    dependencies: [
        // 自动识别的结果用 AnShotCore 的领域模型（DetectionTarget / DetectionGeometry），
        // 与选区共用同一套坐标语义。本地包依赖必须显式声明 path。
        .package(path: "../AnShotCore")
    ],
    targets: [
        .target(name: "AnShotCapture", dependencies: ["AnShotCore"]),
        .testTarget(name: "AnShotCaptureTests", dependencies: ["AnShotCapture", "AnShotCore"])
    ]
)
