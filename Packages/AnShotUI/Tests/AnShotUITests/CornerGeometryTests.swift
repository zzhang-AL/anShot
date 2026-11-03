//
//  CornerGeometryTests.swift
//  AnShotUITests
//
//  选框圆角的几何断言。
//
//  ── 本文件的来历 ──────────────────────────────────────────────
//
//  它是 `-diagnoseSelection` 中 `verifyCornerGeometry` / `verifyMaskMatchesBorder`
//  两段诊断的**单元测试版**。那两段诊断自己就写着「不依赖本机硬件，可复现」——
//  它们读的是 `CaptureFrameStyle` / `SelectionHandleLayout` 的纯几何函数，
//  与屏幕、窗口、权限、事件循环都无关，却因为当时的 `AnShotUI` 还没有测试 target
//  而只能塞进 App 内，靠 `open -n anShot.app --args -diagnoseSelection` 人工触发、
//  读日志判断 MATCH / MISMATCH。
//
//  迁到这里之后：CI 每次提交都会跑，失败直接定位到具体断言，
//  既不必启动 App，也不必人工比对日志。
//
//  ── 断言的四件事 ──────────────────────────────────────────────
//
//  1. 基准圆角只按尺寸收窄，不涉及屏幕；
//  2. 贴屏角时取「屏幕半径 − 描边内缩」，使描边外缘与屏幕圆弧重合（共圆心）；
//  3. 只贴一条边**不算**对齐（屏幕在那里是直线，用屏幕半径反而会提前弯向内部）；
//  4. 遮罩挖空的圆角 = 边框路径圆角 + 描边内缩——这是「边框是圆角、挖空是直角」
//     那个缺陷的几何证据；并直接问路径：角点在挖空区之外、圆弧圆心在之内。
//

import CoreGraphics
import Testing

@testable import AnShotUI

@Suite("选框圆角 · 基准半径")
struct CornerBaseRadiusTests {

    /// 受控尺寸：短边 260，远大于「上限半径 / 短边比例」，
    /// 因此基准半径取到上限值；长边足够长，好让「只看短边」有区分度。
    private static let size = CGSize(width: 480, height: 260)

    @Test("基准半径由短边决定，且不超过短边的一半")
    func baseRadiusComesFromShortSide() {
        let base = CaptureFrameStyle.cornerRadius(for: Self.size)
        #expect(base > 0)
        #expect(base <= min(Self.size.width, Self.size.height) / 2)

        // 只换长边，半径不变：半径是短边的函数。
        #expect(CaptureFrameStyle.cornerRadius(for: CGSize(width: 1920, height: Self.size.height)) == base)

        // 短边缩到低于上限时，半径随之收窄（小框上圆角不能占满整圈）。
        #expect(CaptureFrameStyle.cornerRadius(for: CGSize(width: 4, height: 40)) < base)
    }

    @Test("零尺寸框的基准半径为 0，不产生负值或 NaN")
    func zeroSizeHasZeroRadius() {
        #expect(CaptureFrameStyle.cornerRadius(for: .zero) == 0)
        #expect(CaptureFrameStyle.cornerRadii(for: .zero) == CaptureFrameStyle.CornerRadii.uniform(0))
    }

    @Test("cornerRadii 四角同值，等于基准半径")
    func cornerRadiiAreUniform() {
        let base = CaptureFrameStyle.cornerRadius(for: Self.size)
        #expect(CaptureFrameStyle.cornerRadii(for: Self.size) == CaptureFrameStyle.CornerRadii.uniform(base))
    }

    @Test("极小框的半径被夹到半边长以内，路径不会自交")
    func tinySelectionIsClamped() {
        let tiny = CGSize(width: 10, height: 10)
        var radii = CaptureFrameStyle.cornerRadii(for: tiny)
        // 模拟四角都贴上半径为 40 的屏幕角（远大于这个框）。
        for corner in CaptureFrameStyle.Corner.allCases {
            radii = CaptureFrameStyle.alignedRadius(for: corner, in: radii, screenRadius: 40, strokeInset: 0)
        }
        let clamped = CaptureFrameStyle.clamped(radii, to: tiny)
        for value in [clamped.minXMinY, clamped.maxXMinY, clamped.minXMaxY, clamped.maxXMaxY] {
            #expect(value <= 5)
        }
        #expect(clamped == CaptureFrameStyle.CornerRadii.uniform(5))
    }

    @Test("夹取只收窄、不放大：已经在限值内的半径原样返回")
    func clampDoesNotEnlarge() {
        let radii = CaptureFrameStyle.CornerRadii(minXMinY: 1, maxXMinY: 2, minXMaxY: 3, maxXMaxY: 4)
        #expect(CaptureFrameStyle.clamped(radii, to: CGSize(width: 100, height: 100)) == radii)
    }
}

@Suite("选框圆角 · 贴屏角换算")
struct CornerAlignmentTests {

