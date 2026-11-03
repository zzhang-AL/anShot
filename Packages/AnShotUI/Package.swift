// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnShotUI",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AnShotUI", targets: ["AnShotUI"])
    ],
    dependencies: [
        // 本地包依赖必须显式声明 path，否则 SPM 无法解析 product
        .package(path: "../AnShotCapture"),
        // P4 起：选区几何与坐标换算定义于 AnShotCore，视图层需要调用
        .package(path: "../AnShotCore")
    ],
    targets: [
        .target(name: "AnShotUI", dependencies: ["AnShotCapture", "AnShotCore"]),
        // 本 target 存在的理由：AnShotUI 长期没有测试 target，导致其中
        // **不依赖 AppKit 的纯逻辑**（AnnotationEditorState 的撤销/重做与
        // 选区快照、SelectionDecoration 的手柄命中）无法被单元测试锁定，
        // 只能靠 -diagnoseXxx 诊断做截图式比对。详见 docs/refactor/plan.md。
        .testTarget(
            name: "AnShotUITests",
            dependencies: ["AnShotUI", "AnShotCore", "AnShotCapture"]
        )
    ]
)
