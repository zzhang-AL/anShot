//
//  ColorSpacesTests.swift
//  AnShotCoreTests
//
//  HSV ↔ sRGB 互转与十六进制解析的单元测试。
//
//  取色器依赖这些换算：色相条拖动、取色区拖动、Hex 输入三条路径
//  最终都要落到同一个 `RGBAColor` 上，换算错了会表现为「拖动时颜色跳」，
//  那种缺陷很难靠肉眼看出来。
//

import Testing
import Foundation
@testable import AnShotCore

@Suite("色彩空间 · HSV 互转")
struct ColorSpacesTests {

    /// 允许的浮点误差：转换里有多处乘除与取模。
    private let tolerance = 1e-9

    private func expectClose(
        _ actual: Double,
        _ expected: Double,
        _ label: String
    ) {
        #expect(abs(actual - expected) < 1e-6, "\(label)：实际 \(actual)，期望 \(expected)")
    }

    @Test("三原色与其间的三色互为 60 度整数倍")
    func primariesHaveExpectedHues() {
        let cases: [(RGBAColor, Double)] = [
            (RGBAColor(r: 1, g: 0, b: 0, a: 1), 0),
            (RGBAColor(r: 1, g: 1, b: 0, a: 1), 60),
            (RGBAColor(r: 0, g: 1, b: 0, a: 1), 120),
            (RGBAColor(r: 0, g: 1, b: 1, a: 1), 180),
            (RGBAColor(r: 0, g: 0, b: 1, a: 1), 240),
            (RGBAColor(r: 1, g: 0, b: 1, a: 1), 300),
        ]

        for (color, expectedHue) in cases {
            let hsv = color.hsv
            expectClose(hsv.hue, expectedHue, "色相")
            expectClose(hsv.saturation, 1, "饱和度")
            expectClose(hsv.value, 1, "明度")
        }
    }

    @Test("灰色没有饱和度，色相为 0 而不是 NaN")
    func grayHasZeroSaturation() {
        for level in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let hsv = RGBAColor(r: level, g: level, b: level, a: 1).hsv
            expectClose(hsv.saturation, 0, "灰度饱和度")
            expectClose(hsv.value, level, "灰度明度")
            #expect(!hsv.hue.isNaN, "灰度色相不应是 NaN")
        }
    }

    @Test("RGB → HSV → RGB 往返一致")
    func roundTripThroughHSV() {
        let samples: [RGBAColor] = [
            RGBAColor(r: 1, g: 0.23, b: 0.19, a: 1),
            RGBAColor(r: 0, g: 0.48, b: 1, a: 1),
            RGBAColor(r: 0.20, g: 0.78, b: 0.35, a: 1),
            RGBAColor(r: 0.13, g: 0.62, b: 0.87, a: 1),
            RGBAColor(r: 0.5, g: 0.5, b: 0.5, a: 1),
            RGBAColor(r: 0, g: 0, b: 0, a: 1),
            RGBAColor(r: 1, g: 1, b: 1, a: 1),
        ]

        for original in samples {
            let restored = RGBAColor(hsv: original.hsv)
            expectClose(restored.r, original.r, "红分量往返")
            expectClose(restored.g, original.g, "绿分量往返")
            expectClose(restored.b, original.b, "蓝分量往返")
        }
    }

    @Test("明度或饱和度为 0 时色相无意义，但由 HSV 构造仍应给出正确灰度")
    func degenerateCasesProduceGray() {
        let black = RGBAColor(hsv: HSVColor(hue: 210, saturation: 1, value: 0))
        expectClose(black.r, 0, "明度 0 → 黑")
        expectClose(black.g, 0, "明度 0 → 黑")
        expectClose(black.b, 0, "明度 0 → 黑")

        let white = RGBAColor(hsv: HSVColor(hue: 210, saturation: 0, value: 1))
        expectClose(white.r, 1, "饱和度 0 → 白")
        expectClose(white.g, 1, "饱和度 0 → 白")
        expectClose(white.b, 1, "饱和度 0 → 白")
    }

    @Test("HSB 各分量被夹到合法范围")
    func hsvComponentsAreClamped() {
        let color = RGBAColor(hsv: HSVColor(hue: -30, saturation: 2, value: 3))
        #expect(color.r <= 1 && color.g <= 1 && color.b <= 1, "分量不得溢出")
        #expect(color.r >= 0 && color.g >= 0 && color.b >= 0, "分量不得为负")
    }

    @Test("十六进制往返")
    func hexRoundTrip() {
        let samples: [RGBAColor] = [
            RGBAColor(r: 1, g: 0.23, b: 0.19, a: 1),
            RGBAColor(r: 0, g: 0, b: 0, a: 1),
            RGBAColor(r: 1, g: 1, b: 1, a: 1),
            RGBAColor(r: 0.5, g: 0.5, b: 0.5, a: 1),
        ]

        for original in samples {
            let restored = RGBAColor(hexString: original.hexString)
            #expect(restored != nil, "应当能解析回自身")
            guard let restored else { continue }
            // 十六进制每通道只有 8 位精度，容差取 1/255。
            #expect(abs(restored.r - original.r) <= 1.0 / 255, "红分量往返")
            #expect(abs(restored.g - original.g) <= 1.0 / 255, "绿分量往返")
            #expect(abs(restored.b - original.b) <= 1.0 / 255, "蓝分量往返")
        }
    }

    @Test("十六进制解析容错：大小写、井号、三位缩写")
    func hexParsingIsLenient() {
        let expected = RGBAColor(r: 1, g: 0, b: 0, a: 1)

        for text in ["FF0000", "ff0000", "#FF0000", "#ff0000", "F00", "#f00"] {
            let parsed = RGBAColor(hexString: text)
            #expect(parsed != nil, "\(text) 应当可解析")
            guard let parsed else { continue }
            #expect(abs(parsed.r - expected.r) < tolerance + 1e-6, "\(text) 红分量")
            #expect(abs(parsed.g - expected.g) < tolerance + 1e-6, "\(text) 绿分量")
            #expect(abs(parsed.b - expected.b) < tolerance + 1e-6, "\(text) 蓝分量")
        }
    }

    @Test("非法十六进制返回 nil 而不是黑色")
    func invalidHexReturnsNil() {
        // 返回黑色会让用户看到「输入乱码变成黑」这种莫名其妙的反馈。
        for text in ["", "#", "XYZ", "12345", "1234567", "#GGGGGG"] {
            #expect(RGBAColor(hexString: text) == nil, "\(text) 应当解析失败")
        }
    }
}
