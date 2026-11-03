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
            // 记住每个分组**上次用过的具体工具**。不能只靠当前 `tool` 反推：
            // 切到文字/马赛克后 `tool.family` 已不是 `.shape`，
            // 形状组上次用矩形还是箭头就再也想不起来了。
            lastToolByFamily[tool.family] = tool
            needsDisplay = true
        }
    }

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

    /// 选中的标注是否是文字（面板换用字号档位而不是线宽滑块）。
    var selectedAnnotationIsText = false {
        didSet {
            guard selectedAnnotationIsText != oldValue else { return }
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

    // MARK: - 回调

    var onSelectTool: ((AnnotationTool) -> Void)?
    var onSelectColor: ((RGBAColor) -> Void)?
    var onSelectLineWidth: ((Double) -> Void)?
    var onSelectFontSize: ((Double) -> Void)?
    /// 删除当前选中的标注（指针 + 选中时面板里的删除按钮）。
    var onDeleteSelected: (() -> Void)?
    var onSelectMosaicMode: ((MosaicToolMode) -> Void)?
    var onSelectMosaicBlockSize: ((Double) -> Void)?
    var onSelectMosaicBrushDiameter: ((Double) -> Void)?
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

    /// 打开系统取色器。
    ///
    /// 颜色是高频操作，所以给一级入口而不是藏在各工具的分组面板里；
    /// 系统取色器自带色轮、色卡、滑块数值输入与放大镜取色，
    /// 正是「预设色卡 + 拖动色图 + 手动输入」这三种取色方式。
    var onOpenColorPanel: (() -> Void)?

    // MARK: - 布局常量


    // MARK: - 命中项

    /// 可点击项的身份。
    ///
    /// 不是 `private`：诊断需要按语义拿到项的真实坐标来合成点击。
    /// 直接调编辑器方法证明不了「按钮画在哪里、点击落在哪里」，
    /// 而那正是 P4 出过问题的地方。


    /// 面板是否展开。点当前分组会收起，再点展开。
    private var isPanelExpanded = true

    private var hoveredKind: Kind?

    /// 正在拖动的滑块。
    ///
    /// 为什么需要这个状态：滑块一旦按下，后续的拖动**不再重新命中**。
    /// 面板只有 26pt 高，拖动时指针纵向抖出滑块条是必然的，
    /// 若每次拖动都重新命中，手一抖滑块就「脱手」，表现为拖到一半就不动了。
    private var draggingSliderKind: Kind?

    override var isFlipped: Bool { true }

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
        renderer.selectedAnnotationIsText = selectedAnnotationIsText
        renderer.selectedAnnotationSupportsColor = selectedAnnotationSupportsColor
        renderer.selectedAnnotationSupportsLineWidth = selectedAnnotationSupportsLineWidth
        renderer.hoveredKind = hoveredKind
        renderer.draw(in: context)
    }

    // MARK: - 图标

    // MARK: - 命中测试

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 面板优先：它绘制在主栏之下，两者不重叠，顺序不影响正确性。
        if let item = hitTestItem(point, in: layoutPanel()) {
            // 滑块按下即取值，并进入拖动态（后续交给 `mouseDragged`）。
            // 不进入拖动态的话，用户必须精确点中那 3pt 高的轨道才能改值，
            // 而看到的是一个半径 5pt 的手柄——点中手柄反而没反应。
            if isSlider(item.kind), item.isEnabled {
                draggingSliderKind = item.kind
                updateSlider(item.kind, in: item.rect, at: point)
                return
            }
            handle(item)
            return
        }

        if let item = hitTestItem(point, in: layoutBar()) {
            handle(item)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let kind = draggingSliderKind else {
            super.mouseDragged(with: event)
            return
        }
        // 用**当前布局**里的矩形（不是按下时缓存的那一份）：
        // 拖动期间线宽在变，而线宽会影响面板宽度，条目位置可能跟着移。
        let point = convert(event.locationInWindow, from: nil)
        guard let item = currentItem(kind) else { return }
        updateSlider(kind, in: item.rect, at: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard draggingSliderKind != nil else {
            super.mouseUp(with: event)
            return
        }
        draggingSliderKind = nil
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
        let kind = itemKind(at: point)
        guard kind != hoveredKind else { return }
        hoveredKind = kind
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredKind != nil else { return }
        hoveredKind = nil
        needsDisplay = true
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

    private func handle(_ item: Item) {
        guard item.isEnabled else { return }

        switch item.kind {
        case let .family(family):
            // 点当前分组 = 收起/展开面板；点别的分组 = 切过去并展开。
            if tool.family == family {
                isPanelExpanded.toggle()
                needsDisplay = true
                return
            }
            isPanelExpanded = true
            // 分组记住上一次用的具体工具，不必每次重新挑。
            if let last = lastTool(in: family) {
                onSelectTool?(last)
            } else if let first = AnnotationTool.tools(in: family).first {
                onSelectTool?(first)
            }

        case let .tool(candidate):
            onSelectTool?(candidate)

        case let .color(color):
            onSelectColor?(color)

        case .lineWidthSlider, .arrowHeadScaleSlider, .mosaicBrushDiameterSlider:
            // 滑块的取值走 `mouseDown` / `mouseDragged`，不经 `handle`。
            // 保留分支是为了让 switch 穷尽：新增条目时编译器会要求在这里表态。
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
            onSave?()

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
        case .mosaic: return .mosaic
        }
    }

    // MARK: - 布局


}
