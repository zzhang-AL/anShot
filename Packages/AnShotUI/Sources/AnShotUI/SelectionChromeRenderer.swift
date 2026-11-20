//
//  SelectionChromeRenderer.swift
//  AnShotUI
//
//  选区外观的绘制：边框、圆角、缩放手柄、像素尺寸标签。
//
//  ── 与 `AnnotationRenderer` 的分工 ─────────────────────────
//
//  `AnnotationRenderer`（AnShotCore）画的是**标注内容**：箭头、方框、马赛克等，
//  与选区本身无关。这里画的是**选区怎么呈现**：边框、八个手柄、尺寸标签。
//  两者都只接收值、不持有视图状态，因此渲染结果可以脱离视图验证。
//
//  ── 为什么输入是一个结构而不是一长串参数 ───────────────────
//
//  九个参数的调用点读不出谁是谁，而 `isConfirmed` 与 `isCreating` 这类
//  同类型相邻参数一旦传反，编译器不会报警（两者都是 `Bool`），
//  只有在屏幕上才能看出来。具名结构把每个值的含义绑在调用点上。
//

import AnShotCapture
import AnShotCore
import AppKit
import CoreText

/// 选区的边框、手柄与尺寸标签。
@MainActor
enum SelectionChromeRenderer {

    /// 一次绘制所需的全部状态（都是值，绘制期间不再改变）。
    struct Chrome {
        /// 原始选区，**本视图坐标（左上原点）**。
        let selection: CGRect
        /// 本视图（= 本屏）边界：尺寸标签避让与贴屏幕角判定都读它。
        let viewBounds: CGRect
        /// 本视图所在显示器，决定贴角时读谁的物理圆角。
        let displayID: CGDirectDisplayID
        /// 逻辑点 → 像素缩放（尺寸标签显示像素）。
        let scaleFactor: CGFloat
        let decoration: SelectionDecoration
        /// 选区是否已由用户确认。
        let isConfirmed: Bool
        /// 是否正在拖拽创建。
        let isCreating: Bool
        let activeHandle: SelectionHandle?
        let hoveredHandle: SelectionHandle?
        /// 屏幕顶部安全边距（避开刘海/菜单栏）。
        var topSafeInset: CGFloat = 0
        /// 光标是否正悬停在尺寸胶囊平移把手上。
        var isSizeLabelHovered: Bool = false
        /// 是否正在按住尺寸胶囊平移整个选区。
        var isSizeLabelActive: Bool = false
    }

    /// 绘制边框、手柄与尺寸标签。
    static func draw(_ chrome: Chrome, in context: CGContext) {
        drawBorder(for: chrome, in: context)
        // 缩放手柄只在**已确认**后出现。候选态画出八个控件等于宣告
        // 「选区已定」，而它随时会被下一次识别替换；也正因如此，
        // 候选态的按下拖拽含义是重新框选而不是调整——两者必须一致，
        // 否则又是「看不见却能点中」。
        if !chrome.isCreating, chrome.isConfirmed {
            drawHandles(for: chrome, in: context)
        }
        drawSizeLabel(for: chrome, in: context)
    }

