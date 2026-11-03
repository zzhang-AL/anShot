//
//  CommandLineInterface.swift
//  AnShotAutomation
//
//  命令行截图入口。给脚本、CI 与不想起 MCP 的场景用。
//
//  ── 为什么不只做 MCP ─────────────────────────────────────────
//
//  MCP 面向「模型自己决定要不要截图」；而调试现场还有另一类需求：
//  「我（或脚本）已经知道要截什么，只想拿个文件」。
//  这类需求套一层协议只是多一个会坏的环节，一条命令更直接。
//
//  两条入口共用 `CaptureService`，所以行为不会分叉。
//
//  ── 输出约定 ─────────────────────────────────────────────────
//
//      stdout       → 结果 JSON（**成功与失败都写**）
//      stderr       → 人类可读的简短诊断
//      --json-out   → 同一份 JSON 写入文件
//
//  stdout 上始终是合法 JSON：脚本可以无脑 `| jq .ok`，
//  不必按「这次是不是失败了」决定要不要解析。
//  给眼睛看的信息走 stderr，两者不混。
//
//  ── `--json-out` 为何必需（而不是多余的）────────────────────
//
//  屏幕录制权限记在**发起进程**头上（本项目 M1 阶段已有一手记录）。因此：
//
//      anShot --capture …                     → 权限归因给当前终端 / 宿主
//      open -n anShot.app --args --capture …   → 权限归因给 anShot.app
//
//  后者能**直接复用 anShot.app 已有的授权**（已实测可成功截图），
//  但它同时丢掉了 stdout/stderr（`open` 不转发管道）——
//  于是失败会变成「什么都没有发生」。`--json-out` 把结果写进文件，
//  补回这个缺口，使「零额外授权」的调用方式真正可用。
//

import AnShotCapture
import CoreGraphics
import Foundation

/// 命令行动作。
public enum CommandLineAction: Equatable, Sendable {
    case help
    case listDisplays
    case listDesktops
    case listWindows
    case capture(CaptureParameters)
}

/// 一次解析完成的命令行调用。
public struct Outcome: Equatable, Sendable {

    public var action: CommandLineAction

    /// 结果 JSON 的落盘路径。`nil` 表示只写 stdout。
    public var jsonOutPath: String?

    /// 截图由谁执行。默认复用 anShot.app 已有的屏幕录制授权。
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

    /// 默认输出目录（相对家目录）。仅在 `--capture` 未给 `--out` 时使用。
    ///
    /// 选 `~/Pictures/anShot` 而不是临时目录：调试用的截图通常要回头再看，
    /// 而临时目录会被系统清理，「刚截的图不见了」是比多一个文件夹更差的体验。
    static let defaultOutputDirectoryName = "Pictures/anShot"

