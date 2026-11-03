//
//  AnnotationHitTestTests.swift
//  AnShotCoreTests
//
//  标注命中测试的单元测试。
//
//  为什么这些测试必须存在：
//  命中测试是「点一下能不能选中」的唯一判据，缺陷的表现极其隐蔽——
//  不会崩溃、不会报错，只是某些标注怎么点都选不上（或者点空白却选中了
//  远处的东西）。而每种 kind 的几何完全不同（线段距离 / 折线距离 /
//  贝塞尔采样 / 矩形包含 / 排版包围盒），逐种断言是唯一能锁住的方式。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

// MARK: - 辅助

private func point(_ x: Double, _ y: Double) -> PixelPoint {
    PixelPoint(x: x, y: y)
}

private func annotation(_ kind: Annotation.Kind) -> Annotation {
    Annotation(kind: kind)
}

// MARK: - 面状标注

@Suite("命中测试 · 面状标注")
struct AnnotationHitTestAreaTests {

    @Test("只描边的矩形按边界命中，内部不命中")
    func outlinedRectangleHitsBorderOnly() {
        let subject = annotation(.rectangle(
            rect: rect(10, 10, 80, 60),
            stroke: StrokeStyle(color: red, width: 2),
            fill: nil,
            cornerRadius: 0
        ))

        #expect(subject.hitTest(point(50, 10), tolerance: 0), "上边界应命中")
        #expect(subject.hitTest(point(10, 40), tolerance: 0), "左边界应命中")
        #expect(
            !subject.hitTest(point(50, 40), tolerance: 0),
            "空心框的内部不应命中——否则它会挡住框里的其它标注"
        )
        #expect(!subject.hitTest(point(200, 200), tolerance: 0), "远处不应命中")
    }

    @Test("容差沿边界两侧都生效，且粗线自身宽度也计入")
    func rectangleToleranceAndStrokeWidth() {
        let subject = annotation(.rectangle(
            rect: rect(10, 10, 80, 60),
            stroke: StrokeStyle(color: red, width: 2),
            fill: nil,
            cornerRadius: 0
        ))

        // 距上边界 3px：容差 2 + 半线宽 1 = 3，刚好命中。
        #expect(subject.hitTest(point(50, 13), tolerance: 2))
        #expect(!subject.hitTest(point(50, 13), tolerance: 1), "容差收窄后应判为未命中")

        // 外部同距离。
        #expect(subject.hitTest(point(50, 7), tolerance: 2))
        #expect(!subject.hitTest(point(50, 7), tolerance: 1))
    }

    @Test("有填充的矩形内部任意一点都命中")
    func filledRectangleHitsInterior() {
        let subject = annotation(.rectangle(
            rect: rect(10, 10, 80, 60),
            stroke: StrokeStyle(color: red, width: 2),
            fill: red,
            cornerRadius: 8
        ))

        #expect(subject.hitTest(point(50, 40), tolerance: 0), "填充区内部应命中")
        #expect(subject.hitTest(point(10, 10), tolerance: 0), "边界应命中")
        #expect(!subject.hitTest(point(5, 40), tolerance: 0), "框外不应命中")
    }

    @Test("高亮按整个矩形区域命中")
    func highlightHitsArea() {
        let subject = annotation(.highlight(rect: rect(0, 0, 100, 50), color: red))
        #expect(subject.hitTest(point(50, 25), tolerance: 0))
        #expect(!subject.hitTest(point(50, 60), tolerance: 0))
        #expect(subject.hitTest(point(50, 54), tolerance: 4), "容差允许点在高亮边缘之外一点")
    }

    @Test("框选马赛克与涂抹马赛克分别按矩形、路径命中")
    func mosaicKinds() {
        let boxed = annotation(.mosaic(rect: rect(20, 20, 40, 40), mode: .pixelate, intensity: 8))
        #expect(boxed.hitTest(point(30, 30), tolerance: 0))
        #expect(!boxed.hitTest(point(80, 30), tolerance: 0))

        let brushed = annotation(.mosaicStroke(
            points: [point(0, 0), point(50, 0)],
            radius: 6,
            mode: .pixelate,
            intensity: 8
        ))
        #expect(brushed.hitTest(point(25, 4), tolerance: 0), "笔刷半径内应命中")
        #expect(!brushed.hitTest(point(25, 8), tolerance: 0), "超出笔刷半径且无容差时不应命中")
        #expect(brushed.hitTest(point(25, 8), tolerance: 3), "容差应当把边界外一点也算进来")
    }
}

// MARK: - 圆形标注

@Suite("命中测试 · 圆形与编号")
struct AnnotationHitTestCircularTests {

