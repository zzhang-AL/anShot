//
//  ToastPresenter.swift
//  AnShotUI
//
//  轻提示：屏幕底部居中的深色胶囊，一行文案 + 可选的右侧小按钮。
//
//  ── 与 `PinNotice` 的分工 ────────────────────────────────────
//
//  `PinNotice` 是「钉住流程内的纯文字公告」，文案与停留时长都固定；
//  本类型是**全局操作反馈**（已复制 / 已保存 / 已加入历史），
//  需要动作按钮、可由调用方指定屏幕与时长、可被显式关闭。两者窗口纪律
//  相同（非激活、不抢焦点、不可被捕获），但状态模型不同，故不合并。
//
//  ── 为什么按钮要单独待在一个窗口里 ───────────────────────────
//
//  `NSWindow.ignoresMouseEvents` 是**窗口级**开关，AppKit 没有「某个视图
//  鼠标穿透给其它 App」的等价能力：只要胶囊窗口接收鼠标，胶囊矩形内的
//  每一次点击都会被本应用吃掉。而提示多数时候只是通知，没理由把屏幕底部
//  一条 36pt 高的区域从桌面交互里挖走 1.8 秒。
//
//  因此胶囊窗口**永远** `ignoresMouseEvents = true`，真正可点的动作按钮
//  放进一个贴合在胶囊右上角、同样非激活的小窗口。鼠标只有落在按钮上才会
//  被拦住；其余部分直接到达下面的应用。代价是两个窗口必须一起摆放、
//  一起收起，所以状态集中在本类型的静态变量里。
//
//  ── 为什么计时用 Timer 而不是 `Task.sleep` ─────────────────
//
//  新消息要**立刻**接管：旧消息的计时必须能同步取消，否则旧延时到点会把
//  刚出现的新提示关掉。`Timer.invalidate()` 提供了这个同步取消点。
//  定时器挂在 `RunLoop.main` 的 `.common` 模式：截图/录制期间鼠标可能正处在
//  事件追踪循环里，默认模式的定时器要等追踪结束才触发，提示会滞留不走。
//
//  ── 生命周期 ───────────────────────────────────────────────
//
//  所有静态状态在 `dismiss()` 里一次性清空（窗口、定时器、回调）。
//  回调闭包常强引用控制器/面板，提示消失后继续持有它们就是泄漏。
//

import AppKit

/// 全局轻提示。同一时刻至多显示一条。
@MainActor
public final class ToastPresenter {

    /// 语义状态类型（决定左侧 SF Symbol 图标与强调色）。
    public enum Tone: Sendable {
        case auto
        case info
        case success
        case warning
        case error

        fileprivate func resolved(for message: String) -> Tone {
            guard self == .auto else { return self }
            if message.contains("失败") || message.contains("无法") || message.contains("错误") || message.contains("异常") {
                return .error
            }
            if message.contains("上限") || message.contains("请先") || message.contains("未授权") || message.contains("暂未") {
                return .warning
            }
            if message.contains("已") || message.contains("成功") || message.contains("完成") || message.contains("updated") {
                return .success
            }
            return .info
        }