    /// 本工具的命令行帮助文本。
    public static var usage: String {
        """
        anShot —— 屏幕截图的命令行入口

        用法：
          anShot --list-displays
          anShot --list-desktops
          anShot --list-windows
          anShot --capture [选项]

        选项：
          --display <id>        目标显示器 ID（来自 --list-displays）。默认主显示器。
          --space <id>          目标桌面 ID（来自 --list-desktops）。默认不切换桌面。
          --switch-desktop      明确允许切换到目标桌面并在截图后恢复。
                                可与 --display / --region 组合，不可与 --window / --app 混用。
          --region x,y,w,h      截取区域，单位是**显示器内逻辑点**，原点在该显示器左上角。
                                省略则截取整块显示器。
          --window <id>         截取指定窗口（ID 来自 --list-windows）。
                                **窗口被遮挡、不在最顶层时同样能截到完整内容**——
                                这正是它存在的理由：显示器 + 区域要求调用方先知道
                                窗口在哪，而调用方看不到才要截图。
                                其他桌面的窗口可尝试截图；隐藏或最小化时可能不可用。
          --app <name>          按应用名截取窗口（当前在屏优先，其次面积最大）。
                                与 --window 二选一；两者都不能与 --display/--region 混用。
          --max-size <n>        输出长边像素上限。默认 \(ImageScaling.defaultMaxLongEdge)，0 表示不缩放。
          --out <path>          截图保存路径。省略则存到 ~/\(defaultOutputDirectoryName)/。
                                已存在时自动追加序号，绝不覆盖。
          --json-out <path>     把结果 JSON 额外写入该文件（成功或失败都写）。
          --via-app             **默认行为**（写出仅为显式表达）：让 anShot.app 自己截图，
                                复用它已有的屏幕录制授权。
          --direct              就地截图，用当前终端 / AI 宿主的授权。仅在已给当前进程
                                授权、或环境里没有可启动的 anShot.app 时才需要。
          --mcp                 以 MCP stdio 服务端运行（供 AI 客户端调用）。
          -h, --help            显示本帮助。

        权限：
          屏幕录制授权记在**发起进程**的代码身份上，而不是可执行文件上。
          默认的 --via-app 经 LaunchServices 启动 anShot.app，由它以自己的身份
          截图，因此**不需要**给终端或 AI 客户端任何授权。
          --direct 才会把授权要求落到当前进程——那是显式选择，不是默认。

          注意：窗口**标题**（--list-windows 的 title 字段）同样受这项权限管控。
          无权限的进程枚举出的窗口只有应用名，没有标题。
          --list-windows 包含其他桌面及可能已隐藏、最小化的窗口；
          切换桌面需要同时指定 --space 和 --switch-desktop，并需要辅助功能权限。

        输出：
          stdout 始终是结果 JSON（含 "ok" 字段）；诊断信息走 stderr。
          典型成功输出：
            {"capture":{"savedPath":"…/anshot-20260916-173100.png", …},"ok":true}
          典型失败输出：
            {"error":"…","ok":false}

        示例：
          anShot --list-displays
          anShot --list-desktops
          anShot --list-windows
          anShot --capture --out ~/Desktop/shot.png
          anShot --capture --display 1 --region 0,0,800,600 --max-size 0 --out /tmp/ui.png
          anShot --capture --app Safari --out /tmp/safari.png
          anShot --capture --window 1234 --out /tmp/window.png
          anShot --capture --direct --out /tmp/ui.png   # 用当前进程的授权
        """
    }

    // MARK: - 解析

