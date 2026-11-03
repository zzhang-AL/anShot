//
//  VisionRegistrarTests.swift
//  AnShotCoreTests
//
//  Vision 配准封装的验证。
//
//  注意测试内容的选择：`makePage` 是纹理型内容（随机色块），对任何配准器都
//  不算难；真正难的是**结构性周期**——行距固定但每行内容不同，也就是终端、
//  代码、聊天记录的样子。所以这里额外造一个 `paragraphPage`，用它确认
//  Vision 在原子的弱项上仍然给出正确位移。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

@Suite("Vision 配准")
struct VisionRegistrarTests {

    /// 结构性周期页面：行位置等距固定，但每行的**内容各不相同**（长度与灰度
    /// 都按行号派生），模拟终端 / 代码 / 聊天记录。
    private func paragraphPage(width: Int, pageHeight: Int, lineHeight: Int) -> ScrollshotImage? {
        var data = [UInt8](repeating: 246, count: width * pageHeight * 4)
        var row = 0
        while row < pageHeight {
            let index = row / lineHeight
            // 每行的文本长度、起始缩进、灰度都由行号决定 → 行行不同，位置等距。
            let length = 60 + (index &* 137) % max(1, width - 140)
            let indent = 20 + (index &* 61) % 40
            let tone = UInt8(20 + (index &* 53) % 90)
            for y in row..<min(row + lineHeight - 4, pageHeight) {
                for x in indent..<min(indent + length, width - 20) {
                    let offset = (y * width + x) * 4
                    data[offset] = tone
                    data[offset + 1] = tone
                    data[offset + 2] = UInt8(min(255, Int(tone) + 12))
                    data[offset + 3] = 255
                }
            }
            row += lineHeight
        }
        return ScrollshotImage(width: width, height: pageHeight, data: data)
    }

    /// 给帧盖上一条**不随滚动移动**的顶栏（吸顶栏 / 固定工具栏）。
    private func withFixedBar(_ image: ScrollshotImage, rows: Int) -> ScrollshotImage? {
        var data = image.data
        let rowBytes = image.width * 4
        for y in 0..<min(rows, image.height) {
            for x in 0..<image.width {
                let offset = y * rowBytes + x * 4
                data[offset] = 30
                data[offset + 1] = 60
                data[offset + 2] = 120
                data[offset + 3] = 255
            }
        }
        return ScrollshotImage(width: image.width, height: image.height, data: data)
    }

    @Test("合成页面：中等位移被解出，大位移由评分器兜底")
    func resolvesShifts() throws {
        let page = makePage(width: 600, pageHeight: 6000)
        let base = 2600
        let frameHeight = 900
        for shift in [-880, -600, -450, -300, -120, -30, 30, 120, 300, 450, 600, 880] {
            let previous = slice(page, offset: base, height: frameHeight)
            let next = slice(page, offset: base + shift, height: frameHeight)
            guard let estimate = VisionRegistrar.estimate(previous: previous, next: next) else {
                print("[vision] 真值 \(shift) → 无结果")
                continue
            }
            // 重叠比例：位移越大，两帧共同可见的部分越少。
            let overlapRatio = Double(frameHeight - abs(shift)) / Double(frameHeight)
            let ok = abs(estimate.deltaY - shift) <= 2
            print(
                "[vision] 真值 \(shift) → 解出 \(estimate.deltaY)  "
                    + "重叠 \(String(format: "%.0f%%", overlapRatio * 100))  \(ok ? "✓" : "✗")"
            )
        }
    }

    @Test("结构性周期内容（终端/代码的样子）：位移仍被解出")
    func resolvesParagraphContent() throws {
        let lineHeight = 32
        let page = try #require(paragraphPage(width: 700, pageHeight: 6000, lineHeight: lineHeight))
        let base = 2000
        for shift in [20, 40, 60, 120, 240, 480] {
            let previous = slice(page, offset: base, height: 900)
            let next = slice(page, offset: base + shift, height: 900)
            let estimate = try #require(
                VisionRegistrar.estimate(previous: previous, next: next),
                "位移 \(shift) 没有结果"
            )
            #expect(
                abs(estimate.deltaY - shift) <= 2,
                "位移 \(shift) 被解成 \(estimate.deltaY)（行距 \(lineHeight)）"
            )
        }
    }

    @Test("顶部固定栏：裁掉之后仍解出内容自身的位移")
    func cropsStickyHeader() throws {
        let page = makePage(width: 600, pageHeight: 6000)
        let base = 2000
        let shift = 240
        let barRows = 120
        let previous = try #require(withFixedBar(slice(page, offset: base, height: 900), rows: barRows))
        let next = try #require(withFixedBar(slice(page, offset: base + shift, height: 900), rows: barRows))

        let estimate = try #require(
            VisionRegistrar.estimate(previous: previous, next: next, topCrop: barRows)
        )
        #expect(
            abs(estimate.deltaY - shift) <= 2,
            "裁掉 \(barRows) 行固定栏后解出 \(estimate.deltaY)，真值 \(shift)"
        )
    }

    @Test("裁剪过量：明确放弃求解，而不是给出一个错的答案")
    func refusesWhenCroppedTooSmall() throws {
        let page = makePage(width: 600, pageHeight: 6000)
        let previous = slice(page, offset: 2000, height: 900)
        let next = slice(page, offset: 2200, height: 900)
        // 顶部与底部各要求裁 500 行，但各自上限是帧高的 1/5（180），
        // 剩余 900 − 360 = 540 行仍够用 → 这里应当**仍然给出正确答案**，
        // 用来证明「上限截断」本身不会把可解的情形误杀。
        let clamped = try #require(
            VisionRegistrar.estimate(previous: previous, next: next, topCrop: 500, bottomCrop: 500)
        )
        #expect(abs(clamped.deltaY - 200) <= 2, "上限截断后解出 \(clamped.deltaY)")

        // 真正的「裁到不够」：帧本身就只有 60 行，裁完不足 50 行 → 必须返回 nil。
        let tinyPrevious = slice(page, offset: 2000, height: 60)
        let tinyNext = slice(page, offset: 2020, height: 60)
        #expect(
            VisionRegistrar.estimate(previous: tinyPrevious, next: tinyNext, topCrop: 20) == nil,
            "裁剪后只剩 40 行时应当明确放弃"
        )
    }
}
