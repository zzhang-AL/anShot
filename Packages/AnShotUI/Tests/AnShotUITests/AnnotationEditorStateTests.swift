//
//  AnnotationEditorStateTests.swift
//  AnShotUITests
//
//  标注编辑器权威状态的单元测试。
//
//  ── 为什么这些测试必须存在 ────────────────────────────────────
//
//  `AnnotationEditorState` 是标注的唯一权威（工具、样式、选区、已提交标注、
//  草稿、撤销历史全在这里），1059 行，且**只依赖 AnShotCore 与 Foundation**——
//  完全可单测。但 `AnShotUI` 此前没有测试 target，它只能靠
//  `-diagnoseAnnotation` 做截图式比对来验证。
//
//  风险最高的是「撤销/重做」：`EditState` 同时含选区与标注，若只恢复其中一项，
//  用户看到的历史就是错的（画面与历史脱节）。这类缺陷不会崩溃、不会报错，
//  只会让 ⌘Z 做出用户没预期的结果——正是单元测试该锁死的东西。
//
//  ── 测试策略 ──────────────────────────────────────────────────
//
//  用**状态前后对比**而不是计时或截图像素：编辑器是纯值转换，
//  输入状态 → 操作 → 断言状态，无时序依赖，不会 flaky。
//

import AnShotCore
import Foundation
import Testing

@testable import AnShotUI

// MARK: - 辅助

private func makeRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PixelRect {
    PixelRect(
        origin: PixelPoint(x: x, y: y),
        size: PixelSize(width: width, height: height)
    )
}

private let sessionStart = makeRect(0, 0, 100, 100)

// MARK: - 选区与历史

@MainActor
@Suite("标注编辑器 · 选区与历史的耦合")
struct AnnotationEditorSelectionHistoryTests {

    @Test("撤销必须同时恢复选区与标注，而不是只恢复其中一项")
    func undoRestoresSelectionAndAnnotationsTogether() {
        let editor = AnnotationEditorState(selection: sessionStart)

        // 第 1 步：确认一个选区（进历史）
        editor.commitSelection(makeRect(10, 10, 50, 50))
        // 第 2 步：画一个矩形（进历史）
        editor.select(.rectangle)
        editor.beginDraft(at: PixelPoint(x: 20, y: 20))
        editor.updateDraft(to: PixelPoint(x: 60, y: 60))
        #expect(editor.commitDraft(), "有尺寸的草稿应当提交成功")
        #expect(editor.annotations.count == 1)

        // 撤销一次：标注消失，**且**选区回到「画之前」那一个。
        // 只断言 annotations 是不够的——那正是「画面与历史脱节」的漏检点。
        #expect(editor.undo())
        #expect(editor.annotations.isEmpty, "撤销必须撤掉刚画的标注")
        #expect(
            editor.selection == makeRect(10, 10, 50, 50),
            "选区也必须回到上一步快照，实际 \(editor.selection)"
        )

        // 再撤销一次：回到会话起始状态
        #expect(editor.undo())
        #expect(editor.selection == sessionStart)
        #expect(!editor.canUndo, "已回到会话起点，不应再有可撤销步骤")
    }

    @Test("重做把选区与标注一起送回")
    func redoRestoresBothAgain() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.commitSelection(makeRect(5, 5, 20, 20))
        editor.select(.rectangle)
        editor.beginDraft(at: PixelPoint(x: 0, y: 0))
        editor.updateDraft(to: PixelPoint(x: 30, y: 30))
        _ = editor.commitDraft()

        _ = editor.undo()
        _ = editor.undo()
        #expect(editor.selection == sessionStart)

        #expect(editor.redo())
        #expect(editor.selection == makeRect(5, 5, 20, 20), "重做第 1 步：恢复选区")
        #expect(editor.annotations.isEmpty, "此时还没有标注")

        #expect(editor.redo())
        #expect(editor.annotations.count == 1, "重做第 2 步：恢复标注")
        #expect(editor.selection == makeRect(5, 5, 20, 20), "选区保持在上一步的值")
    }

    @Test("识别候选不进历史，并把选区退回候选态")
    func previewSelectionDoesNotEnterHistory() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.commitSelection(makeRect(10, 10, 50, 50))
        editor.confirmSelection()
        #expect(editor.isSelectionConfirmed)

        // 识别随鼠标移动给出新候选
        editor.setPreviewSelection(makeRect(20, 20, 80, 80))
        #expect(editor.selection == makeRect(20, 20, 80, 80))
        #expect(
            !editor.isSelectionConfirmed,
            "识别结果不体现用户决定，必须退回候选态"
        )

        // 撤销一步必须越过候选、直达上一个已提交快照。
        // 若候选被写进历史，这里会停在候选上，⌘Z 就显得「没反应」。
        #expect(editor.undo())
        #expect(
            editor.selection == sessionStart,
            "候选不入历史，撤销不该停在候选上，实际 \(editor.selection)"
        )
    }

    @Test("确认选区不产生撤销步")
    func confirmSelectionDoesNotPushHistory() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.commitSelection(makeRect(10, 10, 50, 50))
        editor.confirmSelection()

        // 只应有一个撤销步（那次 commitSelection）。若「确认」也压栈，
        // 用户按 ⌘Z 会看到画面毫无变化，得按两次才回退。
        #expect(editor.undo())
        #expect(editor.selection == sessionStart)
        #expect(!editor.canUndo)
    }

    @Test("手势结束即使几何未变也必须翻确认状态")
    func commitSelectionConfirmsEvenWhenGeometryUnchanged() {
        // 会话起点是候选，即使带着初始选区进来
        let editor = AnnotationEditorState(selection: makeRect(10, 10, 50, 50))
        #expect(
            !editor.isSelectionConfirmed,
            "初始选区不是用户的决定，必须是候选"
        )

        // 用户拖拽一圈后落回同一个矩形
        editor.commitSelection(makeRect(10, 10, 50, 50))
        #expect(
            editor.isSelectionConfirmed,
            "手势结束本身就宣告确认，与几何是否变化无关"
        )
        #expect(!editor.canUndo, "几何未变则不产生撤销步")
    }

    @Test("选工具会顺带确认候选，避免拖拽变成重新框选")
    func selectingToolConfirmsCandidate() {
        let editor = AnnotationEditorState(selection: makeRect(10, 10, 50, 50))
        #expect(!editor.isSelectionConfirmed)

        editor.select(.rectangle)
        #expect(
            editor.isSelectionConfirmed,
            "选工具等于声明要开始编辑，候选必须就此确认"
        )
    }
}

// MARK: - 草稿

@MainActor
@Suite("标注编辑器 · 草稿不入历史")
struct AnnotationEditorDraftTests {

