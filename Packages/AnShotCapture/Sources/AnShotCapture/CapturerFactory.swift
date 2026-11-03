//
//  CapturerFactory.swift
//  AnShotCapture
//
//  按运行时的系统版本选择捕获实现。
//
//  集中在一处判断，避免 `#available` 散落在调用方——
//  调用方只应看到 `ScreenCapturing` 协议，不应知道自己跑在哪个实现上。
//
//  两个实现同时存在的原因：`SCScreenshotManager` 是 macOS 14.0+，
//  而部署基线为 13.0，故低版本必须走 `SCStream` 抓首帧。
//  详见 docs/m1-capture/plan.md §3.1。
//

import Foundation

public enum CapturerFactory {

    /// 为当前运行的系统选择捕获实现。
    ///
    /// - macOS 14.0 及以上：`ScreenshotCapturer`（`SCScreenshotManager`，单帧专用）
    /// - macOS 13.0：`StreamCapturer`（`SCStream` 抓首帧）
    public static func makeDefault() -> any ScreenCapturing {
        if #available(macOS 14.0, *) {
            return ScreenshotCapturer()
        } else {
            return StreamCapturer()
        }
    }

    /// 强制指定实现，用于验证非当前系统版本才走的分支。
    ///
    /// 开发机为 macOS 27，`makeDefault()` 永远返回 `ScreenshotCapturer`，
    /// `StreamCapturer` 的代码路径不会被执行。此入口让该路径可被真实验证，
    /// 而不是只停留在「能编译」。
    public enum Implementation: String, Sendable {
        case screenshotManager
        case stream
    }

    public static func make(_ implementation: Implementation, timeout: TimeInterval = 3.0) -> any ScreenCapturing {
        switch implementation {
        case .screenshotManager:
            if #available(macOS 14.0, *) {
                return ScreenshotCapturer()
            } else {
                // 该分支在 13.0 上不可用，回退到基线实现
                return StreamCapturer(timeout: timeout)
            }
        case .stream:
            return StreamCapturer(timeout: timeout)
        }
    }

    #if DEBUG
    /// 诊断：对比获取可共享内容的几种方式的耗时。
    ///
    /// 保留理由：该参数的选择直接决定捕获延迟的量级（实测相差 225 倍）。
    ///
    /// **调用它会预热系统状态**，因此不得在测量「首次捕获」之前调用，
    /// 否则测出的「冷启动」不成立。
    public static func benchmarkShareableContentCost() async {
        await CaptureSetup.benchmarkShareableContentCost()
    }
    #endif
}