    private static let sizeLabelFont: CTFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium) as CTFont
    private static let sizeLabelTextColor: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// 构造纯 CoreText 尺寸文本行（绕开 AppKit `NSString.size(withAttributes:)` 高频重绘触发的字典深拷贝异常）。
    private static func makeSizeLabelLine(_ text: String) -> (line: CTLine, width: CGFloat, height: CGFloat, ascent: CGFloat) {
        let cfText = text as CFString
        let attrStr = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attrStr, CFRange(location: 0, length: 0), cfText)
        let range = CFRange(location: 0, length: CFAttributedStringGetLength(attrStr))
        CFAttributedStringSetAttribute(attrStr, range, kCTFontAttributeName, sizeLabelFont)
        CFAttributedStringSetAttribute(attrStr, range, kCTForegroundColorAttributeName, sizeLabelTextColor)
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return (line, width, ascent + descent, ascent)
    }

    /// 绘制选区边框（未确认候选态附加极轻主题色微光填充，配合全屏原亮度静止零闪烁呈现吸附目标）。
    private static func drawBorder(for chrome: Chrome, in context: CGContext) {
        let decorated = SelectionHandleLayout.decoratedRect(for: chrome.selection)
        let cornerRadii = radii(for: chrome)
        if !chrome.isConfirmed, !chrome.isCreating {
            let fillPath = CaptureFrameStyle.roundedPath(in: decorated, radii: cornerRadii)
            context.saveGState()
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor)
            context.addPath(fillPath)
            context.fillPath()
            context.restoreGState()
        }
        CaptureFrameStyle.drawBorder(
            in: decorated,
            color: CaptureFrameStyle.selection,
            lineWidth: CaptureFrameStyle.selectionStrokeWidth,
            radii: cornerRadii,
            dash: chrome.isConfirmed ? nil : CaptureFrameStyle.candidateDashPattern,
            in: context
        )
    }

    /// 本选区的四角圆角（贴屏幕角时逐角取屏幕半径）。
    private static func radii(for chrome: Chrome) -> CaptureFrameStyle.CornerRadii {
        SelectionHandleLayout.cornerRadii(
            for: chrome.selection,
            viewBounds: chrome.viewBounds,
            displayID: chrome.displayID
        )
    }

    /// 本选区的手柄布局（与命中测试、光标同一份）。
    private static func items(for chrome: Chrome) -> [SelectionHandleLayout.Item] {
        SelectionHandleLayout.items(
            for: chrome.selection,
            viewBounds: chrome.viewBounds,
            displayID: chrome.displayID,
            decoration: chrome.decoration,
            activeHandle: chrome.activeHandle
        )
    }

    private static func drawHandles(for chrome: Chrome, in context: CGContext) {
        let size = SelectionHandleLayout.decoratedRect(for: chrome.selection).size
        // 角括号的圆角必须与**该角**的边框圆角同值：否则贴屏幕角时边框已经沿着
        // 屏幕圆弧走，括号还在那里拐一个小弧，两者在同一处错开。
        let radii = radii(for: chrome)

        for item in items(for: chrome) {
            let isActive = item.handle == chrome.activeHandle
            let isHighlighted = isActive || item.handle == chrome.hoveredHandle
            // 高亮（更亮的蓝）只给悬停或正在操作的控件；常态手柄保持白色，
            // 避免选框上排出一圈彩色标记把边框的主次抢走。
            let color = isHighlighted
                ? CaptureFrameStyle.highlightHandle
                : CaptureFrameStyle.idleHandle
            let strokeWidth = isHighlighted
                ? CaptureFrameStyle.handleHighlightStrokeWidth
                : CaptureFrameStyle.handleStrokeWidth

            if SelectionHandleLayout.isCorner(item.handle) {
                let radius = SelectionHandleLayout.radius(of: item.handle, in: radii)
                drawCornerBracket(
                    item,
                    cornerRadius: radius,
                    armLength: chrome.decoration.armLength(for: size, cornerRadius: radius),
                    color: color,
                    strokeWidth: strokeWidth,
                    in: context
                )
            } else {
                drawMidpointGrip(
                    item,
                    color: color,
                    isActive: isActive,
                    decoration: chrome.decoration,
                    in: context
                )
            }
        }
    }

    /// 角括号：从角点沿两条边界各延伸一段的折线（⌐ 形）。
    ///
    /// 转折处用圆弧而非直角，且半径与边框的圆角一致——
    /// 否则括号的直角拐点会正好压在边框的圆弧上，
    /// 看上去就是圆角外面又套了一个尖角。
    ///
    /// 位置取自 `SelectionHandleLayout.Item.center` 而不是重新算：绘制与命中必须是
    /// 同一个中心，否则会重现「画在这里、要往那边点」的旧缺陷。
    private static func drawCornerBracket(
        _ item: SelectionHandleLayout.Item,
        cornerRadius: CGFloat,
        armLength: CGFloat,
        color: RGBAColor,
        strokeWidth: CGFloat,
        in context: CGContext
    ) {
        let handle = item.handle
        let corner = item.center
        // 沿边界向选区内部延伸
        let dx: CGFloat = handle.movesLeftEdge ? 1 : -1
        let dy: CGFloat = handle.movesTopEdge ? 1 : -1

        // 圆弧半径不能超过臂长，否则切点会落到臂的长度之外。
        // 臂长已按「不小于该角圆角」算过，这里通常不会截小；留 `min` 防住极小选区。
        let radius = min(cornerRadius, armLength)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: corner.x + dx * armLength, y: corner.y))
        // 用「切线→切线」的圆角接法而不是算角度：视图是左上原点（y 向下），
        // 角度的正负方向会随翻转而反转，而这个接法只依赖三个点的位置。
        path.addArc(
            tangent1End: corner,
            tangent2End: CGPoint(x: corner.x, y: corner.y + dy * armLength),
            radius: max(0, radius)
        )
        path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * armLength))

        CaptureFrameStyle.strokePath(
            path,
            color: color,
            lineWidth: strokeWidth,
            lineCap: .round,
            in: context
        )
    }

    /// 中点抓手：沿边界方向的短胶囊。上/下边为横向，左/右边为纵向。
    private static func drawMidpointGrip(
        _ item: SelectionHandleLayout.Item,
        color: RGBAColor,
        isActive: Bool,
        decoration: SelectionDecoration,
        in context: CGContext
    ) {
        let center = item.center
        let isHorizontalEdge = item.handle.movesTopEdge || item.handle.movesBottomEdge
        let scale = isActive ? decoration.midpointGripActiveScale : 1
        let length = decoration.midpointGripLength * scale
        let thickness = decoration.midpointGripThickness * scale
        let size = CGSize(
            width: isHorizontalEdge ? length : thickness,
            height: isHorizontalEdge ? thickness : length
        )
        let rect = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        // 圆角取厚度的一半：两端成为半圆，整体是一个胶囊。
        // 超出上限时 CoreGraphics 自动收窄，不会画出非法路径。
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: thickness / 2,
            cornerHeight: thickness / 2,
            transform: nil
        )
        CaptureFrameStyle.fillPathWithContrast(path, color: color, in: context)
    }

    /// 计算像素尺寸胶囊矩形（绘制与鼠标拖动命中共用同一份几何，绝不漂移）。
    ///
    /// 布局策略：优先放在**选区正上方外侧居中**（与下方标注工具栏自然上下分离、一眼可见）；
    /// 上方放不下时翻到选区正下方外侧；上下都放不下（如整屏选区）时落于底边内侧居中，避开顶部工具栏。
    static func sizeLabelRect(for chrome: Chrome) -> CGRect {
        let pixelSize = CoordinateConversion.pixelRect(
            fromLogical: chrome.selection,
            scaleFactor: chrome.scaleFactor
        ).size
        let text = "\(Int(pixelSize.width.rounded())) × \(Int(pixelSize.height.rounded()))"
        let measured = makeSizeLabelLine(text)

        let showsDragGrip = chrome.isConfirmed && !chrome.isCreating
        // 预留 11pt 矢量四向移动图标 + 6pt 间距
        let gripReserve: CGFloat = showsDragGrip ? 17 : 0
        let horizontalPadding: CGFloat = 10
        let labelSize = CGSize(
            // 下限取两倍高度，保证极窄的内容（如 "9 × 9"）也得到胶囊而非圆
            width: max(ceil(measured.width) + gripReserve + horizontalPadding * 2, chrome.decoration.labelHeight * 2),
            height: chrome.decoration.labelHeight
        )

        let gap: CGFloat = 8
        let topMinY = max(4, chrome.topSafeInset + 4)
        var y = chrome.selection.minY - labelSize.height - gap
        if y < topMinY {
            y = chrome.selection.maxY + gap
        }
        if y + labelSize.height > chrome.viewBounds.maxY - 4 {
            y = chrome.viewBounds.maxY - labelSize.height - 6
        }

        // 水平：跟随选区居中，贴屏幕左右边缘时收进来。
        let margin: CGFloat = 4
        let x = min(
            max(margin, chrome.selection.midX - labelSize.width / 2),
            max(margin, chrome.viewBounds.maxX - labelSize.width - margin)
        )

        return CGRect(origin: CGPoint(x: x, y: y), size: labelSize)
    }

    /// 绘制清晰的 11×11pt 矢量四向移动图标（十字轴 + 四端箭头），直白表达可抓握平移整个选区。
    private static func drawMoveArrowsIcon(
        centeredAt center: CGPoint,
        color: CGColor,
        in context: CGContext
    ) {
        let arm: CGFloat = 5.0
        let tip: CGFloat = 2.1
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(1.25)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // 横竖十字轴
        context.move(to: CGPoint(x: center.x - arm, y: center.y))
        context.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        context.move(to: CGPoint(x: center.x, y: center.y - arm))
        context.addLine(to: CGPoint(x: center.x, y: center.y + arm))

        // 上箭头
        context.move(to: CGPoint(x: center.x - tip, y: center.y - arm + tip))
        context.addLine(to: CGPoint(x: center.x, y: center.y - arm))
        context.addLine(to: CGPoint(x: center.x + tip, y: center.y - arm + tip))
        // 下箭头
        context.move(to: CGPoint(x: center.x - tip, y: center.y + arm - tip))
        context.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        context.addLine(to: CGPoint(x: center.x + tip, y: center.y + arm - tip))
        // 左箭头
        context.move(to: CGPoint(x: center.x - arm + tip, y: center.y - tip))
        context.addLine(to: CGPoint(x: center.x - arm, y: center.y))
        context.addLine(to: CGPoint(x: center.x - arm + tip, y: center.y + tip))
        // 右箭头
        context.move(to: CGPoint(x: center.x + arm - tip, y: center.y - tip))
        context.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        context.addLine(to: CGPoint(x: center.x + arm - tip, y: center.y + tip))

        context.strokePath()
        context.restoreGState()
    }

    /// 绘制像素尺寸提示（已确认态左侧附带清晰四向移动图标，作为任意工具下平移选区的直观把手）。
    ///
    /// 显示的是**像素**而非逻辑点：用户关心的最终产物尺寸是像素，
    /// 而选区在 2x 屏上的逻辑点数值是像素的一半。
    private static func drawSizeLabel(for chrome: Chrome, in context: CGContext) {
        let pixelSize = CoordinateConversion.pixelRect(
            fromLogical: chrome.selection,
            scaleFactor: chrome.scaleFactor
        ).size
        let text = "\(Int(pixelSize.width.rounded())) × \(Int(pixelSize.height.rounded()))"
        let measured = makeSizeLabelLine(text)

        let showsDragGrip = chrome.isConfirmed && !chrome.isCreating
        let labelRect = sizeLabelRect(for: chrome)
        // 用 CGPath 而非 NSBezierPath(cgPath:)：后者是 macOS 14.0+，
        // 会超出本项目的 13.0 基线。
        let path = CGPath(
            roundedRect: labelRect,
            cornerWidth: chrome.decoration.labelCornerRadius,
            cornerHeight: chrome.decoration.labelCornerRadius,
            transform: nil
        )

        let bgColor: NSColor = if chrome.isSizeLabelActive {
            NSColor.controlAccentColor.withAlphaComponent(0.92)
        } else if chrome.isSizeLabelHovered {
            NSColor(calibratedWhite: 0.16, alpha: 0.92)
        } else {
            NSColor.black.withAlphaComponent(0.78)
        }

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 1),
            blur: 3,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
        )
        context.setFillColor(bgColor.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        // 悬停或拖动激活时高亮边框，直观传达可抓取交互反馈。
        let borderColor: NSColor = if chrome.isSizeLabelActive {
            NSColor.white.withAlphaComponent(0.65)
        } else if chrome.isSizeLabelHovered {
            NSColor.controlAccentColor.withAlphaComponent(0.9)
        } else {
            NSColor.white.withAlphaComponent(0.2)
        }
        context.saveGState()
        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(chrome.isSizeLabelHovered || chrome.isSizeLabelActive ? 1.25 : 1)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()

        let textTopY = labelRect.midY - measured.height / 2
        if showsDragGrip {
            let iconSize: CGFloat = 11
            let iconGap: CGFloat = 6
            let contentWidth = iconSize + iconGap + measured.width
            let startX = labelRect.midX - contentWidth / 2
            let iconColor = NSColor.white.withAlphaComponent(
                (chrome.isSizeLabelHovered || chrome.isSizeLabelActive) ? 1.0 : 0.88
            ).cgColor
            drawMoveArrowsIcon(
                centeredAt: CGPoint(x: startX + iconSize / 2, y: labelRect.midY),
                color: iconColor,
                in: context
            )

            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: startX + iconSize + iconGap, y: textTopY + measured.ascent)
            CTLineDraw(measured.line, context)
            context.restoreGState()
        } else {
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: labelRect.midX - measured.width / 2, y: textTopY + measured.ascent)
            CTLineDraw(measured.line, context)
            context.restoreGState()
        }
    }
}
