//
//  AnnotationToolbarLayout.swift
//  AnShotUI
//
//  标注工具栏的布局：常量、条目身份与位置计算。
//
//  ── 为什么把布局从视图里拿出来 ────────────────────────────
//
//  绘制、命中判定与诊断三处必须读**同一份**结果：它们一旦各自计算，
//  就会出现「按钮画在这里、可点击区域在那边」。首版正是绘制时忘了加面板纵向
//  偏移，于是按钮画在主栏位置、热区在下方，整个面板看起来完全错乱——
//  而这类缺陷在自动化里只能靠「按坐标合成点击」才暴露得出来。
//
//  这里不持有视图与绘图上下文：输入是当前工具、样式、历史可用性与展开状态，
//  输出是每个条目的区域。因此它可以被独立断言，也不依赖窗口是否在屏上。
//

import AnShotCore
import AppKit

/// 工具栏的布局计算。
struct AnnotationToolbarLayout {

    // MARK: - 布局常量

    static let barHeight: CGFloat = 36
    static let panelHeight: CGFloat = 32
    static let padding: CGFloat = 8
    static let itemSpacing: CGFloat = 2
    static let groupSpacing: CGFloat = 6
    static let separatorWidth: CGFloat = 1
    static let iconButtonSize: CGFloat = 28
    static let swatchSize: CGFloat = 19
    static let swatchSpacing: CGFloat = 4
    static let textButtonMinWidth: CGFloat = 34

    // MARK: - 滑块几何

    /// 滑块的占用宽度：标识图标 + 轨道 + 右侧读数。
    ///
    /// 106pt 比它取代的控件（三个 28pt 图标按钮 + 两个 2pt 间距 = 88pt）宽 18pt，
    /// 这是有意的：轨道太短时 1~24 的范围内每一像素只能分到不到 2pt，
    /// 拖动会显得「一格一格地跳」。面板总宽因此从 535pt 增至 553pt，
    /// 仍在常见屏幕宽度内。
    ///
    /// 后来加进去的标识图标（左端 16pt）**没有再占宽**：
    /// 从一个滑块扩成两个之后（箭头工具下同时出现线宽与箭头大小），
    /// 两者只靠「轨道 + 数字」完全同形，用户分不出哪个控制什么；
    /// 图标从原有的 106pt 里重新分配（轨道从 68pt 收到 48pt），
    /// 面板宽度保持不变。代价仅是拖动精度略降，而 48pt 覆盖 1~24px
    /// 仍是每像素 2pt，足够精确。
    static let sliderWidth: CGFloat = 106
    /// 滑块左端标识图标的尺寸。
    static let sliderIconSize: CGFloat = 16
    /// 标识图标与轨道之间的间距。
    static let sliderIconGap: CGFloat = 4
    /// 滑块右端留给数值读数的宽度。按最长读数「24.5」定：
    /// 11pt 字体下约 22pt，留 26pt 才不会顶到面板右边缘。
    static let sliderValueWidth: CGFloat = 26
    /// 轨道两端各留的余量（至少容下手柄半径），避免手柄贴到条目边界之外。
    static let sliderTrackInset: CGFloat = 6
    /// 轨道高度。
    static let sliderTrackHeight: CGFloat = 3

    /// 滑块轨道在条目矩形内的位置。
    ///
    /// 绘制、命中、诊断三处必须读这一份几何。滑块是工具栏上唯一
    /// 「值由坐标决定」的控件，两边各算一次必然错位：轨道画在 A 处、
    /// 拖动却从 B 处取值，表现就是「指针还没到尽头，值已经到顶了」。
    static func sliderTrack(in rect: CGRect) -> CGRect {
        let left = rect.minX + sliderIconSize + sliderIconGap + sliderTrackInset
        let right = rect.maxX - sliderValueWidth - sliderTrackInset
        return CGRect(
            x: left,
            y: rect.midY - sliderTrackHeight / 2,
            width: max(1, right - left),
            height: sliderTrackHeight
        )
    }

