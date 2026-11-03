//
//  AnnotationToolbarLayoutTests.swift
//  AnShotUITests
//
//  工具栏布局的单元测试。
//
//  ── 为什么这些测试必须存在 ────────────────────────────────────
//
//  `AnnotationToolbarLayout` 是**纯函数**：输入（当前工具、样式、撤销可用性）
//  → 输出（每个条目的矩形 + 整条工具栏的尺寸）。没有 AppKit 状态、没有时序，
//  是完全可单测的——但此前 `AnShotUI` 没有测试 target，它只能靠
//  `-diagnoseAnnotation` 的截图比对来验证。
//
//  布局算错的表现是「某个图标位置偏几像素」或「点击区与绘制区错位」，
//  不会崩溃、不会报错，肉眼也需要对照才能发现。
//
//  ── 测试策略：断言不变量，而不是抄写坐标 ──────────────────────
//
//  刻意**不**把推导出的绝对坐标写进断言（如「撤销按钮在 x=166」）：
//  那等于把实现抄一遍，重构时要么被迫同步修改、要么测试失去意义。
//
//  这里只断言**结构性不变量**——等尺寸、不重叠、间距取自允许的集合、
//  总宽与末尾留白一致。它们既能在重构中原样通过，又能在算错时失败。
//

import AnShotCore
import CoreGraphics
import Testing

@testable import AnShotUI

/// 工具条中允许出现的相邻间距取值。
private let allowedGaps: Set<CGFloat> = [
    AnnotationToolbarLayout.itemSpacing,
    AnnotationToolbarLayout.groupSpacing
]

@Suite("工具栏布局 · 工具条")
struct AnnotationToolbarLayoutBarTests {

    /// 取一条「所有可选条目都存在」的布局：矩形工具使颜色入口存在。
    private func makeFullLayout(canUndo: Bool = true, canRedo: Bool = true) -> (
        items: [AnnotationToolbarLayout.Item], size: CGSize
    ) {
        var layout = AnnotationToolbarLayout()
        layout.tool = .rectangle
        layout.canUndo = canUndo
        layout.canRedo = canRedo
        return layout.layoutBar()
    }

