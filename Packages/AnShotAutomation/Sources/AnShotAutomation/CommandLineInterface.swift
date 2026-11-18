//
//  CommandLineInterface.swift
//  AnShotAutomation
//
//  命令行自动化入口。给脚本、CI 与 AI 工具调用。
//  使用从左到右单遍游标状态机解析参数，支持 `--option=value`，
//  彻底杜绝跨参数前置扫描造成的参数注入漏洞。
//

import AnShotCapture
import CoreGraphics
import Darwin
import Foundation

/// 命令行动作。
public enum CommandLineAction: Equatable, Sendable {
    case help
    case listDisplays
    case listDesktops
    case listWindows
    case capture(CaptureParameters)
    case ocr(OCRParameters)
    case inspectElements(InspectElementsParameters)
    case record(RecordingParameters)
    case ipcRequest(path: String)
}

/// 一次解析完成的命令行调用。
public struct Outcome: Equatable, Sendable {

    public var action: CommandLineAction

    /// 结果 JSON 的落盘路径。`nil` 表示只写 stdout。
    public var jsonOutPath: String?

    /// 截图/录制由谁执行。默认复用 anShot.app 已有的屏幕录制授权。
    public var execution: CaptureExecution

    public init(
        action: CommandLineAction,
        jsonOutPath: String? = nil,
        execution: CaptureExecution = .reuseApplicationAuthorization
    ) {
        self.action = action
        self.jsonOutPath = jsonOutPath
        self.execution = execution
    }
}

/// 命令行界面。
public enum CommandLineInterface {

    /// 默认输出目录（相对家目录）。仅在未给 `--out` 时使用。
    static let defaultOutputDirectoryName = "Pictures/anShot"

    /// 本工具的命令行帮助文本。
    public static var usage: String {
        """
        anShot —— 屏幕截图、OCR、UI 探测与录制的命令行入口

        用法：
          anShot --list-displays
          anShot --list-desktops
          anShot --list-windows
          anShot --capture [选项]
          anShot --ocr [选项]
          anShot --elements [选项]
          anShot --record [选项]

        截图选项（--capture）：
          --display <id>        目标显示器 ID（来自 --list-displays）。默认主显示器。
          --space <id>          目标桌面 ID（来自 --list-desktops）。默认不切换桌面。
          --switch-desktop      明确允许切换到目标桌面并在截图后恢复。
          --region x,y,w,h      截取区域，单位是**显示器内逻辑点**，原点在该显示器左上角。
          --window <id>         截取指定窗口（ID 来自 --list-windows，遮挡/后台窗口亦可）。
          --app <name>          按应用名截取窗口（当前在屏优先，其次面积最大）。
          --max-size <n>        输出长边像素上限。默认 \(ImageScaling.defaultMaxLongEdge)，0 表示不缩放。
          --format <png|jpeg>   输出图像格式。默认 png。
          --quality <1..100>    JPEG 压缩质量（仅 jpeg 格式生效，默认 82）。
          --coordinate-grid     在导出图边缘绘制逻辑点坐标标尺网格，辅助定位点击坐标。
          --out <path>          截图保存路径。省略则存到 ~/\(defaultOutputDirectoryName)/。
                                已存在时自动追加序号，绝不覆盖。

        离线 OCR 选项（--ocr）：
          --image <path>        识别本地图片文件（与屏幕/窗口/区域参数互斥）。
          --lang <c1,c2,...>    偏好识别语言（如 zh-Hans,en-US）。
          （亦可使用 --display / --space / --switch-desktop / --region / --window / --app）

        UI 控件树探测选项（--elements）：
          --window <id>         目标窗口 ID。
          --app <name>          目标应用名。
          --pid <pid>           目标进程 PID（与 --window / --app 三选一）。
          --max-depth <n>       最大遍历深度（1...12，默认 4）。
          --max-elements <n>    最大返回控件数（1...1000，默认 200）。

        有界时长录制选项（--record）：
          --duration <sec>      录制时长（强制 1...15 秒，默认 3）。
          --format <gif|mp4>    录制输出格式（默认 gif）。
          --fps <n>             帧率（GIF 默认 12，上限 30；MP4 默认 30，上限 60）。
          --max-size <n>        GIF 最大边长（100...1600，默认 800）。
          --out <path>          输出路径。省略则存到 ~/\(defaultOutputDirectoryName)/。
          （目标支持 --display / --region / --window / --app）

        通用选项：
          --json-out <path>     把结果 JSON 额外写入该文件（成功或失败都写，绝不覆盖产物）。
          --via-app             **默认行为**（写出仅为显式表达）：让 anShot.app 自己执行，
                                复用它已有的屏幕录制授权。
          --direct              就地执行，用当前终端 / AI 宿主的授权。
          --mcp                 以 MCP stdio 服务端运行（供 AI 客户端调用）。
          -h, --help            显示本帮助。

        权限：
          屏幕录制授权记在**发起进程**的代码身份上，而不是可执行文件上。
          默认的 --via-app 经 LaunchServices 启动 anShot.app，复用它已有的授权。
          --direct 才会把授权要求落到当前进程。

        输出：
          stdout 始终是结果 JSON（含 "ok" 字段）；诊断信息走 stderr。
        """
    }

