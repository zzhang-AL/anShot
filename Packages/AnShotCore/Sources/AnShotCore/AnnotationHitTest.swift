//
//  AnnotationHitTest.swift
//  AnShotCore
//
//  标注的命中测试与整体平移。
//
//  为什么单独成文件而不是并进 Annotation.swift：
//  `Annotation.swift` 只描述「一条标注长什么样」，编解码已经占了大半；
//  命中测试是**交互几何**（点 → 是否被我接住），依赖 CoreText 测量文字，
//  与模型序列化没有任何关系。放在一起会让模型文件同时依赖排版栈。
//
//  命中规则（契约 docs/refactor/flow-closure-contract.md §4.1）：
//  - 线框类按**路径/边界距离**判定，面状类（填充矩形、高亮、马赛克、
//    放大镜、编号）按**区域包含**判定；
//  - 文字按 `TextMetrics` 同一套排版结果得到的包围盒判定；
//  - 所有距离都加上 `tolerance`，粗线再额外算半个线宽——
//    用户看到的是「那条有宽度的线」，点在笔画边缘也应该算命中。
//

import CoreGraphics
import CoreText
import Foundation

extension Annotation {
    /// 点是否命中本标注。
    ///
    /// - Parameters:
    ///   - point: 底图像素坐标（原点左上，y 轴向下）。
    ///   - tolerance: 额外容差（底图像素），由调用方按缩放比给出；
    ///     负值按 0 处理。
    /// - Returns: 命中为 `true`。
    ///
    /// 命中顺序（z 序反向遍历）由调用方决定：同一个点可能同时命中多条标注，
    /// 模型层不该替界面选择「最上面那条」。
    public func hitTest(_ point: PixelPoint, tolerance: Double) -> Bool {
        let slack = max(0, tolerance)

        switch kind {
        case let .rectangle(rect, stroke, fill, _):
            // 有填充就是一块「面」：内部任意一点都算命中。
            // 只描边时按边界算距离——否则一个空心大框会把框里所有内容
            // 都挡在它后面，用户点内容却选中了压在最上面的框。
            // 圆角只影响角上极小的一块面积，按直角矩形判定即可。
            if fill != nil {
                return Self.contains(rect, point, slack: slack)
            }
            return Self.distanceToRectBoundary(point, rect) <= slack + stroke.width / 2

        case let .line(start, end, stroke):
            return Self.distanceToSegment(point, start, end) <= slack + stroke.width / 2

        case let .arrow(start, end, stroke, headLength, headWidth):
            let threshold = slack + stroke.width / 2
            if Self.distanceToSegment(point, start, end) <= threshold {
                return true
            }
            return Self.hitTestArrowHead(
                point: point,
                tip: end,
                directionFrom: start,
                headLength: headLength,
                headWidth: headWidth,
                tolerance: threshold
            )

        case let .text(origin, text, font, _, _, maxWidth):
            let box = Self.measuredTextRect(
                origin: origin,
                text: text,
                font: font,
                maxWidth: maxWidth
            )
            guard box.isNonEmpty else { return false }
            return Self.contains(box, point, slack: slack)

        case let .mosaic(rect, _, _), let .highlight(rect, _):
            return Self.contains(rect, point, slack: slack)

        case let .mosaicStroke(points, radius, _, _):
            // 涂抹的覆盖范围就是「路径 + 笔刷半径」。
            return Self.distanceToPolyline(point, points) <= slack + radius

        case let .numbering(center, radius, _, _, _, _):
            return Self.distance(point, center) <= slack + radius

        case let .measure(start, end, stroke):
            return Self.distanceToSegment(point, start, end) <= slack + stroke.width / 2

        case let .magnifier(center, radius, _, border):
            return Self.distance(point, center) <= slack + radius + border.width / 2

        case let .freehand(points, stroke):
            return Self.distanceToPolyline(point, points) <= slack + stroke.width / 2

        case let .curvedArrow(start, control, end, stroke, headLength, headWidth):
            let threshold = slack + stroke.width / 2
            let samples = Self.quadraticSamples(from: start, control: control, to: end)
            if Self.distanceToPolyline(point, samples) <= threshold {
                return true
            }
            let tangentOrigin = Self.distance(control, end) > 0 ? control : start
            return Self.hitTestArrowHead(
                point: point,
                tip: end,
                directionFrom: tangentOrigin,
                headLength: headLength,
                headWidth: headWidth,
                tolerance: threshold
            )
        }
    }

