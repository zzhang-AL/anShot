//
//  GIFExporter.swift
//  AnShotCapture
//
//  把录制的影片转换为 GIF。
//
//  ── 为何是「两段式」而不是边录边拼 ────────────────────────────
//
//  录制阶段照常**流式写入临时影片**（帧收到即编码即写盘），导出阶段再从临时文件
//  **逐帧解码 → 立即写入 GIF → 释放**。
//
//  反过来做（录制时把每帧 `CGImage` 累积进数组）在 800×600 / 12 fps / 15 秒下
//  约需 180 帧 × 1.9 MB ≈ **342 MB** 常驻内存，且随时长线性增长。
//  两段式的峰值 ≈ 单帧位图 + 编码器内部缓冲，与时长无关。
//
//  ── 关于「15 秒 / 800px」的性质 ──────────────────────────────
//
//  这两个默认值是**产品默认值而非内存强制的硬上限**：
//  `CGImageDestination` 支持逐帧追加，无需预先知道帧数也不要求全部帧驻留
//  （`model.md` §4.5 的修订记录）。真正的硬约束只有「源帧必须落盘」这一条。
//

import AnShotCore
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let gifLogger = AnShotLog.recording
enum GIFExporter {

    /// 把影片转换为 GIF。
    ///
    /// - Parameters:
    ///   - movieURL: 录制产物（临时影片）。
    ///   - gifURL: 目标 GIF 路径。
    ///   - settings: GIF 设置（帧率、时长上限、尺寸上限、循环次数）。
    ///   - progress: 进度回调（0…1），在任意线程调用。
    /// - Returns: 实际写入的 GIF 信息。
    static func export(
        movieURL: URL,
        to gifURL: URL,
        settings: GIFSettings,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (url: URL, pixelSize: CGSize, frameCount: Int) {
        let asset = AVURLAsset(url: movieURL)
        let duration: TimeInterval
        do {
            duration = try await asset.load(.duration).seconds
        } catch {
            throw RecordingError.gifExportFailed("无法读取临时影片：\(error.localizedDescription)")
        }
        guard duration > 0 else {
            throw RecordingError.gifExportFailed("临时影片时长为零，无法导出 GIF")
        }

        // 时长上限：超长影片只取前 N 秒（产品默认值，见文件头说明）
        let effectiveDuration = min(duration, max(0.1, settings.maximumDuration))
        let frameRate = max(1, settings.frameRate)
        let frameCount = max(1, Int((effectiveDuration * Double(frameRate)).rounded(.down)))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 取帧精度：允许半帧误差，否则每帧都要精确解码、耗时显著上升
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(frameRate * 2))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // 尺寸上限：等比缩小（`maximumSize` 本身即等比约束）
        let maximumDimension = CGFloat(max(1, settings.maximumPixelDimension))
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)

        if FileManager.default.fileExists(atPath: gifURL.path) {
            try? FileManager.default.removeItem(at: gifURL)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            gifURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw RecordingError.gifExportFailed("无法创建 GIF 输出：\(gifURL.path)")
        }

        // 文件级属性：循环次数
        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: settings.loopCount
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        // 帧级属性：帧间隔。GIF 无音频，帧率过高会让体积爆炸。
        //
        // 间隔按「这一帧实际占了几个采样格」给出，而不是固定 1/帧率：
        // 相同的相邻帧会合并、取帧失败的格会并入前一帧（见 `GIFFrameTimeline`），
        // 两者都必须把省下的时长还给保留下来的那一帧，否则 GIF 会整体变快。
        let slotDuration = 1.0 / Double(frameRate)
        var timing = GIFFrameTiming(frameRate: frameRate, totalSlots: frameCount, duration: effectiveDuration)

        var outputPixelSize = CGSize.zero
        var writtenFrames = 0
        var failedSlots = 0
        var timeline = GIFFrameTimeline<GIFSourceFrame>(isSame: { $0.hasSamePixels(as: $1) })
        func write(_ emitted: (frame: GIFSourceFrame, slots: Int)?) {
            guard let emitted else { return }
            CGImageDestinationAddImage(destination, emitted.frame.image, timing.properties(slots: emitted.slots))
            writtenFrames += 1
        }

        let start = Date()
        // 进度只在**整百分比**变化时上报。
        //
        // 逐帧上报（12fps × 60 秒 = 720 次）会把高频回调一路播到主线程去改 label，
        // 界面只会得到无意义的重绘与抖动。量化在这里做，跨层传的就一定是「可见的变化」。
        var lastReportedPercent = -1

        // 批量取帧：一次提交全部时间点，由生成器顺序解码，
        // 而不是每帧单独 `image(at:)`——后者每次都要重新定位到最近的关键帧再解码。
        let times = (0..<frameCount).map { index in
            CMTime(seconds: Double(index) * slotDuration, preferredTimescale: 600)
        }
        var processed = 0
        for await result in generator.images(for: times) {
            // 以请求时间换回格序号，不依赖结果的到达顺序与计数。
            let index = min(
                frameCount - 1,
                max(0, Int((result.requestedTime.seconds / slotDuration).rounded()))
            )
            processed += 1
            do {
                let image = try result.image
                if outputPixelSize == .zero {
                    outputPixelSize = CGSize(width: image.width, height: image.height)
                }
                write(timeline.accept(GIFSourceFrame(image), at: index))
            } catch {
                // 单帧失败（例如影片末尾越界）不应让整个导出失败：
                // 该格的时长并入前一帧，GIF 仍可用且总时长不变。
                failedSlots += 1
                gifLogger.error("GIF 取帧失败（index=\(index, privacy: .public)）：\(error.localizedDescription, privacy: .public)")
            }

            let percent = min(100, processed * 100 / frameCount)
            if percent != lastReportedPercent {
                lastReportedPercent = percent
                // 上报**量化后的值**，而不是帧分数（k/frameCount）。
                //
                // 两者不相等时，门控（截断）与界面显示（四舍五入）就各有各的算法，
                // 而契约也说不清进度到底是什么粒度。上报 1% 粒度的值后，
                // 「回调值 = 界面显示的值」是个可以直接断言的事实。
                progress?(Double(percent) / 100)
            }
        }
        write(timeline.finish(totalSlots: frameCount))

