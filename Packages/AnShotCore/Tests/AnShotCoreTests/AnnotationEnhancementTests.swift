//
//  AnnotationEnhancementTests.swift
//  AnShotCoreTests
//
//  覆盖核心渲染、广色域、几何容差、高斯模糊、手绘风与细节打磨的增强单测。
//

import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import AnShotCore

@Suite("渲染与几何增强验证")
struct AnnotationEnhancementTests {

    // MARK: - 放大镜边界防畸变（P0-8）

    @Test("放大镜贴近画布边缘时不会触发裁剪拉伸畸变")
    func magnifierNearEdgeDoesNotStretch() throws {
        // 底图：x ∈ [0, 30) 为红，其余为白。
        // 放大镜圆心设在 (10, 50)、半径 30、倍率 2：圆左侧超出画布边界，
        // 若用 cropping+draw 拉伸，红白分界会被整体拉歪；
        // 修复后圆心 (10,50) 处原 x=30 应映射至 10 + (30-10)*2 = 50（仍在白区内且分界笔直）。
        let backdrop = regionedImage(
            width: 200,
            height: 100,
            background: white,
            regions: [(0, 0, 20, 100, red)]
        )
        let magnifier = Annotation(kind: .magnifier(
            center: PixelPoint(x: 10, y: 50),
            radius: 30,
            zoom: 2,
            border: StrokeStyle(color: black, width: 2)
        ))

        let image = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 200, 100),
            annotations: [magnifier]
        ))
        let pixels = PixelBuffer(image)

        // 圆心 x=10 处仍映射原 x=10（红色）
        expectColor(pixels.rgb(x: 10, y: 50), (255, 0, 0), "贴边放大镜圆心应保持原红区")
        // 原图红白分界在 x=20，放大 2 倍后应恰好推到 x = 10 + (20 - 10) * 2 = 30
        expectColor(pixels.rgb(x: 26, y: 50), (255, 0, 0), "分界左侧（x=26）应为放大后的红色")
        expectColor(pixels.rgb(x: 34, y: 50), (255, 255, 255), "分界右侧（x=34）应为白色，无拉伸错位")
    }

    // MARK: - 涂抹马赛克局部掩码与全模式（P1-12 & P1-21）

    @Test("涂抹马赛克支持像素化、高斯模糊与纯色遮盖，且无边缘黑晕")
    func mosaicStrokeAllModesAndEdgeExtend() throws {
        let backdrop = regionedImage(
            width: 400,
            height: 300,
            background: white,
            regions: [
                (120, 80, 100, 100, black),
                (220, 80, 100, 100, white),
            ]
        )
        let selection = rect(120, 80, 200, 200)

        // 1. 涂抹高斯模糊跨越黑白边界 (x=220, y=130)
        let blurStroke = Annotation(kind: .mosaicStroke(
            points: [PixelPoint(x: 190, y: 130), PixelPoint(x: 250, y: 130)],
            radius: 18,
            mode: .blur,
            intensity: 10
        ))
        let blurImage = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: selection,
            annotations: [blurStroke]
        ))
        let blurPixels = PixelBuffer(blurImage)
        // 画布 (100, 50) 对应底图 (220, 130) 黑白交界
        let blurredEdge = blurPixels.rgb(x: 100, y: 50)
        #expect(blurredEdge.r > 20 && blurredEdge.r < 235, "涂抹模糊在交界处应有平滑中间灰阶，实际 \(blurredEdge)")
        // 远处画布右下角保持白色
        expectColor(blurPixels.rgb(x: 190, y: 190), (255, 255, 255), "涂抹范围外不应被改变")

        // 2. 贴画布边缘的高斯模糊对纯白底图不应产生任何边缘黑晕
        let whiteBackdrop = solidImage(width: 100, height: 100, color: white)
        let edgeBlur = Annotation(kind: .mosaic(
            rect: rect(0, 0, 100, 100),
            mode: .blur,
            intensity: 12
        ))
        let edgeBlurImage = try #require(AnnotationRenderer.render(
            backdrop: whiteBackdrop,
            selection: rect(0, 0, 100, 100),
            annotations: [edgeBlur]
        ))
        let edgePixels = PixelBuffer(edgeBlurImage)
        expectColor(edgePixels.rgb(x: 0, y: 0), (255, 255, 255), "边缘像素模糊后不得产生黑晕")
        expectColor(edgePixels.rgb(x: 99, y: 99), (255, 255, 255), "右下角边缘像素不得产生黑晕")

        // 3. 涂抹纯色遮盖
        let solidStroke = Annotation(kind: .mosaicStroke(
            points: [PixelPoint(x: 260, y: 130), PixelPoint(x: 290, y: 130)],
            radius: 14,
            mode: .solid,
            intensity: 0
        ))
        let solidImage = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: selection,
            annotations: [solidStroke]
        ))
        let solidPixels = PixelBuffer(solidImage)
        // 底图 (275, 130) -> 画布 (155, 50) 原为白色，涂抹纯色遮盖后应为纯黑
        expectColor(solidPixels.rgb(x: 155, y: 50), (0, 0, 0), "涂抹纯色遮盖处应变为不透明黑色")
        expectColor(solidPixels.rgb(x: 155, y: 150), (255, 255, 255), "涂抹路径外应保持底图白色")
    }

    // MARK: - 几何对齐容差与 clamp（P1-13）

    @Test("alignedRect 浮点容差消除 IEEE 754 尾数导致的 1px 杂边")
    func alignedRectAbsorbsFloatingPointNoise() throws {
        let backdrop = solidImage(width: 200, height: 200, color: white)
        // 模拟逻辑点 * scaleFactor 往返误差：10.999999999999996 与 111.00000000000001
        let noisySelection = rect(10.999999999999996, 20.000000000000004, 100.00000000000001, 50.00000000000001)
        let rendered = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: noisySelection,
            annotations: []
        ))
        #expect(rendered.width == 100, "容差应吸收尾数避免膨胀成 101/102")
        #expect(rendered.height == 50)

        let snapped = CoordinateConversion.snappedPixelRect(noisySelection)
        #expect(snapped == rect(11, 20, 100, 50))

        let logical = CGRect(x: 10.0, y: 20.0, width: 100.0, height: 50.0)
        let snappedLogical = CoordinateConversion.snappedLogicalRect(logical, scaleFactor: 1.5)
        #expect(snappedLogical == logical)
    }

    @Test("SelectionGeometry.clamp 同步钳制超界宽高，防止越出边界")
    func clampRestrictsOversizedRect() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let oversized = CGRect(x: -50, y: 150, width: 500, height: 400)
        let clamped = SelectionGeometry.clamp(oversized, to: bounds)

        #expect(clamped.width <= bounds.width)
        #expect(clamped.height <= bounds.height)
        #expect(clamped.minX >= bounds.minX)
        #expect(clamped.minY >= bounds.minY)
        #expect(clamped.maxX <= bounds.maxX)
        #expect(clamped.maxY <= bounds.maxY)
        #expect(clamped == bounds)
    }

    // MARK: - Display P3 广色域保留（P1-14）

    @Test("Display P3 广色域底图经过渲染与裁剪后保持 P3 色域不降级")
    func displayP3ColorSpaceIsPreserved() throws {
        let p3Space = ImageColorSpace.displayP3
        #expect(ImageColorSpace.isSupportedRGBBitmapOutput(p3Space))

        let context = try #require(CGContext(
            data: nil,
            width: 80,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: p3Space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        let p3Red = try #require(CGColor(colorSpace: p3Space, components: [1.0, 0.0, 0.0, 1.0]))
        context.setFillColor(p3Red)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        let p3Backdrop = try #require(context.makeImage())

        let rendered = try #require(AnnotationRenderer.render(
            backdrop: p3Backdrop,
            selection: rect(10, 10, 40, 40),
            annotations: []
        ))
        let cropped = try #require(AnnotationRenderer.crop(
            backdrop: p3Backdrop,
            selection: rect(10, 10, 40, 40)
        ))

        #expect(rendered.colorSpace?.name == CGColorSpace.displayP3)
        #expect(cropped.colorSpace?.name == CGColorSpace.displayP3)

        // 用 P3 上下文读回像素，验证纯 P3 红 (255, 0, 0) 未被截断
        var buffer = [UInt8](repeating: 0, count: 40 * 40 * 4)
        buffer.withUnsafeMutableBytes { raw in
            let readCtx = CGContext(
                data: raw.baseAddress,
                width: 40,
                height: 40,
                bitsPerComponent: 8,
                bytesPerRow: 40 * 4,
                space: p3Space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            readCtx?.draw(rendered, in: CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        #expect(buffer[0] == 255 && buffer[1] == 0 && buffer[2] == 0)
    }

    // MARK: - 手绘双描边渲染（P1-21）

    @Test("手绘风格 isSketchy 基于标注 id 确定性渲染且重绘不抖动")
    func sketchyRenderingIsDeterministicAndDistinct() throws {
        let backdrop = solidImage(width: 200, height: 200, color: white)
        let idA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let idB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let normalStyle = StrokeStyle(color: black, width: 3, isSketchy: false)
        let sketchyStyle = StrokeStyle(color: black, width: 3, isSketchy: true)

        let normalRect = Annotation(id: idA, kind: .rectangle(
            rect: rect(30, 30, 120, 100),
            stroke: normalStyle,
            fill: nil,
            cornerRadius: 0
        ))
        let sketchyRectA = Annotation(id: idA, kind: .rectangle(
            rect: rect(30, 30, 120, 100),
            stroke: sketchyStyle,
            fill: nil,
            cornerRadius: 0
        ))
        let sketchyRectB = Annotation(id: idB, kind: .rectangle(
            rect: rect(30, 30, 120, 100),
            stroke: sketchyStyle,
            fill: nil,
            cornerRadius: 0
        ))

        let imgNormal = try #require(AnnotationRenderer.render(backdrop: backdrop, selection: rect(0, 0, 200, 200), annotations: [normalRect]))
        let imgSketchyA1 = try #require(AnnotationRenderer.render(backdrop: backdrop, selection: rect(0, 0, 200, 200), annotations: [sketchyRectA]))
        let imgSketchyA2 = try #require(AnnotationRenderer.render(backdrop: backdrop, selection: rect(0, 0, 200, 200), annotations: [sketchyRectA]))
        let imgSketchyB = try #require(AnnotationRenderer.render(backdrop: backdrop, selection: rect(0, 0, 200, 200), annotations: [sketchyRectB]))

        let bufNormal = PixelBuffer(imgNormal).bytes
        let bufA1 = PixelBuffer(imgSketchyA1).bytes
        let bufA2 = PixelBuffer(imgSketchyA2).bytes
        let bufB = PixelBuffer(imgSketchyB).bytes

        #expect(bufA1 == bufA2, "同一 id 多次重绘结果必须逐像素完全一致")
        #expect(bufA1 != bufNormal, "手绘风格应与规整风格存在描边微扰差异")
        #expect(bufA1 != bufB, "不同 id 应产生不同的确定性手绘微扰")

        // 覆盖直线、箭头、弯曲箭头、自由曲线手绘渲染不崩溃且不溢出
        let sketchyVariants: [Annotation] = [
            Annotation(id: idA, kind: .line(start: PixelPoint(x: 20, y: 20), end: PixelPoint(x: 160, y: 40), stroke: sketchyStyle)),
            Annotation(id: idA, kind: .arrow(start: PixelPoint(x: 20, y: 70), end: PixelPoint(x: 160, y: 70), stroke: sketchyStyle, headLength: 16, headWidth: 12)),
            Annotation(id: idA, kind: .curvedArrow(start: PixelPoint(x: 20, y: 120), control: PixelPoint(x: 90, y: 170), end: PixelPoint(x: 160, y: 120), stroke: sketchyStyle, headLength: 16, headWidth: 12)),
            Annotation(id: idA, kind: .freehand(points: [PixelPoint(x: 30, y: 160), PixelPoint(x: 90, y: 180), PixelPoint(x: 150, y: 150)], stroke: sketchyStyle)),
        ]
        let allRendered = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 200, 200),
            annotations: sketchyVariants
        ))
        let allPixels = PixelBuffer(allRendered)
        expectColor(allPixels.rgb(x: 2, y: 2), (255, 255, 255), "手绘矢量不应溢出画布边界")
    }

    // MARK: - 序号重排、百位数自适应、弯箭头、测量、文字、容错解码、椭圆（P1-17 / P2-2 / P2-10）

    @Test("编号序列重排与 nextNumberingIndex 推导")
    func numberingRenumbering() {
        let stroke = StrokeStyle(color: red, width: 2)
        let n1 = Annotation(kind: .numbering(center: PixelPoint(x: 10, y: 10), radius: 14, index: 1, stroke: stroke, fill: white, textColor: black))
        let line = Annotation(kind: .line(start: PixelPoint(x: 0, y: 0), end: PixelPoint(x: 50, y: 0), stroke: stroke))
        let n3 = Annotation(kind: .numbering(center: PixelPoint(x: 60, y: 10), radius: 14, index: 3, stroke: stroke, fill: white, textColor: black))

        let list = [n1, line, n3]
        #expect([Annotation]().nextNumberingIndex == 1)
        #expect(list.nextNumberingIndex == 4)

        let renumbered = list.renumbered()
        #expect(renumbered.count == 3)
        #expect(renumbered[0].id == n1.id)
        #expect(renumbered[1] == line)
        #expect(renumbered[2].id == n3.id)

        if case let .numbering(_, _, index0, _, _, _) = renumbered[0].kind,
           case let .numbering(_, _, index2, _, _, _) = renumbered[2].kind {
            #expect(index0 == 1)
            #expect(index2 == 2)
        } else {
            Issue.record("重排后标注类型应保持为 numbering")
        }
        #expect(renumbered.nextNumberingIndex == 3)
    }

    @Test("百位以上编号自适应缩小字号，不穿出圆形边界")
    func numberingHundredsFitsInsideCircle() throws {
        let backdrop = solidImage(width: 100, height: 100, color: white)
        let annotation = Annotation(kind: .numbering(
            center: PixelPoint(x: 50, y: 50),
            radius: 18,
            index: 108,
            stroke: StrokeStyle(color: red, width: 2),
            fill: white,
            textColor: black
        ))
        let image = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 100, 100),
            annotations: [annotation]
        ))
        let pixels = PixelBuffer(image)
        // 圆外左右两侧（x=28, y=50 与 x=72, y=50，距圆心 22px > radius 18 + stroke 1）应保持白底
        expectColor(pixels.rgb(x: 28, y: 50), (255, 255, 255), "百位数序号不得向左侧穿出圆框")
        expectColor(pixels.rgb(x: 72, y: 50), (255, 255, 255), "百位数序号不得向右侧穿出圆框")
    }

    @Test("弯曲箭头紧致包围盒在控制点出界但曲线在界内时可通过校验，且箭头两翼可命中")
    func curvedArrowTightBoundsAndWingHitTest() throws {
        // 控制点在 x=-30（底图外），但曲线本身全部落在 x >= 0 内：
        // start=(0, 50), control=(-30, 50), end=(60, 50) → 实际最小 x 为 0！
        // wait: start=(10, 50), control=(-8, 50), end=(60, 50) -> x'(t)=0 => t = 18/86 ≈ 0.209 => x(t) ≈ 6.23 >= 0!
        let curve = Annotation(kind: .curvedArrow(
            start: PixelPoint(x: 10, y: 50),
            control: PixelPoint(x: -8, y: 50),
            end: PixelPoint(x: 80, y: 50),
            stroke: StrokeStyle(color: red, width: 2),
            headLength: 24,
            headWidth: 24
        ))
        #expect(curve.boundingRect.origin.x >= 0, "曲线紧致包围盒左边界应落在底图内")

        let session = CaptureSession(
            backdrop: Backdrop(pixelWidth: 200, pixelHeight: 200, scaleFactor: 1),
            selection: rect(0, 0, 200, 200),
            annotations: [curve]
        )
        try session.validate()

        // 箭头两翼命中：tip=(80, 50), control=(-8, 50), headBase=(56, 50), left/right 在 y = 50 ± 12
        #expect(curve.hitTest(PixelPoint(x: 60, y: 59), tolerance: 0), "弯曲箭头上翼三角形区域应命中")
        #expect(curve.hitTest(PixelPoint(x: 60, y: 41), tolerance: 0), "弯曲箭头下翼三角形区域应命中")

        let straightArrow = Annotation(kind: .arrow(
            start: PixelPoint(x: 10, y: 50),
            end: PixelPoint(x: 100, y: 50),
            stroke: StrokeStyle(color: red, width: 2),
            headLength: 24,
            headWidth: 24
        ))
        #expect(straightArrow.hitTest(PixelPoint(x: 80, y: 59), tolerance: 0), "直线箭头两翼三角形区域应命中")
    }

    @Test("测量标注沿法向量偏移绘制底板并钳制到画布内，避免竖线穿字与顶边裁切")
    func measureOffsetAndClamp() throws {
        let backdrop = solidImage(width: 200, height: 200, color: white)

        // 1. 垂直竖线：读数应向右侧法向偏移，线段中点 (100, 100) 本身应保持纯红描边（不被底板/文字穿插遮挡）
        let verticalMeasure = Annotation(kind: .measure(
            start: PixelPoint(x: 100, y: 40),
            end: PixelPoint(x: 100, y: 160),
            stroke: StrokeStyle(color: red, width: 2)
        ))
        let vertImg = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 200, 200),
            annotations: [verticalMeasure]
        ))
        let vertPixels = PixelBuffer(vertImg)
        expectColor(vertPixels.rgb(x: 100, y: 100), (255, 0, 0), "竖线中点应保持红线不被文字遮穿")

        // 2. 贴顶水平线 (20, 6) -> (180, 6)：读数必须自动翻转到线下方且位于画布内
        let topMeasure = Annotation(kind: .measure(
            start: PixelPoint(x: 20, y: 6),
            end: PixelPoint(x: 180, y: 6),
            stroke: StrokeStyle(color: black, width: 2)
        ))
        let topImg = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 200, 200),
            annotations: [topMeasure]
        ))
        let topPixels = PixelBuffer(topImg)
        // 线段下方 x ∈ [80, 120], y ∈ [12, 36] 区域应存在底板/文字的非纯白像素
        var nonWhiteBelow = 0
        for y in 12 ..< 36 {
            for x in 80 ..< 120 {
                let c = topPixels.rgb(x: x, y: y)
                if c.r < 250 || c.g < 250 || c.b < 250 {
                    nonWhiteBelow += 1
                }
            }
        }
        #expect(nonWhiteBelow > 30, "贴顶测量读数应自动翻转至线下方显示在画布内")
    }

    @Test("TextMetrics 系统字体构造与末尾换行高度在有无 maxWidth 下保持一致")
    func textMetricsSystemFontAndTrailingNewline() {
        let regular = FontDescriptor.system(size: 24, weight: 400, italic: false)
        let boldItalic = FontDescriptor.system(size: 24, weight: 700, italic: true)

        let regularFont = TextMetrics.font(for: regular)
        let boldItalicFont = TextMetrics.font(for: boldItalic)
        #expect(CTFontGetSize(regularFont) == 24)
        #expect(CTFontGetSize(boldItalicFont) == 24)

        let withoutMaxWidth = Annotation(kind: .text(
            origin: PixelPoint(x: 10, y: 40),
            text: "Hello\n",
            font: regular,
            color: black,
            background: nil,
            maxWidth: nil
        ))
        let withMaxWidth = Annotation(kind: .text(
            origin: PixelPoint(x: 10, y: 40),
            text: "Hello\n",
            font: regular,
            color: black,
            background: nil,
            maxWidth: 400
        ))
        #expect(
            abs(withoutMaxWidth.hitBoundingRect.size.height - withMaxWidth.hitBoundingRect.size.height) < 1e-6,
            "末尾换行在有无 maxWidth 下高度必须一致"
        )
    }

    @Test("AnnotationList 容错解码区分未知类型与损坏字段，并保留其余有效标注")
    func annotationListHandlesUnknownAndCorruptedItems() throws {
        let valid = Annotation(kind: .line(
            start: PixelPoint(x: 1, y: 2),
            end: PixelPoint(x: 30, y: 40),
            stroke: StrokeStyle(color: red, width: 2)
        ))
        let validData = try JSONEncoder().encode(valid)
        let validObj = try #require(try JSONSerialization.jsonObject(with: validData) as? [String: Any])

        let payload: [[String: Any]] = [
            validObj,
            ["id": UUID().uuidString, "type": "futureTool", "foo": 123], // unknownType
            ["id": UUID().uuidString, "type": "rectangle", "rect": "invalid"], // 已知类型字段损坏
            ["id": UUID().uuidString], // missingType
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(AnnotationList.self, from: data)

        #expect(decoded.annotations == [valid])
        #expect(decoded.skippedCount == 3)
    }

    @Test("预留椭圆绘制与命中辅助函数工作正常")
    func ellipseDrawingAndHitTestHelpers() throws {
        let stroke = StrokeStyle(color: red, width: 4)
        let bounds = rect(20, 20, 100, 60)

        // 命中测试：空心椭圆中心不命中、轮廓命中；填充椭圆中心命中
        #expect(!Annotation.hitTestEllipse(point: PixelPoint(x: 70, y: 50), rect: bounds, stroke: stroke, fill: nil, tolerance: 0))
        #expect(Annotation.hitTestEllipse(point: PixelPoint(x: 70, y: 20), rect: bounds, stroke: stroke, fill: nil, tolerance: 0))
        #expect(Annotation.hitTestEllipse(point: PixelPoint(x: 70, y: 50), rect: bounds, stroke: stroke, fill: white, tolerance: 0))

        // 绘制验证
        let context = try #require(CGContext(
            data: nil,
            width: 140,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: ImageColorSpace.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 140, height: 100))
        context.translateBy(x: 0, y: 100)
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.drawEllipse(bounds, stroke: stroke, fill: blueColor, in: context)

        let rendered = try #require(context.makeImage())
        let pixels = PixelBuffer(rendered)
        expectColor(pixels.rgb(x: 70, y: 50), (0, 0, 255), "椭圆中心应为蓝色填充")
        expectColor(pixels.rgb(x: 70, y: 20), (255, 0, 0), "椭圆顶点轮廓应为红色描边")
        expectColor(pixels.rgb(x: 22, y: 22), (255, 255, 255), "外接矩形角落应保持白底")
    }

    @Test("Annotation.Kind.ellipse 端到端序列化、命中、平移、校验与渲染（含手绘风）")
    func ellipseKindEndToEnd() throws {
        let bounds = rect(10, 15, 80, 50)
        let ellipse = Annotation(kind: .ellipse(
            rect: bounds,
            stroke: StrokeStyle(color: red, width: 4, isSketchy: true),
            fill: nil
        ))

        // 1. 扁平 JSON 序列化往返
        let data = try JSONEncoder().encode(ellipse)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        #expect(decoded == ellipse)
        #expect(decoded.kind.typeName == "ellipse")
        #expect(decoded.boundingRect == bounds)

        // 2. 平移与命中测试
        let moved = ellipse.translated(by: PixelPoint(x: 5, y: 10))
        #expect(moved.boundingRect == rect(15, 25, 80, 50))
        #expect(moved.hitTest(PixelPoint(x: 55, y: 25), tolerance: 1))
        #expect(!moved.hitTest(PixelPoint(x: 55, y: 50), tolerance: 1))

        // 3. 会话不变量校验与完整渲染
        let backdrop = regionedImage(width: 120, height: 100, background: white, regions: [])
        let session = CaptureSession(
            backdrop: Backdrop(pixelWidth: 120, pixelHeight: 100, scaleFactor: 1),
            selection: rect(0, 0, 120, 100),
            annotations: [moved]
        )
        try session.validate()
        let rendered = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 120, 100),
            annotations: [moved]
        ))
        let pixels = PixelBuffer(rendered)
        expectColor(pixels.rgb(x: 55, y: 50), (255, 255, 255), "空心椭圆中心保持白底")
    }

    // MARK: - 最低档马赛克与高斯模糊不可辨识验证

    @Test("最低档高斯模糊与马赛克在真实 2x 文本上彻底破坏可辨识轮廓")
    func lowestMosaicAndBlurEliminateReadableText() throws {
        // 模拟 2x Retina 屏常见 14pt 正文（28px 高黑字白底："123456 机密"）
        let width = 360
        let height = 100
        let textContext = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: ImageColorSpace.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        textContext.setFillColor(white.cgColor)
        textContext.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateUIFontForLanguage(.system, 28, nil) ?? CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 28, nil)
        let attrString = NSAttributedString(
            string: "123456 机密",
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
        )
        let line = CTLineCreateWithAttributedString(attrString)
        textContext.textPosition = CGPoint(x: 40, y: 36)
        CTLineDraw(line, textContext)

        let textBackdrop = try #require(textContext.makeImage())
        let textPixels = PixelBuffer(textBackdrop)
        // 验证原图确实存在高对比黑字笔画（最小亮度 ≈ 0，1px 相邻阶跃 > 180）
        var rawMinLuma = 255
        var rawMaxStep = 0
        for y in 20 ..< 80 {
            for x in 40 ..< 320 {
                let c = textPixels.rgb(x: x, y: y).r
                rawMinLuma = min(rawMinLuma, c)
                let nextC = textPixels.rgb(x: x + 1, y: y).r
                rawMaxStep = max(rawMaxStep, abs(c - nextC))
            }
        }
        #expect(rawMinLuma < 20, "原图文本应含深黑笔画")
        #expect(rawMaxStep > 180, "原图文本笔画边缘应有高对比度阶跃")

        let targetRect = rect(20, 10, 320, 80)

        // 1. 最低档高斯模糊（2x 屏最低档 intensity = 24）
        let lowestBlur = Annotation(kind: .mosaic(rect: targetRect, mode: .blur, intensity: 24))
        let blurredImage = try #require(AnnotationRenderer.render(
            backdrop: textBackdrop,
            selection: rect(0, 0, Double(width), Double(height)),
            annotations: [lowestBlur]
        ))
        let blurredPixels = PixelBuffer(blurredImage)
        var blurMinLuma = 255
        var blurMaxStep = 0
        for y in 20 ..< 80 {
            for x in 40 ..< 320 {
                let c = blurredPixels.rgb(x: x, y: y).r
                blurMinLuma = min(blurMinLuma, c)
                let nextC = blurredPixels.rgb(x: x + 1, y: y).r
                blurMaxStep = max(blurMaxStep, abs(c - nextC))
            }
        }
        // 高斯模糊后笔画已完全冲淡化为浅灰雾，且相邻 1px 阶跃从 255 跌破 12
        #expect(blurMinLuma > 165, "最低档高斯模糊后文字暗部应充分冲淡不可辨认，实际 min=\(blurMinLuma)")
        #expect(blurMaxStep <= 12, "最低档高斯模糊后不得残留尖锐笔画边缘，实际 maxStep=\(blurMaxStep)")

        // 2. 即便外部传入历史小参数 intensity = 6，最低安全下限也应保证强效模糊
        let legacySmallBlur = Annotation(kind: .mosaic(rect: targetRect, mode: .blur, intensity: 6))
        let legacyBlurredImage = try #require(AnnotationRenderer.render(
            backdrop: textBackdrop,
            selection: rect(0, 0, Double(width), Double(height)),
            annotations: [legacySmallBlur]
        ))
        let legacyPixels = PixelBuffer(legacyBlurredImage)
        var legacyMinLuma = 255
        var legacyMaxStep = 0
        for y in 20 ..< 80 {
            for x in 40 ..< 320 {
                let c = legacyPixels.rgb(x: x, y: y).r
                legacyMinLuma = min(legacyMinLuma, c)
                let nextC = legacyPixels.rgb(x: x + 1, y: y).r
                legacyMaxStep = max(legacyMaxStep, abs(c - nextC))
            }
        }
        #expect(legacyMinLuma > 120, "旧参数保底后也应有效打散字形暗部，实际 min=\(legacyMinLuma)")
        #expect(legacyMaxStep <= 20, "旧参数保底后不应保留清晰笔画边，实际 maxStep=\(legacyMaxStep)")

        // 3. 最低档像素化马赛克（2x 屏最低档 intensity = 24）：任意完整 24×24 块内部像素完全同色
        let lowestPixelate = Annotation(kind: .mosaic(rect: targetRect, mode: .pixelate, intensity: 24))
        let pixelatedImage = try #require(AnnotationRenderer.render(
            backdrop: textBackdrop,
            selection: rect(0, 0, Double(width), Double(height)),
            annotations: [lowestPixelate]
        ))
        let pixelatedPixels = PixelBuffer(pixelatedImage)
        // 检查网格对齐块 [48..<72, 24..<48] 内所有像素严格相同，吞没整块文字细节
        let anchorColor = pixelatedPixels.rgb(x: 48, y: 24)
        for y in 24 ..< 48 {
            for x in 48 ..< 72 {
                #expect(pixelatedPixels.rgb(x: x, y: y) == anchorColor, "24×24 马赛克块内应完全均色无笔画残留")
            }
        }
    }
}
