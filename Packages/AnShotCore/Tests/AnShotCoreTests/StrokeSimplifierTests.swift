//
//  StrokeSimplifierTests.swift
//  AnShotCoreTests
//
//  笔迹简化的行为契约。
//
//  为什么必须单测而不是靠渲染结果看：Douglas–Peucker 失效时**画面仍然是对的**
//  （用户看不出 250 个点与 12 个点的笔迹差别），但历史快照的内存与存盘体积
//  会成倍增长。这类退化只能靠断言点数与偏差来抓。
//

import Foundation
import Testing

@testable import AnShotCore

@Suite("笔迹简化（Douglas–Peucker）")
struct StrokeSimplifierTests {

    /// 在一条直线上均匀取 `count` 个点。
    private func straightLine(
        from start: PixelPoint,
        to end: PixelPoint,
        count: Int
    ) -> [PixelPoint] {
        (0 ..< count).map { index in
            let t = Double(index) / Double(count - 1)
            return PixelPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
        }
    }

    @Test("共线点被压成首尾两点")
    func collapsesCollinearRun() {
        let points = straightLine(
            from: PixelPoint(x: 0, y: 0),
            to: PixelPoint(x: 100, y: 0),
            count: 50
        )
        let simplified = StrokeSimplifier.simplify(points, tolerance: 1)

        #expect(simplified.count == 2)
        #expect(simplified.first == points.first)
        #expect(simplified.last == points.last)
    }

    @Test("拐点必须保留")
    func keepsCorners() {
        // 一条 L 形折线：直角处那一点是整条笔迹的形状所在。
        let points = [
            PixelPoint(x: 0, y: 0),
            PixelPoint(x: 50, y: 0),
            PixelPoint(x: 100, y: 0),
            PixelPoint(x: 100, y: 50),
            PixelPoint(x: 100, y: 100),
        ]
        let simplified = StrokeSimplifier.simplify(points, tolerance: 1)

        #expect(simplified.count == 3)
        #expect(simplified[1] == PixelPoint(x: 100, y: 0))
    }

    @Test("容差增大时保留点单调减少")
    func looserToleranceKeepsFewerPoints() {
        // 一段带轻微抖动的笔迹：容差越大，抖动越会被当作噪声抹平。
        let points = (0 ..< 40).map { index in
            PixelPoint(x: Double(index) * 2, y: Double(index % 2) * 0.8)
        }
        let tight = StrokeSimplifier.simplify(points, tolerance: 0.1)
        let loose = StrokeSimplifier.simplify(points, tolerance: 2)

        #expect(loose.count <= tight.count)
        #expect(tight.count <= points.count)
    }

    @Test("丢弃的点到保留折线的偏差不超过容差")
    func respectsTolerance() {
        let points = (0 ..< 60).map { index in
            let x = Double(index)
            // 正弦扰动：既要产生真实的弯曲，又要让简化确实生效。
            return PixelPoint(x: x, y: sin(x / 7) * 6)
        }
        let tolerance = 2.0
        let simplified = StrokeSimplifier.simplify(points, tolerance: tolerance)

        // 简化后的点必须是原序列的子序列，且首尾不变。
        #expect(simplified.first == points.first)
        #expect(simplified.last == points.last)

        var cursor = 0
        for point in simplified {
            while cursor < points.count, points[cursor] != point {
                cursor += 1
            }
            #expect(cursor < points.count)
        }

        let kept = Set(simplified.map { "\($0.x),\($0.y)" })
        for point in points where !kept.contains("\(point.x),\(point.y)") {
            let deviation = perpendicularDeviation(point, in: simplified)
            #expect(deviation <= tolerance + 1e-9)
        }
    }

    @Test("闭合笔迹不会被压掉")
    func keepsClosedStroke() {
        // 首尾重合的圈：基线长度为 0，投影公式会退化成 0/0。
        // 这里若算错，整条笔迹会被压成两个相同的点，圈直接消失。
        let points = [
            PixelPoint(x: 0, y: 0),
            PixelPoint(x: 50, y: 0),
            PixelPoint(x: 50, y: 50),
            PixelPoint(x: 0, y: 50),
            PixelPoint(x: 0, y: 0),
        ]
        let simplified = StrokeSimplifier.simplify(points, tolerance: 1)

        #expect(simplified.count == points.count)
    }

    @Test("点数不超过两点或容差非正时原样返回")
    func passthroughCases() {
        let pair = [PixelPoint(x: 0, y: 0), PixelPoint(x: 10, y: 10)]
        #expect(StrokeSimplifier.simplify(pair, tolerance: 5) == pair)

        let single = [PixelPoint(x: 1, y: 2)]
        #expect(StrokeSimplifier.simplify(single, tolerance: 5) == single)

        let points = straightLine(
            from: PixelPoint(x: 0, y: 0),
            to: PixelPoint(x: 10, y: 0),
            count: 10
        )
        #expect(StrokeSimplifier.simplify(points, tolerance: 0) == points)
        #expect(StrokeSimplifier.simplify(points, tolerance: -1) == points)
    }

    /// 点到折线的最短距离（逐段取垂距，取最小）。
    private func perpendicularDeviation(
        _ point: PixelPoint,
        in polyline: [PixelPoint]
    ) -> Double {
        guard polyline.count >= 2 else { return .infinity }
        var best = Double.infinity
        for index in 1 ..< polyline.count {
            best = min(best, segmentDistance(point, polyline[index - 1], polyline[index]))
        }
        return best
    }

    /// 点到线段的最短距离。
    private func segmentDistance(
        _ point: PixelPoint,
        _ start: PixelPoint,
        _ end: PixelPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        // 投影参数夹在 [0, 1] 内：落在线段外时取端点距离。
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = PixelPoint(x: start.x + dx * t, y: start.y + dy * t)
        return hypot(point.x - projection.x, point.y - projection.y)
    }
}