    /// 把横坐标映射成滑块的 0...1 比例；越界钳制。
    static func sliderFraction(of x: CGFloat, in rect: CGRect) -> Double {
        let track = sliderTrack(in: rect)
        guard track.width > 0 else { return 0 }
        let clamped = min(max(x, track.minX), track.maxX)
        return Double((clamped - track.minX) / track.width)
    }

    // MARK: - 条目身份

    /// 可点击项的身份。
    ///
    /// 不是 `private`：诊断需要按语义拿到项的真实坐标来合成点击。
    /// 直接调编辑器方法证明不了「按钮画在哪里、点击落在哪里」，
    /// 而那正是 P4 出过问题的地方。
    enum Kind: Hashable {
        case family(AnnotationTool.Family)
        case tool(AnnotationTool)
        case color(RGBAColor)
        /// 线宽滑块（连续值）。取代了旧的三档按钮：线宽是连续量，
        /// 档位制在细线/粗线两头都不够用。
        case lineWidthSlider
        /// 箭头头部大小滑块（连续倍率，仅箭头类工具）。
        case arrowHeadScaleSlider
        case fontSize(Double)
        case mosaicMode(MosaicToolMode)
        case mosaicBlockSize(Double)
        /// 涂抹笔刷大小滑块（连续值，仅涂抹模式）。
        case mosaicBrushDiameterSlider
        /// 编号圆的半径（仅编号工具）。
        case numberingRadius(Double)
        /// 放大镜倍率（仅放大镜工具）。
        case magnifierZoom(Double)
        /// 曲线箭头的弯曲程度（仅曲线箭头工具）。
        case curvedArrowBend(Double)
        case colorButton
        case colorPicker
        case undo
        case redo
        case copy
        case save
        /// 以当前选区直接开始录制（不做标注，直接进入录制流程）。
        case record
        /// 以当前选区开始滚动截图（长截图）。
        case longScreenshot
        /// 识别当前选区里的文字（OCR）。
        case recognizeText
        /// 把当前截图钉在屏幕上（固定截图）。
        case pin
        /// 删除当前选中的标注。只在指针工具 + 有选中时出现。
        case deleteSelected
    }

    /// 一个已布局的条目。
    struct Item {
        let kind: Kind
        let rect: CGRect
        let isEnabled: Bool
    }

    // MARK: - 布局输入

    var tool: AnnotationTool = .pointer
    var style: AnnotationStyle = .default
    var canUndo = false
    var canRedo = false
    /// 面板是否展开。点当前分组会收起，再点展开。
    var isPanelExpanded = true
    /// 是否显示「录制 / 长截图 / OCR」三个抓屏动作。
    ///
    /// 编辑磁盘图片时它们没有意义（底图不是屏幕），但按钮若只是点了没反应，
    /// 用户会当成 bug；因此从布局里移除，连带工具栏宽度也一起收窄。
    var allowsCaptureActions = true
    /// 指针工具下是否有被选中的标注。
    ///
    /// 指针分组本身没有可调项，面板只在「有选中标注」时才有内容；
    /// 没有选中时面板仍是空的（不占高度，也不画背景）。
    var hasSelectedAnnotation = false
    /// 选中的标注是否是文字。
    ///
    /// 文字的样式槽是字号而不是线宽，面板据此换掉那一组控件。
    /// 只在 `hasSelectedAnnotation` 为真时有意义。
    var selectedAnnotationIsText = false
    /// 选中的标注是否有可改的颜色槽（马赛克是像素处理，没有颜色）。
    var selectedAnnotationSupportsColor = true
    /// 选中的标注是否有可改的线宽（高亮与文字没有线宽；文字改用字号）。
    ///
    /// 不支持的条目连位置都不占：摆一个点了没反应的滑块
    /// 与工具栏里放一个无效按钮是同一种缺陷。
    var selectedAnnotationSupportsLineWidth = true

    // MARK: - 查询