    @Test("所有条目等尺寸、同一纵坐标")
    func allItemsShareSizeAndBaseline() {
        let (items, _) = makeFullLayout()
        #expect(!items.isEmpty)

        let expectedY = (AnnotationToolbarLayout.barHeight - AnnotationToolbarLayout.iconButtonSize) / 2
        for item in items {
            #expect(
                item.rect.width == AnnotationToolbarLayout.iconButtonSize,
                "\(item.kind) 宽度应为 iconButtonSize"
            )
            #expect(
                item.rect.height == AnnotationToolbarLayout.iconButtonSize,
                "\(item.kind) 高度应为 iconButtonSize"
            )
            #expect(
                item.rect.minY == expectedY,
                "\(item.kind) 应与其它条目同一基线（垂直居中）"
            )
        }
    }

    @Test("条目从左到右依次排布，互不重叠")
    func itemsAreLaidOutLeftToRightWithoutOverlap() {
        let (items, _) = makeFullLayout()
        let sorted = items.sorted { $0.rect.minX < $1.rect.minX }

        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            #expect(
                next.rect.minX >= previous.rect.maxX,
                "\(next.kind) 与 \(previous.kind) 重叠了"
            )
        }
    }

    @Test("相邻间距只取 itemSpacing 或 groupSpacing")
    func gapsComeFromAllowedSet() {
        let (items, _) = makeFullLayout()
        let sorted = items.sorted { $0.rect.minX < $1.rect.minX }

        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            let gap = next.rect.minX - previous.rect.maxX
            #expect(
                allowedGaps.contains(gap),
                "\(previous.kind)→\(next.kind) 的间距是 \(gap)，不在允许集合 \(allowedGaps.sorted()) 内"
            )
        }
    }

    @Test("总宽度 = 最后一个条目的右缘 + 右侧留白")
    func totalWidthLeavesTrailingPadding() {
        let (items, size) = makeFullLayout()
        guard let last = items.max(by: { $0.rect.maxX < $1.rect.maxX }) else {
            Issue.record("布局不应为空")
            return
        }
        #expect(size.width == last.rect.maxX + AnnotationToolbarLayout.padding)
        #expect(size.height == AnnotationToolbarLayout.barHeight)
    }

    @Test("首个条目左侧留出 padding")
    func firstItemRespectsLeadingPadding() {
        let (items, _) = makeFullLayout()
        guard let first = items.min(by: { $0.rect.minX < $1.rect.minX }) else {
            Issue.record("布局不应为空")
            return
        }
        #expect(first.rect.minX == AnnotationToolbarLayout.padding)
    }

    @Test("四个工具家族按固定顺序排在最左")
    func familiesLeadInFixedOrder() {
        let (items, _) = makeFullLayout()
        let sorted = items.sorted { $0.rect.minX < $1.rect.minX }
        let families = sorted.prefix(4).map(\.kind)
        #expect(families == [
            .family(.pointer), .family(.shape), .family(.text), .family(.mosaic)
        ])
    }

    @Test("颜色入口仅在该工具可取色时存在")
    func colorButtonOnlyAppearsForColorCapableTools() {
        var layout = AnnotationToolbarLayout()

        // 马赛克是像素处理，没有颜色槽（`AnnotationStyle.color(for:)` 返回 nil）
        layout.tool = .mosaic
        let withoutColor = layout.layoutBar().items
        #expect(
            !withoutColor.contains { $0.kind == .colorButton },
            "马赛克不应出现颜色入口"
        )

        layout.tool = .rectangle
        let withColor = layout.layoutBar().items
        #expect(
            withColor.contains { $0.kind == .colorButton },
            "矩形应出现颜色入口"
        )
        #expect(
            withColor.count == withoutColor.count + 1,
            "颜色入口应恰好占一个条目"
        )
    }

    @Test("撤销 / 重做的可用性直接来自输入")
    func undoRedoEnabledMirrorsInput() {
        var layout = AnnotationToolbarLayout()
        layout.tool = .rectangle

        layout.canUndo = true
        layout.canRedo = false
        var items = layout.layoutBar().items
        #expect(items.first { $0.kind == .undo }?.isEnabled == true)
        #expect(items.first { $0.kind == .redo }?.isEnabled == false)

        layout.canUndo = false
        layout.canRedo = true
        items = layout.layoutBar().items
        #expect(items.first { $0.kind == .undo }?.isEnabled == false)
        #expect(items.first { $0.kind == .redo }?.isEnabled == true)
    }

    @Test("导出组恒存在且顺序固定，排在历史组之后")
    func exportGroupFollowsHistoryInFixedOrder() {
        let (items, _) = makeFullLayout()
        let sorted = items.sorted { $0.rect.minX < $1.rect.minX }
        let kinds = sorted.map(\.kind)
        let expectedTail: [AnnotationToolbarLayout.Kind] = [
            .undo, .redo, .record, .longScreenshot, .recognizeText, .pin, .copy, .save
        ]
        #expect(
            Array(kinds.suffix(expectedTail.count)) == expectedTail,
            "尾部顺序实际为 \(kinds.suffix(expectedTail.count))"
        )
    }

    @Test("颜色入口存在与否不影响其它条目的纵坐标")
    func optionalColorButtonDoesNotShiftBaseline() {
        var layout = AnnotationToolbarLayout()
        let expectedY = (AnnotationToolbarLayout.barHeight - AnnotationToolbarLayout.iconButtonSize) / 2

        for tool in [AnnotationTool.rectangle, .mosaic, .magnifier, .pointer] {
            layout.tool = tool
            for item in layout.layoutBar().items {
                #expect(item.rect.minY == expectedY, "\(tool) 下 \(item.kind) 的纵坐标被改动了")
            }
        }
    }

    @Test("关闭抓屏动作后，录制 / 长截图 / OCR 从主栏消失且工具栏变窄")
    func captureActionsCanBeHidden() {
        var enabled = AnnotationToolbarLayout()
        enabled.tool = .rectangle
        var disabled = enabled
        disabled.allowsCaptureActions = false

        let full = enabled.layoutBar()
        let reduced = disabled.layoutBar()

        let captureKinds: Set<AnnotationToolbarLayout.Kind> = [
            .record, .longScreenshot, .recognizeText
        ]
        #expect(
            full.items.contains { captureKinds.contains($0.kind) },
            "默认应显示三个抓屏动作"
        )
        #expect(
            !reduced.items.contains { captureKinds.contains($0.kind) },
            "关闭后不应再出现抓屏动作"
        )
        // 其余导出项仍在：隐藏的是「抓屏」，不是整组导出。
        #expect(reduced.items.contains { $0.kind == .pin })
        #expect(reduced.items.contains { $0.kind == .copy })
        #expect(reduced.items.contains { $0.kind == .save })
        #expect(
            reduced.size.width < full.size.width,
            "移除三个按钮后工具栏必须收窄（\(reduced.size.width) 应小于 \(full.size.width)）"
        )

        // 原有的结构性不变量在收窄后仍然成立。
        let sorted = reduced.items.sorted { $0.rect.minX < $1.rect.minX }
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            #expect(next.rect.minX >= previous.rect.maxX, "\(next.kind) 与 \(previous.kind) 重叠了")
            let gap = next.rect.minX - previous.rect.maxX
            #expect(allowedGaps.contains(gap), "\(previous.kind)→\(next.kind) 的间距是 \(gap)")
        }
        guard let last = sorted.last else {
            Issue.record("布局不应为空")
            return
        }
        #expect(reduced.size.width == last.rect.maxX + AnnotationToolbarLayout.padding)
    }
}

