//
//  AnnotationToolbarViewLayoutTests.swift
//  AnShotUITests
//
//  离线工具栏视图：它报告的条目位置必须就是布局函数的输出。
//
//  ── 为什么需要这一层（布局纯函数已有测试）────────────────────
//
//  `AnnotationToolbarLayoutTests` 锁定的是布局函数**自己**的几何。
//  但「视图有没有真的用它」是另一件事：视图完全可以在别处另算一套坐标，
//  两边各自自洽、互相错位——那正是 P4 出过的「画在这里、却要点那边」。
//
//  这里用**不挂到窗口**的工具栏视图（与 `-diagnoseSelection` /
//  `-diagnoseM3Annotation` 的「离线工具栏」同一手法）断言：
//  视图报告的每个条目中心都等于布局结果矩形的中心，且首个条目落在
//  由布局常量独立算出的位置上。全过程不需要窗口、底图与屏幕录制权限——
//  旧诊断之所以要造窗口，只是为了给合成事件提供坐标转换上下文。
//

import AnShotCore
import AppKit
import CoreGraphics
import Testing

@testable import AnShotUI

/// 全部工具。刻意不用 `CaseIterable`：新增工具时这里必须显式加一行，
/// 从而被迫跑一遍本测试，而不是「新工具自动跳过检查」。
///
/// 定义在类型之外：`@MainActor` 的 suite 会让 `static let` 也变成主线程隔离，
/// 而参数化测试的参数表是在非隔离上下文求值的。
private let toolbarAllTools: [AnnotationTool] = [
    .pointer, .rectangle, .line, .arrow, .text, .mosaic,
    .numbering, .highlight, .measure, .magnifier, .freehand, .curvedArrow,
]

@MainActor
@Suite("离线工具栏 · 视图与布局同源")
struct AnnotationToolbarViewLayoutTests {

    private typealias Kind = AnnotationToolbarLayout.Kind

    private static func makeToolbar(tool: AnnotationTool) -> AnnotationToolbarView {
        let view = AnnotationToolbarView()
        view.tool = tool
        view.style = .default
        return view
    }

    /// 由布局纯函数独立构造的期望中心（与视图无关）。
    private static func expectedCenters(tool: AnnotationTool) -> [Kind: CGPoint] {
        var input = AnnotationToolbarLayout()
        input.tool = tool
        input.style = .default
        input.canUndo = false
        input.canRedo = false
        input.isPanelExpanded = true

        var result: [Kind: CGPoint] = [:]
        for item in input.layoutBar().items + input.layoutPanel().items {
            result[item.kind] = CGPoint(x: item.rect.midX, y: item.rect.midY)
        }
        return result
    }

    // MARK: - 同源不变量

    @Test("每个工具下，视图报告的条目集合与布局结果完全一致", arguments: toolbarAllTools)
    func visibleItemsMatchLayoutOutput(tool: AnnotationTool) {
        let actual = Self.makeToolbar(tool: tool).visibleItemCenters()
        let expected = Self.expectedCenters(tool: tool)
        #expect(Set(actual.keys) == Set(expected.keys))
    }

    @Test("每个工具下，视图报告的条目中心等于布局矩形中心", arguments: toolbarAllTools)
    func itemCentersComeFromLayoutRects(tool: AnnotationTool) {
        let actual = Self.makeToolbar(tool: tool).visibleItemCenters()
        let expected = Self.expectedCenters(tool: tool)
        for (kind, center) in expected {
            #expect(actual[kind] == center, "\(kind) 的中心与布局矩形不一致")
        }
    }

    @Test(
        "itemCenter 与 visibleItemCenters 给出同一坐标（两条查询路径不许分家）",
        arguments: toolbarAllTools)
    func itemCenterAgreesWithVisibleCenters(tool: AnnotationTool) {
        let view = Self.makeToolbar(tool: tool)
        let centers = view.visibleItemCenters()
        for (kind, center) in centers {
            #expect(view.itemCenter(kind) == center, "\(kind) 的两条查询路径不一致")
        }
    }

    // MARK: - 独立预期（取自布局常量，不用被测函数的输出反推）

