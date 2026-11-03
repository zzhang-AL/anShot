//
//  RealFrameReplayTests.swift
//  AnShotCoreTests
//
//  用**真实采集的帧**复算长截图：把 `$TMPDIR/anshot-scrollshot-frames/<时间戳>/`
//  里的原始帧喂给真正的 `ScrollshotSession`，验证「视口固定带不得被贴进长图」。
//
//  ── 为什么必须有这一层 ────────────────────────────────────
//
//  合成帧能证明实现的语义，但证明不了真实像素上的行为：真实会话里视口顶部的
//  固定带是**纯色**（窗口边框 + 背景），行内对比度为 0，与页面留白在单帧里完全
//  同形 —— 这正是自动检测失效、必须靠 `unusableTopRows` 兜底的场景。
//  「字只有一半」就是在这样的真实数据上被定位的。
//
//  ── 用法 ──────────────────────────────────────────────────
//
//      ANSHOT_REPLAY_DIR=<帧目录> swift test --filter RealFrameReplay
//
//  帧目录来自 DEBUG 会话的全帧模式：
//      open -n anShot.app --args -recordAllFrames
//  未设置环境变量时整个套件跳过，不影响常规测试与 CI。
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AnShotCore

@Suite("真实帧复算 · 视口固定带")
struct RealFrameReplayTests {

    /// 视口顶部固定带的保守下限（与 `ScrollshotController.unusableTopPoints` 同源：
    /// 8 点 × 2 倍屏 = 16 行）。
    private static let declaredUnusableTopRows = 16

