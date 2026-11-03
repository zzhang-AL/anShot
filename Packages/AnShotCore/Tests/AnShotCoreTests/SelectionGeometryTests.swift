//
//  SelectionGeometryTests.swift
//  AnShotCoreTests
//
//  选区几何与坐标换算的单元测试。
//
//  plan.md §5 要求「坐标换算 1x 与 2x 屏各测一次，选区边界与导出像素一致」。
//  本文件用 1x 与 2x 两组参数把该要求固定在测试里，
//  而不是依赖每次手工上机验证——多显示器组合无法在单台机器上穷举。
//

import CoreGraphics
import Testing
@testable import AnShotCore

// MARK: - 坐标换算

@Suite("坐标换算")
struct CoordinateConversionTests {

    @Test("1x 屏：像素与逻辑点数值相同")
    func scaleFactorOneIsIdentity() {
        let logical = CGRect(x: 10, y: 20, width: 300, height: 200)
        let pixel = CoordinateConversion.pixelRect(fromLogical: logical, scaleFactor: 1)

        #expect(pixel.origin.x == 10)
        #expect(pixel.origin.y == 20)
        #expect(pixel.size.width == 300)
        #expect(pixel.size.height == 200)
    }

    @Test("2x 屏：像素是逻辑点的两倍")
    func scaleFactorTwoDoubles() {
        let logical = CGRect(x: 200, y: 150, width: 600, height: 400)
        let pixel = CoordinateConversion.pixelRect(fromLogical: logical, scaleFactor: 2)

        // 与 P2 实测的已验证值一致：600x400 逻辑点 → 1200x800 像素
        #expect(pixel.origin.x == 400)
        #expect(pixel.origin.y == 300)
        #expect(pixel.size.width == 1200)
        #expect(pixel.size.height == 800)
    }

    @Test("换算是纯缩放：不含轴向翻转", arguments: [1.0, 2.0] as [CGFloat])
    func conversionPreservesOrientation(scale: CGFloat) {
        // 左上角的一个点必须仍落在左上角附近，而不是跑到左下角。
        let logical = CGRect(x: 0, y: 0, width: 100, height: 50)
        let pixel = CoordinateConversion.pixelRect(fromLogical: logical, scaleFactor: scale)

        #expect(pixel.origin.x == 0)
        #expect(pixel.origin.y == 0)
        #expect(pixel.size.width == Double(100 * scale))
        #expect(pixel.size.height == Double(50 * scale))
    }

    @Test("往返换算无损", arguments: [1.0, 2.0] as [CGFloat])
    func roundTripIsLossless(scale: CGFloat) {
        let original = CGRect(x: 123, y: 456, width: 789, height: 321)
        let pixel = CoordinateConversion.pixelRect(fromLogical: original, scaleFactor: scale)
        let back = CoordinateConversion.logicalRect(fromPixel: pixel, scaleFactor: scale)

        #expect(abs(back.minX - original.minX) < 1e-9)
        #expect(abs(back.minY - original.minY) < 1e-9)
        #expect(abs(back.width - original.width) < 1e-9)
        #expect(abs(back.height - original.height) < 1e-9)
    }

    @Test("非整数缩放（如 1.5x）不丢失精度")
    func fractionalScaleIsPreserved() {
        // 部分外接屏的缩放档位会产生非整数倍率。
        let logical = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let pixel = CoordinateConversion.pixelRect(fromLogical: logical, scaleFactor: 1.5)

        #expect(pixel.size.width == 1500)
        #expect(pixel.size.height == 1500)
    }
}

// MARK: - 拖拽规范化

@Suite("拖拽规范化")
struct NormalizedRectTests {

    @Test("从左下往右上拖拽与反向拖拽结果相同")
    func directionAgnostic() {
        let a = SelectionGeometry.normalizedRect(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 300, y: 500))
        let b = SelectionGeometry.normalizedRect(from: CGPoint(x: 300, y: 500), to: CGPoint(x: 100, y: 200))

        #expect(a == b)
        #expect(a.origin == CGPoint(x: 100, y: 200))
        #expect(a.size == CGSize(width: 200, height: 300))
    }

    @Test("四个拖拽方向都得到同一矩形")
    func allFourDirectionsAgree() {
        let corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)
        ]
        let expected = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pairs = [(0, 3), (1, 2), (2, 1), (3, 0)]

        for (i, j) in pairs {
            #expect(SelectionGeometry.normalizedRect(from: corners[i], to: corners[j]) == expected)
        }
    }

    @Test("零尺寸拖拽得到空矩形")
    func zeroSizeDrag() {
        let rect = SelectionGeometry.normalizedRect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        #expect(rect.width == 0)
        #expect(rect.height == 0)
    }
}

// MARK: - 手柄缩放

@Suite("手柄缩放")
struct ResizedRectTests {

    private let base = CGRect(x: 100, y: 100, width: 200, height: 200)
    private let minSize: CGFloat = 8

