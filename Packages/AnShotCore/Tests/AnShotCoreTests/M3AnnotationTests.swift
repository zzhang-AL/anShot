//
//  M3AnnotationTests.swift
//  AnShotCoreTests
//
//  M3-0 模型扩展的测试：六种新标注的契约、版本兼容与渲染。
//
//  ── 为什么兼容性要单独测 ──────────────────────────────────
//
//  「新版本能读旧文件」是契约里最容易在重构中被顺手破坏的一条：
// 给 `StrokeStyle` 加一个字段，合成解码就会因为旧 JSON 缺键而整体失败，
// 而失败表现是「打开历史工程报错」，不是编译错误。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

// MARK: - 夹具

private let redStroke = StrokeStyle(color: RGBAColor(r: 1, g: 0, b: 0, a: 1), width: 4)

/// M3 新增的六种标注各一条。
private let m3Kinds: [Annotation] = [
    Annotation(kind: .numbering(
        center: PixelPoint(x: 100, y: 100),
        radius: 20,
        index: 3,
        stroke: redStroke,
        fill: RGBAColor(r: 1, g: 1, b: 1, a: 1),
        textColor: RGBAColor(r: 0, g: 0, b: 0, a: 1)
    )),
    Annotation(kind: .highlight(
        rect: rect(10, 10, 40, 20),
        color: RGBAColor(r: 1, g: 1, b: 0, a: 1)
    )),
    Annotation(kind: .measure(
        start: PixelPoint(x: 10, y: 10),
        end: PixelPoint(x: 90, y: 10),
        stroke: redStroke
    )),
    Annotation(kind: .magnifier(
        center: PixelPoint(x: 100, y: 100),
        radius: 30,
        zoom: 2,
        border: redStroke
    )),
    Annotation(kind: .freehand(
        points: [PixelPoint(x: 10, y: 10), PixelPoint(x: 30, y: 40), PixelPoint(x: 60, y: 20)],
        stroke: redStroke
    )),
    Annotation(kind: .curvedArrow(
        start: PixelPoint(x: 10, y: 10),
        control: PixelPoint(x: 50, y: 80),
        end: PixelPoint(x: 90, y: 10),
        stroke: redStroke,
        headLength: 12,
        headWidth: 8
    )),
]

// MARK: - 模型契约

@Suite("M3 标注模型")
struct M3AnnotationModelTests {

    @Test("六种新标注均可往返编解码")
    func roundTrip() throws {
        for annotation in m3Kinds {
            let data = try JSONEncoder().encode(annotation)
            let decoded = try JSONDecoder().decode(Annotation.self, from: data)
            #expect(decoded == annotation)
        }
    }

    @Test("type 字符串符合契约")
    func typeNames() {
        let expected = ["numbering", "highlight", "measure", "magnifier", "freehand", "curvedArrow"]
        #expect(m3Kinds.map(\.kind.typeName) == expected)
    }

    @Test("编号的序号来自模型而不是数组下标")
    func numberingKeepsIndex() throws {
        // 契约要求「自动递增由会话维护计数器」：值必须落到模型，
        // 否则删掉中间一笔后，靠下标推断会得到与画面不同的数字。
        let annotation = Annotation(kind: .numbering(
            center: PixelPoint(x: 1, y: 1),
            radius: 10,
            index: 7,
            stroke: redStroke,
            fill: nil,
            textColor: redStroke.color
        ))
        let data = try JSONEncoder().encode(annotation)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["index"] as? Int == 7)

        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        guard case let .numbering(_, _, index, _, _, _) = decoded.kind else {
            Issue.record("解码后不是编号")
            return
        }
        #expect(index == 7)
    }

    @Test("自由绘制的包围盒按笔宽外扩")
    func freehandBoundingRect() {
        let annotation = Annotation(kind: .freehand(
            points: [PixelPoint(x: 10, y: 20), PixelPoint(x: 30, y: 40)],
            stroke: StrokeStyle(color: redStroke.color, width: 6)
        ))
        let box = annotation.boundingRect
        // 笔迹有半径，不外扩的话边缘笔迹会被判为越界。
        #expect(box.origin.x == 7)
        #expect(box.origin.y == 17)
        #expect(box.size.width == 26)
        #expect(box.size.height == 26)
    }

    @Test("弯曲箭头用二次贝塞尔解析极值求紧致包围盒")
    func curvedArrowBoundingRect() {
        let annotation = m3Kinds[5]
        let box = annotation.boundingRect
        // 三个点：(10,10) (50,80) (90,10) → y 在 t=0.5 处取得解析极值 (0.25*10 + 0.5*80 + 0.25*10) = 45，
        // 紧致包围盒高度为 35（y ∈ [10, 45]），而不是控制点盒的 70。
        #expect(box.origin.x == 10)
        #expect(box.origin.y == 10)
        #expect(box.size.width == 80)
        #expect(abs(box.size.height - 35) < 1e-9)
    }
}

// MARK: - 版本兼容

@Suite("M3 版本兼容")
struct M3SchemaCompatibilityTests {

