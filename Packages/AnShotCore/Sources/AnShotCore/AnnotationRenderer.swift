//
//  AnnotationRenderer.swift
//  AnShotCore
//
//  合成渲染管线。
//
//  契约见 docs/m1-capture/model.md §7：
//  1. 按 selection 裁剪 backdrop → canvas；
//  2. 依 annotations 数组顺序逐个应用（数组索引即 z 序）；
//  3. 马赛克读取 **canvas 的当前像素** 而非原始 backdrop，
//     因此先画的箭头会被后加的马赛克真实覆盖；
//  4. 输出 CGImage，尺寸等于 selection.size。
//
//  覆盖层上的显示渲染与导出时的合成渲染必须调用本文件中的同一实现，
//  差异仅在于目标 CGContext，否则必然出现「屏幕上与导出图不一致」的缺陷。
//

import Accelerate
import CoreGraphics
import CoreText
import Foundation

/// 标注合成渲染器。
public enum AnnotationRenderer {
    /// 渲染管线回退色彩空间（sRGB）。
    private static let fallbackColorSpace = ImageColorSpace.sRGB

    // MARK: - 对外接口

    /// 按选区裁剪底图，并按顺序应用标注，返回合成结果。
    ///
    /// - Parameters:
    ///   - backdrop: 原始底图（冻结帧），坐标为像素。
    ///   - selection: 选区（底图像素坐标，原点左上），会被取整到整数像素。
    ///   - annotations: 标注序列，数组索引即 z 序（索引小者在底层）。
    /// - Returns: 尺寸等于选区像素尺寸的图像；参数非法时返回 `nil`。
    public static func render(
        backdrop: CGImage,
        selection: PixelRect,
        annotations: [Annotation]
    ) -> CGImage? {
        guard let canvas = makeCanvas(backdrop: backdrop, selection: selection) else {
            return nil
        }

        drawBackdrop(backdrop, in: canvas.context, canvas: canvas)
        applyAnnotations(
            annotations,
            in: canvas.context,
            canvasOrigin: canvas.origin,
            canvasWidth: canvas.width,
            canvasHeight: canvas.height
        )

        return canvas.context.makeImage()
    }

    /// 在已建立画布坐标系的上下文中，按顺序应用全部标注。
    ///
    /// **仅供 `render` 内部使用，不得对外暴露。**
    ///
    /// 标注应用必须发生在**位图上下文**上：马赛克要直接读写 `context.data`
    /// 来取得已知的 BGRA 存储，而 AppKit 的屏幕上下文不提供这个前提。
    /// 显示侧因此改为调用 `render` 取回一幅原位图、再绘制到视图上
    /// （见 `model.md` §7.2），而不是在自己的上下文里直接画标注。
    ///
    /// - Parameters:
    ///   - annotations: 标注序列，数组索引即 z 序（索引小者在底层）
    ///   - context: 位图上下文，应处于 CoreGraphics 默认状态（原点左下、无变换）
    ///   - canvasOrigin: 画布左上角在底图坐标系中的位置（马赛克寻址需要）
    ///   - canvasWidth: 画布像素宽
    ///   - canvasHeight: 画布像素高（同时决定 y 翻转量）
    private static func applyAnnotations(
        _ annotations: [Annotation],
        in context: CGContext,
        canvasOrigin: PixelPoint,
        canvasWidth: Int,
        canvasHeight: Int
    ) {
        guard !annotations.isEmpty, canvasWidth > 0, canvasHeight > 0 else {
            return
        }

        context.saveGState()
        defer { context.restoreGState() }

        applyCanvasCoordinateSystem(
            to: context,
            canvasOrigin: canvasOrigin,
            canvasHeight: canvasHeight
        )

        for annotation in annotations {
            apply(
                annotation,
                in: context,
                canvasOrigin: canvasOrigin,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight
            )
        }
    }

    /// 只裁剪、不应用标注。
    ///
    /// 供需要「原始选区图像」的场景使用（例如 P4 的坐标校验诊断）；
    /// 与 `render(_:_:[])` 的差别仅在于省去一次上下文翻转。
    public static func crop(backdrop: CGImage, selection: PixelRect) -> CGImage? {
        guard let canvas = makeCanvas(backdrop: backdrop, selection: selection) else {
            return nil
        }

        drawBackdrop(backdrop, in: canvas.context, canvas: canvas)
        return canvas.context.makeImage()
    }

    // MARK: - 画布准备

    /// 建立目标位图上下文。
    ///
    /// 采用 BGRA（little-endian 下的 premultipliedFirst），
    /// 这是 macOS 的原生布局，能避免一次通道重排。
    /// 已经对齐到整数像素、并夹进底图范围的画布。
    private struct Canvas {
        let context: CGContext
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        /// 画布左上角在底图坐标系中的位置（马赛克寻址需要）。
        var origin: PixelPoint {
            PixelPoint(x: Double(x), y: Double(y))
        }
    }

    /// 把 `Double` 选区对齐到整数像素，并夹到底图范围内。
    ///
    /// 规则来自 `model.md` §8：`x0 = floor(origin.x)`、`y0 = floor(origin.y)`、
    /// `x1 = ceil(origin.x + width)`、`y1 = ceil(origin.y + height)`。
    ///
    /// **必须向外取整**，两个理由：
    /// 1. 保证结果**完整覆盖**用户选中的区域，不会少带一行/一列像素；
    /// 2. 对齐之后底图是整数像素搬运——若保留小数偏移，
    ///    `CGContext.draw` 会对整幅图做重采样，把截图糊掉。
    ///    此前画布尺寸用 `rounded()`、绘制却按原始小数 `origin` 平移，
    ///    正是这个缺陷。
    private static func alignedRect(
        _ selection: PixelRect,
        backdropWidth: Int,
        backdropHeight: Int
    ) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard backdropWidth > 0, backdropHeight > 0, selection.isNonEmpty else {
            return nil
        }

        // 选区越界属于不变量违规（调用方应先 validate）；这里夹住而不是崩。
        // 引入 1e-6 浮点容差，避免逻辑点乘以缩放系数后的 IEEE 754 尾数毛刺多吃进 1px 桌面杂边。
        let epsilon = 1e-6
        let x0 = min(max(0, Int((selection.origin.x + epsilon).rounded(.down))), backdropWidth)
        let y0 = min(max(0, Int((selection.origin.y + epsilon).rounded(.down))), backdropHeight)
        let x1 = min(max(0, Int((selection.origin.x + selection.size.width - epsilon).rounded(.up))), backdropWidth)
        let y1 = min(max(0, Int((selection.origin.y + selection.size.height - epsilon).rounded(.up))), backdropHeight)

        let width = x1 - x0
        let height = y1 - y0
        guard width > 0, height > 0 else {
            return nil
        }

