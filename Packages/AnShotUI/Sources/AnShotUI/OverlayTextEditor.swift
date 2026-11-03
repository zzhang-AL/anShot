//
//  OverlayTextEditor.swift
//  AnShotUI
//
//  文字输入的控件宿主：把编辑器状态里的文字草稿显示成一个输入框。
//
//  ── 为什么单独一个类型 ────────────────────────────────────
//
//  输入框有一串只在交互中才暴露的规则，它们与选区几何毫无关系：
//  * 输入法组字过程中不能重写 `stringValue`，否则光标会被顶掉；
//  * 回车在组字中是「确认候选词」，不是「提交」；
//  * ESC 在输入框里是「放弃这笔文字」，而不是退出整个会话；
//  * 移除输入框时必须把键盘焦点交还给宿主，否则回车与 ⌘C 会静默失效。
//  留在覆盖层视图里，视图就要同时承担「几何与绘制」和「文本输入」两种职责，
//  而这些规则又只在打字时才被触发，回归时最容易漏。
//
//  ── 状态归属 ──────────────────────────────────────────────
//
//  文字的权威副本在 `AnnotationEditorState`（草稿与已提交标注），
//  这里只是它的一个视图：`sync` 单向把草稿推给控件，用户改动经回调送回状态。
//  视图与控件**都不保存**文字，因此「输入中看到的」与「提交后写进模型的」
//  不会各记一份而分叉。
//

import AnShotCore
import AppKit

/// 文字输入控件。
@MainActor
final class OverlayTextEditor: NSObject, NSTextFieldDelegate {

    /// 用户改了内容（每次按键、输入法更新都会触发）。
    var onTextChange: ((String) -> Void)?
    /// 回车提交当前文字。
    var onCommit: (() -> Void)?
    /// ESC 放弃这笔文字。
    var onCancel: (() -> Void)?

    private(set) var field: NSTextField?

    /// 当前是否有输入控件存在。
    var isActive: Bool { field != nil }

    /// 输入控件在其父视图坐标系里的 frame（无控件时为 nil）。
    var frame: CGRect? { field?.frame }

    /// 按草稿同步控件；`draft` 为 nil 时移除控件并把焦点交还宿主。
    ///
    /// - Parameters:
    ///   - scaleFactor: 逻辑点 → 像素的缩放。草稿坐标以**底图像素**为单位。
    ///   - host: 控件挂载到哪个视图，同时是键盘焦点交还的对象。
    func sync(draft: TextEditDraft?, scaleFactor: CGFloat, host: NSView) {
        guard let draft else {
            remove(host: host)
            return
        }

        let font = NSFont.systemFont(ofSize: CGFloat(draft.fontSize))
        let color = NSColor(
            srgbRed: CGFloat(draft.color.r),
            green: CGFloat(draft.color.g),
            blue: CGFloat(draft.color.b),
            alpha: 1
        )

        let field: NSTextField
        let isNew: Bool
        if let existing = self.field {
            field = existing
            isNew = false
        } else {
            field = NSTextField(frame: .zero)
            let cell = TopAlignedTextFieldCell(textCell: "")
            // 换 cell 会**丢掉** `NSTextField(frame:)` 默认给出的可编辑性。
            //
            // 可编辑/可选中其实是 cell 上的属性（`field.isEditable` 只是转发到 cell），
            // 而 `NSTextFieldCell` 自身的默认是 not editable；
            // `NSTextField(frame:)` 之所以可编辑，是因为它自带的 cell 被打开过。
            // 丢掉之后的现象很有迷惑性：输入框会正常出现、也能聚焦、光标也在闪，
            // 但**打不进任何字**——看起来像键盘事件被吞了，实际是控件拒绝编辑。
            // 实测：替换前后 `isEditable` 由 true 变 false。
            cell.isEditable = true
            cell.isSelectable = true
            field.cell = cell
            field.isBordered = false
            field.drawsBackground = true
            field.backgroundColor = NSColor.black.withAlphaComponent(0.35)
            field.focusRingType = .none
            field.delegate = self
            host.addSubview(field)
            self.field = field
            isNew = true
        }

        // 只在内容不同时写回：输入法组字过程中无条件赋值会把光标顶掉。
        if field.stringValue != draft.text {
            field.stringValue = draft.text
        }
        field.font = font
        field.textColor = color
        field.placeholderAttributedString = NSAttributedString(
            string: "输入文字后回车",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
            ]
        )

        // 行高走与渲染同源的度量（CoreText），不靠 fontSize 乘系数去猜。
        // 输入框高度因此等于该字号实际排版出来的高度。
        let lineHeight = CGFloat(
            TextMetrics.lineHeight(for: draft.font(scaleFactor: scaleFactor))
        )
        let origin = CGPoint(
            x: CGFloat(draft.topLeft.x) / scaleFactor,
            y: CGFloat(draft.topLeft.y) / scaleFactor
        )
        let width = min(320, max(80, host.bounds.width - 16))
        let maxX = max(8, host.bounds.width - 8 - width)
        let maxY = max(8, host.bounds.height - 8 - lineHeight)
        field.frame = CGRect(
            x: min(max(8, origin.x), maxX),
            y: min(max(8, origin.y), maxY),
            width: width,
            height: max(lineHeight, 12)
        )

        if isNew {
            host.window?.makeFirstResponder(field)
        }
    }

    /// 移除输入控件。
    func remove(host: NSView) {
        guard let field else { return }
        field.removeFromSuperview()
        self.field = nil

        // 必须把键盘焦点交还给宿主。
        //
        // 注意不能拿 `field` 去比对 first responder：输入框处于编辑态时，
        // 真正的 first responder 是共享的 field editor（一个 NSTextView），
        // `firstResponder === field` 恒为假——于是焦点落回窗口本身，
        // 之后回车、⌘C 这些依赖 keyDown 的快捷键**全部静默失效**
        // （用户看到的现象是「按了没反应」，而不是报错）。
        if host.window?.firstResponder !== host {
            host.window?.makeFirstResponder(host)
        }

        host.needsDisplay = true
    }

    // MARK: - NSTextFieldDelegate

    /// 输入内容变化时同步给状态（状态是权威副本，控件只是它的视图）。
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        onTextChange?(field.stringValue)
    }

    /// 拦截回车与 ESC。
    ///
    /// 不用 `target/action`（只能捕回车），也避免让编辑器吞掉 ESC——
    /// ESC 在编辑器内应「放弃这笔文字」而不是退出会话。
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // 输入法正在组字（marked text）时，回车是「确认候选词」，
            // 不能当提交，否则中文输入永远选不了词。
            if textView.hasMarkedText() {
                return false
            }
            onCommit?()
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }

        return false
    }
}
