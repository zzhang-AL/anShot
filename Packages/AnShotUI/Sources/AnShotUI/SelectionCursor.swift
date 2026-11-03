//
//  SelectionCursor.swift
//  AnShotUI
//
//  选区手柄对应的光标。
//
//  ── 为什么要自绘 ──────────────────────────────────────────
//
//  AppKit 提供了上下、左右两个方向的缩放光标，但**没有对角**的。
//  角手柄若只能退化成 `crosshair`，用户就无法区分「可拖动这个角」与
//  「空白处可以新建选区」——两者的光标会完全一样。
//

import AnShotCore
import AppKit

/// 手柄 → 光标的映射。
@MainActor
enum SelectionCursor {

    /// 某个手柄对应的光标。
    static func cursor(for handle: SelectionHandle) -> NSCursor {
        switch handle {
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .topLeft, .bottomRight:
            return diagonalCursorDescending
        case .topRight, .bottomLeft:
            return diagonalCursorAscending
        }
    }

    /// ↘↖ 方向的对角光标。
    private static let diagonalCursorDescending = makeDiagonalCursor(descending: true)

    /// ↗↙ 方向的对角光标。
    private static let diagonalCursorAscending = makeDiagonalCursor(descending: false)

    /// 画一个双向对角箭头光标。
    private static func makeDiagonalCursor(descending: Bool) -> NSCursor {
        let size: CGFloat = 22
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setLineCap(.round)
            context.setLineJoin(.round)

            let inset: CGFloat = 4.5
            let from = CGPoint(x: inset, y: descending ? size - inset : inset)
            let to = CGPoint(x: size - inset, y: descending ? inset : size - inset)

            // 白色主线 + 黑色外圈，保证在明暗两种底上都可见
            for (color, width) in [(NSColor.black.withAlphaComponent(0.55), CGFloat(3.5)),
                                   (NSColor.white, CGFloat(2.0))] {
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(width)
                context.move(to: from)
                context.addLine(to: to)
                context.strokePath()
            }

            // 两端箭头
            let head: CGFloat = 4.5
            for (tip, toward) in [(from, to), (to, from)] {
                let angle = atan2(toward.y - tip.y, toward.x - tip.x)
                context.move(to: tip)
                context.addLine(to: CGPoint(
                    x: tip.x + cos(angle + .pi / 4) * head,
                    y: tip.y + sin(angle + .pi / 4) * head
                ))
                context.move(to: tip)
                context.addLine(to: CGPoint(
                    x: tip.x + cos(angle - .pi / 4) * head,
                    y: tip.y + sin(angle - .pi / 4) * head
                ))
            }
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2.0)
            context.strokePath()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }
}
