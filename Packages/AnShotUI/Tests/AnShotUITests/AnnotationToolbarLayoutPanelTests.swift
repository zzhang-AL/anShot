//
//  AnnotationToolbarLayoutPanelTests.swift
//  AnShotUITests
//
//  二级面板布局的单元测试（形状面板为主）。
//
//  ── 为什么这些测试必须存在 ────────────────────────────────────
//
//  写这些测试时，`layoutShapePanel` 刚被重构为 `ItemRowCursor` 版本，
//  而那次重构**真的写错了一处**：形状组第一个条目的前置空隙被误写成
//  `groupSpacing`（原实现是从 `padding` 开始），整个面板右移 6pt。
//
//  当时 `layoutBar` 有测试（所以那边一改就发现问题），形状面板没有——
//  只能靠逐个核对手算坐标。本文件就是为了让同类错误下次立即失败。
//
//  ── 入口选择 ──────────────────────────────────────────────────
//
//  通过 **internal** 的 `layoutPanel()` 测试，而不是把 private 的
//  `layoutShapePanel()` 放宽可见性：前者是调用方真正使用的方法，
//  测试它才叫测行为；为了让测试够得着而去降低生产代码的封装，
//  是把测试的需要凌驾于设计之上。
//

import AnShotCore
import CoreGraphics
import Testing

@testable import AnShotUI

@Suite("工具栏布局 · 二级面板")
struct AnnotationToolbarLayoutPanelTests {

    private func makePanel(
        tool: AnnotationTool,
        isPanelExpanded: Bool = true
    ) -> (items: [AnnotationToolbarLayout.Item], size: CGSize) {
        var layout = AnnotationToolbarLayout()
        layout.tool = tool
        layout.isPanelExpanded = isPanelExpanded
        return layout.layoutPanel()
    }

    @Test("面板收起时不产生任何条目")
    func collapsedPanelIsEmpty() {
        let (items, size) = makePanel(tool: .rectangle, isPanelExpanded: false)
        #expect(items.isEmpty)
        #expect(size == .zero)
    }

    @Test("指针工具没有二级面板")
    func pointerToolHasNoPanel() {
        let (items, size) = makePanel(tool: .pointer)
        #expect(items.isEmpty, "指针没有可调项")
        #expect(size == .zero)
    }

