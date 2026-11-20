//
//  AnnotationToolbarView.swift
//  AnShotUI
//
//  跟随选区浮动的标注工具栏（P6）。
//
//  ── 为什么是「主栏 + 二级面板」而不是全部平铺 ───────────────
//
//  平铺的做法把 6 个工具、6 个颜色、若干档线宽全塞进一行，
//  结果是工具条比选区还宽，而且「换个颜色」和「换个工具」争夺同一行注意力。
//  这里改成：主栏只放**分组**（指针 / 形状 / 文字 / 马赛克 / 撤销 / 重做），
//  点哪个分组就在它下方展开该组的设置面板：
//
//    - 形状面板：矩形 / 直线 / 箭头 + 颜色 + 线宽
//    - 文字面板：字号 + 颜色
//    - 马赛克面板：框选 / 涂抹 + 块大小（涂抹模式再显示笔刷直径）
//
//  样式按工具分组保存在 `AnnotationStyle` 里，面板只切换**分组**，
//  因此调文字颜色不会动到箭头颜色。
//
//  ── 实现约定 ──────────────────────────────────────────────
//
//  按钮位置由 `layoutBar()` / `layoutPanel()` 单点计算，
//  **绘制与命中读同一份结果**。P4 出现过「画面上隐藏了手柄、
//  命中判定却仍然认它们」的缺陷，这里从结构上避免重演。
//

import AppKit
import AnShotCore

/// 自绘的标注工具栏。
///
/// 不使用 `NSButton`：按钮外观需要跟随深色浮层风格，且要精确控制
/// 选中/悬停/禁用三态，自绘比反复配置 `NSButton` 更直接。
final class AnnotationToolbarView: NSView {

    // MARK: - 状态（由覆盖层推入，视图不反向持有编辑数据）

    var tool: AnnotationTool = .pointer {
        didSet {
            guard tool != oldValue else { return }
            lastToolByFamily[tool.family] = tool
            if AnnotationToolbarLayout.isSecondaryTool(tool) {
                lastSecondaryTool = tool
            }
            needsDisplay = true
        }
    }

    /// 记住「更多工具」收纳槽上次选用的具体次高频工具（默认直线）。
    private var lastSecondaryTool: AnnotationTool = .line

    /// 每个分组上次使用的工具。
    ///
    /// 只记录用户在界面里实际切到过的工具；从未使用过的分组没有条目，
    /// 由 `lastTool(in:)` 的调用方回退到该组第一个工具。
    private var lastToolByFamily: [AnnotationTool.Family: AnnotationTool] = [:]

    /// 工具选中高亮是否可见。
    ///
    /// 候选选区（自动识别给出、尚未确认）阶段置 false：此刻会话的真实状态是
    /// 「还在确定选区」，把指针画成选中会让用户以为现在是移动模式
    /// ——这正是用户反馈的困惑来源。
    /// 颜色/线宽这类样式档位不是工具，不受此开关影响。
    var showsToolSelection = true {
        didSet {
            guard showsToolSelection != oldValue else { return }
            needsDisplay = true
        }
    }

    var style: AnnotationStyle = .default {
        didSet {
            guard style != oldValue else { return }
            needsDisplay = true
        }
    }

    var canUndo = false {
        didSet { needsDisplay = true }
    }

    var canRedo = false {
        didSet { needsDisplay = true }
    }