    @Test("拖拽中间态不产生撤销步")
    func draftUpdatesDoNotPushHistory() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.rectangle)
        editor.beginDraft(at: PixelPoint(x: 10, y: 10))
        for step in 1 ... 20 {
            editor.updateDraft(to: PixelPoint(x: 10 + Double(step), y: 10 + Double(step)))
        }
        #expect(editor.hasDraft)

        // 20 次中间态之后仍应一步可撤都没有：草稿全程只更新 draft，不提交。
        // 若每次 updateDraft 都压栈，⌘Z 会变成「逐像素回退」，彻底不可用。
        #expect(!editor.undo(), "拖拽中间态不得进入历史")
        #expect(!editor.canUndo)
    }

    @Test("单击产生的零尺寸草稿被丢弃，不留标注也不留撤销步")
    func zeroSizeDraftIsDiscarded() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.rectangle)
        editor.beginDraft(at: PixelPoint(x: 30, y: 30))
        // 原地松开：起止同点，矩形宽高为 0

        #expect(!editor.commitDraft(), "零尺寸草稿必须被丢弃")
        #expect(editor.annotations.isEmpty, "误点不得产生不可见的标注")
        #expect(!editor.canUndo, "误点不得留下撤销步")
        #expect(!editor.hasDraft, "被丢弃的草稿必须清空")
    }

    @Test("尺寸刚够的草稿被提交，边界与 isMeaningful 一致")
    func justLargeEnoughDraftIsCommitted() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.rectangle)
        editor.beginDraft(at: PixelPoint(x: 0, y: 0))
        editor.updateDraft(to: PixelPoint(x: 2, y: 2))   // 宽高恰好 2，满足下限
        #expect(editor.commitDraft())
        #expect(editor.annotations.count == 1)
    }

    @Test("手绘累积轨迹点，不退化成起止两点的直线")
    func freehandAccumulatesStrokePoints() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.freehand)
        editor.selectLineWidth(2)

        // 锯齿路径：共线的点会被提交时的 Douglas–Peucker 简化掉，
        // 必须用真正弯曲的轨迹才能证明「点被保留」。
        let waypoints: [PixelPoint] = [
            PixelPoint(x: 0, y: 0),
            PixelPoint(x: 20, y: 0),
            PixelPoint(x: 40, y: 40),
            PixelPoint(x: 60, y: 0),
            PixelPoint(x: 80, y: 40),
            PixelPoint(x: 100, y: 0)
        ]
        editor.beginDraft(at: waypoints[0])
        for point in waypoints.dropFirst() {
            editor.updateDraft(to: point)
        }
        #expect(editor.commitDraft())

        guard case let .freehand(points, _) = editor.annotations.first?.kind else {
            Issue.record("应提交一个手绘标注，实际 \(String(describing: editor.annotations.first?.kind))")
            return
        }
        #expect(
            points.count >= 3,
            "手绘必须保留轨迹点；只留有 2 个点说明退化成了直线，实际 \(points.count) 个"
        )
    }

    @Test("切换工具丢弃未完成草稿：它属于上一个工具")
    func switchingToolDiscardsDraft() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.rectangle)
        editor.beginDraft(at: PixelPoint(x: 10, y: 10))
        editor.updateDraft(to: PixelPoint(x: 50, y: 50))
        #expect(editor.hasDraft)

        editor.select(.arrow)
        #expect(!editor.hasDraft, "切换工具必须丢弃上一工具的草稿")
        #expect(editor.annotations.isEmpty, "被丢弃的草稿不得进入标注列表")
    }

    @Test("编号草稿整段拖拽只取一次序号：拖动不跳号，圆心跟着光标落在松手处")
    func numberingDraftKeepsOneIndexWhileDragging() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.numbering)

        // 模拟 mouseDragged 的每一帧：updateDraft 会反复重建草稿。
        // 修复前每次重建都会 takeNextNumberingIndex，一次拖拽就吃掉十几个号码。
        editor.beginDraft(at: PixelPoint(x: 10, y: 10))
        for step in 1 ... 20 {
            editor.updateDraft(to: PixelPoint(x: 10 + Double(step) * 4, y: 10 + Double(step) * 4))
        }
        #expect(editor.commitDraft())

        guard case let .numbering(center, _, index, _, _, _) = editor.annotations.first?.kind else {
            Issue.record("应提交一个编号标注，实际 \(String(describing: editor.annotations.first?.kind))")
            return
        }
        #expect(index == 1, "一次拖拽只应占用一个序号，实际 \(index)")
        #expect(
            center == PixelPoint(x: 90, y: 90),
            "圆心跟随光标，落在最后一次拖动的位置，实际 \(center)"
        )

        // 下一笔才轮到 2：序号连续，没有因拖动而断档。
        editor.beginDraft(at: PixelPoint(x: 100, y: 100))
        editor.updateDraft(to: PixelPoint(x: 120, y: 120))
        #expect(editor.commitDraft())
        guard case let .numbering(_, _, secondIndex, _, _, _) = editor.annotations.last?.kind else {
            Issue.record("应提交第二个编号标注")
            return
        }
        #expect(secondIndex == 2, "第二笔编号应为 2，实际 \(secondIndex)")
    }

    @Test("被丢弃的编号草稿归还序号，下一笔不留断档")
    func discardedNumberingDraftReleasesIndex() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.numbering)
        editor.beginDraft(at: PixelPoint(x: 10, y: 10))
        editor.updateDraft(to: PixelPoint(x: 40, y: 40))
        editor.discardDraft()

        // 丢弃的草稿从未出现在画面上，它的号码应当可以被复用；
        // 若只增不减，用户第一笔误拖后就会看到编号从 2 开始。
        editor.beginDraft(at: PixelPoint(x: 50, y: 50))
        editor.updateDraft(to: PixelPoint(x: 70, y: 70))
        #expect(editor.commitDraft())
        guard case let .numbering(_, _, index, _, _, _) = editor.annotations.first?.kind else {
            Issue.record("应提交一个编号标注")
            return
        }
        #expect(index == 1, "丢弃草稿占用的序号应被归还，实际 \(index)")
    }

    @Test("指针工具不创建草稿")
    func pointerToolCreatesNoDraft() {
        let editor = AnnotationEditorState(selection: sessionStart)
        #expect(editor.tool == .pointer, "会话起点应是指针工具")
        editor.beginDraft(at: PixelPoint(x: 10, y: 10))
        #expect(!editor.hasDraft, "指针工具只调整选区，不创建标注草稿")
    }
}

// MARK: - 样式

@MainActor
@Suite("标注编辑器 · 样式按工具分组")
struct AnnotationEditorStyleTests {

