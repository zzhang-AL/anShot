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

import CoreGraphics
import CoreText
import Foundation

/// 标注合成渲染器。
public enum AnnotationRenderer {
    /// 渲染管线可用的色彩空间（sRGB）。
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

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
        let x0 = min(max(0, Int(selection.origin.x.rounded(.down))), backdropWidth)
        let y0 = min(max(0, Int(selection.origin.y.rounded(.down))), backdropHeight)
        let x1 = min(max(0, Int((selection.origin.x + selection.size.width).rounded(.up))), backdropWidth)
        let y1 = min(max(0, Int((selection.origin.y + selection.size.height).rounded(.up))), backdropHeight)

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

        guard let context = CGContext(
            data: nil,
            width: rect.width,
            height: rect.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
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
            drawRectangle(rect, stroke: stroke, fill: fill, cornerRadius: cornerRadius, in: context)

        case let .line(start, end, stroke):
            drawLine(start, end, stroke: stroke, in: context)

        case let .arrow(start, end, stroke, headLength, headWidth):
            drawArrow(
                start: start,
                end: end,
                stroke: stroke,
                headLength: headLength,
                headWidth: headWidth,
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
            drawMeasure(start: start, end: end, stroke: stroke, in: context)

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
            drawFreehand(points, stroke: stroke, in: context)

        case let .curvedArrow(start, control, end, stroke, headLength, headWidth):
            drawCurvedArrow(
                start: start,
                control: control,
                end: end,
                stroke: stroke,
                headLength: headLength,
                headWidth: headWidth,
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

    private static func drawRectangle(
        _ rect: PixelRect,
        stroke: StrokeStyle,
        fill: RGBAColor?,
        cornerRadius: Double,
        in context: CGContext
    ) {
        let cgRect = rect.cgRect
        guard cgRect.width > 0, cgRect.height > 0 else {
            return
        }

        let radius = max(0, cornerRadius)
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

        // 描边居中于路径：与 CoreGraphics 默认语义一致，不额外内缩。
        context.addPath(path)
        configureStroke(stroke, in: context)
        context.strokePath()
    }

    private static func drawLine(
        _ start: PixelPoint,
        _ end: PixelPoint,
        stroke: StrokeStyle,
        in context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }

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

        // 字号随半径走：固定字号在半径小的时候会撑满整个圆，半径大时又显得空。
        let font = FontDescriptor.system(size: max(9, radius * 1.1))
        drawCenteredText("\(index)", center: center.cgPoint, font: font, color: textColor, in: context)
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

    /// 测量：两点连线 + 中点处的距离读数（像素）。
    ///
    /// 只画读数不画单位：单位换算属 UI 层（契约 §2.2），
    /// 模型存的是底图像素，导出图上的数字必须与像素一致。
    private static func drawMeasure(
        start: PixelPoint,
        end: PixelPoint,
        stroke: StrokeStyle,
        in context: CGContext
    ) {
        drawLine(start, end, stroke: stroke, in: context)

        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length >= 1 else {
            return
        }

        // 读数贴着中点上方：字号跟线宽走，细线不至于读出大字。
        let font = FontDescriptor.system(size: max(10, stroke.width * 6))
        let center = CGPoint(
            x: (start.x + end.x) / 2,
            y: (start.y + end.y) / 2 - max(10, stroke.width * 6)
        )
        drawCenteredText("\(Int(length.rounded()))", center: center, font: font, color: stroke.color, in: context)
    }

    /// 放大镜：把圆心处一小块底图放大后画回圆形区域。
    ///
    /// 与马赛克同类——都需要读**当前画布**的像素。这里取整幅画布的快照后裁出源矩形，
    /// 而不是逐像素搬：放大是按倍率重采样，交给 CoreGraphics 的插值质量更好。
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

        // 源矩形比目标小 `zoom` 倍，且要在**画布图像坐标**下给出：
        // 画布含留白，内容的原点在 `canvasOrigin`（makeCanvas 建立的坐标系）。
        let sourceRect = CGRect(
            x: canvasOrigin.x + center.x - radius / zoom,
            y: canvasOrigin.y + center.y - radius / zoom,
            width: radius * 2 / zoom,
            height: radius * 2 / zoom
        )

        context.saveGState()
        defer { context.restoreGState() }

        if let snapshot = context.makeImage(), let source = snapshot.cropping(to: sourceRect) {
            context.addPath(path)
            context.clip()
            context.interpolationQuality = .high
            context.draw(source, in: destRect)
        }

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
        in context: CGContext
    ) {
        guard points.count >= 2 else {
            return
        }
        let path = CGMutablePath()
        path.move(to: points[0].cgPoint)

        if points.count == 2 {
            path.addLine(to: points[1].cgPoint)
        } else {
            // 以每个采样点为控制点、相邻两点的中点为端点：
            // 曲线恰好穿过中点，不会像直接连折线那样出现尖角。
            for index in 1..<(points.count - 1) {
                let current = points[index].cgPoint
                let next = points[index + 1].cgPoint
                let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
                path.addQuadCurve(to: mid, control: current)
            }
            path.addLine(to: points[points.count - 1].cgPoint)
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(path)
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
        in context: CGContext
    ) {
        // 头部方向取**终点切线**（end − control），不是 start→end 的弦方向：
        // 曲线末端可能与弦差很多，用弦会让箭头头部歪出曲线。
        let tangentX = end.x - control.x
        let tangentY = end.y - control.y
        let tangentLength = (tangentX * tangentX + tangentY * tangentY).squareRoot()
        guard tangentLength > 0 else {
            drawLine(start, end, stroke: stroke, in: context)
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

        let ctFont = TextMetrics.font(for: font)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: ctFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color.cgColor,
        ]

        var baselineY = origin.y

        if let maxWidth, maxWidth > 0 {
            // 有宽度约束时才交给 typesetter 做断行分析。
            // 无约束时不传「极大宽度」而改为按显式换行符分行，是为了让语义准确
            // （「不约束宽度」不应靠一个假宽度来表达），也省掉一次无谓的断行分析。
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var index = 0

            while index < attributed.length {
                let count = CTTypesetterSuggestLineBreak(typesetter, index, maxWidth)
                guard count > 0 else {
                    break
                }

                let line = CTTypesetterCreateLine(
                    typesetter,
                    CFRange(location: index, length: count)
                )
                baselineY = drawTextLine(
                    line,
                    x: origin.x,
                    baselineY: baselineY,
                    background: background,
                    in: context
                )
                index += count
            }
        } else {
            // 无宽度约束：只在显式换行符处分行，不做宽度分析。
            let fragments = text.split(separator: "\n", omittingEmptySubsequences: false)
            let emptyLineHeight = fontLineHeight(ctFont)

            for fragment in fragments {
                if fragment.isEmpty {
                    // 空行没有字形，用字体行高推进基线，保持行间距一致。
                    baselineY += emptyLineHeight
                    continue
                }

                let attributed = NSAttributedString(string: String(fragment), attributes: attributes)
                let line = CTLineCreateWithAttributedString(attributed)
                baselineY = drawTextLine(
                    line,
                    x: origin.x,
                    baselineY: baselineY,
                    background: background,
                    in: context
                )
            }
        }
    }

    /// 绘制一行文字，返回下一行的基线 y。
    private static func drawTextLine(
        _ line: CTLine,
        x: Double,
        baselineY: Double,
        background: RGBAColor?,
        in context: CGContext
    ) -> Double {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let lineHeight = Double(ascent + descent + leading)

        if let background {
            // 底色紧贴该行的排版盒：上边为基线再加 ascent。
            let box = CGRect(
                x: x,
                y: baselineY - Double(ascent),
                width: Double(width),
                height: lineHeight
            )
            context.setFillColor(background.cgColor)
            context.fill(box)
        }

        context.textPosition = CGPoint(x: x, y: baselineY)
        CTLineDraw(line, context)

        return baselineY + lineHeight
    }

    /// 字体自身的行高（ascent + descent + leading）。
    private static func fontLineHeight(_ font: CTFont) -> Double {
        Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
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

    /// 像素化马赛克。
    ///
    /// 直接读写位图数据而不经过 CoreGraphics 绘制：
    /// 这是唯一需要「读回像素」的标注，走绘制路径无法实现。
    ///
    /// 正因为它是直接寻址位图，调用者必须提供 `canvasOrigin`：
    /// CGContext 的变换只影响矢量绘制，**不会**改变 `context.data` 的索引基准。
    ///
    /// 块网格**锚定在底图原点**。块号由底图坐标决定，与拖动框或笔画的起点无关；
    /// 若按「框的左上角」起算，同一区域先后刷两次会得到两套网格，
    /// 拼缝处会出现半块错位。
    private static func applyMosaic(
        coverage: MosaicCoverage,
        mode: MosaicMode,
        intensity: Double,
        in context: CGContext,
        canvasOrigin: PixelPoint,
        canvasWidth: Int,
        canvasHeight: Int
    ) {
        // M1 只实现 pixelate；其余模式在契约中预留，此处静默跳过而非中断整幅渲染。
        guard mode == .pixelate else {
            return
        }

        let blockSize = max(2, Int(intensity.rounded()))
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

        // 向下取整地求块号：块网格锚定在底图原点，
        // 因此块号 = floor(底图坐标 / 块边长)。
        let firstBlockX = Int(floor(Double(canvasX0 + originX) / Double(blockSize)))
        let lastBlockX = Int(floor(Double(canvasX1 - 1 + originX) / Double(blockSize)))
        let firstBlockY = Int(floor(Double(canvasY0 + originY) / Double(blockSize)))
        let lastBlockY = Int(floor(Double(canvasY1 - 1 + originY) / Double(blockSize)))

        let halfDiagonal = Double(blockSize) * 0.7072

        // 涂抹：先把笔迹描成一条粗线作为**覆盖掩码**，再逐像素查表。
        //
        // 不能逐像素问 `coverage.covers`：对 `.stroke` 它要算到整条路径的
        // 距离（O(点数)），于是总成本变成 O(覆盖像素 × 点数)。实测
        // 2000×1500 选区（300 万像素）配 300 个点是 **6.5 秒/帧**——
        // 用户感受到的「涂抹很卡」就是它。把描线交给 CoreGraphics 后，
        // 每像素只剩一次查表（O(1)）。
        var maskContext: CGContext?
        var maskBuffer: UnsafeMutablePointer<UInt8>?
        var digestContext: CGContext?
        var digestBuffer: UnsafeMutablePointer<UInt8>?
        if case let .stroke(points, radius) = coverage {
            maskContext = makeStrokeMask(
                points: points,
                radius: radius,
                originX: originX,
                originY: originY,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight
            )
            maskBuffer = maskContext?.data?.assumingMemoryBound(to: UInt8.self)

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

                // 块级预筛之一：笔迹的块摘要。摘要为 0 的块整块跳过。
                //
                // 这是涂抹最重要的一层优化：包围盒对「手抖、来回涂」的笔迹
                // 会迅速膨胀（实测弯曲笔迹的包围盒覆盖 11385 块，实际只经过
                // 约 500 块），多算的二十倍全花在空块上。
                if let digestBuffer, let digestContext {
                    let dx = blockX - firstBlockX
                    let dy = blockY - firstBlockY
                    if digestBuffer[dy * digestContext.bytesPerRow + dx] == 0 {
                        continue
                    }
                }

                // 块级预筛之二（仅几何覆盖需要，矩形与笔迹都走不到这里）：
                // 块很小，块中心到路径的距离与块内任意点的偏差不超过半对角线。
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
                    maskBytesPerRow: maskContext?.bytesPerRow ?? 0,
                    originX: originX,
                    originY: originY,
                    buffer: buffer,
                    bytesPerRow: bytesPerRow
                )
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

    /// 把笔迹描成一条粗线，作为涂抹的覆盖掩码。
    ///
    /// 描线交给 CoreGraphics：它是高度优化的扫描线填充，比在 Swift 里
    /// 逐像素算距离快几个数量级，也不需要自己处理圆头、圆转角与重叠段。
    ///
    /// 掩码是 8 位灰度、与画布同尺寸，**非零即覆盖**。
    private static func makeStrokeMask(
        points: [PixelPoint],
        radius: Double,
        originX: Int,
        originY: Int,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> CGContext? {
        guard canvasWidth > 0, canvasHeight > 0, let first = points.first else {
            return nil
        }
        guard let mask = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: canvasWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        mask.setFillColor(gray: 0, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        mask.setStrokeColor(gray: 1, alpha: 1)
        // 直径 = 2 × 半径。半径可能小于 1（阈值下限），描出 0 宽度会什么都画不出。
        mask.setLineWidth(max(1, CGFloat(radius) * 2))
        mask.setLineCap(.round)
        mask.setLineJoin(.round)

        // 画布坐标是**左上原点**（模型坐标 − 画布原点），而 CGContext 位图
        // 的原点在左下。不翻的话笔迹会上下镜像——马赛克会出现在对称的位置。
        mask.translateBy(x: 0, y: CGFloat(canvasHeight))
        mask.scaleBy(x: 1, y: -1)

        func canvasPoint(_ point: PixelPoint) -> CGPoint {
            CGPoint(x: CGFloat(point.x) - CGFloat(originX), y: CGFloat(point.y) - CGFloat(originY))
        }

        mask.beginPath()
        mask.move(to: canvasPoint(first))
        for point in points.dropFirst() {
            mask.addLine(to: canvasPoint(point))
        }
        // 单点笔迹：补一段零长度线段，靠 round cap 画出一个圆盘。
        if points.count == 1 {
            mask.addLine(to: canvasPoint(first))
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
        /// 涂抹走掩码查表（O(1)），矩形仍走几何判定（本身就是 O(1)）。
        /// 两者语义相同：掩码就是「几何判定」预先光栅化的结果。
        func isCovered(_ x: Int, _ y: Int) -> Bool {
            if let mask {
                return mask[y * maskBytesPerRow + x] != 0
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
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)]
        ) ?? CGColor(gray: 0, alpha: CGFloat(a))
    }
}