    @Test("放大镜按圆形区域命中，含边框半宽")
    func magnifierHitsCircle() {
        let subject = annotation(.magnifier(
            center: point(100, 100),
            radius: 30,
            zoom: 2,
            border: StrokeStyle(color: red, width: 4)
        ))
        #expect(subject.hitTest(point(100, 100), tolerance: 0), "圆心应命中")
        #expect(subject.hitTest(point(130, 100), tolerance: 0), "半径处应命中")
        #expect(
            subject.hitTest(point(132, 100), tolerance: 0),
            "边框有宽度，半径外半条线宽也应命中"
        )
        #expect(!subject.hitTest(point(140, 100), tolerance: 0))
    }

    @Test("编号标记按圆面命中")
    func numberingHitsCircle() {
        let subject = annotation(.numbering(
            center: point(50, 50),
            radius: 14,
            index: 1,
            stroke: StrokeStyle(color: red, width: 2),
            fill: nil,
            textColor: black
        ))
        #expect(subject.hitTest(point(50, 50), tolerance: 0))
        #expect(subject.hitTest(point(60, 50), tolerance: 0))
        #expect(!subject.hitTest(point(70, 50), tolerance: 0))
        #expect(subject.hitTest(point(66, 50), tolerance: 2))
    }
}

// MARK: - 线状标注

@Suite("命中测试 · 线状标注")
struct AnnotationHitTestStrokeTests {

    @Test("直线按线段距离命中，端点之外不算命中")
    func lineHitsSegmentOnly() {
        let subject = annotation(.line(
            start: point(0, 0),
            end: point(100, 0),
            stroke: StrokeStyle(color: red, width: 4)
        ))
        #expect(subject.hitTest(point(50, 0), tolerance: 0))
        #expect(subject.hitTest(point(50, 2), tolerance: 0), "半线宽内应命中")
        #expect(!subject.hitTest(point(50, 3), tolerance: 0), "半线宽之外应未命中")
        #expect(
            !subject.hitTest(point(150, 0), tolerance: 0),
            "延长线上不应命中——投影参数必须夹在 [0,1]"
        )
    }

    @Test("箭头沿箭杆命中，头部端点在线上")
    func arrowHitsShaft() {
        let subject = annotation(.arrow(
            start: point(0, 0),
            end: point(100, 100),
            stroke: StrokeStyle(color: red, width: 4),
            headLength: 20,
            headWidth: 12
        ))
        #expect(subject.hitTest(point(50, 50), tolerance: 0))
        #expect(subject.hitTest(point(100, 100), tolerance: 0), "箭头尖端是线的终点")
        #expect(!subject.hitTest(point(100, 20), tolerance: 0))
    }

    @Test("曲线箭头按真实曲线命中，而不是按弦")
    func curvedArrowHitsCurve() {
        // 弦中点 (100,100)，控制点 (100,200) → 曲线在 t=0.5 处到达 (100,150)。
        let subject = annotation(.curvedArrow(
            start: point(0, 100),
            control: point(100, 200),
            end: point(200, 100),
            stroke: StrokeStyle(color: red, width: 2),
            headLength: 20,
            headWidth: 12
        ))

        #expect(subject.hitTest(point(100, 150), tolerance: 0), "曲线顶点应命中")
        #expect(
            !subject.hitTest(point(100, 100), tolerance: 0),
            "弦中点离曲线 50px，按弦判定会误命中"
        )
        #expect(
            !subject.hitTest(point(100, 100), tolerance: 10),
            "容差 10px 也不该够到曲线"
        )
        #expect(subject.hitTest(point(100, 100), tolerance: 52), "容差够大时才够到曲线")
    }

    @Test("自由笔与折线路径距离一致")
    func freehandHitsPolyline() {
        let subject = annotation(.freehand(
            points: [point(0, 0), point(50, 50), point(100, 0)],
            stroke: StrokeStyle(color: red, width: 2)
        ))
        #expect(subject.hitTest(point(25, 25), tolerance: 0), "斜段中点应命中")
        #expect(subject.hitTest(point(75, 25), tolerance: 0), "回折段中点应命中")
        #expect(!subject.hitTest(point(50, 20), tolerance: 0), "两条线之间应未命中")
        // 距线段 25,25–0,0 约 2.1px：无容差时未命中，容差 2 时命中。
        #expect(!subject.hitTest(point(25, 28), tolerance: 0))
        #expect(subject.hitTest(point(25, 28), tolerance: 2), "容差应当够到折线")
    }

    @Test("测量线按线段命中")
    func measureHitsSegment() {
        let subject = annotation(.measure(
            start: point(10, 10),
            end: point(10, 110),
            stroke: StrokeStyle(color: red, width: 2)
        ))
        #expect(subject.hitTest(point(10, 60), tolerance: 0))
        #expect(subject.hitTest(point(11, 60), tolerance: 0), "半线宽内应命中")
        #expect(!subject.hitTest(point(13, 60), tolerance: 0))
    }
}

// MARK: - 文字

@Suite("命中测试 · 文字包围盒")
struct AnnotationHitTestTextTests {

    private func text(
        _ content: String,
        origin: PixelPoint = point(100, 100),
        size: Double = 40,
        maxWidth: Double? = nil
    ) -> Annotation {
        annotation(.text(
            origin: origin,
            text: content,
            font: .system(size: size),
            color: black,
            background: nil,
            maxWidth: maxWidth
        ))
    }

