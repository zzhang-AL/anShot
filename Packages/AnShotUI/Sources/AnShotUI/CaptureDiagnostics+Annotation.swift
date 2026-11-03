//
//  CaptureDiagnostics+Annotation.swift
//
//  CaptureDiagnostics 按主题拆分的一部分（同一类型的多文件 extension）。
//  纯机械拆分：函数体未改动。
//

#if DEBUG

import AnShotCapture
import AnShotCore
@preconcurrency import AVFoundation
import AppKit
import ImageIO
import Carbon.HIToolbox
@preconcurrency import ScreenCaptureKit
import Foundation
import os

extension CaptureDiagnostics {

    /// 标注渲染诊断：用真实事件在**合成底图**上画出全部标注，截图供人眼审查。
    ///
    /// 用途是视觉审查：标注落点、面板遮挡、马赛克对文字的实际遮挡效果。
    /// 数值断言由 AnShotCore 的单元测试负责，这里只产出能看的图。
    static func runAnnotationDiagnostic() async {
        let displayID = DisplayGeometry.mainDisplay()

        let controller = OverlayController(capturer: CapturerFactory.makeDefault())
        controller.present()
        try? await Task.sleep(for: .seconds(2))

        guard let window = controller.primaryOverlayWindow,
              let editor = controller.editorState else {
            logger.error("annotation diag: missing window or editor")
            controller.dismiss()
            return
        }

        applyDiagnosticBackdrop(to: controller, displayID: displayID)
        logFootprint(action: "annotation diag 会话开始")

        let selection = CGRect(x: 260, y: 180, width: 760, height: 460)
        _ = controller.setSelection(selection)
        try? await Task.sleep(for: .milliseconds(400))

        // 布局一致性检查必须在选区建立之后：没有选区就没有工具栏。
        if let overlayView = window.contentView as? OverlayView {
            assertPanelBelowBar(view: overlayView, editor: editor)
        }

        let scale = DisplayGeometry.scaleFactor(for: displayID)

        // 图形标注走真实事件路径：工具 → 拖拽 → 模型整条链路都被覆盖，
        // 直接往模型里塞标注则连命中判定都验证不到。
        editor.select(.rectangle)
        editor.selectColor(RGBAColor(r: 1.00, g: 0.23, b: 0.19, a: 1))
        editor.selectLineWidth(4)
        logAnnotationStep("before rectangle", editor: editor, view: window.contentView as? OverlayView)
        simulateDrag(in: window, from: CGPoint(x: 320, y: 240), to: CGPoint(x: 520, y: 360))
        logAnnotationStep("after rectangle", editor: editor, view: window.contentView as? OverlayView)

        editor.select(.arrow)
        editor.selectColor(RGBAColor(r: 0.00, g: 0.48, b: 1.00, a: 1))
        editor.selectLineWidth(6)
        simulateDrag(in: window, from: CGPoint(x: 640, y: 250), to: CGPoint(x: 790, y: 390))

        editor.select(.line)
        editor.selectColor(RGBAColor(r: 0.20, g: 0.78, b: 0.35, a: 1))
        editor.selectLineWidth(5)
        simulateDrag(in: window, from: CGPoint(x: 320, y: 420), to: CGPoint(x: 640, y: 470))

        // 文字走编辑器状态里的文字草稿——它就是输入框背后的那份状态，
        // 因此这里验证到的字号换算与基线换算和真实输入完全同路。
        editor.select(.text)
        editor.selectColor(RGBAColor(r: 0.90, g: 0.15, b: 0.15, a: 1))
        editor.selectFontSize(28)
        editor.beginTextEditing(at: PixelPoint(
            x: Double(330) * Double(scale),
            y: Double(540) * Double(scale)
        ))
        editor.updateTextDraft("文字标注 Sample 123")
        // 输入中先截一张：与提交后那张对比，
        // 就能看出输入框里的字与最终渲染出来的字是否同字号、同位置。
        try? await Task.sleep(for: .milliseconds(700))
        await captureOverlaySelfShot(round: 61)
        editor.commitTextDraft(scaleFactor: scale)

        // 涂抹马赛克：沿横向路径刷过底图上的文字与色块。
        editor.select(.mosaic)
        editor.selectMosaicMode(.brush)
        editor.selectMosaicBlockSize(12)
        editor.selectMosaicBrushDiameter(36)
        simulateDrag(in: window, from: CGPoint(x: 620, y: 300), to: CGPoint(x: 960, y: 330))
        logAnnotationStep("after brush mosaic", editor: editor, view: window.contentView as? OverlayView)

        // 再补一个框选马赛克，便于对比两种模式。
        editor.selectMosaicMode(.rectangle)
        simulateDrag(in: window, from: CGPoint(x: 320, y: 600), to: CGPoint(x: 560, y: 632))
        logAnnotationStep("after rect mosaic", editor: editor, view: window.contentView as? OverlayView)

        // 停在形状工具上而不是指针档位：这样截图里面板是展开的，
        // 面板的排版、间距、与尺寸标签是否打架都能一眼看到。
        editor.select(.rectangle)
        try? await Task.sleep(for: .milliseconds(500))

        logger.notice("""
            annotation diag: annotations=\(editor.annotations.count, privacy: .public) \
            canUndo=\(editor.canUndo, privacy: .public)
            """)

        logFootprint(action: "annotation diag 全部标注后")

        await captureOverlaySelfShot(round: 60)

        try? await Task.sleep(for: .seconds(1))
        controller.dismiss()

        // 会话结束后必须回落：标注、合成缓存、输入控件都应被释放。
        // 连测三次而不是一次：单次读数分不清「还在释放」与「停在某个水平」，
        // 而诊断本身做过的全屏捕获会留下大块可回收内存。
        for round in 1 ... 3 {
            try? await Task.sleep(for: .seconds(2))
            logFootprint(action: "annotation diag 关闭后 #\(round)")
        }
    }