        fileprivate var symbolName: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error:   return "xmark.circle.fill"
            case .info, .auto: return "info.circle.fill"
            }
        }

        fileprivate var tintColor: NSColor {
            switch self {
            case .success: return .systemGreen
            case .warning: return .systemOrange
            case .error:   return .systemRed
            case .info, .auto: return NSColor.white.withAlphaComponent(0.9)
            }
        }
    }

    /// 全局完成轻提示开关（由 `AppSettings.showCompletionToast` 同步；失败/警告或带 action 按钮仍可按需展示）。
    public static var isEnabled: Bool = true

    /// 显示一条提示；已有提示会被替换，计时重新开始。
    public static func show(
        _ message: String,
        on screen: NSScreen? = nil,
        duration: TimeInterval = 2.0,
        actionTitle: String? = nil,
        tone: Tone = .auto,
        action: (() -> Void)? = nil
    ) {
        let resolvedTone = tone.resolved(for: message)
        if !isEnabled && resolvedTone != .error && action == nil {
            return
        }

        // 先拆旧的：旧回调不能在新提示上被触发，旧计时也不能再关新窗口。
        dismissImmediately()

        let targetScreen = screen ?? screenUnderMouse()
        let screenFrame = targetScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let messageFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let trimmedTitle = actionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableTitle = (action != nil && trimmedTitle?.isEmpty == false) ? trimmedTitle : nil

        let layout = measureLayout(
            message: message,
            messageFont: messageFont,
            actionTitle: usableTitle,
            screenFrame: screenFrame
        )
        let capsuleWidth = layout.capsuleSize.width
        let capsuleHeight = layout.capsuleSize.height
        let textWidth = layout.textSize.width
        let messageHeight = layout.textSize.height
        let buttonSize = layout.buttonSize
        let buttonFont = Self.actionButtonFont
        let iconAreaWidth: CGFloat = iconSize + iconGap

        let origin = CGPoint(
            x: screenFrame.midX - capsuleWidth / 2,
            y: screenFrame.minY + bottomInset
        )

        let capsule = ToastCapsuleView(frame: CGRect(x: 0, y: 0, width: capsuleWidth, height: capsuleHeight))
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        capsule.layer?.cornerRadius = layout.isMultiline ? 12 : (capsuleHeight / 2)
        capsule.layer?.borderWidth = 1
        capsule.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let iconView = NSImageView(frame: CGRect(
            x: horizontalPadding - 2,
            y: (capsuleHeight - iconSize) / 2,
            width: iconSize,
            height: iconSize
        ))
        iconView.image = NSImage(systemSymbolName: resolvedTone.symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = resolvedTone.tintColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        capsule.addSubview(iconView)

        let label = makeMessageLabel(
            message: message,
            font: messageFont,
            isMultiline: layout.isMultiline
        )
        label.frame = CGRect(
            x: horizontalPadding + iconAreaWidth,
            y: ((capsuleHeight - messageHeight) / 2).rounded(),
            width: textWidth,
            height: messageHeight
        )
        capsule.addSubview(label)

        let capsuleHandlesClick = action != nil && usableTitle == nil
        if capsuleHandlesClick, let action {
            capsule.onClick = {
                ToastPresenter.dismissImmediately()
                action()
            }
        }
        capsule.onHoverChanged = { hovered in
            ToastPresenter.handleHoverChanged(hovered)
        }

        let panel = ToastPanel(
            contentRect: CGRect(x: origin.x, y: origin.y, width: capsuleWidth, height: capsuleHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure(panel)
        panel.hasShadow = true
        panel.ignoresMouseEvents = !capsuleHandlesClick
        panel.alphaValue = 0
        panel.contentView = capsule

        var buttonPanel: ToastButtonPanel?
        if usableTitle != nil, let action {
            let relay = ToastActionRelay {
                ToastPresenter.dismissImmediately()
                action()
            }

            let button = makeActionButton(title: usableTitle ?? "", font: buttonFont, target: relay)
            button.frame = CGRect(origin: .zero, size: buttonSize)
            if let toastButton = button as? ToastActionButton {
                toastButton.onHoverChanged = { hovered in
                    ToastPresenter.handleHoverChanged(hovered)
                }
            }

            let buttonFrame = CGRect(
                x: capsuleWidth - horizontalPadding - buttonSize.width,
                y: (capsuleHeight - buttonSize.height) / 2,
                width: buttonSize.width,
                height: buttonSize.height
            )
            let panelForButton = ToastButtonPanel(
                contentRect: CGRect(
                    x: origin.x + buttonFrame.minX,
                    y: origin.y + buttonFrame.minY,
                    width: buttonSize.width,
                    height: buttonSize.height
                ),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            configure(panelForButton)
            panelForButton.hasShadow = false
            panelForButton.ignoresMouseEvents = false
            panelForButton.alphaValue = 0
            panelForButton.contentView = button

            buttonPanel = panelForButton
            self.buttonRelay = relay
        }

        self.panel = panel
        self.buttonPanel = buttonPanel
        self.activeDuration = duration
        self.toastGeneration &+= 1
        let currentGen = self.toastGeneration

        panel.orderFrontRegardless()
        buttonPanel?.orderFrontRegardless()

        // 柔和淡入（0.15s）
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
            buttonPanel?.animator().alphaValue = 1
        }

        scheduleAutoDismiss(after: duration, generation: currentGen)
    }

    /// 淡出并关闭当前提示。
    public static func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let currentPanel = panel else { return }
        let currentButton = buttonPanel
        let expectedGen = toastGeneration

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            currentPanel.animator().alphaValue = 0
            currentButton?.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                guard ToastPresenter.toastGeneration == expectedGen else { return }
                ToastPresenter.dismissImmediately()
            }
        })
    }

    /// 立即同步关闭（供切换新消息、点击动作或测试清理使用）。
    public static func dismissImmediately() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        buttonPanel?.orderOut(nil)
        panel = nil
        buttonPanel = nil
        buttonRelay = nil
        activeDuration = 0
    }

    private static func scheduleAutoDismiss(after duration: TimeInterval, generation: UInt64) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard duration > 0 else { return }
        let timer = Timer(timeInterval: duration, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard ToastPresenter.toastGeneration == generation else { return }
                ToastPresenter.dismiss()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    private static func handleHoverChanged(_ hovered: Bool) {
        if hovered {
            dismissTimer?.invalidate()
            dismissTimer = nil
        } else if activeDuration > 0 {
            scheduleAutoDismiss(after: max(0.8, activeDuration * 0.6), generation: toastGeneration)
        }
    }

    // MARK: - 静态状态

    private static var panel: ToastPanel?
    private static var buttonPanel: ToastButtonPanel?
    private static var dismissTimer: Timer?
    private static var buttonRelay: ToastActionRelay?
    private static var activeDuration: TimeInterval = 0
    private static var toastGeneration: UInt64 = 0

    private static let actionButtonFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let toastLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    /// 供生产展示与单元测试共用的精确排版度量结果。
    struct MeasuredLayout {
        let capsuleSize: CGSize
        let textSize: CGSize
        let buttonSize: CGSize
        let isMultiline: Bool
    }

    /// 通过真实 `NSTextFieldCell` 测量文本宽高（天然计入 AppKit 单元格左右内边距），
    /// 彻底杜绝单行中文（如「已复制到剪贴板」）因少算 4pt cell padding 被折行裁断成「已复制到」。
    static func measureLayout(
        message: String,
        messageFont: NSFont = NSFont.systemFont(ofSize: 13, weight: .medium),
        actionTitle: String?,
        screenFrame: CGRect
    ) -> MeasuredLayout {
        let buttonTitleSize = actionTitle.map {
            ($0 as NSString).size(withAttributes: [.font: actionButtonFont])
        } ?? .zero
        let buttonSize = CGSize(
            width: ceil(buttonTitleSize.width) + buttonHorizontalPadding * 2 + 2,
            height: ceil(buttonTitleSize.height) + buttonVerticalPadding * 2
        )
        let buttonAreaWidth = actionTitle == nil ? 0 : buttonGap + buttonSize.width
        let iconAreaWidth: CGFloat = iconSize + iconGap

        let maxCapsuleWidth = max(minimumAvailableWidth, screenFrame.width - screenInset * 2)
        let maxTextWidth = max(1, min(maximumTextWidth, maxCapsuleWidth - horizontalPadding * 2 - iconAreaWidth - buttonAreaWidth))

        let hasExplicitNewline = message.contains("\n")
        // 1. 先按单行标签实测自然宽度（含 NSTextFieldCell 自身左右 padding）。
        let singleProbe = NSTextField(labelWithString: message)
        singleProbe.font = messageFont
        let naturalSingleSize = singleProbe.cell?.cellSize(
            forBounds: CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 140)
        ) ?? singleProbe.fittingSize
        let naturalSingleWidth = ceil(naturalSingleSize.width) + 4
        let singleLineHeight = ceil(naturalSingleSize.height)

        let textWidth: CGFloat
        let messageHeight: CGFloat
        let isMultiline: Bool

        if !hasExplicitNewline && naturalSingleWidth <= maxTextWidth {
            textWidth = max(1, naturalSingleWidth)
            messageHeight = singleLineHeight
            isMultiline = false
        } else {
            let multiProbe = makeMessageLabel(message: message, font: messageFont, isMultiline: true)
            let wrappedSize = multiProbe.cell?.cellSize(
                forBounds: CGRect(x: 0, y: 0, width: maxTextWidth, height: 200)
            ) ?? CGSize(width: maxTextWidth, height: singleLineHeight * 2)
            textWidth = max(1, min(maxTextWidth, ceil(wrappedSize.width) + 4))
            messageHeight = max(singleLineHeight, ceil(wrappedSize.height) + 2)
            isMultiline = messageHeight > singleLineHeight * 1.35 || hasExplicitNewline
        }

        let capsuleHeight = max(minimumCapsuleHeight, messageHeight + verticalPadding * 2)
        let capsuleWidth = horizontalPadding * 2 + iconAreaWidth + textWidth + buttonAreaWidth
        return MeasuredLayout(
            capsuleSize: CGSize(width: capsuleWidth, height: capsuleHeight),
            textSize: CGSize(width: textWidth, height: messageHeight),
            buttonSize: buttonSize,
            isMultiline: isMultiline
        )
    }

    private static func makeMessageLabel(message: String, font: NSFont, isMultiline: Bool) -> NSTextField {
        let label: NSTextField
        if isMultiline {
            label = NSTextField(wrappingLabelWithString: message)
            label.usesSingleLineMode = false
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 4
        } else {
            label = NSTextField(labelWithString: message)
            label.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        label.font = font
        label.textColor = .white
        label.alignment = .left
        label.isSelectable = false
        return label
    }
    private static let bottomInset: CGFloat = 72
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 10
    private static let iconSize: CGFloat = 15
    private static let iconGap: CGFloat = 8
    private static let maximumTextWidth: CGFloat = 420
    private static let screenInset: CGFloat = 24
    private static let minimumCapsuleHeight: CGFloat = 36
    private static let minimumAvailableWidth: CGFloat = 120
    private static let buttonGap: CGFloat = 14
    private static let buttonHorizontalPadding: CGFloat = 10
    private static let buttonVerticalPadding: CGFloat = 4

    /// 纯静态类型，不提供实例。
    private init() {}

    // MARK: - 内部实现

    /// 默认屏幕：鼠标所在的屏。多显示器下用户刚操作的就是这块屏。
    private static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        if let hovered = NSScreen.screens.first(where: { $0.frame.contains(location) }) {
            return hovered
        }
        // 鼠标恰好在屏幕之间的缝隙：退回 `NSScreen.main`（当前活动窗口所在屏），
        // 再不行取第一块屏。
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// 两个窗口共用的配置：非激活、悬浮于覆盖层之上、不可被屏幕捕获。
    private static func configure(_ window: NSPanel) {
        window.level = toastLevel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // 系统默认的出现动画有可见延迟，提示要「立刻看见」。
        window.animationBehavior = .none
        window.isMovable = false
        window.isMovableByWindowBackground = false
        // 全空间可见、不参与 Exposé 的空间变换、不进入 Cmd+Tab/窗口循环。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // 提示不该出现在用户下一张截图或别人的录屏里。
        window.sharingType = .none
    }

    private static func makeActionButton(title: String, font: NSFont, target: ToastActionRelay) -> NSButton {
        let button = ToastActionButton(title: title, target: target, action: #selector(ToastActionRelay.fire))
        // 无边框 + 自绘背景：系统的 bordered 样式在深色胶囊上会显得笨重，
        // 而 `.inline` 圆角按钮是浅色主题的样式。
        button.isBordered = false
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        button.layer?.cornerRadius = 6
        // 标题用 attributed 明确给白字：胶囊是深色，系统按钮的默认标题色在
        // 非 key 窗口里会退成灰色，读起来像禁用。
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: NSColor.white]
        )
        button.alignment = .center
        return button
    }
}

// MARK: - 窗口与视图

/// 胶囊窗口：不可成为 key/main，否则点击按钮时会把提示变成焦点窗口。
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 动作按钮窗口：只覆盖按钮那一小块，是「有 action 时仅按钮可点」的载体。
private final class ToastButtonPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 胶囊内容视图。整块可点只在「有回调但没有按钮标题」的兜底路径下启用。
private final class ToastCapsuleView: NSView {
    var onClick: (@MainActor () -> Void)?
    var onHoverChanged: (@MainActor (Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil, bounds.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

private final class ToastActionButton: NSButton {
    var onHoverChanged: (@MainActor (Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 按钮的 target。`NSControl` 不持有 target，实例由 `ToastPresenter` 静态持有。
@MainActor
private final class ToastActionRelay: NSObject {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        // 回调里会 dismiss()，而 dismiss 会清空静态引用（本对象唯一的强引用）。
        // 显式延长生命周期，避免方法还没返回对象就被释放。
        withExtendedLifetime(self) {
            handler()
        }
    }
}
