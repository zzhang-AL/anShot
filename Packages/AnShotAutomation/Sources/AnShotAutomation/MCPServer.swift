//
//  MCPServer.swift
//  AnShotAutomation
//
//  MCP stdio 服务端。让 AI 客户端（Claude Code / Cursor / pi 等）能直接截图。
//
//  ── 传输选型：stdio ──────────────────────────────────────────
//
//  MCP 规范定义 stdio 与 streamable HTTP 两种传输。这里选 stdio，理由是
//  使用场景本身决定的：截图是**本机能力**，调用方与本进程在同一台机器上，
//  stdio 由客户端直接 spawn 子进程，不需要监听端口、不需要鉴权、
//  也不存在「谁会连上这个端口」的问题。HTTP 传输的价值在跨网络共享，
//  而这恰好是这里不需要的。
//
//  ── stdout 是协议通道，不是日志通道 ──────────────────────────
//
//  stdio 传输把 stdout 当作 JSON-RPC 消息流（换行分隔）。
//  任何一行非协议输出都会让客户端解析失败，且症状通常是
//  「客户端连上了但一个工具都没有」——排查方向完全被误导。
//
//  因此本文件遵守一条硬规则：
//      - 协议消息 → stdout（只由 StdioTransport 写）
//      - 一切日志 → stderr
//  这也是给 `StdioTransport` 显式传 logger 的原因：它的默认 logger
//  是 NoOp（丢弃），显式传入既避免污染又保留可调试性。
//

import AnShotCapture
import CoreGraphics
import Foundation
import Logging
import MCP

/// 构建信息。用于在 MCP 握手时声明服务端版本。
enum AnShotBuildInfo {

    /// 对外声明的版本号。取 app bundle 的 `CFBundleShortVersionString`。
    ///
    /// 取不到时返回 `"unknown"` 而非崩溃：版本号只用于诊断，
    /// 不该成为截图能力可用的前提。
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "unknown"
    }
}

/// MCP 服务端入口。
public enum AnShotMCP {

    /// 服务端在 `initialize` 时返回给客户端的用法说明。
    ///
    /// 这段文字会进入模型的上下文，因此写得**可操作**：
    /// 说清坐标系单位、以及无权限时该做什么。少这两条，
    /// 模型最常见的两个错误就是「坐标传成像素」和「无权限时反复重试」。
    private static let instructions = """
    anShot 的 macOS 屏幕捕获能力。三个工具配合使用：

    - list_displays  看有哪些屏幕（id / 逻辑尺寸 / 像素尺寸 / 缩放系数）
    - list_windows   看有哪些可截图的窗口（应用名 / 标题 / window_id）
    - capture_screenshot  截图

    截图的三种取景方式（互斥，按优先级排）：
    1. window_id 或 app —— 截指定窗口。**窗口被遮挡、不在最顶层时同样能截到
       完整内容**，所以「看一眼某个应用/某个窗口」优先用它，而不是去猜坐标。
    2. display_id + region —— 截某块屏幕的一块区域，单位是**显示器内逻辑点**
       （不是像素，也不是全局坐标），原点在该显示器左上角。
    3. 都不传 —— 截主显示器整屏。

    挑选窗口时以 title 为主要依据；title 为空表示该窗口本就没有标题，
    此时用 appName 判断。app 参数接受应用名（如 "Safari"、"Xcode"），
    会选中该应用在屏且面积最大的窗口。

    输出尺寸默认把长边压到 2560 像素以内以控制体积，用 max_size 覆盖
    （传 0 表示保持原分辨率——做像素计数类判断时必须这样传）。

    若无权限，工具会返回明确的处理步骤。授权对象是 **anShot.app 自身**，
    不是你的宿主进程；不要建议用户给终端或客户端授予屏幕录制权限。
    """

    /// 在 stdio 上运行服务端，直到 stdin 关闭。
    ///
    /// - Throws: 传输建立失败时抛出。
    public static func run() async throws {
        let logger = makeLogger()

        let server = Server(
            name: "anshot",
            version: AnShotBuildInfo.version,
            title: "anShot Screen Capture",
            instructions: instructions,
            capabilities: .init(
                // listChanged 为 false：工具集是编译期固定的，
                // 声明 true 却从不发通知属于虚假声明。
                tools: .init(listChanged: false)
            )
        )

        await registerListTools(on: server, logger: logger)
        await registerCallTool(on: server, logger: logger)

        let transport = StdioTransport(logger: logger)
        try await server.start(transport: transport)
        logger.notice("anshot MCP server started; awaiting stdio")

        // 阻塞到 stdin EOF（客户端关闭管道）或对端断开。
        // 用 waitUntilCompleted 而非 `Task.sleep(for: .days(365*100))`：
        // 后者在客户端异常退出时会让进程一直挂着，成为孤儿进程。
        await server.waitUntilCompleted()
        await server.stop()
        logger.notice("anshot MCP server stopped")
    }

