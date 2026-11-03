//
//  ShortcutRecorderView.swift
//  AnShotUI
//
//  快捷键录制控件。点击后进入录制态，捕获下一次按键组合。
//
//  ── 为什么需要「录制前先注销全局热键」 ────────────────────────
//
//  Carbon 的 `RegisterEventHotKey` 是**系统级**截获：组合一旦被注册，
//  系统会把它投递成 `kEventHotKeyPressed` 给注册者，**不会**再作为
//  `keyDown` 事件流经 key window。
//
//  后果很具体：假设当前快捷键是 `⌃1`，用户点开控件想把它改成别的，
//  顺手按了 `⌃1`（想「先看看现在的值」或「确认一下」），
//  这个按键会被系统直接送给热键处理器触发一次截图，
//  录制控件**一个事件都收不到**，表现为「按了没反应」。
//
//  因此录制开始前必须临时注销全局热键，结束时恢复。
//  这条约束由宿主（设置窗口 → AppDelegate）实现，本控件只负责发信号——
//  它不该知道全局热键的存在，那是应用层的所有权。
//

import AppKit
import Carbon.HIToolbox

/// 快捷键录制控件。
///
/// 交互约定：
///   - 点击进入录制态，控件变强调色并显示提示文案；
///   - 按下有效组合即提交，由 `commitHandler` 决定是否接受；
///   - `Esc` 取消，窗口失焦取消，两者都恢复原值；
///   - 校验不通过时**保持录制态**并回报原因，让用户直接重按，不必再来一遍。
@MainActor
final class ShortcutRecorderView: NSView {

    // MARK: 对外接口

    /// 当前显示的快捷键。
    var shortcut: Shortcut {
        didSet {
            guard shortcut != oldValue else { return }
            // 键帽数量变化会改变需要的宽度。
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// 即将进入录制态。返回 `false` 可以拒绝进入（宿主无法让出热键时）。
    var willBeginRecording: (() -> Bool)?

    /// 已退出录制态（提交或取消都会调用）。宿主在此恢复热键注册。
    var didEndRecording: (() -> Void)?
    /// 用户提交了一个候选组合。
    ///
    /// - Returns: `nil` 表示接受；返回字符串表示拒绝，内容是给用户看的原因。
    ///   宿主在这里做**真实**的注册尝试——只有它能知道组合是否已被占用。
    var commitHandler: ((Shortcut) -> String?)?

    /// 需要展示一条错误说明。传 `nil` 清除。
    var onMessage: ((String?) -> Void)?

    // MARK: 状态

    private(set) var isRecording = false

    /// 进入录制态时暂存的显示值，取消时恢复。
    private var shortcutBeforeRecording: Shortcut?

    // MARK: 构造

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        // 让系统负责 focus ring，不在 draw 里自绘——自绘的 ring 在
        // 不同 macOS 版本和高对比度模式下与系统样式对不上。
        focusRingType = .default
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    /// 记录鼠标是否悬停，用于给出可点击的反馈。
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: 尺寸

    override var intrinsicContentSize: NSSize {
        // 宽度按当前键帽总宽算，但设一个下限：
        // 录制态的提示文字比单个键帽长，不留余地会让控件在两种状态间跳动。
        let gap: CGFloat = 5
        let labels = shortcut.keycapLabels
        let capsWidth = labels.map(Self.keycapWidth).reduce(0, +)
            + gap * CGFloat(max(0, labels.count - 1))
        return NSSize(
            width: max(132, capsWidth + 28),
            height: SettingsTheme.keycapHeight + 8
        )
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
    }

    // MARK: 焦点

    override var acceptsFirstResponder: Bool { true }

    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        // 焦点离开即取消录制。这是必须的：用户点别处时如果还在录制态，
        // 之后任何一次按键都会被当成快捷键输入。
        if isRecording {
            cancelRecording()
        }
        needsDisplay = true
        return true
    }

    // MARK: focus ring

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds,
            xRadius: 8,
            yRadius: 8
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        guard !isRecording else {
            // 录制中再点一次：视为放弃本次录制。
            cancelRecording()
            return
        }
        window?.makeFirstResponder(self)
        beginRecording()
    }

    // MARK: 录制

    private func beginRecording() {
        // 宿主先让出热键。让不出就不进入录制态——
        // 进去了也录不到，那才是真正的坏体验。
        if let willBeginRecording, !willBeginRecording() {
            return
        }
        shortcutBeforeRecording = shortcut
        isRecording = true
        onMessage?(nil)
        needsDisplay = true
    }

