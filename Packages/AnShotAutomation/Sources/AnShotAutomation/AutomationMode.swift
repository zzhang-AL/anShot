//
//  AutomationMode.swift
//  AnShotAutomation
//
//  进程启动模式的分流。`main.swift` 在这里决定「起 GUI 还是不起」。
//
//  ── 为什么分流点必须在 AppDelegate 之前 ───────────────────────
//
//  自动化运行的进程**不该有任何界面副作用**：
//
//      - 不装菜单栏图标   —— 否则每被 AI 调用一次就多一个图标
//      - 不注册全局热键   —— 热键是进程级独占资源；同 bundle 的第二个进程
//                            注册会让按键流向不确定（这是本项目已实测过的
//                            现象，见 AppDelegate 中 `isDiagnosticRun` 的注释）
//      - 不创建覆盖层/选区窗口
//
//  这些副作用都在 `applicationDidFinishLaunching` 里发生，所以判断必须在
//  `NSApplication.shared` 被触碰之前完成。一旦 app 实例被创建，
//  即使不 run()，`LSUIElement` 的激活策略也已开始生效。
//
//  ── 与 `--diagnose*` 的关系 ──────────────────────────────────
//
//  已有的 `CaptureDiagnostics` 是 **Debug 专属**的开发自检入口，
//  它的产物是给人看的日志。本模式是**发布版也带着**的外部接口，
//  产物是给机器用的 JSON / 图像。两者目的不同，故不合并：
//  把对外接口关进 `#if DEBUG` 会让 Release 包失去这个能力。
//

import CoreGraphics
import Foundation

/// 启动模式。
///
/// `Sendable` 是必需的：`runBlocking` 会在 detached task 里使用它，
/// 而非 Sendable 的值无法跨并发域传递。
public enum AutomationMode: Equatable, Sendable {

    /// 以 MCP stdio 服务端运行。
    case mcp

    /// 以命令行工具运行。携带原始参数交给 `CommandLineInterface` 解析。
    case commandLine([String])
}

/// 模式识别与运行。
public enum AutomationRunner {

    /// 命令行选项全集。用于识别「这是自动化调用」而非 GUI 启动。
    ///
    /// 刻意不做成「凡是不认识的参数就当 CLI」：GUI 启动也可能带参数
    /// （macOS 会附加 `-psn_...` 之类的系统参数），把它们误判成 CLI
    /// 会让用户双击应用时得到一个莫名其妙的报错。
    private static let cliOptions: Set<String> = [
        "--capture", "--list-displays", "--list-desktops", "--list-windows", "--help", "-h",
        "--display", "--space", "--switch-desktop", "--region", "--window", "--app",
        "--max-size", "--out", "--json-out",
        "--direct", "--via-app"
    ]

    /// 识别启动模式。
    ///
    /// - Parameter arguments: 完整 `CommandLine.arguments`（含可执行文件路径）。
    /// - Returns: 自动化模式；`nil` 表示按 GUI 正常启动。
    /// - Throws: `AutomationError.invalidArgument` —— `--mcp` 与其它选项混用。
    ///
    /// ── 为什么混用必须在**这里**拒绝 ────────────────────────────
    ///
    /// 曾经的实现是「见到 `--mcp` 就进 MCP 模式」，于是 `--mcp --capture`
    /// 被静默当成纯 MCP 启动，CLI 解析器里那条「--mcp 不能与其它选项同时使用」
    /// 的检查**永远不可达**——测试测的是一个生产路径到不了的函数。
    /// 调用方（或 AI）写下两个意图明确的参数却只得到一个的效果，
    /// 是比报错更糟的失败方式。
    public static func detect(from arguments: [String]) throws -> AutomationMode? {
        let rest = Array(arguments.dropFirst())

        let wantsMCP = rest.contains("--mcp")
        let wantsCLI = rest.contains(where: { cliOptions.contains($0) })

        if wantsMCP {
            // `--help` 与 `--mcp` 并存时也一样拒绝：此时「用户想看的到底是
            // 命令行帮助还是 MCP 服务」没有正确答案，不能让实现替调用方猜。
            guard !wantsCLI else {
                throw AutomationError.invalidArgument(
                    "--mcp 不能与其它选项同时使用（同时收到："
                    + rest.filter { cliOptions.contains($0) }.joined(separator: " ")
                    + "）。--mcp 会以 stdio 服务端独占运行，不执行截图命令。"
                )
            }
            return .mcp
        }

        if wantsCLI {
            return .commandLine(arguments)
        }

        return nil
    }