    /// stderr 日志器。
    ///
    /// 级别由 `ANSHOT_MCP_LOG` 环境变量控制（trace/debug/info/notice/warning/error），
    /// 默认 `notice`。默认不开 debug 是因为 MCP 客户端会把 stderr
    /// 原样转给用户，逐条消息的 trace 日志会淹没真正重要的信息。
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
            .init(tools: [listDisplaysTool, listDesktopsTool, listWindowsTool, captureScreenshotTool])
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

            用其中的 id 作为 capture_screenshot 的 window_id，或把 appName
            作为该工具的 app 参数。

            注意 title 可能为空：那表示该窗口本就没有标题（不少应用的主窗口
            就是如此），此时按 appName 与 frame 判断即可，不要因此认为
            列表不可用。

            isOnScreen 为 false 可能表示窗口在其他桌面、已最小化或隐藏，
            并不保证系统能捕获；后台窗口的内容也可能过期或为空。
            用 list_desktops 把 spaceIDs 对应到桌面；spaceIDs 可能缺失，表示系统未提供归属。
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
               **窗口被遮挡、不在最顶层时同样能截到完整内容**：
               这是「看一眼某个应用现在长什么样」的首选方式，
               不需要知道窗口在哪，也不需要把它切到前台。
               其他桌面的窗口也会尝试捕获；最小化、隐藏或后台窗口的内容
               可能不可用、过期或为空。app 优先选当前在屏窗口，其次面积最大。
               不要为了截图先调用 activate、设置 frontmost、执行 AXRaise 或其他窗口置前操作；
               截不到时应说明限制，不能擅自激活应用或切换桌面。
               如果其他界面交互需要将窗口切到前台，应先取得用户明确同意。

            2. 区域 —— 传 display_id + region。
               region 是 **显示器内逻辑点**（不是像素、不是全局坐标），
               原点在该显示器左上角，格式 [x, y, width, height]。

            3. 整屏 —— 传 display_id，省略时为主显示器。
               可传 space_id 指定桌面。默认不切换；只有用户明确同意后，才能传入
               allow_switch: true 短暂切换并恢复原桌面，且需要辅助功能权限。
               先用 list_desktops 获取 ID。
               优先按窗口后台截图；需要其他桌面的完整画面时才使用切换模式。

            window_id/app 不能与 display_id、space_id 或 region 同时使用。

            其他参数：
            - max_size：输出长边像素上限，默认 2560；传 0 表示不缩放。
              做像素计数类判断（「这个按钮宽 400 像素吗」）必须传 0。
            - save_path：把截图另存到该路径（已存在时自动追加序号，不覆盖）。