    @Test("首个条目从左侧留白开始")
    func firstItemRespectsLeadingPadding() {
        // 这一条正是重构时写错的那处：形状组第一个条目被多加了 groupSpacing，
        // 整个面板因此右移。断言绝对左边界能把这类「整体偏移」直接抓住。
        for tool in [AnnotationTool.rectangle, .text, .mosaic] {
            let (items, _) = makePanel(tool: tool)
            guard let first = items.min(by: { $0.rect.minX < $1.rect.minX }) else {
                Issue.record("\(tool) 的面板不应为空")
                continue
            }
            #expect(
                first.rect.minX == AnnotationToolbarLayout.padding,
                "\(tool) 的首个条目 minX=\(first.rect.minX)，应为 padding=\(AnnotationToolbarLayout.padding)"
            )
        }
    }

    @Test("条目从左到右依次排布，互不重叠")
    func itemsDoNotOverlap() {
        for tool in [AnnotationTool.rectangle, .arrow, .curvedArrow, .numbering, .text, .mosaic] {
            let (items, _) = makePanel(tool: tool)
            let sorted = items.sorted { $0.rect.minX < $1.rect.minX }
            for (previous, next) in zip(sorted, sorted.dropFirst()) {
                #expect(
                    next.rect.minX >= previous.rect.maxX,
                    "\(tool) 下 \(next.kind) 与 \(previous.kind) 重叠"
                )
            }
        }
    }

    @Test("所有条目垂直居中于面板")
    func itemsAreVerticallyCentred() {
        // 面板里有三类尺寸（图标 28、色卡 19、滑块 26），各自的 y 由不同公式算出。
        // 「都居中」是它们唯一的共同不变量，也正是手算时最容易各偏一点的地方。
        //
        // 注意纵坐标的基准：`layoutPanel()` 会把面板条目整体下移一个偏移
        //（面板位于主栏下方），所以不是以 0 为基准、也不是以 `size.height` 为基准。
        let offsetY = AnnotationToolbarLayout.barHeight + AnnotationToolbarLayout.itemSpacing
        for tool in [AnnotationTool.rectangle, .arrow, .curvedArrow, .numbering, .text, .mosaic] {
            let (items, size) = makePanel(tool: tool)
            let expectedMidY = offsetY + size.height / 2
            for item in items {
                #expect(
                    abs(item.rect.midY - expectedMidY) < 0.0001,
                    "\(tool) 下 \(item.kind) 的 midY=\(item.rect.midY)，应为 \(expectedMidY)"
                )
            }
        }
    }

    @Test("总宽 = 最后条目右缘 + 右侧留白")
    func totalWidthLeavesTrailingPadding() {
        for tool in [AnnotationTool.rectangle, .arrow, .curvedArrow, .numbering, .text, .mosaic] {
            let (items, size) = makePanel(tool: tool)
            guard let last = items.max(by: { $0.rect.maxX < $1.rect.maxX }) else {
                Issue.record("\(tool) 的面板不应为空")
                continue
            }
            #expect(
                size.width == last.rect.maxX + AnnotationToolbarLayout.padding,
                "\(tool) 总宽 \(size.width) 与最后条目右缘 \(last.rect.maxX) 不吻合"
            )
            #expect(size.height == AnnotationToolbarLayout.panelHeight)
        }
    }

    @Test("连续滑块只在特定工具下出现的档位按钮确实按条件出现")
    func conditionalGroupsAppearOnlyForTheirTools() {
        let numbering = makePanel(tool: .numbering).items
        #expect(
            numbering.contains { if case .numberingRadius = $0.kind { return true } else { return false } },
            "编号工具应出现半径档位"
        )
        #expect(
            !makePanel(tool: .rectangle).items.contains {
                if case .numberingRadius = $0.kind { return true } else { return false }
            },
            "非编号工具不应出现半径档位"
        )

        let curved = makePanel(tool: .curvedArrow).items
        #expect(
            curved.contains { if case .curvedArrowBend = $0.kind { return true } else { return false } },
            "曲线箭头工具应出现弯曲度档位"
        )
        #expect(
            !makePanel(tool: .rectangle).items.contains {
                if case .curvedArrowBend = $0.kind { return true } else { return false }
            },
            "非曲线箭头工具不应出现弯曲度档位"
        )
    }

    @Test("箭头头部滑块只在箭头类工具下出现")
    func arrowHeadSliderOnlyForArrowTools() {
        for tool in [AnnotationTool.arrow, .curvedArrow] {
            #expect(
                makePanel(tool: tool).items.contains { $0.kind == .arrowHeadScaleSlider },
                "\(tool) 应出现箭头头部滑块"
            )
        }
        for tool in [AnnotationTool.rectangle, .line, .numbering, .freehand] {
            #expect(
                !makePanel(tool: tool).items.contains { $0.kind == .arrowHeadScaleSlider },
                "\(tool) 不应出现箭头头部滑块——它没有箭头头部，多余控件只会撑宽面板"
            )
        }
    }

    @Test("线宽滑块对每个形状类工具恒存在")
    func lineWidthSliderAlwaysPresentForShapeTools() {
        // 只测 shape family。马赛克面板调的是块大小、文字面板调的是字号，
        // 它们各有自己的主轴参数，不含线宽滑块是**正确**的。
        let shapeTools = AnnotationTool.tools(in: .shape)
        #expect(!shapeTools.isEmpty, "shape family 不应为空")
        for tool in shapeTools {
            #expect(
                makePanel(tool: tool).items.contains { $0.kind == .lineWidthSlider },
                "\(tool) 缺少线宽滑块"
            )
        }
    }

    @Test("色卡数量与调色板一致，且每张都是色卡尺寸")
    func swatchCountMatchesPalette() {
        let (items, _) = makePanel(tool: .rectangle)
        let swatches = items.filter {
            if case .color = $0.kind { return true } else { return false }
        }
        #expect(swatches.count == AnnotationStyle.palette.count)
        for swatch in swatches {
            #expect(swatch.rect.width == AnnotationToolbarLayout.swatchSize)
            #expect(swatch.rect.height == AnnotationToolbarLayout.swatchSize)
        }
    }

    @Test("三级面板互不相同：切换工具会改变面板内容")
    func differentToolsYieldDifferentPanels() {
        // 若三个 layoutXxxPanel 因复制粘贴而指向同一份实现，这条会失败。
        let shape = makePanel(tool: .rectangle).items.map(\.kind)
        let text = makePanel(tool: .text).items.map(\.kind)
        let mosaic = makePanel(tool: .mosaic).items.map(\.kind)
        #expect(shape != text)
        #expect(text != mosaic)
        #expect(shape != mosaic)
    }
}