    /// 入口级失败的统一出口。供 `main.swift` 在分流阶段使用。
    ///
    /// 与 CLI 内部的失败出口共用同一套通道约定（stdout 是合法失败 JSON、
    /// stderr 是可读诊断），只是退出码用 2：命令行**用法错误**
    /// （如 `--mcp` 与截图选项混用）与「命令跑起来了但失败」是两类不同的事，
    /// 调用方应当能区分。
    ///
    /// 这里不写 `--json-out`：走到这条路径时参数整体已不可信，
    /// 从中挑一个路径去写文件并不比不写更安全。
    ///
    /// - Returns: `exitCode`（默认 2）。
    public static func emitEntryFailure(
        _ message: String,
        exitCode: Int32 = 2
    ) -> Int32 {
        _ = CommandLineInterface.emitFailure(message)
        return exitCode
    }

    /// 同步执行一个模式并返回退出码。
    ///
    /// ── 同步桥接的理由 ──────────────────────────────────────
    ///
    /// `main.swift` 的顶层代码不能是 `async`，而捕获与 MCP 都是异步的。
    /// 这里用「detached task 执行 + 主线程等待」桥接：
    ///
    ///     为什么不跑在主线程上：`ScreenCaptureKit` 的异步 API
    ///     与 `StreamCapturer` 的帧回调都不要求主线程（后者用的是
    ///     自建的 DispatchQueue），放进 detached task 不会阻塞任何调度。
    ///
    ///     为什么不泵 run loop：本路径不创建任何 AppKit 窗口，
    ///     没有 run loop 需要驱动；泵一个空 run loop 只会引入
    ///     与退出时机相关的额外不确定性。
    public static func runBlocking(_ mode: AutomationMode) -> Int32 {
        let box = ExitCodeBox()
        let done = DispatchSemaphore(value: 0)

        Task.detached(priority: .userInitiated) {
            let code = await execute(mode)
            box.set(code)
            done.signal()
        }

        done.wait()
        return box.value
    }

    /// 执行模式，返回退出码。
    private static func execute(_ mode: AutomationMode) async -> Int32 {
        switch mode {
        case .mcp:
            do {
                try await AnShotMCP.run()
                return 0
            } catch {
                writeStderr("MCP 服务运行失败：\(error.localizedDescription)")
                return 1
            }

        case .commandLine(let arguments):
            let parsed: Outcome
            do {
                parsed = try CommandLineInterface.parse(arguments: arguments)
            } catch {
                let message = (error as? AutomationError)?.localizedDescription
                    ?? "参数解析失败：\(error.localizedDescription)"

                // 解析失败也要写 `--json-out`：文档承诺「成功或失败都写」，
                // 而参数错误恰恰是最需要落盘取证的一类失败
                // （`open -n` 那种调用方式下 stdout/stderr 都会被丢掉）。
                //
                // 但**路径冲突**这类失败例外：调用方明确要求「别覆盖那个文件」，
                // 失败处理再把报告写上去就把初衷破坏了，所以目标传 nil。
                let reportPath = CommandLineInterface.isPathConflict(error)
                    ? nil
                    : CommandLineInterface.bestEffortJSONOutPath(arguments: arguments)

                return CommandLineInterface.emitFailure(message, jsonOutPath: reportPath)
            }

            return await CommandLineInterface.run(parsed)
        }
    }

    // MARK: - 输出通道

    /// MCP 分支的启动失败出口。
    ///
    /// MCP 模式下 stdout 是**协议通道**，绝不能被诊断文字污染，
    /// 所以这里只写 stderr。（CLI 分支的失败统一走
    /// `CommandLineInterface.emitFailure`。）
    private static func writeStderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// 跨并发域传递退出码的小容器。
///
/// 用锁而非 `actor`：`runBlocking` 需要在**同步**上下文里读取结果，
/// 而访问 actor 的属性必须是 `await`。
private final class ExitCodeBox: @unchecked Sendable {

    private let lock = NSLock()
    private var stored: Int32 = 1

    var value: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ code: Int32) {
        lock.lock()
        stored = code
        lock.unlock()
    }
}
