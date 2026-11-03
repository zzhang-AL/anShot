//
//  ScrollshotFrameRecorder.swift
//  AnShotUI
//
//  诊断（仅 DEBUG）：把长截图会话中**值得复盘的那几帧原始画面**落盘。
//
//  ── 为什么需要它 ──────────────────────────────────────────
//
//  「拼出来的长图有重复 / 有缺失」这类问题**没法用合成数据复现**。真实帧里带着
//  滚动条、光标、终端固定边框、TUI 的加载动画——这些东西在拼接完成的长图里
//  **已经消失**，所以拿结果图往回推只能靠猜：
//
//  * 从长图裁帧来测配准，测到的是「理想输入」下的表现（实测全部正确），
//    测不出真实采集时那些干扰区域的影响；
//  * 而配准失败恰恰常常由这些区域引起（它们与页面内容的移动速度不同）。
//
//  只有把原始帧留下来，才能复盘「那一帧到底配准成了什么」。
//
//  ── 两种模式，都是运行时开关（不再依赖 DEBUG 构建）────────
//
//      open -n anShot.app --args -recordFrames      # 只记可疑帧
//      open -n anShot.app --args -recordAllFrames   # 全帧 + 逐帧日志
//
//  全帧模式的用途：「最终长图有错位」这类问题的定位需要**正常帧也留下来** ——
//  错位可能发生在两帧都「看起来正常」的接缝上，只留可疑帧就回放不出那一段。
//  成本：一帧 2940×1774 的 RGBA 是 20 MB，PNG 后仍有数 MB，一场 240 帧可能写掉
//  几个 GB，只在定位问题时开。
//
//  ── 为什么不是编译期开关（实测数字）───────────────────────
//
//  Debug 构建（-Onone）一次配准 **437ms**、一次预览 81ms，而抓帧间隔只有 125ms ——
//  用它做日常长截图必然卡顿，且这些开销都在 MainActor 上；Release 下同样的代码是
//  **24.7ms / 0.7ms**。若把记录能力绑在 `#if DEBUG` 上，「流畅」与「可诊断」就
//  不可兼得。改成运行时开关后两者都能要。
//
//  ── 为什么默认只记可疑帧 ──────────────────────────────────
//
//  一帧 2940×1912 的 RGBA 缓冲是 22 MB，整场 240 帧就是 5 GB——不可能全留。
//  而真正需要复盘的是**被丢弃或被仲裁的帧**（duplicate / transient / rewind /
//  unresolved / 由 Vision 翻案），它们才是问题现场。所以只记这些，并限总数。
//
//  写盘放在后台队列：PNG 编码一帧要几十毫秒，留在采集线程上会拖慢 8Hz 采样。
//

import AnShotCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 把长截图会话的可疑帧落盘，供事后复盘。
@MainActor
final class ScrollshotFrameRecorder {

    /// 单场最多落盘的帧数，避免长会话把磁盘写满（全帧模式不受此限）。
    private static let maxRecords = 60

    /// 是否落盘**全部**帧，由 `-recordAllFrames` 参数或 `ANSHOT_RECORD_ALL_FRAMES=1` 开启。
    ///
    /// 用于让用户复现一次真实故障后离线重放——只留可疑帧时，发生在两个
    /// 「看起来正常」的帧之间的接缝错位是回放不出来的。
    /// 参数方式更可靠：`open -n app --args -recordAllFrames` 一定能传到，
    /// 而 `open` 启动的进程不保证继承 shell 的环境变量。
    static var recordsAllFrames: Bool {
        ProcessInfo.processInfo.environment["ANSHOT_RECORD_ALL_FRAMES"] == "1"
            || CommandLine.arguments.contains("-recordAllFrames")
    }

    /// 是否**开启记录**（至少记可疑帧），由 `-recordFrames` 开启。
    ///
    /// ── 为什么从 `#if DEBUG` 改成运行时开关 ────────────────────
    /// Debug 构建（-Onone）下一次配准要 **437ms**、一次预览 81ms，而抓帧间隔
    /// 只有 125ms——用它做日常长截图会明显卡顿，而且这些开销全在 MainActor 上。
    /// Release 下同样的代码是 **24.7ms / 0.7ms**。可若要留证据就只能跑 Debug，
    /// 二者不可兼得。改成运行时开关后：日常用 Release（流畅），需要复盘时
    /// 加一个参数即可（PNG 编码本来就在后台队列上，不占采集路径）。
    static var isEnabled: Bool {
        recordsAllFrames || CommandLine.arguments.contains("-recordFrames")
    }
    /// 写盘队列：采集线程只做一次数据投递，不等待 PNG 编码。
    private static let queue = DispatchQueue(label: "com.anshot.scrollshot-frames", qos: .utility)

    private static var directory: URL?
    private static var logURL: URL?
    private static var recorded = 0

    private static let logger = AnShotLog.scrollshotFrames
    /// 开始一次记录。目录形如 `$TMPDIR/anshot-scrollshot-frames/<时间戳>/`。
    ///
    /// 未开启记录时什么都不做——后续 `record` 会因为目录为空而直接返回，
    /// 调用方不需要在每帧上判断开关（代价是一次静态属性读取）。
    static func begin() {
        guard isEnabled else { return }
        recorded = 0
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-scrollshot-frames", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
        // 先落到局部量再用：`logURL` 是可选属性，直接 `logURL!.path`
        // 要在一行内同时完成赋值与强解，可读性差且解包点未被局部上下文约束。
        let framesLog = url.appendingPathComponent("frames.log")
        logURL = framesLog
        FileManager.default.createFile(atPath: framesLog.path, contents: nil)
        logger.notice("[scrollshot-frames] 原始帧目录 \(url.path, privacy: .public)")
    }

    /// 记录一帧。`note` 是诊断行（verdict、delta、置信度、是否由 Vision 翻案等）。
    ///
    /// - Parameter saveImage: 是否同时落盘画面。整体不重复的帧只需要行日志。
    static func record(_ image: ScrollshotImage, index: Int, note: String, saveImage: Bool) {
        guard let directory, let logURL else { return }
        let line = "[\(String(format: "%03d", index))] \(note)\n"
        let frameURL = directory.appendingPathComponent(String(format: "%03d.png", index))

        // 全帧模式：无视可疑判定，逐帧落盘（也不受 maxRecords 限制，
        // 因为开启它的目的就是要拿到完整会话）。
        let writeBoth = (saveImage || recordsAllFrames) && (recordsAllFrames || recorded < maxRecords)
        if writeBoth { recorded += 1 }

        // 只在后台队列里碰文件与 PNG 编码。
        queue.async {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }
            guard writeBoth, let cgImage = image.makeCGImage() else { return }
            guard let destination = CGImageDestinationCreateWithURL(
                frameURL as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { return }
            CGImageDestinationAddImage(destination, cgImage, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    /// 诊断进程退出前等待已有写盘任务，避免最终几帧仍在队列中就退出。
    static func flush() async {
        guard isEnabled else { return }
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// 结束记录。返回目录路径，供诊断报告。
    @discardableResult
    static func finish() -> URL? {
        let url = directory
        directory = nil
        logURL = nil
        if let url {
            logger.notice("[scrollshot-frames] 记录结束 \(url.path, privacy: .public)（画面 \(recorded) 张）")
        }
        return url
    }
}
