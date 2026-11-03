//
//  DraftOutlineTests.swift
//  AnShotUITests
//
//  草稿辅助轮廓的纯函数断言。
//
//  ── 本文件的来历 ──────────────────────────────────────────────
//
//  它取代 `-diagnoseSelection` 里的 `verifyDraftOutline`。那段诊断自己就写着
//  「把『哪种草稿该有轮廓、换算落在哪』抽成纯函数后，这部分就不依赖窗口、
//  鼠标与屏幕录制权限」——断言的对象是 `OverlayView.draftOutlineRect`，
//  一个只读标注模型与缩放比的静态函数，却因为当时没有测试 target
//  而只能写进 App 内、靠人工跑诊断读日志。
//
//  ── 断言的三件事 ──────────────────────────────────────────────
//
//  1. 只有**马赛克框选**草稿画辅助轮廓：涂抹由笔刷光标表达落点与粗细，
//     矩形等自带描边，再加轮廓只是噪声；
//  2. 模型坐标（底图像素）必须按 scaleFactor 换算到视图坐标（逻辑点）；
//  3. `scaleFactor <= 0` 时不得除出无穷大矩形，只能返回 nil。
//

import AnShotCore
import CoreGraphics
import Testing

@testable import AnShotUI

@Suite("覆盖层 · 草稿辅助轮廓")
@MainActor
struct DraftOutlineTests {

    /// 底图 2x 缩放下的模型矩形：(200,100) 起、400×200。
    private static let pixelRect = PixelRect(
        origin: PixelPoint(x: 200, y: 100),
        size: PixelSize(width: 400, height: 200)
    )

    private static let mosaic = Annotation(
        kind: .mosaic(rect: pixelRect, mode: .pixelate, intensity: 12)
    )

    private static let mosaicStroke = Annotation(
        kind: .mosaicStroke(
            points: [PixelPoint(x: 0, y: 0), PixelPoint(x: 10, y: 10)],
            radius: 16,
            mode: .pixelate,
            intensity: 12
        )
    )

    private static let rectangle = Annotation(
        kind: .rectangle(
            rect: pixelRect,
            stroke: StrokeStyle(color: RGBAColor(r: 1, g: 0, b: 0, a: 1), width: 4),
            fill: nil,
            cornerRadius: 0
        )
    )

    @Test("马赛克框选草稿有辅助轮廓，且像素按缩放比换算为逻辑点")
    func mosaicDraftHasOutline() {
        let outline = OverlayView.draftOutlineRect(for: Self.mosaic, scaleFactor: 2)
        #expect(outline == CGRect(x: 100, y: 50, width: 200, height: 100))
    }

    @Test("缩放比为 1 时轮廓就是模型矩形本身")
    func unitScaleKeepsPixelRect() {
        let outline = OverlayView.draftOutlineRect(for: Self.mosaic, scaleFactor: 1)
        #expect(outline == CGRect(x: 200, y: 100, width: 400, height: 200))
    }

    @Test("分数缩放（1.5）同样按比例换算")
    func fractionalScaleIsConverted() throws {
        let outline = try #require(
            OverlayView.draftOutlineRect(for: Self.mosaic, scaleFactor: 1.5)
        )
        // 400 / 1.5 与 200 / 1.5 都不是整数：换算必须是浮点除法，
        // 不能先取整（先取整会让轮廓与真实落点差出半个像素以上）。
        //
        // ── 期望值必须显式标注 CGFloat ──────────────────────────
        //
        // 写成 `outline.origin.x == 200.0 / 1.5`（或先 let 一个**无类型注解**的
        // 常量）会**假失败**，而产品代码是对的：
        //
        // * `CGRect.origin.x` 是 `CGFloat`；
        // * 右侧没有 CGFloat 上下文时，`200.0 / 1.5` 被推断为 `Double`；
        // * 在当前 SDK 下这个 `CGFloat == Double` 桥接比较对 `133.333…`
        //   这类非二进制精确值返回 **false**，而两侧的 `bitPattern` 实测
        //   完全相同（`4638895266176084651`）、直接 `==` 求值也是 `true`。
        //
        // 所以差异不在精度，而在「拿哪个类型的 `==` 去比」。显式 `: CGFloat`
        // 让两侧走同一个 `==(CGFloat, CGFloat)`，断言才真正在测换算。
        //
        // 同时用 `#require` 解包：`outline` 为 nil 时给出“期望有值”的清晰失败，
        // 而不是四个字段各自报一次 false。
        let expectedX: CGFloat = 200.0 / 1.5
        let expectedY: CGFloat = 100.0 / 1.5
        let expectedWidth: CGFloat = 400.0 / 1.5
        let expectedHeight: CGFloat = 200.0 / 1.5
        #expect(outline.origin.x == expectedX)
        #expect(outline.origin.y == expectedY)
        #expect(outline.width == expectedWidth)
        #expect(outline.height == expectedHeight)
    }

    @Test("涂抹草稿不画轮廓：笔刷光标已表达落点与粗细")
    func mosaicStrokeHasNoOutline() {
        #expect(OverlayView.draftOutlineRect(for: Self.mosaicStroke, scaleFactor: 2) == nil)
    }

    @Test("矩形草稿不画轮廓：它自带描边，轮廓只会多一层噪点")
    func rectangleHasNoOutline() {
        #expect(OverlayView.draftOutlineRect(for: Self.rectangle, scaleFactor: 2) == nil)
    }

    @Test("缩放比为 0 或负数时不产出轮廓，不除出无穷大矩形")
    func nonPositiveScaleProducesNoOutline() {
        #expect(OverlayView.draftOutlineRect(for: Self.mosaic, scaleFactor: 0) == nil)
        #expect(OverlayView.draftOutlineRect(for: Self.mosaic, scaleFactor: -1) == nil)
        #expect(OverlayView.draftOutlineRect(for: Self.mosaicStroke, scaleFactor: 0) == nil)
    }
}