    @Test("主栏高频直达按钮中心由布局常量独立算出：firstBarItemX + 序号 × (按钮 + 间距) + 按钮一半")
    func primaryToolButtonsSitAtConstantPositions() {
        let primaryOrder = AnnotationToolbarLayout.primaryTools
        let centers = Self.makeToolbar(tool: .rectangle).visibleItemCenters()

        for (index, tool) in primaryOrder.enumerated() {
            guard let center = centers[.tool(tool)] else {
                Issue.record("主栏缺少高频直达按钮 .tool(\(tool))")
                continue
            }
            let expectedX =
                AnnotationToolbarLayout.firstBarItemX
                + CGFloat(index) * (AnnotationToolbarLayout.iconButtonSize + AnnotationToolbarLayout.itemSpacing)
                + AnnotationToolbarLayout.iconButtonSize / 2
            #expect(abs(center.x - expectedX) < 0.5, "\(tool) 的横向位置与布局常量不符")
            #expect(abs(center.y - AnnotationToolbarLayout.barHeight / 2) < 0.5)
        }
        #expect(
            centers[.tool(.pointer)]?.x == AnnotationToolbarLayout.firstBarItemX
                + AnnotationToolbarLayout.iconButtonSize / 2)
    }

    @Test("面板条目的纵向中心 = 栏高 + 条目间距 + 面板高的一半", arguments: toolbarAllTools)
    func panelItemsSitBelowBar(tool: AnnotationTool) {
        let view = Self.makeToolbar(tool: tool)
        let centers = view.visibleItemCenters()
        let barKinds = Self.expectedCenters(tool: tool).filter { kind, center in
            center.y < AnnotationToolbarLayout.barHeight
        }
        let barMaxY = barKinds.values.map(\.y).max() ?? 0
        let panelCenters = centers.filter { $0.value.y > barMaxY }

        // 面板展开时（指针工具没有面板）必须整体位于主栏之下，不许重叠。
        let input = Self.layoutInput(tool: tool)
        if input.layoutPanel().items.isEmpty {
            #expect(panelCenters.isEmpty)
            return
        }
        let expectedY =
            AnnotationToolbarLayout.barHeight
            + AnnotationToolbarLayout.panelGap
            + AnnotationToolbarLayout.panelHeight / 2
        for (kind, center) in panelCenters {
            #expect(abs(center.y - expectedY) < 0.5, "\(kind) 不在面板的纵向中心线上")
        }
        #expect(panelCenters.values.map(\.y).min() ?? 0 > barMaxY)
    }

    @Test("工具栏高度 = 栏高（无面板时）或 栏高 + 气泡间距 + 面板高")
    func toolbarSizeCombinesBarAndPanel() {
        let noPanel = Self.makeToolbar(tool: .pointer)
        #expect(noPanel.toolbarSize.height == AnnotationToolbarLayout.barHeight)

        let withPanel = Self.makeToolbar(tool: .rectangle)
        #expect(
            withPanel.toolbarSize.height == AnnotationToolbarLayout.barHeight
                + AnnotationToolbarLayout.panelGap
                + AnnotationToolbarLayout.panelHeight)
        // 面板比主栏宽时取面板宽，否则取主栏宽。
        #expect(
            withPanel.toolbarSize.width
                == max(
                    withPanel.barSize.width,
                    withPanel.panelSize.width
                ))
    }

    // MARK: - 面板内容随工具切换

    @Test("编号工具的面板有半径档位、没有放大镜倍率")
    func numberingPanelHasRadiusOnly() {
        let kinds = Set(Self.makeToolbar(tool: .numbering).visibleItemCenters().keys)
        #expect(kinds.contains { if case .numberingRadius = $0 { return true } else { return false } })
        #expect(!kinds.contains { if case .magnifierZoom = $0 { return true } else { return false } })
    }

    @Test("放大镜工具的面板有倍率档位、没有编号半径")
    func magnifierPanelHasZoomOnly() {
        let kinds = Set(Self.makeToolbar(tool: .magnifier).visibleItemCenters().keys)
        #expect(kinds.contains { if case .magnifierZoom = $0 { return true } else { return false } })
        #expect(!kinds.contains { if case .numberingRadius = $0 { return true } else { return false } })
    }

    @Test("箭头与曲线箭头有箭头大小滑块，矩形没有")
    func arrowHeadSliderBelongsToArrowTools() {
        let arrow = Set(Self.makeToolbar(tool: .arrow).visibleItemCenters().keys)
        let curved = Set(Self.makeToolbar(tool: .curvedArrow).visibleItemCenters().keys)
        let rectangle = Set(Self.makeToolbar(tool: .rectangle).visibleItemCenters().keys)
        #expect(arrow.contains(.arrowHeadScaleSlider))
        #expect(curved.contains(.arrowHeadScaleSlider))
        #expect(!rectangle.contains(.arrowHeadScaleSlider))
    }

    @Test("颜色入口只对有颜色的工具出现（马赛克没有颜色槽，统一收敛在属性气泡的色轮入口）")
    func colorEntryFollowsToolCapability() {
        let rectangle = Set(Self.makeToolbar(tool: .rectangle).visibleItemCenters().keys)
        let mosaic = Set(Self.makeToolbar(tool: .mosaic).visibleItemCenters().keys)
        #expect(rectangle.contains(.colorPicker))
        #expect(!mosaic.contains(.colorPicker))
    }

    @Test("滑块轨道落在它的条目矩形内，且是用户真正能拖的那一段")
    func sliderTrackLiesInsideItsItem() {
        let view = Self.makeToolbar(tool: .rectangle)
        guard
            let item = Self.layoutInput(tool: .rectangle).layoutPanel().items
                .first(where: { $0.kind == .lineWidthSlider }),
            let track = view.sliderTrackForDiagnostics(.lineWidthSlider)
        else {
            Issue.record("矩形工具的面板里没有线宽滑块")
            return
        }
        #expect(track.lowerBound >= item.rect.minX)
        #expect(track.upperBound <= item.rect.maxX)
        #expect(track.lowerBound < track.upperBound)
    }

    @Test("工具栏渲染器对编号半径、放大镜倍率、曲线弯曲度给出选中高亮")
    func rendererHighlightsEnhancementOptions() {
        let renderer = AnnotationToolbarRenderer()
        renderer.style = .default

        renderer.tool = .numbering
        #expect(renderer.isSelected(.numberingRadius(AnnotationStyle.default.numberingRadius)))

        renderer.tool = .magnifier
        #expect(renderer.isSelected(.magnifierZoom(AnnotationStyle.default.magnifierZoom)))

        renderer.tool = .curvedArrow
        #expect(renderer.isSelected(.curvedArrowBend(AnnotationStyle.default.curvedArrowBend)))
    }

    @Test("折叠/展开二级面板触发尺寸变更回调，且提供完整 Tooltip 与 VoiceOver 子元素")
    func panelCollapseNotifiesAndAccessibilityExposesItems() throws {
        let view = Self.makeToolbar(tool: .rectangle)
        var sizeChanges = 0
        view.onIntrinsicSizeChanged = { sizeChanges += 1 }

        // 点击主栏当前已激活的工具按钮（矩形）触发收起
        let rectCenter = try #require(view.itemCenter(.tool(.rectangle)))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: view.toolbarSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(rectCenter, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseDown(with: event)
        #expect(sizeChanges == 1, "折叠二级面板必须通知更新 frame")
        #expect(view.toolbarSize.height == AnnotationToolbarLayout.barHeight)

        // 校验无障碍元素数量与文案
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(children.count == view.visibleItemCenters().count)
        #expect(children.allSatisfy { ($0.accessibilityLabel()?.isEmpty == false) })
        #expect(AnnotationToolbarView.tooltipText(for: .longScreenshot).contains("⌥点击横向"))
        #expect(AnnotationToolbarView.tooltipText(for: .pin).contains("⌘P"))
    }

    @Test("透明空气区精准穿透回画布，不拦截主栏与精巧属性气泡之外的点击")
    func transparentAirspacePassesThroughToCanvas() {
        let view = Self.makeToolbar(tool: .spotlight)
        let barRect = Self.layoutInput(tool: .spotlight).barFrame
        let panelRect = Self.layoutInput(tool: .spotlight).panelFrame
        // 聚光灯属性气泡很窄（仅 3 个压暗度按钮），位于主栏中段下方，其左侧和右侧大片区域均为透明空气。
        #expect(panelRect.width < barRect.width * 0.5)
        #expect(view.containsInteractivePoint(CGPoint(x: barRect.midX, y: barRect.midY)))
        #expect(view.containsInteractivePoint(CGPoint(x: panelRect.midX, y: panelRect.midY)))

        // 气泡左侧空气区与右侧空气区必须返回 false（穿透回画布）
        let leftAir = CGPoint(x: 4, y: panelRect.midY)
        let rightAir = CGPoint(x: barRect.maxX - 4, y: panelRect.midY)
        if leftAir.x < panelRect.minX {
            #expect(!view.containsInteractivePoint(leftAir), "气泡左侧透明空气区不应吞掉画布点击")
        }
        if rightAir.x > panelRect.maxX {
            #expect(!view.containsInteractivePoint(rightAir), "气泡右侧透明空气区不应吞掉画布点击")
        }
    }

    @Test("落笔绘制自动轻收起二级气泡，切工具或选中标注后按需展开，且支持 ⌥+点击保存直达另存为")
    func drawAutoCollapseAndOptionSaveAsInteraction() throws {
        let view = Self.makeToolbar(tool: .rectangle)
        var sizeChanges = 0
        view.onIntrinsicSizeChanged = { sizeChanges += 1 }
        #expect(view.isPanelExpanded)

        // 落笔绘制：自动收起气泡释放画布视野
        view.collapsePanelForDrawing()
        #expect(!view.isPanelExpanded)
        #expect(view.toolbarSize.height == AnnotationToolbarLayout.barHeight)
        #expect(sizeChanges == 1)

        // 重复调用保持幂等
        view.collapsePanelForDrawing()
        #expect(sizeChanges == 1)

        // 选中标注或切工具：重新展开属性气泡
        view.expandPanelForInteraction()
        #expect(view.isPanelExpanded)
        #expect(view.toolbarSize.height > AnnotationToolbarLayout.barHeight)

        // ⌥+点击保存按钮触发强制另存为
        var receivedSaveAs: (ExportFormatOption?, Bool)?
        view.onSaveAs = { format, forceAsk in
            receivedSaveAs = (format, forceAsk)
        }
        let saveCenter = try #require(view.itemCenter(.save))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: view.toolbarSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let optClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(saveCenter, to: nil),
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseDown(with: optClick)
        #expect(receivedSaveAs?.1 == true, "⌥+点击保存应直接请求弹出另存为面板")
    }

    /// 构造与视图等价的布局输入（两者的状态在这里显式对齐）。
    private static func layoutInput(tool: AnnotationTool) -> AnnotationToolbarLayout {
        var input = AnnotationToolbarLayout()
        input.tool = tool
        input.style = .default
        input.canUndo = false
        input.canRedo = false
        input.isPanelExpanded = true
        return input
    }
}