    /// 提交成功或主动取消后退出录制态。
    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        shortcutBeforeRecording = nil
        needsDisplay = true
        didEndRecording?()
    }

    private func cancelRecording() {
        guard isRecording else { return }
        // 恢复进入录制前显示的值：用户按 Esc 就是「当我没动过」。
        if let shortcutBeforeRecording {
            shortcut = shortcutBeforeRecording
        }
        onMessage?(nil)
        endRecording()
    }

    /// 从控件外部取消录制。
    ///
    /// 窗口失焦或关闭时由宿主调用。必须走和 Esc 相同的路径——
    /// 「恢复原值 + 通知宿主恢复热键」这两件事一件都不能少，
    /// 少了第二件，用户的热键会被永久性地留在「已让出」状态。
    func cancelRecordingExternally() {
        cancelRecording()
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            // 未录制时：Space / Return 启动录制。
            // 不处理的话，纯键盘用户永远无法进入录制态——
            // 而「点击方框」是鼠标专属动作。
            let code = UInt32(event.keyCode)
            if code == UInt32(kVK_Space) || code == UInt32(kVK_Return) {
                beginRecording()
                return
            }
            // 其余按键不吞，交给正常响应链（Tab 焦点切换等）。
            super.keyDown(with: event)
            return
        }

        let code = UInt32(event.keyCode)

        // Tab 在录制态下用于**离开**，不当作候选键。
        // 不处理的话，用户会被困在录制态里：Tab 会被当成一个缺修饰键的
        // 非法组合而被拒，而它恰恰是最自然的退出方式。
        if code == UInt32(kVK_Tab) {
            cancelRecording()
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(nil)
            } else {
                window?.selectNextKeyView(nil)
            }
            return
        }

        // Escape 单独处理，且**先于**校验：它是取消手段，不是候选快捷键。
        if code == UInt32(kVK_Escape) {
            cancelRecording()
            return
        }

        let candidate = Shortcut(
            keyCode: code,
            modifiers: Shortcut.carbonModifiers(from: event.modifierFlags)
        )

        // 先做静态校验（缺修饰键之类），再做注册尝试。
        // 顺序有意义：静态校验不需要碰系统状态，拒绝成本为零，
        // 因此这类拒绝可以**保持录制态**让用户直接重按。
        if let issue = candidate.registrationIssue {
            onMessage?(issue.message)
            NSSound.beep()
            return
        }

        if let reason = commitHandler?(candidate) {
            onMessage?(reason)
            NSSound.beep()
            // 注册失败必须**退出录制态**。
            // 此时宿主已经在录制开始时让出了旧注册，
            // 停在录制态会让用户的热键一直处于未注册状态；
            // 退出会触发 didEndRecording，宿主的 resume 把旧热键装回去。
            endRecording()
            return
        }

        shortcut = candidate
        onMessage?(nil)
        endRecording()
    }

    /// 拦截未处理的按键，避免录制态下按键穿透到菜单快捷键
    /// （否则按 ⌘Q 会真的退出应用）。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    /// Esc：录制中先取消录制，否则沿响应链传递（让窗口关闭）。
    override func cancelOperation(_ sender: Any?) {
        if isRecording {
            cancelRecording()
        } else {
            super.cancelOperation(sender)
        }
    }

    // MARK: 绘制

    /// 把组合键画成一排独立的键帽。
    ///
    /// 为什么不直接画一行文本（`⌃1`）：键帽把「这是两个按键」这件事
    /// 画了出来，而字符串需要用户自己解析。录制控件是设置页里唯一
    /// 需要用户动手操作的地方，多用一点视觉分量是值得的。
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let container = bounds.insetBy(dx: 0.5, dy: 0.5)

        if isRecording {
            // 录制态用实心反色块：这是全窗口对比度最高的状态，
            // 用来明确告知「现在按下的键会被捕获」。
            SettingsTheme.fillRoundedRect(
                container, radius: 8,
                color: SettingsTheme.accent, in: context
            )
            drawCentered(
                "按下组合键…",
                size: 12,
                color: SettingsTheme.onAccent,
                weight: .medium
            )
        } else {
            SettingsTheme.fillRoundedRect(
                container, radius: 8,
                color: SettingsTheme.insetBackground, in: context
            )
            SettingsTheme.strokeRoundedRect(
                container, radius: 8,
                color: isHovered ? NSColor.labelColor.withAlphaComponent(0.25) : SettingsTheme.cardBorder,
                lineWidth: 1, in: context
            )
            drawKeycaps(in: context)
        }
    }

    private func drawKeycaps(in context: CGContext) {
        let labels = shortcut.keycapLabels
        let gap: CGFloat = 5
        let height = SettingsTheme.keycapHeight
        let y = (bounds.height - height) / 2

        let widths = labels.map(Self.keycapWidth)
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, labels.count - 1))
        var x = (bounds.width - total) / 2

        for (index, label) in labels.enumerated() {
            let rect = CGRect(x: x, y: y, width: widths[index], height: height)
            drawKeycap(label, in: rect, context: context)
            x += widths[index] + gap
        }
    }

    private func drawKeycap(_ label: String, in rect: CGRect, context: CGContext) {
        SettingsTheme.fillRoundedRect(
            rect, radius: SettingsTheme.keycapRadius,
            color: SettingsTheme.keycapBackground, in: context
        )
        // 描边而非纯色块：键帽的边界靠这条细线勾出，
        // 浅色模式下白底白键帽才分得开。
        SettingsTheme.strokeRoundedRect(
            rect, radius: SettingsTheme.keycapRadius,
            color: SettingsTheme.keycapEdge, lineWidth: 1, in: context
        )

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }

    /// 单个键帽的宽度。修饰符符号较窄，字母数字较宽，
    /// 太窄会让「空格」「F12」这类标签贴边。
    private static func keycapWidth(for label: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]
        let textWidth = (label as NSString).size(withAttributes: attributes).width
        return max(28, textWidth + 16)
    }

    private func drawCentered(
        _ text: String,
        size: CGFloat,
        color: NSColor,
        weight: NSFont.Weight
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(
                x: bounds.midX - textSize.width / 2,
                y: bounds.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    // MARK: 辅助功能

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? { "快捷键" }

    override func accessibilityValue() -> Any? {
        isRecording ? "正在录制" : shortcut.displayName
    }

    override func accessibilityHelp() -> String? {
        isRecording
            ? "按下要使用的快捷键组合，按 Escape 或 Tab 取消。"
            : "按下以录制新的快捷键。"
    }

    /// 无障碍「按下」动作。
    ///
    /// 声明了 `.button` 角色却不实现它，VoiceOver 用户会得到一个
    /// 「能按下但按了没反应」的按钮。
    override func accessibilityPerformPress() -> Bool {
        guard !isRecording else { return false }
        window?.makeFirstResponder(self)
        beginRecording()
        return true
    }
}
