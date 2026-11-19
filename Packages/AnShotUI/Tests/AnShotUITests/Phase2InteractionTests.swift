//
//  Phase2InteractionTests.swift
//  AnShotUITests
//
//  Phase 2 覆盖层交互、绘制优先、滚轮调参、开放样式与气泡工具栏契约单测。
//

import AnShotCore
import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import AnShotUI

@MainActor
@Suite("Phase 2 · 覆盖层手感、绘制优先与气泡工具栏")
struct Phase2InteractionTests {

    private static func makeBackdrop(width: Int = 400, height: Int = 300) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func makeKeyEvent(
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test("覆盖层候选态隐藏工具栏，确认后显示，且角热区收窄至 12pt")
    func silentInitialFrameHidesToolbarUntilConfirmed() {
        #expect(SelectionDecoration.standard.cornerHitRadius == 12)

        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), displayID: 1)
        let editor = AnnotationEditorState(selection: nil)
        view.editorState = editor
        view.backdrop = Self.makeBackdrop()

        // 1. 静默首帧（selection == nil）：工具栏隐藏。
        view.refreshToolbar()
        #expect(view.toolbarFrame == .zero)

        // 2. 悬停产生未确认候选框：工具栏仍隐藏。
        view.setSelection(CGRect(x: 40, y: 40, width: 160, height: 120))
        view.refreshToolbar()
        #expect(view.toolbarFrame == .zero)

        // 3. 确认选区后：工具栏立刻出现。
        editor.confirmSelection()
        view.refreshToolbar()
        #expect(view.toolbarFrame.width > 0 && view.toolbarFrame.height > 0)