    @Test("改文字颜色不动形状颜色（样式不串味）")
    func textColorDoesNotLeakIntoShapeColor() {
        let editor = AnnotationEditorState(selection: sessionStart)
        let red = RGBAColor(r: 1, g: 0, b: 0, a: 1)
        let blue = RGBAColor(r: 0, g: 0, b: 1, a: 1)

        editor.select(.rectangle)
        editor.selectColor(blue)
        #expect(editor.style.shapeColor == blue)

        editor.select(.text)
        editor.selectColor(red)

        #expect(editor.style.textColor == red, "文字颜色应当被写入文字槽")
        #expect(
            editor.style.shapeColor == blue,
            "改文字颜色不得影响形状颜色——这正是分组存在的理由"
        )
    }

    @Test("高亮颜色独立于形状颜色")
    func highlightColorIsIndependent() {
        let editor = AnnotationEditorState(selection: sessionStart)
        let shape = RGBAColor(r: 1, g: 0, b: 0, a: 1)
        let highlight = RGBAColor(r: 1, g: 1, b: 0, a: 0.4)

        editor.select(.rectangle)
        editor.selectColor(shape)
        editor.select(.highlight)
        editor.selectColor(highlight)

        #expect(editor.style.highlightColor == highlight)
        #expect(editor.style.shapeColor == shape, "高亮不得改动形状颜色槽")
    }

    @Test("线宽量化到 0.1，且结果与界面显示的一位小数严格相等")
    func lineWidthIsQuantizedExactly() {
        let editor = AnnotationEditorState(selection: sessionStart)
        let range = AnnotationStyle.lineWidthRange

        // 断言用**精确相等**而不是容差。
        //
        // 量化的目的就是「模型存的值 == 界面显示的那一位小数」；
        // 一旦用容差就放过了 2.3000000000000003 这类误差——
        // 那正是修复前真实存在的缺陷（`23 * 0.1 != 2.3`）。
        editor.selectLineWidth(4.3478260869565215)
        #expect(
            editor.style.shapeLineWidth == 4.3,
            "应量化为 4.3，实际 \(editor.style.shapeLineWidth)"
        )

        // 修复前这一个会失败：2.25 → 2.3000000000000003 ≠ 2.3
        editor.selectLineWidth(2.25)
        #expect(
            editor.style.shapeLineWidth == 2.3,
            "2.25 应量化为 2.3，实际 \(editor.style.shapeLineWidth)"
        )

        editor.selectLineWidth(1.05)
        #expect(editor.style.shapeLineWidth == 1.1)

        editor.selectLineWidth(range.lowerBound - 100)
        #expect(editor.style.shapeLineWidth == range.lowerBound, "低于下界必须夹取")

        editor.selectLineWidth(range.upperBound + 100)
        #expect(editor.style.shapeLineWidth == range.upperBound, "高于上界必须夹取")
    }

    @Test("步长 0.1 全区间量化结果都严格等于一位小数字面量")
    func lineWidthQuantizationIsExactAcrossRange() {
        // 穷尽整个区间。这类浮点缺陷只在特定取值上暴露：
        // 修复前 4.3 恰好正确、2.3 才是错的——抽查几个值必然漏掉。
        let editor = AnnotationEditorState(selection: sessionStart)
        var failures: [(input: Double, got: Double)] = []
        var value = AnnotationStyle.lineWidthRange.lowerBound
        while value <= AnnotationStyle.lineWidthRange.upperBound {
            editor.selectLineWidth(value)
            let quantized = editor.style.shapeLineWidth
            let oneDecimal = (quantized * 10).rounded() / 10
            if quantized != oneDecimal {
                failures.append((value, quantized))
            }
            value += 0.05
        }
        #expect(
            failures.isEmpty,
            "以下输入量化后与一位小数字面量不等：\(failures.map { "\($0.input)→\($0.got)" })"
        )
    }

    @Test("箭头头部倍率量化到 0.1 并夹在区间内")
    func arrowHeadScaleIsQuantizedAndClamped() {
        let editor = AnnotationEditorState(selection: sessionStart)
        let range = AnnotationStyle.arrowHeadScaleRange

        editor.selectArrowHeadScale(1.24)
        #expect(
            editor.style.arrowHeadScale == 1.2,
            "应量化为 1.2，实际 \(editor.style.arrowHeadScale)"
        )

        editor.selectArrowHeadScale(0)
        #expect(editor.style.arrowHeadScale == range.lowerBound)

        editor.selectArrowHeadScale(100)
        #expect(editor.style.arrowHeadScale == range.upperBound)
    }

    @Test("笔刷接口收直径，模型存半径（换算只有一处）")
    func brushDiameterConvertsToRadius() {
        let editor = AnnotationEditorState(selection: sessionStart)
        let range = AnnotationStyle.mosaicBrushDiameterRange

        editor.selectMosaicBrushDiameter(32)
        #expect(editor.style.mosaicBrushRadius == 16, "直径 32 应存为半径 16")

        // 非偶数直径：量化到整数点后再取半，允许出现 .5 半径
        editor.selectMosaicBrushDiameter(33)
        #expect(editor.style.mosaicBrushRadius == 16.5)

        editor.selectMosaicBrushDiameter(0)
        #expect(editor.style.mosaicBrushRadius == range.lowerBound / 2, "低于下界夹取后取半")

        editor.selectMosaicBrushDiameter(10_000)
        #expect(editor.style.mosaicBrushRadius == range.upperBound / 2, "高于上界夹取后取半")
    }

    @Test("放大镜与马赛克没有颜色槽")
    func pixelToolsHaveNoColorSlot() {
        let editor = AnnotationEditorState(selection: sessionStart)
        // 放大镜/马赛克是像素处理：给它们显示「颜色」会让用户以为能改像素色
        #expect(editor.style.color(for: .mosaic) == nil)
        #expect(editor.style.color(for: .magnifier) == nil)
        #expect(editor.style.color(for: .pointer) == nil)
    }
}

// MARK: - 文字编辑

@MainActor
@Suite("标注编辑器 · 文字编辑")
struct AnnotationEditorTextTests {

    @Test("空文本提交 = 放弃，不产生标注也不进历史")
    func emptyTextIsDiscarded() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.text)
        editor.beginTextEditing(at: PixelPoint(x: 10, y: 10))
        editor.updateTextDraft("   \n  ")   // 只有空白

        #expect(!editor.commitTextDraft(scaleFactor: 2), "空白文本应被视为放弃")
        #expect(editor.annotations.isEmpty)
        #expect(!editor.canUndo, "放弃不得留下撤销步")
        #expect(!editor.isEditingText)
    }

    @Test("重新编辑保持原标注的 ID 与 z 序")
    func reEditingPreservesIdentityAndOrder() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.text)

        // 先放两个文字标注
        editor.beginTextEditing(at: PixelPoint(x: 0, y: 0))
        editor.updateTextDraft("第一个")
        #expect(editor.commitTextDraft(scaleFactor: 1))

        editor.beginTextEditing(at: PixelPoint(x: 0, y: 40))
        editor.updateTextDraft("第二个")
        #expect(editor.commitTextDraft(scaleFactor: 1))

        let firstID = editor.annotations[0].id
        let secondID = editor.annotations[1].id
        let countBefore = editor.annotations.count

        // 重新编辑第一个
        editor.beginTextEditing(annotation: editor.annotations[0], topLeft: PixelPoint(x: 0, y: 0))
        editor.updateTextDraft("第一个（已改）")
        #expect(editor.commitTextDraft(scaleFactor: 1))

        #expect(editor.annotations.count == countBefore, "原地替换，不新增标注")
        #expect(editor.annotations[0].id == firstID, "ID 必须保留，否则 z 序与引用会错位")
        #expect(editor.annotations[1].id == secondID)
        guard case let .text(_, text, _, _, _, _) = editor.annotations[0].kind else {
            Issue.record("第一个标注应仍是文字")
            return
        }
        #expect(text == "第一个（已改）")
    }

    @Test("重新编辑时清空内容 = 删除该标注，且可撤销")
    func clearingTextOnReEditDeletesAnnotation() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.text)
        editor.beginTextEditing(at: PixelPoint(x: 0, y: 0))
        editor.updateTextDraft("原文")
        #expect(editor.commitTextDraft(scaleFactor: 1))

        editor.beginTextEditing(annotation: editor.annotations[0], topLeft: PixelPoint(x: 0, y: 0))
        editor.updateTextDraft("   \n  ")   // 清空（含纯空白）
        #expect(editor.commitTextDraft(scaleFactor: 1), "清空已有文字是一次有效的删除操作")
        #expect(editor.annotations.isEmpty, "文档承诺「清空即删除」，不能保留原文")
        #expect(!editor.isEditingText)

        #expect(editor.undo(), "删除应当可撤销")
        #expect(editor.annotations.count == 1, "撤销一次就把标注找回来")
        guard case let .text(_, text, _, _, _, _) = editor.annotations[0].kind else {
            Issue.record("撤销后标注应恢复为文字")
            return
        }
        #expect(text == "原文", "撤销必须恢复原有内容")
    }

    @Test("取消文字编辑不改动已有标注")
    func cancelKeepsOriginalAnnotation() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.text)
        editor.beginTextEditing(at: PixelPoint(x: 0, y: 0))
        editor.updateTextDraft("原文")
        #expect(editor.commitTextDraft(scaleFactor: 1))

        editor.beginTextEditing(annotation: editor.annotations[0], topLeft: PixelPoint(x: 0, y: 0))
        editor.updateTextDraft("改了一半")
        editor.cancelTextEditing()

        #expect(!editor.isEditingText)
        guard case let .text(_, text, _, _, _, _) = editor.annotations[0].kind else {
            Issue.record("标注应仍存在")
            return
        }
        #expect(text == "原文", "ESC 取消必须丢弃改动")
    }

    @Test("删除正在编辑的文字标注只产生一个撤销步")
    func deletingEditingTextIsOneStep() {
        let editor = AnnotationEditorState(selection: sessionStart)
        editor.select(.text)
        editor.beginTextEditing(at: PixelPoint(x: 0, y: 0))
        editor.updateTextDraft("将被删除")
        #expect(editor.commitTextDraft(scaleFactor: 1))
        #expect(editor.annotations.count == 1)

        editor.beginTextEditing(annotation: editor.annotations[0], topLeft: PixelPoint(x: 0, y: 0))
        editor.deleteEditingText()
        #expect(editor.annotations.isEmpty)
        #expect(!editor.isEditingText)

        #expect(editor.undo(), "删除应当可撤销")
        #expect(editor.annotations.count == 1, "撤销一次就把标注找回来")
        // 提交文字与删除各占一步，故此处仍可继续撤销
        #expect(editor.canUndo, "提交与删除各占一步，此时仍有可撤销步骤")

        #expect(editor.undo())
        #expect(editor.annotations.isEmpty, "再撤销一次才回到会话起点")
        #expect(!editor.canUndo)
    }
}

