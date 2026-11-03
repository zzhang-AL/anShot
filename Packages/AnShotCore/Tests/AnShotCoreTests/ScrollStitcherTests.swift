//
//  ScrollStitcherTests.swift
//  AnShotCoreTests
//
//  拼接编排的测试。
//
//  ── 为什么用「整页 → 切帧 → 拼接 → 比对整页」 ──────────────
//
//  逐条断言「这一帧收了、那一帧丢了」只能证明分支走到了，证明不了**拼出来的图对**。
//  这里先渲染一整页（内容只由世界坐标决定），再按已知的偏移切成若干帧，
//  最后把拼接结果与整页的对应区间**逐像素比较**——
//  重复、错位、漏接、sticky 顶栏多贴一次，任何一种都会在这里暴露。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

// MARK: - 测试

@Suite("滚动截图拼接编排")
struct ScrollStitcherTests {

    @Test("连续滚动：拼接结果与整页对应区间逐像素一致")
    func stitchesContinuousScroll() throws {
        let page = makePage(pageHeight: 2000)
        let frameHeight = 480
        let step = 120
        let frames = (0..<5).map { slice(page, offset: $0 * step, height: frameHeight) }

        let result = ScrollStitcher.stitch(frames: frames)
        let image = try #require(result.image)
        #expect(result.failure == nil)

        // 5 帧、每帧新增 step 行：总高 = 480 + 4 × 120
        let expectedHeight = frameHeight + 4 * step
        #expect(image.height == expectedHeight, "输出高度 \(image.height)")
        #expect(result.plan.seamRows == [480, 600, 720, 840])

        let expected = slice(page, offset: 0, height: expectedHeight)
        let diff = compare(image, expected)
        #expect(diff.differentPixels == 0, "不同像素 \(diff.differentPixels)，最大误差 \(diff.maxError)")
    }

    @Test("滚动到底的空转：重复帧被丢弃，不增加高度")
    func dropsDuplicateFrames() throws {
        let page = makePage(pageHeight: 2000)
        let frames = [
            slice(page, offset: 0, height: 480),
            slice(page, offset: 100, height: 480),
            slice(page, offset: 100, height: 480),   // 没滚动
            slice(page, offset: 200, height: 480),
        ]
        let result = ScrollStitcher.stitch(frames: frames)
        let image = try #require(result.image)

        #expect(image.height == 480 + 200, "输出高度 \(image.height)")
        let dropped = result.plan.frames.filter(\.discardedAsDuplicate)
        #expect(dropped.count == 1, "应正好丢弃 1 帧，实际 \(dropped.count)")
        #expect(dropped.first?.inputIndex == 2)
    }

    @Test("重复帧后仍能继续拼接（丢弃不打断后续）")
    func continuesAfterDuplicate() throws {
        let page = makePage(pageHeight: 2000)
        let frames = [
            slice(page, offset: 0, height: 400),
            slice(page, offset: 90, height: 400),
            slice(page, offset: 90, height: 400),
            slice(page, offset: 180, height: 400),
            slice(page, offset: 270, height: 400),
        ]
        let result = ScrollStitcher.stitch(frames: frames)
        let image = try #require(result.image)
        #expect(image.height == 400 + 270)
        let expected = slice(page, offset: 0, height: 400 + 270)
        #expect(compare(image, expected).differentPixels == 0)
    }

    @Test("输入不足 2 帧：报 notEnoughFrames")
    func rejectsSingleFrame() {
        let page = makePage(pageHeight: 600)
        let result = ScrollStitcher.stitch(frames: [slice(page, offset: 0, height: 480)])
        #expect(result.failure == .notEnoughFrames(1))
        #expect(result.image == nil)
    }

    @Test("除首帧外没有任何帧被接受：报 noAcceptedFrame")
    func rejectsAllDuplicates() {
        let page = makePage(pageHeight: 600)
        let frame = slice(page, offset: 0, height: 480)
        let result = ScrollStitcher.stitch(frames: [frame, frame, frame])
        #expect(result.failure == .noAcceptedFrame)
    }

    @Test("尺寸不一致的帧被跳过并告警")
    func skipsMismatchedFrame() throws {
        let page = makePage(width: 300, pageHeight: 2000)
        let narrow = makePage(width: 240, pageHeight: 2000)
        let frames = [
            slice(page, offset: 0, height: 400),
            slice(narrow, offset: 90, height: 400),
            slice(page, offset: 180, height: 400),
        ]
        let result = ScrollStitcher.stitch(frames: frames)
        let image = try #require(result.image)
        #expect(result.plan.warnings.contains { $0.contains("尺寸与首帧不一致") })
        #expect(image.height == 400 + 180, "输出高度 \(image.height)")
    }