    /// 解析命令行参数。
    ///
    /// - Throws: `AutomationError.invalidArgument`（未知选项、缺值、格式错误、路径冲突）
    public static func parse(arguments: [String]) throws -> Outcome {
        // 跳过可执行文件路径
        var args = arguments.dropFirst().map { $0 }

        // `--json-out` 对任何动作都适用，故先摘出来，
        // 各动作分支不必各自处理它。
        let jsonOutPath = try extractOption("--json-out", from: &args)

        let wantsHelp = args.contains("--help") || args.contains("-h")
        if args.isEmpty || wantsHelp {
            return Outcome(action: .help, jsonOutPath: jsonOutPath)
        }

        if args.contains("--mcp") {
            // `--mcp` 由 AutomationRunner.detect 在更早处拦截（含与其它选项
            // 混用的拒绝）。走到这里通常意味着有人直接调用了本解析器。
            throw AutomationError.invalidArgument("--mcp 不能与其它选项同时使用。")
        }

        if args.contains("--list-displays") {
            args.removeAll { $0 == "--list-displays" }
            // 与 `--list-windows` 不同，这里**刻意不接受** `--direct` / `--via-app`：
            // 列举显示器是纯 CoreGraphics 查询，不需要屏幕录制权限，
            // 两种执行方式的结果完全一样。接受一个无效果的标志只会让调用方
            // 以为自己切换了什么，而行为毫无变化。
            guard args.isEmpty else {
                throw AutomationError.invalidArgument(
                    "--list-displays 不接受其它选项（收到：\(args.joined(separator: " "))）。"
                )
            }
            return Outcome(action: .listDisplays, jsonOutPath: jsonOutPath)
        }

        if args.contains("--list-desktops") {
            args.removeAll { $0 == "--list-desktops" }
            guard args.isEmpty else {
                throw AutomationError.invalidArgument(
                    "--list-desktops 不接受其它选项（收到：\(args.joined(separator: " "))）。"
                )
            }
            return Outcome(action: .listDesktops, jsonOutPath: jsonOutPath)
        }

        if args.contains("--list-windows") {
            args.removeAll { $0 == "--list-windows" }
            // 这里的 `--direct` 还承担一个**防递归**职责：
            // 默认路径下本进程会让 anShot.app 去枚举（标题需要屏幕录制权限），
            // 而它启动的子实例同样是这个 CLI —— 子实例若不改成就地执行，
            // 就会再启动一个孙实例，无限递归。
            // 因此 `OutOfProcessCapture.listWindows` 固定给子实例传 `--direct`。
            let execution = try extractExecutionFlag(from: &args, into: .reuseApplicationAuthorization)
            guard args.isEmpty else {
                throw AutomationError.invalidArgument(
                    "--list-windows 不接受其它选项（收到：\(args.joined(separator: " "))）。"
                )
            }
            return Outcome(action: .listWindows, jsonOutPath: jsonOutPath, execution: execution)
        }

        guard args.contains("--capture") else {
            throw AutomationError.invalidArgument(
                "缺少动作。可用：--capture、--list-displays、--list-desktops、--list-windows、--help。"
            )
        }
        args.removeAll { $0 == "--capture" }

        var parameters = CaptureParameters()

        // 执行位置。默认复用 anShot.app 已有的授权——这是**默认**而不是可选
        // 优化：被 AI 宿主 spawn 的进程没有自己的 TCC 身份，就地截图会要求
        // 宿主再授权一次，而 anShot 明明已经授权过了。
        var execution = CaptureExecution.reuseApplicationAuthorization
        var executionWasSpecified = false

        // 用 while 而非 for：每个选项都要从数组里摘掉自己的值，
        // 否则循环体会把值当成下一个选项。
        while !args.isEmpty {
            let option = args.removeFirst()

            switch option {
            case "--display":
                let value = try takeValue(for: option, from: &args)
                guard let id = UInt32(value) else {
                    throw AutomationError.invalidArgument(
                        "--display 需要一个无符号整数 ID，收到「\(value)」。"
                    )
                }
                parameters.displayID = CGDirectDisplayID(id)

            case "--region":
                let value = try takeValue(for: option, from: &args)
                parameters.region = try parseRegion(value)

            case "--space":
                let value = try takeValue(for: option, from: &args)
                guard let id = UInt64(value), id > 0 else {
                    throw AutomationError.invalidArgument("--space 需要大于 0 的桌面 ID，收到「\(value)」。")
                }
                parameters.spaceID = id

            case "--switch-desktop":
                parameters.allowDesktopSwitch = true

            case "--window":
                let value = try takeValue(for: option, from: &args)
                guard let id = UInt32(value) else {
                    throw AutomationError.invalidArgument(
                        "--window 需要一个无符号整数 ID，收到「\(value)」。"
                        + "可用 --list-windows 获取窗口 ID。"
                    )
                }
                parameters.windowID = CGWindowID(id)

            case "--app":
                parameters.applicationName = try takeValue(for: option, from: &args)

            case "--max-size":
                let value = try takeValue(for: option, from: &args)
                guard let size = Int(value) else {
                    throw AutomationError.invalidArgument(
                        "--max-size 需要一个整数，收到「\(value)」。"
                    )
                }
                parameters.maxLongEdge = size

            case "--out":
                parameters.savePath = try takeValue(for: option, from: &args)

            case "--direct", "--via-app":
                // 这两个是**一对反义**标志，同时给出说明调用方自己没想清楚
                // 要哪种权限归属，静默取其一是不合适的。
                let requested: CaptureExecution =
                    option == "--direct" ? .currentProcess : .reuseApplicationAuthorization
                if executionWasSpecified, execution != requested {
                    throw AutomationError.invalidArgument(
                        "--direct 与 --via-app 含义相反，不能同时使用。"
                    )
                }
                execution = requested
                executionWasSpecified = true

            default:
                throw AutomationError.invalidArgument(
                    "未知选项「\(option)」。运行 `anShot --help` 查看可用选项。"
                )
            }
        }

        try validatePathSeparation(
            savePath: parameters.savePath,
            jsonOutPath: jsonOutPath
        )

        return Outcome(
            action: .capture(parameters),
            jsonOutPath: jsonOutPath,
            execution: execution
        )
    }