        // 4. 窗体捕获模式下隐藏工具栏。
        view.isWindowPickerMode = true
        view.refreshToolbar()
        #expect(view.toolbarFrame == .zero)
    }

    @Test("快捷键支持 ⌥+方向键微调选区宽高且消除 C 键取色冲突")
    func optionArrowResizesSelectionAndCKeyHasNoToolConflict() {
        // 任何标注工具快捷键均不得占用 C（保留给 C/⇧C 取色）。
        #expect(!AnnotationTool.allCases.contains(where: { $0.keyCharacter == "c" }))
        #expect(AnnotationTool.curvedArrow.keyCharacter == "u")
        #expect(AnnotationTool.spotlight.keyCharacter == "s")

        let right1 = Self.makeKeyEvent(keyCode: 124, modifiers: [.option])
        let down5 = Self.makeKeyEvent(keyCode: 125, modifiers: [.option, .shift])
        #expect(OverlayKeyCommand.parse(right1) == .resizeSelection(dw: 1, dh: 0))
        #expect(OverlayKeyCommand.parse(down5) == .resizeSelection(dw: 0, dh: 5))
    }

    @Test("已有标注且开启防误关保护时，首次 Esc 仅轻提示不退出，二次 Esc 才退出")
    func doubleEscapeGuardProtectsAnnotations() {
        let suiteName = "com.anshot.tests.phase2.esc.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(store: defaults)
        #expect(settings.confirmCancelWithAnnotations)

        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), displayID: 1)
        let editor = AnnotationEditorState(
            selection: PixelRect(origin: .zero, size: PixelSize(width: 400, height: 300))
        )
        editor.confirmSelection()
        view.editorState = editor
        view.appSettings = settings

        var cancelCount = 0
        view.onCancel = { cancelCount += 1 }

        // 无标注时按一次 Esc 直接退出。
        view.requestCancel(source: .escapeKey)
        #expect(cancelCount == 1)

        // 画一条矩形后首次按 Esc 被保护拦截，紧接着第二次按 Esc 放行退出。
        editor.select(.rectangle)
        editor.beginDraft(at: PixelPoint(x: 20, y: 20))
        editor.updateDraft(to: PixelPoint(x: 120, y: 90))
        #expect(editor.commitDraft())

        view.requestCancel(source: .escapeKey)
        #expect(cancelCount == 1, "首次 Esc 应仅提示，不退出会话")

        view.requestCancel(source: .escapeKey)
        #expect(cancelCount == 2, "1.8 秒内第二次 Esc 应确认退出")
    }

    @Test("绘制优先自动选中、滚轮调参、开放填充/圆角/文字粗斜体/字体族与改序号")
    func drawFirstAutoSelectionScrollWheelAndOpenStyles() {
        let editor = AnnotationEditorState(
            selection: PixelRect(origin: .zero, size: PixelSize(width: 600, height: 400))
        )
        editor.confirmSelection()

        // 1. 矩形开启填充并绘制：提交后自动选中，无需切回指针即可滚轮加粗、拖圆角手柄。
        editor.select(.rectangle)
        editor.toggleShapeFilled()
        #expect(editor.style.shapeFilled)
        editor.beginDraft(at: PixelPoint(x: 40, y: 40))
        editor.updateDraft(to: PixelPoint(x: 200, y: 160))
        #expect(editor.commitDraft())
        #expect(editor.selectedAnnotationID == editor.annotations.last?.id)
        #expect(editor.selectedAnnotationIsFilled)

        let initialWidth = editor.style.shapeLineWidth
        #expect(editor.adjustParameterByScrollWheel(delta: 1, scaleFactor: 1))
        #expect(editor.style.shapeLineWidth == initialWidth + 1)
        if case let .rectangle(_, stroke, fill, _) = editor.selectedAnnotation?.kind {
            #expect(stroke.width == initialWidth + 1)
            #expect(fill != nil)
        } else {
            Issue.record("选中标注应为矩形")
        }

        // 拖动圆角手柄更新圆角半径。
        editor.updateSelectedControlHandle(.cornerRadius, to: PixelPoint(x: 70, y: 54))
        if case let .rectangle(_, _, _, cornerRadius) = editor.selectedAnnotation?.kind {
            #expect(cornerRadius == 16)
        } else {
            Issue.record("应保持矩形类型")
        }

        // 2. 聚光灯创建与滚轮调整压暗度。
        editor.select(.spotlight)
        editor.beginDraft(at: PixelPoint(x: 60, y: 60))
        editor.updateDraft(to: PixelPoint(x: 180, y: 140))
        #expect(editor.commitDraft())
        #expect(editor.selectedAnnotationIsSpotlight)
        let beforeDim = editor.selectedAnnotationSpotlightDimOpacity ?? 0
        #expect(editor.adjustParameterByScrollWheel(delta: 1, scaleFactor: 1))
        #expect((editor.selectedAnnotationSpotlightDimOpacity ?? 0) > beforeDim)

        // 3. 文字粗体/斜体/字体族并提交后自动选中。
        editor.select(.text)
        editor.toggleTextBold()
        editor.toggleTextItalic()
        editor.cycleTextFontFamily()
        editor.beginTextEditing(at: PixelPoint(x: 80, y: 80))
        editor.updateTextDraft("重点标注")
        #expect(editor.commitTextDraft(scaleFactor: 2))
        #expect(editor.selectedAnnotationIsBold)
        #expect(editor.selectedAnnotationIsItalic)
        #expect(editor.selectedAnnotationFontFamily == "Menlo")

        // 4. 编号标注双击修改数字并推进计数器防撞号。
        editor.select(.numbering)
        editor.beginDraft(at: PixelPoint(x: 100, y: 100))
        #expect(editor.commitDraft())
        #expect(editor.updateSelectedNumberingIndex(8))
        if case let .numbering(_, _, index, _, _, _) = editor.selectedAnnotation?.kind {
            #expect(index == 8)
        } else {
            Issue.record("应为编号标注")
        }
        #expect(editor.takeNextNumberingIndex() == 9)

        // 5. 涂抹马赛克提交后不强行选中，确保连续涂抹顺滑。
        editor.select(.mosaic)
        editor.selectMosaicMode(.brush)
        editor.beginDraft(at: PixelPoint(x: 50, y: 50))
        editor.updateDraft(to: PixelPoint(x: 120, y: 60))
        #expect(editor.commitDraft())
        #expect(editor.selectedAnnotationID == nil)
    }

    @Test("二级尖角气泡支持上下翻转锚定，主栏支持按槽位显隐且新设置可持久化")
    func bubblePlacementAnchorAndToolbarSlotCustomization() {
        var layout = AnnotationToolbarLayout()
        layout.tool = .rectangle
        layout.panelPlacement = .above
        let bar = layout.layoutBar()
        let panel = layout.layoutPanel()
        // 上翻时面板在上方（y = 0），主栏在下方，互不重叠。
        #expect(panel.items.allSatisfy { $0.rect.maxY <= AnnotationToolbarLayout.panelHeight })
        #expect(bar.items.allSatisfy { $0.rect.minY >= AnnotationToolbarLayout.panelHeight + AnnotationToolbarLayout.panelGap })
        let rectIcon = bar.items.first { $0.kind == .tool(.rectangle) }!
        #expect(abs(layout.panelAnchorX() - rectIcon.rect.midX) < 0.01)

        // 隐藏部分主栏槽位后，主栏移除对应条目并变窄，但核心输出（复制/保存）始终保留。
        let fullWidth = layout.barSize.width
        layout.hiddenSlots = ["record", "longScreenshot", "cancel"]
        let filteredKinds = layout.layoutBar().items.map(\.kind)
        #expect(!filteredKinds.contains(.record))
        #expect(!filteredKinds.contains(.longScreenshot))
        #expect(!filteredKinds.contains(.cancel))
        #expect(filteredKinds.contains(.copy))
        #expect(filteredKinds.contains(.save))
        #expect(layout.barSize.width < fullWidth)

        // AppSettings 新增持久化偏好往返。
        let suiteName = "com.anshot.tests.phase2.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(store: defaults)
        settings.setWindowCaptureShadow(false)
        settings.setConfirmCancelWithAnnotations(false)
        settings.setToolbarSlot("record", visible: false)

        let reloaded = AppSettings(store: defaults)
        #expect(!reloaded.windowCaptureShadow)
        #expect(!reloaded.confirmCancelWithAnnotations)
        #expect(reloaded.toolbarHiddenSlots == ["record"])
    }
}
