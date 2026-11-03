//
//  MosaicBrushCursor.swift
//  AnShotUI
//
//  马赛克涂抹的笔刷光标：一个与笔刷同直径的圆。
//
//  ── 为什么不能用十字光标 ──────────────────────────────────
//
//  涂抹是「按住拖出一条笔刷轨迹」，而十字光标完全无法表达**笔刷有多大**：
//  用户落笔前不知道这一下会盖住多少内容，只能先涂一笔看看，
//  涂多了还得撤销。画成与笔刷同直径的圆之后，落笔前就能判断覆盖范围。
//
//  同样不能用系统光标（`NSCursor.circle` 之类）：它们的尺寸固定，
//  与笔刷大小无关，表达不了「粗细可调」这件事。
//

import AnShotCore
import AppKit

/// 笔刷直径 → 光标。
@MainActor
enum MosaicBrushCursor {

    /// 光标图像的直径上限（逻辑点）。
    ///
    /// 光标图像是逐像素光栅化的，笔刷开到很大时（直径 120pt）图像也才 126pt，
    /// 本身不慢；但**命中判定与光标本身无关**，画得比屏幕还大没有意义。
    /// 超过就夹取，避免构造出巨幅 NSImage。
    private static let maxDiameter: CGFloat = 160

    /// 缓存上一次的结果：`cursor` 在每次 `mouseMoved` 都会被调用，
    /// 而笔刷大小在一次拖动里通常不变，每次重建 NSImage 纯属浪费。
    private static var cached: (radius: CGFloat, cursor: NSCursor)?

    /// 指定笔刷半径（**视图逻辑点**）对应的光标。
    static func cursor(radius: CGFloat) -> NSCursor {
        let clamped = max(1, min(radius, maxDiameter / 2))
        if let cached, cached.radius == clamped {
            return cached.cursor
        }
        let cursor = make(radius: clamped)
        cached = (clamped, cursor)
        return cursor
    }

    private static func make(radius: CGFloat) -> NSCursor {
        // 四周各留 3pt 给描边，圆本身才不会被裁掉半个线宽。
        let padding: CGFloat = 3
        let size = radius * 2 + padding * 2

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let rect = CGRect(
                x: padding,
                y: padding,
                width: radius * 2,
                height: radius * 2
            )

            // 白色圆环 + 黑色外圈，保证在明暗两种底上都可见
            //（与 `SelectionCursor` 的对角线光标同一套做法）。
            // 两层同心同半径、只差线宽：黑色更粗，视觉上就是圆环的黑边。
            for (color, width) in [(NSColor.black.withAlphaComponent(0.55), CGFloat(3)),
                                   (NSColor.white, CGFloat(1.5))] {
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(width)
                context.strokeEllipse(in: rect)
            }
            return true
        }

        // 热点在圆心：用户按下时落在哪，笔刷的圆心就在哪。
        return NSCursor(
            image: image,
            hotSpot: NSPoint(x: size / 2, y: size / 2)
        )
    }
}