    /// 从参数里摘出「由谁执行」的开关。
    ///
    /// 两个标志是**反义**的，同时给出说明调用方自己没想清楚要哪种权限归属，
    /// 静默取其一是不合适的。
    ///
    /// 抽成独立函数是因为它现在有三个使用点（列举显示器 / 列举窗口 / 截图）：
    /// 原先只有截图分支处理它，于是 `--list-windows --direct` 会被当成
    /// 「多余的选项」拒绝——而那个标志恰恰是防自我递归所必需的。
    private static func extractExecutionFlag(
        from args: inout [String],
        into defaultValue: CaptureExecution
    ) throws -> CaptureExecution {
        var execution = defaultValue
        var wasSpecified = false

        for option in ["--direct", "--via-app"] where args.contains(option) {
            let requested: CaptureExecution =
                option == "--direct" ? .currentProcess : .reuseApplicationAuthorization

            if wasSpecified, execution != requested {
                throw AutomationError.invalidArgument(
                    "--direct 与 --via-app 含义相反，不能同时使用。"
                )
            }
            execution = requested
            wasSpecified = true
        }

        args.removeAll { $0 == "--direct" || $0 == "--via-app" }
        return execution
    }

    /// 拒绝「截图与报告写到同一个文件」。
    ///
    /// 不拦的后果很隐蔽：PNG 先写成功，紧接着 JSON 把它覆盖掉，
    /// 调用方拿到一个后缀是 `.png` 却装着 JSON 的文件，
    /// 而退出码是 0——看起来一切正常。
    static func validatePathSeparation(
        savePath: String?,
        jsonOutPath: String?
    ) throws {
        guard let savePath, let jsonOutPath else { return }

        // 经 PathIdentity 比较：折叠 `.`/`..`、解析符号链接。
        // 直接比字符串会漏判（macOS 上 `/tmp` 本身就是指向 /private/tmp 的链接）。
        guard PathIdentity.areSame(savePath, jsonOutPath) else { return }

        throw AutomationError.outputPathConflict(
            "--out 与 --json-out 指向同一个文件（\(PathIdentity.canonical(savePath))）。"
            + "结果是 JSON 覆盖掉刚写好的 PNG；请给两者不同的路径。"
        )
    }

    // MARK: - 执行

