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

/// MCP 响应体量限制。
enum MCPPayloadLimits {

    /// PNG 原始字节数上限（不含 base64 膨胀）。
    static let maximumPNGBytes = 16 * 1024 * 1024

    /// 校验图像体量。
    ///
    /// - Parameter pngByteCount: 已编码 PNG 的字节数。
    /// - Throws: `AutomationError.invalidArgument` —— 附带上限、实际值与处置建议。
    static func validate(pngByteCount: Int) throws {
        guard pngByteCount > maximumPNGBytes else { return }

        let actualMiB = Double(pngByteCount) / 1024 / 1024
        let limitMiB = Double(maximumPNGBytes) / 1024 / 1024

        throw AutomationError.invalidArgument(
            String(
                format: "图像过大，无法作为 MCP 响应返回：%.1f MiB，上限 %.0f MiB。",
                actualMiB,
                limitMiB
            )
            + "请设置 max_size（例如 2560）限制长边，或缩小 region 只截需要的部分。"
            + "（需要原始分辨率的图请改用命令行 --capture --max-size 0 --out <路径>，"
            + "那条路径写磁盘，不受本节限制。）"
        )
    }
}