    /// 某个可点击项的中心点（本视图坐标）；不存在或不可用时为 nil。
    func itemCenter(_ kind: Kind) -> CGPoint? {
        if let item = layoutBar().items.first(where: { $0.kind == kind }) {
            return CGPoint(x: item.rect.midX, y: item.rect.midY)
        }
        if let item = layoutPanel().items.first(where: { $0.kind == kind }) {
            return CGPoint(x: item.rect.midX, y: item.rect.midY)
        }
        return nil
    }

    /// 当前所有可见项及其中心，便于诊断整体检查。
    func visibleItemCenters() -> [Kind: CGPoint] {
        var result: [Kind: CGPoint] = [:]
        for item in layoutBar().items {
            result[item.kind] = CGPoint(x: item.rect.midX, y: item.rect.midY)
        }
        for item in layoutPanel().items {
            result[item.kind] = CGPoint(x: item.rect.midX, y: item.rect.midY)
        }
        return result
    }

    // MARK: - 尺寸

    /// 主栏尺寸。
    var barSize: CGSize {
        layoutBar().size
    }

    /// 当前分组的面板尺寸；该组没有设置项时为 `.zero`。
    var panelSize: CGSize {
        guard isPanelExpanded else { return .zero }
        return layoutPanel().size
    }

    /// 整个工具栏（主栏 + 面板）的尺寸。
    var toolbarSize: CGSize {
        let bar = barSize
        let panel = panelSize
        guard panel.height > 0 else { return bar }
        return CGSize(
            width: max(bar.width, panel.width),
            height: bar.height + Self.itemSpacing + panel.height
        )
    }

    /// 工具栏相对选区的落点（本视图坐标）。
    ///
    /// 三级避让：优先贴在**尺寸标签**下方；放不下翻到选区上方（标签之上）；
    /// 两边都不够就落在视图内，宁可紧贴也不越界。中间那层不是可选的——
    /// 顶部贴边的小选区若只处理「下方」，会算出负的 y 而跑出屏幕。
    ///
    /// - Parameters:
    ///   - labelReserve: 要给尺寸标签留出的纵向空间。
    ///     尺寸标签总是紧贴选区（见 `SelectionChromeRenderer.drawSizeLabel`），
    ///     工具栏不避让它就会盖住尺寸读数——实测踩过。
    static func toolbarOrigin(
        selection: CGRect,
        toolbarSize: CGSize,
        labelReserve: CGFloat,
        viewBounds: CGRect,
        gap: CGFloat
    ) -> CGPoint {
        // 优先贴在标签下方；放不下就翻到选区上方（标签之上）；
        // 两边都不够时落在视图内，宁可紧贴也不越界。
        let below = selection.maxY + labelReserve + gap
        let above = selection.minY - labelReserve - gap - toolbarSize.height

        let y: CGFloat
        if below + toolbarSize.height <= viewBounds.height - gap {
            y = below
        } else if above >= gap {
            y = above
        } else {
            // 选区几乎占满整个视图（整屏截图、图片编辑）：上下都放不下。
            // 放顶部而不是底部——尺寸标签在下方，放底部会正好压住读数。
            y = gap
        }

        // 水平方向与选区左对齐，并钳制在视图内。
        let maxX = max(gap, viewBounds.width - gap - toolbarSize.width)
        let x = min(max(gap, selection.minX), maxX)
        return CGPoint(x: x, y: y)
    }

    // MARK: - 布局