// MARK: - 标注选中

/// 画一个矩形并返回它的 ID。
///
/// 走真实的草稿路径（而不是往 `annotations` 里塞值）：编辑器的几何
/// 与命中测试必须建立在「用户真的这样画出来」的标注上。
@MainActor
@discardableResult
private func drawRectangle(
    _ editor: AnnotationEditorState,
    from start: PixelPoint,
    to end: PixelPoint
) -> UUID {
    editor.select(.rectangle)
    editor.beginDraft(at: start)
    editor.updateDraft(to: end)
    _ = editor.commitDraft()
    return editor.annotations.last!.id
}

/// 画一段文字并返回它的 ID。`topLeft` 是文字左上角（底图像素）。
@MainActor
@discardableResult
private func drawText(
    _ editor: AnnotationEditorState,
    at topLeft: PixelPoint,
    _ content: String
) -> UUID {
    editor.select(.text)
    editor.beginTextEditing(at: topLeft)
    editor.updateTextDraft(content)
    _ = editor.commitTextDraft(scaleFactor: 1)
    return editor.annotations.last!.id
}

@MainActor
@Suite("标注编辑器 · 选中")
struct AnnotationEditorSelectionTests {

    @Test("命中最上层标注：重叠时选中的是后画的那一条")
    func selectsTopmostAnnotation() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        // 高亮是面状命中，两个重叠矩形可以直接断言 z 序。
        editor.select(.highlight)
        editor.beginDraft(at: PixelPoint(x: 0, y: 0))
        editor.updateDraft(to: PixelPoint(x: 100, y: 100))
        _ = editor.commitDraft()
        editor.beginDraft(at: PixelPoint(x: 50, y: 50))
        editor.updateDraft(to: PixelPoint(x: 150, y: 150))
        _ = editor.commitDraft()

        #expect(editor.annotations.count == 2)
        let topID = editor.annotations[1].id
        let bottomID = editor.annotations[0].id

        #expect(editor.selectAnnotation(at: PixelPoint(x: 75, y: 75), tolerance: 2))
        #expect(
            editor.selectedAnnotationID == topID,
            "重叠处应选中 z 序更靠上的那条，实际 \(String(describing: editor.selectedAnnotationID))"
        )

        // 只有下面那条覆盖的位置
        #expect(editor.selectAnnotation(at: PixelPoint(x: 20, y: 20), tolerance: 2))
        #expect(editor.selectedAnnotationID == bottomID)
    }

    @Test("空心矩形只有边界命中，内部不命中")
    func outlinedRectangleInteriorIsNotAHit() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        drawRectangle(editor, from: PixelPoint(x: 20, y: 20), to: PixelPoint(x: 80, y: 60))

        #expect(
            !editor.selectAnnotation(at: PixelPoint(x: 50, y: 40), tolerance: 2),
            "空心框内部不应命中，否则它会挡住框里的其它标注"
        )
        #expect(editor.selectAnnotation(at: PixelPoint(x: 50, y: 20), tolerance: 2), "边界应命中")
        #expect(editor.hasSelectedAnnotation)

        // 点到空白：既返回 false，也把已有选中清掉。
        #expect(!editor.selectAnnotation(at: PixelPoint(x: 180, y: 180), tolerance: 2))
        #expect(!editor.hasSelectedAnnotation, "点空白必须清除选中")
    }

    @Test("点在空白处清除选中，且选中本身不产生撤销步")
    func clickingEmptyAreaClearsSelectionWithoutHistory() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        drawRectangle(editor, from: PixelPoint(x: 20, y: 20), to: PixelPoint(x: 80, y: 60))
        #expect(editor.selectAnnotation(at: PixelPoint(x: 20, y: 40), tolerance: 2))

        // 此时历史里只有「提交这条标注」一步。选中若也压栈，撤销后画面
        // 依然有标注，用户会以为 ⌘Z 坏了。
        #expect(editor.undo())
        #expect(editor.annotations.isEmpty, "撤销应当直接越过选中，撤掉标注")
        #expect(
            !editor.hasSelectedAnnotation,
            "选中的标注已不存在，选中必须自动清空"
        )
    }

    @Test("切到绘制工具清除选中，切回指针保留")
    func toolSwitchingKeepsSelectionOnlyForPointer() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        drawRectangle(editor, from: PixelPoint(x: 20, y: 20), to: PixelPoint(x: 80, y: 60))
        #expect(editor.selectAnnotation(at: PixelPoint(x: 50, y: 20), tolerance: 2))

        editor.select(.arrow)
        #expect(!editor.hasSelectedAnnotation, "切到绘制工具必须清空选中")

        #expect(editor.selectAnnotation(at: PixelPoint(x: 50, y: 20), tolerance: 2))
        editor.select(.pointer)
        #expect(
            editor.hasSelectedAnnotation,
            "指针工具就是用来继续调整的，切到指针不得清空选中"
        )
    }
}

// MARK: - 移动

@MainActor
@Suite("标注编辑器 · 移动")
struct AnnotationEditorMoveTests {

    @Test("移动选中标注并进入历史，撤销回到原位")
    func moveEntersHistory() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        drawRectangle(editor, from: PixelPoint(x: 20, y: 20), to: PixelPoint(x: 80, y: 60))
        #expect(editor.selectAnnotation(at: PixelPoint(x: 50, y: 20), tolerance: 2))

        let before = editor.annotations[0].hitBoundingRect
        editor.moveSelected(by: PixelPoint(x: 10, y: 5))
        let after = editor.annotations[0].hitBoundingRect
        #expect(after.origin == PixelPoint(x: 30, y: 25))
        #expect(after.size == before.size, "移动只改位置，不改尺寸")

