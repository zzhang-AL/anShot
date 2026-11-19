//
//  OverlayTextEditor.swift
//  AnShotUI
//
//  文字输入的控件宿主：把编辑器状态里的文字草稿显示成一个多行自动折行输入框。
//
//  ── 为什么使用 NSTextView ─────────────────────────────────
//
//  支持多行编辑（Return 提交、⇧Return 换行）以及按选区右边界自适应宽度折行，
//  同时配合应用常驻 Edit 主菜单天然支持 ⌘C / ⌘V / ⌘X / ⌘A 文本编辑快捷键，
//  并保留输入法组字（hasMarkedText）期间不误拦截回车的规则。
//

import AnShotCore
import AppKit

/// 支持 Return 提交、⇧Return 换行、ESC 取消与空态占位的自绘多行输入视图。
private final class OverlayInputTextView: NSTextView {
    var onCommitKey: (() -> Void)?
    var onCancelKey: (() -> Void)?
    var placeholderText: String = "输入文字后回车（⇧回车换行）"

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let font else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.42),
        ]
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 0
        (placeholderText as NSString).draw(
            at: CGPoint(x: inset.width + padding, y: inset.height),
            withAttributes: attrs
        )
    }

    override func keyDown(with event: NSEvent) {
        // 输入法正在组字时，回车与 ESC 交给输入法处理选词/消词。
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        // 53 = Escape：放弃本次文字编辑
        if event.keyCode == 53 {
            onCancelKey?()
            return
        }
        // 36 = 主键盘 Return，76 = 小键盘 Return
        if event.keyCode == 36 || event.keyCode == 76 {
            let flags = event.modifierFlags
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            onCommitKey?()
            return
        }
        super.keyDown(with: event)
    }
}

/// 文字输入控件宿主。
@MainActor
final class OverlayTextEditor: NSObject, NSTextViewDelegate {

    /// 用户改了内容（每次按键、输入法更新都会触发）。
    var onTextChange: ((String) -> Void)?
    /// 输入框自适应折行最大宽度变化（底图像素），用于同步导出换行。
    var onMaxWidthChange: ((Double?) -> Void)?
    /// 回车提交当前文字。
    var onCommit: (() -> Void)?
    /// ESC 放弃这笔文字。
    var onCancel: (() -> Void)?

    private var editorView: OverlayInputTextView?

    /// 当前是否有输入控件存在。
    var isActive: Bool { editorView != nil }

    /// 输入控件在其父视图坐标系里的 frame（无控件时为 nil）。
    var frame: CGRect? { editorView?.frame }

    /// 供诊断读取当前输入框状态。
    var diagnosticStateString: String {
        guard let tv = editorView else { return "none" }
        let isEditing = tv.window?.firstResponder === tv
        return "editable=\(tv.isEditable),selectable=\(tv.isSelectable),editing=\(isEditing)"
    }

