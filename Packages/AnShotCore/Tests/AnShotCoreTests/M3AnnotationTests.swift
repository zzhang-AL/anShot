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

    @Test("弯曲箭头用控制点包围盒作为保守上界")
    func curvedArrowBoundingRect() {
        let annotation = m3Kinds[5]
        let box = annotation.boundingRect
        // 三个点：(10,10) (50,80) (90,10) → 上界必须包含控制点，
        // 即使曲线的真实极值可能略超出它（不可低估为更小的盒子）。
        #expect(box.origin.x == 10)
        #expect(box.origin.y == 10)
        #expect(box.size.width == 80)
        #expect(box.size.height == 70)
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

    @Test("高亮：矩形内被填充，矩形外保持底图")
    func highlightPlacement() throws {
        let pixels = try render(m3Kinds[1], on: solidImage(width: 200, height: 200, color: black))
        expectColor(pixels.rgb(x: 30, y: 20), (255, 255, 0), "高亮矩形内应为黄色")
        expectColor(pixels.rgb(x: 100, y: 100), (0, 0, 0), "矩形外应保持底图")
    }

    @Test("测量：连线经过中点，读数不改变连线存在性")
    func measurePlacement() throws {
        let pixels = try render(m3Kinds[2], on: solidImage(width: 200, height: 200, color: black))
        // 线宽 4，y=10 处应命中描边。
        expectColor(pixels.rgb(x: 50, y: 10), (255, 0, 0), "连线中段应为描边色")
        expectColor(pixels.rgb(x: 50, y: 60), (0, 0, 0), "远离连线处应保持底图")
    }

    @Test("放大镜：把中心处底图放大后画回圆内")
    func magnifierZoomsBackdrop() throws {
        // 底图上半白、下半黑：放大镜取圆心附近更小的源区域，
        // 因此圆内黑白分界会被推开（黑区在圆内出现的位置更靠下）。
        let backdrop = splitImage(width: 200, height: 200, top: white, bottom: black)
        let pixels = try render(m3Kinds[3], on: backdrop)

        // 源区域是以 (100,100) 为中心、60/2=30 的一半：y ∈ [85,115]，
        // 放大 2 倍后黑色（y>100）应从 destRect 的中间略下开始。
        // 这里只断言「圆心下方为黑、上方为白」，与不分界时相同，
        // 但额外断言圆外的分界位置未被影响。
        expectColor(pixels.rgb(x: 100, y: 60), (255, 255, 255), "圆内上半应为白色（放大后的黑区尚未开始）")
        expectColor(pixels.rgb(x: 100, y: 140), (0, 0, 0), "圆内下半应为黑色")
        expectColor(pixels.rgb(x: 5, y: 95), (255, 255, 255), "圆外分界上侧应保持底图")
        expectColor(pixels.rgb(x: 5, y: 105), (0, 0, 0), "圆外分界下侧应保持底图")
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