        guard writtenFrames > 0 else {
            throw RecordingError.gifExportFailed("临时影片中没有可解码的帧")
        }

        guard CGImageDestinationFinalize(destination) else {
            throw RecordingError.gifExportFailed("GIF 编码失败")
        }

        // 终值必达：最后一帧若未跨越百分比边界（如整除后停在 99），
        // 进度会停在那里——界面此时正处在「生成 GIF…」文案上，不补上就等于永远差一点。
        //
        // 但**已到 100 就不能再报一次**：重复值会让「进度严格递增」这条契约不成立
        // （实测：22 帧时最后一帧正好落在 100%，补报就产生了两个 100%）。
        if lastReportedPercent != 100 {
            progress?(1.0)
        }

        gifLogger.notice("""
            GIF 导出完成：frames=\(writtenFrames, privacy: .public)/\(frameCount, privacy: .public) \
            failed=\(failedSlots, privacy: .public) \
            duration=\(String(format: "%.2f", effectiveDuration), privacy: .public)s \
            pixel=\(Int(outputPixelSize.width), privacy: .public)x\(Int(outputPixelSize.height), privacy: .public) \
            耗时=\(String(format: "%.2f", Date().timeIntervalSince(start)), privacy: .public)s
            """)

        return (url: gifURL, pixelSize: outputPixelSize, frameCount: writtenFrames)
    }
}

// MARK: - 帧时间轴

/// GIF 延迟以百分之一秒保存。按累计终点取整，避免逐帧取整让长 GIF 越播越快。
struct GIFFrameTiming {
    let frameRate: Int
    let totalSlots: Int
    let duration: TimeInterval
    private var emittedSlots = 0
    private var emittedCentiseconds = 0

    init(frameRate: Int, totalSlots: Int, duration: TimeInterval) {
        self.frameRate = frameRate
        self.totalSlots = totalSlots
        self.duration = duration
    }

    mutating func properties(slots: Int) -> CFDictionary {
        emittedSlots += slots
        // 最后一帧承接不足一个采样格的尾段，保留实际播放总时长。
        let end = emittedSlots >= totalSlots ? duration : min(duration, Double(emittedSlots) / Double(frameRate))
        let targetCentiseconds = Int((end * 100).rounded())
        let delayCentiseconds = max(1, targetCentiseconds - emittedCentiseconds)
        emittedCentiseconds += delayCentiseconds
        let delay = Double(delayCentiseconds) / 100
        return [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delay,
                kCGImagePropertyGIFUnclampedDelayTime as String: delay
            ]
        ] as CFDictionary
    }
}

/// 把逐格取样的结果合成为「帧 + 占用格数」的序列。
///
/// 两条规则，目的都是**保持总时长不变**：
///
/// * 与上一帧像素完全相同的帧不另写一帧，而是延长上一帧（静止画面多时体积显著下降）；
/// * 取帧失败的格并入上一帧；开头就失败的格并入第一个成功的帧。
///
/// 纯逻辑、与 ImageIO 无关，单独抽出来是为了能直接测「时长守恒」。
struct GIFFrameTimeline<Frame> {

    private let isSame: (Frame, Frame) -> Bool
    private var pending: (frame: Frame, startSlot: Int)?

    init(isSame: @escaping (Frame, Frame) -> Bool) {
        self.isSame = isSame
    }

    /// 接收第 `slot` 格的帧。返回因此而**定稿**的上一帧及其占用格数。
    mutating func accept(_ frame: Frame, at slot: Int) -> (frame: Frame, slots: Int)? {
        guard let current = pending else {
            // 从 0 起算：开头失败的格归第一帧所有，否则 GIF 会比影片短。
            pending = (frame, 0)
            return nil
        }
        if isSame(current.frame, frame) {
            return nil
        }
        // 乱序或重复的格号不应产生非正的时长。
        guard slot > current.startSlot else { return nil }
        pending = (frame, slot)
        return (current.frame, slot - current.startSlot)
    }

    /// 收尾：定稿最后一帧，它一直占到第 `totalSlots` 格为止。
    mutating func finish(totalSlots: Int) -> (frame: Frame, slots: Int)? {
        guard let current = pending else { return nil }
        pending = nil
        return (current.frame, max(1, totalSlots - current.startSlot))
    }
}

/// 一帧 GIF 源图，附带用于判等的像素字节。
///
/// 判等只用**逐字节完全相同**：这里的目的是合并静止画面，宁可漏合并也不能误合并
/// （误合并会直接丢掉画面变化）。
struct GIFSourceFrame {

    let image: CGImage
    private let pixels: Data?

    init(_ image: CGImage) {
        self.image = image
        self.pixels = image.dataProvider?.data as Data?
    }

    func hasSamePixels(as other: GIFSourceFrame) -> Bool {
        guard image.width == other.image.width,
              image.height == other.image.height,
              image.bytesPerRow == other.image.bytesPerRow,
              image.bitmapInfo == other.image.bitmapInfo,
              let pixels, let otherPixels = other.pixels else {
            return false
        }
        return pixels == otherPixels
    }
}
