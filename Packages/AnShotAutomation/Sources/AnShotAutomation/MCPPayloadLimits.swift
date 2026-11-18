//
//  MCPPayloadLimits.swift
//  AnShotAutomation
//
//  MCP 响应的体量上限。
//
//  ── 为什么需要单独一层 ───────────────────────────────────────
//
//  CLI 把截图画到磁盘，图有多大只影响磁盘；而 MCP 把图**编码进一条
//  JSON-RPC 消息**（PNG → base64，体积再涨约 1/3）。同一条消息要经
//  stdio 传给客户端、被它整条读入内存、再交给模型。
//
//  所以「图能截出来」不等于「能安全地放进响应里」：
//
//      max_size: 0  +  6K 屏  →  6016×3384 ≈ 2000 万像素
//      → 一张细节丰富的 PNG 可达 30 MB 以上
//      → base64 后约 40 MB，压在**一行** JSON-RPC 里
//
//  这不是理论风险：`max_size: 0` 是被文档鼓励的用法（需要原始分辨率时）。
//
//  ── 上限取值 ─────────────────────────────────────────────────
//
//  16 MiB（原始 PNG 字节数，不含 base64 膨胀）。
//  默认 2560 长边的截图实测在 1–6 MB 量级，因此这个上限
//  对**正常用法完全无感**，只拦住「为了原始分辨率而不设限」的极端情形。
//
//  超限时返回的是可操作错误（告诉调用方该做什么），而不是一张
//  可能让对端卡死的巨图。
//

import Foundation

/// MCP 响应体量限制与自适应压缩策略。
enum MCPPayloadLimits {

    /// MCP 截图默认长边像素上限（在清晰度与视觉 Token 间取得平衡）。
    static let defaultMaxLongEdge = 1568

    /// 未显式指定 `format: "png"` 时，触发自动 JPEG 降级的原始 PNG 字节阈值（3.5 MiB）。
    ///
    /// 3.5 MiB 经 base64 编码后约为 4.67 MiB，可稳定控制在 Claude 5 MB 单消息红线之下。
    static let autoJPEGThresholdBytes = 3_670_016

    /// 自动降级为 JPEG 时使用的默认质量（1...100）。
    static let autoJPEGQuality = 82

    /// 图像原始字节数上限（不含 base64 膨胀）。
    static let maximumPayloadBytes = 16 * 1024 * 1024

    /// 向后兼容别名：PNG 原始字节数上限（不含 base64 膨胀）。
    static let maximumPNGBytes = maximumPayloadBytes

    /// 校验图像体量。
    ///
    /// - Parameters:
    ///   - byteCount: 已编码图像字节数。
    ///   - format: 图像编码格式。
    /// - Throws: `AutomationError.invalidArgument` —— 附带上限、实际值与处置建议。
    static func validate(byteCount: Int, format: CaptureImageFormat = .png) throws {
        guard byteCount > maximumPayloadBytes else { return }

        let actualMiB = Double(byteCount) / 1024 / 1024
        let limitMiB = Double(maximumPayloadBytes) / 1024 / 1024

        let formatAdvice = format == .png
            ? "或改用 format: \"jpeg\"（默认 quality=82），"
            : "或降低 quality（如 75），"

        throw AutomationError.invalidArgument(
            String(
                format: "图像过大，无法作为 MCP 响应返回：%.1f MiB，上限 %.0f MiB。",
                actualMiB,
                limitMiB
            )
            + "请设置 max_size（例如 1568）限制长边、\(formatAdvice)或缩小 region 只截需要的部分。"
            + "（需要原始分辨率的图请改用命令行 --capture --max-size 0 --out <路径>，"
            + "那条路径写磁盘，不受本节限制。）"
        )
    }

    /// 兼容原有单参数签名。
    static func validate(pngByteCount: Int) throws {
        try validate(byteCount: pngByteCount, format: .png)
    }
}
