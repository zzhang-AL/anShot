//
//  OCRTests.swift
//  AnShotCoreTests
//
//  OCR 结果模型与坐标转换的测试。
//
//  契约（`m3-advanced/model.md` §4.2）点名要求：「转换函数必须有单元测试，
//  覆盖『图像上下翻转后包围盒仍对齐』这一情形」。这里是那条要求的落地。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

@Suite("OCR 坐标转换与阅读顺序")
struct OCRTests {

    @Test("覆盖全图的归一化框转成整幅像素矩形")
    func fullImageBox() {
        let rect = OCRCoordinateConversion.pixelRect(
            normalized: CGRect(x: 0, y: 0, width: 1, height: 1),
            imagePixelSize: PixelSize(width: 800, height: 600)
        )
        #expect(rect.origin.x == 0)
        #expect(rect.origin.y == 0)
        #expect(rect.size.width == 800)
        #expect(rect.size.height == 600)
    }

    @Test("翻转对齐：归一化 y 高（图像上部）的框，像素下应落在图像上方")
    func topOfImageStaysOnTop() {
        // Vision 原点在左下：y = 0.8 且高 0.1 的框是**图像上部**那条。
        // 若漏掉 y 翻转，它会落到图像底部——这正是契约要求锁死的错法。
        let rect = OCRCoordinateConversion.pixelRect(
            normalized: CGRect(x: 0, y: 0.8, width: 1, height: 0.1),
            imagePixelSize: PixelSize(width: 1000, height: 1000)
        )
        // 浮点：1 − 0.8 − 0.1 在二进制下不精确，用容差比较。
        #expect(abs(rect.origin.y - 100) < 0.001, "上部框的顶边应在 y=100，实测 \(rect.origin.y)")
        #expect(abs(rect.size.height - 100) < 0.001)

        // 反过来：y = 0（图像下部）的框，像素下应落在图像下方。
        let bottom = OCRCoordinateConversion.pixelRect(
            normalized: CGRect(x: 0, y: 0, width: 1, height: 0.1),
            imagePixelSize: PixelSize(width: 1000, height: 1000)
        )
        #expect(abs(bottom.origin.y - 900) < 0.001, "下部框的顶边应在 y=900，实测 \(bottom.origin.y)")
    }

    @Test("横向不翻转，只按宽度缩放")
    func horizontalIsNotFlipped() {
        let rect = OCRCoordinateConversion.pixelRect(
            normalized: CGRect(x: 0.25, y: 0, width: 0.5, height: 1),
            imagePixelSize: PixelSize(width: 400, height: 200)
        )
        #expect(rect.origin.x == 100)
        #expect(rect.size.width == 200)
        #expect(rect.origin.y == 0)
        #expect(rect.size.height == 200)
    }

    @Test("非方形图像：两个方向各按自己的尺寸缩放")
    func nonSquareImage() {
        let rect = OCRCoordinateConversion.pixelRect(
            normalized: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            imagePixelSize: PixelSize(width: 800, height: 400)
        )
        // x: 0.5 × 800 = 400；y（翻转）: (1 − 0.5 − 0.5) × 400 = 0
        #expect(rect.origin.x == 400)
        #expect(rect.origin.y == 0)
        #expect(rect.size.width == 400)
        #expect(rect.size.height == 200)
    }

    @Test("阅读顺序：先上后下，同一行内先左后右")
    func readingOrder() {
        func line(_ text: String, x: Double, y: Double) -> OCRTextLine {
            OCRTextLine(
                text: text, candidates: [], confidence: 0.9,
                boundingBox: PixelRect(
                    origin: PixelPoint(x: x, y: y),
                    size: PixelSize(width: 50, height: 20)
                )
            )
        }
        // 故意打乱顺序，且让同一行的两段有 2px 的行高差（真实识别的常见情形）。
        let shuffled = [
            line("第二行左", x: 10, y: 100),
            line("第一行右", x: 200, y: 2),
            line("第二行右", x: 200, y: 102),
            line("第一行左", x: 10, y: 0),
        ]
        let ordered = OCRResult.readingOrder(shuffled).map(\.text)
        #expect(ordered == ["第一行左", "第一行右", "第二行左", "第二行右"])
    }

    @Test("纯文本按行拼接")
    func plainText() {
        let result = OCRResult(
            lines: [
                OCRTextLine(
                    text: "第一行", candidates: ["1"], confidence: 0.9,
                    boundingBox: PixelRect(origin: .zero, size: PixelSize(width: 10, height: 10))
                ),
                OCRTextLine(
                    text: "第二行", candidates: [], confidence: 0.8,
                    boundingBox: PixelRect(origin: PixelPoint(x: 0, y: 20), size: PixelSize(width: 10, height: 10))
                ),
            ],
            imagePixelSize: PixelSize(width: 100, height: 100)
        )
        #expect(result.plainText == "第一行\n第二行")
        #expect(!result.isEmpty)
    }
}
