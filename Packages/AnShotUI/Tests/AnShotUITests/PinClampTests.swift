//
//  PinClampTests.swift
//  AnShotUITests
//
//  贴图窗口的「夹进可见区」几何。
//
//  ── 为什么要单测一个看起来只有几行的函数 ────────────────────
//
//  贴图比屏幕还大时没法整个塞进去，只能选择保留哪一侧。选错的代价是
//  **卡片右上角的关闭 / 图钉按钮跑出屏幕**：用户看得到图，却关不掉它，
//  只能等它自己消失或重启应用。
//
//  AppKit 的窗口原点在**左下角**，而人看的是顶边。曾经这里对齐
//  `visible.minY`，本意是「至少左上角能抓到」，实际把溢出部分全堆到了
//  屏幕顶部（菜单栏之外），右上角按钮恰好一起消失——这类「坐标轴想反了」
//  的缺陷在代码里读不出问题，只能靠断言锁住。
//

import AnShotCore
import CoreGraphics
import Testing

@testable import AnShotUI

@Suite("贴图窗口 · 夹进可见区")
@MainActor
struct PinClampTests {

    /// 一块典型的可见区：比整屏矮（菜单栏 + Dock），原点非零更接近真实。
    private static let visible = CGRect(x: 0, y: 40, width: 1440, height: 835)

    @Test("超高贴图保留顶边：右上角按钮不能跑出屏幕")
    func tallerThanVisibleKeepsTopEdge() {
        let size = CGSize(width: 600, height: 1200)
        let origin = PinManager.clampOrigin(CGPoint(x: 100, y: 100), size: size, into: Self.visible)

        // 顶边 = origin.y + height，必须贴住可见区顶边而不是溢出。
        #expect(origin.y + size.height == Self.visible.maxY)
        // 底边会溢出屏幕下沿，这是「保留顶边」的必然代价。
        #expect(origin.y < Self.visible.minY)
    }

    @Test("超宽贴图保留右边：按钮在右侧，不能被推到屏幕外")
    func widerThanVisibleKeepsRightEdge() {
        let size = CGSize(width: 2000, height: 400)
        let origin = PinManager.clampOrigin(CGPoint(x: 0, y: 100), size: size, into: Self.visible)

        #expect(origin.x + size.width == Self.visible.maxX)
        #expect(origin.x < Self.visible.minX)
    }

    @Test("放得下时夹进可见区，越小越靠近原点")
    func smallerThanVisibleIsClampedInside() {
        let size = CGSize(width: 400, height: 300)

        // 左上越界 → 夹到可见区原点。
        let topLeft = PinManager.clampOrigin(CGPoint(x: -500, y: -500), size: size, into: Self.visible)
        #expect(topLeft == CGPoint(x: Self.visible.minX, y: Self.visible.minY))

        // 右下越界 → 夹到「右下角贴住可见区」。
        let bottomRight = PinManager.clampOrigin(
            CGPoint(x: 9_999, y: 9_999), size: size, into: Self.visible
        )
        #expect(bottomRight == CGPoint(
            x: Self.visible.maxX - size.width,
            y: Self.visible.maxY - size.height
        ))

        // 本来就在里面 → 原样不动。
        let inside = CGPoint(x: 200, y: 200)
        #expect(PinManager.clampOrigin(inside, size: size, into: Self.visible) == inside)
    }

    @Test("恰好等于可见区大小：贴齐原点，不左右上下翻转")
    func exactlyVisibleSizeAnchorsToOrigin() {
        let size = Self.visible.size
        let origin = PinManager.clampOrigin(
            CGPoint(x: 123, y: 456), size: size, into: Self.visible
        )
        #expect(origin == CGPoint(x: Self.visible.minX, y: Self.visible.minY))
    }
}
