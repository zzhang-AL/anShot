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
        // 本 target 覆盖 AnShotUI 中不依赖屏幕捕获权限的核心逻辑与视图状态机测试
        // （如标注编辑器撤销/重做、选区手势与几何、贴图边界、设置窗口、历史缩略图、自动更新安全校验等）。
        .testTarget(
            name: "AnShotUITests",
            dependencies: ["AnShotUI", "AnShotCore", "AnShotCapture"]
        )
    ]
)