@Suite("工具栏布局 · 指针选中面板")
struct AnnotationToolbarPointerPanelTests {

    /// 构造指针工具的布局；`selected` / `isText` 描述当前的选中标注。
    private func makePointerLayout(
        selected: Bool,
        isText: Bool = false
    ) -> AnnotationToolbarLayout {
        var layout = AnnotationToolbarLayout()
        layout.tool = .pointer
        layout.hasSelectedAnnotation = selected
        layout.selectedAnnotationIsText = isText
        return layout
    }

    @Test("没有选中时指针面板为空，工具栏只有主栏")
    func emptyWithoutSelection() {
        let layout = makePointerLayout(selected: false)
        let (items, size) = layout.layoutPanel()
        #expect(items.isEmpty)
        #expect(size == .zero)
        #expect(layout.panelSize == .zero)
        #expect(layout.toolbarSize.height == AnnotationToolbarLayout.barHeight)
    }

    @Test("选中标注后面板出现颜色、线宽与删除")
    func showsStyleAndDeleteForShapeSelection() {
        let layout = makePointerLayout(selected: true)
        let (items, size) = layout.layoutPanel()

        #expect(size.height == AnnotationToolbarLayout.panelHeight)
        #expect(items.contains { $0.kind == .deleteSelected }, "应出现删除按钮")
        #expect(items.contains { $0.kind == .lineWidthSlider }, "非文字应出现线宽滑块")
        #expect(
            AnnotationStyle.palette.contains { color in items.contains { $0.kind == .color(color) } },
            "应出现色卡"
        )
        #expect(
            !AnnotationStyle.fontSizes.contains { size in items.contains { $0.kind == .fontSize(size) } },
            "非文字不应出现字号"
        )

        // 删除按钮与其它图标按钮等尺寸；面板项互不重叠。
        if let delete = items.first(where: { $0.kind == .deleteSelected }) {
            #expect(delete.rect.width == AnnotationToolbarLayout.iconButtonSize)
            #expect(delete.rect.height == AnnotationToolbarLayout.iconButtonSize)
        }
        let sorted = items.sorted { $0.rect.minX < $1.rect.minX }
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            #expect(next.rect.minX >= previous.rect.maxX, "\(next.kind) 与 \(previous.kind) 重叠了")
        }
    }

    @Test("选中文字时改用字号档位，不再显示线宽滑块")
    func showsFontSizesForTextSelection() {
        let layout = makePointerLayout(selected: true, isText: true)
        let (items, _) = layout.layoutPanel()

        #expect(items.contains { $0.kind == .deleteSelected })
        #expect(
            AnnotationStyle.fontSizes.contains { size in items.contains { $0.kind == .fontSize(size) } },
            "文字应出现字号档位"
        )
        #expect(!items.contains { $0.kind == .lineWidthSlider }, "文字没有线宽概念")
    }

    @Test("选中标注没有颜色/线宽时，面板只保留删除")
    func hidesUnsupportedStyleControls() {
        var layout = makePointerLayout(selected: true)
        layout.selectedAnnotationSupportsColor = false
        layout.selectedAnnotationSupportsLineWidth = false

        let (items, size) = layout.layoutPanel()
        #expect(items.map(\.kind) == [AnnotationToolbarLayout.Kind.deleteSelected])
        #expect(size.height == AnnotationToolbarLayout.panelHeight)
    }

    @Test("选中面板的条目都落在面板区域内，且不与主栏重叠")
    func panelItemsLiveBelowBar() {
        let layout = makePointerLayout(selected: true)
        let (items, size) = layout.layoutPanel()
        let panelTop = AnnotationToolbarLayout.barHeight + AnnotationToolbarLayout.itemSpacing

        for item in items {
            #expect(item.rect.minY >= panelTop, "\(item.kind) 跑进了主栏")
            #expect(
                item.rect.maxY <= panelTop + size.height,
                "\(item.kind) 超出面板底部"
            )
        }
        #expect(layout.toolbarSize.height == AnnotationToolbarLayout.barHeight
            + AnnotationToolbarLayout.itemSpacing + AnnotationToolbarLayout.panelHeight)
    }

    @Test("选中与否不影响主栏布局")
    func selectionDoesNotChangeBar() {
        var layout = makePointerLayout(selected: false)
        let before = layout.layoutBar()
        layout.hasSelectedAnnotation = true
        let after = layout.layoutBar()

        #expect(before.size == after.size)
        #expect(before.items.map(\.kind) == after.items.map(\.kind))
        #expect(before.items.map(\.rect) == after.items.map(\.rect))
    }
}