    // MARK: - 单遍游标参数解析

    private enum PrimaryAction: Equatable {
        case help
        case listDisplays
        case listDesktops
        case listWindows
        case capture
        case ocr
        case elements
        case record
        case ipcRequest(String)

        var flagName: String {
            switch self {
            case .help:           return "--help"
            case .listDisplays:   return "--list-displays"
            case .listDesktops:   return "--list-desktops"
            case .listWindows:    return "--list-windows"
            case .capture:        return "--capture"
            case .ocr:            return "--ocr"
            case .elements:       return "--elements"
            case .record:         return "--record"
            case .ipcRequest:     return "--ipc-request"
            }
        }
    }

    /// 内部选项采集状态，用于单遍扫描后按动作精确校验合法性。
    private struct ParsedTokens {
        var action: PrimaryAction?
        var sawHelp = false
        var jsonOutPath: String?
        var execution: CaptureExecution = .reuseApplicationAuthorization
        var executionWasSpecified = false

        var displayID: CGDirectDisplayID?
        var spaceID: UInt64?
        var allowDesktopSwitch = false
        var region: CGRect?
        var windowID: CGWindowID?
        var applicationName: String?
        var maxLongEdge: Int?
        var savePath: String?
        var rawFormat: String?
        var quality: Int?
        var coordinateGrid = false

        var imagePath: String?
        var languages: [String]?

        var pid: Int32?
        var maxDepth: Int?
        var maxElements: Int?

        var durationSeconds: TimeInterval?
        var fps: Int?

        /// 记录已出现的非全局选项名称，以便在动作不兼容时给出精准提示。
        var specificOptionFlags: Set<String> = []
    }