        #expect(editor.undo())
        #expect(editor.annotations[0].hitBoundingRect.origin == before.origin, "撤销回到原位")
        #expect(editor.redo())
        #expect(editor.annotations[0].hitBoundingRect.origin == after.origin)
    }

    @Test("移动被夹在选区内，不能整块移出画布")
    func moveIsClampedIntoSelection() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 100, 100))
        drawRectangle(editor, from: PixelPoint(x: 10, y: 10), to: PixelPoint(x: 50, y: 40))
        #expect(editor.selectAnnotation(at: PixelPoint(x: 30, y: 10), tolerance: 2))

        editor.moveSelected(by: PixelPoint(x: 1000, y: 1000))
        let moved = editor.annotations[0].hitBoundingRect
        #expect(moved.origin.x + moved.size.width == 100, "右边界应停在画布边缘")
        #expect(moved.origin.y + moved.size.height == 100, "下边界应停在画布边缘")

        editor.moveSelected(by: PixelPoint(x: -1000, y: -1000))
        let back = editor.annotations[0].hitBoundingRect
        #expect(back.origin == PixelPoint(x: 0, y: 0), "反方向同样夹在画布内")
    }

    @Test("文字按下真实包围盒夹取，而不是零尺寸点")
    func textMoveUsesMeasuredBounds() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        drawText(editor, at: PixelPoint(x: 20, y: 20), "移动我")
        editor.select(.pointer)
        let box = editor.annotations[0].hitBoundingRect
        #expect(box.size.width > 0, "文字包围盒必须有宽度可供夹取")

        #expect(editor.selectAnnotation(
            at: PixelPoint(x: box.origin.x + box.size.width / 2, y: box.origin.y + box.size.height / 2),
            tolerance: 0
        ))
        editor.moveSelected(by: PixelPoint(x: 5000, y: 5000))

        let moved = editor.annotations[0].hitBoundingRect
        #expect(moved.origin.x + moved.size.width <= 200.001, "右边界不得越过选区")
        #expect(moved.origin.y + moved.size.height <= 200.001, "下边界不得越过选区")
        #expect(moved.size.width == box.size.width, "移动不改字号")
    }

    @Test("没有选中时移动是空操作，不产生撤销步")
    func moveWithoutSelectionDoesNothing() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        drawRectangle(editor, from: PixelPoint(x: 10, y: 10), to: PixelPoint(x: 40, y: 40))
        // 绘制优先契约下刚提交的新标注会自动选中，这里显式取消选中再测无选中移动。
        editor.clearAnnotationSelection()
        let before = editor.annotations[0]
        editor.moveSelected(by: PixelPoint(x: 10, y: 10))
        #expect(editor.annotations[0] == before)
        #expect(editor.undo())
        #expect(editor.annotations.isEmpty, "唯一一步应仍是「提交标注」")
    }
}

// MARK: - 删除

@MainActor
@Suite("标注编辑器 · 删除选中")
struct AnnotationEditorDeleteTests {

    @Test("删除选中标注并进入历史，撤销可找回")
    func deleteAndUndo() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        drawRectangle(editor, from: PixelPoint(x: 10, y: 10), to: PixelPoint(x: 50, y: 40))
        #expect(editor.selectAnnotation(at: PixelPoint(x: 30, y: 10), tolerance: 2))

        #expect(editor.deleteSelected())
        #expect(editor.annotations.isEmpty)
        #expect(!editor.hasSelectedAnnotation, "删除后选中必须清空")

        #expect(editor.undo())
        #expect(editor.annotations.count == 1, "撤销把标注找回来")
        #expect(
            !editor.hasSelectedAnnotation,
            "选中态不在历史里：恢复标注不等于恢复选中"
        )
    }

    @Test("没有选中时删除返回 false，不产生撤销步")
    func deleteWithoutSelectionIsNoOp() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        drawRectangle(editor, from: PixelPoint(x: 10, y: 10), to: PixelPoint(x: 50, y: 40))
        editor.clearAnnotationSelection()
        #expect(!editor.deleteSelected())
        #expect(editor.annotations.count == 1)
    }
}

// MARK: - 改样式

/// 改样式测试用的目标颜色（放在文件作用域，避免给 suite 增加实例状态）。
private let restyleBlue = RGBAColor(r: 0, g: 0, b: 1, a: 1)

@MainActor
@Suite("标注编辑器 · 选中项改样式")
struct AnnotationEditorRestyleTests {

    @Test("改色同时作用于选中标注与样式，且可撤销")
    func colorUpdatesAnnotationAndStyle() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        drawRectangle(editor, from: PixelPoint(x: 10, y: 10), to: PixelPoint(x: 50, y: 40))
        #expect(editor.selectAnnotation(at: PixelPoint(x: 30, y: 10), tolerance: 2))

        guard case let .rectangle(_, originalStroke, _, _) = editor.annotations[0].kind else {
            Issue.record("应有一条矩形标注")
            return
        }
        let originalColor = originalStroke.color

        editor.selectColor(restyleBlue)

        #expect(editor.style.shapeColor == restyleBlue, "样式槽也要跟着变（下一笔用新颜色）")
        guard case let .rectangle(_, updatedStroke, _, _) = editor.annotations[0].kind else {
            Issue.record("应有一条矩形标注")
            return
        }
        #expect(updatedStroke.color == restyleBlue, "选中标注本身必须被改色")

        #expect(editor.undo())
        guard case let .rectangle(_, undoneStroke, _, _) = editor.annotations[0].kind else {
            Issue.record("应有一条矩形标注")
            return
        }
        #expect(undoneStroke.color == originalColor, "撤销恢复原色")
    }

    @Test("没有选中时只改样式，不产生撤销步")
    func colorWithoutSelectionOnlyTouchesStyle() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        editor.selectColor(restyleBlue)
        #expect(editor.style.shapeColor == restyleBlue)
        #expect(!editor.canUndo, "只改样式不得产生撤销步")
    }

    @Test("线宽改的是量化后的值，与界面读数一致")
    func lineWidthAppliesQuantizedValue() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        drawRectangle(editor, from: PixelPoint(x: 10, y: 10), to: PixelPoint(x: 50, y: 40))
        #expect(editor.selectAnnotation(at: PixelPoint(x: 30, y: 10), tolerance: 2))

        editor.selectLineWidth(6.25)
        guard case let .rectangle(_, stroke, _, _) = editor.annotations[0].kind else {
            Issue.record("应有一条矩形标注")
            return
        }
        #expect(editor.style.shapeLineWidth == 6.3)
        #expect(stroke.width == 6.3, "标注线宽必须与界面显示的同为 6.3")
    }

    @Test("字号改的是选中文字，且保持左上角不动")
    func fontSizeAppliesToSelectedText() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        drawText(editor, at: PixelPoint(x: 20, y: 20), "字号")
        editor.select(.pointer)
        let boxBefore = editor.annotations[0].hitBoundingRect
        #expect(editor.selectAnnotation(
            at: PixelPoint(x: boxBefore.origin.x + 2, y: boxBefore.origin.y + 2),
            tolerance: 0
        ))

        editor.selectFontSize(48)
        guard case let .text(_, _, font, _, _, _) = editor.annotations[0].kind else {
            Issue.record("应有一条文字标注")
            return
        }
        #expect(font.size == 48)

        let boxAfter = editor.annotations[0].hitBoundingRect
        #expect(abs(boxAfter.origin.y - boxBefore.origin.y) < 0.5, "放大的文字不应从顶端窜出去")
        #expect(boxAfter.size.height > boxBefore.size.height)

        #expect(editor.undo())
        guard case let .text(_, _, undoneFont, _, _, _) = editor.annotations[0].kind else {
            Issue.record("应有一条文字标注")
            return
        }
        #expect(undoneFont.size == AnnotationStyle.default.textFontSize)
    }

    @Test("马赛克没有颜色/线宽概念，改样式不会凭空产生撤销步")
    func mosaicIgnoresColorAndLineWidth() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        editor.select(.mosaic)
        editor.beginDraft(at: PixelPoint(x: 10, y: 10))
        editor.updateDraft(to: PixelPoint(x: 60, y: 60))
        _ = editor.commitDraft()
        editor.select(.pointer)
        #expect(editor.selectAnnotation(at: PixelPoint(x: 30, y: 30), tolerance: 2))

        let before = editor.annotations[0]
        editor.updateSelectedColor(restyleBlue)
        editor.updateSelectedLineWidth(10)
        #expect(editor.annotations[0] == before, "马赛克的颜色/线宽不参与渲染，改动应是空操作")
    }
}

