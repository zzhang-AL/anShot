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
    /// 选中的标注是否有颜色 / 线宽可改（决定面板条目的存在与否）。
    var selectedAnnotationSupportsColor = true
    var selectedAnnotationSupportsLineWidth = true
    var hoveredKind: AnnotationToolbarLayout.Kind?

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
        input.selectedAnnotationSupportsColor = selectedAnnotationSupportsColor
        input.selectedAnnotationSupportsLineWidth = selectedAnnotationSupportsLineWidth
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

    /// 绘制整个工具栏（主栏 + 面板）。
    func draw(in context: CGContext) {
        let bar = layoutBar()
        let panel = layoutPanel()

        drawBarBackground(bar.size, in: context)
        drawPanelBackground(panel.size, in: context)

        for item in bar.items {
            drawItem(item, in: context, isInPanel: false)
        }
        for item in panel.items {
            drawItem(item, in: context, isInPanel: true)
        }
    }

    private func drawBarBackground(_ size: CGSize, in context: CGContext) {
        fillRoundedRect(
            CGRect(origin: .zero, size: size),
            radius: 9,
            color: NSColor.black.withAlphaComponent(0.82),
            in: context
        )
    }

    private func drawPanelBackground(_ size: CGSize, in context: CGContext) {
        guard size.height > 0 else { return }
        let bar = barSize
        let rect = CGRect(
            x: 0,
            y: bar.height + itemSpacing,
            width: size.width,
            height: size.height
        )
        fillRoundedRect(
            rect,
            radius: 8,
            color: NSColor.black.withAlphaComponent(0.74),
            in: context
        )
    }

    private func fillRoundedRect(
        _ rect: CGRect,
        radius: CGFloat,
        color: NSColor,
        in context: CGContext
    ) {
        // 用 CGPath 而非 NSBezierPath(cgPath:)：后者是 macOS 14.0+，
        // 会超出本项目的 13.0 基线。
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
        // 背景高亮只在这一处决定，字形交给 `drawGlyph`。
        //
        // 原先每个 case 各写一遍 `drawHighlight(…)`（共 16 处，参数只差
        // `isSelected`），其中 13 处硬编码 `false`——而那些 kind 在
        // `isSelected(_:)` 里本来就恒为 false（见该函数的 case 清单）。
        // 统一传值后**行为完全等价**，且「哪些条目有背景」从 16 处收敛为
        // `drawsItemHighlight(_:)` 一处可枚举的判断。
        let hover = hoveredKind == item.kind && item.isEnabled

        if Self.drawsItemHighlight(item.kind) {
            drawHighlight(
                item.rect,
                radius: Self.itemCornerRadius,
                isSelected: isSelected(item.kind),
                isHovered: hover,
                in: context
            )
        }

        drawGlyph(for: item, in: context)

        _ = isInPanel
    }

    /// 条目背景高亮的圆角。
    private static let itemCornerRadius: CGFloat = 6

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
             .color, .magnifierZoom, .mosaicMode:
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
                "\(Int(zoom * 10))x",
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
            drawPinGlyph(rect: rect, alpha: alpha, in: context)

        case .recognizeText:
            drawRecognizeTextGlyph(rect: iconBox(in: rect), alpha: alpha, in: context)

        case .longScreenshot:
            drawScrollshotGlyph(rect: iconBox(in: rect), alpha: alpha, in: context)

        case .record:
            drawRecordGlyph(rect: rect, alpha: alpha, in: context)

        case .copy:
            drawCopyGlyph(rect: rect, alpha: alpha, in: context)

        case .save:
            drawSaveGlyph(rect: rect, alpha: alpha, in: context)

        case .deleteSelected:
            // 垃圾桶符号：与其它「结束/破坏性」动作一样用系统符号，
            // 手绘的桶身在 16pt 里分不清是杯子还是垃圾桶。
            drawSymbolGlyph("trash", rect: rect, alpha: alpha, scale: 0.52, in: context)

        case .colorPicker:
            drawColorPickerGlyph(rect: rect, alpha: alpha, in: context)

        case .colorButton:
            // 布局已经保证只有取色的工具才会有这一项。
            guard let currentColor = style.color(for: tool) else { break }
            drawColorButton(currentColor, rect: rect, alpha: alpha, in: context)

        case .undo:
            drawHistoryGlyph(isUndo: true, rect: rect, alpha: alpha, in: context)

        case .redo:
            drawHistoryGlyph(isUndo: false, rect: rect, alpha: alpha, in: context)
        }
    }

    /// 选中高亮：系统强调色只用于「当前生效的那个」，
    /// 不做放大或加阴影，避免工具条里到处是彩色块。
    private func drawHighlight(
        _ rect: CGRect,
        radius: CGFloat,
        isSelected: Bool,
        isHovered: Bool,
        in context: CGContext
    ) {
        guard isSelected || isHovered else { return }
        let color = isSelected
            ? NSColor.controlAccentColor
            : NSColor.white.withAlphaComponent(0.14)
        fillRoundedRect(rect, radius: radius, color: color, in: context)
    }

    private func isSelected(_ kind: Kind) -> Bool {
        // 候选阶段不显示「哪个工具生效」（理由见 `showsToolSelection`）。
        if !showsToolSelection {
            switch kind {
            case .family, .tool: return false
            default: break
            }
        }

        switch kind {
        case let .family(family):
            return tool.family == family
        case let .tool(candidate):
            return tool == candidate
        case let .color(color):
            // 指针 + 选中时面板改的是**选中标注**的颜色，样式槽也会被同步
            //（见 `OverlayView` 的工具栏回调），因此当前值取形状色。
            if tool == .pointer {
                return style.shapeColor == color
            }
            return style.color(for: tool) == color
        case .lineWidthSlider, .arrowHeadScaleSlider:
            // 连续滑块没有「选中档位」这回事：它的当前值由手柄位置表达，
            // 不属于「多选一」的选中态。
            return false
        case let .fontSize(size):
            return style.textFontSize == size
        case let .mosaicMode(mode):
            return style.mosaicMode == mode
        case let .mosaicBlockSize(size):
            return style.mosaicBlockSize == size
        case .mosaicBrushDiameterSlider:
            // 与其余滑块同理：连续值没有「选中档位」这回事。
            return false
        case .colorButton, .colorPicker, .undo, .redo, .copy, .save, .record, .longScreenshot,
             .recognizeText, .numberingRadius, .magnifierZoom, .curvedArrowBend, .pin,
             .deleteSelected:
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
    /// 固定图标：一枚图钉（系统符号 `pin.fill`）。
    ///
    /// 为什么这里不用手绘：宽顶窄底的纵向对称结构在 16pt 绘制区里只能二选一——
    /// 肩部斜线拉得够长就读成漏斗，缩短到够短就读成 T 或伞。
    /// 具体取舍的完整理由见 `drawSymbolGlyph`。
    ///
    /// 比例比默认值大一点（0.54 对 0.46）：`pin.fill` 的字形是高瘦型，
    /// 同样字号下视觉高度只有宽扁的 `video.fill` 的七成，
    /// 按默认值画出来会比旁边的图标瘦一圈、量不一致。
    private func drawPinGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        drawSymbolGlyph("pin.fill", rect: rect, alpha: alpha, scale: 0.54, in: context)
    }

    /// OCR 图标：一个四角取景框，框内三条长度递减的文字行。
    ///
    /// 上一版只有**右下角**一段折线，四角不成对：它读起来更像画歪的一条线，
    /// 而不是「取景」。四个角补齐之后，中间的文字行才落进一个明确的框里，
    /// 「从画面里取字」这层意思才立得住。
    ///
    /// 文字行只画三条且长度递减——排满会糊成一团灰块，
    /// 递减则一眼是「几行字」而不是「一个表格」。
    private func drawRecognizeTextGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        let box = iconBox(in: rect)
        let armLength: CGFloat = 4.5
        let rowInset: CGFloat = 4

        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // 取景框：四个角各一段折线，拐点落在绘制区顶点上。
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: box.minX, y: box.minY + armLength),
             CGPoint(x: box.minX, y: box.minY),
             CGPoint(x: box.minX + armLength, y: box.minY)),
            (CGPoint(x: box.maxX - armLength, y: box.minY),
             CGPoint(x: box.maxX, y: box.minY),
             CGPoint(x: box.maxX, y: box.minY + armLength)),
            (CGPoint(x: box.minX, y: box.maxY - armLength),
             CGPoint(x: box.minX, y: box.maxY),
             CGPoint(x: box.minX + armLength, y: box.maxY)),
            (CGPoint(x: box.maxX - armLength, y: box.maxY),
             CGPoint(x: box.maxX, y: box.maxY),
             CGPoint(x: box.maxX, y: box.maxY - armLength)),
        ]
        for (start, corner, end) in corners {
            context.beginPath()
            context.move(to: start)
            context.addLine(to: corner)
            context.addLine(to: end)
            context.strokePath()
        }

        // 文字行：三条，长度递减。
        let rows: [(offset: CGFloat, ratio: CGFloat)] = [
            (-4.0, 1.00), (0.0, 0.78), (4.0, 0.55),
        ]
        let rowWidth = box.width - rowInset * 2
        for row in rows {
            let y = box.midY + row.offset
            context.beginPath()
            context.move(to: CGPoint(x: box.minX + rowInset, y: y))
            context.addLine(to: CGPoint(x: box.minX + rowInset + rowWidth * row.ratio, y: y))
            context.strokePath()
        }
    }

    /// 长截图图标：**上下开口**的竖框 + 向下的箭头。
    ///
    /// 演进过程（每一版都是按真实尺寸渲染后发现的）：
    ///
    /// 1. 最早是「两横线 + 向下箭头 + 两横线」，与紧邻的**保存**图标
    ///    （向下箭头 + 托盘）几乎同形，只能靠数横线的根数分辨；
    /// 2. 改成完整闭合的圆角竖框后，与保存分开了，但在 16pt 里它读起来
    ///    像一台**手机**（竖长比例 + 圆角），而不是「一页很长的内容」；
    /// 3. 现在把上下边留出开口：只有左右两条带圆角的边是完整的，
    ///    「内容还在上下继续」这层意思才立得住——那正是长截图与
    ///    普通截图的区别所在，也是这个按钮唯一要说清的事。
    ///
    /// 竖框宽 11pt（绘制区 16pt 的 0.69）：再宽就像平板，再窄就与箭头
    /// 抢不出层次。开口宽度取 3.4pt（圆角 2.2 + 直线段 1.2）：
    /// 再小就等于没开口，再大就退化成两个括号、看不出那是个「框」。
    private func drawScrollshotGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        let box = iconBox(in: rect)
        let midX = box.midX
        let frameWidth: CGFloat = 11
        let radius: CGFloat = 2.2
        let opening: CGFloat = 3.4

        let left = midX - frameWidth / 2
        let right = midX + frameWidth / 2
        // 上下各留 1pt：去掉的话描边外沿正好压在绘制区边界上，
        // 与旁边图标相比会显得「胀出去」一截。
        let top = box.minY + 1
        let bottom = box.maxY - 1

        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // 左右两条边：各带上下两个圆角，并在上边/下边各伸出一小段。
        // 两条边分开画（而不是一个闭合路径）正是「开口」的实现方式。
        for side in [left, right] {
            let inward: CGFloat = side == left ? 1 : -1
            context.beginPath()
            context.move(to: CGPoint(x: side + inward * opening, y: top))
            context.addQuadCurve(
                to: CGPoint(x: side, y: top + radius),
                control: CGPoint(x: side, y: top)
            )
            context.addLine(to: CGPoint(x: side, y: bottom - radius))
            context.addQuadCurve(
                to: CGPoint(x: side + inward * opening, y: bottom),
                control: CGPoint(x: side, y: bottom)
            )
            context.strokePath()
        }

        // 向下的箭头：表示「一路向下捕获」。
        // 杆比箭头头部略长，头部的两翼比框宽的一半略窄，
        // 这样箭头在框内仍有留白，不会看起来把框塞满。
        let headLength: CGFloat = 3.4
        let headHalfWidth: CGFloat = 2.3
        let tip = CGPoint(x: midX, y: bottom - radius - 1.4)
        context.beginPath()
        context.move(to: CGPoint(x: midX, y: top + radius + 0.8))
        context.addLine(to: CGPoint(x: midX, y: tip.y - headLength + 0.4))
        context.move(to: CGPoint(x: midX - headHalfWidth, y: tip.y - headLength))
        context.addLine(to: tip)
        context.addLine(to: CGPoint(x: midX + headHalfWidth, y: tip.y - headLength))
        context.strokePath()
    }

    private func drawRecordGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        drawSymbolGlyph("video.fill", rect: rect, alpha: alpha, in: context)
    }

    /// 用系统符号画一个按钮图标（模板图染白）。
    ///
    /// 工具栏里的图标绝大多数是自绘的：它们的笔画粗细、比例都能共享同一套
    /// 常量，整排看起来才像一套东西。只有两个图标例外——录制（`video.fill`）
    /// 与固定（`pin.fill`），两者都是**先试过手绘、按真实按钮尺寸渲染后发现站不住**：
    ///
    /// - 录制：机身圆角矩形 + 梯形镜头，在 18pt 按钮里比例失控，像两个小方块；
    /// - 固定：宽顶窄底的纵向对称结构，无论帽线加粗到多少、肩部斜线收到多短，
    ///   在 16pt 绘制区里都会糊成一个倒三角，读起来是漏斗或伞（前后试了二十多个变体）。
    ///
    /// 这里的关键是先例：判断「像不像」必须按**真实尺寸**看。
    /// 放大到 5 倍时手绘版本都很好看，缩回 28pt 按钮里才暴露问题。
    /// 系统符号在不同字号下都保持正确的光学比例与笔画粗细，因此这两个例外用它。
    ///
    /// - Parameters:
    ///   - name: SF Symbol 名称。
    ///   - rect: 按钮区域（不是绘制区）：符号按短边的 `scale` 倍确定字号。
    ///   - alpha: 不透明度（禁用态用）。
    ///   - scale: 符号字号相对按钮短边的比例。
    private func drawSymbolGlyph(
        _ name: String,
        rect: CGRect,
        alpha: CGFloat,
        scale: CGFloat = 0.46,
        in context: CGContext
    ) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return
        }
        let pointSize = min(rect.width, rect.height) * scale
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let symbol = base.withSymbolConfiguration(configuration) else { return }

        // 模板图像不会自带颜色：用 sourceAtop 把整幅符号染成白色。
        let tinted = NSImage(size: symbol.size, flipped: false) { drawRect in
            symbol.draw(in: drawRect)
            NSColor.white.withAlphaComponent(alpha).set()
            drawRect.fill(using: .sourceAtop)
            return true
        }

        let target = CGRect(
            x: rect.midX - symbol.size.width / 2,
            y: rect.midY - symbol.size.height / 2,
            width: symbol.size.width,
            height: symbol.size.height
        )
        // 本视图的绘制走的是 CGContext，绘制 NSImage 需要临时桥接一个 NSGraphicsContext。
        //
        // ⚠️ `flipped:` 必须为 **true**，它描述的是「这个 CTM 已经翻了」，不是期望。
        // `AnnotationToolbarView.isFlipped == true`，AppKit 交给 `draw(_:)` 的 CTM 就是
        // 左上原点、y 向下；这里写 false 等于告诉 AppKit「没翻过」，它会再翻一次——
        // 凡走 `NSImage.draw` 的符号全部上下颠倒。
        //
        // 实测（与本节同一条代码路径：flipped 视图 CTM + 本桥接方式，各自渲染成图）：
        // `pin.fill` 在未翻转上下文里是「帽在上、针尖朝下」（卡片按钮上看到的就是它），
        // 而本方法旧版（false）渲染出来针尖朝**上**——用户报告的「截图图钉方向反了」
        // 就是它；改成 true 后与未翻转上下文逐行一致。
        // `video.fill` 上下近似对称，肉眼与断言都看不出来，所以这条更得靠对照渲染看。
        //
        // 参照：`SettingsComponents` 里的 `drawSymbol` 直接用 AppKit 设好的
        // `NSGraphicsContext.current`，不需要这个参数，也就不存在这个坑。
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        tinted.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
    }

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

    /// 主栏的颜色入口：一个圆形色块，与工具图标同一绘制区尺寸。
    private func drawColorButton(
        _ color: RGBAColor,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let box = iconBox(in: rect, size: 16)

        context.saveGState()
        context.setFillColor(NSColor(
            srgbRed: CGFloat(color.r),
            green: CGFloat(color.g),
            blue: CGFloat(color.b),
            alpha: alpha
        ).cgColor)
        context.fillEllipse(in: box)
        // 深色（尤其纯黑）在深色浮层上看不出来，统一描一圈浅边。
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.45 * alpha).cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: box.insetBy(dx: 0.5, dy: 0.5))
        context.restoreGState()
    }

    /// 完整取色器入口：画成色相环。
    ///
    /// 用色相环而不是加号/省略号：它一眼表达「这里能选任意颜色」，
    /// 与旁边的固定色卡形成明确区分。
    private func drawColorPickerGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        let box = iconBox(in: rect, size: 15)
        let center = CGPoint(x: box.midX, y: box.midY)
        let radius = box.width / 2 - 1

        let segments = 12
        context.saveGState()
        context.setLineWidth(2.5)
        context.setLineCap(.butt)
        for index in 0 ..< segments {
            let start = CGFloat(index) / CGFloat(segments) * 2 * .pi
            let end = CGFloat(index + 1) / CGFloat(segments) * 2 * .pi
            // 细分时略微重叠，避免扇段之间出现缝隙。
            let hue = (CGFloat(index) + 0.5) / CGFloat(segments)
            context.setStrokeColor(NSColor(
                hue: hue,
                saturation: 0.85,
                brightness: 0.95,
                alpha: alpha
            ).cgColor)
            context.addArc(
                center: center,
                radius: radius,
                startAngle: start,
                endAngle: end + 0.02,
                clockwise: false
            )
            context.strokePath()
        }
        context.restoreGState()
    }

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
            alpha: alpha
        )

        context.saveGState()
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: rect)
        context.restoreGState()

        // 深色块（黑）在深色底上看不见，给一圈浅描边保证可辨识。
        let needsOutline = color.r + color.g + color.b < 0.5
        if needsOutline {
            context.saveGState()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.35 * alpha).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
            context.restoreGState()
        }

        // 选中态：外圈再描一道白环，不改尺寸。
        guard isSelected || isHovered else { return }
        context.saveGState()
        context.setStrokeColor(
            (isSelected ? NSColor.white : NSColor.white.withAlphaComponent(0.4)).cgColor
        )
        context.setLineWidth(isSelected ? 2 : 1.5)
        context.strokeEllipse(in: rect.insetBy(dx: -3, dy: -3))
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
        drawHighlight(rect, radius: 6, isSelected: isSelected, isHovered: isHovered, in: context)

        // 与图标字形（「T」「1」）走**同一套**居中逻辑，只是字号与字重不同。
        //
        // 上一版自己按 `NSAttributedString.size.height` 居中，而那个高度含
        // ascent / descent / leading，ascent 里又留着重音符号等大写字母用不到
        // 的空间——结果是全部文字按钮**整体偏下**，实测 12pt 下偏 3.2pt。
        // 在 26pt 高的按钮里这不是「差一点」，而是一眼就能看出没对齐：
        // 「直」「25」「框选」以及号档数字都骑着按钮的下半部。
        drawCenteredGlyphText(
            text,
            pointSize: 12,
            weight: .medium,
            center: CGPoint(x: rect.midX, y: rect.midY),
            alpha: alpha,
            in: context
        )
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
        context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch glyph {
        case .lineWidth:
            drawLineWidthGlyph(box: box, in: context)
        case .arrowHeadScale:
            drawArrowHeadScaleGlyph(box: box, in: context)
        case .mosaicBrush:
            drawMosaicBrushGlyph(box: box, in: context)
        }

        context.restoreGState()
    }

    /// 线宽标识：三条**等长、粗细递增**的横线。
    ///
    /// 不用「一条粗线」：单线看不出「可调粗细」这回事，与轨道本身也容易混。
    /// 三条从细到粗的线一眼就是「粗细刻度」，正是滑块控制的那件事。
    /// 也不做成长度递减：那会读成一个阶梯，反而看不出与粗细有关。
    private func drawLineWidthGlyph(box: CGRect, in context: CGContext) {
        let widths: [CGFloat] = [1.2, 2.4, 4] 
        let step = box.height / CGFloat(widths.count)

        for (index, width) in widths.enumerated() {
            context.setLineWidth(width)
            let y = box.minY + step * (CGFloat(index) + 0.5)
            context.move(to: CGPoint(x: box.minX + 1, y: y))
            context.addLine(to: CGPoint(x: box.maxX - 1, y: y))
            context.strokePath()
        }
    }

    /// 箭头大小标识：**头部占主导**加一小段短杆。
    ///
    /// 与工具栏的「箭头」工具图标刻意拉开：那个是 45° 斜线 + 头部，
    /// 这里水平放置且杆故意画得很短，让头部占满绘制区——
    /// 一眼是「头部尺寸」而不是「换成箭头工具」。
    private func drawArrowHeadScaleGlyph(box: CGRect, in context: CGContext) {
        let tip = CGPoint(x: box.maxX - 0.6, y: box.midY)
        let baseX = box.minX + 5
        let halfHeight: CGFloat = 5

        // 杆：只到头部底边，避免线宽在三角形外露出一截。
        context.setLineWidth(1.6)
        context.move(to: CGPoint(x: box.minX + 0.6, y: box.midY))
        context.addLine(to: CGPoint(x: baseX, y: box.midY))
        context.strokePath()

        // 头部：占绘制区右侧三分之二。
        context.beginPath()
        context.move(to: tip)
        context.addLine(to: CGPoint(x: baseX, y: box.midY - halfHeight))
        context.addLine(to: CGPoint(x: baseX, y: box.midY + halfHeight))
        context.closePath()
        context.fillPath()
    }

    /// 涂抹笔刷标识：一个圆环。
    ///
    /// 不用棋盘格（那是马赛克块大小的语义）：笔刷大小说的是**笔头多粗**，
    /// 而「一个圆」正是笔刷在画面上的形状，与旁边的线宽（三条横线）、
    /// 箭头大小（三角头部）三者形状互不重叠。
    /// 画成空心环而不是实心圆：实心白圆与面板左侧的彩色色卡在轮廓上太像。
    private func drawMosaicBrushGlyph(box: CGRect, in context: CGContext) {
        context.setLineWidth(1.6)
        context.strokeEllipse(in: box.insetBy(dx: 1.6, dy: 1.6))
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
        context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        for row in 0 ..< cells {
            for column in 0 ..< cells where (row + column) % 2 == 0 {
                context.fill(CGRect(
                    x: box.minX + CGFloat(column) * cell,
                    y: box.minY + CGFloat(row) * cell,
                    width: cell,
                    height: cell
                ))
            }
        }
        context.restoreGState()
    }

    /// 编号半径的档位图标：三个直径的圆环 + 圆心一点。
    ///
    /// 数字（14 / 20 / 28）不告诉用户那是半径。圆环的大小直接就是
    /// 「编号标记会画多大」。圆心那一点是为了与面板里的彩色色卡
    ///（纯实心圆）区分开。
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
        context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
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
        context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(1.6)
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

    /// 线宽滑块：轨道 + 已填充段 + 圆形手柄 + 右侧数值。
    ///
    /// 数值必须给：滑块只表达「在范围内的大致位置」，而线宽是**模型单位**
    /// （底图像素），用户需要知道写进图里的到底是几像素。
    ///
    /// 手柄用固定半径的圆，而不是「按线宽变化的粗横线」：
    /// 后者在 1~24 的范围里必须先压缩到一个能看到的最大粗细，
    /// 压缩后相邻值（如 20 与 24）看起来一样粗，反而失去了表达力。
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
        context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)

        // 轨道底色：整条范围。
        context.setFillColor(NSColor.white.withAlphaComponent(0.25 * alpha).cgColor)
        context.addPath(CGPath(
            roundedRect: track,
            cornerWidth: track.height / 2,
            cornerHeight: track.height / 2,
            transform: nil
        ))
        context.fillPath()

        // 已填充段：左端到手柄，表达「当前值在范围里的位置」。
        let filled = CGRect(
            x: track.minX,
            y: track.minY,
            width: max(0, knobCenter.x - track.minX),
            height: track.height
        )
        if filled.width > 0 {
            context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            context.addPath(CGPath(
                roundedRect: filled,
                cornerWidth: filled.height / 2,
                cornerHeight: filled.height / 2,
                transform: nil
            ))
            context.fillPath()
        }

        // 手柄：白色圆点。
        let radius: CGFloat = isHovered ? 6 : 5
        context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.fillEllipse(in: CGRect(
            x: knobCenter.x - radius,
            y: knobCenter.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

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

    /// 右对齐画一段小号数值文字（中点对齐到 `anchor` 的纵向位置）。
    private func drawRightAlignedText(
        _ text: String,
        anchor: CGPoint,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        let line = CTLineCreateWithAttributedString(attributed)

        context.saveGState()
        // 视图是左上原点，文字绘制需要 y 轴向上。
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: anchor.x - size.width,
            // 视图原点在左上，文字绘制按 y 向上：基线要下移半个行高，
            // 视觉上（而不是几何上）才是与手柄同心。
            y: anchor.y + size.height / 2
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
        switch family {
        case .pointer:
            drawPointerGlyph(rect: rect, alpha: alpha, in: context)
        case .shape:
            // 形状组显示当前形状，用户一眼能看出选的是矩形还是箭头。
            let shape: AnnotationTool
            switch tool.family {
            case .shape: shape = tool
            default: shape = .rectangle
            }
            drawShapeGlyph(shape, rect: rect, alpha: alpha, in: context)
        case .text:
            drawTextGlyph(rect: rect, alpha: alpha, in: context)
        case .mosaic:
            // 与形状组同理：分组图标跟随组内当前工具。
            // 否则用户用快捷键切到放大镜后，主栏还画着马赛克方块阵列，等于没有反馈。
            if tool == .magnifier {
                drawMagnifierGlyph(rect: rect, alpha: alpha, in: context)
            } else {
                drawMosaicGlyph(rect: rect, alpha: alpha, in: context)
            }
        }
    }

    /// 面板里的具体工具图标。
    private func drawToolGlyph(
        _ tool: AnnotationTool,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        switch tool.family {
        case .shape:
            drawShapeGlyph(tool, rect: rect, alpha: alpha, in: context)
        case .text:
            drawTextGlyph(rect: rect, alpha: alpha, in: context)
        case .mosaic:
            // 马赛克与放大镜同属一组，图标必须分开：两者都是像素处理，
            // 画成同一个方块阵列就再也分不出选的是哪个。
            if tool == .magnifier {
                drawMagnifierGlyph(rect: rect, alpha: alpha, in: context)
            } else {
                drawMosaicGlyph(rect: rect, alpha: alpha, in: context)
            }
        case .pointer:
            drawPointerGlyph(rect: rect, alpha: alpha, in: context)
        }
    }

    private func drawPointerGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        // 先按单位坐标构造箭头，再整体缩放平移到绘制区中心。
        // 直接按绘制区比例写死坐标的话，箭头自身的重心会把它带偏。
        let box = iconBox(in: rect, size: 16)

        // 单位坐标（y 向下）：经典的指针轮廓，尾部落在左上角。
        let outline: [CGPoint] = [
            CGPoint(x: 0.00, y: 0.00),
            CGPoint(x: 0.00, y: 1.00),
            CGPoint(x: 0.26, y: 0.72),
            CGPoint(x: 0.45, y: 1.00),
            CGPoint(x: 0.63, y: 0.90),
            CGPoint(x: 0.44, y: 0.63),
            CGPoint(x: 0.82, y: 0.62),
        ]

        let path = CGMutablePath()
        for (index, point) in outline.enumerated() {
            let mapped = CGPoint(
                x: box.minX + point.x * box.width,
                y: box.minY + point.y * box.height
            )
            if index == 0 {
                path.move(to: mapped)
            } else {
                path.addLine(to: mapped)
            }
        }
        path.closeSubpath()

        context.saveGState()
        context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    /// 形状组工具的图标。
    ///
    /// 分派必须**穷尽到每个工具**，不能留宽泛的 `default`。
    ///
    /// 上一版只写了 `line` / `arrow` 两个分支，其余全部落进 `default` 画成同一个
    /// 空心方框——于是编号、高亮、测量、手绘、曲线箭头五个工具在面板里长得一模一样，
    /// 用户只能靠一个个试才知道哪个是哪个。这类「静默降级」不会编译报错，
    /// 也不会让任何诊断失败，只能靠肉眼看出「好几个都没有图标」。
    ///
    /// 显式列出全部 case 之后，将来往 `AnnotationTool` 里新增形状工具会**编译不过**，
    /// 强制补齐图标，而不是再退化成一个方框。
    private func drawShapeGlyph(
        _ shape: AnnotationTool,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let box = iconBox(in: rect)

        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch shape {
        case .rectangle:
            drawRectangleGlyph(box: box, in: context)

        case .line:
            drawLineGlyph(box: box, in: context)

        case .arrow:
            drawArrowGlyph(box: box, alpha: alpha, in: context)

        case .numbering:
            drawNumberingGlyph(box: box, alpha: alpha, in: context)

        case .highlight:
            drawHighlightGlyph(box: box, alpha: alpha, in: context)

        case .measure:
            drawMeasureGlyph(box: box, in: context)

        case .freehand:
            drawFreehandGlyph(box: box, in: context)

        case .curvedArrow:
            drawCurvedArrowGlyph(box: box, alpha: alpha, in: context)

        case .pointer, .text, .mosaic, .magnifier:
            // 这四个不属于形状组，两个调用方都先按 family 分派，正常路径到不了这里。
            // 仍然显式列出（而不是交给 `default`）的理由见方法头。
            drawRectangleGlyph(box: box, in: context)
        }

        context.restoreGState()
    }

    /// 矩形：一个空心方框。
    private func drawRectangleGlyph(box: CGRect, in context: CGContext) {
        context.stroke(box)
    }

    /// 直线：一条右下到左上的斜线。
    private func drawLineGlyph(box: CGRect, in context: CGContext) {
        context.move(to: CGPoint(x: box.minX, y: box.maxY))
        context.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        context.strokePath()
    }

    /// 箭头：斜线 + 实心箭头头部。
    private func drawArrowGlyph(box: CGRect, alpha: CGFloat, in context: CGContext) {
        context.move(to: CGPoint(x: box.minX, y: box.maxY))
        context.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        context.strokePath()

        let head = CGMutablePath()
        head.move(to: CGPoint(x: box.maxX, y: box.minY))
        head.addLine(to: CGPoint(x: box.maxX - box.width * 0.38, y: box.minY + box.height * 0.10))
        head.addLine(to: CGPoint(x: box.maxX - box.width * 0.10, y: box.minY + box.height * 0.38))
        head.closeSubpath()
        context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.addPath(head)
        context.fillPath()
    }

    /// 编号：圆圈 + 圈内的序号。
    ///
    /// 圈里的「1」走文字渲染而不是手绘折线：竖笔加起笔小撇在 12pt 的内径里，
    /// 撇短了糊成一根「丨」，长了读成「7」，交给字体渲染才稳定。
    private func drawNumberingGlyph(box: CGRect, alpha: CGFloat, in context: CGContext) {
        context.strokeEllipse(in: box.insetBy(dx: 1, dy: 1))
        drawCenteredGlyphText(
            "1",
            pointSize: 10,
            center: CGPoint(x: box.midX, y: box.midY),
            alpha: alpha,
            in: context
        )
    }

    /// 高亮：两行示意文字，下面一行被一条半透明色带盖住。
    ///
    /// 不用「一个半透明矩形」表示：那样与矩形图标只差填充方式，
    /// 在 16pt 绘制区里几乎分不出来。高亮工具的作用是标出**已有内容**，
    /// 画面上先有内容，这层意思才立得住。
    private func drawHighlightGlyph(box: CGRect, alpha: CGFloat, in context: CGContext) {
        // 色带先画，文字行压在它上面，才读得出「被盖住的是文字」。
        context.saveGState()
        context.setFillColor(NSColor.white.withAlphaComponent(alpha * 0.5).cgColor)
        context.fill(CGRect(
            x: box.minX,
            y: box.minY + box.height * 0.52,
            width: box.width,
            height: box.height * 0.30
        ))
        context.restoreGState()

        context.setLineWidth(1.4)
        // 第一行：完整一行，落在色带上方。
        context.move(to: CGPoint(x: box.minX + 0.6, y: box.minY + 3.4))
        context.addLine(to: CGPoint(x: box.maxX - 0.6, y: box.minY + 3.4))
        // 第二行：落在色带里，右侧短一截——等长会读成两条条纹而不是一行字。
        context.move(to: CGPoint(x: box.minX + 0.6, y: box.minY + 10.2))
        context.addLine(to: CGPoint(x: box.maxX - 4.4, y: box.minY + 10.2))
        context.strokePath()
    }

    /// 测量：一把带刻度的尺子。
    ///
    /// 不用「两端带箭头的横线」：那与箭头图标的差别只剩多一个三角，
    /// 而测量工具要表达的是「量出长度」，尺子的横边加刻度没有第二种读法。
    private func drawMeasureGlyph(box: CGRect, in context: CGContext) {
        let ruler = CGRect(
            x: box.minX + 0.6,
            y: box.midY - 3.4,
            width: box.width - 1.2,
            height: 6.8
        )
        context.stroke(ruler)

        // 刻度自尺子上边缘向下，长短交替：等长会读成一排栅栏。
        context.saveGState()
        context.setLineWidth(1.2)
        let ticks: [CGFloat] = [0.2, 0.4, 0.6, 0.8]
        for (index, fraction) in ticks.enumerated() {
            let x = ruler.minX + ruler.width * fraction
            let length: CGFloat = index.isMultiple(of: 2) ? 1.8 : 2.8
            context.move(to: CGPoint(x: x, y: ruler.minY))
            context.addLine(to: CGPoint(x: x, y: ruler.minY + length))
        }
        context.strokePath()
        context.restoreGState()
    }

    /// 手绘：一条 S 形自由笔迹。
    ///
    /// 必须与直线、曲线箭头同时拉开距离：直线不带弯，曲线箭头带头部，
    /// 手绘是两端都不收口的连续波浪，三者摆在一起才不会互相冒充。
    private func drawFreehandGlyph(box: CGRect, in context: CGContext) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: box.minX + 0.8, y: box.maxY - 2.4))
        path.addCurve(
            to: CGPoint(x: box.maxX - 0.8, y: box.minY + 2.4),
            control1: CGPoint(x: box.minX + 4.6, y: box.minY + 0.4),
            control2: CGPoint(x: box.maxX - 4.6, y: box.maxY - 0.4)
        )
        context.addPath(path)
        context.strokePath()
    }

    /// 曲线箭头：一段弧 + 沿弧末端切线方向的实心箭头。
    ///
    /// 箭头头部不能照搬箭头图标的 45° 硬编码角度：弧线一弯，
    /// 头部与笔迹就会差出一个折角，读起来像「两笔画错的线」。
    /// 二次贝塞尔的终点切线方向就是 `end - control`，照它摆头部才对得齐。
    private func drawCurvedArrowGlyph(box: CGRect, alpha: CGFloat, in context: CGContext) {
        let start = CGPoint(x: box.minX + 1, y: box.maxY - 1.4)
        let end = CGPoint(x: box.maxX - 1.6, y: box.minY + 3.6)
        let control = CGPoint(x: box.minX + 1.4, y: box.minY + 1.4)

        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        context.addPath(path)
        context.strokePath()

        let tangent = CGPoint(x: end.x - control.x, y: end.y - control.y)
        let tangentLength = max(1, (tangent.x * tangent.x + tangent.y * tangent.y).squareRoot())
        let unit = CGPoint(x: tangent.x / tangentLength, y: tangent.y / tangentLength)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        let headLength: CGFloat = 4.6
        let headHalfWidth: CGFloat = 2.3
        let base = CGPoint(
            x: end.x - unit.x * headLength,
            y: end.y - unit.y * headLength
        )

        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: CGPoint(
            x: base.x + normal.x * headHalfWidth,
            y: base.y + normal.y * headHalfWidth
        ))
        head.addLine(to: CGPoint(
            x: base.x - normal.x * headHalfWidth,
            y: base.y - normal.y * headHalfWidth
        ))
        head.closeSubpath()
        context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.addPath(head)
        context.fillPath()
    }

    private func drawTextGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        let box = iconBox(in: rect)
        drawCenteredGlyphText(
            "T",
            pointSize: 16,
            center: CGPoint(x: box.midX, y: box.midY),
            alpha: alpha,
            in: context
        )
    }

    /// 在指定中心画一段短文字（「T」「1」这类以字形充当图标的绘制区）。
    ///
    /// 垂直居中用 **capHeight** 而不是 (ascent - descent)/2：
    /// ascent 里含了重音符号等大写字母用不到的空间，按它居中会让字形整体偏低；
    /// 大写字母的视觉高度就是 capHeight，把它的中点对齐到绘制区中心，
    /// 才对得齐旁边的矩形、马赛克这类几何图标。
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
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
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

    private func drawMosaicGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        let box = iconBox(in: rect)
        let cell = box.width / 3

        context.saveGState()
        context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        for row in 0 ..< 3 {
            for column in 0 ..< 3 where (row + column) % 2 == 0 {
                context.fill(CGRect(
                    x: box.minX + CGFloat(column) * cell,
                    y: box.minY + CGFloat(row) * cell,
                    width: cell,
                    height: cell
                ))
            }
        }
        context.restoreGState()
    }

    /// 放大镜：一个镜片圆 + 一条 45° 手柄。
    ///
    /// 镜片里不再画任何东西（不画「+」、也不画被放大的内容）：
    /// 内径只有 8pt 左右，多画一笔就糊成一团灰块，而圆加手柄本身已无歧义。
    private func drawMagnifierGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        let box = iconBox(in: rect)
        let diameter: CGFloat = 11
        let lens = CGRect(x: box.minX, y: box.minY, width: diameter, height: diameter)

        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.strokeEllipse(in: lens)

        // 手柄从圆周的右下 45° 处伸出，末端落在绘制区角上，
        // 这样「一圆一笔」的总体量与其他图标一致。
        let radius = diameter / 2
        let diagonal = radius * CGFloat(2).squareRoot() / 2
        context.move(to: CGPoint(x: lens.midX + diagonal, y: lens.midY + diagonal))
        context.addLine(to: CGPoint(x: box.maxX - 0.4, y: box.maxY - 0.4))
        context.strokePath()

        context.restoreGState()
    }

    /// 拷贝图标：两张错位的圆角矩形。
    private func drawCopyGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        let box = iconBox(in: rect)
        let cardWidth = box.width * 0.62
        let cardHeight = box.height * 0.70
        let offset = box.width * 0.22

        // 图形实际占用范围：宽 = 错位量 + 卡片宽，高 = 错位量 + 卡片高。
        //
        // 按**占用范围**居中，而不是让某一张卡片居中：两张卡片错开之后，
        // 后卡比前卡向左上各多出一截，按单卡定位会让整体偏下、偏左
        //（实测 dy=+1.12、dx=-1.25）。
        let contentWidth = offset + cardWidth
        let contentHeight = offset + cardHeight
        let originX = box.minX + (box.width - contentWidth) / 2
        let originY = box.minY + (box.height - contentHeight) / 2
        let color = NSColor.white.withAlphaComponent(alpha)

        context.saveGState()
        context.setLineWidth(1.5)
        context.setLineJoin(.round)

        // 后面那张只画露出来的三条边（左、上、下），避免与前一张叠成一团。
        // 它与前一张**等大**，只是向左上错开了 offset——等大才能让整体
        // 包围盒仍是一个矩形，也才谈得上「居中」。
        context.setStrokeColor(color.withAlphaComponent(alpha * 0.55).cgColor)
        context.beginPath()
        context.move(to: CGPoint(x: originX + offset, y: originY))
        context.addLine(to: CGPoint(x: originX, y: originY))
        context.addLine(to: CGPoint(x: originX, y: originY + cardHeight))
        context.addLine(to: CGPoint(x: originX + offset, y: originY + cardHeight))
        context.strokePath()

        // 前面那张画完整轮廓。
        context.setStrokeColor(color.cgColor)
        context.addPath(CGPath(
            roundedRect: CGRect(
                x: originX + offset,
                y: originY + offset,
                width: cardWidth,
                height: cardHeight
            ),
            cornerWidth: 2.5,
            cornerHeight: 2.5,
            transform: nil
        ))
        context.strokePath()

        context.restoreGState()
    }

    /// 保存图标：向下的箭头落在托盘中。
    private func drawSaveGlyph(rect: CGRect, alpha: CGFloat, in context: CGContext) {
        let box = iconBox(in: rect)
        let color = NSColor.white.withAlphaComponent(alpha)
        let centerX = box.midX

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // 竖杆。
        context.beginPath()
        context.move(to: CGPoint(x: centerX, y: box.minY + 1))
        context.addLine(to: CGPoint(x: centerX, y: box.midY + 2))
        context.strokePath()

        // 箭头（实心三角）。
        let tip = CGPoint(x: centerX, y: box.midY + 4)
        context.beginPath()
        context.move(to: CGPoint(x: tip.x - 3.2, y: tip.y - 3.4))
        context.addLine(to: CGPoint(x: tip.x + 3.2, y: tip.y - 3.4))
        context.addLine(to: tip)
        context.closePath()
        context.fillPath()

        // 托盘。
        context.beginPath()
        context.move(to: CGPoint(x: box.minX + 1, y: box.midY - 2.5))
        context.addLine(to: CGPoint(x: box.minX + 1, y: box.maxY - 1))
        context.addLine(to: CGPoint(x: box.maxX - 1, y: box.maxY - 1))
        context.addLine(to: CGPoint(x: box.maxX - 1, y: box.midY - 2.5))
        context.strokePath()

        context.restoreGState()
    }

    /// 撤销/重做图标：一段留下缺口的圆弧，缺口一端接一个沿切线方向的箭头。
    ///
    /// 三个几何决定，都对应上一版的一处失效：
    ///
    /// - **弧用显式采样，不用 `CGContext.addArc`**。后者的 `clockwise`
    ///   语义会随坐标系翻转而反号：上一版 undo 与 redo 只差这一个参数，
    ///   结果一个画满 270°、另一个只剩 72°，退化成一小段钩子——
    ///   两个本该成对的图标因此看起来像两个不相干的符号。
    /// - **箭头沿切线摆放**。上一版把箭头三个顶点写成与端点无关的固定偏移，
    ///   弧转了一圈箭头却始终朝着同一个方向，「回转」这层意思整个丢掉。
    /// - **缺口朝正下方**。缺口留在上方时，弧的两肩被压扁，
    ///   认起来更像「刷新」而不是「回退」；朝下时两侧弧肩最完整。
    private func drawHistoryGlyph(
        isUndo: Bool,
        rect: CGRect,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let box = iconBox(in: rect)
        // 半径收到「绘制区一半再减半个线宽」，弧的外沿才刚好贴住绘制区。
        let radius = box.width / 2 - 0.8

        // 两个方向互为镜像：
        // undo 从左下起、逆时针经上方绕到右下；redo 从右下起、顺时针经上方绕到左下。
        let fromDegrees: CGFloat = isUndo ? 45 : 135
        let sweepDegrees: CGFloat = isUndo ? -270 : 270

        // 先按绘制区中心布置几何，再**整体平移到实际包围盒居中**。
        //
        // 这个图标按几何中心定位必然偏：弧缺一个 90° 扇区（右下方），
        // 而箭头又伸向左上方，两侧的「最远点」并不对称——实测偏上 1.0pt、
        // 横向偏 1.1pt。而且弧与箭头必须**一起**平移，各自居中会让他俩错位。
        //
        // 描边会把路径外扩半个线宽，所以参与测量的包围盒也要先外扩。
        let center = CGPoint(x: box.midX, y: box.midY)
        let strokeOutset: CGFloat = 0.8

        let arc = CGMutablePath()
        let points = arcPoints(
            center: center,
            radius: radius,
            fromDegrees: fromDegrees,
            sweepDegrees: sweepDegrees
        )
        arc.move(to: points[0])
        for point in points.dropFirst() {
            arc.addLine(to: point)
        }

        let head = CGMutablePath()
        let headPoints = tangentArrowPoints(
            center: center,
            radius: radius,
            endDegrees: fromDegrees + sweepDegrees,
            sweepDegrees: sweepDegrees
        )
        head.move(to: headPoints[0])
        head.addLine(to: headPoints[1])
        head.addLine(to: headPoints[2])

        let bounds = arc.boundingBoxOfPath
            .insetBy(dx: -strokeOutset, dy: -strokeOutset)
            .union(head.boundingBoxOfPath.insetBy(dx: -strokeOutset, dy: -strokeOutset))
        var shift = CGAffineTransform(
            translationX: box.midX - bounds.midX,
            y: box.midY - bounds.midY
        )

        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if let movedArc = arc.copy(using: &shift) {
            context.addPath(movedArc)
        }
        context.strokePath()

        if let movedHead = head.copy(using: &shift) {
            context.addPath(movedHead)
        }
        context.strokePath()
    }

    /// 圆弧采样点。
    ///
    /// 角度用**视觉角度**：0° 指向右、90° 指向下（本视图 y 轴向下），
    /// 角度增大对应屏幕上的顺时针。显式采样换来的确定性是值得的——
    /// 端点角度与切线方向都能直接算出来，箭头才可能摆正。
    private func arcPoints(
        center: CGPoint,
        radius: CGFloat,
        fromDegrees: CGFloat,
        sweepDegrees: CGFloat,
        steps: Int = 48
    ) -> [CGPoint] {
        (0 ... steps).map { index in
            let ratio = CGFloat(index) / CGFloat(steps)
            let radian = (fromDegrees + sweepDegrees * ratio) * .pi / 180
            return CGPoint(
                x: center.x + radius * cos(radian),
                y: center.y + radius * sin(radian)
            )
        }
    }

    /// 弧终点处切线箭头的三个顶点（左后、尖端、右后）。
    ///
    /// 与弧一样**先返回几何、由调用方统一平移**：两者必须一起居中，
    /// 各自居中会让箭头脱离弧的端点。
    ///
    /// - Parameters:
    ///   - center: 圆弧圆心。
    ///   - radius: 圆弧半径。
    ///   - endDegrees: 弧终点的视觉角度。
    ///   - sweepDegrees: 弧的扫描方向；负值表示终点处的「前进方向」与角度增大方向相反。
    private func tangentArrowPoints(
        center: CGPoint,
        radius: CGFloat,
        endDegrees: CGFloat,
        sweepDegrees: CGFloat,
        length: CGFloat = 4,
        halfWidth: CGFloat = 2
    ) -> [CGPoint] {
        let radian = endDegrees * .pi / 180
        let tip = CGPoint(
            x: center.x + radius * cos(radian),
            y: center.y + radius * sin(radian)
        )

        // 角度增大方向的切线；再按扫描方向取反，得到弧真正的行进方向。
        var direction = CGPoint(x: -sin(radian), y: cos(radian))
        if sweepDegrees < 0 {
            direction = CGPoint(x: -direction.x, y: -direction.y)
        }
        let normal = CGPoint(x: -direction.y, y: direction.x)

        return [
            CGPoint(
                x: tip.x - direction.x * length + normal.x * halfWidth,
                y: tip.y - direction.y * length + normal.y * halfWidth
            ),
            tip,
            CGPoint(
                x: tip.x - direction.x * length - normal.x * halfWidth,
                y: tip.y - direction.y * length - normal.y * halfWidth
            ),
        ]
    }
}
