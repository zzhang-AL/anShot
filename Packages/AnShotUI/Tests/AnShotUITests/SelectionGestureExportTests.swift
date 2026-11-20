//
//  SelectionGestureExportTests.swift
//  AnShotUITests
//
//  「选区手势还没结束就导出」的时序缺陷。
//
//  ── 这一条测的是什么 ─────────────────────────────────────────
//
//  选区只在 `mouseUp` 时才写进模型（`AnnotationEditorState.selection`），
//  拖拽途中控制器**不更新**它（`selectionDidChange` 只动控制器自己的
//  `selection`）。偏偏「框完立刻按 ⌘C」是常见手感：鼠标还没抬起，
//  键盘已经按下。此刻合成读到的是**上一个**选区——通常是自动识别给出的
//  候选框，它比用户刚拖出的框小得多。
//
//  用户看到的现象：选框还在、手柄（调整控件）还没出现，按了复制，
//  得到的却是「只有一部分」的截图。
//
//  ── 为什么用真实鼠标事件而不是直接摆状态 ──────────────────────
//
//  `interaction` 是 private，而且它的取值本身就是被测逻辑的一部分
//  （`mouseDown` 会根据命中的分支决定是 `.pending` / `.creating` /
//  `.moving` / `.resizing`）。直接摆状态等于跳过了「用户从哪起手」
//  这个真实变量，测出来的结论不成立。这里让视图自己走一遍。
//

import AnShotCore
import AppKit
import Testing

@testable import AnShotUI

// MARK: - 辅助

private func makeRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PixelRect {
    PixelRect(
        origin: PixelPoint(x: x, y: y),
        size: PixelSize(width: width, height: height)
    )
}

/// 一块纯色底图。
///
/// 视图的 `backdropScale`（底图像素 ÷ 视图逻辑点）由它反推，
/// 所以「传入 2 倍的位图」就等于复现 Retina 屏上的会话。
private func makeBackdrop(width: Int, height: Int) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else {
        fatalError("底图构造失败：\(width)x\(height)")
    }
    context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        fatalError("底图填充失败：\(width)x\(height)")
    }
    return image
}

/// 视图 + 承载它的窗口。
///
/// 必须有窗口：`mouseDown` / `mouseDragged` 的第一件事就是
/// `convert(_:from: nil)`，而视图不在窗口层级里时这个换算是无意义的。
@MainActor
private struct Fixture {
    let window: NSWindow
    let view: OverlayView
    let editor: AnnotationEditorState

    /// - Parameters:
    ///   - logicalSize: 视图逻辑点尺寸。
    ///   - scale: 底图像素 ÷ 逻辑点（2 即 Retina）。
    ///   - initialSelection: 会话初始选区，用来模拟「自动识别给出的候选」。
    init(
        logicalSize: CGSize = CGSize(width: 800, height: 600),
        scale: Int = 2,
        initialSelection: PixelRect
    ) {
        let frame = CGRect(origin: .zero, size: logicalSize)
        let panel = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let overlay = OverlayView(frame: frame, displayID: CGMainDisplayID())
        window = panel
        view = overlay
        panel.contentView = overlay

        overlay.backdrop = makeBackdrop(
            width: Int(logicalSize.width) * scale,
            height: Int(logicalSize.height) * scale
        )

        let state = AnnotationEditorState(selection: initialSelection)
        editor = state
        overlay.editorState = state

        // 只复刻控制器**写模型**的那一条接线（`selectionDidCommit`）。
        //
        // 刻意**不**把 `onSelectionChanged` 接到模型上：控制器现状就没有接
        // （拖拽途中只更新它自己的 `selection`），而本缺陷正来自这个不对称。
        // 若这里顺手接上，测试会立刻变绿，却掩盖了真实代码里仍存在的窗口期。
        overlay.onSelectionCommitted = { [weak overlay, weak state] logicalRect in
            guard let overlay, let state else { return }
            state.commitSelection(
                CoordinateConversion.pixelRect(
                    fromLogical: logicalRect,
                    scaleFactor: overlay.pixelsPerPoint
                )
            )
        }
    }