    /// 椭圆标注命中测试辅助函数（预留供集成阶段接入 `Kind.ellipse` 复用）。
    ///
    /// - Parameters:
    ///   - point: 测试点（底图像素坐标）
    ///   - rect: 椭圆外接矩形
    ///   - stroke: 描边样式
    ///   - fill: 可选填充颜色；非 `nil` 时按面状区域命中，否则按椭圆轮廓距离命中
    ///   - tolerance: 额外命中容差（底图像素）
    public static func hitTestEllipse(
        point: PixelPoint,
        rect: PixelRect,
        stroke: StrokeStyle,
        fill: RGBAColor?,
        tolerance: Double
    ) -> Bool {
        let rx = rect.size.width / 2
        let ry = rect.size.height / 2
        guard rx > 0, ry > 0 else {
            return false
        }

        let slack = max(0, tolerance)
        let threshold = slack + stroke.width / 2
        let cx = rect.origin.x + rx
        let cy = rect.origin.y + ry

        if fill != nil {
            let ex = rx + threshold
            let ey = ry + threshold
            let nx = (point.x - cx) / ex
            let ny = (point.y - cy) / ey
            return nx * nx + ny * ny <= 1
        }

        // 将椭圆轮廓离散为 96 段闭合折线，在任意长宽比下精确测量点到椭圆边界的最短距离。
        let steps = 96
        var samples: [PixelPoint] = []
        samples.reserveCapacity(steps + 1)
        for step in 0 ... steps {
            let angle = (Double(step) / Double(steps)) * (.pi * 2)
            samples.append(PixelPoint(
                x: cx + rx * Foundation.cos(angle),
                y: cy + ry * Foundation.sin(angle)
            ))
        }
        return distanceToPolyline(point, samples) <= threshold
    }

    /// 命中测试与选中框使用的紧致包围盒。
    ///
    /// 与 `boundingRect` 的唯一差别是文字：`boundingRect` 在排版前无法得知
    /// 文字宽高，只返回零尺寸；这里按 `TextMetrics` 的同一套字体做一次排版，
    /// 得到真实包围盒。选中框要套住文字，就必须用这一份。
    public var hitBoundingRect: PixelRect {
        switch kind {
        case let .text(origin, text, font, _, _, maxWidth):
            return Self.measuredTextRect(
                origin: origin,
                text: text,
                font: font,
                maxWidth: maxWidth
            )
        default:
            return boundingRect
        }
    }

    /// 整体平移（不改变形状与样式）。
    ///
    /// 放在模型层而不是编辑器：十二种 kind 的坐标字段各不相同，
    /// 散落在界面上迟早会漏掉一种（例如忘了 `curvedArrow.control`），
    /// 表现为「拖了但曲线形状跟着变形」。
    public func translated(by delta: PixelPoint) -> Annotation {
        guard delta != PixelPoint.zero else { return self }
        return Annotation(id: id, kind: kind.translated(by: delta))
    }
}

// MARK: - 几何工具

