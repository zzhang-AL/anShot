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

    @Test("分组按钮中心由布局常量独立算出：左内边距 + 序号 × (按钮 + 间距) + 按钮一半")
    func familyButtonsSitAtConstantPositions() {
        // 主栏分组按钮的固定顺序是布局的对外契约（`AnnotationToolbarLayoutTests`
        // 也锁了它），因此这里用一份**独立写出**的顺序与算出来的期望位置，
        // 而不是从被测的布局结果里反推。
        let familyOrder: [AnnotationTool.Family] = [.pointer, .shape, .text, .mosaic]
        let centers = Self.makeToolbar(tool: .rectangle).visibleItemCenters()

        for (index, family) in familyOrder.enumerated() {
            guard let center = centers[.family(family)] else {
                Issue.record("主栏缺少分组按钮 .family(\(family))")
                continue
            }
            let expectedX =
                AnnotationToolbarLayout.padding
                + CGFloat(index) * (AnnotationToolbarLayout.iconButtonSize + AnnotationToolbarLayout.itemSpacing)
                + AnnotationToolbarLayout.iconButtonSize / 2
            #expect(abs(center.x - expectedX) < 0.5, "\(family) 的横向位置与布局常量不符")
            #expect(abs(center.y - AnnotationToolbarLayout.barHeight / 2) < 0.5)
        }
        // 首个分组按钮正是 `-diagnoseSelection` 里以 (22, 18) 硬编码断言的那个位置。
        #expect(
            centers[.family(.pointer)]?.x == AnnotationToolbarLayout.padding
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
            + AnnotationToolbarLayout.itemSpacing
            + AnnotationToolbarLayout.panelHeight / 2
        for (kind, center) in panelCenters {
            #expect(abs(center.y - expectedY) < 0.5, "\(kind) 不在面板的纵向中心线上")
        }
        #expect(panelCenters.values.map(\.y).min() ?? 0 > barMaxY)
    }

    @Test("工具栏高度 = 栏高（无面板时）或 栏高 + 间距 + 面板高")
    func toolbarSizeCombinesBarAndPanel() {
        let noPanel = Self.makeToolbar(tool: .pointer)
        #expect(noPanel.toolbarSize.height == AnnotationToolbarLayout.barHeight)

        let withPanel = Self.makeToolbar(tool: .rectangle)
        #expect(
            withPanel.toolbarSize.height == AnnotationToolbarLayout.barHeight
                + AnnotationToolbarLayout.itemSpacing
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

    @Test("颜色入口只对有颜色的工具出现（马赛克没有颜色槽）")
    func colorEntryFollowsToolCapability() {
        let rectangle = Set(Self.makeToolbar(tool: .rectangle).visibleItemCenters().keys)
        let mosaic = Set(Self.makeToolbar(tool: .mosaic).visibleItemCenters().keys)
        #expect(rectangle.contains(.colorButton))
        #expect(!mosaic.contains(.colorButton))
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