    /// 是否显示「录制 / 长截图 / OCR」三个抓屏动作。
    ///
    /// 图片编辑时置 false：底图来自磁盘，这三个动作无从执行。
    /// 布局随之移除这三个条目，工具栏宽度也一并收窄。
    var allowsCaptureActions = true {
        didSet {
            guard allowsCaptureActions != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 指针工具下是否有被选中的标注（决定面板是否提供样式与删除）。
    var hasSelectedAnnotation = false {
        didSet {
            guard hasSelectedAnnotation != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注是否与当前激活的绘图工具同类型。
    var selectedAnnotationMatchesTool = true {
        didSet {
            guard selectedAnnotationMatchesTool != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注是否是文字（面板换用字号档位而不是线宽滑块）。
    var selectedAnnotationIsText = false {
        didSet {
            guard selectedAnnotationIsText != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注是否是高亮荧光笔（面板改用半透明荧光色板）。
    var selectedAnnotationIsHighlight = false {
        didSet {
            guard selectedAnnotationIsHighlight != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注颜色（指针选中态高亮色卡使用）。
    var selectedAnnotationColor: RGBAColor? {
        didSet {
            guard selectedAnnotationColor != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 当前匹配字体档位高亮的逻辑点字号。
    var activeFontSizeForToolbar: Double? {
        didSet {
            guard activeFontSizeForToolbar != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注是否有可改的颜色槽（马赛克没有）。
    var selectedAnnotationSupportsColor = true {
        didSet {
            guard selectedAnnotationSupportsColor != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注是否有可改的线宽（高亮、文字没有）。
    var selectedAnnotationSupportsLineWidth = true {
        didSet {
            guard selectedAnnotationSupportsLineWidth != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注是否支持手绘风格开关。
    var selectedAnnotationSupportsSketchy = false {
        didSet {
            guard selectedAnnotationSupportsSketchy != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注当前是否处于手绘风格。
    var selectedAnnotationIsSketchy = false {
        didSet {
            guard selectedAnnotationIsSketchy != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注是否支持填充切换（矩形 / 椭圆）。
    var selectedAnnotationSupportsFill = false {
        didSet {
            guard selectedAnnotationSupportsFill != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注当前是否已填充。
    var selectedAnnotationIsFilled = false {
        didSet {
            guard selectedAnnotationIsFilled != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的文字当前是否粗体 / 斜体 / 字体族。
    var selectedAnnotationIsBold = false {
        didSet {
            guard selectedAnnotationIsBold != oldValue else { return }
            needsDisplay = true
        }
    }

    var selectedAnnotationIsItalic = false {
        didSet {
            guard selectedAnnotationIsItalic != oldValue else { return }
            needsDisplay = true
        }
    }

    var selectedAnnotationFontFamily: String? {
        didSet {
            guard selectedAnnotationFontFamily != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注是否为聚光灯及当前压暗透明度。
    var selectedAnnotationIsSpotlight = false {
        didSet {
            guard selectedAnnotationIsSpotlight != oldValue else { return }
            needsDisplay = true
        }
    }

    var selectedAnnotationSpotlightDimOpacity: Double? {
        didSet {
            guard selectedAnnotationSpotlightDimOpacity != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 二级气泡面板相对主栏的展开方向（向下或向上翻转）。
    var panelPlacement: AnnotationToolbarLayout.PanelPlacement = .below {
        didSet {
            guard panelPlacement != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 用户隐藏的主工具栏槽位集合。
    var hiddenSlots: Set<String> = [] {
        didSet {
            guard hiddenSlots != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的标注是否支持马赛克打码效果切换（像素化 / 高斯模糊）。
    var selectedAnnotationSupportsMosaicEffect = false {
        didSet {
            guard selectedAnnotationSupportsMosaicEffect != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的马赛克标注当前效果模式。
    var selectedAnnotationMosaicMode: MosaicMode? {
        didSet {
            guard selectedAnnotationMosaicMode != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 选中的马赛克标注对应的逻辑档位（指针选中时用于面板选中态对齐）。
    var selectedAnnotationMosaicBlockSize: Double? {
        didSet {
            guard selectedAnnotationMosaicBlockSize != oldValue else { return }
            needsDisplay = true
        }
    }

    // MARK: - 回调

    var onSelectTool: ((AnnotationTool) -> Void)?
    var onSelectColor: ((RGBAColor) -> Void)?
    var onSelectLineWidth: ((Double) -> Void)?
    var onSelectFontSize: ((Double) -> Void)?
    /// 删除当前选中的标注（指针 + 选中时面板里的删除按钮）。
    var onDeleteSelected: (() -> Void)?
    var onSelectMosaicMode: ((MosaicToolMode) -> Void)?
    /// 切换马赛克打码效果（像素化 / 高斯模糊）。
    var onSelectMosaicEffectMode: ((MosaicMode) -> Void)?
    var onSelectMosaicBlockSize: ((Double) -> Void)?
    var onSelectMosaicBrushDiameter: ((Double) -> Void)?
    /// 切换手绘风格。
    var onToggleSketchy: (() -> Void)?
    /// 切换矩形/椭圆填充。
    var onToggleFill: (() -> Void)?
    /// 切换文字粗体 / 斜体 / 循环字体族。
    var onToggleTextBold: (() -> Void)?
    var onToggleTextItalic: (() -> Void)?
    var onCycleTextFontFamily: (() -> Void)?
    /// 选择聚光灯焦点外压暗透明度。
    var onSelectSpotlightDimOpacity: ((Double) -> Void)?
    /// 一键取消并退出覆盖层。
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onRecord: (() -> Void)?
    /// 以当前选区开始滚动截图。
    var onLongScreenshot: (() -> Void)?
    /// 识别当前选区里的文字。
    var onRecognizeText: (() -> Void)?
    /// 标注增强的两个可调参数与一个样式参数。
    var onSelectNumberingRadius: ((Double) -> Void)?
    var onSelectMagnifierZoom: ((Double) -> Void)?
    var onSelectCurvedArrowBend: ((Double) -> Void)?
    /// 箭头头部大小的缩放倍率。
    var onSelectArrowHeadScale: ((Double) -> Void)?
    /// 把当前截图钉在屏幕上。
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    /// 按指定格式保存或临时强制弹出另存为面板（`⌥+点击保存` 或右键「保存」菜单）。
    var onSaveAs: ((ExportFormatOption?, Bool) -> Void)?

    /// 打开系统取色器。
    var onOpenColorPanel: (() -> Void)?

    /// 二级面板折叠/展开导致工具栏固有尺寸变化时回调。
    var onIntrinsicSizeChanged: (() -> Void)?

    /// 滑块拖动起止手势事务回调（用于在拖动结束时合并提交一次撤销历史）。
    var onSliderGestureBegan: (() -> Void)?
    var onSliderGestureEnded: (() -> Void)?

    /// 按住工具栏空白背景或拖拽握把拖动时回调（参数为视图坐标下的位移增量）。
    var onDragMove: ((CGSize) -> Void)?

    /// 双击拖拽握把或工具栏空白处，请求一键复位到选区默认停靠位置。
    var onResetPosition: (() -> Void)?

    // MARK: - 布局常量


    // MARK: - 命中项

    /// 面板是否展开。点击当前激活工具可手动收起/展开；落笔绘制时自动轻收起不挡画面。
    private(set) var isPanelExpanded = true

    private var hoveredKind: Kind?
    private var pressedKind: Kind?

    /// 正在拖动的滑块。
    private var draggingSliderKind: Kind?

    /// 是否正在按住工具栏空白区域整体拖动位置。
    private var isDraggingToolbar = false
    private var lastDragScreenPoint: CGPoint = .zero

    /// 悬停瞬时毛玻璃 Tooltip 控制器与延迟任务。
    private let tooltipHUD = ToolbarTooltipHUD()
    private var tooltipDelayWorkItem: DispatchWorkItem?
    /// 滚轮调滑块结束后自动提交撤销事务的去抖定时器。
    private var wheelCommitWorkItem: DispatchWorkItem?
    private var isWheelTransactionActive = false

    override var isHidden: Bool {
        didSet {
            if isHidden {
                hideTooltipImmediately()
                pressedKind = nil
                hoveredKind = nil
            }
        }
    }

    /// 落笔在画布开始绘制或拖动标注时调用：轻收起二级属性气泡，让出全部画布视野。
    func collapsePanelForDrawing() {
        hideTooltipImmediately()
        guard isPanelExpanded else { return }
        isPanelExpanded = false
        needsDisplay = true
        onIntrinsicSizeChanged?()
    }

    /// 切换工具或单击选中已有标注时调用：展开对应工具/标注的属性气泡。
    func expandPanelForInteraction() {
        guard !isPanelExpanded else { return }
        isPanelExpanded = true
        needsDisplay = true
        onIntrinsicSizeChanged?()
    }

    /// 主栏在当前视图坐标系中的纵向原点（供外层在折叠/展开上方气泡时锁定主栏位置不跳动）。
    var barOriginY: CGFloat { layoutInput.barOriginY }

    /// 精准命中判定：主栏与二级气泡之外的透明空气区返回 `false`，100% 穿透回画布。
    func containsInteractivePoint(_ point: CGPoint) -> Bool {
        layoutInput.containsInteractivePoint(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard containsInteractivePoint(local) else { return nil }
        return self
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureFloatingShadow()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureFloatingShadow()
    }

    private func configureFloatingShadow() {
        wantsLayer = true
        layer?.masksToBounds = false
        let dropShadow = NSShadow()
        dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.36)
        dropShadow.shadowBlurRadius = 18
        dropShadow.shadowOffset = NSSize(width: 0, height: -6)
        self.shadow = dropShadow
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - 布局
    //
    // 布局本身在 `AnnotationToolbarLayout`（值类型，可独立断言）。
    // 这里只把本视图的状态摊平传进去并转发查询，使绘制、命中与诊断
    // 继续读同一份结果——三处分头计算就是「画在这里、点却点不到」的来源。

    typealias Kind = AnnotationToolbarLayout.Kind
    typealias Item = AnnotationToolbarLayout.Item

    // 布局常量转发：数值只有一份（在布局类型里），这里只是让本文件的
    // 绘制代码继续用短名字，避免同一数字在两处各写一遍。
    private var barHeight: CGFloat { AnnotationToolbarLayout.barHeight }
    private var panelHeight: CGFloat { AnnotationToolbarLayout.panelHeight }
    private var padding: CGFloat { AnnotationToolbarLayout.padding }
    private var itemSpacing: CGFloat { AnnotationToolbarLayout.itemSpacing }
    private var groupSpacing: CGFloat { AnnotationToolbarLayout.groupSpacing }
    private var separatorWidth: CGFloat { AnnotationToolbarLayout.separatorWidth }
    private var iconButtonSize: CGFloat { AnnotationToolbarLayout.iconButtonSize }
    private var swatchSize: CGFloat { AnnotationToolbarLayout.swatchSize }
    private var swatchSpacing: CGFloat { AnnotationToolbarLayout.swatchSpacing }
    private var textButtonMinWidth: CGFloat { AnnotationToolbarLayout.textButtonMinWidth }

    private var layoutInput: AnnotationToolbarLayout {
        var input = AnnotationToolbarLayout()
        input.tool = tool
        input.style = style
        input.canUndo = canUndo
        input.canRedo = canRedo
        input.isPanelExpanded = isPanelExpanded
        input.allowsCaptureActions = allowsCaptureActions
        input.hasSelectedAnnotation = hasSelectedAnnotation
        input.selectedAnnotationMatchesTool = selectedAnnotationMatchesTool
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

    /// 主栏尺寸。
    var barSize: CGSize { layoutInput.barSize }

    /// 当前分组的面板尺寸；该组没有设置项时为 `.zero`。
    var panelSize: CGSize { layoutInput.panelSize }

    /// 整个工具栏（主栏 + 面板）的尺寸。
    var toolbarSize: CGSize { layoutInput.toolbarSize }

    /// 某个可点击项的中心点（本视图坐标）；不存在或不可用时为 nil。
    func itemCenter(_ kind: Kind) -> CGPoint? { layoutInput.itemCenter(kind) }

    /// 当前所有可见项及其中心，便于诊断整体检查。
    ///
    /// 与绘制读同一份布局结果，因此这些坐标既是「画在哪」也是「点在哪」。
    func visibleItemCenters() -> [Kind: CGPoint] { layoutInput.visibleItemCenters() }

    /// 某个滑块条目的轨道横向范围（本视图坐标）；非滑块或不存在时为 nil。
    ///
    /// 供诊断合成真实的拖动事件。返回的几何来自渲染用的同一个
    /// `AnnotationToolbarLayout.sliderTrack`，所以它就是用户能拖的那一段。
    func sliderTrackForDiagnostics(_ kind: Kind) -> ClosedRange<CGFloat>? {
        guard isSlider(kind), let item = currentItem(kind) else { return nil }
        let track = AnnotationToolbarLayout.sliderTrack(in: item.rect)
        return track.minX ... track.maxX
    }

    // MARK: - 尺寸


    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // 绘制本身在 `AnnotationToolbarRenderer`：它只接收状态（工具、样式、
        // 悬停项与展开状态），不持有视图，因此可以脱离窗口渲染与比对。
        let renderer = AnnotationToolbarRenderer()
        renderer.tool = tool
        renderer.style = style
        renderer.showsToolSelection = showsToolSelection
        renderer.isPanelExpanded = isPanelExpanded
        renderer.canUndo = canUndo
        renderer.canRedo = canRedo
        renderer.allowsCaptureActions = allowsCaptureActions
        renderer.hasSelectedAnnotation = hasSelectedAnnotation
        renderer.selectedAnnotationMatchesTool = selectedAnnotationMatchesTool
        renderer.selectedAnnotationIsText = selectedAnnotationIsText
        renderer.selectedAnnotationIsHighlight = selectedAnnotationIsHighlight
        renderer.selectedAnnotationColor = selectedAnnotationColor
        renderer.activeFontSizeForToolbar = activeFontSizeForToolbar
        renderer.selectedAnnotationSupportsColor = selectedAnnotationSupportsColor
        renderer.selectedAnnotationSupportsLineWidth = selectedAnnotationSupportsLineWidth
        renderer.selectedAnnotationSupportsSketchy = selectedAnnotationSupportsSketchy
        renderer.selectedAnnotationIsSketchy = selectedAnnotationIsSketchy
        renderer.selectedAnnotationSupportsFill = selectedAnnotationSupportsFill
        renderer.selectedAnnotationIsFilled = selectedAnnotationIsFilled
        renderer.selectedAnnotationIsBold = selectedAnnotationIsBold
        renderer.selectedAnnotationIsItalic = selectedAnnotationIsItalic
        renderer.selectedAnnotationFontFamily = selectedAnnotationFontFamily
        renderer.selectedAnnotationIsSpotlight = selectedAnnotationIsSpotlight
        renderer.selectedAnnotationSpotlightDimOpacity = selectedAnnotationSpotlightDimOpacity
        renderer.selectedAnnotationSupportsMosaicEffect = selectedAnnotationSupportsMosaicEffect
        renderer.selectedAnnotationMosaicMode = selectedAnnotationMosaicMode
        renderer.selectedAnnotationMosaicBlockSize = selectedAnnotationMosaicBlockSize
        renderer.panelPlacement = panelPlacement
        renderer.hiddenSlots = hiddenSlots
        renderer.hoveredKind = hoveredKind
        renderer.pressedKind = pressedKind
        renderer.isDarkAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        renderer.draw(in: context)
    }

    // MARK: - 图标

    // MARK: - 命中测试

    override func mouseDown(with event: NSEvent) {
        hideTooltipImmediately()
        let point = convert(event.locationInWindow, from: nil)

        // 面板优先：它与主栏不重叠，顺序不影响正确性。
        if let item = hitTestItem(point, in: layoutPanel()) {
            if isSlider(item.kind), item.isEnabled {
                draggingSliderKind = item.kind
                onSliderGestureBegan?()
                updateSlider(item.kind, in: item.rect, at: point)
                return
            }
            if item.isEnabled {
                pressedKind = item.kind
                needsDisplay = true
            }
            handle(item, isInPanel: true, modifiers: event.modifierFlags)
            return
        }

        if let item = hitTestItem(point, in: layoutBar()) {
            if item.isEnabled {
                pressedKind = item.kind
                needsDisplay = true
            }
            handle(item, isInPanel: false, modifiers: event.modifierFlags)
            return
        }

        // 双击拖拽握把或空白背景：一键复位回选区默认停靠位置。
        if event.clickCount >= 2 {
            onResetPosition?()
            return
        }

        // 未命中任何条目：按住工具栏握把或空白背景可自由拖拽移动工具栏位置。
        isDraggingToolbar = true
        lastDragScreenPoint = NSEvent.mouseLocation
        NSCursor.closedHand.set()
    }

    override func rightMouseDown(with event: NSEvent) {
        hideTooltipImmediately()
        let point = convert(event.locationInWindow, from: nil)
        if let item = hitTestItem(point, in: layoutBar()), item.kind == .save, item.isEnabled {
            presentSaveFormatMenu(with: event)
            return
        }
        super.rightMouseDown(with: event)
    }

    private func presentSaveFormatMenu(with event: NSEvent) {
        let menu = NSMenu(title: "快速保存格式")
        for option in ExportFormatOption.allCases {
            let item = NSMenuItem(
                title: "保存为 \(option.displayName)",
                action: #selector(handleQuickFormatSaveMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let saveAs = NSMenuItem(
            title: "另存为…",
            action: #selector(handleQuickSaveAsMenuItem),
            keyEquivalent: ""
        )
        saveAs.target = self
        menu.addItem(saveAs)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func handleQuickFormatSaveMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = ExportFormatOption(rawValue: raw) else { return }
        if let onSaveAs {
            onSaveAs(option, false)
        } else {
            onSave?()
        }
    }

    @objc private func handleQuickSaveAsMenuItem() {
        if let onSaveAs {
            onSaveAs(nil, true)
        } else {
            onSave?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isDraggingToolbar {
            let current = NSEvent.mouseLocation
            // AppKit 屏幕坐标 y 向上，而覆盖层宿主视图 isFlipped = true（y 向下）。
            let delta = CGSize(
                width: current.x - lastDragScreenPoint.x,
                height: -(current.y - lastDragScreenPoint.y)
            )
            lastDragScreenPoint = current
            if delta.width != 0 || delta.height != 0 {
                onDragMove?(delta)
            }
            return
        }
        guard let kind = draggingSliderKind else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let item = currentItem(kind) else { return }
        updateSlider(kind, in: item.rect, at: point)
    }

    override func mouseUp(with event: NSEvent) {
        if pressedKind != nil {
            pressedKind = nil
            needsDisplay = true
        }
        if isDraggingToolbar {
            isDraggingToolbar = false
            updateCursor(at: convert(event.locationInWindow, from: nil))
            return
        }
        guard draggingSliderKind != nil else {
            super.mouseUp(with: event)
            return
        }
        draggingSliderKind = nil
        onSliderGestureEnded?()
    }

    /// 滑块悬停滚轮微调：无需精准拖手柄，滚轮轻拨即平滑调节线宽、箭头大小或笔刷直径。
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }

        if let item = hitTestItem(point, in: layoutPanel()), isSlider(item.kind), item.isEnabled {
            let direction: Double = delta > 0 ? 1 : -1
            beginWheelTransactionIfNeeded()
            switch item.kind {
            case .lineWidthSlider:
                let next = min(
                    max(style.shapeLineWidth + direction * 1.0, AnnotationStyle.lineWidthRange.lowerBound),
                    AnnotationStyle.lineWidthRange.upperBound
                )
                onSelectLineWidth?(next)
            case .arrowHeadScaleSlider:
                let next = min(
                    max(style.arrowHeadScale + direction * 0.1, AnnotationStyle.arrowHeadScaleRange.lowerBound),
                    AnnotationStyle.arrowHeadScaleRange.upperBound
                )
                onSelectArrowHeadScale?(next)
            case .mosaicBrushDiameterSlider:
                let current = style.mosaicBrushRadius * 2
                let next = min(
                    max(current + direction * 4.0, AnnotationStyle.mosaicBrushDiameterRange.lowerBound),
                    AnnotationStyle.mosaicBrushDiameterRange.upperBound
                )
                onSelectMosaicBrushDiameter?(next)
            default:
                break
            }
            scheduleWheelTransactionCommit()
            return
        }

        // 其余工具栏区域吸收滚轮事件，避免在工具栏上误滚影响下方画布参数。
        if containsInteractivePoint(point) {
            return
        }
        super.scrollWheel(with: event)
    }

    private func beginWheelTransactionIfNeeded() {
        if !isWheelTransactionActive {
            isWheelTransactionActive = true
            onSliderGestureBegan?()
        }
    }

    private func scheduleWheelTransactionCommit() {
        wheelCommitWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isWheelTransactionActive else { return }
            self.isWheelTransactionActive = false
            self.onSliderGestureEnded?()
        }
        wheelCommitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 是否是滑块类条目。
    private func isSlider(_ kind: Kind) -> Bool {
        switch kind {
        case .lineWidthSlider, .arrowHeadScaleSlider, .mosaicBrushDiameterSlider:
            return true
        default:
            return false
        }
    }

    /// 当前布局里某个条目的最新位置。
    private func currentItem(_ kind: Kind) -> Item? {
        if let item = layoutPanel().items.first(where: { $0.kind == kind }) {
            return item
        }
        return layoutBar().items.first(where: { $0.kind == kind })
    }

    /// 把拖动位置换算成滑块值并上报。
    ///
    /// 比例的计算走 `AnnotationToolbarLayout.sliderFraction`：
    /// 与渲染器画轨道用的是**同一个函数**，两边不会算出不同的映射。
    private func updateSlider(_ kind: Kind, in rect: CGRect, at point: CGPoint) {
        let fraction = AnnotationToolbarLayout.sliderFraction(of: point.x, in: rect)

        switch kind {
        case .lineWidthSlider:
            onSelectLineWidth?(resolvedValue(of: fraction, in: AnnotationStyle.lineWidthRange))
        case .arrowHeadScaleSlider:
            onSelectArrowHeadScale?(
                resolvedValue(of: fraction, in: AnnotationStyle.arrowHeadScaleRange)
            )
        case .mosaicBrushDiameterSlider:
            onSelectMosaicBrushDiameter?(
                resolvedValue(of: fraction, in: AnnotationStyle.mosaicBrushDiameterRange)
            )
        default:
            break
        }
    }

    /// 把 0...1 的比例映射回区间内的值。
    private func resolvedValue(
        of fraction: Double,
        in range: ClosedRange<Double>
    ) -> Double {
        range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCursor(at: point)
        let hit = hitTestAnyItem(at: point)
        let kind = hit?.kind
        guard kind != hoveredKind else { return }
        hoveredKind = kind
        if let hit, hit.isEnabled {
            scheduleTooltip(for: hit)
        } else {
            hideTooltipImmediately()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hideTooltipImmediately()
        guard hoveredKind != nil || pressedKind != nil else { return }
        hoveredKind = nil
        pressedKind = nil
        needsDisplay = true
    }

    private func updateCursor(at point: CGPoint) {
        guard !isDraggingToolbar else {
            NSCursor.closedHand.set()
            return
        }
        if let hit = hitTestAnyItem(at: point), hit.isEnabled {
            if isSlider(hit.kind) {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.pointingHand.set()
            }
        } else if containsInteractivePoint(point) {
            NSCursor.openHand.set()
        }
    }

    private func hitTestAnyItem(at point: CGPoint) -> Item? {
        if let item = hitTestItem(point, in: layoutPanel()) {
            return item
        }
        return hitTestItem(point, in: layoutBar())
    }

    private func scheduleTooltip(for item: Item) {
        tooltipDelayWorkItem?.cancel()
        let spec = Self.tooltipSpec(for: item.kind, mosaicEffectMode: activeMosaicEffectMode)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        let itemRect = item.rect

        let present = { [weak self] in
            guard let self, !self.isHidden, let window = self.window else { return }
            let rectInWindow = self.convert(itemRect, to: nil)
            let rectInScreen = window.convertToScreen(rectInWindow)
            let preferBelow = (self.panelPlacement == .above)
            self.tooltipHUD.show(
                title: spec.title,
                shortcut: spec.shortcut,
                near: rectInScreen,
                preferBelow: preferBelow,
                isDark: isDark
            )
        }

        // 若 Tooltip 已处于可见态，相邻按钮移动 0ms 瞬时切换；首次悬停延迟 220ms 优雅弹出。
        if tooltipHUD.isVisible {
            present()
            return
        }
        let work = DispatchWorkItem(block: present)
        tooltipDelayWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func hideTooltipImmediately() {
        tooltipDelayWorkItem?.cancel()
        tooltipDelayWorkItem = nil
        tooltipHUD.hide()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    private func itemKind(at point: CGPoint) -> Kind? {
        if let item = hitTestItem(point, in: layoutPanel()) {
            return item.kind
        }
        return hitTestItem(point, in: layoutBar())?.kind
    }

    private func hitTestItem(
        _ point: CGPoint,
        in layout: (items: [Item], size: CGSize)
    ) -> Item? {
        for item in layout.items where item.rect.contains(point) {
            return item
        }
        return nil
    }

    private func handle(_ item: Item, isInPanel: Bool, modifiers: NSEvent.ModifierFlags) {
        guard item.isEnabled else { return }

        switch item.kind {
        case let .family(family):
            if tool.family == family {
                isPanelExpanded.toggle()
                needsDisplay = true
                onIntrinsicSizeChanged?()
                return
            }
            isPanelExpanded = true
            onIntrinsicSizeChanged?()
            if let last = lastTool(in: family) {
                onSelectTool?(last)
            } else if let first = AnnotationTool.tools(in: family).first {
                onSelectTool?(first)
            }

        case .moreTools:
            // 当前已选中次高频工具时再点「更多」收起/展开；否则直接切入上次选用的次高频工具并展开气泡。
            if AnnotationToolbarLayout.isSecondaryTool(tool) {
                isPanelExpanded.toggle()
                needsDisplay = true
                onIntrinsicSizeChanged?()
                return
            }
            isPanelExpanded = true
            onSelectTool?(lastSecondaryTool)
            onIntrinsicSizeChanged?()

        case let .tool(candidate):
            if !isInPanel && tool == candidate {
                // 主栏点击当前已激活的工具：切换属性气泡显隐（指针无选中标注时无需展开）。
                if candidate != .pointer || hasSelectedAnnotation {
                    isPanelExpanded.toggle()
                    needsDisplay = true
                    onIntrinsicSizeChanged?()
                }
                return
            }
            if candidate != .pointer || hasSelectedAnnotation {
                isPanelExpanded = true
            }
            onSelectTool?(candidate)
            onIntrinsicSizeChanged?()

        case let .color(color):
            onSelectColor?(color)

        case .lineWidthSlider, .arrowHeadScaleSlider, .mosaicBrushDiameterSlider:
            break

        case let .numberingRadius(radius):
            onSelectNumberingRadius?(radius)

        case let .magnifierZoom(zoom):
            onSelectMagnifierZoom?(zoom)

        case let .curvedArrowBend(bend):
            onSelectCurvedArrowBend?(bend)

        case let .fontSize(size):
            onSelectFontSize?(size)

        case let .mosaicMode(mode):
            onSelectMosaicMode?(mode)

        case let .mosaicEffectMode(mode):
            onSelectMosaicEffectMode?(mode)

        case .sketchyToggle:
            onToggleSketchy?()

        case .fillToggle:
            onToggleFill?()

        case .textBoldToggle:
            onToggleTextBold?()

        case .textItalicToggle:
            onToggleTextItalic?()

        case .textFontFamily:
            onCycleTextFontFamily?()

        case let .spotlightDimOpacity(opacity):
            onSelectSpotlightDimOpacity?(opacity)

        case let .mosaicBlockSize(size):
            onSelectMosaicBlockSize?(size)

        case .colorPicker:
            onOpenColorPanel?()

        case .colorButton:
            guard style.color(for: tool) != nil else { return }
            onOpenColorPanel?()

        case .undo:
            onUndo?()

        case .redo:
            onRedo?()

        case .record:
            onRecord?()

        case .longScreenshot:
            onLongScreenshot?()

        case .recognizeText:
            onRecognizeText?()

        case .pin:
            onPin?()

        case .copy:
            onCopy?()

        case .save:
            if modifiers.contains(.option), let onSaveAs {
                onSaveAs(nil, true)
            } else {
                onSave?()
            }

        case .cancel:
            onCancel?()

        case .deleteSelected:
            onDeleteSelected?()
        }
    }

    /// 分组记住的具体工具。
    ///
    /// 形状组读取 `lastToolByFamily`：切走再切回时恢复上次画的那个形状。
    /// 文字与马赛克各自只有一个工具，保持常量返回即可
    /// （对它们查记忆表会得到同一结果，反而多一层不必要的间接）。
    private func lastTool(in family: AnnotationTool.Family) -> AnnotationTool? {
        switch family {
        case .pointer: return .pointer
        case .shape: return lastToolByFamily[family]
        case .text: return .text
        case .mosaic: return lastToolByFamily[family] ?? .mosaic
        }
    }

    // MARK: - 悬浮提示与无障碍支持

    /// 工具栏条目对应的 Tooltip 与无障碍标签文案。
    nonisolated static func tooltipText(for kind: Kind, mosaicEffectMode: MosaicMode = .pixelate) -> String {
        switch kind {
        case let .family(family):
            switch family {
            case .pointer: return "指针 (V)"
            case .shape: return "形状标注"
            case .text: return "文字 (T)"
            case .mosaic: return "马赛克与放大镜 (M)"
            }
        case let .tool(tool):
            return "\(tool.displayName) (\(String(tool.keyCharacter).uppercased()))"
        case .moreTools:
            return "更多工具：直线 / 曲线箭头 / 测量 / 放大镜"
        case let .color(color):
            return "颜色 \(color.hexString)"
        case .lineWidthSlider:
            return "线宽（支持滚轮微调）"
        case .arrowHeadScaleSlider:
            return "箭头大小（支持滚轮微调）"
        case let .fontSize(size):
            return "字号 \(Int(size))pt"
        case let .mosaicMode(mode):
            return "马赛克模式：\(mode.displayName)"
        case let .mosaicEffectMode(mode):
            return "打码效果：\(AnnotationToolbarLayout.mosaicEffectLabel(mode))"
        case .sketchyToggle:
            return "手绘风格"
        case .fillToggle:
            return "形状填充"
        case .textBoldToggle:
            return "粗体"
        case .textItalicToggle:
            return "斜体"
        case .textFontFamily:
            return "切换字体"
        case let .spotlightDimOpacity(opacity):
            return "聚光灯压暗度 \(AnnotationToolbarLayout.spotlightOpacityLabel(opacity))"
        case let .mosaicBlockSize(size):
            let index = AnnotationStyle.mosaicBlockSizes.firstIndex(of: size) ?? 0
            if mosaicEffectMode == .blur {
                let labels = ["标准", "强", "极强"]
                return "模糊程度：\(labels[min(index, labels.count - 1)])"
            }
            let labels = ["细", "中", "粗"]
            return "马赛克粒度：\(labels[min(index, labels.count - 1)])"
        case .mosaicBrushDiameterSlider:
            return "涂抹笔刷直径（支持滚轮微调）"
        case let .numberingRadius(radius):
            return "编号半径 \(Int(radius))"
        case let .magnifierZoom(zoom):
            return "放大倍率 \(AnnotationToolbarLayout.formatZoomLabel(zoom))"
        case let .curvedArrowBend(bend):
            return "曲线弯曲度 \(Int((bend * 100).rounded()))%"
        case .colorButton:
            return "当前颜色"
        case .colorPicker:
            return "自定义取色器"
        case .undo:
            return "撤销 (⌘Z)"
        case .redo:
            return "重做 (⇧⌘Z)"
        case .copy:
            return "复制截图 (⌘C / Enter)"
        case .save:
            return "保存截图 (⌘S · ⌥另存为 · 右键选格式)"
        case .cancel:
            return "取消截图 (Esc)"
        case .record:
            return "录制选区"
        case .longScreenshot:
            return "滚动长截图（⌥点击横向）"
        case .recognizeText:
            return "识别文字 (OCR)"
        case .pin:
            return "钉在屏幕上 (⌘P)"
        case .deleteSelected:
            return "删除选中标注 (Delete)"
        }
    }

    /// 拆分主标题与快捷键键帽徽章，供自绘无遮挡毛玻璃 Tooltip 渲染。
    nonisolated static func tooltipSpec(
        for kind: Kind,
        mosaicEffectMode: MosaicMode = .pixelate
    ) -> (title: String, shortcut: String?) {
        switch kind {
        case let .tool(tool):
            return (tool.displayName, String(tool.keyCharacter).uppercased())
        case .moreTools:
            return ("更多工具", "L / U / E / G")
        case .undo:
            return ("撤销", "⌘Z")
        case .redo:
            return ("重做", "⇧⌘Z")
        case .copy:
            return ("复制截图", "⌘C / ↵")
        case .save:
            return ("保存 · 右键选格式", "⌘S / ⌥")
        case .cancel:
            return ("取消截图", "Esc")
        case .longScreenshot:
            return ("滚动长截图", "⌥横向")
        case .pin:
            return ("钉在屏幕上", "⌘P")
        case .deleteSelected:
            return ("删除标注", "⌫")
        case .lineWidthSlider:
            return ("线宽", "滚轮")
        case .arrowHeadScaleSlider:
            return ("箭头大小", "滚轮")
        case .mosaicBrushDiameterSlider:
            return ("笔刷直径", "滚轮")
        default:
            return (tooltipText(for: kind, mosaicEffectMode: mosaicEffectMode), nil)
        }
    }

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .toolbar }

    override func accessibilityLabel() -> String? { "标注工具栏" }

    private var activeMosaicEffectMode: MosaicMode {
        (hasSelectedAnnotation && selectedAnnotationSupportsMosaicEffect)
            ? (selectedAnnotationMosaicMode ?? style.mosaicEffectMode)
            : style.mosaicEffectMode
    }

    override func accessibilityChildren() -> [Any]? {
        let items = layoutBar().items + layoutPanel().items
        let effectMode = activeMosaicEffectMode
        return items.map { item in
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(accessibilityRole(for: item.kind))
            element.setAccessibilityLabel(Self.tooltipText(for: item.kind, mosaicEffectMode: effectMode))
            element.setAccessibilityEnabled(item.isEnabled)
            if let window {
                let rectInWindow = convert(item.rect, to: nil)
                element.setAccessibilityFrame(window.convertToScreen(rectInWindow))
            } else {
                element.setAccessibilityFrame(item.rect)
            }
            return element
        }
    }

    private func accessibilityRole(for kind: Kind) -> NSAccessibility.Role {
        switch kind {
        case .lineWidthSlider, .arrowHeadScaleSlider, .mosaicBrushDiameterSlider:
            return .slider
        case .color, .colorButton, .colorPicker:
            return .colorWell
        default:
            return .button
        }
    }

    // MARK: - 布局


}

// MARK: - 自绘瞬时无遮挡毛玻璃 Tooltip

/// 独立于系统原生 Tooltip 的轻量无焦点提示胶囊（置于 `screenSaver + 3` 层级，永不被覆盖层遮挡，支持快捷键键帽）。
@MainActor
private final class ToolbarTooltipHUD {
    private let panel: NSPanel
    private let contentView: ToolbarTooltipContentView

    var isVisible: Bool { panel.isVisible }

    init() {
        let view = ToolbarTooltipContentView(frame: .zero)
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: 26),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        self.panel = panel
        self.contentView = view
    }

    func show(
        title: String,
        shortcut: String?,
        near anchorScreenRect: CGRect,
        preferBelow: Bool,
        isDark: Bool
    ) {
        let size = contentView.configure(title: title, shortcut: shortcut, isDark: isDark)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorScreenRect) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 7

        let x = min(
            max(bounds.minX + 8, anchorScreenRect.midX - size.width / 2),
            bounds.maxX - size.width - 8
        )
        let aboveY = anchorScreenRect.maxY + gap
        let belowY = anchorScreenRect.minY - size.height - gap
        let y: CGFloat
        if preferBelow {
            y = (belowY >= bounds.minY + 6) ? belowY : min(aboveY, bounds.maxY - size.height - 6)
        } else {
            y = (aboveY + size.height <= bounds.maxY - 6) ? aboveY : max(belowY, bounds.minY + 6)
        }

        panel.setFrame(CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size), display: true)
        contentView.frame = CGRect(origin: .zero, size: size)
        contentView.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

private final class ToolbarTooltipContentView: NSView {
    private var titleText: String = ""
    private var shortcutText: String?
    private var isDark: Bool = true

    override var isFlipped: Bool { true }

    func configure(title: String, shortcut: String?, isDark: Bool) -> CGSize {
        self.titleText = title
        self.shortcutText = shortcut
        self.isDark = isDark

        let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let titleW = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width) + 1
        var totalW = 10 + titleW + 10
        if let shortcut, !shortcut.isEmpty {
            let keyFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
            let keyW = ceil((shortcut as NSString).size(withAttributes: [.font: keyFont]).width)
            totalW += 6 + keyW + 10
        }
        return CGSize(width: totalW, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil)

        let bg = isDark
            ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 0.96)
            : NSColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 0.97)
        let border = isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.12)
        let textColor = isDark
            ? NSColor.white.withAlphaComponent(0.95)
            : NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 0.94)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(bg.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(border.cgColor)
        ctx.setLineWidth(0.8)
        ctx.strokePath()
        ctx.restoreGState()

        let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: textColor]
        let titleSize = (titleText as NSString).size(withAttributes: titleAttrs)
        (titleText as NSString).draw(
            at: NSPoint(x: 10, y: (bounds.height - titleSize.height) / 2),
            withAttributes: titleAttrs
        )

        if let shortcut = shortcutText, !shortcut.isEmpty {
            let keyFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
            let keyColor = isDark
                ? NSColor.white.withAlphaComponent(0.78)
                : NSColor(srgbRed: 0.25, green: 0.28, blue: 0.34, alpha: 0.88)
            let keyAttrs: [NSAttributedString.Key: Any] = [.font: keyFont, .foregroundColor: keyColor]
            let keySize = (shortcut as NSString).size(withAttributes: keyAttrs)
            let pillRect = CGRect(
                x: 10 + ceil(titleSize.width) + 6,
                y: (bounds.height - 17) / 2,
                width: ceil(keySize.width) + 10,
                height: 17
            )
            let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
            let pillBg = isDark
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.065)
            ctx.saveGState()
            ctx.addPath(pillPath)
            ctx.setFillColor(pillBg.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            (shortcut as NSString).draw(
                at: NSPoint(
                    x: pillRect.minX + 5,
                    y: pillRect.midY - keySize.height / 2
                ),
                withAttributes: keyAttrs
            )
        }
    }
}
