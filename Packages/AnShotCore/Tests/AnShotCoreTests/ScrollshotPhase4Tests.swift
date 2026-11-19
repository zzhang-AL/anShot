//
//  ScrollshotPhase4Tests.swift
//  AnShotCoreTests
//
//  Phase 4 核心算法专项单测：
//    - 分段撤销 `undoLastSegment()`；
//    - 未滚出第二段首帧兜底 `allowsSingleFrameFallback`；
//    - 固定左侧栏洁净背景延展覆写 `extendSidebarBackground`；
//    - 窗口底部左右圆角检测 `detectBottomCornerHeight`。
//

import Foundation
import Testing

@testable import AnShotCore

@Suite("Phase 4 · 长截图撤销、首帧兜底与美学收口")
struct ScrollshotPhase4Tests {

    /// 构造带明显唯一行特征的测试长卷，按起止行裁出模拟滚动帧。
    private func makeRichScrollCanvas(width: Int, totalHeight: Int) -> ScrollshotImage {
        var data = Data(count: width * totalHeight * 4)
        data.withUnsafeMutableBytes { raw in
            guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<totalHeight {
                // 每 20 行绘制不同颜色横条与不规则纹理块，确保纵向配准单峰高置信度。
                let band = y / 20
                let baseR = UInt8((band * 53 + 40) % 210 + 20)
                let baseG = UInt8((band * 97 + 70) % 200 + 30)
                let baseB = UInt8((band * 131 + 20) % 200 + 30)
                let markerX = (band * 37 + y * 3) % max(1, width - 24)
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let isAccent = (y % 20 >= 4 && y % 20 <= 12) && (x >= markerX && x < markerX + 20)
                    ptr[i] = isAccent ? UInt8(255 - Int(baseR)) : baseR
                    ptr[i + 1] = isAccent ? UInt8(255 - Int(baseG)) : baseG
                    ptr[i + 2] = isAccent ? UInt8(255 - Int(baseB)) : baseB
                    ptr[i + 3] = 255
                }
            }
        }
        return ScrollshotImage(width: width, height: totalHeight, data: data)!
    }

    private func cropFrame(from canvas: ScrollshotImage, top: Int, height: Int) -> ScrollshotImage {
        ScrollshotViewport(x: 0, y: top, width: canvas.width, height: height).crop(canvas)!
    }

    @Test("分段撤销精准回退上一段高度与世界坐标，退回首帧后不可再撤")
    func segmentUndoRestoresPreviousCoverage() {
        let canvas = makeRichScrollCanvas(width: 240, totalHeight: 800)
        let frame0 = cropFrame(from: canvas, top: 0, height: 300)
        let frame1 = cropFrame(from: canvas, top: 120, height: 300)
        let frame2 = cropFrame(from: canvas, top: 260, height: 300)

        var session = ScrollshotSession(options: .init(joinsInsideOverlap: true, allowsSingleFrameFallback: true))
        _ = session.submit(frame0)
        #expect(!session.canUndoSegment)
        #expect(session.coveredWorldHeight == 300)

        let d1 = session.submit(frame1)
        #expect(d1.isAccepted)
        let heightAfter1 = session.coveredWorldHeight
        #expect(heightAfter1 > 300)
        #expect(session.canUndoSegment)

        let d2 = session.submit(frame2)
        #expect(d2.isAccepted)
        let heightAfter2 = session.coveredWorldHeight
        #expect(heightAfter2 > heightAfter1)

        // 撤销第 2 段 → 精确回到第 1 段后的高度
        let undone2 = session.undoLastSegment()
        #expect(undone2)
        #expect(session.coveredWorldHeight == heightAfter1)
        #expect(session.acceptedFrameCount == 2)

        // 再撤销第 1 段 → 精确回到首帧 300px，且无可继续撤销
        let undone1 = session.undoLastSegment()
        #expect(undone1)
        #expect(session.coveredWorldHeight == 300)
        #expect(session.acceptedFrameCount == 1)
        #expect(!session.canUndoSegment)
        let undone0 = session.undoLastSegment()
        #expect(!undone0)

        // 首帧兜底开启时此时完成直接产出首帧
        let res = session.result()
        #expect(res.failure == nil)
        #expect(res.image?.height == 300)
    }

    @Test("开启 allowsSingleFrameFallback 时未滚出第二段静默输出首帧")
    func singleFrameFallbackOutputsFirstFrameWithoutError() {
        let canvas = makeRichScrollCanvas(width: 200, totalHeight: 300)
        let frame0 = cropFrame(from: canvas, top: 0, height: 240)

        // 仅提交首帧即完成
        var single = ScrollshotSession(options: .init(allowsSingleFrameFallback: true))
        _ = single.submit(frame0)
        let res1 = single.result()
        #expect(res1.failure == nil)
        #expect(res1.image?.width == 200)
        #expect(res1.image?.height == 240)

        // 提交重复静止帧后完成同样静默输出首帧
        var still = ScrollshotSession(options: .init(allowsSingleFrameFallback: true))
        _ = still.submit(frame0)
        _ = still.submit(frame0)
        let res2 = still.result()
        #expect(res2.failure == nil)
        #expect(res2.image?.height == 240)
    }

    @Test("静态左侧栏洁净背景延展覆写首帧以下区域并保留分隔线与首帧原文")
    func sidebarBackgroundExtensionCleansBelowFirstFrame() {
        let width = 200
        let height = 360
        let firstHeight = 200
        let leftWidth = 60
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    if x == leftWidth - 1 {
                        // 1px 分隔线（深灰）
                        ptr[i] = 80; ptr[i + 1] = 80; ptr[i + 2] = 80; ptr[i + 3] = 255
                    } else if x < leftWidth - 1 {
                        if y < firstHeight {
                            // 首帧顶部有导航按钮色块，首帧底部留有纯净浅灰底色 (240, 242, 245)
                            if y >= 20 && y < 60 && x >= 10 && x < 45 {
                                ptr[i] = 30; ptr[i + 1] = 120; ptr[i + 2] = 220; ptr[i + 3] = 255
                            } else {
                                ptr[i] = 240; ptr[i + 1] = 242; ptr[i + 2] = 245; ptr[i + 3] = 255
                            }
                        } else {
                            // 模拟中段被腰斩重复的脏侧栏按钮（红块）
                            ptr[i] = 220; ptr[i + 1] = 40; ptr[i + 2] = 40; ptr[i + 3] = 255
                        }
                    } else {
                        // 正文区
                        ptr[i] = 255; ptr[i + 1] = 255; ptr[i + 2] = 255; ptr[i + 3] = 255
                    }
                }
            }
        }
        let raw = ScrollshotImage(width: width, height: height, data: data)!
        let cleaned = ScrollStitcher.extendSidebarBackground(
            in: raw,
            firstFrameHeight: firstHeight,
            leftWidth: leftWidth
        )

        cleaned.withPixels { pixels in
            // 首帧内的侧栏导航按钮完整保留
            let topBtn = (30 * width + 20) * 4
            #expect(pixels[topBtn] == 30 && pixels[topBtn + 1] == 120 && pixels[topBtn + 2] == 220)

            // 首帧以下原脏红块被洁净延展底色 (240, 242, 245) 覆盖
            let lowerSidebar = (260 * width + 20) * 4
            #expect(pixels[lowerSidebar] == 240 && pixels[lowerSidebar + 1] == 242 && pixels[lowerSidebar + 2] == 245)

            // 1px 竖直分隔线笔直保留
            let sep = (260 * width + (leftWidth - 1)) * 4
            #expect(pixels[sep] == 80 && pixels[sep + 1] == 80 && pixels[sep + 2] == 80)
        }
    }

    @Test("窗口底部左右对称圆角可被准确探测，纯平直窗口不误判")
    func detectsBottomWindowCorners() {
        let width = 200
        let height = 200

        func makeWindowFrame(cornerRadius: Int, shift: Int) -> ScrollshotImage {
            var data = Data(count: width * height * 4)
            data.withUnsafeMutableBytes { raw in
                guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for y in 0..<height {
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        // 白色正文底 + 随滚动移动的文字条
                        let isStripe = ((y + shift) % 30) < 6 && x > 30 && x < width - 30
                        var r: UInt8 = isStripe ? 40 : 250
                        var g: UInt8 = isStripe ? 40 : 250
                        var b: UInt8 = isStripe ? 40 : 250

                        // 在底部左右角绘制固定深色桌面圆角弧区
                        if cornerRadius > 0, y >= height - cornerRadius {
                            let dy = y - (height - cornerRadius)
                            if x < cornerRadius {
                                let dx = cornerRadius - 1 - x
                                if dx * dx + dy * dy >= cornerRadius * cornerRadius {
                                    r = 20; g = 25; b = 30
                                }
                            } else if x >= width - cornerRadius {
                                let dx = x - (width - cornerRadius)
                                if dx * dx + dy * dy >= cornerRadius * cornerRadius {
                                    r = 20; g = 25; b = 30
                                }
                            }
                        }
                        ptr[i] = r; ptr[i + 1] = g; ptr[i + 2] = b; ptr[i + 3] = 255
                    }
                }
            }
            return ScrollshotImage(width: width, height: height, data: data)!
        }

        let roundedA = makeWindowFrame(cornerRadius: 12, shift: 0)
        let roundedB = makeWindowFrame(cornerRadius: 12, shift: 40)
        let detected = ScrollshotViewport.detectBottomCornerHeight(previous: roundedA, next: roundedB)
        #expect(detected >= 6 && detected <= 14)

        let sharpA = makeWindowFrame(cornerRadius: 0, shift: 0)
        let sharpB = makeWindowFrame(cornerRadius: 0, shift: 40)
        #expect(ScrollshotViewport.detectBottomCornerHeight(previous: sharpA, next: sharpB) == 0)
    }
}
