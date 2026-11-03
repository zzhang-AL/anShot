//
//  OverlayColorPickerPresenter.swift
//  AnShotUI
//
//  覆盖层自绘取色器的生命周期与摆放。
//
//  ── 为什么不用系统 `NSColorPanel` ────────────────────────────
//
//  它是全局共享窗口，且默认 `hidesOnDeactivate = true`；而本应用是无 Dock 图标的
//  菜单栏辅助程序、**始终不是活跃应用**，于是它一显示就自我隐藏
//  （`isVisible` 仍为 true，窗口却已 order out）。自有面板同时解决外观不一致的问题。
//
//  ── 为什么单独抽出来 ──────────────────────────────────────
//
//  面板的创建、摆放、收起、以及「有没有压住选区」的自检自成一件事，
//  与选区交互、标注绘制、文字编辑都无关。留在 `OverlayView` 里只会让它继续膨胀
//  （那里已经是一个 2000+ 行的类）。
//

import AnShotCore
import AppKit

private let pickerLogger = AnShotLog.overlay
/// 覆盖层取色器的展示与摆放。
@MainActor
final class OverlayColorPickerPresenter {

    /// 当前会话的面板（会话结束即释放）。
    private var panel: ColorPickerPanel?

    /// 供诊断读取取色器视图（不参与业务逻辑）。
    var pickerView: ColorPickerView? { panel?.pickerView }

    /// 供诊断读取取色器窗口（用于查窗口服务器的在屏列表）。
    var panelWindow: NSWindow? { panel }

    /// 是否已经展示。
    var isPresented: Bool { panel?.isVisible ?? false }

    /// 打开取色器（已在展示时重新定位并同步颜色）。
    ///
    /// - Parameters:
    ///   - anchorInView: 颜色入口在**宿主视图坐标**（左上原点）里的位置。
    ///   - toolbarFrame: 工具栏在宿主视图坐标里的 frame，用于判断它开在选区的哪一侧。
    ///   - selection: 当前选区（宿主视图坐标），用于决定朝哪一侧展开。
    ///   - host: 宿主视图：提供窗口与坐标换算。
    ///   - state: 标注编辑器：读当前工具的颜色，拖动取色时写回。
    func present(
        anchorInView: CGPoint,
        toolbarFrame: CGRect,
        selection: CGRect?,
        in host: NSView,
        state: AnnotationEditorState
    ) {
        guard let window = host.window else { return }

        let panel = existingOrNewPanel(in: window, state: state)
        // 再次打开时同步一次当前颜色（用户可能刚改过工具或样式）。
        panel.pickerView.color = state.style.color(for: state.tool)
            ?? AnnotationStyle.default.shapeColor

        position(
            panel,
            anchorInView: anchorInView,
            toolbarFrame: toolbarFrame,
            selection: selection,
            in: host
        )
        panel.makeKeyAndOrderFront(nil)
        // 焦点给取色器本身，而不是让它自动落进 Hex 输入框。
        panel.makeFirstResponder(panel.pickerView)
    }

    /// 收起取色器并释放面板。会话结束必须调用。
    func dismiss() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    // MARK: - 内部

    private func existingOrNewPanel(
        in window: NSWindow,
        state: AnnotationEditorState
    ) -> ColorPickerPanel {
        if let panel { return panel }

        let panel = ColorPickerPanel()
        panel.pickerView.color = state.style.color(for: state.tool)
            ?? AnnotationStyle.default.shapeColor
        // 只弱引用编辑器：会话结束后它随会话释放，闭包不该把它留住。
        panel.pickerView.onChange = { [weak state] color in
            state?.selectColor(color)
        }
        // 挂成覆盖层的子窗口：跟随覆盖层显示/隐藏，也不会跑到它后面。
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        return panel
    }

    /// 把取色器摆在颜色入口附近，并保证不越出屏幕可见区。
    private func position(
        _ panel: ColorPickerPanel,
        anchorInView: CGPoint,
        toolbarFrame: CGRect,
        selection: CGRect?,
        in host: NSView
    ) {
        guard let window = host.window else { return }

        // 必须先把**视图坐标**转成**窗口坐标**再转屏幕坐标。
        //
        // 宿主视图是 flipped（原点在左上），而窗口坐标原点在左下；
        // 直接把视图坐标喂给 `convertPoint(toScreen:)` 会让锚点被当成
        // 「从屏幕底部量起」，面板跑到屏幕上半区去（实测踩过）。
        let inScreen = window.convertPoint(toScreen: host.convert(anchorInView, to: nil))
        let size = panel.frame.size

        // 优先开在**远离选区**的一侧。
        //
        // 工具栏紧贴选区，若取色器也朝选区方向展开就会盖住用户正要标注的内容。
        // 工具栏在选区下方（最常见）时往下开，在选区上方时往上开，
        // 也就是「同一侧连续排开」，视线不来回跳。
        let gap: CGFloat = 12
        let toolbarIsBelowSelection = selection.map { toolbarFrame.midY > $0.midY } ?? true

        var origin = CGPoint(
            x: inScreen.x - 12,
            y: toolbarIsBelowSelection ? inScreen.y - size.height - gap : inScreen.y + gap
        )

        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            // 首选位置放不下时翻到另一侧，最后统一夹进可见区。
            if origin.y < visible.minY + 8 {
                origin.y = inScreen.y + gap
            } else if origin.y + size.height > visible.maxY - 8 {
                origin.y = inScreen.y - size.height - gap
            }
            origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
            origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)

        // 自检：面板不应当盖住选区——盖住就会挡住用户正要标注的内容，
        // 而这只有在把两边坐标换算到同一空间后才看得出来
        // （曾因漏掉视图→窗口的翻转，面板跑到屏幕上半区、正好压在选区上）。
        guard let selection else { return }
        let selectionOnScreen = window.convertToScreen(host.convert(selection, to: nil))
        let overlaps = panel.frame.intersects(selectionOnScreen)
        pickerLogger.notice("""
            color picker placement: 与选区重叠=\(overlaps, privacy: .public) \
            \(overlaps ? "MISMATCH（取色器盖住了选区）" : "MATCH", privacy: .public)
            """)
    }
}