// MARK: - 2x 字号对齐、手势事务、控制手柄与层级操作

@MainActor
@Suite("标注编辑器 · 字号对齐与高级编辑能力")
struct AnnotationEditorEnhancementTests {

    @Test("2x 屏下文字重编辑字号除以 scaleFactor 不翻倍，指针改字号乘以 scaleFactor 不缩水")
    func textFontSizeAlignsBetweenPointsAndPixels() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 400, 400))
        editor.select(.text)
        editor.selectFontSize(28, scaleFactor: 2)
        editor.beginTextEditing(at: PixelPoint(x: 20, y: 20))
        editor.updateTextDraft("Retina 文字")
        #expect(editor.commitTextDraft(scaleFactor: 2))

        guard case let .text(origin, _, createdFont, _, _, _) = editor.annotations.first?.kind else {
            Issue.record("应存在一条文字标注")
            return
        }
        #expect(createdFont.size == 56, "28pt 在 2x 屏模型字号应为 56px")

        // 双击重编辑：传入 scaleFactor: 2 应还原为 28pt，提交后保持 56px 不翻倍
        let topLeft = PixelPoint(x: origin.x, y: origin.y - TextMetrics.ascent(for: createdFont))
        editor.beginTextEditing(annotation: editor.annotations[0], topLeft: topLeft, scaleFactor: 2)
        #expect(editor.textDraft?.fontSize == 28, "重编辑字号应还原为逻辑点 28")
        #expect(editor.commitTextDraft(scaleFactor: 2))

        guard case let .text(_, _, reEditedFont, _, _, _) = editor.annotations[0].kind else {
            Issue.record("应仍存在文字标注")
            return
        }
        #expect(reEditedFont.size == 56, "重编辑提交后字号不得翻倍成 112px")

        // 指针选中改字号：选 40pt 写入 80px
        editor.select(.pointer)
        let box = editor.annotations[0].hitBoundingRect
        #expect(editor.selectAnnotation(at: PixelPoint(x: box.origin.x + 4, y: box.origin.y + 4), tolerance: 2))
        editor.updateSelectedFontSize(40, scaleFactor: 2)
        guard case let .text(_, _, resizedFont, _, _, _) = editor.annotations[0].kind else {
            Issue.record("应仍存在文字标注")
            return
        }
        #expect(resizedFont.size == 80, "指针改字号 40pt 在 2x 屏下应存为 80px")
        #expect(editor.selectedTextLogicalFontSize(scaleFactor: 2) == 40)
    }

    @Test("手势起止事务把连续移动和线宽拖动合并为单条撤销记录")
    func editTransactionCoalescesHistoryIntoSingleStep() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 300, 300))
        drawRectangle(editor, from: PixelPoint(x: 20, y: 20), to: PixelPoint(x: 80, y: 60))
        let original = editor.annotations[0]
        editor.select(.pointer)
        #expect(editor.selectAnnotation(at: PixelPoint(x: 50, y: 20), tolerance: 2))

        // 连续移动 20 次仅压入 1 步撤销
        editor.beginEditTransaction()
        for _ in 0 ..< 20 {
            editor.moveSelected(by: PixelPoint(x: 2, y: 1))
        }
        editor.commitEditTransaction()

        #expect(editor.annotations[0].hitBoundingRect.origin == PixelPoint(x: 60, y: 40))
        #expect(editor.undo())
        #expect(editor.annotations[0] == original, "撤销 1 次即完整回到拖拽前原位")

        // 连续拖动线宽滑块仅压入 1 步撤销
        editor.beginEditTransaction()
        for width in stride(from: 2.0, through: 12.0, by: 1.0) {
            editor.selectLineWidth(width)
        }
        editor.commitEditTransaction()

        guard case let .rectangle(_, updatedStroke, _, _) = editor.annotations[0].kind else {
            Issue.record("应为矩形标注")
            return
        }
        #expect(updatedStroke.width == 12.0)
        #expect(editor.undo())
        #expect(editor.annotations[0] == original, "撤销 1 次即完整退回滑块拖动前线宽")
    }

    @Test("调粗已有箭头和弯曲箭头线宽时按比例同步放大头部尺寸")
    func restylingArrowLineWidthScalesHeadDimensions() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 300, 300))
        editor.selectLineWidth(4)
        editor.select(.arrow)
        editor.beginDraft(at: PixelPoint(x: 20, y: 20))
        editor.updateDraft(to: PixelPoint(x: 120, y: 20))
        #expect(editor.commitDraft())

        guard case let .arrow(_, _, oldStroke, oldLen, oldWidth) = editor.annotations[0].kind else {
            Issue.record("应为箭头标注")
            return
        }
        #expect(oldStroke.width == 4)

        editor.select(.pointer)
        #expect(editor.selectAnnotation(at: PixelPoint(x: 70, y: 20), tolerance: 2))
        editor.updateSelectedLineWidth(12)

        guard case let .arrow(_, _, newStroke, newLen, newWidth) = editor.annotations[0].kind else {
            Issue.record("应为箭头标注")
            return
        }
        #expect(newStroke.width == 12)
        #expect(abs(newLen - oldLen * 3) < 0.001)
        #expect(abs(newWidth - oldWidth * 3) < 0.001)
    }

    @Test("荧光笔高亮工具拒绝不透明色值，自动锁定 alpha = 0.35")
    func highlightToolLocksTranslucentAlpha() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 200, 200))
        editor.select(.highlight)
        // 模拟从取色器传入全不透明黑色 (a = 1.0)
        editor.selectColor(RGBAColor(r: 0, g: 0, b: 0, a: 1.0))
        #expect(abs(editor.style.highlightColor.a - 0.35) < 0.001, "不透明色必须被锁定回半透明 0.35")

        editor.beginDraft(at: PixelPoint(x: 10, y: 10))
        editor.updateDraft(to: PixelPoint(x: 80, y: 40))
        #expect(editor.commitDraft())

        editor.select(.pointer)
        #expect(editor.selectAnnotation(at: PixelPoint(x: 40, y: 25), tolerance: 2))
        editor.updateSelectedColor(RGBAColor(r: 1, g: 0, b: 0, a: 1.0))
        guard case let .highlight(_, updatedColor) = editor.annotations[0].kind else {
            Issue.record("应为高亮标注")
            return
        }
        #expect(abs(updatedColor.a - 0.35) < 0.001, "选中高亮改色也不得变成实心块")
    }

    @Test("指针控制手柄支持矩形缩放、弯曲箭头调弯、放大镜改半径，以及置顶置底和复制")
    func controlHandlesZOrderAndDuplicateWork() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 400, 400))
        drawRectangle(editor, from: PixelPoint(x: 20, y: 20), to: PixelPoint(x: 100, y: 80))

        editor.select(.curvedArrow)
        editor.beginDraft(at: PixelPoint(x: 40, y: 120))
        editor.updateDraft(to: PixelPoint(x: 200, y: 120))
        #expect(editor.commitDraft())

        editor.select(.magnifier)
        editor.beginDraft(at: PixelPoint(x: 250, y: 250))
        editor.updateDraft(to: PixelPoint(x: 290, y: 250))
        #expect(editor.commitDraft())

        editor.select(.pointer)
        // 1. 缩放矩形右下角（矩形含 8 个缩放手柄 + 1 个圆角调节手柄 = 9 个）
        #expect(editor.selectAnnotation(at: PixelPoint(x: 20, y: 50), tolerance: 3))
        let rectHandles = AnnotationEditorState.controlHandles(for: editor.selectedAnnotation!)
        #expect(rectHandles.count == 9)
        #expect(rectHandles.contains(where: { $0.handle == .cornerRadius }))
        editor.updateSelectedControlHandle(.rect(.bottomRight), to: PixelPoint(x: 150, y: 100))
        guard case let .rectangle(resized, _, _, _) = editor.selectedAnnotation?.kind else {
            Issue.record("应为矩形")
            return
        }
        #expect(resized.size == PixelSize(width: 130, height: 80))

        // 2. 置顶与置底
        let firstID = editor.annotations[0].id
        #expect(editor.bringSelectedToFront())
        #expect(editor.annotations.last?.id == firstID)
        #expect(editor.sendSelectedToBack())
        #expect(editor.annotations.first?.id == firstID)

        // 3. 复制
        let countBefore = editor.annotations.count
        #expect(editor.duplicateSelected(offset: PixelPoint(x: 10, y: 10)))
        #expect(editor.annotations.count == countBefore + 1)
        #expect(editor.selectedAnnotationID != firstID)

        // 4. 弯曲箭头控制点
        let curved = editor.annotations.first {
            if case .curvedArrow = $0.kind { return true }
            return false
        }!
        let curvedHandles = AnnotationEditorState.controlHandles(for: curved)
        #expect(curvedHandles.map(\.handle) == [.start, .control, .end])

        // 5. 放大镜半径控制点
        let mag = editor.annotations.first {
            if case .magnifier = $0.kind { return true }
            return false
        }!
        let magHandles = AnnotationEditorState.controlHandles(for: mag)
        #expect(magHandles.map(\.handle) == [.radius])
    }

    @Test("Shift 约束矩形为正方形、直线与箭头对齐 45° 增量")
    func shiftConstrainsGeometry() {
        let square = AnnotationEditorState.constrainedEndPoint(
            PixelPoint(x: 150, y: 120),
            from: PixelPoint(x: 100, y: 100),
            tool: .rectangle,
            isShiftPressed: true
        )
        #expect(square == PixelPoint(x: 150, y: 150))

        let horizontal = AnnotationEditorState.constrainedEndPoint(
            PixelPoint(x: 200, y: 105),
            from: PixelPoint(x: 100, y: 100),
            tool: .line,
            isShiftPressed: true
        )
        #expect(abs(horizontal.y - 100) < 0.001, "接近水平应吸附到 0°")
    }

    @Test("椭圆工具（O 键）、高斯模糊效果与手绘风格端到端接通")
    func ellipseBlurAndSketchyEndToEnd() {
        #expect(AnnotationTool.ellipse.keyCharacter == "o")
        #expect(AnnotationTool.ellipse.family == .shape)

        let editor = AnnotationEditorState(selection: makeRect(0, 0, 400, 400))

        // 1. 开启手绘风并绘制椭圆（含 Shift 正圆约束）
        editor.select(.ellipse)
        editor.toggleSketchy()
        #expect(editor.style.shapeIsSketchy)
        editor.beginDraft(at: PixelPoint(x: 40, y: 40))
        editor.updateDraft(to: PixelPoint(x: 120, y: 90), isShiftPressed: true)
        #expect(editor.commitDraft())

        guard case let .ellipse(ellipseRect, ellipseStroke, _) = editor.annotations.last?.kind else {
            Issue.record("应生成椭圆标注")
            return
        }
        #expect(ellipseRect.size.width == 80 && ellipseRect.size.height == 80, "Shift 约束椭圆为正圆")
        #expect(ellipseStroke.isSketchy, "新绘椭圆应携带手绘风格标记")

        // 2. 切换为高斯模糊并绘制框选与涂抹马赛克
        editor.select(.mosaic)
        editor.selectMosaicEffectMode(.blur)
        #expect(editor.style.mosaicEffectMode == .blur)
        editor.beginDraft(at: PixelPoint(x: 200, y: 40))
        editor.updateDraft(to: PixelPoint(x: 280, y: 100))
        #expect(editor.commitDraft())

        guard case let .mosaic(_, mode, _, _) = editor.annotations.last?.kind else {
            Issue.record("应生成马赛克标注")
            return
        }
        #expect(mode == .blur, "马赛克标注应使用高斯模糊模式")

        // 3. 指针选中后可反向切换手绘风与打码效果
        editor.select(.pointer)
        #expect(editor.selectAnnotation(at: PixelPoint(x: 80, y: 40), tolerance: 4))
        #expect(editor.selectedAnnotationSupportsSketchy)
        #expect(editor.selectedAnnotationIsSketchy)
        editor.toggleSketchy()
        #expect(!editor.selectedAnnotationIsSketchy)

        #expect(editor.selectAnnotation(at: PixelPoint(x: 240, y: 70), tolerance: 4))
        #expect(editor.selectedAnnotationSupportsMosaicEffect)
        #expect(editor.selectedAnnotationMosaicMode == .blur)
        editor.selectMosaicEffectMode(.pixelate)
        #expect(editor.selectedAnnotationMosaicMode == .pixelate)

        // 4. EditorStyleStore 持久化保留 shapeIsSketchy 与 mosaicEffectMode
        let suiteName = "com.anshot.tests.style.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EditorStyleStore(defaults: defaults)
        var saved = AnnotationStyle.default
        saved.shapeIsSketchy = true
        saved.mosaicEffectMode = .blur
        store.save(saved)
        let loaded = store.load()
        #expect(loaded.shapeIsSketchy)
        #expect(loaded.mosaicEffectMode == .blur)
    }

    @Test("马赛克与高斯模糊在各屏幕倍率下均保持强力打码并支持选中调档")
    func mosaicIntensityScaleAndPointerAdjustment() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 800, 600))
        editor.select(.mosaic)

        // 1. 选到最低档（12pt）：2x 屏输出 24px，1x 屏保底 >= 17px，且涂抹半径同步乘以 scaleFactor
        editor.selectMosaicBlockSize(AnnotationStyle.mosaicBlockSizes[0])
        editor.selectMosaicBrushDiameter(32)
        editor.selectMosaicMode(.brush)
        editor.beginDraft(at: PixelPoint(x: 100, y: 100), scaleFactor: 2)
        editor.updateDraft(to: PixelPoint(x: 240, y: 120))
        #expect(editor.commitDraft())

        guard case let .mosaicStroke(_, radius2x, _, intensity2x) = editor.annotations.last?.kind else {
            Issue.record("应生成涂抹马赛克标注")
            return
        }
        #expect(intensity2x == 24, "2x 屏最低档应为 24px，确保常规文字肉眼不可分辨")
        #expect(radius2x == 32, "2x 屏直径 32pt（半径 16pt）应折算为 32px 半径与屏幕光标一致")

        // 2. 1x 非 Retina 屏下最低档也有保底（>= 17px），防止文字漏出
        editor.selectMosaicMode(.rectangle)
        editor.beginDraft(at: PixelPoint(x: 50, y: 50), scaleFactor: 1)
        editor.updateDraft(to: PixelPoint(x: 200, y: 120))
        #expect(editor.commitDraft())

        guard case let .mosaic(_, _, intensity1x, _) = editor.annotations.last?.kind else {
            Issue.record("应生成框选马赛克标注")
            return
        }
        #expect(intensity1x >= 16, "1x 屏最低档也应有足够遮蔽力度，实际 \(intensity1x)")

        // 3. 指针选中已有马赛克后可直接切换到最高档（28pt -> 56px）且支持撤销还原
        editor.select(.pointer)
        #expect(editor.selectAnnotation(at: PixelPoint(x: 100, y: 80), tolerance: 4))
        editor.selectMosaicBlockSize(AnnotationStyle.mosaicBlockSizes[2], scaleFactor: 2)
        guard case let .mosaic(_, _, updatedIntensity, _) = editor.annotations.last?.kind else {
            Issue.record("选中马赛克应保持马赛克类型")
            return
        }
        #expect(updatedIntensity == 56, "切换最高档后应立即更新选中标注为 56px")
        #expect(editor.undo())
        guard case let .mosaic(_, _, restoredIntensity, _) = editor.annotations.last?.kind else {
            Issue.record("撤销后应回到马赛克标注")
            return
        }
        #expect(restoredIntensity == intensity1x, "撤销应还原先前强度")
    }

    @Test("绘图工具下可直接拖动刚画好及已有非背景标注，同时保留未选中框内套画与面状叠加绘制能力")
    func directMoveTargetMatchesDrawingWorkflow() {
        let editor = AnnotationEditorState(selection: makeRect(0, 0, 800, 600))

        // 1. 刚画完的空心矩形处于选中态：边框与框内任意位置均可直接拖动移动；
        //    取消选中后，框内空白恢复放行新建标注（支持大框内套画小框）。
        editor.select(.rectangle)
        editor.beginDraft(at: PixelPoint(x: 100, y: 100))
        editor.updateDraft(to: PixelPoint(x: 300, y: 260))
        #expect(editor.commitDraft())
        let rectID = editor.annotations[0].id
        #expect(editor.selectedAnnotationID == rectID)
        #expect(editor.selectedAnnotationMatchesTool)

        #expect(
            editor.directMoveTarget(at: PixelPoint(x: 200, y: 100), tolerance: 6)?.id == rectID,
            "刚画好矩形的边框应可直接拖动移动，不需切指针工具"
        )
        #expect(
            editor.directMoveTarget(at: PixelPoint(x: 200, y: 180), tolerance: 6)?.id == rectID,
            "当前已选中的空心矩形在框内任意位置也应可直接拖动移动"
        )

        editor.clearAnnotationSelection()
        #expect(
            editor.directMoveTarget(at: PixelPoint(x: 200, y: 180), tolerance: 6) == nil,
            "取消选中后，空心矩形内部空白处应放行新建标注（支持大框内套画小框）"
        )

        // 2. 继续画第二个框后，旧框虽然不再是选中态，其边框仍可直接选中并拖动
        editor.beginDraft(at: PixelPoint(x: 400, y: 100))
        editor.updateDraft(to: PixelPoint(x: 560, y: 220))
        #expect(editor.commitDraft())
        let secondRectID = editor.annotations[1].id
        #expect(editor.selectedAnnotationID == secondRectID)

        #expect(
            editor.directMoveTarget(at: PixelPoint(x: 200, y: 100), tolerance: 6)?.id == rectID,
            "绘图工具下点击旧空心框的边框也应可直接拖走"
        )

        // 3. 刚画完的聚光灯（面状背景型）处于选中态时可直接拖动微调；
        //    切换到箭头工具后聚光灯取消选中，在其内部普通拖动应放行叠加画箭头，按 ⌘/⌃ 则强制拖动
        editor.select(.spotlight)
        editor.beginDraft(at: PixelPoint(x: 50, y: 300))
        editor.updateDraft(to: PixelPoint(x: 350, y: 500))
        #expect(editor.commitDraft())
        let spotlightID = editor.annotations[2].id
        #expect(
            editor.directMoveTarget(at: PixelPoint(x: 200, y: 400), tolerance: 6)?.id == spotlightID,
            "刚画完且选中的聚光灯应允许直接拖动对齐"
        )

        editor.select(.arrow)
        #expect(editor.selectedAnnotationID == nil)
        #expect(
            editor.directMoveTarget(at: PixelPoint(x: 200, y: 400), tolerance: 6) == nil,
            "未选中的聚光灯内部在箭头工具下应放行叠加画箭头"
        )
        #expect(
            editor.directMoveTarget(at: PixelPoint(x: 200, y: 400), tolerance: 6, forceMove: true)?.id == spotlightID,
            "按住 ⌘/⌃（forceMove）时应可强行拖动底层聚光灯"
        )

        // 4. 文字工具下：刚提交的文字处于选中态可直接拖动，点在未选中聚光灯上放行新建文字
        editor.select(.text)
        editor.beginTextEditing(at: PixelPoint(x: 500, y: 350))
        editor.updateTextDraft("Hello")
        #expect(editor.commitTextDraft(scaleFactor: 1))
        let textID = editor.annotations[3].id
        #expect(
            editor.directMoveTarget(at: PixelPoint(x: 515, y: 365), tolerance: 6)?.id == textID,
            "文字工具下刚输入的文字应可直接拖动移动"
        )
        #expect(
            editor.directMoveTarget(at: PixelPoint(x: 200, y: 400), tolerance: 6) == nil,
            "文字工具点在未选中的聚光灯上应放行直接新建文字"
        )

        // 5. 跨类型选中标注：矩形工具下选中文字，selectedAnnotationMatchesTool 为 false，改色只改文字不污染矩形默认色
        editor.select(.rectangle)
        let originalShapeColor = editor.style.shapeColor
        let blue = AnnotationStyle.palette[3]
        #expect(originalShapeColor != blue)
        editor.selectAnnotation(id: textID)
        #expect(!editor.selectedAnnotationMatchesTool, "矩形工具下选中文字应标记为跨类型选中")
        editor.selectColor(blue)
        #expect(editor.style.shapeColor == originalShapeColor, "跨类型给文字改色不得污染矩形工具默认颜色")
        #expect(editor.style.textColor == blue, "跨类型给文字改色应同步到文字颜色槽")
        #expect(editor.selectedAnnotationColor == blue)

        // 6. 连续笔触工具（手绘 / 涂抹马赛克）：普通拖动不截胡，避免连笔误拖旧标注；按 forceMove 才移动
        editor.select(.freehand)
        #expect(
            editor.directMoveTarget(at: PixelPoint(x: 200, y: 100), tolerance: 6) == nil,
            "手绘工具普通拖动不应误拖已有边框"
        )
        #expect(
            editor.directMoveTarget(at: PixelPoint(x: 200, y: 100), tolerance: 6, forceMove: true)?.id == rectID,
            "手绘工具按住 ⌘/⌃ 仍可移动已有标注"
        )
    }
}
