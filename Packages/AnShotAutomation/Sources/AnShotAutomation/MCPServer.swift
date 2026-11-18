//
//  MCPServer.swift
//  AnShotAutomation
//
//  MCP stdio 服务端。让 AI 客户端（Claude Code / Cursor / pi 等）直接调用截图、
//  离线 OCR、UI 控件树探测与有界时长录屏能力。
//
//  ── stdout 是协议通道，不是日志通道 ──────────────────────────
//
//      - 协议消息 → stdout（只由 StdioTransport 写）
//      - 一切日志 → stderr
//

import AnShotCapture
import CoreGraphics
import Foundation
import Logging
import MCP

/// 构建信息。用于在 MCP 握手时声明服务端版本。
enum AnShotBuildInfo {

    /// 对外声明的版本号。取 app bundle 的 `CFBundleShortVersionString`。
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "unknown"
    }
}

/// MCP 服务端入口。
public enum AnShotMCP {

    /// 服务端在 `initialize` 时返回给客户端的用法说明。
    static let instructions = """
    anShot 的 macOS 屏幕捕获、离线 OCR、UI 控件树探测与有界录制能力。七个工具配合使用：

    - list_displays             看有哪些屏幕（id / 逻辑尺寸 / 像素尺寸 / 缩放系数）
    - list_desktops             看各显示器的桌面与全屏空间（space_id / isCurrent）
    - list_windows              看有哪些可截图的窗口（应用名 / 标题 / window_id）
    - capture_screenshot        捕获屏幕/区域/后台窗口截图（支持 JPEG 压缩与坐标标尺网格）
    - ocr_screenshot            离线识别屏幕或本地图像中的文字，返回全文与逐行像素包围盒
    - inspect_window_elements   探测目标窗口或应用的 AX 控件树（角色 / 标题 / 逻辑点坐标框）
    - record_screen             有界时长（1...15 秒）录制为 GIF 或 MP4 文件，用于验收动画与交互

    截图的三种取景方式（互斥，按优先级排）：
    1. window_id 或 app —— 截指定窗口。**窗口被遮挡、不在最顶层时同样能截到
       完整内容**，所以「看一眼某个应用/某个窗口」优先用它，而不是去猜坐标。
    2. display_id + region —— 截某块屏幕的一块区域，单位是**显示器内逻辑点**
       （不是像素，也不是全局坐标），原点在该显示器左上角。
    3. 都不传 —— 截主显示器整屏。

    挑选窗口时以 title 为主要依据；title 为空表示该窗口本就没有标题，
    此时用 appName 判断。app 参数接受应用名（如 "Safari"、"Xcode"），
    会选中该应用在屏且面积最大的窗口。

    图像压缩与体积控制：
    - 默认 max_size 为 1568 像素（传 0 表示保持原分辨率——做像素级核验时传 0）。
    - 未显式指定 format: "png" 且 PNG 超过 3.5 MiB 时，自动降级为高质量 JPEG（quality=82）
      以控制响应在 5 MB 红线以内并大幅节省视觉 Token。
    - 可按需传入 format: "jpeg" / "png" 与 quality（1...100），或开启 coordinate_grid: true 辅助定位坐标。

    若无权限，工具会返回明确的处理步骤。授权对象是 **anShot.app 自身**，
    不是你的宿主进程；不要建议用户给终端或客户端授予屏幕录制权限。
    """

    /// 在 stdio 上运行服务端，直到 stdin 关闭。
    public static func run() async throws {
        let logger = makeLogger()

        let server = Server(
            name: "anshot",
            version: AnShotBuildInfo.version,
            title: "anShot Screen Capture",
            instructions: instructions,
            capabilities: .init(
                tools: .init(listChanged: false)
            )
        )

        await registerListTools(on: server, logger: logger)
        await registerCallTool(on: server, logger: logger)

        let transport = StdioTransport(logger: logger)
        try await server.start(transport: transport)
        logger.notice("anshot MCP server started; awaiting stdio")

        await server.waitUntilCompleted()
        await server.stop()
        logger.notice("anshot MCP server stopped")
    }

    /// stderr 日志器。
    private static func makeLogger() -> Logger {
        var logger = Logger(label: "com.anshot.mcp") { label in
            StreamLogHandler.standardError(label: label)
        }

        let raw = ProcessInfo.processInfo.environment["ANSHOT_MCP_LOG"]?.lowercased()
        switch raw {
        case "trace":   logger.logLevel = .trace
        case "debug":   logger.logLevel = .debug
        case "info":    logger.logLevel = .info
        case "warning": logger.logLevel = .warning
        case "error":   logger.logLevel = .error
        default:        logger.logLevel = .notice
        }

        return logger
    }

    // MARK: - 工具声明