    @Test("当前契约版本为 3")
    func currentVersion() {
        #expect(CaptureSession.currentSchemaVersion == 3)
    }

    @Test("v2 的 StrokeStyle（无 isSketchy）仍可解码")
    func decodesLegacyStrokeStyle() throws {
        // v2 文件里 StrokeStyle 没有 isSketchy 键。合成解码会因缺键失败，
        // 这里必须由 decodeIfPresent 兜底成 false。
        let legacy = #"{"color":{"r":1,"g":0,"b":0,"a":1},"width":4}"#
        let decoded = try JSONDecoder().decode(StrokeStyle.self, from: Data(legacy.utf8))
        #expect(decoded.width == 4)
        #expect(decoded.isSketchy == false)
        #expect(decoded.isDashed == false)
    }

    @Test("v2 的标注 JSON（矩形，无 isSketchy）仍可整体解码")
    func decodesLegacyRectangle() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","type":"rectangle",
         "rect":{"origin":{"x":1,"y":2},"size":{"width":3,"height":4}},
         "stroke":{"color":{"r":0,"g":0,"b":0,"a":1},"width":2},
         "fill":null,"cornerRadius":0}
        """
        let decoded = try JSONDecoder().decode(Annotation.self, from: Data(legacy.utf8))
        guard case .rectangle = decoded.kind else {
            Issue.record("应解码为矩形")
            return
        }
    }

    @Test("v1/v2 会话文件中的 schemaVersion 被容忍而非拒绝")
    func toleratesOlderSessionVersion() throws {
        let legacy = """
        {"schemaVersion":2,"id":"00000000-0000-0000-0000-000000000002",
         "createdAt":"2026-01-01T00:00:00Z",
         "backdrop":{"pixelWidth":10,"pixelHeight":10,"scaleFactor":2},
         "selection":{"origin":{"x":0,"y":0},"size":{"width":10,"height":10}},
         "annotations":[]}
        """
        let session = try JSONDecoder().decode(CaptureSession.self, from: Data(legacy.utf8))
        #expect(session.schemaVersion == 2)
        #expect(session.annotations.isEmpty)
    }

    @Test("isSketchy 为 true 时往返保持")
    func sketchyRoundTrip() throws {
        let style = StrokeStyle(color: redStroke.color, width: 2, dash: nil, isSketchy: true)
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(StrokeStyle.self, from: data)
        #expect(decoded.isSketchy)
    }
}

// MARK: - 渲染

@Suite("M3 新增标注渲染")
struct M3AnnotationRendererTests {

    private func render(_ annotation: Annotation, on backdrop: CGImage) throws -> PixelBuffer {
        let image = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: rect(0, 0, 200, 200),
            annotations: [annotation]
        ))
        return PixelBuffer(image)
    }

    @Test("编号：圆心为填充色，圆外保持底图")
    func numberingPlacement() throws {
        let pixels = try render(m3Kinds[0], on: solidImage(width: 200, height: 200, color: black))
        // 圆心 (100,100)、半径 20 → 圆内 y ∈ [80,120]，取 (100,90) 才在圆内。
        expectColor(pixels.rgb(x: 100, y: 90), (255, 255, 255), "圆内上部应为白色填充")
        expectColor(pixels.rgb(x: 5, y: 5), (0, 0, 0), "圆外应保持底图")
    }

    @Test("高亮：正片叠底在白底上显色且保持黑字锐黑不被洗灰")
    func highlightPlacement() throws {
        let whitePixels = try render(m3Kinds[1], on: solidImage(width: 200, height: 200, color: white))
        expectColor(whitePixels.rgb(x: 30, y: 20), (255, 255, 0), "白底高亮矩形内应为鲜艳黄色")
        expectColor(whitePixels.rgb(x: 100, y: 100), (255, 255, 255), "矩形外应保持白底")

        let blackPixels = try render(m3Kinds[1], on: solidImage(width: 200, height: 200, color: black))
        expectColor(blackPixels.rgb(x: 30, y: 20), (0, 0, 0), "正片叠底在纯黑文字像素上应保持锐黑不泛灰")
    }

    @Test("测量：连线经过中点，读数不改变连线存在性")
    func measurePlacement() throws {
        let pixels = try render(m3Kinds[2], on: solidImage(width: 200, height: 200, color: black))
        // 线宽 4，y=10 处应命中描边。
        expectColor(pixels.rgb(x: 50, y: 10), (255, 0, 0), "连线中段应为描边色")
        expectColor(pixels.rgb(x: 50, y: 60), (0, 0, 0), "远离连线处应保持底图")
    }

    @Test("放大镜：把中心处底图放大后正立画回圆内，且在非零选区下不偏离")
    func magnifierZoomsBackdrop() throws {
        // 构造非对称彩色条纹底图（上白，y ∈ [90,100) 红，y ∈ [100,110) 绿，下黑）：
        // 放大镜中心 (100,100)、半径 30、倍率 2：
        // - 圆心上方 10px 处（y=90..99 红）放大 2 倍后应正立映射到圆心上方 20px（y=80..99）；
        // - 圆心下方 10px 处（y=100..109 绿）放大 2 倍后应正立映射到圆心下方 20px（y=100..119）；
        // 若 CTM 导致上下倒置，y=85 会变绿、y=115 会变红，直接检出。
        let backdrop = regionedImage(
            width: 300,
            height: 300,
            background: black,
            regions: [
                (0, 0, 300, 90, white),
                (0, 90, 300, 10, red),
                (0, 100, 300, 10, green),
            ]
        )
        let pixels = try render(m3Kinds[3], on: backdrop)

        // 圆内采样（圆内 y ∈ [70, 130]）：
        expectColor(pixels.rgb(x: 100, y: 85), (255, 0, 0), "圆内上半（y=85）应映射自红带，证明正立放大")
        expectColor(pixels.rgb(x: 100, y: 115), (0, 255, 0), "圆内下半（y=115）应映射自绿带，证明正立放大")
        // 放大推开更远：原图 y=85 为白，放大 2 倍映射到 y=70；取 y=74 仍在圆内且映射自原 y=87（白）
        expectColor(pixels.rgb(x: 100, y: 74), (255, 255, 255), "圆内顶部应映射自白色区域")

        // 圆外底图保持原样：
        expectColor(pixels.rgb(x: 5, y: 95), (255, 0, 0), "圆外红带保持不变")
        expectColor(pixels.rgb(x: 5, y: 105), (0, 255, 0), "圆外绿带保持不变")

        // 非零 selection.origin = (80, 60) 下再次验证：
        let offsetSelection = rect(80, 60, 160, 160)
        let offsetMagnifier = Annotation(kind: .magnifier(
            center: PixelPoint(x: 160, y: 100),
            radius: 30,
            zoom: 2,
            border: redStroke
        ))
        let offsetImage = try #require(AnnotationRenderer.render(
            backdrop: backdrop,
            selection: offsetSelection,
            annotations: [offsetMagnifier]
        ))
        let offsetPixels = PixelBuffer(offsetImage)
        // 画布坐标 (80, 40) 对应模型中心 (160, 100)：
        expectColor(offsetPixels.rgb(x: 80, y: 25), (255, 0, 0), "非零选区圆内上半应为红色（正立）")
        expectColor(offsetPixels.rgb(x: 80, y: 55), (0, 255, 0), "非零选区圆内下半应为绿色（正立）")
    }

    @Test("自由绘制：笔迹经过采样点附近")
    func freehandStroke() throws {
        let pixels = try render(m3Kinds[4], on: solidImage(width: 200, height: 200, color: black))
        // 三点折线的第一个采样点在 (10,10)，笔宽 4。
        expectColor(pixels.rgb(x: 10, y: 10), (255, 0, 0), "起点附近应为笔迹色")
        expectColor(pixels.rgb(x: 150, y: 150), (0, 0, 0), "远离笔迹处应保持底图")
    }

    @Test("弯曲箭头：杆沿曲线、头部在终点")
    func curvedArrowShape() throws {
        let pixels = try render(m3Kinds[5], on: solidImage(width: 200, height: 200, color: black))

        func isRed(_ x: Int, _ y: Int) -> Bool {
            let c = pixels.rgb(x: x, y: y)
            return c.r > 200 && c.g < 60 && c.b < 60
        }

        // 曲线与弦的判别：直线 start→end 的 y 恒为 10（两端 y 都是 10），
        // 只有真的走二次贝塞尔才会下探到 40 以上。这条断言比逐点比对更本质，
        // 也不受「杆画到头部底边还是终点」这类实现细节影响。
        var maxRedY = -1
        for y in 0..<200 {
            for x in 0..<200 where isRed(x, y) {
                maxRedY = max(maxRedY, y)
            }
        }
        #expect(isRed(10, 10), "起点应有杆")
        #expect(maxRedY >= 40, "杆必须走曲线（弦的 y 不会超过 10），实际最低 y=\(maxRedY)")

        // 头部用区域判定而不是精确点：三角形只有 12×8 且描边宽 4，
        // 内部实心区离边界不到 3px，逐点断言会被抗锯齿摇摆。
        var headPixels = 0
        for y in 8..<26 {
            for x in 78..<94 where isRed(x, y) {
                headPixels += 1
            }
        }
        #expect(headPixels > 20, "终点附近应画出箭头头部，实际 \(headPixels) 个像素")
    }

    @Test("六种新标注都不产生越界绘制")
    func staysInsideCanvas() throws {
        for annotation in m3Kinds {
            let pixels = try render(annotation, on: solidImage(width: 200, height: 200, color: black))
            // 四角远离所有几何，必须仍是底图；出现颜色即说明绘制溢出了画布。
            for (x, y) in [(1, 1), (198, 1), (1, 198), (198, 198)] {
                expectColor(pixels.rgb(x: x, y: y), (0, 0, 0), "\(annotation.kind.typeName) 在 (\(x),\(y)) 越界")
            }
        }
    }
}