    private func frameDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["ANSHOT_REPLAY_DIR"] else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func loadFrames(_ directory: URL) throws -> [ScrollshotImage] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".png") }
            .sorted()
        var frames: [ScrollshotImage] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let image = ScrollshotImage(cgImage) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            frames.append(image)
        }
        return frames
    }

    /// 输出里「整行都是那条固定带色」的行号。
    ///
    /// 真实会话的固定带第 0 行是恒定纯色（实测三通道均值 60、行内 std 0），
    /// 它一旦被当作内容贴进长图，就会在每个采纳帧的段首留下这样一整行。
    /// 用户看到的长图上那是一条凭空多出来的横线，同时该位置的真实内容被顶掉。
    private func bandRows(_ image: ScrollshotImage, channel: Int, value: UInt8) -> [Int] {
        var rows: [Int] = []
        image.withPixels { pixels in
            for y in 0..<image.height {
                let base = y * image.width * 4
                var isBand = true
                for x in 0..<image.width {
                    let index = base + x * 4
                    if abs(Int(pixels[index + channel]) - Int(value)) > 2 {
                        isBand = false
                        break
                    }
                }
                if isBand { rows.append(y) }
            }
        }
        return rows
    }

    /// 读出固定带第一条的颜色（取首帧第 0 行的中位列，避免左右边缘的固定元素）。
    private func bandColor(_ image: ScrollshotImage) -> (red: UInt8, green: UInt8, blue: UInt8) {
        var color: (red: UInt8, green: UInt8, blue: UInt8) = (red: 0, green: 0, blue: 0)
        image.withPixels { pixels in
            let x = image.width / 2
            let index = x * 4
            color = (pixels[index], pixels[index + 1], pixels[index + 2])
        }
        return color
    }

    @Test("诊断：配准在 ignoreTopRows 0 / 16 与无忽略下的差异")
    func overlapAcrossIgnoreTopRows() throws {
        // 目的：确认「视口顶部不可用行」进入配准忽略区后**没有把配准判坏**。
        // 真实会话里出现过相邻两帧内容匹配良好（离线暴力搜索 MAD 0.30）却被报出
        // 一个噪声位移（+426）的情形，需要排除是这一改动造成的。
        guard let directory = frameDirectory() else { return }
        let frames = try loadFrames(directory)
        try #require(frames.count >= 3)
        for index in 1..<min(frames.count, 9) {
            var line = "配对 \(index): "
            for top in [0, 16, 32] {
                var options = VerticalOverlap.Options()
                options.ignoreTopRows = top
                guard let match = try? VerticalOverlap.estimate(
                    previous: frames[index - 1], next: frames[index], options: options
                ) else {
                    line += "| top=\(top) 无解 "
                    continue
                }
                line += String(
                    format: "| top=%d d=%d c=%.3f %@ mr=%.3f ",
                    top, match.deltaY, match.confidence, match.source.rawValue, match.matchRatio
                )
            }
            print("[配准诊断] \(line)")
        }
    }

    @Test("诊断：真实帧下的 submit / 配准 / preview 耗时（卡顿来源量化）")
    func realFrameTimings() throws {
        guard let directory = frameDirectory() else { return }
        let frames = try loadFrames(directory)
        try #require(frames.count >= 6)
        var options = VerticalOverlap.Options()
        options.ignoreTopRows = 16

        var session = ScrollshotSession(options: ScrollStitcher.Options(unusableTopRows: 16))
        var submits: [Double] = []
        for frame in frames.prefix(6) {
            let start = Date()
            session.submit(frame)
            submits.append(Date().timeIntervalSince(start) * 1000)
        }

        var overlaps: [Double] = []
        for index in 1..<min(frames.count, 6) {
            let start = Date()
            _ = try? VerticalOverlap.estimate(
                previous: frames[index - 1], next: frames[index], options: options
            )
            overlaps.append(Date().timeIntervalSince(start) * 1000)
        }

        var previews: [Double] = []
        for _ in 0..<4 {
            let start = Date()
            _ = session.preview(fittingWidth: 168, fittingHeight: 488)
            previews.append(Date().timeIntervalSince(start) * 1000)
        }

        // 放大栏：用户拖动定位框时每帧都要取一段切片，这个耗时直接决定跟不跟手。
        let detailWindow = 0..<min(1000, session.coveredWorldHeight)
        var slices: [Double] = []
        for _ in 0..<4 {
            let start = Date()
            _ = session.slice(worldRows: detailWindow, targetWidth: 688)
            slices.append(Date().timeIntervalSince(start) * 1000)
        }

        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            return String(format: "中位=%.1fms 最大=%.1fms", median, sorted.last ?? 0)
        }
        func samples(_ values: [Double]) -> String {
            values.map { String(format: "%.0f", $0) }.joined(separator: ", ")
        }
        print("[性能诊断] submit(含配准) \(summary(submits)) 样本=[\(samples(submits))]")
        print("[性能诊断] 单次配准        \(summary(overlaps)) 样本=[\(samples(overlaps))]")
        print("[性能诊断] preview(导航168×488) \(summary(previews)) 样本=[\(samples(previews))]")
        print("[性能诊断] slice(放大栏688宽)  \(summary(slices)) 样本=[\(samples(slices))]")
        print("[性能诊断] 帧尺寸 \(frames[0].width)x\(frames[0].height)")
    }

    @Test("真实帧：设了下限后，固定带不再被逐帧贴进长图")
    func fixedBandIsSkippedOnRealFrames() throws {        guard let directory = frameDirectory() else { return }
        let frames = try loadFrames(directory)
        try #require(frames.count >= 3, "帧目录里只有 \(frames.count) 帧")

        // 上滚会话：先看首帧的顶部固定带颜色（第 0 行是恒定纯色）。
        let leadingColor = bandColor(frames[0])

        func run(unusableTopRows: Int) -> ScrollshotSession {
            var session = ScrollshotSession(
                options: ScrollStitcher.Options(unusableTopRows: unusableTopRows)
            )
            for frame in frames { session.submit(frame) }
            return session
        }

        // 对照：旧默认（检测不到就当作 0）——固定带被逐帧贴进长图。
        let before = run(unusableTopRows: 0)
        let beforeImage = try #require(before.result().image)
        let beforeRows = bandRows(beforeImage, channel: 0, value: leadingColor.red)

        // 修复后：固定带只应出现在**首帧段顶端**那一次（用户选区里真实看到的顶边）。
        let after = run(unusableTopRows: Self.declaredUnusableTopRows)
        let afterImage = try #require(after.result().image)
        let afterRows = bandRows(afterImage, channel: 0, value: leadingColor.red)
        let afterGreen = bandRows(afterImage, channel: 1, value: leadingColor.green)
        let afterBlue = bandRows(afterImage, channel: 2, value: leadingColor.blue)

        let summary = """
            帧数=\(frames.count) 首帧顶色=\(leadingColor) \
            输出高度=\(beforeImage.height)→\(afterImage.height) \
            固定带整行数=\(beforeRows.count)→\(afterRows.count) \
            修复后位置=\(afterRows.prefix(20))
            """
        print("[真实帧复算] \(summary)")

        // 旧行为下每个采纳帧的段首都留下一条固定带（接缝数 ≫ 1）。
        #expect(beforeRows.count > 1, "对照应复现旧缺陷，实际 \(beforeRows.count) 行：\(summary)")
        // 修复后只剩首帧顶端那一行（段数减少不影响：首帧段只有一处）。
        #expect(afterRows.count <= 1, "固定带被贴进长图：\(summary)")
        #expect(afterGreen.count <= 1 && afterBlue.count <= 1, "固定带被贴进长图：\(summary)")
        // 代价只有「末段被固定带遮住的那几行」（用户当时也看不到），其余内容照旧接上。
        #expect(
            beforeImage.height - afterImage.height <= Self.declaredUnusableTopRows + 4,
            "高度损失超出预期：\(summary)"
        )
        #expect(afterImage.height > beforeImage.height / 2, "输出高度异常：\(summary)")
    }
}