    func layoutBar() -> (items: [Item], size: CGSize) {
        let centerY = (Self.barHeight - Self.iconButtonSize) / 2
        let iconSize = CGSize(width: Self.iconButtonSize, height: Self.iconButtonSize)
        var cursor = ItemRowCursor(x: Self.padding)
        // 本函数的条目**全部**是等尺寸图标按钮，故把 size 与 y 收敛进这个局部简写，
        // 免得每一行都重复传同样的两个值。
        func place(_ kind: Kind, leading: CGFloat, isEnabled: Bool = true) {
            cursor.append(kind, leading: leading, size: iconSize, y: centerY, isEnabled: isEnabled)
        }

        // 工具家族组。首个之前不留空隙（左侧留白由游标初值承担）。
        let families: [AnnotationTool.Family] = [.pointer, .shape, .text, .mosaic]
        for (index, family) in families.enumerated() {
            place(.family(family), leading: index == 0 ? 0 : Self.itemSpacing)
        }

        // 颜色入口：仅在当前工具取色时才存在。
        // 不取色的工具（马赛克）连位置都不占——布局、命中、诊断三者
        // 读的都是这份结果，所以「不存在」在任何一侧都成立。
        if style.color(for: tool) != nil {
            place(.colorButton, leading: Self.groupSpacing)
        }

        // 历史组。与工具组之间留一条空隙而不是画线：工具条很小，竖线反而显脏。
        place(.undo, leading: Self.groupSpacing, isEnabled: canUndo)
        // 撤销与重做是同一组内的两个按钮，故用 itemSpacing 而非 groupSpacing。
        place(.redo, leading: Self.itemSpacing, isEnabled: canRedo)

        // 导出组：拷贝与保存。
        // 放在最右侧：它们是「结束本次会话」的动作，与左侧的编辑动作
        // 在语义上不同，位置上分开可以避免误点。
        // 录制放在导出组最前：它与拷贝/保存同属「结束本次会话的动作」，
        // 但语义是「改用另一种方式捕获同一区域」。
        if allowsCaptureActions {
            place(.record, leading: Self.groupSpacing)
            place(.longScreenshot, leading: Self.itemSpacing)
            place(.recognizeText, leading: Self.itemSpacing)
            place(.pin, leading: Self.itemSpacing)
        } else {
            // 图片编辑：三个抓屏动作不存在，导出组从「钉住」开始。
            // 这里仍留 groupSpacing，保证与撤销/重做之间保持同一段空隙。
            place(.pin, leading: Self.groupSpacing)
        }
        place(.copy, leading: Self.itemSpacing)
        place(.save, leading: Self.itemSpacing)

        // 右侧留白
        cursor.advance(Self.padding)

        return (cursor.items, CGSize(width: cursor.x, height: Self.barHeight))
    }

    /// 顺序排布条目的游标。
    ///
    /// 抽出来的理由：`layoutBar` 与 `layoutShapePanel` 原先共有 20 余处
    /// 「append 一个条目 + 把 x 前进一格」的重复样板，每处的差异只有
    /// 条目身份、尺寸、纵坐标、可用性、以及**它前面要留多少空隙**。
    /// 逐处展开不仅冗长，还会让「每个条目都落在自己的位置上、互不重叠」
    /// 这一不变量埋没在重复里——而它一旦被写错一处，表现是某个图标偏几像素，
    /// 肉眼要对照才发现（`AnnotationToolbarLayoutTests` 现在能拦住）。
    ///
    /// `leading` 表达「这个条目**之前**的空隙」而不是上一个之后的：
    /// 这样每个条目的间距要求都写在它自己那一行，读代码时不必回看上一行。
    private struct ItemRowCursor {
        private(set) var items: [Item] = []
        private(set) var x: CGFloat

        init(x: CGFloat) {
            self.x = x
        }

        /// 追加一个条目，并在它之前留出 `leading` 的空隙。
        mutating func append(
            _ kind: Kind,
            leading: CGFloat,
            size: CGSize,
            y: CGFloat,
            isEnabled: Bool = true
        ) {
            x += leading
            items.append(Item(
                kind: kind,
                rect: CGRect(x: x, y: y, width: size.width, height: size.height),
                isEnabled: isEnabled
            ))
            x += size.width
        }

        /// 在当前光标处再前进一段距离（用于末尾留白）。
        mutating func advance(_ distance: CGFloat) {
            x += distance
        }
    }