    private static let size = CGSize(width: 480, height: 260)
    private static let base = CaptureFrameStyle.cornerRadius(for: size)

    /// 描边内缩：选中态最外层线宽 2.5 + 对比层 1.5 = 4，内缩其一半。
    private static let strokeInset = CaptureFrameStyle.strokeInset(
        lineWidth: CaptureFrameStyle.selectionStrokeWidth + CaptureFrameStyle.contrastExtraWidth
    )

    @Test("同心换算：路径半径 = 屏幕半径 − 描边内缩")
    func concentricRadiusSubtractsStrokeInset() {
        #expect(
            CaptureFrameStyle.concentricRadius(screenRadius: 20, strokeInset: Self.strokeInset)
                == 20 - Self.strokeInset)
    }

    @Test("屏幕半径小于描边内缩时夹到 0，不退化为负半径")
    func concentricRadiusNeverNegative() {
        #expect(CaptureFrameStyle.concentricRadius(screenRadius: 1, strokeInset: 4) == 0)
        #expect(CaptureFrameStyle.concentricRadius(screenRadius: 0, strokeInset: 4) == 0)
    }

    @Test("alignedRadius 只改指定的那个角，其余三角保持原值")
    func alignedRadiusTouchesOneCornerOnly() {
        let plain = CaptureFrameStyle.cornerRadii(for: Self.size)
        let expected = 20 - Self.strokeInset
        for corner in CaptureFrameStyle.Corner.allCases {
            let radii = CaptureFrameStyle.alignedRadius(
                for: corner, in: plain, screenRadius: 20, strokeInset: Self.strokeInset
            )
            let values: [(CaptureFrameStyle.Corner, CGFloat)] = [
                (.minXMinY, radii.minXMinY),
                (.maxXMinY, radii.maxXMinY),
                (.minXMaxY, radii.minXMaxY),
                (.maxXMaxY, radii.maxXMaxY),
            ]
            for (other, value) in values {
                #expect(value == (other == corner ? expected : Self.base))
            }
        }
    }

    @Test("四角各取自己的屏幕值：不假设四角相等，也不做压平")
    func eachCornerUsesItsOwnScreenRadius() {
        // 左上 20、右上 16、左下 0、右下 24 —— 四角互不相同。
        // 一旦「屏幕角 → 绘图角」的映射写反（例如上下颠倒，
        // 本功能的第一次实现正是栽在这里），本断言必然失败。
        let screen: [(CaptureFrameStyle.Corner, CGFloat)] = [
            (.minXMinY, 20), (.maxXMinY, 16), (.minXMaxY, 0), (.maxXMaxY, 24),
        ]
        var radii = CaptureFrameStyle.cornerRadii(for: Self.size)
        for (corner, screenRadius) in screen {
            radii = CaptureFrameStyle.alignedRadius(
                for: corner, in: radii, screenRadius: screenRadius, strokeInset: Self.strokeInset
            )
        }
        #expect(radii.minXMinY == 20 - Self.strokeInset)
        #expect(radii.maxXMinY == 16 - Self.strokeInset)
        #expect(radii.minXMaxY == 0)
        #expect(radii.maxXMaxY == 24 - Self.strokeInset)
    }

    @Test("矩形屏（屏幕半径为 0）的贴合角为 0，这正是正确的贴合")
    func rectangularScreenGivesZeroRadius() {
        let aligned = CaptureFrameStyle.alignedRadius(
            for: .minXMinY,
            in: CaptureFrameStyle.cornerRadii(for: Self.size),
            screenRadius: 0,
            strokeInset: Self.strokeInset
        )
        #expect(aligned.minXMinY == 0)
    }

    @Test("只贴一条边不算对齐：屏幕在那里是直线")
    func singleEdgeIsNotAligned() {
        // 上边贴住（minYGap = 0），但左右两侧都远离：minY 侧的两个角都不该对齐。
        #expect(
            !CaptureFrameStyle.isCornerAligned(
                .minXMinY, minXGap: 300, maxXGap: 300, minYGap: 0, maxYGap: 400
            ))
        #expect(
            !CaptureFrameStyle.isCornerAligned(
                .maxXMinY, minXGap: 300, maxXGap: 300, minYGap: 0, maxYGap: 400
            ))
    }

    @Test("两条边都贴才算对齐，否则贴合永不生效")
    func bothEdgesAligned() {
        #expect(
            CaptureFrameStyle.isCornerAligned(
                .minXMinY, minXGap: 0, maxXGap: 300, minYGap: 0, maxYGap: 400
            ))
        #expect(
            CaptureFrameStyle.isCornerAligned(
                .maxXMaxY, minXGap: 300, maxXGap: 0, minYGap: 400, maxYGap: 0
            ))
        // 容差内仍算贴边：真实坐标是浮点算出来的，不会精确等于 0。
        #expect(
            CaptureFrameStyle.isCornerAligned(
                .minXMinY, minXGap: 0.5, maxXGap: 300, minYGap: 0.5, maxYGap: 400
            ))
        // 超出容差就不算。
        #expect(
            !CaptureFrameStyle.isCornerAligned(
                .minXMinY, minXGap: 2, maxXGap: 300, minYGap: 0, maxYGap: 400
            ))
    }

    @Test("四角独立：逐个贴合的结果与顺序无关")
    func cornerApplicationsAreIndependent() {
        let plain = CaptureFrameStyle.cornerRadii(for: Self.size)
        let forward = Self.applyAll(plain, order: CaptureFrameStyle.Corner.allCases)
        let reversed = Self.applyAll(plain, order: Array(CaptureFrameStyle.Corner.allCases.reversed()))
        #expect(forward == reversed)
        #expect(forward.minXMinY == 20 - Self.strokeInset)
        #expect(forward.maxXMaxY == 24 - Self.strokeInset)
    }

    /// 按给定顺序把四个角各贴到自己的屏幕半径上。
    private static func applyAll(
        _ radii: CaptureFrameStyle.CornerRadii,
        order: [CaptureFrameStyle.Corner]
    ) -> CaptureFrameStyle.CornerRadii {
        let screenRadius: [(CaptureFrameStyle.Corner, CGFloat)] = [
            (.minXMinY, 20), (.maxXMinY, 16), (.minXMaxY, 0), (.maxXMaxY, 24),
        ]
        var result = radii
        for corner in order {
            let radius = screenRadius.first { $0.0 == corner }?.1 ?? 0
            result = CaptureFrameStyle.alignedRadius(
                for: corner, in: result, screenRadius: radius, strokeInset: strokeInset
            )
        }
        return result
    }
}