    /// 按草稿同步控件；`draft` 为 nil 时移除控件并把焦点交还宿主。
    ///
    /// - Parameters:
    ///   - scaleFactor: 逻辑点 → 像素的缩放。草稿坐标以**底图像素**为单位。
    ///   - selectionBounds: 当前选区（宿主视图逻辑点），用于按选区右边界自适应折行。
    ///   - host: 控件挂载到哪个视图，同时是键盘焦点交还的对象。
    func sync(
        draft: TextEditDraft?,
        scaleFactor: CGFloat,
        selectionBounds: CGRect? = nil,
        host: NSView
    ) {
        guard let draft else {
            remove(host: host)
            return
        }

        let safeScale = scaleFactor > 0 ? scaleFactor : 1
        // 复用模型层的字体描述符构造与导出同源的逻辑点字体（含字体族、粗体、斜体）。
        let logicalDescriptor = FontDescriptor(
            family: draft.fontFamily,
            size: draft.fontSize,
            weight: draft.isBold ? 700 : 400,
            italic: draft.isItalic
        )
        let font = TextMetrics.font(for: logicalDescriptor) as NSFont
        let color = NSColor(
            srgbRed: CGFloat(draft.color.r),
            green: CGFloat(draft.color.g),
            blue: CGFloat(draft.color.b),
            alpha: 1
        )

        let textView: OverlayInputTextView
        let isNew: Bool
        if let existing = editorView {
            textView = existing
            isNew = false
        } else {
            let tv = OverlayInputTextView(frame: .zero)
            tv.isRichText = false
            tv.importsGraphics = false
            tv.allowsUndo = true
            tv.isEditable = true
            tv.isSelectable = true
            tv.drawsBackground = true
            tv.backgroundColor = NSColor.black.withAlphaComponent(0.35)
            tv.insertionPointColor = .white
            tv.isHorizontallyResizable = false
            tv.isVerticallyResizable = false
            tv.textContainerInset = NSSize(width: 0, height: 2)
            tv.textContainer?.lineFragmentPadding = 0
            tv.textContainer?.widthTracksTextView = true
            tv.delegate = self
            tv.onCommitKey = { [weak self] in self?.onCommit?() }
            tv.onCancelKey = { [weak self] in self?.onCancel?() }
            host.addSubview(tv)
            self.editorView = tv
            textView = tv
            isNew = true
        }

        // 只在内容不同时写回：输入法组字过程中无条件赋值会把光标顶掉。
        if textView.string != draft.text && !textView.hasMarkedText() {
            textView.string = draft.text
        }
        textView.font = font
        textView.textColor = color
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: color,
        ]

        // 根据选区右边界自适应最大输入宽度，防导出右侧裁切。
        let lineHeight = CGFloat(
            TextMetrics.lineHeight(for: draft.font(scaleFactor: safeScale))
        )
        let origin = CGPoint(
            x: CGFloat(draft.topLeft.x) / safeScale,
            y: CGFloat(draft.topLeft.y) / safeScale
        )
        let boundary = selectionBounds ?? host.bounds
        let maxContainerWidth = max(120, boundary.width - 16)
        let clampedX = min(max(boundary.minX + 8, origin.x), max(boundary.minX + 8, boundary.maxX - 128))
        let availableToRightEdge = max(120, boundary.maxX - 8 - clampedX)
        let width = min(maxContainerWidth, availableToRightEdge)

        // 将逻辑点宽度换算回底图像素写入模型 maxWidth，保持输入折行与 CoreText 导出一致。
        let pixelMaxWidth = Double(width * safeScale)
        if draft.maxWidth != pixelMaxWidth {
            onMaxWidthChange?(pixelMaxWidth)
        }

        // 先按可用宽度排版一次，求出实际多行高度。
        textView.frame = CGRect(x: clampedX, y: origin.y, width: width, height: max(lineHeight + 4, 20))
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            let usedRect = layoutManager.usedRect(for: container)
            let neededHeight = ceil(max(lineHeight, usedRect.height)) + textView.textContainerInset.height * 2
            let maxHeight = max(lineHeight + 4, host.bounds.height - 8 - origin.y)
            let finalHeight = min(neededHeight, maxHeight)
            let maxY = max(8, host.bounds.height - 8 - finalHeight)
            textView.frame = CGRect(
                x: clampedX,
                y: min(max(8, origin.y), maxY),
                width: width,
                height: max(finalHeight, 16)
            )
        }

        if isNew {
            host.window?.makeFirstResponder(textView)
        }
    }

    /// 移除输入控件。
    func remove(host: NSView) {
        guard let tv = editorView else { return }
        tv.removeFromSuperview()
        self.editorView = nil

        if host.window?.firstResponder !== host {
            host.window?.makeFirstResponder(host)
        }
        host.needsDisplay = true
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let tv = editorView else { return }
        onTextChange?(tv.string)
    }
}
