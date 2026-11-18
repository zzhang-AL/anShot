// swift-tools-version: 6.0
import PackageDescription

// AnShotAutomation：把 anShot 的捕获、识别、探测与录制能力暴露给外部 AI 工具/脚本。
//
// ── 为什么它是独立包而非直接写进 App ─────────────────────────
//
// 自动化协议与参数校验需要高频独立单测，而不应耦合界面层；
// 同时 MCP/CLI 的协议细节也不该污染捕获模块（`AnShotCapture`）。
// 本包夹在两者之间：只做「参数校验 → 调用捕获/识别/录制 → 编码/裁切 → 输出」，
// 不重新实现任何捕获或编解码算法。
//
// ── 为什么依赖 MCP SDK 而不是自己拼 JSON-RPC ────────────────
//
// 协议里的初始化协商、能力声明、批量请求、取消通知都有既成语义，
// 手写一遍等价于把协议版本演进的责任揽到自己身上。
// SDK 版本固定为 0.12.1（实测可编译、对应规范 2025-06-18）。
//
// 依赖说明：MCP product 自身只依赖 swift-system / swift-log / eventsource，
// 不链接 swift-nio；故 stdio 场景不会把网络栈带进 app。
//
// 版本用 `exact` 而非 `from`：本包是**应用**的一部分而不是被广泛复用的库，
// 构建应当可重现；`from` 会让同一个提交在不同时间解析出不同版本。
// （升级时显式改这个数字，并执行 `swift test` 与 `tools/anshot-mcp-smoke.py` 验证。）
let package = Package(
    name: "AnShotAutomation",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AnShotAutomation", targets: ["AnShotAutomation"])
    ],
    dependencies: [
        // 本地包依赖必须显式声明 path，否则 SPM 无法解析 product
        .package(path: "../AnShotCapture"),
        .package(path: "../AnShotCore"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        // 显式声明：MCP 的 product 不 re-export Logging，
        // 而本包需要它把日志指向 stderr（见 MCPServer.swift 的说明）。
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "AnShotAutomation",
            dependencies: [
                "AnShotCapture",
                "AnShotCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "AnShotAutomationTests",
            dependencies: ["AnShotAutomation"]
        )
    ]
)