extension Annotation.Kind {
    /// 所有坐标字段整体平移。
    fileprivate func translated(by delta: PixelPoint) -> Annotation.Kind {
        // 点与矩形各写一个局部平移函数：`PixelRect` 没有 `offsetBy` 之类的
        // 便捷方法，若在 12 个分支里各写一遍 origin/size，漏掉一处就会
        // 出现「拖了，但只有一部分坐标跟着动」。
        func moved(_ point: PixelPoint) -> PixelPoint {
            PixelPoint(x: point.x + delta.x, y: point.y + delta.y)
        }
        func moved(_ rect: PixelRect) -> PixelRect {
            PixelRect(origin: moved(rect.origin), size: rect.size)
        }

        switch self {
        case let .rectangle(rect, stroke, fill, cornerRadius):
            return .rectangle(rect: moved(rect), stroke: stroke, fill: fill, cornerRadius: cornerRadius)

        case let .line(start, end, stroke):
            return .line(start: moved(start), end: moved(end), stroke: stroke)

        case let .arrow(start, end, stroke, headLength, headWidth):
            return .arrow(
                start: moved(start),
                end: moved(end),
                stroke: stroke,
                headLength: headLength,
                headWidth: headWidth
            )

        case let .text(origin, text, font, color, background, maxWidth):
            return .text(
                origin: moved(origin),
                text: text,
                font: font,
                color: color,
                background: background,
                maxWidth: maxWidth
            )

        case let .mosaic(rect, mode, intensity):
            return .mosaic(rect: moved(rect), mode: mode, intensity: intensity)

        case let .mosaicStroke(points, radius, mode, intensity):
            return .mosaicStroke(points: points.map { moved($0) }, radius: radius, mode: mode, intensity: intensity)

        case let .numbering(center, radius, index, stroke, fill, textColor):
            return .numbering(
                center: moved(center),
                radius: radius,
                index: index,
                stroke: stroke,
                fill: fill,
                textColor: textColor
            )

        case let .highlight(rect, color):
            return .highlight(rect: moved(rect), color: color)

        case let .measure(start, end, stroke):
            return .measure(start: moved(start), end: moved(end), stroke: stroke)

        case let .magnifier(center, radius, zoom, border):
            return .magnifier(center: moved(center), radius: radius, zoom: zoom, border: border)

        case let .freehand(points, stroke):
            return .freehand(points: points.map { moved($0) }, stroke: stroke)

        case let .curvedArrow(start, control, end, stroke, headLength, headWidth):
            return .curvedArrow(
                start: moved(start),
                control: moved(control),
                end: moved(end),
                stroke: stroke,
                headLength: headLength,
                headWidth: headWidth
            )
        }
    }
}

extension Annotation {
    /// 两点距离。
    fileprivate static func distance(_ a: PixelPoint, _ b: PixelPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 点到线段的最短距离。
    ///
    /// 用投影参数 t 夹到 `[0, 1]`：不夹的话起点与终点之外的延长线上
    /// 也会被算作命中（点在线的正后方几个像素也会选中它）。
    fileprivate static func distanceToSegment(
        _ point: PixelPoint,
        _ start: PixelPoint,
        _ end: PixelPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return distance(point, start)
        }
        let raw = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let t = min(max(raw, 0), 1)
        let projection = PixelPoint(x: start.x + dx * t, y: start.y + dy * t)
        return distance(point, projection)
    }