@Suite("遮罩挖空与边框同形")
struct MaskMatchesBorderTests {

    /// 居中选区：四角都远离屏幕边缘，屏幕圆角不参与计算，
    /// 因此这些断言与**本机显示器是什么样**无关（CI 上同样成立）。
    private static let viewBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private static let selection = CGRect(x: 300, y: 200, width: 480, height: 260)

    /// 描边内缩：选中态最外层线宽 2.5 + 对比层 1.5 = 4，内缩其一半。
    private static let strokeInset = CaptureFrameStyle.strokeInset(
        lineWidth: CaptureFrameStyle.selectionStrokeWidth + CaptureFrameStyle.contrastExtraWidth
    )

    @Test("遮罩挖空圆角比边框路径多一个描边内缩")
    func maskRadiiAddStrokeInset() {
        let id = CGMainDisplayID()
        let border = SelectionHandleLayout.cornerRadii(
            for: Self.selection, viewBounds: Self.viewBounds, displayID: id
        )
        let mask = SelectionHandleLayout.maskRadii(
            for: Self.selection, viewBounds: Self.viewBounds, displayID: id
        )
        // 独立预期：内缩量 = 装饰矩形相对选区向内缩的距离。
        // 不取 maskRadii 的内部实现作为预期，否则断言会变成自证。
        #expect(Self.strokeInset == SelectionHandleLayout.decoratedRect(for: Self.selection).minX - Self.selection.minX)
        #expect(mask.minXMinY == border.minXMinY + Self.strokeInset)
        #expect(mask.maxXMinY == border.maxXMinY + Self.strokeInset)
        #expect(mask.minXMaxY == border.minXMaxY + Self.strokeInset)
        #expect(mask.maxXMaxY == border.maxXMaxY + Self.strokeInset)
    }

    @Test("挖空真的是圆角：角点在挖空区之外，圆弧圆心在之内")
    func maskPathIsRounded() {
        let id = CGMainDisplayID()
        let mask = SelectionHandleLayout.maskRadii(
            for: Self.selection, viewBounds: Self.viewBounds, displayID: id
        )
        let path = SelectionHandleLayout.maskPath(
            for: Self.selection, viewBounds: Self.viewBounds, displayID: id
        )
        // 选区的直角角点落在圆角之外——用 addRect 挖空时它会在之内，
        // 四个角就会各露出一块没被压暗的小三角。
        #expect(!path.contains(CGPoint(x: Self.selection.minX + 0.5, y: Self.selection.minY + 0.5)))
        // 圆弧圆心在挖空区之内。
        #expect(
            path.contains(
                CGPoint(
                    x: Self.selection.minX + mask.minXMinY,
                    y: Self.selection.minY + mask.minXMinY
                )))
    }

    @Test("居中选区的四角都用基准半径：不贴屏角时完全不碰屏幕值")
    func centeredSelectionUsesBaseRadius() {
        let base = CaptureFrameStyle.cornerRadius(for: Self.selection.size)
        let radii = SelectionHandleLayout.cornerRadii(
            for: Self.selection, viewBounds: Self.viewBounds, displayID: CGMainDisplayID()
        )
        #expect(radii == CaptureFrameStyle.CornerRadii.uniform(base))
    }
}
