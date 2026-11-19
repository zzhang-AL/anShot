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

    @Test("多栏阶梯框满足严格弱序且排序确定性")
    func staggeredColumnsHaveDeterministicOrder() {
        func line(_ text: String, x: Double, y: Double, width: Double = 40, height: Double = 10) -> OCRTextLine {
            OCRTextLine(
                text: text, candidates: [], confidence: 0.9,
                boundingBox: PixelRect(
                    origin: PixelPoint(x: x, y: y),
                    size: PixelSize(width: width, height: height)
                )
            )
        }
        // 审查报告反例：A(y:0..10)、B(y:4..14)、C(y:8..18) 在旧比较器下会形成循环比较。
        let a = line("A", x: 200, y: 0)
        let b = line("B", x: 100, y: 4)
        let c = line("C", x: 0, y: 8)
        let expected = ["B", "A", "C"]

        // 无论输入如何排列，输出必须完全确定。
        let permutations = [
            [a, b, c],
            [c, b, a],
            [b, c, a],
            [a, c, b],
        ]
        for input in permutations {
            #expect(OCRResult.readingOrder(input).map(\.text) == expected)
        }

        // 覆盖行带内多列与多行交错情形。
        let multi = [
            line("R2C3", x: 300, y: 40, height: 14),
            line("R1C2", x: 150, y: 12, height: 14),
            line("R2C1", x: 20, y: 42, height: 14),
            line("R1C1", x: 20, y: 10, height: 14),
            line("R2C2", x: 150, y: 39, height: 14),
        ]
        #expect(OCRResult.readingOrder(multi).map(\.text) == ["R1C1", "R1C2", "R2C1", "R2C2", "R2C3"])
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

    @Test("段落软换行合并：英文连字符拼接、CJK 紧拼不插空格、列表项与空行保留分段")
    func paragraphMergerHandlesCJKHyphenAndLists() {
        let raw = """
        这是一段被截图软换行的中文
        继续接在上一句后面没有空格
        The quick brown fox imple-
        mentation works well
        - 第一条列表项
        - 第二条列表项

        空行之后的独立新段落
        """
        let merged = OCRParagraphMerger.merge(plainText: raw)
        let lines = merged.components(separatedBy: "\n")
        #expect(lines.contains { $0.contains("中文继续接在上一句") })
        #expect(lines.contains { $0.contains("implementation works well") })
        #expect(lines.contains("- 第一条列表项"))
        #expect(lines.contains("- 第二条列表项"))
        #expect(lines.last == "空行之后的独立新段落")
    }

    @Test("超长图分块 OCR 瓦片规划完整覆盖且重叠区空间去重保留更完整行")
    func tilePlannerCoverageAndSpatialDeduplication() {
        #expect(!OCRTilePlanner.shouldTile(width: 1920, height: 1080))
        #expect(OCRTilePlanner.shouldTile(width: 1440, height: 8000))
        #expect(OCRTilePlanner.shouldTile(width: 600, height: 3000))

        let tiles = OCRTilePlanner.planTiles(width: 1440, height: 6000)
        #expect(tiles.count >= 3)
        #expect(tiles.first?.y == 0)
        #expect((tiles.last!.y + tiles.last!.height) == 6000)
        for index in 1 ..< tiles.count {
            let prevEnd = tiles[index - 1].y + tiles[index - 1].height
            #expect(tiles[index].y < prevEnd, "相邻瓦片应有重叠区以防拦腰切断文字")
        }

        // 重叠区两份重复行应合并为置信度更高 / 文本更完整的一份。
        let lineA = OCRTextLine(
            text: "重复行内容",
            candidates: ["重复行内容"],
            confidence: 0.72,
            boundingBox: PixelRect(origin: PixelPoint(x: 40, y: 1900), size: PixelSize(width: 200, height: 28))
        )
        let lineB = OCRTextLine(
            text: "重复行内容完整版",
            candidates: ["重复行内容完整版"],
            confidence: 0.95,
            boundingBox: PixelRect(origin: PixelPoint(x: 42, y: 1901), size: PixelSize(width: 240, height: 28))
        )
        let lineC = OCRTextLine(
            text: "另一行独立文字",
            candidates: ["另一行独立文字"],
            confidence: 0.9,
            boundingBox: PixelRect(origin: PixelPoint(x: 40, y: 2100), size: PixelSize(width: 220, height: 28))
        )
        let deduped = OCRTilePlanner.deduplicateTiledLines([lineA, lineB, lineC])
        #expect(deduped.count == 2)
        #expect(deduped.first?.text == "重复行内容完整版")
        #expect(deduped.last?.text == "另一行独立文字")
    }

    @Test("二维码载荷准确识别 HTTP/HTTPS 网页链接与纯文本，语言偏好展开符合契约")
    func barcodeItemAndLanguagePreference() {
        let link = BarcodeItem(payload: "https://github.com/zzusec/isnip", symbology: "二维码")
        #expect(link.isWebURL)
        #expect(link.webURL?.host == "github.com")

        let plain = BarcodeItem(payload: "WIFI:T:WPA;S:Office;P:123456;;", symbology: "二维码")
        #expect(!plain.isWebURL)
        #expect(plain.webURL == nil)

        #expect(OCRLanguagePreference.auto.recognitionLanguages == ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"])
        #expect(TranslationProviderKind.appleTranslation.requiredSystemVersion == "macOS 15.0")
        #expect(TranslationLanguage.commonTargetLanguages.count == 7)
    }
}
