import AnShotCore
import Foundation

/// 截图由**谁**执行。
///
/// 这不是一个性能选项，而是权限归属选项——它决定 TCC 把屏幕录制授权
/// 算在哪个进程头上。
public enum CaptureExecution: Sendable, Equatable {

    /// 让 anShot.app 自己执行，复用它**已有的**屏幕录制授权。**这是默认值。**
    ///
    /// 适用于所有「当前进程没有自己的 TCC 身份」的场景：被 AI 宿主 spawn 的
    /// stdio MCP 服务器、终端里跑的 CLI。
    case reuseApplicationAuthorization

    /// 由当前进程直接执行，用当前终端 / AI 宿主的授权。
    ///
    /// 只在两种情况下才需要：调用方已经给当前进程授过权，或者环境里没有可
    /// 启动的 anShot.app（CI、无 GUI 会话）。
    case currentProcess
}

/// 统一的截图入口：决定由谁执行，并统一负责落盘。
///
/// 之所以要有这一层：MCP 与 CLI 对「谁执行截图」必须做出**同一个**判断。
/// 否则两条路径的权限行为会悄悄分叉，而权限行为恰好是本项目最容易出错的地方——
/// 它不产生编译错误，只在特定调用方式下表现为「明明授权了却说没授权」，
/// 且错误信息还会把用户指向错误的授权对象。
public enum CaptureRunner {

    /// 执行一次截图。
    ///
    /// - Parameters:
    ///   - parameters: 截图参数。
    ///   - execution: 由谁执行。
    ///   - reservedOutputPaths: 视为已占用的输出路径（已规范化）。CLI 用它把
    ///     `--json-out` 的目标排除在 PNG 的候选名之外。
    public static func run(
        parameters: CaptureParameters,
        execution: CaptureExecution,
        reservedOutputPaths: Set<String> = []
    ) async throws -> CaptureOutcome {

        // 落盘一律由本层完成，不交给子实例。
        //
        // 原因：子实例不知道父进程的保留路径。若让子实例自己命名，
        // `--out shot.png --json-out shot-2.png`（shot.png 已存在）会让 PNG
        // 排他到 shot-2.png，随后父进程的报告把它覆盖掉——这个缺陷修过一次，
        // 不能在跨进程路径上原样复活，而且它同样不报错、退出码还是 0。
        var captureOnly = parameters
        let requestedSavePath = captureOnly.savePath
        captureOnly.savePath = nil

        let outcome = try await capture(parameters: captureOnly, execution: execution)

        guard let savePath = requestedSavePath, !savePath.isEmpty else {
            return outcome
        }
        let savedURL = try CaptureService.save(
            outcome.pngData,
            to: savePath,
            reservedPaths: reservedOutputPaths
        )
        return outcome.withSavedURL(savedURL)
    }

    // MARK: - 分派

    private static func capture(
        parameters: CaptureParameters,
        execution: CaptureExecution
    ) async throws -> CaptureOutcome {

        if execution == .reuseApplicationAuthorization,
           let appURL = OutOfProcessCapture.currentAppURL {

            return try await OutOfProcessCapture.capture(
                parameters: parameters,
                appURL: appURL,
                timeout: parameters.spaceID == nil ? OutOfProcessCapture.defaultTimeout : 60
            )
        }

        // 走到这里有两种情况，都不需要或无法启动 app：
        //   · 调用方显式要求就地截图（--direct）
        //   · 当前进程不在 .app 里（单测、`swift run`、裸二进制），无从启动自己
        return try await CaptureService.capture(parameters)
    }
}