    func layoutPanel() -> (items: [Item], size: CGSize) {
        guard isPanelExpanded else {
            return ([], .zero)
        }

        let content: (items: [Item], size: CGSize)
        switch tool.family {
        case .pointer:
            // 指针分组平时没有可调项；只有选中了标注，面板才提供
            // 颜色 / 线宽（文字为字号）与删除。
            guard hasSelectedAnnotation else {
                return ([], .zero)
            }
            content = layoutPointerSelectionPanel()
        case .shape:
            content = layoutShapePanel()
        case .text:
            content = layoutTextPanel()
        case .mosaic:
            content = layoutMosaicPanel()
        }

        // 面板项一律返回**含纵向偏移的绝对坐标**。
        //
        // 绘制、命中判定、诊断取坐标三者共用这一份结果；
        // 任何一处自己再加一次偏移都会错位——首版就是绘制时忘了加偏移，
        // 于是按钮画在主栏位置、可点击区域在下方，整个面板看起来完全错乱。
        let offsetY = Self.barHeight + Self.itemSpacing
        let shifted = content.items.map { item in
            Item(
                kind: item.kind,
                rect: item.rect.offsetBy(dx: 0, dy: offsetY),
                isEnabled: item.isEnabled
            )
        }
        return (shifted, content.size)
    }

    /// 指针 + 选中：颜色、线宽（文字为字号）与删除。
    ///
    /// 控件与绘制工具的面板**同源**：色卡、滑块、字号档位都复用
    /// `AnnotationStyle` 的同一份取值，因此样式面板不会出现两套外观。
    /// 差别只在语义——这里的每次改动都作用于**选中的那一条**标注
    ///（见 `OverlayView` 的工具栏回调），而不是「下一笔用什么样式」。
    private func layoutPointerSelectionPanel() -> (items: [Item], size: CGSize) {
        var items: [Item] = []
        var x = Self.padding
        let swatchY = (Self.panelHeight - Self.swatchSize) / 2
        let iconY = (Self.panelHeight - Self.iconButtonSize) / 2
        let buttonY: CGFloat = 3
        let buttonHeight = Self.panelHeight - buttonY * 2

        // 颜色（马赛克没有颜色槽，不摆色卡）
        if selectedAnnotationSupportsColor {
            for (index, color) in AnnotationStyle.palette.enumerated() {
                if index > 0 {
                    x += Self.swatchSpacing
                }
                items.append(Item(
                    kind: .color(color),
                    rect: CGRect(x: x, y: swatchY, width: Self.swatchSize, height: Self.swatchSize),
                    isEnabled: true
                ))
                x += Self.swatchSize
            }

            // 完整取色器入口（与形状/文字面板一致）。
            x += Self.swatchSpacing
            items.append(Item(
                kind: .colorPicker,
                rect: CGRect(x: x, y: swatchY, width: Self.swatchSize, height: Self.swatchSize),
                isEnabled: true
            ))
            x += Self.swatchSize
        }

        // 文字的样式槽是字号，其余标注是线宽（高亮/马赛克没有线宽）。
        if selectedAnnotationIsText {
            if selectedAnnotationSupportsColor {
                x += Self.groupSpacing
            }
            for (index, size) in AnnotationStyle.fontSizes.enumerated() {
                if index > 0 {
                    x += Self.itemSpacing
                }
                items.append(Item(
                    kind: .fontSize(size),
                    rect: CGRect(
                        x: x,
                        y: iconY,
                        width: Self.iconButtonSize,
                        height: Self.iconButtonSize
                    ),
                    isEnabled: true
                ))
                x += Self.iconButtonSize
            }
        } else if selectedAnnotationSupportsLineWidth {
            if selectedAnnotationSupportsColor {
                x += Self.groupSpacing
            }
            items.append(Item(
                kind: .lineWidthSlider,
                rect: CGRect(x: x, y: buttonY, width: Self.sliderWidth, height: buttonHeight),
                isEnabled: true
            ))
            x += Self.sliderWidth
        }

        // 删除放在最后：它是面板里唯一「破坏性」的动作，与样式控件隔开。
        if !items.isEmpty {
            x += Self.groupSpacing
        }
        items.append(Item(
            kind: .deleteSelected,
            rect: CGRect(x: x, y: iconY, width: Self.iconButtonSize, height: Self.iconButtonSize),
            isEnabled: true
        ))
        x += Self.iconButtonSize

        x += Self.padding
        return (items, CGSize(width: x, height: Self.panelHeight))
    }

