//
//  AnnotationToolbarIcons.swift
//  AnShotUI
//
//  工具栏全套「精雕双色线性（Duotone Outline）」矢量图标绘制引擎。
//
//  设计规范：
//  - 统一 20×20 逻辑光学网格（核心活区 [2.5, 17.5]，映射到按钮居中 18×18 渲染盒）；
//  - 统一主描边 1.55pt（圆头 `.round`、圆角 `.round`），次级细节线 1.25pt；
//  - 统一双色柔铺层（Duotone Fill = 主墨色 20% 透明度），在深色玻璃、浅色霜白与
//    蓝色激活态反白下均可自动保持一致的光学体量与层次感，彻底消除 SF Symbols 与
//    手绘几何线混搭造成的视觉割裂。
//

import AppKit
import AnShotCore
import CoreText

enum AnnotationToolbarIcons {

    /// 统一图标绘制上下文参数（封装前景色、透明度与外观感知）。
    struct Style {
        let inkColor: NSColor
        let alpha: CGFloat

        var strokeColor: CGColor {
            inkColor.withAlphaComponent(inkColor.alphaComponent * alpha).cgColor
        }

        func fillColor(opacity: CGFloat = 0.20) -> CGColor {
            inkColor.withAlphaComponent(inkColor.alphaComponent * alpha * opacity).cgColor
        }

        func ink(_ factor: CGFloat) -> NSColor {
            inkColor.withAlphaComponent(inkColor.alphaComponent * alpha * factor)
        }
    }

    // MARK: - 统一 20×20 逻辑网格变换

    /// 将 `20×20` 逻辑网格映射到按钮居中 `boxSize × boxSize` 渲染盒，并预设统一笔触状态。
    private static func drawInGrid(
        rect: CGRect,
        boxSize: CGFloat = 18.0,
        style: Style,
        in context: CGContext,
        body: (CGContext) -> Void
    ) {
        let scale = boxSize / 20.0
        let originX = rect.midX - boxSize / 2.0
        let originY = rect.midY - boxSize / 2.0

        context.saveGState()
        context.translateBy(x: originX, y: originY)
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(style.strokeColor)
        context.setFillColor(style.fillColor())
        context.setLineWidth(1.55 / scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        body(context)
        context.restoreGState()
    }

    /// 逻辑网格内的主描边宽（确保屏幕输出恒定 1.55pt）。
    private static let primaryStroke: CGFloat = 1.55 / (18.0 / 20.0)
    /// 逻辑网格内的次级细节描边宽（约 1.25pt）。
    private static let detailStroke: CGFloat = 1.25 / (18.0 / 20.0)

    // MARK: - 主栏高频与次高频标注工具

    static func drawTool(_ tool: AnnotationTool, in rect: CGRect, style: Style, context: CGContext) {
        switch tool {
        case .pointer: drawPointer(in: rect, style: style, context: context)
        case .rectangle: drawRectangle(in: rect, style: style, context: context)
        case .ellipse: drawEllipse(in: rect, style: style, context: context)
        case .arrow: drawArrow(in: rect, style: style, context: context)
        case .freehand: drawFreehand(in: rect, style: style, context: context)
        case .highlight: drawHighlight(in: rect, style: style, context: context)
        case .text: drawText(in: rect, style: style, context: context)
        case .mosaic: drawMosaic(in: rect, style: style, context: context)
        case .numbering: drawNumbering(in: rect, style: style, context: context)
        case .spotlight: drawSpotlight(in: rect, style: style, context: context)
        case .line: drawLine(in: rect, style: style, context: context)
        case .curvedArrow: drawCurvedArrow(in: rect, style: style, context: context)
        case .measure: drawMeasure(in: rect, style: style, context: context)
        case .magnifier: drawMagnifier(in: rect, style: style, context: context)
        }
    }

    /// 指针：修长现代矢量选择指针（内铺柔色 + 清晰圆角轮廓）。
    static func drawPointer(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 4.4, y: 2.6))
            path.addLine(to: CGPoint(x: 4.4, y: 15.8))
            path.addLine(to: CGPoint(x: 8.1, y: 12.4))
            path.addLine(to: CGPoint(x: 11.2, y: 17.5))
            path.addLine(to: CGPoint(x: 13.4, y: 16.3))
            path.addLine(to: CGPoint(x: 10.3, y: 11.3))
            path.addLine(to: CGPoint(x: 15.6, y: 11.1))
            path.closeSubpath()

            ctx.setFillColor(style.fillColor(opacity: 0.24))
            ctx.addPath(path)
            ctx.fillPath()

            ctx.setLineWidth(primaryStroke * 0.94)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    /// 矩形：黄金比例圆角框 + 双色柔铺内底。
    static func drawRectangle(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let box = CGRect(x: 2.6, y: 4.0, width: 14.8, height: 12.0)
            let path = CGPath(roundedRect: box, cornerWidth: 2.6, cornerHeight: 2.6, transform: nil)
            ctx.setFillColor(style.fillColor(opacity: 0.18))
            ctx.addPath(path)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    /// 椭圆：与矩形同等光学面积的优雅水平椭圆 + 双色柔铺内底。
    static func drawEllipse(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let box = CGRect(x: 2.4, y: 4.4, width: 15.2, height: 11.2)
            ctx.setFillColor(style.fillColor(opacity: 0.18))
            ctx.fillEllipse(in: box)
            ctx.strokeEllipse(in: box)
        }
    }