    @Test("四个角手柄移动对应的两条边")
    func cornerHandlesMoveTwoEdges() {
        let tl = SelectionGeometry.resizedRect(base, handle: .topLeft, to: CGPoint(x: 50, y: 60), minimumSize: minSize)
        #expect(tl == CGRect(x: 50, y: 60, width: 250, height: 240))

        let br = SelectionGeometry.resizedRect(base, handle: .bottomRight, to: CGPoint(x: 400, y: 350), minimumSize: minSize)
        #expect(br == CGRect(x: 100, y: 100, width: 300, height: 250))
    }

    @Test("四个边手柄只移动一条边")
    func edgeHandlesMoveOneEdge() {
        let top = SelectionGeometry.resizedRect(base, handle: .top, to: CGPoint(x: 150, y: 40), minimumSize: minSize)
        #expect(top == CGRect(x: 100, y: 40, width: 200, height: 260))

        let right = SelectionGeometry.resizedRect(base, handle: .right, to: CGPoint(x: 500, y: 150), minimumSize: minSize)
        #expect(right == CGRect(x: 100, y: 100, width: 400, height: 200))
    }

    @Test("拖过对边时被钳制，不允许翻转")
    func clampingPreventsFlip() {
        // 左边界被拖到远超右边界的位置
        let rect = SelectionGeometry.resizedRect(base, handle: .left, to: CGPoint(x: 9999, y: 150), minimumSize: minSize)
        #expect(rect.minX == base.maxX - minSize)
        #expect(rect.width == minSize)
        #expect(rect.width > 0)
    }

    @Test("四个方向都不会翻转出负尺寸")
    func neverProducesNegativeSize() {
        let oversized = CGPoint(x: 99999, y: 99999)
        let undersized = CGPoint(x: -99999, y: -99999)

        for handle in SelectionHandle.allCases {
            for point in [oversized, undersized] {
                let rect = SelectionGeometry.resizedRect(base, handle: handle, to: point, minimumSize: minSize)
                #expect(rect.width > 0, "handle=\(handle) 产生了非正宽度")
                #expect(rect.height > 0, "handle=\(handle) 产生了非正高度")
                #expect(rect.width >= minSize)
                #expect(rect.height >= minSize)
            }
        }
    }
}

// MARK: - 手柄命中测试

@Suite("手柄命中测试")
struct HandleHitTestTests {

    private let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test("每个手柄的中心都能命中自身")
    func centersHitThemselves() {
        for handle in SelectionHandle.allCases {
            let center = SelectionGeometry.center(of: handle, in: rect)
            #expect(SelectionGeometry.handle(at: center, in: rect, tolerance: 2) == handle)
        }
    }

    @Test("手柄中心位置符合归一化定义")
    func centersMatchUnitPoints() {
        #expect(SelectionGeometry.center(of: .topLeft, in: rect) == CGPoint(x: 100, y: 100))
        #expect(SelectionGeometry.center(of: .topRight, in: rect) == CGPoint(x: 300, y: 100))
        #expect(SelectionGeometry.center(of: .bottomLeft, in: rect) == CGPoint(x: 100, y: 200))
        #expect(SelectionGeometry.center(of: .bottomRight, in: rect) == CGPoint(x: 300, y: 200))
        #expect(SelectionGeometry.center(of: .top, in: rect) == CGPoint(x: 200, y: 100))
        #expect(SelectionGeometry.center(of: .left, in: rect) == CGPoint(x: 100, y: 150))
    }

    @Test("选区正中心不命中任何手柄")
    func centerOfSelectionMissesAllHandles() {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        #expect(SelectionGeometry.handle(at: center, in: rect, tolerance: 2) == nil)
    }

    @Test("容差之外不命中")
    func outsideToleranceMisses() {
        let nearTopLeft = CGPoint(x: 100 + 10, y: 100 + 10)
        #expect(SelectionGeometry.handle(at: nearTopLeft, in: rect, tolerance: 2) == nil)
        #expect(SelectionGeometry.handle(at: nearTopLeft, in: rect, tolerance: 12) == .topLeft)
    }
}

// MARK: - 钳制

@Suite("钳制")
struct ClampTests {

    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test("点被限制在边界内")
    func clampsPoint() {
        #expect(SelectionGeometry.clamp(CGPoint(x: -50, y: -50), to: bounds) == CGPoint(x: 0, y: 0))
        #expect(SelectionGeometry.clamp(CGPoint(x: 5000, y: 5000), to: bounds) == CGPoint(x: 1000, y: 800))
        #expect(SelectionGeometry.clamp(CGPoint(x: 500, y: 400), to: bounds) == CGPoint(x: 500, y: 400))
    }

    @Test("矩形移动时保持尺寸不变")
    func clampsRectKeepingSize() {
        let rect = CGRect(x: 900, y: 700, width: 200, height: 100)
        let clamped = SelectionGeometry.clamp(rect, to: bounds)

        #expect(clamped.size == rect.size)
        #expect(clamped.maxX <= bounds.maxX)
        #expect(clamped.maxY <= bounds.maxY)
    }

    @Test("矩形小于边界时不会被压成负值")
    func clampsRectWhenSmallerThanBounds() {
        let rect = CGRect(x: -500, y: -500, width: 50, height: 50)
        let clamped = SelectionGeometry.clamp(rect, to: bounds)

        #expect(clamped.origin == CGPoint(x: 0, y: 0))
        #expect(clamped.size == rect.size)
    }
}
