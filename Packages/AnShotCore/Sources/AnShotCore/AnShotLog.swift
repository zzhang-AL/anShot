//
//  AnShotLog.swift
//  AnShotCore
//
//  全应用统一的日志入口。
//
//  ── 为什么需要它 ──────────────────────────────────────────────
//
//  改造前，22 个文件各自写了一遍：
//
//      private let xxxLogger = Logger(subsystem: "com.anshot.app", category: "…")
//
//  带来三个具体问题：
//
//  1. **subsystem 字符串硬编码 22 次**。改一次 bundle ID（或想换成可配置的
//     测试用 subsystem）要动 22 个文件，且漏掉一处不会有任何编译错误——
//     只会在运维侧表现为「某几条日志用 log show 过滤不到」。
//  2. **category 名风格不一致**：`launchAtLogin`（小驼峰）与
//     `recording-ui` / `scrollshot-frames`（短横线）混用。过滤日志时
//     要记住每个文件各用哪种写法。
//  3. **无法一眼看全**：想知道「本应用一共哪些 category」必须全仓 grep。
//
//  ── 为什么放在 AnShotCore 而不是各模块自己一份 ─────────────────
//
//  `AnShotCapture` 与 `AnShotUI` 都产出日志，而两者共同依赖 `AnShotCore`。
//  各建一份会让 subsystem 重复定义、category 再次分裂，等于把问题搬了个位置。
//
//  ── 使用方式 ──────────────────────────────────────────────────
//
//  保持各文件原有的局部名字，只把右边换成这里的常量：
//
//      private let logger = AnShotLog.overlay
//      private let recorderLogger = AnShotLog.recording
//
//  这样文件内所有 `logger.notice(…)` 调用点**无需改动**——集中化
//  不应以重写调用点为代价。
//
//  ⚠️ category 名是运维可见的接口（`log show --predicate 'category == "…"'`）。
//  改动它会使已有的过滤命令失效，因此这里的取值经过核对：
//  `docs/` 与 `tools/` 中只引用了 `capture`，其余无外部依赖。
//  唯一的规范化改动是 `launchAtLogin` → `launch-at-login`。
//

import os

/// 全应用统一的日志入口。
///
/// 只定义 `Logger` 常量，不含任何逻辑；调用方拿到的仍是标准 `os.Logger`，
/// 故既有的 `privacy:` 标注、多行日志等用法全部保持不变。
public enum AnShotLog {

    /// 日志子系统。
    ///
    /// 取值与 App 的 bundle ID 一致，便于：
    ///     log show --predicate 'subsystem == "com.anshot.app"' --last 5m
    public static let subsystem = "com.anshot.app"

    // MARK: - 捕获

    /// 单帧捕获、录制范围装配、屏幕圆角探测。
    public static let capture = Logger(subsystem: subsystem, category: "capture")

    // MARK: - 录制

    /// 录制流水线：流录制、素材写入、麦克风、GIF 导出。
    public static let recording = Logger(subsystem: subsystem, category: "recording")

    /// 录制界面（控制条、准备面板、范围框）。
    ///
    /// 与 `recording` 分开的理由：排查「按了开始却没录上」时，
    /// 界面侧的日志会淹没流水线侧的日志，两者需要能独立过滤。
    public static let recordingUI = Logger(subsystem: subsystem, category: "recording-ui")

    // MARK: - 文字与翻译

    /// 文字识别（OCR）的框架调用细节。
    public static let translation = Logger(
        subsystem: subsystem,
        category: "translation"
    )

    /// 翻译提供者的选择与失败（本机 / 云端）。
    public static let translationProvider = Logger(
        subsystem: subsystem,
        category: "translation-provider"
    )

    // MARK: - 覆盖层与编辑

    /// 覆盖层会话与底图生命周期。
    public static let overlay = Logger(subsystem: subsystem, category: "overlay")

    /// 滚动截图。
    public static let scrollshot = Logger(subsystem: subsystem, category: "scrollshot")

    /// 滚动截图原始帧记录（`ScrollshotFrameRecorder` 专用，默认关闭）。
    public static let scrollshotFrames = Logger(
        subsystem: subsystem,
        category: "scrollshot-frames"
    )

    /// 贴图（Pin）。
    public static let pin = Logger(subsystem: subsystem, category: "pin")

    /// 历史记录。
    public static let history = Logger(subsystem: subsystem, category: "history")

    // MARK: - 应用级

    /// 应用生命周期、菜单栏、通知分发。
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")

    /// 全局热键注册与冲突。
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")

    /// 设置窗口与设置持久化。
    public static let settings = Logger(subsystem: subsystem, category: "settings")

    /// 开机自启动。
    ///
    /// 注意这里的 category 用短横线（原为 `launchAtLogin` 小驼峰）：
    /// 全应用统一为短横线风格，避免过滤时要记住每个文件各用哪种写法。
    public static let launchAtLogin = Logger(
        subsystem: subsystem,
        category: "launch-at-login"
    )

    /// 命令行诊断（仅 Debug 构建存在）。
    public static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")

    /// 自动化接口（MCP 服务端与命令行截图）。
    public static let automation = Logger(subsystem: subsystem, category: "automation")
}