    private func layoutShapePanel() -> (items: [Item], size: CGSize) {
        let iconY = (Self.panelHeight - Self.iconButtonSize) / 2
        let swatchY = (Self.panelHeight - Self.swatchSize) / 2
        // 数值型选项（编号半径、弯曲度）用文字按钮，与字号/块大小同一套尺寸。
        let buttonY: CGFloat = 3
        let buttonHeight = Self.panelHeight - buttonY * 2

        let iconSize = CGSize(width: Self.iconButtonSize, height: Self.iconButtonSize)
        let swatchSize = CGSize(width: Self.swatchSize, height: Self.swatchSize)
        let sliderSize = CGSize(width: Self.sliderWidth, height: buttonHeight)

        var cursor = ItemRowCursor(x: Self.padding)

        // 具体形状
        for (index, shape) in AnnotationTool.tools(in: .shape).enumerated() {
            cursor.append(
                .tool(shape),
                leading: index == 0 ? 0 : Self.itemSpacing,
                size: iconSize,
                y: iconY
            )
        }

        // 颜色
        for (index, color) in AnnotationStyle.palette.enumerated() {
            cursor.append(
                .color(color),
                leading: index == 0 ? Self.groupSpacing : Self.swatchSpacing,
                size: swatchSize,
                y: swatchY
            )
        }

        // 完整取色器入口：色卡只是高频色的快捷方式，
        // 选任意颜色必须能从面板里直接进系统取色器。
        cursor.append(
            .colorPicker,
            leading: Self.groupSpacing + Self.swatchSpacing,
            size: swatchSize,
            y: swatchY
        )

        // 编号半径：只在编号工具下出现。按工具条件显示，面板不会为其它工具变长。
        //
        // 宽度与位置跟形状图标按钮一致（28pt、垂直居中）：这几个档位现在画的是
        // 图标而不是数字，用文字按钮的尺寸会让它们比旁边的图标偏下半个行高。
        if tool == .numbering {
            for (index, radius) in AnnotationStyle.numberingRadii.enumerated() {
                cursor.append(
                    .numberingRadius(radius),
                    leading: index == 0 ? Self.groupSpacing : Self.itemSpacing,
                    size: iconSize,
                    y: iconY
                )
            }
        }

        // 弯曲程度：只在曲线箭头工具下出现。
        if tool == .curvedArrow {
            for (index, bend) in AnnotationStyle.curvedArrowBends.enumerated() {
                cursor.append(
                    .curvedArrowBend(bend),
                    leading: index == 0 ? Self.groupSpacing : Self.itemSpacing,
                    size: iconSize,
                    y: iconY
                )
            }
        }

        // 箭头大小：只在箭头与曲线箭头下出现。
        // 与弯度档位同一套条件显示的做法：其余工具根本没有箭头头部，
        // 给它们一个无效的滑块只会把面板白白撑宽。
        if tool == .arrow || tool == .curvedArrow {
            cursor.append(
                .arrowHeadScaleSlider,
                leading: Self.groupSpacing,
                size: sliderSize,
                y: buttonY
            )
        }

        // 线宽：一个连续滑块（取代原来的三档按钮）。
        cursor.append(.lineWidthSlider, leading: Self.groupSpacing, size: sliderSize, y: buttonY)

        // 右侧留白
        cursor.advance(Self.padding)

        return (cursor.items, CGSize(width: cursor.x, height: Self.panelHeight))
    }

