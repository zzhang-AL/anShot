//
//  AnnotationToolbarRenderer.swift
//  AnShotUI
//
//  标注工具栏的绘制：主栏与面板的背景、每个条目的图标/色卡/文字按钮。
//
//  ── 为什么它不持有视图 ────────────────────────────────────
//
//  绘制只依赖「当前工具、样式、悬停项、面板是否展开」这四个状态，
//  不依赖窗口、坐标原点或鼠标事件。抽出来之后同一份状态可以在离屏上下文里
//  渲染成图做逐像素比对——这正是不久前搬移选框绘制时验证视觉零变化的手段。
//
//  ── 命名与视图对齐 ────────────────────────────────────────
//
//  属性名与 `AnnotationToolbarView` 一致（`tool` / `style` / `hoveredKind` …），
//  因为绘制代码原本就写在这些名字上：搬移时保持同名，函数体可以原样保留，
//  不需要在几十处引用上做改名替换（改名正是搬移引入回归的主要来源）。
//

import AnShotCore
import AppKit

/// 工具栏绘制。
@MainActor
final class AnnotationToolbarRenderer {

    // MARK: - 条目身份

    typealias Kind = AnnotationToolbarLayout.Kind
    typealias Item = AnnotationToolbarLayout.Item

    // MARK: - 状态

    var tool: AnnotationTool = .pointer
    var style: AnnotationStyle = .default
    var showsToolSelection = true
    var isPanelExpanded = true
    /// 撤销/重做是否可用：决定这两个图标画成常态还是禁用态。
    var canUndo = false
    var canRedo = false
    /// 与 `AnnotationToolbarView` 同名同义：决定抓屏动作是否参与布局。
    var allowsCaptureActions = true
    /// 指针工具下是否有选中标注（决定面板内容）。
    var hasSelectedAnnotation = false
    /// 选中的标注是否是文字（面板用字号档位代替线宽滑块）。
    var selectedAnnotationIsText = false
    /// 选中的标注是否是高亮荧光笔（面板改用半透明荧光色板）。
    var selectedAnnotationIsHighlight = false
    /// 选中的标注颜色（指针模式有选中时，优先用于色卡选中态对齐）。
    var selectedAnnotationColor: RGBAColor?
    /// 当前在面板高亮匹配的逻辑点字号（来自选中文字或正在编辑的草稿）。
    var activeFontSizeForToolbar: Double?
    /// 选中的标注是否有颜色 / 线宽 / 手绘 / 打码效果可改（决定面板条目的存在与否）。
    var selectedAnnotationSupportsColor = true
    var selectedAnnotationSupportsLineWidth = true
    var selectedAnnotationSupportsSketchy = false
    var selectedAnnotationIsSketchy = false
    var selectedAnnotationSupportsFill = false
    var selectedAnnotationIsFilled = false
    var selectedAnnotationIsBold = false
    var selectedAnnotationIsItalic = false
    var selectedAnnotationFontFamily: String?
    var selectedAnnotationIsSpotlight = false
    var selectedAnnotationSpotlightDimOpacity: Double?
    var selectedAnnotationSupportsMosaicEffect = false
    var selectedAnnotationMosaicMode: MosaicMode?
    var selectedAnnotationMosaicBlockSize: Double?
    var panelPlacement: AnnotationToolbarLayout.PanelPlacement = .below
    var hiddenSlots: Set<String> = []
    var hoveredKind: AnnotationToolbarLayout.Kind?
    /// 当前正被鼠标按下的条目（提供即时按压反馈，移出按钮松手可安全取消）。
    var pressedKind: AnnotationToolbarLayout.Kind?
    /// 当前外观是否为深色（默认深色碳墨浮岛；随设置窗口与系统浅/深模式实时响应）。
    var isDarkAppearance = true

    /// 供下层手绘字形读取的当前条目墨水色（选中态恒为纯白；浅色/深色自适应高对比前景色）。
    private var currentGlyphInkColor: NSColor = .white

    private struct ToolbarPalette {
        let barTop: NSColor
        let barBottom: NSColor
        let panelTop: NSColor
        let panelBottom: NSColor
        let border: NSColor
        let topInnerHighlight: NSColor
        let separator: NSColor
        let primaryInk: NSColor
        let secondaryInk: NSColor
        let hoverFill: NSColor
        let copyIdleFill: NSColor
        let copyHoverFill: NSColor
        let copyInk: NSColor
        let dangerHoverFill: NSColor
        let dangerInk: NSColor
        let sliderTrack: NSColor
        let swatchSelectedRing: NSColor
        let swatchHoverRing: NSColor