    /// 以**视图坐标**（左上原点）投递一次鼠标事件。
    ///
    /// 事件携带的是窗口坐标，因此这里先换算——否则 y 会被翻转，
    /// 拖出来的矩形与预期镜像对称，断言会以难以理解的方式失败。
    func send(_ type: NSEvent.EventType, at viewPoint: CGPoint) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: view.convert(viewPoint, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            Issue.record("无法构造鼠标事件：\(type)")
            return
        }
        switch type {
        case .leftMouseDown:
            view.mouseDown(with: event)
        case .leftMouseDragged:
            view.mouseDragged(with: event)
        case .leftMouseUp:
            view.mouseUp(with: event)
        default:
            Issue.record("未覆盖的事件类型：\(type)")
        }
    }

    /// 投递一次 ⌘C。
    func sendCommandC() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ) else {
            Issue.record("无法构造 ⌘C 事件")
            return
        }
        view.keyDown(with: event)
    }
}

// MARK: - 用例

@MainActor
@Suite("选区手势与导出的时序")
struct SelectionGestureExportTests {

    /// 端到端：框完立刻按 ⌘C（鼠标还没抬起），导出必须是**刚拖出的那个框**。
    @Test("手势未结束就按 ⌘C：导出用的是刚拖出的框，不是识别候选")
    func exportDuringGestureUsesFreshSelection() {
        // 会话开始时的「识别候选」：逻辑点 (500,200,200,150)，缩放后是它的两倍。
        let candidate = makeRect(1000, 400, 400, 300)
        let fixture = Fixture(initialSelection: candidate)
        let editor = fixture.editor

        // 从候选之外起手（候选内按下会走「单击确认 / 重框」的裁决分支，
        // 那不是本用例要测的路径），拖到右下角。
        fixture.send(.leftMouseDown, at: CGPoint(x: 50, y: 50))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 750, y: 550))

        // 前提：模型此刻仍是候选——这正是缺陷现场，也是本测试有效的证明。
        #expect(
            editor.selection == candidate,
            "拖拽途中模型不应被改写，实际 \(editor.selection)"
        )

        // 对照：此刻若不落定就合成，拿到的就是候选框——修复前的行为。
        // 没有这条对照，「落定」万一退化成空操作，上面的断言仍会通过，
        // 而用户看到的故障依旧。
        guard let backdrop = fixture.view.backdrop else {
            Issue.record("底图未绑定，无法做对照合成")
            return
        }
        let withoutSettling = SessionExporter.compose(
            editor: editor,
            backdrop: backdrop,
            scaleFactor: fixture.view.pixelsPerPoint
        )
        #expect(
            withoutSettling?.width == 400 && withoutSettling?.height == 300,
            "未落定时合成应停在候选框「\(candidate)」上，实际 \(withoutSettling?.width ?? -1)x\(withoutSettling?.height ?? -1)"
        )

        var exported: CGImage?
        fixture.view.onExport = { image, _ in exported = image }
        fixture.sendCommandC()

        #expect(
            editor.selection == makeRect(100, 100, 1400, 1000),
            "落定后模型必须是刚拖出的矩形（逻辑点 50,50,700,500 × 2），实际 \(editor.selection)"
        )
        #expect(exported?.width == 1400, "导出宽应为 1400 像素，实际 \(exported?.width ?? -1)")
        #expect(exported?.height == 1000, "导出高应为 1000 像素，实际 \(exported?.height ?? -1)")
    }

    /// 没有手势时落定必须是空操作：它挂在每次导出的必经之路上。
    @Test("没有手势时落定不改动模型，且放行导出")
    func settleIsNoOpWithoutGesture() {
        let candidate = makeRect(1000, 400, 400, 300)
        let fixture = Fixture(initialSelection: candidate)

        #expect(fixture.view.settleSelectionGestureForExport())
        #expect(
            fixture.editor.selection == candidate,
            "无手势时不应改动模型，实际 \(fixture.editor.selection)"
        )
    }

    /// 手势刚起步（框还很小）时导出：按误触收掉并**拒绝导出**。
    ///
    /// 拒绝而不是「退回上一个选区」：导出一个与用户刚画的框无关的旧选区，
    /// 比明确不导出更糟——用户会以为那就是他框到的东西。
    @Test("手势太小：收掉这次手势并拒绝导出")
    func tooSmallGestureIsRejected() {
        let candidate = makeRect(1000, 400, 400, 300)
        let fixture = Fixture(initialSelection: candidate)

        // 4x2 逻辑点，低于最小选区尺寸（8）。
        fixture.send(.leftMouseDown, at: CGPoint(x: 50, y: 50))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 54, y: 52))

        #expect(!fixture.view.settleSelectionGestureForExport(), "过小的手势不应放行导出")
        #expect(fixture.view.effectiveSelection == nil, "过小的矩形应被清掉，不留细线选区")
    }

    @Test("快捷键解析支持 ⌘P 贴图、⌘D 复制标注与方向键 1px/10px 微调")
    func keyCommandParsesPinDuplicateAndNudge() throws {
        let pinEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "p", charactersIgnoringModifiers: "p",
            isARepeat: false, keyCode: 35
        ))
        #expect(OverlayKeyCommand.parse(pinEvent) == .pin)

        let dupEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d",
            isARepeat: false, keyCode: 2
        ))
        #expect(OverlayKeyCommand.parse(dupEvent) == .duplicate)

        let right1 = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 124
        ))
        #expect(OverlayKeyCommand.parse(right1) == .nudge(dx: 1, dy: 0))

        let up10 = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 126
        ))
        #expect(OverlayKeyCommand.parse(up10) == .nudge(dx: 0, dy: -10))
    }

    @Test("候选态按单键切换工具时自动确认当前候选选区")
    func selectingToolInCandidateStateConfirmsSelection() throws {
        let candidate = makeRect(100, 100, 400, 300)
        let fixture = Fixture(initialSelection: candidate)
        fixture.view.setSelection(CGRect(x: 50, y: 50, width: 200, height: 150))
        #expect(!fixture.editor.isSelectionConfirmed)

        let rKey = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil,
            characters: "r", charactersIgnoringModifiers: "r",
            isARepeat: false, keyCode: 15
        ))
        fixture.view.keyDown(with: rKey)
        #expect(fixture.editor.isSelectionConfirmed, "候选态按 R 切工具必须自动锁定选区")
        #expect(fixture.editor.tool == .rectangle)
    }

    @Test("指针模式双击文字进入重编辑并同步多行 maxWidth 折行")
    func pointerDoubleClickReEditsTextAndSyncsMaxWidth() throws {
        let candidate = makeRect(0, 0, 800, 600)
        let fixture = Fixture(scale: 2, initialSelection: candidate)
        fixture.view.setSelection(CGRect(x: 50, y: 50, width: 400, height: 300))
        fixture.editor.confirmSelection()

        fixture.editor.select(.text)
        fixture.editor.beginTextEditing(at: PixelPoint(x: 200, y: 200))
        fixture.editor.updateTextDraft("第一行\n第二行")
        fixture.view.syncTextEditorFromState()
        #expect(fixture.editor.textDraft?.maxWidth != nil, "多行编辑器应根据选区右边界同步 maxWidth")
        #expect(fixture.editor.commitTextDraft(scaleFactor: 2))

        // 切回指针模式，双击刚提交的文字应直接进入重编辑态
        fixture.editor.select(.pointer)
        let box = fixture.editor.annotations[0].hitBoundingRect
        let clickPoint = CGPoint(
            x: (box.origin.x + box.size.width / 2) / 2,
            y: (box.origin.y + box.size.height / 2) / 2
        )
        let doubleClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: fixture.view.convert(clickPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        ))
        fixture.view.mouseDown(with: doubleClick)
        #expect(fixture.editor.isEditingText, "指针模式下双击已有文字必须进入编辑态")
        #expect(fixture.editor.textDraft?.fontSize == AnnotationStyle.default.textFontSize)
    }

    @Test("已确认选区误点暗区不清空选区，有标注时锁定防误丢，绘图工具下可直拉选区手柄与选区内约束草稿")
    func confirmedSelectionGuardsAndAnnotationInteractions() {
        let initial = makeRect(200, 200, 600, 400) // 逻辑点 (100,100,300,200)
        let fixture = Fixture(scale: 2, initialSelection: initial)
        let logicalSelection = CGRect(x: 100, y: 100, width: 300, height: 200)
        fixture.view.setSelection(logicalSelection)
        fixture.editor.confirmSelection()

        // 1. 无标注时，在选区外暗区轻点一下：零闪烁，原选区完好保留
        fixture.send(.leftMouseDown, at: CGPoint(x: 30, y: 30))
        #expect(fixture.view.effectiveSelection == logicalSelection, "选区外按下瞬间不应立刻清空原选区")
        fixture.send(.leftMouseUp, at: CGPoint(x: 30, y: 30))
        #expect(fixture.view.effectiveSelection == logicalSelection, "选区外轻点抬起后应保持原选区")

        // 2. 矩形工具下新建草稿并拖出选区外部：草稿必须被夹紧在选区内，不越界画进暗区
        fixture.editor.select(.rectangle)
        fixture.send(.leftMouseDown, at: CGPoint(x: 150, y: 150))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 600, y: 500))
        fixture.send(.leftMouseUp, at: CGPoint(x: 600, y: 500))
        #expect(fixture.editor.annotations.count == 1)
        if case let .rectangle(rect, _, _, _) = fixture.editor.annotations[0].kind {
            #expect(rect.origin.x + rect.size.width <= initial.origin.x + initial.size.width + 0.5, "草稿右缘不得越出选区")
            #expect(rect.origin.y + rect.size.height <= initial.origin.y + initial.size.height + 0.5, "草稿下缘不得越出选区")
        } else {
            Issue.record("应提交矩形标注")
        }

        // 3. 刚画好矩形处于选中态，在框内拖动直接移动它（不新建第二个矩形）
        let beforeMove = fixture.editor.annotations[0].boundingRect
        fixture.send(.leftMouseDown, at: CGPoint(x: 220, y: 220))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 200, y: 200))
        fixture.send(.leftMouseUp, at: CGPoint(x: 200, y: 200))
        #expect(fixture.editor.annotations.count == 1, "拖动已选中空心框内部必须移动它，不得新建重复框")
        let afterMove = fixture.editor.annotations[0].boundingRect
        #expect(afterMove.origin.x < beforeMove.origin.x && afterMove.origin.y < beforeMove.origin.y)

        // 4. 已有标注时，在选区外暗区误点或拖拽：仅取消标注选中，绝不清空选区
        fixture.send(.leftMouseDown, at: CGPoint(x: 20, y: 20))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 80, y: 80))
        fixture.send(.leftMouseUp, at: CGPoint(x: 80, y: 80))
        #expect(fixture.view.effectiveSelection == logicalSelection, "已有标注时选区外误拖不得清空原选区")
        #expect(!fixture.editor.hasSelectedAnnotation, "点击选区外暗区应清除当前标注选中态")

        // 5. 绘图工具下拖动选区左上角手柄可直接缩放截图选区
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 80, y: 80))
        fixture.send(.leftMouseUp, at: CGPoint(x: 80, y: 80))
        #expect(fixture.view.effectiveSelection?.minX == 80, "绘图工具下直接拖动选区左上角手柄应可扩大选区")

        // 6. 方向键连续微调标注：多次微调合并为单条撤销记录
        fixture.editor.selectAnnotation(id: fixture.editor.annotations[0].id)
        let beforeNudge = fixture.editor.annotations[0].boundingRect
        for _ in 0 ..< 5 {
            fixture.view.performCommand(.nudge(dx: 2, dy: 0))
        }
        #expect(fixture.editor.annotations[0].boundingRect.origin.x == beforeNudge.origin.x + 10)
        // 触发一次非微调命令（undo），先自动落盘事务再撤销，一次撤销应完整回到微调前
        fixture.view.performCommand(.undo)
        #expect(fixture.editor.annotations[0].boundingRect.origin.x == beforeNudge.origin.x, "连续 5 次方向键微调应合并为单条撤销记录")

        // 7. 跨类型选中标注：矩形工具下选中文字，工具栏布局自动切为文字属性检查面板（含字号与删除）
        var layout = AnnotationToolbarLayout()
        layout.tool = .rectangle
        layout.hasSelectedAnnotation = true
        layout.selectedAnnotationMatchesTool = false
        layout.selectedAnnotationIsText = true
        layout.selectedAnnotationSupportsColor = true
        layout.selectedAnnotationSupportsLineWidth = false
        let panelKinds = Set(layout.layoutPanel().items.map(\.kind))
        #expect(panelKinds.contains(.deleteSelected), "跨类型选中检查面板应包含删除按钮")
        #expect(panelKinds.contains(.textBoldToggle), "矩形工具下选中文字时应展示文字属性控件而非矩形线宽")
    }
}