    /// 从左到右单遍游标状态机解析命令行参数（支持 `--option=value`）。
    ///
    /// - Throws: `AutomationError.invalidArgument`（未知选项、缺值、格式错误、路径冲突）
    public static func parse(arguments: [String]) throws -> Outcome {
        var cursor = arguments.dropFirst()
        if cursor.isEmpty {
            return Outcome(action: .help)
        }

        var state = ParsedTokens()

        func setAction(_ next: PrimaryAction) throws {
            if let existing = state.action, existing != next {
                throw AutomationError.invalidArgument(
                    "\(existing.flagName) 与 \(next.flagName) 不能同时使用。"
                )
            }
            state.action = next
        }

        while let token = cursor.first {
            cursor = cursor.dropFirst()

            let (option, inlineValue) = splitOptionToken(token)

            switch option {
            case "--help", "-h":
                guard inlineValue == nil else {
                    throw AutomationError.invalidArgument("\(option) 不接受参数值。")
                }
                state.sawHelp = true

            case "--mcp":
                throw AutomationError.invalidArgument("--mcp 不能与其它选项同时使用。")

            case "--list-displays":
                guard inlineValue == nil else {
                    throw AutomationError.invalidArgument("--list-displays 不接受参数值。")
                }
                try setAction(.listDisplays)

            case "--list-desktops":
                guard inlineValue == nil else {
                    throw AutomationError.invalidArgument("--list-desktops 不接受参数值。")
                }
                try setAction(.listDesktops)

            case "--list-windows":
                guard inlineValue == nil else {
                    throw AutomationError.invalidArgument("--list-windows 不接受参数值。")
                }
                try setAction(.listWindows)

            case "--capture":
                guard inlineValue == nil else {
                    throw AutomationError.invalidArgument("--capture 不接受参数值。")
                }
                try setAction(.capture)

            case "--ocr":
                guard inlineValue == nil else {
                    throw AutomationError.invalidArgument("--ocr 不接受参数值。")
                }
                try setAction(.ocr)

            case "--elements":
                guard inlineValue == nil else {
                    throw AutomationError.invalidArgument("--elements 不接受参数值。")
                }
                try setAction(.elements)

            case "--record":
                guard inlineValue == nil else {
                    throw AutomationError.invalidArgument("--record 不接受参数值。")
                }
                try setAction(.record)

            case "--ipc-request":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                try setAction(.ipcRequest(value))

            case "--json-out":
                state.jsonOutPath = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)

            case "--direct", "--via-app":
                guard inlineValue == nil else {
                    throw AutomationError.invalidArgument("\(option) 不接受参数值。")
                }
                let requested: CaptureExecution =
                    option == "--direct" ? .currentProcess : .reuseApplicationAuthorization
                if state.executionWasSpecified, state.execution != requested {
                    throw AutomationError.invalidArgument(
                        "--direct 与 --via-app 含义相反，不能同时使用。"
                    )
                }
                state.execution = requested
                state.executionWasSpecified = true

            case "--display":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                guard let id = UInt32(value) else {
                    throw AutomationError.invalidArgument(
                        "--display 需要一个无符号整数 ID，收到「\(value)」。"
                    )
                }
                state.displayID = CGDirectDisplayID(id)
                state.specificOptionFlags.insert(option)

            case "--space":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                guard let id = UInt64(value), id > 0 else {
                    throw AutomationError.invalidArgument("--space 需要大于 0 的桌面 ID，收到「\(value)」。")
                }
                state.spaceID = id
                state.specificOptionFlags.insert(option)

            case "--switch-desktop":
                guard inlineValue == nil else {
                    throw AutomationError.invalidArgument("--switch-desktop 不接受参数值。")
                }
                state.allowDesktopSwitch = true
                state.specificOptionFlags.insert(option)

            case "--region":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                state.region = try parseRegion(value)
                state.specificOptionFlags.insert(option)

            case "--window":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                guard let id = UInt32(value) else {
                    throw AutomationError.invalidArgument(
                        "--window 需要一个无符号整数 ID，收到「\(value)」。可用 --list-windows 获取窗口 ID。"
                    )
                }
                state.windowID = CGWindowID(id)
                state.specificOptionFlags.insert(option)

            case "--app":
                state.applicationName = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                state.specificOptionFlags.insert(option)

            case "--max-size":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                guard let size = Int(value) else {
                    throw AutomationError.invalidArgument(
                        "--max-size 需要一个整数，收到「\(value)」。"
                    )
                }
                state.maxLongEdge = size
                state.specificOptionFlags.insert(option)

            case "--out":
                state.savePath = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                state.specificOptionFlags.insert(option)

            case "--format":
                state.rawFormat = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                state.specificOptionFlags.insert(option)

            case "--quality":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                guard let q = Int(value) else {
                    throw AutomationError.invalidArgument("--quality 需要一个整数（1...100），收到「\(value)」。")
                }
                state.quality = q
                state.specificOptionFlags.insert(option)

            case "--coordinate-grid":
                guard inlineValue == nil else {
                    throw AutomationError.invalidArgument("--coordinate-grid 不接受参数值。")
                }
                state.coordinateGrid = true
                state.specificOptionFlags.insert(option)

            case "--image":
                state.imagePath = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                state.specificOptionFlags.insert(option)

            case "--lang":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                state.languages = value
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                state.specificOptionFlags.insert(option)

            case "--pid":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                guard let pid = Int32(value) else {
                    throw AutomationError.invalidArgument("--pid 需要一个整数 PID，收到「\(value)」。")
                }
                state.pid = pid
                state.specificOptionFlags.insert(option)

            case "--max-depth":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                guard let depth = Int(value) else {
                    throw AutomationError.invalidArgument("--max-depth 需要一个整数，收到「\(value)」。")
                }
                state.maxDepth = depth
                state.specificOptionFlags.insert(option)

            case "--max-elements":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                guard let count = Int(value) else {
                    throw AutomationError.invalidArgument("--max-elements 需要一个整数，收到「\(value)」。")
                }
                state.maxElements = count
                state.specificOptionFlags.insert(option)

            case "--duration":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                guard let seconds = Double(value), seconds.isFinite else {
                    throw AutomationError.invalidArgument("--duration 需要一个有限数字（1...15 秒），收到「\(value)」。")
                }
                state.durationSeconds = seconds
                state.specificOptionFlags.insert(option)

            case "--fps":
                let value = try takeValue(for: option, inlineValue: inlineValue, cursor: &cursor)
                guard let fps = Int(value) else {
                    throw AutomationError.invalidArgument("--fps 需要一个整数，收到「\(value)」。")
                }
                state.fps = fps
                state.specificOptionFlags.insert(option)

            default:
                throw AutomationError.invalidArgument(
                    "未知选项「\(option)」。运行 `anShot --help` 查看可用选项。"
                )
            }
        }

        if state.sawHelp {
            return Outcome(action: .help, jsonOutPath: state.jsonOutPath)
        }

        guard let action = state.action else {
            throw AutomationError.invalidArgument(
                "缺少动作。可用：--capture、--ocr、--elements、--record、--list-displays、--list-desktops、--list-windows、--help。"
            )
        }