    private static func registerListTools(
        on server: Server,
        logger: Logger
    ) async {
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                listDisplaysTool,
                listDesktopsTool,
                listWindowsTool,
                captureScreenshotTool,
                ocrScreenshotTool,
                inspectWindowElementsTool,
                recordScreenTool
            ])
        }
    }

    private static var listDisplaysTool: Tool {
        Tool(
            name: "list_displays",
            description: """
            列出当前所有显示器，返回每块显示器的 ID、逻辑尺寸、物理像素尺寸、
            缩放系数与全局位置。用 display_id + region 截图前先调它，
            以拿到 ID 并用返回的逻辑尺寸校验 region 是否越界。

            若目标是「某个应用的窗口」，改用 list_windows —— 那不需要猜坐标。
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false)
            ]),
            annotations: .init(title: "列出显示器", readOnlyHint: true, openWorldHint: false)
        )
    }

    private static var listDesktopsTool: Tool {
        Tool(
            name: "list_desktops",
            description: """
            列出各显示器的桌面与全屏空间，返回 id、displayID、position、desktopNumber、
            kind 和 isCurrent。position 是该屏 Mission Control 从左到右的位置；
            desktopNumber 只对普通桌面计数。id 可作为 capture_screenshot 的 space_id。
            桌面 ID 可能变化，截图前应重新查询。
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false)
            ]),
            annotations: .init(title: "列出桌面", readOnlyHint: true, openWorldHint: false)
        )
    }

    private static var listWindowsTool: Tool {
        Tool(
            name: "list_windows",
            description: """
            列出所有桌面的窗口，按「当前在屏优先、面积降序」排序。

            每个窗口返回：id、应用名（appName）、标题（title）、
            窗口矩形（frame，全局逻辑点）、所在显示器、所属桌面 ID（spaceIDs）、是否在屏。

            用其中的 id 作为 capture_screenshot / inspect_window_elements / ocr_screenshot 的 window_id，
            或把 appName 作为对应工具的 app 参数。

            注意 title 可能为空：那表示该窗口本就没有标题，此时按 appName 与 frame 判断即可。
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false)
            ]),
            annotations: .init(title: "列出窗口", readOnlyHint: true, openWorldHint: false)
        )
    }

    private static var captureScreenshotTool: Tool {
        Tool(
            name: "capture_screenshot",
            description: """
            捕获屏幕截图并以图像返回。

            **取景方式三选一（互斥）**：

            1. 窗口 —— 传 window_id（来自 list_windows）或 app（应用名）。
               **窗口被遮挡、不在最顶层时同样能截到完整内容**。
               不要为了截图先调用 activate、设置 frontmost、执行 AXRaise 或其他窗口置前操作；
               截不到时应说明限制，不能擅自激活应用或切换桌面。
            2. 区域 —— 传 display_id + region（显示器内逻辑点 [x, y, width, height]，原点左上）。
            3. 整屏 —— 传 display_id，省略时为主显示器。可传 space_id 指定桌面（默认不切换，
               仅在用户明确同意后才能传 allow_switch: true）。

            其他参数：
            - max_size：输出长边像素上限，默认 1568；传 0 表示不缩放。
            - format："png" 或 "jpeg"。省略时默认优先 PNG，若 PNG 超过 3.5 MiB 则自动降级为高质量 JPEG（quality=82）。
            - quality：JPEG 压缩质量（1...100，默认 82，仅 JPEG 时生效）。
            - coordinate_grid：可选布尔值，为 true 时在图像边缘绘制逻辑点坐标标尺网格，辅助精准定位点击坐标。
            - save_path：把截图另存到该路径（已存在时自动追加序号，不覆盖）。

            截图由 anShot.app 自己完成，复用它已有的屏幕录制授权。
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_id": .object([
                        "type": .string("integer"),
                        "description": .string("目标窗口 ID，来自 list_windows 的 id。")
                    ]),
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("应用名（如 Safari、Xcode），与 window_id 二选一。")
                    ]),
                    "display_id": .object([
                        "type": .string("integer"),
                        "description": .string("目标显示器 ID，来自 list_displays。省略则截取主显示器。")
                    ]),
                    "space_id": .object([
                        "type": .string("integer"),
                        "description": .string("桌面 ID，来自 list_desktops。默认不会切换到其他桌面。"),
                        "minimum": .int(1)
                    ]),
                    "allow_switch": .object([
                        "type": .string("boolean"),
                        "description": .string("仅在用户明确同意切换桌面后设为 true，允许切换并恢复。默认 false。")
                    ]),
                    "region": .object([
                        "type": .string("array"),
                        "description": .string("显示器内逻辑点区域 [x, y, width, height]，原点该显示器左上角。"),
                        "items": .object(["type": .string("number")]),
                        "minItems": .int(4),
                        "maxItems": .int(4)
                    ]),
                    "max_size": .object([
                        "type": .string("integer"),
                        "description": .string("输出长边像素上限，默认 1568；0 表示不缩放。"),
                        "minimum": .int(0)
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("png"), .string("jpeg")]),
                        "description": .string("图像编码格式（png 或 jpeg）。省略时优先 PNG，超过 3.5 MiB 自动转 JPEG。")
                    ]),
                    "quality": .object([
                        "type": .string("integer"),
                        "description": .string("JPEG 压缩质量（1...100，默认 82；仅 JPEG 时有效）。"),
                        "minimum": .int(1),
                        "maximum": .int(100)
                    ]),
                    "coordinate_grid": .object([
                        "type": .string("boolean"),
                        "description": .string("是否在图像边缘绘制逻辑点坐标标尺网格辅助定位坐标，默认 false。")
                    ]),
                    "save_path": .object([
                        "type": .string("string"),
                        "description": .string("另存路径（可选）。已存在时自动追加序号，不会覆盖。")
                    ])
                ]),
                "additionalProperties": .bool(false)
            ]),
            annotations: .init(title: "截取屏幕", readOnlyHint: false, openWorldHint: false)
        )
    }

    private static var ocrScreenshotTool: Tool {
        Tool(
            name: "ocr_screenshot",
            description: """
            离线识别屏幕/窗口/区域截图或本地图片文件中的文字（基于 Apple Vision，100% 本地运行），
            返回全文（fullText）与按阅读顺序排列的逐行结果（text、confidence、boundingBox 像素包围盒）。

            输入来源二选一（互斥）：
            1. image_path —— 读取本地图片文件进行识别（无需屏幕录制权限）。
            2. 屏幕取景 —— 传 window_id / app 或 display_id + region / space_id + allow_switch，
               自动以原始分辨率抓帧并识别。
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "image_path": .object([
                        "type": .string("string"),
                        "description": .string("本地图片文件路径（与截屏参数互斥）。")
                    ]),
                    "window_id": .object([
                        "type": .string("integer"),
                        "description": .string("目标窗口 ID，来自 list_windows。")
                    ]),
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("目标应用名。")
                    ]),
                    "display_id": .object([
                        "type": .string("integer"),
                        "description": .string("目标显示器 ID。")
                    ]),
                    "space_id": .object([
                        "type": .string("integer"),
                        "description": .string("目标桌面 ID。"),
                        "minimum": .int(1)
                    ]),
                    "allow_switch": .object([
                        "type": .string("boolean"),
                        "description": .string("是否允许切换桌面并恢复，默认 false。")
                    ]),
                    "region": .object([
                        "type": .string("array"),
                        "description": .string("显示器内逻辑点区域 [x, y, width, height]。"),
                        "items": .object(["type": .string("number")]),
                        "minItems": .int(4),
                        "maxItems": .int(4)
                    ]),
                    "languages": .object([
                        "type": .string("array"),
                        "description": .string("偏好识别语言代码列表（如 [\"zh-Hans\", \"en-US\"]）。"),
                        "items": .object(["type": .string("string")])
                    ])
                ]),
                "additionalProperties": .bool(false)
            ]),
            annotations: .init(title: "离线文字识别", readOnlyHint: true, openWorldHint: false)
        )
    }

    private static var inspectWindowElementsTool: Tool {
        Tool(
            name: "inspect_window_elements",
            description: """
            探测目标窗口或应用内的辅助功能（AX）UI 控件树，返回各控件的角色（role）、标题（title）、
            描述、值、启用状态与全局逻辑点坐标框（frame）。
            需要辅助功能权限；若无权限则返回包含 hasAccessibilityPermission: false 与授权指引的结构化结果。
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_id": .object([
                        "type": .string("integer"),
                        "description": .string("目标窗口 ID（与 app / pid 三选一）。")
                    ]),
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("目标应用名（与 window_id / pid 三选一）。")
                    ]),
                    "pid": .object([
                        "type": .string("integer"),
                        "description": .string("目标进程 PID（与 window_id / app 三选一）。"),
                        "minimum": .int(1)
                    ]),
                    "max_depth": .object([
                        "type": .string("integer"),
                        "description": .string("最大遍历深度（1...12，默认 4）。"),
                        "minimum": .int(1),
                        "maximum": .int(12)
                    ]),
                    "max_elements": .object([
                        "type": .string("integer"),
                        "description": .string("最大返回控件数量（1...1000，默认 200）。"),
                        "minimum": .int(1),
                        "maximum": .int(1000)
                    ])
                ]),
                "additionalProperties": .bool(false)
            ]),
            annotations: .init(title: "探测窗口控件树", readOnlyHint: true, openWorldHint: false)
        )
    }

    private static var recordScreenTool: Tool {
        Tool(
            name: "record_screen",
            description: """
            录制有界时长（强制 1...15 秒）的屏幕、区域或窗口视频，输出 GIF 或 MP4 文件路径，
            供验收动画、过渡效果与交互时序。

            取景参数与 capture_screenshot 一致（window_id / app 或 display_id + region，默认主显示器）。
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_id": .object([
                        "type": .string("integer"),
                        "description": .string("目标窗口 ID。")
                    ]),
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("目标应用名。")
                    ]),
                    "display_id": .object([
                        "type": .string("integer"),
                        "description": .string("目标显示器 ID。")
                    ]),
                    "region": .object([
                        "type": .string("array"),
                        "description": .string("显示器内逻辑点区域 [x, y, width, height]。"),
                        "items": .object(["type": .string("number")]),
                        "minItems": .int(4),
                        "maxItems": .int(4)
                    ]),
                    "duration": .object([
                        "type": .string("number"),
                        "description": .string("录制时长（秒），强制限制在 1...15 秒之间，默认 3 秒。"),
                        "minimum": .int(1),
                        "maximum": .int(15)
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("gif"), .string("mp4")]),
                        "description": .string("输出格式：gif（默认）或 mp4。")
                    ]),
                    "fps": .object([
                        "type": .string("integer"),
                        "description": .string("帧率（GIF 默认 12，上限 30；MP4 默认 30，上限 60）。"),
                        "minimum": .int(1),
                        "maximum": .int(60)
                    ]),
                    "max_size": .object([
                        "type": .string("integer"),
                        "description": .string("GIF 长边像素上限（100...1600，默认 800；仅 gif 格式支持）。"),
                        "minimum": .int(100),
                        "maximum": .int(1600)
                    ]),
                    "save_path": .object([
                        "type": .string("string"),
                        "description": .string("另存路径（可选）。省略时保存至 ~/Pictures/anShot/；绝不覆盖已有文件。")
                    ])
                ]),
                "additionalProperties": .bool(false)
            ]),
            annotations: .init(title: "录制屏幕", readOnlyHint: false, openWorldHint: false)
        )
    }

    // MARK: - 工具调用

    private static func registerCallTool(
        on server: Server,
        logger: Logger
    ) async {
        await server.withMethodHandler(CallTool.self) { params in
            switch params.name {
            case "list_displays":
                return handleListDisplays()

            case "list_desktops":
                return handleListDesktops()

            case "list_windows":
                return await handleListWindows(logger: logger)

            case "capture_screenshot":
                return await handleCaptureScreenshot(
                    arguments: params.arguments,
                    logger: logger
                )

            case "ocr_screenshot":
                return await handleOCRScreenshot(
                    arguments: params.arguments,
                    logger: logger
                )

            case "inspect_window_elements":
                return await handleInspectWindowElements(
                    arguments: params.arguments,
                    logger: logger
                )

            case "record_screen":
                return await handleRecordScreen(
                    arguments: params.arguments,
                    logger: logger
                )

            default:
                return errorResult(
                    "未知工具：\(params.name)。"
                    + "可用工具：list_displays、list_desktops、list_windows、capture_screenshot、"
                    + "ocr_screenshot、inspect_window_elements、record_screen。"
                )
            }
        }
    }

    private static func handleListWindows(logger: Logger) async -> CallTool.Result {
        let windows: [WindowInfo]
        do {
            if let appURL = OutOfProcessCapture.currentAppURL {
                windows = try await OutOfProcessCapture.listWindows(appURL: appURL)
            } else {
                logger.notice("list_windows: running outside an app bundle; titles may be unavailable")
                windows = WindowCatalog.all()
            }
        } catch let error as AutomationError {
            logger.warning("list_windows failed: \(error.localizedDescription)")
            return errorResult(error.localizedDescription)
        } catch {
            logger.error("list_windows failed unexpectedly: \(String(describing: error))")
            return errorResult("枚举窗口失败：\(error.localizedDescription)")
        }

        return structuredJSONResult(WindowsPayload(windows: windows), failureMessage: "窗口列表序列化失败。")
    }

    private static func handleListDisplays() -> CallTool.Result {
        structuredJSONResult(DisplaysPayload(displays: DisplayCatalog.all()), failureMessage: "显示器列表序列化失败。")
    }

    private static func handleListDesktops() -> CallTool.Result {
        do {
            return structuredJSONResult(
                DesktopsPayload(desktops: try DesktopCatalog.all()),
                failureMessage: "桌面列表序列化失败。"
            )
        } catch {
            return errorResult("枚举桌面失败：\(error.localizedDescription)")
        }
    }

    private static func handleCaptureScreenshot(
        arguments: [String: Value]?,
        logger: Logger
    ) async -> CallTool.Result {
        let parameters: CaptureParameters
        do {
            parameters = try parse(arguments: arguments)
        } catch let error as AutomationError {
            return errorResult(error.localizedDescription)
        } catch {
            return errorResult("参数解析失败：\(error.localizedDescription)")
        }

        do {
            var captureOnly = parameters
            captureOnly.savePath = nil
            var outcome = try await CaptureRunner.run(
                parameters: captureOnly,
                execution: .reuseApplicationAuthorization
            )

            try MCPPayloadLimits.validate(
                byteCount: outcome.imageData.count,
                format: outcome.imageFormat
            )

            if let savePath = parameters.savePath, !savePath.isEmpty {
                outcome = outcome.withSavedURL(
                    try CaptureService.save(outcome.imageData, to: savePath)
                )
            }

            let base64 = outcome.imageData.base64EncodedString()
            return CallTool.Result(
                content: [
                    .image(
                        data: base64,
                        mimeType: outcome.mimeType,
                        annotations: nil,
                        _meta: nil
                    ),
                    .text(
                        text: metadataText(for: outcome),
                        annotations: nil,
                        _meta: nil
                    )
                ],
                isError: false
            )
        } catch let error as AutomationError {
            logger.warning("capture failed: \(error.localizedDescription)")
            return errorResult(error.localizedDescription)
        } catch {
            logger.error("capture failed unexpectedly: \(String(describing: error))")
            return errorResult("截图失败：\(error.localizedDescription)")
        }
    }

    private static func handleOCRScreenshot(
        arguments: [String: Value]?,
        logger: Logger
    ) async -> CallTool.Result {
        let parameters: OCRParameters
        do {
            parameters = try parseOCR(arguments: arguments)
        } catch let error as AutomationError {
            return errorResult(error.localizedDescription)
        } catch {
            return errorResult("参数解析失败：\(error.localizedDescription)")
        }

        do {
            let result = try await AutomationOCRService.recognize(
                parameters,
                execution: .reuseApplicationAuthorization
            )
            return structuredJSONResult(result, failureMessage: "OCR 结果序列化失败。")
        } catch let error as AutomationError {
            logger.warning("ocr_screenshot failed: \(error.localizedDescription)")
            return errorResult(error.localizedDescription)
        } catch {
            logger.error("ocr_screenshot failed unexpectedly: \(String(describing: error))")
            return errorResult("离线文字识别失败：\(error.localizedDescription)")
        }
    }

    private static func handleInspectWindowElements(
        arguments: [String: Value]?,
        logger: Logger
    ) async -> CallTool.Result {
        let parameters: InspectElementsParameters
        do {
            parameters = try parseInspectElements(arguments: arguments)
        } catch let error as AutomationError {
            return errorResult(error.localizedDescription)
        } catch {
            return errorResult("参数解析失败：\(error.localizedDescription)")
        }

        do {
            let result = try await AccessibilityInspector.inspect(
                parameters,
                execution: .reuseApplicationAuthorization
            )
            return structuredJSONResult(result, failureMessage: "控件树结果序列化失败。")
        } catch let error as AutomationError {
            logger.warning("inspect_window_elements failed: \(error.localizedDescription)")
            return errorResult(error.localizedDescription)
        } catch {
            logger.error("inspect_window_elements failed unexpectedly: \(String(describing: error))")
            return errorResult("探测控件树失败：\(error.localizedDescription)")
        }
    }

    private static func handleRecordScreen(
        arguments: [String: Value]?,
        logger: Logger
    ) async -> CallTool.Result {
        let parameters: RecordingParameters
        do {
            parameters = try parseRecord(arguments: arguments)
        } catch let error as AutomationError {
            return errorResult(error.localizedDescription)
        } catch {
            return errorResult("参数解析失败：\(error.localizedDescription)")
        }

        do {
            let result = try await RecordingService.record(
                parameters,
                execution: .reuseApplicationAuthorization
            )
            return structuredJSONResult(result, failureMessage: "录制结果序列化失败。")
        } catch let error as AutomationError {
            logger.warning("record_screen failed: \(error.localizedDescription)")
            return errorResult(error.localizedDescription)
        } catch {
            logger.error("record_screen failed unexpectedly: \(String(describing: error))")
            return errorResult("屏幕录制失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 参数解析（internal 便于单元测试直接覆盖）

    /// 把 `capture_screenshot` MCP 参数解析为共享请求模型。
    static func parse(
        arguments: [String: Value]?
    ) throws -> CaptureParameters {
        let arguments = arguments ?? [:]

        let allowedKeys: Set<String> = [
            "window_id", "app", "display_id", "space_id", "allow_switch",
            "region", "max_size", "format", "quality", "coordinate_grid", "save_path"
        ]
        try rejectUnknownArguments(in: arguments, allowedKeys: allowedKeys)

        var parameters = CaptureParameters(
            maxLongEdge: MCPPayloadLimits.defaultMaxLongEdge,
            autoFallbackToJPEG: true
        )

        if let raw = arguments["window_id"] {
            parameters.windowID = try parseWindowID(raw)
        }
        if let raw = arguments["app"] {
            parameters.applicationName = try parseString(raw, name: "app")
        }
        if let raw = arguments["display_id"] {
            parameters.displayID = try parseDisplayID(raw)
        }
        if let raw = arguments["space_id"] {
            parameters.spaceID = try parseSpaceID(raw)
        }
        if let raw = arguments["allow_switch"] {
            parameters.allowDesktopSwitch = try parseBool(raw, name: "allow_switch")
        }
        if let raw = arguments["region"] {
            parameters.region = try parseRegion(raw)
        }
        if let raw = arguments["max_size"] {
            guard let value = raw.intValue else {
                throw AutomationError.invalidArgument("max_size 必须是整数，收到 \(raw)。")
            }
            parameters.maxLongEdge = value
        }
        if let raw = arguments["format"] {
            let rawString = try parseString(raw, name: "format").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let format = CaptureImageFormat(rawValue: rawString) else {
                throw AutomationError.invalidArgument("format 仅支持 \"png\" 或 \"jpeg\"，收到「\(rawString)」。")
            }
            parameters.outputFormat = format
            parameters.autoFallbackToJPEG = (format != .png)
        }
        if let raw = arguments["quality"] {
            guard let value = raw.intValue else {
                throw AutomationError.invalidArgument("quality 必须是整数（1...100），收到 \(raw)。")
            }
            parameters.jpegQuality = value
        }
        if let raw = arguments["coordinate_grid"] {
            parameters.coordinateGrid = try parseBool(raw, name: "coordinate_grid")
        }
        if let raw = arguments["save_path"] {
            parameters.savePath = try parseString(raw, name: "save_path")
        }

        // 入口即做数值边界与格式互斥校验（如 quality 1...100、png+quality 冲突）。
        if let quality = parameters.jpegQuality {
            guard (1...100).contains(quality) else {
                throw AutomationError.invalidArgument("quality 必须在 1 到 100 之间（收到 \(quality)）。")
            }
            if parameters.outputFormat == .png {
                throw AutomationError.invalidArgument("quality 仅适用于 jpeg 格式，不能与 format: \"png\" 同时使用。")
            }
        }
        if let maxSize = parameters.maxLongEdge {
            guard maxSize >= 0 else {
                throw AutomationError.invalidArgument("max_size 不能为负：\(maxSize)。")
            }
            guard maxSize <= CaptureParameters.maximumLongEdge else {
                throw AutomationError.invalidArgument(
                    "max_size 过大：\(maxSize)（上限 \(CaptureParameters.maximumLongEdge)）。"
                )
            }
        }

        return parameters
    }

    /// 解析 `ocr_screenshot` 参数。
    static func parseOCR(arguments: [String: Value]?) throws -> OCRParameters {
        let arguments = arguments ?? [:]
        let allowedKeys: Set<String> = [
            "image_path", "window_id", "app", "display_id", "space_id", "allow_switch", "region", "languages"
        ]
        try rejectUnknownArguments(in: arguments, allowedKeys: allowedKeys)

        var parameters = OCRParameters()
        if let raw = arguments["image_path"] {
            parameters.imagePath = try parseString(raw, name: "image_path")
        }
        if let raw = arguments["window_id"] {
            parameters.windowID = try parseWindowID(raw)
        }
        if let raw = arguments["app"] {
            parameters.applicationName = try parseString(raw, name: "app")
        }
        if let raw = arguments["display_id"] {
            parameters.displayID = try parseDisplayID(raw)
        }
        if let raw = arguments["space_id"] {
            parameters.spaceID = try parseSpaceID(raw)
        }
        if let raw = arguments["allow_switch"] {
            parameters.allowDesktopSwitch = try parseBool(raw, name: "allow_switch")
        }
        if let raw = arguments["region"] {
            parameters.region = try parseRegion(raw)
        }
        if let raw = arguments["languages"] {
            guard let items = raw.arrayValue else {
                throw AutomationError.invalidArgument("languages 必须是字符串数组。")
            }
            parameters.languages = try items.map { item in
                guard let s = item.stringValue else {
                    throw AutomationError.invalidArgument("languages 的元素必须是字符串，收到 \(item)。")
                }
                return s
            }
        }

        // 入口提前校验与 image_path 的互斥性。
        if let imagePath = parameters.imagePath {
            if imagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AutomationError.invalidArgument("image_path 不能为空字符串。")
            }
            if parameters.displayID != nil || parameters.spaceID != nil
                || parameters.allowDesktopSwitch || parameters.region != nil
                || parameters.windowID != nil || parameters.applicationName != nil {
                throw AutomationError.invalidArgument(
                    "image_path 与截屏目标参数（display_id / space_id / allow_switch / region / window_id / app）不能同时使用。"
                )
            }
        }
        return parameters
    }

    /// 解析 `inspect_window_elements` 参数。
    static func parseInspectElements(arguments: [String: Value]?) throws -> InspectElementsParameters {
        let arguments = arguments ?? [:]
        let allowedKeys: Set<String> = ["window_id", "app", "pid", "max_depth", "max_elements"]
        try rejectUnknownArguments(in: arguments, allowedKeys: allowedKeys)

        var parameters = InspectElementsParameters()
        if let raw = arguments["window_id"] {
            parameters.windowID = try parseWindowID(raw)
        }
        if let raw = arguments["app"] {
            parameters.applicationName = try parseString(raw, name: "app")
        }
        if let raw = arguments["pid"] {
            guard let value = raw.intValue, value > 0, value <= Int(Int32.max) else {
                throw AutomationError.invalidArgument("pid 必须是大于 0 的整数，收到 \(raw)。")
            }
            parameters.pid = Int32(value)
        }
        if let raw = arguments["max_depth"] {
            guard let value = raw.intValue else {
                throw AutomationError.invalidArgument("max_depth 必须是整数，收到 \(raw)。")
            }
            parameters.maxDepth = value
        }
        if let raw = arguments["max_elements"] {
            guard let value = raw.intValue else {
                throw AutomationError.invalidArgument("max_elements 必须是整数，收到 \(raw)。")
            }
            parameters.maxElements = value
        }

        try parameters.validate()
        return parameters
    }

    /// 解析 `record_screen` 参数。
    static func parseRecord(arguments: [String: Value]?) throws -> RecordingParameters {
        let arguments = arguments ?? [:]
        let allowedKeys: Set<String> = [
            "window_id", "app", "display_id", "region", "duration", "format", "fps", "max_size", "save_path"
        ]
        try rejectUnknownArguments(in: arguments, allowedKeys: allowedKeys)

        var parameters = RecordingParameters()
        if let raw = arguments["window_id"] {
            parameters.windowID = try parseWindowID(raw)
        }
        if let raw = arguments["app"] {
            parameters.applicationName = try parseString(raw, name: "app")
        }
        if let raw = arguments["display_id"] {
            parameters.displayID = try parseDisplayID(raw)
        }
        if let raw = arguments["region"] {
            parameters.region = try parseRegion(raw)
        }
        if let raw = arguments["duration"] {
            if let d = raw.doubleValue {
                parameters.durationSeconds = d
            } else if let i = raw.intValue {
                parameters.durationSeconds = Double(i)
            } else {
                throw AutomationError.invalidArgument("duration 必须是数字（1...15 秒），收到 \(raw)。")
            }
        }
        if let raw = arguments["format"] {
            let rawString = try parseString(raw, name: "format").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let format = RecordingOutputFormat(rawValue: rawString) else {
                throw AutomationError.invalidArgument("record_screen 的 format 仅支持 \"gif\" 或 \"mp4\"，收到「\(rawString)」。")
            }
            parameters.format = format
        }
        if let raw = arguments["fps"] {
            guard let value = raw.intValue else {
                throw AutomationError.invalidArgument("fps 必须是整数，收到 \(raw)。")
            }
            parameters.fps = value
        }
        if let raw = arguments["max_size"] {
            guard let value = raw.intValue else {
                throw AutomationError.invalidArgument("max_size 必须是整数，收到 \(raw)。")
            }
            parameters.maxDimension = value
        }
        if let raw = arguments["save_path"] {
            parameters.savePath = try parseString(raw, name: "save_path")
        }

        // 先做边界与格式组合校验，确保无效时长/fps/max_size 在 parse 阶段即拦截。
        guard parameters.durationSeconds.isFinite,
              parameters.durationSeconds >= RecordingParameters.minimumDurationSeconds,
              parameters.durationSeconds <= RecordingParameters.maximumDurationSeconds else {
            throw AutomationError.invalidArgument(
                "duration 必须在 \(Int(RecordingParameters.minimumDurationSeconds)) 到 "
                + "\(Int(RecordingParameters.maximumDurationSeconds)) 秒之间（收到 \(parameters.durationSeconds)）。"
            )
        }
        if let fps = parameters.fps {
            let maxFPS = parameters.format == .gif ? 30 : 60
            guard (1...maxFPS).contains(fps) else {
                throw AutomationError.invalidArgument("\(parameters.format.rawValue) 模式下 fps 必须在 1 到 \(maxFPS) 之间（收到 \(fps)）。")
            }
        }
        if let maxDimension = parameters.maxDimension {
            guard parameters.format == .gif else {
                throw AutomationError.invalidArgument("max_size 仅在 format: \"gif\" 时支持（MP4 请勿传入 max_size）。")
            }
            guard (100...1600).contains(maxDimension) else {
                throw AutomationError.invalidArgument("GIF max_size 必须在 100 到 1600 之间（收到 \(maxDimension)）。")
            }
        }
        return parameters
    }

    // MARK: - 解析辅助

    private static func rejectUnknownArguments(
        in arguments: [String: Value],
        allowedKeys: Set<String>
    ) throws {
        let unknown = Set(arguments.keys).subtracting(allowedKeys)
        guard unknown.isEmpty else {
            throw AutomationError.invalidArgument(
                "未知参数：\(unknown.sorted().joined(separator: "、"))。"
                + "可用参数：\(allowedKeys.sorted().joined(separator: "、"))。"
            )
        }
    }

    private static func parseWindowID(_ raw: Value) throws -> CGWindowID {
        guard let value = raw.intValue else {
            throw AutomationError.invalidArgument("window_id 必须是整数，收到 \(raw)。")
        }
        guard value >= 0, value <= Int(UInt32.max) else {
            throw AutomationError.invalidArgument("window_id 超出有效范围：\(value)。")
        }
        return CGWindowID(UInt32(value))
    }

    private static func parseDisplayID(_ raw: Value) throws -> CGDirectDisplayID {
        guard let value = raw.intValue else {
            throw AutomationError.invalidArgument("display_id 必须是整数，收到 \(raw)。")
        }
        guard value >= 0, value <= Int(UInt32.max) else {
            throw AutomationError.invalidArgument("display_id 超出有效范围：\(value)。")
        }
        return CGDirectDisplayID(UInt32(value))
    }

    private static func parseSpaceID(_ raw: Value) throws -> UInt64 {
        guard let value = raw.intValue, value > 0 else {
            throw AutomationError.invalidArgument("space_id 必须是大于 0 的整数。")
        }
        return UInt64(value)
    }

    private static func parseString(_ raw: Value, name: String) throws -> String {
        guard let value = raw.stringValue else {
            throw AutomationError.invalidArgument("\(name) 必须是字符串。")
        }
        return value
    }

    private static func parseBool(_ raw: Value, name: String) throws -> Bool {
        guard let value = raw.boolValue else {
            throw AutomationError.invalidArgument("\(name) 必须是布尔值。")
        }
        return value
    }

    private static func parseRegion(_ raw: Value) throws -> CGRect {
        guard let items = raw.arrayValue else {
            throw AutomationError.invalidArgument(
                "region 必须是数组 [x, y, width, height]。"
            )
        }
        guard items.count == 4 else {
            throw AutomationError.invalidArgument(
                "region 需要恰好 4 个数字 [x, y, width, height]，收到 \(items.count) 个。"
            )
        }

        let numbers = try items.map { item -> CGFloat in
            if let value = item.doubleValue { return CGFloat(value) }
            if let value = item.intValue { return CGFloat(value) }
            throw AutomationError.invalidArgument(
                "region 的元素必须都是数字，收到 \(item)。"
            )
        }

        return CGRect(
            x: numbers[0],
            y: numbers[1],
            width: numbers[2],
            height: numbers[3]
        )
    }

    // MARK: - 结果构造

    /// 生成附在图像之后的文本元数据（internal 便于单测校验格式与尺寸透明说明）。
    static func metadataText(for outcome: CaptureOutcome) -> String {
        let source = outcome.sourcePixelSize
        let output = outcome.pixelSize
        let scaled = source != output

        var lines: [String] = []

        if let window = outcome.window {
            let name = window.title ?? window.applicationName ?? "未命名窗口"
            lines.append("已捕获窗口 #\(window.windowID)「\(name)」")
            if let app = window.applicationName, window.title != nil {
                lines.append("所属应用：\(app)")
            }
            lines.append(
                "窗口位置：x=\(Int(window.frame.origin.x)), y=\(Int(window.frame.origin.y)), "
                + "宽=\(Int(window.frame.width)), 高=\(Int(window.frame.height))（全局逻辑点，"
                + "原点主屏左上）"
            )
            if window.isOnScreen == false {
                lines.append("窗口不在当前可见桌面；内容可能过期、为空，或来自最小化/隐藏窗口。")
            }
        } else {
            lines.append("已捕获显示器 #\(outcome.displayID)")
        }

        if let spaceID = outcome.spaceID {
            lines.append("目标桌面 ID：\(spaceID)（已完成恢复检查）")
        }

        lines.append("输出尺寸：\(Int(output.width))×\(Int(output.height)) 像素")

        let byteText = formattedByteCount(outcome.imageData.count)
        switch outcome.imageFormat {
        case .png:
            lines.append("编码格式：PNG（\(byteText)）")
        case .jpeg:
            let quality = outcome.jpegQuality ?? MCPPayloadLimits.autoJPEGQuality
            if outcome.didAutoFallbackToJPEG, let origBytes = outcome.originalPNGByteCount {
                lines.append(
                    "编码格式：JPEG（quality=\(quality)，\(byteText)；"
                    + "原 PNG \(formattedByteCount(origBytes)) 超过 3.5 MiB 阈值已自动降级）"
                )
            } else {
                lines.append("编码格式：JPEG（quality=\(quality)，\(byteText)）")
            }
        }

        if scaled {
            let percent = source.width > 0
                ? Int((output.width / source.width * 100).rounded())
                : 100
            lines.append(
                "原始尺寸：\(Int(source.width))×\(Int(source.height)) 像素"
                + "（已缩放到 \(percent)%，如需原始分辨率请传 max_size: 0）"
            )
        }

        if let region = outcome.region {
            lines.append(
                "采样区域：x=\(Int(region.origin.x)), y=\(Int(region.origin.y)), "
                + "宽=\(Int(region.width)), 高=\(Int(region.height))（显示器内逻辑点）"
            )
        } else if outcome.window == nil {
            lines.append("采样区域：整块显示器")
        }

        if outcome.coordinateGridEnabled, let origin = outcome.coordinateGridOrigin {
            lines.append(
                "坐标网格：已启用（标尺刻度单位为逻辑点，左上角原点=(\(Int(origin.x.rounded())), \(Int(origin.y.rounded())))）"
            )
        }

        lines.append("显示器缩放系数：\(outcome.scaleFactor)")

        if let saved = outcome.savedURL {
            lines.append("已另存为：\(saved.path)")
        }

        return lines.joined(separator: "\n")
    }

    private static func formattedByteCount(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.2f MiB", Double(bytes) / 1024.0 / 1024.0)
        }
        return String(format: "%.1f KiB", Double(bytes) / 1024.0)
    }

    private static func structuredJSONResult<T: Codable>(
        _ payload: T,
        failureMessage: String
    ) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return errorResult(failureMessage)
        }
        return CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: try? Value(payload),
            isError: false
        )
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

/// `list_displays` 的结构化返回。
private struct DisplaysPayload: Codable {
    let displays: [DisplayInfo]
}

private struct DesktopsPayload: Codable {
    let desktops: [DesktopInfo]
}

/// `list_windows` 的结构化返回。
private struct WindowsPayload: Codable {
    let windows: [WindowInfo]
}
