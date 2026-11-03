//
//  OutputPath.swift
//  AnShotCore
//
//  产物路径的唯一化。
//
//  ── 为什么需要它 ─────────────────────────────────────────────
//
//  录制产物的文件名带时间戳，但只精确到**秒**；而两个写入器在启动时
//  都会「存在同名文件则先删掉再写」（`MovieWriter` 的注释原文：
//  「AVAssetWriter 不会覆盖已存在的文件，必须先删除」）。
//  于是「按下停止 → 立刻再录一次」会让第一次的录像**无声消失**——
//  这不是理论风险：`-diagnoseRecording` 的既有场景就是轮间零延迟。
//
//  因此「产物路径不得覆盖已存在文件」被立为不变量，本类型是它的唯一实现。
//  放在 `AnShotCore` 而非界面层的原因：`AnShotUI` 没有测试 target，
//  而这里恰好是边界条件最密集、最适合单测的那类逻辑。
//

import Foundation

/// 产物路径工具。
public enum OutputPath {

    /// 序号尝试上限。
    ///
    /// 只为「不覆盖」这条不变量兜底：真正用完 999 个序号的目录，
    /// 继续加序号也只是把一个坏局面拖得更久。
    public static let maximumAttempts = 999

    /// 为 `base` 找一个不会被覆盖的路径。
    ///
    /// 已存在时追加序号：`a.gif` → `a-2.gif` → `a-3.gif`……
    /// 序号从 **2** 起：第一个候选默认就是原路径，写 `-1` 只会让命名多一个空档。
    ///
    /// - Parameters:
    ///   - base: 期望路径。不存在时**原样返回**。
    ///   - fileExists: 存在性判据。注入以便单测不触碰真实文件系统。
    /// - Returns: 未被占用的路径。序号空间用尽时退化为 UUID 后缀，
    ///   以保证「绝不覆盖」优先于「命名好看」。
    public static func unique(
        base: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        guard fileExists(base) else { return base }

        for attempt in 1...maximumAttempts {
            let candidate = candidate(for: base, attempt: attempt)
            if !fileExists(candidate) { return candidate }
        }

        return fallbackCandidate(for: base)
    }

    /// GIF 转码失败时的回退影片路径：与 GIF **同目录、同名换 `.mp4`**。
    ///
    /// 同目录是刻意的：用户设了「保存到某文件夹」，被挽救的产物就该出现在那里，
    /// 放进临时目录的「已保留」等于没保留——临时目录会被系统清理。
    ///
    /// - Note: 返回的路径**尚未**唯一化，调用方需再经 `unique(base:)`。
    /// 第 `attempt` 个候选路径：0 为原路径，之后依次为 `-2`、`-3`……
    ///
    /// 「检查后再写」（`unique`）与「排他创建」（`O_EXCL` 的各个调用方）是两种
    /// 占位方式，但**命名规则只能有一套**：否则同一个目录里会同时出现
    /// `a-1.png` 与 `a-2.png` 两种风格，用户无从判断哪张更新。
    public static func candidate(for base: URL, attempt: Int) -> URL {
        guard attempt > 0 else { return base }
        let directory = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent(
            numbered(stem: stem, ext: base.pathExtension, index: attempt + 1)
        )
    }

    /// 序号用尽后的兜底候选：UUID 后缀，保证「绝不覆盖」。
    public static func fallbackCandidate(for base: URL) -> URL {
        let directory = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent(
            numbered(stem: stem, ext: base.pathExtension, index: UUID().uuidString)
        )
    }

    public static func fallbackMovie(forGIFAt gifURL: URL) -> URL {
        gifURL
            .deletingPathExtension()
            .appendingPathExtension(MovieContainer.mp4.fileExtension)
    }

    /// 按扩展名拼序号文件名。
    private static func numbered(stem: String, ext: String, index: Int) -> String {
        numbered(stem: stem, ext: ext, index: String(index))
    }

    /// 按扩展名拼序号文件名（序号可为 UUID 字符串）。
    private static func numbered(stem: String, ext: String, index: String) -> String {
        guard !ext.isEmpty else { return "\(stem)-\(index)" }
        return "\(stem)-\(index).\(ext)"
    }
}