        return try finalizeOutcome(action: action, state: state)
    }

    private static func finalizeOutcome(action: PrimaryAction, state: ParsedTokens) throws -> Outcome {
        switch action {
        case .help:
            return Outcome(action: .help, jsonOutPath: state.jsonOutPath)

        case .listDisplays:
            try rejectDisallowedOptions(
                actionFlag: "--list-displays",
                state: state,
                allowed: [],
                allowExecutionFlag: false
            )
            return Outcome(action: .listDisplays, jsonOutPath: state.jsonOutPath)

        case .listDesktops:
            try rejectDisallowedOptions(
                actionFlag: "--list-desktops",
                state: state,
                allowed: [],
                allowExecutionFlag: false
            )
            return Outcome(action: .listDesktops, jsonOutPath: state.jsonOutPath)

        case .listWindows:
            try rejectDisallowedOptions(
                actionFlag: "--list-windows",
                state: state,
                allowed: [],
                allowExecutionFlag: true
            )
            return Outcome(action: .listWindows, jsonOutPath: state.jsonOutPath, execution: state.execution)

        case .ipcRequest(let path):
            try rejectDisallowedOptions(
                actionFlag: "--ipc-request",
                state: state,
                allowed: [],
                allowExecutionFlag: false
            )
            guard state.jsonOutPath == nil else {
                throw AutomationError.invalidArgument("--ipc-request 不允许与 --json-out 同时使用。")
            }
            return Outcome(action: .ipcRequest(path: path))

        case .capture:
            let allowed: Set<String> = [
                "--display", "--space", "--switch-desktop", "--region",
                "--window", "--app", "--max-size", "--out",
                "--format", "--quality", "--coordinate-grid"
            ]
            try rejectDisallowedOptions(
                actionFlag: "--capture",
                state: state,
                allowed: allowed,
                allowExecutionFlag: true
            )

            let imageFormat: CaptureImageFormat?
            if let raw = state.rawFormat {
                guard let parsed = CaptureImageFormat(rawValue: raw) else {
                    throw AutomationError.invalidArgument(
                        "--format 仅支持 png 或 jpeg（收到「\(raw)」）。"
                    )
                }
                imageFormat = parsed
            } else {
                imageFormat = nil
            }

            try validatePathSeparation(savePath: state.savePath, jsonOutPath: state.jsonOutPath)

            let parameters = CaptureParameters(
                displayID: state.displayID,
                spaceID: state.spaceID,
                allowDesktopSwitch: state.allowDesktopSwitch,
                region: state.region,
                windowID: state.windowID,
                applicationName: state.applicationName,
                maxLongEdge: state.maxLongEdge,
                savePath: state.savePath,
                outputFormat: imageFormat,
                jpegQuality: state.quality,
                autoFallbackToJPEG: false,
                coordinateGrid: state.coordinateGrid
            )
            return Outcome(
                action: .capture(parameters),
                jsonOutPath: state.jsonOutPath,
                execution: state.execution
            )

        case .ocr:
            let allowed: Set<String> = [
                "--image", "--lang",
                "--display", "--space", "--switch-desktop", "--region", "--window", "--app"
            ]
            try rejectDisallowedOptions(
                actionFlag: "--ocr",
                state: state,
                allowed: allowed,
                allowExecutionFlag: true
            )
            let parameters = OCRParameters(
                imagePath: state.imagePath,
                displayID: state.displayID,
                spaceID: state.spaceID,
                allowDesktopSwitch: state.allowDesktopSwitch,
                region: state.region,
                windowID: state.windowID,
                applicationName: state.applicationName,
                languages: state.languages
            )
            return Outcome(
                action: .ocr(parameters),
                jsonOutPath: state.jsonOutPath,
                execution: state.execution
            )

        case .elements:
            let allowed: Set<String> = [
                "--window", "--app", "--pid", "--max-depth", "--max-elements"
            ]
            try rejectDisallowedOptions(
                actionFlag: "--elements",
                state: state,
                allowed: allowed,
                allowExecutionFlag: true
            )
            let parameters = InspectElementsParameters(
                windowID: state.windowID,
                applicationName: state.applicationName,
                pid: state.pid,
                maxDepth: state.maxDepth ?? InspectElementsParameters.defaultMaxDepth,
                maxElements: state.maxElements ?? InspectElementsParameters.defaultMaxElements
            )
            return Outcome(
                action: .inspectElements(parameters),
                jsonOutPath: state.jsonOutPath,
                execution: state.execution
            )

        case .record:
            let allowed: Set<String> = [
                "--display", "--region", "--window", "--app",
                "--duration", "--format", "--fps", "--max-size", "--out"
            ]
            try rejectDisallowedOptions(
                actionFlag: "--record",
                state: state,
                allowed: allowed,
                allowExecutionFlag: true
            )

            let recordFormat: RecordingOutputFormat
            if let raw = state.rawFormat {
                guard let parsed = RecordingOutputFormat(rawValue: raw) else {
                    throw AutomationError.invalidArgument(
                        "--record 下 --format 仅支持 gif 或 mp4（收到「\(raw)」）。"
                    )
                }
                recordFormat = parsed
            } else {
                recordFormat = .gif
            }

            try validatePathSeparation(savePath: state.savePath, jsonOutPath: state.jsonOutPath)

            let parameters = RecordingParameters(
                displayID: state.displayID,
                region: state.region,
                windowID: state.windowID,
                applicationName: state.applicationName,
                durationSeconds: state.durationSeconds ?? RecordingParameters.defaultDurationSeconds,
                format: recordFormat,
                fps: state.fps,
                maxDimension: state.maxLongEdge,
                savePath: state.savePath
            )
            return Outcome(
                action: .record(parameters),
                jsonOutPath: state.jsonOutPath,
                execution: state.execution
            )
        }
    }

    private static func rejectDisallowedOptions(
        actionFlag: String,
        state: ParsedTokens,
        allowed: Set<String>,
        allowExecutionFlag: Bool
    ) throws {
        if !allowExecutionFlag && state.executionWasSpecified {
            let flag = state.execution == .currentProcess ? "--direct" : "--via-app"
            throw AutomationError.invalidArgument(
                "\(actionFlag) 不接受其它选项（收到：\(flag)）。"
            )
        }
        let extra = state.specificOptionFlags.subtracting(allowed).sorted()
        guard extra.isEmpty else {
            throw AutomationError.invalidArgument(
                "\(actionFlag) 不接受其它选项（收到：\(extra.joined(separator: " "))）。"
            )
        }
    }

    /// 拆分 `--option=value` 形式的 token。
    private static func splitOptionToken(_ token: String) -> (option: String, inlineValue: String?) {
        guard token.hasPrefix("--"), let eqIndex = token.firstIndex(of: "=") else {
            return (token, nil)
        }
        let option = String(token[..<eqIndex])
        let value = String(token[token.index(after: eqIndex)...])
        return (option, value)
    }

    /// 取选项值：优先取 `--option=value` 中的内联值，否则从游标消费下一项。
    private static func takeValue(
        for option: String,
        inlineValue: String?,
        cursor: inout ArraySlice<String>
    ) throws -> String {
        if let inlineValue {
            return inlineValue
        }
        guard let value = cursor.first else {
            throw AutomationError.invalidArgument("\(option) 缺少值。")
        }
        cursor = cursor.dropFirst()
        guard !value.hasPrefix("--") else {
            throw AutomationError.invalidArgument(
                "\(option) 缺少值（下一个参数是选项「\(value)」）。"
            )
        }
        return value
    }

    /// 拒绝「输出产物与报告写到同一个文件」（含 APFS 大小写折叠与 inode 比对）。
    static func validatePathSeparation(
        savePath: String?,
        jsonOutPath: String?
    ) throws {
        guard let savePath, let jsonOutPath else { return }
        guard PathIdentity.areSame(savePath, jsonOutPath) else { return }

        throw AutomationError.outputPathConflict(
            "--out 与 --json-out 指向同一个文件（\(PathIdentity.canonical(savePath))）。"
            + "结果是 JSON 覆盖掉刚写好的产物；请给两者不同的路径。"
        )
    }

    // MARK: - 执行

    /// 执行一条已解析的调用。
    ///
    /// - Returns: 进程退出码（0 成功；非 0 失败）。
    public static func run(_ outcome: Outcome) async -> Int32 {
        if case .help = outcome.action {
            emit(usage)
            return 0
        }

        if case .ipcRequest(let requestPath) = outcome.action {
            return await executeIPCRequest(at: requestPath)
        }

        let reservedPaths: Set<String> = outcome.jsonOutPath
            .map { [PathIdentity.comparisonKey($0)] } ?? []

        var report: CommandReport
        var exitCode: Int32 = 0

        switch outcome.action {
        case .help, .ipcRequest:
            report = CommandReport.failure("未预期的动作分发。")
            exitCode = 1

        case .listDisplays:
            report = CommandReport(ok: true, displays: DisplayCatalog.all())

        case .listDesktops:
            do {
                report = CommandReport(ok: true, desktops: try DesktopCatalog.all())
            } catch {
                report = CommandReport.failure(error.localizedDescription)
                exitCode = 1
            }

        case .listWindows:
            do {
                let windows: [WindowInfo]
                if outcome.execution == .reuseApplicationAuthorization,
                   let appURL = OutOfProcessCapture.currentAppURL {
                    windows = try await OutOfProcessCapture.listWindows(appURL: appURL)
                } else {
                    windows = WindowCatalog.all()
                }
                report = CommandReport(ok: true, windows: windows)
            } catch let error as AutomationError {
                report = CommandReport.failure(error.localizedDescription)
                exitCode = 1
            } catch {
                report = CommandReport.failure("枚举窗口失败：\(error.localizedDescription)")
                exitCode = 1
            }

        case .capture(let parameters):
            var effective = parameters
            if effective.savePath == nil || effective.savePath?.isEmpty == true {
                effective.savePath = defaultOutputPath(format: effective.outputFormat ?? .png)
            }

            do {
                let capture = try await CaptureRunner.run(
                    parameters: effective,
                    execution: outcome.execution,
                    reservedOutputPaths: reservedPaths
                )
                report = CommandReport(
                    ok: true,
                    capture: CaptureOutput(outcome: capture)
                )
            } catch let error as AutomationError {
                report = CommandReport.failure(error.localizedDescription)
                exitCode = 1
            } catch {
                report = CommandReport.failure("截图失败：\(error.localizedDescription)")
                exitCode = 1
            }

        case .ocr(let parameters):
            do {
                let ocr = try await AutomationOCRService.recognize(
                    parameters,
                    execution: outcome.execution
                )
                report = CommandReport(ok: true, ocr: ocr)
            } catch let error as AutomationError {
                report = CommandReport.failure(error.localizedDescription)
                exitCode = 1
            } catch {
                report = CommandReport.failure("离线文字识别失败：\(error.localizedDescription)")
                exitCode = 1
            }

        case .inspectElements(let parameters):
            do {
                let elements = try await AccessibilityInspector.inspect(
                    parameters,
                    execution: outcome.execution
                )
                report = CommandReport(ok: true, elements: elements)
            } catch let error as AutomationError {
                report = CommandReport.failure(error.localizedDescription)
                exitCode = 1
            } catch {
                report = CommandReport.failure("控件树探测失败：\(error.localizedDescription)")
                exitCode = 1
            }

        case .record(let parameters):
            do {
                let recording = try await RecordingService.record(
                    parameters,
                    execution: outcome.execution,
                    reservedOutputPaths: reservedPaths
                )
                report = CommandReport(ok: true, recording: recording)
            } catch let error as AutomationError {
                report = CommandReport.failure(error.localizedDescription)
                exitCode = 1
            } catch {
                report = CommandReport.failure("屏幕录制失败：\(error.localizedDescription)")
                exitCode = 1
            }
        }

        let protectedPath = report.capture?.savedPath ?? report.recording?.savedPath
        if let path = outcome.jsonOutPath,
           !writeReport(report, to: path, protectedOutputPath: protectedPath) {
            report = CommandReport(
                ok: false,
                error: "结果 JSON 写入失败（或目标与已保存产物路径重合）：\(path)。",
                displays: report.displays,
                desktops: report.desktops,
                windows: report.windows,
                capture: report.capture,
                ocr: report.ocr,
                elements: report.elements,
                recording: report.recording
            )
            exitCode = 1
        }

        guard let json = encode(report) else {
            emit(#"{"ok":false,"error":"结果序列化失败"}"#)
            emitDiagnostic("结果序列化失败")
            return 1
        }

        emit(json)
        if !report.ok, let message = report.error {
            emitDiagnostic(message)
        }

        return exitCode
    }

    // MARK: - 跨进程请求执行与 Watchdog

    private static func executeIPCRequest(at requestPath: String) async -> Int32 {
        let request: IPCRequest
        do {
            request = try IPCRequest.load(from: requestPath)
        } catch {
            emitDiagnostic("IPC 请求加载失败：\(error.localizedDescription)")
            return 1
        }

        // 启动后第一时间写入 child.pid，便于父进程超时/取消时回收本进程。
        IPCRequest.writeCurrentPID(to: request.pidFilePath)

        // 挂载进程内硬超时 Watchdog 自毁兜底，防止父进程意外退出时子实例残留成孤儿。
        let watchdogDelay = max(5, request.watchdogTimeoutSeconds + 5)
        let watchdogReportPath = request.reportPath
        let watchdogTask = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64((watchdogDelay * 1_000_000_000).rounded()))
            guard !Task.isCancelled else { return }
            let timeoutReport = CommandReport.failure(
                "anShot 子实例执行超出硬超时上限（\(Int(watchdogDelay)) 秒），已自动终止。"
            )
            if let data = encode(timeoutReport).map({ Data($0.utf8) }) {
                try? IPCRequest.writePrivateFile(data, to: URL(fileURLWithPath: watchdogReportPath))
            }
            Darwin._exit(124)
        }
        defer { watchdogTask.cancel() }

        var report: CommandReport
        var exitCode: Int32 = 0

        switch request.action {
        case .listWindows:
            report = CommandReport(ok: true, windows: WindowCatalog.all())

        case .capture(var params):
            params.savePath = nil
            do {
                let timeout = max(10, request.watchdogTimeoutSeconds)
                let outcome = try await CaptureService.capture(params, lockTimeout: timeout)
                guard let outputPath = request.outputPath else {
                    throw AutomationError.outputFailed("IPC 请求缺少中转输出路径。")
                }
                try IPCRequest.writePrivateFile(outcome.imageData, to: URL(fileURLWithPath: outputPath))
                report = CommandReport(
                    ok: true,
                    capture: CaptureOutput(outcome: outcome, overrideSavedPath: outputPath)
                )
            } catch let error as AutomationError {
                report = CommandReport.failure(error.localizedDescription)
                exitCode = 1
            } catch {
                report = CommandReport.failure("截图失败：\(error.localizedDescription)")
                exitCode = 1
            }

        case .ocr(let params):
            do {
                let ocr = try await AutomationOCRService.recognize(params, execution: .currentProcess)
                report = CommandReport(ok: true, ocr: ocr)
            } catch let error as AutomationError {
                report = CommandReport.failure(error.localizedDescription)
                exitCode = 1
            } catch {
                report = CommandReport.failure("离线文字识别失败：\(error.localizedDescription)")
                exitCode = 1
            }

        case .inspectElements(let params):
            do {
                let elements = try await AccessibilityInspector.inspect(params, execution: .currentProcess)
                report = CommandReport(ok: true, elements: elements)
            } catch let error as AutomationError {
                report = CommandReport.failure(error.localizedDescription)
                exitCode = 1
            } catch {
                report = CommandReport.failure("控件树探测失败：\(error.localizedDescription)")
                exitCode = 1
            }

        case .record(let params):
            do {
                let artifact = try await RecordingService.recordLocallyToTemporaryFile(params)
                defer {
                    try? FileManager.default.removeItem(
                        at: artifact.temporaryURL.deletingLastPathComponent()
                    )
                }
                guard let outputPath = request.outputPath else {
                    throw AutomationError.outputFailed("IPC 请求缺少录制中转输出路径。")
                }
                let data = try Data(contentsOf: artifact.temporaryURL, options: [.mappedIfSafe])
                try IPCRequest.writePrivateFile(data, to: URL(fileURLWithPath: outputPath))
                let rec = RecordingOutcomeOutput(
                    savedPath: outputPath,
                    format: artifact.format,
                    durationSeconds: artifact.durationSeconds,
                    pixelWidth: artifact.pixelWidth,
                    pixelHeight: artifact.pixelHeight,
                    frameRate: artifact.frameRate,
                    fileSizeBytes: artifact.fileSizeBytes
                )
                report = CommandReport(ok: true, recording: rec)
            } catch let error as AutomationError {
                report = CommandReport.failure(error.localizedDescription)
                exitCode = 1
            } catch {
                report = CommandReport.failure("屏幕录制失败：\(error.localizedDescription)")
                exitCode = 1
            }
        }

        if let data = encode(report).map({ Data($0.utf8) }) {
            do {
                try IPCRequest.writePrivateFile(data, to: URL(fileURLWithPath: request.reportPath))
            } catch {
                emitDiagnostic("IPC 报告写入失败：\(error.localizedDescription)")
                return 1
            }
        } else {
            return 1
        }
        return exitCode
    }

    // MARK: - 失败出口与尽力写报告

    @discardableResult
    public static func emitFailure(
        _ message: String,
        jsonOutPath: String? = nil
    ) -> Int32 {
        let report = CommandReport.failure(message)

        guard let json = encode(report) else {
            emit(#"{"ok":false,"error":"结果序列化失败"}"#)
            emitDiagnostic(message)
            return 1
        }

        emit(json)
        emitDiagnostic(message)

        if let path = jsonOutPath, !writeReport(report, to: path) {
            emitDiagnostic("结果 JSON 写入失败：\(path)")
        }

        return 1
    }

    static func isPathConflict(_ error: Error) -> Bool {
        if case .outputPathConflict = (error as? AutomationError) { return true }
        return false
    }

    /// 解析失败时从左到右尽力提取 `--json-out`（支持 `--json-out=path` 并跳过其他选项的值）。
    static func bestEffortJSONOutPath(arguments: [String]) -> String? {
        let valueOptions: Set<String> = [
            "--display", "--space", "--region", "--window", "--app",
            "--max-size", "--out", "--format", "--quality",
            "--image", "--lang", "--duration", "--fps", "--pid",
            "--max-depth", "--max-elements", "--ipc-request"
        ]
        var cursor = arguments.dropFirst()
        while let token = cursor.first {
            cursor = cursor.dropFirst()
            let (option, inlineValue) = splitOptionToken(token)
            if option == "--json-out" {
                if let inlineValue {
                    return inlineValue.isEmpty ? nil : inlineValue
                }
                guard let next = cursor.first, !next.hasPrefix("--") else {
                    return nil
                }
                return next
            }
            if valueOptions.contains(option), inlineValue == nil,
               let next = cursor.first, !next.hasPrefix("--") {
                cursor = cursor.dropFirst()
            }
        }
        return nil
    }

    // MARK: - 默认路径

    static func defaultOutputPath(
        format: CaptureImageFormat = .png,
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/\(defaultOutputDirectoryName)/anshot-\(formatter.string(from: now)).\(format.fileExtension)"
    }

    // MARK: - 参数辅助

    private static func parseRegion(_ raw: String) throws -> CGRect {
        let parts = raw
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard parts.count == 4 else {
            throw AutomationError.invalidArgument(
                "--region 需要 4 个数 x,y,w,h，收到 \(parts.count) 个：「\(raw)」。"
            )
        }

        var numbers: [CGFloat] = []
        for (index, part) in parts.enumerated() {
            guard let value = Double(part) else {
                throw AutomationError.invalidArgument(
                    "--region 的第 \(index + 1) 项不是数字：「\(part)」。"
                )
            }
            guard value.isFinite else {
                throw AutomationError.invalidArgument(
                    "--region 的第 \(index + 1) 项不是有限数值：「\(part)」。"
                )
            }
            numbers.append(CGFloat(value))
        }

        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    // MARK: - 输出

    private static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 把结果写入 `--json-out` 指定的文件；写入前校验不与已保存产物重合（含 APFS 大小写与 inode 检查）。
    @discardableResult
    static func writeReport(
        _ report: CommandReport,
        to path: String?,
        protectedOutputPath: String? = nil
    ) -> Bool {
        guard let path, !path.isEmpty else { return true }
        if let protectedOutputPath {
            if PathIdentity.areSame(path, protectedOutputPath)
                || PathIdentity.isSameInode(path, protectedOutputPath) {
                return false
            }
        }
        guard let json = encode(report) else { return false }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(json.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func emitDiagnostic(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// 命令行结果报告。
struct CommandReport: Codable {

    let ok: Bool
    let error: String?
    let displays: [DisplayInfo]?
    let desktops: [DesktopInfo]?
    let windows: [WindowInfo]?
    let capture: CaptureOutput?
    let ocr: OCRResponseOutput?
    let elements: ElementsInspectionOutput?
    let recording: RecordingOutcomeOutput?

    init(
        ok: Bool,
        error: String? = nil,
        displays: [DisplayInfo]? = nil,
        desktops: [DesktopInfo]? = nil,
        windows: [WindowInfo]? = nil,
        capture: CaptureOutput? = nil,
        ocr: OCRResponseOutput? = nil,
        elements: ElementsInspectionOutput? = nil,
        recording: RecordingOutcomeOutput? = nil
    ) {
        self.ok = ok
        self.error = error
        self.displays = displays
        self.desktops = desktops
        self.windows = windows
        self.capture = capture
        self.ocr = ocr
        self.elements = elements
        self.recording = recording
    }

    static func failure(_ message: String) -> CommandReport {
        CommandReport(ok: false, error: message)
    }
}

/// `--capture` 的输出结构。
struct CaptureOutput: Codable {

    let displayId: UInt32
    let spaceId: UInt64?
    let pixelWidth: Int
    let pixelHeight: Int
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    let scaleFactor: Double
    let imageFormat: String?
    let mimeType: String?
    let jpegQuality: Int?
    let didAutoFallbackToJPEG: Bool?
    let originalPNGByteCount: Int?
    let coordinateGridEnabled: Bool?
    let coordinateGridOrigin: PointOutput?
    let region: RegionOutput?
    let window: WindowOutput?
    let savedPath: String?

    struct PointOutput: Codable {
        let x: Double
        let y: Double
    }

    struct RegionOutput: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var rect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    struct WindowOutput: Codable {
        let windowId: UInt32
        let title: String?
        let applicationName: String?
        let isOnScreen: Bool?
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var frame: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    init(outcome: CaptureOutcome, overrideSavedPath: String? = nil) {
        self.displayId = outcome.displayID
        self.spaceId = outcome.spaceID
        self.pixelWidth = outcome.image.width
        self.pixelHeight = outcome.image.height
        self.sourcePixelWidth = Int(outcome.sourcePixelSize.width)
        self.sourcePixelHeight = Int(outcome.sourcePixelSize.height)
        self.scaleFactor = Double(outcome.scaleFactor)
        self.imageFormat = outcome.imageFormat.rawValue
        self.mimeType = outcome.mimeType
        self.jpegQuality = outcome.jpegQuality
        self.didAutoFallbackToJPEG = outcome.didAutoFallbackToJPEG
        self.originalPNGByteCount = outcome.originalPNGByteCount
        self.coordinateGridEnabled = outcome.coordinateGridEnabled
        self.coordinateGridOrigin = outcome.coordinateGridOrigin.map {
            PointOutput(x: Double($0.x), y: Double($0.y))
        }
        self.region = outcome.region.map {
            RegionOutput(
                x: Double($0.origin.x),
                y: Double($0.origin.y),
                width: Double($0.width),
                height: Double($0.height)
            )
        }
        self.window = outcome.window.map {
            WindowOutput(
                windowId: UInt32($0.windowID),
                title: $0.title,
                applicationName: $0.applicationName,
                isOnScreen: $0.isOnScreen,
                x: Double($0.frame.origin.x),
                y: Double($0.frame.origin.y),
                width: Double($0.frame.width),
                height: Double($0.frame.height)
            )
        }
        self.savedPath = overrideSavedPath ?? outcome.savedURL?.path
    }
}