        return (x0, y0, width, height)
    }

    private static func makeCanvas(
        backdrop: CGImage,
        selection: PixelRect
    ) -> Canvas? {
        guard let rect = alignedRect(
            selection,
            backdropWidth: backdrop.width,
            backdropHeight: backdrop.height
        ) else {
            return nil
        }

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        // 优先保留输入底图原生 RGB 输出广色域（如 Display P3 / sRGB）；
        // 若底图色域不支持 8-bit 预乘位图创建，再安全回退至 sRGB。
        let preferredSpace = ImageColorSpace.canvasColorSpace(for: backdrop)
        let context = CGContext(
            data: nil,
            width: rect.width,
            height: rect.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: preferredSpace,
            bitmapInfo: bitmapInfo
        ) ?? (preferredSpace !== fallbackColorSpace ? CGContext(
            data: nil,
            width: rect.width,
            height: rect.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: fallbackColorSpace,
            bitmapInfo: bitmapInfo
        ) : nil)

        guard let context else {
            return nil
        }

        // 不插值：截图内容按 1:1 像素搬运，任何重采样都会引入模糊。
        context.interpolationQuality = .none
        context.setAllowsAntialiasing(true)

        return Canvas(
            context: context,
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height
        )
    }

    /// 把底图画进上下文。
    ///
    /// 上下文此时仍是默认的左下原点坐标系，因此需要把「画布左上原点」
    /// 换算成左下原点下的绘制矩形。偏移量取**对齐后的整数** origin，
    /// 这样底图是整数像素落位、不触发重采样。
    private static func drawBackdrop(
        _ backdrop: CGImage,
        in context: CGContext,
        canvas: Canvas
    ) {
        let drawRect = CGRect(
            x: -Double(canvas.x),
            y: Double(canvas.height) - Double(backdrop.height) + Double(canvas.y),
            width: Double(backdrop.width),
            height: Double(backdrop.height)
        )

        // 先清成不透明黑，避免选区超出底图（理论上被不变量禁止）时出现未初始化像素。
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.draw(backdrop, in: drawRect)
    }

    /// 把上下文切到「画布坐标」：原点为画布左上角、y 轴向下。
    ///
    /// 需要两步变换：
    /// 1. 翻转 y 轴，使原点从画布左下角移到左上角；
    /// 2. 平移 `-selection.origin`，把**底图坐标**换算成画布坐标。
    ///
    /// 第 2 步不可省：契约规定标注几何一律是底图像素坐标（model.md §8 不变量 2），
    /// 而渲染的初始画布是裁剪后的子图，两者相差一个 `selection.origin`。
    /// 漏掉它会让标注整体偏移到画布之外（被裁剪掉的区域）。
    /// 把上下文变换到「画布坐标 = 底图坐标 − canvasOrigin」的左上原点坐标系。
    private static func applyCanvasCoordinateSystem(
        to context: CGContext,
        canvasOrigin: PixelPoint,
        canvasHeight: Int
    ) {
        context.translateBy(x: 0, y: CGFloat(canvasHeight))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -canvasOrigin.x, y: -canvasOrigin.y)
    }

    // MARK: - 标注分派

    private static func apply(
        _ annotation: Annotation,
        in context: CGContext,
        canvasOrigin: PixelPoint,
        canvasWidth: Int,
        canvasHeight: Int
    ) {
        switch annotation.kind {
        case let .rectangle(rect, stroke, fill, cornerRadius):
            drawRectangle(
                rect,
                stroke: stroke,
                fill: fill,
                cornerRadius: cornerRadius,
                id: annotation.id,
                in: context
            )

        case let .ellipse(rect, stroke, fill):
            drawEllipse(
                rect,
                stroke: stroke,
                fill: fill,
                id: annotation.id,
                in: context
            )

        case let .line(start, end, stroke):
            drawLine(start, end, stroke: stroke, id: annotation.id, in: context)

        case let .arrow(start, end, stroke, headLength, headWidth):
            drawArrow(
                start: start,
                end: end,
                stroke: stroke,
                headLength: headLength,
                headWidth: headWidth,
                id: annotation.id,
                in: context
            )

        case let .text(origin, text, font, color, background, maxWidth):
            drawText(
                origin: origin,
                text: text,
                font: font,
                color: color,
                background: background,
                maxWidth: maxWidth,
                in: context
            )

        case let .mosaic(rect, mode, intensity):
            applyMosaic(
                coverage: .rect(rect),
                mode: mode,
                intensity: intensity,
                in: context,
                canvasOrigin: canvasOrigin,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight
            )

        case let .numbering(center, radius, index, stroke, fill, textColor):
            drawNumbering(
                center: center,
                radius: radius,
                index: index,
                stroke: stroke,
                fill: fill,
                textColor: textColor,
                in: context
            )

        case let .highlight(rect, color):
            drawHighlight(rect, color: color, in: context)

        case let .measure(start, end, stroke):
            drawMeasure(
                start: start,
                end: end,
                stroke: stroke,
                canvasOrigin: canvasOrigin,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                in: context
            )

        case let .magnifier(center, radius, zoom, border):
            drawMagnifier(
                center: center,
                radius: radius,
                zoom: zoom,
                border: border,
                canvasOrigin: canvasOrigin,
                in: context
            )

        case let .freehand(points, stroke):
            drawFreehand(points, stroke: stroke, id: annotation.id, in: context)

        case let .curvedArrow(start, control, end, stroke, headLength, headWidth):
            drawCurvedArrow(
                start: start,
                control: control,
                end: end,
                stroke: stroke,
                headLength: headLength,
                headWidth: headWidth,
                id: annotation.id,
                in: context
            )

        case let .mosaicStroke(points, radius, mode, intensity):
            applyMosaic(
                coverage: .stroke(points: points, radius: radius),
                mode: mode,
                intensity: intensity,
                in: context,
                canvasOrigin: canvasOrigin,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight
            )
        }
    }

    // MARK: - 矢量标注

    /// 绘制椭圆标注辅助方法（预留供集成阶段接入 `Kind.ellipse` 复用）。
    ///
    /// - Parameters:
    ///   - rect: 椭圆外接矩形（底图像素坐标）
    ///   - stroke: 描边样式，支持 `isSketchy` 手绘双描边
    ///   - fill: 可选填充颜色
    ///   - id: 用于手绘微扰的确定性种子；缺省时采用固定常量种子
    ///   - context: 目标渲染上下文
    public static func drawEllipse(
        _ rect: PixelRect,
        stroke: StrokeStyle,
        fill: RGBAColor?,
        id: UUID? = nil,
        in context: CGContext
    ) {
        let cgRect = rect.cgRect
        guard cgRect.width > 0, cgRect.height > 0 else {
            return
        }

        let path = CGPath(ellipseIn: cgRect, transform: nil)
        context.saveGState()
        defer { context.restoreGState() }

        if let fill {
            context.addPath(path)
            context.setFillColor(fill.cgColor)
            context.fillPath()
        }

        if stroke.isSketchy {
            var rng = SketchyRandom(seedID: id)
            let cx = Double(cgRect.midX)
            let cy = Double(cgRect.midY)
            let rx = Double(cgRect.width / 2)
            let ry = Double(cgRect.height / 2)
            let amplitude = sketchyAmplitude(for: stroke, span: min(rx, ry) * 2)
            let segments = 28

            for pass in 0 ..< 2 {
                let passPath = CGMutablePath()
                let angleOffset = rng.nextUnit() * 0.12
                for step in 0 ... segments {
                    let angle = angleOffset + (Double(step) / Double(segments)) * (.pi * 2)
                    let radialJitter = 1.0 + (rng.nextUnit() * amplitude) / max(8.0, min(rx, ry))
                    let pt = CGPoint(
                        x: cx + rx * radialJitter * Foundation.cos(angle),
                        y: cy + ry * radialJitter * Foundation.sin(angle)
                    )
                    if step == 0 {
                        passPath.move(to: pt)
                    } else {
                        passPath.addLine(to: pt)
                    }
                }
                strokeSketchyPass(passPath, stroke: stroke, pass: pass, in: context)
            }
            return
        }

        context.addPath(path)
        configureStroke(stroke, in: context)
        context.strokePath()
    }

    private static func drawRectangle(
        _ rect: PixelRect,
        stroke: StrokeStyle,
        fill: RGBAColor?,
        cornerRadius: Double,
        id: UUID,
        in context: CGContext
    ) {
        let cgRect = rect.cgRect
        guard cgRect.width > 0, cgRect.height > 0 else {
            return
        }

        let radius = min(max(0, cornerRadius), min(cgRect.width, cgRect.height) / 2)
        let path = radius > 0
            ? CGPath(roundedRect: cgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            : CGPath(rect: cgRect, transform: nil)

        context.saveGState()
        defer { context.restoreGState() }

        if let fill {
            context.addPath(path)
            context.setFillColor(fill.cgColor)
            context.fillPath()
        }

        if stroke.isSketchy {
            var rng = SketchyRandom(seedID: id)
            let span = min(Double(cgRect.width), Double(cgRect.height))
            let amplitude = sketchyAmplitude(for: stroke, span: span)
            let corners = [
                CGPoint(x: cgRect.minX, y: cgRect.minY),
                CGPoint(x: cgRect.maxX, y: cgRect.minY),
                CGPoint(x: cgRect.maxX, y: cgRect.maxY),
                CGPoint(x: cgRect.minX, y: cgRect.maxY),
            ]
            for pass in 0 ..< 2 {
                let passPath = CGMutablePath()
                if radius > 0 {
                    // 圆角矩形先取四条直边端点并带轻微圆角插值点，施以手绘双描边扰动。
                    let r = radius
                    let loopPoints: [CGPoint] = [
                        CGPoint(x: cgRect.minX + r, y: cgRect.minY),
                        CGPoint(x: cgRect.maxX - r, y: cgRect.minY),
                        CGPoint(x: cgRect.maxX, y: cgRect.minY + r),
                        CGPoint(x: cgRect.maxX, y: cgRect.maxY - r),
                        CGPoint(x: cgRect.maxX - r, y: cgRect.maxY),
                        CGPoint(x: cgRect.minX + r, y: cgRect.maxY),
                        CGPoint(x: cgRect.minX, y: cgRect.maxY - r),
                        CGPoint(x: cgRect.minX, y: cgRect.minY + r),
                    ]
                    for idx in 0 ..< loopPoints.count {
                        let a = loopPoints[idx]
                        let b = loopPoints[(idx + 1) % loopPoints.count]
                        appendSketchySegment(from: a, to: b, amplitude: amplitude, rng: &rng, to: passPath, moveToStart: idx == 0)
                    }
                } else {
                    for edge in 0 ..< 4 {
                        let a = corners[edge]
                        let b = corners[(edge + 1) % 4]
                        appendSketchySegment(from: a, to: b, amplitude: amplitude, rng: &rng, to: passPath, moveToStart: true)
                    }
                }
                strokeSketchyPass(passPath, stroke: stroke, pass: pass, in: context)
            }
            return
        }

        // 描边居中于路径：与 CoreGraphics 默认语义一致，不额外内缩。
        context.addPath(path)
        configureStroke(stroke, in: context)
        context.strokePath()
    }

    private static func drawLine(
        _ start: PixelPoint,
        _ end: PixelPoint,
        stroke: StrokeStyle,
        id: UUID,
        in context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        if stroke.isSketchy {
            var rng = SketchyRandom(seedID: id)
            let span = hypot(end.x - start.x, end.y - start.y)
            let amplitude = sketchyAmplitude(for: stroke, span: span)
            for pass in 0 ..< 2 {
                let passPath = CGMutablePath()
                appendSketchySegment(
                    from: start.cgPoint,
                    to: end.cgPoint,
                    amplitude: amplitude,
                    rng: &rng,
                    to: passPath,
                    moveToStart: true
                )
                strokeSketchyPass(passPath, stroke: stroke, pass: pass, in: context)
            }
            return
        }

        context.beginPath()
        context.move(to: start.cgPoint)
        context.addLine(to: end.cgPoint)
        configureStroke(stroke, in: context)
        context.strokePath()
    }

    private static func drawArrow(
        start: PixelPoint,
        end: PixelPoint,
        stroke: StrokeStyle,
        headLength: Double,
        headWidth: Double,
        id: UUID,
        in context: CGContext
    ) {
        let from = start.cgPoint
        let to = end.cgPoint
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else {
            return
        }

        // 单位方向向量与其法向量。
        let ux = dx / length
        let uy = dy / length
        let nx = -uy
        let ny = ux

        let head = max(0, headLength)
        let halfWidth = max(0, headWidth) / 2

        // 杆：画到头部底边，避免线宽在尖端露出。
        let shaftEnd = CGPoint(x: to.x - ux * head, y: to.y - uy * head)
        let headBase = CGPoint(x: to.x - ux * head, y: to.y - uy * head)
        let left = CGPoint(x: headBase.x + nx * halfWidth, y: headBase.y + ny * halfWidth)
        let right = CGPoint(x: headBase.x - nx * halfWidth, y: headBase.y - ny * halfWidth)

        context.saveGState()
        defer { context.restoreGState() }

        if stroke.isSketchy {
            var rng = SketchyRandom(seedID: id)
            let shaftAmplitude = sketchyAmplitude(for: stroke, span: Double(length))
            let headAmplitude = sketchyAmplitude(for: stroke, span: max(head, halfWidth * 2))

            for pass in 0 ..< 2 {
                let shaftPath = CGMutablePath()
                appendSketchySegment(
                    from: from,
                    to: shaftEnd,
                    amplitude: shaftAmplitude,
                    rng: &rng,
                    to: shaftPath,
                    moveToStart: true
                )
                strokeSketchyPass(shaftPath, stroke: stroke, pass: pass, in: context)
            }

            // 头部先实心填充以保证尖端不镂空，再叠加手绘双描边轮廓。
            context.beginPath()
            context.move(to: to)
            context.addLine(to: left)
            context.addLine(to: right)
            context.closePath()
            context.setFillColor(stroke.color.cgColor)
            context.fillPath()

            for pass in 0 ..< 2 {
                let headPath = CGMutablePath()
                appendSketchySegment(from: to, to: left, amplitude: headAmplitude, rng: &rng, to: headPath, moveToStart: true)
                appendSketchySegment(from: left, to: right, amplitude: headAmplitude, rng: &rng, to: headPath, moveToStart: false)
                appendSketchySegment(from: right, to: to, amplitude: headAmplitude, rng: &rng, to: headPath, moveToStart: false)
                strokeSketchyPass(headPath, stroke: stroke, pass: pass, in: context)
            }
            return
        }

        context.beginPath()
        context.move(to: from)
        context.addLine(to: shaftEnd)
        configureStroke(stroke, in: context)
        context.strokePath()

        // 箭头头部：闭合三角形，同时描边与填充，
        // 这样即使 stroke.width 很大，尖端也不会出现镂空。
        context.beginPath()
        context.move(to: to)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        configureStroke(stroke, in: context)
        context.strokePath()
        context.setFillColor(stroke.color.cgColor)
        context.fillPath()
    }

    // MARK: - M3 新增标注

    /// 编号标记：圆底（可选填充）+ 描边 + 居中的序号。
    private static func drawNumbering(
        center: PixelPoint,
        radius: Double,
        index: Int,
        stroke: StrokeStyle,
        fill: RGBAColor?,
        textColor: RGBAColor,
        in context: CGContext
    ) {
        guard radius > 0 else {
            return
        }
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let path = CGPath(ellipseIn: rect, transform: nil)

        context.saveGState()
        defer { context.restoreGState() }

        if let fill {
            context.addPath(path)
            context.setFillColor(fill.cgColor)
            context.fillPath()
        }
        context.addPath(path)
        configureStroke(stroke, in: context)
        context.strokePath()

        // 字号随半径走；对于 >= 100 的多位数按实际排版宽度自适应缩放，防止序号穿出圆框。
        let label = "\(index)"
        var fontSize = max(9, radius * 1.1)
        if index >= 100 || label.count >= 3 {
            let probeFont = TextMetrics.font(for: .system(size: fontSize))
            let probeLine = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: label,
                    attributes: [kCTFontAttributeName as NSAttributedString.Key: probeFont]
                )
            )
            let measuredWidth = Double(CTLineGetTypographicBounds(probeLine, nil, nil, nil))
            let safeChordWidth = max(6.0, radius * 1.52)
            if measuredWidth > safeChordWidth {
                fontSize = max(6.0, fontSize * (safeChordWidth / measuredWidth))
            }
        }
        let font = FontDescriptor.system(size: fontSize)
        drawCenteredText(label, center: center.cgPoint, font: font, color: textColor, in: context)
    }

    /// 高亮：半透明填充的矩形。
    ///
    /// 透明度由调用方写进 `color`（模型层不设默认值）：高亮的作用是「标出来但还看得见
    /// 底下的内容」，不透明度只能由使用场景决定。
    private static func drawHighlight(_ rect: PixelRect, color: RGBAColor, in context: CGContext) {
        let cgRect = rect.cgRect
        guard cgRect.width > 0, cgRect.height > 0 else {
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(color.cgColor)
        context.fill(cgRect)
    }

    /// 测量：两点连线 + 沿法向量偏移的圆角半透明读数底板。
    ///
    /// 只画读数不画单位：单位换算属 UI 层（契约 §2.2），
    /// 模型存的是底图像素，导出图上的数字必须与像素一致。
    private static func drawMeasure(
        start: PixelPoint,
        end: PixelPoint,
        stroke: StrokeStyle,
        canvasOrigin: PixelPoint,
        canvasWidth: Int,
        canvasHeight: Int,
        in context: CGContext
    ) {
        drawLine(start, end, stroke: stroke, id: UUID(), in: context)

        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length >= 1 else {
            return
        }

        let label = "\(Int(length.rounded()))"
        let fontSize = max(10, stroke.width * 6)
        let font = FontDescriptor.system(size: fontSize)
        let ctFont = TextMetrics.font(for: font)
        let probeLine = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: label,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: ctFont]
            )
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = Double(CTLineGetTypographicBounds(probeLine, &ascent, &descent, &leading))
        let textHeight = Double(ascent + descent + leading)

        let padX = max(5.0, fontSize * 0.35)
        let padY = max(3.0, fontSize * 0.2)
        let pillWidth = textWidth + padX * 2
        let pillHeight = textHeight + padY * 2

        // 单位方向与规范化法向量（水平/斜线优先向画布上方偏移，纯竖线优先向右侧偏移）。
        let ux = dx / length
        let uy = dy / length
        var nx = -uy
        var ny = ux
        if ny > 0.001 || (abs(ny) <= 0.001 && nx < 0) {
            nx = -nx
            ny = -ny
        }

        let gap = max(4.0, stroke.width / 2 + 4.0)
        let normalOffset = gap + (abs(nx) * pillWidth + abs(ny) * pillHeight) / 2
        let midX = (start.x + end.x) / 2
        let midY = (start.y + end.y) / 2

        let preferredCenter = CGPoint(x: midX + nx * normalOffset, y: midY + ny * normalOffset)
        let flippedCenter = CGPoint(x: midX - nx * normalOffset, y: midY - ny * normalOffset)

        let margin = 2.0
        let minX = canvasOrigin.x + margin + pillWidth / 2
        let maxX = canvasOrigin.x + Double(canvasWidth) - margin - pillWidth / 2
        let minY = canvasOrigin.y + margin + pillHeight / 2
        let maxY = canvasOrigin.y + Double(canvasHeight) - margin - pillHeight / 2

        func fitsInCanvas(_ center: CGPoint) -> Bool {
            (minX > maxX || (center.x >= minX && center.x <= maxX))
                && (minY > maxY || (center.y >= minY && center.y <= maxY))
        }

        var labelCenter = preferredCenter
        if !fitsInCanvas(preferredCenter) && fitsInCanvas(flippedCenter) {
            labelCenter = flippedCenter
        }

        // 将读数底板中心钳制到画布可见边界内，彻底避免顶边或侧边裁切。
        if minX <= maxX {
            labelCenter.x = min(max(labelCenter.x, minX), maxX)
        } else {
            labelCenter.x = canvasOrigin.x + Double(canvasWidth) / 2
        }
        if minY <= maxY {
            labelCenter.y = min(max(labelCenter.y, minY), maxY)
        } else {
            labelCenter.y = canvasOrigin.y + Double(canvasHeight) / 2
        }

        let pillRect = CGRect(
            x: labelCenter.x - pillWidth / 2,
            y: labelCenter.y - pillHeight / 2,
            width: pillWidth,
            height: pillHeight
        )
        let cornerRadius = min(pillWidth, pillHeight) / 2
        let pillPath = CGPath(
            roundedRect: pillRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        // 根据文字感知亮度自适应高对比度半透明底板，确保浅色/深色标注读数均清晰可读。
        let luminance = 0.2126 * stroke.color.r + 0.7152 * stroke.color.g + 0.0722 * stroke.color.b
        let backdropColor = luminance < 0.45
            ? RGBAColor(r: 0.96, g: 0.96, b: 0.98, a: 0.86)
            : RGBAColor(r: 0.08, g: 0.09, b: 0.12, a: 0.78)

        context.saveGState()
        context.addPath(pillPath)
        context.setFillColor(backdropColor.cgColor)
        context.fillPath()
        context.restoreGState()

        drawCenteredText(label, center: labelCenter, font: font, color: stroke.color, in: context)
    }

    /// 放大镜：把圆心处一小块底图放大后画回圆形区域。
    ///
    /// 与马赛克同类——都需要读**当前画布**的像素。直接在圆形 `clip()` 内以 `center` 为锚点
    /// 局部翻转 Y 轴并按 `zoom` 绘制整幅画布快照，既抵消画布坐标系 Y 轴翻转引起的倒置，
    /// 又彻底消除贴边 `cropping` 引起的拉伸畸变。
    private static func drawMagnifier(
        center: PixelPoint,
        radius: Double,
        zoom: Double,
        border: StrokeStyle,
        canvasOrigin: PixelPoint,
        in context: CGContext
    ) {
        guard radius > 0, zoom > 1 else {
            return
        }
        let destRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let path = CGPath(ellipseIn: destRect, transform: nil)

        context.saveGState()
        if let snapshot = context.makeImage() {
            context.addPath(path)
            context.clip()

            // 画布 CTM 已翻转 Y 轴（向下），在圆心处再次局部翻转使图像正立，
            // 同时以 `center - canvasOrigin` 为放大锚点等比绘制快照。
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: 1, y: -1)
            let drawRect = CGRect(
                x: (canvasOrigin.x - center.x) * zoom,
                y: (center.y - canvasOrigin.y - Double(snapshot.height)) * zoom,
                width: Double(snapshot.width) * zoom,
                height: Double(snapshot.height) * zoom
            )
            context.interpolationQuality = .high
            context.draw(snapshot, in: drawRect)
        }
        context.restoreGState()

        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(path)
        configureStroke(border, in: context)
        context.strokePath()
    }

    /// 自由绘制：已简化的点序列，渲染时过中点做二次贝塞尔平滑。
    ///
    /// 平滑**不改变存储的点序列**（契约 §2.3）：模型里始终是简化后的折线点，
    /// 曲线只在这一步生成，因此「模型 → 成图」仍是确定性的。
    private static func drawFreehand(
        _ points: [PixelPoint],
        stroke: StrokeStyle,
        id: UUID,
        in context: CGContext
    ) {
        guard points.count >= 2 else {
            return
        }

        func buildSmoothPath(from source: [PixelPoint]) -> CGMutablePath {
            let path = CGMutablePath()
            path.move(to: source[0].cgPoint)
            if source.count == 2 {
                path.addLine(to: source[1].cgPoint)
            } else {
                // 以每个采样点为控制点、相邻两点的中点为端点：
                // 曲线恰好穿过中点，不会像直接连折线那样出现尖角。
                for index in 1 ..< (source.count - 1) {
                    let current = source[index].cgPoint
                    let next = source[index + 1].cgPoint
                    let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
                    path.addQuadCurve(to: mid, control: current)
                }
                path.addLine(to: source[source.count - 1].cgPoint)
            }
            return path
        }

        context.saveGState()
        defer { context.restoreGState() }

        if stroke.isSketchy {
            var rng = SketchyRandom(seedID: id)
            let amplitude = sketchyAmplitude(for: stroke, span: 60) * 0.75
            let primaryPoints = points.map {
                PixelPoint(
                    x: $0.x + rng.nextUnit() * amplitude * 0.35,
                    y: $0.y + rng.nextUnit() * amplitude * 0.35
                )
            }
            let secondaryPoints = points.map {
                PixelPoint(
                    x: $0.x + rng.nextUnit() * amplitude,
                    y: $0.y + rng.nextUnit() * amplitude
                )
            }
            strokeSketchyPass(buildSmoothPath(from: primaryPoints), stroke: stroke, pass: 0, in: context)
            strokeSketchyPass(buildSmoothPath(from: secondaryPoints), stroke: stroke, pass: 1, in: context)
            return
        }

        context.addPath(buildSmoothPath(from: points))
        configureStroke(stroke, in: context)
        context.strokePath()
    }

    /// 弯曲箭头：二次贝塞尔杆 + 沿终点切线的箭头头部。
    private static func drawCurvedArrow(
        start: PixelPoint,
        control: PixelPoint,
        end: PixelPoint,
        stroke: StrokeStyle,
        headLength: Double,
        headWidth: Double,
        id: UUID,
        in context: CGContext
    ) {
        // 头部方向取**终点切线**（end − control），不是 start→end 的弦方向：
        // 曲线末端可能与弦差很多，用弦会让箭头头部歪出曲线。
        let tangentX = end.x - control.x
        let tangentY = end.y - control.y
        let tangentLength = (tangentX * tangentX + tangentY * tangentY).squareRoot()
        guard tangentLength > 0 else {
            drawLine(start, end, stroke: stroke, id: id, in: context)
            return
        }
        let ux = tangentX / tangentLength
        let uy = tangentY / tangentLength
        let nx = -uy
        let ny = ux

        let head = max(0, headLength)
        let halfWidth = max(0, headWidth) / 2
        let tip = end.cgPoint
        let headBase = CGPoint(x: tip.x - ux * head, y: tip.y - uy * head)
        let left = CGPoint(x: headBase.x + nx * halfWidth, y: headBase.y + ny * halfWidth)
        let right = CGPoint(x: headBase.x - nx * halfWidth, y: headBase.y - ny * halfWidth)

        context.saveGState()
        defer { context.restoreGState() }

        if stroke.isSketchy {
            var rng = SketchyRandom(seedID: id)
            let span = hypot(end.x - start.x, end.y - start.y)
            let shaftAmplitude = sketchyAmplitude(for: stroke, span: span)
            let headAmplitude = sketchyAmplitude(for: stroke, span: max(head, halfWidth * 2))

            for pass in 0 ..< 2 {
                let shaftPath = CGMutablePath()
                let jitterStart = CGPoint(
                    x: start.x + rng.nextUnit() * shaftAmplitude * 0.35,
                    y: start.y + rng.nextUnit() * shaftAmplitude * 0.35
                )
                let jitterControl = CGPoint(
                    x: control.x + rng.nextUnit() * shaftAmplitude,
                    y: control.y + rng.nextUnit() * shaftAmplitude
                )
                let jitterBase = CGPoint(
                    x: headBase.x + rng.nextUnit() * shaftAmplitude * 0.35,
                    y: headBase.y + rng.nextUnit() * shaftAmplitude * 0.35
                )
                shaftPath.move(to: jitterStart)
                shaftPath.addQuadCurve(to: jitterBase, control: jitterControl)
                strokeSketchyPass(shaftPath, stroke: stroke, pass: pass, in: context)
            }

            context.beginPath()
            context.move(to: tip)
            context.addLine(to: left)
            context.addLine(to: right)
            context.closePath()
            context.setFillColor(stroke.color.cgColor)
            context.fillPath()

            for pass in 0 ..< 2 {
                let headPath = CGMutablePath()
                appendSketchySegment(from: tip, to: left, amplitude: headAmplitude, rng: &rng, to: headPath, moveToStart: true)
                appendSketchySegment(from: left, to: right, amplitude: headAmplitude, rng: &rng, to: headPath, moveToStart: false)
                appendSketchySegment(from: right, to: tip, amplitude: headAmplitude, rng: &rng, to: headPath, moveToStart: false)
                strokeSketchyPass(headPath, stroke: stroke, pass: pass, in: context)
            }
            return
        }

        // 杆画到头部底边：画到尖端的话线宽会在三角形外露出一截。
        context.beginPath()
        context.move(to: start.cgPoint)
        context.addQuadCurve(to: headBase, control: control.cgPoint)
        configureStroke(stroke, in: context)
        context.strokePath()

        context.beginPath()
        context.move(to: tip)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        configureStroke(stroke, in: context)
        context.strokePath()
        context.setFillColor(stroke.color.cgColor)
        context.fillPath()
    }

    /// 以给定中心居中绘制一行文字。
    ///
    /// 编号与测量读数都要求文字随标记居中，而居中必须知道**排版宽度**：
    /// 用字号乘系数估算，在两位数与全角字符上会明显偏。
    private static func drawCenteredText(
        _ text: String,
        center: CGPoint,
        font: FontDescriptor,
        color: RGBAColor,
        in context: CGContext
    ) {
        guard !text.isEmpty else {
            return
        }
        let ctFont = TextMetrics.font(for: font)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: ctFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color.cgColor,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        context.saveGState()
        defer { context.restoreGState() }
        // 与 `drawText` 同理：CTM 已翻转为左上原点，文字排版需要 y 轴向上。
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: center.x - width / 2,
            y: center.y + (ascent - descent) / 2
        )
        CTLineDraw(line, context)
    }

    // MARK: - 文字

    private static func drawText(
        origin: PixelPoint,
        text: String,
        font: FontDescriptor,
        color: RGBAColor,
        background: RGBAColor?,
        maxWidth: Double?,
        in context: CGContext
    ) {
        guard !text.isEmpty else {
            return
        }

        // 上下文已被翻转为左上原点，而文字排版需要 y 轴向上，
        // 因此把 textMatrix 的 y 取反来抵消 CTM 的翻转。
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // 与 `AnnotationHitTest.measuredTextRect` 共用 `TextMetrics.layoutLines`，
        // 确保断行宽度、行高及末尾换行空行推进完全一致。
        let layout = TextMetrics.layoutLines(
            text: text,
            font: font,
            maxWidth: maxWidth,
            foregroundColor: color.cgColor
        )

        var baselineY = origin.y
        for item in layout.lines {
            guard let line = item.line else {
                baselineY += item.height
                continue
            }
            if let background {
                // 底色紧贴该行的排版盒：上边为基线减去 ascent。
                let box = CGRect(
                    x: origin.x,
                    y: baselineY - item.ascent,
                    width: item.width,
                    height: item.height
                )
                context.setFillColor(background.cgColor)
                context.fill(box)
            }
            context.textPosition = CGPoint(x: origin.x, y: baselineY)
            CTLineDraw(line, context)
            baselineY += item.height
        }
    }

    // MARK: - 马赛克

    /// 马赛克的覆盖区域。
    ///
    /// 框选是矩形；涂抹是带半径的路径。两者共用同一套像素化实现，
    /// 差别只在「这个像素是否被覆盖」的判定上。
    private enum MosaicCoverage {
        case rect(PixelRect)
        case stroke(points: [PixelPoint], radius: Double)

        /// 覆盖区域在**底图坐标**里的包围盒。
        var backdropBounds: PixelRect {
            switch self {
            case let .rect(rect):
                return rect

            case let .stroke(points, radius):
                guard let first = points.first else {
                    return PixelRect(origin: .zero, size: PixelSize(width: 0, height: 0))
                }
                var minX = first.x, maxX = first.x
                var minY = first.y, maxY = first.y
                for point in points.dropFirst() {
                    minX = min(minX, point.x)
                    maxX = max(maxX, point.x)
                    minY = min(minY, point.y)
                    maxY = max(maxY, point.y)
                }
                // 笔刷有半径，包围盒必须外扩，否则笔画边缘会被裁掉。
                return PixelRect(
                    origin: PixelPoint(x: minX - radius, y: minY - radius),
                    size: PixelSize(
                        width: (maxX - minX) + radius * 2,
                        height: (maxY - minY) + radius * 2
                    )
                )
            }
        }

        /// 某个底图像素是否落在覆盖区内。
        func covers(backdropX x: Double, backdropY y: Double) -> Bool {
            switch self {
            case let .rect(rect):
                return x >= rect.origin.x && x < rect.origin.x + rect.size.width
                    && y >= rect.origin.y && y < rect.origin.y + rect.size.height

            case let .stroke(points, radius):
                guard let first = points.first else { return false }
                if points.count == 1 {
                    return Self.distance(x, y, first.x, first.y) <= radius
                }
                for index in 1 ..< points.count {
                    let a = points[index - 1]
                    let b = points[index]
                    if Self.distanceToSegment(x, y, a, b) <= radius {
                        return true
                    }
                }
                return false
            }
        }

        /// 到覆盖区最近边的距离（仅涂抹用于块级预筛，不要求精确）。
        func distanceToPath(x: Double, y: Double) -> Double {
            switch self {
            case .rect:
                // 矩形直接用包围盒判定，调用方不会走这条路。
                return 0

            case let .stroke(points, _):
                guard let first = points.first else { return .infinity }
                if points.count == 1 {
                    return Self.distance(x, y, first.x, first.y)
                }
                var best = Double.infinity
                for index in 1 ..< points.count {
                    best = min(
                        best,
                        Self.distanceToSegment(x, y, points[index - 1], points[index])
                    )
                }
                return best
            }
        }

        private static func distance(
            _ px: Double, _ py: Double,
            _ ax: Double, _ ay: Double
        ) -> Double {
            let dx = px - ax
            let dy = py - ay
            return (dx * dx + dy * dy).squareRoot()
        }

        private static func distanceToSegment(
            _ px: Double, _ py: Double,
            _ a: PixelPoint, _ b: PixelPoint
        ) -> Double {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else {
                return distance(px, py, a.x, a.y)
            }
            // 投影到线段上并夹到端点，得到真正的线段距离。
            var t = ((px - a.x) * dx + (py - a.y) * dy) / lengthSquared
            t = min(max(t, 0), 1)
            return distance(px, py, a.x + t * dx, a.y + t * dy)
        }
    }

    /// 统一打码入口：支持像素化（`pixelate`）、高斯模糊（`blur`）与纯色遮盖（`solid`）。
    ///
    /// 直接读写位图数据而不经过 CoreGraphics 绘制：
    /// 这是唯一需要「读回像素」的标注，走绘制路径无法实现。
    ///
    /// 正因为它是直接寻址位图，调用者必须提供 `canvasOrigin`：
    /// CGContext 的变换只影响矢量绘制，**不会**改变 `context.data` 的索引基准。
    ///
    /// 对于像素化模式，块网格**锚定在底图原点**，确保同一区域多次涂抹拼缝处不出现半块错位。
    private static func applyMosaic(
        coverage: MosaicCoverage,
        mode: MosaicMode,
        intensity: Double,
        in context: CGContext,
        canvasOrigin: PixelPoint,
        canvasWidth: Int,
        canvasHeight: Int
    ) {
        guard let data = context.data else {
            return
        }

        let bytesPerRow = context.bytesPerRow
        let buffer = data.assumingMemoryBound(to: UInt8.self)

        // 底图坐标 ↔ 画布坐标：canvasX = backdropX - originX。
        // 直接访问 context.data 时坐标是底图坐标，必须显式折算，
        // 否则非零 selection.origin 下马赛克会整体偏移。
        let originX = Int(canvasOrigin.x.rounded())
        let originY = Int(canvasOrigin.y.rounded())

        let bounds = coverage.backdropBounds
        let canvasX0 = max(0, Int(bounds.origin.x.rounded(.down)) - originX)
        let canvasY0 = max(0, Int(bounds.origin.y.rounded(.down)) - originY)
        let canvasX1 = min(
            canvasWidth,
            Int((bounds.origin.x + bounds.size.width).rounded(.up)) - originX
        )
        let canvasY1 = min(
            canvasHeight,
            Int((bounds.origin.y + bounds.size.height).rounded(.up)) - originY
        )
        guard canvasX0 < canvasX1, canvasY0 < canvasY1 else {
            return
        }

        // 涂抹模式统一构建「局部包围盒尺寸」的 8-bit 灰度掩码，
        // 相比分配整幅画布可将大图涂抹内存降低百倍。
        var maskContext: CGContext?
        var maskBuffer: UnsafeMutablePointer<UInt8>?
        let maskWidth = canvasX1 - canvasX0
        let maskHeight = canvasY1 - canvasY0
        if case let .stroke(points, radius) = coverage {
            maskContext = makeStrokeMask(
                points: points,
                radius: radius,
                originX: originX,
                originY: originY,
                maskOriginX: canvasX0,
                maskOriginY: canvasY0,
                maskWidth: maskWidth,
                maskHeight: maskHeight
            )
            maskBuffer = maskContext?.data?.assumingMemoryBound(to: UInt8.self)
        }
        let maskBytesPerRow = maskContext?.bytesPerRow ?? 0

        switch mode {
        case .pixelate:
            let blockSize = max(2, Int(intensity.rounded()))
            let firstBlockX = Int(floor(Double(canvasX0 + originX) / Double(blockSize)))
            let lastBlockX = Int(floor(Double(canvasX1 - 1 + originX) / Double(blockSize)))
            let firstBlockY = Int(floor(Double(canvasY0 + originY) / Double(blockSize)))
            let lastBlockY = Int(floor(Double(canvasY1 - 1 + originY) / Double(blockSize)))
            let halfDiagonal = Double(blockSize) * 0.7072

            var digestContext: CGContext?
            var digestBuffer: UnsafeMutablePointer<UInt8>?
            if case let .stroke(points, radius) = coverage {
                digestContext = makeStrokeBlockDigest(
                    points: points,
                    radius: radius,
                    blockSize: blockSize,
                    firstBlockX: firstBlockX,
                    firstBlockY: firstBlockY,
                    lastBlockX: lastBlockX,
                    lastBlockY: lastBlockY
                )
                digestBuffer = digestContext?.data?.assumingMemoryBound(to: UInt8.self)
            }

            for blockY in firstBlockY ... lastBlockY {
                let blockY0 = max(canvasY0, blockY * blockSize - originY)
                let blockY1 = min(canvasY1, blockY * blockSize - originY + blockSize)
                guard blockY0 < blockY1 else { continue }

                for blockX in firstBlockX ... lastBlockX {
                    let blockX0 = max(canvasX0, blockX * blockSize - originX)
                    let blockX1 = min(canvasX1, blockX * blockSize - originX + blockSize)
                    guard blockX0 < blockX1 else { continue }

                    if let digestBuffer, let digestContext {
                        let dx = blockX - firstBlockX
                        let dy = blockY - firstBlockY
                        if digestBuffer[dy * digestContext.bytesPerRow + dx] == 0 {
                            continue
                        }
                    }

                    if maskBuffer == nil, digestBuffer == nil, case let .stroke(_, radius) = coverage {
                        let centerX = Double((blockX0 + blockX1) / 2 + originX)
                        let centerY = Double((blockY0 + blockY1) / 2 + originY)
                        if coverage.distanceToPath(x: centerX, y: centerY) - halfDiagonal > radius {
                            continue
                        }
                    }

                    pixelateBlock(
                        x0: blockX0,
                        x1: blockX1,
                        y0: blockY0,
                        y1: blockY1,
                        coverage: coverage,
                        mask: maskBuffer,
                        maskOriginX: canvasX0,
                        maskOriginY: canvasY0,
                        maskBytesPerRow: maskBytesPerRow,
                        originX: originX,
                        originY: originY,
                        buffer: buffer,
                        bytesPerRow: bytesPerRow
                    )
                }
            }

        case .blur:
            applyBlur(
                x0: canvasX0,
                x1: canvasX1,
                y0: canvasY0,
                y1: canvasY1,
                intensity: intensity,
                coverage: coverage,
                mask: maskBuffer,
                maskBytesPerRow: maskBytesPerRow,
                originX: originX,
                originY: originY,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                buffer: buffer,
                bytesPerRow: bytesPerRow
            )

        case .solid:
            applySolid(
                x0: canvasX0,
                x1: canvasX1,
                y0: canvasY0,
                y1: canvasY1,
                coverage: coverage,
                mask: maskBuffer,
                maskBytesPerRow: maskBytesPerRow,
                originX: originX,
                originY: originY,
                buffer: buffer,
                bytesPerRow: bytesPerRow
            )
        }
    }

    /// 使用 Accelerate 3-Pass 均匀盒滤波（精确收敛至标准高斯分布，搭配 `kvImageEdgeExtend`）
    /// 实现局部高斯模糊打码。
    ///
    /// - Note: 相比单次 Tent + Box（等效 σ 仅约 0.46 × intensity），连续 3 次同半径 `vImageBoxConvolve`
    ///   的等效高斯标准差为 σ = √(r(r + 1)) ≈ r + 0.5，旁瓣振铃极低、字形笔画彻底混融，
    ///   且借助滑动和算法复杂度与半径无关（O(W × H)）。
    private static func applyBlur(
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        intensity: Double,
        coverage: MosaicCoverage,
        mask: UnsafeMutablePointer<UInt8>?,
        maskBytesPerRow: Int,
        originX: Int,
        originY: Int,
        canvasWidth: Int,
        canvasHeight: Int,
        buffer: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int
    ) {
        // 下限 14px 保证即便传入旧版较小 intensity，最低等级也拥有 σ ≥ 14.5px 的有效高斯扩散，
        // 避免最低档在常规界面字体上出现肉眼仍能辨认轮廓的欠模糊现象。
        let boxRadius = max(14, min(Int((intensity * 1.05).rounded()), 120))
        let kernelSize = UInt32(boxRadius * 2 + 1)

        // 3 次卷积主能量跨度约为 2 * boxRadius；向四周借取真实画布像素以防局部裁剪接缝，
        // 遇画布真边界则交由 `kvImageEdgeExtend` 延伸像素，消除边缘黑晕。
        let sampleMargin = min(boxRadius * 2, 160)
        let srcX0 = max(0, x0 - sampleMargin)
        let srcY0 = max(0, y0 - sampleMargin)
        let srcX1 = min(canvasWidth, x1 + sampleMargin)
        let srcY1 = min(canvasHeight, y1 + sampleMargin)
        let srcWidth = srcX1 - srcX0
        let srcHeight = srcY1 - srcY0
        guard srcWidth > 0, srcHeight > 0 else {
            return
        }

        let srcRowBytes = srcWidth * 4
        var pingBytes = [UInt8](repeating: 0, count: srcRowBytes * srcHeight)
        var pongBytes = [UInt8](repeating: 0, count: srcRowBytes * srcHeight)

        pingBytes.withUnsafeMutableBytes { rawPing in
            guard let dstPtr = rawPing.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in 0 ..< srcHeight {
                let srcRowPtr = buffer + (srcY0 + row) * bytesPerRow + srcX0 * 4
                let localPtr = dstPtr + row * srcRowBytes
                memcpy(localPtr, srcRowPtr, srcRowBytes)
            }
        }

        let blurError: vImage_Error = pingBytes.withUnsafeMutableBytes { rawPing in
            pongBytes.withUnsafeMutableBytes { rawPong in
                var pingBuf = vImage_Buffer(
                    data: rawPing.baseAddress,
                    height: vImagePixelCount(srcHeight),
                    width: vImagePixelCount(srcWidth),
                    rowBytes: srcRowBytes
                )
                var pongBuf = vImage_Buffer(
                    data: rawPong.baseAddress,
                    height: vImagePixelCount(srcHeight),
                    width: vImagePixelCount(srcWidth),
                    rowBytes: srcRowBytes
                )

                let tempSize = vImageBoxConvolve_ARGB8888(
                    &pingBuf,
                    &pongBuf,
                    nil,
                    0,
                    0,
                    kernelSize,
                    kernelSize,
                    nil,
                    vImage_Flags(kvImageEdgeExtend | kvImageGetTempBufferSize)
                )
                guard tempSize >= 0 else { return tempSize }

                var tempBuffer = [UInt8](repeating: 0, count: max(1, tempSize))
                return tempBuffer.withUnsafeMutableBytes { rawTemp in
                    let tempPtr = tempSize > 0 ? rawTemp.baseAddress : nil
                    let flags = vImage_Flags(kvImageEdgeExtend)

                    // 3-Pass Ping-Pong：ping -> pong -> ping -> pong，最终结果稳定落在 pongBytes。
                    let e1 = vImageBoxConvolve_ARGB8888(
                        &pingBuf, &pongBuf, tempPtr, 0, 0, kernelSize, kernelSize, nil, flags
                    )
                    guard e1 == kvImageNoError else { return e1 }

                    let e2 = vImageBoxConvolve_ARGB8888(
                        &pongBuf, &pingBuf, tempPtr, 0, 0, kernelSize, kernelSize, nil, flags
                    )
                    guard e2 == kvImageNoError else { return e2 }

                    return vImageBoxConvolve_ARGB8888(
                        &pingBuf, &pongBuf, tempPtr, 0, 0, kernelSize, kernelSize, nil, flags
                    )
                }
            }
        }
        guard blurError == kvImageNoError else {
            return
        }

        // 将卷积结果按掩码写回主画布：矩形走覆盖判定，涂抹按局部灰度掩码平滑混合。
        for y in y0 ..< y1 {
            let localY = y - srcY0
            let maskRowOffset = (y - y0) * maskBytesPerRow
            for x in x0 ..< x1 {
                let dstOffset = y * bytesPerRow + x * 4
                let blurredOffset = localY * srcRowBytes + (x - srcX0) * 4

                if let mask {
                    let alpha = Int(mask[maskRowOffset + (x - x0)])
                    if alpha == 0 {
                        continue
                    }
                    if alpha == 255 {
                        buffer[dstOffset] = pongBytes[blurredOffset]
                        buffer[dstOffset + 1] = pongBytes[blurredOffset + 1]
                        buffer[dstOffset + 2] = pongBytes[blurredOffset + 2]
                        buffer[dstOffset + 3] = pongBytes[blurredOffset + 3]
                    } else {
                        let inv = 255 - alpha
                        buffer[dstOffset] = UInt8((Int(pongBytes[blurredOffset]) * alpha + Int(buffer[dstOffset]) * inv + 127) / 255)
                        buffer[dstOffset + 1] = UInt8((Int(pongBytes[blurredOffset + 1]) * alpha + Int(buffer[dstOffset + 1]) * inv + 127) / 255)
                        buffer[dstOffset + 2] = UInt8((Int(pongBytes[blurredOffset + 2]) * alpha + Int(buffer[dstOffset + 2]) * inv + 127) / 255)
                        buffer[dstOffset + 3] = UInt8((Int(pongBytes[blurredOffset + 3]) * alpha + Int(buffer[dstOffset + 3]) * inv + 127) / 255)
                    }
                } else if coverage.covers(backdropX: Double(x + originX), backdropY: Double(y + originY)) {
                    buffer[dstOffset] = pongBytes[blurredOffset]
                    buffer[dstOffset + 1] = pongBytes[blurredOffset + 1]
                    buffer[dstOffset + 2] = pongBytes[blurredOffset + 2]
                    buffer[dstOffset + 3] = pongBytes[blurredOffset + 3]
                }
            }
        }
    }

    /// 纯色遮盖打码：按覆盖区域与涂抹掩码填充不透明纯黑遮盖（BGRA = `0, 0, 0, 255`）。
    private static func applySolid(
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        coverage: MosaicCoverage,
        mask: UnsafeMutablePointer<UInt8>?,
        maskBytesPerRow: Int,
        originX: Int,
        originY: Int,
        buffer: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int
    ) {
        for y in y0 ..< y1 {
            let maskRowOffset = (y - y0) * maskBytesPerRow
            for x in x0 ..< x1 {
                let offset = y * bytesPerRow + x * 4
                if let mask {
                    let alpha = Int(mask[maskRowOffset + (x - x0)])
                    if alpha == 0 {
                        continue
                    }
                    if alpha == 255 {
                        buffer[offset] = 0
                        buffer[offset + 1] = 0
                        buffer[offset + 2] = 0
                        buffer[offset + 3] = 255
                    } else {
                        let inv = 255 - alpha
                        buffer[offset] = UInt8((Int(buffer[offset]) * inv + 127) / 255)
                        buffer[offset + 1] = UInt8((Int(buffer[offset + 1]) * inv + 127) / 255)
                        buffer[offset + 2] = UInt8((Int(buffer[offset + 2]) * inv + 127) / 255)
                        buffer[offset + 3] = UInt8((255 * alpha + Int(buffer[offset + 3]) * inv + 127) / 255)
                    }
                } else if coverage.covers(backdropX: Double(x + originX), backdropY: Double(y + originY)) {
                    buffer[offset] = 0
                    buffer[offset + 1] = 0
                    buffer[offset + 2] = 0
                    buffer[offset + 3] = 255
                }
            }
        }
    }

    /// 笔迹的**块摘要**：一个像素代表一个马赛克块是否被笔迹经过。
    ///
    /// 为什么需要它：`applyMosaic` 按包围盒遍历块，而包围盒对
    /// 「手抖、来回涂」的笔迹会迅速膨胀——实测一条弯曲笔迹的包围盒覆盖
    /// 11385 块，实际只经过约 500 块，多算的二十倍全花在空块上
    ///（每块还要两遍扫像素）。摘要把范围降回实际经过的块，
    /// 而它本身只有几万个像素，描线成本可以忽略。
    ///
    /// 线宽按块折算并**外扩一个块**：降采样可能让很细的笔迹在块网格上消失，
    /// 外扩是「宁可多算」的保守方向——多算只是慢一点，
    /// 漏算会让马赛克出现缺口。
    private static func makeStrokeBlockDigest(
        points: [PixelPoint],
        radius: Double,
        blockSize: Int,
        firstBlockX: Int,
        firstBlockY: Int,
        lastBlockX: Int,
        lastBlockY: Int
    ) -> CGContext? {
        guard let first = points.first, blockSize > 0 else { return nil }
        let gridWidth = lastBlockX - firstBlockX + 1
        let gridHeight = lastBlockY - firstBlockY + 1
        guard gridWidth > 0, gridHeight > 0 else { return nil }
        guard let digest = CGContext(
            data: nil,
            width: gridWidth,
            height: gridHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        digest.setFillColor(gray: 0, alpha: 1)
        digest.fill(CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))
        digest.setStrokeColor(gray: 1, alpha: 1)
        digest.setLineWidth(max(1, CGFloat(radius) * 2 / CGFloat(blockSize) + 2))
        digest.setLineCap(.round)
        digest.setLineJoin(.round)

        // Y 轴翻转，与掩码同理：块号向下增长，而 CGContext 位图原点在左下。
        digest.translateBy(x: 0, y: CGFloat(gridHeight))
        digest.scaleBy(x: 1, y: -1)

        func digestPoint(_ point: PixelPoint) -> CGPoint {
            CGPoint(
                x: CGFloat(point.x) / CGFloat(blockSize) - CGFloat(firstBlockX),
                y: CGFloat(point.y) / CGFloat(blockSize) - CGFloat(firstBlockY)
            )
        }

        digest.beginPath()
        digest.move(to: digestPoint(first))
        for point in points.dropFirst() {
            digest.addLine(to: digestPoint(point))
        }
        if points.count == 1 {
            digest.addLine(to: digestPoint(first))
        }
        digest.strokePath()

        return digest
    }

    /// 把笔迹描成一条粗线，作为涂抹的局部覆盖掩码。
    ///
    /// 描线交给 CoreGraphics：它是高度优化的扫描线填充，比在 Swift 里
    /// 逐像素算距离快几个数量级，也不需要自己处理圆头、圆转角与重叠段。
    ///
    /// 掩码仅按笔迹在画布内的裁剪包围盒 `maskWidth × maskHeight` 分配，
    /// **非零即覆盖**，可将大图单笔涂抹内存开销降低百倍。
    private static func makeStrokeMask(
        points: [PixelPoint],
        radius: Double,
        originX: Int,
        originY: Int,
        maskOriginX: Int,
        maskOriginY: Int,
        maskWidth: Int,
        maskHeight: Int
    ) -> CGContext? {
        guard maskWidth > 0, maskHeight > 0, let first = points.first else {
            return nil
        }
        guard let mask = CGContext(
            data: nil,
            width: maskWidth,
            height: maskHeight,
            bitsPerComponent: 8,
            bytesPerRow: maskWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        mask.setFillColor(gray: 0, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: maskWidth, height: maskHeight))
        mask.setStrokeColor(gray: 1, alpha: 1)
        // 直径 = 2 × 半径。半径可能小于 1（阈值下限），描出 0 宽度会什么都画不出。
        mask.setLineWidth(max(1, CGFloat(radius) * 2))
        mask.setLineCap(.round)
        mask.setLineJoin(.round)

        // 局部掩码坐标是（模型坐标 − 画布原点 − 局部包围盒偏移），
        // 而 CGContext 位图原点在左下，因此沿 maskHeight 翻转 Y 轴。
        mask.translateBy(x: 0, y: CGFloat(maskHeight))
        mask.scaleBy(x: 1, y: -1)

        let localOriginX = CGFloat(originX + maskOriginX)
        let localOriginY = CGFloat(originY + maskOriginY)
        func localPoint(_ point: PixelPoint) -> CGPoint {
            CGPoint(x: CGFloat(point.x) - localOriginX, y: CGFloat(point.y) - localOriginY)
        }

        mask.beginPath()
        mask.move(to: localPoint(first))
        for point in points.dropFirst() {
            mask.addLine(to: localPoint(point))
        }
        // 单点笔迹：补一段零长度线段，靠 round cap 画出一个圆盘。
        if points.count == 1 {
            mask.addLine(to: localPoint(first))
        }
        mask.strokePath()

        return mask
    }

    /// 把画布上的一个小块像素化。
    ///
    /// 两遍扫描：先对**被覆盖的**像素求平均，再把这些像素统一写成平均值。
    ///
    /// - 只写回被覆盖的像素，因此马赛克形状与笔刷形状一致，
    ///   不会因为按块取整而外扩成方块。
    /// - 只有一次「读原始值 → 求平均 → 写回」，一笔内部重叠的点
    ///   不会把已经模糊过的结果再模糊一次。
    private static func pixelateBlock(
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        coverage: MosaicCoverage,
        mask: UnsafeMutablePointer<UInt8>?,
        maskOriginX: Int,
        maskOriginY: Int,
        maskBytesPerRow: Int,
        originX: Int,
        originY: Int,
        buffer: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int
    ) {
        var sumB = 0
        var sumG = 0
        var sumR = 0
        var sumA = 0
        var count = 0

        /// 像素是否被马赛克覆盖。
        ///
        /// 涂抹走局部掩码查表（O(1)），矩形仍走几何判定（本身就是 O(1)）。
        /// 两者语义相同：掩码就是「几何判定」预先光栅化的结果。
        func isCovered(_ x: Int, _ y: Int) -> Bool {
            if let mask {
                return mask[(y - maskOriginY) * maskBytesPerRow + (x - maskOriginX)] != 0
            }
            return coverage.covers(
                backdropX: Double(x + originX),
                backdropY: Double(y + originY)
            )
        }

        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                guard isCovered(x, y) else { continue }
                // BGRA（byteOrder32Little + premultipliedFirst）
                let offset = y * bytesPerRow + x * 4
                sumB += Int(buffer[offset])
                sumG += Int(buffer[offset + 1])
                sumR += Int(buffer[offset + 2])
                sumA += Int(buffer[offset + 3])
                count += 1
            }
        }

        guard count > 0 else {
            return
        }

        let avgB = UInt8(sumB / count)
        let avgG = UInt8(sumG / count)
        let avgR = UInt8(sumR / count)
        let avgA = UInt8(sumA / count)

        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                guard isCovered(x, y) else { continue }
                let offset = y * bytesPerRow + x * 4
                buffer[offset] = avgB
                buffer[offset + 1] = avgG
                buffer[offset + 2] = avgR
                buffer[offset + 3] = avgA
            }
        }
    }

    // MARK: - 手绘微扰渲染辅助

    /// 基于标注 UUID 字节序列的确定性伪随机数生成器，保证重绘不抖动且跨进程一致。
    private struct SketchyRandom {
        private var state: UInt64

        init(seedID: UUID?) {
            if let uuid = seedID?.uuid {
                let hi = UInt64(uuid.0) << 56 | UInt64(uuid.1) << 48 | UInt64(uuid.2) << 40 | UInt64(uuid.3) << 32
                    | UInt64(uuid.4) << 24 | UInt64(uuid.5) << 16 | UInt64(uuid.6) << 8 | UInt64(uuid.7)
                let lo = UInt64(uuid.8) << 56 | UInt64(uuid.9) << 48 | UInt64(uuid.10) << 40 | UInt64(uuid.11) << 32
                    | UInt64(uuid.12) << 24 | UInt64(uuid.13) << 16 | UInt64(uuid.14) << 8 | UInt64(uuid.15)
                var mixed = hi ^ (lo &* 0x9E37_79B9_7F4A_7C15)
                mixed ^= mixed >> 30
                mixed &*= 0xBF58_476D_1CE4_E5B9
                mixed ^= mixed >> 27
                mixed &*= 0x94D0_49BB_1331_11EB
                mixed ^= mixed >> 31
                state = mixed == 0 ? 0x9E37_79B9_7F4A_7C15 : mixed
            } else {
                state = 0x9E37_79B9_7F4A_7C15
            }
        }

        mutating func nextUInt64() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// 生成 `[-1.0, 1.0]` 范围内的确定性随机浮点数。
        mutating func nextUnit() -> Double {
            let value = Double(nextUInt64() >> 11) / Double(1 << 53)
            return value * 2.0 - 1.0
        }
    }

    private static func sketchyAmplitude(for stroke: StrokeStyle, span: Double) -> Double {
        let base = min(max(1.2, stroke.width * 0.45), 3.5)
        return min(base, max(0.4, span * 0.06))
    }

    private static func appendSketchySegment(
        from a: CGPoint,
        to b: CGPoint,
        amplitude: Double,
        rng: inout SketchyRandom,
        to path: CGMutablePath,
        moveToStart: Bool
    ) {
        let dx = Double(b.x - a.x)
        let dy = Double(b.y - a.y)
        let len = (dx * dx + dy * dy).squareRoot()
        let nx = len > 0 ? -dy / len : 0
        let ny = len > 0 ? dx / len : 0

        let startJitter = CGPoint(
            x: Double(a.x) + rng.nextUnit() * amplitude * 0.35,
            y: Double(a.y) + rng.nextUnit() * amplitude * 0.35
        )
        let endJitter = CGPoint(
            x: Double(b.x) + rng.nextUnit() * amplitude * 0.35,
            y: Double(b.y) + rng.nextUnit() * amplitude * 0.35
        )
        let bow = rng.nextUnit() * amplitude
        let along = rng.nextUnit() * amplitude * 0.4
        let control = CGPoint(
            x: Double(a.x + b.x) / 2 + nx * bow + (len > 0 ? (dx / len) * along : 0),
            y: Double(a.y + b.y) / 2 + ny * bow + (len > 0 ? (dy / len) * along : 0)
        )

        if moveToStart {
            path.move(to: startJitter)
        } else {
            path.addLine(to: startJitter)
        }
        path.addQuadCurve(to: endJitter, control: control)
    }

    private static func strokeSketchyPass(
        _ path: CGPath,
        stroke: StrokeStyle,
        pass: Int,
        in context: CGContext
    ) {
        let passStyle: StrokeStyle
        if pass == 0 {
            passStyle = stroke
        } else {
            let secondaryColor = RGBAColor(
                r: stroke.color.r,
                g: stroke.color.g,
                b: stroke.color.b,
                a: stroke.color.a * 0.72
            )
            passStyle = StrokeStyle(
                color: secondaryColor,
                width: max(0.8, stroke.width * 0.78),
                dash: stroke.dash,
                isSketchy: stroke.isSketchy
            )
        }
        context.addPath(path)
        configureStroke(passStyle, in: context)
        context.strokePath()
    }

    // MARK: - 描边配置

    private static func configureStroke(_ stroke: StrokeStyle, in context: CGContext) {
        context.setStrokeColor(stroke.color.cgColor)
        context.setLineWidth(max(0, stroke.width))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if let dash = stroke.dash, !dash.isEmpty {
            context.setLineDash(phase: 0, lengths: dash.map { CGFloat(max(0, $0)) })
        } else {
            context.setLineDash(phase: 0, lengths: [])
        }
    }
}

// MARK: - 模型到 CoreGraphics 的桥接

extension PixelPoint {
    /// 转换为 `CGPoint`。
    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

extension PixelSize {
    /// 转换为 `CGSize`。
    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

extension PixelRect {
    /// 转换为 `CGRect`。
    public var cgRect: CGRect {
        CGRect(origin: origin.cgPoint, size: size.cgSize)
    }
}

extension RGBAColor {
    /// 转换为 `CGColor`（sRGB）。
    ///
    /// 模型使用的是非预乘的 sRGB 分量，与 `CGColor` 的语义一致，
    /// 因此这里不需要做任何预乘处理。
    public var cgColor: CGColor {
        CGColor(
            colorSpace: ImageColorSpace.sRGB,
            components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)]
        ) ?? CGColor(gray: 0, alpha: CGFloat(a))
    }
}