    private func layoutTextPanel() -> (items: [Item], size: CGSize) {
        var items: [Item] = []
        var x = Self.padding
        let swatchY = (Self.panelHeight - Self.swatchSize) / 2
        let iconY = (Self.panelHeight - Self.iconButtonSize) / 2

        // 字号：档位画的是逐档变大的字母，用图标按钮尺寸。
        for (index, size) in AnnotationStyle.fontSizes.enumerated() {
            if index > 0 {
                x += Self.itemSpacing
            }
            items.append(Item(
                kind: .fontSize(size),
                rect: CGRect(x: x, y: iconY, width: Self.iconButtonSize, height: Self.iconButtonSize),
                isEnabled: true
            ))
            x += Self.iconButtonSize
        }

        x += Self.groupSpacing

        // 颜色
        for (index, color) in AnnotationStyle.palette.enumerated() {
            if index > 0 {
                x += Self.swatchSpacing
            }
            items.append(Item(
                kind: .color(color),
                rect: CGRect(x: x, y: swatchY, width: Self.swatchSize, height: Self.swatchSize),
                isEnabled: true
            ))
            x += Self.swatchSize
        }

        // 完整取色器入口（同形状面板）。
        x += Self.swatchSpacing
        items.append(Item(
            kind: .colorPicker,
            rect: CGRect(x: x, y: swatchY, width: Self.swatchSize, height: Self.swatchSize),
            isEnabled: true
        ))
        x += Self.swatchSize

        x += Self.padding
        return (items, CGSize(width: x, height: Self.panelHeight))
    }

    private func layoutMosaicPanel() -> (items: [Item], size: CGSize) {
        var items: [Item] = []
        var x = Self.padding
        let buttonY: CGFloat = 3
        let buttonHeight = Self.panelHeight - buttonY * 2
        let iconY = (Self.panelHeight - Self.iconButtonSize) / 2

        // 框选 / 涂抹
        for (index, mode) in MosaicToolMode.allCases.enumerated() {
            if index > 0 {
                x += Self.itemSpacing
            }
            let width = textButtonWidth(for: mode.displayName)
            items.append(Item(
                kind: .mosaicMode(mode),
                rect: CGRect(x: x, y: buttonY, width: width, height: buttonHeight),
                isEnabled: true
            ))
            x += width
        }

        x += Self.groupSpacing

        // 块大小：档位画的是粒度递增的块阵，用图标按钮尺寸。
        for (index, size) in AnnotationStyle.mosaicBlockSizes.enumerated() {
            if index > 0 {
                x += Self.itemSpacing
            }
            items.append(Item(
                kind: .mosaicBlockSize(size),
                rect: CGRect(x: x, y: iconY, width: Self.iconButtonSize, height: Self.iconButtonSize),
                isEnabled: true
            ))
            x += Self.iconButtonSize
        }

        // 放大镜倍率：只在放大镜工具下出现（它没有块大小/笔刷概念）。
        if tool == .magnifier {
            for (index, zoom) in AnnotationStyle.magnifierZooms.enumerated() {
                if index > 0 { x += Self.itemSpacing }
                let width = textButtonWidth(for: "\(Int(zoom * 10))x")
                items.append(Item(
                    kind: .magnifierZoom(zoom),
                    rect: CGRect(x: x, y: buttonY, width: width, height: buttonHeight),
                    isEnabled: true
                ))
                x += width
            }
            x += Self.groupSpacing
        }

        // 笔刷大小只在涂抹模式下出现：框选模式没有笔刷。
        if style.mosaicMode == .brush {
            x += Self.groupSpacing
            items.append(Item(
                kind: .mosaicBrushDiameterSlider,
                rect: CGRect(x: x, y: buttonY, width: Self.sliderWidth, height: buttonHeight),
                isEnabled: true
            ))
            x += Self.sliderWidth
        }

        x += Self.padding
        return (items, CGSize(width: x, height: Self.panelHeight))
    }

    private func textButtonWidth(for text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let width = NSAttributedString(string: text, attributes: attributes).size().width
        return max(Self.textButtonMinWidth, ceil(width) + 16)
    }
}