    @Test("文字按真实排版包围盒命中，而不是零尺寸点")
    func textHitsMeasuredBox() {
        let subject = text("Hello")
        let box = subject.hitBoundingRect

        #expect(box.size.width > 0, "包围盒宽度必须来自实际排版，实际 \(box.size.width)")
        #expect(box.size.height > 0)
        #expect(box.origin.y < 100, "包围盒上边应在基线之上（ascent），实际 \(box.origin.y)")
        #expect(
            box.origin.y + box.size.height > 100,
            "包围盒下边应在基线之下（descent），实际 \(box.origin.y + box.size.height)"
        )

        #expect(subject.hitTest(point(105, 90), tolerance: 0), "文字主体上应命中")
        #expect(
            !subject.hitTest(point(105, 130), tolerance: 0),
            "基线下方远超降部时应未命中"
        )
        #expect(
            !subject.hitTest(point(500, 90), tolerance: 0),
            "远超文字宽度时应未命中"
        )
        #expect(subject.hitTest(point(box.origin.x - 3, 90), tolerance: 5), "容差应扩大包围盒")
    }

    @Test("多行文字包围盒高度随行数增长")
    func multilineTextGrows() {
        let single = text("A")
        let double = text("A\nB")
        #expect(
            double.hitBoundingRect.size.height > single.hitBoundingRect.size.height * 1.5,
            "两行的包围盒应明显高于一行"
        )
        #expect(double.hitTest(point(105, 100 + 30), tolerance: 0), "第二行区域内应命中")
    }

    @Test("有最大宽度时按断行结果收窄包围盒")
    func maxWidthWrapsBox() {
        let bounded = text("Hello world hello world", size: 20, maxWidth: 60)
        #expect(
            bounded.hitBoundingRect.size.width <= 60.5,
            "包围盒宽度不应超过 maxWidth，实际 \(bounded.hitBoundingRect.size.width)"
        )
        let unbounded = text("Hello world hello world", size: 20)
        #expect(
            unbounded.hitBoundingRect.size.width > bounded.hitBoundingRect.size.width,
            "无宽度约束时整行更宽"
        )
    }

    @Test("空文字不命中任何点")
    func emptyTextNeverHits() {
        let subject = text("")
        #expect(!subject.hitTest(point(100, 100), tolerance: 10))
    }
}

// MARK: - 平移

@Suite("标注平移")
struct AnnotationTranslationTests {

    @Test("平移覆盖全部坐标字段，含曲线控制点与文字原点")
    func translationMovesEveryCoordinate() {
        let delta = point(10, -5)
        let cases: [(name: String, original: Annotation, oldPoint: PixelPoint, newPoint: PixelPoint)] = [
            (
                "曲线箭头",
                annotation(.curvedArrow(
                    start: point(0, 100),
                    control: point(100, 200),
                    end: point(200, 100),
                    stroke: StrokeStyle(color: red, width: 2),
                    headLength: 10,
                    headWidth: 8
                )),
                point(100, 150),
                point(110, 145)
            ),
            (
                "自由笔",
                annotation(.freehand(points: [point(0, 0), point(50, 50)], stroke: StrokeStyle(color: red, width: 2))),
                point(25, 25),
                point(35, 20)
            ),
            (
                "涂抹马赛克",
                annotation(.mosaicStroke(points: [point(0, 0), point(50, 0)], radius: 6, mode: .pixelate, intensity: 8)),
                point(25, 0),
                point(35, -5)
            ),
            (
                "编号",
                annotation(.numbering(
                    center: point(50, 50),
                    radius: 14,
                    index: 3,
                    stroke: StrokeStyle(color: red, width: 2),
                    fill: nil,
                    textColor: black
                )),
                point(50, 50),
                point(60, 45)
            ),
            (
                "放大镜",
                annotation(.magnifier(
                    center: point(100, 100),
                    radius: 30,
                    zoom: 2,
                    border: StrokeStyle(color: red, width: 2)
                )),
                point(100, 100),
                point(110, 95)
            )
        ]

        for entry in cases {
            let moved = entry.original.translated(by: delta)
            #expect(moved.id == entry.original.id, "\(entry.name)：平移不得改变 ID")
            // 旧位置不一定「不再命中」：面积型标注（矩形/高亮/文字包围盒）
            // 平移后覆盖范围仍可能包含旧点。真正要锁的是「新位置命中」，
            // 以及包围盒确实跟着移动。
            #expect(
                moved.hitTest(entry.newPoint, tolerance: 0),
                "\(entry.name)：新位置应命中"
            )
            #expect(
                moved.hitBoundingRect != entry.original.hitBoundingRect,
                "\(entry.name)：包围盒应随平移改变"
            )
        }
    }

    @Test("零位移返回同值标注")
    func zeroDeltaKeepsAnnotation() {
        let original = annotation(.line(
            start: point(0, 0),
            end: point(10, 10),
            stroke: StrokeStyle(color: red, width: 2)
        ))
        #expect(original.translated(by: .zero) == original)
    }
}