    /// 执行一条已解析的调用。
    ///
    /// - Returns: 进程退出码（0 成功；非 0 失败）。
    public static func run(_ outcome: Outcome) async -> Int32 {
        // 帮助不是「机器接口」，不产出 JSON 报告。
        if case .help = outcome.action {
            emit(usage)
            return 0
        }

        // 报告目标要排除在 PNG 的候选名之外：否则
        // `--out shot.png --json-out shot-2.png`（shot.png 已存在）
        // 会让 PNG 排他到 shot-2.png，随后报告把它覆盖掉。
        let reservedPaths: Set<String> = outcome.jsonOutPath
            .map { [PathIdentity.canonical($0)] } ?? []

        var report: CommandReport
        var exitCode: Int32 = 0

        switch outcome.action {
        case .help:
            // 上面已返回；此分支只为穷尽性
            report = CommandReport.failure("帮助已输出。")

        case .listDisplays:
            report = CommandReport(
                ok: true,
                displays: DisplayCatalog.all()
            )

        case .listDesktops:
            do {
                report = CommandReport(ok: true, desktops: try DesktopCatalog.all())
            } catch {
                report = CommandReport.failure(error.localizedDescription)
                exitCode = 1
            }

        case .listWindows:
            // 窗口**标题**受屏幕录制权限管控：当前进程若没有这个权限，
            // 枚举出的窗口只有应用名、没有标题，而「选哪个窗口」几乎全靠标题。
            //
            // 所以默认同样经 anShot.app 执行（与截图路径同一套授权复用）。
            // `--direct` 明确要求就地运行，此时才退回本进程枚举——那是显式
            // 选择，不是默认。
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
                effective.savePath = defaultOutputPath()
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
        }

        // 报告落盘失败必须让退出码非零，且**替调用方保住产物信息**。
        //
        // 理由：调用方显式要求了 `--json-out`，而在 `open -n` 那种方式下
        // 这个文件是**唯一**的信息通道——它没写成功就等于整个调用没有结果。
        // 若此时仍输出 `ok: true`，调用方会以为报告已就位；
        // 而截图其实已经生成了，所以失败报告里要保留 `capture`（含 savedPath）。
        if let path = outcome.jsonOutPath, !writeReport(report, to: path) {
            report = CommandReport(
                ok: false,
                error: "结果 JSON 写入失败：\(path)。截图本身可能已生成，见 capture.savedPath。",
                displays: report.displays,
                desktops: report.desktops,
                windows: report.windows,
                capture: report.capture
            )
            exitCode = 1
        }

        guard let json = encode(report) else {
            // 序列化失败属于实现缺陷；仍然要让 stdout 上是合法 JSON，
            // 否则脚本会拿到空输出而无法区分「失败」与「工具没跑」。
            emit(#"{"ok":false,"error":"结果序列化失败"}"#)
            emitDiagnostic("结果序列化失败")
            return 1
        }

        // stdout 始终给 JSON（成功与失败都给）；诊断信息走 stderr。
        emit(json)
        if !report.ok, let message = report.error {
            emitDiagnostic(message)
        }

        return exitCode
    }

    /// 统一的「失败出口」。
    ///
    /// 供所有**在解析之前**就失败的情形复用（参数解析错误、模式冲突等），
    /// 保证它们与解析之后的失败在两条通道上表现一致：
    /// stdout 是合法失败 JSON，stderr 是可读诊断。
    ///
    /// - Parameter jsonOutPath: 报告目标。传 `nil` 表示不写文件。
    /// - Returns: 退出码，恒为非零。
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

    /// 该错误是否属于「报告目标本身就是危险目标」。
    ///
    /// 这类失败**不得**再往那个路径写报告：调用方明确要求的正是
    /// 「不要覆盖那个文件」，而失败处理去写它就把初衷破坏了。
    static func isPathConflict(_ error: Error) -> Bool {
        if case .outputPathConflict = (error as? AutomationError) { return true }
        return false
    }

    /// 从参数中尽力取出 `--json-out` 的值。
    ///
    /// 用途：整体解析**失败**时仍要写报告（文档承诺「成功或失败都写」），
    /// 而此时没有解析结果可用。这里只做最朴素的扫描，取不到就放弃——
    /// 它服务于「尽力保留证据」，本身不该产生新的错误。
    static func bestEffortJSONOutPath(arguments: [String]) -> String? {
        let args = Array(arguments.dropFirst())
        guard let index = args.firstIndex(of: "--json-out"),
              index + 1 < args.count else {
            return nil
        }
        let value = args[index + 1]
        return value.hasPrefix("--") ? nil : value
    }


    // MARK: - 默认路径

    /// 未指定 `--out` 时的默认截图路径。
    ///
    /// 带时间戳（秒级）便于人肉辨认；并发调用时若撞名，
    /// 由 `CaptureService` 的排他创建负责换名，故这里不必再查重。
    static func defaultOutputPath(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/\(defaultOutputDirectoryName)/anshot-\(formatter.string(from: now)).png"
    }

    // MARK: - 参数辅助

    /// 摘出「选项 + 值」并返回其值。
    ///
    /// 值以 `--` 开头时视为「选项被当成了值」而报错：
    /// 若不拦，`--out --max-size` 会把字面量 `--max-size` 当作路径，
    /// 错误会推迟到落盘时才以「路径奇怪」的形式暴露，排查成本高得多。
    private static func extractOption(
        _ name: String,
        from args: inout [String]
    ) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard index + 1 < args.count else {
            throw AutomationError.invalidArgument("\(name) 缺少值。")
        }
        let value = args[index + 1]
        guard !value.hasPrefix("--") else {
            throw AutomationError.invalidArgument(
                "\(name) 缺少值（下一个参数是选项「\(value)」）。"
            )
        }
        args.removeSubrange(index...(index + 1))
        return value
    }