    @Test("sticky 顶栏：在输出图里只出现一次")
    func stickyHeaderAppearsOnce() throws {
        // 页面前 40 行是固定顶栏，其余按视口滚动。
        let page = makePage(pageHeight: 2000)
        let headerRows = 40
        let frameHeight = 400
        func frame(scrollOffset: Int) -> ScrollshotImage {
            var buffer = slice(page, offset: scrollOffset, height: frameHeight)
            // 覆盖前 headerRows 行为「固定顶栏」：内容不随滚动变化。
            var data = buffer.data
            let headerSource = slice(page, offset: 0, height: headerRows)
            let bytesPerRow = buffer.width * 4
            data.withUnsafeMutableBufferPointer { target in
                headerSource.withPixels { source in
                    guard let dst = target.baseAddress, let src = source.baseAddress else { return }
                    memcpy(dst, src, bytesPerRow * headerRows)
                }
            }
            buffer = ScrollshotImage(width: buffer.width, height: frameHeight, data: data)!
            return buffer
        }

        let frames = [frame(scrollOffset: 0), frame(scrollOffset: 100), frame(scrollOffset: 200)]
        let options = ScrollStitcher.Options(stickyHeaderRows: headerRows)
        let result = ScrollStitcher.stitch(frames: frames, options: options)
        let image = try #require(result.image)

        // 视口每下移 100px，底部就新进来 100 行；固定顶栏不重复计入。
        #expect(image.height == frameHeight + 2 * 100, "输出高度 \(image.height)")

        // 顶栏只应出现一次：第 0..<headerRows 行与第 headerRows 之后不应相同。
        let header = slice(image, offset: 0, height: headerRows)
        let later = slice(image, offset: headerRows + 20, height: headerRows)
        #expect(compare(header, later).differentPixels > 0, "顶栏内容在输出里重复出现了")
    }

    @Test("高度上限：截断并告警，而不是让进程被 OOM 杀掉")
    func respectsHeightLimit() throws {
        let page = makePage(pageHeight: 3000)
        let frames = (0..<8).map { slice(page, offset: $0 * 200, height: 400) }
        let options = ScrollStitcher.Options(maxOutputHeight: 1000)
        let result = ScrollStitcher.stitch(frames: frames, options: options)
        let image = try #require(result.image)

        #expect(image.height <= 1000, "输出高度 \(image.height)")
        #expect(result.plan.warnings.contains { $0.contains("高度上限") })
    }

    @Test("配准不可信：结论必须可解释，不能被当成「没滚动」静默丢掉（FAIL-OPEN）")
    func failOpenOnUnreliableFrame() throws {
        // 制造一个「与上一帧毫无重叠关系」的帧：整幅随机噪声，模拟内容整体变化
        // （切换页面、播放中的视频、弹窗遮挡）。实测这一帧会被报成
        // delta=-181 / confidence=0 —— 内核知道自己完全不确定。
        var random = PageRandom(state: 999)
        var noise = [UInt8](repeating: 0, count: 300 * 400 * 4)
        for index in stride(from: 0, to: noise.count, by: 4) {
            let value = UInt8(random.next() * 255)
            noise[index] = value
            noise[index + 1] = UInt8(random.next() * 255)
            noise[index + 2] = UInt8(random.next() * 255)
            noise[index + 3] = 255
        }
        let chaotic = ScrollshotImage(width: 300, height: 400, data: noise)!

        let page = makePage(pageHeight: 2000)
        let frames = [slice(page, offset: 0, height: 400), slice(page, offset: 150, height: 400), chaotic]
        let result = ScrollStitcher.stitch(frames: frames)

        let last = try #require(result.plan.frames.last)
        // 这里断言的是**不变量**，不是某一种实现细节：
        // 配准完全不可信的帧既不能被判成「没滚动」（那等于说无法对齐的内容是空转），
        // 也不能在丢弃时不留下任何说明。
        #expect(last.verdict != .duplicate, "配准不可信的帧被当成「没滚动」静默丢掉了")
        if last.outputY == nil {
            #expect(!last.warnings.isEmpty, "帧被丢弃但没有留下任何说明")
        }
    }

    @Test("性能：8 帧 480 行的拼接在 Release 下远快于抓帧开销")
    func performance() throws {
        let page = makePage(pageHeight: 3000)
        let frames = (0..<8).map { slice(page, offset: $0 * 200, height: 480) }
        let start = Date()
        let result = ScrollStitcher.stitch(frames: frames)
        let elapsed = Date().timeIntervalSince(start) * 1000
        #expect(result.image != nil)
        // Debug（-Onone）构建下放宽；Release 实测见诊断输出。
        #expect(elapsed < 3000, "耗时 \(elapsed)ms")
    }
}