        static func resolve(isDark: Bool) -> ToolbarPalette {
            if isDark {
                return ToolbarPalette(
                    barTop: NSColor(srgbRed: 0.165, green: 0.176, blue: 0.204, alpha: 0.94),
                    barBottom: NSColor(srgbRed: 0.102, green: 0.110, blue: 0.130, alpha: 0.96),
                    panelTop: NSColor(srgbRed: 0.145, green: 0.156, blue: 0.184, alpha: 0.94),
                    panelBottom: NSColor(srgbRed: 0.094, green: 0.102, blue: 0.122, alpha: 0.96),
                    border: NSColor.white.withAlphaComponent(0.15),
                    topInnerHighlight: NSColor.white.withAlphaComponent(0.07),
                    separator: NSColor.white.withAlphaComponent(0.15),
                    primaryInk: NSColor.white.withAlphaComponent(0.94),
                    secondaryInk: NSColor.white.withAlphaComponent(0.68),
                    hoverFill: NSColor.white.withAlphaComponent(0.12),
                    copyIdleFill: NSColor(srgbRed: 0.20, green: 0.78, blue: 0.52, alpha: 0.18),
                    copyHoverFill: NSColor(srgbRed: 0.20, green: 0.78, blue: 0.52, alpha: 0.30),
                    copyInk: NSColor(srgbRed: 0.42, green: 0.94, blue: 0.68, alpha: 1.0),
                    dangerHoverFill: NSColor(srgbRed: 0.98, green: 0.32, blue: 0.30, alpha: 0.24),
                    dangerInk: NSColor(srgbRed: 1.0, green: 0.45, blue: 0.43, alpha: 1.0),
                    sliderTrack: NSColor.white.withAlphaComponent(0.22),
                    swatchSelectedRing: NSColor.white.withAlphaComponent(0.95),
                    swatchHoverRing: NSColor.white.withAlphaComponent(0.45)
                )
            } else {
                return ToolbarPalette(
                    barTop: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.95),
                    barBottom: NSColor(srgbRed: 0.955, green: 0.962, blue: 0.976, alpha: 0.96),
                    panelTop: NSColor(srgbRed: 0.992, green: 0.995, blue: 1.0, alpha: 0.95),
                    panelBottom: NSColor(srgbRed: 0.948, green: 0.956, blue: 0.972, alpha: 0.96),
                    border: NSColor.black.withAlphaComponent(0.11),
                    topInnerHighlight: NSColor.white.withAlphaComponent(0.92),
                    separator: NSColor.black.withAlphaComponent(0.10),
                    primaryInk: NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 0.92),
                    secondaryInk: NSColor(srgbRed: 0.28, green: 0.31, blue: 0.37, alpha: 0.75),
                    hoverFill: NSColor.black.withAlphaComponent(0.065),
                    copyIdleFill: NSColor(srgbRed: 0.08, green: 0.66, blue: 0.42, alpha: 0.13),
                    copyHoverFill: NSColor(srgbRed: 0.08, green: 0.66, blue: 0.42, alpha: 0.22),
                    copyInk: NSColor(srgbRed: 0.05, green: 0.52, blue: 0.32, alpha: 1.0),
                    dangerHoverFill: NSColor(srgbRed: 0.92, green: 0.22, blue: 0.20, alpha: 0.14),
                    dangerInk: NSColor(srgbRed: 0.86, green: 0.18, blue: 0.18, alpha: 1.0),
                    sliderTrack: NSColor.black.withAlphaComponent(0.14),
                    swatchSelectedRing: NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 0.88),
                    swatchHoverRing: NSColor.black.withAlphaComponent(0.32)
                )
            }
        }
    }

    private var palette: ToolbarPalette {
        ToolbarPalette.resolve(isDark: isDarkAppearance)
    }

    /// 结合条目语义色与禁用态透明度的统一字形墨水色。
    private func ink(_ alpha: CGFloat) -> NSColor {
        currentGlyphInkColor.withAlphaComponent(currentGlyphInkColor.alphaComponent * alpha)
    }

    // MARK: - 布局

    private var layoutInput: AnnotationToolbarLayout {
        var input = AnnotationToolbarLayout()
        input.tool = tool
        input.style = style
        input.canUndo = canUndo
        input.canRedo = canRedo
        input.isPanelExpanded = isPanelExpanded
        input.allowsCaptureActions = allowsCaptureActions
        input.hasSelectedAnnotation = hasSelectedAnnotation
        input.selectedAnnotationIsText = selectedAnnotationIsText
        input.selectedAnnotationIsHighlight = selectedAnnotationIsHighlight
        input.selectedAnnotationSupportsColor = selectedAnnotationSupportsColor
        input.selectedAnnotationSupportsLineWidth = selectedAnnotationSupportsLineWidth
        input.selectedAnnotationSupportsSketchy = selectedAnnotationSupportsSketchy
        input.selectedAnnotationSupportsFill = selectedAnnotationSupportsFill
        input.selectedAnnotationIsSpotlight = selectedAnnotationIsSpotlight
        input.selectedAnnotationSupportsMosaicEffect = selectedAnnotationSupportsMosaicEffect
        input.panelPlacement = panelPlacement
        input.hiddenSlots = hiddenSlots
        return input
    }

    private func layoutBar() -> (items: [AnnotationToolbarLayout.Item], size: CGSize) {
        layoutInput.layoutBar()
    }

    private func layoutPanel() -> (items: [AnnotationToolbarLayout.Item], size: CGSize) {
        layoutInput.layoutPanel()
    }

    var barSize: CGSize { layoutInput.barSize }

    // 布局常量转发：数值只有一份（在布局类型里）。
    private var itemSpacing: CGFloat { AnnotationToolbarLayout.itemSpacing }

    // MARK: - 入口

    /// 绘制整个工具栏（主栏 + 二级尖角气泡 + 组间细分隔线 + 全部条目）。
    func draw(in context: CGContext) {
        let bar = layoutBar()
        let panel = layoutPanel()

        drawBarBackground(bar.size, in: context)
        drawPanelBackground(panel.size, in: context)

        drawGroupSeparators(for: bar.items, containerOriginY: layoutInput.barOriginY, containerHeight: bar.size.height, in: context)
        if panel.size.height > 0 {
            drawGroupSeparators(for: panel.items, containerOriginY: layoutInput.panelOriginY, containerHeight: panel.size.height, in: context)
        }

        for item in bar.items {
            drawItem(item, in: context, isInPanel: false)
        }
        for item in panel.items {
            drawItem(item, in: context, isInPanel: true)
        }
    }

    /// 组间精致竖向细分隔线：凡相邻条目间距达到 `groupSpacing`，在其水平正中绘制圆头细线。
    private func drawGroupSeparators(
        for items: [Item],
        containerOriginY: CGFloat,
        containerHeight: CGFloat,
        in context: CGContext
    ) {
        guard items.count >= 2 else { return }
        let sorted = items.sorted { $0.rect.minX < $1.rect.minX }
        let sepHeight = min(16, max(10, containerHeight - 20))
        let topY = containerOriginY + (containerHeight - sepHeight) / 2
        let threshold = AnnotationToolbarLayout.groupSpacing - 0.5

        context.saveGState()
        context.setStrokeColor(palette.separator.cgColor)
        context.setLineWidth(AnnotationToolbarLayout.separatorWidth)
        context.setLineCap(.round)
        for (prev, next) in zip(sorted, sorted.dropFirst()) {
            let gap = next.rect.minX - prev.rect.maxX
            guard gap >= threshold else { continue }
            let x = ((prev.rect.maxX + next.rect.minX) / 2).rounded() + 0.5
            context.beginPath()
            context.move(to: CGPoint(x: x, y: topY))
            context.addLine(to: CGPoint(x: x, y: topY + sepHeight))
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawBarBackground(_ size: CGSize, in context: CGContext) {
        let originY = layoutInput.barOriginY
        let rect = CGRect(origin: CGPoint(x: 0, y: originY), size: size)
        let radius: CGFloat = 11
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        drawGlassSurface(
            path: path,
            bounds: rect,
            topColor: palette.barTop,
            bottomColor: palette.barBottom,
            in: context
        )
        // 顶部柔和微反光，收在圆角内侧避免与外描边产生双线。
        let highlightRect = rect.insetBy(dx: radius + 4, dy: 0)
        if highlightRect.width > 4 {
            context.saveGState()
            context.setStrokeColor(palette.topInnerHighlight.cgColor)
            context.setLineWidth(0.75)
            context.beginPath()
            context.move(to: CGPoint(x: highlightRect.minX, y: rect.minY + 1.1))
            context.addLine(to: CGPoint(x: highlightRect.maxX, y: rect.minY + 1.1))
            context.strokePath()
            context.restoreGState()
        }

        // 主栏最左端 6 点微粒拖拽握把（2 列 × 3 行），低干扰暗示可拖动移位、双击复位。
        drawDragHandleDots(in: rect, context: context)
    }

    private func drawDragHandleDots(in barRect: CGRect, context: CGContext) {
        let dotSize: CGFloat = 1.9
        let colGap: CGFloat = 3.2
        let rowGap: CGFloat = 3.8
        let centerX = barRect.minX + AnnotationToolbarLayout.padding + 1.5
        let centerY = barRect.midY

        context.saveGState()
        context.setFillColor(palette.secondaryInk.withAlphaComponent(isDarkAppearance ? 0.36 : 0.32).cgColor)
        for col in 0 ..< 2 {
            for row in -1 ... 1 {
                let x = centerX + (CGFloat(col) - 0.5) * colGap - dotSize / 2
                let y = centerY + CGFloat(row) * rowGap - dotSize / 2
                context.fillEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
            }
        }
        context.restoreGState()
    }

    /// 绘制二级气泡面板背景及平滑一体化的 `▲`/`▼` 尖角轮廓（水平自动对齐激活工具中心）。
    private func drawPanelBackground(_ size: CGSize, in context: CGContext) {
        guard size.height > 0 else { return }
        let input = layoutInput
        let rect = input.panelFrame
        guard rect.height > 0 else { return }
        let radius: CGFloat = 10
        let halfW = AnnotationToolbarLayout.panelArrowWidth / 2
        let arrowH = AnnotationToolbarLayout.panelArrowHeight
        let rawAnchorX = input.panelAnchorX()
        let anchorX = min(max(rawAnchorX, rect.minX + radius + halfW + 2), rect.maxX - radius - halfW - 2)

        let path = makePopoverBubblePath(
            rect: rect,
            cornerRadius: radius,
            arrowCenterX: anchorX,
            arrowHalfWidth: halfW,
            arrowHeight: arrowH,
            placement: input.panelPlacement
        )
        let gradientBounds = CGRect(
            x: rect.minX,
            y: input.panelPlacement == .below ? rect.minY - arrowH : rect.minY,
            width: rect.width,
            height: rect.height + arrowH
        )
        drawGlassSurface(
            path: path,
            bounds: gradientBounds,
            topColor: palette.panelTop,
            bottomColor: palette.panelBottom,
            in: context
        )
    }

    /// 构造单条连续闭合的圆角气泡 + 平滑微圆润尖角路径，使渐变填充与高光描边浑然一体。
    private func makePopoverBubblePath(
        rect: CGRect,
        cornerRadius r: CGFloat,
        arrowCenterX ax: CGFloat,
        arrowHalfWidth hw: CGFloat,
        arrowHeight ah: CGFloat,
        placement: AnnotationToolbarLayout.PanelPlacement
    ) -> CGPath {
        let path = CGMutablePath()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        let tipRound: CGFloat = 1.6

        // 视图是 flipped（y 向下）：从左上圆角终点顺时针绕行。
        path.move(to: CGPoint(x: minX + r, y: minY))

        if placement == .below {
            // 顶边向右，插入朝上的圆润尖角 ▲
            path.addLine(to: CGPoint(x: ax - hw, y: minY))
            path.addLine(to: CGPoint(x: ax - tipRound, y: minY - ah + tipRound * 0.8))
            path.addQuadCurve(
                to: CGPoint(x: ax + tipRound, y: minY - ah + tipRound * 0.8),
                control: CGPoint(x: ax, y: minY - ah - 0.6)
            )
            path.addLine(to: CGPoint(x: ax + hw, y: minY))
        }
        path.addLine(to: CGPoint(x: maxX - r, y: minY))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + r), radius: r)

        // 右边向下
        path.addLine(to: CGPoint(x: maxX, y: maxY - r))
        path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - r, y: maxY), radius: r)

        if placement == .above {
            // 底边向左，插入朝下的圆润尖角 ▼
            path.addLine(to: CGPoint(x: ax + hw, y: maxY))
            path.addLine(to: CGPoint(x: ax + tipRound, y: maxY + ah - tipRound * 0.8))
            path.addQuadCurve(
                to: CGPoint(x: ax - tipRound, y: maxY + ah - tipRound * 0.8),
                control: CGPoint(x: ax, y: maxY + ah + 0.6)
            )
            path.addLine(to: CGPoint(x: ax - hw, y: maxY))
        }
        path.addLine(to: CGPoint(x: minX + r, y: maxY))
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - r), radius: r)

        // 左边向上回到起点
        path.addLine(to: CGPoint(x: minX, y: minY + r))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + r, y: minY), radius: r)
        path.closeSubpath()
        return path
    }

    /// 通用精致微光泽玻璃浮层填充 + 细腻高光外描边。
    private func drawGlassSurface(
        path: CGPath,
        bounds: CGRect,
        topColor: NSColor,
        bottomColor: NSColor,
        in context: CGContext
    ) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [topColor.cgColor, bottomColor.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: bounds.midX, y: bounds.minY),
                end: CGPoint(x: bounds.midX, y: bounds.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            context.setFillColor(bottomColor.cgColor)
            context.fill(bounds)
        }
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(palette.border.cgColor)
        context.setLineWidth(0.9)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    private func fillRoundedRect(
        _ rect: CGRect,
        radius: CGFloat,
        color: NSColor,
        in context: CGContext
    ) {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    private func drawItem(_ item: Item, in context: CGContext, isInPanel: Bool) {
        let hover = hoveredKind == item.kind && item.isEnabled
        let pressed = pressedKind == item.kind && item.isEnabled
        let selected = isSelected(item.kind)
        // 按压态提供 0.75pt 微内缩质感，松手回弹。
        let visualRect = pressed ? item.rect.insetBy(dx: 0.75, dy: 0.75) : item.rect

        if Self.drawsItemHighlight(item.kind) {
            drawHighlight(
                visualRect,
                radius: Self.itemCornerRadius,
                kind: item.kind,
                isInPanel: isInPanel,
                isSelected: selected,
                isHovered: hover,
                isPressed: pressed,
                in: context
            )
        }

        // 计算当前条目的语义前景色：
        // - 主栏选中态：实心强调色胶囊配纯白；
        // - 二级面板选中态：深色下柔光玻璃胶囊配纯白，浅色下浅强调胶囊配系统强调色，克制不抢主栏焦点。
        if selected {
            if isInPanel && !isDarkAppearance {
                currentGlyphInkColor = NSColor.controlAccentColor
            } else {
                currentGlyphInkColor = .white
            }
        } else {
            switch item.kind {
            case .copy:
                currentGlyphInkColor = palette.copyInk
            case .cancel:
                currentGlyphInkColor = (hover || pressed) ? palette.dangerInk : palette.secondaryInk
            case .deleteSelected:
                currentGlyphInkColor = palette.dangerInk
            default:
                currentGlyphInkColor = palette.primaryInk
            }
        }

        let drawTarget = pressed ? Item(kind: item.kind, rect: visualRect, isEnabled: item.isEnabled) : item
        drawGlyph(for: drawTarget, in: context)
        currentGlyphInkColor = palette.primaryInk
    }

    /// 条目背景高亮的圆角。
    private static let itemCornerRadius: CGFloat = 7.5

    /// 该条目是否绘制「悬停 / 选中底」。
    ///
    /// 三类不画，各有理由：
    /// - **滑块**：轨道本身就是控件的视觉，再叠一层圆角底色会与「已填充段」
    ///   混淆（代码里原有注释即此意）。悬停反馈改由手柄变大承担。
    /// - **纯色块**（`.color`）：由 `drawSwatch` 自绘选中环与悬停态。
    /// - **文字按钮**（`.magnifierZoom` / `.mosaicMode`）：由 `drawTextButton` 自绘。
    private static func drawsItemHighlight(_ kind: Kind) -> Bool {
        switch kind {
        case .lineWidthSlider, .arrowHeadScaleSlider, .mosaicBrushDiameterSlider,
             .color, .magnifierZoom, .mosaicMode, .mosaicEffectMode,
             .textFontFamily, .spotlightDimOpacity:
            return false
        default:
            return true
        }
    }

    /// 绘制条目的字形（背景高亮由 `drawItem` 负责）。
    private func drawGlyph(for item: Item, in context: CGContext) {
        let rect = item.rect
        let alpha: CGFloat = item.isEnabled ? 1 : 0.32
        let selected = isSelected(item.kind)
        // 已把 `isEnabled` 计入的悬停态：不可用项不显示悬停反馈。
        let hover = hoveredKind == item.kind && item.isEnabled
        // **裸**悬停态，不计 `isEnabled`。只有 `.color` 用它——色块即使不可用
        // 也给出悬停反馈。这是改造前的既有行为，此处如实保留，不趁机改动。
        let rawHovered = hoveredKind == item.kind

        switch item.kind {
        case let .family(family):
            drawFamilyGlyph(family, rect: rect, alpha: alpha, in: context)

        case let .tool(tool):
            drawToolGlyph(tool, rect: rect, alpha: alpha, in: context)

        case .moreTools:
            drawMoreToolsGlyph(rect: rect, alpha: alpha, in: context)

        case let .color(color):
            drawSwatch(
                color,
                rect: rect,
                isSelected: selected,
                isHovered: rawHovered,
                alpha: alpha,
                in: context
            )

        case .lineWidthSlider:
            drawSliderGlyph(.lineWidth, rect: rect, alpha: alpha, in: context)
            drawSlider(
                value: style.shapeLineWidth,
                range: AnnotationStyle.lineWidthRange,
                label: formatSliderValue(style.shapeLineWidth),
                rect: rect,
                isHovered: hover,
                alpha: alpha,
                in: context
            )

        case .arrowHeadScaleSlider:
            drawSliderGlyph(.arrowHeadScale, rect: rect, alpha: alpha, in: context)
            drawSlider(
                value: style.arrowHeadScale,
                range: AnnotationStyle.arrowHeadScaleRange,
                label: formatSliderValue(style.arrowHeadScale),
                rect: rect,
                isHovered: hover,
                alpha: alpha,
                in: context
            )

        case let .numberingRadius(radius):
            drawNumberingRadiusGlyph(radius, rect: rect, alpha: alpha, in: context)

        case let .magnifierZoom(zoom):
            drawTextButton(
                AnnotationToolbarLayout.formatZoomLabel(zoom),
                rect: rect,
                isSelected: selected,
                isHovered: hover,
                alpha: alpha,
                in: context
            )

        case let .curvedArrowBend(bend):
            drawCurvedArrowBendGlyph(bend, rect: rect, alpha: alpha, in: context)

        case let .fontSize(size):
            drawFontSizeGlyph(size, rect: rect, alpha: alpha, in: context)

        case let .mosaicMode(mode):
            drawTextButton(
                mode.displayName,
                rect: rect,
                isSelected: selected,
                isHovered: hover,
                alpha: alpha,
                in: context
            )

        case let .mosaicEffectMode(mode):
            drawTextButton(
                AnnotationToolbarLayout.mosaicEffectLabel(mode),
                rect: rect,
                isSelected: selected,
                isHovered: hover,
                alpha: alpha,
                in: context
            )

        case .sketchyToggle:
            AnnotationToolbarIcons.drawSketchyToggle(in: rect, style: iconStyle(alpha), context: context)

        case .fillToggle:
            AnnotationToolbarIcons.drawFillToggle(isFilled: selected, in: rect, style: iconStyle(alpha), context: context)

        case .textBoldToggle:
            AnnotationToolbarIcons.drawTypographicToggle(isItalic: false, in: rect, style: iconStyle(alpha), context: context)

        case .textItalicToggle:
            AnnotationToolbarIcons.drawTypographicToggle(isItalic: true, in: rect, style: iconStyle(alpha), context: context)

        case .textFontFamily:
            let activeFamily = (hasSelectedAnnotation && selectedAnnotationIsText)
                ? (selectedAnnotationFontFamily ?? style.textFontFamily)
                : style.textFontFamily
            drawTextButton(
                AnnotationToolbarLayout.fontFamilyLabel(activeFamily),
                rect: rect,
                isSelected: false,
                isHovered: hover,
                alpha: alpha,
                in: context
            )

        case let .spotlightDimOpacity(opacity):
            drawTextButton(
                AnnotationToolbarLayout.spotlightOpacityLabel(opacity),
                rect: rect,
                isSelected: selected,
                isHovered: hover,
                alpha: alpha,
                in: context
            )

        case let .mosaicBlockSize(size):
            drawMosaicBlockSizeGlyph(size, rect: rect, alpha: alpha, in: context)

        case .mosaicBrushDiameterSlider:
            drawSliderGlyph(.mosaicBrush, rect: rect, alpha: alpha, in: context)
            drawSlider(
                value: style.mosaicBrushRadius * 2,
                range: AnnotationStyle.mosaicBrushDiameterRange,
                label: formatSliderValue((style.mosaicBrushRadius * 2).rounded()),
                rect: rect,
                isHovered: hover,
                alpha: alpha,
                in: context
            )

        case .pin:
            AnnotationToolbarIcons.drawPin(in: rect, style: iconStyle(alpha), context: context)

        case .recognizeText:
            AnnotationToolbarIcons.drawRecognizeText(in: rect, style: iconStyle(alpha), context: context)

        case .longScreenshot:
            AnnotationToolbarIcons.drawScrollshot(in: rect, style: iconStyle(alpha), context: context)

        case .record:
            AnnotationToolbarIcons.drawRecord(in: rect, style: iconStyle(alpha), context: context)

        case .copy:
            AnnotationToolbarIcons.drawCopy(in: rect, style: iconStyle(alpha), context: context)

        case .save:
            AnnotationToolbarIcons.drawSave(in: rect, style: iconStyle(alpha), context: context)

        case .cancel:
            AnnotationToolbarIcons.drawCancel(in: rect, style: iconStyle(alpha), context: context)

        case .deleteSelected:
            AnnotationToolbarIcons.drawDelete(in: rect, style: iconStyle(alpha), context: context)

        case .colorPicker:
            drawColorPickerGlyph(rect: rect, alpha: alpha, in: context)

        case .colorButton:
            // 布局已经保证只有取色的工具才会有这一项。
            guard let currentColor = style.color(for: tool) else { break }
            drawColorButton(currentColor, rect: rect, alpha: alpha, in: context)

        case .undo:
            AnnotationToolbarIcons.drawHistory(isUndo: true, in: rect, style: iconStyle(alpha), context: context)

        case .redo:
            AnnotationToolbarIcons.drawHistory(isUndo: false, in: rect, style: iconStyle(alpha), context: context)
        }
    }

    private func iconStyle(_ alpha: CGFloat) -> AnnotationToolbarIcons.Style {
        AnnotationToolbarIcons.Style(inkColor: currentGlyphInkColor, alpha: alpha)
    }

    /// 选中与悬停胶囊高亮：
    /// - 选中态采用强调色微光泽纵渐变 + 顶部 1px 细腻内高光；
    /// - 主栏「复制」常态带克制翡翠绿完成徽底，悬停点亮；
    /// - 「取消 / 删除」悬停态显示柔和危险红微底。
    private func drawHighlight(
        _ rect: CGRect,
        radius: CGFloat,
        kind: Kind? = nil,
        isInPanel: Bool = false,
        isSelected: Bool,
        isHovered: Bool,
        isPressed: Bool = false,
        in context: CGContext
    ) {
        if isSelected {
            if isInPanel {
                let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
                    ?? NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1.0)
                let fillColor = isDarkAppearance
                    ? NSColor.white.withAlphaComponent(isPressed ? 0.24 : 0.17)
                    : accent.withAlphaComponent(isPressed ? 0.20 : 0.13)
                let strokeColor = isDarkAppearance
                    ? NSColor.white.withAlphaComponent(0.18)
                    : accent.withAlphaComponent(0.30)
                fillRoundedRect(rect, radius: radius, color: fillColor, in: context)
                context.saveGState()
                context.addPath(CGPath(
                    roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                    cornerWidth: max(1, radius - 0.5),
                    cornerHeight: max(1, radius - 0.5),
                    transform: nil
                ))
                context.setStrokeColor(strokeColor.cgColor)
                context.setLineWidth(0.8)
                context.strokePath()
                context.restoreGState()
                return
            }

            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
                ?? NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1.0)
            let topAccent = isPressed
                ? (accent.blended(withFraction: 0.12, of: .black) ?? accent)
                : (accent.blended(withFraction: 0.16, of: .white) ?? accent)
            let bottomAccent = accent.blended(withFraction: isPressed ? 0.20 : 0.10, of: .black) ?? accent
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

            context.saveGState()
            context.addPath(path)
            context.clip()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [topAccent.cgColor, bottomAccent.cgColor] as CFArray,
                locations: [0, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.midX, y: rect.minY),
                    end: CGPoint(x: rect.midX, y: rect.maxY),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            } else {
                context.setFillColor(accent.cgColor)
                context.fill(rect)
            }
            context.restoreGState()

            context.saveGState()
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(1, radius - 0.5), cornerHeight: max(1, radius - 0.5), transform: nil))
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.24).cgColor)
            context.setLineWidth(0.75)
            context.strokePath()
            context.restoreGState()
            return
        }

        if kind == .copy {
            let color: NSColor
            if isPressed {
                color = palette.copyHoverFill.withAlphaComponent(min(1, palette.copyHoverFill.alphaComponent + 0.12))
            } else if isHovered {
                color = palette.copyHoverFill
            } else {
                color = palette.copyIdleFill
            }
            fillRoundedRect(rect, radius: radius, color: color, in: context)
            return
        }

        guard isHovered || isPressed else { return }
        let fill: NSColor
        switch kind {
        case .cancel, .deleteSelected:
            fill = isPressed
                ? palette.dangerHoverFill.withAlphaComponent(min(1, palette.dangerHoverFill.alphaComponent + 0.12))
                : palette.dangerHoverFill
        default:
            fill = isPressed
                ? palette.hoverFill.withAlphaComponent(min(1, palette.hoverFill.alphaComponent + 0.08))
                : palette.hoverFill
        }
        fillRoundedRect(rect, radius: radius, color: fill, in: context)
    }

    func isSelected(_ kind: Kind) -> Bool {
        // 候选阶段不显示「哪个工具生效」（理由见 `showsToolSelection`）。
        if !showsToolSelection {
            switch kind {
            case .family, .tool, .moreTools: return false
            default: break
            }
        }

        switch kind {
        case let .family(family):
            return tool.family == family
        case let .tool(candidate):
            return tool == candidate
        case .moreTools:
            return AnnotationToolbarLayout.isSecondaryTool(tool)
        case let .color(color):
            if tool == .pointer, let selectedAnnotationColor {
                return selectedAnnotationColor == color
            }
            if tool == .pointer {
                return style.shapeColor == color
            }
            return style.color(for: tool) == color
        case .lineWidthSlider, .arrowHeadScaleSlider:
            // 连续滑块没有「选中档位」这回事：它的当前值由手柄位置表达，
            // 不属于「多选一」的选中态。
            return false
        case let .fontSize(size):
            let activeSize = activeFontSizeForToolbar ?? style.textFontSize
            return abs(activeSize - size) < 0.01
        case let .mosaicMode(mode):
            return style.mosaicMode == mode
        case let .mosaicEffectMode(mode):
            if tool == .pointer, hasSelectedAnnotation {
                return selectedAnnotationMosaicMode == mode
            }
            return style.mosaicEffectMode == mode
        case .sketchyToggle:
            if hasSelectedAnnotation, selectedAnnotationSupportsSketchy {
                return selectedAnnotationIsSketchy
            }
            return style.shapeIsSketchy
        case .fillToggle:
            if hasSelectedAnnotation, selectedAnnotationSupportsFill {
                return selectedAnnotationIsFilled
            }
            return style.shapeFilled
        case .textBoldToggle:
            if hasSelectedAnnotation, selectedAnnotationIsText {
                return selectedAnnotationIsBold
            }
            return style.textBold
        case .textItalicToggle:
            if hasSelectedAnnotation, selectedAnnotationIsText {
                return selectedAnnotationIsItalic
            }
            return style.textItalic
        case let .spotlightDimOpacity(opacity):
            let active = (hasSelectedAnnotation && selectedAnnotationIsSpotlight)
                ? (selectedAnnotationSpotlightDimOpacity ?? style.spotlightDimOpacity)
                : style.spotlightDimOpacity
            return abs(active - opacity) < 0.03
        case let .mosaicBlockSize(size):
            if hasSelectedAnnotation, selectedAnnotationSupportsMosaicEffect, let selectedAnnotationMosaicBlockSize {
                return abs(selectedAnnotationMosaicBlockSize - size) < 0.01
            }
            return abs(style.mosaicBlockSize - size) < 0.01
        case let .numberingRadius(radius):
            return abs(style.numberingRadius - radius) < 0.01
        case let .magnifierZoom(zoom):
            return abs(style.magnifierZoom - zoom) < 0.01
        case let .curvedArrowBend(bend):
            return abs(style.curvedArrowBend - bend) < 0.01
        case .mosaicBrushDiameterSlider:
            // 与其余滑块同理：连续值没有「选中档位」这回事。
            return false
        case .colorButton, .colorPicker, .undo, .redo, .copy, .save, .cancel, .record, .longScreenshot,
             .recognizeText, .pin, .deleteSelected, .textFontFamily:
            return false
        }
    }

    /// 录制图标：摄像机（SF Symbol `video.fill`，白色）。
    ///
    /// 早期版本是红色实心圆——那是「录制中」的状态指示，放在工具栏里既与其它
    /// 动作图标不同色、也不表达「用摄像机拍下这块区域」的语义；录制中的红色状态
    /// 由独立控制条上的指示点承担。
    ///
    /// 手绘版本（机身圆角矩形 + 梯形镜头）在 18pt 的按钮里比例失控、看起来像两个
    /// 小方块，故改用系统符号：它在不同字号下都保持正确的光学比例与笔画粗细。
    /// 图标的统一绘制区：按钮内居中的正方形。
    ///
    /// 不让每个图标各自 `insetBy`：图标的光学重心并不一样
    /// （指针箭头天生偏左上、字母 T 偏下），各自定内缩会让整排图标
    /// 看起来高低不齐。统一到同一个正方形里，再让各自形状在其内部居中。
    private func iconBox(in rect: CGRect, size: CGFloat = 16) -> CGRect {
        CGRect(
            x: rect.midX - size / 2,
            y: rect.midY - size / 2,
            width: size,
            height: size
        )
    }

    /// 主栏的颜色入口：精致双环圆形色球，与工具图标光学体量一致。
    private func drawColorButton(
        _ color: RGBAColor,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let outer = iconBox(in: rect, size: 17)
        let inner = iconBox(in: rect, size: 13.5)

        context.saveGState()
        // 外细环：强化浅色/深色背景下的轮廓识别。
        context.setStrokeColor(palette.primaryInk.withAlphaComponent(0.32 * alpha).cgColor)
        context.setLineWidth(1.0)
        context.strokeEllipse(in: outer.insetBy(dx: 0.5, dy: 0.5))

        if color.a < 0.99 {
            context.setFillColor(palette.primaryInk.withAlphaComponent(0.18 * alpha).cgColor)
            context.fillEllipse(in: inner)
        }
        context.setFillColor(NSColor(
            srgbRed: CGFloat(color.r),
            green: CGFloat(color.g),
            blue: CGFloat(color.b),
            alpha: alpha * CGFloat(color.a)
        ).cgColor)
        context.fillEllipse(in: inner)

        context.setStrokeColor(
            (isDarkAppearance ? NSColor.white : NSColor.black).withAlphaComponent(0.22 * alpha).cgColor
        )
        context.setLineWidth(0.75)
        context.strokeEllipse(in: inner.insetBy(dx: 0.375, dy: 0.375))
        context.restoreGState()
    }

    /// 完整取色器入口：24 段平滑连续彩虹色环。
    private func drawColorPickerGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        let box = iconBox(in: rect, size: 15.5)
        let center = CGPoint(x: box.midX, y: box.midY)
        let radius = box.width / 2 - 1.2

        let segments = 24
        context.saveGState()
        context.setLineWidth(2.4)
        context.setLineCap(.butt)
        for index in 0 ..< segments {
            let start = CGFloat(index) / CGFloat(segments) * 2 * .pi
            let end = CGFloat(index + 1) / CGFloat(segments) * 2 * .pi
            let hue = (CGFloat(index) + 0.5) / CGFloat(segments)
            context.setStrokeColor(NSColor(
                hue: hue,
                saturation: 0.86,
                brightness: 0.96,
                alpha: alpha
            ).cgColor)
            context.addArc(
                center: center,
                radius: radius,
                startAngle: start,
                endAngle: end + 0.04,
                clockwise: false
            )
            context.strokePath()
        }
        context.restoreGState()
    }

    /// 面板色卡圆点：内缩色心（13pt）+ 严格落在命中区内的通透选中外环，彻底消除与相邻色点碰撞。
    private func drawSwatch(
        _ color: RGBAColor,
        rect: CGRect,
        isSelected: Bool,
        isHovered: Bool,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let fill = NSColor(
            srgbRed: CGFloat(color.r),
            green: CGFloat(color.g),
            blue: CGFloat(color.b),
            alpha: alpha * CGFloat(color.a)
        )
        let coreDiameter: CGFloat = isSelected ? 12.6 : (isHovered ? 14.0 : 13.4)
        let coreRect = CGRect(
            x: rect.midX - coreDiameter / 2,
            y: rect.midY - coreDiameter / 2,
            width: coreDiameter,
            height: coreDiameter
        )

        context.saveGState()
        if color.a < 0.99 {
            context.setFillColor(palette.primaryInk.withAlphaComponent(0.18 * alpha).cgColor)
            context.fillEllipse(in: coreRect)
        }
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: coreRect)

        // 统一细腻微描边，保证纯黑在深色底、纯白在浅色底均边界清晰。
        let luminance = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b
        let strokeColor: NSColor
        if isDarkAppearance && luminance < 0.22 {
            strokeColor = NSColor.white.withAlphaComponent(0.38 * alpha)
        } else if !isDarkAppearance && luminance > 0.82 {
            strokeColor = NSColor.black.withAlphaComponent(0.24 * alpha)
        } else {
            strokeColor = (isDarkAppearance ? NSColor.white : NSColor.black).withAlphaComponent(0.14 * alpha)
        }
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(0.8)
        context.strokeEllipse(in: coreRect.insetBy(dx: 0.4, dy: 0.4))
        context.restoreGState()

        // 选中/悬停外环：严格限制在 `rect`（18×18）内，与色心之间留出通透呼吸环，绝不撞隔壁。
        guard isSelected || isHovered else { return }
        context.saveGState()
        context.setStrokeColor(
            (isSelected ? palette.swatchSelectedRing : palette.swatchHoverRing).cgColor
        )
        context.setLineWidth(isSelected ? 1.65 : 1.15)
        context.strokeEllipse(in: rect.insetBy(dx: 0.85, dy: 0.85))
        context.restoreGState()
    }

    private func drawTextButton(
        _ text: String,
        rect: CGRect,
        isSelected: Bool,
        isHovered: Bool,
        alpha: CGFloat,
        in context: CGContext
    ) {
        drawHighlight(rect, radius: Self.itemCornerRadius, isInPanel: true, isSelected: isSelected, isHovered: isHovered, in: context)

        let savedInk = currentGlyphInkColor
        if isSelected {
            currentGlyphInkColor = isDarkAppearance ? .white : NSColor.controlAccentColor
        }
        drawCenteredGlyphText(
            text,
            pointSize: 12,
            weight: isSelected ? .semibold : .medium,
            center: CGPoint(x: rect.midX, y: rect.midY),
            alpha: alpha,
            in: context
        )
        currentGlyphInkColor = savedInk
    }

    /// 滑块左端的标识图形。
    ///
    /// 形状面板里会**同时**出现两个滑块（箭头工具下：线宽 + 箭头大小），
    /// 两者只靠「轨道 + 数字」完全同形，光看读数分不出哪个控制什么。
    /// 图标是区分它们的唯一稳定依据——读数只在拖动时才变化，
    /// 而用户要判断的正是「该拖哪一个」。
    private enum SliderGlyph {
        /// 线宽：三条粗细递增的横线。
        case lineWidth
        /// 箭头头部大小：一个占主导的箭头头部加短杆。
        case arrowHeadScale
        /// 涂抹笔刷大小：一个圆环。
        case mosaicBrush
    }

    private func drawSliderGlyph(
        _ glyph: SliderGlyph,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let size = AnnotationToolbarLayout.sliderIconSize
        let box = CGRect(
            x: rect.minX,
            y: rect.midY - size / 2,
            width: size,
            height: size
        )

        context.saveGState()
        context.setStrokeColor(ink(alpha).cgColor)
        context.setFillColor(ink(alpha).cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch glyph {
        case .lineWidth:
            AnnotationToolbarIcons.drawLineWidthSliderGlyph(in: box, style: iconStyle(alpha), context: context)
        case .arrowHeadScale:
            AnnotationToolbarIcons.drawArrowHeadSliderGlyph(in: box, style: iconStyle(alpha), context: context)
        case .mosaicBrush:
            AnnotationToolbarIcons.drawMosaicBrushSliderGlyph(in: box, style: iconStyle(alpha), context: context)
        }

        context.restoreGState()
    }

    /// 马赛克块大小的档位图标：块越粗，格子越大越少。
    ///
    /// 数字（6 / 12 / 20）本身不说明任何事：用户不知道那是像素、边长
    /// 还是强度。画成块阵之后，「格子越大 = 马赛克越粗」是直接可见的。
    private func drawMosaicBlockSizeGlyph(
        _ size: Double,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let box = iconBox(in: rect)
        // 按档位序号取格数，而不是拿数值去除：块大小的单位随时可能变，
        // 而「越粗的档位格数越少」这个关系不会变。
        let index = AnnotationStyle.mosaicBlockSizes.firstIndex(of: size) ?? 0
        let cellCounts = [4, 3, 2]
        let cells = cellCounts[min(index, cellCounts.count - 1)]
        let cell = box.width / CGFloat(cells)

        context.saveGState()
        context.setFillColor(ink(alpha).cgColor)
        for row in 0 ..< cells {
            for column in 0 ..< cells where (row + column) % 2 == 0 {
                let tile = CGRect(
                    x: box.minX + CGFloat(column) * cell + 0.4,
                    y: box.minY + CGFloat(row) * cell + 0.4,
                    width: max(1, cell - 0.8),
                    height: max(1, cell - 0.8)
                )
                context.addPath(CGPath(roundedRect: tile, cornerWidth: 1.0, cornerHeight: 1.0, transform: nil))
                context.fillPath()
            }
        }
        context.restoreGState()
    }

    /// 编号半径的档位图标：三个直径的圆环 + 圆心一点。
    private func drawNumberingRadiusGlyph(
        _ radius: Double,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let box = iconBox(in: rect)
        let index = AnnotationStyle.numberingRadii.firstIndex(of: radius) ?? 0
        let diameters: [CGFloat] = [9, 12, 15]
        let diameter = diameters[min(index, diameters.count - 1)]

        context.saveGState()
        context.setStrokeColor(ink(alpha).cgColor)
        context.setFillColor(ink(alpha).cgColor)
        context.setLineWidth(1.5)

        context.strokeEllipse(in: CGRect(
            x: box.midX - diameter / 2,
            y: box.midY - diameter / 2,
            width: diameter,
            height: diameter
        ))

        let dot: CGFloat = 2.4
        context.fillEllipse(in: CGRect(
            x: box.midX - dot / 2,
            y: box.midY - dot / 2,
            width: dot,
            height: dot
        ))
        context.restoreGState()
    }

    /// 曲线箭头弯曲度的档位图标：一个弯曲程度递增的箭头。
    ///
    /// 画成**箭头**而不是单纯的弧：这个档位属于曲线箭头工具，
    /// 画一条无头弧线会与「手绘」图标的 S 形笔迹混淆。
    /// 三个档位分别是直线、微弯、明显弯曲，一眼能看出是「弯多少」。
    private func drawCurvedArrowBendGlyph(
        _ bend: Double,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let box = iconBox(in: rect)
        let start = CGPoint(x: box.minX + 1, y: box.maxY - 1.4)
        let end = CGPoint(x: box.maxX - 1.6, y: box.minY + 3.6)

        // 控制点从中点沿弦的法线偏移，偏移量按 bend 缩放。
        // 这里只求「示意」：三个档位的弯曲程度必须**单调递增**，
        // 与模型里 `bendControl` 的精确比例不必一致。
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let bulge = CGFloat(bend) * length * 1.5
        let control = CGPoint(
            x: (start.x + end.x) / 2 - normal.x * bulge,
            y: (start.y + end.y) / 2 - normal.y * bulge
        )

        context.saveGState()
        context.setStrokeColor(ink(alpha).cgColor)
        context.setFillColor(ink(alpha).cgColor)
        context.setLineWidth(1.55)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // 先构造路径，再按**实际包围盒**整体平移居中。
        //
        // 不能只按起止点定位：三个档位的形状差异很大——bend=0 是一条直线，
        // bend=0.5 是一条向左上鼓出的弧，两者的包围盒中心差一个多像素。
        // 不统一居中，切换档位时图标会在按钮里上下跳（实测直线档偏下 1.12pt）。
        let curve = CGMutablePath()
        curve.move(to: start)
        curve.addQuadCurve(to: end, control: control)

        // 箭头头部沿**终点切线**（二次贝塞尔的终点切线就是 end − control）。
        let tangent = CGPoint(x: end.x - control.x, y: end.y - control.y)
        let tangentLength = max(0.001, (tangent.x * tangent.x + tangent.y * tangent.y).squareRoot())
        let unit = CGPoint(x: tangent.x / tangentLength, y: tangent.y / tangentLength)
        let headNormal = CGPoint(x: -unit.y, y: unit.x)
        let headLength: CGFloat = 4.2
        let headHalfWidth: CGFloat = 2.1
        let base = CGPoint(
            x: end.x - unit.x * headLength,
            y: end.y - unit.y * headLength
        )
        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: CGPoint(
            x: base.x + headNormal.x * headHalfWidth,
            y: base.y + headNormal.y * headHalfWidth
        ))
        head.addLine(to: CGPoint(
            x: base.x - headNormal.x * headHalfWidth,
            y: base.y - headNormal.y * headHalfWidth
        ))
        head.closeSubpath()

        // 弧是描边（外扩半个线宽），头部是填充（不外扩）。
        let strokeOutset: CGFloat = 0.8
        let bounds = curve.boundingBoxOfPath
            .insetBy(dx: -strokeOutset, dy: -strokeOutset)
            .union(head.boundingBoxOfPath)
        var shift = CGAffineTransform(
            translationX: box.midX - bounds.midX,
            y: box.midY - bounds.midY
        )

        if let movedCurve = curve.copy(using: &shift) {
            context.addPath(movedCurve)
        }
        context.strokePath()

        if let movedHead = head.copy(using: &shift) {
            context.addPath(movedHead)
        }
        context.fillPath()
        context.restoreGState()
    }

    /// 文字字号的档位图标：逐档变大的字母「A」。
    ///
    /// 数字（16 / 20 / 28 …）不告诉用户那是什么单位。字母的大小
    /// 就是「字会写多大」，无需解释。用大写 A 而不是汉字：
    /// 汉字在各字号下的视觉高度受字形影响大，英文大写的 capHeight 最稳。
    private func drawFontSizeGlyph(
        _ size: Double,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let box = iconBox(in: rect)
        let index = AnnotationStyle.fontSizes.firstIndex(of: size) ?? 0
        // 绘制区只有 16pt，所以档位要压缩到这个范围里：
        // 按真实字号画的话，56pt 会直接溢出，而 16pt 又小得看不见。
        let pointSizes: [CGFloat] = [8, 11, 14, 17, 20]
        let pointSize = pointSizes[min(index, pointSizes.count - 1)]

        drawCenteredGlyphText(
            "A",
            pointSize: pointSize,
            center: CGPoint(x: box.midX, y: box.midY),
            alpha: alpha,
            in: context
        )
    }

    /// 现代 macOS 胶囊滑块：柔和轨道 + 强调色已填段 + 带软影白圆球手柄 + 等宽数值读数。
    private func drawSlider(
        value: Double,
        range: ClosedRange<Double>,
        label: String,
        rect: CGRect,
        isHovered: Bool,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let track = AnnotationToolbarLayout.sliderTrack(in: rect)
        let span = max(0.0001, range.upperBound - range.lowerBound)
        let progress = min(max((value - range.lowerBound) / span, 0), 1)
        let knobCenter = CGPoint(
            x: track.minX + CGFloat(progress) * track.width,
            y: rect.midY
        )

        context.saveGState()

        // 轨道底色：整条范围。
        context.setFillColor(palette.sliderTrack.withAlphaComponent(palette.sliderTrack.alphaComponent * alpha).cgColor)
        context.addPath(CGPath(
            roundedRect: track,
            cornerWidth: track.height / 2,
            cornerHeight: track.height / 2,
            transform: nil
        ))
        context.fillPath()

        // 已填充段：采用系统强调色。
        let filled = CGRect(
            x: track.minX,
            y: track.minY,
            width: max(0, knobCenter.x - track.minX),
            height: track.height
        )
        if filled.width > 0 {
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor)
            context.addPath(CGPath(
                roundedRect: filled,
                cornerWidth: filled.height / 2,
                cornerHeight: filled.height / 2,
                transform: nil
            ))
            context.fillPath()
        }

        // 手柄：精致纯白圆球 + 柔和微投影 + 细腻轮廓描边。
        let radius: CGFloat = isHovered ? 6.0 : 5.2
        let knobRect = CGRect(
            x: knobCenter.x - radius,
            y: knobCenter.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 1),
            blur: 3,
            color: NSColor.black.withAlphaComponent(0.32).cgColor
        )
        context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.fillEllipse(in: knobRect)
        context.restoreGState()

        context.setStrokeColor(NSColor.black.withAlphaComponent(isDarkAppearance ? 0.14 : 0.22).cgColor)
        context.setLineWidth(0.7)
        context.strokeEllipse(in: knobRect.insetBy(dx: 0.35, dy: 0.35))

        drawRightAlignedText(
            label,
            anchor: CGPoint(x: rect.maxX - 2, y: rect.midY),
            alpha: alpha,
            in: context
        )

        context.restoreGState()
    }

    /// 滑块读数的格式：整数不显示小数位，非整数显示一位小数。
    ///
    /// 一位小数与 `quantize` 的 0.1 步长严格对应：读数与写进模型的值
    /// 永远一致，不会出现「界面写 4、实际是 4.35」这种对不上的情况。
    /// 统一带一位小数则会把「线宽 4」写成「4.0」，白占掉一个字符宽度，
    /// 而数值区只有 26pt。
    ///
    /// ⚠️ 上面这条「永远一致」曾经**并不成立**：`quantize` 用
    /// `(v / step).rounded() * step` 计算，而二进制浮点下
    /// `23 * 0.1 = 2.3000000000000003`，与字面量 `2.3` 不相等。
    /// 显示层因为要格式化所以看不出差异，但模型里存的确实是另一个值——
    /// 精确比较与序列化往返都会露出来。
    ///
    /// 现已按 step 的十进制位数规整，并由
    /// `AnnotationEditorStateTests.lineWidthQuantizationIsExactAcrossRange`
    /// 在 [1, 24] 全区间穷尽锁定。
    private func formatSliderValue(_ value: Double) -> String {
        value == value.rounded()
            ? "\(Int(value))"
            : String(format: "%.1f", value)
    }

    /// 右对齐画一段等宽小号数值文字（中点对齐到 `anchor` 的纵向位置，拖动时不抖动）。
    private func drawRightAlignedText(
        _ text: String,
        anchor: CGPoint,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: palette.secondaryInk.withAlphaComponent(palette.secondaryInk.alphaComponent * alpha),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        let line = CTLineCreateWithAttributedString(attributed)

        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: anchor.x - size.width,
            y: anchor.y + size.height / 2 - 1.0
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// 分组图标：形状组显示当前选中的具体形状。
    private func drawFamilyGlyph(
        _ family: AnnotationTool.Family,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let targetTool: AnnotationTool
        switch family {
        case .pointer:
            targetTool = .pointer
        case .shape:
            targetTool = tool.family == .shape ? tool : .rectangle
        case .text:
            targetTool = .text
        case .mosaic:
            targetTool = tool == .magnifier ? .magnifier : .mosaic
        }
        AnnotationToolbarIcons.drawTool(targetTool, in: rect, style: iconStyle(alpha), context: context)
    }

    /// 主栏「更多工具」图标：激活次高频工具时展示对应双色图标 + 右下角展开微角标；否则展示三点图标。
    private func drawMoreToolsGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        let activeSecondary = AnnotationToolbarLayout.isSecondaryTool(tool) ? tool : nil
        AnnotationToolbarIcons.drawMoreTools(
            activeSecondaryTool: activeSecondary,
            in: rect,
            style: iconStyle(alpha),
            context: context
        )
    }

    /// 面板里的具体工具图标：统一走精雕双色线性引擎。
    private func drawToolGlyph(
        _ tool: AnnotationTool,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        AnnotationToolbarIcons.drawTool(tool, in: rect, style: iconStyle(alpha), context: context)
    }

    /// 在指定中心画一段短文字（字号 A、倍率、模式等文字型控件）。
    private func drawCenteredGlyphText(
        _ text: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .semibold,
        center: CGPoint,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let ctFont = NSFont.systemFont(ofSize: pointSize, weight: weight) as CTFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ctFont,
            .foregroundColor: ink(alpha),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let capHeight = CTFontGetCapHeight(ctFont)

        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: center.x - width / 2,
            y: center.y + capHeight / 2
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
