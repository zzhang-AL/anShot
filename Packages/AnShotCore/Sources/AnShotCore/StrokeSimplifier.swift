//
//  StrokeSimplifier.swift
//  AnShotCore
//
//  自由笔迹的折线简化（Douglas–Peucker）。
//
//  ── 为什么必须简化而不能直接存采样点 ──────────────────────
//
//  一次拖动的原始采样点可达数千：鼠标事件本身就有上百赫兹，加上
//  高分屏上的亚像素位移，一条两厘米的笔迹能轻易攒出几百个点。
//  这些都进 `Annotation.freehand` 的话：
//
//    - 历史里每一步快照都会复制整条点序列，撤销栈的内存随笔画数平方增长；
//    - 存盘时 JSON 直接膨胀两个数量级（契约 §2.3 明确要求简化）；
//    - 重绘要逐点连线，几十条笔迹叠上去就是每秒几万次线段描边。
//
//  而人手的运动轨迹在容差内本来就是折线可逼近的：**保留下来的点
//  才是笔迹的「拐点」**，被丢掉的那些对最终形状没有贡献。
//
//  ── 为什么是 Douglas–Peucker ──────────────────────────────
//
//  比「等距离抽稀」（每隔 N 个点留一个）好在它按**形状**取舍而不是按步长：
//  抽稀在直线段上留下冗余点、在急转处又丢拐点，同一笔画写得快的地方
//  会明显变钝；DP 则始终保留最偏离基线的那个点，快慢不影响形状保真度。
//

import Foundation

/// 折线简化。
public enum StrokeSimplifier {

    /// 用 Douglas–Peucker 算法简化一条折线。
    ///
    /// **首尾两点始终保留**，即使整条笔迹几乎是直线：
    /// 丢掉端点会让笔迹的起止位置发生肉眼可见的偏移，
    /// 而用户正是照着起止点对齐内容的。
    ///
    /// - Parameters:
    ///   - points: 原始采样点序列（底图像素坐标）。
    ///   - tolerance: 容差（像素）。小于等于 0 或点数不超过 2 时原样返回。
    /// - Returns: 简化后的点序列；首尾与输入一致。
    public static func simplify(_ points: [PixelPoint], tolerance: Double) -> [PixelPoint] {
        guard points.count > 2, tolerance > 0 else { return points }

        // 用「保留标记」而不是递归返回子数组：后者每层都要重新分配数组，
        // 一条上千点的笔迹会产生上千次拷贝，而标记法只分配一次。
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        markKept(points, from: 0, to: points.count - 1, tolerance: tolerance, keep: &keep)

        var result: [PixelPoint] = []
        result.reserveCapacity(points.count)
        for (index, point) in points.enumerated() where keep[index] {
            result.append(point)
        }
        return result
    }

    /// 递归标记 `[start, end]` 区间内需要保留的拐点。
    private static func markKept(
        _ points: [PixelPoint],
        from start: Int,
        to end: Int,
        tolerance: Double,
        keep: inout [Bool]
    ) {
        // 相邻两点之间没有中间点可丢。
        guard end > start + 1 else { return }

        var farthest = -1.0
        var farthestIndex = start

        for index in (start + 1) ..< end {
            let distance = perpendicularDistance(
                points[index],
                lineFrom: points[start],
                to: points[end]
            )
            if distance > farthest {
                farthest = distance
                farthestIndex = index
            }
        }

        // 所有中间点都在容差内：这一段可以用一条直线替代，不再细分。
        guard farthest > tolerance else { return }

        keep[farthestIndex] = true
        markKept(points, from: start, to: farthestIndex, tolerance: tolerance, keep: &keep)
        markKept(points, from: farthestIndex, to: end, tolerance: tolerance, keep: &keep)
    }

    /// 点到线段的垂直距离。
    ///
    /// 起止点重合时（笔迹折返回到起点）退化为点到点的距离：
    /// 此时直线没有方向可言，用投影公式会得到 0/0。
    private static func perpendicularDistance(
        _ point: PixelPoint,
        lineFrom start: PixelPoint,
        to end: PixelPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else {
            let offsetX = point.x - start.x
            let offsetY = point.y - start.y
            return (offsetX * offsetX + offsetY * offsetY).squareRoot()
        }

        // 叉积的绝对值除以基线长度 = 点到直线的垂直距离。
        let cross = (point.x - start.x) * dy - (point.y - start.y) * dx
        return abs(cross) / lengthSquared.squareRoot()
    }
}
