//
//  ScrollshotHorizontalTests.swift
//  AnShotUITests
//
//  横向滚动长截图的**端到端**验证：从帧序列到最终长图。
//
//  ── 为什么必须有这一层 ────────────────────────────────────
//
//  Core 的转置测试只能证明「一次转置的几何是对的」，证明不了
//  「入口转了一次、出口也恰好转了一次」。后者才是横向功能真正的失败模式：
//  少转一次 → 长图躺倒；多转一次 → 尺寸对但内容被二次转置；
//  两者都不会抛错，只会给用户一张错图。
//
//  所以这里跑完整链路（抓帧 → 转置 → 配准 → 世界坐标 → 拼接 → 转置回来），
//  断言输出**沿宽度增长**且高度不变。
//

import AppKit
import CoreGraphics
import Foundation
import os
import Testing

@testable import AnShotCapture
@testable import AnShotCore
@testable import AnShotUI

@Suite("长截图 · 整块选区与轴向")
@MainActor
struct ScrollshotHorizontalTests {

    @Test("横向滚动：输出沿宽度增长，高度不变")
    func horizontalAxisGrowsWidth() async throws {
        // 宽页面：横向滚动时内容向左移动（视口向右滑）。
        let page = makeTexture(width: 1200, height: 100)
        let viewportWidth = 240
        let step = 60
        let frames = [0, 60, 120].map {
            sliceColumns(page, offset: $0, width: viewportWidth)
        }

        let capturer = SequenceCapturer(frames: frames.map(makeCGImage))
        let controller = ScrollshotController(
            capturer: capturer,
            selection: PixelRect(
                origin: PixelPoint(x: 0, y: 0),
                size: PixelSize(width: Double(viewportWidth), height: 100)
            ),
            displayID: 1,
            scaleFactor: 1,
            // 关闭不可用带：本用例只验证	extbf{轴向}，不掺固定带策略。
            // 默认策略下末帧底部 12 行按设计不收，会让期望值带上无关常数。
            options: ScrollStitcher.Options(unusableTopRows: 0, unusableBottomRows: 0),
            axis: .horizontal,
            frameInterval: 3600
        )

        var outcome: ScrollshotController.Outcome?
        controller.onFinish = { outcome = $0 }

        controller.start()
        try await waitUntil { capturer.captureCount >= 1 }
        // 首帧已被 start 消费，剩下的逐个 tick 提交。
        for _ in 1..<frames.count {
            await controller.tick()
        }
        await controller.finish()

        let image = try #require(outcome?.image, "横向会话未产出长图")
        #expect(
            image.height == 100,
            "横向长图高度应等于视口高 100，实际 \(image.height)"
        )
        #expect(
            image.width == viewportWidth + 2 * step,
            "横向长图宽度应为 \(viewportWidth + 2 * step)，实际 \(image.width)（少转/多转都会偏离）"
        )
    }

    @Test("竖向不受影响：同样三帧沿高度增长（轴向改动零回归）")
    func verticalStillGrowsHeight() async throws {
        let page = makeTexture(width: 240, height: 1200)
        let viewportHeight = 100
        let step = 60
        let frames = [0, 60, 120].map {
            sliceRows(page, offset: $0, height: viewportHeight)
        }

        let capturer = SequenceCapturer(frames: frames.map(makeCGImage))
        let controller = ScrollshotController(
            capturer: capturer,
            selection: PixelRect(
                origin: PixelPoint(x: 0, y: 0),
                size: PixelSize(width: 240, height: Double(viewportHeight))
            ),
            displayID: 1,
            scaleFactor: 1,
            options: ScrollStitcher.Options(unusableTopRows: 0, unusableBottomRows: 0),
            axis: .vertical,
            frameInterval: 3600
        )
        var outcome: ScrollshotController.Outcome?
        controller.onFinish = { outcome = $0 }

        controller.start()
        try await waitUntil { capturer.captureCount >= 1 }
        for _ in 1..<frames.count { await controller.tick() }
        await controller.finish()

        let image = try #require(outcome?.image, "竖向会话未产出长图")
        #expect(image.width == 240)
        #expect(image.height == viewportHeight + 2 * step, "输出高 \(image.height)")
    }

    @Test("横向：导航缩略图保持会话空间（沿纵向增长，定位框才对得上）")
    func horizontalPreviewStaysInSessionSpace() async throws {
        // 视口 240×100；6 帧后会话空间的世界高度 400 > 宽 240，
        // 于是缩略图必然“高 > 宽”。若错误地转回显示方向，宽高会倒过来。
        let page = makeTexture(width: 1200, height: 100)
        let frames = (0..<6).map {
            sliceColumns(page, offset: $0 * 60, width: 240)
        }

        let capturer = SequenceCapturer(frames: frames.map(makeCGImage))
        let controller = ScrollshotController(
            capturer: capturer,
            selection: PixelRect(
                origin: PixelPoint(x: 0, y: 0),
                size: PixelSize(width: 240, height: 100)
            ),
            displayID: 1,
            scaleFactor: 1,
            options: ScrollStitcher.Options(unusableTopRows: 0, unusableBottomRows: 0),
            axis: .horizontal,
            frameInterval: 3600
        )
        var latest: ScrollshotPreviewContent?
        controller.onPreview = { latest = $0 }

        controller.start()
        try await waitUntil { capturer.captureCount >= 1 }
        for _ in 1..<frames.count { await controller.tick() }

        let preview = try #require(latest, "未收到预览")
        #expect(
            preview.navigatorPixelHeight > preview.navigatorPixelWidth,
            "横向导航缩略图应沿纵向增长，实际 \(preview.navigatorPixelWidth)×\(preview.navigatorPixelHeight)"
        )
        controller.cancel()
    }

    @Test("横向：放大栏切片等比（高等于视口高，不纵向形变）")
    func horizontalDetailKeepsAspect() async throws {
        let page = makeTexture(width: 1200, height: 100)
        let frames = (0..<4).map {
            sliceColumns(page, offset: $0 * 60, width: 240)
        }

        let capturer = SequenceCapturer(frames: frames.map(makeCGImage))
        let controller = ScrollshotController(
            capturer: capturer,
            selection: PixelRect(
                origin: PixelPoint(x: 0, y: 0),
                size: PixelSize(width: 240, height: 100)
            ),
            displayID: 1,
            scaleFactor: 1,
            options: ScrollStitcher.Options(unusableTopRows: 0, unusableBottomRows: 0),
            axis: .horizontal,
            frameInterval: 3600
        )
        controller.start()
        try await waitUntil { capturer.captureCount >= 1 }
        for _ in 1..<frames.count { await controller.tick() }

        // 请求 120 个「世界行」（横向即 120 列）。
        let slice = try #require(controller.detailImage(worldRows: 0..<120, targetWidth: 688))
        #expect(slice.height == 100, "切片高应等于视口高 100，实际 \(slice.height)")
        #expect(slice.width == 120, "切片宽应等于请求的世界列数 120，实际 \(slice.width)")
        controller.cancel()
    }

    @Test("失去对齐后回到已采内容：恢复提示，收尾状态与输出均恢复正常")
    func recoversAfterStall() async throws {
        let page = makeTexture(width: 240, height: 1800)
        let viewportHeight = 400
        var frames = [0, 100].map { sliceRows(page, offset: $0, height: viewportHeight) }
        for seed: UInt64 in [4242, 2026, 9999] {
            var state = seed
            var data = [UInt8](repeating: 255, count: 240 * viewportHeight * 4)
            for index in stride(from: 0, to: data.count, by: 4) {
                for channel in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    data[index + channel] = UInt8(truncatingIfNeeded: state >> 32)
                }
            }
            frames.append(ScrollshotImage(width: 240, height: viewportHeight, data: data)!)
        }
        frames += [200, 300].map { sliceRows(page, offset: $0, height: viewportHeight) }
        let capturer = SequenceCapturer(frames: frames.map(makeCGImage))
        let controller = ScrollshotController(
            capturer: capturer,
            selection: PixelRect(
                origin: PixelPoint(x: 0, y: 0),
                size: PixelSize(width: 240, height: Double(viewportHeight))
            ),
            displayID: 1,
            scaleFactor: 1,
            options: .init(unusableTopRows: 0, unusableBottomRows: 0),
            frameInterval: 3600
        )
        var stallCount = 0
        var recoveryCount = 0
        var outcome: ScrollshotController.Outcome?
        controller.onStall = { stallCount += 1 }
        controller.onRecovery = { recoveryCount += 1 }
        controller.onFinish = { outcome = $0 }
        controller.start()
        try await waitUntil { capturer.captureCount >= 1 }
        for _ in 1..<frames.count { await controller.tick() }
        await controller.finish()

        #expect(stallCount == 1)
        #expect(recoveryCount == 1)
        #expect(outcome?.stalled == false)
        let image = try #require(outcome?.image)
        let output = try #require(ScrollshotImage(image))
        let expected = sliceRows(page, offset: 0, height: 700)
        #expect(output.width == expected.width)
        #expect(output.height == expected.height)
        #expect(output.data.elementsEqual(expected.data))
    }

    @Test("高频回看已采内容超过 240 次，不应提前结束或增长输出")
    func coveredObservationsDoNotConsumeImageLimit() async throws {
        let page = makeTexture(width: 120, height: 700)
        let pair = [0, 100].map { makeCGImage(sliceRows(page, offset: $0, height: 200)) }
        let capturer = SequenceCapturer(frames: (0..<270).map { pair[$0 % 2] })
        let controller = ScrollshotController(
            capturer: capturer,
            selection: PixelRect(origin: PixelPoint(x: 0, y: 0), size: PixelSize(width: 120, height: 200)),
            displayID: 1, scaleFactor: 1, frameInterval: 3600
        )
        var outcome: ScrollshotController.Outcome?
        var limitReached = false
        controller.onFinish = { outcome = $0 }
        controller.onLimitReached = { _ in limitReached = true }
        controller.start()
        try await waitUntil { capturer.captureCount >= 1 }
        for _ in 0..<260 { await controller.tick() }
        let finishedEarly = outcome != nil
        #expect(!finishedEarly)
        #expect(!limitReached)
        await controller.finish()
        #expect(outcome?.observedFrames ?? 0 >= 260)
        #expect(outcome?.capturedFrames == 2)
        #expect(outcome?.image?.height == 300)
    }

    // MARK: - 夹具

    @Test("主线程阻塞时仍采集中间帧，完成时按序处理队列")
    func finishDrainsCapturedFrames() async throws {
        let page = makeTexture(width: 120, height: 900)
        let source = SequenceCapturer(frames: [0, 100, 200, 300].map {
            makeCGImage(sliceRows(page, offset: $0, height: 200))
        })
        let buffered = ScrollshotFrameCapturer(capturer: source, interval: .milliseconds(1), capacity: 8)
        let controller = ScrollshotController(
            capturer: buffered,
            selection: PixelRect(origin: PixelPoint(x: 0, y: 0), size: PixelSize(width: 120, height: 200)),
            displayID: 1, scaleFactor: 1, frameInterval: 3600
        )
        var ready = false
        var previewHeight = 0
        var outcome: ScrollshotController.Outcome?
        controller.onReady = { ready = true }
        controller.onPreview = { previewHeight = $0?.worldHeight ?? 0 }
        controller.onFinish = { outcome = $0 }
        controller.start()
        try await waitUntil { ready }
        blockMainActorForMatching()
        #expect(source.captureCount >= 4, "配准占用主线程期间也必须继续拍摄")
        await controller.finish()
        #expect(outcome?.capturedFrames == 4)
        #expect(previewHeight == 500, "收尾预览必须包含缓冲队列补齐的内容")
        let image = try #require(outcome?.image)
        let output = try #require(ScrollshotImage(image))
        let matches = output.data.elementsEqual(sliceRows(page, offset: 0, height: 500).data)
        #expect(matches)
    }

    /// 模拟现场慢匹配的同步 CPU 占用，不能用 async sleep 代替主线程阻塞。
    private func blockMainActorForMatching() {
        Thread.sleep(forTimeInterval: 0.08)
    }

    @Test("整窗来回滚动：保留完整选区，正文无缺行，两端界面只出现一次", arguments: [false, true])
    func wholeWindowBidirectionalScroll(startsByRewinding: Bool) async throws {
        let offsets = startsByRewinding
            ? [700, 648, 511, 315, 460, 700, 850]
            : [0, 52, 137, 260, 137, 200, 420]
        let (page, frames) = await Task.detached { [self] in
            let page = makeChatPage(width: 640, height: 2400)
            return (page, offsets.map { makeChatWindow(page: page, offset: $0) })
        }.value
        let capturer = SequenceCapturer(frames: frames.map(makeCGImage))
        let controller = ScrollshotController(
            capturer: capturer,
            selection: PixelRect(
                origin: PixelPoint(x: 0, y: 0), size: PixelSize(width: 800, height: 480)
            ),
            displayID: 1, scaleFactor: 1, frameInterval: 3600
        )
        var outcome: ScrollshotController.Outcome?
        var preview: ScrollshotPreviewContent?
        controller.onFinish = { outcome = $0 }
        controller.onPreview = { preview = $0 }
        controller.start()
        try await waitUntil(timeout: .seconds(15)) { capturer.captureCount >= 1 }
        for _ in 1..<frames.count { await controller.tick() }
        await controller.finish()
        let image = try #require(outcome?.image)
        let output = try #require(ScrollshotImage(image))
        let start = offsets.min()!
        let expected = sliceRows(page, offset: start, height: offsets.max()! - start + 390)
        #expect(output.width == 800)
        #expect(output.height == expected.height + 90)
        let body = try #require(ScrollshotViewport(x: 160, y: 40, width: 640, height: expected.height).crop(output))
        let matches = body.data.elementsEqual(expected.data)
        #expect(matches, "正文在任意接缝处均不能缺失或重复")
        #expect(preview?.worldWidth == 800)
        let worldStart = start - offsets[0]
        let detailCG = try #require(controller.detailImage(
            worldRows: (worldStart + 90)..<(worldStart + 290), targetWidth: 800
        ))
        let detail = try #require(ScrollshotImage(detailCG))
        let detailBody = try #require(ScrollshotViewport(x: 160, y: 0, width: 640, height: 200).crop(detail))
        let detailMatches = detailBody.data.elementsEqual(sliceRows(page, offset: start + 50, height: 200).data)
        #expect(detailMatches)
        let header = sliceRows(output, offset: 0, height: 40)
        let footer = sliceRows(output, offset: output.height - 50, height: 50)
        let headerMatches = header.data.elementsEqual(sliceRows(frames[0], offset: 0, height: 40).data)
        let footerMatches = footer.data.elementsEqual(sliceRows(frames[0], offset: 430, height: 50).data)
        #expect(headerMatches)
        #expect(footerMatches)
        if let directory = ProcessInfo.processInfo.environment["ANSHOT_TEST_ARTIFACT_DIR"] {
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(
                startsByRewinding ? "chat-rewind-result.png" : "chat-forward-result.png"
            ))
            let input = makeCGImage(frames[0])
            let inputPNG = try #require(NSBitmapImageRep(cgImage: input).representation(using: .png, properties: [:]))
            try inputPNG.write(to: URL(fileURLWithPath: directory).appendingPathComponent("chat-window-input.png"))
        }
    }

    @Test("文字周围的留白不等于固定栏，正文边界保持完整")
    nonisolated func whitespaceDoesNotCropContent() throws {
        let page = makeChatPage(width: 640, height: 2400)
        let previous = sliceRows(page, offset: 0, height: 390)
        let next = sliceRows(page, offset: 52, height: 390)
        let viewport = try #require(ScrollshotViewport.detect(previous: previous, next: next))
        #expect(viewport == ScrollshotViewport(x: 0, y: 0, width: 640, height: 390))
    }

    @Test("首个变化只是输入光标时，整块选区的正文仍能连续拼接")
    func cursorChangeDoesNotLockWholeWindow() async throws {
        let page = makeChatPage(width: 640, height: 2400)
        let initial = makeChatWindow(page: page, offset: 0)
        var blinking = initial.data
        for y in 440..<470 {
            for x in 200..<248 {
                let index = (y * initial.width + x) * 4
                for channel in 0..<3 { blinking[index + channel] = 240 }
            }
        }
        let cursorFrame = try #require(ScrollshotImage(width: 800, height: 480, data: blinking))
        let cursorChanged = ScrollshotController.isDifferent(initial, cursorFrame)
        #expect(cursorChanged)
        let frames = [initial, cursorFrame, makeChatWindow(page: page, offset: 52),
                      makeChatWindow(page: page, offset: 137)]
        let capturer = SequenceCapturer(frames: frames.map(makeCGImage))
        let controller = ScrollshotController(
            capturer: capturer,
            selection: PixelRect(origin: PixelPoint(x: 0, y: 0), size: PixelSize(width: 800, height: 480)),
            displayID: 1, scaleFactor: 1, frameInterval: 3600
        )
        var outcome: ScrollshotController.Outcome?
        controller.onFinish = { outcome = $0 }
        controller.start()
        try await waitUntil { capturer.captureCount >= 1 }
        for _ in 1..<frames.count { await controller.tick() }
        await controller.finish()
        let output = try #require(outcome?.image.flatMap(ScrollshotImage.init))
        let expected = sliceRows(page, offset: 0, height: 527)
        #expect(output.width == 800)
        #expect(output.height == 617)
        let body = try #require(ScrollshotViewport(x: 160, y: 40, width: 640, height: 527).crop(output))
        let matches = body.data.elementsEqual(expected.data)
        #expect(matches)
    }

    @Test("相同标题栏和背景不能为无关正文提供高置信度")
    nonisolated func unrelatedPagesWithSameChromeAreRejected() throws {
        let previous = makeChatWindow(page: makeChatPage(width: 640, height: 900), offset: 100)
        let next = makeChatWindow(page: makeChatPage(width: 640, height: 900, seed: 9137), offset: 220)
        var session = ScrollshotSession(options: .init(unusableTopRows: 8, unusableBottomRows: 12))
        session.submit(previous)
        let decision = session.submit(next)
        #expect(decision.verdict == .unresolved)
    }

    @Test("正文图片的直边不能被误认为固定侧栏")
    nonisolated func contentBorderIsNotSidebar() throws {
        let page = makeChatPage(width: 640, height: 900)
        func frame(_ offset: Int) -> ScrollshotImage {
            let source = sliceRows(page, offset: offset, height: 390)
            var data = source.data
            for y in 0..<390 {
                for x in 0..<64 {
                    let index = (y * 640 + x) * 4
                    for channel in 0..<3 { data[index + channel] = 60 }
                }
            }
            return ScrollshotImage(width: 640, height: 390, data: data)!
        }
        let viewport = try #require(ScrollshotViewport.detect(previous: frame(0), next: frame(52)))
        #expect(viewport == ScrollshotViewport(x: 0, y: 0, width: 640, height: 390))
    }

    @Test("稀疏文字落在旧粗网格之间时，真实滚动仍须触发采集")
    func sparseTextIsNotSkippedByChangeGate() {
        func frame(_ top: Int) -> ScrollshotImage {
            var data = [UInt8](repeating: 255, count: 1520 * 1040 * 4)
            for index in stride(from: 0, to: data.count, by: 4) {
                for channel in 0..<3 { data[index + channel] = 24 }
            }
            for y in top..<(top + 5) {
                for x in 180..<1100 where x % 11 < 6 {
                    let index = (y * 1520 + x) * 4
                    for channel in 0..<3 { data[index + channel] = 205 }
                }
            }
            return ScrollshotImage(width: 1520, height: 1040, data: data)!
        }
        let detected = ScrollshotController.isDifferent(frame(20), frame(12))
        #expect(detected)
    }

    @Test("叠加式滚动条随页面缓慢移动时，不把滑块拼入长图")
    nonisolated func scrollbarIsOutsideViewport() throws {
        let page = makeChatPage(width: 640, height: 900)
        func frame(_ offset: Int, thumbY: Int) -> ScrollshotImage {
            let source = makeChatWindow(page: page, offset: offset)
            var data = source.data
            for y in thumbY..<(thumbY + 60) {
                for x in 780..<792 {
                    let index = (y * 800 + x) * 4
                    for channel in 0..<3 { data[index + channel] = 150 }
                }
            }
            return ScrollshotImage(width: 800, height: 480, data: data)!
        }
        let viewport = try #require(ScrollshotViewport.detect(
            previous: frame(0, thumbY: 120), next: frame(52, thumbY: 130)
        ))
        #expect(viewport == ScrollshotViewport(x: 160, y: 40, width: 620, height: 390))
    }

    /// 固定边栏、标题栏和底部输入栏包围着稀疏正文，接近整窗截聊天记录的构图。
    nonisolated private func makeChatWindow(page: ScrollshotImage, offset: Int) -> ScrollshotImage {
        let body = sliceRows(page, offset: offset, height: 390)
        var data = [UInt8](repeating: 255, count: 800 * 480 * 4)
        for y in 0..<480 {
            for x in 0..<800 {
                let index = (y * 800 + x) * 4
                let color: UInt8 = y < 40 ? 52 : y >= 430 ? 68 : x < 160 ? 40 : 24
                for channel in 0..<3 { data[index + channel] = color }
                if y >= 40, y < 430, x >= 160 {
                    let source = ((y - 40) * 640 + x - 160) * 4
                    for channel in 0..<4 { data[index + channel] = body.data[source + channel] }
                } else if x >= 16, x < 120, y % 28 >= 8, y % 28 < 17 {
                    for channel in 0..<3 { data[index + channel] = 190 }
                }
            }
        }
        return ScrollshotImage(width: 800, height: 480, data: data)!
    }

    nonisolated private func makeChatPage(width: Int, height: Int, seed: UInt64 = 7) -> ScrollshotImage {
        var data = [UInt8](repeating: 24, count: width * height * 4)
        for y in 0..<height {
            let line = y / 29
            let glyphY = y % 29
            for x in 0..<width {
                let index = (y * width + x) * 4
                data[index + 3] = 255
                let glyph = max(0, x - 65) / 7
                let hash = UInt64(line + 1) &* 2654435761 &+ UInt64(glyph + 3) &* 2246822519 &+ seed &* 3266489917
                let length = 200 + Int((hash & 7) * 20)
                if x >= 65, x < 65 + length, glyphY >= 7, glyphY < 19,
                   (hash >> ((glyphY + x % 7) % 27)) & 1 != 0 {
                    data[index] = 205
                    data[index + 1] = 205
                    data[index + 2] = 205
                }
            }
        }
        return ScrollshotImage(width: width, height: height, data: data)!
    }

    /// 非周期纹理：每个像素由坐标决定，避免配准被周期图案骗到。
    private func makeTexture(width: Int, height: Int) -> ScrollshotImage {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                data[offset] = UInt8((x * 7 + y * 13) % 251)
                data[offset + 1] = UInt8((x * 31 + y * 5) % 253)
                data[offset + 2] = UInt8((x * 11 + y * 17) % 249)
                data[offset + 3] = 255
            }
        }
        return ScrollshotImage(width: width, height: height, data: data)!
    }

    private func sliceColumns(
        _ page: ScrollshotImage, offset: Int, width: Int
    ) -> ScrollshotImage {
        var buffer = [UInt8](repeating: 0, count: width * page.height * 4)
        for y in 0..<page.height {
            for x in 0..<width {
                let sourceX = offset + x
                guard sourceX < page.width else { continue }
                let from = (y * page.width + sourceX) * 4
                let to = (y * width + x) * 4
                for channel in 0..<4 {
                    buffer[to + channel] = page.data[from + channel]
                }
            }
        }
        return ScrollshotImage(width: width, height: page.height, data: buffer)!
    }

    nonisolated private func sliceRows(
        _ page: ScrollshotImage, offset: Int, height: Int
    ) -> ScrollshotImage {
        var buffer = [UInt8](repeating: 0, count: page.width * height * 4)
        let bytesPerRow = page.width * 4
        for row in 0..<height {
            let sourceRow = offset + row
            guard sourceRow < page.height else { break }
            let from = sourceRow * bytesPerRow
            let to = row * bytesPerRow
            for index in 0..<bytesPerRow {
                buffer[to + index] = page.data[from + index]
            }
        }
        return ScrollshotImage(width: page.width, height: height, data: buffer)!
    }

    private func makeCGImage(_ image: ScrollshotImage) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var buffer = image.data
        return buffer.withUnsafeMutableBytes { raw -> CGImage in
            let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return context.makeImage()!
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等待条件超时")
    }
}

// MARK: - 按序返回预设帧的捕获器

/// 每次 `captureFrame` 返回序列里的下一帧（超出后复用末帧），模拟真实滚动采集。
private final class SequenceCapturer: ScreenCapturing, @unchecked Sendable {
    private let cursor = OSAllocatedUnfairLock(initialState: 0)
    private let frames: [CGImage]

    init(frames: [CGImage]) {
        self.frames = frames
    }

    var captureCount: Int { cursor.withLock { $0 } }

    func captureFrame(scope: CaptureScope) async throws -> CapturedFrame {
        let index = cursor.withLock { state -> Int in
            let current = state
            state += 1
            return current
        }
        let image = frames[min(index, frames.count - 1)]
        return CapturedFrame(image: image, displayID: 1, scaleFactor: 1)
    }
}