    /// 从数组头部取一个选项的值。
    private static func takeValue(
        for option: String,
        from args: inout [String]
    ) throws -> String {
        guard !args.isEmpty else {
            throw AutomationError.invalidArgument("\(option) 缺少值。")
        }
        let value = args.removeFirst()
        guard !value.hasPrefix("--") else {
            throw AutomationError.invalidArgument(
                "\(option) 缺少值（下一个参数是选项「\(value)」）。"
            )
        }
        return value
    }

    /// 解析 `x,y,w,h`。
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
            // NaN / inf 能被 `Double(_:)` 解析出来，但它们在 CGRect 运算里
            // 只会产生难以归因的结果，故在这一并拒掉。
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

    /// 统一用排序键，脚本可依赖字段顺序稳定。
    private static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 把结果写入 `--json-out` 指定的文件。
    ///
    /// - Returns: 是否成功。未指定路径时返回 `true`（没有要求就没失败）。
    @discardableResult
    private static func writeReport(_ report: CommandReport, to path: String?) -> Bool {
        guard let path, !path.isEmpty else { return true }
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
///
/// 一个类型覆盖三种动作，使 stdout 与 `--json-out` 的内容完全一致，
/// 且脚本只需检查 `ok` 字段即可判断成败，不必按动作分支解析。
struct CommandReport: Codable {

    let ok: Bool
    let error: String?
    let displays: [DisplayInfo]?
    let desktops: [DesktopInfo]?
    /// 窗口列表（仅 `--list-windows` 有值）。
    let windows: [WindowInfo]?
    let capture: CaptureOutput?

    /// 显式 init 而不是依赖合成的 memberwise init：
    /// 三个动作各自只填自己那几个字段，其余必须能省略。
    /// （合成的 init 不接受默认值，每次都要写四个 nil，漏一个就是编译错误
    /// 而不是遗漏——但那种噪音会掩盖真正有意义的字段变化。）
    init(
        ok: Bool,
        error: String? = nil,
        displays: [DisplayInfo]? = nil,
        desktops: [DesktopInfo]? = nil,
        windows: [WindowInfo]? = nil,
        capture: CaptureOutput? = nil
    ) {
        self.ok = ok
        self.error = error
        self.displays = displays
        self.desktops = desktops
        self.windows = windows
        self.capture = capture
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
    let region: RegionOutput?
    /// 窗口来源。整屏 / 区域截图为 nil。
    let window: WindowOutput?
    let savedPath: String?

    /// 区域输出。显式列出四个分量，避免 `CGRect` 的编码形式随平台变化。
    struct RegionOutput: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        /// 还原成 `CGRect`。跨进程读回结果时需要它。
        var rect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// 窗口输出。同样显式列分量：跨进程读回时要还原成 `CGRect`。
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

    init(outcome: CaptureOutcome) {
        self.displayId = outcome.displayID
        self.spaceId = outcome.spaceID
        self.pixelWidth = outcome.image.width
        self.pixelHeight = outcome.image.height
        self.sourcePixelWidth = Int(outcome.sourcePixelSize.width)
        self.sourcePixelHeight = Int(outcome.sourcePixelSize.height)
        self.scaleFactor = Double(outcome.scaleFactor)
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
        self.savedPath = outcome.savedURL?.path
    }
}