            截图由 anShot.app 自己完成，复用它已有的屏幕录制授权。因此**不需要**
            给你的终端或 AI 客户端授予屏幕录制权限；若返回权限错误，
            那是 anShot 自身未被授权，请把错误原文转达给用户。
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "window_id": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "目标窗口 ID，来自 list_windows 的 id。可尝试其他桌面的窗口。"
                        )
                    ]),
                    "app": .object([
                        "type": .string("string"),
                        "description": .string(
                            "应用名（如 Safari、Xcode），优先当前在屏窗口，其次面积最大。"
                            + "与 window_id 二选一。"
                        )
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
                        "description": .string(
                            "显示器内逻辑点区域 [x, y, width, height]，原点该显示器左上角。省略则整屏。"
                        ),
                        "items": .object(["type": .string("number")]),
                        "minItems": .int(4),
                        "maxItems": .int(4)
                    ]),
                    "max_size": .object([
                        "type": .string("integer"),
                        "description": .string("输出长边像素上限，默认 2560；0 表示不缩放。"),
                        "minimum": .int(0)
                    ]),
                    "save_path": .object([
                        "type": .string("string"),
                        "description": .string("另存路径（可选）。已存在时自动追加序号，不会覆盖。")
                    ])
                ]),
                "additionalProperties": .bool(false)
            ]),
            // readOnlyHint 必须为 false：本工具可经 `save_path` 写文件。
            //
            // 曾错误地声明为 true。按 MCP 规范，readOnlyHint 的含义是
            // 「不修改其环境」；一个能写盘的工具声称自己只读，会让
            // 客户端在只读会话里放行它——而调用方是靠这个字段做安全判断的。
            // （schema 里 `additionalProperties: false` 只能约束入参形状，
            // 不能表达「会写盘」这件事。）
            annotations: .init(title: "截取屏幕", readOnlyHint: false, openWorldHint: false)
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

            default:
                return errorResult(
                    "未知工具：\(params.name)。"
                    + "可用工具：list_displays、list_desktops、list_windows、capture_screenshot。"
                )
            }
        }
    }

    /// 枚举窗口。
    ///
    /// 走 app 内执行的理由见 `OutOfProcessCapture.listWindows`：窗口标题
    /// 受屏幕录制权限管控，而 MCP 服务器是被宿主 spawn 的，自己没有这个身份。
    /// 就地枚举会得到一列「有应用名、没标题」的窗口，调用方据此挑窗口只能靠猜。
    private static func handleListWindows(logger: Logger) async -> CallTool.Result {
        let windows: [WindowInfo]
        do {
            if let appURL = OutOfProcessCapture.currentAppURL {
                windows = try await OutOfProcessCapture.listWindows(appURL: appURL)
            } else {
                // 不在 .app 内（单测、裸二进制）：退回就地枚举，至少给出应用名。
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

        let payload = WindowsPayload(windows: windows)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return errorResult("窗口列表序列化失败。")
        }

        return CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: try? Value(payload),
            isError: false
        )
    }

    private static func handleListDisplays() -> CallTool.Result {
        let displays = DisplayCatalog.all()
        let payload = DisplaysPayload(displays: displays)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return errorResult("显示器列表序列化失败。")
        }

        return CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: try? Value(payload),
            isError: false
        )
    }

    private static func handleListDesktops() -> CallTool.Result {
        do {
            let payload = DesktopsPayload(desktops: try DesktopCatalog.all())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(payload)
            guard let json = String(data: data, encoding: .utf8) else {
                return errorResult("桌面列表序列化失败。")
            }
            return CallTool.Result(
                content: [.text(text: json, annotations: nil, _meta: nil)],
                structuredContent: try? Value(payload),
                isError: false
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
            // 恒走「让 anShot.app 自己截」，不复用宿主进程的授权。
            //
            // stdio MCP 服务器**总是**被宿主 spawn 的，因此永远没有自己的
            // TCC 身份。就地截图会把授权要求推给宿主——用户得给终端或 AI 客户端
            // 单独开一次录屏权限，而 anShot 已经有这个权限了。给终端录屏权限
            // 比复用一个已知 app 的既有授权更危险，所以这里不提供开关。
            //
            // 落盘推迟到体量检查之后：先截图不落盘，过了检查再按 save_path 保存。
            // 否则超限时文件已经写下，返回的却是一条不带路径的错误——
            // 调用方既拿不到图，也不知道磁盘上多了一个文件。
            var captureOnly = parameters
            captureOnly.savePath = nil
            var outcome = try await CaptureRunner.run(
                parameters: captureOnly,
                execution: .reuseApplicationAuthorization
            )

            // 体量检查必须在**编码进响应之前**：同一条 JSON-RPC 消息
            // 若大到让对端卡死，再好的错误信息也传不出去了。
            try MCPPayloadLimits.validate(pngByteCount: outcome.pngData.count)

            if let savePath = parameters.savePath, !savePath.isEmpty {
                outcome = outcome.withSavedURL(
                    try CaptureService.save(outcome.pngData, to: savePath)
                )
            }

            let base64 = outcome.pngData.base64EncodedString()
            return CallTool.Result(
                content: [
                    .image(
                        data: base64,
                        mimeType: "image/png",
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
            // 工具级错误用 isError 返回而非抛 JSON-RPC 错误：
            // 前者会把可读文案交给模型，后者在许多客户端只表现为「工具失败」。
            logger.warning("capture failed: \(error.localizedDescription)")
            return errorResult(error.localizedDescription)
        } catch {
            logger.error("capture failed unexpectedly: \(String(describing: error))")
            return errorResult("截图失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 参数解析

    /// 把 MCP 参数解析为共享的请求模型。
    ///
    /// ── 为何这里只做「形状」检查，不做值域检查 ─────────────────
    ///
    /// 值域（区域是否越界、`max_size` 是否非负、坐标是否有限）
    /// **一律交给 `CaptureParameters.validate()`**。两侧入口共用同一套规则，
    /// 才能避免「MCP 能过而 CLI 过不了」这类分歧。
    ///
    /// ── 为何要显式拒绝未知参数 ──────────────────────────────────
    ///
    /// schema 里的 `additionalProperties: false` 只是给客户端的**提示**，
    /// 服务端不会因此自动拒绝。这里显式拦掉：一个拼错的参数名
    /// （`maxsize`）若被静默忽略，调用方会得到一张默认尺寸的图，
    /// 却以为自己的限制生效了。
    private static func parse(
        arguments: [String: Value]?
    ) throws -> CaptureParameters {
        let arguments = arguments ?? [:]

        let allowedKeys: Set<String> = [
            "window_id", "app", "display_id", "space_id", "allow_switch", "region", "max_size", "save_path"
        ]
        let unknown = Set(arguments.keys).subtracting(allowedKeys)
        guard unknown.isEmpty else {
            throw AutomationError.invalidArgument(
                "未知参数：\(unknown.sorted().joined(separator: "、"))。"
                + "可用参数：\(allowedKeys.sorted().joined(separator: "、"))。"
            )
        }

        var parameters = CaptureParameters()

        if let raw = arguments["window_id"] {
            guard let value = raw.intValue else {
                throw AutomationError.invalidArgument("window_id 必须是整数，收到 \(raw)。")
            }
            guard value >= 0, value <= Int(UInt32.max) else {
                throw AutomationError.invalidArgument("window_id 超出有效范围：\(value)。")
            }
            parameters.windowID = CGWindowID(UInt32(value))
        }

        if let raw = arguments["app"] {
            guard let value = raw.stringValue else {
                throw AutomationError.invalidArgument("app 必须是字符串（应用名）。")
            }
            parameters.applicationName = value
        }

        if let raw = arguments["display_id"] {
            guard let value = raw.intValue else {
                throw AutomationError.invalidArgument("display_id 必须是整数，收到 \(raw)。")
            }
            guard value >= 0, value <= Int(UInt32.max) else {
                throw AutomationError.invalidArgument("display_id 超出有效范围：\(value)。")
            }
            parameters.displayID = CGDirectDisplayID(UInt32(value))
        }

        if let raw = arguments["space_id"] {
            guard let value = raw.intValue, value > 0 else {
                throw AutomationError.invalidArgument("space_id 必须是大于 0 的整数。")
            }
            parameters.spaceID = UInt64(value)
        }

        if let raw = arguments["allow_switch"] {
            guard let value = raw.boolValue else {
                throw AutomationError.invalidArgument("allow_switch 必须是布尔值。")
            }
            parameters.allowDesktopSwitch = value
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

        if let raw = arguments["save_path"] {
            guard let value = raw.stringValue else {
                throw AutomationError.invalidArgument("save_path 必须是字符串。")
            }
            parameters.savePath = value
        }

        return parameters
    }

    /// 解析 `[x, y, width, height]`。
    ///
    /// 同时接受整数与浮点：JSON 里 `600` 会被解成 `.int(600)`，
    /// 而 `600.0` 是 `.double`，两者语义相同，不该一个能用一个报错。
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

    /// 附在图像之后的元数据。
    ///
    /// 之所以要它：模型看到图像后常需要知道「这是哪块屏、是不是被缩放过」，
    /// 而缩放与否直接决定它数像素得出的结论是否可靠。
    private static func metadataText(for outcome: CaptureOutcome) -> String {
        let source = outcome.sourcePixelSize
        let output = outcome.pixelSize
        let scaled = source != output

        var lines: [String] = []

        // 第一行必须说清「这张图是什么」：窗口截图与整屏截图的后续判断完全不同，
        // 而模型只能靠这段文字区分二者。
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

        lines.append("显示器缩放系数：\(outcome.scaleFactor)")

        if let saved = outcome.savedURL {
            lines.append("已另存为：\(saved.path)")
        }

        return lines.joined(separator: "\n")
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