    /// 点到折线的最短距离。
    fileprivate static func distanceToPolyline(_ point: PixelPoint, _ points: [PixelPoint]) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return distance(point, first) }
        var best = Double.infinity
        for index in 1 ..< points.count {
            best = min(best, distanceToSegment(point, points[index - 1], points[index]))
        }
        return best
    }

    /// 点到矩形**边界**的距离；点在矩形内部时返回到最近一条边的距离。
    fileprivate static func distanceToRectBoundary(_ point: PixelPoint, _ rect: PixelRect) -> Double {
        let minX = rect.origin.x
        let minY = rect.origin.y
        let maxX = minX + rect.size.width
        let maxY = minY + rect.size.height
        let outsideX = max(minX - point.x, point.x - maxX, 0)
        let outsideY = max(minY - point.y, point.y - maxY, 0)
        if outsideX > 0 || outsideY > 0 {
            return (outsideX * outsideX + outsideY * outsideY).squareRoot()
        }
        return min(point.x - minX, maxX - point.x, point.y - minY, maxY - point.y)
    }

    /// 矩形（可外扩 `slack`）是否包含该点。
    fileprivate static func contains(_ rect: PixelRect, _ point: PixelPoint, slack: Double) -> Bool {
        point.x >= rect.origin.x - slack
            && point.y >= rect.origin.y - slack
            && point.x <= rect.origin.x + rect.size.width + slack
            && point.y <= rect.origin.y + rect.size.height + slack
    }

    /// 二次贝塞尔曲线的采样点（含端点）。
    ///
    /// 命中测试用的是「折线到点的距离」，所以曲线必须先离散。
    /// 段数固定 32：一段 1000px 的曲线相邻采样点间距约 30px，
    /// 但折线偏离真实曲线的最大误差只有弦长的平方量级（远小于容差），
    /// 再多采样对判定结果没有影响，只会增加每次鼠标移动的计算量。
    fileprivate static func quadraticSamples(
        from start: PixelPoint,
        control: PixelPoint,
        to end: PixelPoint
    ) -> [PixelPoint] {
        let steps = 32
        return (0 ... steps).map { step in
            let t = Double(step) / Double(steps)
            let oneMinusT = 1 - t
            let a = oneMinusT * oneMinusT
            let b = 2 * oneMinusT * t
            let c = t * t
            return PixelPoint(
                x: a * start.x + b * control.x + c * end.x,
                y: a * start.y + b * control.y + c * end.y
            )
        }
    }

    /// 点是否命中箭头头部三角形（含三角形内部与三边外扩容差）。
    fileprivate static func hitTestArrowHead(
        point: PixelPoint,
        tip: PixelPoint,
        directionFrom: PixelPoint,
        headLength: Double,
        headWidth: Double,
        tolerance: Double
    ) -> Bool {
        let dx = tip.x - directionFrom.x
        let dy = tip.y - directionFrom.y
        let length = (dx * dx + dy * dy).squareRoot()
        let head = max(0, headLength)
        let halfWidth = max(0, headWidth) / 2
        guard length > 0, head > 0, halfWidth > 0 else {
            return false
        }

        let ux = dx / length
        let uy = dy / length
        let nx = -uy
        let ny = ux

        let headBase = PixelPoint(x: tip.x - ux * head, y: tip.y - uy * head)
        let left = PixelPoint(x: headBase.x + nx * halfWidth, y: headBase.y + ny * halfWidth)
        let right = PixelPoint(x: headBase.x - nx * halfWidth, y: headBase.y - ny * halfWidth)

        if pointInTriangle(point, tip, left, right) {
            return true
        }
        return distanceToSegment(point, tip, left) <= tolerance
            || distanceToSegment(point, left, right) <= tolerance
            || distanceToSegment(point, right, tip) <= tolerance
    }

    /// 判定点是否位于三角形内部（含边界）。
    fileprivate static func pointInTriangle(
        _ p: PixelPoint,
        _ a: PixelPoint,
        _ b: PixelPoint,
        _ c: PixelPoint
    ) -> Bool {
        func cross(_ p1: PixelPoint, _ p2: PixelPoint, _ p3: PixelPoint) -> Double {
            (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
        }
        let d1 = cross(p, a, b)
        let d2 = cross(p, b, c)
        let d3 = cross(p, c, a)
        let hasNegative = (d1 < 0) || (d2 < 0) || (d3 < 0)
        let hasPositive = (d1 > 0) || (d2 > 0) || (d3 > 0)
        return !(hasNegative && hasPositive)
    }

    /// 文字标注的实际排版包围盒。
    ///
    /// 与 `AnnotationRenderer.drawText` 共用 `TextMetrics.layoutLines` 同一套排版路径，
    /// 保证断行宽度、行高及末尾换行高度完全一致。
    ///
    /// `origin` 是**基线起点**，因此包围盒上边为 `origin.y - ascent`。
    fileprivate static func measuredTextRect(
        origin: PixelPoint,
        text: String,
        font: FontDescriptor,
        maxWidth: Double?
    ) -> PixelRect {
        guard !text.isEmpty else {
            return PixelRect(origin: origin, size: PixelSize.zero)
        }

        let layout = TextMetrics.layoutLines(text: text, font: font, maxWidth: maxWidth)
        var lineWidth = 0.0
        var totalHeight = 0.0
        for line in layout.lines {
            lineWidth = max(lineWidth, line.width)
            totalHeight += line.height
        }

        return PixelRect(
            origin: PixelPoint(x: origin.x, y: origin.y - layout.ascent),
            size: PixelSize(width: lineWidth, height: totalHeight)
        )
    }
}