    /// 箭头：45° 矢量箭杆 + 饱满双色回勾箭簇（避免实心大黑三角压过邻近图标）。
    static func drawArrow(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            // 箭杆止于箭簇凹槽，杜绝穿帮。
            ctx.move(to: CGPoint(x: 3.4, y: 16.6))
            ctx.addLine(to: CGPoint(x: 12.8, y: 7.2))
            ctx.strokePath()

            let head = CGMutablePath()
            head.move(to: CGPoint(x: 16.8, y: 3.2))
            head.addLine(to: CGPoint(x: 9.2, y: 4.6))
            head.addLine(to: CGPoint(x: 12.6, y: 7.4))
            head.addLine(to: CGPoint(x: 15.4, y: 10.8))
            head.closeSubpath()

            ctx.setFillColor(style.fillColor(opacity: 0.30))
            ctx.addPath(head)
            ctx.fillPath()
            ctx.setLineWidth(primaryStroke * 0.92)
            ctx.addPath(head)
            ctx.strokePath()
        }
    }

    /// 自由画笔：倾斜 45° 精雕绘图笔 + 底部轻盈落笔弧线，一眼识别且不与手绘风混淆。
    static func drawFreehand(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            // 铅笔主体轮廓（右上到左下 45°）。
            let body = CGMutablePath()
            body.move(to: CGPoint(x: 13.6, y: 3.0))
            body.addLine(to: CGPoint(x: 17.0, y: 6.4))
            body.addLine(to: CGPoint(x: 7.6, y: 15.8))
            body.addLine(to: CGPoint(x: 3.4, y: 16.6))
            body.addLine(to: CGPoint(x: 4.2, y: 12.4))
            body.closeSubpath()

            ctx.setFillColor(style.fillColor(opacity: 0.22))
            ctx.addPath(body)
            ctx.fillPath()
            ctx.setLineWidth(primaryStroke * 0.92)
            ctx.addPath(body)
            ctx.strokePath()

            // 笔尾装饰环，强化画笔质感。
            ctx.setLineWidth(detailStroke)
            ctx.move(to: CGPoint(x: 11.6, y: 5.0))
            ctx.addLine(to: CGPoint(x: 15.0, y: 8.4))
            ctx.strokePath()

            // 右下角一抹优雅落笔轨迹。
            ctx.move(to: CGPoint(x: 11.4, y: 16.4))
            ctx.addQuadCurve(to: CGPoint(x: 17.0, y: 16.2), control: CGPoint(x: 14.2, y: 15.0))
            ctx.strokePath()
        }
    }

    /// 荧光笔：斜切宽头荧光马克笔 + 底部清晰高亮色带。
    static func drawHighlight(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            // 底部荧光色带（双色明显铺底，直观表达“划重点高亮”）。
            let strip = CGPath(
                roundedRect: CGRect(x: 2.6, y: 14.5, width: 14.8, height: 3.1),
                cornerWidth: 1.5,
                cornerHeight: 1.5,
                transform: nil
            )
            ctx.setFillColor(style.fillColor(opacity: 0.36))
            ctx.addPath(strip)
            ctx.fillPath()

            // 荧光笔斜握笔杆。
            let barrel = CGMutablePath()
            barrel.move(to: CGPoint(x: 12.2, y: 2.6))
            barrel.addLine(to: CGPoint(x: 16.2, y: 6.6))
            barrel.addLine(to: CGPoint(x: 9.8, y: 13.0))
            barrel.addLine(to: CGPoint(x: 5.8, y: 9.0))
            barrel.closeSubpath()

            ctx.setFillColor(style.fillColor(opacity: 0.22))
            ctx.addPath(barrel)
            ctx.fillPath()
            ctx.setLineWidth(primaryStroke * 0.92)
            ctx.addPath(barrel)
            ctx.strokePath()

            // 斜切宽头笔尖（贴近荧光色带起点）。
            let tip = CGMutablePath()
            tip.move(to: CGPoint(x: 5.8, y: 9.0))
            tip.addLine(to: CGPoint(x: 9.8, y: 13.0))
            tip.addLine(to: CGPoint(x: 6.8, y: 14.6))
            tip.addLine(to: CGPoint(x: 4.3, y: 12.1))
            tip.closeSubpath()

            ctx.setFillColor(style.fillColor(opacity: 0.45))
            ctx.addPath(tip)
            ctx.fillPath()
            ctx.addPath(tip)
            ctx.strokePath()
        }
    }

    /// 文字：精致几何化衬线「T」+ 细腻微背底，与左右几何图标光学体量一致。
    static func drawText(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            // 极淡柔和背衬卡（强化文本框语义，且光学面积对齐矩形）。
            let backing = CGPath(
                roundedRect: CGRect(x: 3.2, y: 3.2, width: 13.6, height: 13.6),
                cornerWidth: 3.0,
                cornerHeight: 3.0,
                transform: nil
            )
            ctx.setFillColor(style.fillColor(opacity: 0.14))
            ctx.addPath(backing)
            ctx.fillPath()

            ctx.setLineWidth(primaryStroke * 1.05)
            // 顶横与两侧优雅下垂衬脚。
            ctx.move(to: CGPoint(x: 5.2, y: 6.4))
            ctx.addLine(to: CGPoint(x: 5.2, y: 4.8))
            ctx.addLine(to: CGPoint(x: 14.8, y: 4.8))
            ctx.addLine(to: CGPoint(x: 14.8, y: 6.4))
            ctx.strokePath()

            // 主竖干。
            ctx.move(to: CGPoint(x: 10.0, y: 4.8))
            ctx.addLine(to: CGPoint(x: 10.0, y: 15.2))
            ctx.strokePath()

            // 底部衬脚。
            ctx.move(to: CGPoint(x: 7.4, y: 15.2))
            ctx.addLine(to: CGPoint(x: 12.6, y: 15.2))
            ctx.strokePath()
        }
    }

    /// 马赛克：3×3 圆角双阶棋盘格矩阵（实块 + 双色柔块交错，精致轻盈）。
    static func drawMosaic(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let start: CGFloat = 3.0
            let gap: CGFloat = 1.4
            let cell: CGFloat = (14.0 - gap * 2) / 3.0

            for row in 0 ..< 3 {
                for col in 0 ..< 3 {
                    let isStrong = (row + col).isMultiple(of: 2)
                    let tile = CGRect(
                        x: start + CGFloat(col) * (cell + gap),
                        y: start + CGFloat(row) * (cell + gap),
                        width: cell,
                        height: cell
                    )
                    let path = CGPath(roundedRect: tile, cornerWidth: 1.15, cornerHeight: 1.15, transform: nil)
                    ctx.setFillColor(style.fillColor(opacity: isStrong ? 0.94 : 0.26))
                    ctx.addPath(path)
                    ctx.fillPath()
                }
            }
        }
    }

    /// 编号：双色圆环徽章 + 居中精准光学「1」。
    static func drawNumbering(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let circle = CGRect(x: 2.8, y: 2.8, width: 14.4, height: 14.4)
            ctx.setFillColor(style.fillColor(opacity: 0.18))
            ctx.fillEllipse(in: circle)
            ctx.strokeEllipse(in: circle)
        }
        drawCenteredText(
            "1",
            pointSize: 9.8,
            weight: .bold,
            center: CGPoint(x: rect.midX - 0.15, y: rect.midY),
            style: style,
            context: context
        )
    }

    /// 聚光灯：简洁现代的「遮罩压暗 + 中心高亮聚焦圆窗 + 顶部微光晕」构图，避免小尺寸下像铃铛。
    static func drawSpotlight(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            // 外层柔和遮罩底框（圆角矩形挖去中心聚焦亮圆，直观传达「四周压暗、聚焦中心」）。
            let outerRect = CGRect(x: 2.6, y: 3.4, width: 14.8, height: 13.2)
            let outerPath = CGPath(roundedRect: outerRect, cornerWidth: 3.0, cornerHeight: 3.0, transform: nil)
            let holeRect = CGRect(x: 6.0, y: 6.0, width: 8.0, height: 8.0)
            let holePath = CGPath(ellipseIn: holeRect, transform: nil)

            let maskPath = CGMutablePath()
            maskPath.addPath(outerPath)
            maskPath.addPath(holePath)

            // 周边遮罩柔铺。
            ctx.setFillColor(style.fillColor(opacity: 0.30))
            ctx.addPath(maskPath)
            ctx.fillPath(using: .evenOdd)

            // 外框使用克制的次级淡描边，突出中心聚焦亮圈为主角。
            ctx.setStrokeColor(style.fillColor(opacity: 0.62))
            ctx.setLineWidth(detailStroke * 0.96)
            ctx.addPath(outerPath)
            ctx.strokePath()

            // 中心聚焦圆环使用完整主描边，形成极清晰的聚光视觉焦点。
            ctx.setStrokeColor(style.strokeColor)
            ctx.setLineWidth(primaryStroke * 0.98)
            ctx.strokeEllipse(in: holeRect)

            // 聚焦圆内左上方一抹极细玻璃高光弧，增强聚光通透感。
            ctx.setLineWidth(detailStroke * 0.80)
            ctx.setStrokeColor(style.fillColor(opacity: 0.70))
            ctx.addArc(
                center: CGPoint(x: 10.0, y: 10.0),
                radius: 2.1,
                startAngle: .pi * 1.08,
                endAngle: .pi * 1.48,
                clockwise: false
            )
            ctx.strokePath()
        }
    }

    /// 直线：45° 矢量线段 + 两端带双色描边锚点圆，与斜杠截然不同。
    static func drawLine(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let p1 = CGPoint(x: 4.5, y: 15.5)
            let p2 = CGPoint(x: 15.5, y: 4.5)
            let r: CGFloat = 2.0
            let offset = r / sqrt(2)

            ctx.move(to: CGPoint(x: p1.x + offset, y: p1.y - offset))
            ctx.addLine(to: CGPoint(x: p2.x - offset, y: p2.y + offset))
            ctx.strokePath()

            for pt in [p1, p2] {
                let dot = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                ctx.setFillColor(style.fillColor(opacity: 0.28))
                ctx.fillEllipse(in: dot)
                ctx.setLineWidth(detailStroke * 1.05)
                ctx.strokeEllipse(in: dot)
            }
        }
    }

    /// 曲线箭头：流畅拱形贝塞尔弧线 + 切向双色箭簇。
    static func drawCurvedArrow(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let start = CGPoint(x: 3.4, y: 16.4)
            let control = CGPoint(x: 3.8, y: 4.2)
            let end = CGPoint(x: 15.8, y: 6.2)

            ctx.move(to: start)
            ctx.addQuadCurve(to: CGPoint(x: 13.4, y: 5.8), control: control)
            ctx.strokePath()

            // 按终点切向绘制双色回勾箭簇。
            let tangent = CGPoint(x: end.x - control.x, y: end.y - control.y)
            let len = max(0.001, hypot(tangent.x, tangent.y))
            let ux = tangent.x / len
            let uy = tangent.y / len
            let nx = -uy
            let ny = ux

            let headLen: CGFloat = 5.2
            let wing: CGFloat = 2.9
            let neck = CGPoint(x: end.x - ux * (headLen * 0.72), y: end.y - uy * (headLen * 0.72))
            let base = CGPoint(x: end.x - ux * headLen, y: end.y - uy * headLen)

            let head = CGMutablePath()
            head.move(to: end)
            head.addLine(to: CGPoint(x: base.x + nx * wing, y: base.y + ny * wing))
            head.addLine(to: neck)
            head.addLine(to: CGPoint(x: base.x - nx * wing, y: base.y - ny * wing))
            head.closeSubpath()

            ctx.setFillColor(style.fillColor(opacity: 0.30))
            ctx.addPath(head)
            ctx.fillPath()
            ctx.setLineWidth(primaryStroke * 0.88)
            ctx.addPath(head)
            ctx.strokePath()
        }
    }

    /// 测量尺：45° 倾斜精雕双色直尺（圆角尺身 + 4 根长短错落精细刻度）。
    static func drawMeasure(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            ctx.translateBy(x: 10, y: 10)
            ctx.rotate(by: -.pi / 4)
            let ruler = CGRect(x: -8.0, y: -3.2, width: 16.0, height: 6.4)
            let path = CGPath(roundedRect: ruler, cornerWidth: 1.8, cornerHeight: 1.8, transform: nil)

            ctx.setFillColor(style.fillColor(opacity: 0.20))
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setLineWidth(primaryStroke * 0.90)
            ctx.addPath(path)
            ctx.strokePath()

            ctx.setLineWidth(detailStroke * 0.95)
            let ticks: [(CGFloat, CGFloat)] = [(-4.8, 2.2), (-1.6, 3.3), (1.6, 2.2), (4.8, 3.3)]
            for (x, h) in ticks {
                ctx.move(to: CGPoint(x: x, y: ruler.minY))
                ctx.addLine(to: CGPoint(x: x, y: ruler.minY + h))
            }
            ctx.strokePath()
        }
    }

    /// 放大镜：通透双色玻璃镜片 + 细腻加号焦心 + 圆润手柄。
    static func drawMagnifier(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let lens = CGRect(x: 2.8, y: 2.8, width: 11.0, height: 11.0)
            ctx.setFillColor(style.fillColor(opacity: 0.18))
            ctx.fillEllipse(in: lens)
            ctx.strokeEllipse(in: lens)

            // 镜片中央微加号，强调“放大”语义而非普通搜索。
            ctx.setLineWidth(detailStroke * 0.95)
            ctx.move(to: CGPoint(x: lens.midX - 2.3, y: lens.midY))
            ctx.addLine(to: CGPoint(x: lens.midX + 2.3, y: lens.midY))
            ctx.move(to: CGPoint(x: lens.midX, y: lens.midY - 2.3))
            ctx.addLine(to: CGPoint(x: lens.midX, y: lens.midY + 2.3))
            ctx.strokePath()

            // 45° 圆润手柄。
            ctx.setLineWidth(primaryStroke * 1.15)
            let r = lens.width / 2.0
            let d = r * sqrt(2) / 2.0
            ctx.move(to: CGPoint(x: lens.midX + d + 0.3, y: lens.midY + d + 0.3))
            ctx.addLine(to: CGPoint(x: 17.0, y: 17.0))
            ctx.strokePath()
        }
    }

    /// 更多工具：3 枚等距圆润微胶囊圆点 + 右下展开小三角（激活次高频工具时显示对应工具双色图标）。
    static func drawMoreTools(activeSecondaryTool: AnnotationTool?, in rect: CGRect, style: Style, context: CGContext) {
        if let activeSecondaryTool {
            drawTool(activeSecondaryTool, in: rect, style: style, context: context)
        } else {
            drawInGrid(rect: rect, style: style, in: context) { ctx in
                let xs: [CGFloat] = [4.6, 10.0, 15.4]
                for (i, x) in xs.enumerated() {
                    let r: CGFloat = 1.65
                    let dot = CGRect(x: x - r, y: 10.0 - r, width: r * 2, height: r * 2)
                    ctx.setFillColor(style.fillColor(opacity: i == 1 ? 0.95 : 0.72))
                    ctx.fillEllipse(in: dot)
                }
            }
        }
        // 右下角微三角展开角标。
        let corner = CGPoint(x: rect.maxX - 3.0, y: rect.maxY - 3.0)
        let tri = CGMutablePath()
        tri.move(to: corner)
        tri.addLine(to: CGPoint(x: corner.x - 3.4, y: corner.y))
        tri.addLine(to: CGPoint(x: corner.x, y: corner.y - 3.4))
        tri.closeSubpath()
        context.saveGState()
        context.setFillColor(style.fillColor(opacity: 0.68))
        context.addPath(tri)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: - 历史、扩展动作与输出退出（全部精雕双色线性统一光学体量）

    /// 撤销 / 重做：统一 1.55pt 流畅半圆弧回转箭头。
    static func drawHistory(isUndo: Bool, in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            if !isUndo {
                ctx.translateBy(x: 20, y: 0)
                ctx.scaleBy(x: -1, y: 1)
            }
            // 上横线 + 右侧圆润 U 型折返弧。
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 4.2, y: 7.4))
            path.addLine(to: CGPoint(x: 12.2, y: 7.4))
            path.addArc(
                center: CGPoint(x: 12.2, y: 11.4),
                radius: 4.0,
                startAngle: -.pi / 2,
                endAngle: .pi / 2,
                clockwise: false
            )
            path.addLine(to: CGPoint(x: 8.6, y: 15.4))
            ctx.addPath(path)
            ctx.strokePath()

            // 左侧圆润折角箭翼。
            ctx.move(to: CGPoint(x: 7.4, y: 4.2))
            ctx.addLine(to: CGPoint(x: 3.8, y: 7.4))
            ctx.addLine(to: CGPoint(x: 7.4, y: 10.6))
            ctx.strokePath()
        }
    }

    /// 录屏：精雕双色圆角摄像机（轻盈透亮，告别沉重实心黑块）+ 录制圆点。
    static func drawRecord(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let body = CGPath(
                roundedRect: CGRect(x: 2.4, y: 5.0, width: 10.4, height: 10.0),
                cornerWidth: 2.4,
                cornerHeight: 2.4,
                transform: nil
            )
            ctx.setFillColor(style.fillColor(opacity: 0.20))
            ctx.addPath(body)
            ctx.fillPath()
            ctx.setLineWidth(primaryStroke * 0.94)
            ctx.addPath(body)
            ctx.strokePath()

            // 右侧梯形圆角镜头。
            let lens = CGMutablePath()
            lens.move(to: CGPoint(x: 12.8, y: 8.2))
            lens.addLine(to: CGPoint(x: 17.2, y: 5.8))
            lens.addLine(to: CGPoint(x: 17.2, y: 14.2))
            lens.addLine(to: CGPoint(x: 12.8, y: 11.8))
            lens.closeSubpath()
            ctx.setFillColor(style.fillColor(opacity: 0.28))
            ctx.addPath(lens)
            ctx.fillPath()
            ctx.addPath(lens)
            ctx.strokePath()

            // 机身内精致录制提示点。
            ctx.setFillColor(style.strokeColor)
            ctx.fillEllipse(in: CGRect(x: 5.6, y: 8.4, width: 2.6, height: 2.6))
        }
    }

    /// 长截图：双色长画卷（两侧竖轨 + 双段向下滚动尖头 `⌄`，与「保存」彻底拉开视觉区隔）。
    static func drawScrollshot(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            // 柔和竖向长画卷衬底。
            let strip = CGPath(
                roundedRect: CGRect(x: 4.8, y: 2.6, width: 10.4, height: 14.8),
                cornerWidth: 2.4,
                cornerHeight: 2.4,
                transform: nil
            )
            ctx.setFillColor(style.fillColor(opacity: 0.16))
            ctx.addPath(strip)
            ctx.fillPath()

            // 左右上下微开口竖边，传达「画卷无限纵向延展」。
            ctx.setLineWidth(primaryStroke * 0.94)
            for isLeft in [true, false] {
                let side: CGFloat = isLeft ? 4.4 : 15.6
                let dir: CGFloat = isLeft ? 1 : -1
                let edge = CGMutablePath()
                edge.move(to: CGPoint(x: side + dir * 2.4, y: 2.8))
                edge.addQuadCurve(to: CGPoint(x: side, y: 5.2), control: CGPoint(x: side, y: 2.8))
                edge.addLine(to: CGPoint(x: side, y: 14.8))
                edge.addQuadCurve(to: CGPoint(x: side + dir * 2.4, y: 17.2), control: CGPoint(x: side, y: 17.2))
                ctx.addPath(edge)
                ctx.strokePath()
            }

            // 中央双层向下滚动人字箭（滚动感极强，且与保存的单箭头+托盘完全不同）。
            ctx.setLineWidth(primaryStroke * 0.90)
            for yOffset in [7.2, 11.4] as [CGFloat] {
                ctx.move(to: CGPoint(x: 7.4, y: yOffset))
                ctx.addLine(to: CGPoint(x: 10.0, y: yOffset + 2.6))
                ctx.addLine(to: CGPoint(x: 12.6, y: yOffset))
            }
            ctx.strokePath()
        }
    }

    /// OCR 文字识别：四角圆润取景框 + 扫描柔光底 + 3 条递减文字行。
    static func drawRecognizeText(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let inner = CGPath(
                roundedRect: CGRect(x: 4.8, y: 4.8, width: 10.4, height: 10.4),
                cornerWidth: 2.0,
                cornerHeight: 2.0,
                transform: nil
            )
            ctx.setFillColor(style.fillColor(opacity: 0.16))
            ctx.addPath(inner)
            ctx.fillPath()

            ctx.setLineWidth(primaryStroke * 0.94)
            let corners: [(CGPoint, CGPoint, CGPoint)] = [
                (CGPoint(x: 2.8, y: 6.4), CGPoint(x: 2.8, y: 2.8), CGPoint(x: 6.4, y: 2.8)),
                (CGPoint(x: 13.6, y: 2.8), CGPoint(x: 17.2, y: 2.8), CGPoint(x: 17.2, y: 6.4)),
                (CGPoint(x: 2.8, y: 13.6), CGPoint(x: 2.8, y: 17.2), CGPoint(x: 6.4, y: 17.2)),
                (CGPoint(x: 13.6, y: 17.2), CGPoint(x: 17.2, y: 17.2), CGPoint(x: 17.2, y: 13.6)),
            ]
            for (a, b, c) in corners {
                ctx.move(to: a)
                ctx.addQuadCurve(to: c, control: b)
                ctx.strokePath()
            }

            ctx.setLineWidth(detailStroke * 1.08)
            let lines: [(CGFloat, CGFloat)] = [(7.0, 13.8), (10.0, 12.6), (13.0, 10.4)]
            for (y, right) in lines {
                ctx.move(to: CGPoint(x: 6.2, y: y))
                ctx.addLine(to: CGPoint(x: right, y: y))
            }
            ctx.strokePath()
        }
    }

    /// 固定贴图：45° 斜插精雕双色图钉（钉帽+钉身双色铺底，45° 构图稳重精致）。
    static func drawPin(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            ctx.translateBy(x: 10, y: 10)
            ctx.rotate(by: .pi / 4)

            // 钉帽 + 钉身一体柔和路径。
            let body = CGMutablePath()
            body.move(to: CGPoint(x: -3.2, y: -6.8))
            body.addLine(to: CGPoint(x: 3.2, y: -6.8))
            body.addLine(to: CGPoint(x: 2.4, y: -1.4))
            body.addLine(to: CGPoint(x: 4.8, y: 1.4))
            body.addLine(to: CGPoint(x: -4.8, y: 1.4))
            body.addLine(to: CGPoint(x: -2.4, y: -1.4))
            body.closeSubpath()

            ctx.setFillColor(style.fillColor(opacity: 0.24))
            ctx.addPath(body)
            ctx.fillPath()
            ctx.setLineWidth(primaryStroke * 0.90)
            ctx.addPath(body)
            ctx.strokePath()

            // 针尖。
            ctx.move(to: CGPoint(x: 0, y: 1.6))
            ctx.addLine(to: CGPoint(x: 0, y: 7.4))
            ctx.strokePath()
        }
    }

    /// 复制：前后错落双层圆角文档卡片（前卡带柔底与精致双细纹）。
    static func drawCopy(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            // 后方叠卡（仅露左上 L 轮廓，防线条重叠）。
            let back = CGMutablePath()
            back.move(to: CGPoint(x: 6.2, y: 14.2))
            back.addLine(to: CGPoint(x: 4.6, y: 14.2))
            back.addQuadCurve(to: CGPoint(x: 3.0, y: 12.6), control: CGPoint(x: 3.0, y: 14.2))
            back.addLine(to: CGPoint(x: 3.0, y: 4.4))
            back.addQuadCurve(to: CGPoint(x: 4.6, y: 2.8), control: CGPoint(x: 3.0, y: 2.8))
            back.addLine(to: CGPoint(x: 11.4, y: 2.8))
            back.addQuadCurve(to: CGPoint(x: 13.0, y: 4.4), control: CGPoint(x: 13.0, y: 2.8))
            back.addLine(to: CGPoint(x: 13.0, y: 5.8))
            ctx.setLineWidth(primaryStroke * 0.92)
            ctx.addPath(back)
            ctx.strokePath()

            // 前方主卡。
            let frontRect = CGRect(x: 6.8, y: 6.2, width: 10.2, height: 11.0)
            let front = CGPath(roundedRect: frontRect, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil)
            ctx.setFillColor(style.fillColor(opacity: 0.22))
            ctx.addPath(front)
            ctx.fillPath()
            ctx.addPath(front)
            ctx.strokePath()

            // 主卡内两条精致微横线。
            ctx.setLineWidth(detailStroke * 0.90)
            ctx.move(to: CGPoint(x: 9.4, y: 10.4))
            ctx.addLine(to: CGPoint(x: 14.4, y: 10.4))
            ctx.move(to: CGPoint(x: 9.4, y: 13.2))
            ctx.addLine(to: CGPoint(x: 13.0, y: 13.2))
            ctx.strokePath()
        }
    }

    /// 保存：双色圆角入盘托槽 + 居中向下入盘箭头。
    static func drawSave(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            // 托盘底部微柔光槽。
            let trayFill = CGPath(
                roundedRect: CGRect(x: 3.0, y: 12.2, width: 14.0, height: 4.8),
                cornerWidth: 2.0,
                cornerHeight: 2.0,
                transform: nil
            )
            ctx.setFillColor(style.fillColor(opacity: 0.20))
            ctx.addPath(trayFill)
            ctx.fillPath()

            // 托盘外廓（上开口 U 形托盘）。
            let tray = CGMutablePath()
            tray.move(to: CGPoint(x: 3.0, y: 12.0))
            tray.addLine(to: CGPoint(x: 3.0, y: 14.8))
            tray.addQuadCurve(to: CGPoint(x: 5.2, y: 17.0), control: CGPoint(x: 3.0, y: 17.0))
            tray.addLine(to: CGPoint(x: 14.8, y: 17.0))
            tray.addQuadCurve(to: CGPoint(x: 17.0, y: 14.8), control: CGPoint(x: 17.0, y: 17.0))
            tray.addLine(to: CGPoint(x: 17.0, y: 12.0))
            ctx.setLineWidth(primaryStroke * 0.94)
            ctx.addPath(tray)
            ctx.strokePath()

            // 居中向下入盘箭头。
            ctx.move(to: CGPoint(x: 10.0, y: 3.0))
            ctx.addLine(to: CGPoint(x: 10.0, y: 12.6))
            ctx.strokePath()
            ctx.move(to: CGPoint(x: 6.4, y: 9.2))
            ctx.addLine(to: CGPoint(x: 10.0, y: 12.8))
            ctx.addLine(to: CGPoint(x: 13.6, y: 9.2))
            ctx.strokePath()
        }
    }

    /// 取消 / 关闭：圆头对称交叉 `×`。
    static func drawCancel(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            ctx.setLineWidth(primaryStroke * 1.02)
            ctx.move(to: CGPoint(x: 5.2, y: 5.2))
            ctx.addLine(to: CGPoint(x: 14.8, y: 14.8))
            ctx.move(to: CGPoint(x: 14.8, y: 5.2))
            ctx.addLine(to: CGPoint(x: 5.2, y: 14.8))
            ctx.strokePath()
        }
    }

    /// 删除选中：双色圆角垃圾桶（顶盖提手 + 桶身柔底 + 两条细腻竖纹）。
    static func drawDelete(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            // 桶身（微收腰梯形圆底）。
            let bin = CGMutablePath()
            bin.move(to: CGPoint(x: 5.0, y: 6.2))
            bin.addLine(to: CGPoint(x: 5.8, y: 15.6))
            bin.addQuadCurve(to: CGPoint(x: 7.4, y: 17.0), control: CGPoint(x: 5.9, y: 17.0))
            bin.addLine(to: CGPoint(x: 12.6, y: 17.0))
            bin.addQuadCurve(to: CGPoint(x: 14.2, y: 15.6), control: CGPoint(x: 14.1, y: 17.0))
            bin.addLine(to: CGPoint(x: 15.0, y: 6.2))
            bin.closeSubpath()

            ctx.setFillColor(style.fillColor(opacity: 0.20))
            ctx.addPath(bin)
            ctx.fillPath()
            ctx.setLineWidth(primaryStroke * 0.90)
            ctx.addPath(bin)
            ctx.strokePath()

            // 顶盖横梁与提手。
            ctx.move(to: CGPoint(x: 3.4, y: 6.2))
            ctx.addLine(to: CGPoint(x: 16.6, y: 6.2))
            ctx.move(to: CGPoint(x: 7.6, y: 6.2))
            ctx.addLine(to: CGPoint(x: 8.2, y: 3.4))
            ctx.addLine(to: CGPoint(x: 11.8, y: 3.4))
            ctx.addLine(to: CGPoint(x: 12.4, y: 6.2))
            ctx.strokePath()

            // 桶内双细纹。
            ctx.setLineWidth(detailStroke * 0.92)
            ctx.move(to: CGPoint(x: 8.4, y: 9.2))
            ctx.addLine(to: CGPoint(x: 8.7, y: 14.2))
            ctx.move(to: CGPoint(x: 11.6, y: 9.2))
            ctx.addLine(to: CGPoint(x: 11.3, y: 14.2))
            ctx.strokePath()
        }
    }

    // MARK: - 二级属性面板专属图标

    /// 填充模式开关：圆角方框（未填充为轻薄描边+极淡内衬，已填充为饱满实心柔光内块）。
    static func drawFillToggle(isFilled: Bool, in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let outer = CGRect(x: 3.0, y: 3.0, width: 14.0, height: 14.0)
            let outerPath = CGPath(roundedRect: outer, cornerWidth: 3.0, cornerHeight: 3.0, transform: nil)
            if isFilled {
                ctx.setFillColor(style.fillColor(opacity: 0.72))
                ctx.addPath(outerPath)
                ctx.fillPath()
            } else {
                // 未填充状态：中心画一条柔和斜向虚感分割或留白，一眼区分“仅描边”。
                ctx.setFillColor(style.fillColor(opacity: 0.14))
                ctx.addPath(outerPath)
                ctx.fillPath()
            }
            ctx.setLineWidth(primaryStroke * 0.92)
            ctx.addPath(outerPath)
            ctx.strokePath()
        }
    }

    /// 手绘风格开关（Sketchy）：灵动有机自由波浪线 + 右上角一点创意星芒，与铅笔画笔截然不同。
    static func drawSketchyToggle(in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            let wave = CGMutablePath()
            wave.move(to: CGPoint(x: 3.0, y: 14.6))
            wave.addCurve(
                to: CGPoint(x: 10.0, y: 10.0),
                control1: CGPoint(x: 4.8, y: 5.8),
                control2: CGPoint(x: 7.4, y: 14.2)
            )
            wave.addCurve(
                to: CGPoint(x: 16.8, y: 7.4),
                control1: CGPoint(x: 12.6, y: 5.8),
                control2: CGPoint(x: 14.8, y: 13.8)
            )
            ctx.setLineWidth(primaryStroke * 0.96)
            ctx.addPath(wave)
            ctx.strokePath()

            // 右上角极简四芒微星，点明“手绘风滤镜/风格”。
            ctx.setFillColor(style.fillColor(opacity: 0.80))
            ctx.fillEllipse(in: CGRect(x: 14.8, y: 2.8, width: 2.4, height: 2.4))
        }
    }

    /// 粗体 `B` / 斜体 `I`：光学等重矢量字形，彻底避免系统无衬线斜体 `I` 退化为斜杠。
    static func drawTypographicToggle(isItalic: Bool, in rect: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: rect, style: style, in: context) { ctx in
            if !isItalic {
                // 精致几何粗体 B。
                ctx.setLineWidth(primaryStroke * 1.15)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 5.6, y: 3.8))
                path.addLine(to: CGPoint(x: 5.6, y: 16.2))
                path.move(to: CGPoint(x: 5.6, y: 3.8))
                path.addLine(to: CGPoint(x: 10.6, y: 3.8))
                path.addCurve(
                    to: CGPoint(x: 10.6, y: 9.8),
                    control1: CGPoint(x: 14.2, y: 3.8),
                    control2: CGPoint(x: 14.2, y: 9.8)
                )
                path.addLine(to: CGPoint(x: 5.6, y: 9.8))
                path.move(to: CGPoint(x: 10.8, y: 9.8))
                path.addCurve(
                    to: CGPoint(x: 11.2, y: 16.2),
                    control1: CGPoint(x: 15.2, y: 9.8),
                    control2: CGPoint(x: 15.2, y: 16.2)
                )
                path.addLine(to: CGPoint(x: 5.6, y: 16.2))
                ctx.addPath(path)
                ctx.strokePath()
            } else {
                // 经典衬线斜体 I（上下清晰横衬脚 + 14° 优雅斜干）。
                ctx.setLineWidth(primaryStroke * 0.96)
                ctx.move(to: CGPoint(x: 8.6, y: 4.0))
                ctx.addLine(to: CGPoint(x: 14.4, y: 4.0))
                ctx.move(to: CGPoint(x: 5.6, y: 16.0))
                ctx.addLine(to: CGPoint(x: 11.4, y: 16.0))
                ctx.move(to: CGPoint(x: 11.5, y: 4.0))
                ctx.addLine(to: CGPoint(x: 8.5, y: 16.0))
                ctx.strokePath()
            }
        }
    }

    // MARK: - 滑块左侧标识图形

    /// 线宽滑块图标：由细到粗三条精致圆润胶囊线，间距呼吸克制。
    static func drawLineWidthSliderGlyph(in box: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: box, boxSize: box.width, style: style, in: context) { ctx in
            let specs: [(y: CGFloat, w: CGFloat, opacity: CGFloat)] = [
                (4.6, 1.35, 0.72),
                (10.0, 2.35, 0.88),
                (15.6, 3.40, 1.00),
            ]
            for spec in specs {
                ctx.setStrokeColor(style.fillColor(opacity: spec.opacity))
                ctx.setLineWidth(spec.w)
                ctx.move(to: CGPoint(x: 3.0, y: spec.y))
                ctx.addLine(to: CGPoint(x: 17.0, y: spec.y))
                ctx.strokePath()
            }
        }
    }

    /// 箭头倍率滑块图标：水平饱满双色回勾箭簇 + 极短杆。
    static func drawArrowHeadSliderGlyph(in box: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: box, boxSize: box.width, style: style, in: context) { ctx in
            ctx.setLineWidth(primaryStroke * 0.92)
            ctx.move(to: CGPoint(x: 2.6, y: 10.0))
            ctx.addLine(to: CGPoint(x: 9.2, y: 10.0))
            ctx.strokePath()

            let head = CGMutablePath()
            head.move(to: CGPoint(x: 17.6, y: 10.0))
            head.addLine(to: CGPoint(x: 8.2, y: 4.4))
            head.addLine(to: CGPoint(x: 10.0, y: 10.0))
            head.addLine(to: CGPoint(x: 8.2, y: 15.6))
            head.closeSubpath()

            ctx.setFillColor(style.fillColor(opacity: 0.30))
            ctx.addPath(head)
            ctx.fillPath()
            ctx.addPath(head)
            ctx.strokePath()
        }
    }

    /// 笔刷直径滑块图标：双色柔光圆环 + 中心微点。
    static func drawMosaicBrushSliderGlyph(in box: CGRect, style: Style, context: CGContext) {
        drawInGrid(rect: box, boxSize: box.width, style: style, in: context) { ctx in
            let ring = CGRect(x: 3.2, y: 3.2, width: 13.6, height: 13.6)
            ctx.setFillColor(style.fillColor(opacity: 0.22))
            ctx.fillEllipse(in: ring)
            ctx.setLineWidth(primaryStroke * 0.92)
            ctx.strokeEllipse(in: ring)
            ctx.setFillColor(style.strokeColor)
            ctx.fillEllipse(in: CGRect(x: 8.8, y: 8.8, width: 2.4, height: 2.4))
        }
    }

    // MARK: - 文字辅助

    private static func drawCenteredText(
        _ text: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        center: CGPoint,
        style: Style,
        context: CGContext
    ) {
        let ctFont = NSFont.systemFont(ofSize: pointSize, weight: weight) as CTFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ctFont,
            .foregroundColor: style.ink(1.0),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let capHeight = CTFontGetCapHeight(ctFont)

        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: center.x - width / 2.0, y: center.y + capHeight / 2.0)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