    /// 标注**输入链路**诊断：走真实的 `NSEvent` 路径创建标注并验证撤销/重做。
    ///
    /// 与 `runAnnotationDiagnostic` 的分工：
    /// - 那个把模型直接画出来，验证的是**渲染**；
    /// - 这个验证的是**交互**（NSEvent → OverlayView → 编辑器状态 → 历史）。
    /// 两者缺一不可：只测渲染会漏掉事件分发与坐标换算的缺陷。
    static func runAnnotationInputDiagnostic() async {
        let displayID = DisplayGeometry.mainDisplay()

        let controller = OverlayController(capturer: CapturerFactory.makeDefault())
        controller.present()
        try? await Task.sleep(for: .seconds(2))

        guard let window = controller.primaryOverlayWindow,
              let editor = controller.editorState else {
            logger.error("annotation input diag: missing window or editor")
            controller.dismiss()
            return
        }

        applyDiagnosticBackdrop(to: controller, displayID: displayID)
        // 等一次布局再往下走。
        //
        // 底图与选区的状态传播要经过一次视图刷新，紧接着读工具栏/选区
        // 会读到一个自相矛盾的中间态（曾出现「标注建不出来 + 工具栏项取不到」
        // 而代码本身完全正确的情况）。这里显式等，不靠调用顺序碰运气。
        try? await Task.sleep(for: .milliseconds(400))

        // 失败时这一行能立刻区分是「底图没装上」还是「选区没生效」。
        if let probe = window.contentView as? OverlayView {
            logger.notice("""
                annotation diag setup: toolbarItems=\(probe.toolbarItemCenters().count, privacy: .public) \
                tool=\(editor.tool.rawValue, privacy: .public) \
                hasBackdrop=\(probe.hasBackdropForDiagnostics, privacy: .public)
                """)
        }

        let selection = CGRect(x: 300, y: 200, width: 600, height: 400)
        guard controller.setSelection(selection) else {
            logger.error("annotation input diag: setSelection 失败，没有可用窗口")
            controller.dismiss()
            return
        }
        try? await Task.sleep(for: .milliseconds(400))

        let scale = DisplayGeometry.scaleFactor(for: displayID)

        // ── 1）矩形工具：拖拽创建 ──
        editor.select(.rectangle)
        simulateDrag(
            in: window,
            from: CGPoint(x: 350, y: 250),
            to: CGPoint(x: 550, y: 400)
        )
        try? await Task.sleep(for: .milliseconds(300))

        let expected = CoordinateConversion.pixelRect(
            fromLogical: CGRect(x: 350, y: 250, width: 200, height: 150),
            scaleFactor: scale
        )

        var rectangleOK = false
        if editor.annotations.count == 1,
           case let .rectangle(rect, _, _, _) = editor.annotations[0].kind {
            rectangleOK = abs(rect.origin.x - expected.origin.x) < 1
                && abs(rect.origin.y - expected.origin.y) < 1
                && abs(rect.size.width - expected.size.width) < 1
                && abs(rect.size.height - expected.size.height) < 1

            logger.notice("""
                annotation input [rect]: measured=\(Int(rect.origin.x.rounded()), privacy: .public),\(Int(rect.origin.y.rounded()), privacy: .public) \
                \(Int(rect.size.width.rounded()), privacy: .public)x\(Int(rect.size.height.rounded()), privacy: .public) \
                expected=\(Int(expected.origin.x.rounded()), privacy: .public),\(Int(expected.origin.y.rounded()), privacy: .public) \
                \(Int(expected.size.width.rounded()), privacy: .public)x\(Int(expected.size.height.rounded()), privacy: .public) \
                -> \(rectangleOK ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        } else {
            logger.error("""
                annotation input [rect]: expected exactly 1 rectangle, \
                got \(editor.annotations.count, privacy: .public)
                """)
        }

        // ── 2）指针档位拖选区内仍是「移动选区」，且这次移动要能整体撤销 ──
        editor.select(.pointer)
        let selectionBeforeMove = controller.selection
        simulateDrag(
            in: window,
            from: CGPoint(x: 450, y: 350),
            to: CGPoint(x: 480, y: 380)
        )
        try? await Task.sleep(for: .milliseconds(300))
        let selectionAfterMove = controller.selection
        let moved = selectionAfterMove != selectionBeforeMove
        let annotationsUntouched = editor.annotations.count == 1

        // 撤销这一次移动：选区应当退回原处，标注保持不动。
        let undoMoveOK = editor.undo()
        let restoredSelection = controller.selection == selectionBeforeMove
        let annotationsStillThere = editor.annotations.count == 1
        let redoMoveOK = editor.redo()
        let reappliedSelection = controller.selection == selectionAfterMove

        let moveHistoryOK = moved
            && annotationsUntouched
            && undoMoveOK
            && restoredSelection
            && annotationsStillThere
            && redoMoveOK
            && reappliedSelection
        logger.notice("""
            annotation input [selection in history]: moved=\(moved, privacy: .public) \
            undo=\(undoMoveOK, privacy: .public)→restored=\(restoredSelection, privacy: .public) \
            redo=\(redoMoveOK, privacy: .public)→reapplied=\(reappliedSelection, privacy: .public) \
            annotations=\("\(annotationsUntouched)/\(annotationsStillThere)", privacy: .public) \
            -> \(moveHistoryOK ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // ── 3）撤销 / 重做标注 ──
        // 此刻历史是 [初始空状态, 矩形标注, 选区移动]，游标在末尾。
        // 因此要连撤两次才回到「没有标注」，这也顺带证明
        // 「移动选区」确实单独占了一格历史而不是被并入标注那一步。
        let undoMoveStep = editor.undo()
        let undoAnnotationStep = editor.undo()
        let afterUndo = editor.annotations.count
        let redoAnnotationStep = editor.redo()
        let redoMoveStep = editor.redo()
        let afterRedo = editor.annotations.count
        let historyOK = undoMoveStep && undoAnnotationStep && redoAnnotationStep && redoMoveStep
            && afterUndo == 0 && afterRedo == 1
        logger.notice("""
            annotation input [history]: twoUndo=\(undoMoveStep && undoAnnotationStep, privacy: .public)→count \(afterUndo, privacy: .public), \
            twoRedo=\(redoAnnotationStep && redoMoveStep, privacy: .public)→count \(afterRedo, privacy: .public) \
            -> \(historyOK ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // ── 4）单击（零尺寸拖拽）不应留下标注 ──
        editor.select(.line)
        let countBeforeTap = editor.annotations.count
        simulateDrag(
            in: window,
            from: CGPoint(x: 700, y: 300),
            to: CGPoint(x: 700, y: 300)
        )
        try? await Task.sleep(for: .milliseconds(300))
        let tapIgnored = editor.annotations.count == countBeforeTap
        logger.notice("""
            annotation input [tap]: count \(countBeforeTap, privacy: .public)→\(editor.annotations.count, privacy: .public) \
            -> \(tapIgnored ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // ── 5）工具栏点击：走事件路径，验证按钮命中与设置生效 ──
        await verifyToolbarClicks(window: window, editor: editor, controller: controller)

        // ── 6）独立几何预期 + 选区在刷新后存活 ──
        if let overlayView = window.contentView as? OverlayView {
            assertBarGeometryFromConstants(view: overlayView, editor: editor)
        }
        await verifySelectionSurvivesRefresh(
            window: window,
            controller: controller,
            editor: editor
        )

        try? await Task.sleep(for: .milliseconds(500))
        await captureOverlaySelfShot(round: 62)

        try? await Task.sleep(for: .seconds(1))
        controller.dismiss()
    }

    /// 用真实鼠标事件点击工具栏与二级面板，验证命中判定与设置生效。
    ///
    /// 直接调用 `editor.selectXxx` 只能证明方法可用，
    /// 证明不了「按钮画在哪里、点击落在哪里」——那正是 P4 出过问题的地方。
    private static func verifyToolbarClicks(
        window: NSWindow,
        editor: AnnotationEditorState,
        controller: OverlayController
    ) async {
        guard let view = window.contentView as? OverlayView else { return }

        // 从指针档位出发：此时形状面板是收起的，
        // 点「形状」才是在**展开**面板，而不是把已展开的面板收起
        // （点当前分组 = 收起/展开，这是设计行为，诊断不能假设它总是展开）。
        editor.select(.pointer)
        try? await Task.sleep(for: .milliseconds(250))

        // 工具栏用例期间停用识别：识别会随鼠标移动改变选区，
        // 工具栏跟着移动，之前读到的坐标就失效了。
        view.isDetectionPausedForDiagnostics = true
        defer { view.isDetectionPausedForDiagnostics = false }

        let bar = view.toolbarItemCenters()
        guard let shapeFamily = bar[.family(.shape)],
              let textFamily = bar[.family(.text)] else {
            logger.error("toolbar clicks: 主栏未提供可点击项，工具栏可能未显示")
            return
        }
        let shapePanelHiddenBefore = bar[.tool(.arrow)] == nil

        // 布局一致性：面板项必须整体位于主栏项之下。
        //
        // 这一条针对一个真实缺陷：首版绘制面板时漏了纵向偏移，
        // 于是面板按钮画在主栏位置上、可点击区域却在下方，
        // 用户看到的和点得到的完全对不上。而当时的诊断只验证「点击命中」，
        // 用命中坐标点命中坐标，自证了那个 bug —— 所以这里改为验证
        // 「面板与主栏在几何上不重叠」。
        assertPanelBelowBar(view: view, editor: editor)

        // 点「形状」分组：应切到形状工具并展开形状面板。
        synthesizeClick(in: window, at: shapeFamily)
        try? await Task.sleep(for: .milliseconds(300))
        let shapeSelected = editor.tool.family == .shape

        let panel = view.toolbarItemCenters()
        guard let redColor = AnnotationStyle.palette.first,
              let arrowTool = panel[.tool(.arrow)],
              let redSwatchPoint = panel[.color(redColor)] else {
            logger.error("""
                toolbar clicks: 形状面板未展开 \
                tool=\(editor.tool.rawValue, privacy: .public) \
                hiddenBefore=\(shapePanelHiddenBefore, privacy: .public)
                """)
            return
        }

        // 点二级面板里的箭头工具。
        synthesizeClick(in: window, at: arrowTool)
        try? await Task.sleep(for: .milliseconds(250))
        let arrowSelected = editor.tool == .arrow

        // 点二级面板里的颜色。
        synthesizeClick(in: window, at: redSwatchPoint)
        try? await Task.sleep(for: .milliseconds(250))
        let colorApplied = editor.style.shapeColor == redColor
        let colorKeptArrow = editor.tool == .arrow

        // 切到文字分组：面板应换成文字面板（形状项消失、字号项出现）。
        synthesizeClick(in: window, at: textFamily)
        try? await Task.sleep(for: .milliseconds(300))
        let textSelected = editor.tool == .text
        let textPanel = view.toolbarItemCenters()
        let panelSwitched = textPanel[.tool(.arrow)] == nil
            && !AnnotationStyle.fontSizes.isEmpty
            && textPanel[.fontSize(AnnotationStyle.fontSizes[0])] != nil

        // 面板里的完整取色器入口：从工具面板也应能进取色器。
        // 注意这里必须重新取一次坐标——上面切换过工具，
        // 旧坐标对应的面板已经不存在了（曾因此得到假失败）。
        var pickerOpened = false
        if let picker = view.toolbarItemCenters()[.colorPicker] {
            view.dismissColorPanel()
            try? await Task.sleep(for: .milliseconds(200))
            synthesizeClick(in: window, at: picker)
            try? await Task.sleep(for: .milliseconds(700))
            pickerOpened = view.colorPickerWindowForDiagnostics != nil
            view.dismissColorPanel()
            try? await Task.sleep(for: .milliseconds(200))
        }

        // 不取色的工具下，颜色入口应当**连位置都不存在**；
        // 取色的工具下应当回来。
        editor.select(.pointer)
        try? await Task.sleep(for: .milliseconds(300))
        let pointerHasNoColor = view.toolbarItemCenters()[.colorButton] == nil

        editor.select(.mosaic)
        try? await Task.sleep(for: .milliseconds(300))
        let mosaicHasNoColor = view.toolbarItemCenters()[.colorButton] == nil

        editor.select(.rectangle)
        try? await Task.sleep(for: .milliseconds(300))
        let shapeHasColor = view.toolbarItemCenters()[.colorButton] != nil

        editor.select(.arrow)
        try? await Task.sleep(for: .milliseconds(300))
        let arrowHasColor = view.toolbarItemCenters()[.colorButton] != nil

        let colorEntryOK = pointerHasNoColor && mosaicHasNoColor
            && shapeHasColor && arrowHasColor
        logger.notice("""
            color entry per tool: 指针无=\(pointerHasNoColor, privacy: .public) \
            马赛克无=\(mosaicHasNoColor, privacy: .public) \
            矩形有=\(shapeHasColor, privacy: .public) \
            箭头有=\(arrowHasColor, privacy: .public) \
            -> \(colorEntryOK ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        let ok = shapePanelHiddenBefore
            && shapeSelected
            && arrowSelected
            && colorApplied
            && colorKeptArrow
            && textSelected
            && panelSwitched
            && pickerOpened
        logger.notice("""
            toolbar clicks: hiddenBefore=\(shapePanelHiddenBefore, privacy: .public) \
            family=\(shapeSelected, privacy: .public) \
            arrow=\(arrowSelected, privacy: .public) \
            color=\(colorApplied, privacy: .public) \
            toolKept=\(colorKeptArrow, privacy: .public) \
            textFamily=\(textSelected, privacy: .public) \
            panelSwitched=\(panelSwitched, privacy: .public) \
            panelColorPicker=\(pickerOpened, privacy: .public) \
            -> \(ok ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // 收尾：回到指针档位，避免后续截图里面板压着标注。
        editor.select(.pointer)
    }

    /// 取色器诊断：验证**自绘**取色器真的上屏、可交互、能回写。
    ///
    /// 为什么验证方式必须是「窗口服务器的在屏列表」而不是视图自述的状态：
    /// 之前用系统 `NSColorPanel` 时，`isVisible` 一直返回 true，
    /// 但窗口因 `hidesOnDeactivate` 早已被 order out——查自述状态永远发现不了。
    static func runColorPanelDiagnostic() async {
        let displayID = DisplayGeometry.mainDisplay()

        let controller = OverlayController(capturer: CapturerFactory.makeDefault())
        controller.present()
        try? await Task.sleep(for: .seconds(2))

        guard let window = controller.primaryOverlayWindow,
              let editor = controller.editorState,
              let view = window.contentView as? OverlayView else {
            logger.error("color picker diag: missing window or editor")
            controller.dismiss()
            return
        }

        applyDiagnosticBackdrop(to: controller, displayID: displayID)
        _ = controller.setSelection(CGRect(x: 300, y: 200, width: 700, height: 420))
        try? await Task.sleep(for: .milliseconds(500))

        // 取色工具才有颜色入口。
        editor.select(.rectangle)
        try? await Task.sleep(for: .milliseconds(300))

        guard let colorButton = view.toolbarItemCenters()[.colorButton] else {
            logger.error("color picker diag: 取不到颜色入口位置")
            controller.dismiss()
            return
        }

        synthesizeClick(in: window, at: colorButton)
        try? await Task.sleep(for: .milliseconds(800))

        guard let panel = view.colorPickerWindowForDiagnostics,
              let picker = view.colorPickerForDiagnostics else {
            logger.error("color picker diag: 点击后未创建取色器面板")
            controller.dismiss()
            return
        }

        // 第一响应者应当是取色器本身，不是 Hex 输入框——
        // 否则输入框会进入编辑态，field editor 用系统浅色样式覆盖深色面板。
        let focusIsPicker = panel.firstResponder === picker
        let editingHex = panel.firstResponder is NSText
        logger.notice("""
            color picker focus: firstResponder=\(String(describing: type(of: panel.firstResponder)), privacy: .public) \
            焦点在取色器=\(focusIsPicker, privacy: .public) 在输入框=\(editingHex, privacy: .public)
            """)

        // 1) 上屏：以窗口服务器为准。
        let panelNumber = panel.windowNumber
        let onScreen = windowNumbers(with: [.optionOnScreenOnly])
        let inOnScreen = onScreen.contains(panelNumber)
        let panelIndex = onScreen.firstIndex(of: panelNumber)
        let overlayIndex = onScreen.firstIndex(of: window.windowNumber)
        let inFront = (panelIndex ?? Int.max) < (overlayIndex ?? Int.max)

        // 2) 交互：直接驱动取色器内部的换算路径。
        //    拖动取色区（饱和度/明度）与拖色相条走的是两套不同分支，
        //    这里都走一遍，确认颜色确实按预期变化。
        let beforeDrag = editor.style.shapeColor
        let svBox = CGRect(x: 12, y: 12, width: 150, height: 110)
        synthesizeDrag(
            in: panel,
            on: picker,
            from: CGPoint(x: svBox.midX, y: svBox.midY),
            to: CGPoint(x: svBox.maxX - 6, y: svBox.minY + 6)
        )
        try? await Task.sleep(for: .milliseconds(400))
        let afterSV = editor.style.shapeColor

        let hueBar = CGRect(x: svBox.maxX + 8, y: svBox.minY, width: 14, height: svBox.height)
        synthesizeDrag(
            in: panel,
            on: picker,
            from: CGPoint(x: hueBar.midX, y: hueBar.minY + 4),
            to: CGPoint(x: hueBar.midX, y: hueBar.midY)
        )
        try? await Task.sleep(for: .milliseconds(400))
        let afterHue = editor.style.shapeColor

        let svWorked = afterSV != beforeDrag
        let hueWorked = afterHue != afterSV

        logger.notice("""
            color picker diag: 上屏=\(inOnScreen, privacy: .public) \
            在覆盖层前=\(inFront, privacy: .public) \
            取色区拖动生效=\(svWorked, privacy: .public) \
            色相条拖动生效=\(hueWorked, privacy: .public) \
            -> \(inOnScreen && inFront && svWorked && hueWorked ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // 3) 十六进制输入路径（换算逻辑另有 AnShotCore 单测覆盖）。
        let hexOK = RGBAColor(hexString: "3366CC") != nil
        logger.notice("color picker diag: hex 解析可用=\(hexOK, privacy: .public)")

        try? await Task.sleep(for: .milliseconds(400))
        await captureOverlaySelfShot(round: 64)

        controller.dismiss()
        try? await Task.sleep(for: .milliseconds(600))

        // 4) 会话结束必须释放。
        let released = view.colorPickerWindowForDiagnostics == nil
        logger.notice("color picker diag: 会话结束已释放=\(released, privacy: .public)")
        logFootprint(action: "color picker 关闭后")
    }

    /// 导出诊断：验证「状态 → 剪贴板 / 文件」这条链路。
    ///
    /// 覆盖三件事：
    /// 1. 导出图的尺寸与内容来自**与显示同一条**渲染路径；
    /// 2. 剪贴板里放的东西能读回来、且与合成结果逐像素一致；
    /// 3. **导出前的收尾**：正在输入的文字按提交处理，不被静默丢弃
    ///    （`model.md` §8 的硬性要求）。
    ///
    /// 保存面板本身不在这里验证：`NSSavePanel` 需要真实点击，
    /// 会话层留给人工确认；这里验证的是面板之后的写入路径。
    static func runExportDiagnostic() async {
        let displayID = DisplayGeometry.mainDisplay()
        let controller = OverlayController(capturer: CapturerFactory.makeDefault())
        controller.present()
        try? await Task.sleep(for: .seconds(2))

        guard let window = controller.primaryOverlayWindow,
              let editor = controller.editorState,
              let view = window.contentView as? OverlayView else {
            logger.error("export diag: missing window or editor")
            controller.dismiss()
            return
        }

        applyDiagnosticBackdrop(to: controller, displayID: displayID)
        try? await Task.sleep(for: .milliseconds(400))

        let selection = CGRect(x: 300, y: 200, width: 400, height: 300)
        guard controller.setSelection(selection) else {
            logger.error("export diag: setSelection 失败")
            controller.dismiss()
            return
        }
        try? await Task.sleep(for: .milliseconds(400))

        let scale = DisplayGeometry.scaleFactor(for: displayID)

        // ── 1）画一个标注 ──
        editor.select(.rectangle)
        simulateDrag(
            in: window,
            from: CGPoint(x: 340, y: 240),
            to: CGPoint(x: 540, y: 380)
        )
        try? await Task.sleep(for: .milliseconds(300))

        // ── 2）工具栏是否提供了导出按钮 ──
        let centers = view.toolbarItemCenters()
        let hasCopy = centers[.copy] != nil
        let hasSave = centers[.save] != nil

        // ── 3）导出前收尾：文字草稿必须被提交 ──
        // 造一个正在输入的文字草稿，然后走导出前的收尾逻辑。
        let beforeText = editor.annotations.count
        editor.select(.text)
        editor.beginTextEditing(at: PixelPoint(x: 700, y: 500))
        editor.updateTextDraft("导出前应提交")
        SessionExporter.finishEditing(editor, scaleFactor: scale)
        try? await Task.sleep(for: .milliseconds(200))
        let afterText = editor.annotations.count
        let textCommitted = afterText == beforeText + 1 && !editor.isEditingText

        // ── 4）合成并核对尺寸 ──
        guard let backdrop = view.backdropForDiagnostics else {
            logger.error("export diag: 底图缺失")
            controller.dismiss()
            return
        }

        let selectionPixel = CoordinateConversion.pixelRect(
            fromLogical: selection,
            scaleFactor: scale
        )
        let expectedWidth = Int(selectionPixel.size.width.rounded())
        let expectedHeight = Int(selectionPixel.size.height.rounded())

        guard let composed = SessionExporter.compose(
            editor: editor,
            backdrop: backdrop,
            scaleFactor: scale
        ) else {
            logger.error("export diag: 合成失败")
            controller.dismiss()
            return
        }

        let sizeOK = composed.width == expectedWidth && composed.height == expectedHeight
        logger.notice("""
            export size: measured=\(composed.width, privacy: .public)x\(composed.height, privacy: .public) \
            expected=\(expectedWidth, privacy: .public)x\(expectedHeight, privacy: .public) \
            -> \(sizeOK ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // ── 5）剪贴板往返 ──
        let copied = SessionExporter.copyToPasteboard(composed)
        var pasteboardMatches = false
        var pasteboardSize = "—"
        if copied,
           let data = NSPasteboard.general.data(forType: .png),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            pasteboardSize = "\(decoded.width)x\(decoded.height)"
            pasteboardMatches = pixelEqual(composed, decoded)
        }
        logger.notice("""
            export pasteboard: 写入=\(copied, privacy: .public) \
            读回=\(pasteboardSize, privacy: .public) \
            逐像素一致=\(pasteboardMatches, privacy: .public) \
            -> \(copied && pasteboardMatches ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // ── 6）落盘往返（绕开需要点击的保存面板，只验写入路径）──
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-export-diag-\(UUID().uuidString).png")
        var fileOK = false
        var fileSize = "—"
        do {
            try SessionExporter.save(composed, to: url)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                fileSize = "\(decoded.width)x\(decoded.height)"
                fileOK = decoded.width == composed.width && decoded.height == composed.height
            }
            try? FileManager.default.removeItem(at: url)
        } catch {
            logger.error("export diag: 写文件失败 \(error.localizedDescription, privacy: .public)")
        }
        logger.notice("""
            export file: 尺寸=\(fileSize, privacy: .public) \
            -> \(fileOK ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // ── 7）工具栏按钮走真实事件路径 ──
        var toolbarCopyWorked = false
        if let copyPoint = centers[.copy] {
            NSPasteboard.general.clearContents()
            synthesizeClick(in: window, at: copyPoint)
            try? await Task.sleep(for: .milliseconds(900))
            // 控制器收到拷贝请求后会结束会话，所以这里只验证剪贴板被写入。
            toolbarCopyWorked = NSPasteboard.general.data(forType: .png) != nil
        }
        logger.notice("""
            export toolbar: 拷贝按钮存在=\(hasCopy, privacy: .public) \
            保存按钮存在=\(hasSave, privacy: .public) \
            点击后剪贴板有内容=\(toolbarCopyWorked, privacy: .public) \
            -> \(hasCopy && hasSave ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        logger.notice("""
            export finishEditing: 导出前提交文字草稿=\(textCommitted, privacy: .public) \
            \("(标注数 \(beforeText) → \(afterText))", privacy: .public) \
            -> \(textCommitted ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // ── 8）键盘路径 ──
        //
        // 放在最后：两类键都会结束会话，跑完就不能再做别的验证了。
        //
        // 先单独查「first responder 是不是覆盖层」——
        // 合成事件不管焦点在哪都能送到，所以它能通过并不代表真实键盘能到达；
        // 而真实键盘要生效，keyDown 必须落在覆盖层视图上。
        let responderIsOverlay = window.firstResponder === view
        let responderName = String(describing: type(of: window.firstResponder ?? window))
        logger.notice("""
            export keyboard focus: firstResponder=\(responderName, privacy: .public) \
            是覆盖层=\(responderIsOverlay, privacy: .public) \
            -> \(responderIsOverlay ? "MATCH" : "MISMATCH（真实键盘事件到不了覆盖层）", privacy: .public)
            """)

        // 两类键都会结束会话，因此**各自需要一个独立会话**。
        // 一开始把回车放在工具栏点击之后测，结果测的是一个已经关闭的窗口，
        // 得到「回车失效」的错误结论——那种假失败比不测更误导人。
        func keyboardCopyWorks(
            keyCode: UInt16,
            flags: NSEvent.ModifierFlags,
            characters: String
        ) async -> Bool {
            controller.present()
            try? await Task.sleep(for: .seconds(2))

            guard let sessionWindow = controller.primaryOverlayWindow,
                  let sessionView = sessionWindow.contentView as? OverlayView else {
                return false
            }

            applyDiagnosticBackdrop(to: controller, displayID: displayID)
            try? await Task.sleep(for: .milliseconds(400))
            _ = controller.setSelection(selection)
            try? await Task.sleep(for: .milliseconds(400))

            // 焦点必须在覆盖层：真实键盘事件要到达 keyDown 以此为前提。
            let focusOK = sessionWindow.firstResponder === sessionView

            NSPasteboard.general.clearContents()
            synthesizeKey(
                in: sessionWindow,
                keyCode: keyCode,
                flags: flags,
                characters: characters
            )
            try? await Task.sleep(for: .milliseconds(900))

            let copied = NSPasteboard.general.data(forType: .png) != nil
            return focusOK && copied
        }

        let enterCopied = await keyboardCopyWorks(
            keyCode: 36,
            flags: [],
            characters: "\r"
        )
        // ⌘C 与回车走的是 keyDown 里两个不同分支，都要覆盖。
        let commandCCopied = await keyboardCopyWorks(
            keyCode: 8,
            flags: .command,
            characters: "c"
        )

        logger.notice("""
            export keyboard: 回车拷到剪贴板=\(enterCopied, privacy: .public) \
            ⌘C拷到剪贴板=\(commandCCopied, privacy: .public) \
            -> \(enterCopied && commandCCopied ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        try? await Task.sleep(for: .seconds(1))
        controller.dismiss()
    }

    /// 内存诊断：跑完 `plan.md` §5 的四项内存验收。
    ///
    /// 为什么必须实测而不是「按设计应该够省」：内存是**唯一**会在长期使用中
    /// 悄悄恶化、并且用户最先感知到的指标。截图工具每次会话都要持有
    /// 一整屏位图，一次没释放干净就停留在几十 MB。
    ///
    /// 四项分别是：
    /// 1. **空闲**：冷启动静置到稳定，目标 ≤ 60MB；
    /// 2. **会话峰值**：底图 + 标注 + 合成 + 导出同时存在时的最高点；
    /// 3. **释放正确性**：会话结束回落，允许 ± 5MB 误差；
    /// 4. **无泄漏**：连续 100 次会话后不出现单调增长。
    ///
    /// 第 4 项是真正能抓住泄漏的一条——单次会话看起来回落正常，
    /// 但每次留下一点点，一百次之后就非常明显。
    static func runMemoryDiagnostic() async {
        let displayID = DisplayGeometry.mainDisplay()
        let selection = CGRect(x: 300, y: 200, width: 400, height: 300)

        // ── 1）冷启动空闲 ──
        logFootprint(action: "冷启动 立即")
        for step in 1...2 {
            try? await Task.sleep(for: .seconds(15))
            logFootprint(action: "冷启动空闲 \(step * 15)s")
        }

        // ── 2）单次会话：逐阶段看增长与回落 ──
        let controller = OverlayController(capturer: CapturerFactory.makeDefault())
        controller.present()
        try? await Task.sleep(for: .seconds(2))
        logFootprint(action: "会话 覆盖层出现后（含底图）")

        guard let window = controller.primaryOverlayWindow,
              let editor = controller.editorState,
              let view = window.contentView as? OverlayView,
              let backdrop = view.backdropForDiagnostics else {
            logger.error("memory diag: missing window or backdrop")
            controller.dismiss()
            return
        }

        applyDiagnosticBackdrop(to: controller, displayID: displayID)
        try? await Task.sleep(for: .milliseconds(400))
        _ = controller.setSelection(selection)
        try? await Task.sleep(for: .milliseconds(400))

        // 六种标注各来一个：这是单个会话能造出的最大标注负载。
        editor.select(.rectangle)
        simulateDrag(in: window, from: CGPoint(x: 320, y: 220), to: CGPoint(x: 420, y: 300))
        editor.select(.line)
        simulateDrag(in: window, from: CGPoint(x: 430, y: 220), to: CGPoint(x: 520, y: 300))
        editor.select(.arrow)
        simulateDrag(in: window, from: CGPoint(x: 530, y: 220), to: CGPoint(x: 620, y: 300))
        editor.select(.mosaic)
        simulateDrag(in: window, from: CGPoint(x: 320, y: 330), to: CGPoint(x: 420, y: 400))
        editor.select(.mosaic)
        editor.selectMosaicMode(.brush)
        simulateDrag(in: window, from: CGPoint(x: 430, y: 340), to: CGPoint(x: 560, y: 400))
        editor.select(.text)
        editor.beginTextEditing(at: PixelPoint(x: 640, y: 460))
        editor.updateTextDraft("内存诊断")
        _ = editor.commitTextDraft(scaleFactor: view.backdropScaleForDiagnostics)
        try? await Task.sleep(for: .milliseconds(500))

        let annotationCount = editor.annotations.count
        logger.notice("memory diag: 标注数=\(annotationCount, privacy: .public)")
        logFootprint(action: "会话 六种标注后")

        // 合成 + 导出：这是会话内的内存最高点。
        let scale = DisplayGeometry.scaleFactor(for: displayID)

        // 合成耗时：热键→出图链路上除了覆盖层出现（已有 overlay session timing）
        // 之外，唯一由本应用控制的一段。用户在框选后按回车，等的是这一段。
        let composeStart = ContinuousClock.now
        let composed = SessionExporter.compose(
            editor: editor,
            backdrop: backdrop,
            scaleFactor: scale
        )
        let composeMs = milliseconds(composeStart, ContinuousClock.now)
        logFootprint(action: "会话 合成后")
        var encodeMs = "—"
        if let composed {
            let encodeStart = ContinuousClock.now
            _ = SessionExporter.copyToPasteboard(composed)
            encodeMs = milliseconds(encodeStart, ContinuousClock.now)
            logFootprint(action: "会话 拷贝到剪贴板后")
        }

        logger.notice("""
            memory diag timing: 合成=\(composeMs, privacy: .public)ms \
            PNG编码+剪贴板=\(encodeMs, privacy: .public)ms \
            （覆盖层出现见 overlay session timing 的 total；两者之和即 \
            「框选完成后按回车到图进剪贴板」的耗时）
            """)

        controller.dismiss()
        for step in 1...3 {
            try? await Task.sleep(for: .seconds(2))
            logFootprint(action: "会话关闭后 #\(step)")
        }

        // ── 3）连续 100 次会话：看是否存在单调增长 ──
        //
        // 每次都完整走一遍「建窗 → 抓底图 → 释放」，只采样不回读，
        // 因为要测的是**每次会话留下的残渣**，不是单次耗时。
        let rounds = 100
        let sampleEvery = 10
        for round in 1...rounds {
            let loopController = OverlayController(capturer: CapturerFactory.makeDefault())
            loopController.present()
            try? await Task.sleep(for: .milliseconds(400))
            if let loopWindow = loopController.primaryOverlayWindow,
               let loopView = loopWindow.contentView as? OverlayView,
               let loopEditor = loopController.editorState {
                _ = loopController.setSelection(selection)
                loopEditor.select(.rectangle)
                simulateDrag(
                    in: loopWindow,
                    from: CGPoint(x: 320, y: 220),
                    to: CGPoint(x: 420, y: 300)
                )
                _ = loopView
            }
            loopController.dismiss()
            try? await Task.sleep(for: .milliseconds(200))

            if round % sampleEvery == 0 {
                logFootprint(action: "连续会话 #\(round)")
            }
        }

        logger.notice("memory diag: 完成（\(rounds, privacy: .public) 次会话）")
    }

    // MARK: - 设置诊断

    /// 生成单色底图，用于受控背景下的外观审查。
    /// 记录一步标注创建的进度，用于定位「哪一步没落进模型」。
    private static func logAnnotationStep(
        _ step: String,
        editor: AnnotationEditorState,
        view: OverlayView?
    ) {
        let kinds = editor.annotations.map { $0.kind.typeName }.joined(separator: ",")
        logger.notice("""
            annotation diag step [\(step, privacy: .public)]: \
            count=\(editor.annotations.count, privacy: .public) \
            tool=\(editor.tool.rawValue, privacy: .public) \
            hasDraft=\(editor.hasDraft, privacy: .public) \
            selection=\(view?.hasSelection == true, privacy: .public) \
            kinds=[\(kinds, privacy: .public)]
            """)
    }

    /// 光标动画器：诊断期间的**可控屏幕变化源**。
    ///
    /// 存在的理由：`SCStream` 只在内容变化时产帧。静止画面下的会话虽然仍会收到
    /// `idle` 状态帧，但有效帧数不会增长，使「暂停期间不增长」「恢复后增长」
    /// 这类断言无从判定。录制的本质是录「变化」。
    ///
    /// 用 `DispatchSourceTimer` 而不是 `Task`：非结构化 `Task` 会继承创建处的
    /// actor 隔离（这里是 `@MainActor`），其执行依赖主 actor 的调度，行为不确定。
    final class CursorAnimator: @unchecked Sendable {

        private let lock = NSLock()
        private var timer: DispatchSourceTimer?
        private var tick = 0
        private let originalLocation: CGPoint?

        init() {
            originalLocation = CGEvent(source: nil)?.location
        }

        func start(displayID: CGDirectDisplayID) {
            let bounds = CGDisplayBounds(displayID)
            lock.withLock {
                guard timer == nil else { return }
                let source = DispatchSource.makeTimerSource(queue: .main)
                source.schedule(deadline: .now(), repeating: .milliseconds(60), leeway: .milliseconds(10))
                source.setEventHandler { [weak self] in
                    guard let self else { return }
                    let step = self.advance()
                    let point = CGPoint(
                        x: bounds.minX + bounds.width * 0.30 + CGFloat(step % 12) * (bounds.width * 0.03),
                        y: bounds.minY + bounds.height * 0.30 + CGFloat((step / 12) % 10) * (bounds.height * 0.02)
                    )
                    CGWarpMouseCursorPosition(point)
                }
                source.resume()
                timer = source
            }
        }

        func stop() {
            let running: DispatchSourceTimer? = lock.withLock {
                let source = timer
                timer = nil
                return source
            }
            running?.cancel()
            if let originalLocation {
                CGWarpMouseCursorPosition(originalLocation)
            }
        }

        private func advance() -> Int {
            lock.withLock {
                tick += 1
                return tick
            }
        }
    }

    /// 包装捕获器，记录最后一次抓取结果。
    ///
    /// 用途：覆盖层自拍只能证明「画出了东西」，无法证明方向正确。
    /// 拿到原始底图后即可逐像素比对自拍图 × 1/0.55，
    /// 从而判定 flipped 视图里的坐标翻转是否搞反了。
    final class RecordingCapturer: ScreenCapturing, @unchecked Sendable {
        private let wrapped: any ScreenCapturing
        // 用 OSAllocatedUnfairLock 而非 NSLock：后者在异步上下文中不可用。
        private let storage = OSAllocatedUnfairLock<CGImage?>(initialState: nil)

        init(wrapping: any ScreenCapturing) {
            self.wrapped = wrapping
        }

        var lastImage: CGImage? {
            storage.withLock { $0 }
        }

        func captureFrame(scope: CaptureScope) async throws -> CapturedFrame {
            let frame = try await wrapped.captureFrame(scope: scope)
            storage.withLock { $0 = frame.image }
            return frame
        }
    }
}

#endif
